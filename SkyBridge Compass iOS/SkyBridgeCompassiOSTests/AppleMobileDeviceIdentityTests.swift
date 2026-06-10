import XCTest
@testable import SkyBridgeCompass_iOS

final class AppleMobileDeviceIdentityTests: XCTestCase {
    func testDefaultAppEntitlementsDoNotRequestUserAssignedDeviceNameAccess() throws {
        for fileName in [
            "SkyBridgeCompass-iOSDebug.entitlements",
            "SkyBridgeCompass-iOSRelease.entitlements"
        ] {
            let entitlements = try loadEntitlements(named: fileName)
            XCTAssertNil(
                entitlements["com.apple.developer.device-information.user-assigned-device-name"],
                "\(fileName) must not request Apple's restricted user-assigned device-name entitlement by default; ordinary development profiles cannot sign it."
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

    func testGenericIPadDeviceNameFallsBackToModelPresentation() {
        let displayName = AppleMobileDeviceIdentity.displayDeviceName(
            rawDeviceName: "iPad",
            platform: .iPadOS,
            modelName: "iPad Pro 11-inch (M4)"
        )

        XCTAssertEqual(displayName, "iPad Pro 11-inch (M4)")
    }

    func testPersonalizedDeviceNameIsPreservedWhenAvailable() {
        let displayName = AppleMobileDeviceIdentity.displayDeviceName(
            rawDeviceName: "Bill's iPad",
            platform: .iPadOS,
            modelName: "iPad Pro 11-inch (M4)"
        )

        XCTAssertEqual(displayName, "Bill's iPad")
    }

    private func loadEntitlements(named fileName: String) throws -> [String: Any] {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let projectURL = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let entitlementURL = projectURL.appendingPathComponent(fileName)
        // 借助共享 helper：真机沙箱无仓库文件时 XCTSkip，而非误报失败。
        let data = Data(try readRepositorySourceForSourceShapeTests(at: entitlementURL).utf8)
        let plist = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        return try XCTUnwrap(plist as? [String: Any])
    }
}
