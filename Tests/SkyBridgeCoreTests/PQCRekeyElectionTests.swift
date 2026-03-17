import XCTest
@testable import SkyBridgeCore

final class PQCRekeyElectionTests: XCTestCase {
    func testLexicographicallySmallerDeviceInitiatesRekey() {
        XCTAssertEqual(
            CrossNetworkConnectionManager.shouldInitiatePQCRekey(
                localDeviceId: "device-a",
                remoteDeviceId: "device-b"
            ),
            true
        )
        XCTAssertEqual(
            CrossNetworkConnectionManager.shouldInitiatePQCRekey(
                localDeviceId: "device-b",
                remoteDeviceId: "device-a"
            ),
            false
        )
    }

    func testElectionCanonicalizesCaseAndWhitespace() {
        XCTAssertEqual(
            CrossNetworkConnectionManager.shouldInitiatePQCRekey(
                localDeviceId: " Device-A ",
                remoteDeviceId: "device-b"
            ),
            true
        )
        XCTAssertEqual(
            CrossNetworkConnectionManager.canonicalPQCRekeyElectionDeviceId("  DEVICE-A  "),
            "device-a"
        )
    }

    func testElectionRejectsPlaceholdersAndDuplicateIds() {
        XCTAssertNil(
            CrossNetworkConnectionManager.shouldInitiatePQCRekey(
                localDeviceId: "device-a",
                remoteDeviceId: "webrtc-session-123"
            )
        )
        XCTAssertNil(
            CrossNetworkConnectionManager.shouldInitiatePQCRekey(
                localDeviceId: "device-a",
                remoteDeviceId: "device-a"
            )
        )
    }
}
