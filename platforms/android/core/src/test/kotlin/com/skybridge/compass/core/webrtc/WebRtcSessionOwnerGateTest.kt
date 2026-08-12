package com.skybridge.compass.core.webrtc

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class WebRtcSessionOwnerGateTest {
    @Test
    fun replacementWithSameSessionIdRejectsOldReadyDisconnectAndFailurePublications() {
        val gate = WebRtcSessionOwnerGate()
        val first = gate.begin("ABC123").owner
        var visibleState = "connecting:first"

        assertTrue(gate.runIfCurrent(first) { visibleState = "ready:first" })
        val replacement = gate.begin("ABC123").owner
        visibleState = "connecting:replacement"

        assertFalse(gate.runIfCurrent(first) { visibleState = "ready:first-late" })
        assertFalse(gate.runIfCurrent(first) { visibleState = "disconnected:first-late" })
        assertFalse(gate.runIfCurrent(first) { visibleState = "failed:first-late" })
        assertEquals("connecting:replacement", visibleState)

        assertTrue(gate.runIfCurrent(replacement) { visibleState = "ready:replacement" })
        assertEquals("ready:replacement", visibleState)
        assertTrue(replacement.generation > first.generation)
    }

    @Test
    fun separatelyCreatedGatesProduceOpaqueDistinctOwners() {
        val first = WebRtcSessionOwnerGate().begin("ABC123").owner
        val second = WebRtcSessionOwnerGate().begin("ABC123").owner

        assertEquals(first.sessionId, second.sessionId)
        assertEquals(first.generation, second.generation)
        assertNotEquals(first, second)
    }

    @Test
    fun staleReleaseCannotClearReplacement() {
        val gate = WebRtcSessionOwnerGate()
        val first = gate.begin("ABC123").owner
        val replacement = gate.begin("ABC123").owner

        assertFalse(gate.releaseIfCurrent(first))
        assertEquals(replacement, gate.current())
        assertTrue(gate.releaseIfCurrent(replacement))
        assertEquals(null, gate.current())
    }
}
