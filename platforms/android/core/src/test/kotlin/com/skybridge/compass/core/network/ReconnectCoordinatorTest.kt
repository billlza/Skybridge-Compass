package com.skybridge.compass.core.network

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.time.Duration

class ReconnectCoordinatorTest {

    /** 抖动为 0 的确定化策略。 */
    private fun policy(maxAttempts: Int) =
        DefaultReconnectPolicy(maxAttempts = maxAttempts, jitterFraction = { 0.0 })

    @Test
    fun unexpectedDisconnect_followsBackoffSequenceAcrossAttempts() = runTest {
        val recordedDelays = mutableListOf<Duration>()
        // 全部尝试失败，以观察完整的退避序列。
        val coordinator = ReconnectCoordinator(
            policy = policy(maxAttempts = 4),
            attemptConnect = { ReconnectAttemptResult.Failed("TIMEOUT") },
            sleep = { recordedDelays += it }
        )

        val result = coordinator.onDisconnected(DisconnectCause.UNEXPECTED)

        assertFalse(result)
        // 退避序列：1s/2s/4s/8s。
        assertEquals(
            listOf(1_000L, 2_000L, 4_000L, 8_000L),
            recordedDelays.map { it.inWholeMilliseconds }
        )
    }

    @Test
    fun givesUpAfterMaxAttemptsAndReportsGaveUpWithFailureCategory() = runTest {
        val coordinator = ReconnectCoordinator(
            policy = policy(maxAttempts = 3),
            attemptConnect = { ReconnectAttemptResult.Failed("NETWORK_UNREACHABLE") },
            sleep = { }
        )

        val result = coordinator.onDisconnected(DisconnectCause.UNEXPECTED)

        assertFalse(result)
        val state = coordinator.state.value
        assertTrue(state is ReconnectState.GaveUp)
        state as ReconnectState.GaveUp
        assertEquals(3, state.attempts)
        assertEquals(3, state.maxAttempts)
        assertEquals("NETWORK_UNREACHABLE", state.failureCategory)
    }

    @Test
    fun successfulReconnect_reportsReconnectedAndResetsOnNextCycle() = runTest {
        var attemptsSeen = 0
        val presented = mutableListOf<ReconnectState>()
        // 第 2 次尝试成功。
        val coordinator = ReconnectCoordinator(
            policy = policy(maxAttempts = 5),
            attemptConnect = { attempt ->
                attemptsSeen = attempt
                if (attempt >= 2) ReconnectAttemptResult.Established
                else ReconnectAttemptResult.Failed("TIMEOUT")
            },
            sleep = { presented += ReconnectState.Idle } // sleep 本身不改状态，占位记录顺序
        )

        val result = coordinator.onDisconnected(DisconnectCause.UNEXPECTED)

        assertTrue(result)
        assertEquals(2, attemptsSeen)
        assertEquals(ReconnectState.Reconnected, coordinator.state.value)

        // 后续再次意外断开：计数从头开始（重置），并再次成功。
        var secondCycleFirstAttempt = -1
        val coordinator2 = ReconnectCoordinator(
            policy = policy(maxAttempts = 5),
            attemptConnect = { attempt ->
                secondCycleFirstAttempt = attempt
                ReconnectAttemptResult.Established
            },
            sleep = { }
        )
        assertTrue(coordinator2.onDisconnected(DisconnectCause.UNEXPECTED))
        assertEquals(1, secondCycleFirstAttempt)
        assertEquals(ReconnectState.Reconnected, coordinator2.state.value)
    }

    @Test
    fun reconnectingState_carriesAttemptNumberAndMaxCap() = runTest {
        // 状态在每次 attemptConnect 调用前被设为 Reconnecting(序号, 上限)，
        // 在 attemptConnect 内读取 coordinator.state 即可如实观察该呈现（R4.7）。
        val presented = mutableListOf<ReconnectState.Reconnecting>()
        lateinit var coordinator: ReconnectCoordinator
        coordinator = ReconnectCoordinator(
            policy = policy(maxAttempts = 7),
            attemptConnect = { attempt ->
                val s = coordinator.state.value
                assertTrue(s is ReconnectState.Reconnecting)
                presented += s as ReconnectState.Reconnecting
                if (attempt < 3) ReconnectAttemptResult.Failed("TIMEOUT")
                else ReconnectAttemptResult.Established
            },
            sleep = { }
        )

        assertTrue(coordinator.onDisconnected(DisconnectCause.UNEXPECTED))

        // 三次尝试的序号与上限均如实呈现。
        assertEquals(listOf(1, 2, 3), presented.map { it.attempt })
        assertTrue(presented.all { it.maxAttempts == 7 })
        assertEquals(ReconnectState.Reconnected, coordinator.state.value)
    }

    @Test
    fun intentionalDisconnect_doesNotTriggerReconnect() = runTest {
        var attemptCount = 0
        val coordinator = ReconnectCoordinator(
            policy = policy(maxAttempts = 5),
            attemptConnect = {
                attemptCount++
                ReconnectAttemptResult.Established
            },
            sleep = { attemptCount++ }
        )

        val result = coordinator.onDisconnected(DisconnectCause.INTENTIONAL)

        assertFalse(result)
        assertEquals(0, attemptCount)
        assertEquals(ReconnectState.Idle, coordinator.state.value)
    }

    @Test
    fun terminalDisconnect_doesNotTriggerReconnect() = runTest {
        var attemptCount = 0
        val coordinator = ReconnectCoordinator(
            policy = policy(maxAttempts = 5),
            attemptConnect = {
                attemptCount++
                ReconnectAttemptResult.Established
            },
            sleep = { attemptCount++ }
        )

        val result = coordinator.onDisconnected(DisconnectCause.TERMINAL)

        assertFalse(result)
        assertEquals(0, attemptCount)
        val state = coordinator.state.value
        assertTrue(state is ReconnectState.GaveUp)
        state as ReconnectState.GaveUp
        assertEquals(0, state.attempts)
        assertEquals(ReconnectCoordinator.FAILURE_TERMINAL, state.failureCategory)
    }

    @Test
    fun handshakeFingerprintMismatch_neverReconnects() = runTest {
        // R4.13: 身份指纹不匹配立即中止，自动重连尝试数为 0。
        var attemptCount = 0
        val coordinator = ReconnectCoordinator(
            policy = policy(maxAttempts = 5),
            attemptConnect = {
                attemptCount++
                ReconnectAttemptResult.Established
            },
            sleep = { attemptCount++ }
        )

        val result = coordinator.onHandshakeFailure(
            com.skybridge.compass.shared.p2p.HandshakeFailureCategory.IDENTITY_FINGERPRINT_MISMATCH
        )

        assertFalse(result)
        assertEquals("fingerprint mismatch must not attempt any reconnect", 0, attemptCount)
        assertTrue(coordinator.state.value is ReconnectState.GaveUp)
    }

    @Test
    fun handshakeTransientFailure_followsBackoffReconnect() = runTest {
        // 瞬时传输失败（超时）仍按 R4.7 退避重连。
        var attemptCount = 0
        val coordinator = ReconnectCoordinator(
            policy = policy(maxAttempts = 3),
            attemptConnect = {
                attemptCount++
                if (attemptCount >= 2) ReconnectAttemptResult.Established
                else ReconnectAttemptResult.Failed("TIMEOUT")
            },
            sleep = { }
        )

        val result = coordinator.onHandshakeFailure(
            com.skybridge.compass.shared.p2p.HandshakeFailureCategory.TIMEOUT
        )

        assertTrue(result)
        assertTrue("transient failure should have attempted at least once", attemptCount >= 1)
        assertEquals(ReconnectState.Reconnected, coordinator.state.value)
    }

    @Test
    fun zeroMaxAttempts_gaveUpImmediatelyWithoutAttempting() = runTest {
        var attemptCount = 0
        val coordinator = ReconnectCoordinator(
            policy = policy(maxAttempts = 0),
            attemptConnect = {
                attemptCount++
                ReconnectAttemptResult.Established
            },
            sleep = { attemptCount++ }
        )

        val result = coordinator.onDisconnected(DisconnectCause.UNEXPECTED)

        assertFalse(result)
        assertEquals(0, attemptCount)
        val state = coordinator.state.value
        assertTrue(state is ReconnectState.GaveUp)
        state as ReconnectState.GaveUp
        assertEquals(0, state.attempts)
        assertEquals(ReconnectCoordinator.FAILURE_RECONNECT_DISABLED, state.failureCategory)
    }
}
