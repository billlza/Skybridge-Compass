// SPDX-License-Identifier: MIT
// SkyBridge Compass - System Impact Bench Tests
//
// Paper add-on: System-level impact (connect + first frame + bulk transfer amortization)
// - T_connect: connectStart -> handshake established (includes Finished + event emission via HandshakeDriver)
// - T_first_frame: connectStart -> first decrypted "remote desktop frame" processed
// - T_file_total: connectStart -> completion of bulk transfer over negotiated session keys
//
// Run with:
//   SKYBRIDGE_RUN_SYSTEM_IMPACT=1 swift test --filter SystemImpactBenchTests
//
// Results are written to:
//   Artifacts/system_impact_<date>.csv
//

import XCTest
import Foundation
import CryptoKit
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class SystemImpactBenchTests: XCTestCase {
    // MARK: - Configuration

    private var shouldRun: Bool {
        ProcessInfo.processInfo.environment["SKYBRIDGE_RUN_SYSTEM_IMPACT"] == "1"
    }

    /// If set, append only missing rows to the existing system_impact_<date>.csv (if present),
    /// instead of rewriting it. This enables upgrading transfer statistics to "final-grade"
    /// without re-running N_connect=1000.
    private var appendMode: Bool {
        ProcessInfo.processInfo.environment["SKYBRIDGE_SYSTEM_IMPACT_APPEND"] == "1"
    }

    /// Back-compat. Prefer SKYBRIDGE_SYSTEM_IMPACT_CONNECT_ITERATIONS.
    private var iterations: Int {
        Int(ProcessInfo.processInfo.environment["SKYBRIDGE_SYSTEM_IMPACT_ITERATIONS"] ?? "") ?? 200
    }

    private var connectIterations: Int {
        Int(ProcessInfo.processInfo.environment["SKYBRIDGE_SYSTEM_IMPACT_CONNECT_ITERATIONS"] ?? "") ?? iterations
    }

    /// Iteration budget for bulk transfer (amortization) runs under RTT50.
    /// Kept separate from connectIterations so we can push N_connect high without exploding runtime.
    private var transferIterations: Int {
        Int(ProcessInfo.processInfo.environment["SKYBRIDGE_SYSTEM_IMPACT_TRANSFER_ITERATIONS"] ?? "") ?? 200
    }

    /// Emulated link bandwidth for large data-plane frames/transfers (MiB/s).
    /// This keeps transfer time realistic (scales with bytes) without paying RTT per chunk.
    private var linkMiBPerSec: Double {
        Double(ProcessInfo.processInfo.environment["SKYBRIDGE_SYSTEM_IMPACT_LINK_MIBPS"] ?? "") ?? 50.0
    }

    /// Payloads >= this threshold are treated as streaming data-plane and only incur bandwidth delay (no base RTT per message).
    private var streamThresholdBytes: Int {
        Int(ProcessInfo.processInfo.environment["SKYBRIDGE_SYSTEM_IMPACT_STREAM_THRESHOLD_BYTES"] ?? "") ?? (128 * 1024)
    }

    private var warmup: Int {
        Int(ProcessInfo.processInfo.environment["SKYBRIDGE_SYSTEM_IMPACT_WARMUP"] ?? "") ?? 5
    }

    private var fileSizesMB: [Int] {
        // Default kept modest to avoid huge runtime in CI. For paper runs, set to "1,10,100".
        let raw = ProcessInfo.processInfo.environment["SKYBRIDGE_SYSTEM_IMPACT_FILE_SIZES_MB"] ?? "1,10"
        return raw
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { $0 > 0 }
    }

    private var frameSize: (w: Int, h: Int) {
        // Keep a non-trivial frame (fits "remote desktop") but still test-friendly.
        let w = Int(ProcessInfo.processInfo.environment["SKYBRIDGE_SYSTEM_IMPACT_FRAME_W"] ?? "") ?? 640
        let h = Int(ProcessInfo.processInfo.environment["SKYBRIDGE_SYSTEM_IMPACT_FRAME_H"] ?? "") ?? 360
        return (max(16, w), max(16, h))
    }

    // MARK: - Suite Types

    private enum SuiteType: String, CaseIterable {
        case classic = "Classic (X25519 + Ed25519)"
        case liboqsPQC = "liboqs PQC (ML-KEM-768 + ML-DSA-65)"
        case applePQC = "CryptoKit PQC (ML-KEM-768 + ML-DSA-65)"

        var csvId: String {
            switch self {
            case .classic: return "classic"
            case .liboqsPQC: return "pqc_liboqs"
            case .applePQC: return "pqc_cryptokit"
            }
        }
    }

    private enum Condition: String, CaseIterable {
        // Deterministic delay+jitter only (reliable stream semantics, like TCP/QUIC).
        case ideal = "ideal"
        case rtt50 = "rtt50_j20"
        case rtt100 = "rtt100_j50"

        var baseLatencyMs: Int {
            switch self {
            case .ideal: return 0
            case .rtt50: return 50
            case .rtt100: return 100
            }
        }

        var jitterMs: Int {
            switch self {
            case .ideal: return 0
            case .rtt50: return 20
            case .rtt100: return 50
            }
        }
    }

    // MARK: - Test entrypoint

    func testSystemImpactArtifactsCSV() async throws {
        try XCTSkipUnless(shouldRun, "Set SKYBRIDGE_RUN_SYSTEM_IMPACT=1 to run system-impact bench")
        try XCTSkipUnless(connectIterations > 0, "SKYBRIDGE_SYSTEM_IMPACT_CONNECT_ITERATIONS must be > 0")

        let capability = CryptoProviderFactory.detectCapability()

        var suites: [SuiteType] = [.classic]
        if capability.hasLiboqs { suites.append(.liboqsPQC) }
        #if HAS_APPLE_PQC_SDK
        if #available(macOS 26.0, iOS 26.0, *) {
            suites.append(.applePQC)
        }
        #endif

        let runDate = Self.dateStamp()
        let artifactsDir = URL(fileURLWithPath: "Artifacts")
        try FileManager.default.createDirectory(at: artifactsDir, withIntermediateDirectories: true)
        let csvPath = artifactsDir.appendingPathComponent("system_impact_\(runDate).csv")

        let header = "date,condition,suite,iteration,file_bytes,frame_bytes,t_connect_ms,t_first_frame_ms,t_file_total_ms,t_file_first_byte_ms\n"
        var csv = header

        // If appending, load existing counts to skip already-satisfied work.
        let existing = appendMode ? readExistingCounts(csvPath: csvPath) : ExistingCounts.empty
        if appendMode, FileManager.default.fileExists(atPath: csvPath.path) {
            // Avoid duplicating header when appending.
            csv = ""
        }

        let frameBytes = frameSize.w * frameSize.h * 4
        let fileBytesList = fileSizesMB.map { Int64($0) * 1024 * 1024 }

        for condition in Condition.allCases {
            for suite in suites {
                // Warmup (unrecorded) to stabilize caches.
                for _ in 0..<warmup {
                    _ = try await runOne(
                        suite: suite,
                        condition: condition,
                        fileBytes: fileBytesList.first ?? 1 * 1024 * 1024,
                        frameBytes: frameBytes,
                        recordCSV: false,
                        includeBulkTransfer: false
                    )
                }

                // 1) Connect + first-frame distribution across all conditions.
                let connectFileBytes = fileBytesList.first ?? 1 * 1024 * 1024
                let haveConnect = existing.connectCount(condition: condition.rawValue, suite: suite.csvId, fileBytes: connectFileBytes)
                if haveConnect < connectIterations {
                    for i in haveConnect..<connectIterations {
                    let r = try await runOne(
                        suite: suite,
                        condition: condition,
                        fileBytes: connectFileBytes,
                        frameBytes: frameBytes,
                        recordCSV: true,
                        includeBulkTransfer: false
                    )
                    csv += String(
                        format: "%@,%@,%@,%d,%lld,%d,%.3f,%.3f,%.3f,%.3f\n",
                        runDate,
                        condition.rawValue,
                        suite.csvId,
                        i,
                        connectFileBytes,
                        frameBytes,
                        r.tConnectMs,
                        r.tFirstFrameMs,
                        r.tFileTotalMs,
                        r.tFileFirstByteMs
                    )
                    }
                }

                // 2) Amortization: evaluate larger file sizes only under RTT 50±20ms (the figure/table condition).
                if condition == .rtt50 {
                    for fileBytes in fileBytesList {
                        let itersForThisFile = max(1, iterationsForFileBytes(fileBytes, baseIters: transferIterations))
                        let haveTotal = existing.transferCount(condition: condition.rawValue, suite: suite.csvId, fileBytes: fileBytes)
                        if haveTotal >= itersForThisFile { continue }
                        for i in haveTotal..<itersForThisFile {
                            let r = try await runOne(
                                suite: suite,
                                condition: condition,
                                fileBytes: fileBytes,
                                frameBytes: frameBytes,
                                recordCSV: true,
                                includeBulkTransfer: true
                            )
                            csv += String(
                                format: "%@,%@,%@,%d,%lld,%d,%.3f,%.3f,%.3f,%.3f\n",
                                runDate,
                                condition.rawValue,
                                suite.csvId,
                                i,
                                fileBytes,
                                frameBytes,
                                r.tConnectMs,
                                r.tFirstFrameMs,
                                r.tFileTotalMs,
                                r.tFileFirstByteMs
                            )
                        }
                    }
                }
            }
        }

        if appendMode, FileManager.default.fileExists(atPath: csvPath.path) {
            if !csv.isEmpty {
                let handle = try FileHandle(forWritingTo: csvPath)
                try handle.seekToEnd()
                if let data = csv.data(using: .utf8) {
                    try handle.write(contentsOf: data)
                }
                try handle.close()
            }
        } else {
            // Fresh write
            if csv.isEmpty {
                try header.write(to: csvPath, atomically: true, encoding: .utf8)
            } else {
                try (header + csv).write(to: csvPath, atomically: true, encoding: .utf8)
            }
        }
        print("[SYSTEM-IMPACT] wrote \(csvPath.path)")
    }

    // MARK: - Append mode: existing counts

    private struct ExistingCounts: Sendable {
        // Key: "condition|suite|fileBytes" -> count
        var connect: [String: Int]
        var transfer: [String: Int]

        static var empty: ExistingCounts { .init(connect: [:], transfer: [:]) }

        func connectCount(condition: String, suite: String, fileBytes: Int64) -> Int {
            connect["\(condition)|\(suite)|\(fileBytes)"] ?? 0
        }

        func transferCount(condition: String, suite: String, fileBytes: Int64) -> Int {
            transfer["\(condition)|\(suite)|\(fileBytes)"] ?? 0
        }
    }

    private func readExistingCounts(csvPath: URL) -> ExistingCounts {
        guard FileManager.default.fileExists(atPath: csvPath.path) else { return .empty }
        guard let data = try? Data(contentsOf: csvPath),
              let text = String(data: data, encoding: .utf8) else { return .empty }

        // CSV has no quoted commas; split by newline + comma is safe.
        // Columns: date,condition,suite,iteration,file_bytes,frame_bytes,t_connect_ms,t_first_frame_ms,t_file_total_ms,t_file_first_byte_ms
        var connect: [String: Int] = [:]
        var transfer: [String: Int] = [:]

        for line in text.split(separator: "\n") {
            if line.hasPrefix("date,condition,suite") { continue }
            let parts = line.split(separator: ",", omittingEmptySubsequences: false)
            if parts.count < 10 { continue }
            let condition = String(parts[1])
            let suite = String(parts[2])
            let fileBytes = Int64(parts[4]) ?? 0
            let tConnect = Double(parts[6])
            let tTotal = Double(parts[8])

            let key = "\(condition)|\(suite)|\(fileBytes)"
            if let tc = tConnect, tc.isFinite {
                connect[key] = (connect[key] ?? 0) + 1
            }
            if let tt = tTotal, tt.isFinite {
                transfer[key] = (transfer[key] ?? 0) + 1
            }
        }
        return ExistingCounts(connect: connect, transfer: transfer)
    }

    private static func dateStamp() -> String {
        ArtifactDate.current()
    }

    private func iterationsForFileBytes(_ fileBytes: Int64, baseIters: Int) -> Int {
        // Keep default runtime sane:
        // - up to 1 MiB: full
        // - up to 10 MiB: half
        // - larger: 1/10
        if fileBytes <= 1 * 1024 * 1024 { return baseIters }
        if fileBytes <= 10 * 1024 * 1024 { return max(1, baseIters / 2) }
        return max(1, baseIters / 10)
    }

    // MARK: - One run

    private struct RunResult: Sendable {
        let tConnectMs: Double
        let tFirstFrameMs: Double
        let tFileTotalMs: Double
        let tFileFirstByteMs: Double
    }

    private func runOne(
        suite: SuiteType,
        condition: Condition,
        fileBytes: Int64,
        frameBytes: Int,
        recordCSV: Bool,
        includeBulkTransfer: Bool
    ) async throws -> RunResult {
        let peer = PeerIdentifier(deviceId: "bench-peer")

        let (initiatorTx, responderTx) = (
            ImpairedTransport(condition: condition, seed: 0x51A7, linkMiBPerSec: linkMiBPerSec, streamThresholdBytes: streamThresholdBytes),
            ImpairedTransport(condition: condition, seed: 0xC0FFEE, linkMiBPerSec: linkMiBPerSec, streamThresholdBytes: streamThresholdBytes)
        )

        let ctx = try await makeHandshakeContext(suite: suite, peer: peer)

        let initiatorDriver = try HandshakeDriver(
            transport: initiatorTx,
            cryptoProvider: ctx.cryptoProvider,
            protocolSignatureProvider: ctx.protocolSignatureProvider,
            protocolSigningKeyHandle: ctx.initiatorKeyHandle,
            sigAAlgorithm: ctx.sigAAlgorithm,
            identityPublicKey: ctx.initiatorIdentityPublicKey,
            offeredSuites: ctx.offeredSuites,
            policy: ctx.handshakePolicy,
            cryptoPolicy: ctx.cryptoPolicy,
            timeout: .seconds(10),
            trustProvider: ctx.trustProviderInitiator
        )

        let responderDriver = try HandshakeDriver(
            transport: responderTx,
            cryptoProvider: ctx.cryptoProvider,
            protocolSignatureProvider: ctx.protocolSignatureProvider,
            protocolSigningKeyHandle: ctx.responderKeyHandle,
            sigAAlgorithm: ctx.sigAAlgorithm,
            identityPublicKey: ctx.responderIdentityPublicKey,
            offeredSuites: ctx.offeredSuites,
            policy: ctx.handshakePolicy,
            cryptoPolicy: ctx.cryptoPolicy,
            timeout: .seconds(10),
            trustProvider: ctx.trustProviderResponder
        )

        await initiatorTx.setOnSend { peer, data in
            await responderDriver.handleMessage(data, from: peer)
        }
        await responderTx.setOnSend { peer, data in
            await initiatorDriver.handleMessage(data, from: peer)
        }

        let start = DispatchTime.now()
        let initiatorKeys = try await initiatorDriver.initiateHandshake(with: peer)
        let tConnectMs = elapsedMs(since: start)

        let responderKeys = try await waitForResponderEstablished(responderDriver)

        // === First frame ===
        let firstFrameRecorder = FirstFrameRecorder()
        let renderer = RemoteFrameRenderer()
        renderer.frameHandler = { _ in
            Task { await firstFrameRecorder.mark() }
        }

        // Send one encrypted "frame" from responder -> initiator and render on initiator side.
        let fw = frameSize.w
        let fh = frameSize.h
        let initiatorRecvKey = initiatorKeys.receiveKey
        let fakeFrame = makeDeterministicBGRAFrameBytes(width: frameSize.w, height: frameSize.h, seed: 0xBEEF)
        let encryptedFrame = try encryptPayload(fakeFrame, keyData: responderKeys.sendKey)
        await responderTx.setOnSend { _, data in
            // Treat all post-handshake traffic as encrypted data-plane frames for this bench.
            do {
                let plaintext = try SystemImpactBenchTests.decryptPayload(data, keyData: initiatorRecvKey)
                _ = renderer.processFrame(data: plaintext, width: fw, height: fh, stride: fw * 4, type: .bgra)
            } catch {
                // Ignore decode errors in bench mode (they will surface as NaN timeouts).
            }
        }
        try await responderTx.send(to: peer, data: encryptedFrame)
        let tFirstFrameMs = await firstFrameRecorder.waitMs(fromStart: start, timeoutMs: 10_000)

        // === File transfer (bulk) ===
        var tFileDoneMs = Double.nan
        var tFileFirstByteMs = Double.nan
        if includeBulkTransfer {
            let bulk = BulkReceiver(expectedBytes: fileBytes)
            let responderRecvKey = responderKeys.receiveKey
            await initiatorTx.setOnSend { _, data in
                do {
                    // Sender uses initiatorKeys.sendKey; receiver opens with responderKeys.receiveKey.
                    let plaintext = try SystemImpactBenchTests.decryptPayload(data, keyData: responderRecvKey)
                    await bulk.onChunk(plaintext.count, now: DispatchTime.now())
                } catch {
                    // Ignore; will reflect as missing bytes / timeout (bench noise).
                }
            }

            // Bulk sender: initiator -> responder, using initiatorKeys.sendKey.
            // Use large chunks to approximate streaming over a reliable channel.
            let chunkSize = 1024 * 1024
            var remaining = Int(fileBytes)
            while remaining > 0 {
                let n = min(chunkSize, remaining)
                let chunk = Data(repeating: 0xA5, count: n)
                let ciphertext = try encryptPayload(chunk, keyData: initiatorKeys.sendKey)
                try await initiatorTx.send(to: peer, data: ciphertext)
                remaining -= n
            }
            tFileDoneMs = await bulk.waitDoneMs(fromStart: start, timeoutMs: 60_000)
            tFileFirstByteMs = await bulk.waitFirstByteMs(fromStart: start, timeoutMs: 60_000)
        }

        _ = responderKeys // keep alive

        // We record connectStart-based totals (handshake + workload) because that supports amortization plots.
        return RunResult(
            tConnectMs: tConnectMs,
            tFirstFrameMs: tFirstFrameMs,
            tFileTotalMs: tFileDoneMs,
            tFileFirstByteMs: tFileFirstByteMs
        )
    }

    // MARK: - Handshake context factory (minimal subset, mirrors other benches)

    private struct HandshakeContextBundle {
        let cryptoProvider: any CryptoProvider
        let offeredSuites: [CryptoSuite]
        let protocolSignatureProvider: any ProtocolSignatureProvider
        let sigAAlgorithm: ProtocolSigningAlgorithm
        let initiatorKeyHandle: SigningKeyHandle
        let responderKeyHandle: SigningKeyHandle
        let initiatorIdentityPublicKey: Data
        let responderIdentityPublicKey: Data
        let trustProviderInitiator: any HandshakeTrustProvider
        let trustProviderResponder: any HandshakeTrustProvider
        let handshakePolicy: HandshakePolicy
        let cryptoPolicy: CryptoPolicy
    }

    private func makeHandshakeContext(suite: SuiteType, peer: PeerIdentifier) async throws -> HandshakeContextBundle {
        let provider: any CryptoProvider
        switch suite {
        case .classic:
            provider = ClassicCryptoProvider()
        case .liboqsPQC:
            provider = OQSPQCCryptoProvider()
        case .applePQC:
            #if HAS_APPLE_PQC_SDK
            if #available(iOS 26.0, macOS 26.0, *) {
                provider = ApplePQCCryptoProvider()
            } else {
                throw XCTSkip("Apple PQC not available on this OS version")
            }
            #else
            throw XCTSkip("HAS_APPLE_PQC_SDK not enabled")
            #endif
        }

        // Mirror the paper harness: suites and signature provider are selected from the provider tier.
        let strategy: HandshakeAttemptStrategy = (suite == .classic) ? .classicOnly : .pqcOnly
        let offeredSuitesResult = TwoAttemptHandshakeManager.getSuites(for: strategy, cryptoProvider: provider)
        guard case .suites(let offeredSuites) = offeredSuitesResult else {
            throw HandshakeError.emptyOfferedSuites
        }

        let protocolSignatureProvider = ProtocolSignatureProviderSelector.select(for: provider.tier)
        let sigAAlgorithm = protocolSignatureProvider.signatureAlgorithm

        let initiatorKeyPair = try await provider.generateKeyPair(for: .signing)
        let responderKeyPair = try await provider.generateKeyPair(for: .signing)

        let initiatorIdentityPublicKey = encodeIdentityPublicKey(
            initiatorKeyPair.publicKey.bytes,
            algorithm: sigAAlgorithm.wire
        )
        let responderIdentityPublicKey = encodeIdentityPublicKey(
            responderKeyPair.publicKey.bytes,
            algorithm: sigAAlgorithm.wire
        )

        // Provide peer KEM public keys when PQC suites are in play.
        let peerKEMPublicKeys = try await makeKEMPublicKeysForPeer(offeredSuites: offeredSuites, provider: provider)
        let trustProviderInitiator: any HandshakeTrustProvider
        let trustProviderResponder: any HandshakeTrustProvider
        if peerKEMPublicKeys.isEmpty {
            trustProviderInitiator = StaticTrustProvider(deviceId: peer.deviceId, fingerprint: nil)
            trustProviderResponder = StaticTrustProvider(deviceId: peer.deviceId, fingerprint: nil)
        } else {
            trustProviderInitiator = StaticTrustProviderWithKEM(deviceId: peer.deviceId, kemPublicKeys: peerKEMPublicKeys)
            trustProviderResponder = StaticTrustProviderWithKEM(deviceId: peer.deviceId, kemPublicKeys: peerKEMPublicKeys)
        }

        let handshakePolicy: HandshakePolicy = (suite == .classic) ? .default : .strictPQC
        let cryptoPolicy: CryptoPolicy = .default

        return HandshakeContextBundle(
            cryptoProvider: provider,
            offeredSuites: offeredSuites,
            protocolSignatureProvider: protocolSignatureProvider,
            sigAAlgorithm: sigAAlgorithm,
            initiatorKeyHandle: .softwareKey(initiatorKeyPair.privateKey.bytes),
            responderKeyHandle: .softwareKey(responderKeyPair.privateKey.bytes),
            initiatorIdentityPublicKey: initiatorIdentityPublicKey,
            responderIdentityPublicKey: responderIdentityPublicKey,
            trustProviderInitiator: trustProviderInitiator,
            trustProviderResponder: trustProviderResponder,
            handshakePolicy: handshakePolicy,
            cryptoPolicy: cryptoPolicy
        )
    }

    private func makeKEMPublicKeysForPeer(
        offeredSuites: [CryptoSuite],
        provider: any CryptoProvider
    ) async throws -> [CryptoSuite: Data] {
        let pqcSuites = offeredSuites.filter { $0.isPQC }
        guard !pqcSuites.isEmpty else { return [:] }
        var kemPublicKeys: [CryptoSuite: Data] = [:]
        for suite in pqcSuites {
            let publicKey = try await DeviceIdentityKeyManager.shared.getKEMPublicKey(for: suite, provider: provider)
            kemPublicKeys[suite] = publicKey
        }
        return kemPublicKeys
    }

    private func waitForResponderEstablished(_ driver: HandshakeDriver) async throws -> SessionKeys {
        for _ in 0..<4000 {
            let st = await driver.getCurrentState()
            if case .established(let keys) = st {
                return keys
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw XCTSkip("Responder did not reach established state")
    }

    // MARK: - Trust Provider (bench-only)

    private struct StaticTrustProviderWithKEM: HandshakeTrustProvider, Sendable {
        let deviceId: String
        let kemPublicKeys: [CryptoSuite: Data]

        func trustedFingerprint(for deviceId: String) async -> String? {
            nil
        }

        func trustedKEMPublicKeys(for deviceId: String) async -> [CryptoSuite: Data] {
            guard deviceId == self.deviceId else { return [:] }
            return kemPublicKeys
        }

        func trustedSecureEnclavePublicKey(for deviceId: String) async -> Data? {
            nil
        }
    }

    // MARK: - Transport (deterministic impairment)

    private actor ImpairedTransport: DiscoveryTransport {
        private let condition: Condition
        private var onSend: (@Sendable (PeerIdentifier, Data) async -> Void)?
        private var counter: UInt64 = 0
        private let seed: UInt64
        private let linkMiBPerSec: Double
        private let streamThresholdBytes: Int

        init(condition: Condition, seed: UInt64, linkMiBPerSec: Double, streamThresholdBytes: Int) {
            self.condition = condition
            self.seed = seed
            self.linkMiBPerSec = max(1.0, linkMiBPerSec)
            self.streamThresholdBytes = max(0, streamThresholdBytes)
        }

        func setOnSend(_ handler: @escaping @Sendable (PeerIdentifier, Data) async -> Void) {
            onSend = handler
        }

        func send(to peer: PeerIdentifier, data: Data) async throws {
            counter &+= 1
            let base = condition.baseLatencyMs
            let jitter = condition.jitterMs
            let j = jitter == 0 ? 0 : Int((lcg(counter &+ seed) % UInt64(2 * jitter + 1))) - jitter

            // Reliable stream approximation:
            // - Small handshake/control frames pay propagation RTT+jitter.
            // - Large data-plane frames/transfers are treated as streaming and pay only bandwidth delay (no per-chunk RTT tax).
            let addBaseRTT = data.count < streamThresholdBytes
            let bytesPerSec = linkMiBPerSec * 1024.0 * 1024.0
            let txMs = (Double(data.count) / bytesPerSec) * 1000.0
            let baseMs = addBaseRTT ? Double(max(0, base + j)) : 0.0
            let totalMs = max(0.0, baseMs + txMs)
            if totalMs > 0.0 {
                try await Task.sleep(for: .milliseconds(Int(totalMs.rounded(.up))))
            }
            await onSend?(peer, data)
        }

        private func lcg(_ x: UInt64) -> UInt64 {
            // Deterministic "random enough" jitter source.
            (1103515245 &* x &+ 12345) & 0x7fff_ffff
        }
    }

    // MARK: - First frame recorder

    private actor FirstFrameRecorder {
        private var firstAt: DispatchTime?

        func mark() {
            if firstAt == nil { firstAt = DispatchTime.now() }
        }

        func waitMs(fromStart start: DispatchTime, timeoutMs: Int) async -> Double {
            let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutMs) * 1_000_000
            while DispatchTime.now().uptimeNanoseconds < deadline {
                if let t = firstAt {
                    return SystemImpactBenchTests.elapsedMs(since: start, end: t)
                }
                try? await Task.sleep(for: .milliseconds(1))
            }
            return Double.nan
        }
    }

    // MARK: - Bulk receiver (file transfer workload)

    private actor BulkReceiver {
        private let expectedBytes: Int64
        private var received: Int64 = 0
        private var firstByteAt: DispatchTime?
        private var doneAt: DispatchTime?

        init(expectedBytes: Int64) {
            self.expectedBytes = expectedBytes
        }

        func onChunk(_ byteCount: Int, now: DispatchTime) {
            if firstByteAt == nil, byteCount > 0 {
                firstByteAt = now
            }
            received += Int64(byteCount)
            if received >= expectedBytes, doneAt == nil {
                doneAt = now
            }
        }

        func waitFirstByteMs(fromStart start: DispatchTime, timeoutMs: Int) async -> Double {
            let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutMs) * 1_000_000
            while DispatchTime.now().uptimeNanoseconds < deadline {
                if let t = firstByteAt {
                    return SystemImpactBenchTests.elapsedMs(since: start, end: t)
                }
                try? await Task.sleep(for: .milliseconds(1))
            }
            return Double.nan
        }

        func waitDoneMs(fromStart start: DispatchTime, timeoutMs: Int) async -> Double {
            let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutMs) * 1_000_000
            while DispatchTime.now().uptimeNanoseconds < deadline {
                if let t = doneAt {
                    return SystemImpactBenchTests.elapsedMs(since: start, end: t)
                }
                try? await Task.sleep(for: .milliseconds(1))
            }
            return Double.nan
        }
    }

    // MARK: - Crypto helpers

    private func encryptPayload(_ plaintext: Data, keyData: Data) throws -> Data {
        try Self.encryptPayload(plaintext, keyData: keyData)
    }

    private static func encryptPayload(_ plaintext: Data, keyData: Data) throws -> Data {
        let key = SymmetricKey(data: keyData)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else {
            throw NSError(domain: "SystemImpactBench", code: 1, userInfo: [NSLocalizedDescriptionKey: "AES.GCM.seal produced nil combined box"])
        }
        return combined
    }

    private static func decryptPayload(_ ciphertext: Data, keyData: Data) throws -> Data {
        let key = SymmetricKey(data: keyData)
        let box = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(box, using: key)
    }

    // MARK: - Deterministic payloads

    private func makeDeterministicBGRAFrameBytes(width: Int, height: Int, seed: UInt64) -> Data {
        // Simple procedural pattern: avoid huge compute but not all-zeros.
        let count = width * height * 4
        var out = Data(count: count)
        out.withUnsafeMutableBytes { raw in
            guard let p = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for i in 0..<count {
                let v = UInt8(truncatingIfNeeded: (UInt64(i) &* 1315423911) &+ seed)
                p[i] = v
            }
        }
        return out
    }

    // MARK: - Timing

    private static func elapsedMs(since start: DispatchTime, end: DispatchTime) -> Double {
        Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
    }

    private func elapsedMs(since start: DispatchTime) -> Double {
        Self.elapsedMs(since: start, end: DispatchTime.now())
    }
}


