//
// STUNClient.swift
// SkyBridgeCompassiOS
//
// STUN 客户端 - 用于 NAT 类型检测和地址发现
// 支持 RFC 5389 STUN 协议
//

import Foundation
import Network
import os

// MARK: - STUN Result

/// STUN 查询结果
public struct STUNResult: Sendable {
    public let publicAddress: String
    public let publicPort: UInt16
    public let natType: NATType
    public let localAddress: String?
    public let localPort: UInt16?
    
    public init(
        publicAddress: String,
        publicPort: UInt16,
        natType: NATType = .unknown,
        localAddress: String? = nil,
        localPort: UInt16? = nil
    ) {
        self.publicAddress = publicAddress
        self.publicPort = publicPort
        self.natType = natType
        self.localAddress = localAddress
        self.localPort = localPort
    }
}

// MARK: - STUN Error

/// STUN 错误
public enum STUNError: Error, LocalizedError, Sendable, Equatable {
    case connectionFailed
    case timeout
    case invalidResponse
    case noMappedAddress
    case serverUnreachable
    case invalidConfiguration
    
    public var errorDescription: String? {
        switch self {
        case .connectionFailed: return "STUN 连接失败"
        case .timeout: return "STUN 请求超时"
        case .invalidResponse: return "无效的 STUN 响应"
        case .noMappedAddress: return "未能获取映射地址"
        case .serverUnreachable: return "STUN 服务器不可达"
        case .invalidConfiguration: return "STUN 超时配置无效"
        }
    }
}

protocol IOSSTUNDatagramConnection: AnyObject, Sendable {
    func setStateUpdateHandler(
        _ handler: @escaping @Sendable (NWConnection.State) -> Void
    )
    func clearStateUpdateHandler()
    func start()
    func send(
        _ data: Data,
        completion: @escaping @Sendable (Error?) -> Void
    )
    func receiveMessage(
        completion: @escaping @Sendable (Data?, Bool, Error?) -> Void
    )
    func cancel()
}

private final class NWIOSSTUNDatagramConnection: IOSSTUNDatagramConnection, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.skybridge.stun", qos: .utility)

    init(endpoint: NWEndpoint) {
        let parameters = NWParameters.udp
        parameters.includePeerToPeer = true
        connection = NWConnection(to: endpoint, using: parameters)
    }

    func setStateUpdateHandler(
        _ handler: @escaping @Sendable (NWConnection.State) -> Void
    ) {
        connection.stateUpdateHandler = handler
    }

    func clearStateUpdateHandler() {
        connection.stateUpdateHandler = nil
    }

    func start() {
        connection.start(queue: queue)
    }

    func send(
        _ data: Data,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        connection.send(content: data, completion: .contentProcessed(completion))
    }

    func receiveMessage(
        completion: @escaping @Sendable (Data?, Bool, Error?) -> Void
    ) {
        connection.receiveMessage { data, _, isComplete, error in
            completion(data, isComplete, error)
        }
    }

    func cancel() {
        connection.cancel()
    }
}

private final class IOSSTUNQueryCompletion: @unchecked Sendable {
    private enum Stage {
        case waitingForReady
        case sending
        case receiving
        case completed
    }

    private struct State {
        var stage = Stage.waitingForReady
        var timeoutTask: Task<Void, Never>?
        var connection: (any IOSSTUNDatagramConnection)?
    }

    private let state: OSAllocatedUnfairLock<State>
    private let continuation: CheckedContinuation<STUNMappedAddress, Error>

    init(
        continuation: CheckedContinuation<STUNMappedAddress, Error>,
        connection: any IOSSTUNDatagramConnection
    ) {
        self.continuation = continuation
        state = OSAllocatedUnfairLock(
            initialState: State(connection: connection)
        )
    }

    func beginSending() -> Bool {
        state.withLock { state in
            guard state.stage == .waitingForReady else { return false }
            state.stage = .sending
            return true
        }
    }

    func beginReceiving() -> Bool {
        state.withLock { state in
            guard state.stage == .sending else { return false }
            state.stage = .receiving
            return true
        }
    }

    func installTimeoutTask(_ task: Task<Void, Never>) {
        let shouldCancel = state.withLock { state -> Bool in
            guard state.stage != .completed else { return true }
            state.timeoutTask = task
            return false
        }
        if shouldCancel {
            task.cancel()
        }
    }

    func finish(_ result: Result<STUNMappedAddress, Error>) {
        let completion = state.withLock { state -> (
            shouldResume: Bool,
            timeoutTask: Task<Void, Never>?,
            connection: (any IOSSTUNDatagramConnection)?
        ) in
            guard state.stage != .completed else { return (false, nil, nil) }
            state.stage = .completed
            defer {
                state.timeoutTask = nil
                state.connection = nil
            }
            return (true, state.timeoutTask, state.connection)
        }
        guard completion.shouldResume else { return }

        // Cleanup is deliberately outside the lock: NWConnection.cancel() may
        // synchronously re-enter its state handler.
        completion.timeoutTask?.cancel()
        completion.connection?.clearStateUpdateHandler()
        completion.connection?.cancel()
        continuation.resume(with: result)
    }
}

private final class WeakIOSSTUNDatagramConnection: @unchecked Sendable {
    weak var value: (any IOSSTUNDatagramConnection)?

    init(_ value: any IOSSTUNDatagramConnection) {
        self.value = value
    }
}

private final class IOSSTUNQueryCancellationRelay: @unchecked Sendable {
    private struct State {
        var isCancelled = false
        var completion: IOSSTUNQueryCompletion?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Registers the completion boundary. Returning `false` means cancellation
    /// arrived before registration and the caller must finish immediately.
    func register(_ completion: IOSSTUNQueryCompletion) -> Bool {
        state.withLock { state in
            guard !state.isCancelled else { return false }
            state.completion = completion
            return true
        }
    }

    func cancel() {
        let completion = state.withLock { state -> IOSSTUNQueryCompletion? in
            state.isCancelled = true
            return state.completion
        }
        completion?.finish(.failure(CancellationError()))
    }
}

enum IOSSTUNQueryPipeline {
    static func query(
        connection: any IOSSTUNDatagramConnection,
        timeout: Duration
    ) async throws -> STUNMappedAddress {
        let cancellationRelay = IOSSTUNQueryCancellationRelay()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let completion = IOSSTUNQueryCompletion(
                    continuation: continuation,
                    connection: connection
                )
                let weakConnection = WeakIOSSTUNDatagramConnection(connection)
                let request = STUNMessageCodec.makeBindingRequest()

                // Install the handler before publishing the completion to the
                // cancellation relay. If cancellation won the race, finish()
                // can now remove every callback installed by this operation.
                connection.setStateUpdateHandler { state in
                    switch state {
                    case .ready:
                        guard completion.beginSending() else { return }
                        guard let activeConnection = weakConnection.value else {
                            completion.finish(.failure(STUNError.connectionFailed))
                            return
                        }
                        activeConnection.send(request.payload) { sendError in
                            guard sendError == nil else {
                                completion.finish(.failure(STUNError.connectionFailed))
                                return
                            }
                            guard completion.beginReceiving() else { return }
                            guard let activeConnection = weakConnection.value else {
                                completion.finish(.failure(STUNError.connectionFailed))
                                return
                            }
                            activeConnection.receiveMessage { data, isComplete, receiveError in
                                guard receiveError == nil else {
                                    completion.finish(.failure(STUNError.connectionFailed))
                                    return
                                }
                                guard isComplete, let data else {
                                    completion.finish(.failure(STUNError.invalidResponse))
                                    return
                                }
                                do {
                                    let mappedAddress = try STUNMessageCodec.parseBindingResponse(
                                        data,
                                        expectedTransactionID: request.transactionID
                                    )
                                    completion.finish(.success(mappedAddress))
                                } catch STUNMessageCodecError.missingMappedAddress {
                                    completion.finish(.failure(STUNError.noMappedAddress))
                                } catch {
                                    completion.finish(.failure(STUNError.invalidResponse))
                                }
                            }
                        }
                    case .failed, .cancelled:
                        completion.finish(.failure(STUNError.connectionFailed))
                    default:
                        break
                    }
                }

                guard cancellationRelay.register(completion) else {
                    completion.finish(.failure(CancellationError()))
                    return
                }

                let timeoutTask = Task { @Sendable in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch is CancellationError {
                        return
                    } catch {
                        completion.finish(.failure(STUNError.connectionFailed))
                        return
                    }
                    completion.finish(.failure(STUNError.timeout))
                }
                completion.installTimeoutTask(timeoutTask)

                guard !Task.isCancelled else {
                    cancellationRelay.cancel()
                    return
                }
                connection.start()
            }
        } onCancel: {
            cancellationRelay.cancel()
        }
    }
}

// MARK: - STUN Client

/// STUN 客户端
@available(iOS 17.0, *)
public actor STUNClient {
    typealias ServerQuery = @Sendable (STUNServer, Duration) async throws -> STUNMappedAddress
    
    // MARK: - Properties
    
    private let servers: [STUNServer]
    private let timeout: TimeInterval
    private let serverQuery: ServerQuery
    
    // MARK: - Initialization
    
    public init(servers: [STUNServer] = STUNServer.defaultServers, timeout: TimeInterval = 5.0) {
        self.servers = servers
        self.timeout = timeout
        serverQuery = Self.liveServerQuery
    }

    init(
        servers: [STUNServer],
        timeout: TimeInterval,
        serverQuery: @escaping ServerQuery
    ) {
        self.servers = servers
        self.timeout = timeout
        self.serverQuery = serverQuery
    }
    
    // MARK: - Public Methods
    
    /// 发现公网地址
    public func discoverPublicAddress() async throws -> STUNResult {
        _ = try validatedTimeout()
        for server in servers {
            do {
                let result = try await queryServer(server)
                SkyBridgeLogger.shared.info("✅ STUN 发现公网地址: \(result.publicAddress):\(result.publicPort)")
                return result
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as STUNError {
                guard error != .invalidConfiguration else { throw error }
                SkyBridgeLogger.shared.warning("⚠️ STUN 服务器 \(server.host) 失败: \(error.localizedDescription)")
                continue
            } catch {
                // Preserve unexpected programmer/runtime failures instead of
                // disguising them as an unreachable STUN server.
                throw error
            }
        }
        
        throw STUNError.serverUnreachable
    }
    
    /// 检测 NAT 类型
    public func detectNATType() async throws -> NATType {
        _ = try validatedTimeout()
        // Two distinct destinations can provide evidence of endpoint-dependent
        // mapping, but equal mappings alone cannot prove full-cone behavior.
        // RFC 5780 filtering tests are required before returning a cone type.
        guard servers.count >= 2 else { return .unknown }
        let firstResult = try await queryServer(servers[0])
        let secondResult = try await queryServer(servers[1])
        if firstResult.publicAddress != secondResult.publicAddress ||
            firstResult.publicPort != secondResult.publicPort {
            return .symmetric
        }
        return .unknown
    }
    
    // MARK: - Private Methods
    
    private func queryServer(_ server: STUNServer) async throws -> STUNResult {
        let queryTimeout = try validatedTimeout()
        let mappedAddress = try await serverQuery(server, queryTimeout)
        return STUNResult(
            publicAddress: mappedAddress.address,
            publicPort: mappedAddress.port
        )
    }

    private func validatedTimeout() throws -> Duration {
        guard timeout.isFinite, timeout > 0, timeout <= 300 else {
            throw STUNError.invalidConfiguration
        }
        return .seconds(timeout)
    }

    private static func liveServerQuery(
        _ server: STUNServer,
        _ timeout: Duration
    ) async throws -> STUNMappedAddress {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(server.host),
            port: NWEndpoint.Port(integerLiteral: server.port)
        )
        let connection = NWIOSSTUNDatagramConnection(endpoint: endpoint)
        return try await IOSSTUNQueryPipeline.query(
            connection: connection,
            timeout: timeout
        )
    }
}

// MARK: - NAT Traversal Helper

/// NAT 穿透辅助
@available(iOS 17.0, *)
public actor NATTraversalHelper {
    
    private let stunClient: STUNClient
    private var cachedNATType: NATType?
    private var cachedPublicEndpoint: (address: String, port: UInt16)?
    private var lastDiscoveryTime: Date?
    
    public init(stunClient: STUNClient = STUNClient()) {
        self.stunClient = stunClient
    }
    
    /// 获取公网端点（带缓存）
    public func getPublicEndpoint(forceRefresh: Bool = false) async throws -> (address: String, port: UInt16) {
        // 检查缓存是否有效（5分钟内）
        if !forceRefresh,
           let cached = cachedPublicEndpoint,
           let lastTime = lastDiscoveryTime,
           Date().timeIntervalSince(lastTime) < 300 {
            return cached
        }
        
        let result = try await stunClient.discoverPublicAddress()
        cachedPublicEndpoint = (result.publicAddress, result.publicPort)
        lastDiscoveryTime = Date()
        
        return (result.publicAddress, result.publicPort)
    }
    
    /// 获取 NAT 类型（带缓存）
    public func getNATType(forceRefresh: Bool = false) async throws -> NATType {
        if !forceRefresh, let cached = cachedNATType {
            return cached
        }
        
        let natType = try await stunClient.detectNATType()
        cachedNATType = natType
        
        return natType
    }
    
    /// 判断是否可以进行 P2P 直连
    public func canEstablishDirectConnection(with peerNATType: NATType) async throws -> Bool {
        // 获取本地 NAT 类型
        let localNATType: NATType
        if let cached = cachedNATType {
            localNATType = cached
        } else {
            localNATType = try await getNATType()
        }
        
        // NAT 兼容性矩阵
        return checkNATCompatibility(local: localNATType, peer: peerNATType)
    }
    
    /// 检查 NAT 兼容性
    private func checkNATCompatibility(local: NATType, peer: NATType) -> Bool {
        switch (local, peer) {
        case (.noNAT, _), (_, .noNAT):
            return true
        case (.fullCone, .fullCone), (.fullCone, .restrictedCone), (.restrictedCone, .fullCone):
            return true
        case (.restrictedCone, .restrictedCone):
            return true
        case (.portRestrictedCone, .fullCone), (.fullCone, .portRestrictedCone):
            return true
        case (.symmetric, .fullCone), (.fullCone, .symmetric):
            return true
        case (.symmetric, .symmetric):
            return false // 需要 TURN 服务器
        default:
            return false
        }
    }
}
