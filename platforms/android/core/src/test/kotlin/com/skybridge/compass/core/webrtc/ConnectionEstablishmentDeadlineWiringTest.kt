package com.skybridge.compass.core.webrtc

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * 源级接线契约（任务 9.7 / R4.1、R4.2）。
 *
 * 这些断言锁定 [SkyBridgeWebRtcConnectionManager] 里整体建立时限的接线，使其不会在后续重构中
 * 被悄悄摘除；它们与 [SignalServerClientContractTest] 既有的「established 仅在安全会话完成后」
 * 断言互补，且不削弱后者。
 */
class ConnectionEstablishmentDeadlineWiringTest {

    @Test
    fun overallEstablishmentDeadlineIsArmedAtSessionStartAndCancelledOnEstablished() {
        val source = managerSource()

        // 时限门被注入构造函数，默认 30s（可注入时钟以便测试）。
        assertTrue(
            "manager must depend on ConnectionEstablishmentDeadline",
            source.contains("establishmentDeadline: ConnectionEstablishmentDeadline")
        )

        // 会话起点（用户选择设备后）武装整体时限。
        assertTrue(
            "deadline must be armed at session start",
            source.contains("armEstablishmentDeadline(owner)")
        )
        assertTrue(source.contains("private fun armEstablishmentDeadline(owner: ProductSessionOwner)"))
        assertTrue(source.contains("if (!sessionOwnerGate.isCurrent(owner)) return@launch"))
        assertTrue(source.contains("establishmentDeadline.start()"))

        // 到期评估以「应用层会话密钥是否已建立」为准（R4.2）。
        assertTrue(
            source.contains("establishmentDeadline.evaluateOnDeadline(")
        )
        assertTrue(source.contains("appLayerSessionKeysEstablished = hasSessionKeys()"))

        // 会话呈现为已建立后停用时限。
        assertTrue(
            "deadline must be cancelled once the session is established",
            source.contains("cancelEstablishmentDeadline()")
        )
    }

    @Test
    fun deadlineExpiryFailsTruthfullyWithTimeoutCategoryAndReleasesResources() {
        val source = managerSource()

        assertTrue(
            "expiry handler must exist",
            source.contains("private fun onEstablishmentDeadlineExpired(")
        )
        // 迟到迁移不得改写已建立 / 已失败的终态。
        assertTrue(source.contains("if (current is State.Established || current is State.Failed) return"))
        // 如实以「超时」失败并经既有 signaling-status 叶节点呈现（不新增屏幕，G2）。
        assertTrue(source.contains("failCurrentSession(\n            owner,"))
        assertTrue(source.contains("signalingEventPrefix = \"establishment timeout\""))
        // 释放本次尝试已分配的连接资源。
        assertTrue(source.contains("productSessionAuthorityStore?.markFailed(owner)"))
        assertTrue(source.contains("sessionOwnerGate.releaseIfCurrent(owner)"))
    }

    @Test
    fun establishedPromotionStillGatedOnSecureSessionCompletion() {
        val source = managerSource()

        // R4.2 不变式（与既有契约互补、不削弱）：仅握手完成派生会话密钥后才 State.Established。
        assertTrue(source.contains("sessionKeys = keys"))
        assertTrue(source.contains("_state.value = State.Established(sessionCode)"))
        assertTrue(source.contains("val shouldEstablish = when (phase)"))
        assertTrue(source.contains("HandshakePhase.INITIAL -> current is State.Connected"))
        // send() 在会话密钥建立前拒绝承载应用负载（引导通道不承载业务流量）。
        assertTrue(source.contains("reject app send before secure session"))
    }

    private fun managerSource(): String {
        val sourceFile = listOf(
            File("core/src/main/kotlin/com/skybridge/compass/core/webrtc/SkyBridgeWebRtcConnectionManager.kt"),
            File("src/main/kotlin/com/skybridge/compass/core/webrtc/SkyBridgeWebRtcConnectionManager.kt")
        ).firstOrNull { it.isFile }
            ?: error("SkyBridgeWebRtcConnectionManager source file not found from cwd=${File(".").absolutePath}")
        return sourceFile.readText()
    }
}
