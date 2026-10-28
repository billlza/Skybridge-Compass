import Foundation
import os

/// Only the authenticated request boundary may classify a temporary failure.
/// Protected-storage, identity and response-validation errors are never wrapped.
public struct AudioMembershipRequestUnavailable: Error, Sendable {
    public let underlying: any Error
    public init(_ underlying: any Error) { self.underlying = underlying }
}

public enum AudioMembershipRequestFailurePolicy {
    public static func isTemporaryNetworkError(_ error: any Error) -> Bool {
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
             .dnsLookupFailed, .notConnectedToInternet, .internationalRoamingOff,
             .callIsActive, .dataNotAllowed:
            return true
        default: return false // Includes TLS, certificates, cancellation and malformed URLs.
        }
    }

    public static func isTemporaryHTTPStatus(_ status: Int, errorCode: String?) -> Bool {
        if let errorCode, ["device_not_registered", "device_not_active", "device_frozen",
            "device_revoked", "current_identity_mismatch"].contains(errorCode) { return false }
        return [429, 500, 502, 503, 504].contains(status)
    }
}

public enum AudioMembershipRenewalState: Equatable, Sendable { case waiting, checking, retryPending, unavailable, failed }

public struct AudioMembershipRenewalUpdate: Sendable {
    public let state: AudioMembershipRenewalState
    public let evidence: AudioAccountMembership
    public let failure: (any Error)?
}

public enum AudioMembershipRenewalError: Error, Equatable, Sendable {
    case deadlineExceeded, predecessorChanged, missingFreshEvidence, incompleteAttempt
}

/// Owned by one playback task. Renewal cannot select a new account, connection,
/// identity, source or output permission. Only the store can publish fresh evidence.
public struct AudioMembershipRenewal: Sendable {
    private let lease: AudioMembershipLease
    private let renew: @Sendable () async throws -> Void
    private let observe: @Sendable (AudioMembershipRenewalUpdate) async -> Void
    private let wall: @Sendable () -> Int64
    private let monotonic: @Sendable () -> ContinuousClock.Instant
    private let sleep: @Sendable (Duration) async throws -> Void

    public init(lease: AudioMembershipLease,
                renew: @escaping @Sendable () async throws -> Void,
                observe: @escaping @Sendable (AudioMembershipRenewalUpdate) async -> Void,
                wall: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) },
                monotonic: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.lease = lease; self.renew = renew; self.observe = observe
        self.wall = wall; self.monotonic = monotonic; self.sleep = sleep
    }

    public func run(allowNetwork: Bool = true) async {
        guard allowNetwork else { return }
        do {
            while true {
                let previous = try checkpoint()
                await publish(.waiting)
                var attempts = 0
                var renewed = false
                var lastTemporaryFailure: (any Error)?
                for lead in [Duration.seconds(120), .seconds(75), .seconds(40)] {
                    try requirePredecessor(previous)
                    let beforeWait = try remaining(previous)
                    // Late admission gets one immediate attempt, never a burst for missed slots.
                    if attempts > 0 && beforeWait < lead { continue }
                    try await sleep(max(.zero, beforeWait - lead))
                    try Task.checkCancellation()
                    try requirePredecessor(previous)
                    await publish(.checking)
                    try requirePredecessor(previous)
                    let requestRemaining = try remaining(previous)
                    let budget = min(.seconds(35), requestRemaining - .milliseconds(1))
                    if budget <= .zero { break }
                    attempts += 1
                    do { try await attempt(budget: budget) }
                    catch {
                        try Task.checkCancellation()
                        if error is CancellationError { throw error }
                        guard error is AudioMembershipRequestUnavailable ||
                            (error as? AudioAccountProviderError) == .requestInProgress else { throw error }
                        // Negative observations and expiry still win over a transport failure.
                        try requirePredecessor(previous)
                        lastTemporaryFailure = error
                        await publish(.retryPending, failure: error)
                        continue
                    }
                    let fresh = try checkpoint()
                    guard fresh.id != previous.id, fresh.account == previous.account,
                          fresh.localIdentity == previous.localIdentity, fresh.peerIdentity == previous.peerIdentity,
                          fresh.issuedAtMilliseconds > previous.issuedAtMilliseconds,
                          fresh.expiresAtMilliseconds > previous.expiresAtMilliseconds,
                          fresh.issuedAtMonotonic > previous.issuedAtMonotonic,
                          fresh.expiresAtMonotonic > previous.expiresAtMonotonic else {
                        throw AudioMembershipRenewalError.missingFreshEvidence
                    }
                    renewed = true
                    break
                }
                if !renewed {
                    await publish(.unavailable, failure: lastTemporaryFailure)
                    return // Existing effect gates enforce the unchanged finite expiry.
                }
            }
        } catch {
            if Task.isCancelled || error is CancellationError { return }
            lease.revoke()
            await publish(.failed, failure: error)
        }
    }

    private func checkpoint() throws -> AudioAccountMembership {
        try Task.checkCancellation()
        if let failure = lease.failure { throw failure }
        return lease.evidence
    }

    private func requirePredecessor(_ expected: AudioAccountMembership) throws {
        guard try checkpoint() == expected else { throw AudioMembershipRenewalError.predecessorChanged }
    }

    private func remaining(_ evidence: AudioAccountMembership) throws -> Duration {
        let now = wall(), instant = monotonic()
        try evidence.validate(account: evidence.account, local: evidence.localIdentity, peer: evidence.peerIdentity,
            nowMilliseconds: now, monotonicNow: instant)
        return min(.milliseconds(evidence.expiresAtMilliseconds - now),
            instant.duration(to: evidence.expiresAtMonotonic))
    }

    private func publish(_ state: AudioMembershipRenewalState, failure: (any Error)? = nil) async {
        await observe(.init(state: state, evidence: lease.evidence, failure: failure))
    }

    private func attempt(budget: Duration) async throws {
        let completion = AttemptCompletion()
        let outcome = await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    do { try Task.checkCancellation(); try await renew(); completion.finish(.success(())) }
                    catch { completion.finish(.failure(error)) }
                }
                group.addTask {
                    do {
                        try await sleep(budget)
                        try Task.checkCancellation()
                        // Stop effects before joining a provider that ignores cancellation.
                        completion.finish(.failure(AudioMembershipRenewalError.deadlineExceeded), revoking: lease)
                    } catch {
                        if Task.isCancelled { return } // The winning task or owner cancelled this timer.
                        completion.finish(.failure(error), revoking: lease)
                    }
                }
                _ = await group.next()
                group.cancelAll()
                // Structured scope exit joins both owners. The timer cannot revoke a winner.
                return completion.outcome
            }
        } onCancel: { completion.cancel() }
        try Task.checkCancellation()
        guard let outcome else { throw AudioMembershipRenewalError.incompleteAttempt }
        try outcome.get()
    }

    private final class AttemptCompletion: Sendable {
        private enum State: Sendable { case pending, cancelled, finished(Result<Void, any Error>) }
        private let state = OSAllocatedUnfairLock(initialState: State.pending)
        func finish(_ result: Result<Void, any Error>, revoking lease: AudioMembershipLease? = nil) {
            state.withLock {
                guard case .pending = $0 else { return }
                lease?.revoke()
                $0 = .finished(result)
            }
        }
        func cancel() { state.withLock { if case .pending = $0 { $0 = .cancelled } } }
        var outcome: Result<Void, any Error>? {
            state.withLock { if case .finished(let result) = $0 { return result }; return nil }
        }
    }
}
