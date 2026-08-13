package com.skybridge.compass.core.p2p

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertFalse
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.net.SocketTimeoutException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.Random

class LengthPrefixedFramingTest {

    @Test
    fun `readFrame handles short reads`() {
        val random = Random(42)
        repeat(1000) {
            val payloadLen = random.nextInt(16 * 1024)
            val payload = ByteArray(payloadLen).also { random.nextBytes(it) }
            val framed = ByteArrayOutputStream().use { out ->
                LengthPrefixedFraming.writeFrame(out, payload)
                out.toByteArray()
            }

            val chunked = ChunkedInputStream(framed, maxChunkSize = 7, random = random)
            val readBack = LengthPrefixedFraming.readFrame(chunked, maxFrameSize = 16 * 1024 * 1024)
            assertArrayEquals(payload, readBack)
        }
    }

    @Test
    fun `oversized handshake prefix is rejected before payload read`() {
        val oversizedLength = 16 * 1024 * 1024
        val header = ByteBuffer.allocate(Int.SIZE_BYTES)
            .order(ByteOrder.BIG_ENDIAN)
            .putInt(oversizedLength)
            .array()
        val input = HeaderOnlyInputStream(header)

        assertThrows(IllegalStateException::class.java) {
            LengthPrefixedFraming.readFrame(
                input = input,
                maxFrameSize = com.skybridge.compass.shared.p2p.P2PHandshakeWire.MAX_HANDSHAKE_FRAME_BYTES
            )
        }

        assertFalse(input.payloadReadAttempted)
    }

    @Test
    fun `absolute handshake budget expires across slow short reads`() {
        val framed = ByteArrayOutputStream().use { out ->
            LengthPrefixedFraming.writeFrame(out, byteArrayOf(1, 2, 3, 4))
            out.toByteArray()
        }
        val input = ChunkedInputStream(framed, maxChunkSize = 1, random = Random(7))
        var nowNanos = 0L
        val deadline = TcpHandshakeDeadline.deadlineNanos(
            startNanos = nowNanos,
            timeoutMillis = 10
        )

        assertThrows(SocketTimeoutException::class.java) {
            LengthPrefixedFraming.readFrame(
                input = input,
                maxFrameSize = 16,
                beforeRead = {
                    TcpHandshakeDeadline.remainingTimeoutMillis(deadline, nowNanos)
                    nowNanos += 4_000_000L
                }
            )
        }
    }

    @Test
    fun `deadline arithmetic is monotonic wrap safe and rounds up`() {
        val start = Long.MAX_VALUE - 5_000_000L
        val deadline = TcpHandshakeDeadline.deadlineNanos(start, timeoutMillis = 10)

        assertEquals(10, TcpHandshakeDeadline.remainingTimeoutMillis(deadline, start))
        assertEquals(
            1,
            TcpHandshakeDeadline.remainingTimeoutMillis(deadline, start + 9_999_999L)
        )
        assertThrows(SocketTimeoutException::class.java) {
            TcpHandshakeDeadline.remainingTimeoutMillis(deadline, start + 10_000_000L)
        }
    }

    private class ChunkedInputStream(
        private val data: ByteArray,
        private val maxChunkSize: Int,
        private val random: Random
    ) : InputStream() {
        private val inner = ByteArrayInputStream(data)

        override fun read(): Int = inner.read()

        override fun read(b: ByteArray, off: Int, len: Int): Int {
            if (len <= 0) return 0
            val max = minOf(len, maxChunkSize)
            val chunk = 1 + random.nextInt(max)
            return inner.read(b, off, chunk)
        }
    }

    private class HeaderOnlyInputStream(
        private val header: ByteArray
    ) : InputStream() {
        private var offset = 0
        var payloadReadAttempted = false
            private set

        override fun read(): Int {
            if (offset < header.size) return header[offset++].toInt() and 0xff
            payloadReadAttempted = true
            throw AssertionError("oversized payload must not be read")
        }

        override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
            if (this.offset >= header.size) {
                payloadReadAttempted = true
                throw AssertionError("oversized payload must not be read")
            }
            val count = minOf(length, header.size - this.offset)
            header.copyInto(buffer, destinationOffset = offset, startIndex = this.offset, endIndex = this.offset + count)
            this.offset += count
            return count
        }
    }
}
