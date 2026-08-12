package com.skybridge.compass.android.remote.mac

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import java.util.ArrayDeque

/** One generation-bound, already encoded remote-input message. */
internal class MacRemoteQueuedInput private constructor(
    val generation: Long,
    encodedMessage: ByteArray
) {
    private val encodedMessageSnapshot = encodedMessage.copyOf()

    fun encodedMessage(): ByteArray = encodedMessageSnapshot.copyOf()

    companion object {
        fun from(generation: Long, message: RemoteMessage): MacRemoteQueuedInput {
            require(generation > 0L) { "remote input generation must be positive" }
            return MacRemoteQueuedInput(
                generation = generation,
                encodedMessage = RemoteControlWireCodec.encodeMessage(message)
            )
        }
    }
}

/** Linearizes a successful transport flush with the lifecycle-owned pressed-input transition. */
internal fun runIfCurrentMacRemoteInputCommit(
    lifecycleLock: Any,
    isCurrent: () -> Boolean,
    commitPressedState: () -> Unit
): Boolean = synchronized(lifecycleLock) {
    if (!isCurrent()) return@synchronized false
    commitPressedState()
    true
}

/**
 * Bounded single-consumer FIFO for LAN remote input. Each caller enqueues synchronously; only the
 * consumer may perform a transport write, so Down/Move/Up ordering cannot depend on coroutine
 * dispatcher scheduling.
 */
internal class MacRemoteOrderedInputQueue(
    private val scope: CoroutineScope,
    private val capacity: Int,
    private val consume: suspend (MacRemoteQueuedInput) -> Unit,
    private val terminate: suspend (Long) -> Unit,
    private val onFailure: (MacRemoteQueuedInput, Throwable) -> Unit
) {
    enum class OfferResult {
        ACCEPTED,
        FULL,
        TERMINATING
    }

    private val lock = Any()
    private val pending = ArrayDeque<MacRemoteQueuedInput>()
    private var terminalGeneration: Long? = null
    private var drainJob: Job? = null

    init {
        require(capacity > 0) { "remote input queue capacity must be positive" }
    }

    fun enqueue(input: MacRemoteQueuedInput): OfferResult = enqueueAll(listOf(input))

    /** Atomically accept a logical event such as key Down+Up, or accept none of it. */
    fun enqueueAll(inputs: List<MacRemoteQueuedInput>): OfferResult {
        require(inputs.isNotEmpty()) { "remote input batch must not be empty" }
        val generation = inputs.first().generation
        require(inputs.all { it.generation == generation }) {
            "remote input batch must use one connection generation"
        }
        var jobToStart: Job? = null
        val result = synchronized(lock) {
            when {
                terminalGeneration != null -> OfferResult.TERMINATING
                inputs.size > capacity - pending.size -> OfferResult.FULL
                else -> {
                    pending.addAll(inputs)
                    if (drainJob == null) {
                        jobToStart = createDrainJobLocked()
                    }
                    OfferResult.ACCEPTED
                }
            }
        }
        jobToStart?.start()
        return result
    }

    /** Stop accepting new input and run one FIFO terminal action after all accepted input. */
    fun requestTerminal(generation: Long): Boolean {
        require(generation > 0L) { "remote input terminal generation must be positive" }
        var jobToStart: Job? = null
        val accepted = synchronized(lock) {
            val currentTerminal = terminalGeneration
            when {
                currentTerminal == generation -> true
                currentTerminal != null -> false
                else -> {
                    terminalGeneration = generation
                    if (drainJob == null) {
                        jobToStart = createDrainJobLocked()
                    }
                    true
                }
            }
        }
        jobToStart?.start()
        return accepted
    }

    fun clear() {
        synchronized(lock) {
            pending.clear()
            terminalGeneration = null
        }
    }

    private fun createDrainJobLocked(): Job {
        check(drainJob == null) { "remote input drain already active" }
        lateinit var owner: Job
        owner = scope.launch(start = CoroutineStart.LAZY) {
            drain(owner)
        }
        drainJob = owner
        return owner
    }

    private suspend fun drain(owner: Job) {
        try {
            while (true) {
                val next = synchronized(lock) {
                    when {
                        drainJob !== owner -> null
                        pending.isNotEmpty() -> pending.removeFirst() to null
                        // Keep the terminal marker installed while the callback runs. A concurrent
                        // caller must observe TERMINATING rather than append work behind a close.
                        terminalGeneration != null -> null to terminalGeneration
                        else -> {
                            drainJob = null
                            null
                        }
                    }
                } ?: return
                val input = next.first
                val terminal = next.second

                if (input != null) {
                    try {
                        consume(input)
                    } catch (error: CancellationException) {
                        throw error
                    } catch (error: Exception) {
                        clear()
                        onFailure(input, error)
                        return
                    }
                } else {
                    checkNotNull(terminal)
                    terminate(terminal)
                    return
                }
            }
        } finally {
            synchronized(lock) {
                if (drainJob === owner) {
                    drainJob = null
                    pending.clear()
                    terminalGeneration = null
                }
            }
        }
    }
}
