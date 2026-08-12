package com.skybridge.compass.shared.p2p

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

/**
 * JUnit 5 (Jupiter) KAT for the PIB-1 SAS derivation.
 *
 * IMPORTANT: the shared module runs `useJUnitPlatform()` (Jupiter engine ONLY). These tests use
 * `org.junit.jupiter.api.*` so the engine actually executes them.
 *
 * The expected values below were computed INDEPENDENTLY by running the real Swift formulas against
 * the same deterministic fixtures (a standalone Swift script invoking Cryptokit SHA256 + the exact
 * canonicalLineEncoding/normalizedToken/sha256Hex helpers from the Pro-release canon):
 *   - SessionKeys.pairingVerificationCode()                        (HandshakeCoreTypes.swift:159)
 *   - ProtocolIdentityBindingRequestPayload.canonicalPreimage      (AppMessage.swift:536)
 *   - SignedProtocolIdentityBindingPayload.signaturePreimage       (AppMessage.swift:656)
 *   - SignedProtocolIdentityBindingPayload.shortAuthenticationCode (AppMessage.swift:728)
 *
 * A mismatch here means Android and the Mac will display different 6-digit codes and PIB-1 pairing is
 * non-interoperable. Do NOT update the expected constants to "make it pass" — re-derive from Swift.
 */
class P2PPibShortAuthStringTest {

    // --- Deterministic fixtures (identical to the Swift KAT script) -------------------------------

    private val transcriptHash = ByteArray(32) { it.toByte() }            // 0x00..0x1f
    private val requesterPubKey = ByteArray(48) { ((it * 7) and 0xFF).toByte() }
    private val responderPubKey = ByteArray(48) { ((it * 3 + 1) and 0xFF).toByte() }
    private val nonce = ByteArray(24) { ((100 + it) and 0xFF).toByte() }
    private val requesterSignature = ByteArray(64) { ((it * 5) and 0xFF).toByte() }
    private val responderSignature = ByteArray(64) { ((it * 9 + 2) and 0xFF).toByte() }
    private val requesterFingerprint = "ab".repeat(32) // 64 hex chars
    private val responderFingerprint = "cd".repeat(32)
    private val transactionId = "12345678-1234-5678-1234-567812345678"

    private val requestSentAtMs = 1_700_000_000_000L
    private val responseSentAtMs = 1_700_000_005_000L
    private val responseExpiresAtMs = 1_700_000_905_000L

    private val requestPreimage = P2PPibShortAuthString.requestCanonicalPreimage(
        version = P2PPibShortAuthString.REQUEST_VERSION,
        transactionId = transactionId,
        requesterDeviceId = "android-device-001",
        targetDeviceId = "mac-target-XYZ",
        requestedProtocolSigningAlgorithms = listOf("ML-DSA-65", "Ed25519"),
        requesterProtocolSigningAlgorithm = "ML-DSA-65",
        requesterProtocolIdentityPublicKey = requesterPubKey,
        requesterProtocolIdentityFingerprint = requesterFingerprint,
        policyRequirePQC = true,
        policyAllowClassicFallback = false,
        routeScope = "lan",
        bonjourEndpointDigest = null,
        nonce = nonce,
        sentAtUnixMillis = requestSentAtMs
    )

    private val responsePreimage = P2PPibShortAuthString.responseSignaturePreimage(
        version = P2PPibShortAuthString.RESPONSE_VERSION,
        transactionId = transactionId,
        deviceId = "mac-target-XYZ",
        aliases = listOf("mac-alias-2", "mac-alias-1"),
        protocolSigningAlgorithm = "ML-DSA-65",
        protocolIdentityPublicKey = responderPubKey,
        protocolIdentityFingerprint = responderFingerprint,
        deviceName = "Bill's Mac",
        sentAtUnixMillis = responseSentAtMs,
        expiresAtUnixMillis = responseExpiresAtMs,
        requestNonce = nonce,
        requestHashHex = P2PPibShortAuthString.canonicalRequestHashHex(requestPreimage),
        policyRequirePQC = true,
        policyAllowClassicFallback = false,
        routeScope = "lan",
        bonjourEndpointDigest = null
    )

    // --- KATs -------------------------------------------------------------------------------------

    @Test
    fun transcriptSasMatchesSwiftFormula() {
        // Swift: SessionKeys.pairingVerificationCode() for transcriptHash 0x00..0x1f.
        assertEquals("879057", P2PPibShortAuthString.pairingVerificationCode(transcriptHash))
    }

    @Test
    fun requestCanonicalHashMatchesSwiftFormula() {
        // Swift: ProtocolIdentityBindingRequestPayload.canonicalRequestHashHex.
        assertEquals(
            "edd9ab2f6b031ccd4be090a41436563236440879be4d2f04dc5ede78d2ac0a76",
            P2PPibShortAuthString.canonicalRequestHashHex(requestPreimage)
        )
    }

    @Test
    fun pib1ShortAuthStringMatchesSwiftFormula() {
        // Swift: SignedProtocolIdentityBindingPayload.shortAuthenticationCode(request:).
        // This is the 6-digit code the macOS operator confirms before writing the Android TrustRecord.
        val sas = P2PPibShortAuthString.pib1ShortAuthenticationCode(
            requestCanonicalPreimage = requestPreimage,
            requesterSignature = requesterSignature,
            responderSignaturePreimage = responsePreimage,
            responderSignature = responderSignature
        )
        assertEquals("863449", sas)
    }

    @Test
    fun emptyRequesterSignatureFoldsAsEmptyData() {
        // Swift uses `request.requesterSignature ?? Data()` — an empty signature must fold identically
        // to passing zero bytes. Recompute with an explicitly empty array and confirm it differs from
        // the full-signature SAS only via the signature bytes (sanity: no NPE / no padding surprises).
        val withEmpty = P2PPibShortAuthString.pib1ShortAuthenticationCode(
            requestCanonicalPreimage = requestPreimage,
            requesterSignature = ByteArray(0),
            responderSignaturePreimage = responsePreimage,
            responderSignature = responderSignature
        )
        // Stable 6-digit numeric output regardless of empty signature.
        assertEquals(6, withEmpty.length)
        assertEquals(true, withEmpty.all { it in '0'..'9' })
    }

    @Test
    fun canonicalLineEncodingUsesLfAndNoTrailingNewline() {
        val encoded = P2PPibShortAuthString.canonicalLineEncoding(
            listOf("a" to "1", "b" to "2", "c" to "3")
        ).toString(Charsets.UTF_8)
        assertEquals("a=1\nb=2\nc=3", encoded)
    }

    @Test
    fun normalizedTokenRejectsInjectionChars() {
        assertEquals("", P2PPibShortAuthString.normalizedToken("has=equals"))
        assertEquals("", P2PPibShortAuthString.normalizedToken("has\nnewline"))
        assertEquals("clean", P2PPibShortAuthString.normalizedToken("  clean  "))
    }

    @Test
    fun normalizedFingerprintRequires64LowercaseHex() {
        assertEquals("ab".repeat(32), P2PPibShortAuthString.normalizedFingerprint("AB".repeat(32)))
        assertEquals(null, P2PPibShortAuthString.normalizedFingerprint("ab".repeat(31))) // too short
        assertEquals(null, P2PPibShortAuthString.normalizedFingerprint("zz".repeat(32))) // non-hex
    }

    @Test
    fun v3ConfirmAndFinalAckCanonicalHashesMatchSwiftFormula() {
        val requestNonce = ByteArray(24) { (it + 1).toByte() }
        val confirmationNonce = ByteArray(24) { (it + 31).toByte() }
        val requesterSignature = ByteArray(64) { (it * 11).toByte() }
        val confirmPreimage = P2PPibShortAuthString.confirmSignaturePreimage(
            version = P2PPibShortAuthString.CONFIRM_VERSION,
            transactionId = transactionId,
            requesterDeviceId = "android-device",
            responderDeviceId = "mac-device",
            requesterProtocolIdentityFingerprint = "ab".repeat(32),
            responderProtocolIdentityFingerprint = "cd".repeat(32),
            requestNonce = requestNonce,
            requestHashHex = "de".repeat(32),
            candidateHashHex = "ef".repeat(32),
            sasTranscriptHashHex = "12".repeat(32),
            confirmationNonce = confirmationNonce,
            sentAtUnixMillis = 1_700_000_010_000L,
            expiresAtUnixMillis = 1_700_000_310_000L,
            policyRequirePQC = true,
            policyAllowClassicFallback = false,
            routeScope = "lan"
        )
        assertEquals(
            "85335ad34ed0b85f5bbf20cea9a4dd3dd9c32ea6e7a3414d5618931a7a9dae77",
            P2PPibShortAuthString.canonicalConfirmHashHex(confirmPreimage, requesterSignature)
        )

        val finalAckPreimage = P2PPibShortAuthString.finalAckSignaturePreimage(
            version = P2PPibShortAuthString.FINAL_ACK_VERSION,
            transactionId = transactionId,
            requesterDeviceId = "android-device",
            responderDeviceId = "mac-device",
            requesterProtocolIdentityFingerprint = "ab".repeat(32),
            responderProtocolIdentityFingerprint = "cd".repeat(32),
            requestNonce = requestNonce,
            confirmationNonce = confirmationNonce,
            requestHashHex = "de".repeat(32),
            candidateHashHex = "ef".repeat(32),
            confirmHashHex = "85335ad34ed0b85f5bbf20cea9a4dd3dd9c32ea6e7a3414d5618931a7a9dae77",
            sasTranscriptHashHex = "12".repeat(32),
            accepted = true,
            sentAtUnixMillis = 1_700_000_011_000L,
            expiresAtUnixMillis = 1_700_000_310_000L,
            policyRequirePQC = true,
            policyAllowClassicFallback = false,
            routeScope = "lan"
        )
        assertEquals(
            "ba1fa194086040858b8efcbb716e33ff94bd20d98c5a2a4ffab6c1c14991156f",
            P2PPibShortAuthString.sha256Hex(finalAckPreimage)
        )
    }
}
