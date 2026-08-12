package com.skybridge.compass.android.ui.screens.remotecontrol

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WebRtcRemoteKeyStrokeCommitterTest {
    @Test
    fun ownerReplacementCannotInterleaveBetweenKeyDownAndUp() {
        val gate = Any()
        var currentOwner = 1
        val ownerAtSend = mutableListOf<Int>()
        val replacementAttempted = CountDownLatch(1)
        val replacementFinished = CountDownLatch(1)
        var replacementThread: Thread? = null

        val complete = WebRtcRemoteKeyStrokeCommitter.commit(
            encodedKeyEvents = listOf(byteArrayOf(1), byteArrayOf(2)),
            commitIfCurrentAcknowledgedOwner = { commit ->
                synchronized(gate) {
                    if (currentOwner != 1) {
                        false
                    } else {
                        commit()
                        true
                    }
                }
            },
            sendForCapturedOwner = { event ->
                ownerAtSend += currentOwner
                if (event.contentEquals(byteArrayOf(1))) {
                    replacementThread = thread(start = true, name = "remote-key-owner-replacement") {
                        replacementAttempted.countDown()
                        synchronized(gate) { currentOwner = 2 }
                        replacementFinished.countDown()
                    }
                    assertTrue(replacementAttempted.await(5, TimeUnit.SECONDS))
                    assertEquals(1L, replacementFinished.count)
                }
                true
            },
            terminalizeCapturedOwner = { error("complete key stroke must not terminalize") }
        )
        replacementThread?.join(5_000)

        assertTrue(complete)
        assertEquals(listOf(1, 1), ownerAtSend)
        assertEquals(2, currentOwner)
        assertEquals(0L, replacementFinished.count)
        assertFalse(replacementThread?.isAlive == true)
    }

    @Test
    fun partialKeyStrokeFailureTerminalizesTheCapturedOwnerOnce() {
        val sends = AtomicInteger(0)
        val terminalizations = AtomicInteger(0)

        val complete = WebRtcRemoteKeyStrokeCommitter.commit(
            encodedKeyEvents = listOf(byteArrayOf(1), byteArrayOf(2)),
            commitIfCurrentAcknowledgedOwner = { commit -> commit(); true },
            sendForCapturedOwner = { sends.incrementAndGet() == 1 },
            terminalizeCapturedOwner = { terminalizations.incrementAndGet() }
        )

        assertFalse(complete)
        assertEquals(2, sends.get())
        assertEquals(1, terminalizations.get())
    }

    @Test
    fun rejectedExactOwnerGateSendsNothingAndDoesNotTerminalizeReplacement() {
        val sends = AtomicInteger(0)
        val terminalizations = AtomicInteger(0)

        val complete = WebRtcRemoteKeyStrokeCommitter.commit(
            encodedKeyEvents = listOf(byteArrayOf(1), byteArrayOf(2)),
            commitIfCurrentAcknowledgedOwner = { false },
            sendForCapturedOwner = { sends.incrementAndGet(); true },
            terminalizeCapturedOwner = { terminalizations.incrementAndGet() }
        )

        assertFalse(complete)
        assertEquals(0, sends.get())
        assertEquals(0, terminalizations.get())
    }
}
