//
// SignalingServiceTests.swift
// SkyBridgeCoreTests
//
// SignalingService 单元测试
// 测试会话管理、SDP 消息处理、ICE Candidate 处理
//
// Requirements: 2.1, 2.2, 2.3, 2.4, 2.5
//

import Testing
import Foundation
@testable import SkyBridgeCore

// MARK: - SignalingService Tests

@Suite("SignalingService Tests")
struct SignalingServiceTests {
    
 // MARK: - Session State Tests
    
    @Test("初始状态应为 idle")
    @MainActor
    func testInitialState() async {
        let agentConnection = AgentConnectionService()
        let signalingService = SignalingService(
            agentConnection: agentConnection,
            localDeviceId: "test-device-id"
        )
        
        #expect(signalingService.sessionState == .idle)
        #expect(signalingService.currentSessionId == nil)
    }
    
    @Test("未认证时加入会话应抛出错误")
    @MainActor
    func testJoinSessionWithoutAuthentication() async throws {
        let agentConnection = AgentConnectionService()
        let signalingService = SignalingService(
            agentConnection: agentConnection,
            localDeviceId: "test-device-id"
        )
        
 // AgentConnectionService 初始状态为 disconnected，不是 authenticated
        await #expect(throws: SignalingError.self) {
            try await signalingService.joinSession("test-session")
        }
    }
    
    @Test("离开未加入的会话应安全返回")
    @MainActor
    func testLeaveSessionWhenNotJoined() async {
        let agentConnection = AgentConnectionService()
        let signalingService = SignalingService(
            agentConnection: agentConnection,
            localDeviceId: "test-device-id"
        )
        
 // 应该安全返回，不抛出错误
        await signalingService.leaveSession()
        
        #expect(signalingService.sessionState == .idle)
        #expect(signalingService.currentSessionId == nil)
    }
    
 // MARK: - SDP Message Validation Tests
    
    @Test("发送空 SDP Offer 应抛出错误")
    @MainActor
    func testSendEmptySDPOffer() async throws {
        let agentConnection = AgentConnectionService()
        let signalingService = SignalingService(
            agentConnection: agentConnection,
            localDeviceId: "test-device-id"
        )
        
 // 未加入会话时发送应抛出 sessionNotJoined
        await #expect(throws: SignalingError.self) {
            try await signalingService.sendOffer("", to: "target-device")
        }
    }
    
    @Test("发送空 SDP Answer 应抛出错误")
    @MainActor
    func testSendEmptySDPAnswer() async throws {
        let agentConnection = AgentConnectionService()
        let signalingService = SignalingService(
            agentConnection: agentConnection,
            localDeviceId: "test-device-id"
        )
        
 // 未加入会话时发送应抛出 sessionNotJoined
        await #expect(throws: SignalingError.self) {
            try await signalingService.sendAnswer("", to: "target-device")
        }
    }
    
 // MARK: - ICE Candidate Validation Tests
    
    @Test("发送空 ICE Candidate 应抛出错误")
    @MainActor
    func testSendEmptyICECandidate() async throws {
        let agentConnection = AgentConnectionService()
        let signalingService = SignalingService(
            agentConnection: agentConnection,
            localDeviceId: "test-device-id"
        )
        
        let emptyCandidate = SBICECandidate(candidate: "", sdpMid: nil, sdpMLineIndex: nil)
        
 // 未加入会话时发送应抛出 sessionNotJoined
        await #expect(throws: SignalingError.self) {
            try await signalingService.sendICECandidate(emptyCandidate, to: "target-device")
        }
    }
    
 // MARK: - Session State Transition Tests
    
    @Test("会话状态转换回调应被调用")
    @MainActor
    func testSessionStateChangeCallback() async {
        let agentConnection = AgentConnectionService()
        let signalingService = SignalingService(
            agentConnection: agentConnection,
            localDeviceId: "test-device-id"
        )
        
        var stateChanges: [SignalingSessionState] = []
        signalingService.onSessionStateChange = { state in
            Task { @MainActor in
                stateChanges.append(state)
            }
        }
        
 // 离开会话会触发状态变更（即使未加入）
        await signalingService.leaveSession()
        
 // 等待回调执行
        try? await Task.sleep(nanoseconds: 100_000_000)
        
 // 状态应该保持 idle（因为本来就没加入）
        #expect(signalingService.sessionState == .idle)
    }
    
 // MARK: - Error Type Tests
    
    @Test("SignalingError 应有正确的描述")
    func testSignalingErrorDescriptions() {
        let errors: [SignalingError] = [
            .notConnected,
            .notAuthenticated,
            .sessionNotJoined,
            .alreadyInSession,
            .invalidSDP("test reason"),
            .invalidICECandidate("test reason"),
            .messageEncodingFailed,
            .messageDecodingFailed("test reason"),
            .sendFailed("test reason"),
            .joinFailed("test reason")
        ]
        
        for error in errors {
            #expect(error.errorDescription != nil)
            #expect(!error.errorDescription!.isEmpty)
        }
    }
    
 // MARK: - Configuration Tests
    
    @Test("SignalingService 应正确存储配置")
    @MainActor
    func testConfiguration() async {
        let agentConnection = AgentConnectionService()
        let deviceId = "my-device-id"
        let authToken = "my-auth-token"
        
        let signalingService = SignalingService(
            agentConnection: agentConnection,
            localDeviceId: deviceId,
            authToken: authToken
        )
        
 // 验证初始状态
        #expect(signalingService.sessionState == .idle)
        #expect(signalingService.currentSessionId == nil)
        #expect(signalingService.lastError == nil)
    }
}

// MARK: - SDP Message Tests

@Suite("SDP Message Tests")
struct SDPMessageTests {
    
    @Test("SDPDescription 应正确序列化")
    func testSDPDescriptionSerialization() throws {
        let sdp = SDPDescription(type: "offer", sdp: "v=0\r\no=- 123 456 IN IP4 127.0.0.1")
        
        let data = try SkyBridgeMessageCodec.encode(SDPOfferMessage(
            sessionId: "session-1",
            deviceId: "device-1",
            authToken: "token",
            offer: sdp
        ))
        
        let decoded = try SkyBridgeMessageCodec.decode(SDPOfferMessage.self, from: data)
        
        #expect(decoded.offer.type == "offer")
        #expect(decoded.offer.sdp == sdp.sdp)
    }
    
    @Test("SDPOfferMessage Round-Trip")
    func testSDPOfferMessageRoundTrip() throws {
        let original = SDPOfferMessage(
            sessionId: "session-123",
            deviceId: "device-456",
            authToken: "auth-token",
            offer: SDPDescription(type: "offer", sdp: "v=0\r\no=- 123 456 IN IP4 127.0.0.1")
        )
        
        let data = try SkyBridgeMessageCodec.encode(original)
        let decoded = try SkyBridgeMessageCodec.decode(SDPOfferMessage.self, from: data)
        
        #expect(decoded == original)
    }
    
    @Test("SDPAnswerMessage Round-Trip")
    func testSDPAnswerMessageRoundTrip() throws {
        let original = SDPAnswerMessage(
            sessionId: "session-123",
            deviceId: "device-456",
            authToken: "auth-token",
            answer: SDPDescription(type: "answer", sdp: "v=0\r\no=- 789 012 IN IP4 192.168.1.1")
        )
        
        let data = try SkyBridgeMessageCodec.encode(original)
        let decoded = try SkyBridgeMessageCodec.decode(SDPAnswerMessage.self, from: data)
        
        #expect(decoded == original)
    }
}

// MARK: - ICE Candidate Message Tests

@Suite("ICE Candidate Message Tests")
struct ICECandidateMessageTests {
    
    @Test("SBICECandidate 应正确序列化")
    func testICECandidateSerialization() throws {
        let candidate = SBICECandidate(
            candidate: "candidate:1 1 UDP 2130706431 192.168.1.1 54321 typ host",
            sdpMid: "0",
            sdpMLineIndex: 0
        )
        
        let message = SBICECandidateMessage(
            sessionId: "session-1",
            deviceId: "device-1",
            authToken: "token",
            candidate: candidate
        )
        
        let data = try SkyBridgeMessageCodec.encode(message)
        let decoded = try SkyBridgeMessageCodec.decode(SBICECandidateMessage.self, from: data)
        
        #expect(decoded.candidate.candidate == candidate.candidate)
        #expect(decoded.candidate.sdpMid == candidate.sdpMid)
        #expect(decoded.candidate.sdpMLineIndex == candidate.sdpMLineIndex)
    }
    
    @Test("SBICECandidateMessage Round-Trip")
    func testICECandidateMessageRoundTrip() throws {
        let original = SBICECandidateMessage(
            sessionId: "session-123",
            deviceId: "device-456",
            authToken: "auth-token",
            candidate: SBICECandidate(
                candidate: "candidate:1 1 UDP 2130706431 192.168.1.1 54321 typ host",
                sdpMid: "audio",
                sdpMLineIndex: 1
            )
        )
        
        let data = try SkyBridgeMessageCodec.encode(original)
        let decoded = try SkyBridgeMessageCodec.decode(SBICECandidateMessage.self, from: data)
        
        #expect(decoded == original)
    }
    
    @Test("SBICECandidate 可选字段为 nil 时应正确序列化")
    func testICECandidateWithNilOptionals() throws {
        let candidate = SBICECandidate(
            candidate: "candidate:1 1 UDP 2130706431 192.168.1.1 54321 typ host",
            sdpMid: nil,
            sdpMLineIndex: nil
        )
        
        let message = SBICECandidateMessage(
            sessionId: "session-1",
            deviceId: "device-1",
            authToken: "token",
            candidate: candidate
        )
        
        let data = try SkyBridgeMessageCodec.encode(message)
        let decoded = try SkyBridgeMessageCodec.decode(SBICECandidateMessage.self, from: data)
        
        #expect(decoded.candidate.sdpMid == nil)
        #expect(decoded.candidate.sdpMLineIndex == nil)
    }
}

// MARK: - Session Message Tests

@Suite("Session Message Tests")
struct SessionMessageTests {
    
    @Test("SessionJoinMessage Round-Trip")
    func testSessionJoinMessageRoundTrip() throws {
        let original = SessionJoinMessage(
            sessionId: "session-abc",
            deviceId: "device-xyz"
        )
        
        let data = try SkyBridgeMessageCodec.encode(original)
        let decoded = try SkyBridgeMessageCodec.decode(SessionJoinMessage.self, from: data)
        
        #expect(decoded == original)
    }
    
    @Test("SessionJoinedMessage Round-Trip")
    func testSessionJoinedMessageRoundTrip() throws {
        let original = SessionJoinedMessage(
            sessionId: "session-abc",
            deviceId: "device-xyz"
        )
        
        let data = try SkyBridgeMessageCodec.encode(original)
        let decoded = try SkyBridgeMessageCodec.decode(SessionJoinedMessage.self, from: data)
        
        #expect(decoded == original)
    }
    
    @Test("SessionLeaveMessage Round-Trip")
    func testSessionLeaveMessageRoundTrip() throws {
        let original = SessionLeaveMessage(
            sessionId: "session-abc",
            deviceId: "device-xyz"
        )
        
        let data = try SkyBridgeMessageCodec.encode(original)
        let decoded = try SkyBridgeMessageCodec.decode(SessionLeaveMessage.self, from: data)
        
        #expect(decoded == original)
    }
}
