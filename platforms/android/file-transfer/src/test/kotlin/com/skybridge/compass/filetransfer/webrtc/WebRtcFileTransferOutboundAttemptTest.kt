package com.skybridge.compass.filetransfer.webrtc

import com.skybridge.compass.core.p2p.P2PHandshakePolicyOverride
import com.skybridge.compass.core.webrtc.AuthenticatedPeerMetadata
import com.skybridge.compass.core.webrtc.SkyBridgeWebRtcConnectionManager
import com.skybridge.compass.core.webrtc.WebRtcSession
import com.skybridge.compass.filetransfer.webrtc.resume.InMemoryTransferCheckpointStore
import com.skybridge.compass.filetransfer.webrtc.resume.TransferCheckpoint
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferMessage
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferOp
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferWireCodec
import com.skybridge.compass.shared.webrtc.WebRtcAppSecureEnvelope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Test
import java.io.ByteArrayInputStream
import java.io.IOException
import java.io.InputStream
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.CyclicBarrier
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

@OptIn(ExperimentalCoroutinesApi::class)
class WebRtcFileTransferOutboundAttemptTest {
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false }

    @Test
    fun blockedResumeReadLongerThanFiveSeconds_isClosedAndCannotSendAfterCancel() = runBlocking {
        val transferId = UUID.randomUUID().toString()
        val stream = BlockingInputStream()
        val transport = RecordingTransport()
        val controller = WebRtcFileTransferController(transport, json = json)
        val checkpoint = sendCheckpoint(transferId, fileSize = 4, chunkSize = 4, totalChunks = 1)

        val sending = async(Dispatchers.IO) {
            runCatching {
                controller.resumeSendFromCheckpoint(
                    checkpoint = checkpoint,
                    owner = TestWebRtcSecureOperationOwner,
                    mimeType = "application/octet-stream",
                    openStream = { stream },
                )
            }
        }

        assertTrue(stream.readEntered.await(2, TimeUnit.SECONDS), "resume must enter the blocking read")
        val recoveryId = requireNotNull(controller.progress.value.transferId)
        assertFalse(recoveryId == transferId)
        Thread.sleep(5_100)
        controller.cancel(recoveryId)
        val result = withTimeout(2_000) { sending.await() }

        assertTrue(result.isFailure, "the cancelled initiator must not return success")
        assertTrue(stream.closed.get(), "cancel must close the exact attempt's blocking stream")
        assertTrue(stream.blockedMillis() >= 5_000, "the regression must cover a read blocked for >5 seconds")
        assertEquals("cancelled", controller.progress.value.lastStatus)
        assertFalse(transport.messages.any { it.op == CrossNetworkFileTransferOp.complete })
        assertEquals(1, transport.messages.count { it.op == CrossNetworkFileTransferOp.cancel })
    }

    @Test
    fun synchronousCompleteAckWinsWhenCompletingTransportSendReturnsFalse() = runBlocking {
        val transferId = UUID.randomUUID().toString()
        val payload = "synchronous ack".encodeToByteArray()
        val transport = RecordingTransport()
        lateinit var controller: WebRtcFileTransferController
        transport.onMessage = { message ->
            if (message.op == CrossNetworkFileTransferOp.complete) {
                controller.handleIncoming(
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
        transport.acceptMessage = { message -> message.op != CrossNetworkFileTransferOp.complete }
        controller = WebRtcFileTransferController(transport, json = json)

        controller.sendBytesAsFile(transferId, "sync.bin", bytes = payload, chunkSize = 4)

        assertTrue(controller.isOperationAcknowledged(transferId))
        assertEquals("send complete acknowledged", controller.progress.value.lastStatus)
    }

    @Test
    fun synchronousPeerErrorWinsWhenCompletingTransportSendReturnsFalse() {
        val transferId = UUID.randomUUID().toString()
        val transport = RecordingTransport()
        lateinit var controller: WebRtcFileTransferController
        transport.onMessage = { message ->
            if (message.op == CrossNetworkFileTransferOp.complete) {
                controller.handleIncoming(
                    encode(
                        CrossNetworkFileTransferMessage(
                            op = CrossNetworkFileTransferOp.error,
                            transferId = transferId,
                            message = "completion rejected",
                        ),
                    ),
                )
            }
        }
        transport.acceptMessage = { message -> message.op != CrossNetworkFileTransferOp.complete }
        controller = WebRtcFileTransferController(transport, json = json)

        val failure = assertThrows(IllegalStateException::class.java) {
            runBlocking {
                controller.sendBytesAsFile(
                    transferId,
                    "sync-error.bin",
                    bytes = "peer error".encodeToByteArray(),
                    chunkSize = 4,
                )
            }
        }
        assertEquals("OutboundAttemptTerminatedException", failure.javaClass.simpleName)
        assertTrue(failure.message?.contains("became FAILED") == true)
        assertEquals("send failed: peer error: completion rejected", controller.progress.value.lastStatus)
    }

    @Test
    fun synchronousCancelWinsWhenChunkTransportSendReturnsFalseAndPreventsCompleteDispatch() {
        val transferId = UUID.randomUUID().toString()
        val transport = RecordingTransport()
        lateinit var controller: WebRtcFileTransferController
        val cancelled = AtomicBoolean(false)
        transport.onMessage = { message ->
            if (message.op == CrossNetworkFileTransferOp.chunk && cancelled.compareAndSet(false, true)) {
                controller.cancel(transferId)
            }
        }
        transport.acceptMessage = { message -> message.op != CrossNetworkFileTransferOp.chunk }
        controller = WebRtcFileTransferController(transport, json = json)

        val failure = assertThrows(IllegalStateException::class.java) {
            runBlocking {
                controller.sendBytesAsFile(
                    transferId,
                    "sync-cancel.bin",
                    bytes = "cancel during send".encodeToByteArray(),
                    chunkSize = 4,
                )
            }
        }

        assertEquals("OutboundAttemptTerminatedException", failure.javaClass.simpleName)
        assertTrue(failure.message?.contains("became CANCELLED") == true)
        assertEquals("cancelled", controller.progress.value.lastStatus)
        assertFalse(transport.messages.any { it.op == CrossNetworkFileTransferOp.complete })
        assertEquals(1, transport.messages.count { it.op == CrossNetworkFileTransferOp.cancel })
    }

    @Test
    fun invalidCompletionAckWinsFailureAndLaterValidAckCannotReverseIt() = runBlocking {
        val transferId = UUID.randomUUID().toString()
        val payload = "ack evidence".encodeToByteArray()
        val controller = WebRtcFileTransferController(RecordingTransport(), json = json)
        controller.sendBytesAsFile(transferId, "ack.bin", bytes = payload, chunkSize = 4)

        controller.handleIncoming(
            encode(
                CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.completeAck,
                    transferId = transferId,
                    receivedBytes = payload.size.toLong(),
                    fileSha256 = sha256(payload).also { it[0] = (it[0].toInt() xor 1).toByte() },
                ),
            ),
        )
        controller.handleIncoming(
            encode(
                CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.completeAck,
                    transferId = transferId,
                    receivedBytes = payload.size.toLong(),
                    fileSha256 = sha256(payload),
                ),
            ),
        )

        assertFalse(controller.isOperationAcknowledged(transferId))
        assertEquals(
            "send failed: invalid complete acknowledgement evidence",
            controller.progress.value.lastStatus,
        )

        controller.handleIncoming(
            encode(
                CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.error,
                    transferId = transferId,
                    message = "late peer error",
                ),
            ),
        )
        assertEquals(
            "send failed: invalid complete acknowledgement evidence",
            controller.progress.value.lastStatus,
        )
    }

    @Test
    fun lostCompletionAcknowledgementRetriesExactPayloadOnceAndCanStillAcknowledge() = runTest {
        val transferId = UUID.randomUUID().toString()
        val payload = "completion retry payload".encodeToByteArray()
        val transport = RecordingTransport()
        val retryGate = CompletableDeferred<Unit>()
        lateinit var controller: WebRtcFileTransferController
        var completeCount = 0
        transport.onMessage = { message ->
            if (message.op == CrossNetworkFileTransferOp.complete) {
                completeCount += 1
                if (completeCount == 2) {
                    controller.handleIncoming(
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
        }
        controller = WebRtcFileTransferController(
            transport,
            json = json,
            backgroundDispatcher = StandardTestDispatcher(testScheduler),
            waitBeforeCompletionRetry = { retryGate.await() },
        )

        controller.sendBytesAsFile(transferId, "retry.bin", bytes = payload, chunkSize = 4)
        runCurrent()
        val beforeRetry = transport.rawMessages
            .filter { it.first.op == CrossNetworkFileTransferOp.complete }
        assertEquals(1, beforeRetry.size, "first completion attempt must precede its retry timer")
        val firstComplete = beforeRetry.first().second
        retryGate.complete(Unit)
        runCurrent()

        val completePayloads = transport.rawMessages
            .filter { it.first.op == CrossNetworkFileTransferOp.complete }
            .map { it.second }
        assertEquals(2, completePayloads.size)
        assertArrayEquals(firstComplete, completePayloads[1])
        assertTrue(controller.isOperationAcknowledged(transferId))
        assertEquals("send complete acknowledged", controller.progress.value.lastStatus)

        runCurrent()
        assertEquals(
            2,
            transport.messages.count { it.op == CrossNetworkFileTransferOp.complete },
            "terminal acknowledgement must cancel the retry job",
        )
    }

    @Test
    fun nackConsumesSecondCompleteAttemptAndTimerCannotCreateThirdAttemptOrFailure() = runTest {
        val transferId = UUID.randomUUID().toString()
        val payload = "nack consumes bounded completion retry".encodeToByteArray()
        val transport = RecordingTransport()
        val retryGate = CompletableDeferred<Unit>()
        val controller = WebRtcFileTransferController(
            transport,
            json = json,
            backgroundDispatcher = StandardTestDispatcher(testScheduler),
            waitBeforeCompletionRetry = { retryGate.await() },
        )

        controller.sendBytesAsFile(transferId, "nack.bin", bytes = payload, chunkSize = 8)
        runCurrent()
        val firstComplete = transport.rawMessages.single {
            it.first.op == CrossNetworkFileTransferOp.complete
        }.second

        controller.handleIncoming(
            encode(
                CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.chunkAck,
                    transferId = transferId,
                    missingChunks = intArrayOf(0),
                ),
            ),
        )
        runCurrent()
        val afterNack = transport.rawMessages.filter {
            it.first.op == CrossNetworkFileTransferOp.complete
        }
        assertEquals(2, afterNack.size)
        assertArrayEquals(firstComplete, afterNack[1].second)
        assertTrue(controller.isCurrentOperation(transferId))
        assertFalse(controller.isOperationAcknowledged(transferId))

        retryGate.complete(Unit)
        runCurrent()
        assertEquals(
            2,
            transport.messages.count { it.op == CrossNetworkFileTransferOp.complete },
            "the timer must exit when a peer NACK already consumed attempt two",
        )
        assertTrue(controller.isCurrentOperation(transferId))
        assertFalse(controller.progress.value.lastStatus?.startsWith("send failed") == true)

        controller.handleIncoming(
            encode(
                CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.completeAck,
                    transferId = transferId,
                    receivedBytes = payload.size.toLong(),
                    fileSha256 = sha256(payload),
                ),
            ),
        )
        assertTrue(controller.isOperationAcknowledged(transferId))
        assertEquals("send complete acknowledged", controller.progress.value.lastStatus)
    }

    @Test
    fun concurrentNackAndTimerReserveExactlyOneSecondCompletionAttempt() = runTest {
        val transferId = UUID.randomUUID().toString()
        val payload = "concurrent retry contenders".encodeToByteArray()
        val transport = RecordingTransport()
        val checkpointStore = InMemoryTransferCheckpointStore()
        val retryGate = CompletableDeferred<Unit>()
        val reservationBarrier = CyclicBarrier(2)
        val completeCount = AtomicInteger()
        val secondComplete = CountDownLatch(1)
        transport.onMessage = { message ->
            if (
                message.op == CrossNetworkFileTransferOp.complete &&
                completeCount.incrementAndGet() == 2
            ) {
                secondComplete.countDown()
            }
        }
        val controller = WebRtcFileTransferController(
            transport,
            json = json,
            checkpointStore = checkpointStore,
            backgroundDispatcher = Dispatchers.IO,
            waitBeforeCompletionRetry = { retryGate.await() },
            beforeCompletionRetryReservation = {
                reservationBarrier.await(2, TimeUnit.SECONDS)
            },
        )

        controller.sendBytesAsFile(transferId, "concurrent.bin", bytes = payload, chunkSize = 4)
        assertEquals(1, completeCount.get())
        val firstComplete = transport.rawMessages.single {
            it.first.op == CrossNetworkFileTransferOp.complete
        }.second

        val executor = Executors.newSingleThreadExecutor()
        try {
            val nack = executor.submit {
                controller.handleIncoming(
                    encode(
                        CrossNetworkFileTransferMessage(
                            op = CrossNetworkFileTransferOp.chunkAck,
                            transferId = transferId,
                            missingChunks = intArrayOf(0),
                        ),
                    ),
                )
            }
            retryGate.complete(Unit)
            assertTrue(secondComplete.await(2, TimeUnit.SECONDS))
            nack.get(2, TimeUnit.SECONDS)

            assertEquals(2, completeCount.get(), "only one contender may reserve attempt two")
            val completePayloads = transport.rawMessages
                .filter { it.first.op == CrossNetworkFileTransferOp.complete }
                .map { it.second }
            assertEquals(2, completePayloads.size)
            assertArrayEquals(firstComplete, completePayloads[1])
            val retained = checkpointStore.load(transferId)
            assertTrue(retained?.completionRequestSent == true)
            assertTrue(controller.isCurrentOperation(transferId))
            assertFalse(controller.progress.value.lastStatus?.startsWith("send failed") == true)

            controller.handleIncoming(
                encode(
                    CrossNetworkFileTransferMessage(
                        op = CrossNetworkFileTransferOp.completeAck,
                        transferId = transferId,
                        receivedBytes = payload.size.toLong(),
                        fileSha256 = sha256(payload),
                    ),
                ),
            )
            assertTrue(controller.isOperationAcknowledged(transferId))
        } finally {
            executor.shutdownNow()
        }
    }

    @Test
    fun terminalPeerErrorOrStaleOwnerPreventsCompletionRetry() = runTest {
        suspend fun assertNoRetry(staleOwner: Boolean) {
            val transferId = UUID.randomUUID().toString()
            val transport = RecordingTransport()
            val retryGate = CompletableDeferred<Unit>()
            val controller = WebRtcFileTransferController(
                transport,
                json = json,
                backgroundDispatcher = StandardTestDispatcher(testScheduler),
                waitBeforeCompletionRetry = { retryGate.await() },
            )
            controller.sendBytesAsFile(
                transferId,
                "terminal.bin",
                bytes = "terminal".encodeToByteArray(),
                chunkSize = 4,
            )
            if (staleOwner) {
                transport.replaceTestSecureOwner()
            } else {
                controller.handleIncoming(
                    encode(
                        CrossNetworkFileTransferMessage(
                            op = CrossNetworkFileTransferOp.error,
                            transferId = transferId,
                            message = "terminal rejection",
                        ),
                    ),
                )
            }
            runCurrent()
            assertFalse(controller.isCurrentOperation(transferId))
            retryGate.complete(Unit)
            runCurrent()
            assertEquals(
                1,
                transport.messages.count { it.op == CrossNetworkFileTransferOp.complete },
                "terminal winner must cancel retry (staleOwner=$staleOwner)",
            )
        }

        assertNoRetry(staleOwner = false)
        assertNoRetry(staleOwner = true)
    }

    @Test
    fun ambiguousCompletionCheckpointCannotResumeUnderFreshIdentifier() {
        val checkpoint = sendCheckpoint(
            transferId = UUID.randomUUID().toString(),
            fileSize = 8,
            chunkSize = 4,
            totalChunks = 2,
        ).copy(completionRequestSent = true)
        val controller = WebRtcFileTransferController(RecordingTransport(), json = json)

        assertThrows(CompletionOutcomeUnknownException::class.java) {
            runBlocking {
                controller.resumeSendFromCheckpoint(
                    checkpoint = checkpoint,
                    owner = TestWebRtcSecureOperationOwner,
                    mimeType = "application/octet-stream",
                    openStream = { ByteArrayInputStream(ByteArray(8)) },
                )
            }
        }
    }

    @Test
    fun lateErrorAfterAcknowledgementCannotOverwriteTerminalSuccess() = runBlocking {
        val transferId = UUID.randomUUID().toString()
        val payload = "terminal success".encodeToByteArray()
        val controller = WebRtcFileTransferController(RecordingTransport(), json = json)
        controller.sendBytesAsFile(transferId, "acked.bin", bytes = payload, chunkSize = 4)
        controller.handleIncoming(
            encode(
                CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.completeAck,
                    transferId = transferId,
                    receivedBytes = payload.size.toLong(),
                    fileSha256 = sha256(payload),
                ),
            ),
        )
        controller.handleIncoming(
            encode(
                CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.error,
                    transferId = transferId,
                    message = "late error",
                ),
            ),
        )

        assertTrue(controller.isOperationAcknowledged(transferId))
        assertEquals("send complete acknowledged", controller.progress.value.lastStatus)
    }

    @Test
    fun terminalFailureLinearizesAfterBlockedNonterminalProgressCommit() = runBlocking {
        val progressEntered = CountDownLatch(1)
        val releaseProgress = CountDownLatch(1)
        val transferId = UUID.randomUUID().toString()
        val transport = RecordingTransport()
        val controller = WebRtcFileTransferController(
            transport,
            json = json,
            beforeOutboundProgressCommit = { status ->
                if (status == "sent complete") {
                    progressEntered.countDown()
                    check(releaseProgress.await(2, TimeUnit.SECONDS))
                }
            },
        )
        val sendResult = async(Dispatchers.IO) {
            runCatching {
                controller.sendBytesAsFile(
                    transferId,
                    "barrier.bin",
                    bytes = "barrier payload".encodeToByteArray(),
                    chunkSize = 4,
                )
            }
        }
        assertTrue(progressEntered.await(2, TimeUnit.SECONDS))

        val failureResult = AtomicReference<Result<Unit>?>(null)
        val failureDone = CountDownLatch(1)
        val failureThread = Thread {
            failureResult.set(
                runCatching {
                    controller.handleIncoming(
                        encode(
                            CrossNetworkFileTransferMessage(
                                op = CrossNetworkFileTransferOp.error,
                                transferId = transferId,
                                message = "barrier terminal",
                            ),
                        ),
                    )
                },
            )
            failureDone.countDown()
        }
        failureThread.start()
        assertFalse(
            failureDone.await(100, TimeUnit.MILLISECONDS),
            "terminal transition must wait for the in-lock nonterminal progress commit",
        )
        releaseProgress.countDown()
        assertTrue(failureDone.await(2, TimeUnit.SECONDS))
        assertTrue(failureResult.get()?.isSuccess == true)
        withTimeout(2_000) { sendResult.await() }

        assertEquals("send failed: peer error: barrier terminal", controller.progress.value.lastStatus)
    }

    @Test
    fun resumeRejectsShortAndLongSourcesBeforeComplete() {
        listOf(
            "short" to "1234".encodeToByteArray(),
            "long" to "123456789012".encodeToByteArray(),
        ).forEach { (label, source) ->
            val transferId = UUID.randomUUID().toString()
            val transport = RecordingTransport()
            val controller = WebRtcFileTransferController(transport, json = json)
            val checkpoint = sendCheckpoint(transferId, fileSize = 8, chunkSize = 4, totalChunks = 2)

            assertThrows(IllegalStateException::class.java) {
                runBlocking {
                    controller.resumeSendFromCheckpoint(
                        checkpoint = checkpoint,
                        owner = TestWebRtcSecureOperationOwner,
                        mimeType = "application/octet-stream",
                        openStream = { ByteArrayInputStream(source) },
                    )
                }
            }

            assertFalse(transport.messages.any { it.op == CrossNetworkFileTransferOp.complete }, label)
            assertEquals(1, transport.messages.count { it.op == CrossNetworkFileTransferOp.error }, label)
            assertTrue(controller.progress.value.lastStatus?.contains("file stream length mismatch") == true)
        }
    }

    @Test
    fun resumeRejectsInexactTotalChunksAndAckSet() {
        val malformed = listOf(
            sendCheckpoint(UUID.randomUUID().toString(), 8, 4, 3),
            sendCheckpoint(UUID.randomUUID().toString(), 8, 4, 2).copy(ackedChunks = intArrayOf(1, 0)),
            sendCheckpoint(UUID.randomUUID().toString(), 8, 4, 2).copy(ackedChunks = intArrayOf(0, 2)),
        )

        malformed.forEach { checkpoint ->
            val transport = RecordingTransport()
            val controller = WebRtcFileTransferController(transport, json = json)
            assertThrows(IllegalArgumentException::class.java) {
                runBlocking {
                    controller.resumeSendFromCheckpoint(
                        checkpoint = checkpoint,
                        owner = TestWebRtcSecureOperationOwner,
                        mimeType = "application/octet-stream",
                        openStream = { ByteArrayInputStream(ByteArray(8)) },
                    )
                }
            }
            assertFalse(transport.messages.any { it.op == CrossNetworkFileTransferOp.complete })
        }
    }

    @Test
    fun transferIdCannotBeReusedAfterTerminalAckInSameSecureSession() = runBlocking {
        val transferId = UUID.randomUUID().toString()
        val payload = "single use id".encodeToByteArray()
        val transport = RecordingTransport()
        val controller = WebRtcFileTransferController(transport, json = json)
        controller.sendBytesAsFile(transferId, "once.bin", bytes = payload, chunkSize = 4)
        controller.handleIncoming(
            encode(
                CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.completeAck,
                    transferId = transferId,
                    receivedBytes = payload.size.toLong(),
                    fileSha256 = sha256(payload),
                ),
            ),
        )
        val metadataBeforeReuse = transport.messages.count { it.op == CrossNetworkFileTransferOp.metadata }

        val failure = runCatching {
            controller.sendBytesAsFile(transferId, "twice.bin", bytes = payload, chunkSize = 4)
        }.exceptionOrNull()

        assertTrue(failure is IllegalStateException)
        assertTrue(failure?.message?.contains("single-use") == true)
        assertEquals(
            metadataBeforeReuse,
            transport.messages.count { it.op == CrossNetworkFileTransferOp.metadata },
        )
        assertTrue(controller.isOperationAcknowledged(transferId))
    }

    private fun sendCheckpoint(
        transferId: String,
        fileSize: Long,
        chunkSize: Int,
        totalChunks: Int,
    ): TransferCheckpoint = TransferCheckpoint.newSend(
        transferId = transferId,
        sourceUri = null,
        fileName = "resume.bin",
        mimeType = "application/octet-stream",
        fileSize = fileSize,
        chunkSize = chunkSize,
        totalChunks = totalChunks,
    )

    private fun encode(message: CrossNetworkFileTransferMessage): ByteArray =
        CrossNetworkFileTransferWireCodec.encode(message)

    private fun sha256(bytes: ByteArray): ByteArray =
        MessageDigest.getInstance("SHA-256").digest(bytes)

    private inner class RecordingTransport : TestCrossNetworkWebRtcTransportAdapter() {
        override val state: StateFlow<SkyBridgeWebRtcConnectionManager.State> =
            MutableStateFlow(SkyBridgeWebRtcConnectionManager.State.Established("test-session"))
        override val signalingStatus: StateFlow<SkyBridgeWebRtcConnectionManager.SignalingStatus> =
            MutableStateFlow(SkyBridgeWebRtcConnectionManager.SignalingStatus())
        override val dataChannelConfigStatus: StateFlow<WebRtcSession.DataChannelConfigStatus> =
            MutableStateFlow(WebRtcSession.DataChannelConfigStatus.Unknown)
        override val authenticatedPeerMetadata: StateFlow<AuthenticatedPeerMetadata?> = MutableStateFlow(null)
        override var onData: ((ByteArray) -> Unit)? = null
        override var onPacketData: ((ByteArray, WebRtcAppSecureEnvelope.PacketType) -> Unit)? = null
        val messages = mutableListOf<CrossNetworkFileTransferMessage>()
        val rawMessages = mutableListOf<Pair<CrossNetworkFileTransferMessage, ByteArray>>()
        var onMessage: ((CrossNetworkFileTransferMessage) -> Unit)? = null
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
            if (packetType == WebRtcAppSecureEnvelope.PacketType.FILE_TRANSFER) {
                val message = CrossNetworkFileTransferWireCodec.decode(bytes)
                messages += message
                rawMessages += message to bytes.copyOf()
                onMessage?.invoke(message)
                return acceptMessage(message)
            }
            return true
        }

        override fun disconnect() = Unit
        override fun release() = Unit
    }

    private class BlockingInputStream : InputStream() {
        val readEntered = CountDownLatch(1)
        val closed = AtomicBoolean(false)
        private val released = CountDownLatch(1)
        private val readStartedNanos = java.util.concurrent.atomic.AtomicLong(0L)
        private val closedNanos = java.util.concurrent.atomic.AtomicLong(0L)

        override fun read(): Int {
            readEntered.countDown()
            readStartedNanos.compareAndSet(0L, System.nanoTime())
            released.await()
            throw IOException("stream closed while read was blocked")
        }

        override fun read(buffer: ByteArray, offset: Int, length: Int): Int = read()

        override fun close() {
            if (closed.compareAndSet(false, true)) {
                closedNanos.set(System.nanoTime())
                released.countDown()
            }
        }

        fun blockedMillis(): Long = TimeUnit.NANOSECONDS.toMillis(
            closedNanos.get() - readStartedNanos.get(),
        )
    }
}
