package com.skybridge.compass.core.p2p

import com.skybridge.compass.core.webrtc.ProtocolSigningAlgorithm
import com.skybridge.compass.shared.crypto.Ed25519SoftwareVerifier
import com.skybridge.compass.shared.crypto.providers.AndroidPQCCryptoProvider
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class ProtocolIdentitySignatureVerifierTest {
    @Test
    fun ed25519UsesProductionSoftwareVerifierWithoutTouchingMlDsaProvider() = runTest {
        var mlDsaInvoked = false
        val verifier = ProtocolIdentitySignatureVerifier(
            verifyMlDsa65 = { _, _, _ ->
                mlDsaInvoked = true
                error("ML-DSA verifier must not run for Ed25519")
            }
        )

        assertTrue(
            verifier.verify(
                algorithm = ProtocolSigningAlgorithm.ED25519,
                data = ByteArray(0),
                signature = RFC8032_SIGNATURE,
                publicKey = RFC8032_PUBLIC_KEY
            )
        )
        assertFalse(
            verifier.verify(
                algorithm = ProtocolSigningAlgorithm.ED25519,
                data = byteArrayOf(1),
                signature = RFC8032_SIGNATURE,
                publicKey = RFC8032_PUBLIC_KEY
            )
        )
        assertFalse(mlDsaInvoked)
    }

    @Test
    fun invalidEd25519LengthRemainsTypedInsteadOfBecomingSignatureFalse() {
        val failure = assertThrows(
            Ed25519SoftwareVerifier.Failure.InvalidInputLength::class.java
        ) {
            kotlinx.coroutines.runBlocking {
                ProtocolIdentitySignatureVerifier().verify(
                    algorithm = ProtocolSigningAlgorithm.ED25519,
                    data = ByteArray(0),
                    signature = ByteArray(63),
                    publicKey = RFC8032_PUBLIC_KEY
                )
            }
        }
        assertTrue(failure.message.orEmpty().contains("signature"))
    }

    @Test
    fun mlDsaDispatchValidatesExactEncodingBeforeCallingVerifier() = runTest {
        var invoked = false
        val verifier = ProtocolIdentitySignatureVerifier(
            verifyEd25519 = { _, _, _ -> error("Ed25519 verifier must not run for ML-DSA-65") },
            verifyMlDsa65 = { _, _, _ ->
                invoked = true
                true
            }
        )

        assertTrue(
            verifier.verify(
                algorithm = ProtocolSigningAlgorithm.ML_DSA_65,
                data = byteArrayOf(1),
                signature = ByteArray(AndroidPQCCryptoProvider.MLDSA65_SIGNATURE_SIZE),
                publicKey = ByteArray(AndroidPQCCryptoProvider.MLDSA65_PUBLIC_KEY_SIZE)
            )
        )
        assertTrue(invoked)
    }

    private companion object {
        val RFC8032_PUBLIC_KEY = hex(
            "d75a980182b10ab7d54bfed3c964073a" +
                "0ee172f3daa62325af021a68f707511a"
        )
        val RFC8032_SIGNATURE = hex(
            "e5564300c360ac729086e2cc806e828a" +
                "84877f1eb8e5d974d873e06522490155" +
                "5fb8821590a33bacc61e39701cf9b46b" +
                "d25bf5f0595bbe24655141438e7a100b"
        )

        fun hex(value: String): ByteArray = ByteArray(value.length / 2) { index ->
            value.substring(index * 2, index * 2 + 2).toInt(16).toByte()
        }
    }
}
