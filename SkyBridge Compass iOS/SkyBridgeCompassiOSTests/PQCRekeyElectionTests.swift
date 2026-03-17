import XCTest
@testable import SkyBridgeCompass_iOS

@available(iOS 17.0, *)
final class PQCRekeyElectionTests: XCTestCase {
    func testLexicographicallySmallerDeviceInitiatesRekey() {
        XCTAssertEqual(
            CrossNetworkWebRTCManager.shouldInitiatePQCRekey(
                localDeviceId: "device-a",
                remoteDeviceId: "device-b"
            ),
            true
        )
        XCTAssertEqual(
            CrossNetworkWebRTCManager.shouldInitiatePQCRekey(
                localDeviceId: "device-b",
                remoteDeviceId: "device-a"
            ),
            false
        )
    }

    func testElectionCanonicalizesCaseAndWhitespace() {
        XCTAssertEqual(
            CrossNetworkWebRTCManager.shouldInitiatePQCRekey(
                localDeviceId: " Device-A ",
                remoteDeviceId: "device-b"
            ),
            true
        )
        XCTAssertEqual(
            CrossNetworkWebRTCManager.canonicalPQCRekeyElectionDeviceId("  DEVICE-A  "),
            "device-a"
        )
    }

    func testElectionRejectsPlaceholdersAndDuplicateIds() {
        XCTAssertNil(
            CrossNetworkWebRTCManager.shouldInitiatePQCRekey(
                localDeviceId: "device-a",
                remoteDeviceId: "webrtc-session-123"
            )
        )
        XCTAssertNil(
            CrossNetworkWebRTCManager.shouldInitiatePQCRekey(
                localDeviceId: "device-a",
                remoteDeviceId: "device-a"
            )
        )
    }
}
