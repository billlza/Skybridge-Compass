package com.skybridge.compass.core.p2p

import org.junit.Assert.assertArrayEquals
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
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
}

