//
// SignalingService.swift
// SkyBridgeCore
//
// 信令服务 - 处理 WebRTC 信令消息
// 负责会话管理、SDP 交换、ICE Candidate 处理
//
// Requirements: 2.1, 2.2, 2.3, 2.4, 2.5
//

import Foundation
import OSLog

// MARK: - Signaling Session State

/// 信令会话状态
public enum SignalingSessionState: String, Sendable, Equatable {
    case idle
    case joining
    case joined
    case leaving
    case failed
}

// MARK: - Signaling Error

/// 信令错误
public enum SignalingError: Error, LocalizedError, Sendable {
    case notConnected
    case notAuthenticated
    case sessionNotJoined
    case alreadyInSession
    case invalidSDP(String)
    case invalidICECandidate(String)
    case messageEncodingFailed
    case messageDecodingFailed(String)
    case sendFailed(String)
    case joinFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "未连接到 Agent"
        case .notAuthenticated:
            return "未认证"
        case .sessionNotJoined:
            return "未加入会话"
        case .alreadyInSession:
            return "已在会话中"
        case .invalidSDP(let reason):
            return "无效的 SDP: \(reason)"
        case .invalidICECandidate(let reason):
            return "无效的 ICE 候选: \(reason)"
        case .messageEncodingFailed:
            return "消息编码失败"
        case .messageDecodingFailed(let reason):
            return "消息解码失败: \(reason)"
        case .sendFailed(let reason):
            return "发送失败: \(reason)"
        case .joinFailed(let reason):
            return "加入会话失败: \(reason)"
        }
    }
}

// MARK: - SignalingService

/// 信令服务 - 处理 WebRTC 信令消息
///
/// 负责：
/// - 会话管理（加入/离开）
/// - SDP Offer/Answer 交换
/// - ICE Candidate 交换
@MainActor
public final class SignalingService: ObservableObject {
    
 // MARK: - Dependencies
    
    private let agentConnection: AgentConnectionService
    
 // MARK: - Published State
    
    @Published public private(set) var currentSessionId: String?
    @Published public private(set) var sessionState: SignalingSessionState = .idle
    @Published public private(set) var lastError: SignalingError?
    
 // MARK: - Configuration
    
    private let localDeviceId: String
    private let authToken: String
    
 // MARK: - Private State
    
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "SignalingService")
    
 // MARK: - Callbacks
    
 /// 收到 SDP Offer 回调 (sdp, fromDeviceId)
    public var onSDPOffer: (@Sendable (String, String) -> Void)?
    
 /// 收到 SDP Answer 回调 (sdp, fromDeviceId)
    public var onSDPAnswer: (@Sendable (String, String) -> Void)?
    
 /// 收到 ICE Candidate 回调 (candidate, fromDeviceId)
    public var onICECandidate: (@Sendable (SBICECandidate, String) -> Void)?
    
 /// 会话状态变更回调
    public var onSessionStateChange: (@Sendable (SignalingSessionState) -> Void)?
    
 // MARK: - Initialization
    
 /// 初始化信令服务
 /// - Parameters:
 /// - agentConnection: Agent 连接服务
 /// - localDeviceId: 本地设备 ID
 /// - authToken: 认证令牌
    public init(
        agentConnection: AgentConnectionService,
        localDeviceId: String,
        authToken: String = ""
    ) {
        self.agentConnection = agentConnection
        self.localDeviceId = localDeviceId
        self.authToken = authToken
        
        setupMessageHandler()
    }
    
 // MARK: - Public Interface - Session Management
    
 /// 加入信令会话
 /// - Parameters:
 /// - sessionId: 会话 ID
 /// - deviceId: 目标设备 ID（可选，用于点对点会话）
    public func joinSession(_ sessionId: String, deviceId: String? = nil) async throws {
        guard agentConnection.connectionState == .authenticated else {
            throw SignalingError.notAuthenticated
        }
        
        guard sessionState == .idle || sessionState == .failed else {
            throw SignalingError.alreadyInSession
        }
        
        updateSessionState(.joining)
        logger.info("正在加入会话: \(sessionId)")
        
        let message = SessionJoinMessage(
            sessionId: sessionId,
            deviceId: deviceId ?? localDeviceId
        )
        
        do {
            try await agentConnection.send(message)
 // 等待 session-joined 响应会在 handleMessage 中处理
        } catch {
            updateSessionState(.failed)
            lastError = .joinFailed(error.localizedDescription)
            throw SignalingError.joinFailed(error.localizedDescription)
        }
    }
    
 /// 离开当前会话
    public func leaveSession() async {
        guard let sessionId = currentSessionId else {
            logger.warning("未在任何会话中")
            return
        }
        
        updateSessionState(.leaving)
        logger.info("正在离开会话: \(sessionId)")
        
        let message = SessionLeaveMessage(
            sessionId: sessionId,
            deviceId: localDeviceId
        )
        
        do {
            try await agentConnection.send(message)
        } catch {
            logger.error("发送离开会话消息失败: \(error.localizedDescription)")
        }
        
 // 无论发送是否成功，都清理本地状态
        currentSessionId = nil
        updateSessionState(.idle)
    }
    
 // MARK: - Public Interface - SDP Messages
    
 /// 发送 SDP Offer
 /// - Parameters:
 /// - sdp: SDP 内容
 /// - toDeviceId: 目标设备 ID
    public func sendOffer(_ sdp: String, to toDeviceId: String) async throws {
        guard let sessionId = currentSessionId else {
            throw SignalingError.sessionNotJoined
        }
        
        guard !sdp.isEmpty else {
            throw SignalingError.invalidSDP("SDP 内容为空")
        }
        
        let offer = SDPDescription(type: "offer", sdp: sdp)
        let message = SDPOfferMessage(
            sessionId: sessionId,
            deviceId: toDeviceId,
            authToken: authToken,
            offer: offer
        )
        
        do {
            try await agentConnection.send(message)
            logger.debug("已发送 SDP Offer 到设备: \(toDeviceId)")
        } catch {
            throw SignalingError.sendFailed(error.localizedDescription)
        }
    }
    
 /// 发送 SDP Answer
 /// - Parameters:
 /// - sdp: SDP 内容
 /// - toDeviceId: 目标设备 ID
    public func sendAnswer(_ sdp: String, to toDeviceId: String) async throws {
        guard let sessionId = currentSessionId else {
            throw SignalingError.sessionNotJoined
        }
        
        guard !sdp.isEmpty else {
            throw SignalingError.invalidSDP("SDP 内容为空")
        }
        
        let answer = SDPDescription(type: "answer", sdp: sdp)
        let message = SDPAnswerMessage(
            sessionId: sessionId,
            deviceId: toDeviceId,
            authToken: authToken,
            answer: answer
        )
        
        do {
            try await agentConnection.send(message)
            logger.debug("已发送 SDP Answer 到设备: \(toDeviceId)")
        } catch {
            throw SignalingError.sendFailed(error.localizedDescription)
        }
    }
    
 // MARK: - Public Interface - ICE Candidate
    
 /// 发送 ICE Candidate
 /// - Parameters:
 /// - candidate: ICE 候选
 /// - toDeviceId: 目标设备 ID
    public func sendICECandidate(_ candidate: SBICECandidate, to toDeviceId: String) async throws {
        guard let sessionId = currentSessionId else {
            throw SignalingError.sessionNotJoined
        }
        
        guard !candidate.candidate.isEmpty else {
            throw SignalingError.invalidICECandidate("候选内容为空")
        }
        
        let message = SBICECandidateMessage(
            sessionId: sessionId,
            deviceId: toDeviceId,
            authToken: authToken,
            candidate: candidate
        )
        
        do {
            try await agentConnection.send(message)
            logger.debug("已发送 ICE Candidate 到设备: \(toDeviceId)")
        } catch {
            throw SignalingError.sendFailed(error.localizedDescription)
        }
    }
    
 // MARK: - Private Methods
    
    private func setupMessageHandler() {
        agentConnection.onMessage = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.handleMessage(message)
            }
        }
    }
    
    private func handleMessage(_ message: any SkyBridgeMessage) {
        switch message {
        case let msg as SessionJoinedMessage:
            handleSessionJoined(msg)
        case let msg as SDPOfferMessage:
            handleSDPOffer(msg)
        case let msg as SDPAnswerMessage:
            handleSDPAnswer(msg)
        case let msg as SBICECandidateMessage:
            handleICECandidate(msg)
        default:
 // 其他消息类型不在此处理
            break
        }
    }
    
    private func handleSessionJoined(_ message: SessionJoinedMessage) {
        currentSessionId = message.sessionId
        updateSessionState(.joined)
        logger.info("已加入会话: \(message.sessionId)")
    }
    
    private func handleSDPOffer(_ message: SDPOfferMessage) {
        logger.debug("收到 SDP Offer 来自设备: \(message.deviceId)")
        onSDPOffer?(message.offer.sdp, message.deviceId)
    }
    
    private func handleSDPAnswer(_ message: SDPAnswerMessage) {
        logger.debug("收到 SDP Answer 来自设备: \(message.deviceId)")
        onSDPAnswer?(message.answer.sdp, message.deviceId)
    }
    
    private func handleICECandidate(_ message: SBICECandidateMessage) {
        logger.debug("收到 ICE Candidate 来自设备: \(message.deviceId)")
        onICECandidate?(message.candidate, message.deviceId)
    }
    
    private func updateSessionState(_ newState: SignalingSessionState) {
        sessionState = newState
        onSessionStateChange?(newState)
    }
}
