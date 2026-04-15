import Testing
@testable import SkyBridgeCore

@Suite("WebRTCSession Concurrency Behavior Tests")
struct WebRTCSessionConcurrencyBehaviorTests {
    @Test("stateQueue 在队列内直接执行，队列外同步切换")
    func stateAccessPlanReflectsQueueAffinity() {
        #expect(WebRTCSession.stateAccessPlan(isOnStateQueue: true) == .executeInline)
        #expect(WebRTCSession.stateAccessPlan(isOnStateQueue: false) == .syncOnStateQueue)
    }

    @Test("dispatchCallback 在 stateQueue 内异步跳出，队列外直接执行")
    func callbackDispatchPlanReflectsQueueAffinity() {
        #expect(WebRTCSession.callbackDispatchPlan(isOnStateQueue: true) == .asyncOffStateQueue)
        #expect(WebRTCSession.callbackDispatchPlan(isOnStateQueue: false) == .executeInline)
    }

    @Test("lifecycle guard 仅在连接匹配且 token 未失效时放行回调")
    func lifecycleGuardRejectsClosedOrStaleCallbacks() {
        #expect(
            WebRTCSession.lifecycleGuardAllowsCallback(
                peerConnectionMatches: true,
                isClosed: false,
                currentLifecycleToken: 7,
                expectedLifecycleToken: 7
            )
        )
        #expect(
            !WebRTCSession.lifecycleGuardAllowsCallback(
                peerConnectionMatches: false,
                isClosed: false,
                currentLifecycleToken: 7,
                expectedLifecycleToken: 7
            )
        )
        #expect(
            !WebRTCSession.lifecycleGuardAllowsCallback(
                peerConnectionMatches: true,
                isClosed: true,
                currentLifecycleToken: 7,
                expectedLifecycleToken: 7
            )
        )
        #expect(
            !WebRTCSession.lifecycleGuardAllowsCallback(
                peerConnectionMatches: true,
                isClosed: false,
                currentLifecycleToken: 8,
                expectedLifecycleToken: 7
            )
        )
    }

    @Test("pending inbound buffer 在 handler 缺失时保留，在 handler 安装后统一排空")
    func pendingInboundBufferPlansMatchHandlerAvailability() {
        #expect(
            WebRTCSession.pendingInboundFlushPlan(
                hasHandlerInstalled: false,
                pendingCount: 2
            ) == .keepBuffered
        )
        #expect(
            WebRTCSession.pendingInboundFlushPlan(
                hasHandlerInstalled: true,
                pendingCount: 2
            ) == .dispatchBuffered(count: 2)
        )
        #expect(
            WebRTCSession.pendingInboundDeliveryPlan(
                hasHandlerInstalled: false,
                pendingCount: 2
            ) == .bufferIncoming(nextPendingCount: 3)
        )
        #expect(
            WebRTCSession.pendingInboundDeliveryPlan(
                hasHandlerInstalled: true,
                pendingCount: 2
            ) == .dispatch(bufferedCount: 2)
        )
    }

    @Test("remote ICE 在重复项、待 remote description、已就绪三种路径间切换")
    func pendingRemoteICEPlanMatchesSessionReadiness() {
        #expect(
            WebRTCSession.pendingRemoteICEPlan(
                isDuplicate: true,
                hasRemoteDescription: false,
                pendingCount: 1
            ) == .ignoreDuplicate
        )
        #expect(
            WebRTCSession.pendingRemoteICEPlan(
                isDuplicate: false,
                hasRemoteDescription: false,
                pendingCount: 1
            ) == .queueCandidate(nextPendingCount: 2)
        )
        #expect(
            WebRTCSession.pendingRemoteICEPlan(
                isDuplicate: false,
                hasRemoteDescription: true,
                pendingCount: 1
            ) == .applyImmediately
        )
    }
}
