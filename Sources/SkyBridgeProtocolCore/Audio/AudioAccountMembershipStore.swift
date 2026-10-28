import Foundation
import os

/// One locally published account epoch and its configured authority scope.
public struct AudioAccountContext: Sendable {
    public let authorization: AccountAudioAuthorization
    public let account: AudioAccountIdentity

    public init(authorization: AccountAudioAuthorization, account: AudioAccountIdentity) {
        self.authorization = authorization; self.account = account
    }
}

public enum AudioAccountProviderError: Error, Equatable, Sendable {
    case requestInProgress, capacity, contradicted
}

public struct AudioObservationSettlementFailure: Error, Sendable {
    public let original: any Error
    public let settlement: any Error
}

/// Frozen Finished-verified identities of one exact channel owner. The synchronous
/// predicate must be thread-safe and remain false after that owner is retired;
/// it must never follow a replacement connection. This binding is not account authority.
@MainActor
public struct AudioAccountChannelBinding: Sendable {
    public let ownerID: UUID
    public let localIdentity: ProtocolIdentityBinding
    public let remoteIdentity: AudioProtocolIdentity
    public let requireCurrent: @MainActor () throws -> Void
    public let isCurrent: @Sendable () -> Bool

    public init(ownerID: UUID, localIdentity: ProtocolIdentityBinding,
                remoteIdentity: AudioProtocolIdentity,
                requireCurrent: @escaping @MainActor () throws -> Void,
                isCurrent: @escaping @Sendable () -> Bool) {
        self.ownerID = ownerID; self.localIdentity = localIdentity; self.remoteIdentity = remoteIdentity
        self.requireCurrent = requireCurrent; self.isCurrent = isCurrent
    }
}

/// Only a fresh authenticated GET can issue evidence. Optional native protected
/// persistence restores the original evidence and expiry; it cannot renew them.
@MainActor
public final class AudioAccountMembershipStore {
    public final class RequestObservation {
        fileprivate weak var owner: AudioAccountMembershipStore?
        fileprivate var isActive = true
        fileprivate let context: AudioAccountContext
        fileprivate let ticket: AudioMembershipPersistenceObservation?
        fileprivate var observed = false
        fileprivate var committed = false
        fileprivate var settlementAttempted = false
        fileprivate var settled = false
        fileprivate init(owner: AudioAccountMembershipStore, context: AudioAccountContext,
                         ticket: AudioMembershipPersistenceObservation?) {
            self.owner = owner; self.context = context; self.ticket = ticket
        }
    }

    private final class Entry: Sendable {
        let context: AudioAccountContext
        let evidence: AudioAccountMembership
        private let revoked = OSAllocatedUnfairLock(initialState: false)
        init(context: AudioAccountContext, evidence: AudioAccountMembership) {
            self.context = context; self.evidence = evidence
        }
        var isCurrent: Bool { context.authorization.isCurrent && revoked.withLock { !$0 } }
        func revoke() { revoked.withLock { $0 = true } }
    }

    private final class Request {
        let id = UUID()
        let context: AudioAccountContext
        let local: AudioProtocolIdentity
        let peer: AudioProtocolIdentity
        var contradicted = false
        // During a protected write these predecessor consumers remain observed for
        // immediate revocation. They are retired only after handoff or write failure.
        var retiringEntries: [Entry] = []
        init(context: AudioAccountContext, local: AudioProtocolIdentity, peer: AudioProtocolIdentity) {
            self.context = context; self.local = local; self.peer = peer
        }
    }

    private struct Observation {
        enum Fact { case registry(AccountDeviceListSnapshot), removed(AudioProtocolIdentity) }
        let id = UUID()
        let context: AudioAccountContext
        let fact: Fact
    }

    private let currentContext: @MainActor () throws -> AudioAccountContext
    private let fetch: @MainActor (AudioAccountContext, ProtocolIdentityBinding) async throws -> AccountDeviceListSnapshot
    private let wall: @Sendable () -> Int64
    private let monotonic: @Sendable () -> ContinuousClock.Instant
    private let isCallerInactive: @Sendable (Error) -> Bool
    private let isTemporaryFetchFailure: @Sendable (Error) -> Bool
    private let persistence: AudioMembershipPersistence?
    private var persistedContext: AudioAccountContext?
    private var persistedSnapshot: AudioMembershipPersistenceSnapshot?
    private var persistenceFailure: Error?
    private var dirty = false
    private var mutationRevision = UUID()
    private var stateBusy = false
    private var stateWaiters: [CheckedContinuation<Void, Error>] = []
    private var observations: [Observation] = []
    public private(set) var restorationStatus: AudioMembershipRestorationStatus
    private var entries: [Entry] = []
    private var pending: Request?
    private static let capacity = 32

    public init(currentContext: @escaping @MainActor () throws -> AudioAccountContext,
         fetch: @escaping @MainActor (AudioAccountContext, ProtocolIdentityBinding) async throws -> AccountDeviceListSnapshot,
         wall: @escaping @Sendable () -> Int64,
         monotonic: @escaping @Sendable () -> ContinuousClock.Instant,
         isCallerInactive: @escaping @Sendable (Error) -> Bool,
         isTemporaryFetchFailure: @escaping @Sendable (Error) -> Bool,
         persistence: AudioMembershipPersistence? = nil) {
        self.currentContext = currentContext; self.fetch = fetch
        self.wall = wall; self.monotonic = monotonic
        self.isCallerInactive = isCallerInactive
        self.isTemporaryFetchFailure = isTemporaryFetchFailure
        self.persistence = persistence
        restorationStatus = persistence == nil ? .notConfigured : .pending
    }

    public func lease(for channel: AudioAccountChannelBinding, refresh: Bool = false) async throws -> AudioMembershipLease {
        try await acquireLease(for: channel, refresh: refresh, continuing: nil)
    }

    public func renew(for channel: AudioAccountChannelBinding,
                      continuing: AudioMembershipLease) async throws -> AudioMembershipLease {
        try await acquireLease(for: channel, refresh: true, continuing: continuing)
    }

    /// All registry requests that can contradict durable grants enter this boundary
    /// before HTTP. A plain completed fact cannot manufacture its missing request owner.
    public func observeRequest<T: Sendable>(context: AudioAccountContext, allowTemporaryFailure: Bool,
        operation: @MainActor (RequestObservation) async throws -> T) async throws -> T {
        try await observeRequest(context: context, allowTemporaryFailure: allowTemporaryFailure,
            request: nil, operation: operation)
    }

    private func observeRequest<T: Sendable>(context: AudioAccountContext, allowTemporaryFailure: Bool,
        request: Request?, operation: @MainActor (RequestObservation) async throws -> T) async throws -> T {
        var observation: RequestObservation?
        defer { observation?.isActive = false }
        var enteredOperation = false
        do {
            try Task.checkCancellation()
            try requireCurrent(context)
            try await acquireState()
            do {
                var recovering = false
                do { try await preparePersistence(context) }
                catch ProtectedAccountSessionError.verificationRequired { recovering = true }
                if recovering, let pending, pending !== request { throw AudioAccountProviderError.requestInProgress }
                let ticket = try await persistence?.beginObservation(context)
                let prepared = RequestObservation(owner: self, context: context, ticket: ticket)
                observation = prepared
                if recovering {
                    // Successful preparation retired the unowned markers and checkpoint.
                    // Other storage errors are never reset by starting another request.
                    entries.forEach { $0.revoke() }; entries.removeAll()
                    persistedContext = nil; persistedSnapshot = nil; persistenceFailure = nil; dirty = false
                }
                try await preparePersistence(context)
                releaseState()
            } catch { releaseState(); throw error }
            let active = try unwrapObservation(observation)
            try Task.checkCancellation()
            enteredOperation = true
            let value = try await operation(active)
            try await settleObservation(active)
            await active.ticket?.abandon()
            return value
        } catch {
            if let active = observation, !active.settlementAttempted, context.authorization.isCurrent,
               !enteredOperation || (active.observed && active.committed) ||
                (allowTemporaryFailure && !active.observed && isTemporaryObservationFailure(error)) {
                do { try await settleObservation(active) }
                catch let settlement {
                    await active.ticket?.abandon()
                    throw AudioObservationSettlementFailure(original: error, settlement: settlement)
                }
            }
            await observation?.ticket?.abandon()
            throw error
        }
    }

    private func isTemporaryObservationFailure(_ error: Error) -> Bool {
        if let unavailable = error as? AudioMembershipRequestUnavailable {
            return isTemporaryFetchFailure(unavailable.underlying)
        }
        return isTemporaryFetchFailure(error)
    }

    private func unwrapObservation(_ observation: RequestObservation?) throws -> RequestObservation {
        guard let observation else { throw ProtectedAccountSessionError.invalidRecord }
        return observation
    }

    private func requireObservation(_ observation: RequestObservation, context: AudioAccountContext) throws {
        try requireCurrent(context)
        guard observation.owner === self, observation.isActive, !observation.settlementAttempted,
              observation.context.authorization === context.authorization,
              observation.context.account == context.account else { throw ProtectedAccountSessionError.changed }
    }

    private func settleObservation(_ observation: RequestObservation) async throws {
        if observation.settled { return }
        try requireObservation(observation, context: observation.context)
        try await acquireState()
        defer { releaseState() }
        try await flushPersistence(observation.context, settling: observation)
    }

    private func acquireLease(for channel: AudioAccountChannelBinding, refresh: Bool,
                              continuing: AudioMembershipLease?) async throws -> AudioMembershipLease {
        try Task.checkCancellation()
        let context = try currentContext()
        try requireCurrent(context)
        try channel.requireCurrent()
        let binding = channel.localIdentity
        let local = try AudioProtocolIdentity(binding)
        let peer = channel.remoteIdentity
        let predecessorID = continuing?.evidence.id
        if let continuing { try requireContinuation(continuing, context: context, channel: channel) }
        let request: Request
        try await acquireState()
        do {
            do { try await preparePersistence(context) }
            catch ProtectedAccountSessionError.verificationRequired {
                guard continuing == nil, pending == nil else { throw ProtectedAccountSessionError.verificationRequired }
                // A new online observation may recover. No stored or live entry is admitted.
                restorationStatus = .verificationRequired
            }
            try Task.checkCancellation()
            try channel.requireCurrent()
            try prune()
            if (persistenceFailure as? ProtectedAccountSessionError) != .verificationRequired {
                try await flushPersistence(context)
            }
            if let continuing {
                try requireContinuation(continuing, context: context, channel: channel)
                guard entries.contains(where: { $0.context.authorization === context.authorization &&
                    $0.evidence.id == predecessorID }) else { throw AudioAccountProviderError.contradicted }
            }
            if !refresh, let cached = entries.first(where: {
                $0.context.authorization === context.authorization && $0.evidence.account == context.account
                    && $0.evidence.localIdentity == local && $0.evidence.peerIdentity == peer
            }) {
                let lease = try makeLease(cached, channel: channel)
                releaseState()
                return lease
            }
            guard pending == nil else { throw AudioAccountProviderError.requestInProgress }
            request = Request(context: context, local: local, peer: peer)
            pending = request
            releaseState()
        } catch {
            releaseState()
            throw error
        }
        defer {
            request.retiringEntries.forEach { $0.revoke() }
            if pending === request { pending = nil }
        }
        return try await observeRequest(context: context, allowTemporaryFailure: true, request: request) { observation in
            try await fetchLease(for: channel, context: context, request: request,
                continuing: continuing, predecessorID: predecessorID, observation: observation)
        }
    }

    private func fetchLease(for channel: AudioAccountChannelBinding, context: AudioAccountContext,
                            request: Request, continuing: AudioMembershipLease?, predecessorID: UUID?,
                            observation: RequestObservation) async throws -> AudioMembershipLease {
        let binding = channel.localIdentity
        let local = request.local, peer = request.peer
        let startedWall = wall(), startedMonotonic = monotonic()
        let response: AccountDeviceListSnapshot
        do {
            response = try await fetch(context, binding)
        } catch {
            if context.authorization.isCurrent,
               isCallerInactive(error) {
                try await revoke(identity: local, context: context, observation: observation)
            }
            if let continuing {
                try Task.checkCancellation()
                if isTemporaryFetchFailure(error) {
                    try requireContinuation(continuing, context: context, channel: channel)
                    throw AudioMembershipRequestUnavailable(error)
                }
            }
            throw error
        }
        try requireCurrent(context)
        let receivedWall = wall(), receivedMonotonic = monotonic()
        try await observeFreshRegistry(response, context: context, caller: local,
            startedWall: startedWall, receivedWall: receivedWall,
            startedMonotonic: startedMonotonic, receivedMonotonic: receivedMonotonic, observation: observation)
        // The completed account GET can revoke other streams even when this
        // particular channel/task ended while it was in flight.
        try Task.checkCancellation()
        try channel.requireCurrent()
        // A different registry/removal request may have completed during the GET.
        // Once contradicted, this exact request cannot publish even a positive reply.
        guard pending === request, !request.contradicted else { throw AudioAccountProviderError.contradicted }
        let evidence = try AudioAccountMembership.verifyFreshResponse(response,
            account: context.account, local: local, peer: peer,
            requestStartedMilliseconds: startedWall, receivedMilliseconds: receivedWall,
            requestStartedMonotonic: startedMonotonic, receivedMonotonic: receivedMonotonic)
        try await acquireState()
        defer { releaseState() }
        try await preparePersistence(context)
        try Task.checkCancellation()
        try channel.requireCurrent()
        guard pending === request, !request.contradicted else { throw AudioAccountProviderError.contradicted }
        try prune()
        let previous = entries.filter { $0.context.authorization === context.authorization
            && $0.evidence.account == context.account && $0.evidence.localIdentity == local && $0.evidence.peerIdentity == peer }
        guard entries.count - previous.count < Self.capacity else { throw AudioAccountProviderError.capacity }
        let entry = Entry(context: context, evidence: evidence)
        _ = try makeLease(entry, channel: channel)
        if let continuing {
            try requireContinuation(continuing, context: context, channel: channel)
            guard previous.contains(where: { $0.evidence.id == predecessorID }) else {
                throw AudioAccountProviderError.contradicted
            }
            request.retiringEntries = previous
        } else {
            // An ordinary explicit replacement still revokes all previous consumers.
            previous.forEach { $0.revoke() }
        }
        entries.removeAll { candidate in previous.contains { $0 === candidate } }
        entries.append(entry)
        markDirty()
        try await flushPersistence(context, settling: observation)
        try Task.checkCancellation()
        guard pending === request, !request.contradicted else { throw AudioAccountProviderError.contradicted }
        if let continuing, let predecessorID {
            try requireContinuation(continuing, context: context, channel: channel)
            try continuing.continueWith(evidence, replacing: predecessorID, isAccountCurrent: { entry.isCurrent })
            return continuing
        }
        return try makeLease(entry, channel: channel)
    }

    public func observeFreshRegistry(_ response: AccountDeviceListSnapshot, context: AudioAccountContext,
                              caller: AudioProtocolIdentity, startedWall: Int64, receivedWall: Int64,
                              startedMonotonic: ContinuousClock.Instant,
                              receivedMonotonic: ContinuousClock.Instant,
                              observation request: RequestObservation) async throws {
        try requireObservation(request, context: context)
        try AudioAccountMembership.validateFreshObservation(response, account: context.account, local: caller,
            requestStartedMilliseconds: startedWall, receivedMilliseconds: receivedWall,
            requestStartedMonotonic: startedMonotonic, receivedMonotonic: receivedMonotonic)
        request.observed = true; request.committed = false
        let observation = try retainObservation(.registry(response), context: context)
        defer { observations.removeAll { $0.id == observation } }
        applyRegistry(response, context: context)
        try await acquireState()
        defer { releaseState() }
        try await preparePersistence(context)
        // A negative observation may arrive before the first protected load.
        // Apply it again to restored entries before any lease can be returned.
        applyRegistry(response, context: context)
        try prune()
        try await flushPersistence(context)
        request.committed = true
    }

    private func applyRegistry(_ response: AccountDeviceListSnapshot, context: AudioAccountContext) {
        for entry in revocableEntries where entry.isCurrent && entry.context.authorization === context.authorization
            && entry.evidence.account == context.account {
            if AudioAccountMembership.contradicts(response, local: entry.evidence.localIdentity,
                                                  peer: entry.evidence.peerIdentity) { entry.revoke(); markDirty() }
        }
        if let pending, pending.context.authorization === context.authorization,
           pending.context.account == context.account,
           AudioAccountMembership.contradicts(response, local: pending.local, peer: pending.peer) {
            pending.contradicted = true
        }
    }

    private func revokeInMemory(identity: AudioProtocolIdentity, authorization: AccountAudioAuthorization) {
        for entry in revocableEntries where entry.isCurrent && entry.context.authorization === authorization
            && (entry.evidence.localIdentity == identity || entry.evidence.peerIdentity == identity) {
            entry.revoke(); markDirty()
        }
        if let pending, pending.context.authorization === authorization,
           pending.local == identity || pending.peer == identity { pending.contradicted = true }
    }

    public func revoke(identity: AudioProtocolIdentity, authorization: AccountAudioAuthorization,
                       observation: RequestObservation) async throws {
        let context = try currentContext()
        guard context.authorization === authorization else { throw AudioMembershipLeaseFailure.accountChanged }
        try await revoke(identity: identity, context: context, observation: observation)
    }

    /// A completed authenticated heartbeat may report an inactive exact caller
    /// even with HTTP 200 (online presence and active registration are separate).
    /// Positive/throttled/unavailable results never create or renew membership.
    public func observeHeartbeat(_ response: SignalServerClient.PresenceRegisterResponseBody,
                                 context: AudioAccountContext, caller: AudioProtocolIdentity,
                                 observation: RequestObservation) async throws {
        try requireObservation(observation, context: context)
        if response.persisted == false, response.persistReason == "device_not_active" {
            try await revoke(identity: caller, context: context, observation: observation)
        }
        observation.observed = true; observation.committed = true
    }

    /// Request adapters use the full captured scope. The authorization-only
    /// overload remains for callers that already own that exact account lifetime.
    public func revoke(identity: AudioProtocolIdentity, context: AudioAccountContext,
                       observation request: RequestObservation) async throws {
        try requireObservation(request, context: context)
        request.observed = true; request.committed = false
        let observation = try retainObservation(.removed(identity), context: context)
        defer { observations.removeAll { $0.id == observation } }
        revokeInMemory(identity: identity, authorization: context.authorization)
        try await acquireState()
        defer { releaseState() }
        try await preparePersistence(context)
        revokeInMemory(identity: identity, authorization: context.authorization)
        try prune()
        try await flushPersistence(context)
        request.committed = true
    }

    private func requireCurrent(_ expected: AudioAccountContext) throws {
        let current = try currentContext()
        guard expected.authorization.isCurrent, current.authorization === expected.authorization,
              current.account == expected.account else { throw AudioMembershipLeaseFailure.accountChanged }
    }

    private var revocableEntries: [Entry] { entries + (pending?.retiringEntries ?? []) }

    private func requireContinuation(_ lease: AudioMembershipLease, context: AudioAccountContext,
                                     channel: AudioAccountChannelBinding) throws {
        try requireCurrent(context)
        try channel.requireCurrent()
        if let failure = lease.failure { throw failure }
        let evidence = lease.evidence
        guard lease.ownerID == channel.ownerID, evidence.account == context.account,
              evidence.localIdentity == (try AudioProtocolIdentity(channel.localIdentity)),
              evidence.peerIdentity == channel.remoteIdentity else { throw AudioMembershipError.invalidIdentity }
    }

    private func prune() throws {
        let now = wall(), monotonicNow = monotonic()
        for entry in entries where entry.isCurrent {
            let evidence = entry.evidence
            do {
                try evidence.validate(account: entry.context.account, local: evidence.localIdentity,
                    peer: evidence.peerIdentity, nowMilliseconds: now, monotonicNow: monotonicNow)
            } catch AudioMembershipError.expired { entry.revoke(); markDirty()
            } catch AudioMembershipError.clockMovedBackwards { entry.revoke(); markDirty() }
        }
        entries.removeAll { !$0.isCurrent }
    }

    private func markDirty() { dirty = true; mutationRevision = UUID() }

    private func retainObservation(_ fact: Observation.Fact, context: AudioAccountContext) throws -> UUID {
        guard observations.count < Self.capacity else {
            // Never let overload discard a completed negative observation while
            // leaving its account able to admit another stream.
            context.authorization.revoke()
            throw AudioAccountProviderError.capacity
        }
        let observation = Observation(context: context, fact: fact)
        observations.append(observation)
        return observation.id
    }

    /// Serializes local protected I/O, never the network GET. Completed negative
    /// observations revoke live entries before waiting for this bounded queue.
    private func acquireState() async throws {
        if !stateBusy { stateBusy = true; return }
        guard stateWaiters.count < Self.capacity else { throw AudioAccountProviderError.capacity }
        try await withCheckedThrowingContinuation { stateWaiters.append($0) }
    }

    private func releaseState() {
        if stateWaiters.isEmpty { stateBusy = false }
        else { stateWaiters.removeFirst().resume() }
    }

    private func preparePersistence(_ context: AudioAccountContext) async throws {
        try requireCurrent(context)
        guard let persistence else { return }
        if let previous = persistedContext,
           previous.authorization === context.authorization, previous.account == context.account {
            if let persistenceFailure { throw persistenceFailure }
            do {
                guard let expected = persistedSnapshot else { throw ProtectedAccountSessionError.invalidRecord }
                let latest = try await persistence.load(context)
                try requireCurrent(context)
                guard latest == expected else { throw ProtectedAccountSessionError.changed }
            } catch {
                // Another process may have cleared/replaced this login or its
                // evidence. In-memory reuse must verify the protected witness
                // at admission; credential-only refresh preserves that witness.
                failPersistence(error, context: context)
                throw error
            }
            return
        }
        entries.forEach { $0.revoke() }; entries.removeAll()
        persistedContext = context; persistedSnapshot = nil; persistenceFailure = nil; dirty = false
        restorationStatus = .pending
        do {
            let snapshot = try await persistence.load(context)
            try requireCurrent(context)
            persistedSnapshot = snapshot
            guard let bytes = snapshot.checkpoint else { restorationStatus = .empty; return }
            let restored: AudioMembershipCheckpoint.Restoration
            do {
                let boot = try await persistence.bootSessionID()
                try requireCurrent(context)
                restored = try AudioMembershipCheckpoint.restore(bytes, account: context.account,
                    loginID: context.authorization.loginID, bootSessionID: boot,
                    nowMilliseconds: wall(), monotonicNow: monotonic())
            } catch AudioMembershipCheckpointError.bootChanged {
                // A reboot retires the old monotonic epoch. Clear its checkpoint;
                // the next authenticated GET is the only route to a new grant.
                restorationStatus = .differentBoot; markDirty(); return
            }
            entries = restored.evidence.map { Entry(context: context, evidence: $0) }
            restorationStatus = .restored(entries: entries.count, expired: restored.expiredEntryCount)
            if restored.expiredEntryCount > 0 { markDirty() }
            // A negative fact can arrive while the first Keychain load suspends.
            // Apply all still-owned facts before a restored lease is considered.
            for observation in observations where observation.context.authorization === context.authorization
                && observation.context.account == context.account {
                switch observation.fact {
                case .registry(let response): applyRegistry(response, context: context)
                case .removed(let identity): revokeInMemory(identity: identity, authorization: context.authorization)
                }
            }
        } catch {
            failPersistence(error, context: context)
            throw error
        }
    }

    private func flushPersistence(_ context: AudioAccountContext, settling observation: RequestObservation? = nil) async throws {
        try requireCurrent(context)
        guard let persistence else {
            dirty = false
            observation?.settlementAttempted = true; observation?.settled = true
            return
        }
        if let persistenceFailure { throw persistenceFailure }
        guard dirty || observation != nil else { return }
        do {
            // Native clock identity may wait on a bounded process lock. A
            // completed negative observation can revoke entries during that
            // suspension, so take the persistence snapshot only afterwards.
            let boot: UUID?
            if dirty && entries.contains(where: {
                $0.isCurrent && $0.context.authorization === context.authorization && $0.evidence.account == context.account
            }) {
                boot = try await persistence.bootSessionID()
                try requireCurrent(context)
                try prune()
            } else {
                boot = nil // Clearing evidence or settling an unchanged record needs no clock.
            }
            guard let snapshot = persistedSnapshot else { throw ProtectedAccountSessionError.invalidRecord }
            let revision = mutationRevision, wasDirty = dirty
            let evidence = entries.filter {
                $0.isCurrent && $0.context.authorization === context.authorization && $0.evidence.account == context.account
            }.map(\.evidence)
            let checkpoint: Data?
            if wasDirty && !evidence.isEmpty {
                guard let boot else { throw ProtectedAccountSessionError.invalidRecord }
                checkpoint = try AudioMembershipCheckpoint.encode(evidence,
                    account: context.account, loginID: context.authorization.loginID,
                    bootSessionID: boot, nowMilliseconds: wall(), monotonicNow: monotonic())
            } else { checkpoint = nil }
            let committed: AudioMembershipPersistenceSnapshot
            if let observation {
                try requireObservation(observation, context: context)
                observation.settlementAttempted = true
                guard let ticket = observation.ticket else { throw ProtectedAccountSessionError.invalidRecord }
                committed = try await ticket.finish(snapshot.revision, wasDirty ? .replace(checkpoint) : .unchanged)
                observation.settled = true
            } else {
                committed = try await persistence.save(context, snapshot.revision, checkpoint)
            }
            try requireCurrent(context)
            guard (!wasDirty || committed.revision != snapshot.revision),
                  committed.checkpoint == (wasDirty ? checkpoint : snapshot.checkpoint) else {
                throw ProtectedAccountSessionError.invalidRecord
            }
            persistedSnapshot = committed
            if mutationRevision == revision { dirty = false }
        } catch {
            failPersistence(error, context: context)
            throw error
        }
    }

    private func failPersistence(_ error: Error, context: AudioAccountContext) {
        for entry in revocableEntries where entry.context.authorization === context.authorization { entry.revoke() }
        persistenceFailure = error
        restorationStatus = .failed
    }

    private func makeLease(_ entry: Entry, channel: AudioAccountChannelBinding) throws -> AudioMembershipLease {
        try requireCurrent(entry.context)
        try channel.requireCurrent()
        return try AudioMembershipLease(evidence: entry.evidence, ownerID: channel.ownerID,
            account: entry.context.account, local: try AudioProtocolIdentity(channel.localIdentity),
            peer: channel.remoteIdentity, wallMilliseconds: wall, monotonicNow: monotonic,
            isAccountCurrent: { entry.isCurrent }, isPeerCurrent: channel.isCurrent)
    }
}
