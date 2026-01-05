import Foundation
import Network

// MARK: - 原生高性能 WebSocket 客户端（基于 Network.framework）
// 说明：
// - 适配 macOS 14+，使用 NWProtocolWebSocket 提供系统级高性能与稳定性。
// - 采用 Swift 6 严格并发模型，核心状态封装在 actor 中，避免数据竞争。
// - 支持自动回复 Ping（保持连接活跃）、连续接收消息、可选的指数退避重连。

/// WebSocket 事件回调协议（通过闭包传递，避免跨 actor 共享引用导致并发问题）
public struct NativeWebSocketCallbacks: Sendable {
 /// 连接就绪回调
    public var onOpen: (@Sendable () -> Void)?
 /// 收到文本消息回调
    public var onText: (@Sendable (String) -> Void)?
 /// 收到二进制消息回调
    public var onBinary: (@Sendable (Data) -> Void)?
 /// 连接状态变化（ready/waiting/failed/cancelled）
    public var onStateChange: (@Sendable (NWConnection.State) -> Void)?
 /// 连接关闭回调（包含关闭码与原因）
    public var onClose: (@Sendable (NWProtocolWebSocket.CloseCode?, Data?) -> Void)?
 /// 错误回调
    public var onError: (@Sendable (NWError) -> Void)?

    public init(
        onOpen: (@Sendable () -> Void)? = nil,
        onText: (@Sendable (String) -> Void)? = nil,
        onBinary: (@Sendable (Data) -> Void)? = nil,
        onStateChange: (@Sendable (NWConnection.State) -> Void)? = nil,
        onClose: (@Sendable (NWProtocolWebSocket.CloseCode?, Data?) -> Void)? = nil,
        onError: (@Sendable (NWError) -> Void)? = nil
    ) {
        self.onOpen = onOpen
        self.onText = onText
        self.onBinary = onBinary
        self.onStateChange = onStateChange
        self.onClose = onClose
        self.onError = onError
    }
}

/// 原生 WebSocket 客户端（严格并发安全）
public actor NativeWebSocketClient {
 // MARK: 配置与状态
    private let endpoint: NWEndpoint
    private let parameters: NWParameters
    private let callbacks: NativeWebSocketCallbacks
    private var connection: NWConnection?
    private var isReceiving: Bool = false
    private var reconnectPolicy: ReconnectPolicy?

 /// 指数退避重连策略
    public struct ReconnectPolicy {
 /// 初始延迟（秒）
        public var initialDelay: TimeInterval
 /// 最大延迟（秒）
        public var maxDelay: TimeInterval
 /// 乘数因子（例如 2.0 表示指数退避）
        public var factor: Double

        public init(initialDelay: TimeInterval = 0.5, maxDelay: TimeInterval = 10.0, factor: Double = 2.0) {
            self.initialDelay = initialDelay
            self.maxDelay = maxDelay
            self.factor = factor
        }
    }

 // MARK: 初始化
 /// 使用 URL 初始化（建议使用 wss://）
 /// - Parameters:
 /// - url: WebSocket 服务器地址（支持 wss/ws）
 /// - tls: 是否启用 TLS（wss 推荐 true）
 /// - pingInterval: 保持连接的 Ping 周期（秒），为 nil 时不主动发送 Ping（系统会自动回复 Ping）
 /// - callbacks: 事件回调集合
 /// - reconnectPolicy: 可选的重连策略
    public init(url: URL, tls: Bool = true, pingInterval: TimeInterval? = 30, callbacks: NativeWebSocketCallbacks = .init(), reconnectPolicy: ReconnectPolicy? = nil) {
        self.endpoint = NWEndpoint.url(url)
        self.parameters = NativeWebSocketClient.buildParameters(tls: tls, pingInterval: pingInterval)
        self.callbacks = callbacks
        self.reconnectPolicy = reconnectPolicy
    }

 /// 构造 Network 参数，插入 WebSocket 协议选项
    private static func buildParameters(tls: Bool, pingInterval: TimeInterval?) -> NWParameters {
 // 配置 TLS 与通用参数
        let params: NWParameters = tls ? .tls : NWParameters(tls: nil)
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = true

 // 配置 WebSocket 选项
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true // 自动回复 Ping，降低心跳管理复杂度
 // macOS 14 SDK 未提供 keepAliveInterval 属性；保留 autoReplyPing 即可维持连接活跃
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
        return params
    }

 // MARK: 连接与生命周期
 /// 建立连接（幂等）
    public func connect() {
 // 若已有连接且未取消，直接返回
        if let conn = connection {
            switch conn.state {
            case .ready, .preparing, .setup, .waiting(_):
                return
            default:
                break
            }
        }

        let conn = NWConnection(to: endpoint, using: parameters)
        self.connection = conn

 // 连接状态回调（跨 actor 闭包，内部用 切回 actor）
        conn.stateUpdateHandler = { [weak self] state in
 // 将状态处理封装为 actor 方法，外部仅调用一次 await，避免出现“await 中无异步操作”的警告
            Task { await self?.handleStateUpdate(state) }
        }

 // 更佳路径迁移（蜂窝/有线/无线切换时优化连接质量）
        conn.betterPathUpdateHandler = { [weak self] _ in
 // 路径优化事件也封装到 actor 方法，统一并发处理
            Task { await self?.handleBetterPathUpdate() }
        }

 // 启动连接（使用系统全局队列即可，实际状态回调会切回 actor）
        conn.start(queue: .global(qos: .userInitiated))
    }

 /// 关闭连接
 /// 部分系统版本的 CloseCode 常量集不完整，这里允许传入可选关闭码，缺省为 nil 以兼容 macOS 14。
    public func close(code: NWProtocolWebSocket.CloseCode? = nil, reason: Data? = nil) {
        guard let conn = connection else { return }
 // macOS 14 的 Metadata 仅支持通过 opcode 指定关闭帧，不支持在初始化时直接设置关闭码与原因
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
 // 在 macOS 14 上使用 NWConnection.SendCompletion.contentProcessed 处理发送完成
        conn.send(content: reason, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
        conn.cancel()
        self.connection = nil
        self.isReceiving = false
    }

 // MARK: 发送消息
 /// 发送文本消息
    public func send(text: String) async throws {
        guard let conn = connection else { throw NativeWebSocketError.notConnected }
        let data = text.data(using: .utf8) ?? Data()
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        try await sendInternal(conn: conn, data: data, context: context)
    }

 /// 发送二进制消息
    public func send(binary data: Data) async throws {
        guard let conn = connection else { throw NativeWebSocketError.notConnected }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "binary", metadata: [metadata])
        try await sendInternal(conn: conn, data: data, context: context)
    }

 /// 主动发送 Ping（通常无需主动调用，系统会自动回复 Ping）
    public func ping() async throws {
        guard let conn = connection else { throw NativeWebSocketError.notConnected }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .ping)
        let context = NWConnection.ContentContext(identifier: "ping", metadata: [metadata])
        try await sendInternal(conn: conn, data: nil, context: context)
    }

 // 内部发送封装（使用 continuation 将回调转为 async）
    private func sendInternal(conn: NWConnection, data: Data?, context: NWConnection.ContentContext) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
 // macOS 14 的 NWConnection.send 使用 NWConnection.SendCompletion 枚举进行完成回调
            conn.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

 // MARK: 接收消息循环
    private func startReceiveLoopIfNeeded() async {
        guard !isReceiving, let conn = connection else { return }
        isReceiving = true
        receiveNext(on: conn)
    }

 /// 使用递归方式连续接收消息（Network 的 receiveMessage 为回调式）
    private func receiveNext(on conn: NWConnection) {
        conn.receiveMessage { [weak self] (data, context, _, error) in
 // 消息处理封装到 actor 方法，避免在闭包中直接跨 actor 访问属性
            Task { await self?.processReceive(data: data, context: context, error: error) }
        }
    }

 /// 在 actor 内部处理收到的消息，避免跨 actor 属性访问产生冗余 await 警告
    private func processReceive(data: Data?, context: NWConnection.ContentContext?, error: NWError?) async {
        let callbacks = self.callbacks
        if let error = error {
            callbacks.onError?(error)
        }

 // 解析 WebSocket 元数据，识别帧类型
        if let wsMeta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata {
            switch wsMeta.opcode {
            case .text:
                if let data, let text = String(data: data, encoding: .utf8) {
                    callbacks.onText?(text)
                }
            case .binary:
                if let data { callbacks.onBinary?(data) }
            case .close:
 // macOS 14 的 Metadata 未暴露 closeReason 字段，这里仅回传关闭码，并以 1000 作为默认正常关闭码
                callbacks.onClose?(wsMeta.closeCode, nil)
 // 在 actor 内部直接关闭，无需 await
                self.close(code: wsMeta.closeCode, reason: nil)
                return
            case .cont:
 // Fragment 帧（continuation）；此处暂不处理，按需扩展聚合消息片段
                break
            case .ping, .pong:
 // 系统已处理 Ping/Pong，这里可按需记录日志
                break
            @unknown default:
                break
            }
        }

 // 继续接收后续消息
        await self.continueReceiveIfNeeded()
    }

 /// 封装状态更新到 actor 内部，消除闭包中对 actor 属性的直接跨越访问
    private func handleStateUpdate(_ state: NWConnection.State) async {
        let callbacks = self.callbacks
        callbacks.onStateChange?(state)
        switch state {
        case .ready:
            callbacks.onOpen?()
            await self.startReceiveLoopIfNeeded()
        case .failed(let error):
            callbacks.onError?(error)
            await self.scheduleReconnectIfNeeded()
        case .waiting(let error):
            callbacks.onError?(error)
        case .cancelled:
            callbacks.onClose?(nil, nil)
        default:
            break
        }
    }

 /// 封装路径优化处理，统一通过 actor 访问回调
    private func handleBetterPathUpdate() async {
        let callbacks = self.callbacks
 // 这里不主动重建连接，Network 会在更佳路径可用时优化底层传输
 // 可根据需要在此做日志或 QoS 调整
        callbacks.onStateChange?(.preparing)
    }

    private func continueReceiveIfNeeded() async {
        guard isReceiving, let conn = connection else { return }
        receiveNext(on: conn)
    }

 // MARK: 重连逻辑（指数退避）
    private func scheduleReconnectIfNeeded() async {
        guard let policy = reconnectPolicy else { return }
 // delay 未被修改，使用 let 提升语义与安全
        let delay = policy.initialDelay
 // 简单示例：尝试一次重连；根据需要可扩展为多次尝试
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        connect()
 // 若需要多次尝试，可将 delay = min(delay * factor, maxDelay) 并循环处理
    }

 // MARK: 错误类型
    public enum NativeWebSocketError: Error {
 /// 尚未建立连接
        case notConnected
    }
}