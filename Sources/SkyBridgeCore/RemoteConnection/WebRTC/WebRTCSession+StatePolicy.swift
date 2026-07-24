import Foundation

extension WebRTCSession {
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

    nonisolated static func stateAccessPlan(isOnStateQueue: Bool) -> StateAccessPlan {
        isOnStateQueue ? .executeInline : .syncOnStateQueue
    }

    nonisolated static func callbackDispatchPlan(isOnStateQueue: Bool) -> CallbackDispatchPlan {
        isOnStateQueue ? .asyncOffStateQueue : .executeInline
    }

    nonisolated static func nativeOutgoingAudioTrackPreference(environment: [String: String]) -> Bool {
        if let raw = environment["SKYBRIDGE_ENABLE_WEBRTC_NATIVE_AUDIO_TRACK"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return raw == "1"
        }
        return false
    }

    nonisolated static func lifecycleGuardAllowsCallback(
        peerConnectionMatches: Bool,
        isClosed: Bool,
        currentLifecycleToken: UInt64,
        expectedLifecycleToken: UInt64
    ) -> Bool {
        peerConnectionMatches && !isClosed && currentLifecycleToken == expectedLifecycleToken
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
