package com.skybridge.compass.shared.p2p

import com.skybridge.compass.shared.crypto.providers.AndroidPQCCryptoProvider
import java.security.KeyPair
import java.security.PrivateKey
import java.security.SecureRandom

/**
 * Minimal initiator-side P2P v1 handshake compatible with SkyBridge Compass Pro release:
 * - Builds MessageA with version-tier suite policy (X-Wing/PQC/classic).
 * - Parses + verifies MessageB signature.
 * - Opens MessageB encryptedPayload via Pro v1 handshake payload KDF/AES-GCM.
 * - Derives session send/receive keys using Pro release KDF (transcriptA/B + nonces).
 *
 * This is a protocol core. Transport integration (TCP/QUIC/WebRTC) is left to caller.
 */
class P2PHandshakeClient(
    private val platformVersion: String,
    private val providerTypeRaw: String = "CryptoKit-Classic", // compatible string; used only for capability decode on peer
    private val secureRandom: SecureRandom = SecureRandom()
) {
    data class PeerKemPublicKeys(
        val qPeriaptPublicKey: ByteArray? = null,
        val xWingPublicKey: ByteArray? = null,
        val mlKem768PublicKey: ByteArray? = null
    )

    data class StartOptions(
        val peerIdForFallbackCooldown: String? = null,
        val fallbackCooldownStore: P2PHandshakeWire.FallbackCooldownStore? = null,
        val peerKemPublicKeys: PeerKemPublicKeys = PeerKemPublicKeys(),
        val messageAExtensionsRaw: ByteArray = ByteArray(0),
        val handshakePolicy: P2PHandshakePolicy = P2PHandshakePolicy.DEFAULT,
        val allowClassicBootstrapForTrustedPeer: Boolean = false,
        /**
         * Optional stable identity signing keys. When present, the handshake uses these keys
         * instead of generating fresh identity keys, so TOFU pinning remains stable across
         * reconnects.
         */
        val protocolSigningKeys: P2PProtocolSigningKeys? = null,
        /**
         * Optional structured downgrade-audit sink. When a classic fallback is taken, the
         * handshake routes the decision through the canonical [PolicyGate] taxonomy
         * (mirrors `rust/crates/skybridge-core/src/policy.rs`) and emits a structured,
         * replayable [DowngradeEvent] here. Leaving this null preserves the legacy
         * bare-boolean behavior, so existing callers are unaffected.
         */
        val downgradeAuditSink: ((DowngradeEvent) -> Unit)? = null
    )

    data class InitiatorState(
        val identityPrivateKey: PrivateKey?,
        val identityPrivateKeyRaw: ByteArray?,
        val identityAlgorithm: P2PIdentityPublicKeys.ProtocolAlgorithm,
        val identityPublicRaw32: ByteArray,
        val x25519KeyPair: KeyPair?,
        val clientNonce32: ByteArray,
        val messageAWithoutPadding: ByteArray,
        val offeredSuites: List<P2PCryptoSuite>,
        val handshakePolicy: P2PHandshakePolicy,
        val allowClassicBootstrapForTrustedPeer: Boolean = false,
        val pqcSharedSecret32: ByteArray? = null,
        /**
         * The structured downgrade-audit record emitted when this handshake took a
         * classic fallback under a fallback-eligible reason; null when no auditable
         * downgrade occurred. Mirrors the canonical [DowngradeEvent].
         */
        val downgradeEvent: DowngradeEvent? = null
    )

    data class Result(
        val sessionKeys: P2PHandshakeWire.DerivedSessionKeys,
        val negotiatedSuite: P2PCryptoSuite,
        val clientFinishedToSend: ByteArray,
        /** Fingerprint whose MessageB signature and configured pin were verified for this result. */
        val remoteProtocolIdentityFingerprint: String
    )

    fun start(): Pair<InitiatorState, ByteArray> {
        return start(StartOptions())
    }

    fun start(options: StartOptions): Pair<InitiatorState, ByteArray> {
        val clientNonce = ByteArray(32).also { secureRandom.nextBytes(it) }
        val normalizedPolicy = normalizePolicy(
            policy = options.handshakePolicy,
            platformVersion = platformVersion
        )
        val runtimeSupport = RuntimeSupport(
            liboqsAvailable = AndroidPQCCryptoProvider.isAvailable(),
            qPeriaptAvailable = P2PQPeriaptKem.isAvailable(),
            xWingAvailable = P2PXWingKem.isAvailable()
        )
        val plan = resolveSuitePlan(
            platformVersion = platformVersion,
            runtimeSupport = runtimeSupport,
            peerKemPublicKeys = options.peerKemPublicKeys,
            policy = normalizedPolicy,
            allowClassicBootstrapForTrustedPeer = options.allowClassicBootstrapForTrustedPeer
        )

        var downgradeEvent: DowngradeEvent? = null
        if (plan.usedClassicFallback) {
            require(
                options.peerIdForFallbackCooldown == null || options.fallbackCooldownStore != null
            ) {
                "fallbackCooldownStore is required when peerIdForFallbackCooldown is provided"
            }
            if (options.peerIdForFallbackCooldown != null && options.fallbackCooldownStore != null) {
                if (options.allowClassicBootstrapForTrustedPeer) {
                    // Bootstrap-assisted: a one-time classic CONTROL channel for paired
                    // KEM-key recovery is permitted even under a strict posture (mirrors
                    // policy.rs `allowsBootstrapControlChannel`). This is NOT a business
                    // downgrade, so it bypasses the business-fallback policy gate but
                    // still consumes the per-peer 300 s cooldown via the shared store.
                    val decision = P2PHandshakeWire.evaluateClassicFallbackCooldown(
                        peerId = options.peerIdForFallbackCooldown,
                        fallbackCooldownStore = options.fallbackCooldownStore
                    )
                    require(decision.allowed) {
                        "Classic fallback cooldown active for peer=${options.peerIdForFallbackCooldown}; retry in ${decision.remainingMillis} ms"
                    }
                    P2PHandshakeWire.recordClassicFallback(
                        peerId = options.peerIdForFallbackCooldown,
                        fallbackCooldownStore = options.fallbackCooldownStore
                    )
                } else {
                    // Route the downgrade through the canonical PolicyGate taxonomy
                    // (mirrors rust/crates/skybridge-core/src/policy.rs). The gate reuses
                    // the same FallbackCooldownStore so the 300 s/peer cooldown has a
                    // single source of truth, and it both enforces the cooldown and mints
                    // a structured, replayable DowngradeEvent on authorization.
                    val gate = PolicyGate(
                        policy = DowngradePolicy.fromHandshakePolicy(normalizedPolicy),
                        cooldownStore = options.fallbackCooldownStore
                    )
                    // This call site is reached only because a preferred PQC/X-Wing tier
                    // was unavailable for this peer (no usable PQC suite), which is the
                    // fallback-eligible SUITE_NEGOTIATION_FAILED reason. Timeouts and auth
                    // failures never reach here and are structurally ineligible.
                    val decision = gate.authorizeDowngrade(
                        peer = options.peerIdForFallbackCooldown,
                        fromSuite = preferredPqcSuiteFor(platformVersion),
                        toSuite = plan.selectedSuite,
                        reason = FallbackReason.SUITE_NEGOTIATION_FAILED,
                        transcriptAnchor = clientNonce
                    )
                    when (decision) {
                        is DowngradeDecision.Allowed -> {
                            downgradeEvent = decision.event
                            options.downgradeAuditSink?.invoke(decision.event)
                        }
                        is DowngradeDecision.DeniedRateLimited ->
                            throw IllegalStateException(
                                "Classic fallback cooldown active for peer=${options.peerIdForFallbackCooldown}; retry in ${decision.remainingMillis} ms"
                            )
                        is DowngradeDecision.DeniedByPolicy ->
                            throw IllegalStateException(
                                "Classic fallback denied by policy posture ${gate.policy} for peer=${options.peerIdForFallbackCooldown}"
                            )
                        is DowngradeDecision.DeniedReasonIneligible ->
                            throw IllegalStateException(
                                "Classic fallback reason ${decision.reason.diagnosticCode} is not fallback-eligible"
                            )
                        // Not reachable from this call site (it uses authorizeDowngrade,
                        // not the user-approved gate), but the taxonomy is exhaustive.
                        DowngradeDecision.DeniedUserNotAuthorized ->
                            throw IllegalStateException(
                                "Classic fallback denied: user did not authorize downgrade for peer=${options.peerIdForFallbackCooldown}"
                            )
                    }
                }
            }
        }

        val caps = P2PCryptoCapabilities(
            supportedKEM = plan.supportedKem,
            supportedSignature = plan.supportedSignatures,
            supportedAuthProfiles = plan.supportedAuthProfiles,
            supportedAEAD = listOf("aes256GCM", "chaCha20Poly1305"),
            pqcAvailable = plan.selectedSuite.isPqc,
            platformVersion = platformVersion,
            providerTypeRaw = plan.providerTypeRaw
        )
        val policy = normalizedPolicy.copy(minimumTierRaw = plan.minimumTierRaw)

        val startMaterial = when (plan.selectedSuite) {
            P2PCryptoSuite.Q_PERIAPT_CONTEXT_BOUND -> buildQPeriaptStartMaterial(
                clientNonce = clientNonce,
                capabilities = caps,
                policy = policy,
                peerQPeriaptPublicKey = requireNotNull(options.peerKemPublicKeys.qPeriaptPublicKey) {
                    "Q-Periapt selected but peer Q-Periapt public key is missing"
                },
                protocolSigningKeys = options.protocolSigningKeys,
                messageAExtensionsRaw = options.messageAExtensionsRaw
            )
            P2PCryptoSuite.X25519 -> buildClassicStartMaterial(
                clientNonce = clientNonce,
                capabilities = caps,
                policy = policy,
                protocolSigningKeys = options.protocolSigningKeys,
                messageAExtensionsRaw = options.messageAExtensionsRaw
            )
            P2PCryptoSuite.MLKEM_768 -> buildMlKemStartMaterial(
                clientNonce = clientNonce,
                capabilities = caps,
                policy = policy,
                peerMlKemPublicKey = requireNotNull(options.peerKemPublicKeys.mlKem768PublicKey) {
                    "ML-KEM-768 selected but peer ML-KEM public key is missing"
                },
                protocolSigningKeys = options.protocolSigningKeys,
                messageAExtensionsRaw = options.messageAExtensionsRaw
            )
            P2PCryptoSuite.X_WING -> buildXWingStartMaterial(
                clientNonce = clientNonce,
                capabilities = caps,
                policy = policy,
                peerXWingPublicKey = requireNotNull(options.peerKemPublicKeys.xWingPublicKey) {
                    "X-Wing selected but peer X-Wing public key is missing"
                },
                protocolSigningKeys = options.protocolSigningKeys,
                messageAExtensionsRaw = options.messageAExtensionsRaw
            )
            P2PCryptoSuite.MLKEM_768_FS_COMPAT ->
                error("0x0102 is compatibility parse-only and not negotiable")
            P2PCryptoSuite.P256 -> error("P256 suite is not supported by this client")
        }

        val state = InitiatorState(
            identityPrivateKey = startMaterial.identityPrivateKey,
            identityPrivateKeyRaw = startMaterial.identityPrivateKeyRaw,
            identityAlgorithm = startMaterial.identityAlgorithm,
            identityPublicRaw32 = startMaterial.identityPublicRaw32,
            x25519KeyPair = startMaterial.x25519KeyPair,
            clientNonce32 = clientNonce,
            messageAWithoutPadding = HandshakePaddingP1.unwrapIfNeeded(startMaterial.messageA),
            offeredSuites = listOf(plan.selectedSuite),
            handshakePolicy = policy,
            allowClassicBootstrapForTrustedPeer = options.allowClassicBootstrapForTrustedPeer,
            pqcSharedSecret32 = startMaterial.pqcSharedSecret32,
            downgradeEvent = downgradeEvent
        )

        // Pro release may wrap with SBP1; we always wrap for compatibility.
        return state to HandshakePaddingP1.wrap(startMaterial.messageA)
    }

    fun finish(state: InitiatorState, rawMessageB: ByteArray): Result {
        return finish(
            state = state,
            rawMessageB = rawMessageB,
            peerIdForTrust = null,
            trustStore = null,
            allowTrustOnFirstUse = false
        )
    }

    fun finish(
        state: InitiatorState,
        rawMessageB: ByteArray,
        peerIdForTrust: String?,
        trustStore: P2PHandshakeWire.TrustStore?,
        allowTrustOnFirstUse: Boolean = false
    ): Result {
        val msgB = P2PHandshakeWire.decodeMessageB(rawMessageB)

        val transcriptA = P2PHandshakeWire.transcriptHashAFromWire(state.messageAWithoutPadding)
        val transcriptB = P2PHandshakeWire.transcriptHashBFromWire(rawMessageB)

        // Verify MessageB signature (Pro release binds transcriptA + payloadHash)
        val okSigB = P2PHandshakeWire.verifyMessageBSignature(
            messageB = msgB,
            transcriptHashA32 = transcriptA,
            rawMessageBWithoutPadding = rawMessageB
        )
        require(okSigB) { "MessageB signature verification failed" }

        val negotiatedSuite = (msgB.selectedSuite as? P2PCryptoSuiteId.Known)?.suite
            ?: throw IllegalArgumentException("Unknown suite ${msgB.selectedSuite.wireId}")
        require(state.offeredSuites.any { it.wireId == msgB.selectedSuite.wireId }) {
            "MessageB selected a suite that was not offered by this initiator attempt"
        }
        enforcePolicyForNegotiatedSuite(
            policy = state.handshakePolicy,
            negotiatedSuite = negotiatedSuite,
            allowClassicBootstrapForTrustedPeer = state.allowClassicBootstrapForTrustedPeer
        )
        enforceIdentityAlgorithmBinding(
            suite = negotiatedSuite,
            algorithm = msgB.identityPublicKeys.protocolAlgorithm
        )
        if (peerIdForTrust != null && trustStore != null) {
            P2PHandshakeWire.verifyOrPersistPeerTrust(
                peerId = peerIdForTrust,
                identityPublicKeys = msgB.identityPublicKeys,
                trustStore = trustStore,
                allowTrustOnFirstUse = allowTrustOnFirstUse
            )
        } else {
            require(peerIdForTrust == null && trustStore == null) {
                "peerIdForTrust and trustStore must be provided together"
            }
        }

        val (payload, sharedSecret32) = when (negotiatedSuite) {
            P2PCryptoSuite.X25519 -> {
                val x25519KeyPair = requireNotNull(state.x25519KeyPair) {
                    "Missing classic keypair for X25519 suite"
                }
                require(msgB.responderShare.contentEquals(msgB.encryptedPayload.encapsulatedKey)) {
                    "Responder share mismatch"
                }
                val receiverPubRaw32 = P2PClassicHpkeX25519.rawPublicKey32(x25519KeyPair.public)
                val opened = P2PClassicHpkeX25519.openAndExport(
                    sealedBox = msgB.encryptedPayload,
                    receiverPrivateKey = x25519KeyPair.private,
                    receiverPublicKeyRaw32 = receiverPubRaw32,
                    info = "handshake-payload".toByteArray(Charsets.UTF_8),
                    suiteWireId = negotiatedSuite.wireId
                )
                opened.plaintext to opened.exportedSecret32
            }
            P2PCryptoSuite.MLKEM_768,
            P2PCryptoSuite.MLKEM_768_FS_COMPAT,
            P2PCryptoSuite.Q_PERIAPT_CONTEXT_BOUND,
            P2PCryptoSuite.X_WING -> {
                val ss = state.pqcSharedSecret32
                    ?: error("Missing precomputed PQC shared secret for negotiated suite")
                val pt = P2PHandshakeWire.openHandshakePayload(
                    sharedSecret32 = ss,
                    transcriptHashA32 = transcriptA,
                    sealedBox = msgB.encryptedPayload
                )
                pt to ss
            }
            P2PCryptoSuite.P256 -> error("P256 suite is not supported by this client")
        }
        // Validate deterministic payload shape for compatibility. Do not treat a malformed payload
        // as an empty/unknown peer state; it is part of the signed handshake transcript.
        val responderCapabilities = P2PCryptoCapabilities.deterministicDecode(payload)
        if (negotiatedSuite == P2PCryptoSuite.Q_PERIAPT_CONTEXT_BOUND) {
            QPeriaptPlatformPolicy.requireHandshakePeerEligible(
                capabilities = responderCapabilities,
                peerRole = "responder"
            )
        }

        val keys = P2PHandshakeWire.deriveSessionKeys(
            roleIsInitiator = true,
            suite = negotiatedSuite,
            transcriptA = transcriptA,
            transcriptB = transcriptB,
            clientNonce = state.clientNonce32,
            serverNonce = msgB.serverNonce,
            sharedSecret32 = sharedSecret32
        )

        val clientFinished = P2PHandshakeWire.buildFinishedToSend(
            direction = P2PHandshakeWire.FinishedDirection.INITIATOR_TO_RESPONDER,
            sessionKeys = keys
        )
        return Result(
            sessionKeys = keys,
            negotiatedSuite = negotiatedSuite,
            clientFinishedToSend = HandshakePaddingP1.wrap(clientFinished),
            remoteProtocolIdentityFingerprint =
                P2PHandshakeWire.computePeerSigningFingerprint(msgB.identityPublicKeys)
        )
    }

    fun verifyResponderFinished(rawFinished: ByteArray, sessionKeys: P2PHandshakeWire.DerivedSessionKeys): Boolean {
        val finished = P2PHandshakeWire.decodeFinished(rawFinished)
        return P2PHandshakeWire.verifyFinished(
            finished = finished,
            sessionKeys = sessionKeys,
            expectingFrom = P2PHandshakeWire.FinishedDirection.RESPONDER_TO_INITIATOR
        )
    }

    private data class StartMaterial(
        val messageA: ByteArray,
        val identityPrivateKey: PrivateKey?,
        val identityPrivateKeyRaw: ByteArray?,
        val identityAlgorithm: P2PIdentityPublicKeys.ProtocolAlgorithm,
        val identityPublicRaw32: ByteArray,
        val x25519KeyPair: KeyPair?,
        val pqcSharedSecret32: ByteArray?
    )

    private fun buildClassicStartMaterial(
        clientNonce: ByteArray,
        capabilities: P2PCryptoCapabilities,
        policy: P2PHandshakePolicy,
        protocolSigningKeys: P2PProtocolSigningKeys?,
        messageAExtensionsRaw: ByteArray
    ): StartMaterial {
        val (idPriv, idPubRaw32) = if (protocolSigningKeys != null) {
            val pub = protocolSigningKeys.ed25519PublicKeyRaw32
            require(pub.size == 32) { "Invalid Ed25519 public key length: ${pub.size}" }
            protocolSigningKeys.ed25519PrivateKey to pub
        } else {
            P2PHandshakeWire.generateEd25519IdentityKeyPair()
        }
        val xk = P2PClassicHpkeX25519.generateX25519KeyPair()
        val xPubRaw32 = P2PClassicHpkeX25519.rawPublicKey32(xk.public)
        val offeredSuites = listOf(P2PCryptoSuite.X25519)
        val identityKeys = P2PIdentityPublicKeys.Keys(
            protocolPublicKey = idPubRaw32,
            protocolAlgorithm = P2PIdentityPublicKeys.ProtocolAlgorithm.ED25519,
            secureEnclavePublicKey = null
        )
        val msgA = P2PHandshakeWire.encodeMessageA(
            supportedSuites = offeredSuites,
            keyShares = listOf(P2PHandshakeWire.KeyShare(P2PCryptoSuite.X25519, xPubRaw32)),
            clientNonce32 = clientNonce,
            capabilities = capabilities,
            policy = policy,
            identityKeys = identityKeys,
            identitySigningPrivateKey = idPriv,
            extensionsRaw = messageAExtensionsRaw
        )
        return StartMaterial(
            messageA = msgA,
            identityPrivateKey = idPriv,
            identityPrivateKeyRaw = null,
            identityAlgorithm = P2PIdentityPublicKeys.ProtocolAlgorithm.ED25519,
            identityPublicRaw32 = idPubRaw32,
            x25519KeyPair = xk,
            pqcSharedSecret32 = null
        )
    }

    private fun buildMlKemStartMaterial(
        clientNonce: ByteArray,
        capabilities: P2PCryptoCapabilities,
        policy: P2PHandshakePolicy,
        peerMlKemPublicKey: ByteArray,
        protocolSigningKeys: P2PProtocolSigningKeys?,
        messageAExtensionsRaw: ByteArray
    ): StartMaterial {
        require(peerMlKemPublicKey.size == AndroidPQCCryptoProvider.MLKEM768_PUBLIC_KEY_SIZE) {
            "Invalid peer ML-KEM public key length: ${peerMlKemPublicKey.size}"
        }

        val pqcProvider = AndroidPQCCryptoProvider()
        val (encapsulatedCiphertext, sharedSecret) = pqcProvider.encapsulate(peerMlKemPublicKey)
        val (idPrivRaw, idPubRaw) = if (protocolSigningKeys?.mlDsa65PrivateKeyRaw != null &&
            protocolSigningKeys.mlDsa65PublicKeyRaw != null
        ) {
            protocolSigningKeys.mlDsa65PrivateKeyRaw to protocolSigningKeys.mlDsa65PublicKeyRaw
        } else {
            P2PHandshakeWire.generateMlDsa65IdentityKeyPair()
        }
        val identityKeys = P2PIdentityPublicKeys.Keys(
            protocolPublicKey = idPubRaw,
            protocolAlgorithm = P2PIdentityPublicKeys.ProtocolAlgorithm.ML_DSA_65,
            secureEnclavePublicKey = null
        )
        val msgA = P2PHandshakeWire.encodeMessageAWithRawSigningKey(
            supportedSuites = listOf(P2PCryptoSuite.MLKEM_768),
            keyShares = listOf(
                P2PHandshakeWire.KeyShare(P2PCryptoSuite.MLKEM_768, encapsulatedCiphertext)
            ),
            clientNonce32 = clientNonce,
            capabilities = capabilities,
            policy = policy,
            identityKeys = identityKeys,
            identitySigningPrivateKeyRaw = idPrivRaw,
            extensionsRaw = messageAExtensionsRaw
        )
        return StartMaterial(
            messageA = msgA,
            identityPrivateKey = null,
            identityPrivateKeyRaw = idPrivRaw,
            identityAlgorithm = P2PIdentityPublicKeys.ProtocolAlgorithm.ML_DSA_65,
            identityPublicRaw32 = idPubRaw,
            x25519KeyPair = null,
            pqcSharedSecret32 = sharedSecret
        )
    }

    private fun buildXWingStartMaterial(
        clientNonce: ByteArray,
        capabilities: P2PCryptoCapabilities,
        policy: P2PHandshakePolicy,
        peerXWingPublicKey: ByteArray,
        protocolSigningKeys: P2PProtocolSigningKeys?,
        messageAExtensionsRaw: ByteArray
    ): StartMaterial {
        require(peerXWingPublicKey.size == P2PXWingKem.XWING_PUBLIC_KEY_SIZE) {
            "Invalid peer X-Wing public key length: ${peerXWingPublicKey.size}"
        }

        val pqcProvider = AndroidPQCCryptoProvider()
        val encap = P2PXWingKem.encapsulate(recipientPublicKey = peerXWingPublicKey, pqcProvider = pqcProvider)
        val (idPrivRaw, idPubRaw) = if (protocolSigningKeys?.mlDsa65PrivateKeyRaw != null &&
            protocolSigningKeys.mlDsa65PublicKeyRaw != null
        ) {
            protocolSigningKeys.mlDsa65PrivateKeyRaw to protocolSigningKeys.mlDsa65PublicKeyRaw
        } else {
            P2PHandshakeWire.generateMlDsa65IdentityKeyPair()
        }
        val identityKeys = P2PIdentityPublicKeys.Keys(
            protocolPublicKey = idPubRaw,
            protocolAlgorithm = P2PIdentityPublicKeys.ProtocolAlgorithm.ML_DSA_65,
            secureEnclavePublicKey = null
        )
        val msgA = P2PHandshakeWire.encodeMessageAWithRawSigningKey(
            supportedSuites = listOf(P2PCryptoSuite.X_WING),
            keyShares = listOf(
                P2PHandshakeWire.KeyShare(P2PCryptoSuite.X_WING, encap.ciphertext)
            ),
            clientNonce32 = clientNonce,
            capabilities = capabilities,
            policy = policy,
            identityKeys = identityKeys,
            identitySigningPrivateKeyRaw = idPrivRaw,
            extensionsRaw = messageAExtensionsRaw
        )
        return StartMaterial(
            messageA = msgA,
            identityPrivateKey = null,
            identityPrivateKeyRaw = idPrivRaw,
            identityAlgorithm = P2PIdentityPublicKeys.ProtocolAlgorithm.ML_DSA_65,
            identityPublicRaw32 = idPubRaw,
            x25519KeyPair = null,
            pqcSharedSecret32 = encap.sharedSecret32
        )
    }

    private fun buildQPeriaptStartMaterial(
        clientNonce: ByteArray,
        capabilities: P2PCryptoCapabilities,
        policy: P2PHandshakePolicy,
        peerQPeriaptPublicKey: ByteArray,
        protocolSigningKeys: P2PProtocolSigningKeys?,
        messageAExtensionsRaw: ByteArray
    ): StartMaterial {
        require(peerQPeriaptPublicKey.size == P2PQPeriaptKem.QPERIAPT_PUBLIC_KEY_SIZE) {
            "Invalid peer Q-Periapt public key length: ${peerQPeriaptPublicKey.size}"
        }

        val pqcProvider = AndroidPQCCryptoProvider()
        val encap = P2PQPeriaptKem.encapsulate(
            recipientPublicKey = peerQPeriaptPublicKey,
            pqcProvider = pqcProvider
        )
        val (idPrivRaw, idPubRaw) = if (protocolSigningKeys?.mlDsa65PrivateKeyRaw != null &&
            protocolSigningKeys.mlDsa65PublicKeyRaw != null
        ) {
            protocolSigningKeys.mlDsa65PrivateKeyRaw to protocolSigningKeys.mlDsa65PublicKeyRaw
        } else {
            P2PHandshakeWire.generateMlDsa65IdentityKeyPair()
        }
        val identityKeys = P2PIdentityPublicKeys.Keys(
            protocolPublicKey = idPubRaw,
            protocolAlgorithm = P2PIdentityPublicKeys.ProtocolAlgorithm.ML_DSA_65,
            secureEnclavePublicKey = null
        )
        val msgA = P2PHandshakeWire.encodeMessageAWithRawSigningKey(
            supportedSuites = listOf(P2PCryptoSuite.Q_PERIAPT_CONTEXT_BOUND),
            keyShares = listOf(
                P2PHandshakeWire.KeyShare(P2PCryptoSuite.Q_PERIAPT_CONTEXT_BOUND, encap.ciphertext)
            ),
            clientNonce32 = clientNonce,
            capabilities = capabilities,
            policy = policy,
            identityKeys = identityKeys,
            identitySigningPrivateKeyRaw = idPrivRaw,
            extensionsRaw = messageAExtensionsRaw
        )
        return StartMaterial(
            messageA = msgA,
            identityPrivateKey = null,
            identityPrivateKeyRaw = idPrivRaw,
            identityAlgorithm = P2PIdentityPublicKeys.ProtocolAlgorithm.ML_DSA_65,
            identityPublicRaw32 = idPubRaw,
            x25519KeyPair = null,
            pqcSharedSecret32 = encap.sharedSecret32
        )
    }

    private data class RuntimeSupport(
        val liboqsAvailable: Boolean,
        val qPeriaptAvailable: Boolean,
        val xWingAvailable: Boolean
    )

    internal data class ResolvedSuitePlan(
        val selectedSuite: P2PCryptoSuite,
        val usedClassicFallback: Boolean,
        val minimumTierRaw: String,
        val supportedKem: List<String>,
        val supportedSignatures: List<String>,
        val supportedAuthProfiles: List<String>,
        val providerTypeRaw: String
    )

    private fun resolveSuitePlan(
        platformVersion: String,
        runtimeSupport: RuntimeSupport,
        peerKemPublicKeys: PeerKemPublicKeys,
        policy: P2PHandshakePolicy,
        allowClassicBootstrapForTrustedPeer: Boolean
    ): ResolvedSuitePlan {
        val requestedMinimumTier = parseMinimumTier(policy.minimumTierRaw)
        val qPeriaptExplicit = requestedMinimumTier == SuiteTier.Q_PERIAPT
        if (qPeriaptExplicit) {
            QPeriaptPlatformPolicy.requireLocalAndroidSupported(platformVersion)
        }
        val peerSupportsMlKemOnly =
            peerKemPublicKeys.mlKem768PublicKey != null && peerKemPublicKeys.xWingPublicKey == null
        val minimumTier = when {
            requestedMinimumTier == SuiteTier.X_WING &&
                runtimeSupport.liboqsAvailable &&
                (!runtimeSupport.xWingAvailable || peerSupportsMlKemOnly) -> SuiteTier.PQC
            else -> requestedMinimumTier
        }
        val preferredTiers =
            if (qPeriaptExplicit) {
                listOf(SuiteTier.Q_PERIAPT)
            } else {
                listOf(SuiteTier.X_WING, SuiteTier.PQC, SuiteTier.CLASSIC)
            }

        if (allowClassicBootstrapForTrustedPeer && !qPeriaptExplicit) {
            return ResolvedSuitePlan(
                selectedSuite = P2PCryptoSuite.X25519,
                usedClassicFallback = preferredTiers.any { it != SuiteTier.CLASSIC },
                minimumTierRaw = "classic",
                supportedKem = listOf("x25519"),
                supportedSignatures = listOf("ed25519"),
                supportedAuthProfiles = listOf("classic"),
                providerTypeRaw = P2PHandshakeWire.PROVIDER_TYPE_CRYPTO_KIT_CLASSIC
            )
        }

        // Suite negotiation is an explicit set intersection followed by a
        // priority-ordered selection within that intersection (R4.3).
        //
        // A tier is in the mutually-supported set iff the local runtime supports it
        // AND the peer declared the corresponding KEM public key. CLASSIC is always
        // mutually supported (both sides always speak x25519).
        fun tierMutuallySupported(tier: SuiteTier): Boolean = when (tier) {
            SuiteTier.Q_PERIAPT ->
                runtimeSupport.qPeriaptAvailable && peerKemPublicKeys.qPeriaptPublicKey != null
            SuiteTier.X_WING ->
                runtimeSupport.xWingAvailable && peerKemPublicKeys.xWingPublicKey != null
            SuiteTier.PQC ->
                runtimeSupport.liboqsAvailable && peerKemPublicKeys.mlKem768PublicKey != null
            SuiteTier.CLASSIC -> true
        }

        val mutuallySupportedTiers = preferredTiers.filter { tierMutuallySupported(it) }

        // Empty intersection → classify as "no common suite" and terminate (R4.3/R4.4).
        // Note: when !qPeriaptExplicit, CLASSIC is always in preferredTiers and always
        // mutually supported, so an empty intersection here implies a qPeriaptExplicit
        // request whose sole tier (Q_PERIAPT) did not intersect.
        if (mutuallySupportedTiers.isEmpty()) {
            throw HandshakeNegotiationException(
                HandshakeFailure.SuiteIntersectionEmpty(
                    "no common suite for policy(minimum=${policy.minimumTierRaw}, " +
                        "requirePqc=${policy.requirePqc}, allowClassicFallback=${policy.allowClassicFallback})"
                )
            )
        }

        // Select the highest-priority tier within the intersection that policy permits.
        val selectedTier = mutuallySupportedTiers.firstOrNull { tier ->
            when (tier) {
                SuiteTier.CLASSIC ->
                    (allowClassicBootstrapForTrustedPeer && !qPeriaptExplicit) ||
                        (!policy.requirePqc &&
                            policy.allowClassicFallback &&
                            tier.rank >= minimumTier.rank)
                else -> tier.rank >= minimumTier.rank
            }
        }

        val resolvedTier = selectedTier ?: run {
            if (allowClassicBootstrapForTrustedPeer && !qPeriaptExplicit) {
                SuiteTier.CLASSIC
            } else {
                // The intersection is non-empty but no member survives the policy
                // constraints (min-tier / requirePqc / allowClassicFallback). Per R4.3
                // this terminates the handshake as "no common suite".
                throw HandshakeNegotiationException(
                    HandshakeFailure.SuiteIntersectionEmpty(
                        "no policy-permitted suite in intersection " +
                            "${mutuallySupportedTiers.map { it.name }} for policy(" +
                            "minimum=${policy.minimumTierRaw}, requirePqc=${policy.requirePqc}, " +
                            "allowClassicFallback=${policy.allowClassicFallback})"
                    )
                )
            }
        }

        val usedClassicFallback =
            resolvedTier == SuiteTier.CLASSIC && preferredTiers.any { it != SuiteTier.CLASSIC }

        return when (resolvedTier) {
            SuiteTier.Q_PERIAPT -> ResolvedSuitePlan(
                selectedSuite = P2PCryptoSuite.Q_PERIAPT_CONTEXT_BOUND,
                usedClassicFallback = usedClassicFallback,
                minimumTierRaw = P2PQPeriaptKem.MINIMUM_TIER_RAW,
                supportedKem = listOf(P2PQPeriaptKem.KEM_CAPABILITY_NAME),
                supportedSignatures = listOf("ml-dsa-65"),
                supportedAuthProfiles = listOf(QPeriaptPlatformPolicy.AUTH_PROFILE),
                providerTypeRaw = P2PHandshakeWire.PROVIDER_TYPE_QPERIAPT
            )
            SuiteTier.X_WING -> ResolvedSuitePlan(
                selectedSuite = P2PCryptoSuite.X_WING,
                usedClassicFallback = usedClassicFallback,
                minimumTierRaw = "nativePQC",
                supportedKem = listOf("x-wing", "mlkem-768"),
                supportedSignatures = listOf("ml-dsa-65"),
                supportedAuthProfiles = listOf("hybrid", "pqc"),
                providerTypeRaw = P2PHandshakeWire.PROVIDER_TYPE_CRYPTO_KIT_PQC
            )
            SuiteTier.PQC -> ResolvedSuitePlan(
                selectedSuite = P2PCryptoSuite.MLKEM_768,
                usedClassicFallback = usedClassicFallback,
                minimumTierRaw = "liboqsPQC",
                supportedKem = listOf("mlkem-768"),
                supportedSignatures = listOf("ml-dsa-65"),
                supportedAuthProfiles = listOf("pqc"),
                providerTypeRaw = P2PHandshakeWire.PROVIDER_TYPE_LIBOQS
            )
            SuiteTier.CLASSIC -> ResolvedSuitePlan(
                selectedSuite = P2PCryptoSuite.X25519,
                usedClassicFallback = usedClassicFallback,
                minimumTierRaw = "classic",
                supportedKem = listOf("x25519"),
                supportedSignatures = listOf("ed25519"),
                supportedAuthProfiles = listOf("classic"),
                providerTypeRaw = providerTypeRaw
            )
        }
    }

    private fun parseMinimumTier(raw: String): SuiteTier = when (raw.trim()) {
        P2PQPeriaptKem.MINIMUM_TIER_RAW, "q-periapt", "qperiapt" -> SuiteTier.Q_PERIAPT
        "nativePQC", "x-wing", "xwing", "strictXWing" -> SuiteTier.X_WING
        "liboqsPQC", "pqc", "mlkem", "ml-kem" -> SuiteTier.PQC
        "classic" -> SuiteTier.CLASSIC
        else -> throw IllegalArgumentException("Unsupported handshake minimum tier: $raw")
    }

    private fun normalizePolicy(policy: P2PHandshakePolicy, platformVersion: String): P2PHandshakePolicy {
        val platformMajor = parsePlatformMajorVersion(platformVersion)
        val defaultTier = when {
            platformMajor != null && platformMajor >= 16 -> "nativePQC"
            platformMajor != null && platformMajor >= 13 -> "liboqsPQC"
            else -> "classic"
        }
        val requested = policy.minimumTierRaw.trim()
        val normalizedTier = if (requested.isBlank()) {
            defaultTier
        } else when (parseMinimumTier(requested)) {
            SuiteTier.Q_PERIAPT -> P2PQPeriaptKem.MINIMUM_TIER_RAW
            SuiteTier.X_WING -> "nativePQC"
            SuiteTier.PQC -> "liboqsPQC"
            SuiteTier.CLASSIC -> "classic"
        }
        return policy.copy(minimumTierRaw = normalizedTier)
    }

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

    private fun enforcePolicyForNegotiatedSuite(
        policy: P2PHandshakePolicy,
        negotiatedSuite: P2PCryptoSuite,
        allowClassicBootstrapForTrustedPeer: Boolean
    ) {
        val negotiatedTier = when (negotiatedSuite) {
            P2PCryptoSuite.Q_PERIAPT_CONTEXT_BOUND -> SuiteTier.Q_PERIAPT
            P2PCryptoSuite.X_WING -> SuiteTier.X_WING
            P2PCryptoSuite.MLKEM_768 -> SuiteTier.PQC
            P2PCryptoSuite.X25519 -> SuiteTier.CLASSIC
            P2PCryptoSuite.MLKEM_768_FS_COMPAT,
            P2PCryptoSuite.P256 ->
                error("Unsupported negotiated suite: ${negotiatedSuite.name}")
        }
        val minimumTier = parseMinimumTier(policy.minimumTierRaw)
        val classicBootstrapAllowed =
            allowClassicBootstrapForTrustedPeer &&
                minimumTier != SuiteTier.Q_PERIAPT &&
                negotiatedTier == SuiteTier.CLASSIC
        require(negotiatedTier.rank >= minimumTier.rank || classicBootstrapAllowed) {
            "Negotiated suite ${negotiatedSuite.name} is below minimum tier ${policy.minimumTierRaw}"
        }
        if (negotiatedTier == SuiteTier.CLASSIC) {
            require(
                allowClassicBootstrapForTrustedPeer ||
                    (!policy.requirePqc && policy.allowClassicFallback)
            ) {
                "Classic fallback denied by policy(requirePqc=${policy.requirePqc}, allowClassicFallback=${policy.allowClassicFallback})"
            }
        }
    }

    private fun parsePlatformMajorVersion(value: String): Int? {
        val token = Regex("(\\d{1,2})").find(value)?.groupValues?.getOrNull(1) ?: return null
        return token.toIntOrNull()
    }

    /**
     * The PQC suite this Android 16+ platform would have preferred before falling back to
     * classic, recorded as the `from_suite` of a [DowngradeEvent].
     */
    private fun preferredPqcSuiteFor(platformVersion: String): P2PCryptoSuite {
        val major = parsePlatformMajorVersion(platformVersion)
        return if (major != null && major >= 16) P2PCryptoSuite.X_WING else P2PCryptoSuite.MLKEM_768
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

    companion object {
        internal fun resolveSuitePlanForTesting(
            platformVersion: String,
            liboqsAvailable: Boolean,
            xWingAvailable: Boolean,
            qPeriaptAvailable: Boolean = false,
            peerKemPublicKeys: PeerKemPublicKeys,
            policy: P2PHandshakePolicy = P2PHandshakePolicy.DEFAULT,
            allowClassicBootstrapForTrustedPeer: Boolean = false
        ): ResolvedSuitePlan {
            val client = P2PHandshakeClient(platformVersion = platformVersion)
            return client.resolveSuitePlan(
                platformVersion = platformVersion,
                runtimeSupport = RuntimeSupport(
                    liboqsAvailable = liboqsAvailable,
                    qPeriaptAvailable = qPeriaptAvailable,
                    xWingAvailable = xWingAvailable
                ),
                peerKemPublicKeys = peerKemPublicKeys,
                policy = policy,
                allowClassicBootstrapForTrustedPeer = allowClassicBootstrapForTrustedPeer
            )
        }
    }
}
