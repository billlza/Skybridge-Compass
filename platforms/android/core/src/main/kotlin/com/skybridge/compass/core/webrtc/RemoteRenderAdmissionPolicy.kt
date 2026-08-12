package com.skybridge.compass.core.webrtc

/**
 * Pure, Android-free render-admission policy for the remote-desktop viewer.
 *
 * Implements the viewer-side admission gate for Requirements 6.1 and 6.11:
 * - R6.1: the viewer supports frame streams up to 1920x1080 and up to 60 fps. A stream whose
 *   resolution exceeds 1920x1080 OR whose (advertised/target) frame rate exceeds 60 fps is REFUSED
 *   and an over-limit notice is surfaced to the UI — the frame is not silently dropped.
 * - R6.11: if the incoming frame's codec is not a renderable format (i.e. not H.264/HEVC for the
 *   MediaCodec video path, and not one of the supported static-image formats handled by the image
 *   path), rendering stops and an "unsupported codec" reason is surfaced. A separate
 *   [RemoteViewerStatus.DecoderError] with cause [RemoteViewerStatus.DecoderError.Cause.DECODER_FAILURE]
 *   is surfaced by the decoder itself when `MediaCodec` initialization/decoding throws.
 *
 * This object holds no Android dependencies so the admission decision is unit-testable without a
 * `MediaCodec`. Both viewer paths (the WebRTC path in `RemoteControlViewModel` and the LAN path in
 * `MacRemoteControlClient`) route their admission decision through [decide].
 *
 * Note on JPEG / static images: R6.11's codec admission targets the video decoder path (H.264/HEVC
 * via `MediaCodec`). The existing viewer also renders static images (JPEG/PNG/WebP/HEIF/AVIF) via a
 * separate image path; those must keep working (existing successful-render behavior is preserved),
 * so they are treated as renderable here. Only genuinely unrenderable/unknown codecs (e.g. an
 * unknown/unsupported video codec, or a null/undetectable format) are rejected as
 * [Decision.UnsupportedCodec].
 */
object RemoteRenderAdmissionPolicy {
    /** Maximum supported render width (inclusive). */
    const val MAX_WIDTH: Int = 1920

    /** Maximum supported render height (inclusive). */
    const val MAX_HEIGHT: Int = 1080

    /** Maximum supported frame rate in fps (inclusive). */
    const val MAX_FRAME_RATE: Int = 60

    enum class RejectionReason {
        /** Resolution exceeds [MAX_WIDTH] x [MAX_HEIGHT]. */
        RESOLUTION_OVER_LIMIT,

        /** Frame rate exceeds [MAX_FRAME_RATE] fps. */
        FRAME_RATE_OVER_LIMIT
    }

    sealed interface Decision {
        /** The stream is within limits and its codec is renderable; render it. */
        data object Admit : Decision

        /** The stream is over the resolution or frame-rate limit; refuse and present an over-limit notice. */
        data class Reject(
            val reason: RejectionReason,
            val width: Int,
            val height: Int,
            val frameRate: Int
        ) : Decision

        /** The frame's codec is not renderable; stop rendering and present an unsupported-codec reason. */
        data class UnsupportedCodec(val format: String?) : Decision
    }

    /**
     * A format is renderable if it is a supported video codec (H.264/HEVC, decoded by `MediaCodec`)
     * or a supported static-image format (decoded by the image path). See the class note on JPEG.
     */
    fun isRenderableFormat(format: String?): Boolean =
        AndroidRemoteVideoFormats.isVideoFormat(format) ||
            AndroidRemoteVideoFormats.isStaticImageFormat(format)

    /**
     * Decide whether a frame stream may be rendered.
     *
     * [format] is the already-normalized format (see [AndroidRemoteVideoFormats.normalizeIncomingFormat]);
     * `null` means the format could not be recognized. [width]/[height] are the frame dimensions and
     * [frameRate] is the advertised/target frame rate of the stream (fps).
     *
     * Precedence: an unrenderable codec is rejected first (there is nothing to render), then the
     * resolution limit, then the frame-rate limit. At exactly 1920x1080 @ 60 fps a renderable codec
     * is admitted; 1921 wide, 1081 tall, or 61 fps is rejected.
     */
    fun decide(format: String?, width: Int, height: Int, frameRate: Int): Decision {
        if (!isRenderableFormat(format)) {
            return Decision.UnsupportedCodec(format)
        }
        if (width > MAX_WIDTH || height > MAX_HEIGHT) {
            return Decision.Reject(RejectionReason.RESOLUTION_OVER_LIMIT, width, height, frameRate)
        }
        if (frameRate > MAX_FRAME_RATE) {
            return Decision.Reject(RejectionReason.FRAME_RATE_OVER_LIMIT, width, height, frameRate)
        }
        return Decision.Admit
    }
}

/**
 * UI-facing status of a remote-desktop viewer, surfaced as a `StateFlow` from both viewer paths so
 * the screen can present admission/decoder errors instead of silently dropping frames (R6.1, R6.11).
 */
sealed interface RemoteViewerStatus {
    /** No active render decision yet (initial / after teardown). */
    data object Idle : RemoteViewerStatus

    /** A frame within limits with a renderable codec is being rendered. */
    data object Rendering : RemoteViewerStatus

    /** The incoming stream is over the resolution or frame-rate limit and was refused (R6.1). */
    data class OverLimit(
        val reason: RemoteRenderAdmissionPolicy.RejectionReason,
        val width: Int,
        val height: Int,
        val frameRate: Int
    ) : RemoteViewerStatus

    /** Rendering stopped because the codec is unsupported or the decoder failed (R6.11). */
    data class DecoderError(
        val cause: Cause,
        val detail: String? = null
    ) : RemoteViewerStatus {
        enum class Cause {
            /** The frame's codec is not H.264/HEVC and not a supported static image. */
            UNSUPPORTED_CODEC,

            /** `MediaCodec` initialization or decoding threw; decode resources are released. */
            DECODER_FAILURE
        }
    }

    /**
     * No frame has arrived for [RemoteFrameWatchdogPolicy.NO_FRAME_INTERRUPT_MS] while the session is
     * established (R6.13). The picture is interrupted but the LAST FRAME IS RETAINED on screen; the
     * UI overlays an interrupted notice.
     */
    data object Interrupted : RemoteViewerStatus

    /**
     * The single allowed reconnect attempt (R6.13) is in progress after an interruption. The last
     * frame is still retained while the transport re-establishes.
     */
    data object Reconnecting : RemoteViewerStatus

    /**
     * The session has ended and disconnect cleanup ran (R6.9 / R6.13): the decoder is released, the
     * last frame is cleared to a placeholder, injection is terminated and any still-running capture
     * foreground service is stopped.
     */
    data object SessionEnded : RemoteViewerStatus
}
