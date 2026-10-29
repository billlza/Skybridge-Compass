import Foundation
import CryptoKit

@available(macOS 14.0, iOS 17.0, *)
public struct HandshakeSOAMetadata: Sendable, Equatable {
    public let initiatorPeerId: Data // 32 bytes
    public let targetPeerId: Data // 32 bytes
    public let attemptId: Data // 16 bytes
    public let extensionRaw: Data

    public init(initiatorPeerId: Data, targetPeerId: Data, attemptId: Data) throws {
        guard initiatorPeerId.count == HandshakeSOAExtension.initiatorPeerIdLength else {
            throw HandshakeError.failed(.invalidMessageFormat("SOA initiatorPeerId must be 32 bytes"))
        }
        guard targetPeerId.count == HandshakeSOAExtension.targetPeerIdLength else {
            throw HandshakeError.failed(.invalidMessageFormat("SOA targetPeerId must be 32 bytes"))
        }
        guard attemptId.count == HandshakeSOAExtension.attemptIdLength else {
            throw HandshakeError.failed(.invalidMessageFormat("SOA attemptId must be 16 bytes"))
        }
        self.initiatorPeerId = initiatorPeerId
        self.targetPeerId = targetPeerId
        self.attemptId = attemptId
        self.extensionRaw = try HandshakeSOAExtension(
            initiatorPeerId: initiatorPeerId,
            targetPeerId: targetPeerId,
            attemptId: attemptId
        ).encodedTLV
    }
}

@available(macOS 14.0, iOS 17.0, *)
public actor PeerSessionArbiter {
    public static let shared = PeerSessionArbiter()

    public enum IncomingAuthenticationState: Sendable {
        case authenticated
        case unauthenticated
    }

    public enum IncomingEstablishedPolicy: Sendable {
        case rejectDuplicate
        case replaceAuthenticated
    }

    public enum SessionScope: String, Sendable {
        case p2p = "p2p"
        case remoteControl = "remote-control"
    }

    public enum RegisterDecision: Sendable {
        case accepted(EstablishmentReservation)
        case alreadyConnected
        case alreadyInProgress
    }

    public enum IncomingDecision: Sendable {
        case accept
        case rejectAlreadyConnected
        case rejectBinding
        case rejectRateLimited
        case rejectLocalWinner
        case acceptAndReplaceEstablished
        case acceptAndSupersedeLocal(winnerPeerId: Data, winnerAttemptId: Data)
    }

    /// Reservation-bearing admission used by modern handshake drivers. The
    /// legacy `IncomingDecision` surface remains available below, but cannot
    /// publish an established owner without an explicit reservation.
    public enum IncomingReservationDecision: Sendable {
        case accept(EstablishmentReservation)
        case rejectAlreadyConnected
        case rejectBinding
        case rejectRateLimited
        case rejectLocalWinner
        case acceptAndReplaceEstablished(EstablishmentReservation)
        case acceptAndSupersedeLocal(
            reservation: EstablishmentReservation,
            winnerPeerId: Data,
            winnerAttemptId: Data
        )
    }

    public struct OutgoingAttempt: Sendable {
        public let pairKey: Data
        public let initiatorPeerId: Data
        public let attemptId: Data
        public let startedAt: Date
        public let onSuperseded: @Sendable (Data, Data) async -> Void
    }

    public struct EstablishedLease: Sendable, Equatable {
        public let pairKey: Data
        public let sessionId: String
        private let ownerId: UUID

        public init(pairKey: Data, sessionId: String) {
            self.pairKey = pairKey
            self.sessionId = sessionId
            self.ownerId = UUID()
        }
    }

    /// A one-shot capability to publish a session into an arbiter slot. The
    /// expected owner is retained only inside the actor, so callers cannot
    /// forge or widen the compare-and-swap precondition.
    public struct EstablishmentReservation: Sendable, Equatable {
        public let pairKey: Data
        public let attemptId: Data
        private let reservationId: UUID

        fileprivate init(pairKey: Data, attemptId: Data, reservationId: UUID) {
            self.pairKey = pairKey
            self.attemptId = attemptId
            self.reservationId = reservationId
        }
    }

    public enum EstablishmentCommitError: Error, Sendable, Equatable {
        case reservationInvalidated
        case establishedOwnerChanged
    }

    private enum EstablishedOwner: Equatable {
        case legacy(UUID)
        case session(EstablishedLease)
    }

    private struct EstablishmentAttemptKey: Hashable {
        let pairKey: Data
        let attemptId: Data
    }

    private struct EstablishmentReservationRecord: Equatable {
        let reservation: EstablishmentReservation
        let expectedOwner: EstablishedOwner?
    }

    private struct RegisteredOutgoingAttempt {
        let attempt: OutgoingAttempt
        let reservation: EstablishmentReservation
    }

    private let pendingWindowSeconds: TimeInterval = 10
    private let supersedeRateLimit: Int = 3
    private let supersedeRateWindowSeconds: TimeInterval = 60

    private var outgoingByPair: [Data: RegisteredOutgoingAttempt] = [:]
    private var establishedOwnerByPair: [Data: EstablishedOwner] = [:]
    private var establishmentReservationByAttempt: [
        EstablishmentAttemptKey: EstablishmentReservationRecord
    ] = [:]
    private var supersedeTimestampsByPair: [Data: [Date]] = [:]

#if DEBUG || SKYBRIDGE_TESTING
    public enum TestEstablishmentBarrierError: Error, Sendable, Equatable {
        case barrierAlreadyConfigured
        case attemptDoesNotOwnBarrier
    }

    private var testSuspendedEstablishmentAttemptId: Data?
    private var testEstablishmentCommitContinuation: CheckedContinuation<Void, Never>?
    private var testEstablishmentCommitIsSuspended = false

    public func testOnlySuspendEstablishmentCommit(attemptId: Data) throws {
        guard testEstablishmentCommitContinuation == nil,
              testSuspendedEstablishmentAttemptId == nil else {
            throw TestEstablishmentBarrierError.barrierAlreadyConfigured
        }
        testSuspendedEstablishmentAttemptId = attemptId
    }

    public func testOnlyIsEstablishmentCommitSuspended() -> Bool {
        testEstablishmentCommitIsSuspended
    }

    public func testOnlyResumeEstablishmentCommit(attemptId: Data) throws {
        guard testSuspendedEstablishmentAttemptId == attemptId else {
            throw TestEstablishmentBarrierError.attemptDoesNotOwnBarrier
        }
        testSuspendedEstablishmentAttemptId = nil
        let continuation = testEstablishmentCommitContinuation
        testEstablishmentCommitContinuation = nil
        continuation?.resume()
    }
#endif

    public func registerOutgoing(_ attempt: OutgoingAttempt) -> RegisterDecision {
        if establishedOwnerByPair[attempt.pairKey] != nil {
            return .alreadyConnected
        }
        if let existing = outgoingByPair[attempt.pairKey] {
            if Date().timeIntervalSince(existing.attempt.startedAt) <= pendingWindowSeconds {
                return .alreadyInProgress
            }
            removeOutgoingAttempt(existing, pairKey: attempt.pairKey)
        }
        let reservation = reserveEstablishment(
            pairKey: attempt.pairKey,
            attemptId: attempt.attemptId,
            expectedOwner: nil
        )
        outgoingByPair[attempt.pairKey] = RegisteredOutgoingAttempt(
            attempt: attempt,
            reservation: reservation
        )
        return .accepted(reservation)
    }

    public func clearOutgoing(pairKey: Data, attemptId: Data?) {
        if let attemptId {
            guard let existing = outgoingByPair[pairKey],
                  existing.attempt.attemptId == attemptId else { return }
            removeOutgoingAttempt(existing, pairKey: pairKey)
            return
        }

        guard let existing = outgoingByPair.removeValue(forKey: pairKey) else { return }
        cancelEstablishmentIfCurrent(existing.reservation)
    }

    /// Removes only the outgoing registration that owns this unforgeable
    /// reservation. Public pair/attempt bytes may be reused by a replacement,
    /// but its private reservation identity cannot be reused by stale teardown.
    @discardableResult
    public func clearOutgoing(_ reservation: EstablishmentReservation) -> Bool {
        guard let existing = outgoingByPair[reservation.pairKey],
              existing.reservation == reservation else {
            return false
        }
        removeOutgoingAttempt(existing, pairKey: reservation.pairKey)
        return true
    }

    /// Legacy compatibility: creates only a legacy owner in a vacant slot.
    /// It can neither replace nor acquire a modern session owner.
    public func markEstablished(pairKey: Data) {
        guard establishedOwnerByPair[pairKey] == nil else { return }
        if let outgoing = outgoingByPair[pairKey] {
            removeOutgoingAttempt(outgoing, pairKey: pairKey)
        }
        establishedOwnerByPair[pairKey] = .legacy(UUID())
        invalidateEstablishmentReservations(for: pairKey)
    }

    /// Legacy compatibility: pair-key teardown is deliberately restricted to
    /// legacy owners and can never remove a reservation-committed session.
    public func clearEstablished(pairKey: Data) {
        guard case .legacy? = establishedOwnerByPair[pairKey] else { return }
        establishedOwnerByPair.removeValue(forKey: pairKey)
    }

    @discardableResult
    public func commitEstablished(
        _ reservation: EstablishmentReservation,
        sessionId: String
    ) async throws -> EstablishedLease {
#if DEBUG || SKYBRIDGE_TESTING
        await waitAtTestEstablishmentBarrierIfNeeded(attemptId: reservation.attemptId)
#endif

        let attemptKey = EstablishmentAttemptKey(
            pairKey: reservation.pairKey,
            attemptId: reservation.attemptId
        )
        guard let record = establishmentReservationByAttempt[attemptKey],
              record.reservation == reservation else {
            throw EstablishmentCommitError.reservationInvalidated
        }
        guard establishedOwnerByPair[reservation.pairKey] == record.expectedOwner else {
            establishmentReservationByAttempt.removeValue(forKey: attemptKey)
            throw EstablishmentCommitError.establishedOwnerChanged
        }

        let lease = EstablishedLease(pairKey: reservation.pairKey, sessionId: sessionId)
        establishedOwnerByPair[reservation.pairKey] = .session(lease)
        if outgoingByPair[reservation.pairKey]?.reservation == reservation {
            outgoingByPair.removeValue(forKey: reservation.pairKey)
        }
        invalidateEstablishmentReservations(for: reservation.pairKey)
        return lease
    }

    @discardableResult
    public func clearEstablished(_ lease: EstablishedLease) -> Bool {
        guard establishedOwnerByPair[lease.pairKey] == .session(lease) else {
            return false
        }
        establishedOwnerByPair.removeValue(forKey: lease.pairKey)
        return true
    }

    @discardableResult
    public func restoreEstablishedIfVacant(_ lease: EstablishedLease) -> Bool {
        guard establishedOwnerByPair[lease.pairKey] == nil else { return false }
        establishedOwnerByPair[lease.pairKey] = .session(lease)
        if let outgoing = outgoingByPair[lease.pairKey] {
            removeOutgoingAttempt(outgoing, pairKey: lease.pairKey)
        }
        invalidateEstablishmentReservations(for: lease.pairKey)
        return true
    }

    /// Compatibility decision surface for callers that only arbitrate and do
    /// not own the resulting session. Any accepted reservation is immediately
    /// cancelled so legacy code cannot leave a latent committer behind.
    public func evaluateIncoming(
        pairKey: Data,
        remoteInitiatorPeerId: Data,
        remoteAttemptId: Data,
        targetPeerId: Data,
        expectedRemotePeerId: Data,
        localPeerId: Data,
        authenticationState: IncomingAuthenticationState,
        establishedPolicy: IncomingEstablishedPolicy = .rejectDuplicate
    ) -> IncomingDecision {
        let admission = evaluateIncomingWithReservation(
            pairKey: pairKey,
            remoteInitiatorPeerId: remoteInitiatorPeerId,
            remoteAttemptId: remoteAttemptId,
            targetPeerId: targetPeerId,
            expectedRemotePeerId: expectedRemotePeerId,
            localPeerId: localPeerId,
            authenticationState: authenticationState,
            establishedPolicy: establishedPolicy
        )
        switch admission {
        case .accept(let reservation):
            cancelEstablishmentIfCurrent(reservation)
            return .accept
        case .rejectAlreadyConnected:
            return .rejectAlreadyConnected
        case .rejectBinding:
            return .rejectBinding
        case .rejectRateLimited:
            return .rejectRateLimited
        case .rejectLocalWinner:
            return .rejectLocalWinner
        case .acceptAndReplaceEstablished(let reservation):
            cancelEstablishmentIfCurrent(reservation)
            return .acceptAndReplaceEstablished
        case .acceptAndSupersedeLocal(let reservation, let winnerPeerId, let winnerAttemptId):
            cancelEstablishmentIfCurrent(reservation)
            return .acceptAndSupersedeLocal(
                winnerPeerId: winnerPeerId,
                winnerAttemptId: winnerAttemptId
            )
        }
    }

    public func evaluateIncomingWithReservation(
        pairKey: Data,
        remoteInitiatorPeerId: Data,
        remoteAttemptId: Data,
        targetPeerId: Data,
        expectedRemotePeerId: Data,
        localPeerId: Data,
        authenticationState: IncomingAuthenticationState,
        establishedPolicy: IncomingEstablishedPolicy = .rejectDuplicate
    ) -> IncomingReservationDecision {
        guard authenticationState == .authenticated else {
            return .rejectBinding
        }
        guard targetPeerId == localPeerId, remoteInitiatorPeerId == expectedRemotePeerId else {
            return .rejectBinding
        }
        if establishedOwnerByPair[pairKey] != nil {
            switch establishedPolicy {
            case .rejectDuplicate:
                return .rejectAlreadyConnected
            case .replaceAuthenticated:
                if let outgoing = outgoingByPair[pairKey] {
                    removeOutgoingAttempt(outgoing, pairKey: pairKey)
                }
                return .acceptAndReplaceEstablished(reserveEstablishment(
                    pairKey: pairKey,
                    attemptId: remoteAttemptId,
                    expectedOwner: establishedOwnerByPair[pairKey]
                ))
            }
        }

        guard let localRegistration = outgoingByPair[pairKey] else {
            return .accept(reserveEstablishment(
                pairKey: pairKey,
                attemptId: remoteAttemptId,
                expectedOwner: nil
            ))
        }
        let local = localRegistration.attempt

        if Date().timeIntervalSince(local.startedAt) > pendingWindowSeconds {
            removeOutgoingAttempt(localRegistration, pairKey: pairKey)
            return .accept(reserveEstablishment(
                pairKey: pairKey,
                attemptId: remoteAttemptId,
                expectedOwner: nil
            ))
        }

        guard canSupersede(pairKey: pairKey) else {
            return .rejectRateLimited
        }

        let remoteWins = isRemoteWinner(
            localInitiatorPeerId: local.initiatorPeerId,
            localAttemptId: local.attemptId,
            remoteInitiatorPeerId: remoteInitiatorPeerId,
            remoteAttemptId: remoteAttemptId
        )

        if remoteWins {
            recordSupersede(pairKey: pairKey)
            removeOutgoingAttempt(localRegistration, pairKey: pairKey)
            Task { await local.onSuperseded(remoteInitiatorPeerId, remoteAttemptId) }
            return .acceptAndSupersedeLocal(
                reservation: reserveEstablishment(
                    pairKey: pairKey,
                    attemptId: remoteAttemptId,
                    expectedOwner: nil
                ),
                winnerPeerId: remoteInitiatorPeerId,
                winnerAttemptId: remoteAttemptId
            )
        }

        return .rejectLocalWinner
    }

    @discardableResult
    public func cancelEstablishment(_ reservation: EstablishmentReservation) -> Bool {
        cancelEstablishmentIfCurrent(reservation)
    }

    private func reserveEstablishment(
        pairKey: Data,
        attemptId: Data,
        expectedOwner: EstablishedOwner?
    ) -> EstablishmentReservation {
        // One pending committer per pair. A newer admitted attempt explicitly
        // invalidates an older suspended Finished before it can publish.
        invalidateEstablishmentReservations(for: pairKey)
        let attemptKey = EstablishmentAttemptKey(pairKey: pairKey, attemptId: attemptId)
        let reservation = EstablishmentReservation(
            pairKey: pairKey,
            attemptId: attemptId,
            reservationId: UUID()
        )
        establishmentReservationByAttempt[attemptKey] = EstablishmentReservationRecord(
            reservation: reservation,
            expectedOwner: expectedOwner
        )
        return reservation
    }

    @discardableResult
    private func cancelEstablishmentIfCurrent(
        _ reservation: EstablishmentReservation
    ) -> Bool {
        let attemptKey = EstablishmentAttemptKey(
            pairKey: reservation.pairKey,
            attemptId: reservation.attemptId
        )
        guard establishmentReservationByAttempt[attemptKey]?.reservation == reservation else {
            return false
        }
        establishmentReservationByAttempt.removeValue(forKey: attemptKey)
        return true
    }

    private func removeOutgoingAttempt(
        _ registration: RegisteredOutgoingAttempt,
        pairKey: Data
    ) {
        guard outgoingByPair[pairKey]?.reservation == registration.reservation else { return }
        outgoingByPair.removeValue(forKey: pairKey)
        cancelEstablishmentIfCurrent(registration.reservation)
    }

    private func invalidateEstablishmentReservations(for pairKey: Data) {
        establishmentReservationByAttempt = establishmentReservationByAttempt.filter {
            $0.key.pairKey != pairKey
        }
    }

#if DEBUG || SKYBRIDGE_TESTING
    private func waitAtTestEstablishmentBarrierIfNeeded(attemptId: Data) async {
        guard testSuspendedEstablishmentAttemptId == attemptId else { return }
        testEstablishmentCommitIsSuspended = true
        await withCheckedContinuation { continuation in
            testEstablishmentCommitContinuation = continuation
        }
        testEstablishmentCommitIsSuspended = false
    }
#endif

    public nonisolated static func pairKey(
        localPeerId: Data,
        remotePeerId: Data,
        scope: SessionScope = .p2p
    ) -> Data {
        let baseKey: Data
        if localPeerId.lexicographicallyPrecedes(remotePeerId) {
            baseKey = localPeerId + remotePeerId
        } else {
            baseKey = remotePeerId + localPeerId
        }
        guard scope != .p2p else { return baseKey }

        var scoped = Data(scope.rawValue.utf8)
        scoped.append(0)
        scoped.append(baseKey)
        return scoped
    }

    public nonisolated static func pairKey(
        localIdentifier: String,
        remoteIdentifier: String,
        scope: SessionScope = .p2p
    ) -> Data {
        let localPeerId = soaPeerId(from: localIdentifier)
        let remotePeerId = soaPeerId(from: remoteIdentifier)
        return pairKey(localPeerId: localPeerId, remotePeerId: remotePeerId, scope: scope)
    }

    public nonisolated static func soaPeerId(from identifier: String) -> Data {
        let canonical = canonicalSOAIdentifier(identifier)
        return Data(SHA256.hash(data: Data(canonical.utf8)))
    }

    public nonisolated static func canonicalSOAIdentifier(_ raw: String) -> String {
        var normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while normalized.hasPrefix("recent:") {
            normalized.removeFirst("recent:".count)
        }
        if normalized.hasPrefix("mac:") {
            normalized.removeFirst("mac:".count)
        }
        if normalized.hasPrefix("id:") {
            normalized.removeFirst("id:".count)
            if let uuid = normalizedUUID(in: normalized) {
                return uuid
            }
            return normalized
        }

        if normalized.hasPrefix("bonjour:") {
            let payload = String(normalized.dropFirst("bonjour:".count))
            let components = payload.split(separator: "@", maxSplits: 1).map(String.init)
            let rawName = components.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let rawDomain = components.count > 1 ? components[1] : "local."
            let domain = rawDomain.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedDomain = domain.isEmpty ? "local." : domain
            return "bonjour:\(rawName)@\(normalizedDomain)"
        }

        if normalized.hasPrefix("host:") {
            let hostPayload = String(normalized.dropFirst("host:".count))
            return "host:\(hostPayload)"
        }

        if let uuid = normalizedUUID(in: normalized) {
            return uuid
        }

        return normalized
    }

    public nonisolated static func supersededFailureReason(
        winnerPeerId: Data,
        winnerAttemptId: Data
    ) -> HandshakeFailureReason {
        .supersededByConcurrentAttempt(
            winnerPeerId: winnerPeerId.map { String(format: "%02x", $0) }.joined(),
            winnerAttemptId: winnerAttemptId.map { String(format: "%02x", $0) }.joined()
        )
    }

    private nonisolated static func normalizedUUID(in raw: String) -> String? {
        let direct = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = UUID(uuidString: direct.uppercased()) else {
            return nil
        }
        return parsed.uuidString.lowercased()
    }

    private func isRemoteWinner(
        localInitiatorPeerId: Data,
        localAttemptId: Data,
        remoteInitiatorPeerId: Data,
        remoteAttemptId: Data
    ) -> Bool {
        if remoteInitiatorPeerId == localInitiatorPeerId {
            return remoteAttemptId.lexicographicallyPrecedes(localAttemptId)
        }
        return remoteInitiatorPeerId.lexicographicallyPrecedes(localInitiatorPeerId)
    }

    private func canSupersede(pairKey: Data) -> Bool {
        let now = Date()
        let recent = (supersedeTimestampsByPair[pairKey] ?? []).filter {
            now.timeIntervalSince($0) <= supersedeRateWindowSeconds
        }
        supersedeTimestampsByPair[pairKey] = recent
        return recent.count < supersedeRateLimit
    }

    private func recordSupersede(pairKey: Data) {
        let now = Date()
        let recent = (supersedeTimestampsByPair[pairKey] ?? []).filter {
            now.timeIntervalSince($0) <= supersedeRateWindowSeconds
        }
        supersedeTimestampsByPair[pairKey] = recent + [now]
    }
}
