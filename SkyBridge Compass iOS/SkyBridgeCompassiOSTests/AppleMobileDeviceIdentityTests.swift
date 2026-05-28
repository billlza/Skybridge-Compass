import XCTest
@testable import SkyBridgeCompass_iOS

final class AppleMobileDeviceIdentityTests: XCTestCase {
    func testAppEntitlementsDeclareUserAssignedDeviceNameAccess() throws {
        for fileName in [
            "SkyBridgeCompass-iOSDebug.entitlements",
            "SkyBridgeCompass-iOSRelease.entitlements"
        ] {
            let entitlements = try loadEntitlements(named: fileName)
            XCTAssertEqual(
                entitlements["com.apple.developer.device-information.user-assigned-device-name"] as? Bool,
                true,
                "\(fileName) must request Apple's user-assigned device-name entitlement so UIDevice.name can advertise the real iPad name instead of the generic family name."
            )
        }
    }

    func testPresentationMapsKnownIPhoneModelIdentifier() {
        let presentation = AppleMobileDeviceIdentity.presentation(
            forModelIdentifier: "iPhone17,1",
            platform: .iOS
        )

        XCTAssertEqual(presentation.modelName, "iPhone 16 Pro")
        XCTAssertEqual(presentation.chip, "A18 Pro")
    }

    func testPresentationMapsKnownIPadModelIdentifier() {
        let presentation = AppleMobileDeviceIdentity.presentation(
            forModelIdentifier: "iPad16,3",
            platform: .iPadOS
        )

        XCTAssertEqual(presentation.modelName, "iPad Pro 11-inch (M4)")
        XCTAssertEqual(presentation.chip, "M4")
    }

    func testUnknownMobileIdentifierFallsBackToIdentifierAndGenericSoC() {
        let presentation = AppleMobileDeviceIdentity.presentation(
            forModelIdentifier: "iPad99,9",
            platform: .iPadOS
        )

        XCTAssertEqual(presentation.modelName, "iPad99,9")
        XCTAssertEqual(presentation.chip, "Apple SoC")
    }

    private func loadEntitlements(named fileName: String) throws -> [String: Any] {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let projectURL = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let entitlementURL = projectURL.appendingPathComponent(fileName)
        let data = try Data(contentsOf: entitlementURL)
        let plist = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        return try XCTUnwrap(plist as? [String: Any])
    }
}
