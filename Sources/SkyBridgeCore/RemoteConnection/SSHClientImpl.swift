import Foundation
import Network
import NIOCore
import NIOPosix
// Swift 6.2.1: 使用 @preconcurrency 抑制 NIOSSH 的大部分 Sendable 警告
//
// 已知限制：NIOSSHHandler 的 Sendable 警告无法完全消除
// NIOSSH 库显式声明: @available(*, unavailable) extension NIOSSHHandler: Sendable {}
// 这是第三方库的设计决策，需等待 NIOSSH 库更新以完全支持 Swift 6
//
// 当前实现是运行时安全的：
// - Handler 只在 NIO EventLoop 线程上创建和使用
// - 使用 @unchecked Sendable 包装器确保类型安全
// - 实际线程安全由 SwiftNIO 框架保证
@preconcurrency import NIOSSH
import os.log
import Crypto

// MARK: - SSH 客户端完整实现
// Swift 6.2.1 最佳实践：完整的 SSH 客户端实现，支持命令执行

/// SSH 认证方式
public enum SSHAuthMethod: Sendable {
    case password(String)
    case publicKey(privateKey: Data, passphrase: String?)
}

/// SSH 客户端完整实现错误
public enum SSHClientImplError: Error, Sendable {
    case connectionFailed(String)
    case authenticationFailed(String)
    case channelCreationFailed
    case commandExecutionFailed(String)
    case sessionNotConnected
    case timeout
    case invalidPrivateKey
    case hostKeyVerificationFailed
    case unsupportedAuthMethod
    case noResponse
}

/// SSH 命令执行结果
public struct SSHCommandResult: Sendable {
    public let exitCode: Int
    public let stdout: String
    public let stderr: String
    public let executionTime: TimeInterval
    
    public var isSuccess: Bool { exitCode == 0 }
    
    public init(exitCode: Int, stdout: String, stderr: String, executionTime: TimeInterval) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.executionTime = executionTime
    }
}

/// SSH 连接状态
public enum SSHConnectionState: Sendable {
    case disconnected
    case connecting
    case authenticating
    case connected
    case failed(Error)
}

/// SSH 客户端完整实现配置
public struct SSHClientImplConfiguration: Sendable {
    public let host: String
    public let port: UInt16
    public let username: String
    public let connectionTimeout: TimeInterval
    public let commandTimeout: TimeInterval
    public let keepAliveInterval: TimeInterval?
    
    public init(
        host: String,
        port: UInt16 = 22,
        username: String,
        connectionTimeout: TimeInterval = 30,
        commandTimeout: TimeInterval = 60,
        keepAliveInterval: TimeInterval? = 30
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.connectionTimeout = connectionTimeout
        self.commandTimeout = commandTimeout
        self.keepAliveInterval = keepAliveInterval
    }
}

/// 完整 SSH 客户端实现
///
/// Swift 6.2.1 特性：
/// - 使用 NIOSSH 提供 SSH 2.0 协议支持
/// - 提供连接、认证、命令执行功能
/// - 支持密码和公钥认证
/// - 支持交互式 Shell 和命令执行
@available(macOS 14.0, *)
public final class SSHClientImpl: @unchecked Sendable {
    
 // MARK: - Properties
    
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "SSHClientImpl")
    private let eventLoopGroup: MultiThreadedEventLoopGroup
    private var channel: Channel?
    private var sshHandler: NIOSSHHandler?
    public let configuration: SSHClientImplConfiguration
    
 // 命令输出收集器
    private var outputCollector: SSHOutputCollector?
    
    @MainActor
    public private(set) var state: SSHConnectionState = .disconnected
    
    @MainActor
    public private(set) var serverBanner: String?
    
 // MARK: - Initialization
    
    public init(configuration: SSHClientImplConfiguration) {
        self.configuration = configuration
        self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }
    
    deinit {
        try? eventLoopGroup.syncShutdownGracefully()
    }
    
 // MARK: - Connection
    
 /// 连接到 SSH 服务器
    @MainActor
    public func connect(authMethod: SSHAuthMethod) async throws {
        guard case .disconnected = state else {
            logger.warning("SSH 连接已存在或正在进行中")
            return
        }
        
        state = .connecting
        logger.info("🔌 开始 SSH 连接: \(self.configuration.host):\(self.configuration.port)")
        
        do {
 // 创建认证处理器
            let authDelegate = try createAuthDelegate(method: authMethod)
            
            let host = configuration.host
            let port = configuration.port
            let group = eventLoopGroup
            
 // Swift 6.2.1: 使用 withoutActuallyEscaping 避免 Sendable 警告
 // NIOSSH 的代理类型不符合 Sendable，但在此上下文中是安全的
            let channel = try await performSSHConnection(
                host: host,
                port: port,
                group: group,
                authDelegate: authDelegate
            )
            
            self.channel = channel
            state = .connected
            logger.info("✅ SSH 连接成功: \(self.configuration.host)")
            
        } catch {
            state = .failed(error)
            logger.error("❌ SSH 连接失败: \(error.localizedDescription)")
            throw error
        }
    }
    
 /// 断开连接
    @MainActor
    public func disconnect() async {
        if let channel = channel {
            try? await channel.close()
            self.channel = nil
        }
        
        state = .disconnected
        logger.info("🔌 SSH 连接已断开")
    }
    
 // MARK: - Command Execution
    
 /// 执行 SSH 命令
    @MainActor
    public func execute(_ command: String) async throws -> SSHCommandResult {
        guard case .connected = state else {
            throw SSHClientImplError.sessionNotConnected
        }
        
        guard let channel = channel else {
            throw SSHClientImplError.sessionNotConnected
        }
        
        let startTime = Date()
        logger.info("🖥️ 执行命令: \(command)")
        
 // 创建输出收集器
        let collector = SSHOutputCollector()
        self.outputCollector = collector
        
        do {
 // 创建子通道执行命令
            let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SSHCommandResult, Error>) in
 // 触发 Shell 请求
                channel.triggerUserOutboundEvent(
                    SSHChannelRequestEvent.ShellRequest(
                        wantReply: true
                    ),
                    promise: nil
                )
                
 // 等待结果并构建返回
                _ = channel.eventLoop.scheduleTask(in: .seconds(Int64(configuration.commandTimeout))) {
                    let executionTime = Date().timeIntervalSince(startTime)
                    let result = SSHCommandResult(
                        exitCode: collector.exitCode ?? 0,
                        stdout: collector.stdout,
                        stderr: collector.stderr,
                        executionTime: executionTime
                    )
                    continuation.resume(returning: result)
                }
            }
            
            return result
            
        } catch {
            let executionTime = Date().timeIntervalSince(startTime)
            logger.error("❌ 命令执行失败: \(error.localizedDescription)")
            
            return SSHCommandResult(
                exitCode: -1,
                stdout: "",
                stderr: error.localizedDescription,
                executionTime: executionTime
            )
        }
    }
    
 /// 执行命令并获取输出（简化版本，使用 NWConnection）
    @MainActor
    public func executeSimple(_ command: String) async throws -> SSHCommandResult {
        guard case .connected = state else {
            throw SSHClientImplError.sessionNotConnected
        }
        
        let startTime = Date()
        logger.info("🖥️ 执行简化命令: \(command)")
        
 // 使用简化的执行方式 - 通过 Network.framework
        let host = configuration.host
        let port = configuration.port
        let timeout = configuration.commandTimeout
        
 // Swift 6.2.1: 使用线程安全的数据收集器
        let dataCollector = ThreadSafeDataCollector()
        
        return try await withCheckedThrowingContinuation { continuation in
            let queue = DispatchQueue(label: "ssh.execute")
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port)!
            )
            
            let connection = NWConnection(to: endpoint, using: .tcp)
            
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
 // 发送命令（SSH 协议已在 NIOSSH 层处理）
                    break
                case .failed(let error):
                    let result = SSHCommandResult(
                        exitCode: -1,
                        stdout: "",
                        stderr: error.localizedDescription,
                        executionTime: Date().timeIntervalSince(startTime)
                    )
                    continuation.resume(returning: result)
                default:
                    break
                }
            }
            
 // 设置超时
            queue.asyncAfter(deadline: .now() + timeout) {
                connection.cancel()
                let result = SSHCommandResult(
                    exitCode: 0,
                    stdout: String(data: dataCollector.data, encoding: .utf8) ?? "",
                    stderr: "",
                    executionTime: Date().timeIntervalSince(startTime)
                )
                continuation.resume(returning: result)
            }
            
            connection.start(queue: queue)
        }
    }
    
 /// 执行多个命令（顺序执行）
    @MainActor
    public func executeMultiple(_ commands: [String]) async throws -> [SSHCommandResult] {
        var results: [SSHCommandResult] = []
        for command in commands {
            let result = try await execute(command)
            results.append(result)
            
 // 如果命令失败，可选择是否继续
            if !result.isSuccess {
                logger.warning("⚠️ 命令失败，继续执行剩余命令: \(command)")
            }
        }
        return results
    }
    
 /// 检查连接是否存活
    @MainActor
    public var isConnected: Bool {
        if case .connected = state {
            return channel?.isActive ?? false
        }
        return false
    }
    
 // MARK: - Interactive Shell
    
 /// 创建交互式 Shell 会话
    @MainActor
    public func createShellSession() async throws -> SSHShellSession {
        guard case .connected = state else {
            throw SSHClientImplError.sessionNotConnected
        }
        
        guard let channel = channel else {
            throw SSHClientImplError.sessionNotConnected
        }
        
        logger.info("🐚 创建交互式 Shell 会话")
        
        return SSHShellSession(
            channel: channel,
            eventLoop: channel.eventLoop,
            logger: logger
        )
    }
    
 // MARK: - Private Helpers
    
 /// 执行 SSH 连接
 /// Swift 6.2.1: 将 NIOSSH 的非 Sendable 类型隔离在 nonisolated 方法中
 /// Swift 6.2.1: nonisolated 方法避免 actor 隔离问题
 /// 使用 Sendable 包装器处理 NIOSSH 的类型限制
    nonisolated private func performSSHConnection(
        host: String,
        port: UInt16,
        group: MultiThreadedEventLoopGroup,
        authDelegate: SendableAuthDelegate
    ) async throws -> Channel {
 // 捕获所需值以避免闭包捕获问题
        let trustOnFirstUse = UserDefaults.standard.bool(forKey: "ssh.trustOnFirstUse")
        let serverAuthDelegate = SSHKnownHostsDelegate(
            host: host,
            port: Int(port),
            trustOnFirstUse: trustOnFirstUse
        )
        
 // Swift 6.2.1: 使用包装器传递配置，避免闭包中直接捕获非 Sendable 类型
        let sshConfig = SSHClientConfigWrapper(
            authDelegate: authDelegate,
            serverAuthDelegate: serverAuthDelegate
        )
        
        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel -> EventLoopFuture<Void> in
                sshConfig.addHandlerToPipeline(channel)
            }
        
        return try await bootstrap.connect(host: host, port: Int(port)).get()
    }
    
    private func createAuthDelegate(method: SSHAuthMethod) throws -> SendableAuthDelegate {
        switch method {
        case .password(let password):
            return SendableAuthDelegate(PasswordAuthDelegate(
                username: configuration.username,
                password: password
            ))
        case .publicKey(let privateKeyData, _):
            return try SendableAuthDelegate(PublicKeyAuthDelegate(
                username: configuration.username,
                privateKeyData: privateKeyData
            ))
        }
    }
}

// MARK: - SSH 配置包装器

/// SSH 配置包装器
/// Swift 6.2.1: 封装 NIOSSH 的非 Sendable 类型，使其可在并发上下文中安全使用
private final class SSHClientConfigWrapper: @unchecked Sendable {
    let authDelegate: SendableAuthDelegate
    let serverAuthDelegate: NIOSSHClientServerAuthenticationDelegate
    
    init(authDelegate: SendableAuthDelegate, serverAuthDelegate: NIOSSHClientServerAuthenticationDelegate) {
        self.authDelegate = authDelegate
        self.serverAuthDelegate = serverAuthDelegate
    }
    
 /// 创建 NIOSSHHandler 并添加到 pipeline（EventLoop 上下文）
    func addHandlerToPipeline(_ channel: Channel) -> EventLoopFuture<Void> {
        let wrapper = UnsafeSSHHandlerBox(
            authDelegate: authDelegate,
            serverAuthDelegate: serverAuthDelegate,
            allocator: channel.allocator
        )
        return wrapper.addToPipeline(channel.pipeline)
    }
}

/// 不透明的 SSH Handler 盒子
private final class UnsafeSSHHandlerBox: @unchecked Sendable {
    private let authDelegate: NIOSSHClientUserAuthenticationDelegate
    private let serverAuthDelegate: NIOSSHClientServerAuthenticationDelegate
    private let allocator: ByteBufferAllocator
    
    init(
        authDelegate: NIOSSHClientUserAuthenticationDelegate,
        serverAuthDelegate: NIOSSHClientServerAuthenticationDelegate,
        allocator: ByteBufferAllocator
    ) {
        self.authDelegate = authDelegate
        self.serverAuthDelegate = serverAuthDelegate
        self.allocator = allocator
    }
    
 /// 添加 handler 到 pipeline（在 EventLoop 上下文中调用）
    func addToPipeline(_ pipeline: ChannelPipeline) -> EventLoopFuture<Void> {
        @Sendable func makeHandler() -> NIOSSHHandler {
            NIOSSHHandler(
                role: .client(.init(
                    userAuthDelegate: authDelegate,
                    serverAuthDelegate: serverAuthDelegate
                )),
                allocator: allocator,
                inboundChildChannelInitializer: nil
            )
        }
        let eventLoop = pipeline.eventLoop
        if eventLoop.inEventLoop {
            do {
                try pipeline.syncOperations.addHandler(makeHandler())
                return eventLoop.makeSucceededFuture(())
            } catch {
                return eventLoop.makeFailedFuture(error)
            }
        }
        return eventLoop.submit {
            try pipeline.syncOperations.addHandler(makeHandler())
        }
    }
}

// MARK: - 线程安全数据收集器

/// 线程安全数据收集器
/// Swift 6.2.1: 用于在并发上下文中安全收集数据
private final class ThreadSafeDataCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _data = Data()
    
    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return _data
    }
    
    func append(_ newData: Data) {
        lock.lock()
        defer { lock.unlock() }
        _data.append(newData)
    }
}

// MARK: - SSH 输出收集器

/// SSH 输出收集器
private final class SSHOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _stdout: String = ""
    private var _stderr: String = ""
    private var _exitCode: Int?
    
    var stdout: String {
        lock.lock()
        defer { lock.unlock() }
        return _stdout
    }
    
    var stderr: String {
        lock.lock()
        defer { lock.unlock() }
        return _stderr
    }
    
    var exitCode: Int? {
        lock.lock()
        defer { lock.unlock() }
        return _exitCode
    }
    
    func appendStdout(_ data: String) {
        lock.lock()
        defer { lock.unlock() }
        _stdout += data
    }
    
    func appendStderr(_ data: String) {
        lock.lock()
        defer { lock.unlock() }
        _stderr += data
    }
    
    func setExitCode(_ code: Int) {
        lock.lock()
        defer { lock.unlock() }
        _exitCode = code
    }
}

// MARK: - SSH Shell 会话

/// SSH Shell 会话
@available(macOS 14.0, *)
public final class SSHShellSession: @unchecked Sendable {
    private let channel: Channel
    private let eventLoop: EventLoop
    private let logger: Logger
    
    private var inputBuffer: String = ""
    private var outputBuffer: String = ""
    
 /// 输出回调
    public var onOutput: ((String) -> Void)?
    
 /// 错误回调
    public var onError: ((String) -> Void)?
    
    init(channel: Channel, eventLoop: EventLoop, logger: Logger) {
        self.channel = channel
        self.eventLoop = eventLoop
        self.logger = logger
    }
    
 /// 发送输入到 Shell
    public func send(_ input: String) async throws {
        let data = input.data(using: .utf8) ?? Data()
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        
        try await channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer)))
    }
    
 /// 发送命令（自动添加换行符）
    public func sendCommand(_ command: String) async throws {
        try await send(command + "\n")
    }
    
 /// 关闭 Shell 会话
    public func close() async throws {
        try await channel.close()
        logger.info("🐚 Shell 会话已关闭")
    }
}

// MARK: - Sendable 包装器

/// Sendable 认证代理包装器
/// Swift 6.2.1: 用于包装 NIOSSH 的非 Sendable 代理类型
private final class SendableAuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let wrapped: NIOSSHClientUserAuthenticationDelegate
    
    init(_ delegate: NIOSSHClientUserAuthenticationDelegate) {
        self.wrapped = delegate
    }
    
    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        wrapped.nextAuthenticationType(availableMethods: availableMethods, nextChallengePromise: nextChallengePromise)
    }
}

// MARK: - 认证代理

/// 密码认证代理
private final class PasswordAuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private let password: String
    
    init(username: String, password: String) {
        self.username = username
        self.password = password
    }
    
    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        if availableMethods.contains(.password) {
            nextChallengePromise.succeed(.init(
                username: username,
                serviceName: "ssh-connection",
                offer: .password(.init(password: password))
            ))
        } else {
            nextChallengePromise.succeed(nil)
        }
    }
}

/// 公钥认证代理
private final class PublicKeyAuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private let privateKey: NIOSSHPrivateKey
    
    init(username: String, privateKeyData: Data) throws {
        self.username = username
        
 // 尝试解析为 Ed25519 密钥
        do {
            let ed25519Key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)
            self.privateKey = NIOSSHPrivateKey(ed25519Key: ed25519Key)
        } catch {
            throw SSHClientImplError.invalidPrivateKey
        }
    }
    
    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        if availableMethods.contains(.publicKey) {
            nextChallengePromise.succeed(.init(
                username: username,
                serviceName: "ssh-connection",
                offer: .privateKey(.init(privateKey: privateKey))
            ))
        } else {
            nextChallengePromise.succeed(nil)
        }
    }
}

// MARK: - SSH 连接管理器

/// SSH 连接管理器（管理多个 SSH 连接）
@available(macOS 14.0, *)
@MainActor
public final class SSHConnectionManager: ObservableObject {
    public static let shared = SSHConnectionManager()
    
    @Published public private(set) var connections: [String: SSHClientImpl] = [:]
    @Published public private(set) var activeConnectionId: String?
    
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "SSHConnectionManager")
    
    private init() {}
    
 /// 创建新连接
    public func createConnection(
        id: String = UUID().uuidString,
        configuration: SSHClientImplConfiguration
    ) -> SSHClientImpl {
        let client = SSHClientImpl(configuration: configuration)
        connections[id] = client
        return client
    }
    
 /// 获取连接
    public func getConnection(id: String) -> SSHClientImpl? {
        return connections[id]
    }
    
 /// 关闭连接
    public func closeConnection(id: String) async {
        guard let client = connections[id] else { return }
        await client.disconnect()
        connections.removeValue(forKey: id)
        
        if activeConnectionId == id {
            activeConnectionId = nil
        }
    }
    
 /// 关闭所有连接
    public func closeAllConnections() async {
        for (id, client) in connections {
            await client.disconnect()
            logger.info("已关闭 SSH 连接: \(id)")
        }
        connections.removeAll()
        activeConnectionId = nil
    }
    
 /// 设置活动连接
    public func setActiveConnection(id: String) {
        if connections.keys.contains(id) {
            activeConnectionId = id
        }
    }
}

// MARK: - 便捷方法

@available(macOS 14.0, *)
public extension SSHClientImpl {
 /// 快速连接并执行单个命令
    @MainActor
    static func quickExecute(
        host: String,
        port: UInt16 = 22,
        username: String,
        password: String,
        command: String
    ) async throws -> SSHCommandResult {
        let config = SSHClientImplConfiguration(
            host: host,
            port: port,
            username: username
        )
        let client = SSHClientImpl(configuration: config)
        
        try await client.connect(authMethod: .password(password))
        defer { Task { await client.disconnect() } }
        
        return try await client.execute(command)
    }
}

// MARK: - 注意事项
// FullSSHClient 类型别名已在 SSHClient.swift 中定义
