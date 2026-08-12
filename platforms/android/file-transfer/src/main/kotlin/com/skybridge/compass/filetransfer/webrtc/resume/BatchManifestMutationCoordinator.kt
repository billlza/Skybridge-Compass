package com.skybridge.compass.filetransfer.webrtc.resume

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import java.io.File
import java.util.concurrent.ConcurrentHashMap

internal data class BatchManifestGenerationToken(
    val batchId: String,
    val generation: Long,
)

internal enum class BatchManifestMutationAdmission {
    REMOTE,
    DELETE_ENTRY,
    DELETE_BATCH,
}

/**
 * Application-scoped, per-batch ordering and invalidation for manifest mutations.
 *
 * No owner or key material is persisted here. A lane only retains a session-local generation,
 * local deletion tombstones, and the accepted mutation tail. Android stores that share the same
 * files directory share this coordinator, so separate ViewModel/controller instances cannot race
 * each other through the same manifest file.
 */
internal class BatchManifestMutationCoordinator(
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
    private val maxLanes: Int = DEFAULT_MAX_LANES,
) {
    private class Lane {
        var generation: Long = 1L
        var batchTombstoned: Boolean = false
        var batchDeletionComplete: Boolean = false
        var outboundInitialized: Boolean = false
        var outboundOpenedDeletedBatch: Boolean = false
        val outboundTransferIds: MutableSet<String> = HashSet()
        val activeTransferIds: MutableSet<String> = HashSet()
        val entryTombstones: MutableSet<String> = HashSet()
        var transferTombstonesSaturated: Boolean = false
        var tail: Deferred<Unit>? = null
    }

    private val lanes = ConcurrentHashMap<String, Lane>()
    private val laneAdmissionLock = Any()

    init {
        require(maxLanes > 0) { "batch manifest lane capacity must be positive" }
    }

    private fun lane(batchId: String): Lane = lanes[batchId] ?: synchronized(laneAdmissionLock) {
        lanes[batchId] ?: run {
            check(lanes.size < maxLanes) {
                "batch manifest lane capacity exhausted; refusing to evict live tombstones"
            }
            Lane().also { lanes[batchId] = it }
        }
    }

    fun beginOutboundBatch(
        batchId: String,
        transferIds: Collection<String>,
    ): BatchManifestGenerationToken {
        require(transferIds.isNotEmpty()) { "outbound batch must contain a transfer" }
        require(transferIds.size == transferIds.toSet().size) {
            "outbound batch transfer ids must be unique"
        }
        val lane = lane(batchId)
        return synchronized(lane) {
            check(!lane.outboundInitialized) { "batch manifest already active for $batchId" }
            val reopeningDeletedBatch = lane.batchTombstoned
            if (reopeningDeletedBatch) {
                check(lane.batchDeletionComplete) {
                    "batch manifest deletion is still in progress for $batchId"
                }
                check(!lane.transferTombstonesSaturated) {
                    "batch manifest cannot be reused after transfer tombstone capacity exhaustion"
                }
            }
            check(transferIds.none { it in lane.entryTombstones || it in lane.activeTransferIds }) {
                "outbound batch contains a previously used transfer id"
            }
            check(lane.activeTransferIds.size + lane.entryTombstones.size + transferIds.size <= MAX_TRACKED_TRANSFERS) {
                "batch manifest transfer capacity exhausted for $batchId"
            }
            if (reopeningDeletedBatch) {
                // Reuse is opened only by this explicit fresh outbound admission. Until now, late
                // inbound metadata remains rejected and its transfer id is remembered below.
                lane.generation += 1L
                lane.batchTombstoned = false
                lane.batchDeletionComplete = false
            }
            lane.outboundInitialized = true
            lane.outboundOpenedDeletedBatch = reopeningDeletedBatch
            lane.outboundTransferIds += transferIds
            lane.activeTransferIds += transferIds
            BatchManifestGenerationToken(batchId, lane.generation)
        }
    }

    fun releaseFailedOutboundInitialization(token: BatchManifestGenerationToken) {
        val lane = lane(token.batchId)
        synchronized(lane) {
            if (lane.generation == token.generation && !lane.batchTombstoned) {
                lane.outboundInitialized = false
                lane.activeTransferIds.removeAll(lane.outboundTransferIds)
                lane.outboundTransferIds.clear()
                if (lane.outboundOpenedDeletedBatch) {
                    lane.generation += 1L
                    lane.batchTombstoned = true
                    lane.batchDeletionComplete = true
                }
                lane.outboundOpenedDeletedBatch = false
            }
        }
    }

    fun completeOutboundInitialization(token: BatchManifestGenerationToken) {
        val lane = lane(token.batchId)
        synchronized(lane) {
            if (lane.generation == token.generation && !lane.batchTombstoned) {
                lane.outboundOpenedDeletedBatch = false
            }
        }
    }

    fun joinRemoteBatch(batchId: String, transferId: String): BatchManifestGenerationToken? {
        val lane = lane(batchId)
        return synchronized(lane) {
            if (lane.batchTombstoned) {
                rememberTransferTombstone(lane, transferId)
                null
            } else if (transferId in lane.entryTombstones) {
                null
            } else if (
                transferId !in lane.activeTransferIds &&
                lane.activeTransferIds.size + lane.entryTombstones.size >= MAX_TRACKED_TRANSFERS
            ) {
                null
            } else {
                lane.activeTransferIds += transferId
                BatchManifestGenerationToken(batchId, lane.generation)
            }
        }
    }

    fun tombstoneBatch(batchId: String): BatchManifestGenerationToken {
        val lane = lane(batchId)
        return synchronized(lane) {
            lane.generation += 1L
            lane.batchTombstoned = true
            lane.batchDeletionComplete = false
            lane.outboundInitialized = false
            lane.outboundOpenedDeletedBatch = false
            lane.outboundTransferIds.clear()
            lane.activeTransferIds.toList().forEach { rememberTransferTombstone(lane, it) }
            lane.activeTransferIds.clear()
            BatchManifestGenerationToken(batchId, lane.generation)
        }
    }

    /**
     * Mark the physical deletion complete. The batch remains tombstoned until an explicit outbound
     * admission opens a fresh generation, so late metadata arriving in that gap is still rejected
     * and remembered. A failed delete never reaches this method and therefore stays fail-closed.
     */
    fun completeBatchDeletion(token: BatchManifestGenerationToken): Boolean {
        val lane = lane(token.batchId)
        return synchronized(lane) {
            if (
                lane.generation != token.generation ||
                !lane.batchTombstoned
            ) {
                false
            } else {
                lane.batchDeletionComplete = true
                true
            }
        }
    }

    fun tombstoneEntry(batchId: String, transferId: String): BatchManifestGenerationToken? {
        val lane = lane(batchId)
        return synchronized(lane) {
            if (lane.batchTombstoned) {
                rememberTransferTombstone(lane, transferId)
                null
            } else {
                lane.activeTransferIds.remove(transferId)
                check(rememberTransferTombstone(lane, transferId)) {
                    "batch manifest transfer tombstone capacity exhausted for $batchId"
                }
                BatchManifestGenerationToken(batchId, lane.generation)
            }
        }
    }

    fun isRemoteMutationCurrent(
        token: BatchManifestGenerationToken,
        transferId: String,
    ): Boolean {
        val lane = lane(token.batchId)
        return synchronized(lane) {
            lane.generation == token.generation &&
                !lane.batchTombstoned &&
                transferId !in lane.entryTombstones &&
                transferId in lane.activeTransferIds
        }
    }

    fun runRemoteCommitIfCurrent(
        token: BatchManifestGenerationToken,
        transferId: String,
        commit: () -> Unit,
    ): Boolean {
        val lane = lane(token.batchId)
        return synchronized(lane) {
            if (
                lane.generation != token.generation ||
                lane.batchTombstoned ||
                transferId in lane.entryTombstones ||
                transferId !in lane.activeTransferIds
            ) {
                false
            } else {
                commit()
                true
            }
        }
    }

    fun enqueue(
        token: BatchManifestGenerationToken,
        transferId: String?,
        admission: BatchManifestMutationAdmission,
        operation: suspend () -> Unit,
    ): Deferred<Unit>? {
        val lane = lane(token.batchId)
        val worker = synchronized(lane) {
            if (!admissionAllowed(lane, token, transferId, admission)) return null
            val predecessor = lane.tail
            scope.async(start = CoroutineStart.LAZY) {
                predecessor?.join()
                if (!executionAllowed(lane, token, transferId, admission)) return@async
                operation()
            }.also { lane.tail = it }
        }
        worker.invokeOnCompletion {
            synchronized(lane) {
                if (lane.tail === worker) lane.tail = null
            }
        }
        worker.start()
        return worker
    }

    private fun admissionAllowed(
        lane: Lane,
        token: BatchManifestGenerationToken,
        transferId: String?,
        admission: BatchManifestMutationAdmission,
    ): Boolean {
        if (lane.generation != token.generation) return false
        return when (admission) {
            BatchManifestMutationAdmission.REMOTE -> remoteTransferAllowed(lane, transferId)
            BatchManifestMutationAdmission.DELETE_ENTRY ->
                !lane.batchTombstoned && transferId != null && transferId in lane.entryTombstones
            BatchManifestMutationAdmission.DELETE_BATCH -> lane.batchTombstoned
        }
    }

    private fun executionAllowed(
        lane: Lane,
        token: BatchManifestGenerationToken,
        transferId: String?,
        admission: BatchManifestMutationAdmission,
    ): Boolean = synchronized(lane) {
        lane.generation == token.generation && when (admission) {
            BatchManifestMutationAdmission.REMOTE -> remoteTransferAllowed(lane, transferId)
            BatchManifestMutationAdmission.DELETE_ENTRY -> !lane.batchTombstoned
            BatchManifestMutationAdmission.DELETE_BATCH -> lane.batchTombstoned
        }
    }

    private fun remoteTransferAllowed(lane: Lane, transferId: String?): Boolean =
        !lane.batchTombstoned &&
            (transferId == null ||
                (transferId !in lane.entryTombstones && transferId in lane.activeTransferIds))

    private fun rememberTransferTombstone(lane: Lane, transferId: String): Boolean {
        if (transferId in lane.entryTombstones) return true
        if (lane.entryTombstones.size >= MAX_TRACKED_TRANSFERS) {
            lane.transferTombstonesSaturated = true
            return false
        }
        lane.entryTombstones += transferId
        return true
    }

    private companion object {
        const val DEFAULT_MAX_LANES = 4_096
        const val MAX_TRACKED_TRANSFERS = 4_096
    }
}

internal object AndroidBatchManifestMutationCoordinatorRegistry {
    private val coordinators = ConcurrentHashMap<String, BatchManifestMutationCoordinator>()
    private val admissionLock = Any()

    fun forDirectory(directory: File): BatchManifestMutationCoordinator =
        forNamespace(directory.absoluteFile.normalize().path)

    fun forNamespace(namespace: String): BatchManifestMutationCoordinator {
        require(namespace.isNotBlank()) { "batch manifest coordination namespace must not be blank" }
        return coordinators[namespace] ?: synchronized(admissionLock) {
            coordinators[namespace] ?: run {
                check(coordinators.size < MAX_NAMESPACES) {
                    "batch manifest coordinator namespace capacity exhausted"
                }
                BatchManifestMutationCoordinator().also { coordinators[namespace] = it }
            }
        }
    }

    private const val MAX_NAMESPACES = 64
}
