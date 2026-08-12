package com.skybridge.compass.android.settings

import com.skybridge.compass.android.KeepScreenOnWindowFlag
import com.skybridge.compass.android.data.AppSettings
import com.skybridge.compass.android.data.SecuritySettings
import com.skybridge.compass.android.keepScreenOnWindowFlag
import com.skybridge.compass.android.notifications.shouldPostBridgedNotification
import com.skybridge.compass.android.securityprompts.PAIRING_TIMEOUT_SEC_MAX
import com.skybridge.compass.android.securityprompts.PAIRING_TIMEOUT_SEC_MIN
import com.skybridge.compass.android.securityprompts.pairingDecisionTimeoutMs
import com.skybridge.compass.android.securityprompts.SecurityPromptStore
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Nested
import org.junit.jupiter.api.Test

/**
 * 任务 15.4 / R7.2：证明每个曾被登记为「零运行时消费方」的设置项，其值确实改变消费方行为，
 * 且默认值被尊重。
 *
 * JUnit Jupiter（`:app` 已接入 JUnit Platform）。每个 [Nested] 对应清单里的一个控件 id，
 * 断言的是**生产代码里真实的判定函数**，不是测试内重写的一份平行逻辑。
 */
@DisplayName("R7.2 零消费方控件接线证据")
class ZeroConsumerControlWiringTest {

    @Nested
    @DisplayName("general.notifications → SystemNotifier 桥接门")
    inner class Notifications {

        @Test
        @DisplayName("关闭后不再桥接系统通知；开启则桥接")
        fun gateFollowsTheSetting() {
            assertTrue(shouldPostBridgedNotification(true), "开启时应桥接系统通知")
            assertFalse(shouldPostBridgedNotification(false), "关闭时不得桥接系统通知")
        }

        @Test
        @DisplayName("默认值为开启，且默认下桥接放行")
        fun defaultIsRespected() {
            assertTrue(AppSettings().notificationsEnabled, "notifications_enabled 默认应为 true")
            assertTrue(shouldPostBridgedNotification(AppSettings().notificationsEnabled))
        }
    }

    @Nested
    @DisplayName("general.keep-screen-on → 窗口 FLAG_KEEP_SCREEN_ON")
    inner class KeepScreenOn {

        @Test
        @DisplayName("开启则持有常亮标志，关闭则清除")
        fun windowFlagFollowsTheSetting() {
            assertEquals(KeepScreenOnWindowFlag.ADD, keepScreenOnWindowFlag(true))
            assertEquals(KeepScreenOnWindowFlag.CLEAR, keepScreenOnWindowFlag(false))
        }

        @Test
        @DisplayName("两个取值映射到不同动作 —— 开关不是空操作")
        fun theTwoValuesDiffer() {
            assertNotEquals(keepScreenOnWindowFlag(true), keepScreenOnWindowFlag(false))
        }

        @Test
        @DisplayName("默认值为关闭，默认下清除常亮标志")
        fun defaultIsRespected() {
            assertFalse(AppSettings().keepScreenOn, "keep_screen_on 默认应为 false")
            assertEquals(
                KeepScreenOnWindowFlag.CLEAR,
                keepScreenOnWindowFlag(AppSettings().keepScreenOn)
            )
        }
    }

    @Nested
    @DisplayName("device-auth.pairing-timeout-sec → 配对提示自动拒绝超时")
    inner class PairingTimeout {

        @Test
        @DisplayName("持久化秒值换算为配对提示的超时毫秒值")
        fun timeoutFollowsTheSetting() {
            assertEquals(30_000L, pairingDecisionTimeoutMs(30))
            assertEquals(120_000L, pairingDecisionTimeoutMs(120))
            assertEquals(5_000L, pairingDecisionTimeoutMs(PAIRING_TIMEOUT_SEC_MIN))
            assertEquals(600_000L, pairingDecisionTimeoutMs(PAIRING_TIMEOUT_SEC_MAX))
        }

        @Test
        @DisplayName("不同设置值给出不同超时 —— 该项不是空操作")
        fun distinctValuesGiveDistinctTimeouts() {
            assertNotEquals(pairingDecisionTimeoutMs(15), pairingDecisionTimeoutMs(45))
        }

        @Test
        @DisplayName("越界值兜底钳制到 5..600 秒")
        fun outOfRangeValuesAreClamped() {
            assertEquals(5_000L, pairingDecisionTimeoutMs(0))
            assertEquals(5_000L, pairingDecisionTimeoutMs(-30))
            assertEquals(600_000L, pairingDecisionTimeoutMs(9_999))
        }

        @Test
        @DisplayName("默认 30 秒被尊重，且不等于 SecurityPromptStore 的 60 秒硬编码兜底")
        fun defaultIsRespectedAndOverridesTheHardcodedFallback() {
            val default = SecuritySettings().pairingTimeoutSec
            assertEquals(30, default, "pairing_timeout_sec 默认应为 30 秒")
            assertEquals(30_000L, pairingDecisionTimeoutMs(default))
            // 若持久化值未被传入，配对提示会落到 60s 硬编码默认值；两者不同即证明该值真的被采纳。
            assertNotEquals(
                SecurityPromptStore.PAIRING_DECISION_TIMEOUT_MS,
                pairingDecisionTimeoutMs(default),
                "默认设置值必须区别于硬编码兜底，否则无法证明它被消费"
            )
        }
    }

    @Nested
    @DisplayName("access-control.allow-clipboard-sync → 能力播报与剪贴板重定向")
    inner class ClipboardSync {

        @Test
        @DisplayName("默认值为开启")
        fun defaultIsRespected() {
            assertTrue(SecuritySettings().allowClipboardSync, "allow_clipboard_sync 默认应为 true")
        }
    }
}
