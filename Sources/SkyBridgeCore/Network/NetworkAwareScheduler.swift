//
// NetworkAwareScheduler.swift
// SkyBridgeCore
//
// 网络感知传输调度服务
// 支持 macOS 14.0+, 使用 NWPathMonitor + QoS
//
// 设计特点:
// - 使用 NWPathMonitor 实时监控网络状态
// - 根据网络条件自动调整传输优先级
// - 支持 WiFi/蜂窝/有线自动切换
// - QoS 优先级管理
//

import Foundation
import Network
import OSLog

// MARK: - 网络状态类型

/// 调度器网络类型
public enum SchedulerNetworkType: String, Sendable, Codable {
    case wifi = "wifi"
    case cellular = "cellular"
    case wired = "wired"
    case loopback = "loopback"
    case unknown = "unknown"

    public var displayName: String {
        switch self {
        case .wifi: return "WiFi"
        case .cellular: return "蜂窝网络"
        case .wired: return "有线网络"
        case .loopback: return "本地回环"
        case .unknown: return "未知"
        }
    }

    public var icon: String {
        switch self {
        case .wifi: return "wifi"
        case .cellular: return "antenna.radiowaves.left.and.right"
        case .wired: return "cable.connector"
        case .loopback: return "arrow.triangle.2.circlepath"
        case .unknown: return "questionmark.circle"
        }
    }

    /// 是否支持大流量传输
    public var supportsLargeTransfer: Bool {
        switch self {
        case .wifi, .wired: return true
        default: return false
        }
    }
}

/// 调度器网络状态快照
public struct SchedulerNetworkStatus: Sendable {
    public let isConnected: Bool
    public let networkType: SchedulerNetworkType
    public let isExpensive: Bool
    public let isConstrained: Bool
    public let supportsIPv4: Bool
    public let supportsIPv6: Bool
    public let interfaceName: String?
    public let timestamp: Date

    public static let disconnected = SchedulerNetworkStatus(
        isConnected: false,
        networkType: .unknown,
        isExpensive: false,
        isConstrained: false,
        supportsIPv4: false,
        supportsIPv6: false,
        interfaceName: nil,
        timestamp: Date()
    )

    public init(
        isConnected: Bool,
        networkType: SchedulerNetworkType,
        isExpensive: Bool,
        isConstrained: Bool,
        supportsIPv4: Bool,
        supportsIPv6: Bool,
        interfaceName: String?,
        timestamp: Date = Date()
    ) {
        self.isConnected = isConnected
        self.networkType = networkType
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.supportsIPv4 = supportsIPv4
        self.supportsIPv6 = supportsIPv6
        self.interfaceName = interfaceName
        self.timestamp = timestamp
    }
}

// MARK: - 传输任务

/// 网络调度传输优先级
public enum NetworkTransferPriority: Int, Sendable, Codable, Comparable {
    case low = 0
    case normal = 1
    case high = 2
    case realtime = 3

    public static func < (lhs: NetworkTransferPriority, rhs: NetworkTransferPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var displayName: String {
        switch self {
        case .low: return "低优先级"
        case .normal: return "普通"
        case .high: return "高优先级"
        case .realtime: return "实时"
        }
    }

    /// 转换为系统 QoS
    public var qualityOfService: DispatchQoS.QoSClass {
        switch self {
        case .low: return .utility
        case .normal: return .default
        case .high: return .userInitiated
        case .realtime: return .userInteractive
        }
    }
}

/// 调度传输任务
public struct ScheduledTransfer: Identifiable, Sendable {
    public let id: UUID
    public let taskDescription: String
    public let dataSize: Int64
    public var priority: NetworkTransferPriority
    public let requiresWiFi: Bool
    public let createdAt: Date
    public var status: ScheduledTransferStatus
    public var networkTypeUsed: SchedulerNetworkType?

    public init(
        taskDescription: String,
        dataSize: Int64,
        priority: NetworkTransferPriority = .normal,
        requiresWiFi: Bool = false
    ) {
        self.id = UUID()
        self.taskDescription = taskDescription
        self.dataSize = dataSize
        self.priority = priority
        self.requiresWiFi = requiresWiFi
        self.createdAt = Date()
        self.status = .pending
        self.networkTypeUsed = nil
    }
}

/// 调度传输状态
public enum ScheduledTransferStatus: String, Sendable, Codable {
    case pending = "pending"
    case scheduled = "scheduled"
    case running = "running"
    case paused = "paused"
    case completed = "completed"
    case failed = "failed"
    case cancelled = "cancelled"

    public var displayName: String {
        switch self {
        case .pending: return "等待中"
        case .scheduled: return "已调度"
        case .running: return "传输中"
        case .paused: return "已暂停"
        case .completed: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }
}

// MARK: - 调度策略

/// 网络感知调度策略
public struct SchedulingPolicy: Codable, Sendable {
    /// 是否在蜂窝网络传输大文件
    public var allowLargeTransferOnCellular: Bool

    /// 大文件阈值（字节）
    public var largeFileThreshold: Int64

    /// 低数据模式下是否暂停
    public var pauseOnLowDataMode: Bool

    /// 网络切换时是否自动恢复
    public var autoResumeOnBetterNetwork: Bool

    /// 最大并发传输数
    public var maxConcurrentTransfers: Int

    /// 实时传输超时（秒）
    public var realtimeTimeout: TimeInterval

    /// 默认策略
    public static let `default` = SchedulingPolicy(
        allowLargeTransferOnCellular: false,
        largeFileThreshold: 50 * 1024 * 1024, // 50MB
        pauseOnLowDataMode: true,
        autoResumeOnBetterNetwork: true,
        maxConcurrentTransfers: 3,
        realtimeTimeout: 30
    )

    public init(
        allowLargeTransferOnCellular: Bool = false,
        largeFileThreshold: Int64 = 50 * 1024 * 1024,
        pauseOnLowDataMode: Bool = true,
        autoResumeOnBetterNetwork: Bool = true,
        maxConcurrentTransfers: Int = 3,
        realtimeTimeout: TimeInterval = 30
    ) {
        self.allowLargeTransferOnCellular = allowLargeTransferOnCellular
        self.largeFileThreshold = largeFileThreshold
        self.pauseOnLowDataMode = pauseOnLowDataMode
        self.autoResumeOnBetterNetwork = autoResumeOnBetterNetwork
        self.maxConcurrentTransfers = maxConcurrentTransfers
        self.realtimeTimeout = realtimeTimeout
    }
}

// MARK: - 网络感知调度服务

/// 网络感知传输调度服务
@MainActor
public final class NetworkAwareScheduler: ObservableObject {

    // MARK: - Singleton

    public static let shared = NetworkAwareScheduler()

    // MARK: - Published Properties

    /// 当前网络状态
    @Published public private(set) var networkStatus: SchedulerNetworkStatus = .disconnected

    /// 调度策略
    @Published public var policy: SchedulingPolicy {
        didSet { savePolicy() }
    }

    /// 待处理传输队列
    @Published public private(set) var pendingTransfers: [ScheduledTransfer] = []

    /// 正在进行的传输
    @Published public private(set) var activeTransfers: [ScheduledTransfer] = []

    /// 是否正在监控
    @Published public private(set) var isMonitoring: Bool = false

    // MARK: - Private Properties

    private let logger = Logger(subsystem: "com.skybridge.compass", category: "NetworkScheduler")
    private var pathMonitor: NWPathMonitor?
    private let monitorQueue = DispatchQueue(label: "com.skybridge.networkMonitor")

    // 传输执行回调
    public var transferHandler: ((ScheduledTransfer) async throws -> Void)?

    // MARK: - Initialization

    private init() {
        self.policy = Self.loadPolicy() ?? .default
        logger.info("📡 网络感知调度服务已初始化")
    }

    // MARK: - Public Methods

    /// 开始网络监控
    public func startMonitoring() {
        guard !isMonitoring else { return }

        pathMonitor = NWPathMonitor()

        pathMonitor?.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.handlePathUpdate(path)
            }
        }

        pathMonitor?.start(queue: monitorQueue)
        isMonitoring = true

        logger.info("📡 开始网络监控")
    }

    /// 停止网络监控
    public func stopMonitoring() {
        pathMonitor?.cancel()
        pathMonitor = nil
        isMonitoring = false

        logger.info("📡 停止网络监控")
    }

    /// 调度传输任务
    @discardableResult
    public func scheduleTransfer(
        description: String,
        dataSize: Int64,
        priority: NetworkTransferPriority = .normal,
        requiresWiFi: Bool = false
    ) -> ScheduledTransfer {
        var transfer = ScheduledTransfer(
            taskDescription: description,
            dataSize: dataSize,
            priority: priority,
            requiresWiFi: requiresWiFi
        )

        // 检查是否可以立即执行
        if canExecuteTransfer(transfer) {
            transfer.status = .scheduled
            pendingTransfers.append(transfer)
            processQueue()
        } else {
            transfer.status = .pending
            pendingTransfers.append(transfer)
        }

        logger.info("📡 调度传输任务: \(transfer.id)")
        return transfer
    }

    /// 取消传输
    public func cancelTransfer(_ transferID: UUID) {
        if let index = pendingTransfers.firstIndex(where: { $0.id == transferID }) {
            pendingTransfers[index].status = .cancelled
            pendingTransfers.remove(at: index)
        }

        if let index = activeTransfers.firstIndex(where: { $0.id == transferID }) {
            activeTransfers[index].status = .cancelled
            activeTransfers.remove(at: index)
        }

        logger.info("📡 取消传输: \(transferID)")
    }

    /// 暂停传输
    public func pauseTransfer(_ transferID: UUID) {
        if let index = activeTransfers.firstIndex(where: { $0.id == transferID }) {
            activeTransfers[index].status = .paused
            let transfer = activeTransfers.remove(at: index)
            pendingTransfers.append(transfer)
        }
    }

    /// 恢复传输
    public func resumeTransfer(_ transferID: UUID) {
        if let index = pendingTransfers.firstIndex(where: { $0.id == transferID && $0.status == .paused }) {
            pendingTransfers[index].status = .scheduled
            processQueue()
        }
    }

    /// 调整优先级
    public func updatePriority(_ transferID: UUID, priority: NetworkTransferPriority) {
        if let index = pendingTransfers.firstIndex(where: { $0.id == transferID }) {
            pendingTransfers[index].priority = priority
            sortQueue()
        }
    }

    // MARK: - Private Methods

    private func handlePathUpdate(_ path: NWPath) {
        let previousStatus = networkStatus

        // 解析网络类型
        let networkType: SchedulerNetworkType
        if path.usesInterfaceType(.wifi) {
            networkType = .wifi
        } else if path.usesInterfaceType(.cellular) {
            networkType = .cellular
        } else if path.usesInterfaceType(.wiredEthernet) {
            networkType = .wired
        } else if path.usesInterfaceType(.loopback) {
            networkType = .loopback
        } else {
            networkType = .unknown
        }

        networkStatus = SchedulerNetworkStatus(
            isConnected: path.status == .satisfied,
            networkType: networkType,
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained,
            supportsIPv4: path.supportsIPv4,
            supportsIPv6: path.supportsIPv6,
            interfaceName: path.availableInterfaces.first?.name
        )

        logger.info("📡 网络状态更新: \(networkType.displayName), 连接: \(path.status == .satisfied)")

        // 网络改善时自动恢复传输
        if policy.autoResumeOnBetterNetwork {
            if !previousStatus.isConnected && networkStatus.isConnected {
                resumePausedTransfers()
            } else if previousStatus.networkType != networkStatus.networkType {
                reevaluateTransfers()
            }
        }

        // 低数据模式处理
        if policy.pauseOnLowDataMode && networkStatus.isConstrained {
            pauseNonEssentialTransfers()
        }

        processQueue()
    }

    private func canExecuteTransfer(_ transfer: ScheduledTransfer) -> Bool {
        guard networkStatus.isConnected else { return false }

        // 检查是否需要 WiFi
        if transfer.requiresWiFi && networkStatus.networkType != .wifi && networkStatus.networkType != .wired {
            return false
        }

        // 大文件检查
        let isLargeFile = transfer.dataSize > policy.largeFileThreshold
        if isLargeFile && !policy.allowLargeTransferOnCellular && networkStatus.networkType == .cellular {
            return false
        }

        // 低数据模式检查
        if networkStatus.isConstrained && policy.pauseOnLowDataMode && transfer.priority < .high {
            return false
        }

        return true
    }

    private func processQueue() {
        sortQueue()

        // 检查并发限制
        while activeTransfers.count < policy.maxConcurrentTransfers {
            // 找到下一个可执行的任务
            guard let index = pendingTransfers.firstIndex(where: { canExecuteTransfer($0) && $0.status == .scheduled }) else {
                break
            }

            var transfer = pendingTransfers.remove(at: index)
            transfer.status = .running
            transfer.networkTypeUsed = networkStatus.networkType
            activeTransfers.append(transfer)

            // 异步执行传输
            Task {
                await executeTransfer(transfer)
            }
        }
    }

    private func executeTransfer(_ transfer: ScheduledTransfer) async {
        guard let handler = transferHandler else {
            completeTransfer(transfer.id, success: false)
            return
        }

        do {
            try await handler(transfer)
            completeTransfer(transfer.id, success: true)
        } catch {
            logger.error("📡 传输失败: \(transfer.id), \(error.localizedDescription)")
            completeTransfer(transfer.id, success: false)
        }
    }

    private func completeTransfer(_ transferID: UUID, success: Bool) {
        if let index = activeTransfers.firstIndex(where: { $0.id == transferID }) {
            activeTransfers[index].status = success ? .completed : .failed
            activeTransfers.remove(at: index)
            processQueue()
        }
    }

    private func sortQueue() {
        pendingTransfers.sort { $0.priority > $1.priority }
    }

    private func resumePausedTransfers() {
        for i in pendingTransfers.indices where pendingTransfers[i].status == .paused {
            pendingTransfers[i].status = .scheduled
        }
        processQueue()
    }

    private func pauseNonEssentialTransfers() {
        for i in activeTransfers.indices where activeTransfers[i].priority < .high {
            var transfer = activeTransfers[i]
            transfer.status = .paused
            activeTransfers.remove(at: i)
            pendingTransfers.append(transfer)
        }
    }

    private func reevaluateTransfers() {
        // 重新评估所有待处理传输
        for i in pendingTransfers.indices {
            if canExecuteTransfer(pendingTransfers[i]) && pendingTransfers[i].status == .pending {
                pendingTransfers[i].status = .scheduled
            }
        }
        processQueue()
    }

    // MARK: - Persistence

    private func savePolicy() {
        if let data = try? JSONEncoder().encode(policy) {
            UserDefaults.standard.set(data, forKey: "com.skybridge.network.policy")
        }
    }

    private static func loadPolicy() -> SchedulingPolicy? {
        guard let data = UserDefaults.standard.data(forKey: "com.skybridge.network.policy"),
              let policy = try? JSONDecoder().decode(SchedulingPolicy.self, from: data) else {
            return nil
        }
        return policy
    }
}
