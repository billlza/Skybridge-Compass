package com.skybridge.compass.shared.p2p

import okio.Buffer
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Pro release TrafficPadding.swift (SBP2) compatible unwrap for post-handshake traffic.
 *
 * For now we keep wrap disabled on Android (returns payload unchanged), but we always support
 * unwrap so we can interop with Apple when padding is enabled there.
 */
object TrafficPaddingP2 {
    // "SBP2"
    private val MAGIC = "SBP2".encodeToByteArray()
    private const val HEADER_LEN = 4 + 4 // magic + u32 actualLen (big-endian)

    fun wrapIfEnabled(payload: ByteArray, label: String? = null): ByteArray {
        // Disabled by default for Android (feature flag can be added later).
        return payload
    }

    fun unwrapIfNeeded(data: ByteArray, label: String? = null): ByteArray {
        if (data.size < HEADER_LEN) return data
        if (!data.copyOfRange(0, 4).contentEquals(MAGIC)) return data

        val bb = ByteBuffer.wrap(data).order(ByteOrder.BIG_ENDIAN)
        bb.position(4)
        val actualLen = bb.int
        if (actualLen < 0 || actualLen > data.size - HEADER_LEN) return data
        return data.copyOfRange(HEADER_LEN, HEADER_LEN + actualLen)
    }

    /**
     * Optional future support: force-wrap to an exact total length for testing.
     */
    fun wrapToLength(payload: ByteArray, totalLen: Int): ByteArray {
        val minLen = HEADER_LEN + payload.size
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


