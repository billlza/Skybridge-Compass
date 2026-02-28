import XCTest
@testable import SkyBridgeCompass_iOS

@available(iOS 17.0, *)
final class PolicyDecisionParityTests: XCTestCase {
    func testBootstrapOnceProducesDeterministicDecisionSnapshot() {
        let input = PolicyDecisionInput(
            policy: .prefer,
            peer_capability_visibility: .unknown,
            local_has_apple_provider: false,
            local_has_liboqs_provider: true,
            compile_time_has_apple_pqc_sdk: false,
            trust_store_state: .trusted,
            bootstrap_rekey_state: .bootstrap
        )

        let first = PolicyDecisionContract.evaluate(input)
        let second = PolicyDecisionContract.evaluate(input)
        XCTAssertEqual(first, second)
    }

    func testRekeyToPQCUpgradesSuiteChoiceWhenCapabilityAppears() {
        let bootstrapInput = PolicyDecisionInput(
            policy: .prefer,
            peer_capability_visibility: .classicOnly,
            local_has_apple_provider: false,
            local_has_liboqs_provider: false,
            compile_time_has_apple_pqc_sdk: false,
            trust_store_state: .trusted,
            bootstrap_rekey_state: .bootstrap
        )

        let rekeyInput = PolicyDecisionInput(
            policy: .prefer,
            peer_capability_visibility: .pqcVisible,
            local_has_apple_provider: false,
            local_has_liboqs_provider: true,
            compile_time_has_apple_pqc_sdk: false,
            trust_store_state: .trusted,
            bootstrap_rekey_state: .rekey
        )

        let beforeRekey = PolicyDecisionContract.evaluate(bootstrapInput)
        let afterRekey = PolicyDecisionContract.evaluate(rekeyInput)

        XCTAssertEqual(beforeRekey.selected_suite_wire_id, CryptoSuite.x25519Ed25519.wireId)
        XCTAssertEqual(afterRekey.selected_suite_wire_id, CryptoSuite.mlkem768.wireId)
    }

    func testReconnectRestoreKeepsDecisionStable() {
        let input = PolicyDecisionInput(
            policy: .strict,
            peer_capability_visibility: .pqcVisible,
            local_has_apple_provider: true,
            local_has_liboqs_provider: true,
            compile_time_has_apple_pqc_sdk: true,
            trust_store_state: .trusted,
            bootstrap_rekey_state: .rekey
        )

        let initial = PolicyDecisionContract.evaluate(input)
        let reconnect = PolicyDecisionContract.evaluate(input)
        XCTAssertEqual(initial, reconnect)
    }

    func testDuplicateMessageIdempotenceKeepsSnapshotStable() {
        let input = PolicyDecisionInput(
            policy: .prefer,
            peer_capability_visibility: .classicOnly,
            local_has_apple_provider: false,
            local_has_liboqs_provider: true,
            compile_time_has_apple_pqc_sdk: false,
            trust_store_state: .trusted,
            bootstrap_rekey_state: .rekey
        )

        let expected = PolicyDecisionContract.evaluate(input)
        for _ in 0..<5 {
            XCTAssertEqual(PolicyDecisionContract.evaluate(input), expected)
        }
    }
}
