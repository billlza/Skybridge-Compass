package com.skybridge.compass.core.p2p

import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Binary business envelope ("SBE1") for high-rate payloads (remote desktop frames).
 *
 * Wire format (matches Swift):
 * - magic: "SBE1" (4)
 * - kind: u8 (1)  (1 = remoteDesktopFrame)
 * - timestampNs: u64 big-endian (8)
 * - payload: remaining bytes
 */
data class BusinessEnvelope(
    val kind: Int,
    val timestampNs: Long,
    val payload: ByteArray
) {
    fun encode(): ByteArray {
        val out = ByteArray(HEADER_LEN + payload.size)
        System.arraycopy(MAGIC, 0, out, 0, 4)
        out[4] = kind.toByte()
        val bb = ByteBuffer.wrap(out).order(ByteOrder.BIG_ENDIAN)
        bb.position(5)
        bb.putLong(timestampNs)
        System.arraycopy(payload, 0, out, HEADER_LEN, payload.size)
        return out
    }

    companion object {
        private val MAGIC = byteArrayOf(0x53, 0x42, 0x45, 0x31) // "SBE1"
        private const val HEADER_LEN: Int = 4 + 1 + 8

        const val KIND_REMOTE_DESKTOP_FRAME: Int = 1

        fun remoteDesktopFrame(timestampNs: Long, payload: ByteArray): BusinessEnvelope =
            BusinessEnvelope(kind = KIND_REMOTE_DESKTOP_FRAME, timestampNs = timestampNs, payload = payload)

        fun decode(data: ByteArray): BusinessEnvelope? {
            if (data.size < HEADER_LEN) return null
            if (!data.copyOfRange(0, 4).contentEquals(MAGIC)) return null
            val kind = data[4].toInt() and 0xFF
            val ts = ByteBuffer.wrap(data, 5, 8).order(ByteOrder.BIG_ENDIAN).long
            val payload = data.copyOfRange(HEADER_LEN, data.size)
            return BusinessEnvelope(kind = kind, timestampNs = ts, payload = payload)
        }
    }
}

