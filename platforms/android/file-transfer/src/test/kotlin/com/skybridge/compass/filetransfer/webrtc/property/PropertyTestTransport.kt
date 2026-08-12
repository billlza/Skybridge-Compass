package com.skybridge.compass.filetransfer.webrtc.property

import com.skybridge.compass.core.p2p.P2PHandshakePolicyOverride
import com.skybridge.compass.core.webrtc.AuthenticatedPeerMetadata
import com.skybridge.compass.core.webrtc.SkyBridgeWebRtcConnectionManager
import com.skybridge.compass.core.webrtc.WebRtcSession
import com.skybridge.compass.filetransfer.webrtc.InboundFileTransferApprovalProvider
import com.skybridge.compass.filetransfer.webrtc.InboundFileTransferDecision
import com.skybridge.compass.filetransfer.webrtc.TestCrossNetworkWebRtcTransportAdapter
import com.skybridge.compass.filetransfer.webrtc.resume.TransferCheckpoint
import com.skybridge.compass.filetransfer.webrtc.resume.TransferCheckpointStore
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferMessage
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferOp
import com.skybridge.compass.shared.webrtc.WebRtcAppSecureEnvelope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.json.Json
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger

/**
 * Shared fixtures for the Epic 11 file-transfer property tests (tasks 11.9–11.17).
 *
 * These mirror the `RecordingTransport` / `RecordingCheckpointStore` doubles already used by the
 * example tests in this package, with two deliberate differences:
 *
 *  - recorders are **thread-safe** ([CopyOnWriteArrayList]) because the controller writes progress
 *    and checkpoints from its own `Dispatchers.IO` scope while a property body reads them;
 *  - nothing is asserted here. These are pure test doubles; every property lives in its own spec.
 *
 * No production code is referenced other than its real public/internal API, and no wire encoding is
 * altered (G4): messages are encoded/decoded with the same `CrossNetworkFileTransferMessage`
 * serializer the controller itself uses.
 */
internal val propertyJson: Json = Json { ignoreUnknownKeys = true; explicitNulls = false }

internal fun sha256(bytes: ByteArray): ByteArray =
    MessageDigest.getInstance("SHA-256").digest(bytes)

internal fun encodeFt(message: CrossNetworkFileTransferMessage): ByteArray =
    propertyJson.encodeToString(CrossNetworkFileTransferMessage.serializer(), message).encodeToByteArray()

internal fun decodeFt(bytes: ByteArray): CrossNetworkFileTransferMessage =
    propertyJson.decodeFromString(CrossNetworkFileTransferMessage.serializer(), bytes.decodeToString())

/** Approval provider that accepts every inbound transfer under the sender-proposed name. */
internal fun acceptingApprovalProvider(
    overwriteExisting: Boolean = false
): InboundFileTransferApprovalProvider = InboundFileTransferApprovalProvider { request ->
    InboundFileTransferDecision.Accept(
        downloadsDisplayName = request.fileName ?: "accepted-${request.transferId}",
        overwriteExisting = overwriteExisting
    )
}

/** Approval provider that declines every inbound transfer. */
internal fun decliningApprovalProvider(): InboundFileTransferApprovalProvider =
    InboundFileTransferApprovalProvider { InboundFileTransferDecision.Decline }

/**
 * Records every FILE_TRANSFER message the controller emits, optionally forwarding to a [peer]
 * controller so a real sender/receiver pair can be driven end to end.
 *
 * @param failTransferIds every send for these transferIds fails (transport-level failure).
 * @param failRelativePath the batch item with this relativePath fails from its metadata onward.
 */
internal class PropertyRecordingTransport(
    private val failTransferIds: Set<String> = emptySet(),
    private val failRelativePath: String? = null
) : TestCrossNetworkWebRtcTransportAdapter() {

    override val state: StateFlow<SkyBridgeWebRtcConnectionManager.State> =
        MutableStateFlow(SkyBridgeWebRtcConnectionManager.State.Established("property-session"))
    override val signalingStatus: StateFlow<SkyBridgeWebRtcConnectionManager.SignalingStatus> =
        MutableStateFlow(SkyBridgeWebRtcConnectionManager.SignalingStatus())
    override val dataChannelConfigStatus: StateFlow<WebRtcSession.DataChannelConfigStatus> =
        MutableStateFlow(WebRtcSession.DataChannelConfigStatus.Unknown)
    override val authenticatedPeerMetadata: StateFlow<AuthenticatedPeerMetadata?> =
        MutableStateFlow(null)

    override var onData: ((ByteArray) -> Unit)? = null
    override var onPacketData: ((ByteArray, WebRtcAppSecureEnvelope.PacketType) -> Unit)? = null

    /** Wired to the opposite controller's `handleIncoming` for end-to-end properties. */
    var peer: PropertyRecordingTransport? = null

    val messages = CopyOnWriteArrayList<CrossNetworkFileTransferMessage>()

    val ops: List<CrossNetworkFileTransferOp> get() = messages.map { it.op }

    private val dynamicFailingTransferIds = ConcurrentHashMap.newKeySet<String>()

    fun clear() = messages.clear()

    fun messagesOf(op: CrossNetworkFileTransferOp): List<CrossNetworkFileTransferMessage> =
        messages.filter { it.op == op }

    fun countOf(op: CrossNetworkFileTransferOp): Int = messages.count { it.op == op }

    override fun hasSessionKeys(): Boolean = true
    override fun authenticatedPeerDeviceId(): String = "trusted-peer"
    override fun negotiatedSuiteName(): String = "Q_PERIAPT_CONTEXT_BOUND"
    override fun negotiatedSuiteWireId(): Int = 0x0011
    override fun hasPqcSessionKeys(): Boolean = true
    override fun hasQPeriaptSessionKeys(): Boolean = true
    override fun computeOutboundHmacSha256(preimage: ByteArray): ByteArray = sha256(preimage)
    override fun verifyInboundHmacSha256(preimage: ByteArray, mac: ByteArray): Boolean =
        mac.contentEquals(sha256(preimage))
    override fun setLocalDeviceId(id: String) = Unit
    override fun setPqcEnabled(enabled: Boolean) = Unit
    override fun setHandshakePolicyOverride(policy: P2PHandshakePolicyOverride?) = Unit
    override suspend fun generateConnectionCode(): String = "property-session"
    override fun startOfferer(code: String) = Unit
    override fun startAnswerer(code: String) = Unit

    override fun send(bytes: ByteArray, packetType: WebRtcAppSecureEnvelope.PacketType): Boolean {
        if (packetType != WebRtcAppSecureEnvelope.PacketType.FILE_TRANSFER) return true
        val message = decodeFt(bytes)

        if (message.transferId in failTransferIds || message.transferId in dynamicFailingTransferIds) {
            return false
        }
        if (failRelativePath != null) {
            if (message.op == CrossNetworkFileTransferOp.metadata && message.relativePath == failRelativePath) {
                dynamicFailingTransferIds += message.transferId
                return false
            }
        }

        messages += message
        peer?.onData?.invoke(bytes)
        return true
    }

    override fun disconnect() = Unit
    override fun release() = Unit
}

/** In-memory [TransferCheckpointStore] that counts saves/deletes for residue assertions. */
internal class PropertyCheckpointStore : TransferCheckpointStore {
    private val checkpoints = ConcurrentHashMap<String, TransferCheckpoint>()
    val saveCount = AtomicInteger()
    val deleteCount = AtomicInteger()

    override suspend fun load(transferId: String): TransferCheckpoint? = checkpoints[transferId]

    override suspend fun save(checkpoint: TransferCheckpoint) {
        checkpoints[checkpoint.transferId] = checkpoint
        saveCount.incrementAndGet()
    }

    override suspend fun delete(transferId: String) {
        checkpoints.remove(transferId)
        deleteCount.incrementAndGet()
    }

    override suspend fun list(): List<TransferCheckpoint> = checkpoints.values.toList()

    /** Non-suspending peek used inside polling loops. */
    fun peek(transferId: String): TransferCheckpoint? = checkpoints[transferId]

    /** Total mutations (saves + deletes), used to detect quiescence. */
    val mutations: Int get() = saveCount.get() + deleteCount.get()

    /**
     * Suspend until the store stops changing for [stableForMs] of real time (or [timeoutMs] elapses).
     *
     * "Zero residue" is an *eventual* property: the controller performs its checkpoint writes on a
     * detached `Dispatchers.IO` scope, so an assertion made the instant a delete is observed could
     * race a still-in-flight write. Waiting for quiescence makes the assertion well defined — after
     * the store has settled, whatever remains is permanent residue.
     */
    suspend fun awaitQuiescence(stableForMs: Long = 150L, timeoutMs: Long = 5_000L) {
        val deadline = System.currentTimeMillis() + timeoutMs
        var lastSeen = mutations
        var stableSince = System.currentTimeMillis()
        while (System.currentTimeMillis() < deadline) {
            kotlinx.coroutines.delay(10L)
            val now = mutations
            if (now != lastSeen) {
                lastSeen = now
                stableSince = System.currentTimeMillis()
            } else if (System.currentTimeMillis() - stableSince >= stableForMs) {
                return
            }
        }
    }
}
