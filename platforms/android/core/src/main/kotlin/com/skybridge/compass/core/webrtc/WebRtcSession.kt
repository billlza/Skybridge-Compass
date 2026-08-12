package com.skybridge.compass.core.webrtc

import android.content.Context
import android.util.Log
import org.webrtc.DataChannel
import org.webrtc.IceCandidate
import org.webrtc.MediaConstraints
import org.webrtc.PeerConnection
import org.webrtc.PeerConnectionFactory
import org.webrtc.SdpObserver
import org.webrtc.SessionDescription
import org.webrtc.SoftwareVideoDecoderFactory
import org.webrtc.SoftwareVideoEncoderFactory

/**
 * Android counterpart of Pro release `WebRTCSession.swift`.
 * Focus: PeerConnection + DataChannel ("skybridge") + ICE callbacks.
 */
class WebRtcSession(
    private val appContext: Context,
    val sessionId: String,
    val localDeviceId: String,
    val role: Role,
    val ice: IceConfig,
    private val diagnosticsConfig: WebRtcDiagnosticsConfig = WebRtcDiagnosticsConfig()
) {
    enum class Role { OFFERER, ANSWERER }

    data class IceConfig(
        val stunUrl: String,
        val turnUrls: List<String>,
        val turnUsername: String,
        val turnPassword: String
    ) {
        val turnUrl: String get() = turnUrls.firstOrNull().orEmpty()
    }

    @Volatile var onLocalOffer: ((String) -> Unit)? = null
    @Volatile var onLocalAnswer: ((String) -> Unit)? = null
    @Volatile var onLocalIceCandidate: ((WebRtcSignalingEnvelope.Payload) -> Unit)? = null
    @Volatile var onData: ((ByteArray) -> Unit)? = null
    @Volatile var onReady: (() -> Unit)? = null
    @Volatile var onDisconnected: ((String) -> Unit)? = null
    @Volatile var onProtocolViolation: ((String) -> Unit)? = null
    @Volatile var onDataChannelConfigStatus: ((DataChannelConfigStatus) -> Unit)? = null
    @Volatile var onSelectedRoute: ((WebRtcSelectedRoute) -> Unit)? = null

    private var factory: PeerConnectionFactory? = null
    private var pc: PeerConnection? = null
    private class DataChannelAttachment(val channel: DataChannel) {
        lateinit var observer: DataChannel.Observer
    }

    private val dataChannelLifecycle = WebRtcDataChannelLifecycle<DataChannelAttachment>()
    private var createdDataChannelInit: DataChannel.Init? = null
    private val pendingRemoteIceCandidates = mutableListOf<IceCandidate>()
    private var pendingRemoteOfferSdp: String? = null
    private var pendingRemoteAnswerSdp: String? = null
    @Volatile private var hasRemoteDescription: Boolean = false
    @Volatile private var isSettingRemoteDescription: Boolean = false

    private data class NormalizedRemoteSdp(
        val sdp: String,
        val droppedSessionLevelCandidateLines: Int,
        val droppedLoopbackCandidateLines: Int,
        val deduplicatedCandidateLines: Int
    )

    data class ExpectedDataChannelConfig(
        val label: String = "skybridge",
        val ordered: Boolean = true,
        val reliable: Boolean = true
    )

    sealed class DataChannelConfigStatus {
        data object Unknown : DataChannelConfigStatus()
        data class LocalInitValidated(
            val ok: Boolean,
            val details: String,
            val init: DataChannelInitSnapshot
        ) : DataChannelConfigStatus()
        data class RemoteChannelReceived(
            val label: String,
            val expected: ExpectedDataChannelConfig
        ) : DataChannelConfigStatus()
    }

    data class DataChannelInitSnapshot(
        val ordered: Boolean,
        val maxRetransmits: Int,
        val maxRetransmitTimeMs: Int,
        val negotiated: Boolean,
        val id: Int,
        val protocol: String?
    ) {
        val isReliable: Boolean get() = maxRetransmits < 0 && maxRetransmitTimeMs < 0
    }

    fun expectedDataChannelConfig(): ExpectedDataChannelConfig = ExpectedDataChannelConfig()

    fun validateCreatedDataChannelInit(): DataChannelConfigStatus {
        val init = createdDataChannelInit ?: return DataChannelConfigStatus.Unknown
        val snap = DataChannelInitSnapshot(
            ordered = init.ordered,
            maxRetransmits = init.maxRetransmits,
            maxRetransmitTimeMs = init.maxRetransmitTimeMs,
            negotiated = init.negotiated,
            id = init.id,
            protocol = init.protocol
        )
        val expected = expectedDataChannelConfig()
        val ok = (snap.ordered == expected.ordered) && (snap.isReliable == expected.reliable)
        val details = "expected ordered=${expected.ordered} reliable=${expected.reliable}, got ordered=${snap.ordered} reliable=${snap.isReliable} (maxRetransmits=${snap.maxRetransmits}, maxRetransmitTimeMs=${snap.maxRetransmitTimeMs})"
        return DataChannelConfigStatus.LocalInitValidated(ok = ok, details = details, init = snap)
    }

    fun start() {
        val ctx = appContext.applicationContext
        PeerConnectionFactory.initialize(
            PeerConnectionFactory.InitializationOptions.builder(ctx).createInitializationOptions()
        )

        // Data-only sessions still need the default platform-safe factory wiring.
        // Explicit ADM injection proved less stable on the Android 16 emulator.
        // Emulator/headless devices expose NO hardware video codecs. Without a video codec
        // factory, native negotiation of an inbound m=video (the Mac remote-desktop offer)
        // aborts in libjingle (front() on an empty codec vector). Software VP8/VP9 supplies a
        // non-empty codec set so a media offer can be answered, mirroring a real device's
        // hardware factory. We still never render video here — the app rides the data channel.
        val factory = PeerConnectionFactory.builder()
            .setFieldTrials("")
            .setVideoEncoderFactory(SoftwareVideoEncoderFactory())
            .setVideoDecoderFactory(SoftwareVideoDecoderFactory())
            .createPeerConnectionFactory()
        this.factory = factory

        val rtcConfig = PeerConnection.RTCConfiguration(buildIceServers())
        rtcConfig.sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN
        rtcConfig.continualGatheringPolicy = PeerConnection.ContinualGatheringPolicy.GATHER_CONTINUALLY
        if (diagnosticsConfig.forceRelayIce) {
            rtcConfig.iceTransportsType = PeerConnection.IceTransportsType.RELAY
        }
        Log.i(
            TAG,
            "start session=${redactLogIdentifier(sessionId)} role=$role forceRelay=${rtcConfig.iceTransportsType == PeerConnection.IceTransportsType.RELAY} iceServers=${rtcConfig.iceServers.size}"
        )

        val createdPeerConnection = factory.createPeerConnection(rtcConfig, object : PeerConnection.Observer {
            override fun onIceCandidate(candidate: IceCandidate) {
                Log.i(
                    TAG,
                    "localIce session=${redactLogIdentifier(sessionId)} type=${candidateType(candidate.sdp)} mid=${candidate.sdpMid ?: "-"} mline=${candidate.sdpMLineIndex}"
                )
                onLocalIceCandidate?.invoke(
                    WebRtcSignalingEnvelope.Payload(
                        candidate = candidate.sdp,
                        sdpMid = candidate.sdpMid,
                        sdpMLineIndex = candidate.sdpMLineIndex
                    )
                )
            }

            override fun onDataChannel(dc: DataChannel) {
                onDataChannelConfigStatus?.invoke(
                    DataChannelConfigStatus.RemoteChannelReceived(
                        label = dc.label(),
                        expected = expectedDataChannelConfig()
                    )
                )
                attachDataChannel(dc, remote = true)
            }

            override fun onIceConnectionChange(newState: PeerConnection.IceConnectionState) {
                Log.i(TAG, "iceConnection session=${redactLogIdentifier(sessionId)} state=$newState")
                when (newState) {
                    PeerConnection.IceConnectionState.FAILED -> onDisconnected?.invoke("ice_failed")
                    PeerConnection.IceConnectionState.CLOSED -> onDisconnected?.invoke("ice_closed")
                    else -> Unit
                }
            }
            override fun onIceConnectionReceivingChange(receiving: Boolean) = Unit
            override fun onIceGatheringChange(newState: PeerConnection.IceGatheringState) {
                Log.i(TAG, "iceGathering session=${redactLogIdentifier(sessionId)} state=$newState")
            }
            override fun onSignalingChange(newState: PeerConnection.SignalingState) = Unit
            override fun onIceCandidatesRemoved(candidates: Array<IceCandidate>) = Unit
            override fun onAddStream(stream: org.webrtc.MediaStream) = Unit
            override fun onRemoveStream(stream: org.webrtc.MediaStream) = Unit
            override fun onRenegotiationNeeded() = Unit
            override fun onAddTrack(receiver: org.webrtc.RtpReceiver, mediaStreams: Array<out org.webrtc.MediaStream>) = Unit
            override fun onConnectionChange(newState: PeerConnection.PeerConnectionState) {
                Log.i(TAG, "peerConnection session=${redactLogIdentifier(sessionId)} state=$newState")
                when (newState) {
                    PeerConnection.PeerConnectionState.FAILED -> onDisconnected?.invoke("peer_connection_failed")
                    PeerConnection.PeerConnectionState.CLOSED -> onDisconnected?.invoke("peer_connection_closed")
                    PeerConnection.PeerConnectionState.DISCONNECTED -> onDisconnected?.invoke("peer_connection_disconnected")
                    else -> Unit
                }
            }
            override fun onStandardizedIceConnectionChange(newState: PeerConnection.IceConnectionState) {
                Log.i(TAG, "iceConnectionStd session=${redactLogIdentifier(sessionId)} state=$newState")
            }
            override fun onSelectedCandidatePairChanged(event: org.webrtc.CandidatePairChangeEvent) {
                onSelectedRoute?.invoke(
                    WebRtcSelectedCandidatePairPolicy.classify(
                        localCandidateSdp = event.local?.sdp,
                        remoteCandidateSdp = event.remote?.sdp
                    )
                )
            }
        })
        pc = createdPeerConnection ?: run {
            failSession("peer_connection_create_failed", "PeerConnectionFactory returned null")
            return
        }
        drainPendingRemoteDescriptions()

        if (role == Role.OFFERER) {
            val dcInit = DataChannel.Init().apply {
                ordered = true
                negotiated = false
            }
            createdDataChannelInit = dcInit
            val createdDataChannel = createdPeerConnection.createDataChannel(
                WebRtcDataChannelAdmission.EXPECTED_LABEL,
                dcInit
            ) ?: run {
                failSession("data_channel_create_failed", "createDataChannel returned null")
                return
            }
            if (!attachDataChannel(createdDataChannel, remote = false)) return
            onDataChannelConfigStatus?.invoke(validateCreatedDataChannelInit())
            createOffer()
        }
    }

    fun setRemoteOffer(sdp: String) {
        val connection = pc ?: run {
            pendingRemoteOfferSdp = sdp
            Log.i(
                TAG,
                "remoteOfferQueued session=${redactLogIdentifier(sessionId)} reason=peer_connection_not_started sdpBytes=${sdp.toByteArray().size}"
            )
            return
        }
        val normalized = normalizeRemoteSdp(sdp)
        if (hasRemoteDescription || isSettingRemoteDescription) return
        Log.i(
            TAG,
            "remoteOffer session=${redactLogIdentifier(sessionId)} sdpBytes=${normalized.sdp.toByteArray().size} droppedSessionCandidates=${normalized.droppedSessionLevelCandidateLines} droppedLoopbackCandidates=${normalized.droppedLoopbackCandidateLines} dedupCandidates=${normalized.deduplicatedCandidateLines}"
        )
        val desc = SessionDescription(SessionDescription.Type.OFFER, normalized.sdp)
        isSettingRemoteDescription = true
        connection.setRemoteDescription(object : SdpObserverAdapter() {
            override fun onSetSuccess() {
                isSettingRemoteDescription = false
                hasRemoteDescription = true
                flushPendingRemoteIceCandidates()
                createAnswer()
            }
            override fun onSetFailure(error: String) {
                isSettingRemoteDescription = false
                failSession("set_remote_offer_failed", error)
            }
        }, desc)
    }

    fun setRemoteAnswer(sdp: String) {
        val connection = pc ?: run {
            pendingRemoteAnswerSdp = sdp
            Log.i(
                TAG,
                "remoteAnswerQueued session=${redactLogIdentifier(sessionId)} reason=peer_connection_not_started sdpBytes=${sdp.toByteArray().size}"
            )
            return
        }
        val normalized = normalizeRemoteSdp(sdp)
        if (hasRemoteDescription || isSettingRemoteDescription) return
        Log.i(
            TAG,
            "remoteAnswer session=${redactLogIdentifier(sessionId)} sdpBytes=${normalized.sdp.toByteArray().size} droppedSessionCandidates=${normalized.droppedSessionLevelCandidateLines} droppedLoopbackCandidates=${normalized.droppedLoopbackCandidateLines} dedupCandidates=${normalized.deduplicatedCandidateLines}"
        )
        val desc = SessionDescription(SessionDescription.Type.ANSWER, normalized.sdp)
        isSettingRemoteDescription = true
        connection.setRemoteDescription(object : SdpObserverAdapter() {
            override fun onSetSuccess() {
                isSettingRemoteDescription = false
                hasRemoteDescription = true
                flushPendingRemoteIceCandidates()
            }
            override fun onSetFailure(error: String) {
                isSettingRemoteDescription = false
                failSession("set_remote_answer_failed", error)
            }
        }, desc)
    }

    fun addRemoteIceCandidate(candidate: String, sdpMid: String?, sdpMLineIndex: Int?) {
        if (WebRtcIceCandidatePolicy.isRemoteLoopbackCandidate(candidate)) {
            Log.i(
                TAG,
                "remoteIceDropped session=${redactLogIdentifier(sessionId)} reason=loopback_candidate type=${candidateType(candidate)} mid=${sdpMid ?: "-"} mline=${sdpMLineIndex ?: -1}"
            )
            return
        }
        Log.i(
            TAG,
            "remoteIce session=${redactLogIdentifier(sessionId)} type=${candidateType(candidate)} mid=${sdpMid ?: "-"} mline=${sdpMLineIndex ?: -1} hasRemoteDesc=$hasRemoteDescription settingRemote=$isSettingRemoteDescription"
        )
        val iceCandidate = IceCandidate(sdpMid, sdpMLineIndex ?: 0, candidate)
        if (!hasRemoteDescription || isSettingRemoteDescription) {
            synchronized(pendingRemoteIceCandidates) {
                pendingRemoteIceCandidates += iceCandidate
            }
            return
        }
        addIceCandidateOrFail(iceCandidate)
    }

    fun send(bytes: ByteArray): Boolean {
        val buf = java.nio.ByteBuffer.wrap(bytes)
        return dataChannelLifecycle.withAttached { attachment ->
            attachment.channel.send(DataChannel.Buffer(buf, /* binary */ true))
        } ?: false
    }

    fun isDataChannelOpen(): Boolean =
        dataChannelLifecycle.isAttached { attachment ->
            attachment.channel.state() == DataChannel.State.OPEN
        }

    private fun attachDataChannel(dc: DataChannel, remote: Boolean): Boolean {
        val attachment = DataChannelAttachment(dc)
        attachment.observer = createDataChannelObserver(attachment)
        val attachResult = dataChannelLifecycle.attach(
            label = dc.label(),
            resource = attachment,
        ) { current ->
            current.channel.registerObserver(current.observer)
        }

        if (!attachResult.accepted) {
            val report = WebRtcResourceCloseReport()
            report.attempt("rejectedDataChannel.close") { dc.close() }
            report.attempt("rejectedDataChannel.dispose") { dc.dispose() }
            val reason = when {
                attachResult.registrationError != null -> "data-channel observer registration failed"
                attachResult.admission == WebRtcDataChannelAdmission.Result.REJECT_CLOSED_SESSION ->
                    "data channel received after session close"
                attachResult.admission == WebRtcDataChannelAdmission.Result.REJECT_WRONG_LABEL ->
                    "unexpected data-channel label"
                else -> "duplicate data channel"
            }
            if (remote) {
                onProtocolViolation?.invoke(
                    if (report.isSuccessful) reason else "$reason; rejected channel cleanup failed"
                )
            } else {
                failSession("data_channel_admission_failed", reason)
            }
            return false
        }

        val attachedState = dataChannelLifecycle.withExactAttached(attachment) { current ->
            current.channel.state()
        }
        if (attachedState == DataChannel.State.OPEN) onReady?.invoke()
        return true
    }

    private fun createDataChannelObserver(attachment: DataChannelAttachment): DataChannel.Observer =
        object : DataChannel.Observer {
            override fun onBufferedAmountChange(previousAmount: Long) = Unit

            override fun onStateChange() {
                val state = dataChannelLifecycle.withExactAttached(attachment) { current ->
                    current.channel.state()
                } ?: return
                Log.i(TAG, "dataChannel session=${redactLogIdentifier(sessionId)} state=$state")
                if (state == DataChannel.State.OPEN) onReady?.invoke()
                if (state == DataChannel.State.CLOSED) onDisconnected?.invoke("data_channel_closed")
            }

            override fun onMessage(buffer: DataChannel.Buffer) {
                deliverDataChannelMessage(buffer)
            }
        }

    private fun deliverDataChannelMessage(buffer: DataChannel.Buffer) {
        if (!buffer.binary) {
            onProtocolViolation?.invoke("text data-channel messages are not allowed")
            return
        }
        val chunk = try {
            WebRtcDataChannelFraming.copyAdmittedChunk(buffer.data)
        } catch (error: WebRtcDataChannelProtocolException) {
            onProtocolViolation?.invoke(error.message ?: "invalid data-channel input")
            return
        }
        onData?.invoke(chunk)
    }

    internal fun close(): WebRtcResourceCloseReport {
        val report = WebRtcResourceCloseReport()
        onSelectedRoute = null
        onData = null
        onReady = null
        onDisconnected = null
        onProtocolViolation = null
        onDataChannelConfigStatus = null
        onLocalOffer = null
        onLocalAnswer = null
        onLocalIceCandidate = null
        val closingAttachment = dataChannelLifecycle.closeAndDetach()
        report.attempt("dataChannel.unregisterObserver") {
            closingAttachment?.channel?.unregisterObserver()
        }
        report.attempt("dataChannel.close") { closingAttachment?.channel?.close() }
        report.attempt("dataChannel.dispose") { closingAttachment?.channel?.dispose() }
        val closingPeerConnection = pc
        pc = null
        report.attempt("peerConnection.close") { closingPeerConnection?.close() }
        report.attempt("peerConnection.dispose") { closingPeerConnection?.dispose() }
        val closingFactory = factory
        factory = null
        report.attempt("peerConnectionFactory.dispose") { closingFactory?.dispose() }
        pendingRemoteOfferSdp = null
        pendingRemoteAnswerSdp = null
        hasRemoteDescription = false
        isSettingRemoteDescription = false
        synchronized(pendingRemoteIceCandidates) {
            pendingRemoteIceCandidates.clear()
        }
        hasRemoteDescription = false
        isSettingRemoteDescription = false
        return report
    }

    private fun flushPendingRemoteIceCandidates() {
        val pending = synchronized(pendingRemoteIceCandidates) {
            if (pendingRemoteIceCandidates.isEmpty()) {
                emptyList()
            } else {
                pendingRemoteIceCandidates.toList().also { pendingRemoteIceCandidates.clear() }
            }
        }
        pending.forEach(::addIceCandidateOrFail)
    }

    private fun drainPendingRemoteDescriptions() {
        val offer = pendingRemoteOfferSdp
        val answer = pendingRemoteAnswerSdp
        pendingRemoteOfferSdp = null
        pendingRemoteAnswerSdp = null
        when {
            offer != null -> setRemoteOffer(offer)
            answer != null -> setRemoteAnswer(answer)
        }
    }

    private fun buildIceServers(): MutableList<PeerConnection.IceServer> {
        val servers = mutableListOf<PeerConnection.IceServer>()

        normalizedIceUrl(ice.stunUrl)
            ?.takeIf { it.startsWith("stun:") }
            ?.let { servers += PeerConnection.IceServer.builder(it).createIceServer() }

        val validTurnUrls = ice.turnUrls
            .mapNotNull(::normalizedIceUrl)
            .distinctBy { it.lowercase() }

        val turnUsername = ice.turnUsername.trim()
        val turnPassword = ice.turnPassword.trim()
        if (validTurnUrls.isNotEmpty() && turnUsername.isNotEmpty() && turnPassword.isNotEmpty()) {
            servers += PeerConnection.IceServer.builder(validTurnUrls)
                .setUsername(turnUsername)
                .setPassword(turnPassword)
                .createIceServer()
        }

        require(servers.isNotEmpty()) { "ICE server config has no usable STUN/TURN URLs" }
        return servers
    }

    private fun addIceCandidateOrFail(candidate: IceCandidate) {
        val added = pc?.addIceCandidate(candidate) ?: false
        if (!added) {
            failSession("add_remote_ice_failed", candidateType(candidate.sdp))
        }
    }

    private fun candidateType(candidateSdp: String): String =
        Regex("\\btyp\\s+(\\w+)").find(candidateSdp)?.groupValues?.getOrNull(1) ?: "unknown"

    private fun normalizeRemoteSdp(sdp: String): NormalizedRemoteSdp {
        val rawLines = sdp
            .replace("\r\n", "\n")
            .split('\n')
            .map { it.trim() }

        val prefix = ArrayList<String>()
        val sections = ArrayList<MutableList<String>>()
        var currentSection: MutableList<String>? = null
        var droppedSessionLevelCandidateLines = 0
        var droppedLoopbackCandidateLines = 0
        var deduplicatedCandidateLines = 0

        for (line in rawLines) {
            if (line.startsWith("m=")) {
                currentSection?.let(sections::add)
                currentSection = mutableListOf(line)
                continue
            }
            if (currentSection != null) {
                currentSection.add(line)
                continue
            }
            if (line.startsWith("a=candidate:") || line == "a=end-of-candidates") {
                droppedSessionLevelCandidateLines += 1
                continue
            }
            if (line.isNotEmpty()) {
                prefix += line
            }
        }
        currentSection?.let(sections::add)

        val flattened = ArrayList<String>(rawLines.size)
        flattened += prefix
        for (section in sections) {
            val seenCandidateLines = LinkedHashSet<String>()
            val cleaned = ArrayList<String>(section.size)
            for (line in section) {
                if (line.isEmpty()) continue
                if (line.startsWith("a=candidate:")) {
                    if (WebRtcIceCandidatePolicy.isRemoteLoopbackCandidate(line)) {
                        droppedLoopbackCandidateLines += 1
                        continue
                    }
                    if (!seenCandidateLines.add(line)) {
                        deduplicatedCandidateLines += 1
                        continue
                    }
                }
                if (line == "a=end-of-candidates" && cleaned.lastOrNull() == "a=end-of-candidates") {
                    deduplicatedCandidateLines += 1
                    continue
                }
                cleaned += line
            }
            flattened += cleaned
        }

        return NormalizedRemoteSdp(
            sdp = flattened.joinToString(separator = "\r\n", postfix = "\r\n"),
            droppedSessionLevelCandidateLines = droppedSessionLevelCandidateLines,
            droppedLoopbackCandidateLines = droppedLoopbackCandidateLines,
            deduplicatedCandidateLines = deduplicatedCandidateLines
        )
    }

    private fun normalizedIceUrl(raw: String?): String? {
        val value = raw?.trim().orEmpty()
        if (value.isEmpty()) return null
        return if (
            value.startsWith("stun:", ignoreCase = true) ||
            value.startsWith("turn:", ignoreCase = true) ||
            value.startsWith("turns:", ignoreCase = true)
        ) value else null
    }

    private fun createOffer() {
        val constraints = MediaConstraints().apply {
            mandatory.add(MediaConstraints.KeyValuePair("OfferToReceiveAudio", "false"))
            mandatory.add(MediaConstraints.KeyValuePair("OfferToReceiveVideo", "false"))
        }
        pc?.createOffer(object : SdpObserverAdapter() {
            override fun onCreateSuccess(desc: SessionDescription) {
                pc?.setLocalDescription(object : SdpObserverAdapter() {
                    override fun onSetSuccess() {
                        onLocalOffer?.invoke(desc.description)
                    }
                    override fun onSetFailure(error: String) {
                        failSession("set_local_offer_failed", error)
                    }
                }, desc)
            }
            override fun onCreateFailure(error: String) {
                failSession("create_offer_failed", error)
            }
        }, constraints)
    }

    private fun createAnswer() {
        val constraints = MediaConstraints().apply {
            mandatory.add(MediaConstraints.KeyValuePair("OfferToReceiveAudio", "false"))
            mandatory.add(MediaConstraints.KeyValuePair("OfferToReceiveVideo", "false"))
        }
        pc?.createAnswer(object : SdpObserverAdapter() {
            override fun onCreateSuccess(desc: SessionDescription) {
                pc?.setLocalDescription(object : SdpObserverAdapter() {
                    override fun onSetSuccess() {
                        onLocalAnswer?.invoke(desc.description)
                    }
                    override fun onSetFailure(error: String) {
                        failSession("set_local_answer_failed", error)
                    }
                }, desc)
            }
            override fun onCreateFailure(error: String) {
                failSession("create_answer_failed", error)
            }
        }, constraints)
    }

    private fun failSession(code: String, detail: String) {
        Log.e(
            TAG,
            "$code session=${redactLogIdentifier(sessionId)} detail=${WebSocketSignalingClient.sanitizeTextForLog(detail)}"
        )
        onDisconnected?.invoke(code)
    }

    private fun redactLogIdentifier(value: String): String {
        if (value.length <= 4) return "****"
        return "${value.take(2)}...${value.takeLast(2)}"
    }

    private open class SdpObserverAdapter : SdpObserver {
        override fun onCreateSuccess(desc: SessionDescription) = Unit
        override fun onSetSuccess() = Unit
        override fun onCreateFailure(error: String) = Unit
        override fun onSetFailure(error: String) = Unit
    }

    companion object {
        private const val TAG = "SB-WEBRTC"
    }
}

internal object WebRtcIceCandidatePolicy {
    fun isRemoteLoopbackCandidate(candidateSdp: String): Boolean {
        val address = candidateAddress(candidateSdp) ?: return false
        val normalized = address
            .trim()
            .trim('[', ']')
            .lowercase()
        return normalized == "localhost" ||
            normalized == "::1" ||
            normalized == "0:0:0:0:0:0:0:1" ||
            normalized.startsWith("127.")
    }

    private fun candidateAddress(candidateSdp: String): String? {
        val line = candidateSdp.trim().removePrefix("a=").trim()
        if (!line.startsWith("candidate:")) return null
        val parts = line.split(Regex("\\s+"))
        return parts.getOrNull(4)?.takeIf { it.isNotBlank() }
    }
}
