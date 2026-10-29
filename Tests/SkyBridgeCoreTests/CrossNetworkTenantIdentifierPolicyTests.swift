import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class CrossNetworkTenantIdentifierPolicyTests: XCTestCase {
    func testDeclaredTenantRequiresMatchingSignedTenantClaim() throws {
        let accessToken = try makeAccessToken(payload: [
            "sub": "user-1",
            "app_metadata": ["tenant_id": "jwt-tenant"]
        ])

        XCTAssertEqual(
            try CrossNetworkTenantIdentifierPolicy.resolve(
                accessToken: accessToken,
                explicitTenantID: " jwt-tenant ",
                sessionTenantID: "jwt-tenant",
                sessionUserIdentifier: "user-1"
            ),
            "jwt-tenant"
        )

        XCTAssertThrowsError(
            try CrossNetworkTenantIdentifierPolicy.resolve(
                accessToken: accessToken,
                explicitTenantID: "jwt-tenant",
                sessionTenantID: "jwt-tenant",
                sessionUserIdentifier: "different-session-user"
            )
        ) { error in
            XCTAssertEqual(
                error as? CrossNetworkTenantIdentifierPolicy.ResolutionError,
                .userIdentityMismatch
            )
        }

        XCTAssertThrowsError(
            try CrossNetworkTenantIdentifierPolicy.resolve(
                accessToken: accessToken,
                explicitTenantID: "other-tenant",
                sessionTenantID: "other-tenant",
                sessionUserIdentifier: "user-1"
            )
        ) { error in
            XCTAssertEqual(
                error as? CrossNetworkTenantIdentifierPolicy.ResolutionError,
                .tenantIdentityMismatch
            )
        }
    }

    func testSessionTenantMayOnlyAssertJWTSubjectFallback() throws {
        let accessToken = try makeAccessToken(payload: ["sub": "NEBULA-session"])

        XCTAssertEqual(
            try CrossNetworkTenantIdentifierPolicy.resolve(
                accessToken: accessToken,
                explicitTenantID: nil,
                sessionTenantID: "NEBULA-session",
                sessionUserIdentifier: "NEBULA-session"
            ),
            "NEBULA-session"
        )
    }

    func testProtectedAppMetadataTenantClaimKeysAreAcceptedWhenCoherent() throws {
        let keys = ["tenant_id", "tenantId", "org_id", "workspace_id"]

        for key in keys {
            let payload: [String: Any] = [
                "sub": "user-1",
                "app_metadata": [key: "tenant-1"]
            ]
            let accessToken = try makeAccessToken(payload: payload)
            XCTAssertEqual(
                try CrossNetworkTenantIdentifierPolicy.resolve(
                    accessToken: accessToken,
                    explicitTenantID: "tenant-1",
                    sessionTenantID: "tenant-1",
                    sessionUserIdentifier: "user-1"
                ),
                "tenant-1",
                "Expected app_metadata.\(key) to be accepted."
            )
        }
    }

    func testConflictingSignedTenantClaimsAreRejected() throws {
        let accessToken = try makeAccessToken(payload: [
            "sub": "user-1",
            "app_metadata": [
                "tenant_id": "app-tenant",
                "workspace_id": "other-app-tenant"
            ]
        ])

        XCTAssertThrowsError(
            try CrossNetworkTenantIdentifierPolicy.resolve(
                accessToken: accessToken,
                explicitTenantID: nil,
                sessionTenantID: nil,
                sessionUserIdentifier: "user-1"
            )
        ) { error in
            XCTAssertEqual(
                error as? CrossNetworkTenantIdentifierPolicy.ResolutionError,
                .conflictingTenantClaims
            )
        }
    }

    func testUserMetadataIsNeverTenantAuthority() throws {
        let accessToken = try makeAccessToken(payload: [
            "sub": "user-1",
            "user_metadata": ["tenant_id": "attacker-selected"]
        ])

        XCTAssertThrowsError(
            try CrossNetworkTenantIdentifierPolicy.resolve(
                accessToken: accessToken,
                explicitTenantID: "attacker-selected",
                sessionTenantID: "attacker-selected",
                sessionUserIdentifier: "user-1"
            )
        ) { error in
            XCTAssertEqual(
                error as? CrossNetworkTenantIdentifierPolicy.ResolutionError,
                .tenantIdentityMismatch
            )
        }
    }

    func testJWTSubjectFallbackRequiresMatchingSessionUser() throws {
        let accessToken = try makeAccessToken(payload: ["sub": "user-1"])
        XCTAssertEqual(
            try CrossNetworkTenantIdentifierPolicy.resolve(
                accessToken: accessToken,
                explicitTenantID: nil,
                sessionTenantID: nil,
                sessionUserIdentifier: "user-1"
            ),
            "user-1"
        )

        XCTAssertThrowsError(
            try CrossNetworkTenantIdentifierPolicy.resolve(
                accessToken: accessToken,
                explicitTenantID: nil,
                sessionTenantID: nil,
                sessionUserIdentifier: "other-user"
            )
        ) { error in
            XCTAssertEqual(
                error as? CrossNetworkTenantIdentifierPolicy.ResolutionError,
                .userIdentityMismatch
            )
        }
    }

    func testOpaqueLegacyTokenIsNeverAuthenticatedTenantAuthority() throws {
        XCTAssertThrowsError(
            try CrossNetworkTenantIdentifierPolicy.resolve(
                accessToken: "opaque-legacy-token",
                explicitTenantID: nil,
                sessionTenantID: nil,
                sessionUserIdentifier: "legacy-user"
            )
        ) { error in
            XCTAssertEqual(
                error as? CrossNetworkTenantIdentifierPolicy.ResolutionError,
                .invalidJWTClaims
            )
        }
    }

    func testMalformedJWTShapedTokensAndClaimsFailClosed() throws {
        let nonJSONPayloadToken = "header.\(Self.base64URLEncodedString(from: Data("not-json".utf8))).signature"
        let nonStringClaimToken = try makeAccessToken(payload: [
            "sub": "user-1",
            "app_metadata": ["tenant_id": 42]
        ])

        for accessToken in [
            "header.invalid!.signature",
            nonJSONPayloadToken,
            nonStringClaimToken
        ] {
            XCTAssertThrowsError(
                try CrossNetworkTenantIdentifierPolicy.resolve(
                    accessToken: accessToken,
                    explicitTenantID: nil,
                    sessionTenantID: nil,
                    sessionUserIdentifier: "user-1"
                )
            ) { error in
                XCTAssertEqual(
                    error as? CrossNetworkTenantIdentifierPolicy.ResolutionError,
                    .invalidJWTClaims
                )
            }
        }
    }

    func testMissingTokenDoesNotPromoteSessionUserToAuthority() throws {
        XCTAssertThrowsError(
            try CrossNetworkTenantIdentifierPolicy.resolve(
                accessToken: nil,
                explicitTenantID: nil,
                sessionTenantID: nil,
                sessionUserIdentifier: "session-user"
            )
        ) { error in
            XCTAssertEqual(
                error as? CrossNetworkTenantIdentifierPolicy.ResolutionError,
                .invalidJWTClaims
            )
        }
    }

    private func makeAccessToken(payload: [String: Any]) throws -> String {
        let header = try Self.base64URLEncodedJSONObject(["alg": "ES256", "typ": "JWT"])
        let payload = try Self.base64URLEncodedJSONObject(payload)
        return "\(header).\(payload).test-signature"
    }

    private static func base64URLEncodedJSONObject(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return base64URLEncodedString(from: data)
    }

    private static func base64URLEncodedString(from data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
