package com.skybridge.compass.android.remote.mac

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class RemoteControlWireTest {

    private val json = Json {
        ignoreUnknownKeys = true
        explicitNulls = false
    }

    @Test
    fun streamConfiguration_serializesWithAppleCompatibleTag() {
        val payload = RemoteDesktopStreamConfiguration(
            preferredCodec = "jpeg",
            supportedVideoFormats = listOf("jpeg"),
            targetFrameRate = 20,
            keyFrameInterval = 30,
            lowLatencyMode = false,
            enableHardwareAcceleration = false,
            enableAppleSiliconOptimization = false,
            clipboardSyncEnabled = false,
            sentAt = 1.0
        )
        val message = RemoteMessage(
            type = RemoteMessage.MessageType.STREAM_CONFIGURATION,
            payload = json.encodeToString(
                RemoteDesktopStreamConfiguration.serializer(),
                payload
            ).encodeToByteArray()
        )

        val encoded = json.encodeToString(RemoteMessage.serializer(), message)

        assertTrue(encoded.contains("streamConfiguration"))

        val decoded = json.decodeFromString(RemoteMessage.serializer(), encoded)
        assertEquals(RemoteMessage.MessageType.STREAM_CONFIGURATION, decoded.type)
        val decodedPayload = json.decodeFromString(
            RemoteDesktopStreamConfiguration.serializer(),
            decoded.payload.decodeToString()
        )
        assertEquals(listOf("jpeg"), decodedPayload.supportedVideoFormats)
    }
}
