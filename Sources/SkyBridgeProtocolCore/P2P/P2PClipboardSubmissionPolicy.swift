import Foundation

/// A clipboard value bound to one pasteboard generation.
///
/// Reading the generation both before and after the value prevents callers
/// from attaching bytes from one pasteboard value to the generation of another.
public enum P2PClipboardSnapshotRead<Value> {
    case stable(value: Value?, changeCount: Int)
    case changed
}

public enum P2PClipboardSnapshotPolicy {
    public static func read<Value>(
        changeCount: () -> Int,
        value: () -> Value?
    ) -> P2PClipboardSnapshotRead<Value> {
        let countBeforeRead = changeCount()
        let snapshot = value()
        let countAfterRead = changeCount()
        guard countBeforeRead == countAfterRead else {
            return .changed
        }
        return .stable(value: snapshot, changeCount: countAfterRead)
    }
}

/// Tracks whether an already-started route may still expose an older clipboard
/// value and paces retries for the latest visible pasteboard generation.
///
/// The coordinator is deliberately transport-agnostic. UIKit/AppKit ownership,
/// content decoding, and observed-generation commits remain in platform code.
@MainActor
public final class P2PClipboardDeliveryConvergence {
    public enum ConfigurationError: Error, Sendable, Equatable {
        case invalidInitialRetryDelay(TimeInterval)
        case invalidMaximumRetryDelay(TimeInterval)
    }

    public private(set) var deliveryMayHaveOccurred = false

    private var retryGeneration: Int?
    private var retryNotBefore: ContinuousClock.Instant?
    private var retryAttemptCount = 0
    private var activeRouteIDs: Set<UUID> = []

    private let initialRetryDelay: TimeInterval
    private let maximumRetryDelay: TimeInterval

    public init() {
        initialRetryDelay = 1
        maximumRetryDelay = 8
    }

    public init(
        initialRetryDelay: TimeInterval,
        maximumRetryDelay: TimeInterval
    ) throws {
        guard initialRetryDelay.isFinite, initialRetryDelay > 0 else {
            throw ConfigurationError.invalidInitialRetryDelay(initialRetryDelay)
        }
        guard maximumRetryDelay.isFinite,
              maximumRetryDelay >= initialRetryDelay else {
            throw ConfigurationError.invalidMaximumRetryDelay(maximumRetryDelay)
        }
        self.initialRetryDelay = initialRetryDelay
        self.maximumRetryDelay = maximumRetryDelay
    }

    /// Marks possible delivery before invoking a route that may suspend.
    public func attemptRoute(
        _ operation: @MainActor () async throws -> Void
    ) async throws {
        let routeID = UUID()
        activeRouteIDs.insert(routeID)
        deliveryMayHaveOccurred = true
        defer { activeRouteIDs.remove(routeID) }
        try await operation()
    }

    /// Completes convergence only after every older route has quiesced.
    ///
    /// A suspended, cancellation-uncooperative route can otherwise publish an
    /// older value after the compensating submission reports success.
    @discardableResult
    public func fullySubmitted(
        generation: Int,
        now: ContinuousClock.Instant
    ) -> Bool {
        guard activeRouteIDs.isEmpty else {
            recordFailure(generation: generation, now: now)
            return false
        }
        deliveryMayHaveOccurred = false
        clearRetry()
        return true
    }

    /// Applies inbound authority without replaying it in the normal case.
    ///
    /// If an older local route is still executing, the inbound value remains
    /// uncommitted as an observed generation and is retried after backoff so it
    /// can compensate for a possible late stale delivery.
    @discardableResult
    public func authoritativeInboundApplied(
        generation: Int,
        now: ContinuousClock.Instant
    ) -> Bool {
        clearRetry()
        guard !activeRouteIDs.isEmpty else {
            deliveryMayHaveOccurred = false
            return false
        }
        deliveryMayHaveOccurred = true
        recordFailure(generation: generation, now: now)
        return true
    }

    /// Returns false until the failed generation's retry deadline. A different
    /// generation clears the obsolete deadline and can preempt immediately.
    public func mayAttempt(
        generation: Int,
        now: ContinuousClock.Instant
    ) -> Bool {
        guard let retryGeneration else { return true }
        guard retryGeneration == generation else {
            clearRetry()
            return true
        }
        guard let retryNotBefore else { return true }
        return now >= retryNotBefore
    }

    /// Records a retry using a capped 1, 2, 4, ... exponential schedule.
    public func recordFailure(
        generation: Int,
        now: ContinuousClock.Instant
    ) {
        if retryGeneration == generation {
            retryAttemptCount = min(retryAttemptCount + 1, 16)
        } else {
            retryGeneration = generation
            retryAttemptCount = 1
        }
        let exponent = min(retryAttemptCount - 1, 8)
        let delay = min(
            maximumRetryDelay,
            initialRetryDelay * Double(1 << exponent)
        )
        retryNotBefore = now.advanced(by: .seconds(delay))
    }

    public func generationWasHandled(_ generation: Int) {
        guard retryGeneration == generation else { return }
        clearRetry()
    }

    public func requiresSubmission(
        contentHash: String,
        committedHash: String?,
        remoteOriginHash: String? = nil
    ) -> Bool {
        guard contentHash != remoteOriginHash || deliveryMayHaveOccurred else {
            return false
        }
        return deliveryMayHaveOccurred || contentHash != committedHash
    }

    private func clearRetry() {
        retryGeneration = nil
        retryNotBefore = nil
        retryAttemptCount = 0
    }
}
