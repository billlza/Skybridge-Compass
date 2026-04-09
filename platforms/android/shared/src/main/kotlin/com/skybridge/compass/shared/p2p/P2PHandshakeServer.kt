package com.skybridge.compass.shared.p2p

import com.skybridge.compass.shared.crypto.providers.AndroidPQCCryptoProvider
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.PrivateKey
import java.security.SecureRandom

/**
 * Minimal responder-side P2P v1 handshake compatible with Pro release:
 * - Classic: X25519 + Ed25519
 * - PQC: ML-KEM-768 + ML-DSA-65 (requires local ML-KEM private key)
 * - Hybrid: X-Wing + ML-DSA-65 (requires local X-Wing private key)
 *
 * This is used to derive SessionKeys for app-layer AES-GCM on WebRTC (DTLS is transport only).
 */
class P2PHandshakeServer(
    private val secureRandom: SecureRandom = SecureRandom()
) {
    data class KemPrivateKeys(
        val xWingPrivateKey: ByteArray? = null,
        val mlKem768PrivateKey: ByteArray? = null
    )

    data class RespondOptions(
        val platformVersion: String = android.os.Build.VERSION.RELEASE,
        val kemPrivateKeys: KemPrivateKeys = KemPrivateKeys(),
        val handshakePolicy: P2PHandshakePolicy = P2PHandshakePolicy.DEFAULT,
        val allowClassicBootstrapForTrustedPeer: Boolean = false,
        /**
         * Optional stable identity signing keys. When present, the handshake uses these keys
         * instead of generating fresh identity keys, so TOFU pinning remains stable across
         * reconnects.
         */
        val protocolSigningKeys: P2PProtocolSigningKeys? = null
    )

    data class ResponderState(
        val identityPrivateKey: PrivateKey?,
        val identityPrivateKeyRaw: ByteArray?,
        val identityAlgorithm: P2PIdentityPublicKeys.ProtocolAlgorithm,
        val identityPublicRaw: ByteArray,
        val clientNonce32: ByteArray,
        val serverNonce32: ByteArray,
        val transcriptHashA32: ByteArray,
        val transcriptHashB32: ByteArray,
        val sessionKeys: P2PHandshakeWire.DerivedSessionKeys
    )

    data class Response(
        val state: ResponderState,
        val messageBToSend: ByteArray
    )

    fun respond(rawMessageA: ByteArray): Response {
        return respond(
            rawMessageA = rawMessageA,
            peerIdForTrust = null,
            trustStore = null,
            allowTrustOnFirstUse = true,
            options = RespondOptions()
        )
    }

    fun respond(rawMessageA: ByteArray, options: RespondOptions): Response {
        return respond(
            rawMessageA = rawMessageA,
            peerIdForTrust = null,
            trustStore = null,
            allowTrustOnFirstUse = true,
            options = options
        )
    }

    fun respond(
        rawMessageA: ByteArray,
        peerIdForTrust: String?,
        trustStore: P2PHandshakeWire.TrustStore?,
        allowTrustOnFirstUse: Boolean = true,
        options: RespondOptions = RespondOptions()
    ): Response {
        val msgA = P2PHandshakeWire.decodeMessageA(rawMessageA)
        val okSigA = P2PHandshakeWire.verifyMessageASignature(
            messageA = msgA,
            rawMessageAWithoutPadding = HandshakePaddingP1.unwrapIfNeeded(rawMessageA)
        )
        require(okSigA) { "MessageA signature invalid" }
        if (peerIdForTrust != null && trustStore != null) {
            P2PHandshakeWire.verifyOrPersistPeerTrust(
                peerId = peerIdForTrust,
                identityPublicKeys = msgA.identityPublicKeys,
                trustStore = trustStore,
                allowTrustOnFirstUse = allowTrustOnFirstUse
            )
        } else {
            require(peerIdForTrust == null && trustStore == null) {
                "peerIdForTrust and trustStore must be provided together"
            }
        }

        // Strict semantics: unknown suite IDs are preserved during parsing but rejected during negotiation.
        // Must happen after signature verification so unauthenticated bytes cannot drive suite decisions.
        if (msgA.unknownSupportedSuiteWireIds.isNotEmpty()) {
            throw IllegalArgumentException("Unknown supported suite(s): ${msgA.unknownSupportedSuiteWireIds}")
        }
        if (msgA.unknownKeyShareSuiteWireIds.isNotEmpty()) {
            throw IllegalArgumentException("Unknown keyShare suite(s): ${msgA.unknownKeyShareSuiteWireIds}")
        }

        val suite = selectSuite(messageA = msgA, options = options)
        enforceIdentityAlgorithmBinding(
            suite = suite,
            algorithm = msgA.identityPublicKeys.protocolAlgorithm
        )
        val initiatorShare = msgA.keyShares.firstOrNull { it.knownSuite == suite }?.shareBytes
            ?: error("Missing keyShare for negotiated suite=${suite.name}")

        val serverNonce = ByteArray(32).also { secureRandom.nextBytes(it) }
        val transcriptA = P2PHandshakeWire.transcriptHashAFromWire(rawMessageA)

        val (idPrivKey, idPrivRaw, idPubRaw, idAlg) = when (suite) {
            P2PCryptoSuite.X25519 -> {
                val injected = options.protocolSigningKeys
                if (injected != null) {
                    val pub = injected.ed25519PublicKeyRaw32
                    require(pub.size == 32) { "Invalid Ed25519 public key length: ${pub.size}" }
                    Quad(injected.ed25519PrivateKey, null, pub, P2PIdentityPublicKeys.ProtocolAlgorithm.ED25519)
                } else {
                    val (priv, pub) = P2PHandshakeWire.generateEd25519IdentityKeyPair()
                    Quad(priv, null, pub, P2PIdentityPublicKeys.ProtocolAlgorithm.ED25519)
                }
            }
            P2PCryptoSuite.MLKEM_768,
            P2PCryptoSuite.X_WING -> {
                val injected = options.protocolSigningKeys
                if (injected?.mlDsa65PrivateKeyRaw != null && injected.mlDsa65PublicKeyRaw != null) {
                    Quad(null, injected.mlDsa65PrivateKeyRaw, injected.mlDsa65PublicKeyRaw, P2PIdentityPublicKeys.ProtocolAlgorithm.ML_DSA_65)
                } else {
                    val (privRaw, pubRaw) = P2PHandshakeWire.generateMlDsa65IdentityKeyPair()
                    Quad(null, privRaw, pubRaw, P2PIdentityPublicKeys.ProtocolAlgorithm.ML_DSA_65)
                }
            }
            else -> error("unsupported suite")
        }
        val identityKeysWire = P2PIdentityPublicKeys.Keys(
            protocolPublicKey = idPubRaw,
            protocolAlgorithm = idAlg,
            secureEnclavePublicKey = null
        )
        val identityBytes = identityKeysWire.encode()

        val payloadPlaintext = when (suite) {
            P2PCryptoSuite.X25519 -> P2PCryptoCapabilities(
                supportedKEM = listOf("x25519"),
                supportedSignature = listOf("ed25519"),
                supportedAuthProfiles = listOf("classic"),
                supportedAEAD = listOf("aes256GCM", "chaCha20Poly1305"),
                pqcAvailable = false,
                platformVersion = options.platformVersion,
                providerTypeRaw = P2PHandshakeWire.PROVIDER_TYPE_CRYPTO_KIT_CLASSIC
            ).deterministicEncode()
            P2PCryptoSuite.MLKEM_768 -> P2PCryptoCapabilities(
                supportedKEM = listOf("mlkem-768", "x25519"),
                supportedSignature = listOf("ml-dsa-65", "ed25519"),
                supportedAuthProfiles = listOf("pqc", "classic"),
                supportedAEAD = listOf("aes256GCM", "chaCha20Poly1305"),
                pqcAvailable = true,
                platformVersion = options.platformVersion,
                providerTypeRaw = P2PHandshakeWire.PROVIDER_TYPE_LIBOQS
            ).deterministicEncode()
            P2PCryptoSuite.X_WING -> P2PCryptoCapabilities(
                supportedKEM = listOf("x-wing", "mlkem-768", "x25519"),
                supportedSignature = listOf("ml-dsa-65", "ed25519"),
                supportedAuthProfiles = listOf("hybrid", "pqc", "classic"),
                supportedAEAD = listOf("aes256GCM", "chaCha20Poly1305"),
                pqcAvailable = true,
                platformVersion = options.platformVersion,
                providerTypeRaw = P2PHandshakeWire.PROVIDER_TYPE_CRYPTO_KIT_PQC
            ).deterministicEncode()
            P2PCryptoSuite.MLKEM_768_FS_COMPAT ->
                error("0x0102 is compatibility parse-only and not negotiable")
            P2PCryptoSuite.P256 -> error("P256 suite is not supported by this server")
        }

        val sharedSecret32: ByteArray
        val responderShare: ByteArray
        val sealedBoxCombined: ByteArray
        when (suite) {
            P2PCryptoSuite.X25519 -> {
                val seal = P2PClassicHpkeX25519.sealAndExport(
                    plaintext = payloadPlaintext,
                    receiverPublicKeyRaw32 = initiatorShare,
                    info = "handshake-payload".toByteArray(Charsets.UTF_8),
                    suiteWireId = suite.wireId
                )
                sharedSecret32 = seal.exportedSecret32
                responderShare = seal.sealedBox.encapsulatedKey
                sealedBoxCombined = seal.sealedBox.combinedWithHeader()
            }
            P2PCryptoSuite.MLKEM_768 -> {
                val sk = requireNotNull(options.kemPrivateKeys.mlKem768PrivateKey) {
                    "ML-KEM-768 selected but local ML-KEM private key is missing"
                }
                require(sk.size == AndroidPQCCryptoProvider.MLKEM768_SECRET_KEY_SIZE) {
                    "Invalid local ML-KEM private key length: ${sk.size}"
                }
                val pqc = AndroidPQCCryptoProvider()
                sharedSecret32 = pqc.decapsulate(initiatorShare, sk)
                responderShare = ByteArray(0)
                val sealed = P2PHandshakeWire.sealHandshakePayload(
                    sharedSecret32 = sharedSecret32,
                    transcriptHashA32 = transcriptA,
                    suite = suite,
                    plaintext = payloadPlaintext,
                    encapsulatedKey = ByteArray(0)
                )
                sealedBoxCombined = sealed.combinedWithHeader()
            }
            P2PCryptoSuite.X_WING -> {
                val sk = requireNotNull(options.kemPrivateKeys.xWingPrivateKey) {
                    "X-Wing selected but local X-Wing private key is missing"
                }
                val pqc = AndroidPQCCryptoProvider()
                sharedSecret32 = P2PXWingKem.decapsulate(ciphertext = initiatorShare, privateKey = sk, pqcProvider = pqc)
                responderShare = ByteArray(0)
                val sealed = P2PHandshakeWire.sealHandshakePayload(
                    sharedSecret32 = sharedSecret32,
                    transcriptHashA32 = transcriptA,
                    suite = suite,
                    plaintext = payloadPlaintext,
                    encapsulatedKey = ByteArray(0)
                )
                sealedBoxCombined = sealed.combinedWithHeader()
            }
            P2PCryptoSuite.MLKEM_768_FS_COMPAT ->
                error("0x0102 is compatibility parse-only and not negotiable")
            P2PCryptoSuite.P256 -> error("P256 suite is not supported by this server")
        }

        // Build MessageB without signature first (for transcript hash B)
        val msgBWithoutSig = buildMessageBWithoutSignature(
            suite = suite,
            responderShare = responderShare,
            serverNonce32 = serverNonce,
            encryptedPayloadCombined = sealedBoxCombined,
            identityPublicKeyBytes = identityBytes
        )
        val transcriptB = sha256(msgBWithoutSig)

        val sigPreimage = P2PHandshakeWire.buildMessageBSignaturePreimagePublic(
            transcriptHashA32 = transcriptA,
            selectedSuiteWireId = suite.wireId,
            responderShare = responderShare,
            serverNonce = serverNonce,
            payloadCombinedWithHeader = sealedBoxCombined,
            identityPublicKeyBytes = identityBytes
        )
        val sigB = when (idAlg) {
            P2PIdentityPublicKeys.ProtocolAlgorithm.ED25519 ->
                P2PHandshakeWire.signEd25519Public(sigPreimage, requireNotNull(idPrivKey))
            P2PIdentityPublicKeys.ProtocolAlgorithm.ML_DSA_65 -> {
                val pqc = AndroidPQCCryptoProvider()
                runBlockingSign(pqc, sigPreimage, requireNotNull(idPrivRaw))
            }
            P2PIdentityPublicKeys.ProtocolAlgorithm.P256_ECDSA_LEGACY ->
                error("P256_ECDSA_LEGACY not supported for handshake signing")
        }

        val msgB = buildMessageBWithSignature(
            withoutSig = msgBWithoutSig,
            signature = sigB
        )

        val keys = P2PHandshakeWire.deriveSessionKeys(
            roleIsInitiator = false,
            suite = suite,
            transcriptA = transcriptA,
            transcriptB = transcriptB,
            clientNonce = msgA.clientNonce,
            serverNonce = serverNonce,
            sharedSecret32 = sharedSecret32
        )

        val st = ResponderState(
            identityPrivateKey = idPrivKey,
            identityPrivateKeyRaw = idPrivRaw,
            identityAlgorithm = idAlg,
            identityPublicRaw = idPubRaw,
            clientNonce32 = msgA.clientNonce,
            serverNonce32 = serverNonce,
            transcriptHashA32 = transcriptA,
            transcriptHashB32 = transcriptB,
            sessionKeys = keys
        )

        return Response(state = st, messageBToSend = HandshakePaddingP1.wrap(msgB))
    }

    fun verifyClientFinished(rawFinished: ByteArray, sessionKeys: P2PHandshakeWire.DerivedSessionKeys): Boolean {
        val finished = P2PHandshakeWire.decodeFinished(rawFinished)
        return P2PHandshakeWire.verifyFinished(
            finished = finished,
            sessionKeys = sessionKeys,
            expectingFrom = P2PHandshakeWire.FinishedDirection.INITIATOR_TO_RESPONDER
        )
    }

    fun buildResponderFinished(sessionKeys: P2PHandshakeWire.DerivedSessionKeys): ByteArray {
        val finished = P2PHandshakeWire.buildFinishedToSend(
            direction = P2PHandshakeWire.FinishedDirection.RESPONDER_TO_INITIATOR,
            sessionKeys = sessionKeys
        )
        return HandshakePaddingP1.wrap(finished)
    }

    private fun buildMessageBWithoutSignature(
        suite: P2PCryptoSuite,
        responderShare: ByteArray,
        serverNonce32: ByteArray,
        encryptedPayloadCombined: ByteArray,
        identityPublicKeyBytes: ByteArray
    ): ByteArray {
        require(serverNonce32.size == 32) { "serverNonce must be 32 bytes" }
        val bb = ByteBuffer.allocate(
            1 + 2 + 2 + responderShare.size + 32 +
                2 + encryptedPayloadCombined.size +
                2 + identityPublicKeyBytes.size
        ).order(ByteOrder.LITTLE_ENDIAN)
        bb.put(0x01)
        bb.putShort(suite.wireId.toShort())
        bb.putShort(responderShare.size.toShort())
        bb.put(responderShare)
        bb.put(serverNonce32)
        bb.putShort(encryptedPayloadCombined.size.toShort())
        bb.put(encryptedPayloadCombined)
        bb.putShort(identityPublicKeyBytes.size.toShort())
        bb.put(identityPublicKeyBytes)
        return bb.array()
    }

    private fun buildMessageBWithSignature(withoutSig: ByteArray, signature: ByteArray): ByteArray {
        val bb = ByteBuffer.allocate(withoutSig.size + 2 + signature.size + 2).order(ByteOrder.LITTLE_ENDIAN)
        bb.put(withoutSig)
        bb.putShort(signature.size.toShort())
        bb.put(signature)
        bb.putShort(0) // no secure enclave sig
        return bb.array()
    }

    private fun sha256(data: ByteArray): ByteArray =
        java.security.MessageDigest.getInstance("SHA-256").digest(data)

    private data class Quad<A, B, C, D>(val first: A, val second: B, val third: C, val fourth: D)

    private fun runBlockingSign(
        pqc: AndroidPQCCryptoProvider,
        data: ByteArray,
        privateKeyRaw: ByteArray
    ): ByteArray {
        // AndroidPQCCryptoProvider.sign is suspend; keep server API synchronous.
        return kotlinx.coroutines.runBlocking { pqc.sign(data, privateKeyRaw) }
    }

    private fun selectSuite(messageA: P2PHandshakeWire.MessageA, options: RespondOptions): P2PCryptoSuite {
        val platformMajor = parsePlatformMajorVersion(options.platformVersion)
        val preferredTiers = when {
            platformMajor != null && platformMajor >= 16 ->
                listOf(SuiteTier.X_WING, SuiteTier.PQC, SuiteTier.CLASSIC)
            platformMajor != null && platformMajor in 13..15 ->
                listOf(SuiteTier.PQC, SuiteTier.CLASSIC)
            else ->
                listOf(SuiteTier.CLASSIC)
        }

        fun supports(suite: P2PCryptoSuite): Boolean =
            messageA.supportedSuites.any { it.knownOrNull() == suite }

        fun hasKeyShare(suite: P2PCryptoSuite): Boolean =
            messageA.keyShares.any { it.knownSuite == suite }

        val runtimeHasLiboqs = AndroidPQCCryptoProvider.isAvailable()
        val runtimeHasXWing = P2PXWingKem.isAvailable()

        val normalizedLocalPolicy = normalizePolicy(options.handshakePolicy)
        val normalizedPeerPolicy = normalizePolicy(messageA.policy)
        val requestedMinimumTier = maxTier(
            parseMinimumTier(normalizedLocalPolicy.minimumTierRaw),
            parseMinimumTier(normalizedPeerPolicy.minimumTierRaw)
        )
        val peerSupportsMlKemOnly =
            supports(P2PCryptoSuite.MLKEM_768) &&
                hasKeyShare(P2PCryptoSuite.MLKEM_768) &&
                !supports(P2PCryptoSuite.X_WING)
        val effectiveMinimumTier = when {
            requestedMinimumTier == SuiteTier.X_WING &&
                peerSupportsMlKemOnly -> SuiteTier.PQC
            else -> requestedMinimumTier
        }
        val effectiveRequirePqc = normalizedLocalPolicy.requirePqc || normalizedPeerPolicy.requirePqc
        val effectiveAllowClassicFallback =
            normalizedLocalPolicy.allowClassicFallback && normalizedPeerPolicy.allowClassicFallback

        val selectedTier = preferredTiers.firstOrNull { tier ->
            val tierAllowed = when (tier) {
                SuiteTier.CLASSIC ->
                    options.allowClassicBootstrapForTrustedPeer ||
                        (!effectiveRequirePqc &&
                            effectiveAllowClassicFallback &&
                            tier.rank >= effectiveMinimumTier.rank)
                else -> tier.rank >= effectiveMinimumTier.rank
            }
            if (!tierAllowed) return@firstOrNull false

            when (tier) {
                SuiteTier.X_WING ->
                    runtimeHasXWing &&
                        options.kemPrivateKeys.xWingPrivateKey != null &&
                        supports(P2PCryptoSuite.X_WING) &&
                        hasKeyShare(P2PCryptoSuite.X_WING)
                SuiteTier.PQC ->
                    runtimeHasLiboqs &&
                        options.kemPrivateKeys.mlKem768PrivateKey != null &&
                        supports(P2PCryptoSuite.MLKEM_768) &&
                        hasKeyShare(P2PCryptoSuite.MLKEM_768)
                SuiteTier.CLASSIC ->
                    supports(P2PCryptoSuite.X25519) &&
                        hasKeyShare(P2PCryptoSuite.X25519)
            }
        } ?: run {
            if (options.allowClassicBootstrapForTrustedPeer &&
                supports(P2PCryptoSuite.X25519) &&
                hasKeyShare(P2PCryptoSuite.X25519)
            ) {
                SuiteTier.CLASSIC
            } else {
                throw IllegalStateException(
                    "No compatible suite for effective policy(minimum=${effectiveMinimumTier.name}, requirePqc=$effectiveRequirePqc, allowClassicFallback=$effectiveAllowClassicFallback)"
                )
            }
        }

        val suite = when (selectedTier) {
            SuiteTier.X_WING -> P2PCryptoSuite.X_WING
            SuiteTier.PQC -> P2PCryptoSuite.MLKEM_768
            SuiteTier.CLASSIC -> P2PCryptoSuite.X25519
        }

        require(P2PCryptoSuite.isNegotiable(suite)) {
            "No compatible suite in MessageA (known=${messageA.supportedSuites.map { it.wireId }}, unknown=${messageA.unknownSupportedSuiteWireIds})"
        }
        return suite
    }

    private fun parsePlatformMajorVersion(value: String): Int? {
        val token = Regex("(\\d{1,2})").find(value)?.groupValues?.getOrNull(1) ?: return null
        return token.toIntOrNull()
    }

    private enum class SuiteTier {
        X_WING,
        PQC,
        CLASSIC;

        val rank: Int
            get() = when (this) {
                CLASSIC -> 0
                PQC -> 1
                X_WING -> 2
            }
    }

    private fun parseMinimumTier(raw: String): SuiteTier = when (raw.trim()) {
        "nativePQC", "x-wing", "xwing", "strictXWing" -> SuiteTier.X_WING
        "liboqsPQC", "pqc", "mlkem", "ml-kem" -> SuiteTier.PQC
        else -> SuiteTier.CLASSIC
    }

    private fun normalizePolicy(policy: P2PHandshakePolicy): P2PHandshakePolicy {
        val normalizedTier = when (parseMinimumTier(policy.minimumTierRaw)) {
            SuiteTier.X_WING -> "nativePQC"
            SuiteTier.PQC -> "liboqsPQC"
            SuiteTier.CLASSIC -> "classic"
        }
        return policy.copy(minimumTierRaw = normalizedTier)
    }

    private fun maxTier(a: SuiteTier, b: SuiteTier): SuiteTier =
        if (a.rank >= b.rank) a else b

    private fun enforceIdentityAlgorithmBinding(
        suite: P2PCryptoSuite,
        algorithm: P2PIdentityPublicKeys.ProtocolAlgorithm
    ) {
        val expected = when (suite) {
            P2PCryptoSuite.X25519 -> P2PIdentityPublicKeys.ProtocolAlgorithm.ED25519
            P2PCryptoSuite.MLKEM_768,
            P2PCryptoSuite.X_WING ->
                P2PIdentityPublicKeys.ProtocolAlgorithm.ML_DSA_65
            P2PCryptoSuite.MLKEM_768_FS_COMPAT,
            P2PCryptoSuite.P256 ->
                error("Unsupported suite for identity binding: ${suite.name}")
        }
        require(algorithm == expected) {
            "Signature algorithm mismatch for suite=${suite.name}: expected=${expected.name}, actual=${algorithm.name}"
        }
    }
}
