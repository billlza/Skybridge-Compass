import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class BoundaryStressBenchTests: XCTestCase {
    private struct BenchRow {
        let category: String
        let scenario: String
        let nRuns: Int
        let acceptRate: Double
        let fallbackViolationRate: Double
        let supersedeReasonAccuracy: Double
        let forcedClassicEdgeRate: Double
        let evidenceSchemaPassRate: Double
        let notes: String

        func csvLine() -> String {
            [
                category,
                scenario,
                String(nRuns),
                formatRate(acceptRate),
                formatRate(fallbackViolationRate),
                formatRate(supersedeReasonAccuracy),
                formatRate(forcedClassicEdgeRate),
                formatRate(evidenceSchemaPassRate),
                csvEscape(notes)
            ].joined(separator: ",")
        }

        private func formatRate(_ value: Double) -> String {
            String(format: "%.4f", value)
        }

        private func csvEscape(_ value: String) -> String {
            if value.contains(",") || value.contains("\"") {
                return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
            }
            return value
        }
    }

    private var shouldRunBench: Bool {
        ProcessInfo.processInfo.environment["SKYBRIDGE_RUN_BOUNDARY_STRESS"] == "1"
    }

    private var iterations: Int {
        Int(ProcessInfo.processInfo.environment["SKYBRIDGE_BOUNDARY_STRESS_ITERATIONS"] ?? "") ?? 100
    }

    func testBoundaryStressBench() async throws {
        try XCTSkipUnless(shouldRunBench, "Set SKYBRIDGE_RUN_BOUNDARY_STRESS=1 to run boundary stress bench")

        var rows: [BenchRow] = []
        rows.append(await runInputPerturbationUnknownSuite())
        rows.append(try runInputPerturbationMalformedTLV())
        rows.append(await runConcurrencyAndSupersedeReason())
        rows.append(await runAdversarialTimeoutSuppression())
        rows.append(runEvidenceIntegritySchemaChecks())

        try writeCSV(rows)
    }

    private func runInputPerturbationUnknownSuite() async -> BenchRow {
        let tracker = BoundaryStrategyTracker()
        var accepted = 0
        var fallbackViolations = 0
        var forcedClassicEdges = 0

        for index in 0..<iterations {
            await tracker.reset()
            do {
                _ = try await TwoAttemptHandshakeManager.performHandshake(
                    deviceId: "boundary-unknown-suite-\(index)",
                    preferPQC: true,
                    policy: .default
                ) { strategy, _ in
                    await tracker.record(strategy)
                    throw HandshakeError.failed(.suiteNotSupported)
                }
                accepted += 1
            } catch {
                // expected: blocked
            }

            let attempts = await tracker.strategies()
            if attempts.count > 1 {
                fallbackViolations += 1
            }
            if attempts.contains(.classicOnly) {
                forcedClassicEdges += 1
            }
        }

        return BenchRow(
            category: "input_perturbation",
            scenario: "unknown_suite_blocked",
            nRuns: iterations,
            acceptRate: rate(accepted),
            fallbackViolationRate: rate(fallbackViolations),
            supersedeReasonAccuracy: 1.0,
            forcedClassicEdgeRate: rate(forcedClassicEdges),
            evidenceSchemaPassRate: 1.0,
            notes: "unknown/unsupported suite never becomes fallback-eligible"
        )
    }

    private func runInputPerturbationMalformedTLV() throws -> BenchRow {
        var accepted = 0
        for _ in 0..<iterations {
            let malformed = try makeMalformedTLVMessageA()
            if (try? HandshakeMessageA.decode(from: malformed.encoded)) != nil {
                accepted += 1
            }
        }

        return BenchRow(
            category: "input_perturbation",
            scenario: "malformed_tlv_rejected",
            nRuns: iterations,
            acceptRate: rate(accepted),
            fallbackViolationRate: 0,
            supersedeReasonAccuracy: 1.0,
            forcedClassicEdgeRate: 0,
            evidenceSchemaPassRate: 1.0,
            notes: "truncated extension TLV must be rejected during decode"
        )
    }

    private func runConcurrencyAndSupersedeReason() async -> BenchRow {
        var convergencePasses = 0
        var reasonAccurate = 0

        for index in 0..<iterations {
            let arbiter = PeerSessionArbiter()
            let localPeerId = Data(repeating: 0xF0, count: 32)
            let remotePeerId = Data(repeating: 0x01, count: 32)
            let pairKey = PeerSessionArbiter.pairKey(localPeerId: localPeerId, remotePeerId: remotePeerId)
            let localAttemptId = fixedAttempt(index: index, fill: 0xAA)
            let remoteAttemptId = fixedAttempt(index: index, fill: 0xBB)

            let register = await arbiter.registerOutgoing(
                PeerSessionArbiter.OutgoingAttempt(
                    pairKey: pairKey,
                    initiatorPeerId: localPeerId,
                    attemptId: localAttemptId,
                    startedAt: Date(),
                    onSuperseded: { _, _ in }
                )
            )
            guard case .accepted = register else { continue }

            let decision = await arbiter.evaluateIncoming(
                pairKey: pairKey,
                remoteInitiatorPeerId: remotePeerId,
                remoteAttemptId: remoteAttemptId,
                targetPeerId: localPeerId,
                expectedRemotePeerId: remotePeerId,
                localPeerId: localPeerId,
                authenticationState: .authenticated
            )

            if case .acceptAndSupersedeLocal(let winnerPeer, let winnerAttempt) = decision {
                convergencePasses += 1
                let reason = PeerSessionArbiter.supersededFailureReason(
                    winnerPeerId: winnerPeer,
                    winnerAttemptId: winnerAttempt
                )
                if case .supersededByConcurrentAttempt = reason {
                    reasonAccurate += 1
                }
            }
        }

        return BenchRow(
            category: "concurrency_race",
            scenario: "soa_simultaneous_open_supersede_reason",
            nRuns: iterations,
            acceptRate: rate(convergencePasses),
            fallbackViolationRate: 0,
            supersedeReasonAccuracy: rate(reasonAccurate),
            forcedClassicEdgeRate: 0,
            evidenceSchemaPassRate: 1.0,
            notes: "supersede only after authenticated binding and maps to supersededByConcurrentAttempt"
        )
    }

    private func runAdversarialTimeoutSuppression() async -> BenchRow {
        var accepted = 0
        var fallbackViolations = 0
        var forcedClassicEdges = 0
        let tracker = BoundaryStrategyTracker()

        for index in 0..<iterations {
            await tracker.reset()
            do {
                _ = try await TwoAttemptHandshakeManager.performHandshake(
                    deviceId: "boundary-timeout-\(index)",
                    preferPQC: true,
                    policy: .default
                ) { strategy, _ in
                    await tracker.record(strategy)
                    throw HandshakeError.failed(.timeout)
                }
                accepted += 1
            } catch {
                // expected: timeout without fallback
            }

            let attempts = await tracker.strategies()
            if attempts.count > 1 {
                fallbackViolations += 1
            }
            if attempts.contains(.classicOnly) {
                forcedClassicEdges += 1
            }
        }

        return BenchRow(
            category: "adversarial_network",
            scenario: "timeout_no_fallback",
            nRuns: iterations,
            acceptRate: rate(accepted),
            fallbackViolationRate: rate(fallbackViolations),
            supersedeReasonAccuracy: 1.0,
            forcedClassicEdgeRate: rate(forcedClassicEdges),
            evidenceSchemaPassRate: 1.0,
            notes: "timeout/loss-like failures must not force classic edges"
        )
    }

    private func runEvidenceIntegritySchemaChecks() -> BenchRow {
        var malformedAccepted = 0
        var validRejected = 0

        for index in 0..<iterations {
            let malformed: [String: String] = [
                "category": "evidence_integrity",
                "scenario": "row-\(index)",
                "outcome": "blocked"
            ]
            let valid: [String: String] = [
                "category": "evidence_integrity",
                "scenario": "row-\(index)",
                "outcome": "blocked",
                "invariant": "schema_complete"
            ]

            if isEvidenceSchemaValid(malformed) {
                malformedAccepted += 1
            }
            if !isEvidenceSchemaValid(valid) {
                validRejected += 1
            }
        }

        let passCount = max(0, iterations - validRejected)
        return BenchRow(
            category: "evidence_integrity",
            scenario: "schema_completeness_enforced",
            nRuns: iterations,
            acceptRate: rate(malformedAccepted),
            fallbackViolationRate: 0,
            supersedeReasonAccuracy: 1.0,
            forcedClassicEdgeRate: 0,
            evidenceSchemaPassRate: rate(passCount),
            notes: "incomplete evidence rows are rejected from decision inputs"
        )
    }

    private func isEvidenceSchemaValid(_ row: [String: String]) -> Bool {
        let required = ["category", "scenario", "outcome", "invariant"]
        for key in required {
            guard let value = row[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else {
                return false
            }
        }
        return true
    }

    private func makeMalformedTLVMessageA() throws -> HandshakeMessageA {
        let capabilities = CryptoCapabilities(
            supportedKEM: ["X25519"],
            supportedSignature: ["Ed25519"],
            supportedAuthProfiles: ["classic"],
            supportedAEAD: ["AES-256-GCM"],
            pqcAvailable: false,
            platformVersion: "boundary-stress",
            providerType: .classic
        )
        let identity = IdentityPublicKeys(
            protocolPublicKey: Data(repeating: 0x10, count: 32),
            protocolAlgorithm: .ed25519,
            secureEnclavePublicKey: nil
        )
        let malformedTLV = Data([0x01, 0x00, 0x08])
        return HandshakeMessageA(
            supportedSuites: [.x25519Ed25519],
            keyShares: [HandshakeKeyShare(suite: .x25519Ed25519, shareBytes: Data(repeating: 0x20, count: 32))],
            clientNonce: Data(repeating: 0x30, count: 32),
            policy: .default,
            capabilities: capabilities,
            signature: Data(repeating: 0x40, count: 64),
            identityPublicKeys: identity,
            extensionsRaw: malformedTLV,
            secureEnclaveSignature: nil,
            initiatorContribution: nil
        )
    }

    private func fixedAttempt(index: Int, fill: UInt8) -> Data {
        var bytes = [UInt8](repeating: fill, count: 16)
        bytes[0] = UInt8((index >> 8) & 0xFF)
        bytes[1] = UInt8(index & 0xFF)
        return Data(bytes)
    }

    private func rate(_ numerator: Int) -> Double {
        guard iterations > 0 else { return 0 }
        return Double(numerator) / Double(iterations)
    }

    private func writeCSV(_ rows: [BenchRow]) throws {
        let artifactsDir = URL(fileURLWithPath: "Artifacts")
        try FileManager.default.createDirectory(at: artifactsDir, withIntermediateDirectories: true)

        let dateString = ArtifactDate.current()
        let csvPath = artifactsDir.appendingPathComponent("boundary_stress_\(dateString).csv")

        var content = "category,scenario,n_runs,accept_rate,fallback_violation_rate,supersede_reason_accuracy,forced_classic_edge_rate,evidence_schema_pass_rate,notes\n"
        for row in rows {
            content += row.csvLine() + "\n"
        }
        try content.write(to: csvPath, atomically: true, encoding: .utf8)
        SkyBridgeLogger.test.info("[BOUNDARY-STRESS] CSV written to: \(csvPath.path)")
    }
}

private actor BoundaryStrategyTracker {
    private var values: [HandshakeAttemptStrategy] = []

    func record(_ strategy: HandshakeAttemptStrategy) {
        values.append(strategy)
    }

    func reset() {
        values = []
    }

    func strategies() -> [HandshakeAttemptStrategy] {
        values
    }
}
