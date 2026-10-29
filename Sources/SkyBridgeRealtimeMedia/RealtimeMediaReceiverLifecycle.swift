import Foundation

/// Monotonic lifecycle shared by a realtime-media receiver and callbacks that
/// can outlive its transport callback queue.
///
/// `retire()` is synchronous so an owning manager can revoke queued datagrams
/// before scheduling actor-isolated cleanup. Once retired, the lifecycle can
/// never become active again.
public final class SkyBridgeRealtimeMediaReceiverLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true

    public init() {}

    public var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    /// Returns `true` only for the caller that performs the active-to-retired
    /// transition.
    @discardableResult
    public func retire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return false }
        active = false
        return true
    }
}

/// Exact, process-local ownership for a shared realtime-media playback sink.
/// A live owner cannot be displaced. A replacement may claim only after the
/// previous lifecycle has been synchronously retired.
public final class SkyBridgeRealtimeMediaPlaybackOwnership: @unchecked Sendable {
    public enum ClaimDisposition: Sendable, Equatable {
        case acquiredVacant
        case alreadyOwned
        case replacedRetiredOwner
        case rejectedInactiveCandidate
        case rejectedLiveOwner

        public var isAccepted: Bool {
            switch self {
            case .acquiredVacant, .alreadyOwned, .replacedRetiredOwner:
                return true
            case .rejectedInactiveCandidate, .rejectedLiveOwner:
                return false
            }
        }

        /// A new sink owner must never inherit queued PCM or decoder state
        /// from a previous/legacy owner, even when the media profile matches.
        public var requiresPipelineReset: Bool {
            switch self {
            case .acquiredVacant, .replacedRetiredOwner:
                return true
            case .alreadyOwned, .rejectedInactiveCandidate, .rejectedLiveOwner:
                return false
            }
        }
    }

    private let lock = NSLock()
    private var owner: SkyBridgeRealtimeMediaReceiverLifecycle?

    public init() {}

    public func claim(
        _ candidate: SkyBridgeRealtimeMediaReceiverLifecycle
    ) -> ClaimDisposition {
        lock.lock()
        defer { lock.unlock() }
        guard candidate.isActive else { return .rejectedInactiveCandidate }
        if let owner {
            if owner === candidate { return .alreadyOwned }
            guard !owner.isActive else { return .rejectedLiveOwner }
            self.owner = candidate
            return .replacedRetiredOwner
        }
        owner = candidate
        return .acquiredVacant
    }

    public func isOwned(by candidate: SkyBridgeRealtimeMediaReceiverLifecycle) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return owner === candidate && candidate.isActive
    }

    @discardableResult
    public func release(ifOwnedBy candidate: SkyBridgeRealtimeMediaReceiverLifecycle) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard owner === candidate else { return false }
        owner = nil
        return true
    }

    /// Revokes the current owner before clearing the slot. This is used by
    /// legacy/global teardown paths so a delayed callback cannot reclaim the
    /// now-vacant sink and resurrect playback.
    @discardableResult
    public func retireCurrentOwnerAndClear() -> Bool {
        lock.lock()
        let owner = self.owner
        _ = owner?.retire()
        self.owner = nil
        lock.unlock()
        return owner != nil
    }
}
