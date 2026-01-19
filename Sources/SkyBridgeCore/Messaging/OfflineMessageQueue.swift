//
// OfflineMessageQueue.swift
// SkyBridgeCore
//
// 离线消息队列服务
// 支持 macOS 14.0+, 兼容 macOS 15.x 和 26.x
//
// 设计特点:
// - 使用 Actor 实现线程安全的队列管理
// - 支持优先级排序和指数退避重试
// - 设备上线时自动投递
// - 持久化存储支持断电恢复
//

import Foundation
import OSLog

// MARK: - 离线消息队列服务

/// 离线消息队列 - 使用 Actor 确保线程安全
@MainActor
public final class OfflineMessageQueue: ObservableObject {

    // MARK: - Singleton

    public static let shared = OfflineMessageQueue()

    // MARK: - Published Properties

    /// 配置
    @Published public var configuration: OfflineQueueConfiguration {
        didSet { saveConfiguration() }
    }

    /// 队列统计
    @Published public private(set) var statistics: QueueStatistics = .empty

    /// 是否正在处理
    @Published public private(set) var isProcessing: Bool = false

    // MARK: - Private Properties

    private let logger = Logger(subsystem: "com.skybridge.compass", category: "OfflineQueue")
    private let queueActor = MessageQueueActor()

    // 在线设备集合
    private var onlineDevices: Set<String> = []

    // 处理任务
    private var processingTask: Task<Void, Never>?

    // 发送回调
    public var sendHandler: ((_ message: QueuedMessage) async throws -> Void)?

    // 持久化
    private let persistenceKey = "com.skybridge.offline.queue"
    private let configKey = "com.skybridge.offline.config"

    // MARK: - Initialization

    private init() {
        self.configuration = Self.loadConfiguration() ?? .default

        Task {
            await loadPersistedQueue()
            startProcessing()
        }

        logger.info("📬 离线消息队列已初始化")
    }

    // MARK: - Public Methods

    /// 入队消息
    /// - Parameters:
    ///   - targetDeviceID: 目标设备 ID
    ///   - messageType: 消息类型
    ///   - priority: 优先级
    ///   - payload: 消息载荷
    ///   - ttl: 有效时间（秒）
    /// - Returns: 入队的消息
    @discardableResult
    public func enqueue(
        targetDeviceID: String,
        messageType: OfflineMessageType,
        priority: MessagePriority = .normal,
        payload: Data,
        ttl: TimeInterval? = nil
    ) async throws -> QueuedMessage {

        let effectiveTTL = ttl ?? (priority == .urgent ? configuration.urgentTTL : configuration.defaultTTL)

        let message = QueuedMessage(
            targetDeviceID: targetDeviceID,
            messageType: messageType,
            priority: priority,
            payload: payload,
            ttl: effectiveTTL
        )

        // 检查队列容量
        let stats = await queueActor.getStatistics()
        if stats.totalMessages >= configuration.maxQueueSize {
            throw OfflineQueueError.queueFull
        }

        // 检查设备队列容量
        let deviceCount = stats.deviceBreakdown[targetDeviceID] ?? 0
        if deviceCount >= configuration.maxMessagesPerDevice {
            throw OfflineQueueError.deviceQueueFull(deviceID: targetDeviceID)
        }

        // 入队
        await queueActor.enqueue(message)

        // 更新统计
        await updateStatistics()

        // 持久化
        await persistQueue()

        logger.info("📬 消息已入队: \(message.id), 目标: \(targetDeviceID), 类型: \(messageType.rawValue)")

        // 如果设备在线，立即尝试发送
        if onlineDevices.contains(targetDeviceID) {
            Task {
                await processMessagesForDevice(targetDeviceID)
            }
        }

        return message
    }

    /// 批量入队
    public func enqueueBatch(_ messages: [(targetDeviceID: String, messageType: OfflineMessageType, priority: MessagePriority, payload: Data)]) async throws -> [QueuedMessage] {
        var results: [QueuedMessage] = []

        for msg in messages {
            let queued = try await enqueue(
                targetDeviceID: msg.targetDeviceID,
                messageType: msg.messageType,
                priority: msg.priority,
                payload: msg.payload
            )
            results.append(queued)
        }

        return results
    }

    /// 取消消息
    public func cancel(messageID: UUID) async throws {
        guard await queueActor.remove(messageID: messageID) else {
            throw OfflineQueueError.messageNotFound(id: messageID)
        }

        await updateStatistics()
        await persistQueue()

        logger.info("📬 消息已取消: \(messageID)")
    }

    /// 取消设备的所有消息
    public func cancelAllMessages(for deviceID: String) async {
        await queueActor.removeAllForDevice(deviceID)
        await updateStatistics()
        await persistQueue()

        logger.info("📬 已取消设备 \(deviceID) 的所有消息")
    }

    /// 清空队列
    public func clearAll() async {
        await queueActor.clearAll()
        await updateStatistics()
        await persistQueue()

        logger.info("📬 队列已清空")
    }

    /// 获取设备的待发消息
    public func getPendingMessages(for deviceID: String) async -> [QueuedMessage] {
        await queueActor.getMessagesForDevice(deviceID)
    }

    /// 获取所有待发消息
    public func getAllPendingMessages() async -> [QueuedMessage] {
        await queueActor.getAllMessages()
    }

    /// 设备上线通知
    public func deviceOnline(_ deviceID: String) async {
        onlineDevices.insert(deviceID)
        logger.info("📬 设备上线: \(deviceID)")

        // 处理该设备的待发消息
        await processMessagesForDevice(deviceID)
    }

    /// 设备离线通知
    public func deviceOffline(_ deviceID: String) {
        onlineDevices.remove(deviceID)
        logger.info("📬 设备离线: \(deviceID)")
    }

    /// 手动重试失败的消息
    public func retryFailed() async {
        await queueActor.resetFailedMessages()
        await updateStatistics()

        logger.info("📬 已重置失败消息")

        // 触发处理
        await processAllDevices()
    }

    // MARK: - Private Methods - Processing

    /// 开始后台处理
    private func startProcessing() {
        processingTask?.cancel()

        processingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.periodicProcessing()

                // 等待重试间隔
                try? await Task.sleep(for: .seconds(self?.configuration.retryInterval ?? 30))
            }
        }
    }

    /// 周期性处理
    private func periodicProcessing() async {
        // 清理过期消息
        let expiredCount = await queueActor.cleanupExpired()
        if expiredCount > 0 {
            logger.info("📬 清理了 \(expiredCount) 条过期消息")
        }

        // 处理在线设备的消息
        await processAllDevices()

        // 更新统计
        await updateStatistics()

        // 持久化
        await persistQueue()
    }

    /// 处理所有在线设备的消息
    private func processAllDevices() async {
        for deviceID in onlineDevices {
            await processMessagesForDevice(deviceID)
        }
    }

    /// 处理特定设备的消息
    private func processMessagesForDevice(_ deviceID: String) async {
        guard let sendHandler else { return }

        isProcessing = true
        defer { isProcessing = false }

        // 获取该设备的待发消息（按优先级排序）
        let messages = await queueActor.getReadyMessages(for: deviceID, config: configuration)

        for message in messages {
            // 检查是否过期
            if message.isExpired {
                await queueActor.updateStatus(messageID: message.id, status: .expired)
                continue
            }

            // 标记为发送中
            await queueActor.updateStatus(messageID: message.id, status: .sending)

            do {
                try await sendHandler(message)

                // 发送成功
                await queueActor.updateStatus(messageID: message.id, status: .delivered)
                logger.debug("📬 消息已送达: \(message.id)")

            } catch {
                // 发送失败，记录尝试
                let newRetryCount = message.retryCount + 1

                if newRetryCount >= configuration.maxRetryCount {
                    // 超过最大重试次数
                    await queueActor.updateStatus(messageID: message.id, status: .failed, error: error.localizedDescription)
                    logger.warning("📬 消息发送失败（超过重试次数）: \(message.id)")
                } else {
                    // 记录重试并回到待发状态
                    await queueActor.recordRetryAttempt(messageID: message.id, error: error.localizedDescription)
                    logger.debug("📬 消息将重试: \(message.id), 第 \(newRetryCount) 次")
                }
            }
        }
    }

    /// 更新统计信息
    private func updateStatistics() async {
        statistics = await queueActor.getStatistics()
    }

    // MARK: - Private Methods - Persistence

    /// 持久化队列
    private func persistQueue() async {
        guard configuration.enablePersistence else { return }

        let messages = await queueActor.getAllMessages()

        do {
            let data = try JSONEncoder().encode(messages)
            UserDefaults.standard.set(data, forKey: persistenceKey)
        } catch {
            logger.error("📬 持久化队列失败: \(error.localizedDescription)")
        }
    }

    /// 加载持久化的队列
    private func loadPersistedQueue() async {
        guard configuration.enablePersistence,
              let data = UserDefaults.standard.data(forKey: persistenceKey),
              let messages = try? JSONDecoder().decode([QueuedMessage].self, from: data) else {
            return
        }

        // 过滤掉已过期的消息
        let validMessages = messages.filter { !$0.isExpired && !$0.status.isTerminal }

        for message in validMessages {
            await queueActor.enqueue(message)
        }

        await updateStatistics()

        logger.info("📬 已恢复 \(validMessages.count) 条消息")
    }

    private func saveConfiguration() {
        if let data = try? JSONEncoder().encode(configuration) {
            UserDefaults.standard.set(data, forKey: configKey)
        }
    }

    private static func loadConfiguration() -> OfflineQueueConfiguration? {
        guard let data = UserDefaults.standard.data(forKey: "com.skybridge.offline.config"),
              let config = try? JSONDecoder().decode(OfflineQueueConfiguration.self, from: data) else {
            return nil
        }
        return config
    }
}

// MARK: - 消息队列 Actor

/// 消息队列 Actor - 线程安全的队列操作
actor MessageQueueActor {

    private var messages: [UUID: QueuedMessage] = [:]
    private var deliveryHistory: [UUID: MessageDeliveryResult] = [:]

    // MARK: - Queue Operations

    func enqueue(_ message: QueuedMessage) {
        messages[message.id] = message
    }

    func remove(messageID: UUID) -> Bool {
        messages.removeValue(forKey: messageID) != nil
    }

    func removeAllForDevice(_ deviceID: String) {
        messages = messages.filter { $0.value.targetDeviceID != deviceID }
    }

    func clearAll() {
        messages.removeAll()
    }

    // MARK: - Query Operations

    func getMessagesForDevice(_ deviceID: String) -> [QueuedMessage] {
        messages.values
            .filter { $0.targetDeviceID == deviceID && !$0.status.isTerminal }
            .sorted { $0.priority > $1.priority }
    }

    func getAllMessages() -> [QueuedMessage] {
        Array(messages.values)
    }

    /// 获取准备好发送的消息
    func getReadyMessages(for deviceID: String, config: OfflineQueueConfiguration) -> [QueuedMessage] {
        let now = Date()

        return messages.values
            .filter { message in
                guard message.targetDeviceID == deviceID else { return false }
                guard message.status == .pending else { return false }
                guard !message.isExpired else { return false }

                // 检查重试间隔（指数退避）
                if let lastAttempt = message.lastAttemptAt {
                    let backoff = config.retryInterval * pow(config.retryBackoffFactor, Double(message.retryCount - 1))
                    let nextRetryTime = lastAttempt.addingTimeInterval(backoff)
                    guard now >= nextRetryTime else { return false }
                }

                return true
            }
            .sorted { $0.priority > $1.priority }
    }

    // MARK: - Status Updates

    func updateStatus(messageID: UUID, status: MessageDeliveryStatus, error: String? = nil) {
        guard var message = messages[messageID] else { return }
        message.updateStatus(status)

        if let error {
            message.recordAttempt(error: error)
        }

        messages[messageID] = message

        // 如果是终态，记录投递结果
        if status.isTerminal {
            let result = MessageDeliveryResult(
                messageID: messageID,
                deviceID: message.targetDeviceID,
                success: status == .delivered,
                error: error,
                retryCount: message.retryCount
            )
            deliveryHistory[messageID] = result
        }
    }

    func updateForRetry(_ message: QueuedMessage) {
        var updated = message
        updated.updateStatus(.pending)
        messages[message.id] = updated
    }

    /// 记录重试尝试
    func recordRetryAttempt(messageID: UUID, error: String?) {
        guard var message = messages[messageID] else { return }
        message.recordAttempt(error: error)
        message.updateStatus(.pending)
        messages[messageID] = message
    }

    func resetFailedMessages() {
        for (id, var message) in messages where message.status == .failed {
            message.updateStatus(.pending)
            messages[id] = message
        }
    }

    // MARK: - Cleanup

    func cleanupExpired() -> Int {
        var expiredCount = 0

        for (id, message) in messages where message.isExpired && !message.status.isTerminal {
            var updated = message
            updated.markExpired()
            messages[id] = updated
            expiredCount += 1
        }

        return expiredCount
    }

    // MARK: - Statistics

    func getStatistics() -> QueueStatistics {
        let allMessages = Array(messages.values)

        let pending = allMessages.filter { $0.status == .pending }.count
        let sending = allMessages.filter { $0.status == .sending }.count
        let delivered = allMessages.filter { $0.status == .delivered }.count
        let failed = allMessages.filter { $0.status == .failed }.count
        let expired = allMessages.filter { $0.status == .expired }.count

        // 设备分布
        var deviceBreakdown: [String: Int] = [:]
        for message in allMessages where !message.status.isTerminal {
            deviceBreakdown[message.targetDeviceID, default: 0] += 1
        }

        // 平均等待时间
        let pendingMessages = allMessages.filter { $0.status == .pending }
        let totalWaitTime = pendingMessages.reduce(0.0) { $0 + $1.waitingDuration }
        let avgWaitTime = pendingMessages.isEmpty ? 0 : totalWaitTime / Double(pendingMessages.count)

        // 最老消息年龄
        let oldestAge = pendingMessages.map { $0.waitingDuration }.max()

        return QueueStatistics(
            totalMessages: allMessages.count,
            pendingMessages: pending,
            sendingMessages: sending,
            deliveredMessages: delivered,
            failedMessages: failed,
            expiredMessages: expired,
            deviceBreakdown: deviceBreakdown,
            averageWaitTime: avgWaitTime,
            oldestMessageAge: oldestAge
        )
    }
}
