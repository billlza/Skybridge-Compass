import XCTest

final class AuthenticatedChannelFailurePolicyTests: XCTestCase {
    func testMacAuthenticatedP2PFramesFailClosed() throws {
        let source = try repositorySource(
            "Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift"
        )

        XCTAssertTrue(source.contains("let msg = try JSONDecoder().decode(AppMessage.self, from: plaintext)"))
        XCTAssertTrue(source.contains("authenticated-channel-failed reason=invalid_app_frame"))
        XCTAssertTrue(source.contains("connection.cancel()"))
        XCTAssertFalse(source.contains("业务消息解密/解析失败（忽略）"))
    }

    func testIOSAuthenticatedP2PFramesFailClosedOffMainActor() throws {
        let source = try repositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )

        XCTAssertTrue(source.contains("try await Task.detached(priority: .userInitiated)"))
        XCTAssertTrue(source.contains("AES.GCM.open(sealedBox, using: key)"))
        XCTAssertTrue(source.contains("cleanupBrokenInboundConnection(connection, peerId: peerId, reason: reason)"))
        XCTAssertFalse(source.contains("无法解析业务消息（忽略）"))
    }

    func testIOSAuthenticatedWebRTCFramesCannotFallThroughAfterAEADFailure() throws {
        let source = try repositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/CrossNetworkWebRTCManager.swift"
        )

        XCTAssertTrue(source.contains("reason: \"authenticated_decryption_failed\""))
        XCTAssertTrue(source.contains("reason: \"invalid_authenticated_payload\""))
        XCTAssertTrue(source.contains("await disconnectInternal("))
        XCTAssertTrue(source.contains("clearSnapshot: true"))
        XCTAssertTrue(source.contains("originatingReceiveLoop: originatingReceiveLoop"))
        XCTAssertFalse(source.contains("// Fall through into handshake-control handling."))
    }

    func testMacSignalingFailuresCannotRestoreFalseHealthyState() throws {
        let source = try repositorySource(
            "Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift"
        )

        XCTAssertFalse(source.contains("signalingHealth = handshakeComplete ? .degradedRecoverable : .healthy"))
        XCTAssertTrue(source.contains("reason: \"missing_signaling_authorization\""))
        XCTAssertTrue(source.contains("reason: \"signaling_send_failed\""))
        XCTAssertTrue(source.contains("signalingHealth = .degradedFatal"))
    }

    private func repositorySource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
