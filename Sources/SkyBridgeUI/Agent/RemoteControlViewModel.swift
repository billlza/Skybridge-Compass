// RemoteControlViewModel.swift
// SkyBridgeUI
//
// 远程控制 ViewModel - 集成 Agent 连接和信令服务
// Created for web-agent-integration spec 13

import Foundation
import SwiftUI
import Combine
import OSLog
import SkyBridgeCore

/// 远程控制会话状态
@available(macOS 14.0, *)
public enum RemoteControlSessionState: String, Sendable {
    case idle = "idle"
    case connecting = "connecting"
    case waitingForPeer = "waiting_for_peer"
    case negotiating = "negotiating"
    case active = "active"
    case disconnected = "disconnected"
    case failed = "failed"
}

/// 远程控制 ViewModel
@available(macOS 14.0, *)
@MainActor
public final class RemoteControlViewModel: ObservableObject {
    
 // MARK: - Published State
    
 /// Agent 连接服务
    @Published public private(set) var agentConnection: AgentConnectionService
    
 /// 信令服务
    @Published public private(set) var signalingService: SignalingService
    
 /// 文件传输信令服务
    @Published public private(set) var fileTransferService: FileTransferSignalingService
    
 /// 当前会话状态
    @Published public private(set) var sessionState: RemoteControlSessionState = .idle
    
 /// 当前连接的远程设备 ID
    @Published public private(set) var remoteDeviceId: String?
    
 /// 错误消息
    @Published public private(set) var errorMessage: String?
    
 /// 是否正在加载
    @Published public private(set) var isLoading: Bool = false
    
 // MARK: - Private Properties
    
    private let logger = Logger(subsystem: "com.skybridge.ui", category: "RemoteControlViewModel")
    private var cancellables = Set<AnyCancellable>()
    
 // MARK: - Initialization
    
    public init(
        agentURL: URL = URL(string: "ws://127.0.0.1:7002/agent")!,
        authToken: String = "",
        localDeviceId: String = UUID().uuidString
    ) {
        let connection = AgentConnectionService(
            agentURL: agentURL,
            authToken: authToken
        )
        self.agentConnection = connection
        self.signalingService = SignalingService(
            agentConnection: connection,
            localDeviceId: localDeviceId,
            authToken: authToken
        )
        self.fileTransferService = FileTransferSignalingService()
        
        setupBindings()
    }
    
 // MARK: - Public Interface
    
 /// 连接到 Agent
    public func connectToAgent() async {
        guard sessionState == .idle || sessionState == .disconnected || sessionState == .failed else {
            logger.warning("无法连接：当前状态为 \(self.sessionState.rawValue)")
            return
        }
        
        isLoading = true
        errorMessage = nil
        sessionState = .connecting
        
        do {
            try await agentConnection.connect()
            sessionState = .waitingForPeer
            logger.info("✅ 已连接到 Agent")
        } catch {
            sessionState = .failed
            errorMessage = error.localizedDescription
            logger.error("❌ 连接 Agent 失败: \(error.localizedDescription)")
        }
        
        isLoading = false
    }
    
 /// 断开连接
    public func disconnect() {
        Task {
            await signalingService.leaveSession()
        }
        agentConnection.disconnect()
        sessionState = .disconnected
        remoteDeviceId = nil
        logger.info("已断开连接")
    }
    
 /// 加入远程控制会话
 /// - Parameters:
 /// - sessionId: 会话 ID
 /// - deviceId: 本地设备 ID
    public func joinSession(sessionId: String, deviceId: String) async {
        guard agentConnection.isAuthenticated else {
            errorMessage = "未连接到 Agent"
            return
        }
        
        isLoading = true
        sessionState = .negotiating
        
        do {
            try await signalingService.joinSession(sessionId, deviceId: deviceId)
            logger.info("✅ 已加入会话: \(sessionId)")
        } catch {
            sessionState = .failed
            errorMessage = error.localizedDescription
            logger.error("❌ 加入会话失败: \(error.localizedDescription)")
        }
        
        isLoading = false
    }
    
 /// 离开当前会话
    public func leaveSession() async {
        await signalingService.leaveSession()
        sessionState = .waitingForPeer
        remoteDeviceId = nil
        logger.info("已离开会话")
    }
    
 /// 发送 SDP Offer
    public func sendOffer(sdp: String, to deviceId: String) async throws {
        try await signalingService.sendOffer(sdp, to: deviceId)
        remoteDeviceId = deviceId
        logger.debug("已发送 SDP Offer 到 \(deviceId)")
    }
    
 /// 发送 SDP Answer
    public func sendAnswer(sdp: String, to deviceId: String) async throws {
        try await signalingService.sendAnswer(sdp, to: deviceId)
        remoteDeviceId = deviceId
        logger.debug("已发送 SDP Answer 到 \(deviceId)")
    }
    
 /// 发送 ICE Candidate
    public func sendICECandidate(_ candidate: SBICECandidate, to deviceId: String) async throws {
        try await signalingService.sendICECandidate(candidate, to: deviceId)
        logger.debug("已发送 ICE Candidate 到 \(deviceId)")
    }
    
 // MARK: - File Transfer
    
 /// 发送文件
    public func sendFile(fileName: String, fileSize: Int64, mimeType: String? = nil) -> FileMetaMessage {
        let (message, _) = fileTransferService.sendFileMeta(
            fileName: fileName,
            fileSize: fileSize,
            mimeType: mimeType
        )
        return message
    }
    
 // MARK: - Private Methods
    
    private func setupBindings() {
 // 监听 Agent 连接状态变化
        agentConnection.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.handleAgentStateChange(state)
            }
            .store(in: &cancellables)
        
 // 监听信令会话状态变化
        signalingService.$sessionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.handleSignalingStateChange(state)
            }
            .store(in: &cancellables)
        
 // 设置信令回调
        setupSignalingCallbacks()
    }
    
    private func handleAgentStateChange(_ state: AgentConnectionState) {
        switch state {
        case .disconnected:
            if sessionState != .idle {
                sessionState = .disconnected
            }
        case .failed:
            sessionState = .failed
            errorMessage = agentConnection.lastError?.localizedDescription
        case .authenticated:
            if sessionState == .connecting {
                sessionState = .waitingForPeer
            }
        default:
            break
        }
    }
    
    private func handleSignalingStateChange(_ state: SignalingSessionState) {
        switch state {
        case .idle:
            if agentConnection.isAuthenticated {
                sessionState = .waitingForPeer
            }
        case .joining:
            sessionState = .negotiating
        case .joined:
            sessionState = .active
        case .leaving:
            break
        case .failed:
            sessionState = .failed
        }
    }
    
    private func setupSignalingCallbacks() {
 // SDP Offer 回调
        signalingService.onSDPOffer = { [weak self] sdp, fromDeviceId in
            Task { @MainActor in
                self?.remoteDeviceId = fromDeviceId
                self?.sessionState = .negotiating
                self?.logger.info("收到 SDP Offer from \(fromDeviceId)")
            }
        }
        
 // SDP Answer 回调
        signalingService.onSDPAnswer = { [weak self] sdp, fromDeviceId in
            Task { @MainActor in
                self?.sessionState = .active
                self?.logger.info("收到 SDP Answer from \(fromDeviceId)")
            }
        }
        
 // ICE Candidate 回调
        signalingService.onICECandidate = { [weak self] candidate, fromDeviceId in
            Task { @MainActor in
                self?.logger.debug("收到 ICE Candidate from \(fromDeviceId)")
            }
        }
    }
}

// MARK: - Convenience Extensions

@available(macOS 14.0, *)
extension RemoteControlViewModel {
    
 /// Agent 是否已连接
    public var isAgentConnected: Bool {
        agentConnection.connectionState == .authenticated
    }
    
 /// 是否在活跃会话中
    public var isInActiveSession: Bool {
        sessionState == .active
    }
    
 /// 状态描述
    public var statusDescription: String {
        switch sessionState {
        case .idle:
            return "未连接"
        case .connecting:
            return "正在连接 Agent..."
        case .waitingForPeer:
            return "等待远程设备连接"
        case .negotiating:
            return "正在建立连接..."
        case .active:
            if let deviceId = remoteDeviceId {
                return "已连接到 \(deviceId)"
            }
            return "远程控制中"
        case .disconnected:
            return "已断开连接"
        case .failed:
            return errorMessage ?? "连接失败"
        }
    }
}
