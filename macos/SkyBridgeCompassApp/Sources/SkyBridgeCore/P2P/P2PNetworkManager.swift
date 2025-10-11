import Foundation
import Network
import Combine

/// P2P网络管理器 - 统一管理设备发现、连接建立和状态监控
@MainActor
public class P2PNetworkManager: ObservableObject {
    
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
    
    // MARK: - 私有属性
    
    private let discoveryService: P2PDiscoveryService
    private let networkLayer: P2PNetworkLayer
    private let securityManager: P2PSecurityManager
    private var cancellables = Set<AnyCancellable>()
    private var discoveryTimer: Timer?
    private var qualityMonitorTimer: Timer?
    
    // MARK: - 初始化
    
    private init() {
        self.discoveryService = P2PDiscoveryService()
        self.networkLayer = P2PNetworkLayer()
        self.securityManager = P2PSecurityManager()
        
        setupBindings()
        startQualityMonitoring()
    }
    
    // MARK: - 设备发现
    
    /// 开始设备发现
    public func startDiscovery() async {
        networkState = .discovering
        
        do {
            _ = try await discoveryService.startDiscovery()
            
            // 监听发现的设备
            discoveryService.$discoveredDevices
                .receive(on: DispatchQueue.main)
                .sink { [weak self] devices in
                    self?.discoveredDevices = devices
                }
                .store(in: &cancellables)
                
            // 启动定期刷新
            startDiscoveryTimer()
            
        } catch {
            print("启动设备发现失败: \(error)")
            networkState = .disconnected
        }
    }
    
    /// 停止设备发现
    public func stopDiscovery() {
        discoveryService.stopDiscovery()
        stopDiscoveryTimer()
        networkState = .disconnected
    }
    
    /// 刷新设备发现
    public func refreshDiscovery() async {
        await discoveryService.refreshDevices()
    }
    
    // MARK: - 连接管理
    
    /// 连接到设备
    public func connectToDevice(_ device: P2PDevice,
                               connectionEstablished: @escaping () -> Void,
                               connectionFailed: @escaping (Error) -> Void) {
        print("🔗 尝试连接到设备: \(device.name)")
        
        networkState = .connecting
        
        // 建立连接
        networkLayer.connectToDevice(device) { [weak self] connection in
            guard let _ = self else { return }
            
            // 认证连接
            Task {
                do {
                    try await connection.authenticate()
                    connectionEstablished()
                } catch {
                    connectionFailed(error)
                }
            }
        } connectionFailed: { deviceId, error in
            connectionFailed(error)
        }
    }
    
    /// 断开设备连接
    public func disconnectFromDevice(_ deviceId: String) {
        guard let connection = activeConnections[deviceId] else { return }
        
        // 关闭连接
        networkLayer.closeConnection(connection)
        
        // 移除活跃连接
        activeConnections.removeValue(forKey: deviceId)
        
        // 更新网络状态
        if activeConnections.isEmpty {
            networkState = .disconnected
        }
    }
    
    /// 检查是否已连接到设备
    public func isConnected(to deviceId: String) -> Bool {
        return activeConnections[deviceId] != nil
    }
    
    // MARK: - 私有方法
    
    private func setupBindings() {
        // 监听网络层状态变化
        networkLayer.connectionStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.handleNetworkStateChange(state)
            }
            .store(in: &cancellables)
    }
    
    private func handleNetworkStateChange(_ state: P2PConnectionStatus) {
        switch state {
        case .connected:
            networkState = .connected
        case .connecting:
            networkState = .connecting
        case .disconnected, .failed:
            networkState = .disconnected
        case .listening:
            networkState = .discovering
        case .authenticating, .authenticated, .networkUnavailable:
            // 这些状态不直接映射到网络状态，保持当前状态
            break
        }
    }
    
    private func startDiscoveryTimer() {
        discoveryTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task {
                await self?.refreshDiscovery()
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
        connection.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.handleConnectionStatusChange(connection, status: status)
            }
            .store(in: &cancellables)
    }
    
    private func handleConnectionStatusChange(_ connection: P2PConnection, status: P2PConnectionStatus) {
        switch status {
        case .disconnected, .failed:
            // 连接断开，从活跃连接中移除
            activeConnections.removeValue(forKey: connection.device.deviceId)
            
            // 如果没有活跃连接，更新网络状态
            if activeConnections.isEmpty {
                networkState = .disconnected
            }
            
        default:
            break
        }
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

#if DEBUG
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