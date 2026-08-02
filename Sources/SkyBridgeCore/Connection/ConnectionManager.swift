// DEDUPLICATION TARGET — not inherently macOS-only.
//
// macOS 侧的发现/连接编排实现。iOS 目前有自己的一份（iOS 侧连接管理），阶段 0 只让
// SkyBridgeCore 能为 iOS 编译，不在同一二进制里立起第二套实现。采用 iOS 版本是
// 阶段 3 的逐类型迁移工作，记录在 Docs/background-wake-capability-ledger.md。
#if os(macOS)
import Foundation
import Network
import OSLog
import Combine

// 导入必要的模型和类型
extension ConnectionManager {
 // 这些类型定义将在文件末尾提供
}

/// 连接管理器 - 支持多种连接方式
/// 继承BaseManager，统一管理器模式和生命周期管理
@MainActor
public class ConnectionManager: BaseManager {
    
 // MARK: - 发布的属性
    
 /// 可用的连接方式
    @Published public var availableConnections: [ConnectionMethod] = []
 /// 当前活跃的连接
    @Published public var activeConnections: [ActiveConnection] = []
 /// 连接状态
    @Published public var connectionStatus: ConnectionStatus = .disconnected
    
 // MARK: - 私有属性
    
    private var wifiManager: WiFiConnectionManager
    private var thunderboltManager: ThunderboltConnectionManager
    private var usbcManager: USBCConnectionManager
    
 // MARK: - 初始化
    
    public init() {
        self.wifiManager = WiFiConnectionManager()
        self.thunderboltManager = ThunderboltConnectionManager()
        self.usbcManager = USBCConnectionManager()
        
 // 调用父类初始化，传入管理器类别
        super.init(category: "ConnectionManager")
    }
    
 // MARK: - BaseManager重写方法
    
 /// 执行连接管理器的初始化逻辑
    public override func performInitialization() async {
        await super.performInitialization()
        
 // 初始化完成后扫描可用连接
        scanAvailableConnections()
        logger.info("✅ 连接管理器初始化完成")
    }
    
 /// 启动连接管理器
    public override func performStart() async throws {
        logger.info("🚀 启动连接管理器服务")
        
 // 开始监控连接状态
        startConnectionMonitoring()
    }
    
 /// 停止连接管理器
    public override func performStop() async {
        logger.info("🛑 停止连接管理器服务")
        
 // 断开所有活跃连接
        await disconnectAllConnections()
        
 // 停止连接监控
        stopConnectionMonitoring()
    }
    
 /// 清理资源
    public override func cleanup() {
        super.cleanup()
        
 // 清理连接数据
        availableConnections.removeAll()
        activeConnections.removeAll()
        connectionStatus = .disconnected
    }
    
 // MARK: - 私有辅助方法
    
 /// 启动连接监控
    private func startConnectionMonitoring() {
 // 实现连接状态监控逻辑
        logger.debug("🔍 启动连接监控")
    }
    
 /// 停止连接监控
    private func stopConnectionMonitoring() {
 // 停止连接状态监控
        logger.debug("🛑 停止连接监控")
    }
    
 /// 断开所有活跃连接
    private func disconnectAllConnections() async {
        logger.info("🔌 断开所有活跃连接 (\(self.activeConnections.count)个)")
        
        for connection in self.activeConnections {
            await disconnectConnection(connection.id)
        }
    }
    
 // MARK: - 公共方法
    
 /// 扫描可用的连接方式
    public func scanAvailableConnections() {
        logger.info("开始扫描可用连接方式")
        
        Task {
            var connections: [ConnectionMethod] = []
            
 // 检查Wi-Fi连接
            if await wifiManager.isAvailable() {
                connections.append(.wifi(interface: "en0"))
            }
            
 // 检查Thunderbolt连接
            if await thunderboltManager.isAvailable() {
                connections.append(.thunderbolt(interface: "bridge100"))
            }
            
 // 检查USB-C连接
            if await usbcManager.isAvailable() {
                connections.append(.usbc(interface: "en5"))
            }
            
            await MainActor.run {
                self.availableConnections = connections
                logger.info("发现 \(connections.count) 种可用连接方式")
            }
        }
    }
    
 /// 建立连接
    public func establishConnection(method: ConnectionMethod, to device: DiscoveredDevice) async throws {
        logger.info("尝试建立连接: \(method.description) -> \(device.name)")
        
        connectionStatus = .connecting
        
        do {
            let connection: ActiveConnection
            
            switch method {
            case .wifi(let interface):
                connection = try await wifiManager.connect(to: device, interface: interface)
            case .thunderbolt(let interface):
                connection = try await thunderboltManager.connect(to: device, interface: interface)
            case .usbc(let interface):
                connection = try await usbcManager.connect(to: device, interface: interface)
            }
            
            activeConnections.append(connection)
            connectionStatus = .connected
            
            logger.info("连接建立成功: \(connection.id)")
            
        } catch {
            connectionStatus = .error
            logger.error("连接失败: \(error.localizedDescription)")
            throw error
        }
    }
    
 /// 断开连接
    public func disconnectConnection(_ connectionId: UUID) async {
        logger.info("断开连接: \(connectionId)")
        
        if let index = activeConnections.firstIndex(where: { $0.id == connectionId }) {
            let connection = activeConnections[index]
            
 // 根据连接类型调用相应的断开方法
            switch connection.method {
            case .wifi:
                await wifiManager.disconnect(connectionId)
            case .thunderbolt:
                await thunderboltManager.disconnect(connectionId)
            case .usbc:
                usbcManager.disconnect(connectionId)
            }
            
            activeConnections.remove(at: index)
            
            if activeConnections.isEmpty {
                connectionStatus = .disconnected
            }
            
            logger.info("连接已断开: \(connectionId)")
        }
    }
    
 /// 发送数据
    public func sendData(_ data: Data, via connectionId: UUID) async throws {
        guard let connection = activeConnections.first(where: { $0.id == connectionId }) else {
            throw ConnectionError.connectionNotFound
        }
        
        switch connection.method {
        case .wifi:
            try await wifiManager.sendData(data, connectionId: connectionId)
        case .thunderbolt:
            try await thunderboltManager.sendData(data, connectionId: connectionId)
        case .usbc:
            try await usbcManager.sendData(data, connectionId: connectionId)
        }
    }
    
 /// 获取连接统计信息
    public func getConnectionStats(_ connectionId: UUID) -> ConnectionStats? {
        guard let connection = activeConnections.first(where: { $0.id == connectionId }) else {
            return nil
        }
        
        switch connection.method {
        case .wifi:
            return wifiManager.getStats(connectionId)
        case .thunderbolt:
            return thunderboltManager.getStats(connectionId)
        case .usbc:
            return usbcManager.getStats(connectionId)
        }
    }
}

// MARK: - 数据模型

/// 连接方式
public enum ConnectionMethod: Hashable, Sendable {
    case wifi(interface: String)
    case thunderbolt(interface: String)
    case usbc(interface: String)
    
    public var description: String {
        switch self {
        case .wifi(let interface):
            return "Wi-Fi (\(interface))"
        case .thunderbolt(let interface):
            return "Thunderbolt Bridge (\(interface))"
        case .usbc(let interface):
            return "USB-C (\(interface))"
        }
    }
    
    public var priority: Int {
        switch self {
        case .thunderbolt: return 3  // 最高优先级
        case .usbc: return 2
        case .wifi: return 1         // 最低优先级
        }
    }
}

/// 活跃连接
public struct ActiveConnection: Identifiable, Sendable {
    public let id: UUID
    public let method: ConnectionMethod
    public let device: DiscoveredDevice
    public let establishedAt: Date
    public var lastActivity: Date
    public var bytesTransferred: UInt64
    
    public init(method: ConnectionMethod, device: DiscoveredDevice) {
        self.id = UUID()
        self.method = method
        self.device = device
        self.establishedAt = Date()
        self.lastActivity = Date()
        self.bytesTransferred = 0
    }
}

/// 连接统计信息
public struct ConnectionStats: Sendable {
    public let connectionId: UUID
    public let bandwidth: Double // Mbps
    public let latency: TimeInterval // ms
    public let packetLoss: Double // %
    public let uptime: TimeInterval // seconds
    
    public init(connectionId: UUID, bandwidth: Double, latency: TimeInterval, packetLoss: Double, uptime: TimeInterval) {
        self.connectionId = connectionId
        self.bandwidth = bandwidth
        self.latency = latency
        self.packetLoss = packetLoss
        self.uptime = uptime
    }
}

/// 连接错误
public enum ConnectionError: Error, LocalizedError {
    case connectionNotFound
    case interfaceNotAvailable
    case authenticationFailed
    case networkUnreachable
    
    public var errorDescription: String? {
        switch self {
        case .connectionNotFound:
            return "连接未找到"
        case .interfaceNotAvailable:
            return "网络接口不可用"
        case .authenticationFailed:
            return "身份验证失败"
        case .networkUnreachable:
            return "网络不可达"
        }
    }
}
#endif
