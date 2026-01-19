import Foundation
import SkyBridgeCore

@main
struct HandshakeBenchRunner {
    private enum ProviderType: String {
        case classic = "Classic (X25519 + Ed25519)"
        case liboqsPQC = "liboqs PQC (ML-KEM-768 + ML-DSA-65)"
        case applePQC = "CryptoKit PQC (ML-KEM-768 + ML-DSA-65)"
        case appleXWing = "CryptoKit Hybrid (X-Wing + ML-DSA-65)"
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

    private struct EnhancedPercentileStats: Sendable {
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
            let computedMean = samples.reduce(0, +) / n
            self.mean = computedMean
            let sumSquaredDiff = samples.reduce(0.0) { acc, x in
                let diff = x - computedMean
                return acc + diff * diff
            }
            self.stdDev = sqrt(sumSquaredDiff / n)
            func percentile(_ p: Double) -> Double {
                let index = Int(Double(sorted.count - 1) * p)
                return sorted[index]
            }
            self.p50 = percentile(0.50)
            self.p95 = percentile(0.95)
            self.p99 = percentile(0.99)
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
        private var isDelivering = false
        private var sentMessages: [(PeerIdentifier, Data)] = []

        func setOnSend(_ handler: @escaping @Sendable (PeerIdentifier, Data) async -> Void) {
            onSend = handler
        }

        func send(to peer: PeerIdentifier, data: Data) async throws {
            pending.append((peer, data))
            sentMessages.append((peer, data))
            if !isDelivering {
                isDelivering = true
                Task { await flushPending() }
            }
        }

        func getSentMessages() -> [(PeerIdentifier, Data)] {
            sentMessages
        }

        private func flushPending() async {
            await Task.yield()
            while !pending.isEmpty {
                let (peer, data) = pending.removeFirst()
                await onSend?(peer, data)
            }
            isDelivering = false
        }
    }

    private static let wireSizeRecorder = WireSizeRecorder()
    private static let runDate = dateStamp()

    static func main() async {
        do {
            let iterations = intEnv("BENCH_ITERATIONS", defaultValue: 1000)
            let warmup = intEnv("BENCH_WARMUP", defaultValue: 10)
            let dateString = runDate

            let capability = CryptoProviderFactory.detectCapability()

            try await runBench(
                providerType: .classic,
                iterations: iterations,
                warmup: warmup,
                dateString: dateString
            )

            if capability.hasLiboqs {
                try await runBench(
                    providerType: .liboqsPQC,
                    iterations: iterations,
                    warmup: warmup,
                    dateString: dateString
                )
            } else {
                print("[BENCH] liboqs not available, skipping PQC bench")
            }

            if capability.hasApplePQC {
                try await runBench(
                    providerType: .applePQC,
                    iterations: iterations,
                    warmup: warmup,
                    dateString: dateString
                )
                try await runBench(
                    providerType: .appleXWing,
                    iterations: iterations,
                    warmup: warmup,
                    dateString: dateString
                )
            } else {
                print("[BENCH] Apple PQC not available, skipping CryptoKit bench")
            }
        } catch {
            fputs("[BENCH] Failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func runBench(
        providerType: ProviderType,
        iterations: Int,
        warmup: Int,
        dateString: String
    ) async throws {
        let context = try await prepareBenchmarkContext(providerType: providerType)
        let latencySamples = try await measureHandshakeLatency(
            context: context,
            iterations: iterations,
            warmup: warmup
        )
        let latencyStats = EnhancedPercentileStats(samples: latencySamples)
        writeLatencyArtifact(
            configuration: providerType.rawValue,
            stats: latencyStats,
            iterations: iterations,
            dateString: dateString
        )

        let rttSamples = try await measureHandshakeRTT(
            context: context,
            iterations: iterations,
            warmup: warmup
        )
        let rttStats = EnhancedPercentileStats(samples: rttSamples)
        writeRTTArtifact(
            configuration: providerType.rawValue,
            stats: rttStats,
            iterations: iterations,
            dateString: dateString
        )
    }

    private static func prepareBenchmarkContext(
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
            throw NSError(domain: "HandshakeBench", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "liboqs not available"
            ])
            #endif
        case .applePQC:
            #if HAS_APPLE_PQC_SDK
            if #available(iOS 26.0, macOS 26.0, *) {
                provider = ApplePQCCryptoProvider()
            } else {
                throw NSError(domain: "HandshakeBench", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Apple PQC not available"
                ])
            }
            #else
            throw NSError(domain: "HandshakeBench", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Apple PQC SDK not available"
            ])
            #endif
        case .appleXWing:
            #if HAS_APPLE_PQC_SDK
            if #available(iOS 26.0, macOS 26.0, *) {
                provider = AppleXWingCryptoProvider()
            } else {
                throw NSError(domain: "HandshakeBench", code: 6, userInfo: [
                    NSLocalizedDescriptionKey: "Apple X-Wing not available"
                ])
            }
            #else
            throw NSError(domain: "HandshakeBench", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "Apple PQC SDK not available"
            ])
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

    private static func makeKEMPublicKeysForPeer(
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

    private static func measureHandshakeLatency(
        context: BenchmarkContext,
        iterations: Int,
        warmup: Int
    ) async throws -> [Double] {
        var samples: [Double] = []

        for _ in 0..<warmup {
            _ = try await performMockHandshake(context: context)
        }

        for _ in 0..<iterations {
            let start = ContinuousClock.now
            _ = try await performMockHandshake(context: context)
            let elapsed = ContinuousClock.now - start
            let ms = Double(elapsed.components.seconds) * 1000.0 +
                Double(elapsed.components.attoseconds) / 1_000_000_000_000_000.0
            samples.append(ms)
        }

        return samples
    }

    private static func measureHandshakeRTT(
        context: BenchmarkContext,
        iterations: Int,
        warmup: Int
    ) async throws -> [Double] {
        var samples: [Double] = []

        for _ in 0..<warmup {
            _ = try await performMockHandshakeWithMetrics(context: context)
        }

        for _ in 0..<iterations {
            let (_, metrics) = try await performMockHandshakeWithMetrics(context: context)
            guard metrics.rttMs >= 0 else {
                throw NSError(domain: "HandshakeBench", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "RTT unavailable in metrics"
                ])
            }
            samples.append(metrics.rttMs)
        }

        return samples
    }

    private static func performMockHandshake(context: BenchmarkContext) async throws -> Data {
        let (transcriptHash, _) = try await performMockHandshakeWithMetrics(context: context)
        return transcriptHash
    }

    private static func performMockHandshakeWithMetrics(
        context: BenchmarkContext
    ) async throws -> (transcriptHash: Data, metrics: HandshakeMetrics) {
        let provider = context.provider
        let offeredSuites = context.offeredSuites

        let initiatorTransport = BenchmarkTransport()
        let responderTransport = BenchmarkTransport()

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
                    throw NSError(domain: "HandshakeBench", code: 4, userInfo: [
                        NSLocalizedDescriptionKey: "Handshake task timeout"
                    ])
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
        } catch {
            throw error
        }

        let initiatorSent = await initiatorTransport.getSentMessages()
        let responderSent = await responderTransport.getSentMessages()
        if initiatorSent.count >= 2, responderSent.count >= 2 {
            let sizes = HandshakeWireSizes(
                messageABytes: initiatorSent[0].1.count,
                messageBBytes: responderSent[0].1.count,
                finishedBytes: initiatorSent[1].1.count + responderSent[1].1.count
            )
            if await wireSizeRecorder.shouldRecord(context.providerType) {
                writeWireSizes(
                    configuration: context.providerType.rawValue,
                    sizes: sizes,
                    dateString: runDate
                )
            }
        }

        guard let metrics = await initiatorDriver.getLastMetrics() else {
            throw NSError(domain: "HandshakeBench", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "Handshake metrics not available"
            ])
        }

        return (sessionKeys.transcriptHash, metrics)
    }

    private static func writeLatencyArtifact(
        configuration: String,
        stats: EnhancedPercentileStats,
        iterations: Int,
        dateString: String
    ) {
        let artifactsDir = URL(fileURLWithPath: "Artifacts")
        let csvPath = artifactsDir.appendingPathComponent("handshake_bench_\(dateString).csv")

        do {
            try FileManager.default.createDirectory(at: artifactsDir, withIntermediateDirectories: true)

            var csvContent = ""
            if !FileManager.default.fileExists(atPath: csvPath.path) {
                csvContent = "configuration,iteration_count,mean_ms,stddev_ms,p50_ms,p95_ms,p99_ms\n"
            }
            csvContent += "\(configuration),\(iterations),\(stats.mean),\(stats.stdDev),\(stats.p50),\(stats.p95),\(stats.p99)\n"

            if let handle = try? FileHandle(forWritingTo: csvPath) {
                handle.seekToEndOfFile()
                handle.write(csvContent.data(using: .utf8)!)
                handle.closeFile()
            } else {
                try csvContent.write(to: csvPath, atomically: true, encoding: .utf8)
            }
        } catch {
            fputs("[BENCH] Failed to write latency artifact: \(error)\n", stderr)
        }
    }

    private static func writeRTTArtifact(
        configuration: String,
        stats: EnhancedPercentileStats,
        iterations: Int,
        dateString: String
    ) {
        let artifactsDir = URL(fileURLWithPath: "Artifacts")
        let csvPath = artifactsDir.appendingPathComponent("handshake_rtt_\(dateString).csv")

        do {
            try FileManager.default.createDirectory(at: artifactsDir, withIntermediateDirectories: true)

            var csvContent = ""
            if !FileManager.default.fileExists(atPath: csvPath.path) {
                csvContent = "configuration,iteration_count,mean_ms,stddev_ms,p50_ms,p95_ms,p99_ms\n"
            }
            csvContent += "\(configuration),\(iterations),\(stats.mean),\(stats.stdDev),\(stats.p50),\(stats.p95),\(stats.p99)\n"

            if let handle = try? FileHandle(forWritingTo: csvPath) {
                handle.seekToEndOfFile()
                handle.write(csvContent.data(using: .utf8)!)
                handle.closeFile()
            } else {
                try csvContent.write(to: csvPath, atomically: true, encoding: .utf8)
            }
        } catch {
            fputs("[BENCH] Failed to write RTT artifact: \(error)\n", stderr)
        }
    }

    private static func writeWireSizes(
        configuration: String,
        sizes: HandshakeWireSizes,
        dateString: String
    ) {
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
            fputs("[BENCH] Failed to write wire size artifact: \(error)\n", stderr)
        }
    }

    private static func encodeIdentityPublicKey(
        _ publicKey: Data,
        algorithm: SignatureAlgorithm
    ) -> Data {
        IdentityPublicKeys(
            protocolPublicKey: publicKey,
            protocolAlgorithm: algorithm,
            secureEnclavePublicKey: nil
        ).encoded
    }

    private static func intEnv(_ key: String, defaultValue: Int) -> Int {
        if let raw = ProcessInfo.processInfo.environment[key], let value = Int(raw) {
            return value
        }
        return defaultValue
    }

    private static func dateStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
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
