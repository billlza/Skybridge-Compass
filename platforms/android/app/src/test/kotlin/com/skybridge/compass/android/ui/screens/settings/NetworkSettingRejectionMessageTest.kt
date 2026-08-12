package com.skybridge.compass.android.ui.screens.settings

import com.skybridge.compass.core.data.NetworkSettingField
import com.skybridge.compass.core.data.NetworkSettingRejection
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test

/**
 * R7.8：呈现给用户的拒绝提示必须**同时包含最小值与最大值**。
 * 这里逐一覆盖四种拒绝原因 × 四个字段。
 */
@DisplayName("Network setting rejection messages carry min and max (R7.8)")
class NetworkSettingRejectionMessageTest {

    private fun assertCarriesBounds(rejection: NetworkSettingRejection) {
        val message = networkSettingRejectionMessage(rejection)
        assertTrue(
            message.contains(rejection.min.toString()),
            "message must contain min ${rejection.min}: $message"
        )
        assertTrue(
            message.contains(rejection.max.toString()),
            "message must contain max ${rejection.max}: $message"
        )
    }

    @Test
    fun `empty rejection carries bounds for every field`() {
        listOf(
            NetworkSettingField.PORT_RANGE_START to (1L to 65535L),
            NetworkSettingField.PORT_RANGE_END to (1L to 65535L),
            NetworkSettingField.DISCOVERY_TIMEOUT_MS to (250L to 120_000L),
            NetworkSettingField.MAX_RECONNECT_ATTEMPTS to (0L to 10L)
        ).forEach { (field, bounds) ->
            assertCarriesBounds(
                NetworkSettingRejection.Empty(field, bounds.first, bounds.second, "")
            )
        }
    }

    @Test
    fun `non-numeric rejection carries bounds`() {
        assertCarriesBounds(
            NetworkSettingRejection.NotNumeric(
                NetworkSettingField.PORT_RANGE_START, 1L, 65535L, "abc"
            )
        )
        assertCarriesBounds(
            NetworkSettingRejection.NotNumeric(
                NetworkSettingField.DISCOVERY_TIMEOUT_MS, 250L, 120_000L, "30s"
            )
        )
    }

    @Test
    fun `out-of-range rejection carries bounds`() {
        assertCarriesBounds(
            NetworkSettingRejection.OutOfRange(
                NetworkSettingField.PORT_RANGE_END, 1L, 65535L, "65536"
            )
        )
        assertCarriesBounds(
            NetworkSettingRejection.OutOfRange(
                NetworkSettingField.MAX_RECONNECT_ATTEMPTS, 0L, 10L, "11"
            )
        )
        assertCarriesBounds(
            NetworkSettingRejection.OutOfRange(
                NetworkSettingField.DISCOVERY_TIMEOUT_MS, 250L, 120_000L, "249"
            )
        )
    }

    @Test
    fun `end-before-start rejection carries bounds and the start value`() {
        val rejection = NetworkSettingRejection.EndBeforeStart(
            start = 9000,
            end = 8080,
            min = 1L,
            max = 65535L
        )
        assertCarriesBounds(rejection)
        assertTrue(networkSettingRejectionMessage(rejection).contains("9000"))
    }

    @Test
    fun `discovery timeout message states the millisecond minimum, not a truncated second`() {
        val message = networkSettingRejectionMessage(
            NetworkSettingRejection.OutOfRange(
                NetworkSettingField.DISCOVERY_TIMEOUT_MS, 250L, 120_000L, "0"
            )
        )
        // 250ms 换算成整数秒会变成 0，从而把下限错报；必须以毫秒呈现。
        assertTrue(message.contains("250"), message)
        assertTrue(message.contains("120000"), message)
    }
}
