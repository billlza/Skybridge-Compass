package com.skybridge.compass.core.webrtc

import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class SignalServerClientContractTest {

    private val json = Json {
        ignoreUnknownKeys = true
        explicitNulls = false
    }

    @Test
    fun signalServerClient_currentEndpointContractsStayStable() {
        assertEquals("/api/webrtc/admission/challenge", SignalServerClient.admissionChallengePath)
        assertEquals("/api/webrtc/admission", SignalServerClient.admissionPath)
        assertEquals("/api/webrtc/register-code", SignalServerClient.registerCodePath)
        assertEquals("/api/webrtc/register-session", SignalServerClient.registerSessionPath)
        assertEquals("/api/webrtc/redeem-session", SignalServerClient.redeemSessionPath)
        assertEquals("/api/webrtc/lookup/ABCDEFGH", SignalServerClient.lookupCodePath("ABCDEFGH"))

        val binding = ProtocolIdentityBinding(
            deviceId = "12345678-1234-1234-1234-1234567890ab",
            protocolSigningAlgorithm = ProtocolSigningAlgorithm.ED25519,
            protocolPublicKeyBytes = ByteArray(32) { 0x11 }
        )

        val registerCodeBody = SignalServerClient.makeRegisterCodeRequestBody(
            binding = binding,
            deviceName = "SkyBridge Android",
            ttlSeconds = 600
        )
        val registerCodeJson = json.parseToJsonElement(json.encodeToString(registerCodeBody)).jsonObject
        assertEquals(binding.deviceId, registerCodeJson.getValue("deviceId").jsonPrimitive.content)
        assertEquals("SkyBridge Android", registerCodeJson.getValue("deviceName").jsonPrimitive.content)
        assertEquals(
            ProtocolSigningAlgorithm.ED25519.rawValue,
            registerCodeJson.getValue("protocolSigningAlgorithm").jsonPrimitive.content
        )
        assertEquals(
            binding.protocolPublicKeyFingerprint,
            registerCodeJson.getValue("protocolPublicKeyFingerprint").jsonPrimitive.content
        )
        assertEquals(600, registerCodeJson.getValue("ttlSeconds").jsonPrimitive.int)

        val registerCodeLease = SignalServerClient.decodeRegisterCodeResponse(
            SignalServerClient.RegisterCodeResponseBody(
                code = "ABCDEFGH",
                sessionId = "ABCDEFGH",
                initiatorToken = "init-token",
                turnAdmissionToken = "turn-token",
                expiresIn = 600,
                signalingServerOrigin = "https://api.example.com"
            )
        )
        assertEquals("ABCDEFGH", registerCodeLease.code)
        assertEquals("ABCDEFGH", registerCodeLease.sessionId)
        assertEquals("init-token", registerCodeLease.initiatorToken)
        assertEquals("turn-token", registerCodeLease.turnAdmissionLease?.token)
        assertEquals("https://api.example.com", registerCodeLease.signalingServerOrigin)

        val lookup = SignalServerClient.decodeLookupCodeResponse(
            SignalServerClient.LookupCodeResponseBody(
                found = true,
                sessionId = "ABCDEFGH",
                responderToken = "resp-token",
                turnAdmissionToken = "turn-token",
                expiresIn = 540,
                signalingServerOrigin = "https://api.example.com",
                initiatorDeviceId = binding.deviceId,
                initiatorProtocolSigningAlgorithm = ProtocolSigningAlgorithm.ED25519,
                initiatorProtocolPublicKeyFingerprint = binding.protocolPublicKeyFingerprint,
                initiatorDeviceName = "SkyBridge Mac"
            )
        )
        assertEquals("ABCDEFGH", lookup.sessionId)
        assertEquals("resp-token", lookup.responderToken)
        assertEquals("turn-token", lookup.turnAdmissionLease?.token)
        assertEquals(binding.deviceId, lookup.initiatorDeviceId)
        assertEquals(binding.protocolPublicKeyFingerprint, lookup.initiatorProtocolPublicKeyFingerprint)

        val registerSessionBody = SignalServerClient.makeRegisterSessionRequestBody(
            sessionId = "session-123",
            binding = binding,
            ttlSeconds = 300
        )
        val registerSessionJson = json.parseToJsonElement(json.encodeToString(registerSessionBody)).jsonObject
        assertEquals("session-123", registerSessionJson.getValue("sessionId").jsonPrimitive.content)
        assertEquals(binding.deviceId, registerSessionJson.getValue("deviceId").jsonPrimitive.content)
        assertEquals(
            ProtocolSigningAlgorithm.ED25519.rawValue,
            registerSessionJson.getValue("protocolSigningAlgorithm").jsonPrimitive.content
        )
        assertEquals(
            binding.protocolPublicKeyFingerprint,
            registerSessionJson.getValue("protocolPublicKeyFingerprint").jsonPrimitive.content
        )
        assertEquals(300, registerSessionJson.getValue("ttlSeconds").jsonPrimitive.int)

        val sessionLease = SignalServerClient.decodeRegisterSessionResponse(
            SignalServerClient.RegisterSessionResponseBody(
                sessionId = "session-123",
                initiatorSignalingToken = "qr-token",
                qrBootstrapToken = "bootstrap-token",
                turnAdmissionToken = "turn-token",
                expiresIn = 300,
                signalingServerOrigin = "https://api.example.com"
            )
        )
        assertEquals("session-123", sessionLease.sessionId)
        assertEquals("qr-token", sessionLease.signalingToken)
        assertEquals("bootstrap-token", sessionLease.qrBootstrapToken)
        assertEquals("turn-token", sessionLease.turnAdmissionLease?.token)
        assertEquals("https://api.example.com", sessionLease.signalingServerOrigin)
    }

    @Test
    fun signalingEnvelope_preservesAuthToken() {
        val envelope = WebRtcSignalingEnvelope(
            sessionId = "session-123",
            from = "device-A",
            type = WebRtcSignalingEnvelope.MessageType.OFFER,
            payload = WebRtcSignalingEnvelope.Payload(sdp = "v=0"),
            authToken = "secure-token",
            sentAt = 1234.5
        )

        val decoded = json.decodeFromString(
            WebRtcSignalingEnvelope.serializer(),
            json.encodeToString(WebRtcSignalingEnvelope.serializer(), envelope)
        )

        assertEquals("secure-token", decoded.authToken)
        assertEquals("session-123", decoded.sessionId)
        assertEquals(WebRtcSignalingEnvelope.MessageType.OFFER, decoded.type)
    }

    @Test
    fun parseServerErrorFrame_recognizesServerErrors() {
        val raw = """{"type":"error","error":"room_full","sessionId":"ABCD1234"}"""
        when (val parsed = WebSocketSignalingClient.parseInboundText(raw)) {
            is WebSocketSignalingClient.InboundMessage.ServerFrame -> {
                assertEquals("error", parsed.value.type)
                assertEquals("room_full", parsed.value.error)
                assertEquals("ABCD1234", parsed.value.sessionId)
                assertTrue(parsed.value.isError)
            }

            else -> fail("Expected signaling server frame, got $parsed")
        }
    }
}
