package com.skybridge.compass.core.webrtc

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for [RemoteRenderAdmissionPolicy] (Task 13.1, Requirements 6.1 and 6.11).
 *
 * Covers the pure render-admission decision so it is verifiable without a `MediaCodec`:
 * - resolution over 1920x1080 is rejected with RESOLUTION_OVER_LIMIT
 * - frame rate over 60 fps is rejected with FRAME_RATE_OVER_LIMIT
 * - a non-H.264/HEVC (and non-static-image) codec is rejected as UnsupportedCodec
 * - H.264/HEVC within limits are admitted
 * - the boundary (exactly 1920x1080 @ 60 fps) is admitted; 1921 / 1081 / 61 fps are rejected
 */
class RemoteRenderAdmissionPolicyTest {

    // --- codec admission (R6.11) ---

    @Test
    fun h264WithinLimits_isAdmitted() {
        val decision = RemoteRenderAdmissionPolicy.decide(
            format = AndroidRemoteVideoFormats.H264,
            width = 1280,
            height = 720,
            frameRate = 30
        )
        assertEquals(RemoteRenderAdmissionPolicy.Decision.Admit, decision)
    }

    @Test
    fun hevcWithinLimits_isAdmitted() {
        val decision = RemoteRenderAdmissionPolicy.decide(
            format = AndroidRemoteVideoFormats.HEVC,
            width = 1920,
            height = 1080,
            frameRate = 60
        )
        assertEquals(RemoteRenderAdmissionPolicy.Decision.Admit, decision)
    }

    @Test
    fun unknownVideoCodec_isRejectedAsUnsupportedCodec() {
        // A non-H.264/HEVC codec that is also not a supported static image (e.g. VP9/AV1) must be
        // refused as an unsupported codec, even when the dimensions and frame rate are within limits.
        for (codec in listOf("vp9", "av1", "vp8", "mpeg4")) {
            val decision = RemoteRenderAdmissionPolicy.decide(
                format = codec,
                width = 1280,
                height = 720,
                frameRate = 30
            )
            assertEquals(
                "codec $codec should be UnsupportedCodec",
                RemoteRenderAdmissionPolicy.Decision.UnsupportedCodec(codec),
                decision
            )
        }
    }

    @Test
    fun nullFormat_isRejectedAsUnsupportedCodec() {
        val decision = RemoteRenderAdmissionPolicy.decide(
            format = null,
            width = 1280,
            height = 720,
            frameRate = 30
        )
        assertEquals(RemoteRenderAdmissionPolicy.Decision.UnsupportedCodec(null), decision)
    }

    @Test
    fun staticImageFormat_isAdmitted_preservingExistingBehavior() {
        // JPEG (and other static image formats) are rendered by the image path, not the MediaCodec
        // video path; they must keep working so existing successful-render behavior is preserved.
        for (format in listOf(
            AndroidRemoteVideoFormats.JPEG,
            "png",
            "webp",
            "heif",
            "avif"
        )) {
            val decision = RemoteRenderAdmissionPolicy.decide(
                format = format,
                width = 1280,
                height = 720,
                frameRate = 30
            )
            assertEquals(
                "static image format $format should be admitted",
                RemoteRenderAdmissionPolicy.Decision.Admit,
                decision
            )
        }
    }

    // --- resolution admission (R6.1) ---

    @Test
    fun resolutionOverWidth_isRejected() {
        val decision = RemoteRenderAdmissionPolicy.decide(
            format = AndroidRemoteVideoFormats.H264,
            width = 1921,
            height = 1080,
            frameRate = 60
        )
        val reject = decision as RemoteRenderAdmissionPolicy.Decision.Reject
        assertEquals(
            RemoteRenderAdmissionPolicy.RejectionReason.RESOLUTION_OVER_LIMIT,
            reject.reason
        )
        assertEquals(1921, reject.width)
        assertEquals(1080, reject.height)
    }

    @Test
    fun resolutionOverHeight_isRejected() {
        val decision = RemoteRenderAdmissionPolicy.decide(
            format = AndroidRemoteVideoFormats.HEVC,
            width = 1920,
            height = 1081,
            frameRate = 60
        )
        val reject = decision as RemoteRenderAdmissionPolicy.Decision.Reject
        assertEquals(
            RemoteRenderAdmissionPolicy.RejectionReason.RESOLUTION_OVER_LIMIT,
            reject.reason
        )
    }

    @Test
    fun typical4kStream_isRejected() {
        val decision = RemoteRenderAdmissionPolicy.decide(
            format = AndroidRemoteVideoFormats.HEVC,
            width = 3840,
            height = 2160,
            frameRate = 60
        )
        assertTrue(decision is RemoteRenderAdmissionPolicy.Decision.Reject)
        assertEquals(
            RemoteRenderAdmissionPolicy.RejectionReason.RESOLUTION_OVER_LIMIT,
            (decision as RemoteRenderAdmissionPolicy.Decision.Reject).reason
        )
    }

    // --- frame-rate admission (R6.1) ---

    @Test
    fun frameRateOverLimit_isRejected() {
        val decision = RemoteRenderAdmissionPolicy.decide(
            format = AndroidRemoteVideoFormats.H264,
            width = 1920,
            height = 1080,
            frameRate = 61
        )
        val reject = decision as RemoteRenderAdmissionPolicy.Decision.Reject
        assertEquals(
            RemoteRenderAdmissionPolicy.RejectionReason.FRAME_RATE_OVER_LIMIT,
            reject.reason
        )
        assertEquals(61, reject.frameRate)
    }

    @Test
    fun frameRate120_isRejected() {
        val decision = RemoteRenderAdmissionPolicy.decide(
            format = AndroidRemoteVideoFormats.HEVC,
            width = 1280,
            height = 720,
            frameRate = 120
        )
        assertTrue(decision is RemoteRenderAdmissionPolicy.Decision.Reject)
        assertEquals(
            RemoteRenderAdmissionPolicy.RejectionReason.FRAME_RATE_OVER_LIMIT,
            (decision as RemoteRenderAdmissionPolicy.Decision.Reject).reason
        )
    }

    // --- boundaries ---

    @Test
    fun exactBoundary_1920x1080At60_isAdmitted() {
        assertEquals(
            RemoteRenderAdmissionPolicy.Decision.Admit,
            RemoteRenderAdmissionPolicy.decide(
                format = AndroidRemoteVideoFormats.H264,
                width = RemoteRenderAdmissionPolicy.MAX_WIDTH,
                height = RemoteRenderAdmissionPolicy.MAX_HEIGHT,
                frameRate = RemoteRenderAdmissionPolicy.MAX_FRAME_RATE
            )
        )
    }

    @Test
    fun justOverEachBoundary_isRejected() {
        // 1921 wide
        assertTrue(
            RemoteRenderAdmissionPolicy.decide(
                AndroidRemoteVideoFormats.H264,
                RemoteRenderAdmissionPolicy.MAX_WIDTH + 1,
                RemoteRenderAdmissionPolicy.MAX_HEIGHT,
                RemoteRenderAdmissionPolicy.MAX_FRAME_RATE
            ) is RemoteRenderAdmissionPolicy.Decision.Reject
        )
        // 1081 tall
        assertTrue(
            RemoteRenderAdmissionPolicy.decide(
                AndroidRemoteVideoFormats.H264,
                RemoteRenderAdmissionPolicy.MAX_WIDTH,
                RemoteRenderAdmissionPolicy.MAX_HEIGHT + 1,
                RemoteRenderAdmissionPolicy.MAX_FRAME_RATE
            ) is RemoteRenderAdmissionPolicy.Decision.Reject
        )
        // 61 fps
        assertTrue(
            RemoteRenderAdmissionPolicy.decide(
                AndroidRemoteVideoFormats.H264,
                RemoteRenderAdmissionPolicy.MAX_WIDTH,
                RemoteRenderAdmissionPolicy.MAX_HEIGHT,
                RemoteRenderAdmissionPolicy.MAX_FRAME_RATE + 1
            ) is RemoteRenderAdmissionPolicy.Decision.Reject
        )
    }

    @Test
    fun unsupportedCodecTakesPrecedenceOverOverLimit() {
        // An unrenderable codec is rejected as UnsupportedCodec even if it is also over the limits:
        // there is nothing to render, so the codec reason is the actionable one.
        val decision = RemoteRenderAdmissionPolicy.decide(
            format = "vp9",
            width = 4096,
            height = 2160,
            frameRate = 120
        )
        assertEquals(RemoteRenderAdmissionPolicy.Decision.UnsupportedCodec("vp9"), decision)
    }
}
