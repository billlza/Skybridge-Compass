import XCTest
@testable import SkyBridgeCore

final class CapabilityResolutionParityTests: XCTestCase {
    func testCompileFlagMasksAppleProviderAvailability() {
        let input = PolicyDecisionInput(
            policy: .prefer,
            peer_capability_visibility: .pqcVisible,
            local_has_apple_provider: true,
            local_has_liboqs_provider: false,
            compile_time_has_apple_pqc_sdk: false,
            trust_store_state: .trusted,
            bootstrap_rekey_state: .rekey
        )

        let snapshot = PolicyDecisionContract.evaluate(input)
        XCTAssertEqual(snapshot.selected_tier, CryptoTier.classic.rawValue)
        XCTAssertEqual(snapshot.selected_suite_wire_id, CryptoSuite.x25519Ed25519.wireId)
    }

    func testProviderTierResolutionMatrix() {
        for availability in PolicyDecisionTestVectors.localProviderAvailability {
            for compileFlag in [false, true] {
                let input = PolicyDecisionInput(
                    policy: .prefer,
                    peer_capability_visibility: .pqcVisible,
                    local_has_apple_provider: availability.apple,
                    local_has_liboqs_provider: availability.liboqs,
                    compile_time_has_apple_pqc_sdk: compileFlag,
                    trust_store_state: .trusted,
                    bootstrap_rekey_state: .rekey
                )
                let snapshot = PolicyDecisionContract.evaluate(input)

                let expectsNative = availability.apple && compileFlag
                if expectsNative {
                    XCTAssertEqual(snapshot.selected_tier, CryptoTier.nativePQC.rawValue)
                } else if availability.liboqs {
                    XCTAssertEqual(snapshot.selected_tier, CryptoTier.liboqsPQC.rawValue)
                } else {
                    XCTAssertEqual(snapshot.selected_tier, CryptoTier.classic.rawValue)
                }
            }
        }
    }

    func testDecisionContractDeterminismAcrossMatrix() {
        for input in PolicyDecisionTestVectors.allInputs() {
            let first = PolicyDecisionContract.evaluate(input)
            let second = PolicyDecisionContract.evaluate(input)
            XCTAssertEqual(first, second)
        }
    }
}
