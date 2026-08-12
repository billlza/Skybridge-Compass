package com.skybridge.compass.android.remote.mac

import java.io.IOException
import java.io.OutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class MacRemoteInputDrainDeadlineTest {
    @Test
    fun deadlineClosesExactOwnerAndUnblocksARealBlockingOutputWrite() = runTest {
        val output = BlockingOutputStream()
        val owner = MacRemoteInputDrainOwner(generation = 1L, transportIdentity = output)
        val currentOwner = AtomicReference(owner)
        val deadline = MacRemoteInputDrainDeadline(
            scope = this,
            timeoutMillis = 100L,
            onTimeout = { expired ->
                if (expired == currentOwner.get() && expired.matches(1L, output)) {
                    output.close()
                }
            }
        )
        val write = async(Dispatchers.IO) {
            runCatching { output.write(1) }.exceptionOrNull()
        }
        assertTrue(output.writeEntered.await(5, TimeUnit.SECONDS))

        assertTrue(deadline.arm(owner))
        advanceTimeBy(100L)
        runCurrent()

        assertTrue(output.closed.await(5, TimeUnit.SECONDS))
        assertTrue(write.await() is IOException)
    }

    @Test
    fun staleDeadlineCannotCloseReplacementWithSameGenerationShape() = runTest {
        val oldTransport = BlockingOutputStream()
        val replacementTransport = BlockingOutputStream()
        val oldOwner = MacRemoteInputDrainOwner(1L, oldTransport)
        val replacementOwner = MacRemoteInputDrainOwner(2L, replacementTransport)
        val currentOwner = AtomicReference(oldOwner)
        val deadline = MacRemoteInputDrainDeadline(
            scope = this,
            timeoutMillis = 100L,
            onTimeout = { expired ->
                val current = currentOwner.get()
                if (expired.matches(current.generation, current.transportIdentity)) {
                    (expired.transportIdentity as BlockingOutputStream).close()
                }
            }
        )

        assertTrue(deadline.arm(oldOwner))
        currentOwner.set(replacementOwner)
        advanceTimeBy(100L)
        runCurrent()

        assertFalse(oldTransport.isClosed)
        assertFalse(replacementTransport.isClosed)
    }

    @Test
    fun staleExactOwnerCannotDetachOrCloseReplacementTransport() {
        val lifecycleLock = Any()
        var generation = 2L
        val oldTransport = BlockingOutputStream()
        val replacementTransport = BlockingOutputStream()
        var currentTransport: OutputStream? = replacementTransport
        val oldOwner = MacRemoteInputDrainOwner(1L, oldTransport)

        val detached = detachIfCurrentMacRemoteInputOwner(
            lifecycleLock = lifecycleLock,
            owner = oldOwner,
            currentGeneration = { generation },
            currentTransportIdentity = { currentTransport },
            detach = {
                generation += 1L
                checkNotNull(currentTransport).also { currentTransport = null }
            }
        )

        assertNull(detached)
        assertFalse(oldTransport.isClosed)
        assertFalse(replacementTransport.isClosed)
        assertTrue(currentTransport === replacementTransport)
    }

    @Test
    fun explicitDisconnectFallsThroughFromStaleOwnerAndDetachesCurrentReplacement() {
        val lifecycleLock = Any()
        var generation = 2L
        val oldTransport = BlockingOutputStream()
        val replacementTransport = BlockingOutputStream()
        var currentTransport: OutputStream? = replacementTransport
        val staleOwner = MacRemoteInputDrainOwner(1L, oldTransport)

        assertNull(
            detachIfCurrentMacRemoteInputOwner(
                lifecycleLock = lifecycleLock,
                owner = staleOwner,
                currentGeneration = { generation },
                currentTransportIdentity = { currentTransport },
                detach = { error("stale owner must not detach the replacement") }
            )
        )
        val detachedCurrent = detachMacRemoteConnectionForUserDisconnect(
            lifecycleLock = lifecycleLock,
            userDisconnectRequested = { true },
            detach = {
                generation += 1L
                checkNotNull(currentTransport).also { currentTransport = null }
            }
        )

        assertTrue(detachedCurrent === replacementTransport)
        requireNotNull(detachedCurrent).close()
        assertFalse(oldTransport.isClosed)
        assertTrue(replacementTransport.isClosed)
        assertNull(currentTransport)
    }

    @Test
    fun explicitDisconnectAdvancesOwnerlessWatchdogReplacementGap() {
        val lifecycleLock = Any()
        var generation = 2L
        val advancedGeneration = detachMacRemoteConnectionForUserDisconnect(
            lifecycleLock = lifecycleLock,
            userDisconnectRequested = { true },
            detach = {
                generation += 1L
                generation
            }
        )

        assertEquals(3L, advancedGeneration)
        assertEquals(3L, generation)
    }

    private class BlockingOutputStream : OutputStream() {
        val writeEntered = CountDownLatch(1)
        val closed = CountDownLatch(1)

        @Volatile
        var isClosed: Boolean = false
            private set

        override fun write(value: Int) {
            writeEntered.countDown()
            check(closed.await(5, TimeUnit.SECONDS)) { "blocking output was not closed" }
            throw IOException("closed")
        }

        override fun close() {
            isClosed = true
            closed.countDown()
        }
    }
}
