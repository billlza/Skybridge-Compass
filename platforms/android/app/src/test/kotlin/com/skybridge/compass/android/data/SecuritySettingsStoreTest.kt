package com.skybridge.compass.android.data

import com.skybridge.compass.shared.p2p.P2PQPeriaptKem
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class SecuritySettingsStoreTest {
    @Test
    fun normalizePqcMinimumTierAcceptsKnownProductionTiers() {
        assertEquals("nativePQC", normalizePqcMinimumTier("nativePQC", qPeriaptSupported = false))
        assertEquals("liboqsPQC", normalizePqcMinimumTier("liboqsPQC", qPeriaptSupported = false))
        assertEquals("classic", normalizePqcMinimumTier("classic", qPeriaptSupported = false))
    }

    @Test
    fun normalizePqcMinimumTierRequiresSupportedLocalPlatformForQPeriapt() {
        assertEquals(
            P2PQPeriaptKem.MINIMUM_TIER_RAW,
            normalizePqcMinimumTier(P2PQPeriaptKem.MINIMUM_TIER_RAW, qPeriaptSupported = true)
        )

        assertThrows(IllegalArgumentException::class.java) {
            normalizePqcMinimumTier(P2PQPeriaptKem.MINIMUM_TIER_RAW, qPeriaptSupported = false)
        }
    }

    @Test
    fun normalizePqcMinimumTierRejectsUnknownTier() {
        assertThrows(IllegalArgumentException::class.java) {
            normalizePqcMinimumTier("futureWeakTier", qPeriaptSupported = true)
        }
    }

    @Test
    fun readStoredPqcMinimumTierFallsBackInsteadOfThrowing() {
        // 任务 15.7 / R7.9 行为更正。
        //
        // 本测试此前断言读取面在两种情形下**抛出** IllegalArgumentException：
        //   ① 持久化值为 q-periapt 而本机不支持；② 无法识别的等级字符串。
        // 那正是 R7.9 的缺陷所在，不是要保护的契约：读取发生在 `observe()` 的 `map` 内，
        // 抛出会摧毁整个 security settings 流（不止这一项），而 R7.9 要求的是该项取值
        // **不参与运行时判定**。且该路径可达——云端设置同步会把新机器保存的值下发到旧机器。
        //
        // 因此断言改为「回落而非抛出」。写入面的严格性未被放宽，见下方
        // writePathStillRejectsValuesFailingThePlatformPrerequisite。
        assertEquals("nativePQC", readStoredPqcMinimumTier(null, qPeriaptSupported = false))
        assertEquals("nativePQC", readStoredPqcMinimumTier("nativePQC", qPeriaptSupported = false))

        // ① 平台前提不满足：回落到平台可支持的默认值，且不是 classic（不静默降级安全性）。
        assertEquals(
            "nativePQC",
            readStoredPqcMinimumTier(P2PQPeriaptKem.MINIMUM_TIER_RAW, qPeriaptSupported = false)
        )
        // 平台前提满足时该值照常生效。
        assertEquals(
            P2PQPeriaptKem.MINIMUM_TIER_RAW,
            readStoredPqcMinimumTier(P2PQPeriaptKem.MINIMUM_TIER_RAW, qPeriaptSupported = true)
        )

        // ② 前向/未知取值：同样回落，旧版本不因未来写入的值而崩溃。
        assertEquals("nativePQC", readStoredPqcMinimumTier("futureWeakTier", qPeriaptSupported = true))
    }

    /** 回落只在读取面；写入面仍必须拒绝不满足平台前提的取值，否则回落会变成绕过前提的通道。 */
    @Test
    fun writePathStillRejectsValuesFailingThePlatformPrerequisite() {
        assertThrows(IllegalArgumentException::class.java) {
            normalizePqcMinimumTier(P2PQPeriaptKem.MINIMUM_TIER_RAW, qPeriaptSupported = false)
        }
        assertThrows(IllegalArgumentException::class.java) {
            normalizePqcMinimumTier("futureWeakTier", qPeriaptSupported = true)
        }
    }

    /** R7.9 判定谓词：仅当「值为 q-periapt 且本机不支持」时该项取值不参与运行时判定。 */
    @Test
    fun platformGatingPredicateMatchesTheFallbackCondition() {
        assertTrue(
            pqcMinimumTierIsGatedByPlatform(P2PQPeriaptKem.MINIMUM_TIER_RAW, qPeriaptSupported = false)
        )
        assertFalse(
            pqcMinimumTierIsGatedByPlatform(P2PQPeriaptKem.MINIMUM_TIER_RAW, qPeriaptSupported = true)
        )
        assertFalse(pqcMinimumTierIsGatedByPlatform("nativePQC", qPeriaptSupported = false))
        assertFalse(pqcMinimumTierIsGatedByPlatform(null, qPeriaptSupported = false))
    }

    /** 被门控时，读取面给出的生效值与「该项从未被设置」完全一致——即其持久化值确实不参与判定。 */
    @Test
    fun gatedValueBehavesExactlyAsIfNeverSet() {
        val asIfUnset = readStoredPqcMinimumTier(null, qPeriaptSupported = false)
        val gated = readStoredPqcMinimumTier(
            P2PQPeriaptKem.MINIMUM_TIER_RAW,
            qPeriaptSupported = false
        )
        assertEquals(asIfUnset, gated)
    }
}
