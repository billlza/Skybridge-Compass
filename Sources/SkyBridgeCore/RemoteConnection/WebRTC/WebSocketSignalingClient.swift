import Foundation
import OSLog
import Network

/// 基于 `NativeWebSocketClient` 的 WebRTC 信令客户端（macOS 侧）
///
/// 设计目标：
/// - 只提供最小能力：connect / send / onEnvelope
/// - 具体 session join/leave 逻辑由上层管理器处理
public actor WebSocketSignalingClient {
    private let logger = Logger(subsystem: "com.skybridge.signal", category: "WebRTCSignalingWS")
    private let url: URL
    
    private var ws: NativeWebSocketClient?
    private var isConnected: Bool = false
    
    public var onEnvelope: (@Sendable (WebRTCSignalingEnvelope) -> Void)?
    
    public init(url: URL) {
        self.url = url
    }
    
    public func setOnEnvelope(_ handler: (@Sendable (WebRTCSignalingEnvelope) -> Void)?) {
        self.onEnvelope = handler
    }
    
    public func connect() async {
        guard ws == nil else { return }
        
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
    
    public func close() async {
        if let ws {
            await ws.close()
        }
        ws = nil
        isConnected = false
    }
    
    public func send(_ envelope: WebRTCSignalingEnvelope) async throws {
        guard let ws else { return }
        let data = try JSONEncoder().encode(envelope)
        guard let text = String(data: data, encoding: .utf8) else { return }
        try await ws.send(text: text)
    }
    
    // MARK: - Internal handlers
    
    private func handleOpen() {
        isConnected = true
        logger.info("✅ signaling websocket open")
    }
    
    private func handleClose() {
        isConnected = false
        logger.info("⏹️ signaling websocket closed")
    }
    
    private func handleError(_ error: NWError) {
        isConnected = false
        logger.error("❌ signaling websocket error: \(error.localizedDescription, privacy: .public)")
    }
    
    private func handleText(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        do {
            let env = try JSONDecoder().decode(WebRTCSignalingEnvelope.self, from: data)
            onEnvelope?(env)
        } catch {
            // 服务端可能会推非 JSON 的日志/提示，忽略
            logger.debug("ignoring non-envelope message: \(text.prefix(200), privacy: .public)")
        }
    }
}

/// 轻量 Actor 捕获盒子：避免在 nonisolated 回调里直接捕获 actor。
private final class ActorBox<T: Actor>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) { self.value = value }
}


