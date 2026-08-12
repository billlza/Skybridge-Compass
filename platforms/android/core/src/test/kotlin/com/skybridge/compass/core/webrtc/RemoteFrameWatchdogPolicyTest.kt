package com.skybridge.compass.core.webrtc

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Unit tests for [RemoteFrameWatchdogPolicy] (Task 13.2, Requirement 6.13).
 *
 * The policy is pure and clock-injected, so every branch is verified deterministically without any
 * timers:
 *  - no frame for 5s while established -> ShowInterrupted
 *  - still no frame while a reconnect is allowed -> Reconnect (exactly once per interruption)
 *  - no frame 10s after the interruption began, reconnect budget spent -> EndSession
 *  - a frame arriving -> Healthy (clears the interruption)
 *  - at most one reconnect per interruption
 *
 * "Retain the last frame" is a ViewModel concern (the decision itself does not clear frames); here we
 * assert the decision the ViewModel acts on.
 */
class RemoteFrameWatchdogPolicyTest {

    private val interruptMs = RemoteFrameWatchdogPolicy.NO_FRAME_INTERRUPT_MS   // 5_000
    private val endMs = RemoteFrameWatchdogPolicy.SESSION_END_AFTER_INTERRUPT_MS // 10_000

    // --- healthy ---

    @Test
    fun freshFrame_isHealthy() {
        val decision = RemoteFrameWatchdogPolicy.decide(
            lastFrameAtMs = 1_000,
            nowMs = 1_100,
            interruptedAtMs = null,
            reconnectAttempts = 0
        )
        assertEquals(RemoteFrameWatchdogPolicy.Decision.Healthy, decision)
    }

    @Test
    fun justUnderInterruptThreshold_isHealthy() {
        // 4_999ms gap: still under the 5s threshold.
        val decision = RemoteFrameWatchdogPolicy.decide(
            lastFrameAtMs = 0,
            nowMs = interruptMs - 1,
            interruptedAtMs = null,
            reconnectAttempts = 0
        )
        assertEquals(RemoteFrameWatchdogPolicy.Decision.Healthy, decision)
    }

    // --- 5s no frame -> ShowInterrupted ---

    @Test
    fun noFrameForFiveSeconds_showsInterrupted() {
        val decision = RemoteFrameWatchdogPolicy.decide(
            lastFrameAtMs = 0,
            nowMs = interruptMs, // exactly 5_000ms gap
            interruptedAtMs = null,
            reconnectAttempts = 0
        )
        assertEquals(RemoteFrameWatchdogPolicy.Decision.ShowInterrupted, decision)
    }

    // --- reconnect exactly once ---

    @Test
    fun whileInterrupted_reconnectAllowed_returnsReconnect() {
        // Interruption recorded, no reconnect used yet, no fresh frame.
        val decision = RemoteFrameWatchdogPolicy.decide(
            lastFrameAtMs = 0,
            nowMs = interruptMs + 100,
            interruptedAtMs = interruptMs,
            reconnectAttempts = 0
        )
        assertEquals(RemoteFrameWatchdogPolicy.Decision.Reconnect, decision)
    }

    @Test
    fun atMostOneReconnectPerInterruption() {
        // First evaluation: reconnect is allowed.
        assertEquals(
            RemoteFrameWatchdogPolicy.Decision.Reconnect,
            RemoteFrameWatchdogPolicy.decide(
                lastFrameAtMs = 0,
                nowMs = interruptMs + 100,
                interruptedAtMs = interruptMs,
                reconnectAttempts = 0
            )
        )
        // After one attempt (reconnectAttempts = 1 = MAX_RECONNECTS), no further reconnect is issued
        // before the end window — the notice keeps showing.
        assertEquals(
            RemoteFrameWatchdogPolicy.Decision.ShowInterrupted,
            RemoteFrameWatchdogPolicy.decide(
                lastFrameAtMs = 0,
                nowMs = interruptMs + 200,
                interruptedAtMs = interruptMs,
                reconnectAttempts = RemoteFrameWatchdogPolicy.MAX_RECONNECTS
            )
        )
    }

    // --- 10s after interruption -> EndSession ---

    @Test
    fun tenSecondsAfterInterruption_reconnectSpent_endsSession() {
        val decision = RemoteFrameWatchdogPolicy.decide(
            lastFrameAtMs = 0,
            nowMs = interruptMs + endMs, // 10s after the interruption began
            interruptedAtMs = interruptMs,
            reconnectAttempts = RemoteFrameWatchdogPolicy.MAX_RECONNECTS
        )
        assertEquals(RemoteFrameWatchdogPolicy.Decision.EndSession, decision)
    }

    @Test
    fun justUnderEndWindow_reconnectSpent_keepsShowingInterrupted() {
        val decision = RemoteFrameWatchdogPolicy.decide(
            lastFrameAtMs = 0,
            nowMs = interruptMs + endMs - 1,
            interruptedAtMs = interruptMs,
            reconnectAttempts = RemoteFrameWatchdogPolicy.MAX_RECONNECTS
        )
        assertEquals(RemoteFrameWatchdogPolicy.Decision.ShowInterrupted, decision)
    }

    // --- a frame arriving resets ---

    @Test
    fun frameArrivingDuringInterruption_isHealthy() {
        // A new frame admitted at/after the interruption point clears the interruption.
        val decision = RemoteFrameWatchdogPolicy.decide(
            lastFrameAtMs = interruptMs + 500,
            nowMs = interruptMs + 600,
            interruptedAtMs = interruptMs,
            reconnectAttempts = RemoteFrameWatchdogPolicy.MAX_RECONNECTS
        )
        assertEquals(RemoteFrameWatchdogPolicy.Decision.Healthy, decision)
    }

    @Test
    fun frameArrivingDuringInterruption_takesPrecedenceOverEndSession() {
        // Even past the end window, a fresh frame means the session is healthy again (not ended).
        val decision = RemoteFrameWatchdogPolicy.decide(
            lastFrameAtMs = interruptMs + endMs + 1,
            nowMs = interruptMs + endMs + 2,
            interruptedAtMs = interruptMs,
            reconnectAttempts = RemoteFrameWatchdogPolicy.MAX_RECONNECTS
        )
        assertEquals(RemoteFrameWatchdogPolicy.Decision.Healthy, decision)
    }

    // --- full lifecycle over a single interruption ---

    @Test
    fun fullLifecycle_interrupt_reconnectOnce_thenEnd() {
        var lastFrameAtMs = 0L
        var interruptedAtMs: Long? = null
        var reconnectAttempts = 0

        // t=5000: first detection -> ShowInterrupted; ViewModel records interruptedAt = now.
        var d = RemoteFrameWatchdogPolicy.decide(lastFrameAtMs, 5_000, interruptedAtMs, reconnectAttempts)
        assertEquals(RemoteFrameWatchdogPolicy.Decision.ShowInterrupted, d)
        interruptedAtMs = 5_000

        // t=5500: still no frame, reconnect allowed -> Reconnect; ViewModel bumps attempts.
        d = RemoteFrameWatchdogPolicy.decide(lastFrameAtMs, 5_500, interruptedAtMs, reconnectAttempts)
        assertEquals(RemoteFrameWatchdogPolicy.Decision.Reconnect, d)
        reconnectAttempts += 1

        // t=6000: reconnect spent, before end window -> ShowInterrupted.
        d = RemoteFrameWatchdogPolicy.decide(lastFrameAtMs, 6_000, interruptedAtMs, reconnectAttempts)
        assertEquals(RemoteFrameWatchdogPolicy.Decision.ShowInterrupted, d)

        // t=15000: 10s after interruption, reconnect spent, still no frame -> EndSession.
        d = RemoteFrameWatchdogPolicy.decide(lastFrameAtMs, 15_000, interruptedAtMs, reconnectAttempts)
        assertEquals(RemoteFrameWatchdogPolicy.Decision.EndSession, d)

        // Sanity: had a frame arrived at t=7000, the very next tick would be Healthy.
        lastFrameAtMs = 7_000
        d = RemoteFrameWatchdogPolicy.decide(lastFrameAtMs, 7_100, interruptedAtMs, reconnectAttempts)
        assertEquals(RemoteFrameWatchdogPolicy.Decision.Healthy, d)
    }

    // --- custom thresholds are honored (used by the ViewModel/LAN client with shortened test windows) ---

    @Test
    fun customThresholds_areHonored() {
        // interruptMs=100, endMs=200, maxReconnects=1
        assertEquals(
            RemoteFrameWatchdogPolicy.Decision.ShowInterrupted,
            RemoteFrameWatchdogPolicy.decide(
                lastFrameAtMs = 0, nowMs = 100, interruptedAtMs = null, reconnectAttempts = 0,
                interruptMs = 100, endMs = 200, maxReconnects = 1
            )
        )
        assertEquals(
            RemoteFrameWatchdogPolicy.Decision.Reconnect,
            RemoteFrameWatchdogPolicy.decide(
                lastFrameAtMs = 0, nowMs = 120, interruptedAtMs = 100, reconnectAttempts = 0,
                interruptMs = 100, endMs = 200, maxReconnects = 1
            )
        )
        assertEquals(
            RemoteFrameWatchdogPolicy.Decision.EndSession,
            RemoteFrameWatchdogPolicy.decide(
                lastFrameAtMs = 0, nowMs = 300, interruptedAtMs = 100, reconnectAttempts = 1,
                interruptMs = 100, endMs = 200, maxReconnects = 1
            )
        )
    }
}
