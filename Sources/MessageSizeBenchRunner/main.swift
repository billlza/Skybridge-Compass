import Foundation
import SkyBridgeCore

@main
struct MessageSizeBenchRunner {
    private enum ProviderType: CaseIterable {
        case classic
        case liboqsPQC
        case applePQC
        case appleXWing

        var label: String {
            switch self {
            case .classic:
                return "Classic"
            case .liboqsPQC:
                return "PQC-liboqs"
            case .applePQC:
                return "PQC-CryptoKit"
            case .appleXWing:
                return "XWing"
            }
        }

        var policy: HandshakePolicy {
            switch self {
            case .classic:
                return .default
            case .liboqsPQC, .applePQC, .appleXWing:
                return .strictPQC
            }
        }

        var timeout: Duration {
            switch self {
            case .classic:
                return .seconds(15)
            case .liboqsPQC, .applePQC, .appleXWing:
                return .seconds(25)
            }
        }
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

    private struct SizeBreakdown {
        let label: String
        let total: Int
        let signature: Int
        let keyshare: Int
        let identity: Int

        var overhead: Int {
            max(0, total - signature - keyshare - identity)
        }

        var csvRow: String {
            "\(label),\(total),\(signature),\(keyshare),\(identity),\(overhead)"
        }
    }

    static func main() async {
        do {
            #if HAS_APPLE_PQC_SDK
            print("[SIZE] HAS_APPLE_PQC_SDK=1 (compiled with CryptoKit PQC symbols)")
            #else
            print("[SIZE] HAS_APPLE_PQC_SDK=0 (compiled without CryptoKit PQC symbols)")
            #endif

            let capability = CryptoProviderFactory.detectCapability()
            var targets: [ProviderType] = [.classic]

            if capability.hasLiboqs {
                targets.append(.liboqsPQC)
            } else {
                print("[SIZE] liboqs not available, skipping PQC-liboqs")
            }

            if capability.hasApplePQC {
                targets.append(.applePQC)
                targets.append(.appleXWing)
            } else {
                print("[SIZE] Apple PQC not available, skipping PQC-CryptoKit")
            }

            var breakdowns: [SizeBreakdown] = []
            for target in targets {
                let (messageA, messageB) = try await captureMessages(providerType: target)
                breakdowns.append(try breakdown(for: messageA, label: "MessageA.\(target.label)"))
                breakdowns.append(try breakdown(for: messageB, label: "MessageB.\(target.label)"))
            }

            // Provide canonical "PQC" rows for downstream plots/tables (provider-independent sizes).
            // Prefer liboqs (open-source reference) when available, else fall back to CryptoKit PQC.
            func find(_ label: String) -> SizeBreakdown? {
                breakdowns.first(where: { $0.label == label })
            }
            if find("MessageA.PQC") == nil || find("MessageB.PQC") == nil {
                let referenceA = find("MessageA.PQC-liboqs") ?? find("MessageA.PQC-CryptoKit")
                let referenceB = find("MessageB.PQC-liboqs") ?? find("MessageB.PQC-CryptoKit")
                if let referenceA, find("MessageA.PQC") == nil {
                    breakdowns.append(SizeBreakdown(
                        label: "MessageA.PQC",
                        total: referenceA.total,
                        signature: referenceA.signature,
                        keyshare: referenceA.keyshare,
                        identity: referenceA.identity
                    ))
                }
                if let referenceB, find("MessageB.PQC") == nil {
                    breakdowns.append(SizeBreakdown(
                        label: "MessageB.PQC",
                        total: referenceB.total,
                        signature: referenceB.signature,
                        keyshare: referenceB.keyshare,
                        identity: referenceB.identity
                    ))
                }
            }

            let finishedSize = HandshakeFinished(
                direction: .responderToInitiator,
                mac: Data(repeating: 0, count: 32)
            ).encoded.count
            breakdowns.append(SizeBreakdown(
                label: "Finished",
                total: finishedSize,
                signature: 0,
                keyshare: 0,
                identity: 0
            ))

            try writeBreakdownCSV(breakdowns)
        } catch {
            fputs("[SIZE] Failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func captureMessages(
        providerType: ProviderType
    ) async throws -> (HandshakeMessageA, HandshakeMessageB) {
        let context = try await prepareBenchmarkContext(providerType: providerType)

        let initiatorTransport = BenchmarkTransport()
        let responderTransport = BenchmarkTransport()

        let initiatorDriver = try HandshakeDriver(
            transport: initiatorTransport,
            cryptoProvider: context.provider,
            protocolSignatureProvider: context.protocolSignatureProvider,
            protocolSigningKeyHandle: context.initiatorKeyHandle,
            sigAAlgorithm: context.sigAAlgorithm,
            identityPublicKey: context.initiatorIdentityPublicKey,
            offeredSuites: context.offeredSuites,
            policy: context.handshakePolicy,
            cryptoPolicy: context.cryptoPolicy,
            timeout: context.handshakeTimeout,
            trustProvider: context.trustProviderInitiator
        )

        let responderDriver = try HandshakeDriver(
            transport: responderTransport,
            cryptoProvider: context.provider,
            protocolSignatureProvider: context.protocolSignatureProvider,
            protocolSigningKeyHandle: context.responderKeyHandle,
            sigAAlgorithm: context.sigAAlgorithm,
            identityPublicKey: context.responderIdentityPublicKey,
            offeredSuites: context.offeredSuites,
            policy: context.handshakePolicy,
            cryptoPolicy: context.cryptoPolicy,
            timeout: context.handshakeTimeout,
            trustProvider: context.trustProviderResponder
        )

        await initiatorTransport.setOnSend { [responderDriver] peer, data in
            // If SBP2 is enabled, the sender wraps frames; receiver must unwrap before passing to HandshakeDriver.
            let unwrapped = TrafficPadding.unwrapIfNeeded(data, label: "rx")
            await responderDriver.handleMessage(unwrapped, from: peer)
        }
        await responderTransport.setOnSend { [initiatorDriver] peer, data in
            let unwrapped = TrafficPadding.unwrapIfNeeded(data, label: "rx")
            await initiatorDriver.handleMessage(unwrapped, from: peer)
        }

        let handshakeTask = Task {
            try await initiatorDriver.initiateHandshake(with: context.peer)
        }

        _ = try await withThrowingTaskGroup(of: SessionKeys.self) { group in
            group.addTask {
                try await handshakeTask.value
            }
            group.addTask {
                try await Task.sleep(for: context.handshakeTimeout)
                throw NSError(domain: "MessageSizeBench", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Handshake task timeout"
                ])
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }

        let initiatorSent = await initiatorTransport.getSentMessages()
        let responderSent = await responderTransport.getSentMessages()

        guard let rawA = initiatorSent.first?.1,
              let rawB = responderSent.first?.1 else {
            throw NSError(domain: "MessageSizeBench", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Missing handshake messages"
            ])
        }

        // Size bench is about message payload encoding; unwrap optional framing layers before decode.
        let unwrappedA = HandshakePadding.unwrapIfNeeded(
            TrafficPadding.unwrapIfNeeded(rawA, label: "rx"),
            label: "rx"
        )
        let unwrappedB = HandshakePadding.unwrapIfNeeded(
            TrafficPadding.unwrapIfNeeded(rawB, label: "rx"),
            label: "rx"
        )

        let messageA = try HandshakeMessageA.decode(from: unwrappedA)
        let messageB = try HandshakeMessageB.decode(from: unwrappedB)
        return (messageA, messageB)
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
            throw NSError(domain: "MessageSizeBench", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "liboqs not available"
            ])
            #endif
        case .applePQC:
            #if HAS_APPLE_PQC_SDK
            if #available(iOS 26.0, macOS 26.0, *) {
                provider = ApplePQCCryptoProvider()
            } else {
                throw NSError(domain: "MessageSizeBench", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "Apple PQC not available"
                ])
            }
            #else
            throw NSError(domain: "MessageSizeBench", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Apple PQC SDK not available"
            ])
            #endif
        case .appleXWing:
            #if HAS_APPLE_PQC_SDK
            if #available(iOS 26.0, macOS 26.0, *) {
                provider = AppleXWingCryptoProvider()
            } else {
                throw NSError(domain: "MessageSizeBench", code: 5, userInfo: [
                    NSLocalizedDescriptionKey: "Apple X-Wing not available"
                ])
            }
            #else
            throw NSError(domain: "MessageSizeBench", code: 5, userInfo: [
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
            handshakeTimeout: providerType.timeout,
            handshakePolicy: providerType.policy,
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

    private static func breakdown(for messageA: HandshakeMessageA, label: String) throws -> SizeBreakdown {
        let encoded = messageA.encoded
        let keyShareBytes = messageA.keyShares.reduce(0) { $0 + $1.shareBytes.count }
        let signatureBytes = messageA.signature.count + (messageA.secureEnclaveSignature?.count ?? 0)
        let identityBytes = messageA.identityPublicKey.count
        return SizeBreakdown(
            label: label,
            total: encoded.count,
            signature: signatureBytes,
            keyshare: keyShareBytes,
            identity: identityBytes
        )
    }

    private static func breakdown(for messageB: HandshakeMessageB, label: String) throws -> SizeBreakdown {
        let encoded = messageB.encoded
        let signatureBytes = messageB.signature.count + (messageB.secureEnclaveSignature?.count ?? 0)
        let identityBytes = messageB.identityPublicKey.count
        let keyShareBytes = messageB.responderShare.count
        return SizeBreakdown(
            label: label,
            total: encoded.count,
            signature: signatureBytes,
            keyshare: keyShareBytes,
            identity: identityBytes
        )
    }

    private static func writeBreakdownCSV(_ rows: [SizeBreakdown]) throws {
        let artifactsDir = URL(fileURLWithPath: "Artifacts")
        try FileManager.default.createDirectory(at: artifactsDir, withIntermediateDirectories: true)

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateString = dateFormatter.string(from: Date())
        let csvPath = artifactsDir.appendingPathComponent("message_sizes_\(dateString).csv")

        var content = "message,total_bytes,signature_bytes,keyshare_bytes,identity_bytes,overhead_bytes\n"
        for row in rows {
            content += row.csvRow + "\n"
        }
        try content.write(to: csvPath, atomically: true, encoding: .utf8)
        print("[SIZE] CSV written to: \(csvPath.path)")
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
