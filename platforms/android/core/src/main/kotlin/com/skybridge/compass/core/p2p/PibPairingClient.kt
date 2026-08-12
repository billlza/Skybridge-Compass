package com.skybridge.compass.core.p2p

import com.skybridge.compass.core.webrtc.ProtocolIdentityBinding
import com.skybridge.compass.core.webrtc.ProtocolSigningAlgorithm
import com.skybridge.compass.shared.crypto.Ed25519SoftwareVerifier
import com.skybridge.compass.shared.crypto.providers.AndroidPQCCryptoProvider
import com.skybridge.compass.shared.p2p.P2PHandshakeWire
import com.skybridge.compass.shared.p2p.P2PPibShortAuthString
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.security.SecureRandom
import java.util.UUID

/**
 * Outbound PIB-1 v3 pairing client (Android requester, Mac responder).
 *
 * The Mac intentionally splits the exchange across two short TCP connections:
 *
 *  1. request -> signed candidate (the candidate connection is then released);
 *  2. after the user verifies the SAS, signed confirm -> final acknowledgement.
 *
 * Trust is persisted only after the final acknowledgement has been validated and its responder
 * signature has been verified. This keeps the Android and Mac trust stores symmetric and prevents a
 * candidate-only response from being treated as an authenticated pairing.
 */
class PibPairingClient internal constructor(
    private val identity: LocalP2PIdentity,
    private val bootstrapTransport: BootstrapControlTransport,
    private val signatureVerifier: ProtocolIdentitySignatureVerifier = ProtocolIdentitySignatureVerifier()
) {
    constructor(identity: LocalP2PIdentity) : this(identity, BootstrapControlTransport())

    private val secureRandom = SecureRandom()

    class PairingResult internal constructor(
        val sasCode: String,
        val macFingerprint: String,
        val macSigningAlgorithm: String,
        val macDeviceId: String,
        val macDeviceName: String?,
        val macAliases: List<String>,
        val transactionId: String,
        val requestNonce: ByteArray,
        val requestHashHex: String,
        val candidateHashHex: String,
        val sasTranscriptHashHex: String,
        val requesterDeviceId: String,
        val requesterProtocolSigningAlgorithm: String,
        val requesterProtocolIdentityFingerprint: String,
        val requesterSignature: ByteArray,
        val requestCanonicalPreimage: ByteArray,
        val macProtocolIdentityPublicKey: ByteArray,
        val candidateExpiresAtReferenceSeconds: Double
    )

    sealed class PairingError(message: String) : Exception(message) {
        class Transport(message: String) : PairingError(message)
        class ProtocolRejected(message: String) : PairingError(message)
        class SignatureInvalid(message: String) : PairingError(message)
        class BindingMismatch(message: String) : PairingError(message)
        class IdentityUnavailable(message: String) : PairingError(message)
        class TrustPersistence(
            message: String,
            val finalAckVerified: Boolean,
            val rollbackConfirmed: Boolean
        ) : PairingError(message)
    }

    /**
     * Perform phase one and return the SAS. The returned transcript is intentionally kept in memory
     * by the caller until [confirmPairing] completes; it is not a trust record.
     */
    suspend fun requestPairing(
        host: String,
        port: Int,
        targetDeviceId: String,
        timeoutMs: Int = REQUEST_TIMEOUT_MS
    ): PairingResult = withContext(Dispatchers.IO) {
        val signingKeys = identity.getOrCreateProtocolSigningKeys()
        val requesterDeviceId = identity.deviceId()
        val requesterAlgorithm = ProtocolSigningAlgorithm.ML_DSA_65
        val requesterPublicKey = signingKeys.mlDsa65PublicKeyRaw
            ?: throw PairingError.IdentityUnavailable(
                "strict PIB-1 pairing requires an ML-DSA-65 public key"
            )
        val requesterFingerprint = ProtocolIdentityBinding.computeFingerprint(
            requesterAlgorithm,
            requesterPublicKey
        )
        val transactionId = UUID.randomUUID().toString().lowercase()
        val nonce = ByteArray(24).also(secureRandom::nextBytes)
        val sentAtReferenceSeconds = nowReferenceSeconds()
        val sentAtCanonicalMillis = PibBootstrapWire.referenceSecondsToCanonicalMillis(
            sentAtReferenceSeconds
        )
        val requestedAlgorithms = listOf(
            ProtocolSigningAlgorithm.ML_DSA_65.rawValue,
            ProtocolSigningAlgorithm.ED25519.rawValue
        )

        val requestPreimage = P2PPibShortAuthString.requestCanonicalPreimage(
            version = P2PPibShortAuthString.REQUEST_VERSION,
            transactionId = transactionId,
            requesterDeviceId = requesterDeviceId,
            targetDeviceId = targetDeviceId,
            requestedProtocolSigningAlgorithms = requestedAlgorithms,
            requesterProtocolSigningAlgorithm = requesterAlgorithm.rawValue,
            requesterProtocolIdentityPublicKey = requesterPublicKey,
            requesterProtocolIdentityFingerprint = requesterFingerprint,
            policyRequirePQC = true,
            policyAllowClassicFallback = false,
            routeScope = "lan",
            bonjourEndpointDigest = null,
            nonce = nonce,
            sentAtUnixMillis = sentAtCanonicalMillis
        )
        val requesterSignature = signOrThrow(
            data = requestPreimage,
            algorithm = requesterAlgorithm,
            keys = signingKeys,
            operation = "request"
        )

        val requestPayload = PibBootstrapWire.ProtocolIdentityBindingRequestPayload(
            transactionId = transactionId,
            requesterDeviceId = requesterDeviceId,
            targetDeviceId = targetDeviceId,
            requestedProtocolSigningAlgorithms = requestedAlgorithms,
            requesterProtocolSigningAlgorithm = requesterAlgorithm.rawValue,
            requesterProtocolIdentityPublicKey = requesterPublicKey,
            requesterProtocolIdentityFingerprint = requesterFingerprint,
            requesterSignature = requesterSignature,
            policyRequirePQC = true,
            policyAllowClassicFallback = false,
            routeScope = "lan",
            bonjourEndpointDigest = null,
            nonce = nonce,
            sentAt = sentAtReferenceSeconds
        )

        val responseBytes = exchange(host, port, PibBootstrapWire.encodeRequest(requestPayload), timeoutMs)
        val signed = try {
            PibBootstrapWire.decodeSignedBinding(responseBytes)
        } catch (_: PibBootstrapWire.DecodeException) {
            throw PairingError.ProtocolRejected(
                "Mac returned a malformed signed protocol identity binding"
            )
        }
        validateCandidate(
            signed = signed,
            transactionId = transactionId,
            targetDeviceId = targetDeviceId,
            requestedAlgorithms = requestedAlgorithms,
            nonce = nonce,
            requestHashHex = P2PPibShortAuthString.canonicalRequestHashHex(requestPreimage)
        )

        val macAlgorithm = ProtocolSigningAlgorithm.entries.firstOrNull {
            it.rawValue == signed.protocolSigningAlgorithm
        } ?: throw PairingError.BindingMismatch("Mac selected an unsupported signature algorithm")
        val macFingerprint = P2PPibShortAuthString.normalizedFingerprint(
            signed.protocolIdentityFingerprint
        ) ?: throw PairingError.BindingMismatch("invalid Mac fingerprint")
        val recomputedFingerprint = try {
            ProtocolIdentityBinding.computeFingerprint(macAlgorithm, signed.protocolIdentityPublicKey)
        } catch (e: Exception) {
            throw PairingError.BindingMismatch(
                "Mac protocol public key is invalid (${e::class.java.simpleName})"
            )
        }
        if (recomputedFingerprint != macFingerprint) {
            throw PairingError.BindingMismatch("Mac fingerprint does not match its public key")
        }

        val responsePreimage = P2PPibShortAuthString.responseSignaturePreimage(
            version = signed.version,
            transactionId = signed.transactionId,
            deviceId = signed.deviceId,
            aliases = signed.aliases,
            protocolSigningAlgorithm = signed.protocolSigningAlgorithm,
            protocolIdentityPublicKey = signed.protocolIdentityPublicKey,
            protocolIdentityFingerprint = signed.protocolIdentityFingerprint,
            deviceName = signed.deviceName,
            sentAtUnixMillis = PibBootstrapWire.referenceSecondsToCanonicalMillis(signed.sentAt),
            expiresAtUnixMillis = PibBootstrapWire.referenceSecondsToCanonicalMillis(signed.expiresAt),
            requestNonce = signed.requestNonce,
            requestHashHex = signed.requestHashHex,
            policyRequirePQC = signed.policyRequirePQC,
            policyAllowClassicFallback = signed.policyAllowClassicFallback,
            routeScope = signed.routeScope,
            bonjourEndpointDigest = signed.bonjourEndpointDigest
        )
        val signatureValid = verifySignature(
            algorithm = macAlgorithm,
            data = responsePreimage,
            signature = signed.signature,
            publicKey = signed.protocolIdentityPublicKey
        )
        if (!signatureValid) {
            throw PairingError.SignatureInvalid("Mac signature verification failed")
        }

        val sas = P2PPibShortAuthString.pib1ShortAuthenticationCode(
            requestCanonicalPreimage = requestPreimage,
            requesterSignature = requesterSignature,
            responderSignaturePreimage = responsePreimage,
            responderSignature = signed.signature
        )
        val candidateHashHex = P2PPibShortAuthString.sha256Hex(responsePreimage + signed.signature)
        val sasTranscriptHashHex = P2PPibShortAuthString.sha256Hex(
            "SkyBridge-PIB-1-SAS\n".toByteArray(Charsets.UTF_8) +
                requestPreimage + requesterSignature + responsePreimage + signed.signature
        )

        PairingResult(
            sasCode = sas,
            macFingerprint = macFingerprint,
            macSigningAlgorithm = signed.protocolSigningAlgorithm,
            macDeviceId = P2PPibShortAuthString.normalizedToken(signed.deviceId),
            macDeviceName = normalizeDisplayName(signed.deviceName),
            macAliases = P2PPibShortAuthString.normalizedUniqueTokens(signed.aliases),
            transactionId = transactionId,
            requestNonce = nonce,
            requestHashHex = P2PPibShortAuthString.canonicalRequestHashHex(requestPreimage),
            candidateHashHex = candidateHashHex,
            sasTranscriptHashHex = sasTranscriptHashHex,
            requesterDeviceId = requesterDeviceId,
            requesterProtocolSigningAlgorithm = requesterAlgorithm.rawValue,
            requesterProtocolIdentityFingerprint = requesterFingerprint,
            requesterSignature = requesterSignature,
            requestCanonicalPreimage = requestPreimage,
            macProtocolIdentityPublicKey = signed.protocolIdentityPublicKey,
            candidateExpiresAtReferenceSeconds = signed.expiresAt
        )
    }

    /**
     * Send phase two on a fresh connection and require a valid signed final acknowledgement. The
     * caller must invoke this only after the operator has confirmed the displayed SAS.
     */
    suspend fun confirmPairing(
        host: String,
        port: Int,
        result: PairingResult,
        timeoutMs: Int = CONFIRM_TIMEOUT_MS
    ): TrustedPeerRecord = withContext(Dispatchers.IO) {
        val now = nowReferenceSeconds()
        if (result.candidateExpiresAtReferenceSeconds <= now) {
            throw PairingError.ProtocolRejected("PIB-1 candidate expired before confirmation")
        }
        val signingKeys = identity.getOrCreateProtocolSigningKeys()
        val requesterAlgorithm = ProtocolSigningAlgorithm.entries.firstOrNull {
            it.rawValue == result.requesterProtocolSigningAlgorithm
        } ?: throw PairingError.IdentityUnavailable("requester signing algorithm is unsupported")
        val confirmationNonce = ByteArray(24).also(secureRandom::nextBytes)
        val sentAt = now
        val expiresAt = minOf(result.candidateExpiresAtReferenceSeconds, sentAt + 300.0)
        if (expiresAt <= sentAt) {
            throw PairingError.ProtocolRejected("PIB-1 confirmation validity window is expired")
        }
        val sentAtMillis = PibBootstrapWire.referenceSecondsToCanonicalMillis(sentAt)
        val expiresAtMillis = PibBootstrapWire.referenceSecondsToCanonicalMillis(expiresAt)
        val unsignedConfirmPreimage = P2PPibShortAuthString.confirmSignaturePreimage(
            version = P2PPibShortAuthString.CONFIRM_VERSION,
            transactionId = result.transactionId,
            requesterDeviceId = result.requesterDeviceId,
            responderDeviceId = result.macDeviceId,
            requesterProtocolIdentityFingerprint = result.requesterProtocolIdentityFingerprint,
            responderProtocolIdentityFingerprint = result.macFingerprint,
            requestNonce = result.requestNonce,
            requestHashHex = result.requestHashHex,
            candidateHashHex = result.candidateHashHex,
            sasTranscriptHashHex = result.sasTranscriptHashHex,
            confirmationNonce = confirmationNonce,
            sentAtUnixMillis = sentAtMillis,
            expiresAtUnixMillis = expiresAtMillis,
            policyRequirePQC = true,
            policyAllowClassicFallback = false,
            routeScope = "lan"
        )
        val requesterSignature = signOrThrow(
            data = unsignedConfirmPreimage,
            algorithm = requesterAlgorithm,
            keys = signingKeys,
            operation = "confirmation"
        )
        val confirmHashHex = P2PPibShortAuthString.canonicalConfirmHashHex(
            unsignedConfirmPreimage,
            requesterSignature
        )
        val confirm = PibBootstrapWire.ProtocolIdentityBindingConfirmPayload(
            transactionId = result.transactionId,
            requesterDeviceId = result.requesterDeviceId,
            responderDeviceId = result.macDeviceId,
            requesterProtocolIdentityFingerprint = result.requesterProtocolIdentityFingerprint,
            responderProtocolIdentityFingerprint = result.macFingerprint,
            requestNonce = result.requestNonce,
            requestHashHex = result.requestHashHex,
            candidateHashHex = result.candidateHashHex,
            sasTranscriptHashHex = result.sasTranscriptHashHex,
            confirmationNonce = confirmationNonce,
            sentAt = sentAt,
            expiresAt = expiresAt,
            policyRequirePQC = true,
            policyAllowClassicFallback = false,
            routeScope = "lan",
            requesterSignature = requesterSignature
        )

        val responseBytes = exchange(host, port, PibBootstrapWire.encodeConfirm(confirm), timeoutMs)
        val finalAck = try {
            PibBootstrapWire.decodeFinalAck(responseBytes)
        } catch (_: PibBootstrapWire.DecodeException) {
            throw PairingError.ProtocolRejected(
                "Mac returned a malformed signed PIB-1 final acknowledgement"
            )
        }
        validateFinalAck(
            finalAck = finalAck,
            result = result,
            confirm = confirm,
            confirmHashHex = confirmHashHex,
            nowReferenceSeconds = nowReferenceSeconds()
        )
        val finalAckPreimage = P2PPibShortAuthString.finalAckSignaturePreimage(
            version = finalAck.version,
            transactionId = finalAck.transactionId,
            requesterDeviceId = finalAck.requesterDeviceId,
            responderDeviceId = finalAck.responderDeviceId,
            requesterProtocolIdentityFingerprint = finalAck.requesterProtocolIdentityFingerprint,
            responderProtocolIdentityFingerprint = finalAck.responderProtocolIdentityFingerprint,
            requestNonce = finalAck.requestNonce,
            confirmationNonce = finalAck.confirmationNonce,
            requestHashHex = finalAck.requestHashHex,
            candidateHashHex = finalAck.candidateHashHex,
            confirmHashHex = finalAck.confirmHashHex,
            sasTranscriptHashHex = finalAck.sasTranscriptHashHex,
            accepted = finalAck.accepted,
            sentAtUnixMillis = PibBootstrapWire.referenceSecondsToCanonicalMillis(finalAck.sentAt),
            expiresAtUnixMillis = PibBootstrapWire.referenceSecondsToCanonicalMillis(finalAck.expiresAt),
            policyRequirePQC = finalAck.policyRequirePQC,
            policyAllowClassicFallback = finalAck.policyAllowClassicFallback,
            routeScope = finalAck.routeScope
        )
        val responderAlgorithm = ProtocolSigningAlgorithm.entries.firstOrNull {
            it.rawValue == result.macSigningAlgorithm
        } ?: throw PairingError.BindingMismatch(
            "PIB-1 final acknowledgement uses an unsupported responder signature algorithm"
        )
        val signatureValid = verifySignature(
            algorithm = responderAlgorithm,
            data = finalAckPreimage,
            signature = finalAck.responderSignature,
            publicKey = result.macProtocolIdentityPublicKey
        )
        if (!signatureValid) {
            throw PairingError.SignatureInvalid("PIB-1 final acknowledgement signature verification failed")
        }
        persistVerifiedFinalAckAuthority(
            trustedPeerStore = identity.trustedPeerStore(),
            deviceId = result.macDeviceId,
            protocolPublicKeyFingerprint = result.macFingerprint,
            name = result.macDeviceName,
            protocolSigningAlgorithm = result.macSigningAlgorithm,
            aliasIds = result.macAliases
        )
    }

    private suspend fun signOrThrow(
        data: ByteArray,
        algorithm: ProtocolSigningAlgorithm,
        keys: LocalP2PIdentity.ProtocolSigningKeys,
        operation: String
    ): ByteArray {
        return try {
            sign(data, algorithm, keys)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            throw PairingError.IdentityUnavailable(
                "failed to sign PIB-1 $operation (${e::class.java.simpleName})"
            )
        }
    }

    private suspend fun verifySignature(
        algorithm: ProtocolSigningAlgorithm,
        data: ByteArray,
        signature: ByteArray,
        publicKey: ByteArray
    ): Boolean = verifyResponderSignature(
        algorithm = algorithm,
        data = data,
        signature = signature,
        publicKey = publicKey,
        signatureVerifier = signatureVerifier
    )

    private fun validateCandidateFields(
        candidate: PibBootstrapWire.SignedProtocolIdentityBindingPayload
    ) {
        canonicalUuid(candidate.transactionId)
        validateDeviceId(candidate.deviceId, "candidate device id")
        if (candidate.aliases.size > MAX_ALIAS_COUNT) {
            throw PairingError.BindingMismatch("candidate contains too many aliases")
        }
        candidate.aliases.forEach { validateText(it, MAX_ALIAS_LENGTH, "candidate alias") }
        candidate.deviceName?.let { validateText(it, MAX_DEVICE_NAME_LENGTH, "candidate device name") }
        validateText(candidate.protocolSigningAlgorithm, MAX_ALGORITHM_LENGTH, "candidate algorithm")
        validateFingerprint(candidate.protocolIdentityFingerprint, "candidate fingerprint")
        if (candidate.protocolIdentityPublicKey.isEmpty() ||
            candidate.protocolIdentityPublicKey.size > MAX_PUBLIC_KEY_BYTES
        ) {
            throw PairingError.BindingMismatch("candidate public key length is invalid")
        }
        if (candidate.signature.isEmpty() || candidate.signature.size > MAX_SIGNATURE_BYTES) {
            throw PairingError.BindingMismatch("candidate signature length is invalid")
        }
        if (candidate.requestNonce.size !in MIN_NONCE_BYTES..MAX_NONCE_BYTES) {
            throw PairingError.BindingMismatch("candidate nonce length is invalid")
        }
        if (candidate.requestHashHex == null ||
            P2PPibShortAuthString.normalizedHex(candidate.requestHashHex, exactCount = 64) == null
        ) {
            throw PairingError.BindingMismatch("candidate request hash is invalid")
        }
        candidate.bonjourEndpointDigest?.let {
            validateText(it, MAX_DIGEST_LENGTH, "candidate endpoint digest")
        }
        if (!candidate.sentAt.isFinite() || !candidate.expiresAt.isFinite()) {
            throw PairingError.ProtocolRejected("candidate timestamp is not finite")
        }
    }

    private fun validateFinalAckFields(
        finalAck: PibBootstrapWire.SignedProtocolIdentityBindingFinalAckPayload
    ) {
        canonicalUuid(finalAck.transactionId)
        validateDeviceId(finalAck.requesterDeviceId, "final acknowledgement requester device id")
        validateDeviceId(finalAck.responderDeviceId, "final acknowledgement responder device id")
        validateFingerprint(
            finalAck.requesterProtocolIdentityFingerprint,
            "final acknowledgement requester fingerprint"
        )
        validateFingerprint(
            finalAck.responderProtocolIdentityFingerprint,
            "final acknowledgement responder fingerprint"
        )
        if (finalAck.requestNonce.size !in MIN_NONCE_BYTES..MAX_NONCE_BYTES ||
            finalAck.confirmationNonce.size !in MIN_NONCE_BYTES..MAX_NONCE_BYTES
        ) {
            throw PairingError.BindingMismatch("final acknowledgement nonce length is invalid")
        }
        listOf(
            "request hash" to finalAck.requestHashHex,
            "candidate hash" to finalAck.candidateHashHex,
            "confirm hash" to finalAck.confirmHashHex,
            "SAS transcript hash" to finalAck.sasTranscriptHashHex
        ).forEach { (label, value) ->
            if (P2PPibShortAuthString.normalizedHex(value, exactCount = 64) == null) {
                throw PairingError.BindingMismatch("final acknowledgement $label is invalid")
            }
        }
        if (finalAck.responderSignature.isEmpty() ||
            finalAck.responderSignature.size > MAX_SIGNATURE_BYTES
        ) {
            throw PairingError.BindingMismatch("final acknowledgement signature length is invalid")
        }
        if (!finalAck.sentAt.isFinite() || !finalAck.expiresAt.isFinite()) {
            throw PairingError.ProtocolRejected("final acknowledgement timestamp is not finite")
        }
    }

    private fun validateDeviceId(value: String, label: String) {
        val normalized = try {
            ProtocolIdentityBinding.normalizedDeviceId(value)
        } catch (_: IllegalArgumentException) {
            throw PairingError.BindingMismatch("$label is invalid")
        }
        if (normalized != value) {
            throw PairingError.BindingMismatch("$label is invalid")
        }
    }

    private fun validateFingerprint(value: String, label: String) {
        if (P2PPibShortAuthString.normalizedFingerprint(value) == null) {
            throw PairingError.BindingMismatch("$label is invalid")
        }
    }

    private fun validateText(value: String, maxLength: Int, label: String) {
        validateCandidateText(value, maxLength, label)
    }

    private fun normalizeDisplayName(value: String?): String? {
        if (value == null) return null
        validateText(value, MAX_DEVICE_NAME_LENGTH, "candidate device name")
        return value.trim().ifEmpty { null }
    }

    private fun validateCandidate(
        signed: PibBootstrapWire.SignedProtocolIdentityBindingPayload,
        transactionId: String,
        targetDeviceId: String,
        requestedAlgorithms: Collection<String>,
        nonce: ByteArray,
        requestHashHex: String
    ) {
        validateCandidateFields(signed)
        if (signed.version != P2PPibShortAuthString.RESPONSE_VERSION) {
            throw PairingError.ProtocolRejected("unsupported PIB-1 signed candidate version=${signed.version}")
        }
        if (canonicalUuid(signed.transactionId) != canonicalUuid(transactionId)) {
            throw PairingError.BindingMismatch("candidate transaction id mismatch")
        }
        if (signed.protocolSigningAlgorithm !in requestedAlgorithms) {
            throw PairingError.ProtocolRejected(
                "Mac selected an unrequested protocol signing algorithm"
            )
        }
        if (!signed.policyRequirePQC || signed.policyAllowClassicFallback || signed.routeScope.trim().lowercase() != "lan") {
            throw PairingError.ProtocolRejected("Mac candidate did not satisfy strict LAN PQC policy")
        }
        if (!signed.requestNonce.contentEquals(nonce)) {
            throw PairingError.BindingMismatch("candidate nonce mismatch")
        }
        if (signed.requestHashHex?.lowercase() != requestHashHex) {
            throw PairingError.BindingMismatch("candidate request-hash mismatch")
        }
        val target = P2PPibShortAuthString.normalizedToken(targetDeviceId)
        val candidateIds = P2PPibShortAuthString.normalizedUniqueTokens(
            listOf(signed.deviceId) + signed.aliases
        )
        if (target.isEmpty() || target !in candidateIds) {
            throw PairingError.BindingMismatch("candidate device id does not match the requested Mac")
        }
        val now = nowReferenceSeconds()
        if (signed.expiresAt <= now || signed.expiresAt <= signed.sentAt || signed.expiresAt - signed.sentAt > 300.0) {
            throw PairingError.ProtocolRejected("Mac candidate validity window is invalid or expired")
        }
        if (signed.sentAt - now > 30.0) {
            throw PairingError.ProtocolRejected("Mac candidate timestamp is too far in the future")
        }
    }

    private fun validateFinalAck(
        finalAck: PibBootstrapWire.SignedProtocolIdentityBindingFinalAckPayload,
        result: PairingResult,
        confirm: PibBootstrapWire.ProtocolIdentityBindingConfirmPayload,
        confirmHashHex: String,
        nowReferenceSeconds: Double
    ) {
        validateFinalAckFields(finalAck)
        if (finalAck.version != P2PPibShortAuthString.FINAL_ACK_VERSION || !finalAck.accepted) {
            throw PairingError.ProtocolRejected("Mac rejected the PIB-1 confirmation")
        }
        if (!finalAck.policyRequirePQC || finalAck.policyAllowClassicFallback || finalAck.routeScope.trim().lowercase() != "lan") {
            throw PairingError.ProtocolRejected("final acknowledgement did not satisfy strict LAN PQC policy")
        }
        if (canonicalUuid(finalAck.transactionId) != canonicalUuid(result.transactionId)) {
            throw PairingError.BindingMismatch("final acknowledgement transaction id mismatch")
        }
        if (finalAck.requesterDeviceId != result.requesterDeviceId || finalAck.responderDeviceId != result.macDeviceId) {
            throw PairingError.BindingMismatch("final acknowledgement device binding mismatch")
        }
        if (P2PPibShortAuthString.normalizedFingerprint(finalAck.requesterProtocolIdentityFingerprint) !=
            result.requesterProtocolIdentityFingerprint ||
            P2PPibShortAuthString.normalizedFingerprint(finalAck.responderProtocolIdentityFingerprint) !=
            result.macFingerprint
        ) {
            throw PairingError.BindingMismatch("final acknowledgement fingerprint binding mismatch")
        }
        if (!finalAck.requestNonce.contentEquals(result.requestNonce) ||
            !finalAck.confirmationNonce.contentEquals(confirm.confirmationNonce)
        ) {
            throw PairingError.BindingMismatch("final acknowledgement nonce binding mismatch")
        }
        if (finalAck.requestHashHex.lowercase() != result.requestHashHex ||
            finalAck.candidateHashHex.lowercase() != result.candidateHashHex ||
            finalAck.confirmHashHex.lowercase() != confirmHashHex ||
            finalAck.sasTranscriptHashHex.lowercase() != result.sasTranscriptHashHex
        ) {
            throw PairingError.BindingMismatch("final acknowledgement transcript hash mismatch")
        }
        if (finalAck.expiresAt <= nowReferenceSeconds ||
            finalAck.expiresAt <= finalAck.sentAt ||
            finalAck.expiresAt - finalAck.sentAt > 300.0 ||
            finalAck.sentAt - nowReferenceSeconds > 30.0
        ) {
            throw PairingError.ProtocolRejected("final acknowledgement validity window is invalid or expired")
        }
    }

    private suspend fun sign(
        data: ByteArray,
        algorithm: ProtocolSigningAlgorithm,
        keys: LocalP2PIdentity.ProtocolSigningKeys
    ): ByteArray = when (algorithm) {
        ProtocolSigningAlgorithm.ED25519 ->
            P2PHandshakeWire.signEd25519Public(data, keys.ed25519PrivateKey)
        ProtocolSigningAlgorithm.ML_DSA_65 -> {
            val privateKey = requireNotNull(keys.mlDsa65PrivateKeyRaw) {
                "ML-DSA-65 private key unavailable"
            }
            AndroidPQCCryptoProvider().sign(data, privateKey)
        }
    }

    private suspend fun exchange(host: String, port: Int, frame: ByteArray, timeoutMs: Int): ByteArray =
        try {
            bootstrapTransport.exchange(host = host, port = port, body = frame, timeoutMs = timeoutMs)
        } catch (e: BootstrapControlTransport.TransportException) {
            throw PairingError.Transport(e.message ?: "bootstrap-control exchange failed")
        }

    private fun canonicalUuid(raw: String): String {
        return try {
            UUID.fromString(raw.trim()).toString().lowercase()
        } catch (_: IllegalArgumentException) {
            throw PairingError.BindingMismatch("invalid PIB-1 transaction id")
        }
    }

    private fun nowReferenceSeconds(): Double =
        (System.currentTimeMillis().toDouble() / 1000.0) - PibBootstrapWire.SWIFT_REFERENCE_EPOCH_UNIX_SECONDS

    companion object {
        internal fun persistVerifiedFinalAckAuthority(
            trustedPeerStore: TrustedPeerStore,
            deviceId: String,
            protocolPublicKeyFingerprint: String,
            name: String?,
            protocolSigningAlgorithm: String,
            aliasIds: Collection<String>
        ): TrustedPeerRecord = try {
            trustedPeerStore.upsertExplicitlyApprovedCurrentPathAuthority(
                deviceId = deviceId,
                protocolPublicKeyFingerprint = protocolPublicKeyFingerprint,
                name = name,
                protocolSigningAlgorithm = protocolSigningAlgorithm,
                aliasIds = aliasIds
            )
        } catch (error: TrustedPeerStorePersistenceException) {
            throw PairingError.TrustPersistence(
                message = "PIB-1 final acknowledgement verified but local trust persistence failed",
                finalAckVerified = true,
                rollbackConfirmed = error.rollbackConfirmed
            )
        } catch (_: TrustedPeerStoreCorruptionException) {
            throw PairingError.TrustPersistence(
                message = "PIB-1 final acknowledgement verified but local trust store is corrupted",
                finalAckVerified = true,
                rollbackConfirmed = true
            )
        }

        internal suspend fun verifyResponderSignature(
            algorithm: ProtocolSigningAlgorithm,
            data: ByteArray,
            signature: ByteArray,
            publicKey: ByteArray,
            signatureVerifier: ProtocolIdentitySignatureVerifier = ProtocolIdentitySignatureVerifier()
        ): Boolean = try {
            signatureVerifier.verify(
                algorithm = algorithm,
                data = data,
                signature = signature,
                publicKey = publicKey
            )
        } catch (e: CancellationException) {
            throw e
        } catch (e: Ed25519SoftwareVerifier.Failure.InvalidInputLength) {
            throw PairingError.BindingMismatch(e.message ?: "invalid Ed25519 signature input")
        } catch (e: Ed25519SoftwareVerifier.Failure.InvalidPublicKey) {
            throw PairingError.BindingMismatch(e.message ?: "invalid Ed25519 public key")
        } catch (e: IllegalArgumentException) {
            throw PairingError.BindingMismatch(e.message ?: "invalid protocol signature input")
        } catch (e: Exception) {
            throw PairingError.IdentityUnavailable(
                "${algorithm.rawValue} signature verification is unavailable (${e::class.java.simpleName})"
            )
        }

        /**
         * Validate a candidate text field before it participates in the signed canonical preimage.
         * `normalizedToken` deliberately maps injection-bearing values to the empty string; keeping
         * the original value after that lossy mapping would make a signed null/empty field appear as
         * attacker-controlled metadata to the UI or trust store.
         */
        internal fun validateCandidateText(value: String, maxLength: Int, label: String) {
            if (value.length > maxLength || value.any {
                    it.code < 0x20 || it.code == 0x7F || it == '\u2028' || it == '\u2029'
                } || P2PPibShortAuthString.normalizedToken(value) != value.trim()) {
                throw PairingError.BindingMismatch("$label is invalid")
            }
        }

        private const val REQUEST_TIMEOUT_MS = 30_000
        private const val CONFIRM_TIMEOUT_MS = 315_000
        private const val MIN_NONCE_BYTES = 16
        private const val MAX_NONCE_BYTES = 128
        private const val MAX_ALIAS_COUNT = 32
        private const val MAX_ALIAS_LENGTH = 256
        private const val MAX_DEVICE_NAME_LENGTH = 256
        private const val MAX_ALGORITHM_LENGTH = 64
        private const val MAX_DIGEST_LENGTH = 128
        private const val MAX_PUBLIC_KEY_BYTES = 4096
        private const val MAX_SIGNATURE_BYTES = 8192
    }
}
