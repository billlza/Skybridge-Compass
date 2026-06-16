import Foundation
import XCTest

final class WebRTCICEPolicySourceContractTests: XCTestCase {
    func testAppleWebRTCSessionsRejectPublicStunFallbackAndTurnCredentialDowngrade() throws {
        for relativePath in [
            "Sources/SkyBridgeCore/RemoteConnection/WebRTC/WebRTCSession.swift",
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/RemoteConnection/WebRTC/WebRTCSession.swift"
        ] {
            let source = try readSource(relativePath)
            XCTAssertFalse(
                source.contains("publicFallbackSTUNURL"),
                "\(relativePath) must not carry a built-in public STUN fallback."
            )
            XCTAssertFalse(
                source.contains("fallback to public STUN"),
                "\(relativePath) must not silently fall back to public STUN."
            )
            XCTAssertTrue(
                source.contains("invalidICEConfiguration"),
                "\(relativePath) must expose invalid ICE configuration as a typed error."
            )
            XCTAssertTrue(
                source.contains("refusing STUN-only downgrade"),
                "\(relativePath) must fail closed when TURN URLs exist but credentials are missing."
            )
        }
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func readSource(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }
}
