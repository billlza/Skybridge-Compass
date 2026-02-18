// SPDX-License-Identifier: MIT
// SkyBridge Compass - Fleet-Level Migration Behavior Bench Tests

import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class MigrationFleetBehaviorBenchTests: XCTestCase {
    private struct FleetConfig {
        let label: String
        let pqcCapableRatio: Double
        let cooldownEnabled: Bool
    }

    private struct FleetRow {
        let label: String
        let sessions: Int
        let peerPool: Int
        let pqcCapableRatio: Double
        let timeoutAttackRate: Double
        let cooldownEnabled: Bool
        let pqcSuccess: Int
        let classicFallbackSuccess: Int
        let failedRateLimited: Int
        let failedTimeout: Int
        let failedOther: Int
        let downgradeEvents: Int
        let meanConnectSuccessMs: Double

        var successCount: Int {
            pqcSuccess + classicFallbackSuccess
        }

        var successRate: Double {
            guard sessions > 0 else { return 0 }
            return Double(successCount) / Double(sessions)
        }

        var downgradePer1k: Double {
            guard sessions > 0 else { return 0 }
            return Double(downgradeEvents) * 1000.0 / Double(sessions)
        }

        private func decisionShare(_ count: Int) -> Double {
            guard sessions > 0 else { return 0 }
            return Double(count) / Double(sessions)
        }

        func csvLine() -> String {
            [
                label,
                String(sessions),
                String(peerPool),
                String(format: "%.2f", pqcCapableRatio),
                String(format: "%.2f", timeoutAttackRate),
                cooldownEnabled ? "1" : "0",
                String(pqcSuccess),
                String(classicFallbackSuccess),
                String(failedRateLimited),
                String(failedTimeout),
                String(failedOther),
                String(downgradeEvents),
                String(format: "%.4f", successRate),
                String(format: "%.2f", downgradePer1k),
                String(format: "%.3f", meanConnectSuccessMs),
                String(format: "%.4f", decisionShare(pqcSuccess)),
                String(format: "%.4f", decisionShare(classicFallbackSuccess)),
                String(format: "%.4f", decisionShare(failedRateLimited)),
                String(format: "%.4f", decisionShare(failedTimeout)),
                String(format: "%.4f", decisionShare(failedOther))
            ].joined(separator: ",")
        }
    }

    private var shouldRunFleetBench: Bool {
        ProcessInfo.processInfo.environment["SKYBRIDGE_RUN_MIGRATION_FLEET_BENCH"] == "1"
    }

    private var sessions: Int {
        Int(ProcessInfo.processInfo.environment["SKYBRIDGE_MIGRATION_FLEET_SESSIONS"] ?? "") ?? 10_000
    }

    private var peerPool: Int {
        Int(ProcessInfo.processInfo.environment["SKYBRIDGE_MIGRATION_FLEET_PEERS"] ?? "") ?? 2_000
    }

    private var timeoutAttackRate: Double {
        let raw = Double(ProcessInfo.processInfo.environment["SKYBRIDGE_MIGRATION_FLEET_TIMEOUT_ATTACK_PCT"] ?? "") ?? 0.05
        return min(max(raw, 0.0), 1.0)
    }

    func testMigrationFleetBehaviorBench() async throws {
        try XCTSkipUnless(
            shouldRunFleetBench,
            "Set SKYBRIDGE_RUN_MIGRATION_FLEET_BENCH=1 to run fleet behavior bench"
        )

        let configs: [FleetConfig] = [
            .init(label: "fleet_r20_cooldown_on", pqcCapableRatio: 0.20, cooldownEnabled: true),
            .init(label: "fleet_r20_cooldown_off", pqcCapableRatio: 0.20, cooldownEnabled: false),
            .init(label: "fleet_r50_cooldown_on", pqcCapableRatio: 0.50, cooldownEnabled: true),
            .init(label: "fleet_r50_cooldown_off", pqcCapableRatio: 0.50, cooldownEnabled: false),
            .init(label: "fleet_r80_cooldown_on", pqcCapableRatio: 0.80, cooldownEnabled: true),
            .init(label: "fleet_r80_cooldown_off", pqcCapableRatio: 0.80, cooldownEnabled: false)
        ]

        var rows: [FleetRow] = []
        for config in configs {
            rows.append(try await runFleetScenario(config: config))
        }
        try writeCSV(rows: rows)
    }

    private func runFleetScenario(config: FleetConfig) async throws -> FleetRow {
        let pqcProvider = OQSPQCCryptoProvider()
        let classicProvider = ClassicCryptoProvider()
        var rng = XorShift64Star(seed: seed(for: config.label))
        let clock = ContinuousClock()

        var pqcSuccess = 0
        var classicFallbackSuccess = 0
        var failedRateLimited = 0
        var failedTimeout = 0
        var failedOther = 0
        var connectSuccessTotalMs = 0.0

        for _ in 0..<sessions {
            let peerIndex = Int(rng.next() % UInt64(max(peerPool, 1)))
            let deviceId = "\(config.label)-peer-\(peerIndex)"
            let provider: any CryptoProvider = rng.nextDouble() < config.pqcCapableRatio ? pqcProvider : classicProvider
            let injectTimeout = rng.nextDouble() < timeoutAttackRate
            let attemptCounter = AttemptCounter()
            let start = clock.now

            do {
                let sessionKeys = try await TwoAttemptHandshakeManager.performHandshakeWithPreparation(
                    deviceId: deviceId,
                    preferPQC: true,
                    policy: .default,
                    cryptoProvider: provider,
                    executor: { preparation in
                        let attempt = await attemptCounter.next()
                        if preparation.strategy == .pqcOnly, attempt == 1, injectTimeout {
                            throw HandshakeError.failed(.timeout)
                        }
                        return Self.makeSessionKeys(for: preparation.strategy)
                    },
                    enforceFallbackRateLimit: config.cooldownEnabled,
                    enablePQCBridgeRetry: false
                )

                if sessionKeys.negotiatedSuite.isPQC {
                    pqcSuccess += 1
                } else {
                    classicFallbackSuccess += 1
                }
                let elapsedMs = Double(start.duration(to: clock.now).components.attoseconds) / 1_000_000_000_000_000.0
                connectSuccessTotalMs += elapsedMs
            } catch let prepError as AttemptPreparationError {
                if case .fallbackRateLimited = prepError {
                    failedRateLimited += 1
                } else {
                    failedOther += 1
                }
            } catch let handshakeError as HandshakeError {
                if case .failed(let reason) = handshakeError, reason == .timeout {
                    failedTimeout += 1
                } else {
                    failedOther += 1
                }
            } catch {
                failedOther += 1
            }
        }

        let successCount = max(pqcSuccess + classicFallbackSuccess, 1)
        return FleetRow(
            label: config.label,
            sessions: sessions,
            peerPool: peerPool,
            pqcCapableRatio: config.pqcCapableRatio,
            timeoutAttackRate: timeoutAttackRate,
            cooldownEnabled: config.cooldownEnabled,
            pqcSuccess: pqcSuccess,
            classicFallbackSuccess: classicFallbackSuccess,
            failedRateLimited: failedRateLimited,
            failedTimeout: failedTimeout,
            failedOther: failedOther,
            downgradeEvents: classicFallbackSuccess,
            meanConnectSuccessMs: connectSuccessTotalMs / Double(successCount)
        )
    }

    private func writeCSV(rows: [FleetRow]) throws {
        let artifactsDir = URL(fileURLWithPath: "Artifacts")
        try FileManager.default.createDirectory(at: artifactsDir, withIntermediateDirectories: true)

        let dateString = ArtifactDate.current()
        let csvPath = artifactsDir.appendingPathComponent("migration_fleet_behavior_\(dateString).csv")
        var content = "scenario,sessions,peer_pool,pqc_capable_ratio,timeout_attack_rate,cooldown_enabled,pqc_success,classic_fallback_success,failed_rate_limited,failed_timeout,failed_other,downgrade_events,success_rate,downgrade_per_1k,mean_connect_success_ms,share_pqc_success,share_classic_fallback,share_failed_rate_limited,share_failed_timeout,share_failed_other\n"
        for row in rows {
            content += row.csvLine() + "\n"
        }
        try content.write(to: csvPath, atomically: true, encoding: .utf8)
        SkyBridgeLogger.test.info("[MIGRATION-FLEET] CSV written to: \(csvPath.path)")
    }

    private func seed(for label: String) -> UInt64 {
        var hash: UInt64 = 0x9E3779B97F4A7C15
        for byte in label.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001B3
        }
        return hash
    }

    private static func makeSessionKeys(for strategy: HandshakeAttemptStrategy) -> SessionKeys {
        let suite: CryptoSuite = (strategy == .classicOnly) ? .x25519Ed25519 : .mlkem768MLDSA65
        return SessionKeys(
            sendKey: Data(repeating: 0x11, count: 32),
            receiveKey: Data(repeating: 0x22, count: 32),
            negotiatedSuite: suite,
            role: .initiator,
            transcriptHash: Data(repeating: 0x33, count: 32),
            sessionId: "migration-fleet-session",
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

private struct XorShift64Star {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0xA5A5A5A5A5A5A5A5 : seed
    }

    mutating func next() -> UInt64 {
        var x = state
        x ^= x >> 12
        x ^= x << 25
        x ^= x >> 27
        state = x
        return x &* 2685821657736338717
    }

    mutating func nextDouble() -> Double {
        Double(next()) / Double(UInt64.max)
    }
}
