import XCTest
@testable import SkyBridgeCompass_iOS

final class BonjourServiceIdentitySanitizerTests: XCTestCase {
    func testRejectsSyntheticBonjourIdentityNames() {
        XCTAssertNil(BonjourServiceIdentitySanitizer.sanitizedServiceInstanceName("id:e0715a9a-d0d3-47e6-b353-de0a30293e1f"))
        XCTAssertNil(BonjourServiceIdentitySanitizer.sanitizedServiceInstanceName("bonjour:id:e0715a9a-d0d3-47e6-b353-de0a30293e1f@local."))
        XCTAssertNil(BonjourServiceIdentitySanitizer.sanitizedServiceInstanceName("host:fe80::1%en0"))
        XCTAssertNil(BonjourServiceIdentitySanitizer.sanitizedServiceInstanceName("E0715A9A-D0D3-47E6-B353-DE0A30293E1F"))
        XCTAssertNil(BonjourServiceIdentitySanitizer.sanitizedServiceInstanceName("fe80::ce0:3cf9:13d0:85b3%en0"))
    }

    func testAcceptsAndNormalizesRealBonjourInstanceNames() {
        XCTAssertEqual(
            BonjourServiceIdentitySanitizer.sanitizedServiceInstanceName("Lza的MacBook Pro._skybridge._tcp"),
            "Lza的MacBook Pro"
        )
        XCTAssertEqual(
            BonjourServiceIdentitySanitizer.sanitizedServiceInstanceName("bonjour:Lza的MacBook Pro@local."),
            "Lza的MacBook Pro"
        )
    }
}

@available(iOS 17.0, *)
@MainActor
final class P2PBootstrapPolicyTests: XCTestCase {
    func testStrictPQCUsesBootstrapWhenPreferredKEMIsMissing() {
        XCTAssertFalse(
            P2PConnectionManager.canSatisfyStrictPQCWithTrustedKEM(
                trustedPeerKEMSuites: [],
                preferredTargetSuite: .xwing
            )
        )
    }

    func testStrictPQCDoesNotBootstrapWhenPreferredKEMExists() {
        XCTAssertTrue(
            P2PConnectionManager.canSatisfyStrictPQCWithTrustedKEM(
                trustedPeerKEMSuites: [.xwing, .mlkem768],
                preferredTargetSuite: .xwing
            )
        )
    }

    func testStrictPQCAllowsAnyPQCTrustWhenNoPreferredSuiteIsPinned() {
        XCTAssertTrue(
            P2PConnectionManager.canSatisfyStrictPQCWithTrustedKEM(
                trustedPeerKEMSuites: [.mlkem768],
                preferredTargetSuite: nil
            )
        )
    }

    func testStrictPQCFallsBackToPurePQCWhenPreferredHybridSuiteIsUnavailable() {
        XCTAssertTrue(
            P2PConnectionManager.canSatisfyStrictPQCWithTrustedKEM(
                trustedPeerKEMSuites: [.mlkem768],
                preferredTargetSuite: .xwing
            )
        )
    }

}

@available(iOS 17.0, *)
@MainActor
final class P2PBootstrapRekeyTargetTests: XCTestCase {
    func testStrictPQCRecognizesCanonicalMLKEMAsSatisfyingForwardSecureTarget() {
        XCTAssertTrue(
            P2PConnectionManager.canSatisfyStrictPQCWithTrustedKEM(
                trustedPeerKEMSuites: [.mlkem768],
                preferredTargetSuite: .mlkem768fs
            )
        )
    }

    func testSuiteSupportsTargetKEMTreatsFSAndCanonicalMLKEMAsEquivalent() {
        XCTAssertTrue(P2PConnectionManager.suiteSupportsTargetKEM(.mlkem768, target: .mlkem768fs))
        XCTAssertTrue(P2PConnectionManager.suiteSupportsTargetKEM(.mlkem768fs, target: .mlkem768))
        XCTAssertFalse(P2PConnectionManager.suiteSupportsTargetKEM(.xwing, target: .mlkem768fs))
    }

    func testPreferredBootstrapRekeyTargetMatchesPreparedHandshakeOfferOrder() throws {
        let provider = CryptoProviderFactory.make(policy: .requirePQC)
        let preparation = try TwoAttemptHandshakeManager.prepareAttempt(
            strategy: .pqcOnly,
            cryptoProvider: provider,
            pqcOfferMode: .preferredSingle
        )

        XCTAssertEqual(
            P2PConnectionManager.preferredBootstrapRekeyTargetSuite(using: provider),
            preparation.offeredSuites.first
        )
    }
}
