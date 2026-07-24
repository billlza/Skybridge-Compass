import Foundation
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

    @Test("inbound callback dispatch keeps DataChannel chunks ordered per session")
    func inboundCallbacksUseSessionSerialQueue() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let macSource = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/RemoteConnection/WebRTC/WebRTCSession.swift"),
            encoding: .utf8
        )
        let iosSource = try String(
            contentsOf: root.appendingPathComponent("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/RemoteConnection/WebRTC/WebRTCSession.swift"),
            encoding: .utf8
        )

        #expect(macSource.contains("private let callbackQueue = DispatchQueue"))
        #expect(macSource.contains("callbackQueue.async(execute: DispatchWorkItem(block: operation))"))
        #expect(macSource.contains("private func dispatchActiveLifecycleCallback"))
        #expect(macSource.contains("guard remainsActive else { return }"))
        #expect(macSource.contains("dataChannel?.delegate = nil"))
        #expect(macSource.contains("peerConnection?.delegate = nil"))
        #expect(!macSource.contains("DispatchQueue.global(qos: .userInitiated).async"))
        #expect(iosSource.contains("private let callbackQueue = DispatchQueue"))
        #expect(iosSource.contains("callbackQueue.async(execute: DispatchWorkItem(block: operation))"))
        #expect(iosSource.contains("private func dispatchActiveLifecycleCallback"))
        #expect(iosSource.contains("guard remainsActive else { return }"))
        #expect(iosSource.contains("dataChannel?.delegate = nil"))
        #expect(iosSource.contains("peerConnection?.delegate = nil"))
        #expect(!iosSource.contains("DispatchQueue.global(qos: .userInitiated).async"))
    }

    @Test("native screen submit can keep SCK raw timestamps separate from paced RTP timestamps")
    func nativeScreenSubmitSeparatesRawAndPacedTimestamps() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let macSource = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/RemoteConnection/WebRTC/WebRTCSession.swift"),
            encoding: .utf8
        )

        #expect(macSource.contains("rawTimeStampNs: Int64"))
        #expect(macSource.contains("preferredTimestampNs: Int64"))
        #expect(macSource.contains("rawTimestampNs: rawTimeStampNs"))
        #expect(macSource.contains("preferredTimestampNs: timeStampNs"))
        #expect(macSource.contains("lastOutgoingNativeVideoRawTimestampDeltaNs = previousRaw.map"))
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

    @Test("pending inbound buffer limit 在超过 count 或 bytes 时快速拒绝")
    func pendingInboundBufferLimitPlanRejectsUnboundedGrowth() {
        #expect(
            WebRTCSession.pendingInboundBufferLimitPlan(
                pendingCount: 2,
                pendingBytes: 8_000,
                incomingBytes: 2_000,
                maxCount: 8,
                maxBytes: 16_000
            ) == .append(nextPendingCount: 3, nextPendingBytes: 10_000)
        )
        #expect(
            WebRTCSession.pendingInboundBufferLimitPlan(
                pendingCount: 8,
                pendingBytes: 8_000,
                incomingBytes: 1_000,
                maxCount: 8,
                maxBytes: 16_000
            ) == .overflow
        )
        #expect(
            WebRTCSession.pendingInboundBufferLimitPlan(
                pendingCount: 2,
                pendingBytes: 15_500,
                incomingBytes: 600,
                maxCount: 8,
                maxBytes: 16_000
            ) == .overflow
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
        #expect(
            WebRTCSession.pendingRemoteICEPlan(
                isDuplicate: false,
                hasRemoteDescription: false,
                pendingCount: 256
            ) == .overflow
        )
    }
}
