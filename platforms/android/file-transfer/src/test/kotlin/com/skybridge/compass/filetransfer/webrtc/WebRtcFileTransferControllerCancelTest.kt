package com.skybridge.compass.filetransfer.webrtc

import com.skybridge.compass.core.p2p.P2PHandshakePolicyOverride
import com.skybridge.compass.core.webrtc.AuthenticatedPeerMetadata
import com.skybridge.compass.core.webrtc.SkyBridgeWebRtcConnectionManager
import com.skybridge.compass.core.webrtc.WebRtcSession
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferMessage
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferOp
import com.skybridge.compass.shared.webrtc.WebRtcAppSecureEnvelope
import com.skybridge.compass.filetransfer.webrtc.resume.TransferCheckpoint
import com.skybridge.compass.filetransfer.webrtc.resume.TransferCheckpointStore
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.yield
import kotlinx.serialization.json.Json
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/**
 * Tests for `op=cancel` cancellation semantics (task 11.1 / Requirement 5.5).
 *
 * `CrossNetworkFileTransferOp.cancel` is part of the existing wire enum shared with the Apple
 * reference, so wiring its handling is NOT a wire-protocol change.
 */
class WebRtcFileTransferControllerCancelTest {
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false }

    @Test
    fun cancel_stopsSendReleasesResourcesAndNotifiesPeer() = runTest {
        val transport = RecordingTransport() // no peer wired: acks never arrive, transfer stays in-progress
        val checkpointStore = RecordingCheckpointStore()
        val sender = WebRtcFileTransferController(transport, json = json, checkpointStore = checkpointStore)

        val transferId = UUID.randomUUID().toString()
        val payload = "cancel me please".encodeToByteArray()
        sender.sendBytesAsFile(
            transferId = transferId,
            fileName = "cancel.txt",
            mimeType = "text/plain",
            bytes = payload,
            chunkSize = 4
        )

        // The send is being tracked (checkpoint saved) before cancel.
        withTimeout(2_000) {
            while (checkpointStore.saveCount.get() == 0) yield()
        }
        assertTrue(transport.ops.contains(CrossNetworkFileTransferOp.chunk), "sender should have sent chunks")

        sender.cancel(transferId)

        // Peer is notified with the existing op=cancel wire message.
        val cancelMsg = transport.messages.lastOrNull { it.op == CrossNetworkFileTransferOp.cancel }
        assertTrue(cancelMsg != null, "cancel must emit an op=cancel message; ops=${transport.ops}")
        assertEquals(transferId, cancelMsg!!.transferId)

        // Checkpoint for THIS transfer is released.
        withTimeout(2_000) {
            while (checkpointStore.deleteCount.get() == 0) yield()
        }
        assertNull(checkpointStore.load(transferId), "cancel must delete this transfer's checkpoint")

        // State reflects cancellation.
        assertEquals("cancelled", sender.progress.value.lastStatus)

        // Send is stopped: a NACK (missingChunks) after cancel must NOT trigger any resend, because
        // the send context and its resend loop were released.
        val opsAfterCancel = transport.ops.toList()
        sender.handleIncoming(
            encode(
                CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.chunkAck,
                    transferId = transferId,
                    missingChunks = intArrayOf(0),
                    message = "missingChunks"
                )
            )
        )
        yield()
        assertEquals(
            opsAfterCancel,
            transport.ops.toList(),
            "no chunk/complete may be resent after cancel released the send context"
        )
    }

    @Test
    fun cancel_ofOneTransferDoesNotAffectAnotherConcurrentTransfer() = runTest {
        val transport = RecordingTransport() // no peer: both transfers stay tracked until we act
        val checkpointStore = RecordingCheckpointStore()
        val sender = WebRtcFileTransferController(transport, json = json, checkpointStore = checkpointStore)

        val idA = UUID.randomUUID().toString()
        val idB = UUID.randomUUID().toString()
        sender.sendBytesAsFile(idA, "a.txt", "text/plain", "aaaa".encodeToByteArray(), chunkSize = 4)
        sender.sendBytesAsFile(idB, "b.txt", "text/plain", "bbbb".encodeToByteArray(), chunkSize = 4)

        withTimeout(2_000) {
            while (checkpointStore.load(idA) == null || checkpointStore.load(idB) == null) yield()
        }

        sender.cancel(idA)

        withTimeout(2_000) {
            while (checkpointStore.load(idA) != null) yield()
        }
        // A is released; B is untouched.
        assertNull(checkpointStore.load(idA), "cancelled transfer A checkpoint must be gone")
        assertTrue(checkpointStore.load(idB) != null, "concurrent transfer B checkpoint must survive")

        // A resend request for A does nothing (released); the same request for B still resends.
        transport.clear()
        sender.handleIncoming(
            encode(
                CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.chunkAck,
                    transferId = idA,
                    missingChunks = intArrayOf(0),
                    message = "missingChunks"
                )
            )
        )
        yield()
        assertTrue(
            transport.messages.none { it.transferId == idA && it.op == CrossNetworkFileTransferOp.chunk },
            "cancelled transfer A must not resend"
        )

        transport.clear()
        sender.handleIncoming(
            encode(
                CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.chunkAck,
                    transferId = idB,
                    missingChunks = intArrayOf(0),
                    message = "missingChunks"
                )
            )
        )
        yield()
        assertTrue(
            transport.messages.any { it.transferId == idB && it.op == CrossNetworkFileTransferOp.chunk },
            "concurrent transfer B must still be able to resend after A was cancelled"
        )
    }

    @Test
    fun incomingCancel_stopsReceiveReleasesResourcesAndDoesNotEchoCancel() = runTest {
        val transport = RecordingTransport()
        val receiver = WebRtcFileTransferController(
            transport,
            json = json,
            inboundApprovalProvider = acceptingApprovalProvider()
        )

        val transferId = UUID.randomUUID().toString()
        val chunk0 = "abcd".encodeToByteArray()

        receiver.handleIncoming(
            encode(
                CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.metadata,
                    transferId = transferId,
                    fileName = "rx.bin",
                    fileSize = 8,
                    chunkSize = 4,
                    totalChunks = 2,
                    mimeType = "application/octet-stream"
                )
            )
        )
        // Receiving is active: a chunk is acked.
        receiver.handleIncoming(
            encode(
                CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.chunk,
                    transferId = transferId,
                    chunkIndex = 0,
                    chunkData = chunk0,
                    chunkSha256 = sha256(chunk0),
                    rawSize = chunk0.size
                )
            )
        )
        withTimeout(2_000) {
            while (transport.ops.none { it == CrossNetworkFileTransferOp.chunkAck }) yield()
        }
        val chunkAcksBefore = transport.ops.count { it == CrossNetworkFileTransferOp.chunkAck }

        // Peer cancels.
        receiver.handleIncoming(
            encode(
                CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.cancel,
                    transferId = transferId
                )
            )
        )

        assertEquals("cancelled by peer", receiver.progress.value.lastStatus)
        // The receiver must NOT echo another cancel back to the peer.
        assertFalse(
            transport.ops.contains(CrossNetworkFileTransferOp.cancel),
            "receiver must not echo op=cancel back to the sender"
        )

        // Receiving is stopped: a further chunk for THIS transfer is ignored (no new chunkAck).
        receiver.handleIncoming(
            encode(
                CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.chunk,
                    transferId = transferId,
                    chunkIndex = 1,
                    chunkData = chunk0,
                    chunkSha256 = sha256(chunk0),
                    rawSize = chunk0.size
                )
            )
        )
        yield()
        assertEquals(
            chunkAcksBefore,
            transport.ops.count { it == CrossNetworkFileTransferOp.chunkAck },
            "no further chunk may be acked after the receive was cancelled"
        )
    }

    private fun encode(message: CrossNetworkFileTransferMessage): ByteArray =
        json.encodeToString(CrossNetworkFileTransferMessage.serializer(), message).encodeToByteArray()

    private fun sha256(bytes: ByteArray): ByteArray =
        MessageDigest.getInstance("SHA-256").digest(bytes)

    private fun acceptingApprovalProvider(): InboundFileTransferApprovalProvider =
        InboundFileTransferApprovalProvider { request ->
            InboundFileTransferDecision.Accept(
                downloadsDisplayName = request.fileName ?: "accepted-${request.transferId}",
                overwriteExisting = false
            )
        }

    private inner class RecordingTransport : TestCrossNetworkWebRtcTransportAdapter() {
        override val state: StateFlow<SkyBridgeWebRtcConnectionManager.State> =
            MutableStateFlow(SkyBridgeWebRtcConnectionManager.State.Established("test-session"))
        override val signalingStatus: StateFlow<SkyBridgeWebRtcConnectionManager.SignalingStatus> =
            MutableStateFlow(SkyBridgeWebRtcConnectionManager.SignalingStatus())
        override val dataChannelConfigStatus: StateFlow<WebRtcSession.DataChannelConfigStatus> =
            MutableStateFlow(WebRtcSession.DataChannelConfigStatus.Unknown)
        override val authenticatedPeerMetadata: StateFlow<AuthenticatedPeerMetadata?> =
            MutableStateFlow(null)

        override var onData: ((ByteArray) -> Unit)? = null
        override var onPacketData: ((ByteArray, WebRtcAppSecureEnvelope.PacketType) -> Unit)? = null
        var peer: RecordingTransport? = null
        val ops = mutableListOf<CrossNetworkFileTransferOp>()
        val messages = mutableListOf<CrossNetworkFileTransferMessage>()

        fun clear() {
            ops.clear()
            messages.clear()
        }

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
        override suspend fun generateConnectionCode(): String = "test-session"
        override fun startOfferer(code: String) = Unit
        override fun startAnswerer(code: String) = Unit

        override fun send(bytes: ByteArray, packetType: WebRtcAppSecureEnvelope.PacketType): Boolean {
            if (packetType == WebRtcAppSecureEnvelope.PacketType.FILE_TRANSFER) {
                val message = json.decodeFromString(
                    CrossNetworkFileTransferMessage.serializer(),
                    bytes.decodeToString()
                )
                messages += message
                ops += message.op
            }
            peer?.onData?.invoke(bytes)
            return true
        }

        override fun disconnect() = Unit
        override fun release() = Unit
    }

    private class RecordingCheckpointStore : TransferCheckpointStore {
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
    }
}
