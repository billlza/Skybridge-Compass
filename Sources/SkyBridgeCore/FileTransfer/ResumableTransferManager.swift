import Foundation
import OSLog
import Combine

// MARK: - 可恢复传输管理器
/// 管理可恢复的文件传输，支持断点续传、传输队列和状态持久化
@MainActor
public final class ResumableTransferManager: ObservableObject {
    
    // MARK: - 单例
    
    public static let shared = ResumableTransferManager()
    
    // MARK: - 发布属性
    
    /// 所有传输任务（按队列优先级排序）
    @Published public private(set) var transfers: [ResumableTransfer] = []
    
    /// 当前活跃的传输数量
    @Published public private(set) var activeTransferCount: Int = 0
    
    /// 队列暂停状态
    @Published public var isQueuePaused: Bool = false
    
    /// 总体统计
    @Published public private(set) var statistics: ResumableTransferStatistics = ResumableTransferStatistics()
    
    // MARK: - 配置
    
    /// 最大并发传输数
    public var maxConcurrentTransfers: Int = 3
    
    /// 自动重试次数
    public var maxRetryAttempts: Int = 3
    
    /// 重试延迟（秒）
    public var retryDelay: TimeInterval = 5
    
    /// 状态持久化路径
    private var persistencePath: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("SkyBridge/Transfers")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("resumable_transfers.json")
    }
    
    // MARK: - 私有属性
    
    private let logger = Logger(subsystem: "com.skybridge.transfer", category: "ResumableTransfer")
    private var transferTasks: [UUID: Task<Void, Never>] = [:]
    private var cancellables = Set<AnyCancellable>()

    // 复用现有引擎（本期先保证可编译 + 基础队列；后续再把断点续传/进度回调与引擎更深度整合）
    private let fileTransferEngine = FileTransferEngine()
    
    // MARK: - 初始化
    
    private init() {
        loadPersistedState()
        startQueueProcessor()
    }
    
    // MARK: - 公开 API
    
    /// 添加传输任务到队列
    public func enqueue(
        _ transfer: ResumableTransfer,
        priority: ResumablePriority = .normal
    ) {
        var newTransfer = transfer
        newTransfer.priority = priority
        newTransfer.queuedAt = Date()
        newTransfer.state = .queued
        
        transfers.append(newTransfer)
        sortQueue()
        savePersistedState()
        
        logger.info("📥 传输入队: \(transfer.fileName) priority=\(priority.rawValue)")
        processQueue()
    }
    
    /// 批量添加传输任务
    public func enqueueBatch(
        _ files: [URL],
        targetDevice: ResumableTransfer.DeviceInfo,
        priority: ResumablePriority = .normal
    ) {
        for url in files {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let fileSize = attributes[.size] as? Int64 else {
                logger.warning("⚠️ 无法获取文件信息: \(url.lastPathComponent)")
                continue
            }
            
            let transfer = ResumableTransfer(
                id: UUID(),
                fileName: url.lastPathComponent,
                fileURL: url,
                fileSize: fileSize,
                direction: .outgoing,
                targetDevice: targetDevice,
                priority: priority
            )
            
            enqueue(transfer, priority: priority)
        }
    }
    
    /// 暂停传输
    public func pause(_ transferId: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == transferId }) else { return }
        
        transfers[index].state = .paused
        transferTasks[transferId]?.cancel()
        transferTasks.removeValue(forKey: transferId)
        activeTransferCount = max(0, activeTransferCount - 1)
        
        savePersistedState()
        logger.info("⏸️ 传输暂停: \(self.transfers[index].fileName)")
    }
    
    /// 恢复传输
    public func resume(_ transferId: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == transferId }) else { return }
        guard transfers[index].state == .paused || transfers[index].state == .failed else { return }
        
        transfers[index].state = .queued
        transfers[index].retryCount = 0  // 重置重试计数
        
        savePersistedState()
        processQueue()
        logger.info("▶️ 传输恢复: \(self.transfers[index].fileName)")
    }
    
    /// 取消传输
    public func cancel(_ transferId: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == transferId }) else { return }
        
        transfers[index].state = .cancelled
        transferTasks[transferId]?.cancel()
        transferTasks.removeValue(forKey: transferId)
        
        if transfers[index].state == .transferring {
            activeTransferCount = max(0, activeTransferCount - 1)
        }
        
        // 清理临时文件
        cleanupTemporaryFiles(for: transfers[index])
        
        savePersistedState()
        processQueue()
        logger.info("❌ 传输取消: \(self.transfers[index].fileName)")
    }
    
    /// 重试失败的传输
    public func retry(_ transferId: UUID) {
        resume(transferId)
    }
    
    /// 调整优先级
    public func setPriority(_ transferId: UUID, priority: ResumablePriority) {
        guard let index = transfers.firstIndex(where: { $0.id == transferId }) else { return }
        
        transfers[index].priority = priority
        sortQueue()
        savePersistedState()
        
        logger.info("📊 优先级调整: \(self.transfers[index].fileName) -> \(priority.rawValue)")
    }
    
    /// 清除已完成的传输
    public func clearCompleted() {
        transfers.removeAll { $0.state == .completed || $0.state == .cancelled }
        savePersistedState()
    }
    
    /// 全部暂停
    public func pauseAll() {
        isQueuePaused = true
        for transfer in transfers where transfer.state == .transferring || transfer.state == .queued {
            pause(transfer.id)
        }
    }
    
    /// 全部恢复
    public func resumeAll() {
        isQueuePaused = false
        for transfer in transfers where transfer.state == .paused {
            resume(transfer.id)
        }
    }
    
    /// 获取传输状态摘要
    public func getStatusSummary() -> TransferStatusSummary {
        TransferStatusSummary(
            queued: transfers.filter { $0.state == .queued }.count,
            transferring: transfers.filter { $0.state == .transferring }.count,
            paused: transfers.filter { $0.state == .paused }.count,
            completed: transfers.filter { $0.state == .completed }.count,
            failed: transfers.filter { $0.state == .failed }.count,
            totalBytes: transfers.reduce(0) { $0 + $1.fileSize },
            transferredBytes: transfers.reduce(0) { $0 + $1.transferredBytes }
        )
    }
    
    // MARK: - 队列处理
    
    private func startQueueProcessor() {
        // 每秒检查一次队列
        Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.processQueue()
                self?.updateStatistics()
            }
            .store(in: &cancellables)
    }
    
    private func processQueue() {
        guard !isQueuePaused else { return }
        guard activeTransferCount < maxConcurrentTransfers else { return }
        
        // 找到下一个待处理的传输
        guard let nextIndex = transfers.firstIndex(where: { $0.state == .queued }) else { return }
        
        let transfer = transfers[nextIndex]
        startTransfer(transfer)
    }
    
    private func startTransfer(_ transfer: ResumableTransfer) {
        guard let index = transfers.firstIndex(where: { $0.id == transfer.id }) else { return }
        
        transfers[index].state = .transferring
        transfers[index].startedAt = Date()
        activeTransferCount += 1
        
        let task = Task { [weak self] in
            guard let self else { return }
            await self.executeTransfer(transfer.id)
        }
        
        transferTasks[transfer.id] = task
        logger.info("🚀 开始传输: \(transfer.fileName)")
    }
    
    private func executeTransfer(_ transferId: UUID) async {
        guard let index = transfers.firstIndex(where: { $0.id == transferId }) else { return }
        let transfer = transfers[index]
        
        do {
            switch transfer.direction {
            case .outgoing:
                try await executeOutgoingTransfer(transfer)
            case .incoming:
                try await executeIncomingTransfer(transfer)
            }
            
            // 传输成功
            await MainActor.run {
                if let idx = self.transfers.firstIndex(where: { $0.id == transferId }) {
                    self.transfers[idx].state = .completed
                    self.transfers[idx].completedAt = Date()
                    self.activeTransferCount = max(0, self.activeTransferCount - 1)
                    self.statistics.completedCount += 1
                    self.statistics.totalBytesTransferred += self.transfers[idx].fileSize
                }
                self.transferTasks.removeValue(forKey: transferId)
                self.savePersistedState()
                self.processQueue()
            }
            
            logger.info("✅ 传输完成: \(transfer.fileName)")
            
        } catch {
            await handleTransferError(transferId: transferId, error: error)
        }
    }
    
    private func executeOutgoingTransfer(_ transfer: ResumableTransfer) async throws {
        // 先对齐现有 FileTransferEngine API（sendFile(at:to:...)），保证队列基础能力可用。
        // 断点续传/分块进度：后续通过引擎 session/通知机制接入。
        _ = try await fileTransferEngine.sendFile(
            at: transfer.fileURL,
            to: transfer.targetDevice.deviceId,
            compressionEnabled: transfer.fileSize > 1024 * 1024,
            encryptionEnabled: true
        )
    }
    
    private func executeIncomingTransfer(_ transfer: ResumableTransfer) async throws {
        // 接收传输由 FileTransferEngine 的监听器处理
        // 这里主要负责状态跟踪
        
        // 等待传输完成或超时
        let timeout: TimeInterval = 3600 // 1 小时超时
        let startTime = Date()
        
        while true {
            try await Task.sleep(nanoseconds: 500_000_000) // 500ms
            
            guard let idx = transfers.firstIndex(where: { $0.id == transfer.id }) else {
                throw ResumableTransferError.transferNotFound
            }
            
            let currentTransfer = transfers[idx]
            
            if currentTransfer.state == .completed {
                return
            }
            
            if currentTransfer.state == .cancelled {
                throw ResumableTransferError.transferCancelled
            }
            
            if Date().timeIntervalSince(startTime) > timeout {
                throw ResumableTransferError.timeout
            }
        }
    }
    
    private func handleTransferError(transferId: UUID, error: Error) async {
        await MainActor.run {
            guard let idx = self.transfers.firstIndex(where: { $0.id == transferId }) else { return }
            
            self.transfers[idx].lastError = error.localizedDescription
            self.transfers[idx].retryCount += 1
            
            if self.transfers[idx].retryCount < self.maxRetryAttempts {
                // 安排重试
                self.transfers[idx].state = .queued
                self.logger.warning("⚠️ 传输失败，将重试: \(self.transfers[idx].fileName) 尝试 \(self.transfers[idx].retryCount)/\(self.maxRetryAttempts)")
                
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(self.retryDelay * 1_000_000_000))
                    await MainActor.run {
                        self.processQueue()
                    }
                }
            } else {
                // 超过重试次数，标记为失败
                self.transfers[idx].state = .failed
                self.statistics.failedCount += 1
                self.logger.error("❌ 传输失败: \(self.transfers[idx].fileName) - \(error.localizedDescription)")
            }
            
            self.activeTransferCount = max(0, self.activeTransferCount - 1)
            self.transferTasks.removeValue(forKey: transferId)
            self.savePersistedState()
        }
    }
    
    // MARK: - 辅助方法
    
    private func sortQueue() {
        transfers.sort { a, b in
            // 首先按状态排序（活跃的在前）
            let stateOrder: [ResumableTransfer.TransferState: Int] = [
                .transferring: 0,
                .queued: 1,
                .paused: 2,
                .failed: 3,
                .completed: 4,
                .cancelled: 5
            ]
            
            let aState = stateOrder[a.state] ?? 5
            let bState = stateOrder[b.state] ?? 5
            
            if aState != bState {
                return aState < bState
            }
            
            // 然后按优先级排序
            if a.priority != b.priority {
                return a.priority.rawValue > b.priority.rawValue
            }
            
            // 最后按入队时间排序
            return (a.queuedAt ?? Date.distantPast) < (b.queuedAt ?? Date.distantPast)
        }
    }
    
    private func updateStatistics() {
        let activeTransfers = transfers.filter { $0.state == .transferring }
        
        // 计算总速度
        var totalSpeed: Double = 0
        for transfer in activeTransfers {
            if let startTime = transfer.startedAt {
                let elapsed = Date().timeIntervalSince(startTime)
                if elapsed > 0 {
                    totalSpeed += Double(transfer.transferredBytes) / elapsed
                }
            }
        }
        
        statistics.currentSpeed = totalSpeed
        statistics.activeTransferCount = activeTransfers.count
        statistics.queuedCount = transfers.filter { $0.state == .queued }.count
    }
    
    private func cleanupTemporaryFiles(for transfer: ResumableTransfer) {
        // 清理传输过程中的临时文件
        if transfer.direction == .incoming {
            let tempPath = NSTemporaryDirectory().appending("skybridge_\(transfer.id).tmp")
            try? FileManager.default.removeItem(atPath: tempPath)
        }
    }
    
    // MARK: - 持久化
    
    private func savePersistedState() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(transfers)
            try data.write(to: persistencePath, options: .atomic)
            logger.debug("💾 传输状态已保存")
        } catch {
            logger.error("❌ 保存传输状态失败: \(error.localizedDescription)")
        }
    }
    
    private func loadPersistedState() {
        guard FileManager.default.fileExists(atPath: persistencePath.path) else { return }
        
        do {
            let data = try Data(contentsOf: persistencePath)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var loaded = try decoder.decode([ResumableTransfer].self, from: data)
            
            // 恢复之前活跃的传输为队列状态
            for i in loaded.indices {
                if loaded[i].state == .transferring {
                    loaded[i].state = .queued
                }
            }
            
            transfers = loaded
            logger.info("📂 加载了 \(self.transfers.count) 个持久化传输任务")
        } catch {
            logger.warning("⚠️ 加载传输状态失败: \(error.localizedDescription)")
        }
    }
}

// MARK: - 数据类型

/// 可恢复的传输任务
public struct ResumableTransfer: Codable, Identifiable, Sendable {
    public let id: UUID
    public let fileName: String
    public let fileURL: URL
    public let fileSize: Int64
    public let direction: TransferDirection
    public let targetDevice: DeviceInfo
    
    public var priority: ResumablePriority = .normal
    public var state: TransferState = .queued
    public var transferredBytes: Int64 = 0
    public var retryCount: Int = 0
    public var lastError: String?
    
    public var queuedAt: Date?
    public var startedAt: Date?
    public var completedAt: Date?
    public var lastActiveAt: Date?
    
    /// 进度百分比 (0-100)
    public var progress: Double {
        guard fileSize > 0 else { return 0 }
        return Double(transferredBytes) / Double(fileSize) * 100
    }
    
    /// 估计剩余时间（秒）
    public var estimatedTimeRemaining: TimeInterval? {
        guard let startTime = startedAt,
              transferredBytes > 0 else { return nil }
        
        let elapsed = Date().timeIntervalSince(startTime)
        let speed = Double(transferredBytes) / elapsed
        guard speed > 0 else { return nil }
        
        let remaining = Double(fileSize - transferredBytes) / speed
        return remaining
    }
    
    public enum TransferDirection: String, Codable, Sendable {
        case incoming
        case outgoing
    }
    
    public enum TransferState: String, Codable, Sendable {
        case queued
        case transferring
        case paused
        case completed
        case failed
        case cancelled
    }
    
    public struct DeviceInfo: Codable, Sendable {
        public let deviceId: String
        public let deviceName: String
        public let connectionType: String
        
        public init(deviceId: String, deviceName: String, connectionType: String) {
            self.deviceId = deviceId
            self.deviceName = deviceName
            self.connectionType = connectionType
        }
    }
    
    public init(
        id: UUID = UUID(),
        fileName: String,
        fileURL: URL,
        fileSize: Int64,
        direction: TransferDirection,
        targetDevice: DeviceInfo,
        priority: ResumablePriority = .normal
    ) {
        self.id = id
        self.fileName = fileName
        self.fileURL = fileURL
        self.fileSize = fileSize
        self.direction = direction
        self.targetDevice = targetDevice
        self.priority = priority
    }
}

/// 可恢复传输优先级
public enum ResumablePriority: Int, Codable, Sendable, Comparable {
    case low = 0
    case normal = 1
    case high = 2
    case urgent = 3
    
    public static func < (lhs: ResumablePriority, rhs: ResumablePriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// 可恢复传输统计
public struct ResumableTransferStatistics: Sendable {
    public var completedCount: Int = 0
    public var failedCount: Int = 0
    public var totalBytesTransferred: Int64 = 0
    public var currentSpeed: Double = 0
    public var activeTransferCount: Int = 0
    public var queuedCount: Int = 0
}

/// 传输状态摘要
public struct TransferStatusSummary: Sendable {
    public let queued: Int
    public let transferring: Int
    public let paused: Int
    public let completed: Int
    public let failed: Int
    public let totalBytes: Int64
    public let transferredBytes: Int64
    
    public var overallProgress: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(transferredBytes) / Double(totalBytes) * 100
    }
}

/// 可恢复传输错误
public enum ResumableTransferError: Error, LocalizedError {
    case engineNotAvailable
    case transferNotFound
    case transferCancelled
    case timeout
    case networkError(underlying: Error?)
    
    public var errorDescription: String? {
        switch self {
        case .engineNotAvailable:
            return "传输引擎不可用"
        case .transferNotFound:
            return "传输任务未找到"
        case .transferCancelled:
            return "传输已取消"
        case .timeout:
            return "传输超时"
        case .networkError(let underlying):
            return "网络错误: \(underlying?.localizedDescription ?? "未知")"
        }
    }
}


