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
    fun combinedWithHeader(): ByteArray = combinedWithHeader(MAX_CIPHERTEXT_BYTES_APPLICATION)

    internal fun combinedWithHeaderForHandshake(): ByteArray =
        combinedWithHeader(MAX_CIPHERTEXT_BYTES_HANDSHAKE)

    private fun combinedWithHeader(maximumCiphertextLength: Int): ByteArray {
        val totalByteCount = validateWireShape(
            version = version,
            encapsulatedKeyLength = encapsulatedKey.size,
            nonceLength = nonce.size,
            ciphertextLength = ciphertext.size,
            tagLength = tag.size,
            maximumCiphertextLength = maximumCiphertextLength
        )
        val out = ByteBuffer.allocate(totalByteCount)
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
        private const val HEADER_SIZE = 17
        private const val MAX_ENCAPSULATED_KEY_BYTES = 4_096
        private const val MAX_CIPHERTEXT_BYTES_HANDSHAKE = 64 * 1_024
        private const val MAX_CIPHERTEXT_BYTES_APPLICATION = 256 * 1_024

        fun parse(combined: ByteArray, isHandshake: Boolean = true): P2PHPKESealedBox {
            require(combined.size >= HEADER_SIZE) { "Data too short for HPKE header" }
            require(combined[0] == 0x48.toByte() && combined[1] == 0x50.toByte() && combined[2] == 0x4B.toByte() && combined[3] == 0x45.toByte()) {
                "HPKE magic mismatch"
            }
            val version = combined[4].toInt() and 0xFF

            val bb = ByteBuffer.wrap(combined).order(ByteOrder.LITTLE_ENDIAN)
            bb.position(5)
            val suiteWireId = bb.short.toUShort()
            bb.short // flags
            val encLen = bb.short.toInt() and 0xFFFF
            val nonceLen = bb.get().toInt() and 0xFF
            val tagLen = bb.get().toInt() and 0xFF
            val ctLen = bb.int

            val expectedTotal = validateWireShape(
                version = version,
                encapsulatedKeyLength = encLen,
                nonceLength = nonceLen,
                ciphertextLength = ctLen,
                tagLength = tagLen,
                maximumCiphertextLength = if (isHandshake) {
                    MAX_CIPHERTEXT_BYTES_HANDSHAKE
                } else {
                    MAX_CIPHERTEXT_BYTES_APPLICATION
                }
            )
            require(combined.size == expectedTotal) { "length mismatch: expected=$expectedTotal actual=${combined.size}" }

            var off = HEADER_SIZE
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

        private fun validateWireShape(
            version: Int,
            encapsulatedKeyLength: Int,
            nonceLength: Int,
            ciphertextLength: Int,
            tagLength: Int,
            maximumCiphertextLength: Int
        ): Int {
            require(version == 1 || version == 2) { "Unsupported HPKESealedBox version: $version" }
            require(encapsulatedKeyLength in 0..MAX_ENCAPSULATED_KEY_BYTES) {
                "encLen out of range: $encapsulatedKeyLength"
            }
            if (version == 1) {
                require(nonceLength == 12) { "invalid nonceLen: $nonceLength" }
                require(tagLength == 16) { "invalid tagLen: $tagLength" }
            } else {
                require(nonceLength == 0) { "invalid nonceLen: $nonceLength" }
                require(tagLength == 0) { "invalid tagLen: $tagLength" }
            }
            require(ciphertextLength in 0..maximumCiphertextLength) {
                "ctLen out of range: $ciphertextLength"
            }
            val totalByteCount = HEADER_SIZE.toLong() +
                encapsulatedKeyLength.toLong() +
                nonceLength.toLong() +
                ciphertextLength.toLong() +
                tagLength.toLong()
            require(totalByteCount <= Int.MAX_VALUE.toLong()) {
                "HPKESealedBox total length overflow: $totalByteCount"
            }
            return totalByteCount.toInt()
        }
    }
}
