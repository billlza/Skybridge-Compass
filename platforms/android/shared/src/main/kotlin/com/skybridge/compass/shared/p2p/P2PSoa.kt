package com.skybridge.compass.shared.p2p

import java.security.MessageDigest

/**
 * Secure Session Overlap Avoidance (SOA) helpers.
 *
 * The optional MessageA extensions container on wire:
 * - magic "SOA1" (4 bytes)
 * - u16(lenLE)
 * - tlvBytes[len]
 *
 * The SOA TLV (type=0x0001, len=81) binds:
 * - version (1)
 * - initiatorPeerId (32)
 * - targetPeerId (32)
 * - attemptId (16)
 */
object P2PSoa {
    val CONTAINER_MAGIC: ByteArray = byteArrayOf(0x53, 0x4F, 0x41, 0x31) // "SOA1"

    const val TLV_TYPE: UShort = 0x0001u
    const val VERSION: Byte = 0x01

    const val PEER_ID_LEN: Int = 32
    const val ATTEMPT_ID_LEN: Int = 16
    const val VALUE_LEN: Int = 1 + PEER_ID_LEN + PEER_ID_LEN + ATTEMPT_ID_LEN

    data class SoaExtension(
        val version: Byte,
        val initiatorPeerId: ByteArray,
        val targetPeerId: ByteArray,
        val attemptId: ByteArray
    ) {
        init {
            require(version == VERSION) { "Unsupported SOA version: $version" }
            require(initiatorPeerId.size == PEER_ID_LEN) { "initiatorPeerId must be 32 bytes" }
            require(targetPeerId.size == PEER_ID_LEN) { "targetPeerId must be 32 bytes" }
            require(attemptId.size == ATTEMPT_ID_LEN) { "attemptId must be 16 bytes" }
        }

        fun encodeTlv(): ByteArray {
            val out = ByteArray(4 + VALUE_LEN)
            // type (u16 LE)
            out[0] = (TLV_TYPE.toInt() and 0xFF).toByte()
            out[1] = ((TLV_TYPE.toInt() ushr 8) and 0xFF).toByte()
            // len (u16 LE)
            out[2] = (VALUE_LEN and 0xFF).toByte()
            out[3] = ((VALUE_LEN ushr 8) and 0xFF).toByte()
            out[4] = version
            System.arraycopy(initiatorPeerId, 0, out, 5, PEER_ID_LEN)
            System.arraycopy(targetPeerId, 0, out, 5 + PEER_ID_LEN, PEER_ID_LEN)
            System.arraycopy(attemptId, 0, out, 5 + PEER_ID_LEN + PEER_ID_LEN, ATTEMPT_ID_LEN)
            return out
        }
    }

    fun decodeFromExtensions(raw: ByteArray): SoaExtension? {
        if (raw.isEmpty()) return null
        var offset = 0
        while (offset + 4 <= raw.size) {
            val tlvType = readU16LE(raw, offset)
            val len = readU16LE(raw, offset + 2).toInt()
            offset += 4
            if (offset + len > raw.size) return null
            if (tlvType == TLV_TYPE) {
                if (len != VALUE_LEN) return null
                val version = raw[offset]
                if (version != VERSION) return null
                val initiatorPeerId = raw.copyOfRange(offset + 1, offset + 1 + PEER_ID_LEN)
                val targetPeerId = raw.copyOfRange(offset + 1 + PEER_ID_LEN, offset + 1 + PEER_ID_LEN + PEER_ID_LEN)
                val attemptId = raw.copyOfRange(offset + VALUE_LEN - ATTEMPT_ID_LEN, offset + VALUE_LEN)
                return SoaExtension(
                    version = version,
                    initiatorPeerId = initiatorPeerId,
                    targetPeerId = targetPeerId,
                    attemptId = attemptId
                )
            }
            offset += len
        }
        return null
    }

    /**
     * Canonical peer id bytes (matches Pro release semantics).
     *
     * `peerId = SHA256(trim(lowercased(deviceIdString)))`
     */
    fun canonicalPeerIdBytes(deviceId: String): ByteArray {
        val normalized = deviceId.trim().lowercase()
        return MessageDigest.getInstance("SHA-256").digest(normalized.toByteArray(Charsets.UTF_8))
    }

    /**
     * Canonical SOA pairKey = sorted concatenation of two peer IDs.
     */
    fun pairKey(a: ByteArray, b: ByteArray): ByteArray {
        require(a.size == PEER_ID_LEN && b.size == PEER_ID_LEN) { "pairKey expects 32-byte peer IDs" }
        val (first, second) = if (compareLexUnsigned(a, b) <= 0) a to b else b to a
        return first + second
    }

    private fun readU16LE(data: ByteArray, offset: Int): UShort {
        return ((data[offset].toInt() and 0xFF) or ((data[offset + 1].toInt() and 0xFF) shl 8)).toUShort()
    }

    private fun compareLexUnsigned(a: ByteArray, b: ByteArray): Int {
        val n = minOf(a.size, b.size)
        for (i in 0 until n) {
            val ai = a[i].toInt() and 0xFF
            val bi = b[i].toInt() and 0xFF
            if (ai != bi) return ai - bi
        }
        return a.size - b.size
    }
}

