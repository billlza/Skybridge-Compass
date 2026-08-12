package com.skybridge.compass.shared.p2p

import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class P2PHPKESealedBoxTest {

    @Test
    fun canonicalV1AndV2ShapesRoundTrip() {
        listOf(
            box(version = 1, nonceLength = 12, tagLength = 16),
            box(version = 2, nonceLength = 0, tagLength = 0)
        ).forEach { expected ->
            val decoded = P2PHPKESealedBox.parse(expected.combinedWithHeader())

            assertEquals(expected.version, decoded.version)
            assertEquals(expected.suiteWireId, decoded.suiteWireId)
            assertArrayEquals(expected.encapsulatedKey, decoded.encapsulatedKey)
            assertArrayEquals(expected.nonce, decoded.nonce)
            assertArrayEquals(expected.ciphertext, decoded.ciphertext)
            assertArrayEquals(expected.tag, decoded.tag)
        }
    }

    @Test
    fun encoderRejectsAllNonCanonicalVersionAndNonceTagShapes() {
        val invalid = listOf(
            box(version = 1, nonceLength = 0, tagLength = 0),
            box(version = 2, nonceLength = 12, tagLength = 0),
            box(version = 2, nonceLength = 0, tagLength = 16),
            box(version = 2, nonceLength = 12, tagLength = 16),
            box(version = 3, nonceLength = 0, tagLength = 0)
        )

        invalid.forEach { value ->
            assertThrows(IllegalArgumentException::class.java) {
                value.combinedWithHeader()
            }
        }
    }

    @Test
    fun encoderRejectsEncapsulationAndApplicationCiphertextBoundsBeforeAllocation() {
        assertThrows(IllegalArgumentException::class.java) {
            box(version = 2, nonceLength = 0, tagLength = 0, encapsulatedKeyLength = 4_097)
                .combinedWithHeader()
        }
        assertThrows(IllegalArgumentException::class.java) {
            box(
                version = 2,
                nonceLength = 0,
                tagLength = 0,
                ciphertextLength = 256 * 1_024 + 1
            ).combinedWithHeader()
        }
    }

    @Test
    fun parserRejectsV2NonceTagAliases() {
        listOf(
            rawBox(version = 2, nonceLength = 12, tagLength = 0),
            rawBox(version = 2, nonceLength = 0, tagLength = 16),
            rawBox(version = 2, nonceLength = 12, tagLength = 16)
        ).forEach { wire ->
            assertThrows(IllegalArgumentException::class.java) {
                P2PHPKESealedBox.parse(wire)
            }
        }
    }

    @Test
    fun parserRejectsV1WithoutExternalNonceAndTag() {
        assertThrows(IllegalArgumentException::class.java) {
            P2PHPKESealedBox.parse(rawBox(version = 1, nonceLength = 0, tagLength = 0))
        }
    }

    @Test
    fun handshakeEncoderRejectsOversizedCiphertextBeforeProducingPayloadBytes() {
        val applicationSized = box(
            version = 2,
            nonceLength = 0,
            tagLength = 0,
            ciphertextLength = 64 * 1_024 + 1
        )

        assertThrows(IllegalArgumentException::class.java) {
            applicationSized.combinedWithHeaderForHandshake()
        }
    }

    @Test
    fun parserPreservesHandshakeAndApplicationCiphertextCaps() {
        val applicationSized = box(
            version = 2,
            nonceLength = 0,
            tagLength = 0,
            ciphertextLength = 64 * 1_024 + 1
        ).combinedWithHeader()

        assertThrows(IllegalArgumentException::class.java) {
            P2PHPKESealedBox.parse(applicationSized, isHandshake = true)
        }
        assertEquals(
            64 * 1_024 + 1,
            P2PHPKESealedBox.parse(applicationSized, isHandshake = false).ciphertext.size
        )
    }

    @Test
    fun parserRejectsMagicVersionDeclaredLengthAndTruncationErrors() {
        val canonical = box(version = 2, nonceLength = 0, tagLength = 0).combinedWithHeader()
        val badMagic = canonical.copyOf().also { it[0] = 0x00 }
        val badVersion = canonical.copyOf().also { it[4] = 0x03 }
        val oversizedCiphertext = canonical.copyOf().also {
            ByteBuffer.wrap(it).order(ByteOrder.LITTLE_ENDIAN).putInt(13, 64 * 1_024 + 1)
        }
        val trailing = canonical + byteArrayOf(0x00)
        val truncated = canonical.copyOf(canonical.size - 1)

        listOf(badMagic, badVersion, oversizedCiphertext, trailing, truncated).forEach { wire ->
            assertThrows(IllegalArgumentException::class.java) {
                P2PHPKESealedBox.parse(wire)
            }
        }
    }

    private fun box(
        version: Int,
        nonceLength: Int,
        tagLength: Int,
        encapsulatedKeyLength: Int = 32,
        ciphertextLength: Int = 48
    ): P2PHPKESealedBox = P2PHPKESealedBox(
        version = version,
        suiteWireId = 0x0101u,
        encapsulatedKey = ByteArray(encapsulatedKeyLength) { it.toByte() },
        nonce = ByteArray(nonceLength) { (it + 0x20).toByte() },
        ciphertext = ByteArray(ciphertextLength) { (it + 0x40).toByte() },
        tag = ByteArray(tagLength) { (it + 0x60).toByte() }
    )

    private fun rawBox(version: Int, nonceLength: Int, tagLength: Int): ByteArray {
        val encapsulatedKey = ByteArray(2)
        val nonce = ByteArray(nonceLength)
        val ciphertext = ByteArray(3)
        val tag = ByteArray(tagLength)
        return ByteBuffer.allocate(17 + encapsulatedKey.size + nonce.size + ciphertext.size + tag.size)
            .order(ByteOrder.LITTLE_ENDIAN)
            .put(byteArrayOf(0x48, 0x50, 0x4B, 0x45))
            .put(version.toByte())
            .putShort(0x0101)
            .putShort(0)
            .putShort(encapsulatedKey.size.toShort())
            .put(nonceLength.toByte())
            .put(tagLength.toByte())
            .putInt(ciphertext.size)
            .put(encapsulatedKey)
            .put(nonce)
            .put(ciphertext)
            .put(tag)
            .array()
    }
}
