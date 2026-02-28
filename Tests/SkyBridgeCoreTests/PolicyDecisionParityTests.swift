import XCTest
@testable import SkyBridgeCore

final class PolicyDecisionParityTests: XCTestCase {
    func testPolicyDecisionMatrixHasStableSuiteAndSemanticOutputs() {
        let knownSuites: Set<UInt16> = [
            CryptoSuite.x25519Ed25519.wireId,
            CryptoSuite.mlkem768MLDSA65.wireId
        ]

        for input in PolicyDecisionTestVectors.allInputs() {
            let snapshot = PolicyDecisionContract.evaluate(input)
            XCTAssertEqual(snapshot.policy, input.policy.rawValue)
            XCTAssertTrue(knownSuites.contains(snapshot.selected_suite_wire_id))
            XCTAssertFalse(snapshot.event_code.isEmpty)
            XCTAssertFalse(snapshot.ui_error_category.isEmpty)
        }
    }

    func testStrictAndClassicPoliciesDoNotExposeClassicFallbackPath() {
        for input in PolicyDecisionTestVectors.allInputs() {
            guard input.policy != .prefer else { continue }
            let snapshot = PolicyDecisionContract.evaluate(input)
            XCTAssertFalse(snapshot.fallback_allowed)
        }
    }

    func testClassicPolicyAlwaysPinsClassicTier() {
        for input in PolicyDecisionTestVectors.allInputs() where input.policy == .classic {
            let snapshot = PolicyDecisionContract.evaluate(input)
            XCTAssertEqual(snapshot.selected_tier, CryptoTier.classic.rawValue)
            XCTAssertEqual(snapshot.selected_suite_wire_id, CryptoSuite.x25519Ed25519.wireId)
            XCTAssertEqual(snapshot.event_code, "classic.selected")
        }
    }
}
