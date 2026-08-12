package com.skybridge.compass.core.webrtc

/**
 * Pure, Android-free no-frame watchdog policy for the remote-desktop viewer (Requirement 6.13).
 *
 * R6.13: while a remote-desktop session is established, if no video frame is received for 5 seconds
 * the viewer SHALL:
 *  - present a "picture interrupted" notice,
 *  - RETAIN the last frame on screen (do not clear it),
 *  - attempt AT MOST 1 reconnect, and
 *  - if still no new frame arrives within 10 seconds of the interruption, END the session and run
 *    disconnect cleanup (R6.9).
 *
 * This object holds no Android dependencies and no clock of its own: callers pass in the current
 * time and the relevant timestamps so the decision is fully deterministic and unit-testable with an
 * injected clock. Both viewer paths (the WebRTC path in `RemoteControlViewModel` and the LAN path in
 * `MacRemoteControlClient`) route their watchdog decision through [decide].
 */
object RemoteFrameWatchdogPolicy {
    /** No frame for this long (ms) while established → present interrupted notice (R6.13). */
    const val NO_FRAME_INTERRUPT_MS: Long = 5_000

    /** Still no frame this long (ms) after the interruption began → end the session (R6.13). */
    const val SESSION_END_AFTER_INTERRUPT_MS: Long = 10_000

    /** At most this many reconnect attempts per interruption (R6.13). */
    const val MAX_RECONNECTS: Int = 1

    /**
     * Watchdog decision for a single evaluation tick. Exactly one is returned per [decide] call.
     */
    sealed interface Decision {
        /** Frames are flowing (or flowing again); no action. Clears any active interruption. */
        data object Healthy : Decision

        /**
         * The stream just crossed the no-frame threshold: present the interrupted notice and retain
         * the last frame. Emitted on the tick that first detects the 5s gap (before an interruption
         * has been recorded).
         */
        data object ShowInterrupted : Decision

        /** Still interrupted and a reconnect is still allowed and not yet used for this interruption. */
        data object Reconnect : Decision

        /** Still interrupted past the session-end window with no new frame: end + clean up. */
        data object EndSession : Decision
    }

    /**
     * Decide the watchdog action for the current tick.
     *
     * @param lastFrameAtMs monotonic-ish timestamp (ms) of the most recently admitted frame.
     * @param nowMs the current time (ms), from the injected clock.
     * @param interruptedAtMs when the current interruption began, or `null` if not currently
     *        interrupted. Callers set this to [nowMs] when they act on [Decision.ShowInterrupted].
     * @param reconnectAttempts reconnect attempts already made for the current interruption.
     * @param interruptMs no-frame threshold (defaults to [NO_FRAME_INTERRUPT_MS]).
     * @param endMs session-end threshold measured from [interruptedAtMs] (defaults to
     *        [SESSION_END_AFTER_INTERRUPT_MS]).
     * @param maxReconnects reconnect cap per interruption (defaults to [MAX_RECONNECTS]).
     *
     * Semantics:
     *  - If NOT interrupted:
     *      - a frame arrived within [interruptMs] → [Decision.Healthy];
     *      - otherwise (>= [interruptMs] with no frame) → [Decision.ShowInterrupted].
     *  - If interrupted:
     *      - a new frame advanced [lastFrameAtMs] past [interruptedAtMs] → [Decision.Healthy]
     *        (the interruption is cleared);
     *      - else if a reconnect is still allowed (`reconnectAttempts < maxReconnects`) →
     *        [Decision.Reconnect];
     *      - else if `nowMs - interruptedAtMs >= endMs` → [Decision.EndSession];
     *      - else → [Decision.ShowInterrupted] (keep showing the notice while waiting).
     */
    fun decide(
        lastFrameAtMs: Long,
        nowMs: Long,
        interruptedAtMs: Long?,
        reconnectAttempts: Int,
        interruptMs: Long = NO_FRAME_INTERRUPT_MS,
        endMs: Long = SESSION_END_AFTER_INTERRUPT_MS,
        maxReconnects: Int = MAX_RECONNECTS
    ): Decision {
        if (interruptedAtMs == null) {
            // Not currently interrupted: healthy until the no-frame gap reaches the threshold.
            return if (nowMs - lastFrameAtMs >= interruptMs) {
                Decision.ShowInterrupted
            } else {
                Decision.Healthy
            }
        }

        // Currently interrupted. A frame admitted at/after the interruption point clears it.
        if (lastFrameAtMs >= interruptedAtMs) {
            return Decision.Healthy
        }

        // Still no fresh frame. Prefer a (single) reconnect before ending the session.
        if (reconnectAttempts < maxReconnects) {
            return Decision.Reconnect
        }

        // Reconnect budget exhausted: end the session once the end window elapses.
        if (nowMs - interruptedAtMs >= endMs) {
            return Decision.EndSession
        }

        // Otherwise keep presenting the interrupted notice while the end window runs down.
        return Decision.ShowInterrupted
    }
}
