package com.skybridge.compass.android.remote.mac

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RemoteInputSenderTest {
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false }

    @Test
    fun policyDisableBlocksNewInputButCommitsOneOwnedPointerRelease() {
        val harness = Harness()

        assertTrue(harness.sender.sendPointer(true, MouseEventType.LEFT_MOUSE_DOWN, 10.0, 20.0))
        assertFalse(harness.sender.sendPointer(false, MouseEventType.MOUSE_MOVED, 11.0, 21.0))
        assertTrue(harness.sender.sendPointer(false, MouseEventType.LEFT_MOUSE_UP, 11.0, 21.0))
        assertFalse(harness.sender.sendPointer(false, MouseEventType.LEFT_MOUSE_UP, 11.0, 21.0))

        assertEquals(
            listOf(MouseEventType.LEFT_MOUSE_DOWN, MouseEventType.LEFT_MOUSE_UP),
            harness.sent.map { RemoteControlWireCodec.decodeMouseEvent(it.second).type }
        )
        assertTrue(harness.terminalized.isEmpty())
    }

    @Test
    fun ownerReplacementNeverRedirectsMoveOrUpToTheReplacement() {
        val harness = Harness()
        val oldOwner = requireNotNull(harness.currentOwner)

        assertTrue(harness.sender.sendPointer(true, MouseEventType.LEFT_MOUSE_DOWN, 1.0, 2.0))
        val replacement = Owner()
        harness.currentOwner = replacement

        assertFalse(harness.sender.sendPointer(true, MouseEventType.MOUSE_MOVED, 3.0, 4.0))
        assertFalse(harness.sender.sendPointer(true, MouseEventType.LEFT_MOUSE_UP, 3.0, 4.0))
        assertEquals(listOf(oldOwner), harness.sent.map { it.first })

        assertTrue(harness.sender.sendPointer(true, MouseEventType.LEFT_MOUSE_DOWN, 5.0, 6.0))
        assertEquals(listOf(oldOwner, replacement), harness.sent.map { it.first })
    }

    @Test
    fun replacementCannotInterleaveWithDownCommitAndLaterUpDoesNotUseNewOwner() {
        val harness = Harness()
        val oldOwner = requireNotNull(harness.currentOwner)
        val replacement = Owner()
        val replacementAttempted = CountDownLatch(1)
        val replacementFinished = CountDownLatch(1)
        var replacementThread: Thread? = null
        harness.beforeSuccessfulSink = {
            replacementThread = thread(start = true, name = "pointer-owner-replacement") {
                replacementAttempted.countDown()
                synchronized(harness.ownerGate) {
                    harness.currentOwner = replacement
                }
                replacementFinished.countDown()
            }
            assertTrue(replacementAttempted.await(5, TimeUnit.SECONDS))
            assertEquals(1L, replacementFinished.count)
        }

        assertTrue(harness.sender.sendPointer(true, MouseEventType.LEFT_MOUSE_DOWN, 1.0, 2.0))
        replacementThread?.join(5_000)
        assertFalse(replacementThread?.isAlive == true)
        assertEquals(replacement, harness.currentOwner)
        assertFalse(harness.sender.sendPointer(true, MouseEventType.LEFT_MOUSE_UP, 1.0, 2.0))
        assertEquals(listOf(oldOwner), harness.sent.map { it.first })
    }

    @Test
    fun failedDownDoesNotRegisterPointerOwnerAndTerminalizesOnlyCapturedOwner() {
        val harness = Harness()
        val owner = requireNotNull(harness.currentOwner)
        harness.rejectNextSink = true

        assertFalse(harness.sender.sendPointer(true, MouseEventType.LEFT_MOUSE_DOWN, 1.0, 2.0))
        assertFalse(harness.sender.sendPointer(true, MouseEventType.LEFT_MOUSE_UP, 1.0, 2.0))

        assertTrue(harness.sent.isEmpty())
        assertEquals(listOf(owner), harness.terminalized)
    }

    @Test
    fun scrollUsesOneExactOwnerAndFailureTerminalizesThatOwner() {
        val harness = Harness()
        val owner = requireNotNull(harness.currentOwner)

        assertTrue(harness.sender.sendScroll(true, RemoteInputMessages.ScrollDirection.UP, 5.0, 6.0))
        harness.rejectNextSink = true
        assertFalse(harness.sender.sendScroll(true, RemoteInputMessages.ScrollDirection.DOWN, 5.0, 6.0))
        assertFalse(harness.sender.sendScroll(false, RemoteInputMessages.ScrollDirection.UP, 5.0, 6.0))

        assertEquals(1, harness.sent.size)
        assertEquals(
            MouseEventType.SCROLL_UP,
            RemoteControlWireCodec.decodeMouseEvent(harness.sent.single().second).type
        )
        assertEquals(listOf(owner), harness.terminalized)
    }

    @Test
    fun keyStrokeBuilderProducesMacVirtualKeyDownThenUpInOrder() {
        val messages = RemoteInputMessages.keyStroke(
            json = json,
            keyCode = MacVirtualKeyCode(0x24),
            timestamp = 1.0
        )

        assertEquals(
            listOf(KeyboardEventType.KEY_DOWN, KeyboardEventType.KEY_UP),
            messages.map(RemoteControlWireCodec::decodeKeyboardEvent).map { it.type }
        )
        assertEquals(
            listOf(0x24, 0x24),
            messages.map(RemoteControlWireCodec::decodeKeyboardEvent).map { it.keyCode }
        )
    }

    private inner class Harness {
        val ownerGate = Any()
        var currentOwner: Owner? = Owner()
        val sent = mutableListOf<Pair<Owner, RemoteMessage>>()
        val terminalized = mutableListOf<Owner>()
        var rejectNextSink = false
        var beforeSuccessfulSink: () -> Unit = {}
        val sender = RemoteInputSender(
            json = json,
            clockSeconds = { 1.0 },
            currentAcknowledgedOwner = { currentOwner },
            commitIfCurrentAcknowledgedOwner = { owner, commit ->
                synchronized(ownerGate) {
                    if (currentOwner !== owner) {
                        false
                    } else {
                        commit()
                        true
                    }
                }
            },
            sink = { owner, message ->
                if (rejectNextSink) {
                    rejectNextSink = false
                    false
                } else {
                    beforeSuccessfulSink()
                    beforeSuccessfulSink = {}
                    sent += owner to message
                    true
                }
            },
            terminalize = { owner -> terminalized += owner }
        )
    }

    private class Owner
}
