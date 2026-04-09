import XCTest
@testable import SkyBridgeCore
@testable import SkyBridgeProtocolCore

final class TURNCredentialServicePolicyTests: XCTestCase {
    func testStaticTurnFallbackIsDisabledByDefault() {
        XCTAssertFalse(
            SkyBridgeServerConfig.staticTURNFallbackAllowed(
                environment: [:],
                infoDictionary: nil
            )
        )
    }

    func testStaticTurnFallbackRequiresExplicitOptIn() {
        XCTAssertTrue(
            SkyBridgeServerConfig.staticTURNFallbackAllowed(
                environment: ["SKYBRIDGE_ALLOW_STATIC_TURN_FALLBACK": "true"],
                infoDictionary: nil
            )
        )
        XCTAssertFalse(
            SkyBridgeServerConfig.staticTURNFallbackAllowed(
                environment: ["SKYBRIDGE_ALLOW_STATIC_TURN_FALLBACK": "0"],
                infoDictionary: nil
            )
        )
    }

    func testResolvedFallbackCredentialsRemainStunOnlyWithoutOptIn() {
        let credentials = TURNCredentialService.resolvedFallbackCredentials(
            allowStaticTURN: false,
            environment: [
                "SKYBRIDGE_TURN_USERNAME": "operator",
                "SKYBRIDGE_TURN_PASSWORD": "secret"
            ],
            turnURLs: ["turns:relay.example.com:5349?transport=tcp"],
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertEqual(credentials.username, "")
        XCTAssertEqual(credentials.password, "")
        XCTAssertTrue(credentials.uris.isEmpty)
    }

    func testResolvedFallbackCredentialsUseStaticTURNWhenOptedIn() {
        let credentials = TURNCredentialService.resolvedFallbackCredentials(
            allowStaticTURN: true,
            environment: [
                "SKYBRIDGE_TURN_USERNAME": "operator",
                "SKYBRIDGE_TURN_PASSWORD": "secret"
            ],
            turnURLs: ["turns:relay.example.com:5349?transport=tcp"],
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertEqual(credentials.username, "operator")
        XCTAssertEqual(credentials.password, "secret")
        XCTAssertEqual(credentials.uris, ["turns:relay.example.com:5349?transport=tcp"])
    }
}
