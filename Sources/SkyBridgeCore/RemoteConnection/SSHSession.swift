import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Combine
import OSLog
@preconcurrency import Crypto

/// 基于 SwiftNIO SSH 的会话管理器
/// - 中文说明：负责建立 SSH 连接、进行密码认证、打开交互式 Shell（PTY），并将输出流发布到 UI。
@MainActor
public final class SSHSession: ObservableObject {
    @Published public private(set) var isConnected: Bool = false
    @Published public private(set) var outputText: String = ""

    public let host: String
    public let port: Int
    public let username: String

    private var password: String = ""
    private var group: EventLoopGroup?
    private var channel: Channel?
    private var childChannel: Channel?
 /// 管理已打开的 DirectTCPIP 转发通道
    private var portForwards: [UUID: Channel] = [:]
    private var keepAliveTask: RepeatedTask?
    private var reconnecting = false
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "SSHSession")
    private let trustOnFirstUseAllowed: Bool = UserDefaults.standard.bool(forKey: "ssh.trustOnFirstUse")

    public init(host: String, port: Int, username: String) {
        self.host = host
        self.port = port
        self.username = username
    }

 /// 连接并启动交互式 Shell
    public func connect(password: String) async throws {
        self.password = password
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group

        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let sync = channel.pipeline.syncOperations
                    let userAuth = SimplePasswordDelegate(username: self.username, password: password)
                    let hostKeyDelegate = SSHKnownHostsDelegate(
                        host: self.host,
                        port: self.port,
                        trustOnFirstUse: self.trustOnFirstUseAllowed
                    )
                    let config = SSHClientConfiguration(userAuthDelegate: userAuth, serverAuthDelegate: hostKeyDelegate)
                    let ssh = NIOSSHHandler(role: .client(config), allocator: channel.allocator, inboundChildChannelInitializer: nil)
                    try sync.addHandler(ssh)
 // 错误处理器：在管道错误发生时记录日志（重连由 closeFuture 统一触发）
                    let pipelineLogger = Logger(subsystem: "com.skybridge.compass", category: "SSHSessionPipeline")
                    try sync.addHandler(SSHErrorHandler(onError: { err in
 // 中文说明：避免捕获 @MainActor self 导致严格并发警告，改为直接记录日志。
                        pipelineLogger.error("SSH 管道错误（主通道）：\(err.localizedDescription)")
                    }))

 // 打开一个 Session 子通道
                    let p = channel.eventLoop.makePromise(of: Channel.self)
                    ssh.createChannel(p, channelType: .session) { child, type in
                        guard case .session = type else {
                            return channel.eventLoop.makeFailedFuture(SSHClientError.invalidChannelType)
                        }
                        return child.eventLoop.makeCompletedFuture {
                            let childSync = child.pipeline.syncOperations
                            try childSync.addHandler(SSHWrapperHandler())
                            try childSync.addHandler(SSHTerminalHandler { [weak self] buf in
                                guard let self else { return }
                                if let s = buf.getString(at: buf.readerIndex, length: buf.readableBytes) {
                                    Task { @MainActor in
                                        self.outputText.append(s)
                                    }
                                }
                            })

 // 请求 PTY 与 Shell
                            let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
                                wantReply: true,
                                term: "xterm-256color",
                                terminalCharacterWidth: 120,
                                terminalRowHeight: 40,
                                terminalPixelWidth: 0,
                                terminalPixelHeight: 0,
                                terminalModes: SSHTerminalModes([:])
                            )
                            _ = child.triggerUserOutboundEvent(pty)
                            let shell = SSHChannelRequestEvent.ShellRequest(wantReply: true)
                            _ = child.triggerUserOutboundEvent(shell)
                        }
                    }

                    p.futureResult.whenSuccess { ch in
                        Task { @MainActor in
                            self.childChannel = ch
                            self.isConnected = true
                            self.logger.info("SSH Shell 子通道已建立")
                            self.startKeepAlive(ch)
                        }
 // 子通道关闭时触发重连
                        ch.closeFuture.whenComplete { [weak self] _ in
                            Task { @MainActor in
                                guard let self else { return }
                                self.logger.warning("SSH Shell 子通道已关闭，准备重连")
                                self.isConnected = false
                                self.scheduleReconnect()
                            }
                        }
                    }
                    p.futureResult.whenFailure { err in
                        Task { @MainActor in
                            self.logger.error("SSH 子通道建立失败：\(err.localizedDescription)")
                        }
                    }
                }
            }
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)

        let ch = try await bootstrap.connect(host: host, port: port).get()
        self.channel = ch
        Task { @MainActor in
            self.logger.info("SSH 主通道已连接：\(self.host):\(self.port)")
        }
 // 绑定关闭事件以触发重连
        ch.closeFuture.whenComplete { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isConnected = false
                self.logger.warning("SSH 主通道已关闭，准备重连")
                self.scheduleReconnect()
            }
        }
    }

 /// 发送一行输入到 Shell（自动追加换行）
    public func sendLine(_ line: String) {
        guard let child = childChannel else { return }
        var buf = child.allocator.buffer(capacity: line.utf8.count + 1)
        buf.writeString(line)
        buf.writeString("\n")
        child.writeAndFlush(buf, promise: nil)
    }

 /// 发送原始文本到 Shell（不追加换行）
 /// - Parameter text: 原始文本或控制序列（例如方向键的 ANSI 序列）
 /// 说明：用于传输特殊按键映射，避免自动追加换行导致行为不符合预期
    public func send(_ text: String) {
        guard let child = childChannel else { return }
        var buf = child.allocator.buffer(capacity: text.utf8.count)
        buf.writeString(text)
        child.writeAndFlush(buf, promise: nil)
    }

 /// 断开连接并清理资源
    public func disconnect() {
        if let child = childChannel {
            child.close(promise: nil)
            childChannel = nil
        }
        if let ch = channel {
            ch.close(promise: nil)
            channel = nil
        }
        keepAliveTask?.cancel()
        if let g = group {
            try? g.syncShutdownGracefully()
            group = nil
        }
        isConnected = false
    }

 // MARK: - 进阶功能
 /// 使用私钥进行认证（Ed25519 原始表示）
    public func connectWithEd25519Key(rawKey: Data) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group
        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let sync = channel.pipeline.syncOperations
                    let priv = try Curve25519.Signing.PrivateKey(rawRepresentation: rawKey)
                    let userAuth = SimplePrivateKeyDelegate(username: self.username, privateKey: NIOSSHPrivateKey(ed25519Key: priv))
                    let hostKeyDelegate = SSHKnownHostsDelegate(
                        host: self.host,
                        port: self.port,
                        trustOnFirstUse: self.trustOnFirstUseAllowed
                    )
                    let config = SSHClientConfiguration(userAuthDelegate: userAuth, serverAuthDelegate: hostKeyDelegate)
                    let ssh = NIOSSHHandler(role: .client(config), allocator: channel.allocator, inboundChildChannelInitializer: nil)
                    try sync.addHandler(ssh)
 // 错误处理器：记录密钥认证主通道错误（重连由 closeFuture 统一触发）
                    let pipelineLogger = Logger(subsystem: "com.skybridge.compass", category: "SSHSessionPipeline")
                    try sync.addHandler(SSHErrorHandler(onError: { err in
                        pipelineLogger.error("SSH 管道错误（密钥认证主通道）：\(err.localizedDescription)")
                    }))
                }
            }
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
        let ch = try await bootstrap.connect(host: host, port: port).get()
        self.channel = ch
        Task { @MainActor in self.logger.info("SSH 主通道已连接（密钥认证）：\(self.host):\(self.port)") }
 // 建立会话子通道与Shell
        try await openSessionShell()
 // 绑定关闭事件以触发重连
        ch.closeFuture.whenComplete { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isConnected = false
                self.logger.warning("SSH 主通道（密钥认证）已关闭，准备重连")
                self.scheduleReconnect()
            }
        }
    }

 /// 使用 PEM/OPENSSH 私钥进行认证（支持 OpenSSH/PKCS#8 Ed25519）
 /// - 参数 pem: 完整的 PEM 文本（含 BEGIN/END）
    public func connectWithPEM(_ pem: String) async throws {
 // 解析 PEM 为 Ed25519 私钥
        let priv = try SSHKeyImporter.importEd25519PrivateKey(fromPEM: pem)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group
        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let sync = channel.pipeline.syncOperations
                    let userAuth = SimplePrivateKeyDelegate(username: self.username, privateKey: NIOSSHPrivateKey(ed25519Key: priv))
                    let hostKeyDelegate = SSHKnownHostsDelegate(
                        host: self.host,
                        port: self.port,
                        trustOnFirstUse: self.trustOnFirstUseAllowed
                    )
                    let config = SSHClientConfiguration(userAuthDelegate: userAuth, serverAuthDelegate: hostKeyDelegate)
                    let ssh = NIOSSHHandler(role: .client(config), allocator: channel.allocator, inboundChildChannelInitializer: nil)
                    try sync.addHandler(ssh)
 // 错误处理器：记录 PEM 认证主通道错误（重连由 closeFuture 统一触发）
                    let pipelineLogger = Logger(subsystem: "com.skybridge.compass", category: "SSHSessionPipeline")
                    try sync.addHandler(SSHErrorHandler(onError: { err in
                        pipelineLogger.error("SSH 管道错误（PEM 认证主通道）：\(err.localizedDescription)")
                    }))
                }
            }
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)

        let ch = try await bootstrap.connect(host: host, port: port).get()
        self.channel = ch
        Task { @MainActor in self.logger.info("SSH 主通道已连接（PEM 密钥认证）：\(self.host):\(self.port)") }
        try await openSessionShell()
 // 绑定关闭事件以触发重连
        ch.closeFuture.whenComplete { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isConnected = false
                self.logger.warning("SSH 主通道（PEM 认证）已关闭，准备重连")
                self.scheduleReconnect()
            }
        }
    }

 /// 打开 DirectTCPIP 通道进行端口转发（客户端发起）
    public func openDirectTCPIP(targetHost: String, targetPort: Int) async throws -> Channel {
        guard let ch = channel else { throw SSHClientError.invalidChannelType }
        let promise = ch.eventLoop.makePromise(of: Channel.self)
        guard let originator = ch.remoteAddress else {
            throw SSHClientError.invalidData
        }
        let dt = SSHChannelType.DirectTCPIP(targetHost: targetHost, targetPort: targetPort, originatorAddress: originator)
        let ssh = try ch.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
        ssh.createChannel(promise, channelType: .directTCPIP(dt)) { child, type in
            guard case .directTCPIP = type else { return ch.eventLoop.makeFailedFuture(SSHClientError.invalidChannelType) }
            return child.eventLoop.makeCompletedFuture {
                let sync = child.pipeline.syncOperations
                try sync.addHandler(SSHWrapperHandler())
 // 子通道错误记录（无需捕获 self）
                let pipelineLogger = Logger(subsystem: "com.skybridge.compass", category: "SSHSessionPipeline")
                try sync.addHandler(SSHErrorHandler(onError: { err in
                    pipelineLogger.error("SSH 端口转发子通道错误：\(err.localizedDescription)")
                }))
            }
        }
        let directChannel = try await promise.futureResult.get()
        return directChannel
    }

    private func openSessionShell() async throws {
        guard let ch = channel else { throw SSHClientError.invalidChannelType }
        let p = ch.eventLoop.makePromise(of: Channel.self)
        let ssh = try ch.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
        ssh.createChannel(p, channelType: .session) { child, type in
            guard case .session = type else { return ch.eventLoop.makeFailedFuture(SSHClientError.invalidChannelType) }
            return child.eventLoop.makeCompletedFuture {
                let childSync = child.pipeline.syncOperations
                try childSync.addHandler(SSHWrapperHandler())
                try childSync.addHandler(SSHTerminalHandler { [weak self] buf in
                    guard let self else { return }
                    if let s = buf.getString(at: buf.readerIndex, length: buf.readableBytes) {
                        Task { @MainActor in self.outputText.append(s) }
                    }
                })
                let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
                    wantReply: true,
                    term: "xterm-256color",
                    terminalCharacterWidth: 120,
                    terminalRowHeight: 40,
                    terminalPixelWidth: 0,
                    terminalPixelHeight: 0,
                    terminalModes: SSHTerminalModes([:])
                )
                _ = child.triggerUserOutboundEvent(pty)
                let shell = SSHChannelRequestEvent.ShellRequest(wantReply: true)
                _ = child.triggerUserOutboundEvent(shell)
            }
        }
        let child = try await p.futureResult.get()
        Task { @MainActor in
            self.childChannel = child
            self.isConnected = true
            self.logger.info("SSH Shell 子通道已建立")
            self.startKeepAlive(child)
        }
 // 子通道关闭时触发重连
        child.closeFuture.whenComplete { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.logger.warning("SSH Shell 子通道已关闭，准备重连")
                self.isConnected = false
                self.scheduleReconnect()
            }
        }
    }

 // MARK: - 端口转发管理
 /// 开始端口转发（通过 SSH 服务器连接到目标主机端口）
    @discardableResult
    public func startPortForward(to targetHost: String, port targetPort: Int) async throws -> UUID {
        let forwardChannel = try await openDirectTCPIP(targetHost: targetHost, targetPort: targetPort)
        let id = UUID()
        portForwards[id] = forwardChannel
        forwardChannel.closeFuture.whenComplete { [weak self] _ in
            Task { @MainActor in self?.portForwards.removeValue(forKey: id) }
        }
        return id
    }

 /// 停止端口转发
    public func stopPortForward(id: UUID) {
        if let ch = portForwards[id] {
            ch.close(promise: nil)
            portForwards.removeValue(forKey: id)
        }
    }

 /// 心跳：周期性发送轻量数据保持连接活跃
    private func startKeepAlive(_ child: Channel) {
        let el = child.eventLoop
        let interval = RemoteDesktopSettingsManager.shared.settings.networkSettings.keepAliveInterval
        keepAliveTask?.cancel()
        keepAliveTask = el.scheduleRepeatedTask(initialDelay: .seconds(Int64(interval)), delay: .seconds(Int64(interval))) { _ in
            var buf = child.allocator.buffer(capacity: 1)
            buf.writeString(" ")
            child.writeAndFlush(buf, promise: nil)
        }
    }

 /// 按退避策略重连
    private func scheduleReconnect() {
        guard !reconnecting else { return }
        reconnecting = true
        let net = RemoteDesktopSettingsManager.shared.settings.networkSettings
        var delayMs = net.reconnectBackoffInitialMs
        let maxMs = net.reconnectBackoffMaxMs
        let multiplier = net.reconnectBackoffMultiplier
        Task { @MainActor [weak self] in
            var attempts = 0
            while attempts < net.maxReconnectAttempts {
                do {
                    guard let self else { return }
                    try await self.connect(password: self.password)
                    self.reconnecting = false
                    return
                } catch {
                    attempts += 1
                    try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                    delayMs = min(Int(Double(delayMs) * multiplier), maxMs)
                }
            }
            self?.reconnecting = false
        }
    }
}

// MARK: - 管道处理程序

/// 错误处理器：捕获管道错误并关闭通道
final class SSHErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Any
 /// 错误回调：用于上层触发重连或记录日志
    private let onError: ((Error) -> Void)?
    init(onError: ((Error) -> Void)? = nil) { self.onError = onError }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        SkyBridgeLogger.network.error("SSH 管道错误: \(String(describing: error), privacy: .private)")
        onError?(error)
        context.close(promise: nil)
    }
}

/// 包装器：在子通道中将 ByteBuffer 封装/解封为 SSHChannelData
final class SSHWrapperHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = self.unwrapInboundIn(data)
        guard case .channel = data.type, case .byteBuffer(let buffer) = data.data else {
            context.fireErrorCaught(SSHClientError.invalidData)
            return
        }
        context.fireChannelRead(self.wrapInboundOut(buffer))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let data = self.unwrapOutboundIn(data)
        let wrapped = SSHChannelData(type: .channel, data: .byteBuffer(data))
        context.write(self.wrapOutboundOut(wrapped), promise: promise)
    }
}

/// 终端输出处理器：将 ByteBuffer 文本输出通过回调传回上层
final class SSHTerminalHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private let onText: (ByteBuffer) -> Void
    init(_ onText: @escaping (ByteBuffer) -> Void) { self.onText = onText }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buf = self.unwrapInboundIn(data)
        onText(buf)
    }
}

/// 简化的错误类型
enum SSHClientError: Error {
    case invalidChannelType
    case invalidData
}

/// 简单私钥认证委托：提供一次性 .privateKey 认证
final class SimplePrivateKeyDelegate: NIOSSHClientUserAuthenticationDelegate {
    private var offer: NIOSSHUserAuthenticationOffer?
    init(username: String, privateKey: NIOSSHPrivateKey) {
        self.offer = NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: .privateKey(.init(privateKey: privateKey)))
    }
    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods, nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        if let off = offer, availableMethods.contains(.publicKey) {
            offer = nil
            nextChallengePromise.succeed(off)
        } else {
            nextChallengePromise.succeed(nil)
        }
    }
}
