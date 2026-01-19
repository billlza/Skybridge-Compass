//
// DiscoveryOrchestrator.swift
// Skybridge-Compass
//
// 统一调度本地设备发现（网络 / USB / 蓝牙）。
// 目标：
//
// - 只允许同一时间存在一个扫描 Job
// - 支持可选的自动超时（autoTimeout + maxDuration）
// - 不依赖任何“未来框架”，只用稳定的 Swift 并发 + Foundation
//

import Foundation
import OSLog
import Network

// MARK: - 公共配置选项

/// 控制一次“统一发现”要跑哪些通道、跑多久。
public struct DiscoveryOptions: Sendable {

 /// 是否启用基于 Network.framework / Bonjour 的网络扫描
    public var enableNetwork: Bool

 /// 是否启用 USB 设备扫描
    public var enableUSB: Bool

 /// 是否启用蓝牙设备扫描
    public var enableBluetooth: Bool

 /// 是否自动在 `maxDuration` 后结束本次扫描
    public var autoTimeout: Bool

 /// 本次扫描最长持续时长（秒）
    public var maxDuration: TimeInterval

 /// 并发限制（同时运行的通道数）
    public var concurrentLimit: Int

    public init(
        enableNetwork: Bool = true,
        enableUSB: Bool = true,
        enableBluetooth: Bool = true,
        autoTimeout: Bool = true,
        maxDuration: TimeInterval = 20,
        concurrentLimit: Int = 2
    ) {
        self.enableNetwork = enableNetwork
        self.enableUSB = enableUSB
        self.enableBluetooth = enableBluetooth
        self.autoTimeout = autoTimeout
        self.maxDuration = max(0, maxDuration)
        self.concurrentLimit = max(1, concurrentLimit)
    }
}

// MARK: - 内部 Job 模型

/// 单次“扫描任务”的并发封装。
/// 只在本文件内部使用，不暴露给外部模块。
actor DiscoveryJob {

    enum State: Sendable {
        case idle
        case running
        case finished
        case cancelled
    }

    let id: UUID = UUID()
    let options: DiscoveryOptions

    private(set) var state: State = .idle

 /// 负责跑网络 / USB / 蓝牙扫描的任务
    private var workerTask: Task<Void, Never>?

 /// 负责处理自动超时的任务（如果启用的话）
    private var timeoutTask: Task<Void, Never>?

    init(options: DiscoveryOptions) {
        self.options = options
    }

 /// 启动本次 Job，对应一次统一扫描。
    func start(
        network: (@Sendable () async -> Void)?,
        usb: (@Sendable () async -> Void)?,
        bluetooth: (@Sendable () async -> Void)?
    ) {
        guard state == .idle else { return }
        state = .running

 // 主工作任务：并行跑各个通道的扫描逻辑
        workerTask = Task {
            await withTaskGroup(of: Void.self) { group in
                if let network, options.enableNetwork {
                    group.addTask { await network() }
                }
                if let usb, options.enableUSB {
                    group.addTask { await usb() }
                }
                if let bluetooth, options.enableBluetooth {
                    group.addTask { await bluetooth() }
                }

 // 等待所有子任务结束（或被取消）
                await group.waitForAll()
            }

 // 所有子任务完成后，如果还在 running，则标记为 finished
            await self.finalizeJob()
        }

 // 自动超时逻辑
        if options.autoTimeout, options.maxDuration > 0 {
            let duration = options.maxDuration
            timeoutTask = Task { [weak self] in
 // 若 自己被 cancel，这里会直接抛错退出
                try? await Task.sleep(
                    nanoseconds: UInt64(duration * 1_000_000_000)
                )
                await self?.timeout()
            }
        }
    }

 /// 主动取消本次 Job。
    func cancel() {
        guard state == .running || state == .idle else { return }

        state = .cancelled
        workerTask?.cancel()
        timeoutTask?.cancel()
        workerTask = nil
        timeoutTask = nil
    }

 /// 自动超时时调用。
    private func timeout() {
 // 如果已经结束/取消，就不用再动
        guard state == .running else { return }

        state = .cancelled
        workerTask?.cancel()
        workerTask = nil
        timeoutTask = nil
    }

 /// 所有子任务自然结束时调用。
    private func finishIfNeeded() {
        if state == .running {
            state = .finished
        }
        timeoutTask?.cancel()
        timeoutTask = nil
        workerTask = nil
    }

    nonisolated func finalizeJob() async {
        await self.finishIfNeeded()
    }
}

// MARK: - 统一调度器

/// 统一调度网络 / USB / 蓝牙三路扫描的 Orchestrator。
///
/// 只暴露：
/// - `start(options:network:usb:bluetooth:)`
/// - `stop()`
///
/// 由 `UnifiedDeviceDiscoveryManager` 之类的上层管理器调用。
public actor DiscoveryOrchestrator {

 // MARK: - 冷却期配置
    
 /// 冷却期配置
    public struct CooldownConfig: Sendable {
 /// 冷却期时长（秒），默认 300 秒
        public var duration: TimeInterval = 300
        
 /// 是否允许手动触发覆盖冷却期，默认允许
        public var allowManualOverride: Bool = true
        
        public init(duration: TimeInterval = 300, allowManualOverride: Bool = true) {
            self.duration = duration
            self.allowManualOverride = allowManualOverride
        }
    }
    
 // MARK: - 属性

    private let logger = Logger(
        subsystem: "com.skybridge.Compass",
        category: "DiscoveryOrchestrator"
    )

 /// 当前正在运行的 Job；保证同一时刻最多一个。
    private var currentJob: DiscoveryJob?
    
 /// 冷却期配置
    private var cooldownConfig = CooldownConfig()
    
 /// 上次扫描完成时间
    private var lastJobFinishedAt: Date?
    
 /// 当前是否处于冷却期
    private var isCoolingDown: Bool {
        guard let lastFinish = lastJobFinishedAt else { return false }
        return Date().timeIntervalSince(lastFinish) < cooldownConfig.duration
    }

    public init() {}

 /// 启动一次新的发现流程。
 ///
 /// - Parameters:
 /// - options: 控制本次扫描要跑哪些通道、持续多久。
 /// - network: 网络扫描逻辑（例如调用 DeviceDiscoveryManager 的 Bonjour/NWBrowser）。
 /// - usb: USB 扫描逻辑。
 /// - bluetooth: 蓝牙扫描逻辑。
 /// - isUserTriggered: 是否为用户手动触发（默认 false），手动触发可以覆盖冷却期
 ///
 /// 任何一个 closure 都可以为 nil，此时对应通道直接跳过。
    public func start(
        options: DiscoveryOptions,
        network: (@Sendable () async -> Void)? = nil,
        usb: (@Sendable () async -> Void)? = nil,
        bluetooth: (@Sendable () async -> Void)? = nil,
        isUserTriggered: Bool = false
    ) async {
 // 🆕 冷却期检查（只限制自动扫描，不限制用户手动触发）
        if isCoolingDown && !isUserTriggered {
            let remaining = cooldownConfig.duration - Date().timeIntervalSince(lastJobFinishedAt ?? Date())
            logger.info("⏱️ 处于冷却期，忽略自动扫描请求（剩余 \(Int(remaining)) 秒）")
            return
        }
        
 // 如果用户手动触发且允许覆盖，记录日志
        if isCoolingDown && isUserTriggered && cooldownConfig.allowManualOverride {
            logger.info("🚀 用户手动触发扫描，覆盖冷却期限制")
        }
        
 // 如果上一次扫描还没停，先取消掉
        if let job = currentJob {
            logger.debug("Cancelling previous discovery job: \(job.id.uuidString, privacy: .public)")
            await job.cancel()
            currentJob = nil
        }

        let job = DiscoveryJob(options: options)
        currentJob = job

        logger.info("""
        🔍 Starting discovery job \(job.id.uuidString, privacy: .public) \
        network=\(options.enableNetwork, privacy: .public) \
        usb=\(options.enableUSB, privacy: .public) \
        bluetooth=\(options.enableBluetooth, privacy: .public) \
        timeout=\(options.autoTimeout ? options.maxDuration : 0, privacy: .public)s \
        userTriggered=\(isUserTriggered, privacy: .public)
        """)

        await job.start(network: network, usb: usb, bluetooth: bluetooth)
        
 // 🆕 扫描完成后记录时间（用于冷却期）
 // 注意：这里是异步启动，实际完成时间由 job 内部控制
 // 我们在这里记录一个启动时间 + maxDuration 的估算值
        if options.autoTimeout && options.maxDuration > 0 {
 // 等待扫描完成后记录时间
            Task {
                try? await Task.sleep(nanoseconds: UInt64((options.maxDuration + 1) * 1_000_000_000))
                self.recordJobCompletion()
            }
        }
    }
    
 /// 记录扫描任务完成时间
    private func recordJobCompletion() {
        self.lastJobFinishedAt = Date()
        self.logger.debug("📝 记录扫描完成时间，下次可扫描时间: \(Date().addingTimeInterval(self.cooldownConfig.duration))")
    }

 /// 手动停止当前的发现流程（如果有的话）。
    public func stop() async {
        guard let job = currentJob else { return }
        logger.info("🛑 Stopping discovery job \(job.id.uuidString, privacy: .public)")
        await job.cancel()
        currentJob = nil
        
 // 停止时也记录完成时间
        recordJobCompletion()
    }

 /// 当前是否有扫描在进行中（仅供调试或上层状态展示）。
    public func isRunning() -> Bool {
        currentJob != nil
    }
    
 /// 检查是否处于冷却期
    public func checkCoolingDown() -> Bool {
        return isCoolingDown
    }
    
 /// 获取冷却期剩余时间（秒）
    public func getCooldownRemaining() -> TimeInterval {
        guard let lastFinish = lastJobFinishedAt else { return 0 }
        let elapsed = Date().timeIntervalSince(lastFinish)
        return max(0, cooldownConfig.duration - elapsed)
    }
    
 /// 配置冷却期参数
    public func configureCooldown(config: CooldownConfig) {
        self.cooldownConfig = config
        logger.info("⚙️ 冷却期配置已更新: duration=\(config.duration)s, allowManualOverride=\(config.allowManualOverride)")
    }
    
 /// 重置冷却期（立即允许下次扫描）
    public func resetCooldown() {
        lastJobFinishedAt = nil
        logger.info("🔄 冷却期已重置")
    }
}

// MARK: - 统一广播中心

/// 统一封装 Bonjour 广播生命周期，确保同一服务类型只存在一个 NWListener
public actor ServiceAdvertiserCenter {
    private let logger = Logger(
        subsystem: "com.skybridge.Compass",
        category: "ServiceAdvertiserCenter"
    )
    private var listeners: [String: NWListener] = [:]

    public static let shared = ServiceAdvertiserCenter()

 /// 启动指定服务类型的广播，若已有同类型监听则先取消；返回实际端口（若系统未暴露则返回 0）
    public func startAdvertising(
        serviceName: String,
        serviceType: String,
        txtRecord: NWTXTRecord? = nil,
        connectionHandler: (@Sendable (NWConnection) -> Void)? = nil,
        stateHandler: (@Sendable (NWListener.State) -> Void)? = nil
    ) throws -> UInt16 {
        if let existing = listeners[serviceType] {
            existing.cancel()
            listeners.removeValue(forKey: serviceType)
            logger.debug("取消旧广播: \(serviceType, privacy: .public)")
        }

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let listener = try NWListener(using: parameters)

        // 默认携带基础 TXT（iOS 端用于显示系统版本等）
        let finalTXT = txtRecord ?? makeDefaultTXTRecord()
        let service = NWListener.Service(name: serviceName, type: serviceType, domain: "local.", txtRecord: finalTXT)
        listener.service = service
        if let ch = connectionHandler {
            listener.newConnectionHandler = { conn in ch(conn) }
        }
        let log = self.logger
        listener.stateUpdateHandler = { state in
            stateHandler?(state)
            if case .failed(let error) = state {
                log.error("❌ 广播监听失败: \(error.localizedDescription, privacy: .public)")
            }
        }
        listener.start(queue: .global(qos: .utility))
        listeners[serviceType] = listener
        let port = listener.port?.rawValue ?? 0
        if port > 0 {
            logger.info("📡 广播服务启动: \(serviceType, privacy: .public) 端口 \(port, privacy: .public)")
        } else {
            logger.info("📡 广播服务启动: \(serviceType, privacy: .public) 系统分配端口")
        }
        return UInt16(port)
    }

 /// 仅在未运行时启动指定服务类型的广播，避免重复启动造成的 stop→start 风暴
    public func startAdvertisingIfNeeded(
        serviceName: String,
        serviceType: String,
        txtRecord: NWTXTRecord? = nil,
        connectionHandler: (@Sendable (NWConnection) -> Void)? = nil,
        stateHandler: (@Sendable (NWListener.State) -> Void)? = nil
    ) throws -> UInt16 {
        if isAdvertising(serviceType) {
            return UInt16(listeners[serviceType]?.port?.rawValue ?? 0)
        }
        return try startAdvertising(
            serviceName: serviceName,
            serviceType: serviceType,
            txtRecord: txtRecord,
            connectionHandler: connectionHandler,
            stateHandler: stateHandler
        )
    }

    private func makeDefaultTXTRecord() -> NWTXTRecord {
        var record = NWTXTRecord()
        record["platform"] = "macos"
        record["osVersion"] = ProcessInfo.processInfo.operatingSystemVersionString
        record["name"] = Host.current().localizedName ?? "Mac"
        return record
    }

 /// 查询指定服务类型是否正在广播
    public func isAdvertising(_ serviceType: String) -> Bool {
        return listeners[serviceType] != nil
    }

 /// 停止指定服务类型的广播
    public func stopAdvertising(_ serviceType: String) {
        if let listener = listeners[serviceType] {
            listener.cancel()
            listeners.removeValue(forKey: serviceType)
            logger.info("⏹️ 停止广播: \(serviceType, privacy: .public)")
        }
    }

 /// 停止所有广播
    public func stopAll() {
        for (_, l) in listeners { l.cancel() }
        listeners.removeAll()
        logger.info("⏹️ 停止所有广播")
    }
}
