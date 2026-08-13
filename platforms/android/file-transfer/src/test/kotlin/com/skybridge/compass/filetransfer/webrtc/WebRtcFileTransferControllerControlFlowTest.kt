package com.skybridge.compass.filetransfer.webrtc

import com.skybridge.compass.core.p2p.P2PHandshakePolicyOverride
import com.skybridge.compass.core.webrtc.AuthenticatedPeerMetadata
import com.skybridge.compass.core.webrtc.SkyBridgeWebRtcConnectionManager
import com.skybridge.compass.core.webrtc.WebRtcSession
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferMessage
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferOp
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferWireCodec
import com.skybridge.compass.shared.webrtc.WebRtcAppSecureEnvelope
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.runCurrent
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
import java.io.IOException
import java.security.MessageDigest
import java.nio.file.Files
import java.util.UUID
import java.util.concurrent.CyclicBarrier
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

@OptIn(ExperimentalCoroutinesApi::class)
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
            val backgroundDispatcher = StandardTestDispatcher(testScheduler)
            val receiver = WebRtcFileTransferController(
                webrtc = transport,
                json = json,
                inboundApprovalProvider = acceptingApprovalProvider(),
                inboundFileDestinationPolicy = InboundFileDestinationPolicy.APP_PRIVATE_DURABLE,
                appPrivateInboundFileCommitterOverride = committer,
                backgroundDispatcher = backgroundDispatcher,
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
                        receivedBytes = payload.size.toLong(),
                        fileSha256 = sha256(payload),
                    ),
                ),
            )

            runCurrent()
            val completed = received.await()
            val committedPath = checkNotNull(completed.localPath)
            assertEquals(null, completed.bytes)
            assertArrayEquals(payload, Files.readAllBytes(java.nio.file.Path.of(committedPath)))
            assertFalse(committedPath.endsWith(".partial"))

            val completeAck = transport.messages.single {
                it.op == CrossNetworkFileTransferOp.completeAck
            }
            assertEquals(payload.size.toLong(), completeAck.receivedBytes)
            assertArrayEquals(sha256(payload), completeAck.fileSha256)

            receiver.handleIncoming(inboundComplete(transferId, payload))
            runCurrent()
            val completeAcks = transport.rawPayloads.zip(transport.messages)
                .filter { it.second.op == CrossNetworkFileTransferOp.completeAck }
                .map { it.first }
            assertEquals(2, completeAcks.size)
            assertEquals(
                completeAcks[0],
                completeAcks[1],
                "an exact duplicate must replay the witness produced by the destination commit gate",
            )
            assertEquals(1, Files.list(java.nio.file.Path.of(committedPath).parent).use { it.count() })

            transport.replaceTestSecureOwner()
            assertArrayEquals(payload, Files.readAllBytes(java.nio.file.Path.of(committedPath)))
        } finally {
            parent.toFile().deleteRecursively()
        }
    }

    @Test
    fun handleIncoming_ownerReplacementBeforeAppPrivateCommitGateLeavesNoDestinationOrWitness() = runTest {
        val parent = Files.createTempDirectory("skybridge-controller-private-stale-")
        try {
            val inboundDirectory = parent.resolve("inbound")
            val committer = AppPrivateInboundFileCommitter(inboundDirectory.toFile())
            val commitReady = CountDownLatch(1)
            val allowCommitGate = CountDownLatch(1)
            val transport = RecordingTransport()
            val receiver = WebRtcFileTransferController(
                webrtc = transport,
                json = json,
                inboundApprovalProvider = acceptingApprovalProvider(),
                inboundFileDestinationPolicy = InboundFileDestinationPolicy.APP_PRIVATE_DURABLE,
                appPrivateInboundFileCommitterOverride = committer,
                backgroundDispatcher = StandardTestDispatcher(testScheduler),
                beforeInboundDestinationCommit = {
                    commitReady.countDown()
                    check(allowCommitGate.await(2, TimeUnit.SECONDS))
                },
            )
            val transferId = UUID.randomUUID().toString()
            val payload = "owner replacement before commit".encodeToByteArray()
            receiver.handleIncoming(inboundMetadata(transferId, payload, "stale.bin"))
            runCurrent()
            receiver.handleIncoming(inboundChunk(transferId, payload))

            val executor = Executors.newSingleThreadExecutor()
            try {
                val completing = executor.submit {
                    receiver.handleIncoming(inboundComplete(transferId, payload))
                }
                assertTrue(commitReady.await(2, TimeUnit.SECONDS))
                val replacement = transport.replaceTestSecureOwner()
                allowCommitGate.countDown()
                completing.get(2, TimeUnit.SECONDS)
                runCurrent()

                val retainedEntries = Files.list(inboundDirectory).use { entries ->
                    entries.map { it.fileName.toString() }.toList()
                }
                assertEquals(1, retainedEntries.size)
                assertTrue(
                    retainedEntries.single().endsWith(".partial"),
                    "stale cleanup may retain only its owned recoverable staging file",
                )
                assertFalse(retainedEntries.contains("stale.bin"))
                assertFalse(
                    transport.messages.any { it.op == CrossNetworkFileTransferOp.completeAck },
                    "a stale owner must neither commit a destination nor publish completion evidence",
                )

                receiver.handleIncoming(replacement, inboundComplete(transferId, payload))
                assertTrue(
                    transport.messages.last().op == CrossNetworkFileTransferOp.error &&
                        transport.messages.last().message == "unknown transferId",
                    "the replacement owner must not inherit a replay witness",
                )
            } finally {
                allowCommitGate.countDown()
                executor.shutdownNow()
            }
        } finally {
            parent.toFile().deleteRecursively()
        }
    }

    @Test
    fun handleIncoming_postPrepareCommitFailureAbortsWitnessAndDuplicateFailsClosed() = runTest {
        val transport = RecordingTransport()
        val receiver = WebRtcFileTransferController(
            webrtc = transport,
            json = json,
            inboundApprovalProvider = acceptingApprovalProvider(),
            backgroundDispatcher = StandardTestDispatcher(testScheduler),
            beforeInboundDestinationCommit = { throw IOException("injected destination failure") },
        )
        val transferId = UUID.randomUUID().toString()
        val payload = "prepared completion must terminate".encodeToByteArray()
        val complete = inboundComplete(transferId, payload)

        receiver.handleIncoming(inboundMetadata(transferId, payload, "abort.bin"))
        runCurrent()
        receiver.handleIncoming(inboundChunk(transferId, payload))
        receiver.handleIncoming(complete)
        runCurrent()

        assertEquals(1, transport.messages.count { it.op == CrossNetworkFileTransferOp.error })
        assertTrue(receiver.progress.value.lastStatus?.contains("destination commit failed") == true)
        assertFalse(transport.messages.any { it.op == CrossNetworkFileTransferOp.completeAck })

        receiver.handleIncoming(complete)
        runCurrent()
        assertEquals(
            2,
            transport.messages.count { it.op == CrossNetworkFileTransferOp.error },
            "an aborted prepared token must become a tombstone, never a silent active wait",
        )
        assertTrue(transport.messages.last().message == "completion evidence mismatch")
    }

    @Test
    fun handleIncoming_approvalBeforeCompleteFinalizesExactlyOnce() = runTest {
        val transport = RecordingTransport()
        val receiver = WebRtcFileTransferController(
            webrtc = transport,
            json = json,
            inboundApprovalProvider = acceptingApprovalProvider(),
            backgroundDispatcher = StandardTestDispatcher(testScheduler),
        )
        val transferId = UUID.randomUUID().toString()
        val payload = "approval precedes completion".encodeToByteArray()
        val received = async { receiver.receivedFiles.first() }
        runCurrent()

        receiver.handleIncoming(inboundMetadata(transferId, payload, "approved-first.txt"))
        runCurrent()
        receiver.handleIncoming(inboundChunk(transferId, payload))
        receiver.handleIncoming(inboundComplete(transferId, payload))

        val completed = received.await()
        assertEquals(transferId, completed.transferId)
        assertArrayEquals(payload, completed.bytes)
        assertEquals(
            1,
            transport.messages.count { it.op == CrossNetworkFileTransferOp.completeAck },
        )
    }

    @Test
    fun handleIncoming_completeBeforeApprovalFinalizesAfterDecisionWithoutPolling() = runTest {
        val approval = CompletableDeferred<InboundFileTransferDecision>()
        val transport = RecordingTransport()
        val receiver = WebRtcFileTransferController(
            webrtc = transport,
            json = json,
            inboundApprovalProvider = InboundFileTransferApprovalProvider { approval.await() },
            backgroundDispatcher = StandardTestDispatcher(testScheduler),
        )
        val transferId = UUID.randomUUID().toString()
        val payload = "completion precedes approval".encodeToByteArray()
        val received = async { receiver.receivedFiles.first() }
        runCurrent()

        receiver.handleIncoming(inboundMetadata(transferId, payload, "completed-first.txt"))
        runCurrent()
        receiver.handleIncoming(inboundChunk(transferId, payload))
        receiver.handleIncoming(inboundComplete(transferId, payload))
        runCurrent()

        assertFalse(received.isCompleted)
        assertFalse(
            transport.messages.any { it.op == CrossNetworkFileTransferOp.completeAck },
            "completion must remain pending until the explicit approval decision",
        )

        approval.complete(acceptDecision("completed-first.txt"))
        runCurrent()

        val completed = received.await()
        assertEquals(transferId, completed.transferId)
        assertArrayEquals(payload, completed.bytes)
        assertEquals(
            1,
            transport.messages.count { it.op == CrossNetworkFileTransferOp.completeAck },
        )
    }

    @Test
    fun handleIncoming_concurrentDuplicateCompleteClaimsFinalizationOnce() = runTest {
        val transport = RecordingTransport()
        val receiver = WebRtcFileTransferController(
            webrtc = transport,
            json = json,
            inboundApprovalProvider = acceptingApprovalProvider(),
            backgroundDispatcher = StandardTestDispatcher(testScheduler),
        )
        val transferId = UUID.randomUUID().toString()
        val payload = "concurrent terminal claim".encodeToByteArray()
        val received = async { receiver.receivedFiles.first() }
        runCurrent()

        receiver.handleIncoming(inboundMetadata(transferId, payload, "concurrent.txt"))
        runCurrent()
        receiver.handleIncoming(inboundChunk(transferId, payload))

        val complete = inboundComplete(transferId, payload)
        val executor = Executors.newFixedThreadPool(2)
        try {
            val barrier = CyclicBarrier(3)
            val completions = List(2) {
                executor.submit {
                    barrier.await()
                    receiver.handleIncoming(complete)
                }
            }
            barrier.await()
            completions.forEach { it.get() }
        } finally {
            executor.shutdownNow()
        }
        runCurrent()

        val completed = received.await()
        assertEquals(transferId, completed.transferId)
        assertArrayEquals(payload, completed.bytes)
        assertEquals(
            1,
            transport.messages.count { it.op == CrossNetworkFileTransferOp.completeAck },
            "concurrent terminal callbacks must not emit duplicate completion evidence",
        )
    }

    @Test
    fun handleIncoming_lostCompletionAckReplaysWitnessWithoutDuplicateDeliveryOrCleanup() = runTest {
        val transport = RecordingTransport()
        var rejectedFirstAcknowledgement = false
        transport.acceptMessage = { message ->
            if (message.op == CrossNetworkFileTransferOp.completeAck && !rejectedFirstAcknowledgement) {
                rejectedFirstAcknowledgement = true
                false
            } else {
                true
            }
        }
        val checkpointStore = RecordingCheckpointStore()
        val receiver = WebRtcFileTransferController(
            webrtc = transport,
            json = json,
            checkpointStore = checkpointStore,
            inboundApprovalProvider = acceptingApprovalProvider(),
            backgroundDispatcher = StandardTestDispatcher(testScheduler),
        )
        val transferId = UUID.randomUUID().toString()
        val payload = "durable replay witness".encodeToByteArray()
        val deliveries = mutableListOf<WebRtcFileTransferController.ReceivedFile>()
        val collector = backgroundScope.launch {
            receiver.receivedFiles.collect { deliveries += it }
        }
        runCurrent()

        val metadata = inboundMetadata(transferId, payload, "replay.txt")
        val complete = inboundComplete(transferId, payload)
        receiver.handleIncoming(metadata)
        runCurrent()
        receiver.handleIncoming(inboundChunk(transferId, payload))
        receiver.handleIncoming(complete)
        runCurrent()

        assertEquals(1, deliveries.size)
        assertEquals(1, checkpointStore.deleteCount.get())
        assertEquals(
            "received complete; acknowledgement pending replay: WebRtcFileTransferSendException",
            receiver.progress.value.lastStatus,
        )

        receiver.handleIncoming(complete)
        runCurrent()
        assertEquals(1, deliveries.size)
        assertEquals(1, checkpointStore.deleteCount.get())
        assertEquals("received complete; acknowledgement replayed", receiver.progress.value.lastStatus)
        assertEquals(
            2,
            transport.messages.count { it.op == CrossNetworkFileTransferOp.completeAck },
            "the second identical complete must replay the stored acknowledgement",
        )

        val conflictingComplete = CrossNetworkFileTransferWireCodec.decode(complete).copy(
            merkleRoot = ByteArray(32) { 7 },
        )
        receiver.handleIncoming(encode(conflictingComplete))
        receiver.handleIncoming(metadata)
        runCurrent()
        assertEquals(
            2,
            transport.messages.count { it.op == CrossNetworkFileTransferOp.error },
            "conflicting completion and same-owner metadata reuse must both fail closed",
        )

        receiver.handleIncoming(complete)
        runCurrent()
        assertEquals(3, transport.messages.count { it.op == CrossNetworkFileTransferOp.completeAck })
        collector.cancelAndJoin()
    }

    @Test
    fun handleIncoming_rekeyBetweenEntryCheckAndLedgerReserveFailsStaleWithoutCrash() = runTest {
        val paused = CountDownLatch(1)
        val release = CountDownLatch(1)
        val pauseFirst = AtomicBoolean(true)
        val transport = RecordingTransport()
        val firstTransferId = UUID.randomUUID().toString()
        val secondTransferId = UUID.randomUUID().toString()
        val firstPayload = "old owner reserve".encodeToByteArray()
        val secondPayload = "new owner reserve".encodeToByteArray()
        val controller = WebRtcFileTransferController(
            webrtc = transport,
            json = json,
            inboundApprovalProvider = acceptingApprovalProvider(),
            afterInboundLedgerRotation = { transferId ->
                if (transferId == firstTransferId && pauseFirst.compareAndSet(true, false)) {
                    paused.countDown()
                    check(release.await(2, TimeUnit.SECONDS))
                }
            },
        )
        val oldOwner = transport.currentTestSecureOwner()
        val executor = Executors.newSingleThreadExecutor()
        try {
            val oldPacket = executor.submit {
                controller.handleIncoming(
                    oldOwner,
                    inboundMetadata(firstTransferId, firstPayload, "old.txt"),
                )
            }
            assertTrue(paused.await(2, TimeUnit.SECONDS))
            val newOwner = transport.replaceTestSecureOwner()
            controller.handleIncoming(
                newOwner,
                inboundMetadata(secondTransferId, secondPayload, "new.txt"),
            )
            release.countDown()
            oldPacket.get(2, TimeUnit.SECONDS)

            assertFalse(
                transport.messages.any {
                    it.op == CrossNetworkFileTransferOp.metadataAck && it.transferId == firstTransferId
                },
                "an old callback must not reserve or acknowledge in the replacement ledger namespace",
            )
            assertTrue(
                transport.messages.any {
                    it.op == CrossNetworkFileTransferOp.metadataAck && it.transferId == secondTransferId
                },
            )
        } finally {
            release.countDown()
            executor.shutdownNow()
        }
    }

    @Test
    fun handleIncoming_rekeyBetweenEntryCheckAndCompletionBindFailsStaleWithoutCrash() = runTest {
        val paused = CountDownLatch(1)
        val release = CountDownLatch(1)
        val pauseComplete = AtomicBoolean(false)
        val transport = RecordingTransport()
        val transferId = UUID.randomUUID().toString()
        val replacementTransferId = UUID.randomUUID().toString()
        val payload = "old owner completion bind".encodeToByteArray()
        val controller = WebRtcFileTransferController(
            webrtc = transport,
            json = json,
            inboundApprovalProvider = acceptingApprovalProvider(),
            afterInboundLedgerRotation = { currentTransferId ->
                if (currentTransferId == transferId && pauseComplete.compareAndSet(true, false)) {
                    paused.countDown()
                    check(release.await(2, TimeUnit.SECONDS))
                }
            },
        )
        val oldOwner = transport.currentTestSecureOwner()
        controller.handleIncoming(oldOwner, inboundMetadata(transferId, payload, "old-complete.txt"))
        runCurrent()
        controller.handleIncoming(oldOwner, inboundChunk(transferId, payload))
        pauseComplete.set(true)

        val executor = Executors.newSingleThreadExecutor()
        try {
            val oldComplete = executor.submit {
                controller.handleIncoming(oldOwner, inboundComplete(transferId, payload))
            }
            assertTrue(paused.await(2, TimeUnit.SECONDS))
            val newOwner = transport.replaceTestSecureOwner()
            controller.handleIncoming(
                newOwner,
                inboundMetadata(replacementTransferId, "replacement".encodeToByteArray(), "new.txt"),
            )
            release.countDown()
            oldComplete.get(2, TimeUnit.SECONDS)

            assertFalse(
                transport.messages.any {
                    it.op == CrossNetworkFileTransferOp.completeAck && it.transferId == transferId
                },
                "an old callback must not bind, commit, or acknowledge after ledger rotation",
            )
        } finally {
            release.countDown()
            executor.shutdownNow()
        }
    }

    @Test
    fun handleIncoming_localCancelLosesAfterFinalizationClaimAndCannotOverwriteSuccess() = runTest {
        val finalizationClaimed = CountDownLatch(1)
        val allowFinalization = CountDownLatch(1)
        val transport = RecordingTransport()
        val receiver = WebRtcFileTransferController(
            webrtc = transport,
            json = json,
            inboundApprovalProvider = acceptingApprovalProvider(),
            backgroundDispatcher = StandardTestDispatcher(testScheduler),
            afterInboundFinalizationClaim = {
                finalizationClaimed.countDown()
                check(allowFinalization.await(2, TimeUnit.SECONDS))
            },
        )
        val transferId = UUID.randomUUID().toString()
        val payload = "finalize wins local cancel".encodeToByteArray()
        val received = async { receiver.receivedFiles.first() }
        runCurrent()
        receiver.handleIncoming(inboundMetadata(transferId, payload, "winner.txt"))
        runCurrent()
        receiver.handleIncoming(inboundChunk(transferId, payload))

        val executor = Executors.newSingleThreadExecutor()
        try {
            val completing = executor.submit {
                receiver.handleIncoming(inboundComplete(transferId, payload))
            }
            assertTrue(finalizationClaimed.await(2, TimeUnit.SECONDS))

            receiver.cancel(transferId)
            allowFinalization.countDown()
            completing.get()
        } finally {
            allowFinalization.countDown()
            executor.shutdownNow()
        }
        runCurrent()

        assertEquals(transferId, received.await().transferId)
        assertEquals("received complete", receiver.progress.value.lastStatus)
        assertFalse(transport.messages.any { it.op == CrossNetworkFileTransferOp.cancel })
        assertEquals(
            1,
            transport.messages.count { it.op == CrossNetworkFileTransferOp.completeAck },
        )
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

    private fun inboundMetadata(
        transferId: String,
        payload: ByteArray,
        fileName: String,
    ): ByteArray = encode(
        CrossNetworkFileTransferMessage(
            op = CrossNetworkFileTransferOp.metadata,
            transferId = transferId,
            fileName = fileName,
            fileSize = payload.size.toLong(),
            chunkSize = payload.size,
            totalChunks = 1,
            mimeType = "text/plain",
        ),
    )

    private fun inboundChunk(
        transferId: String,
        payload: ByteArray,
    ): ByteArray = encode(
        CrossNetworkFileTransferMessage(
            op = CrossNetworkFileTransferOp.chunk,
            transferId = transferId,
            chunkIndex = 0,
            chunkData = payload,
            chunkSha256 = sha256(payload),
            rawSize = payload.size,
        ),
    )

    private fun inboundComplete(
        transferId: String,
        payload: ByteArray,
    ): ByteArray = encode(
        CrossNetworkFileTransferMessage(
            op = CrossNetworkFileTransferOp.complete,
            transferId = transferId,
            receivedBytes = payload.size.toLong(),
            fileSha256 = sha256(payload),
        ),
    )

    private fun encode(message: CrossNetworkFileTransferMessage): ByteArray =
        json.encodeToString(CrossNetworkFileTransferMessage.serializer(), message).encodeToByteArray()

    private fun sha256(bytes: ByteArray): ByteArray =
        MessageDigest.getInstance("SHA-256").digest(bytes)

    private fun acceptingApprovalProvider(): InboundFileTransferApprovalProvider =
        InboundFileTransferApprovalProvider { request ->
            acceptDecision(request.fileName ?: "accepted-${request.transferId}")
        }

    private fun acceptDecision(displayName: String): InboundFileTransferDecision.Accept =
        InboundFileTransferDecision.Accept(
            downloadsDisplayName = displayName,
            overwriteExisting = false,
        )

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
        var acceptMessage: (CrossNetworkFileTransferMessage) -> Boolean = { true }

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
            val accepted = if (packetType == WebRtcAppSecureEnvelope.PacketType.FILE_TRANSFER) {
                acceptMessage(messages.last())
            } else {
                true
            }
            if (accepted) peer?.onData?.invoke(bytes)
            return accepted
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
