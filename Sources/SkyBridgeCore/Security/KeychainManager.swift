import Foundation
import Dispatch
import Security
import CryptoKit
import LocalAuthentication
import os
import OSLog

public enum KeychainError: Error, LocalizedError, Sendable {
    case itemNotFound
    case unexpectedError(OSStatus)
    case decodingError
    case itemChangedDuringReconciliation

    public var errorDescription: String? {
        switch self {
        case .itemNotFound:
            return "Keychain item not found"
        case .unexpectedError(let status):
            return "Keychain error: \(status)"
        case .decodingError:
            return "Keychain item could not be decoded"
        case .itemChangedDuringReconciliation:
            return "Keychain item changed during legacy reconciliation"
        }
    }
}

public enum KeychainInsertResult: Sendable, Equatable {
    case inserted
    case alreadyExists
}

struct LegacyGenericPasswordCandidate: Equatable, Sendable {
    let service: String
    let account: String
    var data: Data
    let location: LegacySecItemLocation
}

struct LegacyGenericPasswordMetadataCandidate: Equatable, Sendable {
    let service: String
    let account: String
    let location: LegacySecItemLocation
}

/// KeychainManager - 安全的密钥存储管理器
///
/// ## 并发安全说明
/// Actor 隔离只保证互斥，不保证同步 Security.framework 调用离开主线程。
/// Actor 自身因此绑定到专用串行执行器；actor-isolated 的认证会话操作会
/// 保持顺序并在后台队列执行。历史 nonisolated API 仍由调用方负责线程边界。
@available(macOS 14.0, *)
public actor KeychainManager {
    public static let shared = KeychainManager()
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "KeychainManager")
    private nonisolated let keychainExecutor = KeychainSerialExecutor(
        label: "com.skybridge.compass.keychain"
    )

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        keychainExecutor.asUnownedSerialExecutor()
    }

    private var interactiveUnlockCompleted = false
    private var lastInteractiveUnlockFailureAt: Date = .distantPast
    private let interactiveUnlockCooldown: TimeInterval = 12 * 60 * 60

    private init() {}

    private nonisolated static var useInMemoryKeychain: Bool {
        #if DEBUG || SKYBRIDGE_TESTING
        let env = ProcessInfo.processInfo.environment
        if env["SKYBRIDGE_KEYCHAIN_IN_MEMORY"] == "1" { return true }
        if env["XCTestConfigurationFilePath"] != nil { return true }
        return NSClassFromString("XCTestCase") != nil
        #else
        return false
        #endif
    }
    private nonisolated(unsafe) static var inMemoryStore: [String: Data] = [:]
    private nonisolated static let inMemoryLock = NSLock()

    private struct ScopedInMemoryKey: Hashable, Sendable {
        let service: String
        let account: String
        let accessGroup: String
        let usesDataProtectionKeychain: Bool
    }

    private nonisolated static let inMemoryDefaultAccessGroup =
        "__skybridge_test_default_access_group__"

    private nonisolated static let scopedInMemoryStore = OSAllocatedUnfairLock(
        initialState: [ScopedInMemoryKey: Data]()
    )

    private nonisolated static func wipeSensitiveData(_ data: inout Data) {
        data.withUnsafeMutableBytes { buffer in
            _ = buffer.initializeMemory(as: UInt8.self, repeating: 0)
        }
        data.removeAll(keepingCapacity: false)
    }

    private struct LegacyGenericPasswordDiscovery {
        let service: String
        let account: String
        var data: Data?
        let location: LegacySecItemLocation
    }

    private enum InMemoryExactDeleteResult: Equatable {
        case deleted
        case missing
        case changed
    }

    private nonisolated static func inMemoryPersistentReference(
        service: String,
        account: String,
        accessGroup: String?,
        usesDataProtectionKeychain: Bool
    ) -> Data {
        let location = [
            service,
            account,
            accessGroup ?? "<legacy-no-group>",
            usesDataProtectionKeychain ? "data-protection" : "legacy"
        ].joined(separator: "\u{1f}")
        return Data(SHA256.hash(data: Data(location.utf8)))
    }

    private nonisolated static func scopedInMemoryValue(
        service: String,
        account: String,
        accessGroup: String?,
        usesDataProtectionKeychain: Bool
    ) -> Data? {
        return scopedInMemoryStore.withLock { storage in
            if let accessGroup {
                return storage[
                    ScopedInMemoryKey(
                        service: service,
                        account: account,
                        accessGroup: accessGroup,
                        usesDataProtectionKeychain: usesDataProtectionKeychain
                    )
                ]
            }
            return storage
                .filter { key, _ in
                    key.service == service
                        && key.account == account
                        && key.usesDataProtectionKeychain
                            == usesDataProtectionKeychain
                }
                .sorted { lhs, rhs in
                    lhs.key.accessGroup < rhs.key.accessGroup
                }
                .first?
                .value
        }
    }

    private nonisolated static func insertScopedInMemoryValueIfAbsent(
        _ data: Data,
        service: String,
        account: String,
        accessGroup: String?,
        usesDataProtectionKeychain: Bool
    ) -> KeychainInsertResult {
        let key = ScopedInMemoryKey(
            service: service,
            account: account,
            accessGroup: accessGroup ?? inMemoryDefaultAccessGroup,
            usesDataProtectionKeychain: usesDataProtectionKeychain
        )
        return scopedInMemoryStore.withLock { storage in
            guard storage[key] == nil else { return .alreadyExists }
            storage[key] = data
            return .inserted
        }
    }

    private nonisolated static func removeScopedInMemoryValue(
        service: String,
        account: String,
        accessGroup: String?,
        usesDataProtectionKeychain: Bool
    ) {
        scopedInMemoryStore.withLock { storage in
            if let accessGroup {
                _ = storage.removeValue(
                    forKey: ScopedInMemoryKey(
                        service: service,
                        account: account,
                        accessGroup: accessGroup,
                        usesDataProtectionKeychain: usesDataProtectionKeychain
                    )
                )
            } else {
                storage = storage.filter { key, _ in
                    key.service != service
                        || key.account != account
                        || key.usesDataProtectionKeychain
                            != usesDataProtectionKeychain
                }
            }
        }
    }

    private nonisolated static func scopedInMemoryAccounts(
        service: String,
        accessGroup: String?,
        usesDataProtectionKeychain: Bool
    ) -> Set<String> {
        return scopedInMemoryStore.withLock { storage in
            Set(
                storage.keys.compactMap { key in
                    guard key.service == service,
                          key.usesDataProtectionKeychain
                              == usesDataProtectionKeychain,
                          accessGroup == nil || key.accessGroup == accessGroup else {
                        return nil
                    }
                    return key.account
                }
            )
        }
    }

    private nonisolated func makeNonInteractiveAuthContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    private nonisolated func forbidKeychainAuthenticationUI(_ query: inout [String: Any]) {
        query[kSecUseAuthenticationContext as String] = makeNonInteractiveAuthContext()
    }

    private nonisolated func accessibility(
        for value: KeychainGenericPasswordAccessibility
    ) -> CFString {
        switch value {
        case .afterFirstUnlockThisDeviceOnly:
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
    }

    private nonisolated func applyAccessGroup(
        _ accessGroup: String?,
        to query: inout [String: Any]
    ) {
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        } else {
            query.removeValue(forKey: kSecAttrAccessGroup as String)
        }
    }

    private nonisolated func applyDataProtectionKeychain(
        _ enabled: Bool,
        to query: inout [String: Any]
    ) {
        #if os(macOS)
        // A missing selector can prefer a same-name Data Protection item and
        // hide the historical file-Keychain item from migration discovery.
        // Security.framework accepts the explicit false value as the legacy
        // domain selector; the signed integration probe protects this rule.
        query[kSecUseDataProtectionKeychain as String] = enabled
        #else
        _ = enabled
        #endif
    }

    private nonisolated func keychainSearchModes(
        scope: KeychainGenericPasswordScope,
        includeLegacyKeychain: Bool
    ) -> [Bool] {
        guard scope.usesDataProtectionKeychain else { return [false] }
        return includeLegacyKeychain ? [true, false] : [true]
    }

    private nonisolated func legacyDiscoverySearchModes(
        includeLegacyKeychain: Bool
    ) -> [Bool] {
        #if os(macOS)
        includeLegacyKeychain ? [true, false] : [true]
        #else
        _ = includeLegacyKeychain
        return [true]
        #endif
    }

    private nonisolated static func performInteractiveUnlockProbe() -> OSStatus {
        let context = LAContext()
        context.interactionNotAllowed = false
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item)
    }

    /// 启动时调用：最多触发一次交互式解锁，后续全部静默读取。
    public func prepareInteractiveUnlockIfNeeded() async -> Bool {
        if Self.useInMemoryKeychain { return true }
        if interactiveUnlockCompleted { return true }

        let now = Date()
        if now.timeIntervalSince(lastInteractiveUnlockFailureAt) < interactiveUnlockCooldown {
            logger.info("跳过交互式 Keychain 解锁（冷却中）")
            return false
        }

        let status = Self.performInteractiveUnlockProbe()
        switch status {
        case errSecSuccess, errSecItemNotFound:
            interactiveUnlockCompleted = true
            logger.info("Keychain 交互式解锁准备完成")
            return true
        default:
            lastInteractiveUnlockFailureAt = now
            logger.error("Keychain 交互式解锁失败: \(status)")
            return false
        }
    }

    private nonisolated func upsertGenericPassword(
        service: String,
        account: String,
        data: Data,
        accessibility: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    ) -> OSStatus {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        forbidKeychainAuthenticationUI(&query)
        let updateAttrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess { return errSecSuccess }
        if updateStatus != errSecItemNotFound { return updateStatus }

        var addQuery = query
        addQuery.removeValue(forKey: kSecUseAuthenticationContext as String)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = accessibility
        return SecItemAdd(addQuery as CFDictionary, nil)
    }

 // MARK: - Keychain 基础操作（nonisolated - Keychain 本身线程安全）

    public nonisolated func importKey(
        data: Data,
        service: String,
        account: String,
        accessibility: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    ) -> Bool {
        if Self.useInMemoryKeychain {
            let key = service + "|" + account
            Self.inMemoryLock.lock()
            Self.inMemoryStore[key] = data
            Self.inMemoryLock.unlock()
            return true
        }
        let status = upsertGenericPassword(
            service: service,
            account: account,
            data: data,
            accessibility: accessibility
        )
        if status != errSecSuccess { logger.error("Key 导入失败: \(status)") }
        return status == errSecSuccess
    }

    /// Atomically creates one generic-password item without replacing an
    /// existing value. Callers implementing immutable identity records must
    /// reload the winner after `.alreadyExists`; update-or-add is unsafe for
    /// concurrent first creation across app and extension processes.
    public nonisolated func insertKeyIfAbsent(
        data: Data,
        service: String,
        account: String,
        accessibility: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    ) throws -> KeychainInsertResult {
        if Self.useInMemoryKeychain {
            let key = service + "|" + account
            return Self.inMemoryLock.withLock {
                guard Self.inMemoryStore[key] == nil else { return .alreadyExists }
                Self.inMemoryStore[key] = data
                return .inserted
            }
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return .inserted
        case errSecDuplicateItem:
            return .alreadyExists
        default:
            throw KeychainError.unexpectedError(status)
        }
    }

    /// Scoped variant used by app/extension-shared immutable identities.
    nonisolated func insertKeyIfAbsent(
        data: Data,
        service: String,
        account: String,
        scope: KeychainGenericPasswordScope
    ) throws -> KeychainInsertResult {
        if Self.useInMemoryKeychain {
            return Self.insertScopedInMemoryValueIfAbsent(
                data,
                service: service,
                account: account,
                accessGroup: scope.writeAccessGroup,
                usesDataProtectionKeychain: scope.usesDataProtectionKeychain
            )
        }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility(for: scope.accessibility),
            kSecAttrSynchronizable as String: scope.synchronizable
        ]
        applyAccessGroup(scope.writeAccessGroup, to: &query)
        applyDataProtectionKeychain(scope.usesDataProtectionKeychain, to: &query)

        switch SecItemAdd(query as CFDictionary, nil) {
        case errSecSuccess:
            return .inserted
        case errSecDuplicateItem:
            return .alreadyExists
        case let status:
            throw KeychainError.unexpectedError(status)
        }
    }

    public nonisolated func exportKey(service: String, account: String) -> Data? {
        do {
            return try exportKeyStrict(service: service, account: account)
        } catch {
            logger.error("Key 导出失败: \(error.localizedDescription)")
            return nil
        }
    }

    public nonisolated func exportKeyStrict(service: String, account: String) throws -> Data? {
        try loadKeyDataStrict(service: service, account: account)
    }

    /// Strictly reads a generic-password item through an ordered set of access
    /// groups and, when requested, the historical non-data-protection keychain.
    nonisolated func exportKeyStrict(
        service: String,
        account: String,
        scope: KeychainGenericPasswordScope,
        includeLegacyKeychain: Bool = false
    ) throws -> Data? {
        if Self.useInMemoryKeychain {
            for accessGroup in scope.readAccessGroups {
                if let data = Self.scopedInMemoryValue(
                    service: service,
                    account: account,
                    accessGroup: accessGroup,
                    usesDataProtectionKeychain: scope.usesDataProtectionKeychain
                ) {
                    return data
                }
            }
            return nil
        }

        for usesDataProtection in keychainSearchModes(
            scope: scope,
            includeLegacyKeychain: includeLegacyKeychain
        ) {
            for accessGroup in scope.readAccessGroups {
                var query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: account,
                    kSecReturnData as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne
                ]
                applyAccessGroup(accessGroup, to: &query)
                applyDataProtectionKeychain(usesDataProtection, to: &query)
                forbidKeychainAuthenticationUI(&query)

                var item: CFTypeRef?
                switch SecItemCopyMatching(query as CFDictionary, &item) {
                case errSecSuccess:
                    guard let data = item as? Data else {
                        throw KeychainError.decodingError
                    }
                    return data
                case errSecItemNotFound:
                    continue
                case let status:
                    throw KeychainError.unexpectedError(status)
                }
            }
        }
        return nil
    }

    /// Enumerates every visible non-synchronizable legacy item and records the
    /// exact Security location returned by the system. The missing access-group
    /// constraint is intentional only for discovery; callers must reconcile
    /// every candidate and mutate it through `deleteLegacyGenericPasswordCandidate`.
    nonisolated func legacyGenericPasswordCandidatesStrict(
        service: String,
        account: String,
        includeLegacyKeychain: Bool = true
    ) throws -> [LegacyGenericPasswordCandidate] {
        var discoveries = try legacyGenericPasswordDiscoveriesStrict(
            service: service,
            account: account,
            includeLegacyKeychain: includeLegacyKeychain,
            returnData: true
        )
        defer {
            for index in discoveries.indices {
                if var data = discoveries[index].data {
                    discoveries[index].data = nil
                    Self.wipeSensitiveData(&data)
                }
            }
        }
        var candidates: [LegacyGenericPasswordCandidate] = []
        candidates.reserveCapacity(discoveries.count)
        for index in discoveries.indices {
            guard let data = discoveries[index].data else {
                throw KeychainError.decodingError
            }
            discoveries[index].data = nil
            candidates.append(
                LegacyGenericPasswordCandidate(
                    service: discoveries[index].service,
                    account: discoveries[index].account,
                    data: data,
                    location: discoveries[index].location
                )
            )
        }
        return candidates
    }

    /// Enumerates only namespace metadata. Backend evidence uses this path so
    /// classification never imports legacy private-key bytes into the process.
    nonisolated func legacyGenericPasswordMetadataCandidatesStrict(
        service: String,
        account: String,
        includeLegacyKeychain: Bool = true
    ) throws -> [LegacyGenericPasswordMetadataCandidate] {
        try legacyGenericPasswordDiscoveriesStrict(
            service: service,
            account: account,
            includeLegacyKeychain: includeLegacyKeychain,
            returnData: false
        ).map {
            LegacyGenericPasswordMetadataCandidate(
                service: $0.service,
                account: $0.account,
                location: $0.location
            )
        }
    }

    private nonisolated func legacyGenericPasswordDiscoveriesStrict(
        service: String,
        account: String,
        includeLegacyKeychain: Bool,
        returnData: Bool
    ) throws -> [LegacyGenericPasswordDiscovery] {
        guard !service.isEmpty, !account.isEmpty else {
            throw KeychainError.decodingError
        }
        if Self.useInMemoryKeychain {
            var discoveries = Self.scopedInMemoryStore.withLock { storage in
                storage.compactMap { key, data -> LegacyGenericPasswordDiscovery? in
                    guard key.service == service,
                          key.account == account,
                          includeLegacyKeychain
                            || key.usesDataProtectionKeychain else {
                        return nil
                    }
                    let persistentReference = Self.inMemoryPersistentReference(
                        service: service,
                        account: account,
                        accessGroup: key.accessGroup,
                        usesDataProtectionKeychain: key.usesDataProtectionKeychain
                    )
                    return LegacyGenericPasswordDiscovery(
                        service: service,
                        account: account,
                        data: returnData ? data : nil,
                        location: LegacySecItemLocation(
                            actualAccessGroup: key.accessGroup,
                            usesDataProtectionKeychain: key.usesDataProtectionKeychain,
                            persistentReference: persistentReference
                        )
                    )
                }
            }
            let legacy = Self.inMemoryLock.withLock {
                let data = Self.inMemoryStore[service + "|" + account]
                return (exists: data != nil, data: returnData ? data : nil)
            }
            if includeLegacyKeychain, legacy.exists {
                discoveries.append(
                    LegacyGenericPasswordDiscovery(
                        service: service,
                        account: account,
                        data: legacy.data,
                        location: LegacySecItemLocation(
                            actualAccessGroup: nil,
                            usesDataProtectionKeychain: false,
                            persistentReference: Self.inMemoryPersistentReference(
                                service: service,
                                account: account,
                                accessGroup: nil,
                                usesDataProtectionKeychain: false
                            )
                        )
                    )
                )
            }
            return discoveries.sorted { lhs, rhs in
                lhs.location.persistentReference.lexicographicallyPrecedes(
                    rhs.location.persistentReference
                )
            }
        }

        var discoveries: [LegacyGenericPasswordDiscovery] = []
        var seenLocations = Set<LegacySecItemLocation>()
        for usesDataProtection in legacyDiscoverySearchModes(
            includeLegacyKeychain: includeLegacyKeychain
        ) {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecAttrSynchronizable as String: false,
                kSecReturnAttributes as String: true,
                kSecReturnPersistentRef as String: true,
                kSecMatchLimit as String: kSecMatchLimitAll
            ]
            if returnData {
                query[kSecReturnData as String] = true
            }
            applyDataProtectionKeychain(usesDataProtection, to: &query)
            forbidKeychainAuthenticationUI(&query)

            var item: CFTypeRef?
            switch SecItemCopyMatching(query as CFDictionary, &item) {
            case errSecItemNotFound:
                continue
            case errSecSuccess:
                break
            case let status:
                throw KeychainError.unexpectedError(status)
            }
            let rows: [[String: Any]]
            if let values = item as? [[String: Any]] {
                rows = values
            } else if let value = item as? [String: Any] {
                rows = [value]
            } else {
                throw KeychainError.decodingError
            }
            for row in rows {
                let data: Data?
                if returnData {
                    guard let returnedData = row[kSecValueData as String] as? Data else {
                        throw KeychainError.decodingError
                    }
                    data = returnedData
                } else {
                    data = nil
                }
                guard let persistentReference = row[
                          kSecValuePersistentRef as String
                      ] as? Data,
                      !persistentReference.isEmpty else {
                    throw KeychainError.decodingError
                }
                let actualAccessGroup = row[kSecAttrAccessGroup as String] as? String
                if usesDataProtection {
                    guard let actualAccessGroup,
                          !actualAccessGroup.trimmingCharacters(
                              in: .whitespacesAndNewlines
                          ).isEmpty else {
                        throw KeychainError.decodingError
                    }
                }
                let location = LegacySecItemLocation(
                    actualAccessGroup: actualAccessGroup,
                    usesDataProtectionKeychain: usesDataProtection,
                    persistentReference: persistentReference
                )
                guard seenLocations.insert(location).inserted else {
                    continue
                }
                discoveries.append(
                    LegacyGenericPasswordDiscovery(
                        service: service,
                        account: account,
                        data: data,
                        location: location
                    )
                )
            }
        }
        return discoveries
    }

    /// Deletes exactly one item discovered above. Persistent references are the
    /// mutation authority; actualAccessGroup is retained for reconciliation and
    /// diagnostics, never translated into a nil-group delete query.
    nonisolated func deleteLegacyGenericPasswordCandidate(
        _ candidate: LegacyGenericPasswordCandidate
    ) throws {
        if Self.useInMemoryKeychain {
            let expectedReference = Self.inMemoryPersistentReference(
                service: candidate.service,
                account: candidate.account,
                accessGroup: candidate.location.actualAccessGroup,
                usesDataProtectionKeychain: candidate.location
                    .usesDataProtectionKeychain
            )
            guard expectedReference == candidate.location.persistentReference else {
                throw KeychainError.decodingError
            }
            if candidate.location.usesDataProtectionKeychain
                || candidate.location.actualAccessGroup != nil {
                guard let accessGroup = candidate.location.actualAccessGroup else {
                    throw KeychainError.decodingError
                }
                let key = ScopedInMemoryKey(
                    service: candidate.service,
                    account: candidate.account,
                    accessGroup: accessGroup,
                    usesDataProtectionKeychain: candidate.location
                        .usesDataProtectionKeychain
                )
                let result = Self.scopedInMemoryStore.withLock { storage in
                    guard let current = storage[key] else {
                        return InMemoryExactDeleteResult.missing
                    }
                    guard current == candidate.data else {
                        return InMemoryExactDeleteResult.changed
                    }
                    storage.removeValue(forKey: key)
                    return InMemoryExactDeleteResult.deleted
                }
                if result == .changed {
                    throw KeychainError.itemChangedDuringReconciliation
                }
            } else {
                let key = candidate.service + "|" + candidate.account
                let result = Self.inMemoryLock.withLock {
                    guard let current = Self.inMemoryStore[key] else {
                        return InMemoryExactDeleteResult.missing
                    }
                    guard current == candidate.data else {
                        return InMemoryExactDeleteResult.changed
                    }
                    Self.inMemoryStore.removeValue(forKey: key)
                    return InMemoryExactDeleteResult.deleted
                }
                if result == .changed {
                    throw KeychainError.itemChangedDuringReconciliation
                }
            }
            return
        }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        candidate.location.applyPersistentReferenceMatch(to: &query)
        applyDataProtectionKeychain(
            candidate.location.usesDataProtectionKeychain,
            to: &query
        )
        forbidKeychainAuthenticationUI(&query)
        var currentItem: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &currentItem) {
        case errSecItemNotFound:
            return
        case errSecSuccess:
            guard let current = currentItem as? Data else {
                throw KeychainError.decodingError
            }
            guard current == candidate.data else {
                throw KeychainError.itemChangedDuringReconciliation
            }
        case let status:
            throw KeychainError.unexpectedError(status)
        }
        query.removeValue(forKey: kSecReturnData as String)
        query.removeValue(forKey: kSecMatchLimit as String)
        switch SecItemDelete(query as CFDictionary) {
        case errSecSuccess, errSecItemNotFound:
            return
        case let status:
            throw KeychainError.unexpectedError(status)
        }
    }

    /// Returns the accounts stored under one generic-password service.
    ///
    /// This strict variant is used only for deterministic legacy-key discovery:
    /// Keychain access and malformed attribute results are surfaced to callers
    /// instead of being interpreted as an empty service.
    nonisolated func genericPasswordAccountsStrict(service: String) throws -> Set<String> {
        guard !service.isEmpty else { throw KeychainError.decodingError }
        if Self.useInMemoryKeychain {
            let prefix = service + "|"
            return Self.inMemoryLock.withLock {
                Set(
                    Self.inMemoryStore.keys.compactMap { key in
                        guard key.hasPrefix(prefix) else { return nil }
                        return String(key.dropFirst(prefix.count))
                    }
                )
            }
        }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        forbidKeychainAuthenticationUI(&query)
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return []
        }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedError(status)
        }
        guard let attributes = item as? [[String: Any]] else {
            throw KeychainError.decodingError
        }
        var accounts = Set<String>()
        for attribute in attributes {
            guard let account = attribute[kSecAttrAccount as String] as? String else {
                throw KeychainError.decodingError
            }
            accounts.insert(account)
        }
        return accounts
    }

    nonisolated func genericPasswordAccountsStrict(
        service: String,
        scope: KeychainGenericPasswordScope,
        includeLegacyKeychain: Bool = false
    ) throws -> Set<String> {
        guard !service.isEmpty else { throw KeychainError.decodingError }
        if Self.useInMemoryKeychain {
            var accounts = Set<String>()
            for accessGroup in scope.readAccessGroups {
                accounts.formUnion(
                    Self.scopedInMemoryAccounts(
                        service: service,
                        accessGroup: accessGroup,
                        usesDataProtectionKeychain: scope.usesDataProtectionKeychain
                    )
                )
            }
            return accounts
        }

        var accounts = Set<String>()
        for usesDataProtection in keychainSearchModes(
            scope: scope,
            includeLegacyKeychain: includeLegacyKeychain
        ) {
            for accessGroup in scope.readAccessGroups {
                var query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecReturnAttributes as String: true,
                    kSecMatchLimit as String: kSecMatchLimitAll
                ]
                applyAccessGroup(accessGroup, to: &query)
                applyDataProtectionKeychain(usesDataProtection, to: &query)
                forbidKeychainAuthenticationUI(&query)

                var item: CFTypeRef?
                switch SecItemCopyMatching(query as CFDictionary, &item) {
                case errSecSuccess:
                    guard let attributes = item as? [[String: Any]] else {
                        throw KeychainError.decodingError
                    }
                    for attribute in attributes {
                        guard let account = attribute[kSecAttrAccount as String] as? String else {
                            throw KeychainError.decodingError
                        }
                        accounts.insert(account)
                    }
                case errSecItemNotFound:
                    continue
                case let status:
                    throw KeychainError.unexpectedError(status)
                }
            }
        }
        return accounts
    }

 // MARK: - 对称密钥存取（AES-GCM等）

    public nonisolated func storeSymmetricKey(_ key: SymmetricKey, account: String) -> Bool {
        let data = key.withUnsafeBytes { Data($0) }
        if Self.useInMemoryKeychain {
            let memKey = "SkyBridge.SymmetricKey" + "|" + account
            Self.inMemoryLock.lock()
            Self.inMemoryStore[memKey] = data
            Self.inMemoryLock.unlock()
            return true
        }
        let status = upsertGenericPassword(
            service: "SkyBridge.SymmetricKey",
            account: account,
            data: data,
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
        if status != errSecSuccess { logger.error("对称密钥存储失败: \(status)") }
        return status == errSecSuccess
    }

    public nonisolated func loadSymmetricKey(account: String) -> SymmetricKey? {
        if Self.useInMemoryKeychain {
            let memKey = "SkyBridge.SymmetricKey" + "|" + account
            Self.inMemoryLock.lock()
            let data = Self.inMemoryStore[memKey]
            Self.inMemoryLock.unlock()
            return data.map { SymmetricKey(data: $0) }
        }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "SkyBridge.SymmetricKey",
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        forbidKeychainAuthenticationUI(&query)
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecItemNotFound { logger.error("对称密钥读取失败: \(status)") }
            return nil
        }
        return SymmetricKey(data: data)
    }

 // MARK: - Secure Enclave P256 签名密钥对

    public nonisolated func generateSecureEnclaveSigningKey(tag: String) -> SecureEnclave.P256.Signing.PrivateKey? {
        do {
            let privateKey = try SecureEnclave.P256.Signing.PrivateKey(compactRepresentable: true)
            let pubData = privateKey.publicKey.rawRepresentation
            _ = storeKeyData(pubData, service: "SkyBridge.SecureEnclavePub", account: tag)
            return privateKey
        } catch {
            logger.error("Secure Enclave 密钥生成失败: \(error.localizedDescription)")
            return nil
        }
    }

    public nonisolated func loadSecureEnclavePublicKey(tag: String) -> P256.Signing.PublicKey? {
        guard let data = loadKeyData(service: "SkyBridge.SecureEnclavePub", account: tag) else { return nil }
        return try? P256.Signing.PublicKey(rawRepresentation: data)
    }

    public nonisolated func storeEnclaveKeyReference(tag: Data, secKey: SecKey) -> Bool {
        var addQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueRef as String: secKey
        ]
        forbidKeychainAuthenticationUI(&addQuery)
        SecItemDelete(addQuery as CFDictionary)
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess { logger.error("Enclave Key 引用存储失败: \(status)") }
        return status == errSecSuccess
    }

    public nonisolated func loadEnclaveKeyReference(tag: Data) -> SecKey? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        forbidKeychainAuthenticationUI(&query)
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let anyItem = item, CFGetTypeID(anyItem) == SecKeyGetTypeID() else {
            return nil
        }
        let secKey = unsafeDowncast(anyItem, to: SecKey.self)
        return secKey
    }

 // MARK: - 非SE P256 签名密钥对（回退）

    public nonisolated func generateP256SigningKeypair(tag: String) -> (private: P256.Signing.PrivateKey, public: P256.Signing.PublicKey)? {
        let priv = P256.Signing.PrivateKey()
        let pub = priv.publicKey
        let privData = priv.rawRepresentation
        let pubData = pub.rawRepresentation
        let ok1 = storeKeyData(
            privData,
            service: "SkyBridge.P256Priv",
            account: tag,
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
        let ok2 = storeKeyData(
            pubData,
            service: "SkyBridge.P256Pub",
            account: tag,
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
        if !ok1 || !ok2 { logger.error("P256 密钥对存储失败") }
        return (priv, pub)
    }

    public nonisolated func loadP256PrivateKey(tag: String) -> P256.Signing.PrivateKey? {
        guard let data = loadKeyData(service: "SkyBridge.P256Priv", account: tag) else { return nil }
        return try? P256.Signing.PrivateKey(rawRepresentation: data)
    }

    public nonisolated func loadP256PublicKey(tag: String) -> P256.Signing.PublicKey? {
        guard let data = loadKeyData(service: "SkyBridge.P256Pub", account: tag) else { return nil }
        return try? P256.Signing.PublicKey(rawRepresentation: data)
    }

 // MARK: - 导入/导出
 // 保留上方显式 SecItemAdd/SecItemCopyMatching 实现，避免重复定义

 // MARK: - 底层Keychain封装

 /// 底层 Keychain 写入（nonisolated - Keychain API 线程安全）
    private nonisolated func storeKeyData(
        _ data: Data,
        service: String,
        account: String,
        accessibility: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    ) -> Bool {
        if Self.useInMemoryKeychain {
            let key = service + "|" + account
            Self.inMemoryLock.lock()
            Self.inMemoryStore[key] = data
            Self.inMemoryLock.unlock()
            return true
        }
 // 若已存在且内容一致，避免重复写入，减少冗余项
        if let existing = loadKeyData(service: service, account: account), existing == data { return true }
        let status = upsertGenericPassword(
            service: service,
            account: account,
            data: data,
            accessibility: accessibility
        )
        if status != errSecSuccess { logger.error("Keychain 写入失败: \(status)") }
        return status == errSecSuccess
    }

 /// 底层 Keychain 读取（nonisolated - Keychain API 线程安全）
    private nonisolated func loadKeyData(service: String, account: String) -> Data? {
        if Self.useInMemoryKeychain {
            let key = service + "|" + account
            Self.inMemoryLock.lock()
            let data = Self.inMemoryStore[key]
            Self.inMemoryLock.unlock()
            return data
        }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        forbidKeychainAuthenticationUI(&query)
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return data
    }

    private nonisolated func loadKeyDataStrict(service: String, account: String) throws -> Data? {
        if Self.useInMemoryKeychain {
            let key = service + "|" + account
            Self.inMemoryLock.lock()
            let data = Self.inMemoryStore[key]
            Self.inMemoryLock.unlock()
            return data
        }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        forbidKeychainAuthenticationUI(&query)
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedError(status)
        }
        guard let data = item as? Data else {
            throw KeychainError.decodingError
        }
        return data
    }

}

// ML-DSA/ML-KEM Keychain存取接口将在升级到最新SDK后补充具体类型
// MARK: - 通用API密钥与服务配置
@available(macOS 14.0, *)
extension KeychainManager {
    public struct SupabaseConfig: Codable {
        public let url: String
        public let anonKey: String

        public init(url: String, anonKey: String) {
            self.url = url
            self.anonKey = anonKey
        }

        @available(*, deprecated, message: "Client-side Supabase configuration no longer exposes service role keys.")
        public var serviceRoleKey: String? {
            nil
        }
    }
    public struct NebulaConfig: Codable {
        public let baseURL: String
        public let clientId: String
        public let clientSecret: String?
    }
    public struct SMSConfig: Codable { public let accessKeyId: String; public let accessKeySecret: String }

    public nonisolated func storeWeatherAPIKey(_ key: String) throws {
        let ok = storeKeyData(Data(key.utf8), service: "SkyBridge.Weather", account: "OpenWeatherMap")
        if !ok { throw NSError(domain: "Keychain", code: -1) }
    }

    public nonisolated func retrieveWeatherAPIKey() throws -> String {
        guard let data = loadKeyData(service: "SkyBridge.Weather", account: "OpenWeatherMap"), let str = String(data: data, encoding: .utf8) else { throw NSError(domain: "Keychain", code: -2) }
        return str
    }

    public nonisolated func storeAppleUserID(_ userID: String) throws {
        let trimmed = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw NSError(domain: "Keychain", code: -20) }
        let ok = storeKeyData(Data(trimmed.utf8), service: "SkyBridge.Auth", account: "AppleUserID")
        if !ok { throw NSError(domain: "Keychain", code: -21) }
    }

    public nonisolated func retrieveAppleUserID() -> String? {
        guard let data = loadKeyData(service: "SkyBridge.Auth", account: "AppleUserID"),
              let str = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public nonisolated func deleteAppleUserID() {
        if Self.useInMemoryKeychain {
            let key = "SkyBridge.Auth" + "|" + "AppleUserID"
            Self.inMemoryLock.lock()
            Self.inMemoryStore.removeValue(forKey: key)
            Self.inMemoryLock.unlock()
            return
        }
        var del: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "SkyBridge.Auth",
            kSecAttrAccount as String: "AppleUserID",
        ]
        forbidKeychainAuthenticationUI(&del)
        SecItemDelete(del as CFDictionary)
    }

    public nonisolated func storeSupabaseConfig(url: String, anonKey: String) throws {
        let base = "SkyBridge.Supabase"
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAnonKey = anonKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let parsedURL = URL(string: trimmedURL),
              let scheme = parsedURL.scheme?.lowercased(),
              ["https", "http"].contains(scheme),
              parsedURL.host != nil else {
            throw NSError(
                domain: "Keychain",
                code: -30,
                userInfo: [NSLocalizedDescriptionKey: "Supabase URL 无效"]
            )
        }
        guard !trimmedAnonKey.isEmpty else {
            throw NSError(
                domain: "Keychain",
                code: -31,
                userInfo: [NSLocalizedDescriptionKey: "Supabase 匿名密钥不能为空"]
            )
        }

        let ok1 = storeKeyData(Data(trimmedURL.utf8), service: base, account: "URL")
        let ok2 = storeKeyData(Data(trimmedAnonKey.utf8), service: base, account: "AnonKey")
        try purgeLegacySupabaseServiceRoleKey()
        if !ok1 || !ok2 { throw NSError(domain: "Keychain", code: -3) }
    }

    @available(*, deprecated, message: "Supabase service role keys must remain server-side.")
    public nonisolated func storeSupabaseConfig(url: String, anonKey: String, serviceRoleKey: String?) throws {
        try storeSupabaseConfig(url: url, anonKey: anonKey)
    }

    public nonisolated func retrieveSupabaseConfig() throws -> SupabaseConfig {
        let base = "SkyBridge.Supabase"
        guard let url = loadKeyData(service: base, account: "URL").flatMap({ String(data: $0, encoding: .utf8) }),
              let anon = loadKeyData(service: base, account: "AnonKey").flatMap({ String(data: $0, encoding: .utf8) }) else { throw NSError(domain: "Keychain", code: -6) }
        try purgeLegacySupabaseServiceRoleKey()
        return SupabaseConfig(url: url, anonKey: anon)
    }

    public nonisolated func storeNebulaConfig(baseURL: String, clientId: String, clientSecret: String?) throws {
        let base = "SkyBridge.Nebula"
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedClientId = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedClientSecret = clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines)

        let ok1 = storeKeyData(Data(trimmedBaseURL.utf8), service: base, account: "BaseURL")
        let ok2 = storeKeyData(Data(trimmedClientId.utf8), service: base, account: "ClientId")
        let ok3: Bool
        if let trimmedClientSecret, !trimmedClientSecret.isEmpty {
            ok3 = storeKeyData(Data(trimmedClientSecret.utf8), service: base, account: "ClientSecret")
        } else {
            do {
                try deleteAPIKey(service: base, account: "ClientSecret")
                ok3 = true
            } catch {
                ok3 = false
            }
        }
        if !ok1 || !ok2 || !ok3 { throw NSError(domain: "Keychain", code: -4) }
    }

    public nonisolated func retrieveNebulaConfig() throws -> NebulaConfig {
        let base = "SkyBridge.Nebula"
        guard let cid = loadKeyData(service: base, account: "ClientId").flatMap({ String(data: $0, encoding: .utf8) }) else {
            throw NSError(domain: "Keychain", code: -7)
        }

        let baseURL = loadKeyData(service: base, account: "BaseURL")
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let clientSecret = loadKeyData(service: base, account: "ClientSecret")
            .flatMap { String(data: $0, encoding: .utf8) }

        return NebulaConfig(baseURL: baseURL, clientId: cid, clientSecret: clientSecret)
    }

    public nonisolated func hasLegacySMSConfig() -> Bool {
        let base = "SkyBridge.SMS"
        return loadKeyData(service: base, account: "AccessKeyId") != nil
            || loadKeyData(service: base, account: "AccessKeySecret") != nil
    }

    public nonisolated func clearLegacySMSConfig() throws {
        let base = "SkyBridge.SMS"
        try deleteAPIKey(service: base, account: "AccessKeyId")
        try deleteAPIKey(service: base, account: "AccessKeySecret")
    }

    @available(*, deprecated, message: "Client-side SMS credentials are retired. Use server-side Supabase send_sms hook + Aliyun SMS.")
    public nonisolated func storeSMSConfig(accessKeyId: String, accessKeySecret: String) throws {
        _ = accessKeyId
        _ = accessKeySecret
        throw NSError(
            domain: "Keychain",
            code: -5,
            userInfo: [NSLocalizedDescriptionKey: "客户端短信密钥已停用，不能再写入本地 Keychain"]
        )
    }

    @available(*, deprecated, message: "Client-side SMS credentials are retained only for legacy cleanup.")
    public nonisolated func retrieveSMSConfig() throws -> SMSConfig {
        let base = "SkyBridge.SMS"
        guard let akid = loadKeyData(service: base, account: "AccessKeyId").flatMap({ String(data: $0, encoding: .utf8) }),
              let aksec = loadKeyData(service: base, account: "AccessKeySecret").flatMap({ String(data: $0, encoding: .utf8) }) else { throw NSError(domain: "Keychain", code: -8) }
        return SMSConfig(accessKeyId: akid, accessKeySecret: aksec)
    }

    public nonisolated func deleteAPIKey(service: String, account: String) throws {
        if Self.useInMemoryKeychain {
            let key = service + "|" + account
            Self.inMemoryLock.lock()
            Self.inMemoryStore.removeValue(forKey: key)
            Self.inMemoryLock.unlock()
            return
        }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        forbidKeychainAuthenticationUI(&query)
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound { throw NSError(domain: "Keychain", code: Int(status)) }
    }

    nonisolated func deleteAPIKey(
        service: String,
        account: String,
        scope: KeychainGenericPasswordScope,
        includeLegacyKeychain: Bool = true
    ) throws {
        if scope.readAccessGroups.contains(where: { $0 == nil }) {
            let candidates = try legacyGenericPasswordCandidatesStrict(
                service: service,
                account: account,
                includeLegacyKeychain: includeLegacyKeychain
            )
            for candidate in candidates {
                try deleteLegacyGenericPasswordCandidate(candidate)
            }
            return
        }
        if Self.useInMemoryKeychain {
            for accessGroup in scope.readAccessGroups {
                Self.removeScopedInMemoryValue(
                    service: service,
                    account: account,
                    accessGroup: accessGroup,
                    usesDataProtectionKeychain: scope.usesDataProtectionKeychain
                )
            }
            return
        }

        for usesDataProtection in keychainSearchModes(
            scope: scope,
            includeLegacyKeychain: includeLegacyKeychain
        ) {
            for accessGroup in scope.readAccessGroups {
                var query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: account
                ]
                applyAccessGroup(accessGroup, to: &query)
                applyDataProtectionKeychain(usesDataProtection, to: &query)
                forbidKeychainAuthenticationUI(&query)
                let status = SecItemDelete(query as CFDictionary)
                guard status == errSecSuccess || status == errSecItemNotFound else {
                    throw KeychainError.unexpectedError(status)
                }
            }
        }
    }

    private nonisolated func purgeLegacySupabaseServiceRoleKey() throws {
        try deleteAPIKey(service: "SkyBridge.Supabase", account: "ServiceRoleKey")
    }

    private nonisolated static let authSessionService = "com.skybridge.compass.authsession"
    private nonisolated static let authSessionAccount = "primary"

    /// Persist an authentication session on the KeychainManager actor.
    ///
    /// Security.framework calls are synchronous. Keeping this method actor-isolated
    /// preserves write ordering while allowing MainActor callers to suspend instead
    /// of blocking the UI during `SecItemUpdate`.
    public func storeAuthSession(_ session: AuthSession) throws {
        let data = try JSONEncoder().encode(session)
        if Self.useInMemoryKeychain {
            let key = Self.authSessionService + "|" + Self.authSessionAccount
            Self.inMemoryLock.lock()
            Self.inMemoryStore[key] = data
            Self.inMemoryLock.unlock()
            return
        }

        let status = upsertGenericPassword(
            service: Self.authSessionService,
            account: Self.authSessionAccount,
            data: data,
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
        if status != errSecSuccess {
            throw NSError(domain: "Keychain", code: Int(status))
        }
    }

    public func loadAuthSession() -> AuthSession? {
        do {
            return try loadAuthSessionStrict()
        } catch {
            logger.error("Auth session Keychain load failed: \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    public func loadAuthSessionStrict() throws -> AuthSession? {
        guard let data = try loadKeyDataStrict(
            service: Self.authSessionService,
            account: Self.authSessionAccount
        ) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(AuthSession.self, from: data)
        } catch {
            throw NSError(
                domain: "Keychain",
                code: Int(errSecDecode),
                userInfo: [NSUnderlyingErrorKey: error]
            )
        }
    }

    /// Atomically replaces the persisted authentication session only when the
    /// exact source session is still authoritative. Actor isolation keeps the
    /// read/compare/write sequence indivisible with respect to sign-out and
    /// account-switch writes.
    public func replaceAuthSession(
        expected: AuthSession,
        with replacement: AuthSession
    ) throws -> Bool {
        guard try loadAuthSessionStrict() == expected else { return false }
        try storeAuthSession(replacement)
        return true
    }

    public func deleteAuthSession() throws {
        try deleteAPIKey(service: Self.authSessionService, account: Self.authSessionAccount)
    }
}

final class KeychainSerialExecutor: SerialExecutor, @unchecked Sendable {
    private let queue: DispatchQueue

    init(label: String) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let unownedJob = UnownedJob(job)
        let executor = asUnownedSerialExecutor()
        queue.async {
            unownedJob.runSynchronously(on: executor)
        }
    }
}

@available(macOS 14.0, *)
extension KeychainManager {
 // MARK: - 对端签名公钥持久化（P256.Signing.PublicKey 原始表示）

 /// 将对端签名公钥以原始字节存入钥匙串，按 peerId 区分
    public nonisolated func storePeerSigningPublicKey(_ keyData: Data, peerId: String) -> Bool {
        let ok = storeKeyData(keyData, service: "SkyBridge.PeerSigningPub", account: peerId)
        if !ok { logger.error("对端签名公钥存储失败: \(peerId)") }
        return ok
    }

 /// 读取指定 peerId 的对端签名公钥原始字节
    public nonisolated func retrievePeerSigningPublicKey(_ peerId: String) -> Data? {
        return loadKeyData(service: "SkyBridge.PeerSigningPub", account: peerId)
    }

}
