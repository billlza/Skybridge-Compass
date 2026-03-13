import Foundation
import OSLog
import Network
import SkyBridgeProtocolCore

/// 基于 `NativeWebSocketClient` 的 WebRTC 信令客户端（macOS 侧）
///
/// 设计目标：
/// - 只提供最小能力：connect / send / onEnvelope
/// - 具体 session join/leave 逻辑由上层管理器处理
public actor WebSocketSignalingClient {
    public enum InboundMessage: Sendable, Equatable {
        case envelope(WebRTCSignalingEnvelope)
        case serverFrame(SignalingServerFrame)
        case unknown
    }

    public struct SignalingServerFrame: Decodable, Sendable, Equatable {
        public let type: String
        public let error: String?
        public let sessionId: String?
        public let what: String?

        public var isError: Bool {
            type == "error" && !(error?.isEmpty ?? true)
        }
    }

    public enum SignalingError: LocalizedError {
        case notConnected
        case connectTimedOut
        case serverRejected(String)

        public var errorDescription: String? {
            switch self {
            case .notConnected:
                return "信令 WebSocket 未连接"
            case .connectTimedOut:
                return "信令 WebSocket 连接超时"
            case .serverRejected(let reason):
                return "信令服务器拒绝请求: \(reason)"
            }
        }
    }

    private let logger = Logger(subsystem: "com.skybridge.signal", category: "WebRTCSignalingWS")
    private let url: URL
    private let connectionTimeout: Duration = .seconds(5)
    
    private var ws: NativeWebSocketClient?
    private var isConnected: Bool = false
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []
    
    public var onEnvelope: (@Sendable (WebRTCSignalingEnvelope) -> Void)?
    public var onServerFrame: (@Sendable (SignalingServerFrame) -> Void)?
    
    public init(url: URL) {
        self.url = url
    }
    
    public func setOnEnvelope(_ handler: (@Sendable (WebRTCSignalingEnvelope) -> Void)?) {
        self.onEnvelope = handler
    }

    public func setOnServerFrame(_ handler: (@Sendable (SignalingServerFrame) -> Void)?) {
        self.onServerFrame = handler
    }
    
    public func connect() async {
        do {
            try await connectOrThrow(timeout: connectionTimeout)
        } catch {
            logger.error("❌ signaling websocket connect failed: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    public func close() async {
        if let ws {
            await ws.close()
        }
        ws = nil
        isConnected = false
        failReadyWaiters(with: SignalingError.notConnected)
    }
    
    public func send(_ envelope: WebRTCSignalingEnvelope) async throws {
        try await connectOrThrow(timeout: connectionTimeout)
        guard let ws, isConnected else {
            throw SignalingError.notConnected
        }
        let data = try JSONEncoder().encode(envelope)
        guard let text = String(data: data, encoding: .utf8) else { return }
        try await ws.send(text: text)
    }
    
    // MARK: - Internal handlers
    
    private func handleOpen() {
        isConnected = true
        resumeReadyWaiters()
        logger.info("✅ signaling websocket open")
    }
    
    private func handleClose() {
        isConnected = false
        ws = nil
        failReadyWaiters(with: SignalingError.notConnected)
        logger.info("⏹️ signaling websocket closed")
    }

    private func handleError(_ error: NWError) {
        isConnected = false
        ws = nil
        failReadyWaiters(with: error)
        logger.error("❌ signaling websocket error: \(error.localizedDescription, privacy: .public)")
    }
    
    private func handleText(_ text: String) {
        switch Self.parseInboundText(text) {
        case .envelope(let env):
            onEnvelope?(env)
        case .serverFrame(let frame):
            onServerFrame?(frame)
            if frame.isError {
                logger.error("❌ signaling server error: \(frame.error ?? "unknown", privacy: .public)")
            } else {
                logger.debug("ℹ️ signaling server frame: type=\(frame.type, privacy: .public)")
            }
        case .unknown:
            // 服务端可能会推非 JSON 的日志/提示，忽略
            logger.debug("ignoring non-envelope message: \(text.prefix(200), privacy: .public)")
        }
    }

    public static func parseInboundText(_ text: String) -> InboundMessage {
        guard let data = text.data(using: .utf8) else { return .unknown }
        if let env = try? JSONDecoder().decode(WebRTCSignalingEnvelope.self, from: data) {
            return .envelope(env)
        }
        if let frame = try? JSONDecoder().decode(SignalingServerFrame.self, from: data) {
            return .serverFrame(frame)
        }
        return .unknown
    }

    private func connectOrThrow(timeout: Duration) async throws {
        if isConnected {
            return
        }

        if ws == nil {
            let callbacks = NativeWebSocketCallbacks(
                onOpen: { [weakSelf = ActorBox(self)] in
                    Task { await weakSelf.value?.handleOpen() }
                },
                onText: { [weakSelf = ActorBox(self)] text in
                    Task { await weakSelf.value?.handleText(text) }
                },
                onBinary: { _ in
                    // binary not used
                },
                onStateChange: { _ in },
                onClose: { [weakSelf = ActorBox(self)] _, _ in
                    Task { await weakSelf.value?.handleClose() }
                },
                onError: { [weakSelf = ActorBox(self)] error in
                    Task { await weakSelf.value?.handleError(error) }
                }
            )

            let client = NativeWebSocketClient(url: url, tls: (url.scheme == "wss"), pingInterval: 30, callbacks: callbacks)
            self.ws = client
            await client.connect()
        }

        do {
            try await waitUntilConnected(timeout: timeout)
        } catch {
            if !isConnected, let ws {
                await ws.close()
                self.ws = nil
            }
            failReadyWaiters(with: error)
            throw error
        }
    }

    private func waitUntilConnected(timeout: Duration) async throws {
        if isConnected {
            return
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await self.waitForReady()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw SignalingError.connectTimedOut
            }

            do {
                _ = try await group.next()
                group.cancelAll()
                while let _ = try? await group.next() {}
            } catch {
                group.cancelAll()
                while let _ = try? await group.next() {}
                throw error
            }
        }
    }

    private func waitForReady() async throws {
        if isConnected {
            return
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            readyWaiters.append(continuation)
        }
    }

    private func resumeReadyWaiters() {
        let waiters = readyWaiters
        readyWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func failReadyWaiters(with error: Error) {
        guard !readyWaiters.isEmpty else { return }
        let waiters = readyWaiters
        readyWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume(throwing: error)
        }
    }
}

/// 轻量 Actor 捕获盒子：避免在 nonisolated 回调里直接捕获 actor。
private final class ActorBox<T: Actor>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) { self.value = value }
}
