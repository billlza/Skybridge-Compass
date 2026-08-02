import CryptoKit
import Foundation
import Security

@available(iOS 17.0, *)
public enum ProtocolSigningKeyProtection: String, Codable, Sendable, CaseIterable {
    case softwareKeychain = "software-keychain"
    case secureEnclaveRequired = "secure-enclave-required"
}

@available(iOS 17.0, *)
struct ProtocolSigningIdentitySlot: Hashable, Sendable {
    let algorithm: ProtocolSigningAlgorithm
    let keyProtection: ProtocolSigningKeyProtection

    init(
        algorithm: ProtocolSigningAlgorithm,
        keyProtection: ProtocolSigningKeyProtection
    ) throws {
        guard algorithm != .ed25519 || keyProtection == .softwareKeychain else {
            throw ProtocolDeviceIdentityError.unsupportedKeyProtection(
                algorithm,
                keyProtection
            )
        }
        self.algorithm = algorithm
        self.keyProtection = keyProtection
    }

    /// Preserve the pre-v2 account for software identities so deployed
    /// ML-DSA-65/Ed25519 keys remain byte-identical. Hardware-backed identities
    /// occupy a distinct immutable slot and can therefore coexist safely.
    var persistenceAccount: String {
        switch keyProtection {
        case .softwareKeychain:
            return algorithm.rawValue
        case .secureEnclaveRequired:
            return "v2|\(algorithm.rawValue)|\(keyProtection.rawValue)"
        }
    }
}

@available(iOS 17.0, *)
struct ProtocolIdentityConfigurationRecord: Codable, Equatable, Sendable {
    static let currentVersion: UInt8 = 1
    static let maximumEncodedSize = 512

    let version: UInt8
    let algorithm: ProtocolSigningAlgorithm
    let keyProtection: ProtocolSigningKeyProtection

    init(
        version: UInt8 = Self.currentVersion,
        algorithm: ProtocolSigningAlgorithm,
        keyProtection: ProtocolSigningKeyProtection
    ) {
        self.version = version
        self.algorithm = algorithm
        self.keyProtection = keyProtection
    }

    func validated() throws -> Self {
        guard version == Self.currentVersion,
              algorithm != .ed25519 else {
            throw ProtocolDeviceIdentityError.corruptIdentityConfiguration
        }
        _ = try ProtocolSigningIdentitySlot(
            algorithm: algorithm,
            keyProtection: keyProtection
        )
        return self
    }

    func canonicalEncodedData() throws -> Data {
        let record = try validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        guard !data.isEmpty, data.count <= Self.maximumEncodedSize else {
            throw ProtocolDeviceIdentityError.corruptIdentityConfiguration
        }
        return data
    }

    static func decodeCanonical(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumEncodedSize else {
            throw ProtocolDeviceIdentityError.corruptIdentityConfiguration
        }
        let decoded: Self
        do {
            decoded = try JSONDecoder().decode(Self.self, from: data).validated()
        } catch {
            throw ProtocolDeviceIdentityError.corruptIdentityConfiguration
        }
        guard try decoded.canonicalEncodedData() == data else {
            throw ProtocolDeviceIdentityError.corruptIdentityConfiguration
        }
        return decoded
    }
}

@available(iOS 17.0, *)
enum ProtocolIdentityConfigurationResolution: Equatable, Sendable {
    case authoritative(ProtocolIdentityConfigurationRecord)
    case freshInstallDefault(ProtocolIdentityConfigurationRecord)
    case requiresExplicitConfirmation

    var effectiveConfiguration: ProtocolIdentityConfigurationRecord {
        switch self {
        case .authoritative(let configuration),
             .freshInstallDefault(let configuration):
            return configuration
        case .requiresExplicitConfirmation:
            return ProtocolIdentityConfigurationRecord(
                algorithm: .mlDSA65,
                keyProtection: .softwareKeychain
            )
        }
    }

    var needsExplicitConfirmation: Bool {
        if case .requiresExplicitConfirmation = self { return true }
        return false
    }
}

@available(iOS 17.0, *)
enum ProtocolSigningIdentityPolicy {
    static let configurationDefaultsKey = "Settings.ProtocolSigningIdentityConfiguration.v1"
    // Pre-release split keys are read only by the exact-slot migration below.
    static let algorithmDefaultsKey = "Settings.ProtocolSigningAlgorithm.v1"
    static let protectionDefaultsKey = "Settings.ProtocolSigningKeyProtection.v1"

    private static let fallbackConfiguration = ProtocolIdentityConfigurationRecord(
        algorithm: .mlDSA65,
        keyProtection: .softwareKeychain
    )

    static func configurationResolution(
        defaults: UserDefaults = .standard,
        legacySlotExists: ((ProtocolSigningIdentitySlot) -> Bool)? = nil
    ) -> ProtocolIdentityConfigurationResolution {
        if defaults.object(forKey: configurationDefaultsKey) != nil {
            guard let data = defaults.data(forKey: configurationDefaultsKey),
                  let record = try? ProtocolIdentityConfigurationRecord
                    .decodeCanonical(data) else {
                return .requiresExplicitConfirmation
            }
            return .authoritative(record)
        }

        let legacyAlgorithm = defaults.object(forKey: algorithmDefaultsKey)
        let legacyProtection = defaults.object(forKey: protectionDefaultsKey)
        guard legacyAlgorithm != nil || legacyProtection != nil else {
            return .freshInstallDefault(fallbackConfiguration)
        }
        guard let algorithmRaw = legacyAlgorithm as? String,
              let protectionRaw = legacyProtection as? String,
              let algorithm = ProtocolSigningAlgorithm(rawValue: algorithmRaw),
              algorithm != .ed25519,
              let protection = ProtocolSigningKeyProtection(rawValue: protectionRaw),
              let slot = try? ProtocolSigningIdentitySlot(
                algorithm: algorithm,
                keyProtection: protection
              ),
              (legacySlotExists ?? exactPersistedSlotExists)(slot) else {
            // Partial, conflicting, or unverifiable pre-release intent is not
            // authoritative. The user must explicitly apply it again.
            return .requiresExplicitConfirmation
        }

        let migrated = ProtocolIdentityConfigurationRecord(
            algorithm: algorithm,
            keyProtection: protection
        )
        guard let encoded = try? migrated.canonicalEncodedData() else {
            return .requiresExplicitConfirmation
        }
        defaults.set(encoded, forKey: configurationDefaultsKey)
        guard defaults.data(forKey: configurationDefaultsKey) == encoded else {
            defaults.removeObject(forKey: configurationDefaultsKey)
            return .requiresExplicitConfirmation
        }
        defaults.removeObject(forKey: algorithmDefaultsKey)
        defaults.removeObject(forKey: protectionDefaultsKey)
        return .authoritative(migrated)
    }

    static func requestedConfiguration(
        defaults: UserDefaults = .standard,
        legacySlotExists: ((ProtocolSigningIdentitySlot) -> Bool)? = nil
    ) -> ProtocolIdentityConfigurationRecord {
        configurationResolution(
            defaults: defaults,
            legacySlotExists: legacySlotExists
        ).effectiveConfiguration
    }

    static func requiredConfiguration(
        defaults: UserDefaults = .standard
    ) throws -> ProtocolIdentityConfigurationRecord {
        let resolution = configurationResolution(defaults: defaults)
        guard !resolution.needsExplicitConfirmation else {
            throw ProtocolDeviceIdentityError.corruptIdentityConfiguration
        }
        return resolution.effectiveConfiguration
    }

    static func requestedPQCAlgorithm(
        defaults: UserDefaults = .standard
    ) -> ProtocolSigningAlgorithm {
        requestedConfiguration(defaults: defaults).algorithm
    }

    static func requestedProtection(
        defaults: UserDefaults = .standard
    ) -> ProtocolSigningKeyProtection {
        requestedConfiguration(defaults: defaults).keyProtection
    }

    static func requestedProtection(
        for algorithm: ProtocolSigningAlgorithm,
        defaults: UserDefaults = .standard
    ) -> ProtocolSigningKeyProtection {
        let configuration = requestedConfiguration(defaults: defaults)
        guard algorithm != .ed25519,
              algorithm == configuration.algorithm else {
            return .softwareKeychain
        }
        return configuration.keyProtection
    }

    static func persist(
        _ configuration: ProtocolIdentityConfigurationRecord,
        defaults: UserDefaults = .standard
    ) throws {
        let encoded = try configuration.canonicalEncodedData()
        defaults.set(encoded, forKey: configurationDefaultsKey)
        guard defaults.data(forKey: configurationDefaultsKey) == encoded else {
            defaults.removeObject(forKey: configurationDefaultsKey)
            throw ProtocolDeviceIdentityError.corruptIdentityConfiguration
        }
        defaults.removeObject(forKey: algorithmDefaultsKey)
        defaults.removeObject(forKey: protectionDefaultsKey)
    }

    private static func exactPersistedSlotExists(
        _ slot: ProtocolSigningIdentitySlot
    ) -> Bool {
        do {
            let persistence = try IOSProtocolIdentityKeychainStore()
            guard let keyData = try persistence.loadSigningKey(for: slot),
                  !keyData.isEmpty,
                  keyData.count <= ProtocolSigningIdentityMaterial.maximumEncodedSize,
                  let authorityData = try persistence.loadSigningAuthority(for: slot),
                  !authorityData.isEmpty,
                  authorityData.count <= ProtocolSigningAuthorityRecord.maximumEncodedSize else {
                return false
            }
            let material = try JSONDecoder()
                .decode(ProtocolSigningIdentityMaterial.self, from: keyData)
                .validated(for: slot.algorithm)
            let authority = try JSONDecoder()
                .decode(ProtocolSigningAuthorityRecord.self, from: authorityData)
                .validated()
            let fingerprint = SHA256.hash(data: material.publicKey)
                .map { String(format: "%02x", $0) }
                .joined()
            return material.keyProtection == slot.keyProtection
                && authority.algorithm == slot.algorithm
                && authority.keyProtection == slot.keyProtection
                && authority.publicKeyFingerprint == fingerprint
        } catch {
            return false
        }
    }
}

@available(iOS 17.0, *)
enum ProtocolIdentityKeychainStage: String, Sendable, Equatable {
    case loadDeviceAuthority
    case insertDeviceAuthority
    case loadSigningKey
    case insertSigningKey
    case loadSigningAuthority
    case insertSigningAuthority
    case queryLegacyDeviceIdentity
    case queryLegacySigningIdentity
    case reloadLegacyItem
    case deleteLegacyItem
}

enum ProtocolDeviceIdentityError: Error, LocalizedError, Sendable, Equatable {
    case invalidDeviceId
    case invalidSmokeOverride
    case smokeOverrideAfterResolution
    case conflictingLegacyDeviceIds
    case corruptAuthorityRecord
    case corruptIdentityConfiguration
    case authorityWinnerMissing
    case signingKeyMissing(ProtocolSigningAlgorithm)
    case corruptSigningKey(ProtocolSigningAlgorithm)
    case signingAuthorityConflict(ProtocolSigningAlgorithm)
    case legacySigningIdentityConflict(ProtocolSigningAlgorithm)
    case applePQCSDKUnavailable
    case secureEnclaveMLDSAUnsupportedPlatform
    case secureEnclaveUnavailable
    case unsupportedKeyProtection(
        ProtocolSigningAlgorithm,
        ProtocolSigningKeyProtection
    )
    case legacyItemChangedDuringReconciliation
    case missingSharedKeychainAccessGroup
    case keychainProbeFailed(OSStatus)
    case corruptKeychainProbeResult
    case keychainProbeCleanupFailed(OSStatus)
    case keychainOperationFailed(stage: ProtocolIdentityKeychainStage, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidDeviceId:
            return "Protocol identity contains an invalid device ID"
        case .invalidSmokeOverride:
            return "Smoke identity override is invalid or was not injected from an explicit smoke launch"
        case .smokeOverrideAfterResolution:
            return "Smoke identity override must be configured before persistent identity resolution"
        case .conflictingLegacyDeviceIds:
            return "Legacy device identity sources disagree; automatic migration is unsafe"
        case .corruptAuthorityRecord:
            return "Protocol identity authority record is corrupt"
        case .corruptIdentityConfiguration:
            return "Protocol identity configuration record is corrupt"
        case .authorityWinnerMissing:
            return "Protocol identity authority winner is missing after compare-and-set"
        case .signingKeyMissing(let algorithm):
            return "Protocol identity authority is missing its \(algorithm.rawValue) signing key"
        case .corruptSigningKey(let algorithm):
            return "Protocol identity contains corrupt \(algorithm.rawValue) signing key material"
        case .signingAuthorityConflict(let algorithm):
            return "Protocol identity \(algorithm.rawValue) authority conflicts with its immutable key"
        case .legacySigningIdentityConflict(let algorithm):
            return "Legacy \(algorithm.rawValue) signing identities disagree with the shared authority"
        case .applePQCSDKUnavailable:
            return "Apple PQC SDK support is not compiled into this build"
        case .secureEnclaveMLDSAUnsupportedPlatform:
            return "Secure Enclave ML-DSA requires iOS 26 or newer on a physical device"
        case .secureEnclaveUnavailable:
            return "Secure Enclave ML-DSA is unavailable in this runtime; no software fallback was used"
        case .unsupportedKeyProtection(let algorithm, let protection):
            return "\(protection.rawValue) is not supported for \(algorithm.rawValue)"
        case .legacyItemChangedDuringReconciliation:
            return "A legacy identity item changed during exact reconciliation"
        case .missingSharedKeychainAccessGroup:
            return "The signed app is missing the shared SkyBridge Keychain access-group entitlement"
        case .keychainProbeFailed(let status):
            return "Unable to resolve the signed app Keychain access group: \(status)"
        case .corruptKeychainProbeResult:
            return "The Keychain access-group probe returned malformed attributes"
        case .keychainProbeCleanupFailed(let status):
            return "The Keychain access-group probe could not be removed exactly: \(status)"
        case .keychainOperationFailed(let stage, let status):
            return "Protocol identity Keychain operation \(stage.rawValue) failed: \(status)"
        }
    }
}

@available(iOS 17.0, *)
struct ProtocolSigningIdentityMaterial: Codable, Equatable, Sendable {
    static let legacySoftwareVersion: UInt8 = 1
    static let currentVersion: UInt8 = 2
    static let maximumEncodedSize = 96 * 1_024

    let version: UInt8
    let algorithm: ProtocolSigningAlgorithm
    let keyProtection: ProtocolSigningKeyProtection
    private(set) var privateKeyRepresentation: Data
    let publicKey: Data

    init(
        version: UInt8? = nil,
        algorithm: ProtocolSigningAlgorithm,
        privateKey: Data,
        publicKey: Data,
        keyProtection: ProtocolSigningKeyProtection = .softwareKeychain
    ) {
        self.version = version ?? (
            keyProtection == .softwareKeychain
                ? Self.legacySoftwareVersion
                : Self.currentVersion
        )
        self.algorithm = algorithm
        self.keyProtection = keyProtection
        self.privateKeyRepresentation = privateKey
        self.publicKey = publicKey
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case algorithm
        case keyProtection
        case privateKeyRepresentation = "privateKey"
        case publicKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(UInt8.self, forKey: .version)
        algorithm = try container.decode(
            ProtocolSigningAlgorithm.self,
            forKey: .algorithm
        )
        keyProtection = try container.decodeIfPresent(
            ProtocolSigningKeyProtection.self,
            forKey: .keyProtection
        ) ?? .softwareKeychain
        privateKeyRepresentation = try container.decode(
            Data.self,
            forKey: .privateKeyRepresentation
        )
        publicKey = try container.decode(Data.self, forKey: .publicKey)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(algorithm, forKey: .algorithm)
        try container.encode(keyProtection, forKey: .keyProtection)
        try container.encode(
            privateKeyRepresentation,
            forKey: .privateKeyRepresentation
        )
        try container.encode(publicKey, forKey: .publicKey)
    }

    func validated(for expectedAlgorithm: ProtocolSigningAlgorithm) throws -> Self {
        let supportedVersion = version == Self.currentVersion
            || (version == Self.legacySoftwareVersion
                && keyProtection == .softwareKeychain)
        let expectedPublicKeyLength: Int
        switch expectedAlgorithm {
        case .ed25519: expectedPublicKeyLength = 32
        case .mlDSA65: expectedPublicKeyLength = 1_952
        case .mlDSA87: expectedPublicKeyLength = 2_592
        }
        guard supportedVersion,
              algorithm == expectedAlgorithm,
              !privateKeyRepresentation.isEmpty,
              !publicKey.isEmpty,
              privateKeyRepresentation.count <= 64 * 1_024,
              publicKey.count == expectedPublicKeyLength else {
            throw ProtocolDeviceIdentityError.corruptSigningKey(expectedAlgorithm)
        }
        guard expectedAlgorithm != .ed25519
                || keyProtection == .softwareKeychain else {
            throw ProtocolDeviceIdentityError.unsupportedKeyProtection(
                expectedAlgorithm,
                keyProtection
            )
        }
        return self
    }

    mutating func wipePrivateKey() {
        privateKeyRepresentation.resetBytes(
            in: privateKeyRepresentation.startIndex..<privateKeyRepresentation.endIndex
        )
    }
}

@available(iOS 26.0, macOS 26.0, *)
actor IOSSecureEnclaveMLDSASigningCallback: SigningCallback {
    private let algorithm: ProtocolSigningAlgorithm
    private let opaqueKeyRepresentation: Data
    private let expectedPublicKey: Data

    init(
        algorithm: ProtocolSigningAlgorithm,
        opaqueKeyRepresentation: Data,
        expectedPublicKey: Data
    ) throws {
        self.algorithm = algorithm
        self.opaqueKeyRepresentation = opaqueKeyRepresentation
        self.expectedPublicKey = expectedPublicKey
        guard try Self.restoredPublicKey(
            algorithm: algorithm,
            representation: opaqueKeyRepresentation
        ) == expectedPublicKey else {
            throw ProtocolDeviceIdentityError.corruptSigningKey(algorithm)
        }
    }

    func sign(data: Data) async throws -> Data {
        #if targetEnvironment(simulator)
        throw ProtocolDeviceIdentityError.secureEnclaveUnavailable
        #else
        #if HAS_APPLE_PQC_SDK
        guard SecureEnclave.isAvailable else {
            throw ProtocolDeviceIdentityError.secureEnclaveUnavailable
        }
        let signature: Data
        switch algorithm {
        case .mlDSA65:
            signature = try SecureEnclave.MLDSA65.PrivateKey(
                dataRepresentation: opaqueKeyRepresentation
            ).signature(for: data)
        case .mlDSA87:
            signature = try SecureEnclave.MLDSA87.PrivateKey(
                dataRepresentation: opaqueKeyRepresentation
            ).signature(for: data)
        case .ed25519:
            throw ProtocolDeviceIdentityError.unsupportedKeyProtection(
                algorithm,
                .secureEnclaveRequired
            )
        }
        let expectedLength = algorithm == .mlDSA65 ? 3_309 : 4_627
        guard signature.count == expectedLength else {
            throw ProtocolDeviceIdentityError.corruptSigningKey(algorithm)
        }
        return signature
        #else
        throw ProtocolDeviceIdentityError.applePQCSDKUnavailable
        #endif
        #endif
    }

    private static func restoredPublicKey(
        algorithm: ProtocolSigningAlgorithm,
        representation: Data
    ) throws -> Data {
        #if targetEnvironment(simulator)
        throw ProtocolDeviceIdentityError.secureEnclaveUnavailable
        #else
        #if HAS_APPLE_PQC_SDK
        switch algorithm {
        case .mlDSA65:
            return try SecureEnclave.MLDSA65.PrivateKey(
                dataRepresentation: representation
            ).publicKey.rawRepresentation
        case .mlDSA87:
            return try SecureEnclave.MLDSA87.PrivateKey(
                dataRepresentation: representation
            ).publicKey.rawRepresentation
        case .ed25519:
            throw ProtocolDeviceIdentityError.unsupportedKeyProtection(
                algorithm,
                .secureEnclaveRequired
            )
        }
        #else
        throw ProtocolDeviceIdentityError.applePQCSDKUnavailable
        #endif
        #endif
    }
}

@available(iOS 17.0, *)
enum IOSSecureEnclaveMLDSAIdentityFactory {
    static var isAvailable: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        #if HAS_APPLE_PQC_SDK
        if #available(iOS 26.0, macOS 26.0, *) {
            return SecureEnclave.isAvailable
        }
        #endif
        return false
        #endif
    }

    static var unavailabilityReason: String? {
        guard !isAvailable else { return nil }
        #if targetEnvironment(simulator)
        return ProtocolDeviceIdentityError.secureEnclaveUnavailable.localizedDescription
        #else
        #if HAS_APPLE_PQC_SDK
        if #unavailable(iOS 26.0, macOS 26.0) {
            return ProtocolDeviceIdentityError
                .secureEnclaveMLDSAUnsupportedPlatform
                .localizedDescription
        }
        return ProtocolDeviceIdentityError.secureEnclaveUnavailable.localizedDescription
        #else
        return ProtocolDeviceIdentityError.applePQCSDKUnavailable.localizedDescription
        #endif
        #endif
    }

    static func create(
        algorithm: ProtocolSigningAlgorithm
    ) async throws -> ProtocolSigningIdentityMaterial {
        #if targetEnvironment(simulator)
        throw ProtocolDeviceIdentityError.secureEnclaveUnavailable
        #else
        guard #available(iOS 26.0, macOS 26.0, *) else {
            throw ProtocolDeviceIdentityError.secureEnclaveMLDSAUnsupportedPlatform
        }
        #if HAS_APPLE_PQC_SDK
        guard isAvailable else {
            throw ProtocolDeviceIdentityError.secureEnclaveUnavailable
        }
        switch algorithm {
        case .mlDSA65:
            let key = try SecureEnclave.MLDSA65.PrivateKey()
            return ProtocolSigningIdentityMaterial(
                algorithm: algorithm,
                privateKey: key.dataRepresentation,
                publicKey: key.publicKey.rawRepresentation,
                keyProtection: .secureEnclaveRequired
            )
        case .mlDSA87:
            let key = try SecureEnclave.MLDSA87.PrivateKey()
            return ProtocolSigningIdentityMaterial(
                algorithm: algorithm,
                privateKey: key.dataRepresentation,
                publicKey: key.publicKey.rawRepresentation,
                keyProtection: .secureEnclaveRequired
            )
        case .ed25519:
            throw ProtocolDeviceIdentityError.unsupportedKeyProtection(
                algorithm,
                .secureEnclaveRequired
            )
        }
        #else
        throw ProtocolDeviceIdentityError.applePQCSDKUnavailable
        #endif
        #endif
    }

    static func keyHandle(
        for material: ProtocolSigningIdentityMaterial
    ) async throws -> SigningKeyHandle {
        switch material.keyProtection {
        case .softwareKeychain:
            return .softwareKey(material.privateKeyRepresentation)
        case .secureEnclaveRequired:
            guard #available(iOS 26.0, macOS 26.0, *) else {
                throw ProtocolDeviceIdentityError.secureEnclaveMLDSAUnsupportedPlatform
            }
            let callback = try IOSSecureEnclaveMLDSASigningCallback(
                algorithm: material.algorithm,
                opaqueKeyRepresentation: material.privateKeyRepresentation,
                expectedPublicKey: material.publicKey
            )
            let probe = Data("SkyBridge/iOS/SecureEnclaveMLDSA/v1".utf8)
            let signature = try await callback.sign(data: probe)
            let provider = ProtocolSignatureProviderSelector.select(
                for: material.algorithm
            )
            guard try await provider.verify(
                probe,
                signature: signature,
                publicKey: material.publicKey
            ) else {
                throw ProtocolDeviceIdentityError.corruptSigningKey(material.algorithm)
            }
            return .callback(callback)
        }
    }
}

@available(iOS 17.0, *)
struct ProtocolIdentitySnapshot: Equatable, Sendable {
    let deviceId: String
    let signingAlgorithm: ProtocolSigningAlgorithm
    let signingPublicKey: Data
    let signingPublicKeyFingerprint: String
}

@available(iOS 17.0, *)
struct CommittedIOSProtocolIdentitySnapshot: Sendable {
    let snapshot: ProtocolIdentitySnapshot
    let algorithm: ProtocolSigningAlgorithm
    let protection: ProtocolSigningKeyProtection
    let publicKey: Data
    let keyHandle: SigningKeyHandle

    var deviceId: String { snapshot.deviceId }

    var authoritativeFingerprint: String {
        ProtocolIdentityPublicKeys(
            protocolPublicKey: publicKey,
            protocolAlgorithm: algorithm
        ).authoritativeFingerprint.lowercased()
    }
}

@available(iOS 17.0, *)
struct ResolvedProtocolSigningIdentity: Equatable, Sendable {
    let snapshot: ProtocolIdentitySnapshot
    let material: ProtocolSigningIdentityMaterial
}

@available(iOS 17.0, *)
private struct ProtocolDeviceAuthorityRecord: Codable, Equatable, Sendable {
    static let currentVersion: UInt8 = 1
    static let maximumEncodedSize = 1_024

    let version: UInt8
    let deviceId: String

    init(version: UInt8 = currentVersion, deviceId: String) {
        self.version = version
        self.deviceId = deviceId
    }

    func validated() throws -> Self {
        guard version == Self.currentVersion else {
            throw ProtocolDeviceIdentityError.corruptAuthorityRecord
        }
        try ProtocolDeviceIdentity.validateDeviceId(deviceId)
        return self
    }
}

@available(iOS 17.0, *)
private struct ProtocolSigningAuthorityRecord: Codable, Equatable, Sendable {
    static let currentVersion: UInt8 = 1
    static let maximumEncodedSize = 2_048

    let version: UInt8
    let deviceId: String
    let algorithm: ProtocolSigningAlgorithm
    let keyProtection: ProtocolSigningKeyProtection
    let publicKeyFingerprint: String

    init(
        version: UInt8 = currentVersion,
        deviceId: String,
        algorithm: ProtocolSigningAlgorithm,
        keyProtection: ProtocolSigningKeyProtection,
        publicKeyFingerprint: String
    ) {
        self.version = version
        self.deviceId = deviceId
        self.algorithm = algorithm
        self.keyProtection = keyProtection
        self.publicKeyFingerprint = publicKeyFingerprint
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case deviceId
        case algorithm
        case keyProtection
        case publicKeyFingerprint
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(UInt8.self, forKey: .version)
        deviceId = try container.decode(String.self, forKey: .deviceId)
        algorithm = try container.decode(ProtocolSigningAlgorithm.self, forKey: .algorithm)
        keyProtection = try container.decodeIfPresent(
            ProtocolSigningKeyProtection.self,
            forKey: .keyProtection
        ) ?? .softwareKeychain
        publicKeyFingerprint = try container.decode(
            String.self,
            forKey: .publicKeyFingerprint
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(deviceId, forKey: .deviceId)
        try container.encode(algorithm, forKey: .algorithm)
        try container.encode(keyProtection, forKey: .keyProtection)
        try container.encode(publicKeyFingerprint, forKey: .publicKeyFingerprint)
    }

    func validated() throws -> Self {
        guard version == Self.currentVersion,
              !(algorithm == .ed25519 && keyProtection == .secureEnclaveRequired),
              publicKeyFingerprint.count == 64,
              publicKeyFingerprint.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw ProtocolDeviceIdentityError.corruptAuthorityRecord
        }
        try ProtocolDeviceIdentity.validateDeviceId(deviceId)
        return self
    }
}

@available(iOS 17.0, *)
struct ProtocolIdentityLegacyItem: Equatable, Sendable {
    enum Location: Equatable, Sendable {
        case persistentReference(Data)
        case inMemoryLegacyDeviceId
    }

    let location: Location
    var data: Data
}

@available(iOS 17.0, *)
protocol ProtocolIdentityPersistence: Sendable {
    func loadDeviceAuthority() throws -> Data?
    func insertDeviceAuthorityIfAbsent(_ data: Data) throws -> IOSKeychainInsertResult
    func loadSigningKey(for slot: ProtocolSigningIdentitySlot) throws -> Data?
    func insertSigningKeyIfAbsent(
        _ data: Data,
        for slot: ProtocolSigningIdentitySlot
    ) throws -> IOSKeychainInsertResult
    func loadSigningAuthority(for slot: ProtocolSigningIdentitySlot) throws -> Data?
    func insertSigningAuthorityIfAbsent(
        _ data: Data,
        for slot: ProtocolSigningIdentitySlot
    ) throws -> IOSKeychainInsertResult
    func legacyDeviceIdCandidates() throws -> [ProtocolIdentityLegacyItem]
    func legacySigningKeyCandidates(
        for algorithm: ProtocolSigningAlgorithm
    ) throws -> [ProtocolIdentityLegacyItem]
    func deleteLegacyItemIfUnchanged(_ item: ProtocolIdentityLegacyItem) throws
    func legacyDefaultsDeviceIds() -> [String]
    func publishDeviceIdMirrors(_ deviceId: String)
}

@available(iOS 17.0, *)
struct IOSProtocolIdentityKeychainStore: ProtocolIdentityPersistence {
    private static let deviceAuthorityService = "com.skybridge.ios.protocol-identity.device.v1"
    private static let deviceAuthorityAccount = "active"
    private static let signingKeyService = "com.skybridge.ios.protocol-identity.signing-key.v1"
    private static let signingAuthorityService = "com.skybridge.ios.protocol-identity.signing-authority.v1"
    private static let legacyDeviceService = "SkyBridge.Identity"
    private static let legacyDeviceAccount = "DeviceUUID"
    private static let protocolIdentityMirrorDefaultsKey = "SkyBridge.P2P.DeviceIdentity.DeviceID"
    private static let legacyDeviceDefaultsKey = "SkyBridge.DeviceId"

    private let accessGroup: String

    init() throws {
        if SkyBridgeRuntimeEnvironment.isRunningUnderXCTest {
            accessGroup = "TEST.group.com.skybridge.compass"
        } else {
            accessGroup = try Self.resolveSharedAccessGroup()
        }
    }

    func loadDeviceAuthority() throws -> Data? {
        try withKeychainContext(.loadDeviceAuthority) {
            try KeychainManager.shared.loadImmutableKeyStrict(
                service: Self.deviceAuthorityService,
                account: Self.deviceAuthorityAccount,
                accessGroup: accessGroup
            )
        }
    }

    func insertDeviceAuthorityIfAbsent(_ data: Data) throws -> IOSKeychainInsertResult {
        try withKeychainContext(.insertDeviceAuthority) {
            try KeychainManager.shared.insertImmutableKeyIfAbsent(
                data: data,
                service: Self.deviceAuthorityService,
                account: Self.deviceAuthorityAccount,
                accessGroup: accessGroup
            )
        }
    }

    func loadSigningKey(for slot: ProtocolSigningIdentitySlot) throws -> Data? {
        try withKeychainContext(.loadSigningKey) {
            try KeychainManager.shared.loadImmutableKeyStrict(
                service: Self.signingKeyService,
                account: slot.persistenceAccount,
                accessGroup: accessGroup
            )
        }
    }

    func insertSigningKeyIfAbsent(
        _ data: Data,
        for slot: ProtocolSigningIdentitySlot
    ) throws -> IOSKeychainInsertResult {
        try withKeychainContext(.insertSigningKey) {
            try KeychainManager.shared.insertImmutableKeyIfAbsent(
                data: data,
                service: Self.signingKeyService,
                account: slot.persistenceAccount,
                accessGroup: accessGroup
            )
        }
    }

    func loadSigningAuthority(for slot: ProtocolSigningIdentitySlot) throws -> Data? {
        try withKeychainContext(.loadSigningAuthority) {
            try KeychainManager.shared.loadImmutableKeyStrict(
                service: Self.signingAuthorityService,
                account: slot.persistenceAccount,
                accessGroup: accessGroup
            )
        }
    }

    func insertSigningAuthorityIfAbsent(
        _ data: Data,
        for slot: ProtocolSigningIdentitySlot
    ) throws -> IOSKeychainInsertResult {
        try withKeychainContext(.insertSigningAuthority) {
            try KeychainManager.shared.insertImmutableKeyIfAbsent(
                data: data,
                service: Self.signingAuthorityService,
                account: slot.persistenceAccount,
                accessGroup: accessGroup
            )
        }
    }

    func legacyDefaultsDeviceIds() -> [String] {
        [Self.protocolIdentityMirrorDefaultsKey, Self.legacyDeviceDefaultsKey]
            .compactMap { UserDefaults.standard.string(forKey: $0) }
    }

    func publishDeviceIdMirrors(_ deviceId: String) {
        UserDefaults.standard.set(deviceId, forKey: Self.protocolIdentityMirrorDefaultsKey)
        UserDefaults.standard.set(deviceId, forKey: Self.legacyDeviceDefaultsKey)
    }

    func legacyDeviceIdCandidates() throws -> [ProtocolIdentityLegacyItem] {
        if SkyBridgeRuntimeEnvironment.isRunningUnderXCTest {
            guard let data = try KeychainManager.shared.exportKeyStrict(
                service: Self.legacyDeviceService,
                account: Self.legacyDeviceAccount
            ) else {
                return []
            }
            return [.init(location: .inMemoryLegacyDeviceId, data: data)]
        }
        return try withKeychainContext(.queryLegacyDeviceIdentity) {
            try legacyCandidates(
                itemClass: kSecClassGenericPassword,
                attributes: [
                    kSecAttrService as String: Self.legacyDeviceService,
                    kSecAttrAccount as String: Self.legacyDeviceAccount
                ]
            )
        }
    }

    func legacySigningKeyCandidates(
        for algorithm: ProtocolSigningAlgorithm
    ) throws -> [ProtocolIdentityLegacyItem] {
        if SkyBridgeRuntimeEnvironment.isRunningUnderXCTest {
            return []
        }
        return try withKeychainContext(.queryLegacySigningIdentity) {
            try legacyCandidates(
                itemClass: kSecClassKey,
                attributes: [
                    kSecAttrApplicationTag as String: Data(
                        "com.skybridge.identity.\(algorithm.rawValue)".utf8
                    )
                ]
            )
        }
    }

    func deleteLegacyItemIfUnchanged(_ item: ProtocolIdentityLegacyItem) throws {
        switch item.location {
        case .inMemoryLegacyDeviceId:
            guard try KeychainManager.shared.exportKeyStrict(
                service: Self.legacyDeviceService,
                account: Self.legacyDeviceAccount
            ) == item.data else {
                throw ProtocolDeviceIdentityError.legacyItemChangedDuringReconciliation
            }
            guard KeychainManager.shared.deleteKey(
                service: Self.legacyDeviceService,
                account: Self.legacyDeviceAccount
            ) else {
                throw KeychainError.unexpectedError(errSecIO)
            }
        case .persistentReference(let reference):
            var reload: [String: Any] = [
                kSecValuePersistentRef as String: reference,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            // Security.framework requires a concrete class for persistent-ref
            // mutations. Probe the two legacy classes without broad deletion.
            var matchedClass: CFTypeRef?
            var currentData: Data?
            for itemClass in [kSecClassGenericPassword, kSecClassKey] {
                reload[kSecClass as String] = itemClass
                var result: CFTypeRef?
                switch SecItemCopyMatching(reload as CFDictionary, &result) {
                case let status where Self.shouldContinueLegacyClassProbe(after: status):
                    continue
                case errSecSuccess:
                    guard let data = result as? Data else {
                        throw KeychainError.decodingError
                    }
                    matchedClass = itemClass
                    currentData = data
                case let status:
                    throw ProtocolDeviceIdentityError.keychainOperationFailed(
                        stage: .reloadLegacyItem,
                        status: status
                    )
                }
                if matchedClass != nil { break }
            }
            guard let matchedClass, currentData == item.data else {
                throw ProtocolDeviceIdentityError.legacyItemChangedDuringReconciliation
            }
            let delete: [String: Any] = [
                kSecClass as String: matchedClass,
                kSecValuePersistentRef as String: reference
            ]
            switch SecItemDelete(delete as CFDictionary) {
            case errSecSuccess, errSecItemNotFound:
                return
            case let status:
                throw ProtocolDeviceIdentityError.keychainOperationFailed(
                    stage: .deleteLegacyItem,
                    status: status
                )
            }
        }
    }

    /// A persistent reference carries its concrete Keychain item class. Querying it with the
    /// wrong class returns either `errSecItemNotFound` or `errSecNoSuchClass`, depending on the
    /// OS/runtime. Both mean only "try the other allowlisted legacy class" in this bounded probe;
    /// no other Keychain failure is downgraded.
    static func shouldContinueLegacyClassProbe(after status: OSStatus) -> Bool {
        status == errSecItemNotFound || status == errSecNoSuchClass
    }

    private func legacyCandidates(
        itemClass: CFTypeRef,
        attributes: [String: Any]
    ) throws -> [ProtocolIdentityLegacyItem] {
        var query = attributes
        query[kSecClass as String] = itemClass
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecReturnPersistentRef as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll

        var result: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecItemNotFound:
            return []
        case errSecSuccess:
            break
        case let status:
            throw KeychainError.unexpectedError(status)
        }
        let rows: [[String: Any]]
        if let many = result as? [[String: Any]] {
            rows = many
        } else if let one = result as? [String: Any] {
            rows = [one]
        } else {
            throw KeychainError.decodingError
        }
        return try rows.map { row in
            guard let data = row[kSecValueData as String] as? Data,
                  let reference = row[kSecValuePersistentRef as String] as? Data,
                  !reference.isEmpty else {
                throw KeychainError.decodingError
            }
            return ProtocolIdentityLegacyItem(
                location: .persistentReference(reference),
                data: data
            )
        }
    }

    private func withKeychainContext<T>(
        _ stage: ProtocolIdentityKeychainStage,
        operation: () throws -> T
    ) throws -> T {
        do {
            return try operation()
        } catch KeychainError.unexpectedError(let status) {
            throw ProtocolDeviceIdentityError.keychainOperationFailed(
                stage: stage,
                status: status
            )
        }
    }

    private static func resolveSharedAccessGroup() throws -> String {
        let bundleId = Bundle.main.bundleIdentifier?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) ?? ""
        guard !bundleId.isEmpty else {
            throw ProtocolDeviceIdentityError.missingSharedKeychainAccessGroup
        }

        let service = "com.skybridge.keychain-access-group-probe.\(UUID().uuidString)"
        let account = "active"
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data([0]),
            kSecReturnPersistentRef as String: true
        ]
        var addedResult: CFTypeRef?
        let addStatus = SecItemAdd(add as CFDictionary, &addedResult)
        guard addStatus == errSecSuccess else {
            throw ProtocolDeviceIdentityError.keychainProbeFailed(addStatus)
        }
        let persistentReference: Data
        if let addedReference = addedResult as? Data,
           !addedReference.isEmpty {
            persistentReference = addedReference
        } else {
            let recovery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnPersistentRef as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var recoveryResult: CFTypeRef?
            if SecItemCopyMatching(recovery as CFDictionary, &recoveryResult) == errSecSuccess,
               let recoveredReference = recoveryResult as? Data,
               !recoveredReference.isEmpty {
                try deleteProbeItem(persistentReference: recoveredReference)
            }
            throw ProtocolDeviceIdentityError.corruptKeychainProbeResult
        }

        do {
            let read: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecValuePersistentRef as String: persistentReference,
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var result: CFTypeRef?
            let readStatus = SecItemCopyMatching(read as CFDictionary, &result)
            guard readStatus == errSecSuccess,
                  let row = result as? [String: Any],
                  let defaultGroup = row[kSecAttrAccessGroup as String] as? String,
                  defaultGroup.hasSuffix(".\(bundleId)"),
                  let teamPrefix = defaultGroup.split(separator: ".", maxSplits: 1).first,
                  !teamPrefix.isEmpty else {
                if readStatus == errSecSuccess {
                    throw ProtocolDeviceIdentityError.corruptKeychainProbeResult
                }
                throw ProtocolDeviceIdentityError.keychainProbeFailed(readStatus)
            }
            let sharedGroup = "\(teamPrefix).group.com.skybridge.compass"

            // A query against an unauthorized group returns
            // errSecMissingEntitlement; a unique empty namespace in an
            // authorized group returns errSecItemNotFound.
            let verify: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.skybridge.identity-entitlement-check.\(UUID().uuidString)",
                kSecAttrAccount as String: "active",
                kSecAttrAccessGroup as String: sharedGroup,
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var verifyResult: CFTypeRef?
            let verifyStatus = SecItemCopyMatching(verify as CFDictionary, &verifyResult)
            guard verifyStatus == errSecItemNotFound else {
                if verifyStatus == errSecMissingEntitlement {
                    throw ProtocolDeviceIdentityError.missingSharedKeychainAccessGroup
                }
                throw ProtocolDeviceIdentityError.keychainProbeFailed(verifyStatus)
            }
            try deleteProbeItem(persistentReference: persistentReference)
            return sharedGroup
        } catch {
            let originalError = error
            try deleteProbeItem(persistentReference: persistentReference)
            throw originalError
        }
    }

    private static func deleteProbeItem(persistentReference: Data) throws {
        let delete: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecValuePersistentRef as String: persistentReference
        ]
        switch SecItemDelete(delete as CFDictionary) {
        case errSecSuccess, errSecItemNotFound:
            return
        case let status:
            throw ProtocolDeviceIdentityError.keychainProbeCleanupFailed(status)
        }
    }
}

@available(iOS 17.0, *)
actor ProtocolDeviceIdentityAuthority {
    static let shared = ProtocolDeviceIdentityAuthority()

    private let persistenceFactory: @Sendable () throws -> any ProtocolIdentityPersistence
    private var persistence: (any ProtocolIdentityPersistence)?
    private var deviceId: String?
    private var smokeDeviceId: String?
    private var cachedSigningIdentities: [ProtocolSigningIdentitySlot: ResolvedProtocolSigningIdentity] = [:]
    private var inFlightSigningTasks: [ProtocolSigningIdentitySlot: Task<ResolvedProtocolSigningIdentity, Error>] = [:]
    private var inFlightTokens: [ProtocolSigningIdentitySlot: UUID] = [:]

    init(
        persistenceFactory: @escaping @Sendable () throws -> any ProtocolIdentityPersistence = {
            try IOSProtocolIdentityKeychainStore()
        }
    ) {
        self.persistenceFactory = persistenceFactory
    }

    func configureSmokeOverride(_ rawDeviceId: String) throws {
        guard deviceId == nil,
              cachedSigningIdentities.isEmpty,
              inFlightSigningTasks.isEmpty else {
            throw ProtocolDeviceIdentityError.smokeOverrideAfterResolution
        }
        do {
            try ProtocolDeviceIdentity.validateDeviceId(rawDeviceId)
        } catch {
            throw ProtocolDeviceIdentityError.invalidSmokeOverride
        }
        if let smokeDeviceId, smokeDeviceId != rawDeviceId {
            throw ProtocolDeviceIdentityError.invalidSmokeOverride
        }
        smokeDeviceId = rawDeviceId
    }

    func resolveDeviceId() throws -> String {
        try Task.checkCancellation()
        let resolved = try resolveDeviceIdForAuthority()
        try Task.checkCancellation()
        return resolved
    }

    func resolveSigningIdentity(
        for algorithm: ProtocolSigningAlgorithm,
        keyProtection: ProtocolSigningKeyProtection,
        generate: @escaping @Sendable () async throws -> ProtocolSigningIdentityMaterial,
        validate: @escaping @Sendable (ProtocolSigningIdentityMaterial) async throws -> Void,
        decodeLegacy: @escaping @Sendable (Data) throws -> ProtocolSigningIdentityMaterial
    ) async throws -> ResolvedProtocolSigningIdentity {
        try Task.checkCancellation()
        let slot = try ProtocolSigningIdentitySlot(
            algorithm: algorithm,
            keyProtection: keyProtection
        )
        if let cached = cachedSigningIdentities[slot] {
            return cached
        }

        let token: UUID
        let task: Task<ResolvedProtocolSigningIdentity, Error>
        if let existing = inFlightSigningTasks[slot],
           let existingToken = inFlightTokens[slot] {
            task = existing
            token = existingToken
        } else {
            token = UUID()
            task = Task {
                    try await self.resolveSigningIdentityToCompletion(
                    for: slot,
                    generate: generate,
                    validate: validate,
                    decodeLegacy: decodeLegacy
                )
            }
            inFlightSigningTasks[slot] = task
            inFlightTokens[slot] = token
        }

        do {
            let resolved = try await task.value
            if inFlightTokens[slot] == token {
                inFlightSigningTasks[slot] = nil
                inFlightTokens[slot] = nil
                cachedSigningIdentities[slot] = resolved
            }
            try Task.checkCancellation()
            return resolved
        } catch {
            if inFlightTokens[slot] == token {
                inFlightSigningTasks[slot] = nil
                inFlightTokens[slot] = nil
            }
            throw error
        }
    }

    private func resolveDeviceIdForAuthority() throws -> String {
        if let deviceId { return deviceId }
        if let smokeDeviceId {
            deviceId = smokeDeviceId
            return smokeDeviceId
        }

        let persistence = try resolvedPersistence()
        let defaults = try persistence.legacyDefaultsDeviceIds().map {
            try ProtocolDeviceIdentity.normalizedDeviceId($0)
        }
        let legacyItems = try persistence.legacyDeviceIdCandidates()
        let keychainIds = try legacyItems.map { item in
            guard let raw = String(data: item.data, encoding: .utf8) else {
                throw ProtocolDeviceIdentityError.invalidDeviceId
            }
            return try ProtocolDeviceIdentity.normalizedDeviceId(raw)
        }
        let legacyIds = defaults + keychainIds
        guard Set(legacyIds).count <= 1 else {
            throw ProtocolDeviceIdentityError.conflictingLegacyDeviceIds
        }

        if let authority = try loadDeviceAuthority(from: persistence) {
            guard legacyIds.allSatisfy({ $0 == authority.deviceId }) else {
                throw ProtocolDeviceIdentityError.conflictingLegacyDeviceIds
            }
            try cleanupLegacyDeviceState(
                legacyItems,
                winner: authority.deviceId,
                persistence: persistence
            )
            deviceId = authority.deviceId
            return authority.deviceId
        }

        let candidate = legacyIds.first ?? UUID().uuidString.lowercased()
        let record = try ProtocolDeviceAuthorityRecord(deviceId: candidate).validated()
        let encoded = try Self.encode(record)
        _ = try persistence.insertDeviceAuthorityIfAbsent(encoded)
        guard let winner = try loadDeviceAuthority(from: persistence) else {
            throw ProtocolDeviceIdentityError.authorityWinnerMissing
        }
        if !legacyIds.isEmpty, winner.deviceId != candidate {
            throw ProtocolDeviceIdentityError.conflictingLegacyDeviceIds
        }
        try cleanupLegacyDeviceState(
            legacyItems,
            winner: winner.deviceId,
            persistence: persistence
        )
        deviceId = winner.deviceId
        return winner.deviceId
    }

    private func resolveSigningIdentityToCompletion(
        for slot: ProtocolSigningIdentitySlot,
        generate: @escaping @Sendable () async throws -> ProtocolSigningIdentityMaterial,
        validate: @escaping @Sendable (ProtocolSigningIdentityMaterial) async throws -> Void,
        decodeLegacy: @escaping @Sendable (Data) throws -> ProtocolSigningIdentityMaterial
    ) async throws -> ResolvedProtocolSigningIdentity {
        let algorithm = slot.algorithm
        // Once started, convergence is intentionally cancellation-independent:
        // abandoning one waiter must not interrupt a key-first/authority-second
        // transaction. Each waiter checks its own cancellation before use.
        let resolvedDeviceId = try resolveDeviceIdForAuthority()
        if smokeDeviceId != nil {
            let material = try await generate().validated(for: algorithm)
            guard material.keyProtection == slot.keyProtection else {
                throw ProtocolDeviceIdentityError.signingAuthorityConflict(algorithm)
            }
            try await validate(material)
            return Self.resolution(deviceId: resolvedDeviceId, material: material)
        }

        let persistence = try resolvedPersistence()
        var legacyItems = slot.keyProtection == .softwareKeychain
            ? try persistence.legacySigningKeyCandidates(for: algorithm)
            : []
        defer {
            for index in legacyItems.indices where !legacyItems[index].data.isEmpty {
                let range = legacyItems[index].data.indices
                legacyItems[index].data.resetBytes(in: range)
            }
        }
        var legacyMaterials = try legacyItems.map {
            try decodeLegacy($0.data).validated(for: algorithm)
        }
        defer {
            for index in legacyMaterials.indices {
                legacyMaterials[index].wipePrivateKey()
            }
        }
        if let firstIndex = legacyMaterials.indices.first {
            for index in legacyMaterials.indices.dropFirst() where
                legacyMaterials[index] != legacyMaterials[firstIndex] {
                throw ProtocolDeviceIdentityError
                    .legacySigningIdentityConflict(algorithm)
            }
        }

        if let authority = try loadSigningAuthority(for: slot, from: persistence) {
            guard authority.deviceId == resolvedDeviceId,
                  authority.algorithm == algorithm,
                  authority.keyProtection == slot.keyProtection,
                  let key = try loadSigningKey(for: slot, from: persistence),
                  key.keyProtection == slot.keyProtection,
                  Self.fingerprint(key.publicKey) == authority.publicKeyFingerprint else {
                throw ProtocolDeviceIdentityError.signingAuthorityConflict(algorithm)
            }
            if !legacyMaterials.isEmpty, legacyMaterials[0] != key {
                throw ProtocolDeviceIdentityError.legacySigningIdentityConflict(algorithm)
            }
            try await validate(key)
            try cleanupLegacySigningState(legacyItems, persistence: persistence)
            return Self.resolution(deviceId: resolvedDeviceId, material: key)
        }

        let candidate: ProtocolSigningIdentityMaterial
        if let existing = try loadSigningKey(for: slot, from: persistence) {
            candidate = existing
        } else if !legacyMaterials.isEmpty {
            candidate = legacyMaterials[0]
        } else {
            candidate = try await generate().validated(for: algorithm)
        }
        guard candidate.keyProtection == slot.keyProtection else {
            throw ProtocolDeviceIdentityError.signingAuthorityConflict(algorithm)
        }
        try await validate(candidate)
        var encodedCandidate = try Self.encode(candidate)
        defer {
            let range = encodedCandidate.indices
            encodedCandidate.resetBytes(in: range)
        }
        _ = try persistence.insertSigningKeyIfAbsent(
            encodedCandidate,
            for: slot
        )
        guard let winnerKey = try loadSigningKey(for: slot, from: persistence),
              winnerKey.keyProtection == slot.keyProtection else {
            throw ProtocolDeviceIdentityError.signingKeyMissing(algorithm)
        }
        if !legacyMaterials.isEmpty, legacyMaterials[0] != winnerKey {
            throw ProtocolDeviceIdentityError.legacySigningIdentityConflict(algorithm)
        }
        try await validate(winnerKey)

        let binding = try ProtocolSigningAuthorityRecord(
            deviceId: resolvedDeviceId,
            algorithm: algorithm,
            keyProtection: slot.keyProtection,
            publicKeyFingerprint: Self.fingerprint(winnerKey.publicKey)
        ).validated()
        _ = try persistence.insertSigningAuthorityIfAbsent(
            try Self.encode(binding),
            for: slot
        )
        guard let winnerAuthority = try loadSigningAuthority(
            for: slot,
            from: persistence
        ), winnerAuthority == binding else {
            throw ProtocolDeviceIdentityError.signingAuthorityConflict(algorithm)
        }
        try cleanupLegacySigningState(legacyItems, persistence: persistence)
        return Self.resolution(deviceId: resolvedDeviceId, material: winnerKey)
    }

    private func resolvedPersistence() throws -> any ProtocolIdentityPersistence {
        if let persistence { return persistence }
        let created = try persistenceFactory()
        persistence = created
        return created
    }

    private func loadDeviceAuthority(
        from persistence: any ProtocolIdentityPersistence
    ) throws -> ProtocolDeviceAuthorityRecord? {
        guard let data = try persistence.loadDeviceAuthority() else { return nil }
        guard data.count <= ProtocolDeviceAuthorityRecord.maximumEncodedSize else {
            throw ProtocolDeviceIdentityError.corruptAuthorityRecord
        }
        do {
            return try JSONDecoder().decode(ProtocolDeviceAuthorityRecord.self, from: data).validated()
        } catch let error as ProtocolDeviceIdentityError {
            throw error
        } catch {
            throw ProtocolDeviceIdentityError.corruptAuthorityRecord
        }
    }

    private func loadSigningKey(
        for slot: ProtocolSigningIdentitySlot,
        from persistence: any ProtocolIdentityPersistence
    ) throws -> ProtocolSigningIdentityMaterial? {
        let algorithm = slot.algorithm
        guard var data = try persistence.loadSigningKey(for: slot) else { return nil }
        defer {
            let range = data.indices
            data.resetBytes(in: range)
        }
        guard data.count <= ProtocolSigningIdentityMaterial.maximumEncodedSize else {
            throw ProtocolDeviceIdentityError.corruptSigningKey(algorithm)
        }
        do {
            let material = try JSONDecoder()
                .decode(ProtocolSigningIdentityMaterial.self, from: data)
                .validated(for: algorithm)
            guard material.keyProtection == slot.keyProtection else {
                throw ProtocolDeviceIdentityError.signingAuthorityConflict(algorithm)
            }
            return material
        } catch let error as ProtocolDeviceIdentityError {
            throw error
        } catch {
            throw ProtocolDeviceIdentityError.corruptSigningKey(algorithm)
        }
    }

    private func loadSigningAuthority(
        for slot: ProtocolSigningIdentitySlot,
        from persistence: any ProtocolIdentityPersistence
    ) throws -> ProtocolSigningAuthorityRecord? {
        let algorithm = slot.algorithm
        guard let data = try persistence.loadSigningAuthority(for: slot) else { return nil }
        guard data.count <= ProtocolSigningAuthorityRecord.maximumEncodedSize else {
            throw ProtocolDeviceIdentityError.corruptAuthorityRecord
        }
        do {
            let authority = try JSONDecoder()
                .decode(ProtocolSigningAuthorityRecord.self, from: data)
                .validated()
            guard authority.algorithm == algorithm,
                  authority.keyProtection == slot.keyProtection else {
                throw ProtocolDeviceIdentityError.signingAuthorityConflict(algorithm)
            }
            return authority
        } catch let error as ProtocolDeviceIdentityError {
            throw error
        } catch {
            throw ProtocolDeviceIdentityError.corruptAuthorityRecord
        }
    }

    private func cleanupLegacyDeviceState(
        _ items: [ProtocolIdentityLegacyItem],
        winner: String,
        persistence: any ProtocolIdentityPersistence
    ) throws {
        for item in items {
            try persistence.deleteLegacyItemIfUnchanged(item)
        }
        persistence.publishDeviceIdMirrors(winner)
    }

    private func cleanupLegacySigningState(
        _ items: [ProtocolIdentityLegacyItem],
        persistence: any ProtocolIdentityPersistence
    ) throws {
        for item in items {
            try persistence.deleteLegacyItemIfUnchanged(item)
        }
    }

    private static func resolution(
        deviceId: String,
        material: ProtocolSigningIdentityMaterial
    ) -> ResolvedProtocolSigningIdentity {
        // Public protocol identity fingerprints are domain-separated by signing algorithm.
        // The Keychain authority record intentionally keeps its legacy raw-key digest as an
        // internal persistence-integrity field; changing that field would require an on-disk
        // migration. Never expose that storage digest in Bonjour or handshake metadata.
        let protocolFingerprint = ProtocolIdentityPublicKeys(
            protocolPublicKey: material.publicKey,
            protocolAlgorithm: material.algorithm
        ).authoritativeFingerprint.lowercased()
        return ResolvedProtocolSigningIdentity(
            snapshot: ProtocolIdentitySnapshot(
                deviceId: deviceId,
                signingAlgorithm: material.algorithm,
                signingPublicKey: material.publicKey,
                signingPublicKeyFingerprint: protocolFingerprint
            ),
            material: material
        )
    }

    private static func fingerprint(_ publicKey: Data) -> String {
        SHA256.hash(data: publicKey).map { String(format: "%02x", $0) }.joined()
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}

@available(iOS 17.0, *)
enum ProtocolDeviceIdentity {
    private static let identityOverrideSmokeRoles: Set<String> = [
        "ios-client",
        "ios-p2p-client"
    ]

    static func configureExplicitSmokeOverrideIfPresent(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws {
        guard let rawDeviceId = try validatedExplicitSmokeOverrideDeviceId(
            environment: environment
        ) else { return }
        try await ProtocolDeviceIdentityAuthority.shared.configureSmokeOverride(rawDeviceId)
    }

    static func validatedExplicitSmokeOverrideDeviceId(
        environment: [String: String]
    ) throws -> String? {
        guard let role = environment["SKYBRIDGE_SMOKE_ROLE"] else {
            return nil
        }
        guard identityOverrideSmokeRoles.contains(role),
              environment["SKYBRIDGE_SMOKE_ALLOW_IDENTITY_OVERRIDE"] == "1",
              let rawDeviceId = environment["SKYBRIDGE_DEVICE_ID"] else {
            throw ProtocolDeviceIdentityError.invalidSmokeOverride
        }
        do {
            return try normalizedDeviceId(rawDeviceId)
        } catch {
            throw ProtocolDeviceIdentityError.invalidSmokeOverride
        }
    }

    static func resolveDeviceId() async throws -> String {
        try await ProtocolDeviceIdentityAuthority.shared.resolveDeviceId()
    }

    static func resolvePersistentDeviceId() async throws -> String {
        let raw = try await resolveDeviceId()
        return PeerIdentityAliasResolver.persistentDeviceId(from: raw) ?? raw
    }

    static func validateDeviceId(_ raw: String) throws {
        _ = try normalizedDeviceId(raw)
    }

    static func normalizedDeviceId(_ raw: String) throws -> String {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized == raw,
              !normalized.isEmpty,
              normalized.utf8.count <= 256,
              normalized.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw ProtocolDeviceIdentityError.invalidDeviceId
        }
        return normalized
    }
}
