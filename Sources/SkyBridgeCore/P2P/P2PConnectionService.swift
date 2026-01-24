//
// P2PConnectionService.swift
// Skybridge-Compass
//
// 点对点连接层（基于 Network.framework UDP 通道）
// 平台：macOS 26.x / Swift 6.2.1
//

import Foundation
import Network
import OSLog

/// P2P 连接服务：负责建立 UDP 通道、发送/接收业务事件
public actor P2PConnectionService {

 // MARK: - 公共类型

 /// 本机扮演的角色
    public enum Role: Sendable {
 /// 作为“服务端”：在本地端口上监听，等待对端连入
        case publisher
 /// 作为“客户端”：主动连接到对端（不需要本地监听）
        case subscriber
    }

 /// 服务状态
    public enum ServiceState: Equatable, Sendable {
        case idle
        case listening(port: UInt16)
        case connected               // 至少存在一个就绪连接
        case failed(String)
    }

 /// 逻辑连接 ID
    public typealias ConnectionID = UUID

 /// 点对点业务事件
    public enum P2PEvent: Codable, Sendable {
        case handshake(Handshake)          // 初始握手
        case keepAlive                     // 心跳
        case textMessage(String)           // 文本消息 / 调试
 // 后面你可以拓展 frame / input / control 等
    }

 /// 握手内容
    public struct Handshake: Codable, Sendable {
        public let appVersion: String
        public let deviceName: String
        public let capabilities: [String]

        public init(appVersion: String,
                    deviceName: String,
                    capabilities: [String]) {
            self.appVersion = appVersion
            self.deviceName = deviceName
            self.capabilities = capabilities
        }
    }

 /// 对上层暴露的连接信息快照
    public struct ConnectionInfo: Sendable {
        public let id: ConnectionID
        public let role: Role
        public let endpoint: NWEndpoint?
        public let isReady: Bool
        public let lastError: Error?
    }

 // MARK: - 单例

    public static let shared = P2PConnectionService()

 // MARK: - 私有状态

    private let logger = Logger(subsystem: "com.skybridge.Compass",
                                category: "P2PConnection")

 /// 当前服务状态
    private var state: ServiceState = .idle

 /// 当前角色（只在 start(role:) 时设置）
    private var role: Role?

 /// UDP 监听器（仅 publisher 需要）
    private var listener: NWListener?

 /// 活跃连接表
    private struct ManagedConnection {
        var role: Role
        var connection: NWConnection
        var lastError: Error?
    }

    private var connections: [ConnectionID: ManagedConnection] = [:]

 /// 上层回调：收到事件时调用
    private var eventHandler: (@Sendable (ConnectionID, P2PEvent) -> Void)?

 /// 编解码器
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

 /// 默认 P2P 端口（不要和 DeviceDiscoveryManager 的 8080 撞）
    private let defaultPort: UInt16 = 9090

 // MARK: - 对外配置 / 查询

    public func setEventHandler(
        _ handler: (@Sendable (ConnectionID, P2PEvent) -> Void)?
    ) {
        self.eventHandler = handler
    }

    public func currentState() -> ServiceState {
        state
    }

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

 // MARK: - 服务启动 / 停止

 /// 启动 P2P 服务。
 ///
 /// - publisher: 在本地 `listenPort` 上监听 UDP，等待对端连接
 /// - subscriber: 这里只记录角色，不主动做事（真正连别人用 connect(toHost:port:)）
    public func start(role: Role, listenPort: UInt16? = nil) async throws {
 // 先停掉之前的
        await stop()

        self.role = role

        switch role {
        case .publisher:
            let port = listenPort ?? defaultPort
            try await startListeningWithFallback(preferredPort: port)
        case .subscriber:
            state = .idle
            logger.info("P2PConnectionService 启动为 subscriber（仅主动发起连接）")
        }
    }

 /// 停止监听并断开所有连接
    public func stop() async {
        listener?.cancel()
        listener = nil

        for (_, managed) in connections {
            managed.connection.cancel()
        }
        connections.removeAll()

        state = .idle
        logger.info("P2PConnectionService 已停止，所有连接已关闭")
    }

 // MARK: - 连接管理（对外）

 /// 作为客户端，主动连接到指定 host:port
    @discardableResult
    public func connect(
        toHost host: String,
        port: UInt16? = nil,
        role: Role = .subscriber
    ) async throws -> ConnectionID {
        let portValue = port ?? defaultPort

        guard let nwPort = NWEndpoint.Port(rawValue: portValue) else {
            throw makeError("无效端口号: \(portValue)")
        }

        let parameters = NWParameters.udp
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: nwPort,
            using: parameters
        )

        let id = ConnectionID()
        try await addConnection(id: id,
                                connection: connection,
                                role: role)

        logger.info("🔗 P2P 主动连接：\(host, privacy: .public):\(portValue)")

        return id
    }

 /// 断开指定连接
    public func disconnect(_ id: ConnectionID) async {
        guard let managed = connections.removeValue(forKey: id) else { return }
        managed.connection.cancel()
        logger.info("🔌 P2P 连接已关闭：\(id.uuidString, privacy: .public)")

        if connections.isEmpty,
           case .listening = state {
 // 仍在监听，但当前没有活动连接
            return
        }

        if connections.isEmpty {
            state = .idle
        }
    }

 /// 向指定连接发送事件
    public func send(_ event: P2PEvent,
                     on id: ConnectionID) async throws {
        guard let managed = connections[id] else {
            throw makeError("连接不存在：\(id.uuidString)")
        }

        let data = try encoder.encode(event)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            managed.connection.send(content: data,
                                    completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

 // MARK: - 内部：监听端口 / 接受连接

    private func startListeningWithFallback(preferredPort: UInt16) async throws {
        let maxAttempts = 16
        var lastError: Error?
        for offset in 0..<maxAttempts {
            let port = preferredPort &+ UInt16(offset)
            do {
                try await startListeningExact(on: port)
                return
            } catch {
                lastError = error
                if isAddressInUse(error) { continue }
                throw error
            }
        }
        throw lastError ?? makeError("P2P 监听启动失败")
    }

    private func startListeningExact(on port: UInt16) async throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw makeError("无效监听端口: \(port)")
        }

        let parameters = NWParameters.udp
        let listener = try NWListener(using: parameters, on: nwPort)
        self.listener = listener

        listener.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            Task { await self.handleListenerStateUpdate(state, port: port) }
        }

        listener.newConnectionHandler = { [weak self] connection in
            guard let self = self else { return }
            Task {
                let id = ConnectionID()
                try await self.addConnection(id: id,
                                             connection: connection,
                                             role: .publisher)
                self.logger.info("🔗 收到新的 P2P 连接：\(id.uuidString, privacy: .public)")
            }
        }

        listener.start(queue: .global())
        state = .listening(port: port)

        logger.info("📡 P2P UDP 监听已启动，端口 \(port)")
    }

    private func isAddressInUse(_ error: Error) -> Bool {
        if let nw = error as? NWError {
            switch nw {
            case .posix(let code):
                return code == .EADDRINUSE
            default:
                return false
            }
        }
        return false
    }

    private func handleListenerStateUpdate(_ state: NWListener.State,
                                           port: UInt16) async {
        switch state {
        case .ready:
            logger.info("📡 P2P 监听就绪，端口 \(port)")
        case .failed(let error):
            logger.error("❌ P2P 监听失败：\(error.localizedDescription, privacy: .public)")
            self.state = .failed(error.localizedDescription)
        case .cancelled:
            logger.info("⏹️ P2P 监听已取消")
        default:
            break
        }
    }

 // MARK: - 内部：添加连接 & 接收循环

    private func addConnection(
        id: ConnectionID,
        connection: NWConnection,
        role: Role
    ) async throws {
 // 设置 state 回调
        connection.stateUpdateHandler = { [weak self] newState in
            guard let self = self else { return }
            Task { await self.handleConnectionStateUpdate(id: id,
                                                          state: newState) }
        }

 // 启动连接
        connection.start(queue: .global())

 // 保存
        connections[id] = ManagedConnection(role: role,
                                            connection: connection,
                                            lastError: nil)

 // 启动接收循环
        startReceiveLoop(for: id, connection: connection)
    }

    private func handleConnectionStateUpdate(
        id: ConnectionID,
        state newState: NWConnection.State
    ) async {
        logger.debug("P2P 连接 \(id.uuidString, privacy: .public) 状态：\(String(describing: newState), privacy: .public)")

        switch newState {
        case .ready:
            state = .connected
        case .failed(let error):
            logger.error("❌ P2P 连接失败 \(id.uuidString, privacy: .public)：\(error.localizedDescription, privacy: .public)")
            if var managed = connections[id] {
                managed.lastError = error
                connections[id] = managed
            }
        case .cancelled:
            connections.removeValue(forKey: id)
            logger.info("⏹️ P2P 连接已取消：\(id.uuidString, privacy: .public)")
        default:
            break
        }
    }

    private func startReceiveLoop(for id: ConnectionID,
                                  connection: NWConnection) {
        Task.detached { [weak self] in
            guard let self = self else { return }

            while true {
                do {
                    guard let data = try await self.receiveMessage(on: connection)
                    else {
 // nil 表示连接关闭
                        break
                    }

                    do {
                        let event = try self.decoder.decode(P2PEvent.self,
                                                            from: data)
                        await self.handleIncomingEvent(id: id,
                                                       event: event)
                    } catch {
                        self.logger.error("❌ P2P 消息解码失败：\(error.localizedDescription, privacy: .public)")
                    }
                } catch {
                    await self.handleConnectionError(id: id, error: error)
                    break
                }
            }
        }
    }

    private func receiveMessage(on connection: NWConnection) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receiveMessage { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: data)
                }
            }
        }
    }

    private func handleIncomingEvent(id: ConnectionID,
                                     event: P2PEvent) async {
        logger.debug("📩 收到 P2P 事件（\(id.uuidString, privacy: .public)）")
        guard let handler = eventHandler else { return }

 // 回调放到主线程，方便直接更新 UI
        await MainActor.run {
            handler(id, event)
        }
    }

    private func handleConnectionError(id: ConnectionID,
                                       error: Error) async {
        logger.error("❌ P2P 连接错误 \(id.uuidString, privacy: .public)：\(error.localizedDescription, privacy: .public)")
        if var managed = connections[id] {
            managed.lastError = error
            connections[id] = managed
        }
    }

 // MARK: - 工具

    private func makeError(_ message: String) -> NSError {
        NSError(domain: "P2PConnectionService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
