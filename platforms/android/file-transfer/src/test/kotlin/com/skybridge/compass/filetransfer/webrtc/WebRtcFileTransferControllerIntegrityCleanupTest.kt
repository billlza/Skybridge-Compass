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
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.yield
import kotlinx.serialization.json.Json
import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger

/**
 * Integrity + zero-residue cleanup tests for the inbound receive path (Requirements 5.2, 5.3).
 *
 * These exercise the controller end-to-end through [WebRtcFileTransferController.handleIncoming]:
 *  - a corrupted transfer never delivers a file and deletes its checkpoint (no residue);
 *  - a transfer whose integrity passes delivers the file exactly once while an exact duplicate
 *    `complete` replays the stored acknowledgement without re-delivery;
 *  - an interruption (decline) cleans up state and never delivers.
 *
 * The in-memory receive path is used (no Android context), so the partial-file residue invariant
 * is covered by [ReceiveIntegrityDecisionTest] plus the shared `failFinalizedReceive` cleanup that
 * every failure branch now routes through; here we assert the observable outcomes: no delivery, no
 * completeAck, and checkpoint deletion on every failure/interruption branch.
 *
 * Delivery is collected independently from the wire ACK count because exact completion retries
 * deliberately replay the stored ACK after the file has already been delivered.
 */
class WebRtcFileTransferControllerIntegrityCleanupTest {
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false }

    @Test
    fun integrityPasses_deliversExactlyOnce_andDeletesCheckpoint() = runTest {
        val transport = RecordingTransport()
        val checkpointStore = RecordingCheckpointStore()
        val receiver = WebRtcFileTransferController(
            transport,
            json = json,
            checkpointStore = checkpointStore,
            inboundApprovalProvider = acceptingApprovalProvider()
        )
        val deliveries = CopyOnWriteArrayList<WebRtcFileTransferController.ReceivedFile>()
        backgroundScope.launch(start = CoroutineStart.UNDISPATCHED) {
            receiver.receivedFiles.collect { deliveries += it }
        }

        val transferId = UUID.randomUUID().toString()
        val chunk0 = "abc".encodeToByteArray()
        val chunk1 = "def".encodeToByteArray()
        val wholeFile = chunk0 + chunk1

        feedMetadataAndChunks(receiver, transferId, chunk0, chunk1)
        receiver.handleIncoming(
            encode(
                CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.complete,
                    transferId = transferId,
                    receivedBytes = wholeFile.size.toLong(),
                    fileSha256 = sha256(wholeFile)
                )
            )
        )

        withTimeout(2_000) {
            while (transport.messages.none { it.op == CrossNetworkFileTransferOp.completeAck }) yield()
            while (checkpointStore.deleteCount.get() == 0) yield()
        }

        // Deliver a duplicate `complete` after finalize; it must NOT produce a second delivery.
        receiver.handleIncoming(
            encode(
                CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.complete,
                    transferId = transferId,
                    receivedBytes = wholeFile.size.toLong(),
                    fileSha256 = sha256(wholeFile)
                )
            )
        )
        repeat(5) { yield() }

        val acknowledgementFrames = transport.rawMessages
            .filter { it.first.op == CrossNetworkFileTransferOp.completeAck }
        assertEquals(2, acknowledgementFrames.size, "exact duplicate complete must replay its ACK")
        assertArrayEquals(
            acknowledgementFrames[0].second,
            acknowledgementFrames[1].second,
            "replayed completion acknowledgement must be byte-identical",
        )
        assertEquals(1, deliveries.size, "completion replay must not deliver the file twice")
        assertEquals(1, checkpointStore.deleteCount.get(), "completion replay must not repeat cleanup")
        assertFalse(
            transport.messages.any { it.op == CrossNetworkFileTransferOp.error },
            "no error must be sent when integrity passes"
        )
        assertTrue(
            receiver.progress.value.lastStatus?.startsWith("received complete") == true,
            "progress must reflect a completed receive"
        )
        assertEquals(null, checkpointStore.load(transferId), "checkpoint must be deleted after delivery")

        val completedProgress = receiver.progress.value
        val staleOwner = transport.currentTestSecureOwner()
        transport.replaceTestSecureOwner()
        receiver.handleIncoming(
            staleOwner,
            encode(
                CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.complete,
                    transferId = transferId,
                    receivedBytes = wholeFile.size.toLong(),
                    fileSha256 = sha256(wholeFile),
                ),
            ),
        )
        assertEquals(
            completedProgress,
            receiver.progress.value,
            "a stale packet with only a deleting checkpoint must not overwrite terminal success",
        )
    }

    @Test
    fun corruptedFile_neverDelivers_andDeletesCheckpoint() = runTest {
        val transport = RecordingTransport()
        val checkpointStore = RecordingCheckpointStore()
        val receiver = WebRtcFileTransferController(
            transport,
            json = json,
            checkpointStore = checkpointStore,
            inboundApprovalProvider = acceptingApprovalProvider()
        )

        val transferId = UUID.randomUUID().toString()
        val chunk0 = "abc".encodeToByteArray()
        val realChunk1 = "def".encodeToByteArray()
        val tamperedChunk1 = "dez".encodeToByteArray()

        // Receive a tampered chunk1 but attest to the ORIGINAL (correct) whole-file hash.
        feedMetadataAndChunks(receiver, transferId, chunk0, tamperedChunk1)
        receiver.handleIncoming(
            encode(
                CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.complete,
                    transferId = transferId,
                    receivedBytes = (chunk0.size + realChunk1.size).toLong(),
                    fileSha256 = sha256(chunk0 + realChunk1)
                )
            )
        )

        withTimeout(2_000) {
            while (transport.messages.none { it.op == CrossNetworkFileTransferOp.error }) yield()
            while (checkpointStore.deleteCount.get() == 0) yield()
        }
        repeat(5) { yield() }

        assertFalse(
            transport.messages.any { it.op == CrossNetworkFileTransferOp.completeAck },
            "corrupted transfer must never be acked as complete (no delivery)"
        )
        val error = transport.messages.last { it.op == CrossNetworkFileTransferOp.error }
        assertTrue(error.message?.contains("sha256 mismatch") == true)
        assertEquals(null, checkpointStore.load(transferId), "checkpoint must be deleted (no residue)")
    }

    @Test
    fun merkleRootMismatch_neverDelivers_andDeletesCheckpoint() = runTest {
        val transport = RecordingTransport()
        val checkpointStore = RecordingCheckpointStore()
        val receiver = WebRtcFileTransferController(
            transport,
            json = json,
            checkpointStore = checkpointStore,
            inboundApprovalProvider = acceptingApprovalProvider()
        )

        val transferId = UUID.randomUUID().toString()
        val chunk0 = "abc".encodeToByteArray()
        val chunk1 = "def".encodeToByteArray()
        val wholeFile = chunk0 + chunk1

        feedMetadataAndChunks(receiver, transferId, chunk0, chunk1)
        // Correct file hash, but a bogus merkle root => integrity must fail before any delivery.
        receiver.handleIncoming(
            encode(
                CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.complete,
                    transferId = transferId,
                    receivedBytes = wholeFile.size.toLong(),
                    fileSha256 = sha256(wholeFile),
                    merkleRoot = ByteArray(32) { 0x5A }
                )
            )
        )

        withTimeout(2_000) {
            while (transport.messages.none { it.op == CrossNetworkFileTransferOp.error }) yield()
            while (checkpointStore.deleteCount.get() == 0) yield()
        }
        repeat(5) { yield() }

        assertFalse(
            transport.messages.any { it.op == CrossNetworkFileTransferOp.completeAck },
            "merkle-mismatch transfer must never be acked (no delivery)"
        )
        val error = transport.messages.last { it.op == CrossNetworkFileTransferOp.error }
        assertTrue(error.message?.contains("merkle root mismatch") == true)
        assertEquals(null, checkpointStore.load(transferId), "checkpoint must be deleted (no residue)")
    }

    @Test
    fun declinedTransfer_cleansUpState_andNeverDelivers() = runTest {
        val transport = RecordingTransport()
        val checkpointStore = RecordingCheckpointStore()
        val receiver = WebRtcFileTransferController(
            transport,
            json = json,
            checkpointStore = checkpointStore,
            inboundApprovalProvider = InboundFileTransferApprovalProvider { InboundFileTransferDecision.Decline }
        )

        val transferId = UUID.randomUUID().toString()
        val chunk0 = "abc".encodeToByteArray()
        val chunk1 = "def".encodeToByteArray()
        val wholeFile = chunk0 + chunk1

        receiver.handleIncoming(
            encode(
                CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.metadata,
                    transferId = transferId,
                    fileName = "file.bin",
                    fileSize = wholeFile.size.toLong(),
                    chunkSize = chunk0.size,
                    totalChunks = 2,
                    mimeType = "application/octet-stream",
                ),
            ),
        )
        withTimeout(2_000) {
            while (checkpointStore.deleteCount.get() == 0) yield()
            while (receiver.progress.value.lastStatus?.contains("declined") != true) yield()
        }
        val declinedStatus = receiver.progress.value

        // Late frames still receive a fail-closed response, but cannot replace the local terminal
        // decision or resurrect delivery state.
        receiver.handleIncoming(
            encode(
                CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.chunk,
                    transferId = transferId,
                    chunkIndex = 0,
                    chunkData = chunk0,
                    chunkSha256 = sha256(chunk0),
                    rawSize = chunk0.size,
                ),
            ),
        )
        receiver.handleIncoming(
            encode(
                CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.complete,
                    transferId = transferId,
                    receivedBytes = wholeFile.size.toLong(),
                    fileSha256 = sha256(wholeFile)
                )
            )
        )

        withTimeout(2_000) {
            while (transport.messages.none { it.op == CrossNetworkFileTransferOp.error }) yield()
        }
        repeat(5) { yield() }

        assertFalse(
            transport.messages.any { it.op == CrossNetworkFileTransferOp.completeAck },
            "declined transfer must never be acked as complete (no delivery)"
        )
        assertEquals(null, checkpointStore.load(transferId), "declined transfer must delete its checkpoint")
        assertEquals(1, checkpointStore.deleteCount.get(), "late frames must not repeat cleanup")
        assertEquals(declinedStatus, receiver.progress.value, "late frames must not overwrite decline")
    }

    private fun feedMetadataAndChunks(
        receiver: WebRtcFileTransferController,
        transferId: String,
        chunk0: ByteArray,
        chunk1: ByteArray
    ) {
        val fileSize = (chunk0.size + chunk1.size).toLong()
        receiver.handleIncoming(
            encode(
                CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.metadata,
                    transferId = transferId,
                    fileName = "file.bin",
                    fileSize = fileSize,
                    chunkSize = chunk0.size,
                    totalChunks = 2,
                    mimeType = "application/octet-stream"
                )
            )
        )
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
        receiver.handleIncoming(
            encode(
                CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.chunk,
                    transferId = transferId,
                    chunkIndex = 1,
                    chunkData = chunk1,
                    chunkSha256 = sha256(chunk1),
                    rawSize = chunk1.size
                )
            )
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
        val ops = mutableListOf<CrossNetworkFileTransferOp>()
        val messages = CopyOnWriteArrayList<CrossNetworkFileTransferMessage>()
        val rawMessages = CopyOnWriteArrayList<Pair<CrossNetworkFileTransferMessage, ByteArray>>()

        override fun hasSessionKeys(): Boolean = true
        override fun authenticatedPeerDeviceId(): String = "trusted-peer"
        override fun negotiatedSuiteName(): String = "Q_PERIAPT_CONTEXT_BOUND"
        override fun negotiatedSuiteWireId(): Int = 0x0011
        override fun hasPqcSessionKeys(): Boolean = true
        override fun hasQPeriaptSessionKeys(): Boolean = true
        override fun computeOutboundHmacSha256(preimage: ByteArray): ByteArray =
            MessageDigest.getInstance("SHA-256").digest(preimage)
        override fun verifyInboundHmacSha256(preimage: ByteArray, mac: ByteArray): Boolean =
            mac.contentEquals(MessageDigest.getInstance("SHA-256").digest(preimage))
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
                rawMessages += message to bytes.copyOf()
                ops += message.op
            }
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
