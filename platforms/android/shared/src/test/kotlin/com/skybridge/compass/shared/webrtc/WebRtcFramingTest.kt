package com.skybridge.compass.shared.webrtc

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class WebRtcFramingTest {

    @Test
    fun frameAndDeframeRoundTripSinglePayload() {
        val payload = "skybridge-payload".encodeToByteArray()

        val decoded = WebRtcFraming.deframe(WebRtcFraming.frame(payload))

        assertEquals(1, decoded.size)
        assertArrayEquals(payload, decoded.single())
    }

    @Test
    fun deframeReadsConcatenatedFrames() {
        val first = "first".encodeToByteArray()
        val second = "second".encodeToByteArray()

        val combined = WebRtcFraming.frame(first) + WebRtcFraming.frame(second)

        val decoded = WebRtcFraming.deframe(combined)
        assertEquals(2, decoded.size)
        assertArrayEquals(first, decoded[0])
        assertArrayEquals(second, decoded[1])
    }

    @Test
    fun deframeRejectsUnframedLegacyPayload() {
        assertThrows(IllegalArgumentException::class.java) {
            WebRtcFraming.deframe("legacy-raw-payload".encodeToByteArray())
        }
    }

    @Test
    fun deframeRejectsTruncatedPayload() {
        val framed = WebRtcFraming.frame("payload".encodeToByteArray()).dropLast(2).toByteArray()

        assertThrows(IllegalArgumentException::class.java) {
            WebRtcFraming.deframe(framed)
        }
    }
}
