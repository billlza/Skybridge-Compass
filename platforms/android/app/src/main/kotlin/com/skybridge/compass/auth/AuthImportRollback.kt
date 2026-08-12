package com.skybridge.compass.auth

import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext

internal data class AuthImportRollbackResult(val cleanupFailed: Boolean)

/**
 * Compensates an import that may have partially installed credentials before throwing.
 * Durable credentials are cleared first, ownership is detached second, and the client is closed
 * last so no callback can republish the uncertain session.
 */
internal suspend fun rollbackUncertainSessionImport(
    originalError: Throwable,
    clearPersistedSession: Boolean,
    clearPersistedSessionAction: () -> Unit,
    detachClientAction: () -> Unit,
    closeClientAction: suspend () -> Unit
): AuthImportRollbackResult {
    var cleanupFailed = false
    fun recordCleanupFailure(cleanupError: RuntimeException) {
        cleanupFailed = true
        if (cleanupError !== originalError) {
            originalError.addSuppressed(cleanupError)
        }
    }
    if (clearPersistedSession) {
        try {
            clearPersistedSessionAction()
        } catch (cleanupError: RuntimeException) {
            recordCleanupFailure(cleanupError)
        }
    }
    try {
        detachClientAction()
    } catch (cleanupError: RuntimeException) {
        recordCleanupFailure(cleanupError)
    }
    try {
        withContext(NonCancellable) { closeClientAction() }
    } catch (cleanupError: RuntimeException) {
        recordCleanupFailure(cleanupError)
    }
    return AuthImportRollbackResult(cleanupFailed = cleanupFailed)
}
