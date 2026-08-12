package com.skybridge.compass.android.ui.screens.remotecontrol

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LanRemoteOwnerLinearizationTest {
    @Test
    fun routeLeaseRevocationDoesNotWaitForExternalAuthorizationCheck() {
        val checkerEntered = CountDownLatch(1)
        val releaseChecker = CountDownLatch(1)
        val leaseResult = AtomicBoolean(true)
        val lease = LanRemoteRouteAuthorizationLease {
            checkerEntered.countDown()
            check(releaseChecker.await(5, TimeUnit.SECONDS))
            true
        }
        val checking = thread {
            leaseResult.set(lease.isCurrent())
        }
        assertTrue(checkerEntered.await(5, TimeUnit.SECONDS))

        val revocationFinished = CountDownLatch(1)
        val revoking = thread {
            lease.revoke()
            revocationFinished.countDown()
        }
        assertTrue(
            "revocation must not acquire the ViewModel or client connection lock",
            revocationFinished.await(1, TimeUnit.SECONDS)
        )
        releaseChecker.countDown()
        checking.join(5_000)
        revoking.join(5_000)

        assertFalse(checking.isAlive)
        assertFalse(revoking.isAlive)
        assertFalse(leaseResult.get())
    }

    @Test
    fun replacementThatLinearizesFirstPreventsActionOnOldOwner() {
        val lock = Any()
        val oldOwner = Any()
        var currentOwner: Any? = oldOwner
        val replacementOwnsLock = CountDownLatch(1)
        val releaseReplacement = CountDownLatch(1)
        val actionResult = AtomicBoolean(true)
        val actionCount = AtomicInteger(0)

        val replacement = thread {
            synchronized(lock) {
                currentOwner = null
                replacementOwnsLock.countDown()
                check(releaseReplacement.await(5, TimeUnit.SECONDS))
            }
        }
        assertTrue(replacementOwnsLock.await(5, TimeUnit.SECONDS))
        val action = thread {
            actionResult.set(
                runLinearizedLanRemoteOwnerAction(
                    lock = lock,
                    ownedValue = { currentOwner },
                    action = { actionCount.incrementAndGet() }
                )
            )
        }

        releaseReplacement.countDown()
        replacement.join(5_000)
        action.join(5_000)

        assertFalse(replacement.isAlive)
        assertFalse(action.isAlive)
        assertFalse(actionResult.get())
        assertEquals(0, actionCount.get())
    }

    @Test
    fun actionThatLinearizesFirstCompletesBeforeReplacement() {
        val lock = Any()
        var currentOwner: Any? = Any()
        val actionOwnsLock = CountDownLatch(1)
        val releaseAction = CountDownLatch(1)
        val replacementStarted = CountDownLatch(1)
        val order = mutableListOf<String>()

        val action = thread {
            runLinearizedLanRemoteOwnerAction(
                lock = lock,
                ownedValue = { currentOwner }
            ) {
                actionOwnsLock.countDown()
                check(releaseAction.await(5, TimeUnit.SECONDS))
                order += "action"
            }
        }
        assertTrue(actionOwnsLock.await(5, TimeUnit.SECONDS))
        val replacement = thread {
            replacementStarted.countDown()
            synchronized(lock) {
                currentOwner = null
                order += "replacement"
            }
        }
        assertTrue(replacementStarted.await(5, TimeUnit.SECONDS))
        releaseAction.countDown()
        action.join(5_000)
        replacement.join(5_000)

        assertEquals(listOf("action", "replacement"), order)
    }
}
