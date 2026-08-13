package com.skybridge.compass.core.p2p

import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

internal class TcpControlServerOwner<L : Any, C : Any, S : Any>(
    private val maxClientOwners: Int = 64,
    private val onCapacityWait: () -> Unit = {}
) {
    private val lock = ReentrantLock()
    private val acceptsDrained = lock.newCondition()
    private val capacityAvailable = lock.newCondition()
    private var nextGeneration = 0L
    private var nextAcceptId = 0L
    private var listener: ListenerOwner<L>? = null
    private val acceptsInFlight = LinkedHashSet<AcceptOwner>()
    private val accepted = LinkedHashSet<ClientOwner<C>>()
    private val sessions = LinkedHashSet<SessionOwner<S>>()
    private var pendingCleanup: RetiredOwner<L, C, S>? = null

    init {
        require(maxClientOwners > 0) { "TCP client owner capacity must be positive" }
    }

    fun installListener(resource: L): ListenerOwner<L> = lock.withLock {
        check(pendingCleanup == null) {
            "TCP control server cleanup is incomplete; stop must be retried before start"
        }
        check(listener == null) { "TCP control server already has an active listener" }
        ListenerOwner(generation = ++nextGeneration, resource = resource).also { listener = it }
    }

    fun currentListener(): ListenerOwner<L>? = lock.withLock { listener }

    fun requireCleanupComplete() = lock.withLock {
        check(pendingCleanup == null) {
            "TCP control server cleanup is incomplete; stop must be retried before start"
        }
    }

    fun isCurrent(owner: ListenerOwner<L>): Boolean = lock.withLock { listener === owner }

    fun beginAcceptWhenAvailable(owner: ListenerOwner<L>): AcceptOwner? = lock.withLock {
        while (listener === owner && clientOwnerCountLocked() >= maxClientOwners) {
            onCapacityWait()
            capacityAvailable.awaitUninterruptibly()
        }
        if (listener !== owner) return null
        AcceptOwner(generation = owner.generation, id = ++nextAcceptId).also(acceptsInFlight::add)
    }

    fun completeAcceptSuccess(owner: AcceptOwner, resource: C): ClientOwner<C>? = lock.withLock {
        check(acceptsInFlight.remove(owner)) { "TCP accept reservation is not active" }
        val acceptedOwner = ClientOwner(generation = owner.generation, resource = resource)
        if (listener?.generation == owner.generation) {
            accepted.add(acceptedOwner)
        } else {
            val current = RetiredOwner<L, C, S>(
                transitionGeneration = nextGeneration,
                listeners = emptyList(),
                accepted = listOf(acceptedOwner),
                sessions = emptyList()
            )
            pendingCleanup = mergePendingCleanupLocked(current)
        }
        acceptsDrained.signalAll()
        acceptedOwner.takeIf { listener?.generation == owner.generation }
    }

    fun completeAcceptFailure(owner: AcceptOwner): Boolean = lock.withLock {
        check(acceptsInFlight.remove(owner)) { "TCP accept reservation is not active" }
        val listenerStillCurrent = listener?.generation == owner.generation
        acceptsDrained.signalAll()
        capacityAvailable.signalAll()
        listenerStillCurrent
    }

    fun awaitAcceptsDrained(timeoutMillis: Long): Boolean = lock.withLock {
        require(timeoutMillis > 0) { "TCP accept drain timeout must be positive" }
        var remaining = TimeUnit.MILLISECONDS.toNanos(timeoutMillis)
        while (acceptsInFlight.isNotEmpty() && remaining > 0L) {
            remaining = acceptsDrained.awaitNanos(remaining)
        }
        acceptsInFlight.isEmpty()
    }

    fun beginAcceptedCleanup(owner: ClientOwner<C>): RetiredOwner<L, C, S>? = lock.withLock {
        if (!accepted.remove(owner)) return null
        val current = RetiredOwner<L, C, S>(
            transitionGeneration = nextGeneration,
            listeners = emptyList(),
            accepted = listOf(owner),
            sessions = emptyList()
        )
        mergePendingCleanupLocked(current).also { pendingCleanup = it }
    }

    fun promoteAcceptedToSession(
        listenerOwner: ListenerOwner<L>,
        clientOwner: ClientOwner<C>,
        resource: S
    ): SessionOwner<S>? = lock.withLock {
        if (listener !== listenerOwner || !accepted.remove(clientOwner)) return null
        SessionOwner(generation = listenerOwner.generation, resource = resource).also(sessions::add)
    }

    fun retireSession(owner: SessionOwner<S>): Boolean = lock.withLock {
        sessions.remove(owner).also { removed ->
            if (removed) capacityAvailable.signalAll()
        }
    }

    fun beginStopCleanup(): RetiredOwner<L, C, S> = lock.withLock {
        val current = retireAllLocked()
        mergePendingCleanupLocked(current).also { pendingCleanup = it }
    }

    fun beginListenerFailureCleanup(
        owner: ListenerOwner<L>
    ): RetiredOwner<L, C, S>? = lock.withLock {
        if (listener !== owner) return null
        val current = retireAllLocked()
        mergePendingCleanupLocked(current).also { pendingCleanup = it }
    }

    fun completeCleanup(owner: RetiredOwner<L, C, S>): Boolean = lock.withLock {
        if (pendingCleanup !== owner) return false
        pendingCleanup = null
        capacityAvailable.signalAll()
        true
    }

    val hasPendingCleanup: Boolean
        get() = lock.withLock { pendingCleanup != null }

    private fun mergeForRetry(
        first: RetiredOwner<L, C, S>,
        second: RetiredOwner<L, C, S>
    ): RetiredOwner<L, C, S> = RetiredOwner(
        transitionGeneration = second.transitionGeneration,
        listeners = distinctIdentity(first.listeners + second.listeners),
        accepted = distinctIdentity(first.accepted + second.accepted),
        sessions = distinctIdentity(first.sessions + second.sessions)
    )

    fun isCurrentTransition(retired: RetiredOwner<L, C, S>): Boolean = lock.withLock {
        listener == null && nextGeneration == retired.transitionGeneration
    }

    private fun retireAllLocked(): RetiredOwner<L, C, S> {
        nextGeneration += 1
        val retired = RetiredOwner(
            transitionGeneration = nextGeneration,
            listeners = listOfNotNull(listener),
            accepted = accepted.toList(),
            sessions = sessions.toList()
        )
        listener = null
        accepted.clear()
        sessions.clear()
        capacityAvailable.signalAll()
        return retired
    }

    private fun mergePendingCleanupLocked(
        current: RetiredOwner<L, C, S>
    ): RetiredOwner<L, C, S> = pendingCleanup?.let { mergeForRetry(it, current) } ?: current

    private fun clientOwnerCountLocked(): Int =
        acceptsInFlight.size +
            accepted.size +
            sessions.size +
            (pendingCleanup?.accepted?.size ?: 0) +
            (pendingCleanup?.sessions?.size ?: 0)

    val acceptedCount: Int get() = lock.withLock { accepted.size }
    val sessionCount: Int get() = lock.withLock { sessions.size }

    class AcceptOwner internal constructor(
        val generation: Long,
        internal val id: Long
    )

    class ListenerOwner<T : Any> internal constructor(
        val generation: Long,
        val resource: T
    )

    class ClientOwner<T : Any> internal constructor(
        val generation: Long,
        val resource: T
    )

    class SessionOwner<T : Any> internal constructor(
        val generation: Long,
        val resource: T
    )

    data class RetiredOwner<L : Any, C : Any, S : Any>(
        val transitionGeneration: Long,
        val listeners: List<ListenerOwner<L>>,
        val accepted: List<ClientOwner<C>>,
        val sessions: List<SessionOwner<S>>
    )

    private fun <T : Any> distinctIdentity(values: List<T>): List<T> =
        values.fold(mutableListOf()) { result, value ->
            if (result.none { it === value }) result.add(value)
            result
        }
}
