package com.skybridge.compass.android.remote.mac

import android.content.Context
import android.os.Build as AndroidBuild
import android.util.Log
import com.skybridge.compass.BuildConfig
import com.skybridge.compass.android.account.AccountBusinessIdentityProvider
import com.skybridge.compass.android.logging.SensitiveLogRedaction
import com.skybridge.compass.core.p2p.LocalP2PIdentity
import com.skybridge.compass.core.p2p.PeerKemKeyStore
import com.skybridge.compass.core.p2p.P2PHandshakePolicyOverride
import com.skybridge.compass.core.p2p.ResolvedBootstrapControlEndpoint
import com.skybridge.compass.core.p2p.isPeerPinned
import com.skybridge.compass.core.p2p.isMissingPqcMaterial
import com.skybridge.compass.core.p2p.toWirePolicy
import com.skybridge.compass.remotecontrol.secure.RemoteControlSecureEnvelope
import com.skybridge.compass.shared.p2p.HandshakePaddingP1
import com.skybridge.compass.shared.p2p.P2PHandshakeClient
import com.skybridge.compass.shared.p2p.P2PProtocolSigningKeys
import com.skybridge.compass.shared.p2p.P2PHandshakeWire
import com.skybridge.compass.shared.p2p.P2PXWingKem
import com.skybridge.compass.core.webrtc.AndroidRemoteVideoFormats
import com.skybridge.compass.core.webrtc.RemoteFrameWatchdogPolicy
import com.skybridge.compass.core.webrtc.RemoteRenderAdmissionPolicy
import com.skybridge.compass.core.webrtc.RemoteViewerStatus
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.Closeable
import java.io.IOException
import java.io.InputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.security.SecureRandom

internal object MacRemoteViewerFailurePolicy {
    fun terminalStatus(
        currentStatus: RemoteViewerStatus,
        interruptedAtMs: Long?,
        watchdogReconnecting: Boolean
    ): RemoteViewerStatus =
        if (
            currentStatus != RemoteViewerStatus.Idle ||
            interruptedAtMs != null ||
            watchdogReconnecting
        ) {
            RemoteViewerStatus.SessionEnded
        } else {
            RemoteViewerStatus.Idle
        }
}

/** Narrow logger seam keeps production Android logging and failure redaction testable as one path. */
internal interface MacRemoteControlLogSink {
    fun debug(message: String)
    fun info(message: String)
    fun warn(message: String)
    fun error(message: String)
}

private object AndroidMacRemoteControlLogSink : MacRemoteControlLogSink {
    private const val TAG = "MacRemoteControlClient"

    override fun debug(message: String) {
        Log.d(TAG, message)
    }

    override fun info(message: String) {
        Log.i(TAG, message)
    }

    override fun warn(message: String) {
        Log.w(TAG, message)
    }

    override fun error(message: String) {
        Log.e(TAG, message)
    }
}

internal data class MacRemoteTrustedFrameOwnershipSnapshot(
    val currentGeneration: Long,
    val transportGeneration: Long?,
    val secureGeneration: Long?,
    val frameGeneration: Long?,
    val acknowledgementGeneration: Long?,
    val trustedSecurityState: Boolean,
    val acknowledgementOwnsTransport: Boolean,
    val acknowledgementOwnsSecureSession: Boolean
)

internal object MacRemoteTrustedFrameEvidencePolicy {
    fun isExactCurrentOwner(snapshot: MacRemoteTrustedFrameOwnershipSnapshot): Boolean {
        val generation = snapshot.currentGeneration
        return snapshot.trustedSecurityState &&
            snapshot.transportGeneration == generation &&
            snapshot.secureGeneration == generation &&
            snapshot.frameGeneration == generation &&
            snapshot.acknowledgementGeneration == generation &&
            snapshot.acknowledgementOwnsTransport &&
            snapshot.acknowledgementOwnsSecureSession
    }
}

class MacRemoteControlClient internal constructor(
    appContext: Context,
    private val accountBusinessIdentityProvider: AccountBusinessIdentityProvider,
    private val json: Json = Json {
        ignoreUnknownKeys = true
        explicitNulls = false
    },
    private val remoteControlSecurityIdentityProvider: (() -> RemoteControlSecurityIdentity?)? = null,
    // R6.13 no-frame watchdog: injectable clock + thresholds so the decision is deterministic in
    // tests. Defaults use the real wall clock and the shared core policy defaults.
    private val clockMs: () -> Long = { System.currentTimeMillis() },
    private val noFrameInterruptMs: Long = RemoteFrameWatchdogPolicy.NO_FRAME_INTERRUPT_MS,
    private val sessionEndAfterInterruptMs: Long = RemoteFrameWatchdogPolicy.SESSION_END_AFTER_INTERRUPT_MS,
    private val maxReconnects: Int = RemoteFrameWatchdogPolicy.MAX_RECONNECTS,
    private val localIdentityOverride: LocalP2PIdentity? = null,
    private val trustContextOverride: MacRemoteControlTrustContext? = null,
    private val formalRouteAuthorizationLease: MacRemoteFormalRouteAuthorizationLease? = null,
    private val socketFactory: () -> Socket = { Socket() },
    private val socketConnector: (Socket, InetSocketAddress, Int) -> Unit =
        { socket, address, timeout -> socket.connect(address, timeout) },
    private val localXWingAvailability: () -> Boolean = P2PXWingKem::isAvailable,
    private val beforeFormalDialRecheck: () -> Unit = {},
    private val beforeTrustedInputWriteRecheck: () -> Unit = {},
    private val trustedInputDrainTimeoutMillis: Long = TRUSTED_INPUT_DRAIN_TIMEOUT_MILLIS,
    private val streamingFormatsProvider: () -> List<String> =
        AndroidRemoteVideoFormats::supportedStreamingFormats,
    private val logSink: MacRemoteControlLogSink = AndroidMacRemoteControlLogSink
) {
    private enum class HandshakePhase {
        WaitingMessageB,
        WaitingResponderFinished
    }

    private class SecureLanSession(
        val keys: P2PHandshakeWire.DerivedSessionKeys
    ) {
        private val sessionId = RemoteControlSecureEnvelope.deterministicSessionId(keys.transcriptHash)
        private val replayWindow = RemoteControlSecureEnvelope.ReplayWindow()
        private var sendCounter = 0L

        fun sealControlFrame(plaintext: ByteArray): ByteArray {
            if (sendCounter == Long.MAX_VALUE) {
                throw IllegalStateException("remote-control secure envelope counter exhausted")
            }
            sendCounter += 1
            return RemoteControlSecureEnvelope.seal(
                plaintext = plaintext,
                sendKey = keys.sendKey,
                role = RemoteControlSecureEnvelope.Role.INITIATOR,
                sessionId = sessionId,
                transcriptHash = keys.transcriptHash,
                packetType = RemoteControlSecureEnvelope.PacketType.CONTROL,
                counter = sendCounter
            )
        }

        fun openRemoteFrame(packet: ByteArray): RemoteControlSecureEnvelope.Opened {
            val opened = RemoteControlSecureEnvelope.open(
                packet = packet,
                receiveKey = keys.receiveKey,
                role = RemoteControlSecureEnvelope.Role.INITIATOR,
                sessionId = sessionId,
                transcriptHash = keys.transcriptHash,
                allowedPacketTypes = setOf(
                    RemoteControlSecureEnvelope.PacketType.CONTROL,
                    RemoteControlSecureEnvelope.PacketType.SCREEN
                )
            )
            replayWindow.validateAndRecord(opened)
            return opened
        }
    }

    private companion object {
        private val SBP1_MAGIC = byteArrayOf(0x53, 0x42, 0x50, 0x31) // "SBP1"
        private const val MAX_FRAME_BYTES = 32_000_000
        private const val TRUSTED_INPUT_QUEUE_CAPACITY = 256
        private const val TRUSTED_INPUT_DRAIN_TIMEOUT_MILLIS = 750L

        /** R6.13 watchdog evaluation cadence while connected. */
        private const val WATCHDOG_TICK_MS = 500L

        private val STREAM_CONFIGURATION_ACK_RETRY_DELAYS_MS = longArrayOf(1_000L, 2_000L, 4_000L)
        // Mac remote-control approval is explicitly bounded to 1...120 seconds. The early retries
        // consume seven seconds, so the final wait preserves that full manual-approval window.
        private const val STREAM_CONFIGURATION_ACK_FINAL_WAIT_MS = 113_000L
    }

    data class ConnectionTarget(
        val host: String,
        val port: Int = 5901,
        val displayName: String? = null,
        val deviceIdHint: String? = null,
        val advertisedFingerprint: String? = null,
        val advertisedFingerprintTrustSource: FingerprintTrustSource = FingerprintTrustSource.UNAUTHENTICATED_DISCOVERY
    )

    enum class FingerprintTrustSource {
        UNAUTHENTICATED_DISCOVERY,
        TRUSTED_CONFIGURATION
    }

    data class SecurityConfig(
        val encryptionRequired: Boolean = true,
        val allowPlaintextFallback: Boolean = false,
        val allowTrustOnFirstUse: Boolean = false,
        val handshakePolicyOverride: P2PHandshakePolicyOverride? = null
    ) {
        companion object {
            fun formalLanAcceptance(): SecurityConfig = SecurityConfig(
                encryptionRequired = true,
                allowPlaintextFallback = false,
                allowTrustOnFirstUse = false,
                handshakePolicyOverride = P2PHandshakePolicyOverride(
                    requirePqc = true,
                    allowClassicFallback = false,
                    minimumTierRaw = "nativePQC"
                )
            )
        }
    }

    private class ConnectionTransport(
        val generation: Long,
        val socket: Socket
    ) {
        var output: BufferedOutputStream? = null
        var input: BufferedInputStream? = null
    }

    private data class ConnectionContext(
        val generation: Long,
        val target: ConnectionTarget,
        val securityConfig: SecurityConfig,
        val transport: ConnectionTransport
    )

    private data class InvalidatedConnection(
        val generation: Long,
        val connectionJob: Job?,
        val transport: ConnectionTransport?,
        val watchdogJob: Job?
    )

    private data class HandshakeSnapshot(
        val secureSession: SecureLanSession?,
        val handshakeClient: P2PHandshakeClient?,
        val handshakeState: P2PHandshakeClient.InitiatorState?,
        val phase: HandshakePhase?
    )

    private data class TrustedOutboundContext(
        val generation: Long,
        val transport: ConnectionTransport,
        val secureSession: SecureLanSession
    )

    /**
     * One logical stream-configuration operation owned by the existing exact connection context.
     * Retries resend [encodedMessage] verbatim; only the outer secure envelope is resealed with its
     * required fresh counter.
     */
    private class StreamConfigurationOperation(
        val context: ConnectionContext,
        val secureSession: SecureLanSession?,
        val expectation: RemoteDesktopStreamConfigurationAcknowledgementExpectation,
        val encodedMessage: ByteArray,
        val requestedFrameRate: Int
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

    internal data class TrustedFrameEvidence(
        val frame: Frame,
        val securityState: SecurityState.Secure,
        val connectionGeneration: Long
    )

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /**
     * Every transport job owns one immutable generation. A late callback from an older socket must
     * never mutate the state or trust decision of a newer connection.
     */
    private val connectionLifecycleLock = Any()
    private var connectionGeneration: Long = 0L
    private var connectionJob: Job? = null
    /** Guarded by [connectionLifecycleLock]; only a later explicit connect may clear this intent. */
    private var userDisconnectRequested: Boolean = false

    private val _state = MutableStateFlow<State>(State.Disconnected)
    val state: StateFlow<State> = _state.asStateFlow()

    private val _latestFrame = MutableStateFlow<Frame?>(null)
    val latestFrame: StateFlow<Frame?> = _latestFrame.asStateFlow()
    private var latestFrameGeneration: Long? = null

    // Viewer render-admission / decoder status (R6.1, R6.11). Over-limit streams and unsupported
    // codecs surface here (rendering stops but the connection stays up so a compliant stream can
    // resume); decoder failures reported by the surface are surfaced here too.
    private val _viewerStatus = MutableStateFlow<RemoteViewerStatus>(RemoteViewerStatus.Idle)
    val viewerStatus: StateFlow<RemoteViewerStatus> = _viewerStatus.asStateFlow()

    // Advertised/target frame rate this viewer requested from the host (R6.1 constrains the stream's
    // negotiated frame rate). Set when the initial stream configuration is built.
    @Volatile
    private var advertisedTargetFrameRate: Int = RemoteRenderAdmissionPolicy.MAX_FRAME_RATE

    private val _securityState = MutableStateFlow<SecurityState>(SecurityState.Disconnected)
    val securityState: StateFlow<SecurityState> = _securityState.asStateFlow()

    // R6.13 no-frame watchdog state. Reuses the shared pure RemoteFrameWatchdogPolicy so the LAN
    // viewer detects a stalled stream (rather than waiting out the 30s socket read timeout), presents
    // the interrupted notice while RETAINING the last frame, attempts at most one reconnect, and ends
    // the session with cleanup if no new frame arrives within the end window.
    @Volatile private var lastFrameAtMs: Long = 0L
    @Volatile private var interruptedAtMs: Long? = null
    @Volatile private var watchdogReconnectAttempts: Int = 0
    @Volatile private var watchdogReconnecting: Boolean = false
    @Volatile private var reconnectInFlight: Boolean = false
    private var watchdogJob: Job? = null
    private var watchdogGeneration: Long? = null
    private var savedReconnectTarget: ConnectionTarget? = null
    private var savedReconnectConfig: SecurityConfig = SecurityConfig()
    private var savedReconnectEnableHandshake: Boolean = true

    private var activeTransport: ConnectionTransport? = null
    private val writeLock = Any()
    private val localIdentity = localIdentityOverride ?: LocalP2PIdentity(appContext.applicationContext)
    private val trustContext = trustContextOverride ?: MacRemoteControlTrustContextFactory.persistentReadWrite(
        appContext = appContext,
        localIdentity = localIdentity
    )
    private val trustedInputQueue = MacRemoteOrderedInputQueue(
        scope = scope,
        capacity = TRUSTED_INPUT_QUEUE_CAPACITY,
        consume = { input ->
            sendTrustedMessageNow(input)
        },
        terminate = { generation -> finishOrderedInputDisconnect(generation) },
        onFailure = { input, error ->
            failConnection(
                productionSafeFailureReason(
                    reasonCode = "remote_input_write_failed",
                    error = error,
                    diagnosticReason =
                        "remote input write failed: ${error.message ?: error.javaClass.simpleName}"
                ),
                input.generation
            )
        }
    )
    private val trustedInputDrainDeadline = MacRemoteInputDrainDeadline(
        scope = scope,
        timeoutMillis = trustedInputDrainTimeoutMillis,
        onTimeout = ::forceCloseExactInputOwner
    )
    private val pressedInputState = MacRemotePressedInputState()
    private var currentTarget: ConnectionTarget? = null
    private var securityConfig: SecurityConfig = SecurityConfig()

    // Optional: P2P v1 handshake + SBRC app-layer encryption over 5901 frames.
    private var handshakeClient: P2PHandshakeClient? = null
    private var handshakeState: P2PHandshakeClient.InitiatorState? = null
    private var handshakePhase: HandshakePhase? = null
    private var pendingSessionKeys: com.skybridge.compass.shared.p2p.P2PHandshakeWire.DerivedSessionKeys? = null
    private var sessionKeys: com.skybridge.compass.shared.p2p.P2PHandshakeWire.DerivedSessionKeys? = null
    private var secureLanSession: SecureLanSession? = null
    private var secureConnectionGeneration: Long? = null
    private var pendingTrustState: TrustState? = null
    private var pendingTrustFingerprint: String? = null
    private var pendingObservedPeerFingerprint: String? = null
    private var activePeerFingerprint: String? = null
    private var negotiatedSuiteName: String? = null
    private var pendingStreamConfiguration: StreamConfigurationOperation? = null
    private var acknowledgedStreamConfiguration: StreamConfigurationOperation? = null
    private var streamConfigurationAckRetryJob: Job? = null
    private val secureRandom = SecureRandom()

    /**
     * Return a frame only when media, authenticated session, acknowledgement, and transport are all
     * owned by the same current connection generation. The normal viewer may intentionally retain an
     * older frame while its watchdog reconnects; that retained UI frame is never evidence for a new
     * secure session.
     */
    internal fun currentTrustedFrameEvidence(): TrustedFrameEvidence? =
        synchronized(connectionLifecycleLock) {
            val frame = _latestFrame.value ?: return@synchronized null
            val security = _securityState.value as? SecurityState.Secure
                ?: return@synchronized null
            val transport = activeTransport ?: return@synchronized null
            val secureSession = secureLanSession ?: return@synchronized null
            val acknowledged = acknowledgedStreamConfiguration ?: return@synchronized null
            val ownership = MacRemoteTrustedFrameOwnershipSnapshot(
                currentGeneration = connectionGeneration,
                transportGeneration = transport.generation,
                secureGeneration = secureConnectionGeneration,
                frameGeneration = latestFrameGeneration,
                acknowledgementGeneration = acknowledged.context.generation,
                trustedSecurityState =
                    MacRemoteTrustedSessionPolicy.isTrustedRemoteControlSession(security),
                acknowledgementOwnsTransport = acknowledged.context.transport === transport,
                acknowledgementOwnsSecureSession = acknowledged.secureSession === secureSession
            )
            if (!MacRemoteTrustedFrameEvidencePolicy.isExactCurrentOwner(ownership)) {
                return@synchronized null
            }
            TrustedFrameEvidence(
                frame = frame,
                securityState = security,
                connectionGeneration = connectionGeneration
            )
        }

    private fun logHandshake(message: String) {
        logSink.info("LAN handshake: $message")
    }

    private fun logHandshakeWarn(message: String) {
        logSink.warn("LAN handshake: $message")
    }

    fun connect(
        target: ConnectionTarget,
        enableHandshake: Boolean = true,
        securityConfig: SecurityConfig = SecurityConfig()
    ) = connectInternal(
        target = target,
        enableHandshake = enableHandshake,
        securityConfig = securityConfig,
        preserveInterruptedState = false
    )

    private fun connectInternal(
        target: ConnectionTarget,
        enableHandshake: Boolean,
        securityConfig: SecurityConfig,
        preserveInterruptedState: Boolean,
        expectedGenerationToReplace: Long? = null,
        expectedInterruptionAtMs: Long? = null
    ) {
        require((expectedGenerationToReplace == null) == (expectedInterruptionAtMs == null)) {
            "watchdog reconnect requires both generation and interruption token"
        }
        if (trustContext.mode == MacRemoteControlTrustMode.FORMAL_ACCEPTANCE_READ_ONLY) {
            MacRemoteFormalLanSecurityPolicy.requireStrict(
                enableHandshake = enableHandshake,
                config = securityConfig
            )
            try {
                ResolvedBootstrapControlEndpoint.fromResolvedBonjour(
                    hostAddress = target.host,
                    port = target.port
                )
            } catch (error: IllegalArgumentException) {
                failConnection(
                    reason = MacRemoteFormalFailurePolicy.reason(
                        mode = trustContext.mode,
                        reasonCode = "formal_resolved_route_required",
                        error = error,
                        diagnosticReason = "resolved LAN route is required"
                    ),
                    generation = expectedGenerationToReplace,
                    expectedInterruptionAtMs = expectedInterruptionAtMs
                )
                return
            }
        }
        val stablePeerId = try {
            MacRemotePeerIdentityPolicy.stablePeerIdForSecureConnection(
                target = target,
                enableHandshake = enableHandshake,
                securityConfig = securityConfig
            )
        } catch (t: IllegalArgumentException) {
            failConnection(
                reason = MacRemoteFormalFailurePolicy.reason(
                    mode = trustContext.mode,
                    reasonCode = "formal_target_validation_failed",
                    error = t,
                    diagnosticReason = t.message ?: "stable peer identity is required"
                ),
                generation = expectedGenerationToReplace,
                expectedInterruptionAtMs = expectedInterruptionAtMs
            )
            return
        }
        val pinned = try {
            if (trustContext.mode == MacRemoteControlTrustMode.FORMAL_ACCEPTANCE_READ_ONLY) {
                requireFormalPreDialReady(target)
                true
            } else {
                stablePeerId?.let { trustContext.peerSigningFingerprints.isPeerPinned(it) } == true
            }
        } catch (error: Exception) {
            failConnection(
                reason = MacRemoteFormalFailurePolicy.reason(
                    mode = trustContext.mode,
                    reasonCode = "formal_trust_precheck_failed",
                    error = error,
                    diagnosticReason = error.message ?: "peer trust state is unavailable"
                ),
                generation = expectedGenerationToReplace,
                expectedInterruptionAtMs = expectedInterruptionAtMs
            )
            return
        }
        try {
            MacRemoteFormalRouteAuthorizationPolicy.requireCurrent(
                mode = trustContext.mode,
                lease = formalRouteAuthorizationLease
            )
        } catch (error: IllegalArgumentException) {
            failConnection(
                reason = MacRemoteFormalFailurePolicy.reason(
                    mode = trustContext.mode,
                    reasonCode = "formal_route_lease_expired",
                    error = error,
                    diagnosticReason = "route authorization expired"
                ),
                generation = expectedGenerationToReplace,
                expectedInterruptionAtMs = expectedInterruptionAtMs
            )
            return
        }
        val generation = if (expectedGenerationToReplace == null) {
            invalidateConnectionForExplicitConnect()
        } else {
            forceReplaceExactWatchdogConnection(
                expectedGeneration = expectedGenerationToReplace,
                expectedInterruptionAtMs = requireNotNull(expectedInterruptionAtMs)
            )?.generation ?: return
        }
        resetConnectionState(generation, preserveInterruptedState)
        val transport = ConnectionTransport(generation = generation, socket = socketFactory())
        val context = ConnectionContext(
            generation = generation,
            target = target,
            securityConfig = securityConfig,
            transport = transport
        )
        val stateInstalled = runIfCurrentConnection(generation) {
            reconnectInFlight = preserveInterruptedState
            this.currentTarget = target
            this.securityConfig = securityConfig
            // R6.13: remember the connection parameters so the single watchdog reconnect can re-dial
            // the same host. Only a normal user connection resets the interruption window.
            savedReconnectTarget = target
            savedReconnectConfig = securityConfig
            savedReconnectEnableHandshake = enableHandshake
            if (!preserveInterruptedState) {
                lastFrameAtMs = clockMs()
                interruptedAtMs = null
                watchdogReconnectAttempts = 0
                watchdogReconnecting = false
            }
            _state.value = State.Connecting(target)
            _securityState.value = if (enableHandshake) {
                SecurityState.Negotiating(
                    peerId = stablePeerId,
                    pinned = pinned
                )
            } else {
                SecurityState.Disconnected
            }
        }
        if (!stateInstalled) {
            closeTransport(transport)
            return
        }
        logHandshake(
                "connect targetHost=${SensitiveLogRedaction.identifier(target.host)} targetPort=${target.port} handshake=$enableHandshake " +
                "requireSecure=${securityConfig.encryptionRequired} allowPlaintext=${securityConfig.allowPlaintextFallback} " +
                "peerHint=${SensitiveLogRedaction.identifier(stablePeerId)}"
        )

        val job = scope.launch(start = CoroutineStart.LAZY) {
            try {
                if (trustContext.mode == MacRemoteControlTrustMode.FORMAL_ACCEPTANCE_READ_ONLY) {
                    try {
                        beforeFormalDialRecheck()
                        requireFormalPreDialReady(target)
                    } catch (error: Exception) {
                        failConnection(
                            MacRemoteFormalFailurePolicy.reason(
                                mode = trustContext.mode,
                                reasonCode = "formal_predial_recheck_failed",
                                error = error,
                                diagnosticReason = "formal LAN authorization changed before dial"
                            ),
                            context.generation
                        )
                        return@launch
                    }
                }
                val s = context.transport.socket
                MacRemoteControlReadDeadlinePolicy.configureSocket(s)
                socketConnector(
                    s,
                    InetSocketAddress(target.host, target.port),
                    MacRemoteControlReadDeadlinePolicy.CONNECT_TIMEOUT_MILLIS
                )

                val connectedOutput = BufferedOutputStream(s.getOutputStream())
                val connectedInput = BufferedInputStream(s.getInputStream())
                if (!installConnectedStreams(
                        context = context,
                        connectedOutput = connectedOutput,
                        connectedInput = connectedInput
                    )
                ) {
                    closeTransportResource("input", connectedInput)
                    closeTransportResource("output", connectedOutput)
                    closeTransport(context.transport)
                    return@launch
                }

                val connectedStateInstalled = runIfCurrentConnection(context) {
                    _state.value = State.Connected(target)
                    // A socket opening is not evidence that a stalled stream recovered. During the
                    // watchdog re-dial, only an admitted frame resets lastFrameAtMs/interruptedAtMs.
                    if (!preserveInterruptedState) {
                        lastFrameAtMs = clockMs()
                    }
                }
                if (!connectedStateInstalled) {
                    closeTransport(context.transport)
                    return@launch
                }
                if (!enableHandshake && !canAcceptPlaintext(context.securityConfig)) {
                    failConnection("remote handshake disabled by caller", context.generation)
                    return@launch
                }

                if ((!enableHandshake || !securityConfig.encryptionRequired) &&
                    canAcceptPlaintext(context.securityConfig)
                ) {
                    logHandshake("sending initial plaintext stream configuration")
                    sendInitialStreamConfigurationNow(
                        secureSession = null,
                        context = context
                    )
                }

                if (enableHandshake) {
                    startHandshake(context)
                } else if (!securityConfig.encryptionRequired) {
                    runIfCurrentConnection(context) {
                        markPlaintext("handshake disabled", context.target)
                    }
                }
                readLoop(context)
            } catch (t: CancellationException) {
                throw t
            } catch (t: Throwable) {
                failConnection(
                    MacRemoteFormalFailurePolicy.reason(
                        mode = trustContext.mode,
                        reasonCode = "formal_transport_failed",
                        error = t,
                        diagnosticReason = t.message ?: "connect failed"
                    ),
                    context.generation
                )
            }
        }
        if (!registerConnectionOwner(context, job)) {
            job.cancel()
            closeTransport(context.transport)
            return
        }
        if (preserveInterruptedState) {
            // Keep the original interruption deadline running while the replacement socket dials
            // and negotiates. This watchdog is owned by the new generation, so the old job cannot
            // terminate it or a later user connection.
            startWatchdog(context.generation)
        }
        job.invokeOnCompletion { clearConnectionJob(context.generation, job) }
        job.start()
    }

    private fun requireFormalPreDialReady(target: ConnectionTarget) {
        MacRemoteFormalRouteAuthorizationPolicy.requireCurrent(
            mode = trustContext.mode,
            lease = formalRouteAuthorizationLease
        )
        MacRemoteFormalPreDialPolicy.requireReady(
            mode = trustContext.mode,
            target = target,
            trustContext = trustContext,
            localXWingAvailable = localXWingAvailability()
        )
    }

    fun disconnect() {
        val watchdogToCancel = synchronized(connectionLifecycleLock) {
            userDisconnectRequested = true
            interruptedAtMs = null
            watchdogGeneration = null
            watchdogReconnecting = false
            reconnectInFlight = false
            watchdogJob.also { watchdogJob = null }
        }
        watchdogToCancel?.cancel()
        val outboundContext = trustedOutboundContext()
        if (
            outboundContext != null &&
            trustedInputQueue.requestTerminal(outboundContext.generation)
        ) {
            val owner = MacRemoteInputDrainOwner(
                generation = outboundContext.generation,
                transportIdentity = outboundContext.transport
            )
            if (trustedInputDrainDeadline.arm(owner) && !isInputDrainOwnerCurrent(owner)) {
                trustedInputDrainDeadline.clearIfOwned(owner)
            }
            if (isInputDrainOwnerCurrent(owner)) return
            trustedInputDrainDeadline.clearIfOwned(owner)
        }
        // Before stream acknowledgement there is no trusted outbound terminal context, but a
        // handshake/stream-config writer may already be blocked while holding writeLock. Detach and
        // socket-close the current exact transport first so disconnect never waits behind that I/O.
        val generation = forceInvalidateUserDisconnectIntent()?.generation ?: return
        resetConnectionState(generation)
    }

    private fun invalidateConnectionForExplicitConnect(): Long =
        requireNotNull(invalidateConnectionIfCurrent(clearUserDisconnectIntent = true))

    private fun invalidateConnectionIfCurrent(
        expectedGeneration: Long? = null,
        clearUserDisconnectIntent: Boolean = false
    ): Long? {
        val invalidated = synchronized(writeLock) {
            synchronized(connectionLifecycleLock) lifecycle@{
                if (expectedGeneration != null && connectionGeneration != expectedGeneration) {
                    return@lifecycle null
                }
                if (clearUserDisconnectIntent) {
                    userDisconnectRequested = false
                }
                detachCurrentConnectionLocked()
            }
        } ?: return null
        invalidated.connectionJob?.cancel()
        invalidated.watchdogJob?.cancel()
        trustedInputQueue.clear()
        invalidated.transport?.let { transport ->
            trustedInputDrainDeadline.clearIfOwned(
                MacRemoteInputDrainOwner(transport.generation, transport)
            )
        }
        invalidated.transport?.let(::closeTransport)
        return invalidated.generation
    }

    private fun isInputDrainOwnerCurrent(owner: MacRemoteInputDrainOwner): Boolean =
        synchronized(connectionLifecycleLock) {
            owner.matches(connectionGeneration, activeTransport)
        }

    /**
     * A blocking Java socket write cannot be cancelled cooperatively. The bounded-drain timeout
     * therefore detaches one exact generation/transport under the lifecycle lock, closes that exact
     * socket without waiting for [writeLock], and lets peer EOF teardown release injected input.
     */
    private fun forceCloseExactInputOwner(owner: MacRemoteInputDrainOwner) {
        val invalidated = forceInvalidateExactInputOwner(owner) ?: return
        resetConnectionState(invalidated.generation)
    }

    private fun forceInvalidateExactInputOwner(
        owner: MacRemoteInputDrainOwner
    ): InvalidatedConnection? {
        val invalidated = detachIfCurrentMacRemoteInputOwner(
            lifecycleLock = connectionLifecycleLock,
            owner = owner,
            currentGeneration = { connectionGeneration },
            currentTransportIdentity = { activeTransport },
            detach = ::detachCurrentConnectionLocked
        ) ?: return null
        finishForcedConnectionInvalidation(invalidated)
        return invalidated
    }

    /** Watchdog replacement cannot consume a transport after an explicit disconnect linearizes. */
    private fun forceReplaceExactWatchdogConnection(
        expectedGeneration: Long,
        expectedInterruptionAtMs: Long
    ): InvalidatedConnection? {
        val owner = synchronized(connectionLifecycleLock) {
            activeTransport?.let { transport ->
                MacRemoteWatchdogConnectionOwner(
                    generation = expectedGeneration,
                    transportIdentity = transport,
                    interruptionAtMs = expectedInterruptionAtMs
                )
            }
        } ?: return null
        val invalidated = detachIfCurrentMacRemoteWatchdogOwner(
            lifecycleLock = connectionLifecycleLock,
            owner = owner,
            currentGeneration = { connectionGeneration },
            currentTransportIdentity = { activeTransport },
            currentInterruptionAtMs = { interruptedAtMs },
            lastFrameAtMs = { lastFrameAtMs },
            additionalCurrent = { !userDisconnectRequested },
            detach = ::detachCurrentConnectionLocked
        ) ?: return null
        finishForcedConnectionInvalidation(invalidated)
        return invalidated
    }

    /** Invalidates even an ownerless watchdog detach/register gap without waiting for writeLock. */
    private fun forceInvalidateUserDisconnectIntent(): InvalidatedConnection? {
        val invalidated = detachMacRemoteConnectionForUserDisconnect(
            lifecycleLock = connectionLifecycleLock,
            userDisconnectRequested = { userDisconnectRequested },
            detach = ::detachCurrentConnectionLocked
        ) ?: return null
        finishForcedConnectionInvalidation(invalidated)
        return invalidated
    }

    private fun forceInvalidateExactWatchdogConnection(
        expectedGeneration: Long,
        expectedInterruptionAtMs: Long
    ): InvalidatedConnection? {
        val owner = synchronized(connectionLifecycleLock) {
            activeTransport?.let { transport ->
                MacRemoteWatchdogConnectionOwner(
                    generation = expectedGeneration,
                    transportIdentity = transport,
                    interruptionAtMs = expectedInterruptionAtMs
                )
            }
        } ?: return null
        val invalidated = detachIfCurrentMacRemoteWatchdogOwner(
            lifecycleLock = connectionLifecycleLock,
            owner = owner,
            currentGeneration = { connectionGeneration },
            currentTransportIdentity = { activeTransport },
            currentInterruptionAtMs = { interruptedAtMs },
            lastFrameAtMs = { lastFrameAtMs },
            detach = ::detachCurrentConnectionLocked
        ) ?: return null
        finishForcedConnectionInvalidation(invalidated)
        return invalidated
    }

    /** Must be called with [connectionLifecycleLock] held. */
    private fun detachCurrentConnectionLocked(): InvalidatedConnection {
        connectionGeneration = Math.addExact(connectionGeneration, 1L)
        return InvalidatedConnection(
            generation = connectionGeneration,
            connectionJob = connectionJob.also { connectionJob = null },
            transport = activeTransport.also { activeTransport = null },
            watchdogJob = watchdogJob.also {
                watchdogJob = null
                watchdogGeneration = null
            }
        )
    }

    /** Completes an already-linearized exact detach without waiting for [writeLock]. */
    private fun finishForcedConnectionInvalidation(invalidated: InvalidatedConnection) {
        invalidated.connectionJob?.cancel()
        invalidated.watchdogJob?.cancel()
        trustedInputQueue.clear()
        invalidated.transport?.let { transport ->
            trustedInputDrainDeadline.clearIfOwned(
                MacRemoteInputDrainOwner(transport.generation, transport)
            )
        }
        invalidated.transport?.let(::interruptAndCloseTransport)
    }

    private fun registerConnectionOwner(context: ConnectionContext, job: Job): Boolean =
        synchronized(connectionLifecycleLock) {
            if (
                !userDisconnectRequested &&
                connectionGeneration == context.generation &&
                activeTransport == null
            ) {
                activeTransport = context.transport
                connectionJob = job
                true
            } else {
                false
            }
        }

    private fun clearConnectionJob(generation: Long, job: Job) {
        synchronized(connectionLifecycleLock) {
            if (connectionGeneration == generation && connectionJob === job) {
                connectionJob = null
            }
        }
    }

    private fun isCurrentConnection(generation: Long): Boolean =
        synchronized(connectionLifecycleLock) { connectionGeneration == generation }

    private fun isCurrentConnection(context: ConnectionContext): Boolean =
        synchronized(connectionLifecycleLock) {
            connectionGeneration == context.generation && activeTransport === context.transport
        }

    private inline fun runIfCurrentConnection(generation: Long?, block: () -> Unit): Boolean {
        if (generation == null) {
            block()
            return true
        }
        return synchronized(connectionLifecycleLock) {
            if (connectionGeneration != generation) {
                false
            } else {
                block()
                true
            }
        }
    }

    private inline fun runIfCurrentConnection(context: ConnectionContext, block: () -> Unit): Boolean =
        synchronized(connectionLifecycleLock) {
            if (connectionGeneration != context.generation || activeTransport !== context.transport) {
                false
            } else {
                block()
                true
            }
        }

    private fun installConnectedStreams(
        context: ConnectionContext,
        connectedOutput: BufferedOutputStream,
        connectedInput: BufferedInputStream
    ): Boolean = synchronized(connectionLifecycleLock) {
        if (connectionGeneration != context.generation || activeTransport !== context.transport) {
            false
        } else {
            context.transport.output = connectedOutput
            context.transport.input = connectedInput
            true
        }
    }

    private fun transportForGeneration(generation: Long): ConnectionTransport? =
        synchronized(connectionLifecycleLock) {
            activeTransport?.takeIf {
                connectionGeneration == generation && it.generation == generation
            }
        }

    private fun handshakeSnapshot(context: ConnectionContext): HandshakeSnapshot? =
        synchronized(connectionLifecycleLock) {
            if (connectionGeneration != context.generation || activeTransport !== context.transport) {
                null
            } else {
                HandshakeSnapshot(
                    secureSession = secureLanSession,
                    handshakeClient = handshakeClient,
                    handshakeState = handshakeState,
                    phase = handshakePhase
                )
            }
        }

    private fun resetConnectionState(
        generation: Long,
        preserveInterruptedState: Boolean = false,
        disconnectedViewerStatus: RemoteViewerStatus = RemoteViewerStatus.Idle
    ) {
        runIfCurrentConnection(generation) {
            // R6.13/R6.9: on a user-initiated disconnect (NOT the single watchdog reconnect) tear the
            // watchdog down and end the session cleanly. When reconnectInFlight, the retained frame +
            // watchdog state are preserved for the single internal re-dial.
            if (!preserveInterruptedState) {
                watchdogJob?.cancel()
                watchdogJob = null
                watchdogGeneration = null
                interruptedAtMs = null
                watchdogReconnectAttempts = 0
                watchdogReconnecting = false
                reconnectInFlight = false
                lastFrameAtMs = 0L
                _latestFrame.value = null
                latestFrameGeneration = null
                _viewerStatus.value = disconnectedViewerStatus
            }
            advertisedTargetFrameRate = RemoteRenderAdmissionPolicy.MAX_FRAME_RATE
            handshakeClient = null
            handshakeState = null
            handshakePhase = null
            pendingSessionKeys = null
            sessionKeys = null
            secureLanSession = null
            secureConnectionGeneration = null
            pressedInputState.clear()
            pendingTrustState = null
            pendingTrustFingerprint = null
            pendingObservedPeerFingerprint = null
            activePeerFingerprint = null
            negotiatedSuiteName = null
            streamConfigurationAckRetryJob?.cancel()
            streamConfigurationAckRetryJob = null
            pendingStreamConfiguration = null
            acknowledgedStreamConfiguration = null
            currentTarget = null
            _state.value = State.Disconnected
            _securityState.value = SecurityState.Disconnected
        }
    }

    /** True only when the trusted channel also has an exact accepted stream configuration. */
    fun hasSecureChannel(): Boolean = trustedOutboundContext() != null

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

    internal fun sendKeyStroke(keyCode: MacVirtualKeyCode) {
        val now = System.currentTimeMillis().toDouble() / 1000.0
        sendMessages(
            RemoteInputMessages.keyStroke(json = json, keyCode = keyCode, timestamp = now)
        )
    }

    // R6.3: scroll is expressed as a MOUSE_EVENT with a scroll MouseEventType, exactly as the macOS
    // host expects — no new wire fields (G4). Reuses the same immediate secure-channel send path as
    // the pointer/keyboard senders; UI gates these on hasSecureChannel() (view-only when closed).
    fun sendScrollUp(x: Double, y: Double) = sendMouse(MouseEventType.SCROLL_UP, x, y)
    fun sendScrollDown(x: Double, y: Double) = sendMouse(MouseEventType.SCROLL_DOWN, x, y)

    private fun sendMessage(msg: RemoteMessage) {
        sendMessages(listOf(msg))
    }

    private fun sendMessages(messages: List<RemoteMessage>) {
        require(messages.isNotEmpty()) { "remote input message batch must not be empty" }
        val outboundContext = trustedOutboundContext() ?: return
        when (
            trustedInputQueue.enqueueAll(
                messages.map { message ->
                    MacRemoteQueuedInput.from(outboundContext.generation, message)
                }
            )
        ) {
            MacRemoteOrderedInputQueue.OfferResult.ACCEPTED -> Unit
            MacRemoteOrderedInputQueue.OfferResult.TERMINATING -> Unit
            MacRemoteOrderedInputQueue.OfferResult.FULL -> failConnection(
                "reasonCode=remote_input_queue_capacity_exceeded exception=IllegalStateException",
                outboundContext.generation
            )
        }
    }

    private fun readLoop(context: ConnectionContext) {
        val ins = context.transport.input ?: return
        val header = ByteArray(4)
        while (isCurrentConnection(context)) {
            val frameDeadline = MacRemoteControlReadDeadlinePolicy.newDeadline()
            val updateReadTimeout: (Int) -> Unit = { remainingMillis ->
                context.transport.socket.soTimeout = remainingMillis
            }
            val readHeader = MacRemoteControlReadDeadlinePolicy.readFully(
                input = ins,
                out = header,
                stage = MacRemoteControlReadDeadlinePolicy.Stage.FRAME_HEADER,
                deadline = frameDeadline,
                updateReadTimeoutMillis = updateReadTimeout
            )
            if (!readHeader) throw IllegalStateException("connection closed")
            if (!isCurrentConnection(context)) return
            val len = ByteBuffer.wrap(header).order(ByteOrder.BIG_ENDIAN).int
            require(len > 0 && len <= MAX_FRAME_BYTES) { "invalid frame length: $len" }

            val payload = ByteArray(len)
            val ok = MacRemoteControlReadDeadlinePolicy.readFully(
                input = ins,
                out = payload,
                stage = MacRemoteControlReadDeadlinePolicy.Stage.FRAME_PAYLOAD,
                deadline = frameDeadline,
                updateReadTimeoutMillis = updateReadTimeout
            )
            if (!ok) throw IllegalStateException("connection closed")
            if (!isCurrentConnection(context)) return

            runCatching { handleInboundFrame(payload, context) }
                .onFailure { err ->
                    if (err is CancellationException) throw err
                    failConnection(
                        productionSafeFailureReason(
                            reasonCode = "inbound_frame_handling_failed",
                            error = err,
                            diagnosticReason =
                                "inbound frame handling failed: ${err.message ?: err.javaClass.simpleName}"
                        ),
                        context.generation
                    )
                    return
                }
        }
    }

    private fun handleInboundFrame(frameBytes: ByteArray, context: ConnectionContext) {
        val snapshot = handshakeSnapshot(context) ?: return
        if (snapshot.phase != null) {
            logHandshake(
                "rx frame bytes=${frameBytes.size} phase=${snapshot.phase.name} " +
                    "looksHandshake=${looksLikeHandshakeFrame(frameBytes)} looksJson=${looksLikeJson(frameBytes)} " +
                    "pendingKeys=${snapshot.handshakeState != null} sessionKeys=${snapshot.secureSession != null}"
            )
        }

        // 1) If handshake established, business frames must be SBRC envelopes.
        snapshot.secureSession?.let { session ->
            val opened = try {
                session.openRemoteFrame(frameBytes)
            } catch (t: Throwable) {
                failConnection(
                    productionSafeFailureReason(
                        reasonCode = "encrypted_payload_authentication_failed",
                        error = t,
                        diagnosticReason = "encrypted remote payload authentication failed: " +
                            (t.message ?: t.javaClass.simpleName)
                    ),
                    context.generation
                )
                return
            }
            if (isCurrentConnection(context)) {
                handleRemotePayload(opened, context)
            }
            return
        }

        // 2) If handshake is in progress, accept interleaved screen frames without aborting handshake.
        val hsClient = snapshot.handshakeClient
        val phase = snapshot.phase
        if (hsClient != null && phase != null) {
            if (looksLikeHandshakeFrame(frameBytes)) {
                when (phase) {
                    HandshakePhase.WaitingMessageB -> {
                        val hsState = snapshot.handshakeState ?: return
                        val trustEvaluation = evaluatePeerTrust(frameBytes, context) ?: return
                        try {
                            val res = hsClient.finish(
                                state = hsState,
                                rawMessageB = frameBytes,
                                peerIdForTrust = null,
                                trustStore = null
                            )
                            MacRemoteFormalKemPolicy.requireNegotiatedSuite(
                                mode = trustContext.mode,
                                negotiatedSuite = res.negotiatedSuite
                            )
                            val stateCommitted = runIfCurrentConnection(context) {
                                pendingSessionKeys = res.sessionKeys
                                pendingTrustState = trustEvaluation.trustState
                                pendingTrustFingerprint = trustEvaluation.fingerprintToPersist
                                pendingObservedPeerFingerprint = trustEvaluation.observedFingerprint
                                negotiatedSuiteName = res.negotiatedSuite.name
                                logHandshake(
                                    "verified MessageB suite=${res.negotiatedSuite.name} " +
                                        "fingerprint=${SensitiveLogRedaction.identifier(activePeerFingerprint)} " +
                                        "trust=${trustEvaluation.trustState}"
                                )
                                handshakeState = null
                                handshakePhase = HandshakePhase.WaitingResponderFinished
                            }
                            if (!stateCommitted) return
                            sendRawFrame(res.clientFinishedToSend, context.generation)
                            logHandshake("sent client Finished bytes=${res.clientFinishedToSend.size}")
                        } catch (error: CancellationException) {
                            throw error
                        } catch (error: Throwable) {
                            handleHandshakeFailure(
                                MacRemoteFormalFailurePolicy.reason(
                                    mode = trustContext.mode,
                                    reasonCode = "formal_message_b_verification_failed",
                                    error = error,
                                    diagnosticReason = "messageB verify failed: ${error.message ?: "unknown"}"
                                ),
                                context
                            )
                        }
                        return
                    }
                    HandshakePhase.WaitingResponderFinished -> {
                        val pendingKeys = pendingSessionKeys ?: return
                        val ok = try {
                            hsClient.verifyResponderFinished(frameBytes, pendingKeys)
                        } catch (error: CancellationException) {
                            throw error
                        } catch (_: Exception) {
                            false
                        }
                        if (ok) {
                            val committed = try {
                                runIfCurrentConnection(context) {
                                    if (pendingSessionKeys !== pendingKeys) {
                                        error("handshake session was superseded before trust commit")
                                    }
                                    val trustState = pendingTrustState ?: TrustState.UNTRUSTED_EPHEMERAL
                                    if (trustContext.mode == MacRemoteControlTrustMode.FORMAL_ACCEPTANCE_READ_ONLY) {
                                        MacRemoteFormalRouteAuthorizationPolicy.requireCurrent(
                                            mode = trustContext.mode,
                                            lease = formalRouteAuthorizationLease
                                        )
                                        MacRemoteFormalTrustCommitPolicy.requireUnchangedAuthority(
                                            mode = trustContext.mode,
                                            trustStore = trustContext.peerSigningFingerprints,
                                            peerId = requireNotNull(peerIdHint(context.target)) {
                                                "formal LAN peer identity is unavailable at session commit"
                                            },
                                            observedFingerprint = requireNotNull(pendingObservedPeerFingerprint) {
                                                "formal LAN observed authority is unavailable at session commit"
                                            }
                                        )
                                    }
                                    MacRemoteTrustedSessionPolicy.requireTrustedRemoteControlTrust(
                                        peerId = peerIdHint(context.target),
                                        trustState = trustState
                                    )
                                    pendingTrustFingerprint?.let { fingerprint ->
                                        trustContext.peerSigningFingerprints.savePeerSigningFingerprint(
                                            peerId = requireNotNull(peerIdHint(context.target)),
                                            peerSigningFingerprint = fingerprint
                                        )
                                    }
                                    val establishedSession = SecureLanSession(pendingKeys)
                                    sessionKeys = pendingKeys
                                    secureLanSession = establishedSession
                                    secureConnectionGeneration = context.generation
                                    clearHandshakeState(keepSessionKeys = true)
                                    _securityState.value = SecurityState.Secure(
                                        peerId = peerIdHint(context.target),
                                        fingerprint = activePeerFingerprint,
                                        suite = negotiatedSuiteName ?: "unknown",
                                        trustState = trustState
                                    )
                                }
                            } catch (error: CancellationException) {
                                throw error
                            } catch (error: Throwable) {
                                failTrustedIdentityNegotiation(
                                    MacRemoteFormalFailurePolicy.reason(
                                        mode = trustContext.mode,
                                        reasonCode = "formal_finished_commit_failed",
                                        error = error,
                                        diagnosticReason = error.message ?: "peer identity is not trusted"
                                    ),
                                    context.generation
                                )
                                return
                            }
                            if (!committed) return
                            logHandshake("responder Finished verified; secure channel established suite=${negotiatedSuiteName ?: "unknown"}")
                            sendEncryptedStreamConfigurationIfNeeded(context)
                        } else {
                            handleHandshakeFailure(
                                "responder Finished verification failed",
                                context
                            )
                        }
                        return
                    }
                }
            }

            if (phase == HandshakePhase.WaitingResponderFinished) {
                handleHandshakeFailure(
                    "expected responder Finished before encrypted business payload",
                    context
                )
                return
            }

            // Legacy plaintext JSON (server did not enable handshake/encryption).
            if (looksLikeJson(frameBytes) && canAcceptPlaintext(context.securityConfig)) {
                val current = runIfCurrentConnection(context) {
                    markPlaintext("server stayed on plaintext transport", context.target)
                }
                if (!current) return
                handleRemoteJsonFrame(frameBytes, context)
            } else if (looksLikeJson(frameBytes)) {
                handleHandshakeFailure(
                    "plaintext remote payload rejected by security policy",
                    context
                )
            } else {
                handleHandshakeFailure(
                    "unexpected non-handshake frame during negotiation",
                    context
                )
            }
            return
        }

        // 3) Legacy plaintext
        if (looksLikeJson(frameBytes) && canAcceptPlaintext(context.securityConfig)) {
            val current = runIfCurrentConnection(context) {
                markPlaintext("legacy plaintext transport", context.target)
            }
            if (!current) return
            handleRemoteJsonFrame(frameBytes, context)
        } else if (looksLikeJson(frameBytes)) {
            failConnection("plaintext remote payload rejected by security policy", context.generation)
        }
    }

    private fun clearHandshakeState(keepSessionKeys: Boolean = false) {
        handshakeClient = null
        handshakeState = null
        handshakePhase = null
        pendingSessionKeys = null
        pendingTrustState = null
        pendingTrustFingerprint = null
        pendingObservedPeerFingerprint = null
        if (!keepSessionKeys) {
            sessionKeys = null
            secureLanSession = null
            secureConnectionGeneration = null
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

    private fun handleRemotePayload(
        opened: RemoteControlSecureEnvelope.Opened,
        context: ConnectionContext
    ) {
        when (opened.packetType) {
            RemoteControlSecureEnvelope.PacketType.CONTROL ->
                handleRemoteControlMessage(opened.payload, context)
            RemoteControlSecureEnvelope.PacketType.SCREEN ->
                handleRemoteScreenPayload(opened.payload, context)
            RemoteControlSecureEnvelope.PacketType.AUDIO ->
                error("audio frames are not supported on Android LAN remote viewer")
        }
    }

    private fun handleRemoteControlMessage(jsonBytes: ByteArray, context: ConnectionContext) {
        val msg = RemoteControlWireCodec.decodeMessage(jsonBytes)
        when (msg.type) {
            RemoteMessage.MessageType.SCREEN_DATA -> handleRemoteScreenMessage(msg, context)
            RemoteMessage.MessageType.STREAM_CONFIGURATION_ACK ->
                handleStreamConfigurationAcknowledgement(msg, context)
            RemoteMessage.MessageType.DAMAGE_REPORT,
            RemoteMessage.MessageType.CURSOR_UPDATE,
            RemoteMessage.MessageType.OVERLAY_UPDATE -> {
                requireAcknowledgedStreamConfiguration(context)
                logSink.debug("LAN remote control message ignored: ${msg.type}")
            }
            RemoteMessage.MessageType.CLIPBOARD,
            RemoteMessage.MessageType.KEYBOARD_EVENT,
            RemoteMessage.MessageType.MOUSE_EVENT,
            RemoteMessage.MessageType.STREAM_CONFIGURATION ->
                error("unexpected remote control message from responder: ${msg.type}")
        }
    }

    private fun handleStreamConfigurationAcknowledgement(
        message: RemoteMessage,
        context: ConnectionContext
    ) {
        val acknowledgement =
            RemoteControlWireCodec.decodeStreamConfigurationAcknowledgement(message)
        var retryJobToCancel: Job? = null
        val decision = synchronized(writeLock) {
            synchronized(connectionLifecycleLock) {
                if (connectionGeneration != context.generation || activeTransport !== context.transport) {
                    return
                }
                val pending = pendingStreamConfiguration?.takeIf { it.context === context }
                val acknowledged = acknowledgedStreamConfiguration?.takeIf { it.context === context }
                val result = RemoteDesktopStreamConfigurationAcknowledgementPolicy.decide(
                    acknowledgement = acknowledgement,
                    awaiting = pending?.expectation,
                    acknowledged = acknowledged?.expectation
                )
                if (result == RemoteDesktopStreamConfigurationAcknowledgementDecision.ACCEPT) {
                    val acceptedOperation = requireNotNull(pending)
                    pendingStreamConfiguration = null
                    acknowledgedStreamConfiguration = acceptedOperation
                    advertisedTargetFrameRate = acceptedOperation.requestedFrameRate
                    retryJobToCancel = streamConfigurationAckRetryJob
                    streamConfigurationAckRetryJob = null
                }
                result
            }
        }
        when (decision) {
            RemoteDesktopStreamConfigurationAcknowledgementDecision.ACCEPT -> Unit
            RemoteDesktopStreamConfigurationAcknowledgementDecision.IGNORE_DUPLICATE -> {
                logHandshake("duplicate exact stream configuration acknowledgement ignored")
                return
            }
            RemoteDesktopStreamConfigurationAcknowledgementDecision.REJECT_UNEXPECTED,
            RemoteDesktopStreamConfigurationAcknowledgementDecision.REJECT_CONFLICTING -> {
                error("invalid stream configuration acknowledgement: $decision")
            }
        }
        retryJobToCancel?.cancel()
        logHandshake("stream configuration acknowledgement accepted")
        startWatchdogForStreaming(context)
    }

    private fun requireAcknowledgedStreamConfiguration(context: ConnectionContext) {
        val acknowledged = synchronized(connectionLifecycleLock) {
            connectionGeneration == context.generation &&
                activeTransport === context.transport &&
                acknowledgedStreamConfiguration?.context === context
        }
        check(acknowledged) {
            "remote media received before exact stream configuration acknowledgement"
        }
    }

    private fun handleRemoteScreenPayload(payload: ByteArray, context: ConnectionContext) {
        if (looksLikeJson(payload)) {
            val msg = RemoteControlWireCodec.decodeMessage(payload)
            handleRemoteScreenMessage(msg, context)
            return
        }
        error("binary remote screen payload is not supported by Android LAN remote viewer")
    }

    private fun handleRemoteJsonFrame(jsonBytes: ByteArray, context: ConnectionContext) {
        handleRemoteControlMessage(jsonBytes, context)
    }

    private fun handleRemoteScreenMessage(msg: RemoteMessage, context: ConnectionContext) {
        requireAcknowledgedStreamConfiguration(context)
        val screen = RemoteControlWireCodec.decodeScreenData(msg)
        val normalizedFormat = AndroidRemoteVideoFormats.normalizeIncomingFormat(
            format = screen.format,
            payload = screen.imageData
        )

        // R6.1/R6.11: refuse over-limit streams and unsupported codecs and surface the reason to the
        // viewer status instead of silently dropping the frame or tearing down the whole connection.
        // Rendering stops (frame cleared) while the transport stays up so a compliant stream can
        // resume.
        runIfCurrentConnection(context) {
            when (val decision = RemoteRenderAdmissionPolicy.decide(
                format = normalizedFormat,
                width = screen.width,
                height = screen.height,
                frameRate = advertisedTargetFrameRate
            )) {
                is RemoteRenderAdmissionPolicy.Decision.Admit -> {
                    // R6.13: a freshly admitted frame resets the no-frame watchdog and completes a
                    // watchdog reconnect's recovery window.
                    lastFrameAtMs = clockMs()
                    interruptedAtMs = null
                    watchdogReconnectAttempts = 0
                    watchdogReconnecting = false
                    reconnectInFlight = false
                    _viewerStatus.value = RemoteViewerStatus.Rendering
                    _latestFrame.value = Frame(
                        width = screen.width,
                        height = screen.height,
                        format = normalizedFormat,
                        timestamp = screen.timestamp,
                        imageBytes = screen.imageData
                    )
                    latestFrameGeneration = context.generation
                }

                is RemoteRenderAdmissionPolicy.Decision.Reject -> {
                    _latestFrame.value = null
                    latestFrameGeneration = null
                    _viewerStatus.value = RemoteViewerStatus.OverLimit(
                        reason = decision.reason,
                        width = decision.width,
                        height = decision.height,
                        frameRate = decision.frameRate
                    )
                }

                is RemoteRenderAdmissionPolicy.Decision.UnsupportedCodec -> {
                    _latestFrame.value = null
                    latestFrameGeneration = null
                    _viewerStatus.value = RemoteViewerStatus.DecoderError(
                        cause = RemoteViewerStatus.DecoderError.Cause.UNSUPPORTED_CODEC,
                        detail = decision.format
                    )
                }
            }
        }
    }

    /**
     * Surfaced by the viewer surface when the `MediaCodec` decoder fails (R6.11). The surface releases
     * decode resources; here we clear the frame and surface the decoder-failure reason.
     */
    fun onDecoderError(detail: String?) {
        synchronized(connectionLifecycleLock) {
            _latestFrame.value = null
            latestFrameGeneration = null
            _viewerStatus.value = RemoteViewerStatus.DecoderError(
                cause = RemoteViewerStatus.DecoderError.Cause.DECODER_FAILURE,
                detail = detail
            )
        }
    }

    // region No-frame watchdog (R6.13)

    private fun startWatchdogForStreaming(context: ConnectionContext) {
        val armed = synchronized(connectionLifecycleLock) {
            if (connectionGeneration != context.generation || activeTransport !== context.transport) {
                false
            } else {
                // A successful reconnect is proven only by an admitted frame. Do not move the
                // original interruption window merely because its secure handshake completed.
                if (interruptedAtMs == null) {
                    lastFrameAtMs = clockMs()
                }
                true
            }
        }
        if (armed) startWatchdog(context.generation)
    }

    /** Start one ~500ms watchdog loop owned by an exact connection generation. */
    private fun startWatchdog(generation: Long) {
        lateinit var job: Job
        job = scope.launch(start = CoroutineStart.LAZY) {
            while (isCurrentConnection(generation)) {
                delay(WATCHDOG_TICK_MS)
                evaluateWatchdog(generation, job, clockMs())
            }
        }
        var previousJob: Job? = null
        val installed = synchronized(connectionLifecycleLock) {
            if (connectionGeneration != generation) {
                false
            } else if (watchdogGeneration == generation && watchdogJob != null) {
                false
            } else {
                previousJob = watchdogJob
                watchdogJob = job
                watchdogGeneration = generation
                true
            }
        }
        if (!installed) {
            job.cancel()
            return
        }
        previousJob?.cancel()
        job.invokeOnCompletion { clearWatchdogJob(generation, job) }
        job.start()
    }

    private fun clearWatchdogJob(generation: Long, job: Job) {
        synchronized(connectionLifecycleLock) {
            if (watchdogGeneration == generation && watchdogJob === job) {
                watchdogJob = null
                watchdogGeneration = null
            }
        }
    }

    /**
     * Apply the shared [RemoteFrameWatchdogPolicy] once (R6.13). Package-visible so a deterministic
     * test can drive it with an injected clock:
     *  - ShowInterrupted → [RemoteViewerStatus.Interrupted], KEEP the last frame,
     *  - Reconnect (once) → [RemoteViewerStatus.Reconnecting] + re-dial the saved target,
     *  - EndSession → [endSessionCleanup] (release + clear frame + SessionEnded + stop transport).
     */
    internal fun evaluateWatchdog(now: Long) {
        val owner = synchronized(connectionLifecycleLock) {
            val generation = watchdogGeneration ?: return@synchronized null
            val job = watchdogJob ?: return@synchronized null
            generation to job
        } ?: return
        evaluateWatchdog(owner.first, owner.second, now)
    }

    private fun evaluateWatchdog(generation: Long, ownerJob: Job, now: Long) {
        var reconnectInterruptionAtMs: Long? = null
        var terminalInterruptionAtMs: Long? = null
        val applied = synchronized(connectionLifecycleLock) {
            if (
                connectionGeneration != generation ||
                watchdogGeneration != generation ||
                watchdogJob !== ownerJob
            ) {
                false
            } else {
                when (RemoteFrameWatchdogPolicy.decide(
                    lastFrameAtMs = lastFrameAtMs,
                    nowMs = now,
                    interruptedAtMs = interruptedAtMs,
                    reconnectAttempts = watchdogReconnectAttempts,
                    interruptMs = noFrameInterruptMs,
                    endMs = sessionEndAfterInterruptMs,
                    maxReconnects = maxReconnects
                )) {
                    RemoteFrameWatchdogPolicy.Decision.Healthy -> Unit

                    RemoteFrameWatchdogPolicy.Decision.ShowInterrupted -> {
                        if (interruptedAtMs == null) interruptedAtMs = now
                        // Retain the last frame; only surface the interrupted/reconnecting notice.
                        _viewerStatus.value =
                            if (watchdogReconnecting) RemoteViewerStatus.Reconnecting
                            else RemoteViewerStatus.Interrupted
                    }

                    RemoteFrameWatchdogPolicy.Decision.Reconnect -> {
                        if (interruptedAtMs == null) interruptedAtMs = now
                        watchdogReconnectAttempts += 1
                        watchdogReconnecting = true
                        _viewerStatus.value = RemoteViewerStatus.Reconnecting
                        reconnectInterruptionAtMs = interruptedAtMs
                    }

                    RemoteFrameWatchdogPolicy.Decision.EndSession -> {
                        terminalInterruptionAtMs = interruptedAtMs
                    }
                }
                true
            }
        }
        if (!applied) return
        reconnectInterruptionAtMs?.let { reconnectNow(generation, it) }
        terminalInterruptionAtMs?.let { endSessionCleanup(generation, it) }
    }

    /** Re-dial the saved target for the single R6.13 reconnect, preserving the retained frame. */
    private fun reconnectNow(expectedGeneration: Long, interruptionAtMs: Long) {
        val reconnect = synchronized(connectionLifecycleLock) {
            if (
                userDisconnectRequested ||
                connectionGeneration != expectedGeneration ||
                this.interruptedAtMs != interruptionAtMs ||
                lastFrameAtMs >= interruptionAtMs ||
                !watchdogReconnecting
            ) {
                null
            } else {
                val target = savedReconnectTarget ?: return@synchronized null
                Triple(target, savedReconnectEnableHandshake, savedReconnectConfig)
            }
        } ?: return
        connectInternal(
            target = reconnect.first,
            enableHandshake = reconnect.second,
            securityConfig = reconnect.third,
            preserveInterruptedState = true,
            expectedGenerationToReplace = expectedGeneration,
            expectedInterruptionAtMs = interruptionAtMs
        )
    }

    /**
     * End the session and run disconnect cleanup (R6.13 → R6.9): stop the watchdog, clear the last
     * frame (the surface releases the decoder on the null frame), present SessionEnded, and tear down
     * the transport. Runs synchronously so it completes well within the 2s bound.
     */
    private fun endSessionCleanup(expectedGeneration: Long, interruptionAtMs: Long) {
        val generation = forceInvalidateExactWatchdogConnection(
            expectedGeneration = expectedGeneration,
            expectedInterruptionAtMs = interruptionAtMs
        )?.generation ?: return
        // Reuse the full teardown after atomically proving this watchdog still owns the interrupted
        // session. A stale watchdog callback is therefore a complete no-op for a replacement.
        resetConnectionState(
            generation = generation,
            disconnectedViewerStatus = RemoteViewerStatus.SessionEnded
        )
    }

    // endregion

    private fun sendRawFrame(payload: ByteArray, generation: Long) {
        if (handshakePhase != null && looksLikeHandshakeFrame(payload)) {
            logHandshake("tx handshake frame bytes=${payload.size} phase=${handshakePhase?.name}")
        }
        synchronized(writeLock) {
            if (!isCurrentConnection(generation)) return
            val os = transportForGeneration(generation)?.output
                ?: error("remote output stream not available")
            val header = ByteBuffer.allocate(4).order(ByteOrder.BIG_ENDIAN).putInt(payload.size).array()
            os.write(header)
            os.write(payload)
            os.flush()
        }
    }

    private fun sendStreamConfigurationOperationNow(
        operation: StreamConfigurationOperation
    ): Boolean {
        synchronized(writeLock) {
            val os = synchronized(connectionLifecycleLock) {
                if (
                    connectionGeneration != operation.context.generation ||
                    activeTransport !== operation.context.transport ||
                    pendingStreamConfiguration !== operation ||
                    secureLanSession !== operation.secureSession
                ) {
                    null
                } else {
                    operation.context.transport.output
                        ?: error("remote output stream not available")
                }
            } ?: return false
            val bytes = operation.secureSession?.sealControlFrame(operation.encodedMessage)
                ?: operation.encodedMessage
            val header = ByteBuffer.allocate(4).order(ByteOrder.BIG_ENDIAN).putInt(bytes.size).array()
            os.write(header)
            os.write(bytes)
            os.flush()
            return true
        }
    }

    private fun trustedOutboundContext(): TrustedOutboundContext? {
        if (
            !MacRemoteFormalRouteAuthorizationPolicy.isCurrent(
                mode = trustContext.mode,
                lease = formalRouteAuthorizationLease
            )
        ) {
            return null
        }
        val context = synchronized(connectionLifecycleLock) {
            val transport = activeTransport ?: return@synchronized null
            val session = secureLanSession ?: return@synchronized null
            if (sessionKeys == null || transport.output == null) return@synchronized null
            if (!MacRemoteTrustedSessionPolicy.isTrustedRemoteControlSession(_securityState.value)) {
                return@synchronized null
            }
            val configured = acknowledgedStreamConfiguration ?: return@synchronized null
            if (
                configured.context.generation != connectionGeneration ||
                configured.context.transport !== transport ||
                configured.secureSession !== session
            ) {
                return@synchronized null
            }
            TrustedOutboundContext(
                generation = connectionGeneration,
                transport = transport,
                secureSession = session
            )
        }
        return context?.takeIf {
            MacRemoteFormalRouteAuthorizationPolicy.isCurrent(
                mode = trustContext.mode,
                lease = formalRouteAuthorizationLease
            )
        }
    }

    private fun sendTrustedMessageNow(
        input: MacRemoteQueuedInput
    ): Boolean {
        beforeTrustedInputWriteRecheck()
        synchronized(writeLock) {
            if (
                !MacRemoteFormalRouteAuthorizationPolicy.isCurrent(
                    mode = trustContext.mode,
                    lease = formalRouteAuthorizationLease
                )
            ) {
                return false
            }
            val context = trustedOutboundContext()
                ?.takeIf { it.generation == input.generation }
                ?: return false
            val os = synchronized(connectionLifecycleLock) {
                if (
                    connectionGeneration != context.generation ||
                    activeTransport !== context.transport ||
                    secureLanSession !== context.secureSession
                ) {
                    null
                } else {
                    context.transport.output
                }
            } ?: return false
            val bytes = context.secureSession.sealControlFrame(input.encodedMessage())
            val header = ByteBuffer.allocate(4).order(ByteOrder.BIG_ENDIAN).putInt(bytes.size).array()
            if (
                !MacRemoteFormalRouteAuthorizationPolicy.isCurrent(
                    mode = trustContext.mode,
                    lease = formalRouteAuthorizationLease
                ) || !isTrustedOutboundContextCurrent(context, os)
            ) {
                return false
            }
            os.write(header)
            os.write(bytes)
            os.flush()
            return runIfCurrentMacRemoteInputCommit(
                lifecycleLock = connectionLifecycleLock,
                isCurrent = { isTrustedOutboundContextCurrentLocked(context, os) },
                commitPressedState = {
                    // Cleanup therefore observes the Down, or it linearizes first and this stale
                    // generation is never recorded after close.
                    pressedInputState.record(input)
                }
            )
        }
    }

    /** Final generation/transport/session proof at the actual ordered-write commit point. */
    private fun isTrustedOutboundContextCurrent(
        context: TrustedOutboundContext,
        output: BufferedOutputStream
    ): Boolean = synchronized(connectionLifecycleLock) {
        isTrustedOutboundContextCurrentLocked(context, output)
    }

    private fun isTrustedOutboundContextCurrentLocked(
        context: TrustedOutboundContext,
        output: BufferedOutputStream
    ): Boolean {
        return connectionGeneration == context.generation &&
            activeTransport === context.transport &&
            context.transport.output === output &&
            secureLanSession === context.secureSession &&
            secureConnectionGeneration == context.generation &&
            sessionKeys != null
    }

    private fun finishOrderedInputDisconnect(generation: Long) {
        try {
            if (
                MacRemoteFormalRouteAuthorizationPolicy.isCurrent(
                    mode = trustContext.mode,
                    lease = formalRouteAuthorizationLease
                )
            ) {
                releasePressedInputs(generation)
            }
        } finally {
            val invalidatedGeneration = invalidateConnectionIfCurrent(
                expectedGeneration = generation
            )
            if (invalidatedGeneration != null) {
                resetConnectionState(invalidatedGeneration)
            }
        }
    }

    private fun releasePressedInputs(generation: Long) {
        pressedInputState.releaseMessages(
            expectedGeneration = generation,
            json = json,
            timestamp = clockMs() / 1_000.0
        ).forEach { message ->
            writeCompensatingRelease(
                generation,
                message
            )
        }
    }

    private fun writeCompensatingRelease(generation: Long, message: RemoteMessage) {
        val input = MacRemoteQueuedInput.from(generation, message)
        sendTrustedMessageNow(input)
    }

    private fun sendInitialStreamConfigurationNow(
        secureSession: SecureLanSession?,
        context: ConnectionContext
    ) {
        val supportedFormats = streamingFormatsProvider().also { formats ->
            require(formats.isNotEmpty()) { "remote streaming format set is empty" }
        }
        // R6.2: advertise transport tuning that (a) converges to the defined enums and (b) matches
        // what the Android viewer's receive/render path actually does. The viewer
        // (SurfaceBackedRemoteVideoDecoder) renders each frame immediately with a single-frame depth,
        // no retransmit and no damage-aware refresh, so the honest advertised values are the most
        // conservative enum members. See RemoteDesktopAdvertisedTuning for the full rationale. This
        // replaces the previous out-of-enum hardcoded refreshStrategy="adaptive"/lossRecoveryMode="none"
        // and supplies the previously-missing jitterBufferFrames. No new wire fields (G4).
        val advertisedTuning = RemoteDesktopAdvertisedTuning.deriveForCurrentViewer()
        val requestedFrameRate =
            if (supportedFormats.firstOrNull() == AndroidRemoteVideoFormats.JPEG) 20 else 30
        // The host treats an adaptive request without explicit dimensions as permission to use the
        // native display size. That can exceed the viewer's 1920x1080 admission ceiling (for example
        // a 1920x1240 Mac display), causing every otherwise-valid frame to be rejected. Request the
        // exact maximum the Android decoder and admission policy support.
        val transaction = RemoteDesktopStreamConfigurationTransaction.fresh()
        val config = RemoteDesktopStreamConfiguration(
            width = RemoteRenderAdmissionPolicy.MAX_WIDTH,
            height = RemoteRenderAdmissionPolicy.MAX_HEIGHT,
            preferredCodec = supportedFormats.first(),
            supportedVideoFormats = supportedFormats,
            adaptiveResolutionEnabled = false,
            targetFrameRate = requestedFrameRate,
            keyFrameInterval = 30,
            lowLatencyMode = supportedFormats.any { it == AndroidRemoteVideoFormats.H264 || it == AndroidRemoteVideoFormats.HEVC },
            enableHardwareAcceleration = supportedFormats.any { it == AndroidRemoteVideoFormats.H264 || it == AndroidRemoteVideoFormats.HEVC },
            enableAppleSiliconOptimization = false,
            clipboardSyncEnabled = false,
            damageTrackingEnabled = true,
            separateCursorChannelEnabled = false,
            interactionOverlayChannelEnabled = false,
            refreshStrategy = advertisedTuning.refreshStrategy,
            jitterBufferFrames = advertisedTuning.jitterBufferFrames,
            lossRecoveryMode = advertisedTuning.lossRecoveryMode,
            remoteControlSecurityIdentity = remoteControlSecurityIdentity(),
            streamConfigurationTransaction = transaction,
            sentAt = System.currentTimeMillis().toDouble() / 1000.0
        )
        val payload = json.encodeToString(
            RemoteDesktopStreamConfiguration.serializer(),
            config
        ).encodeToByteArray()
        val message = RemoteMessage(
            type = RemoteMessage.MessageType.STREAM_CONFIGURATION,
            payload = payload
        )
        val operation = StreamConfigurationOperation(
            context = context,
            secureSession = secureSession,
            expectation = RemoteDesktopStreamConfigurationAcknowledgementExpectation(
                transaction = transaction,
                streamRefreshToken = config.streamRefreshToken,
                audioEndpointPresent = false,
                screenFrameTransport = config.screenFrameTransport
            ),
            encodedMessage = RemoteControlWireCodec.encodeMessage(message),
            requestedFrameRate = requestedFrameRate
        )
        if (!installStreamConfigurationOperation(operation)) return
        if (!sendStreamConfigurationOperationNow(operation)) return
        scheduleStreamConfigurationAcknowledgementRetries(operation)
    }

    private fun sendEncryptedStreamConfigurationIfNeeded(context: ConnectionContext) {
        val session = synchronized(connectionLifecycleLock) {
            if (connectionGeneration != context.generation || activeTransport !== context.transport) {
                null
            } else {
                val establishedSession = secureLanSession
                val existing = pendingStreamConfiguration ?: acknowledgedStreamConfiguration
                if (
                    establishedSession == null ||
                    (existing?.context === context && existing.secureSession === establishedSession)
                ) {
                    null
                } else {
                    establishedSession
                }
            }
        }
        session ?: return
        try {
            logHandshake("sending encrypted stream configuration")
            sendInitialStreamConfigurationNow(secureSession = session, context = context)
        } catch (error: CancellationException) {
            throw error
        } catch (t: Throwable) {
            failConnection(
                productionSafeFailureReason(
                    reasonCode = "stream_configuration_send_failed",
                    error = t,
                    diagnosticReason =
                        "encrypted stream configuration send failed: ${t.message ?: t.javaClass.simpleName}"
                ),
                context.generation
            )
        }
    }

    private fun installStreamConfigurationOperation(
        operation: StreamConfigurationOperation
    ): Boolean {
        var retryJobToCancel: Job? = null
        var watchdogJobToCancel: Job? = null
        val installed = synchronized(writeLock) {
            synchronized(connectionLifecycleLock) {
                if (
                    connectionGeneration != operation.context.generation ||
                    activeTransport !== operation.context.transport ||
                    secureLanSession !== operation.secureSession
                ) {
                    false
                } else {
                    retryJobToCancel = streamConfigurationAckRetryJob
                    streamConfigurationAckRetryJob = null
                    watchdogJobToCancel = watchdogJob
                    watchdogJob = null
                    watchdogGeneration = null
                    pendingStreamConfiguration = operation
                    acknowledgedStreamConfiguration = null
                    true
                }
            }
        }
        retryJobToCancel?.cancel()
        watchdogJobToCancel?.cancel()
        return installed
    }

    private fun scheduleStreamConfigurationAcknowledgementRetries(
        operation: StreamConfigurationOperation
    ) {
        lateinit var retryJob: Job
        retryJob = scope.launch(start = CoroutineStart.LAZY) {
            for ((index, delayMs) in STREAM_CONFIGURATION_ACK_RETRY_DELAYS_MS.withIndex()) {
                delay(delayMs)
                try {
                    if (!sendStreamConfigurationOperationNow(operation)) return@launch
                    logHandshake("stream configuration acknowledgement pending; retry=${index + 1}")
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Throwable) {
                    failConnection(
                        productionSafeFailureReason(
                            reasonCode = "stream_configuration_retry_failed",
                            error = error,
                            diagnosticReason =
                                "stream configuration retry failed: ${error.message ?: error.javaClass.simpleName}"
                        ),
                        operation.context.generation
                    )
                    return@launch
                }
            }
            delay(STREAM_CONFIGURATION_ACK_FINAL_WAIT_MS)
            val acknowledgementMissing = synchronized(connectionLifecycleLock) {
                connectionGeneration == operation.context.generation &&
                    activeTransport === operation.context.transport &&
                    pendingStreamConfiguration === operation
            }
            if (acknowledgementMissing) {
                failConnection(
                    "stream configuration acknowledgement missing after bounded retries",
                    operation.context.generation
                )
            }
        }
        val installed = synchronized(connectionLifecycleLock) {
            if (
                connectionGeneration != operation.context.generation ||
                activeTransport !== operation.context.transport ||
                pendingStreamConfiguration !== operation ||
                streamConfigurationAckRetryJob != null
            ) {
                false
            } else {
                streamConfigurationAckRetryJob = retryJob
                true
            }
        }
        if (!installed) {
            retryJob.cancel()
            return
        }
        retryJob.invokeOnCompletion {
            synchronized(connectionLifecycleLock) {
                if (streamConfigurationAckRetryJob === retryJob) {
                    streamConfigurationAckRetryJob = null
                }
            }
        }
        retryJob.start()
    }

    private fun remoteControlSecurityIdentity(): RemoteControlSecurityIdentity? {
        remoteControlSecurityIdentityProvider?.invoke()?.let { return it }
        val businessIdentity = accountBusinessIdentityProvider.current() ?: return null
        return RemoteControlSecurityIdentity(
            accountDisplayName = businessIdentity.accountDisplayName,
            nebulaId = businessIdentity.nebulaId,
            deviceId = localIdentity.deviceId(),
            deviceName = AndroidBuild.MODEL?.trim()?.takeIf { it.isNotEmpty() }
        )
    }

    private fun startHandshake(context: ConnectionContext) {
        try {
            if (!isCurrentConnection(context)) return
            val target = context.target
            val connectionSecurityConfig = context.securityConfig
            val effectivePolicy = connectionSecurityConfig.handshakePolicyOverride
                ?: localIdentity.defaultHandshakePolicyOverride()
            val peerIdHint = peerIdHint(target)
            val peerKem = peerIdHint?.let { trustContext.peerKemPublicKeys.load(it) }
                ?: PeerKemKeyStore.PeerKemPublicKeys()
            val peerKemPublicKeys = P2PHandshakeClient.PeerKemPublicKeys(
                qPeriaptPublicKey = peerKem.qPeriaptPublicKey,
                xWingPublicKey = peerKem.xWingPublicKey,
                mlKem768PublicKey = peerKem.mlKem768PublicKey
            )

            MacRemoteFormalKemPolicy.requireStartReady(
                mode = trustContext.mode,
                localXWingAvailable = if (
                    trustContext.mode == MacRemoteControlTrustMode.FORMAL_ACCEPTANCE_READ_ONLY
                ) {
                    P2PXWingKem.isAvailable()
                } else {
                    true
                },
                peerXWingPublicKey = peerKemPublicKeys.xWingPublicKey
            )

            if (effectivePolicy.requirePqc && peerKemPublicKeys.isMissingPqcMaterial()) {
                error("required peer KEM bootstrap is unavailable; refresh product pairing before retrying")
            }

            logHandshake(
                "start policy=requirePqc=${effectivePolicy.requirePqc} " +
                    "allowClassicFallback=${effectivePolicy.allowClassicFallback} " +
                    "minimumTier=${effectivePolicy.minimumTierRaw} pinned=${peerIdHint?.let { trustContext.peerSigningFingerprints.isPeerPinned(it) } == true} " +
                    "peerKem[qperiapt=${peerKemPublicKeys.qPeriaptPublicKey?.size ?: 0},xwing=${peerKemPublicKeys.xWingPublicKey?.size ?: 0},mlkem=${peerKemPublicKeys.mlKem768PublicKey?.size ?: 0}]"
            )

            val client = localIdentity.handshakeClient(
                peerKem = peerKemPublicKeys,
                policy = effectivePolicy
            )
            val soaExtensionsRaw = remoteControlSoaExtensions(peerIdHint)
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
                    fallbackCooldownStore = peerIdHint?.let { trustContext.fallbackCooldowns },
                    peerKemPublicKeys = peerKemPublicKeys,
                    handshakePolicy = effectivePolicy.toWirePolicy(),
                    messageAExtensionsRaw = soaExtensionsRaw,
                    protocolSigningKeys = protocolSigningKeys
                )
            )
            if (!runIfCurrentConnection(context) {
                    handshakeClient = client
                    handshakeState = st
                    handshakePhase = HandshakePhase.WaitingMessageB
                    pendingSessionKeys = null
                    sessionKeys = null
                    secureLanSession = null
                    secureConnectionGeneration = null
                    pendingTrustState = null
                    pendingTrustFingerprint = null
                    pendingObservedPeerFingerprint = null
                    activePeerFingerprint = target.advertisedFingerprint
                    negotiatedSuiteName = null
                }
            ) return
            val decodedMessageA = P2PHandshakeWire.decodeMessageA(msgA)
            val msgAPreimageHash = MessageDigest.getInstance("SHA-256")
                .digest(P2PHandshakeWire.buildMessageASignaturePreimagePublic(msgA))
            logHandshake(
                "tx MessageA suites=${decodedMessageA.supportedSuites.joinToString(",") { it.wireId.toString(16) }} " +
                    "bytes=${msgA.size} sigBytes=${decodedMessageA.signature.size} " +
                    "pubBytes=${decodedMessageA.identityPublicKeys.protocolPublicKey.size} " +
                    "soa=${soaExtensionsRaw.isNotEmpty()} " +
                    "preimageSha256=${msgAPreimageHash.take(8).joinToString("") { "%02x".format(it) }}"
            )
            sendRawFrame(msgA, context.generation) // handshake frames are already SBP1-wrapped
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            handleHandshakeFailure(
                MacRemoteFormalFailurePolicy.reason(
                    mode = trustContext.mode,
                    reasonCode = "formal_handshake_start_failed",
                    error = error,
                    diagnosticReason = "handshake start failed: ${error.message ?: "unknown"}"
                ),
                context
            )
        }
    }

    private fun remoteControlSoaExtensions(peerIdHint: String?): ByteArray {
        val remoteDeviceId = peerIdHint?.trim()?.takeIf { it.isNotEmpty() } ?: return ByteArray(0)
        val attemptId = ByteArray(com.skybridge.compass.shared.p2p.P2PSoa.ATTEMPT_ID_LEN)
            .also(secureRandom::nextBytes)
        return MacRemoteControlSoaIdentity.messageAExtensions(
            localDeviceId = localIdentity.deviceId(),
            remoteDeviceId = remoteDeviceId,
            attemptId = attemptId
        ) ?: error("stable SOA identity is required for secure remote-control handshake")
    }

    private fun evaluatePeerTrust(
        frameBytes: ByteArray,
        context: ConnectionContext
    ): MacRemotePeerTrustEvaluation? {
        if (!isCurrentConnection(context)) return null
        val peerId = peerIdHint(context.target) ?:
            return MacRemotePeerTrustEvaluation(
                trustState = TrustState.UNTRUSTED_EPHEMERAL,
                fingerprintToPersist = null,
                observedFingerprint = null
            )
        return try {
            val messageB = P2PHandshakeWire.decodeMessageB(frameBytes)
            val observedFingerprint = P2PHandshakeWire.computePeerSigningFingerprint(messageB.identityPublicKeys)
            val trustStore = trustContext.peerSigningFingerprints
            val pinned = trustStore.loadPeerSigningFingerprint(peerId)
            val evaluation = MacRemotePeerTrustPolicy.evaluate(
                peerId = peerId,
                observedFingerprint = observedFingerprint,
                advertisedFingerprint = context.target.advertisedFingerprint,
                advertisedFingerprintTrustSource = context.target.advertisedFingerprintTrustSource,
                pinnedFingerprint = pinned,
                allowTrustOnFirstUse = context.securityConfig.allowTrustOnFirstUse
            )
            if (!runIfCurrentConnection(context) {
                    activePeerFingerprint = observedFingerprint
                }
            ) return null
            evaluation
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            failTrustedIdentityNegotiation(
                MacRemoteFormalFailurePolicy.reason(
                    mode = trustContext.mode,
                    reasonCode = "formal_trust_verification_failed",
                    error = error,
                    diagnosticReason = "trust verification failed: ${error.message ?: "unknown"}"
                ),
                context.generation
            )
            null
        }
    }

    private fun failTrustedIdentityNegotiation(reason: String, generation: Long? = null) {
        logHandshakeWarn("trusted identity failed: $reason")
        failConnection(reason, generation)
    }

    private fun handleHandshakeFailure(
        reason: String,
        context: ConnectionContext
    ) {
        var mustFail = false
        val applied = runIfCurrentConnection(context) {
            logHandshakeWarn("failed: $reason")
            clearHandshakeState()
            negotiatedSuiteName = null
            if (canAcceptPlaintext(context.securityConfig)) {
                markPlaintext(reason, context.target)
            } else {
                mustFail = true
            }
        }
        if (applied && mustFail) {
            failConnection(reason, context.generation)
        }
    }

    private fun canAcceptPlaintext(config: SecurityConfig = securityConfig): Boolean =
        BuildConfig.DEBUG && !config.encryptionRequired && config.allowPlaintextFallback

    private fun markPlaintext(reason: String, target: ConnectionTarget? = currentTarget) {
        _securityState.value = SecurityState.Plaintext(
            peerId = peerIdHint(target),
            reason = reason
        )
    }

    private fun peerIdHint(target: ConnectionTarget? = currentTarget): String? =
        target?.deviceIdHint?.trim()?.takeIf { it.isNotEmpty() }

    private fun productionSafeFailureReason(
        reasonCode: String,
        error: Throwable,
        diagnosticReason: String
    ): String = MacRemoteFormalFailurePolicy.reason(
        mode = trustContext.mode,
        reasonCode = reasonCode,
        error = error,
        diagnosticReason = diagnosticReason
    )

    private fun failConnection(
        reason: String,
        generation: Long? = null,
        expectedInterruptionAtMs: Long? = null
    ) {
        val failureGeneration = generation ?: synchronized(connectionLifecycleLock) {
            connectionGeneration
        }
        val invalidated = if (expectedInterruptionAtMs != null) {
            checkNotNull(generation) {
                "watchdog failure requires an exact connection generation"
            }
            forceInvalidateExactWatchdogConnection(
                expectedGeneration = failureGeneration,
                expectedInterruptionAtMs = expectedInterruptionAtMs
            ) ?: return
        } else {
            if (!isCurrentConnection(failureGeneration)) return
            val inputOwner = synchronized(connectionLifecycleLock) {
                activeTransport?.takeIf { connectionGeneration == failureGeneration }
                    ?.let { transport -> MacRemoteInputDrainOwner(failureGeneration, transport) }
            }
            inputOwner?.let(::forceInvalidateExactInputOwner)
        }
        logSink.error("LAN remote connection failed: $reason")
        val stateGeneration = invalidated?.generation ?: failureGeneration
        trustedInputQueue.clear()
        val applied = runIfCurrentConnection(stateGeneration) {
            val terminalViewerStatus = MacRemoteViewerFailurePolicy.terminalStatus(
                currentStatus = _viewerStatus.value,
                interruptedAtMs = interruptedAtMs,
                watchdogReconnecting = watchdogReconnecting
            )
            clearHandshakeState()
            sessionKeys = null
            secureLanSession = null
            secureConnectionGeneration = null
            pressedInputState.clear()
            pendingSessionKeys = null
            pendingTrustState = null
            pendingTrustFingerprint = null
            pendingObservedPeerFingerprint = null
            streamConfigurationAckRetryJob?.cancel()
            streamConfigurationAckRetryJob = null
            pendingStreamConfiguration = null
            acknowledgedStreamConfiguration = null
            // Exact invalidation has already detached the failed transport and cancelled its
            // watchdog. A replacement failure must therefore become terminal immediately; keeping
            // Reconnecting here would leave no owner/job capable of reaching EndSession.
            watchdogJob?.cancel()
            watchdogJob = null
            watchdogGeneration = null
            interruptedAtMs = null
            watchdogReconnectAttempts = 0
            watchdogReconnecting = false
            reconnectInFlight = false
            lastFrameAtMs = 0L
            _latestFrame.value = null
            latestFrameGeneration = null
            _viewerStatus.value = terminalViewerStatus
            _state.value = State.Failed(reason)
            _securityState.value = SecurityState.Failed(peerIdHint(), reason)
        }
        if (!applied) return
    }

    private fun closeTransport(transport: ConnectionTransport) {
        closeTransportResource("input", transport.input)
        closeTransportResource("output", transport.output)
        closeTransportResource("socket", transport.socket)
        transport.input = null
        transport.output = null
    }

    /** Close the socket first so a blocking OutputStream.write/flush is interrupted. */
    private fun interruptAndCloseTransport(transport: ConnectionTransport) {
        closeTransportResource("socket", transport.socket)
        closeTransportResource("input", transport.input)
        closeTransportResource("output", transport.output)
        transport.input = null
        transport.output = null
    }

    private fun closeTransportResource(name: String, resource: Closeable?) {
        if (resource == null) return
        runCatching { resource.close() }
            .onFailure { err ->
                val reason = productionSafeFailureReason(
                    reasonCode = "transport_close_failed",
                    error = err,
                    diagnosticReason =
                        "LAN remote $name close failed: ${err.message ?: err.javaClass.simpleName}"
                )
                logSink.warn("LAN remote $name close failed: $reason")
            }
    }

}

internal object MacRemoteControlReadDeadlinePolicy {
    const val CONNECT_TIMEOUT_MILLIS = 10_000
    const val FRAME_READ_TIMEOUT_MILLIS = 30_000

    class Deadline internal constructor(
        val expiresAtNanos: Long,
        val timeoutMillis: Int
    ) {
        private val timeoutNanos = timeoutMillis.toLong() * 1_000_000L

        /**
         * Returns the remaining duration without comparing absolute nanoTime values. The
         * subtraction is intentionally performed in two's-complement arithmetic so a
         * nanoTime wrap (or a negative nanoTime origin) remains valid for this short deadline.
         * Values outside the configured window are clamped to zero, failing closed.
         */
        fun remainingNanos(nowNanos: Long): Long {
            val remaining = expiresAtNanos - nowNanos
            return if (java.lang.Long.compareUnsigned(remaining, timeoutNanos) > 0) {
                0L
            } else {
                remaining
            }
        }
    }

    enum class Stage(val label: String) {
        FRAME_HEADER("frame header"),
        FRAME_PAYLOAD("frame payload")
    }

    class ReadTimeoutException(
        val stage: Stage,
        val readBytes: Int,
        val expectedBytes: Int,
        val timeoutMillis: Int,
        cause: SocketTimeoutException
    ) : IOException(
        "remote read timed out after ${timeoutMillis}ms while reading ${stage.label} " +
            "($readBytes/$expectedBytes bytes)",
        cause
    ) {
    }

    fun configureSocket(socket: Socket) {
        socket.tcpNoDelay = true
        socket.soTimeout = FRAME_READ_TIMEOUT_MILLIS
    }

    fun newDeadline(
        timeoutMillis: Int = FRAME_READ_TIMEOUT_MILLIS,
        monotonicNanos: () -> Long = System::nanoTime
    ): Deadline {
        require(timeoutMillis > 0) { "timeoutMillis must be positive" }
        val now = monotonicNanos()
        val duration = timeoutMillis.toLong() * 1_000_000L
        // Do not saturate an absolute nanoTime value. nanoTime is an arbitrary signed counter and
        // may start negative; two's-complement subtraction in Deadline.remainingNanos() is the
        // overflow-safe operation for a short interval.
        val expiresAt = now + duration
        return Deadline(expiresAtNanos = expiresAt, timeoutMillis = timeoutMillis)
    }

    fun readFully(
        input: InputStream,
        out: ByteArray,
        stage: Stage,
        timeoutMillis: Int = FRAME_READ_TIMEOUT_MILLIS,
        deadline: Deadline? = null,
        monotonicNanos: () -> Long = System::nanoTime,
        updateReadTimeoutMillis: (Int) -> Unit = {}
    ): Boolean {
        require(timeoutMillis > 0) { "timeoutMillis must be positive" }
        val effectiveDeadline = deadline ?: newDeadline(timeoutMillis, monotonicNanos)
        var off = 0
        while (off < out.size) {
            val remainingNanos = effectiveDeadline.remainingNanos(monotonicNanos())
            if (remainingNanos <= 0L) {
                throw ReadTimeoutException(
                    stage = stage,
                    readBytes = off,
                    expectedBytes = out.size,
                    timeoutMillis = effectiveDeadline.timeoutMillis,
                    cause = SocketTimeoutException("read deadline exceeded")
                )
            }
            val remainingMillis = ((remainingNanos + 999_999L) / 1_000_000L)
                .coerceIn(1L, effectiveDeadline.timeoutMillis.toLong())
                .toInt()
            updateReadTimeoutMillis(remainingMillis)
            val r = try {
                input.read(out, off, out.size - off)
            } catch (timeout: SocketTimeoutException) {
                throw ReadTimeoutException(
                    stage = stage,
                    readBytes = off,
                    expectedBytes = out.size,
                    timeoutMillis = effectiveDeadline.timeoutMillis,
                    cause = timeout
                )
            }
            if (r < 0) return false
            off += r
            if (effectiveDeadline.remainingNanos(monotonicNanos()) <= 0L) {
                throw ReadTimeoutException(
                    stage = stage,
                    readBytes = off,
                    expectedBytes = out.size,
                    timeoutMillis = effectiveDeadline.timeoutMillis,
                    cause = SocketTimeoutException("read deadline exceeded")
                )
            }
        }
        return true
    }
}
