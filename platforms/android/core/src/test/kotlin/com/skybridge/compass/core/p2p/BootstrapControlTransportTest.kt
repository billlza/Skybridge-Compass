package com.skybridge.compass.core.p2p

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.Closeable
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.channels.SocketChannel
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread

class BootstrapControlTransportTest {
    @Test
    fun deadlineArithmeticIsWrapSafeForNegativeAndNearOverflowNanoTime() {
        val negativeStart = -25_000_000L
        val negativeDeadline = BootstrapControlDeadline.deadlineNanos(negativeStart, 30)
        assertEquals(30_000_000L, BootstrapControlDeadline.remainingNanos(negativeDeadline, negativeStart))

        val nearOverflowStart = Long.MAX_VALUE - 5_000_000L
        val wrappedDeadline = BootstrapControlDeadline.deadlineNanos(nearOverflowStart, 10)
        assertTrue(wrappedDeadline < 0L)
        assertEquals(10_000_000L, BootstrapControlDeadline.remainingNanos(wrappedDeadline, nearOverflowStart))
        assertEquals(
            1_000_000L,
            BootstrapControlDeadline.remainingNanos(wrappedDeadline, nearOverflowStart + 9_000_000L)
        )
    }

    @Test
    fun finalTransferThatCrossesDeadlineIsRejectedEvenWhenItCompletesBuffer() {
        var complete = false
        val times = ArrayDeque(listOf(1L, 11L))
        val failure = assertThrows(BootstrapControlTransport.TransportException::class.java) {
            BootstrapControlTransfer.untilComplete(
                deadlineNanos = 10L,
                nanoTime = { times.removeFirst() },
                isComplete = { complete },
                transfer = { complete = true },
                awaitReady = { fail("completed transfer must not await readiness") }
            )
        }
        assertTrue(failure.message.orEmpty().contains("timed out"))
    }

    @Test
    fun prefixAndBodyTransfersShareOneAbsoluteDeadline() {
        var now = 1L
        var prefixComplete = false
        BootstrapControlTransfer.untilComplete(
            deadlineNanos = 10L,
            nanoTime = { now },
            isComplete = { prefixComplete },
            transfer = {
                now = 8L
                prefixComplete = true
            },
            awaitReady = { fail("prefix completed in one transfer") }
        )

        var bodyComplete = false
        assertThrows(BootstrapControlTransport.TransportException::class.java) {
            BootstrapControlTransfer.untilComplete(
                deadlineNanos = 10L,
                nanoTime = { now },
                isComplete = { bodyComplete },
                transfer = {
                    now = 10L
                    bodyComplete = true
                },
                awaitReady = { fail("body completed in one transfer") }
            )
        }
    }

    @Test
    fun continuouslyReadyIncompleteTransferStillExpires() {
        var now = 1L
        var transferCount = 0
        assertThrows(BootstrapControlTransport.TransportException::class.java) {
            BootstrapControlTransfer.untilComplete(
                deadlineNanos = 10L,
                nanoTime = { now },
                isComplete = { false },
                transfer = { transferCount++ },
                awaitReady = { now += 5L }
            )
        }
        assertEquals(2, transferCount)
    }

    @Test
    fun closeFailuresNeverReplacePrimaryThrowable() {
        val primary = AssertionError("primary")
        val closeFailure = IOException("close")
        val result = BootstrapControlResourceCloser.close(
            primaryFailure = primary,
            resources = listOf(Closeable { throw closeFailure })
        )

        assertTrue(result == null)
        assertSame(closeFailure, primary.suppressed.single())
    }

    @Test
    fun successCloseFailureReturnsFirstAndSuppressesLaterFailures() {
        val first = IOException("first")
        val second = AssertionError("second")
        val result = BootstrapControlResourceCloser.close(
            primaryFailure = null,
            resources = listOf(
                Closeable { throw first },
                Closeable { throw second }
            )
        )

        assertSame(first, result)
        assertSame(second, first.suppressed.single())
    }

    @Test
    fun selectorAcquisitionFailureClosesAlreadyOwnedChannel() = runTest {
        val channel = SocketChannel.open()
        val transport = BootstrapControlTransport(
            channelFactory = { channel },
            selectorFactory = { throw IOException("selector unavailable") }
        )

        try {
            transport.exchange(
                host = "192.168.1.20",
                port = 9_999,
                body = byteArrayOf(1),
                timeoutMs = 1_000
            )
            fail("expected transport failure")
        } catch (expected: BootstrapControlTransport.TransportException) {
            assertTrue(expected.message.orEmpty().contains("exchange failed"))
        }
        assertFalse(channel.isOpen)
    }

    @Test
    fun coroutineCancellationInterruptsAcquisitionWithoutTransportWrapping() = runTest {
        val started = CountDownLatch(1)
        val interrupted = AtomicBoolean(false)
        var observedFailure: Throwable? = null
        val transport = BootstrapControlTransport(
            channelFactory = {
                started.countDown()
                try {
                    CountDownLatch(1).await()
                } catch (e: InterruptedException) {
                    interrupted.set(true)
                    throw e
                }
                error("unreachable")
            }
        )
        val job = launch {
            try {
                transport.exchange(
                    host = "192.168.1.20",
                    port = 9_999,
                    body = byteArrayOf(1),
                    timeoutMs = 1_000
                )
            } catch (failure: Throwable) {
                observedFailure = failure
                throw failure
            }
        }
        assertTrue(withContext(Dispatchers.IO) { started.await(2, TimeUnit.SECONDS) })

        job.cancelAndJoin()

        assertTrue(interrupted.get())
        assertTrue(observedFailure is CancellationException)
    }

    @Test
    fun resolvedBonjourEndpointRejectsNamesAndNonPeerAddressClasses() {
        val accepted = ResolvedBootstrapControlEndpoint.fromResolvedBonjour("192.168.1.20", 9_999)
        assertEquals("192.168.1.20", accepted.hostAddress)
        assertEquals(9_999, accepted.port)

        listOf("mac.local", "0.0.0.0", "127.0.0.1", "::1", "224.0.0.1", "ff02::fb")
            .forEach { host ->
                assertThrows(IllegalArgumentException::class.java) {
                    ResolvedBootstrapControlEndpoint.fromResolvedBonjour(host, 9_999)
                }
            }
    }

    @Test
    fun partialPrefixAndBodyFromLoopbackPeerAreReadAsOneBoundedResponse() = runTest {
        val expected = ByteArray(257) { index -> (index and 0xff).toByte() }
        withBootstrapServer(
            respond = { socket ->
                readBootstrapRequest(socket)
                val output = socket.getOutputStream()
                val prefix = ByteBuffer.allocate(Int.SIZE_BYTES).putInt(expected.size).array()
                prefix.forEach { byte: Byte ->
                    output.write(byte.toInt() and 0xff)
                    output.flush()
                }
                expected.asList().chunked(7).forEach { chunk ->
                    output.write(chunk.toByteArray())
                    output.flush()
                }
            }
        ) { port ->
            val actual = BootstrapControlTransport().exchange(
                host = LOOPBACK_ADDRESS,
                port = port,
                body = byteArrayOf(1, 2, 3),
                timeoutMs = 2_000
            )
            assertTrue(expected.contentEquals(actual))
        }
    }

    @Test
    fun eofDuringResponsePrefixIsAProtocolTransportFailure() = runTest {
        withBootstrapServer(
            respond = { socket ->
                readBootstrapRequest(socket)
                socket.getOutputStream().write(byteArrayOf(0, 0))
            }
        ) { port ->
            val failure = captureTransportFailure(port)
            assertTrue(failure.message.orEmpty().contains("before 4 bytes"))
        }
    }

    @Test
    fun eofDuringResponseBodyIsAProtocolTransportFailure() = runTest {
        withBootstrapServer(
            respond = { socket ->
                readBootstrapRequest(socket)
                val output = DataOutputStream(socket.getOutputStream())
                output.writeInt(8)
                output.write(byteArrayOf(1, 2, 3))
            }
        ) { port ->
            val failure = captureTransportFailure(port)
            assertTrue(failure.message.orEmpty().contains("before 8 bytes"))
        }
    }

    @Test
    fun oversizedResponseLengthIsRejectedBeforeBodyAllocation() = runTest {
        withBootstrapServer(
            respond = { socket ->
                readBootstrapRequest(socket)
                DataOutputStream(socket.getOutputStream()).writeInt(
                    BootstrapControlTransport.MAX_BODY_BYTES + 1
                )
            }
        ) { port ->
            val failure = captureTransportFailure(port)
            assertTrue(failure.message.orEmpty().contains("invalid inbound"))
        }
    }

    private suspend fun captureTransportFailure(port: Int): BootstrapControlTransport.TransportException =
        try {
            BootstrapControlTransport().exchange(
                host = LOOPBACK_ADDRESS,
                port = port,
                body = byteArrayOf(1),
                timeoutMs = 2_000
            )
            throw AssertionError("expected bootstrap-control transport failure")
        } catch (expected: BootstrapControlTransport.TransportException) {
            expected
        }

    private fun readBootstrapRequest(socket: Socket): ByteArray {
        val input = DataInputStream(socket.getInputStream())
        val length = input.readInt()
        require(length in 1..BootstrapControlTransport.MAX_BODY_BYTES)
        return ByteArray(length).also(input::readFully)
    }

    private suspend fun <T> withBootstrapServer(
        respond: (Socket) -> Unit,
        client: suspend (Int) -> T
    ): T {
        val server = ServerSocket(0, 1, InetAddress.getByName(LOOPBACK_ADDRESS))
        val serverFailure = AtomicReference<Throwable?>(null)
        val accepted = AtomicBoolean(false)
        val serverThread = thread(name = "bootstrap-control-test-server", isDaemon = true) {
            try {
                server.accept().use { socket ->
                    accepted.set(true)
                    respond(socket)
                }
            } catch (failure: Throwable) {
                if (accepted.get() || !server.isClosed) serverFailure.set(failure)
            }
        }
        return try {
            client(server.localPort)
        } finally {
            server.close()
            serverThread.join(5_000)
            assertFalse("loopback bootstrap server did not terminate", serverThread.isAlive)
            serverFailure.get()?.let { throw AssertionError("loopback bootstrap server failed", it) }
        }
    }

    private companion object {
        const val LOOPBACK_ADDRESS = "127.0.0.1"
    }
}
