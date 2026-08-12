package com.skybridge.compass.core.webrtc

import com.skybridge.compass.shared.p2p.P2PHandshakeWire

/**
 * 会话密钥生命周期的可测纯逻辑（任务 9.9 / R4.9），从 [SkyBridgeWebRtcConnectionManager]
 * 抽出，使主动断开时的密钥材料清理可在无实时 WebRTC 传输的情况下单元测试；抽出方式与任务
 * 9.2/9.7 注入的 [ConnectionEstablishmentDeadline] 缝隙一致。
 *
 * **主动断开清理（R4.9）**：主动断开时对内存中的会话密钥材料做置零擦除，而非仅置空引用。
 * [wipeKeyMaterial] 就地把 `sendKey` / `receiveKey` / `transcriptHash` 字节数组填零，随后调用方
 * 再把引用置空并关闭全部 DataChannel、释放信令与 ICE。
 *
 * 密钥更新连续性（R4.8）由 [SkyBridgeWebRtcConnectionManager.onHandshakeEstablished] 内联实现：
 * REKEY 阶段在 Connected/Established 下都保持会话为已建立、以新密钥继续、不丢已确认数据，出站
 * 信封计数器针对新密钥从头重新计数（对端亦如此）。rekey 的「以新密钥继续」路径**不**调用
 * [wipeKeyMaterial]——仍在服务中的密钥不能擦除，否则会破坏在途发送。
 */
internal object SecureSessionKeyLifecycle {

    /**
     * 就地置零擦除会话密钥材料（R4.9 主动断开清理）。把敏感字节数组填 0，使其在被引用置空、
     * 等待 GC 回收前不再以明文形态驻留内存；对 `null` 安全（无密钥可擦除时直接返回）。
     *
     * 仅在会话拆解路径调用（主动断开 / 会话失败清理 / 新会话起点替换旧会话），不在 rekey 的
     * 「以新密钥继续」路径调用。
     */
    fun wipeKeyMaterial(keys: P2PHandshakeWire.DerivedSessionKeys?) {
        if (keys == null) return
        keys.sendKey.fill(0)
        keys.receiveKey.fill(0)
        keys.transcriptHash.fill(0)
    }
}
