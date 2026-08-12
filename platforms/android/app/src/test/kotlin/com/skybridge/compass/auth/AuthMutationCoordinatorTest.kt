package com.skybridge.compass.auth

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.yield
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AuthMutationCoordinatorTest {
    @Test
    fun serializesSessionMutations() = runBlocking {
        val coordinator = AuthMutationCoordinator()
        val ownerEntered = CompletableDeferred<Unit>()
        val releaseOwner = CompletableDeferred<Unit>()
        val waiterStarted = CompletableDeferred<Unit>()
        val waiterEntered = CompletableDeferred<Unit>()

        val owner = async(Dispatchers.Default) {
            coordinator.withLock {
                ownerEntered.complete(Unit)
                releaseOwner.await()
            }
        }
        ownerEntered.await()
        val waiter = async(Dispatchers.Default) {
            waiterStarted.complete(Unit)
            coordinator.withLock { waiterEntered.complete(Unit) }
        }
        waiterStarted.await()
        yield()

        assertFalse(waiterEntered.isCompleted)
        releaseOwner.complete(Unit)
        withTimeout(1_000L) { owner.await() }
        withTimeout(1_000L) { waiter.await() }
        assertTrue(waiterEntered.isCompleted)
    }

    @Test
    fun cancellingWaitingMutationNeverEntersAndDoesNotDisturbOwner() = runBlocking {
        val coordinator = AuthMutationCoordinator()
        val ownerEntered = CompletableDeferred<Unit>()
        val releaseOwner = CompletableDeferred<Unit>()
        val waiterStarted = CompletableDeferred<Unit>()
        val waiterEntered = CompletableDeferred<Unit>()

        val owner = launch(Dispatchers.Default) {
            coordinator.withLock {
                ownerEntered.complete(Unit)
                releaseOwner.await()
            }
        }
        ownerEntered.await()
        val waiter = launch(Dispatchers.Default) {
            waiterStarted.complete(Unit)
            coordinator.withLock { waiterEntered.complete(Unit) }
        }
        waiterStarted.await()
        waiter.cancelAndJoin()

        assertFalse(waiterEntered.isCompleted)
        assertTrue(owner.isActive)
        releaseOwner.complete(Unit)
        withTimeout(1_000L) { owner.join() }
        withTimeout(1_000L) { coordinator.withLock { Unit } }
    }

    @Test
    fun cancellingOwnerReleasesMutationOwnership() = runBlocking {
        val coordinator = AuthMutationCoordinator()
        val ownerEntered = CompletableDeferred<Unit>()
        val owner = launch(Dispatchers.Default) {
            coordinator.withLock {
                ownerEntered.complete(Unit)
                awaitCancellation()
            }
        }
        ownerEntered.await()

        owner.cancelAndJoin()

        withTimeout(1_000L) { coordinator.withLock { Unit } }
    }
}
