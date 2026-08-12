package com.skybridge.compass.auth

import kotlinx.coroutines.sync.Mutex

/** Serializes every operation that can install, replace, restore, or revoke an auth session. */
internal class AuthMutationCoordinator {
    private val mutex = Mutex()

    suspend fun <T> withLock(operation: suspend () -> T): T {
        mutex.lock()
        return try {
            operation()
        } finally {
            mutex.unlock()
        }
    }
}
