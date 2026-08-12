package com.skybridge.compass.core.webrtc

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Wire-compatible with Pro release `WebRTCSignalingEnvelope`.
 * Transport: WebSocket text frames (JSON).
 */
@Serializable
data class WebRtcSignalingEnvelope(
    val sessionId: String,
    val from: String,
    val to: String? = null,
    val type: MessageType,
    val payload: Payload? = null,
    val authToken: String? = null,
    val sentAt: Double
) {
    @Serializable
    enum class MessageType {
        @SerialName("join")
        JOIN,
        @SerialName("offer")
        OFFER,
        @SerialName("answer")
        ANSWER,
        @SerialName("iceCandidate")
        ICE_CANDIDATE,
        @SerialName("leave")
        LEAVE
    }

    @Serializable
    data class Payload(
        val sdp: String? = null,
        val candidate: String? = null,
        val sdpMid: String? = null,
        val sdpMLineIndex: Int? = null,
        // Strict-PQC JOIN bootstrap: the macOS/iOS host advertises its KEM public keys in the
        // signaling JOIN so a strict-PQC peer can offer PQC directly in its INITIAL. Q-Periapt
        // bootstrap additionally requires explicit peer platform metadata before the key is cached.
        val protocolSigningAlgorithm: ProtocolSigningAlgorithm? = null,
        val protocolPublicKeyFingerprint: String? = null,
        val protocolPublicKeyBytes: String? = null,
        val kemPublicKeys: List<BootstrapKemPublicKey>? = null,
        val platform: String? = null,
        val osVersion: String? = null
    ) {
        @Serializable
        data class BootstrapKemPublicKey(
            val suiteWireId: Int,
            val publicKey: String
        )
    }
}
