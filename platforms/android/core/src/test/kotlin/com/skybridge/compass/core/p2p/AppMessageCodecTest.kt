package com.skybridge.compass.core.p2p

import org.junit.Assert.assertEquals
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
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
                capabilities = listOf("remoteControl", "fileTransfer"),
                sentAt = 1234.5
            )
        )

        val encoded = codec.encode(message)
        val decoded = codec.decode(encoded)

        assertTrue(decoded is AppMessage.PairingIdentityExchange)
        val payload = (decoded as AppMessage.PairingIdentityExchange).payload
        assertEquals(listOf("jpeg"), payload.remoteVideoFormats)
        assertEquals(listOf("remoteControl", "fileTransfer"), payload.capabilities)
        assertEquals("android-device", payload.deviceId)
    }

    @Test
    fun pairingIdentityExchange_roundTripsBusinessMetadata() {
        val message = AppMessage.PairingIdentityExchange(
            AppMessage.PairingIdentityExchangePayload(
                deviceId = "android-device",
                kemPublicKeys = emptyList(),
                deviceName = "Pixel",
                platform = "Android",
                osVersion = "Android 16 (API 36)",
                remoteVideoFormats = listOf("hevc", "h264", "jpeg"),
                capabilities = listOf("webrtcMedia", "remoteControl", "clipboard", "fileTransfer"),
                sentAt = 1234.5,
                accountDisplayName = "Bill",
                nebulaId = "NEBULA-2026-ABCDEF123456"
            )
        )

        val encoded = codec.encode(message)
        val decoded = codec.decode(encoded)

        assertTrue(decoded is AppMessage.PairingIdentityExchange)
        val payload = (decoded as AppMessage.PairingIdentityExchange).payload
        assertEquals("Bill", payload.accountDisplayName)
        assertEquals("NEBULA-2026-ABCDEF123456", payload.nebulaId)
        assertEquals(listOf("webrtcMedia", "remoteControl", "clipboard", "fileTransfer"), payload.capabilities)
    }

    @Test
    fun decode_ignoresAppleHeartbeatRemoteVideoFormats() {
        val json = """
            {"heartbeat":{"sentAt":42.0,"deviceId":"peer-1","remoteVideoFormats":["jpeg","h264"],"accountDisplayName":"Alice","nebulaId":"NEBULA-2026-ZYXWVU987654","capabilities":["webrtcMedia"]}}
        """.trimIndent()

        val decoded = codec.decode(json.encodeToByteArray())

        assertNotNull(decoded)
        assertTrue(decoded is AppMessage.Heartbeat)
        val payload = (decoded as AppMessage.Heartbeat).payload
        assertEquals(listOf("jpeg", "h264"), payload.remoteVideoFormats)
        assertEquals("Alice", payload.accountDisplayName)
        assertEquals("NEBULA-2026-ZYXWVU987654", payload.nebulaId)
        assertEquals(listOf("webrtcMedia"), payload.capabilities)
    }

    @Test
    fun heartbeat_roundTripsBusinessMetadataAndCapabilities() {
        val message = AppMessage.Heartbeat(
            AppMessage.HeartbeatPayload(
                sentAt = 42.0,
                deviceId = "android-device",
                deviceName = "Pixel",
                platform = "Android",
                osVersion = "Android 16 (API 36)",
                remoteVideoFormats = listOf("jpeg", "h264"),
                capabilities = listOf("webrtcMedia", "remoteControl"),
                accountDisplayName = "Bill",
                nebulaId = "NEBULA-2026-ABCDEF123456"
            )
        )

        val decoded = codec.decode(codec.encode(message))

        assertTrue(decoded is AppMessage.Heartbeat)
        val payload = (decoded as AppMessage.Heartbeat).payload
        assertEquals("android-device", payload.deviceId)
        assertEquals("Bill", payload.accountDisplayName)
        assertEquals("NEBULA-2026-ABCDEF123456", payload.nebulaId)
        assertEquals(listOf("webrtcMedia", "remoteControl"), payload.capabilities)
        assertEquals(listOf("jpeg", "h264"), payload.remoteVideoFormats)
    }

    @Test
    fun authenticatedRouteBinding_roundTripsWireContract() {
        val message = AppMessage.AuthenticatedRouteBinding(
            AppMessage.AuthenticatedRouteBindingPayload(
                kind = "fileTransfer",
                serviceType = "_skybridge-transfer._tcp",
                instanceName = "Desk Mac._skybridge-transfer._tcp.local",
                hostName = "desk-mac.local",
                port = 9443,
                endpointProvenance = "resolved-dns-sd-endpoint",
                localDeviceId = "android-device",
                remoteDeviceId = "mac-device",
                routeAuthorityProtocolPublicKeyFingerprint = "a".repeat(64),
                remoteProtocolPublicKeyFingerprint = "a".repeat(64),
                sessionHashHex = "0123456789abcdef",
                transcriptPrefixHex = "fedcba9876543210",
                sentAt = 42.0,
                expiresAt = 72.0,
                nonce = routeBindingNonce()
            )
        )

        val encoded = codec.encode(message)
        val decoded = codec.decodeAuthenticatedControl(encoded)

        assertTrue(decoded is AppMessageCodec.DecodeResult.Known)
        val app = (decoded as AppMessageCodec.DecodeResult.Known).message
        assertTrue(app is AppMessage.AuthenticatedRouteBinding)
        val payload = (app as AppMessage.AuthenticatedRouteBinding).payload
        assertEquals("fileTransfer", payload.kind)
        assertEquals("_skybridge-transfer._tcp", payload.serviceType)
        assertEquals("desk-mac.local", payload.hostName)
        assertEquals(9443, payload.port)
        assertEquals("resolved-dns-sd-endpoint", payload.endpointProvenance)
        assertEquals("a".repeat(64), payload.routeAuthorityProtocolPublicKeyFingerprint)
        assertEquals("a".repeat(64), payload.remoteProtocolPublicKeyFingerprint)
        assertEquals("0123456789abcdef", payload.sessionHashHex)
        assertEquals("fedcba9876543210", payload.transcriptPrefixHex)
        assertArrayEquals(routeBindingNonce(), payload.nonce)
    }

    @Test
    fun decodeAppleAuthenticatedRouteBindingPayload() {
        val json = """
            {"authenticatedRouteBinding":{"version":1,"kind":"remoteDesktop","serviceType":"_skybridge-remote._tcp","instanceName":"Desk Mac._skybridge-remote._tcp.local","hostName":"desk-mac.local","port":5901,"endpointProvenance":"resolved-dns-sd-endpoint","localDeviceId":"mac-device","remoteDeviceId":"android-device","routeAuthorityProtocolPublicKeyFingerprint":"${"b".repeat(64)}","remoteProtocolPublicKeyFingerprint":"${"b".repeat(64)}","sessionHashHex":"1111111111111111","transcriptPrefixHex":"2222222222222222","sentAt":42.0,"expiresAt":72.0,"nonce":"AQIDBAUGBwgJCgsMDQ4PEA=="}}
        """.trimIndent()

        val decoded = codec.decodeAuthenticatedControl(json.encodeToByteArray())

        assertTrue(decoded is AppMessageCodec.DecodeResult.Known)
        val app = (decoded as AppMessageCodec.DecodeResult.Known).message
        assertTrue(app is AppMessage.AuthenticatedRouteBinding)
        val payload = (app as AppMessage.AuthenticatedRouteBinding).payload
        assertEquals("remoteDesktop", payload.kind)
        assertEquals("_skybridge-remote._tcp", payload.serviceType)
        assertEquals(5901, payload.port)
        assertArrayEquals(routeBindingNonce(), payload.nonce)
    }

    @Test
    fun decodeAuthenticatedRouteBindingRejectsShortNonce() {
        val json = """
            {"authenticatedRouteBinding":{"version":1,"kind":"remoteDesktop","serviceType":"_skybridge-remote._tcp","instanceName":"Desk Mac._skybridge-remote._tcp.local","hostName":"desk-mac.local","port":5901,"endpointProvenance":"resolved-dns-sd-endpoint","localDeviceId":"mac-device","remoteDeviceId":"android-device","routeAuthorityProtocolPublicKeyFingerprint":"${"b".repeat(64)}","remoteProtocolPublicKeyFingerprint":"${"b".repeat(64)}","sessionHashHex":"1111111111111111","transcriptPrefixHex":"2222222222222222","sentAt":42.0,"expiresAt":72.0,"nonce":"AQIDBA=="}}
        """.trimIndent()

        val error = assertThrows(AppMessageCodec.DecodeException::class.java) {
            codec.decodeAuthenticatedControl(json.encodeToByteArray())
        }
        assertEquals("authenticatedRouteBinding nonce must be at least 16 bytes", error.message)
    }

    @Test
    fun decodeAuthenticatedControlRejectsMalformedJsonAndAmbiguousTopLevelObjects() {
        assertThrows(AppMessageCodec.DecodeException::class.java) {
            codec.decodeAuthenticatedControl("""{"heartbeat":""".encodeToByteArray())
        }
        assertThrows(AppMessageCodec.DecodeException::class.java) {
            codec.decodeAuthenticatedControl(
                """{"ping":{"id":1},"pong":{"id":1}}""".encodeToByteArray()
            )
        }
    }

    @Test
    fun decodeAuthenticatedControlDistinguishesUnknownTypesFromMalformedPayloads() {
        val decoded = codec.decodeAuthenticatedControl("""{"futureControl":{"value":1}}""".encodeToByteArray())

        assertTrue(decoded is AppMessageCodec.DecodeResult.UnknownType)
        assertEquals("futureControl", (decoded as AppMessageCodec.DecodeResult.UnknownType).type)
        assertNull(codec.decode("""{"futureControl":{"value":1}}""".encodeToByteArray()))
    }

    private fun routeBindingNonce(): ByteArray =
        byteArrayOf(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16)
}
