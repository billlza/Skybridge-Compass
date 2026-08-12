package com.skybridge.compass.filetransfer.webrtc

import android.content.ContentResolver
import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Environment
import android.os.StatFs
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
import java.io.Closeable
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.RandomAccessFile
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

internal enum class CheckpointMutation(val operationName: String) {
    SAVE("save"),
    UPDATE("update"),
    DELETE("delete"),
}

internal class CheckpointMutationException(
    val transferId: String,
    val mutation: CheckpointMutation,
    internal val owner: WebRtcSecureOperationOwner?,
    internal val attemptGeneration: Long?,
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
    internal val owner: WebRtcSecureOperationOwner?,
    internal val attemptGeneration: Long?,
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

internal class InboundTransferAdmission(
    private val maximumActiveTransfers: Int,
    private val maximumAggregateBytes: Long,
    private val requireDiskCapacity: Boolean,
    private val usableSpaceBytes: () -> Long,
) {
    private val lock = Any()
    private val admittedBytesByTransferId = HashMap<String, Long>()
    private var aggregateBytes: Long = 0L

    fun tryAdmit(transferId: String, declaredBytes: Long): String? = synchronized(lock) {
        require(declaredBytes > 0L) { "inbound declared bytes must be positive" }
        if (transferId in admittedBytesByTransferId) {
            return@synchronized "inbound transfer admission already in progress"
        }
        if (admittedBytesByTransferId.size >= maximumActiveTransfers) {
            return@synchronized "inbound transfer count capacity exceeded"
        }
        if (declaredBytes > maximumAggregateBytes - aggregateBytes) {
            return@synchronized "inbound aggregate byte capacity exceeded"
        }
        if (requireDiskCapacity) {
            val usableSpace = usableSpaceBytes()
            if (usableSpace < aggregateBytes || declaredBytes > usableSpace - aggregateBytes) {
                return@synchronized "inbound staging disk capacity exceeded"
            }
        }
        admittedBytesByTransferId[transferId] = declaredBytes
        aggregateBytes += declaredBytes
        null
    }

    fun release(transferId: String) = synchronized(lock) {
        val declaredBytes = admittedBytesByTransferId.remove(transferId) ?: return@synchronized
        aggregateBytes = Math.subtractExact(aggregateBytes, declaredBytes)
        check(aggregateBytes >= 0L) { "inbound admission byte accounting underflow" }
    }

    internal fun snapshot(): Pair<Int, Long> = synchronized(lock) {
        admittedBytesByTransferId.size to aggregateBytes
    }
}

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

class BatchResumeMigrationUnsupportedException(
    val transferId: String,
    val batchId: String,
) : IllegalStateException(
    "cannot resume batch transfer $transferId with a fresh wire id without atomic batch migration: $batchId",
)

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
    private val inboundFileDestinationPolicy: InboundFileDestinationPolicy =
        InboundFileDestinationPolicy.IN_MEMORY,
    private val appPrivateInboundFileCommitterOverride: AppPrivateInboundFileCommitter? = null,
    /**
     * Maximum file size whose chunks remain buffered for NACK-driven retransmission. Production
     * uses [MAX_RESEND_CACHE_BYTES]; tests may lower the boundary to exercise the streamed,
     * completion-evidence-only path without allocating a release-sized file.
     */
    private val maxResendCacheBytes: Long = MAX_RESEND_CACHE_BYTES,
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
    private val clockMs: () -> Long = { System.currentTimeMillis() },
    /**
     * Capacity available to this controller's durable receive staging volume. Kept injectable so
     * admission boundaries are deterministic in unit tests and the filesystem query stays in one
     * infrastructure seam.
     */
    private val inboundUsableSpaceBytes: () -> Long = {
        appContext?.applicationContext?.filesDir?.let { filesDir ->
            StatFs(filesDir.absolutePath).availableBytes
        } ?: Long.MAX_VALUE
    },
    /** Test seam immediately before a nonterminal progress commit, while the attempt lock is held. */
    private val beforeOutboundProgressCommit: (String) -> Unit = {},
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val checkpointMutationLock = Any()
    private val inboundAdmission = InboundTransferAdmission(
        maximumActiveTransfers = MAX_ACTIVE_INBOUND_TRANSFERS,
        maximumAggregateBytes = MAX_AGGREGATE_INBOUND_BYTES,
        requireDiskCapacity = inboundFileDestinationPolicy != InboundFileDestinationPolicy.IN_MEMORY,
        usableSpaceBytes = inboundUsableSpaceBytes,
    )
    private val appPrivateInboundFileCommitter: AppPrivateInboundFileCommitter? =
        when (inboundFileDestinationPolicy) {
            InboundFileDestinationPolicy.APP_PRIVATE_DURABLE ->
                appPrivateInboundFileCommitterOverride ?: AppPrivateInboundFileCommitter.forContext(
                    requireNotNull(appContext) {
                        "app-private durable inbound storage requires an application context"
                    },
                )

            InboundFileDestinationPolicy.IN_MEMORY,
            InboundFileDestinationPolicy.DOWNLOADS -> null
        }
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
        require(maxResendCacheBytes > 0) {
            "maxResendCacheBytes must be positive"
        }
        if (inboundFileDestinationPolicy == InboundFileDestinationPolicy.DOWNLOADS) {
            requireNotNull(appContext) { "Downloads inbound storage requires an application context" }
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
        val owner: WebRtcSecureOperationOwner?,
        val attemptGeneration: Long?,
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
    ): QueuedCheckpointMutation {
        val attemptGeneration = currentOutboundAttempt(transferId, owner)?.generation
        return enqueueCheckpointMutationInternal(
            transferId = transferId,
            mutation = mutation,
            failureOwner = owner,
            attemptGeneration = attemptGeneration,
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
    }

    /** Explicit local deletion is not a network operation and deliberately invalidates any owner. */
    private fun enqueueLocalCheckpointDeletion(transferId: String): QueuedCheckpointMutation {
        checkpointOwners.remove(transferId)
        return enqueueCheckpointMutationInternal(
            transferId = transferId,
            mutation = CheckpointMutation.DELETE,
            failureOwner = null,
            attemptGeneration = null,
            operationAllowed = { checkpointOwners[transferId] == null },
            operation = { delete(transferId) },
        )
    }

    private fun enqueueCheckpointMutationInternal(
        transferId: String,
        mutation: CheckpointMutation,
        failureOwner: WebRtcSecureOperationOwner?,
        attemptGeneration: Long?,
        operationAllowed: () -> Boolean,
        operation: suspend TransferCheckpointStore.() -> Unit,
        onSuccess: () -> Unit = {},
    ): QueuedCheckpointMutation {
        val queued = synchronized(checkpointMutationLock) {
            if (!scope.isActive) {
                throw CheckpointMutationException(
                    transferId = transferId,
                    mutation = mutation,
                    owner = failureOwner,
                    attemptGeneration = attemptGeneration,
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
                    throw CheckpointMutationException(
                        transferId,
                        mutation,
                        failureOwner,
                        attemptGeneration,
                        cause,
                    )
                }
            }
            QueuedCheckpointMutation(worker, failureOwner, attemptGeneration).also {
                checkpointMutationTails[transferId] = it
            }
        }
        queued.worker.invokeOnCompletion { cause ->
            if (cause != null) {
                val contextualFailure = cause as? CheckpointMutationException
                    ?: CheckpointMutationException(
                        transferId,
                        mutation,
                        queued.owner,
                        queued.attemptGeneration,
                        cause,
                    )
                recordCheckpointMutationFailure(contextualFailure)
            }
            checkpointMutationTails.remove(transferId, queued)
        }
        queued.worker.start()
        return queued
    }

    private fun recordCheckpointMutationFailure(failure: CheckpointMutationException) {
        _checkpointMutationFailure.value = failure
        recordCriticalPersistenceFailure(
            transferId = failure.transferId,
            owner = failure.owner,
            attemptGeneration = failure.attemptGeneration,
            status = Progress(
                transferId = failure.transferId,
                lastStatus = buildString {
                    append(requireNotNull(failure.message))
                    failure.cause?.let { cause ->
                        append(": ")
                        append(cause.javaClass.simpleName)
                        cause.message?.let { append(": $it") }
                    }
                },
            ),
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
        val attemptGeneration = currentOutboundAttempt(transferId, owner)?.generation
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
                    ?: BatchManifestMutationException(
                        batchToken.batchId,
                        transferId,
                        mutation,
                        owner,
                        attemptGeneration,
                        cause,
                    )
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
        recordCriticalPersistenceFailure(
            transferId = failure.transferId,
            owner = failure.owner,
            attemptGeneration = failure.attemptGeneration,
            status = Progress(
            transferId = failure.transferId,
            lastStatus = buildString {
                append(requireNotNull(failure.message))
                failure.cause?.let { cause ->
                    append(": ")
                    append(cause.javaClass.simpleName)
                    cause.message?.let { append(": $it") }
                }
            },
            ),
        )
    }

    private fun recordCriticalPersistenceFailure(
        transferId: String,
        owner: WebRtcSecureOperationOwner?,
        attemptGeneration: Long?,
        status: Progress,
    ) {
        if (owner == null) return

        if (attemptGeneration == null) {
            // Receiver and pre-attempt batch mutations have no outbound generation. Their error is
            // user-visible only while the exact secure owner is still current and no outbound
            // attempt with this wire id exists. Admission serialization prevents racing a new
            // outbound attempt between the absence check and the progress publication.
            synchronized(outboundAttemptAdmissionLock) {
                if (outboundAttempts[transferId] == null &&
                    webrtc.isCurrentSecureOperationOwner(owner)
                ) {
                    _progress.value = status
                }
            }
            return
        }

        val attempt = outboundAttempts[transferId]?.takeIf {
            it.owner === owner && it.generation == attemptGeneration
        } ?: return
        val totalBytes = outboundTotalBytes(attempt)
        if (!tryTransitionOutboundTerminal(
                attempt,
                OutboundAttemptState.FAILED,
                terminalProgress = {
                    status.copy(
                        sentBytes = totalBytes,
                        totalBytes = totalBytes,
                    )
                },
            )
        ) {
            return
        }
        stopOutboundTracking(attempt, deleteCheckpoint = false)
        terminalizeOutboundBatch(attempt, BatchManifestEntry.Status.FAILED)
    }

    data class Progress(
        val transferId: String? = null,
        val sentBytes: Long = 0L,
        val totalBytes: Long = 0L,
        val lastStatus: String? = null
    )

    private val _progress = MutableStateFlow(Progress())
    val progress: StateFlow<Progress> = _progress.asStateFlow()
    private val _checkpointMutationFailure = MutableStateFlow<CheckpointMutationException?>(null)
    internal val checkpointMutationFailure: StateFlow<CheckpointMutationException?> =
        _checkpointMutationFailure.asStateFlow()
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
        var appPrivateTemporaryFile: AppPrivateInboundFileCommitter.OwnedTemporaryFile?,
        var receivedBytes: Long = 0L
    ) {
        val buffer = ByteArrayOutputStream()
        var nextExpectedChunkIndex: Int = 0
        val pendingChunks: MutableMap<Int, ByteArray> = HashMap()
        var pendingChunkBytes: Long = 0L
        val receivedChunkIndices: MutableSet<Int> = HashSet()
        var completeReceived: Boolean = false
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

    private fun tryAdmitInboundTransfer(
        transferId: String,
        declaredBytes: Long,
    ): String? = inboundAdmission.tryAdmit(transferId, declaredBytes)

    private fun releaseInboundAdmission(context: ReceiveContext) {
        inboundAdmission.release(context.transferId)
    }

    private val receiveContexts = ConcurrentHashMap<String, ReceiveContext>()

    private fun cleanupReceiveContext(
        context: ReceiveContext,
        deletePartialFile: Boolean,
    ): ReceiveResourceCleanupReport {
        releaseInboundAdmission(context)
        context.approvalJob?.cancel()
        context.approvalJob = null
        val receiveFile = context.raf
        context.raf = null
        val appPrivateTemporaryFile = context.appPrivateTemporaryFile
        context.appPrivateTemporaryFile = null
        val partialFile = context.partialFile.takeIf { deletePartialFile }
        val report = if (appPrivateTemporaryFile != null && deletePartialFile) {
            try {
                requireNotNull(appPrivateInboundFileCommitter).discard(appPrivateTemporaryFile)
                ReceiveResourceCleanupReport(context.transferId)
            } catch (error: Exception) {
                ReceiveResourceCleanupReport(
                    transferId = context.transferId,
                    failures = listOf(
                        ReceiveResourceCleanupFailure(
                            ReceiveResourceCleanupStage.DELETE_PARTIAL_FILE,
                            error,
                        ),
                    ),
                )
            }
        } else {
            ReceiveResourceCleanup.execute(
                transferId = context.transferId,
                closePartialFile = when {
                    appPrivateTemporaryFile != null -> ({ appPrivateTemporaryFile.close() })
                    receiveFile != null -> ({ receiveFile.close() })
                    else -> null
                },
                deletePartialFile = partialFile?.let { file ->
                    {
                        if (file.exists() && !file.delete() && file.exists()) {
                            throw IOException("partial file deletion returned false")
                        }
                    }
                },
            )
        }
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
        val attemptGeneration: Long,
        val totalChunks: Int,
        val totalBytes: Long,
        val fileSha256: ByteArray,
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

    /** Completion evidence admitted immediately before the `complete` packet is dispatched. */
    private data class OutboundCompletionExpectation(
        val totalBytes: Long,
        val fileSha256: ByteArray,
    )

    internal enum class OutboundAttemptState {
        ACTIVE,
        COMPLETION_ARMED,
        ACKED,
        FAILED,
        CANCELLED,
        TIMED_OUT,
        STALE,
    }

    /**
     * One immutable `(transferId, secure owner, generation)` authority for an outbound operation.
     *
     * The state is the only terminal arbiter. A synchronous ACK/error/cancel can therefore win
     * while `send()` is still on the stack without a caller subsequently publishing a contradictory
     * status. The attempt remains in [outboundAttempts] for the lifetime of its secure owner, which
     * deliberately makes transfer identifiers single-use within one authenticated key epoch.
     */
    private class OutboundAttempt(
        val owner: WebRtcSecureOperationOwner,
        val transferId: String,
        val generation: Long,
    ) {
        val state = AtomicReference(OutboundAttemptState.ACTIVE)
        val completionExpectation = AtomicReference<OutboundCompletionExpectation?>(null)
        val closeable = AtomicReference<Closeable?>(null)
        val closeFailure = AtomicReference<IOException?>(null)
        val initiatorActive = AtomicBoolean(true)
        val linearizationLock = Any()
    }

    private class OutboundAttemptTerminatedException(
        val transferId: String,
        val terminalState: OutboundAttemptState,
    ) : IllegalStateException("outbound transfer $transferId became $terminalState")

    private val outboundAttemptAdmissionLock = Any()
    private val outboundAttemptGeneration = AtomicLong(0L)
    private val outboundAttempts = ConcurrentHashMap<String, OutboundAttempt>()

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

    private fun beginOutboundAttempt(
        transferId: String,
        owner: WebRtcSecureOperationOwner,
    ): OutboundAttempt {
        val canonicalTransferId = CrossNetworkFileTransferValidator.canonicalTransferId(transferId)
        requireCurrentOwner(canonicalTransferId, owner)
        val attempt = OutboundAttempt(
            owner = owner,
            transferId = canonicalTransferId,
            generation = outboundAttemptGeneration.incrementAndGet(),
        )
        synchronized(outboundAttemptAdmissionLock) {
            val previous = outboundAttempts[canonicalTransferId]
            check(previous?.owner !== owner) {
                "transferId is single-use within one secure session: $canonicalTransferId"
            }
            if (previous != null) {
                check(!webrtc.isCurrentSecureOperationOwner(previous.owner)) {
                    "transferId is already owned by a current secure session: $canonicalTransferId"
                }
                markOutboundStale(previous)
            }
            outboundAttempts[canonicalTransferId] = attempt
        }
        return attempt
    }

    private fun currentOutboundAttempt(
        transferId: String,
        owner: WebRtcSecureOperationOwner,
    ): OutboundAttempt? = outboundAttempts[transferId]
        ?.takeIf { it.owner === owner }

    private fun requireExactOutboundAttempt(attempt: OutboundAttempt): OutboundAttemptState {
        if (outboundAttempts[attempt.transferId] !== attempt) {
            throw StaleWebRtcFileTransferOwnerException(attempt.transferId)
        }
        if (!webrtc.isCurrentSecureOperationOwner(attempt.owner)) {
            markOutboundStale(attempt)
            throw StaleWebRtcFileTransferOwnerException(attempt.transferId)
        }
        return attempt.state.get()
    }

    private fun requireActiveOutboundAttempt(attempt: OutboundAttempt) {
        val state = requireExactOutboundAttempt(attempt)
        if (state != OutboundAttemptState.ACTIVE) {
            throw OutboundAttemptTerminatedException(attempt.transferId, state)
        }
    }

    private fun attachOutboundCloseable(
        attempt: OutboundAttempt,
        closeable: Closeable,
    ) {
        requireActiveOutboundAttempt(attempt)
        check(attempt.closeable.compareAndSet(null, closeable)) {
            "outbound attempt already owns a blocking resource"
        }
        val state = attempt.state.get()
        if (state != OutboundAttemptState.ACTIVE) {
            closeOutboundResource(attempt)?.let { throw it }
            throw OutboundAttemptTerminatedException(attempt.transferId, state)
        }
    }

    private fun closeOutboundResource(attempt: OutboundAttempt): IOException? {
        val resource = attempt.closeable.getAndSet(null) ?: return null
        return try {
            resource.close()
            null
        } catch (error: IOException) {
            attempt.closeFailure.compareAndSet(null, error)
            error
        }
    }

    private fun finishOutboundInitiator(attempt: OutboundAttempt) {
        val closeFailure = closeOutboundResource(attempt)
        attempt.initiatorActive.set(false)
        if (closeFailure != null && attempt.state.get() in NON_TERMINAL_OUTBOUND_STATES) {
            failOutboundTransfer(attempt, "source close failed: ${closeFailure.javaClass.simpleName}")
            throw closeFailure
        }
    }

    private fun tryTransitionOutboundTerminal(
        attempt: OutboundAttempt,
        terminalState: OutboundAttemptState,
        allowedFrom: Set<OutboundAttemptState> = NON_TERMINAL_OUTBOUND_STATES,
        terminalProgress: (() -> Progress)? = null,
    ): Boolean {
        check(terminalState in TERMINAL_OUTBOUND_STATES) {
            "outbound target state must be terminal"
        }
        synchronized(attempt.linearizationLock) {
            if (outboundAttempts[attempt.transferId] !== attempt) return false
            val current = attempt.state.get()
            if (current !in allowedFrom) return false
            check(attempt.state.compareAndSet(current, terminalState)) {
                "outbound attempt state changed inside its linearization lock"
            }
            closeOutboundResource(attempt)
            terminalProgress?.let { _progress.value = it() }
            return true
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
        val attempt = outboundAttempts[transferId]
        if (attempt != null) {
            return attempt.state.get() in NON_TERMINAL_OUTBOUND_STATES &&
                webrtc.isCurrentSecureOperationOwner(attempt.owner)
        }
        val checkpointOwner = checkpointOwners[transferId] ?: return false
        return webrtc.isCurrentSecureOperationOwner(checkpointOwner)
    }

    fun isOperationAcknowledged(transferId: String): Boolean =
        outboundAttempts[transferId]?.state?.get() == OutboundAttemptState.ACKED

    private fun publishSentCompleteIfUnacknowledged(
        transferId: String,
        owner: WebRtcSecureOperationOwner,
        sentBytes: Long,
        totalBytes: Long,
        status: String,
    ) {
        val attempt = currentOutboundAttempt(transferId, owner) ?: return
        synchronized(attempt.linearizationLock) {
            if (outboundAttempts[transferId] !== attempt) return
            if (attempt.state.get() != OutboundAttemptState.COMPLETION_ARMED) return
            beforeOutboundProgressCommit(status)
            _progress.value = Progress(transferId, sentBytes, totalBytes, status)
        }
    }

    /**
     * Drop only owner-local in-memory work. Checkpoint bytes remain available for an explicit fresh
     * restart, but no continuation is allowed to send, cancel, ACK, or commit through a new owner.
     */
    private fun abandonStaleOperation(
        transferId: String,
        owner: WebRtcSecureOperationOwner,
    ) {
        currentOutboundAttempt(transferId, owner)?.let(::markOutboundStale)
        var receiveCleanup = ReceiveResourceCleanupReport(transferId)
        receiveContexts[transferId]?.takeIf { it.owner === owner }?.let { context ->
            if (receiveContexts.remove(transferId, context)) {
                context.declined = true
                receiveCleanup = cleanupReceiveContext(context, deletePartialFile = false)
            }
        }
        if (checkpointOwners[transferId] === owner && currentOutboundAttempt(transferId, owner) == null) {
            _progress.value = Progress(
                transferId = transferId,
                lastStatus = cleanupAwareStatus(
                    "transfer stopped: secure session replaced or rekeyed",
                    receiveCleanup,
                ),
            )
        }
    }

    private fun markOutboundStale(attempt: OutboundAttempt) {
        if (!tryTransitionOutboundTerminal(
                attempt,
                OutboundAttemptState.STALE,
                terminalProgress = {
                    Progress(
                        transferId = attempt.transferId,
                        lastStatus = outboundCloseAwareStatus(
                            attempt,
                            "transfer stopped: secure session replaced or rekeyed",
                        ),
                    )
                },
            )
        ) return
        stopOutboundTracking(attempt, deleteCheckpoint = false)
        sendBatchByTransferId[attempt.transferId]
            ?.takeIf { it.owner === attempt.owner }
            ?.let { sendBatchByTransferId.remove(attempt.transferId, it) }
    }

    private fun outboundCloseAwareStatus(
        attempt: OutboundAttempt,
        baseStatus: String,
    ): String = attempt.closeFailure.get()?.let { failure ->
        "$baseStatus; source close failed: ${failure.javaClass.simpleName}"
    } ?: baseStatus

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
        val deletion = enqueueLocalCheckpointDeletion(transferId)
        withContext(Dispatchers.IO) {
            deletion.awaitCompletion()
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
        openStream: () -> InputStream?
    ): String {
        val originalTransferId = checkpoint.transferId
        requireCurrentOwner(originalTransferId, owner)
        require(checkpoint.direction == TransferDirection.SEND) { "resume checkpoint is not a SEND" }
        val chunkSize = requireNotNull(checkpoint.chunkSize) { "send checkpoint missing chunkSize" }
        val totalChunks = requireNotNull(checkpoint.totalChunks) { "send checkpoint missing totalChunks" }
        val fileSize = requireNotNull(checkpoint.fileSize) { "send checkpoint missing fileSize" }
        val expectedTotalChunks =
            CrossNetworkFileTransferValidator.validatedExpectedChunkCount(fileSize, chunkSize)
        require(totalChunks == expectedTotalChunks) {
            "send checkpoint totalChunks mismatch: expected $expectedTotalChunks, got $totalChunks"
        }
        val canonicalAcked = checkpoint.ackedChunks.distinct().sorted()
        require(checkpoint.ackedChunks.contentEquals(canonicalAcked.toIntArray())) {
            "send checkpoint ackedChunks must be unique and sorted"
        }
        require(canonicalAcked.all { it in 0 until totalChunks }) {
            "send checkpoint ackedChunks contains an out-of-range index"
        }
        require(checkpoint.receivedChunks.isEmpty() && checkpoint.receivedChunkSha256HexByIndex.isEmpty()) {
            "send checkpoint contains receive-side chunk state"
        }
        currentOutboundAttempt(originalTransferId, owner)?.let { previousAttempt ->
            check(previousAttempt.state.get() == OutboundAttemptState.TIMED_OUT) {
                "only a timed-out outbound attempt may be recovered"
            }
        }
        val batch = batchManifestStore?.list()?.firstOrNull { manifest ->
            manifest.entries.any { it.transferId == originalTransferId }
        }
        if (batch != null) {
            throw BatchResumeMigrationUnsupportedException(originalTransferId, batch.batchId)
        }
        if (checkpointOwners[originalTransferId] == null) {
            bindCheckpointOwner(originalTransferId, owner)
        }
        if (checkpointOwners[originalTransferId] !== owner) {
            throw StaleWebRtcFileTransferOwnerException(originalTransferId)
        }

        // The wire has no attempt generation. A fresh UUID is therefore mandatory: an ACK delayed
        // from the timed-out attempt must be unable to authenticate completion of this recovery.
        val transferId = UUID.randomUUID().toString()
        bindCheckpointOwner(transferId, owner)
        val now = System.currentTimeMillis()
        val migratedCheckpoint = checkpoint.copy(
            transferId = transferId,
            ackedChunks = intArrayOf(),
            lastStatus = "recovered from timed-out transfer $originalTransferId",
            createdAtMs = now,
            updatedAtMs = now,
        )
        try {
            enqueueCheckpointMutation(transferId, owner, CheckpointMutation.SAVE) {
                save(migratedCheckpoint)
            }.awaitCompletion()
            enqueueCheckpointMutation(originalTransferId, owner, CheckpointMutation.DELETE) {
                delete(originalTransferId)
            }.awaitCompletion()
        } catch (migrationFailure: Exception) {
            // The original checkpoint is deliberately retained if either durable step fails. If the
            // new save succeeded but old deletion failed, remove only the newly-created recovery
            // record so a retry cannot accumulate ambiguous local recovery entries.
            runCatching {
                enqueueCheckpointMutation(originalTransferId, owner, CheckpointMutation.SAVE) {
                    save(checkpoint)
                }.awaitCompletion()
            }.exceptionOrNull()?.let(migrationFailure::addSuppressed)
            runCatching {
                enqueueLocalCheckpointDeletion(transferId).awaitCompletion()
            }.exceptionOrNull()?.let(migrationFailure::addSuppressed)
            throw migrationFailure
        }

        val attempt = beginOutboundAttempt(transferId, owner)
        try {
            requireActiveOutboundAttempt(attempt)

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
            sendActiveOutbound(attempt, encode(meta))
            startIdleWatchdogFor(metadata.transferId, owner)
            publishActiveOutboundProgress(attempt, 0, metadata.fileSize, "resume: sent metadata")

            val input = openStream() ?: error("openInputStream failed for resume")
            requireActiveOutboundAttempt(attempt)
            attachOutboundCloseable(attempt, input)
            val stream = input
            // Buffer chunks for resend only when the whole file fits the resend cache; for larger
            // files we stream once (no in-memory resend cache) — the resume start point still comes
            // from the checkpoint, not the cache.
            val bufferedChunks = if (fileSize <= maxResendCacheBytes) ArrayList<ByteArray>(totalChunks) else null
            val buf = ByteArray(chunkSize)
            var index = 0
            var sent = 0L
            val fileDigest = MessageDigest.getInstance("SHA-256")
            val chunkHashes = ArrayList<ByteArray>(totalChunks)
            while (true) {
                val n = stream.read(buf)
                requireActiveOutboundAttempt(attempt)
                if (n < 0) break
                if (n == 0) continue
                if (sent + n > fileSize || index >= totalChunks) {
                    failOutboundWithTerminalError(attempt, fileSize, "file stream length mismatch")
                    error("resume stream length mismatch: expected $fileSize bytes, read more than declared")
                }
                val chunkBytes = if (n == buf.size) buf else buf.copyOfRange(0, n)
                fileDigest.update(chunkBytes)
                chunkHashes.add(sha256(chunkBytes))
                bufferedChunks?.add(chunkBytes)
                sendOutboundChunk(attempt, index, chunkBytes, receivedBytes = sent + n)
                sent += n
                index += 1
            }
            if (sent != fileSize || index != totalChunks) {
                failOutboundWithTerminalError(attempt, fileSize, "file stream length mismatch")
                error(
                    "resume stream length mismatch: expected $fileSize bytes/$totalChunks chunks, " +
                        "read $sent bytes/$index chunks",
                )
            }
            requireActiveOutboundAttempt(attempt)

            val fileSha256 = fileDigest.digest()

            // Register a send context so NACK-driven resend works after resume; pre-mark the chunks
            // the checkpoint already confirmed so they are never retransmitted unless the peer asks.
            if (bufferedChunks != null && bufferedChunks.size == totalChunks) {
                val sendCtx = SendContext(
                    owner = owner,
                    transferId = metadata.transferId,
                    attemptGeneration = attempt.generation,
                    totalChunks = totalChunks,
                    totalBytes = fileSize,
                    fileSha256 = fileSha256,
                    chunks = bufferedChunks
                )
                sendContexts[metadata.transferId] = sendCtx
            }

            val merkleRoot = MerkleSha256.root(chunkHashes)
            val merkleSig = computeOutboundHmac(
                attempt = attempt,
                preimage =
                MerkleRootAuthV1.preimage(transferId = transferId, merkleRoot = merkleRoot, fileSha256 = fileSha256)
            )
            requireActiveOutboundAttempt(attempt)
            armAndSendOutboundComplete(
                attempt,
                OutboundCompletionExpectation(fileSize, fileSha256.copyOf()),
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
            if (attempt.state.get() == OutboundAttemptState.COMPLETION_ARMED) {
                startResendLoopIfNeeded(transferId, owner)
                publishSentCompleteIfUnacknowledged(
                    transferId = transferId,
                    owner = owner,
                    sentBytes = metadata.fileSize,
                    totalBytes = metadata.fileSize,
                    status = "resume: sent complete",
                )
            }
        } catch (error: Throwable) {
            failOutboundIfStillRunning(attempt, error)
            throw error
        } finally {
            finishOutboundInitiator(attempt)
        }
        return transferId
    }

    fun sendTestMetadata() {
        val transferId = UUID.randomUUID().toString()
        val owner = captureSecureOwner(transferId)
        val attempt = beginOutboundAttempt(transferId, owner)
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
        try {
            sendActiveOutbound(attempt, encode(msg))
            publishActiveOutboundProgress(attempt, 0L, 5L, "sent metadata(test)")
        } catch (error: Throwable) {
            failOutboundIfStillRunning(attempt, error)
            throw error
        } finally {
            finishOutboundInitiator(attempt)
        }
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
            val attempt = beginOutboundAttempt(transferId, owner)
            try {
            requireActiveOutboundAttempt(attempt)
            val totalBytes = bytes.size.toLong()
            require(totalBytes <= maxResendCacheBytes) {
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
                attemptGeneration = attempt.generation,
                totalChunks = totalChunks,
                totalBytes = totalBytes,
                fileSha256 = sha256(bytes),
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

            sendActiveOutbound(
                attempt,
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
            publishActiveOutboundProgress(attempt, 0, totalBytes, "sent metadata")

            // send all chunks once
            val fileSha256 = sendCtx.fileSha256
            val chunkHashes = chunks.map { sha256(it) }
            val merkleRoot = MerkleSha256.root(chunkHashes)
            val merkleSig = computeOutboundHmac(
                attempt = attempt,
                preimage = MerkleRootAuthV1.preimage(
                    transferId = metadata.transferId,
                    merkleRoot = merkleRoot,
                    fileSha256 = fileSha256,
                ),
            )
            chunks.forEachIndexed { index, chunkBytes ->
                sendOutboundChunk(attempt, index, chunkBytes)
                val sentSoFar = kotlin.math.min(((index + 1).toLong() * chunkSize.toLong()), totalBytes)
                publishActiveOutboundProgress(
                    attempt,
                    sentSoFar,
                    totalBytes,
                    "sent chunk#${index + 1}",
                )
            }

            armAndSendOutboundComplete(
                attempt,
                OutboundCompletionExpectation(totalBytes, fileSha256.copyOf()),
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

            if (attempt.state.get() == OutboundAttemptState.COMPLETION_ARMED) {
                startResendLoopIfNeeded(metadata.transferId, owner)
            }
            } catch (error: Throwable) {
                failOutboundIfStillRunning(attempt, error)
                throw error
            } finally {
                finishOutboundInitiator(attempt)
            }
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
            val attempt = beginOutboundAttempt(transferId, owner)
            try {
            requireActiveOutboundAttempt(attempt)
            val totalBytes = contentResolver.openAssetFileDescriptor(uri, "r")?.use { it.length } ?: -1L
            requireActiveOutboundAttempt(attempt)
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
            requireActiveOutboundAttempt(attempt)
            attachOutboundCloseable(attempt, input)
            run {
                val stream = input
                val bufferedChunks = if (totalBytes <= maxResendCacheBytes) ArrayList<ByteArray>(totalChunks) else null
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

                sendActiveOutbound(
                    attempt,
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
                publishActiveOutboundProgress(attempt, 0, totalBytes, "sent metadata")

                val buf = ByteArray(chunkSize)
                var sent = 0L
                var index = 0
                val fileDigest = MessageDigest.getInstance("SHA-256")
                val chunkHashes = ArrayList<ByteArray>()
                while (true) {
                    val n = stream.read(buf)
                    requireActiveOutboundAttempt(attempt)
                    if (n < 0) break
                    if (n == 0) continue
                    if (sent + n > totalBytes || index >= totalChunks) {
                        failOutboundWithTerminalError(attempt, totalBytes, "file stream length mismatch")
                        error("file stream length mismatch: expected $totalBytes bytes, read more than declared")
                    }
                    val chunkBytes = if (n == buf.size) buf else buf.copyOfRange(0, n)
                    fileDigest.update(chunkBytes)
                    chunkHashes.add(sha256(chunkBytes))
                    bufferedChunks?.add(chunkBytes)
                    sendOutboundChunk(attempt, index, chunkBytes, receivedBytes = sent + n)
                    sent += n
                    index += 1
                    publishActiveOutboundProgress(attempt, sent, totalBytes, "sent chunk#$index")
                }

                if (sent != totalBytes || index != totalChunks) {
                    failOutboundWithTerminalError(attempt, totalBytes, "file stream length mismatch")
                    error(
                        "file stream length mismatch: expected $totalBytes bytes/$totalChunks chunks, " +
                            "read $sent bytes/$index chunks",
                    )
                }
                requireActiveOutboundAttempt(attempt)

                val fileSha256 = fileDigest.digest()
                if (bufferedChunks != null) {
                    require(bufferedChunks.size == totalChunks) { "file chunk count mismatch" }
                    sendContexts[metadata.transferId] = SendContext(
                        owner = owner,
                        transferId = metadata.transferId,
                        attemptGeneration = attempt.generation,
                        totalChunks = totalChunks,
                        totalBytes = totalBytes,
                        fileSha256 = fileSha256,
                        chunks = bufferedChunks
                    )
                }

                val merkleRoot = MerkleSha256.root(chunkHashes)
                val merkleSig = computeOutboundHmac(
                    attempt = attempt,
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
                armAndSendOutboundComplete(
                    attempt,
                    OutboundCompletionExpectation(totalBytes, fileSha256.copyOf()),
                    encode(complete),
                )
                publishSentCompleteIfUnacknowledged(
                    transferId = metadata.transferId,
                    owner = owner,
                    sentBytes = sent,
                    totalBytes = totalBytes,
                    status = "sent complete",
                )

                if (
                    bufferedChunks != null &&
                    attempt.state.get() == OutboundAttemptState.COMPLETION_ARMED
                ) {
                    startResendLoopIfNeeded(metadata.transferId, owner)
                }
            }
            } catch (error: Throwable) {
                failOutboundIfStillRunning(attempt, error)
                throw error
            } finally {
                finishOutboundInitiator(attempt)
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
                if (!webrtc.isCurrentSecureOperationOwner(owner)) {
                    val pendingBatchCommit = sendBatchByTransferId[plan.transferId]
                        ?.takeIf { it.owner === owner }
                    if (pendingBatchCommit != null) {
                        persistBatchEntryStatus(
                            owner,
                            batchToken,
                            plan.transferId,
                            BatchManifestEntry.Status.FAILED,
                        )
                    }
                    abandonStaleOperation(plan.transferId, owner)
                    throw StaleWebRtcFileTransferOwnerException(plan.transferId)
                }
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
                if (outboundAttempts[metadata.transferId]?.owner === owner) {
                    rejectInboundMessage(owner, msg, "transferId is already reserved by an outbound attempt")
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

                if (
                    inboundFileDestinationPolicy == InboundFileDestinationPolicy.IN_MEMORY &&
                    metadata.fileSize > MAX_IN_MEMORY_RECEIVE_BYTES
                ) {
                    rejectInboundMessage(owner, msg, "in-memory receive exceeds supported range")
                    return
                }
                val admissionFailure = tryAdmitInboundTransfer(
                    metadata.transferId,
                    metadata.fileSize,
                )
                if (admissionFailure != null) {
                    rejectInboundMessage(owner, msg, admissionFailure)
                    return
                }
                val storage = try {
                    when (inboundFileDestinationPolicy) {
                        InboundFileDestinationPolicy.IN_MEMORY -> ReceiveStorage(
                            partialFile = null,
                            raf = null,
                            appPrivateTemporaryFile = null,
                        )

                        InboundFileDestinationPolicy.DOWNLOADS -> {
                            val partialDir = File(
                                requireNotNull(appContext).applicationContext.filesDir,
                                "skybridge_inbound_partials",
                            ).apply { mkdirs() }
                            val partialFile = existingPartial
                                ?: File(partialDir, "${metadata.transferId}.partial")
                            ReceiveStorage(
                                partialFile = partialFile,
                                raf = RandomAccessFile(partialFile, "rw"),
                                appPrivateTemporaryFile = null,
                            )
                        }

                        InboundFileDestinationPolicy.APP_PRIVATE_DURABLE -> {
                            val committer = requireNotNull(appPrivateInboundFileCommitter)
                            val temporaryFile = if (existingPartial != null) {
                                committer.reopenOwnedTemporaryFile(metadata.transferId, existingPartial)
                            } else {
                                committer.createExclusiveTemporaryFile(metadata.transferId)
                            }
                            ReceiveStorage(
                                partialFile = temporaryFile.path.toFile(),
                                raf = null,
                                appPrivateTemporaryFile = temporaryFile,
                            )
                        }
                    }
                } catch (error: Exception) {
                    inboundAdmission.release(metadata.transferId)
                    rejectInboundMessage(
                        owner,
                        msg,
                        "inbound staging failed: ${error.javaClass.simpleName}",
                    )
                    return
                }

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
                    partialFile = storage.partialFile,
                    raf = storage.raf,
                    appPrivateTemporaryFile = storage.appPrivateTemporaryFile,
                    receivedBytes = storage.partialFile?.length() ?: 0L
                )
                val previousContext = receiveContexts.putIfAbsent(metadata.transferId, ctx)
                if (previousContext != null) {
                    cleanupReceiveContext(ctx, deletePartialFile = true)
                    if (previousContext.owner === owner) {
                        sendFt(
                            owner,
                            metadata.transferId,
                            encode(
                                CrossNetworkFileTransferMessage(
                                    version = msg.version,
                                    op = CrossNetworkFileTransferOp.metadataAck,
                                    transferId = metadata.transferId,
                                    receivedBytes = metadata.fileSize,
                                ),
                            ),
                        )
                    } else {
                        rejectInboundMessage(owner, msg, "transfer is already owned by another secure session")
                    }
                    return
                }
                // Watch this receive for idle/interrupt timeout (Requirement 5.12).
                startIdleWatchdogFor(metadata.transferId, owner)
                // preload received chunks if we have them (resume after restart)
                ctx.receivedChunkIndices.addAll(preloadReceivedChunks)
                try {
                    restoreContiguousReceiveProgress(ctx, existingCp, storage.partialFile)
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
                            partialPath = storage.partialFile?.absolutePath,
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
                    if (ctx.appPrivateTemporaryFile != null) {
                        try {
                            ctx.appPrivateTemporaryFile?.writeAt(offset, next)
                        } catch (e: Exception) {
                            rejectReceive(ctx, "private partial file write failed: ${e.javaClass.simpleName}")
                            return
                        }
                    } else if (ctx.raf != null) {
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
                    val ctx = currentSendContext(transferId, owner)
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
                    val ctx = currentSendContext(transferId, owner) ?: return
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
                val attempt = currentOutboundAttempt(msg.transferId, owner) ?: return
                if (attempt.state.get() != OutboundAttemptState.COMPLETION_ARMED) return
                val expectation = attempt.completionExpectation.get() ?: return
                val acknowledgedBytes = msg.receivedBytes
                val acknowledgedHash = msg.fileSha256
                if (
                    acknowledgedBytes != expectation.totalBytes ||
                    acknowledgedHash == null ||
                    acknowledgedHash.size != SHA256_BYTES ||
                    !acknowledgedHash.contentEquals(expectation.fileSha256)
                ) {
                    failOutboundTransfer(attempt, "invalid complete acknowledgement evidence")
                    return
                }
                acknowledgeOutboundTransfer(attempt, expectation)
            }
            CrossNetworkFileTransferOp.error -> {
                val attempt = currentOutboundAttempt(msg.transferId, owner)
                val receiveCtx = receiveContexts[msg.transferId]?.takeIf { it.owner === owner }
                if (
                    attempt != null &&
                    attempt.state.get() in TERMINAL_OUTBOUND_STATES
                ) return
                if (
                    attempt == null &&
                    receiveCtx == null &&
                    checkpointOwners[msg.transferId] !== owner
                ) return
                stopIdleWatchdogFor(msg.transferId, owner)
                val peerFailureReason = "peer error: ${msg.message ?: "unspecified"}"
                val hasOutboundOperation = attempt?.state?.get() in NON_TERMINAL_OUTBOUND_STATES
                if (hasOutboundOperation) {
                    failOutboundTransfer(requireNotNull(attempt), peerFailureReason)
                }
                val receiveCleanup = receiveCtx?.let {
                    launchReceiveBatchEntryStatus(it, BatchManifestEntry.Status.FAILED)
                    releaseTransferResources(msg.transferId, owner)
                } ?: ReceiveResourceCleanupReport(msg.transferId)
                if (attempt == null && receiveCtx != null) {
                    _progress.value = Progress(
                        transferId = msg.transferId,
                        lastStatus = cleanupAwareStatus(
                            peerFailureReason,
                            receiveCleanup,
                        ),
                    )
                }
            }
            CrossNetworkFileTransferOp.cancel -> {
                // Peer cancelled this transfer: stop send/receive for THIS transfer and release
                // its resources. cancel is part of the existing wire enum, so this is not a wire
                // protocol change. Do not echo another cancel back to the peer.
                val attempt = currentOutboundAttempt(msg.transferId, owner)
                val operationOwner = attempt?.owner
                    ?: receiveContexts[msg.transferId]?.owner
                    ?: checkpointOwners[msg.transferId]
                if (operationOwner !== owner) return
                if (attempt != null) {
                    val outboundStatus = cleanupAwareStatus(
                        outboundCloseAwareStatus(attempt, "cancelled by peer"),
                        ReceiveResourceCleanupReport(msg.transferId),
                    )
                    if (!tryTransitionOutboundTerminal(
                            attempt,
                            OutboundAttemptState.CANCELLED,
                            terminalProgress = {
                                Progress(msg.transferId, lastStatus = outboundStatus)
                            },
                        )
                    ) return
                }
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
                if (attempt == null) {
                    _progress.value = Progress(
                        transferId = msg.transferId,
                        lastStatus = cleanupAwareStatus("cancelled by peer", receiveCleanup),
                    )
                }
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
        val attempt = outboundAttempts[transferId]
        val receiveContext = receiveContexts[transferId]
        val owner = attempt?.owner
            ?: receiveContext?.owner
            ?: checkpointOwners[transferId]
            ?: return
        if (!webrtc.isCurrentSecureOperationOwner(owner)) {
            abandonStaleOperation(transferId, owner)
            return
        }
        if (attempt != null && !tryTransitionOutboundTerminal(
                attempt,
                OutboundAttemptState.CANCELLED,
                terminalProgress = {
                    Progress(
                        transferId = transferId,
                        lastStatus = outboundCloseAwareStatus(attempt, "cancelled"),
                    )
                },
            )
        ) return
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
            val payload = encode(
                CrossNetworkFileTransferMessage(
                    version = version,
                    op = CrossNetworkFileTransferOp.cancel,
                    transferId = transferId,
                ),
            )
            if (attempt != null) sendTerminalOutbound(attempt, payload) else sendFt(owner, transferId, payload)
        }
        val receiveCleanup = releaseTransferResources(transferId, owner)
        val cancellationStatus = if (notification.isSuccess) {
            "cancelled"
        } else {
            "cancelled locally; peer notification failed: ${notification.exceptionOrNull()?.javaClass?.simpleName}"
        }
        if (attempt == null) {
            _progress.value = Progress(
                transferId = transferId,
                lastStatus = cleanupAwareStatus(cancellationStatus, receiveCleanup),
            )
        }
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
        val attempt = currentOutboundAttempt(transferId, owner)
        if (attempt != null) {
            val total = outboundTotalBytes(attempt)
            val confirmed = _progress.value
                .takeIf { it.transferId == transferId }
                ?.sentBytes
                ?.coerceAtMost(total)
                ?: 0L
            val timeoutStatus = TransferActivityTimeoutDecision.statusMessage(
                TransferActivityTimeoutDecision.reasonFor(
                    sessionUsable = webrtc.isCurrentSecureOperationOwner(owner),
                ),
                idleInterruptTimeoutMs,
            )
            if (!tryTransitionOutboundTerminal(
                    attempt,
                    OutboundAttemptState.TIMED_OUT,
                    terminalProgress = {
                        Progress(
                            transferId = transferId,
                            sentBytes = confirmed,
                            totalBytes = total,
                            lastStatus = outboundCloseAwareStatus(attempt, timeoutStatus),
                        )
                    },
                )
            ) return
            activityByTransferId.remove(transferId, expectedActivity)
        } else if (!activityByTransferId.remove(transferId, expectedActivity)) {
            return
        }

        // Stop this transfer's resend loop immediately (no more chunk retransmits).
        resendJobs[transferId]?.takeIf { it.owner === owner }?.let { ownedJob ->
            if (resendJobs.remove(transferId, ownedJob)) ownedJob.job.cancel()
        }

        // Capture progress figures before dropping in-memory state.
        val sendCtx = sendContexts[transferId]
            ?.takeIf {
                it.owner === owner &&
                    (attempt == null || it.attemptGeneration == attempt.generation)
            }
            ?.also { sendContexts.remove(transferId, it) }
        val completionExpectation = attempt?.completionExpectation?.get()
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
        if (completionExpectation != null) {
            totalBytes = completionExpectation.totalBytes
        }
        if (sendCtx != null) {
            // Sender-side "verified" progress is the acked-chunk boundary already recorded in the
            // checkpoint; report acked bytes as a lower bound for the UI.
            receivedBytes = (sendCtx.delivery.deliveredCount().toLong() * approxChunkBytes(sendCtx))
                .coerceAtMost(sendCtx.totalBytes)
        }

        // Attribute the reason: session dropped vs simply idle.
        val reason = TransferActivityTimeoutDecision.reasonFor(
            sessionUsable = webrtc.isCurrentSecureOperationOwner(owner),
        )
        if (attempt == null) {
            _progress.value = Progress(
                transferId = transferId,
                sentBytes = receivedBytes,
                totalBytes = totalBytes,
                lastStatus = cleanupAwareStatus(
                    TransferActivityTimeoutDecision.statusMessage(reason, idleInterruptTimeoutMs),
                    receiveCleanup,
                ),
            )
        }
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
            when (inboundFileDestinationPolicy) {
                InboundFileDestinationPolicy.IN_MEMORY ->
                    error("in-memory receive checkpoint must not contain a partial path")

                InboundFileDestinationPolicy.DOWNLOADS -> {
                    val context = appContext ?: error("checkpoint partialPath requires app context")
                    val original = File(path)
                    require(!java.nio.file.Files.isSymbolicLink(original.toPath())) {
                        "checkpoint partialPath must not be a symbolic link"
                    }
                    val partialDir = File(
                        context.applicationContext.filesDir,
                        "skybridge_inbound_partials",
                    ).canonicalFile
                    val partial = original.canonicalFile
                    require(partial.name == "${metadata.transferId}.partial") {
                        "checkpoint partialPath file mismatch"
                    }
                    require(partial.path.startsWith(partialDir.path + File.separator)) {
                        "checkpoint partialPath outside inbound partial directory"
                    }
                }

                InboundFileDestinationPolicy.APP_PRIVATE_DURABLE -> require(
                    requireNotNull(appPrivateInboundFileCommitter).ownsTemporaryFile(
                        File(path),
                        metadata.transferId,
                    ),
                ) {
                    "checkpoint partialPath is not an owned app-private staging file"
                }
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
        finalizeReceive(ctx, decision)
    }

    private data class ReceiveStorage(
        val partialFile: File?,
        val raf: RandomAccessFile?,
        val appPrivateTemporaryFile: AppPrivateInboundFileCommitter.OwnedTemporaryFile?,
    )

    private data class DownloadsSaveResult(
        val uri: Uri,
        val displayName: String
    )

    private fun finalizeReceive(
        ctx: ReceiveContext,
        decision: InboundFileTransferDecision.Accept,
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
        val receiveFile = removed.raf
        removed.raf = null
        val appPrivateTemporaryFile = removed.appPrivateTemporaryFile
        if (receiveFile != null || appPrivateTemporaryFile != null) {
            val closeResult = if (appPrivateTemporaryFile != null) {
                appPrivateTemporaryFile.synchronizeAndClose()
            } else {
                closeReceiveFileForFinalization(requireNotNull(receiveFile))
            }
            if (!closeResult.isSuccessful) {
                val actualSize = removed.partialFile?.length() ?: removed.buffer.size().toLong()
                val retryCleanup = cleanupReceiveContext(removed, deletePartialFile = true)
                val cleanup = if (retryCleanup.isSuccessful) {
                    retryCleanup
                } else {
                    ReceiveResourceCleanupReport(
                        transferId = removed.transferId,
                        failures = listOf(
                            ReceiveResourceCleanupFailure(
                                stage = ReceiveResourceCleanupStage.FINALIZE_PARTIAL_FILE,
                                cause = IOException(
                                    "receive file finalization failed: ${closeResult.failedStages.joinToString(",")}",
                                ),
                            ),
                        ) + retryCleanup.failures,
                    )
                }
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
        val actualSize = removed.partialFile?.length() ?: removed.buffer.size().toLong()
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

        if (inboundFileDestinationPolicy == InboundFileDestinationPolicy.DOWNLOADS) {
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
        } else if (inboundFileDestinationPolicy == InboundFileDestinationPolicy.APP_PRIVATE_DURABLE) {
            val committer = requireNotNull(appPrivateInboundFileCommitter)
            val temporaryFile = requireNotNull(appPrivateTemporaryFile) {
                "app-private receive completed without an owned staging file"
            }
            val committedFile = try {
                var result: File? = null
                val committedForOwner = webrtc.runIfCurrentSecureOperationOwner(removed.owner) {
                    result = committer.commitValidated(
                        temporaryFile = temporaryFile,
                        preferredFileName = decision.downloadsDisplayName.ifBlank {
                            removed.fileName ?: "skybridge-received"
                        },
                    )
                }
                if (!committedForOwner) {
                    throw StaleWebRtcFileTransferOwnerException(removed.transferId)
                }
                requireNotNull(result)
            } catch (error: Exception) {
                if (error is StaleWebRtcFileTransferOwnerException) {
                    runCatching { committer.discard(temporaryFile) }
                    ensureFinalizationOwnerIsCurrent(removed)
                    return
                }
                failFinalizedReceive(
                    removed = removed,
                    actualSize = actualSize,
                    expectedSize = expectedSize,
                    status = "received complete (app-private commit failed: ${error.javaClass.simpleName})",
                    peerMessage = "app-private commit failed",
                )
                return
            }
            removed.appPrivateTemporaryFile = null
            removed.partialFile = committedFile
            outLocalPath = committedFile.absolutePath
            outBytes = null
        }

        if (!ensureFinalizationOwnerIsCurrent(removed)) return

        launchReceiveBatchEntryStatus(removed, BatchManifestEntry.Status.COMPLETED)
        releaseInboundAdmission(removed)
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
                    receivedBytes = actualSize,
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

    private fun startResendLoopIfNeeded(
        transferId: String,
        owner: WebRtcSecureOperationOwner,
    ) {
        val attempt = currentOutboundAttempt(transferId, owner)
            ?.takeIf { it.state.get() == OutboundAttemptState.COMPLETION_ARMED }
            ?: return
        sendContexts[transferId]?.takeIf {
            it.owner === owner && it.attemptGeneration == attempt.generation
        } ?: return
        // lightweight retry loop: only resend unacked chunks a few times
        val job = scope.launch {
            val resendDelayMs = 1200L
            while (isActive) {
                delay(resendDelayMs)
                if (!webrtc.isCurrentSecureOperationOwner(owner)) {
                    abandonStaleOperation(transferId, owner)
                    break
                }
                if (attempt.state.get() != OutboundAttemptState.COMPLETION_ARMED) break
                val stillTracked = sendContexts[transferId]
                    ?.takeIf {
                        it.owner === owner &&
                            it.attemptGeneration == attempt.generation
                    }
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
            val attempt = requireNotNull(currentOutboundAttempt(ctx.transferId, ctx.owner)) {
                "outbound attempt missing for ${ctx.transferId}"
            }
            check(attempt.generation == ctx.attemptGeneration) {
                "outbound attempt generation changed for ${ctx.transferId}"
            }
            sendOutboundChunk(attempt, index, ctx.chunks[index])
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
        val attempt = currentOutboundAttempt(ctx.transferId, ctx.owner)
            ?.takeIf { it.generation == ctx.attemptGeneration }
            ?: return
        failOutboundTransfer(attempt, reason)
    }

    private fun failOutboundTransfer(
        attempt: OutboundAttempt,
        reason: String,
        deleteCheckpoint: Boolean = true,
    ): Boolean {
        if (!webrtc.isCurrentSecureOperationOwner(attempt.owner)) {
            markOutboundStale(attempt)
            return false
        }
        val totalBytes = outboundTotalBytes(attempt)
        if (!tryTransitionOutboundTerminal(
                attempt,
                OutboundAttemptState.FAILED,
                terminalProgress = {
                    Progress(
                        transferId = attempt.transferId,
                        sentBytes = totalBytes,
                        totalBytes = totalBytes,
                        lastStatus = outboundCloseAwareStatus(attempt, "send failed: $reason"),
                    )
                },
            )
        ) return false
        stopOutboundTracking(attempt, deleteCheckpoint = deleteCheckpoint)
        terminalizeOutboundBatch(attempt, BatchManifestEntry.Status.FAILED)
        return true
    }

    private fun failOutboundIfStillRunning(
        attempt: OutboundAttempt,
        error: Throwable,
    ) {
        when (error) {
            is StaleWebRtcFileTransferOwnerException -> markOutboundStale(attempt)
            is OutboundAttemptTerminatedException -> Unit
            is CancellationException -> {
                if (tryTransitionOutboundTerminal(
                        attempt,
                        OutboundAttemptState.CANCELLED,
                        terminalProgress = {
                            Progress(
                                attempt.transferId,
                                lastStatus = outboundCloseAwareStatus(attempt, "cancelled"),
                            )
                        },
                    )
                ) {
                    stopOutboundTracking(attempt, deleteCheckpoint = true)
                    terminalizeOutboundBatch(attempt, BatchManifestEntry.Status.CANCELLED)
                }
            }
            else -> failOutboundTransfer(
                attempt,
                "local send failed: ${error.javaClass.simpleName}",
                deleteCheckpoint = error !is CheckpointMutationException,
            )
        }
    }

    private fun failOutboundWithTerminalError(
        attempt: OutboundAttempt,
        totalBytes: Long,
        reason: String,
    ) {
        if (!failOutboundTransfer(attempt, reason)) return
        val payload = encode(
            CrossNetworkFileTransferMessage(
                version = 1,
                op = CrossNetworkFileTransferOp.error,
                transferId = attempt.transferId,
                receivedBytes = totalBytes,
                message = reason,
            ),
        )
        sendTerminalOutbound(attempt, payload)
    }

    private fun acknowledgeOutboundTransfer(
        attempt: OutboundAttempt,
        expectation: OutboundCompletionExpectation,
    ) {
        if (!tryTransitionOutboundTerminal(
                attempt,
                OutboundAttemptState.ACKED,
                allowedFrom = setOf(OutboundAttemptState.COMPLETION_ARMED),
                terminalProgress = {
                    Progress(
                        transferId = attempt.transferId,
                        sentBytes = expectation.totalBytes,
                        totalBytes = expectation.totalBytes,
                        lastStatus = outboundCloseAwareStatus(
                            attempt,
                            "send complete acknowledged",
                        ),
                    )
                },
            )
        ) return
        stopOutboundTracking(attempt, deleteCheckpoint = true)
        terminalizeOutboundBatch(attempt, BatchManifestEntry.Status.COMPLETED)
    }

    private fun stopOutboundTracking(
        attempt: OutboundAttempt,
        deleteCheckpoint: Boolean,
    ) {
        resendJobs[attempt.transferId]?.takeIf { it.owner === attempt.owner }?.let { ownedJob ->
            if (resendJobs.remove(attempt.transferId, ownedJob)) ownedJob.job.cancel()
        }
        sendContexts[attempt.transferId]
            ?.takeIf {
                it.owner === attempt.owner &&
                    it.attemptGeneration == attempt.generation
            }
            ?.let { sendContexts.remove(attempt.transferId, it) }
        stopIdleWatchdogFor(attempt.transferId, attempt.owner)
        if (deleteCheckpoint && checkpointOwners[attempt.transferId] === attempt.owner) {
            enqueueCheckpointMutation(attempt.transferId, attempt.owner, CheckpointMutation.DELETE) {
                delete(attempt.transferId)
            }
        }
    }

    private fun terminalizeOutboundBatch(
        attempt: OutboundAttempt,
        status: BatchManifestEntry.Status,
    ) {
        sendBatchByTransferId[attempt.transferId]
            ?.takeIf { it.owner === attempt.owner }
            ?.let { ref ->
                launchPersistBatchEntryStatus(
                    attempt.owner,
                    ref.batchToken,
                    attempt.transferId,
                    status,
                )
                sendBatchByTransferId.remove(attempt.transferId, ref)
                updateBatchFileStatus(ref.batchId, attempt.transferId, status)
            }
    }

    private fun outboundTotalBytes(attempt: OutboundAttempt): Long =
        attempt.completionExpectation.get()?.totalBytes
            ?: sendContexts[attempt.transferId]
                ?.takeIf {
                    it.owner === attempt.owner &&
                        it.attemptGeneration == attempt.generation
                }
                ?.totalBytes
            ?: _progress.value.takeIf { it.transferId == attempt.transferId }?.totalBytes
            ?: 0L

    private fun currentSendContext(
        transferId: String,
        owner: WebRtcSecureOperationOwner,
    ): SendContext? {
        val attempt = currentOutboundAttempt(transferId, owner) ?: return null
        if (attempt.state.get() !in NON_TERMINAL_OUTBOUND_STATES) return null
        return sendContexts[transferId]?.takeIf {
            it.owner === owner && it.attemptGeneration == attempt.generation
        }
    }

    private fun sendCompleteFromContext(ctx: SendContext) {
        val attempt = currentOutboundAttempt(ctx.transferId, ctx.owner)
            ?.takeIf { it.generation == ctx.attemptGeneration }
            ?: throw StaleWebRtcFileTransferOwnerException(ctx.transferId)
        check(attempt.state.get() == OutboundAttemptState.COMPLETION_ARMED) {
            "complete resend requires an armed outbound attempt"
        }
        val leaves = ctx.chunks.map { sha256(it) }
        val merkleRoot = MerkleSha256.root(leaves)
        val merkleSig = computeOutboundHmac(
            attempt = attempt,
            preimage = MerkleRootAuthV1.preimage(
                transferId = ctx.transferId,
                merkleRoot = merkleRoot,
                fileSha256 = ctx.fileSha256,
            ),
        )

        sendArmedOutbound(
            attempt,
            encode(
                CrossNetworkFileTransferMessage(
                    version = 1,
                    op = CrossNetworkFileTransferOp.complete,
                    transferId = ctx.transferId,
                    receivedBytes = ctx.totalBytes,
                    fileSha256 = ctx.fileSha256,
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
        attempt: OutboundAttempt,
        preimage: ByteArray,
    ): ByteArray {
        val before = requireExactOutboundAttempt(attempt)
        check(before in NON_TERMINAL_OUTBOUND_STATES) {
            "outbound HMAC requires a live attempt"
        }
        val result = webrtc.computeOutboundHmacSha256(attempt.owner, preimage) ?: run {
            requireExactOutboundAttempt(attempt)
            error("file transfer HMAC unavailable for current secure owner")
        }
        val after = requireExactOutboundAttempt(attempt)
        if (after !in NON_TERMINAL_OUTBOUND_STATES) {
            throw OutboundAttemptTerminatedException(attempt.transferId, after)
        }
        return result
    }

    private fun publishActiveOutboundProgress(
        attempt: OutboundAttempt,
        sentBytes: Long,
        totalBytes: Long,
        status: String,
    ) {
        synchronized(attempt.linearizationLock) {
            if (outboundAttempts[attempt.transferId] !== attempt) return
            if (attempt.state.get() != OutboundAttemptState.ACTIVE) return
            beforeOutboundProgressCommit(status)
            _progress.value = Progress(attempt.transferId, sentBytes, totalBytes, status)
        }
    }

    private fun sendActiveOutbound(
        attempt: OutboundAttempt,
        bytes: ByteArray,
    ) {
        sendOutboundPayload(
            attempt = attempt,
            bytes = bytes,
            allowedStates = setOf(OutboundAttemptState.ACTIVE),
            allowSynchronousAck = false,
        )
    }

    private fun sendArmedOutbound(
        attempt: OutboundAttempt,
        bytes: ByteArray,
    ) {
        sendOutboundPayload(
            attempt = attempt,
            bytes = bytes,
            allowedStates = setOf(OutboundAttemptState.COMPLETION_ARMED),
            allowSynchronousAck = true,
        )
    }

    private fun armAndSendOutboundComplete(
        attempt: OutboundAttempt,
        expectation: OutboundCompletionExpectation,
        bytes: ByteArray,
    ) {
        require(expectation.totalBytes >= 0L) { "outbound expected byte count must be non-negative" }
        require(expectation.fileSha256.size == SHA256_BYTES) {
            "outbound file SHA-256 must be 32 bytes"
        }
        requireActiveOutboundAttempt(attempt)
        check(attempt.completionExpectation.compareAndSet(null, expectation)) {
            "outbound completion expectation already registered"
        }
        check(attempt.state.compareAndSet(
            OutboundAttemptState.ACTIVE,
            OutboundAttemptState.COMPLETION_ARMED,
        )) {
            "outbound attempt terminated before completion could be armed"
        }
        sendArmedOutbound(attempt, bytes)
    }

    private fun sendOutboundChunk(
        attempt: OutboundAttempt,
        index: Int,
        chunkBytes: ByteArray,
        receivedBytes: Long? = null,
    ) {
        val msg = CrossNetworkFileTransferMessage(
            version = 1,
            op = CrossNetworkFileTransferOp.chunk,
            transferId = attempt.transferId,
            chunkIndex = index,
            chunkData = chunkBytes,
            chunkSha256 = sha256(chunkBytes),
            rawSize = chunkBytes.size,
            receivedBytes = receivedBytes,
        )
        sendOutboundPayload(
            attempt = attempt,
            bytes = encode(msg),
            allowedStates = NON_TERMINAL_OUTBOUND_STATES,
            allowSynchronousAck = false,
        )
        markTransferActivity(attempt.transferId, attempt.owner)
        currentSendContext(attempt.transferId, attempt.owner)
            ?.delivery
            ?.recordSendAttempt(index)
    }

    private fun sendOutboundPayload(
        attempt: OutboundAttempt,
        bytes: ByteArray,
        allowedStates: Set<OutboundAttemptState>,
        allowSynchronousAck: Boolean,
    ) {
        val before = requireExactOutboundAttempt(attempt)
        if (before !in allowedStates) {
            throw OutboundAttemptTerminatedException(attempt.transferId, before)
        }
        val accepted = webrtc.send(
            attempt.owner,
            bytes,
            WebRtcAppSecureEnvelope.PacketType.FILE_TRANSFER,
        )
        if (!accepted) {
            val afterRejectedSend = requireExactOutboundAttempt(attempt)
            if (allowSynchronousAck && afterRejectedSend == OutboundAttemptState.ACKED) {
                return
            }
            if (afterRejectedSend !in allowedStates) {
                throw OutboundAttemptTerminatedException(attempt.transferId, afterRejectedSend)
            }
            if (failOutboundTransfer(attempt, "transport rejected send")) {
                error("file transfer send failed: payloadBytes=${bytes.size}")
            }

            // A synchronous callback may win the terminal CAS between the state read above and
            // our FAILED transition. Preserve that winner instead of reporting transport failure.
            val terminalWinner = requireExactOutboundAttempt(attempt)
            if (allowSynchronousAck && terminalWinner == OutboundAttemptState.ACKED) {
                return
            }
            throw OutboundAttemptTerminatedException(attempt.transferId, terminalWinner)
        }
        val after = requireExactOutboundAttempt(attempt)
        if (after in allowedStates || (allowSynchronousAck && after == OutboundAttemptState.ACKED)) {
            return
        }
        throw OutboundAttemptTerminatedException(attempt.transferId, after)
    }

    /** A terminal packet may only be emitted by the CAS winner of that exact attempt. */
    private fun sendTerminalOutbound(
        attempt: OutboundAttempt,
        bytes: ByteArray,
    ) {
        val state = requireExactOutboundAttempt(attempt)
        check(state in TERMINAL_OUTBOUND_STATES) {
            "terminal outbound send requires a terminal attempt"
        }
        check(webrtc.send(
            attempt.owner,
            bytes,
            WebRtcAppSecureEnvelope.PacketType.FILE_TRANSFER,
        )) {
            "terminal file transfer notification was rejected"
        }
        requireExactOutboundAttempt(attempt)
    }

    private fun sendFt(
        owner: WebRtcSecureOperationOwner,
        transferId: String,
        bytes: ByteArray,
    ) {
        requireCurrentOwner(transferId, owner)
        if (!webrtc.send(owner, bytes, WebRtcAppSecureEnvelope.PacketType.FILE_TRANSFER)) {
            requireCurrentOwner(transferId, owner)
            error("file transfer send failed: payloadBytes=${bytes.size}")
        }
        requireCurrentOwner(transferId, owner)
    }

    private companion object {
        const val MAX_PENDING_CHUNK_BYTES = 64L * 1024 * 1024
        const val MAX_IN_MEMORY_RECEIVE_BYTES = 64L * 1024 * 1024
        const val MAX_RESEND_CACHE_BYTES = 128L * 1024 * 1024
        const val MAX_ACTIVE_INBOUND_TRANSFERS = 4
        const val MAX_AGGREGATE_INBOUND_BYTES = 16L * 1024 * 1024 * 1024
        const val SHA256_BYTES = 32
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

        val NON_TERMINAL_OUTBOUND_STATES = setOf(
            OutboundAttemptState.ACTIVE,
            OutboundAttemptState.COMPLETION_ARMED,
        )

        val TERMINAL_OUTBOUND_STATES = setOf(
            OutboundAttemptState.ACKED,
            OutboundAttemptState.FAILED,
            OutboundAttemptState.CANCELLED,
            OutboundAttemptState.TIMED_OUT,
            OutboundAttemptState.STALE,
        )

        /** Single-batch file-count upper bound (Requirement 5.8). */
        const val MAX_BATCH_FILES = 500
    }
}
