import CFNetwork
import Foundation
import OSLog

@available(iOS 17.0, *)
public actor WebSocketSignalingClient {
    public enum InboundMessage: Sendable, Equatable {
        case envelope(WebRTCSignalingEnvelope)
        case serverFrame(SignalingServerFrame)
        case unknown
    }

    public enum SignalingBackend: String, Sendable, Equatable, Hashable {
        case urlSession
        case native
    }

    public enum SignalingLifecyclePhase: String, Sendable, Equatable {
        case idle
        case connecting
        case socketOpen
        case bound
        case reconnecting
        case closing
        case closed
        case failed
    }

    public enum SignalingFailureClass: String, Sendable, Equatable {
        case authBindRejected
        case invalidShardOrSessionMismatch
        case tokenExpired
        case transientNetwork
        case transientServer
        case protocolViolation
    }

    public struct SignalingHandleID: Sendable, Equatable, Hashable {
        public let sessionId: String
        public let backend: SignalingBackend
        public let generation: Int

        public init(sessionId: String, backend: SignalingBackend, generation: Int) {
            self.sessionId = sessionId
            self.backend = backend
            self.generation = generation
        }
    }

    public struct SignalingLifecycleEvent: Sendable, Equatable {
        public let handleId: SignalingHandleID
        public let phase: SignalingLifecyclePhase
        public let serverFrameType: String?
        public let failureClass: SignalingFailureClass?
        public let errorDescription: String?
        public let occurredAt: Date

        public init(
            handleId: SignalingHandleID,
            phase: SignalingLifecyclePhase,
            serverFrameType: String? = nil,
            failureClass: SignalingFailureClass? = nil,
            errorDescription: String? = nil,
            occurredAt: Date = Date()
        ) {
            self.handleId = handleId
            self.phase = phase
            self.serverFrameType = serverFrameType
            self.failureClass = failureClass
            self.errorDescription = errorDescription
            self.occurredAt = occurredAt
        }
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
        case sendRequiresBound
        case serverRejected(String)
        case backendFailed(SignalingBackend, String)

        public var errorDescription: String? {
            switch self {
            case .notConnected:
                return "信令 WebSocket 未连接"
            case .connectTimedOut:
                return "信令 WebSocket 连接超时"
            case .sendRequiresBound:
                return "信令通道尚未 bound，不能发送业务消息"
            case .serverRejected(let reason):
                return "信令服务器拒绝请求: \(reason)"
            case .backendFailed(let backend, let reason):
                return "信令后端 \(backend.rawValue) 失败: \(reason)"
            }
        }
    }

    private enum BackendSelectionPolicy: String {
        case auto
        case native
        case urlsession

        static func current() -> BackendSelectionPolicy {
            let raw = ProcessInfo.processInfo.environment["SKYBRIDGE_SIGNALING_TRANSPORT"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""
            return BackendSelectionPolicy(rawValue: raw) ?? .auto
        }
    }

    private enum TransportAttempt: Equatable {
        case urlSession(proxyBypass: Bool)
        case native(proxyBypass: Bool)

        var backend: SignalingBackend {
            switch self {
            case .urlSession:
                return .urlSession
            case .native:
                return .native
            }
        }

        var label: String {
            switch self {
            case .urlSession(let proxyBypass):
                return proxyBypass ? "urlsession-proxy-bypass" : "urlsession"
            case .native(let proxyBypass):
                return proxyBypass ? "native-proxy-bypass" : "native"
            }
        }
    }

    private let logger = Logger(subsystem: "com.skybridge.signal", category: "WebRTCSignalingWS")
    private let url: URL
    private let sessionId: String
    private var nextSequenceGeneration: Int
    private let connectionTimeout: Duration = .seconds(5)
    private static let websocketRequestTimeoutSeconds: TimeInterval = 120
    private static let websocketResourceTimeoutSeconds: TimeInterval = 60 * 60 * 24
    private let selectionPolicy: BackendSelectionPolicy
    private let nativeFallbackEnabled: Bool

    private var currentHandle: SignalingHandleID?
    private var lifecyclePhase: SignalingLifecyclePhase = .idle
    private var isBound: Bool = false
    private var isSocketOpen: Bool = false
    private var hasEverBound: Bool = false
    private var isConnectingSequence: Bool = false
    private var connectWaiters: [CheckedContinuation<Void, Error>] = []
    private var terminalErrorsByHandle: [SignalingHandleID: Error] = [:]

    private var urlSession: URLSession?
    private var urlSessionDelegate: URLSessionSignalingDelegate?
    private var urlTask: URLSessionWebSocketTask?
    private var urlReceiveLoopTask: Task<Void, Never>?
    private var nativeClient: NativeWebSocketClient?

    public var onEnvelope: (@Sendable (WebRTCSignalingEnvelope) -> Void)?
    public var onServerFrame: (@Sendable (SignalingServerFrame) -> Void)?
    public var onLifecycleEvent: (@Sendable (SignalingLifecycleEvent) -> Void)?
    public var onTrace: (@Sendable (String) -> Void)?

    public init(url: URL, sessionId: String, generation: Int) {
        self.url = url
        self.sessionId = sessionId
        self.nextSequenceGeneration = generation
        self.selectionPolicy = BackendSelectionPolicy.current()
        self.nativeFallbackEnabled = ProcessInfo.processInfo.environment["SKYBRIDGE_SIGNALING_DISABLE_NATIVE_FALLBACK"] != "1"
    }

    public func setOnEnvelope(_ handler: (@Sendable (WebRTCSignalingEnvelope) -> Void)?) {
        onEnvelope = handler
    }

    public func setOnServerFrame(_ handler: (@Sendable (SignalingServerFrame) -> Void)?) {
        onServerFrame = handler
    }

    public func setOnLifecycleEvent(_ handler: (@Sendable (SignalingLifecycleEvent) -> Void)?) {
        onLifecycleEvent = handler
    }

    public func setOnTrace(_ handler: (@Sendable (String) -> Void)?) {
        onTrace = handler
    }

    public func connect() async {
        do {
            try await connectOrThrow()
        } catch {
            logger.error("❌ signaling websocket connect failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func connectOrThrow(timeout: Duration? = nil) async throws {
        if isBound {
            return
        }
        if isConnectingSequence {
            try await waitForBound()
            return
        }

        isConnectingSequence = true
        defer { isConnectingSequence = false }

        do {
            try await performConnectSequence(timeout: timeout ?? connectionTimeout)
            resumeConnectWaiters()
        } catch {
            failConnectWaiters(with: error)
            throw error
        }
    }

    public func close() async {
        if let currentHandle {
            emitLifecycle(
                phase: .closing,
                handleId: currentHandle,
                errorDescription: nil,
                failureClass: nil,
                serverFrameType: nil
            )
        }

        isBound = false
        isSocketOpen = false
        lifecyclePhase = .closed
        terminalErrorsByHandle.removeAll()
        onTrace?("close")

        await cleanupURLSessionTransport()
        await cleanupNativeTransport()

        if let currentHandle {
            emitLifecycle(
                phase: .closed,
                handleId: currentHandle,
                errorDescription: nil,
                failureClass: nil,
                serverFrameType: nil
            )
        }

        currentHandle = nil
        failConnectWaiters(with: SignalingError.notConnected)
    }

    public func send(_ envelope: WebRTCSignalingEnvelope) async throws {
        try await connectOrThrow()
        guard isBound, let handleId = currentHandle else {
            throw SignalingError.sendRequiresBound
        }
        let data = try JSONEncoder().encode(envelope)
        guard let text = String(data: data, encoding: .utf8) else { return }
        onTrace?(
            "send session=\(envelope.sessionId) type=\(envelope.type.rawValue) from=\(envelope.from) to=\(envelope.to ?? "-") auth=\(envelope.authToken == nil ? 0 : 1) backend=\(handleId.backend.rawValue)"
        )

        switch handleId.backend {
        case .urlSession:
            guard let urlTask else { throw SignalingError.notConnected }
            do {
                try await urlTask.send(.string(text))
            } catch {
                let ns = error as NSError
                if ns.domain == NSURLErrorDomain {
                    throw SignalingError.notConnected
                }
                throw error
            }
        case .native:
            guard let nativeClient else { throw SignalingError.notConnected }
            try await nativeClient.send(text: text)
        }
    }

    public func currentLifecyclePhase() -> SignalingLifecyclePhase {
        lifecyclePhase
    }

    public func currentHandleID() -> SignalingHandleID? {
        currentHandle
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

    private func performConnectSequence(timeout: Duration) async throws {
        let attempts = transportAttempts()
        var lastError: Error = SignalingError.connectTimedOut

        for attempt in attempts {
            let handleId = reserveNextHandleId(for: attempt.backend)
            currentHandle = handleId
            isBound = false
            isSocketOpen = false
            terminalErrorsByHandle[handleId] = nil

            let phase: SignalingLifecyclePhase = hasEverBound ? .reconnecting : .connecting
            lifecyclePhase = phase
            emitLifecycle(
                phase: phase,
                handleId: handleId,
                errorDescription: nil,
                failureClass: nil,
                serverFrameType: nil
            )
            onTrace?("connect backend=\(attempt.label) url=\(Self.redactedURLString(self.url))")

            do {
                switch attempt {
                case .urlSession(let proxyBypass):
                    try await connectViaURLSession(
                        handleId: handleId,
                        proxyBypass: proxyBypass,
                        timeout: timeout
                    )
                case .native(let proxyBypass):
                    try await connectViaNative(
                        handleId: handleId,
                        proxyBypass: proxyBypass,
                        timeout: timeout
                    )
                }
                return
            } catch {
                lastError = error
                if error is CancellationError {
                    logger.debug(
                        "ℹ️ signaling connect attempt cancelled: session=\(self.sessionId, privacy: .public) backend=\(attempt.label, privacy: .public)"
                    )
                } else {
                    logger.error(
                        "❌ signaling connect attempt failed: session=\(self.sessionId, privacy: .public) backend=\(attempt.label, privacy: .public) err=\(error.localizedDescription, privacy: .public)"
                    )
                }
                onTrace?("connect-failed backend=\(attempt.label) err=\(error.localizedDescription)")
                await cleanupTransport(for: attempt.backend)
                if currentHandle == handleId {
                    currentHandle = nil
                }
            }
        }

        throw lastError
    }

    private func transportAttempts() -> [TransportAttempt] {
        switch selectionPolicy {
        case .urlsession:
            return [.urlSession(proxyBypass: false)]
        case .native:
            return [.native(proxyBypass: false)]
        case .auto:
            var attempts: [TransportAttempt] = []
            if nativeFallbackEnabled {
                attempts.append(.native(proxyBypass: true))
            }
            attempts.append(.urlSession(proxyBypass: true))
            if nativeFallbackEnabled {
                attempts.append(.native(proxyBypass: false))
            }
            attempts.append(.urlSession(proxyBypass: false))
            return attempts
        }
    }

    private func reserveNextHandleId(for backend: SignalingBackend) -> SignalingHandleID {
        let generation = nextSequenceGeneration
        nextSequenceGeneration += 1
        return SignalingHandleID(
            sessionId: sessionId,
            backend: backend,
            generation: generation
        )
    }

    private func connectViaURLSession(
        handleId: SignalingHandleID,
        proxyBypass: Bool,
        timeout: Duration
    ) async throws {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = max(
            Self.websocketRequestTimeoutSeconds,
            Self.durationSeconds(timeout)
        )
        config.timeoutIntervalForResource = max(
            Self.websocketResourceTimeoutSeconds,
            Self.durationSeconds(timeout)
        )
        config.allowsConstrainedNetworkAccess = true
        config.allowsExpensiveNetworkAccess = true
        if proxyBypass {
            config.connectionProxyDictionary = Self.noProxyConnectionProxyDictionary()
        }

        let delegate = URLSessionSignalingDelegate(
            onOpen: { [weakSelf = ActorBox(self)] in
                Task { await weakSelf.value?.handleSocketOpen(handleId: handleId) }
            },
            onClose: { [weakSelf = ActorBox(self)] closeCode, _ in
                Task {
                    await weakSelf.value?.handleClosed(
                        handleId: handleId,
                        errorDescription: "websocket closed (\(closeCode.rawValue))"
                    )
                }
            }
        )
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        let task = session.webSocketTask(with: url)
        urlSessionDelegate = delegate
        urlSession = session
        urlTask = task
        task.resume()
        startURLSessionReceiveLoop(handleId: handleId, task: task)

        do {
            try await waitUntilBound(handleId: handleId, timeout: timeout)
        } catch {
            if proxyBypass || !shouldRetryBypassingProxy(error) {
                throw error
            }
            throw SignalingError.backendFailed(.urlSession, error.localizedDescription)
        }
    }

    private func connectViaNative(
        handleId: SignalingHandleID,
        proxyBypass: Bool,
        timeout: Duration
    ) async throws {
        let callbacks = NativeWebSocketCallbacks(
            onOpen: { [weakSelf = ActorBox(self)] in
                Task { await weakSelf.value?.handleSocketOpen(handleId: handleId) }
            },
            onText: { [weakSelf = ActorBox(self)] text in
                Task { await weakSelf.value?.handleText(handleId: handleId, text: text) }
            },
            onBinary: { _ in },
            onStateChange: { _ in },
            onClose: { [weakSelf = ActorBox(self)] _, _ in
                Task { await weakSelf.value?.handleClosed(handleId: handleId, errorDescription: "native websocket closed") }
            },
            onError: { [weakSelf = ActorBox(self)] error in
                Task { await weakSelf.value?.handleErrored(handleId: handleId, error: error) }
            }
        )

        let client = NativeWebSocketClient(
            url: url,
            tls: (url.scheme == "wss"),
            pingInterval: 30,
            preferNoProxies: proxyBypass,
            callbacks: callbacks
        )
        nativeClient = client
        await client.connect()
        try await waitUntilBound(handleId: handleId, timeout: timeout)
    }

    private func startURLSessionReceiveLoop(handleId: SignalingHandleID, task: URLSessionWebSocketTask) {
        urlReceiveLoopTask?.cancel()
        urlReceiveLoopTask = Task { [weakSelf = ActorBox(self)] in
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    switch message {
                    case .string(let text):
                        await weakSelf.value?.handleText(handleId: handleId, text: text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            await weakSelf.value?.handleText(handleId: handleId, text: text)
                        }
                    @unknown default:
                        break
                    }
                } catch {
                    await weakSelf.value?.handleErrored(handleId: handleId, error: error)
                    return
                }
            }
        }
    }

    private func waitUntilBound(handleId: SignalingHandleID, timeout: Duration) async throws {
        let deadline = Date().addingTimeInterval(Self.durationSeconds(timeout))
        while Date() < deadline {
            if currentHandle == handleId, isBound {
                return
            }
            if let error = terminalErrorsByHandle[handleId] {
                throw error
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw SignalingError.connectTimedOut
    }

    private func waitForBound() async throws {
        if isBound {
            return
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connectWaiters.append(continuation)
        }
    }

    private func resumeConnectWaiters() {
        let waiters = connectWaiters
        connectWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func failConnectWaiters(with error: Error) {
        guard !connectWaiters.isEmpty else { return }
        let waiters = connectWaiters
        connectWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume(throwing: error)
        }
    }

    private func handleSocketOpen(handleId: SignalingHandleID) {
        if currentHandle == handleId {
            isSocketOpen = true
            lifecyclePhase = .socketOpen
        }
        emitLifecycle(
            phase: .socketOpen,
            handleId: handleId,
            errorDescription: nil,
            failureClass: nil,
            serverFrameType: nil
        )
        onTrace?("socket-open backend=\(handleId.backend.rawValue)")
    }

    private func handleText(handleId: SignalingHandleID, text: String) {
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
            if frame.type == "bound" {
                if currentHandle == handleId {
                    isSocketOpen = true
                    isBound = true
                    hasEverBound = true
                    lifecyclePhase = .bound
                }
                emitLifecycle(
                    phase: .bound,
                    handleId: handleId,
                    errorDescription: nil,
                    failureClass: nil,
                    serverFrameType: frame.type
                )
                return
            }
            if frame.isError {
                let reason = frame.error ?? "unknown"
                let error = SignalingError.serverRejected(reason)
                terminalErrorsByHandle[handleId] = error
                if currentHandle == handleId {
                    isBound = false
                    lifecyclePhase = .failed
                }
                emitLifecycle(
                    phase: .failed,
                    handleId: handleId,
                    errorDescription: reason,
                    failureClass: Self.classifyServerError(reason),
                    serverFrameType: frame.type
                )
                logger.error("❌ signaling server error: \(reason, privacy: .public)")
            }
        case .unknown:
            onTrace?("recv-unknown bytes=\(text.utf8.count)")
            logger.debug("ignoring non-envelope message: \(text.prefix(200), privacy: .public)")
        }
    }

    private func handleClosed(handleId: SignalingHandleID, errorDescription: String) async {
        if currentHandle == handleId {
            isSocketOpen = false
            isBound = false
            lifecyclePhase = .closed
        }
        terminalErrorsByHandle[handleId] = SignalingError.notConnected
        emitLifecycle(
            phase: .closed,
            handleId: handleId,
            errorDescription: errorDescription,
            failureClass: .transientNetwork,
            serverFrameType: nil
        )
        onTrace?("closed backend=\(handleId.backend.rawValue) reason=\(errorDescription)")
    }

    private func handleErrored(handleId: SignalingHandleID, error: Error) async {
        if currentHandle == handleId {
            isSocketOpen = false
            isBound = false
            lifecyclePhase = .failed
        }
        terminalErrorsByHandle[handleId] = error
        emitLifecycle(
            phase: .failed,
            handleId: handleId,
            errorDescription: error.localizedDescription,
            failureClass: Self.classifyTransportError(error),
            serverFrameType: nil
        )
        onTrace?("errored backend=\(handleId.backend.rawValue) err=\(error.localizedDescription)")
    }

    private func emitLifecycle(
        phase: SignalingLifecyclePhase,
        handleId: SignalingHandleID,
        errorDescription: String?,
        failureClass: SignalingFailureClass?,
        serverFrameType: String?
    ) {
        onLifecycleEvent?(
            SignalingLifecycleEvent(
                handleId: handleId,
                phase: phase,
                serverFrameType: serverFrameType,
                failureClass: failureClass,
                errorDescription: errorDescription
            )
        )
    }

    private func cleanupURLSessionTransport() async {
        urlReceiveLoopTask?.cancel()
        urlReceiveLoopTask = nil
        if let urlTask {
            urlTask.cancel(with: .goingAway, reason: nil)
        }
        urlTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        urlSessionDelegate = nil
    }

    private func cleanupNativeTransport() async {
        if let nativeClient {
            await nativeClient.close()
        }
        nativeClient = nil
    }

    private func cleanupTransport(for backend: SignalingBackend) async {
        switch backend {
        case .urlSession:
            await cleanupURLSessionTransport()
        case .native:
            await cleanupNativeTransport()
        }
    }

    private static func classifyServerError(_ reason: String) -> SignalingFailureClass {
        let normalized = reason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.contains("token") && normalized.contains("expired") {
            return .tokenExpired
        }
        if normalized.contains("auth")
            || normalized.contains("unauthorized")
            || normalized.contains("forbidden")
            || normalized.contains("bind_rejected") {
            return .authBindRejected
        }
        if normalized.contains("invalid shard")
            || normalized.contains("invalid session")
            || normalized.contains("session mismatch")
            || normalized.contains("scope mismatch")
            || normalized.contains("unknown shard")
            || normalized.contains("room_full") {
            return .invalidShardOrSessionMismatch
        }
        if normalized.contains("protocol") || normalized.contains("malformed") {
            return .protocolViolation
        }
        return .transientServer
    }

    private static func classifyTransportError(_ error: Error) -> SignalingFailureClass {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain || ns.domain == NSPOSIXErrorDomain {
            return .transientNetwork
        }
        let message = ns.localizedDescription.lowercased()
        if message.contains("socket is not connected")
            || message.contains("socket未连接")
            || message.contains("network")
            || message.contains("timed out") {
            return .transientNetwork
        }
        return .transientServer
    }

    private func shouldRetryBypassingProxy(_ error: Error) -> Bool {
        let message = (error as NSError).localizedDescription.lowercased()
        if message.contains("127.0.0.1")
            || message.contains("1082")
            || message.contains("socket is not connected")
            || message.contains("socket未连接") {
            return true
        }

        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorSecureConnectionFailed,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorTimedOut,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorCannotFindHost,
                 NSURLErrorDNSLookupFailed:
                return true
            default:
                break
            }
        }

        return false
    }

    private static func durationSeconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000.0
    }

    private static func noProxyConnectionProxyDictionary() -> [AnyHashable: Any] {
        [
            kCFProxyTypeKey as String: kCFProxyTypeNone as String,
            kCFNetworkProxiesHTTPEnable as String: false,
            "HTTPSEnable": false,
            "SOCKSEnable": false,
            "ProxyAutoConfigEnable": false,
            "ProxyAutoDiscoveryEnable": false,
            "ExceptionsList": [],
            "ExcludeSimpleHostnames": false
        ]
    }
}

private final class ActorBox<T: Actor>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

@available(iOS 17.0, *)
extension WebSocketSignalingClient {
    internal func testOnlyReserveNextHandleId(
        for backend: SignalingBackend
    ) -> SignalingHandleID {
        reserveNextHandleId(for: backend)
    }

    internal func testOnlyTransportAttemptLabels() -> [String] {
        transportAttempts().map(\.label)
    }

    internal static func testOnlyNoProxyConnectionProxyDictionary() -> [AnyHashable: Any] {
        noProxyConnectionProxyDictionary()
    }
}

private final class URLSessionSignalingDelegate: NSObject, URLSessionWebSocketDelegate {
    private let onOpen: @Sendable () -> Void
    private let onClose: @Sendable (URLSessionWebSocketTask.CloseCode, Data?) -> Void

    init(
        onOpen: @escaping @Sendable () -> Void,
        onClose: @escaping @Sendable (URLSessionWebSocketTask.CloseCode, Data?) -> Void
    ) {
        self.onOpen = onOpen
        self.onClose = onClose
    }

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        onOpen()
    }

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        onClose(closeCode, reason)
    }
}
