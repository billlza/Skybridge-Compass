package com.skybridge.compass.core.webrtc

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WebRtcIceCandidatePolicyTest {
    @Test
    fun rejectsRemoteLoopbackHostCandidates() {
        assertTrue(
            WebRtcIceCandidatePolicy.isRemoteLoopbackCandidate(
                "candidate:1 1 tcp 1518280447 127.0.0.1 18789 typ host tcptype passive"
            )
        )
        assertTrue(
            WebRtcIceCandidatePolicy.isRemoteLoopbackCandidate(
                "a=candidate:2 1 udp 2122260223 ::1 53578 typ host"
            )
        )
    }

    @Test
    fun keepsReachablePrivateAndRelayCandidates() {
        assertFalse(
            WebRtcIceCandidatePolicy.isRemoteLoopbackCandidate(
                "candidate:3 1 udp 2122260223 192.168.1.23 53578 typ host"
            )
        )
        assertFalse(
            WebRtcIceCandidatePolicy.isRemoteLoopbackCandidate(
                "candidate:4 1 udp 1677729535 203.0.113.10 3478 typ relay raddr 10.0.0.5 rport 49921"
            )
        )
    }
}
