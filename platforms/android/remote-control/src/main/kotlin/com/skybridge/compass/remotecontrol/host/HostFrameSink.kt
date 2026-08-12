package com.skybridge.compass.remotecontrol.host

/**
 * A single encoded video frame produced by [AndroidRemoteHostVideoEncoder].
 *
 * These fields are exactly what a caller needs to build the existing `ScreenData` / `SCREEN_DATA`
 * wire frame (width, height, encoded bytes, timestamp, format token) — no new wire field is added.
 * Actual reverse SCREEN_DATA transmission to an Apple viewer is gated on WP-04
 * (see gaps/wire-protocol-pending.md); this type is the seam that decouples the capture→encode
 * pipeline from the (pending) transmission direction.
 */
data class HostEncodedFrame(
    val data: ByteArray,
    val width: Int,
    val height: Int,
    /** Wire `format` token: "h264" or "hevc". */
    val format: String,
    /** Presentation timestamp in microseconds. */
    val presentationTimeUs: Long,
    val isKeyFrame: Boolean,
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is HostEncodedFrame) return false
        return width == other.width &&
            height == other.height &&
            format == other.format &&
            presentationTimeUs == other.presentationTimeUs &&
            isKeyFrame == other.isKeyFrame &&
            data.contentEquals(other.data)
    }

    override fun hashCode(): Int {
        var result = data.contentHashCode()
        result = 31 * result + width
        result = 31 * result + height
        result = 31 * result + format.hashCode()
        result = 31 * result + presentationTimeUs.hashCode()
        result = 31 * result + isKeyFrame.hashCode()
        return result
    }
}

/**
 * Reason a host capture session ended, carried on the session-end notice sent to the peer.
 */
enum class HostSessionEndReason {
    /** User (or the guarded stop-hook) explicitly stopped sharing. */
    USER_STOPPED,

    /** MediaProjection authorization was denied or revoked (R6.12). */
    AUTHORIZATION_REVOKED,

    /** The remote-desktop session was torn down / disconnected (R6.9). */
    SESSION_ENDED,

    /** An unrecoverable capture/encode error occurred. */
    ERROR,
}

/**
 * The "send seam": the host pipeline pushes encoded frames and a terminal session-end notice
 * through this sink instead of talking to the transport directly.
 *
 * This keeps the capture→encode→frame pipeline fully unit-testable with a fake sink, and lets the
 * actual transmission direction remain WP-04-pending without blocking this task. Implementations
 * map [HostEncodedFrame] onto the existing `ScreenData`/`SCREEN_DATA` wire message; no new wire
 * field is introduced.
 */
interface HostFrameSink {
    /** Deliver one encoded frame toward the peer. */
    fun onEncodedFrame(frame: HostEncodedFrame)

    /** Deliver a terminal session-end notice toward the peer (R6.6). */
    fun onSessionEnd(reason: HostSessionEndReason)
}
