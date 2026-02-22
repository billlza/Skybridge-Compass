import Foundation

@available(macOS 14.0, iOS 17.0, *)
public struct HandshakeSOAMetadata: Sendable, Equatable {
    public let initiatorPeerId: Data // 32 bytes
    public let targetPeerId: Data // 32 bytes
    public let attemptId: Data // 16 bytes

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
    }

    public var extensionRaw: Data {
        (try? HandshakeSOAExtension(
            initiatorPeerId: initiatorPeerId,
            targetPeerId: targetPeerId,
            attemptId: attemptId
        ).encodedTLV) ?? Data()
    }
}

@available(macOS 14.0, iOS 17.0, *)
public actor PeerSessionArbiter {
    public static let shared = PeerSessionArbiter()

    public enum RegisterDecision: Sendable {
        case accepted
        case alreadyConnected
        case alreadyInProgress
    }

    public enum IncomingDecision: Sendable {
        case accept
        case rejectAlreadyConnected
        case rejectBinding
        case rejectRateLimited
        case rejectLocalWinner
        case acceptAndSupersedeLocal(winnerPeerId: Data, winnerAttemptId: Data)
    }

    public struct OutgoingAttempt: Sendable {
        public let pairKey: Data
        public let initiatorPeerId: Data
        public let attemptId: Data
        public let startedAt: Date
        public let onSuperseded: @Sendable (Data, Data) async -> Void
    }

    private let pendingWindowSeconds: TimeInterval = 10
    private let supersedeRateLimit: Int = 3
    private let supersedeRateWindowSeconds: TimeInterval = 60

    private var outgoingByPair: [Data: OutgoingAttempt] = [:]
    private var establishedPairs: Set<Data> = []
    private var supersedeTimestampsByPair: [Data: [Date]] = [:]

    public func registerOutgoing(_ attempt: OutgoingAttempt) -> RegisterDecision {
        if establishedPairs.contains(attempt.pairKey) {
            return .alreadyConnected
        }
        if let existing = outgoingByPair[attempt.pairKey],
           Date().timeIntervalSince(existing.startedAt) <= pendingWindowSeconds {
            return .alreadyInProgress
        }
        outgoingByPair[attempt.pairKey] = attempt
        return .accepted
    }

    public func clearOutgoing(pairKey: Data, attemptId: Data?) {
        guard let existing = outgoingByPair[pairKey] else { return }
        if let attemptId, existing.attemptId != attemptId { return }
        outgoingByPair.removeValue(forKey: pairKey)
    }

    public func markEstablished(pairKey: Data) {
        establishedPairs.insert(pairKey)
        outgoingByPair.removeValue(forKey: pairKey)
    }

    public func clearEstablished(pairKey: Data) {
        establishedPairs.remove(pairKey)
    }

    public func evaluateIncoming(
        pairKey: Data,
        remoteInitiatorPeerId: Data,
        remoteAttemptId: Data,
        targetPeerId: Data,
        expectedRemotePeerId: Data,
        localPeerId: Data
    ) -> IncomingDecision {
        if establishedPairs.contains(pairKey) {
            return .rejectAlreadyConnected
        }
        guard targetPeerId == localPeerId, remoteInitiatorPeerId == expectedRemotePeerId else {
            return .rejectBinding
        }

        guard let local = outgoingByPair[pairKey] else {
            return .accept
        }

        if Date().timeIntervalSince(local.startedAt) > pendingWindowSeconds {
            outgoingByPair.removeValue(forKey: pairKey)
            return .accept
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
            outgoingByPair.removeValue(forKey: pairKey)
            Task { await local.onSuperseded(remoteInitiatorPeerId, remoteAttemptId) }
            return .acceptAndSupersedeLocal(
                winnerPeerId: remoteInitiatorPeerId,
                winnerAttemptId: remoteAttemptId
            )
        }

        return .rejectLocalWinner
    }

    public nonisolated static func pairKey(localPeerId: Data, remotePeerId: Data) -> Data {
        if localPeerId.lexicographicallyPrecedes(remotePeerId) {
            return localPeerId + remotePeerId
        }
        return remotePeerId + localPeerId
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
