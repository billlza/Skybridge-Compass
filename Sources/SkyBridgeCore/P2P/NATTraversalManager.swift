import Foundation
import Network
import Combine

// MARK: - NAT穿透管理器
public final class NATTraversalManager: BaseManager {
    
 // MARK: - 发布的状态属性
    @Published public var traversalState: TraversalState = .idle
    @Published public var detectedNATType: P2PNATType = .unknown
    @Published public var publicEndpoint: NWEndpoint?
    @Published public var traversalStatistics: TraversalStatistics = TraversalStatistics()
    
 // MARK: - 私有属性
    private let stunClient: STUNClient
    private let configuration: P2PNetworkConfiguration
    private var activeSessions: [String: HolePunchingSession] = [:]
    private let networkQueue: DispatchQueue
    private var listener: NWListener?
    
 // MARK: - 初始化方法
    public init(configuration: P2PNetworkConfiguration) {
        self.configuration = configuration
        self.networkQueue = DispatchQueue(label: "com.skybridge.nat.network", qos: .userInitiated)
        
 // 使用第一个STUN服务器初始化客户端
        let firstServer = configuration.stunServers.first ?? P2PSTUNServer(host: "stun.l.google.com", port: 19302)
        self.stunClient = STUNClient(server: STUNServer(host: firstServer.host, port: firstServer.port))
        
        super.init(category: "NATTraversalManager")
    }
    
 // MARK: - 公共方法
    
 /// 检测NAT类型
    public func detectNATType(completion: @escaping @Sendable (P2PNATType) -> Void) {
        Task {
            await withCheckedContinuation { continuation in
                stunClient.detectNATType { @Sendable result in
 // 在同一个任务上下文中处理结果，避免数据竞争
                    let natType: P2PNATType
                    switch result {
                    case .success(let detectedType):
 // 将NATType转换为P2PNATType
                        switch detectedType {
                        case .fullCone:
                            natType = .fullCone
                        case .restrictedCone:
                            natType = .restrictedCone
                        case .portRestrictedCone:
                            natType = .portRestrictedCone
                        case .symmetric:
                            natType = .symmetric
                        case .noNAT:
                            natType = .noNAT
                        case .unknown:
                            natType = .unknown
                        }
                    case .failure:
                        natType = .unknown
                    }
                    
 // 在主线程更新状态并调用完成回调
                    Task { @MainActor in
                        self.detectedNATType = natType
                        completion(natType)
                        continuation.resume()
                    }
                }
            }
        }
    }
    
 /// 将 NATType 转换为 P2PNATType
    @MainActor
    private func convertToP2PNATType(_ natType: NATType) -> P2PNATType {
        switch natType {
        case .fullCone:
            return .fullCone
        case .restrictedCone:
            return .restrictedCone
        case .portRestrictedCone:
            return .portRestrictedCone
        case .symmetric:
            return .symmetric
        case .noNAT:
            return .noNAT
        case .unknown:
            return .unknown
        }
    }
    
 /// 启动监听器
    public func startListener() throws {
        guard listener == nil else { return }
        
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        
        listener = try NWListener(using: parameters, on: NWEndpoint.Port(integerLiteral: configuration.listenPort))
        
        listener?.newConnectionHandler = { connection in
            Task { @MainActor in
                self.handleIncomingConnection(connection)
            }
        }
        
        listener?.start(queue: networkQueue)
        SkyBridgeLogger.p2p.debugOnly("🎧 监听器启动在端口: \(configuration.listenPort)")
    }
    
 /// 停止监听器
    public func stopListener() {
        listener?.cancel()
        listener = nil
        SkyBridgeLogger.p2p.debugOnly("🛑 监听器已停止")
    }
    
 /// 执行直接连接
    public func performDirectConnection(to session: HolePunchingSession) async throws {
        SkyBridgeLogger.p2p.debugOnly("🔗 尝试直接连接到: \(session.targetDevice.deviceId)")
        
        guard let endpointString = session.targetDevice.endpoints.first else {
            throw TraversalError.noEndpointsAvailable
        }
        
 // 解析端点字符串
        let components = endpointString.split(separator: ":")
        guard components.count == 2,
              let host = components.first,
              let portString = components.last,
              let port = UInt16(portString) else {
            throw TraversalError.invalidEndpoint
        }
        
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(String(host)), 
                                         port: NWEndpoint.Port(integerLiteral: port))
        
        let parameters = NWParameters.udp
        let connection = NWConnection(to: endpoint, using: parameters)
        
        return try await withCheckedThrowingContinuation { continuation in
            connection.stateUpdateHandler = { (state: NWConnection.State) in
                switch state {
                case .ready:
                    SkyBridgeLogger.p2p.debugOnly("✅ 直接连接成功")
                    continuation.resume()
                case .failed(let error):
                    SkyBridgeLogger.p2p.error("❌ 直接连接失败: \(error.localizedDescription, privacy: .private)")
                    continuation.resume(throwing: TraversalError.connectionFailed(error))
                case .cancelled:
                    SkyBridgeLogger.p2p.debugOnly("🚫 连接被取消")
                    continuation.resume(throwing: TraversalError.connectionCancelled)
                default:
                    break
                }
            }
            
            connection.start(queue: networkQueue)
        }
    }
    
 // MARK: - 私有方法
    
    private func handleIncomingConnection(_ connection: NWConnection) {
        SkyBridgeLogger.p2p.debugOnly("📥 收到新的连接")
        connection.start(queue: networkQueue)
    }
}

// MARK: - 支持类型

/// 穿透状态枚举
public enum TraversalState: String, CaseIterable {
    case idle = "空闲"
    case detecting = "检测中"
    case connecting = "连接中"
    case connected = "已连接"
    case failed = "失败"
    
    public var displayName: String {
        return rawValue
    }
}

/// 穿透错误枚举
public enum TraversalError: LocalizedError {
    case stunDetectionFailed(STUNError)
    case noEndpointsAvailable
    case invalidEndpoint
    case connectionFailed(Error)
    case connectionCancelled
    case timeout
    
    public var errorDescription: String? {
        switch self {
        case .stunDetectionFailed(let stunError):
            return "STUN检测失败: \(stunError.localizedDescription)"
        case .noEndpointsAvailable:
            return "没有可用的端点"
        case .invalidEndpoint:
            return "无效的端点格式"
        case .connectionFailed(let error):
            return "连接失败: \(error.localizedDescription)"
        case .connectionCancelled:
            return "连接被取消"
        case .timeout:
            return "连接超时"
        }
    }
}

/// 穿透统计信息
public struct TraversalStatistics {
    public var successfulConnections: Int = 0
    public var failedConnections: Int = 0
    public var averageConnectionTime: TimeInterval = 0.0
    public var lastConnectionAttempt: Date?
    
    public init() {}
}

/// 打洞会话
public struct HolePunchingSession {
    public let sessionId: String
    public let targetDevice: P2PDevice
    public let createdAt: Date
    public var state: TraversalState
    
    public init(sessionId: String, targetDevice: P2PDevice) {
        self.sessionId = sessionId
        self.targetDevice = targetDevice
        self.createdAt = Date()
        self.state = .idle
    }
}
