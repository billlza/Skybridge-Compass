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
import CryptoKit

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
            let jobId = job.id
            Task {
                try? await Task.sleep(nanoseconds: UInt64((options.maxDuration + 1) * 1_000_000_000))
                self.recordJobCompletion(for: jobId)
            }
        }
    }

 /// 记录扫描任务完成时间
    private func recordJobCompletion(for jobId: UUID? = nil) {
 // 忽略属于已被替换 Job 的过期计时器，避免把新启动的 Job 误置入冷却窗口。
        if let jobId, currentJob?.id != jobId { return }
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
public struct ServiceAdvertisementSnapshot: Sendable, Equatable {
    public enum ListenerState: String, Sendable {
        case absent
        case starting
        case ready
    }

    public let serviceType: String
    public let owner: String?
    public let port: UInt16?
    public let state: ListenerState

    public init(
        serviceType: String,
        owner: String? = nil,
        port: UInt16? = nil,
        state: ListenerState = .absent
    ) {
        self.serviceType = serviceType
        self.owner = owner
        self.port = port
        self.state = state
    }

    public var isAdvertising: Bool {
        state != .absent
    }

    public var isStarting: Bool {
        state == .starting
    }

    public var isConnectable: Bool {
        state == .ready && (port ?? 0) > 0
    }

    public func isOwned(by expectedOwner: String) -> Bool {
        owner == expectedOwner
    }
}

public actor ServiceAdvertiserCenter {
    public enum AdvertisingError: LocalizedError, Sendable {
        case listenerEndedBeforeReady
        case timedOut
        case ownerConflict(serviceType: String, current: String?, requested: String?)

        public var errorDescription: String? {
            switch self {
            case .listenerEndedBeforeReady:
                return "Bonjour listener ended before becoming ready"
            case .timedOut:
                return "Bonjour listener did not become ready before the startup deadline"
            case .ownerConflict(let serviceType, let current, let requested):
                let currentOwner = current ?? "<unowned>"
                let requestedOwner = requested ?? "<unowned>"
                return "Bonjour service \(serviceType) is owned by \(currentOwner); \(requestedOwner) cannot replace it"
            }
        }
    }

    private let logger = Logger(
        subsystem: "com.skybridge.Compass",
        category: "ServiceAdvertiserCenter"
    )

    private struct ListenerRecord {
        let listener: NWListener
        let owner: String?
        let token: UUID
        let readinessGate: BonjourRegistrationReadinessGate
        let connectionHandler: (@Sendable (NWConnection) -> Void)?
        let stateHandler: (@Sendable (NWListener.State) -> Void)?
        let readinessHandler: (@Sendable (Bool) -> Void)?
        var state: ServiceAdvertisementSnapshot.ListenerState
        var port: UInt16?
        var registrationEndpoints: Set<NWEndpoint>
    }

    private struct StartOperation {
        let owner: String?
        let token: UUID
        let task: Task<UInt16, Error>
    }

    private var records: [String: ListenerRecord] = [:]
    private var startOperations: [String: StartOperation] = [:]

    public static let shared = ServiceAdvertiserCenter()

 /// 启动指定服务类型的广播，若已有同类型监听则先取消；返回实际端口（若系统未暴露则返回 0）
    public func startAdvertising(
        serviceName: String,
        serviceType: String,
        owner: String? = nil,
        includePeerToPeer: Bool = true,
        connectionHandler: (@Sendable (NWConnection) -> Void)? = nil,
        stateHandler: (@Sendable (NWListener.State) -> Void)? = nil,
        readinessHandler: (@Sendable (Bool) -> Void)? = nil
    ) async throws -> UInt16 {
        if let operation = startOperations[serviceType] {
            try validateOwner(
                serviceType: serviceType,
                current: operation.owner,
                requested: owner
            )
            return try await awaitStartOperation(operation, serviceType: serviceType)
        }

        if let existing = records[serviceType] {
            try validateOwner(
                serviceType: serviceType,
                current: existing.owner,
                requested: owner
            )
            existing.readinessHandler?(false)
            Self.cancelListener(existing.listener)
            records.removeValue(forKey: serviceType)
            logger.debug("取消旧广播: \(serviceType, privacy: .public)")
        }

        return try await beginStartOperation(
            serviceName: serviceName,
            serviceType: serviceType,
            owner: owner,
            includePeerToPeer: includePeerToPeer,
            connectionHandler: connectionHandler,
            stateHandler: stateHandler,
            readinessHandler: readinessHandler
        )
    }

    private func beginStartOperation(
        serviceName: String,
        serviceType: String,
        owner: String?,
        includePeerToPeer: Bool,
        connectionHandler: (@Sendable (NWConnection) -> Void)?,
        stateHandler: (@Sendable (NWListener.State) -> Void)?,
        readinessHandler: (@Sendable (Bool) -> Void)?
    ) async throws -> UInt16 {
        let token = UUID()
        let task = Task {
            try await self.performStart(
                serviceName: serviceName,
                serviceType: serviceType,
                owner: owner,
                token: token,
                includePeerToPeer: includePeerToPeer,
                connectionHandler: connectionHandler,
                stateHandler: stateHandler,
                readinessHandler: readinessHandler
            )
        }
        let operation = StartOperation(owner: owner, token: token, task: task)
        startOperations[serviceType] = operation
        return try await awaitStartOperation(operation, serviceType: serviceType)
    }

    private func awaitStartOperation(
        _ operation: StartOperation,
        serviceType: String
    ) async throws -> UInt16 {
        do {
            let port = try await operation.task.value
            finishStartOperation(serviceType: serviceType, token: operation.token)
            return port
        } catch {
            finishStartOperation(serviceType: serviceType, token: operation.token)
            throw error
        }
    }

    private func performStart(
        serviceName: String,
        serviceType: String,
        owner: String?,
        token: UUID,
        includePeerToPeer: Bool,
        connectionHandler: (@Sendable (NWConnection) -> Void)?,
        stateHandler: (@Sendable (NWListener.State) -> Void)?,
        readinessHandler: (@Sendable (Bool) -> Void)?
    ) async throws -> UInt16 {
        // Identity resolution may suspend. The start-operation token makes stop,
        // restart and same-service concurrency observable across that suspension.
        let finalTXT = try await makeDefaultTXTRecord()
        try Task.checkCancellation()
        guard startOperations[serviceType]?.token == token else {
            throw POSIXError(.ECANCELED)
        }

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = includePeerToPeer
        parameters.allowLocalEndpointReuse = true
        if let tcpOptions = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcpOptions.enableKeepalive = true
            tcpOptions.keepaliveIdle = 30
            tcpOptions.keepaliveInterval = 15
            tcpOptions.keepaliveCount = 4
        }

        // `_skybridge._tcp` 通过 Bonjour 服务名与 TXT 记录暴露控制面能力；
        // 固定绑定 9527 在实际设备上容易因旧实例/系统残留占用而异步失败。
        // 这里统一使用系统分配端口，避免启动期 address-in-use 抖动。
        let listener = try NWListener(using: parameters)

        // The service type and SRV record own capabilities and ports. Keep TXT
        // limited to the canonical discovery identity so AWDL advertisements stay
        // well below the platform's 200-byte interoperability recommendation.
        let service = NWListener.Service(name: serviceName, type: serviceType, domain: "local.", txtRecord: finalTXT)
        listener.service = service
        listener.newConnectionHandler = { [weak listener] connection in
            guard let listener else {
                connection.cancel()
                return
            }
            Task {
                await self.handleNewConnection(
                    serviceType: serviceType,
                    token: token,
                    listener: listener,
                    connection: connection
                )
            }
        }
        let log = self.logger
        let resolvedServiceType = serviceType
        listener.stateUpdateHandler = { [weak listener] state in
            guard let listener else { return }
            let actualPort = listener.port?.rawValue
            if case .failed(let error) = state {
                log.error("❌ 广播监听失败: \(error.localizedDescription, privacy: .public)")
            }
            Task {
                await self.handleListenerStateUpdate(
                    serviceType: resolvedServiceType,
                    token: token,
                    state: state,
                    port: actualPort
                )
            }
        }
        listener.serviceRegistrationUpdateHandler = { change in
            Task {
                await self.handleServiceRegistrationUpdate(
                    serviceType: resolvedServiceType,
                    token: token,
                    change: change
                )
            }
        }
        guard startOperations[serviceType]?.token == token,
              !Task.isCancelled else {
            Self.cancelListener(listener)
            throw POSIXError(.ECANCELED)
        }
        records[serviceType] = ListenerRecord(
            listener: listener,
            owner: owner,
            token: token,
            readinessGate: BonjourRegistrationReadinessGate(),
            connectionHandler: connectionHandler,
            stateHandler: stateHandler,
            readinessHandler: readinessHandler,
            state: .starting,
            port: nil,
            registrationEndpoints: []
        )
        listener.start(queue: .global(qos: .utility))
        let readyPort = try await waitForAdvertisingReady(
            serviceType: serviceType,
            token: token,
            cancelRecordOnFailure: true
        )
        logger.info("📡 广播服务已就绪: \(serviceType, privacy: .public) 端口 \(readyPort, privacy: .public) peerToPeer=\(includePeerToPeer, privacy: .public)")
        return readyPort
    }

 /// 仅在未运行时启动指定服务类型的广播，避免重复启动造成的 stop→start 风暴
    public func startAdvertisingIfNeeded(
        serviceName: String,
        serviceType: String,
        owner: String? = nil,
        includePeerToPeer: Bool = true,
        connectionHandler: (@Sendable (NWConnection) -> Void)? = nil,
        stateHandler: (@Sendable (NWListener.State) -> Void)? = nil,
        readinessHandler: (@Sendable (Bool) -> Void)? = nil
    ) async throws -> UInt16 {
        if let operation = startOperations[serviceType] {
            try validateOwner(
                serviceType: serviceType,
                current: operation.owner,
                requested: owner
            )
            return try await awaitStartOperation(operation, serviceType: serviceType)
        }
        if let record = records[serviceType] {
            try validateOwner(
                serviceType: serviceType,
                current: record.owner,
                requested: owner
            )
            if record.state == .ready,
               let port = record.port ?? record.listener.port?.rawValue,
               port > 0 {
                return port
            }
            return try await waitForAdvertisingReady(
                serviceType: serviceType,
                token: record.token
            )
        }
        return try await startAdvertising(
            serviceName: serviceName,
            serviceType: serviceType,
            owner: owner,
            includePeerToPeer: includePeerToPeer,
            connectionHandler: connectionHandler,
            stateHandler: stateHandler,
            readinessHandler: readinessHandler
        )
    }

    private func makeDefaultTXTRecord() async throws -> NWTXTRecord {
        let identity = try await CanonicalBonjourAdvertisementIdentityProvider.current(
            allowCreateDeviceId: true
        )
        return try BonjourInteropContract.makeCanonicalAdvertisementTXT(
            deviceId: identity.deviceId,
            pubKeyFingerprint: identity.protocolPublicKeyFingerprint,
            platform: .macOS,
            role: .control
        )
    }

 /// 查询指定服务类型是否正在广播
    public func isAdvertising(_ serviceType: String) -> Bool {
        return records[serviceType] != nil
    }

    public func advertisementSnapshot(for serviceType: String) -> ServiceAdvertisementSnapshot {
        guard let record = records[serviceType] else {
            return ServiceAdvertisementSnapshot(serviceType: serviceType)
        }
        return ServiceAdvertisementSnapshot(
            serviceType: serviceType,
            owner: record.owner,
            port: record.port ?? record.listener.port?.rawValue,
            state: record.state
        )
    }

    public func waitUntilReady(
        _ serviceType: String,
        timeout: Duration = .seconds(8)
    ) async throws -> UInt16 {
        guard let record = records[serviceType] else {
            throw AdvertisingError.listenerEndedBeforeReady
        }
        return try await waitForAdvertisingReady(
            serviceType: serviceType,
            token: record.token,
            timeout: timeout
        )
    }

 /// 停止指定服务类型的广播
    public func stopAdvertising(_ serviceType: String, owner: String? = nil) {
        let currentOwner = records[serviceType]?.owner ?? startOperations[serviceType]?.owner
        guard records[serviceType] != nil || startOperations[serviceType] != nil else { return }
        if let owner, currentOwner != owner {
            logger.warning(
                "⚠️ 忽略非 owner 停止广播请求: service=\(serviceType, privacy: .public) owner=\(owner, privacy: .public) current=\(currentOwner ?? "-", privacy: .public)"
            )
            return
        }
        startOperations.removeValue(forKey: serviceType)?.task.cancel()
        if let record = records.removeValue(forKey: serviceType) {
            record.readinessHandler?(false)
            Self.cancelListener(record.listener)
        }
        logger.info("⏹️ 停止广播: \(serviceType, privacy: .public)")
    }

 /// 停止所有广播
    public func stopAll() {
        for operation in startOperations.values { operation.task.cancel() }
        startOperations.removeAll()
        for (_, record) in records {
            record.readinessHandler?(false)
            Self.cancelListener(record.listener)
        }
        records.removeAll()
        logger.info("⏹️ 停止所有广播")
    }

    private func handleListenerStateUpdate(
        serviceType: String,
        token: UUID,
        state: NWListener.State,
        port: UInt16?
    ) {
        guard var record = records[serviceType], record.token == token else { return }
        switch state {
        case .ready:
            if let port, port > 0 {
                record.port = port
            }
            let observation = record.readinessGate.observeSocketReady()
            let becameReady = (observation == .completesStartup
                    || observation == .runtimeReady)
                && (record.port ?? 0) > 0
            if becameReady {
                record.state = .ready
            }
            records[serviceType] = record
            if becameReady {
                record.readinessHandler?(true)
                record.stateHandler?(.ready)
            }
        case .waiting(let error):
            _ = record.readinessGate.observeSocketUnavailable()
            record.state = .starting
            records[serviceType] = record
            record.readinessHandler?(false)
            record.stateHandler?(.waiting(error))
        case .failed, .cancelled:
            _ = record.readinessGate.observeTerminal()
            records.removeValue(forKey: serviceType)
            record.readinessHandler?(false)
            record.stateHandler?(state)
            if case .failed = state {
                Self.cancelListener(record.listener)
            } else {
                Self.clearListenerHandlers(record.listener)
            }
        case .setup:
            record.stateHandler?(state)
        @unknown default:
            _ = record.readinessGate.observeTerminal()
            records.removeValue(forKey: serviceType)
            record.readinessHandler?(false)
            Self.cancelListener(record.listener)
        }
    }

    private func handleServiceRegistrationUpdate(
        serviceType: String,
        token: UUID,
        change: NWListener.ServiceRegistrationChange
    ) {
        guard var record = records[serviceType], record.token == token else { return }
        switch change {
        case .add(let endpoint):
            record.registrationEndpoints.insert(endpoint)
            let observation = record.readinessGate.observeRegistrationAdded(
                endpoint.debugDescription
            )
            if (observation == .completesStartup || observation == .runtimeReady),
               (record.port ?? 0) > 0 {
                record.state = .ready
            }
        case .remove(let endpoint):
            record.registrationEndpoints.remove(endpoint)
            let observation = record.readinessGate.observeRegistrationRemoved(
                endpoint.debugDescription
            )
            if observation == .runtimeDegraded {
                record.state = .starting
            }
        @unknown default:
            logger.error(
                "Unsupported Bonjour registration change: service=\(serviceType, privacy: .public)"
            )
            return
        }

        let becameReady = record.state == .ready
            && records[serviceType]?.state != .ready
        if record.registrationEndpoints.isEmpty {
            record.state = .starting
        }
        records[serviceType] = record

        if becameReady {
            logger.info(
                "📡 Bonjour registration confirmed: service=\(serviceType, privacy: .public) registrations=\(record.registrationEndpoints.count, privacy: .public)"
            )
            record.readinessHandler?(true)
            record.stateHandler?(.ready)
        } else if record.registrationEndpoints.isEmpty {
            logger.warning(
                "⚠️ Bonjour registration removed: service=\(serviceType, privacy: .public)"
            )
            record.readinessHandler?(false)
        }
    }

    private func handleNewConnection(
        serviceType: String,
        token: UUID,
        listener: NWListener,
        connection: NWConnection
    ) {
        guard let record = records[serviceType],
              record.token == token,
              record.listener === listener,
              record.state == .ready,
              let connectionHandler = record.connectionHandler else {
            connection.cancel()
            return
        }
        connectionHandler(connection)
    }

    private func waitForAdvertisingReady(
        serviceType: String,
        token: UUID,
        timeout: Duration = .seconds(8),
        cancelRecordOnFailure: Bool = false
    ) async throws -> UInt16 {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while clock.now < deadline {
            guard let record = records[serviceType], record.token == token else {
                throw AdvertisingError.listenerEndedBeforeReady
            }
            if record.state == .ready,
               let port = record.port ?? record.listener.port?.rawValue,
               port > 0 {
                return port
            }
            do {
                try await Task.sleep(for: .milliseconds(25))
            } catch {
                if cancelRecordOnFailure {
                    cancelRecord(serviceType: serviceType, token: token)
                }
                throw error
            }
        }

        if cancelRecordOnFailure {
            cancelRecord(serviceType: serviceType, token: token)
        }
        throw AdvertisingError.timedOut
    }

    private func cancelRecord(serviceType: String, token: UUID) {
        guard let record = records[serviceType], record.token == token else { return }
        _ = record.readinessGate.claimTimeout()
        record.readinessHandler?(false)
        Self.cancelListener(record.listener)
        records.removeValue(forKey: serviceType)
    }

    private func finishStartOperation(serviceType: String, token: UUID) {
        guard startOperations[serviceType]?.token == token else { return }
        startOperations.removeValue(forKey: serviceType)
    }

    private func validateOwner(
        serviceType: String,
        current: String?,
        requested: String?
    ) throws {
        guard current == requested else {
            throw AdvertisingError.ownerConflict(
                serviceType: serviceType,
                current: current,
                requested: requested
            )
        }
    }

    private nonisolated static func clearListenerHandlers(_ listener: NWListener) {
        listener.stateUpdateHandler = nil
        listener.serviceRegistrationUpdateHandler = nil
        listener.newConnectionHandler = nil
    }

    private nonisolated static func cancelListener(_ listener: NWListener) {
        clearListenerHandlers(listener)
        listener.cancel()
    }
}
