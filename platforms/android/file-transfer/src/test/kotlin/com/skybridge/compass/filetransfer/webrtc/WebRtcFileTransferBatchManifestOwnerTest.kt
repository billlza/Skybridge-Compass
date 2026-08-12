package com.skybridge.compass.filetransfer.webrtc

import com.skybridge.compass.core.p2p.P2PHandshakePolicyOverride
import com.skybridge.compass.core.webrtc.AuthenticatedPeerMetadata
import com.skybridge.compass.core.webrtc.SkyBridgeWebRtcConnectionManager
import com.skybridge.compass.core.webrtc.WebRtcSession
import com.skybridge.compass.filetransfer.webrtc.resume.BatchManifest
import com.skybridge.compass.filetransfer.webrtc.resume.BatchManifestCommitRejectedException
import com.skybridge.compass.filetransfer.webrtc.resume.BatchManifestEntry
import com.skybridge.compass.filetransfer.webrtc.resume.BatchManifestStore
import com.skybridge.compass.filetransfer.webrtc.resume.AndroidBatchManifestStore
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferMessage
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferOp
import com.skybridge.compass.shared.webrtc.WebRtcAppSecureEnvelope
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertInstanceOf
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import java.io.IOException
import java.security.MessageDigest
import java.nio.file.Path
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class WebRtcFileTransferBatchManifestOwnerTest {
    @TempDir
    lateinit var filesDirectory: Path

    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false }

    @Test
    fun suspendedLoad_rekeyPreventsOldInProgressCommit() = runBlocking {
        val store = ControllableBatchManifestStore(suspendLoadAt = 2)
        val transport = ManifestTransport(json)
        val controller = controller(transport, store)

        val sending = isolatedAsync {
            controller.sendBytesAsFilesBatch(singleItem("old.txt"), batchId = LOAD_BATCH_ID)
        }
        withTimeout(TIMEOUT_MS) { store.loadStaged.await() }

        transport.replaceTestSecureOwner()
        store.releaseLoad.complete(Unit)

        val failure = runCatching { withTimeout(TIMEOUT_MS) { sending.await() } }.exceptionOrNull()
        assertInstanceOf(StaleWebRtcFileTransferOwnerException::class.java, failure)
        assertEquals(BatchManifestEntry.Status.PENDING, store.status(LOAD_BATCH_ID))
        assertEquals(1, store.saveInvocations.get(), "old load continuation must never reach save")
        assertTrue(transport.messages.isEmpty())
    }

    @Test
    fun nonCancellableStagedSave_rekeyRejectsOldInProgressCommit() = runBlocking {
        val store = ControllableBatchManifestStore(suspendSaveAt = 2)
        val transport = ManifestTransport(json)
        val controller = controller(transport, store)

        val sending = isolatedAsync {
            controller.sendBytesAsFilesBatch(singleItem("old.txt"), batchId = IN_PROGRESS_BATCH_ID)
        }
        withTimeout(TIMEOUT_MS) { store.saveStaged.await() }

        transport.replaceTestSecureOwner()
        store.releaseSave.complete(Unit)

        val failure = runCatching { withTimeout(TIMEOUT_MS) { sending.await() } }.exceptionOrNull()
        assertInstanceOf(StaleWebRtcFileTransferOwnerException::class.java, failure)
        withTimeout(TIMEOUT_MS) { store.commitRejected.await() }
        assertEquals(BatchManifestEntry.Status.PENDING, store.status(IN_PROGRESS_BATCH_ID))
        assertFalse(transport.messages.any { it.batchId == IN_PROGRESS_BATCH_ID })
    }

    @Test
    fun nonCancellableStagedSave_replacementRejectsOldFailedCommit() = runBlocking {
        val store = ControllableBatchManifestStore(suspendSaveAt = 3)
        val transport = ManifestTransport(json, failSends = true)
        val controller = controller(transport, store)

        val sending = isolatedAsync {
            controller.sendBytesAsFilesBatch(singleItem("failed.txt"), batchId = FAILED_BATCH_ID)
        }
        withTimeout(TIMEOUT_MS) { store.saveStaged.await() }

        transport.replaceTestSecureOwner()
        store.releaseSave.complete(Unit)

        val failure = runCatching { withTimeout(TIMEOUT_MS) { sending.await() } }.exceptionOrNull()
        assertInstanceOf(StaleWebRtcFileTransferOwnerException::class.java, failure)
        withTimeout(TIMEOUT_MS) { store.commitRejected.await() }
        assertEquals(
            BatchManifestEntry.Status.IN_PROGRESS,
            store.status(FAILED_BATCH_ID),
            "FAILED belongs to the invalidated owner and must not replace the durable state",
        )
    }

    @Test
    fun oldCompletedCommitIsRejected_thenCurrentOwnerStartsFreshBatchNormally() = runBlocking {
        val store = ControllableBatchManifestStore(suspendSaveAt = 3)
        val transport = ManifestTransport(json)
        val controller = controller(transport, store)
        val ownerA = transport.currentTestSecureOwner()

        controller.sendBytesAsFilesBatch(singleItem("a.txt"), batchId = SHARED_BATCH_ID)
        val transferA = transport.messages.single { it.op == CrossNetworkFileTransferOp.metadata }.transferId
        controller.handleIncoming(ownerA, completeAck(transferA))
        withTimeout(TIMEOUT_MS) { store.saveStaged.await() }

        val ownerB = transport.replaceTestSecureOwner()
        store.releaseSave.complete(Unit)
        withTimeout(TIMEOUT_MS) { store.commitRejected.await() }
        assertEquals(BatchManifestEntry.Status.IN_PROGRESS, store.status(SHARED_BATCH_ID))

        val messageCountBeforeCollision = transport.messages.size
        val collision = runCatching {
            controller.sendBytesAsFilesBatch(singleItem("must-not-resume.txt"), batchId = SHARED_BATCH_ID)
        }.exceptionOrNull()
        assertInstanceOf(IllegalStateException::class.java, collision)
        assertEquals(messageCountBeforeCollision, transport.messages.size)

        controller.sendBytesAsFilesBatch(singleItem("b.txt"), batchId = CURRENT_OWNER_BATCH_ID)
        val transferB = transport.messages
            .last { it.op == CrossNetworkFileTransferOp.metadata }
            .transferId
        controller.handleIncoming(ownerB, completeAck(transferB))

        val completed = withTimeout(TIMEOUT_MS) {
            store.awaitStatus(CURRENT_OWNER_BATCH_ID, BatchManifestEntry.Status.COMPLETED)
        }
        assertEquals(transferB, completed.entries.single().transferId)
        assertEquals(BatchManifestEntry.Status.COMPLETED, completed.entries.single().status)
        assertEquals(BatchManifestEntry.Status.IN_PROGRESS, store.status(SHARED_BATCH_ID))
    }

    @Test
    fun secureOwnerGatePrecedesBatchLane_doesNotDeadlockInboundCallback() = runBlocking {
        val store = ControllableBatchManifestStore(suspendSaveAt = 3)
        val transport = ManifestTransport(json)
        val controller = controller(transport, store)
        val owner = transport.currentTestSecureOwner()

        controller.sendBytesAsFilesBatch(singleItem("outbound.txt"), batchId = LOCK_ORDER_BATCH_ID)
        val outboundTransferId = transport.messages
            .single { it.op == CrossNetworkFileTransferOp.metadata }
            .transferId
        controller.handleIncoming(owner, completeAck(outboundTransferId))
        withTimeout(TIMEOUT_MS) { store.saveStaged.await() }

        val callback = isolatedAsync {
            check(
                transport.runIfCurrentSecureOperationOwner(owner) {
                    store.releaseSave.complete(Unit)
                    val committingThread = runBlocking {
                        withTimeout(TIMEOUT_MS) { store.authorizedCommitThread.await() }
                    }
                    check(waitUntilBlocked(committingThread)) {
                        "manifest commit did not block on the held secure-owner gate"
                    }
                    controller.handleIncoming(
                        owner,
                        inboundMetadata(
                            transferId = LOCK_ORDER_INBOUND_TRANSFER_ID,
                            batchId = LOCK_ORDER_BATCH_ID,
                        ),
                    )
                },
            )
        }

        withTimeout(TIMEOUT_MS) { callback.await() }
        val completed = withTimeout(TIMEOUT_MS) {
            store.awaitStatus(LOCK_ORDER_BATCH_ID, BatchManifestEntry.Status.COMPLETED)
        }
        assertEquals(outboundTransferId, completed.entries.first().transferId)
    }

    @Test
    fun storeFailureIsTypedAndPublishedInsteadOfSwallowed() = runBlocking {
        val store = ControllableBatchManifestStore(failSaveAt = 1)
        val transport = ManifestTransport(json)
        val controller = controller(transport, store)

        val failure = runCatching {
            controller.sendBytesAsFilesBatch(singleItem("error.txt"), batchId = ERROR_BATCH_ID)
        }.exceptionOrNull()

        val typed = assertInstanceOf(BatchManifestMutationException::class.java, failure)
        assertInstanceOf(IOException::class.java, typed.cause)
        assertTrue(controller.progress.value.lastStatus?.contains("batch manifest initialize failed") == true)
        assertTrue(controller.progress.value.lastStatus?.contains("synthetic manifest save failure") == true)
        assertTrue(transport.messages.isEmpty(), "manifest durability failure must fail before network send")
    }

    @Test
    fun deleteEntryWhileOldTerminalSaveIsStaged_preemptsItWithCancelled() = runBlocking {
        val store = ControllableBatchManifestStore(suspendSaveAt = 3)
        val transport = ManifestTransport(json)
        val controller = controller(transport, store)
        val owner = transport.currentTestSecureOwner()

        controller.sendBytesAsFilesBatch(singleItem("cancel.txt"), batchId = DELETE_RACE_BATCH_ID)
        val transferId = transport.messages.single { it.op == CrossNetworkFileTransferOp.metadata }.transferId
        controller.handleIncoming(owner, completeAck(transferId))
        withTimeout(TIMEOUT_MS) { store.saveStaged.await() }

        val deleting = isolatedAsyncUndispatched {
            controller.deleteBatchEntry(DELETE_RACE_BATCH_ID, transferId)
        }
        store.releaseSave.complete(Unit)
        withTimeout(TIMEOUT_MS) { deleting.await() }

        assertEquals(BatchManifestEntry.Status.CANCELLED, store.status(DELETE_RACE_BATCH_ID))
        assertEquals(4, store.saveInvocations.get(), "old COMPLETED must reject before CANCELLED commits")
    }

    @Test
    fun deleteEntryBeforeLateAck_keepsCancelledTerminal() = runBlocking {
        val store = ControllableBatchManifestStore()
        val transport = ManifestTransport(json)
        val controller = controller(transport, store)
        val owner = transport.currentTestSecureOwner()

        controller.sendBytesAsFilesBatch(singleItem("cancel-first.txt"), batchId = DELETE_FIRST_BATCH_ID)
        val transferId = transport.messages.single { it.op == CrossNetworkFileTransferOp.metadata }.transferId
        controller.deleteBatchEntry(DELETE_FIRST_BATCH_ID, transferId)
        val savesAfterDelete = store.saveInvocations.get()

        controller.handleIncoming(owner, completeAck(transferId))

        assertEquals(BatchManifestEntry.Status.CANCELLED, store.status(DELETE_FIRST_BATCH_ID))
        assertEquals(savesAfterDelete, store.saveInvocations.get(), "late ACK must not enter the closed entry lane")
    }

    @Test
    fun deleteBatchPreemptsStagedTerminal_andLateInboundCannotRecreateIt() = runBlocking {
        val store = ControllableBatchManifestStore(suspendSaveAt = 3)
        val transport = ManifestTransport(json)
        val controller = controller(transport, store)
        val owner = transport.currentTestSecureOwner()

        controller.sendBytesAsFilesBatch(singleItem("delete-batch.txt"), batchId = DELETE_BATCH_ID)
        val transferId = transport.messages.single { it.op == CrossNetworkFileTransferOp.metadata }.transferId
        controller.handleIncoming(owner, completeAck(transferId))
        withTimeout(TIMEOUT_MS) { store.saveStaged.await() }

        val deleting = isolatedAsyncUndispatched { controller.deleteBatch(DELETE_BATCH_ID) }
        val messagesBeforeRejectedReuse = transport.messages.size
        val inFlightReuse = runCatching {
            controller.sendBytesAsFilesBatch(singleItem("too-early.txt"), batchId = DELETE_BATCH_ID)
        }.exceptionOrNull()
        assertInstanceOf(IllegalStateException::class.java, inFlightReuse)
        assertEquals(messagesBeforeRejectedReuse, transport.messages.size)

        store.releaseSave.complete(Unit)
        withTimeout(TIMEOUT_MS) { deleting.await() }

        assertEquals(null, store.status(DELETE_BATCH_ID))
        val savesAfterDelete = store.saveInvocations.get()
        controller.handleIncoming(owner, completeAck(transferId))
        controller.handleIncoming(
            owner,
            inboundMetadata(
                transferId = DELETE_BATCH_LATE_TRANSFER_ID,
                batchId = DELETE_BATCH_ID,
            ),
        )
        assertEquals(null, store.status(DELETE_BATCH_ID))
        assertEquals(savesAfterDelete, store.saveInvocations.get())

        controller.sendBytesAsFilesBatch(singleItem("fresh.txt"), batchId = DELETE_BATCH_ID)
        val freshTransferId = transport.messages
            .last { it.op == CrossNetworkFileTransferOp.metadata && it.batchId == DELETE_BATCH_ID }
            .transferId
        assertTrue(freshTransferId != transferId)
        assertEquals(BatchManifestEntry.Status.IN_PROGRESS, store.status(DELETE_BATCH_ID))
        val savesAfterFreshBatch = store.saveInvocations.get()

        // The late transfer id observed while deleted remains tombstoned across explicit reuse.
        controller.handleIncoming(
            owner,
            inboundMetadata(
                transferId = DELETE_BATCH_LATE_TRANSFER_ID,
                batchId = DELETE_BATCH_ID,
            ),
        )
        assertEquals(savesAfterFreshBatch, store.saveInvocations.get())
        assertEquals(BatchManifestEntry.Status.IN_PROGRESS, store.status(DELETE_BATCH_ID))
    }

    @Test
    fun failedFreshInitializationAfterDelete_restoresTombstoneUntilExplicitRetry() = runBlocking {
        val store = ControllableBatchManifestStore(failSaveAt = 3)
        val transport = ManifestTransport(json)
        val controller = controller(transport, store)
        val owner = transport.currentTestSecureOwner()

        controller.sendBytesAsFilesBatch(singleItem("old.txt"), batchId = DELETE_RETRY_BATCH_ID)
        controller.deleteBatch(DELETE_RETRY_BATCH_ID)

        val failedFresh = runCatching {
            controller.sendBytesAsFilesBatch(singleItem("failed-fresh.txt"), batchId = DELETE_RETRY_BATCH_ID)
        }.exceptionOrNull()
        val typedFailure = assertInstanceOf(BatchManifestMutationException::class.java, failedFresh)
        assertInstanceOf(IOException::class.java, typedFailure.cause)
        assertEquals(null, store.status(DELETE_RETRY_BATCH_ID))
        val savesAfterFailure = store.saveInvocations.get()

        controller.handleIncoming(
            owner,
            inboundMetadata(
                transferId = DELETE_RETRY_LATE_TRANSFER_ID,
                batchId = DELETE_RETRY_BATCH_ID,
            ),
        )
        assertEquals(savesAfterFailure, store.saveInvocations.get())
        assertEquals(null, store.status(DELETE_RETRY_BATCH_ID))

        controller.sendBytesAsFilesBatch(singleItem("retry.txt"), batchId = DELETE_RETRY_BATCH_ID)
        assertEquals(BatchManifestEntry.Status.IN_PROGRESS, store.status(DELETE_RETRY_BATCH_ID))
        val savesAfterRetry = store.saveInvocations.get()
        controller.handleIncoming(
            owner,
            inboundMetadata(
                transferId = DELETE_RETRY_LATE_TRANSFER_ID,
                batchId = DELETE_RETRY_BATCH_ID,
            ),
        )
        assertEquals(savesAfterRetry, store.saveInvocations.get())
    }

    @Test
    fun twoControllersWithSameApplicationFilesDirectory_shareCoordinator() = runBlocking {
        val storeA = AndroidBatchManifestStore.forFilesDirectory(filesDirectory.toFile(), json)
        val storeB = AndroidBatchManifestStore.forFilesDirectory(filesDirectory.toFile(), json)
        assertEquals(storeA.coordinationNamespace, storeB.coordinationNamespace)
        val transportA = ManifestTransport(json)
        val transportB = ManifestTransport(json)
        val ownerA = transportA.currentTestSecureOwner()
        transportB.replaceTestSecureOwner()
        val controllerA = controller(transportA, storeA)
        val controllerB = controller(transportB, storeB)

        controllerA.sendBytesAsFilesBatch(singleItem("a.txt"), batchId = SHARED_DIRECTORY_BATCH_ID)
        val transferA = transportA.messages.single { it.op == CrossNetworkFileTransferOp.metadata }.transferId

        val collision = runCatching {
            controllerB.sendBytesAsFilesBatch(singleItem("b.txt"), batchId = SHARED_DIRECTORY_BATCH_ID)
        }.exceptionOrNull()

        assertTrue(collision is IllegalStateException)
        assertTrue(transportB.messages.isEmpty())
        controllerA.handleIncoming(ownerA, completeAck(transferA))
        val durable = withTimeout(TIMEOUT_MS) {
            awaitStatus(storeB, SHARED_DIRECTORY_BATCH_ID, BatchManifestEntry.Status.COMPLETED)
        }
        assertEquals(transferA, durable.entries.single().transferId)
        assertEquals(BatchManifestEntry.Status.COMPLETED, durable.entries.single().status)
    }

    private fun controller(
        transport: ManifestTransport,
        store: BatchManifestStore,
    ): WebRtcFileTransferController = WebRtcFileTransferController(
        webrtc = transport,
        json = json,
        batchManifestStore = store,
    )

    private fun isolatedAsync(operation: suspend () -> Unit) =
        CoroutineScope(SupervisorJob() + Dispatchers.Default).async { operation() }

    private fun isolatedAsyncUndispatched(operation: suspend () -> Unit) =
        CoroutineScope(SupervisorJob() + Dispatchers.Default).async(start = CoroutineStart.UNDISPATCHED) {
            operation()
        }

    private suspend fun awaitStatus(
        store: BatchManifestStore,
        batchId: String,
        status: BatchManifestEntry.Status,
    ): BatchManifest {
        while (true) {
            store.load(batchId)?.takeIf { manifest ->
                manifest.entries.singleOrNull()?.status == status
            }?.let { return it }
            delay(1)
        }
    }

    private fun singleItem(name: String) = listOf(
        WebRtcFileTransferController.BatchBytesItem(
            fileName = name,
            bytes = name.encodeToByteArray(),
            relativePath = name,
            mimeType = "text/plain",
        ),
    )

    private fun completeAck(transferId: String): ByteArray = json.encodeToString(
        CrossNetworkFileTransferMessage.serializer(),
        CrossNetworkFileTransferMessage(
            op = CrossNetworkFileTransferOp.completeAck,
            transferId = transferId,
        ),
    ).encodeToByteArray()

    private fun inboundMetadata(transferId: String, batchId: String): ByteArray = json.encodeToString(
        CrossNetworkFileTransferMessage.serializer(),
        CrossNetworkFileTransferMessage(
            op = CrossNetworkFileTransferOp.metadata,
            transferId = transferId,
            senderDeviceId = "trusted-peer",
            senderDeviceName = "peer",
            fileName = "inbound.txt",
            fileSize = 1,
            chunkSize = 1,
            totalChunks = 1,
            batchId = batchId,
            batchIndex = 1,
            batchTotal = 2,
            relativePath = "inbound.txt",
        ),
    ).encodeToByteArray()

    private fun waitUntilBlocked(thread: Thread): Boolean {
        val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(TIMEOUT_MS)
        while (System.nanoTime() < deadline) {
            if (thread.state == Thread.State.BLOCKED) return true
            Thread.yield()
        }
        return false
    }

    private class ControllableBatchManifestStore(
        private val suspendLoadAt: Int? = null,
        private val suspendSaveAt: Int? = null,
        private val failSaveAt: Int? = null,
    ) : BatchManifestStore {
        override val coordinationNamespace: String = "manifest-test-${java.util.UUID.randomUUID()}"
        private val manifests = ConcurrentHashMap<String, BatchManifest>()
        private val committed = Channel<BatchManifest>(Channel.UNLIMITED)
        val loadInvocations = AtomicInteger(0)
        val saveInvocations = AtomicInteger(0)
        val loadStaged = CompletableDeferred<Unit>()
        val saveStaged = CompletableDeferred<Unit>()
        val releaseLoad = CompletableDeferred<Unit>()
        val releaseSave = CompletableDeferred<Unit>()
        val commitRejected = CompletableDeferred<Unit>()
        val authorizedCommitThread = CompletableDeferred<Thread>()

        override suspend fun save(
            manifest: BatchManifest,
            runAuthorizedCommit: (commit: () -> Unit) -> Boolean,
        ) {
            val invocation = saveInvocations.incrementAndGet()
            if (invocation == suspendSaveAt) {
                saveStaged.complete(Unit)
                // Simulates blocking/non-cooperative staging I/O: coroutine cancellation alone is
                // insufficient; the mandatory pre-commit validator must reject the old owner.
                withContext(NonCancellable) { releaseSave.await() }
            }
            if (invocation == failSaveAt) throw IOException("synthetic manifest save failure")
            if (invocation == suspendSaveAt) {
                authorizedCommitThread.complete(Thread.currentThread())
            }
            val didCommit = runAuthorizedCommit {
                manifests[manifest.batchId] = manifest
                committed.trySend(manifest)
            }
            if (!didCommit) {
                commitRejected.complete(Unit)
                throw BatchManifestCommitRejectedException(manifest.batchId)
            }
        }

        override suspend fun load(batchId: String): BatchManifest? {
            val invocation = loadInvocations.incrementAndGet()
            if (invocation == suspendLoadAt) {
                loadStaged.complete(Unit)
                withContext(NonCancellable) { releaseLoad.await() }
            }
            return manifests[batchId]
        }

        override suspend fun delete(batchId: String) {
            manifests.remove(batchId)
        }

        override suspend fun list(): List<BatchManifest> = manifests.values.toList()

        fun status(batchId: String): BatchManifestEntry.Status? =
            manifests[batchId]?.entries?.singleOrNull()?.status

        suspend fun awaitStatus(
            batchId: String,
            status: BatchManifestEntry.Status,
        ): BatchManifest {
            manifests[batchId]?.takeIf { it.entries.singleOrNull()?.status == status }?.let { return it }
            while (true) {
                val manifest = committed.receive()
                if (manifest.batchId == batchId && manifest.entries.singleOrNull()?.status == status) {
                    return manifest
                }
            }
        }
    }

    private class ManifestTransport(
        private val json: Json,
        private val failSends: Boolean = false,
    ) : TestCrossNetworkWebRtcTransportAdapter() {
        override val state: StateFlow<SkyBridgeWebRtcConnectionManager.State> =
            MutableStateFlow(SkyBridgeWebRtcConnectionManager.State.Established("same-session"))
        override val signalingStatus: StateFlow<SkyBridgeWebRtcConnectionManager.SignalingStatus> =
            MutableStateFlow(SkyBridgeWebRtcConnectionManager.SignalingStatus())
        override val dataChannelConfigStatus: StateFlow<WebRtcSession.DataChannelConfigStatus> =
            MutableStateFlow(WebRtcSession.DataChannelConfigStatus.Unknown)
        override val authenticatedPeerMetadata: StateFlow<AuthenticatedPeerMetadata?> = MutableStateFlow(null)
        override var onData: ((ByteArray) -> Unit)? = null
        override var onPacketData: ((ByteArray, WebRtcAppSecureEnvelope.PacketType) -> Unit)? = null
        val messages = mutableListOf<CrossNetworkFileTransferMessage>()

        override fun hasSessionKeys(): Boolean = true
        override fun authenticatedPeerDeviceId(): String = "trusted-peer"
        override fun negotiatedSuiteName(): String = "Q_PERIAPT_CONTEXT_BOUND"
        override fun negotiatedSuiteWireId(): Int = 0x0011
        override fun hasPqcSessionKeys(): Boolean = true
        override fun hasQPeriaptSessionKeys(): Boolean = true
        override fun computeOutboundHmacSha256(preimage: ByteArray): ByteArray =
            MessageDigest.getInstance("SHA-256").digest(preimage)

        override fun verifyInboundHmacSha256(preimage: ByteArray, mac: ByteArray): Boolean =
            mac.contentEquals(computeOutboundHmacSha256(preimage))

        override fun setLocalDeviceId(id: String) = Unit
        override fun setPqcEnabled(enabled: Boolean) = Unit
        override fun setHandshakePolicyOverride(policy: P2PHandshakePolicyOverride?) = Unit
        override suspend fun generateConnectionCode(): String = "same-session"
        override fun startOfferer(code: String) = Unit
        override fun startAnswerer(code: String) = Unit

        override fun send(bytes: ByteArray, packetType: WebRtcAppSecureEnvelope.PacketType): Boolean {
            if (failSends) return false
            messages += json.decodeFromString(CrossNetworkFileTransferMessage.serializer(), bytes.decodeToString())
            return true
        }

        override fun disconnect() = Unit
        override fun release() = Unit
    }

    private companion object {
        const val TIMEOUT_MS = 2_000L
        const val LOAD_BATCH_ID = "00000000-0000-0000-0000-000000000001"
        const val IN_PROGRESS_BATCH_ID = "00000000-0000-0000-0000-000000000002"
        const val FAILED_BATCH_ID = "00000000-0000-0000-0000-000000000003"
        const val SHARED_BATCH_ID = "00000000-0000-0000-0000-000000000004"
        const val ERROR_BATCH_ID = "00000000-0000-0000-0000-000000000005"
        const val DELETE_RACE_BATCH_ID = "00000000-0000-0000-0000-000000000006"
        const val DELETE_FIRST_BATCH_ID = "00000000-0000-0000-0000-000000000007"
        const val SHARED_DIRECTORY_BATCH_ID = "00000000-0000-0000-0000-000000000008"
        const val CURRENT_OWNER_BATCH_ID = "00000000-0000-0000-0000-000000000009"
        const val LOCK_ORDER_BATCH_ID = "00000000-0000-0000-0000-000000000010"
        const val LOCK_ORDER_INBOUND_TRANSFER_ID = "00000000-0000-0000-0000-000000000011"
        const val DELETE_BATCH_ID = "00000000-0000-0000-0000-000000000012"
        const val DELETE_BATCH_LATE_TRANSFER_ID = "00000000-0000-0000-0000-000000000013"
        const val DELETE_RETRY_BATCH_ID = "00000000-0000-0000-0000-000000000014"
        const val DELETE_RETRY_LATE_TRANSFER_ID = "00000000-0000-0000-0000-000000000015"
    }
}
