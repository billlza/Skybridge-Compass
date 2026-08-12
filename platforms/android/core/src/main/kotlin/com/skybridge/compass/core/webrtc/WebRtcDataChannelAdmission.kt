package com.skybridge.compass.core.webrtc

/** Single admission policy for the application DataChannel owned by one WebRTC session. */
internal object WebRtcDataChannelAdmission {
    const val EXPECTED_LABEL = "skybridge"

    enum class Result {
        ACCEPT,
        REJECT_CLOSED_SESSION,
        REJECT_WRONG_LABEL,
        REJECT_DUPLICATE
    }

    fun evaluate(
        label: String,
        hasActiveChannel: Boolean,
        sessionClosed: Boolean
    ): Result = when {
        sessionClosed -> Result.REJECT_CLOSED_SESSION
        label != EXPECTED_LABEL -> Result.REJECT_WRONG_LABEL
        hasActiveChannel -> Result.REJECT_DUPLICATE
        else -> Result.ACCEPT
    }
}
