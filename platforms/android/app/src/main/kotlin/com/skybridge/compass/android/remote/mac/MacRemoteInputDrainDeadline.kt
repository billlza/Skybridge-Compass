package com.skybridge.compass.android.remote.mac

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** Exact connection owner captured when a normal input drain begins. */
internal data class MacRemoteInputDrainOwner(
    val generation: Long,
    val transportIdentity: Any
) {
    init {
        require(generation > 0L) { "remote input drain generation must be positive" }
    }

    fun matches(currentGeneration: Long, currentTransportIdentity: Any?): Boolean =
        generation == currentGeneration && transportIdentity === currentTransportIdentity
}

/** Atomically detaches only the exact generation/transport captured by [owner]. */
internal fun <Detached> detachIfCurrentMacRemoteInputOwner(
    lifecycleLock: Any,
    owner: MacRemoteInputDrainOwner,
    currentGeneration: () -> Long,
    currentTransportIdentity: () -> Any?,
    detach: () -> Detached
): Detached? = synchronized(lifecycleLock) {
    if (!owner.matches(currentGeneration(), currentTransportIdentity())) {
        null
    } else {
        detach()
    }
}

/**
 * Invalidates the connection current at an explicit-disconnect commit point. This also advances an
 * ownerless generation while a watchdog replacement is between detach and registration.
 */
internal fun <Detached> detachMacRemoteConnectionForUserDisconnect(
    lifecycleLock: Any,
    userDisconnectRequested: () -> Boolean,
    detach: () -> Detached
): Detached? = synchronized(lifecycleLock) {
    if (!userDisconnectRequested()) null else detach()
}

/**
 * Bounded graceful-drain deadline. Timeout delegates an exact owner to the client, which may close
 * only that transport; a stale deadline therefore cannot affect a replacement connection.
 */
internal class MacRemoteInputDrainDeadline(
    private val scope: CoroutineScope,
    private val timeoutMillis: Long,
    private val onTimeout: (MacRemoteInputDrainOwner) -> Unit
) {
    private val lock = Any()
    private var armedOwner: MacRemoteInputDrainOwner? = null
    private var deadlineJob: Job? = null

    init {
        require(timeoutMillis > 0L) { "remote input drain timeout must be positive" }
    }

    fun arm(owner: MacRemoteInputDrainOwner): Boolean {
        lateinit var created: Job
        created = scope.launch(start = CoroutineStart.LAZY) {
            delay(timeoutMillis)
            val stillOwned = synchronized(lock) {
                armedOwner?.matches(owner.generation, owner.transportIdentity) == true &&
                    deadlineJob === created
            }
            if (stillOwned) onTimeout(owner)
        }
        val installed = synchronized(lock) {
            if (armedOwner != null) {
                false
            } else {
                armedOwner = owner
                deadlineJob = created
                true
            }
        }
        if (installed) {
            created.invokeOnCompletion {
                synchronized(lock) {
                    if (deadlineJob === created) {
                        deadlineJob = null
                        armedOwner = null
                    }
                }
            }
            created.start()
        } else {
            created.cancel()
        }
        return installed
    }

    fun clearIfOwned(owner: MacRemoteInputDrainOwner): Boolean {
        val job = synchronized(lock) {
            if (armedOwner?.matches(owner.generation, owner.transportIdentity) != true) {
                return false
            }
            armedOwner = null
            deadlineJob.also { deadlineJob = null }
        }
        job?.cancel()
        return true
    }

}
