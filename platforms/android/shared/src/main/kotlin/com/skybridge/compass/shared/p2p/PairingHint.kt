package com.skybridge.compass.shared.p2p

/**
 * An actionable pairing hint surfaced when a session cannot be established because the
 * peer's KEM public key is unobtainable (task 9.3, acceptance criterion **R4.11**).
 *
 * > IF 对端 KEM 公钥既不存在于本地配对记录，也无法通过第 2 条的一次性经典控制通道在
 * > 10 秒内获取，THEN THE Connection_Subsystem SHALL 拒绝建立会话、把失败原因分类记为
 * > 「对端 KEM 公钥不可得」，并向用户呈现可执行的配对提示，且不以经典套件承载业务流量。
 *
 * ### Layering (G2)
 * This is a pure **domain/result-layer** value: it carries the machine-selected reason
 * and the ordered, human-actionable [steps] the user can take to pair, but it holds
 * **no UI**. If the UI renders it, it must do so as a *leaf node* inside an existing
 * `GroupedGlassSection` / `GroupedGlassRow` (G2) — this type never dictates layout,
 * navigation, or structure. Keeping the hint here means the connection layer decides
 * *what* to tell the user while the UI decides only *how* to draw it.
 *
 * The hint is deliberately transport- and locale-agnostic: [steps] are stable, ordered
 * action keys/messages the presentation layer renders; they never carry secrets,
 * connection codes, or device fingerprints (those are redaction-controlled elsewhere).
 */
data class PairingHint(
    /** The machine-readable reason this hint was produced. */
    val reason: PairingHintReason,
    /**
     * Ordered, user-actionable steps to establish pairing so a future connection can
     * obtain the peer KEM public key. Non-empty and non-blank by construction: an
     * "actionable" hint with no actions would not satisfy R4.11.
     */
    val steps: List<String>
) {
    init {
        require(steps.isNotEmpty()) { "an actionable pairing hint must contain at least one step" }
        require(steps.all { it.isNotBlank() }) { "pairing hint steps must be non-blank" }
    }

    companion object {
        /**
         * The canonical actionable hint for an unobtainable peer KEM public key
         * (R4.11). The steps tell the user how to bring the two devices into a state
         * where the KEM public key can be exchanged: bring the devices together on the
         * same network and initiate pairing on the Apple device.
         */
        fun peerKemPublicKeyUnavailable(): PairingHint = PairingHint(
            reason = PairingHintReason.PEER_KEM_PUBLIC_KEY_UNAVAILABLE,
            steps = listOf(
                "将两台设备靠近并接入同一本地网络。",
                "在 Apple 设备（Mac / iPhone）上打开 SkyBridge 并发起配对。",
                "配对建立后返回本机，重新选择该设备发起连接。"
            )
        )
    }
}

/** The machine-readable reason a [PairingHint] was produced. */
enum class PairingHintReason {
    /**
     * R4.11 — the peer's KEM public key was neither in the local pairing record nor
     * obtainable via the one-time classic bootstrap control channel within the
     * acquisition deadline, so no session may be established.
     */
    PEER_KEM_PUBLIC_KEY_UNAVAILABLE
}
