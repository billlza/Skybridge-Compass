package com.skybridge.compass.core.webrtc

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AndroidRemoteVideoFormatsTest {

    @Test
    fun streamingFormats_preferHevcThenH264ThenJpeg() {
        val formats = AndroidRemoteVideoFormats.videoFormatsForMimeTypes(
            setOf("video/hevc", "video/avc")
        )

        assertEquals(listOf("hevc", "h264", "jpeg"), formats)
    }

    @Test
    fun normalizeIncomingFormat_treatsBgraWrappedJpegAsJpeg() {
        val jpeg = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte(), 0x00)

        assertEquals(
            AndroidRemoteVideoFormats.JPEG,
            AndroidRemoteVideoFormats.normalizeIncomingFormat("bgra", jpeg)
        )
    }

    @Test
    fun normalizeIncomingFormat_detectsIsoBmffImageFormats() {
        val avif = byteArrayOf(
            0x00, 0x00, 0x00, 0x18,
            0x66, 0x74, 0x79, 0x70,
            0x61, 0x76, 0x69, 0x66,
            0x00, 0x00, 0x00, 0x00
        )

        assertEquals(
            "avif",
            AndroidRemoteVideoFormats.normalizeIncomingFormat(null, avif)
        )
    }

    @Test
    fun normalizeIncomingFormat_rejectsUnknownBgraPayload() {
        assertNull(
            AndroidRemoteVideoFormats.normalizeIncomingFormat(
                "bgra",
                ByteArray(16) { 0x11 }
            )
        )
    }
}
