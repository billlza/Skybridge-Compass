//
// OfflineMessageTypes.swift
// SkyBridgeCore
//
// 离线消息队列 - 类型定义
// 支持 macOS 14.0+, 兼容 macOS 15.x 和 26.x
//

import Foundation

// MARK: - 消息优先级

/// 消息优先级
public enum MessagePriority: Int, Codable, Sendable, Comparable, CaseIterable {
    case low = 0
    case normal = 1
    case high = 2
    case urgent = 3

    public static func < (lhs: MessagePriority, rhs: MessagePriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var displayName: String {
        switch self {
        case .low: return "低优先级"
        case .normal: return "普通"
        case .high: return "高优先级"
        case .urgent: return "紧急"
        }
    }
}

// MARK: - 消息类型

/// 离线消息类型枚举
public enum OfflineMessageType: String, Codable, Sendable, CaseIterable {
    case text = "text"
    case file = "file"
    case command = "command"
    case notification = "notification"
    case clipboardSync = "clipboard_sync"
    case systemEvent = "system_event"

    public var displayName: String {
        switch self {
        case .text: return "文本消息"
        case .file: return "文件传输"
        case .command: return "远程命令"
        case .notification: return "通知"
        case .clipboardSync: return "剪贴板同步"
        case .systemEvent: return "系统事件"
        }
    }
}

// MARK: - 消息状态

/// 消息投递状态
public enum MessageDeliveryStatus: String, Codable, Sendable {
    case pending = "pending"           // 等待发送
    case sending = "sending"           // 发送中
    case delivered = "delivered"       // 已送达
    case failed = "failed"             // 发送失败
    case expired = "expired"           // 已过期

    public var displayName: String {
        switch self {
        case .pending: return "等待发送"
        case .sending: return "发送中"
        case .delivered: return "已送达"
        case .failed: return "发送失败"
        case .expired: return "已过期"
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .delivered, .failed, .expired: return true
        default: return false
        }
    }
}

// MARK: - 排队消息

/// 排队消息
public struct QueuedMessage: Identifiable, Codable, Sendable {
    public let id: UUID
    public let targetDeviceID: String
    public let messageType: OfflineMessageType
    public let priority: MessagePriority
    public let payload: Data
    public let createdAt: Date
    public let expiresAt: Date
    public private(set) var status: MessageDeliveryStatus
    public private(set) var retryCount: Int
    public private(set) var lastAttemptAt: Date?
    public private(set) var lastError: String?

    /// 是否已过期
    public var isExpired: Bool {
        Date() > expiresAt
    }

    /// 等待时间
    public var waitingDuration: TimeInterval {
        Date().timeIntervalSince(createdAt)
    }

    /// 剩余有效时间
    public var remainingTTL: TimeInterval {
        max(0, expiresAt.timeIntervalSince(Date()))
    }

    public init(
        targetDeviceID: String,
        messageType: OfflineMessageType,
        priority: MessagePriority = .normal,
        payload: Data,
        ttl: TimeInterval = 86400 // 默认24小时
    ) {
        self.id = UUID()
        self.targetDeviceID = targetDeviceID
        self.messageType = messageType
        self.priority = priority
        self.payload = payload
        self.createdAt = Date()
        self.expiresAt = Date().addingTimeInterval(ttl)
        self.status = .pending
        self.retryCount = 0
        self.lastAttemptAt = nil
        self.lastError = nil
    }

    /// 更新状态
    public mutating func updateStatus(_ newStatus: MessageDeliveryStatus) {
        self.status = newStatus
    }

    /// 记录发送尝试
    public mutating func recordAttempt(error: String? = nil) {
        self.retryCount += 1
        self.lastAttemptAt = Date()
        self.lastError = error
    }

    /// 标记为过期
    public mutating func markExpired() {
        self.status = .expired
    }
}

// MARK: - 消息队列配置

/// 离线消息队列配置
public struct OfflineQueueConfiguration: Codable, Sendable {
    /// 最大队列大小
    public var maxQueueSize: Int

    /// 每个设备的最大消息数
    public var maxMessagesPerDevice: Int

    /// 最大重试次数
    public var maxRetryCount: Int

    /// 重试间隔（秒）
    public var retryInterval: TimeInterval

    /// 重试退避因子（指数退避）
    public var retryBackoffFactor: Double

    /// 默认消息 TTL（秒）
    public var defaultTTL: TimeInterval

    /// 紧急消息 TTL（秒）
    public var urgentTTL: TimeInterval

    /// 是否启用持久化
    public var enablePersistence: Bool

    /// 是否按优先级排序
    public var priorityOrdering: Bool

    /// 默认配置
    public static let `default` = OfflineQueueConfiguration(
        maxQueueSize: 1000,
        maxMessagesPerDevice: 100,
        maxRetryCount: 5,
        retryInterval: 30,
        retryBackoffFactor: 2.0,
        defaultTTL: 86400,        // 24小时
        urgentTTL: 86400 * 7,     // 7天
        enablePersistence: true,
        priorityOrdering: true
    )

    public init(
        maxQueueSize: Int = 1000,
        maxMessagesPerDevice: Int = 100,
        maxRetryCount: Int = 5,
        retryInterval: TimeInterval = 30,
        retryBackoffFactor: Double = 2.0,
        defaultTTL: TimeInterval = 86400,
        urgentTTL: TimeInterval = 86400 * 7,
        enablePersistence: Bool = true,
        priorityOrdering: Bool = true
    ) {
        self.maxQueueSize = maxQueueSize
        self.maxMessagesPerDevice = maxMessagesPerDevice
        self.maxRetryCount = maxRetryCount
        self.retryInterval = retryInterval
        self.retryBackoffFactor = retryBackoffFactor
        self.defaultTTL = defaultTTL
        self.urgentTTL = urgentTTL
        self.enablePersistence = enablePersistence
        self.priorityOrdering = priorityOrdering
    }
}

// MARK: - 队列统计

/// 队列统计信息
public struct QueueStatistics: Sendable {
    public let totalMessages: Int
    public let pendingMessages: Int
    public let sendingMessages: Int
    public let deliveredMessages: Int
    public let failedMessages: Int
    public let expiredMessages: Int
    public let deviceBreakdown: [String: Int]
    public let averageWaitTime: TimeInterval
    public let oldestMessageAge: TimeInterval?
    public let timestamp: Date

    public init(
        totalMessages: Int,
        pendingMessages: Int,
        sendingMessages: Int,
        deliveredMessages: Int,
        failedMessages: Int,
        expiredMessages: Int,
        deviceBreakdown: [String: Int],
        averageWaitTime: TimeInterval,
        oldestMessageAge: TimeInterval?
    ) {
        self.totalMessages = totalMessages
        self.pendingMessages = pendingMessages
        self.sendingMessages = sendingMessages
        self.deliveredMessages = deliveredMessages
        self.failedMessages = failedMessages
        self.expiredMessages = expiredMessages
        self.deviceBreakdown = deviceBreakdown
        self.averageWaitTime = averageWaitTime
        self.oldestMessageAge = oldestMessageAge
        self.timestamp = Date()
    }

    public static let empty = QueueStatistics(
        totalMessages: 0,
        pendingMessages: 0,
        sendingMessages: 0,
        deliveredMessages: 0,
        failedMessages: 0,
        expiredMessages: 0,
        deviceBreakdown: [:],
        averageWaitTime: 0,
        oldestMessageAge: nil
    )
}

// MARK: - 队列错误

/// 离线消息队列错误
public enum OfflineQueueError: Error, Sendable, LocalizedError {
    case queueFull
    case deviceQueueFull(deviceID: String)
    case messageExpired
    case messageTooLarge(size: Int, maxSize: Int)
    case deviceOffline(deviceID: String)
    case sendFailed(reason: String)
    case persistenceError(String)
    case messageNotFound(id: UUID)

    public var errorDescription: String? {
        switch self {
        case .queueFull:
            return "消息队列已满"
        case .deviceQueueFull(let deviceID):
            return "设备 \(deviceID) 的消息队列已满"
        case .messageExpired:
            return "消息已过期"
        case .messageTooLarge(let size, let maxSize):
            return "消息过大: \(size) 字节 (最大 \(maxSize) 字节)"
        case .deviceOffline(let deviceID):
            return "设备 \(deviceID) 离线"
        case .sendFailed(let reason):
            return "发送失败: \(reason)"
        case .persistenceError(let reason):
            return "持久化错误: \(reason)"
        case .messageNotFound(let id):
            return "消息未找到: \(id)"
        }
    }
}

// MARK: - 设备连接状态

/// 设备连接状态通知
public struct DeviceConnectionEvent: Sendable {
    public let deviceID: String
    public let isOnline: Bool
    public let timestamp: Date

    public init(deviceID: String, isOnline: Bool) {
        self.deviceID = deviceID
        self.isOnline = isOnline
        self.timestamp = Date()
    }
}

// MARK: - 消息投递结果

/// 消息投递结果
public struct MessageDeliveryResult: Sendable {
    public let messageID: UUID
    public let deviceID: String
    public let success: Bool
    public let error: String?
    public let deliveredAt: Date?
    public let retryCount: Int

    public init(
        messageID: UUID,
        deviceID: String,
        success: Bool,
        error: String? = nil,
        retryCount: Int = 0
    ) {
        self.messageID = messageID
        self.deviceID = deviceID
        self.success = success
        self.error = error
        self.deliveredAt = success ? Date() : nil
        self.retryCount = retryCount
    }
}
