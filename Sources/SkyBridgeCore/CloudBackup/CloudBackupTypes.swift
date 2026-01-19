//
// CloudBackupTypes.swift
// SkyBridgeCore
//
// 加密云端备份 - 类型定义
// 支持 macOS 14.0+, 使用 CloudKit + 端到端加密
//

import Foundation
import CryptoKit

// MARK: - 备份项目类型

/// 可备份的数据类型
public enum BackupItemType: String, Codable, Sendable, CaseIterable {
    case devicePairings = "device_pairings"
    case connectionHistory = "connection_history"
    case preferences = "preferences"
    case certificates = "certificates"
    case clipboardHistory = "clipboard_history"
    case transferHistory = "transfer_history"

    public var displayName: String {
        switch self {
        case .devicePairings: return "设备配对信息"
        case .connectionHistory: return "连接历史"
        case .preferences: return "应用偏好设置"
        case .certificates: return "安全证书"
        case .clipboardHistory: return "剪贴板历史"
        case .transferHistory: return "传输历史"
        }
    }

    public var icon: String {
        switch self {
        case .devicePairings: return "link"
        case .connectionHistory: return "clock.arrow.circlepath"
        case .preferences: return "gearshape"
        case .certificates: return "lock.shield"
        case .clipboardHistory: return "doc.on.clipboard"
        case .transferHistory: return "arrow.left.arrow.right"
        }
    }
}

// MARK: - 备份项目

/// 备份项目
public struct BackupItem: Identifiable, Codable, Sendable {
    public let id: UUID
    public let type: BackupItemType
    public let encryptedData: Data
    public let metadata: BackupMetadata
    public let createdAt: Date
    public let checksum: String

    public init(
        type: BackupItemType,
        encryptedData: Data,
        metadata: BackupMetadata
    ) {
        self.id = UUID()
        self.type = type
        self.encryptedData = encryptedData
        self.metadata = metadata
        self.createdAt = Date()

        // 计算校验和
        let hash = SHA256.hash(data: encryptedData)
        self.checksum = hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}

/// 备份元数据
public struct BackupMetadata: Codable, Sendable {
    public let originalSize: Int
    public let encryptedSize: Int
    public let itemCount: Int
    public let appVersion: String
    public let deviceName: String
    public let deviceID: String

    public init(
        originalSize: Int,
        encryptedSize: Int,
        itemCount: Int,
        appVersion: String,
        deviceName: String,
        deviceID: String
    ) {
        self.originalSize = originalSize
        self.encryptedSize = encryptedSize
        self.itemCount = itemCount
        self.appVersion = appVersion
        self.deviceName = deviceName
        self.deviceID = deviceID
    }
}

// MARK: - 备份快照

/// 完整备份快照
public struct BackupSnapshot: Identifiable, Codable, Sendable {
    public let id: UUID
    public let items: [BackupItem]
    public let createdAt: Date
    public let deviceID: String
    public let deviceName: String
    public let appVersion: String
    public let encryptionVersion: Int

    /// 总大小
    public var totalSize: Int {
        items.reduce(0) { $0 + $1.encryptedData.count }
    }

    /// 项目数量
    public var itemCount: Int {
        items.count
    }

    public init(
        items: [BackupItem],
        deviceID: String,
        deviceName: String,
        appVersion: String,
        encryptionVersion: Int = 1
    ) {
        self.id = UUID()
        self.items = items
        self.createdAt = Date()
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.appVersion = appVersion
        self.encryptionVersion = encryptionVersion
    }
}

// MARK: - 备份状态

/// 备份操作状态
public enum BackupStatus: Sendable, Equatable {
    case idle
    case preparing
    case encrypting(progress: Double)
    case uploading(progress: Double)
    case downloading(progress: Double)
    case decrypting(progress: Double)
    case restoring(progress: Double)
    case completed
    case failed(String)

    public var displayName: String {
        switch self {
        case .idle: return "空闲"
        case .preparing: return "准备中"
        case .encrypting(let p): return "加密中 \(Int(p * 100))%"
        case .uploading(let p): return "上传中 \(Int(p * 100))%"
        case .downloading(let p): return "下载中 \(Int(p * 100))%"
        case .decrypting(let p): return "解密中 \(Int(p * 100))%"
        case .restoring(let p): return "恢复中 \(Int(p * 100))%"
        case .completed: return "已完成"
        case .failed(let msg): return "失败: \(msg)"
        }
    }

    public var isActive: Bool {
        switch self {
        case .idle, .completed, .failed: return false
        default: return true
        }
    }

    public var progress: Double? {
        switch self {
        case .encrypting(let p), .uploading(let p),
             .downloading(let p), .decrypting(let p), .restoring(let p):
            return p
        default:
            return nil
        }
    }
}

// MARK: - 备份配置

/// 云端备份配置
public struct CloudBackupConfiguration: Codable, Sendable {
    /// 是否启用自动备份
    public var autoBackupEnabled: Bool

    /// 自动备份间隔（秒）
    public var autoBackupInterval: TimeInterval

    /// 要备份的项目类型
    public var enabledBackupTypes: Set<BackupItemType>

    /// 保留的备份数量
    public var maxBackupCount: Int

    /// 是否仅在 WiFi 下备份
    public var wifiOnlyBackup: Bool

    /// 是否备份到 iCloud
    public var useICloud: Bool

    /// 默认配置
    public static let `default` = CloudBackupConfiguration(
        autoBackupEnabled: false,
        autoBackupInterval: 86400, // 每天
        enabledBackupTypes: Set(BackupItemType.allCases),
        maxBackupCount: 10,
        wifiOnlyBackup: true,
        useICloud: true
    )

    public init(
        autoBackupEnabled: Bool = false,
        autoBackupInterval: TimeInterval = 86400,
        enabledBackupTypes: Set<BackupItemType> = Set(BackupItemType.allCases),
        maxBackupCount: Int = 10,
        wifiOnlyBackup: Bool = true,
        useICloud: Bool = true
    ) {
        self.autoBackupEnabled = autoBackupEnabled
        self.autoBackupInterval = autoBackupInterval
        self.enabledBackupTypes = enabledBackupTypes
        self.maxBackupCount = maxBackupCount
        self.wifiOnlyBackup = wifiOnlyBackup
        self.useICloud = useICloud
    }
}

// MARK: - 备份错误

/// 云端备份错误
public enum CloudBackupError: Error, Sendable, LocalizedError {
    case notSignedIn
    case encryptionFailed(String)
    case decryptionFailed(String)
    case uploadFailed(String)
    case downloadFailed(String)
    case noBackupFound
    case invalidBackup(String)
    case keyDerivationFailed
    case checksumMismatch
    case quotaExceeded
    case networkUnavailable
    case iCloudNotAvailable

    public var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "未登录 iCloud 账户"
        case .encryptionFailed(let reason):
            return "加密失败: \(reason)"
        case .decryptionFailed(let reason):
            return "解密失败: \(reason)"
        case .uploadFailed(let reason):
            return "上传失败: \(reason)"
        case .downloadFailed(let reason):
            return "下载失败: \(reason)"
        case .noBackupFound:
            return "未找到备份"
        case .invalidBackup(let reason):
            return "备份无效: \(reason)"
        case .keyDerivationFailed:
            return "密钥派生失败"
        case .checksumMismatch:
            return "校验和不匹配"
        case .quotaExceeded:
            return "存储空间不足"
        case .networkUnavailable:
            return "网络不可用"
        case .iCloudNotAvailable:
            return "iCloud 不可用"
        }
    }
}

// MARK: - 云端备份记录

/// 云端备份记录（用于列表显示）
public struct CloudBackupRecord: Identifiable, Sendable {
    public let id: UUID
    public let snapshotID: UUID
    public let createdAt: Date
    public let deviceName: String
    public let totalSize: Int
    public let itemCount: Int
    public let appVersion: String

    public init(
        snapshotID: UUID,
        createdAt: Date,
        deviceName: String,
        totalSize: Int,
        itemCount: Int,
        appVersion: String
    ) {
        self.id = UUID()
        self.snapshotID = snapshotID
        self.createdAt = createdAt
        self.deviceName = deviceName
        self.totalSize = totalSize
        self.itemCount = itemCount
        self.appVersion = appVersion
    }
}

// MARK: - 恢复选项

/// 恢复选项
public struct RestoreOptions: Sendable {
    public let itemTypes: Set<BackupItemType>
    public let overwriteExisting: Bool
    public let mergePreferences: Bool

    public static let full = RestoreOptions(
        itemTypes: Set(BackupItemType.allCases),
        overwriteExisting: true,
        mergePreferences: false
    )

    public static let partial = RestoreOptions(
        itemTypes: [.devicePairings, .preferences],
        overwriteExisting: false,
        mergePreferences: true
    )

    public init(
        itemTypes: Set<BackupItemType>,
        overwriteExisting: Bool = false,
        mergePreferences: Bool = true
    ) {
        self.itemTypes = itemTypes
        self.overwriteExisting = overwriteExisting
        self.mergePreferences = mergePreferences
    }
}
