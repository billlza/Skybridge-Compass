import XCTest

final class ProtocolParityWireAnchorTests: XCTestCase {
    func testProtocolParityScriptCoversCoreWireShapes() throws {
        let script = try repositorySource("Scripts/check_protocol_parity.py")

        XCTAssertTrue(script.contains("AppMessage payload cases"))
        XCTAssertTrue(script.contains("Cross-network file-transfer operations"))
        XCTAssertTrue(script.contains("Remote-control secure envelope constants"))
        XCTAssertTrue(script.contains("Handshake identity algorithm bytes"))
        XCTAssertTrue(script.contains("WebRTC signaling payload fields"))
        XCTAssertTrue(script.contains("Remote SDP/ICE validator limits"))
        XCTAssertTrue(script.contains("Remote SDP/ICE fail-closed reasons"))
    }

    func testIOSAppMessageKeepsMacTextMessageWireCase() throws {
        let source = try repositorySource("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/Messaging/AppMessage.swift")

        XCTAssertTrue(source.contains("case textMessage(TextMessagePayload)"))
        XCTAssertTrue(source.contains("public struct TextMessagePayload: Codable, Sendable, Equatable"))
        XCTAssertTrue(source.contains("case textMessage"))
        XCTAssertTrue(source.contains("container.decode(TextMessagePayload.self, forKey: .textMessage)"))
        XCTAssertTrue(source.contains("LegacyAssociatedValueBox<TextMessagePayload>"))
        XCTAssertTrue(source.contains("case .textMessage(let payload):"))
        XCTAssertTrue(source.contains("container.encode(payload, forKey: .textMessage)"))
    }

    func testCurrentPathSessionLabelsRemainDiagnosticAndRedacted() throws {
        let macPolicy = try repositorySource(
            "Sources/SkyBridgeCore/RemoteConnection/WebRTC/CrossNetworkWebRTCSignalingPolicy.swift"
        )
        let iosPolicy = try repositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/RemoteConnection/WebRTC/CrossNetworkWebRTCSignalingPolicy.swift"
        )

        XCTAssertTrue(macPolicy.contains("internal static func publicSignalingSessionLabel"))
        XCTAssertTrue(iosPolicy.contains("nonisolated static func publicSignalingSessionLabel"))
        XCTAssertTrue(
            macPolicy.contains("return \"present\""),
            "macOS keeps the public label as a presence-only diagnostic value."
        )
        XCTAssertTrue(
            iosPolicy.contains("return SkyBridgeTraceRedaction.stableReference(sessionId)"),
            "iOS may emit a stable diagnostic reference, but it must not expose the raw session id."
        )
        XCTAssertFalse(macPolicy.contains("return sessionID"))
        XCTAssertFalse(iosPolicy.contains("return sessionId"))
    }

    private func repositorySource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
