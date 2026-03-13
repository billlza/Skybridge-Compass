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
                    "signalingServerOrigin": "https://api.example.com"
                ],
                options: [.sortedKeys]
            )
        )
        #expect(registerCodeLease.code == "ABCDEFGH")
        #expect(registerCodeLease.sessionID == "ABCDEFGH")
        #expect(registerCodeLease.initiatorToken == "init-token")
        #expect(registerCodeLease.signalingServerOrigin == "https://api.example.com")

        let lookup = try SignalServerClient.decodeLookupCodeResponse(
            from: try JSONSerialization.data(
                withJSONObject: [
                    "found": true,
                    "sessionId": "ABCDEFGH",
                    "responderToken": "resp-token",
                    "expiresIn": 540,
                    "signalingServerOrigin": "https://api.example.com",
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
                    "signalingServerOrigin": "https://api.example.com"
                ],
                options: [.sortedKeys]
            )
        )
        #expect(sessionLease.sessionID == "session-123")
        #expect(sessionLease.signalingToken == "qr-token")
        #expect(sessionLease.qrBootstrapToken == "bootstrap-token")
        #expect(sessionLease.signalingServerOrigin == "https://api.example.com")
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
