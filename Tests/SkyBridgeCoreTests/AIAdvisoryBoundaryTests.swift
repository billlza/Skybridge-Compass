import Foundation
import XCTest
@testable import SkyBridgeCore

final class AIAdvisoryBoundaryTests: XCTestCase {
    private func encodedJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private func assertEncodedJSON<T: Encodable>(
        _ value: T,
        excludes forbiddenFragments: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let json = try encodedJSON(value)
        for fragment in forbiddenFragments {
            XCTAssertFalse(
                json.contains(fragment),
                "AI advisory DTO must not expose sensitive fragment: \(fragment). JSON: \(json)",
                file: file,
                line: line
            )
        }
    }

    func testAnomalyAdvisoryInputRedactsRawIdentifiersAndLogs() throws {
        let sensitiveFragments = [
            "SECRET-DEVICE-ID",
            "SECRET-SESSION-ID",
            "SECRET-FINGERPRINT",
            "Sensitive iPad",
            "10.0.0.42",
            "Documents/Client NDA.pdf",
            "123456",
            "raw handshake transcript",
            "SECRET-TOKEN"
        ]
        let anomaly = DetectedAnomaly(
            type: .suspiciousFileAccess,
            description: "Sensitive iPad tried Client NDA.pdf from 10.0.0.42",
            sourceDeviceID: "SECRET-DEVICE-ID",
            confidence: 0.93,
            context: [
                "deviceName": "Sensitive iPad",
                "sessionId": "SECRET-SESSION-ID",
                "protocolFingerprint": "SECRET-FINGERPRINT",
                "peerEndpoint": "10.0.0.42:8443",
                "filePath": "Documents/Client NDA.pdf",
                "connectionCode": "123456",
                "handshakeTranscript": "raw handshake transcript",
                "token": "SECRET-TOKEN"
            ]
        )

        let dto = try AIAdvisoryRedactor.input(from: anomaly)

        XCTAssertEqual(dto.subject, .anomalyExplanation)
        XCTAssertTrue(dto.sensitiveInputsRedacted)
        XCTAssertFalse(dto.rawLogsIncluded)
        XCTAssertTrue(dto.advisoryOnly)
        XCTAssertTrue(dto.facts.contains(AIAdvisoryFactDTO(name: "source_identifier", value: "present_redacted")))
        XCTAssertTrue(
            dto.facts.contains { $0.name == "context_categories" && $0.value.contains("crypto_metadata") }
        )
        XCTAssertTrue(
            dto.facts.contains { $0.name == "context_categories" && $0.value.contains("session_metadata") }
        )

        try assertEncodedJSON(dto, excludes: sensitiveFragments)
    }

    func testPolicyDecisionAdvisoryInputPreservesOnlySanitizedDeterministicFields() throws {
        let maliciousSnapshot = PolicyDecisionSnapshot(
            policy: "strict SECRET-POLICY",
            selected_tier: "nativePQC SECRET-TIER",
            selected_suite_wire_id: 49152,
            fallback_allowed: true,
            event_code: "strict.pqc_selected SECRET-EVENT",
            ui_error_category: "SECRET-CATEGORY"
        )
        let maliciousDTO = try AIAdvisoryRedactor.input(from: maliciousSnapshot)

        XCTAssertTrue(maliciousDTO.sensitiveInputsRedacted)
        XCTAssertFalse(maliciousDTO.rawLogsIncluded)
        XCTAssertTrue(maliciousDTO.advisoryOnly)
        XCTAssertTrue(maliciousDTO.facts.contains(AIAdvisoryFactDTO(name: "policy", value: "unknown")))
        XCTAssertTrue(maliciousDTO.facts.contains(AIAdvisoryFactDTO(name: "selected_tier", value: "unknown")))
        XCTAssertTrue(maliciousDTO.facts.contains(AIAdvisoryFactDTO(name: "event_code", value: "unknown")))
        XCTAssertTrue(maliciousDTO.facts.contains(AIAdvisoryFactDTO(name: "ui_error_category", value: "unknown")))
        try assertEncodedJSON(
            maliciousDTO,
            excludes: ["SECRET-POLICY", "SECRET-TIER", "SECRET-EVENT", "SECRET-CATEGORY"]
        )

        let deterministicSnapshot = PolicyDecisionContract.evaluate(
            PolicyDecisionInput(
                policy: .strict,
                peer_capability_visibility: .pqcVisible,
                local_has_apple_provider: false,
                local_has_liboqs_provider: false,
                compile_time_has_apple_pqc_sdk: false,
                trust_store_state: .trusted,
                bootstrap_rekey_state: .rekey
            )
        )
        let deterministicDTO = try AIAdvisoryRedactor.input(from: deterministicSnapshot)

        XCTAssertTrue(
            deterministicDTO.facts.contains(
                AIAdvisoryFactDTO(
                    name: "event_code",
                    value: PolicyDecisionEventCode.strictPQCProviderUnavailable.rawValue
                )
            )
        )
        XCTAssertTrue(
            deterministicDTO.facts.contains(
                AIAdvisoryFactDTO(
                    name: "ui_error_category",
                    value: PolicyDecisionUIErrorCategory.pqcRequiredUnavailable.rawValue
                )
            )
        )
    }

    func testAdvisoryOutputSchemaHasNoAuthorityActionFields() throws {
        let output = AIAdvisoryOutputDTO(
            summary: "Explain the deterministic decision to the user.",
            confidenceBand: .medium,
            evidenceLabels: ["anomaly_type", "policy_decision"]
        )
        let data = try JSONEncoder().encode(output)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let keys = Set(object.keys)

        XCTAssertEqual(keys, ["authority", "summary", "confidenceBand", "evidenceLabels"])
        XCTAssertEqual(object["authority"] as? String, AIAdvisoryOutputDTO.Authority.advisoryOnly.rawValue)
        for forbiddenKey in ["block", "allow", "trust", "admission", "provider", "pqc", "release_eligible", "releaseEligible"] {
            XCTAssertFalse(keys.contains(forbiddenKey))
        }
    }

    func testInputDTOCannotDecodeUnsafeAdvisoryBoundaryFlags() throws {
        let safeDTO = try AIAdvisoryInputDTO(
            subject: .policyDecisionExplanation,
            facts: [AIAdvisoryFactDTO(name: "policy", value: "strict")]
        )

        let safeData = try JSONEncoder().encode(safeDTO)
        let decoded = try JSONDecoder().decode(AIAdvisoryInputDTO.self, from: safeData)
        XCTAssertTrue(decoded.sensitiveInputsRedacted)
        XCTAssertFalse(decoded.rawLogsIncluded)
        XCTAssertTrue(decoded.advisoryOnly)

        let unsafePayload = """
        {
          "subject": "policy_decision_explanation",
          "facts": [],
          "sensitiveInputsRedacted": false,
          "rawLogsIncluded": true,
          "advisoryOnly": false
        }
        """.data(using: .utf8)!

        XCTAssertThrowsError(
            try JSONDecoder().decode(AIAdvisoryInputDTO.self, from: unsafePayload),
            "Decoded AI advisory input must fail closed if it claims raw logs, unredacted input, or non-advisory authority."
        )
    }

    func testInputDTORejectsUnknownFactNamesAndRawLookingValues() throws {
        XCTAssertThrowsError(
            try AIAdvisoryInputDTO(
                subject: .anomalyExplanation,
                facts: [
                    AIAdvisoryFactDTO(name: "device_id", value: "SECRET-DEVICE-ID")
                ]
            ),
            "Programmatic AI advisory input must fail closed when a caller bypasses the redactor with a raw identifier-shaped fact."
        )

        let unsafePolicyPayload = """
        {
          "subject": "policy_decision_explanation",
          "facts": [
            { "name": "policy", "value": "strict" },
            { "name": "selected_suite_wire_id", "value": "fingerprint:SECRET" }
          ],
          "sensitiveInputsRedacted": true,
          "rawLogsIncluded": false,
          "advisoryOnly": true
        }
        """.data(using: .utf8)!

        XCTAssertThrowsError(
            try JSONDecoder().decode(AIAdvisoryInputDTO.self, from: unsafePolicyPayload),
            "Decoded AI advisory input must reject values outside the bounded fact schema even when the safety flags are true."
        )
    }
}
