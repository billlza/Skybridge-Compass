package com.skybridge.compass.filetransfer.webrtc

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * Exhaustive unit tests for the pure idle/interrupt timeout decision (Requirement 5.12).
 *
 * The invariant under test: given a last-activity timestamp, the current time and an idle
 * threshold, a transfer is "timed out" iff at least the threshold has elapsed with no activity;
 * fresh activity (a more recent timestamp) keeps it alive; and the fired reason is attributable to
 * either an idle peer or a dropped session. Because the decision is pure, every boundary is
 * covered without a live transport or real clock.
 */
class TransferActivityTimeoutDecisionTest {

    private val threshold = 30_000L

    @Test
    fun notTimedOut_whenIdleBelowThreshold() {
        assertFalse(TransferActivityTimeoutDecision.isTimedOut(lastActivityMs = 0, nowMs = 29_999, idleThresholdMs = threshold))
    }

    @Test
    fun timedOut_exactlyAtThreshold() {
        // `>=` boundary: silent for exactly the threshold counts as timed out.
        assertTrue(TransferActivityTimeoutDecision.isTimedOut(lastActivityMs = 0, nowMs = 30_000, idleThresholdMs = threshold))
    }

    @Test
    fun timedOut_pastThreshold() {
        assertTrue(TransferActivityTimeoutDecision.isTimedOut(lastActivityMs = 1_000, nowMs = 40_000, idleThresholdMs = threshold))
    }

    @Test
    fun freshActivity_resetsIdleAndAvoidsTimeout() {
        // At t=40s a transfer whose last activity was t=0 is timed out...
        assertTrue(TransferActivityTimeoutDecision.isTimedOut(lastActivityMs = 0, nowMs = 40_000, idleThresholdMs = threshold))
        // ...but if activity was refreshed at t=39s, the same t=40s check is NOT timed out.
        assertFalse(TransferActivityTimeoutDecision.isTimedOut(lastActivityMs = 39_000, nowMs = 40_000, idleThresholdMs = threshold))
    }

    @Test
    fun negativeElapsed_isClampedAndNotTimedOut() {
        // Clock skew (now < lastActivity) must not produce a spurious timeout.
        assertFalse(TransferActivityTimeoutDecision.isTimedOut(lastActivityMs = 10_000, nowMs = 5_000, idleThresholdMs = threshold))
    }

    @Test
    fun nonPositiveThreshold_rejected() {
        assertThrows(IllegalArgumentException::class.java) {
            TransferActivityTimeoutDecision.isTimedOut(0, 1, 0)
        }
    }

    @Test
    fun reason_isIdleWhenSessionUsable_andInterruptedOtherwise() {
        assertEquals(
            TransferActivityTimeoutDecision.Reason.IDLE_NO_ACTIVITY,
            TransferActivityTimeoutDecision.reasonFor(sessionUsable = true)
        )
        assertEquals(
            TransferActivityTimeoutDecision.Reason.SESSION_INTERRUPTED,
            TransferActivityTimeoutDecision.reasonFor(sessionUsable = false)
        )
    }

    @Test
    fun statusMessage_isTruthfulAndCarriesThresholdSeconds() {
        val idle = TransferActivityTimeoutDecision.statusMessage(
            TransferActivityTimeoutDecision.Reason.IDLE_NO_ACTIVITY, threshold
        )
        val dropped = TransferActivityTimeoutDecision.statusMessage(
            TransferActivityTimeoutDecision.Reason.SESSION_INTERRUPTED, threshold
        )
        assertTrue(idle.contains("30s"), "idle reason must state the 30s threshold: $idle")
        assertTrue(idle.contains("no chunk/ack"), "idle reason must explain the cause: $idle")
        assertTrue(idle.contains("resumable"), "reason must indicate the transfer is resumable: $idle")
        assertTrue(dropped.contains("30s"), "interrupt reason must state the 30s threshold: $dropped")
        assertTrue(dropped.contains("session"), "interrupt reason must explain the cause: $dropped")
        assertTrue(dropped.contains("resumable"), "reason must indicate the transfer is resumable: $dropped")
    }
}
