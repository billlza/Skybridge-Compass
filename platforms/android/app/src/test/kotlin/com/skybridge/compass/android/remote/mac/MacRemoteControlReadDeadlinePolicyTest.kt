package com.skybridge.compass.android.remote.mac

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.InputStream
import java.net.Socket
import java.net.SocketTimeoutException

class MacRemoteControlReadDeadlinePolicyTest {

    @Test
    fun readFullyCompletesAcrossShortReads() {
        val out = ByteArray(5)
        val source = ChunkedInputStream(byteArrayOf(1, 2, 3, 4, 5), maxChunkSize = 2)

        val completed = MacRemoteControlReadDeadlinePolicy.readFully(
            input = source,
            out = out,
            stage = MacRemoteControlReadDeadlinePolicy.Stage.FRAME_PAYLOAD
        )

        assertTrue(completed)
        assertArrayEquals(byteArrayOf(1, 2, 3, 4, 5), out)
    }

    @Test
    fun readFullyReturnsFalseWhenPeerClosesBeforeBufferCompletes() {
        val out = ByteArray(4)

        val completed = MacRemoteControlReadDeadlinePolicy.readFully(
            input = ByteArrayInputStream(byteArrayOf(1, 2)),
            out = out,
            stage = MacRemoteControlReadDeadlinePolicy.Stage.FRAME_HEADER
        )

        assertFalse(completed)
    }

    @Test
    fun readFullyConvertsSocketTimeoutToStageSpecificFailure() {
        val cause = SocketTimeoutException("Read timed out")
        val failure = org.junit.Assert.assertThrows(
            MacRemoteControlReadDeadlinePolicy.ReadTimeoutException::class.java
        ) {
            MacRemoteControlReadDeadlinePolicy.readFully(
                input = TimeoutInputStream(cause),
                out = ByteArray(4),
                stage = MacRemoteControlReadDeadlinePolicy.Stage.FRAME_HEADER,
                timeoutMillis = 123
            )
        }

        assertEquals(MacRemoteControlReadDeadlinePolicy.Stage.FRAME_HEADER, failure.stage)
        assertEquals(0, failure.readBytes)
        assertEquals(4, failure.expectedBytes)
        assertEquals(123, failure.timeoutMillis)
        assertSame(cause, failure.cause)
        assertEquals(
            "remote read timed out after 123ms while reading frame header (0/4 bytes)",
            failure.message
        )
    }

    @Test
    fun readFullyReportsPartialPayloadProgressOnTimeout() {
        val cause = SocketTimeoutException("Read timed out")
        val failure = org.junit.Assert.assertThrows(
            MacRemoteControlReadDeadlinePolicy.ReadTimeoutException::class.java
        ) {
            MacRemoteControlReadDeadlinePolicy.readFully(
                input = PartialThenTimeoutInputStream(byteArrayOf(9, 8), cause),
                out = ByteArray(4),
                stage = MacRemoteControlReadDeadlinePolicy.Stage.FRAME_PAYLOAD,
                timeoutMillis = 456
            )
        }

        assertEquals(MacRemoteControlReadDeadlinePolicy.Stage.FRAME_PAYLOAD, failure.stage)
        assertEquals(2, failure.readBytes)
        assertEquals(4, failure.expectedBytes)
        assertEquals(456, failure.timeoutMillis)
        assertSame(cause, failure.cause)
        assertEquals(
            "remote read timed out after 456ms while reading frame payload (2/4 bytes)",
            failure.message
        )
    }

    @Test
    fun configureSocketUsesFiniteFrameReadDeadline() {
        Socket().use { socket ->
            MacRemoteControlReadDeadlinePolicy.configureSocket(socket)

            assertTrue(socket.tcpNoDelay)
            assertEquals(MacRemoteControlReadDeadlinePolicy.FRAME_READ_TIMEOUT_MILLIS, socket.soTimeout)
            assertTrue(socket.soTimeout > 0)
        }
    }

    @Test
    fun readFullyUsesOneAbsoluteDeadlineAcrossSlowShortReads() {
        var nowNanos = 0L
        val appliedTimeouts = mutableListOf<Int>()
        var index = 0
        val source = object : InputStream() {
            override fun read(b: ByteArray, off: Int, len: Int): Int {
                b[off] = index++.toByte()
                nowNanos += 40_000_000L
                return 1
            }

            override fun read(): Int = error("buffered read is required")
        }

        val failure = org.junit.Assert.assertThrows(
            MacRemoteControlReadDeadlinePolicy.ReadTimeoutException::class.java
        ) {
            MacRemoteControlReadDeadlinePolicy.readFully(
                input = source,
                out = ByteArray(4),
                stage = MacRemoteControlReadDeadlinePolicy.Stage.FRAME_PAYLOAD,
                timeoutMillis = 100,
                monotonicNanos = { nowNanos },
                updateReadTimeoutMillis = appliedTimeouts::add
            )
        }

        assertEquals(3, failure.readBytes)
        assertEquals(100, failure.timeoutMillis)
        assertEquals(listOf(100, 60, 20), appliedTimeouts)
    }

    @Test
    fun readFullyCompletesShortReadsWhenCumulativeTimeStaysWithinDeadline() {
        var nowNanos = 0L
        val appliedTimeouts = mutableListOf<Int>()
        var index = 0
        val source = object : InputStream() {
            override fun read(b: ByteArray, off: Int, len: Int): Int {
                b[off] = index++.toByte()
                nowNanos += 20_000_000L
                return 1
            }

            override fun read(): Int = error("buffered read is required")
        }
        val out = ByteArray(3)

        assertTrue(
            MacRemoteControlReadDeadlinePolicy.readFully(
                input = source,
                out = out,
                stage = MacRemoteControlReadDeadlinePolicy.Stage.FRAME_PAYLOAD,
                timeoutMillis = 100,
                monotonicNanos = { nowNanos },
                updateReadTimeoutMillis = appliedTimeouts::add
            )
        )

        assertArrayEquals(byteArrayOf(0, 1, 2), out)
        assertEquals(listOf(100, 80, 60), appliedTimeouts)
    }

    @Test
    fun readFullyFailsClosedWhenAReadCompletesExactlyAtDeadline() {
        var nowNanos = 0L
        val source = object : InputStream() {
            override fun read(b: ByteArray, off: Int, len: Int): Int {
                b[off] = 7
                nowNanos = 100_000_000L
                return 1
            }

            override fun read(): Int = error("buffered read is required")
        }

        val failure = org.junit.Assert.assertThrows(
            MacRemoteControlReadDeadlinePolicy.ReadTimeoutException::class.java
        ) {
            MacRemoteControlReadDeadlinePolicy.readFully(
                input = source,
                out = ByteArray(2),
                stage = MacRemoteControlReadDeadlinePolicy.Stage.FRAME_HEADER,
                timeoutMillis = 100,
                monotonicNanos = { nowNanos }
            )
        }

        assertEquals(1, failure.readBytes)
        assertEquals(MacRemoteControlReadDeadlinePolicy.Stage.FRAME_HEADER, failure.stage)
    }

    @Test
    fun readFullyDoesNotSaturateWhenMonotonicClockStartsNegative() {
        var nowNanos = -1L
        var index = 0
        val source = object : InputStream() {
            override fun read(b: ByteArray, off: Int, len: Int): Int {
                b[off] = index++.toByte()
                nowNanos += 40_000_000L
                return 1
            }

            override fun read(): Int = error("buffered read is required")
        }

        val failure = org.junit.Assert.assertThrows(
            MacRemoteControlReadDeadlinePolicy.ReadTimeoutException::class.java
        ) {
            MacRemoteControlReadDeadlinePolicy.readFully(
                input = source,
                out = ByteArray(4),
                stage = MacRemoteControlReadDeadlinePolicy.Stage.FRAME_PAYLOAD,
                timeoutMillis = 100,
                monotonicNanos = { nowNanos }
            )
        }

        assertEquals(3, failure.readBytes)
    }

    @Test
    fun readFullyRemainsCorrectAcrossSignedNanoTimeWrap() {
        var nowNanos = Long.MAX_VALUE - 50_000_000L
        var index = 0
        val source = object : InputStream() {
            override fun read(b: ByteArray, off: Int, len: Int): Int {
                b[off] = index++.toByte()
                nowNanos += 20_000_000L
                return 1
            }

            override fun read(): Int = error("buffered read is required")
        }

        val out = ByteArray(3)
        assertTrue(
            MacRemoteControlReadDeadlinePolicy.readFully(
                input = source,
                out = out,
                stage = MacRemoteControlReadDeadlinePolicy.Stage.FRAME_PAYLOAD,
                timeoutMillis = 100,
                monotonicNanos = { nowNanos }
            )
        )
        assertArrayEquals(byteArrayOf(0, 1, 2), out)
    }

    private class TimeoutInputStream(
        private val failure: SocketTimeoutException
    ) : InputStream() {
        override fun read(): Int = throw failure

        override fun read(b: ByteArray, off: Int, len: Int): Int = throw failure
    }

    private class ChunkedInputStream(
        bytes: ByteArray,
        private val maxChunkSize: Int
    ) : ByteArrayInputStream(bytes) {
        override fun read(b: ByteArray, off: Int, len: Int): Int =
            super.read(b, off, minOf(len, maxChunkSize))
    }

    private class PartialThenTimeoutInputStream(
        bytes: ByteArray,
        private val failure: SocketTimeoutException
    ) : ByteArrayInputStream(bytes) {
        override fun read(b: ByteArray, off: Int, len: Int): Int {
            if (available() == 0) throw failure
            return super.read(b, off, minOf(len, available()))
        }
    }
}
