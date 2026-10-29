import Foundation
import SkyBridgeCore

@main
struct MessageSizeBenchRunner {
    private enum ProviderType: CaseIterable {
        case classic
        case liboqsPQC
        case liboqsPQCv2FS
        case applePQC
        case appleXWing

        var label: String {
            switch self {
            case .classic:
                return "Classic"
            case .liboqsPQC:
                return "PQC-liboqs"
            case .liboqsPQCv2FS:
                return "PQC-liboqs-v2fs"
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
            case .liboqsPQC, .liboqsPQCv2FS, .applePQC, .appleXWing:
                return .strictPQC
            }
        }

        var timeout: Duration {
            switch self {
            case .classic:
                return .seconds(15)
            case .liboqsPQC, .liboqsPQCv2FS, .applePQC, .appleXWing:
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
                targets.append(.liboqsPQCv2FS)
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
                print("[SIZE] capturing \(target.label)")
                let (messageA, messageB): (HandshakeMessageA, HandshakeMessageB)
                do {
                    (messageA, messageB) = try await captureMessages(providerType: target)
                } catch {
                    throw NSError(domain: "MessageSizeBench", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "\(target.label): \(error.localizedDescription)"
                    ])
                }
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
        let messageA = try createSyntheticMessageA(for: providerType)
        let messageB = try createSyntheticMessageB(for: providerType)
        return (messageA, messageB)
    }

    private static func createSyntheticMessageA(
        for providerType: ProviderType
    ) throws -> HandshakeMessageA {
        let supportedSuites: [CryptoSuite]
        let keyShares: [HandshakeKeyShare]
        let signature: Data
        let identityPublicKeys: IdentityPublicKeys
        let policy: HandshakePolicy
        let capabilities: CryptoCapabilities
        let initiatorContribution: Data?

        switch providerType {
        case .classic:
            supportedSuites = [.x25519Ed25519]
            keyShares = [HandshakeKeyShare(suite: .x25519Ed25519, shareBytes: Data(repeating: 0xAA, count: 32))]
            signature = Data(repeating: 0xBB, count: 64)
            identityPublicKeys = IdentityPublicKeys(
                protocolPublicKey: Data(repeating: 0xCC, count: 32),
                protocolAlgorithm: .ed25519,
                secureEnclavePublicKey: nil
            )
            policy = .default
            capabilities = CryptoCapabilities(
                supportedKEM: ["X25519"],
                supportedSignature: ["Ed25519"],
                supportedAuthProfiles: ["classic"],
                supportedAEAD: ["AES-256-GCM"],
                pqcAvailable: false,
                platformVersion: "macOS",
                providerType: .classic
            )
            initiatorContribution = nil

        case .liboqsPQC, .applePQC:
            supportedSuites = [.mlkem768MLDSA65]
            keyShares = [HandshakeKeyShare(suite: .mlkem768MLDSA65, shareBytes: Data(repeating: 0xAA, count: 1088))]
            signature = Data(repeating: 0xBB, count: 3309)
            identityPublicKeys = IdentityPublicKeys(
                protocolPublicKey: Data(repeating: 0xCC, count: 1952),
                protocolAlgorithm: .mlDSA65,
                secureEnclavePublicKey: nil
            )
            policy = .strictPQC
            capabilities = CryptoCapabilities(
                supportedKEM: ["ML-KEM-768"],
                supportedSignature: ["ML-DSA-65"],
                supportedAuthProfiles: ["pqc"],
                supportedAEAD: ["AES-256-GCM"],
                pqcAvailable: true,
                platformVersion: "macOS",
                providerType: providerType == .applePQC ? .cryptoKitPQC : .liboqs
            )
            initiatorContribution = nil

        case .liboqsPQCv2FS:
            supportedSuites = [.mlkem768MLDSA65FS]
            keyShares = [HandshakeKeyShare(suite: .mlkem768MLDSA65FS, shareBytes: Data(repeating: 0xAA, count: 1088))]
            signature = Data(repeating: 0xBB, count: 3309)
            identityPublicKeys = IdentityPublicKeys(
                protocolPublicKey: Data(repeating: 0xCC, count: 1952),
                protocolAlgorithm: .mlDSA65,
                secureEnclavePublicKey: nil
            )
            policy = .strictPQC
            capabilities = CryptoCapabilities(
                supportedKEM: ["ML-KEM-768-FS"],
                supportedSignature: ["ML-DSA-65"],
                supportedAuthProfiles: ["pqc-v2-fs"],
                supportedAEAD: ["AES-256-GCM"],
                pqcAvailable: true,
                platformVersion: "macOS",
                providerType: .liboqs
            )
            initiatorContribution = Data(repeating: 0xAB, count: 32)

        case .appleXWing:
            supportedSuites = [.xwingMLDSA]
            keyShares = [HandshakeKeyShare(suite: .xwingMLDSA, shareBytes: Data(repeating: 0xAA, count: 1216))]
            signature = Data(repeating: 0xBB, count: 3309)
            identityPublicKeys = IdentityPublicKeys(
                protocolPublicKey: Data(repeating: 0xCC, count: 1952),
                protocolAlgorithm: .mlDSA65,
                secureEnclavePublicKey: nil
            )
            policy = .strictPQC
            capabilities = CryptoCapabilities(
                supportedKEM: ["X-Wing"],
                supportedSignature: ["ML-DSA-65"],
                supportedAuthProfiles: ["hybrid"],
                supportedAEAD: ["AES-256-GCM"],
                pqcAvailable: true,
                platformVersion: "macOS",
                providerType: .cryptoKitPQC
            )
            initiatorContribution = nil
        }

        return HandshakeMessageA(
            version: 1,
            supportedSuites: supportedSuites,
            keyShares: keyShares,
            clientNonce: Data(repeating: 0x11, count: 32),
            policy: policy,
            capabilities: capabilities,
            signature: signature,
            identityPublicKeys: identityPublicKeys,
            secureEnclaveSignature: nil,
            initiatorContribution: initiatorContribution
        )
    }

    private static func createSyntheticMessageB(
        for providerType: ProviderType
    ) throws -> HandshakeMessageB {
        let selectedSuite: CryptoSuite
        let responderShare: Data
        let signature: Data
        let identityPublicKeys: IdentityPublicKeys
        let encryptedPayload: HPKESealedBox

        switch providerType {
        case .classic:
            selectedSuite = .x25519Ed25519
            responderShare = Data(repeating: 0xDD, count: 32)
            signature = Data(repeating: 0xEE, count: 64)
            identityPublicKeys = IdentityPublicKeys(
                protocolPublicKey: Data(repeating: 0xFF, count: 32),
                protocolAlgorithm: .ed25519,
                secureEnclavePublicKey: nil
            )
            encryptedPayload = HPKESealedBox(
                encapsulatedKey: Data(repeating: 0xAB, count: 32),
                nonce: Data(repeating: 0xCD, count: 12),
                ciphertext: Data(repeating: 0x33, count: 64),
                tag: Data(repeating: 0xEF, count: 16)
            )

        case .liboqsPQC, .applePQC:
            selectedSuite = .mlkem768MLDSA65
            responderShare = Data()
            signature = Data(repeating: 0xEE, count: 3309)
            identityPublicKeys = IdentityPublicKeys(
                protocolPublicKey: Data(repeating: 0xFF, count: 1952),
                protocolAlgorithm: .mlDSA65,
                secureEnclavePublicKey: nil
            )
            encryptedPayload = HPKESealedBox(
                encapsulatedKey: Data(),
                nonce: Data(repeating: 0xCD, count: 12),
                ciphertext: Data(repeating: 0x33, count: 64),
                tag: Data(repeating: 0xEF, count: 16)
            )

        case .liboqsPQCv2FS:
            selectedSuite = .mlkem768MLDSA65FS
            responderShare = Data(repeating: 0xDD, count: 32)
            signature = Data(repeating: 0xEE, count: 3309)
            identityPublicKeys = IdentityPublicKeys(
                protocolPublicKey: Data(repeating: 0xFF, count: 1952),
                protocolAlgorithm: .mlDSA65,
                secureEnclavePublicKey: nil
            )
            encryptedPayload = HPKESealedBox(
                encapsulatedKey: Data(),
                nonce: Data(repeating: 0xCD, count: 12),
                ciphertext: Data(repeating: 0x33, count: 64),
                tag: Data(repeating: 0xEF, count: 16)
            )

        case .appleXWing:
            selectedSuite = .xwingMLDSA
            responderShare = Data()
            signature = Data(repeating: 0xEE, count: 3309)
            identityPublicKeys = IdentityPublicKeys(
                protocolPublicKey: Data(repeating: 0xFF, count: 1952),
                protocolAlgorithm: .mlDSA65,
                secureEnclavePublicKey: nil
            )
            encryptedPayload = HPKESealedBox(
                encapsulatedKey: Data(),
                nonce: Data(repeating: 0xCD, count: 12),
                ciphertext: Data(repeating: 0x33, count: 64),
                tag: Data(repeating: 0xEF, count: 16)
            )
        }

        return HandshakeMessageB(
            version: 1,
            selectedSuite: selectedSuite,
            responderShare: responderShare,
            serverNonce: Data(repeating: 0x22, count: 32),
            encryptedPayload: encryptedPayload,
            signature: signature,
            identityPublicKeys: identityPublicKeys,
            secureEnclaveSignature: nil
        )
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

        // Keep this bench runner independent from Keychain-backed identity stores.
        // We only need deterministic, suite-compatible peer KEM material to drive
        // handshake serialization and measure message sizes.
        var canonicalKeys: [CryptoSuite: Data] = [:]
        var kemPublicKeys: [CryptoSuite: Data] = [:]
        for suite in pqcSuites {
            let canonical = suite.canonicalKEMSuite
            let publicKey: Data
            if let existing = canonicalKeys[canonical] {
                publicKey = existing
            } else {
                let keyPair = try await provider.generateKeyPair(for: .keyExchange)
                publicKey = keyPair.publicKey.bytes
                canonicalKeys[canonical] = publicKey
            }
            kemPublicKeys[suite] = publicKey
            kemPublicKeys[canonical] = kemPublicKeys[canonical] ?? publicKey
            if let upgraded = canonical.forwardSecureUpgradeSuite {
                kemPublicKeys[upgraded] = kemPublicKeys[upgraded] ?? publicKey
            }
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
        let artifactsDir = ArtifactPaths.writableArtifactsDirectory()
        try FileManager.default.createDirectory(at: artifactsDir, withIntermediateDirectories: true)

        let env = ProcessInfo.processInfo.environment
        let dateString: String
        if let v = env["ARTIFACT_DATE"], !v.isEmpty {
            dateString = v
        } else if let v = env["SKYBRIDGE_ARTIFACT_DATE"], !v.isEmpty {
            dateString = v
        } else {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd"
            dateString = dateFormatter.string(from: Date())
        }
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
