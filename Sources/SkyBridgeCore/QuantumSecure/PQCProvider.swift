import Foundation
import OSLog
#if canImport(CryptoKit)
import CryptoKit
#endif
import OQSRAII

@available(macOS 14.0, *)
@preconcurrency public protocol PQCProvider: Sendable {
    var suite: PQCAlgorithmSuite { get }
    var backend: PQCBackend { get }
    func sign(data: Data, peerId: String, algorithm: String) async throws -> Data
    func verify(data: Data, signature: Data, peerId: String, algorithm: String) async -> Bool
    func kemEncapsulate(peerId: String, kemVariant: String) async throws -> (sharedSecret: Data, encapsulated: Data)
    func kemDecapsulate(peerId: String, encapsulated: Data, kemVariant: String) async throws -> Data
    func hpkeSeal(recipientPeerId: String, plaintext: Data, associatedData: Data?) async throws -> (ciphertext: Data, encapsulatedKey: Data)
    func hpkeOpen(recipientPeerId: String, ciphertext: Data, encapsulatedKey: Data, associatedData: Data?) async throws -> Data
}

/// Exact runtime capabilities for providers that participate in wire
/// negotiation. A provider that does not conform is treated as advertising no
/// PQC variants; callers must never infer support from enum case lists.
@available(macOS 14.0, *)
public protocol PQCProviderCapabilityReporting: Sendable {
    var supportedKEMVariants: Set<String> { get }
    var supportedSignatureAlgorithms: Set<String> { get }
}

/// Narrow trust-injection boundary for remote signing keys that were already
/// authenticated by the protocol handshake and canonical trust store.
/// Implementations keep these keys instance-local; this protocol is not a key
/// discovery or trust-on-first-use mechanism.
@available(macOS 14.0, *)
public protocol AuthenticatedPQCSigningKeyConsumer: Sendable {
    func registerAuthenticatedSigningPublicKey(
        _ publicKey: Data,
        peerId: String,
        algorithm: String
    ) async throws
}

/// Exposes only the public half of a local signing identity. Callers may send
/// this value through an authenticated pairing channel; possession of the key
/// does not itself establish remote trust.
@available(macOS 14.0, *)
public protocol PQCLocalSigningPublicKeyProviding: Sendable {
    func localSigningPublicKey(peerId: String, algorithm: String) async throws -> Data
}

@available(macOS 14.0, *)
public enum PQCSigningTrustError: Error, LocalizedError, Sendable, Equatable {
    case invalidPeerId
    case unsupportedSignatureAlgorithm(String)
    case invalidPublicKeyLength(algorithm: String, expected: Int, actual: Int)
    case authenticatedKeyConflict(peerId: String, algorithm: String)
    case corruptLocalKeyPair(peerId: String, algorithm: String)
    case localSigningPublicKeyUnavailable(peerId: String, algorithm: String)

    public var errorDescription: String? {
        switch self {
        case .invalidPeerId:
            return "PQC signing peer identifier is empty"
        case .unsupportedSignatureAlgorithm(let algorithm):
            return "Unsupported PQC signature algorithm: \(algorithm)"
        case .invalidPublicKeyLength(let algorithm, let expected, let actual):
            return "Invalid \(algorithm) public key length: expected \(expected), got \(actual)"
        case .authenticatedKeyConflict:
            return "An authenticated PQC signing key is already pinned for this peer and algorithm"
        case .corruptLocalKeyPair(_, let algorithm):
            return "Corrupt or incomplete local \(algorithm) key pair"
        case .localSigningPublicKeyUnavailable(_, let algorithm):
            return "No local \(algorithm) signing public key is available"
        }
    }
}

@available(macOS 14.0, *)
public enum PQCAlgorithmSuite: String, Sendable {
    case classicP256 = "classic-p256"
    case pqcMlKemMlDsa = "pqc-mlkem-mldsa"
    case hybridXWing = "hybrid-xwing-mlkem768-x25519"
}

@available(macOS 14.0, *)
public enum PQCBackend: String, Sendable {
    case none
    case applePQC
    case liboqs
}

@available(macOS 14.0, *)
@preconcurrency public protocol PQCHPKEProvider: Sendable {
    func senderContext(recipientPublicKey: Data, suite: PQCAlgorithmSuite) throws -> HPKESenderContext
    func recipientContext(recipientPrivateKey: Data, suite: PQCAlgorithmSuite, encapsulatedKey: Data) throws -> HPKERecipientContext
}

@available(macOS 14.0, *)
public struct HPKESenderContext: Sendable {
    public let suite: PQCAlgorithmSuite
    private let sealFn: @Sendable (Data, Data) throws -> (Data, Data)
    public init(suite: PQCAlgorithmSuite, sealFn: @escaping @Sendable (Data, Data) throws -> (Data, Data)) {
        self.suite = suite
        self.sealFn = sealFn
    }
    public func seal(_ plaintext: Data, authenticating aad: Data) throws -> (ciphertext: Data, encapsulatedKey: Data) {
        return try sealFn(plaintext, aad)
    }
}

@available(macOS 14.0, *)
public struct HPKERecipientContext: Sendable {
    public let suite: PQCAlgorithmSuite
    private let openFn: @Sendable (Data, Data) throws -> Data
    public init(suite: PQCAlgorithmSuite, openFn: @escaping @Sendable (Data, Data) throws -> Data) {
        self.suite = suite
        self.openFn = openFn
    }
    public func open(_ ciphertext: Data, authenticating aad: Data) throws -> Data {
        return try openFn(ciphertext, aad)
    }
}

@available(macOS 14.0, *)
public enum PQCProviderFactory {
    private static let logger = Logger(subsystem: "com.skybridge.quantum", category: "PQCProviderFactory")
    
    public static func makeProvider() -> PQCProvider? {
        makeProvider(
            for: .pqcMlKemMlDsa,
            scopeSource: .requiredEntitlement
        )
    }

    public static func makeProvider(for suite: PQCAlgorithmSuite) -> PQCProvider? {
        makeProvider(for: suite, scopeSource: .requiredEntitlement)
    }

    static func makeProvider(
        scopeSource: SkyBridgeSharedIdentityScopeSource
    ) -> PQCProvider? {
        makeProvider(for: .pqcMlKemMlDsa, scopeSource: scopeSource)
    }

    static func makeProvider(
        for suite: PQCAlgorithmSuite,
        scopeSource: SkyBridgeSharedIdentityScopeSource
    ) -> PQCProvider? {
        switch suite {
        case .classicP256:
            return nil
        case .hybridXWing:
            return makeHPKEProvider(
                for: .hybridXWing,
                scopeSource: scopeSource
            )
        case .pqcMlKemMlDsa:
            return makeMLKEMMLDSAProvider(scopeSource: scopeSource)
        }
    }

    public static func makeHPKEProvider(for suite: PQCAlgorithmSuite) -> (PQCProvider & PQCHPKEProvider)? {
        makeHPKEProvider(for: suite, scopeSource: .requiredEntitlement)
    }

    static func makeHPKEProvider(
        for suite: PQCAlgorithmSuite,
        scopeSource: SkyBridgeSharedIdentityScopeSource
    ) -> (PQCProvider & PQCHPKEProvider)? {
        guard suite == .hybridXWing else {
            return nil
        }

        #if HAS_APPLE_PQC_SDK
        if #available(iOS 26.0, macOS 26.0, *), isAppleXWingHPKEAvailable() {
            logger.info("🍎 使用Apple CryptoKit X-Wing HPKE")
            return ApplePQCProvider(
                suite: .hybridXWing,
                keyPairAuthority: .active,
                scopeSource: scopeSource
            )
        }
        #endif

        logger.warning("⚠️ 无可用的X-Wing HPKE实现")
        return nil
    }

    public static func supportsSuite(_ suite: PQCAlgorithmSuite) -> Bool {
        supportsSuite(suite, scopeSource: .requiredEntitlement)
    }

    static func supportsSuite(
        _ suite: PQCAlgorithmSuite,
        scopeSource: SkyBridgeSharedIdentityScopeSource
    ) -> Bool {
        switch suite {
        case .classicP256:
            return true
        case .hybridXWing:
            #if HAS_APPLE_PQC_SDK
            if #available(iOS 26.0, macOS 26.0, *) {
                return isAppleXWingHPKEAvailable()
            }
            #endif
            return false
        case .pqcMlKemMlDsa:
            return (try? previewMLKEMMLDSABackend(scopeSource: scopeSource)) != nil
        }
    }

    private static func makeMLKEMMLDSAProvider(
        scopeSource: SkyBridgeSharedIdentityScopeSource
    ) -> PQCProvider? {
        do {
            switch try resolvedMLKEMMLDSABackend(scopeSource: scopeSource) {
            case .appleCryptoKit:
                #if HAS_APPLE_PQC_SDK
                if #available(iOS 26.0, macOS 26.0, *) {
                    logger.info("🍎 使用Apple CryptoKit原生PQC (iOS/macOS 26.0+)")
                    return ApplePQCProvider(
                        suite: .pqcMlKemMlDsa,
                        keyPairAuthority: .active,
                        scopeSource: scopeSource
                    )
                }
                #endif
                logger.error("PQC backend authority selected unavailable Apple CryptoKit")
                return nil
            case .liboqs:
                logger.info("🔧 使用OQS/liboqs PQC实现")
                return OQSProvider(
                    keyPairAuthority: .active,
                    scopeSource: scopeSource
                )
            }
        } catch {
            logger.error("PQC backend resolution failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
    /// 检查当前使用的PQC提供者类型
    public static var currentProvider: String {
        currentProvider(scopeSource: .requiredEntitlement)
    }

    static func currentProvider(
        scopeSource: SkyBridgeSharedIdentityScopeSource
    ) -> String {
        switch try? previewMLKEMMLDSABackend(scopeSource: scopeSource) {
        case .appleCryptoKit:
            return "Apple CryptoKit (原生)"
        case .liboqs:
            return "OQS/liboqs"
        case nil:
            return "不可用"
        }
    }

    private static func resolvedMLKEMMLDSABackend(
        scopeSource: SkyBridgeSharedIdentityScopeSource
    ) throws -> PQCKeyPairStoreBackend {
        let appleAvailable = isAppleMLKEMMLDSAAvailable()
        let liboqsAvailable = isOQSAvailable()
        return try PQCBackendAuthorityStore.resolveActiveBackend(
            preferred: appleAvailable ? .appleCryptoKit : .liboqs,
            appleAvailable: appleAvailable,
            liboqsAvailable: liboqsAvailable,
            scopeSource: scopeSource
        )
    }

    private static func previewMLKEMMLDSABackend(
        scopeSource: SkyBridgeSharedIdentityScopeSource
    ) throws -> PQCKeyPairStoreBackend {
        let appleAvailable = isAppleMLKEMMLDSAAvailable()
        let liboqsAvailable = isOQSAvailable()
        return try PQCBackendAuthorityStore.previewActiveBackend(
            preferred: appleAvailable ? .appleCryptoKit : .liboqs,
            appleAvailable: appleAvailable,
            liboqsAvailable: liboqsAvailable,
            scopeSource: scopeSource
        )
    }

    private static func isAppleMLKEMMLDSAAvailable() -> Bool {
        #if HAS_APPLE_PQC_SDK
        if #available(iOS 26.0, macOS 26.0, *) {
            return isApplePQCAvailable()
        }
        #endif
        return false
    }
    #if HAS_APPLE_PQC_SDK
    private static func isApplePQCAvailable() -> Bool {
        if #available(iOS 26.0, macOS 26.0, *) {
            do {
                _ = try MLKEM768.PrivateKey()
                _ = try MLDSA65.PrivateKey()
                return true
            } catch {
                return false
            }
        }
        return false
    }

    private static func isAppleXWingHPKEAvailable() -> Bool {
        if #available(iOS 26.0, macOS 26.0, *) {
            do {
                let recipientPrivateKey = try XWingMLKEM768X25519.PrivateKey.generate()
                let ciphersuite = HPKE.Ciphersuite.XWingMLKEM768X25519_SHA256_AES_GCM_256
                let info = Data("SkyBridge-XWing-HPKE-runtime-probe".utf8)
                let plaintext = Data("probe".utf8)
                var sender = try HPKE.Sender(
                    recipientKey: recipientPrivateKey.publicKey,
                    ciphersuite: ciphersuite,
                    info: info
                )
                let ciphertext = try sender.seal(plaintext, authenticating: info)
                var recipient = try HPKE.Recipient(
                    privateKey: recipientPrivateKey,
                    ciphersuite: ciphersuite,
                    info: info,
                    encapsulatedKey: sender.encapsulatedKey
                )
                return try recipient.open(ciphertext, authenticating: info) == plaintext
            } catch {
                return false
            }
        }
        return false
    }
    #endif
    private static func isOQSAvailable() -> Bool {
 // 检查OQS RAII是否可用
        #if canImport(OQSRAII)
        return true
        #else
        return false
        #endif
    }
}

#if HAS_APPLE_PQC_SDK
@available(iOS 26.0, macOS 26.0, *)
enum XWingKeyMaterialStoreError: Error, LocalizedError, Sendable, Equatable {
    case invalidPeerId
    case invalidLegacyPrivateKey
    case invalidLegacyPublicKey
    case ambiguousLegacyPublicKeyRole
    case conflictingAuthenticatedRemotePublicKey
    case authenticatedRemotePublicKeyMissingAfterInsert
    case stagedMaterialIsNotOperational

    var errorDescription: String? {
        switch self {
        case .invalidPeerId:
            return "X-Wing peer identity is empty"
        case .invalidLegacyPrivateKey:
            return "A legacy X-Wing private-key candidate is malformed"
        case .invalidLegacyPublicKey:
            return "A legacy X-Wing public-key candidate is malformed"
        case .ambiguousLegacyPublicKeyRole:
            return "A legacy X-Wing public key cannot be classified without the local canonical identity"
        case .conflictingAuthenticatedRemotePublicKey:
            return "Authenticated X-Wing remote public-key candidates conflict"
        case .authenticatedRemotePublicKeyMissingAfterInsert:
            return "The authenticated X-Wing remote public key is missing after atomic insertion"
        case .stagedMaterialIsNotOperational:
            return "Staged X-Wing material cannot be used by operational HPKE paths"
        }
    }
}

/// Owns the role split between the local X-Wing identity and an authenticated
/// remote recipient key. Legacy `Pub` and v2 items were historically shared by
/// both roles, so they are only removed after strict, account-scoped
/// classification against either the immutable local canonical public key or
/// the authenticated remote canonical public key.
@available(iOS 26.0, macOS 26.0, *)
enum XWingKeyMaterialStore {
    static let algorithm = "X-Wing-ML-KEM-768-X25519"
    static let publicKeyLength = 1_216
    static let privateKeyLength = 64

    private enum LegacyPublicReconciliation {
        case complete
        case requiresRemoteMigration(Data)
    }

    static func normalizedPeerId(_ peerId: String) throws -> String {
        do {
            return try PQCIdentityToken.validated(peerId)
        } catch {
            throw XWingKeyMaterialStoreError.invalidPeerId
        }
    }

    static func descriptor(
        peerId: String,
        authority: PQCKeyPairStoreAuthority,
        scopeSource: SkyBridgeSharedIdentityScopeSource
    ) -> PQCKeyPairStoreDescriptor {
        PQCKeyPairStoreDescriptor(
            backend: .appleCryptoKit,
            purpose: .kem,
            algorithm: algorithm,
            identity: peerId,
            authority: authority,
            authorityDomain: .xWingHPKE,
            storageScope: PQCKeyPairStoreStorageScope(
                canonicalLocation: nil,
                keychainScopeSource: scopeSource,
                includeLegacyKeychain: true
            )
        )
    }

    static func loadLocalRecord(
        peerId: String,
        authority: PQCKeyPairStoreAuthority,
        scopeSource: SkyBridgeSharedIdentityScopeSource
    ) throws -> PQCKeyPairRecord? {
        let identity = try normalizedPeerId(peerId)
        try requireOperationalAuthority(authority, scopeSource: scopeSource)
        let descriptor = descriptor(
            peerId: identity,
            authority: authority,
            scopeSource: scopeSource
        )
        return try PQCKeyPairStore.loadOrMigrateDerivedPrivateLegacy(
            descriptor: descriptor,
            publicKeyLength: publicKeyLength,
            privateKeyLength: privateKeyLength,
            legacySources: PQCKeyPairStoreDerivedPrivateLegacySources(
                privateKeyLocations: [
                    KeychainGenericPasswordLocation(
                        service: PQCKeyTags.xWingLegacyPrivate,
                        account: identity
                    ),
                    KeychainGenericPasswordLocation(
                        service: PQCKeyTags.xWingV2,
                        account: identity
                    )
                ],
                keychainScopeSource: scopeSource,
                includeLegacyKeychain: true
            ),
            classify: { service, representation in
                try classifyLegacyPrivateRepresentation(
                    representation,
                    service: service,
                    descriptor: descriptor
                )
            },
            validatePair: validateLocalRecord
        )
    }

    static func persistLocalPrivateKey(
        _ privateKey: XWingMLKEM768X25519.PrivateKey,
        peerId: String,
        authority: PQCKeyPairStoreAuthority,
        scopeSource: SkyBridgeSharedIdentityScopeSource
    ) throws -> PQCKeyPairRecord {
        let identity = try normalizedPeerId(peerId)
        try requireOperationalAuthority(authority, scopeSource: scopeSource)
        let descriptor = descriptor(
            peerId: identity,
            authority: authority,
            scopeSource: scopeSource
        )
        var candidate = PQCKeyPairRecord(
            algorithmIdentifier: descriptor.algorithmIdentifier,
            publicKey: privateKey.publicKey.rawRepresentation,
            privateKey: privateKey.integrityCheckedRepresentation
        )
        defer { PQCKeyPairRecordCodec.wipe(&candidate.privateKey) }

        if var existing = try loadLocalRecord(
            peerId: identity,
            authority: authority,
            scopeSource: scopeSource
        ) {
            defer { PQCKeyPairRecordCodec.wipe(&existing.privateKey) }
            guard existing == candidate else {
                throw PQCKeyPairStoreError.conflictingLegacyKeyPair(
                    algorithm: descriptor.algorithm
                )
            }
            try reconcileLegacyPublicRoles(
                peerId: identity,
                authority: authority,
                scopeSource: scopeSource
            )
            let result = existing
            existing.privateKey = Data()
            return result
        }

        var winner = try PQCKeyPairStore.insertIfAbsent(
            candidate,
            descriptor: descriptor,
            publicKeyLength: publicKeyLength,
            privateKeyLength: privateKeyLength,
            validatePair: validateLocalRecord
        )
        do {
            guard winner == candidate else {
                throw PQCKeyPairStoreError.conflictingLegacyKeyPair(
                    algorithm: descriptor.algorithm
                )
            }
            // Do not cache or return the new identity until all legacy private
            // candidates have been freshly reconciled after the CAS winner.
            guard var reloaded = try loadLocalRecord(
                peerId: identity,
                authority: authority,
                scopeSource: scopeSource
            ) else {
                throw PQCKeyPairStoreError.canonicalRecordMissingAfterInsert(
                    algorithm: descriptor.algorithm
                )
            }
            defer { PQCKeyPairRecordCodec.wipe(&reloaded.privateKey) }
            guard reloaded == candidate else {
                throw PQCKeyPairStoreError.conflictingLegacyKeyPair(
                    algorithm: descriptor.algorithm
                )
            }
            try reconcileLegacyPublicRoles(
                peerId: identity,
                authority: authority,
                scopeSource: scopeSource
            )
            PQCKeyPairRecordCodec.wipe(&winner.privateKey)
            let result = reloaded
            reloaded.privateKey = Data()
            return result
        } catch {
            PQCKeyPairRecordCodec.wipe(&winner.privateKey)
            throw error
        }
    }

    static func loadLocalPrivateRepresentation(
        peerId: String,
        authority: PQCKeyPairStoreAuthority,
        scopeSource: SkyBridgeSharedIdentityScopeSource
    ) throws -> Data? {
        let identity = try normalizedPeerId(peerId)
        try requireOperationalAuthority(authority, scopeSource: scopeSource)
        guard var record = try loadLocalRecord(
            peerId: identity,
            authority: authority,
            scopeSource: scopeSource
        ) else {
            return nil
        }
        try reconcileLegacyPublicRoles(
            peerId: identity,
            authority: authority,
            scopeSource: scopeSource
        )
        let representation = record.privateKey
        record.privateKey = Data()
        return representation
    }

    static func persistAuthenticatedRemotePublicKey(
        _ publicKey: XWingMLKEM768X25519.PublicKey,
        peerId: String,
        authority: PQCKeyPairStoreAuthority,
        scopeSource: SkyBridgeSharedIdentityScopeSource
    ) throws {
        let identity = try normalizedPeerId(peerId)
        try requireOperationalAuthority(authority, scopeSource: scopeSource)
        let candidate = publicKey.rawRepresentation
        let scope = try scopeSource.resolve()
        let existing = try loadOrMigrateRemoteNamespace(
            peerId: identity,
            scope: scope
        )
        if let existing {
            guard existing == candidate else {
                throw XWingKeyMaterialStoreError
                    .conflictingAuthenticatedRemotePublicKey
            }
        }

        var localRecord = try loadLocalRecord(
            peerId: identity,
            authority: authority,
            scopeSource: scopeSource
        )
        defer {
            if localRecord != nil {
                var ownedRecord = localRecord!
                localRecord = nil
                PQCKeyPairRecordCodec.wipe(&ownedRecord.privateKey)
            }
        }
        guard case .complete = try reconcileLegacyPublicCandidates(
            peerId: identity,
            localPublicKey: localRecord?.publicKey,
            canonicalRemotePublicKey: existing ?? candidate,
            deleteValidatedCandidates: false
        ) else {
            // Supplying an authenticated canonical remote key makes migration
            // unnecessary. Treat any future/new reconciliation state as a
            // conflict instead of proceeding to the compare-and-set write.
            throw XWingKeyMaterialStoreError
                .conflictingAuthenticatedRemotePublicKey
        }

        if existing == nil {
            _ = try KeychainManager.shared.insertKeyIfAbsent(
                data: candidate,
                service: PQCKeyTags.xWingRemotePublic,
                account: identity,
                scope: scope
            )
        }

        guard let winner = try loadAuthoritativeRemotePublicKey(
            peerId: identity,
            scope: scope
        ) else {
            throw XWingKeyMaterialStoreError
                .authenticatedRemotePublicKeyMissingAfterInsert
        }
        guard winner == candidate else {
            throw XWingKeyMaterialStoreError
                .conflictingAuthenticatedRemotePublicKey
        }
        guard let reconciled = try loadAuthenticatedRemotePublicKey(
            peerId: identity,
            authority: authority,
            scopeSource: scopeSource
        ), reconciled == candidate else {
            throw XWingKeyMaterialStoreError
                .conflictingAuthenticatedRemotePublicKey
        }
    }

    static func loadAuthenticatedRemotePublicKey(
        peerId: String,
        authority: PQCKeyPairStoreAuthority,
        scopeSource: SkyBridgeSharedIdentityScopeSource
    ) throws -> Data? {
        let identity = try normalizedPeerId(peerId)
        try requireOperationalAuthority(authority, scopeSource: scopeSource)
        let scope = try scopeSource.resolve()
        var canonicalRemote = try loadOrMigrateRemoteNamespace(
            peerId: identity,
            scope: scope
        )

        var localRecord = try loadLocalRecord(
            peerId: identity,
            authority: authority,
            scopeSource: scopeSource
        )
        defer {
            if localRecord != nil {
                var ownedRecord = localRecord!
                localRecord = nil
                PQCKeyPairRecordCodec.wipe(&ownedRecord.privateKey)
            }
        }
        let localPublicKey = localRecord?.publicKey
        switch try reconcileLegacyPublicCandidates(
            peerId: identity,
            localPublicKey: localPublicKey,
            canonicalRemotePublicKey: canonicalRemote
        ) {
        case .complete:
            return canonicalRemote
        case .requiresRemoteMigration(let legacyRemote):
            guard canonicalRemote == nil else {
                throw XWingKeyMaterialStoreError
                    .conflictingAuthenticatedRemotePublicKey
            }
            _ = try KeychainManager.shared.insertKeyIfAbsent(
                data: legacyRemote,
                service: PQCKeyTags.xWingRemotePublic,
                account: identity,
                scope: scope
            )
            guard let winner = try loadAuthoritativeRemotePublicKey(
                peerId: identity,
                scope: scope
            ) else {
                throw XWingKeyMaterialStoreError
                    .authenticatedRemotePublicKeyMissingAfterInsert
            }
            guard winner == legacyRemote else {
                throw XWingKeyMaterialStoreError
                    .conflictingAuthenticatedRemotePublicKey
            }
            canonicalRemote = winner
            try reconcileRemoteNamespaceCandidates(
                peerId: identity,
                canonicalRemotePublicKey: winner,
                scope: scope
            )
            guard case .complete = try reconcileLegacyPublicCandidates(
                peerId: identity,
                localPublicKey: localPublicKey,
                canonicalRemotePublicKey: winner
            ) else {
                throw XWingKeyMaterialStoreError
                    .conflictingAuthenticatedRemotePublicKey
            }
            return canonicalRemote
        }
    }

    static func validateLocalRecord(_ record: PQCKeyPairRecord) throws {
        guard record.publicKey.count == publicKeyLength,
              record.privateKey.count == privateKeyLength else {
            throw XWingKeyMaterialStoreError.invalidLegacyPrivateKey
        }
        do {
            let privateKey = try XWingMLKEM768X25519.PrivateKey(
                integrityCheckedRepresentation: record.privateKey
            )
            let publicKey = try XWingMLKEM768X25519.PublicKey(
                rawRepresentation: record.publicKey
            )
            guard privateKey.publicKey.rawRepresentation
                    == publicKey.rawRepresentation else {
                throw XWingKeyMaterialStoreError.invalidLegacyPrivateKey
            }
        } catch let error as XWingKeyMaterialStoreError {
            throw error
        } catch {
            throw XWingKeyMaterialStoreError.invalidLegacyPrivateKey
        }
    }

    private static func classifyLegacyPrivateRepresentation(
        _ representation: Data,
        service: String,
        descriptor: PQCKeyPairStoreDescriptor
    ) throws -> PQCKeyPairStoreDerivedPrivateLegacyCandidate {
        if service == PQCKeyTags.xWingV2,
           representation.count == publicKeyLength {
            do {
                _ = try XWingMLKEM768X25519.PublicKey(
                    rawRepresentation: representation
                )
            } catch {
                throw XWingKeyMaterialStoreError.invalidLegacyPublicKey
            }
            return .differentRole
        }
        guard service == PQCKeyTags.xWingLegacyPrivate
                || service == PQCKeyTags.xWingV2,
              representation.count == privateKeyLength else {
            throw XWingKeyMaterialStoreError.invalidLegacyPrivateKey
        }
        do {
            let privateKey = try XWingMLKEM768X25519.PrivateKey(
                integrityCheckedRepresentation: representation
            )
            return .keyPair(
                PQCKeyPairRecord(
                    algorithmIdentifier: descriptor.algorithmIdentifier,
                    publicKey: privateKey.publicKey.rawRepresentation,
                    privateKey: privateKey.integrityCheckedRepresentation
                )
            )
        } catch {
            throw XWingKeyMaterialStoreError.invalidLegacyPrivateKey
        }
    }

    private static func loadOrMigrateRemoteNamespace(
        peerId: String,
        scope: KeychainGenericPasswordScope
    ) throws -> Data? {
        if let canonical = try loadAuthoritativeRemotePublicKey(
            peerId: peerId,
            scope: scope
        ) {
            try reconcileRemoteNamespaceCandidates(
                peerId: peerId,
                canonicalRemotePublicKey: canonical,
                scope: scope
            )
            return canonical
        }

        let authoritativeScope = try scope.authoritativeOnly()
        var candidates = try KeychainManager.shared
            .legacyGenericPasswordCandidatesStrict(
                service: PQCKeyTags.xWingRemotePublic,
                account: peerId,
                includeLegacyKeychain: true
            )
        defer { wipeLegacyCandidates(&candidates) }
        let legacyIndices = candidates.indices.filter { index in
            !isAuthoritative(
                candidates[index].location,
                authoritativeScope: authoritativeScope
            )
        }
        guard let firstIndex = legacyIndices.first else {
            guard !candidates.isEmpty else { return nil }
            guard let concurrentWinner = try loadAuthoritativeRemotePublicKey(
                peerId: peerId,
                scope: scope
            ) else {
                throw XWingKeyMaterialStoreError
                    .authenticatedRemotePublicKeyMissingAfterInsert
            }
            try reconcileRemoteNamespaceCandidates(
                peerId: peerId,
                canonicalRemotePublicKey: concurrentWinner,
                scope: scope
            )
            return concurrentWinner
        }
        let candidate = try validatedPublicKey(candidates[firstIndex].data)
        for index in legacyIndices.dropFirst() {
            guard try validatedPublicKey(candidates[index].data) == candidate else {
                throw XWingKeyMaterialStoreError
                    .conflictingAuthenticatedRemotePublicKey
            }
        }

        _ = try KeychainManager.shared.insertKeyIfAbsent(
            data: candidate,
            service: PQCKeyTags.xWingRemotePublic,
            account: peerId,
            scope: scope
        )
        guard let winner = try loadAuthoritativeRemotePublicKey(
            peerId: peerId,
            scope: scope
        ) else {
            throw XWingKeyMaterialStoreError
                .authenticatedRemotePublicKeyMissingAfterInsert
        }
        guard winner == candidate else {
            throw XWingKeyMaterialStoreError
                .conflictingAuthenticatedRemotePublicKey
        }
        try reconcileRemoteNamespaceCandidates(
            peerId: peerId,
            canonicalRemotePublicKey: winner,
            scope: scope
        )
        return winner
    }

    private static func loadAuthoritativeRemotePublicKey(
        peerId: String,
        scope: KeychainGenericPasswordScope
    ) throws -> Data? {
        let authoritativeScope = try scope.authoritativeOnly()
        guard let data = try KeychainManager.shared.exportKeyStrict(
            service: PQCKeyTags.xWingRemotePublic,
            account: peerId,
            scope: authoritativeScope,
            includeLegacyKeychain: false
        ) else {
            return nil
        }
        return try validatedPublicKey(data)
    }

    private static func reconcileRemoteNamespaceCandidates(
        peerId: String,
        canonicalRemotePublicKey: Data,
        scope: KeychainGenericPasswordScope
    ) throws {
        let authoritativeScope = try scope.authoritativeOnly()
        var candidates = try KeychainManager.shared
            .legacyGenericPasswordCandidatesStrict(
                service: PQCKeyTags.xWingRemotePublic,
                account: peerId,
                includeLegacyKeychain: true
            )
        defer { wipeLegacyCandidates(&candidates) }
        let legacyIndices = candidates.indices.filter { index in
            !isAuthoritative(
                candidates[index].location,
                authoritativeScope: authoritativeScope
            )
        }
        for index in legacyIndices {
            guard try validatedPublicKey(candidates[index].data)
                    == canonicalRemotePublicKey else {
                throw XWingKeyMaterialStoreError
                    .conflictingAuthenticatedRemotePublicKey
            }
        }
        for index in legacyIndices {
            try KeychainManager.shared.deleteLegacyGenericPasswordCandidate(
                candidates[index]
            )
        }
    }

    private static func reconcileLegacyPublicRoles(
        peerId: String,
        authority: PQCKeyPairStoreAuthority,
        scopeSource: SkyBridgeSharedIdentityScopeSource
    ) throws {
        _ = try loadAuthenticatedRemotePublicKey(
            peerId: peerId,
            authority: authority,
            scopeSource: scopeSource
        )
    }

    private static func reconcileLegacyPublicCandidates(
        peerId: String,
        localPublicKey: Data?,
        canonicalRemotePublicKey: Data?,
        deleteValidatedCandidates: Bool = true
    ) throws -> LegacyPublicReconciliation {
        var candidates: [LegacyGenericPasswordCandidate] = []
        do {
            candidates.append(
                contentsOf: try KeychainManager.shared
                    .legacyGenericPasswordCandidatesStrict(
                        service: PQCKeyTags.xWingLegacyPublic,
                        account: peerId,
                        includeLegacyKeychain: true
                    )
            )
            candidates.append(
                contentsOf: try KeychainManager.shared
                    .legacyGenericPasswordCandidatesStrict(
                        service: PQCKeyTags.xWingV2,
                        account: peerId,
                        includeLegacyKeychain: true
                    )
            )
        } catch {
            wipeLegacyCandidates(&candidates)
            throw error
        }
        defer { wipeLegacyCandidates(&candidates) }

        var publicCandidateIndices: [Int] = []
        var selectedRemotePublicKey: Data?
        for index in candidates.indices {
            let candidate = candidates[index]
            if candidate.service == PQCKeyTags.xWingV2,
               candidate.data.count == privateKeyLength {
                do {
                    _ = try XWingMLKEM768X25519.PrivateKey(
                        integrityCheckedRepresentation: candidate.data
                    )
                } catch {
                    throw XWingKeyMaterialStoreError.invalidLegacyPrivateKey
                }
                // The local private reconciliation owns this candidate. It is
                // never deleted from a remote-public migration snapshot.
                continue
            }
            let publicKey = try validatedPublicKey(candidate.data)
            publicCandidateIndices.append(index)
            if let localPublicKey, publicKey == localPublicKey {
                continue
            }
            if localPublicKey == nil {
                guard let canonicalRemotePublicKey else {
                    throw XWingKeyMaterialStoreError
                        .ambiguousLegacyPublicKeyRole
                }
                guard publicKey == canonicalRemotePublicKey else {
                    throw XWingKeyMaterialStoreError
                        .conflictingAuthenticatedRemotePublicKey
                }
            }
            if let selectedRemotePublicKey {
                guard selectedRemotePublicKey == publicKey else {
                    throw XWingKeyMaterialStoreError
                        .conflictingAuthenticatedRemotePublicKey
                }
            } else {
                selectedRemotePublicKey = publicKey
            }
        }

        if let selectedRemotePublicKey {
            guard let canonicalRemotePublicKey else {
                return .requiresRemoteMigration(selectedRemotePublicKey)
            }
            guard canonicalRemotePublicKey == selectedRemotePublicKey else {
                throw XWingKeyMaterialStoreError
                    .conflictingAuthenticatedRemotePublicKey
            }
        }

        // Every public-form candidate has been classified and every remote
        // candidate matches the immutable canonical winner. Exact persistent
        // references are now safe to delete; private-form v2 items remain.
        if deleteValidatedCandidates {
            for index in publicCandidateIndices {
                try KeychainManager.shared.deleteLegacyGenericPasswordCandidate(
                    candidates[index]
                )
            }
        }
        return .complete
    }

    private static func validatedPublicKey(_ representation: Data) throws -> Data {
        guard representation.count == publicKeyLength else {
            throw XWingKeyMaterialStoreError.invalidLegacyPublicKey
        }
        do {
            _ = try XWingMLKEM768X25519.PublicKey(
                rawRepresentation: representation
            )
        } catch {
            throw XWingKeyMaterialStoreError.invalidLegacyPublicKey
        }
        return representation
    }

    private static func isAuthoritative(
        _ location: LegacySecItemLocation,
        authoritativeScope: KeychainGenericPasswordScope
    ) -> Bool {
        guard let accessGroup = authoritativeScope.writeAccessGroup else {
            return false
        }
        return location.actualAccessGroup == accessGroup
            && location.usesDataProtectionKeychain
                == authoritativeScope.usesDataProtectionKeychain
    }

    private static func wipeLegacyCandidates(
        _ candidates: inout [LegacyGenericPasswordCandidate]
    ) {
        for index in candidates.indices {
            PQCKeyPairRecordCodec.wipe(&candidates[index].data)
        }
    }

    private static func requireOperationalAuthority(
        _ authority: PQCKeyPairStoreAuthority,
        scopeSource: SkyBridgeSharedIdentityScopeSource
    ) throws {
        guard authority == .active else {
            throw XWingKeyMaterialStoreError.stagedMaterialIsNotOperational
        }
        _ = try PQCBackendAuthorityStore.claim(
            .appleCryptoKit,
            domain: .xWingHPKE,
            scopeSource: scopeSource
        )
    }
}

@available(iOS 26.0, macOS 26.0, *)
actor ApplePQCProvider: PQCProvider, PQCProviderCapabilityReporting, AuthenticatedPQCSigningKeyConsumer, PQCLocalSigningPublicKeyProviding {
    private enum KeyContract {
        // Measured from the macOS 26.5 CryptoKit SDK. These are persistence
        // contracts, not values inferred from signature or ciphertext sizes.
        static let mldsa65 = (publicKey: 1_952, privateKey: 64)
        static let mldsa87 = (publicKey: 2_592, privateKey: 64)
        static let mlkem768 = (publicKey: 1_184, privateKey: 96)
        static let mlkem1024 = (publicKey: 1_568, privateKey: 96)
    }

    nonisolated let suite: PQCAlgorithmSuite
    nonisolated var backend: PQCBackend { .applePQC }
    nonisolated let supportedKEMVariants: Set<String> = ["ML-KEM-768", "ML-KEM-1024"]
    nonisolated let supportedSignatureAlgorithms: Set<String> = ["ML-DSA-65", "ML-DSA-87"]
    private let logger = Logger(subsystem: "com.skybridge.quantum", category: "ApplePQCProvider")
    private var mldsa65Memory: [String: MLDSA65.PrivateKey] = [:]
    private var mldsa87Memory: [String: MLDSA87.PrivateKey] = [:]
    // Authenticated REMOTE peer signing public keys — the only keys that can
    // truly authenticate a remote ML-DSA signature. Kept in a namespace distinct
    // from the locally-generated keypairs above so verify() never confuses
    // "my own key" with "the peer's pinned key".
    private var mldsa65RemotePublicKeys: [String: MLDSA65.PublicKey] = [:]
    private var mldsa87RemotePublicKeys: [String: MLDSA87.PublicKey] = [:]
    private var mlkem768Keys: [String: MLKEM768.PrivateKey] = [:]
    private var mlkem1024Keys: [String: MLKEM1024.PrivateKey] = [:]
    private let keyPairAuthority: PQCKeyPairStoreAuthority
    private let scopeSource: SkyBridgeSharedIdentityScopeSource

    init(
        suite: PQCAlgorithmSuite = .pqcMlKemMlDsa,
        keyPairAuthority: PQCKeyPairStoreAuthority = .active,
        scopeSource: SkyBridgeSharedIdentityScopeSource = .requiredEntitlement
    ) {
        self.suite = suite
        self.keyPairAuthority = keyPairAuthority
        self.scopeSource = scopeSource
    }

    func sign(data: Data, peerId: String, algorithm: String) async throws -> Data {
        switch algorithm {
        case "ML-DSA", "ML-DSA-65":
            let priv = try getOrCreateMLDSA65(peerId)
            return try priv.signature(for: data)
        case "ML-DSA-87":
            let priv = try getOrCreateMLDSA87(peerId)
            return try priv.signature(for: data)
        default:
            throw NSError(domain: "PQC", code: -115, userInfo: [NSLocalizedDescriptionKey: "不支持的ML‑DSA算法: \(algorithm)"])
        }
    }
    func verify(data: Data, signature: Data, peerId: String, algorithm: String) async -> Bool {
        switch algorithm {
        case "ML-DSA", "ML-DSA-65":
            if let remote = loadAuthenticatedMLDSA65PublicKey(peerId) {
                return remote.isValidSignature(signature, for: data)
            }
            return false
        case "ML-DSA-87":
            if let remote = loadAuthenticatedMLDSA87PublicKey(peerId) {
                return remote.isValidSignature(signature, for: data)
            }
            return false
        default:
            return false
        }
    }
    func kemEncapsulate(peerId: String, kemVariant: String) async throws -> (sharedSecret: Data, encapsulated: Data) {
        let normalizedPeerId = try validatedPQCPeerId(peerId)
        switch kemVariant {
        case "ML-KEM-768":
            let pub = try getOrCreateMLKEM768Key(normalizedPeerId).publicKey
            let enc = try pub.encapsulate()
            let ss = enc.sharedSecret.withUnsafeBytes { Data($0) }
            return (ss, enc.encapsulated)
        case "ML-KEM-1024":
            let pub = try getOrCreateMLKEM1024Key(normalizedPeerId).publicKey
            let enc = try pub.encapsulate()
            let ss = enc.sharedSecret.withUnsafeBytes { Data($0) }
            return (ss, enc.encapsulated)
        default:
            throw NSError(domain: "PQC", code: -120, userInfo: [NSLocalizedDescriptionKey: "不支持的KEM变体: \(kemVariant)"])
        }
    }
    func kemDecapsulate(peerId: String, encapsulated: Data, kemVariant: String) async throws -> Data {
        switch kemVariant {
        case "ML-KEM-768":
            let priv = try getOrCreateMLKEM768Key(peerId)
            let ss = try priv.decapsulate(encapsulated)
            return ss.withUnsafeBytes { Data($0) }
        case "ML-KEM-1024":
            let priv = try getOrCreateMLKEM1024Key(peerId)
            let ss = try priv.decapsulate(encapsulated)
            return ss.withUnsafeBytes { Data($0) }
        default:
            throw NSError(domain: "PQC", code: -121, userInfo: [NSLocalizedDescriptionKey: "不支持的KEM变体: \(kemVariant)"])
        }
    }
    func hpkeSeal(recipientPeerId: String, plaintext: Data, associatedData: Data?) async throws -> (ciphertext: Data, encapsulatedKey: Data) {
 // 使用 HPKE X‑Wing（X25519 + ML‑KEM‑768），将会话策略/上下文作为 AAD 绑定
        let info = associatedData ?? Data("SkyBridgeHPKE".utf8)
        let recipientKey = try loadExistingXWingPublicKey(recipientPeerId)
        var sender = try HPKE.Sender(recipientKey: recipientKey, ciphersuite: .XWingMLKEM768X25519_SHA256_AES_GCM_256, info: info)
        let ct = try sender.seal(plaintext, authenticating: info)
        return (ct, sender.encapsulatedKey)
    }
    func hpkeOpen(recipientPeerId: String, ciphertext: Data, encapsulatedKey: Data, associatedData: Data?) async throws -> Data {
 // HPKE 解密与加密保持一致的 AAD 绑定（同一 info），确保上下文完整性
        let info = associatedData ?? Data("SkyBridgeHPKE".utf8)
        let priv = try loadExistingXWingPrivateKey(recipientPeerId)
        var recipient = try HPKE.Recipient(privateKey: priv, ciphersuite: .XWingMLKEM768X25519_SHA256_AES_GCM_256, info: info, encapsulatedKey: encapsulatedKey)
        return try recipient.open(ciphertext, authenticating: info)
    }

    func setAuthenticatedXWingRecipientPublicKey(_ publicKey: XWingMLKEM768X25519.PublicKey, for peerId: String) throws {
        do {
            try XWingKeyMaterialStore.persistAuthenticatedRemotePublicKey(
                publicKey,
                peerId: peerId,
                authority: keyPairAuthority,
                scopeSource: scopeSource
            )
        } catch XWingKeyMaterialStoreError.invalidPeerId {
            throw xWingPeerIdError()
        } catch {
            throw localKeyPairError(
                code: -920,
                description: "无法保存已认证的X-Wing对端公钥",
                underlying: error
            )
        }
    }

    func setLocalXWingRecipientPrivateKey(_ privateKey: XWingMLKEM768X25519.PrivateKey, for peerId: String) throws {
        do {
            var persisted = try XWingKeyMaterialStore.persistLocalPrivateKey(
                privateKey,
                peerId: peerId,
                authority: keyPairAuthority,
                scopeSource: scopeSource
            )
            PQCKeyPairRecordCodec.wipe(&persisted.privateKey)
        } catch XWingKeyMaterialStoreError.invalidPeerId {
            throw xWingPeerIdError()
        } catch {
            throw localKeyPairError(
                code: -921,
                description: "无法保存本地X-Wing密钥对",
                underlying: error
            )
        }
    }

 // MARK: - Authenticated remote ML-DSA verification keys
 // 注册「已认证」的远端 ML-DSA 公钥（与 X-Wing 的已认证接收公钥同构）。注册后，
 // verify(...) 会优先用它来真正认证远端签名，而不是回退到本地密钥。

    func setAuthenticatedMLDSA65PublicKey(_ publicKey: MLDSA65.PublicKey, for peerId: String) throws {
        let identity = try validatedPQCPeerId(peerId)
        if let existing = mldsa65RemotePublicKeys[identity] {
            guard existing.rawRepresentation == publicKey.rawRepresentation else {
                throw PQCSigningTrustError.authenticatedKeyConflict(
                    peerId: identity,
                    algorithm: "ML-DSA-65"
                )
            }
            return
        }
        mldsa65RemotePublicKeys[identity] = publicKey
    }

    func setAuthenticatedMLDSA87PublicKey(_ publicKey: MLDSA87.PublicKey, for peerId: String) throws {
        let identity = try validatedPQCPeerId(peerId)
        if let existing = mldsa87RemotePublicKeys[identity] {
            guard existing.rawRepresentation == publicKey.rawRepresentation else {
                throw PQCSigningTrustError.authenticatedKeyConflict(
                    peerId: identity,
                    algorithm: "ML-DSA-87"
                )
            }
            return
        }
        mldsa87RemotePublicKeys[identity] = publicKey
    }

    private func loadAuthenticatedMLDSA65PublicKey(_ peerId: String) -> MLDSA65.PublicKey? {
        mldsa65RemotePublicKeys[peerId]
    }

    private func loadAuthenticatedMLDSA87PublicKey(_ peerId: String) -> MLDSA87.PublicKey? {
        mldsa87RemotePublicKeys[peerId]
    }

    func registerAuthenticatedSigningPublicKey(
        _ publicKey: Data,
        peerId: String,
        algorithm: String
    ) throws {
        switch algorithm {
        case "ML-DSA", "ML-DSA-65":
            guard publicKey.count == 1_952 else {
                throw PQCSigningTrustError.invalidPublicKeyLength(
                    algorithm: "ML-DSA-65",
                    expected: 1_952,
                    actual: publicKey.count
                )
            }
            try setAuthenticatedMLDSA65PublicKey(
                MLDSA65.PublicKey(rawRepresentation: publicKey),
                for: peerId
            )
        case "ML-DSA-87":
            guard publicKey.count == 2_592 else {
                throw PQCSigningTrustError.invalidPublicKeyLength(
                    algorithm: "ML-DSA-87",
                    expected: 2_592,
                    actual: publicKey.count
                )
            }
            try setAuthenticatedMLDSA87PublicKey(
                MLDSA87.PublicKey(rawRepresentation: publicKey),
                for: peerId
            )
        default:
            throw PQCSigningTrustError.unsupportedSignatureAlgorithm(algorithm)
        }
    }

    func localSigningPublicKey(peerId: String, algorithm: String) throws -> Data {
        let normalizedPeerId = try validatedPQCPeerId(peerId)
        switch algorithm.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "ML-DSA", "ML-DSA-65", "MLDSA", "MLDSA-65":
            guard let key = mldsa65Memory[normalizedPeerId] else {
                throw PQCSigningTrustError.localSigningPublicKeyUnavailable(
                    peerId: normalizedPeerId,
                    algorithm: "ML-DSA-65"
                )
            }
            return key.publicKey.rawRepresentation
        case "ML-DSA-87", "MLDSA-87":
            guard let key = mldsa87Memory[normalizedPeerId] else {
                throw PQCSigningTrustError.localSigningPublicKeyUnavailable(
                    peerId: normalizedPeerId,
                    algorithm: "ML-DSA-87"
                )
            }
            return key.publicKey.rawRepresentation
        default:
            throw PQCSigningTrustError.unsupportedSignatureAlgorithm(algorithm)
        }
    }

    // MARK: - Key Loading / Storage
    // Local identities use one immutable, versioned Keychain item. The store's
    // create-only insert is the cross-process CAS boundary; every contender
    // reloads the winner before a CryptoKit operation begins.

    private func getOrCreateMLDSA65(_ peerId: String) throws -> MLDSA65.PrivateKey {
        let identity = try validatedPQCPeerId(peerId)
        if let key = mldsa65Memory[identity] { return key }
        let descriptor = keyPairDescriptor(
            purpose: .signature,
            algorithm: "ML-DSA-65",
            identity: identity
        )
        var record: PQCKeyPairRecord
        do {
            record = try PQCKeyPairStore.loadOrCreate(
                descriptor: descriptor,
                publicKeyLength: KeyContract.mldsa65.publicKey,
                privateKeyLength: KeyContract.mldsa65.privateKey,
                legacyPublicService: PQCKeyTags.service("MLDSA", "65", "Pub"),
                legacyPrivateService: PQCKeyTags.service("MLDSA", "65", "Mem"),
                validatePair: { try self.validateMLDSA65Record($0, peerId: identity) },
                generate: {
                    let key = try MLDSA65.PrivateKey()
                    return PQCKeyPairRecord(
                        algorithmIdentifier: descriptor.algorithmIdentifier,
                        publicKey: key.publicKey.rawRepresentation,
                        privateKey: key.integrityCheckedRepresentation
                    )
                }
            )
        } catch let error as PQCSigningTrustError {
            throw error
        } catch PQCKeyPairStoreError.incompleteLegacyKeyPair {
            throw PQCSigningTrustError.corruptLocalKeyPair(
                peerId: identity,
                algorithm: "ML-DSA-65"
            )
        } catch PQCKeyPairStoreError.conflictingLegacyKeyPair {
            throw PQCSigningTrustError.corruptLocalKeyPair(
                peerId: identity,
                algorithm: "ML-DSA-65"
            )
        } catch is PQCKeyPairRecordCodecError {
            throw PQCSigningTrustError.corruptLocalKeyPair(
                peerId: identity,
                algorithm: "ML-DSA-65"
            )
        }
        defer { PQCKeyPairRecordCodec.wipe(&record.privateKey) }
        do {
            let key = try MLDSA65.PrivateKey(integrityCheckedRepresentation: record.privateKey)
            mldsa65Memory[identity] = key
            return key
        } catch {
            throw PQCSigningTrustError.corruptLocalKeyPair(
                peerId: identity,
                algorithm: "ML-DSA-65"
            )
        }
    }

    private func getOrCreateMLDSA87(_ peerId: String) throws -> MLDSA87.PrivateKey {
        let identity = try validatedPQCPeerId(peerId)
        if let key = mldsa87Memory[identity] { return key }
        let descriptor = keyPairDescriptor(
            purpose: .signature,
            algorithm: "ML-DSA-87",
            identity: identity
        )
        var record: PQCKeyPairRecord
        do {
            record = try PQCKeyPairStore.loadOrCreate(
                descriptor: descriptor,
                publicKeyLength: KeyContract.mldsa87.publicKey,
                privateKeyLength: KeyContract.mldsa87.privateKey,
                legacyPublicService: PQCKeyTags.service("MLDSA", "87", "Pub"),
                legacyPrivateService: PQCKeyTags.service("MLDSA", "87", "Mem"),
                validatePair: { try self.validateMLDSA87Record($0, peerId: identity) },
                generate: {
                    let key = try MLDSA87.PrivateKey()
                    return PQCKeyPairRecord(
                        algorithmIdentifier: descriptor.algorithmIdentifier,
                        publicKey: key.publicKey.rawRepresentation,
                        privateKey: key.integrityCheckedRepresentation
                    )
                }
            )
        } catch let error as PQCSigningTrustError {
            throw error
        } catch PQCKeyPairStoreError.incompleteLegacyKeyPair {
            throw PQCSigningTrustError.corruptLocalKeyPair(
                peerId: identity,
                algorithm: "ML-DSA-87"
            )
        } catch PQCKeyPairStoreError.conflictingLegacyKeyPair {
            throw PQCSigningTrustError.corruptLocalKeyPair(
                peerId: identity,
                algorithm: "ML-DSA-87"
            )
        } catch is PQCKeyPairRecordCodecError {
            throw PQCSigningTrustError.corruptLocalKeyPair(
                peerId: identity,
                algorithm: "ML-DSA-87"
            )
        }
        defer { PQCKeyPairRecordCodec.wipe(&record.privateKey) }
        do {
            let key = try MLDSA87.PrivateKey(integrityCheckedRepresentation: record.privateKey)
            mldsa87Memory[identity] = key
            return key
        } catch {
            throw PQCSigningTrustError.corruptLocalKeyPair(
                peerId: identity,
                algorithm: "ML-DSA-87"
            )
        }
    }

    private func getOrCreateMLKEM768Key(_ peerId: String) throws -> MLKEM768.PrivateKey {
        let identity: String
        do {
            identity = try PQCIdentityToken.validated(peerId)
        } catch {
            throw localKeyPairError(code: -934, description: "ML-KEM-768本地密钥对身份无效", underlying: nil)
        }
        if let key = mlkem768Keys[identity] { return key }
        let descriptor = keyPairDescriptor(
            purpose: .kem,
            algorithm: "ML-KEM-768",
            identity: identity
        )
        do {
            var record = try PQCKeyPairStore.loadOrCreate(
                descriptor: descriptor,
                publicKeyLength: KeyContract.mlkem768.publicKey,
                privateKeyLength: KeyContract.mlkem768.privateKey,
                legacyPublicService: PQCKeyTags.service("MLKEM", "768", "Pub"),
                legacyPrivateService: PQCKeyTags.service("MLKEM", "768", "Mem"),
                validatePair: validateMLKEM768Record,
                generate: {
                    let key = try MLKEM768.PrivateKey()
                    return PQCKeyPairRecord(
                        algorithmIdentifier: descriptor.algorithmIdentifier,
                        publicKey: key.publicKey.rawRepresentation,
                        privateKey: key.integrityCheckedRepresentation
                    )
                }
            )
            defer { PQCKeyPairRecordCodec.wipe(&record.privateKey) }
            let key = try MLKEM768.PrivateKey(integrityCheckedRepresentation: record.privateKey)
            mlkem768Keys[identity] = key
            return key
        } catch let error as NSError where error.domain == "PQC" && error.code == -934 {
            throw error
        } catch {
            throw localKeyPairError(
                code: -934,
                description: "无法加载或创建ML-KEM-768本地密钥对",
                underlying: error
            )
        }
    }

    private func getOrCreateMLKEM1024Key(_ peerId: String) throws -> MLKEM1024.PrivateKey {
        let identity: String
        do {
            identity = try PQCIdentityToken.validated(peerId)
        } catch {
            throw localKeyPairError(code: -936, description: "ML-KEM-1024本地密钥对身份无效", underlying: nil)
        }
        if let key = mlkem1024Keys[identity] { return key }
        let descriptor = keyPairDescriptor(
            purpose: .kem,
            algorithm: "ML-KEM-1024",
            identity: identity
        )
        do {
            var record = try PQCKeyPairStore.loadOrCreate(
                descriptor: descriptor,
                publicKeyLength: KeyContract.mlkem1024.publicKey,
                privateKeyLength: KeyContract.mlkem1024.privateKey,
                legacyPublicService: PQCKeyTags.service("MLKEM", "1024", "Pub"),
                legacyPrivateService: PQCKeyTags.service("MLKEM", "1024", "Mem"),
                validatePair: validateMLKEM1024Record,
                generate: {
                    let key = try MLKEM1024.PrivateKey()
                    return PQCKeyPairRecord(
                        algorithmIdentifier: descriptor.algorithmIdentifier,
                        publicKey: key.publicKey.rawRepresentation,
                        privateKey: key.integrityCheckedRepresentation
                    )
                }
            )
            defer { PQCKeyPairRecordCodec.wipe(&record.privateKey) }
            let key = try MLKEM1024.PrivateKey(integrityCheckedRepresentation: record.privateKey)
            mlkem1024Keys[identity] = key
            return key
        } catch let error as NSError where error.domain == "PQC" && error.code == -936 {
            throw error
        } catch {
            throw localKeyPairError(
                code: -936,
                description: "无法加载或创建ML-KEM-1024本地密钥对",
                underlying: error
            )
        }
    }

    private func keyPairDescriptor(
        purpose: PQCKeyPairStorePurpose,
        algorithm: String,
        identity: String
    ) -> PQCKeyPairStoreDescriptor {
        PQCKeyPairStoreDescriptor(
            backend: .appleCryptoKit,
            purpose: purpose,
            algorithm: algorithm,
            identity: identity,
            authority: keyPairAuthority,
            storageScope: keyPairStorageScope
        )
    }

    private var keyPairStorageScope: PQCKeyPairStoreStorageScope {
        PQCKeyPairStoreStorageScope(
            canonicalLocation: nil,
            keychainScopeSource: scopeSource,
            includeLegacyKeychain: true
        )
    }

    private func validatedPQCPeerId(_ peerId: String) throws -> String {
        do {
            return try PQCIdentityToken.validated(peerId)
        } catch {
            throw PQCSigningTrustError.invalidPeerId
        }
    }

    private func validateMLDSA65Record(_ record: PQCKeyPairRecord, peerId: String) throws {
        do {
            let privateKey = try MLDSA65.PrivateKey(
                integrityCheckedRepresentation: record.privateKey
            )
            let publicKey = try MLDSA65.PublicKey(rawRepresentation: record.publicKey)
            guard privateKey.publicKey.rawRepresentation == publicKey.rawRepresentation else {
                throw PQCSigningTrustError.corruptLocalKeyPair(
                    peerId: peerId,
                    algorithm: "ML-DSA-65"
                )
            }
        } catch let error as PQCSigningTrustError {
            throw error
        } catch {
            throw PQCSigningTrustError.corruptLocalKeyPair(
                peerId: peerId,
                algorithm: "ML-DSA-65"
            )
        }
    }

    private func validateMLDSA87Record(_ record: PQCKeyPairRecord, peerId: String) throws {
        do {
            let privateKey = try MLDSA87.PrivateKey(
                integrityCheckedRepresentation: record.privateKey
            )
            let publicKey = try MLDSA87.PublicKey(rawRepresentation: record.publicKey)
            guard privateKey.publicKey.rawRepresentation == publicKey.rawRepresentation else {
                throw PQCSigningTrustError.corruptLocalKeyPair(
                    peerId: peerId,
                    algorithm: "ML-DSA-87"
                )
            }
        } catch let error as PQCSigningTrustError {
            throw error
        } catch {
            throw PQCSigningTrustError.corruptLocalKeyPair(
                peerId: peerId,
                algorithm: "ML-DSA-87"
            )
        }
    }

    private func validateMLKEM768Record(_ record: PQCKeyPairRecord) throws {
        do {
            let privateKey = try MLKEM768.PrivateKey(
                integrityCheckedRepresentation: record.privateKey
            )
            let publicKey = try MLKEM768.PublicKey(rawRepresentation: record.publicKey)
            guard privateKey.publicKey.rawRepresentation == publicKey.rawRepresentation else {
                throw localKeyPairError(
                    code: -934,
                    description: "ML-KEM-768本地密钥对不匹配",
                    underlying: nil
                )
            }
        } catch let error as NSError where error.domain == "PQC" && error.code == -934 {
            throw error
        } catch {
            throw localKeyPairError(
                code: -934,
                description: "ML-KEM-768本地密钥对损坏",
                underlying: error
            )
        }
    }

    private func validateMLKEM1024Record(_ record: PQCKeyPairRecord) throws {
        do {
            let privateKey = try MLKEM1024.PrivateKey(
                integrityCheckedRepresentation: record.privateKey
            )
            let publicKey = try MLKEM1024.PublicKey(rawRepresentation: record.publicKey)
            guard privateKey.publicKey.rawRepresentation == publicKey.rawRepresentation else {
                throw localKeyPairError(
                    code: -936,
                    description: "ML-KEM-1024本地密钥对不匹配",
                    underlying: nil
                )
            }
        } catch let error as NSError where error.domain == "PQC" && error.code == -936 {
            throw error
        } catch {
            throw localKeyPairError(
                code: -936,
                description: "ML-KEM-1024本地密钥对损坏",
                underlying: error
            )
        }
    }

    private func localKeyPairError(
        code: Int,
        description: String,
        underlying: Error?
    ) -> NSError {
        var userInfo: [String: Any] = [NSLocalizedDescriptionKey: description]
        if let underlying {
            userInfo[NSUnderlyingErrorKey] = underlying as NSError
        }
        return NSError(domain: "PQC", code: code, userInfo: userInfo)
    }

    private func xWingPeerIdError() -> NSError {
        NSError(
            domain: "PQC",
            code: -922,
            userInfo: [NSLocalizedDescriptionKey: "X-Wing peerId不能为空"]
        )
    }

    private func loadExistingXWingPublicKey(_ peerId: String) throws -> XWingMLKEM768X25519.PublicKey {
        do {
            guard let data = try XWingKeyMaterialStore
                .loadAuthenticatedRemotePublicKey(
                    peerId: peerId,
                    authority: keyPairAuthority,
                    scopeSource: scopeSource
                ) else {
                throw localKeyPairError(
                    code: -918,
                    description: "缺少已认证的X-Wing对端公钥",
                    underlying: nil
                )
            }
            return try XWingMLKEM768X25519.PublicKey(
                rawRepresentation: data
            )
        } catch let error as NSError where error.domain == "PQC"
                && error.code == -918 {
            throw error
        } catch XWingKeyMaterialStoreError.invalidPeerId {
            throw xWingPeerIdError()
        } catch {
            throw localKeyPairError(
                code: -918,
                description: "无法加载已认证的X-Wing对端公钥",
                underlying: error
            )
        }
    }

    private func loadExistingXWingPrivateKey(_ peerId: String) throws -> XWingMLKEM768X25519.PrivateKey {
        do {
            guard var representation = try XWingKeyMaterialStore
                .loadLocalPrivateRepresentation(
                    peerId: peerId,
                    authority: keyPairAuthority,
                    scopeSource: scopeSource
                ) else {
                throw localKeyPairError(
                    code: -919,
                    description: "缺少本地X-Wing私钥",
                    underlying: nil
                )
            }
            defer { PQCKeyPairRecordCodec.wipe(&representation) }
            return try XWingMLKEM768X25519.PrivateKey(
                integrityCheckedRepresentation: representation
            )
        } catch let error as NSError where error.domain == "PQC" && error.code == -919 {
            throw error
        } catch XWingKeyMaterialStoreError.invalidPeerId {
            throw xWingPeerIdError()
        } catch {
            throw localKeyPairError(
                code: -919,
                description: "无法加载本地X-Wing密钥对",
                underlying: error
            )
        }
    }
}

@available(iOS 26.0, macOS 26.0, *)
extension ApplePQCProvider: PQCHPKEProvider {
    nonisolated public func senderContext(recipientPublicKey: Data, suite: PQCAlgorithmSuite) throws -> HPKESenderContext {
        #if canImport(CryptoKit)
        let seal: @Sendable (Data, Data) throws -> (Data, Data)
        switch suite {
        case .hybridXWing:
            let cs = HPKE.Ciphersuite.XWingMLKEM768X25519_SHA256_AES_GCM_256
            guard let pub = try? XWingMLKEM768X25519.PublicKey(rawRepresentation: recipientPublicKey) else {
                throw NSError(domain: "PQC", code: -910, userInfo: [NSLocalizedDescriptionKey: "Invalid XWing public key"])
            }
            seal = { plaintext, aad in
                var sender = try HPKE.Sender(recipientKey: pub, ciphersuite: cs, info: aad)
                let ct = try sender.seal(plaintext, authenticating: aad)
                return (ct, sender.encapsulatedKey)
            }
        case .pqcMlKemMlDsa:
            throw NSError(domain: "PQC", code: -916, userInfo: [NSLocalizedDescriptionKey: "Pure PQC HPKE ciphersuite mapping requires confirmed KEM names; use hybrid X‑Wing as recommended by Apple."])
        case .classicP256:
            throw NSError(domain: "PQC", code: -912, userInfo: [NSLocalizedDescriptionKey: "HPKE not used for classic profile"])
        }
        return HPKESenderContext(suite: suite, sealFn: seal)
        #else
        throw NSError(domain: "PQC", code: -900, userInfo: [NSLocalizedDescriptionKey: "CryptoKit unavailable"])
        #endif
    }
    nonisolated public func recipientContext(recipientPrivateKey: Data, suite: PQCAlgorithmSuite, encapsulatedKey: Data) throws -> HPKERecipientContext {
        #if canImport(CryptoKit)
        let open: @Sendable (Data, Data) throws -> Data
        switch suite {
        case .hybridXWing:
            let cs = HPKE.Ciphersuite.XWingMLKEM768X25519_SHA256_AES_GCM_256
            guard let priv = try? XWingMLKEM768X25519.PrivateKey(integrityCheckedRepresentation: recipientPrivateKey) else {
                throw NSError(domain: "PQC", code: -913, userInfo: [NSLocalizedDescriptionKey: "Invalid XWing private key"])
            }
            open = { ciphertext, aad in
                var recipient = try HPKE.Recipient(privateKey: priv, ciphersuite: cs, info: aad, encapsulatedKey: encapsulatedKey)
                return try recipient.open(ciphertext, authenticating: aad)
            }
        case .pqcMlKemMlDsa:
            throw NSError(domain: "PQC", code: -917, userInfo: [NSLocalizedDescriptionKey: "Pure PQC HPKE recipient context unsupported until KEM names confirmed; use hybrid X‑Wing."])
        case .classicP256:
            throw NSError(domain: "PQC", code: -915, userInfo: [NSLocalizedDescriptionKey: "HPKE not used for classic profile"])
        }
        return HPKERecipientContext(suite: suite, openFn: open)
        #else
        throw NSError(domain: "PQC", code: -900, userInfo: [NSLocalizedDescriptionKey: "CryptoKit unavailable"])
        #endif
    }
}
#endif // HAS_APPLE_PQC_SDK

@available(macOS 14.0, *)
actor OQSProvider: PQCProvider, PQCProviderCapabilityReporting, AuthenticatedPQCSigningKeyConsumer, PQCLocalSigningPublicKeyProviding {
    nonisolated let suite: PQCAlgorithmSuite = .pqcMlKemMlDsa
    nonisolated let backend: PQCBackend = .liboqs
    #if canImport(liboqs)
    nonisolated let supportedKEMVariants: Set<String> = ["ML-KEM-768", "ML-KEM-1024"]
    nonisolated let supportedSignatureAlgorithms: Set<String> = ["ML-DSA-65", "ML-DSA-87"]
    #else
    nonisolated let supportedKEMVariants: Set<String> = ["ML-KEM-768"]
    nonisolated let supportedSignatureAlgorithms: Set<String> = ["ML-DSA-65"]
    #endif

    private struct SigningKeyID: Hashable {
        let peerId: String
        let algorithm: String
    }

    private let logger = Logger(subsystem: "com.skybridge.quantum", category: "OQSProvider")
    private let keyPairAuthority: PQCKeyPairStoreAuthority
    private let scopeSource: SkyBridgeSharedIdentityScopeSource
    private var mldsa65Keys: [String: (publicKey: Data, privateKey: SecureBytes)] = [:]
    private var localSigningPublicKeys: [SigningKeyID: Data] = [:]
    private var authenticatedRemoteSigningPublicKeys: [SigningKeyID: Data] = [:]

    init(
        keyPairAuthority: PQCKeyPairStoreAuthority = .staged,
        scopeSource: SkyBridgeSharedIdentityScopeSource = .requiredEntitlement
    ) {
        self.keyPairAuthority = keyPairAuthority
        self.scopeSource = scopeSource
    }

    private var keyPairStorageScope: PQCKeyPairStoreStorageScope {
        PQCKeyPairStoreStorageScope(
            canonicalLocation: nil,
            keychainScopeSource: scopeSource,
            includeLegacyKeychain: true
        )
    }

    private func validatedPQCPeerId(_ peerId: String) throws -> String {
        do {
            return try PQCIdentityToken.validated(peerId)
        } catch {
            throw PQCSigningTrustError.invalidPeerId
        }
    }

    func registerAuthenticatedSigningPublicKey(
        _ publicKey: Data,
        peerId: String,
        algorithm: String
    ) throws {
        let normalizedPeerId = try validatedPQCPeerId(peerId)
        let parameters = try signingParameters(for: algorithm)
        guard supportedSignatureAlgorithms.contains(parameters.algorithm) else {
            throw PQCSigningTrustError.unsupportedSignatureAlgorithm(parameters.algorithm)
        }
        guard publicKey.count == parameters.publicKeyLength else {
            throw PQCSigningTrustError.invalidPublicKeyLength(
                algorithm: parameters.algorithm,
                expected: parameters.publicKeyLength,
                actual: publicKey.count
            )
        }

        let keyID = SigningKeyID(peerId: normalizedPeerId, algorithm: parameters.algorithm)
        if let existing = authenticatedRemoteSigningPublicKeys[keyID] {
            guard existing == publicKey else {
                throw PQCSigningTrustError.authenticatedKeyConflict(
                    peerId: normalizedPeerId,
                    algorithm: parameters.algorithm
                )
            }
            return
        }
        authenticatedRemoteSigningPublicKeys[keyID] = publicKey
    }

    func sign(data: Data, peerId: String, algorithm: String) async throws -> Data {
        let normalizedPeerId = try validatedPQCPeerId(peerId)
        let parameters = try signingParameters(for: algorithm)
        guard supportedSignatureAlgorithms.contains(parameters.algorithm) else {
            throw PQCSigningTrustError.unsupportedSignatureAlgorithm(parameters.algorithm)
        }

        switch parameters.algorithm {
        case "ML-DSA-65":
#if canImport(liboqs)
            let result: OQSSignatureResult
            do {
                result = try await OQSBridge.sign(
                    data,
                    peerId: normalizedPeerId,
                    algorithm: .mldsa65,
                    authority: keyPairAuthority,
                    scopeSource: scopeSource
                )
            } catch let error as NSError
                where error.domain == "PQC" && [-303, -306].contains(error.code) {
                throw PQCSigningTrustError.corruptLocalKeyPair(
                    peerId: normalizedPeerId,
                    algorithm: parameters.algorithm
                )
            } catch PQCKeyPairStoreError.incompleteLegacyKeyPair {
                throw PQCSigningTrustError.corruptLocalKeyPair(
                    peerId: normalizedPeerId,
                    algorithm: parameters.algorithm
                )
            } catch is PQCKeyPairRecordCodecError {
                throw PQCSigningTrustError.corruptLocalKeyPair(
                    peerId: normalizedPeerId,
                    algorithm: parameters.algorithm
                )
            }
            guard result.publicKey.count == parameters.publicKeyLength,
                  result.signature.count == parameters.signatureLength else {
                throw PQCSigningTrustError.corruptLocalKeyPair(
                    peerId: normalizedPeerId,
                    algorithm: parameters.algorithm
                )
            }
            localSigningPublicKeys[
                SigningKeyID(peerId: normalizedPeerId, algorithm: parameters.algorithm)
            ] = result.publicKey
            return result.signature
#else
            let pkLen = oqs_raii_mldsa65_public_key_length()
            let skLen = oqs_raii_mldsa65_secret_key_length()
            let sigMax = oqs_raii_mldsa65_signature_length()
            let pubService = PQCKeyTags.service("MLDSA", "65", "Pub")
            let privService = PQCKeyTags.service("MLDSA", "65", "Priv")
            if let cached = mldsa65Keys[normalizedPeerId] {
                guard cached.publicKey.count == Int(pkLen),
                      cached.privateKey.byteCount == Int(skLen) else {
                    throw PQCSigningTrustError.corruptLocalKeyPair(
                        peerId: normalizedPeerId,
                        algorithm: parameters.algorithm
                    )
                }
                let sig = try mldsa65Sign(data: data, privateKey: cached.privateKey, sigMax: sigMax, skLen: skLen)
                localSigningPublicKeys[
                    SigningKeyID(peerId: normalizedPeerId, algorithm: parameters.algorithm)
                ] = cached.publicKey
                return sig
            }

            let descriptor = PQCKeyPairStoreDescriptor(
                backend: .liboqs,
                purpose: .signature,
                algorithm: "ML-DSA-65",
                identity: normalizedPeerId,
                authority: keyPairAuthority,
                storageScope: keyPairStorageScope
            )
            var record: PQCKeyPairRecord
            do {
                record = try PQCKeyPairStore.loadOrCreate(
                    descriptor: descriptor,
                    publicKeyLength: Int(pkLen),
                    privateKeyLength: Int(skLen),
                    legacyPublicService: pubService,
                    legacyPrivateService: privService,
                    validatePair: { record in
                        try Self.validateMLDSA65KeyPair(
                            record,
                            publicKeyLength: pkLen,
                            privateKeyLength: skLen,
                            signatureLength: sigMax
                        )
                    },
                    generate: {
                        var pub = [UInt8](repeating: 0, count: Int(pkLen))
                        var sec = [UInt8](repeating: 0, count: Int(skLen))
                        defer {
                            PQCKeyPairRecordCodec.wipe(&pub)
                            PQCKeyPairRecordCodec.wipe(&sec)
                        }
                        let rc = oqs_raii_mldsa65_keypair(&pub, pkLen, &sec, skLen)
                        if rc != OQSRAII_SUCCESS {
                            throw NSError(
                                domain: "PQC",
                                code: -401,
                                userInfo: [NSLocalizedDescriptionKey: "ML‑DSA‑65 密钥对生成失败"]
                            )
                        }
                        return PQCKeyPairRecord(
                            algorithmIdentifier: descriptor.algorithmIdentifier,
                            publicKey: Data(pub),
                            privateKey: Data(sec)
                        )
                    }
                )
            } catch PQCKeyPairStoreError.incompleteLegacyKeyPair {
                throw PQCSigningTrustError.corruptLocalKeyPair(
                    peerId: normalizedPeerId,
                    algorithm: parameters.algorithm
                )
            } catch is PQCKeyPairRecordCodecError {
                throw PQCSigningTrustError.corruptLocalKeyPair(
                    peerId: normalizedPeerId,
                    algorithm: parameters.algorithm
                )
            }
            defer { PQCKeyPairRecordCodec.wipe(&record.privateKey) }
            let keyPair = (
                publicKey: record.publicKey,
                privateKey: SecureBytes(data: record.privateKey)
            )
            mldsa65Keys[normalizedPeerId] = keyPair
            localSigningPublicKeys[
                SigningKeyID(peerId: normalizedPeerId, algorithm: parameters.algorithm)
            ] = keyPair.publicKey
            return try mldsa65Sign(
                data: data,
                privateKey: keyPair.privateKey,
                sigMax: sigMax,
                skLen: skLen
            )
#endif
        case "ML-DSA-87":
            #if canImport(liboqs)
            let result: OQSSignatureResult
            do {
                result = try await OQSBridge.sign(
                    data,
                    peerId: normalizedPeerId,
                    algorithm: .mldsa87,
                    authority: keyPairAuthority,
                    scopeSource: scopeSource
                )
            } catch let error as NSError
                where error.domain == "PQC" && [-303, -306].contains(error.code) {
                throw PQCSigningTrustError.corruptLocalKeyPair(
                    peerId: normalizedPeerId,
                    algorithm: parameters.algorithm
                )
            } catch PQCKeyPairStoreError.incompleteLegacyKeyPair {
                throw PQCSigningTrustError.corruptLocalKeyPair(
                    peerId: normalizedPeerId,
                    algorithm: parameters.algorithm
                )
            } catch is PQCKeyPairRecordCodecError {
                throw PQCSigningTrustError.corruptLocalKeyPair(
                    peerId: normalizedPeerId,
                    algorithm: parameters.algorithm
                )
            }
            guard result.publicKey.count == parameters.publicKeyLength,
                  result.signature.count == parameters.signatureLength else {
                throw PQCSigningTrustError.corruptLocalKeyPair(
                    peerId: normalizedPeerId,
                    algorithm: parameters.algorithm
                )
            }
            localSigningPublicKeys[
                SigningKeyID(peerId: normalizedPeerId, algorithm: parameters.algorithm)
            ] = result.publicKey
            return result.signature
            #else
            throw PQCSigningTrustError.unsupportedSignatureAlgorithm(parameters.algorithm)
            #endif
        default:
            throw PQCSigningTrustError.unsupportedSignatureAlgorithm(parameters.algorithm)
        }
    }

    func localSigningPublicKey(peerId: String, algorithm: String) throws -> Data {
        let normalizedPeerId = try validatedPQCPeerId(peerId)
        let parameters = try signingParameters(for: algorithm)
        let keyID = SigningKeyID(peerId: normalizedPeerId, algorithm: parameters.algorithm)
        guard let publicKey = localSigningPublicKeys[keyID] else {
            throw PQCSigningTrustError.localSigningPublicKeyUnavailable(
                peerId: normalizedPeerId,
                algorithm: parameters.algorithm
            )
        }
        return publicKey
    }

    func verify(data: Data, signature: Data, peerId: String, algorithm: String) async -> Bool {
        guard let normalizedPeerId = try? PQCIdentityToken.validated(peerId),
              let parameters = try? signingParameters(for: algorithm),
              supportedSignatureAlgorithms.contains(parameters.algorithm),
              signature.count == parameters.signatureLength else {
            return false
        }
        let keyID = SigningKeyID(peerId: normalizedPeerId, algorithm: parameters.algorithm)
        guard let publicKey = authenticatedRemoteSigningPublicKeys[keyID],
              publicKey.count == parameters.publicKeyLength else {
            return false
        }

        switch parameters.algorithm {
        case "ML-DSA-65":
#if canImport(liboqs)
            return await OQSBridge.verify(
                data,
                signature: signature,
                publicKey: publicKey,
                algorithm: .mldsa65
            )
#else
            let pkLen = oqs_raii_mldsa65_public_key_length()
            let messageBacking = data.isEmpty ? Data([0]) : data
            let ok = signature.withUnsafeBytes { sPtr -> Bool in
                messageBacking.withUnsafeBytes { mPtr -> Bool in
                    publicKey.withUnsafeBytes { pPtr -> Bool in
                        let s = sPtr.bindMemory(to: UInt8.self)
                        let m = mPtr.bindMemory(to: UInt8.self)
                        let p = pPtr.bindMemory(to: UInt8.self)
                        return oqs_raii_mldsa65_verify(m.baseAddress, data.count, s.baseAddress, signature.count, p.baseAddress, pkLen)
                    }
                }
            }
            return ok
#endif
        case "ML-DSA-87":
            #if canImport(liboqs)
            return await OQSBridge.verify(
                data,
                signature: signature,
                publicKey: publicKey,
                algorithm: .mldsa87
            )
            #else
            return false
            #endif
        default:
            return false
        }
    }

    private func signingParameters(
        for algorithm: String
    ) throws -> (algorithm: String, publicKeyLength: Int, signatureLength: Int) {
        switch algorithm.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "ML-DSA", "ML-DSA-65", "MLDSA", "MLDSA-65":
            return ("ML-DSA-65", 1_952, 3_309)
        case "ML-DSA-87", "MLDSA-87":
            return ("ML-DSA-87", 2_592, 4_627)
        default:
            throw PQCSigningTrustError.unsupportedSignatureAlgorithm(algorithm)
        }
    }

    private func mldsa65Sign(
        data: Data,
        privateKey: SecureBytes,
        sigMax: Int,
        skLen: Int
    ) throws -> Data {
        guard privateKey.byteCount == skLen else {
            throw PQCSigningTrustError.corruptLocalKeyPair(
                peerId: "<redacted>",
                algorithm: "ML-DSA-65"
            )
        }
        var sig = [UInt8](repeating: 0, count: Int(sigMax))
        var sigLen = Int(sigMax)
        let msg = data.isEmpty ? [UInt8(0)] : [UInt8](data)
        let rc: Int32 = privateKey.withUnsafeBytes { skPtr -> Int32 in
            let s = skPtr.bindMemory(to: UInt8.self)
            return oqs_raii_mldsa65_sign(msg, data.count, s.baseAddress, skLen, &sig, &sigLen)
        }
        if rc != Int32(OQSRAII_SUCCESS) {
            throw NSError(domain: "PQC", code: -403, userInfo: [NSLocalizedDescriptionKey: "ML‑DSA‑65 签名失败"])
        }
        guard sigLen == Int(sigMax) else {
            throw NSError(
                domain: "PQC",
                code: -409,
                userInfo: [NSLocalizedDescriptionKey: "ML‑DSA‑65 签名长度无效"]
            )
        }
        return Data(sig[0..<sigLen])
    }

    private static func validateMLDSA65KeyPair(
        _ record: PQCKeyPairRecord,
        publicKeyLength: Int,
        privateKeyLength: Int,
        signatureLength: Int
    ) throws {
        let challenge = [UInt8]("SkyBridge/PQCKeyPair/v3/signature-validation".utf8)
        var signature = [UInt8](repeating: 0, count: signatureLength)
        defer { PQCKeyPairRecordCodec.wipe(&signature) }
        var actualSignatureLength = signatureLength
        let signResult: Int32 = record.privateKey.withUnsafeBytes { privateRaw in
            let privateKey = privateRaw.bindMemory(to: UInt8.self)
            return oqs_raii_mldsa65_sign(
                challenge,
                challenge.count,
                privateKey.baseAddress,
                privateKeyLength,
                &signature,
                &actualSignatureLength
            )
        }
        guard signResult == Int32(OQSRAII_SUCCESS),
              actualSignatureLength == signatureLength else {
            throw PQCSigningTrustError.corruptLocalKeyPair(
                peerId: "<redacted>",
                algorithm: "ML-DSA-65"
            )
        }
        let isValid = record.publicKey.withUnsafeBytes { publicRaw in
            let publicKey = publicRaw.bindMemory(to: UInt8.self)
            return oqs_raii_mldsa65_verify(
                challenge,
                challenge.count,
                signature,
                actualSignatureLength,
                publicKey.baseAddress,
                publicKeyLength
            )
        }
        guard isValid else {
            throw PQCSigningTrustError.corruptLocalKeyPair(
                peerId: "<redacted>",
                algorithm: "ML-DSA-65"
            )
        }
    }

    private static func validateMLKEM768KeyPair(
        _ record: PQCKeyPairRecord,
        publicKeyLength: Int,
        privateKeyLength: Int,
        ciphertextLength: Int,
        sharedSecretLength: Int
    ) throws {
        var ciphertext = [UInt8](repeating: 0, count: ciphertextLength)
        var encapsulatedSecret = [UInt8](repeating: 0, count: sharedSecretLength)
        var decapsulatedSecret = [UInt8](repeating: 0, count: sharedSecretLength)
        defer {
            PQCKeyPairRecordCodec.wipe(&encapsulatedSecret)
            PQCKeyPairRecordCodec.wipe(&decapsulatedSecret)
        }
        let encapsulationResult: Int32 = record.publicKey.withUnsafeBytes { publicRaw in
            let publicKey = publicRaw.bindMemory(to: UInt8.self)
            return oqs_raii_mlkem768_encaps(
                publicKey.baseAddress,
                publicKeyLength,
                &ciphertext,
                ciphertextLength,
                &encapsulatedSecret,
                sharedSecretLength
            )
        }
        guard encapsulationResult == Int32(OQSRAII_SUCCESS) else {
            throw NSError(
                domain: "PQC",
                code: -405,
                userInfo: [NSLocalizedDescriptionKey: "ML-KEM-768 local key-pair validation failed"]
            )
        }
        let decapsulationResult: Int32 = record.privateKey.withUnsafeBytes { privateRaw in
            let privateKey = privateRaw.bindMemory(to: UInt8.self)
            return oqs_raii_mlkem768_decaps(
                ciphertext,
                ciphertextLength,
                privateKey.baseAddress,
                privateKeyLength,
                &decapsulatedSecret,
                sharedSecretLength
            )
        }
        guard decapsulationResult == Int32(OQSRAII_SUCCESS),
              constantTimeEqual(encapsulatedSecret, decapsulatedSecret) else {
            throw NSError(
                domain: "PQC",
                code: -405,
                userInfo: [NSLocalizedDescriptionKey: "ML-KEM-768 public/private keys do not match"]
            )
        }
    }

    private static func constantTimeEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }

    func kemEncapsulate(peerId: String, kemVariant: String) async throws -> (sharedSecret: Data, encapsulated: Data) {
        let normalizedPeerId = try validatedPQCPeerId(peerId)
        switch kemVariant {
        case "ML-KEM-768":
            let pkLen = oqs_raii_mlkem768_public_key_length()
            let skLen = oqs_raii_mlkem768_secret_key_length()
            let ctLen = oqs_raii_mlkem768_ciphertext_length()
            let ssLen = oqs_raii_mlkem768_shared_secret_length()
            let pubService = PQCKeyTags.service("MLKEM", "768", "Pub")
            let privService = PQCKeyTags.service("MLKEM", "768", "Priv")
            let descriptor = PQCKeyPairStoreDescriptor(
                backend: .liboqs,
                purpose: .kem,
                algorithm: "ML-KEM-768",
                identity: normalizedPeerId,
                authority: keyPairAuthority,
                storageScope: keyPairStorageScope
            )
            var record = try PQCKeyPairStore.loadOrCreate(
                descriptor: descriptor,
                publicKeyLength: Int(pkLen),
                privateKeyLength: Int(skLen),
                legacyPublicService: pubService,
                legacyPrivateService: privService,
                validatePair: { record in
                    try Self.validateMLKEM768KeyPair(
                        record,
                        publicKeyLength: pkLen,
                        privateKeyLength: skLen,
                        ciphertextLength: ctLen,
                        sharedSecretLength: ssLen
                    )
                },
                generate: {
                var p = [UInt8](repeating: 0, count: Int(pkLen))
                var s = [UInt8](repeating: 0, count: Int(skLen))
                defer {
                    PQCKeyPairRecordCodec.wipe(&p)
                    PQCKeyPairRecordCodec.wipe(&s)
                }
                let rc = oqs_raii_mlkem768_keypair(&p, pkLen, &s, skLen)
                if rc != OQSRAII_SUCCESS { throw NSError(domain: "PQC", code: -404, userInfo: [NSLocalizedDescriptionKey: "ML‑KEM‑768 密钥对生成失败"]) }
                return PQCKeyPairRecord(
                    algorithmIdentifier: descriptor.algorithmIdentifier,
                    publicKey: Data(p),
                    privateKey: Data(s)
                )
            })
            defer { PQCKeyPairRecordCodec.wipe(&record.privateKey) }
            var ct = [UInt8](repeating: 0, count: Int(ctLen))
            var ss = [UInt8](repeating: 0, count: Int(ssLen))
            defer { PQCKeyPairRecordCodec.wipe(&ss) }
            let rc: Int32 = record.publicKey.withUnsafeBytes { pPtr -> Int32 in
                let p = pPtr.bindMemory(to: UInt8.self)
                return oqs_raii_mlkem768_encaps(p.baseAddress, pkLen, &ct, ctLen, &ss, ssLen)
            }
            if rc != Int32(OQSRAII_SUCCESS) { throw NSError(domain: "PQC", code: -406, userInfo: [NSLocalizedDescriptionKey: "ML‑KEM‑768 封装失败"]) }
            return (Data(ss), Data(ct))
        case "ML-KEM-1024":
            let r = try await OQSBridge.kemEncapsulate(
                peerId: normalizedPeerId,
                algorithm: .mlkem1024,
                authority: keyPairAuthority,
                scopeSource: scopeSource
            )
            return (r.shared, r.encapsulated)
        default:
            throw NSError(domain: "PQC", code: -102, userInfo: [NSLocalizedDescriptionKey: "不支持的KEM变体: \(kemVariant)"])
        }
    }
    func kemDecapsulate(peerId: String, encapsulated: Data, kemVariant: String) async throws -> Data {
        let normalizedPeerId = try validatedPQCPeerId(peerId)
        switch kemVariant {
        case "ML-KEM-768":
            let pkLen = oqs_raii_mlkem768_public_key_length()
            let skLen = oqs_raii_mlkem768_secret_key_length()
            let ctLen = oqs_raii_mlkem768_ciphertext_length()
            let ssLen = oqs_raii_mlkem768_shared_secret_length()
            let pubService = PQCKeyTags.service("MLKEM", "768", "Pub")
            let privService = PQCKeyTags.service("MLKEM", "768", "Priv")
            guard encapsulated.count == Int(ctLen) else {
                throw NSError(
                    domain: "PQC",
                    code: -407,
                    userInfo: [NSLocalizedDescriptionKey: "ML‑KEM‑768 封装密文长度无效"]
                )
            }
            let descriptor = PQCKeyPairStoreDescriptor(
                backend: .liboqs,
                purpose: .kem,
                algorithm: "ML-KEM-768",
                identity: normalizedPeerId,
                authority: keyPairAuthority,
                storageScope: keyPairStorageScope
            )
            guard var record = try PQCKeyPairStore.loadOrMigrateLegacy(
                descriptor: descriptor,
                publicKeyLength: Int(pkLen),
                privateKeyLength: Int(skLen),
                legacyPublicService: pubService,
                legacyPrivateService: privService,
                validatePair: { record in
                    try Self.validateMLKEM768KeyPair(
                        record,
                        publicKeyLength: pkLen,
                        privateKeyLength: skLen,
                        ciphertextLength: ctLen,
                        sharedSecretLength: ssLen
                    )
                }
            ) else {
                throw NSError(
                    domain: "PQC",
                    code: -407,
                    userInfo: [NSLocalizedDescriptionKey: "ML‑KEM‑768 本地密钥对缺失"]
                )
            }
            defer { PQCKeyPairRecordCodec.wipe(&record.privateKey) }
            var ss = [UInt8](repeating: 0, count: Int(ssLen))
            defer { PQCKeyPairRecordCodec.wipe(&ss) }
            let rc: Int32 = record.privateKey.withUnsafeBytes { sPtr -> Int32 in
                encapsulated.withUnsafeBytes { cPtr -> Int32 in
                    let s = sPtr.bindMemory(to: UInt8.self)
                    let c = cPtr.bindMemory(to: UInt8.self)
                    return oqs_raii_mlkem768_decaps(c.baseAddress, ctLen, s.baseAddress, skLen, &ss, ssLen)
                }
            }
            if rc != Int32(OQSRAII_SUCCESS) { throw NSError(domain: "PQC", code: -408, userInfo: [NSLocalizedDescriptionKey: "ML‑KEM‑768 解封装失败"]) }
            return Data(ss)
        case "ML-KEM-1024":
            return try await OQSBridge.kemDecapsulate(
                encapsulated,
                peerId: normalizedPeerId,
                algorithm: .mlkem1024,
                authority: keyPairAuthority,
                scopeSource: scopeSource
            )
        default:
            throw NSError(domain: "PQC", code: -103, userInfo: [NSLocalizedDescriptionKey: "不支持的KEM变体: \(kemVariant)"])
        }
    }
 /// HPKE 封装 - 使用 KEM + AEAD 组合实现
 ///
 /// 注意：完整的 HPKE 需要 oqs-provider 集成，当前使用 KEM + AES-GCM 组合实现
 /// - macOS 26.0+ 请使用 ApplePQCProvider 获得原生 HPKE 支持
 /// - macOS 14.0-15.x 使用此降级实现
    func hpkeSeal(recipientPeerId: String, plaintext: Data, associatedData: Data?) async throws -> (ciphertext: Data, encapsulatedKey: Data) {
 // 降级实现：使用 KEM 封装 + AES-GCM 加密
 // 这不是标准 HPKE，但提供了类似的安全保证
        logger.info("ℹ️ OQS HPKE 降级实现：使用 KEM + AES-GCM 组合")
        
 // 1. 使用 ML-KEM-768 获取共享密钥
        let kemResult = try await kemEncapsulate(peerId: recipientPeerId, kemVariant: "ML-KEM-768")
        var sharedSecret = kemResult.sharedSecret
        defer { PQCKeyPairRecordCodec.wipe(&sharedSecret) }
        let encapsulatedKey = kemResult.encapsulated
        
 // 2. 从共享密钥派生 AES-256 密钥（使用 HKDF）
        let derivedKey = try CryptoKitEnhancements.deriveSessionKey(
            from: SymmetricKey(data: sharedSecret),
            salt: associatedData ?? Data("SkyBridgeOQSHPKE".utf8),
            info: Data("hpke-seal".utf8),
            outputLength: 32
        )
        
 // 3. 使用 AES-GCM 加密明文
        let sealedBox = try AES.GCM.seal(plaintext, using: derivedKey)
        let ciphertext = sealedBox.combined ?? (sealedBox.nonce + sealedBox.ciphertext + sealedBox.tag)
        
        logger.info("✅ OQS HPKE 封装完成：密文 \(ciphertext.count) 字节，封装密钥 \(encapsulatedKey.count) 字节")
        return (ciphertext, encapsulatedKey)
    }
    
 /// HPKE 解封 - 使用 KEM + AEAD 组合实现
    func hpkeOpen(recipientPeerId: String, ciphertext: Data, encapsulatedKey: Data, associatedData: Data?) async throws -> Data {
 // 降级实现：使用 KEM 解封装 + AES-GCM 解密
        logger.info("ℹ️ OQS HPKE 降级实现：使用 KEM + AES-GCM 组合")
        
 // 1. 使用 ML-KEM-768 解封装获取共享密钥
        var sharedSecret = try await kemDecapsulate(
            peerId: recipientPeerId,
            encapsulated: encapsulatedKey,
            kemVariant: "ML-KEM-768"
        )
        defer { PQCKeyPairRecordCodec.wipe(&sharedSecret) }
        
 // 2. 从共享密钥派生 AES-256 密钥（与加密时相同的参数）
        let derivedKey = try CryptoKitEnhancements.deriveSessionKey(
            from: SymmetricKey(data: sharedSecret),
            salt: associatedData ?? Data("SkyBridgeOQSHPKE".utf8),
            info: Data("hpke-seal".utf8),
            outputLength: 32
        )
        
 // 3. 使用 AES-GCM 解密密文
 // 解析 combined 格式：nonce (12) + ciphertext + tag (16)
        guard ciphertext.count >= 28 else { // 最小：12 + 0 + 16
            throw NSError(domain: "PQC", code: -106, userInfo: [NSLocalizedDescriptionKey: "HPKE 密文格式无效"])
        }
        
        let nonce = try AES.GCM.Nonce(data: ciphertext.prefix(12))
        let tag = ciphertext.suffix(16)
        let encryptedData = ciphertext.dropFirst(12).dropLast(16)
        
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: encryptedData, tag: tag)
        let plaintext = try AES.GCM.open(sealedBox, using: derivedKey)
        
        logger.info("✅ OQS HPKE 解封完成：明文 \(plaintext.count) 字节")
        return plaintext
    }
}

// MARK: - PQC 系统要求说明

/// PQC（后量子密码学）功能的系统要求
public enum PQCSystemRequirements {
 /// 获取当前系统的 PQC 支持状态
    public static var supportStatus: String {
        if #available(iOS 26.0, macOS 26.0, *) {
            #if HAS_APPLE_PQC_SDK
            return "✅ iOS/macOS 26+：Apple CryptoKit PQC 候选能力可用；必须通过 runtime self-test 与协商套件证明后才可显示为 PQC 保护"
            #else
            return "⚠️ iOS/macOS 26+：系统具备 Apple PQC 基础，但当前构建未启用 HAS_APPLE_PQC_SDK；不得显示为 Apple PQC 保护"
            #endif
        } else if #available(iOS 17.0, macOS 14.0, *) {
            return "⚠️ iOS 17+/macOS 14.0–15.x：可使用 liboqs PQC 候选能力；连接是否 PQC 保护必须来自协商套件证明"
        } else {
            return "❌ iOS 16/macOS 13 及以下：不支持项目 PQC provider；仅可作为传统兼容连接"
        }
    }
    
 /// 获取详细的系统要求说明
    public static var detailedRequirements: String {
        """
        后量子密码学 (PQC) 系统要求：

        以下内容描述本机候选能力和部署要求，不代表当前连接已使用 PQC。连接状态必须来自 runtime self-test、握手协商套件和会话证明。
        
        【推荐】macOS Tahoe 26+ （2025-09-15 正式发布）
        - 原生 Apple CryptoKit PQC 候选能力（HPKE X-Wing、ML-KEM、ML-DSA）
        - ML-KEM-768/1024 密钥封装
        - ML-DSA-65/87 数字签名
        - X-Wing HPKE（混合后量子+经典），需 runtime self-test 与协商证明
        - 硬件加速（Apple Silicon）
        
        【兼容】macOS 14.0–15.x
        - 经典密码 + liboqs/OQSRAII PQC 候选实现
        - ML-KEM-768/1024 密钥封装
        - ML-DSA-65/87 数字签名
        - HPKE 使用 KEM+AES-GCM 降级实现（无原生 HPKE）
        
        【不支持】macOS 13.x 及以下
        - 仅支持传统 P-256 ECDH/ECDSA
        - 无后量子保护
        
        安全建议：为获得最佳候选能力，建议升级到 macOS Tahoe 26 或更高版本；不要仅凭系统版本或 SDK 符号显示“已受 PQC 保护”。
        """
    }
}
