package com.skybridge.compass.shared.p2p

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest

/**
 * Pro release HPKESealedBox combined-with-header format.
 *
 * Header:
 *  magic(4)="HPKE" ||
 *  version(1) ||
 *  suiteWireId(2 LE) ||
 *  flags(2) ||
 *  encLen(2 LE) ||
 *  nonceLen(1) ||
 *  tagLen(1) ||
 *  ctLen(4 LE) ||
 *  encapsulatedKey || nonce || ciphertext || tag
 */
data class P2PHPKESealedBox(
    val version: Int,
    val suiteWireId: UShort,
    val encapsulatedKey: ByteArray,
    val nonce: ByteArray,
    val ciphertext: ByteArray,
    val tag: ByteArray
) {
    fun combinedWithHeader(): ByteArray {
        val headerSize = 17
        val out = ByteBuffer.allocate(headerSize + encapsulatedKey.size + nonce.size + ciphertext.size + tag.size)
            .order(ByteOrder.LITTLE_ENDIAN)
        out.put(byteArrayOf(0x48, 0x50, 0x4B, 0x45)) // "HPKE"
        out.put(version.toByte())
        out.putShort(suiteWireId.toShort())
        out.putShort(0) // flags
        out.putShort(encapsulatedKey.size.toShort())
        out.put(nonce.size.toByte())
        out.put(tag.size.toByte())
        out.putInt(ciphertext.size)
        out.put(encapsulatedKey)
        out.put(nonce)
        out.put(ciphertext)
        out.put(tag)
        return out.array()
    }

    fun sha256OfCombinedWithHeader(): ByteArray =
        MessageDigest.getInstance("SHA-256").digest(combinedWithHeader())

    companion object {
        fun parse(combined: ByteArray, isHandshake: Boolean = true): P2PHPKESealedBox {
            val headerSize = 17
            require(combined.size >= headerSize) { "Data too short for HPKE header" }
            require(combined[0] == 0x48.toByte() && combined[1] == 0x50.toByte() && combined[2] == 0x4B.toByte() && combined[3] == 0x45.toByte()) {
                "HPKE magic mismatch"
            }
            val version = combined[4].toInt() and 0xFF
            require(version == 1 || version == 2) { "Unsupported HPKESealedBox version: $version" }

            val bb = ByteBuffer.wrap(combined).order(ByteOrder.LITTLE_ENDIAN)
            bb.position(5)
            val suiteWireId = bb.short.toUShort()
            bb.short // flags
            val encLen = bb.short.toInt() and 0xFFFF
            val nonceLen = bb.get().toInt() and 0xFF
            val tagLen = bb.get().toInt() and 0xFF
            val ctLen = bb.int

            require(encLen <= 4096) { "encLen too large: $encLen" }
            if (version == 1) {
                require(nonceLen == 12) { "invalid nonceLen: $nonceLen" }
                require(tagLen == 16) { "invalid tagLen: $tagLen" }
            } else {
                require(nonceLen == 0 || nonceLen == 12) { "invalid nonceLen: $nonceLen" }
                require(tagLen == 0 || tagLen == 16) { "invalid tagLen: $tagLen" }
            }
            val maxCt = if (isHandshake) 64 * 1024 else 256 * 1024
            require(ctLen in 0..maxCt) { "ctLen too large: $ctLen" }

            val expectedTotal = headerSize + encLen + nonceLen + ctLen + tagLen
            require(combined.size == expectedTotal) { "length mismatch: expected=$expectedTotal actual=${combined.size}" }

            var off = headerSize
            val enc = combined.copyOfRange(off, off + encLen)
            off += encLen
            val nonce = combined.copyOfRange(off, off + nonceLen)
            off += nonceLen
            val ct = combined.copyOfRange(off, off + ctLen)
            off += ctLen
            val tag = combined.copyOfRange(off, off + tagLen)

            return P2PHPKESealedBox(
                version = version,
                suiteWireId = suiteWireId,
                encapsulatedKey = enc,
                nonce = nonce,
                ciphertext = ct,
                tag = tag
            )
        }
    }
}


