import CryptoKit
import Foundation
import Security

@available(iOS 17.0, *)
enum ProtocolDeviceIdentityError: Error, LocalizedError, Sendable, Equatable {
    case invalidDeviceId
    case invalidSmokeOverride
    case smokeOverrideAfterResolution
    case conflictingLegacyDeviceIds
    case corruptAuthorityRecord
    case authorityWinnerMissing
    case signingKeyMissing(ProtocolSigningAlgorithm)
    case corruptSigningKey(ProtocolSigningAlgorithm)
    case signingAuthorityConflict(ProtocolSigningAlgorithm)
    case legacySigningIdentityConflict(ProtocolSigningAlgorithm)
    case legacyItemChangedDuringReconciliation
    case missingSharedKeychainAccessGroup
    case keychainProbeFailed(OSStatus)
    case corruptKeychainProbeResult
    case keychainProbeCleanupFailed(OSStatus)

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
        }
    }
}

@available(iOS 17.0, *)
struct ProtocolSigningIdentityMaterial: Codable, Equatable, Sendable {
    static let currentVersion: UInt8 = 1
    static let maximumEncodedSize = 32 * 1_024

    let version: UInt8
    let algorithm: ProtocolSigningAlgorithm
    private(set) var privateKey: Data
    let publicKey: Data

    init(
        version: UInt8 = currentVersion,
        algorithm: ProtocolSigningAlgorithm,
        privateKey: Data,
        publicKey: Data
    ) {
        self.version = version
        self.algorithm = algorithm
        self.privateKey = privateKey
        self.publicKey = publicKey
    }

    func validated(for expectedAlgorithm: ProtocolSigningAlgorithm) throws -> Self {
        guard version == Self.currentVersion,
              algorithm == expectedAlgorithm,
              !privateKey.isEmpty,
              !publicKey.isEmpty,
              privateKey.count <= Self.maximumEncodedSize,
              publicKey.count <= Self.maximumEncodedSize else {
            throw ProtocolDeviceIdentityError.corruptSigningKey(expectedAlgorithm)
        }
        return self
    }

    mutating func wipePrivateKey() {
        privateKey.resetBytes(
            in: privateKey.startIndex..<privateKey.endIndex
        )
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
    let publicKeyFingerprint: String

    init(
        version: UInt8 = currentVersion,
        deviceId: String,
        algorithm: ProtocolSigningAlgorithm,
        publicKeyFingerprint: String
    ) {
        self.version = version
        self.deviceId = deviceId
        self.algorithm = algorithm
        self.publicKeyFingerprint = publicKeyFingerprint
    }

    func validated() throws -> Self {
        guard version == Self.currentVersion,
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
    func loadSigningKey(for algorithm: ProtocolSigningAlgorithm) throws -> Data?
    func insertSigningKeyIfAbsent(
        _ data: Data,
        for algorithm: ProtocolSigningAlgorithm
    ) throws -> IOSKeychainInsertResult
    func loadSigningAuthority(for algorithm: ProtocolSigningAlgorithm) throws -> Data?
    func insertSigningAuthorityIfAbsent(
        _ data: Data,
        for algorithm: ProtocolSigningAlgorithm
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
        try KeychainManager.shared.loadImmutableKeyStrict(
            service: Self.deviceAuthorityService,
            account: Self.deviceAuthorityAccount,
            accessGroup: accessGroup
        )
    }

    func insertDeviceAuthorityIfAbsent(_ data: Data) throws -> IOSKeychainInsertResult {
        try KeychainManager.shared.insertImmutableKeyIfAbsent(
            data: data,
            service: Self.deviceAuthorityService,
            account: Self.deviceAuthorityAccount,
            accessGroup: accessGroup
        )
    }

    func loadSigningKey(for algorithm: ProtocolSigningAlgorithm) throws -> Data? {
        try KeychainManager.shared.loadImmutableKeyStrict(
            service: Self.signingKeyService,
            account: algorithm.rawValue,
            accessGroup: accessGroup
        )
    }

    func insertSigningKeyIfAbsent(
        _ data: Data,
        for algorithm: ProtocolSigningAlgorithm
    ) throws -> IOSKeychainInsertResult {
        try KeychainManager.shared.insertImmutableKeyIfAbsent(
            data: data,
            service: Self.signingKeyService,
            account: algorithm.rawValue,
            accessGroup: accessGroup
        )
    }

    func loadSigningAuthority(for algorithm: ProtocolSigningAlgorithm) throws -> Data? {
        try KeychainManager.shared.loadImmutableKeyStrict(
            service: Self.signingAuthorityService,
            account: algorithm.rawValue,
            accessGroup: accessGroup
        )
    }

    func insertSigningAuthorityIfAbsent(
        _ data: Data,
        for algorithm: ProtocolSigningAlgorithm
    ) throws -> IOSKeychainInsertResult {
        try KeychainManager.shared.insertImmutableKeyIfAbsent(
            data: data,
            service: Self.signingAuthorityService,
            account: algorithm.rawValue,
            accessGroup: accessGroup
        )
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
        return try legacyCandidates(
            itemClass: kSecClassGenericPassword,
            attributes: [
                kSecAttrService as String: Self.legacyDeviceService,
                kSecAttrAccount as String: Self.legacyDeviceAccount
            ]
        )
    }

    func legacySigningKeyCandidates(
        for algorithm: ProtocolSigningAlgorithm
    ) throws -> [ProtocolIdentityLegacyItem] {
        if SkyBridgeRuntimeEnvironment.isRunningUnderXCTest {
            return []
        }
        return try legacyCandidates(
            itemClass: kSecClassKey,
            attributes: [
                kSecAttrApplicationTag as String: Data(
                    "com.skybridge.identity.\(algorithm.rawValue)".utf8
                )
            ]
        )
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
                case errSecItemNotFound:
                    continue
                case errSecSuccess:
                    guard let data = result as? Data else {
                        throw KeychainError.decodingError
                    }
                    matchedClass = itemClass
                    currentData = data
                case let status:
                    throw KeychainError.unexpectedError(status)
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
                throw KeychainError.unexpectedError(status)
            }
        }
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
    private var cachedSigningIdentities: [ProtocolSigningAlgorithm: ResolvedProtocolSigningIdentity] = [:]
    private var inFlightSigningTasks: [ProtocolSigningAlgorithm: Task<ResolvedProtocolSigningIdentity, Error>] = [:]
    private var inFlightTokens: [ProtocolSigningAlgorithm: UUID] = [:]

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
        generate: @escaping @Sendable () async throws -> ProtocolSigningIdentityMaterial,
        validate: @escaping @Sendable (ProtocolSigningIdentityMaterial) async throws -> Void,
        decodeLegacy: @escaping @Sendable (Data) throws -> ProtocolSigningIdentityMaterial
    ) async throws -> ResolvedProtocolSigningIdentity {
        try Task.checkCancellation()
        if let cached = cachedSigningIdentities[algorithm] {
            return cached
        }

        let token: UUID
        let task: Task<ResolvedProtocolSigningIdentity, Error>
        if let existing = inFlightSigningTasks[algorithm],
           let existingToken = inFlightTokens[algorithm] {
            task = existing
            token = existingToken
        } else {
            token = UUID()
            task = Task {
                try await self.resolveSigningIdentityToCompletion(
                    for: algorithm,
                    generate: generate,
                    validate: validate,
                    decodeLegacy: decodeLegacy
                )
            }
            inFlightSigningTasks[algorithm] = task
            inFlightTokens[algorithm] = token
        }

        do {
            let resolved = try await task.value
            if inFlightTokens[algorithm] == token {
                inFlightSigningTasks[algorithm] = nil
                inFlightTokens[algorithm] = nil
                cachedSigningIdentities[algorithm] = resolved
            }
            try Task.checkCancellation()
            return resolved
        } catch {
            if inFlightTokens[algorithm] == token {
                inFlightSigningTasks[algorithm] = nil
                inFlightTokens[algorithm] = nil
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
        for algorithm: ProtocolSigningAlgorithm,
        generate: @escaping @Sendable () async throws -> ProtocolSigningIdentityMaterial,
        validate: @escaping @Sendable (ProtocolSigningIdentityMaterial) async throws -> Void,
        decodeLegacy: @escaping @Sendable (Data) throws -> ProtocolSigningIdentityMaterial
    ) async throws -> ResolvedProtocolSigningIdentity {
        // Once started, convergence is intentionally cancellation-independent:
        // abandoning one waiter must not interrupt a key-first/authority-second
        // transaction. Each waiter checks its own cancellation before use.
        let resolvedDeviceId = try resolveDeviceIdForAuthority()
        if smokeDeviceId != nil {
            let material = try await generate().validated(for: algorithm)
            try await validate(material)
            return Self.resolution(deviceId: resolvedDeviceId, material: material)
        }

        let persistence = try resolvedPersistence()
        var legacyItems = try persistence.legacySigningKeyCandidates(for: algorithm)
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

        if let authority = try loadSigningAuthority(for: algorithm, from: persistence) {
            guard authority.deviceId == resolvedDeviceId,
                  authority.algorithm == algorithm,
                  let key = try loadSigningKey(for: algorithm, from: persistence),
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
        if let existing = try loadSigningKey(for: algorithm, from: persistence) {
            candidate = existing
        } else if !legacyMaterials.isEmpty {
            candidate = legacyMaterials[0]
        } else {
            candidate = try await generate().validated(for: algorithm)
        }
        try await validate(candidate)
        var encodedCandidate = try Self.encode(candidate)
        defer {
            let range = encodedCandidate.indices
            encodedCandidate.resetBytes(in: range)
        }
        _ = try persistence.insertSigningKeyIfAbsent(
            encodedCandidate,
            for: algorithm
        )
        guard let winnerKey = try loadSigningKey(for: algorithm, from: persistence) else {
            throw ProtocolDeviceIdentityError.signingKeyMissing(algorithm)
        }
        if !legacyMaterials.isEmpty, legacyMaterials[0] != winnerKey {
            throw ProtocolDeviceIdentityError.legacySigningIdentityConflict(algorithm)
        }
        try await validate(winnerKey)

        let binding = try ProtocolSigningAuthorityRecord(
            deviceId: resolvedDeviceId,
            algorithm: algorithm,
            publicKeyFingerprint: Self.fingerprint(winnerKey.publicKey)
        ).validated()
        _ = try persistence.insertSigningAuthorityIfAbsent(
            try Self.encode(binding),
            for: algorithm
        )
        guard let winnerAuthority = try loadSigningAuthority(
            for: algorithm,
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
        for algorithm: ProtocolSigningAlgorithm,
        from persistence: any ProtocolIdentityPersistence
    ) throws -> ProtocolSigningIdentityMaterial? {
        guard var data = try persistence.loadSigningKey(for: algorithm) else { return nil }
        defer {
            let range = data.indices
            data.resetBytes(in: range)
        }
        guard data.count <= ProtocolSigningIdentityMaterial.maximumEncodedSize else {
            throw ProtocolDeviceIdentityError.corruptSigningKey(algorithm)
        }
        do {
            return try JSONDecoder().decode(ProtocolSigningIdentityMaterial.self, from: data)
                .validated(for: algorithm)
        } catch let error as ProtocolDeviceIdentityError {
            throw error
        } catch {
            throw ProtocolDeviceIdentityError.corruptSigningKey(algorithm)
        }
    }

    private func loadSigningAuthority(
        for algorithm: ProtocolSigningAlgorithm,
        from persistence: any ProtocolIdentityPersistence
    ) throws -> ProtocolSigningAuthorityRecord? {
        guard let data = try persistence.loadSigningAuthority(for: algorithm) else { return nil }
        guard data.count <= ProtocolSigningAuthorityRecord.maximumEncodedSize else {
            throw ProtocolDeviceIdentityError.corruptAuthorityRecord
        }
        do {
            return try JSONDecoder().decode(ProtocolSigningAuthorityRecord.self, from: data).validated()
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
        let fingerprint = fingerprint(material.publicKey)
        return ResolvedProtocolSigningIdentity(
            snapshot: ProtocolIdentitySnapshot(
                deviceId: deviceId,
                signingAlgorithm: material.algorithm,
                signingPublicKey: material.publicKey,
                signingPublicKeyFingerprint: fingerprint
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
