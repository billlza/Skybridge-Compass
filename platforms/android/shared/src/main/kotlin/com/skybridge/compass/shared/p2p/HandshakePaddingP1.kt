package com.skybridge.compass.shared.p2p

import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Pro release HandshakePadding (SBP1):
 * magic "SBP1" || u32(actualLen, big-endian) || payload || randomPadding...
 *
 * NOTE: Padding is outside transcript; unwrap before decoding.
 */
object HandshakePaddingP1 {
    private val MAGIC = byteArrayOf(0x53, 0x42, 0x50, 0x31) // "SBP1"

    fun wrap(payload: ByteArray): ByteArray {
        // Android side: keep minimal wrapper (no bucket sizing); receiver will still unwrap.
        val headerLen = 8
        val out = ByteArray(headerLen + payload.size)
        System.arraycopy(MAGIC, 0, out, 0, 4)
        ByteBuffer.wrap(out, 4, 4).order(ByteOrder.BIG_ENDIAN).putInt(payload.size)
        System.arraycopy(payload, 0, out, headerLen, payload.size)
        return out
    }

    fun unwrapIfNeeded(data: ByteArray): ByteArray {
        if (data.size < 8) return data
        if (!data.copyOfRange(0, 4).contentEquals(MAGIC)) return data
        val actualLen = ByteBuffer.wrap(data, 4, 4).order(ByteOrder.BIG_ENDIAN).int
        if (actualLen < 0) return data
        val start = 8
        val end = start + actualLen
        if (end > data.size) return data
        return data.copyOfRange(start, end)
    }
}


