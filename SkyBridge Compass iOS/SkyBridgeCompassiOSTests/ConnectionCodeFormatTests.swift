import XCTest
@testable import SkyBridgeCompass_iOS

@MainActor
@available(iOS 17.0, *)
final class ConnectionCodeFormatTests: XCTestCase {
    func testSanitizeConnectionCodeInputUppercasesFiltersAndCapsLength() {
        let raw = "ab-cd12 34efghjkmnpqrstuvwxyz23456789"
        let sanitized = CrossNetworkWebRTCManager.sanitizeConnectionCodeInput(raw)

        XCTAssertEqual(sanitized, "ABCD234EFGHJKMNP")
        XCTAssertEqual(sanitized.count, CrossNetworkWebRTCManager.maximumConnectionCodeLength)
    }

    func testCanSubmitConnectionCodeAcceptsLegacyAndCurrentLengths() {
        XCTAssertTrue(CrossNetworkWebRTCManager.canSubmitConnectionCode("ABCDEF"))
        XCTAssertTrue(CrossNetworkWebRTCManager.canSubmitConnectionCode("ABCDEFGH"))
        XCTAssertTrue(CrossNetworkWebRTCManager.canSubmitConnectionCode("ABCDEFGHJK"))
        XCTAssertFalse(CrossNetworkWebRTCManager.canSubmitConnectionCode("ABCDE"))
        XCTAssertFalse(CrossNetworkWebRTCManager.canSubmitConnectionCode("ABCDEFG"))
    }

    func testIOSDeviceSupportGateBlocksExplicit2018And2019A12FamilyDevices() {
        XCTAssertFalse(IOSDeviceSupportGate.isSupported(modelIdentifier: "iPhone11,2"))
        XCTAssertFalse(IOSDeviceSupportGate.isSupported(modelIdentifier: "iPhone11,8"))
        XCTAssertFalse(IOSDeviceSupportGate.isSupported(modelIdentifier: "iPad8,1"))
        XCTAssertFalse(IOSDeviceSupportGate.isSupported(modelIdentifier: "iPad11,3"))
    }

    func testIOSDeviceSupportGateAllows2020AndLaterDevices() {
        XCTAssertTrue(IOSDeviceSupportGate.isSupported(modelIdentifier: "iPhone12,8"))
        XCTAssertTrue(IOSDeviceSupportGate.isSupported(modelIdentifier: "iPhone13,2"))
        XCTAssertTrue(IOSDeviceSupportGate.isSupported(modelIdentifier: "iPad11,6"))
        XCTAssertTrue(IOSDeviceSupportGate.isSupported(modelIdentifier: "iPad13,1"))
    }
}
