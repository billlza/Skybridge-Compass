package com.skybridge.compass.android.ui.screens.filetransfer

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import android.os.Build
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.skybridge.compass.android.data.SecuritySettings
import com.skybridge.compass.android.data.SecuritySettingsStore
import com.skybridge.compass.android.discovery.DiscoveryPeerLaunchTarget
import com.skybridge.compass.android.discovery.ProductActionGateDecision
import com.skybridge.compass.android.discovery.ProductSessionActionGate
import com.skybridge.compass.android.discovery.userMessage
import com.skybridge.compass.android.filetransfer.AndroidInboundFileTransferApprovalProvider
import com.skybridge.compass.android.security.toHandshakePolicyOverride
import com.skybridge.compass.android.webrtc.AppWebRtcTransportFactory
import com.skybridge.compass.core.filetransfer.LanTransferProgress
import com.skybridge.compass.core.filetransfer.MacLanFileTransferClient
import com.skybridge.compass.core.webrtc.CrossNetworkWebRtcTransportAdapter
import com.skybridge.compass.core.webrtc.SkyBridgeWebRtcConnectionManager
import com.skybridge.compass.filetransfer.webrtc.WebRtcFileTransferController
import com.skybridge.compass.filetransfer.webrtc.InboundFileDestinationPolicy
import com.skybridge.compass.shared.webrtc.WebRtcAppSecureEnvelope
import dagger.hilt.android.lifecycle.HiltViewModel
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import javax.inject.Inject

/**
 * Owns the WebRTC file-transfer transport logic that previously lived inline in
 * [FileTransferScreen] in FileTransferScreen.kt:
 * - the transport adapter lifecycle (was `remember { AndroidCrossNetworkWebRtcTransportAdapter(...) }` ~:119-125)
 * - the inbound approval provider (was `remember { AndroidInboundFileTransferApprovalProvider(...) }` ~:134)
 * - the file-transfer controller lifecycle (was `remember { WebRtcFileTransferController(...) }` ~:135-144)
 * - the pqc/handshake-policy settings push (was `LaunchedEffect(pqc..., webrtc)` ~:153-163)
 * - exact-key-epoch inbound FILE_TRANSFER routing through `onSecurePacketData`
 * - the received-file collection (was `LaunchedEffect(transferController)` ~:188-194)
 * - the connection-code generate / connect-peer / disconnect / send-file intents (were inline onClicks)
 *
 * The user-facing "connected" gate stays on State.Established (post-handshake, NOT Connected),
 * while the controller independently captures the exact secure key epoch. "Sent" is published
 * only after an owner-bound completeAck; writing metadata/chunks alone remains "Sending".
 */
@HiltViewModel
class FileTransferViewModel @Inject constructor(
    @ApplicationContext private val appContext: Context,
    webRtcTransportFactory: AppWebRtcTransportFactory,
    private val productActionGate: ProductSessionActionGate
) : ViewModel() {

    /** WebRTC init can fail; surfaced to the UI exactly like the old runCatching {} block. */
    private val webrtcResult: Result<CrossNetworkWebRtcTransportAdapter> = runCatching {
        webRtcTransportFactory.create()
    }
    val webrtc: CrossNetworkWebRtcTransportAdapter? = webrtcResult.getOrNull()
    val webrtcInitError: String? =
        if (webrtc == null) webrtcResult.exceptionOrNull()?.message else null

    private val controllerResult: Result<WebRtcFileTransferController>? = webrtc?.let { transport ->
        runCatching {
            val inboundApprovalProvider = AndroidInboundFileTransferApprovalProvider(appContext)
            WebRtcFileTransferController(
                webrtc = transport,
                appContext = appContext,
                inboundApprovalProvider = inboundApprovalProvider,
                inboundFileDestinationPolicy = InboundFileDestinationPolicy.DOWNLOADS
            )
        }
    }
    val transferController: WebRtcFileTransferController? = controllerResult?.getOrNull()
    val controllerInitError: String? =
        if (webrtc != null && transferController == null) {
            controllerResult?.exceptionOrNull()?.message
        } else {
            null
        }

    val securitySettings: StateFlow<SecuritySettings> =
        SecuritySettingsStore.observe(appContext)
            .stateIn(viewModelScope, SharingStarted.Eagerly, SecuritySettings())

    val connState: StateFlow<SkyBridgeWebRtcConnectionManager.State>? = webrtc?.state
    val signalingStatus: StateFlow<SkyBridgeWebRtcConnectionManager.SignalingStatus>? =
        webrtc?.signalingStatus
    val progress: StateFlow<WebRtcFileTransferController.Progress>? = transferController?.progress
    private val lanFileTransferClient = MacLanFileTransferClient()

    /**
     * Byte-accurate LAN transfer progress observed by the UI as a leaf-node value. Driven by the
     * [MacLanFileTransferClient] progress callback which reports actually-confirmed bytes; the value
     * is monotonically non-decreasing and never a placeholder/estimate.
     */
    private val _lanProgress = MutableStateFlow<LanTransferProgress?>(null)
    val lanProgress: StateFlow<LanTransferProgress?> = _lanProgress.asStateFlow()

    private val _generatedCode = MutableStateFlow("")
    val generatedCode: StateFlow<String> = _generatedCode.asStateFlow()

    private val _statusMessage = MutableStateFlow<LocalizedStatus>(LocalizedStatus.WaitingForConnection)
    val statusMessage: StateFlow<LocalizedStatus> = _statusMessage.asStateFlow()

    private val _inboundLogs = MutableStateFlow<List<InboundLog>>(emptyList())
    val inboundLogs: StateFlow<List<InboundLog>> = _inboundLogs.asStateFlow()
    private val pendingOutboundFileNames = ConcurrentHashMap<String, String>()

    init {
        val transport = webrtc
        val controller = transferController
        if (transport != null && controller != null) {
            // Inbound file-transfer frames are SBWC packetType=FILE_TRANSFER. App-control frames
            // such as heartbeat/pairing are routed elsewhere and must not enter the FT parser.
            transport.onSecurePacketData = { owner, bytes, packetType ->
                if (packetType == WebRtcAppSecureEnvelope.PacketType.FILE_TRANSFER) {
                    controller.handleIncoming(owner, bytes)
                }
            }

            // pqc/handshake-policy push (was LaunchedEffect(pqc..., webrtc) ~:153-163).
            viewModelScope.launch {
                var lastSignature: List<Any?>? = null
                securitySettings.collect { settings ->
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

            // Received-file collection (was LaunchedEffect(transferController) ~:188-194).
            viewModelScope.launch {
                controller.receivedFiles.collect { file ->
                    val label = file.localPath ?: file.fileName ?: file.transferId
                    _inboundLogs.value = listOf(InboundLog.Received(label)) + _inboundLogs.value
                    _statusMessage.value = LocalizedStatus.ReceiveComplete(label)
                }
            }

            viewModelScope.launch {
                controller.progress.collect { update ->
                    val transferId = update.transferId ?: return@collect
                    val fileName = pendingOutboundFileNames[transferId] ?: return@collect
                    when {
                        update.lastStatus == "send complete acknowledged" -> {
                            pendingOutboundFileNames.remove(transferId, fileName)
                            _statusMessage.value = LocalizedStatus.Sent(fileName)
                        }
                        update.lastStatus?.contains("secure session replaced or rekeyed") == true -> {
                            pendingOutboundFileNames.remove(transferId, fileName)
                            _statusMessage.value = LocalizedStatus.SendFailed(update.lastStatus)
                        }
                        update.lastStatus?.startsWith("send failed:") == true ||
                            update.lastStatus?.startsWith("peer error:") == true -> {
                            pendingOutboundFileNames.remove(transferId, fileName)
                            _statusMessage.value = LocalizedStatus.SendFailed(update.lastStatus)
                        }
                    }
                }
            }
        }
    }

    /** Canon: user-facing "ready to transfer" == handshakeComplete == State.Established (NOT Connected). */
    fun isConnected(state: SkyBridgeWebRtcConnectionManager.State): Boolean =
        state is SkyBridgeWebRtcConnectionManager.State.Established

    /** Was the inline onGenerateCode onClick ~FileTransferScreen.kt:285-305. */
    fun generateConnectionCode() {
        val transport = webrtc ?: return
        viewModelScope.launch {
            runCatching { transport.generateConnectionCode() }
                .onSuccess { code ->
                    _generatedCode.value = code
                    _statusMessage.value = LocalizedStatus.ConnectionCodeCreated(code)
                }
                .onFailure { error ->
                    _statusMessage.value = LocalizedStatus.GenerateCodeFailed(error.message)
                }
        }
    }

    /**
     * Was the inline onConnectPeer onClick ~FileTransferScreen.kt:306-318.
     * Returns the sanitized code that was joined (or null if validation failed).
     */
    fun connectPeer(rawCode: String) {
        val transport = webrtc ?: return
        val code = rawCode.uppercase().filter { it.isLetterOrDigit() }
        if (code.length !in 6..16) {
            _statusMessage.value = LocalizedStatus.InvalidConnectionCode
            return
        }
        transport.startAnswerer(code)
        _statusMessage.value = LocalizedStatus.Connecting(code)
    }

    /** Was the inline onDisconnect onClick ~FileTransferScreen.kt:320-323. */
    fun disconnect() {
        webrtc?.disconnect()
        _statusMessage.value = LocalizedStatus.ConnectionClosed
    }

    /**
     * User-triggered cancel entry point for an in-progress WebRTC transfer (R5.5).
     *
     * Delegates to [WebRtcFileTransferController.cancel], which stops send/receive for THIS
     * transfer, releases its resources, and notifies the peer with the existing `op=cancel`
     * wire message. Other concurrent transfers are unaffected.
     */
    fun cancelTransfer(transferId: String?) {
        val controller = transferController ?: return
        val id = transferId?.takeIf { it.isNotBlank() } ?: return
        controller.cancel(id)
        pendingOutboundFileNames.remove(id)
        _statusMessage.value = when (val status = controller.progress.value.lastStatus) {
            "cancelled" -> LocalizedStatus.Cancelled(id)
            else -> LocalizedStatus.SendFailed(status ?: "cancel failed")
        }
    }

    /**
     * Was the inline filePicker callback body ~FileTransferScreen.kt:196-241. The Composable still
     * owns the SAF launcher (needs Activity scope); it hands the resolved uri here. Gating on
     * transferEnabled (allowFileTransfer) + Established is preserved exactly.
     */
    fun sendFile(
        contentResolver: ContentResolver,
        uri: Uri,
        fileName: String,
        mimeType: String?,
        transferEnabled: Boolean,
        connected: Boolean
    ) {
        val controller = transferController ?: return
        if (!transferEnabled) {
            _statusMessage.value = LocalizedStatus.TransferDisabled
            return
        }
        if (!connected) {
            _statusMessage.value = LocalizedStatus.EstablishConnectionFirst
            return
        }
        viewModelScope.launch {
            val transferId = UUID.randomUUID().toString()
            pendingOutboundFileNames[transferId] = fileName
            runCatching {
                controller.sendFile(
                    contentResolver = contentResolver,
                    uri = uri,
                    transferId = transferId,
                    fileName = fileName,
                    mimeType = mimeType,
                    chunkSize = 128 * 1024
                )
            }.onSuccess {
                val update = controller.progress.value
                _statusMessage.value = when {
                    controller.isOperationAcknowledged(transferId) ||
                        (update.transferId == transferId && update.lastStatus == "send complete acknowledged") -> {
                        pendingOutboundFileNames.remove(transferId, fileName)
                        LocalizedStatus.Sent(fileName)
                    }
                    controller.isCurrentOperation(transferId) -> LocalizedStatus.Sending(fileName)
                    else -> {
                        pendingOutboundFileNames.remove(transferId, fileName)
                        LocalizedStatus.SendFailed("secure session replaced or rekeyed")
                    }
                }
            }.onFailure {
                pendingOutboundFileNames.remove(transferId, fileName)
                _statusMessage.value = LocalizedStatus.SendFailed(it.message)
            }
        }
    }

    fun sendLanFile(
        target: DiscoveryPeerLaunchTarget,
        contentResolver: ContentResolver,
        uri: Uri,
        fileName: String,
        fileSize: Long?,
        transferEnabled: Boolean
    ) {
        if (!target.isFileTransfer) {
            _statusMessage.value = LocalizedStatus.SendFailed("selected endpoint is not file transfer")
            return
        }
        if (!transferEnabled) {
            _statusMessage.value = LocalizedStatus.TransferDisabled
            return
        }
        if (target.requiresAuthenticatedClassicFileTransferSession) {
            _statusMessage.value = LocalizedStatus.AuthenticatedClassicSessionRequired
            return
        }
        val gateDecision = productActionGate.checkFileTransfer(target)
        if (gateDecision is ProductActionGateDecision.Denied) {
            _statusMessage.value = LocalizedStatus.SendFailed(gateDecision.reason.userMessage())
            return
        }
        val expectedSize = fileSize?.takeIf { it >= 0 }
        if (expectedSize == null) {
            _statusMessage.value = LocalizedStatus.SendFailed("file size unavailable")
            return
        }
        viewModelScope.launch {
            _statusMessage.value = LocalizedStatus.Sending(fileName)
            _lanProgress.value = LanTransferProgress.initial(expectedSize)
            runCatching {
                lanFileTransferClient.sendFile(
                    MacLanFileTransferClient.SendRequest(
                        host = target.host,
                        port = target.port,
                        fileName = fileName,
                        fileSize = expectedSize,
                        openInputStream = {
                            contentResolver.openInputStream(uri)
                                ?: error("openInputStream failed")
                        },
                        senderDeviceName = Build.MODEL,
                        senderOSVersion = Build.VERSION.RELEASE,
                        senderModelName = Build.MODEL,
                        onProgress = { progress -> _lanProgress.value = progress }
                    )
                )
            }.onSuccess { result ->
                _statusMessage.value = LocalizedStatus.Sent("$fileName (${result.bytesSent} bytes)")
            }.onFailure { error ->
                _statusMessage.value = LocalizedStatus.SendFailed(lanSendFailureMessage(error))
            }
        }
    }

    override fun onCleared() {
        // Was DisposableEffect.onDispose { webrtc.disconnect() } ~:183-185.
        webrtc?.onSecurePacketData = null
        webrtc?.disconnect()
    }

    /**
     * Status/log strings are localized at the UI layer (the old code resolved them inline). The VM
     * keeps locale-agnostic state so it stays free of Compose/resolve dependencies; the Composable
     * maps each case to the same zh/en/ja text the inline code used.
     */
    sealed interface LocalizedStatus {
        data object WaitingForConnection : LocalizedStatus
        data class ReceiveComplete(val label: String) : LocalizedStatus
        data class ConnectionCodeCreated(val code: String) : LocalizedStatus
        data class GenerateCodeFailed(val error: String?) : LocalizedStatus
        data object InvalidConnectionCode : LocalizedStatus
        data class Connecting(val code: String) : LocalizedStatus
        data object ConnectionClosed : LocalizedStatus
        data object TransferDisabled : LocalizedStatus
        data object AuthenticatedClassicSessionRequired : LocalizedStatus
        data object EstablishConnectionFirst : LocalizedStatus
        data class Sending(val fileName: String) : LocalizedStatus
        data class Sent(val fileName: String) : LocalizedStatus
        data class SendFailed(val error: String?) : LocalizedStatus
        data class Cancelled(val transferId: String) : LocalizedStatus
    }

    sealed interface InboundLog {
        data class Received(val label: String) : InboundLog
    }

    private fun lanSendFailureMessage(error: Throwable): String =
        when (error) {
            is MacLanFileTransferClient.LanFileTransferException ->
                error.message ?: "LAN file transfer failed"
            is IllegalArgumentException ->
                error.message ?: "invalid LAN file transfer target"
            else -> "LAN file transfer failed (${error.javaClass.simpleName})"
        }
}
