package com.skybridge.compass.android.webrtc

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Wire-compatible with Pro release `WebRTCSignalingEnvelope`.
 * Transport: WebSocket JSON text frames.
 */
@Serializable
data class WebRtcSignalingEnvelope(
    val sessionId: String,
    val from: String,
    val to: String? = null,
    val type: MessageType,
    val payload: Payload? = null,
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
        val sdpMLineIndex: Int? = null
    )
}


