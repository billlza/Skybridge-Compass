package com.skybridge.compass.core.p2p

import java.io.EOFException
import java.io.InputStream
import java.io.OutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Pro release framing: 4-byte big-endian length prefix + payload bytes.
 */
object LengthPrefixedFraming {
    fun writeFrame(out: OutputStream, payload: ByteArray) {
        val header = ByteBuffer.allocate(4).order(ByteOrder.BIG_ENDIAN).putInt(payload.size).array()
        out.write(header)
        out.write(payload)
        out.flush()
    }

    fun readFrame(input: InputStream, maxFrameSize: Int): ByteArray {
        return readFrame(input, maxFrameSize, beforeRead = {})
    }

    internal fun readFrame(
        input: InputStream,
        maxFrameSize: Int,
        beforeRead: () -> Unit
    ): ByteArray {
        val header = readExactly(input, 4, beforeRead)
        val len = ByteBuffer.wrap(header).order(ByteOrder.BIG_ENDIAN).int
        if (len <= 0 || len > maxFrameSize) {
            throw IllegalStateException("Invalid frame length: $len")
        }
        return readExactly(input, len, beforeRead)
    }

    private fun readExactly(input: InputStream, len: Int, beforeRead: () -> Unit): ByteArray {
        val buf = ByteArray(len)
        var off = 0
        while (off < len) {
            beforeRead()
            val n = input.read(buf, off, len - off)
            if (n < 0) throw EOFException("EOF")
            off += n
        }
        return buf
    }
}
