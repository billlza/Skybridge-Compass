// SPDX-License-Identifier: MIT
// SkyBridge Compass - Handshake Benchmark Tests
// IEEE Paper Table I/II/III reproducibility harness

import XCTest
import Foundation
@testable import SkyBridgeCore

/// Benchmark tests for handshake latency and throughput measurements.
/// Run with `SKYBRIDGE_RUN_BENCH=1 swift test --filter HandshakeBenchmarkTests`
/// Results are written to `Artifacts/handshake_bench_2026-01-06.csv`
final class HandshakeBenchmarkTests: XCTestCase {
    
 // MARK: - Benchmark Configuration
 // Trigger: SKYBRIDGE_RUN_BENCH=1 swift test --filter HandshakeBenchmarkTests
 // Paper reference: Section VI.B, Table I (N=1000 iterations)
 // 15.1: Changed from 100 to 1000 iterations for statistical significance
    
    private static let iterationCount = 1000  // Production benchmark iterations (IEEE paper: N=1000)
    private static let warmupCount = 10
    
    private var shouldRunBenchmarks: Bool {
        ProcessInfo.processInfo.environment["SKYBRIDGE_RUN_BENCH"] == "1"
    }
    
 // MARK: - Latency Benchmarks (Table I)
 // Requirements: 4.1, 4.3, 4.4
    
    func testHandshakeLatency_Classic() async throws {
        try XCTSkipUnless(shouldRunBenchmarks, "Set SKYBRIDGE_RUN_BENCH=1 to run benchmarks")
        
        let samples = try await measureHandshakeLatency(
            providerType: .classic,
            iterations: Self.iterationCount,
            warmup: Self.warmupCount
        )
        
        let stats = computeEnhancedStats(samples)
        reportLatencyStats(configuration: "Classic (X25519 + Ed25519)", stats: stats)
    }

    func testHandshakeRTT_Classic() async throws {
        try XCTSkipUnless(shouldRunBenchmarks, "Set SKYBRIDGE_RUN_BENCH=1 to run benchmarks")

        let samples = try await measureHandshakeRTT(
            providerType: .classic,
            iterations: Self.iterationCount,
            warmup: Self.warmupCount
        )

        let stats = computeEnhancedStats(samples)
        reportRTTStats(configuration: "Classic (X25519 + Ed25519)", stats: stats)
    }
    
    func testHandshakeLatency_LiboqsPQC() async throws {
        try XCTSkipUnless(shouldRunBenchmarks, "Set SKYBRIDGE_RUN_BENCH=1 to run benchmarks")
        
 // Skip if liboqs not available
        let capability = CryptoProviderFactory.detectCapability()
        guard capability.hasLiboqs else {
            throw XCTSkip("liboqs not available on this system")
        }
        
        let samples = try await measureHandshakeLatency(
            providerType: .liboqsPQC,
            iterations: Self.iterationCount,
            warmup: Self.warmupCount
        )
        
        let stats = computeEnhancedStats(samples)
        reportLatencyStats(configuration: "liboqs PQC (ML-KEM-768 + ML-DSA-65)", stats: stats)
    }

    func testHandshakeRTT_LiboqsPQC() async throws {
        try XCTSkipUnless(shouldRunBenchmarks, "Set SKYBRIDGE_RUN_BENCH=1 to run benchmarks")

 // Skip if liboqs not available
        let capability = CryptoProviderFactory.detectCapability()
        guard capability.hasLiboqs else {
            throw XCTSkip("liboqs not available on this system")
        }

        let samples = try await measureHandshakeRTT(
            providerType: .liboqsPQC,
            iterations: Self.iterationCount,
            warmup: Self.warmupCount
        )

        let stats = computeEnhancedStats(samples)
        reportRTTStats(configuration: "liboqs PQC (ML-KEM-768 + ML-DSA-65)", stats: stats)
    }
    
    #if HAS_APPLE_PQC_SDK
    @available(macOS 26.0, iOS 26.0, *)
    func testHandshakeLatency_ApplePQC() async throws {
        try XCTSkipUnless(shouldRunBenchmarks, "Set SKYBRIDGE_RUN_BENCH=1 to run benchmarks")
        
        let samples = try await measureHandshakeLatency(
            providerType: .applePQC,
            iterations: Self.iterationCount,
            warmup: Self.warmupCount
        )
        
        let stats = computeEnhancedStats(samples)
        reportLatencyStats(configuration: "CryptoKit PQC (ML-KEM-768 + ML-DSA-65)", stats: stats)
    }

    @available(macOS 26.0, iOS 26.0, *)
    func testHandshakeRTT_ApplePQC() async throws {
        try XCTSkipUnless(shouldRunBenchmarks, "Set SKYBRIDGE_RUN_BENCH=1 to run benchmarks")

        let samples = try await measureHandshakeRTT(
            providerType: .applePQC,
            iterations: Self.iterationCount,
            warmup: Self.warmupCount
        )

        let stats = computeEnhancedStats(samples)
        reportRTTStats(configuration: "CryptoKit PQC (ML-KEM-768 + ML-DSA-65)", stats: stats)
    }

    @available(macOS 26.0, iOS 26.0, *)
    func testHandshakeLatency_AppleXWing() async throws {
        try XCTSkipUnless(shouldRunBenchmarks, "Set SKYBRIDGE_RUN_BENCH=1 to run benchmarks")

        let samples = try await measureHandshakeLatency(
            providerType: .appleXWing,
            iterations: Self.iterationCount,
            warmup: Self.warmupCount
        )

        let stats = computeEnhancedStats(samples)
        reportLatencyStats(configuration: "CryptoKit Hybrid (X-Wing + ML-DSA-65)", stats: stats)
    }

    @available(macOS 26.0, iOS 26.0, *)
    func testHandshakeRTT_AppleXWing() async throws {
        try XCTSkipUnless(shouldRunBenchmarks, "Set SKYBRIDGE_RUN_BENCH=1 to run benchmarks")

        let samples = try await measureHandshakeRTT(
            providerType: .appleXWing,
            iterations: Self.iterationCount,
            warmup: Self.warmupCount
        )

        let stats = computeEnhancedStats(samples)
        reportRTTStats(configuration: "CryptoKit Hybrid (X-Wing + ML-DSA-65)", stats: stats)
    }
    #endif
    
 // MARK: - Throughput Benchmarks (Table III)
 // Note: Data-plane throughput tests are implemented in HandshakeDriverTests.testBench_DataPlaneThroughputAndCPUProxy
 // Run with: SKYBRIDGE_RUN_BENCH=1 swift test --filter testBench_DataPlaneThroughputAndCPUProxy
    
    func testDataPlaneThroughput_1KiB() async throws {
        try XCTSkipUnless(shouldRunBenchmarks, "Set SKYBRIDGE_RUN_BENCH=1 to run benchmarks")
 // Redirect to HandshakeDriverTests which has the working implementation
 // See: testBench_DataPlaneThroughputAndCPUProxy in HandshakeDriverTests.swift
        SkyBridgeLogger.test.info("[BENCH] Data-plane throughput tests are in HandshakeDriverTests.testBench_DataPlaneThroughputAndCPUProxy")
    }
    
    func testDataPlaneThroughput_64KiB() async throws {
        try XCTSkipUnless(shouldRunBenchmarks, "Set SKYBRIDGE_RUN_BENCH=1 to run benchmarks")
 // Redirect to HandshakeDriverTests which has the working implementation
        SkyBridgeLogger.test.info("[BENCH] Data-plane throughput tests are in HandshakeDriverTests.testBench_DataPlaneThroughputAndCPUProxy")
    }
    
    func testDataPlaneThroughput_1MiB() async throws {
        try XCTSkipUnless(shouldRunBenchmarks, "Set SKYBRIDGE_RUN_BENCH=1 to run benchmarks")
 // Redirect to HandshakeDriverTests which has the working implementation
        SkyBridgeLogger.test.info("[BENCH] Data-plane throughput tests are in HandshakeDriverTests.testBench_DataPlaneThroughputAndCPUProxy")
    }
    
 // MARK: - Provider Selection Overhead (Table IV)
 // Note: Provider selection tests are implemented in HandshakeDriverTests.testBench_ProviderSelectionOverhead
 // Run with: SKYBRIDGE_RUN_BENCH=1 swift test --filter testBench_ProviderSelectionOverhead
    
    func testProviderSelectionOverhead_Cold() async throws {
        try XCTSkipUnless(shouldRunBenchmarks, "Set SKYBRIDGE_RUN_BENCH=1 to run benchmarks")
 // Redirect to HandshakeDriverTests which has the working implementation
        SkyBridgeLogger.test.info("[BENCH] Provider selection tests are in HandshakeDriverTests.testBench_ProviderSelectionOverhead")
    }
    
    func testProviderSelectionOverhead_Hot() async throws {
        try XCTSkipUnless(shouldRunBenchmarks, "Set SKYBRIDGE_RUN_BENCH=1 to run benchmarks")
 // Redirect to HandshakeDriverTests which has the working implementation
        SkyBridgeLogger.test.info("[BENCH] Provider selection tests are in HandshakeDriverTests.testBench_ProviderSelectionOverhead")
    }
    
 // MARK: - Private Helpers
    
    private enum ProviderType {
        case classic
        case liboqsPQC
        case applePQC
        case appleXWing
    }

    private struct BenchmarkContext {
        let providerType: ProviderType
        let provider: any CryptoProvider
        let offeredSuites: [CryptoSuite]
        let protocolSignatureProvider: any ProtocolSignatureProvider
        let sigAAlgorithm: ProtocolSigningAlgorithm
        let initiatorKeyHandle: SigningKeyHandle
        let responderKeyHandle: SigningKeyHandle
        let initiatorIdentityPublicKey: Data
        let responderIdentityPublicKey: Data
        let peer: PeerIdentifier
        let trustProviderInitiator: any HandshakeTrustProvider
        let trustProviderResponder: any HandshakeTrustProvider
        let handshakeTimeout: Duration
        let handshakePolicy: HandshakePolicy
        let cryptoPolicy: CryptoPolicy
    }
    
    private struct HandshakeWireSizes: Sendable {
        let messageABytes: Int
        let messageBBytes: Int
        let finishedBytes: Int
    }
    
    private static let configurationNames: [ProviderType: String] = [
        .classic: "Classic (X25519 + Ed25519)",
        .liboqsPQC: "liboqs PQC (ML-KEM-768 + ML-DSA-65)",
        .applePQC: "CryptoKit PQC (ML-KEM-768 + ML-DSA-65)",
        .appleXWing: "CryptoKit Hybrid (X-Wing + ML-DSA-65)"
    ]
    private static let wireSizeRecorder = WireSizeRecorder()
    
    private func makeKEMPublicKeysForPeer(
        offeredSuites: [CryptoSuite],
        provider: any CryptoProvider
    ) async throws -> [CryptoSuite: Data] {
        let pqcSuites = offeredSuites.filter { $0.isPQC }
        guard !pqcSuites.isEmpty else {
            return [:]
        }
        
        var kemPublicKeys: [CryptoSuite: Data] = [:]
        for suite in pqcSuites {
            let publicKey = try await DeviceIdentityKeyManager.shared.getKEMPublicKey(
                for: suite,
                provider: provider
            )
            kemPublicKeys[suite] = publicKey
        }
        return kemPublicKeys
    }

    private func prepareBenchmarkContext(
        providerType: ProviderType
    ) async throws -> BenchmarkContext {
        let provider: any CryptoProvider
        switch providerType {
        case .classic:
            provider = ClassicCryptoProvider()
        case .liboqsPQC:
            #if canImport(OQSRAII)
            provider = OQSPQCCryptoProvider()
            #else
            throw XCTSkip("liboqs not available on this system")
            #endif
        case .applePQC:
            #if HAS_APPLE_PQC_SDK
            if #available(iOS 26.0, macOS 26.0, *) {
                provider = ApplePQCCryptoProvider()
            } else {
                throw XCTSkip("Apple PQC not available on this OS version")
            }
            #else
            throw XCTSkip("Apple PQC SDK not available in this build")
            #endif
        case .appleXWing:
            #if HAS_APPLE_PQC_SDK
            if #available(iOS 26.0, macOS 26.0, *) {
                provider = AppleXWingCryptoProvider()
            } else {
                throw XCTSkip("Apple X-Wing not available on this OS version")
            }
            #else
            throw XCTSkip("Apple PQC SDK not available in this build")
            #endif
        }

        let strategy: HandshakeAttemptStrategy = (providerType == .classic) ? .classicOnly : .pqcOnly
        let offeredSuitesResult = TwoAttemptHandshakeManager.getSuites(for: strategy, cryptoProvider: provider)
        guard case .suites(let offeredSuites) = offeredSuitesResult else {
            throw HandshakeError.emptyOfferedSuites
        }

        let protocolSignatureProvider = ProtocolSignatureProviderSelector.select(for: provider.tier)
        let sigAAlgorithm = protocolSignatureProvider.signatureAlgorithm

        let initiatorKeyPair = try await provider.generateKeyPair(for: .signing)
        let responderKeyPair = try await provider.generateKeyPair(for: .signing)
        let initiatorKeyHandle = SigningKeyHandle.softwareKey(initiatorKeyPair.privateKey.bytes)
        let responderKeyHandle = SigningKeyHandle.softwareKey(responderKeyPair.privateKey.bytes)
        let initiatorIdentityPublicKey = encodeIdentityPublicKey(
            initiatorKeyPair.publicKey.bytes,
            algorithm: sigAAlgorithm.wire
        )
        let responderIdentityPublicKey = encodeIdentityPublicKey(
            responderKeyPair.publicKey.bytes,
            algorithm: sigAAlgorithm.wire
        )

        let peer = PeerIdentifier(deviceId: "bench-peer")
        let peerKEMPublicKeys = try await makeKEMPublicKeysForPeer(
            offeredSuites: offeredSuites,
            provider: provider
        )
        let trustProviderInitiator: any HandshakeTrustProvider
        let trustProviderResponder: any HandshakeTrustProvider
        if peerKEMPublicKeys.isEmpty {
            trustProviderInitiator = StaticTrustProvider(deviceId: peer.deviceId, fingerprint: nil)
            trustProviderResponder = StaticTrustProvider(deviceId: peer.deviceId, fingerprint: nil)
        } else {
            trustProviderInitiator = StaticTrustProviderWithKEM(
                deviceId: peer.deviceId,
                kemPublicKeys: peerKEMPublicKeys
            )
            trustProviderResponder = StaticTrustProviderWithKEM(
                deviceId: peer.deviceId,
                kemPublicKeys: peerKEMPublicKeys
            )
        }

        let handshakeTimeout: Duration = (providerType == .classic) ? .seconds(15) : .seconds(25)
        let handshakePolicy: HandshakePolicy = (providerType == .classic) ? .default : .strictPQC
        let cryptoPolicy: CryptoPolicy
        switch providerType {
        case .appleXWing:
            cryptoPolicy = CryptoPolicy(
                minimumSecurityTier: .hybridPreferred,
                allowExperimentalHybrid: true,
                advertiseHybrid: true,
                requireHybridIfAvailable: true
            )
        default:
            cryptoPolicy = .default
        }

        return BenchmarkContext(
            providerType: providerType,
            provider: provider,
            offeredSuites: offeredSuites,
            protocolSignatureProvider: protocolSignatureProvider,
            sigAAlgorithm: sigAAlgorithm,
            initiatorKeyHandle: initiatorKeyHandle,
            responderKeyHandle: responderKeyHandle,
            initiatorIdentityPublicKey: initiatorIdentityPublicKey,
            responderIdentityPublicKey: responderIdentityPublicKey,
            peer: peer,
            trustProviderInitiator: trustProviderInitiator,
            trustProviderResponder: trustProviderResponder,
            handshakeTimeout: handshakeTimeout,
            handshakePolicy: handshakePolicy,
            cryptoPolicy: cryptoPolicy
        )
    }
    
 /// Measure handshake latency
 /// Requirements: 4.1, 4.3
    @available(macOS 14.0, iOS 17.0, *)
    private func measureHandshakeLatency(
        providerType: ProviderType,
        iterations: Int,
        warmup: Int
    ) async throws -> [Double] {
        var samples: [Double] = []
        let context = try await prepareBenchmarkContext(providerType: providerType)
        
 // Warmup
        for _ in 0..<warmup {
            _ = try await performMockHandshake(context: context)
        }
        
 // Measured iterations
        for _ in 0..<iterations {
            let start = ContinuousClock.now
            _ = try await performMockHandshake(context: context)
            let elapsed = ContinuousClock.now - start
            
 // Convert to milliseconds
            let ms = Double(elapsed.components.seconds) * 1000.0 +
                     Double(elapsed.components.attoseconds) / 1_000_000_000_000_000.0
            samples.append(ms)
        }
        
        return samples
    }

 /// Measure handshake RTT (MessageB receive - MessageA send)
    @available(macOS 14.0, iOS 17.0, *)
    private func measureHandshakeRTT(
        providerType: ProviderType,
        iterations: Int,
        warmup: Int
    ) async throws -> [Double] {
        var samples: [Double] = []
        let context = try await prepareBenchmarkContext(providerType: providerType)

        for _ in 0..<warmup {
            _ = try await performMockHandshakeWithMetrics(context: context)
        }

        for _ in 0..<iterations {
            let (_, metrics) = try await performMockHandshakeWithMetrics(context: context)
            guard metrics.rttMs >= 0 else {
                throw BenchmarkError.missingMetrics("RTT unavailable in metrics")
            }
            samples.append(metrics.rttMs)
        }

        return samples
    }
    
 /// Perform a mock handshake using auto-forwarded in-memory transport
 /// Requirements: 4.3
    @available(macOS 14.0, iOS 17.0, *)
    private func performMockHandshake(providerType: ProviderType) async throws -> Data {
        let context = try await prepareBenchmarkContext(providerType: providerType)
        return try await performMockHandshake(context: context)
    }

    private func performMockHandshake(context: BenchmarkContext) async throws -> Data {
        let (transcriptHash, _) = try await performMockHandshakeWithMetrics(context: context)
        return transcriptHash
    }

    private func performMockHandshakeWithMetrics(
        context: BenchmarkContext
    ) async throws -> (transcriptHash: Data, metrics: HandshakeMetrics) {
        let provider = context.provider
        let offeredSuites = context.offeredSuites

 // Create transports that auto-forward messages
        let initiatorTransport = BenchmarkTransport()
        let responderTransport = BenchmarkTransport()

 // Create drivers with protocol signing capability
        let initiatorDriver = try HandshakeDriver(
            transport: initiatorTransport,
            cryptoProvider: provider,
            protocolSignatureProvider: context.protocolSignatureProvider,
            protocolSigningKeyHandle: context.initiatorKeyHandle,
            sigAAlgorithm: context.sigAAlgorithm,
            identityPublicKey: context.initiatorIdentityPublicKey,
            offeredSuites: offeredSuites,
            policy: context.handshakePolicy,
            cryptoPolicy: context.cryptoPolicy,
            timeout: context.handshakeTimeout,
            trustProvider: context.trustProviderInitiator
        )
        
        let responderDriver = try HandshakeDriver(
            transport: responderTransport,
            cryptoProvider: provider,
            protocolSignatureProvider: context.protocolSignatureProvider,
            protocolSigningKeyHandle: context.responderKeyHandle,
            sigAAlgorithm: context.sigAAlgorithm,
            identityPublicKey: context.responderIdentityPublicKey,
            offeredSuites: offeredSuites,
            policy: context.handshakePolicy,
            cryptoPolicy: context.cryptoPolicy,
            timeout: context.handshakeTimeout,
            trustProvider: context.trustProviderResponder
        )
        
        await initiatorTransport.setOnSend { [responderDriver] peer, data in
            await responderDriver.handleMessage(data, from: peer)
        }
        await responderTransport.setOnSend { [initiatorDriver] peer, data in
            await initiatorDriver.handleMessage(data, from: peer)
        }
        
        let handshakeTask = Task {
            try await initiatorDriver.initiateHandshake(with: context.peer)
        }
        
        let sessionKeys: SessionKeys
        do {
            sessionKeys = try await withThrowingTaskGroup(of: SessionKeys.self) { group in
                group.addTask {
                    try await handshakeTask.value
                }
                group.addTask {
                    try await Task.sleep(for: context.handshakeTimeout)
                    throw BenchmarkError.timeout("Handshake task timeout")
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
        } catch BenchmarkError.timeout {
            let initiatorState = await initiatorDriver.getCurrentState()
            let responderState = await responderDriver.getCurrentState()
            throw HandshakeError.invalidState(
                "Handshake task timeout, initiatorState=\(initiatorState), responderState=\(responderState)"
            )
        }
        
        let initiatorSent = await initiatorTransport.getSentMessages()
        let responderSent = await responderTransport.getSentMessages()
        if initiatorSent.count >= 2, responderSent.count >= 2 {
            let sizes = HandshakeWireSizes(
                messageABytes: initiatorSent[0].1.count,
                messageBBytes: responderSent[0].1.count,
                finishedBytes: initiatorSent[1].1.count + responderSent[1].1.count
            )
            if let configuration = Self.configurationNames[context.providerType],
               await Self.wireSizeRecorder.shouldRecord(context.providerType) {
                writeWireSizes(configuration: configuration, sizes: sizes)
            }
        }
        
        guard let metrics = await initiatorDriver.getLastMetrics() else {
            throw BenchmarkError.missingMetrics("Handshake metrics not available")
        }

 // Return transcript hash as proof of successful handshake
        return (sessionKeys.transcriptHash, metrics)
    }
    
 /// Benchmark error types
    private enum BenchmarkError: Error {
        case timeout(String)
        case missingMetrics(String)
    }
    
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

    private struct StaticTrustProvider: HandshakeTrustProvider, Sendable {
        let deviceId: String
        let fingerprint: String?

        func trustedFingerprint(for deviceId: String) async -> String? {
            guard deviceId == self.deviceId else { return nil }
            return fingerprint
        }

        func trustedKEMPublicKeys(for deviceId: String) async -> [CryptoSuite: Data] {
            [:]
        }

        func trustedSecureEnclavePublicKey(for deviceId: String) async -> Data? {
            nil
        }
    }
    
    private actor WireSizeRecorder {
        private var recordedProviders: Set<ProviderType> = []
        
        func shouldRecord(_ providerType: ProviderType) -> Bool {
            if recordedProviders.contains(providerType) {
                return false
            }
            recordedProviders.insert(providerType)
            return true
        }
    }

    private actor BenchmarkTransport: DiscoveryTransport {
        private var onSend: (@Sendable (PeerIdentifier, Data) async -> Void)?
        private var pending: [(PeerIdentifier, Data)] = []
        private var sentMessages: [(PeerIdentifier, Data)] = []
        
        func setOnSend(_ handler: @escaping @Sendable (PeerIdentifier, Data) async -> Void) {
            onSend = handler
            guard !pending.isEmpty else { return }
            let buffered = pending
            pending.removeAll()
            Task {
                for (peer, data) in buffered {
                    await handler(peer, data)
                }
            }
        }
        
        func send(to peer: PeerIdentifier, data: Data) async throws {
            sentMessages.append((peer, data))
            guard let handler = onSend else {
                pending.append((peer, data))
                return
            }
            Task {
                await handler(peer, data)
            }
        }
        
        func getSentMessages() -> [(PeerIdentifier, Data)] {
            sentMessages
        }
    }
    
    private struct PercentileStats {
        let mean: Double
        let p50: Double
        let p95: Double
        let p99: Double
    }
    
 /// Enhanced percentile statistics including standard deviation
 /// Requirements: 5.1
    struct EnhancedPercentileStats: Sendable {
        let mean: Double
        let stdDev: Double
        let p50: Double
        let p95: Double
        let p99: Double
        
        init(samples: [Double]) {
            guard !samples.isEmpty else {
                self.mean = 0
                self.stdDev = 0
                self.p50 = 0
                self.p95 = 0
                self.p99 = 0
                return
            }
            
            let sorted = samples.sorted()
            let n = Double(samples.count)
            
 // Mean
            self.mean = samples.reduce(0, +) / n
            
 // Standard Deviation: sqrt(sum((x-mean)^2)/n)
            let computedMean = self.mean
            let sumSquaredDiff = samples.reduce(0.0) { acc, x in
                let diff = x - computedMean
                return acc + diff * diff
            }
            self.stdDev = sqrt(sumSquaredDiff / n)
            
 // Percentiles
            func percentile(_ p: Double) -> Double {
                let index = Int(Double(sorted.count - 1) * p)
                return sorted[index]
            }
            
            self.p50 = percentile(0.50)
            self.p95 = percentile(0.95)
            self.p99 = percentile(0.99)
        }
    }
    
    private func computePercentiles(_ samples: [Double]) -> PercentileStats {
        guard !samples.isEmpty else {
            return PercentileStats(mean: 0, p50: 0, p95: 0, p99: 0)
        }
        
        let sorted = samples.sorted()
        let mean = samples.reduce(0, +) / Double(samples.count)
        
        func percentile(_ p: Double) -> Double {
            let index = Int(Double(sorted.count - 1) * p)
            return sorted[index]
        }
        
        return PercentileStats(
            mean: mean,
            p50: percentile(0.50),
            p95: percentile(0.95),
            p99: percentile(0.99)
        )
    }
    
 /// Compute enhanced statistics including standard deviation
 /// Requirements: 5.1
    func computeEnhancedStats(_ samples: [Double]) -> EnhancedPercentileStats {
        return EnhancedPercentileStats(samples: samples)
    }
    
    private func reportLatencyStats(configuration: String, stats: PercentileStats) {
 // Compute enhanced stats for stdDev
 // Note: We need samples to compute stdDev, so we'll use a helper
        SkyBridgeLogger.test.info("""
            [BENCH] \(configuration):
              mean=\(stats.mean, format: .fixed(precision: 3))ms
              p50=\(stats.p50, format: .fixed(precision: 3))ms
              p95=\(stats.p95, format: .fixed(precision: 3))ms
              p99=\(stats.p99, format: .fixed(precision: 3))ms
            """)
        
 // Write to CSV artifact (without stdDev for legacy PercentileStats)
        writeToArtifact(configuration: configuration, stats: stats)
    }
    
 /// Report latency statistics with enhanced stats including stdDev
 /// Requirements: 5.2
    private func reportLatencyStats(configuration: String, stats: EnhancedPercentileStats) {
        SkyBridgeLogger.test.info("""
            [BENCH] \(configuration):
              mean=\(stats.mean, format: .fixed(precision: 3))ms
              stdDev=\(stats.stdDev, format: .fixed(precision: 3))ms
              p50=\(stats.p50, format: .fixed(precision: 3))ms
              p95=\(stats.p95, format: .fixed(precision: 3))ms
              p99=\(stats.p99, format: .fixed(precision: 3))ms
            """)
        
 // Write to CSV artifact with stdDev
        writeToArtifact(configuration: configuration, stats: stats)
    }

    private func reportRTTStats(configuration: String, stats: EnhancedPercentileStats) {
        SkyBridgeLogger.test.info("""
            [BENCH-RTT] \(configuration):
              mean=\(stats.mean, format: .fixed(precision: 3))ms
              stdDev=\(stats.stdDev, format: .fixed(precision: 3))ms
              p50=\(stats.p50, format: .fixed(precision: 3))ms
              p95=\(stats.p95, format: .fixed(precision: 3))ms
              p99=\(stats.p99, format: .fixed(precision: 3))ms
            """)

        writeRTTArtifact(configuration: configuration, stats: stats)
    }
    
    private func writeToArtifact(configuration: String, stats: PercentileStats) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateString = dateFormatter.string(from: Date())
        
        let artifactsDir = URL(fileURLWithPath: "Artifacts")
        let csvPath = artifactsDir.appendingPathComponent("handshake_bench_\(dateString).csv")
        
        do {
            try FileManager.default.createDirectory(at: artifactsDir, withIntermediateDirectories: true)
            
            var csvContent = ""
            if !FileManager.default.fileExists(atPath: csvPath.path) {
 // Legacy format without stdDev
                csvContent = "configuration,p50_ms,p95_ms,p99_ms,mean_ms\n"
            }
            csvContent += "\(configuration),\(stats.p50),\(stats.p95),\(stats.p99),\(stats.mean)\n"
            
            if let handle = try? FileHandle(forWritingTo: csvPath) {
                handle.seekToEndOfFile()
                handle.write(csvContent.data(using: .utf8)!)
                handle.closeFile()
            } else {
                try csvContent.write(to: csvPath, atomically: true, encoding: .utf8)
            }
        } catch {
            SkyBridgeLogger.test.warning("Failed to write benchmark artifact: \(error)")
        }
    }
    
 /// Write enhanced benchmark results to CSV artifact with stdDev column
 /// Requirements: 5.3
 /// 15.1: CSV header includes iteration_count for reproducibility
    private func writeToArtifact(configuration: String, stats: EnhancedPercentileStats) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateString = dateFormatter.string(from: Date())
        
        let artifactsDir = URL(fileURLWithPath: "Artifacts")
        let csvPath = artifactsDir.appendingPathComponent("handshake_bench_\(dateString).csv")
        
        do {
            try FileManager.default.createDirectory(at: artifactsDir, withIntermediateDirectories: true)
            
            var csvContent = ""
            if !FileManager.default.fileExists(atPath: csvPath.path) {
 // Enhanced format with stdDev and iteration_count: configuration,iteration_count,mean_ms,stddev_ms,p50_ms,p95_ms,p99_ms
 // 15.1: Added iteration_count column for IEEE paper reproducibility (N=1000)
                csvContent = "configuration,iteration_count,mean_ms,stddev_ms,p50_ms,p95_ms,p99_ms\n"
            }
            csvContent += "\(configuration),\(Self.iterationCount),\(stats.mean),\(stats.stdDev),\(stats.p50),\(stats.p95),\(stats.p99)\n"
            
            if let handle = try? FileHandle(forWritingTo: csvPath) {
                handle.seekToEndOfFile()
                handle.write(csvContent.data(using: .utf8)!)
                handle.closeFile()
            } else {
                try csvContent.write(to: csvPath, atomically: true, encoding: .utf8)
            }
        } catch {
            SkyBridgeLogger.test.warning("Failed to write benchmark artifact: \(error)")
        }
    }

    private func writeRTTArtifact(configuration: String, stats: EnhancedPercentileStats) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateString = dateFormatter.string(from: Date())

        let artifactsDir = URL(fileURLWithPath: "Artifacts")
        let csvPath = artifactsDir.appendingPathComponent("handshake_rtt_\(dateString).csv")

        do {
            try FileManager.default.createDirectory(at: artifactsDir, withIntermediateDirectories: true)

            var csvContent = ""
            if !FileManager.default.fileExists(atPath: csvPath.path) {
                csvContent = "configuration,iteration_count,mean_ms,stddev_ms,p50_ms,p95_ms,p99_ms\n"
            }
            csvContent += "\(configuration),\(Self.iterationCount),\(stats.mean),\(stats.stdDev),\(stats.p50),\(stats.p95),\(stats.p99)\n"

            if let handle = try? FileHandle(forWritingTo: csvPath) {
                handle.seekToEndOfFile()
                handle.write(csvContent.data(using: .utf8)!)
                handle.closeFile()
            } else {
                try csvContent.write(to: csvPath, atomically: true, encoding: .utf8)
            }
        } catch {
            SkyBridgeLogger.test.warning("Failed to write RTT artifact: \(error)")
        }
    }
    
    private func writeWireSizes(configuration: String, sizes: HandshakeWireSizes) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateString = dateFormatter.string(from: Date())
        
        let artifactsDir = URL(fileURLWithPath: "Artifacts")
        let csvPath = artifactsDir.appendingPathComponent("handshake_wire_\(dateString).csv")
        
        do {
            try FileManager.default.createDirectory(at: artifactsDir, withIntermediateDirectories: true)
            
            var csvContent = ""
            if !FileManager.default.fileExists(atPath: csvPath.path) {
                csvContent = "configuration,messageA_bytes,messageB_bytes,finished_bytes,total_bytes\n"
            }
            let total = sizes.messageABytes + sizes.messageBBytes + sizes.finishedBytes
            csvContent += "\(configuration),\(sizes.messageABytes),\(sizes.messageBBytes),\(sizes.finishedBytes),\(total)\n"
            
            if let handle = try? FileHandle(forWritingTo: csvPath) {
                handle.seekToEndOfFile()
                handle.write(csvContent.data(using: .utf8)!)
                handle.closeFile()
            } else {
                try csvContent.write(to: csvPath, atomically: true, encoding: .utf8)
            }
        } catch {
            SkyBridgeLogger.test.warning("Failed to write wire size artifact: \(error)")
        }
    }
    
 // MARK: - Property Tests
    
 /// Feature: handshake-fault-injection-bench, Property 5: Standard Deviation Correctness
 /// Validates: Requirements 5.1
 /// For any non-empty sample set, the computed standard deviation SHALL equal
 /// sqrt(sum((x-mean)^2)/n) within floating-point precision tolerance.
    func testProperty_StandardDeviationCorrectness() {
 // Run 100 iterations with random sample sets
        for iteration in 0..<100 {
 // Generate random sample size (1 to 100)
            let sampleCount = Int.random(in: 1...100)
            
 // Generate random samples (latency-like values: 0.1ms to 100ms)
            var samples: [Double] = []
            for _ in 0..<sampleCount {
                samples.append(Double.random(in: 0.1...100.0))
            }
            
 // Compute using our implementation
            let stats = computeEnhancedStats(samples)
            
 // Compute expected stdDev manually: sqrt(sum((x-mean)^2)/n)
            let n = Double(samples.count)
            let expectedMean = samples.reduce(0, +) / n
            let sumSquaredDiff = samples.reduce(0.0) { acc, x in
                let diff = x - expectedMean
                return acc + diff * diff
            }
            let expectedStdDev = sqrt(sumSquaredDiff / n)
            
 // Verify mean matches
            XCTAssertEqual(
                stats.mean,
                expectedMean,
                accuracy: 1e-10,
                "Iteration \(iteration): Mean mismatch"
            )
            
 // Verify stdDev matches within floating-point tolerance
            XCTAssertEqual(
                stats.stdDev,
                expectedStdDev,
                accuracy: 1e-10,
                "Iteration \(iteration): StdDev mismatch. Expected \(expectedStdDev), got \(stats.stdDev)"
            )
        }
    }
    
 /// Property test: stdDev of constant samples should be 0
    func testProperty_StandardDeviationConstantSamples() {
        for _ in 0..<100 {
            let constantValue = Double.random(in: 0.1...100.0)
            let sampleCount = Int.random(in: 1...100)
            let samples = Array(repeating: constantValue, count: sampleCount)
            
            let stats = computeEnhancedStats(samples)
            
            XCTAssertEqual(stats.mean, constantValue, accuracy: 1e-10)
            XCTAssertEqual(stats.stdDev, 0.0, accuracy: 1e-10, "StdDev of constant samples should be 0")
        }
    }
    
 /// Property test: empty samples should return 0 for all stats
    func testProperty_StandardDeviationEmptySamples() {
        let stats = computeEnhancedStats([])
        
        XCTAssertEqual(stats.mean, 0.0)
        XCTAssertEqual(stats.stdDev, 0.0)
        XCTAssertEqual(stats.p50, 0.0)
        XCTAssertEqual(stats.p95, 0.0)
        XCTAssertEqual(stats.p99, 0.0)
    }
}

// MARK: - Mock Loopback Transport
// MockLoopbackTransport is now defined in MockLoopbackTransport.swift
