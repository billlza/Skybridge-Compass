package com.skybridge.compass.shared.p2p

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class P2PQPeriaptKemTest {
    @Test
    fun qPeriaptKemRoundTripsWhenNativeProviderIsAvailable() {
        val unavailableReason = P2PQPeriaptKem.availabilityFailureReason()
        if (unavailableReason != null) {
            assertTrue(unavailableReason.isNotBlank())
            return
        }

        val keyPair = P2PQPeriaptKem.generateKeyPair()
        assertEquals(P2PQPeriaptKem.QPERIAPT_PUBLIC_KEY_SIZE, keyPair.publicKey.size)
        assertEquals(P2PQPeriaptKem.QPERIAPT_PRIVATE_KEY_SIZE, keyPair.privateKey.size)

        val context = ascii("skybridge-qperiapt/roundtrip-test")
        val encap = P2PQPeriaptKem.encapsulate(keyPair.publicKey, context = context)
        assertEquals(P2PQPeriaptKem.QPERIAPT_CIPHERTEXT_SIZE, encap.ciphertext.size)
        assertEquals(P2PQPeriaptKem.SHARED_SECRET_SIZE, encap.sharedSecret32.size)

        val decapsulated = P2PQPeriaptKem.decapsulate(
            ciphertext = encap.ciphertext,
            privateKey = keyPair.privateKey,
            context = context
        )
        assertArrayEquals(encap.sharedSecret32, decapsulated)

        val wrongContextSecret = P2PQPeriaptKem.decapsulate(
            ciphertext = encap.ciphertext,
            privateKey = keyPair.privateKey,
            context = ascii("skybridge-qperiapt/wrong-context")
        )
        assertFalse(encap.sharedSecret32.contentEquals(wrongContextSecret))

        val corruptPrivateKey = keyPair.privateKey.copyOf()
        corruptPrivateKey[corruptPrivateKey.lastIndex] =
            (corruptPrivateKey[corruptPrivateKey.lastIndex].toInt() xor 0x01).toByte()
        assertThrows(IllegalArgumentException::class.java) {
            P2PQPeriaptKem.decapsulate(
                ciphertext = encap.ciphertext,
                privateKey = corruptPrivateKey,
                context = context
            )
        }
    }

    @Test
    fun contextBoundCombinerMatchesReferenceVectors() {
        val vectors = listOf(
            ContextBoundVector(
                suiteId = ascii("ML-KEM-768+X25519"),
                policyVersion = 1,
                ssPq = filled(0x11, 32),
                ssTrad = filled(0x22, 32),
                ctPq = filled(0x33, 32),
                pkPq = filled(0x44, 32),
                ctTrad = filled(0x11, 32),
                pkTrad = filled(0x22, 32),
                context = ascii("q-periapt/v1/ctx"),
                expectedSecretHex = "f0a32d28860bd9d8aaab4faf4c859205924b27651a68e70042abe908fef5da85"
            ),
            ContextBoundVector(
                suiteId = ascii("S"),
                policyVersion = 0,
                ssPq = filled(0x11, 32),
                ssTrad = filled(0x22, 32),
                ctPq = ByteArray(0),
                pkPq = ByteArray(0),
                ctTrad = ByteArray(0),
                pkTrad = ByteArray(0),
                context = ascii("x"),
                expectedSecretHex = "98476bc6033b9f04d50e48b2298011c25a38d3f5efe0914b18670623e576c4bc"
            ),
            ContextBoundVector(
                suiteId = ascii("ML-KEM-768+X25519"),
                policyVersion = 2,
                ssPq = filled(0x11, 32),
                ssTrad = filled(0x22, 32),
                ctPq = filled(0x42, 1088),
                pkPq = filled(0x37, 1184),
                ctTrad = filled(0x33, 32),
                pkTrad = filled(0x44, 32),
                context = ascii("handshake-transcript"),
                expectedSecretHex = "6c28e6a465773c6c7969349a2ca827792799591b94c8fa23927d18b0cb1cf9f3"
            ),
            ContextBoundVector(
                suiteId = ascii("S"),
                policyVersion = 9,
                ssPq = ascii("AB"),
                ssTrad = ascii("X"),
                ctPq = ascii("C"),
                pkPq = ascii("D"),
                ctTrad = ascii("E"),
                pkTrad = ascii("F"),
                context = ascii("ctx"),
                expectedSecretHex = "572cbe29ec15781bb54103465c551839dffbfa17346f3a679e8f483a2b1d49d6"
            ),
            ContextBoundVector(
                suiteId = ascii("S"),
                policyVersion = 9,
                ssPq = ascii("A"),
                ssTrad = ascii("BX"),
                ctPq = ascii("C"),
                pkPq = ascii("D"),
                ctTrad = ascii("E"),
                pkTrad = ascii("F"),
                context = ascii("ctx"),
                expectedSecretHex = "8fa3ad2f914b5838586f2b7f881377f26c56dd2de75b50de352dffec4ce2fcad"
            ),
            ContextBoundVector(
                suiteId = ByteArray(0),
                policyVersion = -1,
                ssPq = filled(0x11, 32),
                ssTrad = filled(0x22, 32),
                ctPq = filled(0x33, 32),
                pkPq = filled(0x44, 32),
                ctTrad = filled(0x11, 32),
                pkTrad = filled(0x22, 32),
                context = filled(0x5a, 200),
                expectedSecretHex = "043a5998baccd1462ad2e55cf14a64c58d6fca254b880f193d3fc0b18833f069"
            )
        )

        vectors.forEach { vector ->
            assertArrayEquals(hex(vector.expectedSecretHex), combine(vector))
        }
    }

    @Test
    fun contextBoundCombinerRejectsEmptyContext() {
        assertThrows(IllegalArgumentException::class.java) {
            P2PQPeriaptKem.combineContextBound(
                suiteId = "ML-KEM-768+X25519".toByteArray(Charsets.UTF_8),
                policyVersion = 1,
                ssPq = ByteArray(32) { 0x11 },
                ssTrad = ByteArray(32) { 0x22 },
                ctPq = ByteArray(32) { 0x33 },
                pkPq = ByteArray(32) { 0x44 },
                ctTrad = ByteArray(32) { 0x11 },
                pkTrad = ByteArray(32) { 0x22 },
                context = ByteArray(0)
            )
        }
    }

    @Test
    fun contextBoundCombinerSeparatesNaiveConcatenationCollisionPair() {
        val first = ContextBoundVector(
            suiteId = ascii("S"),
            policyVersion = 9,
            ssPq = ascii("AB"),
            ssTrad = ascii("X"),
            ctPq = ascii("C"),
            pkPq = ascii("D"),
            ctTrad = ascii("E"),
            pkTrad = ascii("F"),
            context = ascii("ctx"),
            expectedSecretHex = "572cbe29ec15781bb54103465c551839dffbfa17346f3a679e8f483a2b1d49d6"
        )
        val second = first.copy(
            ssPq = ascii("A"),
            ssTrad = ascii("BX"),
            expectedSecretHex = "8fa3ad2f914b5838586f2b7f881377f26c56dd2de75b50de352dffec4ce2fcad"
        )

        assertArrayEquals(naiveConcat(first), naiveConcat(second))
        assertFalse(combine(first).contentEquals(combine(second)))
    }

    @Test
    fun contextBoundCombinerBindsPolicyVersion() {
        val v1 = P2PQPeriaptKem.combineContextBound(
            suiteId = "ML-KEM-768+X25519".toByteArray(Charsets.UTF_8),
            policyVersion = 1,
            ssPq = ByteArray(32) { 0x11 },
            ssTrad = ByteArray(32) { 0x22 },
            ctPq = ByteArray(32) { 0x33 },
            pkPq = ByteArray(32) { 0x44 },
            ctTrad = ByteArray(32) { 0x11 },
            pkTrad = ByteArray(32) { 0x22 },
            context = "q-periapt/v1/ctx".toByteArray(Charsets.UTF_8)
        )
        val v2 = P2PQPeriaptKem.combineContextBound(
            suiteId = "ML-KEM-768+X25519".toByteArray(Charsets.UTF_8),
            policyVersion = 2,
            ssPq = ByteArray(32) { 0x11 },
            ssTrad = ByteArray(32) { 0x22 },
            ctPq = ByteArray(32) { 0x33 },
            pkPq = ByteArray(32) { 0x44 },
            ctTrad = ByteArray(32) { 0x11 },
            pkTrad = ByteArray(32) { 0x22 },
            context = "q-periapt/v1/ctx".toByteArray(Charsets.UTF_8)
        )

        assertFalse(v1.contentEquals(v2))
    }

    private fun hex(raw: String): ByteArray {
        require(raw.length % 2 == 0) { "hex length must be even" }
        return ByteArray(raw.length / 2) { index ->
            raw.substring(index * 2, index * 2 + 2).toInt(16).toByte()
        }
    }

    private data class ContextBoundVector(
        val suiteId: ByteArray,
        val policyVersion: Int,
        val ssPq: ByteArray,
        val ssTrad: ByteArray,
        val ctPq: ByteArray,
        val pkPq: ByteArray,
        val ctTrad: ByteArray,
        val pkTrad: ByteArray,
        val context: ByteArray,
        val expectedSecretHex: String
    )

    private fun combine(vector: ContextBoundVector): ByteArray =
        P2PQPeriaptKem.combineContextBound(
            suiteId = vector.suiteId,
            policyVersion = vector.policyVersion,
            ssPq = vector.ssPq,
            ssTrad = vector.ssTrad,
            ctPq = vector.ctPq,
            pkPq = vector.pkPq,
            ctTrad = vector.ctTrad,
            pkTrad = vector.pkTrad,
            context = vector.context
        )

    private fun naiveConcat(vector: ContextBoundVector): ByteArray =
        vector.ssPq + vector.ssTrad + vector.ctPq + vector.pkPq + vector.ctTrad + vector.pkTrad + vector.context

    private fun ascii(raw: String): ByteArray = raw.toByteArray(Charsets.UTF_8)

    private fun filled(value: Int, size: Int): ByteArray = ByteArray(size) { value.toByte() }
}
