package com.skybridge.compass.core.webrtc

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * 源级接线契约（任务 9.9 / R4.8、R4.9）。
 *
 * 锁定 [SkyBridgeWebRtcConnectionManager] 里密钥更新连续性与主动断开清理的接线，使其不会在
 * 后续重构中被悄悄摘除；与 [ConnectionEstablishmentDeadlineWiringTest]、
 * [SignalServerClientContractTest] 既有断言互补，且不削弱后者。
 */
class SecureSessionKeyLifecycleWiringTest {

    @Test
    fun rekeyContinuityKeepsSessionEstablishedWithoutDroppingData() {
        val source = managerSource()

        // REKEY 阶段在 Connected 或 Established 下都保持会话为已建立（R4.8 连续性）——
        // 一次成功的密钥更新以新密钥继续，不撕毁已建立会话。
        assertTrue(
            "rekey must keep an established session established",
            source.contains("HandshakePhase.REKEY -> current is State.Connected || current is State.Established")
        )
        // rekey 成功仍以新密钥继续并呈现为已建立（不撕毁会话、不丢已确认数据）。
        assertTrue(source.contains("sessionKeys = keys"))
        assertTrue(source.contains("_state.value = State.Established(sessionCode)"))
        // rekey 分支只清 in-progress 标志，不关 DataChannel、不丢数据。
        assertTrue(source.contains("if (phase == HandshakePhase.REKEY) {"))
        assertTrue(source.contains("rekeyInProgress = false"))
    }

    @Test
    fun newKeysRestartOutboundEnvelopeCounter() {
        val source = managerSource()

        // 换用新会话密钥后出站信封计数器从头重新计数，对齐对端针对新密钥的重放泳道（R4.8）。
        assertTrue(source.contains("resetSecureEnvelopeState()"))
        // 计数器从 0 起，下一帧自增为 1（SBWC 拒绝 0）。
        assertTrue(source.contains("webrtcSecureEnvelopeSendCounter = 0L"))
        assertTrue(source.contains("webrtcSecureEnvelopeSendCounter += 1"))
        // rekey 「以新密钥继续」路径不擦除仍在服务中的旧密钥（避免破坏在途发送）。
        assertTrue(
            "rekey continuation must not wipe in-service keys",
            source.contains("REKEY 阶段不擦除")
        )
    }

    @Test
    fun activeDisconnectStopsIoAndZeroizesKeyMaterial() {
        val source = managerSource()

        // 主动断开入口：disconnect() 触发 resetConnection（重建信令 = true），停止收发并清理。
        assertTrue(source.contains("fun disconnect() {"))
        assertTrue(source.contains("resetConnection(recreateSignaling = true)"))
        // 停止 I/O：全部尝试关闭会话（含 DataChannel）与信令，且聚合任一清理失败；
        // 主动断开不得把未释放的原生资源静默呈现为成功。
        assertTrue(source.contains("closingSession?.let { cleanup.merge(\"session\", it.close()) }"))
        assertTrue(source.contains("cleanup.merge(\"signaling\", closingSignaling.close())"))
        assertTrue(source.contains("if (!cleanup.isSuccessful) {"))
        assertTrue(source.contains("throw cleanup.asException(\"WebRTC connection reset\")"))
        // 清理状态并置零擦除内存密钥材料，而非仅置空引用（R4.9）。
        assertTrue(source.contains("clearConnectionState(owner)"))
        assertTrue(
            "disconnect cleanup must zeroize key material, not just null the reference",
            source.contains("SecureSessionKeyLifecycle.wipeKeyMaterial(sessionKeys)")
        )
        // 清空会话/对端标识并呈现已断开（回到 Idle）。
        assertTrue(source.contains("currentSessionId = null"))
        assertTrue(source.contains("remoteSignalingId = null"))
        assertTrue(source.contains("remoteDeviceId = null"))
        assertTrue(source.contains("_state.value = State.Idle"))
    }

    @Test
    fun keyMaterialIsZeroizedOnEverySessionTeardownPath() {
        val source = managerSource()

        // 主动断开 / 会话失败清理 / 新会话起点替换旧会话三条拆解路径都要置零擦除密钥材料。
        val needle = "SecureSessionKeyLifecycle.wipeKeyMaterial(sessionKeys)"
        val wipeCount = source.split(needle).size - 1
        assertTrue(
            "key material must be zeroized on all teardown paths (found $wipeCount)",
            wipeCount >= 3
        )
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
