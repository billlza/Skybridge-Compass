//
// OfflineMessageQueue.swift
// SkyBridgeCompassiOS
//
// 离线消息队列 - 当设备离线时缓存消息，在线后自动发送
//

import Foundation

// MARK: - Offline Message

public enum OfflineMessageQueueError: Error, LocalizedError, Sendable {
    case capacityExceeded(maxMessages: Int)
    case persistenceFailed

    public var errorDescription: String? {
        switch self {
        case .capacityExceeded(let maxMessages):
            return "Offline message queue exceeds \(maxMessages) messages"
        case .persistenceFailed:
            return "Offline message queue persistence failed"
        }
    }
}

/// 离线消息
public struct OfflineMessage: Codable, Identifiable, Sendable {
    public let id: String
    public let targetDeviceId: String
    public let messageType: OfflineMessageType
    public let payload: Data
    public let createdAt: Date
    public let expiresAt: Date?
    public var retryCount: Int
    public var lastRetryAt: Date?
    public var status: OfflineMessageStatus
    
    public init(
        id: String = UUID().uuidString,
        targetDeviceId: String,
        messageType: OfflineMessageType,
        payload: Data,
        createdAt: Date = Date(),
        expiresAt: Date? = nil,
        retryCount: Int = 0,
        lastRetryAt: Date? = nil,
        status: OfflineMessageStatus = .pending
    ) {
        self.id = id
        self.targetDeviceId = targetDeviceId
        self.messageType = messageType
        self.payload = payload
        self.createdAt = createdAt
        self.expiresAt = expiresAt ?? Date().addingTimeInterval(24 * 60 * 60) // 默认24小时过期
        self.retryCount = retryCount
        self.lastRetryAt = lastRetryAt
        self.status = status
    }
    
    /// 是否已过期
    public var isExpired: Bool {
        guard let expiresAt = expiresAt else { return false }
        return Date() > expiresAt
    }
}

/// 离线消息类型
public enum OfflineMessageType: String, Codable, Sendable {
    case text = "text"
    case fileTransferRequest = "file_transfer_request"
    case connectionRequest = "connection_request"
    case notification = "notification"
    case system = "system"
    case custom = "custom"
}

/// 离线消息状态
public enum OfflineMessageStatus: String, Codable, Sendable {
    case pending = "pending"
    case sending = "sending"
    case sent = "sent"
    case failed = "failed"
    case expired = "expired"
}

// MARK: - Offline Message Queue

/// 离线消息队列
@available(iOS 17.0, *)
@MainActor
public class OfflineMessageQueue: ObservableObject {
    
    public static let shared = OfflineMessageQueue()
    
    // MARK: - Published Properties
    
    /// 待发送的消息
    @Published public private(set) var pendingMessages: [OfflineMessage] = []
    
    /// 发送失败的消息
    @Published public private(set) var failedMessages: [OfflineMessage] = []
    
    /// 队列中的消息总数
    @Published public private(set) var totalCount: Int = 0
    
    // MARK: - Private Properties
    
    private static let storage = CodablePersistenceStore<StoredMessages>(
        location: .protectedApplicationSupport(
            path: "Messaging/offline-message-queue.json",
            legacyUserDefaultsKey: "offline_message_queue"
        )
    )
    private static let maxQueuedMessages = 500
    private let maxRetryCount = 3
    private let retryInterval: TimeInterval = 60 // 60秒后重试
    private var retryTimer: Timer?
    
    // MARK: - Initialization
    
    private init() {
        loadFromStorage()
        startRetryTimer()
    }
    
    // MARK: - Public Methods
    
    /// 添加消息到队列
    public func enqueue(_ message: OfflineMessage) throws {
        var newMessage = message
        newMessage.status = .pending
        var nextPending = pendingMessages
        nextPending.append(newMessage)
        try commit(
            pending: nextPending,
            failed: failedMessages,
            persistenceFailureLog: "Offline message queue enqueue persistence failed"
        )
        
        SkyBridgeLogger.shared.info("📬 消息已加入离线队列: \(message.id)")
    }
    
    /// 创建并添加消息
    public func enqueue(
        targetDeviceId: String,
        messageType: OfflineMessageType,
        payload: Data,
        expiresIn: TimeInterval? = nil
    ) throws {
        let message = OfflineMessage(
            targetDeviceId: targetDeviceId,
            messageType: messageType,
            payload: payload,
            expiresAt: expiresIn.map { Date().addingTimeInterval($0) }
        )
        try enqueue(message)
    }
    
    /// 获取指定设备的待发送消息
    public func getMessages(for deviceId: String) -> [OfflineMessage] {
        pendingMessages.filter { $0.targetDeviceId == deviceId && !$0.isExpired }
    }
    
    /// 标记消息为已发送
    public func markAsSent(_ messageId: String) throws {
        if let index = pendingMessages.firstIndex(where: { $0.id == messageId }) {
            var nextPending = pendingMessages
            nextPending.remove(at: index)
            try commit(
                pending: nextPending,
                failed: failedMessages,
                persistenceFailureLog: "Offline message queue sent-state persistence failed"
            )
            
            SkyBridgeLogger.shared.info("✅ 离线消息已发送: \(messageId)")
        }
    }
    
    /// 标记消息发送失败
    public func markAsFailed(_ messageId: String) throws {
        if let index = pendingMessages.firstIndex(where: { $0.id == messageId }) {
            var nextPending = pendingMessages
            var nextFailed = failedMessages
            var message = pendingMessages[index]
            message.retryCount += 1
            message.lastRetryAt = Date()
            
            if message.retryCount >= maxRetryCount {
                message.status = .failed
                nextPending.remove(at: index)
                nextFailed.append(message)
                
                SkyBridgeLogger.shared.warning("⚠️ 离线消息发送失败（重试次数已达上限）: \(messageId)")
            } else {
                message.status = .pending
                nextPending[index] = message
                
                SkyBridgeLogger.shared.info("🔄 离线消息将稍后重试: \(messageId)")
            }
            
            try commit(
                pending: nextPending,
                failed: nextFailed,
                persistenceFailureLog: "Offline message queue failed-state persistence failed"
            )
        }
    }
    
    /// 重试失败的消息
    public func retryFailedMessages() throws {
        var nextPending = pendingMessages
        for message in failedMessages {
            var retryMessage = message
            retryMessage.retryCount = 0
            retryMessage.status = .pending
            nextPending.append(retryMessage)
        }
        try commit(
            pending: nextPending,
            failed: [],
            persistenceFailureLog: "Offline message queue retry-state persistence failed"
        )
    }
    
    /// 删除消息
    public func remove(_ messageId: String) throws {
        let nextPending = pendingMessages.filter { $0.id != messageId }
        let nextFailed = failedMessages.filter { $0.id != messageId }
        try commit(
            pending: nextPending,
            failed: nextFailed,
            persistenceFailureLog: "Offline message queue removal persistence failed"
        )
    }
    
    /// 清空队列
    public func clear() throws {
        try commit(
            pending: [],
            failed: [],
            persistenceFailureLog: "Offline message queue clear persistence failed"
        )
    }
    
    /// 清理过期消息
    public func cleanupExpiredMessages() throws {
        let expiredPendingIds = pendingMessages.filter { $0.isExpired }.map { $0.id }
        let expiredFailedIds = failedMessages.filter { $0.isExpired }.map { $0.id }

        let nextPending = pendingMessages.filter { !$0.isExpired }
        let nextFailed = failedMessages.filter { !$0.isExpired }

        for id in expiredPendingIds + expiredFailedIds {
            SkyBridgeLogger.shared.info("🗑️ 离线消息已过期并删除: \(id)")
        }

        guard !expiredPendingIds.isEmpty || !expiredFailedIds.isEmpty else { return }
        try commit(
            pending: nextPending,
            failed: nextFailed,
            persistenceFailureLog: "Offline message queue expiry cleanup persistence failed"
        )
    }
    
    /// 处理设备上线
    public func onDeviceOnline(_ deviceId: String, sendHandler: @escaping (OfflineMessage) async -> Bool) {
        let messages = getMessages(for: deviceId)
        
        Task {
            for message in messages {
                // 更新状态为发送中
                if let index = pendingMessages.firstIndex(where: { $0.id == message.id }) {
                    pendingMessages[index].status = .sending
                }
                
                // 尝试发送
                let success = await sendHandler(message)
                
                if success {
                    do {
                        try markAsSent(message.id)
                    } catch {
                        SkyBridgeLogger.shared.error(
                            "Offline message sent-state update failed: \(Self.logSafeErrorSummary(error))"
                        )
                    }
                } else {
                    do {
                        try markAsFailed(message.id)
                    } catch {
                        SkyBridgeLogger.shared.error(
                            "Offline message failed-state update failed: \(Self.logSafeErrorSummary(error))"
                        )
                    }
                }
            }
        }
    }
    
    // MARK: - Private Methods
    
    private func updateTotalCount() {
        totalCount = pendingMessages.count + failedMessages.count
    }
    
    private func startRetryTimer() {
        retryTimer = Timer.scheduledTimer(withTimeInterval: retryInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                do {
                    try self?.cleanupExpiredMessages()
                } catch {
                    SkyBridgeLogger.shared.error(
                        "Offline message cleanup failed: \(Self.logSafeErrorSummary(error))"
                    )
                }
            }
        }
    }
    
    private func stopRetryTimer() {
        retryTimer?.invalidate()
        retryTimer = nil
    }
    
    // MARK: - Persistence

    private static func logSafeErrorSummary(_ error: Error) -> String {
        guard let error = error as? OfflineMessageQueueError else {
            return String(describing: type(of: error))
        }
        switch error {
        case .capacityExceeded:
            return "capacity_exceeded"
        case .persistenceFailed:
            return "persistence_failed"
        }
    }

    private func commit(
        pending nextPending: [OfflineMessage],
        failed nextFailed: [OfflineMessage],
        persistenceFailureLog: String
    ) throws {
        let nextCount = nextPending.count + nextFailed.count
        guard nextCount <= Self.maxQueuedMessages else {
            throw OfflineMessageQueueError.capacityExceeded(maxMessages: Self.maxQueuedMessages)
        }

        let previousPending = pendingMessages
        let previousFailed = failedMessages
        let previousTotalCount = totalCount

        pendingMessages = nextPending
        failedMessages = nextFailed
        updateTotalCount()

        do {
            try saveToStorage()
        } catch {
            pendingMessages = previousPending
            failedMessages = previousFailed
            totalCount = previousTotalCount
            SkyBridgeLogger.shared.error(persistenceFailureLog)
            throw error
        }
    }
    
    private func saveToStorage() throws {
        let data = StoredMessages(pending: pendingMessages, failed: failedMessages)
        do {
            try Self.storage.save(data)
        } catch {
            throw OfflineMessageQueueError.persistenceFailed
        }
    }
    
    private func loadFromStorage() {
        guard let stored = Self.storage.load() else {
            return
        }
        
        pendingMessages = stored.pending
        failedMessages = stored.failed
        updateTotalCount()
        
        // 清理过期消息
        do {
            try cleanupExpiredMessages()
        } catch {
            SkyBridgeLogger.shared.error(
                "Offline message load cleanup failed: \(Self.logSafeErrorSummary(error))"
            )
        }
    }
    
    private struct StoredMessages: Codable {
        let pending: [OfflineMessage]
        let failed: [OfflineMessage]
    }
}
