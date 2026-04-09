package com.skybridge.compass.core.webrtc

/**
 * Mirrors Pro release `SkyBridgeServerConfig` for WebRTC cross-network signaling/ICE.
 * Signaling follows the same public TLS entrypoint as Apple builds.
 * STUN/TURN stay on the direct relay IP because UDP relay traffic does not traverse Cloudflare.
 */
object SkyBridgeServerConfig {
    const val signalingServerURL: String = "https://api.nebula-technologies.net"
    const val signalingWebSocketURL: String = "wss://api.nebula-technologies.net/ws"

    const val stunServerHost: String = "54.92.79.99"
    const val stunServerPort: Int = 3478

    const val turnServerHost: String = "54.92.79.99"
    const val turnServerPort: Int = 3478
    const val turnTlsServerPort: Int = 5349

    val stunURL: String get() = "stun:$stunServerHost:$stunServerPort"
    val turnURL: String get() = "turn:$turnServerHost:$turnServerPort?transport=udp"
    val turnTLSURL: String get() = "turns:$turnServerHost:$turnTlsServerPort?transport=tcp"
    val turnURLs: List<String> get() = listOf(turnTLSURL, turnURL)
    val defaultStunServers: List<String> get() = listOf(
        stunURL,
        "stun:stun.l.google.com:19302",
        "stun:stun1.l.google.com:19302"
    )
    val defaultTurnServers: List<String> get() = turnURLs

    /**
     * Pro release uses a public client API key for TURN credential requests (not a secret).
     */
    const val clientApiKey: String = "skybridge-client-v1"

    fun turnCredentialEndpoint(): String = "$signalingServerURL/api/turn/credentials"
}
