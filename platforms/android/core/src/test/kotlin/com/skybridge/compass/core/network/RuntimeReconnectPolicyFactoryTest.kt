package com.skybridge.compass.core.network

import com.skybridge.compass.core.data.RuntimeNetworkParameters
import com.skybridge.compass.core.data.RuntimeNetworkParametersPolicy
import com.skybridge.compass.core.data.RuntimeNetworkParametersSnapshot
import com.skybridge.compass.core.data.RuntimeNetworkParametersSource
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds

/**
 * `maxReconnectAttempts` 经单一读取面接线到 `ReconnectPolicy.maxAttempts`，且**新建立的会话**
 * 按新值运行、进行中的会话不被改动（任务 15.2 / R7.4）。
 */
class RuntimeReconnectPolicyFactoryTest {

    private class MutableSource(
        listenPortRange: IntRange = 8080..8090,
        discoveryWindow: Duration = 30_000.milliseconds,
        maxReconnectAttempts: Int = 3
    ) : RuntimeNetworkParametersSource {
        private val state = MutableStateFlow<RuntimeNetworkParameters>(
            RuntimeNetworkParametersSnapshot(
                listenPortRange = listenPortRange,
                discoveryWindow = discoveryWindow,
                maxReconnectAttempts = maxReconnectAttempts
            )
        )

        fun setMaxReconnectAttempts(attempts: Int) {
            val previous = state.value
            state.value = RuntimeNetworkParametersSnapshot(
                listenPortRange = previous.listenPortRange,
                discoveryWindow = previous.discoveryWindow,
                maxReconnectAttempts = attempts
            )
        }

        override suspend fun current(): RuntimeNetworkParameters = state.value

        override fun observe(): Flow<RuntimeNetworkParameters> = state.asStateFlow()
    }

    @Test
    fun reconnectPolicyMaxAttemptsFollowsTheSetting() = runTest {
        val source = MutableSource(maxReconnectAttempts = 5)
        val factory = RuntimeReconnectPolicyFactory(source)

        assertEquals(5, factory.forNewSession().maxAttempts)
    }

    @Test
    fun newSessionUsesTheChangedValueWhileTheInFlightSessionKeepsItsOwn() = runTest {
        val source = MutableSource(maxReconnectAttempts = 3)
        val factory = RuntimeReconnectPolicyFactory(source)

        // 会话 A 在旧值下建立，持有它建立时拿到的策略实例。
        val inFlightSessionPolicy = factory.forNewSession()
        assertEquals(3, inFlightSessionPolicy.maxAttempts)

        // 用户改设置。
        source.setMaxReconnectAttempts(8)

        // 新建立的会话 B 按新值运行……
        assertEquals(8, factory.forNewSession().maxAttempts)
        // ……而进行中的会话 A 的策略未被改动。
        assertEquals(3, inFlightSessionPolicy.maxAttempts)
    }

    @Test
    fun zeroAttemptsDisablesReconnectThroughTheSameSurface() = runTest {
        val source = MutableSource(maxReconnectAttempts = 0)

        assertEquals(0, RuntimeReconnectPolicyFactory(source).forNewSession().maxAttempts)
    }

    @Test
    fun policyBuiltFromTheReadSurfaceMatchesTheClampedStoredValue() = runTest {
        // 读取面已把越界值钳制到 0..10，策略据此构造不再抛错。
        val clamped = RuntimeNetworkParametersPolicy.from(
            com.skybridge.compass.core.data.NetworkSettings(maxReconnectAttempts = 99)
        )
        val policy = DefaultReconnectPolicy.from(clamped) { 0.0 }

        assertEquals(RuntimeNetworkParametersPolicy.MAX_RECONNECT_ATTEMPTS, policy.maxAttempts)
    }
}
