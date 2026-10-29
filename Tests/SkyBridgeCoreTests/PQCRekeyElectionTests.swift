import XCTest
@testable import SkyBridgeCore

final class PQCRekeyElectionTests: XCTestCase {
    func testLexicographicallySmallerDeviceInitiatesRekey() {
        XCTAssertEqual(
            WebRTCPQCHandshakePolicy.shouldInitiatePQCRekey(
                localDeviceId: "device-a",
                remoteDeviceId: "device-b"
            ),
            true
        )
        XCTAssertEqual(
            WebRTCPQCHandshakePolicy.shouldInitiatePQCRekey(
                localDeviceId: "device-b",
                remoteDeviceId: "device-a"
            ),
            false
        )
    }

    func testElectionCanonicalizesCaseAndWhitespace() {
        XCTAssertEqual(
            WebRTCPQCHandshakePolicy.shouldInitiatePQCRekey(
                localDeviceId: " Device-A ",
                remoteDeviceId: "device-b"
            ),
            true
        )
        XCTAssertEqual(
            WebRTCPQCHandshakePolicy.canonicalPQCRekeyElectionDeviceId("  DEVICE-A  "),
            "device-a"
        )
    }

    func testElectionRejectsPlaceholdersAndDuplicateIds() {
        XCTAssertNil(
            WebRTCPQCHandshakePolicy.shouldInitiatePQCRekey(
                localDeviceId: "device-a",
                remoteDeviceId: "webrtc-session-123"
            )
        )
        XCTAssertNil(
            WebRTCPQCHandshakePolicy.shouldInitiatePQCRekey(
                localDeviceId: "device-a",
                remoteDeviceId: "device-a"
            )
        )
    }
}
