package com.skybridge.compass.shared.p2p

import com.skybridge.compass.shared.crypto.providers.AndroidPQCCryptoProvider
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
        val qPeriaptPrivateKey: ByteArray? = null,
        val xWingPrivateKey: ByteArray? = null,
        val mlKem768PrivateKey: ByteArray? = null
    )

    data class RespondOptions(
        val platformVersion: String = defaultPlatformVersion(),
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
        val sessionKeys: P2PHandshakeWire.DerivedSessionKeys,
        /** Fingerprint whose MessageA signature and configured pin were verified for this state. */
        val remoteProtocolIdentityFingerprint: String
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
            allowTrustOnFirstUse = false,
            options = RespondOptions()
        )
    }

    fun respond(rawMessageA: ByteArray, options: RespondOptions): Response {
        return respond(
            rawMessageA = rawMessageA,
            peerIdForTrust = null,
            trustStore = null,
            allowTrustOnFirstUse = false,
            options = options
        )
    }

    fun respond(
        rawMessageA: ByteArray,
        peerIdForTrust: String?,
        trustStore: P2PHandshakeWire.TrustStore?,
        allowTrustOnFirstUse: Boolean = false,
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
            P2PCryptoSuite.Q_PERIAPT_CONTEXT_BOUND,
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
            P2PCryptoSuite.Q_PERIAPT_CONTEXT_BOUND -> {
                val capabilities = P2PCryptoCapabilities(
                    supportedKEM = listOf(P2PQPeriaptKem.KEM_CAPABILITY_NAME),
                    supportedSignature = listOf("ml-dsa-65"),
                    supportedAuthProfiles = listOf(QPeriaptPlatformPolicy.AUTH_PROFILE),
                    supportedAEAD = listOf("aes256GCM", "chaCha20Poly1305"),
                    pqcAvailable = true,
                    platformVersion = options.platformVersion,
                    providerTypeRaw = P2PHandshakeWire.PROVIDER_TYPE_QPERIAPT
                )
                QPeriaptPlatformPolicy.requireLocalAndroidSupported(options.platformVersion)
                capabilities.deterministicEncode()
            }
            P2PCryptoSuite.MLKEM_768 -> P2PCryptoCapabilities(
                supportedKEM = listOf("mlkem-768"),
                supportedSignature = listOf("ml-dsa-65"),
                supportedAuthProfiles = listOf("pqc"),
                supportedAEAD = listOf("aes256GCM", "chaCha20Poly1305"),
                pqcAvailable = true,
                platformVersion = options.platformVersion,
                providerTypeRaw = P2PHandshakeWire.PROVIDER_TYPE_LIBOQS
            ).deterministicEncode()
            P2PCryptoSuite.X_WING -> P2PCryptoCapabilities(
                supportedKEM = listOf("x-wing", "mlkem-768"),
                supportedSignature = listOf("ml-dsa-65"),
                supportedAuthProfiles = listOf("hybrid", "pqc"),
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
        val sealedBox: P2PHPKESealedBox
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
                sealedBox = seal.sealedBox
            }
            P2PCryptoSuite.Q_PERIAPT_CONTEXT_BOUND -> {
                val sk = requireNotNull(options.kemPrivateKeys.qPeriaptPrivateKey) {
                    "Q-Periapt selected but local Q-Periapt private key is missing"
                }
                val pqc = AndroidPQCCryptoProvider()
                sharedSecret32 = P2PQPeriaptKem.decapsulate(
                    ciphertext = initiatorShare,
                    privateKey = sk,
                    pqcProvider = pqc
                )
                responderShare = ByteArray(0)
                val sealed = P2PHandshakeWire.sealHandshakePayload(
                    sharedSecret32 = sharedSecret32,
                    transcriptHashA32 = transcriptA,
                    suite = suite,
                    plaintext = payloadPlaintext,
                    encapsulatedKey = ByteArray(0)
                )
                sealedBox = sealed
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
                sealedBox = sealed
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
                sealedBox = sealed
            }
            P2PCryptoSuite.MLKEM_768_FS_COMPAT ->
                error("0x0102 is compatibility parse-only and not negotiable")
            P2PCryptoSuite.P256 -> error("P256 suite is not supported by this server")
        }

        val sealedBoxCombined = sealedBox.combinedWithHeader()

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

        val msgB = P2PHandshakeWire.encodeMessageB(
            P2PHandshakeWire.MessageB(
                selectedSuite = P2PCryptoSuiteId.Known(suite),
                responderShare = responderShare,
                serverNonce = serverNonce,
                encryptedPayload = sealedBox,
                identityPublicKeys = identityKeysWire,
                signature = sigB,
                secureEnclaveSignature = null
            )
        )
        val transcriptB = P2PHandshakeWire.transcriptHashBFromWire(msgB)

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
            sessionKeys = keys,
            remoteProtocolIdentityFingerprint =
                P2PHandshakeWire.computePeerSigningFingerprint(msgA.identityPublicKeys)
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
        val normalizedLocalPolicy = normalizePolicy(options.handshakePolicy)
        val normalizedPeerPolicy = normalizePolicy(messageA.policy)
        val requestedMinimumTier = maxTier(
            parseMinimumTier(normalizedLocalPolicy.minimumTierRaw),
            parseMinimumTier(normalizedPeerPolicy.minimumTierRaw)
        )
        val qPeriaptExplicit = requestedMinimumTier == SuiteTier.Q_PERIAPT
        if (qPeriaptExplicit) {
            QPeriaptPlatformPolicy.requireLocalAndroidSupported(options.platformVersion)
        }
        val preferredTiers =
            if (qPeriaptExplicit) {
                listOf(SuiteTier.Q_PERIAPT)
            } else {
                listOf(SuiteTier.X_WING, SuiteTier.PQC, SuiteTier.CLASSIC)
            }

        fun supports(suite: P2PCryptoSuite): Boolean =
            messageA.supportedSuites.any { it.knownOrNull() == suite }

        fun hasKeyShare(suite: P2PCryptoSuite): Boolean =
            messageA.keyShares.any { it.knownSuite == suite }

        val runtimeHasLiboqs = AndroidPQCCryptoProvider.isAvailable()
        val runtimeHasXWing = P2PXWingKem.isAvailable()

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
                    (options.allowClassicBootstrapForTrustedPeer && !qPeriaptExplicit) ||
                        (!effectiveRequirePqc &&
                            effectiveAllowClassicFallback &&
                            tier.rank >= effectiveMinimumTier.rank)
                else -> tier.rank >= effectiveMinimumTier.rank
            }
            if (!tierAllowed) return@firstOrNull false

            when (tier) {
                SuiteTier.Q_PERIAPT ->
                    P2PQPeriaptKem.isAvailable() &&
                        options.kemPrivateKeys.qPeriaptPrivateKey != null &&
                        supports(P2PCryptoSuite.Q_PERIAPT_CONTEXT_BOUND) &&
                        hasKeyShare(P2PCryptoSuite.Q_PERIAPT_CONTEXT_BOUND) &&
                        messageA.capabilities
                            .let {
                                QPeriaptPlatformPolicy.requireHandshakePeerEligible(
                                    capabilities = it,
                                    peerRole = "initiator"
                                )
                                true
                            }
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
                !qPeriaptExplicit &&
                supports(P2PCryptoSuite.X25519) &&
                hasKeyShare(P2PCryptoSuite.X25519)
            ) {
                SuiteTier.CLASSIC
            } else {
                // Explicit set intersection for the diagnostic: a tier is mutually
                // supported iff this responder can run it (runtime + private key) AND
                // the initiator both declared it and sent a matching key share (R4.3).
                fun tierMutuallySupported(tier: SuiteTier): Boolean = when (tier) {
                    SuiteTier.Q_PERIAPT ->
                        P2PQPeriaptKem.isAvailable() &&
                            options.kemPrivateKeys.qPeriaptPrivateKey != null &&
                            supports(P2PCryptoSuite.Q_PERIAPT_CONTEXT_BOUND) &&
                            hasKeyShare(P2PCryptoSuite.Q_PERIAPT_CONTEXT_BOUND)
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
                        supports(P2PCryptoSuite.X25519) && hasKeyShare(P2PCryptoSuite.X25519)
                }
                val mutualTiers = preferredTiers.filter { tierMutuallySupported(it) }
                val detail = if (mutualTiers.isEmpty()) {
                    "no common suite for effective policy(minimum=${effectiveMinimumTier.name}, " +
                        "requirePqc=$effectiveRequirePqc, allowClassicFallback=$effectiveAllowClassicFallback)"
                } else {
                    "no policy-permitted suite in intersection ${mutualTiers.map { it.name }} " +
                        "for effective policy(minimum=${effectiveMinimumTier.name}, " +
                        "requirePqc=$effectiveRequirePqc, allowClassicFallback=$effectiveAllowClassicFallback)"
                }
                // Terminate the handshake, classified as "no common suite" (R4.3/R4.4).
                throw HandshakeNegotiationException(HandshakeFailure.SuiteIntersectionEmpty(detail))
            }
        }

        val suite = when (selectedTier) {
            SuiteTier.Q_PERIAPT -> P2PCryptoSuite.Q_PERIAPT_CONTEXT_BOUND
            SuiteTier.X_WING -> P2PCryptoSuite.X_WING
            SuiteTier.PQC -> P2PCryptoSuite.MLKEM_768
            SuiteTier.CLASSIC -> P2PCryptoSuite.X25519
        }

        require(P2PCryptoSuite.isNegotiable(suite)) {
            "No compatible suite in MessageA (known=${messageA.supportedSuites.map { it.wireId }}, unknown=${messageA.unknownSupportedSuiteWireIds})"
        }
        return suite
    }

    private enum class SuiteTier {
        Q_PERIAPT,
        X_WING,
        PQC,
        CLASSIC;

        val rank: Int
            get() = when (this) {
                CLASSIC -> 0
                PQC -> 1
                X_WING -> 2
                Q_PERIAPT -> 3
            }
    }

    private fun parseMinimumTier(raw: String): SuiteTier = when (raw.trim()) {
        P2PQPeriaptKem.MINIMUM_TIER_RAW, "q-periapt", "qperiapt" -> SuiteTier.Q_PERIAPT
        "nativePQC", "x-wing", "xwing", "strictXWing" -> SuiteTier.X_WING
        "liboqsPQC", "pqc", "mlkem", "ml-kem" -> SuiteTier.PQC
        "classic" -> SuiteTier.CLASSIC
        else -> throw IllegalArgumentException("Unsupported handshake minimum tier: $raw")
    }

    private fun normalizePolicy(policy: P2PHandshakePolicy): P2PHandshakePolicy {
        val normalizedTier = when (parseMinimumTier(policy.minimumTierRaw)) {
            SuiteTier.Q_PERIAPT -> P2PQPeriaptKem.MINIMUM_TIER_RAW
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
            P2PCryptoSuite.Q_PERIAPT_CONTEXT_BOUND,
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

private fun defaultPlatformVersion(): String =
    QPeriaptPlatformPolicy.androidHandshakePlatformVersion(
        release = android.os.Build.VERSION.RELEASE,
        sdkInt = android.os.Build.VERSION.SDK_INT
    )
