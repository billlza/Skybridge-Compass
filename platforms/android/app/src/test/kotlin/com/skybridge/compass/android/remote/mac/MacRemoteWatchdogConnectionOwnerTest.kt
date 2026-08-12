package com.skybridge.compass.android.remote.mac

import java.io.IOException
import java.io.OutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class MacRemoteWatchdogConnectionOwnerTest {
    @Test
    fun exactWatchdogOwnerDetachesAndClosesWithoutWaitingForBlockedWriter() {
        val lifecycleLock = Any()
        val output = BlockingOutputStream()
        var generation = 1L
        var transport: OutputStream? = output
        var interruptionAtMs: Long? = 100L
        val lastFrameAtMs = 0L
        val owner = MacRemoteWatchdogConnectionOwner(1L, output, 100L)
        val writeFailure = AtomicReference<Throwable?>()
        val writer = thread(start = true, name = "watchdog-blocked-output") {
            writeFailure.set(runCatching { output.write(1) }.exceptionOrNull())
        }
        assertTrue(output.writeEntered.await(5, TimeUnit.SECONDS))

        val detached = detachIfCurrentMacRemoteWatchdogOwner(
            lifecycleLock = lifecycleLock,
            owner = owner,
            currentGeneration = { generation },
            currentTransportIdentity = { transport },
            currentInterruptionAtMs = { interruptionAtMs },
            lastFrameAtMs = { lastFrameAtMs },
            detach = {
                generation = 2L
                interruptionAtMs = null
                checkNotNull(transport).also { transport = null }
            }
        )

        assertSame(output, detached)
        requireNotNull(detached).close()
        writer.join(5_000)
        assertFalse(writer.isAlive)
        assertTrue(writeFailure.get() is IOException)
    }

    @Test
    fun staleWatchdogOwnerCannotDetachOrCloseReplacementTransport() {
        val lifecycleLock = Any()
        val oldTransport = CloseTrackingOutputStream()
        val replacementTransport = CloseTrackingOutputStream()
        val oldOwner = MacRemoteWatchdogConnectionOwner(1L, oldTransport, 100L)
        val generation = 2L
        val transport: OutputStream = replacementTransport
        val interruptionAtMs = 200L
        val lastFrameAtMs = 0L

        val detached = detachIfCurrentMacRemoteWatchdogOwner(
            lifecycleLock = lifecycleLock,
            owner = oldOwner,
            currentGeneration = { generation },
            currentTransportIdentity = { transport },
            currentInterruptionAtMs = { interruptionAtMs },
            lastFrameAtMs = { lastFrameAtMs },
            detach = { error("stale watchdog owner must not detach the replacement") }
        )

        assertNull(detached)
        assertFalse(oldTransport.closed)
        assertFalse(replacementTransport.closed)
        assertSame(replacementTransport, transport)
    }

    @Test
    fun recoveredFrameInvalidatesTheCapturedInterruptionToken() {
        val transport = CloseTrackingOutputStream()
        val owner = MacRemoteWatchdogConnectionOwner(1L, transport, 100L)

        val detached = detachIfCurrentMacRemoteWatchdogOwner(
            lifecycleLock = Any(),
            owner = owner,
            currentGeneration = { 1L },
            currentTransportIdentity = { transport },
            currentInterruptionAtMs = { 100L },
            lastFrameAtMs = { 100L },
            detach = { transport }
        )

        assertNull(detached)
        assertFalse(transport.closed)
    }

    @Test
    fun explicitDisconnectIntentWinsBeforeQueuedWatchdogReplacementDetach() {
        val lifecycleLock = Any()
        val transport = CloseTrackingOutputStream()
        val owner = MacRemoteWatchdogConnectionOwner(1L, transport, 100L)
        val disconnectRequested = AtomicBoolean(false)
        val replacementAttempting = CountDownLatch(1)
        val detached = AtomicReference<OutputStream?>()
        lateinit var replacementThread: Thread

        synchronized(lifecycleLock) {
            replacementThread = thread(start = true, name = "queued-watchdog-replacement") {
                replacementAttempting.countDown()
                detached.set(
                    detachIfCurrentMacRemoteWatchdogOwner(
                        lifecycleLock = lifecycleLock,
                        owner = owner,
                        currentGeneration = { 1L },
                        currentTransportIdentity = { transport },
                        currentInterruptionAtMs = { 100L },
                        lastFrameAtMs = { 0L },
                        additionalCurrent = { !disconnectRequested.get() },
                        detach = { transport }
                    )
                )
            }
            assertTrue(replacementAttempting.await(5, TimeUnit.SECONDS))
            disconnectRequested.set(true)
        }

        replacementThread.join(5_000)
        assertFalse(replacementThread.isAlive)
        assertNull(detached.get())
        assertFalse(transport.closed)
    }

    private class BlockingOutputStream : OutputStream() {
        val writeEntered = CountDownLatch(1)
        private val closedLatch = CountDownLatch(1)

        override fun write(value: Int) {
            writeEntered.countDown()
            check(closedLatch.await(5, TimeUnit.SECONDS)) { "blocking output was not closed" }
            throw IOException("closed")
        }

        override fun close() {
            closedLatch.countDown()
        }
    }

    private class CloseTrackingOutputStream : OutputStream() {
        @Volatile var closed: Boolean = false
            private set

        override fun write(value: Int) = Unit

        override fun close() {
            closed = true
        }
    }
}
