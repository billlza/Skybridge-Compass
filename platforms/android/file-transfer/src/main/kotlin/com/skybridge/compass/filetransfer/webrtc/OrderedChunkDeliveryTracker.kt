package com.skybridge.compass.filetransfer.webrtc

/**
 * Pure, Android-independent bookkeeping for ordered chunk send and per-chunk delivery
 * confirmation on the SENDER side of a CrossNetwork (WebRTC DataChannel) file transfer.
 *
 * This isolates the ordering / ack / delivery-decision logic from the I/O-heavy controller so the
 * following invariants are explicit and unit-testable without a live transport (Requirements 5.1,
 * 5.10):
 *
 *  - **Ordered send.** [sendOrder] enumerates chunk indices strictly ascending (0, 1, ..., n-1);
 *    the controller emits chunks in exactly this order and the receiver reassembles by index.
 *  - **A chunk is "delivered" only after its ack arrives.** A chunk is considered delivered iff
 *    its corresponding `chunkAck` has been observed via [markDelivered]; until then
 *    [isChunkDelivered] is false. A peer NACK (`missingChunks`) flips a chunk back to un-delivered
 *    via [markUndelivered].
 *  - **Only un-acked chunks are retransmitted, bounded by attempts.** [resendCandidates] returns
 *    exactly the still-un-acked chunk indices (ascending) whose send-attempt count is below the
 *    supplied ceiling; already-acked chunks are never resent.
 *  - **Overall "all delivered" predicate.** [isAllDelivered] is true iff every chunk is acked. This
 *    is the sender-side necessary condition for delivery; the transfer is only *declared* delivered
 *    when the receiver's `completeAck` arrives, which the receiver emits solely after its integrity
 *    checks (size + file SHA-256 + Merkle root, and optional signature) pass. Thus overall delivery
 *    requires BOTH all chunks acked AND receiver-side integrity verification.
 *
 * The tracker holds no bytes and performs no I/O; it only tracks per-chunk ack state and attempt
 * counts. All index arguments are bounds-checked and out-of-range indices are ignored (no throw),
 * matching the controller's tolerance for spurious/duplicate acks from the peer.
 */
internal class OrderedChunkDeliveryTracker(val totalChunks: Int) {

    init {
        require(totalChunks >= 0) { "totalChunks must be non-negative, was $totalChunks" }
    }

    private val acked: BooleanArray = BooleanArray(totalChunks)
    private val attempts: IntArray = IntArray(totalChunks)

    /** Ascending chunk indices in the exact order chunks must be sent (Requirement 5.1). */
    fun sendOrder(): IntRange = 0 until totalChunks

    private fun inRange(index: Int): Boolean = index in 0 until totalChunks

    /** True iff chunk [index]'s ack has been received. Out-of-range indices are not delivered. */
    fun isChunkDelivered(index: Int): Boolean = inRange(index) && acked[index]

    /**
     * Mark chunk [index] as delivered because its `chunkAck` arrived. No-op for out-of-range
     * indices. Returns true iff the index was in range.
     */
    fun markDelivered(index: Int): Boolean {
        if (!inRange(index)) return false
        acked[index] = true
        return true
    }

    /**
     * Mark chunk [index] as NOT delivered because the peer reported it missing (NACK). No-op for
     * out-of-range indices. Returns true iff the index was in range.
     */
    fun markUndelivered(index: Int): Boolean {
        if (!inRange(index)) return false
        acked[index] = false
        return true
    }

    /** Record that chunk [index] was (re)transmitted, incrementing its attempt count. */
    fun recordSendAttempt(index: Int) {
        if (inRange(index)) attempts[index] += 1
    }

    /** Number of times chunk [index] has been transmitted. */
    fun attemptsFor(index: Int): Int = if (inRange(index)) attempts[index] else 0

    /**
     * Sender-side necessary condition for overall delivery: every chunk has been acked. Note this
     * is NOT sufficient on its own — the transfer is declared delivered only when the receiver's
     * integrity-gated `completeAck` is received (Requirement 5.10).
     */
    fun isAllDelivered(): Boolean = acked.all { it }

    /** Count of chunks whose ack has been received. */
    fun deliveredCount(): Int = acked.count { it }

    /** Ascending indices of chunks still awaiting an ack. */
    fun unackedChunks(): List<Int> = sendOrder().filter { !acked[it] }

    /**
     * Ascending indices of chunks that should be retransmitted right now: still un-acked AND
     * having been attempted fewer than [maxAttempts] times. Already-acked chunks are excluded so a
     * confirmed chunk is never resent (Requirement 5.10).
     */
    fun resendCandidates(maxAttempts: Int): List<Int> =
        sendOrder().filter { !acked[it] && attempts[it] < maxAttempts }
}
