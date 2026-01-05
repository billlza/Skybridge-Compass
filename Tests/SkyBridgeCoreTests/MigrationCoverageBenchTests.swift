// SPDX-License-Identifier: MIT
// SkyBridge Compass - Migration Coverage Bench Tests

import XCTest
import CryptoKit
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class MigrationCoverageBenchTests: XCTestCase {
    private var shouldRunMigrationBench: Bool {
        ProcessInfo.processInfo.environment["SKYBRIDGE_RUN_MIGRATION_BENCH"] == "1"
    }

    private var iterations: Int {
        Int(ProcessInfo.processInfo.environment["SKYBRIDGE_MIGRATION_ITERATIONS"] ?? "") ?? 1000
    }

    func testMigrationCoverageBench() async throws {
        try XCTSkipUnless(shouldRunMigrationBench, "Set SKYBRIDGE_RUN_MIGRATION_BENCH=1 to run migration coverage bench")

        let scenarios = Self.coverageScenarios()
        var rows: [String] = []

        for scenario in scenarios {
            var allowedCount = 0
            var rejectedCount = 0
            for _ in 0..<iterations {
                let precondition = LegacyTrustPreconditionChecker.check(
                    deviceId: scenario.deviceId,
                    trustRecord: scenario.trustRecord,
                    pairingContext: scenario.pairingContext
                )
                if precondition.isSatisfied {
                    allowedCount += 1
                } else {
                    rejectedCount += 1
                }
            }

            rows.append([
                scenario.label,
                scenario.preconditionType.rawValue,
                scenario.pairingChannel ?? "none",
                scenario.pairingVerified ? "true" : "false",
                scenario.hasTrustRecord ? "true" : "false",
                scenario.hasLegacyKey ? "true" : "false",
                scenario.expectedSatisfied ? "true" : "false",
                "\(iterations)",
                "\(allowedCount)",
                "\(rejectedCount)"
            ].joined(separator: ","))
        }

        try writeCSV(rows: rows)
    }

    private func writeCSV(rows: [String]) throws {
        let artifactsDir = URL(fileURLWithPath: "Artifacts")
        try FileManager.default.createDirectory(at: artifactsDir, withIntermediateDirectories: true)

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateString = dateFormatter.string(from: Date())
        let csvPath = artifactsDir.appendingPathComponent("migration_coverage_\(dateString).csv")

        var content = "scenario,precondition_type,pairing_channel,pairing_verified,has_trust_record,has_legacy_key,expected_satisfied,iterations,allowed_count,rejected_count\n"
        for row in rows {
            content += row + "\n"
        }

        try content.write(to: csvPath, atomically: true, encoding: .utf8)
        SkyBridgeLogger.test.info("[MIGRATION-BENCH] CSV written to: \(csvPath.path)")
    }
}

@available(macOS 14.0, iOS 17.0, *)
private extension MigrationCoverageBenchTests {
    struct CoverageScenario {
        let label: String
        let deviceId: String
        let trustRecord: TrustRecord?
        let pairingContext: PairingContext?
        let preconditionType: LegacyTrustPreconditionType
        let pairingChannel: String?
        let pairingVerified: Bool
        let hasTrustRecord: Bool
        let hasLegacyKey: Bool
        let expectedSatisfied: Bool
    }

    static func coverageScenarios() -> [CoverageScenario] {
        [
            makeScenario(
                label: "stranger_none",
                trustRecord: nil,
                pairingContext: nil,
                expectedSatisfied: false
            ),
            makeScenario(
                label: "network_discovery_unverified",
                trustRecord: nil,
                pairingContext: PairingContext(channelType: .networkDiscovery, isVerified: false),
                expectedSatisfied: false
            ),
            makeScenario(
                label: "qr_verified",
                trustRecord: nil,
                pairingContext: PairingContext(channelType: .qrCode, isVerified: true),
                expectedSatisfied: true
            ),
            makeScenario(
                label: "qr_unverified",
                trustRecord: nil,
                pairingContext: PairingContext(channelType: .qrCode, isVerified: false),
                expectedSatisfied: false
            ),
            makeScenario(
                label: "pake_verified",
                trustRecord: nil,
                pairingContext: PairingContext(channelType: .pake, isVerified: true),
                expectedSatisfied: true
            ),
            makeScenario(
                label: "local_pairing_verified",
                trustRecord: nil,
                pairingContext: PairingContext(channelType: .localPairing, isVerified: true),
                expectedSatisfied: true
            ),
            makeScenario(
                label: "local_pairing_unverified",
                trustRecord: nil,
                pairingContext: PairingContext(channelType: .localPairing, isVerified: false),
                expectedSatisfied: false
            ),
            makeScenario(
                label: "trust_record_with_legacy",
                trustRecord: makeTrustRecord(hasLegacyKey: true),
                pairingContext: nil,
                expectedSatisfied: true
            ),
            makeScenario(
                label: "trust_record_without_legacy",
                trustRecord: makeTrustRecord(hasLegacyKey: false),
                pairingContext: nil,
                expectedSatisfied: false
            ),
            makeScenario(
                label: "trust_record_with_legacy_and_qr",
                trustRecord: makeTrustRecord(hasLegacyKey: true),
                pairingContext: PairingContext(channelType: .qrCode, isVerified: true),
                expectedSatisfied: true
            ),
            makeScenario(
                label: "trust_record_without_legacy_with_qr",
                trustRecord: makeTrustRecord(hasLegacyKey: false),
                pairingContext: PairingContext(channelType: .qrCode, isVerified: true),
                expectedSatisfied: true
            ),
            makeScenario(
                label: "trust_record_without_legacy_with_unverified_qr",
                trustRecord: makeTrustRecord(hasLegacyKey: false),
                pairingContext: PairingContext(channelType: .qrCode, isVerified: false),
                expectedSatisfied: false
            )
        ]
    }

    static func makeScenario(
        label: String,
        trustRecord: TrustRecord?,
        pairingContext: PairingContext?,
        expectedSatisfied: Bool
    ) -> CoverageScenario {
        let deviceId = "bench-device-\(label)"
        let precondition = LegacyTrustPreconditionChecker.check(
            deviceId: deviceId,
            trustRecord: trustRecord,
            pairingContext: pairingContext
        )
        return CoverageScenario(
            label: label,
            deviceId: deviceId,
            trustRecord: trustRecord,
            pairingContext: pairingContext,
            preconditionType: precondition.type,
            pairingChannel: pairingContext?.channelType.rawValue,
            pairingVerified: pairingContext?.isVerified ?? false,
            hasTrustRecord: trustRecord != nil,
            hasLegacyKey: trustRecord?.legacyP256PublicKey != nil,
            expectedSatisfied: expectedSatisfied
        )
    }

    static func makeTrustRecord(hasLegacyKey: Bool) -> TrustRecord {
        let publicKey = Data(repeating: 0x01, count: 32)
        let legacyKey = hasLegacyKey ? Data([0x04] + Array(repeating: 0x01, count: 64)) : nil
        let fingerprint = SHA256.hash(data: publicKey).compactMap { String(format: "%02x", $0) }.joined()
        return TrustRecord(
            deviceId: "bench-trust-record",
            pubKeyFP: fingerprint,
            publicKey: publicKey,
            legacyP256PublicKey: legacyKey,
            signature: Data(repeating: 0x02, count: 64)
        )
    }
}
