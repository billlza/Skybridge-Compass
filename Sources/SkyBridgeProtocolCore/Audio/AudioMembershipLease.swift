import Foundation
import os

public enum AudioMembershipLeaseFailure: Error, Equatable, Sendable {
    case revoked, accountChanged, peerChanged, expired, clockMovedBackwards
}

/// A connection-bound, local lease usable without network access until expiry.
/// The online evidence is distinct from the receiver's one-stream permission.
/// Persistent/offline restoration must obtain evidence from protected local
/// storage; this type never accepts remote bytes or device-list display caches.
public final class AudioMembershipLease: Sendable {
    private struct State: Sendable {
        var evidence: AudioAccountMembership
        var isAccountCurrent: @Sendable () -> Bool
        var failure: AudioMembershipLeaseFailure?
    }
    private let state: OSAllocatedUnfairLock<State>
    public var evidence: AudioAccountMembership { state.withLock { $0.evidence } }
    public let ownerID: UUID
    private let account: AudioAccountIdentity
    private let local: AudioProtocolIdentity
    private let peer: AudioProtocolIdentity
    private let wallMilliseconds: @Sendable () -> Int64
    private let monotonicNow: @Sendable () -> ContinuousClock.Instant
    private let isPeerCurrent: @Sendable () -> Bool

    public init(evidence: AudioAccountMembership, ownerID: UUID,
                account: AudioAccountIdentity, local: AudioProtocolIdentity, peer: AudioProtocolIdentity,
                wallMilliseconds: @escaping @Sendable () -> Int64,
                monotonicNow: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
                isAccountCurrent: @escaping @Sendable () -> Bool,
                isPeerCurrent: @escaping @Sendable () -> Bool) throws {
        let started = monotonicNow()
        let now = wallMilliseconds()
        try evidence.validate(account: account, local: local, peer: peer, nowMilliseconds: now,
                              monotonicNow: started)
        guard ownerID != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) else {
            throw AudioMembershipError.invalidIdentity
        }
        guard isAccountCurrent() else { throw AudioMembershipLeaseFailure.accountChanged }
        guard isPeerCurrent() else { throw AudioMembershipLeaseFailure.peerChanged }
        state = OSAllocatedUnfairLock(initialState: State(evidence: evidence,
            isAccountCurrent: isAccountCurrent, failure: nil))
        self.ownerID = ownerID; self.account = account; self.local = local; self.peer = peer
        self.wallMilliseconds = wallMilliseconds; self.monotonicNow = monotonicNow
        self.isPeerCurrent = isPeerCurrent
        if let failure { throw failure }
    }

    public var failure: AudioMembershipLeaseFailure? {
        if let failure = accountEffectFailure { return failure }
        if !isPeerCurrent() { return fail(.peerChanged) }
        return state.withLock { $0.failure }
    }

    /// The carrier already holds and validates its peer owner. Re-entering the
    /// peer predicate here would recurse into that lock. Account predicates and
    /// clock providers must remain synchronous, thread-safe and non-reentrant.
    public func requireEffectCurrent() throws {
        if let failure = accountEffectFailure { throw failure }
    }

    private var accountEffectFailure: AudioMembershipLeaseFailure? {
        state.withLock { accountEffectFailure(in: &$0) }
    }

    private func accountEffectFailure(in current: inout State) -> AudioMembershipLeaseFailure? {
        if let failure = current.failure { return failure }
        if !current.isAccountCurrent() { current.failure = .accountChanged; return current.failure }
        let now = wallMilliseconds()
        let monotonic = monotonicNow()
        let evidence = current.evidence
        if now < evidence.issuedAtMilliseconds || monotonic < evidence.issuedAtMonotonic { current.failure = .clockMovedBackwards }
        else if now >= evidence.expiresAtMilliseconds || monotonic >= evidence.expiresAtMonotonic { current.failure = .expired }
        return current.failure
    }

    /// Store-only publication after a fresh authenticated GET and protected persistence.
    /// The effect gate and handoff share this lock, so retiring the predecessor cannot
    /// manufacture a revocation between selecting the current evidence and validating it.
    func continueWith(_ replacement: AudioAccountMembership, replacing expectedID: UUID,
                      isAccountCurrent: @escaping @Sendable () -> Bool) throws {
        guard isPeerCurrent() else { throw fail(.peerChanged) }
        try state.withLock { current in
            if let failure = accountEffectFailure(in: &current) { throw failure }
            guard current.evidence.id == expectedID else { throw AudioMembershipLeaseFailure.revoked }
            try replacement.validate(account: account, local: local, peer: peer,
                nowMilliseconds: wallMilliseconds(), monotonicNow: monotonicNow())
            let previous = current.evidence
            guard replacement.id != previous.id,
                  replacement.issuedAtMilliseconds > previous.issuedAtMilliseconds,
                  replacement.expiresAtMilliseconds > previous.expiresAtMilliseconds,
                  replacement.issuedAtMonotonic > previous.issuedAtMonotonic,
                  replacement.expiresAtMonotonic > previous.expiresAtMonotonic else {
                throw AudioMembershipError.invalidTime
            }
            guard isAccountCurrent() else { throw AudioMembershipLeaseFailure.accountChanged }
            current = State(evidence: replacement, isAccountCurrent: isAccountCurrent, failure: nil)
        }
    }

    public var isCurrent: Bool { failure == nil }

    public func revoke(_ reason: AudioMembershipLeaseFailure = .revoked) {
        state.withLock { if $0.failure == nil { $0.failure = reason } }
    }

    private func fail(_ reason: AudioMembershipLeaseFailure) -> AudioMembershipLeaseFailure {
        state.withLock {
            if let existing = $0.failure { return existing }
            $0.failure = reason
            return reason
        }
    }
}
