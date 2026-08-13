package com.skybridge.compass.shared.p2p

import okio.Buffer
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Pro release TrafficPadding.swift (SBP2) compatible padding for post-handshake traffic.
 *
 * Unwrap is always supported so we can interop with Apple when padding is enabled there.
 * TX wrap is now implemented behind a feature flag ([txPaddingEnabled], default off) that
 * mirrors the canon's "wrap-when-enabled" contract: when off, [wrapIfEnabled] returns the
 * payload unchanged so the existing interop path is byte-for-byte unaffected; when on, it
 * emits SBP2 framing (rounding the wrapped size up to a coarse [PADDING_BUCKET] bucket to
 * blunt length-based traffic analysis), which the peer's [unwrapIfNeeded] strips
 * transparently.
 */
object TrafficPaddingP2 {
    // "SBP2"
    private val MAGIC = "SBP2".encodeToByteArray()
    const val HEADER_BYTES: Int = 4 + 4 // magic + u32 actualLen (big-endian)

    /** Coarse padding bucket (bytes) used to quantize wrapped frame sizes. */
    const val PADDING_BUCKET: Int = 256

    /**
     * TX padding feature flag. Default off, matching the canon flag default so that
     * enabling it is an explicit, opt-in deployment decision and the LAN interop path
     * stays unchanged until both ends agree to pad. Volatile so a runtime toggle is
     * visible across threads.
     */
    @Volatile
    var txPaddingEnabled: Boolean = false

    fun wrapIfEnabled(payload: ByteArray, label: String? = null): ByteArray {
        if (!txPaddingEnabled) return payload
        // Round the framed size up to the next padding bucket so distinct payload
        // lengths collapse into a small set of observable sizes.
        val framed = HEADER_BYTES + payload.size
        val bucketed = ((framed + PADDING_BUCKET - 1) / PADDING_BUCKET) * PADDING_BUCKET
        return wrapToLength(payload, bucketed)
    }

    fun unwrapIfNeeded(data: ByteArray, label: String? = null): ByteArray {
        if (data.size < HEADER_BYTES) return data
        if (!data.copyOfRange(0, 4).contentEquals(MAGIC)) return data

        val bb = ByteBuffer.wrap(data).order(ByteOrder.BIG_ENDIAN)
        bb.position(4)
        val actualLen = bb.int
        if (actualLen < 0 || actualLen > data.size - HEADER_BYTES) return data
        return data.copyOfRange(HEADER_BYTES, HEADER_BYTES + actualLen)
    }

    /**
     * Optional future support: force-wrap to an exact total length for testing.
     */
    fun wrapToLength(payload: ByteArray, totalLen: Int): ByteArray {
        val minLen = HEADER_BYTES + payload.size
        val target = maxOf(minLen, totalLen)
        val buf = Buffer()
        buf.write(MAGIC)
        buf.writeInt(payload.size) // big-endian
        buf.write(payload)
        val pad = (target - buf.size).toInt()
        if (pad > 0) buf.write(ByteArray(pad))
        return buf.readByteArray()
    }
}

