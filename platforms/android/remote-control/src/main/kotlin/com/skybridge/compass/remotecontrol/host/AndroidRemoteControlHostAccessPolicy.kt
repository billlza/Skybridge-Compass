package com.skybridge.compass.remotecontrol.host

/**
 * State of the MediaProjection screen-record authorization for the host capture session.
 */
enum class HostAuthorizationState {
    /** User explicitly granted screen recording and a valid projection result is available. */
    GRANTED,

    /** User denied the authorization prompt (or no valid projection result was provided). */
    DENIED,

    /** A previously-granted authorization was revoked at runtime (projection onStop callback). */
    REVOKED,
}

/**
 * Decision for whether/how to start a host capture session, given the authorization state.
 *
 * @param startCapture whether the foreground service + capture pipeline should start.
 * @param presentMissingAuthorizationNotice whether to surface the "authorization missing" UI (R6.12).
 * @param keepViewingSessionUsable whether the remote-desktop *viewing* session must remain usable.
 */
data class HostStartDecision(
    val startCapture: Boolean,
    val presentMissingAuthorizationNotice: Boolean,
    val keepViewingSessionUsable: Boolean,
)

/**
 * Decision for tearing down a host capture session.
 *
 * @param stopCapture whether to stop the encoder + virtual display capture.
 * @param stopForegroundService whether to stop the foreground service.
 * @param removeNotification whether to remove the persistent capture notification.
 * @param sendSessionEndNotice whether to emit a session-end notice to the peer.
 * @param sessionEndReason the reason carried on that notice (null when no notice is sent).
 * @param presentMissingAuthorizationNotice whether to surface the "authorization missing" UI.
 * @param keepViewingSessionUsable whether the viewing session must remain usable after teardown.
 */
data class HostStopDecision(
    val stopCapture: Boolean,
    val stopForegroundService: Boolean,
    val removeNotification: Boolean,
    val sendSessionEndNotice: Boolean,
    val sessionEndReason: HostSessionEndReason?,
    val presentMissingAuthorizationNotice: Boolean,
    val keepViewingSessionUsable: Boolean,
)

/**
 * Pure, framework-free authorization + lifecycle decision logic for the host capture service.
 *
 * Encodes the R6.5/R6.6/R6.12 rules so they can be unit-tested without a real MediaProjection or a
 * running Service:
 *  - Start only when authorization is GRANTED; when DENIED/REVOKED do not start, present a missing-
 *    authorization notice, and keep the viewing session usable.
 *  - Every teardown path stops capture, stops the service, and removes the notification.
 *  - A normal/explicit stop and a revoked/error stop each emit a session-end notice to the peer.
 */
object AndroidRemoteControlHostAccessPolicy {

    /** Decide whether to start capture given the current authorization state. */
    fun decideStart(state: HostAuthorizationState): HostStartDecision = when (state) {
        HostAuthorizationState.GRANTED -> HostStartDecision(
            startCapture = true,
            presentMissingAuthorizationNotice = false,
            keepViewingSessionUsable = true,
        )
        HostAuthorizationState.DENIED,
        HostAuthorizationState.REVOKED -> HostStartDecision(
            startCapture = false,
            presentMissingAuthorizationNotice = true,
            keepViewingSessionUsable = true,
        )
    }

    /**
     * Decide teardown when the user (or the guarded stop-hook) explicitly stops sharing (R6.6):
     * stop capture, stop service, remove notification, and send a session-end notice.
     */
    fun decideUserStop(): HostStopDecision = HostStopDecision(
        stopCapture = true,
        stopForegroundService = true,
        removeNotification = true,
        sendSessionEndNotice = true,
        sessionEndReason = HostSessionEndReason.USER_STOPPED,
        presentMissingAuthorizationNotice = false,
        keepViewingSessionUsable = true,
    )

    /**
     * Decide teardown when authorization is denied/revoked while (or before) capturing (R6.12):
     * stop everything, present the missing-authorization notice, send a session-end notice, and
     * keep the viewing session usable.
     */
    fun decideAuthorizationLost(wasCapturing: Boolean): HostStopDecision = HostStopDecision(
        stopCapture = wasCapturing,
        stopForegroundService = true,
        removeNotification = true,
        sendSessionEndNotice = wasCapturing,
        sessionEndReason = if (wasCapturing) HostSessionEndReason.AUTHORIZATION_REVOKED else null,
        presentMissingAuthorizationNotice = true,
        keepViewingSessionUsable = true,
    )

    /**
     * Decide teardown when the overall remote-desktop session ends/disconnects (R6.9): stop the
     * still-running capture, stop the service, remove the notification, and notify the peer.
     */
    fun decideSessionEnded(): HostStopDecision = HostStopDecision(
        stopCapture = true,
        stopForegroundService = true,
        removeNotification = true,
        sendSessionEndNotice = true,
        sessionEndReason = HostSessionEndReason.SESSION_ENDED,
        presentMissingAuthorizationNotice = false,
        keepViewingSessionUsable = true,
    )
}
