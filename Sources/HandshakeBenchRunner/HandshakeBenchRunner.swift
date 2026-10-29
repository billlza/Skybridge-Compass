import Foundation
import SkyBridgeCore
import SkyBridgeBenchmarkSupport
import SkyBridgeQPeriaptRuntime

@main
struct HandshakeBenchRunner {
    enum ProviderType: String, Sendable {
        case classic = "Classic (X25519 + Ed25519)"
        case liboqsPQC = "liboqs PQC (ML-KEM-768 + ML-DSA-65)"
        case liboqsPQCv2FS = "liboqs PQC v2 FS (ML-KEM-768-FS + ML-DSA-65)"
        case applePQC = "CryptoKit PQC (ML-KEM-768 + ML-DSA-65)"
        case appleXWing = "CryptoKit Hybrid (X-Wing + ML-DSA-65)"
        case qPeriapt = "Q-Periapt ABI2 ContextBound + CryptoKit ML-DSA-65"
    }

    private struct BenchmarkContext: Sendable {
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
        let initiatorKEMIdentityStore: BenchmarkHandshakeKEMIdentityStore
        let responderKEMIdentityStore: BenchmarkHandshakeKEMIdentityStore
        let handshakeTimeout: Duration
        let handshakePolicy: HandshakePolicy
        let cryptoPolicy: CryptoPolicy
    }

    static func main() async {
        do {
            let config = try BenchmarkConfiguration()
            let artifacts = try BenchmarkArtifacts(configuration: config)
            print("[BENCH] Artifacts: \(artifacts.directory.path)")
            let providers = try selectedProviders(config)
            try artifacts.writeJSON([
                "transport": "deterministic in-memory; no sockets or network RTT",
                "latencyScope": "initiateHandshake through Finished; excludes identity/policy setup and cleanup",
                "signature": "production tier selector; comparison uses CryptoKit ML-DSA-65 for all three providers",
                "trust": "fresh in-memory keys pinned before measurement; benchmark-only policy CAS",
                "order": config.profile == .comparison ? "six fixed permutations of Q/Apple ML-KEM/Apple X-Wing" : "provider blocks",
                "providers": providers.map(\.rawValue).joined(separator: "; "),
                "os": ProcessInfo.processInfo.operatingSystemVersionString
            ], filename: "scope.json")
            var contexts: [BenchmarkContext] = []
            for provider in providers {
                contexts.append(try await prepareBenchmarkContext(providerType: provider))
            }
            var sequence = 0
            for batch in 1...config.batches {
                var samples = Array(repeating: [BenchmarkSample](), count: contexts.count)
                for context in contexts {
                    for _ in 0..<config.warmup {
                        _ = try await performHandshake(context: context, sequence: 0, batch: batch, iteration: 0)
                    }
                }
                if config.profile == .comparison {
                    for iteration in 0..<config.iterations {
                        for index in BenchmarkConfiguration.comparisonOrder(iteration: iteration) {
                            sequence += 1
                            let sample = try await performHandshake(context: contexts[index], sequence: sequence, batch: batch, iteration: iteration + 1)
                            try artifacts.record(sample)
                            samples[index].append(sample)
                        }
                    }
                } else {
                    for (index, context) in contexts.enumerated() {
                        let count = (context.providerType == .applePQC || context.providerType == .appleXWing)
                            ? config.appleIterations : config.iterations
                        for iteration in 1...count {
                            sequence += 1
                            let sample = try await performHandshake(context: context, sequence: sequence, batch: batch, iteration: iteration)
                            try artifacts.record(sample)
                            samples[index].append(sample)
                        }
                    }
                }
                for (index, context) in contexts.enumerated() {
                    try artifacts.writeSummary(provider: context.providerType.rawValue, samples: samples[index])
                }
                print("[BENCH] Completed batch \(batch)/\(config.batches), \(sequence) recorded handshakes")
                if config.cooldownSeconds > 0, batch < config.batches {
                    try await Task.sleep(for: .seconds(config.cooldownSeconds))
                }
            }
            try artifacts.writeJSON(["completedSamples": sequence, "completedBatches": config.batches], filename: "completion.json")
        } catch {
            fputs("[BENCH] Failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func selectedProviders(_ config: BenchmarkConfiguration) throws -> [ProviderType] {
        let capability = CryptoProviderFactory.detectCapability()
        if config.profile == .comparison {
            guard capability.hasApplePQC else { throw BenchmarkError.unavailableProvider("Apple PQC comparison requires native support") }
            return [.qPeriapt, .applePQC, .appleXWing]
        }
        var providers: [ProviderType] = []
        if config.profile != .contrast {
            providers.append(.classic)
            if capability.hasLiboqs { providers += [.liboqsPQC, .liboqsPQCv2FS] }
            else { print("[BENCH] liboqs unavailable; omitted from this profile") }
        }
        if config.profile != .core, capability.hasApplePQC {
            providers.append(.applePQC)
            if config.includeXWing { providers.append(.appleXWing) }
        }
        guard !providers.isEmpty else { throw BenchmarkError.unavailableProvider("No selected provider is available") }
        return providers
    }

    private static func prepareBenchmarkContext(
        providerType: ProviderType
    ) async throws -> BenchmarkContext {
        let provider: any CryptoProvider
        switch providerType {
        case .classic:
            provider = ClassicCryptoProvider()
        case .liboqsPQC, .liboqsPQCv2FS:
            #if canImport(OQSRAII)
            provider = OQSPQCCryptoProvider()
            #else
            throw NSError(domain: "HandshakeBench", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "liboqs not available"
            ])
            #endif
        case .qPeriapt:
            provider = QPeriaptCryptoProvider(session: try await makeBenchmarkPolicySession())
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

        let offeredSuites: [CryptoSuite]
        switch providerType {
        case .classic:
            let offeredSuitesResult = TwoAttemptHandshakeManager.getSuites(for: .classicOnly, cryptoProvider: provider)
            guard case .suites(let suites) = offeredSuitesResult else {
                throw HandshakeError.emptyOfferedSuites
            }
            offeredSuites = suites
        case .liboqsPQC, .applePQC:
            offeredSuites = [.mlkem768MLDSA65]
        case .liboqsPQCv2FS:
            let offeredSuitesResult = TwoAttemptHandshakeManager.getSuites(
                for: .pqcOnly,
                cryptoProvider: provider,
                pqcOfferMode: .preferredSingle
            )
            guard case .suites(let suites) = offeredSuitesResult else {
                throw HandshakeError.emptyOfferedSuites
            }
            offeredSuites = suites
        case .appleXWing:
            offeredSuites = [.xwingMLDSA]
        case .qPeriapt:
            offeredSuites = [.qperiaptABI2PolicyBound]
        }

        let protocolSignatureProvider = ProtocolSignatureProviderSelector.select(for: provider.tier)
        let sigAAlgorithm = protocolSignatureProvider.signatureAlgorithm

        // Q's KEM provider also exposes legacy OQS signing keys. The real
        // protocol selector uses Apple ML-DSA-65 at the Q tier, so create the
        // matching identity format instead of passing an OQS key to CryptoKit.
        let identityProvider: any CryptoProvider
        if providerType == .qPeriapt {
            #if HAS_APPLE_PQC_SDK
            guard #available(macOS 26.0, iOS 26.0, *) else {
                throw BenchmarkError.unavailableProvider("Apple ML-DSA-65")
            }
            identityProvider = ApplePQCCryptoProvider()
            #else
            throw BenchmarkError.unavailableProvider("Apple PQC SDK")
            #endif
        } else {
            identityProvider = provider
        }
        let initiatorKeyPair = try await identityProvider.generateKeyPair(for: .signing)
        let responderKeyPair = try await identityProvider.generateKeyPair(for: .signing)
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
        let initiatorKEMIdentityStore = try await BenchmarkHandshakeKEMIdentityStore.make(
            offeredSuites: offeredSuites,
            provider: provider
        )
        let responderKEMIdentityStore = try await BenchmarkHandshakeKEMIdentityStore.make(
            offeredSuites: offeredSuites,
            provider: provider
        )
        let initiatorKEMPublicKeys = try initiatorKEMIdentityStore.trustPublicKeys(for: offeredSuites)
        let responderKEMPublicKeys = try responderKEMIdentityStore.trustPublicKeys(for: offeredSuites)
        let trustProviderInitiator = BenchmarkTrustProvider(
            deviceId: peer.deviceId,
            identity: .init(algorithm: sigAAlgorithm, publicKey: responderKeyPair.publicKey.bytes),
            kemPublicKeys: responderKEMPublicKeys
        )
        let trustProviderResponder = BenchmarkTrustProvider(
            deviceId: peer.deviceId,
            identity: .init(algorithm: sigAAlgorithm, publicKey: initiatorKeyPair.publicKey.bytes),
            kemPublicKeys: initiatorKEMPublicKeys
        )

        let handshakeTimeout: Duration = (providerType == .classic) ? .seconds(15) : .seconds(25)
        let handshakePolicy: HandshakePolicy = (providerType == .classic) ? .default : .strictPQC
        let cryptoPolicy: CryptoPolicy
        switch providerType {
        case .appleXWing, .qPeriapt:
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
            initiatorKEMIdentityStore: initiatorKEMIdentityStore,
            responderKEMIdentityStore: responderKEMIdentityStore,
            handshakeTimeout: handshakeTimeout,
            handshakePolicy: handshakePolicy,
            cryptoPolicy: cryptoPolicy
        )
    }

    private static func makeBenchmarkPolicySession() async throws -> QPeriaptRuntimeSession {
        let material = QPeriaptProductionTrustRootMaterial.makeSignedPolicyMaterial()
        let store = BenchmarkPolicyStateStore(trustRootIdentifier: material.trustRootIdentifier)
        let session = try await QPeriaptPolicyRuntime().resolveSession(
            material: material,
            enrollmentMode: .explicitlyAuthorizedFirstEnrollment,
            trustedStateStore: store
        )
        try await QPeriaptPlatformPolicy.activateRuntimeSession(session)
        return session
    }

    private static func performHandshake(
        context: BenchmarkContext, sequence: Int, batch: Int, iteration: Int
    ) async throws -> BenchmarkSample {
        let initiatorTransport = BenchmarkTransport()
        let responderTransport = BenchmarkTransport()
        let initiator = try HandshakeDriver(
            transport: initiatorTransport, cryptoProvider: context.provider,
            protocolSignatureProvider: context.protocolSignatureProvider,
            protocolSigningKeyHandle: context.initiatorKeyHandle,
            sigAAlgorithm: context.sigAAlgorithm, identityPublicKey: context.initiatorIdentityPublicKey,
            offeredSuites: context.offeredSuites, policy: context.handshakePolicy,
            cryptoPolicy: context.cryptoPolicy, timeout: context.handshakeTimeout,
            trustProvider: context.trustProviderInitiator, kemIdentityStore: context.initiatorKEMIdentityStore
        )
        let responder = try HandshakeDriver(
            transport: responderTransport, cryptoProvider: context.provider,
            protocolSignatureProvider: context.protocolSignatureProvider,
            protocolSigningKeyHandle: context.responderKeyHandle,
            sigAAlgorithm: context.sigAAlgorithm, identityPublicKey: context.responderIdentityPublicKey,
            offeredSuites: context.offeredSuites, policy: context.handshakePolicy,
            cryptoPolicy: context.cryptoPolicy, timeout: context.handshakeTimeout,
            trustProvider: context.trustProviderResponder, kemIdentityStore: context.responderKEMIdentityStore
        )
        await initiatorTransport.setReceiver { [weak responder] peer, data in
            guard let responder else { throw BenchmarkError.missingReceiver }
            await responder.handleMessage(data, from: peer)
        }
        await responderTransport.setReceiver { [weak initiator] peer, data in
            guard let initiator else { throw BenchmarkError.missingReceiver }
            await initiator.handleMessage(data, from: peer)
        }
        do {
            let start = ContinuousClock.now
            let keys = try await withDeadline(timeout: context.handshakeTimeout, cancel: {
                await initiator.cancel()
                await responder.cancel()
            }) {
                try await initiator.initiateHandshake(with: context.peer)
            }
            let elapsed = ContinuousClock.now - start
            guard case .established(let remoteKeys) = await responder.getCurrentState(),
                  case .established = await initiator.getCurrentState(),
                  keys.negotiatedSuite == context.offeredSuites.first,
                  remoteKeys.negotiatedSuite == keys.negotiatedSuite,
                  keys.sendKey == remoteKeys.receiveKey, keys.receiveKey == remoteKeys.sendKey,
                  keys.transcriptHash == remoteKeys.transcriptHash,
                  keys.role == .initiator, remoteKeys.role == .responder else {
                throw BenchmarkError.invalidMeasurement("Both peers must establish the requested suite with matching directional keys and transcript")
            }
            guard await initiator.getAuthenticatedRemoteAuthority() != nil,
                  await responder.getAuthenticatedRemoteAuthority() != nil else {
                throw BenchmarkError.invalidMeasurement("Finished did not publish both authenticated identities")
            }
            guard let metrics = await initiator.getLastMetrics(), metrics.rttMs.isFinite, metrics.rttMs >= 0 else {
                throw BenchmarkError.invalidMeasurement("Handshake RTT is unavailable")
            }
            let sentA = await initiatorTransport.sentMessages
            let sentB = await responderTransport.sentMessages
            guard sentA.count == 2, sentB.count == 2 else {
                throw BenchmarkError.invalidMeasurement("Expected MessageA/MessageB and two Finished frames")
            }
            let sample = BenchmarkSample(
                sequence: sequence, batch: batch, iteration: iteration,
                provider: context.providerType.rawValue, suiteWireID: keys.negotiatedSuite.wireId,
                latencyMS: Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15,
                rttMS: metrics.rttMs, messageABytes: sentA[0].count, messageBBytes: sentB[0].count,
                finishedBytes: sentA[1].count + sentB[1].count
            )
            await initiatorTransport.close()
            await responderTransport.close()
            await initiator.cancel()
            await responder.cancel()
            return sample
        } catch {
            await initiatorTransport.close()
            await responderTransport.close()
            await initiator.cancel()
            await responder.cancel()
            throw error
        }
    }

    /// Cancellation explicitly reaches the driver continuations before the
    /// structured group joins. There is no detached handshake task to outlive it.
    static func withDeadline<T: Sendable>(
        timeout: Duration,
        cancel: @escaping @Sendable () async -> Void,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw BenchmarkError.timeout
            }
            defer { group.cancelAll() }
            do {
                guard let result = try await group.next() else {
                    throw BenchmarkError.invalidMeasurement("Deadline group returned no result")
                }
                return result
            } catch {
                await cancel()
                throw error
            }
        }
    }

    private static func encodeIdentityPublicKey(_ publicKey: Data, algorithm: SignatureAlgorithm) -> Data {
        IdentityPublicKeys(protocolPublicKey: publicKey, protocolAlgorithm: algorithm, secureEnclavePublicKey: nil).encoded
    }
}

private struct BenchmarkTrustProvider: ExactProtocolIdentityHandshakeTrustProvider {
    let deviceId: String
    let identity: TrustedProtocolIdentityRawKey
    let kemPublicKeys: [CryptoSuite: Data]

    func trustedProtocolIdentityRawKeys(for deviceId: String) async -> [TrustedProtocolIdentityRawKey] {
        deviceId == self.deviceId ? [identity] : []
    }
    func requiresPinnedProtocolIdentity(for deviceId: String) async -> Bool { true }
    func trustedFingerprint(for deviceId: String) async -> String? { nil }
    func trustedKEMPublicKeys(for deviceId: String) async -> [CryptoSuite: Data] {
        deviceId == self.deviceId ? kemPublicKeys : [:]
    }
    func trustedSecureEnclavePublicKey(for deviceId: String) async -> Data? { nil }
}

/// Only the isolated benchmark process uses this store. Product enrollment
/// remains in its durable Keychain store; this is not a persistence benchmark.
private actor BenchmarkPolicyStateStore: QPeriaptTrustedStateStore {
    let trustRootIdentifier: String
    private var state: Data?
    init(trustRootIdentifier: String) { self.trustRootIdentifier = trustRootIdentifier }
    func loadTrustedState(trustRootIdentifier: String) throws -> Data? {
        try validate(trustRootIdentifier)
        return state
    }
    func compareAndSwapTrustedState(expectedPreviousState: Data?, newState: Data, trustRootIdentifier: String) throws -> Bool {
        try validate(trustRootIdentifier)
        guard newState.count == 36 else {
            throw QPeriaptPolicyRuntimeError.invalidTrustedStateLength(actual: newState.count, expected: 36)
        }
        guard expectedPreviousState == state else { return false }
        state = newState
        return true
    }
    private func validate(_ identifier: String) throws {
        guard identifier == trustRootIdentifier else {
            throw QPeriaptPolicyRuntimeError.invalidTrustRootIdentifier
        }
    }
}
