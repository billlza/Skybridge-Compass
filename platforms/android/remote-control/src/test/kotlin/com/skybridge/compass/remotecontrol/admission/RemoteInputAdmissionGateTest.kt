package com.skybridge.compass.remotecontrol.admission

import com.skybridge.compass.remotecontrol.secure.RemoteControlSecureEnvelope.PacketType
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for the remote input admission gate (R6.7/R6.8).
 *
 * Window boundary convention under test: with `highest` the highest accepted counter and
 * `delta = counter - highest`, the gate accepts `1 <= delta <= 256` — inclusive at +256, rejected at
 * +257 — and rejects `delta <= 0` as non-monotonic.
 */
class RemoteInputAdmissionGateTest {

    private val peer = "authorized-peer"
    private val otherPeer = "stranger-peer"

    private class RecordingAuditSink : RemoteInputAuditSink {
        val events = mutableListOf<RemoteInputAuditEvent>()
        override fun record(event: RemoteInputAuditEvent) {
            events.add(event)
        }
    }

    private fun openGate(sink: RemoteInputAuditSink): RemoteInputAdmissionGate =
        RemoteInputAdmissionGate(auditSink = sink).apply { startInjection(peer) }

    private fun RemoteInputAdmissionGate.admitFrom(
        counter: Long,
        peerId: String = peer,
        signatureValid: Boolean = true,
    ): Admission = admit(
        envelopeCounter = counter,
        packetType = PacketType.CONTROL,
        peerId = peerId,
        signatureValid = signatureValid,
    )

    @Test
    fun acceptsStrictlyIncreasingCounters() {
        val sink = RecordingAuditSink()
        val gate = openGate(sink)

        assertEquals(Admission.Accept(1L), gate.admitFrom(1L))
        assertEquals(Admission.Accept(2L), gate.admitFrom(2L))
        assertEquals(Admission.Accept(3L), gate.admitFrom(3L))
        assertTrue("accepted events must not be audited", sink.events.isEmpty())
    }

    @Test
    fun rejectsEqualCounterAsNonMonotonic() {
        val sink = RecordingAuditSink()
        val gate = openGate(sink)
        gate.admitFrom(7L)

        val replay = gate.admitFrom(7L)

        assertEquals(
            Admission.Reject(RemoteInputRejectionReason.COUNTER_NOT_MONOTONIC),
            replay,
        )
        assertEquals(1, sink.events.size)
        assertEquals(RemoteInputRejectionReason.COUNTER_NOT_MONOTONIC, sink.events[0].reason)
        assertEquals(7L, sink.events[0].counter)
        assertEquals(7L, sink.events[0].highestAcceptedCounter)
        assertEquals(peer, sink.events[0].peerId)
    }

    @Test
    fun rejectsLowerCounterAsNonMonotonic() {
        val sink = RecordingAuditSink()
        val gate = openGate(sink)
        gate.admitFrom(10L)

        assertEquals(
            Admission.Reject(RemoteInputRejectionReason.COUNTER_NOT_MONOTONIC),
            gate.admitFrom(9L),
        )
        assertEquals(
            Admission.Reject(RemoteInputRejectionReason.COUNTER_NOT_MONOTONIC),
            gate.admitFrom(1L),
        )
        assertEquals(2, sink.events.size)
        assertTrue(
            sink.events.all { it.reason == RemoteInputRejectionReason.COUNTER_NOT_MONOTONIC },
        )
    }

    @Test
    fun rejectsZeroAndNegativeCounters() {
        val sink = RecordingAuditSink()
        val gate = openGate(sink)

        assertEquals(
            Admission.Reject(RemoteInputRejectionReason.COUNTER_NOT_MONOTONIC),
            gate.admitFrom(0L),
        )
        assertEquals(
            Admission.Reject(RemoteInputRejectionReason.COUNTER_NOT_MONOTONIC),
            gate.admitFrom(-5L),
        )
        assertEquals(2, sink.events.size)
    }

    @Test
    fun acceptsExactlyWindowEdgeAndRejectsOneBeyond() {
        val sink = RecordingAuditSink()
        val gate = RemoteInputAdmissionGate(auditSink = sink)
        gate.startInjection(peer, baselineCounter = 999L)
        gate.admitFrom(1_000L)

        // +256 from the highest accepted counter is inside the window (inclusive edge).
        assertEquals(Admission.Accept(1_256L), gate.admitFrom(1_256L))
        assertTrue("edge acceptance must not audit", sink.events.isEmpty())

        // +257 from the new highest (1_256) is outside the window.
        assertEquals(
            Admission.Reject(RemoteInputRejectionReason.COUNTER_OUTSIDE_WINDOW),
            gate.admitFrom(1_256L + 257L),
        )
        assertEquals(1, sink.events.size)
        assertEquals(RemoteInputRejectionReason.COUNTER_OUTSIDE_WINDOW, sink.events[0].reason)
        assertEquals(1_256L + 257L, sink.events[0].counter)
        assertEquals(1_256L, sink.events[0].highestAcceptedCounter)
    }

    @Test
    fun rejectsFirstEventBeyondWindowFromSessionStart() {
        val sink = RecordingAuditSink()
        val gate = openGate(sink)

        // Lane starts at 0, so 256 is the inclusive edge and 257 is out of window.
        assertEquals(
            Admission.Reject(RemoteInputRejectionReason.COUNTER_OUTSIDE_WINDOW),
            gate.admitFrom(257L),
        )
        assertEquals(Admission.Accept(256L), gate.admitFrom(256L))
        assertEquals(1, sink.events.size)
    }

    @Test
    fun rejectsUnauthorizedPeer() {
        val sink = RecordingAuditSink()
        val gate = openGate(sink)

        val decision = gate.admitFrom(counter = 1L, peerId = otherPeer)

        assertEquals(
            Admission.Reject(RemoteInputRejectionReason.PEER_NOT_AUTHORIZED),
            decision,
        )
        assertEquals(1, sink.events.size)
        assertEquals(RemoteInputRejectionReason.PEER_NOT_AUTHORIZED, sink.events[0].reason)
        assertEquals(otherPeer, sink.events[0].peerId)
    }

    @Test
    fun unauthorizedPeerCannotAdvanceTheAuthorizedLane() {
        val sink = RecordingAuditSink()
        val gate = openGate(sink)

        gate.admitFrom(counter = 5L, peerId = otherPeer)

        // The authorized peer's lane was untouched, so counter 1 is still acceptable.
        assertEquals(Admission.Accept(1L), gate.admitFrom(1L))
    }

    @Test
    fun rejectsInvalidSignature() {
        val sink = RecordingAuditSink()
        val gate = openGate(sink)

        val decision = gate.admitFrom(counter = 1L, signatureValid = false)

        assertEquals(
            Admission.Reject(RemoteInputRejectionReason.SIGNATURE_INVALID),
            decision,
        )
        assertEquals(1, sink.events.size)
        assertEquals(RemoteInputRejectionReason.SIGNATURE_INVALID, sink.events[0].reason)
    }

    @Test
    fun signatureFailureDoesNotAdvanceTheLane() {
        val sink = RecordingAuditSink()
        val gate = openGate(sink)

        gate.admitFrom(counter = 9L, signatureValid = false)

        assertEquals(Admission.Accept(1L), gate.admitFrom(1L))
    }

    @Test
    fun midSessionAuthorizationSeedsTheWindowFromTheObservedCounter() {
        val sink = RecordingAuditSink()
        val gate = RemoteInputAdmissionGate(auditSink = sink)

        // Injection enabled long after the session started: envelope counter is already at 10_000.
        gate.startInjection(peer, baselineCounter = 10_000L)

        assertEquals(Admission.Accept(10_001L), gate.admitFrom(10_001L))
        assertTrue(sink.events.isEmpty())

        // Counters from before authorization stay rejected.
        assertEquals(
            Admission.Reject(RemoteInputRejectionReason.COUNTER_NOT_MONOTONIC),
            gate.admitFrom(9_999L),
        )
    }

    @Test
    fun everyRejectRecordsExactlyOneAuditEvent() {
        val sink = RecordingAuditSink()
        val gate = openGate(sink)
        gate.admitFrom(100L)

        gate.admitFrom(100L)                                   // non-monotonic
        gate.admitFrom(100L + 257L)                            // outside window
        gate.admitFrom(counter = 101L, peerId = otherPeer)     // unauthorized peer
        gate.admitFrom(counter = 101L, signatureValid = false)  // bad signature

        assertEquals(4, sink.events.size)
        assertEquals(
            listOf(
                RemoteInputRejectionReason.COUNTER_NOT_MONOTONIC,
                RemoteInputRejectionReason.COUNTER_OUTSIDE_WINDOW,
                RemoteInputRejectionReason.PEER_NOT_AUTHORIZED,
                RemoteInputRejectionReason.SIGNATURE_INVALID,
            ),
            sink.events.map { it.reason },
        )
    }

    @Test
    fun localStopClosesGateSynchronouslyAndDropsSubsequentEvents() {
        val sink = RecordingAuditSink()
        val gate = openGate(sink)
        assertEquals(Admission.Accept(1L), gate.admitFrom(1L))
        assertTrue(gate.isInjectionAllowed)

        gate.stopAllInjection()

        // The gate flipped on the calling thread — no scheduling, no await.
        assertFalse("gate must be closed synchronously", gate.isInjectionAllowed)

        assertEquals(
            Admission.Reject(RemoteInputRejectionReason.INJECTION_STOPPED),
            gate.admitFrom(2L),
        )
        assertEquals(
            Admission.Reject(RemoteInputRejectionReason.INJECTION_STOPPED),
            gate.admitFrom(3L),
        )
        assertEquals(2, sink.events.size)
        assertTrue(
            sink.events.all { it.reason == RemoteInputRejectionReason.INJECTION_STOPPED },
        )
    }

    @Test
    fun gateRejectsEverythingBeforeInjectionIsAuthorized() {
        val sink = RecordingAuditSink()
        val gate = RemoteInputAdmissionGate(auditSink = sink)

        assertFalse(gate.isInjectionAllowed)
        assertEquals(
            Admission.Reject(RemoteInputRejectionReason.INJECTION_STOPPED),
            gate.admitFrom(1L),
        )
    }

    @Test
    fun stopIsIdempotentAndRestartReopensGate() {
        val sink = RecordingAuditSink()
        val gate = openGate(sink)

        gate.stopAllInjection()
        gate.stopAllInjection()
        assertFalse(gate.isInjectionAllowed)

        gate.startInjection(peer)
        assertTrue(gate.isInjectionAllowed)
        // Lanes reset on restart, so the session may begin from counter 1 again.
        assertEquals(Admission.Accept(1L), gate.admitFrom(1L))
    }

    @Test
    fun packetTypeLanesAreIndependent() {
        val sink = RecordingAuditSink()
        val gate = openGate(sink)

        val control = gate.admit(50L, PacketType.CONTROL, peer, signatureValid = true)
        val screen = gate.admit(50L, PacketType.SCREEN, peer, signatureValid = true)

        assertEquals(Admission.Accept(50L), control)
        assertEquals("SCREEN lane must not be starved by CONTROL", Admission.Accept(50L), screen)
        assertTrue(sink.events.isEmpty())
    }

    @Test
    fun rejectionPrecedenceIsStopThenPeerThenSignatureThenCounter() {
        // Pure decision function: exhaustive precedence check, no state involved.
        assertEquals(
            Admission.Reject(RemoteInputRejectionReason.INJECTION_STOPPED),
            RemoteInputAdmissionGate.decide(
                highestAcceptedCounter = 5L,
                incomingCounter = 1L,
                injectionAllowed = false,
                peerAuthorized = false,
                signatureValid = false,
            ),
        )
        assertEquals(
            Admission.Reject(RemoteInputRejectionReason.PEER_NOT_AUTHORIZED),
            RemoteInputAdmissionGate.decide(
                highestAcceptedCounter = 5L,
                incomingCounter = 1L,
                injectionAllowed = true,
                peerAuthorized = false,
                signatureValid = false,
            ),
        )
        assertEquals(
            Admission.Reject(RemoteInputRejectionReason.SIGNATURE_INVALID),
            RemoteInputAdmissionGate.decide(
                highestAcceptedCounter = 5L,
                incomingCounter = 1L,
                injectionAllowed = true,
                peerAuthorized = true,
                signatureValid = false,
            ),
        )
        assertEquals(
            Admission.Reject(RemoteInputRejectionReason.COUNTER_NOT_MONOTONIC),
            RemoteInputAdmissionGate.decide(
                highestAcceptedCounter = 5L,
                incomingCounter = 1L,
                injectionAllowed = true,
                peerAuthorized = true,
                signatureValid = true,
            ),
        )
    }

    @Test
    fun pureDecisionCoversWholeCounterNeighbourhoodOfTheWindowEdge() {
        val highest = 1_000L
        // delta from -2 through +258 around the boundary, all four gates open.
        for (delta in -2L..258L) {
            val decision = RemoteInputAdmissionGate.decide(
                highestAcceptedCounter = highest,
                incomingCounter = highest + delta,
                injectionAllowed = true,
                peerAuthorized = true,
                signatureValid = true,
            )
            val expected: Admission = when {
                delta <= 0L -> Admission.Reject(RemoteInputRejectionReason.COUNTER_NOT_MONOTONIC)
                delta <= 256L -> Admission.Accept(highest + delta)
                else -> Admission.Reject(RemoteInputRejectionReason.COUNTER_OUTSIDE_WINDOW)
            }
            assertEquals("delta=$delta", expected, decision)
        }
    }
}
