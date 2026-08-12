package com.skybridge.compass.core.webrtc

import java.io.File
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
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

    @Test
    fun currentPathWebSocketCredentials_useHeaderSessionToken() {
        val url = SkyBridgeWebRtcConnectionManager.currentPathSignalingUrlWithShard(
            baseUrl = "wss://api.nebula-technologies.net/ws?st=legacy&ST=legacyUpper&sessionToken=secret&foo=bar",
            shard = "abc12345",
            clientVersion = "1.2.3",
            protocolVersion = "2"
        )
        assertTrue(url.startsWith("wss://api.nebula-technologies.net/ws?"))
        assertTrue(url.contains("shard=ABC12345"))
        assertTrue(url.contains("cv=1.2.3"))
        assertTrue(url.contains("pv=2"))
        assertTrue(url.contains("foo=bar"))
        assertTrue("session token must not be carried in the WebSocket URL", !url.contains("st="))
        assertTrue("uppercase session token query must not be carried in the WebSocket URL", !url.contains("ST="))
        assertTrue("session token query must not be carried in the WebSocket URL", !url.contains("sessionToken="))
        assertTrue("session token value must not leak into the WebSocket URL", !url.contains("legacy"))
        assertTrue("uppercase session token value must not leak into the WebSocket URL", !url.contains("legacyUpper"))
        assertTrue("session token value must not leak into the WebSocket URL", !url.contains("secret"))

        val headers = SkyBridgeWebRtcConnectionManager.currentPathSignalingHeaders(
            sessionId = "abc12345",
            sessionToken = "session-token-secret",
            clientVersion = "1.2.3",
            protocolVersion = "2"
        )
        assertEquals("ABC12345", headers["X-SkyBridge-Session-Id"])
        assertEquals("session-token-secret", headers["X-SkyBridge-Session"])
        assertEquals("1.2.3", headers["X-SkyBridge-Client-Version"])
        assertEquals("2", headers["X-SkyBridge-Protocol-Version"])
    }

    @Test
    fun webSocketClientLogRedaction_removesSessionAndTokenMaterial() {
        val redactedUrl = WebSocketSignalingClient.redactedUrlString(
            "wss://api.nebula-technologies.net/ws?shard=ABC12345&st=legacy&sessionToken=secret&foo=bar"
        )
        assertTrue(redactedUrl.contains("shard=%3Credacted%3E"))
        assertTrue(redactedUrl.contains("st=%3Credacted%3E"))
        assertTrue(redactedUrl.contains("sessionToken=%3Credacted%3E"))
        assertTrue(redactedUrl.contains("foo=bar"))
        assertTrue(!redactedUrl.contains("ABC12345"))
        assertTrue(!redactedUrl.contains("legacy"))
        assertTrue(!redactedUrl.contains("secret"))

        val redactedFrame = WebSocketSignalingClient.sanitizeTextForLog(
            """{"sessionId":"ABC12345","authToken":"secret-token","payload":{"sdp":"v=0"}}"""
        )
        assertTrue(redactedFrame.contains(""""sessionId":"<redacted>""""))
        assertTrue(redactedFrame.contains(""""authToken":"<redacted>""""))
        assertTrue(redactedFrame.contains(""""sdp":"<redacted>""""))
        assertTrue(!redactedFrame.contains("ABC12345"))
        assertTrue(!redactedFrame.contains("secret-token"))
        assertTrue(!redactedFrame.contains("v=0"))

        val redactedText = WebSocketSignalingClient.sanitizeTextForLog(
            "server error token=secret-token sessionId=ABC12345 password=turn-pass credential=turn-cred Authorization: Bearer abc.def.ghi X-SkyBridge-Turn-Admission: turn-admission-secret X-API-Key: api-key-secret"
        )
        assertTrue(redactedText.contains("token=<redacted>"))
        assertTrue(redactedText.contains("sessionId=<redacted>"))
        assertTrue(redactedText.contains("password=<redacted>"))
        assertTrue(redactedText.contains("credential=<redacted>"))
        assertTrue(redactedText.contains("Bearer <redacted>"))
        assertTrue(redactedText.contains("X-SkyBridge-Turn-Admission: <redacted>"))
        assertTrue(redactedText.contains("X-API-Key: <redacted>"))
        assertTrue(!redactedText.contains("secret-token"))
        assertTrue(!redactedText.contains("ABC12345"))
        assertTrue(!redactedText.contains("turn-pass"))
        assertTrue(!redactedText.contains("turn-cred"))
        assertTrue(!redactedText.contains("abc.def.ghi"))
        assertTrue(!redactedText.contains("turn-admission-secret"))
        assertTrue(!redactedText.contains("api-key-secret"))

        val redactedCredentialJson = WebSocketSignalingClient.sanitizeTextForLog(
            """{"password":"turn-pass","credential":"turn-cred","xSkyBridgeTurnAdmission":"turn-token"}"""
        )
        assertTrue(redactedCredentialJson.contains(""""password":"<redacted>""""))
        assertTrue(redactedCredentialJson.contains(""""credential":"<redacted>""""))
        assertTrue(redactedCredentialJson.contains(""""xSkyBridgeTurnAdmission":"<redacted>""""))
        assertTrue(!redactedCredentialJson.contains("turn-pass"))
        assertTrue(!redactedCredentialJson.contains("turn-cred"))
        assertTrue(!redactedCredentialJson.contains("turn-token"))

        val payloadSummary = WebSocketSignalingClient.payloadSizeSummary(
            """{"payload":{"sdp":"v=0"}}"""
        )
        assertTrue(payloadSummary.startsWith("payloadBytes="))
        assertTrue(!payloadSummary.contains("v=0"))

        val headerSummary = WebSocketSignalingClient.redactedHeadersSummary(
            mapOf(
                "X-SkyBridge-Session-Id" to "ABC12345",
                "X-SkyBridge-Session" to "session-token-secret"
            )
        )
        assertTrue(headerSummary.contains("X-SkyBridge-Session-Id"))
        assertTrue(headerSummary.contains("X-SkyBridge-Session"))
        assertTrue(!headerSummary.contains("ABC12345"))
        assertTrue(!headerSummary.contains("session-token-secret"))

        assertEquals("<redacted>", WebSocketSignalingClient.redactIdentifierForLog("peer-device-raw-id"))
        assertEquals("-", WebSocketSignalingClient.redactIdentifierForLog(" "))
    }

    @Test
    fun webSocketClientLogTemplates_doNotEmitRawPeerIdentifiers() {
        val sourceFile = listOf(
            File("core/src/main/kotlin/com/skybridge/compass/core/webrtc/WebSocketSignalingClient.kt"),
            File("src/main/kotlin/com/skybridge/compass/core/webrtc/WebSocketSignalingClient.kt")
        ).firstOrNull { it.isFile }
            ?: error("WebSocketSignalingClient source file not found from cwd=${File(".").absolutePath}")
        val source = sourceFile.readText()

        assertTrue(source.contains("""from=${'$'}{redactIdentifierForLog(inbound.value.from)}"""))
        assertTrue(source.contains("""to=${'$'}{inbound.value.to?.let(::redactIdentifierForLog) ?: "-"}"""))
        assertTrue(source.contains("""from=${'$'}{redactIdentifierForLog(envelope.from)}"""))
        assertTrue(source.contains("""to=${'$'}{envelope.to?.let(::redactIdentifierForLog) ?: "-"}"""))
        assertTrue(!source.contains("""from=${'$'}{inbound.value.from}"""))
        assertTrue(!source.contains("""to=${'$'}{inbound.value.to}"""))
        assertTrue(!source.contains("""from=${'$'}{envelope.from}"""))
        assertTrue(!source.contains("""to=${'$'}{envelope.to}"""))
    }

    @Test
    fun strictQPeriaptInitialHandshakeWaitsForJoinBootstrapKem() {
        val sourceFile = listOf(
            File("core/src/main/kotlin/com/skybridge/compass/core/webrtc/SkyBridgeWebRtcConnectionManager.kt"),
            File("src/main/kotlin/com/skybridge/compass/core/webrtc/SkyBridgeWebRtcConnectionManager.kt")
        ).firstOrNull { it.isFile }
            ?: error("SkyBridgeWebRtcConnectionManager source file not found from cwd=${File(".").absolutePath}")
        val source = sourceFile.readText()

        assertTrue(source.contains("awaitPeerKemForInitialHandshake(owner, peerId, policy)"))
        assertTrue(source.contains("if (!sessionOwnerGate.isCurrent(owner)) return null"))
        assertTrue(source.contains("policy.minimumTierRaw != P2PQPeriaptKem.MINIMUM_TIER_RAW"))
        assertTrue(source.contains("keys.qPeriaptPublicKey != null"))
        assertTrue(source.contains("missing_qperiapt_join_bootstrap"))
        assertTrue(source.contains("qPeriaptJoinBootstrapWaitTimeoutMs"))
        assertTrue(source.contains("qPeriaptJoinBootstrapPollIntervalMs"))
    }

    @Test
    fun turnAdmissionFailuresPreserveSanitizedDiagnosticCause() {
        val source = skyBridgeWebRtcConnectionManagerSource()

        assertTrue(source.contains("""val safeReason = diagnosticErrorMessage(t, "turn admission failed")"""))
        assertTrue(source.contains("""lastEvent = "turn admission failed: ${'$'}safeReason""""))
        assertTrue(source.contains("""Log.e("SB-WEBRTC", "turn admission failure reason=${'$'}safeReason")"""))
        assertTrue(source.contains("""IllegalStateException("TURN credential admission failed: ${'$'}safeReason", t)"""))
    }

    @Test
    fun initialHandshakeFailureClosesSessionAndCannotPromoteFromFailedState() {
        val source = skyBridgeWebRtcConnectionManagerSource()

        assertTrue(source.contains("failCurrentSession(owner, safeMessage"))
        assertTrue(source.contains("private fun failCurrentSession("))
        assertTrue(source.contains("productSessionAuthorityStore?.markFailed(owner)"))
        assertTrue(source.contains("sessionOwnerGate.releaseIfCurrent(owner)"))
        assertTrue(source.contains("val cleanup = session?.close()"))
        assertTrue(source.contains("native cleanup incomplete"))
        assertTrue(source.contains("session = null"))
        assertTrue(source.contains("val shouldEstablish = when (phase)"))
        assertTrue(source.contains("HandshakePhase.INITIAL -> current is State.Connected"))
        assertTrue(source.contains("ignored established handshake for inactive session="))
        assertTrue(source.contains("if (!shouldEstablish) {"))
        assertTrue(!source.contains("phase == HandshakePhase.INITIAL ||"))
    }

    @Test
    fun signalServerCurrentPathAdmissionAndErrors_failClosedWithoutSensitiveEcho() {
        val client = SignalServerClient()

        assertTrue(client.shouldUseAdmissionForBaseUrl("https://api.nebula-technologies.net"))
        assertTrue(client.shouldUseAdmissionForBaseUrl("https://signal.example.com"))
        assertTrue(!client.shouldUseAdmissionForBaseUrl("http://10.0.2.2:18443"))
        assertTrue(!client.shouldUseAdmissionForBaseUrl("http://127.0.0.1:18443"))
        assertTrue(!client.shouldUseAdmissionForBaseUrl("http://192.168.1.20:18443"))
        assertTrue(!client.shouldUseAdmissionForBaseUrl("http://skybridge.local:18443"))
        assertTrue(
            client.shouldAttemptAdmissionForBaseUrl(
                baseUrl = "http://127.0.0.1:18443",
                authContext = SignalServerClient.UserAuthContext(
                    bearerToken = "test-token",
                    tenantId = "test-tenant"
                )
            )
        )
        assertTrue(
            !client.shouldAttemptAdmissionForBaseUrl(
                baseUrl = "http://127.0.0.1:18443",
                authContext = null
            )
        )
        assertTrue(
            client.shouldAttemptAdmissionForBaseUrl(
                baseUrl = "https://api.nebula-technologies.net",
                authContext = null
            )
        )

        val rejected = client.safeServerRejectionMessage(
            statusCode = 401,
            payload = """{"error":"auth_required","token":"secret-token","sessionId":"ABC12345"}"""
        )
        assertEquals("signal server rejected (401, error=auth_required)", rejected)
        assertTrue(!rejected.contains("secret-token"))
        assertTrue(!rejected.contains("ABC12345"))

        val malformed = client.safeServerRejectionMessage(
            statusCode = 500,
            payload = """{"error":"bad error with spaces","token":"secret-token"}"""
        )
        assertEquals("signal server rejected (500)", malformed)
        assertTrue(!malformed.contains("secret-token"))
    }

    @Test
    fun legacySignalEndpoints_failClosedOnPublicBaseUrls() {
        val binding = ProtocolIdentityBinding(
            deviceId = "12345678-1234-1234-1234-1234567890ab",
            protocolSigningAlgorithm = ProtocolSigningAlgorithm.ED25519,
            protocolPublicKeyBytes = ByteArray(32) { 0x11 }
        )
        val client = SignalServerClient(
            baseUrlProvider = { "https://api.nebula-technologies.net" }
        )

        assertThrows(IllegalStateException::class.java) {
            runBlocking {
                client.registerConnectionCode(
                    binding = binding,
                    deviceName = "SkyBridge Android",
                    validDurationSeconds = 600
                )
            }
        }.also { error ->
            assertEquals(
                "registerConnectionCode requires current-path admission on public signaling endpoint",
                error.message
            )
        }

        assertThrows(IllegalStateException::class.java) {
            runBlocking {
                client.lookupConnectionCode(
                    code = "ABCDEFGH",
                    binding = binding
                )
            }
        }.also { error ->
            assertEquals(
                "lookupConnectionCode requires current-path admission on public signaling endpoint",
                error.message
            )
        }
    }

    @Test
    fun legacySignalEndpoints_failClosedOnPublicBaseUrlsEvenInDebugBuild() {
        val binding = testBinding()
        val client = SignalServerClient(
            baseUrlProvider = { "https://api.nebula-technologies.net" },
            isDebugBuildProvider = { true }
        )

        // Public base URL must use current-path admission; the legacy direct path is
        // rejected before any request is sent, regardless of build type.
        assertThrows(IllegalStateException::class.java) {
            runBlocking {
                client.registerConnectionCode(
                    binding = binding,
                    deviceName = "SkyBridge Android",
                    validDurationSeconds = 600
                )
            }
        }.also { error ->
            assertEquals(
                "registerConnectionCode requires current-path admission on public signaling endpoint",
                error.message
            )
        }
    }

    @Test
    fun legacySignalEndpoints_failClosedOnPrivateHostWhenNotDebugBuild() {
        val binding = testBinding()
        val client = SignalServerClient(
            baseUrlProvider = { "http://127.0.0.1:18443" },
            isDebugBuildProvider = { false }
        )

        // Even a loopback diagnostic endpoint must fail closed on non-debug builds,
        // before any request is sent, and be classified as a path authentication failure.
        assertThrows(IllegalStateException::class.java) {
            runBlocking {
                client.registerConnectionCode(
                    binding = binding,
                    deviceName = "SkyBridge Android",
                    validDurationSeconds = 600
                )
            }
        }.also { error ->
            assertEquals(
                "registerConnectionCode legacy signaling path rejected: current-path authentication required",
                error.message
            )
        }

        assertThrows(IllegalStateException::class.java) {
            runBlocking {
                client.lookupConnectionCode(code = "ABCDEFGH", binding = binding)
            }
        }.also { error ->
            assertEquals(
                "lookupConnectionCode legacy signaling path rejected: current-path authentication required",
                error.message
            )
        }

        assertThrows(IllegalStateException::class.java) {
            runBlocking {
                client.redeemSession(
                    sessionId = "session-123",
                    qrBootstrapToken = "bootstrap-token",
                    binding = binding
                )
            }
        }.also { error ->
            assertEquals(
                "redeemSession legacy signaling path rejected: current-path authentication required",
                error.message
            )
        }
    }

    @Test
    fun legacyDiagnosticEndpointGate_allowsOnlyDebugBuildLocalPrivateRanges() {
        val debugClient = SignalServerClient(isDebugBuildProvider = { true })

        // Loopback + RFC1918 private + link-local + IPv6 loopback + fc00::/7 ULA are allowed in debug.
        assertTrue(debugClient.isLegacyDiagnosticEndpointAllowed("http://127.0.0.1:18443"))
        assertTrue(debugClient.isLegacyDiagnosticEndpointAllowed("http://127.5.6.7:18443"))
        assertTrue(debugClient.isLegacyDiagnosticEndpointAllowed("http://10.0.2.2:18443"))
        assertTrue(debugClient.isLegacyDiagnosticEndpointAllowed("http://172.16.4.9:18443"))
        assertTrue(debugClient.isLegacyDiagnosticEndpointAllowed("http://172.31.4.9:18443"))
        assertTrue(debugClient.isLegacyDiagnosticEndpointAllowed("http://192.168.1.20:18443"))
        assertTrue(debugClient.isLegacyDiagnosticEndpointAllowed("http://169.254.1.1:18443"))
        assertTrue(debugClient.isLegacyDiagnosticEndpointAllowed("http://[::1]:18443"))
        assertTrue(debugClient.isLegacyDiagnosticEndpointAllowed("http://[fc00::1]:18443"))
        assertTrue(debugClient.isLegacyDiagnosticEndpointAllowed("http://[fd12:3456::1]:18443"))

        // Public hosts and out-of-range hosts are never permitted, even in debug.
        assertTrue(!debugClient.isLegacyDiagnosticEndpointAllowed("https://api.nebula-technologies.net"))
        assertTrue(!debugClient.isLegacyDiagnosticEndpointAllowed("https://signal.example.com"))
        assertTrue(!debugClient.isLegacyDiagnosticEndpointAllowed("http://172.32.0.1:18443"))
        assertTrue(!debugClient.isLegacyDiagnosticEndpointAllowed("http://8.8.8.8:18443"))
        assertTrue(!debugClient.isLegacyDiagnosticEndpointAllowed("http://[2001:db8::1]:18443"))

        // Non-debug builds never permit the legacy diagnostic path.
        val releaseClient = SignalServerClient(isDebugBuildProvider = { false })
        assertTrue(!releaseClient.isLegacyDiagnosticEndpointAllowed("http://127.0.0.1:18443"))
        assertTrue(!releaseClient.isLegacyDiagnosticEndpointAllowed("http://192.168.1.20:18443"))
        assertTrue(!releaseClient.isLegacyDiagnosticEndpointAllowed("http://[fc00::1]:18443"))
    }

    @Test
    fun publicSignalingBaseUrl_usesCurrentPathAdmission() {
        val client = SignalServerClient(isDebugBuildProvider = { true })

        // Public base URLs are admission (current-path) endpoints, not legacy diagnostic ones.
        assertTrue(client.shouldUseAdmissionForBaseUrl("https://api.nebula-technologies.net"))
        assertTrue(client.shouldUseAdmissionForBaseUrl("https://signal.example.com"))
        assertTrue(!client.isLegacyDiagnosticEndpointAllowed("https://api.nebula-technologies.net"))

        // Loopback/private diagnostic endpoints do not force current-path admission.
        assertTrue(!client.shouldUseAdmissionForBaseUrl("http://127.0.0.1:18443"))
        assertTrue(!client.shouldUseAdmissionForBaseUrl("http://192.168.1.20:18443"))
    }

    private fun testBinding(): ProtocolIdentityBinding =
        ProtocolIdentityBinding(
            deviceId = "12345678-1234-1234-1234-1234567890ab",
            protocolSigningAlgorithm = ProtocolSigningAlgorithm.ED25519,
            protocolPublicKeyBytes = ByteArray(32) { 0x11 }
        )

    private fun skyBridgeWebRtcConnectionManagerSource(): String {
        val sourceFile = listOf(
            File("core/src/main/kotlin/com/skybridge/compass/core/webrtc/SkyBridgeWebRtcConnectionManager.kt"),
            File("src/main/kotlin/com/skybridge/compass/core/webrtc/SkyBridgeWebRtcConnectionManager.kt")
        ).firstOrNull { it.isFile }
            ?: error("SkyBridgeWebRtcConnectionManager source file not found from cwd=${File(".").absolutePath}")
        return sourceFile.readText()
    }
}
