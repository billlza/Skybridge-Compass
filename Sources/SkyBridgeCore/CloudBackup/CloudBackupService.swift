//
// CloudBackupService.swift
// SkyBridgeCore
//
// 加密云端备份服务
// 支持 macOS 14.0+, 使用 CloudKit + 端到端加密
//
// 设计特点:
// - 使用 AES-256-GCM 端到端加密
// - 密钥派生自用户密码 (PBKDF2)
// - CloudKit 私有数据库存储
// - 支持增量备份和完整快照
//

import Foundation
import CloudKit
import CryptoKit
import OSLog

// MARK: - 云端备份服务

/// 加密云端备份服务
@MainActor
public final class CloudBackupService: ObservableObject {

    // MARK: - Singleton

    public static let shared = CloudBackupService()

    // MARK: - Published Properties

    /// 当前状态
    @Published public private(set) var status: BackupStatus = .idle

    /// 配置
    @Published public var configuration: CloudBackupConfiguration {
        didSet { saveConfiguration() }
    }

    /// 可用备份列表
    @Published public private(set) var availableBackups: [CloudBackupRecord] = []

    /// 上次备份时间
    @Published public private(set) var lastBackupTime: Date?

    /// iCloud 是否可用
    @Published public private(set) var isICloudAvailable: Bool = false

    // MARK: - Private Properties

    private let logger = Logger(subsystem: "com.skybridge.compass", category: "CloudBackup")
    private let container: CKContainer
    private let privateDatabase: CKDatabase

    private let recordType = "BackupSnapshot"
    private var encryptionKey: SymmetricKey?

    // 持久化 keys
    private let configKey = "com.skybridge.backup.config"
    private let lastBackupKey = "com.skybridge.backup.lastTime"

    // 数据提供者回调
    public var dataProviders: [BackupItemType: () async throws -> Data] = [:]
    public var dataRestorers: [BackupItemType: (Data) async throws -> Void] = [:]

    // MARK: - Initialization

    private init() {
        self.container = CKContainer(identifier: "iCloud.com.skybridge.compass")
        self.privateDatabase = container.privateCloudDatabase
        self.configuration = Self.loadConfiguration() ?? .default

        if let lastTime = UserDefaults.standard.object(forKey: lastBackupKey) as? Date {
            self.lastBackupTime = lastTime
        }

        Task {
            await checkICloudStatus()
        }

        logger.info("☁️ 云端备份服务已初始化")
    }

    // MARK: - Public Methods

    /// 设置加密密码（派生加密密钥）
    public func setEncryptionPassword(_ password: String) throws {
        // 使用 PBKDF2 派生密钥
        // 使用固定盐值确保跨设备可恢复，通过高迭代次数保证安全
        let salt = "com.skybridge.compass.backup.v2.salt.2025".data(using: .utf8)!
        let passwordData = password.data(using: .utf8)!

        // 派生 256 位密钥
        let derivedKey = try PBKDF2.deriveKey(
            password: passwordData,
            salt: salt,
            iterations: 100_000,
            keyLength: 32
        )

        self.encryptionKey = SymmetricKey(data: derivedKey)
        logger.info("☁️ 加密密钥已设置")
    }

    /// 创建备份
    public func createBackup() async throws {
        guard encryptionKey != nil else {
            throw CloudBackupError.keyDerivationFailed
        }

        guard isICloudAvailable else {
            throw CloudBackupError.iCloudNotAvailable
        }

        status = .preparing

        do {
            // 收集备份数据
            var backupItems: [BackupItem] = []

            for type in configuration.enabledBackupTypes {
                if let provider = dataProviders[type] {
                    status = .encrypting(progress: Double(backupItems.count) / Double(configuration.enabledBackupTypes.count))

                    let rawData = try await provider()
                    let encryptedData = try encrypt(rawData)

                    let metadata = BackupMetadata(
                        originalSize: rawData.count,
                        encryptedSize: encryptedData.count,
                        itemCount: 1,
                        appVersion: getAppVersion(),
                        deviceName: getDeviceName(),
                        deviceID: getDeviceID()
                    )

                    let item = BackupItem(
                        type: type,
                        encryptedData: encryptedData,
                        metadata: metadata
                    )

                    backupItems.append(item)
                }
            }

            // 创建快照
            let snapshot = BackupSnapshot(
                items: backupItems,
                deviceID: getDeviceID(),
                deviceName: getDeviceName(),
                appVersion: getAppVersion()
            )

            // 上传到 CloudKit
            status = .uploading(progress: 0)
            try await uploadSnapshot(snapshot)

            // 清理旧备份
            await cleanupOldBackups()

            // 更新状态
            lastBackupTime = Date()
            UserDefaults.standard.set(lastBackupTime, forKey: lastBackupKey)

            status = .completed
            logger.info("☁️ 备份创建成功，共 \(backupItems.count) 项")

            // 刷新可用备份列表
            await refreshAvailableBackups()

        } catch {
            status = .failed(error.localizedDescription)
            logger.error("☁️ 备份失败: \(error.localizedDescription)")
            throw error
        }
    }

    /// 恢复备份
    public func restoreBackup(_ record: CloudBackupRecord, options: RestoreOptions = .full) async throws {
        guard encryptionKey != nil else {
            throw CloudBackupError.keyDerivationFailed
        }

        status = .downloading(progress: 0)

        do {
            // 下载快照
            let snapshot = try await downloadSnapshot(record.snapshotID)

            status = .decrypting(progress: 0)

            // 解密并恢复每个项目
            var restored = 0
            for item in snapshot.items {
                guard options.itemTypes.contains(item.type) else { continue }

                status = .decrypting(progress: Double(restored) / Double(snapshot.items.count))

                // 验证校验和
                let hash = SHA256.hash(data: item.encryptedData)
                let checksum = hash.compactMap { String(format: "%02x", $0) }.joined()
                guard checksum == item.checksum else {
                    throw CloudBackupError.checksumMismatch
                }

                // 解密
                let decryptedData = try decrypt(item.encryptedData)

                status = .restoring(progress: Double(restored) / Double(snapshot.items.count))

                // 恢复数据
                if let restorer = dataRestorers[item.type] {
                    try await restorer(decryptedData)
                }

                restored += 1
            }

            status = .completed
            logger.info("☁️ 备份恢复成功，共 \(restored) 项")

        } catch {
            status = .failed(error.localizedDescription)
            logger.error("☁️ 恢复失败: \(error.localizedDescription)")
            throw error
        }
    }

    /// 删除备份
    public func deleteBackup(_ record: CloudBackupRecord) async throws {
        let recordID = CKRecord.ID(recordName: record.snapshotID.uuidString)

        try await privateDatabase.deleteRecord(withID: recordID)

        // 刷新列表
        await refreshAvailableBackups()

        logger.info("☁️ 备份已删除: \(record.snapshotID)")
    }

    /// 刷新可用备份列表
    public func refreshAvailableBackups() async {
        do {
            let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
            query.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]

            let (results, _) = try await privateDatabase.records(matching: query)

            var records: [CloudBackupRecord] = []

            for (_, result) in results {
                if case .success(let record) = result {
                    if let snapshotIDString = record["snapshotID"] as? String,
                       let snapshotID = UUID(uuidString: snapshotIDString),
                       let createdAt = record["createdAt"] as? Date,
                       let deviceName = record["deviceName"] as? String,
                       let totalSize = record["totalSize"] as? Int,
                       let itemCount = record["itemCount"] as? Int,
                       let appVersion = record["appVersion"] as? String {

                        let backupRecord = CloudBackupRecord(
                            snapshotID: snapshotID,
                            createdAt: createdAt,
                            deviceName: deviceName,
                            totalSize: totalSize,
                            itemCount: itemCount,
                            appVersion: appVersion
                        )
                        records.append(backupRecord)
                    }
                }
            }

            availableBackups = records

        } catch {
            logger.error("☁️ 刷新备份列表失败: \(error.localizedDescription)")
        }
    }

    /// 检查 iCloud 状态
    public func checkICloudStatus() async {
        do {
            let status = try await container.accountStatus()
            isICloudAvailable = (status == .available)
        } catch {
            isICloudAvailable = false
            logger.error("☁️ 检查 iCloud 状态失败: \(error.localizedDescription)")
        }
    }

    // MARK: - Private Methods - Encryption

    private func encrypt(_ data: Data) throws -> Data {
        guard let key = encryptionKey else {
            throw CloudBackupError.keyDerivationFailed
        }

        do {
            let sealedBox = try AES.GCM.seal(data, using: key)
            guard let combined = sealedBox.combined else {
                throw CloudBackupError.encryptionFailed("无法组合加密数据")
            }
            return combined
        } catch let error as CloudBackupError {
            throw error
        } catch {
            throw CloudBackupError.encryptionFailed(error.localizedDescription)
        }
    }

    private func decrypt(_ data: Data) throws -> Data {
        guard let key = encryptionKey else {
            throw CloudBackupError.keyDerivationFailed
        }

        do {
            let sealedBox = try AES.GCM.SealedBox(combined: data)
            return try AES.GCM.open(sealedBox, using: key)
        } catch {
            throw CloudBackupError.decryptionFailed(error.localizedDescription)
        }
    }

    // MARK: - Private Methods - CloudKit

    private func uploadSnapshot(_ snapshot: BackupSnapshot) async throws {
        let recordID = CKRecord.ID(recordName: snapshot.id.uuidString)
        let record = CKRecord(recordType: recordType, recordID: recordID)

        // 序列化快照
        let snapshotData = try JSONEncoder().encode(snapshot)

        record["snapshotID"] = snapshot.id.uuidString
        record["createdAt"] = snapshot.createdAt
        record["deviceID"] = snapshot.deviceID
        record["deviceName"] = snapshot.deviceName
        record["appVersion"] = snapshot.appVersion
        record["totalSize"] = snapshot.totalSize
        record["itemCount"] = snapshot.itemCount

        // 存储加密的快照数据为 Asset
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(snapshot.id.uuidString).backup")
        try snapshotData.write(to: tempURL)
        record["snapshotData"] = CKAsset(fileURL: tempURL)

        _ = try await privateDatabase.save(record)

        // 清理临时文件
        try? FileManager.default.removeItem(at: tempURL)

        status = .uploading(progress: 1.0)
    }

    private func downloadSnapshot(_ snapshotID: UUID) async throws -> BackupSnapshot {
        let recordID = CKRecord.ID(recordName: snapshotID.uuidString)
        let record = try await privateDatabase.record(for: recordID)

        guard let asset = record["snapshotData"] as? CKAsset,
              let fileURL = asset.fileURL else {
            throw CloudBackupError.noBackupFound
        }

        let data = try Data(contentsOf: fileURL)
        let snapshot = try JSONDecoder().decode(BackupSnapshot.self, from: data)

        return snapshot
    }

    private func cleanupOldBackups() async {
        guard availableBackups.count > configuration.maxBackupCount else { return }

        // 删除最旧的备份
        let toDelete = availableBackups
            .sorted { $0.createdAt < $1.createdAt }
            .prefix(availableBackups.count - configuration.maxBackupCount)

        for record in toDelete {
            try? await deleteBackup(record)
        }
    }

    // MARK: - Private Methods - Utilities

    private func getAppVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private func getDeviceName() -> String {
        Host.current().localizedName ?? "Mac"
    }

    private func getDeviceID() -> String {
        if let deviceID = UserDefaults.standard.string(forKey: "com.skybridge.deviceID") {
            return deviceID
        }
        let newID = UUID().uuidString
        UserDefaults.standard.set(newID, forKey: "com.skybridge.deviceID")
        return newID
    }

    // MARK: - Persistence

    private func saveConfiguration() {
        if let data = try? JSONEncoder().encode(configuration) {
            UserDefaults.standard.set(data, forKey: configKey)
        }
    }

    private static func loadConfiguration() -> CloudBackupConfiguration? {
        guard let data = UserDefaults.standard.data(forKey: "com.skybridge.backup.config"),
              let config = try? JSONDecoder().decode(CloudBackupConfiguration.self, from: data) else {
            return nil
        }
        return config
    }
}

// MARK: - PBKDF2 密钥派生

private enum PBKDF2 {
    static func deriveKey(password: Data, salt: Data, iterations: Int, keyLength: Int) throws -> Data {
        var derivedKey = Data(count: keyLength)

        let result = derivedKey.withUnsafeMutableBytes { derivedKeyBytes in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        password.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        derivedKeyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        keyLength
                    )
                }
            }
        }

        guard result == kCCSuccess else {
            throw CloudBackupError.keyDerivationFailed
        }

        return derivedKey
    }
}

// CommonCrypto import
import CommonCrypto
