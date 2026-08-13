package com.skybridge.compass.filetransfer.webrtc

/**
 * Pure, Android-independent decision unit for the idle / interrupt timeout of an in-progress
 * CrossNetwork (WebRTC DataChannel) file transfer (Requirement 5.12).
 *
 * The invariant this isolates is a single time comparison:
 *
 *   given the last-activity timestamp, the current time, and an idle threshold, the transfer has
 *   "timed out" iff no chunk/ack activity has been observed for at least the threshold.
 *
 * A transfer stays alive as long as chunk or ack messages keep flowing; every such message resets
 * `lastActivityMs`. When the peer goes silent (no chunk/ack for the threshold) OR the session drops
 * (which also stops all inbound activity), the elapsed idle time crosses the threshold and this
 * decision reports a timeout.
 *
 * Crucially, this is a *decision*, not an action: acting on the decision is the caller's job. A
 * pre-completion checkpoint remains resumable, while a checkpoint that records a sent completion
 * request is retained only as evidence of an unknown delivery outcome. This separation keeps the
 * "idle 30s => timed out, reason attributable" rule exhaustively unit-testable with an injected
 * clock and no live transport.
 *
 * This does NOT change the wire protocol.
 */
internal object TransferActivityTimeoutDecision {

    /** Why an active transfer was terminated by the activity watchdog (Requirement 5.12). */
    enum class Reason {
        /** No chunk or ack message was observed for at least the idle threshold. */
        IDLE_NO_ACTIVITY,

        /** The transport session was interrupted (not established) past the idle threshold. */
        SESSION_INTERRUPTED
    }

    /**
     * True iff at least [idleThresholdMs] have elapsed between [lastActivityMs] and [nowMs].
     *
     * Uses a `>=` boundary so a transfer that has been silent for *exactly* the threshold is treated
     * as timed out. Clock skew that makes [nowMs] < [lastActivityMs] yields a non-timed-out result
     * (elapsed clamped at 0) rather than a spurious timeout.
     */
    fun isTimedOut(lastActivityMs: Long, nowMs: Long, idleThresholdMs: Long): Boolean {
        require(idleThresholdMs > 0) { "idleThresholdMs must be positive, was $idleThresholdMs" }
        val elapsed = (nowMs - lastActivityMs).coerceAtLeast(0L)
        return elapsed >= idleThresholdMs
    }

    /**
     * The attributable [Reason] for a fired timeout. When the transport session is no longer
     * established/usable the timeout is attributed to a session interruption; otherwise the peer was
     * simply silent (idle). Callers should only invoke this after [isTimedOut] returns true.
     */
    fun reasonFor(sessionUsable: Boolean): Reason =
        if (sessionUsable) Reason.IDLE_NO_ACTIVITY else Reason.SESSION_INTERRUPTED

    /**
     * Human-readable, truthful status line presented to the user for a fired timeout
     * (Requirement 5.12: "present the interrupt/timeout reason"). Includes the idle threshold in
     * seconds so the reason is self-describing and stable for assertions.
     */
    fun statusMessage(reason: Reason, idleThresholdMs: Long): String {
        val seconds = idleThresholdMs / 1000L
        return when (reason) {
            Reason.IDLE_NO_ACTIVITY ->
                "transfer interrupted: no chunk/ack for ${seconds}s (checkpoint retained, resumable)"
            Reason.SESSION_INTERRUPTED ->
                "transfer interrupted: session dropped >${seconds}s (checkpoint retained, resumable)"
        }
    }

    /**
     * A completion request may already have been durably committed by the peer. Its checkpoint is
     * evidence of an ambiguous outcome, not a resumable payload; retrying under a fresh identifier
     * could deliver the same file twice.
     */
    fun completionOutcomeUnknownStatusMessage(reason: Reason, idleThresholdMs: Long): String {
        val seconds = idleThresholdMs / 1000L
        val prefix = when (reason) {
            Reason.IDLE_NO_ACTIVITY -> "transfer interrupted: no completion acknowledgement for ${seconds}s"
            Reason.SESSION_INTERRUPTED -> "transfer interrupted: session dropped >${seconds}s"
        }
        return "$prefix (delivery outcome unknown; checkpoint retained for evidence; do not resend)"
    }
}
