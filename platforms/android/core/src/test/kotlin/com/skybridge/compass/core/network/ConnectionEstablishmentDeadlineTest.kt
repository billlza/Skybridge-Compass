package com.skybridge.compass.core.network

import com.skybridge.compass.shared.p2p.HandshakeFailureCategory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

/**
 * 单元测试覆盖任务 9.7 的两条核心行为（R4.1 / R4.2）：
 *
 * 1. 整体连接建立时限（30s）到期即失败并如实呈现原因分类（恒为「超时」）；
 * 2. 仅在应用层会话密钥建立后才可把会话呈现为「已建立」，之前一律不呈现。
 *
 * 时钟通过注入确定化，无需真实等待即可推进到时限边界。
 */
class ConnectionEstablishmentDeadlineTest {

    /** 可控单调时钟（毫秒），供确定化推进。 */
    private class FakeClock(var nowMs: Long = 0L) {
        fun advance(duration: Duration) {
            nowMs += duration.inWholeMilliseconds
        }
    }

    private fun deadlineWith(
        clock: FakeClock,
        overall: Duration = ConnectionEstablishmentDeadline.DEFAULT_OVERALL_DEADLINE
    ): ConnectionEstablishmentDeadline =
        ConnectionEstablishmentDeadline(overallDeadline = overall, now = { clock.nowMs })

    // ---- 整体时限到期即失败并如实呈现「超时」原因（R4.1 / R4.4）----

    @Test
    fun defaultOverallDeadlineIsThirtySeconds() {
        assertEquals(30.seconds, ConnectionEstablishmentDeadline.DEFAULT_OVERALL_DEADLINE)
    }

    @Test
    fun segmentDeadlinesMatchDesignSection4() {
        assertEquals(5.seconds, ConnectionEstablishmentDeadline.CONTROL_CHANNEL_DEADLINE)
        assertEquals(10.seconds, ConnectionEstablishmentDeadline.ICE_GATHERING_DEADLINE)
        assertEquals(15.seconds, ConnectionEstablishmentDeadline.HANDSHAKE_DEADLINE)
    }

    @Test
    fun notExpiredBeforeStart() {
        val clock = FakeClock()
        val deadline = deadlineWith(clock)
        assertFalse("un-armed deadline must never be expired", deadline.hasExpired())
        assertFalse(deadline.isArmed())
    }

    @Test
    fun notExpiredJustBeforeThirtySeconds() {
        val clock = FakeClock()
        val deadline = deadlineWith(clock)
        deadline.start()
        clock.advance(29_999.milliseconds)
        assertFalse("29.999s < 30s must not be expired", deadline.hasExpired())
    }

    @Test
    fun expiredExactlyAtThirtySeconds() {
        val clock = FakeClock()
        val deadline = deadlineWith(clock)
        deadline.start()
        clock.advance(30.seconds)
        assertTrue("elapsed == 30s must be expired (inclusive deadline)", deadline.hasExpired())
    }

    @Test
    fun deadlineExpiryWithoutSessionKeysFailsWithTruthfulTimeoutReason() {
        val clock = FakeClock()
        val deadline = deadlineWith(clock)
        deadline.start()
        clock.advance(30.seconds)

        assertTrue(deadline.hasExpired())
        // 到期时应用层会话密钥仍未建立 => 超时失败，且分类恒为 TIMEOUT（如实呈现，不改分类）。
        val outcome = deadline.evaluateOnDeadline(appLayerSessionKeysEstablished = false)
        assertTrue(outcome is ConnectionEstablishmentDeadline.Outcome.TimedOut)
        assertEquals(
            HandshakeFailureCategory.TIMEOUT,
            (outcome as ConnectionEstablishmentDeadline.Outcome.TimedOut).category
        )
        assertEquals("timeout", outcome.category.diagnosticCode)
        assertEquals("timeout", ConnectionEstablishmentDeadline.TIMEOUT_DIAGNOSTIC_CODE)
    }

    @Test
    fun remainingCountsDownAndClampsAtZero() {
        val clock = FakeClock()
        val deadline = deadlineWith(clock)
        assertEquals("un-armed remaining is the full deadline", 30.seconds, deadline.remaining())

        deadline.start()
        assertEquals(30.seconds, deadline.remaining())

        clock.advance(10.seconds)
        assertEquals(20.seconds, deadline.remaining())
        assertEquals(10.seconds, deadline.elapsed())

        clock.advance(40.seconds)
        assertEquals("remaining never goes negative", Duration.ZERO, deadline.remaining())
    }

    @Test
    fun clearDisarmsTheDeadline() {
        val clock = FakeClock()
        val deadline = deadlineWith(clock)
        deadline.start()
        clock.advance(60.seconds)
        assertTrue(deadline.hasExpired())

        deadline.clear()
        assertFalse("cleared deadline must not be expired", deadline.hasExpired())
        assertFalse(deadline.isArmed())
    }

    @Test
    fun rejectsNonPositiveDeadline() {
        assertThrows(IllegalArgumentException::class.java) {
            ConnectionEstablishmentDeadline(overallDeadline = Duration.ZERO)
        }
        assertThrows(IllegalArgumentException::class.java) {
            ConnectionEstablishmentDeadline(overallDeadline = (-1).seconds)
        }
    }

    // ---- 会话建立呈现门：仅在应用层会话密钥建立后才呈现「已建立」（R4.2 不变式）----

    @Test
    fun sessionNotPresentedEstablishedBeforeAppLayerSessionKeysExist() {
        val deadline = deadlineWith(FakeClock())
        // 应用层会话密钥尚未建立（经典引导通道未完成强制 PQC 更新 / 握手未派生密钥）。
        assertFalse(
            "must NOT present established before app-layer session keys exist",
            deadline.canPresentEstablished(appLayerSessionKeysEstablished = false)
        )
    }

    @Test
    fun establishedPresentedOnlyAfterSecureSessionCompletes() {
        val deadline = deadlineWith(FakeClock())
        // 安全会话完成、会话密钥建立后方可呈现为已建立。
        assertTrue(
            "established is presented once app-layer session keys are established",
            deadline.canPresentEstablished(appLayerSessionKeysEstablished = true)
        )
    }

    @Test
    fun deadlineWithinWindowAndKeysEstablishedYieldsEstablishedOutcome() {
        val clock = FakeClock()
        val deadline = deadlineWith(clock)
        deadline.start()
        clock.advance(29.seconds)
        // 时限内会话密钥已建立 => 终态为已建立，无超时。
        val outcome = deadline.evaluateOnDeadline(appLayerSessionKeysEstablished = true)
        assertEquals(ConnectionEstablishmentDeadline.Outcome.Established, outcome)
    }
}
