package com.skybridge.compass.core.data

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertInstanceOf
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Nested
import org.junit.jupiter.api.Test

/**
 * 任务 15.6 / R7.8：「先校验后写入」的纯函数校验面测试。
 *
 * 覆盖：边界接受值、刚越界拒绝值、`end < start`、空串、非数值，以及每条拒绝提示都同时含
 * 最小值与最大值。
 */
@DisplayName("NetworkSettingsValidator (R7.8 validate-before-write)")
class NetworkSettingsValidatorTest {

    private fun <T> assertAccepted(expected: T, result: NetworkSettingValidation<T>) {
        val accepted = assertInstanceOf(
            NetworkSettingValidation.Accepted::class.java,
            result,
            "expected accepted, got $result"
        )
        assertEquals(expected, accepted.value)
    }

    private fun <T> assertRejected(result: NetworkSettingValidation<T>): NetworkSettingRejection {
        val rejected = assertInstanceOf(
            NetworkSettingValidation.Rejected::class.java,
            result,
            "expected rejected, got $result"
        )
        return rejected.reason
    }

    /** R7.8 提示必须同时含最小与最大值。 */
    private fun assertMessageCarriesBounds(reason: NetworkSettingRejection) {
        assertTrue(
            reason.message.contains(reason.min.toString()),
            "message must contain min ${reason.min}: ${reason.message}"
        )
        assertTrue(
            reason.message.contains(reason.max.toString()),
            "message must contain max ${reason.max}: ${reason.message}"
        )
    }

    @Nested
    @DisplayName("port range 1..65535 and end >= start")
    inner class PortRange {

        @Test
        fun `accepts in-range boundary values`() {
            assertAccepted(1..65535, NetworkSettingsValidator.validatePortRangeInput("1", "65535"))
            assertAccepted(65535..65535, NetworkSettingsValidator.validatePortRangeInput("65535", "65535"))
            assertAccepted(8080..8090, NetworkSettingsValidator.validatePortRangeInput("8080", "8090"))
        }

        @Test
        fun `accepts equal start and end`() {
            assertAccepted(1..1, NetworkSettingsValidator.validatePortRangeInput("1", "1"))
        }

        @Test
        fun `rejects just-outside start values`() {
            listOf("0", "-1", "65536", "99999").forEach { raw ->
                val reason = assertRejected(
                    NetworkSettingsValidator.validatePortRangeInput(raw, "9000")
                )
                assertInstanceOf(NetworkSettingRejection.OutOfRange::class.java, reason, "raw=$raw")
                assertEquals(NetworkSettingField.PORT_RANGE_START, reason.settingField, "raw=$raw")
                assertEquals(1L, reason.min)
                assertEquals(65535L, reason.max)
                assertMessageCarriesBounds(reason)
            }
        }

        @Test
        fun `rejects just-outside end values`() {
            listOf("0", "65536").forEach { raw ->
                val reason = assertRejected(
                    NetworkSettingsValidator.validatePortRangeInput("8080", raw)
                )
                assertInstanceOf(NetworkSettingRejection.OutOfRange::class.java, reason, "raw=$raw")
                assertEquals(NetworkSettingField.PORT_RANGE_END, reason.settingField, "raw=$raw")
                assertMessageCarriesBounds(reason)
            }
        }

        @Test
        fun `rejects just-outside values on typed path`() {
            listOf(0 to 9000, 65536 to 65535, 8080 to 0, 8080 to 65536).forEach { (start, end) ->
                val reason = assertRejected(NetworkSettingsValidator.validatePortRange(start, end))
                assertMessageCarriesBounds(reason)
            }
        }

        @Test
        fun `rejects end before start`() {
            val reason = assertRejected(
                NetworkSettingsValidator.validatePortRangeInput("9000", "8080")
            )
            val endBeforeStart = assertInstanceOf(
                NetworkSettingRejection.EndBeforeStart::class.java,
                reason
            )
            assertEquals(9000, endBeforeStart.start)
            assertEquals(8080, endBeforeStart.end)
            assertEquals(NetworkSettingField.PORT_RANGE_END, reason.settingField)
            assertMessageCarriesBounds(reason)
        }

        @Test
        fun `rejects end before start on typed path`() {
            val reason = assertRejected(NetworkSettingsValidator.validatePortRange(9000, 8080))
            assertInstanceOf(NetworkSettingRejection.EndBeforeStart::class.java, reason)
            assertMessageCarriesBounds(reason)
        }

        @Test
        fun `rejects empty start`() {
            listOf("", "   ").forEach { raw ->
                val reason = assertRejected(
                    NetworkSettingsValidator.validatePortRangeInput(raw, "9000")
                )
                assertInstanceOf(NetworkSettingRejection.Empty::class.java, reason, "raw=[$raw]")
                assertEquals(NetworkSettingField.PORT_RANGE_START, reason.settingField)
                assertMessageCarriesBounds(reason)
            }
        }

        @Test
        fun `rejects empty end`() {
            val reason = assertRejected(
                NetworkSettingsValidator.validatePortRangeInput("8080", "")
            )
            assertInstanceOf(NetworkSettingRejection.Empty::class.java, reason)
            assertEquals(NetworkSettingField.PORT_RANGE_END, reason.settingField)
            assertMessageCarriesBounds(reason)
        }

        @Test
        fun `rejects non-numeric input`() {
            listOf("abc", "80 80", "8.0", "0x1f", "１２３", "--1").forEach { raw ->
                val reason = assertRejected(
                    NetworkSettingsValidator.validatePortRangeInput(raw, "9000")
                )
                assertInstanceOf(NetworkSettingRejection.NotNumeric::class.java, reason, "raw=$raw")
                assertMessageCarriesBounds(reason)
            }
        }

        @Test
        fun `treats overlong digit string as out of range`() {
            val reason = assertRejected(
                NetworkSettingsValidator.validatePortRangeInput("99999999999999999999", "9000")
            )
            assertInstanceOf(NetworkSettingRejection.OutOfRange::class.java, reason)
            assertMessageCarriesBounds(reason)
        }
    }

    @Nested
    @DisplayName("discovery timeout 250..120000 ms")
    inner class DiscoveryTimeout {

        @Test
        fun `accepts boundary values`() {
            listOf(250L, 120_000L, 30_000L).forEach { value ->
                assertAccepted(
                    value,
                    NetworkSettingsValidator.validateDiscoveryTimeoutMsInput(value.toString())
                )
                assertAccepted(value, NetworkSettingsValidator.validateDiscoveryTimeoutMs(value))
            }
        }

        @Test
        fun `rejects just-outside values`() {
            listOf("249", "120001", "0", "-1").forEach { raw ->
                val reason = assertRejected(
                    NetworkSettingsValidator.validateDiscoveryTimeoutMsInput(raw)
                )
                assertInstanceOf(NetworkSettingRejection.OutOfRange::class.java, reason, "raw=$raw")
                assertEquals(NetworkSettingField.DISCOVERY_TIMEOUT_MS, reason.settingField)
                assertEquals(250L, reason.min)
                assertEquals(120_000L, reason.max)
                assertMessageCarriesBounds(reason)
            }
        }

        @Test
        fun `rejects just-outside values on typed path`() {
            listOf(249L, 120_001L).forEach { value ->
                val reason = assertRejected(
                    NetworkSettingsValidator.validateDiscoveryTimeoutMs(value)
                )
                assertInstanceOf(NetworkSettingRejection.OutOfRange::class.java, reason)
                assertMessageCarriesBounds(reason)
            }
        }

        @Test
        fun `rejects empty`() {
            listOf("", "  ").forEach { raw ->
                val reason = assertRejected(
                    NetworkSettingsValidator.validateDiscoveryTimeoutMsInput(raw)
                )
                assertInstanceOf(NetworkSettingRejection.Empty::class.java, reason)
                assertMessageCarriesBounds(reason)
            }
        }

        @Test
        fun `rejects non-numeric`() {
            listOf("abc", "30s", "3e4", "250.0").forEach { raw ->
                val reason = assertRejected(
                    NetworkSettingsValidator.validateDiscoveryTimeoutMsInput(raw)
                )
                assertInstanceOf(NetworkSettingRejection.NotNumeric::class.java, reason, "raw=$raw")
                assertMessageCarriesBounds(reason)
            }
        }
    }

    @Nested
    @DisplayName("reconnect attempts 0..10")
    inner class ReconnectAttempts {

        @Test
        fun `accepts boundary values`() {
            listOf(0, 10, 3).forEach { value ->
                assertAccepted(
                    value,
                    NetworkSettingsValidator.validateMaxReconnectAttemptsInput(value.toString())
                )
                assertAccepted(value, NetworkSettingsValidator.validateMaxReconnectAttempts(value))
            }
        }

        @Test
        fun `rejects just-outside values`() {
            listOf("-1", "11", "100").forEach { raw ->
                val reason = assertRejected(
                    NetworkSettingsValidator.validateMaxReconnectAttemptsInput(raw)
                )
                assertInstanceOf(NetworkSettingRejection.OutOfRange::class.java, reason, "raw=$raw")
                assertEquals(NetworkSettingField.MAX_RECONNECT_ATTEMPTS, reason.settingField)
                assertEquals(0L, reason.min)
                assertEquals(10L, reason.max)
                assertMessageCarriesBounds(reason)
            }
        }

        @Test
        fun `rejects just-outside values on typed path`() {
            listOf(-1, 11).forEach { value ->
                val reason = assertRejected(
                    NetworkSettingsValidator.validateMaxReconnectAttempts(value)
                )
                assertInstanceOf(NetworkSettingRejection.OutOfRange::class.java, reason)
                assertMessageCarriesBounds(reason)
            }
        }

        @Test
        fun `rejects empty`() {
            val reason = assertRejected(
                NetworkSettingsValidator.validateMaxReconnectAttemptsInput("  ")
            )
            assertInstanceOf(NetworkSettingRejection.Empty::class.java, reason)
            assertMessageCarriesBounds(reason)
        }

        @Test
        fun `rejects non-numeric`() {
            listOf("abc", "1x", "+-1", "3.0").forEach { raw ->
                val reason = assertRejected(
                    NetworkSettingsValidator.validateMaxReconnectAttemptsInput(raw)
                )
                assertInstanceOf(NetworkSettingRejection.NotNumeric::class.java, reason, "raw=$raw")
                assertMessageCarriesBounds(reason)
            }
        }
    }

    @Nested
    @DisplayName("no silent clamping / storage backstop stays identity for validated values")
    inner class NoSilentClamping {

        @Test
        fun `out-of-range input never yields a clamped accepted value`() {
            listOf("0", "65536", "99999").forEach { raw ->
                assertNull(
                    NetworkSettingsValidator.validatePortRangeInput(raw, "65535").acceptedValueOrNull(),
                    "raw=$raw must not produce a value"
                )
            }
            assertNull(NetworkSettingsValidator.validateDiscoveryTimeoutMsInput("120001").acceptedValueOrNull())
            assertNull(NetworkSettingsValidator.validateDiscoveryTimeoutMsInput("249").acceptedValueOrNull())
            assertNull(NetworkSettingsValidator.validateMaxReconnectAttemptsInput("11").acceptedValueOrNull())
            assertNull(NetworkSettingsValidator.validateMaxReconnectAttemptsInput("-1").acceptedValueOrNull())
        }

        @Test
        fun `backstop is identity for every validated boundary value`() {
            assertEquals(1, NetworkSettingsStorageBackstop.clampPortStart(1))
            assertEquals(65535, NetworkSettingsStorageBackstop.clampPortStart(65535))
            assertEquals(65535, NetworkSettingsStorageBackstop.clampPortEnd(1, 65535))
            assertEquals(8090, NetworkSettingsStorageBackstop.clampPortEnd(8080, 8090))
            assertEquals(250L, NetworkSettingsStorageBackstop.clampDiscoveryTimeoutMs(250L))
            assertEquals(120_000L, NetworkSettingsStorageBackstop.clampDiscoveryTimeoutMs(120_000L))
            assertEquals(0, NetworkSettingsStorageBackstop.clampReconnectAttempts(0))
            assertEquals(10, NetworkSettingsStorageBackstop.clampReconnectAttempts(10))
        }

        @Test
        fun `backstop still guards callers that bypass validation`() {
            assertEquals(1, NetworkSettingsStorageBackstop.clampPortStart(0))
            assertEquals(65535, NetworkSettingsStorageBackstop.clampPortStart(70_000))
            assertEquals(8080, NetworkSettingsStorageBackstop.clampPortEnd(8080, 1))
            assertEquals(250L, NetworkSettingsStorageBackstop.clampDiscoveryTimeoutMs(0L))
            assertEquals(120_000L, NetworkSettingsStorageBackstop.clampDiscoveryTimeoutMs(999_999L))
            assertEquals(0, NetworkSettingsStorageBackstop.clampReconnectAttempts(-5))
            assertEquals(10, NetworkSettingsStorageBackstop.clampReconnectAttempts(99))
        }

        @Test
        fun `validator bounds match the runtime read-side policy`() {
            assertEquals(RuntimeNetworkParametersPolicy.MIN_PORT, NetworkSettingsValidator.MIN_PORT)
            assertEquals(RuntimeNetworkParametersPolicy.MAX_PORT, NetworkSettingsValidator.MAX_PORT)
            assertEquals(
                RuntimeNetworkParametersPolicy.MIN_RECONNECT_ATTEMPTS,
                NetworkSettingsValidator.MIN_RECONNECT_ATTEMPTS
            )
            assertEquals(
                RuntimeNetworkParametersPolicy.MAX_RECONNECT_ATTEMPTS,
                NetworkSettingsValidator.MAX_RECONNECT_ATTEMPTS
            )
            assertEquals(
                RuntimeNetworkParametersPolicy.MIN_DISCOVERY_WINDOW.inWholeMilliseconds,
                NetworkSettingsValidator.MIN_DISCOVERY_TIMEOUT_MS
            )
            assertEquals(
                RuntimeNetworkParametersPolicy.MAX_DISCOVERY_WINDOW.inWholeMilliseconds,
                NetworkSettingsValidator.MAX_DISCOVERY_TIMEOUT_MS
            )
        }
    }
}
