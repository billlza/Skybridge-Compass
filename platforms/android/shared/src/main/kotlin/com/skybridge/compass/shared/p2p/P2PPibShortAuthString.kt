package com.skybridge.compass.shared.p2p

import java.security.MessageDigest

/**
 * PIB-1 Short Authentication String (SAS) derivation — byte-for-byte interop with the macOS/iOS
 * Pro-release canon. This is SECURITY-CRITICAL: if the canonical preimage or the digest fold differs
 * from Swift by a single byte, the 6-digit code shown on Android will not match the code the Mac
 * operator sees, and PIB-1 pairing is non-interoperable.
 *
 * Two distinct SAS exist in the Swift canon; both are reproduced here:
 *
 *  (a) [pairingVerificationCode] — the post-handshake transcript SAS.
 *      Swift: `SkyBridgeProtocolCore/P2P/HandshakeCoreTypes.swift:159`
 *        SessionKeys.pairingVerificationCode():
 *          material = "SkyBridge-Pairing-SAS|".utf8 + transcriptHash
 *          digest   = SHA256(material)
 *          raw      = first 4 bytes of digest as UInt32 big-endian
 *          code     = String(format: "%06d", raw % 1_000_000)
 *      This is NOT the code that gates inbound-remote-control trust; it is informational.
 *
 *  (b) [pib1ShortAuthenticationCode] — THE PIB-1 trust-gating SAS.
 *      Swift: `Sources/SkyBridgeCore/P2P/AppMessage.swift:728`
 *        SignedProtocolIdentityBindingPayload.shortAuthenticationCode(request:):
 *          material = "SkyBridge-PIB-1-SAS\n".utf8
 *                   + request.canonicalPreimage
 *                   + (request.requesterSignature ?? Data())
 *                   + responder.signaturePreimage
 *                   + responder.signature
 *          digest   = SHA256(material)
 *          raw      = first 4 bytes of digest as UInt32 big-endian
 *          code     = String(format: "%06d", raw % 1_000_000)
 *      The macOS operator confirms code (b) before the Mac writes the Android device's TrustRecord
 *      (via PairingTrustApprovalService.stageProtocolIdentityBindingRequesterApproval), which is what
 *      flips RemoteControlInboundTrustResolver from `.missing` (untrustedPeer) to `.resolved`.
 *
 * The canonical preimages here reproduce:
 *  - request:   `AppMessage.ProtocolIdentityBindingRequestPayload.canonicalPreimage`   (AppMessage.swift:536)
 *  - responder: `AppMessage.SignedProtocolIdentityBindingPayload.signaturePreimage`    (AppMessage.swift:656)
 * using `AppMessage.canonicalLineEncoding` (AppMessage.swift:1274) and the `normalizedToken`,
 * `sha256Hex`, `millisecondsSinceEpoch`, `normalizedFingerprint`, `normalizedUniqueTokens` helpers
 * (AppMessage.swift:1274-1314).
 *
 * Field ORDER is positional and load-bearing — do not reorder.
 */
object P2PPibShortAuthString {

    // Swift domain separators (exact bytes).
    private const val PAIRING_SAS_DOMAIN = "SkyBridge-Pairing-SAS|"
    private const val PIB1_SAS_DOMAIN = "SkyBridge-PIB-1-SAS\n"

    // ProtocolIdentityBindingRequestPayload.domainSeparator / currentVersion (AppMessage.swift:445-446)
    const val REQUEST_DOMAIN: String = "SkyBridge-PIB-1-Request"
    const val REQUEST_VERSION: Int = 3

    // SignedProtocolIdentityBindingPayload.domainSeparator / currentVersion (AppMessage.swift:567-568)
    const val RESPONSE_DOMAIN: String = "SkyBridge-PIB-1-SignedProtocolIdentityBinding"
    const val RESPONSE_VERSION: Int = 2

    const val CONFIRM_DOMAIN: String = "SkyBridge-PIB-1-V3-Confirm"
    const val CONFIRM_VERSION: Int = 3
    const val FINAL_ACK_DOMAIN: String = "SkyBridge-PIB-1-V3-SignedFinalAck"
    const val FINAL_ACK_VERSION: Int = 3

    // --- (a) Transcript SAS -------------------------------------------------------------------

    /**
     * Reproduces `SessionKeys.pairingVerificationCode()` (HandshakeCoreTypes.swift:159).
     */
    fun pairingVerificationCode(transcriptHash: ByteArray): String {
        val material = PAIRING_SAS_DOMAIN.toByteArray(Charsets.UTF_8) + transcriptHash
        return sixDigitCode(MessageDigest.getInstance("SHA-256").digest(material))
    }

    // --- (b) PIB-1 trust-gating SAS -----------------------------------------------------------

    /**
     * Reproduces `SignedProtocolIdentityBindingPayload.shortAuthenticationCode(request:)`
     * (AppMessage.swift:728). Inputs are the two canonical preimages and the two raw signatures.
     *
     * @param requestCanonicalPreimage   [requestCanonicalPreimage]
     * @param requesterSignature         requester's signature over the request canonical preimage
     *                                    (may be empty; Swift uses `?? Data()`)
     * @param responderSignaturePreimage [responseSignaturePreimage]
     * @param responderSignature         responder's (Mac's) signature over its signaturePreimage
     */
    fun pib1ShortAuthenticationCode(
        requestCanonicalPreimage: ByteArray,
        requesterSignature: ByteArray,
        responderSignaturePreimage: ByteArray,
        responderSignature: ByteArray
    ): String {
        val digest = MessageDigest.getInstance("SHA-256").apply {
            update(PIB1_SAS_DOMAIN.toByteArray(Charsets.UTF_8))
            update(requestCanonicalPreimage)
            update(requesterSignature)
            update(responderSignaturePreimage)
            update(responderSignature)
        }.digest()
        return sixDigitCode(digest)
    }

    // --- Canonical preimages ------------------------------------------------------------------

    /**
     * Reproduces `ProtocolIdentityBindingRequestPayload.canonicalPreimage` (AppMessage.swift:536).
     *
     * Field order is positional. `requestedProtocolSigningAlgorithms` is trimmed/filtered/sorted and
     * comma-joined; the public key is hashed (NOT included raw); nonce is standard base64; sentAt is
     * floor(unixSeconds * 1000) as a decimal string.
     */
    fun requestCanonicalPreimage(
        version: Int,
        transactionId: String,
        requesterDeviceId: String,
        targetDeviceId: String,
        requestedProtocolSigningAlgorithms: List<String>,
        requesterProtocolSigningAlgorithm: String?,
        requesterProtocolIdentityPublicKey: ByteArray?,
        requesterProtocolIdentityFingerprint: String?,
        policyRequirePQC: Boolean,
        policyAllowClassicFallback: Boolean,
        routeScope: String,
        bonjourEndpointDigest: String?,
        nonce: ByteArray,
        sentAtUnixMillis: Long
    ): ByteArray {
        val algorithms = requestedProtocolSigningAlgorithms
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .sorted()
            .joinToString(",")
        val requesterAlgorithm = requesterProtocolSigningAlgorithm?.trim().orEmpty()
        val requesterKeyHash = requesterProtocolIdentityPublicKey?.let { sha256Hex(it) }.orEmpty()
        val requesterFingerprint = normalizedFingerprint(requesterProtocolIdentityFingerprint).orEmpty()

        return canonicalLineEncoding(
            listOf(
                "domain" to REQUEST_DOMAIN,
                "version" to version.toString(),
                "transactionId" to canonicalUuid(transactionId),
                "requesterDeviceId" to normalizedToken(requesterDeviceId),
                "targetDeviceId" to normalizedToken(targetDeviceId),
                "requestedProtocolSigningAlgorithms" to algorithms,
                "requesterProtocolSigningAlgorithm" to requesterAlgorithm,
                "requesterProtocolIdentityPublicKeyHash" to requesterKeyHash,
                "requesterProtocolIdentityFingerprint" to requesterFingerprint,
                "policyRequirePQC" to boolBit(policyRequirePQC),
                "policyAllowClassicFallback" to boolBit(policyAllowClassicFallback),
                "routeScope" to routeScope.trim().lowercase(),
                "bonjourEndpointDigest" to normalizedToken(bonjourEndpointDigest.orEmpty()),
                "nonce" to base64Standard(nonce),
                "sentAtMs" to millisecondsString(sentAtUnixMillis)
            )
        )
    }

    /**
     * Reproduces `SignedProtocolIdentityBindingPayload.signaturePreimage` (AppMessage.swift:656).
     * This is the responder/Mac canonical structure; Android only RECEIVES it (decoded from the
     * wire), then recomputes this preimage locally to fold into the SAS for display.
     */
    fun responseSignaturePreimage(
        version: Int,
        transactionId: String,
        deviceId: String,
        aliases: List<String>,
        protocolSigningAlgorithm: String,
        protocolIdentityPublicKey: ByteArray,
        protocolIdentityFingerprint: String?,
        deviceName: String?,
        sentAtUnixMillis: Long,
        expiresAtUnixMillis: Long,
        requestNonce: ByteArray,
        requestHashHex: String?,
        policyRequirePQC: Boolean,
        policyAllowClassicFallback: Boolean,
        routeScope: String,
        bonjourEndpointDigest: String?
    ): ByteArray {
        val protocolKeyHash = sha256Hex(protocolIdentityPublicKey)
        return canonicalLineEncoding(
            listOf(
                "domain" to RESPONSE_DOMAIN,
                "version" to version.toString(),
                "transactionId" to canonicalUuid(transactionId),
                "deviceId" to normalizedToken(deviceId),
                "aliases" to normalizedUniqueTokens(aliases).joinToString(","),
                "protocolSigningAlgorithm" to protocolSigningAlgorithm.trim(),
                "protocolIdentityPublicKeyHash" to protocolKeyHash,
                "protocolIdentityFingerprint" to normalizedFingerprint(protocolIdentityFingerprint).orEmpty(),
                "deviceName" to normalizedToken(deviceName.orEmpty()),
                "sentAtMs" to millisecondsString(sentAtUnixMillis),
                "expiresAtMs" to millisecondsString(expiresAtUnixMillis),
                "requestNonce" to base64Standard(requestNonce),
                "requestHashHex" to (normalizedHex(requestHashHex, exactCount = null) ?: ""),
                "policyRequirePQC" to boolBit(policyRequirePQC),
                "policyAllowClassicFallback" to boolBit(policyAllowClassicFallback),
                "routeScope" to routeScope.trim().lowercase(),
                "bonjourEndpointDigest" to normalizedToken(bonjourEndpointDigest.orEmpty())
            )
        )
    }

    /** Reproduces `canonicalRequestHashHex` = sha256Hex(canonicalPreimage) (AppMessage.swift:495). */
    fun canonicalRequestHashHex(requestCanonicalPreimage: ByteArray): String =
        sha256Hex(requestCanonicalPreimage)

    /** Reproduces ProtocolIdentityBindingConfirmPayload.signaturePreimage (AppMessage.swift:804). */
    fun confirmSignaturePreimage(
        version: Int,
        transactionId: String,
        requesterDeviceId: String,
        responderDeviceId: String,
        requesterProtocolIdentityFingerprint: String?,
        responderProtocolIdentityFingerprint: String?,
        requestNonce: ByteArray,
        requestHashHex: String,
        candidateHashHex: String,
        sasTranscriptHashHex: String,
        confirmationNonce: ByteArray,
        sentAtUnixMillis: Long,
        expiresAtUnixMillis: Long,
        policyRequirePQC: Boolean,
        policyAllowClassicFallback: Boolean,
        routeScope: String
    ): ByteArray = canonicalLineEncoding(
        listOf(
            "domain" to CONFIRM_DOMAIN,
            "version" to version.toString(),
            "transactionId" to canonicalUuid(transactionId),
            "requesterDeviceId" to normalizedToken(requesterDeviceId),
            "responderDeviceId" to normalizedToken(responderDeviceId),
            "requesterProtocolIdentityFingerprint" to normalizedFingerprint(requesterProtocolIdentityFingerprint).orEmpty(),
            "responderProtocolIdentityFingerprint" to normalizedFingerprint(responderProtocolIdentityFingerprint).orEmpty(),
            "requestNonce" to base64Standard(requestNonce),
            "requestHashHex" to (normalizedHex(requestHashHex, exactCount = 64) ?: ""),
            "candidateHashHex" to (normalizedHex(candidateHashHex, exactCount = 64) ?: ""),
            "sasTranscriptHashHex" to (normalizedHex(sasTranscriptHashHex, exactCount = 64) ?: ""),
            "confirmationNonce" to base64Standard(confirmationNonce),
            "sentAtMs" to millisecondsString(sentAtUnixMillis),
            "expiresAtMs" to millisecondsString(expiresAtUnixMillis),
            "policyRequirePQC" to boolBit(policyRequirePQC),
            "policyAllowClassicFallback" to boolBit(policyAllowClassicFallback),
            "routeScope" to routeScope.trim().lowercase()
        )
    )

    fun canonicalConfirmHashHex(confirmSignaturePreimage: ByteArray, requesterSignature: ByteArray): String =
        sha256Hex(confirmSignaturePreimage + requesterSignature)

    /** Reproduces SignedProtocolIdentityBindingFinalAckPayload.signaturePreimage (AppMessage.swift:958). */
    fun finalAckSignaturePreimage(
        version: Int,
        transactionId: String,
        requesterDeviceId: String,
        responderDeviceId: String,
        requesterProtocolIdentityFingerprint: String?,
        responderProtocolIdentityFingerprint: String?,
        requestNonce: ByteArray,
        confirmationNonce: ByteArray,
        requestHashHex: String,
        candidateHashHex: String,
        confirmHashHex: String,
        sasTranscriptHashHex: String,
        accepted: Boolean,
        sentAtUnixMillis: Long,
        expiresAtUnixMillis: Long,
        policyRequirePQC: Boolean,
        policyAllowClassicFallback: Boolean,
        routeScope: String
    ): ByteArray = canonicalLineEncoding(
        listOf(
            "domain" to FINAL_ACK_DOMAIN,
            "version" to version.toString(),
            "transactionId" to canonicalUuid(transactionId),
            "requesterDeviceId" to normalizedToken(requesterDeviceId),
            "responderDeviceId" to normalizedToken(responderDeviceId),
            "requesterProtocolIdentityFingerprint" to normalizedFingerprint(requesterProtocolIdentityFingerprint).orEmpty(),
            "responderProtocolIdentityFingerprint" to normalizedFingerprint(responderProtocolIdentityFingerprint).orEmpty(),
            "requestNonce" to base64Standard(requestNonce),
            "confirmationNonce" to base64Standard(confirmationNonce),
            "requestHashHex" to (normalizedHex(requestHashHex, exactCount = 64) ?: ""),
            "candidateHashHex" to (normalizedHex(candidateHashHex, exactCount = 64) ?: ""),
            "confirmHashHex" to (normalizedHex(confirmHashHex, exactCount = 64) ?: ""),
            "sasTranscriptHashHex" to (normalizedHex(sasTranscriptHashHex, exactCount = 64) ?: ""),
            "accepted" to boolBit(accepted),
            "sentAtMs" to millisecondsString(sentAtUnixMillis),
            "expiresAtMs" to millisecondsString(expiresAtUnixMillis),
            "policyRequirePQC" to boolBit(policyRequirePQC),
            "policyAllowClassicFallback" to boolBit(policyAllowClassicFallback),
            "routeScope" to routeScope.trim().lowercase()
        )
    )

    // --- Swift Codable helper parity ----------------------------------------------------------

    /**
     * `AppMessage.canonicalLineEncoding` (AppMessage.swift:1274): `key=value` lines joined by a single
     * LF, UTF-8, no trailing newline.
     */
    fun canonicalLineEncoding(fields: List<Pair<String, String>>): ByteArray =
        fields.joinToString("\n") { (k, v) -> "$k=$v" }.toByteArray(Charsets.UTF_8)

    /**
     * `AppMessage.normalizedToken` (AppMessage.swift:1280): trims; returns empty if the trimmed value
     * contains '\n', '\r', or '=' (anti-injection).
     */
    fun normalizedToken(raw: String): String {
        val value = raw.trim()
        if (value.any { it == '\n' || it == '\r' || it == '=' }) return ""
        return value
    }

    /**
     * `AppMessage.normalizedUniqueTokens` (AppMessage.swift:1290): trim via normalizedToken, drop
     * empties, sort ascending, de-dup (preserving first occurrence after sort).
     */
    fun normalizedUniqueTokens(raw: List<String>): List<String> =
        raw.map { normalizedToken(it) }
            .filter { it.isNotEmpty() }
            .sorted()
            .distinct()

    /**
     * `AppMessage.normalizedHex` (AppMessage.swift:1304): trim, lowercase, require all-hex; when
     * [exactCount] is non-null also require that length. Returns null if invalid.
     * `normalizedFingerprint` is `normalizedHex(exactCount = 64)` (AppMessage.swift:1300).
     */
    fun normalizedHex(raw: String?, exactCount: Int?): String? {
        val value = raw?.trim()?.lowercase() ?: return null
        if (value.isEmpty()) return null
        if (!value.all { it in '0'..'9' || it in 'a'..'f' }) return null
        if (exactCount != null && value.length != exactCount) return null
        return value
    }

    fun normalizedFingerprint(raw: String?): String? = normalizedHex(raw, exactCount = 64)

    /** `AppMessage.sha256Hex` (AppMessage.swift:1312): lowercase hex SHA-256. */
    fun sha256Hex(data: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(data)
            .joinToString("") { "%02x".format(it) }

    /**
     * `AppMessage.millisecondsSinceEpoch` (AppMessage.swift:1276): Int64(floor(unixSeconds * 1000)).
     * Callers pass the already-floored millis; rendered as a plain decimal string.
     */
    private fun millisecondsString(unixMillis: Long): String = unixMillis.toString()

    /** Standard base64 with padding, matching Swift `Data.base64EncodedString()`. */
    fun base64Standard(data: ByteArray): String =
        java.util.Base64.getEncoder().encodeToString(data)

    private fun canonicalUuid(raw: String): String =
        java.util.UUID.fromString(raw.trim()).toString().lowercase()

    private fun boolBit(value: Boolean): String = if (value) "1" else "0"

    /**
     * Common digest fold for both SAS: first 4 bytes of the digest as a big-endian UInt32, modulo
     * 1_000_000, zero-padded to 6 digits. Reproduces the Swift `loadUnaligned(as: UInt32.self).bigEndian`
     * + `% 1_000_000` + `%06d`.
     */
    private fun sixDigitCode(digest: ByteArray): String {
        val raw =
            ((digest[0].toLong() and 0xFF) shl 24) or
                ((digest[1].toLong() and 0xFF) shl 16) or
                ((digest[2].toLong() and 0xFF) shl 8) or
                (digest[3].toLong() and 0xFF)
        val code = (raw % 1_000_000L).toInt()
        return "%06d".format(code)
    }
}
