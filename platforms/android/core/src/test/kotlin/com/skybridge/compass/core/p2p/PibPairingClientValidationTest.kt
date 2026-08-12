package com.skybridge.compass.core.p2p

import com.skybridge.compass.core.webrtc.ProtocolSigningAlgorithm
import com.skybridge.compass.shared.crypto.Ed25519SoftwareVerifier
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class PibPairingClientValidationTest {

    @Test
    fun candidateTextRejectsValueThatCanonicalizesToEmpty() {
        val error = assertThrows(PibPairingClient.PairingError.BindingMismatch::class.java) {
            PibPairingClient.validateCandidateText(
                value = "spoof=name",
                maxLength = 256,
                label = "candidate device name"
            )
        }

        assertEquals("candidate device name is invalid", error.message)
    }

    @Test
    fun candidateAliasThatCanonicalizesToEmptyIsRejected() {
        assertThrows(PibPairingClient.PairingError.BindingMismatch::class.java) {
            PibPairingClient.validateCandidateText("spoof=alias", 256, "candidate alias")
        }
    }

    @Test
    fun candidateBonjourDigestThatCanonicalizesToEmptyIsRejected() {
        assertThrows(PibPairingClient.PairingError.BindingMismatch::class.java) {
            PibPairingClient.validateCandidateText("spoof=digest", 128, "candidate endpoint digest")
        }
    }

    @Test
    fun nullCanonicalNameCannotBeReplacedWithSpoofedName() {
        // A null/empty deviceName is canonicalized as empty. Any non-empty value that would also
        // canonicalize to empty must be rejected before SAS or trust persistence can proceed.
        assertThrows(PibPairingClient.PairingError.BindingMismatch::class.java) {
            PibPairingClient.validateCandidateText("spoof=name", 256, "candidate device name")
        }
    }

    @Test
    fun candidateTextAllowsTrimOnlyNormalization() {
        PibPairingClient.validateCandidateText(
            value = "  Bill's Mac  ",
            maxLength = 256,
            label = "candidate device name"
        )
    }

    @Test
    fun pibResponderEd25519PathUsesProductionVerifierAndRejectsTampering() = runTest {
        assertTrue(
            PibPairingClient.verifyResponderSignature(
                algorithm = ProtocolSigningAlgorithm.ED25519,
                data = ByteArray(0),
                signature = RFC8032_SIGNATURE,
                publicKey = RFC8032_PUBLIC_KEY
            )
        )
        assertFalse(
            PibPairingClient.verifyResponderSignature(
                algorithm = ProtocolSigningAlgorithm.ED25519,
                data = byteArrayOf(1),
                signature = RFC8032_SIGNATURE,
                publicKey = RFC8032_PUBLIC_KEY
            )
        )
    }

    @Test
    fun pibDoesNotMisreportProviderFailureAsAnInvalidRemoteSignature() = runTest {
        val unavailable = ProtocolIdentitySignatureVerifier(
            verifyEd25519 = { _, _, _ ->
                throw Ed25519SoftwareVerifier.Failure.SoftwareProviderUnavailable("Signature.Ed25519")
            }
        )

        try {
            PibPairingClient.verifyResponderSignature(
                algorithm = ProtocolSigningAlgorithm.ED25519,
                data = ByteArray(0),
                signature = RFC8032_SIGNATURE,
                publicKey = RFC8032_PUBLIC_KEY,
                signatureVerifier = unavailable
            )
            fail("expected local verifier unavailability")
        } catch (expected: PibPairingClient.PairingError.IdentityUnavailable) {
            assertTrue(expected.message.orEmpty().contains("verification is unavailable"))
        }
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
