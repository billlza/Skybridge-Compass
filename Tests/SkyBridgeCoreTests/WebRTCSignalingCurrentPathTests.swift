import Foundation
import Testing
import SkyBridgeProtocolCore
@testable import SkyBridgeCore

@Suite("Current WebRTC signaling tests")
struct WebRTCSignalingCurrentPathTests {
    @Test("WebSocket 信令客户端会识别服务端 error frame")
    func parseServerErrorFrame() {
        let raw = #"{"type":"error","error":"room_full","sessionId":"ABCD1234"}"#
        let parsed = WebSocketSignalingClient.parseInboundText(raw)

        switch parsed {
        case .serverFrame(let frame):
            #expect(frame.type == "error")
            #expect(frame.error == "room_full")
            #expect(frame.sessionId == "ABCD1234")
            #expect(frame.isError)
        default:
            Issue.record("Expected signaling server frame, got \(parsed)")
        }
    }

    @Test("WebSocket 信令客户端会识别服务端 bound frame 并脱敏 URL")
    func parseBoundFrameAndRedactURL() {
        let raw = #"{"type":"bound","sessionId":"ROOM1234","role":"initiator","clientId":"client-1"}"#
        let parsed = WebSocketSignalingClient.parseInboundText(raw)

        switch parsed {
        case .serverFrame(let frame):
            #expect(frame.type == "bound")
            #expect(frame.sessionId == "ROOM1234")
            #expect(!frame.isError)
        default:
            Issue.record("Expected signaling bound frame, got \(parsed)")
        }

        let url = URL(string: "wss://api.example.com/ws?shard=ROOM1234&st=secret-token&cv=1.0&pv=1")!
        let redacted = WebSocketSignalingClient.redactedURLString(url)
        #expect(!redacted.contains("secret-token"))
        #expect(redacted.contains("st=%3Credacted%3E") || redacted.contains("st=<redacted>"))
    }

    @Test("SignalServerClient 的当前 WebRTC 端点与编解码逻辑保持稳定")
    func signalServerClientCurrentEndpointContracts() throws {
        #expect(SignalServerClient.registerCodePath == "/api/webrtc/register-code")
        #expect(SignalServerClient.registerSessionPath == "/api/webrtc/register-session")
        #expect(SignalServerClient.redeemSessionPath == "/api/webrtc/redeem-session")
        #expect(SignalServerClient.lookupCodePath(for: "ABCDEFGH") == "/api/webrtc/lookup/ABCDEFGH")

        let binding = try ProtocolIdentityBinding(
            deviceId: "12345678-1234-1234-1234-1234567890ab",
            protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyBytes: Data(repeating: 0x11, count: 32)
        )

        let registerCodeBody = SignalServerClient.makeRegisterCodeRequestBody(
            binding: binding,
            deviceName: "SkyBridge Mac",
            ttlSeconds: 600
        )
        let registerCodeJSON = try XCTJSON.decode(JSONEncoder().encode(registerCodeBody))
        #expect(registerCodeJSON["deviceId"] as? String == binding.deviceId)
        #expect(registerCodeJSON["deviceName"] as? String == "SkyBridge Mac")
        #expect(registerCodeJSON["protocolSigningAlgorithm"] as? String == ProtocolSigningAlgorithm.ed25519.rawValue)
        #expect(registerCodeJSON["protocolPublicKeyFingerprint"] as? String == binding.protocolPublicKeyFingerprint)
        #expect(registerCodeJSON["ttlSeconds"] as? Int == 600)

        let registerCodeLease = try SignalServerClient.decodeRegisterCodeResponse(
            from: try JSONSerialization.data(
                withJSONObject: [
                    "code": "ABCDEFGH",
                    "sessionId": "ABCDEFGH",
                    "initiatorToken": "init-token",
                    "expiresIn": 600,
                    "signalingServerOrigin": "https://api.example.com",
                    "wsPath": "/tenant/ws"
                ],
                options: [.sortedKeys]
            )
        )
        #expect(registerCodeLease.code == "ABCDEFGH")
        #expect(registerCodeLease.sessionID == "ABCDEFGH")
        #expect(registerCodeLease.initiatorToken == "init-token")
        #expect(registerCodeLease.signalingServerOrigin == "https://api.example.com")
        #expect(registerCodeLease.wsPath == "/tenant/ws")

        let lookup = try SignalServerClient.decodeLookupCodeResponse(
            from: try JSONSerialization.data(
                withJSONObject: [
                    "found": true,
                    "sessionId": "ABCDEFGH",
                    "responderToken": "resp-token",
                    "expiresIn": 540,
                    "signalingServerOrigin": "https://api.example.com",
                    "wsPath": "/tenant/ws",
                    "initiatorDeviceId": binding.deviceId,
                    "initiatorProtocolSigningAlgorithm": ProtocolSigningAlgorithm.ed25519.rawValue,
                    "initiatorProtocolPublicKeyFingerprint": binding.protocolPublicKeyFingerprint,
                    "initiatorDeviceName": "SkyBridge Mac"
                ],
                options: [.sortedKeys]
            )
        )
        #expect(lookup.sessionID == "ABCDEFGH")
        #expect(lookup.responderToken == "resp-token")
        #expect(lookup.wsPath == "/tenant/ws")
        #expect(lookup.initiatorDeviceId == binding.deviceId)
        #expect(lookup.initiatorProtocolPublicKeyFingerprint == binding.protocolPublicKeyFingerprint)

        let registerSessionBody = SignalServerClient.makeRegisterSessionRequestBody(
            sessionId: "session-123",
            binding: binding,
            ttlSeconds: 300
        )
        let registerSessionJSON = try XCTJSON.decode(JSONEncoder().encode(registerSessionBody))
        #expect(registerSessionJSON["sessionId"] as? String == "session-123")
        #expect(registerSessionJSON["deviceId"] as? String == binding.deviceId)
        #expect(registerSessionJSON["protocolSigningAlgorithm"] as? String == ProtocolSigningAlgorithm.ed25519.rawValue)
        #expect(registerSessionJSON["protocolPublicKeyFingerprint"] as? String == binding.protocolPublicKeyFingerprint)
        #expect(registerSessionJSON["ttlSeconds"] as? Int == 300)

        let sessionLease = try SignalServerClient.decodeRegisterSessionResponse(
            from: try JSONSerialization.data(
                withJSONObject: [
                    "sessionId": "session-123",
                    "initiatorSignalingToken": "qr-token",
                    "qrBootstrapToken": "bootstrap-token",
                    "expiresIn": 300,
                    "signalingServerOrigin": "https://api.example.com",
                    "wsPath": "/tenant/ws"
                ],
                options: [.sortedKeys]
            )
        )
        #expect(sessionLease.sessionID == "session-123")
        #expect(sessionLease.signalingToken == "qr-token")
        #expect(sessionLease.qrBootstrapToken == "bootstrap-token")
        #expect(sessionLease.signalingServerOrigin == "https://api.example.com")
        #expect(sessionLease.wsPath == "/tenant/ws")
    }

    @Test("Current-path WebSocket URL follows server origin and wsPath")
    func currentPathWebSocketURLFollowsLeaseEndpoint() throws {
        let url = try #require(CrossNetworkConnectionManager.currentPathSignalingWebSocketURL(
            signalingServerOrigin: "https://api.example.com",
            wsPath: "/tenant/ws",
            sessionID: "abc123",
            sessionToken: "token-1",
            clientVersion: "1.2.3",
            protocolVersion: "2"
        ))
        #expect(url.scheme == "wss")
        #expect(url.host == "api.example.com")
        #expect(url.path == "/tenant/ws")

        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })
        #expect(query["shard"] == "ABC123")
        #expect(query["st"] == "token-1")
        #expect(query["cv"] == "1.2.3")
        #expect(query["pv"] == "2")

        let defaultPathURL = CrossNetworkConnectionManager.currentPathSignalingWebSocketURL(
            signalingServerOrigin: "http://localhost:8787",
            wsPath: "bad?path",
            sessionID: "room",
            sessionToken: "token-2",
            clientVersion: "1.2.3",
            protocolVersion: "2"
        )
        #expect(defaultPathURL == nil)

        let missingPathURL = CrossNetworkConnectionManager.currentPathSignalingWebSocketURL(
            signalingServerOrigin: "http://localhost:8787",
            wsPath: nil,
            sessionID: "room",
            sessionToken: "token-2",
            clientVersion: "1.2.3",
            protocolVersion: "2"
        )
        #expect(missingPathURL == nil)
    }

    @Test("Current-path tooling does not synthesize /ws or config WebSocket fallbacks")
    func currentPathToolingDoesNotSynthesizeFallbackWebSocketRoutes() throws {
        let managerSource = try String(contentsOfFile: "Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift")
        #expect(!managerSource.contains("return \"/ws\""))
        #expect(!managerSource.contains("return URL(string: SkyBridgeServerConfig.signalingWebSocketURL)"))

        let probeSource = try String(contentsOfFile: "Sources/CurrentPathProbe/main.swift")
        #expect(!probeSource.contains("?? \"/ws\""))

        let serverSource = try String(contentsOfFile: "Server/skybridge-signaling/server.js")
        #expect(serverSource.contains("SIGNALING_WEBSOCKET_PATH"))
        #expect(!serverSource.contains("wsPath: '/ws'"))
        #expect(!serverSource.contains("path: '/ws'"))

        let localCompatServerSource = try String(contentsOfFile: "Server/skybridge-signaling/local_compat_server.js")
        #expect(localCompatServerSource.contains("SIGNALING_WEBSOCKET_PATH"))
        #expect(!localCompatServerSource.contains("wsPath: '/ws'"))
        #expect(!localCompatServerSource.contains("path: '/ws'"))
    }

    @Test("iOS QR redeem uses a stable idempotency key")
    func iOSQRCodeRedeemUsesStableIdempotencyKey() throws {
        let clientSource = try String(contentsOfFile: "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/RemoteConnection/WebRTC/CrossNetworkSignalServerClient.swift")
        #expect(clientSource.contains("\"Idempotency-Key\": normalizedIdempotencyKey"))
        #expect(clientSource.contains("case missingIdempotencyKey"))

        let managerSource = try String(contentsOfFile: "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/CrossNetworkWebRTCManager.swift")
        #expect(managerSource.contains(#"idempotencyKey: "qr-redeem-\(qr.sessionID)-\(localBinding.deviceId)""#))
    }

    @Test("macOS runtime signaling URL construction preserves endpoint errors")
    func macOSRuntimeSignalingURLConstructionPreservesEndpointErrors() throws {
        let managerSource = try String(contentsOfFile: "Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift")
        #expect(managerSource.contains("private func signalingWebSocketURL(shardKey: String? = nil) throws -> URL"))
        #expect(managerSource.contains("invalidSignalingEndpoint(\"missing current-path signaling origin\")"))
        #expect(managerSource.contains("invalidSignalingEndpoint(error.localizedDescription)"))
        #expect(managerSource.contains("let url = try signalingWebSocketURL(shardKey: sessionID)"))
    }

    @Test("Current-path artifacts validate endpoint before caching tokens")
    func currentPathArtifactsValidateEndpointBeforeCachingTokens() throws {
        let managerSource = try String(contentsOfFile: "Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift")

        assertEndpointValidationPrecedesTokenCaching(
            in: managerSource,
            sectionStart: "public func generateDynamicQRCode",
            sectionEnd: "public func scanDynamicQRCode",
            endpointVariable: "let signalingEndpoint = try validatedCurrentPathSignalingEndpoint(\n                origin: sessionLease.signalingServerOrigin,\n                wsPath: sessionLease.wsPath\n            )",
            tokenWrite: "webrtcSignalingAuthTokenBySessionId[sessionLease.sessionID] = sessionLease.sessionToken"
        )
        assertEndpointValidationPrecedesTokenCaching(
            in: managerSource,
            sectionStart: "public func scanDynamicQRCode",
            sectionEnd: "public func connectToCloudDevice",
            endpointVariable: "let signalingEndpoint = try validatedCurrentPathSignalingEndpoint(\n                origin: redeemed.signalingServerOrigin,\n                wsPath: redeemed.wsPath\n            )",
            tokenWrite: "webrtcSignalingAuthTokenBySessionId[qrData.sessionID] = redeemed.sessionToken"
        )
        assertEndpointValidationPrecedesTokenCaching(
            in: managerSource,
            sectionStart: "public func generateConnectionCode",
            sectionEnd: "private func scheduleConnectionCodeLeaseInvalidation",
            endpointVariable: "let signalingEndpoint = try validatedCurrentPathSignalingEndpoint(\n                origin: lease.signalingServerOrigin,\n                wsPath: lease.wsPath\n            )",
            tokenWrite: "webrtcSignalingAuthTokenBySessionId[lease.sessionID] = lease.sessionToken"
        )
        assertEndpointValidationPrecedesTokenCaching(
            in: managerSource,
            sectionStart: "public func connectWithCode",
            sectionEnd: "private func scanServerBackedQRCodeInvite",
            endpointVariable: "let signalingEndpoint = try validatedCurrentPathSignalingEndpoint(\n                origin: lookup.signalingServerOrigin,\n                wsPath: lookup.wsPath\n            )",
            tokenWrite: "webrtcSignalingAuthTokenBySessionId[lookup.sessionID] = lookup.sessionToken"
        )
        assertEndpointValidationPrecedesTokenCaching(
            in: managerSource,
            sectionStart: "private func scanServerBackedQRCodeInvite",
            sectionEnd: "private func establishP2PConnection",
            endpointVariable: "let signalingEndpoint = try validatedCurrentPathSignalingEndpoint(\n            origin: redeemed.signalingServerOrigin,\n            wsPath: redeemed.wsPath\n        )",
            tokenWrite: "webrtcSignalingAuthTokenBySessionId[invite.sessionID] = redeemed.sessionToken"
        )
    }

    @Test("WebRTC signaling envelope 保留 authToken 字段")
    func signalingEnvelopePreservesAuthToken() throws {
        let envelope = WebRTCSignalingEnvelope(
            sessionId: "session-123",
            from: "device-A",
            type: .offer,
            payload: .init(sdp: "v=0"),
            authToken: "secure-token"
        )

        let decoded = try JSONDecoder().decode(
            WebRTCSignalingEnvelope.self,
            from: JSONEncoder().encode(envelope)
        )

        #expect(decoded.authToken == "secure-token")
        #expect(decoded.sessionId == "session-123")
        #expect(decoded.type == .offer)
    }

    @Test("Control-plane client API key remains non-empty by default")
    func controlPlaneClientAPIKeyDefaultIsPresent() {
        #expect(!SkyBridgeServerConfig.clientAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

private func assertEndpointValidationPrecedesTokenCaching(
    in source: String,
    sectionStart: String,
    sectionEnd: String,
    endpointVariable: String,
    tokenWrite: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    guard let startRange = source.range(of: sectionStart),
          let endRange = source.range(of: sectionEnd, range: startRange.upperBound..<source.endIndex) else {
        Issue.record("Missing source section \(sectionStart)", sourceLocation: sourceLocation)
        return
    }
    let section = source[startRange.lowerBound..<endRange.lowerBound]
    guard let endpointRange = section.range(of: endpointVariable),
          let tokenRange = section.range(of: tokenWrite) else {
        Issue.record("Missing endpoint validation or token write in \(sectionStart)", sourceLocation: sourceLocation)
        return
    }
    #expect(endpointRange.lowerBound < tokenRange.lowerBound, sourceLocation: sourceLocation)
}

private enum XCTJSON {
    static func decode(_ data: Data?) throws -> [String: Any] {
        guard let data else { throw URLError(.cannotDecodeContentData) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotDecodeContentData)
        }
        return object
    }
}
