package com.skybridge.compass.core.p2p

import com.skybridge.compass.core.webrtc.ProtocolIdentityBinding
import com.skybridge.compass.core.webrtc.ProtocolSigningAlgorithm
import com.skybridge.compass.shared.crypto.Ed25519SoftwareVerifier
import com.skybridge.compass.shared.p2p.P2PCryptoSuite
import kotlinx.coroutines.CancellationException
import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import java.util.Base64
import java.util.Locale

internal object SkrCanonical {
    const val CURRENT_VERSION = 1
    const val ROUTE_SCOPE_LAN = "lan"
    const val REQUEST_MAXIMUM_AGE_MILLIS = 120_000L
    const val MAXIMUM_FUTURE_SKEW_MILLIS = 30_000L

    private const val POLICY_DOMAIN = "SkyBridge-SKR-1-Policy"
    private const val REQUEST_DOMAIN = "SkyBridge-SKR-1-Request"
    private const val RESPONSE_DOMAIN = "SkyBridge-SKR-1-SignedKEMRefresh"
    private val HEX = Regex("^[0-9a-f]+$")

    fun policyHashHex(
        requirePqc: Boolean = true,
        allowClassicFallback: Boolean = false,
        routeScope: String = ROUTE_SCOPE_LAN
    ): String = sha256Hex(
        canonicalLines(
            listOf(
                "domain" to POLICY_DOMAIN,
                "version" to CURRENT_VERSION.toString(),
                "policyRequirePQC" to requirePqc.bit(),
                "policyAllowClassicFallback" to allowClassicFallback.bit(),
                "routeScope" to routeScope.trim().lowercase(Locale.ROOT)
            )
        )
    )

    fun requestPreimage(request: SkrBootstrapWire.KemRefreshRequestPayload): ByteArray =
        canonicalLines(
            listOf(
                "domain" to REQUEST_DOMAIN,
                "version" to request.version.toString(),
                "requesterDeviceId" to normalizedToken(request.requesterDeviceId),
                "targetDeviceId" to normalizedToken(request.targetDeviceId),
                "requesterProtocolIdentityFingerprint" to normalizedFingerprint(
                    request.requesterProtocolIdentityFingerprint
                ).orEmpty(),
                "targetProtocolIdentityFingerprint" to normalizedFingerprint(
                    request.targetProtocolIdentityFingerprint
                ).orEmpty(),
                "requestedSuiteWireIds" to request.requestedSuiteWireIds
                    .sorted()
                    .joinToString(",", transform = ::wireIdHex),
                "policyRequirePQC" to request.policyRequirePQC.bit(),
                "policyAllowClassicFallback" to request.policyAllowClassicFallback.bit(),
                "policyHashHex" to normalizedHex(request.policyHashHex, exactLength = 64).orEmpty(),
                "routeScope" to request.routeScope.trim().lowercase(Locale.ROOT),
                "bonjourEndpointDigest" to normalizedToken(request.bonjourEndpointDigest.orEmpty()),
                "nonce" to Base64.getEncoder().encodeToString(request.nonce),
                "sentAtMs" to canonicalMillis(request.sentAt).toString()
            )
        )

    fun requestHashHex(request: SkrBootstrapWire.KemRefreshRequestPayload): String =
        sha256Hex(requestPreimage(request))

    fun responseSignaturePreimage(payload: SkrBootstrapWire.SignedKemRefreshPayload): ByteArray {
        val normalizedKeys = normalizedKemKeys(payload.kemPublicKeys)
        val suiteNames = normalizedKeys.map { suiteName(it.suiteWireId) }.sorted().joinToString(",")
        val suiteWireIds = normalizedKeys.map { wireIdHex(it.suiteWireId) }.sorted().joinToString(",")
        return canonicalLines(
            listOf(
                "domain" to RESPONSE_DOMAIN,
                "version" to payload.version.toString(),
                "deviceId" to normalizedToken(payload.deviceId),
                "aliases" to normalizedUniqueTokens(payload.aliases).joinToString(","),
                "protocolSigningAlgorithm" to payload.protocolSigningAlgorithm.trim(),
                "protocolIdentityPublicKeyHash" to sha256Hex(payload.protocolIdentityPublicKey),
                "protocolIdentityFingerprint" to normalizedFingerprint(
                    payload.protocolIdentityFingerprint
                ).orEmpty(),
                "suiteNames" to suiteNames,
                "suiteWireIds" to suiteWireIds,
                "kemPublicKeyHash" to kemPublicKeyHashHex(normalizedKeys),
                "keyId" to normalizedToken(payload.keyId),
                "generation" to payload.generation.toString(),
                "sentAtMs" to canonicalMillis(payload.sentAt).toString(),
                "expiresAtMs" to canonicalMillis(payload.expiresAt).toString(),
                "requestNonce" to Base64.getEncoder().encodeToString(payload.requestNonce),
                "requestHashHex" to normalizedHex(payload.requestHashHex).orEmpty(),
                "policyRequirePQC" to payload.policyRequirePQC.bit(),
                "policyAllowClassicFallback" to payload.policyAllowClassicFallback.bit(),
                "routeScope" to payload.routeScope.trim().lowercase(Locale.ROOT),
                "bonjourEndpointDigest" to normalizedToken(payload.bonjourEndpointDigest.orEmpty())
            )
        )
    }

    fun payloadHashHex(payload: SkrBootstrapWire.SignedKemRefreshPayload): String =
        sha256Hex(responseSignaturePreimage(payload))

    fun normalizedToken(raw: String): String {
        val value = raw.trim()
        return if (value.any { it == '\n' || it == '\r' || it == '=' }) "" else value
    }

    fun normalizedUniqueTokens(raw: List<String>): List<String> =
        raw.map(::normalizedToken).filter(String::isNotEmpty).distinct().sorted()

    fun normalizedFingerprint(raw: String?): String? = normalizedHex(raw, exactLength = 64)

    fun normalizedHex(raw: String?, exactLength: Int? = null): String? {
        val value = raw?.trim()?.lowercase(Locale.ROOT)?.takeIf(String::isNotEmpty) ?: return null
        if (!HEX.matches(value)) return null
        if (exactLength != null && value.length != exactLength) return null
        return value
    }

    fun sha256Hex(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256")
        .digest(bytes)
        .joinToString(separator = "") { "%02x".format(Locale.ROOT, it.toInt() and 0xff) }

    fun kemPublicKeyHashHex(keys: List<SkrBootstrapWire.KemPublicKeyInfo>): String {
        val material = ByteArrayOutputStream()
        material.write("SkyBridge-SKR-1-KEMPublicKeys\n".toByteArray(Charsets.UTF_8))
        for (key in normalizedKemKeys(keys)) {
            material.write(key.suiteWireId and 0xff)
            material.write((key.suiteWireId ushr 8) and 0xff)
            val length = key.publicKey.size
            material.write(length and 0xff)
            material.write((length ushr 8) and 0xff)
            material.write((length ushr 16) and 0xff)
            material.write((length ushr 24) and 0xff)
            material.write(key.publicKey)
        }
        return sha256Hex(material.toByteArray())
    }

    private fun normalizedKemKeys(
        keys: List<SkrBootstrapWire.KemPublicKeyInfo>
    ): List<SkrBootstrapWire.KemPublicKeyInfo> {
        val bySuite = linkedMapOf<Int, SkrBootstrapWire.KemPublicKeyInfo>()
        keys.filter { it.publicKey.isNotEmpty() }.forEach { bySuite[it.suiteWireId] = it }
        return bySuite.toSortedMap().values.toList()
    }

    private fun suiteName(wireId: Int): String = when (wireId) {
        P2PCryptoSuite.X_WING.wireId.toInt() -> "X-Wing"
        P2PCryptoSuite.MLKEM_768.wireId.toInt() -> "ML-KEM-768"
        P2PCryptoSuite.MLKEM_768_FS_COMPAT.wireId.toInt() -> "ML-KEM-768-FS"
        P2PCryptoSuite.Q_PERIAPT_CONTEXT_BOUND.wireId.toInt() -> "Q-Periapt-ContextBound"
        else -> "unknown-$wireId"
    }

    private fun wireIdHex(wireId: Int): String =
        String.format(Locale.ROOT, "0x%04X", wireId)

    fun canonicalMillis(referenceSeconds: Double): Long {
        require(referenceSeconds.isFinite()) { "SKR-1 timestamp is not finite" }
        val unixMillis = kotlin.math.floor(
            (referenceSeconds + PibBootstrapWire.SWIFT_REFERENCE_EPOCH_UNIX_SECONDS) * 1_000.0
        )
        require(unixMillis.isFinite() && unixMillis >= Long.MIN_VALUE.toDouble() &&
            unixMillis < LONG_MAX_EXCLUSIVE_AS_DOUBLE
        ) { "SKR-1 timestamp is outside Int64 milliseconds" }
        return unixMillis.toLong()
    }

    private fun canonicalLines(fields: List<Pair<String, String>>): ByteArray =
        fields.joinToString("\n") { (key, value) -> "$key=$value" }.toByteArray(Charsets.UTF_8)

    private fun Boolean.bit(): String = if (this) "1" else "0"

    private const val LONG_MAX_EXCLUSIVE_AS_DOUBLE = 9_223_372_036_854_775_808.0
}

internal data class VerifiedSignedLanKemRefresh(
    val responseDeviceId: String,
    val aliases: List<String>,
    val protocolIdentityFingerprint: String,
    val kemPublicKeys: List<AppMessage.KemPublicKeyInfo>,
    val keyId: String,
    val generation: Long,
    val sentAtMillis: Long,
    val expiresAtMillis: Long,
    val payloadHashHex: String,
    val kemPublicKeyHashHex: String,
    val signedSuiteWireIds: List<Int>
) {
    val allDeviceIds: List<String>
        get() = (listOf(responseDeviceId) + aliases).distinct()
}

internal class SignedLanKemRefreshValidationException(
    message: String,
    cause: Throwable? = null
) : Exception(message, cause)

internal class SignedLanKemRefreshVerificationUnavailableException(
    message: String,
    cause: Throwable
) : Exception(message, cause)

internal class SignedLanKemRefreshVerifier(
    private val signatureVerifier: ProtocolIdentitySignatureVerifier = ProtocolIdentitySignatureVerifier()
) {
    suspend fun verify(
        request: SkrBootstrapWire.KemRefreshRequestPayload,
        response: SkrBootstrapWire.SignedKemRefreshPayload,
        pinnedProtocolFingerprint: String,
        minimumGeneration: Long?,
        nowMillis: Long = System.currentTimeMillis()
    ): VerifiedSignedLanKemRefresh {
        validateRequest(request = request, nowMillis = nowMillis)
        val pin = SkrCanonical.normalizedFingerprint(pinnedProtocolFingerprint)
            ?: invalid("pinned protocol identity fingerprint is invalid")
        val requestTargetFingerprint = SkrCanonical.normalizedFingerprint(
            request.targetProtocolIdentityFingerprint
        ) ?: invalid("request target protocol identity fingerprint is invalid")
        if (requestTargetFingerprint != pin) {
            invalid("request target protocol identity does not match the active PIB pin")
        }
        if (response.version != SkrCanonical.CURRENT_VERSION) invalid("response version is invalid")
        val deviceId = requiredToken(response.deviceId, "response device id")
        if (response.aliases.size > MAX_ALIAS_COUNT) invalid("response contains too many aliases")
        val aliases = response.aliases.map { requiredToken(it, "response alias") }
            .distinct()
            .sorted()
        if (aliases.size != response.aliases.size) invalid("response aliases are duplicated")

        val algorithm = ProtocolSigningAlgorithm.entries.firstOrNull {
            it.rawValue == response.protocolSigningAlgorithm.trim()
        } ?: invalid("response signature algorithm is unsupported")
        val claimedFingerprint = SkrCanonical.normalizedFingerprint(response.protocolIdentityFingerprint)
            ?: invalid("response protocol identity fingerprint is invalid")
        val computedFingerprint = try {
            ProtocolIdentityBinding.computeFingerprint(algorithm, response.protocolIdentityPublicKey)
        } catch (e: IllegalArgumentException) {
            throw SignedLanKemRefreshValidationException(
                "response protocol identity public key is invalid (${e.message ?: "encoding"})"
            )
        }
        if (computedFingerprint != claimedFingerprint) {
            invalid("response protocol identity fingerprint does not match its public key")
        }
        if (claimedFingerprint != pin) invalid("response protocol identity does not match the active PIB pin")

        if (!response.policyRequirePQC || response.policyAllowClassicFallback) {
            invalid("response policy is not strict PQC")
        }
        if (response.routeScope.trim().lowercase(Locale.ROOT) != SkrCanonical.ROUTE_SCOPE_LAN) {
            invalid("response route scope is invalid")
        }
        val keyId = requiredToken(response.keyId, "response key id")
        if (response.generation < 0L) invalid("response generation is invalid")
        if (minimumGeneration != null && response.generation < minimumGeneration) {
            invalid("response generation rollback detected")
        }
        validateFiniteTimestamp(response.sentAt, "response sentAt")
        validateFiniteTimestamp(response.expiresAt, "response expiresAt")
        val sentAtMillis = canonicalMillis(response.sentAt, "response sentAt")
        val expiresAtMillis = canonicalMillis(response.expiresAt, "response expiresAt")
        if (sentAtMillis > saturatingAdd(nowMillis, SkrCanonical.MAXIMUM_FUTURE_SKEW_MILLIS)) {
            invalid("response timestamp is too far in the future")
        }
        if (expiresAtMillis <= sentAtMillis) invalid("response validity window is invalid")
        if (expiresAtMillis <= nowMillis) invalid("response is expired")
        if (response.requestNonce.size !in MIN_NONCE_BYTES..MAX_NONCE_BYTES ||
            !response.requestNonce.contentEquals(request.nonce)
        ) {
            invalid("response request nonce does not match")
        }
        if (SkrCanonical.normalizedHex(response.requestHashHex, exactLength = 64) !=
            SkrCanonical.requestHashHex(request)
        ) {
            invalid("response request hash does not match")
        }
        if (SkrCanonical.normalizedToken(response.bonjourEndpointDigest.orEmpty()) !=
            SkrCanonical.normalizedToken(request.bonjourEndpointDigest.orEmpty())
        ) {
            invalid("response Bonjour endpoint digest does not match")
        }
        val targetDeviceId = requiredToken(request.targetDeviceId, "request target device id")
        if (targetDeviceId !in (listOf(deviceId) + aliases)) {
            invalid("response device id does not match request target")
        }

        if (response.kemPublicKeys.isEmpty()) invalid("response contains no KEM public key")
        val requestedSuites = request.requestedSuiteWireIds.toSet()
        val seenSuites = mutableSetOf<Int>()
        val keys = response.kemPublicKeys.map { key ->
            if (!seenSuites.add(key.suiteWireId)) invalid("response contains duplicate KEM suite")
            val suite = knownSuite(key.suiteWireId)
            if (key.suiteWireId !in requestedSuites) invalid("response KEM suite was not requested")
            requireStrictSkrSuite(suite, key.suiteWireId)
            try {
                PeerKemPublicKeyValidation.validatePublicKey(suite, key.publicKey)
            } catch (_: IllegalArgumentException) {
                invalid("response KEM public key is invalid for wireId=${key.suiteWireId}")
            }
            AppMessage.KemPublicKeyInfo(suiteWireId = key.suiteWireId, publicKey = key.publicKey.copyOf())
        }.sortedBy(AppMessage.KemPublicKeyInfo::suiteWireId)

        if (response.signature.isEmpty() || response.signature.size > MAX_SIGNATURE_BYTES) {
            invalid("response signature length is invalid")
        }
        val preimage = SkrCanonical.responseSignaturePreimage(response)
        val signatureValid = try {
            signatureVerifier.verify(
                algorithm = algorithm,
                data = preimage,
                signature = response.signature,
                publicKey = response.protocolIdentityPublicKey
            )
        } catch (e: CancellationException) {
            throw e
        } catch (e: Ed25519SoftwareVerifier.Failure.InvalidInputLength) {
            throw SignedLanKemRefreshValidationException(
                "SKR-1 response signature input is invalid",
                e
            )
        } catch (e: Ed25519SoftwareVerifier.Failure.InvalidPublicKey) {
            throw SignedLanKemRefreshValidationException(
                "SKR-1 response signature public key is invalid",
                e
            )
        } catch (e: IllegalArgumentException) {
            throw SignedLanKemRefreshValidationException(
                "SKR-1 response signature input is invalid",
                e
            )
        } catch (e: Exception) {
            throw SignedLanKemRefreshVerificationUnavailableException(
                "SKR-1 ${algorithm.rawValue} signature verification is unavailable",
                e
            )
        }
        if (!signatureValid) invalid("response signature is invalid")

        return VerifiedSignedLanKemRefresh(
            responseDeviceId = deviceId,
            aliases = aliases,
            protocolIdentityFingerprint = claimedFingerprint,
            kemPublicKeys = keys,
            keyId = keyId,
            generation = response.generation,
            sentAtMillis = sentAtMillis,
            expiresAtMillis = expiresAtMillis,
            payloadHashHex = SkrCanonical.sha256Hex(preimage),
            kemPublicKeyHashHex = SkrCanonical.kemPublicKeyHashHex(response.kemPublicKeys),
            signedSuiteWireIds = keys.map(AppMessage.KemPublicKeyInfo::suiteWireId)
        )
    }

    private fun validateRequest(
        request: SkrBootstrapWire.KemRefreshRequestPayload,
        nowMillis: Long
    ) {
        if (request.version != SkrCanonical.CURRENT_VERSION) invalid("request version is invalid")
        requiredToken(request.requesterDeviceId, "request requester device id")
        requiredToken(request.targetDeviceId, "request target device id")
        if (SkrCanonical.normalizedFingerprint(request.requesterProtocolIdentityFingerprint) == null) {
            invalid("request requester protocol identity fingerprint is invalid")
        }
        if (SkrCanonical.normalizedFingerprint(request.targetProtocolIdentityFingerprint) == null) {
            invalid("request target protocol identity fingerprint is invalid")
        }
        if (!request.policyRequirePQC || request.policyAllowClassicFallback) {
            invalid("request policy is not strict PQC")
        }
        if (request.routeScope.trim().lowercase(Locale.ROOT) != SkrCanonical.ROUTE_SCOPE_LAN) {
            invalid("request route scope is invalid")
        }
        if (SkrCanonical.normalizedHex(request.policyHashHex, exactLength = 64) !=
            SkrCanonical.policyHashHex(
                requirePqc = request.policyRequirePQC,
                allowClassicFallback = request.policyAllowClassicFallback,
                routeScope = request.routeScope
            )
        ) {
            invalid("request policy hash is invalid")
        }
        if (request.nonce.size !in MIN_NONCE_BYTES..MAX_NONCE_BYTES) invalid("request nonce is invalid")
        validateFiniteTimestamp(request.sentAt, "request sentAt")
        val sentAtMillis = canonicalMillis(request.sentAt, "request sentAt")
        if (sentAtMillis > saturatingAdd(nowMillis, SkrCanonical.MAXIMUM_FUTURE_SKEW_MILLIS)) {
            invalid("request timestamp is too far in the future")
        }
        if (sentAtMillis < saturatingSubtract(nowMillis, SkrCanonical.REQUEST_MAXIMUM_AGE_MILLIS)) {
            invalid("request is expired")
        }
        if (request.requestedSuiteWireIds.isEmpty() ||
            request.requestedSuiteWireIds.distinct().size != request.requestedSuiteWireIds.size
        ) {
            invalid("request suite list is empty or duplicated")
        }
        request.requestedSuiteWireIds.forEach(::strictSupportedSuite)
        if (request.requestedSuiteWireIds.toSet() != REQUIRED_SKR_SUITE_WIRE_IDS) {
            invalid("request KEM suite set must contain X-Wing and ML-KEM-768")
        }
        request.bonjourEndpointDigest?.let { digest ->
            if (SkrCanonical.normalizedHex(digest, exactLength = 64) == null) {
                invalid("request Bonjour endpoint digest is invalid")
            }
        }
    }

    private fun strictSupportedSuite(wireId: Int): P2PCryptoSuite {
        val suite = knownSuite(wireId)
        requireStrictSkrSuite(suite, wireId)
        return suite
    }

    private fun knownSuite(wireId: Int): P2PCryptoSuite {
        if (wireId !in 0..0xffff) invalid("KEM suite wireId is outside UInt16 range: $wireId")
        return P2PCryptoSuite.fromWireId(wireId.toUShort())
            ?: invalid("unknown KEM suite wireId=$wireId")
    }

    private fun requireStrictSkrSuite(suite: P2PCryptoSuite, wireId: Int) {
        if (suite != P2PCryptoSuite.X_WING && suite != P2PCryptoSuite.MLKEM_768) {
            invalid("KEM suite is not eligible for Android SKR-1 wireId=$wireId")
        }
    }

    private fun requiredToken(raw: String, label: String): String {
        val value = SkrCanonical.normalizedToken(raw)
        if (value.isEmpty() || value.length > MAX_TOKEN_LENGTH || value != raw.trim()) {
            invalid("$label is invalid")
        }
        return value
    }

    private fun validateFiniteTimestamp(value: Double, label: String) {
        if (!value.isFinite()) invalid("$label is not finite")
    }

    private fun canonicalMillis(value: Double, label: String): Long = try {
        SkrCanonical.canonicalMillis(value)
    } catch (_: IllegalArgumentException) {
        invalid("$label is outside the supported range")
    }

    private fun saturatingAdd(value: Long, positiveDelta: Long): Long =
        if (value > Long.MAX_VALUE - positiveDelta) Long.MAX_VALUE else value + positiveDelta

    private fun saturatingSubtract(value: Long, positiveDelta: Long): Long =
        if (value < Long.MIN_VALUE + positiveDelta) Long.MIN_VALUE else value - positiveDelta

    private fun invalid(message: String): Nothing =
        throw SignedLanKemRefreshValidationException("SKR-1 $message")

    private companion object {
        val REQUIRED_SKR_SUITE_WIRE_IDS = setOf(
            P2PCryptoSuite.X_WING.wireId.toInt(),
            P2PCryptoSuite.MLKEM_768.wireId.toInt()
        )
        const val MIN_NONCE_BYTES = 16
        const val MAX_NONCE_BYTES = 128
        const val MAX_ALIAS_COUNT = 32
        const val MAX_TOKEN_LENGTH = 256
        const val MAX_SIGNATURE_BYTES = 8_192
    }
}
