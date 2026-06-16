import Foundation
import XCTest
@testable import SkyBridgeCore

final class P2PRedactionSourceContractTests: XCTestCase {
    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func readSource(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func assertSource(
        _ source: String,
        named sourceName: String,
        excludes forbiddenFragments: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for fragment in forbiddenFragments {
            XCTAssertFalse(
                source.contains(fragment),
                "\(sourceName) must not expose raw identifiers or raw error descriptions in public diagnostics: \(fragment)",
                file: file,
                line: line
            )
        }
    }

    func testDiagnosticRedactionHelperDoesNotCreateStableAliases() {
        XCTAssertEqual(SkyBridgeDiagnosticRedaction.stableIdentifierLabel("device-alpha"), "<redacted>")
        XCTAssertEqual(SkyBridgeDiagnosticRedaction.stableIdentifierLabel("device-beta"), "<redacted>")
        XCTAssertEqual(SkyBridgeDiagnosticRedaction.stableIdentifierLabel("  "), "<redacted>")
        XCTAssertEqual(SkyBridgeDiagnosticRedaction.stableIdentifierLabel(nil), "<redacted>")

        let error = NSError(domain: "SkyBridge.Test", code: 42)
        XCTAssertEqual(
            SkyBridgeDiagnosticRedaction.errorSummary(error),
            "error_domain=SkyBridge.Test code=42"
        )
    }

    func testP2PAndTrustSyncDiagnosticsRedactRawIdentifiersAndErrors() throws {
        let sources = [
            "Sources/SkyBridgeCore/P2P/P2PModels.swift",
            "Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift",
            "Sources/SkyBridgeCore/P2P/TrustSyncService.swift",
            "Sources/SkyBridgeCore/Diagnostics/DiscoveryDiagnosticsService.swift"
        ]

        for path in sources {
            let source = try readSource(path)
            XCTAssertTrue(
                source.contains("SkyBridgeDiagnosticRedaction"),
                "\(path) must use the shared redaction helper at public diagnostic boundaries."
            )
            assertSource(
                source,
                named: path,
                excludes: [
                    "error.localizedDescription, privacy: .public",
                    "handshakePeer.deviceId, privacy: .public",
                    "peer.deviceId, privacy: .public",
                    "payload.deviceId, privacy: .public",
                    "record.deviceId, privacy: .public",
                    "oldDeviceId, privacy: .public",
                    "newDeviceId, privacy: .public",
                    "endpoint.debugDescription, privacy: .public",
                    "endpointDescriptionForPresence, privacy: .public",
                    "String(describing: st)",
                    "String(describing: existingState)",
                    "String(describing: reason)"
                ]
            )
        }
    }

    func testHandshakeDiagnosticsUseReasonCodesAndStateSummaries() throws {
        let helper = try readSource("Sources/SkyBridgeCore/Common/SkyBridgeDiagnosticRedaction.swift")

        XCTAssertTrue(helper.contains("extension HandshakeFailureReason"))
        XCTAssertTrue(helper.contains("var diagnosticReasonCode: String"))
        XCTAssertTrue(helper.contains("return \"identity_mismatch\""))
        XCTAssertTrue(helper.contains("return \"superseded_by_concurrent_attempt\""))
        XCTAssertTrue(helper.contains("extension HandshakeState"))
        XCTAssertTrue(helper.contains("var diagnosticSummary: String"))
        XCTAssertFalse(helper.contains("SessionKeys("))
    }

    func testHandshakeSecurityEventsAndIOSFormatterRedactIdentityMaterial() throws {
        let coreDriver = try readSource("Sources/SkyBridgeCore/P2P/HandshakeDriver.swift")
        let coreTwoAttempt = try readSource("Sources/SkyBridgeCore/P2P/TwoAttemptHandshakeManager.swift")
        let iosFormatter = try readSource("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/Handshake/P2PHandshakeErrorFormatter.swift")
        let iosHandshakeTypes = try readSource("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/Handshake/HandshakeTypes.swift")
        let iosTwoAttempt = try readSource("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/Handshake/TwoAttemptHandshakeManager.swift")

        XCTAssertTrue(coreDriver.contains("SkyBridgeDiagnosticRedaction.stableIdentifierLabel(currentPeer?.deviceId)"))
        XCTAssertTrue(coreDriver.contains(#""reason": reason.diagnosticReasonCode"#))
        XCTAssertFalse(coreDriver.contains(#""peer": currentPeer?.deviceId ?? "unknown""#))
        XCTAssertFalse(coreDriver.contains(#""reason": String(describing: reason)"#))

        XCTAssertTrue(coreTwoAttempt.contains("SkyBridgeDiagnosticRedaction.stableIdentifierLabel(deviceId)"))
        XCTAssertTrue(coreTwoAttempt.contains("SkyBridgeDiagnosticRedaction.errorSummary(error)"))
        XCTAssertFalse(coreTwoAttempt.contains(#""deviceId": deviceId"#))
        XCTAssertFalse(coreTwoAttempt.contains(#""bridgeRetryError": error.localizedDescription"#))

        XCTAssertTrue(iosFormatter.contains("设备身份不匹配，连接已中止。请重新验证受信任设备后重试。"))
        XCTAssertFalse(iosFormatter.contains("期望连接到"))
        XCTAssertFalse(iosFormatter.contains("case .identityMismatch(let expected"))

        XCTAssertTrue(iosHandshakeTypes.contains("var diagnosticReasonCode: String"))
        XCTAssertTrue(iosHandshakeTypes.contains("return \"identity_mismatch\""))
        XCTAssertTrue(iosHandshakeTypes.contains("HandshakeDiagnosticRedaction"))
        XCTAssertFalse(iosHandshakeTypes.contains("winner=\\(winnerPeerId)"))
        XCTAssertFalse(iosHandshakeTypes.contains("实际 \\(actual)"))

        XCTAssertTrue(iosTwoAttempt.contains("HandshakeDiagnosticRedaction.stableIdentifierLabel(deviceId)"))
        XCTAssertTrue(iosTwoAttempt.contains("reason.diagnosticReasonCode"))
        XCTAssertFalse(iosTwoAttempt.contains(#""deviceId": deviceId"#))
        XCTAssertFalse(iosTwoAttempt.contains("String(describing: reason)"))
    }

    func testIOSP2PStatusLinesRedactRawIdentifiersAndLocalErrors() throws {
        let source = try readSource("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift")

        XCTAssertTrue(source.contains("private nonisolated static var protocolIdentityLogRedaction"))
        XCTAssertTrue(source.contains("private nonisolated static func diagnosticErrorSummary(_ error: Error)"))
        XCTAssertTrue(source.contains("error_domain=\\(nsError.domain) code=\\(nsError.code)"))

        let inboundStart = try XCTUnwrap(source.range(of: "private func makeInboundBootstrapControlResponse"))
        let inboundEnd = try XCTUnwrap(
            source.range(
                of: "private func makeInboundSignedKEMRefreshPayload",
                range: inboundStart.lowerBound..<source.endIndex
            )
        )
        let inboundStatusBuilder = String(source[inboundStart.lowerBound..<inboundEnd.lowerBound])

        XCTAssertTrue(inboundStatusBuilder.contains("SKR-1 signed LAN KEM refresh served"))
        XCTAssertTrue(inboundStatusBuilder.contains("SKR-1 signed LAN KEM refresh rejected"))
        XCTAssertTrue(inboundStatusBuilder.contains("reason: error.localizedDescription"))
        XCTAssertTrue(inboundStatusBuilder.contains("reason=%@ responderLatencyMs"))
        XCTAssertTrue(inboundStatusBuilder.contains("requestHashHex: request.canonicalRequestHashHex"))
        XCTAssertTrue(inboundStatusBuilder.contains("requesterDeviceId: request.requesterDeviceId"))
        XCTAssertTrue(inboundStatusBuilder.contains("targetDeviceId: request.targetDeviceId"))
        XCTAssertTrue(inboundStatusBuilder.contains("""
                    Self.protocolIdentityLogRedaction,
                    Self.protocolIdentityLogRedaction,
                    Self.protocolIdentityLogRedaction,
"""))
        XCTAssertTrue(inboundStatusBuilder.contains("""
                    Self.protocolIdentityLogRedaction,
                    Self.protocolIdentityLogRedaction,
                    failure.reasonCode,
                    Self.protocolIdentityLogRedaction,
"""))
        assertSource(
            inboundStatusBuilder,
            named: "iOS P2P inbound bootstrap status builder",
            excludes: [
                "                    payload.keyId,",
                "\n                    error.localizedDescription,\n"
            ]
        )

        let pairingStart = try XCTUnwrap(source.range(of: "public func resolvePairingTrustRequest"))
        let pairingEnd = try XCTUnwrap(
            source.range(
                of: "public func waitForPairingIdentityExchangeActivity",
                range: pairingStart.lowerBound..<source.endIndex
            )
        )
        let pairingDiagnostics = String(source[pairingStart.lowerBound..<pairingEnd.lowerBound])

        XCTAssertTrue(pairingDiagnostics.contains("peer=\\(Self.protocolIdentityLogRedaction)"))
        XCTAssertTrue(pairingDiagnostics.contains("declaredDeviceId=\\(Self.protocolIdentityLogRedaction)"))
        XCTAssertTrue(pairingDiagnostics.contains("deviceId: localId"))
        XCTAssertTrue(pairingDiagnostics.contains("await KEMTrustStore.shared.upsert(deviceId: declaredDeviceId"))
        assertSource(
            pairingDiagnostics,
            named: "iOS pairingIdentityExchange diagnostics",
            excludes: [
                "Pairing/trust request rejected: peer=\\(peerId)",
                "Pairing/trust request timed out: peer=\\(peerId)",
                "Pairing/trust request auto-rejected: peer=\\(peerId)",
                "UI prompt already pending; ignoring duplicate. peer=\\(peerId)",
                "忽略无效 pairingIdentityExchange: peer=\\(runtimePeerId)",
                "已保存对端 KEM 公钥：peer=\\(peerId) declaredDeviceId=\\(declaredDeviceId)",
                "已加入受信任设备：\\(device.name) peerId=\\(peerId)",
                "pairingIdentityExchange replied to peer=\\(peerId)",
                "pairingIdentityExchange reply failed (ignored): \\(error.localizedDescription)",
                "cleared stale rekey marker before pairingIdentityExchange: peer=\\(deviceId)",
                "pairingIdentityExchange delayed during active rekey: peer=\\(deviceId)",
                "pairingIdentityExchange sent: peer=\\(deviceId)"
            ]
        )

        let traceStart = try XCTUnwrap(source.range(of: "private func handleIncomingConnection"))
        let traceEnd = try XCTUnwrap(
            source.range(
                of: "private func isLikelyHandshakeControlPacket",
                range: traceStart.lowerBound..<source.endIndex
            )
        )
        let traceDiagnostics = String(source[traceStart.lowerBound..<traceEnd.lowerBound])
        XCTAssertTrue(source.contains("diagnosticConnectionState(_ state: NWConnection.State)"))
        XCTAssertTrue(source.contains("diagnosticHandshakeFailureCode(_ reason: HandshakeFailureReason)"))
        XCTAssertTrue(traceDiagnostics.contains("p2p-inbound handle-start peer=\\(Self.protocolIdentityLogRedaction)"))
        XCTAssertTrue(traceDiagnostics.contains("p2p-inbound strict-trust-ready peer=\\(Self.protocolIdentityLogRedaction) stable=\\(Self.protocolIdentityLogRedaction)"))
        XCTAssertTrue(traceDiagnostics.contains("p2p-inbound handshake-failed peer=\\(Self.protocolIdentityLogRedaction) reason=\\(Self.diagnosticHandshakeFailureCode(reason))"))
        XCTAssertTrue(traceDiagnostics.contains("error=\\(Self.diagnosticErrorSummary(error))"))
        assertSource(
            traceDiagnostics,
            named: "iOS P2P inbound trace diagnostics",
            excludes: [
                "Self.smokeSanitize(peerId)",
                "Self.smokeSanitize(canonicalPeerId)",
                "Self.smokeSanitize(context.stablePeerId)",
                "peer=\\(peerId)",
                "处理入站连接: \\(peerId)",
                "等待来自 \\(canonicalPeerId)",
                "from \\(peerId)",
                "header=0x\\(headerHex)",
                "String(describing: reason)",
                "error=\\(Self.smokeSanitize(error.localizedDescription))",
                "error=\\(Self.smokeSanitize(error2.localizedDescription))"
            ]
        )

        let endpointStart = try XCTUnwrap(source.range(of: "private func establishReadyConnectionWithMetrics"))
        let endpointEnd = try XCTUnwrap(
            source.range(
                of: "private static func attemptDurationJitterMs",
                range: endpointStart.lowerBound..<source.endIndex
            )
        )
        let endpointDiagnostics = String(source[endpointStart.lowerBound..<endpointEnd.lowerBound])
        XCTAssertTrue(endpointDiagnostics.contains("endpoint=\\(Self.protocolIdentityLogRedaction)"))
        assertSource(
            endpointDiagnostics,
            named: "iOS P2P endpoint diagnostics",
            excludes: [
                "endpointDescription",
                "String(describing: endpoint)",
                "\\(device.name) endpoint="
            ]
        )

        let stateStart = try XCTUnwrap(source.range(of: "private func handleConnectionStateChange"))
        let stateEnd = try XCTUnwrap(
            source.range(
                of: "private func scheduleReconnectIfNeeded",
                range: stateStart.lowerBound..<source.endIndex
            )
        )
        let stateDiagnostics = String(source[stateStart.lowerBound..<stateEnd.lowerBound])
        XCTAssertTrue(stateDiagnostics.contains("state=\\(Self.diagnosticConnectionState(state))"))
        assertSource(
            stateDiagnostics,
            named: "iOS P2P connection-state diagnostics",
            excludes: [
                "String(describing: state)",
                "effectiveDevice.name",
                "runtimePeerId)) state="
            ]
        )
    }

    func testOS27SourceContractsIncludeP2PRedactionContracts() throws {
        let source = try readSource("Scripts/run_os27_beta_compatibility.sh")

        XCTAssertTrue(source.contains("P2PRedactionSourceContractTests"))
        XCTAssertTrue(
            source.contains("source_contract_filter='SkyBridgeCoreTests.(ApplePQCSDKGateSourceContractTests|AppleDesignAPISourceContractTests|AppleAIAdvisorySourceContractTests|AppleAppIntentAuthoritySourceContractTests|AIAdvisoryBoundaryTests|MetalShaderSourceCompileContractTests|AppUpdateManifestTests|QuantumCryptoManagerStrictPQCPolicyTests|P2PRedactionSourceContractTests)'")
        )
    }

    func testLegacyQuantumP2PNetworkDoesNotLogPlaintextOrRawPeerIdentifiers() throws {
        let source = try readSource("Sources/SkyBridgeCore/QuantumSecure/QuantumSecureP2PNetwork.swift")

        XCTAssertTrue(source.contains("private nonisolated static func redactedPeerLabel"))
        XCTAssertTrue(source.contains("SkyBridgeDiagnosticRedaction.stableIdentifierLabel(peerId)"))
        XCTAssertTrue(source.contains("private nonisolated static func diagnosticErrorSummary"))
        XCTAssertTrue(source.contains("SkyBridgeDiagnosticRedaction.errorSummary(error)"))
        XCTAssertTrue(source.contains("logger.info(\"📥 接收到安全消息: peer=\\(Self.redactedPeerLabel(peerId)) bytes=\\(decryptedMessage.utf8.count)"))

        assertSource(
            source,
            named: "legacy QuantumSecureP2PNetwork diagnostics",
            excludes: [
                "logger.info(\"📥 接收到安全消息: \\(decryptedMessage)\")",
                "logger.info(\"📤 发送量子安全消息到: \\(peerId)\")",
                "logger.info(\"✅ 消息已发送并加密: \\(peerId)\")",
                "logger.error(\"❌ 数据包签名验证失败: \\(peerId)\")",
                "logger.error(\"❌ 未找到解密密钥: \\(peerId)\")",
                "logger.error(\"❌ 处理接收数据失败: \\(error)\")",
                "logger.error(\"❌ 接收数据失败: \\(error)\")",
                "logger.info(\"🔗 处理新连接: \\(peerId)\")",
                "logger.info(\"🔑 处理ECDH密钥交换: \\(peerId)\")",
                "logger.warning(\"⚠️ 心跳失败：连接不存在: \\(peerId)\")",
                "String(describing: error)"
            ]
        )
    }

    func testLegacyQuantumP2PUserMessagesRequireStrictPQCSignatures() throws {
        let source = try readSource("Sources/SkyBridgeCore/QuantumSecure/QuantumSecureP2PNetwork.swift")

        XCTAssertTrue(source.contains("postQuantumCrypto.signPQCRequired(encrypted.combined, for: peerId)"))
        XCTAssertTrue(source.contains("postQuantumCrypto.verifyPQCRequired("))
        XCTAssertTrue(source.contains("用户消息缺少 Strict-PQC 签名"))
        XCTAssertTrue(source.contains("用户消息 Strict-PQC 签名验证失败"))

        assertSource(
            source,
            named: "legacy QuantumSecureP2PNetwork message authentication",
            excludes: [
                "postQuantumCrypto.sign(encrypted.combined, for: peerId)",
                "let isValid = try await postQuantumCrypto.verify(packet.data, signature: packet.signature, for: peerId)",
                "验证签名（可选）：如果 signature 为空，则跳过",
                "if !packet.signature.isEmpty {",
                "signature 为空，则跳过"
            ]
        )
    }
}
