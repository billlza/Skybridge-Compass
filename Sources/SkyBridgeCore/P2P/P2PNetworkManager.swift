import Foundation
import Network
import Combine
import os

/// P2P网络管理器 - 统一管理设备发现、连接建立和状态监控
@MainActor
public class P2PNetworkManager: ObservableObject, Sendable {
    private static let maximumConcurrentConnectionAttempts = 8
    private static let maximumActiveConnections = 32
    private final class ConnectionReadinessContext: @unchecked Sendable {
        private struct State {
            var didResume = false
            var timeoutTask: Task<Void, Never>?
        }

        private let state = OSAllocatedUnfairLock(initialState: State())
        private let continuation: CheckedContinuation<Void, Error>

        init(continuation: CheckedContinuation<Void, Error>) {
            self.continuation = continuation
        }

        func installTimeoutTask(_ task: Task<Void, Never>) {
            let shouldCancel = state.withLock { state -> Bool in
                guard !state.didResume else { return true }
                state.timeoutTask = task
                return false
            }
            if shouldCancel {
                task.cancel()
            }
        }

        func complete(
            _ result: Result<Void, Error>,
            beforeResume: () -> Void = {}
        ) {
            let completion = state.withLock { state -> (Bool, Task<Void, Never>?) in
                guard !state.didResume else { return (false, nil) }
                state.didResume = true
                defer { state.timeoutTask = nil }
                return (true, state.timeoutTask)
            }
            guard completion.0 else { return }
            completion.1?.cancel()
            beforeResume()
            switch result {
            case .success:
                continuation.resume()
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
    }

    private final class ConnectionReadinessCancellationHandle: @unchecked Sendable {
        private struct State {
            var context: ConnectionReadinessContext?
            var cancelled = false
        }

        private let state = OSAllocatedUnfairLock(initialState: State())

        func install(_ context: ConnectionReadinessContext) {
            let wasCancelled = state.withLock { state -> Bool in
                state.context = context
                return state.cancelled
            }
            if wasCancelled {
                context.complete(.failure(CancellationError()))
            }
        }

        func cancel(connection: NWConnection) {
            let context = state.withLock { state -> ConnectionReadinessContext? in
                state.cancelled = true
                return state.context
            }
            connection.stateUpdateHandler = nil
            connection.cancel()
            context?.complete(.failure(CancellationError()))
        }
    }
    
 // MARK: - 单例
    
    public static let shared = P2PNetworkManager()
    
 // MARK: - 发布属性
    
    @Published public var discoveredDevices: [P2PDevice] = []
    @Published public var activeConnections: [String: P2PConnection] = [:]
    @Published public var connectionHistory: [P2PDevice] = []
    @Published public var networkState: P2PNetworkState = .disconnected
    @Published public var networkQuality: P2PConnectionQuality = P2PConnectionQuality(
        latency: 0.0,
        packetLoss: 0.0,
        bandwidth: 0,
        stabilityScore: 0
    )
 /// 已发布“可连接设备”提醒的时间戳（用于限频与去重）
    private var connectableNotifyTimestamps: [String: Date] = [:]
    @Published public private(set) var isStarted: Bool = false
    
 // MARK: - 私有属性
    
    private let discoveryService: P2PDiscoveryService
    private var p2pNetworkCancellables = Set<AnyCancellable>()
    private var connectionStatusSubscriptions: [ObjectIdentifier: AnyCancellable] = [:]
    private var connectionAttempts: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    private var wifiAwareStartTask: Task<Void, Never>?
    private let startupLifecycle = P2PStartupLifecycle()
    private var discoveryTimer: Timer?
    private var qualityMonitorTimer: Timer?
    private var localProtocolDeviceId: String?
    private var pendingLocalProtocolDeviceId: String?
    
 // MARK: - 初始化
    
    private init() {
        self.discoveryService = P2PDiscoveryService.shared
        startQualityMonitoring()
    }
    
 // MARK: - 生命周期管理
    
 /// 启动P2P网络管理器
    public func start() async throws {
        try await startupLifecycle.ensureStarted(
            operation: { [weak self] in
                guard let self else { throw CancellationError() }

                let rawLocalDeviceId = try await SelfIdentityProvider.shared
                    .protocolIdentityDeviceId(allowCreate: true)
                let normalizedLocalDeviceId = rawLocalDeviceId
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                guard !normalizedLocalDeviceId.isEmpty else {
                    throw P2PConnectionError.disconnected
                }
                self.pendingLocalProtocolDeviceId = normalizedLocalDeviceId

                // This is the sole managed discovery startup path. It returns
                // only after browsing and the connectable control advertisement
                // are both ready, and propagates every startup failure.
                try await self.discoveryService.ensureStartedAndScanning()
                try Task.checkCancellation()
            },
            commit: { [self] in
                self.localProtocolDeviceId = self.pendingLocalProtocolDeviceId
                self.pendingLocalProtocolDeviceId = nil
                self.isStarted = true
                self.activateDiscoveryObservation()
            },
            rollback: { [weak self] in
                await self?.rollbackFailedStartup()
            }
        )
    }
    
 /// 停止P2P网络管理器
    public func stop() async {
        let startupError = await startupLifecycle.stop(
            willStop: { [weak self] in
                self?.isStarted = false
                self?.pendingLocalProtocolDeviceId = nil
            },
            operation: { [weak self] in
                await self?.performStop()
            }
        )
        if let startupError {
            SkyBridgeLogger.p2p.error(
                "P2P manager startup failed while stop completed cleanup: \(startupError.localizedDescription, privacy: .private)"
            )
        }
    }

    private func performStop() async {
        stopDiscovery()

        let wifiAwareTask = wifiAwareStartTask
        wifiAwareStartTask = nil
        wifiAwareTask?.cancel()
        if let wifiAwareTask {
            await wifiAwareTask.value
        }

        let attempts = Array(connectionAttempts.values)
        connectionAttempts.removeAll()
        attempts.forEach { $0.task.cancel() }
        for attempt in attempts {
            await attempt.task.value
        }
        
 // 断开所有连接
        for deviceId in Array(activeConnections.keys) {
            disconnectFromDevice(deviceId)
        }
    }

    private func rollbackFailedStartup() async {
        pendingLocalProtocolDeviceId = nil
        isStarted = false
        stopDiscovery()

        let wifiAwareTask = wifiAwareStartTask
        wifiAwareStartTask = nil
        wifiAwareTask?.cancel()
        if let wifiAwareTask {
            await wifiAwareTask.value
        }
    }
    
 /// 清理P2P网络管理器资源
    public func cleanup() async {
        await stop()
        
 // 清理定时器
        discoveryTimer?.invalidate()
        discoveryTimer = nil
        qualityMonitorTimer?.invalidate()
        qualityMonitorTimer = nil
        
 // 清理订阅
        p2pNetworkCancellables.removeAll()
        connectionStatusSubscriptions.values.forEach { $0.cancel() }
        connectionStatusSubscriptions.removeAll()
        
 // 清理数据
        discoveredDevices.removeAll()
        activeConnections.removeAll()
        connectionHistory.removeAll()
        localProtocolDeviceId = nil
    }
    
 // MARK: - 设备发现
    
 /// 开始设备发现
    public func startDiscovery() async {
        guard isStarted else { return }

        discoveryService.startBrowsing()
        activateDiscoveryObservation()
    }

    private func activateDiscoveryObservation() {
        guard isStarted else { return }

        networkState = .discovering
        #if canImport(WiFiAware)
        wifiAwareStartTask?.cancel()
        wifiAwareStartTask = Task { @MainActor in
            do {
                try await P2PConnectionService.shared.start(role: .publisher)
            } catch is CancellationError {
                return
            } catch {
                SkyBridgeLogger.p2p.error("Wi-Fi Aware publisher start failed: \(error.localizedDescription, privacy: .private)")
            }
        }
        #endif

 // 监听发现的设备
        p2pNetworkCancellables.removeAll()
        discoveryService.$p2pDevices
            .receive(on: DispatchQueue.main)
            .sink { [weak self] devices in
                guard let self = self else { return }
                self.discoveredDevices = devices
                self.publishConnectableDeviceEvents(devices)
            }
            .store(in: &p2pNetworkCancellables)
        
        startDiscoveryTimer()
    }

 /// 发布“可连接设备”通知事件（通过NotificationCenter），供UI层监听
    private func publishConnectableDeviceEvents(_ devices: [P2PDevice]) {
        let now = Date()
 // 本机协议身份用于发布通知前做二次自过滤。名称和 IP 都不是身份；
 // 同名设备及共享/碰撞地址必须保留。
 // 清理超过1小时的记录
        connectableNotifyTimestamps = connectableNotifyTimestamps.filter { now.timeIntervalSince($0.value) < 3600 }
        for d in devices {
            if Self.shouldSuppressConnectableNotification(
                for: d,
                localProtocolDeviceId: localProtocolDeviceId
            ) {
                SkyBridgeLogger.p2p.debugOnly("🛑 跳过发布‘可连接设备’通知（本机过滤）: \(d.name) @ \(d.address)")
                continue
            }
            let isOnline = d.isOnline
            let isConnected = activeConnections[d.deviceId] != nil
            let hasTCPDialRoute = !d.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && d.port > 0
            if isOnline && hasTCPDialRoute && !isConnected && connectableNotifyTimestamps[d.deviceId] == nil {
                connectableNotifyTimestamps[d.deviceId] = now
                NotificationCenter.default.post(name: Notification.Name("ConnectableDeviceDiscovered"), object: nil, userInfo: [
                    "deviceId": d.deviceId,
                    "name": d.name,
                    "address": d.address,
                    "port": d.port,
                    "isVerified": d.isVerified,
                    "verificationFailedReason": d.verificationFailedReason ?? ""
                ])
            }
        }
    }

    nonisolated static func shouldSuppressConnectableNotification(
        for device: P2PDevice,
        localProtocolDeviceId: String?
    ) -> Bool {
        let localId = localProtocolDeviceId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let remoteIds = ([device.deviceId] + [device.persistentDeviceId].compactMap { $0 })
            .compactMap { value -> String? in
                let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return normalized.isEmpty ? nil : normalized
            }
        return localId.map { !($0.isEmpty) && remoteIds.contains($0) } ?? false
    }
    
 /// 停止设备发现
    public func stopDiscovery() {
        discoveryService.stopScanning()
        p2pNetworkCancellables.removeAll()
        stopDiscoveryTimer()
        networkState = .disconnected
    }
    
 /// 刷新设备发现
    public func refreshDiscovery() async {
        // Avoid hard stop/start:
        // - It interrupts ongoing handshakes/transfers
        // - It triggers NWBrowser cancelled/ready churn ("not in ready or waiting state")
        // - It makes peers "disappear" briefly, causing UI flapping
        await discoveryService.refreshDevices()
    }
    
 // MARK: - 连接管理
    
 /// 连接到设备
    public func connectToDevice(_ device: P2PDevice,
                               connectionEstablished: @escaping () -> Void,
                               connectionFailed: @escaping (Error) -> Void) {
        guard isStarted else {
            connectionFailed(P2PConnectionError.disconnected)
            return
        }
        guard activeConnections[device.deviceId] != nil
                || activeConnections.count < Self.maximumActiveConnections else {
            connectionFailed(
                P2PConnectionError.capacityExceeded(
                    resource: "active connections",
                    limit: Self.maximumActiveConnections
                )
            )
            return
        }
        guard connectionAttempts[device.deviceId] != nil
                || connectionAttempts.count < Self.maximumConcurrentConnectionAttempts else {
            connectionFailed(
                P2PConnectionError.capacityExceeded(
                    resource: "connection attempts",
                    limit: Self.maximumConcurrentConnectionAttempts
                )
            )
            return
        }
        SkyBridgeLogger.p2p.debugOnly("🔗 尝试连接到设备: \(device.name)")
        
        networkState = .connecting
        
        let deviceCopy = device
        let attemptID = UUID()
        connectionAttempts[deviceCopy.deviceId]?.task.cancel()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            var attemptedConnection: P2PConnection?
            do {
                let connection = try await establishConnection(to: deviceCopy)
                attemptedConnection = connection
                try await connection.authenticate()
                try Task.checkCancellation()
                guard self.connectionAttempts[deviceCopy.deviceId]?.id == attemptID,
                      self.isStarted else {
                    connection.disconnect()
                    return
                }
                self.activeConnections[deviceCopy.deviceId] = connection
                self.monitorConnection(connection)
                self.addToHistory(deviceCopy)
                self.networkState = .connected
                self.connectionAttempts.removeValue(forKey: deviceCopy.deviceId)
                connectionEstablished()
            } catch {
                if let attemptedConnection {
                    attemptedConnection.disconnect()
                    self.removeActiveConnection(attemptedConnection)
                }
                let isCurrentAttempt = self.connectionAttempts[deviceCopy.deviceId]?.id == attemptID
                if isCurrentAttempt {
                    self.connectionAttempts.removeValue(forKey: deviceCopy.deviceId)
                }
                if self.activeConnections.isEmpty && self.connectionAttempts.isEmpty {
                    self.networkState = .disconnected
                } else if !self.activeConnections.isEmpty {
                    self.networkState = .connected
                }
                if isCurrentAttempt, !(error is CancellationError) {
                    connectionFailed(error)
                }
            }
        }
        connectionAttempts[deviceCopy.deviceId] = (attemptID, task)
    }
    
    /// 断开设备连接
    public func disconnectFromDevice(_ deviceId: String) {
        connectionAttempts.removeValue(forKey: deviceId)?.task.cancel()
        guard let connection = activeConnections[deviceId]
                ?? activeConnections.first(where: { entry in
                    let key = entry.key
                    let connection = entry.value
                    let targetAliases = Set(PeerTrustLookup.lookupCandidates(for: deviceId))
                    let connectionAliases = Set(
                        PeerTrustLookup.lookupCandidates(primary: connection.device.deviceId, persistent: connection.device.persistentDeviceId)
                    )
                    return key == deviceId || !targetAliases.isDisjoint(with: connectionAliases)
                })?.value else {
            if activeConnections.isEmpty && connectionAttempts.isEmpty {
                networkState = .disconnected
            }
            return
        }
        
 // 关闭连接
        connection.disconnect()
        
 // 移除活跃连接
        removeActiveConnection(connection, additionalKeys: [deviceId])
        
 // 更新网络状态
        if activeConnections.isEmpty {
            networkState = .disconnected
        }
    }

    private func establishConnection(to device: P2PDevice) async throws -> P2PConnection {
        guard !device.address.isEmpty else {
            throw P2PConnectionError.disconnected
        }
        guard let port = NWEndpoint.Port(rawValue: device.port) else {
            throw P2PConnectionError.disconnected
        }

        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(device.address), port: port)
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        parameters.allowLocalEndpointReuse = true
        if let tcpOptions = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcpOptions.enableKeepalive = true
            tcpOptions.keepaliveIdle = 30
            tcpOptions.keepaliveInterval = 15
            tcpOptions.keepaliveCount = 4
            tcpOptions.noDelay = true
        }

        let nw = NWConnection(to: endpoint, using: parameters)
        let p2p = P2PConnection(device: device, connection: nw)

        try await waitUntilReady(nw, updating: p2p, timeoutSeconds: 10)
        return p2p
    }

    private func waitUntilReady(_ connection: NWConnection, updating p2p: P2PConnection, timeoutSeconds: Double) async throws {
        let cancellationHandle = ConnectionReadinessCancellationHandle()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let context = ConnectionReadinessContext(continuation: continuation)
                cancellationHandle.install(context)

                connection.stateUpdateHandler = { [weak connection, weak p2p] state in
                    guard let connection else {
                        context.complete(.failure(P2PConnectionError.disconnected))
                        return
                    }
                    Task { @MainActor [weak connection, weak p2p] in
                        guard let connection else {
                            context.complete(.failure(P2PConnectionError.disconnected))
                            return
                        }
                        switch state {
                        case .ready:
                            connection.stateUpdateHandler = nil
                            context.complete(.success(())) {
                                p2p?.markTransportReady()
                            }

                        case .failed(let error):
                            connection.stateUpdateHandler = nil
                            p2p?.disconnect()
                            context.complete(.failure(error))

                        case .cancelled:
                            connection.stateUpdateHandler = nil
                            p2p?.disconnect()
                            context.complete(.failure(P2PConnectionError.disconnected))

                        default:
                            break
                        }
                    }
                }

                guard !Task.isCancelled else {
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    context.complete(.failure(CancellationError()))
                    return
                }

                let queue = DispatchQueue(label: "com.skybridge.p2p.networkmanager.connection", qos: .userInitiated)
                connection.start(queue: queue)

                let timeoutTask = Task {
                    do {
                        try await Task.sleep(for: .seconds(timeoutSeconds))
                    } catch {
                        return
                    }
                    if connection.state != .ready && connection.state != .cancelled {
                        connection.stateUpdateHandler = nil
                        connection.cancel()
                        context.complete(.failure(P2PConnectionError.disconnected))
                    }
                }
                context.installTimeoutTask(timeoutTask)
            }
        } onCancel: {
            cancellationHandle.cancel(connection: connection)
        }
    }
    
 /// 检查是否已连接到设备
    public func isConnected(to deviceId: String) -> Bool {
        return activeConnections[deviceId] != nil
    }
    
 // MARK: - 私有方法
    
    private func startDiscoveryTimer() {
        discoveryTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // If we have any active secure session, do not refresh discovery (keeps presence stable).
                if !self.activeConnections.isEmpty { return }
                await self.refreshDiscovery()
            }
        }
    }
    
    private func stopDiscoveryTimer() {
        discoveryTimer?.invalidate()
        discoveryTimer = nil
    }

    private func startQualityMonitoring() {
        qualityMonitorTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task {
                await self?.updateNetworkQuality()
            }
        }
    }
    
    private func updateNetworkQuality() async {
        guard !activeConnections.isEmpty else {
            networkQuality = P2PConnectionQuality(
                latency: 0.0,
                packetLoss: 0.0,
                bandwidth: 0,
                stabilityScore: 0
            )
            return
        }
        
 // 计算平均网络质量
        let connections = Array(activeConnections.values)
        let avgLatency = connections.map { $0.quality.latency }.reduce(0, +) / Double(connections.count)
        let avgBandwidth = connections.map { Double($0.quality.bandwidth) }.reduce(0, +) / Double(connections.count)
        let avgPacketLoss = connections.map { $0.quality.packetLoss }.reduce(0, +) / Double(connections.count)
        
 // 计算稳定性评分
        let stabilityScore: Int
        if avgLatency < 0.05 && avgPacketLoss < 0.01 {
            stabilityScore = 90
        } else if avgLatency < 0.1 && avgPacketLoss < 0.03 {
            stabilityScore = 70
        } else if avgLatency < 0.2 && avgPacketLoss < 0.05 {
            stabilityScore = 50
        } else {
            stabilityScore = 20
        }
        
        networkQuality = P2PConnectionQuality(
            latency: avgLatency,
            packetLoss: avgPacketLoss,
            bandwidth: UInt64(avgBandwidth),
            stabilityScore: stabilityScore
        )
    }
    
    private func monitorConnection(_ connection: P2PConnection) {
 // 监听连接状态变化
        let identifier = ObjectIdentifier(connection)
        connectionStatusSubscriptions[identifier]?.cancel()
        connectionStatusSubscriptions[identifier] = connection.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.handleConnectionStatusChange(connection, status: status)
            }
    }
    
    private func handleConnectionStatusChange(_ connection: P2PConnection, status: P2PConnectionStatus) {
        guard activeConnections.values.contains(where: { $0 === connection }) else {
            connectionStatusSubscriptions.removeValue(forKey: ObjectIdentifier(connection))?.cancel()
            return
        }
        switch status {
        case .connected, .authenticated:
            networkState = .connected
        case .disconnected, .failed:
 // 连接断开，从活跃连接中移除
            removeActiveConnection(connection)
            
 // 如果没有活跃连接，更新网络状态
            if activeConnections.isEmpty {
                networkState = .disconnected
            }
            
        default:
            break
        }
    }

    private func removeActiveConnection(_ connection: P2PConnection, additionalKeys: [String] = []) {
        _ = additionalKeys
        for key in Array(activeConnections.keys) {
            guard let stored = activeConnections[key] else { continue }
            if stored === connection {
                activeConnections.removeValue(forKey: key)
            }
        }
        connectionStatusSubscriptions.removeValue(forKey: ObjectIdentifier(connection))?.cancel()
    }
    
    private func addToHistory(_ device: P2PDevice) {
 // 移除已存在的记录
        connectionHistory.removeAll { $0.deviceId == device.deviceId }
        
 // 添加到历史记录开头
        connectionHistory.insert(device, at: 0)
        
 // 限制历史记录数量
        if connectionHistory.count > 20 {
            connectionHistory = Array(connectionHistory.prefix(20))
        }
    }
    
 // MARK: - 清理
    
    deinit {
 // 在deinit中不能访问非Sendable属性
 // Timer清理将由系统自动处理
    }
}

// MARK: - 网络状态和质量管理
// 注意：P2PNetworkState 和 P2PConnectionQuality 已在 P2PNetworkTypes.swift 中定义

// MARK: - 扩展方法

extension P2PNetworkManager {
    
 /// 获取设备连接统计信息
    public var connectionStats: ConnectionStats {
        ConnectionStats(
            discoveredDevicesCount: discoveredDevices.count,
            activeConnectionsCount: activeConnections.count,
            historyConnectionsCount: connectionHistory.count,
            averageLatency: networkQuality.latency,
            totalBandwidth: Double(networkQuality.bandwidth)
        )
    }
    
 /// 连接统计信息结构
    public struct ConnectionStats {
        public let discoveredDevicesCount: Int
        public let activeConnectionsCount: Int
        public let historyConnectionsCount: Int
        public let averageLatency: Double
        public let totalBandwidth: Double
    }
}

// MARK: - 模拟数据扩展

#if DEBUG || SKYBRIDGE_TESTING
extension P2PNetworkManager {
    
 /// 添加模拟设备用于测试
    public func addMockDevices() {
        let mockDevices = [
            P2PDevice(
                id: "mock-mac-1",
                name: "MacBook Pro",
                type: .macOS,
                address: "192.168.1.100",
                port: 8080,
                osVersion: "macOS 14.0",
                capabilities: ["remote_desktop", "file_transfer", "screen_sharing"],
                publicKey: Data(),
                lastSeen: Date(),
                endpoints: ["192.168.1.100:8080"]
            ),
            P2PDevice(
                id: "mock-iphone-1",
                name: "iPhone 15 Pro",
                type: .iOS,
                address: "192.168.1.101",
                port: 8081,
                osVersion: "iOS 17.0",
                capabilities: ["remote_desktop", "file_transfer"],
                publicKey: Data(),
                lastSeen: Date().addingTimeInterval(-300),
                endpoints: ["192.168.1.101:8081"]
            ),
            P2PDevice(
                id: "mock-windows-1",
                name: "Windows PC",
                type: .windows,
                address: "192.168.1.102",
                port: 8082,
                osVersion: "Windows 11",
                capabilities: ["remote_desktop", "file_transfer"],
                publicKey: Data(),
                lastSeen: Date().addingTimeInterval(-600),
                endpoints: ["192.168.1.102:8082"]
            )
        ]
        
        discoveredDevices = mockDevices
    }
}
#endif
