import XCTest
@testable import SkyBridgeCore

final class ICloudDeviceIdentityHintsTests: XCTestCase {
    func testICloudDeviceDecodesStableIdentityHintsWithoutBreakingOlderPresenceRecords() throws {
        let modernJSON = """
        {
          "id": "kvs-path-usb",
          "name": "Bill iPad",
          "model": "iPad Pro 11-inch (M4)",
          "osVersion": "26.5",
          "appVersion": "1.0.0",
          "lastSeen": "2026-05-25T08:00:00Z",
          "capabilities": ["remote_desktop", "file_transfer"],
          "isOnline": true,
          "networkType": "wifi",
          "stableIdentityDeviceId": "stable-ipad-id",
          "registrationFingerprint": "registration-fingerprint",
          "vendorDeviceId": "vendor-ipad-id"
        }
        """.data(using: .utf8)!

        let legacyJSON = """
        {
          "id": "kvs-path-wifi",
          "name": "Bill iPad",
          "model": "iPad Pro 11-inch (M4)",
          "osVersion": "26.5",
          "appVersion": "1.0.0",
          "lastSeen": "2026-05-25T08:00:00Z",
          "capabilities": ["remote_desktop", "file_transfer"],
          "isOnline": true,
          "networkType": "wifi"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let modern = try decoder.decode(iCloudDevice.self, from: modernJSON)
        let legacy = try decoder.decode(iCloudDevice.self, from: legacyJSON)

        XCTAssertEqual(modern.stableIdentityDeviceId, "stable-ipad-id")
        XCTAssertEqual(modern.registrationFingerprint, "registration-fingerprint")
        XCTAssertEqual(modern.vendorDeviceId, "vendor-ipad-id")
        XCTAssertNil(legacy.stableIdentityDeviceId)
        XCTAssertNil(legacy.registrationFingerprint)
        XCTAssertNil(legacy.vendorDeviceId)
    }
}
