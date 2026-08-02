import XCTest

final class AuthenticatedChannelFailurePolicyTests: XCTestCase {
    func testMacAuthenticatedP2PFramesFailClosed() throws {
        let source = try repositorySource(
            "Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift"
        )

        XCTAssertTrue(source.contains("let msg = try AppMessage.decodeWireMessage(from: plaintext)"))
        XCTAssertTrue(source.contains("authenticated-channel-failed reason=invalid_app_frame"))
        XCTAssertTrue(source.contains("connection.cancel()"))
        XCTAssertFalse(source.contains("业务消息解密/解析失败（忽略）"))
    }

    func testP2PConnectionAuthenticatedFramesPropagateFailuresToReceiveLoop() throws {
        let source = try repositorySource(
            "Sources/SkyBridgeCore/P2P/P2PModels.swift"
        )

        XCTAssertTrue(source.contains("try await self.handleInboundFrame("))
        XCTAssertTrue(source.contains("private func handleInboundFrame("))
        XCTAssertTrue(source.contains("throw P2PConnectionError.unexpectedAuthenticatedHandshakeFrame"))
        XCTAssertTrue(source.contains("message = try AppMessage.decodeWireMessage(from: plaintext)"))
        XCTAssertTrue(source.contains("throw P2PConnectionError.invalidAuthenticatedPayload"))
        XCTAssertTrue(source.contains("try await handleAppMessage(\n            message,"))
        XCTAssertTrue(source.contains("authenticatedConversationFingerprint: authenticatedConversationFingerprint"))
        XCTAssertTrue(source.contains("private func conversationFingerprintForAuthenticatedFrame("))
        XCTAssertTrue(source.contains("current?.receiveKey == keys.receiveKey"))
        XCTAssertTrue(source.contains("authenticatedHandshakePeerBindingLock.withLock({ $0 })"))
        XCTAssertTrue(source.contains("private func handleAppMessage(\n        _ message: AppMessage,"))
        XCTAssertTrue(source.contains("authenticatedConversationFingerprint: String?"))
        XCTAssertTrue(source.contains("throw P2PConnectionError.authenticatedPongReplyFailed"))
        XCTAssertTrue(source.contains("authenticated pong reply failed; closing session"))
        XCTAssertTrue(source.contains("self.disconnectIfOwnedReceiveLease("))
        let exactCloseStart = try XCTUnwrap(
            source.range(of: "private func disconnectIfOwnedReceiveLease(")
        )
        let exactCloseEnd = try XCTUnwrap(
            source.range(
                of: "private func handleInboundFrame(",
                range: exactCloseStart.upperBound..<source.endIndex
            )
        )
        let exactClose = String(
            source[exactCloseStart.lowerBound..<exactCloseEnd.lowerBound]
        )
        XCTAssertTrue(exactClose.contains("state?.id == id"))
        XCTAssertTrue(exactClose.contains("state?.connectionGeneration == connectionGeneration"))
        XCTAssertTrue(exactClose.contains("$0.ownsConnectionGeneration(connectionGeneration)"))
        XCTAssertTrue(exactClose.contains("disconnect()"))

        XCTAssertFalse(source.contains("if let msg = try? JSONDecoder().decode"))
        XCTAssertFalse(source.contains("Best-effort: ignore reply failures"))
        XCTAssertFalse(source.contains("Best-effort: ignore frames that aren't business messages"))
        XCTAssertFalse(source.contains("rekey期间收到无法解析的业务帧（忽略）"))
        XCTAssertFalse(source.contains("if isLikelyHandshakeControlPacket(frame) { return }"))

        let envelopeDecode = try XCTUnwrap(
            source.range(of: "if let envelope = BusinessEnvelope.decode(plaintext)")
        )
        let envelopeReturn = try XCTUnwrap(
            source.range(of: "return", range: envelopeDecode.upperBound..<source.endIndex)
        )
        let appMessageDecode = try XCTUnwrap(
            source.range(
                of: "message = try AppMessage.decodeWireMessage(from: plaintext)",
                range: envelopeReturn.upperBound..<source.endIndex
            )
        )
        XCTAssertLessThan(envelopeReturn.lowerBound, appMessageDecode.lowerBound)
    }

    func testIOSAuthenticatedP2PFramesFailClosedOffMainActor() throws {
        let source = try repositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )

        XCTAssertTrue(source.contains("try await Task.detached(priority: .userInitiated)"))
        XCTAssertTrue(source.contains("AES.GCM.open(sealedBox, using: key)"))
        XCTAssertTrue(source.contains("return try AppMessage.decodeWireMessage(from: plaintext)"))
        XCTAssertTrue(source.contains("throw P2PError.unexpectedAuthenticatedHandshakeFrame"))
        XCTAssertTrue(source.contains("try await handleAppMessage(\n                    msg,\n                    from: peerId,"))
        XCTAssertTrue(source.contains("expectedReceipt: AuthenticatedConnectionReceipt("))
        XCTAssertTrue(source.contains("private func handleAppMessage(\n        _ message: AppMessage,\n        from peerId: String,\n        expectedReceipt: AuthenticatedConnectionReceipt"))
        XCTAssertTrue(source.contains("try requireCurrentAuthenticatedConnection(expectedReceipt)"))
        XCTAssertTrue(source.contains("try await replyPong(\n                to: peerId,\n                pingId: payload.id,\n                expectedReceipt: expectedReceipt"))
        XCTAssertTrue(source.contains("throw P2PError.authenticatedPongReplyFailed"))
        XCTAssertTrue(source.contains("authenticated pong reply failed; closing session"))
        XCTAssertTrue(source.contains("cleanupBrokenInboundConnection(connection, peerId: peerId, reason: reason)"))
        XCTAssertFalse(source.contains("无法解析业务消息（忽略）"))
        XCTAssertFalse(source.contains("收到握手控制包（忽略）"))
        XCTAssertFalse(source.contains("pong reply failed (ignored)"))
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

    func testProductionAppMessageWireBoundariesUseStrictRawJSONValidation() throws {
        let productionFiles = [
            "Sources/SkyBridgeCore/DeviceDiscovery/DeviceDiscoveryManager.swift",
            "Sources/SkyBridgeCore/DeviceDiscovery/DeviceDiscoveryManagerOptimized.swift",
            "Sources/SkyBridgeCore/P2P/P2PModels.swift",
            "Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift",
            "Sources/SkyBridgeCore/RemoteConnection/WebRTC/WebRTCControlChannelCodec.swift",
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift",
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/CrossNetworkWebRTCManager.swift",
        ]

        for file in productionFiles {
            let source = try repositorySource(file)
            XCTAssertFalse(
                source.contains("decode(AppMessage.self"),
                "Authenticated AppMessage bytes must pass raw duplicate-key validation: \(file)"
            )
        }
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
