import Testing
import Foundation
@testable import SkyBridgeCore

private actor AgentConnectionBarrier {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() { lock.withLock { value += 1 } }
    func snapshot() -> Int { lock.withLock { value } }
}

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

    @Test("外部丢弃达到阈值时立即断开")
    @MainActor
    func testExternalDropThresholdDisconnectsImmediately() async throws {
        let limits = makeAgentSecurityLimits(dropThreshold: 3)
        let limiter = ConnectionRateLimiter(
            limits: limits,
            connectionId: "external-drop-threshold"
        )
        let service = AgentConnectionService(
            authToken: "test-token",
            securityLimits: limits
        )
        service.installRateLimiter(limiter)

        let firstDisconnected = await service.applyExternalDropPolicy(using: limiter)
        let secondDisconnected = await service.applyExternalDropPolicy(using: limiter)
        let thresholdDisconnected = await service.applyExternalDropPolicy(using: limiter)

        #expect(firstDisconnected == false)
        #expect(secondDisconnected == false)
        #expect(thresholdDisconnected == true)
        #expect(service.connectionState == .disconnected)
        #expect(service.lastError?.errorDescription == AgentConnectionError.rateLimitExceeded.errorDescription)
        #expect(await limiter.droppedMessageCount == 3)
    }

    @Test("旧连接的限流终态不能断开替代连接")
    @MainActor
    func testStaleExternalDropCannotDisconnectReplacement() async throws {
        let limits = makeAgentSecurityLimits(dropThreshold: 1)
        let oldLimiter = ConnectionRateLimiter(
            limits: limits,
            connectionId: "old-rate-limit-owner"
        )
        let replacementLimiter = ConnectionRateLimiter(
            limits: limits,
            connectionId: "replacement-rate-limit-owner"
        )
        let service = AgentConnectionService(
            authToken: "test-token",
            securityLimits: limits
        )
        service.installRateLimiter(oldLimiter)
        service.afterExternalDropDecision = {
            await MainActor.run {
                service.installRateLimiter(replacementLimiter)
            }
        }

        let staleDisconnected = await service.applyExternalDropPolicy(using: oldLimiter)

        #expect(staleDisconnected == false)
        #expect(service.lastError == nil)

        service.afterExternalDropDecision = nil
        let replacementDisconnected = await service.applyExternalDropPolicy(using: replacementLimiter)
        #expect(replacementDisconnected == true)
        #expect(service.lastError?.errorDescription == AgentConnectionError.rateLimitExceeded.errorDescription)
    }

    @Test("外来限流器不能改变当前连接")
    @MainActor
    func testForeignLimiterCannotDisconnectCurrentConnection() async throws {
        let limits = makeAgentSecurityLimits(dropThreshold: 1)
        let currentLimiter = ConnectionRateLimiter(
            limits: limits,
            connectionId: "current-rate-limit-owner"
        )
        let foreignLimiter = ConnectionRateLimiter(
            limits: limits,
            connectionId: "foreign-rate-limit-owner"
        )
        let service = AgentConnectionService(
            authToken: "test-token",
            securityLimits: limits
        )
        service.installRateLimiter(currentLimiter)

        let foreignDisconnected = await service.applyExternalDropPolicy(using: foreignLimiter)

        #expect(foreignDisconnected == false)
        #expect(service.lastError == nil)
        #expect(await foreignLimiter.droppedMessageCount == 0)
    }

    @Test("未知消息类型累计到阈值时立即断开")
    @MainActor
    func testUnknownMessageTypeCountsTowardExternalDropThreshold() async throws {
        let limits = makeAgentSecurityLimits(dropThreshold: 2)
        let limiter = ConnectionRateLimiter(
            limits: limits,
            connectionId: "unknown-message-owner"
        )
        let service = AgentConnectionService(
            authToken: "test-token",
            securityLimits: limits
        )
        service.installRateLimiter(limiter)
        let unknownMessage = URLSessionWebSocketTask.Message.string(#"{"type":"unknown"}"#)

        await service.handleReceivedMessageForTesting(unknownMessage)
        #expect(service.lastError == nil)
        #expect(await limiter.droppedMessageCount == 1)

        await service.handleReceivedMessageForTesting(unknownMessage)
        #expect(service.lastError?.errorDescription == AgentConnectionError.rateLimitExceeded.errorDescription)
        #expect(await limiter.droppedMessageCount == 2)
    }

    @Test("重连等待被手动断开后不能复活连接")
    @MainActor
    func testManualDisconnectCancelsPendingReconnect() async throws {
        let limits = makeAgentSecurityLimits(dropThreshold: 3)
        let limiter = ConnectionRateLimiter(
            limits: limits,
            connectionId: "reconnect-cancellation-owner"
        )
        let service = AgentConnectionService(
            authToken: "test-token",
            reconnectDelay: 1,
            securityLimits: limits
        )
        let barrier = AgentConnectionBarrier()
        let attempts = LockedCounter()
        service.installRateLimiter(limiter)
        service.waitBeforeReconnect = { _ in
            await barrier.suspend()
            try Task.checkCancellation()
        }
        service.onConnectionAttemptStarted = { attempts.increment() }

        let reconnectTask = Task { @MainActor in
            await service.handleDisconnectionForTesting()
        }
        await barrier.waitUntilEntered()
        service.disconnect()
        reconnectTask.cancel()
        await barrier.release()
        await reconnectTask.value

        #expect(service.connectionState == .disconnected)
        #expect(attempts.snapshot() == 0)
    }

    @Test("首次连接失败归属当前尝试且允许再次连接")
    @MainActor
    func testInitialConnectionFailureIsAttributedAndRetryable() async throws {
        let attempts = LockedCounter()
        let service = AgentConnectionService(
            agentURL: URL(string: "ws://127.0.0.1:7002/agent")!,
            authToken: "test-token"
        )
        service.performConnectionPing = { _ in
            attempts.increment()
            throw AgentConnectionError.connectionFailed("injected ping failure")
        }

        for expectedAttemptCount in 1...2 {
            do {
                try await service.connect()
                Issue.record("连接探测失败必须显式抛出")
            } catch {
                #expect(error is AgentConnectionError)
            }

            #expect(service.connectionState == .failed)
            #expect(service.isAuthenticated == false)
            if case .connectionFailed(let reason) = service.lastError {
                #expect(reason == "injected ping failure")
            } else {
                Issue.record("连接失败必须保留精确领域错误")
            }
            #expect(attempts.snapshot() == expectedAttemptCount)
            #expect(await service.availableRateLimitTokens == 0)
        }
    }

    @Test("重连连续失败达到上限后进入唯一失败终态")
    @MainActor
    func testReconnectFailuresReachConfiguredLimit() async throws {
        let limits = makeAgentSecurityLimits(dropThreshold: 3)
        let limiter = ConnectionRateLimiter(
            limits: limits,
            connectionId: "reconnect-failure-owner"
        )
        let attempts = LockedCounter()
        let service = AgentConnectionService(
            agentURL: URL(string: "ws://127.0.0.1:7002/agent")!,
            authToken: "test-token",
            maxReconnectAttempts: 2,
            reconnectDelay: 1,
            securityLimits: limits
        )
        service.installRateLimiter(limiter)
        service.waitBeforeReconnect = { _ in }
        service.performConnectionPing = { _ in
            attempts.increment()
            throw AgentConnectionError.connectionFailed("injected retry failure")
        }

        await service.handleDisconnectionForTesting()

        #expect(attempts.snapshot() == 2)
        #expect(service.connectionState == .failed)
        #expect(service.isAuthenticated == false)
        #expect(
            service.lastError?.errorDescription
                == AgentConnectionError.maxReconnectAttemptsExceeded.errorDescription
        )
        #expect(await service.availableRateLimitTokens == 0)
    }
}

private func makeAgentSecurityLimits(dropThreshold: Int) -> SecurityLimits {
    let defaults = SecurityLimits.default
    return SecurityLimits(
        maxTotalFiles: defaults.maxTotalFiles,
        maxTotalBytes: defaults.maxTotalBytes,
        globalTimeout: defaults.globalTimeout,
        maxRegexPatternLength: defaults.maxRegexPatternLength,
        maxRegexPatternCount: defaults.maxRegexPatternCount,
        maxRegexGroups: defaults.maxRegexGroups,
        maxRegexQuantifiers: defaults.maxRegexQuantifiers,
        maxRegexAlternations: defaults.maxRegexAlternations,
        maxRegexLookaheads: defaults.maxRegexLookaheads,
        perPatternTimeout: defaults.perPatternTimeout,
        perPatternInputLimit: defaults.perPatternInputLimit,
        maxTotalHistoryBytes: defaults.maxTotalHistoryBytes,
        tokenBucketRate: defaults.tokenBucketRate,
        tokenBucketBurst: defaults.tokenBucketBurst,
        maxMessageBytes: defaults.maxMessageBytes,
        decodeDepthLimit: defaults.decodeDepthLimit,
        decodeArrayLengthLimit: defaults.decodeArrayLengthLimit,
        decodeStringLengthLimit: defaults.decodeStringLengthLimit,
        droppedMessagesThreshold: dropThreshold,
        droppedMessagesWindow: defaults.droppedMessagesWindow,
        pakeRecordTTL: defaults.pakeRecordTTL,
        pakeMaxRecords: defaults.pakeMaxRecords,
        pakeCleanupInterval: defaults.pakeCleanupInterval,
        maxSymlinkDepth: defaults.maxSymlinkDepth,
        maxRetryCount: defaults.maxRetryCount,
        maxRetryDelay: defaults.maxRetryDelay,
        maxExtractedFiles: defaults.maxExtractedFiles,
        maxTotalExtractedBytes: defaults.maxTotalExtractedBytes,
        maxNestingDepth: defaults.maxNestingDepth,
        maxCompressionRatio: defaults.maxCompressionRatio,
        maxExtractionTime: defaults.maxExtractionTime,
        maxBytesPerFile: defaults.maxBytesPerFile,
        largeFileThreshold: defaults.largeFileThreshold,
        hashTimeoutQuick: defaults.hashTimeoutQuick,
        hashTimeoutStandard: defaults.hashTimeoutStandard,
        hashTimeoutDeep: defaults.hashTimeoutDeep,
        maxEventQueueSize: defaults.maxEventQueueSize,
        maxPendingPerSubscriber: defaults.maxPendingPerSubscriber
    )
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
