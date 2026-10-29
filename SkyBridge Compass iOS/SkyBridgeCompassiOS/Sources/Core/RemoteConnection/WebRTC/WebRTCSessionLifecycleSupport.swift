import Foundation

#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif

@available(iOS 17.0, *)
extension WebRTCSession {
    enum BoundedCallbackOutcome<Value: Sendable>: Sendable {
        case completed(Value)
        case timedOut
        case cancelled
    }
}

@available(iOS 17.0, *)
private final class WebRTCBoundedCallbackGate<Value: Sendable>: @unchecked Sendable {
    typealias Outcome = WebRTCSession.BoundedCallbackOutcome<Value>

    private let lock = NSLock()
    private var resolution: Outcome?
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var timeoutTimer: DispatchSourceTimer?

    func install(
        _ continuation: CheckedContinuation<Outcome, Never>,
        timeoutSeconds: TimeInterval
    ) -> Bool {
        lock.lock()
        if let resolution {
            lock.unlock()
            continuation.resume(returning: resolution)
            return false
        }

        precondition(self.continuation == nil, "A bounded callback gate supports exactly one waiter")
        self.continuation = continuation
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.setEventHandler { [weak self] in
            self?.resolve(.timedOut)
        }
        timer.schedule(deadline: .now() + timeoutSeconds)
        timeoutTimer = timer
        timer.activate()
        lock.unlock()
        return true
    }

    func resolve(_ outcome: Outcome) {
        let continuationToResume: CheckedContinuation<Outcome, Never>?
        let timerToCancel: DispatchSourceTimer?
        lock.lock()
        guard resolution == nil else {
            lock.unlock()
            return
        }
        resolution = outcome
        continuationToResume = continuation
        continuation = nil
        timerToCancel = timeoutTimer
        timeoutTimer = nil
        lock.unlock()

        timerToCancel?.cancel()
        continuationToResume?.resume(returning: outcome)
    }
}

@available(iOS 17.0, *)
extension WebRTCSession {
    enum RemoteVideoTrackRefreshAction: Equatable {
        case noOp
        case rebind
    }

    enum StateAccessPlan: Equatable {
        case executeInline
        case syncOnStateQueue
    }

    enum CallbackDispatchPlan: Equatable {
        case executeInline
        case asyncOffStateQueue
    }

    enum PendingInboundFlushPlan: Equatable {
        case keepBuffered
        case dispatchBuffered(count: Int)
    }

    enum PendingInboundDeliveryPlan: Equatable {
        case bufferIncoming(nextPendingCount: Int)
        case dispatch(bufferedCount: Int)
    }

    enum PendingInboundBufferLimitPlan: Equatable {
        case append(nextPendingCount: Int, nextPendingBytes: Int)
        case overflow
    }

    enum PendingRemoteICEPlan: Equatable {
        case ignoreDuplicate
        case queueCandidate(nextPendingCount: Int)
        case applyImmediately
        case overflow
    }

    nonisolated static func receiverStatsProbeRemoteVideoTrackRefreshAction(
        currentTrackId: String?,
        receiverTrackId: String?,
        hasCurrentRemoteVideoTrack: Bool
    ) -> RemoteVideoTrackRefreshAction {
        guard hasCurrentRemoteVideoTrack else { return .rebind }

        let current = normalizedRemoteVideoTrackId(currentTrackId)
        let incoming = normalizedRemoteVideoTrackId(receiverTrackId)
        if current != incoming {
            return .rebind
        }
        return .noOp
    }

    nonisolated static func normalizedRemoteVideoTrackId(_ trackId: String?) -> String {
        trackId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    nonisolated static func stateAccessPlan(isOnStateQueue: Bool) -> StateAccessPlan {
        isOnStateQueue ? .executeInline : .syncOnStateQueue
    }

    nonisolated static func callbackDispatchPlan(isOnStateQueue: Bool) -> CallbackDispatchPlan {
        isOnStateQueue ? .asyncOffStateQueue : .executeInline
    }

    nonisolated static func lifecycleGuardAllowsCallback(
        peerConnectionMatches: Bool,
        isClosed: Bool,
        currentLifecycleToken: UInt64,
        expectedLifecycleToken: UInt64
    ) -> Bool {
        peerConnectionMatches && !isClosed && currentLifecycleToken == expectedLifecycleToken
    }

    /// Bridges a third-party callback without trusting that the callback will
    /// arrive. Timeout, task cancellation, and callback completion race through
    /// one lock-protected resolution, so the continuation is resumed exactly
    /// once and never remains suspended indefinitely.
    nonisolated static func awaitBoundedStatsCallback<Value: Sendable>(
        timeoutSeconds: TimeInterval,
        start: (@escaping @Sendable (Value) -> Void) -> Void
    ) async -> BoundedCallbackOutcome<Value> {
        precondition(
            timeoutSeconds.isFinite && timeoutSeconds >= 0,
            "Stats callback timeout must be finite and non-negative"
        )
        let gate = WebRTCBoundedCallbackGate<Value>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard gate.install(continuation, timeoutSeconds: timeoutSeconds) else {
                    return
                }
                start { value in
                    gate.resolve(.completed(value))
                }
            }
        } onCancel: {
            gate.resolve(.cancelled)
        }
    }

    nonisolated static func pendingInboundFlushPlan(
        hasHandlerInstalled: Bool,
        pendingCount: Int
    ) -> PendingInboundFlushPlan {
        guard hasHandlerInstalled, pendingCount > 0 else {
            return .keepBuffered
        }
        return .dispatchBuffered(count: pendingCount)
    }

    nonisolated static func pendingInboundDeliveryPlan(
        hasHandlerInstalled: Bool,
        pendingCount: Int
    ) -> PendingInboundDeliveryPlan {
        guard hasHandlerInstalled else {
            return .bufferIncoming(nextPendingCount: pendingCount + 1)
        }
        return .dispatch(bufferedCount: pendingCount)
    }

    nonisolated static func pendingInboundBufferLimitPlan(
        pendingCount: Int,
        pendingBytes: Int,
        incomingBytes: Int,
        maxCount: Int,
        maxBytes: Int
    ) -> PendingInboundBufferLimitPlan {
        let nextPendingCount = pendingCount + 1
        let nextPendingBytes = pendingBytes + incomingBytes
        guard nextPendingCount <= maxCount, nextPendingBytes <= maxBytes else {
            return .overflow
        }
        return .append(nextPendingCount: nextPendingCount, nextPendingBytes: nextPendingBytes)
    }

    nonisolated static func pendingRemoteICEPlan(
        isDuplicate: Bool,
        hasRemoteDescription: Bool,
        pendingCount: Int,
        maxPendingCount: Int = 256
    ) -> PendingRemoteICEPlan {
        if isDuplicate {
            return .ignoreDuplicate
        }
        if hasRemoteDescription {
            return .applyImmediately
        }
        guard pendingCount < maxPendingCount else {
            return .overflow
        }
        return .queueCandidate(nextPendingCount: pendingCount + 1)
    }
}
