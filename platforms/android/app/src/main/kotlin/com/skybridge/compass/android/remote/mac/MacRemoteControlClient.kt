package com.skybridge.compass.android.remote.mac

import android.content.Context
import android.util.Log
import com.skybridge.compass.core.p2p.LocalP2PIdentity
import com.skybridge.compass.core.p2p.PeerKemKeyStore
import com.skybridge.compass.core.p2p.P2PHandshakePolicyOverride
import com.skybridge.compass.core.p2p.isPeerPinned
import com.skybridge.compass.core.p2p.isMissingPqcMaterial
import com.skybridge.compass.core.p2p.toWirePolicy
import com.skybridge.compass.shared.crypto.AesGcmCombined
import com.skybridge.compass.shared.p2p.HandshakePaddingP1
import com.skybridge.compass.shared.p2p.P2PHandshakeClient
import com.skybridge.compass.shared.p2p.P2PProtocolSigningKeys
import com.skybridge.compass.shared.p2p.P2PHandshakeWire
import com.skybridge.compass.core.webrtc.AndroidRemoteVideoFormats
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import kotlin.time.Duration.Companion.seconds

class MacRemoteControlClient(
    appContext: Context,
    private val json: Json = Json {
        ignoreUnknownKeys = true
        explicitNulls = false
    }
) {
    private enum class HandshakePhase {
        WaitingMessageB,
        WaitingResponderFinished
    }

    private companion object {
        private const val TAG = "MacRemoteControlClient"
        private val SBP1_MAGIC = byteArrayOf(0x53, 0x42, 0x50, 0x31) // "SBP1"
        private const val MAX_FRAME_BYTES = 32_000_000
    }

    data class ConnectionTarget(
        val host: String,
        val port: Int = 5901,
        val displayName: String? = null,
        val deviceIdHint: String? = null,
        val advertisedFingerprint: String? = null
    )

    data class SecurityConfig(
        val encryptionRequired: Boolean = true,
        val allowPlaintextFallback: Boolean = false,
        val allowTrustOnFirstUse: Boolean = true,
        val handshakePolicyOverride: P2PHandshakePolicyOverride? = null
    )

    sealed class State {
        data object Disconnected : State()
        data class Connecting(val target: ConnectionTarget) : State()
        data class Connected(val target: ConnectionTarget) : State()
        data class Failed(val message: String) : State()
    }

    enum class TrustState {
        TRUSTED_NEW,
        TRUSTED_EXISTING,
        UNTRUSTED_EPHEMERAL
    }

    sealed class SecurityState {
        data object Disconnected : SecurityState()
        data class Negotiating(val peerId: String?, val pinned: Boolean) : SecurityState()
        data class Secure(
            val peerId: String?,
            val fingerprint: String?,
            val suite: String,
            val trustState: TrustState
        ) : SecurityState()

        data class Plaintext(val peerId: String?, val reason: String) : SecurityState()
        data class Failed(val peerId: String?, val reason: String) : SecurityState()
    }

    data class Frame(
        val width: Int,
        val height: Int,
        val format: String?,
        val timestamp: Double,
        val imageBytes: ByteArray
    )

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private val _state = MutableStateFlow<State>(State.Disconnected)
    val state: StateFlow<State> = _state.asStateFlow()

    private val _latestFrame = MutableStateFlow<Frame?>(null)
    val latestFrame: StateFlow<Frame?> = _latestFrame.asStateFlow()

    private val _securityState = MutableStateFlow<SecurityState>(SecurityState.Disconnected)
    val securityState: StateFlow<SecurityState> = _securityState.asStateFlow()

    private var socket: Socket? = null
    private var out: BufferedOutputStream? = null
    private var input: BufferedInputStream? = null
    private val writeLock = Any()
    private val localIdentity = LocalP2PIdentity(appContext.applicationContext)
    private val peerKemStore = PeerKemKeyStore(appContext.applicationContext)
    private var currentTarget: ConnectionTarget? = null
    private var securityConfig: SecurityConfig = SecurityConfig()

    // Optional: P2P v1 handshake + AES-GCM app-layer encryption over 5901 frames (backward compatible).
    private var handshakeClient: P2PHandshakeClient? = null
    private var handshakeState: P2PHandshakeClient.InitiatorState? = null
    private var handshakePhase: HandshakePhase? = null
    private var pendingSessionKeys: com.skybridge.compass.shared.p2p.P2PHandshakeWire.DerivedSessionKeys? = null
    private var sessionKeys: com.skybridge.compass.shared.p2p.P2PHandshakeWire.DerivedSessionKeys? = null
    private var pendingTrustState: TrustState? = null
    private var activePeerFingerprint: String? = null
    private var negotiatedSuiteName: String? = null
    @Volatile private var encryptedStreamConfigurationSent: Boolean = false

    private fun logHandshake(message: String) {
        Log.i(TAG, "LAN handshake: $message")
    }

    private fun logHandshakeWarn(message: String) {
        Log.w(TAG, "LAN handshake: $message")
    }

    fun connect(
        target: ConnectionTarget,
        enableHandshake: Boolean = true,
        securityConfig: SecurityConfig = SecurityConfig()
    ) {
        disconnect()
        this.currentTarget = target
        this.securityConfig = securityConfig
        logHandshake(
            "connect target=${target.host}:${target.port} handshake=$enableHandshake " +
                "requireSecure=${securityConfig.encryptionRequired} allowPlaintext=${securityConfig.allowPlaintextFallback} " +
                "peerHint=${peerIdHint() ?: "none"}"
        )
        _state.value = State.Connecting(target)
        _securityState.value = if (enableHandshake) {
            SecurityState.Negotiating(
                peerId = peerIdHint(),
                pinned = peerIdHint()?.let { localIdentity.trustStore().isPeerPinned(it) } == true
            )
        } else {
            SecurityState.Disconnected
        }

        scope.launch {
            try {
                val s = Socket()
                s.tcpNoDelay = true
                s.soTimeout = 0
                s.connect(InetSocketAddress(target.host, target.port), 10.seconds.inWholeMilliseconds.toInt())

                socket = s
                out = BufferedOutputStream(s.getOutputStream())
                input = BufferedInputStream(s.getInputStream())

                _state.value = State.Connected(target)
                if (!enableHandshake || !securityConfig.encryptionRequired) {
                    logHandshake("sending initial plaintext stream configuration")
                    sendInitialStreamConfigurationNow(encryptWith = null)
                }

                if (enableHandshake) {
                    startHandshake(target)
                } else if (!securityConfig.encryptionRequired) {
                    markPlaintext("handshake disabled")
                }
                readLoop()
            } catch (t: Throwable) {
                failConnection(t.message ?: "connect failed")
            }
        }
    }

    fun disconnect() {
        closeTransport()
        _latestFrame.value = null
        handshakeClient = null
        handshakeState = null
        handshakePhase = null
        pendingSessionKeys = null
        sessionKeys = null
        pendingTrustState = null
        activePeerFingerprint = null
        negotiatedSuiteName = null
        encryptedStreamConfigurationSent = false
        currentTarget = null
        _state.value = State.Disconnected
        _securityState.value = SecurityState.Disconnected
    }

    fun hasSecureChannel(): Boolean = sessionKeys != null

    fun sendMouseMove(x: Double, y: Double) = sendMouse(MouseEventType.MOUSE_MOVED, x, y)
    fun sendLeftDown(x: Double, y: Double) = sendMouse(MouseEventType.LEFT_MOUSE_DOWN, x, y)
    fun sendLeftUp(x: Double, y: Double) = sendMouse(MouseEventType.LEFT_MOUSE_UP, x, y)

    private fun sendMouse(type: MouseEventType, x: Double, y: Double) {
        val now = System.currentTimeMillis().toDouble() / 1000.0
        val evt = RemoteMouseEvent(type = type, x = x, y = y, timestamp = now)
        val payload = json.encodeToString(RemoteMouseEvent.serializer(), evt).encodeToByteArray()
        val msg = RemoteMessage(type = RemoteMessage.MessageType.MOUSE_EVENT, payload = payload)
        sendMessage(msg)
    }

    fun sendKeyDown(keyCode: Int) {
        val now = System.currentTimeMillis().toDouble() / 1000.0
        val evt = RemoteKeyboardEvent(type = KeyboardEventType.KEY_DOWN, keyCode = keyCode, timestamp = now)
        val payload = json.encodeToString(RemoteKeyboardEvent.serializer(), evt).encodeToByteArray()
        val msg = RemoteMessage(type = RemoteMessage.MessageType.KEYBOARD_EVENT, payload = payload)
        sendMessage(msg)
    }

    fun sendKeyUp(keyCode: Int) {
        val now = System.currentTimeMillis().toDouble() / 1000.0
        val evt = RemoteKeyboardEvent(type = KeyboardEventType.KEY_UP, keyCode = keyCode, timestamp = now)
        val payload = json.encodeToString(RemoteKeyboardEvent.serializer(), evt).encodeToByteArray()
        val msg = RemoteMessage(type = RemoteMessage.MessageType.KEYBOARD_EVENT, payload = payload)
        sendMessage(msg)
    }

    private fun sendMessage(msg: RemoteMessage) {
        scope.launch {
            try {
                sendEncodedMessageNow(msg = msg, encryptWith = sessionKeys)
            } catch (_: Throwable) {
                // ignore; readLoop will transition state on disconnect
            }
        }
    }

    private fun readLoop() {
        val ins = input ?: return
        val header = ByteArray(4)
        while (true) {
            val readHeader = readFully(ins, header)
            if (!readHeader) throw IllegalStateException("connection closed")
            val len = ByteBuffer.wrap(header).order(ByteOrder.BIG_ENDIAN).int
            require(len > 0 && len <= MAX_FRAME_BYTES) { "invalid frame length: $len" }

            val payload = ByteArray(len)
            val ok = readFully(ins, payload)
            if (!ok) throw IllegalStateException("connection closed")

            runCatching { handleInboundFrame(payload) }
                .onFailure { err ->
                    failConnection("inbound frame handling failed: ${err.message ?: err.javaClass.simpleName}")
                    return
                }
        }
    }

    private fun handleInboundFrame(frameBytes: ByteArray) {
        if (handshakePhase != null) {
            logHandshake(
                "rx frame bytes=${frameBytes.size} phase=${handshakePhase?.name} " +
                    "looksHandshake=${looksLikeHandshakeFrame(frameBytes)} looksJson=${looksLikeJson(frameBytes)} " +
                    "pendingKeys=${pendingSessionKeys != null} sessionKeys=${sessionKeys != null}"
            )
        }

        // 1) If handshake established, try decrypt frames first.
        sessionKeys?.let { keys ->
            val plain = runCatching { AesGcmCombined.open(keys.receiveKey, frameBytes) }.getOrNull()
            if (plain != null) {
                tryHandleRemoteJsonFrame(plain)
                return
            }

            // Transition tolerance: server may still send legacy plaintext JSON briefly.
            if (looksLikeJson(frameBytes)) {
                markPlaintext("received plaintext frame after secure channel")
                tryHandleRemoteJsonFrame(frameBytes)
                return
            }
        }

        // 2) If handshake is in progress, accept interleaved screen frames without aborting handshake.
        val hsClient = handshakeClient
        val phase = handshakePhase
        if (hsClient != null && phase != null) {
            if (looksLikeHandshakeFrame(frameBytes)) {
                when (phase) {
                    HandshakePhase.WaitingMessageB -> {
                        val hsState = handshakeState ?: return
                        val trustState = verifyOrPersistPeerTrust(frameBytes) ?: return
                        runCatching {
                            val res = hsClient.finish(
                                state = hsState,
                                rawMessageB = frameBytes,
                                peerIdForTrust = null,
                                trustStore = null
                            )
                            pendingSessionKeys = res.sessionKeys
                            pendingTrustState = trustState
                            negotiatedSuiteName = res.negotiatedSuite.name
                            logHandshake(
                                "verified MessageB suite=${res.negotiatedSuite.name} " +
                                    "fingerprint=${activePeerFingerprint ?: "unknown"} trust=$trustState"
                            )
                            handshakeState = null
                            handshakePhase = HandshakePhase.WaitingResponderFinished
                            sendRawFrame(res.clientFinishedToSend)
                            logHandshake("sent client Finished bytes=${res.clientFinishedToSend.size}")
                        }.onFailure {
                            handleHandshakeFailure("messageB verify failed: ${it.message ?: "unknown"}")
                        }
                        return
                    }
                    HandshakePhase.WaitingResponderFinished -> {
                        val pendingKeys = pendingSessionKeys ?: return
                        val ok = runCatching { hsClient.verifyResponderFinished(frameBytes, pendingKeys) }
                            .getOrNull() == true
                        if (ok) {
                            val trustState = pendingTrustState ?: TrustState.UNTRUSTED_EPHEMERAL
                            sessionKeys = pendingKeys
                            clearHandshakeState(keepSessionKeys = true)
                            _securityState.value = SecurityState.Secure(
                                peerId = peerIdHint(),
                                fingerprint = activePeerFingerprint,
                                suite = negotiatedSuiteName ?: "unknown",
                                trustState = trustState
                            )
                            logHandshake("responder Finished verified; secure channel established suite=${negotiatedSuiteName ?: "unknown"}")
                            sendEncryptedStreamConfigurationIfNeeded()
                        } else {
                            // Not a valid finished frame (or not finished at all). Ignore and continue.
                            logHandshake("ignored handshake-like frame while waiting responder Finished")
                        }
                        return
                    }
                }
            }

            // Not a handshake frame: if we already derived pending keys, the server may have
            // switched to encrypted frames before we observe responder-finished.
            if (phase == HandshakePhase.WaitingResponderFinished) {
                val pendingKeys = pendingSessionKeys
                if (pendingKeys != null) {
                    val decrypted = runCatching { AesGcmCombined.open(pendingKeys.receiveKey, frameBytes) }.getOrNull()
                    if (decrypted != null && looksLikeJson(decrypted)) {
                        val trustState = pendingTrustState ?: TrustState.UNTRUSTED_EPHEMERAL
                        sessionKeys = pendingKeys
                        clearHandshakeState(keepSessionKeys = true)
                        _securityState.value = SecurityState.Secure(
                            peerId = peerIdHint(),
                            fingerprint = activePeerFingerprint,
                            suite = negotiatedSuiteName ?: "unknown",
                            trustState = trustState
                        )
                        logHandshake("secure channel inferred from early encrypted business frame suite=${negotiatedSuiteName ?: "unknown"}")
                        sendEncryptedStreamConfigurationIfNeeded()
                        tryHandleRemoteJsonFrame(decrypted)
                        return
                    }
                }
            }

            // Legacy plaintext JSON (server did not enable handshake/encryption).
            if (looksLikeJson(frameBytes) && canAcceptPlaintext()) {
                markPlaintext("server stayed on plaintext transport")
                tryHandleRemoteJsonFrame(frameBytes)
            } else if (looksLikeJson(frameBytes)) {
                handleHandshakeFailure("plaintext remote payload rejected by security policy")
            } else {
                logHandshake("ignored non-handshake non-json frame during negotiation bytes=${frameBytes.size}")
            }
            return
        }

        // 3) Legacy plaintext
        if (looksLikeJson(frameBytes) && canAcceptPlaintext()) {
            markPlaintext("legacy plaintext transport")
            tryHandleRemoteJsonFrame(frameBytes)
        } else if (looksLikeJson(frameBytes)) {
            failConnection("plaintext remote payload rejected by security policy")
        }
    }

    private fun clearHandshakeState(keepSessionKeys: Boolean = false) {
        handshakeClient = null
        handshakeState = null
        handshakePhase = null
        pendingSessionKeys = null
        pendingTrustState = null
        if (!keepSessionKeys) {
            sessionKeys = null
        }
    }

    private fun looksLikeJson(bytes: ByteArray): Boolean =
        bytes.isNotEmpty() && bytes[0] == '{'.code.toByte()

    private fun looksLikeHandshakeFrame(bytes: ByteArray): Boolean {
        if (bytes.size < 4) return false
        for (i in 0 until 4) {
            if (bytes[i] != SBP1_MAGIC[i]) return false
        }
        return true
    }

    private fun tryHandleRemoteJsonFrame(jsonBytes: ByteArray) {
        runCatching {
            val msg = json.decodeFromString(RemoteMessage.serializer(), jsonBytes.decodeToString())
            if (msg.type != RemoteMessage.MessageType.SCREEN_DATA) return@runCatching
            val screen = json.decodeFromString(ScreenData.serializer(), msg.payload.decodeToString())
            if (screen.imageData.isEmpty()) return@runCatching
            val normalizedFormat = AndroidRemoteVideoFormats.normalizeIncomingFormat(
                format = screen.format,
                payload = screen.imageData
            ) ?: return@runCatching

            _latestFrame.value = Frame(
                width = screen.width,
                height = screen.height,
                format = normalizedFormat,
                timestamp = screen.timestamp,
                imageBytes = screen.imageData
            )
        }
    }

    private fun sendRawFrame(payload: ByteArray) {
        val os = out ?: return
        if (handshakePhase != null && looksLikeHandshakeFrame(payload)) {
            logHandshake("tx handshake frame bytes=${payload.size} phase=${handshakePhase?.name}")
        }
        synchronized(writeLock) {
            val header = ByteBuffer.allocate(4).order(ByteOrder.BIG_ENDIAN).putInt(payload.size).array()
            os.write(header)
            os.write(payload)
            os.flush()
        }
    }

    private fun sendEncodedMessageNow(
        msg: RemoteMessage,
        encryptWith: com.skybridge.compass.shared.p2p.P2PHandshakeWire.DerivedSessionKeys?
    ) {
        val os = out ?: return
        val plain = json.encodeToString(RemoteMessage.serializer(), msg).encodeToByteArray()
        val bytes = encryptWith?.let { keys ->
            AesGcmCombined.seal(keys.sendKey, plain)
        } ?: plain
        synchronized(writeLock) {
            val header = ByteBuffer.allocate(4).order(ByteOrder.BIG_ENDIAN).putInt(bytes.size).array()
            os.write(header)
            os.write(bytes)
            os.flush()
        }
    }

    private fun sendInitialStreamConfigurationNow(
        encryptWith: com.skybridge.compass.shared.p2p.P2PHandshakeWire.DerivedSessionKeys?
    ) {
        val supportedFormats = AndroidRemoteVideoFormats.supportedStreamingFormats()
        val config = RemoteDesktopStreamConfiguration(
            preferredCodec = AndroidRemoteVideoFormats.preferredStreamingCodec(),
            supportedVideoFormats = supportedFormats,
            adaptiveResolutionEnabled = true,
            targetFrameRate = if (supportedFormats.firstOrNull() == AndroidRemoteVideoFormats.JPEG) 20 else 30,
            keyFrameInterval = 30,
            lowLatencyMode = supportedFormats.any { it == AndroidRemoteVideoFormats.H264 || it == AndroidRemoteVideoFormats.HEVC },
            enableHardwareAcceleration = supportedFormats.any { it == AndroidRemoteVideoFormats.H264 || it == AndroidRemoteVideoFormats.HEVC },
            enableAppleSiliconOptimization = false,
            clipboardSyncEnabled = false,
            damageTrackingEnabled = true,
            separateCursorChannelEnabled = false,
            interactionOverlayChannelEnabled = false,
            refreshStrategy = "adaptive",
            lossRecoveryMode = "none",
            sentAt = System.currentTimeMillis().toDouble() / 1000.0
        )
        val payload = json.encodeToString(
            RemoteDesktopStreamConfiguration.serializer(),
            config
        ).encodeToByteArray()
        sendEncodedMessageNow(
            msg = RemoteMessage(
                type = RemoteMessage.MessageType.STREAM_CONFIGURATION,
                payload = payload
            ),
            encryptWith = encryptWith
        )
    }

    private fun sendEncryptedStreamConfigurationIfNeeded() {
        val keys = sessionKeys ?: return
        if (encryptedStreamConfigurationSent) return
        encryptedStreamConfigurationSent = true
        runCatching {
            logHandshake("sending encrypted stream configuration")
            sendInitialStreamConfigurationNow(encryptWith = keys)
        }
    }

    private fun startHandshake(target: ConnectionTarget) {
        runCatching {
            val effectivePolicy = securityConfig.handshakePolicyOverride ?: localIdentity.defaultHandshakePolicyOverride()
            val peerIdHint = peerIdHint()
            val peerKem = peerIdHint?.let { peerKemStore.load(it) }
                ?: PeerKemKeyStore.PeerKemPublicKeys()
            val peerKemPublicKeys = P2PHandshakeClient.PeerKemPublicKeys(
                xWingPublicKey = peerKem.xWingPublicKey,
                mlKem768PublicKey = peerKem.mlKem768PublicKey
            )

            if (effectivePolicy.requirePqc && peerKemPublicKeys.isMissingPqcMaterial()) {
                error(
                    "missing peer KEM bootstrap for ${peerIdHint ?: target.host}; " +
                        "complete one trusted WebRTC/bootstrap run first"
                )
            }

            logHandshake(
                "start policy=requirePqc=${effectivePolicy.requirePqc} " +
                    "allowClassicFallback=${effectivePolicy.allowClassicFallback} " +
                    "minimumTier=${effectivePolicy.minimumTierRaw} pinned=${peerIdHint?.let { localIdentity.trustStore().isPeerPinned(it) } == true} " +
                    "peerKem[xwing=${peerKemPublicKeys.xWingPublicKey?.size ?: 0},mlkem=${peerKemPublicKeys.mlKem768PublicKey?.size ?: 0}]"
            )

            val client = localIdentity.handshakeClient(
                peerKem = peerKemPublicKeys,
                policy = effectivePolicy
            )
            val protocolSigningKeys = localIdentity.getOrCreateProtocolSigningKeys().let {
                P2PProtocolSigningKeys(
                    ed25519PrivateKey = it.ed25519PrivateKey,
                    ed25519PublicKeyRaw32 = it.ed25519PublicRaw32,
                    mlDsa65PrivateKeyRaw = it.mlDsa65PrivateKeyRaw,
                    mlDsa65PublicKeyRaw = it.mlDsa65PublicKeyRaw
                )
            }
            val (st, msgA) = client.start(
                P2PHandshakeClient.StartOptions(
                    peerIdForFallbackCooldown = peerIdHint,
                    fallbackCooldownStore = peerIdHint?.let { localIdentity.fallbackCooldownStore() },
                    peerKemPublicKeys = peerKemPublicKeys,
                    handshakePolicy = effectivePolicy.toWirePolicy(),
                    protocolSigningKeys = protocolSigningKeys
                )
            )
            handshakeClient = client
            handshakeState = st
            handshakePhase = HandshakePhase.WaitingMessageB
            pendingSessionKeys = null
            sessionKeys = null
            pendingTrustState = null
            activePeerFingerprint = target.advertisedFingerprint
            negotiatedSuiteName = null
            val decodedMessageA = P2PHandshakeWire.decodeMessageA(msgA)
            val msgAPreimageHash = MessageDigest.getInstance("SHA-256")
                .digest(P2PHandshakeWire.buildMessageASignaturePreimagePublic(msgA))
            logHandshake(
                "tx MessageA suites=${decodedMessageA.supportedSuites.joinToString(",") { it.wireId.toString(16) }} " +
                    "bytes=${msgA.size} sigBytes=${decodedMessageA.signature.size} " +
                    "pubBytes=${decodedMessageA.identityPublicKeys.protocolPublicKey.size} " +
                    "preimageSha256=${msgAPreimageHash.take(8).joinToString("") { "%02x".format(it) }}"
            )
            sendRawFrame(msgA) // handshake frames are already SBP1-wrapped
        }.onFailure {
            handleHandshakeFailure("handshake start failed: ${it.message ?: "unknown"}")
        }
    }

    private fun verifyOrPersistPeerTrust(frameBytes: ByteArray): TrustState? {
        val peerId = peerIdHint() ?: return TrustState.UNTRUSTED_EPHEMERAL
        return runCatching {
            val messageB = P2PHandshakeWire.decodeMessageB(frameBytes)
            val observedFingerprint = P2PHandshakeWire.computePeerSigningFingerprint(messageB.identityPublicKeys)
            val advertisedFingerprint = currentTarget?.advertisedFingerprint?.trim()?.lowercase()
            if (!advertisedFingerprint.isNullOrBlank() &&
                !advertisedFingerprint.equals(observedFingerprint, ignoreCase = true)
            ) {
                error("advertised fingerprint mismatch")
            }

            val trustStore = localIdentity.trustStore()
            val pinned = trustStore.loadPeerSigningFingerprint(peerId)
            activePeerFingerprint = observedFingerprint
            when {
                !advertisedFingerprint.isNullOrBlank() &&
                    advertisedFingerprint.equals(observedFingerprint, ignoreCase = true) -> {
                    if (!pinned.equals(observedFingerprint, ignoreCase = true)) {
                        trustStore.savePeerSigningFingerprint(peerId, observedFingerprint)
                    }
                    if (pinned.isNullOrBlank()) {
                        TrustState.TRUSTED_NEW
                    } else {
                        TrustState.TRUSTED_EXISTING
                    }
                }

                pinned.isNullOrBlank() && securityConfig.allowTrustOnFirstUse -> {
                    trustStore.savePeerSigningFingerprint(peerId, observedFingerprint)
                    TrustState.TRUSTED_NEW
                }

                pinned.isNullOrBlank() -> {
                    TrustState.UNTRUSTED_EPHEMERAL
                }

                pinned.equals(observedFingerprint, ignoreCase = true) -> {
                    TrustState.TRUSTED_EXISTING
                }

                else -> error("peer identity mismatch")
            }
        }.onFailure {
            handleHandshakeFailure("trust verification failed: ${it.message ?: "unknown"}")
        }.getOrNull()
    }

    private fun handleHandshakeFailure(reason: String) {
        logHandshakeWarn("failed: $reason")
        clearHandshakeState()
        negotiatedSuiteName = null
        if (canAcceptPlaintext()) {
            markPlaintext(reason)
        } else {
            failConnection(reason)
        }
    }

    private fun canAcceptPlaintext(): Boolean =
        !securityConfig.encryptionRequired && securityConfig.allowPlaintextFallback

    private fun markPlaintext(reason: String) {
        _securityState.value = SecurityState.Plaintext(
            peerId = peerIdHint(),
            reason = reason
        )
    }

    private fun peerIdHint(): String? =
        currentTarget?.deviceIdHint?.takeIf { it.isNotBlank() }
            ?: currentTarget?.host?.takeIf { it.isNotBlank() }

    private fun failConnection(reason: String) {
        Log.e(TAG, "LAN remote connection failed: $reason")
        clearHandshakeState()
        sessionKeys = null
        pendingSessionKeys = null
        pendingTrustState = null
        closeTransport()
        _latestFrame.value = null
        _state.value = State.Failed(reason)
        _securityState.value = SecurityState.Failed(peerIdHint(), reason)
    }

    private fun closeTransport() {
        try { input?.close() } catch (_: Throwable) {}
        try { out?.close() } catch (_: Throwable) {}
        try { socket?.close() } catch (_: Throwable) {}
        input = null
        out = null
        socket = null
    }

    private fun readFully(ins: BufferedInputStream, out: ByteArray): Boolean {
        var off = 0
        while (off < out.size) {
            val r = ins.read(out, off, out.size - off)
            if (r < 0) return false
            off += r
        }
        return true
    }
}
