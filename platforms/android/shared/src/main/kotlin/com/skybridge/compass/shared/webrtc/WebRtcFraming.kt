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
    private const val MAX_FRAME_BYTES = 8_000_000

    fun frame(payload: ByteArray): ByteArray {
        val bb = ByteBuffer.allocate(4 + payload.size).order(ByteOrder.BIG_ENDIAN)
        bb.putInt(payload.size)
        bb.put(payload)
        return bb.array()
    }

    fun deframe(buffer: ByteArray): List<ByteArray> {
        require(buffer.isEmpty() || buffer.size >= 4) {
            "Incomplete WebRTC frame header: ${buffer.size} byte(s)"
        }
        val out = ArrayList<ByteArray>()
        var off = 0
        while (off + 4 <= buffer.size) {
            val len = ByteBuffer.wrap(buffer, off, 4).order(ByteOrder.BIG_ENDIAN).int
            require(len in 0..MAX_FRAME_BYTES) {
                "Invalid WebRTC frame length: $len"
            }
            require(off + 4 + len <= buffer.size) {
                "Incomplete WebRTC frame payload: expected=$len available=${buffer.size - off - 4}"
            }
            out.add(buffer.copyOfRange(off + 4, off + 4 + len))
            off += 4 + len
        }
        require(off == buffer.size) {
            "Trailing bytes after WebRTC frame stream: ${buffer.size - off}"
        }
        return out
    }
}

