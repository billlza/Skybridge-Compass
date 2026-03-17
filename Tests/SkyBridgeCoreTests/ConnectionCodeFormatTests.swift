import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
@MainActor
final class ConnectionCodeFormatTests: XCTestCase {
    func testSanitizeConnectionCodeInputUppercasesFiltersAndCapsLength() {
        let raw = "ab-cd12 34efghjkmnpqrstuvwxyz23456789"
        let sanitized = CrossNetworkConnectionManager.sanitizeConnectionCodeInput(raw)

        XCTAssertEqual(sanitized, "ABCD234EFGHJKMNP")
        XCTAssertEqual(sanitized.count, CrossNetworkConnectionManager.maximumConnectionCodeLength)
    }

    func testCanSubmitConnectionCodeAcceptsLegacyAndCurrentLengths() {
        XCTAssertTrue(CrossNetworkConnectionManager.canSubmitConnectionCode("ABCDEF"))
        XCTAssertTrue(CrossNetworkConnectionManager.canSubmitConnectionCode("ABCDEFGH"))
        XCTAssertTrue(CrossNetworkConnectionManager.canSubmitConnectionCode("ABCDEFGHJK"))
        XCTAssertFalse(CrossNetworkConnectionManager.canSubmitConnectionCode("ABCDE"))
        XCTAssertFalse(CrossNetworkConnectionManager.canSubmitConnectionCode("ABCDEFG"))
    }
}
