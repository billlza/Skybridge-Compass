import Foundation
import OSLog

@available(iOS 17.0, *)
public actor WebSocketSignalingClient {
    public enum SignalingError: LocalizedError {
        case notConnected

        public var errorDescription: String? {
            switch self {
            case .notConnected:
                return "信令 WebSocket 未连接"
            }
        }
    }

    private let logger = Logger(subsystem: "com.skybridge.compass.ios", category: "WebRTCSignalingWS")
    private let url: URL
    private var task: URLSessionWebSocketTask?
    private let session: URLSession
    private var receiveLoopTask: Task<Void, Never>?
    
    public var onEnvelope: (@Sendable (WebRTCSignalingEnvelope) -> Void)?
    
    public init(url: URL) {
        self.url = url
        self.session = URLSession(configuration: .default)
    }
    
    public func setOnEnvelope(_ handler: (@Sendable (WebRTCSignalingEnvelope) -> Void)?) {
        self.onEnvelope = handler
    }
    
    public func connect() {
        guard task == nil else { return }
        let t = session.webSocketTask(with: url)
        self.task = t
        t.resume()
        logger.info("connecting signaling websocket… \(self.url.absoluteString, privacy: .public)")
        startReceiveLoop()
    }
    
    public func close() {
        receiveLoopTask?.cancel()
        receiveLoopTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }
    
    public func send(_ envelope: WebRTCSignalingEnvelope) async throws {
        guard let task else {
            throw SignalingError.notConnected
        }
        let data = try JSONEncoder().encode(envelope)
        guard let text = String(data: data, encoding: .utf8) else { return }
        try await task.send(.string(text))
    }
    
    private func startReceiveLoop() {
        guard receiveLoopTask == nil else { return }
        receiveLoopTask = Task { [weak self] in
            guard let self else { return }
            await self.receiveLoop()
        }
    }
    
    private func receiveLoop() async {
        defer { receiveLoopTask = nil }
        while !Task.isCancelled {
            guard let task else { return }
            do {
                let msg = try await task.receive()
                switch msg {
                case .string(let text):
                    handleText(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        handleText(text)
                    }
                @unknown default:
                    break
                }
            } catch {
                logger.error("signaling receive failed: \(error.localizedDescription, privacy: .public)")
                task.cancel(with: .goingAway, reason: nil)
                self.task = nil
                return
            }
        }
    }
    
    private func handleText(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        do {
            let env = try JSONDecoder().decode(WebRTCSignalingEnvelope.self, from: data)
            onEnvelope?(env)
        } catch {
            logger.debug("ignoring non-envelope message: \(text.prefix(200), privacy: .public)")
        }
    }
}
