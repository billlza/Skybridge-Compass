package com.skybridge.compass.android.remote.mac

import com.skybridge.compass.remotecontrol.secure.RemoteControlSecureEnvelope
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64
import java.util.UUID

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
            streamConfigurationTransaction = RemoteDesktopStreamConfigurationTransaction(
                UUID.fromString("550e8400-e29b-41d4-a716-446655440000")
            ),
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
        assertEquals(
            UUID.fromString("550e8400-e29b-41d4-a716-446655440000"),
            decodedPayload.streamConfigurationTransaction?.id
        )
    }

    @Test
    fun streamConfiguration_carriesQualityPresetAndCompressionLevel() {
        val payload = RemoteDesktopStreamConfiguration(
            preferredCodec = "hevc",
            supportedVideoFormats = listOf("hevc", "h264", "jpeg"),
            qualityPreset = "geek4k120",
            videoCompressionLevel = 70,
            width = 3840,
            height = 2160,
            adaptiveResolutionEnabled = false,
            targetFrameRate = 120,
            keyFrameInterval = 60,
            lowLatencyMode = true,
            enableHardwareAcceleration = true,
            enableAppleSiliconOptimization = false,
            clipboardSyncEnabled = true,
            damageTrackingEnabled = true,
            refreshStrategy = "instant",
            jitterBufferFrames = 1,
            lossRecoveryMode = "fast-retransmit",
            sentAt = 2.0
        )
        val encoded = json.encodeToString(RemoteDesktopStreamConfiguration.serializer(), payload)
        assertTrue(encoded.contains("geek4k120"))
        assertTrue(encoded.contains("videoCompressionLevel"))

        val decoded = json.decodeFromString(RemoteDesktopStreamConfiguration.serializer(), encoded)
        assertEquals("geek4k120", decoded.qualityPreset)
        assertEquals(70, decoded.videoCompressionLevel)
        assertEquals(3840, decoded.width)
        assertEquals(true, decoded.clipboardSyncEnabled)
        assertEquals(false, decoded.adaptiveResolutionEnabled)
    }

    @Test
    fun streamConfiguration_carriesRemoteControlSecurityIdentity() {
        val payload = RemoteDesktopStreamConfiguration(
            preferredCodec = "jpeg",
            supportedVideoFormats = listOf("jpeg"),
            targetFrameRate = 20,
            keyFrameInterval = 30,
            lowLatencyMode = false,
            enableHardwareAcceleration = false,
            enableAppleSiliconOptimization = false,
            clipboardSyncEnabled = false,
            remoteControlSecurityIdentity = RemoteControlSecurityIdentity(
                accountDisplayName = "SkyBridge Android LAN Smoke",
                nebulaId = "NEBULA-2026-ABCDEF123456",
                deviceId = "android-device-1",
                deviceName = "Pixel"
            ),
            sentAt = 3.0
        )

        val encoded = json.encodeToString(RemoteDesktopStreamConfiguration.serializer(), payload)

        assertTrue(encoded.contains("remoteControlSecurityIdentity"))
        val decoded = json.decodeFromString(RemoteDesktopStreamConfiguration.serializer(), encoded)
        assertEquals("SkyBridge Android LAN Smoke", decoded.remoteControlSecurityIdentity?.accountDisplayName)
        assertEquals("NEBULA-2026-ABCDEF123456", decoded.remoteControlSecurityIdentity?.nebulaId)
        assertEquals("android-device-1", decoded.remoteControlSecurityIdentity?.deviceId)
        assertEquals("Pixel", decoded.remoteControlSecurityIdentity?.deviceName)
    }

    @Test
    fun streamConfigurationTransactionAndAcknowledgement_matchAppleGoldenJson() {
        val transaction = RemoteDesktopStreamConfigurationTransaction(
            id = UUID.fromString("550e8400-e29b-41d4-a716-446655440000")
        )
        val acknowledgement = RemoteDesktopStreamConfigurationAcknowledgement(
            acceptedAt = 1.75,
            transaction = transaction,
            streamRefreshToken = null,
            audioEndpointPresent = false,
            screenFrameTransport = null
        )
        val acknowledgementJson = json.encodeToString(
            RemoteDesktopStreamConfigurationAcknowledgement.serializer(),
            acknowledgement
        )
        assertEquals(
            """{"acceptedAt":1.75,"transaction":{"id":"550E8400-E29B-41D4-A716-446655440000"},"audioEndpointPresent":false}""",
            acknowledgementJson
        )

        val messageJson = json.encodeToString(
            RemoteMessage.serializer(),
            RemoteMessage(
                type = RemoteMessage.MessageType.STREAM_CONFIGURATION_ACK,
                payload = acknowledgementJson.encodeToByteArray()
            )
        )
        val expectedBase64 = Base64.getEncoder()
            .encodeToString(acknowledgementJson.encodeToByteArray())
        assertEquals(
            """{"type":"streamConfigurationAck","payload":"$expectedBase64"}""",
            messageJson
        )
    }

    @Test
    fun acknowledgementDecoder_acceptsFoundationUppercaseUuidAndRejectsMissingTransaction() {
        val valid = RemoteMessage(
            type = RemoteMessage.MessageType.STREAM_CONFIGURATION_ACK,
            payload = """{"acceptedAt":10.0,"transaction":{"id":"550E8400-E29B-41D4-A716-446655440000"},"audioEndpointPresent":false}"""
                .encodeToByteArray()
        )
        val decoded = RemoteControlWireCodec.decodeStreamConfigurationAcknowledgement(valid)
        assertEquals(UUID.fromString("550e8400-e29b-41d4-a716-446655440000"), decoded.transaction.id)

        val maximumRefreshToken = valid.copy(
            payload = """{"acceptedAt":10.0,"transaction":{"id":"550E8400-E29B-41D4-A716-446655440000"},"streamRefreshToken":18446744073709551615,"audioEndpointPresent":false}"""
                .encodeToByteArray()
        )
        assertEquals(
            ULong.MAX_VALUE,
            RemoteControlWireCodec.decodeStreamConfigurationAcknowledgement(maximumRefreshToken)
                .streamRefreshToken
        )

        val missingTransaction = valid.copy(
            payload = """{"acceptedAt":10.0,"audioEndpointPresent":false}""".encodeToByteArray()
        )
        assertThrows(Exception::class.java) {
            RemoteControlWireCodec.decodeStreamConfigurationAcknowledgement(missingTransaction)
        }
    }

    @Test
    fun acknowledgementDecoder_rejectsNonCanonicalUuidAndInvalidMetadata() {
        val nonCanonicalUuid = RemoteMessage(
            type = RemoteMessage.MessageType.STREAM_CONFIGURATION_ACK,
            payload = """{"acceptedAt":10.0,"transaction":{"id":"1-1-1-1-1"},"audioEndpointPresent":false}"""
                .encodeToByteArray()
        )
        assertThrows(Exception::class.java) {
            RemoteControlWireCodec.decodeStreamConfigurationAcknowledgement(nonCanonicalUuid)
        }

        val unknownField = nonCanonicalUuid.copy(
            payload = """{"acceptedAt":10.0,"transaction":{"id":"550E8400-E29B-41D4-A716-446655440000"},"audioEndpointPresent":false,"unversionedExtension":true}"""
                .encodeToByteArray()
        )
        assertThrows(Exception::class.java) {
            RemoteControlWireCodec.decodeStreamConfigurationAcknowledgement(unknownField)
        }

        assertThrows(IllegalArgumentException::class.java) {
            RemoteDesktopStreamConfigurationAcknowledgement(
                acceptedAt = Double.NaN,
                transaction = RemoteDesktopStreamConfigurationTransaction.fresh(),
                audioEndpointPresent = false
            )
        }
        val negativeRefreshToken = nonCanonicalUuid.copy(
            payload = """{"acceptedAt":10.0,"transaction":{"id":"550E8400-E29B-41D4-A716-446655440000"},"streamRefreshToken":-1,"audioEndpointPresent":false}"""
                .encodeToByteArray()
        )
        assertThrows(Exception::class.java) {
            RemoteControlWireCodec.decodeStreamConfigurationAcknowledgement(negativeRefreshToken)
        }
    }

    @Test
    fun secureLegacyControlScreenDataFromResponder_decodesAsScreenFrame() {
        val receiveKey = ByteArray(32) { (it + 1).toByte() }
        val transcriptHash = ByteArray(32) { (it + 11).toByte() }
        val sessionId = RemoteControlSecureEnvelope.deterministicSessionId(transcriptHash)
        val screen = ScreenData(
            width = 1280,
            height = 720,
            imageData = byteArrayOf(0x01, 0x02, 0x03),
            timestamp = 42.0,
            format = "jpeg"
        )
        val message = RemoteMessage(
            type = RemoteMessage.MessageType.SCREEN_DATA,
            payload = json.encodeToString(ScreenData.serializer(), screen).encodeToByteArray()
        )
        val plaintext = RemoteControlWireCodec.encodeMessage(message)
        val packet = RemoteControlSecureEnvelope.seal(
            plaintext = plaintext,
            sendKey = receiveKey,
            role = RemoteControlSecureEnvelope.Role.RESPONDER,
            sessionId = sessionId,
            transcriptHash = transcriptHash,
            packetType = RemoteControlSecureEnvelope.PacketType.CONTROL,
            counter = 1
        )

        val opened = RemoteControlSecureEnvelope.open(
            packet = packet,
            receiveKey = receiveKey,
            role = RemoteControlSecureEnvelope.Role.INITIATOR,
            sessionId = sessionId,
            transcriptHash = transcriptHash,
            allowedPacketTypes = setOf(
                RemoteControlSecureEnvelope.PacketType.CONTROL,
                RemoteControlSecureEnvelope.PacketType.SCREEN
            )
        )
        val decodedMessage = RemoteControlWireCodec.decodeMessage(opened.payload)
        val decodedScreen = RemoteControlWireCodec.decodeScreenData(decodedMessage)

        assertEquals(RemoteControlSecureEnvelope.PacketType.CONTROL, opened.packetType)
        assertEquals(1280, decodedScreen.width)
        assertEquals(720, decodedScreen.height)
        assertEquals("jpeg", decodedScreen.format)
        assertEquals(listOf(1.toByte(), 2.toByte(), 3.toByte()), decodedScreen.imageData.toList())
    }

    @Test
    fun clipboardPayload_roundTripsWithBase64Data() {
        val text = "hello clipboard 你好"
        val payload = RemoteClipboardPayload(
            mimeType = "text/plain",
            data = text.encodeToByteArray(),
            sentAt = 1.5
        )
        val message = RemoteMessage(
            type = RemoteMessage.MessageType.CLIPBOARD,
            payload = json.encodeToString(RemoteClipboardPayload.serializer(), payload).encodeToByteArray()
        )

        val encoded = json.encodeToString(RemoteMessage.serializer(), message)
        assertTrue(encoded.contains("clipboard"))

        val decodedMsg = json.decodeFromString(RemoteMessage.serializer(), encoded)
        assertEquals(RemoteMessage.MessageType.CLIPBOARD, decodedMsg.type)
        val decoded = json.decodeFromString(
            RemoteClipboardPayload.serializer(),
            decodedMsg.payload.decodeToString()
        )
        assertEquals("text/plain", decoded.mimeType)
        assertEquals(text, decoded.data.decodeToString())
        assertEquals(1.5, decoded.sentAt, 0.0)
    }

    @Test
    fun wireCodec_rejectsMalformedRemoteMessage() {
        assertThrows(Exception::class.java) {
            RemoteControlWireCodec.decodeMessage("{not-json".encodeToByteArray())
        }
    }

    @Test
    fun wireCodec_rejectsEmptyScreenData() {
        val screen = ScreenData(
            width = 1920,
            height = 1080,
            imageData = ByteArray(0),
            timestamp = 3.0,
            format = "jpeg"
        )
        val message = RemoteMessage(
            type = RemoteMessage.MessageType.SCREEN_DATA,
            payload = json.encodeToString(ScreenData.serializer(), screen).encodeToByteArray()
        )

        assertThrows(IllegalArgumentException::class.java) {
            RemoteControlWireCodec.decodeScreenData(message)
        }
    }
}
