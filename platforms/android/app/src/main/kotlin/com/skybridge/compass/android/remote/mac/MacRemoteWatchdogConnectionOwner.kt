package com.skybridge.compass.android.remote.mac

/** Exact transport and interruption window captured by one no-frame watchdog decision. */
internal data class MacRemoteWatchdogConnectionOwner(
    val generation: Long,
    val transportIdentity: Any,
    val interruptionAtMs: Long
) {
    init {
        require(generation > 0L) { "watchdog connection generation must be positive" }
        require(interruptionAtMs >= 0L) { "watchdog interruption timestamp must not be negative" }
    }

    fun matches(
        currentGeneration: Long,
        currentTransportIdentity: Any?,
        currentInterruptionAtMs: Long?,
        lastFrameAtMs: Long
    ): Boolean =
        generation == currentGeneration &&
            transportIdentity === currentTransportIdentity &&
            interruptionAtMs == currentInterruptionAtMs &&
            lastFrameAtMs < interruptionAtMs
}

/**
 * Atomically proves and detaches one watchdog-owned transport without acquiring the transport's
 * potentially blocked write lock. The detached resource must be closed by the caller outside
 * [lifecycleLock].
 */
internal fun <Detached> detachIfCurrentMacRemoteWatchdogOwner(
    lifecycleLock: Any,
    owner: MacRemoteWatchdogConnectionOwner,
    currentGeneration: () -> Long,
    currentTransportIdentity: () -> Any?,
    currentInterruptionAtMs: () -> Long?,
    lastFrameAtMs: () -> Long,
    additionalCurrent: () -> Boolean = { true },
    detach: () -> Detached
): Detached? = synchronized(lifecycleLock) {
    if (
        !additionalCurrent() ||
        !owner.matches(
            currentGeneration = currentGeneration(),
            currentTransportIdentity = currentTransportIdentity(),
            currentInterruptionAtMs = currentInterruptionAtMs(),
            lastFrameAtMs = lastFrameAtMs()
        )
    ) {
        null
    } else {
        detach()
    }
}
