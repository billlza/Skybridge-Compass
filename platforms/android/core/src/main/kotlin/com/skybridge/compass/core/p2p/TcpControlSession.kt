package com.skybridge.compass.core.p2p

import com.skybridge.compass.shared.p2p.HandshakePaddingP1
import com.skybridge.compass.shared.p2p.P2PHandshakeClient
import com.skybridge.compass.shared.p2p.P2PHandshakeServer
import com.skybridge.compass.shared.p2p.P2PHandshakeWire
import com.skybridge.compass.shared.p2p.P2PProtocolSigningKeys
import com.skybridge.compass.shared.p2p.P2PQPeriaptKem
import com.skybridge.compass.shared.p2p.P2PSoa
import com.skybridge.compass.shared.p2p.QPeriaptPlatformPolicy
import com.skybridge.compass.shared.p2p.TrafficPaddingP2
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.Socket
import java.net.SocketTimeoutException
import java.security.SecureRandom
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

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
    private val role: Role,
    private val handshakeDeadlineMillis: Long = DEFAULT_HANDSHAKE_DEADLINE_MILLIS,
    private val nanoTime: () -> Long = System::nanoTime
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
    private val initialHandshakeDeadlineNanos = TcpHandshakeDeadline.deadlineNanos(
        startNanos = nanoTime(),
        timeoutMillis = handshakeDeadlineMillis
    )

    @Volatile private var sessionKeys: P2PHandshakeWire.DerivedSessionKeys? = null
    @Volatile private var negotiatedSuiteWireId: Int = 0
    @Volatile private var soaPairKey: ByteArray? = null
    @Volatile private var authenticatedPeerId: String? = peerIdHint
    private val authenticatedPairingAttemptGate = AuthenticatedPairingAttemptGate()

    private val running = AtomicBoolean(false)
    private val closeState = TcpControlSessionCloseState()
    private val ownerCloseCallback = TcpControlSessionOwnerCloseCallback(this)
    private val pairingExchangeSent = AtomicBoolean(false)

    private var readJob: Job? = null

    internal fun setOnClosed(callback: (TcpControlSession) -> Unit) {
        ownerCloseCallback.register(callback)
    }

    fun start() {
        closeState.runIfOpen {
            if (!running.compareAndSet(false, true)) return@runIfOpen
            readJob = scope.launch {
                try {
                    when (role) {
                        Role.INITIATOR -> performHandshakeAsInitiator()
                        Role.RESPONDER -> performHandshakeAsResponder()
                    }
                    startReceiveLoop()
                } catch (cancellation: CancellationException) {
                    try {
                        close()
                    } catch (closeFailure: Exception) {
                        cancellation.addSuppressed(closeFailure)
                    }
                    throw cancellation
                } catch (_: Exception) {
                    _events.emit(
                        TcpControlEvent.Failed(
                            currentPeerId(),
                            "TCP session terminated due to a protocol or transport error"
                        )
                    )
                    try {
                        close()
                    } catch (_: Exception) {
                        withContext(NonCancellable) {
                            _events.emit(
                                TcpControlEvent.Failed(
                                    currentPeerId(),
                                    "TCP session cleanup failed after termination"
                                )
                            )
                        }
                    }
                }
            }
        }
    }

    fun close() = closeState.close(
        prepare = {
            running.set(false)
            authenticatedPairingAttemptGate.clear()
            readJob?.cancel()
            soaPairKey?.let { SoaPeerSessionArbiter.shared.clearEstablished(it) }
            soaPairKey = null
        },
        closeSocket = socket::close,
        notifyClosed = {
            _events.tryEmit(TcpControlEvent.Disconnected(currentPeerId()))
            ownerCloseCallback.notifyClosed()
        }
    )

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
            qPeriaptPublicKey = peerKem.qPeriaptPublicKey,
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
                    close()
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
                val frame = readHandshakeFrame(initialHandshakeDeadlineNanos)
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

            val committed = onHandshakeEstablished(
                peerId = peerId,
                suiteWireId = result.negotiatedSuite.wireId.toInt(),
                keys = result.sessionKeys,
                remoteProtocolIdentityFingerprint = result.remoteProtocolIdentityFingerprint,
                establishedPairKey = outgoingPairKey,
                handshakeDeadlineNanos = initialHandshakeDeadlineNanos
            )
            if (!committed) return

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
        val server = P2PHandshakeServer()
        val msgAFrame = readHandshakeFrame(initialHandshakeDeadlineNanos)
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

        val resolvedPeer = resolveInboundPeerIdentity(decodedMsgA)
        val peerId = resolvedPeer.peerId

        val localPeerId = P2PSoa.canonicalPeerIdBytes(localIdentity.deviceId())
        val pairKey = P2PSoa.pairKey(localPeerId, resolvedPeer.remoteSoaPeerId)
        val ext = resolvedPeer.soaExtension
        val decision = arbiter.evaluateIncoming(
            pairKey = pairKey,
            remoteInitiatorPeerId = ext.initiatorPeerId,
            remoteAttemptId = ext.attemptId,
            targetPeerId = ext.targetPeerId,
            expectedRemotePeerId = resolvedPeer.remoteSoaPeerId,
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

        val policyOverride = effectivePolicyOverride()
        val allowClassicBootstrap = localIdentity.trustStore().isPeerPinned(peerId)
        val effectiveHandshakePolicy = policyOverride.forTrustedClassicBootstrap(
            enabled = allowClassicBootstrap
        )
        val kem = localIdentity.getOrCreateKemIdentityKeys(
            allowQPeriapt = effectiveHandshakePolicy.minimumTierRaw == P2PQPeriaptKem.MINIMUM_TIER_RAW
        )
        val signKeys = localIdentity.getOrCreateProtocolSigningKeys()
        val protocolSigningKeys = P2PProtocolSigningKeys(
            ed25519PrivateKey = signKeys.ed25519PrivateKey,
            ed25519PublicKeyRaw32 = signKeys.ed25519PublicRaw32,
            mlDsa65PrivateKeyRaw = signKeys.mlDsa65PrivateKeyRaw,
            mlDsa65PublicKeyRaw = signKeys.mlDsa65PublicKeyRaw
        )

        val resp = server.respond(
            rawMessageA = msgA,
            peerIdForTrust = peerId,
            trustStore = localIdentity.trustStore(),
            allowTrustOnFirstUse = false,
            options = P2PHandshakeServer.RespondOptions(
                platformVersion = QPeriaptPlatformPolicy.androidHandshakePlatformVersion(
                    release = android.os.Build.VERSION.RELEASE,
                    sdkInt = android.os.Build.VERSION.SDK_INT
                ),
                kemPrivateKeys = P2PHandshakeServer.KemPrivateKeys(
                    qPeriaptPrivateKey = kem.qPeriaptPrivateKey,
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
        val finFrame = readHandshakeFrame(initialHandshakeDeadlineNanos)
        val fin = HandshakePaddingP1.unwrapIfNeeded(TrafficPaddingP2.unwrapIfNeeded(finFrame, label = "rx"))
        require(server.verifyClientFinished(fin, resp.state.sessionKeys)) { "Client Finished MAC invalid" }

        val committed = onHandshakeEstablished(
            peerId = peerId,
            suiteWireId = P2PHandshakeWire.decodeMessageB(
                HandshakePaddingP1.unwrapIfNeeded(resp.messageBToSend)
            ).selectedSuite.wireId.toInt(),
            keys = resp.state.sessionKeys,
            remoteProtocolIdentityFingerprint = resp.state.remoteProtocolIdentityFingerprint,
            establishedPairKey = incomingPairKey,
            handshakeDeadlineNanos = initialHandshakeDeadlineNanos
        )
        if (!committed) return
        sendPairingIdentityExchangeIfNeeded(force = false)
    }

    private fun onHandshakeEstablished(
        peerId: String?,
        suiteWireId: Int,
        keys: P2PHandshakeWire.DerivedSessionKeys,
        remoteProtocolIdentityFingerprint: String,
        establishedPairKey: ByteArray?,
        handshakeDeadlineNanos: Long
    ): Boolean {
        val committed = closeState.commitIfOpen {
            TcpHandshakeDeadline.remainingTimeoutMillis(
                deadlineNanos = handshakeDeadlineNanos,
                nowNanos = nanoTime()
            )
            socket.soTimeout = 0
            authenticatedPairingAttemptGate.establishIfActive(
                observedProtocolFingerprint = remoteProtocolIdentityFingerprint,
                isActive = running::get,
                onEstablished = {
                    if (peerId != null) {
                        authenticatedPeerId = peerId
                    }
                    sessionKeys = keys
                    negotiatedSuiteWireId = suiteWireId
                }
            ) ?: return@commitIfOpen false
            establishedPairKey?.let {
                SoaPeerSessionArbiter.shared.markEstablished(it)
                soaPairKey = it
            }
            _events.tryEmit(
                TcpControlEvent.HandshakeEstablished(
                    negotiatedSuiteWireId = suiteWireId,
                    peerId = peerId
                )
            )
            true
        }
        return committed == true
    }

    private fun readHandshakeFrame(deadlineNanos: Long): ByteArray =
        LengthPrefixedFraming.readFrame(
            input = input,
            maxFrameSize = P2PHandshakeWire.MAX_HANDSHAKE_FRAME_BYTES,
            beforeRead = {
                socket.soTimeout = TcpHandshakeDeadline.remainingTimeoutMillis(
                    deadlineNanos = deadlineNanos,
                    nowNanos = nanoTime()
                )
            }
        )

    private fun readFrame(): ByteArray {
        // macOS uses maxFrameBytes; keep a conservative limit here.
        return LengthPrefixedFraming.readFrame(input, maxFrameSize = 16 * 1024 * 1024)
    }

    private suspend fun startReceiveLoop() {
        while (running.get()) {
            val frame = try {
                readFrame()
            } catch (_: Exception) {
                break
            }
            val traffic = TrafficPaddingP2.unwrapIfNeeded(frame, label = "rx")
            val unpadded = HandshakePaddingP1.unwrapIfNeeded(traffic)

            // Rekey support: allow receiving a new MessageA while already established (macOS strict PQC bootstrap).
            if (isLikelyMessageA(unpadded)) {
                try {
                    performRekeyAsResponder(rawMessageA = unpadded)
                } catch (cancellation: CancellationException) {
                    throw cancellation
                } catch (_: Exception) {
                    _events.tryEmit(
                        TcpControlEvent.Failed(currentPeerId(), "authenticated session rekey failed")
                    )
                    break
                }
                continue
            }

            val keys = sessionKeys ?: continue
            val plaintext = try {
                AesGcmCombined.decrypt(keys.receiveKey, unpadded)
            } catch (_: Exception) {
                _events.tryEmit(
                    TcpControlEvent.Failed(currentPeerId(), "authenticated frame validation failed")
                )
                break
            }

            val env = BusinessEnvelope.decode(plaintext)
            if (env != null && env.kind == BusinessEnvelope.KIND_REMOTE_DESKTOP_FRAME) {
                _events.tryEmit(
                    TcpControlEvent.RemoteDesktopFrameReceived(
                        peerId = currentPeerId(),
                        timestampNs = env.timestampNs,
                        payload = env.payload
                    )
                )
                continue
            }

            val decoded = try {
                codec.decodeAuthenticatedControl(plaintext)
            } catch (_: AppMessageCodec.DecodeException) {
                _events.tryEmit(
                    TcpControlEvent.Failed(
                        peerId = currentPeerId(),
                        error = "malformed authenticated app-control payload"
                    )
                )
                break
            }
            val msg = when (decoded) {
                is AppMessageCodec.DecodeResult.Known -> decoded.message
                is AppMessageCodec.DecodeResult.UnknownType -> {
                    _events.tryEmit(
                        TcpControlEvent.Failed(
                            peerId = currentPeerId(),
                            error = "unsupported authenticated app-control message"
                        )
                    )
                    break
                }
            }
            when (msg) {
                is AppMessage.PairingIdentityExchange -> {
                    handlePairingIdentityExchange(msg.payload)
                }
                else -> {
                    _events.tryEmit(TcpControlEvent.AppMessageReceived(peerId = currentPeerId(), message = msg))
                }
            }
        }
        close()
    }

    private suspend fun performRekeyAsResponder(rawMessageA: ByteArray) {
        val rekeyDeadlineNanos = TcpHandshakeDeadline.deadlineNanos(
            startNanos = nanoTime(),
            timeoutMillis = handshakeDeadlineMillis
        )
        val decodedMsgA = P2PHandshakeWire.decodeMessageA(rawMessageA)
        val okSigA = P2PHandshakeWire.verifyMessageASignature(decodedMsgA, rawMessageAWithoutPadding = rawMessageA)
        require(okSigA) { "MessageA signature invalid (rekey)" }
        val resolvedPeer = resolveInboundPeerIdentity(decodedMsgA)
        val peerId = resolvedPeer.peerId
        val existingPeerId = requireNotNull(currentPeerId()) { "rekey requires an authenticated peer" }
        require(peerId == existingPeerId) { "rekey peer identity mismatch" }
        val policyOverride = effectivePolicyOverride()
        val allowClassicBootstrap =
            localIdentity.trustStore().isPeerPinned(peerId)
        val effectiveHandshakePolicy = policyOverride.forTrustedClassicBootstrap(
            enabled = allowClassicBootstrap
        )
        val kem = localIdentity.getOrCreateKemIdentityKeys(
            allowQPeriapt = effectiveHandshakePolicy.minimumTierRaw == P2PQPeriaptKem.MINIMUM_TIER_RAW
        )
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
                platformVersion = QPeriaptPlatformPolicy.androidHandshakePlatformVersion(
                    release = android.os.Build.VERSION.RELEASE,
                    sdkInt = android.os.Build.VERSION.SDK_INT
                ),
                kemPrivateKeys = P2PHandshakeServer.KemPrivateKeys(
                    qPeriaptPrivateKey = kem.qPeriaptPrivateKey,
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
        val finFrame = readHandshakeFrame(rekeyDeadlineNanos)
        val fin = HandshakePaddingP1.unwrapIfNeeded(TrafficPaddingP2.unwrapIfNeeded(finFrame, label = "rx"))
        require(server.verifyClientFinished(fin, resp.state.sessionKeys)) { "Client Finished MAC invalid (rekey)" }

        val suite = P2PHandshakeWire
            .decodeMessageB(HandshakePaddingP1.unwrapIfNeeded(resp.messageBToSend))
            .selectedSuite
            .wireId
            .toInt()
        check(onHandshakeEstablished(
            peerId = peerId,
            suiteWireId = suite,
            keys = resp.state.sessionKeys,
            remoteProtocolIdentityFingerprint = resp.state.remoteProtocolIdentityFingerprint,
            establishedPairKey = null,
            handshakeDeadlineNanos = rekeyDeadlineNanos
        )) { "rekey completed after session close" }
    }

    private suspend fun handlePairingIdentityExchange(payload: AppMessage.PairingIdentityExchangePayload) {
        val attempt = authenticatedPairingAttemptGate.snapshot()
            ?: throw IllegalStateException("authenticated product-session KEM authority is unavailable")
        val observedProtocolFingerprint = attempt.observedProtocolFingerprint
        val activePeerId = currentPeerId()
        val peerId = payload.deviceId.ifBlank { activePeerId } ?: return
        val aliasIds = buildSet {
            add(peerId)
            activePeerId?.let { add(it) }
            peerIdHint?.let { add(it) }
        }
        val trustedPeerStore = localIdentity.trustedPeerStore()
        val storeConflict = trustedPeerStore.corruptionConflictOrNull()
        val exactExistingAuthority = if (storeConflict == null) {
            trustedPeerStore.findExactVerifiedAuthorityReadOnly(
                deviceIds = aliasIds,
                protocolPublicKeyFingerprint = observedProtocolFingerprint
            )
        } else {
            null
        }
        val conflict = storeConflict ?: aliasIds.asSequence()
            .mapNotNull { deviceId ->
                trustedPeerStore.evaluateCurrentPathBinding(
                    deviceId = deviceId,
                    protocolPublicKeyFingerprint = observedProtocolFingerprint
                )
            }
            .firstOrNull()
        val request = PairingTrustRequest(
            peerId = activePeerId ?: peerId,
            declaredDeviceId = peerId,
            deviceName = payload.deviceName,
            platform = payload.platform,
            modelName = payload.modelName,
            osVersion = payload.osVersion,
            chip = payload.chip,
            protocolPublicKeyFingerprint = observedProtocolFingerprint,
            conflict = conflict
        )
        // R7.5：已配对设备是否免交互批准由 `auto_trust_known_devices` 决定（PairingApprovalPolicy），
        // 关闭时即使已有 exact product authority 也进入等待用户显式批准态。
        val decision = when {
            conflict != null -> {
                val explicitDecision = PairingTrustManager.requestDecision(request)
                if (conflict == PairingTrustConflict.DEVICE_ID_MIGRATION_REQUIRED) {
                    explicitDecision
                } else {
                    PairingTrustDecision.DECLINE
                }
            }
            else -> PairingTrustManager.requestDecision(
                request = request,
                isKnownDevice = exactExistingAuthority != null
            )
        }
        if (decision == PairingTrustDecision.DECLINE) return
        val persistenceResult = authenticatedPairingAttemptGate.runIfCurrent(attempt) {
            if (!running.get()) return@runIfCurrent AuthenticatedPairingPersistenceResult.SESSION_ONLY
            AuthenticatedPairingPersistence(
                trustedPeerStore = trustedPeerStore,
                peerKemStore = peerKemStore
            ).persistApprovedAttempt(
                decision = decision,
                declaredDeviceId = peerId,
                aliasIds = aliasIds,
                observedProtocolFingerprint = observedProtocolFingerprint,
                deviceName = payload.deviceName?.trim()?.takeIf { it.isNotEmpty() },
                protocolSigningAlgorithm = exactExistingAuthority?.protocolSigningAlgorithm,
                kemPublicKeys = payload.kemPublicKeys,
                platform = payload.platform,
                osVersion = payload.osVersion
            )
        }
        if (persistenceResult == null) {
            _events.tryEmit(
                TcpControlEvent.Failed(
                    peerId = currentPeerId(),
                    error = "authenticated pairing attempt was replaced before approval"
                )
            )
            return
        }
        if (!running.get()) return
        sendPairingIdentityExchangeIfNeeded(force = true)
        _events.tryEmit(TcpControlEvent.AppMessageReceived(peerId = currentPeerId(), message = AppMessage.PairingIdentityExchange(payload)))
    }

    private suspend fun sendPairingIdentityExchangeIfNeeded(force: Boolean) {
        if (!force && pairingExchangeSent.get()) return
        val now = SwiftDateSeconds.now()
        val policy = effectivePolicyOverride()
        val payload = localIdentity.buildPairingIdentityExchange(
            nowSwiftSeconds = now,
            allowQPeriapt = policy.minimumTierRaw == P2PQPeriaptKem.MINIMUM_TIER_RAW
        )
        sendAppMessage(AppMessage.PairingIdentityExchange(payload))
        pairingExchangeSent.set(true)
    }

    private fun isUuidLike(value: String): Boolean = UUID_REGEX.matches(value.trim())

    private fun isLikelyFinished(data: ByteArray): Boolean {
        if (data.size != 38) return false
        return try {
            P2PHandshakeWire.decodeFinished(data)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun isLikelyMessageA(data: ByteArray): Boolean = try {
        P2PHandshakeWire.decodeMessageA(data)
        true
    } catch (_: Exception) {
        false
    }

    private fun isLikelyMessageB(data: ByteArray): Boolean = try {
        P2PHandshakeWire.decodeMessageB(data)
        true
    } catch (_: Exception) {
        false
    }

    private fun effectivePolicyOverride(): P2PHandshakePolicyOverride {
        return handshakePolicyOverride ?: localIdentity.defaultHandshakePolicyOverride()
    }

    private fun currentPeerId(): String? = authenticatedPeerId ?: peerIdHint

    private fun resolveInboundPeerIdentity(messageA: P2PHandshakeWire.MessageA): InboundTcpPeerIdentity =
        InboundTcpPeerIdentityResolver(
            trustedPeerStore = localIdentity.trustedPeerStore(),
            localDeviceId = localIdentity.deviceId()
        ).resolve(messageA)

    companion object {
        private const val DEFAULT_HANDSHAKE_DEADLINE_MILLIS = 30_000L
        private val UUID_REGEX =
            Regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
    }
}

internal object TcpHandshakeDeadline {
    private const val NANOS_PER_MILLISECOND = 1_000_000L

    fun deadlineNanos(startNanos: Long, timeoutMillis: Long): Long {
        require(timeoutMillis > 0) { "TCP handshake deadline must be positive" }
        require(timeoutMillis <= Long.MAX_VALUE / NANOS_PER_MILLISECOND) {
            "TCP handshake deadline is too large"
        }
        val durationNanos = timeoutMillis * NANOS_PER_MILLISECOND
        require(durationNanos < Long.MAX_VALUE / 2) { "TCP handshake deadline is too large" }
        return startNanos + durationNanos
    }

    fun remainingTimeoutMillis(deadlineNanos: Long, nowNanos: Long): Int {
        val remainingNanos = deadlineNanos - nowNanos
        if (remainingNanos <= 0L) {
            throw SocketTimeoutException("TCP handshake deadline exceeded")
        }
        val roundedUpMillis = (remainingNanos - 1L) / NANOS_PER_MILLISECOND + 1L
        return roundedUpMillis.coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
    }
}

/**
 * Coordinates the three distinct phases of session shutdown.
 *
 * A requested close permanently prevents a later [TcpControlSession.start], but a failed socket
 * close does not pretend that shutdown completed. The same session owner can therefore retry the
 * exact resource without repeating already-completed preparation or notification phases.
 */
internal class TcpControlSessionCloseState {
    private val lock = ReentrantLock()
    private val closeCompleted = lock.newCondition()
    private var closeRequested = false
    private var closeInProgress = false
    private var prepared = false
    private var socketClosed = false
    private var notified = false

    val canStart: Boolean
        get() = lock.withLock { !closeRequested }

    fun runIfOpen(action: () -> Unit): Boolean = lock.withLock {
        if (closeRequested) return false
        action()
        true
    }

    fun <T> commitIfOpen(action: () -> T): T? = lock.withLock {
        if (closeRequested) return null
        action()
    }

    fun close(
        prepare: () -> Unit,
        closeSocket: () -> Unit,
        notifyClosed: () -> Unit
    ) {
        lock.withLock {
            closeRequested = true
            while (closeInProgress) closeCompleted.await()
            if (notified) return
            closeInProgress = true
        }

        try {
            if (lock.withLock { !prepared }) {
                prepare()
                lock.withLock { prepared = true }
            }
            if (lock.withLock { !socketClosed }) {
                closeSocket()
                lock.withLock { socketClosed = true }
            }
            if (lock.withLock { !notified }) {
                notifyClosed()
                lock.withLock { notified = true }
            }
        } finally {
            lock.withLock {
                closeInProgress = false
                closeCompleted.signalAll()
            }
        }
    }
}

internal class TcpControlSessionOwnerCloseCallback<T : Any>(
    private val owner: T
) {
    private val lock = Any()
    private var callback: ((T) -> Unit)? = null
    private var closed = false
    private var callbackRunning = false
    private var callbackCompleted = false

    fun register(value: (T) -> Unit) {
        val claimed = synchronized(lock) {
            check(callback == null && !callbackCompleted) {
                "TCP session close ownership callback is already registered"
            }
            callback = value
            claimLocked()
        }
        claimed?.let(::runClaimed)
    }

    fun notifyClosed() {
        val claimed = synchronized(lock) {
            closed = true
            claimLocked()
        }
        claimed?.let(::runClaimed)
    }

    private fun claimLocked(): ((T) -> Unit)? {
        val value = callback
        if (!closed || value == null || callbackRunning || callbackCompleted) return null
        callbackRunning = true
        return value
    }

    private fun runClaimed(value: (T) -> Unit) {
        var completed = false
        try {
            value(owner)
            completed = true
        } finally {
            synchronized(lock) {
                callbackRunning = false
                if (completed && callback === value) {
                    callbackCompleted = true
                    callback = null
                }
            }
        }
    }
}
