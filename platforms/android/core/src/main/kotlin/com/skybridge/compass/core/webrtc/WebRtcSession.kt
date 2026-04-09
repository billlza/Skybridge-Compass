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

/**
 * Android counterpart of Pro release `WebRTCSession.swift`.
 * Focus: PeerConnection + DataChannel ("skybridge") + ICE callbacks.
 */
class WebRtcSession(
    private val appContext: Context,
    val sessionId: String,
    val localDeviceId: String,
    val role: Role,
    val ice: IceConfig
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
    @Volatile var onDataChannelConfigStatus: ((DataChannelConfigStatus) -> Unit)? = null

    private var factory: PeerConnectionFactory? = null
    private var pc: PeerConnection? = null
    private var dataChannel: DataChannel? = null
    private var createdDataChannelInit: DataChannel.Init? = null
    private val pendingRemoteIceCandidates = mutableListOf<IceCandidate>()
    @Volatile private var hasRemoteDescription: Boolean = false
    @Volatile private var isSettingRemoteDescription: Boolean = false

    private data class NormalizedRemoteSdp(
        val sdp: String,
        val droppedSessionLevelCandidateLines: Int,
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
        val factory = PeerConnectionFactory.builder()
            .setFieldTrials("")
            .createPeerConnectionFactory()
        this.factory = factory

        val rtcConfig = PeerConnection.RTCConfiguration(buildIceServers())
        rtcConfig.sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN
        rtcConfig.continualGatheringPolicy = PeerConnection.ContinualGatheringPolicy.GATHER_CONTINUALLY
        if (System.getProperty("skybridge.smoke.forceRelayIce") == "1") {
            rtcConfig.iceTransportsType = PeerConnection.IceTransportsType.RELAY
        }
        Log.i(
            TAG,
            "start session=$sessionId role=$role forceRelay=${rtcConfig.iceTransportsType == PeerConnection.IceTransportsType.RELAY} iceServers=${rtcConfig.iceServers.size}"
        )

        pc = factory.createPeerConnection(rtcConfig, object : PeerConnection.Observer {
            override fun onIceCandidate(candidate: IceCandidate) {
                Log.i(
                    TAG,
                    "localIce session=$sessionId type=${candidateType(candidate.sdp)} mid=${candidate.sdpMid ?: "-"} mline=${candidate.sdpMLineIndex}"
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
                dataChannel = dc
                onDataChannelConfigStatus?.invoke(
                    DataChannelConfigStatus.RemoteChannelReceived(
                        label = dc.label(),
                        expected = expectedDataChannelConfig()
                    )
                )
                dc.registerObserver(object : DataChannel.Observer {
                    override fun onBufferedAmountChange(previousAmount: Long) = Unit
                    override fun onStateChange() {
                        Log.i(TAG, "dataChannel session=$sessionId state=${dc.state()}")
                        if (dc.state() == DataChannel.State.OPEN) onReady?.invoke()
                        if (dc.state() == DataChannel.State.CLOSED) onDisconnected?.invoke("data_channel_closed")
                    }
                    override fun onMessage(buffer: DataChannel.Buffer) {
                        val bytes = ByteArray(buffer.data.remaining())
                        buffer.data.get(bytes)
                        onData?.invoke(bytes)
                    }
                })
                if (dc.state() == DataChannel.State.OPEN) {
                    onReady?.invoke()
                }
            }

            override fun onIceConnectionChange(newState: PeerConnection.IceConnectionState) {
                Log.i(TAG, "iceConnection session=$sessionId state=$newState")
                when (newState) {
                    PeerConnection.IceConnectionState.FAILED -> onDisconnected?.invoke("ice_failed")
                    PeerConnection.IceConnectionState.CLOSED -> onDisconnected?.invoke("ice_closed")
                    else -> Unit
                }
            }
            override fun onIceConnectionReceivingChange(receiving: Boolean) = Unit
            override fun onIceGatheringChange(newState: PeerConnection.IceGatheringState) {
                Log.i(TAG, "iceGathering session=$sessionId state=$newState")
            }
            override fun onSignalingChange(newState: PeerConnection.SignalingState) = Unit
            override fun onIceCandidatesRemoved(candidates: Array<IceCandidate>) = Unit
            override fun onAddStream(stream: org.webrtc.MediaStream) = Unit
            override fun onRemoveStream(stream: org.webrtc.MediaStream) = Unit
            override fun onRenegotiationNeeded() = Unit
            override fun onAddTrack(receiver: org.webrtc.RtpReceiver, mediaStreams: Array<out org.webrtc.MediaStream>) = Unit
            override fun onConnectionChange(newState: PeerConnection.PeerConnectionState) {
                Log.i(TAG, "peerConnection session=$sessionId state=$newState")
                when (newState) {
                    PeerConnection.PeerConnectionState.FAILED -> onDisconnected?.invoke("peer_connection_failed")
                    PeerConnection.PeerConnectionState.CLOSED -> onDisconnected?.invoke("peer_connection_closed")
                    PeerConnection.PeerConnectionState.DISCONNECTED -> onDisconnected?.invoke("peer_connection_disconnected")
                    else -> Unit
                }
            }
            override fun onStandardizedIceConnectionChange(newState: PeerConnection.IceConnectionState) {
                Log.i(TAG, "iceConnectionStd session=$sessionId state=$newState")
            }
        })

        if (role == Role.OFFERER) {
            val dcInit = DataChannel.Init().apply {
                ordered = true
                negotiated = false
            }
            createdDataChannelInit = dcInit
            dataChannel = pc?.createDataChannel("skybridge", dcInit)?.also { dc ->
                dc.registerObserver(object : DataChannel.Observer {
                    override fun onBufferedAmountChange(previousAmount: Long) = Unit
                    override fun onStateChange() {
                        Log.i(TAG, "dataChannel session=$sessionId state=${dc.state()}")
                        if (dc.state() == DataChannel.State.OPEN) onReady?.invoke()
                        if (dc.state() == DataChannel.State.CLOSED) onDisconnected?.invoke("data_channel_closed")
                    }
                    override fun onMessage(buffer: DataChannel.Buffer) {
                        val bytes = ByteArray(buffer.data.remaining())
                        buffer.data.get(bytes)
                        onData?.invoke(bytes)
                    }
                })
            }
            onDataChannelConfigStatus?.invoke(validateCreatedDataChannelInit())
            createOffer()
        }
    }

    fun setRemoteOffer(sdp: String) {
        val normalized = normalizeRemoteSdp(sdp)
        if (hasRemoteDescription || isSettingRemoteDescription) return
        Log.i(
            TAG,
            "remoteOffer session=$sessionId sdpBytes=${normalized.sdp.toByteArray().size} droppedSessionCandidates=${normalized.droppedSessionLevelCandidateLines} dedupCandidates=${normalized.deduplicatedCandidateLines}"
        )
        val desc = SessionDescription(SessionDescription.Type.OFFER, normalized.sdp)
        isSettingRemoteDescription = true
        pc?.setRemoteDescription(object : SdpObserverAdapter() {
            override fun onSetSuccess() {
                isSettingRemoteDescription = false
                hasRemoteDescription = true
                flushPendingRemoteIceCandidates()
                createAnswer()
            }
            override fun onSetFailure(error: String) {
                isSettingRemoteDescription = false
                Log.e(TAG, "setRemoteOffer failed session=$sessionId error=$error")
            }
        }, desc)
    }

    fun setRemoteAnswer(sdp: String) {
        val normalized = normalizeRemoteSdp(sdp)
        if (hasRemoteDescription || isSettingRemoteDescription) return
        Log.i(
            TAG,
            "remoteAnswer session=$sessionId sdpBytes=${normalized.sdp.toByteArray().size} droppedSessionCandidates=${normalized.droppedSessionLevelCandidateLines} dedupCandidates=${normalized.deduplicatedCandidateLines}"
        )
        val desc = SessionDescription(SessionDescription.Type.ANSWER, normalized.sdp)
        isSettingRemoteDescription = true
        pc?.setRemoteDescription(object : SdpObserverAdapter() {
            override fun onSetSuccess() {
                isSettingRemoteDescription = false
                hasRemoteDescription = true
                flushPendingRemoteIceCandidates()
            }
            override fun onSetFailure(error: String) {
                isSettingRemoteDescription = false
                Log.e(TAG, "setRemoteAnswer failed session=$sessionId error=$error")
            }
        }, desc)
    }

    fun addRemoteIceCandidate(candidate: String, sdpMid: String?, sdpMLineIndex: Int?) {
        Log.i(
            TAG,
            "remoteIce session=$sessionId type=${candidateType(candidate)} mid=${sdpMid ?: "-"} mline=${sdpMLineIndex ?: -1} hasRemoteDesc=$hasRemoteDescription settingRemote=$isSettingRemoteDescription"
        )
        val iceCandidate = IceCandidate(sdpMid, sdpMLineIndex ?: 0, candidate)
        if (!hasRemoteDescription || isSettingRemoteDescription) {
            synchronized(pendingRemoteIceCandidates) {
                pendingRemoteIceCandidates += iceCandidate
            }
            return
        }
        pc?.addIceCandidate(iceCandidate)
    }

    fun send(bytes: ByteArray): Boolean {
        val dc = dataChannel ?: return false
        val buf = java.nio.ByteBuffer.wrap(bytes)
        return dc.send(DataChannel.Buffer(buf, /* binary */ true))
    }

    fun isDataChannelOpen(): Boolean =
        dataChannel?.state() == DataChannel.State.OPEN

    fun close() {
        runCatching { dataChannel?.close() }
        runCatching { dataChannel?.dispose() }
        dataChannel = null
        runCatching { pc?.close() }
        runCatching { pc?.dispose() }
        pc = null
        runCatching { factory?.dispose() }
        factory = null
        synchronized(pendingRemoteIceCandidates) {
            pendingRemoteIceCandidates.clear()
        }
        hasRemoteDescription = false
        isSettingRemoteDescription = false
    }

    private fun flushPendingRemoteIceCandidates() {
        val pending = synchronized(pendingRemoteIceCandidates) {
            if (pendingRemoteIceCandidates.isEmpty()) {
                emptyList()
            } else {
                pendingRemoteIceCandidates.toList().also { pendingRemoteIceCandidates.clear() }
            }
        }
        pending.forEach { pc?.addIceCandidate(it) }
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

        if (servers.isEmpty()) {
            servers += PeerConnection.IceServer.builder("stun:stun.l.google.com:19302").createIceServer()
        }

        return servers
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
                }, desc)
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
                }, desc)
            }
        }, constraints)
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
