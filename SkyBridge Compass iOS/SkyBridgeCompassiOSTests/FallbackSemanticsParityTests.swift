import XCTest
@testable import SkyBridgeCompass_iOS

@available(iOS 17.0, *)
final class FallbackSemanticsParityTests: XCTestCase {
    func testFallbackAllowedExpressionMatchesPolicyContract() {
        for input in PolicyDecisionTestVectors.allInputs() {
            let snapshot = PolicyDecisionContract.evaluate(input)

            let hasApple = input.compile_time_has_apple_pqc_sdk && input.local_has_apple_provider
            let hasPQCProvider = hasApple || input.local_has_liboqs_provider
            let fallbackCandidate = input.policy == .prefer
                && hasPQCProvider
                && input.peer_capability_visibility != .pqcVisible
            let expectedFallback = fallbackCandidate
                && input.trust_store_state == .trusted
                && input.bootstrap_rekey_state == .rekey

            XCTAssertEqual(snapshot.fallback_allowed, expectedFallback)
        }
    }

    func testFallbackDeniedIsAuditable() {
        let input = PolicyDecisionInput(
            policy: .prefer,
            peer_capability_visibility: .classicOnly,
            local_has_apple_provider: false,
            local_has_liboqs_provider: true,
            compile_time_has_apple_pqc_sdk: false,
            trust_store_state: .untrusted,
            bootstrap_rekey_state: .bootstrap
        )

        let snapshot = PolicyDecisionContract.evaluate(input)
        XCTAssertFalse(snapshot.fallback_allowed)
        XCTAssertEqual(snapshot.event_code, PolicyDecisionEventCode.preferClassicFallbackDenied.rawValue)
        XCTAssertEqual(snapshot.ui_error_category, PolicyDecisionUIErrorCategory.downgradeBlocked.rawValue)
    }
}
