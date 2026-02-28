import XCTest
@testable import SkyBridgeCompass_iOS

@available(iOS 17.0, *)
final class ObservabilityContractTests: XCTestCase {
    func testStrictModeFailureProducesExplicitNonSilentReason() {
        let snapshot = PolicyDecisionContract.evaluate(
            PolicyDecisionInput(
                policy: .strict,
                peer_capability_visibility: .classicOnly,
                local_has_apple_provider: false,
                local_has_liboqs_provider: false,
                compile_time_has_apple_pqc_sdk: false,
                trust_store_state: .untrusted,
                bootstrap_rekey_state: .bootstrap
            )
        )

        XCTAssertEqual(snapshot.event_code, PolicyDecisionEventCode.strictPQCProviderUnavailable.rawValue)
        XCTAssertNotEqual(snapshot.ui_error_category, PolicyDecisionUIErrorCategory.none.rawValue)
    }

    func testTelemetrySchemaFieldsRemainFixed() {
        let snapshot = PolicyDecisionContract.evaluate(
            PolicyDecisionInput(
                policy: .prefer,
                peer_capability_visibility: .unknown,
                local_has_apple_provider: true,
                local_has_liboqs_provider: true,
                compile_time_has_apple_pqc_sdk: true,
                trust_store_state: .trusted,
                bootstrap_rekey_state: .rekey
            )
        )

        XCTAssertEqual(Set(snapshot.telemetry_fields.keys), PolicyDecisionSnapshot.required_telemetry_keys)
    }

    func testUIFacingReasonCategorySetIsStable() {
        let allowedCategories = Set(PolicyDecisionUIErrorCategory.allCases.map(\.rawValue))

        for input in PolicyDecisionTestVectors.allInputs() {
            let snapshot = PolicyDecisionContract.evaluate(input)
            XCTAssertTrue(allowedCategories.contains(snapshot.ui_error_category))
        }
    }
}
