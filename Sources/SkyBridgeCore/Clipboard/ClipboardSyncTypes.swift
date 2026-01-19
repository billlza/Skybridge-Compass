//
// ClipboardSyncTypes.swift
// SkyBridgeCore
//
// 跨设备剪贴板同步 - 类型定义
// 支持 macOS 14.0+, 兼容 macOS 15.x 和 26.x
//

import Foundation
import CryptoKit

// MARK: - 剪贴板同步错误

/// 剪贴板同步错误类型
public enum ClipboardSyncError: Error, Sendable, LocalizedError {
    case encryptionFailed(String)
    case decryptionFailed(String)
    case connectionLost
    case contentTooLarge(size: Int, maxSize: Int)
    case unsupportedType(String)
    case noConnectedDevices
    case encodingFailed
    case decodingFailed
    case timeout

    public var errorDescription: String? {
        switch self {
        case .encryptionFailed(let reason):
            return "加密失败: \(reason)"
        case .decryptionFailed(let reason):
            return "解密失败: \(reason)"
        case .connectionLost:
            return "连接已断开"
        case .contentTooLarge(let size, let maxSize):
            return "内容过大: \(size) 字节 (最大 \(maxSize) 字节)"
        case .unsupportedType(let type):
            return "不支持的内容类型: \(type)"
        case .noConnectedDevices:
            return "没有已连接的设备"
        case .encodingFailed:
            return "编码失败"
        case .decodingFailed:
            return "解码失败"
        case .timeout:
            return "同步超时"
        }
    }
}

// MARK: - 剪贴板内容类型

/// 剪贴板内容类型
public enum ClipboardContentType: String, Codable, Sendable, CaseIterable {
    case text = "text"
    case image = "image"
    case fileURL = "file_url"
    case richText = "rich_text"
    case html = "html"

    /// MIME 类型
    public var mimeType: String {
        switch self {
        case .text: return "text/plain"
        case .image: return "image/png"
        case .fileURL: return "text/uri-list"
        case .richText: return "text/rtf"
        case .html: return "text/html"
        }
    }

    /// 从 MIME 类型创建
    public static func from(mimeType: String) -> ClipboardContentType {
        switch mimeType.lowercased() {
        case "text/plain", "text/plain;charset=utf-8":
            return .text
        case "image/png", "image/jpeg", "image/tiff", "image/gif":
            return .image
        case "text/uri-list":
            return .fileURL
        case "text/rtf", "application/rtf":
            return .richText
        case "text/html":
            return .html
        default:
            return .text
        }
    }
}

// MARK: - 剪贴板内容模型

/// 剪贴板内容
public struct ClipboardContent: Codable, Sendable, Equatable {
    /// 唯一标识符
    public let id: UUID

    /// 内容类型
    public let type: ClipboardContentType

    /// 内容数据
    public let data: Data

    /// 内容哈希（用于去重）
    public let contentHash: String

    /// 来源设备 ID
    public let sourceDeviceID: String

    /// 创建时间戳
    public let timestamp: Date

    /// 文本预览（用于 UI 显示）
    public var textPreview: String? {
        guard type == .text || type == .richText || type == .html else { return nil }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return String(text.prefix(100))
    }

    /// 内容大小（字节）
    public var size: Int { data.count }

    public init(
        type: ClipboardContentType,
        data: Data,
        sourceDeviceID: String
    ) {
        self.id = UUID()
        self.type = type
        self.data = data
        self.sourceDeviceID = sourceDeviceID
        self.timestamp = Date()

        // 计算内容哈希
        let hash = SHA256.hash(data: data)
        self.contentHash = hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    public static func == (lhs: ClipboardContent, rhs: ClipboardContent) -> Bool {
        lhs.contentHash == rhs.contentHash
    }
}

// MARK: - 同步消息

/// 剪贴板同步消息（P2P 传输格式）
public struct ClipboardSyncMessage: Codable, Sendable {
    /// 消息版本
    public let version: Int

    /// 消息类型
    public let messageType: MessageType

    /// 内容（加密后）
    public let encryptedContent: Data?

    /// 内容元数据
    public let metadata: Metadata?

    /// 发送时间戳
    public let timestamp: Date

    /// 消息类型
    public enum MessageType: String, Codable, Sendable {
        case content = "content"           // 剪贴板内容
        case ack = "ack"                   // 确认接收
        case request = "request"           // 请求最新内容
        case ping = "ping"                 // 心跳
    }

    /// 内容元数据
    public struct Metadata: Codable, Sendable {
        public let contentType: ClipboardContentType
        public let contentHash: String
        public let contentSize: Int
        public let sourceDeviceID: String

        public init(content: ClipboardContent) {
            self.contentType = content.type
            self.contentHash = content.contentHash
            self.contentSize = content.size
            self.sourceDeviceID = content.sourceDeviceID
        }
    }

    public init(
        messageType: MessageType,
        encryptedContent: Data? = nil,
        metadata: Metadata? = nil
    ) {
        self.version = 1
        self.messageType = messageType
        self.encryptedContent = encryptedContent
        self.metadata = metadata
        self.timestamp = Date()
    }
}

// MARK: - 同步状态

/// 剪贴板同步状态
public enum ClipboardSyncState: Sendable, Equatable {
    case disabled
    case idle
    case syncing
    case error(String)

    public var displayName: String {
        switch self {
        case .disabled: return "已禁用"
        case .idle: return "空闲"
        case .syncing: return "同步中"
        case .error(let msg): return "错误: \(msg)"
        }
    }

    public var isActive: Bool {
        switch self {
        case .idle, .syncing: return true
        default: return false
        }
    }
}

// MARK: - 同步配置

/// 剪贴板同步配置
public struct ClipboardSyncConfiguration: Codable, Sendable {
    /// 是否启用同步
    public var isEnabled: Bool

    /// 最大内容大小（字节）
    public var maxContentSize: Int

    /// 同步间隔（秒）
    public var syncInterval: TimeInterval

    /// 是否同步图片
    public var syncImages: Bool

    /// 是否同步文件 URL
    public var syncFileURLs: Bool

    /// 历史记录保留数量
    public var historyLimit: Int

    /// 历史记录保留时间（秒）
    public var historyRetentionDuration: TimeInterval

    /// 默认配置
    public static let `default` = ClipboardSyncConfiguration(
        isEnabled: false,
        maxContentSize: 10 * 1024 * 1024,  // 10MB
        syncInterval: 0.5,
        syncImages: true,
        syncFileURLs: false,
        historyLimit: 50,
        historyRetentionDuration: 86400 * 7  // 7天
    )

    public init(
        isEnabled: Bool = false,
        maxContentSize: Int = 10 * 1024 * 1024,
        syncInterval: TimeInterval = 0.5,
        syncImages: Bool = true,
        syncFileURLs: Bool = false,
        historyLimit: Int = 50,
        historyRetentionDuration: TimeInterval = 86400 * 7
    ) {
        self.isEnabled = isEnabled
        self.maxContentSize = maxContentSize
        self.syncInterval = syncInterval
        self.syncImages = syncImages
        self.syncFileURLs = syncFileURLs
        self.historyLimit = historyLimit
        self.historyRetentionDuration = historyRetentionDuration
    }
}

// MARK: - 同步历史条目

/// 剪贴板同步历史条目
public struct ClipboardHistoryEntry: Identifiable, Codable, Sendable {
    public let id: UUID
    public let content: ClipboardContent
    public let direction: SyncDirection
    public let syncedAt: Date
    public let targetDeviceIDs: [String]

    public enum SyncDirection: String, Codable, Sendable {
        case outgoing = "outgoing"  // 发送到其他设备
        case incoming = "incoming"  // 从其他设备接收
    }

    public init(
        content: ClipboardContent,
        direction: SyncDirection,
        targetDeviceIDs: [String] = []
    ) {
        self.id = UUID()
        self.content = content
        self.direction = direction
        self.syncedAt = Date()
        self.targetDeviceIDs = targetDeviceIDs
    }
}

// MARK: - 设备剪贴板状态

/// 设备剪贴板状态
public struct DeviceClipboardStatus: Sendable {
    public let deviceID: String
    public let deviceName: String
    public let isOnline: Bool
    public let lastSyncTime: Date?
    public let syncEnabled: Bool

    public init(
        deviceID: String,
        deviceName: String,
        isOnline: Bool,
        lastSyncTime: Date?,
        syncEnabled: Bool
    ) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.isOnline = isOnline
        self.lastSyncTime = lastSyncTime
        self.syncEnabled = syncEnabled
    }
}
