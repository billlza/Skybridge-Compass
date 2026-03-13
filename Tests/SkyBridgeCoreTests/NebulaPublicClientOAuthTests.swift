import XCTest
@testable import SkyBridgeCore

@MainActor
final class NebulaPublicClientOAuthTests: XCTestCase {
    override func setUp() async throws {
        NebulaPublicClientOAuth.shared.overrideConfiguration(
            baseURL: "https://nebula.example.com",
            clientId: "skybridge_compass_tests"
        )
    }

    override func tearDown() async throws {
        NebulaPublicClientOAuth.shared.clearConfigurationOverride()
    }

    func testCodeVerifierMeetsPKCELengthRequirements() {
        let verifier = NebulaPublicClientOAuth.generateCodeVerifier()
        XCTAssertGreaterThanOrEqual(verifier.count, 43)
        XCTAssertLessThanOrEqual(verifier.count, 128)
        XCTAssertFalse(verifier.contains("="))
    }

    func testCodeChallengeMatchesKnownVector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let challenge = NebulaPublicClientOAuth.codeChallenge(for: verifier)
        XCTAssertEqual(challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testAuthorizationRequestContainsRequiredQueryItems() throws {
        let request = try NebulaPublicClientOAuth.shared.makeAuthorizationRequest(
            redirectURI: "skybridge://auth/nebula",
            scopes: ["openid", "profile"]
        )

        let components = try XCTUnwrap(URLComponents(url: request.authorizationURL, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(items["response_type"], "code")
        XCTAssertEqual(items["redirect_uri"], "skybridge://auth/nebula")
        XCTAssertEqual(items["scope"], "openid profile")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["code_challenge"], request.codeChallenge)
        XCTAssertEqual(items["state"], request.state)
    }
}
