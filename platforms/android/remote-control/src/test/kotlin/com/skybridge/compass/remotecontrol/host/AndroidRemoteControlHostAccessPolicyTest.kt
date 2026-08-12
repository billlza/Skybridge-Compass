package com.skybridge.compass.remotecontrol.host

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for the pure host authorization + lifecycle decision logic (R6.6/R6.12).
 */
class AndroidRemoteControlHostAccessPolicyTest {

    @Test
    fun grantedAuthorizationStartsCaptureWithoutNotice() {
        val decision = AndroidRemoteControlHostAccessPolicy.decideStart(HostAuthorizationState.GRANTED)
        assertTrue(decision.startCapture)
        assertFalse(decision.presentMissingAuthorizationNotice)
        assertTrue(decision.keepViewingSessionUsable)
    }

    @Test
    fun deniedAuthorizationDoesNotStartAndKeepsViewingSession() {
        val decision = AndroidRemoteControlHostAccessPolicy.decideStart(HostAuthorizationState.DENIED)
        assertFalse("must not start capture when denied", decision.startCapture)
        assertTrue("must present missing-auth notice", decision.presentMissingAuthorizationNotice)
        assertTrue("viewing session stays usable", decision.keepViewingSessionUsable)
    }

    @Test
    fun revokedAuthorizationDoesNotStartAndKeepsViewingSession() {
        val decision = AndroidRemoteControlHostAccessPolicy.decideStart(HostAuthorizationState.REVOKED)
        assertFalse(decision.startCapture)
        assertTrue(decision.presentMissingAuthorizationNotice)
        assertTrue(decision.keepViewingSessionUsable)
    }

    @Test
    fun userStopStopsEverythingAndSendsSessionEndNotice() {
        val decision = AndroidRemoteControlHostAccessPolicy.decideUserStop()
        assertTrue(decision.stopCapture)
        assertTrue(decision.stopForegroundService)
        assertTrue(decision.removeNotification)
        assertTrue("session-end notice sent to peer", decision.sendSessionEndNotice)
        assertEquals(HostSessionEndReason.USER_STOPPED, decision.sessionEndReason)
        assertTrue(decision.keepViewingSessionUsable)
    }

    @Test
    fun authorizationLostWhileCapturingStopsAndNotifiesPeer() {
        val decision = AndroidRemoteControlHostAccessPolicy.decideAuthorizationLost(wasCapturing = true)
        assertTrue(decision.stopCapture)
        assertTrue(decision.stopForegroundService)
        assertTrue(decision.removeNotification)
        assertTrue(decision.sendSessionEndNotice)
        assertEquals(HostSessionEndReason.AUTHORIZATION_REVOKED, decision.sessionEndReason)
        assertTrue("must present missing-auth notice", decision.presentMissingAuthorizationNotice)
        assertTrue("viewing session stays usable", decision.keepViewingSessionUsable)
    }

    @Test
    fun authorizationLostBeforeCapturingStopsServiceWithoutFrameNotice() {
        val decision = AndroidRemoteControlHostAccessPolicy.decideAuthorizationLost(wasCapturing = false)
        assertFalse("nothing to stop capturing", decision.stopCapture)
        assertTrue(decision.stopForegroundService)
        assertTrue(decision.removeNotification)
        assertFalse("no capture ran, no session-end notice", decision.sendSessionEndNotice)
        assertNull(decision.sessionEndReason)
        assertTrue(decision.presentMissingAuthorizationNotice)
        assertTrue(decision.keepViewingSessionUsable)
    }

    @Test
    fun sessionEndedStopsCaptureAndNotifiesPeer() {
        val decision = AndroidRemoteControlHostAccessPolicy.decideSessionEnded()
        assertTrue(decision.stopCapture)
        assertTrue(decision.stopForegroundService)
        assertTrue(decision.removeNotification)
        assertTrue(decision.sendSessionEndNotice)
        assertEquals(HostSessionEndReason.SESSION_ENDED, decision.sessionEndReason)
        assertTrue(decision.keepViewingSessionUsable)
    }
}
