import Foundation
import SkyBridgeProtocolCore
import XCTest

final class QPeriaptPeerPlatformPolicyTests: XCTestCase {
    private struct Contract: Decodable {
        let schema_version: Int
        let native_admission_required: Bool
        let handshake: [HandshakeCase]
        let app: [AppCase]
    }

    private struct HandshakeCase: Decodable {
        let version: String?
        let eligible: Bool
    }

    private struct AppCase: Decodable {
        let platform: String?
        let os_version: String?
        let eligible: Bool
    }

    func testHandshakePlatformContract() throws {
        let contract = try loadContract()
        XCTAssertEqual(contract.schema_version, 1)
        XCTAssertTrue(contract.native_admission_required)
        XCTAssertEqual(contract.handshake.count, 62)
        for entry in contract.handshake {
            XCTAssertEqual(
                QPeriaptPeerPlatformPolicy.isPeerHandshakePlatformVersionEligible(entry.version),
                entry.eligible,
                "platform version: \(String(describing: entry.version))"
            )
        }
    }

    func testPairingMetadataContractRequiresMatchingPlatformFamily() throws {
        let contract = try loadContract()
        XCTAssertEqual(contract.app.count, 23)
        for entry in contract.app {
            XCTAssertEqual(
                QPeriaptPeerPlatformPolicy.isPeerAppPlatformEligible(
                    platform: entry.platform,
                    osVersion: entry.os_version
                ),
                entry.eligible,
                "platform: \(String(describing: entry.platform)); version: \(String(describing: entry.os_version))"
            )
        }
    }

    private func loadContract() throws -> Contract {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Config/qperiapt-peer-platform-contract.json"))
        return try JSONDecoder().decode(Contract.self, from: data)
    }
}
