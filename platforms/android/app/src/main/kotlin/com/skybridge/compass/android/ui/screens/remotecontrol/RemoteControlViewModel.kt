package com.skybridge.compass.android.ui.screens.remotecontrol

import android.content.Context
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.skybridge.compass.android.data.RemoteDesktopCodec
import com.skybridge.compass.android.data.RemoteDesktopStreamSettings
import com.skybridge.compass.android.data.RemoteDesktopStreamSettingsStore
import com.skybridge.compass.android.data.SecuritySettings
import com.skybridge.compass.android.data.SecuritySettingsStore
import com.skybridge.compass.android.remote.mac.MouseEventType
import com.skybridge.compass.android.remote.mac.RemoteClipboardPayload
import com.skybridge.compass.android.remote.mac.RemoteDesktopAdvertisedTuning
import com.skybridge.compass.android.remote.mac.RemoteDesktopStreamConfiguration
import com.skybridge.compass.android.remote.mac.RemoteDesktopStreamConfigurationAcknowledgement
import com.skybridge.compass.android.remote.mac.RemoteDesktopStreamConfigurationAcknowledgementDecision
import com.skybridge.compass.android.remote.mac.RemoteDesktopStreamConfigurationAcknowledgementExpectation
import com.skybridge.compass.android.remote.mac.RemoteDesktopStreamConfigurationAcknowledgementPolicy
import com.skybridge.compass.android.remote.mac.RemoteDesktopStreamConfigurationTransaction
import com.skybridge.compass.android.remote.mac.RemoteInputMessages
import com.skybridge.compass.android.remote.mac.RemoteInputSender
import com.skybridge.compass.android.remote.mac.RemoteKeyIntent
import com.skybridge.compass.android.remote.mac.RemoteKeyboardInputMapper
import com.skybridge.compass.android.remote.mac.RemoteMessage
import com.skybridge.compass.android.remote.mac.RemoteControlWireCodec
import com.skybridge.compass.android.remote.mac.ScreenData
import com.skybridge.compass.android.security.toHandshakePolicyOverride
import com.skybridge.compass.android.webrtc.AppWebRtcTransportFactory
import com.skybridge.compass.core.webrtc.AndroidRemoteVideoFormats
import com.skybridge.compass.core.webrtc.CrossNetworkWebRtcTransportAdapter
import com.skybridge.compass.core.webrtc.RemoteFrameWatchdogPolicy
import com.skybridge.compass.core.webrtc.RemoteRenderAdmissionPolicy
import com.skybridge.compass.core.webrtc.RemoteViewerStatus
import com.skybridge.compass.core.webrtc.SkyBridgeWebRtcConnectionManager
import com.skybridge.compass.core.webrtc.WebRtcSecureOperationOwner
import com.skybridge.compass.shared.webrtc.WebRtcAppSecureEnvelope
import dagger.hilt.android.lifecycle.HiltViewModel
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import javax.inject.Inject

/**
 * Owns the cross-network (WebRTC) remote-control transport logic that previously lived inline in
 * [WebRtcRemoteControlContent] in RemoteControlScreen.kt:
 * - the transport adapter lifecycle (was `remember { AndroidCrossNetworkWebRtcTransportAdapter(...) }`)
 * - the stream-configuration build/send (was `sendStreamConfiguration` ~RemoteControlScreen.kt:432-464)
 * - the keyed stream configuration send
 * - the mouse send + gating (was `sendMouse` ~:478-486)
 * - the Connected/Established transport loop (was `LaunchedEffect(webrtcState)` ~:516-543)
 * - the inbound SCREEN_DATA decode (was `DisposableEffect(webrtc, json)` ~:488-514)
 * - the pqc/handshake-policy settings push (was `LaunchedEffect(...)` ~:418-428)
 *
 * SBWC packetType routing is preserved (REMOTE_CONTROL for control payloads, default APP_CONTROL
 * for heartbeat), while application callbacks and sends are additionally bound to the exact
 * State.Established owner. A stale operation cannot resolve and mutate a replacement session.
 */
@HiltViewModel
class RemoteControlViewModel @Inject constructor(
    @ApplicationContext private val appContext: Context,
    webRtcTransportFactory: AppWebRtcTransportFactory
) : ViewModel() {

    /** Construction can fail (WebRTC init); surfaced to the UI exactly like the old runCatching {} block. */
    private val webrtcResult: Result<CrossNetworkWebRtcTransportAdapter> = runCatching {
        webRtcTransportFactory.create()
    }

    val webrtc: CrossNetworkWebRtcTransportAdapter? = webrtcResult.getOrNull()
    val initErrorMessage: String? = if (webrtc == null) {
        webrtcResult.exceptionOrNull()?.message
    } else {
        null
    }

    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false }
    private val supportedStreamingFormats = AndroidRemoteVideoFormats.supportedStreamingFormats()

    val securitySettings: StateFlow<SecuritySettings> =
        SecuritySettingsStore.observe(appContext)
            .stateIn(viewModelScope, SharingStarted.Eagerly, SecuritySettings())

    /**
     * The viewer's persisted stream-configuration request (resolution/fps/codec/preset/latency/hw),
     * sourced from the same DataStore the new Stream Settings UI writes. Replaces the previously
     * HARDCODED config in [buildStreamConfigurationOperation].
     */
    private val streamSettings: StateFlow<RemoteDesktopStreamSettings> =
        RemoteDesktopStreamSettingsStore.observe(appContext)
            .stateIn(viewModelScope, SharingStarted.Eagerly, RemoteDesktopStreamSettings())

    /** System clipboard, used for clipboard redirection with the Mac (gated on allowClipboardSync). */
    private val clipboardManager =
        appContext.getSystemService(Context.CLIPBOARD_SERVICE) as? android.content.ClipboardManager

    val webrtcState: StateFlow<SkyBridgeWebRtcConnectionManager.State>? = webrtc?.state
    val signalingStatus: StateFlow<SkyBridgeWebRtcConnectionManager.SignalingStatus>? =
        webrtc?.signalingStatus

    private val _frame = MutableStateFlow<RemoteFrame?>(null)
    // RemoteFrame is internal to the remotecontrol package; expose the flow at the same visibility.
    internal val frame: StateFlow<RemoteFrame?> = _frame.asStateFlow()

    // Viewer render-admission / decoder status (R6.1, R6.11). Replaces the previous silently-dropping
    // catch on the SCREEN_DATA decode path: over-limit streams, unsupported codecs and decoder
    // failures are surfaced here so the UI can present the reason instead of dropping frames.
    private val _viewerStatus = MutableStateFlow<RemoteViewerStatus>(RemoteViewerStatus.Idle)
    val viewerStatus: StateFlow<RemoteViewerStatus> = _viewerStatus.asStateFlow()

    private val _streamConfigurationReady = MutableStateFlow(false)
    val streamConfigurationReady: StateFlow<Boolean> = _streamConfigurationReady.asStateFlow()

    /** Exact secure-session incarnation currently admitted for remote-control operations. */
    @Volatile private var activeOwner: WebRtcSecureOperationOwner? = null

    private class StreamConfigurationOperation(
        val owner: WebRtcSecureOperationOwner,
        val expectation: RemoteDesktopStreamConfigurationAcknowledgementExpectation,
        val encodedMessage: ByteArray
    )

    private enum class AcknowledgementHandling {
        ACCEPTED,
        DUPLICATE,
        REJECTED
    }

    private val streamConfigurationLock = Any()
    private var pendingStreamConfiguration: StreamConfigurationOperation? = null
    private var acknowledgedStreamConfiguration: StreamConfigurationOperation? = null
    private var streamConfigurationAckRetryJob: Job? = null

    /** Exact-owner pointer/scroll sender; one gesture can never spill into a replacement key epoch. */
    private val inputSender = RemoteInputSender<WebRtcSecureOperationOwner>(
        json = json,
        clockSeconds = { nowUnixSeconds() },
        currentAcknowledgedOwner = ::currentRemoteControlOwner,
        commitIfCurrentAcknowledgedOwner = { owner, commit ->
            commitIfCurrentAcknowledgedRemoteControlOwner(owner, commit)
        },
        sink = { owner, message ->
            val transport = webrtc
            if (transport == null) {
                false
            } else {
                val msgJson = json.encodeToString(RemoteMessage.serializer(), message)
                    .encodeToByteArray()
                transport.send(owner, msgJson, WebRtcAppSecureEnvelope.PacketType.REMOTE_CONTROL)
            }
        },
        terminalize = { owner ->
            failRemoteControlProtocol(owner, "remote pointer input send failed")
        }
    )

    // region No-frame watchdog (R6.13) + disconnect cleanup (R6.9)

    /**
     * Injectable clock and watchdog thresholds. These are `internal var` (not @Inject constructor
     * params, which Hilt cannot default) so deterministic tests can drive [evaluateWatchdog] with a
     * fixed clock and shortened windows while production uses the real wall clock and the policy
     * defaults from [RemoteFrameWatchdogPolicy].
     */
    internal var clockMs: () -> Long = { System.currentTimeMillis() }
    internal var noFrameInterruptMs: Long = RemoteFrameWatchdogPolicy.NO_FRAME_INTERRUPT_MS
    internal var sessionEndAfterInterruptMs: Long = RemoteFrameWatchdogPolicy.SESSION_END_AFTER_INTERRUPT_MS
    internal var maxReconnects: Int = RemoteFrameWatchdogPolicy.MAX_RECONNECTS

    /** Timestamp (ms) of the most recently ADMITTED frame; drives the no-frame gap (R6.13). */
    @Volatile private var lastFrameAtMs: Long = 0L

    /** First exact configuration ACK for the current interruption window; this is not a frame. */
    @Volatile private var streamConfigurationAcknowledgedAtMs: Long? = null

    /** When the current interruption began, or null when frames are healthy. */
    @Volatile private var interruptedAtMs: Long? = null

    /** Reconnect attempts used for the current interruption (reset when frames resume). */
    @Volatile private var reconnectAttempts: Int = 0

    /** The connection code captured from the transport state, used for the single reconnect. */
    @Volatile private var currentCode: String? = null

    /** True while the single reconnect attempt is in flight, so state churn keeps the retained frame. */
    @Volatile private var reconnecting: Boolean = false

    private var watchdogJob: Job? = null

    // endregion

    init {
        val transport = webrtc
        if (transport != null) {
            transport.onSecurePacketData = packet@{ owner, bytes, packetType ->
                if (packetType != WebRtcAppSecureEnvelope.PacketType.REMOTE_CONTROL) {
                    return@packet
                }
                val expectedOwner = activeOwner
                when (
                    WebRtcRemoteControlPacketAdmissionPolicy.decide(
                        expectedOwner = expectedOwner,
                        callbackOwner = owner,
                        callbackOwnerIsCurrent = transport.isCurrentSecureOperationOwner(owner)
                    )
                ) {
                    WebRtcRemoteControlPacketAdmissionPolicy.Decision.HANDLE ->
                        handleSecureRemoteControlPacket(owner, bytes)

                    WebRtcRemoteControlPacketAdmissionPolicy.Decision.IGNORE_STALE_OWNER -> Unit
                }
            }

            // pqc/handshake-policy push (was LaunchedEffect(pqc..., webrtc) ~:418-428).
            // Re-applied whenever the relevant security settings change. Also keeps the local
            // clipboard watcher registration in sync with the allowClipboardSync gate.
            viewModelScope.launch {
                var lastSignature: List<Any?>? = null
                securitySettings.collect { settings ->
                    syncClipboardListenerRegistration(settings.allowClipboardSync)
                    val signature = listOf(
                        settings.pqcEnabled,
                        settings.enforcePqcHandshake,
                        settings.allowClassicFallbackForCompatibility,
                        settings.pqcMinimumTier,
                        settings.requireSecureEnclavePoP
                    )
                    if (signature != lastSignature) {
                        lastSignature = signature
                        transport.setPqcEnabled(settings.pqcEnabled)
                        transport.setHandshakePolicyOverride(settings.toHandshakePolicyOverride())
                    }
                }
            }

            // Transport loop, keyed on connection state (was LaunchedEffect(webrtcState) ~:516-543).
            viewModelScope.launch {
                transport.state.collect { state ->
                    onConnectionStateChanged(state)
                }
            }

            // State.Established carries only the stable connection code, so a same-session rekey
            // does not produce a distinct StateFlow value. Observe the authoritative opaque key-
            // epoch capability as a separate lifecycle signal and re-run configuration/ACK for it.
            viewModelScope.launch {
                transport.secureOperationOwner.collect { owner ->
                    onSecureOperationOwnerChanged(owner)
                }
            }
        }
    }

    private fun nowUnixSeconds(): Double = System.currentTimeMillis() / 1000.0

    private fun handleSecureRemoteControlPacket(
        owner: WebRtcSecureOperationOwner,
        bytes: ByteArray
    ) {
        val message = runCatching { RemoteControlWireCodec.decodeMessage(bytes) }
            .getOrElse {
                failRemoteControlProtocol(owner, "malformed remote-control message")
                return
            }
        when (message.type) {
            RemoteMessage.MessageType.STREAM_CONFIGURATION_ACK ->
                handleStreamConfigurationAcknowledgement(owner, message)

            RemoteMessage.MessageType.SCREEN_DATA -> {
                if (!hasAcknowledgedStreamConfiguration(owner)) {
                    failRemoteControlProtocol(owner, "screen frame received before stream configuration acknowledgement")
                    return
                }
                val screen = runCatching { RemoteControlWireCodec.decodeScreenData(message) }
                    .getOrElse {
                        failRemoteControlProtocol(owner, "malformed screen frame")
                        return
                    }
                onInboundScreenData(owner, screen)
            }

            RemoteMessage.MessageType.CLIPBOARD -> {
                if (!hasAcknowledgedStreamConfiguration(owner)) {
                    failRemoteControlProtocol(owner, "clipboard received before stream configuration acknowledgement")
                    return
                }
                handleInboundClipboard(owner, message)
            }

            RemoteMessage.MessageType.DAMAGE_REPORT,
            RemoteMessage.MessageType.CURSOR_UPDATE,
            RemoteMessage.MessageType.OVERLAY_UPDATE -> {
                if (!hasAcknowledgedStreamConfiguration(owner)) {
                    failRemoteControlProtocol(owner, "remote media metadata received before stream configuration acknowledgement")
                }
            }

            RemoteMessage.MessageType.MOUSE_EVENT,
            RemoteMessage.MessageType.KEYBOARD_EVENT,
            RemoteMessage.MessageType.STREAM_CONFIGURATION ->
                failRemoteControlProtocol(owner, "unexpected viewer-side remote-control message")
        }
    }

    private fun handleStreamConfigurationAcknowledgement(
        owner: WebRtcSecureOperationOwner,
        message: RemoteMessage
    ) {
        val transport = webrtc ?: return
        val acknowledgement = runCatching {
            RemoteControlWireCodec.decodeStreamConfigurationAcknowledgement(message)
        }.getOrElse {
            failRemoteControlProtocol(owner, "malformed stream configuration acknowledgement")
            return
        }
        var retryJobToCancel: Job? = null
        var handling = AcknowledgementHandling.REJECTED
        val ownerWasCurrent = transport.runIfCurrentSecureOperationOwner(owner) {
            handling = synchronized(streamConfigurationLock) {
                if (activeOwner !== owner) {
                    return@synchronized AcknowledgementHandling.REJECTED
                }
                val pending = pendingStreamConfiguration?.takeIf { it.owner === owner }
                if (pending != null) {
                    val decision = RemoteDesktopStreamConfigurationAcknowledgementPolicy.decide(
                        acknowledgement = acknowledgement,
                        awaiting = pending.expectation,
                        acknowledged = null
                    )
                    if (decision != RemoteDesktopStreamConfigurationAcknowledgementDecision.ACCEPT) {
                        return@synchronized AcknowledgementHandling.REJECTED
                    }
                    pendingStreamConfiguration = null
                    acknowledgedStreamConfiguration = pending
                    retryJobToCancel = streamConfigurationAckRetryJob
                    streamConfigurationAckRetryJob = null
                    return@synchronized AcknowledgementHandling.ACCEPTED
                }
                val acknowledged = acknowledgedStreamConfiguration?.takeIf { it.owner === owner }
                if (acknowledged != null && acknowledgement.matches(acknowledged.expectation)) {
                    AcknowledgementHandling.DUPLICATE
                } else {
                    AcknowledgementHandling.REJECTED
                }
            }

            if (handling == AcknowledgementHandling.ACCEPTED) {
                _streamConfigurationReady.value = true
                streamConfigurationAcknowledgedAtMs =
                    WebRtcRemoteControlWatchdogBaselinePolicy.recordAcknowledgement(
                        existingAcknowledgedAtMs = streamConfigurationAcknowledgedAtMs,
                        acceptedAtMs = clockMs()
                    )
                startWatchdog()
            }
        }
        if (!ownerWasCurrent) return
        when (handling) {
            AcknowledgementHandling.ACCEPTED -> retryJobToCancel?.cancel()

            AcknowledgementHandling.DUPLICATE -> Unit
            AcknowledgementHandling.REJECTED ->
                failRemoteControlProtocol(owner, "conflicting or unexpected stream configuration acknowledgement")
        }
    }

    private fun RemoteDesktopStreamConfigurationAcknowledgement.matches(
        expectation: RemoteDesktopStreamConfigurationAcknowledgementExpectation
    ): Boolean =
        transaction == expectation.transaction &&
            streamRefreshToken == expectation.streamRefreshToken &&
            audioEndpointPresent == expectation.audioEndpointPresent &&
            screenFrameTransport == expectation.screenFrameTransport

    private fun hasAcknowledgedStreamConfiguration(owner: WebRtcSecureOperationOwner): Boolean {
        val acknowledged = synchronized(streamConfigurationLock) {
            acknowledgedStreamConfiguration?.owner === owner
        }
        return acknowledged && webrtc?.isCurrentSecureOperationOwner(owner) == true
    }

    private fun failRemoteControlProtocol(
        owner: WebRtcSecureOperationOwner,
        reason: String
    ) {
        val transport = webrtc ?: return
        if (activeOwner !== owner) return
        if (!transport.failSecureOperation(owner, reason)) return
        android.util.Log.e("SB-REMOTE-CONTROL", reason)
        _streamConfigurationReady.value = false
        endSessionCleanup(RemoteViewerStatus.SessionEnded)
    }

    /**
     * Render-admission gate for an inbound [ScreenData] frame (R6.1, R6.11). Runs the pure
     * [RemoteRenderAdmissionPolicy] on the normalized format + dimensions + advertised target frame
     * rate, and:
     * - Admit: publishes the frame and marks the viewer Rendering.
     * - Reject (over resolution/frame-rate limit): clears the frame and surfaces an over-limit notice.
     * - UnsupportedCodec: clears the frame and surfaces the unsupported-codec reason.
     *
     * The frame rate is the viewer's advertised/target fps (what this device asked the host to send),
     * which is the value R6.1 constrains for the negotiated stream.
     */
    private fun onInboundScreenData(
        owner: WebRtcSecureOperationOwner,
        screen: ScreenData
    ) {
        if (screen.imageData.isEmpty()) return
        val normalizedFormat = AndroidRemoteVideoFormats.normalizeIncomingFormat(
            format = screen.format,
            payload = screen.imageData
        )
        val targetFrameRate = streamSettings.value.frameRate.targetFps
        val decision = RemoteRenderAdmissionPolicy.decide(
            format = normalizedFormat,
            width = screen.width,
            height = screen.height,
            frameRate = targetFrameRate
        )
        viewModelScope.launch {
            // The packet callback and this UI commit are separated by coroutine scheduling. Keep
            // the final, non-suspending effect inside the transport's exact key-epoch boundary so
            // replacement/rekey cannot interleave between validation and publication.
            commitIfCurrentAcknowledgedRemoteControlOwner(owner) {
                when (decision) {
                    is RemoteRenderAdmissionPolicy.Decision.Admit -> {
                        // R6.13: a freshly admitted frame resets the no-frame watchdog: record its
                        // arrival, clear the interruption, and reset this interruption's retry budget.
                        lastFrameAtMs = clockMs()
                        interruptedAtMs = null
                        reconnectAttempts = 0
                        reconnecting = false
                        _viewerStatus.value = RemoteViewerStatus.Rendering
                        _frame.value = RemoteFrame(
                            width = screen.width,
                            height = screen.height,
                            format = normalizedFormat,
                            timestampSeconds = screen.timestamp,
                            imageBytes = screen.imageData
                        )
                    }

                    is RemoteRenderAdmissionPolicy.Decision.Reject -> {
                        _frame.value = null
                        _viewerStatus.value = RemoteViewerStatus.OverLimit(
                            reason = decision.reason,
                            width = decision.width,
                            height = decision.height,
                            frameRate = decision.frameRate
                        )
                    }

                    is RemoteRenderAdmissionPolicy.Decision.UnsupportedCodec -> {
                        _frame.value = null
                        _viewerStatus.value = RemoteViewerStatus.DecoderError(
                            cause = RemoteViewerStatus.DecoderError.Cause.UNSUPPORTED_CODEC,
                            detail = decision.format
                        )
                    }
                }
            }
        }
    }

    /**
     * Surfaced by [RemoteVideoSurface] when the `MediaCodec` decoder fails to initialize or decode a
     * frame (R6.11). The decoder releases its resources on this path; here we clear the frame and
     * surface the decoder-failure reason so the UI stops rendering and presents the cause.
     */
    fun onDecoderError(detail: String?) {
        _frame.value = null
        _viewerStatus.value = RemoteViewerStatus.DecoderError(
            cause = RemoteViewerStatus.DecoderError.Cause.DECODER_FAILURE,
            detail = detail
        )
    }

    /**
     * Reset frame + config guards on every state change, then capture the exact owner only after the
     * secure transport reaches Established. Connected is intentionally not an application-data
     * admission state. Replacement cancels the immutable configuration transaction and its retries.
     */
    private fun onConnectionStateChanged(state: SkyBridgeWebRtcConnectionManager.State) {
        val transport = webrtc ?: return

        val establishedOwner = if (state is SkyBridgeWebRtcConnectionManager.State.Established) {
            transport.currentSecureOperationOwner()
        } else {
            null
        }
        if (establishedOwner != null && activeOwner === establishedOwner) {
            return
        }
        inputSender.clearPointerOwner()
        cancelStreamConfigurationOperation()
        watchdogJob?.cancel()
        watchdogJob = null

        // Capture the connection code from any code-carrying state so the single R6.13 reconnect can
        // re-join the same session.
        codeOf(state)?.let { currentCode = it }

        // While a reconnect is in flight (R6.13), do NOT clear the retained frame or reset the
        // Interrupted/Reconnecting status on the intermediate Waiting/Connecting/Connected churn — the
        // last frame must stay on screen until a new frame arrives or the session ends.
        if (!reconnecting) {
            _frame.value = null
            _viewerStatus.value = RemoteViewerStatus.Idle
            lastFrameAtMs = 0L
            streamConfigurationAcknowledgedAtMs = null
            interruptedAtMs = null
            reconnectAttempts = 0
        }
        activeOwner = establishedOwner

        val owner = activeOwner ?: return
        beginStreamConfigurationOperation(owner)
    }

    /**
     * Rebind the viewer to one exact secure key epoch without requiring a product-session state
     * transition. A rekey invalidates configuration ACK authority while preserving the last visual
     * frame; media/input resume only after the replacement owner completes a fresh transaction.
     */
    private fun onSecureOperationOwnerChanged(owner: WebRtcSecureOperationOwner?) {
        val transport = webrtc ?: return
        if (transport.state.value !is SkyBridgeWebRtcConnectionManager.State.Established) return
        if (activeOwner === owner) return

        inputSender.clearPointerOwner()
        cancelStreamConfigurationOperation()
        watchdogJob?.cancel()
        watchdogJob = null
        activeOwner = null
        lastFrameAtMs = 0L
        streamConfigurationAcknowledgedAtMs = null
        interruptedAtMs = null
        reconnectAttempts = 0

        if (owner == null || !transport.isCurrentSecureOperationOwner(owner)) {
            return
        }
        activeOwner = owner
        beginStreamConfigurationOperation(owner)
    }

    private fun codeOf(state: SkyBridgeWebRtcConnectionManager.State): String? = when (state) {
        is SkyBridgeWebRtcConnectionManager.State.Waiting -> state.code
        is SkyBridgeWebRtcConnectionManager.State.Connecting -> state.code
        is SkyBridgeWebRtcConnectionManager.State.Connected -> state.code
        is SkyBridgeWebRtcConnectionManager.State.Established -> state.code
        is SkyBridgeWebRtcConnectionManager.State.Failed -> state.code
        SkyBridgeWebRtcConnectionManager.State.Idle -> null
    }

    /** Start the ~500ms watchdog tick loop (R6.13). Idempotent: an existing loop is reused. */
    private fun startWatchdog() {
        if (watchdogJob?.isActive == true) return
        watchdogJob = viewModelScope.launch {
            while (true) {
                delay(WATCHDOG_TICK_MS)
                evaluateWatchdog(clockMs())
            }
        }
    }

    /**
     * Apply [RemoteFrameWatchdogPolicy] once for the given [now] (R6.13). Exposed as `internal` so a
     * deterministic test can drive it with an injected clock instead of waiting on real time:
     *  - ShowInterrupted → present [RemoteViewerStatus.Interrupted] and KEEP the last frame.
     *  - Reconnect (once) → present [RemoteViewerStatus.Reconnecting] and re-join via
     *    disconnect()+startAnswerer(code), preserving the retained frame.
     *  - EndSession → run [endSessionCleanup] (clears the frame → decoder released via
     *    DisposableEffect, SessionEnded, loops cancelled).
     *  - Healthy → no-op (a new admitted frame already reset the interruption in [onInboundScreenData]).
     */
    internal fun evaluateWatchdog(now: Long) {
        val noFrameBaseline = WebRtcRemoteControlWatchdogBaselinePolicy.baseline(
            lastAdmittedFrameAtMs = lastFrameAtMs,
            acknowledgedAtMs = streamConfigurationAcknowledgedAtMs
        ) ?: return
        when (RemoteFrameWatchdogPolicy.decide(
            lastFrameAtMs = noFrameBaseline,
            nowMs = now,
            interruptedAtMs = interruptedAtMs,
            reconnectAttempts = reconnectAttempts,
            interruptMs = noFrameInterruptMs,
            endMs = sessionEndAfterInterruptMs,
            maxReconnects = maxReconnects
        )) {
            RemoteFrameWatchdogPolicy.Decision.Healthy -> Unit

            RemoteFrameWatchdogPolicy.Decision.ShowInterrupted -> {
                if (interruptedAtMs == null) interruptedAtMs = now
                // Retain the last frame (do NOT clear _frame); only overlay the interrupted notice.
                _viewerStatus.value = RemoteViewerStatus.Reconnecting.takeIf { reconnecting }
                    ?: RemoteViewerStatus.Interrupted
            }

            RemoteFrameWatchdogPolicy.Decision.Reconnect -> {
                if (interruptedAtMs == null) interruptedAtMs = now
                reconnectAttempts += 1
                reconnecting = true
                _viewerStatus.value = RemoteViewerStatus.Reconnecting
                // Re-join the same session; the retained frame stays on screen (guarded above).
                val code = currentCode
                if (code != null) {
                    webrtc?.disconnect()
                    webrtc?.startAnswerer(code)
                }
            }

            RemoteFrameWatchdogPolicy.Decision.EndSession -> {
                endSessionCleanup(RemoteViewerStatus.SessionEnded)
            }
        }
    }

    /**
     * Was `sendStreamConfiguration()` ~RemoteControlScreen.kt:432-464, which HARDCODED the config.
     * Now built FROM the persisted [streamSettings] (resolution/fps/codec/preset/latency/hw) and the
     * security `allowClipboardSync` toggle. Only fields the macOS host actually honors are populated
     * (see RemoteDesktopControlPayloads.swift:161-181 + RemoteControlStreamRequestPolicy.request()).
     */
    private fun buildStreamConfigurationOperation(
        owner: WebRtcSecureOperationOwner
    ): StreamConfigurationOperation {
        val settings = streamSettings.value
        val preset = settings.qualityPreset
        val transaction = RemoteDesktopStreamConfigurationTransaction.fresh()

        // Resolve the requested codec against what THIS device can actually decode, mirroring iOS
        // `RemoteDesktopViewerCodec.resolvedWireValue(supportedFormats:)`. Never advertise a codec the
        // Android decoder can't play back; fall back to the device's preferred streaming codec.
        val resolvedPreferredCodec = resolveWireCodec(settings.preferredCodec, supportedStreamingFormats)

        // R6.2: the advertised transport tuning must both converge to the defined enums AND match what
        // the Android viewer actually does. The preset's refreshStrategy/jitterBufferFrames/
        // lossRecoveryMode describe the HOST's frame pump; the Android viewer
        // (SurfaceBackedRemoteVideoDecoder) renders immediately with a single-frame depth, no
        // retransmit and no damage-aware refresh. So we clamp the preset's requested tuning down to the
        // viewer's actual capabilities instead of advertising the preset values verbatim. See
        // RemoteDesktopAdvertisedTuning for the rationale.
        val advertisedTuning = RemoteDesktopAdvertisedTuning.deriveForCurrentViewer(preset)

        val config = RemoteDesktopStreamConfiguration(
            // Resolution -> width/height + adaptiveResolutionEnabled (host honors in request()).
            width = settings.resolution.width,
            height = settings.resolution.height,
            preferredCodec = resolvedPreferredCodec,
            supportedVideoFormats = supportedStreamingFormats,
            // qualityPreset + videoCompressionLevel: carried through host change-detection + WebRTC
            // streaming policy (RemoteControlStreamRequestPolicy.swift:188-189).
            qualityPreset = preset.wireValue,
            videoCompressionLevel = preset.videoCompressionLevel,
            adaptiveResolutionEnabled = settings.resolution.isAdaptive,
            // targetFrameRate (host clamps 12..120) and keyFrameInterval (host clamps 10..240).
            targetFrameRate = settings.frameRate.targetFps,
            keyFrameInterval = settings.keyFrameInterval,
            lowLatencyMode = settings.lowLatencyMode,
            enableHardwareAcceleration = settings.enableHardwareAcceleration,
            enableAppleSiliconOptimization = false,
            // clipboardSyncEnabled gates clipboard redirection on the host
            // (RemoteControlManager.swift:2474 send-side, :3119 receive-side). Driven by the
            // Access-control allowClipboardSync toggle so there is one source of truth.
            clipboardSyncEnabled = securitySettings.value.allowClipboardSync,
            // Transport tuning honored by the outbound frame pump (damageTrackingEnabled at
            // RemoteControlOutboundFramePump.swift:344) and carried in request change-detection
            // (RemoteControlStreamRequestPolicy.swift:197-202).
            damageTrackingEnabled = preset.damageTrackingEnabled,
            separateCursorChannelEnabled = false,
            interactionOverlayChannelEnabled = false,
            refreshStrategy = advertisedTuning.refreshStrategy,
            jitterBufferFrames = advertisedTuning.jitterBufferFrames,
            lossRecoveryMode = advertisedTuning.lossRecoveryMode,
            streamConfigurationTransaction = transaction,
            sentAt = nowUnixSeconds()
        )
        val configJson = json.encodeToString(
            RemoteDesktopStreamConfiguration.serializer(),
            config
        ).encodeToByteArray()
        val message = RemoteMessage(
            type = RemoteMessage.MessageType.STREAM_CONFIGURATION,
            payload = configJson
        )
        return StreamConfigurationOperation(
            owner = owner,
            expectation = RemoteDesktopStreamConfigurationAcknowledgementExpectation(
                transaction = transaction,
                streamRefreshToken = config.streamRefreshToken,
                audioEndpointPresent = false,
                screenFrameTransport = config.screenFrameTransport
            ),
            encodedMessage = RemoteControlWireCodec.encodeMessage(message)
        )
    }

    private fun beginStreamConfigurationOperation(owner: WebRtcSecureOperationOwner) {
        val transport = webrtc ?: return
        if (!transport.isCurrentSecureOperationOwner(owner)) return
        val operation = buildStreamConfigurationOperation(owner)
        val installed = synchronized(streamConfigurationLock) {
            if (activeOwner !== owner) {
                false
            } else {
                pendingStreamConfiguration = operation
                acknowledgedStreamConfiguration = null
                true
            }
        }
        if (!installed) return
        if (!sendStreamConfigurationOperationNow(operation)) {
            val stillPending = synchronized(streamConfigurationLock) {
                pendingStreamConfiguration === operation
            }
            if (stillPending) {
                failRemoteControlProtocol(owner, "initial stream configuration send failed")
            }
            return
        }
        scheduleStreamConfigurationAcknowledgementRetries(operation)
    }

    private fun sendStreamConfigurationOperationNow(
        operation: StreamConfigurationOperation
    ): Boolean {
        val transport = webrtc ?: return false
        val current = synchronized(streamConfigurationLock) {
            activeOwner === operation.owner &&
                pendingStreamConfiguration === operation
        }
        if (!current || !transport.isCurrentSecureOperationOwner(operation.owner)) return false
        return transport.send(
            operation.owner,
            operation.encodedMessage,
            WebRtcAppSecureEnvelope.PacketType.REMOTE_CONTROL
        )
    }

    private fun scheduleStreamConfigurationAcknowledgementRetries(
        operation: StreamConfigurationOperation
    ) {
        val retryJob = viewModelScope.launch {
            for (delayMs in STREAM_CONFIGURATION_ACK_RETRY_DELAYS_MS) {
                delay(delayMs)
                if (!sendStreamConfigurationOperationNow(operation)) {
                    val stillPending = synchronized(streamConfigurationLock) {
                        pendingStreamConfiguration === operation
                    }
                    if (stillPending) {
                        failRemoteControlProtocol(
                            operation.owner,
                            "stream configuration retry failed or key epoch changed"
                        )
                    }
                    return@launch
                }
            }
            delay(STREAM_CONFIGURATION_ACK_FINAL_WAIT_MS)
            val acknowledgementMissing = synchronized(streamConfigurationLock) {
                activeOwner === operation.owner &&
                    pendingStreamConfiguration === operation
            }
            if (acknowledgementMissing) {
                failRemoteControlProtocol(
                    operation.owner,
                    "stream configuration acknowledgement missing after bounded retries"
                )
            }
        }
        val installed = synchronized(streamConfigurationLock) {
            if (
                activeOwner !== operation.owner ||
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
            synchronized(streamConfigurationLock) {
                if (streamConfigurationAckRetryJob === retryJob) {
                    streamConfigurationAckRetryJob = null
                }
            }
        }
    }

    private fun cancelStreamConfigurationOperation() {
        val retryJob = synchronized(streamConfigurationLock) {
            pendingStreamConfiguration = null
            acknowledgedStreamConfiguration = null
            streamConfigurationAckRetryJob.also { streamConfigurationAckRetryJob = null }
        }
        retryJob?.cancel()
        _streamConfigurationReady.value = false
    }

    /**
     * Resolve the requested viewer codec to a wire value intersected with the formats this device can
     * actually decode. Mirrors iOS `RemoteDesktopViewerCodec.resolvedWireValue(supportedFormats:)`:
     * - AUTOMATIC / JPEG: prefer HEVC if supported, else first supported format.
     * - HEVC / H264: only if the device decodes it, otherwise fall back to the preferred codec.
     */
    private fun resolveWireCodec(
        codec: RemoteDesktopCodec,
        supportedFormats: List<String>
    ): String? {
        val fallback = AndroidRemoteVideoFormats.preferredStreamingCodec()
        return when (codec) {
            RemoteDesktopCodec.AUTOMATIC, RemoteDesktopCodec.JPEG ->
                supportedFormats.firstOrNull { it == AndroidRemoteVideoFormats.HEVC }
                    ?: supportedFormats.firstOrNull()
                    ?: fallback
            RemoteDesktopCodec.HEVC, RemoteDesktopCodec.H264 -> {
                val raw = codec.wireValue
                if (raw != null && supportedFormats.contains(raw)) raw else fallback
            }
        }
    }

    /**
     * Pointer input is bound to one acknowledged secure owner for the full gesture. Disabling
     * control blocks new Down/Move events but still permits the one owned Up required to release an
     * already accepted Down.
     */
    fun sendMouse(type: MouseEventType, x: Double, y: Double) {
        inputSender.sendPointer(
            controlEnabled = securitySettings.value.allowRemoteControl,
            type = type,
            x = x,
            y = y
        )
    }

    /**
     * R6.3 keyboard send path (previously ABSENT on the WebRTC viewer). Reuses
     * [RemoteMessage.MessageType.KEYBOARD_EVENT] with a [RemoteKeyboardEvent] (KEY_DOWN/KEY_UP);
     * admitted only while remote control is enabled and through one exact acknowledged owner.
     */
    internal fun sendKeyStroke(intent: RemoteKeyIntent) {
        if (!securitySettings.value.allowRemoteControl) return
        val transport = webrtc ?: return
        val owner = currentRemoteControlOwner() ?: return
        val encodedEvents = RemoteInputMessages.keyStroke(
            json = json,
            keyCode = RemoteKeyboardInputMapper.toMacVirtualKeyCode(intent),
            timestamp = nowUnixSeconds()
        ).map { message ->
            json.encodeToString(RemoteMessage.serializer(), message).encodeToByteArray()
        }
        WebRtcRemoteKeyStrokeCommitter.commit(
            encodedKeyEvents = encodedEvents,
            commitIfCurrentAcknowledgedOwner = { commit ->
                commitIfCurrentAcknowledgedRemoteControlOwner(owner, commit)
            },
            sendForCapturedOwner = { bytes ->
                transport.send(
                    owner,
                    bytes,
                    WebRtcAppSecureEnvelope.PacketType.REMOTE_CONTROL
                )
            },
            terminalizeCapturedOwner = {
                failRemoteControlProtocol(owner, "remote keyboard input send failed")
            }
        )
    }

    /**
     * R6.3 scroll send path (previously ABSENT on the WebRTC viewer). Reuses
     * [RemoteMessage.MessageType.MOUSE_EVENT] with [MouseEventType.SCROLL_UP]/[MouseEventType.SCROLL_DOWN]
     * — no new wire fields (G4); new scroll input is discarded in view-only mode (R6.4).
     */
    fun sendScroll(direction: RemoteInputMessages.ScrollDirection, x: Double, y: Double) {
        inputSender.sendScroll(
            controlEnabled = securitySettings.value.allowRemoteControl,
            direction = direction,
            x = x,
            y = y
        )
    }

    // region Clipboard redirection (gated on securitySettings.allowClipboardSync)

    /** Most recent clipboard text we applied/sent, to avoid echo loops with the host. */
    @Volatile private var lastClipboardText: String? = null

    private val clipboardListener = android.content.ClipboardManager.OnPrimaryClipChangedListener {
        // Outbound: local clipboard changed -> send to the Mac if sync is enabled and a session exists.
        if (!securitySettings.value.allowClipboardSync) return@OnPrimaryClipChangedListener
        val transport = webrtc ?: return@OnPrimaryClipChangedListener
        val owner = currentRemoteControlOwner() ?: return@OnPrimaryClipChangedListener
        val text = currentClipboardText() ?: return@OnPrimaryClipChangedListener
        if (text == lastClipboardText) return@OnPrimaryClipChangedListener
        if (sendClipboard(owner, text)) {
            lastClipboardText = text
        }
    }
    @Volatile private var clipboardListenerRegistered = false

    private fun currentClipboardText(): String? {
        val clip = clipboardManager?.primaryClip ?: return null
        if (clip.itemCount == 0) return null
        val text = clip.getItemAt(0)?.coerceToText(appContext)?.toString()
        return text?.takeIf { it.isNotEmpty() }
    }

    /** Install/remove the local-clipboard watcher to match the current allowClipboardSync gate. */
    private fun syncClipboardListenerRegistration(enabled: Boolean) {
        val manager = clipboardManager ?: return
        if (enabled && !clipboardListenerRegistered) {
            manager.addPrimaryClipChangedListener(clipboardListener)
            clipboardListenerRegistered = true
        } else if (!enabled && clipboardListenerRegistered) {
            manager.removePrimaryClipChangedListener(clipboardListener)
            clipboardListenerRegistered = false
        }
    }

    /** Send the local clipboard text to the Mac over the REMOTE_CONTROL channel as a clipboard payload. */
    private fun sendClipboard(owner: WebRtcSecureOperationOwner, text: String): Boolean {
        val transport = webrtc ?: return false
        val payload = RemoteClipboardPayload(
            mimeType = "text/plain",
            data = text.encodeToByteArray(),
            sentAt = nowUnixSeconds()
        )
        val payloadJson = json.encodeToString(RemoteClipboardPayload.serializer(), payload).encodeToByteArray()
        val msg = RemoteMessage(type = RemoteMessage.MessageType.CLIPBOARD, payload = payloadJson)
        val msgJson = json.encodeToString(RemoteMessage.serializer(), msg).encodeToByteArray()
        return transport.send(owner, msgJson, WebRtcAppSecureEnvelope.PacketType.REMOTE_CONTROL)
    }

    /** Inbound clipboard from the Mac: apply to the local clipboard if sync is enabled. */
    private fun handleInboundClipboard(
        owner: WebRtcSecureOperationOwner,
        msg: RemoteMessage
    ) {
        if (!securitySettings.value.allowClipboardSync) return
        val payload = runCatching {
            json.decodeFromString(RemoteClipboardPayload.serializer(), msg.payload.decodeToString())
        }.getOrElse {
            failRemoteControlProtocol(owner, "malformed clipboard payload")
            return
        }
        if (!payload.mimeType.startsWith("text")) return
        val text = runCatching { payload.data.decodeToString() }
            .getOrElse {
                failRemoteControlProtocol(owner, "invalid clipboard text encoding")
                return
            }
            .takeIf { it.isNotEmpty() }
            ?: return
        val manager = clipboardManager ?: return
        viewModelScope.launch {
            try {
                commitIfCurrentAcknowledgedRemoteControlOwner(owner) {
                    if (!securitySettings.value.allowClipboardSync || text == lastClipboardText) {
                        return@commitIfCurrentAcknowledgedRemoteControlOwner
                    }
                    manager.setPrimaryClip(
                        android.content.ClipData.newPlainText("SkyBridge Remote", text)
                    )
                    lastClipboardText = text
                }
            } catch (_: RuntimeException) {
                failRemoteControlProtocol(owner, "clipboard update failed")
            }
        }
    }

    // endregion

    private fun currentRemoteControlOwner(): WebRtcSecureOperationOwner? {
        val owner = activeOwner ?: return null
        return owner.takeIf(::isCurrentAcknowledgedRemoteControlOwner)
    }

    private fun isCurrentAcknowledgedRemoteControlOwner(
        owner: WebRtcSecureOperationOwner
    ): Boolean = activeOwner === owner && hasAcknowledgedStreamConfiguration(owner)

    /**
     * Linearize one short UI/system effect with the exact transport key epoch and the exact
     * acknowledged stream operation. The manager lock is acquired before [streamConfigurationLock]
     * everywhere this helper is used. [commit] must not suspend; exact-owner transport sends may
     * re-enter the manager's re-entrant owner gate when one logical operation must remain atomic.
     */
    private fun commitIfCurrentAcknowledgedRemoteControlOwner(
        owner: WebRtcSecureOperationOwner,
        commit: () -> Unit
    ): Boolean {
        val transport = webrtc ?: return false
        var committed = false
        val ownerWasCurrent = transport.runIfCurrentSecureOperationOwner(owner) {
            val acknowledged = activeOwner === owner && synchronized(streamConfigurationLock) {
                acknowledgedStreamConfiguration?.owner === owner
            }
            if (acknowledged) {
                commit()
                committed = true
            }
        }
        return ownerWasCurrent && committed
    }

    fun hasSessionKeys(): Boolean = currentRemoteControlOwner() != null

    /** P2P evidence gate: relay, unknown, missing, and stale-owner routes all return false. */
    fun hasDirectRoute(): Boolean {
        val transport = webrtc ?: return false
        val owner = currentRemoteControlOwner() ?: return false
        return transport.hasDirectRoute(owner)
    }

    suspend fun generateConnectionCode(): String =
        webrtc?.generateConnectionCode() ?: error("WebRTC transport unavailable")

    fun startAnswerer(code: String) {
        currentCode = code
        webrtc?.startAnswerer(code)
    }

    /**
     * User-initiated disconnect (R6.9). Within the 2s bound this: clears the last frame (which
     * releases the `MediaCodec` decoder via the surface's DisposableEffect once _frame is null),
     * presents the disconnected placeholder, then tears down the viewer transport.
     */
    fun disconnect() {
        endSessionCleanup(RemoteViewerStatus.SessionEnded)
        webrtc?.disconnect()
    }

    /**
     * Shared session-end cleanup for both the watchdog EndSession path (R6.13) and user disconnect
     * (R6.9). All steps are synchronous and local so they complete well within the 2s bound:
     *  1. cancel the watchdog + transport loops and clear watchdog state,
     *  2. clear the last frame → the decoder is released by [RemoteVideoSurface]'s DisposableEffect
     *     when `_frame` becomes null and the surface leaves composition,
     *  3. surface the terminal [status] so the UI shows the no-picture placeholder,
     */
    private fun endSessionCleanup(status: RemoteViewerStatus) {
        watchdogJob?.cancel()
        watchdogJob = null
        cancelStreamConfigurationOperation()
        interruptedAtMs = null
        reconnectAttempts = 0
        reconnecting = false
        lastFrameAtMs = 0L
        streamConfigurationAcknowledgedAtMs = null
        inputSender.clearPointerOwner()
        activeOwner = null
        _frame.value = null
        _viewerStatus.value = status
    }

    override fun onCleared() {
        // R6.9 cleanup on teardown (also was DisposableEffect.onDispose { onData = null; release() }).
        endSessionCleanup(RemoteViewerStatus.Idle)
        syncClipboardListenerRegistration(enabled = false)
        webrtc?.onSecurePacketData = null
        webrtc?.release()
    }

    private companion object {
        /** Watchdog evaluation cadence while the transport is open (R6.13). */
        const val WATCHDOG_TICK_MS: Long = 500
        val STREAM_CONFIGURATION_ACK_RETRY_DELAYS_MS = longArrayOf(1_000L, 2_000L, 4_000L)
        const val STREAM_CONFIGURATION_ACK_FINAL_WAIT_MS: Long = 113_000L

    }
}
