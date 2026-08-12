package com.skybridge.compass.remotecontrol.host

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for the host send seam ([HostFrameSink]): frames flow through the seam and each
 * teardown decision that reports a session-end notice maps to a peer-facing [HostSessionEndReason].
 */
class HostFrameSinkTest {

    private class FakeSink : HostFrameSink {
        val frames = mutableListOf<HostEncodedFrame>()
        val sessionEnds = mutableListOf<HostSessionEndReason>()
        override fun onEncodedFrame(frame: HostEncodedFrame) { frames.add(frame) }
        override fun onSessionEnd(reason: HostSessionEndReason) { sessionEnds.add(reason) }
    }

    /** Apply a stop decision against a fake sink exactly like the service teardown does. */
    private fun applyStop(sink: HostFrameSink, decision: HostStopDecision) {
        if (decision.sendSessionEndNotice) {
            decision.sessionEndReason?.let { sink.onSessionEnd(it) }
        }
    }

    @Test
    fun encodedFramesArePushedThroughSeam() {
        val sink = FakeSink()
        val frame = HostEncodedFrame(
            data = byteArrayOf(1, 2, 3),
            width = 1920,
            height = 1080,
            format = "h264",
            presentationTimeUs = 1_000L,
            isKeyFrame = true,
        )
        sink.onEncodedFrame(frame)
        assertEquals(1, sink.frames.size)
        assertEquals("h264", sink.frames.first().format)
        assertTrue(sink.frames.first().data.contentEquals(byteArrayOf(1, 2, 3)))
    }

    @Test
    fun userStopEmitsSessionEndNoticeToPeer() {
        val sink = FakeSink()
        applyStop(sink, AndroidRemoteControlHostAccessPolicy.decideUserStop())
        assertEquals(listOf(HostSessionEndReason.USER_STOPPED), sink.sessionEnds)
    }

    @Test
    fun authorizationRevokedWhileCapturingEmitsSessionEndNotice() {
        val sink = FakeSink()
        applyStop(sink, AndroidRemoteControlHostAccessPolicy.decideAuthorizationLost(wasCapturing = true))
        assertEquals(listOf(HostSessionEndReason.AUTHORIZATION_REVOKED), sink.sessionEnds)
    }

    @Test
    fun deniedBeforeCaptureEmitsNoSessionEndNotice() {
        val sink = FakeSink()
        applyStop(sink, AndroidRemoteControlHostAccessPolicy.decideAuthorizationLost(wasCapturing = false))
        assertTrue("no notice when capture never started", sink.sessionEnds.isEmpty())
    }

    @Test
    fun encodedFrameEqualityIsContentBased() {
        val a = HostEncodedFrame(byteArrayOf(9, 9), 2, 2, "hevc", 5L, false)
        val b = HostEncodedFrame(byteArrayOf(9, 9), 2, 2, "hevc", 5L, false)
        assertEquals(a, b)
        assertEquals(a.hashCode(), b.hashCode())
    }
}
