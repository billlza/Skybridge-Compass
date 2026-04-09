package com.skybridge.compass.shared.webrtc

import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Pro release WebRTC "sendFramed": 4-byte big-endian length prefix + payload.
 *
 * WebRTC DataChannel is message-oriented, but we still follow the same framing so that both sides
 * can concatenate multiple frames and the receiver can safely deframe.
 */
object WebRtcFraming {
    fun frame(payload: ByteArray): ByteArray {
        val bb = ByteBuffer.allocate(4 + payload.size).order(ByteOrder.BIG_ENDIAN)
        bb.putInt(payload.size)
        bb.put(payload)
        return bb.array()
    }

    fun deframe(buffer: ByteArray): List<ByteArray> {
        val out = ArrayList<ByteArray>()
        var off = 0
        while (off + 4 <= buffer.size) {
            val len = ByteBuffer.wrap(buffer, off, 4).order(ByteOrder.BIG_ENDIAN).int
            if (len < 0 || len > 8_000_000) break
            if (off + 4 + len > buffer.size) break
            out.add(buffer.copyOfRange(off + 4, off + 4 + len))
            off += 4 + len
        }
        // Legacy fallback: if no frames parsed, treat whole buffer as a single frame.
        return if (out.isEmpty()) listOf(buffer) else out
    }
}


