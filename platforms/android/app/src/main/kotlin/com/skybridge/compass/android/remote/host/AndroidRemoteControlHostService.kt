package com.skybridge.compass.android.remote.host

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.Image
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.SystemClock
import android.util.DisplayMetrics
import android.util.Log
import android.view.KeyEvent
import androidx.core.app.NotificationCompat
import com.skybridge.compass.android.data.SecuritySettings
import com.skybridge.compass.android.data.SecuritySettingsStore
import com.skybridge.compass.android.security.toHandshakePolicyOverride
import com.skybridge.compass.android.remote.mac.KeyboardEventType
import com.skybridge.compass.android.remote.mac.MouseEventType
import com.skybridge.compass.android.remote.mac.RemoteKeyboardEvent
import com.skybridge.compass.android.remote.mac.RemoteMessage
import com.skybridge.compass.android.remote.mac.RemoteMouseEvent
import com.skybridge.compass.android.remote.mac.ScreenData
import com.skybridge.compass.core.p2p.LocalP2PIdentity
import com.skybridge.compass.core.p2p.PairingTrustDecision
import com.skybridge.compass.core.p2p.PairingTrustManager
import com.skybridge.compass.core.p2p.PairingTrustRequest
import com.skybridge.compass.core.p2p.toWirePolicy
import com.skybridge.compass.core.webrtc.ProtocolSigningAlgorithm
import com.skybridge.compass.core.webrtc.AndroidRemoteVideoFormats
import com.skybridge.compass.discovery.data.datasources.BonjourAdvertiserDataSource
import com.skybridge.compass.discovery.data.interop.AppleBonjourInterop
import com.skybridge.compass.discovery.domain.entities.DeviceCapability
import com.skybridge.compass.remotecontrol.execution.InputExecutionManager
import com.skybridge.compass.remotecontrol.model.GestureEvent
import com.skybridge.compass.remotecontrol.model.GestureType
import com.skybridge.compass.remotecontrol.model.InputEventUtils
import com.skybridge.compass.remotecontrol.model.KeyAction
import com.skybridge.compass.remotecontrol.model.KeyboardEvent as AndroidKeyboardEvent
import com.skybridge.compass.remotecontrol.model.MouseAction
import com.skybridge.compass.remotecontrol.model.MouseButton
import com.skybridge.compass.remotecontrol.model.MouseEvent as AndroidMouseEvent
import com.skybridge.compass.shared.crypto.AesGcmCombined
import com.skybridge.compass.shared.protocol.CrossPlatformRemoteControlProtocol
import com.skybridge.compass.shared.p2p.HandshakePaddingP1
import com.skybridge.compass.shared.p2p.P2PHandshakeServer
import com.skybridge.compass.shared.p2p.P2PHandshakeWire
import com.skybridge.compass.shared.p2p.P2PProtocolSigningKeys
import dagger.hilt.android.AndroidEntryPoint
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.ByteArrayOutputStream
import java.net.ServerSocket
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import javax.inject.Inject
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json

@AndroidEntryPoint
class AndroidRemoteControlHostService : Service() {
    private data class MousePressState(
        val downX: Float,
        val downY: Float,
        var currentX: Float,
        var currentY: Float
    )

    private data class HandshakeContext(
        val server: P2PHandshakeServer,
        val responderState: P2PHandshakeServer.ResponderState
    )

    private data class StreamPlan(
        val width: Int,
        val height: Int,
        val codec: String,
        val frameRate: Int,
        val keyFrameInterval: Int,
        val bitrate: Int
    ) {
        val usesVideoEncoder: Boolean
            get() = codec == AndroidRemoteVideoFormats.H264 || codec == AndroidRemoteVideoFormats.HEVC
    }

    private class ClientSession(
        val id: String,
        val socket: Socket,
        val input: BufferedInputStream,
        val output: BufferedOutputStream,
        val sendLock: Any = Any()
    ) {
        @Volatile
        var sessionKeys: P2PHandshakeWire.DerivedSessionKeys? = null

        @Volatile
        var handshakeContext: HandshakeContext? = null

        @Volatile
        var clientFinishedVerified: Boolean = false

        @Volatile
        var requestedStreamConfiguration: com.skybridge.compass.android.remote.mac.RemoteDesktopStreamConfiguration? = null

        @Volatile
        var trustPeerId: String? = null
    }

    companion object {
        private const val TAG = "AndroidRemoteHostService"
        private const val ACTION_START = "com.skybridge.compass.android.remote.host.START"
        private const val ACTION_STOP = "com.skybridge.compass.android.remote.host.STOP"
        private const val EXTRA_RESULT_CODE = "result_code"
        private const val EXTRA_RESULT_DATA = "result_data"
        private const val NOTIFICATION_CHANNEL_ID = "android_remote_host"
        private const val NOTIFICATION_ID = 4107
        private const val DEFAULT_PORT = 5901
        private const val MAX_FRAME_BYTES = 32_000_000
        private const val DEFAULT_JPEG_FRAME_INTERVAL_MS = 125L
        private const val REMOTE_SERVICE_TYPE = AppleBonjourInterop.REMOTE_SERVICE_TYPE

        fun start(context: Context, resultCode: Int, resultData: Intent) {
            val intent = Intent(context, AndroidRemoteControlHostService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_RESULT_CODE, resultCode)
                putExtra(EXTRA_RESULT_DATA, resultData)
            }
            androidx.core.content.ContextCompat.startForegroundService(context, intent)
        }

        fun stop(context: Context) {
            val intent = Intent(context, AndroidRemoteControlHostService::class.java).apply {
                action = ACTION_STOP
            }
            context.startService(intent)
        }
    }

    @Inject lateinit var advertiser: BonjourAdvertiserDataSource
    @Inject lateinit var identity: LocalP2PIdentity
    @Inject lateinit var inputExecutionManager: InputExecutionManager

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val clients = ConcurrentHashMap<String, ClientSession>()
    private val mousePressStates = ConcurrentHashMap<String, MousePressState>()
    private val keyboardMetaStates = ConcurrentHashMap<String, Int>()
    private val running = AtomicBoolean(false)
    private val frameEncoding = AtomicBoolean(false)
    private val lastFrameAtMs = AtomicLong(0L)
    private val json = Json {
        ignoreUnknownKeys = true
        explicitNulls = false
    }

    @Volatile private var serverSocket: ServerSocket? = null
    @Volatile private var mediaProjection: MediaProjection? = null
    @Volatile private var imageReader: ImageReader? = null
    @Volatile private var virtualDisplay: VirtualDisplay? = null
    @Volatile private var advertisedServiceName: String? = null
    @Volatile private var handlerThread: HandlerThread? = null
    @Volatile private var backgroundHandler: Handler? = null
    @Volatile private var captureWidth: Int = 0
    @Volatile private var captureHeight: Int = 0
    @Volatile private var displayWidth: Int = 0
    @Volatile private var displayHeight: Int = 0
    @Volatile private var securitySettings: SecuritySettings = SecuritySettings()
    @Volatile private var inputReady: Boolean = false
    @Volatile private var currentStreamPlan: StreamPlan? = null
    @Volatile private var remoteVideoEncoder: AndroidRemoteHostVideoEncoder? = null
    @Volatile private var jpegFrameIntervalMs: Long = DEFAULT_JPEG_FRAME_INTERVAL_MS

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                val resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, Int.MIN_VALUE)
                val resultData = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(EXTRA_RESULT_DATA, Intent::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(EXTRA_RESULT_DATA)
                }
                if (resultCode == Int.MIN_VALUE || resultData == null) {
                    AndroidRemoteControlHostRuntime.update(
                        AndroidRemoteControlHostRuntime.State.Error("Missing MediaProjection permission result")
                    )
                    stopSelf()
                    return START_NOT_STICKY
                }
                scope.launch { startHost(resultCode, resultData) }
            }
            ACTION_STOP -> scope.launch { stopHost("requested") }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        scope.launch { stopHost("destroy") }
        super.onDestroy()
    }

    private suspend fun startHost(resultCode: Int, resultData: Intent) {
        if (!running.compareAndSet(false, true)) {
            return
        }
        AndroidRemoteControlHostRuntime.update(
            AndroidRemoteControlHostRuntime.State.Starting("Preparing Android remote host")
        )
        try {
            securitySettings = SecuritySettingsStore.observe(applicationContext).first()
            if (!securitySettings.allowScreenMirroring) {
                throw IllegalStateException("Screen mirroring is disabled in access control settings")
            }

            startForeground(NOTIFICATION_ID, buildNotification("Preparing screen sharing"))

            setupProjection(resultCode, resultData)
            setupServer()
            setupAdvertising()

            inputReady = maybeStartInputExecution()
            updateRunningState()

            scope.launch { acceptLoop() }
        } catch (t: Throwable) {
            Log.e(TAG, "Failed to start host", t)
            AndroidRemoteControlHostRuntime.update(
                AndroidRemoteControlHostRuntime.State.Error(t.message ?: "Failed to start host")
            )
            stopHost("startup_failed")
        }
    }

    private suspend fun stopHost(reason: String) {
        if (!running.compareAndSet(true, false)) {
            if (reason == "destroy") {
                scope.cancel()
            }
            return
        }
        Log.i(TAG, "Stopping Android remote host: $reason")
        runCatching { advertiser.stopAdvertising(REMOTE_SERVICE_TYPE) }
        advertisedServiceName = null

        clients.values.forEach { client ->
            runCatching { client.socket.close() }
        }
        clients.clear()
        mousePressStates.clear()
        keyboardMetaStates.clear()

        runCatching { serverSocket?.close() }
        serverSocket = null

        runCatching { virtualDisplay?.release() }
        virtualDisplay = null
        runCatching { imageReader?.close() }
        imageReader = null
        runCatching { remoteVideoEncoder?.stop() }
        remoteVideoEncoder = null
        currentStreamPlan = null
        runCatching { mediaProjection?.stop() }
        mediaProjection = null

        runCatching { handlerThread?.quitSafely() }
        handlerThread = null
        backgroundHandler = null

        inputReady = false
        AndroidRemoteControlHostRuntime.update(AndroidRemoteControlHostRuntime.State.Stopped)
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
        if (reason == "destroy") {
            scope.cancel()
        }
    }

    private fun setupProjection(resultCode: Int, resultData: Intent) {
        val metrics = resources.displayMetrics
        displayWidth = metrics.widthPixels
        displayHeight = metrics.heightPixels

        val projectionManager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val projection = projectionManager.getMediaProjection(resultCode, resultData)
            ?: throw IllegalStateException("MediaProjection is unavailable")
        mediaProjection = projection

        handlerThread = HandlerThread("AndroidRemoteHostCapture").also { it.start() }
        backgroundHandler = Handler(handlerThread!!.looper)

        projection.registerCallback(
            object : MediaProjection.Callback() {
                override fun onStop() {
                    scope.launch { stopHost("projection_stopped") }
                }
            },
            backgroundHandler
        )

        rebuildCapturePipeline(force = true)
    }

    private fun setupServer() {
        val server = try {
            ServerSocket(DEFAULT_PORT)
        } catch (_: Throwable) {
            ServerSocket(0)
        }
        serverSocket = server
    }

    private suspend fun setupAdvertising() {
        val servicePort = serverSocket?.localPort ?: throw IllegalStateException("Server socket unavailable")
        advertisedServiceName = advertiser.startAdvertising(
            port = servicePort,
            advertisement = BonjourAdvertiserDataSource.Advertisement(
                deviceId = identity.deviceId(),
                pubKeyFP = identity.pubKeyFingerprint(),
                uniqueId = identity.deviceId(),
                name = identity.deviceName(),
                platform = "android",
                version = "1.0.0",
                osVersion = "Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})",
                model = Build.MODEL,
                capabilities = AppleBonjourInterop.appleCompatibleCapabilities(
                    setOf(
                        DeviceCapability.SCREEN_SHARING,
                        DeviceCapability.REMOTE_CONTROL
                    )
                ),
                cryptoSuites = identity.discoveryCryptoSuitesCsv(),
                remoteVideoFormats = AndroidRemoteVideoFormats.supportedStreamingFormats().toSet(),
                supportsSoa = true
            ),
            serviceType = REMOTE_SERVICE_TYPE
        )
    }

    private suspend fun acceptLoop() {
        val server = serverSocket ?: return
        while (running.get()) {
            val socket = try {
                server.accept()
            } catch (_: Throwable) {
                break
            }
            socket.tcpNoDelay = true
            socket.keepAlive = true

            val id = UUID.randomUUID().toString()
            val client = ClientSession(
                id = id,
                socket = socket,
                input = BufferedInputStream(socket.getInputStream()),
                output = BufferedOutputStream(socket.getOutputStream())
            )
            clients[id] = client
            updateRunningState()
            scope.launch { receiveLoop(client) }
        }
    }

    private suspend fun receiveLoop(client: ClientSession) {
        try {
            while (running.get()) {
                val payload = readFramedPayload(client.input) ?: break
                handleInboundPayload(client, payload)
            }
        } catch (t: Throwable) {
            Log.w(TAG, "Client loop ended: ${t.message}")
        } finally {
            clients.remove(client.id)
            mousePressStates.remove(client.id)
            keyboardMetaStates.remove(client.id)
            scope.launch { rebuildCapturePipeline(force = false) }
            updateRunningState()
            runCatching { client.socket.close() }
        }
    }

    private suspend fun handleInboundPayload(client: ClientSession, payload: ByteArray) {
        val handshakeContext = client.handshakeContext
        if (handshakeContext != null) {
            val finishedVerified = runCatching {
                handshakeContext.server.verifyClientFinished(
                    rawFinished = payload,
                    sessionKeys = handshakeContext.responderState.sessionKeys
                )
            }.getOrDefault(false)
            if (finishedVerified) {
                client.clientFinishedVerified = true
                client.handshakeContext = null
                rebuildCapturePipeline(force = false)
                updateRunningState()
                return
            }

            if (!client.clientFinishedVerified) {
                return
            }
        }

        if (client.sessionKeys == null) {
            if (handleUnauthenticatedRemoteMessage(client, payload)) {
                return
            }
            tryStartHandshake(client, payload)
            return
        }

        val sessionKeys = requireNotNull(client.sessionKeys)
        val plaintext = runCatching {
            AesGcmCombined.open(sessionKeys.receiveKey, payload)
        }.getOrNull() ?: payload

        val message = runCatching {
            json.decodeFromString(RemoteMessage.serializer(), plaintext.decodeToString())
        }.getOrNull()
        if (message != null) {
            handleRemoteMessage(client, message)
            return
        }

    }

    private fun handleUnauthenticatedRemoteMessage(client: ClientSession, payload: ByteArray): Boolean {
        val message = runCatching {
            json.decodeFromString(RemoteMessage.serializer(), payload.decodeToString())
        }.getOrNull() ?: return false

        return if (message.type == RemoteMessage.MessageType.STREAM_CONFIGURATION) {
            client.requestedStreamConfiguration = runCatching {
                json.decodeFromString(
                    com.skybridge.compass.android.remote.mac.RemoteDesktopStreamConfiguration.serializer(),
                    message.payload.decodeToString()
                )
            }.getOrNull()
            true
        } else {
            Log.w(TAG, "Dropping unauthenticated ${message.type} from ${client.socket.inetAddress.hostAddress}")
            runCatching { client.socket.close() }
            true
        }
    }

    private suspend fun handleRemoteMessage(client: ClientSession, message: RemoteMessage) {
        when (message.type) {
            RemoteMessage.MessageType.MOUSE_EVENT -> {
                if (!securitySettings.allowRemoteControl) return
                val event = runCatching {
                    json.decodeFromString(
                        RemoteMouseEvent.serializer(),
                        message.payload.decodeToString()
                    )
                }.getOrNull() ?: return
                ensureInputExecutionReady()
                handleRemoteMouseEvent(client.id, event)
            }
            RemoteMessage.MessageType.KEYBOARD_EVENT -> {
                if (!securitySettings.allowRemoteControl) return
                val event = runCatching {
                    json.decodeFromString(
                        RemoteKeyboardEvent.serializer(),
                        message.payload.decodeToString()
                    )
                }.getOrNull() ?: return
                ensureInputExecutionReady()
                handleRemoteKeyboardEvent(client.id, event)
            }
            RemoteMessage.MessageType.STREAM_CONFIGURATION -> {
                val config = runCatching {
                    json.decodeFromString(
                        com.skybridge.compass.android.remote.mac.RemoteDesktopStreamConfiguration.serializer(),
                        message.payload.decodeToString()
                    )
                }.getOrNull() ?: return
                client.requestedStreamConfiguration = config
                Log.i(
                    TAG,
                    "Updated viewer stream config for ${client.id}: preferred=${config.preferredCodec} formats=${config.supportedVideoFormats.joinToString(",")}"
                )
                rebuildCapturePipeline(force = false)
            }
            RemoteMessage.MessageType.SCREEN_DATA,
            RemoteMessage.MessageType.CLIPBOARD -> Unit
        }
    }

    private suspend fun tryStartHandshake(client: ClientSession, payload: ByteArray) {
        val decodedMessageA = runCatching { P2PHandshakeWire.decodeMessageA(payload) }.getOrNull() ?: return
        val verifiedMessageA = runCatching {
            P2PHandshakeWire.verifyMessageASignature(
                messageA = decodedMessageA,
                rawMessageAWithoutPadding = HandshakePaddingP1.unwrapIfNeeded(payload)
            )
        }.getOrDefault(false)
        if (!verifiedMessageA) {
            Log.w(TAG, "Rejecting remote host handshake: invalid MessageA signature")
            runCatching { client.socket.close() }
            return
        }

        val peerFingerprint = P2PHandshakeWire.computePeerSigningFingerprint(decodedMessageA.identityPublicKeys)
        val peerId = client.socket.inetAddress?.hostAddress?.takeIf { it.isNotBlank() } ?: "remote-host:${client.id}"
        val trustedPeerStore = identity.trustedPeerStore()
        val existingRecord = trustedPeerStore.currentPathTrustRecord(peerFingerprint)
            ?: trustedPeerStore.findByKnownDeviceId(peerId)
        val conflict = trustedPeerStore.evaluateCurrentPathBinding(
            deviceId = peerId,
            protocolPublicKeyFingerprint = peerFingerprint
        )
        val alreadyTrusted = existingRecord != null ||
            identity.trustStore().loadPeerSigningFingerprint(peerId)?.equals(peerFingerprint, ignoreCase = true) == true
        val request = PairingTrustRequest(
            peerId = peerId,
            declaredDeviceId = peerId,
            deviceName = peerId,
            platform = "macOS/iOS",
            protocolPublicKeyFingerprint = peerFingerprint,
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
        if (decision == PairingTrustDecision.DECLINE) {
            Log.w(TAG, "Remote host pairing declined for $peerId")
            runCatching { client.socket.close() }
            return
        }

        if (decision == PairingTrustDecision.TRUST_ALWAYS) {
            identity.trustStore().savePeerSigningFingerprint(peerId, peerFingerprint)
            trustedPeerStore.upsertCurrentPathAuthority(
                deviceId = peerId,
                name = peerId,
                protocolSigningAlgorithm = ProtocolSigningAlgorithm
                    .fromIdentityAlgorithm(decodedMessageA.identityPublicKeys.protocolAlgorithm)
                    ?.rawValue,
                protocolPublicKeyFingerprint = peerFingerprint,
                aliasIds = listOf(peerId)
            )
        }
        client.trustPeerId = peerId

        val response = runCatching {
            val kemKeys = identity.getOrCreateKemIdentityKeys()
            val signingKeys = identity.getOrCreateProtocolSigningKeys()
            val server = P2PHandshakeServer()
            server to server.respond(
                rawMessageA = payload,
                peerIdForTrust = peerId,
                trustStore = identity.trustStore(),
                allowTrustOnFirstUse = false,
                options = P2PHandshakeServer.RespondOptions(
                    platformVersion = Build.VERSION.RELEASE,
                    kemPrivateKeys = P2PHandshakeServer.KemPrivateKeys(
                        xWingPrivateKey = kemKeys.xWingPrivateKey,
                        mlKem768PrivateKey = kemKeys.mlKem768PrivateKey
                    ),
                    handshakePolicy = securitySettings.toHandshakePolicyOverride().toWirePolicy(),
                    protocolSigningKeys = P2PProtocolSigningKeys(
                        ed25519PrivateKey = signingKeys.ed25519PrivateKey,
                        ed25519PublicKeyRaw32 = signingKeys.ed25519PublicRaw32,
                        mlDsa65PrivateKeyRaw = signingKeys.mlDsa65PrivateKeyRaw,
                        mlDsa65PublicKeyRaw = signingKeys.mlDsa65PublicKeyRaw
                    )
                )
            )
        }.getOrNull() ?: return

        val (server, serverResponse) = response
        val responderFinished = server.buildResponderFinished(serverResponse.state.sessionKeys)
        client.sessionKeys = serverResponse.state.sessionKeys
        client.handshakeContext = HandshakeContext(
            server = server,
            responderState = serverResponse.state
        )
        client.clientFinishedVerified = false

        runCatching {
            synchronized(client.sendLock) {
                client.output.write(framePayload(serverResponse.messageBToSend))
                client.output.write(framePayload(responderFinished))
                client.output.flush()
            }
        }.onFailure {
            client.sessionKeys = null
            client.handshakeContext = null
            throw it
        }
    }

    private suspend fun handleRemoteMouseEvent(deviceId: String, event: RemoteMouseEvent) {
        val (x, y) = mapRemotePoint(event.x, event.y)
        when (event.type) {
            MouseEventType.LEFT_MOUSE_DOWN -> {
                mousePressStates[deviceId] = MousePressState(
                    downX = x,
                    downY = y,
                    currentX = x,
                    currentY = y
                )
            }
            MouseEventType.LEFT_MOUSE_UP -> {
                val state = mousePressStates.remove(deviceId)
                if (state == null) {
                    inputExecutionManager.executeInputEvent(
                        GestureEvent(
                            timestamp = System.currentTimeMillis(),
                            deviceId = deviceId,
                            eventId = InputEventUtils.generateEventId(),
                            gestureType = GestureType.TAP,
                            startX = x,
                            startY = y,
                            endX = x,
                            endY = y
                        )
                    )
                    return
                }
                val endX = x
                val endY = y
                val distance = kotlin.math.hypot(
                    (endX - state.downX).toDouble(),
                    (endY - state.downY).toDouble()
                )
                val inputEvent =
                    if (distance >= 12.0) {
                        GestureEvent(
                            timestamp = System.currentTimeMillis(),
                            deviceId = deviceId,
                            eventId = InputEventUtils.generateEventId(),
                            gestureType = GestureType.DRAG,
                            startX = state.downX,
                            startY = state.downY,
                            endX = endX,
                            endY = endY
                        )
                    } else {
                        GestureEvent(
                            timestamp = System.currentTimeMillis(),
                            deviceId = deviceId,
                            eventId = InputEventUtils.generateEventId(),
                            gestureType = GestureType.TAP,
                            startX = endX,
                            startY = endY,
                            endX = endX,
                            endY = endY
                        )
                    }
                inputExecutionManager.executeInputEvent(inputEvent)
            }
            MouseEventType.MOUSE_MOVED -> {
                mousePressStates[deviceId]?.let { state ->
                    state.currentX = x
                    state.currentY = y
                }
            }
            MouseEventType.RIGHT_MOUSE_DOWN -> {
                inputExecutionManager.executeInputEvent(
                    GestureEvent(
                        timestamp = System.currentTimeMillis(),
                        deviceId = deviceId,
                        eventId = InputEventUtils.generateEventId(),
                        gestureType = GestureType.LONG_PRESS,
                        startX = x,
                        startY = y,
                        endX = x,
                        endY = y
                    )
                )
            }
            MouseEventType.RIGHT_MOUSE_UP -> Unit
            MouseEventType.SCROLL_UP,
            MouseEventType.SCROLL_DOWN -> {
                inputExecutionManager.executeInputEvent(
                    AndroidMouseEvent(
                        timestamp = System.currentTimeMillis(),
                        deviceId = deviceId,
                        eventId = InputEventUtils.generateEventId(),
                        action = MouseAction.SCROLL,
                        x = x,
                        y = y,
                        button = MouseButton.LEFT,
                        scrollY = if (event.type == MouseEventType.SCROLL_UP) -3f else 3f
                    )
                )
            }
        }
    }

    private suspend fun handleRemoteKeyboardEvent(deviceId: String, event: RemoteKeyboardEvent) {
        val androidKeyCode = CrossPlatformRemoteControlProtocol.KeyCodeMapping.macOSToAndroid(event.keyCode)
        val currentMetaState = keyboardMetaStates[deviceId] ?: 0
        val eventMetaState = AndroidRemoteKeyboardMetaState.metaStateForEvent(
            currentMetaState = currentMetaState,
            keyCode = androidKeyCode,
            type = event.type
        )
        val nextMetaState = AndroidRemoteKeyboardMetaState.updatedMetaState(
            currentMetaState = currentMetaState,
            keyCode = androidKeyCode,
            type = event.type
        )
        if (nextMetaState == 0) {
            keyboardMetaStates.remove(deviceId)
        } else {
            keyboardMetaStates[deviceId] = nextMetaState
        }
        inputExecutionManager.executeInputEvent(
            AndroidKeyboardEvent(
                timestamp = System.currentTimeMillis(),
                deviceId = deviceId,
                eventId = InputEventUtils.generateEventId(),
                action = when (event.type) {
                    KeyboardEventType.KEY_DOWN -> KeyAction.DOWN
                    KeyboardEventType.KEY_UP -> KeyAction.UP
                },
                keyCode = androidKeyCode,
                metaState = eventMetaState
            )
        )
    }

    private fun ensureInputExecutionReady() {
        if (inputReady) return
        inputReady = maybeStartInputExecution()
        updateRunningState()
    }

    private fun maybeStartInputExecution(): Boolean {
        if (!securitySettings.allowRemoteControl) return false
        if (!inputExecutionManager.isAccessibilityServiceAvailable()) return false
        return inputExecutionManager.startExecution().isSuccess
    }

    private fun handleImageAvailable(reader: ImageReader) {
        val plan = currentStreamPlan
        if (plan?.usesVideoEncoder == true) {
            reader.acquireLatestImage()?.close()
            return
        }
        if (!running.get()) {
            reader.acquireLatestImage()?.close()
            return
        }
        val now = SystemClock.elapsedRealtime()
        if (now - lastFrameAtMs.get() < jpegFrameIntervalMs) {
            reader.acquireLatestImage()?.close()
            return
        }
        if (!frameEncoding.compareAndSet(false, true)) {
            reader.acquireLatestImage()?.close()
            return
        }
        val image = reader.acquireLatestImage()
        if (image == null) {
            frameEncoding.set(false)
            return
        }
        scope.launch {
            try {
                val jpegBytes = imageToJpeg(image)
                lastFrameAtMs.set(SystemClock.elapsedRealtime())
                broadcastScreenFrame(
                    frameBytes = jpegBytes,
                    format = AndroidRemoteVideoFormats.JPEG,
                    width = image.width,
                    height = image.height
                )
            } catch (t: Throwable) {
                Log.w(TAG, "Failed to encode frame: ${t.message}")
            } finally {
                image.close()
                frameEncoding.set(false)
            }
        }
    }

    private suspend fun broadcastScreenFrame(
        frameBytes: ByteArray,
        format: String,
        width: Int,
        height: Int
    ) {
        val readyClients = clients.values.filter { it.sessionKeys != null && it.handshakeContext == null }
        if (readyClients.isEmpty()) return
        val screenData = ScreenData(
            width = width,
            height = height,
            imageData = frameBytes,
            timestamp = System.currentTimeMillis() / 1000.0,
            format = format
        )
        val screenPayload = json.encodeToString(ScreenData.serializer(), screenData).encodeToByteArray()
        val message = RemoteMessage(
            type = RemoteMessage.MessageType.SCREEN_DATA,
            payload = screenPayload
        )
        val payload = json.encodeToString(RemoteMessage.serializer(), message).encodeToByteArray()

        val deadClients = ArrayList<String>()
        readyClients.forEach { client ->
            val sent = runCatching {
                synchronized(client.sendLock) {
                    client.output.write(framePayload(encryptAppPayloadIfNeeded(client, payload)))
                    client.output.flush()
                }
            }.isSuccess
            if (!sent) {
                deadClients += client.id
            }
        }
        deadClients.forEach { id ->
            clients.remove(id)?.let { client ->
                runCatching { client.socket.close() }
            }
        }
        updateRunningState()
    }

    private fun imageToJpeg(image: Image): ByteArray {
        val planes = image.planes
        val buffer = planes[0].buffer
        val pixelStride = planes[0].pixelStride
        val rowStride = planes[0].rowStride
        val rowPadding = rowStride - pixelStride * image.width

        val bitmap = Bitmap.createBitmap(
            image.width + rowPadding / pixelStride,
            image.height,
            Bitmap.Config.ARGB_8888
        )
        bitmap.copyPixelsFromBuffer(buffer)

        val cropped = if (rowPadding == 0) {
            bitmap
        } else {
            Bitmap.createBitmap(bitmap, 0, 0, image.width, image.height).also {
                bitmap.recycle()
            }
        }

        return ByteArrayOutputStream().use { stream ->
            cropped.compress(Bitmap.CompressFormat.JPEG, 72, stream)
            cropped.recycle()
            stream.toByteArray()
        }
    }

    private fun readFramedPayload(input: BufferedInputStream): ByteArray? {
        val header = ByteArray(4)
        if (!readExactly(input, header)) return null
        val length = ByteBuffer.wrap(header).order(ByteOrder.BIG_ENDIAN).int
        require(length in 1..MAX_FRAME_BYTES) { "Invalid frame length: $length" }
        val payload = ByteArray(length)
        require(readExactly(input, payload)) { "Connection closed" }
        return payload
    }

    private fun readExactly(input: BufferedInputStream, out: ByteArray): Boolean {
        var offset = 0
        while (offset < out.size) {
            val read = input.read(out, offset, out.size - offset)
            if (read < 0) return false
            offset += read
        }
        return true
    }

    private fun framePayload(payload: ByteArray): ByteArray {
        val header = ByteBuffer.allocate(4).order(ByteOrder.BIG_ENDIAN).putInt(payload.size).array()
        return header + payload
    }

    private fun encryptAppPayloadIfNeeded(client: ClientSession, payload: ByteArray): ByteArray {
        val sessionKeys = client.sessionKeys ?: return payload
        return AesGcmCombined.seal(sessionKeys.sendKey, payload)
    }

    private fun mapRemotePoint(remoteX: Double, remoteY: Double): Pair<Float, Float> {
        val sourceWidth = captureWidth.takeIf { it > 0 } ?: displayWidth
        val sourceHeight = captureHeight.takeIf { it > 0 } ?: displayHeight
        val mappedX = ((remoteX / sourceWidth.toDouble()) * displayWidth.toDouble())
            .coerceIn(0.0, displayWidth.toDouble())
        val mappedY = ((remoteY / sourceHeight.toDouble()) * displayHeight.toDouble())
            .coerceIn(0.0, displayHeight.toDouble())
        return mappedX.toFloat() to mappedY.toFloat()
    }

    private fun rebuildCapturePipeline(force: Boolean) {
        val projection = mediaProjection ?: return
        val handler = backgroundHandler ?: return
        val desiredPlan = currentDesiredStreamPlan()
        if (!force && desiredPlan == currentStreamPlan) {
            return
        }

        runCatching { virtualDisplay?.release() }
        virtualDisplay = null
        runCatching { imageReader?.close() }
        imageReader = null
        runCatching { remoteVideoEncoder?.stop() }
        remoteVideoEncoder = null

        captureWidth = desiredPlan.width
        captureHeight = desiredPlan.height
        currentStreamPlan = desiredPlan
        jpegFrameIntervalMs = (1000L / desiredPlan.frameRate.coerceAtLeast(1)).coerceAtLeast(40L)
        frameEncoding.set(false)
        lastFrameAtMs.set(0L)

        val captureSurface = if (desiredPlan.usesVideoEncoder) {
            val encoder = AndroidRemoteHostVideoEncoder(
                scope = scope,
                onFrame = { encoded ->
                    scope.launch {
                        broadcastScreenFrame(
                            frameBytes = encoded.bytes,
                            format = encoded.format,
                            width = encoded.width,
                            height = encoded.height
                        )
                    }
                },
                onError = { throwable ->
                    Log.w(TAG, "Video encoder failed: ${throwable.message}", throwable)
                }
            )
            remoteVideoEncoder = encoder
            encoder.start(
                AndroidRemoteHostStreamPlan(
                    width = desiredPlan.width,
                    height = desiredPlan.height,
                    codec = desiredPlan.codec,
                    frameRate = desiredPlan.frameRate,
                    keyFrameInterval = desiredPlan.keyFrameInterval,
                    bitrate = desiredPlan.bitrate
                )
            )
        } else {
            imageReader = ImageReader.newInstance(
                desiredPlan.width,
                desiredPlan.height,
                PixelFormat.RGBA_8888,
                2
            ).apply {
                setOnImageAvailableListener({ reader ->
                    handleImageAvailable(reader)
                }, handler)
            }
            requireNotNull(imageReader?.surface)
        }

        val metrics = resources.displayMetrics
        virtualDisplay = projection.createVirtualDisplay(
            "SkyBridge-AndroidRemoteHost",
            desiredPlan.width,
            desiredPlan.height,
            metrics.densityDpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            captureSurface,
            null,
            handler
        ) ?: throw IllegalStateException("VirtualDisplay is unavailable")

        Log.i(
            TAG,
            "Capture pipeline rebuilt: ${desiredPlan.width}x${desiredPlan.height} codec=${desiredPlan.codec} fps=${desiredPlan.frameRate} bitrate=${desiredPlan.bitrate}"
        )
        updateRunningState()
    }

    private fun currentDesiredStreamPlan(): StreamPlan {
        val metrics = resources.displayMetrics
        val (defaultWidth, defaultHeight) = chooseCaptureSize(metrics)
        val activeConfigs = clients.values
            .filter { it.sessionKeys != null && it.handshakeContext == null }
            .mapNotNull { it.requestedStreamConfiguration }

        val commonFormats = activeConfigs
            .map(::effectiveRequestedFormats)
            .fold<Set<String>, Set<String>?>(null) { acc, formats ->
                acc?.intersect(formats) ?: formats
            }
            ?.intersect(AndroidRemoteVideoFormats.supportedEncodingFormats().toSet())
            .orEmpty()

        val codec = when {
            AndroidRemoteVideoFormats.HEVC in commonFormats -> AndroidRemoteVideoFormats.HEVC
            AndroidRemoteVideoFormats.H264 in commonFormats -> AndroidRemoteVideoFormats.H264
            else -> AndroidRemoteVideoFormats.JPEG
        }

        val fixedSizeRequest = activeConfigs
            .filter { it.adaptiveResolutionEnabled == false && (it.width ?: 0) > 0 && (it.height ?: 0) > 0 }
            .minByOrNull { (it.width ?: Int.MAX_VALUE) * (it.height ?: Int.MAX_VALUE) }

        val width = fixedSizeRequest?.width ?: defaultWidth
        val height = fixedSizeRequest?.height ?: defaultHeight
        val frameRate = activeConfigs.mapNotNull { requested ->
            requested.targetFrameRate.takeIf { it > 0 }
        }.minOrNull()
            ?: if (codec == AndroidRemoteVideoFormats.JPEG) 20 else 30
        val lowLatencyRequested = activeConfigs.any { it.lowLatencyMode }
        val keyFrameInterval = activeConfigs.mapNotNull { requested ->
            requested.keyFrameInterval.takeIf { it > 0 }
        }.minOrNull()
            ?: if (lowLatencyRequested) frameRate else 30

        return StreamPlan(
            width = width,
            height = height,
            codec = codec,
            frameRate = frameRate.coerceIn(12, 60),
            keyFrameInterval = keyFrameInterval.coerceIn(10, 120),
            bitrate = calculateBitrate(width = width, height = height, frameRate = frameRate, codec = codec)
        )
    }

    private fun effectiveRequestedFormats(
        config: com.skybridge.compass.android.remote.mac.RemoteDesktopStreamConfiguration
    ): Set<String> {
        val formats = LinkedHashSet<String>()
        formats += config.supportedVideoFormats.mapNotNull { raw ->
            AndroidRemoteVideoFormats.normalizeIncomingFormat(raw, ByteArray(0))
        }.filter { it == AndroidRemoteVideoFormats.JPEG || it == AndroidRemoteVideoFormats.H264 || it == AndroidRemoteVideoFormats.HEVC }

        AndroidRemoteVideoFormats.normalizeIncomingFormat(config.preferredCodec, ByteArray(0))
            ?.takeIf { it == AndroidRemoteVideoFormats.JPEG || it == AndroidRemoteVideoFormats.H264 || it == AndroidRemoteVideoFormats.HEVC }
            ?.let { formats += it }

        if (formats.isEmpty()) {
            formats += AndroidRemoteVideoFormats.JPEG
        }
        return formats
    }

    private fun calculateBitrate(width: Int, height: Int, frameRate: Int, codec: String): Int {
        if (codec == AndroidRemoteVideoFormats.JPEG) {
            return 0
        }
        val pixelsPerSecond = width.toLong() * height.toLong() * frameRate.toLong()
        val factor = if (codec == AndroidRemoteVideoFormats.HEVC) 0.07 else 0.11
        return (pixelsPerSecond * factor).toInt().coerceIn(1_500_000, 18_000_000)
    }

    private fun chooseCaptureSize(metrics: DisplayMetrics): Pair<Int, Int> {
        val rawWidth = metrics.widthPixels
        val rawHeight = metrics.heightPixels
        val longEdge = maxOf(rawWidth, rawHeight)
        val maxLongEdge = 1280f
        if (longEdge <= maxLongEdge) {
            return rawWidth to rawHeight
        }
        val scale = maxLongEdge / longEdge.toFloat()
        return (rawWidth * scale).toInt().coerceAtLeast(360) to
            (rawHeight * scale).toInt().coerceAtLeast(640)
    }

    private fun updateRunningState() {
        val port = serverSocket?.localPort ?: return
        val readyClientCount = clients.values.count { it.sessionKeys != null && it.handshakeContext == null }
        AndroidRemoteControlHostRuntime.update(
            AndroidRemoteControlHostRuntime.State.Running(
                port = port,
                serviceName = advertisedServiceName,
                captureWidth = captureWidth,
                captureHeight = captureHeight,
                connectedClients = readyClientCount,
                inputEnabled = inputReady
            )
        )
        val content = if (readyClientCount == 0) {
            "Sharing Android screen on port $port"
        } else {
            val plan = currentStreamPlan
            if (plan != null) {
                "Sharing Android screen with ${readyClientCount} active client(s) via ${plan.codec.uppercase()}"
            } else {
                "Sharing Android screen with ${readyClientCount} active client(s)"
            }
        }
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(NOTIFICATION_ID, buildNotification(content))
    }

    private fun buildNotification(contentText: String): Notification {
        ensureNotificationChannel()
        return NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setContentTitle("SkyBridge remote host")
            .setContentText(contentText)
            .setSmallIcon(android.R.drawable.ic_menu_share)
            .setOngoing(true)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val existing = manager.getNotificationChannel(NOTIFICATION_CHANNEL_ID)
        if (existing != null) return
        manager.createNotificationChannel(
            NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                "Android Remote Host",
                NotificationManager.IMPORTANCE_LOW
            )
        )
    }
}
