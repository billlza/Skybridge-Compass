package com.skybridge.compass.shared.p2p

import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.min

/**
 * Kotlin port of Pro release DeterministicEncoder/Decoder used for handshake capabilities/policy.
 *
 * Encoding rules (matches Pro release):
 * - Integers: little-endian
 * - String: UTF-8, prefixed with u32 length
 * - Bool: 1 byte (0x00/0x01)
 * - Array: u32 length + elements
 */
object DeterministicCodec {

    class Encoder {
        private val out = ArrayList<Byte>(256)

        fun toByteArray(): ByteArray = ByteArray(out.size).also { arr ->
            for (i in out.indices) arr[i] = out[i]
        }

        fun encodeBool(v: Boolean) {
            out += if (v) 0x01 else 0x00
        }

        fun encodeU32(v: Int) {
            val bb = ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(v)
            val a = bb.array()
            for (b in a) out += b
        }

        fun encodeString(v: String) {
            val bytes = v.toByteArray(Charsets.UTF_8)
            encodeU32(bytes.size)
            for (b in bytes) out += b
        }

        fun encodeStringArray(values: List<String>) {
            encodeU32(values.size)
            for (s in values) encodeString(s)
        }
    }

    class Decoder(private val data: ByteArray) {
        private var offset: Int = 0
        val isAtEnd: Boolean get() = offset >= data.size

        fun decodeBool(): Boolean {
            return when (val raw = decodeU8()) {
                0x00 -> false
                0x01 -> true
                else -> throw IllegalArgumentException("Invalid deterministic bool: $raw")
            }
        }

        fun decodeU32(): Int {
            require(offset + 4 <= data.size) { "Unexpected end of data" }
            val v = ByteBuffer.wrap(data, offset, 4).order(ByteOrder.LITTLE_ENDIAN).int
            offset += 4
            return v
        }

        fun decodeString(): String {
            val len = decodeU32()
            require(len >= 0 && offset + len <= data.size) { "Unexpected end of data" }
            val str = data.copyOfRange(offset, offset + len).toString(Charsets.UTF_8)
            offset += len
            return str
        }

        fun decodeStringArray(): List<String> {
            val count = decodeU32()
            require(count >= 0) { "Invalid array length" }
            val out = ArrayList<String>(min(count, 1024))
            repeat(count) { out += decodeString() }
            return out
        }

        private fun decodeU8(): Int {
            require(offset < data.size) { "Unexpected end of data" }
            return data[offset++].toInt() and 0xFF
        }
    }
}

