package com.skybridge.compass.core.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.time.Duration.Companion.milliseconds

/**
 * 单一读取面的映射与守卫（任务 15.2 / R7.4、R7.8 区间）。
 */
class RuntimeNetworkParametersTest {

    @Test
    fun mapsStoredNetworkSettingsToTheThreeRuntimeParameters() {
        val parameters = RuntimeNetworkParametersPolicy.from(
            NetworkSettings(
                portRangeStart = 9000,
                portRangeEnd = 9010,
                discoveryTimeoutMs = 4_500L,
                maxReconnectAttempts = 7
            )
        )

        assertEquals(9000..9010, parameters.listenPortRange)
        assertEquals(4_500.milliseconds, parameters.discoveryWindow)
        assertEquals(7, parameters.maxReconnectAttempts)
    }

    @Test
    fun defaultStoredSettingsMapToDocumentedDefaults() {
        val parameters = RuntimeNetworkParametersPolicy.from(NetworkSettings())

        assertEquals(8080..8090, parameters.listenPortRange)
        assertEquals(30_000.milliseconds, parameters.discoveryWindow)
        assertEquals(3, parameters.maxReconnectAttempts)
    }

    @Test
    fun readSurfaceDoesNotTrustOutOfRangeStoredPorts() {
        // 存储层若含越界端口（例如历史数据或直写），读取面必须钳制回 1..65535。
        val low = RuntimeNetworkParametersPolicy.from(
            NetworkSettings(portRangeStart = -5, portRangeEnd = 0)
        )
        assertEquals(RuntimeNetworkParametersPolicy.MIN_PORT, low.listenPortRange.first)
        assertTrue(low.listenPortRange.last >= low.listenPortRange.first)

        val high = RuntimeNetworkParametersPolicy.from(
            NetworkSettings(portRangeStart = 70_000, portRangeEnd = 99_999)
        )
        assertEquals(RuntimeNetworkParametersPolicy.MAX_PORT, high.listenPortRange.first)
        assertEquals(RuntimeNetworkParametersPolicy.MAX_PORT, high.listenPortRange.last)
    }

    @Test
    fun readSurfaceKeepsEndNotBelowStartSoTheRangeIsNeverEmpty() {
        val parameters = RuntimeNetworkParametersPolicy.from(
            NetworkSettings(portRangeStart = 9000, portRangeEnd = 8000)
        )

        assertTrue(parameters.listenPortRange.last >= parameters.listenPortRange.first)
        assertTrue(!parameters.listenPortRange.isEmpty())
        assertEquals(9000..9000, parameters.listenPortRange)
    }

    @Test
    fun readSurfaceClampsDiscoveryWindowToDeclaredBounds() {
        val tooShort = RuntimeNetworkParametersPolicy.from(NetworkSettings(discoveryTimeoutMs = 0L))
        assertEquals(RuntimeNetworkParametersPolicy.MIN_DISCOVERY_WINDOW, tooShort.discoveryWindow)

        val tooLong = RuntimeNetworkParametersPolicy.from(
            NetworkSettings(discoveryTimeoutMs = 999_999L)
        )
        assertEquals(RuntimeNetworkParametersPolicy.MAX_DISCOVERY_WINDOW, tooLong.discoveryWindow)
    }

    @Test
    fun readSurfaceClampsReconnectAttemptsToZeroThroughTen() {
        assertEquals(
            0,
            RuntimeNetworkParametersPolicy.from(
                NetworkSettings(maxReconnectAttempts = -3)
            ).maxReconnectAttempts
        )
        assertEquals(
            10,
            RuntimeNetworkParametersPolicy.from(
                NetworkSettings(maxReconnectAttempts = 42)
            ).maxReconnectAttempts
        )
    }
}
