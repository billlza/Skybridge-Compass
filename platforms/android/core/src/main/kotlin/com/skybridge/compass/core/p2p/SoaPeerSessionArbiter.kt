package com.skybridge.compass.core.p2p

import java.util.concurrent.atomic.AtomicReference

/**
 * Process-local SOA session arbiter.
 *
 * - Outgoing attempts are registered by pairKey (sorted concat of two peer IDs).
 * - Incoming MessageA may carry authenticated SOA metadata; arbitration runs only after sigA verification.
 * - Winner ordering matches other platforms: (initiatorPeerId, attemptId) ascending wins.
 */
class SoaPeerSessionArbiter(
    private val pendingWindowNs: Long = 10_000_000_000L,
    private val supersedeRateLimit: Int = 3,
    private val supersedeRateWindowNs: Long = 60_000_000_000L,
    private val nowNs: () -> Long = System::nanoTime
) {
    enum class RegisterDecision {
        Accepted,
        AlreadyConnected,
        AlreadyInProgress
    }

    sealed class IncomingDecision {
        data object Accept : IncomingDecision()
        data object RejectAlreadyConnected : IncomingDecision()
        data object RejectBinding : IncomingDecision()
        data object RejectRateLimited : IncomingDecision()
        data class RejectLocalWinner(val winnerPeerId: ByteArray, val winnerAttemptId: ByteArray) : IncomingDecision()
        data class AcceptAndSupersedeLocal(val winnerPeerId: ByteArray, val winnerAttemptId: ByteArray) : IncomingDecision()
    }

    data class OutgoingAttempt(
        val pairKey: ByteArray,
        val initiatorPeerId: ByteArray,
        val attemptId: ByteArray,
        val startedAtNs: Long,
        val onSuperseded: (winnerPeerId: ByteArray, winnerAttemptId: ByteArray) -> Unit
    ) {
        init {
            require(pairKey.size == 64) { "pairKey must be 64 bytes" }
            require(initiatorPeerId.size == 32) { "initiatorPeerId must be 32 bytes" }
            require(attemptId.size == 16) { "attemptId must be 16 bytes" }
        }
    }

    private class BytesKey(private val bytes: ByteArray) {
        private val hash: Int = bytes.contentHashCode()

        override fun equals(other: Any?): Boolean {
            return other is BytesKey && bytes.contentEquals(other.bytes)
        }

        override fun hashCode(): Int = hash
    }

    private data class State(
        val outgoingByPair: LinkedHashMap<BytesKey, OutgoingAttempt> = LinkedHashMap(),
        val establishedPairs: LinkedHashSet<BytesKey> = LinkedHashSet(),
        val supersedeTimestampsByPair: LinkedHashMap<BytesKey, MutableList<Long>> = LinkedHashMap()
    )

    private val stateRef = AtomicReference(State())

    fun registerOutgoing(attempt: OutgoingAttempt): RegisterDecision {
        val key = BytesKey(attempt.pairKey)
        while (true) {
            val snapshot = stateRef.get()
            if (snapshot.establishedPairs.contains(key)) return RegisterDecision.AlreadyConnected

            val existing = snapshot.outgoingByPair[key]
            if (existing != null && nowNs() - existing.startedAtNs <= pendingWindowNs) {
                return RegisterDecision.AlreadyInProgress
            }

            val next = snapshot.copy(
                outgoingByPair = LinkedHashMap(snapshot.outgoingByPair).apply {
                    put(key, attempt)
                }
            )
            if (stateRef.compareAndSet(snapshot, next)) return RegisterDecision.Accepted
        }
    }

    fun clearOutgoing(pairKey: ByteArray, attemptId: ByteArray? = null) {
        val key = BytesKey(pairKey)
        while (true) {
            val snapshot = stateRef.get()
            val existing = snapshot.outgoingByPair[key] ?: return
            if (attemptId != null && !existing.attemptId.contentEquals(attemptId)) return

            val next = snapshot.copy(
                outgoingByPair = LinkedHashMap(snapshot.outgoingByPair).apply { remove(key) }
            )
            if (stateRef.compareAndSet(snapshot, next)) return
        }
    }

    fun markEstablished(pairKey: ByteArray) {
        val key = BytesKey(pairKey)
        while (true) {
            val snapshot = stateRef.get()
            val next = snapshot.copy(
                outgoingByPair = LinkedHashMap(snapshot.outgoingByPair).apply { remove(key) },
                establishedPairs = LinkedHashSet(snapshot.establishedPairs).apply { add(key) }
            )
            if (stateRef.compareAndSet(snapshot, next)) return
        }
    }

    fun clearEstablished(pairKey: ByteArray) {
        val key = BytesKey(pairKey)
        while (true) {
            val snapshot = stateRef.get()
            if (!snapshot.establishedPairs.contains(key)) return
            val next = snapshot.copy(
                establishedPairs = LinkedHashSet(snapshot.establishedPairs).apply { remove(key) }
            )
            if (stateRef.compareAndSet(snapshot, next)) return
        }
    }

    fun evaluateIncoming(
        pairKey: ByteArray,
        remoteInitiatorPeerId: ByteArray,
        remoteAttemptId: ByteArray,
        targetPeerId: ByteArray,
        expectedRemotePeerId: ByteArray,
        localPeerId: ByteArray
    ): IncomingDecision {
        require(pairKey.size == 64) { "pairKey must be 64 bytes" }
        require(remoteInitiatorPeerId.size == 32) { "remoteInitiatorPeerId must be 32 bytes" }
        require(remoteAttemptId.size == 16) { "remoteAttemptId must be 16 bytes" }
        require(targetPeerId.size == 32) { "targetPeerId must be 32 bytes" }
        require(expectedRemotePeerId.size == 32) { "expectedRemotePeerId must be 32 bytes" }
        require(localPeerId.size == 32) { "localPeerId must be 32 bytes" }

        val key = BytesKey(pairKey)
        val supersededCb = AtomicReference<((ByteArray, ByteArray) -> Unit)?>(null)
        val decision: IncomingDecision

        while (true) {
            val snapshot = stateRef.get()
            if (snapshot.establishedPairs.contains(key)) {
                return IncomingDecision.RejectAlreadyConnected
            }
            if (!targetPeerId.contentEquals(localPeerId) || !remoteInitiatorPeerId.contentEquals(expectedRemotePeerId)) {
                return IncomingDecision.RejectBinding
            }

            val localAttempt = snapshot.outgoingByPair[key]
            if (localAttempt == null) {
                return IncomingDecision.Accept
            }

            val now = nowNs()
            if (now - localAttempt.startedAtNs > pendingWindowNs) {
                val next = snapshot.copy(
                    outgoingByPair = LinkedHashMap(snapshot.outgoingByPair).apply { remove(key) }
                )
                if (stateRef.compareAndSet(snapshot, next)) {
                    return IncomingDecision.Accept
                }
                continue
            }

            val recentSupersedes = snapshot.supersedeTimestampsByPair[key]
                .orEmpty()
                .filter { now - it <= supersedeRateWindowNs }
                .toMutableList()
            if (recentSupersedes.size >= supersedeRateLimit) {
                val next = snapshot.copy(
                    supersedeTimestampsByPair = LinkedHashMap(snapshot.supersedeTimestampsByPair).apply {
                        put(key, recentSupersedes)
                    }
                )
                if (stateRef.compareAndSet(snapshot, next)) {
                    return IncomingDecision.RejectRateLimited
                }
                continue
            }

            val remoteWins = isRemoteWinner(
                localInitiatorPeerId = localAttempt.initiatorPeerId,
                localAttemptId = localAttempt.attemptId,
                remoteInitiatorPeerId = remoteInitiatorPeerId,
                remoteAttemptId = remoteAttemptId
            )

            if (remoteWins) {
                recentSupersedes.add(now)
                val nextOutgoing = LinkedHashMap(snapshot.outgoingByPair).apply { remove(key) }
                val nextSupersedes = LinkedHashMap(snapshot.supersedeTimestampsByPair).apply { put(key, recentSupersedes) }
                val next = snapshot.copy(
                    outgoingByPair = nextOutgoing,
                    supersedeTimestampsByPair = nextSupersedes
                )
                if (stateRef.compareAndSet(snapshot, next)) {
                    supersededCb.set(localAttempt.onSuperseded)
                    decision = IncomingDecision.AcceptAndSupersedeLocal(
                        winnerPeerId = remoteInitiatorPeerId,
                        winnerAttemptId = remoteAttemptId
                    )
                    break
                }
            } else {
                decision = IncomingDecision.RejectLocalWinner(
                    winnerPeerId = localAttempt.initiatorPeerId,
                    winnerAttemptId = localAttempt.attemptId
                )
                break
            }
        }

        supersededCb.get()?.invoke(remoteInitiatorPeerId, remoteAttemptId)
        return decision
    }

    private fun isRemoteWinner(
        localInitiatorPeerId: ByteArray,
        localAttemptId: ByteArray,
        remoteInitiatorPeerId: ByteArray,
        remoteAttemptId: ByteArray
    ): Boolean {
        return if (remoteInitiatorPeerId.contentEquals(localInitiatorPeerId)) {
            compareLexUnsigned(remoteAttemptId, localAttemptId) < 0
        } else {
            compareLexUnsigned(remoteInitiatorPeerId, localInitiatorPeerId) < 0
        }
    }

    private fun compareLexUnsigned(a: ByteArray, b: ByteArray): Int {
        val n = minOf(a.size, b.size)
        for (i in 0 until n) {
            val ai = a[i].toInt() and 0xFF
            val bi = b[i].toInt() and 0xFF
            if (ai != bi) return ai - bi
        }
        return a.size - b.size
    }

    companion object {
        val shared: SoaPeerSessionArbiter by lazy { SoaPeerSessionArbiter() }
    }
}

