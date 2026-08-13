package com.skybridge.compass.filetransfer.webrtc

import com.skybridge.compass.core.webrtc.WebRtcSecureOperationOwner
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferMessage
import com.skybridge.compass.shared.p2p.filetransfer.CrossNetworkFileTransferOp

/**
 * Immutable completion request identity. Byte arrays are copied on input and output so a decoded
 * wire message cannot mutate a replay decision after admission.
 */
internal class InboundCompletionFingerprint(
    val version: Int,
    val transferId: String,
    val receivedBytes: Long,
    fileSha256: ByteArray,
    merkleRoot: ByteArray?,
    merkleRootSignature: ByteArray?,
    val merkleRootSignatureAlgorithm: String?,
) {
    private val fileSha256Bytes = fileSha256.copyOf()
    private val merkleRootBytes = merkleRoot?.copyOf()
    private val merkleRootSignatureBytes = merkleRootSignature?.copyOf()

    fun fileSha256(): ByteArray = fileSha256Bytes.copyOf()
    fun merkleRoot(): ByteArray? = merkleRootBytes?.copyOf()
    fun merkleRootSignature(): ByteArray? = merkleRootSignatureBytes?.copyOf()

    override fun equals(other: Any?): Boolean =
        other is InboundCompletionFingerprint &&
            version == other.version &&
            transferId == other.transferId &&
            receivedBytes == other.receivedBytes &&
            fileSha256Bytes.contentEquals(other.fileSha256Bytes) &&
            nullableBytesEqual(merkleRootBytes, other.merkleRootBytes) &&
            nullableBytesEqual(merkleRootSignatureBytes, other.merkleRootSignatureBytes) &&
            merkleRootSignatureAlgorithm == other.merkleRootSignatureAlgorithm

    override fun hashCode(): Int {
        var result = version
        result = 31 * result + transferId.hashCode()
        result = 31 * result + receivedBytes.hashCode()
        result = 31 * result + fileSha256Bytes.contentHashCode()
        result = 31 * result + (merkleRootBytes?.contentHashCode() ?: 0)
        result = 31 * result + (merkleRootSignatureBytes?.contentHashCode() ?: 0)
        result = 31 * result + (merkleRootSignatureAlgorithm?.hashCode() ?: 0)
        return result
    }

    private fun nullableBytesEqual(left: ByteArray?, right: ByteArray?): Boolean = when {
        left == null -> right == null
        right == null -> false
        else -> left.contentEquals(right)
    }
}

/**
 * Bounded, process-local completion witness for one exact WebRTC secure-operation owner.
 *
 * This is Level 1 reliability state, not crash-durable security state. Completed ACK payloads are
 * retained for a short replay window and then reduced to fixed-size tombstones. Tombstones are not
 * evicted within an owner epoch: transfer identifiers remain single-use until the exact owner is
 * replaced. Active, completed, and tombstone entries share one fixed capacity budget.
 */
internal class InboundCompletionReplayLedger(
    private val capacity: Int = DEFAULT_CAPACITY,
    private val completedPayloadTtlMs: Long = DEFAULT_COMPLETED_PAYLOAD_TTL_MS,
    private val clockMs: () -> Long = { System.currentTimeMillis() },
) {
    enum class Reservation {
        RESERVED,
        ALREADY_ACTIVE,
        ALREADY_USED,
        CAPACITY_EXCEEDED,
    }

    enum class PreparedAbortResult {
        ABORTED,
        OWNER_ROTATED,
        INVALID_TOKEN,
    }

    sealed interface CompletionLookup {
        data object Active : CompletionLookup
        data class Replay(val acknowledgement: CrossNetworkFileTransferMessage) : CompletionLookup
        data object Conflict : CompletionLookup
        data object Tombstone : CompletionLookup
        data object Missing : CompletionLookup
    }

    internal class PreparedCompletion internal constructor(
        internal val owner: WebRtcSecureOperationOwner,
        internal val transferId: String,
        internal val generation: Long,
        internal val fingerprint: InboundCompletionFingerprint,
        acknowledgement: CrossNetworkFileTransferMessage,
    ) {
        internal val acknowledgement = acknowledgement.deepCopy()
    }

    private class OwnerTransferKey(
        val owner: WebRtcSecureOperationOwner,
        val transferId: String,
    ) {
        override fun equals(other: Any?): Boolean =
            other is OwnerTransferKey && owner === other.owner && transferId == other.transferId

        override fun hashCode(): Int =
            31 * System.identityHashCode(owner) + transferId.hashCode()
    }

    private sealed interface Entry {
        data class Active(
            val generation: Long,
            val fingerprint: InboundCompletionFingerprint?,
            val prepared: Boolean = false,
        ) : Entry

        data class Completed(
            val fingerprint: InboundCompletionFingerprint,
            val acknowledgement: CrossNetworkFileTransferMessage,
            val completedAtMs: Long,
        ) : Entry

        data object Tombstone : Entry
    }

    private val lock = Any()
    private val entries = HashMap<OwnerTransferKey, Entry>()
    private var currentOwner: WebRtcSecureOperationOwner? = null
    private var nextGeneration = 0L

    init {
        require(capacity > 0) { "completion replay capacity must be positive" }
        require(completedPayloadTtlMs > 0L) { "completion replay TTL must be positive" }
    }

    val size: Int get() = synchronized(lock) { entries.size }

    /** Must be called only inside the transport's exact-current-owner commit gate. */
    fun rotateTo(owner: WebRtcSecureOperationOwner) = synchronized(lock) {
        if (currentOwner === owner) return@synchronized
        entries.clear()
        currentOwner = owner
    }

    fun reserve(
        owner: WebRtcSecureOperationOwner,
        transferId: String,
    ): Reservation = synchronized(lock) {
        requireCurrentOwner(owner)
        pruneCompletedPayloads(clockMs())
        val key = OwnerTransferKey(owner, transferId)
        when (entries[key]) {
            is Entry.Active -> Reservation.ALREADY_ACTIVE
            is Entry.Completed, Entry.Tombstone -> Reservation.ALREADY_USED
            null -> {
                if (entries.size >= capacity) {
                    Reservation.CAPACITY_EXCEEDED
                } else {
                    entries[key] = Entry.Active(++nextGeneration, fingerprint = null)
                    Reservation.RESERVED
                }
            }
        }
    }

    /**
     * Atomically binds the first complete request, or classifies a duplicate against existing state.
     * A conflict is reported but not tombstoned here: a finalizer may already own durable commit.
     */
    fun bindOrLookup(
        owner: WebRtcSecureOperationOwner,
        fingerprint: InboundCompletionFingerprint,
    ): CompletionLookup = synchronized(lock) {
        requireCurrentOwner(owner)
        pruneCompletedPayloads(clockMs())
        val key = OwnerTransferKey(owner, fingerprint.transferId)
        when (val entry = entries[key]) {
            null -> CompletionLookup.Missing
            Entry.Tombstone -> CompletionLookup.Tombstone
            is Entry.Completed -> if (entry.fingerprint == fingerprint) {
                CompletionLookup.Replay(entry.acknowledgement.deepCopy())
            } else {
                CompletionLookup.Conflict
            }
            is Entry.Active -> when (val bound = entry.fingerprint) {
                null -> {
                    entries[key] = entry.copy(fingerprint = fingerprint)
                    CompletionLookup.Active
                }
                else -> if (bound == fingerprint) {
                    CompletionLookup.Active
                } else {
                    CompletionLookup.Conflict
                }
            }
        }
    }

    fun prepareCompletion(
        owner: WebRtcSecureOperationOwner,
        fingerprint: InboundCompletionFingerprint,
        acknowledgement: CrossNetworkFileTransferMessage,
    ): PreparedCompletion = synchronized(lock) {
        requireCurrentOwner(owner)
        val key = OwnerTransferKey(owner, fingerprint.transferId)
        val active = entries[key] as? Entry.Active
            ?: error("completion preparation requires an active reservation")
        check(active.fingerprint == fingerprint) {
            "completion preparation fingerprint does not match the active request"
        }
        check(!active.prepared) { "completion request is already prepared" }
        validateAcknowledgement(fingerprint, acknowledgement)
        val prepared = PreparedCompletion(
            owner = owner,
            transferId = fingerprint.transferId,
            generation = active.generation,
            fingerprint = fingerprint,
            acknowledgement = acknowledgement,
        )
        entries[key] = active.copy(prepared = true)
        prepared
    }

    /** Records the witness synchronously after durable commit and before any ACK is attempted. */
    fun commitPrepared(prepared: PreparedCompletion): Boolean = synchronized(lock) {
        if (currentOwner !== prepared.owner) return@synchronized false
        val key = OwnerTransferKey(prepared.owner, prepared.transferId)
        val active = entries[key] as? Entry.Active ?: return@synchronized false
        if (
            !active.prepared ||
            active.generation != prepared.generation ||
            active.fingerprint != prepared.fingerprint
        ) {
            return@synchronized false
        }
        entries[key] = Entry.Completed(
            fingerprint = prepared.fingerprint,
            acknowledgement = prepared.acknowledgement.deepCopy(),
            completedAtMs = clockMs(),
        )
        true
    }

    fun tombstoneActive(
        owner: WebRtcSecureOperationOwner,
        transferId: String,
    ) = synchronized(lock) {
        if (currentOwner !== owner) return@synchronized
        val key = OwnerTransferKey(owner, transferId)
        val active = entries[key] as? Entry.Active ?: return@synchronized
        if (!active.prepared) entries[key] = Entry.Tombstone
    }

    /** Only the exact finalizer token may abandon a prepared destination transaction. */
    fun abortPrepared(prepared: PreparedCompletion): PreparedAbortResult = synchronized(lock) {
        if (currentOwner !== prepared.owner) return@synchronized PreparedAbortResult.OWNER_ROTATED
        val key = OwnerTransferKey(prepared.owner, prepared.transferId)
        val active = entries[key] as? Entry.Active
            ?: return@synchronized PreparedAbortResult.INVALID_TOKEN
        if (
            !active.prepared ||
            active.generation != prepared.generation ||
            active.fingerprint != prepared.fingerprint
        ) {
            return@synchronized PreparedAbortResult.INVALID_TOKEN
        }
        entries[key] = Entry.Tombstone
        PreparedAbortResult.ABORTED
    }

    private fun requireCurrentOwner(owner: WebRtcSecureOperationOwner) {
        check(currentOwner === owner) { "completion replay ledger owner is not current" }
    }

    private fun pruneCompletedPayloads(nowMs: Long) {
        entries.replaceAll { _, entry ->
            if (entry is Entry.Completed && nowMs - entry.completedAtMs >= completedPayloadTtlMs) {
                Entry.Tombstone
            } else {
                entry
            }
        }
    }

    private fun validateAcknowledgement(
        fingerprint: InboundCompletionFingerprint,
        acknowledgement: CrossNetworkFileTransferMessage,
    ) {
        check(acknowledgement.version == fingerprint.version)
        check(acknowledgement.op == CrossNetworkFileTransferOp.completeAck)
        check(acknowledgement.transferId == fingerprint.transferId)
        check(acknowledgement.receivedBytes == fingerprint.receivedBytes)
        check(acknowledgement.fileSha256?.contentEquals(fingerprint.fileSha256()) == true)
    }

    private companion object {
        const val DEFAULT_CAPACITY = 1_024
        const val DEFAULT_COMPLETED_PAYLOAD_TTL_MS = 5L * 60L * 1_000L
    }
}

private fun CrossNetworkFileTransferMessage.deepCopy(): CrossNetworkFileTransferMessage = copy(
    chunkData = chunkData?.copyOf(),
    nonce = nonce?.copyOf(),
    chunkSha256 = chunkSha256?.copyOf(),
    fileSha256 = fileSha256?.copyOf(),
    merkleRoot = merkleRoot?.copyOf(),
    merkleRootSignature = merkleRootSignature?.copyOf(),
    missingChunks = missingChunks?.copyOf(),
)
