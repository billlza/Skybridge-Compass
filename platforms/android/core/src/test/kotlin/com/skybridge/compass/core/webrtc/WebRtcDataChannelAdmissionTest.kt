package com.skybridge.compass.core.webrtc

import org.junit.Assert.assertEquals
import org.junit.Test

class WebRtcDataChannelAdmissionTest {
    @Test
    fun acceptsOnlyTheExpectedFirstChannelForAnOpenSession() {
        assertEquals(
            WebRtcDataChannelAdmission.Result.ACCEPT,
            WebRtcDataChannelAdmission.evaluate(
                label = WebRtcDataChannelAdmission.EXPECTED_LABEL,
                hasActiveChannel = false,
                sessionClosed = false
            )
        )
        assertEquals(
            WebRtcDataChannelAdmission.Result.REJECT_WRONG_LABEL,
            WebRtcDataChannelAdmission.evaluate(
                label = "other",
                hasActiveChannel = false,
                sessionClosed = false
            )
        )
        assertEquals(
            WebRtcDataChannelAdmission.Result.REJECT_DUPLICATE,
            WebRtcDataChannelAdmission.evaluate(
                label = WebRtcDataChannelAdmission.EXPECTED_LABEL,
                hasActiveChannel = true,
                sessionClosed = false
            )
        )
        assertEquals(
            WebRtcDataChannelAdmission.Result.REJECT_CLOSED_SESSION,
            WebRtcDataChannelAdmission.evaluate(
                label = WebRtcDataChannelAdmission.EXPECTED_LABEL,
                hasActiveChannel = false,
                sessionClosed = true
            )
        )
    }
}
