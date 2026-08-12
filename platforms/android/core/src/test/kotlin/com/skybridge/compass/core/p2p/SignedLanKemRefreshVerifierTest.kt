package com.skybridge.compass.core.p2p

import com.skybridge.compass.core.webrtc.ProtocolIdentityBinding
import com.skybridge.compass.core.webrtc.ProtocolSigningAlgorithm
import com.skybridge.compass.shared.crypto.Ed25519SoftwareVerifier
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.security.KeyPairGenerator
import java.security.Signature

class SignedLanKemRefreshVerifierTest {
    @Test
    fun rejectsWireIdOutsideUInt16BeforeConversion() = runTest {
        assertValidationFailure("outside UInt16 range") {
            verifierAcceptingSignature().verify(
                request = request().copy(requestedSuiteWireIds = listOf(65_537)),
                response = response(),
                pinnedProtocolFingerprint = PIN,
                minimumGeneration = null,
                nowMillis = NOW
            )
        }
    }

    @Test
    fun rejectsLegacyAndForwardSecureCompatibilitySuites() = runTest {
        listOf(0x0011, 0x0102).forEach { wireId ->
            assertValidationFailure("not eligible") {
                verifierAcceptingSignature().verify(
                    request = request().copy(requestedSuiteWireIds = listOf(wireId)),
                    response = response(),
                    pinnedProtocolFingerprint = PIN,
                    minimumGeneration = null,
                    nowMillis = NOW
                )
            }
        }
    }

    @Test
    fun rejectsNegativeGenerationAndNonFiniteOrOutOfRangeDates() = runTest {
        listOf(Double.NaN, Double.POSITIVE_INFINITY).forEach { invalidDate ->
            assertValidationFailure("not finite") {
                verifierAcceptingSignature().verify(
                    request = request().copy(sentAt = invalidDate),
                    response = response(),
                    pinnedProtocolFingerprint = PIN,
                    minimumGeneration = null,
                    nowMillis = NOW
                )
            }
        }
        assertValidationFailure("outside the supported range") {
            verifierAcceptingSignature().verify(
                request = request().copy(sentAt = Double.MAX_VALUE),
                response = response(),
                pinnedProtocolFingerprint = PIN,
                minimumGeneration = null,
                nowMillis = NOW
            )
        }
        val longMinReferenceSeconds =
            Long.MIN_VALUE.toDouble() / 1_000.0 - PibBootstrapWire.SWIFT_REFERENCE_EPOCH_UNIX_SECONDS
        assertValidationFailure("request is expired") {
            verifierAcceptingSignature().verify(
                request = request().copy(sentAt = longMinReferenceSeconds),
                response = response(),
                pinnedProtocolFingerprint = PIN,
                minimumGeneration = null,
                nowMillis = NOW
            )
        }
        assertValidationFailure("response expiresAt is not finite") {
            verifierAcceptingSignature().verify(
                request = request(),
                response = response().copy(expiresAt = Double.NEGATIVE_INFINITY),
                pinnedProtocolFingerprint = PIN,
                minimumGeneration = null,
                nowMillis = NOW
            )
        }
        assertValidationFailure("generation is invalid") {
            verifierAcceptingSignature().verify(
                request = request(),
                response = response().copy(generation = -1),
                pinnedProtocolFingerprint = PIN,
                minimumGeneration = null,
                nowMillis = NOW
            )
        }
    }

    @Test
    fun verifiesRealEd25519SignedXWingOnlyResponseAndRejectsTampering() = runTest {
        val xWingKey = ByteArray(1_216) { 0x55 }
        val fixture = realEdSignedResponse(
            listOf(SkrBootstrapWire.KemPublicKeyInfo(0x0001, xWingKey))
        )
        val verifier = SignedLanKemRefreshVerifier()

        val verified = verifier.verify(
            request = fixture.request,
            response = fixture.response,
            pinnedProtocolFingerprint = fixture.fingerprint,
            minimumGeneration = 6,
            nowMillis = NOW
        )
        assertEquals(7, verified.generation)
        assertEquals(listOf(0x0001), verified.signedSuiteWireIds)
        assertArrayEquals(xWingKey, verified.kemPublicKeys.single().publicKey)

        val tampered = fixture.response.copy(
            signature = fixture.response.signature.copyOf().also {
                it[0] = (it[0].toInt() xor 1).toByte()
            }
        )
        assertValidationFailure("signature is invalid") {
            verifier.verify(
                fixture.request,
                tampered,
                fixture.fingerprint,
                minimumGeneration = 6,
                nowMillis = NOW
            )
        }
    }

    @Test
    fun verifiesAndImportsRealEd25519SignedMlKemOnlyResponse() = runTest {
        val mlKemKey = ByteArray(1_184) { 0x66 }
        val fixture = realEdSignedResponse(
            listOf(SkrBootstrapWire.KemPublicKeyInfo(0x0101, mlKemKey))
        )

        val verified = SignedLanKemRefreshVerifier().verify(
            request = fixture.request,
            response = fixture.response,
            pinnedProtocolFingerprint = fixture.fingerprint,
            minimumGeneration = 6,
            nowMillis = NOW
        )

        assertEquals(listOf(0x0101), verified.signedSuiteWireIds)
        assertEquals(0x0101, verified.kemPublicKeys.single().suiteWireId)
        assertArrayEquals(mlKemKey, verified.kemPublicKeys.single().publicKey)
    }

    @Test
    fun localEd25519ProviderFailureIsNotMisclassifiedAsAnInvalidPeerSignature() = runTest {
        val unavailable = SignedLanKemRefreshVerifier(
            ProtocolIdentitySignatureVerifier(
                verifyEd25519 = { _, _, _ ->
                    throw Ed25519SoftwareVerifier.Failure.SoftwareProviderUnavailable(
                        "Signature.Ed25519"
                    )
                }
            )
        )

        try {
            unavailable.verify(
                request = request(),
                response = response(),
                pinnedProtocolFingerprint = PIN,
                minimumGeneration = null,
                nowMillis = NOW
            )
            fail("expected local signature verifier failure")
        } catch (expected: SignedLanKemRefreshVerificationUnavailableException) {
            assertTrue(expected.message.orEmpty().contains("verification is unavailable"))
        }
    }

    @Test
    fun rejectsRequestTargetFingerprintThatDoesNotMatchVerifierPin() = runTest {
        assertValidationFailure("request target protocol identity does not match") {
            verifierAcceptingSignature().verify(
                request = request(pin = "a".repeat(64)),
                response = response(),
                pinnedProtocolFingerprint = PIN,
                minimumGeneration = null,
                nowMillis = NOW
            )
        }
    }

    @Test
    fun malformedKemKeyIsReportedAsTypedProtocolValidation() = runTest {
        val malformed = response().copy(
            kemPublicKeys = listOf(
                SkrBootstrapWire.KemPublicKeyInfo(0x0001, ByteArray(1_215)),
                SkrBootstrapWire.KemPublicKeyInfo(0x0101, ByteArray(1_184) { 0x66 })
            )
        )
        assertValidationFailure("response KEM public key is invalid for wireId=1") {
            verifierAcceptingSignature().verify(
                request = request(),
                response = malformed,
                pinnedProtocolFingerprint = PIN,
                minimumGeneration = null,
                nowMillis = NOW
            )
        }
    }

    @Test
    fun requestStillRequiresTheExactDualSuiteSet() = runTest {
        assertValidationFailure("request KEM suite set must contain X-Wing and ML-KEM-768") {
            verifierAcceptingSignature().verify(
                request = request().copy(requestedSuiteWireIds = listOf(0x0101)),
                response = response(),
                pinnedProtocolFingerprint = PIN,
                minimumGeneration = null,
                nowMillis = NOW
            )
        }
    }

    @Test
    fun rejectsEmptyUnknownAndUnrequestedResponseSuiteSets() = runTest {
        assertValidationFailure("response contains no KEM public key") {
            verifierAcceptingSignature().verify(
                request = request(),
                response = response().copy(kemPublicKeys = emptyList()),
                pinnedProtocolFingerprint = PIN,
                minimumGeneration = null,
                nowMillis = NOW
            )
        }
        assertValidationFailure("unknown KEM suite wireId=30583") {
            verifierAcceptingSignature().verify(
                request = request(),
                response = response().copy(
                    kemPublicKeys = listOf(SkrBootstrapWire.KemPublicKeyInfo(0x7777, ByteArray(1)))
                ),
                pinnedProtocolFingerprint = PIN,
                minimumGeneration = null,
                nowMillis = NOW
            )
        }
        assertValidationFailure("response KEM suite was not requested") {
            verifierAcceptingSignature().verify(
                request = request(),
                response = response().copy(
                    kemPublicKeys = listOf(SkrBootstrapWire.KemPublicKeyInfo(0x0011, ByteArray(1)))
                ),
                pinnedProtocolFingerprint = PIN,
                minimumGeneration = null,
                nowMillis = NOW
            )
        }
    }

    @Test
    fun generationLongMaxIsRepresentableButLowerGenerationRollsBack() = runTest {
        val accepted = verifierAcceptingSignature().verify(
            request = request(),
            response = response().copy(generation = Long.MAX_VALUE),
            pinnedProtocolFingerprint = PIN,
            minimumGeneration = Long.MAX_VALUE,
            nowMillis = NOW
        )
        assertEquals(Long.MAX_VALUE, accepted.generation)

        assertValidationFailure("generation rollback detected") {
            verifierAcceptingSignature().verify(
                request = request(),
                response = response().copy(generation = 6),
                pinnedProtocolFingerprint = PIN,
                minimumGeneration = 7,
                nowMillis = NOW
            )
        }
    }

    private fun verifierAcceptingSignature() = SignedLanKemRefreshVerifier(
        ProtocolIdentitySignatureVerifier(
            verifyEd25519 = { _, _, _ -> true },
            verifyMlDsa65 = { _, _, _ -> true }
        )
    )

    private fun realEdSignedResponse(
        kemPublicKeys: List<SkrBootstrapWire.KemPublicKeyInfo>
    ): RealEdFixture {
        val keyPair = KeyPairGenerator.getInstance("Ed25519").generateKeyPair()
        val rawPublicKey = keyPair.public.encoded.takeLast(32).toByteArray()
        val fingerprint = ProtocolIdentityBinding.computeFingerprint(
            ProtocolSigningAlgorithm.ED25519,
            rawPublicKey
        )
        val request = request(pin = fingerprint)
        val unsigned = response(
            publicKey = rawPublicKey,
            fingerprint = fingerprint,
            requestHash = SkrCanonical.requestHashHex(request),
            signature = ByteArray(64)
        ).copy(kemPublicKeys = kemPublicKeys)
        val signature = Signature.getInstance("Ed25519").run {
            initSign(keyPair.private)
            update(SkrCanonical.responseSignaturePreimage(unsigned))
            sign()
        }
        return RealEdFixture(
            request = request,
            response = unsigned.copy(signature = signature),
            fingerprint = fingerprint
        )
    }

    private fun request(pin: String = PIN) = SkrBootstrapWire.KemRefreshRequestPayload(
        requesterDeviceId = "id:android-1",
        targetDeviceId = "id:mac-1",
        requesterProtocolIdentityFingerprint = "a".repeat(64),
        targetProtocolIdentityFingerprint = pin,
        requestedSuiteWireIds = listOf(0x0001, 0x0101),
        policyHashHex = SkrCanonical.policyHashHex(),
        bonjourEndpointDigest = "c".repeat(64),
        nonce = ByteArray(24) { it.toByte() },
        sentAt = PibBootstrapWire.unixMillisToReferenceSeconds(NOW)
    )

    private fun response(
        publicKey: ByteArray = DEFAULT_PUBLIC_KEY,
        fingerprint: String = PIN,
        requestHash: String = SkrCanonical.requestHashHex(request(pin = fingerprint)),
        signature: ByteArray = ByteArray(64) { 0x42 }
    ) = SkrBootstrapWire.SignedKemRefreshPayload(
        deviceId = "id:mac-1",
        aliases = emptyList(),
        protocolSigningAlgorithm = if (publicKey.size == 32) "Ed25519" else "ML-DSA-65",
        protocolIdentityPublicKey = publicKey,
        protocolIdentityFingerprint = fingerprint,
        kemPublicKeys = listOf(
            SkrBootstrapWire.KemPublicKeyInfo(0x0001, ByteArray(1_216) { 0x55 }),
            SkrBootstrapWire.KemPublicKeyInfo(0x0101, ByteArray(1_184) { 0x66 })
        ),
        keyId = "skr-key-1",
        generation = 7,
        sentAt = PibBootstrapWire.unixMillisToReferenceSeconds(NOW),
        expiresAt = PibBootstrapWire.unixMillisToReferenceSeconds(NOW + 300_000),
        requestNonce = ByteArray(24) { it.toByte() },
        requestHashHex = requestHash,
        bonjourEndpointDigest = "c".repeat(64),
        signature = signature
    )

    private suspend fun assertValidationFailure(
        expectedMessage: String,
        block: suspend () -> Unit
    ) {
        try {
            block()
            fail("expected SignedLanKemRefreshValidationException")
        } catch (expected: SignedLanKemRefreshValidationException) {
            assertTrue(expected.message.orEmpty().startsWith("SKR-1"))
            assertTrue(
                "expected message to contain '$expectedMessage', got '${expected.message}'",
                expected.message.orEmpty().contains(expectedMessage)
            )
        }
    }

    private companion object {
        const val NOW = 1_700_000_000_000L
        val DEFAULT_PUBLIC_KEY = hex(
            "d75a980182b10ab7d54bfed3c964073a" +
                "0ee172f3daa62325af021a68f707511a"
        )
        val PIN = ProtocolIdentityBinding.computeFingerprint(
            ProtocolSigningAlgorithm.ED25519,
            DEFAULT_PUBLIC_KEY
        )

        fun hex(value: String): ByteArray = ByteArray(value.length / 2) { index ->
            value.substring(index * 2, index * 2 + 2).toInt(16).toByte()
        }
    }

    private data class RealEdFixture(
        val request: SkrBootstrapWire.KemRefreshRequestPayload,
        val response: SkrBootstrapWire.SignedKemRefreshPayload,
        val fingerprint: String
    )
}
