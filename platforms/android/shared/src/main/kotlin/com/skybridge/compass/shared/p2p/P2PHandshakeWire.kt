package com.skybridge.compass.shared.p2p

import android.util.Log
import com.skybridge.compass.shared.crypto.KeyUsage
import com.skybridge.compass.shared.crypto.Ed25519SoftwareVerifier
import com.skybridge.compass.shared.crypto.providers.AndroidPQCCryptoProvider
import kotlinx.coroutines.runBlocking
import org.bouncycastle.jce.provider.BouncyCastleProvider
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.PrivateKey
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.Security
import java.security.Signature
import java.security.KeyFactory
import java.security.spec.PKCS8EncodedKeySpec
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Android implementation of Pro release P2P v1 handshake wire pieces:
 * - MessageA / MessageB encoder/decoder (minimal interop subset)
 * - KDF (SkyBridge-KDF-Salt-v1| + suiteWireId + transcriptA + transcriptB + nonces)
 * - Finished MAC (FIN1)
 *
 * NOTE: For cross-platform interop we fully support Ed25519 signatures (classic suites).
 * ML-DSA-65 Secure Enclave PoP is not implemented here.
 */
object P2PHandshakeWire {
    private const val TAG = "SB-HANDSHAKE-WIRE"
    const val PROVIDER_TYPE_QPERIAPT = "Q-Periapt-ContextBound"
    const val PROVIDER_TYPE_CRYPTO_KIT_PQC = "CryptoKit-PQC"
    const val PROVIDER_TYPE_LIBOQS = "liboqs"
    const val PROVIDER_TYPE_CRYPTO_KIT_CLASSIC = "CryptoKit-Classic"

    private const val PROTOCOL_VERSION: Byte = 0x01
    private const val MAX_HANDSHAKE_MESSAGE_BYTES: Int = 16 * 1_024
    private const val MAX_SUPPORTED_SUITES: Int = 8
    private const val MAX_KEY_SHARES: Int = 2
    private val DOMAIN_A = "SkyBridge-A".toByteArray(Charsets.UTF_8)
    private val DOMAIN_B = "SkyBridge-B".toByteArray(Charsets.UTF_8)
    private const val CLASSIC_FALLBACK_COOLDOWN_MILLIS: Long = 300_000L
    private val secureRandom = SecureRandom()
    private val pqcProvider: AndroidPQCCryptoProvider? by lazy {
        if (!AndroidPQCCryptoProvider.isAvailable()) {
            null
        } else {
            runCatching { AndroidPQCCryptoProvider() }.getOrNull()
        }
    }

    data class KeyShare(val suiteId: P2PCryptoSuiteId, val shareBytes: ByteArray) {
        constructor(suite: P2PCryptoSuite, shareBytes: ByteArray) : this(P2PCryptoSuiteId.Known(suite), shareBytes)

        val knownSuite: P2PCryptoSuite?
            get() = suiteId.knownOrNull()
    }

    /**
     * capabilities(var) and policy(var) are Pro-release "TranscriptVersion" encoded blobs.
     * For initial interoperability on LAN, we treat them as opaque byte arrays.
     */
    data class MessageA(
        val supportedSuites: List<P2PCryptoSuiteId>,
        val keyShares: List<KeyShare>,
        val clientNonce: ByteArray,
        val capabilities: P2PCryptoCapabilities,
        val policy: P2PHandshakePolicy,
        val identityPublicKeys: P2PIdentityPublicKeys.Keys,
        val initiatorContribution: ByteArray? = null,
        val extensionsRaw: ByteArray = ByteArray(0),
        val signature: ByteArray,
        val secureEnclaveSignature: ByteArray? = null
    ) {
        val unknownSupportedSuiteWireIds: List<UShort>
            get() = supportedSuites.mapNotNull { (it as? P2PCryptoSuiteId.Unknown)?.wireId }

        val unknownKeyShareSuiteWireIds: List<UShort>
            get() = keyShares.mapNotNull { (it.suiteId as? P2PCryptoSuiteId.Unknown)?.wireId }
    }

    /**
     * Minimal MessageB fields needed for KDF:
     * - selectedSuite
     * - responderShare (classic only)
     * - serverNonce
     * - encryptedPayload (opaque bytes; in Pro it's HPKESealedBox combined for handshake)
     * - identityPublicKey, signature, seSig
     */
    data class MessageB(
        val selectedSuite: P2PCryptoSuiteId,
        val responderShare: ByteArray,
        val serverNonce: ByteArray,
        val encryptedPayload: P2PHPKESealedBox,
        val identityPublicKeys: P2PIdentityPublicKeys.Keys,
        val signature: ByteArray,
        val secureEnclaveSignature: ByteArray? = null
    )

    data class DerivedSessionKeys(
        val sendKey: ByteArray,
        val receiveKey: ByteArray,
        val transcriptHash: ByteArray
    )

    fun compatibleProviderTypeRawForTier(minimumTierRaw: String): String = when (minimumTierRaw.trim()) {
        P2PQPeriaptKem.MINIMUM_TIER_RAW -> PROVIDER_TYPE_QPERIAPT
        "nativePQC" -> PROVIDER_TYPE_CRYPTO_KIT_PQC
        "liboqsPQC" -> PROVIDER_TYPE_LIBOQS
        "classic" -> PROVIDER_TYPE_CRYPTO_KIT_CLASSIC
        else -> throw IllegalArgumentException("Unsupported handshake minimum tier: $minimumTierRaw")
    }

    // Shared trust contract used by handshake call-sites and artifacts.
    const val PEER_SIGNING_FINGERPRINT_FIELD: String = "peer_signing_fingerprint"

    interface TrustStore {
        fun loadPeerSigningFingerprint(peerId: String): String?
        fun savePeerSigningFingerprint(peerId: String, peerSigningFingerprint: String)
    }

    class InMemoryTrustStore : TrustStore {
        private val peerSigningFingerprints = LinkedHashMap<String, String>()

        override fun loadPeerSigningFingerprint(peerId: String): String? =
            peerSigningFingerprints[peerId]

        override fun savePeerSigningFingerprint(peerId: String, peerSigningFingerprint: String) {
            peerSigningFingerprints[peerId] = peerSigningFingerprint
        }
    }

    data class FallbackCooldownDecision(
        val allowed: Boolean,
        val remainingMillis: Long
    )

    interface FallbackCooldownStore {
        fun loadLastClassicFallbackAtMillis(peerId: String): Long?
        fun saveLastClassicFallbackAtMillis(peerId: String, unixTimeMillis: Long)
    }

    class InMemoryFallbackCooldownStore : FallbackCooldownStore {
        private val lastFallbackByPeer = LinkedHashMap<String, Long>()

        override fun loadLastClassicFallbackAtMillis(peerId: String): Long? {
            return lastFallbackByPeer[peerId]
        }

        override fun saveLastClassicFallbackAtMillis(peerId: String, unixTimeMillis: Long) {
            lastFallbackByPeer[peerId] = unixTimeMillis
        }
    }

    fun evaluateClassicFallbackCooldown(
        peerId: String,
        fallbackCooldownStore: FallbackCooldownStore,
        nowUnixTimeMillis: Long = System.currentTimeMillis(),
        cooldownMillis: Long = CLASSIC_FALLBACK_COOLDOWN_MILLIS
    ): FallbackCooldownDecision {
        require(peerId.isNotBlank()) { "peerId is required for fallback cooldown evaluation" }
        val lastFallbackAt = fallbackCooldownStore.loadLastClassicFallbackAtMillis(peerId)
            ?: return FallbackCooldownDecision(allowed = true, remainingMillis = 0)
        val elapsed = (nowUnixTimeMillis - lastFallbackAt).coerceAtLeast(0L)
        if (elapsed >= cooldownMillis) {
            return FallbackCooldownDecision(allowed = true, remainingMillis = 0)
        }
        return FallbackCooldownDecision(
            allowed = false,
            remainingMillis = cooldownMillis - elapsed
        )
    }

    fun recordClassicFallback(
        peerId: String,
        fallbackCooldownStore: FallbackCooldownStore,
        nowUnixTimeMillis: Long = System.currentTimeMillis()
    ) {
        require(peerId.isNotBlank()) { "peerId is required for fallback cooldown persistence" }
        fallbackCooldownStore.saveLastClassicFallbackAtMillis(peerId, nowUnixTimeMillis)
    }

    enum class TrustDecision {
        UNTRUSTED_EPHEMERAL,
        TRUSTED_NEW,
        TRUSTED_EXISTING
    }

    enum class FinishedDirection(val wire: Byte) {
        RESPONDER_TO_INITIATOR(0x01),
        INITIATOR_TO_RESPONDER(0x02);

        companion object {
            fun fromWire(b: Byte): FinishedDirection? = entries.firstOrNull { it.wire == b }
        }
    }

    data class Finished(
        val version: Byte,
        val direction: FinishedDirection,
        val mac: ByteArray
    )

    fun decodeMessageA(wire: ByteArray): MessageA {
        val data = HandshakePaddingP1.unwrapIfNeeded(wire)
        require(data.size >= 1 + 2 + 2 + 32) { "MessageA too short" }
        require(data.size <= MAX_HANDSHAKE_MESSAGE_BYTES) { "MessageA exceeds maximum length" }
        val bb = ByteBuffer.wrap(data).order(ByteOrder.LITTLE_ENDIAN)
        val version = bb.get()
        require(version == PROTOCOL_VERSION) { "Version mismatch: $version" }

        val suitesCount = bb.short.toInt() and 0xFFFF
        require(suitesCount in 1..8) { "Invalid supportedSuites count" }
        val suites = ArrayList<P2PCryptoSuiteId>(suitesCount)
        repeat(suitesCount) {
            val wireId = bb.short.toUShort()
            suites += P2PCryptoSuiteId.parse(wireId)
        }

        val ksCount = bb.short.toInt() and 0xFFFF
        require(ksCount in 0..2 && ksCount <= suitesCount) { "Invalid keyShares count" }
        val keyShares = ArrayList<KeyShare>(ksCount)
        repeat(ksCount) {
            val suiteId = bb.short.toUShort()
            val shareLen = bb.short.toInt() and 0xFFFF
            require(shareLen >= 0 && bb.remaining() >= shareLen) { "KeyShare truncated" }
            val share = ByteArray(shareLen)
            bb.get(share)
            val parsedSuiteId = P2PCryptoSuiteId.parse(suiteId)
            keyShares += KeyShare(parsedSuiteId, share)
        }
        validateMessageAOfferShape(suites, keyShares)

        val clientNonce = ByteArray(32)
        bb.get(clientNonce)

        val capLen = bb.short.toInt() and 0xFFFF
        require(bb.remaining() >= capLen) { "Capabilities truncated" }
        val capabilities = ByteArray(capLen)
        bb.get(capabilities)

        val policyLen = bb.short.toInt() and 0xFFFF
        require(bb.remaining() >= policyLen) { "Policy truncated" }
        val policy = ByteArray(policyLen)
        bb.get(policy)

        val idKeyLen = bb.short.toInt() and 0xFFFF
        require(bb.remaining() >= idKeyLen) { "Identity key truncated" }
        val identityKey = ByteArray(idKeyLen)
        bb.get(identityKey)

        val needsV2Contribution = suites.any { it.knownOrNull() == P2PCryptoSuite.MLKEM_768_FS_COMPAT }
        val initiatorContribution = if (needsV2Contribution) {
            val contribLen = bb.short.toInt() and 0xFFFF
            require(bb.remaining() >= contribLen) { "v2 initiator contribution truncated" }
            require(contribLen == 0 || contribLen == 32) { "v2 initiator contribution length mismatch: $contribLen" }
            if (contribLen > 0) {
                ByteArray(contribLen).also { bb.get(it) }
            } else {
                null
            }
        } else {
            null
        }

        var extensionsRaw = ByteArray(0)
        if (bb.remaining() >= P2PSoa.CONTAINER_MAGIC.size + 2) {
            bb.mark()
            val magic = ByteArray(P2PSoa.CONTAINER_MAGIC.size)
            bb.get(magic)
            if (magic.contentEquals(P2PSoa.CONTAINER_MAGIC)) {
                val extLen = bb.short.toInt() and 0xFFFF
                require(bb.remaining() >= extLen) { "Extensions truncated" }
                extensionsRaw = ByteArray(extLen).also { bb.get(it) }
            } else {
                bb.reset()
            }
        }

        val sigLen = bb.short.toInt() and 0xFFFF
        require(bb.remaining() >= sigLen) { "Signature truncated" }
        val sig = ByteArray(sigLen)
        bb.get(sig)

        val seSigLen = bb.short.toInt() and 0xFFFF
        val seSig = if (seSigLen > 0) {
            require(bb.remaining() >= seSigLen) { "SE signature truncated" }
            ByteArray(seSigLen).also { bb.get(it) }
        } else null
        require(!bb.hasRemaining()) { "MessageA contains trailing bytes" }

        return MessageA(
            supportedSuites = suites,
            keyShares = keyShares,
            clientNonce = clientNonce,
            capabilities = P2PCryptoCapabilities.deterministicDecode(capabilities),
            policy = P2PHandshakePolicy.deterministicDecode(policy),
            identityPublicKeys = P2PIdentityPublicKeys.decode(identityKey),
            initiatorContribution = initiatorContribution,
            extensionsRaw = extensionsRaw,
            signature = sig,
            secureEnclaveSignature = seSig
        )
    }

    fun encodeMessageA(
        supportedSuites: List<P2PCryptoSuite>,
        keyShares: List<KeyShare>,
        clientNonce32: ByteArray,
        capabilities: P2PCryptoCapabilities,
        policy: P2PHandshakePolicy,
        identityKeys: P2PIdentityPublicKeys.Keys,
        identitySigningPrivateKey: PrivateKey,
        initiatorContribution: ByteArray? = null,
        extensionsRaw: ByteArray = ByteArray(0)
    ): ByteArray {
        return encodeMessageAInternal(
            supportedSuites = supportedSuites,
            keyShares = keyShares,
            clientNonce32 = clientNonce32,
            capabilities = capabilities,
            policy = policy,
            identityKeys = identityKeys,
            initiatorContribution = initiatorContribution,
            extensionsRaw = extensionsRaw
        ) { signingPreimage ->
            signByAlgorithm(
                data = signingPreimage,
                algorithm = identityKeys.protocolAlgorithm,
                ed25519PrivateKey = identitySigningPrivateKey,
                mlDsaPrivateKey = null
            )
        }
    }

    /**
     * Canonically encodes an already-signed MessageA value.
     *
     * This is the same unpadded production wire representation emitted by the signing overloads.
     * Padding remains a transport concern. Suite and key-share order are protocol data and are
     * therefore preserved exactly.
     */
    fun encodeMessageA(message: MessageA): ByteArray {
        val withoutSignature = buildMessageAWithoutSignatureGeneric(
            supportedSuites = message.supportedSuites,
            keyShares = message.keyShares,
            clientNonce32 = message.clientNonce,
            capabilitiesBytes = message.capabilities.deterministicEncode(),
            policyBytes = message.policy.deterministicEncode(),
            identityPublicKeyBytes = message.identityPublicKeys.encode(),
            initiatorContribution = message.initiatorContribution,
            extensionsRaw = message.extensionsRaw
        )
        return appendMessageSignatures(
            withoutSignature = withoutSignature,
            signature = message.signature,
            secureEnclaveSignature = message.secureEnclaveSignature
        )
    }

    fun encodeMessageAWithRawSigningKey(
        supportedSuites: List<P2PCryptoSuite>,
        keyShares: List<KeyShare>,
        clientNonce32: ByteArray,
        capabilities: P2PCryptoCapabilities,
        policy: P2PHandshakePolicy,
        identityKeys: P2PIdentityPublicKeys.Keys,
        identitySigningPrivateKeyRaw: ByteArray,
        initiatorContribution: ByteArray? = null,
        extensionsRaw: ByteArray = ByteArray(0)
    ): ByteArray {
        return encodeMessageAInternal(
            supportedSuites = supportedSuites,
            keyShares = keyShares,
            clientNonce32 = clientNonce32,
            capabilities = capabilities,
            policy = policy,
            identityKeys = identityKeys,
            initiatorContribution = initiatorContribution,
            extensionsRaw = extensionsRaw
        ) { signingPreimage ->
            signByAlgorithm(
                data = signingPreimage,
                algorithm = identityKeys.protocolAlgorithm,
                ed25519PrivateKey = null,
                mlDsaPrivateKey = identitySigningPrivateKeyRaw
            )
        }
    }

    private fun encodeMessageAInternal(
        supportedSuites: List<P2PCryptoSuite>,
        keyShares: List<KeyShare>,
        clientNonce32: ByteArray,
        capabilities: P2PCryptoCapabilities,
        policy: P2PHandshakePolicy,
        identityKeys: P2PIdentityPublicKeys.Keys,
        initiatorContribution: ByteArray?,
        extensionsRaw: ByteArray,
        signer: (ByteArray) -> ByteArray
    ): ByteArray {
        require(clientNonce32.size == 32) { "clientNonce must be 32 bytes" }

        val identityBytes = identityKeys.encode()
        val capBytes = capabilities.deterministicEncode()
        val policyBytes = policy.deterministicEncode()

        val withoutSig = buildMessageAWithoutSignature(
            supportedSuites = supportedSuites,
            keyShares = keyShares,
            clientNonce32 = clientNonce32,
            capabilitiesBytes = capBytes,
            policyBytes = policyBytes,
            identityPublicKeyBytes = identityBytes,
            initiatorContribution = initiatorContribution,
            extensionsRaw = extensionsRaw
        )
        val sig = signer(concat(DOMAIN_A, withoutSig))

        return appendMessageSignatures(
            withoutSignature = withoutSig,
            signature = sig,
            secureEnclaveSignature = null
        )
    }

    private fun buildMessageAWithoutSignature(
        supportedSuites: List<P2PCryptoSuite>,
        keyShares: List<KeyShare>,
        clientNonce32: ByteArray,
        capabilitiesBytes: ByteArray,
        policyBytes: ByteArray,
        identityPublicKeyBytes: ByteArray,
        initiatorContribution: ByteArray?,
        extensionsRaw: ByteArray
    ): ByteArray = buildMessageAWithoutSignatureGeneric(
        supportedSuites = supportedSuites.map { P2PCryptoSuiteId.Known(it) },
        keyShares = keyShares,
        clientNonce32 = clientNonce32,
        capabilitiesBytes = capabilitiesBytes,
        policyBytes = policyBytes,
        identityPublicKeyBytes = identityPublicKeyBytes,
        initiatorContribution = initiatorContribution,
        extensionsRaw = extensionsRaw
    )

    private fun buildMessageAWithoutSignatureGeneric(
        supportedSuites: List<P2PCryptoSuiteId>,
        keyShares: List<KeyShare>,
        clientNonce32: ByteArray,
        capabilitiesBytes: ByteArray,
        policyBytes: ByteArray,
        identityPublicKeyBytes: ByteArray,
        initiatorContribution: ByteArray?,
        extensionsRaw: ByteArray
    ): ByteArray {
        validateMessageAOfferShape(supportedSuites, keyShares)
        require(clientNonce32.size == 32) { "clientNonce must be 32 bytes" }
        requireUInt16Length(capabilitiesBytes, "capabilities")
        requireUInt16Length(policyBytes, "policy")
        requireUInt16Length(identityPublicKeyBytes, "identityPublicKey")
        keyShares.forEachIndexed { index, keyShare ->
            requireUInt16Length(keyShare.shareBytes, "keyShares[$index]")
        }
        val needsV2Contribution = supportedSuites.any { it.knownOrNull() == P2PCryptoSuite.MLKEM_768_FS_COMPAT }
        val contributionBytes = when {
            !needsV2Contribution -> ByteArray(0)
            initiatorContribution == null -> ByteArray(0)
            else -> {
                require(initiatorContribution.size == 32) { "v2 initiator contribution must be 32 bytes" }
                initiatorContribution
            }
        }
        requireUInt16Length(extensionsRaw, "extensionsRaw")
        val suitesBytes = ByteBuffer.allocate(2 + supportedSuites.size * 2).order(ByteOrder.LITTLE_ENDIAN).apply {
            putShort(supportedSuites.size.toShort())
            for (suiteId in supportedSuites) putShort(suiteId.wireId.toShort())
        }.array()
        val ksLen = keyShares.sumOf { 2 + 2 + it.shareBytes.size }
        val ksBytes = ByteBuffer.allocate(2 + ksLen).order(ByteOrder.LITTLE_ENDIAN).apply {
            putShort(keyShares.size.toShort())
            for (ks in keyShares) {
                putShort(ks.suiteId.wireId.toShort())
                putShort(ks.shareBytes.size.toShort())
                put(ks.shareBytes)
            }
        }.array()

        val extensionsLen = if (extensionsRaw.isEmpty()) 0 else P2PSoa.CONTAINER_MAGIC.size + 2 + extensionsRaw.size
        val encodedSize =
            1 + suitesBytes.size + ksBytes.size + 32 +
                2 + capabilitiesBytes.size +
                2 + policyBytes.size +
                2 + identityPublicKeyBytes.size +
                (if (needsV2Contribution) 2 + contributionBytes.size else 0) +
                extensionsLen
        require(encodedSize <= MAX_HANDSHAKE_MESSAGE_BYTES) {
            "MessageA without signature exceeds maximum length: $encodedSize"
        }
        val out = ByteBuffer.allocate(encodedSize).order(ByteOrder.LITTLE_ENDIAN)

        out.put(PROTOCOL_VERSION)
        out.put(suitesBytes)
        out.put(ksBytes)
        out.put(clientNonce32)
        out.putShort(capabilitiesBytes.size.toShort())
        out.put(capabilitiesBytes)
        out.putShort(policyBytes.size.toShort())
        out.put(policyBytes)
        out.putShort(identityPublicKeyBytes.size.toShort())
        out.put(identityPublicKeyBytes)
        if (needsV2Contribution) {
            out.putShort(contributionBytes.size.toShort())
            out.put(contributionBytes)
        }
        if (extensionsRaw.isNotEmpty()) {
            out.put(P2PSoa.CONTAINER_MAGIC)
            out.putShort(extensionsRaw.size.toShort())
            out.put(extensionsRaw)
        }
        return out.array()
    }

    private fun appendMessageSignatures(
        withoutSignature: ByteArray,
        signature: ByteArray,
        secureEnclaveSignature: ByteArray?
    ): ByteArray {
        requireUInt16Length(signature, "signature")
        val secureEnclaveBytes = secureEnclaveSignature ?: ByteArray(0)
        requireUInt16Length(secureEnclaveBytes, "secureEnclaveSignature")
        val encodedSize = withoutSignature.size.toLong() + 2L + signature.size + 2L + secureEnclaveBytes.size
        require(encodedSize <= MAX_HANDSHAKE_MESSAGE_BYTES.toLong()) {
            "Handshake message exceeds maximum length: $encodedSize"
        }
        return ByteBuffer.allocate(encodedSize.toInt()).order(ByteOrder.LITTLE_ENDIAN).apply {
            put(withoutSignature)
            putShort(signature.size.toShort())
            put(signature)
            putShort(secureEnclaveBytes.size.toShort())
            put(secureEnclaveBytes)
        }.array()
    }

    private fun requireUInt16Length(bytes: ByteArray, fieldName: String) {
        require(bytes.size <= 0xFFFF) { "$fieldName too large: ${bytes.size}" }
    }

    private fun validateMessageAOfferShape(
        supportedSuites: List<P2PCryptoSuiteId>,
        keyShares: List<KeyShare>
    ) {
        require(supportedSuites.size in 1..MAX_SUPPORTED_SUITES) {
            "supportedSuites count out of range: ${supportedSuites.size}"
        }
        require(keyShares.size in 0..MAX_KEY_SHARES && keyShares.size <= supportedSuites.size) {
            "keyShares count out of range: ${keyShares.size}"
        }

        val supportedWireIds = supportedSuites.map(P2PCryptoSuiteId::wireId)
        require(supportedWireIds.distinct().size == supportedWireIds.size) {
            "Duplicate supported suite"
        }

        val seenKeyShareWireIds = HashSet<UShort>(keyShares.size)
        var lastSupportedIndex = -1
        keyShares.forEach { keyShare ->
            require(seenKeyShareWireIds.add(keyShare.suiteId.wireId)) {
                "Duplicate keyShare suite"
            }
            val supportedIndex = supportedWireIds.indexOf(keyShare.suiteId.wireId)
            require(supportedIndex >= 0) { "keyShare suite not in supportedSuites" }
            require(supportedIndex > lastSupportedIndex) { "keyShares out of order" }
            lastSupportedIndex = supportedIndex
            keyShare.knownSuite?.let { validateKeyShareLength(keyShare.shareBytes.size, it) }
        }
    }

    private fun validateResponderShareLength(length: Int, suite: P2PCryptoSuiteId) {
        val knownSuite = suite.knownOrNull() ?: return
        val expectedLength = when (knownSuite) {
            P2PCryptoSuite.Q_PERIAPT_CONTEXT_BOUND,
            P2PCryptoSuite.X_WING,
            P2PCryptoSuite.MLKEM_768 -> 0
            P2PCryptoSuite.MLKEM_768_FS_COMPAT,
            P2PCryptoSuite.X25519 -> 32
            P2PCryptoSuite.P256 -> 65
        }
        require(length == expectedLength) {
            "ResponderShare length mismatch for ${knownSuite.name}: $length != $expectedLength"
        }
    }

    private fun canonicalMessageAWithoutSignature(messageA: MessageA): ByteArray =
        buildMessageAWithoutSignatureGeneric(
            supportedSuites = messageA.supportedSuites,
            keyShares = messageA.keyShares,
            clientNonce32 = messageA.clientNonce,
            capabilitiesBytes = messageA.capabilities.deterministicEncode(),
            policyBytes = messageA.policy.deterministicEncode(),
            identityPublicKeyBytes = messageA.identityPublicKeys.encode(),
            initiatorContribution = messageA.initiatorContribution,
            extensionsRaw = messageA.extensionsRaw
        )

    fun decodeMessageB(wire: ByteArray): MessageB {
        val data = HandshakePaddingP1.unwrapIfNeeded(wire)
        require(data.size >= 1 + 2 + 2 + 32 + 2) { "MessageB too short" }
        require(data.size <= MAX_HANDSHAKE_MESSAGE_BYTES) { "MessageB exceeds maximum length" }
        val bb = ByteBuffer.wrap(data).order(ByteOrder.LITTLE_ENDIAN)
        val version = bb.get()
        require(version == PROTOCOL_VERSION) { "Version mismatch: $version" }

        val suiteWireId = bb.short.toUShort()
        val suite = P2PCryptoSuiteId.parse(suiteWireId)

        val shareLen = bb.short.toInt() and 0xFFFF
        require(shareLen >= 0 && bb.remaining() >= shareLen) { "Responder share truncated" }
        val responderShare = ByteArray(shareLen)
        bb.get(responderShare)
        validateResponderShareLength(responderShare.size, suite)

        val serverNonce = ByteArray(32)
        bb.get(serverNonce)

        val payloadLen = bb.short.toInt() and 0xFFFF
        require(bb.remaining() >= payloadLen) { "Payload truncated" }
        val payload = ByteArray(payloadLen)
        bb.get(payload)
        val encryptedPayload = P2PHPKESealedBox.parse(payload, isHandshake = true)
        require(encryptedPayload.suiteWireId == suite.wireId) {
            "MessageB encrypted payload suite does not match selected suite"
        }
        require(encryptedPayload.combinedWithHeaderForHandshake().contentEquals(payload)) {
            "MessageB encrypted payload is not canonically encoded for selected suite"
        }

        val idKeyLen = bb.short.toInt() and 0xFFFF
        require(bb.remaining() >= idKeyLen) { "Identity key truncated" }
        val idKey = ByteArray(idKeyLen)
        bb.get(idKey)

        val sigLen = bb.short.toInt() and 0xFFFF
        require(bb.remaining() >= sigLen) { "Signature truncated" }
        val sig = ByteArray(sigLen)
        bb.get(sig)

        val seSigLen = bb.short.toInt() and 0xFFFF
        val seSig = if (seSigLen > 0) {
            require(bb.remaining() >= seSigLen) { "SE signature truncated" }
            ByteArray(seSigLen).also { bb.get(it) }
        } else null
        require(!bb.hasRemaining()) { "MessageB contains trailing bytes" }

        return MessageB(
            selectedSuite = suite,
            responderShare = responderShare,
            serverNonce = serverNonce,
            encryptedPayload = encryptedPayload,
            identityPublicKeys = P2PIdentityPublicKeys.decode(idKey),
            signature = sig,
            secureEnclaveSignature = seSig
        )
    }

    /**
     * Canonically encodes an already-signed MessageB value without transport padding.
     */
    fun encodeMessageB(message: MessageB): ByteArray {
        require(message.serverNonce.size == 32) { "serverNonce must be 32 bytes" }
        requireUInt16Length(message.responderShare, "responderShare")
        validateResponderShareLength(message.responderShare.size, message.selectedSuite)
        val payloadBytes = message.encryptedPayload.combinedWithHeaderForHandshake()
        require(message.encryptedPayload.suiteWireId == message.selectedSuite.wireId) {
            "MessageB payload suite does not match selected suite"
        }
        requireUInt16Length(payloadBytes, "encryptedPayload")
        // Re-parse the produced handshake payload before it can enter the signed wire. This keeps
        // version and per-field length constraints aligned with the production decoder.
        P2PHPKESealedBox.parse(payloadBytes, isHandshake = true)
        val identityBytes = message.identityPublicKeys.encode()
        requireUInt16Length(identityBytes, "identityPublicKey")

        val unsignedSize = 1L + 2L + 2L + message.responderShare.size + 32L +
            2L + payloadBytes.size + 2L + identityBytes.size
        require(unsignedSize <= MAX_HANDSHAKE_MESSAGE_BYTES.toLong()) {
            "MessageB without signature exceeds maximum length: $unsignedSize"
        }
        val withoutSignature = ByteBuffer.allocate(unsignedSize.toInt()).order(ByteOrder.LITTLE_ENDIAN).apply {
            put(PROTOCOL_VERSION)
            putShort(message.selectedSuite.wireId.toShort())
            putShort(message.responderShare.size.toShort())
            put(message.responderShare)
            put(message.serverNonce)
            putShort(payloadBytes.size.toShort())
            put(payloadBytes)
            putShort(identityBytes.size.toShort())
            put(identityBytes)
        }.array()
        return appendMessageSignatures(
            withoutSignature = withoutSignature,
            signature = message.signature,
            secureEnclaveSignature = message.secureEnclaveSignature
        )
    }

    /**
     * Pro release transcriptHashA/B are SHA-256 of transcriptBytes, i.e. encodedWithoutSignature().
     */
    fun transcriptHashAFromWire(rawMessageA: ByteArray): ByteArray =
        sha256(extractMessageAWithoutSignature(rawMessageA))

    fun transcriptHashBFromWire(rawMessageB: ByteArray): ByteArray =
        sha256(extractMessageBWithoutSignature(rawMessageB))

    /** Return MessageB transcript bytes (everything up to, but not including, signatureLen). */
    fun messageBWithoutSignatureFromWire(rawMessageBWithoutPadding: ByteArray): ByteArray =
        extractMessageBWithoutSignature(rawMessageBWithoutPadding)

    /**
     * Return MessageA transcript bytes (everything up to, but not including, signatureLen).
     *
     * This includes any optional extensions container when present.
     */
    fun messageAWithoutSignatureFromWire(rawMessageAWithoutPadding: ByteArray): ByteArray =
        extractMessageAWithoutSignature(rawMessageAWithoutPadding)

    /**
     * Public helper for auditing and tests.
     *
     * `sigA_preimage = DOMAIN_A || messageAWithoutSignature`
     */
    fun buildMessageASignaturePreimagePublic(rawMessageAWithoutPadding: ByteArray): ByteArray =
        concat(DOMAIN_A, messageAWithoutSignatureFromWire(rawMessageAWithoutPadding))

    fun verifyMessageASignature(messageA: MessageA, rawMessageAWithoutPadding: ByteArray): Boolean {
        val rawPreimage = buildMessageASignaturePreimagePublic(rawMessageAWithoutPadding)
        val rawOutcome = verifyByAlgorithmDetailed(
            data = rawPreimage,
            signature = messageA.signature,
            publicKey = messageA.identityPublicKeys.protocolPublicKey,
            algorithm = messageA.identityPublicKeys.protocolAlgorithm
        )
        if (rawOutcome.verified) {
            return true
        }

        val canonicalPreimage = runCatching {
            concat(DOMAIN_A, canonicalMessageAWithoutSignature(messageA))
        }.getOrNull()

        if (canonicalPreimage != null && !rawPreimage.contentEquals(canonicalPreimage)) {
            val canonicalOutcome = verifyByAlgorithmDetailed(
                data = canonicalPreimage,
                signature = messageA.signature,
                publicKey = messageA.identityPublicKeys.protocolPublicKey,
                algorithm = messageA.identityPublicKeys.protocolAlgorithm
            )
            if (canonicalOutcome.verified) {
                emitInteropLog(
                    level = Log.WARN,
                    message = buildString {
                        append("MessageA signature verified via canonical fallback")
                        append(" alg=${messageA.identityPublicKeys.protocolAlgorithm.name}")
                        append(" suites=${messageA.supportedSuites.joinToString(",") { it.wireId.toString(16) }}")
                        append(" rawHash=${sha256Hex(rawPreimage).take(16)}")
                        append(" canonicalHash=${sha256Hex(canonicalPreimage).take(16)}")
                        append(" sigBytes=${messageA.signature.size}")
                        append(" pubBytes=${messageA.identityPublicKeys.protocolPublicKey.size}")
                        rawOutcome.failure?.let { append(" rawFailure=$it") }
                    }
                )
                return true
            }

            emitInteropLog(
                level = Log.WARN,
                message = buildString {
                    append("MessageA signature invalid")
                    append(" alg=${messageA.identityPublicKeys.protocolAlgorithm.name}")
                    append(" suites=${messageA.supportedSuites.joinToString(",") { it.wireId.toString(16) }}")
                    append(" rawHash=${sha256Hex(rawPreimage).take(16)}")
                    append(" canonicalHash=${sha256Hex(canonicalPreimage).take(16)}")
                    append(" sigBytes=${messageA.signature.size}")
                    append(" pubBytes=${messageA.identityPublicKeys.protocolPublicKey.size}")
                    rawOutcome.failure?.let { append(" rawFailure=$it") }
                    canonicalOutcome.failure?.let { append(" canonicalFailure=$it") }
                }
            )
            return false
        }

        emitInteropLog(
            level = Log.WARN,
            message = buildString {
                append("MessageA signature invalid")
                append(" alg=${messageA.identityPublicKeys.protocolAlgorithm.name}")
                append(" suites=${messageA.supportedSuites.joinToString(",") { it.wireId.toString(16) }}")
                append(" rawHash=${sha256Hex(rawPreimage).take(16)}")
                append(" sigBytes=${messageA.signature.size}")
                append(" pubBytes=${messageA.identityPublicKeys.protocolPublicKey.size}")
                rawOutcome.failure?.let { append(" rawFailure=$it") }
            }
        )
        return false
    }

    fun verifyMessageBSignature(
        messageB: MessageB,
        transcriptHashA32: ByteArray,
        @Suppress("UNUSED_PARAMETER") rawMessageBWithoutPadding: ByteArray
    ): Boolean {
        val preimage = buildMessageBSignaturePreimage(
            transcriptHashA32 = transcriptHashA32,
            selectedSuiteWireId = messageB.selectedSuite.wireId,
            responderShare = messageB.responderShare,
            serverNonce = messageB.serverNonce,
            payloadCombinedWithHeader = messageB.encryptedPayload.combinedWithHeader(),
            identityPublicKeyBytes = messageB.identityPublicKeys.encode()
        )
        return verifyByAlgorithm(
            data = preimage,
            signature = messageB.signature,
            publicKey = messageB.identityPublicKeys.protocolPublicKey,
            algorithm = messageB.identityPublicKeys.protocolAlgorithm
        )
    }

    private fun buildMessageBSignaturePreimage(
        transcriptHashA32: ByteArray,
        selectedSuiteWireId: UShort,
        responderShare: ByteArray,
        serverNonce: ByteArray,
        payloadCombinedWithHeader: ByteArray,
        identityPublicKeyBytes: ByteArray
    ): ByteArray {
        require(transcriptHashA32.size == 32) { "transcriptHashA must be 32 bytes" }
        val payloadHash = sha256(payloadCombinedWithHeader)

        val bb = ByteBuffer.allocate(
            DOMAIN_B.size + 32 + 2 + 2 + responderShare.size + 32 + 32 + 2 + identityPublicKeyBytes.size
        ).order(ByteOrder.LITTLE_ENDIAN)
        bb.put(DOMAIN_B)
        bb.put(transcriptHashA32)
        bb.putShort(selectedSuiteWireId.toShort())
        bb.putShort(responderShare.size.toShort())
        bb.put(responderShare)
        bb.put(serverNonce)
        bb.put(payloadHash)
        bb.putShort(identityPublicKeyBytes.size.toShort())
        bb.put(identityPublicKeyBytes)
        return bb.array()
    }

    fun buildMessageBSignaturePreimagePublic(
        transcriptHashA32: ByteArray,
        selectedSuiteWireId: UShort,
        responderShare: ByteArray,
        serverNonce: ByteArray,
        payloadCombinedWithHeader: ByteArray,
        identityPublicKeyBytes: ByteArray
    ): ByteArray = buildMessageBSignaturePreimage(
        transcriptHashA32 = transcriptHashA32,
        selectedSuiteWireId = selectedSuiteWireId,
        responderShare = responderShare,
        serverNonce = serverNonce,
        payloadCombinedWithHeader = payloadCombinedWithHeader,
        identityPublicKeyBytes = identityPublicKeyBytes
    )

    private fun extractMessageAWithoutSignature(rawWithoutPadding: ByteArray): ByteArray {
        // Everything up to (but not including) signature length field:
        // We parse until identityPublicKey section end, which is right before signatureLen.
        val data = HandshakePaddingP1.unwrapIfNeeded(rawWithoutPadding)
        var off = 0
        require(data[off++] == PROTOCOL_VERSION) { "bad version" }
        val supportedCount = readU16LE(data, off).also { off += 2 }.toInt()
        var needsV2Contribution = false
        repeat(supportedCount) {
            val suiteId = readU16LE(data, off).also { off += 2 }
            if (suiteId == P2PCryptoSuite.MLKEM_768_FS_COMPAT.wireId) {
                needsV2Contribution = true
            }
        }
        val ksCount = readU16LE(data, off).also { off += 2 }.toInt()
        repeat(ksCount) {
            off += 2 // suiteId
            val shareLen = readU16LE(data, off).also { off += 2 }.toInt()
            off += shareLen
        }
        off += 32 // clientNonce
        val capLen = readU16LE(data, off).also { off += 2 }.toInt()
        off += capLen
        val policyLen = readU16LE(data, off).also { off += 2 }.toInt()
        off += policyLen
        val idLen = readU16LE(data, off).also { off += 2 }.toInt()
        off += idLen
        if (needsV2Contribution) {
            val contribLen = readU16LE(data, off).also { off += 2 }.toInt()
            off += contribLen
        }
        if (off + P2PSoa.CONTAINER_MAGIC.size + 2 <= data.size) {
            val maybeMagic = data.copyOfRange(off, off + P2PSoa.CONTAINER_MAGIC.size)
            if (maybeMagic.contentEquals(P2PSoa.CONTAINER_MAGIC)) {
                off += P2PSoa.CONTAINER_MAGIC.size
                val extLen = readU16LE(data, off).also { off += 2 }.toInt()
                require(off + extLen <= data.size) { "Extensions truncated" }
                off += extLen
            }
        }
        return data.copyOfRange(0, off)
    }

    private fun extractMessageBWithoutSignature(rawWithoutPadding: ByteArray): ByteArray {
        val data = HandshakePaddingP1.unwrapIfNeeded(rawWithoutPadding)
        var off = 0
        require(data[off++] == PROTOCOL_VERSION) { "bad version" }
        off += 2 // selectedSuiteWireId
        val shareLen = readU16LE(data, off).also { off += 2 }.toInt()
        off += shareLen
        off += 32 // serverNonce
        val payloadLen = readU16LE(data, off).also { off += 2 }.toInt()
        off += payloadLen
        val idLen = readU16LE(data, off).also { off += 2 }.toInt()
        off += idLen
        return data.copyOfRange(0, off)
    }

    private fun readU16LE(data: ByteArray, offset: Int): UShort {
        return ((data[offset].toInt() and 0xFF) or ((data[offset + 1].toInt() and 0xFF) shl 8)).toUShort()
    }

    fun generateEd25519IdentityKeyPair(): Pair<PrivateKey, ByteArray> {
        val discoveredProviders = Security.getProviders("KeyPairGenerator.Ed25519").orEmpty()
        val softwareProviders = buildList {
            discoveredProviders
                .filterNot { provider ->
                    provider.name.contains("AndroidKeyStore", ignoreCase = true)
                }
                .forEach(::add)

            listOf("Conscrypt", "AndroidOpenSSL", "BC").forEach { name ->
                Security.getProvider(name)?.let { provider ->
                    if (none { it.name == provider.name } &&
                        !provider.name.contains("AndroidKeyStore", ignoreCase = true)
                    ) {
                        add(provider)
                    }
                }
            }

            val bundledBc = bundledBouncyCastleProviderOrNull()
            if (bundledBc != null && !providerAlreadyIncluded(this, bundledBc)) {
                add(bundledBc)
            }
        }
        val kp = softwareProviders.asSequence()
            .mapNotNull { provider ->
                runCatching {
                    KeyPairGenerator.getInstance("Ed25519", provider).generateKeyPair()
                }.getOrNull()
            }
            .firstOrNull()
            ?: run {
                val defaultGenerator = KeyPairGenerator.getInstance("Ed25519")
                require(!defaultGenerator.provider.name.contains("AndroidKeyStore", ignoreCase = true)) {
                    "No exportable Ed25519 software provider available"
                }
                defaultGenerator.generateKeyPair()
            }
        val rawPub = kp.public.encoded.copyOfRange(kp.public.encoded.size - 32, kp.public.encoded.size)
        return kp.private to rawPub
    }

    fun decodeEd25519PrivateKey(pkcs8: ByteArray): PrivateKey {
        softwareEd25519KeyFactoryOrNull()?.let { keyFactory ->
            return keyFactory.generatePrivate(PKCS8EncodedKeySpec(pkcs8))
        }
        val defaultFactory = KeyFactory.getInstance("Ed25519")
        require(!defaultFactory.provider.name.contains("AndroidKeyStore", ignoreCase = true)) {
            "No exportable Ed25519 KeyFactory provider available"
        }
        return defaultFactory.generatePrivate(PKCS8EncodedKeySpec(pkcs8))
    }

    private fun softwareEd25519KeyFactoryOrNull(): KeyFactory? {
        val providers = buildList {
            Security.getProviders("KeyFactory.Ed25519").orEmpty()
                .filterNot { provider ->
                    provider.name.contains("AndroidKeyStore", ignoreCase = true)
                }
                .forEach(::add)

            listOf("Conscrypt", "AndroidOpenSSL", "BC").forEach { name ->
                Security.getProvider(name)?.let { provider ->
                    if (none { it.name == provider.name } &&
                        !provider.name.contains("AndroidKeyStore", ignoreCase = true)
                    ) {
                        add(provider)
                    }
                }
            }

            val bundledBc = bundledBouncyCastleProviderOrNull()
            if (bundledBc != null && !providerAlreadyIncluded(this, bundledBc)) {
                add(bundledBc)
            }
        }

        providers.forEach { provider ->
            runCatching {
                return KeyFactory.getInstance("Ed25519", provider)
            }
        }
        return null
    }

    fun generateMlDsa65IdentityKeyPair(): Pair<ByteArray, ByteArray> {
        val provider = requireNotNull(pqcProvider) {
            "ML-DSA-65 key generation requested but AndroidPQCCryptoProvider unavailable"
        }
        val keyPair = runBlocking { provider.generateKeyPair(KeyUsage.SIGNING) }
        return keyPair.privateKey.bytes to keyPair.publicKey.bytes
    }

    private fun signEd25519(data: ByteArray, privateKey: PrivateKey): ByteArray {
        val sig = softwareEd25519Signatures()
            .asSequence()
            .mapNotNull { candidate ->
                runCatching {
                    candidate.initSign(privateKey)
                    candidate
                }.getOrNull()
            }
            .firstOrNull()
            ?: Signature.getInstance("Ed25519").also { fallback ->
                require(!fallback.provider.name.contains("AndroidKeyStore", ignoreCase = true)) {
                    "No exportable Ed25519 software signature provider available"
                }
                fallback.initSign(privateKey)
            }
        sig.update(data)
        return sig.sign()
    }

    fun signEd25519Public(data: ByteArray, privateKey: PrivateKey): ByteArray =
        signEd25519(data, privateKey)

    private fun signByAlgorithm(
        data: ByteArray,
        algorithm: P2PIdentityPublicKeys.ProtocolAlgorithm,
        ed25519PrivateKey: PrivateKey?,
        mlDsaPrivateKey: ByteArray?
    ): ByteArray {
        return when (algorithm) {
            P2PIdentityPublicKeys.ProtocolAlgorithm.ED25519 -> {
                val key = requireNotNull(ed25519PrivateKey) {
                    "ED25519 signing requires a java.security.PrivateKey"
                }
                signEd25519(data, key)
            }
            P2PIdentityPublicKeys.ProtocolAlgorithm.ML_DSA_65 -> {
                val key = requireNotNull(mlDsaPrivateKey) {
                    "ML-DSA-65 signing requires raw private key bytes"
                }
                val provider = requireNotNull(pqcProvider) {
                    "ML-DSA-65 requested but AndroidPQCCryptoProvider unavailable"
                }
                runBlocking { provider.sign(data, key) }
            }
            P2PIdentityPublicKeys.ProtocolAlgorithm.P256_ECDSA_LEGACY -> {
                error("P256_ECDSA_LEGACY signing is not supported in this handshake wire")
            }
        }
    }

    private fun verifyByAlgorithm(
        data: ByteArray,
        signature: ByteArray,
        publicKey: ByteArray,
        algorithm: P2PIdentityPublicKeys.ProtocolAlgorithm
    ): Boolean {
        return verifyByAlgorithmDetailed(
            data = data,
            signature = signature,
            publicKey = publicKey,
            algorithm = algorithm
        ).verified
    }

    internal fun verifyByAlgorithmDetailed(
        data: ByteArray,
        signature: ByteArray,
        publicKey: ByteArray,
        algorithm: P2PIdentityPublicKeys.ProtocolAlgorithm,
        ed25519Verifier: (ByteArray, ByteArray, ByteArray) -> Boolean = Ed25519SoftwareVerifier::verify
    ): VerifyOutcome {
        return when (algorithm) {
            P2PIdentityPublicKeys.ProtocolAlgorithm.ED25519 -> {
                runCatching { ed25519Verifier(data, signature, publicKey) }
                    .fold(
                        onSuccess = { VerifyOutcome(verified = it) },
                        onFailure = { VerifyOutcome(verified = false, failure = it.message ?: it::class.java.simpleName) }
                    )
            }
            P2PIdentityPublicKeys.ProtocolAlgorithm.ML_DSA_65 -> {
                val provider = pqcProvider ?: return VerifyOutcome(
                    verified = false,
                    failure = "AndroidPQCCryptoProvider unavailable"
                )
                runCatching { runBlocking { provider.verify(data, signature, publicKey) } }
                    .fold(
                        onSuccess = { VerifyOutcome(verified = it) },
                        onFailure = { VerifyOutcome(verified = false, failure = it.message ?: it::class.java.simpleName) }
                    )
            }
            P2PIdentityPublicKeys.ProtocolAlgorithm.P256_ECDSA_LEGACY -> VerifyOutcome(
                verified = false,
                failure = "P256 legacy is unsupported for protocol signatures"
            )
        }
    }

    internal data class VerifyOutcome(
        val verified: Boolean,
        val failure: String? = null
    )

    private fun emitInteropLog(level: Int, message: String) {
        runCatching {
            when (level) {
                Log.WARN -> Log.w(TAG, message)
                Log.ERROR -> Log.e(TAG, message)
                else -> Log.i(TAG, message)
            }
        }.getOrElse {
            println("$TAG: $message")
        }
    }

    private fun sha256Hex(data: ByteArray): String =
        sha256(data).joinToString(separator = "") { "%02x".format(it) }

    private fun softwareEd25519Signatures(): List<Signature> =
        buildList {
            Security.getProviders("Signature.Ed25519").orEmpty()
                .filterNot { provider ->
                    provider.name.contains("AndroidKeyStore", ignoreCase = true)
                }
                .forEach { provider ->
                    runCatching { Signature.getInstance("Ed25519", provider) }.getOrNull()?.let(::add)
                }

            listOf("Conscrypt", "AndroidOpenSSL", "BC").forEach { name ->
                Security.getProvider(name)?.let { provider ->
                    if (none { it.provider.name == provider.name } &&
                        !provider.name.contains("AndroidKeyStore", ignoreCase = true)
                    ) {
                        runCatching { Signature.getInstance("Ed25519", provider) }.getOrNull()?.let(::add)
                    }
                }
            }

            val bundledBc = bundledBouncyCastleProviderOrNull()
            if (bundledBc != null && this.none { existing ->
                    providerMatches(existing.provider, bundledBc)
                }
            ) {
                runCatching { Signature.getInstance("Ed25519", bundledBc) }.getOrNull()?.let(::add)
            }
        }

    private fun bundledBouncyCastleProviderOrNull() =
        runCatching { BouncyCastleProvider() }.getOrNull()

    private fun providerAlreadyIncluded(providers: List<java.security.Provider>, candidate: java.security.Provider): Boolean =
        providers.any { existing -> providerMatches(existing, candidate) }

    private fun providerMatches(existing: java.security.Provider, candidate: java.security.Provider): Boolean =
        existing.name == candidate.name &&
            existing::class.java.name == candidate::class.java.name

    fun validateKeyShareLength(length: Int, suite: P2PCryptoSuite) {
        val expected = when (suite) {
            P2PCryptoSuite.Q_PERIAPT_CONTEXT_BOUND -> P2PQPeriaptKem.QPERIAPT_CIPHERTEXT_SIZE
            P2PCryptoSuite.X_WING -> 1120
            P2PCryptoSuite.MLKEM_768 -> 1088
            P2PCryptoSuite.MLKEM_768_FS_COMPAT -> 1088
            P2PCryptoSuite.X25519 -> 32
            P2PCryptoSuite.P256 -> 65
        }
        require(length == expected) { "KeyShare length mismatch for ${suite.name}: $length != $expected" }
    }

    /**
     * Pro release KDF core:
     * kdfInfo = "SkyBridge-KDF" || 0x01 || suiteWireIdLE(2) || kdfCompositionLabel || transcriptHashA || transcriptHashB || clientNonce || serverNonce
     * salt = SHA256("SkyBridge-KDF-Salt-v1|" || kdfInfo)
     * sendKey = HKDF-SHA256(sharedSecret, salt, info = kdfInfo || "handshake|initiator_to_responder" or opposite, out=32)
     * receiveKey similarly.
     *
     * transcriptHash = SHA256(transcriptHashA || transcriptHashB)
     */
    fun deriveSessionKeys(
        roleIsInitiator: Boolean,
        suite: P2PCryptoSuite,
        transcriptA: ByteArray,
        transcriptB: ByteArray,
        clientNonce: ByteArray,
        serverNonce: ByteArray,
        sharedSecret32: ByteArray
    ): DerivedSessionKeys {
        require(sharedSecret32.size == 32) { "sharedSecret must be 32 bytes" }
        require(clientNonce.size == 32) { "clientNonce must be 32 bytes" }
        require(serverNonce.size == 32) { "serverNonce must be 32 bytes" }
        require(transcriptA.size == 32) { "transcriptA must be 32 bytes" }
        require(transcriptB.size == 32) { "transcriptB must be 32 bytes" }

        val suiteIdLe = ByteBuffer.allocate(2).order(ByteOrder.LITTLE_ENDIAN).putShort(suite.wireId.toShort()).array()
        val compositionLabel = if (suite == P2PCryptoSuite.MLKEM_768_FS_COMPAT) "v2-static+ephemeral" else "v1-single"
        val kdfInfo = concat(
            "SkyBridge-KDF".toByteArray(Charsets.UTF_8),
            byteArrayOf(0x01.toByte()),
            suiteIdLe,
            compositionLabel.toByteArray(Charsets.UTF_8),
            transcriptA,
            transcriptB,
            clientNonce,
            serverNonce
        )

        val salt = sha256(concat("SkyBridge-KDF-Salt-v1|".toByteArray(Charsets.UTF_8), kdfInfo))

        val i2rInfo = concat(kdfInfo, "handshake|initiator_to_responder".toByteArray(Charsets.UTF_8))
        val r2iInfo = concat(kdfInfo, "handshake|responder_to_initiator".toByteArray(Charsets.UTF_8))

        val sendInfo = if (roleIsInitiator) i2rInfo else r2iInfo
        val recvInfo = if (roleIsInitiator) r2iInfo else i2rInfo

        val sendKey = hkdfSha256(sharedSecret32, salt, sendInfo, 32)
        val receiveKey = hkdfSha256(sharedSecret32, salt, recvInfo, 32)
        val transcriptHash = sha256(concat(transcriptA, transcriptB))
        return DerivedSessionKeys(sendKey, receiveKey, transcriptHash)
    }

    /**
     * Pro release handshake payload sealing:
     * key = HKDF-SHA256(ikm=sharedSecret32, salt=transcriptHashA32, info="handshake-payload", out=32)
     * ciphertext/tag = AES-256-GCM(key, nonce=random(12), aad=empty)
     * sealed wire = HandshakeSealedBox combined-with-header (HPKE header shape, version=1)
     */
    fun sealHandshakePayload(
        sharedSecret32: ByteArray,
        transcriptHashA32: ByteArray,
        suite: P2PCryptoSuite,
        plaintext: ByteArray,
        encapsulatedKey: ByteArray
    ): P2PHPKESealedBox {
        require(sharedSecret32.size == 32) { "sharedSecret must be 32 bytes" }
        require(transcriptHashA32.size == 32) { "transcriptHashA must be 32 bytes" }

        val key = deriveHandshakePayloadKey(sharedSecret32, transcriptHashA32)
        val nonce = ByteArray(12).also { secureRandom.nextBytes(it) }

        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        val secretKey = SecretKeySpec(key, "AES")
        cipher.init(Cipher.ENCRYPT_MODE, secretKey, GCMParameterSpec(128, nonce))
        val ciphertextWithTag = cipher.doFinal(plaintext)
        require(ciphertextWithTag.size >= 16) { "ciphertext too short" }

        val ciphertext = ciphertextWithTag.copyOfRange(0, ciphertextWithTag.size - 16)
        val tag = ciphertextWithTag.copyOfRange(ciphertextWithTag.size - 16, ciphertextWithTag.size)

        return P2PHPKESealedBox(
            version = 1,
            suiteWireId = suite.wireId,
            encapsulatedKey = encapsulatedKey,
            nonce = nonce,
            ciphertext = ciphertext,
            tag = tag
        )
    }

    fun openHandshakePayload(
        sharedSecret32: ByteArray,
        transcriptHashA32: ByteArray,
        sealedBox: P2PHPKESealedBox
    ): ByteArray {
        require(sharedSecret32.size == 32) { "sharedSecret must be 32 bytes" }
        require(transcriptHashA32.size == 32) { "transcriptHashA must be 32 bytes" }

        val key = deriveHandshakePayloadKey(sharedSecret32, transcriptHashA32)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        val secretKey = SecretKeySpec(key, "AES")
        cipher.init(Cipher.DECRYPT_MODE, secretKey, GCMParameterSpec(128, sealedBox.nonce))
        return cipher.doFinal(concat(sealedBox.ciphertext, sealedBox.tag))
    }

    /**
     * Pro release Finished:
     * macKey = HKDF-SHA256(baseKey, salt="", info="SkyBridge-FINISHED|LABEL|" + transcriptHash, out=32)
     * mac = HMAC-SHA256(transcriptHash, macKey)  (32 bytes)
     * wire = "FIN1" || direction(1) || reserved(1) || mac(32)
     */
    fun computeFinishedMac(
        label: String,
        baseKey32: ByteArray,
        transcriptHash32: ByteArray
    ): ByteArray {
        val info = concat("SkyBridge-FINISHED|$label|".toByteArray(Charsets.UTF_8), transcriptHash32)
        val macKey = hkdfSha256(baseKey32, salt = ByteArray(0), info = info, outLen = 32)
        return hmacSha256(macKey, transcriptHash32)
    }

    fun encodeFinished(direction: FinishedDirection, mac32: ByteArray): ByteArray {
        require(mac32.size == 32) { "Finished mac must be 32 bytes" }
        val out = ByteArray(4 + 1 + 1 + 32)
        // "FIN1"
        out[0] = 0x46
        out[1] = 0x49
        out[2] = 0x4E
        out[3] = 0x31
        out[4] = PROTOCOL_VERSION
        out[5] = direction.wire
        System.arraycopy(mac32, 0, out, 6, 32)
        return out
    }

    fun decodeFinished(wire: ByteArray): Finished {
        val data = HandshakePaddingP1.unwrapIfNeeded(wire)
        require(data.size == 4 + 1 + 1 + 32) { "Finished length mismatch" }
        require(data[0] == 0x46.toByte() && data[1] == 0x49.toByte() && data[2] == 0x4E.toByte() && data[3] == 0x31.toByte()) {
            "Finished magic mismatch"
        }
        val version = data[4]
        require(version == PROTOCOL_VERSION) { "Finished version mismatch" }
        val direction = requireNotNull(FinishedDirection.fromWire(data[5])) { "Finished direction invalid" }
        val mac = data.copyOfRange(6, 38)
        return Finished(version = version, direction = direction, mac = mac)
    }

    fun computePeerSigningFingerprint(identityPublicKeys: P2PIdentityPublicKeys.Keys): String {
        return ProtocolIdentityFingerprint.compute(identityPublicKeys)
    }

    fun verifyOrPersistPeerTrust(
        peerId: String,
        identityPublicKeys: P2PIdentityPublicKeys.Keys,
        trustStore: TrustStore,
        allowTrustOnFirstUse: Boolean = false
    ): TrustDecision {
        require(peerId.isNotBlank()) { "peerId is required for trust verification" }
        val observed = computePeerSigningFingerprint(identityPublicKeys)
        val pinned = trustStore.loadPeerSigningFingerprint(peerId)
        if (pinned == null) {
            require(allowTrustOnFirstUse) { "Peer is not pre-pinned: $peerId" }
            trustStore.savePeerSigningFingerprint(peerId, observed)
            return TrustDecision.TRUSTED_NEW
        }
        require(pinned.equals(observed, ignoreCase = true)) {
            "Peer identity mismatch for peer=$peerId ($PEER_SIGNING_FINGERPRINT_FIELD mismatch)"
        }
        return TrustDecision.TRUSTED_EXISTING
    }

    fun verifyFinished(
        finished: Finished,
        sessionKeys: DerivedSessionKeys,
        expectingFrom: FinishedDirection
    ): Boolean {
        if (finished.direction != expectingFrom) return false
        if (finished.mac.size != 32) return false

        val label = when (expectingFrom) {
            FinishedDirection.RESPONDER_TO_INITIATOR -> "R2I"
            FinishedDirection.INITIATOR_TO_RESPONDER -> "I2R"
        }
        val baseKey = when (expectingFrom) {
            // If we are verifying a message coming from peer, use our receiveKey (Pro release verifyFinished)
            FinishedDirection.RESPONDER_TO_INITIATOR,
            FinishedDirection.INITIATOR_TO_RESPONDER -> sessionKeys.receiveKey
        }
        val expected = computeFinishedMac(label = label, baseKey32 = baseKey, transcriptHash32 = sessionKeys.transcriptHash)
        return expected.contentEquals(finished.mac)
    }

    fun buildFinishedToSend(direction: FinishedDirection, sessionKeys: DerivedSessionKeys): ByteArray {
        val label = when (direction) {
            FinishedDirection.RESPONDER_TO_INITIATOR -> "R2I"
            FinishedDirection.INITIATOR_TO_RESPONDER -> "I2R"
        }
        val mac = computeFinishedMac(label = label, baseKey32 = sessionKeys.sendKey, transcriptHash32 = sessionKeys.transcriptHash)
        return encodeFinished(direction, mac)
    }

    private fun sha256(data: ByteArray): ByteArray =
        MessageDigest.getInstance("SHA-256").digest(data)

    private fun deriveHandshakePayloadKey(sharedSecret32: ByteArray, transcriptHashA32: ByteArray): ByteArray {
        return hkdfSha256(
            ikm = sharedSecret32,
            salt = transcriptHashA32,
            info = "handshake-payload".toByteArray(Charsets.UTF_8),
            outLen = 32
        )
    }

    private fun hkdfSha256(ikm: ByteArray, salt: ByteArray, info: ByteArray, outLen: Int): ByteArray {
        // HKDF-Extract: if salt is not provided, use HashLen zeros (RFC 5869).
        val extractSalt = if (salt.isEmpty()) ByteArray(32) else salt
        val prk = hmacSha256(extractSalt, ikm)
        var t = ByteArray(0)
        var okm = ByteArray(0)
        var counter: Byte = 1
        while (okm.size < outLen) {
            val input = concat(t, info, byteArrayOf(counter))
            t = hmacSha256(prk, input)
            okm = concat(okm, t)
            counter = (counter + 1).toByte()
        }
        return okm.copyOfRange(0, outLen)
    }

    private fun hmacSha256(key: ByteArray, data: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(data)
    }

    private fun concat(vararg parts: ByteArray): ByteArray {
        val total = parts.sumOf { it.size }
        val out = ByteArray(total)
        var off = 0
        for (p in parts) {
            System.arraycopy(p, 0, out, off, p.size)
            off += p.size
        }
        return out
    }
}
