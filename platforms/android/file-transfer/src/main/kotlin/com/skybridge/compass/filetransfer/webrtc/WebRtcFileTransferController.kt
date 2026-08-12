package com.skybridge.compass.filetransfer.webrtc

import android.content.ContentResolver
import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Environment
import android.provider.MediaStore
import androidx.core.net.toUri
import com.skybridge.compass.core.webrtc.CrossNetworkWebRtcTransportAdapter
import com.skybridge.compass.core.webrtc.WebRtcSecureOperationOwner
import com.skybridge.compass.shared.webrtc.WebRtcAppSecureEnvelope
import com.skybridge.compass.shared.crypto.MerkleSha256
import com.skybridge.compass.shared.p2p.filetransfer.MerkleRootAuthV1
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferMessage
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferOp
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferWireCodec
import com.skybridge.compass.filetransfer.webrtc.resume.InMemoryTransferCheckpointStore
import com.skybridge.compass.filetransfer.webrtc.resume.BatchManifest
import com.skybridge.compass.filetransfer.webrtc.resume.BatchManifestCommitRejectedException
import com.skybridge.compass.filetransfer.webrtc.resume.BatchManifestEntry
import com.skybridge.compass.filetransfer.webrtc.resume.BatchManifestGenerationToken
import com.skybridge.compass.filetransfer.webrtc.resume.BatchManifestMutationAdmission
import com.skybridge.compass.filetransfer.webrtc.resume.BatchManifestMutationCoordinator
import com.skybridge.compass.filetransfer.webrtc.resume.AndroidBatchManifestMutationCoordinatorRegistry
import com.skybridge.compass.filetransfer.webrtc.resume.BatchManifestStore
import com.skybridge.compass.filetransfer.webrtc.resume.AndroidBatchManifestStore
import com.skybridge.compass.filetransfer.webrtc.resume.TransferCheckpoint
import com.skybridge.compass.filetransfer.webrtc.resume.TransferCheckpointStore
import com.skybridge.compass.filetransfer.webrtc.resume.ResumeReceivePlanner
import com.skybridge.compass.filetransfer.webrtc.resume.TransferDirection
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.supervisorScope
import kotlinx.coroutines.selects.select
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong

internal enum class CheckpointMutation(val operationName: String) {
    SAVE("save"),
    UPDATE("update"),
    DELETE("delete"),
}

internal class CheckpointMutationException(
    val transferId: String,
    val mutation: CheckpointMutation,
    cause: Throwable,
) : IllegalStateException(
    "checkpoint ${mutation.operationName} failed for transfer $transferId",
    cause,
)

enum class BatchManifestMutation(val operationName: String) {
    INITIALIZE("initialize"),
    MERGE_INBOUND("merge inbound entry"),
    UPDATE_STATUS("update status"),
}

class BatchManifestMutationException(
    val batchId: String,
    val transferId: String,
    val mutation: BatchManifestMutation,
    cause: Throwable,
) : IllegalStateException(
    "batch manifest ${mutation.operationName} failed for batch $batchId transfer $transferId",
    cause,
)

internal class StaleBatchManifestGenerationException(
    val batchId: String,
    val transferId: String,
) : IllegalStateException("batch manifest generation is stale for batch $batchId transfer $transferId")

internal class BatchManifestTransitionException(
    val transferId: String,
    val from: BatchManifestEntry.Status,
    val to: BatchManifestEntry.Status,
) : IllegalStateException("invalid batch manifest transition for $transferId: $from -> $to")

/**
 * The transfer outlived the exact WebRTC application-key epoch that admitted it.
 *
 * This is intentionally distinct from an ordinary DataChannel send failure: callers may retain a
 * checkpoint for an explicit restart, but must never retry the old operation through a replacement
 * session or a same-session rekey.
 */
class StaleWebRtcFileTransferOwnerException(
    val transferId: String,
) : IllegalStateException("file transfer owner is stale for transfer $transferId")

/**
 * Minimal CrossNetwork (WebRTC DataChannel) file transfer controller compatible with Pro release
 * message shapes. This provides a real metadata->chunk->complete flow.
 *
 * Notes:
 * - Payload is JSON bytes. Chunk bytes are base64-encoded inside JSON (Swift Data Codable behavior).
 * - Resume, integrity proof, and inbound approval are enforced here; WebRTC provides the secure
 *   transport and SBWC application envelope.
 * - Every live operation is bound to one opaque WebRTC key-epoch capability. Session replacement
 *   or same-session rekey invalidates its sends, ACKs, HMACs, retries, approvals, and completion.
 */
class WebRtcFileTransferController(
    private val webrtc: CrossNetworkWebRtcTransportAdapter,
    private val json: Json = Json { ignoreUnknownKeys = true; explicitNulls = false },
    private val checkpointStore: TransferCheckpointStore = InMemoryTransferCheckpointStore(),
    private val appContext: Context? = null,
    private val batchManifestStore: BatchManifestStore? = appContext?.let { AndroidBatchManifestStore(it.applicationContext, json) },
    private val inboundApprovalProvider: InboundFileTransferApprovalProvider = InboundFileTransferApprovalProvider {
        InboundFileTransferDecision.Decline
    },
    private val saveAcceptedInboundToDownloads: Boolean = false,
    private val missingChunkReceiveTimeoutMs: Long = DEFAULT_MISSING_CHUNK_RECEIVE_TIMEOUT_MS,
    /**
     * Idle / interrupt threshold for an active transfer (Requirement 5.12): if no chunk or ack
     * activity is observed for this long — or the session stays interrupted this long — THIS
     * transfer is terminated while its verified-bytes checkpoint is RETAINED for resume. Injectable
     * so tests can drive it deterministically.
     */
    private val idleInterruptTimeoutMs: Long = DEFAULT_IDLE_INTERRUPT_TIMEOUT_MS,
    /** Poll cadence of the background idle/interrupt watchdog. */
    private val idleWatchdogPollMs: Long = DEFAULT_IDLE_WATCHDOG_POLL_MS,
    /** Injectable monotonic-ish clock (epoch millis) used for activity/idle bookkeeping. */
    private val clockMs: () -> Long = { System.currentTimeMillis() }
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val checkpointMutationLock = Any()
    private val checkpointMutationTails = ConcurrentHashMap<String, QueuedCheckpointMutation>()
    private val batchManifestMutationCoordinator = batchManifestStore
        ?.coordinationNamespace
        ?.let(AndroidBatchManifestMutationCoordinatorRegistry::forNamespace)
        ?: appContext?.let { context ->
            AndroidBatchManifestMutationCoordinatorRegistry.forDirectory(
                File(context.applicationContext.filesDir, "skybridge_batch_manifests"),
            )
        }
        ?: BatchManifestMutationCoordinator()

    init {
        require(missingChunkReceiveTimeoutMs > 0) {
            "missingChunkReceiveTimeoutMs must be positive"
        }
        require(idleInterruptTimeoutMs > 0) {
            "idleInterruptTimeoutMs must be positive"
        }
        require(idleWatchdogPollMs > 0) {
            "idleWatchdogPollMs must be positive"
        }
    }

    /**
     * Preserve source-order for checkpoint mutations belonging to one transfer.
     *
     * Data-channel callbacks are synchronous, while persistence is dispatched to IO. Launching
     * independent save/delete coroutines allowed an older chunk save to run after terminal cleanup
     * and resurrect a checkpoint. The per-transfer job chain keeps unrelated transfers parallel,
     * bounds retained state to active mutation tails, and makes a terminal delete run only after
     * every mutation enqueued before it has completed.
     */
    private data class QueuedCheckpointMutation(
        val worker: Deferred<Unit>,
    ) {
        /** Waiting is cancellable, but the accepted persistence job remains owned by the controller. */
        suspend fun awaitCompletion() {
            worker.await()
        }
    }

    private fun enqueueCheckpointMutation(
        transferId: String,
        owner: WebRtcSecureOperationOwner,
        mutation: CheckpointMutation,
        operation: suspend TransferCheckpointStore.() -> Unit,
    ): QueuedCheckpointMutation = enqueueCheckpointMutationInternal(
        transferId = transferId,
        mutation = mutation,
        operationAllowed = {
            checkpointOwners[transferId] === owner &&
                webrtc.isCurrentSecureOperationOwner(owner)
        },
        operation = operation,
        onSuccess = {
            if (mutation == CheckpointMutation.DELETE) {
                checkpointOwners.remove(transferId, owner)
            }
        },
    )

    /** Explicit local deletion is not a network operation and deliberately invalidates any owner. */
    private fun enqueueLocalCheckpointDeletion(transferId: String): QueuedCheckpointMutation {
        checkpointOwners.remove(transferId)
        return enqueueCheckpointMutationInternal(
            transferId = transferId,
            mutation = CheckpointMutation.DELETE,
            operationAllowed = { checkpointOwners[transferId] == null },
            operation = { delete(transferId) },
        )
    }

    private fun enqueueCheckpointMutationInternal(
        transferId: String,
        mutation: CheckpointMutation,
        operationAllowed: () -> Boolean,
        operation: suspend TransferCheckpointStore.() -> Unit,
        onSuccess: () -> Unit = {},
    ): QueuedCheckpointMutation {
        val queued = synchronized(checkpointMutationLock) {
            if (!scope.isActive) {
                throw CheckpointMutationException(
                    transferId = transferId,
                    mutation = mutation,
                    cause = IllegalStateException("checkpoint mutation queue is closed"),
                )
            }
            val predecessor = checkpointMutationTails[transferId]
            val worker = scope.async(start = CoroutineStart.LAZY) {
                // A failed predecessor must not strand terminal cleanup. Job.join waits for source
                // order without rethrowing; this mutation reports its own typed failure below.
                predecessor?.worker?.join()
                try {
                    if (!operationAllowed()) return@async
                    checkpointStore.operation()
                    onSuccess()
                } catch (cause: CancellationException) {
                    throw cause
                } catch (cause: Exception) {
                    throw CheckpointMutationException(transferId, mutation, cause)
                }
            }
            QueuedCheckpointMutation(worker).also {
                checkpointMutationTails[transferId] = it
            }
        }
        queued.worker.invokeOnCompletion { cause ->
            if (cause != null) {
                val contextualFailure = cause as? CheckpointMutationException
                    ?: CheckpointMutationException(transferId, mutation, cause)
                recordCheckpointMutationFailure(contextualFailure)
            }
            checkpointMutationTails.remove(transferId, queued)
        }
        queued.worker.start()
        return queued
    }

    private fun recordCheckpointMutationFailure(failure: CheckpointMutationException) {
        _progress.value = Progress(
            transferId = failure.transferId,
            lastStatus = buildString {
                append(requireNotNull(failure.message))
                failure.cause?.let { cause ->
                    append(": ")
                    append(cause.javaClass.simpleName)
                    cause.message?.let { append(": $it") }
                }
            },
        )
    }

    /**
     * Narrow store facade that makes every suspending batch-manifest I/O owner-aware.
     *
     * The controller never exposes the raw store inside a remote-driven mutation. If a same-session
     * rekey or replacement happens while load/save is suspended, [awaitStoreOperation] cancels that
     * continuation and waits for it to finish before the serialized mutation lane can admit newer
     * owner work.
     */
    private inner class ExactOwnerBatchManifestAccess(
        private val store: BatchManifestStore,
        private val owner: WebRtcSecureOperationOwner,
        private val transferId: String,
        private val batchToken: BatchManifestGenerationToken,
    ) {
        suspend fun load(batchId: String): BatchManifest? = awaitStoreOperation(owner, transferId, batchToken) {
            store.load(batchId)
        }

        suspend fun save(manifest: BatchManifest) = awaitStoreOperation(owner, transferId, batchToken) {
            store.save(manifest) { commit ->
                var generationCommitted = false
                // Inbound packets enter through the manager's secure-owner gate before touching a
                // batch lane. Preserve that single lock order here: owner gate -> lane -> atomic
                // move. Reversing these two gates deadlocks an inbound callback against a staged
                // manifest commit, while either gate alone leaves a replacement/delete race.
                val ownerCommitted = webrtc.runIfCurrentSecureOperationOwner(owner) {
                    generationCommitted = batchManifestMutationCoordinator.runRemoteCommitIfCurrent(
                        batchToken,
                        transferId,
                        commit,
                    )
                }
                generationCommitted && ownerCommitted
            }
        }
    }

    /** Revalidate immediately before and after every store suspension, and cancel on owner change. */
    private suspend fun <T> awaitStoreOperation(
        owner: WebRtcSecureOperationOwner,
        transferId: String,
        batchToken: BatchManifestGenerationToken,
        operation: suspend () -> T,
    ): T = supervisorScope {
        requireCurrentBatchMutation(batchToken, transferId, owner)
        requireCurrentOwner(transferId, owner)
        val ownerInvalidated = async(start = CoroutineStart.UNDISPATCHED) {
            webrtc.secureOperationOwner.first { current ->
                current !== owner || !webrtc.isCurrentSecureOperationOwner(owner)
            }
        }
        requireCurrentBatchMutation(batchToken, transferId, owner)
        val storeOperation = async(start = CoroutineStart.UNDISPATCHED) { operation() }
        try {
            val result = try {
                select<T> {
                    storeOperation.onAwait { it }
                    ownerInvalidated.onAwait {
                        storeOperation.cancelAndJoin()
                        abandonStaleOperation(transferId, owner)
                        throw StaleWebRtcFileTransferOwnerException(transferId)
                    }
                }
            } catch (rejected: BatchManifestCommitRejectedException) {
                if (!batchManifestMutationCoordinator.isRemoteMutationCurrent(batchToken, transferId)) {
                    abandonStaleOperation(transferId, owner)
                    throw StaleBatchManifestGenerationException(batchToken.batchId, transferId)
                } else if (!webrtc.isCurrentSecureOperationOwner(owner)) {
                    abandonStaleOperation(transferId, owner)
                    throw StaleWebRtcFileTransferOwnerException(transferId)
                }
                throw rejected
            } catch (cancelled: CancellationException) {
                if (!webrtc.isCurrentSecureOperationOwner(owner)) {
                    abandonStaleOperation(transferId, owner)
                    throw StaleWebRtcFileTransferOwnerException(transferId)
                }
                throw cancelled
            }
            requireCurrentBatchMutation(batchToken, transferId, owner)
            result
        } finally {
            ownerInvalidated.cancel()
            if (!storeOperation.isCompleted) storeOperation.cancelAndJoin()
        }
    }

    private fun requireCurrentBatchMutation(
        token: BatchManifestGenerationToken,
        transferId: String,
        owner: WebRtcSecureOperationOwner,
    ) {
        if (!batchManifestMutationCoordinator.isRemoteMutationCurrent(token, transferId)) {
            abandonStaleOperation(transferId, owner)
            throw StaleBatchManifestGenerationException(token.batchId, transferId)
        }
        requireCurrentOwner(transferId, owner)
    }

    /** Synchronously admits work to the per-batch tail before returning to a callback caller. */
    private fun enqueueBatchManifestMutation(
        owner: WebRtcSecureOperationOwner,
        batchToken: BatchManifestGenerationToken,
        transferId: String,
        mutation: BatchManifestMutation,
        operation: suspend ExactOwnerBatchManifestAccess.() -> Unit,
    ): Deferred<Unit>? {
        val store = batchManifestStore ?: return null
        val worker = batchManifestMutationCoordinator.enqueue(
            token = batchToken,
            transferId = transferId,
            admission = BatchManifestMutationAdmission.REMOTE,
        ) {
            try {
                requireCurrentBatchMutation(batchToken, transferId, owner)
                ExactOwnerBatchManifestAccess(store, owner, transferId, batchToken).operation()
                requireCurrentBatchMutation(batchToken, transferId, owner)
            } catch (stale: StaleWebRtcFileTransferOwnerException) {
                throw stale
            } catch (stale: StaleBatchManifestGenerationException) {
                throw stale
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (cause: Exception) {
                val failure = cause as? BatchManifestMutationException
                    ?: BatchManifestMutationException(batchToken.batchId, transferId, mutation, cause)
                throw failure
            }
        }
        worker?.invokeOnCompletion { cause ->
            (cause as? BatchManifestMutationException)?.let(::recordBatchManifestMutationFailure)
        }
        return worker
    }

    private suspend fun runBatchManifestMutation(
        owner: WebRtcSecureOperationOwner,
        batchToken: BatchManifestGenerationToken,
        transferId: String,
        mutation: BatchManifestMutation,
        operation: suspend ExactOwnerBatchManifestAccess.() -> Unit,
    ) {
        val worker = enqueueBatchManifestMutation(owner, batchToken, transferId, mutation, operation)
            ?: if (batchManifestStore == null) {
                return
            } else {
                throw StaleBatchManifestGenerationException(batchToken.batchId, transferId)
            }
        worker.await()
    }

    /** Callback-driven persistence is admitted synchronously; typed failures remain observable. */
    private fun launchBatchManifestMutation(
        owner: WebRtcSecureOperationOwner,
        batchToken: BatchManifestGenerationToken,
        transferId: String,
        mutation: BatchManifestMutation,
        operation: suspend ExactOwnerBatchManifestAccess.() -> Unit,
    ) {
        enqueueBatchManifestMutation(owner, batchToken, transferId, mutation, operation)
    }

    private fun recordBatchManifestMutationFailure(failure: BatchManifestMutationException) {
        _batchManifestFailure.value = failure
        _progress.value = Progress(
            transferId = failure.transferId,
            lastStatus = buildString {
                append(requireNotNull(failure.message))
                failure.cause?.let { cause ->
                    append(": ")
                    append(cause.javaClass.simpleName)
                    cause.message?.let { append(": $it") }
                }
            },
        )
    }

    data class Progress(
        val transferId: String? = null,
        val sentBytes: Long = 0L,
        val totalBytes: Long = 0L,
        val lastStatus: String? = null
    )

    private val _progress = MutableStateFlow(Progress())
    val progress: StateFlow<Progress> = _progress.asStateFlow()
    private val _batchManifestFailure = MutableStateFlow<BatchManifestMutationException?>(null)
    val batchManifestFailure: StateFlow<BatchManifestMutationException?> =
        _batchManifestFailure.asStateFlow()

    /**
     * Per-file progress inside a batch (leaf-node observable value; no UI restructuring).
     *
     * [status] mirrors the batch manifest entry lifecycle so a single file's failure inside a
     * batch is isolated (FAILED) while the rest of the batch keeps going.
     */
    data class BatchFileProgress(
        val transferId: String,
        val batchIndex: Int?,
        val relativePath: String?,
        val fileName: String?,
        val totalBytes: Long,
        val confirmedBytes: Long = 0L,
        val status: BatchManifestEntry.Status = BatchManifestEntry.Status.PENDING
    )

    /**
     * Overall progress of the most recently started batch, exposed for the UI to observe as a
     * leaf value. Aggregates per-file byte progress across all entries (Requirement 5.8) and
     * surfaces per-file success/failure results (Requirement 5.13).
     */
    data class BatchProgress(
        val batchId: String? = null,
        val batchTotal: Int? = null,
        val files: List<BatchFileProgress> = emptyList()
    ) {
        /** Sum of every file's total bytes in the batch. */
        val totalBytes: Long get() = files.sumOf { it.totalBytes }

        /** Sum of every file's confirmed (delivered) bytes in the batch. */
        val confirmedBytes: Long get() = files.sumOf { it.confirmedBytes }

        /** Overall batch progress as confirmed-bytes / total-bytes in [0.0, 1.0]. */
        val fraction: Double
            get() = if (totalBytes <= 0L) 0.0 else (confirmedBytes.toDouble() / totalBytes.toDouble()).coerceIn(0.0, 1.0)

        val completedCount: Int get() = files.count { it.status == BatchManifestEntry.Status.COMPLETED }

        val failedCount: Int
            get() = files.count {
                it.status == BatchManifestEntry.Status.FAILED || it.status == BatchManifestEntry.Status.CANCELLED
            }

        /** True once every file in the batch has reached a terminal state (completed/failed/cancelled). */
        val isTerminal: Boolean
            get() = files.isNotEmpty() && files.all {
                it.status == BatchManifestEntry.Status.COMPLETED ||
                    it.status == BatchManifestEntry.Status.FAILED ||
                    it.status == BatchManifestEntry.Status.CANCELLED
            }
    }

    private val _batchProgress = MutableStateFlow(BatchProgress())
    val batchProgress: StateFlow<BatchProgress> = _batchProgress.asStateFlow()

    /** Live batch progress keyed by batchId so late acks can update the aggregate. */
    private val batchProgressByBatchId = ConcurrentHashMap<String, BatchProgress>()

    /** One item to transfer as part of an in-memory batch (used for tests and programmatic sends). */
    data class BatchBytesItem(
        val fileName: String,
        val bytes: ByteArray,
        val relativePath: String,
        val mimeType: String = "application/octet-stream"
    )

    private data class BatchSendPlan(
        val transferId: String,
        val batchIndex: Int,
        val relativePath: String,
        val fileName: String,
        val totalBytes: Long,
        val send: suspend (WebRtcSecureOperationOwner, BatchManifestGenerationToken) -> Unit
    )

    private val rxBytes = AtomicLong(0L)
    data class ReceivedFile(
        val transferId: String,
        val fileName: String?,
        val mimeType: String?,
        val bytes: ByteArray? = null,
        val localPath: String? = null,
        val downloadsUri: String? = null,
        val downloadsDisplayName: String? = null
    )

    private val _receivedFiles = MutableSharedFlow<ReceivedFile>(extraBufferCapacity = 8)
    val receivedFiles: SharedFlow<ReceivedFile> = _receivedFiles

    private data class ReceiveContext(
        val owner: WebRtcSecureOperationOwner,
        val batchToken: BatchManifestGenerationToken?,
        val metadata: CrossNetworkFileTransferValidator.Metadata,
        val transferId: String,
        val version: Int,
        val authenticatedSenderDeviceId: String?,
        val senderDeviceId: String?,
        val senderDeviceName: String?,
        val fileName: String?,
        val mimeType: String?,
        val totalBytes: Long?,
        val chunkSize: Int?,
        val totalChunks: Int?,
        var partialFile: File?,
        var raf: RandomAccessFile?,
        var receivedBytes: Long = 0L
    ) {
        val buffer = ByteArrayOutputStream()
        var nextExpectedChunkIndex: Int = 0
        val pendingChunks: MutableMap<Int, ByteArray> = HashMap()
        var pendingChunkBytes: Long = 0L
        val receivedChunkIndices: MutableSet<Int> = HashSet()
        var completeReceived: Boolean = false
        var completeReceivedBytes: Long? = null
        var completeReceivedAtMs: Long = 0L
        var expectedFileSha256: ByteArray? = null
        var expectedMerkleRoot: ByteArray? = null
        var expectedMerkleSig: ByteArray? = null
        var expectedMerkleSigAlg: String? = null
        val chunkHashes: MutableMap<Int, ByteArray> = HashMap()

        @Volatile
        var approvalDecision: InboundFileTransferDecision? = null

        @Volatile
        var declined: Boolean = false

        @Volatile
        var approvalJob: Job? = null
    }

    private val receiveContexts = ConcurrentHashMap<String, ReceiveContext>()

    private fun cleanupReceiveContext(
        context: ReceiveContext,
        deletePartialFile: Boolean,
    ): ReceiveResourceCleanupReport {
        context.approvalJob?.cancel()
        context.approvalJob = null
        val receiveFile = context.raf
        context.raf = null
        val partialFile = context.partialFile.takeIf { deletePartialFile }
        val report = ReceiveResourceCleanup.execute(
            transferId = context.transferId,
            closePartialFile = receiveFile?.let { file -> { file.close() } },
            deletePartialFile = partialFile?.let { file ->
                {
                    if (file.exists() && !file.delete() && file.exists()) {
                        throw IOException("partial file deletion returned false")
                    }
                }
            },
        )
        if (deletePartialFile && report.isSuccessful) {
            context.partialFile = null
        }
        context.pendingChunks.clear()
        context.pendingChunkBytes = 0L
        return report
    }

    private fun cleanupAwareStatus(
        baseStatus: String,
        cleanup: ReceiveResourceCleanupReport,
    ): String = if (cleanup.isSuccessful) {
        baseStatus
    } else {
        "$baseStatus; cleanup incomplete (${cleanup.failedStages.joinToString(",")}); " +
            "checkpoint retained for recovery"
    }

    private fun deleteCheckpointAfterSuccessfulCleanup(
        context: ReceiveContext,
        cleanup: ReceiveResourceCleanupReport,
    ) {
        if (cleanup.checkpointDisposition != ReceiveCleanupCheckpointDisposition.DELETE) return
        enqueueCheckpointMutation(context.transferId, context.owner, CheckpointMutation.DELETE) {
            delete(context.transferId)
        }
    }

    private data class SendContext(
        val owner: WebRtcSecureOperationOwner,
        val transferId: String,
        val totalChunks: Int,
        val totalBytes: Long,
        val chunks: List<ByteArray>
    ) {
        /**
         * Pure ordering / ack / delivery-decision state (Requirements 5.1, 5.10). A chunk is only
         * "delivered" once its `chunkAck` is recorded here; only un-acked chunks are resent; overall
         * "all delivered" (necessary, not sufficient) is [OrderedChunkDeliveryTracker.isAllDelivered].
         */
        val delivery: OrderedChunkDeliveryTracker = OrderedChunkDeliveryTracker(totalChunks)
    }

    private val sendContexts = ConcurrentHashMap<String, SendContext>()

    /**
     * Short-lived terminal witness for synchronous loopback/peer ACKs that can arrive while the
     * outbound send call is still unwinding. Entries expire promptly; this is not a transfer log.
     */
    private val recentlyAcknowledgedOwners =
        ConcurrentHashMap<String, WebRtcSecureOperationOwner>()

    /**
     * Exact secure owner of the checkpoint namespace for one transfer id.
     *
     * The persistent store is keyed only by transfer id. This in-memory binding prevents a queued
     * mutation from owner A from deleting or updating owner B's checkpoint when B reuses the same
     * transfer id. A checkpoint restored after process death has no live binding and therefore is
     * never resumed automatically; the user must start a fresh transfer under the new key epoch.
     */
    private val checkpointOwners = ConcurrentHashMap<String, WebRtcSecureOperationOwner>()

    private data class OwnedTransferJob(
        val owner: WebRtcSecureOperationOwner,
        val job: Job,
    )

    /** Per-transfer resend loop jobs, bound to the exact key epoch that created them. */
    private val resendJobs = ConcurrentHashMap<String, OwnedTransferJob>()

    /**
     * Last chunk/ack activity timestamp (epoch millis via [clockMs]) per active transfer. An entry's
     * presence marks the transfer as "watched" by the idle/interrupt watchdog; it is seeded when a
     * transfer starts and removed when the transfer reaches any terminal state. Every inbound
     * chunk/ack for the transfer refreshes the timestamp (Requirement 5.12).
     */
    private data class OwnedTransferActivity(
        val owner: WebRtcSecureOperationOwner,
        val lastActivityMs: Long,
    )

    private val activityByTransferId = ConcurrentHashMap<String, OwnedTransferActivity>()

    /** The single background idle/interrupt watchdog job (lazily started while transfers are live). */
    @Volatile
    private var idleWatchdogJob: Job? = null

    private data class BatchRef(
        val owner: WebRtcSecureOperationOwner,
        val batchToken: BatchManifestGenerationToken,
        val batchId: String,
        val batchIndex: Int? = null,
        val batchTotal: Int? = null,
        val relativePath: String? = null
    )
    private val sendBatchByTransferId = ConcurrentHashMap<String, BatchRef>()

    private fun captureSecureOwner(transferId: String): WebRtcSecureOperationOwner =
        webrtc.currentSecureOperationOwner()
            ?: throw StaleWebRtcFileTransferOwnerException(transferId)

    private fun requireCurrentOwner(
        transferId: String,
        owner: WebRtcSecureOperationOwner,
    ) {
        if (!webrtc.isCurrentSecureOperationOwner(owner)) {
            abandonStaleOperation(transferId, owner)
            throw StaleWebRtcFileTransferOwnerException(transferId)
        }
    }

    private fun bindCheckpointOwner(
        transferId: String,
        owner: WebRtcSecureOperationOwner,
    ) {
        requireCurrentOwner(transferId, owner)
        val previous = checkpointOwners.putIfAbsent(transferId, owner)
        if (previous != null && previous !== owner) {
            abandonStaleOperation(transferId, previous)
            throw StaleWebRtcFileTransferOwnerException(transferId)
        }
    }

    /** Used by the UI to avoid publishing a success state after a replacement or rekey. */
    fun isCurrentOperation(transferId: String): Boolean {
        val owner = checkpointOwners[transferId] ?: return false
        return webrtc.isCurrentSecureOperationOwner(owner)
    }

    fun isOperationAcknowledged(transferId: String): Boolean =
        recentlyAcknowledgedOwners.containsKey(transferId)

    private fun recordAcknowledgedOperation(
        transferId: String,
        owner: WebRtcSecureOperationOwner,
    ) {
        recentlyAcknowledgedOwners[transferId] = owner
        scope.launch {
            delay(RECENT_ACK_WITNESS_TTL_MS)
            recentlyAcknowledgedOwners.remove(transferId, owner)
        }
    }

    private fun publishSentCompleteIfUnacknowledged(
        transferId: String,
        owner: WebRtcSecureOperationOwner,
        sentBytes: Long,
        totalBytes: Long,
        status: String,
    ) {
        if (recentlyAcknowledgedOwners[transferId] === owner) return
        _progress.value = Progress(transferId, sentBytes, totalBytes, status)
    }

    /**
     * Drop only owner-local in-memory work. Checkpoint bytes remain available for an explicit fresh
     * restart, but no continuation is allowed to send, cancel, ACK, or commit through a new owner.
     */
    private fun abandonStaleOperation(
        transferId: String,
        owner: WebRtcSecureOperationOwner,
    ) {
        var receiveCleanup = ReceiveResourceCleanupReport(transferId)
        sendContexts[transferId]?.takeIf { it.owner === owner }?.let { context ->
            sendContexts.remove(transferId, context)
        }
        receiveContexts[transferId]?.takeIf { it.owner === owner }?.let { context ->
            if (receiveContexts.remove(transferId, context)) {
                context.declined = true
                receiveCleanup = cleanupReceiveContext(context, deletePartialFile = false)
            }
        }
        resendJobs[transferId]?.takeIf { it.owner === owner }?.let { ownedJob ->
            if (resendJobs.remove(transferId, ownedJob)) ownedJob.job.cancel()
        }
        activityByTransferId[transferId]?.takeIf { it.owner === owner }?.let { activity ->
            activityByTransferId.remove(transferId, activity)
        }
        sendBatchByTransferId[transferId]?.takeIf { it.owner === owner }?.let { batchRef ->
            sendBatchByTransferId.remove(transferId, batchRef)
        }
        if (checkpointOwners[transferId] === owner) {
            _progress.value = Progress(
                transferId = transferId,
                lastStatus = cleanupAwareStatus(
                    "transfer stopped: secure session replaced or rekeyed",
                    receiveCleanup,
                ),
            )
        }
    }

    suspend fun listPendingCheckpoints(): List<TransferCheckpoint> = checkpointStore.list()

    suspend fun listPendingBatches(): List<BatchManifest> =
        batchManifestStore?.list()?.filter { m ->
            m.entries.any { it.status == BatchManifestEntry.Status.PENDING || it.status == BatchManifestEntry.Status.IN_PROGRESS }
        } ?: emptyList()

    suspend fun deleteBatch(batchId: String) {
        val canonicalBatchId = CrossNetworkFileTransferValidator.canonicalBatchId(batchId)
        val token = batchManifestMutationCoordinator.tombstoneBatch(canonicalBatchId)
        val store = batchManifestStore ?: return
        val worker = requireNotNull(
            batchManifestMutationCoordinator.enqueue(
                token = token,
                transferId = null,
                admission = BatchManifestMutationAdmission.DELETE_BATCH,
            ) {
                val current = store.load(canonicalBatchId)
                // Delete every checkpoint before forgetting its local batch mapping.
                current?.entries.orEmpty().forEach { entry ->
                    enqueueLocalCheckpointDeletion(entry.transferId).awaitCompletion()
                    sendBatchByTransferId.remove(entry.transferId)
                }
                store.delete(canonicalBatchId)
                batchManifestMutationCoordinator.completeBatchDeletion(token)
            },
        )
        worker.await()
    }

    private suspend fun saveLocalBatchManifest(
        store: BatchManifestStore,
        manifest: BatchManifest,
    ) {
        store.save(manifest) { commit ->
            commit()
            true
        }
    }

    suspend fun deleteBatchEntry(batchId: String, transferId: String) {
        val canonicalBatchId = CrossNetworkFileTransferValidator.canonicalBatchId(batchId)
        val token = batchManifestMutationCoordinator.tombstoneEntry(canonicalBatchId, transferId)
            ?: return
        val store = batchManifestStore ?: return
        val worker = requireNotNull(
            batchManifestMutationCoordinator.enqueue(
                token = token,
                transferId = transferId,
                admission = BatchManifestMutationAdmission.DELETE_ENTRY,
            ) {
                val current = store.load(canonicalBatchId)
                enqueueLocalCheckpointDeletion(transferId).awaitCompletion()
                sendBatchByTransferId.remove(transferId)
                if (current == null) return@enqueue
                val existing = current.entries.firstOrNull { it.transferId == transferId }
                    ?: return@enqueue
                val alreadyTerminal = existing.status == BatchManifestEntry.Status.COMPLETED ||
                    existing.status == BatchManifestEntry.Status.FAILED ||
                    existing.status == BatchManifestEntry.Status.CANCELLED
                if (alreadyTerminal) return@enqueue
                val now = System.currentTimeMillis()
                val updatedEntries = current.entries.map { entry ->
                    if (entry.transferId == transferId) {
                        entry.copy(
                            status = BatchManifestEntry.Status.CANCELLED,
                            updatedAtMs = now,
                        )
                    } else {
                        entry
                    }
                }
                saveLocalBatchManifest(
                    store,
                    current.copy(entries = updatedEntries, updatedAtMs = now),
                )
            },
        )
        worker.await()
    }

    suspend fun resumeBatch(contentResolver: ContentResolver, batchId: String) {
        withContext(Dispatchers.IO) {
            val store = batchManifestStore ?: return@withContext
            val manifest = store.load(batchId) ?: return@withContext
            // Resume all SEND entries that still have checkpoints with sourceUri.
            for (e in manifest.entries) {
                val cp = checkpointStore.load(e.transferId) ?: continue
                if (cp.direction != TransferDirection.SEND) continue
                // Only attempt resume if we have enough info.
                if (cp.sourceUri.isNullOrBlank()) continue
                try {
                    resumeSend(contentResolver, e.transferId)
                } catch (stale: StaleWebRtcFileTransferOwnerException) {
                    _progress.value = Progress(
                        transferId = e.transferId,
                        lastStatus = "resume requires a fresh transfer after session replacement or rekey",
                    )
                }
            }
        }
    }

    suspend fun deleteCheckpoint(transferId: String) {
        withContext(Dispatchers.IO) {
            enqueueLocalCheckpointDeletion(transferId).awaitCompletion()
        }
    }

    /**
     * Resume a previously started SEND transfer using persisted checkpoint.
     * Requires `sourceUri` to be present and readable (persistable permission recommended).
     *
     * Resume is admitted only while the exact secure owner that created the checkpoint is still
     * current. A checkpoint surviving process death, reconnection, or rekey is recovery evidence,
     * not authority to send through a new peer/key epoch.
     */
    suspend fun resumeSend(contentResolver: ContentResolver, transferId: String) {
        withContext(Dispatchers.IO) {
            val owner = captureSecureOwner(transferId)
            if (checkpointOwners[transferId] !== owner) {
                throw StaleWebRtcFileTransferOwnerException(transferId)
            }
            val cp = checkpointStore.load(transferId) ?: return@withContext
            if (cp.direction != TransferDirection.SEND) return@withContext
            val uriStr = cp.sourceUri ?: return@withContext
            val uri = uriStr.toUri()
            val mime = cp.mimeType ?: contentResolver.getType(uri) ?: "application/octet-stream"
            resumeSendFromCheckpoint(
                owner = owner,
                checkpoint = cp,
                mimeType = mime,
                openStream = { contentResolver.openInputStream(uri) }
            )
        }
    }

    /**
     * Testable core of [resumeSend] with all Android URI plumbing lifted out.
     *
     * Resumes a SEND transfer from its persisted checkpoint. Chunks whose index is already present
     * in `ackedChunks` are NOT re-sent on the initial resume pass (Requirement 5.6: do not retransmit
     * already-confirmed chunks). A [SendContext] is registered (with `acked` pre-populated from the
     * checkpoint) so that the resend loop and any peer NACK (`missingChunks`) only ever retransmit
     * chunks that are still un-acked — the resume start point is the last acked boundary, never zero.
     *
     * This does NOT change the wire protocol.
     */
    internal suspend fun resumeSendFromCheckpoint(
        checkpoint: TransferCheckpoint,
        owner: WebRtcSecureOperationOwner,
        mimeType: String,
        openStream: () -> java.io.InputStream?
    ) {
        if (checkpointOwners[checkpoint.transferId] == null) {
            bindCheckpointOwner(checkpoint.transferId, owner)
        }
        if (checkpointOwners[checkpoint.transferId] !== owner) {
            throw StaleWebRtcFileTransferOwnerException(checkpoint.transferId)
        }
        requireCurrentOwner(checkpoint.transferId, owner)
        require(checkpoint.direction == TransferDirection.SEND) { "resume checkpoint is not a SEND" }
        val transferId = checkpoint.transferId
        val chunkSize = checkpoint.chunkSize ?: return
        val totalChunks = checkpoint.totalChunks ?: return
        val fileSize = requireNotNull(checkpoint.fileSize) { "send checkpoint missing fileSize" }
        CrossNetworkFileTransferValidator.validatedExpectedChunkCount(fileSize, chunkSize)
        val acked = checkpoint.ackedChunks.toSet()

        val meta = CrossNetworkFileTransferMessage(
            version = 1,
            op = CrossNetworkFileTransferOp.metadata,
            transferId = transferId,
            senderDeviceId = android.os.Build.MODEL,
            senderDeviceName = android.os.Build.MODEL,
            fileName = checkpoint.fileName ?: "file",
            fileSize = fileSize,
            chunkSize = chunkSize,
            totalChunks = totalChunks,
            mimeType = mimeType
        )
        val metadata = CrossNetworkFileTransferValidator.validateMetadata(meta)
        sendFt(owner, metadata.transferId, encode(meta))
        startIdleWatchdogFor(metadata.transferId, owner)
        _progress.value = Progress(metadata.transferId, 0, metadata.fileSize, "resume: sent metadata")

        val input = openStream() ?: return
        input.use { stream ->
            // Buffer chunks for resend only when the whole file fits the resend cache; for larger
            // files we stream once (no in-memory resend cache) — the resume start point still comes
            // from the checkpoint, not the cache.
            val bufferedChunks = if (fileSize <= MAX_RESEND_CACHE_BYTES) ArrayList<ByteArray>(totalChunks) else null
            val buf = ByteArray(chunkSize)
            var index = 0
            var sent = 0L
            val fileDigest = MessageDigest.getInstance("SHA-256")
            val chunkHashes = ArrayList<ByteArray>(totalChunks)
            while (true) {
                val n = stream.read(buf)
                if (n <= 0) break
                val chunkBytes = if (n == buf.size) buf else buf.copyOfRange(0, n)
                fileDigest.update(chunkBytes)
                chunkHashes.add(sha256(chunkBytes))
                bufferedChunks?.add(chunkBytes)
                if (!acked.contains(index)) {
                    sendChunk(owner, transferId, index, chunkBytes, receivedBytes = sent + n)
                }
                sent += n
                index += 1
            }

            // Register a send context so NACK-driven resend works after resume; pre-mark the chunks
            // the checkpoint already confirmed so they are never retransmitted unless the peer asks.
            if (bufferedChunks != null && bufferedChunks.size == totalChunks) {
                val sendCtx = SendContext(
                    owner = owner,
                    transferId = metadata.transferId,
                    totalChunks = totalChunks,
                    totalBytes = fileSize,
                    chunks = bufferedChunks
                )
                acked.forEach { ackedIndex ->
                    sendCtx.delivery.markDelivered(ackedIndex)
                }
                sendContexts[metadata.transferId] = sendCtx
            }

            val fileSha256 = fileDigest.digest()
            val merkleRoot = MerkleSha256.root(chunkHashes)
            val merkleSig = computeOutboundHmac(
                owner = owner,
                transferId = transferId,
                preimage =
                MerkleRootAuthV1.preimage(transferId = transferId, merkleRoot = merkleRoot, fileSha256 = fileSha256)
            )
            sendFt(
                owner,
                transferId,
                encode(
                    CrossNetworkFileTransferMessage(
                        version = 1,
                        op = CrossNetworkFileTransferOp.complete,
                        transferId = transferId,
                        receivedBytes = metadata.fileSize,
                        fileSha256 = fileSha256,
                        merkleRoot = merkleRoot,
                        merkleRootSignature = merkleSig,
                        merkleRootSignatureAlg = "hmac-sha256-session-v1"
                    )
                )
            )
        }

        startResendLoopIfNeeded(transferId, owner)
        publishSentCompleteIfUnacknowledged(
            transferId = transferId,
            owner = owner,
            sentBytes = metadata.fileSize,
            totalBytes = metadata.fileSize,
            status = "resume: sent complete",
        )
    }

    fun sendTestMetadata() {
        val transferId = UUID.randomUUID().toString()
        val owner = captureSecureOwner(transferId)
        val msg = CrossNetworkFileTransferMessage(
            version = 1,
            op = CrossNetworkFileTransferOp.metadata,
            transferId = transferId,
            senderDeviceId = android.os.Build.MODEL,
            senderDeviceName = android.os.Build.MODEL,
            fileName = "hello.txt",
            fileSize = 5,
            chunkSize = 16 * 1024,
            totalChunks = 1,
            mimeType = "text/plain",
            message = "hello-from-android"
        )
        sendFt(owner, transferId, encode(msg))
        _progress.value = Progress(transferId = msg.transferId, lastStatus = "sent metadata(test)")
    }

    /**
     * Send an in-memory "file" over the CrossNetwork protocol (metadata -> chunks -> complete).
     * Useful for interoperability testing before wiring document pickers/UI.
     */
    suspend fun sendBytesAsFile(
        transferId: String,
        fileName: String,
        mimeType: String = "application/octet-stream",
        bytes: ByteArray,
        chunkSize: Int = 16 * 1024,
        batchId: String? = null,
        batchIndex: Int? = null,
        batchTotal: Int? = null,
        relativePath: String? = null
    ) {
        val canonicalBatchId = batchId?.let(CrossNetworkFileTransferValidator::canonicalBatchId)
        val batchToken = canonicalBatchId?.let {
            batchManifestMutationCoordinator.joinRemoteBatch(it, transferId)
                ?: throw StaleBatchManifestGenerationException(it, transferId)
        }
        sendBytesAsFile(
            owner = captureSecureOwner(transferId),
            batchToken = batchToken,
            transferId = transferId,
            fileName = fileName,
            mimeType = mimeType,
            bytes = bytes,
            chunkSize = chunkSize,
            batchId = canonicalBatchId,
            batchIndex = batchIndex,
            batchTotal = batchTotal,
            relativePath = relativePath,
        )
    }

    private suspend fun sendBytesAsFile(
        owner: WebRtcSecureOperationOwner,
        batchToken: BatchManifestGenerationToken?,
        transferId: String,
        fileName: String,
        mimeType: String,
        bytes: ByteArray,
        chunkSize: Int,
        batchId: String?,
        batchIndex: Int?,
        batchTotal: Int?,
        relativePath: String?,
    ) {
        withContext(Dispatchers.IO) {
            requireCurrentOwner(transferId, owner)
            val totalBytes = bytes.size.toLong()
            require(totalBytes <= MAX_RESEND_CACHE_BYTES) {
                "in-memory file transfer exceeds resend cache limit"
            }
            val totalChunks = CrossNetworkFileTransferValidator.validatedExpectedChunkCount(totalBytes, chunkSize)
            val meta = CrossNetworkFileTransferMessage(
                version = 1,
                op = CrossNetworkFileTransferOp.metadata,
                transferId = transferId,
                senderDeviceId = android.os.Build.MODEL,
                senderDeviceName = android.os.Build.MODEL,
                fileName = fileName,
                fileSize = totalBytes,
                chunkSize = chunkSize,
                totalChunks = totalChunks,
                mimeType = mimeType,
                batchId = batchId,
                batchIndex = batchIndex,
                batchTotal = batchTotal,
                relativePath = relativePath
            )
            val metadata = CrossNetworkFileTransferValidator.validateMetadata(meta)
            bindCheckpointOwner(metadata.transferId, owner)

            val chunks = ArrayList<ByteArray>(totalChunks)
            run {
                var off = 0
                while (off < bytes.size) {
                    val end = kotlin.math.min(off + chunkSize, bytes.size)
                    chunks.add(bytes.copyOfRange(off, end))
                    off = end
                }
            }
            val sendCtx = SendContext(
                owner = owner,
                transferId = metadata.transferId,
                totalChunks = totalChunks,
                totalBytes = totalBytes,
                chunks = chunks
            )
            enqueueCheckpointMutation(metadata.transferId, owner, CheckpointMutation.SAVE) {
                save(
                    TransferCheckpoint.newSend(
                        transferId = metadata.transferId,
                        sourceUri = null,
                        fileName = metadata.fileName,
                        mimeType = mimeType,
                        fileSize = totalBytes,
                        chunkSize = chunkSize,
                        totalChunks = totalChunks
                    )
                )
            }.awaitCompletion()
            sendContexts[metadata.transferId] = sendCtx
            if (metadata.batchId != null) {
                sendBatchByTransferId[metadata.transferId] = BatchRef(
                    owner = owner,
                    batchToken = requireNotNull(batchToken),
                    batchId = metadata.batchId,
                    batchIndex = metadata.batchIndex,
                    batchTotal = metadata.batchTotal,
                    relativePath = metadata.relativePath,
                )
            }
            startIdleWatchdogFor(metadata.transferId, owner)

            sendFt(
                owner,
                metadata.transferId,
                encode(
                    meta.copy(
                        transferId = metadata.transferId,
                        fileName = metadata.fileName,
                        batchId = metadata.batchId,
                        batchIndex = metadata.batchIndex,
                        batchTotal = metadata.batchTotal,
                        relativePath = metadata.relativePath
                    )
                )
            )
            _progress.value = Progress(metadata.transferId, 0, totalBytes, "sent metadata")

            // send all chunks once
            val fileSha256 = sha256(bytes)
            val chunkHashes = chunks.map { sha256(it) }
            val merkleRoot = MerkleSha256.root(chunkHashes)
            val merkleSig = computeOutboundHmac(
                owner = owner,
                transferId = metadata.transferId,
                preimage = MerkleRootAuthV1.preimage(
                    transferId = metadata.transferId,
                    merkleRoot = merkleRoot,
                    fileSha256 = fileSha256,
                ),
            )
            chunks.forEachIndexed { index, chunkBytes ->
                sendChunk(owner, metadata.transferId, index, chunkBytes)
                val sentSoFar = kotlin.math.min(((index + 1).toLong() * chunkSize.toLong()), totalBytes)
                _progress.value = Progress(metadata.transferId, sentSoFar, totalBytes, "sent chunk#${index + 1}")
            }

            sendFt(
                owner,
                metadata.transferId,
                encode(
                    CrossNetworkFileTransferMessage(
                        version = 1,
                        op = CrossNetworkFileTransferOp.complete,
                        transferId = metadata.transferId,
                        receivedBytes = totalBytes,
                        fileSha256 = fileSha256,
                        merkleRoot = merkleRoot,
                        merkleRootSignature = merkleSig,
                        merkleRootSignatureAlg = "hmac-sha256-session-v1",
                        batchId = metadata.batchId,
                        batchIndex = metadata.batchIndex,
                        batchTotal = metadata.batchTotal,
                        relativePath = metadata.relativePath
                    )
                )
            )
            publishSentCompleteIfUnacknowledged(
                transferId = metadata.transferId,
                owner = owner,
                sentBytes = totalBytes,
                totalBytes = totalBytes,
                status = "sent complete",
            )

            startResendLoopIfNeeded(metadata.transferId, owner)
        }
    }

    suspend fun sendFile(
        contentResolver: ContentResolver,
        uri: Uri,
        transferId: String,
        fileName: String,
        mimeType: String?,
        chunkSize: Int = 64 * 1024,
        batchId: String? = null,
        batchIndex: Int? = null,
        batchTotal: Int? = null,
        relativePath: String? = null
    ) {
        val canonicalBatchId = batchId?.let(CrossNetworkFileTransferValidator::canonicalBatchId)
        val batchToken = canonicalBatchId?.let {
            batchManifestMutationCoordinator.joinRemoteBatch(it, transferId)
                ?: throw StaleBatchManifestGenerationException(it, transferId)
        }
        sendFile(
            owner = captureSecureOwner(transferId),
            batchToken = batchToken,
            contentResolver = contentResolver,
            uri = uri,
            transferId = transferId,
            fileName = fileName,
            mimeType = mimeType,
            chunkSize = chunkSize,
            batchId = canonicalBatchId,
            batchIndex = batchIndex,
            batchTotal = batchTotal,
            relativePath = relativePath,
        )
    }

    private suspend fun sendFile(
        owner: WebRtcSecureOperationOwner,
        batchToken: BatchManifestGenerationToken?,
        contentResolver: ContentResolver,
        uri: Uri,
        transferId: String,
        fileName: String,
        mimeType: String?,
        chunkSize: Int,
        batchId: String?,
        batchIndex: Int?,
        batchTotal: Int?,
        relativePath: String?,
    ) {
        withContext(Dispatchers.IO) {
            requireCurrentOwner(transferId, owner)
            val totalBytes = contentResolver.openAssetFileDescriptor(uri, "r")?.use { it.length } ?: -1L
            require(totalBytes >= 0L) { "file size is required for cross-network file transfer metadata" }
            val totalChunks = CrossNetworkFileTransferValidator.validatedExpectedChunkCount(totalBytes, chunkSize)
            val meta = CrossNetworkFileTransferMessage(
                version = 1,
                op = CrossNetworkFileTransferOp.metadata,
                transferId = transferId,
                senderDeviceId = android.os.Build.MODEL,
                senderDeviceName = android.os.Build.MODEL,
                fileName = fileName,
                fileSize = totalBytes,
                chunkSize = chunkSize,
                totalChunks = totalChunks,
                mimeType = mimeType ?: "application/octet-stream",
                batchId = batchId,
                batchIndex = batchIndex,
                batchTotal = batchTotal,
                relativePath = relativePath
            )
            val metadata = CrossNetworkFileTransferValidator.validateMetadata(meta)
            bindCheckpointOwner(metadata.transferId, owner)
            val input = contentResolver.openInputStream(uri) ?: error("openInputStream failed")
            input.use { stream ->
                val bufferedChunks = if (totalBytes <= MAX_RESEND_CACHE_BYTES) ArrayList<ByteArray>(totalChunks) else null
                enqueueCheckpointMutation(metadata.transferId, owner, CheckpointMutation.SAVE) {
                    save(
                        TransferCheckpoint.newSend(
                            transferId = metadata.transferId,
                            sourceUri = uri.toString(),
                            fileName = metadata.fileName,
                            mimeType = mimeType ?: "application/octet-stream",
                            fileSize = totalBytes,
                            chunkSize = chunkSize,
                            totalChunks = totalChunks
                        )
                    )
                }.awaitCompletion()
                startIdleWatchdogFor(metadata.transferId, owner)

                if (metadata.batchId != null) {
                    sendBatchByTransferId[metadata.transferId] = BatchRef(
                        owner = owner,
                        batchToken = requireNotNull(batchToken),
                        batchId = metadata.batchId,
                        batchIndex = metadata.batchIndex,
                        batchTotal = metadata.batchTotal,
                        relativePath = metadata.relativePath,
                    )
                }

                sendFt(
                    owner,
                    metadata.transferId,
                    encode(
                        meta.copy(
                            transferId = metadata.transferId,
                            fileName = metadata.fileName,
                            batchId = metadata.batchId,
                            batchIndex = metadata.batchIndex,
                            batchTotal = metadata.batchTotal,
                            relativePath = metadata.relativePath
                        )
                    )
                )
                _progress.value = Progress(metadata.transferId, 0, totalBytes, "sent metadata")

                val buf = ByteArray(chunkSize)
                var sent = 0L
                var index = 0
                val fileDigest = MessageDigest.getInstance("SHA-256")
                val chunkHashes = ArrayList<ByteArray>()
                while (true) {
                    val n = stream.read(buf)
                    if (n <= 0) break
                    val chunkBytes = if (n == buf.size) buf else buf.copyOfRange(0, n)
                    fileDigest.update(chunkBytes)
                    chunkHashes.add(sha256(chunkBytes))
                    bufferedChunks?.add(chunkBytes)
                    sendChunk(owner, metadata.transferId, index, chunkBytes, receivedBytes = sent + n)
                    sent += n
                    index += 1
                    _progress.value = Progress(metadata.transferId, sent, totalBytes, "sent chunk#$index")
                }

                if (sent != totalBytes) {
                    enqueueCheckpointMutation(metadata.transferId, owner, CheckpointMutation.DELETE) {
                        delete(metadata.transferId)
                    }.awaitCompletion()
                    sendFt(
                        owner,
                        metadata.transferId,
                        encode(
                            CrossNetworkFileTransferMessage(
                                version = 1,
                                op = CrossNetworkFileTransferOp.error,
                                transferId = metadata.transferId,
                                message = "file stream length mismatch"
                            )
                        )
                    )
                    error("file stream length mismatch: expected $totalBytes bytes, read $sent bytes")
                }

                if (bufferedChunks != null) {
                    require(bufferedChunks.size == totalChunks) { "file chunk count mismatch" }
                    sendContexts[metadata.transferId] = SendContext(
                        owner = owner,
                        transferId = metadata.transferId,
                        totalChunks = totalChunks,
                        totalBytes = totalBytes,
                        chunks = bufferedChunks
                    )
                }

                val fileSha256 = fileDigest.digest()
                val merkleRoot = MerkleSha256.root(chunkHashes)
                val merkleSig = computeOutboundHmac(
                    owner = owner,
                    transferId = metadata.transferId,
                    preimage = MerkleRootAuthV1.preimage(
                        transferId = metadata.transferId,
                        merkleRoot = merkleRoot,
                        fileSha256 = fileSha256,
                    ),
                )
                val complete = CrossNetworkFileTransferMessage(
                    version = 1,
                    op = CrossNetworkFileTransferOp.complete,
                    transferId = metadata.transferId,
                    receivedBytes = sent,
                    fileSha256 = fileSha256,
                    merkleRoot = merkleRoot,
                    merkleRootSignature = merkleSig,
                    merkleRootSignatureAlg = "hmac-sha256-session-v1",
                    batchId = metadata.batchId,
                    batchIndex = metadata.batchIndex,
                    batchTotal = metadata.batchTotal,
                    relativePath = metadata.relativePath
                )
                sendFt(owner, metadata.transferId, encode(complete))
                publishSentCompleteIfUnacknowledged(
                    transferId = metadata.transferId,
                    owner = owner,
                    sentBytes = sent,
                    totalBytes = totalBytes,
                    status = "sent complete",
                )

                if (bufferedChunks != null) {
                    startResendLoopIfNeeded(metadata.transferId, owner)
                }
            }
        }
    }

    /**
     * Batch send helper (multiple files, optional directory semantics).
     * Emits one transfer per item, grouped by batchId. The batch fields
     * (batchId/batchIndex/batchTotal/relativePath) travel end-to-end on each item's
     * metadata/complete messages using the existing wire enum (no wire-protocol change).
     *
     * A single file's failure inside the batch is ISOLATED: that entry is marked FAILED in the
     * batch manifest and its resources are released, while the remaining files keep transferring
     * (Requirement 5.13). Overall progress is aggregated across the batch entries and exposed via
     * [batchProgress] (Requirement 5.8).
     */
    suspend fun sendFilesBatch(
        contentResolver: ContentResolver,
        items: List<Pair<Uri, String>>, // (uri, relativePathOrName)
        batchId: String = UUID.randomUUID().toString(),
        mimeTypeResolver: ((Uri) -> String?)? = null
    ) {
        withContext(Dispatchers.IO) {
            val canonicalBatchId = CrossNetworkFileTransferValidator.canonicalBatchId(batchId)
            val total = items.size
            require(total in 1..MAX_BATCH_FILES) { "batch file count out of range: $total" }
            val plans = items.mapIndexed { idx, (uri, rel) ->
                val name = rel.substringAfterLast('/').ifBlank { "file" }
                val mime = mimeTypeResolver?.invoke(uri) ?: contentResolver.getType(uri)
                val transferId = UUID.randomUUID().toString()
                val size = runCatching {
                    contentResolver.openAssetFileDescriptor(uri, "r")?.use { it.length } ?: -1L
                }.getOrDefault(-1L).coerceAtLeast(0L)
                BatchSendPlan(
                    transferId = transferId,
                    batchIndex = idx,
                    relativePath = rel,
                    fileName = name,
                    totalBytes = size,
                    send = { owner, batchToken ->
                        sendFile(
                            owner = owner,
                            batchToken = batchToken,
                            contentResolver = contentResolver,
                            uri = uri,
                            transferId = transferId,
                            fileName = name,
                            mimeType = mime,
                            chunkSize = 64 * 1024,
                            batchId = canonicalBatchId,
                            batchIndex = idx,
                            batchTotal = total,
                            relativePath = rel
                        )
                    }
                )
            }
            runBatchSend(canonicalBatchId, total, plans)
        }
    }

    /**
     * In-memory batch send (multiple files) with the same batch-field wiring, overall progress
     * aggregation and per-item failure isolation as [sendFilesBatch]. Useful for programmatic
     * sends and tests without a [ContentResolver]/[Uri].
     */
    suspend fun sendBytesAsFilesBatch(
        items: List<BatchBytesItem>,
        batchId: String = UUID.randomUUID().toString(),
        chunkSize: Int = 16 * 1024
    ) {
        withContext(Dispatchers.IO) {
            val canonicalBatchId = CrossNetworkFileTransferValidator.canonicalBatchId(batchId)
            val total = items.size
            require(total in 1..MAX_BATCH_FILES) { "batch file count out of range: $total" }
            val plans = items.mapIndexed { idx, item ->
                val transferId = UUID.randomUUID().toString()
                BatchSendPlan(
                    transferId = transferId,
                    batchIndex = idx,
                    relativePath = item.relativePath,
                    fileName = item.fileName,
                    totalBytes = item.bytes.size.toLong(),
                    send = { owner, batchToken ->
                        sendBytesAsFile(
                            owner = owner,
                            batchToken = batchToken,
                            transferId = transferId,
                            fileName = item.fileName,
                            mimeType = item.mimeType,
                            bytes = item.bytes,
                            chunkSize = chunkSize,
                            batchId = canonicalBatchId,
                            batchIndex = idx,
                            batchTotal = total,
                            relativePath = item.relativePath
                        )
                    }
                )
            }
            runBatchSend(canonicalBatchId, total, plans)
        }
    }

    /**
     * Drive a batch of [plans]: persist the batch manifest, publish an aggregated [BatchProgress],
     * and send each item independently. One item throwing marks only that entry FAILED and releases
     * its resources; the loop continues with the remaining items.
     */
    private suspend fun runBatchSend(canonicalBatchId: String, total: Int, plans: List<BatchSendPlan>) {
        val owner = captureSecureOwner(plans.first().transferId)
        val batchToken = batchManifestMutationCoordinator.beginOutboundBatch(
            canonicalBatchId,
            plans.map(BatchSendPlan::transferId),
        )
        val initialFiles = plans.map { plan ->
            BatchFileProgress(
                transferId = plan.transferId,
                batchIndex = plan.batchIndex,
                relativePath = plan.relativePath,
                fileName = plan.fileName,
                totalBytes = plan.totalBytes,
                confirmedBytes = 0L,
                status = BatchManifestEntry.Status.PENDING
            )
        }
        publishBatchProgress(BatchProgress(canonicalBatchId, total, initialFiles))

        try {
            persistInitialBatchManifest(owner, batchToken, total, plans)
            batchManifestMutationCoordinator.completeOutboundInitialization(batchToken)
        } catch (cause: Exception) {
            batchManifestMutationCoordinator.releaseFailedOutboundInitialization(batchToken)
            throw cause
        }

        for (plan in plans) {
            requireCurrentOwner(plan.transferId, owner)
            updateBatchFileStatus(canonicalBatchId, plan.transferId, BatchManifestEntry.Status.IN_PROGRESS)
            persistBatchEntryStatus(
                owner,
                batchToken,
                plan.transferId,
                BatchManifestEntry.Status.IN_PROGRESS,
            )
            try {
                requireCurrentBatchMutation(batchToken, plan.transferId, owner)
                plan.send(owner, batchToken)
            } catch (stale: StaleWebRtcFileTransferOwnerException) {
                throw stale
            } catch (stale: StaleBatchManifestGenerationException) {
                throw stale
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                requireCurrentOwner(plan.transferId, owner)
                // Isolate this file's failure: mark FAILED, release its resources, keep going.
                updateBatchFileStatus(canonicalBatchId, plan.transferId, BatchManifestEntry.Status.FAILED)
                persistBatchEntryStatus(
                    owner,
                    batchToken,
                    plan.transferId,
                    BatchManifestEntry.Status.FAILED,
                )
                if (checkpointOwners[plan.transferId] === owner) {
                    releaseTransferResources(plan.transferId, owner)
                }
            }
        }
    }

    private fun publishBatchProgress(progress: BatchProgress) {
        val bid = progress.batchId
        if (bid != null) {
            batchProgressByBatchId[bid] = progress
        }
        _batchProgress.value = progress
    }

    /** Update a file's status (and, for terminal states, confirmed bytes) inside the live batch. */
    private fun updateBatchFileStatus(
        batchId: String,
        transferId: String,
        status: BatchManifestEntry.Status
    ) {
        val updated = batchProgressByBatchId.computeIfPresent(batchId) { _, progress ->
            progress.copy(
                files = progress.files.map { f ->
                    if (f.transferId != transferId) {
                        f
                    } else {
                        val confirmed = if (status == BatchManifestEntry.Status.COMPLETED) f.totalBytes else f.confirmedBytes
                        f.copy(status = status, confirmedBytes = confirmed)
                    }
                }
            )
        } ?: return
        if (_batchProgress.value.batchId == batchId) {
            _batchProgress.value = updated
        }
    }

    private suspend fun persistInitialBatchManifest(
        owner: WebRtcSecureOperationOwner,
        batchToken: BatchManifestGenerationToken,
        total: Int,
        plans: List<BatchSendPlan>,
    ) {
        runBatchManifestMutation(
            owner = owner,
            batchToken = batchToken,
            transferId = plans.first().transferId,
            mutation = BatchManifestMutation.INITIALIZE,
        ) {
            check(load(batchToken.batchId) == null) {
                "batch manifest already exists for ${batchToken.batchId}"
            }
            save(
                BatchManifest(
                    batchId = batchToken.batchId,
                    batchTotal = total,
                    entries = plans.map { plan ->
                        BatchManifestEntry(
                            transferId = plan.transferId,
                            batchIndex = plan.batchIndex,
                            relativePath = plan.relativePath,
                            fileName = plan.fileName,
                            fileSize = plan.totalBytes,
                            status = BatchManifestEntry.Status.PENDING,
                            updatedAtMs = System.currentTimeMillis(),
                        )
                    },
                ),
            )
        }
    }

    private suspend fun persistBatchEntryStatus(
        owner: WebRtcSecureOperationOwner,
        batchToken: BatchManifestGenerationToken,
        transferId: String,
        status: BatchManifestEntry.Status,
    ) {
        runBatchManifestMutation(
            owner = owner,
            batchToken = batchToken,
            transferId = transferId,
            mutation = BatchManifestMutation.UPDATE_STATUS,
        ) {
            transitionBatchEntry(this, batchToken.batchId, transferId, status)
        }
    }

    private fun launchPersistBatchEntryStatus(
        owner: WebRtcSecureOperationOwner,
        batchToken: BatchManifestGenerationToken,
        transferId: String,
        status: BatchManifestEntry.Status,
    ) {
        launchBatchManifestMutation(
            owner = owner,
            batchToken = batchToken,
            transferId = transferId,
            mutation = BatchManifestMutation.UPDATE_STATUS,
        ) {
            transitionBatchEntry(this, batchToken.batchId, transferId, status)
        }
    }

    private fun launchReceiveBatchEntryStatus(
        context: ReceiveContext,
        status: BatchManifestEntry.Status,
    ) {
        context.batchToken?.let { token ->
            launchPersistBatchEntryStatus(
                owner = context.owner,
                batchToken = token,
                transferId = context.transferId,
                status = status,
            )
        }
    }

    private suspend fun transitionBatchEntry(
        access: ExactOwnerBatchManifestAccess,
        batchId: String,
        transferId: String,
        requested: BatchManifestEntry.Status,
    ) {
        val current = requireNotNull(access.load(batchId)) { "batch manifest missing for $batchId" }
        val existing = requireNotNull(current.entries.firstOrNull { it.transferId == transferId }) {
            "batch manifest entry missing for $transferId"
        }
        val next = nextRemoteBatchStatus(transferId, existing.status, requested) ?: return
        val now = System.currentTimeMillis()
        val updated = current.entries.map { entry ->
            if (entry.transferId == transferId) entry.copy(status = next, updatedAtMs = now) else entry
        }
        access.save(current.copy(entries = updated, updatedAtMs = now))
    }

    private fun nextRemoteBatchStatus(
        transferId: String,
        current: BatchManifestEntry.Status,
        requested: BatchManifestEntry.Status,
    ): BatchManifestEntry.Status? {
        if (current == requested) return null
        val terminal = current == BatchManifestEntry.Status.COMPLETED ||
            current == BatchManifestEntry.Status.FAILED ||
            current == BatchManifestEntry.Status.CANCELLED
        if (terminal) throw BatchManifestTransitionException(transferId, current, requested)
        val allowed = when (current) {
            BatchManifestEntry.Status.PENDING -> requested == BatchManifestEntry.Status.IN_PROGRESS ||
                requested == BatchManifestEntry.Status.COMPLETED ||
                requested == BatchManifestEntry.Status.FAILED ||
                requested == BatchManifestEntry.Status.CANCELLED
            BatchManifestEntry.Status.IN_PROGRESS -> requested == BatchManifestEntry.Status.COMPLETED ||
                requested == BatchManifestEntry.Status.FAILED ||
                requested == BatchManifestEntry.Status.CANCELLED
        }
        if (!allowed) throw BatchManifestTransitionException(transferId, current, requested)
        return requested
    }

    fun handleIncoming(
        owner: WebRtcSecureOperationOwner,
        bytes: ByteArray,
    ) {
        rxBytes.addAndGet(bytes.size.toLong())
        val msg = runCatching {
            CrossNetworkFileTransferWireCodec.decode(bytes)
        }.getOrElse {
            if (webrtc.isCurrentSecureOperationOwner(owner)) {
                _progress.value = Progress(lastStatus = "rejected inbound file transfer: invalid payload")
            }
            return
        }

        if (!webrtc.isCurrentSecureOperationOwner(owner)) {
            abandonStaleOperation(msg.transferId, owner)
            return
        }

        // Any chunk/ack (or other) message for a watched transfer counts as activity and resets the
        // idle/interrupt watchdog (Requirement 5.12). No-op for transfers not currently watched.
        markTransferActivity(msg.transferId, owner)

        when (msg.op) {
            CrossNetworkFileTransferOp.metadata -> {
                val metadata = runCatching {
                    CrossNetworkFileTransferValidator.validateMetadata(msg)
                }.getOrElse { err ->
                    rejectInboundMessage(owner, msg, err.message ?: "invalid metadata")
                    return
                }
                val batchToken = metadata.batchId?.let { batchId ->
                    batchManifestMutationCoordinator.joinRemoteBatch(batchId, metadata.transferId)
                }
                if (metadata.batchId != null && batchToken == null) {
                    rejectInboundMessage(owner, msg, "batch was deleted locally")
                    return
                }
                // Idempotent: if already tracking, just ACK (supports resume).
                val existingContext = receiveContexts[metadata.transferId]
                if (existingContext?.owner === owner) {
                    sendFt(
                        owner,
                        metadata.transferId,
                        encode(
                            CrossNetworkFileTransferMessage(
                                version = msg.version,
                                op = CrossNetworkFileTransferOp.metadataAck,
                                transferId = metadata.transferId,
                                receivedBytes = metadata.fileSize
                            )
                        )
                    )
                    return
                }
                if (existingContext != null) {
                    abandonStaleOperation(metadata.transferId, existingContext.owner)
                }

                val existingCp = try {
                    runBlocking(Dispatchers.IO) { checkpointStore.load(metadata.transferId) }
                } catch (e: Exception) {
                    rejectInboundMessage(owner, msg, "checkpoint load failed: ${e.javaClass.simpleName}")
                    return
                }
                if (existingCp != null && checkpointOwners[metadata.transferId] !== owner) {
                    rejectInboundMessage(owner, msg, "checkpoint belongs to a previous secure owner")
                    return
                }
                bindCheckpointOwner(metadata.transferId, owner)
                try {
                    existingCp?.validateReceiveCheckpoint(metadata)
                } catch (e: Exception) {
                    rejectInboundMessage(owner, msg, "checkpoint metadata mismatch: ${e.message ?: e.javaClass.simpleName}")
                    return
                }
                val authenticatedSenderDeviceId = webrtc.authenticatedPeerDeviceId()
                if (!webrtc.isCurrentSecureOperationOwner(owner)) {
                    abandonStaleOperation(metadata.transferId, owner)
                    return
                }
                val existingPartial = existingCp?.partialPath?.let { p ->
                    val f = File(p)
                    if (f.exists()) f else null
                }
                val preloadReceivedChunks = existingCp?.receivedChunks?.toSet().orEmpty()

                val partialDir = appContext?.let {
                    File(it.applicationContext.filesDir, "skybridge_inbound_partials").apply { mkdirs() }
                }
                if (partialDir == null && metadata.fileSize > MAX_IN_MEMORY_RECEIVE_BYTES) {
                    rejectInboundMessage(owner, msg, "in-memory receive exceeds supported range")
                    return
                }
                val partialFile = existingPartial ?: partialDir?.let { File(it, "${metadata.transferId}.partial") }
                val raf = partialFile?.let { RandomAccessFile(it, "rw") }

                val ctx = ReceiveContext(
                    owner = owner,
                    batchToken = batchToken,
                    metadata = metadata,
                    transferId = metadata.transferId,
                    version = msg.version,
                    authenticatedSenderDeviceId = authenticatedSenderDeviceId,
                    senderDeviceId = msg.senderDeviceId,
                    senderDeviceName = msg.senderDeviceName,
                    fileName = metadata.fileName,
                    mimeType = msg.mimeType,
                    totalBytes = metadata.fileSize,
                    chunkSize = metadata.chunkSize,
                    totalChunks = metadata.totalChunks,
                    partialFile = partialFile,
                    raf = raf,
                    receivedBytes = partialFile?.length() ?: 0L
                )
                receiveContexts[metadata.transferId] = ctx
                // Watch this receive for idle/interrupt timeout (Requirement 5.12).
                startIdleWatchdogFor(metadata.transferId, owner)
                // preload received chunks if we have them (resume after restart)
                ctx.receivedChunkIndices.addAll(preloadReceivedChunks)
                try {
                    restoreContiguousReceiveProgress(ctx, existingCp, existingPartial)
                } catch (e: Exception) {
                    receiveContexts.remove(metadata.transferId, ctx)
                    val cleanup = cleanupReceiveContext(ctx, deletePartialFile = false)
                    rejectInboundMessage(
                        owner,
                        msg,
                        cleanupAwareStatus(
                            "checkpoint resume failed: ${e.message ?: e.javaClass.simpleName}",
                            cleanup,
                        ),
                    )
                    return
                }

                // Batch manifest persistence is bound to the exact inbound key epoch.
                val bid = metadata.batchId
                if (bid != null && batchToken != null) {
                    launchBatchManifestMutation(
                        owner = owner,
                        batchToken = batchToken,
                        transferId = metadata.transferId,
                        mutation = BatchManifestMutation.MERGE_INBOUND,
                    ) {
                        if (receiveContexts[metadata.transferId] === ctx) {
                            val current = load(bid)
                            if (receiveContexts[metadata.transferId] === ctx) {
                                val existing = current?.entries?.firstOrNull {
                                    it.transferId == metadata.transferId
                                }
                                if (existing != null) {
                                    check(existing.batchIndex == metadata.batchIndex)
                                    check(existing.relativePath == metadata.relativePath)
                                    check(existing.fileName == metadata.fileName)
                                    check(existing.fileSize == metadata.fileSize)
                                }
                                val terminal = existing?.status == BatchManifestEntry.Status.COMPLETED ||
                                    existing?.status == BatchManifestEntry.Status.FAILED ||
                                    existing?.status == BatchManifestEntry.Status.CANCELLED
                                if (!terminal) {
                                    val existingEntries = current?.entries.orEmpty()
                                        .associateBy { it.transferId }
                                        .toMutableMap()
                                    existingEntries[metadata.transferId] = BatchManifestEntry(
                                        transferId = metadata.transferId,
                                        batchIndex = metadata.batchIndex,
                                        relativePath = metadata.relativePath,
                                        fileName = metadata.fileName,
                                        fileSize = metadata.fileSize,
                                        status = BatchManifestEntry.Status.IN_PROGRESS,
                                        updatedAtMs = System.currentTimeMillis(),
                                    )
                                    val merged = BatchManifest(
                                        batchId = bid,
                                        batchTotal = metadata.batchTotal ?: current?.batchTotal,
                                        entries = existingEntries.values.sortedWith(
                                            compareBy({ it.batchIndex ?: Int.MAX_VALUE }, { it.transferId }),
                                        ),
                                        createdAtMs = current?.createdAtMs ?: System.currentTimeMillis(),
                                        updatedAtMs = System.currentTimeMillis(),
                                    )
                                    if (receiveContexts[metadata.transferId] === ctx) save(merged)
                                }
                            }
                        }
                    }
                }
                enqueueCheckpointMutation(metadata.transferId, owner, CheckpointMutation.SAVE) {
                    save(
                        TransferCheckpoint.newReceive(
                            transferId = metadata.transferId,
                            partialPath = partialFile?.absolutePath,
                            fileName = metadata.fileName,
                            mimeType = msg.mimeType,
                            fileSize = metadata.fileSize,
                            chunkSize = metadata.chunkSize,
                            totalChunks = metadata.totalChunks
                        )
                    )
                }

                // Start approval flow (app-provided). Until approved, we will not emit a completed file.
                startInboundApprovalIfNeeded(ctx)

                // ack metadata (best-effort)
                sendFt(
                    owner,
                    metadata.transferId,
                    encode(
                        CrossNetworkFileTransferMessage(
                            version = msg.version,
                            op = CrossNetworkFileTransferOp.metadataAck,
                            transferId = metadata.transferId,
                            receivedBytes = metadata.fileSize
                        )
                    )
                )
            }
            CrossNetworkFileTransferOp.chunk -> {
                val ctx = receiveContexts[msg.transferId]?.takeIf { it.owner === owner }
                if (ctx?.declined == true) return
                if (ctx == null) return
                val actualHash = msg.chunkData?.let { sha256(it) }
                val chunkData = runCatching {
                    CrossNetworkFileTransferValidator.validateChunk(msg, ctx.metadata, actualHash)
                }.getOrElse { err ->
                    rejectReceive(ctx, err.message ?: "invalid chunk")
                    return
                }
                val chunkIndex = requireNotNull(msg.chunkIndex)
                val verifiedHash = requireNotNull(actualHash)

                ctx.chunkHashes[chunkIndex] = verifiedHash
                // tolerate out-of-order + duplicates: buffer by index, then flush contiguous window
                if (chunkIndex >= ctx.nextExpectedChunkIndex && !ctx.pendingChunks.containsKey(chunkIndex)) {
                    val pendingBytes = ctx.pendingChunkBytes + chunkData.size.toLong()
                    if (pendingBytes > MAX_PENDING_CHUNK_BYTES) {
                        rejectReceive(ctx, "pending chunk window exceeded")
                        return
                    }
                    ctx.pendingChunks[chunkIndex] = chunkData
                    ctx.pendingChunkBytes = pendingBytes
                }
                ctx.receivedChunkIndices.add(chunkIndex)
                while (true) {
                    if (!webrtc.isCurrentSecureOperationOwner(owner) || receiveContexts[ctx.transferId] !== ctx) {
                        abandonStaleOperation(ctx.transferId, owner)
                        return
                    }
                    val next = ctx.pendingChunks.remove(ctx.nextExpectedChunkIndex) ?: break
                    ctx.pendingChunkBytes = (ctx.pendingChunkBytes - next.size.toLong()).coerceAtLeast(0L)
                    val cs = ctx.chunkSize ?: next.size
                    val offset = ctx.nextExpectedChunkIndex.toLong() * cs.toLong()
                    if (ctx.raf != null) {
                        try {
                            ctx.raf?.seek(offset)
                            ctx.raf?.write(next)
                        } catch (e: Exception) {
                            rejectReceive(ctx, "partial file write failed: ${e.javaClass.simpleName}")
                            return
                        }
                    } else {
                        ctx.buffer.write(next)
                    }
                    ctx.receivedBytes = maxOf(ctx.receivedBytes, offset + next.size.toLong())
                    ctx.nextExpectedChunkIndex += 1
                }

                enqueueCheckpointMutation(ctx.transferId, owner, CheckpointMutation.UPDATE) {
                    val existing = load(ctx.transferId)
                    if (existing != null) {
                        val merged = (existing.receivedChunks.toList() + listOf(chunkIndex)).distinct().sorted().toIntArray()
                        save(
                            existing.copy(
                                receivedChunks = merged,
                                receivedChunkSha256HexByIndex = existing.receivedChunkSha256HexByIndex +
                                    (chunkIndex to verifiedHash.toHex())
                            )
                        )
                    }
                }

                // If sender already signaled "complete" but we were missing chunks, finalize once complete.
                if (ctx.completeReceived) {
                    val totalChunks = ctx.totalChunks
                    if (totalChunks != null && totalChunks > 0 && ctx.receivedChunkIndices.size == totalChunks) {
                        maybeFinalizeIfReady(ctx)
                    }
                }

                sendFt(
                    owner,
                    ctx.transferId,
                    encode(
                        CrossNetworkFileTransferMessage(
                            version = msg.version,
                            op = CrossNetworkFileTransferOp.chunkAck,
                            transferId = msg.transferId,
                            chunkIndex = chunkIndex,
                            rawSize = msg.rawSize,
                            receivedBytes = msg.receivedBytes
                        )
                    )
                )
            }
            CrossNetworkFileTransferOp.complete -> {
                val ctx = receiveContexts[msg.transferId]?.takeIf { it.owner === owner }
                if (ctx != null) {
                    runCatching {
                        CrossNetworkFileTransferValidator.validateComplete(msg, ctx.metadata)
                    }.onFailure { err ->
                        rejectReceive(ctx, err.message ?: "invalid complete")
                        return
                    }
                    ctx.completeReceived = true
                    ctx.completeReceivedBytes = msg.receivedBytes
                    ctx.completeReceivedAtMs = System.currentTimeMillis()
                    ctx.expectedFileSha256 = msg.fileSha256
                    ctx.expectedMerkleRoot = msg.merkleRoot
                    ctx.expectedMerkleSig = msg.merkleRootSignature
                    ctx.expectedMerkleSigAlg = msg.merkleRootSignatureAlg

                    val totalChunks = ctx.totalChunks
                    if (totalChunks != null && totalChunks > 0 && ctx.receivedChunkIndices.size != totalChunks) {
                        val missing = (0 until totalChunks).filterNot { ctx.receivedChunkIndices.contains(it) }
                        _progress.value = Progress(
                            transferId = ctx.transferId,
                            sentBytes = ctx.buffer.size().toLong(),
                            totalBytes = ctx.totalBytes ?: 0L,
                            lastStatus = "waiting missing chunks: ${missing.take(16)}${if (missing.size > 16) "..." else ""}"
                        )

                        // Optional NACK: ask sender to resend missing chunks (backward compatible).
                        sendFt(
                            owner,
                            ctx.transferId,
                            encode(
                                CrossNetworkFileTransferMessage(
                                    version = msg.version,
                                    op = CrossNetworkFileTransferOp.chunkAck,
                                    transferId = msg.transferId,
                                    missingChunks = missing.take(512).toIntArray(),
                                    message = "missingChunks"
                                )
                            )
                        )

                        // Safety for iOS/mac interop: do NOT proactively send op=error here.
                        // We just keep receiving; if sender retries/resends, we'll finalize once complete.
                        scope.launch {
                            delay(missingChunkReceiveTimeoutMs)
                            val still = receiveContexts[ctx.transferId]
                            if (
                                still === ctx &&
                                still.owner === owner &&
                                webrtc.isCurrentSecureOperationOwner(owner) &&
                                still.completeReceived &&
                                still.completeReceivedAtMs == ctx.completeReceivedAtMs
                            ) {
                                val tc = still.totalChunks
                                val ok = (tc == null) || (still.receivedChunkIndices.size == tc)
                                if (!ok) {
                                    // Best-effort final NACK before we give up.
                                    val tcNonNull = tc // smart-cast: !ok implies tc != null
                                    if (tcNonNull > 0) {
                                        val missing2 = (0 until tcNonNull).filterNot { still.receivedChunkIndices.contains(it) }
                                        runCatching {
                                            sendFt(
                                                owner,
                                                still.transferId,
                                                encode(
                                                    CrossNetworkFileTransferMessage(
                                                        version = msg.version,
                                                        op = CrossNetworkFileTransferOp.chunkAck,
                                                        transferId = msg.transferId,
                                                        missingChunks = missing2.take(512).toIntArray(),
                                                        message = "missingChunks(timeout)"
                                                    )
                                                )
                                            )
                                        }
                                    }
                                    cleanupTimedOutReceive(still)
                                }
                            } else if (still === ctx && still.owner === owner) {
                                abandonStaleOperation(ctx.transferId, owner)
                            }
                        }
                        return
                    }

                    maybeFinalizeIfReady(ctx)
                }
            }
            CrossNetworkFileTransferOp.chunkAck -> {
                val transferId = msg.transferId
                val idx = msg.chunkIndex
                val missing = msg.missingChunks

                if (missing != null && missing.isNotEmpty()) {
                    val ctx = sendContexts[transferId]?.takeIf { it.owner === owner }
                    if (ctx != null) {
                        // Peer reported these chunks missing: flip them back to un-delivered and
                        // retransmit only the ones still under the attempt ceiling. Chunks the peer
                        // did NOT list stay acked and are never resent (Requirement 5.10).
                        missing.forEach { mi ->
                            if (ctx.delivery.markUndelivered(mi) &&
                                ctx.delivery.attemptsFor(mi) < NACK_RESEND_MAX_ATTEMPTS
                            ) {
                                if (!tryResendChunk(ctx, mi)) return
                            }
                        }
                        // Re-send complete to prompt finalize (receiver enforces integrity if present).
                        if (!tryResendComplete(ctx)) return
                    }
                }
                if (idx != null && idx >= 0) {
                    // A chunk becomes "delivered" ONLY when its chunkAck arrives (Requirement 5.10).
                    val ctx = sendContexts[transferId]?.takeIf { it.owner === owner } ?: return
                    ctx.delivery.markDelivered(idx)
                    enqueueCheckpointMutation(transferId, owner, CheckpointMutation.UPDATE) {
                        val existing = load(transferId)
                        if (existing != null) {
                            val merged = (existing.ackedChunks.toList() + listOf(idx)).distinct().sorted().toIntArray()
                            save(existing.copy(ackedChunks = merged))
                        }
                    }
                }
            }
            CrossNetworkFileTransferOp.completeAck -> {
                val contextOwner = sendContexts[msg.transferId]?.owner
                    ?: checkpointOwners[msg.transferId]
                if (contextOwner !== owner) return
                recordAcknowledgedOperation(msg.transferId, owner)
                // sender-side completion; stop tracking
                sendContexts[msg.transferId]?.takeIf { it.owner === owner }?.let { context ->
                    sendContexts.remove(msg.transferId, context)
                }
                stopIdleWatchdogFor(msg.transferId, owner)
                enqueueCheckpointMutation(msg.transferId, owner, CheckpointMutation.DELETE) {
                    delete(msg.transferId)
                }

                // If this transfer belongs to a batch, mark completed and advance overall progress.
                val ref = sendBatchByTransferId[msg.transferId]
                    ?.takeIf { it.owner === owner }
                if (ref != null) {
                    launchPersistBatchEntryStatus(
                        owner,
                        ref.batchToken,
                        msg.transferId,
                        BatchManifestEntry.Status.COMPLETED,
                    )
                    sendBatchByTransferId.remove(msg.transferId, ref)
                    updateBatchFileStatus(ref.batchId, msg.transferId, BatchManifestEntry.Status.COMPLETED)
                }
                _progress.value = Progress(
                    transferId = msg.transferId,
                    sentBytes = msg.receivedBytes ?: 0L,
                    totalBytes = msg.receivedBytes ?: 0L,
                    lastStatus = "send complete acknowledged",
                )
            }
            CrossNetworkFileTransferOp.error -> {
                val ctx = sendContexts[msg.transferId]?.takeIf { it.owner === owner }
                val receiveCtx = receiveContexts[msg.transferId]?.takeIf { it.owner === owner }
                if (ctx == null && receiveCtx == null && checkpointOwners[msg.transferId] !== owner) return
                stopIdleWatchdogFor(msg.transferId, owner)
                if (ctx != null && sendContexts.remove(msg.transferId, ctx)) {
                    val ref = sendBatchByTransferId[msg.transferId]
                        ?.takeIf { it.owner === owner }
                    if (ref != null) {
                        // Isolate this batch item's failure; the rest of the batch is unaffected.
                        launchPersistBatchEntryStatus(
                            owner,
                            ref.batchToken,
                            msg.transferId,
                            BatchManifestEntry.Status.FAILED,
                        )
                        sendBatchByTransferId.remove(msg.transferId, ref)
                        updateBatchFileStatus(ref.batchId, msg.transferId, BatchManifestEntry.Status.FAILED)
                    }
                    enqueueCheckpointMutation(ctx.transferId, owner, CheckpointMutation.DELETE) {
                        delete(ctx.transferId)
                    }
                }
                val receiveCleanup = receiveCtx?.let {
                    launchReceiveBatchEntryStatus(it, BatchManifestEntry.Status.FAILED)
                    releaseTransferResources(msg.transferId, owner)
                } ?: ReceiveResourceCleanupReport(msg.transferId)
                _progress.value = Progress(
                    transferId = msg.transferId,
                    lastStatus = cleanupAwareStatus(
                        "peer error: ${msg.message ?: "unspecified"}",
                        receiveCleanup,
                    )
                )
            }
            CrossNetworkFileTransferOp.cancel -> {
                // Peer cancelled this transfer: stop send/receive for THIS transfer and release
                // its resources. cancel is part of the existing wire enum, so this is not a wire
                // protocol change. Do not echo another cancel back to the peer.
                val operationOwner = sendContexts[msg.transferId]?.owner
                    ?: receiveContexts[msg.transferId]?.owner
                    ?: checkpointOwners[msg.transferId]
                if (operationOwner !== owner) return
                sendBatchByTransferId[msg.transferId]
                    ?.takeIf { it.owner === owner }
                    ?.let { ref ->
                        launchPersistBatchEntryStatus(
                            owner,
                            ref.batchToken,
                            msg.transferId,
                            BatchManifestEntry.Status.CANCELLED,
                        )
                    }
                receiveContexts[msg.transferId]
                    ?.takeIf { it.owner === owner }
                    ?.let { launchReceiveBatchEntryStatus(it, BatchManifestEntry.Status.CANCELLED) }
                val receiveCleanup = releaseTransferResources(msg.transferId, owner)
                _progress.value = Progress(
                    transferId = msg.transferId,
                    lastStatus = cleanupAwareStatus("cancelled by peer", receiveCleanup)
                )
            }
            else -> Unit
        }
    }

    /**
     * Cancel a single in-progress transfer initiated locally (sender or receiver side).
     *
     * Immediately stops sending/receiving for THIS transfer, releases the resources it holds
     * (resend loop, partial [RandomAccessFile], send/receive contexts, checkpoint), notifies the
     * peer with the existing `op=cancel` wire message (no wire-protocol change), and reflects the
     * cancelled state in [progress]. Other concurrent transfers are unaffected.
     */
    fun cancel(transferId: String) {
        if (transferId.isBlank()) return
        if (recentlyAcknowledgedOwners.containsKey(transferId)) return
        val sendContext = sendContexts[transferId]
        val receiveContext = receiveContexts[transferId]
        val owner = sendContext?.owner ?: receiveContext?.owner ?: checkpointOwners[transferId] ?: return
        if (!webrtc.isCurrentSecureOperationOwner(owner)) {
            abandonStaleOperation(transferId, owner)
            return
        }
        sendBatchByTransferId[transferId]
            ?.takeIf { it.owner === owner }
            ?.let { ref ->
                launchPersistBatchEntryStatus(
                    owner,
                    ref.batchToken,
                    transferId,
                    BatchManifestEntry.Status.CANCELLED,
                )
            }
        receiveContext
            ?.takeIf { it.owner === owner }
            ?.let { launchReceiveBatchEntryStatus(it, BatchManifestEntry.Status.CANCELLED) }
        val version = receiveContext?.takeIf { it.owner === owner }?.version ?: 1
        val notification = runCatching {
            sendFt(
                owner,
                transferId,
                encode(
                    CrossNetworkFileTransferMessage(
                        version = version,
                        op = CrossNetworkFileTransferOp.cancel,
                        transferId = transferId
                    )
                )
            )
        }
        val receiveCleanup = releaseTransferResources(transferId, owner)
        val cancellationStatus = if (notification.isSuccess) {
            "cancelled"
        } else {
            "cancelled locally; peer notification failed: ${notification.exceptionOrNull()?.javaClass?.simpleName}"
        }
        _progress.value = Progress(
            transferId = transferId,
            lastStatus = cleanupAwareStatus(cancellationStatus, receiveCleanup),
        )
    }

    /**
     * Stop send/receive for a single transfer and release every resource it holds, without
     * touching any other transfer's state. Safe to call for a transfer we are only sending,
     * only receiving, both, or no longer tracking.
     */
    private fun releaseTransferResources(
        transferId: String,
        owner: WebRtcSecureOperationOwner,
    ): ReceiveResourceCleanupReport {
        // Stop this transfer's resend loop immediately.
        resendJobs[transferId]?.takeIf { it.owner === owner }?.let { ownedJob ->
            if (resendJobs.remove(transferId, ownedJob)) ownedJob.job.cancel()
        }

        // Sender side: drop context, batch mapping.
        sendContexts[transferId]?.takeIf { it.owner === owner }?.let { context ->
            sendContexts.remove(transferId, context)
        }
        sendBatchByTransferId[transferId]?.takeIf { it.owner === owner }?.let { ref ->
            sendBatchByTransferId.remove(transferId, ref)
        }

        // Receiver side: cancel approval, close + delete partial file, clear buffers.
        var receiveCleanup = ReceiveResourceCleanupReport(transferId)
        receiveContexts[transferId]?.takeIf { it.owner === owner }?.let { rx ->
            if (!receiveContexts.remove(transferId, rx)) return@let
            rx.declined = true
            receiveCleanup = cleanupReceiveContext(rx, deletePartialFile = true)
        }

        // Stop watching this transfer for idle/interrupt (it is terminal now).
        stopIdleWatchdogFor(transferId, owner)

        // Delete this transfer's checkpoint so it is not offered for resume.
        if (receiveCleanup.checkpointDisposition == ReceiveCleanupCheckpointDisposition.DELETE) {
            enqueueCheckpointMutation(transferId, owner, CheckpointMutation.DELETE) { delete(transferId) }
        }
        return receiveCleanup
    }

    // region Idle / interrupt watchdog (Requirement 5.12)

    /**
     * Begin watching [transferId] for idle/interrupt timeout. Seeds its last-activity timestamp to
     * "now" and (idempotently) starts the single background watchdog loop. Called when a send or
     * receive for the transfer becomes active.
     */
    private fun startIdleWatchdogFor(
        transferId: String,
        owner: WebRtcSecureOperationOwner,
    ) {
        if (transferId.isBlank()) return
        requireCurrentOwner(transferId, owner)
        activityByTransferId[transferId] = OwnedTransferActivity(owner, clockMs())
        ensureIdleWatchdogRunning()
    }

    /** Stop watching [transferId] (its transfer reached a terminal state). */
    private fun stopIdleWatchdogFor(
        transferId: String,
        owner: WebRtcSecureOperationOwner,
    ) {
        activityByTransferId[transferId]?.takeIf { it.owner === owner }?.let { activity ->
            activityByTransferId.remove(transferId, activity)
        }
    }

    /**
     * Refresh [transferId]'s last-activity timestamp because a chunk/ack message was observed. Only
     * refreshes transfers that are currently watched, so late/stray messages for already-terminated
     * transfers do not resurrect them.
     */
    private fun markTransferActivity(
        transferId: String,
        owner: WebRtcSecureOperationOwner,
    ) {
        if (transferId.isBlank()) return
        activityByTransferId.computeIfPresent(transferId) { _, activity ->
            if (activity.owner === owner) activity.copy(lastActivityMs = clockMs()) else activity
        }
    }

    private fun ensureIdleWatchdogRunning() {
        if (idleWatchdogJob?.isActive == true) return
        synchronized(this) {
            if (idleWatchdogJob?.isActive == true) return
            idleWatchdogJob = scope.launch {
                while (isActive && activityByTransferId.isNotEmpty()) {
                    delay(idleWatchdogPollMs)
                    runIdleInterruptSweep(clockMs())
                }
            }
        }
    }

    /**
     * Terminate every watched transfer whose idle time has crossed [idleInterruptTimeoutMs] as of
     * [nowMs], RETAINING each one's verified-bytes checkpoint so it can be resumed
     * (Requirement 5.12). Pure enough to be driven directly from tests with an injected clock; the
     * background loop simply calls it on each poll.
     */
    internal fun runIdleInterruptSweep(nowMs: Long) {
        // Snapshot to avoid mutating while iterating.
        val watched = activityByTransferId.entries.toList()
        for ((transferId, activity) in watched) {
            if (!webrtc.isCurrentSecureOperationOwner(activity.owner)) {
                abandonStaleOperation(transferId, activity.owner)
            } else if (
                TransferActivityTimeoutDecision.isTimedOut(
                    activity.lastActivityMs,
                    nowMs,
                    idleInterruptTimeoutMs,
                )
            ) {
                timeoutTransferRetainingCheckpoint(transferId, activity.owner, activity)
            }
        }
    }

    /**
     * Terminate THIS transfer due to idle/interrupt while RETAINING its checkpoint (Requirement
     * 5.12). This is deliberately distinct from [releaseTransferResources] / [rejectReceive] /
     * [cleanupTimedOutReceive], which PURGE the checkpoint on cancel/decline/corrupt/give-up: here
     * the transfer is resumable, so the verified-bytes checkpoint (and any partial file) is left in
     * place. It can resume only if the same live secure owner remains current; after reconnect or
     * rekey the UI must start a fresh transfer rather than silently crossing owners. Presents a
     * truthful interrupt/timeout reason.
     */
    private fun timeoutTransferRetainingCheckpoint(
        transferId: String,
        owner: WebRtcSecureOperationOwner,
        expectedActivity: OwnedTransferActivity,
    ) {
        // Only act if still watched (avoid double-firing / racing a concurrent terminal path).
        if (!activityByTransferId.remove(transferId, expectedActivity)) return

        // Stop this transfer's resend loop immediately (no more chunk retransmits).
        resendJobs[transferId]?.takeIf { it.owner === owner }?.let { ownedJob ->
            if (resendJobs.remove(transferId, ownedJob)) ownedJob.job.cancel()
        }

        // Capture progress figures before dropping in-memory state.
        val sendCtx = sendContexts[transferId]
            ?.takeIf { it.owner === owner }
            ?.also { sendContexts.remove(transferId, it) }
        sendBatchByTransferId[transferId]
            ?.takeIf { it.owner === owner }
            ?.let { sendBatchByTransferId.remove(transferId, it) }

        var receivedBytes = 0L
        var totalBytes = 0L
        var receiveCleanup = ReceiveResourceCleanupReport(transferId)
        receiveContexts[transferId]?.takeIf { it.owner === owner }?.let { rx ->
            if (!receiveContexts.remove(transferId, rx)) return@let
            rx.declined = true
            // Close the RAF but DO NOT delete the partial file — it backs the retained checkpoint.
            receiveCleanup = cleanupReceiveContext(rx, deletePartialFile = false)
            receivedBytes = rx.receivedBytes
            totalBytes = rx.totalBytes ?: 0L
        }
        if (sendCtx != null) {
            totalBytes = sendCtx.totalBytes
            // Sender-side "verified" progress is the acked-chunk boundary already recorded in the
            // checkpoint; report acked bytes as a lower bound for the UI.
            receivedBytes = (sendCtx.delivery.deliveredCount().toLong() * approxChunkBytes(sendCtx))
                .coerceAtMost(sendCtx.totalBytes)
        }

        // Attribute the reason: session dropped vs simply idle.
        val reason = TransferActivityTimeoutDecision.reasonFor(
            sessionUsable = webrtc.isCurrentSecureOperationOwner(owner),
        )
        _progress.value = Progress(
            transferId = transferId,
            sentBytes = receivedBytes,
            totalBytes = totalBytes,
            lastStatus = cleanupAwareStatus(
                TransferActivityTimeoutDecision.statusMessage(reason, idleInterruptTimeoutMs),
                receiveCleanup,
            ),
        )
        // NOTE: checkpoint is intentionally NOT deleted here (resume entry stays available).
    }

    /** Best-effort per-chunk byte size for a send context (last chunk may be smaller; UI lower bound). */
    private fun approxChunkBytes(ctx: SendContext): Long =
        if (ctx.totalChunks <= 0) 0L else (ctx.totalBytes / ctx.totalChunks).coerceAtLeast(0L)

    // endregion

    private fun rejectInboundMessage(
        owner: WebRtcSecureOperationOwner,
        msg: CrossNetworkFileTransferMessage,
        reason: String,
    ) {
        _progress.value = Progress(
            transferId = msg.transferId.takeIf { it.isNotBlank() },
            lastStatus = "rejected inbound file transfer: $reason"
        )
        sendFt(
            owner,
            msg.transferId,
            encode(
                CrossNetworkFileTransferMessage(
                    version = msg.version,
                    op = CrossNetworkFileTransferOp.error,
                    transferId = msg.transferId,
                    message = reason
                )
            )
        )
    }

    private fun rejectReceive(ctx: ReceiveContext, reason: String) {
        if (!webrtc.isCurrentSecureOperationOwner(ctx.owner)) {
            abandonStaleOperation(ctx.transferId, ctx.owner)
            return
        }
        val removed = if (receiveContexts.remove(ctx.transferId, ctx)) ctx else return
        launchReceiveBatchEntryStatus(removed, BatchManifestEntry.Status.FAILED)
        stopIdleWatchdogFor(removed.transferId, removed.owner)
        val cleanup = cleanupReceiveContext(removed, deletePartialFile = true)
        deleteCheckpointAfterSuccessfulCleanup(removed, cleanup)
        _progress.value = Progress(
            transferId = removed.transferId,
            sentBytes = removed.receivedBytes,
            totalBytes = removed.totalBytes ?: 0L,
            lastStatus = cleanupAwareStatus("rejected inbound file transfer: $reason", cleanup)
        )
        sendFt(
            removed.owner,
            removed.transferId,
            encode(
                CrossNetworkFileTransferMessage(
                    version = removed.version,
                    op = CrossNetworkFileTransferOp.error,
                    transferId = removed.transferId,
                    message = reason
                )
            )
        )
    }

    private suspend fun cleanupTimedOutReceive(ctx: ReceiveContext) {
        if (!webrtc.isCurrentSecureOperationOwner(ctx.owner)) {
            abandonStaleOperation(ctx.transferId, ctx.owner)
            return
        }
        val removed = if (receiveContexts.remove(ctx.transferId, ctx)) ctx else return
        launchReceiveBatchEntryStatus(removed, BatchManifestEntry.Status.FAILED)
        stopIdleWatchdogFor(removed.transferId, removed.owner)
        val cleanup = cleanupReceiveContext(removed, deletePartialFile = true)
        _progress.value = Progress(
            transferId = removed.transferId,
            sentBytes = removed.receivedBytes,
            totalBytes = removed.totalBytes ?: 0L,
            lastStatus = cleanupAwareStatus("receive timed out (missing chunks)", cleanup)
        )
        if (cleanup.checkpointDisposition == ReceiveCleanupCheckpointDisposition.DELETE) {
            enqueueCheckpointMutation(removed.transferId, removed.owner, CheckpointMutation.DELETE) {
                delete(removed.transferId)
            }.awaitCompletion()
        }
    }

    private fun startInboundApprovalIfNeeded(ctx: ReceiveContext) {
        if (ctx.approvalDecision != null || ctx.approvalJob != null || ctx.declined) return

        ctx.approvalJob = scope.launch {
            val decision = runCatching {
                inboundApprovalProvider.requestDecision(
                    InboundFileTransferApprovalRequest(
                        transferId = ctx.transferId,
                        fileName = ctx.fileName,
                        mimeType = ctx.mimeType,
                        fileSizeBytes = ctx.totalBytes,
                        authenticatedSenderDeviceId = ctx.authenticatedSenderDeviceId,
                        senderDeviceId = ctx.senderDeviceId,
                        senderDeviceName = ctx.senderDeviceName
                    )
                )
            }.getOrElse {
                InboundFileTransferDecision.Decline
            }

            val current = receiveContexts[ctx.transferId]
            if (
                current !== ctx ||
                current.owner !== ctx.owner ||
                !webrtc.isCurrentSecureOperationOwner(ctx.owner)
            ) {
                abandonStaleOperation(ctx.transferId, ctx.owner)
                return@launch
            }
            current.approvalDecision = decision

            when (decision) {
                is InboundFileTransferDecision.Accept -> maybeFinalizeIfReady(current)
                InboundFileTransferDecision.Decline -> abortInboundReceive(current, reason = "declined")
            }
        }
    }

    private fun abortInboundReceive(ctx: ReceiveContext, reason: String) {
        if (!webrtc.isCurrentSecureOperationOwner(ctx.owner)) {
            abandonStaleOperation(ctx.transferId, ctx.owner)
            return
        }
        ctx.declined = true
        val removed = if (receiveContexts.remove(ctx.transferId, ctx)) ctx else return
        launchReceiveBatchEntryStatus(removed, BatchManifestEntry.Status.CANCELLED)
        stopIdleWatchdogFor(removed.transferId, removed.owner)
        val cleanup = cleanupReceiveContext(removed, deletePartialFile = true)
        deleteCheckpointAfterSuccessfulCleanup(removed, cleanup)
        _progress.value = Progress(
            transferId = removed.transferId,
            sentBytes = removed.receivedBytes,
            totalBytes = removed.totalBytes ?: removed.receivedBytes,
            lastStatus = cleanupAwareStatus("inbound declined ($reason)", cleanup)
        )
        // Best-effort notify peer.
        sendFt(
            removed.owner,
            removed.transferId,
            encode(
                CrossNetworkFileTransferMessage(
                    version = removed.version,
                    op = CrossNetworkFileTransferOp.error,
                    transferId = removed.transferId,
                    message = "declined"
                )
            )
        )
    }

    private fun TransferCheckpoint.validateReceiveCheckpoint(
        metadata: CrossNetworkFileTransferValidator.Metadata
    ) {
        require(direction == TransferDirection.RECEIVE) { "checkpoint direction mismatch" }
        require(transferId == metadata.transferId) { "checkpoint transferId mismatch" }
        ResumeReceivePlanner.validateMetadataConsistency(
            checkpointFileName = fileName,
            checkpointFileSize = fileSize,
            checkpointChunkSize = chunkSize,
            checkpointTotalChunks = totalChunks,
            metadataFileName = metadata.fileName,
            metadataFileSize = metadata.fileSize,
            metadataChunkSize = metadata.chunkSize,
            metadataTotalChunks = metadata.totalChunks
        )

        val path = partialPath
        if (path != null) {
            val context = appContext ?: error("checkpoint partialPath requires app context")
            val partialDir = File(context.applicationContext.filesDir, "skybridge_inbound_partials").canonicalFile
            val partial = File(path).canonicalFile
            require(partial.name == "${metadata.transferId}.partial") { "checkpoint partialPath file mismatch" }
            require(partial.path.startsWith(partialDir.path + File.separator)) {
                "checkpoint partialPath outside inbound partial directory"
            }
        }
    }

    private fun restoreContiguousReceiveProgress(
        ctx: ReceiveContext,
        checkpoint: TransferCheckpoint?,
        partialFile: File?
    ) {
        if (checkpoint == null) return
        ctx.receivedChunkIndices.clear()
        ctx.chunkHashes.clear()
        ctx.nextExpectedChunkIndex = 0
        ctx.receivedBytes = 0L

        if (partialFile == null) return
        val partialLength = partialFile.length()
        val restored = ResumeReceivePlanner.restoreContiguousPrefix(
            fileSize = ctx.metadata.fileSize,
            chunkSize = ctx.metadata.chunkSize,
            totalChunks = ctx.metadata.totalChunks,
            partialLength = partialLength,
            receivedChunks = checkpoint.receivedChunks.toSet(),
            receivedChunkSha256HexByIndex = checkpoint.receivedChunkSha256HexByIndex
        )
        for ((index, hash) in restored.chunkHashesByIndex) {
            ctx.receivedChunkIndices.add(index)
            ctx.chunkHashes[index] = hash
        }
        ctx.nextExpectedChunkIndex = restored.prefixChunks
        ctx.receivedBytes = restored.restoredBytes
    }

    private fun isReceiveComplete(ctx: ReceiveContext): Boolean {
        if (!ctx.completeReceived) return false
        val totalChunks = ctx.totalChunks
        return totalChunks == null || totalChunks <= 0 || ctx.nextExpectedChunkIndex == totalChunks
    }

    private fun maybeFinalizeIfReady(ctx: ReceiveContext) {
        val decision = ctx.approvalDecision
        if (decision !is InboundFileTransferDecision.Accept) return
        if (!isReceiveComplete(ctx)) return
        finalizeReceive(ctx, decision, receivedBytesHint = ctx.completeReceivedBytes)
    }

    private data class DownloadsSaveResult(
        val uri: Uri,
        val displayName: String
    )

    private fun finalizeReceive(
        ctx: ReceiveContext,
        decision: InboundFileTransferDecision.Accept,
        receivedBytesHint: Long?
    ) {
        if (!webrtc.isCurrentSecureOperationOwner(ctx.owner)) {
            abandonStaleOperation(ctx.transferId, ctx.owner)
            return
        }
        // Remove first so we don't emit twice if duplicates arrive.
        val removed = if (receiveContexts.remove(ctx.transferId, ctx)) ctx else return
        stopIdleWatchdogFor(removed.transferId, removed.owner)
        removed.approvalJob?.cancel()
        removed.approvalJob = null
        val expectedSize = requireNotNull(removed.totalBytes) { "validated metadata missing fileSize" }
        val actualSize = removed.partialFile?.length() ?: removed.buffer.size().toLong()
        val receiveFile = removed.raf
        removed.raf = null
        if (receiveFile != null) {
            val closeResult = closeReceiveFileForFinalization(receiveFile)
            if (!closeResult.isSuccessful) {
                val cleanup = ReceiveResourceCleanupReport(
                    transferId = removed.transferId,
                    failures = listOf(
                        ReceiveResourceCleanupFailure(
                            stage = ReceiveResourceCleanupStage.FINALIZE_PARTIAL_FILE,
                            cause = IOException(
                                "receive file finalization failed: ${closeResult.failedStages.joinToString(",")}",
                            ),
                        ),
                    ),
                )
                failFinalizedReceive(
                    removed = removed,
                    actualSize = actualSize,
                    expectedSize = expectedSize,
                    status = "received complete (file finalization failed: ${closeResult.failedStages.joinToString(",")})",
                    peerMessage = "file finalization failed",
                    preexistingCleanupFailure = cleanup,
                )
                return
            }
        }
        if (!ensureFinalizationOwnerIsCurrent(removed)) return

        // Compute the actual verification material from the received bytes. Any material that
        // cannot be computed is left null and mapped to a discriminable failure below; the
        // decision itself is made by the pure [ReceiveIntegrityDecision.evaluate] so the
        // "verify before deliver, zero residue on any failure" invariant is centralized and
        // exhaustively testable (Requirements 5.2, 5.3).
        //
        // Only hash when size matches (cheap short-circuit that also preserves the original
        // check ordering: size -> file sha256 -> merkle -> signature).
        val actualHash: ByteArray? = if (expectedSize != actualSize || removed.expectedFileSha256 == null) {
            null
        } else {
            try {
                if (removed.partialFile != null) sha256File(removed.partialFile!!) else sha256(removed.buffer.toByteArray())
            } catch (e: Exception) {
                // Hashing failed: refuse delivery and clean up with a discriminable status.
                failFinalizedReceive(
                    removed = removed,
                    actualSize = actualSize,
                    expectedSize = expectedSize,
                    status = "received complete (file sha256 unavailable: ${e.javaClass.simpleName})",
                    peerMessage = "file sha256 unavailable"
                )
                return
            }
        }
        if (!ensureFinalizationOwnerIsCurrent(removed)) return

        // Reconstruct the Merkle root from received chunk hashes (only when the sender enforced one
        // and the file-level checks are still viable). A missing chunk hash or a compute failure is
        // surfaced as a distinct, discriminable outcome.
        val expectedMerkle = removed.expectedMerkleRoot
        var merkleChunkHashesMissing = false
        val actualMerkle: ByteArray? = if (
            expectedMerkle == null || expectedSize != actualSize ||
            actualHash == null || !actualHash.contentEquals(removed.expectedFileSha256 ?: ByteArray(0))
        ) {
            null
        } else {
            val totalChunks = removed.totalChunks
            if (totalChunks != null && totalChunks > 0) {
                val leaves = ArrayList<ByteArray>(totalChunks)
                for (i in 0 until totalChunks) {
                    val h = removed.chunkHashes[i]
                    if (h == null) {
                        merkleChunkHashesMissing = true
                        break
                    }
                    leaves.add(h)
                }
                if (merkleChunkHashesMissing) {
                    null
                } else {
                    try {
                        MerkleSha256.root(leaves)
                    } catch (e: Exception) {
                        failFinalizedReceive(
                            removed = removed,
                            actualSize = actualSize,
                            expectedSize = expectedSize,
                            status = "received complete (merkle unavailable: ${e.javaClass.simpleName})",
                            peerMessage = "merkle unavailable"
                        )
                        return
                    }
                }
            } else {
                null
            }
        }

        // Verify the optional session signature over the Merkle root (only meaningful when a
        // Merkle root was enforced, reconstructed and matches). The pure decision decides whether
        // the signature was required; here we only supply the computed booleans.
        val sig = removed.expectedMerkleSig
        val merkleSigProvided = expectedMerkle != null && sig != null
        val merkleSigAlgRecognized = removed.expectedMerkleSigAlg == "hmac-sha256-session-v1"
        val merkleSigValid = if (
            merkleSigProvided && merkleSigAlgRecognized &&
            actualMerkle != null && actualMerkle.contentEquals(expectedMerkle)
        ) {
            val preimage = MerkleRootAuthV1.preimage(
                transferId = removed.transferId,
                merkleRoot = expectedMerkle,
                fileSha256 = removed.expectedFileSha256
            )
            webrtc.verifyInboundHmacSha256(removed.owner, preimage, sig)
        } else {
            false
        }
        if (!ensureFinalizationOwnerIsCurrent(removed)) return

        val decisionOutcome = ReceiveIntegrityDecision.evaluate(
            expectedSize = expectedSize,
            actualSize = actualSize,
            expectedFileSha256 = removed.expectedFileSha256,
            actualFileSha256 = actualHash,
            expectedMerkleRoot = expectedMerkle,
            actualMerkleRoot = actualMerkle,
            merkleChunkHashesMissing = merkleChunkHashesMissing,
            merkleSigProvided = merkleSigProvided,
            merkleSigAlgRecognized = merkleSigAlgRecognized,
            merkleSigValid = merkleSigValid
        )
        if (decisionOutcome is ReceiveIntegrityDecision.Outcome.Fail) {
            // Integrity NOT proven: delete the partial file + checkpoint, notify the peer, and do
            // NOT emit or commit anything (Requirement 5.3, zero residue / no corrupted delivery).
            failFinalizedReceive(
                removed = removed,
                actualSize = actualSize,
                expectedSize = expectedSize,
                status = decisionOutcome.status,
                peerMessage = decisionOutcome.peerMessage
            )
            return
        }
        // From here integrity is proven; actualHash is guaranteed non-null by a Pass outcome.
        val verifiedHash = requireNotNull(actualHash) { "integrity passed without a computed hash" }

        var outLocalPath: String? = removed.partialFile?.absolutePath
        var outBytes: ByteArray? = if (removed.partialFile != null) null else removed.buffer.toByteArray()
        var downloadsUri: String? = null
        var downloadsDisplayName: String? = null
        var terminalCleanup = ReceiveResourceCleanupReport(removed.transferId)

        if (saveAcceptedInboundToDownloads) {
            val ctx = appContext ?: run {
                failFinalizedReceive(
                    removed = removed,
                    actualSize = actualSize,
                    expectedSize = expectedSize,
                    status = "received complete (downloads save unavailable)",
                    peerMessage = "downloads save unavailable"
                )
                return
            }
            val save = runCatching { saveInboundToDownloads(ctx, removed, decision) }.getOrElse { err ->
                if (err is StaleWebRtcFileTransferOwnerException) {
                    ensureFinalizationOwnerIsCurrent(removed)
                    return
                }
                failFinalizedReceive(
                    removed = removed,
                    actualSize = actualSize,
                    expectedSize = expectedSize,
                    status = "received complete (downloads save failed: ${err.javaClass.simpleName})",
                    peerMessage = "downloads save failed"
                )
                return
            }
            downloadsUri = save.uri.toString()
            downloadsDisplayName = save.displayName
            outLocalPath = null
            outBytes = null
            // Keep storage tidy: remove the private partial after successful commit to Downloads.
            terminalCleanup = cleanupReceiveContext(removed, deletePartialFile = true)
        }

        if (!ensureFinalizationOwnerIsCurrent(removed)) return

        launchReceiveBatchEntryStatus(removed, BatchManifestEntry.Status.COMPLETED)
        _progress.value = Progress(
            transferId = removed.transferId,
            sentBytes = actualSize,
            totalBytes = expectedSize,
            lastStatus = cleanupAwareStatus(
                buildString {
                    append("received complete")
                    if (downloadsDisplayName != null) append(" → Downloads/$downloadsDisplayName")
                },
                terminalCleanup,
            )
        )
        _receivedFiles.tryEmit(
            ReceivedFile(
                transferId = removed.transferId,
                fileName = downloadsDisplayName ?: removed.fileName,
                mimeType = removed.mimeType,
                bytes = outBytes,
                localPath = outLocalPath,
                downloadsUri = downloadsUri,
                downloadsDisplayName = downloadsDisplayName
            )
        )
        deleteCheckpointAfterSuccessfulCleanup(removed, terminalCleanup)
        sendFt(
            removed.owner,
            removed.transferId,
            encode(
                CrossNetworkFileTransferMessage(
                    version = removed.version,
                    op = CrossNetworkFileTransferOp.completeAck,
                    transferId = removed.transferId,
                    receivedBytes = receivedBytesHint ?: expectedSize,
                    fileSha256 = verifiedHash
                )
            )
        )
    }

    private fun failFinalizedReceive(
        removed: ReceiveContext,
        actualSize: Long,
        expectedSize: Long,
        status: String,
        peerMessage: String,
        preexistingCleanupFailure: ReceiveResourceCleanupReport? = null,
    ) {
        if (!ensureFinalizationOwnerIsCurrent(removed)) return
        launchReceiveBatchEntryStatus(removed, BatchManifestEntry.Status.FAILED)
        stopIdleWatchdogFor(removed.transferId, removed.owner)
        val cleanup = preexistingCleanupFailure
            ?: cleanupReceiveContext(removed, deletePartialFile = true)
        deleteCheckpointAfterSuccessfulCleanup(removed, cleanup)
        _progress.value = Progress(
            transferId = removed.transferId,
            sentBytes = actualSize,
            totalBytes = expectedSize,
            lastStatus = cleanupAwareStatus(status, cleanup)
        )
        sendFt(
            removed.owner,
            removed.transferId,
            encode(
                CrossNetworkFileTransferMessage(
                    version = removed.version,
                    op = CrossNetworkFileTransferOp.error,
                    transferId = removed.transferId,
                    message = peerMessage
                )
            )
        )
    }

    private fun ensureFinalizationOwnerIsCurrent(context: ReceiveContext): Boolean {
        if (webrtc.isCurrentSecureOperationOwner(context.owner)) return true
        context.declined = true
        val cleanup = cleanupReceiveContext(context, deletePartialFile = false)
        stopIdleWatchdogFor(context.transferId, context.owner)
        if (checkpointOwners[context.transferId] === context.owner) {
            _progress.value = Progress(
                transferId = context.transferId,
                sentBytes = context.receivedBytes,
                totalBytes = context.totalBytes ?: 0L,
                lastStatus = cleanupAwareStatus(
                    "receive stopped: secure session replaced or rekeyed",
                    cleanup,
                ),
            )
        }
        return false
    }

    private fun saveInboundToDownloads(
        context: Context,
        removed: ReceiveContext,
        decision: InboundFileTransferDecision.Accept
    ): DownloadsSaveResult {
        requireCurrentOwner(removed.transferId, removed.owner)
        val resolver = context.contentResolver
        val desired = sanitizeDownloadsDisplayName(
            decision.downloadsDisplayName.ifBlank { removed.fileName ?: "skybridge-received" }
        )

        val targetName = if (!decision.overwriteExisting) {
            uniqueDownloadsDisplayName(context, desired)
        } else {
            // Explicit overwrite means deletion failures are terminal, not permission fallbacks.
            resolver.delete(
                MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                "${MediaStore.MediaColumns.DISPLAY_NAME}=?",
                arrayOf(desired)
            )
            desired
        }

        requireCurrentOwner(removed.transferId, removed.owner)

        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, targetName)
            put(MediaStore.MediaColumns.MIME_TYPE, removed.mimeType ?: "application/octet-stream")
            put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }

        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: error("MediaStore insert failed")

        try {
            requireCurrentOwner(removed.transferId, removed.owner)
            resolver.openOutputStream(uri, "wt")?.use { os ->
                val partial = removed.partialFile
                if (partial != null && partial.exists()) {
                    partial.inputStream().use { it.copyTo(os) }
                } else {
                    os.write(removed.buffer.toByteArray())
                }
                os.flush()
            } ?: error("openOutputStream failed")
            requireCurrentOwner(removed.transferId, removed.owner)
            val done = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }
            check(resolver.update(uri, done, null, null) == 1) {
                "MediaStore finalize failed"
            }
            requireCurrentOwner(removed.transferId, removed.owner)
        } catch (error: Exception) {
            // The item is not a committed receive until the exact owner survives the full write.
            try {
                resolver.delete(uri, null, null)
            } catch (cleanupError: Exception) {
                error.addSuppressed(
                    IllegalStateException("failed to remove uncommitted Downloads item", cleanupError),
                )
            }
            throw error
        }

        return DownloadsSaveResult(uri = uri, displayName = targetName)
    }

    private fun sanitizeDownloadsDisplayName(raw: String): String {
        val cleaned = raw
            .replace('/', '_')
            .replace('\\', '_')
            .trim()
        return cleaned.ifBlank { "skybridge-received" }
    }

    private fun downloadsItemExists(context: Context, displayName: String): Boolean {
        val resolver = context.contentResolver
        val uri = MediaStore.Downloads.EXTERNAL_CONTENT_URI
        val projection = arrayOf(MediaStore.MediaColumns._ID)
        val selection = "${MediaStore.MediaColumns.DISPLAY_NAME}=?"
        val args = arrayOf(displayName)
        resolver.query(uri, projection, selection, args, null)?.use { cursor ->
            return cursor.moveToFirst()
        }
        return false
    }

    private fun uniqueDownloadsDisplayName(context: Context, desiredName: String): String =
        DownloadsFilenameDeduper.deduplicate(
            desiredName = desiredName,
            nameExists = { candidate -> downloadsItemExists(context, candidate) }
        )

    private fun sendChunk(
        owner: WebRtcSecureOperationOwner,
        transferId: String,
        index: Int,
        chunkBytes: ByteArray,
        receivedBytes: Long? = null
    ) {
        val msg = CrossNetworkFileTransferMessage(
            version = 1,
            op = CrossNetworkFileTransferOp.chunk,
            transferId = transferId,
            chunkIndex = index,
            chunkData = chunkBytes,
            chunkSha256 = sha256(chunkBytes),
            rawSize = chunkBytes.size,
            receivedBytes = receivedBytes
        )
        sendFt(owner, transferId, encode(msg))
        sendContexts[transferId]
            ?.takeIf { it.owner === owner }
            ?.delivery
            ?.recordSendAttempt(index)
    }

    private fun startResendLoopIfNeeded(
        transferId: String,
        owner: WebRtcSecureOperationOwner,
    ) {
        sendContexts[transferId]?.takeIf { it.owner === owner } ?: return
        // lightweight retry loop: only resend unacked chunks a few times
        val job = scope.launch {
            val resendDelayMs = 1200L
            while (isActive) {
                delay(resendDelayMs)
                if (!webrtc.isCurrentSecureOperationOwner(owner)) {
                    abandonStaleOperation(transferId, owner)
                    break
                }
                val stillTracked = sendContexts[transferId]
                    ?.takeIf { it.owner === owner }
                    ?: break
                // Overall delivery is declared only on the receiver's integrity-gated completeAck
                // (which removes the send context); here we only keep retransmitting still-unacked
                // chunks that remain under the attempt ceiling, in ascending index order.
                if (stillTracked.delivery.isAllDelivered()) {
                    // Every chunk acked: stop retrying and idle until completeAck arrives.
                    break
                }
                for (i in stillTracked.delivery.resendCandidates(LOOP_RESEND_MAX_ATTEMPTS)) {
                    if (!tryResendChunk(stillTracked, i)) return@launch
                }
            }
        }
        val ownedJob = OwnedTransferJob(owner, job)
        resendJobs.put(transferId, ownedJob)?.let { previous ->
            if (previous.owner !== owner) previous.job.cancel()
        }
        job.invokeOnCompletion { resendJobs.remove(transferId, ownedJob) }
    }

    private fun tryResendChunk(ctx: SendContext, index: Int): Boolean =
        runCatching {
            sendChunk(ctx.owner, ctx.transferId, index, ctx.chunks[index])
        }.fold(
            onSuccess = { true },
            onFailure = { error ->
                failOutboundTransfer(ctx, "chunk#$index resend failed: ${error.javaClass.simpleName}")
                false
            }
        )

    private fun tryResendComplete(ctx: SendContext): Boolean =
        runCatching {
            sendCompleteFromContext(ctx)
        }.fold(
            onSuccess = { true },
            onFailure = { error ->
                failOutboundTransfer(ctx, "complete resend failed: ${error.javaClass.simpleName}")
                false
            }
        )

    private fun failOutboundTransfer(ctx: SendContext, reason: String) {
        if (!webrtc.isCurrentSecureOperationOwner(ctx.owner)) {
            abandonStaleOperation(ctx.transferId, ctx.owner)
            return
        }
        stopIdleWatchdogFor(ctx.transferId, ctx.owner)
        sendContexts.remove(ctx.transferId, ctx)
        sendBatchByTransferId[ctx.transferId]
            ?.takeIf { it.owner === ctx.owner }
            ?.let { ref ->
                // Isolate this batch item's failure; other files in the batch keep going.
                launchPersistBatchEntryStatus(
                    ctx.owner,
                    ref.batchToken,
                    ctx.transferId,
                    BatchManifestEntry.Status.FAILED,
                )
                sendBatchByTransferId.remove(ctx.transferId, ref)
                updateBatchFileStatus(ref.batchId, ctx.transferId, BatchManifestEntry.Status.FAILED)
            }
        enqueueCheckpointMutation(ctx.transferId, ctx.owner, CheckpointMutation.DELETE) {
            delete(ctx.transferId)
        }
        _progress.value = Progress(
            transferId = ctx.transferId,
            sentBytes = ctx.totalBytes,
            totalBytes = ctx.totalBytes,
            lastStatus = "send failed: $reason"
        )
    }

    private fun sendCompleteFromContext(ctx: SendContext) {
        val fileDigest = MessageDigest.getInstance("SHA-256")
        ctx.chunks.forEach { fileDigest.update(it) }
        val fileSha256 = fileDigest.digest()

        val leaves = ctx.chunks.map { sha256(it) }
        val merkleRoot = MerkleSha256.root(leaves)
        val merkleSig = computeOutboundHmac(
            owner = ctx.owner,
            transferId = ctx.transferId,
            preimage = MerkleRootAuthV1.preimage(
                transferId = ctx.transferId,
                merkleRoot = merkleRoot,
                fileSha256 = fileSha256,
            ),
        )

        sendFt(
            ctx.owner,
            ctx.transferId,
            encode(
                CrossNetworkFileTransferMessage(
                    version = 1,
                    op = CrossNetworkFileTransferOp.complete,
                    transferId = ctx.transferId,
                    receivedBytes = ctx.totalBytes,
                    fileSha256 = fileSha256,
                    merkleRoot = merkleRoot,
                    merkleRootSignature = merkleSig,
                    merkleRootSignatureAlg = "hmac-sha256-session-v1"
                )
            )
        )
    }

    private fun sha256(data: ByteArray): ByteArray =
        MessageDigest.getInstance("SHA-256").digest(data)

    private fun sha256File(file: File): ByteArray {
        val md = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { ins ->
            val buf = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val n = ins.read(buf)
                if (n <= 0) break
                md.update(buf, 0, n)
            }
        }
        return md.digest()
    }

    private fun ByteArray.toHex(): String =
        joinToString(separator = "") { "%02x".format(it) }

    private fun encode(msg: CrossNetworkFileTransferMessage): ByteArray =
        CrossNetworkFileTransferWireCodec.encode(msg)

    /**
     * Send a file-transfer payload through the SBWC envelope tagged FILE_TRANSFER, matching the
     * macOS CrossNetworkConnectionManager+WebRTCFileTransfer path (packetType = .fileTransfer).
     */
    private fun computeOutboundHmac(
        owner: WebRtcSecureOperationOwner,
        transferId: String,
        preimage: ByteArray,
    ): ByteArray {
        requireCurrentOwner(transferId, owner)
        return webrtc.computeOutboundHmacSha256(owner, preimage) ?: run {
            requireCurrentOwner(transferId, owner)
            error("file transfer HMAC unavailable for current secure owner")
        }
    }

    private fun sendFt(
        owner: WebRtcSecureOperationOwner,
        transferId: String,
        bytes: ByteArray,
    ) {
        requireCurrentOwner(transferId, owner)
        if (!webrtc.send(owner, bytes, WebRtcAppSecureEnvelope.PacketType.FILE_TRANSFER)) {
            requireCurrentOwner(transferId, owner)
            val sendContext = sendContexts[transferId]?.takeIf { it.owner === owner }
            if (sendContext != null) {
                failOutboundTransfer(sendContext, "transport rejected send")
            } else {
                releaseTransferResources(transferId, owner)
            }
            error("file transfer send failed: payloadBytes=${bytes.size}")
        }
    }

    private companion object {
        const val MAX_PENDING_CHUNK_BYTES = 64L * 1024 * 1024
        const val MAX_IN_MEMORY_RECEIVE_BYTES = 64L * 1024 * 1024
        const val MAX_RESEND_CACHE_BYTES = 128L * 1024 * 1024
        const val DEFAULT_MISSING_CHUNK_RECEIVE_TIMEOUT_MS = 10_000L

        /**
         * Idle / interrupt timeout for an active transfer (Requirement 5.12): 30s with no chunk/ack
         * activity, or a session interrupted for >30s, terminates THIS transfer while RETAINING its
         * verified-bytes checkpoint for resume.
         */
        const val DEFAULT_IDLE_INTERRUPT_TIMEOUT_MS = 30_000L

        /** Background idle/interrupt watchdog poll cadence. */
        const val DEFAULT_IDLE_WATCHDOG_POLL_MS = 1_000L

        /** Attempt ceiling when retransmitting a chunk in response to a peer NACK. */
        const val NACK_RESEND_MAX_ATTEMPTS = 6

        /** Attempt ceiling for the background resend loop (bounded, un-acked chunks only). */
        const val LOOP_RESEND_MAX_ATTEMPTS = 3

        /** Covers synchronous ACK delivery while the initiating suspend call returns to its UI. */
        const val RECENT_ACK_WITNESS_TTL_MS = 5_000L

        /** Single-batch file-count upper bound (Requirement 5.8). */
        const val MAX_BATCH_FILES = 500
    }
}
