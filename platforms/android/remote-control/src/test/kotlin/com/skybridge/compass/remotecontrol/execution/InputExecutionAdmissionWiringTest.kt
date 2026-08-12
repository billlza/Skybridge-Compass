package com.skybridge.compass.remotecontrol.execution

import android.content.Context
import com.skybridge.compass.remotecontrol.admission.RemoteInputRejectionReason
import com.skybridge.compass.remotecontrol.model.TouchAction
import com.skybridge.compass.remotecontrol.model.TouchEvent
import io.mockk.mockk
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Verifies the admission gate sits in front of injection and that the local stop entry closes the
 * hard gate synchronously (R6.7/R6.8).
 *
 * These tests deliberately never reach real gesture dispatch: every event asserted here is refused
 * *before* injection, which is exactly the behaviour under test. No Android accessibility service is
 * attached, so nothing can touch device input state.
 */
class InputExecutionAdmissionWiringTest {

    private val context = mockk<Context>(relaxed = true)
    private val peer = "authorized-peer"

    private fun manager() = InputExecutionManager(context)

    private fun touchEvent(id: String = "e1") = TouchEvent(
        timestamp = 1L,
        deviceId = "device",
        eventId = id,
        action = TouchAction.DOWN,
        x = 10f,
        y = 20f,
    )

    @Test
    fun localStopFlipsTheHardGateSynchronously() {
        val manager = manager()
        manager.authorizeInjectionPeer(peer)
        assertTrue(manager.admissionGate.isInjectionAllowed)
        assertFalse(manager.isInjectionHardStopped)

        manager.stopAllInjectionNow()

        // No dispatcher advance, no awaiting: the gate is already closed when the call returns.
        assertTrue("hard gate must flip synchronously", manager.isInjectionHardStopped)
        assertFalse(manager.admissionGate.isInjectionAllowed)
    }

    @Test
    fun eventsAfterLocalStopAreDropped() = runTest {
        val manager = manager()
        manager.authorizeInjectionPeer(peer)

        manager.stopAllInjectionNow()

        val response = manager.executeAdmittedInputEvent(
            event = touchEvent(),
            envelopeCounter = 1L,
            peerId = peer,
            signatureValid = true,
        )

        assertFalse("injection must not run after local stop", response.success)
        assertEquals("输入注入已被本地停止", response.errorMessage)
    }

    @Test
    fun unauthorizedPeerEventIsRefusedBeforeInjection() = runTest {
        val manager = manager()
        manager.authorizeInjectionPeer(peer)

        val response = manager.executeAdmittedInputEvent(
            event = touchEvent(),
            envelopeCounter = 1L,
            peerId = "stranger",
            signatureValid = true,
        )

        assertFalse(response.success)
        assertTrue(
            "refusal reason must be carried back: ${response.errorMessage}",
            response.errorMessage?.contains(RemoteInputRejectionReason.PEER_NOT_AUTHORIZED.name) == true,
        )
    }

    @Test
    fun replayedCounterIsRefusedBeforeInjection() = runTest {
        val manager = manager()
        manager.authorizeInjectionPeer(peer)

        // Accepted by the gate (then fails at injection because no accessibility service is attached),
        // which is enough to advance the lane.
        manager.executeAdmittedInputEvent(touchEvent("e1"), 5L, peer, signatureValid = true)

        val replay = manager.executeAdmittedInputEvent(touchEvent("e2"), 5L, peer, signatureValid = true)

        assertFalse(replay.success)
        assertTrue(
            "replay must be refused by the gate: ${replay.errorMessage}",
            replay.errorMessage?.contains(RemoteInputRejectionReason.COUNTER_NOT_MONOTONIC.name) == true,
        )
    }

    @Test
    fun eventsAreRefusedBeforeAnyPeerIsAuthorized() = runTest {
        val manager = manager()

        val response = manager.executeAdmittedInputEvent(
            event = touchEvent(),
            envelopeCounter = 1L,
            peerId = peer,
            signatureValid = true,
        )

        assertFalse(response.success)
        assertTrue(
            response.errorMessage?.contains(RemoteInputRejectionReason.INJECTION_STOPPED.name) == true,
        )
    }
}
