package com.skybridge.compass.core.p2p

import com.skybridge.compass.shared.p2p.HandshakePaddingP1
import com.skybridge.compass.shared.p2p.P2PHandshakeClient
import com.skybridge.compass.shared.p2p.P2PHandshakeServer
import com.skybridge.compass.shared.p2p.P2PHandshakeWire
import com.skybridge.compass.shared.p2p.P2PProtocolSigningKeys
import com.skybridge.compass.shared.p2p.P2PSoa
import com.skybridge.compass.shared.p2p.TrafficPaddingP2
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.Socket
import java.security.SecureRandom
import java.util.concurrent.atomic.AtomicBoolean

sealed class TcpControlEvent {
    data class HandshakeEstablished(
        val negotiatedSuiteWireId: Int,
        val peerId: String?
    ) : TcpControlEvent()

    data class AppMessageReceived(
        val peerId: String?,
        val message: AppMessage
    ) : TcpControlEvent()

    data class RemoteDesktopFrameReceived(
        val peerId: String?,
        val timestampNs: Long,
        val payload: ByteArray
    ) : TcpControlEvent()

    data class Failed(val peerId: String?, val error: String) : TcpControlEvent()
    data class Disconnected(val peerId: String?) : TcpControlEvent()
}

class TcpControlSession internal constructor(
    private val socket: Socket,
    private val localIdentity: LocalP2PIdentity,
    private val peerKemStore: PeerKemKeyStore,
    private val peerIdHint: String?,
    private val handshakePolicyOverride: P2PHandshakePolicyOverride? = null,
    private val role: Role
) {
    enum class Role { INITIATOR, RESPONDER }

    private val input: InputStream = BufferedInputStream(socket.getInputStream())
    private val output: OutputStream = BufferedOutputStream(socket.getOutputStream())

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val sendMutex = Mutex()

    private val _events = MutableSharedFlow<TcpControlEvent>(extraBufferCapacity = 32)
    val events: SharedFlow<TcpControlEvent> = _events

    private val codec = AppMessageCodec()
    private val secureRandom = SecureRandom()

    @Volatile private var sessionKeys: P2PHandshakeWire.DerivedSessionKeys? = null
    @Volatile private var negotiatedSuiteWireId: Int = 0
    @Volatile private var soaPairKey: ByteArray? = null

    private val running = AtomicBoolean(false)
    private val pairingExchangeSent = AtomicBoolean(false)

    private var readJob: Job? = null

    fun start() {
        if (!running.compareAndSet(false, true)) return
        readJob = scope.launch {
            try {
                when (role) {
                    Role.INITIATOR -> performHandshakeAsInitiator()
                    Role.RESPONDER -> performHandshakeAsResponder()
                }
                startReceiveLoop()
            } catch (t: Throwable) {
                _events.tryEmit(TcpControlEvent.Failed(peerIdHint, t.message ?: "tcp session failed"))
                close()
            }
        }
    }

    fun close() {
        running.set(false)
        runCatching { readJob?.cancel() }
        soaPairKey?.let { SoaPeerSessionArbiter.shared.clearEstablished(it) }
        soaPairKey = null
        runCatching { socket.close() }
        _events.tryEmit(TcpControlEvent.Disconnected(peerIdHint))
    }

    suspend fun sendAppMessage(message: AppMessage) {
        val keys = requireNotNull(sessionKeys) { "session not authenticated" }
        val plaintext = codec.encode(message)
        val ciphertext = AesGcmCombined.encrypt(keys.sendKey, plaintext)
        val framed = TrafficPaddingP2.wrapIfEnabled(ciphertext, label = "tx")
        sendMutex.withLock {
            LengthPrefixedFraming.writeFrame(output, framed)
        }
    }

    suspend fun sendRemoteDesktopFrame(timestampNs: Long, payload: ByteArray) {
        val keys = requireNotNull(sessionKeys) { "session not authenticated" }
        val env = BusinessEnvelope.remoteDesktopFrame(timestampNs = timestampNs, payload = payload).encode()
        val ciphertext = AesGcmCombined.encrypt(keys.sendKey, env)
        val framed = TrafficPaddingP2.wrapIfEnabled(ciphertext, label = "tx")
        sendMutex.withLock {
            LengthPrefixedFraming.writeFrame(output, framed)
        }
    }

    private suspend fun performHandshakeAsInitiator() {
        val peerId = peerIdHint
        val peerKem = if (peerId != null) peerKemStore.load(peerId) else PeerKemKeyStore.PeerKemPublicKeys()
        val policyOverride = effectivePolicyOverride()
        val peerKemPublicKeys = P2PHandshakeClient.PeerKemPublicKeys(
            xWingPublicKey = peerKem.xWingPublicKey,
            mlKem768PublicKey = peerKem.mlKem768PublicKey
        )
        val allowClassicBootstrap =
            peerId != null &&
                peerKemPublicKeys.isMissingPqcMaterial() &&
                localIdentity.trustStore().isPeerPinned(peerId)
        val effectiveHandshakePolicy = policyOverride.forTrustedClassicBootstrap(
            enabled = allowClassicBootstrap
        )
        val signKeys = localIdentity.getOrCreateProtocolSigningKeys()
        val protocolSigningKeys = P2PProtocolSigningKeys(
            ed25519PrivateKey = signKeys.ed25519PrivateKey,
            ed25519PublicKeyRaw32 = signKeys.ed25519PublicRaw32,
            mlDsa65PrivateKeyRaw = signKeys.mlDsa65PrivateKeyRaw,
            mlDsa65PublicKeyRaw = signKeys.mlDsa65PublicKeyRaw
        )

        val arbiter = SoaPeerSessionArbiter.shared
        val localDeviceId = localIdentity.deviceId()
        var outgoingPairKey: ByteArray? = null
        var outgoingAttemptId: ByteArray? = null
        var outgoingRegistered = false
        var soaExtensionsRaw = ByteArray(0)

        if (peerId != null && isUuidLike(peerId) && isUuidLike(localDeviceId)) {
            val localPeerId = P2PSoa.canonicalPeerIdBytes(localDeviceId)
            val remotePeerId = P2PSoa.canonicalPeerIdBytes(peerId)
            val pairKey = P2PSoa.pairKey(localPeerId, remotePeerId)
            val attemptId = ByteArray(P2PSoa.ATTEMPT_ID_LEN).also { secureRandom.nextBytes(it) }
            soaExtensionsRaw = P2PSoa.SoaExtension(
                version = P2PSoa.VERSION,
                initiatorPeerId = localPeerId,
                targetPeerId = remotePeerId,
                attemptId = attemptId
            ).encodeTlv()

            val decision = arbiter.registerOutgoing(
                SoaPeerSessionArbiter.OutgoingAttempt(
                    pairKey = pairKey,
                    initiatorPeerId = localPeerId,
                    attemptId = attemptId,
                    startedAtNs = System.nanoTime()
                ) { _, _ ->
                    runCatching { socket.close() }
                }
            )
            when (decision) {
                SoaPeerSessionArbiter.RegisterDecision.Accepted -> {
                    outgoingPairKey = pairKey
                    outgoingAttemptId = attemptId
                    outgoingRegistered = true
                }
                SoaPeerSessionArbiter.RegisterDecision.AlreadyConnected ->
                    throw IllegalStateException("SOA: already connected")
                SoaPeerSessionArbiter.RegisterDecision.AlreadyInProgress ->
                    throw IllegalStateException("SOA: already in progress")
            }
        }

        try {
            val client = localIdentity.handshakeClient(
                peerKem = peerKemPublicKeys,
                policy = effectiveHandshakePolicy
            )
            val (state, msgA) = client.start(
                P2PHandshakeClient.StartOptions(
                    peerIdForFallbackCooldown = peerId,
                    fallbackCooldownStore = localIdentity.fallbackCooldownStore(),
                    peerKemPublicKeys = peerKemPublicKeys,
                    handshakePolicy = effectiveHandshakePolicy.toWirePolicy(),
                    allowClassicBootstrapForTrustedPeer = allowClassicBootstrap,
                    messageAExtensionsRaw = soaExtensionsRaw,
                    protocolSigningKeys = protocolSigningKeys
                )
            )

            sendMutex.withLock { LengthPrefixedFraming.writeFrame(output, msgA) }

            var rawMessageB: ByteArray? = null
            var rawFinishedFromResponder: ByteArray? = null
            while (rawMessageB == null || rawFinishedFromResponder == null) {
                val frame = readFrame()
                val traffic = TrafficPaddingP2.unwrapIfNeeded(frame, label = "rx")
                val handshake = HandshakePaddingP1.unwrapIfNeeded(traffic)
                if (isLikelyFinished(handshake)) {
                    rawFinishedFromResponder = handshake
                    continue
                }
                if (isLikelyMessageB(handshake)) {
                    rawMessageB = handshake
                    continue
                }
            }

            val result = client.finish(
                state = state,
                rawMessageB = rawMessageB,
                peerIdForTrust = peerId,
                trustStore = localIdentity.trustStore(),
                allowTrustOnFirstUse = false
            )
            val okFinished = client.verifyResponderFinished(rawFinishedFromResponder, result.sessionKeys)
            require(okFinished) { "Responder Finished MAC invalid" }

            sendMutex.withLock { LengthPrefixedFraming.writeFrame(output, result.clientFinishedToSend) }

            onHandshakeEstablished(peerId = peerId, suiteWireId = result.negotiatedSuite.wireId.toInt(), keys = result.sessionKeys)
            outgoingPairKey?.let {
                arbiter.markEstablished(it)
                soaPairKey = it
            }

            // Best-effort: proactively send pairingIdentityExchange (helps strict PQC bootstrap).
            sendPairingIdentityExchangeIfNeeded(force = false)
        } finally {
            if (outgoingRegistered) {
                val pk = outgoingPairKey
                if (pk != null) {
                    arbiter.clearOutgoing(pk, outgoingAttemptId)
                }
            }
        }
    }

    private suspend fun performHandshakeAsResponder() {
        val peerId = peerIdHint
        val policyOverride = effectivePolicyOverride()
        val allowClassicBootstrap =
            peerId != null && localIdentity.trustStore().isPeerPinned(peerId)
        val effectiveHandshakePolicy = policyOverride.forTrustedClassicBootstrap(
            enabled = allowClassicBootstrap
        )
        val kem = localIdentity.getOrCreateKemIdentityKeys()
        val signKeys = localIdentity.getOrCreateProtocolSigningKeys()
        val protocolSigningKeys = P2PProtocolSigningKeys(
            ed25519PrivateKey = signKeys.ed25519PrivateKey,
            ed25519PublicKeyRaw32 = signKeys.ed25519PublicRaw32,
            mlDsa65PrivateKeyRaw = signKeys.mlDsa65PrivateKeyRaw,
            mlDsa65PublicKeyRaw = signKeys.mlDsa65PublicKeyRaw
        )

        val server = P2PHandshakeServer()
        val msgAFrame = readFrame()
        val msgA = HandshakePaddingP1.unwrapIfNeeded(TrafficPaddingP2.unwrapIfNeeded(msgAFrame, label = "rx"))

        val arbiter = SoaPeerSessionArbiter.shared
        var incomingPairKey: ByteArray? = null
        val decodedMsgA = P2PHandshakeWire.decodeMessageA(msgA)
        val okSigA = P2PHandshakeWire.verifyMessageASignature(decodedMsgA, rawMessageAWithoutPadding = msgA)
        require(okSigA) { "MessageA signature invalid" }
        if (decodedMsgA.unknownSupportedSuiteWireIds.isNotEmpty()) {
            throw IllegalArgumentException("Unknown supported suite(s): ${decodedMsgA.unknownSupportedSuiteWireIds}")
        }
        if (decodedMsgA.unknownKeyShareSuiteWireIds.isNotEmpty()) {
            throw IllegalArgumentException("Unknown keyShare suite(s): ${decodedMsgA.unknownKeyShareSuiteWireIds}")
        }

        val ext = P2PSoa.decodeFromExtensions(decodedMsgA.extensionsRaw)
        if (ext != null) {
            val localPeerId = P2PSoa.canonicalPeerIdBytes(localIdentity.deviceId())
            val expectedRemotePeerId = ext.initiatorPeerId
            val pairKey = P2PSoa.pairKey(localPeerId, expectedRemotePeerId)
            val decision = arbiter.evaluateIncoming(
                pairKey = pairKey,
                remoteInitiatorPeerId = ext.initiatorPeerId,
                remoteAttemptId = ext.attemptId,
                targetPeerId = ext.targetPeerId,
                expectedRemotePeerId = expectedRemotePeerId,
                localPeerId = localPeerId
            )
            when (decision) {
                SoaPeerSessionArbiter.IncomingDecision.Accept,
                is SoaPeerSessionArbiter.IncomingDecision.AcceptAndSupersedeLocal -> {
                    incomingPairKey = pairKey
                }
                SoaPeerSessionArbiter.IncomingDecision.RejectAlreadyConnected ->
                    throw IllegalStateException("SOA: already connected")
                SoaPeerSessionArbiter.IncomingDecision.RejectBinding ->
                    throw IllegalStateException("SOA: binding rejected")
                SoaPeerSessionArbiter.IncomingDecision.RejectRateLimited ->
                    throw IllegalStateException("SOA: rate limited")
                is SoaPeerSessionArbiter.IncomingDecision.RejectLocalWinner ->
                    throw IllegalStateException("SOA: local winner")
            }
        }

        val resp = server.respond(
            rawMessageA = msgA,
            peerIdForTrust = peerId,
            trustStore = localIdentity.trustStore(),
            allowTrustOnFirstUse = false,
            options = P2PHandshakeServer.RespondOptions(
                platformVersion = android.os.Build.VERSION.RELEASE,
                kemPrivateKeys = P2PHandshakeServer.KemPrivateKeys(
                    xWingPrivateKey = kem.xWingPrivateKey,
                    mlKem768PrivateKey = kem.mlKem768PrivateKey
                ),
                handshakePolicy = effectiveHandshakePolicy.toWirePolicy(),
                allowClassicBootstrapForTrustedPeer = allowClassicBootstrap,
                protocolSigningKeys = protocolSigningKeys
            )
        )

        val responderFinished = server.buildResponderFinished(resp.state.sessionKeys)
        sendMutex.withLock {
            LengthPrefixedFraming.writeFrame(output, resp.messageBToSend)
            LengthPrefixedFraming.writeFrame(output, responderFinished)
        }

        // Await client Finished.
        val finFrame = readFrame()
        val fin = HandshakePaddingP1.unwrapIfNeeded(TrafficPaddingP2.unwrapIfNeeded(finFrame, label = "rx"))
        require(server.verifyClientFinished(fin, resp.state.sessionKeys)) { "Client Finished MAC invalid" }

        incomingPairKey?.let {
            arbiter.markEstablished(it)
            soaPairKey = it
        }
        onHandshakeEstablished(peerId = peerId, suiteWireId = P2PHandshakeWire.decodeMessageB(HandshakePaddingP1.unwrapIfNeeded(resp.messageBToSend)).selectedSuite.wireId.toInt(), keys = resp.state.sessionKeys)
        sendPairingIdentityExchangeIfNeeded(force = false)
    }

    private suspend fun onHandshakeEstablished(peerId: String?, suiteWireId: Int, keys: P2PHandshakeWire.DerivedSessionKeys) {
        sessionKeys = keys
        negotiatedSuiteWireId = suiteWireId
        _events.tryEmit(TcpControlEvent.HandshakeEstablished(negotiatedSuiteWireId = suiteWireId, peerId = peerId))
    }

    private fun readFrame(): ByteArray {
        // macOS uses maxFrameBytes; keep a conservative limit here.
        return LengthPrefixedFraming.readFrame(input, maxFrameSize = 16 * 1024 * 1024)
    }

    private suspend fun startReceiveLoop() {
        while (running.get()) {
            val frame = try {
                readFrame()
            } catch (t: Throwable) {
                break
            }
            val traffic = TrafficPaddingP2.unwrapIfNeeded(frame, label = "rx")
            val unpadded = HandshakePaddingP1.unwrapIfNeeded(traffic)

            // Rekey support: allow receiving a new MessageA while already established (macOS strict PQC bootstrap).
            if (isLikelyMessageA(unpadded)) {
                runCatching { performRekeyAsResponder(rawMessageA = unpadded) }
                    .onFailure { _events.tryEmit(TcpControlEvent.Failed(peerIdHint, it.message ?: "rekey failed")) }
                continue
            }

            val keys = sessionKeys ?: continue
            val plaintext = runCatching { AesGcmCombined.decrypt(keys.receiveKey, unpadded) }.getOrNull() ?: continue

            val env = BusinessEnvelope.decode(plaintext)
            if (env != null && env.kind == BusinessEnvelope.KIND_REMOTE_DESKTOP_FRAME) {
                _events.tryEmit(
                    TcpControlEvent.RemoteDesktopFrameReceived(
                        peerId = peerIdHint,
                        timestampNs = env.timestampNs,
                        payload = env.payload
                    )
                )
                continue
            }

            val msg = codec.decode(plaintext) ?: continue
            when (msg) {
                is AppMessage.PairingIdentityExchange -> {
                    handlePairingIdentityExchange(msg.payload)
                }
                else -> {
                    _events.tryEmit(TcpControlEvent.AppMessageReceived(peerId = peerIdHint, message = msg))
                }
            }
        }
        close()
    }

    private suspend fun performRekeyAsResponder(rawMessageA: ByteArray) {
        val peerId = peerIdHint
        val policyOverride = effectivePolicyOverride()
        val allowClassicBootstrap =
            peerId != null && localIdentity.trustStore().isPeerPinned(peerId)
        val effectiveHandshakePolicy = policyOverride.forTrustedClassicBootstrap(
            enabled = allowClassicBootstrap
        )
        val kem = localIdentity.getOrCreateKemIdentityKeys()
        val signKeys = localIdentity.getOrCreateProtocolSigningKeys()
        val protocolSigningKeys = P2PProtocolSigningKeys(
            ed25519PrivateKey = signKeys.ed25519PrivateKey,
            ed25519PublicKeyRaw32 = signKeys.ed25519PublicRaw32,
            mlDsa65PrivateKeyRaw = signKeys.mlDsa65PrivateKeyRaw,
            mlDsa65PublicKeyRaw = signKeys.mlDsa65PublicKeyRaw
        )
        val server = P2PHandshakeServer()
        val resp = server.respond(
            rawMessageA = rawMessageA,
            peerIdForTrust = peerId,
            trustStore = localIdentity.trustStore(),
            allowTrustOnFirstUse = false,
            options = P2PHandshakeServer.RespondOptions(
                platformVersion = android.os.Build.VERSION.RELEASE,
                kemPrivateKeys = P2PHandshakeServer.KemPrivateKeys(
                    xWingPrivateKey = kem.xWingPrivateKey,
                    mlKem768PrivateKey = kem.mlKem768PrivateKey
                ),
                handshakePolicy = effectiveHandshakePolicy.toWirePolicy(),
                allowClassicBootstrapForTrustedPeer = allowClassicBootstrap,
                protocolSigningKeys = protocolSigningKeys
            )
        )
        val responderFinished = server.buildResponderFinished(resp.state.sessionKeys)
        sendMutex.withLock {
            LengthPrefixedFraming.writeFrame(output, resp.messageBToSend)
            LengthPrefixedFraming.writeFrame(output, responderFinished)
        }

        // Await client Finished.
        val finFrame = readFrame()
        val fin = HandshakePaddingP1.unwrapIfNeeded(TrafficPaddingP2.unwrapIfNeeded(finFrame, label = "rx"))
        require(server.verifyClientFinished(fin, resp.state.sessionKeys)) { "Client Finished MAC invalid (rekey)" }

        val suite = P2PHandshakeWire
            .decodeMessageB(HandshakePaddingP1.unwrapIfNeeded(resp.messageBToSend))
            .selectedSuite
            .wireId
            .toInt()
        onHandshakeEstablished(peerId = peerId, suiteWireId = suite, keys = resp.state.sessionKeys)
    }

    private suspend fun handlePairingIdentityExchange(payload: AppMessage.PairingIdentityExchangePayload) {
        val peerId = payload.deviceId.ifBlank { peerIdHint } ?: return
        val aliasIds = buildSet {
            add(peerId)
            peerIdHint?.let { add(it) }
        }
        val trustedPeerStore = localIdentity.trustedPeerStore()
        val existingRecord = aliasIds
            .asSequence()
            .mapNotNull { trustedPeerStore.findByKnownDeviceId(it) }
            .firstOrNull()
        val fingerprint = existingRecord?.protocolPublicKeyFingerprint
            ?: aliasIds
                .asSequence()
                .mapNotNull { aliasId -> localIdentity.trustStore().loadPeerSigningFingerprint(aliasId) }
                .firstOrNull()
        val conflict = fingerprint?.let {
            trustedPeerStore.evaluateCurrentPathBinding(
                deviceId = peerId,
                protocolPublicKeyFingerprint = it
            )
        }
        val alreadyTrusted = existingRecord != null ||
            aliasIds.any { aliasId -> localIdentity.trustStore().isPeerPinned(aliasId) }
        val request = PairingTrustRequest(
            peerId = peerIdHint ?: peerId,
            declaredDeviceId = peerId,
            deviceName = payload.deviceName,
            platform = payload.platform,
            modelName = payload.modelName,
            osVersion = payload.osVersion,
            chip = payload.chip,
            protocolPublicKeyFingerprint = fingerprint,
            conflict = conflict
        )
        val decision = when {
            conflict != null -> {
                PairingTrustManager.requestDecision(request)
                PairingTrustDecision.DECLINE
            }
            alreadyTrusted -> PairingTrustDecision.TRUST_ALWAYS
            else -> PairingTrustManager.requestDecision(request)
        }
        if (decision == PairingTrustDecision.DECLINE) return

        peerKemStore.save(peerId, payload.kemPublicKeys)
        peerIdHint
            ?.takeIf { it != peerId }
            ?.let { aliasId -> peerKemStore.save(aliasId, payload.kemPublicKeys) }
        if (decision == PairingTrustDecision.TRUST_ALWAYS) {
            persistTrustedAliasFromPairingExchange(
                declaredDeviceId = peerId,
                payload = payload
            )
        }
        sendPairingIdentityExchangeIfNeeded(force = true)
        _events.tryEmit(TcpControlEvent.AppMessageReceived(peerId = peerIdHint, message = AppMessage.PairingIdentityExchange(payload)))
    }

    private fun persistTrustedAliasFromPairingExchange(
        declaredDeviceId: String,
        payload: AppMessage.PairingIdentityExchangePayload
    ) {
        val aliasIds = buildSet {
            add(declaredDeviceId)
            peerIdHint?.let { add(it) }
        }
        val trustedPeerStore = localIdentity.trustedPeerStore()
        val existingRecord = aliasIds
            .asSequence()
            .mapNotNull { trustedPeerStore.findByKnownDeviceId(it) }
            .firstOrNull()
        val fingerprint = existingRecord?.protocolPublicKeyFingerprint
            ?: aliasIds
                .asSequence()
                .mapNotNull { aliasId -> localIdentity.trustStore().loadPeerSigningFingerprint(aliasId) }
                .firstOrNull()
            ?: return
        trustedPeerStore.upsertCurrentPathAuthority(
            deviceId = declaredDeviceId,
            name = payload.deviceName?.trim()?.takeIf { it.isNotEmpty() } ?: existingRecord?.name,
            protocolSigningAlgorithm = existingRecord?.protocolSigningAlgorithm,
            protocolPublicKeyFingerprint = fingerprint,
            aliasIds = aliasIds
        )
    }

    private suspend fun sendPairingIdentityExchangeIfNeeded(force: Boolean) {
        if (!force && pairingExchangeSent.get()) return
        val now = SwiftDateSeconds.now()
        val payload = localIdentity.buildPairingIdentityExchange(nowSwiftSeconds = now)
        sendAppMessage(AppMessage.PairingIdentityExchange(payload))
        pairingExchangeSent.set(true)
    }

    private fun isUuidLike(value: String): Boolean = UUID_REGEX.matches(value.trim())

    private fun isLikelyFinished(data: ByteArray): Boolean {
        if (data.size != 38) return false
        return runCatching { P2PHandshakeWire.decodeFinished(data) }.isSuccess
    }

    private fun isLikelyMessageA(data: ByteArray): Boolean =
        runCatching { P2PHandshakeWire.decodeMessageA(data) }.isSuccess

    private fun isLikelyMessageB(data: ByteArray): Boolean =
        runCatching { P2PHandshakeWire.decodeMessageB(data) }.isSuccess

    private fun effectivePolicyOverride(): P2PHandshakePolicyOverride {
        return handshakePolicyOverride ?: localIdentity.defaultHandshakePolicyOverride()
    }

    companion object {
        private val UUID_REGEX =
            Regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
    }
}
