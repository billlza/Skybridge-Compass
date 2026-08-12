package com.skybridge.compass.core.webrtc

import java.nio.ByteBuffer
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class WebRtcDataChannelFramingTest {
    @Test
    fun fragmentedHeaderAndPayloadProduceOneExactFrame() {
        val decoder = WebRtcDataChannelFraming.Decoder(maximumFrameBytes = 32, maximumChunkBytes = 8)
        val framed = frame(byteArrayOf(1, 2, 3, 4, 5))

        assertEquals(emptyList<ByteArray>(), decoder.push(framed.copyOfRange(0, 1)))
        assertEquals(emptyList<ByteArray>(), decoder.push(framed.copyOfRange(1, 2)))
        assertEquals(emptyList<ByteArray>(), decoder.push(framed.copyOfRange(2, 6)))
        val frames = decoder.push(framed.copyOfRange(6, framed.size))

        assertEquals(1, frames.size)
        assertArrayEquals(byteArrayOf(1, 2, 3, 4, 5), frames.single())
    }

    @Test
    fun oneTransportChunkMayContainMultipleFrames() {
        val decoder = WebRtcDataChannelFraming.Decoder(maximumFrameBytes = 32, maximumChunkBytes = 32)
        val combined = frame(byteArrayOf(0x11)) + frame(byteArrayOf(0x22, 0x33))

        val frames = decoder.push(combined)

        assertEquals(2, frames.size)
        assertArrayEquals(byteArrayOf(0x11), frames[0])
        assertArrayEquals(byteArrayOf(0x22, 0x33), frames[1])
    }

    @Test
    fun transportChunkIsRejectedBeforeCopyingWhenItExceedsTheProtocolLimit() {
        val oversized = ByteBuffer.wrap(ByteArray(WebRtcDataChannelFraming.MAXIMUM_CHUNK_BYTES + 1))

        assertThrows(WebRtcDataChannelProtocolException::class.java) {
            WebRtcDataChannelFraming.copyAdmittedChunk(oversized)
        }
        assertEquals(0, oversized.position())
    }

    @Test
    fun zeroNegativeAndOversizedFrameLengthsAreRejectedAndStateResets() {
        val decoder = WebRtcDataChannelFraming.Decoder(maximumFrameBytes = 16, maximumChunkBytes = 16)
        val invalidHeaders = listOf(
            byteArrayOf(0, 0, 0, 0),
            byteArrayOf(0xFF.toByte(), 0xFF.toByte(), 0xFF.toByte(), 0xFF.toByte()),
            byteArrayOf(0, 0, 0, 17)
        )

        invalidHeaders.forEach { header ->
            assertThrows(WebRtcDataChannelProtocolException::class.java) {
                decoder.push(header)
            }
            val recovered = decoder.push(frame(byteArrayOf(0x55)))
            assertEquals(1, recovered.size)
            assertArrayEquals(byteArrayOf(0x55), recovered.single())
        }
    }

    @Test
    fun exactMaximumFragmentedPayloadIsAccepted() {
        val decoder = WebRtcDataChannelFraming.Decoder(maximumFrameBytes = 8, maximumChunkBytes = 8)
        val framed = frame(ByteArray(8) { it.toByte() })

        assertEquals(emptyList<ByteArray>(), decoder.push(framed.copyOfRange(0, 8)))
        val frames = decoder.push(framed.copyOfRange(8, framed.size))

        assertEquals(1, frames.size)
        assertArrayEquals(ByteArray(8) { it.toByte() }, frames.single())
    }

    @Test
    fun outboundEncoderEnforcesTheSameFrameContract() {
        assertThrows(WebRtcDataChannelProtocolException::class.java) {
            WebRtcDataChannelFraming.encode(byteArrayOf())
        }
        assertThrows(WebRtcDataChannelProtocolException::class.java) {
            WebRtcDataChannelFraming.encode(ByteArray(WebRtcDataChannelFraming.MAXIMUM_FRAME_BYTES + 1))
        }

        val payload = byteArrayOf(0x31, 0x32)
        assertArrayEquals(frame(payload), WebRtcDataChannelFraming.encode(payload))
    }

    private fun frame(payload: ByteArray): ByteArray {
        val length = payload.size
        return byteArrayOf(
            (length ushr 24).toByte(),
            (length ushr 16).toByte(),
            (length ushr 8).toByte(),
            length.toByte()
        ) + payload
    }
}
