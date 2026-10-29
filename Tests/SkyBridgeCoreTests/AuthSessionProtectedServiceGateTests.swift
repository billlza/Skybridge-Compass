import XCTest
@testable import SkyBridgeCore

final class AuthSessionProtectedServiceGateTests: XCTestCase {
    func testProtectedServiceAuthenticationRejectsGuestPendingAndEmptyTokens() {
        XCTAssertFalse(session(accessToken: "").isAuthenticatedForProtectedServices)
        XCTAssertFalse(session(accessToken: "   ").isAuthenticatedForProtectedServices)
        XCTAssertFalse(session(accessToken: "guest_token").isAuthenticatedForProtectedServices)
        XCTAssertFalse(session(accessToken: "pending_verification").isAuthenticatedForProtectedServices)
    }

    func testProtectedServiceAuthenticationAcceptsRealToken() {
        XCTAssertTrue(session(accessToken: "header.payload.signature").isAuthenticatedForProtectedServices)
    }

    private func session(accessToken: String) -> AuthSession {
        AuthSession(
            accessToken: accessToken,
            refreshToken: nil,
            userIdentifier: "user-1",
            displayName: "User"
        )
    }
}
