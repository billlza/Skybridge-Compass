package com.skybridge.compass.filetransfer.webrtc

import com.skybridge.compass.core.p2p.P2PHandshakePolicyOverride
import com.skybridge.compass.core.webrtc.AuthenticatedPeerMetadata
import com.skybridge.compass.core.webrtc.SkyBridgeWebRtcConnectionManager
import com.skybridge.compass.core.webrtc.WebRtcSession
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferMessage
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferOp
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferWireCodec
import com.skybridge.compass.shared.webrtc.WebRtcAppSecureEnvelope
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.yield
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import com.skybridge.compass.filetransfer.webrtc.resume.TransferCheckpoint
import com.skybridge.compass.filetransfer.webrtc.resume.TransferCheckpointStore
import kotlinx.serialization.json.Json
import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.security.MessageDigest
import java.nio.file.Files
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

class WebRtcFileTransferControllerControlFlowTest {
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false }

    @Test
    fun sendBytesAsFile_usesFileTransferPacketTypeAndCompletesAgainstPeerController() = runTest {
        val senderTransport = RecordingTransport()
        val receiverTransport = RecordingTransport()
        senderTransport.peer = receiverTransport
        receiverTransport.peer = senderTransport

        val sender = WebRtcFileTransferController(senderTransport, json = json)
        val receiver = WebRtcFileTransferController(
            receiverTransport,
            json = json,
            inboundApprovalProvider = acceptingApprovalProvider()
        )
        senderTransport.onData = { bytes -> sender.handleIncoming(bytes) }
        receiverTransport.onData = { bytes -> receiver.handleIncoming(bytes) }

        val payload = "android file transfer proof".encodeToByteArray()
        val received = async {
            receiver.receivedFiles.first()
        }
        yield()

        sender.sendBytesAsFile(
            transferId = UUID.randomUUID().toString(),
            fileName = "proof.txt",
            mimeType = "text/plain",
            bytes = payload,
            chunkSize = 8
        )

        val file = withTimeoutOrNull(2_000) { received.await() }
            ?: error(
                "receiver did not emit completed file; " +
                    "receiverProgress=${receiver.progress.value}; " +
                    "senderOps=${senderTransport.ops}; receiverOps=${receiverTransport.ops}"
            )
        assertEquals("proof.txt", file.fileName)
        assertArrayEquals(payload, file.bytes)
        assertTrue(senderTransport.packetTypes.all { it == WebRtcAppSecureEnvelope.PacketType.FILE_TRANSFER })
        assertTrue(receiverTransport.packetTypes.all { it == WebRtcAppSecureEnvelope.PacketType.FILE_TRANSFER })
        val expectedChunkCount = (payload.size + 7) / 8
        assertEquals(
            listOf(CrossNetworkFileTransferOp.metadata) +
                List(expectedChunkCount) { CrossNetworkFileTransferOp.chunk } +
                listOf(CrossNetworkFileTransferOp.complete),
            senderTransport.ops
        )
        assertTrue(
            senderTransport.rawPayloads.first().contains("\"version\":1"),
            "metadata JSON must include version for Swift Codable interop"
        )
        (senderTransport.rawPayloads + receiverTransport.rawPayloads).forEach { rawPayload ->
            val bytes = rawPayload.encodeToByteArray()
            assertArrayEquals(
                bytes,
                CrossNetworkFileTransferWireCodec.encode(
                    CrossNetworkFileTransferWireCodec.decode(bytes),
                ),
                "shipping controller must emit the canonical F1 encoding",
            )
        }
        assertEquals(
            listOf(CrossNetworkFileTransferOp.metadataAck) +
                List(expectedChunkCount) { CrossNetworkFileTransferOp.chunkAck } +
                listOf(CrossNetworkFileTransferOp.completeAck),
            receiverTransport.ops
        )
        assertEquals(
            "send complete acknowledged",
            sender.progress.value.lastStatus,
            "a synchronous completeAck must not be overwritten by the initiating send call",
        )
    }

    @Test
    fun sendBytesAsFile_doesNotAcceptCompletionAcknowledgementBeforeCompleteDispatch() = runTest {
        val transport = RecordingTransport()
        lateinit var sender: WebRtcFileTransferController
        val payload = "early acknowledgement must not complete".encodeToByteArray()
        val transferId = UUID.randomUUID().toString()
        var injected = false
        transport.onFileTransferMessage = { message ->
            if (!injected && message.op == CrossNetworkFileTransferOp.chunk) {
                injected = true
                sender.handleIncoming(
                    encode(
                        CrossNetworkFileTransferMessage(
                            op = CrossNetworkFileTransferOp.completeAck,
                            transferId = transferId,
                            receivedBytes = payload.size.toLong(),
                            fileSha256 = sha256(payload),
                        ),
                    ),
                )
            }
        }
        sender = WebRtcFileTransferController(transport, json = json)

        sender.sendBytesAsFile(
            transferId = transferId,
            fileName = "early.bin",
            mimeType = "application/octet-stream",
            bytes = payload,
            chunkSize = 8,
        )

        assertTrue(injected)
        assertFalse(sender.isOperationAcknowledged(transferId))
        assertEquals("sent complete", sender.progress.value.lastStatus)

        sender.handleIncoming(
            encode(
                CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.completeAck,
                    transferId = transferId,
                    receivedBytes = payload.size.toLong(),
                    fileSha256 = sha256(payload),
                ),
            ),
        )
        assertTrue(sender.isOperationAcknowledged(transferId))
        assertEquals("send complete acknowledged", sender.progress.value.lastStatus)
    }

    @Test
    fun sendBytesAsFile_rejectsMissingOrMismatchedCompletionEvidence() = runTest {
        val payload = "completion evidence".encodeToByteArray()
        val digest = sha256(payload)
        val invalidEvidence = listOf(
            CrossNetworkFileTransferMessage(
                op = CrossNetworkFileTransferOp.completeAck,
                transferId = "placeholder",
            ),
            CrossNetworkFileTransferMessage(
                op = CrossNetworkFileTransferOp.completeAck,
                transferId = "placeholder",
                receivedBytes = payload.size.toLong() + 1,
                fileSha256 = digest,
            ),
            CrossNetworkFileTransferMessage(
                op = CrossNetworkFileTransferOp.completeAck,
                transferId = "placeholder",
                receivedBytes = payload.size.toLong(),
                fileSha256 = digest.copyOf(31),
            ),
            CrossNetworkFileTransferMessage(
                op = CrossNetworkFileTransferOp.completeAck,
                transferId = "placeholder",
                receivedBytes = payload.size.toLong(),
                fileSha256 = digest.copyOf().also { it[0] = (it[0].toInt() xor 1).toByte() },
            ),
        )

        invalidEvidence.forEach { invalid ->
            val transport = RecordingTransport()
            val checkpoints = RecordingCheckpointStore()
            val sender = WebRtcFileTransferController(
                transport,
                json = json,
                checkpointStore = checkpoints,
            )
            val transferId = UUID.randomUUID().toString()
            sender.sendBytesAsFile(
                transferId = transferId,
                fileName = "evidence.bin",
                mimeType = "application/octet-stream",
                bytes = payload,
                chunkSize = 8,
            )

            sender.handleIncoming(encode(invalid.copy(transferId = transferId)))
            withTimeout(2_000) {
                while (checkpoints.deleteCount.get() == 0) yield()
            }

            assertFalse(sender.isOperationAcknowledged(transferId))
            assertEquals(
                "send failed: invalid complete acknowledgement evidence",
                sender.progress.value.lastStatus,
            )
        }
    }

    @Test
    fun sendBytesAsFile_peerErrorCleansBufferedSendAndCannotBeOverwrittenByCaller() = runTest {
        val transport = RecordingTransport()
        val checkpoints = RecordingCheckpointStore()
        lateinit var sender: WebRtcFileTransferController
        val transferId = UUID.randomUUID().toString()
        transport.onFileTransferMessage = { message ->
            if (message.op == CrossNetworkFileTransferOp.complete) {
                sender.handleIncoming(
                    encode(
                        CrossNetworkFileTransferMessage(
                            op = CrossNetworkFileTransferOp.error,
                            transferId = transferId,
                            message = "receiver rejected completion",
                        ),
                    ),
                )
            }
        }
        sender = WebRtcFileTransferController(
            transport,
            json = json,
            checkpointStore = checkpoints,
        )

        val failure = runCatching {
            sender.sendBytesAsFile(
                transferId = transferId,
                fileName = "rejected.bin",
                mimeType = "application/octet-stream",
                bytes = "buffered payload".encodeToByteArray(),
                chunkSize = 8,
            )
        }.exceptionOrNull()
        withTimeout(2_000) {
            while (checkpoints.deleteCount.get() == 0) yield()
        }

        assertTrue(failure is IllegalStateException)
        assertEquals(
            "send failed: peer error: receiver rejected completion",
            sender.progress.value.lastStatus,
        )
        assertFalse(sender.isOperationAcknowledged(transferId))
    }

    @Test
    fun handleIncoming_acceptsAppleStyleCompleteWithFileSha256Only() = runTest {
        val transport = RecordingTransport()
        val receiver = WebRtcFileTransferController(
            transport,
            json = json,
            inboundApprovalProvider = acceptingApprovalProvider()
        )
        val transferId = UUID.randomUUID().toString()
        val payload = "apple complete proof".encodeToByteArray()
        val received = async {
            receiver.receivedFiles.first()
        }
        yield()

        receiver.handleIncoming(
            encode(
                CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.metadata,
                    transferId = transferId,
                    fileName = "apple.txt",
                    fileSize = payload.size.toLong(),
                    chunkSize = payload.size,
                    totalChunks = 1,
                    mimeType = "text/plain"
                )
            )
        )
        receiver.handleIncoming(
            encode(
                CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.chunk,
                    transferId = transferId,
                    chunkIndex = 0,
                    chunkData = payload,
                    chunkSha256 = sha256(payload),
                    rawSize = payload.size
                )
            )
        )
        receiver.handleIncoming(
            encode(
                CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.complete,
                    transferId = transferId,
                    receivedBytes = payload.size.toLong(),
                    fileSha256 = sha256(payload)
                )
            )
        )

        val file = received.await()
        assertEquals("apple.txt", file.fileName)
        assertArrayEquals(payload, file.bytes)
        assertEquals(
            listOf(
                CrossNetworkFileTransferOp.metadataAck,
                CrossNetworkFileTransferOp.chunkAck,
                CrossNetworkFileTransferOp.completeAck
            ),
            transport.ops
        )
        val completeAck = transport.messages.single { it.op == CrossNetworkFileTransferOp.completeAck }
        assertEquals(payload.size.toLong(), completeAck.receivedBytes)
        assertArrayEquals(sha256(payload), completeAck.fileSha256)
    }

    @Test
    fun handleIncoming_appPrivatePolicyCommitsBeforeAcknowledgingActualBytesAndDigest() = runTest {
        val parent = Files.createTempDirectory("skybridge-controller-private-")
        try {
            val committer = AppPrivateInboundFileCommitter(parent.resolve("inbound").toFile())
            val transport = RecordingTransport()
            val receiver = WebRtcFileTransferController(
                webrtc = transport,
                json = json,
                inboundApprovalProvider = acceptingApprovalProvider(),
                inboundFileDestinationPolicy = InboundFileDestinationPolicy.APP_PRIVATE_DURABLE,
                appPrivateInboundFileCommitterOverride = committer,
            )
            val transferId = UUID.randomUUID().toString()
            val payload = "durable app-private payload".encodeToByteArray()
            val received = async { receiver.receivedFiles.first() }
            yield()

            receiver.handleIncoming(
                encode(
                    CrossNetworkFileTransferMessage(
                        op = CrossNetworkFileTransferOp.metadata,
                        transferId = transferId,
                        fileName = "payload.bin",
                        fileSize = payload.size.toLong(),
                        chunkSize = payload.size,
                        totalChunks = 1,
                        mimeType = "application/octet-stream",
                    ),
                ),
            )
            receiver.handleIncoming(
                encode(
                    CrossNetworkFileTransferMessage(
                        op = CrossNetworkFileTransferOp.chunk,
                        transferId = transferId,
                        chunkIndex = 0,
                        chunkData = payload,
                        chunkSha256 = sha256(payload),
                        rawSize = payload.size,
                    ),
                ),
            )
            receiver.handleIncoming(
                encode(
                    CrossNetworkFileTransferMessage(
                        op = CrossNetworkFileTransferOp.complete,
                        transferId = transferId,
                        fileSha256 = sha256(payload),
                    ),
                ),
            )

            val completed = withTimeout(2_000) { received.await() }
            val committedPath = checkNotNull(completed.localPath)
            assertEquals(null, completed.bytes)
            assertArrayEquals(payload, Files.readAllBytes(java.nio.file.Path.of(committedPath)))
            assertFalse(committedPath.endsWith(".partial"))

            val completeAck = transport.messages.single {
                it.op == CrossNetworkFileTransferOp.completeAck
            }
            assertEquals(payload.size.toLong(), completeAck.receivedBytes)
            assertArrayEquals(sha256(payload), completeAck.fileSha256)
        } finally {
            parent.toFile().deleteRecursively()
        }
    }

    @Test
    fun handleIncoming_withoutApprovalProviderDeclinesInboundTransfer() = runTest {
        val transport = RecordingTransport()
        val receiver = WebRtcFileTransferController(transport, json = json)
        val transferId = UUID.randomUUID().toString()

        receiver.handleIncoming(
            encode(
                CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.metadata,
                    transferId = transferId,
                    fileName = "unapproved.txt",
                    fileSize = 4,
                    chunkSize = 4,
                    totalChunks = 1,
                    mimeType = "text/plain"
                )
            )
        )

        kotlinx.coroutines.withTimeout(2_000) {
            while (transport.ops.none { it == CrossNetworkFileTransferOp.error }) {
                yield()
            }
        }
        val error = transport.messages.single { it.op == CrossNetworkFileTransferOp.error }
        assertEquals(transferId, error.transferId)
        assertTrue(error.message?.contains("declined") == true)
        assertTrue(receiver.progress.value.lastStatus?.contains("declined") == true)
    }

    @Test
    fun handleIncoming_completeWithMissingChunksTimesOutAndDeletesReceiveCheckpoint() = runTest {
        val transport = RecordingTransport()
        val checkpointStore = RecordingCheckpointStore()
        val receiver = WebRtcFileTransferController(
            transport,
            json = json,
            checkpointStore = checkpointStore,
            inboundApprovalProvider = acceptingApprovalProvider(),
            missingChunkReceiveTimeoutMs = 25
        )
        val transferId = UUID.randomUUID().toString()
        val chunk0 = "abc".encodeToByteArray()
        val wholeFile = "abcdef".encodeToByteArray()

        receiver.handleIncoming(
            encode(
                CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.metadata,
                    transferId = transferId,
                    fileName = "missing.txt",
                    fileSize = wholeFile.size.toLong(),
                    chunkSize = 3,
                    totalChunks = 2,
                    mimeType = "text/plain"
                )
            )
        )
        withTimeout(2_000) {
            while (checkpointStore.saveCount.get() == 0) {
                yield()
            }
        }

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
                    op = CrossNetworkFileTransferOp.complete,
                    transferId = transferId,
                    receivedBytes = wholeFile.size.toLong(),
                    fileSha256 = sha256(wholeFile)
                )
            )
        )

        withTimeout(2_000) {
            while (checkpointStore.deleteCount.get() == 0) {
                yield()
            }
        }

        assertEquals(null, checkpointStore.load(transferId))
        assertTrue(receiver.progress.value.lastStatus?.contains("receive timed out") == true)
        assertTrue(
            transport.messages.any { message ->
                message.op == CrossNetworkFileTransferOp.chunkAck &&
                    message.message == "missingChunks(timeout)" &&
                    message.missingChunks?.contentEquals(intArrayOf(1)) == true
            },
            "receiver must send a final timeout NACK for the missing chunk"
        )
        assertFalse(
            transport.messages.any { it.op == CrossNetworkFileTransferOp.completeAck },
            "receiver must not complete ACK a timed-out incomplete transfer"
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
        val packetTypes = mutableListOf<WebRtcAppSecureEnvelope.PacketType>()
        val ops = mutableListOf<CrossNetworkFileTransferOp>()
        val messages = mutableListOf<CrossNetworkFileTransferMessage>()
        val rawPayloads = mutableListOf<String>()
        var onFileTransferMessage: ((CrossNetworkFileTransferMessage) -> Unit)? = null

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
            packetTypes += packetType
            if (packetType == WebRtcAppSecureEnvelope.PacketType.FILE_TRANSFER) {
                rawPayloads += bytes.decodeToString()
                val message = json.decodeFromString(
                    CrossNetworkFileTransferMessage.serializer(),
                    bytes.decodeToString()
                )
                messages += message
                ops += message.op
                onFileTransferMessage?.invoke(message)
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

        override suspend fun load(transferId: String): TransferCheckpoint? =
            checkpoints[transferId]

        override suspend fun save(checkpoint: TransferCheckpoint) {
            checkpoints[checkpoint.transferId] = checkpoint
            saveCount.incrementAndGet()
        }

        override suspend fun delete(transferId: String) {
            checkpoints.remove(transferId)
            deleteCount.incrementAndGet()
        }

        override suspend fun list(): List<TransferCheckpoint> =
            checkpoints.values.toList()
    }
}
