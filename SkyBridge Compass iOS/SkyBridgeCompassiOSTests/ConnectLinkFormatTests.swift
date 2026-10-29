import XCTest
@testable import SkyBridgeCompass_iOS

@MainActor
@available(iOS 17.0, *)
final class ConnectLinkFormatTests: XCTestCase {
    func testIsConnectLinkStringAcceptsCurrentPathURLForms() {
        XCTAssertTrue(CrossNetworkWebRTCManager.isConnectLinkString("skybridge://connect/abc123"))
        XCTAssertTrue(CrossNetworkWebRTCManager.isConnectLinkString("skybridge://connect?data=abc123"))
    }

    func testIsConnectLinkStringRejectsLegacyJSONPayloads() {
        let pairingJSON = #"{"type":"device_pairing","deviceId":"abc","deviceName":"iPhone"}"#
        let fileTransferJSON = #"{"type":"file_transfer","server":"http://127.0.0.1","code":"AB12CD34"}"#

        XCTAssertFalse(CrossNetworkWebRTCManager.isConnectLinkString(pairingJSON))
        XCTAssertFalse(CrossNetworkWebRTCManager.isConnectLinkString(fileTransferJSON))
        XCTAssertFalse(CrossNetworkWebRTCManager.isConnectLinkString(""))
    }
}
