package com.skybridge.compass.core.p2p

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AppMessageCodecTest {

    private val codec = AppMessageCodec()

    @Test
    fun pairingIdentityExchange_roundTripsRemoteVideoFormats() {
        val message = AppMessage.PairingIdentityExchange(
            AppMessage.PairingIdentityExchangePayload(
                deviceId = "android-device",
                kemPublicKeys = emptyList(),
                deviceName = "Pixel",
                platform = "android",
                osVersion = "Android 16",
                remoteVideoFormats = listOf("jpeg"),
                sentAt = 1234.5
            )
        )

        val encoded = codec.encode(message)
        val decoded = codec.decode(encoded)

        assertTrue(decoded is AppMessage.PairingIdentityExchange)
        val payload = (decoded as AppMessage.PairingIdentityExchange).payload
        assertEquals(listOf("jpeg"), payload.remoteVideoFormats)
        assertEquals("android-device", payload.deviceId)
    }

    @Test
    fun decode_ignoresAppleHeartbeatRemoteVideoFormats() {
        val json = """
            {"heartbeat":{"sentAt":42.0,"deviceId":"peer-1","remoteVideoFormats":["jpeg","h264"]}}
        """.trimIndent()

        val decoded = codec.decode(json.encodeToByteArray())

        assertNotNull(decoded)
        assertTrue(decoded is AppMessage.Heartbeat)
        val payload = (decoded as AppMessage.Heartbeat).payload
        assertEquals(listOf("jpeg", "h264"), payload.remoteVideoFormats)
    }
}
