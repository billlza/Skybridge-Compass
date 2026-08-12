package com.skybridge.compass.core.webrtc

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class WebRtcDataChannelLifecycleTest {
    @Test
    fun closeWaitsForInFlightSendThenDetachesExactlyOnce() {
        val lifecycle = WebRtcDataChannelLifecycle<String>()
        assertTrue(lifecycle.attach("skybridge", "channel") { }.accepted)

        val sendEntered = CountDownLatch(1)
        val allowSendToReturn = CountDownLatch(1)
        val closeStarted = CountDownLatch(1)
        val closeCompleted = CountDownLatch(1)
        val order = AtomicInteger(0)
        val executor = Executors.newFixedThreadPool(2)
        try {
            val send = executor.submit<Boolean> {
                lifecycle.withAttached { value ->
                    assertEquals("channel", value)
                    sendEntered.countDown()
                    assertTrue(allowSendToReturn.await(2, TimeUnit.SECONDS))
                    assertEquals(1, order.incrementAndGet())
                    true
                } ?: false
            }
            assertTrue(sendEntered.await(2, TimeUnit.SECONDS))

            val close = executor.submit<String?> {
                closeStarted.countDown()
                lifecycle.closeAndDetach().also {
                    assertEquals(2, order.incrementAndGet())
                    closeCompleted.countDown()
                }
            }
            assertTrue(closeStarted.await(2, TimeUnit.SECONDS))
            assertFalse(
                closeCompleted.await(100, TimeUnit.MILLISECONDS),
                "close must remain blocked while the linearized native send is in flight",
            )

            allowSendToReturn.countDown()
            assertTrue(send.get(2, TimeUnit.SECONDS))
            assertEquals("channel", close.get(2, TimeUnit.SECONDS))
            assertNull(lifecycle.closeAndDetach(), "close must be idempotent")
            assertFalse(lifecycle.withAttached { true } ?: false, "send after close must fail")
        } finally {
            executor.shutdownNow()
            assertTrue(executor.awaitTermination(2, TimeUnit.SECONDS))
        }
    }

    @Test
    fun closedLifecycleRejectsReplacementRegistration() {
        val lifecycle = WebRtcDataChannelLifecycle<String>()
        assertNull(lifecycle.closeAndDetach())

        var registrationCalled = false
        val result = lifecycle.attach("skybridge", "replacement") {
            registrationCalled = true
        }

        assertEquals(WebRtcDataChannelAdmission.Result.REJECT_CLOSED_SESSION, result.admission)
        assertFalse(result.accepted)
        assertFalse(registrationCalled)
    }

    @Test
    fun closeWaitsForExactAttachmentCallbackAndStaleCallbackIsRejected() {
        val lifecycle = WebRtcDataChannelLifecycle<String>()
        val channel = String(charArrayOf('c', 'h', 'a', 'n', 'n', 'e', 'l'))
        assertTrue(lifecycle.attach("skybridge", channel) { }.accepted)

        val callbackEntered = CountDownLatch(1)
        val allowCallbackToReturn = CountDownLatch(1)
        val closeCompleted = CountDownLatch(1)
        val executor = Executors.newFixedThreadPool(2)
        try {
            val callback = executor.submit<String?> {
                lifecycle.withExactAttached(channel) {
                    callbackEntered.countDown()
                    assertTrue(allowCallbackToReturn.await(2, TimeUnit.SECONDS))
                    "OPEN"
                }
            }
            assertTrue(callbackEntered.await(2, TimeUnit.SECONDS))
            val close = executor.submit<String?> {
                lifecycle.closeAndDetach().also { closeCompleted.countDown() }
            }
            assertFalse(closeCompleted.await(100, TimeUnit.MILLISECONDS))

            allowCallbackToReturn.countDown()
            assertEquals("OPEN", callback.get(2, TimeUnit.SECONDS))
            assertEquals(channel, close.get(2, TimeUnit.SECONDS))
            assertNull(lifecycle.withExactAttached(channel) { "CLOSED" })
        } finally {
            executor.shutdownNow()
            assertTrue(executor.awaitTermination(2, TimeUnit.SECONDS))
        }
    }
}
