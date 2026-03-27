import XCTest
@testable import SkyBridgeCore

final class AuthenticationServiceRefreshTokenTests: XCTestCase {
    func testMergedRefreshTokenPrefersNonEmptyCandidate() {
        XCTAssertEqual(
            AuthenticationService.mergedRefreshToken(" new-token ", fallback: "old-token"),
            "new-token"
        )
    }

    func testMergedRefreshTokenFallsBackWhenCandidateMissing() {
        XCTAssertEqual(
            AuthenticationService.mergedRefreshToken(nil, fallback: " old-token "),
            "old-token"
        )
        XCTAssertEqual(
            AuthenticationService.mergedRefreshToken("   ", fallback: "old-token"),
            "old-token"
        )
    }

    func testMergedRefreshTokenReturnsNilWhenBothMissing() {
        XCTAssertNil(AuthenticationService.mergedRefreshToken(nil, fallback: nil))
        XCTAssertNil(AuthenticationService.mergedRefreshToken(" ", fallback: " "))
    }
}
