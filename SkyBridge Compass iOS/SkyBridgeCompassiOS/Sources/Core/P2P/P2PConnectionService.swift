//
// P2PConnectionService.swift
// SkyBridgeCompassiOS
//
// P2P 连接服务 - 管理点对点连接的建立和维护
// 与 macOS 版本兼容
//

import Foundation
import Network

// MARK: - P2P Connection Service

/// P2P 连接服务
@available(iOS 17.0, *)
public actor P2PConnectionService {
    
    // MARK: - Types
    
    /// 角色
    public enum Role: Sendable {
        case publisher  // 服务端
        case subscriber // 客户端
    }
    
    /// 服务状态
    public enum ServiceState: Equatable, Sendable {
        case idle
        case listening(port: UInt16)
        case connected
        case failed(String)
    }
    
    /// 连接 ID
    public typealias ConnectionID = UUID
    
    /// P2P 事件
    public enum P2PEvent: Codable, Sendable {
        case handshake(Handshake)
        case keepAlive
        case textMessage(String)
        case data(Data)
    }
    
    /// 握手信息
    public struct Handshake: Codable, Sendable {
        public let appVersion: String
        public let deviceName: String
        public let capabilities: [String]
        
        public init(appVersion: String, deviceName: String, capabilities: [String]) {
            self.appVersion = appVersion
            self.deviceName = deviceName
            self.capabilities = capabilities
        }
    }
    
    /// 连接信息
    public struct ConnectionInfo: Sendable {
        public let id: ConnectionID
        public let role: Role
        public let endpoint: NWEndpoint?
        public let isReady: Bool
        public let lastError: Error?
    }
    
    // MARK: - Singleton
    
    public static let shared = P2PConnectionService()
    
    // MARK: - Private Properties
    
    private var state: ServiceState = .idle
    private var role: Role?
    private var listener: NWListener?
    
    private struct ManagedConnection {
        var role: Role
        var connection: NWConnection
        var lastError: Error?
    }
    
    private var connections: [ConnectionID: ManagedConnection] = [:]
    private var eventHandler: (@Sendable (ConnectionID, P2PEvent) -> Void)?
    
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let defaultPort: UInt16 = 9090
    private let queue = DispatchQueue(label: "com.skybridge.p2p.connection", qos: .userInitiated)
    
    // MARK: - Utilities
    
    /// 防止 continuation 被多次 resume（NWConnection/NWListener 会多次触发 stateUpdate）
    private final class ResumeGuard: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false
        func tryResume() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if resumed { return false }
            resumed = true
            return true
        }
    }
    
    // MARK: - Initialization
    
    private init() {}
    
    // MARK: - Configuration
    
    /// 设置事件处理器
    public func setEventHandler(_ handler: (@Sendable (ConnectionID, P2PEvent) -> Void)?) {
        self.eventHandler = handler
    }
    
    /// 获取当前状态
    public func currentState() -> ServiceState {
        state
    }
    
    /// 获取当前连接列表
    public func currentConnections() -> [ConnectionInfo] {
        connections.map { (id, managed) in
            let isReady = (managed.connection.state == .ready)
            let endpoint = isReady ? managed.connection.currentPath?.remoteEndpoint : nil
            return ConnectionInfo(
                id: id,
                role: managed.role,
                endpoint: endpoint,
                isReady: isReady,
                lastError: managed.lastError
            )
        }
    }
    
    // MARK: - Service Control
    
    /// 启动服务
    public func start(role: Role, listenPort: UInt16? = nil) async throws {
        await stop()
        
        self.role = role
        
        switch role {
        case .publisher:
            let port = listenPort ?? defaultPort
            try await startListening(on: port)
            
        case .subscriber:
            state = .idle
            SkyBridgeLogger.shared.info("P2PConnectionService 启动为 subscriber")
        }
    }
    
    /// 停止服务
    public func stop() async {
        listener?.cancel()
        listener = nil
        
        for (_, managed) in connections {
            managed.connection.cancel()
        }
        connections.removeAll()
        
        state = .idle
        SkyBridgeLogger.shared.info("P2PConnectionService 已停止")
    }
    
    // MARK: - Connection Management
    
    /// 连接到指定主机
    @discardableResult
    public func connect(toHost host: String, port: UInt16) async throws -> ConnectionID {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(integerLiteral: port)
        )
        
        let parameters = NWParameters.udp
        parameters.includePeerToPeer = true
        
        let connection = NWConnection(to: endpoint, using: parameters)
        let connectionId = ConnectionID()
        
        connections[connectionId] = ManagedConnection(
            role: .subscriber,
            connection: connection,
            lastError: nil
        )
        
        setupConnectionHandler(connection, id: connectionId)
        
        let guard_ = ResumeGuard()
        
        return try await withCheckedThrowingContinuation { continuation in
            connection.stateUpdateHandler = { [weak self] newState in
                Task { [weak self] in
                    await self?.handleConnectionState(newState, id: connectionId, continuation: continuation, resumeGuard: guard_)
                }
            }
            
            connection.start(queue: queue)
        }
    }
    
    /// 断开连接
    public func disconnect(_ connectionId: ConnectionID) {
        if let managed = connections[connectionId] {
            managed.connection.cancel()
            connections.removeValue(forKey: connectionId)
        }
    }
    
    /// 发送事件
    public func sendEvent(_ event: P2PEvent, to connectionId: ConnectionID) async throws {
        guard let managed = connections[connectionId] else {
            throw P2PConnectionError.connectionNotFound
        }
        
        let data = try encoder.encode(event)
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            managed.connection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
    
    /// 广播事件到所有连接
    public func broadcast(_ event: P2PEvent) async {
        for connectionId in connections.keys {
            try? await sendEvent(event, to: connectionId)
        }
    }
    
    // MARK: - Private Methods
    
    private func startListening(on port: UInt16) async throws {
        let parameters = NWParameters.udp
        parameters.includePeerToPeer = true
        parameters.allowLocalEndpointReuse = true
        
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(integerLiteral: port))
        self.listener = listener
        
        listener.newConnectionHandler = { [weak self] newConnection in
            Task { [weak self] in
                await self?.handleNewConnection(newConnection)
            }
        }
        
        // 等待监听器就绪（必须先设置 stateUpdateHandler 再 start，避免丢失 .ready 事件）
        let guard_ = ResumeGuard()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self] newState in
                Task { [weak self] in
                    await self?.handleListenerState(newState, port: port)
                    
                    switch newState {
                    case .ready:
                        if guard_.tryResume() { continuation.resume() }
                    case .failed(let error):
                        if guard_.tryResume() { continuation.resume(throwing: error) }
                    default:
                        break
                    }
                }
            }
            listener.start(queue: queue)
        }
    }
    
    private func handleListenerState(_ state: NWListener.State, port: UInt16) {
        switch state {
        case .ready:
            self.state = .listening(port: port)
            SkyBridgeLogger.shared.info("P2PConnectionService 正在监听端口: \(port)")
            
        case .failed(let error):
            self.state = .failed(error.localizedDescription)
            SkyBridgeLogger.shared.error("监听失败: \(error.localizedDescription)")
            
        case .cancelled:
            self.state = .idle
            
        default:
            break
        }
    }
    
    private func handleNewConnection(_ connection: NWConnection) {
        let connectionId = ConnectionID()
        
        connections[connectionId] = ManagedConnection(
            role: .publisher,
            connection: connection,
            lastError: nil
        )
        
        setupConnectionHandler(connection, id: connectionId)
        connection.start(queue: queue)
        
        SkyBridgeLogger.shared.info("新连接: \(connectionId)")
    }
    
    private func setupConnectionHandler(_ connection: NWConnection, id: ConnectionID) {
        // 开始接收数据
        receiveData(from: connection, id: id)
    }
    
    private func receiveData(from connection: NWConnection, id: ConnectionID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { [weak self] in
                if let error = error {
                    SkyBridgeLogger.shared.error("接收数据错误: \(error.localizedDescription)")
                    return
                }
                
                if let data = data, let self = self {
                    await self.handleReceivedData(data, from: id)
                }
                
                if !isComplete {
                    await self?.receiveData(from: connection, id: id)
                }
            }
        }
    }
    
    private func handleReceivedData(_ data: Data, from connectionId: ConnectionID) async {
        do {
            let event = try decoder.decode(P2PEvent.self, from: data)
            eventHandler?(connectionId, event)
        } catch {
            SkyBridgeLogger.shared.error("解码事件失败: \(error.localizedDescription)")
        }
    }
    
    private func handleConnectionState(
        _ state: NWConnection.State,
        id: ConnectionID,
        continuation: CheckedContinuation<ConnectionID, Error>?,
        resumeGuard: ResumeGuard
    ) {
        switch state {
        case .ready:
            self.state = .connected
            if resumeGuard.tryResume() { continuation?.resume(returning: id) }
            SkyBridgeLogger.shared.info("连接就绪: \(id)")
            
        case .failed(let error):
            if var managed = connections[id] {
                managed.lastError = error
                connections[id] = managed
            }
            if resumeGuard.tryResume() { continuation?.resume(throwing: error) }
            SkyBridgeLogger.shared.error("连接失败: \(error.localizedDescription)")
            
        case .cancelled:
            connections.removeValue(forKey: id)
            
        default:
            break
        }
    }
}

// MARK: - P2P Connection Error

/// P2P 连接错误
public enum P2PConnectionError: Error, LocalizedError, Sendable {
    case connectionNotFound
    case connectionFailed(String)
    case sendFailed(String)
    case decodingFailed
    case timeout
    
    public var errorDescription: String? {
        switch self {
        case .connectionNotFound: return "连接未找到"
        case .connectionFailed(let reason): return "连接失败: \(reason)"
        case .sendFailed(let reason): return "发送失败: \(reason)"
        case .decodingFailed: return "解码失败"
        case .timeout: return "连接超时"
        }
    }
}

