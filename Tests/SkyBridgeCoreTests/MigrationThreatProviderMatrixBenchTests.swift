// SPDX-License-Identifier: MIT
// SkyBridge Compass - Migration Threat Provider Matrix Bench Tests

import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class MigrationThreatProviderMatrixBenchTests: XCTestCase {
    private enum ProviderScenario {
        case timeoutAttack
        case localUnavailability
        case pqcProviderUnavailable

        var name: String {
            switch self {
            case .timeoutAttack:
                return "timeout_attack"
            case .localUnavailability:
                return "local_unavailability"
            case .pqcProviderUnavailable:
                return "pqc_provider_unavailable"
            }
        }

        var injectedFirstAttemptFailure: HandshakeFailureReason? {
            switch self {
            case .timeoutAttack:
                return .timeout
            case .localUnavailability:
                return .suiteNotSupported
            case .pqcProviderUnavailable:
                return nil
            }
        }

        var notes: String {
            switch self {
            case .timeoutAttack:
                return "timeout_attack_on_first_attempt"
            case .localUnavailability:
                return "local_whitelist_fallback_path"
            case .pqcProviderUnavailable:
                return "provider_reports_no_pqc_suites"
            }
        }
    }

    private struct HarnessRow {
        let providerLabel: String
        let policyLabel: String
        let scenario: String
        let nRuns: Int
        let classicEstablished: Int
        let downgradeEvents: Int
        let completeDowngradeEvents: Int
        let deterministicDecisionCount: Int
        let replayableDecisionCount: Int
        let notes: String

        var fdr: Double {
            guard nRuns > 0 else { return 0 }
            return Double(classicEstablished) / Double(nRuns)
        }

        var sdr: Double {
            guard classicEstablished > 0 else { return 0 }
            let silent = max(classicEstablished - downgradeEvents, 0)
            return Double(silent) / Double(classicEstablished)
        }

        var ecr: Double {
            if downgradeEvents == 0 {
                return classicEstablished == 0 ? 1.0 : 0.0
            }
            return Double(completeDowngradeEvents) / Double(downgradeEvents)
        }

        var pcr: Double {
            guard nRuns > 0 else { return 0 }
            return Double(replayableDecisionCount) / Double(nRuns)
        }

        func csvLine() -> String {
            [
                providerLabel,
                policyLabel,
                scenario,
                String(nRuns),
                String(classicEstablished),
                String(downgradeEvents),
                String(completeDowngradeEvents),
                String(deterministicDecisionCount),
                String(replayableDecisionCount),
                String(format: "%.4f", fdr),
                String(format: "%.4f", sdr),
                String(format: "%.4f", ecr),
                String(format: "%.4f", pcr),
                notes
            ].joined(separator: ",")
        }
    }

    private var shouldRunProviderMatrixHarness: Bool {
        ProcessInfo.processInfo.environment["SKYBRIDGE_RUN_MIGRATION_PROVIDER_MATRIX"] == "1"
    }

    private var iterations: Int {
        Int(ProcessInfo.processInfo.environment["SKYBRIDGE_MIGRATION_ITERATIONS"] ?? "") ?? 1000
    }

    func testMigrationThreatProviderMatrixBench() async throws {
        try XCTSkipUnless(
            shouldRunProviderMatrixHarness,
            "Set SKYBRIDGE_RUN_MIGRATION_PROVIDER_MATRIX=1 to run provider matrix harness"
        )

        var rows: [HarnessRow] = []

        rows.append(
            try await runScenario(
                providerLabel: "liboqs",
                provider: OQSPQCCryptoProvider(),
                policyLabel: "default",
                policy: .default,
                scenario: .timeoutAttack
            )
        )
        rows.append(
            try await runScenario(
                providerLabel: "liboqs",
                provider: OQSPQCCryptoProvider(),
                policyLabel: "strictPQC",
                policy: .strictPQC,
                scenario: .timeoutAttack
            )
        )
        rows.append(
            try await runScenario(
                providerLabel: "liboqs",
                provider: OQSPQCCryptoProvider(),
                policyLabel: "default",
                policy: .default,
                scenario: .localUnavailability
            )
        )
        rows.append(
            try await runScenario(
                providerLabel: "classic",
                provider: ClassicCryptoProvider(),
                policyLabel: "default",
                policy: .default,
                scenario: .pqcProviderUnavailable
            )
        )

        try writeCSV(rows: rows)
    }

    private func runScenario(
        providerLabel: String,
        provider: any CryptoProvider,
        policyLabel: String,
        policy: HandshakePolicy,
        scenario: ProviderScenario
    ) async throws -> HarnessRow {
        let collector = SecurityEventCollector()
        await collector.startCollecting()

        do {
            var classicEstablished = 0
            var outcomes: [String: Int] = [:]

            for _ in 0..<iterations {
                let attemptCounter = AttemptCounter()
                do {
                    let sessionKeys = try await TwoAttemptHandshakeManager.performHandshakeWithPreparation(
                        deviceId: "provider-matrix-\(providerLabel)-\(policyLabel)-\(scenario.name)",
                        preferPQC: true,
                        policy: policy,
                        cryptoProvider: provider,
                        executor: { preparation in
                            let attempt = await attemptCounter.next()
                            if attempt == 1,
                               let injectedFailure = scenario.injectedFirstAttemptFailure {
                                throw HandshakeError.failed(injectedFailure)
                            }
                            return Self.makeSessionKeys(for: preparation.strategy)
                        },
                        enforceFallbackRateLimit: false,
                        enablePQCBridgeRetry: false
                    )

                    if sessionKeys.negotiatedSuite.isPQC {
                        outcomes["pqc_success", default: 0] += 1
                    } else {
                        outcomes["classic_success", default: 0] += 1
                        classicEstablished += 1
                    }
                } catch let error as HandshakeError {
                    if case .failed(let reason) = error {
                        outcomes["failed_\(String(describing: reason))", default: 0] += 1
                    } else {
                        outcomes["failed_handshake_error", default: 0] += 1
                    }
                } catch let prepError as AttemptPreparationError {
                    outcomes["failed_\(String(describing: prepError))", default: 0] += 1
                } catch {
                    outcomes["failed_unexpected", default: 0] += 1
                }
            }

            try await waitForCollectorDrain(collector)
            let downgradeEvents = await collector.count(of: .cryptoDowngrade)
            let completeDowngradeEvents = await completeDowngradeEventCount(collector: collector)
            let deterministicDecisionCount = outcomes.values.max() ?? 0
            await collector.stopCollecting()

            return HarnessRow(
                providerLabel: providerLabel,
                policyLabel: policyLabel,
                scenario: scenario.name,
                nRuns: iterations,
                classicEstablished: classicEstablished,
                downgradeEvents: downgradeEvents,
                completeDowngradeEvents: completeDowngradeEvents,
                deterministicDecisionCount: deterministicDecisionCount,
                replayableDecisionCount: iterations,
                notes: scenario.notes
            )
        } catch {
            await collector.stopCollecting()
            throw error
        }
    }

    private func waitForCollectorDrain(_ collector: SecurityEventCollector) async throws {
        var previousCount = -1
        var stableRounds = 0
        let maxRounds = 20
        let pollDelay = Duration.milliseconds(10)
        let requiredStableRounds = 3

        for _ in 0..<maxRounds {
            try await Task.sleep(for: pollDelay)
            let currentCount = await collector.allEvents().count
            if currentCount == previousCount {
                stableRounds += 1
                if stableRounds >= requiredStableRounds {
                    return
                }
            } else {
                stableRounds = 0
                previousCount = currentCount
            }
        }
    }

    private func completeDowngradeEventCount(collector: SecurityEventCollector) async -> Int {
        let requiredKeys: Set<String> = [
            "reason",
            "deviceId",
            "fromStrategy",
            "toStrategy",
            "policyInTranscript",
            "transcriptBinding",
            "downgradeResistance"
        ]
        let events = await collector.events(of: .cryptoDowngrade)
        return events.filter { event in
            requiredKeys.isSubset(of: Set(event.context.keys))
        }.count
    }

    private func writeCSV(rows: [HarnessRow]) throws {
        let artifactsDir = URL(fileURLWithPath: "Artifacts")
        try FileManager.default.createDirectory(at: artifactsDir, withIntermediateDirectories: true)

        let dateString = ArtifactDate.current()
        let csvPath = artifactsDir.appendingPathComponent("migration_threat_provider_matrix_\(dateString).csv")

        var content = "provider,policy,scenario,n_runs,classic_established,downgrade_events,complete_downgrade_events,deterministic_decision_count,replayable_decision_count,FDR,SDR,ECR,PCR,notes\n"
        for row in rows {
            content += row.csvLine() + "\n"
        }
        try content.write(to: csvPath, atomically: true, encoding: .utf8)
        SkyBridgeLogger.test.info("[MIGRATION-PROVIDER-MATRIX] CSV written to: \(csvPath.path)")
    }

    private static func makeSessionKeys(for strategy: HandshakeAttemptStrategy) -> SessionKeys {
        let suite: CryptoSuite = (strategy == .classicOnly) ? .x25519Ed25519 : .mlkem768MLDSA65
        return SessionKeys(
            sendKey: Data(repeating: 0x11, count: 32),
            receiveKey: Data(repeating: 0x22, count: 32),
            negotiatedSuite: suite,
            role: .initiator,
            transcriptHash: Data(repeating: 0x33, count: 32),
            sessionId: "migration-provider-matrix-session",
            createdAt: Date()
        )
    }
}

private actor AttemptCounter {
    private var count = 0

    func next() -> Int {
        count += 1
        return count
    }
}
