package com.skybridge.compass.core.webrtc

import android.content.Context
import android.net.Uri
import android.os.Build
import android.util.Base64
import com.skybridge.compass.core.data.NetworkSettings
import com.skybridge.compass.core.data.NetworkSettingsStore
import com.skybridge.compass.core.p2p.AppMessage
import com.skybridge.compass.core.p2p.AppMessageCodec
import com.skybridge.compass.core.p2p.LocalP2PIdentity
import com.skybridge.compass.core.p2p.P2PHandshakePolicyOverride
import com.skybridge.compass.core.p2p.PairingTrustDecision
import com.skybridge.compass.core.p2p.PairingTrustManager
import com.skybridge.compass.core.p2p.PairingTrustRequest
import com.skybridge.compass.core.p2p.PeerKemKeyStore
import com.skybridge.compass.core.p2p.SwiftDateSeconds
import com.skybridge.compass.core.p2p.forTrustedClassicBootstrap
import com.skybridge.compass.core.p2p.isMissingPqcMaterial
import com.skybridge.compass.core.p2p.isPeerPinned
import com.skybridge.compass.core.p2p.toWirePolicy
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import com.skybridge.compass.shared.crypto.AesGcmCombined
import com.skybridge.compass.shared.p2p.HandshakePaddingP1
import com.skybridge.compass.shared.p2p.P2PHandshakeClient
import com.skybridge.compass.shared.p2p.P2PHandshakeServer
import com.skybridge.compass.shared.p2p.P2PHandshakeWire
import com.skybridge.compass.shared.p2p.P2PIdentityPublicKeys
import com.skybridge.compass.shared.p2p.P2PProtocolSigningKeys
import com.skybridge.compass.shared.p2p.TrafficPaddingP2
import java.net.URI
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import android.util.Log

/**
 * Minimal connection manager aligning with Pro release CrossNetworkConnectionManager for code-based WebRTC:
 * - sessionId == server-issued connection code
 * - signaling via WebSocketSignalingClient (join/offer/answer/iceCandidate)
 * - DataChannel label "skybridge"
 */
class SkyBridgeWebRtcConnectionManager(
    private val appContext: Context,
    private val networkSettingsOverrideProvider: (suspend () -> NetworkSettings?)? = null,
    private val localIdentityProvider: (() -> LocalP2PIdentity)? = null,
    private val userAuthContextProvider: (suspend () -> SignalServerClient.UserAuthContext?)? = null
) {
    sealed class State {
        data object Idle : State()
        data class Waiting(val code: String) : State()
        data class Connecting(val code: String) : State()
        data class Connected(val code: String) : State()
        data class Failed(val code: String?, val message: String) : State()
    }

    data class SignalingStatus(
        val sessionId: String? = null,
        val websocketUrl: String = SkyBridgeServerConfig.signalingWebSocketURL,
        val shard: String? = null,
        val peerSignalingId: String? = null,
        val lastEvent: String = "idle"
    )

    private data class CurrentPathRemoteAuthority(
        val deviceId: String,
        val protocolSigningAlgorithm: ProtocolSigningAlgorithm,
        val protocolPublicKeyFingerprint: String,
        val deviceName: String? = null
    )

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var signalingUrl: String = SkyBridgeServerConfig.signalingWebSocketURL
    private var signalingShard: String? = null
    private var signaling: WebSocketSignalingClient = WebSocketSignalingClient(wsUrlString = signalingUrl)
    private val turnService = TURNCredentialService()
    private val authSessionStore: CurrentPathAuthSessionStore by lazy {
        CurrentPathAuthSessionStore(appContext)
    }

    private var session: WebRtcSession? = null
    private val localIdentity: LocalP2PIdentity by lazy {
        localIdentityProvider?.invoke() ?: LocalP2PIdentity(appContext)
    }
    private val peerKemStore: PeerKemKeyStore by lazy { PeerKemKeyStore(appContext) }
    private val appMessageCodec: AppMessageCodec = AppMessageCodec()

    private var localId: String = runCatching { defaultDeviceId() }
        .getOrElse { generateFallbackDeviceId() }
    private var currentSessionId: String? = null
    private var remoteSignalingId: String? = null
    private var remoteDeviceId: String? = null
    private val webrtcSignalingAuthTokenBySessionId = linkedMapOf<String, String>()
    private val currentPathExpectedRemoteAuthorityBySessionId = linkedMapOf<String, CurrentPathRemoteAuthority>()
    private val currentPathSignalingOriginBySessionId = linkedMapOf<String, String>()
    private val currentPathTurnAdmissionTokenBySessionId = linkedMapOf<String, String>()

    @Volatile
    private var pqcEnabled: Boolean = true
    @Volatile
    private var handshakePolicyOverride: P2PHandshakePolicyOverride? = null

    private val _state = MutableStateFlow<State>(State.Idle)
    val state: StateFlow<State> = _state.asStateFlow()

    var onData: ((ByteArray) -> Unit)? = null

    private val _dataChannelConfigStatus =
        MutableStateFlow<WebRtcSession.DataChannelConfigStatus>(WebRtcSession.DataChannelConfigStatus.Unknown)
    val dataChannelConfigStatus: StateFlow<WebRtcSession.DataChannelConfigStatus> = _dataChannelConfigStatus.asStateFlow()
    private val _signalingStatus = MutableStateFlow(
        SignalingStatus(
            websocketUrl = signalingUrl,
            shard = signalingShard,
            lastEvent = "boot"
        )
    )
    val signalingStatus: StateFlow<SignalingStatus> = _signalingStatus.asStateFlow()

    // WebRTC app-layer crypto (derived from P2P v1 handshake over DataChannel)
    private var sessionKeys: com.skybridge.compass.shared.p2p.P2PHandshakeWire.DerivedSessionKeys? = null
    private var negotiatedSuite: com.skybridge.compass.shared.p2p.P2PCryptoSuite? = null

    private var initiatorHandshake: Pair<P2PHandshakeClient.InitiatorState, P2PHandshakeClient>? = null
    private var initiatorHandshakePhase: HandshakePhase? = null
    private var initiatorPendingMessageB: ByteArray? = null
    private var initiatorPendingResponderFinished: ByteArray? = null

    private var responderHandshake: Pair<P2PHandshakeServer.ResponderState, P2PHandshakeServer>? = null
    private var responderHandshakePhase: HandshakePhase? = null
    private var responderNegotiatedSuite: com.skybridge.compass.shared.p2p.P2PCryptoSuite? = null

    private var pairingExchangeSent: Boolean = false
    private var rekeyInProgress: Boolean = false
    private var rekeyAttempted: Boolean = false
    private var appHeartbeatTask: Job? = null
    private var lastSentPairingExchangeFingerprint: String? = null

    private val inboundFrames = FramedDataChannelStream()
    private val sendLock = Any()

    private enum class HandshakePhase { INITIAL, REKEY }

    init {
        bindSignalingCallbacks()
        signaling.connect()
    }

    fun setPqcEnabled(enabled: Boolean) {
        pqcEnabled = enabled
    }

    fun setHandshakePolicyOverride(policy: P2PHandshakePolicyOverride?) {
        handshakePolicyOverride = policy
    }

    fun setLocalDeviceId(id: String) {
        localId = id
    }

    suspend fun generateConnectionCode(): String {
        val net = loadNetworkSettings()
        require(net.webrtcEnabled) { "WebRTC disabled in settings" }
        updateSignalingStatus(sessionId = null, lastEvent = "register-code start")

        val localBinding = currentPathLocalBinding()
        val lease = signalServerClient(net.webrtcSignalingUrl).registerConnectionCode(
            binding = localBinding,
            localIdentity = localIdentity,
            deviceName = localIdentity.deviceName(),
            validDurationSeconds = 600
        )
        validateCurrentPathOrigin(lease.signalingServerOrigin, net.webrtcSignalingUrl)
        updateSignalingStatus(sessionId = lease.sessionId, lastEvent = "register-code ok")

        val sessionId = requireNotNull(normalizeCode(lease.sessionId)) {
            "Invalid connection code lease"
        }

        prepareForSessionStart(sessionId)
        webrtcSignalingAuthTokenBySessionId[sessionId] = lease.initiatorToken
        currentPathSignalingOriginBySessionId[sessionId] = lease.signalingServerOrigin
        currentPathTurnAdmissionTokenBySessionId[sessionId] = lease.turnAdmissionToken
        currentPathExpectedRemoteAuthorityBySessionId.remove(sessionId)

        runCatching {
            startOffererSession(sessionId, net)
        }.onFailure {
            clearSessionSecurity(sessionId)
            _state.value = State.Failed(sessionId, it.message ?: "generateConnectionCode failed")
            updateSignalingStatus(sessionId = sessionId, lastEvent = "failed: ${it.message ?: "generateConnectionCode"}")
            throw it
        }

        return lease.code
    }

    fun startOfferer(code: String) {
        val sessionId = normalizeCode(code)
        if (sessionId == null) {
            _state.value = State.Failed(null, "Invalid connection code")
            updateSignalingStatus(sessionId = null, lastEvent = "invalid connection code")
            return
        }
        scope.launch {
            runCatching {
                val token = webrtcSignalingAuthTokenBySessionId[sessionId]
                require(!token.isNullOrBlank()) { "Connection code must be server-issued" }
                val net = loadNetworkSettings()
                require(net.webrtcEnabled) { "WebRTC disabled in settings" }
                prepareForSessionStart(sessionId)
                startOffererSession(sessionId, net)
            }.onFailure {
                println("SB-WEBRTC startOfferer failure\n${it.stackTraceToString()}")
                _state.value = State.Failed(sessionId, it.message ?: "startOfferer failed")
                updateSignalingStatus(sessionId = sessionId, lastEvent = "failed: ${it.message ?: "startOfferer"}")
            }
        }
    }

    fun startAnswerer(code: String) {
        val sessionId = normalizeCode(code)
        if (sessionId == null) {
            _state.value = State.Failed(null, "Invalid connection code")
            updateSignalingStatus(sessionId = null, lastEvent = "invalid connection code")
            return
        }
        _state.value = State.Connecting(sessionId)
        scope.launch {
            runCatching {
                val net = loadNetworkSettings()
                require(net.webrtcEnabled) { "WebRTC disabled in settings" }
                updateSignalingStatus(sessionId = sessionId, lastEvent = "lookup start")

                val localBinding = currentPathLocalBinding()
                val lookup = signalServerClient(net.webrtcSignalingUrl).lookupConnectionCode(
                    code = sessionId,
                    binding = localBinding,
                    localIdentity = localIdentity
                )
                validateCurrentPathOrigin(lookup.signalingServerOrigin, net.webrtcSignalingUrl)
                updateSignalingStatus(sessionId = sessionId, lastEvent = "lookup ok")

                prepareForSessionStart(sessionId)
                webrtcSignalingAuthTokenBySessionId[sessionId] = lookup.responderToken
                currentPathSignalingOriginBySessionId[sessionId] = lookup.signalingServerOrigin
                currentPathTurnAdmissionTokenBySessionId[sessionId] = lookup.turnAdmissionToken
                currentPathExpectedRemoteAuthorityBySessionId[sessionId] = CurrentPathRemoteAuthority(
                    deviceId = lookup.initiatorDeviceId,
                    protocolSigningAlgorithm = lookup.initiatorProtocolSigningAlgorithm,
                    protocolPublicKeyFingerprint = lookup.initiatorProtocolPublicKeyFingerprint,
                    deviceName = lookup.initiatorDeviceName
                )
                remoteSignalingId = lookup.initiatorDeviceId
                remoteDeviceId = lookup.initiatorDeviceId
                ensureAnswererSignalingPrimed(sessionId, net)
                updateSignalingStatus(sessionId = sessionId, lastEvent = "session start")
                startAnswererSession(sessionId, net)
            }.onFailure {
                println("SB-WEBRTC startAnswerer failure\n${it.stackTraceToString()}")
                clearSessionSecurity(sessionId)
                _state.value = State.Failed(sessionId, it.message ?: "startAnswerer failed")
                updateSignalingStatus(sessionId = sessionId, lastEvent = "failed: ${it.message ?: "startAnswerer"}")
            }
        }
    }

    fun disconnect() {
        scope.launch {
            resetConnection(recreateSignaling = true)
        }
    }

    fun release() {
        onData = null
        scope.launch {
            resetConnection(recreateSignaling = false)
            scope.cancel()
        }
    }

    /**
     * Send an application payload over WebRTC.
     * - If handshake keys are established: AES-GCM encrypt + SBP2 unwrap compatibility + 4B length framing.
     * - If not yet established: legacy raw send (still framed) for compatibility with in-progress handshake.
     */
    fun send(bytes: ByteArray): Boolean {
        val keys = sessionKeys
        val payload = if (keys != null) {
            val enc = AesGcmCombined.seal(keys.sendKey, bytes)
            TrafficPaddingP2.wrapIfEnabled(enc, "tx/webrtc")
        } else {
            bytes
        }
        return sendFramed(payload)
    }

    private fun sendHandshakeFrame(payload: ByteArray): Boolean {
        Log.i(
            "SB-HANDSHAKE",
            "send session=${currentSessionId ?: "-"} bytes=${payload.size} phase=${initiatorHandshakePhase ?: responderHandshakePhase ?: HandshakePhase.INITIAL}"
        )
        return sendFramed(payload)
    }

    private fun sendFramed(payload: ByteArray): Boolean {
        val s = session ?: return false
        val framed = ByteArray(4 + payload.size)
        val len = payload.size
        framed[0] = (len ushr 24).toByte()
        framed[1] = (len ushr 16).toByte()
        framed[2] = (len ushr 8).toByte()
        framed[3] = (len ushr 0).toByte()
        System.arraycopy(payload, 0, framed, 4, payload.size)

        // Match Pro release: chunk framed payload to avoid SCTP message-size rejection.
        val maxChunk = 16 * 1024
        synchronized(sendLock) {
            var offset = 0
            while (offset < framed.size) {
                val end = minOf(offset + maxChunk, framed.size)
                val chunk = framed.copyOfRange(offset, end)
                if (!s.send(chunk)) return false
                offset = end
            }
        }
        return true
    }

    /** Returns true when app-layer session keys are established (P2P handshake completed). */
    fun hasSessionKeys(): Boolean = sessionKeys != null

    /** Returns the currently negotiated app-layer suite, when the handshake has completed. */
    fun negotiatedSuiteName(): String? = negotiatedSuite?.name

    /** Returns true once the active app-layer session has been upgraded onto a PQC suite. */
    fun hasPqcSessionKeys(): Boolean = sessionKeys != null && (negotiatedSuite?.isPqc == true)

    /** Returns true once the current peer has published PQC bootstrap material into the local alias store. */
    fun hasBootstrappedPeerKemForCurrentPeer(): Boolean {
        val candidateIds = buildList {
            remoteDeviceId?.takeIf { it.isNotBlank() }?.let { add(it) }
            remoteSignalingId?.takeIf { it.isNotBlank() && it != remoteDeviceId }?.let { add(it) }
        }
        return candidateIds.any { peerId ->
            val peerKem = peerKemStore.load(peerId)
            peerKem.xWingPublicKey != null || peerKem.mlKem768PublicKey != null
        }
    }

    fun debugKickoffHandshakeNow() {
        val activeSession = session ?: return
        if (!activeSession.isDataChannelOpen()) {
            Log.i(
                "SB-HANDSHAKE",
                "debugKickoff skipped session=${activeSession.sessionId} reason=datachannel_not_open"
            )
            return
        }
        Log.i(
            "SB-HANDSHAKE",
            "debugKickoff session=${activeSession.sessionId} role=${activeSession.role} hasKeys=${sessionKeys != null} initPending=${initiatorHandshake != null} respPending=${responderHandshake != null}"
        )
        scheduleHandshakeStart(activeSession.role)
    }

    /**
     * Compute a v1 MAC for merkleRootSignature:
     * HMAC-SHA256(key = sendKey, data = preimage).
     *
     * Backward compatible: callers may omit signature fields if keys are not available.
     */
    fun computeOutboundHmacSha256(preimage: ByteArray): ByteArray? {
        val keys = sessionKeys ?: return null
        return hmacSha256(keys.sendKey, preimage)
    }

    /**
     * Verify a v1 MAC for merkleRootSignature:
     * HMAC-SHA256(key = receiveKey, data = preimage) == mac.
     */
    fun verifyInboundHmacSha256(preimage: ByteArray, mac: ByteArray): Boolean {
        val keys = sessionKeys ?: return false
        val expected = hmacSha256(keys.receiveKey, preimage)
        return expected.contentEquals(mac)
    }

    private fun hmacSha256(key: ByteArray, data: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(data)
    }

    private suspend fun loadNetworkSettings(): NetworkSettings =
        networkSettingsOverrideProvider?.invoke()
            ?: NetworkSettingsStore.observe(appContext).first()

    private fun prepareForSessionStart(sessionId: String) {
        val previousSessionId = currentSessionId
        if (previousSessionId != null && previousSessionId != sessionId) {
            clearSessionSecurity(previousSessionId)
        }
        runCatching { session?.close() }
        session = null
        currentSessionId = sessionId
        sessionKeys = null
        negotiatedSuite = null
        initiatorHandshake = null
        initiatorHandshakePhase = null
        initiatorPendingMessageB = null
        initiatorPendingResponderFinished = null
        responderHandshake = null
        responderHandshakePhase = null
        responderNegotiatedSuite = null
        remoteSignalingId = null
        remoteDeviceId = null
        pairingExchangeSent = false
        rekeyInProgress = false
        rekeyAttempted = false
        inboundFrames.reset()
    }

    private suspend fun startOffererSession(sessionId: String, net: NetworkSettings) {
        prepareSession(sessionId = sessionId, net = net, role = WebRtcSession.Role.OFFERER)
        _state.value = State.Waiting(sessionId)
        sendSignalingEnvelope(
            WebRtcSignalingEnvelope(
                sessionId = sessionId,
                from = localId,
                type = WebRtcSignalingEnvelope.MessageType.JOIN,
                payload = null,
                sentAt = nowSeconds()
            )
        )
        updateSignalingStatus(sessionId = sessionId, lastEvent = "sent join")
    }

    private suspend fun startAnswererSession(sessionId: String, net: NetworkSettings) {
        prepareSession(sessionId = sessionId, net = net, role = WebRtcSession.Role.ANSWERER)
        sendSignalingEnvelope(
            WebRtcSignalingEnvelope(
                sessionId = sessionId,
                from = localId,
                type = WebRtcSignalingEnvelope.MessageType.JOIN,
                payload = null,
                sentAt = nowSeconds()
            )
        )
        updateSignalingStatus(sessionId = sessionId, lastEvent = "sent join")
    }

    private suspend fun ensureAnswererSignalingPrimed(sessionId: String, net: NetworkSettings) {
        ensureSignalingConfigured(net, sessionId)
        sendSignalingEnvelope(
            WebRtcSignalingEnvelope(
                sessionId = sessionId,
                from = localId,
                type = WebRtcSignalingEnvelope.MessageType.JOIN,
                payload = null,
                sentAt = nowSeconds()
            )
        )
        updateSignalingStatus(sessionId = sessionId, lastEvent = "sent early join")
    }

    private suspend fun prepareSession(
        sessionId: String,
        net: NetworkSettings,
        role: WebRtcSession.Role
    ) {
        ensureSignalingConfigured(net, sessionId)
        val ice = dynamicIceConfig()
        withContext(Dispatchers.Main.immediate) {
            updateSignalingStatus(sessionId = sessionId, lastEvent = "peerconnection create")
            val created = WebRtcSession(
                appContext = appContext,
                sessionId = sessionId,
                localDeviceId = localId,
                role = role,
                ice = ice
            )
            attachSessionCallbacks(created, sessionId)
            session = created
            _state.value = State.Connecting(sessionId)
            updateSignalingStatus(sessionId = sessionId, lastEvent = "peerconnection start")
            created.start()
        }
    }

    private fun currentPathLocalBinding(): ProtocolIdentityBinding {
        val signingKeys = localIdentity.getOrCreateProtocolSigningKeys()
        return ProtocolIdentityBinding(
            deviceId = localIdentity.deviceId(),
            protocolSigningAlgorithm = ProtocolSigningAlgorithm.ED25519,
            protocolPublicKeyBytes = signingKeys.ed25519PublicRaw32
        )
    }

    private fun signalServerClient(signalingEndpoint: String): SignalServerClient =
        SignalServerClient(
            baseUrlProvider = { controlPlaneBaseUrl(signalingEndpoint) },
            userAuthContextProvider = {
                userAuthContextProvider?.invoke() ?: authSessionStore.loadUserAuthContext()
            },
            clientVersionProvider = { resolvedClientVersion() },
            protocolVersionProvider = { resolvedProtocolVersion() }
        )

    private fun validateCurrentPathOrigin(rawOrigin: String, configuredSignalingUrl: String): String {
        val configuredOrigin = CurrentPathOriginPolicy.canonicalOrigin(controlPlaneBaseUrl(configuredSignalingUrl))
        val claimedOrigin = CurrentPathOriginPolicy.canonicalOrigin(rawOrigin)
        val allowSmokeLoopbackAlias =
            System.getProperty("skybridge.smoke.allowLoopbackOriginAlias") == "1"
        require(
            configuredOrigin == claimedOrigin ||
                (allowSmokeLoopbackAlias && originsEquivalentForSmoke(configuredOrigin, claimedOrigin))
        ) { "Invalid signaling origin" }
        return claimedOrigin
    }

    private fun originsEquivalentForSmoke(left: String, right: String): Boolean {
        val leftUri = runCatching { URI(left) }.getOrNull() ?: return false
        val rightUri = runCatching { URI(right) }.getOrNull() ?: return false
        if (!leftUri.scheme.equals(rightUri.scheme, ignoreCase = true)) return false

        fun normalizedPort(uri: URI): Int =
            when {
                uri.port >= 0 -> uri.port
                uri.scheme.equals("https", ignoreCase = true) -> 443
                else -> 80
            }

        val leftHost = leftUri.host?.lowercase() ?: return false
        val rightHost = rightUri.host?.lowercase() ?: return false
        if (normalizedPort(leftUri) != normalizedPort(rightUri)) return false

        val loopbackAliases = setOf("127.0.0.1", "localhost", "10.0.2.2")
        return leftHost in loopbackAliases && rightHost in loopbackAliases
    }

    private fun controlPlaneBaseUrl(signalingEndpoint: String): String {
        val uri = runCatching { URI(signalingEndpoint.trim()) }
            .getOrElse { throw IllegalArgumentException("invalid signaling base url") }
        val scheme = when (uri.scheme?.lowercase()) {
            "wss" -> "https"
            "ws" -> "http"
            "https", "http" -> uri.scheme.lowercase()
            else -> throw IllegalArgumentException("invalid signaling base url")
        }
        val host = uri.host ?: throw IllegalArgumentException("invalid signaling base url")
        val port = uri.port
        val includePort = when {
            port < 0 -> false
            scheme == "https" && port == 443 -> false
            scheme == "http" && port == 80 -> false
            else -> true
        }
        return if (includePort) {
            "$scheme://$host:$port"
        } else {
            "$scheme://$host"
        }
    }

    private suspend fun ensureSignalingConfigured(net: NetworkSettings, sessionId: String?) {
        val baseUrl = net.webrtcSignalingUrl.trim().ifBlank { SkyBridgeServerConfig.signalingWebSocketURL }
        val desiredShard = sessionId?.trim()?.takeIf { it.isNotEmpty() }
        val desired = signalingUrlWithShard(baseUrl, desiredShard)
        if (desired == signalingUrl && desiredShard == signalingShard) {
            updateSignalingStatus(sessionId = sessionId, lastEvent = "signaling route ready")
            return
        }
        runCatching { signaling.close() }
        signalingUrl = desired
        signalingShard = desiredShard
        signaling = WebSocketSignalingClient(wsUrlString = desired)
        bindSignalingCallbacks()
        signaling.connect()
        updateSignalingStatus(sessionId = sessionId, lastEvent = "signaling reconnect")
    }

    private suspend fun resetConnection(recreateSignaling: Boolean) {
        runCatching { session?.close() }
        session = null
        runCatching { signaling.close() }
        if (recreateSignaling) {
            signaling = WebSocketSignalingClient(wsUrlString = signalingUrl)
            bindSignalingCallbacks()
            signaling.connect()
        } else {
            signaling.onEnvelope = null
            signaling.onServerFrame = null
            signaling.onError = null
        }
        clearConnectionState()
    }

    private fun bindSignalingCallbacks() {
        signaling.onEnvelope = { env -> handleEnvelope(env) }
        signaling.onServerFrame = { frame -> handleServerFrame(frame) }
        signaling.onError = { throwable ->
            updateSignalingStatus(
                sessionId = currentSessionId,
                peerSignalingId = remoteSignalingId,
                lastEvent = "signaling error: ${throwable.message ?: "unknown"}"
            )
        }
    }

    private fun clearConnectionState() {
        clearSessionSecurity(currentSessionId)
        appHeartbeatTask?.cancel()
        appHeartbeatTask = null
        sessionKeys = null
        negotiatedSuite = null
        initiatorHandshake = null
        initiatorHandshakePhase = null
        initiatorPendingMessageB = null
        initiatorPendingResponderFinished = null
        responderHandshake = null
        responderHandshakePhase = null
        responderNegotiatedSuite = null
        lastSentPairingExchangeFingerprint = null
        currentSessionId = null
        remoteSignalingId = null
        remoteDeviceId = null
        signalingShard = null
        pairingExchangeSent = false
        rekeyInProgress = false
        rekeyAttempted = false
        inboundFrames.reset()
        _state.value = State.Idle
        updateSignalingStatus(sessionId = null, peerSignalingId = null, lastEvent = "idle")
    }

    private fun clearSessionSecurity(sessionId: String?) {
        if (sessionId == null) return
        webrtcSignalingAuthTokenBySessionId.remove(sessionId)
        currentPathExpectedRemoteAuthorityBySessionId.remove(sessionId)
        currentPathSignalingOriginBySessionId.remove(sessionId)
        currentPathTurnAdmissionTokenBySessionId.remove(sessionId)
    }

    private suspend fun dynamicIceConfig(): WebRtcSession.IceConfig {
        val net = loadNetworkSettings()
        val turnAdmissionToken = currentSessionId
            ?.let { sessionId -> currentPathTurnAdmissionTokenBySessionId[sessionId] }
        val creds = turnService.getCredentials(
            turnAdmissionToken = turnAdmissionToken,
            deviceId = localIdentity.deviceId()
        )
        val stunUrl = net.stunServers.firstOrNull()?.trim().orEmpty().ifBlank { SkyBridgeServerConfig.stunURL }
        val turnUrls = buildList {
            creds.uris.mapTo(this) { it.trim() }
            if (isEmpty()) {
                net.turnServers
                    .map(String::trim)
                    .filterTo(this) { it.isNotEmpty() }
            }
            if (isEmpty()) {
                addAll(SkyBridgeServerConfig.turnURLs)
            }
        }
        return WebRtcSession.IceConfig(
            stunUrl = stunUrl,
            turnUrls = turnUrls,
            turnUsername = creds.username,
            turnPassword = creds.password
        )
    }

    private fun attachSessionCallbacks(s: WebRtcSession, sessionId: String) {
        s.onLocalOffer = { sdp ->
            scope.launch {
                sendSignalingEnvelope(
                    WebRtcSignalingEnvelope(
                        sessionId = sessionId,
                        from = localId,
                        type = WebRtcSignalingEnvelope.MessageType.OFFER,
                        payload = WebRtcSignalingEnvelope.Payload(sdp = sdp),
                        sentAt = nowSeconds()
                    )
                )
                updateSignalingStatus(sessionId = sessionId, peerSignalingId = remoteSignalingId, lastEvent = "sent offer")
            }
        }
        s.onLocalAnswer = { sdp ->
            scope.launch {
                sendSignalingEnvelope(
                    WebRtcSignalingEnvelope(
                        sessionId = sessionId,
                        from = localId,
                        type = WebRtcSignalingEnvelope.MessageType.ANSWER,
                        payload = WebRtcSignalingEnvelope.Payload(sdp = sdp),
                        sentAt = nowSeconds()
                    )
                )
                updateSignalingStatus(sessionId = sessionId, peerSignalingId = remoteSignalingId, lastEvent = "sent answer")
            }
        }
        s.onLocalIceCandidate = { payload ->
            scope.launch {
                sendSignalingEnvelope(
                    WebRtcSignalingEnvelope(
                        sessionId = sessionId,
                        from = localId,
                        type = WebRtcSignalingEnvelope.MessageType.ICE_CANDIDATE,
                        payload = payload,
                        sentAt = nowSeconds()
                    )
                )
                updateSignalingStatus(sessionId = sessionId, peerSignalingId = remoteSignalingId, lastEvent = "sent iceCandidate")
            }
        }
        s.onData = { raw ->
            // Pro release framing: 4-byte big-endian length prefix; frames may be chunked across DC messages.
            for (frame in inboundFrames.push(raw)) {
                handleInboundFrame(sessionId, frame)
            }
        }
        s.onReady = {
            Log.i(
                "SB-HANDSHAKE",
                "onReady session=$sessionId role=${s.role} hasKeys=${sessionKeys != null} initPending=${initiatorHandshake != null} respPending=${responderHandshake != null}"
            )
            _state.value = State.Connected(sessionId)
            updateSignalingStatus(sessionId = sessionId, peerSignalingId = remoteSignalingId, lastEvent = "datachannel ready")
            scheduleHandshakeStart(s.role)
        }
        s.onDisconnected = { reason ->
            _state.value = State.Failed(sessionId, "WebRTC transport disconnected: $reason")
            updateSignalingStatus(
                sessionId = sessionId,
                peerSignalingId = remoteSignalingId,
                lastEvent = "transport disconnected: $reason"
            )
        }
        s.onDataChannelConfigStatus = { _dataChannelConfigStatus.value = it }
    }

    private fun authenticatedEnvelope(env: WebRtcSignalingEnvelope): WebRtcSignalingEnvelope {
        if (!env.authToken.isNullOrBlank()) return env
        val token = webrtcSignalingAuthTokenBySessionId[env.sessionId]
        require(!token.isNullOrBlank()) { "Missing signaling authorization" }
        return env.copy(authToken = token)
    }

    private suspend fun sendSignalingEnvelope(env: WebRtcSignalingEnvelope) {
        signaling.send(authenticatedEnvelope(env))
    }

    private fun handleServerFrame(frame: WebSocketSignalingClient.SignalingServerFrame) {
        val sessionId = frame.sessionId ?: currentSessionId
        val event = if (frame.isError) {
            "server error: ${frame.error ?: frame.type}"
        } else {
            "server frame: ${frame.type}"
        }
        updateSignalingStatus(
            sessionId = sessionId,
            peerSignalingId = remoteSignalingId,
            lastEvent = event
        )
        if (frame.isError && sessionId == currentSessionId) {
            _state.value = State.Failed(sessionId, frame.error ?: frame.type)
        }
    }

    private fun handleInboundFrame(sessionId: String, frame: ByteArray) {
        val traffic = TrafficPaddingP2.unwrapIfNeeded(frame, "rx/webrtc")

        val keys = sessionKeys
        if (keys != null) {
            // Decrypt-first (safer): only treat non-decryptable frames as handshake/control.
            val plain = runCatching { AesGcmCombined.open(keys.receiveKey, traffic) }.getOrNull()
            if (plain != null) {
                val app = runCatching { appMessageCodec.decode(plain) }.getOrNull()
                if (app is AppMessage.PairingIdentityExchange) {
                    Log.i(
                        "SB-WEBRTC",
                        "pairingExchangeRecv session=$sessionId deviceId=${app.payload.deviceId} keys=${app.payload.kemPublicKeys.size}"
                    )
                    handlePairingIdentityExchange(app.payload)
                    return
                }
                if (app is AppMessage.Heartbeat) {
                    Log.i(
                        "SB-WEBRTC",
                        "heartbeatRecv session=$sessionId formats=${app.payload.remoteVideoFormats?.joinToString(",") ?: "-"}"
                    )
                }
                if (app == null && System.getProperty("skybridge.smoke.keepAliveHeartbeat") == "1") {
                    val previewBytes = plain.take(96).toByteArray()
                    val preview = runCatching { previewBytes.decodeToString() }
                        .getOrElse { previewBytes.joinToString(separator = "") { "%02x".format(it) } }
                    Log.i(
                        "SB-WEBRTC",
                        "appDecodeNull session=$sessionId preview=$preview"
                    )
                }
                onData?.invoke(plain)
                return
            }
            if (System.getProperty("skybridge.smoke.keepAliveHeartbeat") == "1") {
                Log.i(
                    "SB-WEBRTC",
                    "decryptMiss session=$sessionId bytes=${traffic.size} hasKeys=true"
                )
            }
            handleHandshakeFrame(sessionId, traffic)
            return
        }

        // No keys yet: only handshake/control frames are meaningful.
        handleHandshakeFrame(sessionId, traffic)
    }

    private fun handleHandshakeFrame(sessionId: String, frame: ByteArray): Boolean {
        Log.i(
            "SB-HANDSHAKE",
            "recv session=$sessionId bytes=${frame.size} hasKeys=${sessionKeys != null} initPending=${initiatorHandshake != null} respPending=${responderHandshake != null}"
        )
        // Initiator handshake (initial or rekey): wait for MessageB + responder Finished, then send client Finished.
        val init = initiatorHandshake
        if (init != null) {
            val (st, client) = init
            if (isLikelyMessageA(frame)) {
                // Simultaneous open: if we should be responder, abandon initiator and respond.
                val local = localId
                val remote = remoteDeviceId ?: remoteSignalingId
                val shouldYield = when {
                    remote != null -> local > remote
                    session?.role == WebRtcSession.Role.OFFERER -> true
                    else -> false
                }
                if (shouldYield) {
                    initiatorHandshake = null
                    initiatorHandshakePhase = null
                    initiatorPendingMessageB = null
                    initiatorPendingResponderFinished = null
                    rekeyInProgress = false
                    // Continue below and treat this as inbound MessageA.
                } else {
                    return true
                }
            } else {
                if (isLikelyMessageB(frame)) {
                    initiatorPendingMessageB = frame
                } else if (isLikelyFinished(frame)) {
                    initiatorPendingResponderFinished = frame
                } else {
                    return false
                }

                val rawMessageB = initiatorPendingMessageB ?: return true
                val rawResponderFinished = initiatorPendingResponderFinished ?: return true
                val phase = initiatorHandshakePhase ?: HandshakePhase.INITIAL
                val messageB = runCatching { P2PHandshakeWire.decodeMessageB(rawMessageB) }.getOrElse { err ->
                    onHandshakeFailed(phase, sessionId, "messageB decode failed: ${err.message ?: "unknown"}")
                    return true
                }

                if (phase == HandshakePhase.INITIAL) {
                    runCatching {
                        validateCurrentPathRemoteAuthority(
                            sessionId = sessionId,
                            peerId = currentPeerId(),
                            identityPublicKeys = messageB.identityPublicKeys
                        )
                    }.onFailure { err ->
                        onHandshakeFailed(phase, sessionId, err.message ?: "current-path validation failed")
                        return true
                    }
                }

                val peerIdForTrust = currentPeerId()
                val currentAuthority = currentSessionId?.let(currentPathExpectedRemoteAuthorityBySessionId::get)
                val usePinnedTrustStore =
                    peerIdForTrust != null &&
                        currentAuthority?.protocolPublicKeyFingerprint.isNullOrBlank()
                val trustPeerId = peerIdForTrust?.takeIf { usePinnedTrustStore }
                val trustStore = if (usePinnedTrustStore) localIdentity.trustStore() else null
                val result = runCatching {
                    client.finish(
                        state = st,
                        rawMessageB = rawMessageB,
                        peerIdForTrust = trustPeerId,
                        trustStore = trustStore,
                        allowTrustOnFirstUse = false
                    )
                }.getOrElse { err ->
                    onHandshakeFailed(phase, sessionId, "handshake finish failed: ${err.message ?: "unknown"}")
                    return true
                }

                val okFinished = runCatching { client.verifyResponderFinished(rawResponderFinished, result.sessionKeys) }.getOrDefault(false)
                if (!okFinished) {
                    onHandshakeFailed(phase, sessionId, "responder finished MAC invalid")
                    return true
                }
                if (!sendHandshakeFrame(result.clientFinishedToSend)) {
                    onHandshakeFailed(phase, sessionId, "send client finished failed")
                    return true
                }

                onHandshakeEstablished(
                    keys = result.sessionKeys,
                    suite = result.negotiatedSuite,
                    phase = phase
                )
                return true
            }
        }

        // Responder handshake: wait for MessageA then send MessageB + responder Finished, then verify client Finished.
        val existingResponder = responderHandshake
        if (existingResponder == null) {
            if (!isLikelyMessageA(frame)) return false

            val phase = if (sessionKeys == null) HandshakePhase.INITIAL else HandshakePhase.REKEY
            responderHandshakePhase = phase
            val messageA = runCatching { P2PHandshakeWire.decodeMessageA(frame) }.getOrElse { err ->
                onHandshakeFailed(phase, sessionId, "messageA decode failed: ${err.message ?: "unknown"}")
                return true
            }

            if (phase == HandshakePhase.INITIAL) {
                runCatching {
                    validateCurrentPathRemoteAuthority(
                        sessionId = sessionId,
                        peerId = currentPeerId(),
                        identityPublicKeys = messageA.identityPublicKeys
                    )
                }.onFailure { err ->
                    onHandshakeFailed(phase, sessionId, err.message ?: "current-path validation failed")
                    return true
                }
            }

            val kem = localIdentity.getOrCreateKemIdentityKeys()
            val signKeys = localIdentity.getOrCreateProtocolSigningKeys()
            val protocolSigningKeys = P2PProtocolSigningKeys(
                ed25519PrivateKey = signKeys.ed25519PrivateKey,
                ed25519PublicKeyRaw32 = signKeys.ed25519PublicRaw32,
                mlDsa65PrivateKeyRaw = signKeys.mlDsa65PrivateKeyRaw,
                mlDsa65PublicKeyRaw = signKeys.mlDsa65PublicKeyRaw
            )

            val server = P2PHandshakeServer()
            val peerIdForTrust = currentPeerId()
            val policyOverride = effectivePolicyOverride()
            val currentAuthority = currentSessionId?.let(currentPathExpectedRemoteAuthorityBySessionId::get)
            val usePinnedTrustStore =
                peerIdForTrust != null &&
                    currentAuthority?.protocolPublicKeyFingerprint.isNullOrBlank()
            val trustPeerId = peerIdForTrust?.takeIf { usePinnedTrustStore }
            val trustStore = if (usePinnedTrustStore) localIdentity.trustStore() else null
            val allowClassicBootstrap =
                peerIdForTrust != null &&
                    (
                        trustStore?.isPeerPinned(peerIdForTrust) == true ||
                            !currentAuthority?.protocolPublicKeyFingerprint.isNullOrBlank()
                    )
            val effectiveHandshakePolicy = policyOverride.forTrustedClassicBootstrap(
                enabled = allowClassicBootstrap
            )
            val resp = runCatching {
                server.respond(
                    rawMessageA = frame,
                    peerIdForTrust = trustPeerId,
                    trustStore = trustStore,
                    allowTrustOnFirstUse = false,
                    options = P2PHandshakeServer.RespondOptions(
                        platformVersion = Build.VERSION.RELEASE,
                        kemPrivateKeys = P2PHandshakeServer.KemPrivateKeys(
                            xWingPrivateKey = kem.xWingPrivateKey,
                            mlKem768PrivateKey = kem.mlKem768PrivateKey
                        ),
                        handshakePolicy = effectiveHandshakePolicy.toWirePolicy(),
                        allowClassicBootstrapForTrustedPeer = allowClassicBootstrap,
                        protocolSigningKeys = protocolSigningKeys
                    )
                )
            }.getOrElse { err ->
                onHandshakeFailed(phase, sessionId, "handshake respond failed: ${err.message ?: "unknown"}")
                return true
            }

            responderHandshake = resp.state to server
            responderNegotiatedSuite = runCatching {
                val msgB = P2PHandshakeWire.decodeMessageB(resp.messageBToSend)
                (msgB.selectedSuite as? com.skybridge.compass.shared.p2p.P2PCryptoSuiteId.Known)?.suite
            }.getOrNull()

            if (!sendHandshakeFrame(resp.messageBToSend)) {
                onHandshakeFailed(phase, sessionId, "send messageB failed")
                return true
            }
            val responderFinished = server.buildResponderFinished(resp.state.sessionKeys)
            if (!sendHandshakeFrame(responderFinished)) {
                onHandshakeFailed(phase, sessionId, "send responder finished failed")
                return true
            }
            return true
        } else {
            if (!isLikelyFinished(frame)) return false
            val (st, server) = existingResponder
            val phase = responderHandshakePhase ?: HandshakePhase.INITIAL
            val ok = runCatching { server.verifyClientFinished(frame, st.sessionKeys) }.getOrDefault(false)
            if (!ok) {
                onHandshakeFailed(phase, sessionId, "client finished MAC invalid")
                return true
            }
            val suite = responderNegotiatedSuite ?: negotiatedSuite
            onHandshakeEstablished(keys = st.sessionKeys, suite = suite, phase = phase)
            return true
        }
    }

    private fun validateCurrentPathRemoteAuthority(
        sessionId: String,
        peerId: String?,
        identityPublicKeys: P2PIdentityPublicKeys.Keys
    ) {
        val expected = currentPathExpectedRemoteAuthorityBySessionId[sessionId] ?: return
        if (peerId != null) {
            require(peerId == expected.deviceId) {
                "Unexpected remote deviceId: expected ${expected.deviceId}, got $peerId"
            }
        }
        val actualAlgorithm = ProtocolSigningAlgorithm.fromIdentityAlgorithm(identityPublicKeys.protocolAlgorithm)
            ?: throw IllegalArgumentException("Unsupported current-path signing algorithm")
        require(actualAlgorithm == expected.protocolSigningAlgorithm) {
            "Unexpected remote signing algorithm"
        }
        val actualFingerprint = ProtocolIdentityBinding.computeFingerprint(
            algorithm = actualAlgorithm,
            publicKeyBytes = identityPublicKeys.protocolPublicKey
        )
        require(actualFingerprint.equals(expected.protocolPublicKeyFingerprint, ignoreCase = true)) {
            "Remote signing fingerprint mismatch"
        }
    }

    private fun persistCurrentPathTrust(sessionId: String) {
        val authority = currentPathExpectedRemoteAuthorityBySessionId[sessionId] ?: return
        localIdentity.trustedPeerStore().upsertCurrentPathAuthority(
            deviceId = authority.deviceId,
            name = authority.deviceName ?: authority.deviceId,
            protocolSigningAlgorithm = authority.protocolSigningAlgorithm.rawValue,
            protocolPublicKeyFingerprint = authority.protocolPublicKeyFingerprint,
            aliasIds = buildSet {
                add(authority.deviceId)
                remoteDeviceId?.let { add(it) }
                remoteSignalingId?.let { add(it) }
            }
        )
    }

    private fun persistTrustedAliasFromPairingExchange(
        declaredDeviceId: String,
        payload: AppMessage.PairingIdentityExchangePayload,
        priorPeerId: String?
    ) {
        val aliasIds = buildSet {
            add(declaredDeviceId)
            priorPeerId?.let { add(it) }
            remoteSignalingId?.let { add(it) }
        }
        val trustedPeerStore = localIdentity.trustedPeerStore()
        val existingRecord = aliasIds
            .asSequence()
            .mapNotNull { trustedPeerStore.findByKnownDeviceId(it) }
            .firstOrNull()
        val currentAuthority = currentSessionId?.let(currentPathExpectedRemoteAuthorityBySessionId::get)
        val fingerprint = existingRecord?.protocolPublicKeyFingerprint
            ?: aliasIds
                .asSequence()
                .mapNotNull { aliasId -> localIdentity.trustStore().loadPeerSigningFingerprint(aliasId) }
                .firstOrNull()
            ?: currentAuthority?.protocolPublicKeyFingerprint
            ?: return
        val algorithm = existingRecord?.protocolSigningAlgorithm
            ?: currentAuthority?.protocolSigningAlgorithm?.rawValue
        val displayName = payload.deviceName?.trim()?.takeIf { it.isNotEmpty() }
            ?: currentAuthority?.deviceName

        trustedPeerStore.upsertCurrentPathAuthority(
            deviceId = declaredDeviceId,
            name = displayName,
            protocolSigningAlgorithm = algorithm,
            protocolPublicKeyFingerprint = fingerprint,
            aliasIds = aliasIds
        )
    }

    private fun onHandshakeEstablished(
        keys: com.skybridge.compass.shared.p2p.P2PHandshakeWire.DerivedSessionKeys,
        suite: com.skybridge.compass.shared.p2p.P2PCryptoSuite?,
        phase: HandshakePhase
    ) {
        Log.i("SB-HANDSHAKE", "established session=${currentSessionId ?: "-"} suite=${suite?.name ?: "unknown"} phase=$phase")
        sessionKeys = keys
        negotiatedSuite = suite
        initiatorHandshake = null
        initiatorHandshakePhase = null
        initiatorPendingMessageB = null
        initiatorPendingResponderFinished = null
        responderHandshake = null
        responderHandshakePhase = null
        responderNegotiatedSuite = null

        if (phase == HandshakePhase.REKEY) {
            rekeyInProgress = false
        }
        currentSessionId?.let(::persistCurrentPathTrust)
        updateSignalingStatus(
            sessionId = currentSessionId,
            peerSignalingId = remoteSignalingId,
            lastEvent = "handshake established: ${suite?.name ?: "unknown"}"
        )

        // Best-effort: proactively send pairingIdentityExchange (helps PQC bootstrap).
        scope.launch { sendPairingIdentityExchangeIfNeeded(force = false) }
        startAppHeartbeatLoop()

        // After classic bootstrap, attempt a PQC rekey if peer KEM keys are already available.
        scope.launch { maybeStartPqcRekey(trigger = "post_handshake") }
    }

    private fun onHandshakeFailed(phase: HandshakePhase, sessionId: String, message: String) {
        Log.e("SB-HANDSHAKE", "failed session=$sessionId phase=$phase message=$message")
        updateSignalingStatus(
            sessionId = sessionId,
            peerSignalingId = remoteSignalingId,
            lastEvent = "handshake failed: $message"
        )
        // Initial handshake failures are fatal; rekey failures should keep the existing session keys.
        if (phase == HandshakePhase.REKEY) {
            initiatorHandshake = null
            initiatorHandshakePhase = null
            initiatorPendingMessageB = null
            initiatorPendingResponderFinished = null
            responderHandshake = null
            responderHandshakePhase = null
            responderNegotiatedSuite = null
            rekeyInProgress = false
            return
        }
        _state.value = State.Failed(sessionId, message)
    }

    private fun handlePairingIdentityExchange(payload: AppMessage.PairingIdentityExchangePayload) {
        scope.launch {
            processIncomingPairingIdentityExchange(payload)
        }
    }

    private suspend fun processIncomingPairingIdentityExchange(payload: AppMessage.PairingIdentityExchangePayload) {
        val priorPeerId = currentPeerId()
        val peerId = payload.deviceId.ifBlank { priorPeerId } ?: return
        val aliasIds = buildSet {
            add(peerId)
            priorPeerId?.let { add(it) }
            remoteSignalingId?.let { add(it) }
        }
        val trustedPeerStore = localIdentity.trustedPeerStore()
        val existingRecord = aliasIds
            .asSequence()
            .mapNotNull { trustedPeerStore.findByKnownDeviceId(it) }
            .firstOrNull()
        val currentAuthority = currentSessionId?.let(currentPathExpectedRemoteAuthorityBySessionId::get)
        val fingerprint = existingRecord?.protocolPublicKeyFingerprint
            ?: aliasIds
                .asSequence()
                .mapNotNull { aliasId -> localIdentity.trustStore().loadPeerSigningFingerprint(aliasId) }
                .firstOrNull()
            ?: currentAuthority?.protocolPublicKeyFingerprint
        val conflict = fingerprint?.let {
            trustedPeerStore.evaluateCurrentPathBinding(
                deviceId = peerId,
                protocolPublicKeyFingerprint = it
            )
        }
        val alreadyTrusted = existingRecord != null ||
            aliasIds.any { aliasId -> localIdentity.trustStore().isPeerPinned(aliasId) }
        val request = PairingTrustRequest(
            peerId = priorPeerId ?: peerId,
            declaredDeviceId = peerId,
            deviceName = payload.deviceName ?: currentAuthority?.deviceName,
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

        remoteDeviceId = peerId
        peerKemStore.save(peerId, payload.kemPublicKeys)
        priorPeerId
            ?.takeIf { it != peerId }
            ?.let { aliasId -> peerKemStore.save(aliasId, payload.kemPublicKeys) }
        if (decision == PairingTrustDecision.TRUST_ALWAYS) {
            persistTrustedAliasFromPairingExchange(
                declaredDeviceId = peerId,
                payload = payload,
                priorPeerId = priorPeerId
            )
        }

        sendPairingIdentityExchangeIfNeeded(force = true)
        maybeStartPqcRekey(trigger = "pairing_identity_exchange")
    }

    private suspend fun sendPairingIdentityExchangeIfNeeded(force: Boolean) {
        if (!pqcEnabled) return
        if (sessionKeys == null) return
        val now = SwiftDateSeconds.now()
        val payload = localIdentity.buildPairingIdentityExchange(nowSwiftSeconds = now, platform = "Android")
        val payloadFingerprint = pairingExchangeFingerprint(payload)
        val payloadChanged = payloadFingerprint != lastSentPairingExchangeFingerprint
        if (pairingExchangeSent && !payloadChanged) return
        Log.i(
            "SB-WEBRTC",
            "pairingExchangeSend session=${currentSessionId ?: "-"} deviceId=${payload.deviceId} keys=${payload.kemPublicKeys.size} force=$force changed=$payloadChanged"
        )
        send(appMessageCodec.encode(AppMessage.PairingIdentityExchange(payload)))
        pairingExchangeSent = true
        lastSentPairingExchangeFingerprint = payloadFingerprint
    }

    private fun startAppHeartbeatLoop() {
        appHeartbeatTask?.cancel()
        appHeartbeatTask = scope.launch {
            val intervalMillis = if (System.getProperty("skybridge.smoke.keepAliveHeartbeat") == "1") {
                1_000L
            } else {
                2_000L
            }
            while (sessionKeys != null) {
                if (initiatorHandshake != null || responderHandshake != null) {
                    delay(250L)
                    continue
                }
                val heartbeat = AppMessage.Heartbeat(
                    AppMessage.HeartbeatPayload(
                        sentAt = SwiftDateSeconds.now(),
                        deviceId = localIdentity.deviceId(),
                        deviceName = localIdentity.deviceName(),
                        modelName = Build.MODEL,
                        platform = "Android",
                        osVersion = "Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})",
                        remoteVideoFormats = AndroidRemoteVideoFormats.supportedStreamingFormats()
                    )
                )
                val sent = send(appMessageCodec.encode(heartbeat))
                if (System.getProperty("skybridge.smoke.keepAliveHeartbeat") == "1") {
                    Log.i(
                        "SB-WEBRTC",
                        "smokeHeartbeat session=${currentSessionId ?: "-"} sent=$sent"
                    )
                }
                if (!sent) break
                delay(intervalMillis)
            }
        }
    }

    private suspend fun maybeStartPqcRekey(trigger: String) {
        if (!pqcEnabled) return
        if (rekeyInProgress || rekeyAttempted) return
        if (initiatorHandshake != null || responderHandshake != null) return
        if (sessionKeys == null) return
        val suite = negotiatedSuite ?: return
        if (suite.isPqc) return
        val localKem = localIdentity.getOrCreateKemIdentityKeys()
        if (localKem.xWingPublicKey == null && localKem.mlKem768PublicKey == null) return
        val peerId = currentPeerId() ?: return
        val peerKem = peerKemStore.load(peerId)
        if (peerKem.xWingPublicKey == null && peerKem.mlKem768PublicKey == null) return
        val shouldInitiate = shouldInitiatePqcRekey(
            localDeviceId = localIdentity.deviceId(),
            remoteDeviceId = peerId
        ) ?: return
        if (!shouldInitiate) return

        // Start a second handshake over the established channel (un-encrypted frames) to upgrade to PQC.
        rekeyInProgress = true
        rekeyAttempted = true
        startInitiatorHandshake(
            peerKemPublicKeys = P2PHandshakeClient.PeerKemPublicKeys(
                xWingPublicKey = peerKem.xWingPublicKey,
                mlKem768PublicKey = peerKem.mlKem768PublicKey
            ),
            phase = HandshakePhase.REKEY,
            trigger = trigger
        )
        if (initiatorHandshake == null) {
            rekeyInProgress = false
        }
    }

    private fun currentPeerId(): String? =
        remoteDeviceId ?: remoteSignalingId

    private fun pairingExchangeFingerprint(payload: AppMessage.PairingIdentityExchangePayload): String {
        val digest = MessageDigest.getInstance("SHA-256")
        digest.update(payload.deviceId.toByteArray(Charsets.UTF_8))
        payload.kemPublicKeys
            .sortedBy { it.suiteWireId }
            .forEach { key ->
                digest.update(key.suiteWireId.toString().toByteArray(Charsets.UTF_8))
                digest.update(key.publicKey)
            }
        payload.remoteVideoFormats
            ?.map { it.lowercase() }
            ?.sorted()
            ?.forEach { format ->
                digest.update(format.toByteArray(Charsets.UTF_8))
        }
        return Base64.encodeToString(digest.digest(), Base64.NO_WRAP)
    }

    private fun shouldInitiatePqcRekey(localDeviceId: String?, remoteDeviceId: String?): Boolean? {
        val local = canonicalPqcRekeyElectionDeviceId(localDeviceId) ?: return null
        val remote = canonicalPqcRekeyElectionDeviceId(remoteDeviceId) ?: return null
        if (local == remote) return null
        return local < remote
    }

    private fun canonicalPqcRekeyElectionDeviceId(raw: String?): String? {
        val trimmed = raw?.trim()?.lowercase()?.takeIf { it.isNotEmpty() } ?: return null
        if (trimmed.startsWith("webrtc-")) return null
        return trimmed
    }

    private fun effectivePolicyOverride(): P2PHandshakePolicyOverride {
        if (!pqcEnabled) {
            return P2PHandshakePolicyOverride(
                requirePqc = false,
                allowClassicFallback = true,
                minimumTierRaw = "classic",
                requireSecureEnclavePoP = false,
                providerTypeRaw = P2PHandshakeWire.PROVIDER_TYPE_CRYPTO_KIT_CLASSIC
            )
        }
        return handshakePolicyOverride ?: localIdentity.defaultHandshakePolicyOverride()
    }

    private fun startInitiatorHandshake(
        peerKemPublicKeys: P2PHandshakeClient.PeerKemPublicKeys,
        phase: HandshakePhase,
        trigger: String
    ) {
        if (initiatorHandshake != null || responderHandshake != null) return

        val peerId = currentPeerId()
        val peerKem = peerKemPublicKeys
        val policyOverride = effectivePolicyOverride()
        val currentAuthority = currentSessionId?.let(currentPathExpectedRemoteAuthorityBySessionId::get)
        val hasAuthoritativeCurrentPathIdentity =
            !currentAuthority?.protocolPublicKeyFingerprint.isNullOrBlank()
        val allowClassicBootstrap =
            phase == HandshakePhase.INITIAL &&
            peerId != null &&
                (
                    localIdentity.trustStore().isPeerPinned(peerId) ||
                        hasAuthoritativeCurrentPathIdentity
                )
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

        val client = localIdentity.handshakeClient(peerKem = peerKem, policy = effectiveHandshakePolicy)
        val bypassFallbackCooldown =
            System.getProperty("skybridge.smoke.ignoreClassicFallbackCooldown") == "1"
        Log.i(
            "SB-HANDSHAKE",
            "start session=${currentSessionId ?: "-"} phase=$phase trigger=$trigger peerId=${peerId ?: "-"} classicOnly=${!pqcEnabled} bootstrapClassic=$allowClassicBootstrap minTier=${effectiveHandshakePolicy.minimumTierRaw} requirePqc=${effectiveHandshakePolicy.requirePqc}"
        )
        updateSignalingStatus(
            sessionId = currentSessionId,
            peerSignalingId = remoteSignalingId,
            lastEvent = "handshake start: $phase/$trigger"
        )
        val (st, msgA) = runCatching {
            client.start(
                P2PHandshakeClient.StartOptions(
                    peerIdForFallbackCooldown = if (bypassFallbackCooldown) null else peerId,
                    fallbackCooldownStore = if (bypassFallbackCooldown) null else localIdentity.fallbackCooldownStore(),
                    peerKemPublicKeys = peerKem,
                    handshakePolicy = effectiveHandshakePolicy.toWirePolicy(),
                    allowClassicBootstrapForTrustedPeer = allowClassicBootstrap,
                    protocolSigningKeys = protocolSigningKeys
                )
            )
        }.getOrElse { err ->
            onHandshakeFailed(phase, session?.sessionId ?: "", "handshake start failed: ${err.message ?: "unknown"}")
            return
        }

        initiatorHandshake = st to client
        initiatorHandshakePhase = phase
        initiatorPendingMessageB = null
        initiatorPendingResponderFinished = null
        if (!sendHandshakeFrame(msgA)) {
            onHandshakeFailed(phase, session?.sessionId ?: "", "send messageA failed")
        }
    }

    private fun scheduleHandshakeStart(role: WebRtcSession.Role) {
        if (initiatorHandshake != null || responderHandshake != null) return

        // Prefer the answerer to initiate; offerer will initiate as a fallback (macOS is responder-only).
        val immediate = System.getProperty("skybridge.smoke.immediateHandshake") == "1"
        val baseDelayMs = if (immediate) 0L else if (role == WebRtcSession.Role.ANSWERER) 150L else 900L
        val jitterMs = if (immediate) 0L else SecureRandom().nextInt(200).toLong()
        Log.i("SB-HANDSHAKE", "schedule session=${currentSessionId ?: "-"} role=$role delayMs=${baseDelayMs + jitterMs} immediate=$immediate")
        updateSignalingStatus(
            sessionId = currentSessionId,
            peerSignalingId = remoteSignalingId,
            lastEvent = "handshake scheduled: ${baseDelayMs + jitterMs}ms"
        )
        scope.launch {
            delay(baseDelayMs + jitterMs)
            if (initiatorHandshake != null || responderHandshake != null) return@launch

            val peerId = currentPeerId()
            val peerKem = if (peerId != null) peerKemStore.load(peerId) else PeerKemKeyStore.PeerKemPublicKeys()
            startInitiatorHandshake(
                peerKemPublicKeys = P2PHandshakeClient.PeerKemPublicKeys(
                    xWingPublicKey = peerKem.xWingPublicKey,
                    mlKem768PublicKey = peerKem.mlKem768PublicKey
                ),
                phase = HandshakePhase.INITIAL,
                trigger = "datachannel_ready"
            )
        }
    }

    private fun isLikelyMessageA(data: ByteArray): Boolean =
        runCatching { P2PHandshakeWire.decodeMessageA(data) }.isSuccess

    private fun isLikelyMessageB(data: ByteArray): Boolean =
        runCatching { P2PHandshakeWire.decodeMessageB(data) }.isSuccess

    private fun isLikelyFinished(data: ByteArray): Boolean {
        if (data.size != 38 && HandshakePaddingP1.unwrapIfNeeded(data).size != 38) return false
        return runCatching { P2PHandshakeWire.decodeFinished(data) }.isSuccess
    }

    private class FramedDataChannelStream {
        private var buffer: ByteArray = ByteArray(32 * 1024)
        private var readPos: Int = 0
        private var writePos: Int = 0

        fun reset() {
            readPos = 0
            writePos = 0
        }

        fun push(chunk: ByteArray): List<ByteArray> {
            ensureCapacity(chunk.size)
            System.arraycopy(chunk, 0, buffer, writePos, chunk.size)
            writePos += chunk.size
            return drainFrames()
        }

        private fun ensureCapacity(additional: Int) {
            // First, compact if needed.
            if (readPos > 0 && (buffer.size - writePos) < additional) {
                val len = writePos - readPos
                System.arraycopy(buffer, readPos, buffer, 0, len)
                readPos = 0
                writePos = len
            }
            if (buffer.size - writePos >= additional) return
            var newSize = buffer.size
            while (newSize - writePos < additional) newSize *= 2
            buffer = buffer.copyOf(newSize)
        }

        private fun drainFrames(): List<ByteArray> {
            val out = ArrayList<ByteArray>()
            while (writePos - readPos >= 4) {
                val len =
                    ((buffer[readPos].toInt() and 0xFF) shl 24) or
                        ((buffer[readPos + 1].toInt() and 0xFF) shl 16) or
                        ((buffer[readPos + 2].toInt() and 0xFF) shl 8) or
                        ((buffer[readPos + 3].toInt() and 0xFF) shl 0)
                if (len <= 0 || len > 8_000_000) {
                    reset()
                    break
                }
                if (writePos - readPos < 4 + len) break
                val start = readPos + 4
                val end = start + len
                out.add(buffer.copyOfRange(start, end))
                readPos = end
                if (readPos == writePos) {
                    readPos = 0
                    writePos = 0
                }
            }
            // Compact when we have a lot of consumed bytes.
            if (readPos > 0 && readPos > buffer.size / 2) {
                val len = writePos - readPos
                System.arraycopy(buffer, readPos, buffer, 0, len)
                readPos = 0
                writePos = len
            }
            return out
        }
    }

    private fun handleEnvelope(env: WebRtcSignalingEnvelope) {
        if (env.from == localId) return
        val s = session ?: return
        if (env.sessionId != s.sessionId) return
        remoteSignalingId = env.from
        if (remoteDeviceId.isNullOrBlank()) {
            remoteDeviceId = env.from
        }
        updateSignalingStatus(
            sessionId = env.sessionId,
            peerSignalingId = env.from,
            lastEvent = "received ${env.type.name.lowercase()}"
        )

        when (env.type) {
            WebRtcSignalingEnvelope.MessageType.OFFER -> env.payload?.sdp?.let { s.setRemoteOffer(it) }
            WebRtcSignalingEnvelope.MessageType.ANSWER -> env.payload?.sdp?.let { s.setRemoteAnswer(it) }
            WebRtcSignalingEnvelope.MessageType.ICE_CANDIDATE -> {
                val p = env.payload ?: return
                val cand = p.candidate ?: return
                s.addRemoteIceCandidate(cand, p.sdpMid, p.sdpMLineIndex)
            }
            WebRtcSignalingEnvelope.MessageType.JOIN,
            WebRtcSignalingEnvelope.MessageType.LEAVE -> Unit
        }
    }

    private fun normalizeCode(code: String): String? {
        val normalized = code.uppercase().filter { it.isLetterOrDigit() }
        return normalized.takeIf { it.length in 6..16 }
    }

    private fun signalingUrlWithShard(baseUrl: String, shard: String?): String {
        val normalizedBase = baseUrl.trim().ifBlank { SkyBridgeServerConfig.signalingWebSocketURL }
        val normalizedShard = shard?.trim().takeIf { !it.isNullOrEmpty() } ?: return normalizedBase
        val uri = Uri.parse(normalizedBase)
        val builder = uri.buildUpon().clearQuery()
        val existingKeys = linkedSetOf<String>()
        for (name in uri.queryParameterNames) {
            if (name == "shard" || name == "st" || name == "cv" || name == "pv") continue
            if (!existingKeys.add(name)) continue
            uri.getQueryParameters(name).forEach { value ->
                builder.appendQueryParameter(name, value)
            }
        }
        builder.appendQueryParameter("shard", normalizedShard.uppercase())
        webrtcSignalingAuthTokenBySessionId[normalizedShard]
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?.let { builder.appendQueryParameter("st", it) }
        builder.appendQueryParameter("cv", resolvedClientVersion())
        builder.appendQueryParameter("pv", resolvedProtocolVersion())
        return builder.build().toString()
    }

    private fun resolvedClientVersion(): String =
        System.getProperty("skybridge.clientVersion")
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?: runCatching {
                appContext.packageManager.getPackageInfo(appContext.packageName, 0).versionName
            }.getOrNull()
                ?.trim()
                ?.takeIf { it.isNotEmpty() }
            ?: "1.0.0"

    private fun resolvedProtocolVersion(): String =
        System.getProperty("skybridge.protocolVersion")
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?: "1"

    private fun updateSignalingStatus(
        sessionId: String?,
        peerSignalingId: String? = remoteSignalingId,
        lastEvent: String
    ) {
        _signalingStatus.value = SignalingStatus(
            sessionId = sessionId,
            websocketUrl = signalingUrl,
            shard = signalingShard,
            peerSignalingId = peerSignalingId,
            lastEvent = lastEvent
        )
    }

    private fun nowSeconds(): Double = System.currentTimeMillis() / 1000.0

    private fun defaultDeviceId(): String =
        localIdentity.deviceId()

    private fun generateFallbackDeviceId(): String {
        val rnd = SecureRandom()
        val bytes = ByteArray(16)
        rnd.nextBytes(bytes)
        return bytes.joinToString(separator = "") { "%02x".format(it) }
    }
}
