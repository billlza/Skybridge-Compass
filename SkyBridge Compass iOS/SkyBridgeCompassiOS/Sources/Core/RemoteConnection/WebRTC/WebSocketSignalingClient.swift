import Foundation
import OSLog

@available(iOS 17.0, *)
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
    public var onServerFrame: (@Sendable (SignalingServerFrame) -> Void)?
    public var onTrace: (@Sendable (String) -> Void)?
    
    public init(url: URL) {
        self.url = url
        self.session = URLSession(configuration: .default)
    }
    
    public func setOnEnvelope(_ handler: (@Sendable (WebRTCSignalingEnvelope) -> Void)?) {
        self.onEnvelope = handler
    }

    public func setOnServerFrame(_ handler: (@Sendable (SignalingServerFrame) -> Void)?) {
        self.onServerFrame = handler
    }

    public func setOnTrace(_ handler: (@Sendable (String) -> Void)?) {
        self.onTrace = handler
    }
    
    public func connect() {
        guard task == nil else { return }
        let t = session.webSocketTask(with: url)
        self.task = t
        t.resume()
        logger.info("connecting signaling websocket… \(Self.redactedURLString(self.url), privacy: .public)")
        onTrace?("connect url=\(Self.redactedURLString(self.url))")
        startReceiveLoop()
    }
    
    public func close() {
        onTrace?("close")
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
        onTrace?(
            "send session=\(envelope.sessionId) type=\(envelope.type.rawValue) from=\(envelope.from) to=\(envelope.to ?? "-") auth=\(envelope.authToken == nil ? 0 : 1)"
        )
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
        onTrace?("receive-loop start")
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
                onTrace?("receive-loop failed error=\(error.localizedDescription)")
                task.cancel(with: .goingAway, reason: nil)
                self.task = nil
                return
            }
        }
        onTrace?("receive-loop ended cancelled=\(Task.isCancelled ? 1 : 0)")
    }
    
    private func handleText(_ text: String) {
        switch Self.parseInboundText(text) {
        case .envelope(let env):
            onTrace?(
                "recv-envelope session=\(env.sessionId) type=\(env.type.rawValue) from=\(env.from) to=\(env.to ?? "-") auth=\(env.authToken == nil ? 0 : 1)"
            )
            onEnvelope?(env)
        case .serverFrame(let frame):
            onTrace?(
                "recv-server-frame type=\(frame.type) session=\(frame.sessionId ?? "-") error=\(frame.error ?? "-")"
            )
            onServerFrame?(frame)
            if frame.isError {
                logger.error("❌ signaling server error: \(frame.error ?? "unknown", privacy: .public)")
            } else {
                logger.debug("ℹ️ signaling server frame: type=\(frame.type, privacy: .public)")
            }
        case .unknown:
            onTrace?("recv-unknown bytes=\(text.utf8.count)")
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

    public static func redactedURLString(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.host ?? "<redacted>"
        }
        components.queryItems = components.queryItems?.map { item in
            guard item.name == "st" else { return item }
            return URLQueryItem(name: item.name, value: "<redacted>")
        }
        return components.string ?? components.host ?? "<redacted>"
    }
}
