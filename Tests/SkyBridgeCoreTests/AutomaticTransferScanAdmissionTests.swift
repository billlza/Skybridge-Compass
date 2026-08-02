import XCTest
@testable import SkyBridgeCore

final class AutomaticTransferScanAdmissionTests: XCTestCase {
    private let fileURL = URL(fileURLWithPath: "/tmp/automatic-transfer-scan-admission.bin")

    func testOnlySafeVerdictIsAutomaticallyAdmitted() {
        XCTAssertEqual(result(verdict: .safe).automaticTransferAdmission, .allow)
    }

    func testUnsafeVerdictProducesThreatBlock() {
        let scanResult = FileScanResult(
            fileURL: fileURL,
            verdict: .unsafe,
            threats: [
                ThreatHit(
                    signatureId: "test-signature",
                    signatureName: "Test threat",
                    category: "malware",
                    matchType: .string,
                    region: .full,
                    snippetHash: "redacted",
                    confidence: 1
                )
            ]
        )

        XCTAssertEqual(
            scanResult.automaticTransferAdmission,
            .block(.unsafe(threatName: "Test threat"))
        )
    }

    func testWarningVerdictRequiresReviewEvenThoughLegacyIsSafeIsTrue() {
        let scanResult = result(
            verdict: .warning,
            warningCodes: ["SCAN_TIMEOUT", "PERMISSION_DENIED", "SCAN_TIMEOUT"]
        )

        XCTAssertTrue(scanResult.isSafe, "Legacy history compatibility must remain unchanged")
        XCTAssertEqual(
            scanResult.automaticTransferAdmission,
            .block(.reviewRequired(warningCodes: ["PERMISSION_DENIED", "SCAN_TIMEOUT"]))
        )
    }

    func testUnknownVerdictIsIncompleteAndBlocked() {
        let scanResult = result(
            verdict: .unknown,
            warningCodes: ["RESOURCE_EXHAUSTED"]
        )

        XCTAssertEqual(
            scanResult.automaticTransferAdmission,
            .block(
                .incomplete(
                    verdict: .unknown,
                    warningCodes: ["RESOURCE_EXHAUSTED"]
                )
            )
        )
    }

    func testReviewAndIncompleteMapToTypedNonThreatErrors() {
        let reviewReason = AutomaticTransferScanBlockReason.reviewRequired(
            warningCodes: ["NOT_NOTARIZED"]
        )
        let incompleteReason = AutomaticTransferScanBlockReason.incomplete(
            verdict: .unknown,
            warningCodes: ["PERMISSION_DENIED"]
        )

        guard case .securityScanReviewRequired(let reviewCodes) = reviewReason.managerError else {
            return XCTFail("Warning must not be reported as malware")
        }
        XCTAssertEqual(reviewCodes, ["NOT_NOTARIZED"])

        guard case .securityScanIncomplete(let verdict, let incompleteCodes) = incompleteReason.engineError else {
            return XCTFail("Incomplete scans must preserve their distinct error type")
        }
        XCTAssertEqual(verdict, .unknown)
        XCTAssertEqual(incompleteCodes, ["PERMISSION_DENIED"])
    }

    private func result(
        verdict: ScanVerdict,
        warningCodes: [String] = []
    ) -> FileScanResult {
        FileScanResult(
            fileURL: fileURL,
            verdict: verdict,
            warnings: warningCodes.map {
                ScanWarning(code: $0, message: "test", severity: .warning)
            }
        )
    }
}
