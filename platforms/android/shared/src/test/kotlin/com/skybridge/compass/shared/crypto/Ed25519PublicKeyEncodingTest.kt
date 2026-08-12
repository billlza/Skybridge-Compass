package com.skybridge.compass.shared.crypto

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.security.Provider

class Ed25519PublicKeyEncodingTest {
    @Test
    fun productionVerifierAcceptsRfc8032EmptyMessageVectorAndRejectsTampering() {
        val publicKey = hex(
            "d75a980182b10ab7d54bfed3c964073a" +
                "0ee172f3daa62325af021a68f707511a"
        )
        val signature = hex(
            "e5564300c360ac729086e2cc806e828a" +
                "84877f1eb8e5d974d873e06522490155" +
                "5fb8821590a33bacc61e39701cf9b46b" +
                "d25bf5f0595bbe24655141438e7a100b"
        )
        assertTrue(Ed25519SoftwareVerifier.verify(ByteArray(0), signature, publicKey))
        assertFalse(
            Ed25519SoftwareVerifier.verify(
                message = ByteArray(0),
                signature = signature.copyOf().also { it[0] = (it[0].toInt() xor 1).toByte() },
                rawPublicKey = publicKey
            )
        )
    }

    @Test
    fun productionVerifierRejectsInvalidKeyAndSignatureLengthsExplicitly() {
        val invalidKey = assertThrows(
            Ed25519SoftwareVerifier.Failure.InvalidInputLength::class.java
        ) {
            Ed25519SoftwareVerifier.verify(ByteArray(0), ByteArray(64), ByteArray(31))
        }
        assertTrue(invalidKey.message.orEmpty().contains("public key"))

        val invalidSignature = assertThrows(
            Ed25519SoftwareVerifier.Failure.InvalidInputLength::class.java
        ) {
            Ed25519SoftwareVerifier.verify(ByteArray(0), ByteArray(63), ByteArray(32))
        }
        assertTrue(invalidSignature.message.orEmpty().contains("signature"))
    }

    @Test
    fun providerAbsenceIsTypedAndNeverReportedAsABadSignature() {
        val failure = assertThrows(
            Ed25519SoftwareVerifier.Failure.SoftwareProviderUnavailable::class.java
        ) {
            Ed25519SoftwareVerifier.verifyWithCatalog(
                message = ByteArray(0),
                signature = ByteArray(64),
                rawPublicKey = ByteArray(32),
                providerCatalog = Ed25519SoftwareVerifier.ProviderCatalog { emptyList() }
            )
        }

        assertTrue(failure.message.orEmpty().contains("non-AndroidKeyStore"))
    }

    @Test
    fun androidKeyStoreIsNeverAcceptedAsTheRemoteKeyVerificationProvider() {
        val androidKeyStore = object : Provider("AndroidKeyStore", 1.0, "test-only provider") {}

        assertThrows(Ed25519SoftwareVerifier.Failure.SoftwareProviderUnavailable::class.java) {
            Ed25519SoftwareVerifier.verifyWithCatalog(
                message = ByteArray(0),
                signature = ByteArray(64),
                rawPublicKey = ByteArray(32),
                providerCatalog = Ed25519SoftwareVerifier.ProviderCatalog { listOf(androidKeyStore) }
            )
        }
    }

    @Test
    fun bundledProviderInitializationFailureAllowsInstalledProviderFallback() {
        assertNull(
            Ed25519SoftwareVerifier.constructOptionalBundledProvider {
                throw IllegalStateException("synthetic provider construction failure")
            }
        )
        assertNull(
            Ed25519SoftwareVerifier.constructOptionalBundledProvider {
                throw NoClassDefFoundError("synthetic provider linkage failure")
            }
        )
        assertThrows(OutOfMemoryError::class.java) {
            Ed25519SoftwareVerifier.constructOptionalBundledProvider {
                throw OutOfMemoryError("must not be swallowed")
            }
        }
    }

    @Test
    fun rfc8410WrapperPreservesEveryRawPublicKeyBit() {
        val raw = ByteArray(32) { index -> (index * 7 + 3).toByte() }.also {
            it[31] = 0x7f
        }
        val encoded = Ed25519PublicKeyEncoding.toRfc8410SubjectPublicKeyInfo(raw)

        assertArrayEquals(raw, encoded.takeLast(32).toByteArray())
        assertArrayEquals(
            hex("302a300506032b6570032100"),
            encoded.copyOfRange(0, encoded.size - raw.size)
        )
    }

    private fun hex(value: String): ByteArray {
        require(value.length % 2 == 0)
        return ByteArray(value.length / 2) { index ->
            value.substring(index * 2, index * 2 + 2).toInt(16).toByte()
        }
    }
}
