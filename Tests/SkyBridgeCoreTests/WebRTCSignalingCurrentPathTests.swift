import Foundation
import Testing
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
        #expect(SignalServerClient.lookupCodePath(for: "ABCDEFGH") == "/api/webrtc/lookup/ABCDEFGH")

        let registerCodeBody = SignalServerClient.makeRegisterCodeRequestBody(
            deviceId: "INITIATOR-01",
            deviceName: "SkyBridge Mac",
            ttlSeconds: 600
        )
        let registerCodeJSON = try XCTJSON.decode(JSONEncoder().encode(registerCodeBody))
        #expect(registerCodeJSON["deviceId"] as? String == "INITIATOR-01")
        #expect(registerCodeJSON["deviceName"] as? String == "SkyBridge Mac")
        #expect(registerCodeJSON["ttlSeconds"] as? Int == 600)

        let registerCodeLease = try SignalServerClient.decodeRegisterCodeResponse(
            from: try JSONSerialization.data(
                withJSONObject: [
                    "code": "ABCDEFGH",
                    "sessionId": "ABCDEFGH",
                    "initiatorToken": "init-token",
                    "expiresIn": 600
                ],
                options: [.sortedKeys]
            )
        )
        #expect(registerCodeLease.code == "ABCDEFGH")
        #expect(registerCodeLease.sessionID == "ABCDEFGH")
        #expect(registerCodeLease.initiatorToken == "init-token")

        let lookup = try SignalServerClient.decodeLookupCodeResponse(
            from: try JSONSerialization.data(
                withJSONObject: [
                    "found": true,
                    "sessionId": "ABCDEFGH",
                    "responderToken": "resp-token",
                    "expiresIn": 540
                ],
                options: [.sortedKeys]
            )
        )
        #expect(lookup.sessionID == "ABCDEFGH")
        #expect(lookup.responderToken == "resp-token")

        let registerSessionBody = SignalServerClient.makeRegisterSessionRequestBody(
            sessionId: "session-123",
            deviceId: "INITIATOR-01",
            ttlSeconds: 300
        )
        let registerSessionJSON = try XCTJSON.decode(JSONEncoder().encode(registerSessionBody))
        #expect(registerSessionJSON["sessionId"] as? String == "session-123")
        #expect(registerSessionJSON["deviceId"] as? String == "INITIATOR-01")
        #expect(registerSessionJSON["ttlSeconds"] as? Int == 300)

        let sessionLease = try SignalServerClient.decodeRegisterSessionResponse(
            from: try JSONSerialization.data(
                withJSONObject: [
                    "sessionId": "session-123",
                    "signalingToken": "qr-token",
                    "expiresIn": 300
                ],
                options: [.sortedKeys]
            )
        )
        #expect(sessionLease.sessionID == "session-123")
        #expect(sessionLease.signalingToken == "qr-token")
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
