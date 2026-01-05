import Foundation
import OSLog

/// Agent 连接状态
public enum AgentConnectionState: String, Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    case authenticating
    case authenticated
    case reconnecting
    case failed
}

/// Agent 连接错误
public enum AgentConnectionError: Error, LocalizedError, Sendable {
    case connectionFailed(String)
    case authenticationFailed(String)
    case connectionClosed
    case maxReconnectAttemptsExceeded
    case invalidMessage(String)
    case timeout
    case sendFailed(String)
    case rateLimitExceeded
    case messageTooLarge(Int)
    case queueOverflow
    case decodingFailed(String)
    case authTokenInvalid(String)
    
    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let reason):
            return "Agent 连接失败: \(reason)"
        case .authenticationFailed(let reason):
            return "认证失败: \(reason)"
        case .connectionClosed:
            return "连接已关闭"
        case .maxReconnectAttemptsExceeded:
            return "超过最大重连次数"
        case .invalidMessage(let reason):
            return "无效消息: \(reason)"
        case .timeout:
            return "连接超时"
        case .sendFailed(let reason):
            return "发送失败: \(reason)"
        case .rateLimitExceeded:
            return "消息速率超限，连接已断开"
        case .messageTooLarge(let size):
            return "消息过大: \(size) bytes"
        case .queueOverflow:
            return "消息队列溢出"
        case .decodingFailed(let reason):
            return "消息解码失败: \(reason)"
        case .authTokenInvalid(let reason):
            return "认证令牌无效: \(reason)"
        }
    }
}

/// Agent 连接服务 - 管理与本地 SkyBridge Agent 的 WebSocket 连接
///
/// 负责：
/// - 建立和维护 WebSocket 连接到 `ws://127.0.0.1:7002/agent`
/// - 处理认证流程
/// - 自动重连机制
/// - 消息收发
/// - DoS 防护（速率限制、消息大小限制、队列深度限制）
///
/// **Security Hardening (Requirements 4.1-4.8):**
/// - Per-connection TokenBucketLimiter (100 msg/s, burst 200)
/// - Message size check (64KB max)
/// - LimitedJSONDecoder for safe parsing
/// - Disconnect on excessive drops (500 in 10s window)
@MainActor
public final class AgentConnectionService: ObservableObject {
    
 // MARK: - DoS Protection Constants (Legacy - kept for backward compatibility)
    
 /// 单条消息最大字节数（64KB per SecurityLimits）
    public static let maxMessageBytes: Int = SecurityLimits.default.maxMessageBytes
    
 /// 待处理消息队列最大深度
    public static let maxQueueDepth: Int = 1000
    
 /// Token Bucket 容量（突发上限）
    public static let rateLimitBucketCapacity: Int = SecurityLimits.default.tokenBucketBurst
    
 /// Token Bucket 每秒补充速率
    public static let rateLimitTokensPerSecond: Double = SecurityLimits.default.tokenBucketRate
    
 /// 连续超限次数阈值（超过则断开）- now uses sliding window
    public static let rateLimitViolationThreshold: Int = SecurityLimits.default.droppedMessagesThreshold
    
 // MARK: - Published State
    
    @Published public private(set) var connectionState: AgentConnectionState = .disconnected
    @Published public private(set) var isAuthenticated: Bool = false
    @Published public private(set) var lastError: AgentConnectionError?
    
 // MARK: - Configuration
    
    private let agentURL: URL
    private let maxReconnectAttempts: Int
    private let reconnectDelay: TimeInterval
    private let authToken: String
    
 /// Security limits configuration
    private let securityLimits: SecurityLimits

 // MARK: - Private State
    
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "AgentConnectionService")
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var reconnectAttempts: Int = 0
    private var isManuallyDisconnected: Bool = false
    private var receiveTask: Task<Void, Never>?
    
 // MARK: - DoS Protection State (Security Hardening)
    
 /// Connection rate limiter (combines token bucket + sliding window disconnect threshold)
 /// Initialized on connection, uses SecurityLimits configuration
 /// **Validates: Requirements 4.1, 4.6, 4.7, 4.8**
    private var connectionRateLimiter: ConnectionRateLimiter?
    
 /// Limited JSON decoder for safe message parsing
 /// **Validates: Requirements 4.4, 4.5**
    private let limitedDecoder: LimitedJSONDecoder
    
 /// Auth token validator for message authentication
 /// **Validates: Requirements 9.1, 9.2, 9.4, 9.5, 9.6**
    private let authTokenValidator: AuthTokenValidator
    
 /// 待处理消息计数（用于队列深度检测）
    private var pendingMessageCount: Int = 0
    
 /// Connection identifier for this session
    private var connectionId: String = UUID().uuidString
    
 // MARK: - Callbacks
    
 /// 消息接收回调
    public var onMessage: (@Sendable (any SkyBridgeMessage) -> Void)?
    
 /// 连接状态变更回调
    public var onStateChange: (@Sendable (AgentConnectionState) -> Void)?
    
 /// 速率限制触发回调（用于监控/告警）
    public var onRateLimitTriggered: (@Sendable (Int) -> Void)?
    
 // MARK: - Initialization
    
 /// 初始化 Agent 连接服务
 /// - Parameters:
 /// - agentURL: Agent WebSocket URL，默认为 `ws://127.0.0.1:7002/agent`
 /// - authToken: 认证令牌
 /// - maxReconnectAttempts: 最大重连次数，默认 3 次
 /// - reconnectDelay: 重连延迟，默认 5 秒
 /// - securityLimits: Security limits configuration (default: SecurityLimits.default)
    public init(
        agentURL: URL = URL(string: "ws://127.0.0.1:7002/agent")!,
        authToken: String = "",
        maxReconnectAttempts: Int = 3,
        reconnectDelay: TimeInterval = 5.0,
        securityLimits: SecurityLimits = .default
    ) {
        self.agentURL = agentURL
        self.authToken = authToken
        self.maxReconnectAttempts = maxReconnectAttempts
        self.reconnectDelay = reconnectDelay
        self.securityLimits = securityLimits
        self.limitedDecoder = LimitedJSONDecoder(from: securityLimits)
        self.authTokenValidator = AuthTokenValidator()
    }
    
    deinit {
        receiveTask?.cancel()
    }
    
 // MARK: - Monitoring
    
 /// 获取丢弃的消息数量（用于监控）
    public var totalDroppedMessages: Int {
        get async {
            await connectionRateLimiter?.droppedMessageCount ?? 0
        }
    }
    
 /// 获取当前可用令牌数（用于监控）
    public var availableRateLimitTokens: Double {
        get async {
            await connectionRateLimiter?.availableTokens ?? 0
        }
    }
    
 // MARK: - Public Interface
    
 /// 连接到 Agent
    public func connect() async throws {
        guard connectionState == .disconnected || connectionState == .failed else {
            logger.warning("已经在连接中或已连接")
            return
        }
        
        isManuallyDisconnected = false
        reconnectAttempts = 0
        
 // Initialize per-connection rate limiter (Requirements 4.1, 4.8)
        connectionId = UUID().uuidString
        connectionRateLimiter = ConnectionRateLimiter(
            limits: securityLimits,
            connectionId: connectionId
        )
        
        try await performConnect()
    }
    
 /// 断开连接
    public func disconnect() {
        isManuallyDisconnected = true
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        
 // Clean up rate limiter
        connectionRateLimiter = nil
        
        updateState(.disconnected)
        isAuthenticated = false
        logger.info("已断开与 Agent 的连接")
    }
    
 /// 发送消息
    public func send(_ message: any SkyBridgeMessage) async throws {
        guard connectionState == .authenticated else {
            throw AgentConnectionError.sendFailed("未认证")
        }
        
        guard let webSocketTask = webSocketTask else {
            throw AgentConnectionError.sendFailed("WebSocket 未连接")
        }
        
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(message)
        
        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw AgentConnectionError.sendFailed("消息编码失败")
        }
        
        try await webSocketTask.send(.string(jsonString))
        logger.debug("发送消息: \(message.type)")
    }

    
 // MARK: - Private Methods
    
    private func performConnect() async throws {
        updateState(.connecting)
        logger.info("正在连接到 Agent: \(self.agentURL)")
        
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10
        urlSession = URLSession(configuration: configuration)
        
        guard let session = urlSession else {
            throw AgentConnectionError.connectionFailed("无法创建 URLSession")
        }
        
        webSocketTask = session.webSocketTask(with: agentURL)
        webSocketTask?.resume()
        
 // 等待连接建立
        do {
 // 发送 ping 验证连接
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                webSocketTask?.sendPing { error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
            updateState(.connected)
            logger.info("WebSocket 连接已建立")
            
 // 开始认证
            try await authenticate()
            
 // 开始接收消息
            startReceiving()
            
        } catch {
            logger.error("连接失败: \(error.localizedDescription)")
            throw AgentConnectionError.connectionFailed(error.localizedDescription)
        }
    }
    
    private func authenticate() async throws {
        updateState(.authenticating)
        logger.info("正在认证...")
        
        let authMessage = AuthMessage(token: authToken)
        let encoder = JSONEncoder()
        let data = try encoder.encode(authMessage)
        
        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw AgentConnectionError.authenticationFailed("认证消息编码失败")
        }
        
        try await webSocketTask?.send(.string(jsonString))
        
 // 等待认证响应
        guard let webSocketTask = webSocketTask else {
            throw AgentConnectionError.authenticationFailed("WebSocket 已断开")
        }
        
        let message = try await webSocketTask.receive()
        
        switch message {
        case .string(let text):
            try handleAuthResponse(text)
        case .data(let data):
            if let text = String(data: data, encoding: .utf8) {
                try handleAuthResponse(text)
            } else {
                throw AgentConnectionError.authenticationFailed("无法解析认证响应")
            }
        @unknown default:
            throw AgentConnectionError.authenticationFailed("未知消息类型")
        }
    }
    
    private func handleAuthResponse(_ text: String) throws {
        guard let data = text.data(using: .utf8) else {
            throw AgentConnectionError.authenticationFailed("无法解析响应数据")
        }
        
        let decoder = JSONDecoder()
        
 // 尝试解析为 auth-ok 消息
        if let authOK = try? decoder.decode(AuthOKMessage.self, from: data) {
            updateState(.authenticated)
            isAuthenticated = true
            reconnectAttempts = 0
            logger.info("认证成功: \(authOK.message)")
            return
        }
        
 // 尝试解析错误消息
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let type = json["type"] as? String {
            if type == "error" {
                let errorMsg = json["message"] as? String ?? "未知错误"
                throw AgentConnectionError.authenticationFailed(errorMsg)
            }
        }
        
        throw AgentConnectionError.authenticationFailed("未知响应格式")
    }

    
    private func startReceiving() {
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }
    
    private func receiveLoop() async {
        while !Task.isCancelled {
            guard let webSocketTask = webSocketTask else { break }
            
            do {
                let message = try await webSocketTask.receive()
                
 // DoS 防护：速率限制检查 (Requirements 4.1, 4.6, 4.7, 4.8)
                if let rateLimiter = connectionRateLimiter {
                    let decision = await rateLimiter.shouldProcess()
                    
                    switch decision {
                    case .allow:
 // Message allowed, continue processing
                        break
                        
                    case .drop:
 // Message dropped due to rate limiting
                        let droppedCount = await rateLimiter.droppedMessageCount
                        onRateLimitTriggered?(droppedCount)
                        logger.warning("⚠️ 速率限制：丢弃消息 (总丢弃: \(droppedCount))")
                        continue  // 丢弃此消息，继续接收下一条
                        
                    case .disconnect(let reason):
 // Too many dropped messages - disconnect and emit security event
                        logger.error("🚨 速率限制：\(reason)，断开连接")
                        lastError = .rateLimitExceeded
                        
 // Emit security event (Requirements 4.6, 4.7)
                        let droppedCount = await rateLimiter.droppedMessageCount
                        SecurityEventEmitter.emitDetached(
                            SecurityEvent.rateLimitDisconnect(
                                connectionId: connectionId,
                                droppedCount: droppedCount,
                                windowSeconds: securityLimits.droppedMessagesWindow
                            )
                        )
                        
                        disconnect()
                        return
                    }
                }
                
 // DoS 防护：队列深度检查
                if pendingMessageCount >= Self.maxQueueDepth {
                    await connectionRateLimiter?.recordDropped()
                    logger.warning("⚠️ 队列溢出：丢弃消息 (队列深度: \(self.pendingMessageCount))")
                    continue
                }
                
                pendingMessageCount += 1
                await handleReceivedMessage(message)
                pendingMessageCount -= 1
                
            } catch {
                if !Task.isCancelled && !isManuallyDisconnected {
                    logger.error("接收消息失败: \(error.localizedDescription)")
                    await handleDisconnection()
                }
                break
            }
        }
    }
    
    private func handleReceivedMessage(_ message: URLSessionWebSocketTask.Message) async {
        let data: Data
        let messageSize: Int
        
        switch message {
        case .string(let str):
            messageSize = str.utf8.count
            guard let strData = str.data(using: .utf8) else {
                logger.warning("无法转换消息字符串为数据")
                return
            }
            data = strData
        case .data(let msgData):
            messageSize = msgData.count
            data = msgData
        @unknown default:
            logger.warning("未知消息类型")
            return
        }
        
 // DoS 防护：消息大小检查 (Requirement 4.3)
 // Check BEFORE any parsing to prevent memory exhaustion
        if messageSize > securityLimits.maxMessageBytes {
            await connectionRateLimiter?.recordDropped()
            logger.warning("⚠️ 消息过大：\(messageSize) bytes > \(self.securityLimits.maxMessageBytes) bytes，关闭连接")
            lastError = .messageTooLarge(messageSize)
            disconnect()
            return
        }
        
        do {
            let agentMessage = try parseMessageWithLimits(data)
            
 // Auth token validation before processing (Requirements 9.4, 9.5, 9.6)
            let isTokenValid = await validateMessageAuthToken(agentMessage)
            if !isTokenValid {
 // Invalid token - close connection (Requirement 9.4)
                logger.error("🚨 认证令牌验证失败，关闭连接")
                disconnect()
                return
            }
            
            onMessage?(agentMessage)
        } catch let error as LimitedJSONDecoder.DecodingError {
 // Handle decoder limit violations (Requirements 4.4, 4.5)
            logger.warning("消息解码限制违规: \(error)")
            await connectionRateLimiter?.recordDropped()
        } catch {
            logger.warning("解析消息失败: \(error.localizedDescription)")
        }
    }
    
 /// Parse message with security limits enforcement (Requirements 4.4, 4.5)
 /// Uses LimitedJSONDecoder to enforce depth, array length, and string length limits
    private func parseMessageWithLimits(_ data: Data) throws -> any SkyBridgeMessage {
 // First, extract the message type using limited decoder for initial validation
 // This validates the structure before full decode
        struct TypeWrapper: Decodable {
            let type: String
        }
        
        let typeWrapper: TypeWrapper
        do {
            typeWrapper = try limitedDecoder.decode(TypeWrapper.self, from: data)
        } catch let error as LimitedJSONDecoder.DecodingError {
            throw AgentConnectionError.decodingFailed(describeDecodingError(error))
        }
        
 // Now decode the full message based on type
 // The limitedDecoder has already validated the structure
        return try decodeMessageByType(typeWrapper.type, from: data)
    }
    
 /// Decode message by type using LimitedJSONDecoder
    private func decodeMessageByType(_ type: String, from data: Data) throws -> any SkyBridgeMessage {
        do {
            switch type {
            case "auth-ok":
                return try limitedDecoder.decode(AuthOKMessage.self, from: data)
            case "devices":
                return try limitedDecoder.decode(SBDevicesMessage.self, from: data)
            case "session-joined":
                return try limitedDecoder.decode(SessionJoinedMessage.self, from: data)
            case "sdp-offer":
                return try limitedDecoder.decode(SDPOfferMessage.self, from: data)
            case "sdp-answer":
                return try limitedDecoder.decode(SDPAnswerMessage.self, from: data)
            case "ice-candidate":
                return try limitedDecoder.decode(SBICECandidateMessage.self, from: data)
            case "file-meta":
                return try limitedDecoder.decode(FileMetaMessage.self, from: data)
            case "file-ack-meta":
                return try limitedDecoder.decode(FileAckMetaMessage.self, from: data)
            case "file-end":
                return try limitedDecoder.decode(FileEndMessage.self, from: data)
            default:
                throw AgentConnectionError.invalidMessage("未知消息类型: \(type)")
            }
        } catch let error as LimitedJSONDecoder.DecodingError {
            throw AgentConnectionError.decodingFailed(describeDecodingError(error))
        }
    }
    
 /// Convert LimitedJSONDecoder.DecodingError to human-readable description
    private func describeDecodingError(_ error: LimitedJSONDecoder.DecodingError) -> String {
        switch error {
        case .messageTooLarge(let actual, let max):
            return "消息过大: \(actual) > \(max) bytes"
        case .depthExceeded(let actual, let max):
            return "嵌套深度超限: \(actual) > \(max)"
        case .arrayLengthExceeded(let actual, let max):
            return "数组长度超限: \(actual) > \(max)"
        case .stringLengthExceeded(let actual, let max):
            return "字符串长度超限: \(actual) > \(max)"
        case .jsonParsingFailed(let reason):
            return "JSON 解析失败: \(reason)"
        case .decodeFailed(let reason):
            return "解码失败: \(reason)"
        }
    }
    
 // MARK: - Auth Token Validation (Requirements 9.1-9.6)
    
 /// Validate auth token in a message before processing
 /// **Validates: Requirements 9.4, 9.5, 9.6**
 ///
 /// - Parameter message: The message to validate
 /// - Returns: true if valid, false if invalid (connection should be closed)
    private func validateMessageAuthToken(_ message: any SkyBridgeMessage) async -> Bool {
 // Extract authToken from messages that contain it
        let tokenToValidate: String?
        
        switch message {
        case let sdpOffer as SDPOfferMessage:
            tokenToValidate = sdpOffer.authToken
        case let sdpAnswer as SDPAnswerMessage:
            tokenToValidate = sdpAnswer.authToken
        case let iceCandidate as SBICECandidateMessage:
            tokenToValidate = iceCandidate.authToken
        default:
 // Messages without authToken don't need validation
            return true
        }
        
        guard let token = tokenToValidate else {
            return true
        }
        
 // Use validateWithDebugSupport for Release/Debug handling (Requirements 9.1, 9.2, 9.3)
        let result = authTokenValidator.validateWithDebugSupport(token)
        
        if !result.isValid {
            let reason = result.rejectionReason?.rawValue ?? "unknown"
            logger.warning("🚨 认证令牌无效: \(reason)")
            
 // Emit security event (Requirement 9.4)
            SecurityEventEmitter.emitDetached(
                SecurityEvent.authTokenInvalid(
                    reason: reason,
                    connectionId: connectionId
                )
            )
            
 // Log security warning and close connection (Requirement 9.4)
            lastError = .authTokenInvalid(reason)
            return false
        }
        
        return true
    }
    
 /// Legacy parseMessage method (kept for backward compatibility)
    private func parseMessage(_ text: String) throws -> any SkyBridgeMessage {
        guard let data = text.data(using: .utf8) else {
            throw AgentConnectionError.invalidMessage("无法转换为数据")
        }
        return try parseMessageWithLimits(data)
    }
    
    private func handleDisconnection() async {
        updateState(.disconnected)
        isAuthenticated = false
        
        guard !isManuallyDisconnected else { return }
        
 // 尝试重连
        if reconnectAttempts < maxReconnectAttempts {
            reconnectAttempts += 1
            updateState(.reconnecting)
            logger.info("尝试重连 (\(self.reconnectAttempts)/\(self.maxReconnectAttempts))...")
            
            try? await Task.sleep(nanoseconds: UInt64(reconnectDelay * 1_000_000_000))
            
            do {
                try await performConnect()
            } catch {
                logger.error("重连失败: \(error.localizedDescription)")
                await handleDisconnection()
            }
        } else {
            updateState(.failed)
            lastError = .maxReconnectAttemptsExceeded
            logger.error("超过最大重连次数，放弃重连")
        }
    }
    
    private func updateState(_ newState: AgentConnectionState) {
        connectionState = newState
        onStateChange?(newState)
    }
}


