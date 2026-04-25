import XCTest
@testable import SkyBridgeCompass_iOS

final class AppleMobileDeviceIdentityTests: XCTestCase {
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
}
