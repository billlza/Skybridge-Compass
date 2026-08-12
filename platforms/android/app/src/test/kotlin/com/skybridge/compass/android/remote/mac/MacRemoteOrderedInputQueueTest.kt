package com.skybridge.compass.android.remote.mac

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class MacRemoteOrderedInputQueueTest {
    private val json = Json { explicitNulls = false }

    @Test
    fun concurrentSchedulingStillWritesOneExactFifoFrameSequence() = runTest {
        val firstWriteEntered = CompletableDeferred<Unit>()
        val releaseFirstWrite = CompletableDeferred<Unit>()
        val framedWire = ByteArrayOutputStream()
        var consumeCount = 0
        val queue = MacRemoteOrderedInputQueue(
            scope = this,
            capacity = 8,
            consume = { input ->
                consumeCount += 1
                if (consumeCount == 1) {
                    firstWriteEntered.complete(Unit)
                    releaseFirstWrite.await()
                }
                appendFrame(framedWire, input.encodedMessage())
            },
            terminate = {},
            onFailure = { _, error -> throw error }
        )
        val keyStroke = RemoteInputMessages.keyStroke(
            json = json,
            keyCode = MacVirtualKeyCode(0x24),
            timestamp = 1.0
        ).map { MacRemoteQueuedInput.from(1L, it) }
        val pointerDown = MacRemoteQueuedInput.from(
            1L,
            RemoteInputMessages.mouse(json, MouseEventType.LEFT_MOUSE_DOWN, 10.0, 20.0, 2.0)
        )
        val pointerMove = MacRemoteQueuedInput.from(
            1L,
            RemoteInputMessages.mouse(json, MouseEventType.MOUSE_MOVED, 11.0, 21.0, 3.0)
        )
        val pointerUp = MacRemoteQueuedInput.from(
            1L,
            RemoteInputMessages.mouse(json, MouseEventType.LEFT_MOUSE_UP, 11.0, 21.0, 4.0)
        )

        assertEquals(MacRemoteOrderedInputQueue.OfferResult.ACCEPTED, queue.enqueueAll(keyStroke))
        runCurrent()
        firstWriteEntered.await()
        assertEquals(MacRemoteOrderedInputQueue.OfferResult.ACCEPTED, queue.enqueue(pointerDown))
        assertEquals(MacRemoteOrderedInputQueue.OfferResult.ACCEPTED, queue.enqueue(pointerMove))
        assertEquals(MacRemoteOrderedInputQueue.OfferResult.ACCEPTED, queue.enqueue(pointerUp))
        releaseFirstWrite.complete(Unit)
        advanceUntilIdle()

        val decoded = decodeFrames(framedWire.toByteArray())
        assertEquals(5, decoded.size)
        assertEquals(
            listOf(KeyboardEventType.KEY_DOWN, KeyboardEventType.KEY_UP),
            decoded.take(2).map(RemoteControlWireCodec::decodeKeyboardEvent).map { it.type }
        )
        assertEquals(
            listOf(
                MouseEventType.LEFT_MOUSE_DOWN,
                MouseEventType.MOUSE_MOVED,
                MouseEventType.LEFT_MOUSE_UP
            ),
            decoded.drop(2).map(RemoteControlWireCodec::decodeMouseEvent).map { it.type }
        )
    }

    @Test
    fun keyStrokeBatchIsRejectedAtomicallyWhenOnlyOneQueueSlotExists() = runTest {
        val written = mutableListOf<RemoteMessage>()
        val queue = MacRemoteOrderedInputQueue(
            scope = this,
            capacity = 1,
            consume = { written += RemoteControlWireCodec.decodeMessage(it.encodedMessage()) },
            terminate = {},
            onFailure = { _, error -> throw error }
        )
        val keyStroke = RemoteInputMessages.keyStroke(
            json = json,
            keyCode = MacVirtualKeyCode(0x00),
            timestamp = 1.0
        ).map { MacRemoteQueuedInput.from(1L, it) }

        assertEquals(MacRemoteOrderedInputQueue.OfferResult.FULL, queue.enqueueAll(keyStroke))
        advanceUntilIdle()

        assertTrue(written.isEmpty())
    }

    @Test
    fun terminalRejectsNewInputUntilCompletionThenTransientConsumerRestarts() = runTest {
        val terminalEntered = CompletableDeferred<Unit>()
        val releaseTerminal = CompletableDeferred<Unit>()
        val consumedGenerations = mutableListOf<Long>()
        val terminatedGenerations = mutableListOf<Long>()
        val queue = MacRemoteOrderedInputQueue(
            scope = this,
            capacity = 4,
            consume = { consumedGenerations += it.generation },
            terminate = { generation ->
                terminalEntered.complete(Unit)
                releaseTerminal.await()
                terminatedGenerations += generation
            },
            onFailure = { _, error -> throw error }
        )
        val first = queuedMouse(generation = 1L, MouseEventType.LEFT_MOUSE_DOWN)

        assertEquals(MacRemoteOrderedInputQueue.OfferResult.ACCEPTED, queue.enqueue(first))
        assertTrue(queue.requestTerminal(1L))
        runCurrent()
        terminalEntered.await()
        assertEquals(
            MacRemoteOrderedInputQueue.OfferResult.TERMINATING,
            queue.enqueue(queuedMouse(generation = 2L, MouseEventType.MOUSE_MOVED))
        )
        releaseTerminal.complete(Unit)
        advanceUntilIdle()

        assertEquals(listOf(1L), consumedGenerations)
        assertEquals(listOf(1L), terminatedGenerations)
        assertEquals(
            MacRemoteOrderedInputQueue.OfferResult.ACCEPTED,
            queue.enqueue(queuedMouse(generation = 2L, MouseEventType.MOUSE_MOVED))
        )
        advanceUntilIdle()
        assertEquals(listOf(1L, 2L), consumedGenerations)
    }

    @Test
    fun revokedFormalRouteAtConsumerCommitProducesNoWireBytes() = runTest {
        val routeCurrent = AtomicBoolean(true)
        val consumerEntered = CompletableDeferred<Unit>()
        val releaseConsumer = CompletableDeferred<Unit>()
        val framedWire = ByteArrayOutputStream()
        val queue = MacRemoteOrderedInputQueue(
            scope = this,
            capacity = 4,
            consume = { input ->
                consumerEntered.complete(Unit)
                releaseConsumer.await()
                if (
                    MacRemoteFormalRouteAuthorizationPolicy.isCurrent(
                        mode = MacRemoteControlTrustMode.FORMAL_ACCEPTANCE_READ_ONLY,
                        lease = MacRemoteFormalRouteAuthorizationLease(routeCurrent::get)
                    )
                ) {
                    appendFrame(framedWire, input.encodedMessage())
                }
            },
            terminate = {},
            onFailure = { _, error -> throw error }
        )

        queue.enqueue(queuedMouse(generation = 1L, MouseEventType.LEFT_MOUSE_DOWN))
        runCurrent()
        consumerEntered.await()
        routeCurrent.set(false)
        releaseConsumer.complete(Unit)
        advanceUntilIdle()

        assertEquals(0, framedWire.size())
    }

    @Test
    fun lifecycleInvalidationBeforePressedStateCommitCannotResurrectOldGeneration() {
        val lifecycleLock = Any()
        var generation = 1L
        val flushCompleted = java.util.concurrent.CountDownLatch(1)
        val allowPressedCommit = java.util.concurrent.CountDownLatch(1)
        val committed = AtomicReference<Boolean?>(null)
        var pressedDown = false
        val writer = thread(start = true, name = "remote-input-pressed-commit") {
            flushCompleted.countDown()
            check(allowPressedCommit.await(5, java.util.concurrent.TimeUnit.SECONDS))
            committed.set(
                runIfCurrentMacRemoteInputCommit(
                    lifecycleLock = lifecycleLock,
                    isCurrent = { generation == 1L },
                    commitPressedState = { pressedDown = true }
                )
            )
        }
        assertTrue(flushCompleted.await(5, java.util.concurrent.TimeUnit.SECONDS))

        synchronized(lifecycleLock) {
            generation = 2L
            pressedDown = false
        }
        allowPressedCommit.countDown()
        writer.join(5_000)

        assertEquals(false, committed.get())
        assertEquals(false, pressedDown)
        assertEquals(false, writer.isAlive)
    }

    @Test
    fun normalTerminalSnapshotProducesExactKeyAndPointerReleases() {
        val state = MacRemotePressedInputState()
        val keyDown = MacRemoteQueuedInput.from(
            1L,
            RemoteInputMessages.keyboard(
                json,
                KeyboardEventType.KEY_DOWN,
                MacVirtualKeyCode(0x24),
                1.0
            )
        )
        val pointerDown = queuedMouse(1L, MouseEventType.LEFT_MOUSE_DOWN)
        val pointerMove = MacRemoteQueuedInput.from(
            1L,
            RemoteInputMessages.mouse(json, MouseEventType.MOUSE_MOVED, 8.0, 9.0, 2.0)
        )
        state.record(keyDown)
        state.record(pointerDown)
        state.record(pointerMove)

        val releases = state.releaseMessages(1L, json, 3.0)

        assertEquals(2, releases.size)
        assertEquals(
            KeyboardEventType.KEY_UP,
            RemoteControlWireCodec.decodeKeyboardEvent(releases[0]).type
        )
        assertEquals(0x24, RemoteControlWireCodec.decodeKeyboardEvent(releases[0]).keyCode)
        val pointerRelease = RemoteControlWireCodec.decodeMouseEvent(releases[1])
        assertEquals(MouseEventType.LEFT_MOUSE_UP, pointerRelease.type)
        assertEquals(8.0, pointerRelease.x, 0.0)
        assertEquals(9.0, pointerRelease.y, 0.0)

        state.record(MacRemoteQueuedInput.from(1L, releases[0]))
        state.record(MacRemoteQueuedInput.from(1L, releases[1]))
        assertTrue(state.releaseMessages(1L, json, 4.0).isEmpty())
        state.clear()
        assertTrue(state.releaseMessages(1L, json, 5.0).isEmpty())
    }

    private fun queuedMouse(generation: Long, type: MouseEventType): MacRemoteQueuedInput =
        MacRemoteQueuedInput.from(
            generation,
            RemoteInputMessages.mouse(json, type, 1.0, 2.0, 3.0)
        )

    private fun appendFrame(output: ByteArrayOutputStream, payload: ByteArray) {
        output.write(
            ByteBuffer.allocate(Int.SIZE_BYTES)
                .order(ByteOrder.BIG_ENDIAN)
                .putInt(payload.size)
                .array()
        )
        output.write(payload)
    }

    private fun decodeFrames(bytes: ByteArray): List<RemoteMessage> {
        val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.BIG_ENDIAN)
        return buildList {
            while (buffer.hasRemaining()) {
                val length = buffer.int
                require(length > 0 && length <= buffer.remaining()) { "invalid test frame length" }
                val payload = ByteArray(length)
                buffer.get(payload)
                add(RemoteControlWireCodec.decodeMessage(payload))
            }
        }
    }
}
