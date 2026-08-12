package com.skybridge.compass.auth

import java.util.concurrent.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.yield
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AuthImportRollbackTest {
    @Test
    fun partialImportFailureClearsThenDetachesThenCloses() = runBlocking {
        val events = mutableListOf<String>()
        val original = IllegalStateException("partial import")

        val result = rollbackUncertainSessionImport(
            originalError = original,
            clearPersistedSession = true,
            clearPersistedSessionAction = { events += "clear" },
            detachClientAction = { events += "detach" },
            closeClientAction = { events += "close" }
        )

        assertEquals(listOf("clear", "detach", "close"), events)
        assertFalse(result.cleanupFailed)
        assertTrue(original.suppressed.isEmpty())
    }

    @Test
    fun cleanupFailuresDoNotPreventOwnershipDetachmentOrRemainingCleanup() = runBlocking {
        val events = mutableListOf<String>()
        val original = IllegalStateException("partial import")

        val result = rollbackUncertainSessionImport(
            originalError = original,
            clearPersistedSession = true,
            clearPersistedSessionAction = {
                events += "clear"
                throw IllegalStateException("clear failed")
            },
            detachClientAction = { events += "detach" },
            closeClientAction = {
                events += "close"
                throw IllegalStateException("close failed")
            }
        )

        assertEquals(listOf("clear", "detach", "close"), events)
        assertTrue(result.cleanupFailed)
        assertEquals(listOf("clear failed", "close failed"), original.suppressed.map { it.message })
    }

    @Test
    fun detachFailureStillClosesClientAndIsReportedAsCleanupFailure() = runBlocking {
        val events = mutableListOf<String>()
        val original = IllegalStateException("partial import")

        val result = rollbackUncertainSessionImport(
            originalError = original,
            clearPersistedSession = false,
            clearPersistedSessionAction = { throw AssertionError("must not clear") },
            detachClientAction = {
                events += "detach"
                throw IllegalStateException("detach failed")
            },
            closeClientAction = { events += "close" }
        )

        assertEquals(listOf("detach", "close"), events)
        assertTrue(result.cleanupFailed)
        assertEquals(listOf("detach failed"), original.suppressed.map { it.message })
    }

    @Test
    fun cancellationUsesSameOwnerCleanupWithoutDeletingNonPersistedSession() = runBlocking {
        val events = mutableListOf<String>()
        val original = CancellationException("cancelled import")

        val result = rollbackUncertainSessionImport(
            originalError = original,
            clearPersistedSession = false,
            clearPersistedSessionAction = { events += "clear" },
            detachClientAction = { events += "detach" },
            closeClientAction = { events += "close" }
        )

        assertEquals(listOf("detach", "close"), events)
        assertFalse(result.cleanupFailed)
    }

    @Test
    fun closeReThrowingOriginalCancellationDoesNotSelfSuppress() = runBlocking {
        val original = CancellationException("cancelled import")

        val result = rollbackUncertainSessionImport(
            originalError = original,
            clearPersistedSession = false,
            clearPersistedSessionAction = { error("must not clear") },
            detachClientAction = {},
            closeClientAction = { throw original }
        )

        assertTrue(result.cleanupFailed)
        assertFalse(original.suppressed.any { it === original })
    }

    @Test
    fun clearReThrowingOriginalFailureStillDetachesAndClosesWithoutSelfSuppression() = runBlocking {
        val events = mutableListOf<String>()
        val original = IllegalStateException("partial import")

        val result = rollbackUncertainSessionImport(
            originalError = original,
            clearPersistedSession = true,
            clearPersistedSessionAction = { throw original },
            detachClientAction = { events += "detach" },
            closeClientAction = { events += "close" }
        )

        assertEquals(listOf("detach", "close"), events)
        assertTrue(result.cleanupFailed)
        assertFalse(original.suppressed.any { it === original })
    }

    @Test
    fun cancelledJobStillRunsSuspendingClientCloseToCompletion() = runBlocking {
        val started = CompletableDeferred<Unit>()
        val closeCompleted = CompletableDeferred<Unit>()
        val job = launch {
            try {
                started.complete(Unit)
                awaitCancellation()
            } catch (error: CancellationException) {
                rollbackUncertainSessionImport(
                    originalError = error,
                    clearPersistedSession = false,
                    clearPersistedSessionAction = { throw AssertionError("must not clear") },
                    detachClientAction = {},
                    closeClientAction = {
                        delay(1L)
                        closeCompleted.complete(Unit)
                    }
                )
                throw error
            }
        }
        started.await()
        yield()

        job.cancel()
        withTimeout(1_000L) { job.join() }

        assertTrue(closeCompleted.isCompleted)
    }
}
