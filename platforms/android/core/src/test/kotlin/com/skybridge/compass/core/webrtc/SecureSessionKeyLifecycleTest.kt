package com.skybridge.compass.core.webrtc

import com.skybridge.compass.shared.p2p.P2PHandshakeWire
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 会话密钥生命周期纯逻辑单测（任务 9.9 / R4.9）。
 *
 * 无需实时 WebRTC 传输即可锁定：主动断开时对密钥材料做置零擦除，而非仅置空引用（R4.9）。
 * 密钥更新连续性（R4.8）的状态迁移契约由 [SecureSessionKeyLifecycleWiringTest] 源级锁定。
 */
class SecureSessionKeyLifecycleTest {

    @Test
    fun wipeKeyMaterialZeroizesAllSecretBytes() {
        val sendKey = ByteArray(32) { (it + 1).toByte() }
        val receiveKey = ByteArray(32) { (it + 33).toByte() }
        val transcriptHash = ByteArray(32) { (it + 65).toByte() }
        val keys = P2PHandshakeWire.DerivedSessionKeys(
            sendKey = sendKey,
            receiveKey = receiveKey,
            transcriptHash = transcriptHash
        )

        SecureSessionKeyLifecycle.wipeKeyMaterial(keys)

        assertTrue("sendKey must be zeroized", sendKey.all { it == 0.toByte() })
        assertTrue("receiveKey must be zeroized", receiveKey.all { it == 0.toByte() })
        assertTrue("transcriptHash must be zeroized", transcriptHash.all { it == 0.toByte() })
    }

    @Test
    fun wipeKeyMaterialIsNullSafe() {
        // 无密钥可擦除时（会话尚未建立即断开）不得抛异常。
        SecureSessionKeyLifecycle.wipeKeyMaterial(null)
    }
}
