//
// DiscoveryTransport.swift
// SkyBridgeCore
//
// Tech Debt Cleanup - 12: DiscoveryTransport 实现
// Requirements: 5.1, 5.2, 5.3
//
// 发现层传输协议和实现：
// - DiscoveryTransport 协议：定义发送/接收接口
// - BonjourDiscoveryTransport：基于 Bonjour/Network.framework 的实现
// - 传输层只负责发送/接收，不负责等待逻辑
//

import Foundation
import Network
import Atomics

// MARK: - DiscoveryTransport Protocol

// Note: DiscoveryTransport protocol is defined in HandshakeDriver.swift
// This file provides concrete implementations

// MARK: - Transport Error

/// 传输层错误
public enum DiscoveryTransportError: Error, LocalizedError, Sendable {
 /// 连接失败
    case connectionFailed(String)

 /// 发送失败
    case sendFailed(String)

 /// 接收失败
    case receiveFailed(String)

 /// 对端不可达
    case peerUnreachable(PeerIdentifier)

 /// 连接已关闭
    case connectionClosed

 /// 超时
    case timeout

 /// 无效数据
    case invalidData

    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        case .sendFailed(let reason):
            return "Send failed: \(reason)"
        case .receiveFailed(let reason):
            return "Receive failed: \(reason)"
        case .peerUnreachable(let peer):
            return "Peer unreachable: \(peer.deviceId)"
        case .connectionClosed:
            return "Connection closed"
        case .timeout:
            return "Operation timed out"
        case .invalidData:
            return "Invalid data received"
        }
    }
}

// MARK: - BonjourDiscoveryTransport

/// 基于 Bonjour/Network.framework 的传输实现
///
/// **设计决策**：
/// - 只负责发送/接收，不负责等待逻辑
/// - HandshakeDriver 拥有 continuation 和 timeout
/// - 使用 NWConnection 进行点对点通信
@available(macOS 14.0, *)
public actor BonjourDiscoveryTransport: DiscoveryTransport {

 // MARK: - Properties

    private static let connectionQueue = DispatchQueue(
        label: "com.skybridge.discoverytransport",
        qos: .userInitiated,
        attributes: .concurrent
    )

 /// 活跃的连接（peer deviceId -> connection）
    private var connections: [String: NWConnection] = [:]

 /// 活跃连接（peer address -> connection），用于复用入站连接
    private var connectionsByAddress: [String: NWConnection] = [:]

 /// 消息处理回调
    private var messageHandler: (@Sendable (PeerIdentifier, Data) async -> Void)?

 /// 连接世代（用于屏蔽关闭后的滞留数据）
    private nonisolated let connectionGeneration = ManagedAtomic<UInt64>(0)

 /// 监听器（用于接收入站连接）
    private var listener: NWListener?

 /// 服务类型
    private let serviceType: String

 /// 连接超时
    private let connectionTimeout: Duration

 /// 是否已启动
    private var isStarted: Bool = false

 // MARK: - Initialization

    public init(
        serviceType: String = "_skybridge-handshake._tcp",
        connectionTimeout: Duration = .seconds(10)
    ) {
        self.serviceType = serviceType
        self.connectionTimeout = connectionTimeout
    }

 // MARK: - DiscoveryTransport Protocol

 /// 发送数据到对端
 /// - Parameters:
 /// - peer: 对端标识
 /// - data: 要发送的数据
    public func send(to peer: PeerIdentifier, data: Data) async throws {
 // 获取或创建连接
        let connection = try await getOrCreateConnection(to: peer)

 // 发送数据（带长度前缀）
        let framedData = frameData(data)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: framedData,
                completion: .contentProcessed { error in
                    if let error = error {
                        continuation.resume(throwing: DiscoveryTransportError.sendFailed(error.localizedDescription))
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }

 // MARK: - Public API

 /// 启动传输层（开始监听入站连接）
 /// - Parameter port: 监听端口（0 表示自动分配）
 /// - Returns: 分配的端口号
    @discardableResult
    public func start(port: UInt16 = 0) async throws -> UInt16 {
        guard !isStarted else { return listener?.port?.rawValue ?? 0 }

        let parameters = makeTCPParameters()

        let newListener: NWListener
        if port > 0 {
            newListener = try NWListener(using: parameters, on: NWEndpoint.Port.validated(port))
        } else {
            newListener = try NWListener(using: parameters)
        }

 // 设置新连接处理
        newListener.newConnectionHandler = { [weak self] connection in
            Task {
                await self?.handleIncomingConnection(connection)
            }
        }

 // 启动监听并等待就绪
        try await waitForListenerReady(newListener)
        self.listener = newListener
        self.isStarted = true

        return newListener.port?.rawValue ?? 0
    }

 /// 停止传输层
    public func stop() {
        connectionGeneration.wrappingIncrement(ordering: .relaxed)
 // 取消所有连接
        for (_, connection) in connections {
            connection.cancel()
        }
        connections.removeAll()
        connectionsByAddress.removeAll()

 // 取消监听器
        listener?.cancel()
        listener = nil

        isStarted = false
    }

 /// 设置消息处理回调
 /// - Parameter handler: 消息处理回调
    public func setMessageHandler(
        _ handler: @escaping @Sendable (PeerIdentifier, Data) async -> Void
    ) {
        self.messageHandler = handler
    }

 /// 关闭与特定对端的连接
 /// - Parameter peer: 对端标识
    public func closeConnection(to peer: PeerIdentifier) {
        if let connection = connections.removeValue(forKey: peer.deviceId) {
            connection.cancel()
        }
        if let address = peer.address {
            connectionsByAddress.removeValue(forKey: address)
        }
    }

 /// 关闭所有活动连接但保留监听器（用于基准测试）
    public func closeAllConnections() {
        connectionGeneration.wrappingIncrement(ordering: .relaxed)
        for (_, connection) in connections {
            connection.cancel()
        }
        connections.removeAll()
        connectionsByAddress.removeAll()
    }

 // MARK: - Private Methods

 /// 获取或创建到对端的连接
    private func getOrCreateConnection(to peer: PeerIdentifier) async throws -> NWConnection {
 // 优先复用入站连接（根据地址）
        if let address = peer.address, let existingByAddress = connectionsByAddress[address] {
            if existingByAddress.state == .ready {
                return existingByAddress
            }
            connectionsByAddress.removeValue(forKey: address)
        }

 // 检查是否已有连接
        if let existing = connections[peer.deviceId] {
            if existing.state == .ready {
                return existing
            }
 // 连接不可用，移除
            connections.removeValue(forKey: peer.deviceId)
        }

 // 创建新连接
        guard let address = peer.address else {
            throw DiscoveryTransportError.peerUnreachable(peer)
        }

 // 解析地址（支持 host:port 格式）
        let (host, port) = parseAddress(address)

        let nwPort: NWEndpoint.Port
        do {
            nwPort = try NWEndpoint.Port.validated(port)
        } catch {
            // Fall back to a known-good default if the peer's advertised port is invalid/missing.
            nwPort = try NWEndpoint.Port.validated(8765)
        }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)

        let parameters = makeTCPParameters()

        let connection = NWConnection(to: endpoint, using: parameters)

 // 等待连接就绪
        try await waitForConnection(connection)

 // 保存连接
        connections[peer.deviceId] = connection
        if let address = peer.address {
            connectionsByAddress[address] = connection
        }

 // 开始接收数据
        startReceiving(on: connection, from: peer)

        return connection
    }

 /// 等待连接就绪
    private func waitForConnection(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
 // 使用 class 包装以支持 Sendable
            final class ResumeGuard: @unchecked Sendable {
                private let lock = NSLock()
                private var _resumed = false

                func tryResume() -> Bool {
                    lock.lock()
                    defer { lock.unlock() }
                    if _resumed { return false }
                    _resumed = true
                    return true
                }
            }

            let guard_ = ResumeGuard()
            let timeoutTask = Task {
                do {
                    try await Task.sleep(for: connectionTimeout)
                } catch {
                    return
                }
                if guard_.tryResume() {
                    connection.cancel()
                    continuation.resume(throwing: DiscoveryTransportError.timeout)
                }
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if guard_.tryResume() {
                        timeoutTask.cancel()
                        continuation.resume()
                    }
                case .failed(let error):
                    if guard_.tryResume() {
                        timeoutTask.cancel()
                        continuation.resume(throwing: DiscoveryTransportError.connectionFailed(error.localizedDescription))
                    }
                case .cancelled:
                    if guard_.tryResume() {
                        timeoutTask.cancel()
                        continuation.resume(throwing: DiscoveryTransportError.connectionClosed)
                    }
                default:
                    break
                }
            }

            connection.start(queue: Self.connectionQueue)
        }
    }

    private func waitForListenerReady(_ listener: NWListener) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            final class ResumeGuard: @unchecked Sendable {
                private let lock = NSLock()
                private var _resumed = false

                func tryResume() -> Bool {
                    lock.lock()
                    defer { lock.unlock() }
                    if _resumed { return false }
                    _resumed = true
                    return true
                }
            }

            let guard_ = ResumeGuard()
            let timeoutTask = Task {
                do {
                    try await Task.sleep(for: connectionTimeout)
                } catch {
                    return
                }
                if guard_.tryResume() {
                    listener.cancel()
                    continuation.resume(throwing: DiscoveryTransportError.timeout)
                }
            }

            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if guard_.tryResume() {
                        timeoutTask.cancel()
                        continuation.resume()
                    }
                case .failed(let error):
                    if guard_.tryResume() {
                        timeoutTask.cancel()
                        continuation.resume(throwing: DiscoveryTransportError.connectionFailed(error.localizedDescription))
                    }
                case .cancelled:
                    if guard_.tryResume() {
                        timeoutTask.cancel()
                        continuation.resume(throwing: DiscoveryTransportError.connectionClosed)
                    }
                default:
                    break
                }
            }

            listener.start(queue: Self.connectionQueue)
        }
    }

 /// 处理入站连接
    private func handleIncomingConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                Task {
 // 从连接中提取对端信息
                    let peer = await self?.extractPeerIdentifier(from: connection)
                    if let peer = peer {
                        await self?.registerConnection(connection, for: peer)
                        await self?.startReceiving(on: connection, from: peer)
                    }
                }
            case .failed, .cancelled:
                connection.cancel()
            default:
                break
            }
        }

        connection.start(queue: Self.connectionQueue)
    }

 /// 注册连接
    private func registerConnection(_ connection: NWConnection, for peer: PeerIdentifier) {
        connections[peer.deviceId] = connection
        if let address = peer.address {
            connectionsByAddress[address] = connection
        }
    }

 /// 从连接中提取对端标识
    private func extractPeerIdentifier(from connection: NWConnection) -> PeerIdentifier {
 // 从连接端点提取地址
        var address: String?
        if case .hostPort(let host, let port) = connection.currentPath?.remoteEndpoint {
            address = formatHostPort(host: host, port: port)
        }
        if address == nil, case .hostPort(let host, let port) = connection.endpoint {
            address = formatHostPort(host: host, port: port)
        }

 // 使用连接的唯一标识作为临时 deviceId
        let deviceId = "incoming-\(ObjectIdentifier(connection).hashValue)"

        return PeerIdentifier(deviceId: deviceId, address: address)
    }

 /// 开始接收数据
    private func startReceiving(on connection: NWConnection, from peer: PeerIdentifier) {
        let generation = connectionGeneration.load(ordering: .relaxed)
        receiveNextMessage(on: connection, from: peer, generation: generation)
    }

 /// 接收下一条消息
    private func receiveNextMessage(on connection: NWConnection, from peer: PeerIdentifier, generation: UInt64) {
 // 先读取 4 字节长度前缀
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }
            guard generation == self.connectionGeneration.load(ordering: .relaxed) else { return }

            if let error = error {
                SkyBridgeLogger.p2p.error("Receive error: \(error.localizedDescription)")
                return
            }

            if isComplete {
 // 连接关闭
                Task {
                    await self.closeConnection(to: peer)
                }
                return
            }

            guard let lengthData = content, lengthData.count == 4 else {
 // 继续接收
                Task {
                    await self.receiveNextMessage(on: connection, from: peer, generation: generation)
                }
                return
            }

 // 解析长度
            let length = lengthData.withUnsafeBytes { ptr in
                ptr.load(as: UInt32.self).bigEndian
            }

 // 读取消息体
            connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { [weak self] content, _, _, error in
                guard let self = self else { return }
                guard generation == self.connectionGeneration.load(ordering: .relaxed) else { return }

                if let error = error {
                    SkyBridgeLogger.p2p.error("Receive body error: \(error.localizedDescription)")
                    return
                }

                if let data = content {
 // 调用消息处理回调
                    Task {
                        await self.handleReceivedData(data, from: peer)
 // 继续接收下一条消息
                        await self.receiveNextMessage(on: connection, from: peer, generation: generation)
                    }
                }
            }
        }
    }

 /// 处理接收到的数据
    private func handleReceivedData(_ data: Data, from peer: PeerIdentifier) async {
        await messageHandler?(peer, data)
    }

 /// 添加长度前缀帧
    private func frameData(_ data: Data) -> Data {
        var framedData = Data()

 // 4 字节长度前缀（big-endian）
        var length = UInt32(data.count).bigEndian
        framedData.append(Data(bytes: &length, count: 4))
        framedData.append(data)

        return framedData
    }

 /// 解析地址字符串
    private func parseAddress(_ address: String) -> (host: String, port: UInt16) {
        if address.hasPrefix("[") {
            if let end = address.firstIndex(of: "]") {
                let host = String(address[address.index(after: address.startIndex)..<end])
                var port: UInt16 = 8765
                let portStart = address.index(after: end)
                if portStart < address.endIndex, address[portStart] == ":" {
                    let portString = address[address.index(after: portStart)...]
                    if let parsedPort = UInt16(portString) {
                        port = parsedPort
                    }
                }
                return (host, port)
            }
        }
        let components = address.split(separator: ":")
        if components.count == 2,
           let port = UInt16(components[1]) {
            return (String(components[0]), port)
        }
        return (address, 8765) // 默认端口
    }

    private func formatHostPort(host: NWEndpoint.Host, port: NWEndpoint.Port) -> String {
        let hostString = String(describing: host)
        if hostString.contains(":") && !hostString.hasPrefix("[") {
            return "[\(hostString)]:\(port.rawValue)"
        }
        return "\(hostString):\(port.rawValue)"
    }

    private func makeTCPParameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        parameters.allowLocalEndpointReuse = true
        if let tcpOptions = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcpOptions.noDelay = true
            // 🧷 降低空闲链路被系统/路由器清理导致的“幽灵断开”
            tcpOptions.enableKeepalive = true
            tcpOptions.keepaliveIdle = 30
            tcpOptions.keepaliveInterval = 15
            tcpOptions.keepaliveCount = 4
        }
        return parameters
    }
}

// MARK: - In-Memory Transport (for testing)

/// 内存传输实现（用于测试）
@available(macOS 14.0, iOS 17.0, *)
public actor InMemoryDiscoveryTransport: DiscoveryTransport {

 /// 发送的消息记录
    public private(set) var sentMessages: [(peer: PeerIdentifier, data: Data)] = []

 /// 是否应该失败
    private var shouldFail: Bool = false

 /// 失败错误
    private var failError: Error = DiscoveryTransportError.sendFailed("Mock failure")

 /// 消息处理回调
    private var messageHandler: (@Sendable (PeerIdentifier, Data) async -> Void)?

    public init() {}

    public func send(to peer: PeerIdentifier, data: Data) async throws {
        if shouldFail {
            throw failError
        }
        sentMessages.append((peer, data))
    }

 /// 配置发送失败
    public func setShouldFail(_ fail: Bool, error: Error? = nil) {
        shouldFail = fail
        if let error = error {
            failError = error
        }
    }

 /// 模拟接收消息
    public func simulateReceive(from peer: PeerIdentifier, data: Data) async {
        await messageHandler?(peer, data)
    }

 /// 设置消息处理回调
    public func setMessageHandler(
        _ handler: @escaping @Sendable (PeerIdentifier, Data) async -> Void
    ) {
        messageHandler = handler
    }

 /// 清除发送记录
    public func clearSentMessages() {
        sentMessages.removeAll()
    }

 /// 获取发送消息数量
    public func getSentMessageCount() -> Int {
        sentMessages.count
    }
}
