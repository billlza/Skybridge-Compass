//
// TrustSyncService.swift
// SkyBridgeCore
//
// iOS/iPadOS P2P Integration - Trust Sync Service
// Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7, 3.8
//
// 设备信任记录的 iCloud 同步服务：
// 1. 支持 tombstone 防止幽灵复活
// 2. 冲突解决：revoke 优先 + LWW
// 3. iCloud Keychain 同步（kSecAttrSynchronizable）
//

import Foundation
import CryptoKit
import Security

// MARK: - Trust Record Type

/// 信任记录类型
public enum TrustRecordType: String, Codable, Sendable {
 /// 添加信任
    case add = "add"
    
 /// 撤销信任（tombstone）
    case revoke = "revoke"
}

// MARK: - Trust Record

/// 信任记录
public struct TrustRecord: Codable, Sendable, Equatable, Identifiable {
 /// 记录 ID（deviceId 作为主键）
    public var id: String { deviceId }
    
 /// 设备 ID
    public let deviceId: String
    
 /// 公钥指纹 (SHA-256 hex, 64 chars)
    public let pubKeyFP: String
    
 /// 公钥数据
    public let publicKey: Data

 /// Secure Enclave PoP 公钥（可选，用于握手阶段额外校验）
    public let secureEnclavePublicKey: Data?
    
 /// 协议签名公钥 (Ed25519/ML-DSA)（ 7.2）
 ///
 /// 新版本使用此字段存储协议签名公钥。
 /// 如果为 nil，回退到 `publicKey` 字段。
    public let protocolPublicKey: Data?
    
 /// Legacy P-256 身份公钥（ 7.2）
 ///
 /// 迁移期保留，用于向后兼容验证。
 /// 当对端是旧版本时，允许 fallback 到 P-256 ECDSA 验证。
    public let legacyP256PublicKey: Data?
    
 /// 对端使用的签名算法（ 7.2）
    public let signatureAlgorithm: SignatureAlgorithm?
    
 /// KEM 身份公钥（可选）
    public let kemPublicKeys: [KEMPublicKeyInfo]?
    
 /// 证明等级
    public let attestationLevel: P2PAttestationLevel
    
 /// 证明数据
    public let attestationData: Data?
    
 /// 设备能力
    public let capabilities: [String]
    
 /// 创建时间
    public let createdAt: Date
    
 /// 更新时间
    public let updatedAt: Date
    
 /// 版本号
    public let version: Int

 /// 签名（由本机管理密钥签名）
    public let signature: Data
    
 /// 记录类型
    public let recordType: TrustRecordType
    
 /// 撤销时间（tombstone）
    public let revokedAt: Date?
    
 /// 设备名称（用于 UI 显示）
    public let deviceName: String?
    
 /// 短 ID（用于 UI 显示）
    public var shortId: String {
        String(pubKeyFP.prefix(P2PConstants.pubKeyFPDisplayLength))
    }
    
 /// 是否为 tombstone
    public var isTombstone: Bool {
        recordType == .revoke
    }
    
 /// 是否过期（tombstone 30 天后过期）
    public var isExpired: Bool {
        guard let revokedAt = revokedAt else { return false }
        let expirationDate = revokedAt.addingTimeInterval(30 * 24 * 60 * 60) // 30 天
        return Date() > expirationDate
    }
    
 /// 是否允许 legacy P-256 fallback（ 7.2）
 ///
 /// 只有当 TrustRecord 明确记录了 legacy P-256 公钥时才允许 fallback。
 /// 首次连接（无 TrustRecord）不允许 fallback。
    public var allowsLegacyFallback: Bool {
        legacyP256PublicKey != nil
    }
    
 /// 获取用于验证的公钥（ 7.2）
 ///
 /// 根据预期算法返回对应的公钥。
 /// - Parameter algorithm: 预期的签名算法
 /// - Returns: 用于验证的公钥，如果没有对应算法的公钥则返回 nil
    public func getVerificationPublicKey(for algorithm: SignatureAlgorithm) -> Data? {
        switch algorithm {
        case .ed25519, .mlDSA65:
 // 优先使用新的协议公钥，回退到旧的 publicKey
            return protocolPublicKey ?? publicKey
        case .p256ECDSA:
 // P-256 用于 legacy 验证或 SE PoP
            return legacyP256PublicKey ?? secureEnclavePublicKey
        }
    }
    
    public init(
        deviceId: String,
        pubKeyFP: String,
        publicKey: Data,
        secureEnclavePublicKey: Data? = nil,
        protocolPublicKey: Data? = nil,
        legacyP256PublicKey: Data? = nil,
        signatureAlgorithm: SignatureAlgorithm? = nil,
        kemPublicKeys: [KEMPublicKeyInfo]? = nil,
        attestationLevel: P2PAttestationLevel = .none,
        attestationData: Data? = nil,
        capabilities: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        version: Int = 1,
        signature: Data,
        recordType: TrustRecordType = .add,
        revokedAt: Date? = nil,
        deviceName: String? = nil
    ) {
        self.deviceId = deviceId
        self.pubKeyFP = pubKeyFP
        self.publicKey = publicKey
        self.secureEnclavePublicKey = secureEnclavePublicKey
        self.protocolPublicKey = protocolPublicKey
        self.legacyP256PublicKey = legacyP256PublicKey
        self.signatureAlgorithm = signatureAlgorithm
        self.kemPublicKeys = kemPublicKeys
        self.attestationLevel = attestationLevel
        self.attestationData = attestationData
        self.capabilities = capabilities
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.version = version
        self.signature = signature
        self.recordType = recordType
        self.revokedAt = revokedAt
        self.deviceName = deviceName
    }
    
 /// 创建撤销记录（tombstone）
    public func revoked(signature: Data) -> TrustRecord {
        TrustRecord(
            deviceId: deviceId,
            pubKeyFP: pubKeyFP,
            publicKey: publicKey,
            secureEnclavePublicKey: secureEnclavePublicKey,
            protocolPublicKey: protocolPublicKey,
            legacyP256PublicKey: legacyP256PublicKey,
            signatureAlgorithm: signatureAlgorithm,
            kemPublicKeys: kemPublicKeys,
            attestationLevel: attestationLevel,
            attestationData: attestationData,
            capabilities: capabilities,
            createdAt: createdAt,
            updatedAt: Date(),
            version: version + 1,
            signature: signature,
            recordType: .revoke,
            revokedAt: Date(),
            deviceName: deviceName
        )
    }
}

// MARK: - Trust Record Envelope

/// 信任记录信封（用于 iCloud 同步）
public struct TrustRecordEnvelope: Codable, Sendable {
 /// 信任记录
    public let record: TrustRecord
    
 /// 创建此记录的本机 ID
    public let localDeviceId: String
    
 /// 信封签名（由本机管理密钥签名）
    public let envelopeSignature: Data
    
 /// 创建时间
    public let createdAt: Date
    
    public init(
        record: TrustRecord,
        localDeviceId: String,
        envelopeSignature: Data,
        createdAt: Date = Date()
    ) {
        self.record = record
        self.localDeviceId = localDeviceId
        self.envelopeSignature = envelopeSignature
        self.createdAt = createdAt
    }
    
 /// 获取待签名数据
    public func dataToSign() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(record)
    }
}

// MARK: - Sync Status

/// 同步状态
public enum SyncStatus: String, Sendable {
    case idle = "idle"
    case syncing = "syncing"
    case synced = "synced"
    case failed = "failed"
    case unavailable = "unavailable"
}

// MARK: - Trust Sync Error

/// 信任同步错误
public enum TrustSyncError: Error, LocalizedError, Sendable {
    case recordNotFound
    case signatureFailed(String)
    case verificationFailed
    case keychainError(OSStatus)
    case syncUnavailable
    case conflictResolutionFailed
    case encodingError(String)
    case decodingError(String)
    
    public var errorDescription: String? {
        switch self {
        case .recordNotFound:
            return "Trust record not found"
        case .signatureFailed(let reason):
            return "Signature failed: \(reason)"
        case .verificationFailed:
            return "Signature verification failed"
        case .keychainError(let status):
            return "Keychain error: \(status)"
        case .syncUnavailable:
            return "iCloud sync is not available"
        case .conflictResolutionFailed:
            return "Conflict resolution failed"
        case .encodingError(let reason):
            return "Encoding error: \(reason)"
        case .decodingError(let reason):
            return "Decoding error: \(reason)"
        }
    }
}


// MARK: - Trust Sync Service

/// 信任同步服务 - iCloud Keychain 同步
@available(macOS 14.0, iOS 17.0, *)
@MainActor
public final class TrustSyncService: ObservableObject {
    
 // MARK: - Singleton
    
 /// 共享实例
    public static let shared = TrustSyncService()
    
 // MARK: - Constants
    
    private enum KeychainConstants {
        static let service = "com.skybridge.p2p.trust"
        static let recordPrefix = "trust_record_"
        static let syncEnabled = "sync_enabled"
    }
    
 // MARK: - Published Properties
    
 /// 同步状态
    @Published public var syncStatus: SyncStatus = .idle
    
 /// 活跃的信任记录
    @Published public var activeTrustRecords: [TrustRecord] = []
    
 /// 最后同步时间
    @Published public var lastSyncTime: Date?
    
 // MARK: - Properties
    
 /// 密钥管理器
    private let keyManager = DeviceIdentityKeyManager.shared
    
 /// 本地缓存
    private var localCache: [String: TrustRecord] = [:]
    
 // MARK: - Initialization
    
    private init() {
        Task {
            await loadLocalRecords()
        }
    }
    
 // MARK: - Public Properties
    
 /// 同步前提条件检查
    public var isSyncAvailable: Bool {
 // 检查 iCloud 登录状态
        FileManager.default.ubiquityIdentityToken != nil
    }
    
 // MARK: - Public Methods
    
 /// 添加信任记录
 /// - Parameter record: 信任记录（不含签名）
 /// - Returns: 签名后的信任记录
    @discardableResult
    public func addTrustRecord(_ record: TrustRecord) async throws -> TrustRecord {
 // 检查是否已存在
        if let existing = localCache[record.deviceId] {
 // 如果已存在且不是 tombstone，更新
            if !existing.isTombstone {
                return try await updateTrustRecord(record)
            }
 // 如果是 tombstone，不允许重新添加同一 deviceId
            throw TrustSyncError.conflictResolutionFailed
        }
        
 // 签名记录
        let signedRecord = try await signRecord(record)
        
 // 保存到本地
        try saveToKeychain(signedRecord, synchronizable: isSyncAvailable)
        localCache[signedRecord.deviceId] = signedRecord
        
 // 更新 UI
        await updateActiveTrustRecords()
        
        SkyBridgeLogger.p2p.info("Added trust record: \(signedRecord.shortId)")
        return signedRecord
    }
    
 /// 撤销信任记录（创建 tombstone）
 /// - Parameter deviceId: 设备 ID
    public func revokeTrustRecord(deviceId: String) async throws {
        guard let existing = localCache[deviceId] else {
            throw TrustSyncError.recordNotFound
        }
        
 // 创建撤销记录
        let dataToSign = try createDataToSign(for: existing, revoked: true)
        let signature = try await keyManager.sign(data: dataToSign)
        let revokedRecord = existing.revoked(signature: signature)
        
 // 保存到本地
        try saveToKeychain(revokedRecord, synchronizable: isSyncAvailable)
        localCache[deviceId] = revokedRecord
        
 // 更新 UI
        await updateActiveTrustRecords()
        
        SkyBridgeLogger.p2p.info("Revoked trust record: \(revokedRecord.shortId)")
    }
    
 /// 获取所有有效信任记录（排除 tombstone）
    public func getActiveTrustRecords() async -> [TrustRecord] {
        return localCache.values.filter { !$0.isTombstone && !$0.isExpired }
    }
    
 /// 获取信任记录
 /// - Parameter deviceId: 设备 ID
 /// - Returns: 信任记录（如果存在）
    public func getTrustRecord(deviceId: String) -> TrustRecord? {
        guard let record = localCache[deviceId] else { return nil }
        return record.isTombstone ? nil : record
    }
    
 /// 检查设备是否受信任
 /// - Parameter deviceId: 设备 ID
 /// - Returns: 是否受信任
    public func isTrusted(deviceId: String) -> Bool {
        guard let record = localCache[deviceId] else { return false }
        return !record.isTombstone && !record.isExpired
    }
    
 /// 检查公钥指纹是否受信任
 /// - Parameter pubKeyFP: 公钥指纹
 /// - Returns: 是否受信任
    public func isTrusted(pubKeyFP: String) -> Bool {
        return localCache.values.contains { 
            $0.pubKeyFP == pubKeyFP && !$0.isTombstone && !$0.isExpired 
        }
    }
    
 /// 同步信任记录
    public func sync() async throws {
        guard isSyncAvailable else {
            syncStatus = .unavailable
            throw TrustSyncError.syncUnavailable
        }
        
        syncStatus = .syncing
        
        do {
 // 从 Keychain 加载所有记录（包括同步的）
            let allRecords = try loadAllFromKeychain()
            
 // 解决冲突
            for record in allRecords {
                if let existing = localCache[record.deviceId] {
                    let resolved = resolveConflict(local: existing, remote: record)
                    localCache[record.deviceId] = resolved
                } else {
                    localCache[record.deviceId] = record
                }
            }
            
 // 清理过期 tombstone
            await cleanupExpiredTombstones()
            
 // 更新 UI
            await updateActiveTrustRecords()
            
            syncStatus = .synced
            lastSyncTime = Date()
            
            SkyBridgeLogger.p2p.info("Trust sync completed, \(self.activeTrustRecords.count) active records")
        } catch {
            syncStatus = .failed
            throw error
        }
    }
    
 /// 清理过期 tombstone（30 天）
    public func cleanupExpiredTombstones() async {
        let expiredIds = localCache.filter { $0.value.isExpired }.map { $0.key }
        
        for deviceId in expiredIds {
            deleteFromKeychain(deviceId: deviceId)
            localCache.removeValue(forKey: deviceId)
        }
        
        if !expiredIds.isEmpty {
            SkyBridgeLogger.p2p.info("Cleaned up \(expiredIds.count) expired tombstones")
        }
    }

    
 /// Key Rotation 处理
 /// - Parameters:
 /// - oldDeviceId: 旧设备 ID
 /// - newDeviceId: 新设备 ID
 /// - newCertificate: 新证书
    public func handleKeyRotation(
        oldDeviceId: String,
        newDeviceId: String,
        newCertificate: P2PIdentityCertificate
    ) async throws {
 // 撤销旧设备
        if localCache[oldDeviceId] != nil {
            try await revokeTrustRecord(deviceId: oldDeviceId)
        }
        
 // 添加新设备
        let newRecord = TrustRecord(
            deviceId: newDeviceId,
            pubKeyFP: newCertificate.pubKeyFP,
            publicKey: newCertificate.publicKey,
            secureEnclavePublicKey: newCertificate.publicKey,
            kemPublicKeys: newCertificate.kemPublicKeys,
            attestationLevel: newCertificate.attestationLevel,
            attestationData: newCertificate.attestationData,
            capabilities: newCertificate.capabilities,
            signature: Data(), // 将在 addTrustRecord 中签名
            deviceName: nil
        )
        
        try await addTrustRecord(newRecord)
        
        SkyBridgeLogger.p2p.info("Key rotation: \(oldDeviceId) -> \(newDeviceId)")
    }
    
 // MARK: - Conflict Resolution
    
 /// 解决冲突（revoke 优先 + LWW）
    public func resolveConflict(
        local: TrustRecord,
        remote: TrustRecord
    ) -> TrustRecord {
 // 1. revoke 永远优先于 add
        if local.recordType == .revoke || remote.recordType == .revoke {
            if local.recordType == .revoke && remote.recordType == .revoke {
                return local.updatedAt > remote.updatedAt ? local : remote
            }
            return local.recordType == .revoke ? local : remote
        }

 // 2. 同类型使用 LWW (Last Writer Wins)
        return local.updatedAt > remote.updatedAt ? local : remote
    }
    
 // MARK: - Private Methods
    
 /// 加载本地记录
    private func loadLocalRecords() async {
        do {
            let records = try loadAllFromKeychain()
            for record in records {
                localCache[record.deviceId] = record
            }
            await updateActiveTrustRecords()
            SkyBridgeLogger.p2p.debug("Loaded \(records.count) trust records from Keychain")
        } catch {
            // errSecParam(-50) 在部分系统/环境下会出现在 synchronizable 查询中；
            // 对于启动期加载而言，视作“暂无可用 trust records”更合理，避免刷错误日志。
            if let e = error as? TrustSyncError, case .keychainError(let status) = e, status == errSecParam {
                SkyBridgeLogger.p2p.debug("Trust records load skipped (errSecParam=-50)")
                return
            }
            SkyBridgeLogger.p2p.error("Failed to load trust records: \(error.localizedDescription)")
        }
    }
    
 /// 更新活跃信任记录
    private func updateActiveTrustRecords() async {
        activeTrustRecords = await getActiveTrustRecords()
    }
    
 /// 签名记录
    private func signRecord(_ record: TrustRecord) async throws -> TrustRecord {
        let dataToSign = try createDataToSign(for: record, revoked: false)
        let signature = try await keyManager.sign(data: dataToSign)
        
        return TrustRecord(
            deviceId: record.deviceId,
            pubKeyFP: record.pubKeyFP,
            publicKey: record.publicKey,
            secureEnclavePublicKey: record.secureEnclavePublicKey,
            protocolPublicKey: record.protocolPublicKey,
            legacyP256PublicKey: record.legacyP256PublicKey,
            signatureAlgorithm: record.signatureAlgorithm,
            kemPublicKeys: record.kemPublicKeys,
            attestationLevel: record.attestationLevel,
            attestationData: record.attestationData,
            capabilities: record.capabilities,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            version: record.version,
            signature: signature,
            recordType: record.recordType,
            revokedAt: record.revokedAt,
            deviceName: record.deviceName
        )
    }
    
 /// 更新信任记录
    private func updateTrustRecord(_ record: TrustRecord) async throws -> TrustRecord {
        guard let existing = localCache[record.deviceId] else {
            throw TrustSyncError.recordNotFound
        }
        
        let updatedRecord = TrustRecord(
            deviceId: record.deviceId,
            pubKeyFP: record.pubKeyFP,
            publicKey: record.publicKey,
            secureEnclavePublicKey: record.secureEnclavePublicKey,
            protocolPublicKey: record.protocolPublicKey,
            legacyP256PublicKey: record.legacyP256PublicKey,
            signatureAlgorithm: record.signatureAlgorithm,
            kemPublicKeys: record.kemPublicKeys,
            attestationLevel: record.attestationLevel,
            attestationData: record.attestationData,
            capabilities: record.capabilities,
            createdAt: existing.createdAt,
            updatedAt: Date(),
            version: existing.version + 1,
            signature: Data(), // 将被签名
            recordType: .add,
            revokedAt: nil,
            deviceName: record.deviceName
        )
        
        let signedRecord = try await signRecord(updatedRecord)
        try saveToKeychain(signedRecord, synchronizable: isSyncAvailable)
        localCache[signedRecord.deviceId] = signedRecord
        
        await updateActiveTrustRecords()
        return signedRecord
    }
    
 /// 创建待签名数据
    private func createDataToSign(for record: TrustRecord, revoked: Bool) throws -> Data {
        var encoder = DeterministicEncoder()
        encoder.encode(record.deviceId)
        encoder.encode(record.pubKeyFP)
        encoder.encode(record.publicKey)
        if let seKey = record.secureEnclavePublicKey {
            encoder.encode(seKey)
        }
        encoder.encode(record.kemPublicKeys, encoder: { enc, keys in
            let sorted = keys.sorted { $0.suiteWireId < $1.suiteWireId }
            enc.encode(sorted, encoder: { inner, key in
                inner.encode(key.suiteWireId)
                inner.encode(key.publicKey)
            })
        })
        encoder.encode(UInt8(record.attestationLevel.rawValue))
        encoder.encode(record.capabilities)
        encoder.encode(record.createdAt)
        encoder.encode(record.updatedAt)
        encoder.encode(Int64(record.version))
        encoder.encode(revoked ? "revoke" : "add")
        return encoder.finalize()
    }
    
 // MARK: - Keychain Operations
    
 /// 保存到 Keychain
    private func saveToKeychain(_ record: TrustRecord, synchronizable: Bool) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(record)
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainConstants.service,
            kSecAttrAccount as String: KeychainConstants.recordPrefix + record.deviceId,
            kSecValueData as String: data,
            kSecAttrSynchronizable as String: synchronizable ? kCFBooleanTrue! : kCFBooleanFalse!
        ]
        
 // 先删除旧的
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainConstants.service,
            kSecAttrAccount as String: KeychainConstants.recordPrefix + record.deviceId,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        
 // 添加新的
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw TrustSyncError.keychainError(status)
        }
    }
    
 /// 从 Keychain 加载所有记录
    private func loadAllFromKeychain() throws -> [TrustRecord] {
        func copyItems(_ query: [String: Any]) throws -> [[String: Any]] {
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound {
                return []
            }
            guard status == errSecSuccess else {
                throw TrustSyncError.keychainError(status)
            }
            return (result as? [[String: Any]]) ?? []
        }
        
        func copyDataItems(_ query: [String: Any]) throws -> [Data] {
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound {
                return []
            }
            guard status == errSecSuccess else {
                throw TrustSyncError.keychainError(status)
            }
            return (result as? [Data]) ?? []
        }

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainConstants.service,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecReturnAttributes as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        
        // data-only 查询：某些环境下同时返回 attributes + synchronizableAny 会 errSecParam(-50)
        let baseQueryDataOnly: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainConstants.service,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]

        // 首选：一次性拉取所有（含 synchronizable true/false）。
        // 在部分系统/环境下，kSecAttrSynchronizableAny 会返回 errSecParam(-50)，因此提供降级方案。
        var items: [[String: Any]] = []
        do {
            var q = baseQuery
            q[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
            items = try copyItems(q)
        } catch let TrustSyncError.keychainError(status) where status == errSecParam {
            // 先尝试 data-only + synchronizableAny（不依赖 attributes）
            do {
                var q = baseQueryDataOnly
                q[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
                let dataItems = try copyDataItems(q)
                return decodeTrustRecords(from: dataItems)
            } catch {
                // 继续降级到分开查询
            }

            // 降级：分别拉取 non-sync 和 sync 项，再合并去重
            var nonSync = baseQuery
            nonSync[kSecAttrSynchronizable as String] = kCFBooleanFalse as Any
            var sync = baseQuery
            sync[kSecAttrSynchronizable as String] = kCFBooleanTrue as Any
            let a: [[String: Any]]
            do {
                a = try copyItems(nonSync)
            } catch let TrustSyncError.keychainError(status) where status == errSecParam {
                a = []
            }
            let b: [[String: Any]]
            do {
                b = try copyItems(sync)
            } catch let TrustSyncError.keychainError(status) where status == errSecParam {
                // 某些环境下 “synchronizable=true” 会返回 errSecParam（例如未启用 iCloud Keychain），视作无同步项即可
                b = []
            }

            // 合并去重（按 account）
            var seen: Set<String> = []
            var merged: [[String: Any]] = []
            for item in (a + b) {
                let account = item[kSecAttrAccount as String] as? String ?? UUID().uuidString
                if seen.insert(account).inserted {
                    merged.append(item)
                }
            }
            items = merged
        }
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        
        let dataItems = items.compactMap { $0[kSecValueData as String] as? Data }
        return decodeTrustRecords(from: dataItems, decoder: decoder)
    }
    
    private func decodeTrustRecords(from dataItems: [Data], decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()) -> [TrustRecord] {
        var records: [TrustRecord] = []
        records.reserveCapacity(dataItems.count)
        for data in dataItems {
            if let record = try? decoder.decode(TrustRecord.self, from: data) {
                records.append(record)
            }
        }
        return records
    }
    
 /// 从 Keychain 删除记录
    private func deleteFromKeychain(deviceId: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainConstants.service,
            kSecAttrAccount as String: KeychainConstants.recordPrefix + deviceId,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        SecItemDelete(query as CFDictionary)
    }
    
 /// 验证记录签名
    public func verifyRecordSignature(_ record: TrustRecord) async throws -> Bool {
        let dataToVerify = try createDataToSign(for: record, revoked: record.isTombstone)
        let signerPublicKey = try await keyManager.getOrCreateIdentityKey().publicKey
        return try await keyManager.verify(
            data: dataToVerify,
            signature: record.signature,
            publicKey: signerPublicKey
        )
    }
}
