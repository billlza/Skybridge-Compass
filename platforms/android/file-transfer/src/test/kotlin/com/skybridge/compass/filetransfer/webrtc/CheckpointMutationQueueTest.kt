package com.skybridge.compass.filetransfer.webrtc

import com.skybridge.compass.filetransfer.webrtc.property.PropertyRecordingTransport
import com.skybridge.compass.filetransfer.webrtc.property.acceptingApprovalProvider
import com.skybridge.compass.filetransfer.webrtc.resume.TransferCheckpoint
import com.skybridge.compass.filetransfer.webrtc.resume.TransferCheckpointStore
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferMessage
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferOp
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
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

    private companion object {
        const val TEST_TIMEOUT_MS = 5_000L
    }
}
