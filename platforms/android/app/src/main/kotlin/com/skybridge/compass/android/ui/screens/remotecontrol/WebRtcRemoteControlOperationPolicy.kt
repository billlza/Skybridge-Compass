package com.skybridge.compass.android.ui.screens.remotecontrol

import com.skybridge.compass.core.webrtc.WebRtcSecureOperationOwner

/** Pure stale-callback policy for one exact remote-control secure operation. */
internal object WebRtcRemoteControlPacketAdmissionPolicy {
    enum class Decision {
        HANDLE,
        IGNORE_STALE_OWNER
    }

    fun decide(
        expectedOwner: WebRtcSecureOperationOwner?,
        callbackOwner: WebRtcSecureOperationOwner,
        callbackOwnerIsCurrent: Boolean
    ): Decision = when {
        expectedOwner !== callbackOwner -> Decision.IGNORE_STALE_OWNER
        // A callback capability that is no longer current belongs to an old key epoch. The
        // authoritative transport may already have installed a replacement while the UI's owner
        // StateFlow collector is still queued, so this must never be promoted into a terminal
        // failure for whichever epoch is current now.
        !callbackOwnerIsCurrent -> Decision.IGNORE_STALE_OWNER
        else -> Decision.HANDLE
    }
}

/**
 * Chooses the no-frame watchdog baseline without treating an acknowledgement as a frame.
 * A retained admitted-frame timestamp always wins; otherwise the first ACK starts the initial
 * no-frame window and later reconnect ACKs preserve that original baseline.
 */
internal object WebRtcRemoteControlWatchdogBaselinePolicy {
    fun recordAcknowledgement(
        existingAcknowledgedAtMs: Long?,
        acceptedAtMs: Long
    ): Long {
        require(acceptedAtMs >= 0) { "acknowledgement time is negative" }
        return existingAcknowledgedAtMs ?: acceptedAtMs
    }

    fun baseline(
        lastAdmittedFrameAtMs: Long,
        acknowledgedAtMs: Long?
    ): Long? = lastAdmittedFrameAtMs.takeIf { it > 0L } ?: acknowledgedAtMs
}
