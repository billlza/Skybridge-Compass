package com.skybridge.compass.remotecontrol.host

import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Video codec selectable for the Android host-side capture pipeline.
 *
 * Values map to the MediaCodec MIME strings and to the wire `format` token reused by the existing
 * `ScreenData.format` field ("h264" / "hevc"). No new wire field is introduced here.
 */
enum class HostVideoCodec(val mimeType: String, val wireFormat: String) {
    H264("video/avc", "h264"),
    HEVC("video/hevc", "hevc");

    companion object {
        /**
         * Parse a requested codec token (case-insensitive). Accepts the common aliases
         * "h264"/"avc" and "hevc"/"h265". Returns `null` when the token is unrecognised so the
         * caller can apply its own default.
         */
        fun parse(token: String?): HostVideoCodec? = when (token?.trim()?.lowercase()) {
            "h264", "avc", "video/avc" -> H264
            "hevc", "h265", "video/hevc" -> HEVC
            else -> null
        }
    }
}

/**
 * Pure, framework-free capture parameter plan for the Android remote-desktop host.
 *
 * Mirrors the viewer-side render admission clamps (R6.1) and enforces the host limits (R6.5/R6.6):
 * frame rate clamped to [15, 60] fps and resolution clamped to <= 1920x1080 while preserving aspect
 * ratio when downscaling. Contains no Android dependencies so it is fully unit-testable without a
 * device.
 */
data class AndroidRemoteHostStreamPlan(
    val width: Int,
    val height: Int,
    val frameRate: Int,
    val codec: HostVideoCodec,
    val bitRateBitsPerSecond: Int,
    val keyFrameIntervalSeconds: Int,
) {
    init {
        require(width in MIN_DIMENSION..MAX_WIDTH) { "width out of range: $width" }
        require(height in MIN_DIMENSION..MAX_HEIGHT) { "height out of range: $height" }
        require(frameRate in MIN_FPS..MAX_FPS) { "frameRate out of range: $frameRate" }
        require(width % 2 == 0 && height % 2 == 0) { "dimensions must be even: ${width}x$height" }
    }

    companion object {
        const val MIN_FPS: Int = 15
        const val MAX_FPS: Int = 60
        const val MAX_WIDTH: Int = 1920
        const val MAX_HEIGHT: Int = 1080
        const val MIN_DIMENSION: Int = 2
        const val DEFAULT_KEY_FRAME_INTERVAL_SECONDS: Int = 2

        /** Bits-per-pixel-per-frame heuristic used to derive a sane default bitrate. */
        private const val BITS_PER_PIXEL_PER_FRAME: Double = 0.12
        private const val MIN_BITRATE: Int = 500_000
        private const val MAX_BITRATE: Int = 20_000_000

        /**
         * Build a clamped plan from requested capture parameters.
         *
         * @param requestedWidth source width in pixels (e.g. the display width).
         * @param requestedHeight source height in pixels.
         * @param requestedFrameRate desired frame rate; clamped into [15, 60].
         * @param requestedCodec desired codec token; falls back to the best supported codec.
         * @param supportedCodecs codecs the local encoder can produce (defaults to H.264 only, the
         *   universally-available baseline).
         */
        fun from(
            requestedWidth: Int,
            requestedHeight: Int,
            requestedFrameRate: Int,
            requestedCodec: String? = null,
            supportedCodecs: Set<HostVideoCodec> = setOf(HostVideoCodec.H264),
        ): AndroidRemoteHostStreamPlan {
            val (width, height) = clampResolution(requestedWidth, requestedHeight)
            val frameRate = clampFrameRate(requestedFrameRate)
            val codec = selectCodec(requestedCodec, supportedCodecs)
            val bitRate = defaultBitRate(width, height, frameRate)
            return AndroidRemoteHostStreamPlan(
                width = width,
                height = height,
                frameRate = frameRate,
                codec = codec,
                bitRateBitsPerSecond = bitRate,
                keyFrameIntervalSeconds = DEFAULT_KEY_FRAME_INTERVAL_SECONDS,
            )
        }

        /** Clamp frame rate into the allowed [15, 60] range. */
        fun clampFrameRate(requested: Int): Int = requested.coerceIn(MIN_FPS, MAX_FPS)

        /**
         * Clamp resolution to fit within [MAX_WIDTH] x [MAX_HEIGHT], preserving the source aspect
         * ratio when downscaling. Returned dimensions are always even and never exceed the caps.
         */
        fun clampResolution(requestedWidth: Int, requestedHeight: Int): Pair<Int, Int> {
            val srcW = requestedWidth.coerceAtLeast(MIN_DIMENSION)
            val srcH = requestedHeight.coerceAtLeast(MIN_DIMENSION)
            if (srcW <= MAX_WIDTH && srcH <= MAX_HEIGHT) {
                return makeEven(srcW, MAX_WIDTH) to makeEven(srcH, MAX_HEIGHT)
            }
            val scale = min(
                MAX_WIDTH.toDouble() / srcW.toDouble(),
                MAX_HEIGHT.toDouble() / srcH.toDouble(),
            )
            val scaledW = (srcW * scale).roundToInt().coerceIn(MIN_DIMENSION, MAX_WIDTH)
            val scaledH = (srcH * scale).roundToInt().coerceIn(MIN_DIMENSION, MAX_HEIGHT)
            return makeEven(scaledW, MAX_WIDTH) to makeEven(scaledH, MAX_HEIGHT)
        }

        /**
         * Select a codec: honour the requested token when the local encoder supports it, otherwise
         * prefer HEVC when available, then fall back to H.264.
         */
        fun selectCodec(requested: String?, supportedCodecs: Set<HostVideoCodec>): HostVideoCodec {
            val available = if (supportedCodecs.isEmpty()) setOf(HostVideoCodec.H264) else supportedCodecs
            val parsed = HostVideoCodec.parse(requested)
            if (parsed != null && parsed in available) return parsed
            return when {
                HostVideoCodec.HEVC in available -> HostVideoCodec.HEVC
                else -> HostVideoCodec.H264
            }
        }

        private fun defaultBitRate(width: Int, height: Int, frameRate: Int): Int {
            val raw = width.toLong() * height.toLong() * frameRate.toLong() * BITS_PER_PIXEL_PER_FRAME
            return raw.toLong().coerceIn(MIN_BITRATE.toLong(), MAX_BITRATE.toLong()).toInt()
        }

        /** Round down to the nearest even value, keeping it within [MIN_DIMENSION, cap]. */
        private fun makeEven(value: Int, cap: Int): Int {
            val bounded = value.coerceIn(MIN_DIMENSION, cap)
            val even = bounded - (bounded % 2)
            return even.coerceAtLeast(MIN_DIMENSION)
        }
    }
}
