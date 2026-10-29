import XCTest
import SkyBridgeProtocolCore

final class ProtocolParityWireAnchorTests: XCTestCase {
    func testProtocolIdentityFingerprintMatchesCrossPlatformVectors() {
        let vectors: [(ProtocolSigningAlgorithm, Data, String)] = [
            (
                .ed25519,
                Data((0..<32).map(UInt8.init)),
                "09d14ebcd4f85644dbb1957e4b5bcf4501953e8ff2a96a6debcc1c9e5ef25de6"
            ),
            (
                .mlDSA65,
                Data(repeating: 0x65, count: 1_952),
                "1fdfd364181724c0cc67300bef7bdf2b555614b550785781d9fb3ef6de0e26d4"
            ),
            (
                .mlDSA87,
                Data(repeating: 0x87, count: 2_592),
                "49fa4ab724c2d05fb329373c72d899767f4cdb95f18dd497a36714aea3ee32c4"
            ),
        ]

        for (algorithm, publicKey, expected) in vectors {
            XCTAssertEqual(
                ProtocolIdentityBinding.computeFingerprint(
                    algorithm: algorithm,
                    publicKeyBytes: publicKey
                ),
                expected
            )
        }
    }

    func testProtocolParityScriptCoversCoreWireShapes() throws {
        let script = try repositorySource("Scripts/check_protocol_parity.py")

        XCTAssertTrue(script.contains("AppMessage payload cases"))
        XCTAssertTrue(script.contains("Cross-network file-transfer operations"))
        XCTAssertTrue(script.contains("Remote-control secure envelope constants"))
        XCTAssertTrue(script.contains("Handshake identity algorithm bytes"))
        XCTAssertTrue(script.contains("Handshake signature wire codes"))
        XCTAssertTrue(script.contains("Handshake identity public-key lengths"))
        XCTAssertTrue(script.contains("ML-DSA provider size contracts"))
        XCTAssertTrue(script.contains("Handshake message allocation limits"))
        XCTAssertTrue(script.contains("WebRTC control-frame chunk limits"))
        XCTAssertTrue(script.contains("WebRTC signaling payload fields"))
        XCTAssertTrue(script.contains("Remote SDP/ICE validator limits"))
        XCTAssertTrue(script.contains("Remote SDP/ICE fail-closed reasons"))
    }

    func testIOSAppMessageKeepsMacTextMessageWireCase() throws {
        let source = try repositorySource("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/Messaging/AppMessage.swift")

        XCTAssertTrue(source.contains("case textMessage(TextMessagePayload)"))
        XCTAssertTrue(source.contains("public struct TextMessagePayload: Codable, Sendable, Equatable"))
        XCTAssertTrue(source.contains("case textMessage"))
        XCTAssertTrue(source.contains("case .textMessage:"))
        XCTAssertTrue(source.contains("TextMessagePayload.self, forKey: selectedKey"))
        XCTAssertTrue(source.contains("private struct LegacyAssociatedValueBox<Value: Decodable>"))
        XCTAssertTrue(source.contains("legacyAssociatedValue: usesLegacyAssociatedValue"))
        XCTAssertTrue(source.contains("AppMessage must contain exactly one known discriminator"))
        XCTAssertTrue(source.contains("StrictJSONSingleDiscriminatorWireValidator.validate("))
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
            iosPolicy.contains("return SkyBridgeDiagnosticReference.stableReference(sessionId)"),
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
