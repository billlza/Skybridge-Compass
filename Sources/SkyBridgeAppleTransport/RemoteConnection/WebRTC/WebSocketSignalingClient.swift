import CFNetwork
import Foundation
import Network
import OSLog
import SkyBridgeProtocolCore

/// Dual-stack WebRTC signaling client for macOS.
///
/// Lifecycle semantics are intentionally strict:
/// - `socketOpen` only means the websocket transport is open.
/// - `bound` only means the server accepted the shard/session binding.
/// - only `bound` unlocks signaling-plane business sends.
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
        case invalidSignalingEndpoint(String)
        case sendRequiresBound
        case protocolViolation
        case serverRejected(String)
        case backendFailed(SignalingBackend, String)

        public var errorDescription: String? {
            switch self {
            case .notConnected:
                return "信令 WebSocket 未连接"
            case .connectTimedOut:
                return "信令 WebSocket 连接超时"
            case .invalidSignalingEndpoint(let reason):
                return "信令 WebSocket 端点无效: \(reason)"
            case .sendRequiresBound:
                return "信令通道尚未 bound，不能发送业务消息"
            case .protocolViolation:
                return "信令服务器返回了与当前会话不一致的数据"
            case .serverRejected(_):
                return "信令服务器拒绝请求: \(WebSocketSignalingClient.redactedServerErrorReasonDescription)"
            case .backendFailed(let backend, let reason):
                return "信令后端 \(backend.rawValue) 失败: \(reason)"
            }
        }
    }

    enum BackendSelectionPolicy: String {
        case auto
        case urlSession
        case native

        static func current() -> BackendSelectionPolicy {
#if DEBUG || SKYBRIDGE_TESTING
            let raw = ProcessInfo.processInfo.environment["SKYBRIDGE_SIGNALING_TRANSPORT"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""
            return BackendSelectionPolicy(rawValue: raw) ?? .auto
#else
            return .auto
#endif
        }
    }

    private struct TransportConfiguration {
        let selectionPolicy: BackendSelectionPolicy
        let nativeFallbackEnabled: Bool

        static func current() -> TransportConfiguration {
#if DEBUG || SKYBRIDGE_TESTING
            return TransportConfiguration(
                selectionPolicy: BackendSelectionPolicy.current(),
                nativeFallbackEnabled: ProcessInfo.processInfo.environment["SKYBRIDGE_SIGNALING_DISABLE_NATIVE_FALLBACK"] != "1"
            )
#else
            return TransportConfiguration(selectionPolicy: .auto, nativeFallbackEnabled: true)
#endif
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
    nonisolated private static let redactedServerErrorReasonDescription = "<redacted-server-error>"
    nonisolated private static let redactedTransportErrorDescription = "<redacted-transport-error>"
    nonisolated private static let sensitiveLogRedaction = "<redacted>"
    nonisolated private static let maximumInboundTextBytes = 64 * 1024
    private let url: URL
    private let sessionId: String
    private let additionalHeaders: [String: String]
    private var nextSequenceGeneration: Int
    private let connectionTimeout: Duration = .seconds(15)
    private static let websocketRequestTimeoutSeconds: TimeInterval = 120
    private static let websocketResourceTimeoutSeconds: TimeInterval = 60 * 60 * 24
    private let selectionPolicy: BackendSelectionPolicy
    private let nativeFallbackEnabled: Bool

    private var currentHandle: SignalingHandleID?
    private var lifecyclePhase: SignalingLifecyclePhase = .idle
    private var isBound: Bool = false
    private var isSocketOpen: Bool = false
    private var hasEverBound: Bool = false
    private var lifecycleEpoch: UInt64 = 0
    private var activeConnectSequenceEpoch: UInt64?
    private var connectWaiters: [CheckedContinuation<Void, Error>] = []
    private var terminalErrorsByHandle: [SignalingHandleID: Error] = [:]
    private var lastBoundHandle: SignalingHandleID?

    private var urlSession: URLSession?
    private var urlSessionDelegate: URLSessionSignalingDelegate?
    private var urlTask: URLSessionWebSocketTask?
    private var urlReceiveLoopTask: Task<Void, Never>?

    private var nativeClient: NativeWebSocketClient?

    public var onEnvelope: (@Sendable (WebRTCSignalingEnvelope) async -> Void)?
    public var onServerFrame: (@Sendable (SignalingServerFrame) -> Void)?
    public var onLifecycleEvent: (@Sendable (SignalingLifecycleEvent) -> Void)?

    public init(url: URL, sessionId: String, generation: Int, additionalHeaders: [String: String] = [:]) {
        self.init(
            url: url,
            sessionId: sessionId,
            generation: generation,
            additionalHeaders: additionalHeaders,
            transportConfiguration: TransportConfiguration.current()
        )
    }

    private init(
        url: URL,
        sessionId: String,
        generation: Int,
        additionalHeaders: [String: String] = [:],
        transportConfiguration: TransportConfiguration
    ) {
        self.url = url
        self.sessionId = sessionId
        self.additionalHeaders = additionalHeaders
        self.nextSequenceGeneration = generation
        self.selectionPolicy = transportConfiguration.selectionPolicy
        self.nativeFallbackEnabled = transportConfiguration.nativeFallbackEnabled
    }

#if DEBUG || SKYBRIDGE_TESTING
    init(
        url: URL,
        sessionId: String,
        generation: Int,
        additionalHeaders: [String: String] = [:],
        selectionPolicy: BackendSelectionPolicy,
        nativeFallbackEnabled: Bool
    ) {
        self.init(
            url: url,
            sessionId: sessionId,
            generation: generation,
            additionalHeaders: additionalHeaders,
            transportConfiguration: TransportConfiguration(
                selectionPolicy: selectionPolicy,
                nativeFallbackEnabled: nativeFallbackEnabled
            )
        )
    }
#endif

    public func setOnEnvelope(_ handler: (@Sendable (WebRTCSignalingEnvelope) async -> Void)?) {
        onEnvelope = handler
    }

    public func setOnServerFrame(_ handler: (@Sendable (SignalingServerFrame) -> Void)?) {
        onServerFrame = handler
    }

    public func setOnLifecycleEvent(_ handler: (@Sendable (SignalingLifecycleEvent) -> Void)?) {
        onLifecycleEvent = handler
    }

    public func connect() async {
        do {
            try await connectOrThrow()
        } catch {
            logger.error("❌ signaling websocket connect failed: err=\(Self.transportErrorLogSummary(error), privacy: .public)")
        }
    }

    public func connectOrThrow(timeout: Duration? = nil) async throws {
        if isBound {
            return
        }

        if activeConnectSequenceEpoch != nil {
            try await waitForBound()
            return
        }

        lifecycleEpoch &+= 1
        let sequenceEpoch = lifecycleEpoch
        activeConnectSequenceEpoch = sequenceEpoch
        defer {
            if activeConnectSequenceEpoch == sequenceEpoch {
                activeConnectSequenceEpoch = nil
            }
        }

        do {
            // A previous terminal callback may have left its transport object
            // allocated while marking the logical channel unbound. Invalidate
            // ownership before teardown so stale close callbacks are ignored,
            // then start the new sequence from exactly zero live backends.
            currentHandle = nil
            await cleanupURLSessionTransport()
            await cleanupNativeTransport()
            try requireActiveConnectSequence(sequenceEpoch)
            isSocketOpen = false
            try await performConnectSequence(
                timeout: timeout ?? connectionTimeout,
                sequenceEpoch: sequenceEpoch
            )
            try requireActiveConnectSequence(sequenceEpoch)
            resumeConnectWaiters()
        } catch {
            if activeConnectSequenceEpoch == sequenceEpoch {
                failConnectWaiters(with: error)
            }
            throw error
        }
    }

    public func close() async {
        lifecycleEpoch &+= 1
        activeConnectSequenceEpoch = nil
        let closingHandle = currentHandle
        currentHandle = nil
        if let closingHandle {
            emitLifecycle(
                phase: .closing,
                handleId: closingHandle,
                errorDescription: nil,
                failureClass: nil,
                serverFrameType: nil
            )
        }

        isBound = false
        isSocketOpen = false
        lifecyclePhase = .closed
        terminalErrorsByHandle.removeAll()
        failConnectWaiters(with: SignalingError.notConnected)

        await cleanupURLSessionTransport()
        await cleanupNativeTransport()

        if let closingHandle {
            emitLifecycle(
                phase: .closed,
                handleId: closingHandle,
                errorDescription: nil,
                failureClass: nil,
                serverFrameType: nil
            )
        }
    }

    public func send(_ envelope: WebRTCSignalingEnvelope) async throws {
        try await connectOrThrow()
        guard isBound, let handleId = currentHandle else {
            throw SignalingError.sendRequiresBound
        }
        guard Self.sessionIDsMatch(envelope.sessionId, handleId.sessionId) else {
            throw SignalingError.protocolViolation
        }

        let data = try JSONEncoder().encode(envelope)
        guard let text = String(data: data, encoding: .utf8) else {
            throw SignalingError.protocolViolation
        }

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
        guard isBound, currentHandle == handleId else {
            throw SignalingError.notConnected
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
            let name = item.name.lowercased()
            guard name == "st"
                || name == "shard"
                || name == "sessionid"
                || name.contains("token")
                || name.contains("secret") else { return item }
            return URLQueryItem(name: item.name, value: "<redacted>")
        }
        return components.string ?? components.host ?? "<redacted>"
    }

    private func performConnectSequence(
        timeout: Duration,
        sequenceEpoch: UInt64
    ) async throws {
        let attempts = transportAttempts()
        var lastError: Error = SignalingError.connectTimedOut

        for attempt in attempts {
            try requireActiveConnectSequence(sequenceEpoch)
            let handleId = reserveNextHandleId(for: attempt.backend)
            currentHandle = handleId
            isBound = false
            isSocketOpen = false
            terminalErrorsByHandle.removeAll(keepingCapacity: true)

            let phase: SignalingLifecyclePhase = hasEverBound ? .reconnecting : .connecting
            lifecyclePhase = phase
            emitLifecycle(
                phase: phase,
                handleId: handleId,
                errorDescription: nil,
                failureClass: nil,
                serverFrameType: nil
            )

            logger.info(
                "🔌 signaling connect attempt: session=\(Self.sensitiveLogRedaction, privacy: .public) generation=\(handleId.generation, privacy: .public) backend=\(attempt.label, privacy: .public)"
            )

            do {
                switch attempt {
                case .urlSession(let proxyBypass):
                    try await connectViaURLSession(handleId: handleId, proxyBypass: proxyBypass, timeout: timeout)
                case .native(let proxyBypass):
                    try await connectViaNative(handleId: handleId, proxyBypass: proxyBypass, timeout: timeout)
                }
                try requireActiveConnectSequence(sequenceEpoch)

                logger.info(
                    "✅ signaling backend pinned after bound: session=\(Self.sensitiveLogRedaction, privacy: .public) generation=\(handleId.generation, privacy: .public) backend=\(handleId.backend.rawValue, privacy: .public)"
                )
                lastBoundHandle = handleId
                terminalErrorsByHandle.removeValue(forKey: handleId)
                return
            } catch {
                try requireActiveConnectSequence(sequenceEpoch)
                lastError = error
                if error is CancellationError {
                    logger.debug(
                        "ℹ️ signaling connect attempt cancelled: session=\(Self.sensitiveLogRedaction, privacy: .public) generation=\(handleId.generation, privacy: .public) backend=\(attempt.label, privacy: .public)"
                    )
                } else {
                    logger.error(
                        "❌ signaling connect attempt failed: session=\(Self.sensitiveLogRedaction, privacy: .public) generation=\(handleId.generation, privacy: .public) backend=\(attempt.label, privacy: .public) err=\(Self.transportErrorLogSummary(error), privacy: .public)"
                    )
                }
                await cleanupTransport(for: attempt.backend)
                try requireActiveConnectSequence(sequenceEpoch)
                terminalErrorsByHandle.removeValue(forKey: handleId)
                if currentHandle == handleId {
                    currentHandle = nil
                }
                if error is CancellationError {
                    throw error
                }
                if let signalingError = error as? SignalingError,
                   case .protocolViolation = signalingError {
                    throw error
                }
            }
        }

        throw lastError
    }

    private func requireActiveConnectSequence(_ sequenceEpoch: UInt64) throws {
        guard lifecycleEpoch == sequenceEpoch,
              activeConnectSequenceEpoch == sequenceEpoch else {
            throw CancellationError()
        }
    }

    private func transportAttempts() -> [TransportAttempt] {
        switch selectionPolicy {
        case .urlSession:
            return [.urlSession(proxyBypass: false)]
        case .native:
            return [.native(proxyBypass: false)]
        case .auto:
            var attempts: [TransportAttempt] = []
#if os(macOS)
            if nativeFallbackEnabled {
                attempts.append(.native(proxyBypass: true))
            }
            attempts.append(.urlSession(proxyBypass: true))
            if nativeFallbackEnabled {
                attempts.append(.native(proxyBypass: false))
            }
            attempts.append(.urlSession(proxyBypass: false))
#else
            attempts.append(.urlSession(proxyBypass: true))
            attempts.append(.urlSession(proxyBypass: false))
            if nativeFallbackEnabled {
                attempts.append(.native(proxyBypass: true))
                attempts.append(.native(proxyBypass: false))
            }
#endif
            return attempts
        }
    }

    private func reserveNextHandleId(for backend: SignalingBackend) -> SignalingHandleID {
        let generation = nextSequenceGeneration
        nextSequenceGeneration += 1
        return SignalingHandleID(sessionId: sessionId, backend: backend, generation: generation)
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
                Task { await weakSelf.value?.handleClosed(handleId: handleId, errorDescription: "websocket closed (\(closeCode.rawValue))") }
            }
        )
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        var request = URLRequest(url: url)
        for (name, value) in additionalHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = Self.maximumInboundTextBytes
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
            throw SignalingError.backendFailed(.urlSession, Self.transportErrorLogSummary(error))
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
                await weakSelf.value?.handleText(handleId: handleId, text: text)
            },
            onBinary: { [weakSelf = ActorBox(self)] data in
                await weakSelf.value?.handleBinary(handleId: handleId, data: data)
            },
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
            additionalHeaders: additionalHeaders,
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
                        await weakSelf.value?.handleBinary(handleId: handleId, data: data)
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
            if let error = terminalErrorsByHandle[handleId] {
                throw error
            }
            guard currentHandle == handleId else {
                throw CancellationError()
            }
            if isBound {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw SignalingError.connectTimedOut
    }

    private func handleBinary(handleId: SignalingHandleID, data: Data) async {
        guard data.count <= Self.maximumInboundTextBytes,
              let text = String(data: data, encoding: .utf8) else {
            await failProtocolViolation(handleId: handleId, reasonCode: "invalid_binary_message")
            return
        }
        await handleText(handleId: handleId, text: text)
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
        guard currentHandle == handleId else { return }
        isSocketOpen = true
        lifecyclePhase = .socketOpen
        emitLifecycle(
            phase: .socketOpen,
            handleId: handleId,
            errorDescription: nil,
            failureClass: nil,
            serverFrameType: nil
        )
        logger.info("✅ signaling websocket open: session=\(Self.sensitiveLogRedaction, privacy: .public) backend=\(handleId.backend.rawValue, privacy: .public)")
    }

    private func handleText(handleId: SignalingHandleID, text: String) async {
        guard currentHandle == handleId else {
            logger.debug("ignoring stale signaling callback generation=\(handleId.generation, privacy: .public)")
            return
        }
        guard text.utf8.count <= Self.maximumInboundTextBytes else {
            await failProtocolViolation(handleId: handleId, reasonCode: "message_too_large")
            return
        }

        switch Self.parseInboundText(text) {
        case .envelope(let env):
            guard isBound,
                  Self.sessionIDsMatch(env.sessionId, handleId.sessionId) else {
                await failProtocolViolation(handleId: handleId, reasonCode: "envelope_session_mismatch")
                return
            }
            await onEnvelope?(env)
        case .serverFrame(let frame):
            if frame.type == "bound" {
                guard let frameSessionId = frame.sessionId,
                      Self.sessionIDsMatch(frameSessionId, handleId.sessionId) else {
                    await failProtocolViolation(handleId: handleId, reasonCode: "bound_session_mismatch")
                    return
                }
                onServerFrame?(frame)
                isSocketOpen = true
                isBound = true
                hasEverBound = true
                lifecyclePhase = .bound
                emitLifecycle(
                    phase: .bound,
                    handleId: handleId,
                    errorDescription: nil,
                    failureClass: nil,
                    serverFrameType: frame.type
                )
                logger.info("✅ signaling server bound: session=\(Self.sensitiveLogRedaction, privacy: .public) backend=\(handleId.backend.rawValue, privacy: .public)")
                return
            }

            if frame.isError {
                if let frameSessionId = frame.sessionId,
                   !Self.sessionIDsMatch(frameSessionId, handleId.sessionId) {
                    await failProtocolViolation(handleId: handleId, reasonCode: "error_session_mismatch")
                    return
                }
                onServerFrame?(frame)
                let reason = frame.error ?? "unknown"
                let failureClass = Self.classifyServerError(reason)
                let redactedReason = Self.redactedServerErrorReasonDescription
                let error = SignalingError.serverRejected(redactedReason)
                terminalErrorsByHandle[handleId] = error
                if currentHandle == handleId {
                    isBound = false
                    lifecyclePhase = .failed
                }
                emitLifecycle(
                    phase: .failed,
                    handleId: handleId,
                    errorDescription: redactedReason,
                    failureClass: failureClass,
                    serverFrameType: frame.type
                )
                logger.error("❌ signaling server error: \(redactedReason, privacy: .public)")
            } else {
                if let frameSessionId = frame.sessionId,
                   !Self.sessionIDsMatch(frameSessionId, handleId.sessionId) {
                    await failProtocolViolation(handleId: handleId, reasonCode: "server_frame_session_mismatch")
                    return
                }
                onServerFrame?(frame)
                emitLifecycle(
                    phase: lifecyclePhase,
                    handleId: handleId,
                    errorDescription: nil,
                    failureClass: nil,
                    serverFrameType: frame.type
                )
                logger.debug("ℹ️ signaling server frame: type=\(frame.type, privacy: .public)")
            }
        case .unknown:
            await failProtocolViolation(handleId: handleId, reasonCode: "malformed_message")
        }
    }

    private func failProtocolViolation(
        handleId: SignalingHandleID,
        reasonCode: String
    ) async {
        guard currentHandle == handleId else { return }
        let error = SignalingError.protocolViolation
        terminalErrorsByHandle.removeAll(keepingCapacity: true)
        terminalErrorsByHandle[handleId] = error
        isSocketOpen = false
        isBound = false
        lifecyclePhase = .failed
        // Invalidate ownership before closing the transport. Native/URLSession
        // close callbacks for this handle are expected side effects and must
        // not overwrite the terminal protocol-violation classification.
        currentHandle = nil
        emitLifecycle(
            phase: .failed,
            handleId: handleId,
            errorDescription: Self.redactedServerErrorReasonDescription,
            failureClass: .protocolViolation,
            serverFrameType: nil
        )
        logger.error("signaling protocol violation code=\(reasonCode, privacy: .public)")
        await cleanupTransport(for: handleId.backend)
    }

    private func handleClosed(handleId: SignalingHandleID, errorDescription: String) async {
        guard currentHandle == handleId else { return }
        isSocketOpen = false
        isBound = false
        lifecyclePhase = .closed
        terminalErrorsByHandle.removeAll(keepingCapacity: true)
        terminalErrorsByHandle[handleId] = SignalingError.notConnected
        emitLifecycle(
            phase: .closed,
            handleId: handleId,
            errorDescription: errorDescription,
            failureClass: .transientNetwork,
            serverFrameType: nil
        )
        logger.info("⏹️ signaling websocket closed: session=\(Self.sensitiveLogRedaction, privacy: .public) backend=\(handleId.backend.rawValue, privacy: .public)")
    }

    private func handleErrored(handleId: SignalingHandleID, error: Error) async {
        guard currentHandle == handleId else { return }
        isSocketOpen = false
        isBound = false
        lifecyclePhase = .failed
        terminalErrorsByHandle.removeAll(keepingCapacity: true)
        terminalErrorsByHandle[handleId] = error
        let failureClass = Self.classifyTransportError(error)
        emitLifecycle(
            phase: .failed,
            handleId: handleId,
            errorDescription: Self.redactedTransportErrorDescription,
            failureClass: failureClass,
            serverFrameType: nil
        )
        logger.error(
            "❌ signaling websocket error: session=\(Self.sensitiveLogRedaction, privacy: .public) backend=\(handleId.backend.rawValue, privacy: .public) err=\(Self.transportErrorLogSummary(error), privacy: .public)"
        )
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

    private func cleanupTransport(for backend: SignalingBackend) async {
        switch backend {
        case .urlSession:
            await cleanupURLSessionTransport()
        case .native:
            await cleanupNativeTransport()
        }
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
        let client = nativeClient
        nativeClient = nil
        await client?.close()
    }

    private static func classifyServerError(_ reason: String) -> SignalingFailureClass {
        let normalized = reason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.contains("token") && normalized.contains("expired") {
            return .tokenExpired
        }
        if normalized.contains("auth") || normalized.contains("unauthorized") || normalized.contains("forbidden") || normalized.contains("bind_rejected") {
            return .authBindRejected
        }
        if normalized.contains("invalid shard") || normalized.contains("invalid session") || normalized.contains("session mismatch") || normalized.contains("unknown shard") || normalized.contains("room_full") {
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
        if message.contains("socket is not connected") || message.contains("network") || message.contains("timed out") {
            return .transientNetwork
        }
        return .transientServer
    }

    private static func transportErrorLogSummary(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain)#\(ns.code)"
    }

    private func shouldRetryBypassingProxy(_ error: Error) -> Bool {
        let message = (error as NSError).localizedDescription.lowercased()
        if message.contains("127.0.0.1") || message.contains("1082") || message.contains("socket is not connected") {
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

    private static func sessionIDsMatch(_ lhs: String, _ rhs: String) -> Bool {
        let normalizedLeft = lhs.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let normalizedRight = rhs.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return !normalizedLeft.isEmpty && normalizedLeft == normalizedRight
    }

    private static func noProxyConnectionProxyDictionary() -> [AnyHashable: Any] {
        var proxyDictionary: [AnyHashable: Any] = [
            kCFProxyTypeKey as String: kCFProxyTypeNone as String,
            kCFNetworkProxiesHTTPEnable as String: false,
            kCFNetworkProxiesProxyAutoConfigEnable as String: false
        ]

        // These CFNetwork proxy keys are macOS-only. iOS exposes the HTTP and
        // PAC controls above, so keep the no-proxy request within the public
        // API surface of the platform being compiled.
        #if os(macOS)
        proxyDictionary[kCFNetworkProxiesHTTPSEnable as String] = false
        proxyDictionary[kCFNetworkProxiesSOCKSEnable as String] = false
        proxyDictionary[kCFNetworkProxiesProxyAutoDiscoveryEnable as String] = false
        proxyDictionary[kCFNetworkProxiesExceptionsList as String] = []
        proxyDictionary[kCFNetworkProxiesExcludeSimpleHostnames as String] = false
        #endif

        return proxyDictionary
    }
}

private final class ActorBox<T: Actor>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

#if DEBUG || SKYBRIDGE_TESTING
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

    internal static func testOnlyDefaultConnectionTimeoutSeconds() -> Double {
        durationSeconds(.seconds(15))
    }

    internal func testOnlySeedCurrentHandle(_ handleId: SignalingHandleID) {
        currentHandle = handleId
        lifecyclePhase = .socketOpen
        isSocketOpen = true
        isBound = false
        terminalErrorsByHandle.removeAll(keepingCapacity: true)
    }

    internal func testOnlyHandleText(handleId: SignalingHandleID, text: String) async {
        await handleText(handleId: handleId, text: text)
    }

    internal func testOnlyIsBound() -> Bool {
        isBound
    }

    internal func testOnlyTerminalErrorCount() -> Int {
        terminalErrorsByHandle.count
    }
}
#endif

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

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocolName: String?
    ) {
        _ = protocolName
        onOpen()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        _ = webSocketTask
        onClose(closeCode, reason)
    }
}
