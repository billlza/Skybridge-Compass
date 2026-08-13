package com.skybridge.compass.filetransfer.webrtc

import com.skybridge.compass.core.p2p.P2PHandshakePolicyOverride
import com.skybridge.compass.core.webrtc.AuthenticatedPeerMetadata
import com.skybridge.compass.core.webrtc.SkyBridgeWebRtcConnectionManager
import com.skybridge.compass.core.webrtc.WebRtcSession
import com.skybridge.compass.filetransfer.webrtc.resume.TransferCheckpoint
import com.skybridge.compass.filetransfer.webrtc.resume.TransferCheckpointStore
import com.skybridge.compass.filetransfer.webrtc.resume.BatchManifest
import com.skybridge.compass.filetransfer.webrtc.resume.BatchManifestEntry
import com.skybridge.compass.filetransfer.webrtc.resume.BatchManifestStore
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferMessage
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferOp
import com.skybridge.compass.shared.webrtc.WebRtcAppSecureEnvelope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.yield
import kotlinx.serialization.json.Json
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.io.ByteArrayInputStream
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import java.io.IOException

/**
 * Tests for SEND-side resume from a persisted checkpoint (task 11.3 / Requirement 5.6, 5.7).
 *
 * The wire protocol carries no attempt generation. Recovery therefore migrates to a fresh transfer
 * id and retransmits from chunk zero; delayed packets for the timed-out id cannot affect it.
 */
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class WebRtcFileTransferControllerResumeSendTest {
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false }

    @Test
    fun resumeSend_usesFreshTransferIdAndRetransmitsFromZero() = runTest {
        val transport = RecordingTransport()
        val controller = WebRtcFileTransferController(transport, json = json)

        val transferId = UUID.randomUUID().toString()
        // 16 bytes, chunkSize 4 -> 4 chunks (indices 0..3), all full-size.
        val payload = "0123456789abcdef".encodeToByteArray()
        val checkpoint = TransferCheckpoint.newSend(
            transferId = transferId,
            sourceUri = null,
            fileName = "resume.bin",
            mimeType = "application/octet-stream",
            fileSize = payload.size.toLong(),
            chunkSize = 4,
            totalChunks = 4
        ).copy(ackedChunks = intArrayOf(0, 1)) // chunks 0 and 1 already confirmed by the peer

        val recoveryId = controller.resumeSendFromCheckpoint(
            checkpoint = checkpoint,
            owner = TestWebRtcSecureOperationOwner,
            mimeType = "application/octet-stream",
            openStream = { ByteArrayInputStream(payload) }
        )

        assertFalse(recoveryId == transferId, "recovery needs a fresh wire transfer id")
        val chunkIndices = transport.messages
            .filter { it.op == CrossNetworkFileTransferOp.chunk }
            .mapNotNull { it.chunkIndex }
            .toSet()
        assertEquals(setOf(0, 1, 2, 3), chunkIndices, "fresh-id recovery must retransmit from zero")

        assertTrue(
            transport.messages.any { it.op == CrossNetworkFileTransferOp.metadata && it.transferId == recoveryId },
            "recovery must send metadata only under the fresh id"
        )
        assertTrue(
            transport.messages.any { it.op == CrossNetworkFileTransferOp.complete && it.transferId == recoveryId },
            "recovery must send complete under the fresh id"
        )
        assertTrue(transport.messages.none { it.transferId == transferId })
    }

    @Test
    fun resumeSend_registersSendContextSoPeerNackResendsOnlyTheMissingChunk() = runTest {
        val transport = RecordingTransport()
        val controller = WebRtcFileTransferController(transport, json = json)

        val transferId = UUID.randomUUID().toString()
        val payload = "0123456789abcdef".encodeToByteArray() // 4 chunks of 4 bytes
        val checkpoint = TransferCheckpoint.newSend(
            transferId = transferId,
            sourceUri = null,
            fileName = "resume.bin",
            mimeType = "application/octet-stream",
            fileSize = payload.size.toLong(),
            chunkSize = 4,
            totalChunks = 4
        ).copy(ackedChunks = intArrayOf(0, 1, 2, 3)) // everything acked: initial pass sends no chunks

        val recoveryId = controller.resumeSendFromCheckpoint(
            checkpoint = checkpoint,
            owner = TestWebRtcSecureOperationOwner,
            mimeType = "application/octet-stream",
            openStream = { ByteArrayInputStream(payload) }
        )

        assertEquals(
            setOf(0, 1, 2, 3),
            transport.messages.filter { it.op == CrossNetworkFileTransferOp.chunk }.mapNotNull { it.chunkIndex }.toSet(),
            "old acknowledgements are not authority for a fresh wire id",
        )

        transport.clear()

        // Peer NACKs chunk 2. Because resume registered a send context (with the buffered chunk),
        // the NACK must trigger a targeted resend of exactly chunk 2.
        controller.handleIncoming(
            encode(
                CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.chunkAck,
                    transferId = recoveryId,
                    missingChunks = intArrayOf(2),
                    message = "missingChunks"
                )
            )
        )
        yield()

        val resent = transport.messages.filter { it.op == CrossNetworkFileTransferOp.chunk }
        assertEquals(1, resent.size, "exactly one chunk should be resent for a single-chunk NACK")
        assertEquals(2, resent.single().chunkIndex, "the resent chunk must be the NACKed chunk 2")
        assertFalse(
            resent.any { it.chunkIndex == 0 || it.chunkIndex == 1 },
            "a targeted NACK must not resend other already-acked chunks"
        )
    }

    @Test
    fun resumeSend_withoutResendCacheStillRequiresAndAcceptsExactCompletionEvidence() = runTest {
        val transport = RecordingTransport()
        val transferId = UUID.randomUUID().toString()
        val payload = "0123456789abcdef".encodeToByteArray()
        val checkpoint = TransferCheckpoint.newSend(
            transferId = transferId,
            sourceUri = null,
            fileName = "large-resume.bin",
            mimeType = "application/octet-stream",
            fileSize = payload.size.toLong(),
            chunkSize = 4,
            totalChunks = 4,
        )
        val checkpointStore = TrackingCheckpointStore(checkpoint)
        val controller = WebRtcFileTransferController(
            transport,
            json = json,
            checkpointStore = checkpointStore,
            maxResendCacheBytes = 8,
        )

        val recoveryId = controller.resumeSendFromCheckpoint(
            checkpoint = checkpoint,
            owner = TestWebRtcSecureOperationOwner,
            mimeType = "application/octet-stream",
            openStream = { ByteArrayInputStream(payload) },
        )

        transport.clear()
        controller.handleIncoming(
            encode(
                CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.chunkAck,
                    transferId = recoveryId,
                    missingChunks = intArrayOf(0),
                ),
            ),
        )
        assertTrue(
            transport.messages.none { it.op == CrossNetworkFileTransferOp.chunk },
            "a file above the resend-cache boundary must not retain chunk bytes",
        )

        controller.handleIncoming(
            encode(
                CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.completeAck,
                    transferId = recoveryId,
                    receivedBytes = payload.size.toLong(),
                    fileSha256 = sha256(payload),
                ),
            ),
        )
        withTimeout(2_000) {
            while (checkpointStore.deleteCount.get() < 2) yield()
        }

        assertTrue(controller.isOperationAcknowledged(recoveryId))
        assertEquals("send complete acknowledged", controller.progress.value.lastStatus)
        assertEquals(null, checkpointStore.load(transferId))
        assertEquals(null, checkpointStore.load(recoveryId))
    }

    @Test
    fun resumeSend_withoutResendCacheStillRetriesExactCompletionPayload() = runTest {
        val transport = RecordingTransport()
        val originalId = UUID.randomUUID().toString()
        val payload = "0123456789abcdef".encodeToByteArray()
        val checkpoint = TransferCheckpoint.newSend(
            transferId = originalId,
            sourceUri = null,
            fileName = "large-retry.bin",
            mimeType = "application/octet-stream",
            fileSize = payload.size.toLong(),
            chunkSize = 4,
            totalChunks = 4,
        )
        val controller = WebRtcFileTransferController(
            transport,
            json = json,
            checkpointStore = TrackingCheckpointStore(checkpoint),
            maxResendCacheBytes = 8,
            backgroundDispatcher = StandardTestDispatcher(testScheduler),
            completionAcknowledgementRetryDelayMs = 50L,
        )

        val recoveryId = controller.resumeSendFromCheckpoint(
            checkpoint = checkpoint,
            owner = TestWebRtcSecureOperationOwner,
            mimeType = "application/octet-stream",
            openStream = { ByteArrayInputStream(payload) },
        )
        val firstComplete = transport.rawMessages.single {
            it.first.op == CrossNetworkFileTransferOp.complete && it.first.transferId == recoveryId
        }.second

        advanceTimeBy(50L)
        runCurrent()

        val completions = transport.rawMessages.filter {
            it.first.op == CrossNetworkFileTransferOp.complete && it.first.transferId == recoveryId
        }
        assertEquals(2, completions.size)
        org.junit.jupiter.api.Assertions.assertArrayEquals(firstComplete, completions[1].second)
    }

    @Test
    fun resumeSend_withoutResendCachePeerErrorFailsAndCleansCompletionState() = runTest {
        val transport = RecordingTransport()
        val transferId = UUID.randomUUID().toString()
        val payload = "0123456789abcdef".encodeToByteArray()
        val checkpoint = TransferCheckpoint.newSend(
            transferId = transferId,
            sourceUri = null,
            fileName = "large-rejected.bin",
            mimeType = "application/octet-stream",
            fileSize = payload.size.toLong(),
            chunkSize = 4,
            totalChunks = 4,
        )
        val checkpointStore = TrackingCheckpointStore(checkpoint)
        val controller = WebRtcFileTransferController(
            transport,
            json = json,
            checkpointStore = checkpointStore,
            maxResendCacheBytes = 8,
        )

        val recoveryId = controller.resumeSendFromCheckpoint(
            checkpoint = checkpoint,
            owner = TestWebRtcSecureOperationOwner,
            mimeType = "application/octet-stream",
            openStream = { ByteArrayInputStream(payload) },
        )
        controller.handleIncoming(
            encode(
                CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.error,
                    transferId = recoveryId,
                    message = "receiver rejected streamed file",
                ),
            ),
        )
        withTimeout(2_000) {
            while (checkpointStore.deleteCount.get() < 2) yield()
        }

        assertEquals(
            "send failed: peer error: receiver rejected streamed file",
            controller.progress.value.lastStatus,
        )
        assertEquals(null, checkpointStore.load(transferId))
        controller.handleIncoming(
            encode(
                CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.completeAck,
                    transferId = recoveryId,
                    receivedBytes = payload.size.toLong(),
                    fileSha256 = sha256(payload),
                ),
            ),
        )
        assertFalse(controller.isOperationAcknowledged(recoveryId))
        assertEquals(
            "send failed: peer error: receiver rejected streamed file",
            controller.progress.value.lastStatus,
        )
    }

    @Test
    fun delayedAckForTimedOutIdCannotAcknowledgeFreshRecoveryGeneration() = runTest {
        val transport = RecordingTransport()
        val originalId = UUID.randomUUID().toString()
        val payload = "late acknowledgement isolation".encodeToByteArray()
        val checkpoint = TransferCheckpoint.newSend(
            transferId = originalId,
            sourceUri = null,
            fileName = "recovery.bin",
            mimeType = "application/octet-stream",
            fileSize = payload.size.toLong(),
            chunkSize = 4,
            totalChunks = (payload.size + 3) / 4,
        ).copy(ackedChunks = intArrayOf(0))
        val checkpointStore = TrackingCheckpointStore(checkpoint)
        val controller = WebRtcFileTransferController(
            transport,
            json = json,
            checkpointStore = checkpointStore,
        )

        val recoveryId = controller.resumeSendFromCheckpoint(
            checkpoint = checkpoint,
            owner = TestWebRtcSecureOperationOwner,
            mimeType = "application/octet-stream",
            openStream = { ByteArrayInputStream(payload) },
        )
        assertFalse(recoveryId == originalId)
        assertEquals(null, checkpointStore.load(originalId))
        assertTrue(checkpointStore.load(recoveryId)?.ackedChunks?.isEmpty() == true)

        controller.handleIncoming(
            encode(
                CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.completeAck,
                    transferId = originalId,
                    receivedBytes = payload.size.toLong(),
                    fileSha256 = sha256(payload),
                ),
            ),
        )
        assertFalse(controller.isOperationAcknowledged(originalId))
        assertFalse(controller.isOperationAcknowledged(recoveryId))
        assertEquals(recoveryId, controller.progress.value.transferId)
        assertEquals("resume: sent complete", controller.progress.value.lastStatus)

        controller.handleIncoming(
            encode(
                CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.completeAck,
                    transferId = recoveryId,
                    receivedBytes = payload.size.toLong(),
                    fileSha256 = sha256(payload),
                ),
            ),
        )
        assertTrue(controller.isOperationAcknowledged(recoveryId))
        assertEquals("send complete acknowledged", controller.progress.value.lastStatus)
    }

    @Test
    fun batchRecoveryFailsClosedBeforeCheckpointOrWireMutation() = runTest {
        val originalId = UUID.randomUUID().toString()
        val batchId = UUID.randomUUID().toString()
        val payload = "batch recovery".encodeToByteArray()
        val checkpoint = TransferCheckpoint.newSend(
            transferId = originalId,
            sourceUri = null,
            fileName = "batch.bin",
            mimeType = "application/octet-stream",
            fileSize = payload.size.toLong(),
            chunkSize = 4,
            totalChunks = (payload.size + 3) / 4,
        )
        val checkpoints = TrackingCheckpointStore(checkpoint)
        val transport = RecordingTransport()
        val controller = WebRtcFileTransferController(
            transport,
            json = json,
            checkpointStore = checkpoints,
            batchManifestStore = StaticBatchManifestStore(
                BatchManifest(
                    batchId = batchId,
                    entries = listOf(BatchManifestEntry(transferId = originalId)),
                ),
            ),
        )

        val failure = runCatching {
            controller.resumeSendFromCheckpoint(
                checkpoint = checkpoint,
                owner = TestWebRtcSecureOperationOwner,
                mimeType = "application/octet-stream",
                openStream = { ByteArrayInputStream(payload) },
            )
        }.exceptionOrNull()

        assertTrue(failure is BatchResumeMigrationUnsupportedException)
        assertEquals(checkpoint, checkpoints.load(originalId))
        assertEquals(listOf(originalId), checkpoints.list().map { it.transferId })
        assertTrue(transport.messages.isEmpty())
    }

    @Test
    fun failedOldCheckpointDeletionRollsBackFreshRecoveryCheckpointWithoutSending() = runTest {
        val originalId = UUID.randomUUID().toString()
        val payload = "migration rollback".encodeToByteArray()
        val checkpoint = TransferCheckpoint.newSend(
            transferId = originalId,
            sourceUri = null,
            fileName = "rollback.bin",
            mimeType = "application/octet-stream",
            fileSize = payload.size.toLong(),
            chunkSize = 4,
            totalChunks = (payload.size + 3) / 4,
        )
        val checkpoints = TrackingCheckpointStore(checkpoint, failDeleteId = originalId)
        val transport = RecordingTransport()
        val controller = WebRtcFileTransferController(
            transport,
            json = json,
            checkpointStore = checkpoints,
        )

        val failure = runCatching {
            controller.resumeSendFromCheckpoint(
                checkpoint = checkpoint,
                owner = TestWebRtcSecureOperationOwner,
                mimeType = "application/octet-stream",
                openStream = { ByteArrayInputStream(payload) },
            )
        }.exceptionOrNull()

        assertTrue(failure is CheckpointMutationException)
        assertEquals(checkpoint, checkpoints.load(originalId))
        assertEquals(listOf(originalId), checkpoints.list().map { it.transferId })
        assertTrue(transport.messages.isEmpty())
    }

    private fun encode(message: CrossNetworkFileTransferMessage): ByteArray =
        json.encodeToString(CrossNetworkFileTransferMessage.serializer(), message).encodeToByteArray()

    private fun sha256(bytes: ByteArray): ByteArray =
        MessageDigest.getInstance("SHA-256").digest(bytes)

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
        val messages = mutableListOf<CrossNetworkFileTransferMessage>()
        val rawMessages = mutableListOf<Pair<CrossNetworkFileTransferMessage, ByteArray>>()

        fun clear() = messages.clear()

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
                rawMessages += message to bytes.copyOf()
            }
            return true
        }

        override fun disconnect() = Unit
        override fun release() = Unit
    }

    private class TrackingCheckpointStore(
        initial: TransferCheckpoint,
        private val failDeleteId: String? = null,
    ) : TransferCheckpointStore {
        private val checkpoints = ConcurrentHashMap<String, TransferCheckpoint>().apply {
            put(initial.transferId, initial)
        }
        val deleteCount = AtomicInteger()

        override suspend fun load(transferId: String): TransferCheckpoint? = checkpoints[transferId]

        override suspend fun save(checkpoint: TransferCheckpoint) {
            checkpoints[checkpoint.transferId] = checkpoint
        }

        override suspend fun delete(transferId: String) {
            if (transferId == failDeleteId) throw IOException("synthetic old checkpoint delete failure")
            checkpoints.remove(transferId)
            deleteCount.incrementAndGet()
        }

        override suspend fun list(): List<TransferCheckpoint> = checkpoints.values.toList()
    }

    private class StaticBatchManifestStore(
        private val manifest: BatchManifest,
    ) : BatchManifestStore {
        override val coordinationNamespace: String = "resume-test-${manifest.batchId}"

        override suspend fun save(
            manifest: BatchManifest,
            runAuthorizedCommit: (commit: () -> Unit) -> Boolean,
        ) = error("save is not expected")

        override suspend fun load(batchId: String): BatchManifest? =
            manifest.takeIf { it.batchId == batchId }

        override suspend fun delete(batchId: String) = error("delete is not expected")

        override suspend fun list(): List<BatchManifest> = listOf(manifest)
    }
}
