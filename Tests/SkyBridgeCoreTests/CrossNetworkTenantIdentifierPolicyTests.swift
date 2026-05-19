import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class CrossNetworkTenantIdentifierPolicyTests: XCTestCase {
    func testEnvironmentTenantOverridesAccessTokenClaims() throws {
        let accessToken = try makeAccessToken(payload: [
            "app_metadata": ["tenant_id": "jwt-tenant"]
        ])

        XCTAssertEqual(
            CrossNetworkTenantIdentifierPolicy.derive(
                accessToken: accessToken,
                environment: ["SKYBRIDGE_TENANT_ID": " env-tenant "]
            ),
            "env-tenant"
        )
    }

    func testBlankEnvironmentTenantFallsBackToAccessTokenClaims() throws {
        let accessToken = try makeAccessToken(payload: [
            "app_metadata": ["tenant_id": "jwt-tenant"]
        ])

        XCTAssertEqual(
            CrossNetworkTenantIdentifierPolicy.derive(
                accessToken: accessToken,
                environment: ["SKYBRIDGE_TENANT_ID": " \n\t "]
            ),
            "jwt-tenant"
        )
    }

    func testAppMetadataCandidateKeys() throws {
        let cases: [(key: String, expected: String)] = [
            ("tenant_id", "tenant-id"),
            ("tenantId", "tenant-camel"),
            ("org_id", "org-id"),
            ("workspace_id", "workspace-id")
        ]

        for testCase in cases {
            let accessToken = try makeAccessToken(payload: [
                "app_metadata": [testCase.key: testCase.expected]
            ])

            XCTAssertEqual(
                CrossNetworkTenantIdentifierPolicy.derive(accessToken: accessToken, environment: [:]),
                testCase.expected,
                "Expected app_metadata.\(testCase.key) to be accepted."
            )
        }
    }

    func testUserMetadataCandidateKeysAreFallbacks() throws {
        let cases: [(key: String, expected: String)] = [
            ("tenant_id", "user-tenant-id"),
            ("tenantId", "user-tenant-camel"),
            ("org_id", "user-org-id"),
            ("workspace_id", "user-workspace-id")
        ]

        for testCase in cases {
            let accessToken = try makeAccessToken(payload: [
                "app_metadata": ["tenant_id": "   "],
                "user_metadata": [testCase.key: testCase.expected]
            ])

            XCTAssertEqual(
                CrossNetworkTenantIdentifierPolicy.derive(accessToken: accessToken, environment: [:]),
                testCase.expected,
                "Expected user_metadata.\(testCase.key) to be accepted when app metadata is empty."
            )
        }
    }

    func testCandidatePriorityPrefersAppMetadataThenUserMetadataThenRootClaims() throws {
        let accessToken = try makeAccessToken(payload: [
            "app_metadata": [
                "tenant_id": "app-tenant",
                "tenantId": "app-tenant-camel"
            ],
            "user_metadata": [
                "tenant_id": "user-tenant"
            ],
            "tenant_id": "root-tenant",
            "sub": "subject-id"
        ])

        XCTAssertEqual(
            CrossNetworkTenantIdentifierPolicy.derive(accessToken: accessToken, environment: [:]),
            "app-tenant"
        )
    }

    func testNilStringCandidatesAreSkipped() throws {
        let accessToken = try makeAccessToken(payload: [
            "app_metadata": [
                "tenant_id": "nil",
                "tenantId": "app-tenant-camel"
            ],
            "user_metadata": [
                "tenant_id": "user-tenant"
            ],
            "tenant_id": "root-tenant"
        ])

        XCTAssertEqual(
            CrossNetworkTenantIdentifierPolicy.derive(accessToken: accessToken, environment: [:]),
            "app-tenant-camel"
        )
    }

    func testRootCandidateKeysAreFallbacks() throws {
        let cases: [(key: String, expected: String)] = [
            ("tenant_id", "root-tenant-id"),
            ("tenantId", "root-tenant-camel"),
            ("sub", "subject-id")
        ]

        for testCase in cases {
            let accessToken = try makeAccessToken(payload: [
                "app_metadata": ["tenant_id": "   "],
                "user_metadata": ["tenant_id": "   "],
                testCase.key: testCase.expected
            ])

            XCTAssertEqual(
                CrossNetworkTenantIdentifierPolicy.derive(accessToken: accessToken, environment: [:]),
                testCase.expected,
                "Expected root \(testCase.key) to be accepted after metadata fallbacks."
            )
        }
    }

    func testInvalidAccessTokensReturnEmptyTenantIdentifier() throws {
        let nonJSONPayloadToken = "header.\(Self.base64URLEncodedString(from: Data("not-json".utf8))).signature"

        XCTAssertEqual(CrossNetworkTenantIdentifierPolicy.derive(accessToken: nil, environment: [:]), "")
        XCTAssertEqual(CrossNetworkTenantIdentifierPolicy.derive(accessToken: "", environment: [:]), "")
        XCTAssertEqual(CrossNetworkTenantIdentifierPolicy.derive(accessToken: "not-a-jwt", environment: [:]), "")
        XCTAssertEqual(CrossNetworkTenantIdentifierPolicy.derive(accessToken: "header.invalid!.signature", environment: [:]), "")
        XCTAssertEqual(CrossNetworkTenantIdentifierPolicy.derive(accessToken: nonJSONPayloadToken, environment: [:]), "")
    }

    private func makeAccessToken(payload: [String: Any]) throws -> String {
        let header = try Self.base64URLEncodedJSONObject(["alg": "none", "typ": "JWT"])
        let payload = try Self.base64URLEncodedJSONObject(payload)
        return "\(header).\(payload).signature"
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
