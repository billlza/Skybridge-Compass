package com.skybridge.compass.filetransfer.webrtc

import com.skybridge.compass.core.p2p.P2PHandshakePolicyOverride
import com.skybridge.compass.core.webrtc.AuthenticatedPeerMetadata
import com.skybridge.compass.core.webrtc.SkyBridgeWebRtcConnectionManager
import com.skybridge.compass.core.webrtc.WebRtcSession
import com.skybridge.compass.filetransfer.webrtc.resume.BatchManifestEntry
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferMessage
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferOp
import com.skybridge.compass.shared.webrtc.WebRtcAppSecureEnvelope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.security.MessageDigest

/**
 * Tests for batch/directory transfer wiring (task 11.2 / Requirement 5.8, 5.13).
 *
 * The batch fields (batchId/batchIndex/batchTotal/relativePath) are part of the existing wire
 * schema shared with the Apple reference, so exercising them is NOT a wire-protocol change.
 */
class WebRtcFileTransferControllerBatchTest {
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false }

    @Test
    fun batchFields_flowThroughMetadataAndCompleteForEachItem() = runTest {
        val transport = RecordingTransport()
        val sender = WebRtcFileTransferController(transport, json = json)

        val items = listOf(
            WebRtcFileTransferController.BatchBytesItem(
                fileName = "a.txt",
                bytes = "alpha".encodeToByteArray(),
                relativePath = "docs/a.txt"
            ),
            WebRtcFileTransferController.BatchBytesItem(
                fileName = "b.txt",
                bytes = "bravo!!".encodeToByteArray(),
                relativePath = "docs/nested/b.txt"
            ),
            WebRtcFileTransferController.BatchBytesItem(
                fileName = "c.txt",
                bytes = "charlie".encodeToByteArray(),
                relativePath = "c.txt"
            )
        )

        sender.sendBytesAsFilesBatch(items, chunkSize = 4)

        val metadatas = transport.messages.filter { it.op == CrossNetworkFileTransferOp.metadata }
        val completes = transport.messages.filter { it.op == CrossNetworkFileTransferOp.complete }
        assertEquals(3, metadatas.size, "one metadata per batch item")
        assertEquals(3, completes.size, "one complete per batch item")

        // A single, shared, canonical batchId across all items.
        val batchIds = metadatas.mapNotNull { it.batchId }.toSet()
        assertEquals(1, batchIds.size, "all items share one batchId; got $batchIds")

        // batchTotal is the item count and batchIndex covers 0..total-1 on both metadata & complete.
        metadatas.forEach { assertEquals(3, it.batchTotal) }
        completes.forEach { assertEquals(3, it.batchTotal) }
        assertEquals(setOf(0, 1, 2), metadatas.mapNotNull { it.batchIndex }.toSet())
        assertEquals(setOf(0, 1, 2), completes.mapNotNull { it.batchIndex }.toSet())

        // relativePath (with directory hierarchy) travels through metadata and complete per item.
        assertEquals(
            setOf("docs/a.txt", "docs/nested/b.txt", "c.txt"),
            metadatas.mapNotNull { it.relativePath }.toSet()
        )
        assertEquals(
            setOf("docs/a.txt", "docs/nested/b.txt", "c.txt"),
            completes.mapNotNull { it.relativePath }.toSet()
        )

        // Per item, the metadata and complete carry the SAME batch fields (matched by transferId).
        metadatas.forEach { meta ->
            val complete = completes.first { it.transferId == meta.transferId }
            assertEquals(meta.batchId, complete.batchId)
            assertEquals(meta.batchIndex, complete.batchIndex)
            assertEquals(meta.batchTotal, complete.batchTotal)
            assertEquals(meta.relativePath, complete.relativePath)
        }
    }

    @Test
    fun batchProgress_aggregatesPerFileProgressAcrossEntries() {
        // Pure aggregation over the exposed leaf-node value (Requirement 5.8).
        val files = listOf(
            WebRtcFileTransferController.BatchFileProgress(
                transferId = "t0", batchIndex = 0, relativePath = "a", fileName = "a",
                totalBytes = 100, confirmedBytes = 100, status = BatchManifestEntry.Status.COMPLETED
            ),
            WebRtcFileTransferController.BatchFileProgress(
                transferId = "t1", batchIndex = 1, relativePath = "b", fileName = "b",
                totalBytes = 300, confirmedBytes = 150, status = BatchManifestEntry.Status.IN_PROGRESS
            ),
            WebRtcFileTransferController.BatchFileProgress(
                transferId = "t2", batchIndex = 2, relativePath = "c", fileName = "c",
                totalBytes = 100, confirmedBytes = 0, status = BatchManifestEntry.Status.PENDING
            )
        )
        val progress = WebRtcFileTransferController.BatchProgress(
            batchId = "batch", batchTotal = 3, files = files
        )

        assertEquals(500L, progress.totalBytes)
        assertEquals(250L, progress.confirmedBytes)
        assertEquals(0.5, progress.fraction, 1e-9)
        assertEquals(1, progress.completedCount)
        assertEquals(0, progress.failedCount)
        assertTrue(!progress.isTerminal, "batch with a pending file is not terminal")
    }

    @Test
    fun batchProgress_reachesFullAsEachItemIsConfirmed() = runTest {
        val transport = RecordingTransport()
        val sender = WebRtcFileTransferController(transport, json = json)

        val items = listOf(
            WebRtcFileTransferController.BatchBytesItem("a.txt", "aaaa".encodeToByteArray(), "a.txt"),
            WebRtcFileTransferController.BatchBytesItem("b.txt", "bbbb".encodeToByteArray(), "b.txt")
        )
        sender.sendBytesAsFilesBatch(items, chunkSize = 4)

        // Nothing confirmed yet: overall progress is 0.
        assertEquals(0.0, sender.batchProgress.value.fraction, 1e-9)
        assertEquals(8L, sender.batchProgress.value.totalBytes)

        // Confirm each item via completeAck; overall progress advances then reaches 100%.
        val transferIds = transport.messages
            .filter { it.op == CrossNetworkFileTransferOp.metadata }
            .map { it.transferId }
        assertEquals(2, transferIds.size)

        sender.handleIncoming(completeAck(transferIds[0], "aaaa".encodeToByteArray()))
        assertEquals(0.5, sender.batchProgress.value.fraction, 1e-9)

        sender.handleIncoming(completeAck(transferIds[1], "bbbb".encodeToByteArray()))
        assertEquals(1.0, sender.batchProgress.value.fraction, 1e-9)
        assertEquals(2, sender.batchProgress.value.completedCount)
        assertTrue(sender.batchProgress.value.isTerminal)
    }

    @Test
    fun batchItemFailure_isIsolatedAndOthersStillComplete() = runTest {
        // Transport fails every send for the item whose relativePath is the target; others succeed.
        val transport = RecordingTransport(failRelativePath = "docs/bad.txt")
        val sender = WebRtcFileTransferController(transport, json = json)

        val items = listOf(
            WebRtcFileTransferController.BatchBytesItem("good1.txt", "one".encodeToByteArray(), "docs/good1.txt"),
            WebRtcFileTransferController.BatchBytesItem("bad.txt", "boom".encodeToByteArray(), "docs/bad.txt"),
            WebRtcFileTransferController.BatchBytesItem("good2.txt", "three".encodeToByteArray(), "docs/good2.txt")
        )
        sender.sendBytesAsFilesBatch(items, chunkSize = 4)

        val progress = sender.batchProgress.value
        assertEquals(3, progress.files.size, "the loop must not abort early: all items are tracked")

        val bad = progress.files.first { it.relativePath == "docs/bad.txt" }
        assertEquals(BatchManifestEntry.Status.FAILED, bad.status, "the failing item is isolated as FAILED")
        assertEquals(1, progress.failedCount)

        // The other two items were sent successfully and are awaiting confirmation.
        val good1 = progress.files.first { it.relativePath == "docs/good1.txt" }
        val good2 = progress.files.first { it.relativePath == "docs/good2.txt" }
        assertEquals(BatchManifestEntry.Status.IN_PROGRESS, good1.status)
        assertEquals(BatchManifestEntry.Status.IN_PROGRESS, good2.status)

        // Both good items produced a full metadata->complete flow on the wire.
        val goodMetas = transport.messages.filter {
            it.op == CrossNetworkFileTransferOp.metadata && it.relativePath != "docs/bad.txt"
        }
        assertEquals(2, goodMetas.size)
        goodMetas.forEach { meta ->
            assertNotNull(
                transport.messages.firstOrNull {
                    it.op == CrossNetworkFileTransferOp.complete && it.transferId == meta.transferId
                },
                "each surviving batch item must send its complete message"
            )
        }

        // Confirm the two good items; the batch reaches a terminal state with exactly one failure.
        transport.messages
            .filter { it.op == CrossNetworkFileTransferOp.metadata && it.relativePath != "docs/bad.txt" }
            .forEach { meta ->
                val payload = items.single { it.relativePath == meta.relativePath }.bytes
                sender.handleIncoming(completeAck(meta.transferId, payload))
            }
        val finalProgress = sender.batchProgress.value
        assertEquals(2, finalProgress.completedCount)
        assertEquals(1, finalProgress.failedCount)
        assertTrue(finalProgress.isTerminal, "batch is terminal once every item is completed or failed")
    }

    private fun encode(message: CrossNetworkFileTransferMessage): ByteArray =
        json.encodeToString(CrossNetworkFileTransferMessage.serializer(), message).encodeToByteArray()

    private fun completeAck(transferId: String, payload: ByteArray): ByteArray = encode(
        CrossNetworkFileTransferMessage(
            op = CrossNetworkFileTransferOp.completeAck,
            transferId = transferId,
            receivedBytes = payload.size.toLong(),
            fileSha256 = sha256(payload),
        ),
    )

    private fun sha256(bytes: ByteArray): ByteArray =
        MessageDigest.getInstance("SHA-256").digest(bytes)

    private inner class RecordingTransport(
        private val failRelativePath: String? = null
    ) : TestCrossNetworkWebRtcTransportAdapter() {
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

        // transferIds whose metadata carried the target relativePath -> every send fails.
        private val failingTransferIds = mutableSetOf<String>()

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
            if (packetType != WebRtcAppSecureEnvelope.PacketType.FILE_TRANSFER) return true
            val message = json.decodeFromString(
                CrossNetworkFileTransferMessage.serializer(),
                bytes.decodeToString()
            )
            if (failRelativePath != null) {
                if (message.op == CrossNetworkFileTransferOp.metadata && message.relativePath == failRelativePath) {
                    // Fail this item's very first send; record it so any later sends also fail.
                    failingTransferIds += message.transferId
                    return false
                }
                if (message.transferId in failingTransferIds) return false
            }
            messages += message
            return true
        }

        override fun disconnect() = Unit
        override fun release() = Unit
    }
}
