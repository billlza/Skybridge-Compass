// SPDX-License-Identifier: MIT
// SkyBridge Compass - SOA Interoperability/Arbitration Bench Tests

import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class SOAInteroperabilityBenchTests: XCTestCase {
    private struct BenchRow {
        let scenario: String
        let nRuns: Int
        let passCount: Int
        let metric: String
        let notes: String

        var failCount: Int { max(0, nRuns - passCount) }
        var passRate: Double {
            guard nRuns > 0 else { return 0 }
            return Double(passCount) / Double(nRuns)
        }

        func csvLine() -> String {
            [
                scenario,
                String(nRuns),
                String(passCount),
                String(failCount),
                String(format: "%.4f", passRate),
                metric,
                csvEscape(notes)
            ].joined(separator: ",")
        }

        private func csvEscape(_ input: String) -> String {
            if input.contains(",") || input.contains("\"") {
                return "\"\(input.replacingOccurrences(of: "\"", with: "\"\""))\""
            }
            return input
        }
    }

    private var shouldRunBench: Bool {
        ProcessInfo.processInfo.environment["SKYBRIDGE_RUN_SOA_BENCH"] == "1"
    }

    private var iterations: Int {
        Int(ProcessInfo.processInfo.environment["SKYBRIDGE_SOA_ITERATIONS"] ?? "") ?? 100
    }

    func testSOAInteroperabilityBench() async throws {
        try XCTSkipUnless(shouldRunBench, "Set SKYBRIDGE_RUN_SOA_BENCH=1 to run SOA bench")

        var rows: [BenchRow] = []
        rows.append(try await runSimultaneousOpenSingleFlight())
        rows.append(try await runBindingGuardRejectsForgedTarget())
        rows.append(try await runEstablishedGuardAndRelease())
        rows.append(try await runSupersedeRateLimit())
        rows.append(try runLegacyMessageACompatibility())
        rows.append(try runExtensionPassthroughAndTranscriptBinding())

        try writeCSV(rows)
    }

    private func runSimultaneousOpenSingleFlight() async throws -> BenchRow {
        let localWinnerPeer = Self.fixedPeerId(0x10)
        let remoteLoserPeer = Self.fixedPeerId(0x90)
        let pairKey = PeerSessionArbiter.pairKey(localPeerId: localWinnerPeer, remotePeerId: remoteLoserPeer)

        var passCount = 0
        for idx in 0..<iterations {
            let winnerAttempt = Self.fixedAttemptId(index: idx, salt: 0xA1)
            let loserAttempt = Self.fixedAttemptId(index: idx, salt: 0xB2)

            let winnerArbiter = PeerSessionArbiter()
            let loserArbiter = PeerSessionArbiter()

            let winnerRegister = await winnerArbiter.registerOutgoing(Self.outgoing(
                pairKey: pairKey,
                initiatorPeerId: localWinnerPeer,
                attemptId: winnerAttempt
            ))
            let loserRegister = await loserArbiter.registerOutgoing(Self.outgoing(
                pairKey: pairKey,
                initiatorPeerId: remoteLoserPeer,
                attemptId: loserAttempt
            ))
            guard case .accepted = winnerRegister, case .accepted = loserRegister else {
                continue
            }

            let winnerDecision = await winnerArbiter.evaluateIncoming(
                pairKey: pairKey,
                remoteInitiatorPeerId: remoteLoserPeer,
                remoteAttemptId: loserAttempt,
                targetPeerId: localWinnerPeer,
                expectedRemotePeerId: remoteLoserPeer,
                localPeerId: localWinnerPeer
            )
            let loserDecision = await loserArbiter.evaluateIncoming(
                pairKey: pairKey,
                remoteInitiatorPeerId: localWinnerPeer,
                remoteAttemptId: winnerAttempt,
                targetPeerId: remoteLoserPeer,
                expectedRemotePeerId: localWinnerPeer,
                localPeerId: remoteLoserPeer
            )

            let winnerKeepsAttempt: Bool
            if case .rejectLocalWinner = winnerDecision {
                winnerKeepsAttempt = true
            } else {
                winnerKeepsAttempt = false
            }

            let loserSuperseded: Bool
            if case .acceptAndSupersedeLocal(let winnerPeerId, let winnerAttemptId) = loserDecision {
                loserSuperseded = (winnerPeerId == localWinnerPeer && winnerAttemptId == winnerAttempt)
            } else {
                loserSuperseded = false
            }

            if winnerKeepsAttempt && loserSuperseded {
                passCount += 1
            }
        }

        return BenchRow(
            scenario: "simultaneous_open_single_flight",
            nRuns: iterations,
            passCount: passCount,
            metric: "winner=lexicographic(initiatorPeerId,attemptId)",
            notes: "Two-side concurrent open converges to one winning attempt"
        )
    }

    private func runBindingGuardRejectsForgedTarget() async throws -> BenchRow {
        let localPeerId = Self.fixedPeerId(0x33)
        let expectedRemotePeerId = Self.fixedPeerId(0x44)
        let pairKey = PeerSessionArbiter.pairKey(localPeerId: localPeerId, remotePeerId: expectedRemotePeerId)
        let forgedTarget = Self.fixedPeerId(0x99)

        var passCount = 0
        for idx in 0..<iterations {
            let arbiter = PeerSessionArbiter()
            let localAttemptId = Self.fixedAttemptId(index: idx, salt: 0x10)
            _ = await arbiter.registerOutgoing(Self.outgoing(
                pairKey: pairKey,
                initiatorPeerId: localPeerId,
                attemptId: localAttemptId
            ))

            let decision = await arbiter.evaluateIncoming(
                pairKey: pairKey,
                remoteInitiatorPeerId: expectedRemotePeerId,
                remoteAttemptId: Self.fixedAttemptId(index: idx, salt: 0x22),
                targetPeerId: forgedTarget,
                expectedRemotePeerId: expectedRemotePeerId,
                localPeerId: localPeerId
            )

            if case .rejectBinding = decision {
                passCount += 1
            }
        }

        return BenchRow(
            scenario: "binding_guard_forged_target_rejected",
            nRuns: iterations,
            passCount: passCount,
            metric: "targetPeerId/localPeerId binding",
            notes: "Forged MessageA target cannot induce local cancellation"
        )
    }

    private func runEstablishedGuardAndRelease() async throws -> BenchRow {
        var passCount = 0

        for idx in 0..<iterations {
            let arbiter = PeerSessionArbiter()
            let localPeerId = Self.fixedPeerId(UInt8((idx % 200) + 1))
            let remotePeerId = Self.fixedPeerId(UInt8(((idx + 100) % 200) + 1))
            let pairKey = PeerSessionArbiter.pairKey(localPeerId: localPeerId, remotePeerId: remotePeerId)

            await arbiter.markEstablished(pairKey: pairKey)
            let whileEstablished = await arbiter.registerOutgoing(Self.outgoing(
                pairKey: pairKey,
                initiatorPeerId: localPeerId,
                attemptId: Self.fixedAttemptId(index: idx, salt: 0x31)
            ))
            await arbiter.clearEstablished(pairKey: pairKey)
            let afterRelease = await arbiter.registerOutgoing(Self.outgoing(
                pairKey: pairKey,
                initiatorPeerId: localPeerId,
                attemptId: Self.fixedAttemptId(index: idx, salt: 0x32)
            ))

            let blockedWhenEstablished: Bool
            if case .alreadyConnected = whileEstablished {
                blockedWhenEstablished = true
            } else {
                blockedWhenEstablished = false
            }

            let acceptedAfterRelease: Bool
            if case .accepted = afterRelease {
                acceptedAfterRelease = true
            } else {
                acceptedAfterRelease = false
            }

            if blockedWhenEstablished && acceptedAfterRelease {
                passCount += 1
            }
        }

        return BenchRow(
            scenario: "established_guard_release",
            nRuns: iterations,
            passCount: passCount,
            metric: "already_connected_then_immediate_reconnect",
            notes: "Established guard blocks duplicates and releases immediately on clear"
        )
    }

    private func runSupersedeRateLimit() async throws -> BenchRow {
        var passCount = 0

        for idx in 0..<iterations {
            let arbiter = PeerSessionArbiter()
            let localPeerId = Self.fixedPeerId(0xD0)
            let remotePeerId = Self.fixedPeerId(0x10) // Remote wins by peerId ordering.
            let pairKey = PeerSessionArbiter.pairKey(localPeerId: localPeerId, remotePeerId: remotePeerId)

            var decisions: [PeerSessionArbiter.IncomingDecision] = []
            for round in 0..<4 {
                let register = await arbiter.registerOutgoing(Self.outgoing(
                    pairKey: pairKey,
                    initiatorPeerId: localPeerId,
                    attemptId: Self.fixedAttemptId(index: idx * 10 + round, salt: 0x41)
                ))
                guard case .accepted = register else { continue }
                let decision = await arbiter.evaluateIncoming(
                    pairKey: pairKey,
                    remoteInitiatorPeerId: remotePeerId,
                    remoteAttemptId: Self.fixedAttemptId(index: idx * 10 + round, salt: 0x42),
                    targetPeerId: localPeerId,
                    expectedRemotePeerId: remotePeerId,
                    localPeerId: localPeerId
                )
                decisions.append(decision)
            }

            guard decisions.count == 4 else { continue }

            let firstThreeSupersede = decisions.prefix(3).allSatisfy { decision in
                if case .acceptAndSupersedeLocal = decision { return true }
                return false
            }
            let fourthRateLimited: Bool
            if case .rejectRateLimited = decisions[3] {
                fourthRateLimited = true
            } else {
                fourthRateLimited = false
            }

            if firstThreeSupersede && fourthRateLimited {
                passCount += 1
            }
        }

        return BenchRow(
            scenario: "supersede_rate_limit_3_per_60s",
            nRuns: iterations,
            passCount: passCount,
            metric: "max_supersede=3/window=60s",
            notes: "Fourth supersede attempt in same window is rejected"
        )
    }

    private func runLegacyMessageACompatibility() throws -> BenchRow {
        var passCount = 0

        for _ in 0..<iterations {
            let message = try makeMessageA(extensionsRaw: Data())
            let decoded = try HandshakeMessageA.decode(from: message.encoded)

            let noSOA = decoded.soaExtension == nil && decoded.extensionsRaw.isEmpty
            let transcriptStable = decoded.transcriptBytes == message.transcriptBytes
            if noSOA && transcriptStable {
                passCount += 1
            }
        }

        return BenchRow(
            scenario: "legacy_messageA_compatibility",
            nRuns: iterations,
            passCount: passCount,
            metric: "extensionsRaw=empty",
            notes: "New parser preserves legacy MessageA path when SOA extension is absent"
        )
    }

    private func runExtensionPassthroughAndTranscriptBinding() throws -> BenchRow {
        var passCount = 0
        var totalExtraBytes = 0
        var totalSOAOnlyExtraBytes = 0

        for idx in 0..<iterations {
            let soa = try HandshakeSOAExtension(
                initiatorPeerId: Self.fixedPeerId(0x21),
                targetPeerId: Self.fixedPeerId(0x22),
                attemptId: Self.fixedAttemptId(index: idx, salt: 0x55)
            )
            let unknownPrefix = Self.unknownTLV(type: 0x7FFE, value: Data([0xAA, 0xBB, UInt8(idx & 0xFF)]))
            let unknownSuffix = Self.unknownTLV(type: 0x7FFD, value: Data([0xCC, UInt8((idx + 7) & 0xFF)]))
            let extensionsRaw = unknownPrefix + soa.encodedTLV + unknownSuffix

            let legacyMessage = try makeMessageA(extensionsRaw: Data())
            let soaOnlyMessage = try makeMessageA(extensionsRaw: soa.encodedTLV)
            let extendedMessage = try makeMessageA(extensionsRaw: extensionsRaw)
            let decoded = try HandshakeMessageA.decode(from: extendedMessage.encoded)

            let passthrough = decoded.extensionsRaw == extensionsRaw
            let transcriptStable = decoded.encodedWithoutSignature() == extendedMessage.encodedWithoutSignature()
            let soaParsed: Bool
            if let parsedSOA = decoded.soaExtension {
                soaParsed = parsedSOA.initiatorPeerId == soa.initiatorPeerId
                    && parsedSOA.targetPeerId == soa.targetPeerId
                    && parsedSOA.attemptId == soa.attemptId
            } else {
                soaParsed = false
            }

            if passthrough && transcriptStable && soaParsed {
                passCount += 1
                totalExtraBytes += max(0, extendedMessage.encodedWithoutSignature().count - legacyMessage.encodedWithoutSignature().count)
                totalSOAOnlyExtraBytes += max(0, soaOnlyMessage.encodedWithoutSignature().count - legacyMessage.encodedWithoutSignature().count)
            }
        }

        let meanExtra = passCount > 0 ? Double(totalExtraBytes) / Double(passCount) : 0
        let meanSOAOnlyExtra = passCount > 0 ? Double(totalSOAOnlyExtraBytes) / Double(passCount) : 0
        return BenchRow(
            scenario: "extensions_passthrough_transcript_binding",
            nRuns: iterations,
            passCount: passCount,
            metric: String(format: "mean_extra_bytes=%.1f;soa_only_extra=%.1f", meanExtra, meanSOAOnlyExtra),
            notes: "Unknown TLV bytes are preserved and included in transcript/signature preimage"
        )
    }

    private static func outgoing(
        pairKey: Data,
        initiatorPeerId: Data,
        attemptId: Data
    ) -> PeerSessionArbiter.OutgoingAttempt {
        PeerSessionArbiter.OutgoingAttempt(
            pairKey: pairKey,
            initiatorPeerId: initiatorPeerId,
            attemptId: attemptId,
            startedAt: Date(),
            onSuperseded: { _, _ in }
        )
    }

    private func makeMessageA(extensionsRaw: Data) throws -> HandshakeMessageA {
        let capabilities = CryptoCapabilities(
            supportedKEM: ["X25519"],
            supportedSignature: ["Ed25519"],
            supportedAuthProfiles: ["classic"],
            supportedAEAD: ["AES-256-GCM"],
            pqcAvailable: false,
            platformVersion: "bench",
            providerType: .classic
        )
        let identityKeys = IdentityPublicKeys(
            protocolPublicKey: Data(repeating: 0x11, count: 32),
            protocolAlgorithm: .ed25519,
            secureEnclavePublicKey: nil
        )
        return HandshakeMessageA(
            supportedSuites: [.x25519Ed25519],
            keyShares: [HandshakeKeyShare(suite: .x25519Ed25519, shareBytes: Data(repeating: 0x22, count: 32))],
            clientNonce: Data(repeating: 0x33, count: 32),
            policy: .default,
            capabilities: capabilities,
            signature: Data(repeating: 0x44, count: 64),
            identityPublicKeys: identityKeys,
            extensionsRaw: extensionsRaw,
            secureEnclaveSignature: nil,
            initiatorContribution: nil
        )
    }

    private static func unknownTLV(type: UInt16, value: Data) -> Data {
        var data = Data()
        data.append(UInt8(type & 0xFF))
        data.append(UInt8((type >> 8) & 0xFF))
        let len = UInt16(value.count)
        data.append(UInt8(len & 0xFF))
        data.append(UInt8((len >> 8) & 0xFF))
        data.append(value)
        return data
    }

    private static func fixedPeerId(_ fill: UInt8) -> Data {
        Data(repeating: fill, count: HandshakeSOAExtension.initiatorPeerIdLength)
    }

    private static func fixedAttemptId(index: Int, salt: UInt8) -> Data {
        var bytes = [UInt8](repeating: salt, count: HandshakeSOAExtension.attemptIdLength)
        bytes[0] = UInt8((index >> 8) & 0xFF)
        bytes[1] = UInt8(index & 0xFF)
        return Data(bytes)
    }

    private func writeCSV(_ rows: [BenchRow]) throws {
        let artifactsDir = URL(fileURLWithPath: "Artifacts")
        try FileManager.default.createDirectory(at: artifactsDir, withIntermediateDirectories: true)

        let dateString = ArtifactDate.current()
        let csvPath = artifactsDir.appendingPathComponent("soa_interop_\(dateString).csv")

        var content = "scenario,n_runs,pass_count,fail_count,pass_rate,metric,notes\n"
        for row in rows {
            content += row.csvLine() + "\n"
        }
        try content.write(to: csvPath, atomically: true, encoding: .utf8)
        SkyBridgeLogger.test.info("[SOA-BENCH] CSV written to: \(csvPath.path)")
    }
}
