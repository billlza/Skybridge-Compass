package com.skybridge.compass.remotecontrol.host

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for the pure host capture parameter plan (R6.5/R6.6):
 * frame rate clamped to [15, 60], resolution clamped to <= 1920x1080 with aspect preservation, and
 * codec selection.
 */
class AndroidRemoteHostStreamPlanTest {

    @Test
    fun frameRateIsClampedToLowerBound() {
        assertEquals(15, AndroidRemoteHostStreamPlan.clampFrameRate(1))
        assertEquals(15, AndroidRemoteHostStreamPlan.clampFrameRate(14))
        assertEquals(15, AndroidRemoteHostStreamPlan.clampFrameRate(0))
    }

    @Test
    fun frameRateIsClampedToUpperBound() {
        assertEquals(60, AndroidRemoteHostStreamPlan.clampFrameRate(61))
        assertEquals(60, AndroidRemoteHostStreamPlan.clampFrameRate(240))
    }

    @Test
    fun frameRateInRangeIsUnchanged() {
        assertEquals(15, AndroidRemoteHostStreamPlan.clampFrameRate(15))
        assertEquals(30, AndroidRemoteHostStreamPlan.clampFrameRate(30))
        assertEquals(60, AndroidRemoteHostStreamPlan.clampFrameRate(60))
    }

    @Test
    fun resolutionWithinCapIsKeptButForcedEven() {
        val (w, h) = AndroidRemoteHostStreamPlan.clampResolution(1280, 720)
        assertEquals(1280, w)
        assertEquals(720, h)
    }

    @Test
    fun oddResolutionWithinCapIsRoundedToEven() {
        val (w, h) = AndroidRemoteHostStreamPlan.clampResolution(1281, 721)
        assertTrue(w % 2 == 0)
        assertTrue(h % 2 == 0)
        assertTrue(w <= AndroidRemoteHostStreamPlan.MAX_WIDTH)
        assertTrue(h <= AndroidRemoteHostStreamPlan.MAX_HEIGHT)
    }

    @Test
    fun oversizedResolutionIsClampedPreservingAspectRatio() {
        // 4K 16:9 downscaled must fit within 1920x1080 and keep 16:9.
        val (w, h) = AndroidRemoteHostStreamPlan.clampResolution(3840, 2160)
        assertTrue("width <= cap", w <= AndroidRemoteHostStreamPlan.MAX_WIDTH)
        assertTrue("height <= cap", h <= AndroidRemoteHostStreamPlan.MAX_HEIGHT)
        assertEquals(1920, w)
        assertEquals(1080, h)
    }

    @Test
    fun tallResolutionIsClampedByHeightPreservingAspect() {
        // Portrait 1080x2400 must fit within caps; height is the binding constraint.
        val (w, h) = AndroidRemoteHostStreamPlan.clampResolution(1080, 2400)
        assertTrue(w <= AndroidRemoteHostStreamPlan.MAX_WIDTH)
        assertTrue(h <= AndroidRemoteHostStreamPlan.MAX_HEIGHT)
        assertEquals(1080, h)
        // aspect ratio preserved within rounding tolerance
        val srcAspect = 1080.0 / 2400.0
        val outAspect = w.toDouble() / h.toDouble()
        assertTrue("aspect preserved", kotlin.math.abs(srcAspect - outAspect) < 0.02)
    }

    @Test
    fun ultraWideResolutionIsClampedByWidthPreservingAspect() {
        val (w, h) = AndroidRemoteHostStreamPlan.clampResolution(5120, 1440)
        assertTrue(w <= AndroidRemoteHostStreamPlan.MAX_WIDTH)
        assertTrue(h <= AndroidRemoteHostStreamPlan.MAX_HEIGHT)
        assertEquals(1920, w)
    }

    @Test
    fun codecSelectionHonoursRequestedWhenSupported() {
        val codec = AndroidRemoteHostStreamPlan.selectCodec(
            requested = "hevc",
            supportedCodecs = setOf(HostVideoCodec.H264, HostVideoCodec.HEVC),
        )
        assertEquals(HostVideoCodec.HEVC, codec)
    }

    @Test
    fun codecSelectionFallsBackWhenRequestedUnsupported() {
        val codec = AndroidRemoteHostStreamPlan.selectCodec(
            requested = "hevc",
            supportedCodecs = setOf(HostVideoCodec.H264),
        )
        assertEquals(HostVideoCodec.H264, codec)
    }

    @Test
    fun codecSelectionPrefersHevcWhenNoRequestAndSupported() {
        val codec = AndroidRemoteHostStreamPlan.selectCodec(
            requested = null,
            supportedCodecs = setOf(HostVideoCodec.H264, HostVideoCodec.HEVC),
        )
        assertEquals(HostVideoCodec.HEVC, codec)
    }

    @Test
    fun codecSelectionDefaultsToH264WhenSupportedSetEmpty() {
        val codec = AndroidRemoteHostStreamPlan.selectCodec(
            requested = "hevc",
            supportedCodecs = emptySet(),
        )
        assertEquals(HostVideoCodec.H264, codec)
    }

    @Test
    fun fromProducesFullyClampedValidPlan() {
        val plan = AndroidRemoteHostStreamPlan.from(
            requestedWidth = 3840,
            requestedHeight = 2160,
            requestedFrameRate = 120,
            requestedCodec = "h264",
        )
        assertEquals(1920, plan.width)
        assertEquals(1080, plan.height)
        assertEquals(60, plan.frameRate)
        assertEquals(HostVideoCodec.H264, plan.codec)
        assertTrue("bitrate positive", plan.bitRateBitsPerSecond > 0)
    }

    @Test
    fun fromClampsLowFrameRateUp() {
        val plan = AndroidRemoteHostStreamPlan.from(
            requestedWidth = 640,
            requestedHeight = 480,
            requestedFrameRate = 5,
        )
        assertEquals(15, plan.frameRate)
    }
}
