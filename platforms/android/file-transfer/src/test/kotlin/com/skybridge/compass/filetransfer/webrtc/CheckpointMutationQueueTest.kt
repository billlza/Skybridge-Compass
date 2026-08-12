package com.skybridge.compass.filetransfer.webrtc

import com.skybridge.compass.filetransfer.webrtc.property.PropertyRecordingTransport
import com.skybridge.compass.filetransfer.webrtc.property.acceptingApprovalProvider
import com.skybridge.compass.filetransfer.webrtc.resume.TransferCheckpoint
import com.skybridge.compass.filetransfer.webrtc.resume.TransferCheckpointStore
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferMessage
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferOp
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.yield
import kotlinx.serialization.json.Json
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertSame
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.io.IOException
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger

class CheckpointMutationQueueTest {
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false }

    @Test
    fun sameTransferSaveAndChunkUpdatePreserveSourceOrder() = runBlocking {
        val store = OrderedSaveStore()
        val controller = controller(store)
        val transferId = UUID.randomUUID().toString()

        controller.handleIncoming(metadata(transferId))
        withTimeout(TEST_TIMEOUT_MS) { store.initialSaveStarted.await() }

        // handleIncoming enqueues synchronously, so this update has been accepted before release.
        controller.handleIncoming(chunk(transferId))
        store.releaseInitialSave.complete(Unit)
        withTimeout(TEST_TIMEOUT_MS) { store.updateSaveCompleted.await() }

        assertEquals(
            listOf(
                "metadata-load",
                "initial-save-start",
                "initial-save-end",
                "update-load",
                "update-save",
            ),
            store.events,
        )
    }

    @Test
    fun differentTransfersPersistInParallel() = runBlocking {
        val store = ParallelSaveStore()
        val controller = controller(store)
        val firstTransferId = UUID.randomUUID().toString()
        val secondTransferId = UUID.randomUUID().toString()

        controller.handleIncoming(metadata(firstTransferId))
        withTimeout(TEST_TIMEOUT_MS) { store.firstSaveStarted.await() }
        controller.handleIncoming(metadata(secondTransferId))

        withTimeout(TEST_TIMEOUT_MS) { store.bothSavesStarted.await() }
        assertEquals(setOf(firstTransferId, secondTransferId), store.startedTransferIds)

        store.releaseSaves.complete(Unit)
        withTimeout(TEST_TIMEOUT_MS) { store.bothSavesCompleted.await() }
    }

    @Test
    fun saveFailurePropagatesTypedContextAndDoesNotStrandFollowingDelete() = runBlocking {
        val saveFailure = IOException("synthetic checkpoint save failure")
        val store = SaveFailingStore(saveFailure)
        val transport = PropertyRecordingTransport()
        val controller = controller(store, transport)
        val transferId = UUID.randomUUID().toString()

        val failure = runCatching {
            controller.sendBytesAsFile(
                transferId = transferId,
                fileName = "failure.bin",
                bytes = byteArrayOf(1),
                chunkSize = 1,
            )
        }.exceptionOrNull()

        assertTrue(failure is CheckpointMutationException)
        failure as CheckpointMutationException
        assertEquals(transferId, failure.transferId)
        assertEquals(CheckpointMutation.SAVE, failure.mutation)
        assertSame(saveFailure, failure.cause)
        assertTrue(
            transport.messages.isEmpty(),
            "metadata must not be emitted when the durable initial checkpoint failed",
        )

        withTimeout(TEST_TIMEOUT_MS) { controller.deleteCheckpoint(transferId) }
        assertEquals(listOf(transferId), store.deletedTransferIds)
    }

    @Test
    fun deleteFailurePropagatesTypedContextAndOriginalCause() = runBlocking {
        val deleteFailure = IOException("synthetic checkpoint delete failure")
        val controller = controller(DeleteFailingStore(deleteFailure))
        val transferId = UUID.randomUUID().toString()

        val failure = runCatching {
            controller.deleteCheckpoint(transferId)
        }.exceptionOrNull()

        assertTrue(failure is CheckpointMutationException)
        failure as CheckpointMutationException
        assertEquals(transferId, failure.transferId)
        assertEquals(CheckpointMutation.DELETE, failure.mutation)
        assertSame(deleteFailure, failure.cause)
    }

    @Test
    fun cancellingWaiterDoesNotCancelAcceptedDelete() = runBlocking {
        val store = BlockingDeleteStore()
        val controller = controller(store)
        val transferId = UUID.randomUUID().toString()
        val waiterEntered = CompletableDeferred<Unit>()

        val waiter = launch {
            waiterEntered.complete(Unit)
            controller.deleteCheckpoint(transferId)
        }
        waiterEntered.await()
        withTimeout(TEST_TIMEOUT_MS) { store.deleteStarted.await() }

        waiter.cancelAndJoin()
        assertFalse(store.deleteCompleted.isCompleted)

        store.releaseDelete.complete(Unit)
        withTimeout(TEST_TIMEOUT_MS) { store.deleteCompleted.await() }
        assertEquals(listOf(transferId), store.deletedTransferIds)
    }

    @Test
    fun lateCheckpointDeleteFailureCannotOverwriteAcknowledgedTerminalProgress() = runBlocking {
        val store = DelayedFailingDeleteStore()
        val transport = PropertyRecordingTransport()
        val controller = controller(store, transport)
        val transferId = UUID.randomUUID().toString()
        val payload = byteArrayOf(0x2A)

        controller.sendBytesAsFile(
            transferId = transferId,
            fileName = "late-delete.bin",
            bytes = payload,
            chunkSize = 1,
        )
        controller.handleIncoming(
            encode(
                CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.completeAck,
                    transferId = transferId,
                    receivedBytes = 1,
                    fileSha256 = java.security.MessageDigest.getInstance("SHA-256").digest(payload),
                ),
            ),
        )
        assertEquals("send complete acknowledged", controller.progress.value.lastStatus)
        withTimeout(TEST_TIMEOUT_MS) { store.deleteStarted.await() }
        store.releaseDelete.complete(Unit)
        withTimeout(TEST_TIMEOUT_MS) {
            while (!store.failureThrown.isCompleted) yield()
        }
        repeat(5) { yield() }

        assertTrue(controller.isOperationAcknowledged(transferId))
        assertEquals("send complete acknowledged", controller.progress.value.lastStatus)
    }

    @Test
    fun oldOwnerLateCheckpointFailureCannotFailReplacementAttemptWithSameTransferId() = runBlocking {
        val store = BlockingSecondSaveFailureStore()
        val transport = PropertyRecordingTransport()
        val controller = controller(store, transport)
        val transferId = UUID.randomUUID().toString()

        controller.sendBytesAsFile(
            transferId = transferId,
            fileName = "owner-a.bin",
            bytes = byteArrayOf(0x2A),
            chunkSize = 1,
        )
        val ownerA = transport.currentTestSecureOwner()
        controller.handleIncoming(
            ownerA,
            encode(
                CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.chunkAck,
                    transferId = transferId,
                    chunkIndex = 0,
                ),
            ),
        )
        withTimeout(TEST_TIMEOUT_MS) { store.secondSaveStarted.await() }

        val ownerB = transport.replaceTestSecureOwner()
        val localDeletion = async(start = CoroutineStart.UNDISPATCHED) {
            controller.deleteCheckpoint(transferId)
        }
        val sendsBeforeB = transport.messages.size
        val sendB = async(start = CoroutineStart.UNDISPATCHED) {
            controller.sendBytesAsFile(
                transferId = transferId,
                fileName = "owner-b.bin",
                bytes = byteArrayOf(0x33),
                chunkSize = 1,
            )
        }
        withTimeout(TEST_TIMEOUT_MS) {
            while (!controller.isCurrentOperation(transferId)) yield()
        }
        val progressBeforeLateFailure = controller.progress.value
        val messagesBeforeLateFailure = transport.messages.size

        store.releaseSecondSave.complete(Unit)
        val typed = withTimeout(TEST_TIMEOUT_MS) {
            controller.checkpointMutationFailure.first { it?.owner === ownerA }
        }
        withTimeout(TEST_TIMEOUT_MS) { store.thirdSaveStarted.await() }

        assertSame(ownerA, typed?.owner)
        assertTrue(typed?.attemptGeneration != null)
        assertFalse(ownerA === ownerB)
        assertTrue(controller.isCurrentOperation(transferId))
        assertEquals(progressBeforeLateFailure, controller.progress.value)
        assertEquals(messagesBeforeLateFailure, transport.messages.size)

        store.releaseThirdSave.complete(Unit)
        withTimeout(TEST_TIMEOUT_MS) { sendB.await() }
        withTimeout(TEST_TIMEOUT_MS) { localDeletion.await() }
        assertEquals("sent complete", controller.progress.value.lastStatus)
        assertTrue(transport.messages.drop(sendsBeforeB).all { it.transferId == transferId })
        assertFalse(controller.progress.value.lastStatus?.contains("synthetic owner A") == true)
    }

    @Test
    fun oldOwnerSuccessfulDeleteCallbackCannotRemoveReplacementCheckpointBinding() = runBlocking {
        val store = BlockingFirstDeleteStore()
        val transport = PropertyRecordingTransport()
        val controller = controller(store, transport)
        val transferId = UUID.randomUUID().toString()
        val payload = byteArrayOf(0x2A)

        controller.sendBytesAsFile(transferId, "owner-a.bin", bytes = payload, chunkSize = 1)
        val ownerA = transport.currentTestSecureOwner()
        controller.handleIncoming(
            ownerA,
            encode(
                CrossNetworkFileTransferMessage(
                    op = CrossNetworkFileTransferOp.completeAck,
                    transferId = transferId,
                    receivedBytes = 1,
                    fileSha256 = java.security.MessageDigest.getInstance("SHA-256").digest(payload),
                ),
            ),
        )
        withTimeout(TEST_TIMEOUT_MS) { store.firstDeleteStarted.await() }

        transport.replaceTestSecureOwner()
        val localDeletion = async(start = CoroutineStart.UNDISPATCHED) {
            controller.deleteCheckpoint(transferId)
        }
        val sendB = async(start = CoroutineStart.UNDISPATCHED) {
            controller.sendBytesAsFile(
                transferId,
                "owner-b.bin",
                bytes = byteArrayOf(0x33),
                chunkSize = 1,
            )
        }
        withTimeout(TEST_TIMEOUT_MS) {
            while (!controller.isCurrentOperation(transferId)) yield()
        }

        store.releaseFirstDelete.complete(Unit)
        withTimeout(TEST_TIMEOUT_MS) { localDeletion.await() }
        withTimeout(TEST_TIMEOUT_MS) { sendB.await() }

        assertTrue(controller.isCurrentOperation(transferId))
        assertEquals("sent complete", controller.progress.value.lastStatus)
        assertEquals(transferId, store.load(transferId)?.transferId)
    }

    private fun controller(
        store: TransferCheckpointStore,
        transport: PropertyRecordingTransport = PropertyRecordingTransport(),
    ): WebRtcFileTransferController = WebRtcFileTransferController(
        webrtc = transport,
        json = json,
        checkpointStore = store,
        inboundApprovalProvider = acceptingApprovalProvider(),
    )

    private fun metadata(transferId: String): ByteArray = encode(
        CrossNetworkFileTransferMessage(
            op = CrossNetworkFileTransferOp.metadata,
            transferId = transferId,
            fileName = "queue.bin",
            fileSize = 1,
            chunkSize = 1,
            totalChunks = 1,
            mimeType = "application/octet-stream",
        ),
    )

    private fun chunk(transferId: String): ByteArray {
        val data = byteArrayOf(0x2A)
        return encode(
            CrossNetworkFileTransferMessage(
                op = CrossNetworkFileTransferOp.chunk,
                transferId = transferId,
                chunkIndex = 0,
                chunkData = data,
                chunkSha256 = java.security.MessageDigest.getInstance("SHA-256").digest(data),
                rawSize = data.size,
            ),
        )
    }

    private fun encode(message: CrossNetworkFileTransferMessage): ByteArray =
        json.encodeToString(CrossNetworkFileTransferMessage.serializer(), message).encodeToByteArray()

    private abstract class EmptyCheckpointStore : TransferCheckpointStore {
        override suspend fun load(transferId: String): TransferCheckpoint? = null
        override suspend fun save(checkpoint: TransferCheckpoint) = Unit
        override suspend fun delete(transferId: String) = Unit
        override suspend fun list(): List<TransferCheckpoint> = emptyList()
    }

    private class OrderedSaveStore : EmptyCheckpointStore() {
        private val checkpoints = ConcurrentHashMap<String, TransferCheckpoint>()
        private val saveCount = AtomicInteger()
        private val loadCount = AtomicInteger()
        val events = CopyOnWriteArrayList<String>()
        val initialSaveStarted = CompletableDeferred<Unit>()
        val releaseInitialSave = CompletableDeferred<Unit>()
        val updateSaveCompleted = CompletableDeferred<Unit>()

        override suspend fun load(transferId: String): TransferCheckpoint? {
            events += if (loadCount.incrementAndGet() == 1) "metadata-load" else "update-load"
            return checkpoints[transferId]
        }

        override suspend fun save(checkpoint: TransferCheckpoint) {
            if (saveCount.incrementAndGet() == 1) {
                events += "initial-save-start"
                initialSaveStarted.complete(Unit)
                releaseInitialSave.await()
                checkpoints[checkpoint.transferId] = checkpoint
                events += "initial-save-end"
            } else {
                checkpoints[checkpoint.transferId] = checkpoint
                events += "update-save"
                updateSaveCompleted.complete(Unit)
            }
        }
    }

    private class ParallelSaveStore : EmptyCheckpointStore() {
        val startedTransferIds = ConcurrentHashMap.newKeySet<String>()
        val firstSaveStarted = CompletableDeferred<Unit>()
        val bothSavesStarted = CompletableDeferred<Unit>()
        val releaseSaves = CompletableDeferred<Unit>()
        val bothSavesCompleted = CompletableDeferred<Unit>()
        private val completedCount = AtomicInteger()

        override suspend fun save(checkpoint: TransferCheckpoint) {
            startedTransferIds += checkpoint.transferId
            firstSaveStarted.complete(Unit)
            if (startedTransferIds.size == 2) bothSavesStarted.complete(Unit)
            releaseSaves.await()
            if (completedCount.incrementAndGet() == 2) bothSavesCompleted.complete(Unit)
        }
    }

    private class SaveFailingStore(
        private val failure: IOException,
    ) : EmptyCheckpointStore() {
        val deletedTransferIds = CopyOnWriteArrayList<String>()

        override suspend fun save(checkpoint: TransferCheckpoint) {
            throw failure
        }

        override suspend fun delete(transferId: String) {
            deletedTransferIds += transferId
        }
    }

    private class DeleteFailingStore(
        private val failure: IOException,
    ) : EmptyCheckpointStore() {
        override suspend fun delete(transferId: String) {
            throw failure
        }
    }

    private class BlockingDeleteStore : EmptyCheckpointStore() {
        val deleteStarted = CompletableDeferred<Unit>()
        val releaseDelete = CompletableDeferred<Unit>()
        val deleteCompleted = CompletableDeferred<Unit>()
        val deletedTransferIds = CopyOnWriteArrayList<String>()

        override suspend fun delete(transferId: String) {
            deleteStarted.complete(Unit)
            releaseDelete.await()
            deletedTransferIds += transferId
            deleteCompleted.complete(Unit)
        }
    }

    private class DelayedFailingDeleteStore : EmptyCheckpointStore() {
        private val checkpoints = ConcurrentHashMap<String, TransferCheckpoint>()
        val deleteStarted = CompletableDeferred<Unit>()
        val releaseDelete = CompletableDeferred<Unit>()
        val failureThrown = CompletableDeferred<Unit>()

        override suspend fun load(transferId: String): TransferCheckpoint? = checkpoints[transferId]

        override suspend fun save(checkpoint: TransferCheckpoint) {
            checkpoints[checkpoint.transferId] = checkpoint
        }

        override suspend fun delete(transferId: String) {
            deleteStarted.complete(Unit)
            releaseDelete.await()
            failureThrown.complete(Unit)
            throw IOException("synthetic late delete failure")
        }
    }

    private class BlockingSecondSaveFailureStore : EmptyCheckpointStore() {
        private val saveInvocations = AtomicInteger()
        private val checkpoints = ConcurrentHashMap<String, TransferCheckpoint>()
        val secondSaveStarted = CompletableDeferred<Unit>()
        val releaseSecondSave = CompletableDeferred<Unit>()
        val thirdSaveStarted = CompletableDeferred<Unit>()
        val releaseThirdSave = CompletableDeferred<Unit>()

        override suspend fun load(transferId: String): TransferCheckpoint? = checkpoints[transferId]

        override suspend fun save(checkpoint: TransferCheckpoint) {
            val invocation = saveInvocations.incrementAndGet()
            if (invocation == 2) {
                secondSaveStarted.complete(Unit)
                releaseSecondSave.await()
                throw IOException("synthetic owner A late save failure")
            }
            if (invocation == 3) {
                thirdSaveStarted.complete(Unit)
                releaseThirdSave.await()
            }
            checkpoints[checkpoint.transferId] = checkpoint
        }

        override suspend fun delete(transferId: String) {
            checkpoints.remove(transferId)
        }
    }

    private class BlockingFirstDeleteStore : EmptyCheckpointStore() {
        private val deleteInvocations = AtomicInteger()
        private val checkpoints = ConcurrentHashMap<String, TransferCheckpoint>()
        val firstDeleteStarted = CompletableDeferred<Unit>()
        val releaseFirstDelete = CompletableDeferred<Unit>()

        override suspend fun load(transferId: String): TransferCheckpoint? = checkpoints[transferId]

        override suspend fun save(checkpoint: TransferCheckpoint) {
            checkpoints[checkpoint.transferId] = checkpoint
        }

        override suspend fun delete(transferId: String) {
            if (deleteInvocations.incrementAndGet() == 1) {
                firstDeleteStarted.complete(Unit)
                releaseFirstDelete.await()
            }
            checkpoints.remove(transferId)
        }
    }

    private companion object {
        const val TEST_TIMEOUT_MS = 5_000L
    }
}
