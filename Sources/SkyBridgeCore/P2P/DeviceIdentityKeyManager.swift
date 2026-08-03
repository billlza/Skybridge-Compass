//
// DeviceIdentityKeyManager.swift
// SkyBridgeCore
//
// iOS/iPadOS P2P Integration - Device Identity Key Management
// Requirements: 4.1, 9.1
//
// 管理设备身份密钥：
// 1. 优先使用 Secure Enclave (kSecAttrTokenIDSecureEnclave)
// 2. 回退到 Keychain 存储
// 3. 支持密钥轮换策略
// 4. 非导出密钥策略
//

import Foundation
import CryptoKit
import Security
#if canImport(OQSRAII)
import OQSRAII
#endif

// MARK: - Device Identity Key Type

/// 设备身份密钥类型
public enum DeviceIdentityKeyType: String, Codable, Sendable {
 /// P-256 签名密钥（Secure Enclave 支持）
    case p256Signing = "P256-Signing"
    
 /// P-256 密钥协商密钥
    case p256KeyAgreement = "P256-KeyAgreement"
}

// MARK: - Device Identity Key Info

/// 设备身份密钥信息
public struct DeviceIdentityKeyInfo: Codable, Sendable, Equatable {
 /// 设备 ID
    public let deviceId: String
    
 /// 公钥指纹 (SHA-256 hex, 64 chars)
    public let pubKeyFP: String
    
 /// 公钥数据 (DER 编码)
    public let publicKey: Data
    
 /// 密钥类型
    public let keyType: DeviceIdentityKeyType
    
 /// 创建时间
    public let createdAt: Date
    
 /// 是否存储在 Secure Enclave
    public let isSecureEnclave: Bool
    
 /// 短 ID（用于 UI 显示，前 16 chars）
    public var shortId: String {
        String(pubKeyFP.prefix(P2PConstants.pubKeyFPDisplayLength))
    }
    
    public init(
        deviceId: String,
        pubKeyFP: String,
        publicKey: Data,
        keyType: DeviceIdentityKeyType,
        createdAt: Date = Date(),
        isSecureEnclave: Bool
    ) {
        self.deviceId = deviceId
        self.pubKeyFP = pubKeyFP
        self.publicKey = publicKey
        self.keyType = keyType
        self.createdAt = createdAt
        self.isSecureEnclave = isSecureEnclave
    }
}

/// Fixed, non-secret storage categories for the signed laboratory identity
/// audit. Real access-group names and persistent references never cross this
/// boundary.
@_spi(SkyBridgeSmokeDiagnostics)
public enum DeviceIdentityLegacyAuditNamespace: String, Codable, Sendable, CaseIterable {
    case sharedDataProtection = "shared-data-protection"
    case otherDataProtection = "other-data-protection"
    case legacyFileKeychain = "legacy-file-keychain"
}

@_spi(SkyBridgeSmokeDiagnostics)
public enum DeviceIdentityLegacyAuditState: String, Codable, Sendable {
    case inspectionUnavailable = "inspection-unavailable"
    case noIdentity = "no-identity"
    case legacyMigrationIncomplete = "legacy-migration-incomplete"
    case legacyMigrationConflict = "legacy-migration-conflict"
    case legacyMigrationRequiresRotation = "legacy-migration-requires-rotation"
    case legacyCommittedTupleSelected = "legacy-committed-tuple-selected"
    case authorityClean = "authority-clean"
    case matchingLegacyRemnants = "matching-legacy-remnants"
    case conflictingLegacyRemnants = "conflicting-legacy-remnants"
}

@_spi(SkyBridgeSmokeDiagnostics)
public enum DeviceIdentityLegacyAuditComparisonBasis: String, Codable, Sendable {
    case none
    case sharedAuthority = "shared-authority"
    case firstValidatedLegacyKeyInfo = "first-validated-legacy-key-info"
}

@_spi(SkyBridgeSmokeDiagnostics)
public enum DeviceIdentityLegacyAuditMismatchDimension: String, Codable, Sendable, CaseIterable {
    case keyInfoDeviceId = "key-info-device-id"
    case keyInfoPublicKey = "key-info-public-key"
    case keyInfoFingerprint = "key-info-fingerprint"
    case keyInfoCreatedAt = "key-info-created-at"
    case keyInfoSecureEnclave = "key-info-secure-enclave"
    case privateKeyPublicKey = "private-key-public-key"
    case privateKeySecureEnclave = "private-key-secure-enclave"
    case deviceId = "device-id"
}

@_spi(SkyBridgeSmokeDiagnostics)
public struct DeviceIdentityLegacyAuditMismatchCount: Codable, Sendable, Equatable {
    public let dimension: DeviceIdentityLegacyAuditMismatchDimension
    public let count: Int
}

/// Count-only evidence for one value class in one fixed storage category.
/// `unresolved` is used only when no shared authority exists, so the audit does
/// not pretend legacy values can be classified against a missing winner.
@_spi(SkyBridgeSmokeDiagnostics)
public struct DeviceIdentityLegacyAuditValueCount: Codable, Sendable, Equatable {
    public let matching: Int
    public let conflicting: Int
    public let unresolved: Int

    public var total: Int {
        matching + conflicting + unresolved
    }
}

@_spi(SkyBridgeSmokeDiagnostics)
public struct DeviceIdentityLegacyAuditNamespaceSummary: Codable, Sendable, Equatable {
    public let namespace: DeviceIdentityLegacyAuditNamespace
    public let privateKeys: DeviceIdentityLegacyAuditValueCount
    public let keyInfos: DeviceIdentityLegacyAuditValueCount
    public let deviceIds: DeviceIdentityLegacyAuditValueCount
    public let mismatches: [DeviceIdentityLegacyAuditMismatchCount]
}

/// A deliberately narrow diagnostic record. It proves only what the current
/// signed process could read at one instant; it contains no identity value,
/// fingerprint, application tag, access-group string, or persistent reference.
@_spi(SkyBridgeSmokeDiagnostics)
public struct DeviceIdentityLegacyAuditReport: Codable, Sendable, Equatable {
    public let schemaVersion: UInt8
    public let state: DeviceIdentityLegacyAuditState
    public let authorityPresent: Bool
    public let authorityKeyValidated: Bool
    public let comparisonBasis: DeviceIdentityLegacyAuditComparisonBasis
    public let stableAcrossReads: Bool
    public let inspectionStatus: DeviceIdentityLegacyResidueInspectionStatus
    public let namespaces: [DeviceIdentityLegacyAuditNamespaceSummary]
}

/// Fixed, non-secret reasons why non-authoritative legacy residue could not be
/// inspected after the shared authority and its exact private key were already
/// validated. These values are safe for signed smoke status and diagnostics;
/// raw Security.framework errors, tags, access groups, and persistent
/// references must never cross this boundary.
@_spi(SkyBridgeSmokeDiagnostics)
public enum DeviceIdentityLegacyResidueInspectionFailureReason: String, Codable, Sendable {
    case accessDenied = "access-denied"
    case keychainUnavailable = "keychain-unavailable"
    case malformedAttributes = "malformed-attributes"
    case malformedKeyInfo = "malformed-key-info"
    case invalidDeviceId = "invalid-device-id"
    case candidateLimitExceeded = "candidate-limit-exceeded"
    case keyMaterialUnavailable = "key-material-unavailable"
    case changedDuringRead = "changed-during-read"
}

/// Last startup inspection status for residue surrounding a validated shared
/// authority. The sum type makes it impossible to represent an unavailable
/// inspection as clean or to attach conflict counts to incomplete evidence.
@_spi(SkyBridgeSmokeDiagnostics)
public enum DeviceIdentityLegacyResidueInspectionStatus: Sendable, Equatable {
    case complete(hasConflicts: Bool)
    case unavailable(DeviceIdentityLegacyResidueInspectionFailureReason)

    public var schemaVersion: UInt8 { 1 }

    public var inspectionComplete: Bool {
        if case .complete = self { return true }
        return false
    }

    public var failureReason: DeviceIdentityLegacyResidueInspectionFailureReason? {
        guard case .unavailable(let reason) = self else { return nil }
        return reason
    }

    public var hasConflicts: Bool? {
        guard case .complete(let hasConflicts) = self else { return nil }
        return hasConflicts
    }
}

extension DeviceIdentityLegacyResidueInspectionStatus: Codable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case inspectionComplete
        case failureReason
        case hasConflicts
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(UInt8.self, forKey: .schemaVersion)
        guard schemaVersion == 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported legacy residue inspection schema"
            )
        }
        let inspectionComplete = try container.decode(
            Bool.self,
            forKey: .inspectionComplete
        )
        let failureReason = try container.decodeIfPresent(
            DeviceIdentityLegacyResidueInspectionFailureReason.self,
            forKey: .failureReason
        )
        let hasConflicts = try container.decodeIfPresent(
            Bool.self,
            forKey: .hasConflicts
        )
        switch (inspectionComplete, failureReason, hasConflicts) {
        case (true, nil, .some(let conflicts)):
            self = .complete(hasConflicts: conflicts)
        case (false, .some(let reason), nil):
            self = .unavailable(reason)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .inspectionComplete,
                in: container,
                debugDescription: "Incoherent legacy residue inspection status"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(inspectionComplete, forKey: .inspectionComplete)
        try container.encodeIfPresent(failureReason, forKey: .failureReason)
        try container.encodeIfPresent(hasConflicts, forKey: .hasConflicts)
    }
}

// MARK: - KEM Identity Key Record

/// KEM 身份密钥记录（本地存储）
public struct KEMIdentityKeyRecord: Codable, Sendable, Equatable {
    public let suiteWireId: UInt16
    public let publicKey: Data
    public let privateKey: Data
    public let createdAt: Date
    
    public init(
        suiteWireId: UInt16,
        publicKey: Data,
        privateKey: Data,
        createdAt: Date = Date()
    ) {
        self.suiteWireId = suiteWireId
        self.publicKey = publicKey
        self.privateKey = privateKey
        self.createdAt = createdAt
    }
}


// MARK: - Device Identity Key Error

/// 设备身份密钥错误
public enum DeviceIdentityKeyError: Error, LocalizedError, Sendable {
    case keyGenerationFailed(String)
    case keyNotFound
    case keyAccessDenied
    case secureEnclaveNotAvailable
    case invalidKeyData
    case incompleteKeyMaterial(String)
    case keychainError(OSStatus)
    case signatureFailed(String)
    case verificationFailed
    case keyRotationFailed(String)
    case authorityConflict(String)
    case corruptIdentityAuthority(String)
    case identityMigrationRequired
    case identityMigrationRequiresRotationAndRepinning(String)
    
    public var errorDescription: String? {
        switch self {
        case .keyGenerationFailed(let reason):
            return "Key generation failed: \(reason)"
        case .keyNotFound:
            return "Device identity key not found"
        case .keyAccessDenied:
            return "Access to device identity key denied"
        case .secureEnclaveNotAvailable:
            return "Secure Enclave not available on this device"
        case .invalidKeyData:
            return "Invalid key data"
        case .incompleteKeyMaterial(let reason):
            return "Incomplete identity key material: \(reason)"
        case .keychainError(let status):
            return "Keychain error: \(status)"
        case .signatureFailed(let reason):
            return "Signature failed: \(reason)"
        case .verificationFailed:
            return "Signature verification failed"
        case .keyRotationFailed(let reason):
            return "Key rotation failed: \(reason)"
        case .authorityConflict(let reason):
            return "Device identity authority conflict: \(reason)"
        case .corruptIdentityAuthority(let reason):
            return "Device identity authority is corrupt or incomplete: \(reason)"
        case .identityMigrationRequired:
            return "A legacy device identity exists and requires explicit migration into the shared identity authority"
        case .identityMigrationRequiresRotationAndRepinning(let reason):
            return "Device identity migration requires explicit rotation and peer re-pinning: \(reason)"
        }
    }
}

#if DEBUG || SKYBRIDGE_TESTING
enum DeviceIdentityTestingConfigurationError: Error, Sendable, Equatable {
    case emptyStorageNamespace
    case requiresNamespacedInMemoryStore
}
#endif

// MARK: - Device Identity Key Manager

/// 设备身份密钥管理器
///
/// 管理设备的长期身份密钥，用于 P2P 认证。
/// 优先使用 Secure Enclave 存储密钥（不可导出）。
@available(macOS 14.0, iOS 17.0, *)
public actor DeviceIdentityKeyManager {
    
 // MARK: - Singleton
    
 /// 共享实例
    public static let shared = DeviceIdentityKeyManager()
    
 // MARK: - Constants
    
    private enum KeychainConstants {
        static let service = "com.skybridge.p2p.identity"
        static let signingKeyTag = "com.skybridge.p2p.identity.signing"
        static let keyAgreementKeyTag = "com.skybridge.p2p.identity.keyagreement"
        static let deviceIdKey = "com.skybridge.p2p.deviceId"
        static let kemService = "com.skybridge.p2p.identity.kem"
        static let kemKeyPrefix = "kem_key_"
        
 // MARK: - Signature Mechanism Alignment ( 5.1, 5.2)
        
 /// Ed25519 协议签名密钥 tag
        static let protocolSigningKeyTag = "com.skybridge.p2p.identity.protocol.ed25519"
        
        /// Historical P-256 SE PoP tag. New code never creates or queries it;
        /// the validated unique-tag identity authority carries the PoP key.
        static let sePoPKeyTag = "com.skybridge.p2p.identity.pop.p256"
        
 // MARK: - ML-DSA-65 Protocol Signing Key ( 11.1, 11.2)
        
 /// ML-DSA-65 协议签名密钥 service
        static let mldsaService = "com.skybridge.p2p.identity.mldsa65"
        
 /// ML-DSA-65 公钥 account
        static let mldsaPublicKeyAccount = "mldsa65_publicKey"
        
        /// ML-DSA-65 私钥 account
        static let mldsaSecretKeyAccount = "mldsa65_secretKey"
        static let mldsaCanonicalKeyPairAccount = "mldsa65_keypair_v3"
        static let mldsaAlgorithmIdentifier = "ML-DSA-65"
        static let mldsaPublicKeyLength = 1_952
        static let mldsaPrivateKeyLength = 4_032
        static let mldsaSignatureLength = 3_309
        static let secureEnclaveMLDSAService = "com.skybridge.p2p.identity.protocol.secure-enclave.v1"
        static let mirroredDeviceIdDefaultsKey = "SkyBridge.P2P.DeviceIdentity.DeviceID"
        static let mirroredProtocolSigningPublicKeyDefaultsKey = "SkyBridge.P2P.DeviceIdentity.ProtocolSigningPublicKey"
        static let mirroredMLDSAPublicKeyDefaultsKey = "SkyBridge.P2P.DeviceIdentity.MLDSA65PublicKey"
        static let inMemorySigningPrivateKey = "com.skybridge.p2p.identity.signing.inmemory.private"
        static let legacyIdentityMaximumCandidatesPerClass = 64
        static let legacyKeyInfoMaximumEncodedSize = 4_096
        static let legacyDeviceIdMaximumEncodedSize = 256
    }

    private nonisolated static var useInMemoryKeychain: Bool {
        #if DEBUG || SKYBRIDGE_TESTING
        let env = ProcessInfo.processInfo.environment
        if env["SKYBRIDGE_KEYCHAIN_IN_MEMORY"] == "1" { return true }
        if env["XCTestConfigurationFilePath"] != nil { return true }
        return NSClassFromString("XCTestCase") != nil
            || NSClassFromString("XCTest.XCTestCase") != nil
        #else
        return false
        #endif
    }

    /// Exposes only the storage lifetime contract, not the environment switch itself.
    /// Settings restoration uses this to avoid requiring a durable key to exist inside
    /// an explicitly ephemeral test store. Release builds always return `false`.
    public nonisolated static var usesEphemeralIdentityStoreForCurrentProcess: Bool {
        useInMemoryKeychain
    }
    private nonisolated(unsafe) static var inMemoryStore: [String: Data] = [:]
    private nonisolated static let inMemoryLock = NSLock()
    private nonisolated(unsafe) static var inMemoryKEMStore: [String: Data] = [:]
    private nonisolated static let inMemoryKEMLock = NSLock()

    private nonisolated static func inMemoryGet(_ key: String) -> Data? {
        inMemoryLock.lock()
        defer { inMemoryLock.unlock() }
        return inMemoryStore[key]
    }

    private nonisolated static func inMemorySet(_ data: Data, for key: String) {
        inMemoryLock.lock()
        inMemoryStore[key] = data
        inMemoryLock.unlock()
    }

    private func resolvedSharedIdentityKeychainScope() throws -> KeychainGenericPasswordScope {
        try effectiveSharedIdentityScopeSource.resolve()
    }

    /// The shipping singleton always requires the signed shared-access-group
    /// entitlement. SwiftPM XCTest processes cannot carry that entitlement, so
    /// their already-selected process-local backend receives an equally
    /// explicit synthetic scope instead of accidentally reaching production
    /// Keychain authority through one of the PQC helper layers.
    private var effectiveSharedIdentityScopeSource: SkyBridgeSharedIdentityScopeSource {
        #if DEBUG || SKYBRIDGE_TESTING
        if Self.useInMemoryKeychain {
            return .explicitForTesting(.inMemorySharedIdentityForTesting)
        }
        #endif
        return sharedIdentityScopeSource
    }

    private enum ExistingIdentityLegacyMigrationPolicy: Equatable {
        case allow
        case rejectMutation
    }

    /// Only this dedicated error may be downgraded to an unavailable residue
    /// inspection after a shared authority has already been independently
    /// validated. Unknown programming errors and authority errors still escape.
    private struct LegacyResidueInspectionError: Error, Sendable, Equatable {
        let reason: DeviceIdentityLegacyResidueInspectionFailureReason
    }
    
 // MARK: - Properties
    
    /// 缓存的密钥信息
    private var cachedKeyInfo: DeviceIdentityKeyInfo?

    /// Count-free startup health for legacy residue surrounding the cached
    /// authority. It is cached with the immutable winner so a validated
    /// authority does not trigger repeated Keychain scans or authorization UI.
    private var cachedLegacyResidueInspectionStatus:
        DeviceIdentityLegacyResidueInspectionStatus?
    
 /// 缓存的 KEM 公钥（按 suite wireId + provider tier）
    private var cachedKEMPublicKeys: [KEMCacheKey: Data] = [:]
    
 /// 缓存的 Ed25519 协议签名密钥
    private var cachedProtocolSigningKey: (publicKey: Data, privateKey: Data)?
    
    /// 缓存的 ML-DSA-65 协议签名密钥
    private var cachedMLDSASigningKey: (publicKey: Data, privateKey: Data)?
    private var cachedMLDSA87SigningIdentity: (publicKey: Data, keyHandle: SigningKeyHandle)?
    private var cachedSecureEnclaveMLDSAIdentities: [
        ProtocolSigningAlgorithm: SecureEnclaveMLDSAIdentityMaterial
    ] = [:]
    
    /// 设备 ID
    private var _deviceId: String?

    /// Tests use a namespaced in-memory slot so race and migration fixtures do
    /// not mutate the process-wide production singleton's cached identity.
    private let testingStorageNamespace: String?
    private let sharedIdentityScopeSource: SkyBridgeSharedIdentityScopeSource
    
 // MARK: - Initialization
    
    private init() {
        testingStorageNamespace = nil
        sharedIdentityScopeSource = .requiredEntitlement
    }

    #if DEBUG || SKYBRIDGE_TESTING
    internal init(
        testingStorageNamespace: String,
        keychainScope: KeychainGenericPasswordScope
    ) throws {
        guard !testingStorageNamespace.isEmpty else {
            throw DeviceIdentityTestingConfigurationError.emptyStorageNamespace
        }
        self.testingStorageNamespace = testingStorageNamespace
        self.sharedIdentityScopeSource = .explicitForTesting(keychainScope)
    }
    #endif

    private var mldsaStorageService: String {
        guard let testingStorageNamespace else {
            return KeychainConstants.mldsaService
        }
        return KeychainConstants.mldsaService + ".testing." + testingStorageNamespace
    }

    private var kemStorageService: String {
        guard let testingStorageNamespace else {
            return KeychainConstants.kemService
        }
        return KeychainConstants.kemService + ".testing." + testingStorageNamespace
    }

    private var mldsaMirrorDefaultsKey: String {
        guard let testingStorageNamespace else {
            return KeychainConstants.mirroredMLDSAPublicKeyDefaultsKey
        }
        return KeychainConstants.mirroredMLDSAPublicKeyDefaultsKey + ".testing." + testingStorageNamespace
    }

    private var mldsaStoreIdentity: String {
        guard let testingStorageNamespace else {
            return "device-protocol-signing"
        }
        return "device-protocol-signing.testing.\(testingStorageNamespace)"
    }

    private var mldsaAuthorityDomain: PQCBackendAuthorityDomain {
        guard let testingStorageNamespace else { return .protocolIdentity }
        return .testing("device-protocol-signing.\(testingStorageNamespace)")
    }

    private var mldsa87StoreIdentity: String {
        guard let testingStorageNamespace else {
            return "device-protocol-signing-mldsa87"
        }
        return "device-protocol-signing-mldsa87.testing.\(testingStorageNamespace)"
    }

    private var secureEnclaveMLDSAService: String {
        guard let testingStorageNamespace else {
            return KeychainConstants.secureEnclaveMLDSAService
        }
        return KeychainConstants.secureEnclaveMLDSAService
            + ".testing."
            + testingStorageNamespace
    }

    private var mldsaStoreDescriptor: PQCKeyPairStoreDescriptor {
        PQCKeyPairStoreDescriptor(
            backend: .liboqs,
            purpose: .signature,
            algorithm: KeychainConstants.mldsaAlgorithmIdentifier,
            identity: mldsaStoreIdentity,
            authority: .active,
            authorityDomain: mldsaAuthorityDomain,
            storageScope: PQCKeyPairStoreStorageScope(
                canonicalLocation: KeychainGenericPasswordLocation(
                    service: mldsaStorageService,
                    account: KeychainConstants.mldsaCanonicalKeyPairAccount
                ),
                keychainScopeSource: effectiveSharedIdentityScopeSource,
                includeLegacyKeychain: true
            ),
            recordAlgorithmIdentifier: KeychainConstants.mldsaAlgorithmIdentifier
        )
    }

    private var mldsaLegacyKeyPair: PQCKeyPairStoreLegacyKeyPair {
        PQCKeyPairStoreLegacyKeyPair(
            publicKeyLocation: KeychainGenericPasswordLocation(
                service: mldsaStorageService,
                account: KeychainConstants.mldsaPublicKeyAccount
            ),
            privateKeyLocation: KeychainGenericPasswordLocation(
                service: mldsaStorageService,
                account: KeychainConstants.mldsaSecretKeyAccount
            ),
            keychainScopeSource: effectiveSharedIdentityScopeSource,
            includeLegacyKeychain: true
        )
    }
    
 // MARK: - Public Methods
    
 /// 获取或创建设备身份密钥
 /// - Returns: 密钥信息
    public func getOrCreateIdentityKey() async throws -> DeviceIdentityKeyInfo {
        // The P-256 device authority is add-only and immutable for the lifetime of
        // an installation (`deleteIdentityKey` refuses to remove it), so a resolved
        // authority is valid for the whole process. Re-resolving it per call forced
        // every discovery batch, presence heartbeat and advertisement to replay the
        // full Keychain + legacy-domain migration scan, which is what produced the
        // repeating macOS Keychain authorization panels.
        if let cached = cachedKeyInfo {
            return cached
        }
        
        do {
            if let existing = try await loadExistingKey(
                legacyMigrationPolicy: .allow
            ) {
                cachedKeyInfo = existing
                return existing
            }
        } catch {
            let publicError = Self.publicIdentityError(for: error)
            let diagnosticCode = Self.identityDiagnosticCode(for: publicError)
            SkyBridgeLogger.p2p.error(
                "Device identity load failed; code=\(diagnosticCode, privacy: .public)"
            )
            throw publicError
        }
        
        do {
            let keyInfo = try await createNewIdentityKey()
            cachedKeyInfo = keyInfo
            return keyInfo
        } catch {
            throw Self.publicIdentityError(for: error)
        }
    }

    /// Returns the device ID bound to the immutable P-256 identity authority.
    ///
    /// This compatibility spelling remains throwing so callers cannot turn a
    /// missing, corrupt, or conflicting authority into an empty identity.
    public func getDeviceId() async throws -> String {
        try await getOrCreateDeviceIdStrict()
    }

    public func getOrCreateDeviceIdStrict() async throws -> String {
        if Self.useInMemoryKeychain, let deviceId = _deviceId {
            return deviceId
        }

        if Self.useInMemoryKeychain {
            if let stored = try loadStoredDeviceIdStrict() {
                _deviceId = stored
                return stored
            }
            let newId = UUID().uuidString
            try saveDeviceIdStrict(newId)
            _deviceId = newId
            return newId
        }

        // A device ID is one field of the immutable P-256 identity authority.
        // Persisting it independently would let app/extension first creation
        // publish different logical identities.
        return try await getOrCreateIdentityKey().deviceId
    }

    /// Loads the existing identity authority without creating one.
    ///
    /// `nil` means the authority is genuinely absent. Storage, validation, and
    /// migration failures remain typed errors and are never collapsed into
    /// absence.
    public func existingIdentityKeyInfoStrict() async throws -> DeviceIdentityKeyInfo? {
        // Same immutability argument as `getOrCreateIdentityKey`: a cache hit is a
        // previously validated authority, never a substitute for a missing one.
        // A miss still performs the strict Keychain resolution and can return nil.
        if let cachedKeyInfo {
            return cachedKeyInfo
        }
        do {
            guard let existing = try await loadExistingKey(
                legacyMigrationPolicy: .rejectMutation
            ) else { return nil }
            cachedKeyInfo = existing
            _deviceId = existing.deviceId
            return existing
        } catch {
            throw Self.publicIdentityError(for: error)
        }
    }

    /// Returns the residue-inspection health captured when the current process
    /// resolved or created its immutable authority. This accessor performs no
    /// Keychain I/O and never triggers migration or identity creation.
    @_spi(SkyBridgeSmokeDiagnostics)
    public func lastLegacyResidueInspectionStatus()
        -> DeviceIdentityLegacyResidueInspectionStatus? {
        cachedLegacyResidueInspectionStatus
    }

    /// Performs a read-only, count-only audit using the same signed Keychain
    /// scope and legacy enumeration as normal identity startup. This method
    /// never reconciles, deletes, migrates, creates, or caches identity state.
    @_spi(SkyBridgeSmokeDiagnostics)
    public func legacyIdentityAuditReport() throws -> DeviceIdentityLegacyAuditReport {
        let store = try identityAuthorityStore()
        let initialAuthority = try DeviceIdentityAuthorityTransaction.resolve(
            using: store
        )
        do {
            var legacy = try discoverStableLegacyIdentity(using: store)
            defer { legacy.secureEraseEncodedItems() }
            let verifiedAuthority = try DeviceIdentityAuthorityTransaction.resolve(
                using: store
            )
            guard initialAuthority == verifiedAuthority else {
                throw DeviceIdentityAuthorityError
                    .legacyIdentityChangedDuringAudit
            }
            let reconciliation: DeviceIdentityLegacyReconciliationAudit?
            if let authority = verifiedAuthority {
                do {
                    reconciliation = try DeviceIdentityLegacyReconciliation.audit(
                        legacy.state,
                        against: authority
                    )
                } catch DeviceIdentityAuthorityError.legacyIdentityIncomplete(_) {
                    throw LegacyResidueInspectionError(reason: .malformedKeyInfo)
                }
            } else {
                reconciliation = try DeviceIdentityLegacyReconciliation
                    .auditCoherenceWithoutAuthority(legacy.state)
            }
            return try makeLegacyIdentityAuditReport(
                legacy: legacy,
                authority: verifiedAuthority,
                reconciliation: reconciliation,
                authoritativeAccessGroup: store.authoritativeScope.writeAccessGroup
            )
        } catch let inspectionError as LegacyResidueInspectionError {
            let verifiedAuthority = try DeviceIdentityAuthorityTransaction.resolve(
                using: store
            )
            guard initialAuthority == verifiedAuthority else {
                throw DeviceIdentityAuthorityError
                    .legacyIdentityChangedDuringAudit
            }
            guard verifiedAuthority != nil else {
                // Without a validated authority, uncertainty about legacy data
                // remains fatal so it cannot be mistaken for identity absence.
                throw inspectionError
            }
            return DeviceIdentityLegacyAuditReport(
                schemaVersion: 2,
                state: .inspectionUnavailable,
                authorityPresent: true,
                authorityKeyValidated: true,
                comparisonBasis: .sharedAuthority,
                stableAcrossReads: false,
                inspectionStatus: .unavailable(inspectionError.reason),
                namespaces: []
            )
        }
    }

    /// Loads the device ID from an existing identity authority without creating
    /// identity material.
    public func existingDeviceIdStrict() async throws -> String? {
        try await existingIdentityKeyInfoStrict()?.deviceId
    }
    
 /// 使用身份密钥签名
 /// - Parameter data: 待签名数据
 /// - Returns: 签名
    public func sign(data: Data) async throws -> Data {
        let keyInfo = try await getOrCreateIdentityKey()

        if Self.useInMemoryKeychain {
            guard let privateKeyData = Self.inMemoryGet(KeychainConstants.inMemorySigningPrivateKey) else {
                throw DeviceIdentityKeyError.keyNotFound
            }
            do {
                let privateKey = try P256.Signing.PrivateKey(rawRepresentation: privateKeyData)
                let signature = try privateKey.signature(for: SHA256.hash(data: data))
                SkyBridgeLogger.p2p.debug("Signed data with in-memory identity key: \(keyInfo.shortId)")
                return signature.derRepresentation
            } catch {
                throw DeviceIdentityKeyError.invalidKeyData
            }
        }
        
 // 从 Keychain 获取私钥引用
        guard let privateKeyRef = try getPrivateKeyReference() else {
            throw DeviceIdentityKeyError.keyNotFound
        }
        
 // 执行签名
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKeyRef,
            .ecdsaSignatureMessageX962SHA256,
            data as CFData,
            &error
        ) else {
            let errorDesc = error?.takeRetainedValue().localizedDescription ?? "Unknown error"
            throw DeviceIdentityKeyError.signatureFailed(errorDesc)
        }
        
        SkyBridgeLogger.p2p.debug("Signed data with identity key: \(keyInfo.shortId)")
        return signature as Data
    }

    /// Prewarm identity material used by local P2P / current-path pairing so the first real connection
    /// does not block on first-touch keychain / key generation work.
    public func prewarmConnectionIdentityMaterials() async {
        do {
            _ = try await getOrCreateIdentityKey()
        } catch {
            let diagnosticCode = Self.identityDiagnosticCode(for: error)
            SkyBridgeLogger.p2p.warning(
                "Prewarm identity key failed; code=\(diagnosticCode, privacy: .public)"
            )
        }

        do {
            _ = try await getOrCreateProtocolSigningKey()
        } catch {
            SkyBridgeLogger.p2p.warning(
                "Prewarm protocol signing key failed; code=protocol-signing-key-unavailable"
            )
        }

        let provider = CryptoProviderFactory.make(policy: .preferPQC)
        do {
            _ = try await pairingIdentityKEMPublicKeys(using: provider)
        } catch {
            SkyBridgeLogger.p2p.warning(
                "Prewarm pairing KEM identity keys failed; code=pairing-kem-identity-unavailable"
            )
        }
    }
    
 /// 获取身份密钥句柄（Keychain/Secure Enclave）
    public func getSigningKeyHandle() async throws -> SigningKeyHandle {
        _ = try await getOrCreateIdentityKey()
        guard let privateKeyRef = try getPrivateKeyReference() else {
            throw DeviceIdentityKeyError.keyNotFound
        }
        return .secureEnclaveRef(privateKeyRef)
    }

 /// 获取 Secure Enclave 签名回调（不暴露私钥）
    public func getSigningCallback() async throws -> SigningCallback {
        _ = try await getOrCreateIdentityKey()
        return DeviceIdentityManagerSigningCallback(manager: self)
    }
    
 // MARK: - Protocol Signing Key (Ed25519) - 5.1
    
 /// 获取或创建 Ed25519 协议签名密钥
 ///
 /// 用于 sigA/sigB 主协议签名（Classic suite）。
 /// 存储在 Keychain（非 Secure Enclave，因为 SE 不支持 Ed25519）。
 ///
 /// **Requirements: 2.1, 2.2, 2.4**
    public func getOrCreateProtocolSigningKey() async throws -> (publicKey: Data, keyHandle: SigningKeyHandle) {
 // 检查缓存
        if let cached = cachedProtocolSigningKey {
            return (publicKey: cached.publicKey, keyHandle: .softwareKey(cached.privateKey))
        }
        
 // 尝试从 Keychain 加载
        if let existing = try loadProtocolSigningKey() {
            cachedProtocolSigningKey = existing
            return (publicKey: existing.publicKey, keyHandle: .softwareKey(existing.privateKey))
        }
        
 // 创建新密钥
        let keyPair = try createProtocolSigningKey()
        cachedProtocolSigningKey = keyPair
        return (publicKey: keyPair.publicKey, keyHandle: .softwareKey(keyPair.privateKey))
    }
    
 /// 获取协议签名密钥句柄 (Ed25519)
 ///
 /// 用于 sigA/sigB 主协议签名。
 ///
 /// **Requirements: 2.4**
    public func getProtocolSigningKeyHandle() async throws -> SigningKeyHandle {
        let (_, keyHandle) = try await getOrCreateProtocolSigningKey()
        return keyHandle
    }
    
 /// 获取协议签名公钥 (Ed25519)
    public func getProtocolSigningPublicKey() async throws -> Data {
        let (publicKey, _) = try await getOrCreateProtocolSigningKey()
        return publicKey
    }
    
 // MARK: - Protocol Signing Key by Algorithm ( 11.1)
    
 /// 根据协议签名算法获取密钥句柄
 ///
 /// ** 11.1**: 统一入口，根据算法类型返回对应的密钥句柄
 /// - ed25519：沿用现有 rawRepresentation 存储
 /// - mlDSA65：OQS keypair 生成 + Keychain 存储
 ///
 /// **Requirements: 8.1, 8.6**
    public func getProtocolSigningKeyHandle(
        for algorithm: ProtocolSigningAlgorithm
    ) async throws -> SigningKeyHandle {
        try await getProtocolSigningIdentity(
            for: algorithm,
            protection: .softwareKeychain
        ).keyHandle
    }

    /// Resolves the main-protocol signing identity under an explicit key
    /// protection policy. The policy is part of the identity authority; a
    /// Secure Enclave request never falls back to software.
    public func getProtocolSigningIdentity(
        for algorithm: ProtocolSigningAlgorithm,
        protection: ProtocolSigningKeyProtection
    ) async throws -> (publicKey: Data, keyHandle: SigningKeyHandle) {
        if protection == .secureEnclaveRequired {
            return try await getOrCreateSecureEnclaveMLDSAIdentity(for: algorithm)
        }
        switch algorithm {
        case .ed25519:
            let publicKey = try await getProtocolSigningPublicKey()
            let keyHandle = try await getProtocolSigningKeyHandle()
            return (publicKey, keyHandle)
        case .mlDSA65:
            return try await getOrCreateMLDSASigningKey()
        case .mlDSA87:
            return try await getOrCreateMLDSA87SigningIdentity()
        }
    }
    
 /// 根据协议签名算法获取公钥
 ///
 /// ** 11.1**: 统一入口，根据算法类型返回对应的公钥
 ///
 /// **Requirements: 8.1**
    public func getProtocolSigningPublicKey(
        for algorithm: ProtocolSigningAlgorithm
    ) async throws -> Data {
        try await getProtocolSigningIdentity(
            for: algorithm,
            protection: .softwareKeychain
        ).publicKey
    }

    public func getProtocolSigningPublicKey(
        for algorithm: ProtocolSigningAlgorithm,
        protection: ProtocolSigningKeyProtection
    ) async throws -> Data {
        try await getProtocolSigningIdentity(
            for: algorithm,
            protection: protection
        ).publicKey
    }

    /// Loads one exact `(algorithm, protection)` authority without creating or
    /// switching key material. Software and Secure Enclave identities occupy
    /// independent immutable slots and may coexist during peer re-pinning.
    public func existingProtocolSigningPublicKey(
        for algorithm: ProtocolSigningAlgorithm,
        protection: ProtocolSigningKeyProtection
    ) async throws -> Data? {
        switch protection {
        case .secureEnclaveRequired:
            return try loadSecureEnclaveMLDSARecord(for: algorithm)?.publicKey
        case .softwareKeychain:
            switch algorithm {
            case .ed25519:
                guard let existing = try loadProtocolSigningKey() else { return nil }
                cachedProtocolSigningKey = existing
                return existing.publicKey
            case .mlDSA65:
                guard let existing = try loadMLDSASigningKey() else { return nil }
                cachedMLDSASigningKey = existing
                return existing.publicKey
            case .mlDSA87:
                let persistedPublicKey = try OQSBridge.existingSigningPublicKey(
                    peerId: mldsa87StoreIdentity,
                    algorithm: .mldsa87,
                    authority: .active,
                    scopeSource: effectiveSharedIdentityScopeSource
                )
                guard let persistedPublicKey else { return nil }
                if let cachedMLDSA87SigningIdentity,
                   cachedMLDSA87SigningIdentity.publicKey != persistedPublicKey {
                    throw DeviceIdentityKeyError.authorityConflict(
                        "Cached ML-DSA-87 identity disagrees with its persisted authority"
                    )
                }
                return persistedPublicKey
            }
        }
    }

    /// Loads the complete signer from one exact committed authority slot.
    /// Unlike `getProtocolSigningIdentity`, this never provisions a missing key.
    public func existingProtocolSigningIdentity(
        for algorithm: ProtocolSigningAlgorithm,
        protection: ProtocolSigningKeyProtection
    ) async throws -> (publicKey: Data, keyHandle: SigningKeyHandle)? {
        switch protection {
        case .secureEnclaveRequired:
            guard let record = try loadSecureEnclaveMLDSARecord(for: algorithm) else {
                return nil
            }
            let material = try await restoreSecureEnclaveMLDSARecord(record)
            cachedSecureEnclaveMLDSAIdentities[algorithm] = material
            return (material.publicKey, .callback(material.signingCallback))

        case .softwareKeychain:
            switch algorithm {
            case .ed25519:
                guard let existing = try loadProtocolSigningKey() else { return nil }
                cachedProtocolSigningKey = existing
                return (existing.publicKey, .softwareKey(existing.privateKey))
            case .mlDSA65:
                guard let existing = try loadMLDSASigningKey() else { return nil }
                cachedMLDSASigningKey = existing
                return (existing.publicKey, .softwareKey(existing.privateKey))
            case .mlDSA87:
                guard let persistedPublicKey = try OQSBridge.existingSigningPublicKey(
                    peerId: mldsa87StoreIdentity,
                    algorithm: .mldsa87,
                    authority: .active,
                    scopeSource: effectiveSharedIdentityScopeSource
                ) else {
                    return nil
                }
                let resolved = try await OQSProtocolMLDSASigningCallback.resolve(
                    algorithm: .mlDSA87,
                    identity: mldsa87StoreIdentity,
                    scopeSource: effectiveSharedIdentityScopeSource
                )
                guard resolved.publicKey == persistedPublicKey else {
                    throw DeviceIdentityKeyError.authorityConflict(
                        "Resolved ML-DSA-87 signer disagrees with its persisted authority"
                    )
                }
                cachedMLDSA87SigningIdentity = resolved
                return resolved
            }
        }
    }
    
 // MARK: - SE PoP Key (P-256) - 5.2
    
 /// 获取 Secure Enclave PoP 密钥句柄 (P-256)
 ///
 /// 用于可选的 seSigA/seSigB Proof-of-Possession 签名。
 /// 如果 Secure Enclave 不可用，返回 nil。
 ///
 /// **Requirements: 2.3, 2.5**
    public func getSecureEnclaveKeyHandle() async throws -> SigningKeyHandle? {
        guard shouldUseSecureEnclaveForSigning() else {
            SkyBridgeLogger.p2p.info("Secure Enclave signing disabled by settings, using software fallback path")
            return nil
        }

        _ = try await getOrCreateIdentityKey()
        guard let secKey = try getSEPoPKeyReference() else { return nil }
        return .secureEnclaveRef(secKey)
    }
    
 /// 获取 Secure Enclave PoP 公钥 (P-256)
    public func getSecureEnclavePublicKey() async throws -> Data? {
        guard shouldUseSecureEnclaveForSigning() else { return nil }
        _ = try await getOrCreateIdentityKey()
        do {
            let store = try identityAuthorityStore()
            guard let authority = try DeviceIdentityAuthorityTransaction.resolve(
                using: store
            ), authority.isSecureEnclave else {
                return nil
            }
            return authority.publicKey
        } catch {
            throw Self.publicIdentityError(for: error)
        }
    }
    
 // MARK: - Key Migration - 5.3
    
    /// Migrates an exportable legacy fixed-tag P-256 identity into the shared
    /// immutable identity authority.
    ///
    /// The legacy key is copied under a unique shared-group tag before the
    /// add-only authority claim is attempted. Secure Enclave or otherwise
    /// unexportable legacy identities require explicit rotation and peer
    /// re-pinning. Repeated calls resolve the same authority winner.
    ///
    /// **Requirements: 5.4**
    public func migrateExistingIdentityKey() async throws {
        // Tests run with SKYBRIDGE_KEYCHAIN_IN_MEMORY=1 to avoid touching the system Keychain.
        // In this mode, identity-key migration is a no-op by design.
        if Self.useInMemoryKeychain { return }

        // Loading performs the only supported legacy transition: an exportable
        // software fixed-tag identity is copied under a unique shared tag and
        // then elected through the add-only authority CAS. Legacy Secure
        // Enclave material throws an explicit rotation/re-pin error.
        do {
            _ = try await loadExistingKey(legacyMigrationPolicy: .allow)
        } catch {
            throw Self.publicIdentityError(for: error)
        }
    }
    
 /// 识别密钥用途
 ///
 /// - Parameter tag: 密钥 tag
 /// - Returns: 密钥用途
    public func identifyKeyPurpose(tag: String) -> KeyPurpose {
        if tag.hasPrefix(DeviceIdentityAuthorityRecord.privateKeyTagPrefix) {
            return .identity
        }
        switch tag {
        case KeychainConstants.signingKeyTag:
            return .legacy  // 旧 P-256 身份密钥（迁移前）
        case KeychainConstants.protocolSigningKeyTag:
            return .protocol  // Ed25519 协议签名密钥
        case KeychainConstants.sePoPKeyTag:
            return .pop  // P-256 SE PoP 密钥（迁移后）
        default:
            return .unknown
        }
    }

 /// 获取或创建 KEM 身份密钥（用于 PQC 套件）
    public func getOrCreateKEMIdentityKey(
        for suite: CryptoSuite,
        provider: any CryptoProvider
    ) async throws -> (publicKey: Data, privateKey: SecureBytes) {
        let storageSuite = suite.canonicalKEMSuite
        guard provider.supportsSuite(storageSuite) else {
            throw CryptoProviderError.unsupportedAlgorithm(
                "\(provider.providerName) does not support \(storageSuite.rawValue)"
            )
        }
        let cacheKey = KEMCacheKey(suiteWireId: storageSuite.wireId, tier: provider.tier)
        if cachedKEMPublicKeys[cacheKey] != nil {
            if let record = try loadKEMKeyRecord(suiteWireId: storageSuite.wireId, tier: provider.tier) {
                cachedKEMPublicKeys[cacheKey] = record.publicKey
                return (publicKey: record.publicKey, privateKey: SecureBytes(data: record.privateKey))
            }
            cachedKEMPublicKeys.removeValue(forKey: cacheKey)
        }
        
        if let record = try loadKEMKeyRecord(suiteWireId: storageSuite.wireId, tier: provider.tier) {
            cachedKEMPublicKeys[cacheKey] = record.publicKey
            return (publicKey: record.publicKey, privateKey: SecureBytes(data: record.privateKey))
        }
        
        let keyPair = try await provider.generateKeyPair(for: .keyExchange)
        guard keyPair.publicKey.usage == .keyExchange else {
            throw CryptoProviderError.keyUsageMismatch(
                expected: .keyExchange,
                actual: keyPair.publicKey.usage
            )
        }
        guard keyPair.privateKey.usage == .keyExchange else {
            throw CryptoProviderError.keyUsageMismatch(
                expected: .keyExchange,
                actual: keyPair.privateKey.usage
            )
        }
        guard keyPair.publicKey.suite.canonicalKEMSuite.wireId == storageSuite.wireId,
              keyPair.privateKey.suite.canonicalKEMSuite.wireId == storageSuite.wireId else {
            throw CryptoProviderError.unsupportedAlgorithm(
                "\(provider.providerName) generated key material for a different KEM suite"
            )
        }
        let record = KEMIdentityKeyRecord(
            suiteWireId: storageSuite.wireId,
            publicKey: keyPair.publicKey.bytes,
            privateKey: keyPair.privateKey.bytes
        )
        try validateKEMRecord(record, suiteWireId: storageSuite.wireId, tier: provider.tier)
        let winner = try saveKEMKeyRecord(
            record,
            tier: provider.tier,
            conflictPolicy: .adoptWinner
        )
        cachedKEMPublicKeys[cacheKey] = winner.publicKey
        return (
            publicKey: winner.publicKey,
            privateKey: SecureBytes(data: winner.privateKey)
        )
    }
    
 /// 获取 KEM 身份公钥（不存在则创建）
    public func getKEMPublicKey(
        for suite: CryptoSuite,
        provider: any CryptoProvider
    ) async throws -> Data {
        let record = try await getOrCreateKEMIdentityKey(for: suite, provider: provider)
        return record.publicKey
    }

    public nonisolated static func pairingIdentityAdvertisedPQCSuites(
        using provider: any CryptoProvider
    ) -> [CryptoSuite] {
        pairingIdentityAdvertisedPQCSuites(
            using: provider,
            appleXWingAvailable: isAppleXWingAvailable(),
            qPeriaptEnabled: false,
            activeProtocolSigningAlgorithm: nil
        )
    }

    public nonisolated static func pairingIdentityAdvertisedPQCSuites(
        using provider: any CryptoProvider,
        activeProtocolSigningAlgorithm: ProtocolSigningAlgorithm,
        qPeriaptEnabled: Bool
    ) -> [CryptoSuite] {
        pairingIdentityAdvertisedPQCSuites(
            using: provider,
            appleXWingAvailable: isAppleXWingAvailable(),
            qPeriaptEnabled: qPeriaptEnabled,
            activeProtocolSigningAlgorithm: activeProtocolSigningAlgorithm
        )
    }

    public nonisolated static func pairingIdentityAdvertisedPQCSuites(
        using provider: any CryptoProvider,
        appleXWingAvailable: Bool,
        qPeriaptEnabled: Bool = false,
        activeProtocolSigningAlgorithm: ProtocolSigningAlgorithm? = nil
    ) -> [CryptoSuite] {
        // Q-Periapt has an additional authenticated-runtime admission gate. Do
        // not let a provider's broad capability list bypass that product gate.
        var suites = provider.supportedSuites.filter {
            $0.isPQCGroup
                && $0.isNegotiable
                && $0.wireId != CryptoSuite.qperiaptABI2PolicyBound.wireId
        }

        if qPeriaptEnabled, activeProtocolSigningAlgorithm == .mlDSA65 {
            suites.append(.qperiaptABI2PolicyBound)
        }

        if provider.tier == .nativePQC {
            if appleXWingAvailable {
                suites.append(.xwingMLDSA)
            }
            suites.append(.mlkem768MLDSA65)
            suites.append(.mlkem768MLDSA65FS)
        }

        let dedupedByWire = suites.reduce(into: [UInt16: CryptoSuite]()) { partialResult, suite in
            partialResult[suite.wireId] = suite
        }
        return dedupedByWire.values.sorted { $0.wireId < $1.wireId }
    }

    private nonisolated static func isAppleXWingAvailable() -> Bool {
        #if HAS_APPLE_PQC_SDK
        if #available(macOS 26.0, iOS 26.0, *) {
            return AppleXWingCryptoProvider.selfTest()
        }
        #endif
        return false
    }

    public func pairingIdentityKEMPublicKeys(
        using provider: any CryptoProvider,
        limitingTo requestedSuites: [CryptoSuite]? = nil
    ) async throws -> [KEMPublicKeyInfo] {
        let activeIdentity = try await CommittedLocalProtocolIdentitySnapshot.loadActive(
            keyManager: self
        )
        let frozenQPeriaptProvider: QPeriaptCryptoProvider?
        if activeIdentity.algorithm == .mlDSA65,
           QPeriaptPlatformPolicy.isEnabledForLocalRuntime() {
            frozenQPeriaptProvider = QPeriaptPlatformPolicy.makeCryptoProvider()
        } else {
            frozenQPeriaptProvider = nil
        }
        var suites = Self.pairingIdentityAdvertisedPQCSuites(
            using: provider,
            activeProtocolSigningAlgorithm: activeIdentity.algorithm,
            qPeriaptEnabled: frozenQPeriaptProvider != nil
        )
        if let requestedSuites {
            let requestedWireIds = Set(requestedSuites.map(\.wireId))
            suites = suites.filter { requestedWireIds.contains($0.wireId) }
        }
        guard !suites.isEmpty else { return [] }

        var requiredWireIds = Set(
            provider.supportedSuites
                .filter { $0.isPQCGroup && $0.isNegotiable }
                .map(\.wireId)
        )
        if frozenQPeriaptProvider != nil,
           suites.contains(where: {
               $0.wireId == CryptoSuite.qperiaptABI2PolicyBound.wireId
           }) {
            requiredWireIds.insert(CryptoSuite.qperiaptABI2PolicyBound.wireId)
        }
        var kemKeys: [KEMPublicKeyInfo] = []
        kemKeys.reserveCapacity(suites.count)

        for suite in suites {
            let suiteProvider = try Self.pairingIdentityProvider(
                for: suite,
                baseProvider: provider,
                qPeriaptProvider: frozenQPeriaptProvider
            )
            do {
                let publicKey = try await getKEMPublicKey(for: suite, provider: suiteProvider)
                kemKeys.append(KEMPublicKeyInfo(suiteWireId: suite.wireId, publicKey: publicKey))
            } catch {
                if requiredWireIds.contains(suite.wireId) {
                    throw error
                }
                SkyBridgeLogger.p2p.warning(
                    "Optional pairing identity KEM public key is unavailable; suite=\(suite.rawValue, privacy: .public) code=optional-kem-identity-unavailable"
                )
            }
        }

        return kemKeys
    }

    private nonisolated static func pairingIdentityProvider(
        for suite: CryptoSuite,
        baseProvider: any CryptoProvider,
        qPeriaptProvider: QPeriaptCryptoProvider?
    ) throws -> any CryptoProvider {
        if suite == .qperiaptABI2PolicyBound {
            guard let qPeriaptProvider else {
                throw CryptoProviderError.providerNotAvailable(.qPeriapt)
            }
            return qPeriaptProvider
        }

        #if HAS_APPLE_PQC_SDK
        if baseProvider.tier == .nativePQC {
            if #available(iOS 26.0, macOS 26.0, *) {
                if suite == .xwingMLDSA {
                    return AppleXWingCryptoProvider()
                }
                if suite.isPQCGroup {
                    return ApplePQCCryptoProvider()
                }
            }
        }
        #endif
        return baseProvider
    }
    
 /// 验证签名
 /// - Parameters:
 /// - data: 原始数据
 /// - signature: 签名
 /// - publicKey: 公钥（DER 编码）
 /// - Returns: 是否验证通过
    public func verify(data: Data, signature: Data, publicKey: Data) async throws -> Bool {
 // 从 DER 数据创建公钥
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic
        ]
        
        var error: Unmanaged<CFError>?
        guard let publicKeyRef = SecKeyCreateWithData(
            publicKey as CFData,
            attributes as CFDictionary,
            &error
        ) else {
            throw DeviceIdentityKeyError.invalidKeyData
        }
        
 // 验证签名
        let isValid = SecKeyVerifySignature(
            publicKeyRef,
            .ecdsaSignatureMessageX962SHA256,
            data as CFData,
            signature as CFData,
            &error
        )
        
        return isValid
    }
    
 /// 检查 Secure Enclave 是否可用
    public func isSecureEnclaveAvailable() -> Bool {
        #if targetEnvironment(simulator)
        return false
        #else
 // 检查设备是否支持 Secure Enclave
 // 通过尝试创建 SecAccessControl 来验证
        var error: Unmanaged<CFError>?
        let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .privateKeyUsage,
            &error
        )
        
        return access != nil && error == nil
        #endif
    }

    
 /// 轮换密钥
 /// - Returns: 新的密钥信息
    public func rotateKey() async throws -> DeviceIdentityKeyInfo {
        // Replacing the add-only cross-process authority requires a durable
        // staged cutover plus explicit peer re-pinning. Deleting the old claim
        // before publishing a replacement creates a crash window with no
        // identity authority, so the current release refuses that unsafe path.
        throw DeviceIdentityKeyError.keyRotationFailed(
            "Cross-process identity rotation requires an explicit staged cutover and peer re-pinning; the existing authority was preserved"
        )
    }
    
 /// 删除身份密钥
    public func deleteIdentityKey() throws {
        throw DeviceIdentityKeyError.keyRotationFailed(
            "Deleting the immutable cross-process identity requires an explicit reset transaction, peer trust removal, and re-pinning; the existing authority was preserved"
        )
    }
    
 // MARK: - Private Methods
    
    /// 创建新的身份密钥
    private func createNewIdentityKey() async throws -> DeviceIdentityKeyInfo {
        if Self.useInMemoryKeychain {
            let deviceId = try await getOrCreateDeviceIdStrict()
            let privateKey = P256.Signing.PrivateKey()
            let publicKeyData = privateKey.publicKey.x963Representation
            Self.inMemorySet(privateKey.rawRepresentation, for: KeychainConstants.inMemorySigningPrivateKey)
            let keyInfo = DeviceIdentityKeyInfo(
                deviceId: deviceId,
                pubKeyFP: computePublicKeyFingerprint(publicKeyData),
                publicKey: publicKeyData,
                keyType: .p256Signing,
                isSecureEnclave: false
            )
            try saveKeyInfo(keyInfo)
            cachedLegacyResidueInspectionStatus = .complete(hasConflicts: false)
            SkyBridgeLogger.p2p.info("Created new in-memory device identity key: \(keyInfo.shortId)")
            return keyInfo
        }

        let store = try identityAuthorityStore()
        let deviceId = UUID().uuidString
        let preferSecureEnclave = shouldUseSecureEnclaveForSigning()
        var useSecureEnclave = preferSecureEnclave && isSecureEnclaveAvailable()
        if preferSecureEnclave && !useSecureEnclave {
            SkyBridgeLogger.p2p.warning("Secure Enclave signing requested but unavailable, falling back to software key")
        }
        if !preferSecureEnclave {
            SkyBridgeLogger.p2p.info("Secure Enclave signing disabled by settings, generating software key")
        }

        var candidateTag = DeviceIdentityAuthorityRecord.uniquePrivateKeyApplicationTag()
        let privateKey: SecKey
        do {
            privateKey = try store.createRandomPrivateKey(
                applicationTag: candidateTag,
                useSecureEnclave: useSecureEnclave
            )
        } catch {
            if useSecureEnclave, shouldFallbackIdentityKeyToSoftware(error: error) {
                SkyBridgeLogger.p2p.warning(
                    "⚠️ Identity key Secure Enclave creation failed (likely missing entitlement); falling back to software keychain key."
                )
                try store.deletePrivateKey(applicationTag: candidateTag)
                useSecureEnclave = false
                candidateTag = DeviceIdentityAuthorityRecord.uniquePrivateKeyApplicationTag()
                privateKey = try store.createRandomPrivateKey(
                    applicationTag: candidateTag,
                    useSecureEnclave: false
                )
            } else {
                throw error
            }
        }

        _ = privateKey
        let metadata: DeviceIdentityPrivateKeyMetadata?
        do {
            metadata = try store.privateKeyMetadata(
                forPrivateKeyApplicationTag: candidateTag
            )
        } catch {
            try store.deletePrivateKey(applicationTag: candidateTag)
            throw error
        }
        guard let metadata else {
            try store.deletePrivateKey(applicationTag: candidateTag)
            throw DeviceIdentityAuthorityError.authorityWinnerKeyMissing(candidateTag)
        }
        let candidate = DeviceIdentityAuthorityRecord(
            deviceId: deviceId,
            publicKey: metadata.publicKey,
            publicKeyFingerprint: DeviceIdentityAuthorityRecord.fingerprint(
                for: metadata.publicKey
            ),
            privateKeyApplicationTag: candidateTag,
            isSecureEnclave: metadata.isSecureEnclave,
            createdAt: Date()
        )
        let winner = try DeviceIdentityAuthorityTransaction.claimCandidate(
            candidate,
            using: store
        )
        // A legacy writer may have appeared after the initial empty scan. The
        // post-claim stable inspection makes that split-brain residue visible
        // without allowing it to replace or delete the immutable winner.
        cachedLegacyResidueInspectionStatus = try inspectLegacyResidue(
            beside: winner,
            using: store
        )
        let keyInfo = keyInfo(from: winner)
        publishResolvedIdentity(winner)
        SkyBridgeLogger.p2p.info(
            "Created or joined device identity authority: \(keyInfo.shortId), Secure Enclave: \(winner.isSecureEnclave)"
        )
        return keyInfo
    }

    private func shouldFallbackIdentityKeyToSoftware(error: Error) -> Bool {
        guard case DeviceIdentityKeyError.secureEnclaveNotAvailable = error else {
            return false
        }
        return true
    }

    nonisolated static func publicIdentityError(
        for error: Error
    ) -> DeviceIdentityKeyError {
        if let inspectionError = error as? LegacyResidueInspectionError {
            return .corruptIdentityAuthority(
                "legacy-residue-inspection-\(inspectionError.reason.rawValue)"
            )
        }
        if let keyError = error as? DeviceIdentityKeyError {
            switch keyError {
            case .keyGenerationFailed:
                return .keyGenerationFailed("identity-key-generation-failed")
            case .incompleteKeyMaterial:
                return .incompleteKeyMaterial("identity-key-material-incomplete")
            case .signatureFailed:
                return .signatureFailed("identity-signature-failed")
            case .keyRotationFailed:
                return .keyRotationFailed("identity-rotation-requires-explicit-cutover")
            case .authorityConflict:
                return .authorityConflict("identity-authority-conflict")
            case .corruptIdentityAuthority:
                return .corruptIdentityAuthority("identity-authority-invalid")
            case .identityMigrationRequiresRotationAndRepinning:
                return .identityMigrationRequiresRotationAndRepinning(
                    "legacy-identity-not-exportable"
                )
            case .keyNotFound,
                 .keyAccessDenied,
                 .secureEnclaveNotAvailable,
                 .invalidKeyData,
                 .keychainError,
                 .verificationFailed,
                 .identityMigrationRequired:
                return keyError
            }
        }
        guard let authorityError = error as? DeviceIdentityAuthorityError else {
            return .corruptIdentityAuthority("unexpected-identity-storage-failure")
        }
        switch authorityError {
        case .legacySecureEnclaveRequiresRotationAndRepinning,
             .legacyPrivateKeyNotExportableRequiresRotationAndRepinning:
            return .identityMigrationRequiresRotationAndRepinning(
                "legacy-identity-not-exportable"
            )
        case .legacyIdentityRequiresExplicitMigration:
            return .identityMigrationRequired
        case .legacyIdentityConflictsWithAuthority,
             .legacyIdentityChangedDuringAudit,
             .immutableGenericPasswordConflict,
             .candidateKeyPublicKeyMismatch,
             .candidateCleanupFailed:
            return .authorityConflict("identity-authority-conflict")
        case .unsupportedRecordVersion,
             .invalidDeviceId,
             .invalidPublicKey,
             .publicKeyFingerprintMismatch,
             .invalidPrivateKeyApplicationTag,
             .invalidCreatedAt,
             .corruptAuthorityRecord,
             .authorityWinnerMissing,
             .authorityWinnerKeyMissing,
             .authorityWinnerPublicKeyMismatch,
             .authorityWinnerSecureEnclaveMismatch,
             .legacyIdentityIncomplete:
            return .corruptIdentityAuthority("identity-authority-invalid")
        }
    }

    nonisolated static func identityDiagnosticCode(for error: Error) -> String {
        switch publicIdentityError(for: error) {
        case .keyGenerationFailed:
            return "key-generation-failed"
        case .keyNotFound:
            return "key-not-found"
        case .keyAccessDenied:
            return "key-access-denied"
        case .secureEnclaveNotAvailable:
            return "secure-enclave-unavailable"
        case .invalidKeyData:
            return "invalid-key-data"
        case .incompleteKeyMaterial:
            return "incomplete-key-material"
        case .keychainError:
            return "keychain-error"
        case .signatureFailed:
            return "signature-failed"
        case .verificationFailed:
            return "verification-failed"
        case .keyRotationFailed:
            return "rotation-required"
        case .authorityConflict:
            return "authority-conflict"
        case .corruptIdentityAuthority:
            return "authority-corrupt"
        case .identityMigrationRequired:
            return "migration-required"
        case .identityMigrationRequiresRotationAndRepinning:
            return "migration-requires-rotation-and-repinning"
        }
    }

    private func shouldUseSecureEnclaveForSigning() -> Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "Settings.UseSecureEnclaveMLDSA") == nil {
            return true
        }
        return defaults.bool(forKey: "Settings.UseSecureEnclaveMLDSA")
    }
    
 /// 加载现有密钥
    private func loadExistingKey(
        legacyMigrationPolicy: ExistingIdentityLegacyMigrationPolicy
    ) async throws -> DeviceIdentityKeyInfo? {
        if Self.useInMemoryKeychain {
            cachedLegacyResidueInspectionStatus = .complete(hasConflicts: false)
            let key = KeychainConstants.service + "|" + "keyInfo"
            let data = Self.inMemoryGet(key)
            guard let data else { return nil }
            return try JSONDecoder().decode(DeviceIdentityKeyInfo.self, from: data)
        }

        let store = try identityAuthorityStore()
        if let authority = try DeviceIdentityAuthorityTransaction.resolve(
            using: store
        ) {
            cachedLegacyResidueInspectionStatus = try inspectLegacyResidue(
                beside: authority,
                using: store
            )
            publishResolvedIdentity(authority)
            return keyInfo(from: authority)
        }

        var legacy = try discoverStableLegacyIdentity(using: store)
        defer { legacy.secureEraseEncodedItems() }
        guard !legacy.state.isEmpty else {
            return nil
        }
        guard legacyMigrationPolicy == .allow else {
            throw DeviceIdentityAuthorityError
                .legacyIdentityRequiresExplicitMigration
        }
        let migrated = try migrateLegacyIdentity(legacy, using: store)
        cachedLegacyResidueInspectionStatus = try inspectLegacyResidue(
            beside: migrated,
            using: store
        )
        publishResolvedIdentity(migrated)
        return keyInfo(from: migrated)
    }

    /// A validated authority remains authoritative even if its obsolete legacy
    /// residue cannot be inspected. Only the dedicated, typed inspection error
    /// is converted to degraded health; unknown errors continue to fail.
    private func inspectLegacyResidue(
        beside authority: DeviceIdentityAuthorityRecord,
        using store: DeviceIdentityKeychainAuthorityStore
    ) throws -> DeviceIdentityLegacyResidueInspectionStatus {
        do {
            var legacy = try discoverStableLegacyIdentity(using: store)
            defer { legacy.secureEraseEncodedItems() }
            let resolution: DeviceIdentityAuthorityResidueResolution
            do {
                resolution = try DeviceIdentityLegacyReconciliation
                    .resolveValidatedAuthority(
                        authority,
                        retaining: legacy.state
                    )
            } catch DeviceIdentityAuthorityError.legacyIdentityIncomplete(_) {
                throw LegacyResidueInspectionError(reason: .malformedKeyInfo)
            } catch let authorityError as DeviceIdentityAuthorityError {
                guard let inspectionError = Self.legacyResidueInspectionError(
                    for: authorityError
                ) else {
                    throw authorityError
                }
                throw inspectionError
            }
            let audit = resolution.residueAudit
            if audit.hasConflicts {
                SkyBridgeLogger.p2p.error(
                    "Legacy identity residue retained beside the validated shared authority; keyInfoConflicts=\(audit.keyInfos.conflicting, privacy: .public) deviceIdConflicts=\(audit.deviceIds.conflicting, privacy: .public) privateKeyConflicts=\(audit.privateKeys.conflicting, privacy: .public)"
                )
            } else if !legacy.state.isEmpty {
                SkyBridgeLogger.p2p.info(
                    "Matching legacy identity aliases retained beside the validated shared authority"
                )
            }
            return .complete(hasConflicts: audit.hasConflicts)
        } catch let inspectionError as LegacyResidueInspectionError {
            SkyBridgeLogger.p2p.error(
                "Legacy identity residue inspection unavailable beside the validated shared authority; reason=\(inspectionError.reason.rawValue, privacy: .public)"
            )
            return .unavailable(inspectionError.reason)
        }
    }
    
 /// 获取私钥引用
    private func getPrivateKeyReference() throws -> SecKey? {
        if Self.useInMemoryKeychain { return nil }
        do {
            let store = try identityAuthorityStore()
            guard let authority = try DeviceIdentityAuthorityTransaction.resolve(
                using: store
            ) else {
                return nil
            }
            return try store.loadAuthoritativePrivateKey(
                applicationTag: authority.privateKeyApplicationTag
            )
        } catch {
            throw Self.publicIdentityError(for: error)
        }
    }
    
 /// 保存密钥信息
    private func saveKeyInfo(_ keyInfo: DeviceIdentityKeyInfo) throws {
        let data = try JSONEncoder().encode(keyInfo)

        if Self.useInMemoryKeychain {
            let key = KeychainConstants.service + "|" + "keyInfo"
            Self.inMemoryLock.lock()
            Self.inMemoryStore[key] = data
            Self.inMemoryLock.unlock()
            return
        }

        throw DeviceIdentityAuthorityError.legacyIdentityIncomplete(
            "keyInfo cannot be persisted independently of the identity authority"
        )
    }

    private func identityAuthorityStore() throws -> DeviceIdentityKeychainAuthorityStore {
        try DeviceIdentityKeychainAuthorityStore(
            keychainScope: resolvedSharedIdentityKeychainScope()
        )
    }

    private func keyInfo(
        from authority: DeviceIdentityAuthorityRecord
    ) -> DeviceIdentityKeyInfo {
        DeviceIdentityKeyInfo(
            deviceId: authority.deviceId,
            pubKeyFP: authority.publicKeyFingerprint,
            publicKey: authority.publicKey,
            keyType: .p256Signing,
            createdAt: authority.createdAt,
            isSecureEnclave: authority.isSecureEnclave
        )
    }

    private func publishResolvedIdentity(_ authority: DeviceIdentityAuthorityRecord) {
        let resolvedKeyInfo = keyInfo(from: authority)
        cachedKeyInfo = resolvedKeyInfo
        _deviceId = authority.deviceId
        saveMirroredDeviceId(authority.deviceId)
    }

    private struct LegacyIdentityDiscovery: Equatable {
        let privateKeys: [DeviceIdentityLegacyPrivateKeyCandidate]
        var keyInfoItems: [LegacyGenericPasswordCandidate]
        var deviceIdItems: [LegacyGenericPasswordCandidate]
        let state: DeviceIdentityLegacyState

        mutating func secureEraseEncodedItems() {
            for index in keyInfoItems.indices {
                keyInfoItems[index].data.secureErase()
            }
            for index in deviceIdItems.indices {
                deviceIdItems[index].data.secureErase()
            }
        }
    }

    private struct MutableLegacyAuditValueCount {
        var matching = 0
        var conflicting = 0
        var unresolved = 0

        mutating func record(matchesAuthority: Bool?) {
            switch matchesAuthority {
            case .some(true):
                matching += 1
            case .some(false):
                conflicting += 1
            case .none:
                unresolved += 1
            }
        }

        var snapshot: DeviceIdentityLegacyAuditValueCount {
            DeviceIdentityLegacyAuditValueCount(
                matching: matching,
                conflicting: conflicting,
                unresolved: unresolved
            )
        }
    }

    private struct MutableLegacyAuditNamespaceSummary {
        var privateKeys = MutableLegacyAuditValueCount()
        var keyInfos = MutableLegacyAuditValueCount()
        var deviceIds = MutableLegacyAuditValueCount()
        var mismatches = Dictionary(
            uniqueKeysWithValues: DeviceIdentityLegacyAuditMismatchDimension
                .allCases.map { ($0, 0) }
        )

        mutating func recordMismatch(
            _ dimension: DeviceIdentityLegacyAuditMismatchDimension
        ) {
            mismatches[dimension, default: 0] += 1
        }
    }

    private func makeLegacyIdentityAuditReport(
        legacy: LegacyIdentityDiscovery,
        authority: DeviceIdentityAuthorityRecord?,
        reconciliation: DeviceIdentityLegacyReconciliationAudit?,
        authoritativeAccessGroup: String?
    ) throws -> DeviceIdentityLegacyAuditReport {
        let comparisonKeyInfo = authority.map { keyInfo(from: $0) }
            ?? legacy.state.keyInfos.first
        let comparisonBasis: DeviceIdentityLegacyAuditComparisonBasis
        if authority != nil {
            comparisonBasis = .sharedAuthority
        } else if comparisonKeyInfo != nil {
            comparisonBasis = .firstValidatedLegacyKeyInfo
        } else {
            comparisonBasis = .none
        }
        var summaries = Dictionary(
            uniqueKeysWithValues: DeviceIdentityLegacyAuditNamespace.allCases.map {
                ($0, MutableLegacyAuditNamespaceSummary())
            }
        )

        for candidate in legacy.privateKeys {
            let namespace = Self.legacyAuditNamespace(
                for: candidate.location,
                authoritativeAccessGroup: authoritativeAccessGroup
            )
            let matchesAuthority = comparisonKeyInfo.map {
                candidate.metadata.publicKey == $0.publicKey
                    && candidate.metadata.isSecureEnclave == $0.isSecureEnclave
            }
            summaries[namespace]?.privateKeys.record(
                matchesAuthority: matchesAuthority
            )
            if let comparisonKeyInfo {
                if candidate.metadata.publicKey != comparisonKeyInfo.publicKey {
                    summaries[namespace]?.recordMismatch(.privateKeyPublicKey)
                }
                if candidate.metadata.isSecureEnclave
                    != comparisonKeyInfo.isSecureEnclave {
                    summaries[namespace]?.recordMismatch(
                        .privateKeySecureEnclave
                    )
                }
            }
        }
        for (candidate, keyInfo) in zip(
            legacy.keyInfoItems,
            legacy.state.keyInfos
        ) {
            let namespace = Self.legacyAuditNamespace(
                for: candidate.location,
                authoritativeAccessGroup: authoritativeAccessGroup
            )
            summaries[namespace]?.keyInfos.record(
                matchesAuthority: comparisonKeyInfo.map { keyInfo == $0 }
            )
            if let comparisonKeyInfo {
                if keyInfo.deviceId != comparisonKeyInfo.deviceId {
                    summaries[namespace]?.recordMismatch(.keyInfoDeviceId)
                }
                if keyInfo.publicKey != comparisonKeyInfo.publicKey {
                    summaries[namespace]?.recordMismatch(.keyInfoPublicKey)
                }
                if keyInfo.pubKeyFP != comparisonKeyInfo.pubKeyFP {
                    summaries[namespace]?.recordMismatch(.keyInfoFingerprint)
                }
                if keyInfo.createdAt != comparisonKeyInfo.createdAt {
                    summaries[namespace]?.recordMismatch(.keyInfoCreatedAt)
                }
                if keyInfo.isSecureEnclave
                    != comparisonKeyInfo.isSecureEnclave {
                    summaries[namespace]?.recordMismatch(
                        .keyInfoSecureEnclave
                    )
                }
            }
        }
        for (candidate, deviceId) in zip(
            legacy.deviceIdItems,
            legacy.state.deviceIds
        ) {
            let namespace = Self.legacyAuditNamespace(
                for: candidate.location,
                authoritativeAccessGroup: authoritativeAccessGroup
            )
            summaries[namespace]?.deviceIds.record(
                matchesAuthority: comparisonKeyInfo.map {
                    deviceId == $0.deviceId
                }
            )
            if let comparisonKeyInfo,
               deviceId != comparisonKeyInfo.deviceId {
                summaries[namespace]?.recordMismatch(.deviceId)
            }
        }

        let state: DeviceIdentityLegacyAuditState
        if authority == nil {
            if legacy.state.isEmpty {
                state = .noIdentity
            } else {
                do {
                    let committed = try DeviceIdentityLegacyReconciliation
                        .committedMigrationKeyInfo(from: legacy.state)
                    _ = try DeviceIdentityLegacyReconciliation
                        .uniqueCommittedMigrationPrivateKey(
                            from: legacy.privateKeys,
                            matching: committed
                        )
                    state = .legacyCommittedTupleSelected
                } catch let authorityError as DeviceIdentityAuthorityError {
                    switch authorityError {
                    case .legacySecureEnclaveRequiresRotationAndRepinning,
                         .legacyPrivateKeyNotExportableRequiresRotationAndRepinning:
                        state = .legacyMigrationRequiresRotation
                    case .legacyIdentityIncomplete:
                        state = .legacyMigrationIncomplete
                    case .legacyIdentityConflictsWithAuthority:
                        state = .legacyMigrationConflict
                    default:
                        throw authorityError
                    }
                }
            }
        } else if legacy.state.isEmpty {
            state = .authorityClean
        } else if reconciliation?.hasConflicts == true {
            state = .conflictingLegacyRemnants
        } else {
            state = .matchingLegacyRemnants
        }

        return DeviceIdentityLegacyAuditReport(
            schemaVersion: 2,
            state: state,
            authorityPresent: authority != nil,
            authorityKeyValidated: authority != nil,
            comparisonBasis: comparisonBasis,
            stableAcrossReads: true,
            inspectionStatus: .complete(
                hasConflicts: reconciliation?.hasConflicts == true
            ),
            namespaces: DeviceIdentityLegacyAuditNamespace.allCases.map { namespace in
                let summary = summaries[namespace]
                    ?? MutableLegacyAuditNamespaceSummary()
                return DeviceIdentityLegacyAuditNamespaceSummary(
                    namespace: namespace,
                    privateKeys: summary.privateKeys.snapshot,
                    keyInfos: summary.keyInfos.snapshot,
                    deviceIds: summary.deviceIds.snapshot,
                    mismatches: DeviceIdentityLegacyAuditMismatchDimension
                        .allCases.map { dimension in
                            DeviceIdentityLegacyAuditMismatchCount(
                                dimension: dimension,
                                count: summary.mismatches[dimension, default: 0]
                            )
                        }
                )
            }
        )
    }

    nonisolated static func legacyAuditNamespace(
        for location: LegacySecItemLocation,
        authoritativeAccessGroup: String?
    ) -> DeviceIdentityLegacyAuditNamespace {
        guard location.usesDataProtectionKeychain else {
            return .legacyFileKeychain
        }
        if location.actualAccessGroup == authoritativeAccessGroup {
            return .sharedDataProtection
        }
        return .otherDataProtection
    }

    private func discoverStableLegacyIdentity(
        using store: DeviceIdentityKeychainAuthorityStore
    ) throws -> LegacyIdentityDiscovery {
        var initial = try discoverLegacyIdentity(using: store)
        var returnedVerifiedSnapshot = false
        defer {
            if !returnedVerifiedSnapshot {
                initial.secureEraseEncodedItems()
            }
        }
        var verified = try discoverLegacyIdentity(using: store)
        guard initial == verified else {
            verified.secureEraseEncodedItems()
            throw LegacyResidueInspectionError(reason: .changedDuringRead)
        }
        initial.secureEraseEncodedItems()
        returnedVerifiedSnapshot = true
        return verified
    }

    /// Maps only known storage/data-boundary failures. A nil result means the
    /// error is not an expected residue-inspection failure and must propagate.
    nonisolated static func legacyResidueInspectionFailureReason(
        for error: Error
    ) -> DeviceIdentityLegacyResidueInspectionFailureReason? {
        if let inspectionError = error as? LegacyResidueInspectionError {
            return inspectionError.reason
        }
        if let keychainError = error as? KeychainError {
            switch keychainError {
            case .itemNotFound, .itemChangedDuringReconciliation:
                return .changedDuringRead
            case .decodingError:
                return .malformedAttributes
            case .unexpectedError(let status):
                return legacyResidueInspectionFailureReason(for: status)
            case .immutableStateCorrupt, .immutableStateCycleRejected,
                 .immutableStateTransitionLimitExceeded:
                // Q-Periapt trusted-state failures cannot originate from
                // identity residue inspection; they must propagate untouched.
                return nil
            }
        }
        if let keyError = error as? DeviceIdentityKeyError {
            switch keyError {
            case .keyAccessDenied:
                return .accessDenied
            case .keychainError(let status):
                return legacyResidueInspectionFailureReason(for: status)
            case .keyGenerationFailed:
                return .keyMaterialUnavailable
            case .keyNotFound:
                return .changedDuringRead
            case .invalidKeyData:
                return .malformedAttributes
            case .secureEnclaveNotAvailable,
                 .incompleteKeyMaterial,
                 .signatureFailed,
                 .verificationFailed,
                 .keyRotationFailed,
                 .authorityConflict,
                 .corruptIdentityAuthority,
                 .identityMigrationRequired,
                 .identityMigrationRequiresRotationAndRepinning:
                return nil
            }
        }
        if let authorityError = error as? DeviceIdentityAuthorityError {
            switch authorityError {
            case .legacyIdentityChangedDuringAudit:
                return .changedDuringRead
            case .legacyIdentityIncomplete, .invalidPublicKey:
                return .malformedAttributes
            case .unsupportedRecordVersion,
                 .invalidDeviceId,
                 .publicKeyFingerprintMismatch,
                 .invalidPrivateKeyApplicationTag,
                 .invalidCreatedAt,
                 .corruptAuthorityRecord,
                 .authorityWinnerMissing,
                 .authorityWinnerKeyMissing,
                 .authorityWinnerPublicKeyMismatch,
                 .authorityWinnerSecureEnclaveMismatch,
                 .candidateKeyPublicKeyMismatch,
                 .candidateCleanupFailed,
                 .legacyIdentityConflictsWithAuthority,
                 .legacyIdentityRequiresExplicitMigration,
                 .legacySecureEnclaveRequiresRotationAndRepinning,
                 .legacyPrivateKeyNotExportableRequiresRotationAndRepinning,
                 .immutableGenericPasswordConflict:
                return nil
            }
        }
        return nil
    }

    private nonisolated static func legacyResidueInspectionFailureReason(
        for status: OSStatus
    ) -> DeviceIdentityLegacyResidueInspectionFailureReason {
        switch status {
        case errSecInteractionNotAllowed,
             errSecAuthFailed,
             errSecUserCanceled,
             errSecMissingEntitlement:
            return .accessDenied
        default:
            return .keychainUnavailable
        }
    }

    private nonisolated static func legacyResidueInspectionError(
        for error: Error
    ) -> LegacyResidueInspectionError? {
        guard let reason = legacyResidueInspectionFailureReason(for: error) else {
            return nil
        }
        return LegacyResidueInspectionError(reason: reason)
    }

    private func performLegacyResidueInspectionOperation<T>(
        _ operation: () throws -> T
    ) throws -> T {
        do {
            return try operation()
        } catch let keychainError as KeychainError {
            guard let inspectionError = Self.legacyResidueInspectionError(
                for: keychainError
            ) else {
                throw keychainError
            }
            throw inspectionError
        } catch let keyError as DeviceIdentityKeyError {
            guard let inspectionError = Self.legacyResidueInspectionError(
                for: keyError
            ) else {
                throw keyError
            }
            throw inspectionError
        } catch let authorityError as DeviceIdentityAuthorityError {
            guard let inspectionError = Self.legacyResidueInspectionError(
                for: authorityError
            ) else {
                throw authorityError
            }
            throw inspectionError
        }
    }

    private func discoverLegacyIdentity(
        using store: DeviceIdentityKeychainAuthorityStore
    ) throws -> LegacyIdentityDiscovery {
        var keyInfoItems: [LegacyGenericPasswordCandidate] = []
        var deviceIdItems: [LegacyGenericPasswordCandidate] = []
        var discoveryCompleted = false
        defer {
            if !discoveryCompleted {
                for index in keyInfoItems.indices {
                    keyInfoItems[index].data.secureErase()
                }
                for index in deviceIdItems.indices {
                    deviceIdItems[index].data.secureErase()
                }
            }
        }
        do {
            let privateKeys = try performLegacyResidueInspectionOperation {
                try store.loadLegacyPrivateKeyCandidates(
                    applicationTag: KeychainConstants.signingKeyTag
                )
            }
            keyInfoItems = try performLegacyResidueInspectionOperation {
                try KeychainManager.shared
                    .legacyGenericPasswordCandidatesStrict(
                        service: KeychainConstants.service,
                        account: "keyInfo",
                        includeLegacyKeychain: true
                    )
            }
            deviceIdItems = try performLegacyResidueInspectionOperation {
                try KeychainManager.shared
                    .legacyGenericPasswordCandidatesStrict(
                        service: KeychainConstants.service,
                        account: KeychainConstants.deviceIdKey,
                        includeLegacyKeychain: true
                    )
            }
            guard privateKeys.count
                    <= KeychainConstants.legacyIdentityMaximumCandidatesPerClass,
                  keyInfoItems.count
                    <= KeychainConstants.legacyIdentityMaximumCandidatesPerClass,
                  deviceIdItems.count
                    <= KeychainConstants.legacyIdentityMaximumCandidatesPerClass else {
                throw LegacyResidueInspectionError(
                    reason: .candidateLimitExceeded
                )
            }
            let keyInfos: [DeviceIdentityKeyInfo] = try keyInfoItems.map { item in
                guard item.data.count
                        <= KeychainConstants.legacyKeyInfoMaximumEncodedSize else {
                    throw LegacyResidueInspectionError(reason: .malformedKeyInfo)
                }
                do {
                    return try JSONDecoder().decode(
                        DeviceIdentityKeyInfo.self,
                        from: item.data
                    )
                } catch {
                    throw LegacyResidueInspectionError(reason: .malformedKeyInfo)
                }
            }
            let deviceIds: [String] = try deviceIdItems.map { item in
                guard item.data.count
                        <= KeychainConstants.legacyDeviceIdMaximumEncodedSize,
                      let value = String(data: item.data, encoding: .utf8),
                      !value.isEmpty,
                      value == value.trimmingCharacters(
                          in: .whitespacesAndNewlines
                      ),
                      value.unicodeScalars.allSatisfy({
                          !CharacterSet.controlCharacters.contains($0)
                      }) else {
                    throw LegacyResidueInspectionError(reason: .invalidDeviceId)
                }
                return value
            }
            let discovery = LegacyIdentityDiscovery(
                privateKeys: privateKeys,
                keyInfoItems: keyInfoItems,
                deviceIdItems: deviceIdItems,
                state: DeviceIdentityLegacyState(
                    keyInfos: keyInfos,
                    deviceIds: deviceIds,
                    privateKeyMetadata: privateKeys.map(\.metadata)
                )
            )
            discoveryCompleted = true
            return discovery
        }
    }

    private func migrateLegacyIdentity(
        _ legacy: LegacyIdentityDiscovery,
        using store: DeviceIdentityKeychainAuthorityStore
    ) throws -> DeviceIdentityAuthorityRecord {
        let legacyKeyInfo = try DeviceIdentityLegacyReconciliation
            .committedMigrationKeyInfo(from: legacy.state)
        let sourceKey = try DeviceIdentityLegacyReconciliation
            .uniqueCommittedMigrationPrivateKey(
                from: legacy.privateKeys,
                matching: legacyKeyInfo
            )
        var privateKeyRepresentation = try store.exportLegacyPrivateKey(
            sourceKey
        )
        defer { privateKeyRepresentation.secureErase() }

        let candidateTag = DeviceIdentityAuthorityRecord.uniquePrivateKeyApplicationTag()
        let legacyAuthority = DeviceIdentityAuthorityRecord(
            deviceId: legacyKeyInfo.deviceId,
            publicKey: legacyKeyInfo.publicKey,
            publicKeyFingerprint: legacyKeyInfo.pubKeyFP,
            privateKeyApplicationTag: candidateTag,
            isSecureEnclave: false,
            createdAt: legacyKeyInfo.createdAt
        )
        let winner = try DeviceIdentityAuthorityTransaction.migrateLegacy(
            .software(
                authority: legacyAuthority,
                privateKeyRepresentation: privateKeyRepresentation
            ),
            candidateApplicationTag: candidateTag,
            using: store
        )
        return winner
    }

 /// 加载 KEM 身份密钥记录（按 suite + provider tier）
    private func loadKEMKeyRecord(suiteWireId: UInt16, tier: CryptoTier) throws -> KEMIdentityKeyRecord? {
        let tierAccount = kemAccount(suiteWireId: suiteWireId, tier: tier)
        let currentRecord = try loadKEMKeyRecord(
            account: tierAccount,
            suiteWireId: suiteWireId,
            validationPolicy: .providerTier(tier)
        )

        // Legacy records omitted the provider tier. Decode them against the
        // union of supported persisted contracts before assigning exactly one
        // provider namespace; validating them as the requested tier would turn
        // a legitimate liboqs-to-Apple transition into apparent corruption.
        let legacyAccount = kemAccount(suiteWireId: suiteWireId, tier: nil)
        let legacyRecord = try loadKEMKeyRecord(
            account: legacyAccount,
            suiteWireId: suiteWireId,
            validationPolicy: .untieredLegacy
        )
        guard let legacyRecord else {
            return currentRecord
        }

        let legacyTier = try providerTierForUntieredKEMRecord(
            legacyRecord,
            suiteWireId: suiteWireId
        )
        if legacyTier == tier {
            if let currentRecord {
                guard legacyRecord == currentRecord else {
                    throw DeviceIdentityAuthorityError
                        .immutableGenericPasswordConflict(
                            service: kemStorageService,
                            account: legacyAccount
                        )
                }
                try deleteGenericPasswordItems(
                    service: kemStorageService,
                    account: legacyAccount
                )
                return currentRecord
            }
            let winner = try saveKEMKeyRecord(
                legacyRecord,
                tier: tier,
                conflictPolicy: .requireExactCandidate
            )
            try deleteGenericPasswordItems(
                service: kemStorageService,
                account: legacyAccount
            )
            return winner
        }

        // A valid record from another provider is a separate KEM identity, not
        // a conflicting candidate for this tier. Bind it to its uniquely
        // inferred namespace before removing the ambiguous legacy slot. If a
        // different winner already occupies that namespace, the exact-candidate
        // policy still fails closed and leaves the legacy record intact.
        _ = try saveKEMKeyRecord(
            legacyRecord,
            tier: legacyTier,
            conflictPolicy: .requireExactCandidate
        )
        try deleteGenericPasswordItems(
            service: kemStorageService,
            account: legacyAccount
        )
        return currentRecord
    }

    private func providerTierForUntieredKEMRecord(
        _ record: KEMIdentityKeyRecord,
        suiteWireId: UInt16
    ) throws -> CryptoTier {
        guard record.suiteWireId == suiteWireId else {
            throw DeviceIdentityKeyError.incompleteKeyMaterial(
                "stored untiered KEM suite does not match its identity slot"
            )
        }
        let matchingTiers = [
            CryptoTier.qperiaptPQC,
            .nativePQC,
            .liboqsPQC
        ].filter {
            kemRecordMatchesProvider(
                record,
                suiteWireId: suiteWireId,
                tier: $0
            )
        }
        guard matchingTiers.count == 1, let matchedTier = matchingTiers.first else {
            throw DeviceIdentityKeyError.incompleteKeyMaterial(
                "stored untiered KEM identity does not match exactly one provider contract"
            )
        }
        return matchedTier
    }

    private enum KEMRecordValidationPolicy {
        case providerTier(CryptoTier)
        case untieredLegacy
    }

    private func validateDecodedKEMRecord(
        _ record: KEMIdentityKeyRecord,
        suiteWireId: UInt16,
        policy: KEMRecordValidationPolicy
    ) throws {
        switch policy {
        case .providerTier(let tier):
            try validateKEMRecord(
                record,
                suiteWireId: suiteWireId,
                tier: tier
            )
        case .untieredLegacy:
            _ = try providerTierForUntieredKEMRecord(
                record,
                suiteWireId: suiteWireId
            )
        }
    }

    #if DEBUG || SKYBRIDGE_TESTING
    internal func seedUntieredKEMIdentityRecordForTesting(
        _ record: KEMIdentityKeyRecord
    ) throws {
        guard Self.useInMemoryKeychain, testingStorageNamespace != nil else {
            throw DeviceIdentityTestingConfigurationError
                .requiresNamespacedInMemoryStore
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(record)
        try validateDecodedKEMRecord(
            record,
            suiteWireId: record.suiteWireId,
            policy: .untieredLegacy
        )
        let account = kemAccount(suiteWireId: record.suiteWireId, tier: nil)
        let key = kemStorageService + "|" + account
        let inserted = Self.inMemoryKEMLock.withLock { () -> Bool in
            guard Self.inMemoryKEMStore[key] == nil else { return false }
            Self.inMemoryKEMStore[key] = data
            return true
        }
        guard inserted else {
            throw DeviceIdentityKeyError.authorityConflict(
                "test KEM identity slot already contains a record"
            )
        }
    }

    internal func storedKEMIdentityRecordForTesting(
        suiteWireId: UInt16,
        tier: CryptoTier?
    ) throws -> KEMIdentityKeyRecord? {
        guard Self.useInMemoryKeychain, testingStorageNamespace != nil else {
            throw DeviceIdentityTestingConfigurationError
                .requiresNamespacedInMemoryStore
        }
        let account = kemAccount(suiteWireId: suiteWireId, tier: tier)
        let key = kemStorageService + "|" + account
        guard let data = Self.inMemoryKEMLock.withLock({
            Self.inMemoryKEMStore[key]
        }) else {
            return nil
        }
        let policy = tier.map(KEMRecordValidationPolicy.providerTier)
            ?? .untieredLegacy
        return try decodeKEMRecord(
            data,
            suiteWireId: suiteWireId,
            validationPolicy: policy
        )
    }

    internal func clearKEMIdentityRecordsForTesting() throws {
        guard Self.useInMemoryKeychain, testingStorageNamespace != nil else {
            throw DeviceIdentityTestingConfigurationError
                .requiresNamespacedInMemoryStore
        }
        let keyPrefix = kemStorageService + "|"
        Self.inMemoryKEMLock.withLock {
            Self.inMemoryKEMStore = Self.inMemoryKEMStore.filter {
                !$0.key.hasPrefix(keyPrefix)
            }
        }
        cachedKEMPublicKeys.removeAll()
    }
    #endif

    private func deleteGenericPasswordItems(
        service: String,
        account: String
    ) throws {
        if Self.useInMemoryKeychain, service == kemStorageService {
            Self.inMemoryKEMLock.withLock {
                _ = Self.inMemoryKEMStore.removeValue(
                    forKey: service + "|" + account
                )
            }
            return
        }
        let candidates = try KeychainManager.shared
            .legacyGenericPasswordCandidatesStrict(
                service: service,
                account: account,
                includeLegacyKeychain: true
            )
        for candidate in candidates {
            try KeychainManager.shared
                .deleteLegacyGenericPasswordCandidate(candidate)
        }
    }
    
 /// 保存 KEM 身份密钥记录（按 suite + provider tier）
    private enum ImmutableCandidateConflictPolicy: Equatable {
        case adoptWinner
        case requireExactCandidate
    }

    private func saveKEMKeyRecord(
        _ record: KEMIdentityKeyRecord,
        tier: CryptoTier,
        conflictPolicy: ImmutableCandidateConflictPolicy
    ) throws -> KEMIdentityKeyRecord {
        try validateKEMRecord(
            record,
            suiteWireId: record.suiteWireId,
            tier: tier
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(record)
        
        let account = kemAccount(suiteWireId: record.suiteWireId, tier: tier)
        if Self.useInMemoryKeychain {
            let key = kemStorageService + "|" + account
            let winnerData = Self.inMemoryKEMLock.withLock { () -> Data in
                if let existing = Self.inMemoryKEMStore[key] {
                    return existing
                }
                Self.inMemoryKEMStore[key] = data
                return data
            }
            let winner = try decodeKEMRecord(
                winnerData,
                suiteWireId: record.suiteWireId,
                validationPolicy: .providerTier(tier)
            )
            if conflictPolicy == .requireExactCandidate, winner != record {
                throw DeviceIdentityKeyError.authorityConflict(
                    "immutable Keychain winner differs for \(kemStorageService)/\(account)"
                )
            }
            return winner
        }

        let winnerData = try insertImmutableGenericPasswordCandidate(
            service: kemStorageService,
            account: account,
            data: data,
            conflictPolicy: conflictPolicy,
            validate: { encoded in
                _ = try self.decodeKEMRecord(
                    encoded,
                    suiteWireId: record.suiteWireId,
                    validationPolicy: .providerTier(tier)
                )
            },
            equivalent: { lhs, rhs in
                try self.decodeKEMRecord(
                    lhs,
                    suiteWireId: record.suiteWireId,
                    validationPolicy: .providerTier(tier)
                ) == self.decodeKEMRecord(
                    rhs,
                    suiteWireId: record.suiteWireId,
                    validationPolicy: .providerTier(tier)
                )
            }
        )
        return try decodeKEMRecord(
            winnerData,
            suiteWireId: record.suiteWireId,
            validationPolicy: .providerTier(tier)
        )
    }

    private struct KEMCacheKey: Hashable, Sendable {
        let suiteWireId: UInt16
        let tier: CryptoTier
    }

    private func kemAccount(suiteWireId: UInt16, tier: CryptoTier?) -> String {
        if let tier {
            return KeychainConstants.kemKeyPrefix + "\(suiteWireId)-\(tier.rawValue)"
        }
        return KeychainConstants.kemKeyPrefix + String(suiteWireId)
    }

    private func loadKEMKeyRecord(
        account: String,
        suiteWireId: UInt16,
        validationPolicy: KEMRecordValidationPolicy
    ) throws -> KEMIdentityKeyRecord? {
        if Self.useInMemoryKeychain {
            let key = kemStorageService + "|" + account
            Self.inMemoryKEMLock.lock()
            let data = Self.inMemoryKEMStore[key]
            Self.inMemoryKEMLock.unlock()
            guard let data else { return nil }
            return try decodeKEMRecord(
                data,
                suiteWireId: suiteWireId,
                validationPolicy: validationPolicy
            )
        }
        guard let data = try readGenericPasswordData(
            service: kemStorageService,
            account: account,
            validate: { encoded in
                _ = try self.decodeKEMRecord(
                    encoded,
                    suiteWireId: suiteWireId,
                    validationPolicy: validationPolicy
                )
            },
            equivalent: { lhs, rhs in
                try self.decodeKEMRecord(
                    lhs,
                    suiteWireId: suiteWireId,
                    validationPolicy: validationPolicy
                ) == self.decodeKEMRecord(
                    rhs,
                    suiteWireId: suiteWireId,
                    validationPolicy: validationPolicy
                )
            }
        ) else {
            return nil
        }

        return try decodeKEMRecord(
            data,
            suiteWireId: suiteWireId,
            validationPolicy: validationPolicy
        )
    }

    private func decodeKEMRecord(
        _ data: Data,
        suiteWireId: UInt16,
        validationPolicy: KEMRecordValidationPolicy
    ) throws -> KEMIdentityKeyRecord {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let record = try decoder.decode(KEMIdentityKeyRecord.self, from: data)
        try validateDecodedKEMRecord(
            record,
            suiteWireId: suiteWireId,
            policy: validationPolicy
        )
        return record
    }

    private func kemRecordMatchesProvider(
        _ record: KEMIdentityKeyRecord,
        suiteWireId: UInt16,
        tier: CryptoTier
    ) -> Bool {
        guard record.suiteWireId == suiteWireId,
              suiteWireId != CryptoSuite.qperiaptContextBound.wireId else {
            return false
        }
        guard let contract = KEMIdentityKeyLengthContract.resolve(
            suite: CryptoSuite(wireId: suiteWireId),
            providerTier: tier
        ) else {
            return false
        }
        return record.privateKey.count == contract.privateKeyLength
            && record.publicKey.count == contract.publicKeyLength
    }

    private func validateKEMRecord(
        _ record: KEMIdentityKeyRecord,
        suiteWireId: UInt16,
        tier: CryptoTier
    ) throws {
        guard record.suiteWireId == suiteWireId else {
            throw DeviceIdentityKeyError.incompleteKeyMaterial(
                "stored KEM suite does not match its identity slot"
            )
        }
        guard let contract = KEMIdentityKeyLengthContract.resolve(
            suite: CryptoSuite(wireId: suiteWireId),
            providerTier: tier
        ) else {
            throw CryptoProviderError.unsupportedAlgorithm(
                "No KEM identity length contract for suite \(suiteWireId) and tier \(tier.rawValue)"
            )
        }
        guard record.publicKey.count == contract.publicKeyLength else {
            throw CryptoProviderError.invalidKeyLength(
                expected: contract.publicKeyLength,
                actual: record.publicKey.count,
                suite: CryptoSuite(wireId: suiteWireId).rawValue,
                usage: .keyExchange
            )
        }
        guard record.privateKey.count == contract.privateKeyLength else {
            throw CryptoProviderError.invalidKeyLength(
                expected: contract.privateKeyLength,
                actual: record.privateKey.count,
                suite: CryptoSuite(wireId: suiteWireId).rawValue,
                usage: .keyExchange
            )
        }
    }
    
 /// 计算公钥指纹
    private func computePublicKeyFingerprint(_ publicKey: Data) -> String {
        let hash = SHA256.hash(data: publicKey)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
    
    private func loadStoredDeviceIdStrict() throws -> String? {
        if Self.useInMemoryKeychain {
            let key = KeychainConstants.service + "|" + KeychainConstants.deviceIdKey
            Self.inMemoryLock.lock()
            let data = Self.inMemoryStore[key]
            Self.inMemoryLock.unlock()
            guard let data else { return nil }
            guard let value = String(data: data, encoding: .utf8), !value.isEmpty else {
                throw DeviceIdentityKeyError.invalidKeyData
            }
            saveMirroredDeviceId(value)
            return value
        }
        throw DeviceIdentityAuthorityError.legacyIdentityIncomplete(
            "deviceId must be loaded from the identity authority"
        )
    }

    private func saveDeviceIdStrict(_ deviceId: String) throws {
        guard let data = deviceId.data(using: .utf8) else {
            throw DeviceIdentityKeyError.invalidKeyData
        }

        if Self.useInMemoryKeychain {
            let key = KeychainConstants.service + "|" + KeychainConstants.deviceIdKey
            Self.inMemoryLock.lock()
            Self.inMemoryStore[key] = data
            Self.inMemoryLock.unlock()
            saveMirroredDeviceId(deviceId)
            return
        }

        throw DeviceIdentityAuthorityError.legacyIdentityIncomplete(
            "deviceId cannot be persisted independently of the identity authority"
        )
    }

    private func saveMirroredDeviceId(_ deviceId: String) {
        UserDefaults.standard.set(deviceId, forKey: KeychainConstants.mirroredDeviceIdDefaultsKey)
    }

    private func saveMirroredData(_ data: Data, forKey key: String) {
        UserDefaults.standard.set(data, forKey: key)
    }

    private func readGenericPasswordData(
        service: String,
        account: String,
        includeLegacyMigration: Bool = true,
        validate: (Data) throws -> Void,
        equivalent: (Data, Data) throws -> Bool = { $0 == $1 }
    ) throws -> Data? {
        let migrationScope = try resolvedSharedIdentityKeychainScope()
        let authoritativeScope = try migrationScope.authoritativeOnly()
        if let authoritative = try KeychainManager.shared.exportKeyStrict(
            service: service,
            account: account,
            scope: authoritativeScope,
            includeLegacyKeychain: false
        ) {
            try validate(authoritative)
            if includeLegacyMigration {
                try reconcileLegacyGenericPasswordCandidates(
                    service: service,
                    account: account,
                    authoritative: authoritative,
                    authoritativeScope: authoritativeScope,
                    validate: validate,
                    equivalent: equivalent
                )
            }
            return authoritative
        }

        guard includeLegacyMigration else {
            return nil
        }
        var legacyCandidates = try KeychainManager.shared
            .legacyGenericPasswordCandidatesStrict(
            service: service,
            account: account,
            includeLegacyKeychain: true
        )
        defer {
            for index in legacyCandidates.indices {
                legacyCandidates[index].data.secureErase()
            }
        }
        if let concurrentAuthority = try KeychainManager.shared.exportKeyStrict(
            service: service,
            account: account,
            scope: authoritativeScope,
            includeLegacyKeychain: false
        ) {
            try validate(concurrentAuthority)
            try reconcileLegacyGenericPasswordCandidates(
                service: service,
                account: account,
                authoritative: concurrentAuthority,
                authoritativeScope: authoritativeScope,
                validate: validate,
                equivalent: equivalent
            )
            return concurrentAuthority
        }
        guard let legacy = legacyCandidates.first?.data else { return nil }
        for candidate in legacyCandidates {
            try validate(candidate.data)
            guard try equivalent(candidate.data, legacy) else {
                throw DeviceIdentityAuthorityError
                    .immutableGenericPasswordConflict(
                        service: service,
                        account: account
                    )
            }
        }
        _ = try KeychainManager.shared.insertKeyIfAbsent(
            data: legacy,
            service: service,
            account: account,
            scope: authoritativeScope
        )
        guard let winner = try KeychainManager.shared.exportKeyStrict(
            service: service,
            account: account,
            scope: authoritativeScope,
            includeLegacyKeychain: false
        ) else {
            throw DeviceIdentityKeyError.corruptIdentityAuthority(
                "immutable Keychain winner is missing for \(service)/\(account)"
            )
        }
        try validate(winner)
        guard try equivalent(winner, legacy) else {
            throw DeviceIdentityAuthorityError
                .immutableGenericPasswordConflict(
                    service: service,
                    account: account
                )
        }
        try reconcileLegacyGenericPasswordCandidates(
            service: service,
            account: account,
            authoritative: winner,
            authoritativeScope: authoritativeScope,
            validate: validate,
            equivalent: equivalent
        )
        return winner
    }

    private func reconcileLegacyGenericPasswordCandidates(
        service: String,
        account: String,
        authoritative: Data,
        authoritativeScope: KeychainGenericPasswordScope,
        validate: (Data) throws -> Void,
        equivalent: (Data, Data) throws -> Bool
    ) throws {
        guard let authoritativeAccessGroup = authoritativeScope.writeAccessGroup else {
            throw KeychainGenericPasswordScopeError.missingAuthoritativeWriteAccessGroup
        }
        var candidates = try KeychainManager.shared
            .legacyGenericPasswordCandidatesStrict(
                service: service,
                account: account,
                includeLegacyKeychain: true
            )
        defer {
            for index in candidates.indices {
                candidates[index].data.secureErase()
            }
        }
        for candidate in candidates {
            try validate(candidate.data)
            let isAuthoritative = candidate.location.actualAccessGroup
                    == authoritativeAccessGroup
                && candidate.location.usesDataProtectionKeychain
                    == authoritativeScope.usesDataProtectionKeychain
            guard try equivalent(candidate.data, authoritative) else {
                throw DeviceIdentityAuthorityError
                    .immutableGenericPasswordConflict(
                        service: service,
                        account: account
                    )
            }
            if !isAuthoritative {
                try KeychainManager.shared
                    .deleteLegacyGenericPasswordCandidate(candidate)
            }
        }
    }

    private func insertImmutableGenericPasswordCandidate(
        service: String,
        account: String,
        data: Data,
        conflictPolicy: ImmutableCandidateConflictPolicy,
        validate: (Data) throws -> Void,
        equivalent: (Data, Data) throws -> Bool = { $0 == $1 }
    ) throws -> Data {
        try validate(data)
        let authoritativeScope = try resolvedSharedIdentityKeychainScope()
            .authoritativeOnly()
        _ = try KeychainManager.shared.insertKeyIfAbsent(
            data: data,
            service: service,
            account: account,
            scope: authoritativeScope
        )
        guard let winner = try KeychainManager.shared.exportKeyStrict(
            service: service,
            account: account,
            scope: authoritativeScope,
            includeLegacyKeychain: false
        ) else {
            throw DeviceIdentityKeyError.corruptIdentityAuthority(
                "immutable Keychain winner is missing for \(service)/\(account)"
            )
        }
        try validate(winner)
        if conflictPolicy == .requireExactCandidate,
           !(try equivalent(winner, data)) {
            throw DeviceIdentityAuthorityError
                .immutableGenericPasswordConflict(
                    service: service,
                    account: account
                )
        }
        try reconcileLegacyGenericPasswordCandidates(
            service: service,
            account: account,
            authoritative: winner,
            authoritativeScope: authoritativeScope,
            validate: validate,
            equivalent: equivalent
        )
        return winner
    }
    
 // MARK: - Ed25519 Protocol Signing Key Helpers ( 5.1)
    
 /// 创建 Ed25519 协议签名密钥
    private func createProtocolSigningKey() throws -> (publicKey: Data, privateKey: Data) {
        let candidatePrivateKey = Curve25519.Signing.PrivateKey()
        var candidatePrivateKeyData = candidatePrivateKey.rawRepresentation
        defer { candidatePrivateKeyData.secureErase() }
        
 // 存储到 Keychain
        if Self.useInMemoryKeychain {
            let key = KeychainConstants.service + "|" + KeychainConstants.protocolSigningKeyTag
            let privateKeyData = Self.inMemoryLock.withLock { () -> Data in
                if let winner = Self.inMemoryStore[key] {
                    return winner
                }
                Self.inMemoryStore[key] = candidatePrivateKeyData
                return candidatePrivateKeyData
            }
            let privateKey = try Curve25519.Signing.PrivateKey(
                rawRepresentation: privateKeyData
            )
            let publicKeyData = privateKey.publicKey.rawRepresentation
            saveMirroredData(publicKeyData, forKey: KeychainConstants.mirroredProtocolSigningPublicKeyDefaultsKey)
            SkyBridgeLogger.p2p.info("Created new Ed25519 protocol signing key (in-memory)")
            return (publicKey: publicKeyData, privateKey: privateKeyData)
        }

        let privateKeyData = try insertImmutableGenericPasswordCandidate(
            service: KeychainConstants.service,
            account: KeychainConstants.protocolSigningKeyTag,
            data: candidatePrivateKeyData,
            conflictPolicy: .adoptWinner,
            validate: { encoded in
                _ = try Curve25519.Signing.PrivateKey(rawRepresentation: encoded)
            }
        )
        let privateKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: privateKeyData
        )
        let publicKeyData = privateKey.publicKey.rawRepresentation
        saveMirroredData(publicKeyData, forKey: KeychainConstants.mirroredProtocolSigningPublicKeyDefaultsKey)
        
        SkyBridgeLogger.p2p.info("Created new Ed25519 protocol signing key")
        return (publicKey: publicKeyData, privateKey: privateKeyData)
    }
    
 /// 加载 Ed25519 协议签名密钥
    private func loadProtocolSigningKey() throws -> (publicKey: Data, privateKey: Data)? {
        if Self.useInMemoryKeychain {
            let key = KeychainConstants.service + "|" + KeychainConstants.protocolSigningKeyTag
            Self.inMemoryLock.lock()
            let privateKeyData = Self.inMemoryStore[key]
            Self.inMemoryLock.unlock()
            guard let privateKeyData else { return nil }
            let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)
            return (publicKey: privateKey.publicKey.rawRepresentation, privateKey: privateKeyData)
        }

        guard let privateKeyData = try readGenericPasswordData(
            service: KeychainConstants.service,
            account: KeychainConstants.protocolSigningKeyTag,
            validate: { encoded in
                _ = try Curve25519.Signing.PrivateKey(rawRepresentation: encoded)
            }
        ) else {
            return nil
        }
        
 // 从私钥派生公钥
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)
        let publicKeyData = privateKey.publicKey.rawRepresentation
        saveMirroredData(publicKeyData, forKey: KeychainConstants.mirroredProtocolSigningPublicKeyDefaultsKey)
        
        return (publicKey: publicKeyData, privateKey: privateKeyData)
    }
    
 // MARK: - ML-DSA protocol identity protection

    private func getOrCreateMLDSA87SigningIdentity() async throws -> (
        publicKey: Data,
        keyHandle: SigningKeyHandle
    ) {
        if let cachedMLDSA87SigningIdentity {
            return cachedMLDSA87SigningIdentity
        }
        let resolved = try await OQSProtocolMLDSASigningCallback.resolve(
            algorithm: .mlDSA87,
            identity: mldsa87StoreIdentity,
            scopeSource: effectiveSharedIdentityScopeSource
        )
        cachedMLDSA87SigningIdentity = resolved
        return resolved
    }

    /// Returns the authoritative protection mode already persisted for an
    /// algorithm. This is status, not user intent; absence means no identity
    /// has been provisioned for that algorithm yet.
    public func existingProtocolSigningKeyProtection(
        for algorithm: ProtocolSigningAlgorithm
    ) async throws -> ProtocolSigningKeyProtection? {
        if try loadSecureEnclaveMLDSARecord(for: algorithm) != nil {
            return .secureEnclaveRequired
        }
        switch algorithm {
        case .ed25519:
            return try loadProtocolSigningKey() == nil ? nil : .softwareKeychain
        case .mlDSA65:
            return try loadMLDSASigningKey() == nil ? nil : .softwareKeychain
        case .mlDSA87:
            if cachedMLDSA87SigningIdentity != nil {
                return .softwareKeychain
            }
            let publicKey = try OQSBridge.existingSigningPublicKey(
                peerId: mldsa87StoreIdentity,
                algorithm: .mldsa87,
                authority: .active,
                scopeSource: effectiveSharedIdentityScopeSource
            )
            return publicKey == nil ? nil : .softwareKeychain
        }
    }

    private func getOrCreateSecureEnclaveMLDSAIdentity(
        for algorithm: ProtocolSigningAlgorithm
    ) async throws -> (publicKey: Data, keyHandle: SigningKeyHandle) {
        guard algorithm != .ed25519 else {
            throw SecureEnclaveMLDSAIdentityError.unsupportedAlgorithm(algorithm)
        }
        if let cached = cachedSecureEnclaveMLDSAIdentities[algorithm] {
            return (cached.publicKey, .callback(cached.signingCallback))
        }
        if let existing = try loadSecureEnclaveMLDSARecord(for: algorithm) {
            let material = try await restoreSecureEnclaveMLDSARecord(existing)
            cachedSecureEnclaveMLDSAIdentities[algorithm] = material
            return (material.publicKey, .callback(material.signingCallback))
        }

        guard #available(macOS 26.0, iOS 26.0, *) else {
            throw SecureEnclaveMLDSAIdentityError.sdkUnavailable
        }
        let candidate = try await SecureEnclaveMLDSAIdentityFactory.create(
            algorithm: algorithm
        )
        var candidateRecord = SecureEnclaveMLDSAIdentityRecord(
            algorithm: algorithm,
            publicKey: candidate.publicKey,
            opaqueKeyRepresentation: candidate.opaqueKeyRepresentation
        )
        defer { candidateRecord.wipeOpaqueKeyRepresentation() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var encoded = try encoder.encode(candidateRecord)
        defer { encoded.secureErase() }
        guard encoded.count <= SecureEnclaveMLDSAIdentityRecord.maximumEncodedSize else {
            throw DeviceIdentityKeyError.corruptIdentityAuthority(
                "Secure Enclave protocol identity record exceeds its size bound"
            )
        }

        let scope = try resolvedSharedIdentityKeychainScope().authoritativeOnly()
        _ = try KeychainManager.shared.insertKeyIfAbsent(
            data: encoded,
            service: secureEnclaveMLDSAService,
            account: secureEnclaveMLDSAAccount(for: algorithm),
            scope: scope
        )
        guard let winner = try loadSecureEnclaveMLDSARecord(for: algorithm) else {
            throw DeviceIdentityKeyError.corruptIdentityAuthority(
                "Secure Enclave protocol identity winner is missing after compare-and-set"
            )
        }
        let material = try await restoreSecureEnclaveMLDSARecord(winner)
        cachedSecureEnclaveMLDSAIdentities[algorithm] = material
        return (material.publicKey, .callback(material.signingCallback))
    }

    private func loadSecureEnclaveMLDSARecord(
        for algorithm: ProtocolSigningAlgorithm
    ) throws -> SecureEnclaveMLDSAIdentityRecord? {
        let scope = try resolvedSharedIdentityKeychainScope().authoritativeOnly()
        let account = secureEnclaveMLDSAAccount(for: algorithm)
        if let preferred = try loadSecureEnclaveMLDSARecord(
            for: algorithm,
            account: account,
            scope: scope
        ) {
            return preferred
        }

        // Pre-release builds used only the algorithm as the account. Copy that
        // immutable record into the versioned `(algorithm, protection)` slot;
        // the old item is intentionally retained for rollback/read compatibility.
        guard let legacy = try loadSecureEnclaveMLDSARecord(
            for: algorithm,
            account: algorithm.rawValue,
            scope: scope
        ) else {
            return nil
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var encoded = try encoder.encode(legacy)
        defer { encoded.secureErase() }
        _ = try KeychainManager.shared.insertKeyIfAbsent(
            data: encoded,
            service: secureEnclaveMLDSAService,
            account: account,
            scope: scope
        )
        guard let winner = try loadSecureEnclaveMLDSARecord(
            for: algorithm,
            account: account,
            scope: scope
        ), winner == legacy else {
            throw DeviceIdentityKeyError.corruptIdentityAuthority(
                "Secure Enclave protocol identity migration produced a conflicting winner"
            )
        }
        return winner
    }

    private func secureEnclaveMLDSAAccount(
        for algorithm: ProtocolSigningAlgorithm
    ) -> String {
        "protocol-signing|\(algorithm.rawValue)|\(ProtocolSigningKeyProtection.secureEnclaveRequired.rawValue)|v1"
    }

    private func loadSecureEnclaveMLDSARecord(
        for algorithm: ProtocolSigningAlgorithm,
        account: String,
        scope: KeychainGenericPasswordScope
    ) throws -> SecureEnclaveMLDSAIdentityRecord? {
        guard var encoded = try KeychainManager.shared.exportKeyStrict(
            service: secureEnclaveMLDSAService,
            account: account,
            scope: scope,
            includeLegacyKeychain: false
        ) else {
            return nil
        }
        defer { encoded.secureErase() }
        guard encoded.count <= SecureEnclaveMLDSAIdentityRecord.maximumEncodedSize else {
            throw DeviceIdentityKeyError.corruptIdentityAuthority(
                "Secure Enclave protocol identity record exceeds its size bound"
            )
        }
        return try JSONDecoder().decode(
            SecureEnclaveMLDSAIdentityRecord.self,
            from: encoded
        ).validated(for: algorithm)
    }

    private func restoreSecureEnclaveMLDSARecord(
        _ record: SecureEnclaveMLDSAIdentityRecord
    ) async throws -> SecureEnclaveMLDSAIdentityMaterial {
        guard #available(macOS 26.0, iOS 26.0, *) else {
            throw SecureEnclaveMLDSAIdentityError.sdkUnavailable
        }
        return try await SecureEnclaveMLDSAIdentityFactory.restore(
            algorithm: record.algorithm,
            publicKey: record.publicKey,
            opaqueKeyRepresentation: record.opaqueKeyRepresentation
        )
    }

 // MARK: - ML-DSA-65 Protocol Signing Key Helpers ( 11.2, 11.3)
    
 /// 获取或创建 ML-DSA-65 协议签名密钥。
 ///
 /// v3 uses one add-only Keychain item as the sole authority. Legacy split
 /// public/private items are accepted only as a complete, cryptographically
 /// matched migration input.
    public func getOrCreateMLDSASigningKey() async throws -> (publicKey: Data, keyHandle: SigningKeyHandle) {
        if let cached = cachedMLDSASigningKey {
            return (publicKey: cached.publicKey, keyHandle: .softwareKey(cached.privateKey))
        }

        do {
            let record = try PQCKeyPairStore.loadOrCreate(
                descriptor: mldsaStoreDescriptor,
                publicKeyLength: KeychainConstants.mldsaPublicKeyLength,
                privateKeyLength: KeychainConstants.mldsaPrivateKeyLength,
                legacyKeyPair: mldsaLegacyKeyPair,
                validatePair: validateMLDSARecord,
                generate: generateMLDSARecord
            )
            let resolved = (publicKey: record.publicKey, privateKey: record.privateKey)
            saveMirroredData(resolved.publicKey, forKey: mldsaMirrorDefaultsKey)
            cachedMLDSASigningKey = resolved
            SkyBridgeLogger.p2p.info("Resolved canonical ML-DSA-65 protocol signing key")
            return (
                publicKey: resolved.publicKey,
                keyHandle: .softwareKey(resolved.privateKey)
            )
        } catch {
            throw translateMLDSAStorageError(error)
        }
    }

    private func generateMLDSARecord() throws -> PQCKeyPairRecord {
        #if canImport(OQSRAII)
        let pkLen = oqs_raii_mldsa65_public_key_length()
        let skLen = oqs_raii_mldsa65_secret_key_length()
        guard pkLen == KeychainConstants.mldsaPublicKeyLength,
              skLen == KeychainConstants.mldsaPrivateKeyLength,
              oqs_raii_mldsa65_signature_length() == KeychainConstants.mldsaSignatureLength else {
            throw DeviceIdentityKeyError.keyGenerationFailed(
                "ML-DSA-65 runtime length contract mismatch"
            )
        }

        var publicKeyBytes = [UInt8](repeating: 0, count: Int(pkLen))
        var privateKeyBytes = [UInt8](repeating: 0, count: Int(skLen))
        defer {
            PQCKeyPairRecordCodec.wipe(&publicKeyBytes)
            PQCKeyPairRecordCodec.wipe(&privateKeyBytes)
        }

        let result = oqs_raii_mldsa65_keypair(
            &publicKeyBytes, pkLen,
            &privateKeyBytes, skLen
        )

        guard result == OQSRAII_SUCCESS else {
            throw DeviceIdentityKeyError.keyGenerationFailed("ML-DSA-65 keypair generation failed")
        }
        return PQCKeyPairRecord(
            algorithmIdentifier: mldsaStoreDescriptor.algorithmIdentifier,
            publicKey: Data(publicKeyBytes),
            privateKey: Data(privateKeyBytes)
        )
        #else
        throw DeviceIdentityKeyError.keyGenerationFailed("OQSRAII not available")
        #endif
    }

    private func loadMLDSASigningKey() throws -> (publicKey: Data, privateKey: Data)? {
        do {
            guard let record = try PQCKeyPairStore.loadOrMigrateLegacy(
                descriptor: mldsaStoreDescriptor,
                publicKeyLength: KeychainConstants.mldsaPublicKeyLength,
                privateKeyLength: KeychainConstants.mldsaPrivateKeyLength,
                legacyKeyPair: mldsaLegacyKeyPair,
                validatePair: validateMLDSARecord
            ) else {
                return nil
            }
            saveMirroredData(record.publicKey, forKey: mldsaMirrorDefaultsKey)
            return (publicKey: record.publicKey, privateKey: record.privateKey)
        } catch {
            throw translateMLDSAStorageError(error)
        }
    }

    private func validateMLDSARecord(_ record: PQCKeyPairRecord) throws {
        try validateMLDSAKeyPair(
            publicKey: record.publicKey,
            privateKey: record.privateKey
        )
    }

    private func translateMLDSAStorageError(_ error: Error) -> Error {
        if let keychainError = error as? KeychainError {
            switch keychainError {
            case .itemNotFound:
                return DeviceIdentityKeyError.keyNotFound
            case .unexpectedError(let status):
                return DeviceIdentityKeyError.keychainError(status)
            case .decodingError:
                return DeviceIdentityKeyError.incompleteKeyMaterial(
                    "ML-DSA-65 canonical Keychain item could not be decoded"
                )
            case .itemChangedDuringReconciliation,
                 .immutableStateCorrupt,
                 .immutableStateCycleRejected,
                 .immutableStateTransitionLimitExceeded:
                // Not ML-DSA storage semantics; propagate untranslated.
                return keychainError
            }
        }
        if error is PQCKeyPairRecordCodecError {
            return DeviceIdentityKeyError.incompleteKeyMaterial(
                "ML-DSA-65 canonical record failed strict decoding"
            )
        }
        if let storeError = error as? PQCKeyPairStoreError {
            switch storeError {
            case .incompleteLegacyKeyPair:
                return DeviceIdentityKeyError.incompleteKeyMaterial(
                    "ML-DSA-65 public/private keypair is incomplete (legacy split record)"
                )
            case .conflictingLegacyKeyPair:
                return DeviceIdentityKeyError.authorityConflict(
                    "Conflicting ML-DSA-65 canonical and legacy key material"
                )
            case .canonicalRecordMissingAfterInsert:
                return DeviceIdentityKeyError.incompleteKeyMaterial(
                    "ML-DSA-65 canonical record disappeared after atomic insertion"
                )
            default:
                return storeError
            }
        }
        return error
    }

    private func validateMLDSAKeyPair(publicKey: Data, privateKey: Data) throws {
        #if canImport(OQSRAII)
        guard publicKey.count == KeychainConstants.mldsaPublicKeyLength,
              privateKey.count == KeychainConstants.mldsaPrivateKeyLength,
              oqs_raii_mldsa65_public_key_length() == KeychainConstants.mldsaPublicKeyLength,
              oqs_raii_mldsa65_secret_key_length() == KeychainConstants.mldsaPrivateKeyLength,
              oqs_raii_mldsa65_signature_length() == KeychainConstants.mldsaSignatureLength else {
            throw DeviceIdentityKeyError.incompleteKeyMaterial(
                "ML-DSA-65 keypair violates the fixed-length contract"
            )
        }

        let challenge = Array("SkyBridge ML-DSA-65 canonical keypair validation v3".utf8)
        var signature = [UInt8](
            repeating: 0,
            count: KeychainConstants.mldsaSignatureLength
        )
        defer {
            PQCKeyPairRecordCodec.wipe(&signature)
        }
        var signatureLength = signature.count

        let signResult = challenge.withUnsafeBufferPointer { message in
            privateKey.withUnsafeBytes { secretKey in
                oqs_raii_mldsa65_sign(
                    message.baseAddress,
                    message.count,
                    secretKey.bindMemory(to: UInt8.self).baseAddress,
                    privateKey.count,
                    &signature,
                    &signatureLength
                )
            }
        }
        guard signResult == OQSRAII_SUCCESS,
              signatureLength == KeychainConstants.mldsaSignatureLength else {
            throw DeviceIdentityKeyError.incompleteKeyMaterial(
                "ML-DSA-65 private key failed the validation challenge"
            )
        }

        let verified = challenge.withUnsafeBufferPointer { message in
            publicKey.withUnsafeBytes { publicKeyBytes in
                signature.withUnsafeBufferPointer { signatureBytes in
                    oqs_raii_mldsa65_verify(
                        message.baseAddress,
                        message.count,
                        signatureBytes.baseAddress,
                        signatureLength,
                        publicKeyBytes.bindMemory(to: UInt8.self).baseAddress,
                        publicKey.count
                    )
                }
            }
        }
        guard verified else {
            throw DeviceIdentityKeyError.incompleteKeyMaterial(
                "ML-DSA-65 public/private keys failed pair validation"
            )
        }
        #else
        throw DeviceIdentityKeyError.keyGenerationFailed("OQSRAII not available")
        #endif
    }

    #if DEBUG || SKYBRIDGE_TESTING
    private nonisolated static func testingMLDSAService(namespace: String) -> String {
        KeychainConstants.mldsaService + ".testing." + namespace
    }

    private nonisolated static func testingMLDSAMirrorDefaultsKey(namespace: String) -> String {
        KeychainConstants.mirroredMLDSAPublicKeyDefaultsKey + ".testing." + namespace
    }

    private nonisolated static func testingMLDSAKeychainScope(
        namespace: String
    ) -> KeychainGenericPasswordScope {
        let accessGroup = "group.com.skybridge.tests.device-identity.\(namespace)"
        return KeychainGenericPasswordScope(
            accessibility: .afterFirstUnlockThisDeviceOnly,
            writeAccessGroup: accessGroup,
            readAccessGroups: [accessGroup, nil],
            usesDataProtectionKeychain: true,
            synchronizable: false
        )
    }

    private nonisolated static func testingMLDSALocation(
        namespace: String,
        account: String
    ) -> KeychainGenericPasswordLocation {
        KeychainGenericPasswordLocation(
            service: testingMLDSAService(namespace: namespace),
            account: account
        )
    }

    private nonisolated static func testingSetMLDSAStorageData(
        _ data: Data?,
        location: KeychainGenericPasswordLocation,
        namespace: String
    ) throws {
        let keychainScope = testingMLDSAKeychainScope(namespace: namespace)
        try KeychainManager.shared.deleteAPIKey(
            service: location.service,
            account: location.account,
            scope: keychainScope
        )
        if let data {
            _ = try KeychainManager.shared.insertKeyIfAbsent(
                data: data,
                service: location.service,
                account: location.account,
                scope: keychainScope
            )
        }
    }

    internal nonisolated static func testingResetMLDSAStorage(namespace: String) throws {
        let service = testingMLDSAService(namespace: namespace)
        let keychainScope = testingMLDSAKeychainScope(namespace: namespace)
        for account in [
            KeychainConstants.mldsaCanonicalKeyPairAccount,
            KeychainConstants.mldsaPublicKeyAccount,
            KeychainConstants.mldsaSecretKeyAccount
        ] {
            try KeychainManager.shared.deleteAPIKey(
                service: service,
                account: account,
                scope: keychainScope
            )
        }
        try PQCBackendAuthorityStore.deleteForTesting(
            domain: .testing("device-protocol-signing.\(namespace)"),
            scopeSource: .explicitForTesting(keychainScope)
        )
        UserDefaults.standard.removeObject(
            forKey: testingMLDSAMirrorDefaultsKey(namespace: namespace)
        )
    }

    internal nonisolated static func testingSeedLegacyMLDSAStorage(
        namespace: String,
        publicKey: Data?,
        privateKey: Data?
    ) throws {
        try testingSetMLDSAStorageData(
            publicKey,
            location: testingMLDSALocation(
                namespace: namespace,
                account: KeychainConstants.mldsaPublicKeyAccount
            ),
            namespace: namespace
        )
        try testingSetMLDSAStorageData(
            privateKey,
            location: testingMLDSALocation(
                namespace: namespace,
                account: KeychainConstants.mldsaSecretKeyAccount
            ),
            namespace: namespace
        )
    }

    internal nonisolated static func testingSeedCanonicalMLDSAStorage(
        namespace: String,
        encodedRecord: Data
    ) throws {
        try testingSetMLDSAStorageData(
            encodedRecord,
            location: testingMLDSALocation(
                namespace: namespace,
                account: KeychainConstants.mldsaCanonicalKeyPairAccount
            ),
            namespace: namespace
        )
    }

    internal nonisolated static func testingHasCanonicalMLDSARecord(
        namespace: String
    ) throws -> Bool {
        let keychainScope = testingMLDSAKeychainScope(namespace: namespace)
        let location = testingMLDSALocation(
            namespace: namespace,
            account: KeychainConstants.mldsaCanonicalKeyPairAccount
        )
        return try KeychainManager.shared.exportKeyStrict(
            service: location.service,
            account: location.account,
            scope: keychainScope,
            includeLegacyKeychain: true
        ) != nil
    }

    internal nonisolated static func testingSetMirroredMLDSAPublicKey(
        _ publicKey: Data?,
        namespace: String
    ) {
        let key = testingMLDSAMirrorDefaultsKey(namespace: namespace)
        if let publicKey {
            UserDefaults.standard.set(publicKey, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    internal nonisolated static func testingMirroredMLDSAPublicKey(
        namespace: String
    ) -> Data? {
        UserDefaults.standard.data(
            forKey: testingMLDSAMirrorDefaultsKey(namespace: namespace)
        )
    }
    #endif

 // MARK: - SE PoP Key Helpers ( 5.2)
    
 /// 获取 SE PoP 密钥引用
    private func getSEPoPKeyReference() throws -> SecKey? {
        if Self.useInMemoryKeychain { return nil }
        do {
            let store = try identityAuthorityStore()
            guard let authority = try DeviceIdentityAuthorityTransaction.resolve(
                using: store
            ), authority.isSecureEnclave else {
                return nil
            }
            return try store.loadAuthoritativePrivateKey(
                applicationTag: authority.privateKeyApplicationTag
            )
        } catch {
            throw Self.publicIdentityError(for: error)
        }
    }
}

// MARK: - KeyPurpose

/// 密钥用途枚举
///
/// **Requirements: 5.4**
public enum KeyPurpose: String, Sendable {
 /// 旧 P-256 身份密钥（迁移前）
    case legacy = "legacy"

    /// 当前 immutable authority 引用的 unique-tag P-256 身份密钥
    case identity = "identity"
    
 /// Ed25519/ML-DSA 协议签名密钥
    case `protocol` = "protocol"
    
 /// P-256 SE PoP 密钥（迁移后）
    case pop = "pop"
    
 /// 未知用途
    case unknown = "unknown"
}
