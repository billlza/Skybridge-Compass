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
    @Published public private(set) var terminalOutputBatch: SSHTerminalOutputBatch?
    @Published public private(set) var terminalPresentationBatch: SSHTerminalPresentationBatch?

    public var terminalOutputReplay: SSHTerminalOutputReplay {
        terminalOutputHistory.replay
    }

    public var terminalPresentationReplay: SSHTerminalPresentationReplay {
        terminalPresentationHistory.replay
    }

    /// Clears retained/replayable output without resetting the active remote terminal stream.
    /// Sequence numbers remain monotonic so an observer can still reject stale pre-clear batches.
    public func clearTerminalOutputHistory() {
        let persistentPresentationStatus = terminalPresentationPipeline.persistentStatusOperations()
        terminalOutputRevision &+= 1
        terminalOutputClearEpoch &+= 1
        terminalOutputSnapshotTask?.cancel()
        terminalOutputSnapshotTask = nil
        terminalOutputSnapshotToken = nil
        terminalOutputHistory.reset()
        terminalPresentationHistory.reset()
        terminalOutputBatch = nil
        terminalPresentationBatch = nil
        outputText = ""
        guard !persistentPresentationStatus.isEmpty else { return }

        // A dropped raw prefix permanently desynchronizes the parser for this transport
        // generation. Clearing retained output must not hide that fail-closed state or make a
        // frozen terminal look healthy. Publish a fresh monotonic status batch without admitting
        // any of the rejected raw payload into the presentation surface.
        terminalOutputSequence &+= 1
        let statusBatch = SSHTerminalPresentationBatch(
            generation: lifecycleGeneration,
            sequence: terminalOutputSequence,
            operations: persistentPresentationStatus
        )
        terminalPresentationHistory.append(statusBatch)
        terminalPresentationBatch = statusBatch
    }

    public let host: String
    public let port: Int
    public let username: String

    private var reconnectCredential: SSHReconnectCredential?
    private var lifecycleGeneration: UInt64 = 0
    private var group: MultiThreadedEventLoopGroup?
    private var channel: Channel?
    private var childChannel: Channel?
    private let terminalOutputBuffer = SSHTerminalOutputBuffer()
    private let terminalPresentationPipeline = SSHTerminalPresentationPipeline()
    private var terminalOutputHistory = SSHTerminalOutputHistory()
    private var terminalPresentationHistory = SSHTerminalPresentationHistory()
    private var terminalOutputSequence: UInt64 = 0
    private var terminalOutputRevision: UInt64 = 0
    private var terminalOutputClearEpoch: UInt64 = 0
    private var terminalOutputSnapshotTask: Task<Void, Never>?
    private var terminalOutputSnapshotToken: UUID?
 /// 管理已打开的 DirectTCPIP 转发通道
    private var portForwards: [UUID: Channel] = [:]
    private var reconnectTask: Task<Void, Never>?
    private var reconnectToken: UUID?
    private var connectionToken: UUID?
    private var reconnecting = false
    private var isDisconnecting = false
    private let eventLoopGroupWillShutdown: @Sendable () -> Void
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "SSHSession")
    private let trustOnFirstUseAllowed: Bool = UserDefaults.standard.bool(forKey: "ssh.trustOnFirstUse")

    public init(host: String, port: Int, username: String) {
        self.host = host
        self.port = port
        self.username = username
        eventLoopGroupWillShutdown = {}
    }

#if DEBUG || SKYBRIDGE_TESTING
    init(
        host: String,
        port: Int,
        username: String,
        eventLoopGroupWillShutdown: @escaping @Sendable () -> Void
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.eventLoopGroupWillShutdown = eventLoopGroupWillShutdown
    }
#endif

    /// Public callers are expected to disconnect explicitly, but resource correctness cannot rely
    /// on every UI/navigation/error path doing so. The finalizer is deliberately non-blocking: it
    /// cancels owned work, closes every channel, then transfers the exact remaining event-loop
    /// group to NIO's asynchronous graceful shutdown callback without retaining `self`.
    deinit {
        reconnectTask?.cancel()
        terminalOutputSnapshotTask?.cancel()
        childChannel?.close(promise: nil)
        channel?.close(promise: nil)
        for forwardChannel in portForwards.values {
            forwardChannel.close(promise: nil)
        }

        guard let abandonedGroup = group else { return }
        let eventLoopGroupWillShutdown = self.eventLoopGroupWillShutdown
        let logger = self.logger
        eventLoopGroupWillShutdown()
        abandonedGroup.shutdownGracefully(queue: DispatchQueue.global(qos: .utility)) { error in
            guard let error else { return }
            logger.error(
                "SSH event-loop shutdown failed: context=raii-finalizer errorClass=\(String(reflecting: Swift.type(of: error)), privacy: .public)"
            )
        }
    }

 /// 连接并启动交互式 Shell
    public func connect(password: String) async throws {
        try await connectManually(using: .password(password))
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
        lifecycleGeneration &+= 1
        isDisconnecting = true
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectToken = nil
        connectionToken = nil
        reconnecting = false
        terminalOutputBuffer.reset(generation: lifecycleGeneration)
        terminalPresentationPipeline.reset(generation: lifecycleGeneration)
        if let child = childChannel {
            child.close(promise: nil)
            childChannel = nil
        }
        if let ch = channel {
            ch.close(promise: nil)
            channel = nil
        }
        for channel in portForwards.values {
            channel.close(promise: nil)
        }
        portForwards.removeAll()
        if let g = group {
            group = nil
            let eventLoopGroupWillShutdown = self.eventLoopGroupWillShutdown
            let logger = self.logger
            Task {
                eventLoopGroupWillShutdown()
                do {
                    try await g.shutdownGracefully()
                } catch {
                    logger.error(
                        "SSH event-loop shutdown failed: context=explicit-disconnect errorClass=\(String(reflecting: Swift.type(of: error)), privacy: .public)"
                    )
                }
            }
        }
        isConnected = false
        reconnectCredential = nil
    }

 // MARK: - 进阶功能
    /// 使用私钥进行认证（Ed25519 原始表示）
    public func connectWithEd25519Key(rawKey: Data) async throws {
        try await connectManually(using: .ed25519Raw(rawKey))
    }

    /// 使用 PEM/OPENSSH 私钥进行认证（支持 OpenSSH/PKCS#8 Ed25519）
    /// - 参数 pem: 完整的 PEM 文本（含 BEGIN/END）
    public func connectWithPEM(_ pem: String) async throws {
        try await connectManually(using: .pem(pem))
    }

 /// 打开 DirectTCPIP 通道进行端口转发（客户端发起）
    public func openDirectTCPIP(targetHost: String, targetPort: Int) async throws -> Channel {
        guard let ch = channel,
              let eventLoopGroup = group,
              isConnected,
              !isDisconnecting else {
            throw SSHClientError.invalidChannelType
        }
        let transportIdentity = SSHTransportIdentity(
            generation: lifecycleGeneration,
            group: eventLoopGroup,
            mainChannel: ch
        )
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
                    pipelineLogger.error(
                        "SSH forwarding channel failed: errorClass=\(String(reflecting: Swift.type(of: err)), privacy: .public)"
                    )
                }))
            }
        }
        let directChannel = try await promise.futureResult.get()
        guard !Task.isCancelled, isCurrentTransport(transportIdentity) else {
            directChannel.close(promise: nil)
            throw CancellationError()
        }
        return directChannel
    }

    private func connectManually(using strategy: SSHConnectionCredential) async throws {
        guard !isConnected else {
            throw SSHClientError.alreadyConnected
        }
        if reconnectTask != nil || reconnecting {
            reconnectTask?.cancel()
            reconnectTask = nil
            reconnectToken = nil
            reconnecting = false

            // A manual connect supersedes a reconnect attempt. Invalidate the old attempt before
            // releasing the actor so its late close/catch callbacks cannot mutate the new transport.
            lifecycleGeneration &+= 1
            connectionToken = nil
        }
        guard connectionToken == nil else {
            throw SSHClientError.alreadyConnected
        }
        // Passwords are one-shot authentication material. Only key-based strategies are eligible
        // for unattended reconnect and therefore retained by the session.
        reconnectCredential = strategy.reconnectCredential
        do {
            try await performConnection(using: strategy)
        } catch {
            if !isConnected {
                reconnectCredential = nil
            }
            throw error
        }
    }

    private func performConnection(using strategy: SSHConnectionCredential) async throws {
        guard !isConnected, connectionToken == nil else {
            throw SSHClientError.alreadyConnected
        }

        let token = UUID()
        connectionToken = token
        isDisconnecting = false
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        terminalOutputBuffer.reset(generation: generation)
        terminalPresentationPipeline.reset(generation: generation)

        defer {
            if connectionToken == token {
                connectionToken = nil
            }
        }

        await prepareTransportForReconnect()
        try Task.checkCancellation()
        guard connectionToken == token,
              lifecycleGeneration == generation,
              !isDisconnecting else {
            throw CancellationError()
        }

        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        group = eventLoopGroup
        do {
            let bootstrap = makeBootstrap(using: strategy, group: eventLoopGroup)
            let mainChannel = try await establishMainChannel(
                using: bootstrap,
                group: eventLoopGroup,
                generation: generation
            )
            guard connectionToken == token,
                  isCurrentTransport(generation: generation, group: eventLoopGroup) else {
                mainChannel.close(promise: nil)
                throw CancellationError()
            }

            channel = mainChannel
            let mainTransportIdentity = SSHTransportIdentity(
                generation: generation,
                group: eventLoopGroup,
                mainChannel: mainChannel
            )
            bindMainChannelClose(
                mainChannel,
                identity: mainTransportIdentity
            )
            let handshakeTimeoutSeconds = RemoteDesktopSettingsManager.shared.settings
                .networkSettings.boundedConnectionTimeoutSeconds
            let handshakeTimeoutTask = mainChannel.eventLoop.scheduleTask(
                in: .seconds(Int64(handshakeTimeoutSeconds))
            ) {
                mainChannel.close(promise: nil)
            }
            defer { handshakeTimeoutTask.cancel() }
            try await openSessionShell(
                mainChannel: mainChannel,
                group: eventLoopGroup,
                generation: generation
            )
        } catch {
            await cleanupFailedTransportIfCurrent(
                group: eventLoopGroup,
                generation: generation
            )
            throw error
        }
    }

    private func makeBootstrap(
        using strategy: SSHConnectionCredential,
        group: MultiThreadedEventLoopGroup
    ) -> ClientBootstrap {
        let username = username
        let host = host
        let port = port
        let trustOnFirstUseAllowed = trustOnFirstUseAllowed
        let networkSettings = RemoteDesktopSettingsManager.shared.settings.networkSettings
        let connectionTimeoutSeconds = networkSettings.boundedConnectionTimeoutSeconds
        let keepAliveIdleSeconds = SSHKeepAlivePolicy.boundedIdleSeconds(
            networkSettings.keepAliveInterval
        )

        return ClientBootstrap(group: group)
            .connectTimeout(.seconds(Int64(connectionTimeoutSeconds)))
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let userAuthDelegate: NIOSSHClientUserAuthenticationDelegate
                    switch strategy {
                    case .password(let password):
                        userAuthDelegate = SimplePasswordDelegate(
                            username: username,
                            password: password
                        )
                    case .ed25519Raw(let rawKey):
                        let privateKey = try Curve25519.Signing.PrivateKey(
                            rawRepresentation: rawKey
                        )
                        userAuthDelegate = SimplePrivateKeyDelegate(
                            username: username,
                            privateKey: NIOSSHPrivateKey(ed25519Key: privateKey)
                        )
                    case .pem(let pem):
                        let privateKey = try SSHKeyImporter.importEd25519PrivateKey(
                            fromPEM: pem
                        )
                        userAuthDelegate = SimplePrivateKeyDelegate(
                            username: username,
                            privateKey: NIOSSHPrivateKey(ed25519Key: privateKey)
                        )
                    }

                    let hostKeyDelegate = SSHKnownHostsDelegate(
                        host: host,
                        port: port,
                        trustOnFirstUse: trustOnFirstUseAllowed
                    )
                    let configuration = SSHClientConfiguration(
                        userAuthDelegate: userAuthDelegate,
                        serverAuthDelegate: hostKeyDelegate
                    )
                    let sshHandler = NIOSSHHandler(
                        role: .client(configuration),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil
                    )
                    let sync = channel.pipeline.syncOperations
                    try sync.addHandler(sshHandler)
                    let pipelineLogger = Logger(
                        subsystem: "com.skybridge.compass",
                        category: "SSHSessionPipeline"
                    )
                    try sync.addHandler(SSHErrorHandler(onError: { error in
                        pipelineLogger.error(
                            "SSH main-channel pipeline failed: errorClass=\(String(reflecting: Swift.type(of: error)), privacy: .public)"
                        )
                    }))
                }
            }
            .channelOption(
                ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR),
                value: 1
            )
            .channelOption(
                ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY),
                value: 1
            )
            // Keepalive belongs to the main TCP transport. Both options are bootstrap channel
            // options, so an unsupported/failed setsockopt fails connection establishment instead
            // of silently falling back to writing bytes into the interactive PTY.
            .channelOption(
                ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_KEEPALIVE),
                value: 1
            )
            .channelOption(
                ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_KEEPALIVE),
                value: keepAliveIdleSeconds
            )
    }

    private func openSessionShell(
        mainChannel: Channel,
        group eventLoopGroup: MultiThreadedEventLoopGroup,
        generation: UInt64
    ) async throws {
        let promise = mainChannel.eventLoop.makePromise(of: Channel.self)
        let sshHandler = try mainChannel.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
        let outputBuffer = terminalOutputBuffer
        let presentationPipeline = terminalPresentationPipeline
        sshHandler.createChannel(promise, channelType: .session) { child, type in
            guard case .session = type else {
                return mainChannel.eventLoop.makeFailedFuture(SSHClientError.invalidChannelType)
            }
            return child.eventLoop.makeCompletedFuture {
                let childSync = child.pipeline.syncOperations
                try childSync.addHandler(SSHWrapperHandler())
                let identity = SSHTransportIdentity(
                    generation: generation,
                    group: eventLoopGroup,
                    mainChannel: mainChannel,
                    childChannel: child
                )
                try childSync.addHandler(SSHTerminalHandler { [weak self] buffer, eventLoop in
                    guard let self else { return }
                    guard outputBuffer.enqueue(buffer, generation: generation) else {
                        return
                    }
                    self.scheduleTerminalOutputDrain(
                        outputBuffer: outputBuffer,
                        presentationPipeline: presentationPipeline,
                        generation: generation,
                        identity: identity,
                        eventLoop: eventLoop
                    )
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

        let shellChannel = try await promise.futureResult.get()
        guard !Task.isCancelled,
              isCurrentTransport(
                generation: generation,
                group: eventLoopGroup,
                mainChannel: mainChannel
              ) else {
            shellChannel.close(promise: nil)
            throw CancellationError()
        }

        childChannel = shellChannel
        isConnected = true
        logger.info("SSH shell channel established")
        let shellTransportIdentity = SSHTransportIdentity(
            generation: generation,
            group: eventLoopGroup,
            mainChannel: mainChannel,
            childChannel: shellChannel
        )
        bindShellChannelClose(
            shellChannel,
            identity: shellTransportIdentity
        )
    }

    private func appendTerminalOutput(
        _ batch: String,
        presentationOperations: [SSHTerminalRenderOperation],
        identity: SSHTransportIdentity
    ) {
        guard isCurrentTransport(identity) else {
            return
        }
        terminalOutputSequence &+= 1
        let outputBatch = SSHTerminalOutputBatch(
            generation: identity.generation,
            sequence: terminalOutputSequence,
            text: batch
        )
        let presentationBatch = SSHTerminalPresentationBatch(
            generation: identity.generation,
            sequence: terminalOutputSequence,
            operations: presentationOperations
        )
        recordTerminalOutputBatch(
            outputBatch,
            presentationBatch: presentationBatch
        )
    }

    private func recordTerminalOutputBatch(
        _ outputBatch: SSHTerminalOutputBatch,
        presentationBatch: SSHTerminalPresentationBatch
    ) {
        terminalOutputHistory.append(outputBatch)
        terminalOutputBatch = outputBatch
        if !presentationBatch.operations.isEmpty {
            terminalPresentationHistory.append(presentationBatch)
            terminalPresentationBatch = presentationBatch
        }
        terminalOutputRevision &+= 1
        scheduleCompatibilityOutputSnapshot()
    }

    /// Keeps exactly one drained String/MainActor delivery in flight. New NIO output remains in
    /// the bounded byte buffer until the MainActor acknowledges the current batch.
    nonisolated private func scheduleTerminalOutputDrain(
        outputBuffer: SSHTerminalOutputBuffer,
        presentationPipeline: SSHTerminalPresentationPipeline,
        generation: UInt64,
        identity: SSHTransportIdentity,
        eventLoop: any EventLoop
    ) {
        _ = eventLoop.scheduleTask(in: .milliseconds(16)) { [weak self] in
            guard let drainedOutput = outputBuffer.drainBatch(generation: generation) else {
                return
            }
            let parserTask = Task.detached(priority: .utility) {
                presentationPipeline.consume(
                    drainedOutput.text,
                    generation: generation,
                    inputPrefixWasDropped: drainedOutput.didDropInputPrefix
                )
            }
            Task { @MainActor [weak self] in
                if let presentationOperations = await parserTask.value {
                    self?.appendTerminalOutput(
                        drainedOutput.text,
                        presentationOperations: presentationOperations,
                        identity: identity
                    )
                }
                let shouldScheduleNext = outputBuffer.acknowledgeDelivery(
                    generation: generation
                )
                guard shouldScheduleNext, let self else { return }
                self.scheduleTerminalOutputDrain(
                    outputBuffer: outputBuffer,
                    presentationPipeline: presentationPipeline,
                    generation: generation,
                    identity: identity,
                    eventLoop: eventLoop
                )
            }
        }
    }

    /// Preserves the original `@Published outputText` API without rebuilding the complete
    /// transcript on every 16 ms delivery. Snapshot construction is single-flight, throttled and
    /// performed off the MainActor; only the final copy-on-write String assignment runs here.
    private func scheduleCompatibilityOutputSnapshot() {
        guard terminalOutputSnapshotTask == nil else { return }
        let token = UUID()
        terminalOutputSnapshotToken = token
        terminalOutputSnapshotTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch is CancellationError {
                self?.finishCompatibilityOutputSnapshot(token: token)
                return
            } catch {
                guard let self else { return }
                self.logger.error(
                    "SSH terminal snapshot throttle failed: errorClass=\(String(reflecting: Swift.type(of: error)), privacy: .public)"
                )
                self.finishCompatibilityOutputSnapshot(token: token)
                return
            }

            guard let self, self.terminalOutputSnapshotToken == token else { return }
            let capturedRevision = self.terminalOutputRevision
            let capturedClearEpoch = self.terminalOutputClearEpoch
            let replay = self.terminalOutputHistory.replay
            let expectedByteCount = self.terminalOutputHistory.byteCount
            let worker = Task.detached(priority: .utility) { () -> String? in
                var snapshot = ""
                snapshot.reserveCapacity(expectedByteCount)
                for batch in replay.batches {
                    guard !Task.isCancelled else { return nil }
                    snapshot.append(batch.text)
                }
                return snapshot
            }
            let snapshot = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }

            guard self.terminalOutputSnapshotToken == token else { return }
            let needsFollowUp = self.terminalOutputRevision != capturedRevision
            if let snapshot, self.terminalOutputClearEpoch == capturedClearEpoch {
                self.outputText = snapshot
            }
            self.finishCompatibilityOutputSnapshot(token: token)
            if needsFollowUp {
                self.scheduleCompatibilityOutputSnapshot()
            }
        }
    }

    private func finishCompatibilityOutputSnapshot(token: UUID) {
        guard terminalOutputSnapshotToken == token else { return }
        terminalOutputSnapshotTask = nil
        terminalOutputSnapshotToken = nil
    }

    private func bindMainChannelClose(
        _ mainChannel: Channel,
        identity: SSHTransportIdentity
    ) {
        mainChannel.closeFuture.whenComplete { [weak self] _ in
            Task { @MainActor in
                await self?.handleTransportClosure(
                    identity: identity,
                    source: "main-channel"
                )
            }
        }
    }

    private func bindShellChannelClose(
        _ shellChannel: Channel,
        identity: SSHTransportIdentity
    ) {
        shellChannel.closeFuture.whenComplete { [weak self] _ in
            Task { @MainActor in
                await self?.handleTransportClosure(
                    identity: identity,
                    source: "shell-channel"
                )
            }
        }
    }

    private func handleTransportClosure(
        identity: SSHTransportIdentity,
        source: String
    ) async {
        guard isCurrentTransport(identity) else { return }

        isConnected = false

        // A close during an in-flight connect is owned by `performConnection`, whose catch path
        // closes and shuts down the exact group. Starting a second owner here would race it.
        guard connectionToken == nil else {
            logger.notice("SSH \(source, privacy: .public) closed during connection setup")
            return
        }

        guard reconnectCredential != nil else {
            logger.notice(
                "SSH \(source, privacy: .public) closed; one-shot credentials require terminal cleanup"
            )
            await cleanupTerminalTransport(
                matching: SSHTransportCleanupIdentity(identity),
                context: "one-shot-remote-close"
            )
            return
        }

        logger.warning("SSH \(source, privacy: .public) closed; scheduling reconnect")
        scheduleReconnect(expectedGeneration: identity.generation)
    }

 // MARK: - 端口转发管理
 /// 开始端口转发（通过 SSH 服务器连接到目标主机端口）
    @discardableResult
    public func startPortForward(to targetHost: String, port targetPort: Int) async throws -> UUID {
        guard let transportIdentity = currentMainTransportIdentity() else {
            throw SSHClientError.invalidChannelType
        }
        let forwardChannel = try await openDirectTCPIP(targetHost: targetHost, targetPort: targetPort)
        // `openDirectTCPIP` validates immediately after its own await. Validate again here because
        // returning from that actor-isolated async call is itself a suspension point at which an
        // explicit disconnect or reconnect may install another transport.
        guard !Task.isCancelled, isCurrentTransport(transportIdentity) else {
            forwardChannel.close(promise: nil)
            throw CancellationError()
        }
        let id = UUID()
        portForwards[id] = forwardChannel
        forwardChannel.closeFuture.whenComplete { [weak self] _ in
            Task { @MainActor in self?.portForwards.removeValue(forKey: id) }
        }
        return id
    }

    private func currentMainTransportIdentity() -> SSHTransportIdentity? {
        guard let group,
              let channel,
              isConnected,
              !isDisconnecting else {
            return nil
        }
        return SSHTransportIdentity(
            generation: lifecycleGeneration,
            group: group,
            mainChannel: channel
        )
    }

 /// 停止端口转发
    public func stopPortForward(id: UUID) {
        if let ch = portForwards[id] {
            ch.close(promise: nil)
            portForwards.removeValue(forKey: id)
        }
    }

    /// 按退避策略重连
    private func scheduleReconnect(expectedGeneration: UInt64) {
        guard !reconnecting, !isDisconnecting else { return }
        guard connectionToken == nil else { return }
        guard lifecycleGeneration == expectedGeneration else { return }
        guard let reconnectCredential else {
            logger.notice("SSH automatic reconnect is disabled for one-shot credentials")
            return
        }

        reconnecting = true
        let token = UUID()
        reconnectToken = token
        let net = RemoteDesktopSettingsManager.shared.settings.networkSettings
        var delayMs = net.boundedReconnectBackoffInitialMilliseconds
        let maxMs = net.boundedReconnectBackoffMaxMilliseconds
        let multiplier = net.boundedReconnectBackoffMultiplier
        reconnectTask = Task { @MainActor [weak self] in
            defer {
                if let session = self, session.reconnectToken == token {
                    session.reconnecting = false
                    session.reconnectTask = nil
                    session.reconnectToken = nil
                }
            }
            var attempts = 0
            while attempts < net.boundedMaxReconnectAttempts {
                do {
                    // Keep a strong session reference only for one concrete attempt. In
                    // particular, do not retain the public session across backoff sleeps; this
                    // allows its RAII finalizer to cancel an otherwise abandoned reconnect task.
                    guard let session = self,
                          session.reconnectToken == token,
                          !session.isDisconnecting else { return }
                    try Task.checkCancellation()
                    try await session.performConnection(
                        using: reconnectCredential.connectionCredential
                    )
                    return
                } catch is CancellationError {
                    return
                } catch {
                    attempts += 1
                    guard attempts < net.boundedMaxReconnectAttempts else {
                        guard let session = self else { return }
                        session.logger.error(
                            "SSH reconnect attempts exhausted: attempts=\(attempts, privacy: .public) errorClass=\(String(reflecting: Swift.type(of: error)), privacy: .public)"
                        )
                        await session.finishTerminalLifecycleAfterReconnectFailure(token: token)
                        return
                    }
                    do {
                        try await Task.sleep(for: .milliseconds(delayMs))
                    } catch is CancellationError {
                        return
                    } catch {
                        guard let session = self else { return }
                        session.logger.error(
                            "SSH reconnect delay failed: errorClass=\(String(reflecting: Swift.type(of: error)), privacy: .public)"
                        )
                        await session.finishTerminalLifecycleAfterReconnectFailure(token: token)
                        return
                    }
                    delayMs = min(Int(Double(delayMs) * multiplier), maxMs)
                }
            }
            await self?.finishTerminalLifecycleAfterReconnectFailure(token: token)
        }
    }

    private func finishTerminalLifecycleAfterReconnectFailure(token: UUID) async {
        guard reconnectToken == token,
              connectionToken == nil,
              !isDisconnecting,
              !isConnected else {
            return
        }

        if let identity = currentTransportCleanupIdentity() {
            await cleanupTerminalTransport(
                matching: identity,
                context: "reconnect-exhausted"
            )
            return
        }

        // Failed attempts normally detach and shut down their group before returning. Still
        // invalidate the generation and clear every remaining reference so a late callback cannot
        // revive the exhausted lifecycle or retain reconnect credentials indefinitely.
        lifecycleGeneration &+= 1
        terminalOutputBuffer.reset(generation: lifecycleGeneration)
        terminalPresentationPipeline.reset(generation: lifecycleGeneration)
        releaseTerminalTransportReferences()
    }

    private func prepareTransportForReconnect() async {
        childChannel?.close(promise: nil)
        childChannel = nil
        channel?.close(promise: nil)
        channel = nil
        for channel in portForwards.values {
            channel.close(promise: nil)
        }
        portForwards.removeAll()
        guard let staleGroup = group else { return }
        group = nil
        await shutdownEventLoopGroup(staleGroup, context: "reconnect-replacement")
    }

    private func establishMainChannel(
        using bootstrap: ClientBootstrap,
        group eventLoopGroup: MultiThreadedEventLoopGroup,
        generation: UInt64
    ) async throws -> Channel {
        let connectedChannel = try await bootstrap.connect(host: host, port: port).get()
        guard !Task.isCancelled,
              isCurrentTransport(generation: generation, group: eventLoopGroup) else {
            connectedChannel.close(promise: nil)
            throw CancellationError()
        }
        return connectedChannel
    }

    private func cleanupFailedTransportIfCurrent(
        group eventLoopGroup: MultiThreadedEventLoopGroup,
        generation: UInt64
    ) async {
        guard lifecycleGeneration == generation, group === eventLoopGroup else {
            return
        }

        childChannel?.close(promise: nil)
        childChannel = nil
        channel?.close(promise: nil)
        channel = nil
        for forwardChannel in portForwards.values {
            forwardChannel.close(promise: nil)
        }
        portForwards.removeAll()
        group = nil
        isConnected = false
        await shutdownEventLoopGroup(eventLoopGroup, context: "failed-attempt")
    }

    private func currentTransportCleanupIdentity() -> SSHTransportCleanupIdentity? {
        guard let group else { return nil }
        return SSHTransportCleanupIdentity(
            generation: lifecycleGeneration,
            groupIdentifier: ObjectIdentifier(group)
        )
    }

    /// Claims and terminates one exact transport generation.
    ///
    /// `group = nil` is the ownership transfer: once detached, duplicate main/shell close
    /// callbacks and stale reconnect tasks cannot shut the same group down twice or touch a newer
    /// transport that happens to use the same session object.
    private func cleanupTerminalTransport(
        matching identity: SSHTransportCleanupIdentity,
        context: String
    ) async {
        guard lifecycleGeneration == identity.generation,
              let eventLoopGroup = group,
              ObjectIdentifier(eventLoopGroup) == identity.groupIdentifier else {
            return
        }

        lifecycleGeneration &+= 1
        terminalOutputBuffer.reset(generation: lifecycleGeneration)
        terminalPresentationPipeline.reset(generation: lifecycleGeneration)
        group = nil
        releaseTerminalTransportReferences()
        await shutdownEventLoopGroup(eventLoopGroup, context: context)
    }

    private func releaseTerminalTransportReferences() {
        childChannel?.close(promise: nil)
        childChannel = nil
        channel?.close(promise: nil)
        channel = nil
        for forwardChannel in portForwards.values {
            forwardChannel.close(promise: nil)
        }
        portForwards.removeAll()
        isConnected = false
        reconnectCredential = nil
    }

    private func shutdownEventLoopGroup(
        _ eventLoopGroup: MultiThreadedEventLoopGroup,
        context: String
    ) async {
        eventLoopGroupWillShutdown()
        do {
            try await eventLoopGroup.shutdownGracefully()
        } catch {
            logger.error(
                "SSH event-loop shutdown failed: context=\(context, privacy: .public) errorClass=\(String(reflecting: Swift.type(of: error)), privacy: .public)"
            )
        }
    }

#if DEBUG || SKYBRIDGE_TESTING
    func installIdleTransportForLifecycleTesting() -> SSHTransportCleanupIdentity {
        precondition(group == nil)
        lifecycleGeneration &+= 1
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        group = eventLoopGroup
        isDisconnecting = false
        return SSHTransportCleanupIdentity(
            generation: lifecycleGeneration,
            groupIdentifier: ObjectIdentifier(eventLoopGroup)
        )
    }

    func cleanupTerminalTransportForLifecycleTesting(
        matching identity: SSHTransportCleanupIdentity
    ) async {
        await cleanupTerminalTransport(matching: identity, context: "lifecycle-test")
    }

    var hasInstalledTransportForLifecycleTesting: Bool { group != nil }

    func appendTerminalOutputForLifecycleTesting(
        _ text: String,
        generation: UInt64 = 0,
        inputPrefixWasDropped: Bool = false
    ) {
        terminalOutputSequence &+= 1
        let batch = SSHTerminalOutputBatch(
            generation: generation,
            sequence: terminalOutputSequence,
            text: text
        )
        guard let operations = terminalPresentationPipeline.consume(
            text,
            generation: generation,
            inputPrefixWasDropped: inputPrefixWasDropped
        ) else {
            preconditionFailure("Testing output generation must match the presentation pipeline")
        }
        recordTerminalOutputBatch(
            batch,
            presentationBatch: SSHTerminalPresentationBatch(
                generation: generation,
                sequence: terminalOutputSequence,
                operations: operations
            )
        )
    }
#endif

    private func isCurrentTransport(
        generation: UInt64,
        group expectedGroup: MultiThreadedEventLoopGroup,
        mainChannel expectedMainChannel: Channel? = nil,
        childChannel expectedChildChannel: Channel? = nil
    ) -> Bool {
        guard lifecycleGeneration == generation,
              !isDisconnecting,
              group === expectedGroup else {
            return false
        }
        if let expectedMainChannel,
           channel !== expectedMainChannel {
            return false
        }
        if let expectedChildChannel,
           childChannel !== expectedChildChannel {
            return false
        }
        return true
    }

    private func isCurrentTransport(_ identity: SSHTransportIdentity) -> Bool {
        guard !isDisconnecting, let group, let channel else {
            return false
        }
        return identity.matches(
            generation: lifecycleGeneration,
            groupIdentifier: ObjectIdentifier(group),
            mainChannelIdentifier: ObjectIdentifier(channel),
            childChannelIdentifier: childChannel.map(ObjectIdentifier.init)
        )
    }
}

struct SSHTransportCleanupIdentity: Sendable, Equatable {
    let generation: UInt64
    let groupIdentifier: ObjectIdentifier

    init(generation: UInt64, groupIdentifier: ObjectIdentifier) {
        self.generation = generation
        self.groupIdentifier = groupIdentifier
    }

    init(_ identity: SSHTransportIdentity) {
        generation = identity.generation
        groupIdentifier = identity.groupIdentifier
    }
}

struct SSHTransportIdentity: Sendable {
    let generation: UInt64
    let groupIdentifier: ObjectIdentifier
    let mainChannelIdentifier: ObjectIdentifier
    let childChannelIdentifier: ObjectIdentifier?

    init(
        generation: UInt64,
        group: MultiThreadedEventLoopGroup,
        mainChannel: Channel,
        childChannel: Channel? = nil
    ) {
        self.generation = generation
        groupIdentifier = ObjectIdentifier(group)
        mainChannelIdentifier = ObjectIdentifier(mainChannel)
        childChannelIdentifier = childChannel.map(ObjectIdentifier.init)
    }

    init(
        generation: UInt64,
        groupIdentifier: ObjectIdentifier,
        mainChannelIdentifier: ObjectIdentifier,
        childChannelIdentifier: ObjectIdentifier? = nil
    ) {
        self.generation = generation
        self.groupIdentifier = groupIdentifier
        self.mainChannelIdentifier = mainChannelIdentifier
        self.childChannelIdentifier = childChannelIdentifier
    }

    func matches(
        generation: UInt64,
        groupIdentifier: ObjectIdentifier,
        mainChannelIdentifier: ObjectIdentifier,
        childChannelIdentifier: ObjectIdentifier?
    ) -> Bool {
        guard self.generation == generation,
              self.groupIdentifier == groupIdentifier,
              self.mainChannelIdentifier == mainChannelIdentifier else {
            return false
        }
        guard let expectedChildChannelIdentifier = self.childChannelIdentifier else {
            return true
        }
        return expectedChildChannelIdentifier == childChannelIdentifier
    }
}

enum SSHConnectionCredential: Sendable {
    case password(String)
    case ed25519Raw(Data)
    case pem(String)

    var reconnectCredential: SSHReconnectCredential? {
        switch self {
        case .password:
            return nil
        case .ed25519Raw(let rawKey):
            return .ed25519Raw(rawKey)
        case .pem(let pem):
            return .pem(pem)
        }
    }
}

/// Credentials eligible for unattended reconnect. Password is intentionally unrepresentable.
enum SSHReconnectCredential: Sendable {
    case ed25519Raw(Data)
    case pem(String)

    var connectionCredential: SSHConnectionCredential {
        switch self {
        case .ed25519Raw(let rawKey):
            return .ed25519Raw(rawKey)
        case .pem(let pem):
            return .pem(pem)
        }
    }
}

enum SSHOutputRetentionPolicy {
    static let maximumBytes = 1_048_576
    static let retainedBytesAfterTrim = 786_432
}

enum SSHKeepAlivePolicy {
    static let minimumIdleSeconds = 10
    static let maximumIdleSeconds = 3_600

    /// Darwin's `TCP_KEEPALIVE` accepts a signed C integer number of idle seconds. Clamp persisted
    /// settings before conversion so malformed or legacy defaults cannot overflow or disable the
    /// transport-level liveness contract.
    static func boundedIdleSeconds(_ requestedSeconds: Int) -> CInt {
        CInt(max(minimumIdleSeconds, min(requestedSeconds, maximumIdleSeconds)))
    }
}

struct SSHTerminalDrainedOutput: Equatable, Sendable {
    let text: String
    let didDropInputPrefix: Bool
}

/// Thread-safe coalescing buffer used by NIO event-loop callbacks.
///
/// `enqueue` returns `true` only for the producer that must schedule the next drain. This bounds
/// pending memory and prevents one MainActor task per network chunk under high-throughput output.
final class SSHTerminalOutputBuffer: @unchecked Sendable {
    static let truncationMarker = "\r\n[terminal output truncated before display]\r\n"

    private let lock = NSLock()
    private let maximumPendingBytes: Int
    private let retainedPendingBytesAfterTrim: Int
    private var generation: UInt64 = 0
    private var pending: [UInt8] = []
    private var deliveryScheduledOrInFlight = false
    private var wasTruncated = false

    init(
        maximumPendingBytes: Int = 65_536,
        retainedPendingBytesAfterTrim: Int = 49_152
    ) {
        precondition(maximumPendingBytes > 0)
        precondition(retainedPendingBytesAfterTrim > 0)
        precondition(retainedPendingBytesAfterTrim <= maximumPendingBytes)
        self.maximumPendingBytes = maximumPendingBytes
        self.retainedPendingBytesAfterTrim = retainedPendingBytesAfterTrim
    }

    func reset(generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        self.generation = generation
        pending.removeAll(keepingCapacity: false)
        deliveryScheduledOrInFlight = false
        wasTruncated = false
    }

    func enqueue(_ text: String, generation: UInt64) -> Bool {
        enqueue(Array(text.utf8), generation: generation)
    }

    func enqueue(_ bytes: [UInt8], generation: UInt64) -> Bool {
        guard !bytes.isEmpty else { return false }
        let inputWasTruncated = bytes.count > maximumPendingBytes
        let boundedBytes = inputWasTruncated
            ? bytes.suffix(retainedPendingBytesAfterTrim)
            : bytes[...]
        return enqueueBounded(
            boundedBytes,
            generation: generation,
            inputWasTruncated: inputWasTruncated
        )
    }

    /// Extracts at most the configured retained suffix directly from NIO storage. A malicious or
    /// misconfigured peer therefore cannot make the event loop allocate a full unbounded frame
    /// before the pending-output limit is applied.
    func enqueue(_ buffer: ByteBuffer, generation: UInt64) -> Bool {
        let readableByteCount = buffer.readableBytes
        guard readableByteCount > 0 else { return false }
        let inputWasTruncated = readableByteCount > maximumPendingBytes
        let retainedByteCount = inputWasTruncated
            ? retainedPendingBytesAfterTrim
            : readableByteCount
        let retainedStart = buffer.readerIndex + readableByteCount - retainedByteCount
        guard let bytes = buffer.getBytes(at: retainedStart, length: retainedByteCount) else {
            return false
        }
        return enqueueBounded(
            bytes[...],
            generation: generation,
            inputWasTruncated: inputWasTruncated
        )
    }

    private func enqueueBounded(
        _ unalignedBytes: ArraySlice<UInt8>,
        generation: UInt64,
        inputWasTruncated: Bool
    ) -> Bool {
        let bytes: ArraySlice<UInt8>
        if inputWasTruncated {
            let firstScalarBoundary = unalignedBytes.firstIndex(
                where: { !Self.isUTF8ContinuationByte($0) }
            ) ?? unalignedBytes.endIndex
            bytes = unalignedBytes[firstScalarBoundary...]
        } else {
            bytes = unalignedBytes
        }

        lock.lock()
        defer { lock.unlock() }
        guard self.generation == generation else { return false }

        wasTruncated = wasTruncated || inputWasTruncated
        pending.append(contentsOf: bytes)
        if pending.count > maximumPendingBytes {
            pending = Array(pending.suffix(retainedPendingBytesAfterTrim))
            let firstScalarBoundary = pending.firstIndex(
                where: { !Self.isUTF8ContinuationByte($0) }
            ) ?? pending.endIndex
            if firstScalarBoundary > pending.startIndex {
                pending.removeSubrange(pending.startIndex..<firstScalarBoundary)
            }
            wasTruncated = true
        }
        guard !deliveryScheduledOrInFlight else { return false }
        deliveryScheduledOrInFlight = true
        return true
    }

    func drain(generation: UInt64) -> String? {
        drainBatch(generation: generation)?.text
    }

    func drainBatch(generation: UInt64) -> SSHTerminalDrainedOutput? {
        lock.lock()
        defer { lock.unlock() }
        guard self.generation == generation else { return nil }

        let completePrefixCount = Self.completeUTF8PrefixCount(in: pending)
        guard completePrefixCount > 0 else {
            deliveryScheduledOrInFlight = false
            return nil
        }
        let decoded = String(decoding: pending.prefix(completePrefixCount), as: UTF8.self)
        let didDropInputPrefix = wasTruncated
        let batch = (didDropInputPrefix ? Self.truncationMarker : "") + decoded
        pending.removeFirst(completePrefixCount)
        wasTruncated = false
        return SSHTerminalDrainedOutput(
            text: batch,
            didDropInputPrefix: didDropInputPrefix
        )
    }

    /// Releases the single in-flight delivery only after MainActor consumption. Returns true when
    /// pending bytes require exactly one follow-up drain schedule.
    func acknowledgeDelivery(generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard self.generation == generation, deliveryScheduledOrInFlight else {
            return false
        }
        deliveryScheduledOrInFlight = false
        guard !pending.isEmpty else { return false }
        deliveryScheduledOrInFlight = true
        return true
    }

    /// Returns the largest prefix that cannot end in a potentially incomplete UTF-8 scalar.
    /// Invalid complete byte sequences are left for `String(decoding:as:)` to replace explicitly.
    private static func completeUTF8PrefixCount(in bytes: [UInt8]) -> Int {
        guard let last = bytes.last else { return 0 }

        if expectedUTF8Length(forLeadingByte: last).map({ $0 > 1 }) == true {
            return bytes.count - 1
        }
        guard isUTF8ContinuationByte(last) else { return bytes.count }

        var continuationCount = 0
        var index = bytes.count
        while index > 0,
              continuationCount < 3,
              isUTF8ContinuationByte(bytes[index - 1]) {
            continuationCount += 1
            index -= 1
        }
        guard index > 0,
              let expectedLength = expectedUTF8Length(forLeadingByte: bytes[index - 1]) else {
            return bytes.count
        }
        let availableLength = continuationCount + 1
        return availableLength < expectedLength ? index - 1 : bytes.count
    }

    private static func expectedUTF8Length(forLeadingByte byte: UInt8) -> Int? {
        switch byte {
        case 0x00...0x7F: 1
        case 0xC2...0xDF: 2
        case 0xE0...0xEF: 3
        case 0xF0...0xF4: 4
        default: nil
        }
    }

    private static func isUTF8ContinuationByte(_ byte: UInt8) -> Bool {
        (0x80...0xBF).contains(byte)
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
    private let onText: (ByteBuffer, EventLoop) -> Void
    init(_ onText: @escaping (ByteBuffer, EventLoop) -> Void) { self.onText = onText }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buf = self.unwrapInboundIn(data)
        onText(buf, context.eventLoop)
    }
}

/// 简化的错误类型
enum SSHClientError: Error {
    case alreadyConnected
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
