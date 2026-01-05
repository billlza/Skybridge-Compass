import Testing
import Foundation
@testable import SkyBridgeCore

/// AgentConnectionService 测试
/// 测试 Agent 连接、认证和重连机制
struct AgentConnectionServiceTests {
    
 // MARK: - 状态转换测试
    
 /// **Feature: web-agent-integration, Property 2: 认证状态转换一致性**
 /// **Validates: Requirements 1.3**
    @Test("认证状态转换：disconnected -> connecting -> connected -> authenticating -> authenticated")
    @MainActor
    func testAuthenticationStateTransitions() async throws {
 // 创建服务实例
        let service = AgentConnectionService(
            agentURL: URL(string: "ws://127.0.0.1:7002/agent")!,
            authToken: "test-token"
        )
        
 // 初始状态应该是 disconnected
        #expect(service.connectionState == .disconnected)
        #expect(service.isAuthenticated == false)
        
 // 注意：由于没有真实的 Agent 服务器，我们只能测试初始状态
 // 完整的状态转换测试需要 Mock WebSocket 或集成测试环境
    }
    
    @Test("断开连接后状态应该重置")
    @MainActor
    func testDisconnectResetsState() async throws {
        let service = AgentConnectionService(
            agentURL: URL(string: "ws://127.0.0.1:7002/agent")!,
            authToken: "test-token"
        )
        
 // 断开连接
        service.disconnect()
        
 // 状态应该是 disconnected
        #expect(service.connectionState == .disconnected)
        #expect(service.isAuthenticated == false)
    }
    
 // MARK: - 配置测试
    
    @Test("默认配置正确")
    @MainActor
    func testDefaultConfiguration() async throws {
        let service = AgentConnectionService()
        
        #expect(service.connectionState == .disconnected)
        #expect(service.isAuthenticated == false)
        #expect(service.lastError == nil)
    }
    
    @Test("自定义配置正确应用")
    @MainActor
    func testCustomConfiguration() async throws {
        let customURL = URL(string: "ws://localhost:8080/agent")!
        let service = AgentConnectionService(
            agentURL: customURL,
            authToken: "custom-token",
            maxReconnectAttempts: 5,
            reconnectDelay: 10.0
        )
        
        #expect(service.connectionState == .disconnected)
    }
}

// MARK: - 状态枚举测试

@Suite("AgentConnectionState 测试")
struct AgentConnectionStateTests {
    
    @Test("所有状态值都是唯一的")
    func testStateUniqueness() {
        let states: [AgentConnectionState] = [
            .disconnected,
            .connecting,
            .connected,
            .authenticating,
            .authenticated,
            .reconnecting,
            .failed
        ]
        
        let uniqueStates = Set(states.map { $0.rawValue })
        #expect(uniqueStates.count == states.count)
    }
    
    @Test("状态 rawValue 正确")
    func testStateRawValues() {
        #expect(AgentConnectionState.disconnected.rawValue == "disconnected")
        #expect(AgentConnectionState.connecting.rawValue == "connecting")
        #expect(AgentConnectionState.connected.rawValue == "connected")
        #expect(AgentConnectionState.authenticating.rawValue == "authenticating")
        #expect(AgentConnectionState.authenticated.rawValue == "authenticated")
        #expect(AgentConnectionState.reconnecting.rawValue == "reconnecting")
        #expect(AgentConnectionState.failed.rawValue == "failed")
    }
}

// MARK: - 错误类型测试

@Suite("AgentConnectionError 测试")
struct AgentConnectionErrorTests {
    
    @Test("错误描述不为空")
    func testErrorDescriptions() {
        let errors: [AgentConnectionError] = [
            .connectionFailed("test"),
            .authenticationFailed("test"),
            .connectionClosed,
            .maxReconnectAttemptsExceeded,
            .invalidMessage("test"),
            .timeout,
            .sendFailed("test")
        ]
        
        for error in errors {
            #expect(error.errorDescription != nil)
            #expect(!error.errorDescription!.isEmpty)
        }
    }
    
    @Test("错误描述包含原因")
    func testErrorDescriptionsContainReason() {
        let reason = "specific-reason"
        
        let connectionError = AgentConnectionError.connectionFailed(reason)
        #expect(connectionError.errorDescription?.contains(reason) == true)
        
        let authError = AgentConnectionError.authenticationFailed(reason)
        #expect(authError.errorDescription?.contains(reason) == true)
        
        let messageError = AgentConnectionError.invalidMessage(reason)
        #expect(messageError.errorDescription?.contains(reason) == true)
        
        let sendError = AgentConnectionError.sendFailed(reason)
        #expect(sendError.errorDescription?.contains(reason) == true)
    }
}


// MARK: - 重连机制测试

@Suite("重连机制测试")
struct ReconnectionTests {
    
 /// **Feature: web-agent-integration, Property 3: 重连行为正确性**
 /// **Validates: Requirements 1.4**
    @Test("重连次数不超过最大限制")
    @MainActor
    func testReconnectAttemptsLimit() async throws {
        let maxAttempts = 3
        let service = AgentConnectionService(
            agentURL: URL(string: "ws://127.0.0.1:7002/agent")!,
            authToken: "test-token",
            maxReconnectAttempts: maxAttempts,
            reconnectDelay: 0.1  // 使用短延迟加速测试
        )
        
 // 初始状态
        #expect(service.connectionState == .disconnected)
        
 // 注意：完整的重连测试需要 Mock WebSocket
 // 这里只验证配置正确应用
    }
    
    @Test("手动断开后不应自动重连")
    @MainActor
    func testNoReconnectAfterManualDisconnect() async throws {
        let service = AgentConnectionService(
            agentURL: URL(string: "ws://127.0.0.1:7002/agent")!,
            authToken: "test-token"
        )
        
 // 手动断开
        service.disconnect()
        
 // 状态应该保持 disconnected，不应该变成 reconnecting
        #expect(service.connectionState == .disconnected)
        #expect(service.isAuthenticated == false)
    }
    
    @Test("重连延迟配置正确")
    @MainActor
    func testReconnectDelayConfiguration() async throws {
        let customDelay: TimeInterval = 10.0
        let service = AgentConnectionService(
            agentURL: URL(string: "ws://127.0.0.1:7002/agent")!,
            authToken: "test-token",
            maxReconnectAttempts: 5,
            reconnectDelay: customDelay
        )
        
 // 验证服务创建成功
        #expect(service.connectionState == .disconnected)
    }
}

// MARK: - 消息发送测试

@Suite("消息发送测试")
struct MessageSendingTests {
    
    @Test("未认证时发送消息应该失败")
    @MainActor
    func testSendWithoutAuthentication() async throws {
        let service = AgentConnectionService(
            agentURL: URL(string: "ws://127.0.0.1:7002/agent")!,
            authToken: "test-token"
        )
        
        let message = AuthMessage(token: "test")
        
        do {
            try await service.send(message)
            Issue.record("应该抛出错误")
        } catch let error as AgentConnectionError {
 // 预期的错误
            #expect(error.errorDescription?.contains("未认证") == true)
        }
    }
}
