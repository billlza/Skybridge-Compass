//
// KeychainManager.swift
// SkyBridgeCompassiOS
//
// 钥匙串管理器 - 安全的密钥存储
// 与 macOS 版本兼容的 API
//

import Foundation
import Dispatch
import Security
import CryptoKit
import os
import SkyBridgeProtocolCore

// MARK: - Keychain Error

/// 钥匙串错误
public enum KeychainError: Error, LocalizedError, Sendable {
    case itemNotFound
    case duplicateItem
    case unexpectedError(OSStatus)
    case encodingError
    case decodingError
    case ambiguousAccessGroup
    case incompleteKeyMaterial(String)
    case immutableStateCorrupt(String)
    case immutableStateCycleRejected
    case immutableStateTransitionLimitExceeded(maximum: Int)

    public var errorDescription: String? {
        switch self {
        case .itemNotFound: return "钥匙串项目未找到"
        case .duplicateItem: return "钥匙串项目已存在"
        case .unexpectedError(let status): return "钥匙串错误: \(status)"
        case .encodingError: return "编码错误"
        case .decodingError: return "解码错误"
        case .ambiguousAccessGroup: return "多个钥匙串访问组包含同名条目，已停止操作"
        case .incompleteKeyMaterial(let reason): return "密钥材料不完整: \(reason)"
        case .immutableStateCorrupt(let reason): return "不可变状态损坏: \(reason)"
        case .immutableStateCycleRejected:
            return "不可变状态迁移会重复历史状态，已在写入前拒绝"
        case .immutableStateTransitionLimitExceeded(let maximum):
            return "不可变状态迁移链超过上限 \(maximum)，需要受控重新注册"
        }
    }
}

enum IOSKeychainInsertResult: Sendable, Equatable {
    case inserted
    case alreadyExists
}

// MARK: - Keychain Manager

/// 钥匙串管理器
///
/// Actor 隔离只保证互斥，不保证同步 Security.framework 调用离开主线程。
/// 认证与配置 API 通过此 actor 的专用串行执行器运行；历史 nonisolated
/// 密钥 API 继续由现有调用方负责线程边界。
@available(iOS 17.0, *)
public actor KeychainManager {

    public static let shared = KeychainManager()
    private nonisolated let keychainExecutor = IOSKeychainSerialExecutor(
        label: "com.skybridge.compass.ios.keychain"
    )

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        keychainExecutor.asUnownedSerialExecutor()
    }
    
    private init() {
#if DEBUG || SKYBRIDGE_TESTING
        accountTestDependencies = nil
#endif
    }

    private var accountObservations: [UUID: IOSAuthSessionObservation] = [:]
#if DEBUG || SKYBRIDGE_TESTING
    private struct AccountTestDependencies: Sendable {
        let storage: any ProtectedAccountSessionStorage
        let loadLegacy: @Sendable () throws -> Data?
        let deleteLegacy: @Sendable () throws -> Void
    }
    private let accountTestDependencies: AccountTestDependencies?
    init(accountStorage: any ProtectedAccountSessionStorage,
         loadLegacy: @escaping @Sendable () throws -> Data?,
         deleteLegacy: @escaping @Sendable () throws -> Void) {
        accountTestDependencies = AccountTestDependencies(storage: accountStorage,
            loadLegacy: loadLegacy, deleteLegacy: deleteLegacy)
    }
#endif

    
    // MARK: - Test Mode Support
    
    private nonisolated static var useInMemoryKeychain: Bool {
#if DEBUG || SKYBRIDGE_TESTING
        if ProcessInfo.processInfo.environment["SKYBRIDGE_KEYCHAIN_IN_MEMORY"] == "1" { return true }
        return SkyBridgeRuntimeEnvironment.isRunningUnderXCTest
#else
        false
#endif
    }

    private nonisolated(unsafe) static var inMemoryStore: [String: Data] = [:]
    private nonisolated static let inMemoryLock = NSLock()
    
    // MARK: - Basic Key Operations
    
    /// 导入密钥
    public nonisolated func importKey(
        data: Data,
        service: String,
        account: String,
        accessibility: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    ) -> Bool {
        do {
            try upsertKeyStrict(
                data: data,
                service: service,
                account: account,
                accessibility: accessibility
            )
            return true
        } catch {
            return false
        }
    }

    private nonisolated func upsertKeyStrict(
        data: Data,
        service: String,
        account: String,
        accessibility: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    ) throws {
        if Self.useInMemoryKeychain {
            let key = service + "|" + account
            Self.inMemoryLock.lock()
            Self.inMemoryStore[key] = data
            Self.inMemoryLock.unlock()
            return
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility
        ]
        let scope = try IOSLegacyKeychainScope.current()
        let updateStatus = try scope.update(query, updateAttributes)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedError(updateStatus)
        }

        var addQuery = query
        addQuery[kSecAttrAccessible as String] = accessibility
        addQuery[kSecValueData as String] = data
        let status = try scope.add(addQuery)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedError(status)
        }
    }
    
    /// 导出密钥
    public nonisolated func exportKey(service: String, account: String) -> Data? {
        try? exportKeyStrict(service: service, account: account)
    }

    /// 导出密钥，保留 Keychain 错误语义。
    public nonisolated func exportKeyStrict(service: String, account: String) throws -> Data? {
        if Self.useInMemoryKeychain {
            let key = service + "|" + account
            Self.inMemoryLock.lock()
            let data = Self.inMemoryStore[key]
            Self.inMemoryLock.unlock()
            return data
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var item: CFTypeRef?
        let status = try IOSLegacyKeychainScope.current().copyMatching(query, &item)
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

    /// Reads one exact, non-synchronizable generic-password item. This is the
    /// authoritative primitive used by immutable identity records; callers
    /// must provide the concrete shared access group resolved from the signed
    /// app entitlement.
    nonisolated func loadImmutableKeyStrict(
        service: String,
        account: String,
        accessGroup: String
    ) throws -> Data? {
        let normalizedGroup = accessGroup.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedGroup.isEmpty else {
            throw KeychainError.encodingError
        }

        if Self.useInMemoryKeychain {
            let key = Self.inMemoryScopedKey(
                service: service,
                account: account,
                accessGroup: normalizedGroup
            )
            Self.inMemoryLock.lock()
            let data = Self.inMemoryStore[key]
            Self.inMemoryLock.unlock()
            return data
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: normalizedGroup,
            kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &item) {
        case errSecItemNotFound:
            return nil
        case errSecSuccess:
            guard let data = item as? Data else {
                throw KeychainError.decodingError
            }
            return data
        case let status:
            throw KeychainError.unexpectedError(status)
        }
    }

    /// Add-only compare-and-set for immutable identity state. A duplicate is
    /// never overwritten; the authority actor must reload and validate the
    /// winning value.
    nonisolated func insertImmutableKeyIfAbsent(
        data: Data,
        service: String,
        account: String,
        accessGroup: String
    ) throws -> IOSKeychainInsertResult {
        let normalizedGroup = accessGroup.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !data.isEmpty, !normalizedGroup.isEmpty else {
            throw KeychainError.encodingError
        }

        if Self.useInMemoryKeychain {
            let key = Self.inMemoryScopedKey(
                service: service,
                account: account,
                accessGroup: normalizedGroup
            )
            return Self.inMemoryLock.withLock {
                guard Self.inMemoryStore[key] == nil else {
                    return .alreadyExists
                }
                Self.inMemoryStore[key] = data
                return .inserted
            }
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: normalizedGroup,
            kSecAttrSynchronizable as String: false,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ]
        switch SecItemAdd(query as CFDictionary, nil) {
        case errSecSuccess:
            return .inserted
        case errSecDuplicateItem:
            return .alreadyExists
        case let status:
            throw KeychainError.unexpectedError(status)
        }
    }

    private nonisolated static func inMemoryScopedKey(
        service: String,
        account: String,
        accessGroup: String
    ) -> String {
        "scoped|\(accessGroup)|\(service)|\(account)"
    }

    /// Optional metadata follows the same namespace and test-backend rules as
    /// the key bytes. Missing metadata is legitimate; native I/O errors are not.
    nonisolated func keyCreationDate(account: String) throws -> Date? {
        if Self.useInMemoryKeychain { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = try IOSLegacyKeychainScope.current().copyMatching(query, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedError(status) }
        guard let attributes = result as? [String: Any] else { throw KeychainError.decodingError }
        guard let value = attributes[kSecAttrCreationDate as String] else { return nil }
        guard let date = value as? Date else { throw KeychainError.decodingError }
        return date
    }

    // MARK: - Q-Periapt immutable persistence

    /// Maximum number of monotonic policy transitions retained for one root.
    /// Crossing the bound is a controlled re-enrollment condition, not a signal
    /// to scan or mutate an unbounded Keychain history.
    private nonisolated static let qPeriaptMaximumTrustedStateTransitions = 64
    private nonisolated static let qPeriaptTrustedStateLength = 36
    private nonisolated static let qPeriaptTrustedStateService =
        "com.skybridge.compass.qperiapt.trusted-state.v1"
    private nonisolated static let qPeriaptIdentityService =
        "com.skybridge.compass.qperiapt.kem-identity.v1"

    /// Reads the current state by following an append-only transition chain.
    /// Each transition account is derived only from the authenticated root-key
    /// fingerprint and SHA-256(expected state); the registry label never enters
    /// the Keychain namespace.
    nonisolated func loadQPeriaptTrustedState(
        rootFingerprint: Data
    ) throws -> Data? {
        try qPeriaptTrustedStateSnapshot(rootFingerprint: rootFingerprint).state
    }

    private nonisolated func qPeriaptTrustedStateSnapshot(
        rootFingerprint: Data
    ) throws -> (state: Data?, transitionCount: Int, visitedStateDigests: Set<Data>) {
        try Self.validateQPeriaptRootFingerprint(rootFingerprint)

        var currentState: Data?
        var visitedStateDigests = Set<Data>()
        for transitionIndex in 0..<Self.qPeriaptMaximumTrustedStateTransitions {
            guard let nextState = try loadQPeriaptItem(
                service: Self.qPeriaptTrustedStateService,
                account: Self.qPeriaptTransitionAccount(
                    rootFingerprint: rootFingerprint,
                    expectedState: currentState
                )
            ) else {
                return (currentState, transitionIndex, visitedStateDigests)
            }
            guard nextState.count == Self.qPeriaptTrustedStateLength else {
                throw KeychainError.immutableStateCorrupt(
                    "Q-Periapt trusted-state transition has \(nextState.count) bytes"
                )
            }
            let nextDigest = Data(SHA256.hash(data: nextState))
            guard visitedStateDigests.insert(nextDigest).inserted else {
                throw KeychainError.immutableStateCorrupt(
                    "Q-Periapt trusted-state transition chain contains a cycle"
                )
            }
            currentState = nextState
        }

        let overflowTransition = try loadQPeriaptItem(
            service: Self.qPeriaptTrustedStateService,
            account: Self.qPeriaptTransitionAccount(
                rootFingerprint: rootFingerprint,
                expectedState: currentState
            )
        )
        guard overflowTransition == nil else {
            throw KeychainError.immutableStateTransitionLimitExceeded(
                maximum: Self.qPeriaptMaximumTrustedStateTransitions
            )
        }
        return (
            currentState,
            Self.qPeriaptMaximumTrustedStateTransitions,
            visitedStateDigests
        )
    }

    /// Cross-process add-only CAS for monotonic trusted state. `SecItemAdd` is
    /// the commit point: two contenders for the same expected-state account
    /// cannot both win. Replaying the already-current state is an idempotent
    /// success, while attempting to return to any older state is rejected
    /// before the append-only record is written.
    nonisolated func compareAndSwapQPeriaptTrustedState(
        expectedPreviousState: Data?,
        newState: Data,
        rootFingerprint: Data
    ) throws -> Bool {
        try Self.validateQPeriaptRootFingerprint(rootFingerprint)
        if let expectedPreviousState {
            guard expectedPreviousState.count == Self.qPeriaptTrustedStateLength else {
                throw KeychainError.immutableStateCorrupt(
                    "Q-Periapt expected trusted state has \(expectedPreviousState.count) bytes"
                )
            }
        }
        guard newState.count == Self.qPeriaptTrustedStateLength else {
            throw KeychainError.immutableStateCorrupt(
                "Q-Periapt candidate trusted state has \(newState.count) bytes"
            )
        }

        let snapshot = try qPeriaptTrustedStateSnapshot(rootFingerprint: rootFingerprint)
        guard snapshot.state == expectedPreviousState else { return false }
        guard snapshot.state != newState else { return true }
        let newStateDigest = Data(SHA256.hash(data: newState))
        guard !snapshot.visitedStateDigests.contains(newStateDigest) else {
            throw KeychainError.immutableStateCycleRejected
        }
        guard snapshot.transitionCount < Self.qPeriaptMaximumTrustedStateTransitions else {
            throw KeychainError.immutableStateTransitionLimitExceeded(
                maximum: Self.qPeriaptMaximumTrustedStateTransitions
            )
        }

        return try insertQPeriaptItemIfAbsent(
            data: newState,
            service: Self.qPeriaptTrustedStateService,
            account: Self.qPeriaptTransitionAccount(
                rootFingerprint: rootFingerprint,
                expectedState: expectedPreviousState
            )
        ) == .inserted
    }

    /// Loads the one versioned Q-Periapt KEM identity envelope for a root-key
    /// fingerprint. The caller validates the envelope before using any key bytes.
    nonisolated func loadQPeriaptIdentityEnvelope(
        rootFingerprint: Data,
        suiteWireId: UInt16,
        formatVersion: UInt8
    ) throws -> Data? {
        try Self.validateQPeriaptRootFingerprint(rootFingerprint)
        return try loadQPeriaptItem(
            service: Self.qPeriaptIdentityService,
            account: Self.qPeriaptIdentityAccount(
                rootFingerprint: rootFingerprint,
                suiteWireId: suiteWireId,
                formatVersion: formatVersion
            )
        )
    }

    /// Add-only commit for a complete public/private identity envelope.
    nonisolated func insertQPeriaptIdentityEnvelopeIfAbsent(
        _ envelope: Data,
        rootFingerprint: Data,
        suiteWireId: UInt16,
        formatVersion: UInt8
    ) throws -> IOSKeychainInsertResult {
        try Self.validateQPeriaptRootFingerprint(rootFingerprint)
        guard !envelope.isEmpty else { throw KeychainError.encodingError }
        return try insertQPeriaptItemIfAbsent(
            data: envelope,
            service: Self.qPeriaptIdentityService,
            account: Self.qPeriaptIdentityAccount(
                rootFingerprint: rootFingerprint,
                suiteWireId: suiteWireId,
                formatVersion: formatVersion
            )
        )
    }

    #if DEBUG || SKYBRIDGE_TESTING
    /// Injects one append-only transition into the in-memory XCTest backend so
    /// corruption and cycle handling can be exercised without touching a real
    /// device Keychain. Production builds expose no mutation bypass.
    nonisolated func insertQPeriaptTrustedStateTransitionForTesting(
        rootFingerprint: Data,
        expectedState: Data?,
        storedState: Data
    ) throws -> IOSKeychainInsertResult {
        guard Self.useInMemoryKeychain else {
            throw KeychainError.immutableStateCorrupt(
                "Q-Periapt test transition injection requires the in-memory Keychain"
            )
        }
        try Self.validateQPeriaptRootFingerprint(rootFingerprint)
        if let expectedState,
           expectedState.count != Self.qPeriaptTrustedStateLength {
            throw KeychainError.immutableStateCorrupt(
                "Q-Periapt test expected state has an invalid length"
            )
        }
        return try insertQPeriaptItemIfAbsent(
            data: storedState,
            service: Self.qPeriaptTrustedStateService,
            account: Self.qPeriaptTransitionAccount(
                rootFingerprint: rootFingerprint,
                expectedState: expectedState
            )
        )
    }
    #endif

    private nonisolated func loadQPeriaptItem(
        service: String,
        account: String
    ) throws -> Data? {
        if Self.useInMemoryKeychain {
            let key = "qperiapt|\(service)|\(account)"
            return Self.inMemoryLock.withLock { Self.inMemoryStore[key] }
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        switch try IOSLegacyKeychainScope.current().copyMatching(query, &item) {
        case errSecItemNotFound:
            return nil
        case errSecSuccess:
            guard let data = item as? Data else { throw KeychainError.decodingError }
            return data
        case let status:
            throw KeychainError.unexpectedError(status)
        }
    }

    private nonisolated func insertQPeriaptItemIfAbsent(
        data: Data,
        service: String,
        account: String
    ) throws -> IOSKeychainInsertResult {
        guard !data.isEmpty else { throw KeychainError.encodingError }
        if Self.useInMemoryKeychain {
            let key = "qperiapt|\(service)|\(account)"
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
            kSecAttrSynchronizable as String: false,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ]
        switch try IOSLegacyKeychainScope.current().add(query) {
        case errSecSuccess:
            return .inserted
        case errSecDuplicateItem:
            return .alreadyExists
        case let status:
            throw KeychainError.unexpectedError(status)
        }
    }

    private nonisolated static func qPeriaptTransitionAccount(
        rootFingerprint: Data,
        expectedState: Data?
    ) -> String {
        let expectedDigest = Data(SHA256.hash(data: expectedState ?? Data()))
        return "\(hex(rootFingerprint)).\(hex(expectedDigest))"
    }

    private nonisolated static func qPeriaptIdentityAccount(
        rootFingerprint: Data,
        suiteWireId: UInt16,
        formatVersion: UInt8
    ) -> String {
        "\(hex(rootFingerprint)).\(String(format: "%04x", suiteWireId)).v\(formatVersion)"
    }

    private nonisolated static func validateQPeriaptRootFingerprint(
        _ rootFingerprint: Data
    ) throws {
        guard rootFingerprint.count == SHA256.byteCount else {
            throw KeychainError.immutableStateCorrupt(
                "Q-Periapt root-key fingerprint has \(rootFingerprint.count) bytes"
            )
        }
    }

    private nonisolated static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// 删除密钥
    public nonisolated func deleteKey(service: String, account: String) -> Bool {
        do {
            try deleteKeyStrict(service: service, account: account)
            return true
        } catch {
            return false
        }
    }

    private nonisolated func deleteKeyStrict(service: String, account: String) throws {
        if Self.useInMemoryKeychain {
            let key = service + "|" + account
            Self.inMemoryLock.lock()
            Self.inMemoryStore.removeValue(forKey: key)
            Self.inMemoryLock.unlock()
            return
        }
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        
        let status = try IOSLegacyKeychainScope.current().delete(query)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedError(status)
        }
    }

    public func storeAppleUserID(_ userID: String) throws {
        let trimmed = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw KeychainError.encodingError
        }
        try upsertKeyStrict(
            data: Data(trimmed.utf8),
            service: "SkyBridge.Auth",
            account: "AppleUserID"
        )
    }

    public func retrieveAppleUserID() throws -> String? {
        guard let data = try exportKeyStrict(service: "SkyBridge.Auth", account: "AppleUserID"),
              let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    public func deleteAppleUserID() throws {
        try deleteKeyStrict(service: "SkyBridge.Auth", account: "AppleUserID")
    }
    
    // MARK: - Symmetric Key Operations
    
    /// 存储对称密钥
    public nonisolated func storeSymmetricKey(_ key: SymmetricKey, account: String) -> Bool {
        let data = key.withUnsafeBytes { Data($0) }
        return importKey(
            data: data,
            service: "SkyBridge.SymmetricKey",
            account: account,
            accessibility: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        )
    }
    
    /// 加载对称密钥
    public nonisolated func loadSymmetricKey(account: String) -> SymmetricKey? {
        guard let data = exportKey(service: "SkyBridge.SymmetricKey", account: account) else {
            return nil
        }
        return SymmetricKey(data: data)
    }
    
    // MARK: - P256 Key Operations
    
    /// 生成并存储 P256 签名密钥对
    public nonisolated func generateP256SigningKeypair(tag: String) -> (private: P256.Signing.PrivateKey, public: P256.Signing.PublicKey)? {
        let privateKey = P256.Signing.PrivateKey()
        let publicKey = privateKey.publicKey
        
        let privData = privateKey.rawRepresentation
        let pubData = publicKey.rawRepresentation
        
        let ok1 = importKey(
            data: privData,
            service: "SkyBridge.P256Priv",
            account: tag,
            accessibility: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        )
        let ok2 = importKey(
            data: pubData,
            service: "SkyBridge.P256Pub",
            account: tag
        )
        
        if !ok1 || !ok2 {
            return nil
        }
        
        return (privateKey, publicKey)
    }
    
    /// 加载 P256 私钥
    public nonisolated func loadP256PrivateKey(tag: String) -> P256.Signing.PrivateKey? {
        guard let data = exportKey(service: "SkyBridge.P256Priv", account: tag) else {
            return nil
        }
        return try? P256.Signing.PrivateKey(rawRepresentation: data)
    }
    
    /// 加载 P256 公钥
    public nonisolated func loadP256PublicKey(tag: String) -> P256.Signing.PublicKey? {
        guard let data = exportKey(service: "SkyBridge.P256Pub", account: tag) else {
            return nil
        }
        return try? P256.Signing.PublicKey(rawRepresentation: data)
    }
    
    /// 生成 P256 密钥交换密钥对
    public nonisolated func generateP256KeyAgreementKeypair(tag: String) -> (private: P256.KeyAgreement.PrivateKey, public: P256.KeyAgreement.PublicKey)? {
        let privateKey = P256.KeyAgreement.PrivateKey()
        let publicKey = privateKey.publicKey
        
        let privData = privateKey.rawRepresentation
        let pubData = publicKey.rawRepresentation
        
        let ok1 = importKey(
            data: privData,
            service: "SkyBridge.P256KAPriv",
            account: tag,
            accessibility: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        )
        let ok2 = importKey(
            data: pubData,
            service: "SkyBridge.P256KAPub",
            account: tag
        )
        
        if !ok1 || !ok2 {
            return nil
        }
        
        return (privateKey, publicKey)
    }
    
    /// 加载 P256 密钥交换私钥
    public nonisolated func loadP256KeyAgreementPrivateKey(tag: String) -> P256.KeyAgreement.PrivateKey? {
        guard let data = exportKey(service: "SkyBridge.P256KAPriv", account: tag) else {
            return nil
        }
        return try? P256.KeyAgreement.PrivateKey(rawRepresentation: data)
    }
    
    // MARK: - Curve25519 Key Operations
    
    /// 生成并存储 Curve25519 签名密钥对
    public nonisolated func generateCurve25519SigningKeypair(tag: String) -> (private: Curve25519.Signing.PrivateKey, public: Curve25519.Signing.PublicKey)? {
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey
        
        let privData = privateKey.rawRepresentation
        let pubData = publicKey.rawRepresentation
        
        let ok1 = importKey(
            data: privData,
            service: "SkyBridge.Ed25519Priv",
            account: tag,
            accessibility: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        )
        let ok2 = importKey(
            data: pubData,
            service: "SkyBridge.Ed25519Pub",
            account: tag
        )
        
        if !ok1 || !ok2 {
            return nil
        }
        
        return (privateKey, publicKey)
    }
    
    /// 加载 Curve25519 签名私钥
    public nonisolated func loadCurve25519SigningPrivateKey(tag: String) -> Curve25519.Signing.PrivateKey? {
        guard let data = exportKey(service: "SkyBridge.Ed25519Priv", account: tag) else {
            return nil
        }
        return try? Curve25519.Signing.PrivateKey(rawRepresentation: data)
    }
    
    /// 加载 Curve25519 签名公钥
    public nonisolated func loadCurve25519SigningPublicKey(tag: String) -> Curve25519.Signing.PublicKey? {
        guard let data = exportKey(service: "SkyBridge.Ed25519Pub", account: tag) else {
            return nil
        }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: data)
    }
    
    /// 生成 X25519 密钥交换密钥对
    public nonisolated func generateX25519Keypair(tag: String) -> (private: Curve25519.KeyAgreement.PrivateKey, public: Curve25519.KeyAgreement.PublicKey)? {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let publicKey = privateKey.publicKey
        
        let privData = privateKey.rawRepresentation
        let pubData = publicKey.rawRepresentation
        
        let ok1 = importKey(
            data: privData,
            service: "SkyBridge.X25519Priv",
            account: tag,
            accessibility: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        )
        let ok2 = importKey(
            data: pubData,
            service: "SkyBridge.X25519Pub",
            account: tag
        )
        
        if !ok1 || !ok2 {
            return nil
        }
        
        return (privateKey, publicKey)
    }
    
    /// 加载 X25519 私钥
    public nonisolated func loadX25519PrivateKey(tag: String) -> Curve25519.KeyAgreement.PrivateKey? {
        guard let data = exportKey(service: "SkyBridge.X25519Priv", account: tag) else {
            return nil
        }
        return try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
    }
    
    // MARK: - Peer Key Storage
    
    /// 存储对端签名公钥
    public nonisolated func storePeerSigningPublicKey(_ keyData: Data, peerId: String) -> Bool {
        importKey(data: keyData, service: "SkyBridge.PeerSigningPub", account: peerId)
    }
    
    /// 获取对端签名公钥
    public nonisolated func retrievePeerSigningPublicKey(_ peerId: String) -> Data? {
        exportKey(service: "SkyBridge.PeerSigningPub", account: peerId)
    }
    
    // MARK: - Device Identity

    /// 获取或生成设备 ID
    public nonisolated func getOrGenerateDeviceId() -> String {
        do {
            return try getOrGenerateDeviceIdStrict()
        } catch {
            return ""
        }
    }

    /// 获取或生成设备 ID，保留 Keychain 错误语义。
    public nonisolated func getOrGenerateDeviceIdStrict() throws -> String {
        let service = "SkyBridge.Identity"
        let account = "DeviceUUID"

        if let data = try exportKeyStrict(service: service, account: account) {
            guard let uuidString = String(data: data, encoding: .utf8),
                  !uuidString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw KeychainError.decodingError
            }
            return uuidString
        }

        let newUUID = UUID().uuidString
        guard let data = newUUID.data(using: .utf8) else {
            throw KeychainError.encodingError
        }
        guard importKey(data: data, service: service, account: account) else {
            throw KeychainError.unexpectedError(errSecIO)
        }
        return newUUID
    }

    // MARK: - Session Key Storage
    
    /// 存储会话密钥
    public nonisolated func storeSessionKey(_ key: SymmetricKey, sessionId: String) -> Bool {
        storeSymmetricKey(key, account: "Session.\(sessionId)")
    }
    
    /// 加载会话密钥
    public nonisolated func loadSessionKey(sessionId: String) -> SymmetricKey? {
        loadSymmetricKey(account: "Session.\(sessionId)")
    }
    
    /// 删除会话密钥
    public nonisolated func deleteSessionKey(sessionId: String) -> Bool {
        deleteKey(service: "SkyBridge.SymmetricKey", account: "Session.\(sessionId)")
    }
    
    // MARK: - API Key Storage
    
    /// 存储 API 密钥
    public nonisolated func storeAPIKey(_ key: String, service: String, account: String) throws {
        guard let data = key.data(using: .utf8) else {
            throw KeychainError.encodingError
        }
        
        if !importKey(data: data, service: service, account: account) {
            throw KeychainError.unexpectedError(-1)
        }
    }
    
    /// 获取 API 密钥
    public nonisolated func retrieveAPIKey(service: String, account: String) throws -> String {
        guard let data = try exportKeyStrict(service: service, account: account),
              let key = String(data: data, encoding: .utf8) else {
            throw KeychainError.itemNotFound
        }
        return key
    }
    
    // MARK: - Cleanup
    
    /// 清理过期的会话密钥
    public nonisolated func cleanupExpiredSessionKeys() {
        // 在内存模式下，清理所有 Session 开头的密钥
        if Self.useInMemoryKeychain {
            Self.inMemoryLock.lock()
            Self.inMemoryStore = Self.inMemoryStore.filter { !$0.key.contains("Session.") }
            Self.inMemoryLock.unlock()
            return
        }
        
        do {
            let scope = try IOSLegacyKeychainScope.current()
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "SkyBridge.SymmetricKey",
                kSecMatchLimit as String: kSecMatchLimitAll,
                kSecReturnAttributes as String: true
            ]
            var items: CFTypeRef?
            let status = try scope.copyMatching(query, &items)
            if status == errSecItemNotFound { return }
            guard status == errSecSuccess else { throw KeychainError.unexpectedError(status) }
            guard let itemList = items as? [[String: Any]] else { throw KeychainError.decodingError }
            for item in itemList {
                guard let account = item[kSecAttrAccount as String] as? String,
                      account.hasPrefix("Session.") else { continue }
                try deleteKeyStrict(service: "SkyBridge.SymmetricKey", account: account)
            }
        } catch {
            SkyBridgeLogger.shared.error("Keychain session cleanup failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Generic Password (no-service) helpers

@available(iOS 17.0, *)
private extension KeychainManager {
    /// Save a generic password item addressed only by account (for backward compatibility with older storage).
    func saveGenericPassword(
        account: String,
        data: Data,
        accessibility: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    ) throws {
        try saveGenericPasswordData(
            account: account,
            data: data,
            accessibility: accessibility
        )
    }

    /// Load a generic password item addressed only by account (for backward compatibility with older storage).
    private nonisolated func genericPasswordData(account: String) throws -> Data {
        if Self.useInMemoryKeychain {
            let key = "GenericPassword|" + account
            Self.inMemoryLock.lock()
            let data = Self.inMemoryStore[key]
            Self.inMemoryLock.unlock()
            guard let data else { throw KeychainError.itemNotFound }
            return data
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = try IOSLegacyKeychainScope.current().copyMatching(query, &result)
        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                throw KeychainError.itemNotFound
            }
            throw KeychainError.unexpectedError(status)
        }
        guard let data = result as? Data else {
            throw KeychainError.decodingError
        }
        return data
    }

    private nonisolated func saveGenericPasswordData(
        account: String,
        data: Data,
        accessibility: CFString
    ) throws {
        if Self.useInMemoryKeychain {
            let key = "GenericPassword|" + account
            Self.inMemoryLock.lock()
            Self.inMemoryStore[key] = data
            Self.inMemoryLock.unlock()
            return
        }

        let updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account
        ]
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility
        ]
        let scope = try IOSLegacyKeychainScope.current()
        let updateStatus = try scope.update(updateQuery, updateAttributes)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedError(updateStatus)
        }

        var addQuery = updateQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = accessibility
        let addStatus = try scope.add(addQuery)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedError(addStatus)
        }
    }

    func loadGenericPassword(account: String) throws -> Data {
        do {
            return try genericPasswordData(account: account)
        } catch KeychainError.itemNotFound {
            throw KeychainError.itemNotFound
        } catch {
            throw error
        }
    }
    
    func deleteGenericPassword(account: String) {
        deleteGenericPasswordSync(account: account)
    }
}

// MARK: - PQC Key Storage (compat with PQCCryptoManager identifiers)

@available(iOS 17.0, *)
public extension KeychainManager {
    nonisolated func savePrivateKey(_ key: Data, identifier: String) throws {
        try saveGenericPasswordSync(
            account: identifier,
            data: key,
            accessibility: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        )
    }
    
    nonisolated func savePublicKey(_ key: Data, identifier: String) throws {
        try saveGenericPasswordSync(account: identifier, data: key)
    }
    
    nonisolated func loadPrivateKey(identifier: String) throws -> Data {
        try loadGenericPasswordSync(account: identifier)
    }
    
    nonisolated func loadPublicKey(identifier: String) throws -> Data {
        try loadGenericPasswordSync(account: identifier)
    }
    
    nonisolated func deleteKey(identifier: String) {
        deleteGenericPasswordSync(account: identifier)
    }
    
    // MARK: - Sync helpers for nonisolated access
    
    private nonisolated func saveGenericPasswordSync(
        account: String,
        data: Data,
        accessibility: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    ) throws {
        if Self.useInMemoryKeychain {
            let key = "GenericPassword|" + account
            Self.inMemoryLock.lock()
            Self.inMemoryStore[key] = data
            Self.inMemoryLock.unlock()
            return
        }
        
        try saveGenericPasswordData(
            account: account,
            data: data,
            accessibility: accessibility
        )
    }
    
    private nonisolated func loadGenericPasswordSync(account: String) throws -> Data {
        try genericPasswordData(account: account)
    }
    
    private nonisolated func deleteGenericPasswordSync(account: String) {
        do {
            try deleteGenericPasswordSyncStrict(account: account)
        } catch {
            SkyBridgeLogger.shared.error("❌ Keychain 删除失败 account=\(account): \(error.localizedDescription)")
        }
    }

    private nonisolated func deleteGenericPasswordSyncStrict(account: String) throws {
        if Self.useInMemoryKeychain {
            let key = "GenericPassword|" + account
            Self.inMemoryLock.lock()
            Self.inMemoryStore.removeValue(forKey: key)
            Self.inMemoryLock.unlock()
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account
        ]
        let status = try IOSLegacyKeychainScope.current().delete(query)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedError(status)
        }
    }
}

// MARK: - Supabase / Auth config (与 macOS 端同构)

@available(iOS 17.0, *)
public extension KeychainManager {
    struct SupabaseConfig: Codable, Sendable {
        public let url: String
        public let anonKey: String
        
        public init(url: String, anonKey: String) {
            self.url = url
            self.anonKey = anonKey
        }
    }
    
    func storeSupabaseConfig(url: String, anonKey: String) throws {
        let urlTrimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let anonTrimmed = anonKey.trimmingCharacters(in: .whitespacesAndNewlines)
        try saveGenericPasswordSync(account: "supabase.url", data: Data(urlTrimmed.utf8))
        try saveGenericPasswordSync(account: "supabase.anonKey", data: Data(anonTrimmed.utf8))
        
        // Compatibility: also store under the macOS-style service/account keys so iOS/macOS stay aligned conceptually.
        // This also helps when users switch between older/newer builds that used different key naming.
        try upsertKeyStrict(data: Data(urlTrimmed.utf8), service: "SkyBridge.Supabase", account: "URL")
        try upsertKeyStrict(data: Data(anonTrimmed.utf8), service: "SkyBridge.Supabase", account: "AnonKey")
        
        // SECURITY: Never store a Supabase service-role key on client devices.
        try deleteGenericPasswordSyncStrict(account: "supabase.serviceRoleKey")
        try deleteKeyStrict(service: "SkyBridge.Supabase", account: "ServiceRoleKey")
    }
    
    func retrieveSupabaseConfig() throws -> SupabaseConfig {
        do {
            let urlData = try loadGenericPasswordSync(account: "supabase.url")
            let anonData = try loadGenericPasswordSync(account: "supabase.anonKey")
            guard let url = String(data: urlData, encoding: .utf8),
                  let anon = String(data: anonData, encoding: .utf8) else {
                throw KeychainError.decodingError
            }
            // Best-effort: clean up any legacy stored service role key.
            try deleteGenericPasswordSyncStrict(account: "supabase.serviceRoleKey")
            try deleteKeyStrict(service: "SkyBridge.Supabase", account: "ServiceRoleKey")
            return SupabaseConfig(url: url, anonKey: anon)
        } catch KeychainError.itemNotFound {
            // Fallback: macOS-style keys (service-based)
            if let urlData = try exportKeyStrict(service: "SkyBridge.Supabase", account: "URL"),
               let anonData = try exportKeyStrict(service: "SkyBridge.Supabase", account: "AnonKey"),
               let url = String(data: urlData, encoding: .utf8),
               let anon = String(data: anonData, encoding: .utf8) {
                // Migrate forward to the current iOS storage keys for next launch.
                try storeSupabaseConfig(url: url, anonKey: anon)
                return SupabaseConfig(url: url, anonKey: anon)
            }
            throw KeychainError.itemNotFound
        }
    }

    /// 清除 Supabase 配置（用于从占位符/错误配置恢复）
    func deleteSupabaseConfig() throws {
        try deleteGenericPasswordSyncStrict(account: "supabase.url")
        try deleteGenericPasswordSyncStrict(account: "supabase.anonKey")
        try deleteGenericPasswordSyncStrict(account: "supabase.serviceRoleKey")
        try deleteKeyStrict(service: "SkyBridge.Supabase", account: "URL")
        try deleteKeyStrict(service: "SkyBridge.Supabase", account: "AnonKey")
        try deleteKeyStrict(service: "SkyBridge.Supabase", account: "ServiceRoleKey")
    }

    struct NebulaConfig: Codable, Sendable {
        public let baseURL: String
        public let clientId: String
        public let clientSecret: String?

        public init(baseURL: String, clientId: String, clientSecret: String?) {
            self.baseURL = baseURL
            self.clientId = clientId
            self.clientSecret = clientSecret
        }
    }

    nonisolated func storeNebulaConfig(baseURL: String, clientId: String, clientSecret: String?) throws {
        let baseURLTrimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientIdTrimmed = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientSecretTrimmed = clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines)

        try saveGenericPasswordSync(account: "nebula.baseURL", data: Data(baseURLTrimmed.utf8))
        try saveGenericPasswordSync(account: "nebula.clientId", data: Data(clientIdTrimmed.utf8))
        if let clientSecretTrimmed, !clientSecretTrimmed.isEmpty {
            try saveGenericPasswordSync(
                account: "nebula.clientSecret",
                data: Data(clientSecretTrimmed.utf8),
                accessibility: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            )
        } else {
            deleteGenericPasswordSync(account: "nebula.clientSecret")
        }

        _ = importKey(data: Data(baseURLTrimmed.utf8), service: "SkyBridge.Nebula", account: "BaseURL")
        _ = importKey(data: Data(clientIdTrimmed.utf8), service: "SkyBridge.Nebula", account: "ClientId")
        if let clientSecretTrimmed, !clientSecretTrimmed.isEmpty {
            _ = importKey(
                data: Data(clientSecretTrimmed.utf8),
                service: "SkyBridge.Nebula",
                account: "ClientSecret",
                accessibility: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            )
        } else {
            _ = deleteKey(service: "SkyBridge.Nebula", account: "ClientSecret")
        }
    }

    nonisolated func retrieveNebulaConfig() throws -> NebulaConfig {
        do {
            let baseURLData = try loadGenericPasswordSync(account: "nebula.baseURL")
            let clientIdData = try loadGenericPasswordSync(account: "nebula.clientId")
            let clientSecretData: Data?
            do {
                clientSecretData = try loadGenericPasswordSync(account: "nebula.clientSecret")
            } catch KeychainError.itemNotFound {
                // Client secret is explicitly optional; all other Keychain failures propagate.
                clientSecretData = nil
            }
            guard let baseURL = String(data: baseURLData, encoding: .utf8),
                  let clientId = String(data: clientIdData, encoding: .utf8) else {
                throw KeychainError.decodingError
            }
            let clientSecret = clientSecretData.flatMap { String(data: $0, encoding: .utf8) }
            return NebulaConfig(baseURL: baseURL, clientId: clientId, clientSecret: clientSecret)
        } catch KeychainError.itemNotFound {
            if let clientIdData = try exportKeyStrict(service: "SkyBridge.Nebula", account: "ClientId"),
               let clientId = String(data: clientIdData, encoding: .utf8) {
                let baseURL = try exportKeyStrict(service: "SkyBridge.Nebula", account: "BaseURL")
                    .flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let clientSecret = try exportKeyStrict(service: "SkyBridge.Nebula", account: "ClientSecret")
                    .flatMap { String(data: $0, encoding: .utf8) }
                try storeNebulaConfig(baseURL: baseURL, clientId: clientId, clientSecret: clientSecret)
                return NebulaConfig(baseURL: baseURL, clientId: clientId, clientSecret: clientSecret)
            }
            throw KeychainError.itemNotFound
        }
    }

    nonisolated func deleteNebulaConfig() {
        deleteGenericPasswordSync(account: "nebula.baseURL")
        deleteGenericPasswordSync(account: "nebula.clientId")
        deleteGenericPasswordSync(account: "nebula.clientSecret")
        _ = deleteKey(service: "SkyBridge.Nebula", account: "BaseURL")
        _ = deleteKey(service: "SkyBridge.Nebula", account: "ClientId")
        _ = deleteKey(service: "SkyBridge.Nebula", account: "ClientSecret")
    }
    
    private nonisolated static let protectedAuthSessionService = "com.skybridge.compass.ios.authsession.v2"
    private nonisolated static let authSessionAccount = "primary"
#if DEBUG || SKYBRIDGE_TESTING
    private nonisolated static let inMemoryAuthSessionStorage = IOSInMemoryAccountSessionStorage()
#endif

    private func protectedAuthSessionStore() throws -> ProtectedAccountSessionStore<AuthSession> {
#if DEBUG || SKYBRIDGE_TESTING
        if let accountTestDependencies {
            return ProtectedAccountSessionStore(storage: accountTestDependencies.storage)
        }
        if Self.useInMemoryKeychain {
            return ProtectedAccountSessionStore(storage: Self.inMemoryAuthSessionStorage)
        }
#endif
        // The build expands this exact app-private group. Security.framework checks
        // the signed entitlement on every operation; a plist value grants no access.
        let group = try Self.requiredAccountAccessGroup()
        return ProtectedAccountSessionStore(storage: try DataProtectionAccountSessionStorage(
            service: Self.protectedAuthSessionService, account: Self.authSessionAccount, accessGroup: group))
    }

    private nonisolated static func requiredAccountAccessGroup() throws -> String {
        try requiredAccountAccessGroup(
            Bundle.main.object(forInfoDictionaryKey: "SkyBridgeAccountKeychainAccessGroup") as? String,
            bundleIdentifier: Bundle.main.bundleIdentifier)
    }

    internal nonisolated static func requiredAccountAccessGroup(_ group: String?, bundleIdentifier: String?) throws -> String {
        guard let group, let bundleIdentifier, !bundleIdentifier.isEmpty,
              group.utf8.count <= 256, !group.contains("\0"), !bundleIdentifier.contains("\0"),
              group == group.trimmingCharacters(in: .whitespacesAndNewlines),
              bundleIdentifier == bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines),
              group.hasSuffix("." + bundleIdentifier),
              let prefix = group.split(separator: ".", maxSplits: 1).first, prefix.utf8.count == 10,
              prefix.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) }),
              group == String(prefix) + "." + bundleIdentifier else {
            throw ProtectedAccountSessionError.invalidRecord
        }
        return group
    }

    private func loadProtectedAuthSession(_ store: ProtectedAccountSessionStore<AuthSession>) throws -> IOSAuthSessionRecord? {
        do { return try store.load() }
        catch is DecodingError { throw KeychainError.decodingError }
    }

    /// Explicit login creates a new durable lifetime, including identical tokens.
    /// Native I/O remains on this actor's background serial executor.
    @discardableResult
    internal func storeAuthSession(_ session: AuthSession) throws -> IOSAuthSessionRecord {
        try installAuthSession(session, requireCurrent: {})
    }

    @discardableResult
    internal func storeAuthSession(_ session: AuthSession, intent: IOSAuthenticationIntent) throws -> IOSAuthSessionRecord {
        try installAuthSession(session, requireCurrent: intent.requireCurrent)
    }

    private func installAuthSession(_ session: AuthSession, requireCurrent: () throws -> Void) throws -> IOSAuthSessionRecord {
        try requireCurrent()
        let store = try protectedAuthSessionStore()
        let previous = try loadProtectedAuthSession(store)
        try requireCurrent()
        let installed = try store.install(session, replacing: previous)
        accountObservations.removeAll()
        try deleteLegacyAuthSession()
        return installed
    }

    internal func loadAuthSession() throws -> AuthSession? { try loadAuthSessionStrict() }

    internal func loadAuthSessionStrict() throws -> AuthSession? {
        try loadAuthSessionRecordStrict()?.session
    }

    internal func loadAuthSessionRecordStrict() throws -> IOSAuthSessionRecord? {
        try loadAuthSessionRecord(requireCurrent: {})
    }

    internal func loadAuthSessionRecordStrict(intent: IOSAuthenticationIntent) throws -> IOSAuthSessionRecord? {
        try loadAuthSessionRecord(requireCurrent: intent.requireCurrent)
    }

    private func loadAuthSessionRecord(requireCurrent: () throws -> Void) throws -> IOSAuthSessionRecord? {
        let store = try protectedAuthSessionStore()
        let record: IOSAuthSessionRecord?
        do {
            record = try store.loadMigratingLegacy({
                try requireCurrent()
                return try loadLegacyAuthSession()
            }, requireCurrent: requireCurrent)
        } catch is DecodingError {
            throw KeychainError.decodingError
        }
        // A canonical tombstone or malformed canonical item never reaches legacy
        // loading. A previous canonical commit may have outlived interrupted or
        // failed legacy retirement. Retry that idempotent cleanup on every valid
        // canonical load without replacing the record or renewing its lifetime.
        if record != nil {
            try requireCurrent()
            try deleteLegacyAuthSession()
        }
        return record
    }

    internal func beginAccountObservation(kind: ProtectedAccountObservation.Kind, expected: AuthSession,
                                 loginID: UUID, intent: IOSAuthenticationIntent) throws -> IOSAuthSessionObservation {
        let store = try protectedAuthSessionStore()
        let observation = ProtectedAccountObservation(kind: kind)
        for attempt in 0..<2 {
            try intent.requireCurrent()
            guard let current = try loadProtectedAuthSession(store), current.loginID == loginID, current.session == expected else {
                throw ProtectedAccountSessionError.changed
            }
            let owned = Set(accountObservations.values.filter {
                $0.loginID == loginID && $0.intent === intent
            }.map { $0.observation.id })
            let unresolvedCredential = current.version == 1 || current.observations.contains {
                $0.kind == .credential && !owned.contains($0.id)
            }
            try intent.requireCurrent()
            do {
                _ = try store.beginObservation(observation, owned: owned, replacing: current)
                let ticket = IOSAuthSessionObservation(observation: observation, loginID: loginID,
                    source: expected, intent: intent, requiresCredentialRecovery: unresolvedCredential)
                accountObservations[observation.id] = ticket
                return ticket
            } catch ProtectedAccountSessionError.changed {
                if attempt == 1 { throw ProtectedAccountSessionError.changed }
            }
        }
        throw ProtectedAccountSessionError.changed
    }

    /// An explicit no-write CAS conflict may reconcile once with this same owner.
    /// Every other failure consumes it and leaves its durable marker unresolved.
    internal func finishAccountObservation(_ ticket: IOSAuthSessionObservation, replacement: AuthSession? = nil,
                                  temporaryFailure: Bool = false,
                                  checkpoint: ProtectedAudioCheckpointUpdate = .unchanged,
                                  expectedAudioRevision: UUID? = nil) throws -> IOSAuthSessionRecord {
        guard accountObservations[ticket.observation.id] === ticket else {
            throw ProtectedAccountSessionError.changed
        }
        accountObservations.removeValue(forKey: ticket.observation.id)
        let store = try protectedAuthSessionStore()
        for attempt in 0..<2 {
            try ticket.intent.requireCurrent()
            guard let current = try loadProtectedAuthSession(store), current.loginID == ticket.loginID,
                  current.observations.contains(ticket.observation),
                  ticket.observation.kind != .credential || current.session == ticket.source,
                  expectedAudioRevision == nil || current.audioRevision == expectedAudioRevision else {
                throw ProtectedAccountSessionError.changed
            }
            try ticket.intent.requireCurrent()
            do {
                return try store.finishObservation(ticket.observation, replacementSession: replacement,
                    checkpoint: checkpoint,
                    keepUnverifiedCredential: temporaryFailure && ticket.requiresCredentialRecovery,
                    replacing: current)
            } catch ProtectedAccountSessionError.changed {
                if attempt == 1 { throw ProtectedAccountSessionError.changed }
            }
        }
        throw ProtectedAccountSessionError.changed
    }

    internal func abandonAccountObservation(_ ticket: IOSAuthSessionObservation) {
        if accountObservations[ticket.observation.id] === ticket {
            accountObservations.removeValue(forKey: ticket.observation.id)
        }
    }

    /// An exact source AND durable login are required. The one bounded conflict
    /// retry accepts only the same login and source/replacement credentials, while
    /// preserving the latest checkpoint or rejection written by another owner.
    internal func replaceAuthSession(expected: AuthSession, expectedLoginID: UUID,
                                   with replacement: AuthSession) throws -> Bool {
        try replaceAuthSession(expected: expected, expectedLoginID: expectedLoginID,
                               with: replacement, requireCurrent: {})
    }

    internal func replaceAuthSession(expected: AuthSession, expectedLoginID: UUID,
                            with replacement: AuthSession, intent: IOSAuthenticationIntent) throws -> Bool {
        try replaceAuthSession(expected: expected, expectedLoginID: expectedLoginID,
                               with: replacement, requireCurrent: intent.requireCurrent)
    }

    private func replaceAuthSession(expected: AuthSession, expectedLoginID: UUID,
                                    with replacement: AuthSession, requireCurrent: () throws -> Void) throws -> Bool {
        let store = try protectedAuthSessionStore()
        for attempt in 0..<2 {
            try requireCurrent()
            guard let current = try loadProtectedAuthSession(store), current.loginID == expectedLoginID else { return false }
            if current.session == replacement { return true }
            guard current.session == expected else { return false }
            try requireCurrent()
            do { _ = try store.refresh(replacement, replacing: current); return true }
            catch ProtectedAccountSessionError.changed {
                if attempt == 1 { return false }
            }
        }
        return false
    }

    internal func revokeAudioAuthorization(expected: AuthSession, loginID: UUID,
                                  intent: IOSAuthenticationIntent) throws {
        let store = try protectedAuthSessionStore()
        for attempt in 0..<2 {
            try intent.requireCurrent()
            guard let current = try loadProtectedAuthSession(store), current.loginID == loginID,
                  current.session == expected else { throw ProtectedAccountSessionError.changed }
            if current.audioRevoked { return }
            try intent.requireCurrent()
            do { _ = try store.revokeAudio(replacing: current); return }
            catch ProtectedAccountSessionError.changed {
                if attempt == 1 { throw ProtectedAccountSessionError.changed }
            }
        }
        throw ProtectedAccountSessionError.changed
    }

    internal func loadAudioMembershipCheckpoint(loginID: UUID, intent: IOSAuthenticationIntent) throws
        -> AudioMembershipPersistenceSnapshot {
        try intent.requireCurrent()
        guard let record = try loadProtectedAuthSession(protectedAuthSessionStore()),
              record.loginID == loginID, record.session != nil else {
            throw ProtectedAccountSessionError.changed
        }
        guard !record.audioRevoked else { throw ProtectedAccountSessionError.audioRevoked }
        try requireOwnedAudioObservations(record, loginID: loginID, intent: intent)
        try intent.requireCurrent()
        return .init(revision: record.audioRevision, checkpoint: record.audioCheckpoint)
    }

    internal func saveAudioMembershipCheckpoint(_ bytes: Data?, replacing revision: UUID,
                                                loginID: UUID, intent: IOSAuthenticationIntent) throws
        -> AudioMembershipPersistenceSnapshot {
        let store = try protectedAuthSessionStore()
        // Only an explicit no-write CAS conflict may retry once. A credential
        // refresh can change the root revision, but never the login/audio witness.
        for attempt in 0..<2 {
            try intent.requireCurrent()
            guard let record = try loadProtectedAuthSession(store), record.loginID == loginID,
                  record.audioRevision == revision, record.session != nil else {
                throw ProtectedAccountSessionError.changed
            }
            guard !record.audioRevoked else { throw ProtectedAccountSessionError.audioRevoked }
            try requireOwnedAudioObservations(record, loginID: loginID, intent: intent)
            try intent.requireCurrent()
            do {
                let saved = try store.saveAudioCheckpoint(bytes, replacing: record)
                return .init(revision: saved.audioRevision, checkpoint: saved.audioCheckpoint)
            } catch ProtectedAccountSessionError.changed {
                if attempt == 1 { throw ProtectedAccountSessionError.changed }
            }
        }
        throw ProtectedAccountSessionError.changed
    }

    private func requireOwnedAudioObservations(_ record: IOSAuthSessionRecord, loginID: UUID,
                                               intent: IOSAuthenticationIntent) throws {
        guard record.version == 2, record.observations.allSatisfy({ observation in
            guard let owner = accountObservations[observation.id] else { return false }
            return owner.loginID == loginID && owner.intent === intent
        }) else { throw ProtectedAccountSessionError.verificationRequired }
    }

    internal func deleteAuthSession() throws { try clearAuthSession(requireCurrent: {}) }

    internal func deleteAuthSession(intent: IOSAuthenticationIntent) throws {
        try clearAuthSession(requireCurrent: intent.requireCurrent)
    }

    private func clearAuthSession(requireCurrent: () throws -> Void) throws {
        try requireCurrent()
        let store = try protectedAuthSessionStore()
        let current = try loadProtectedAuthSession(store)
        try requireCurrent()
        _ = try store.clear(replacing: current)
        accountObservations.removeAll()
        try deleteLegacyAuthSession()
    }

    private func loadLegacyAuthSession() throws -> AuthSession? {
        let data: Data
#if DEBUG || SKYBRIDGE_TESTING
        if let accountTestDependencies {
            guard let bytes = try accountTestDependencies.loadLegacy() else { return nil }
            return try decodeLegacyAuthSession(bytes)
        }
#endif
        if Self.useInMemoryKeychain {
            do { data = try loadGenericPasswordSync(account: "auth.session") }
            catch KeychainError.itemNotFound { return nil }
        } else {
            // The old writer inserted an item with no service into the default
            // app-private group. Do not search or retire other accessible groups.
            guard let legacy = try loadImmutableKeyStrict(service: "", account: "auth.session",
                accessGroup: Self.requiredAccountAccessGroup()) else { return nil }
            data = legacy
        }
        return try decodeLegacyAuthSession(data)
    }

    private func decodeLegacyAuthSession(_ data: Data) throws -> AuthSession {
        guard data.count <= ProtectedAccountSessionStore<AuthSession>.maximumSessionBytes else {
            throw ProtectedAccountSessionError.capacity
        }
        do { return try JSONDecoder().decode(AuthSession.self, from: data) }
        catch { throw KeychainError.decodingError }
    }

    private func deleteLegacyAuthSession() throws {
#if DEBUG || SKYBRIDGE_TESTING
        if let accountTestDependencies { try accountTestDependencies.deleteLegacy(); return }
#endif
        if Self.useInMemoryKeychain { try deleteGenericPasswordSyncStrict(account: "auth.session"); return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "", kSecAttrAccount as String: "auth.session",
            kSecAttrAccessGroup as String: try Self.requiredAccountAccessGroup(),
            kSecAttrSynchronizable as String: false,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedError(status)
        }
    }

}

/// Native boundary for the two namespaces used before App Groups admission.
/// Explicit immutable identity and account-session stores retain their own scopes.
@available(iOS 17.0, *)
struct IOSLegacyKeychainScope: Sendable {
    let applicationGroup: String
    let sharedIdentityGroup: String

    private nonisolated init(applicationGroup: String, sharedIdentityGroup: String) {
        self.applicationGroup = applicationGroup
        self.sharedIdentityGroup = sharedIdentityGroup
    }

    nonisolated static func current() throws -> Self {
        let application = try KeychainManager.requiredAccountAccessGroup(
            Bundle.main.object(forInfoDictionaryKey: "SkyBridgeAccountKeychainAccessGroup") as? String,
            bundleIdentifier: Bundle.main.bundleIdentifier)
        let prefix = application.prefix(10)
        return Self(applicationGroup: application,
                    sharedIdentityGroup: String(prefix) + ".group.com.skybridge.compass")
    }

    /// A new entitlement must never enlarge a legacy query. Read both original
    /// groups before returning one result; an inaccessible group is not absence.
    /// Identity migration explicitly asks for all records so its existing
    /// reconciliation policy can inspect conflicts and exact persistent refs.
    nonisolated func copyMatching(_ query: [String: Any], _ result: inout CFTypeRef?) throws -> OSStatus {
        result = nil
        try validateUnscopedInput(query)
        let limit: String
        if let value = query[kSecMatchLimit as String] {
            guard let string = value as? String else { throw KeychainError.unexpectedError(errSecParam) }
            limit = string
        } else {
            limit = kSecMatchLimitOne as String
        }
        guard limit == kSecMatchLimitOne as String || limit == kSecMatchLimitAll as String else {
            throw KeychainError.unexpectedError(errSecParam)
        }
        let all = limit == kSecMatchLimitAll as String
        var matches: [CFTypeRef] = []
        for group in [applicationGroup, sharedIdentityGroup] {
            var scoped = query
            scoped[kSecAttrAccessGroup as String] = group
            var found: CFTypeRef?
            let status = SecItemCopyMatching(scoped as CFDictionary, &found)
            if status == errSecItemNotFound { continue }
            guard status == errSecSuccess else { return status }
            guard let found else { throw KeychainError.decodingError }
            if all {
                guard let rows = found as? [AnyObject], !rows.isEmpty else { throw KeychainError.decodingError }
                matches.append(contentsOf: rows)
            } else {
                matches.append(found)
            }
        }
        guard !matches.isEmpty else { return errSecItemNotFound }
        if all {
            result = matches as NSArray
        } else {
            guard matches.count == 1 else { throw KeychainError.ambiguousAccessGroup }
            result = matches[0]
        }
        return errSecSuccess
    }

    /// Keep a legacy shared record in its existing namespace. Never update both
    /// groups or reinterpret a group conflict as a missing item to be re-created.
    nonisolated func update(_ query: [String: Any], _ updateAttributes: [String: Any]) throws -> OSStatus {
        guard updateAttributes[kSecAttrAccessGroup as String] == nil else {
            throw KeychainError.unexpectedError(errSecParam)
        }
        guard let group = try matchingGroup(query) else { return errSecItemNotFound }
        var updateQuery = query
        updateQuery[kSecAttrAccessGroup as String] = group
        return SecItemUpdate(updateQuery as CFDictionary, updateAttributes as CFDictionary)
    }

    nonisolated func add(_ query: [String: Any]) throws -> OSStatus {
        SecItemAdd(try privateInsert(query) as CFDictionary, nil)
    }

    nonisolated func add(_ query: [String: Any], result: inout CFTypeRef?) throws -> OSStatus {
        SecItemAdd(try privateInsert(query) as CFDictionary, &result)
    }

    nonisolated func delete(_ query: [String: Any]) throws -> OSStatus {
        guard let group = try matchingGroup(query) else { return errSecItemNotFound }
        var scoped = query
        scoped[kSecAttrAccessGroup as String] = group
        return SecItemDelete(scoped as CFDictionary)
    }

    private nonisolated func privateInsert(_ query: [String: Any]) throws -> [String: Any] {
        try validateUnscopedInput(query)
        var scoped = query
        scoped[kSecAttrAccessGroup as String] = applicationGroup
        return scoped
    }

    private nonisolated func matchingGroup(_ query: [String: Any]) throws -> String? {
        var lookup = query
        lookup.removeValue(forKey: kSecReturnData as String)
        lookup.removeValue(forKey: kSecReturnRef as String)
        lookup.removeValue(forKey: kSecReturnPersistentRef as String)
        lookup[kSecReturnAttributes as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = try copyMatching(lookup, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedError(status) }
        guard let attributes = result as? [String: Any],
              let group = attributes[kSecAttrAccessGroup as String] as? String,
              group == applicationGroup || group == sharedIdentityGroup else {
            throw KeychainError.decodingError
        }
        return group
    }

    private nonisolated func validateUnscopedInput(_ query: [String: Any]) throws {
        // Explicitly scoped stores use Security.framework directly. Reject a
        // conflicting caller scope instead of silently overriding it.
        guard query[kSecAttrAccessGroup as String] == nil else {
            throw KeychainError.unexpectedError(errSecParam)
        }
    }
}


final class IOSKeychainSerialExecutor: SerialExecutor, @unchecked Sendable {
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

#if DEBUG || SKYBRIDGE_TESTING
/// Uses the existing test-only Keychain mode. Device admission uses the signed
/// Data Protection Keychain, never this controlled storage adapter.
final class IOSInMemoryAccountSessionStorage: ProtectedAccountSessionStorage, Sendable {
    private let value = OSAllocatedUnfairLock<ProtectedAccountSessionValue?>(initialState: nil)
    func load() throws -> ProtectedAccountSessionValue? { value.withLock { $0 } }
    func insert(_ replacement: ProtectedAccountSessionValue) throws -> Bool {
        value.withLock { value in
            guard value == nil else { return false }
            value = replacement; return true
        }
    }
    func replace(expectedRevision: UUID, with replacement: ProtectedAccountSessionValue) throws -> Bool {
        value.withLock { value in
            guard value?.revision == expectedRevision else { return false }
            value = replacement; return true
        }
    }
}
#endif
