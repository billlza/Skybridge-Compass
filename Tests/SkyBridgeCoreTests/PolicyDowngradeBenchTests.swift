// SPDX-License-Identifier: MIT
// SkyBridge Compass - Policy Downgrade Bench Tests

import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class PolicyDowngradeBenchTests: XCTestCase {
    private var shouldRunPolicyBench: Bool {
        ProcessInfo.processInfo.environment["SKYBRIDGE_RUN_POLICY_BENCH"] == "1"
    }

    private var iterations: Int {
        Int(ProcessInfo.processInfo.environment["SKYBRIDGE_POLICY_ITERATIONS"] ?? "") ?? 1000
    }

    func testPolicyDowngradeBench() async throws {
        try XCTSkipUnless(shouldRunPolicyBench, "Set SKYBRIDGE_RUN_POLICY_BENCH=1 to run policy bench")

        let policies: [(label: String, policy: HandshakePolicy)] = [
            ("strictPQC", .strictPQC),
            ("default", .default)
        ]

        var rows: [String] = []

        for entry in policies {
            let result = try await runFallbackScenario(policy: entry.policy, iterations: iterations)
            rows.append("\(entry.label),\(iterations),\(result.classicAttempts),\(result.fallbackEvents)")

            if entry.policy.requirePQC {
                XCTAssertEqual(result.classicAttempts, 0, "strictPQC should never attempt Classic")
                XCTAssertEqual(result.fallbackEvents, 0, "strictPQC should never emit fallback events")
            } else {
                XCTAssertEqual(result.classicAttempts, iterations, "default policy should fallback to Classic once per iteration")
                XCTAssertGreaterThan(result.fallbackEvents, 0, "default policy should emit fallback events")
            }
        }

        try writeCSV(rows: rows)
    }

    private func runFallbackScenario(
        policy: HandshakePolicy,
        iterations: Int
    ) async throws -> (classicAttempts: Int, fallbackEvents: Int) {
        let collector = SecurityEventCollector()
        await collector.startCollecting()
        defer { Task { await collector.stopCollecting() } }

        let tracker = AttemptTracker()
        for _ in 0..<iterations {
            do {
                let attemptCounter = AttemptCounter()
                _ = try await TwoAttemptHandshakeManager.performHandshake(
                    deviceId: "bench-device",
                    preferPQC: true,
                    policy: policy
                ) { strategy, _ in
                    let count = await attemptCounter.next()
                    if count == 1 {
                        throw HandshakeError.failed(.suiteNotSupported)
                    }
                    if strategy == .classicOnly {
                        await tracker.recordClassicAttempt()
                    }
                    return Self.makeSessionKeys()
                }
            } catch {
 // strictPQC path is expected to throw; ignore for bench
            }
        }

 // Allow async event emission to flush
        try await Task.sleep(for: .milliseconds(50))
        let fallbackEvents = await collector.count(of: .handshakeFallback)
        await collector.reset()
        let classicAttempts = await tracker.classicAttempts()
        return (classicAttempts: classicAttempts, fallbackEvents: fallbackEvents)
    }

    private func writeCSV(rows: [String]) throws {
        let artifactsDir = URL(fileURLWithPath: "Artifacts")
        try FileManager.default.createDirectory(at: artifactsDir, withIntermediateDirectories: true)

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateString = dateFormatter.string(from: Date())
        let csvPath = artifactsDir.appendingPathComponent("policy_downgrade_\(dateString).csv")

        var content = "policy,iterations,classic_attempts,fallback_events\n"
        for row in rows {
            content += row + "\n"
        }
        try content.write(to: csvPath, atomically: true, encoding: .utf8)
        SkyBridgeLogger.test.info("[POLICY-BENCH] CSV written to: \(csvPath.path)")
    }

    private static func makeSessionKeys() -> SessionKeys {
        SessionKeys(
            sendKey: Data(repeating: 0x11, count: 32),
            receiveKey: Data(repeating: 0x22, count: 32),
            negotiatedSuite: .x25519Ed25519,
            role: .initiator,
            transcriptHash: Data(repeating: 0x33, count: 32),
            sessionId: "bench-session",
            createdAt: Date()
        )
    }
}

private actor AttemptTracker {
    private var classicCount = 0

    func recordClassicAttempt() {
        classicCount += 1
    }

    func classicAttempts() -> Int {
        classicCount
    }
}

private actor AttemptCounter {
    private var count = 0

    func next() -> Int {
        count += 1
        return count
    }
}
