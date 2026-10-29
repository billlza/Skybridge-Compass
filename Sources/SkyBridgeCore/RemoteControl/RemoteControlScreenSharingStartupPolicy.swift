import Foundation

enum RemoteControlScreenSharingStartupDecision: Equatable, Sendable {
    case startImmediately
    case awaitViewerConfiguration
}

enum RemoteControlScreenSharingStartupPolicy {
    static let initialConfigurationGrace: Duration = .milliseconds(900)

    static func decision(
        hasInitialStreamConfiguration: Bool
    ) -> RemoteControlScreenSharingStartupDecision {
        if hasInitialStreamConfiguration {
            return .startImmediately
        }
        return .awaitViewerConfiguration
    }

}

struct RemoteControlScreenSharingAttemptGate: Sendable {
    private var generationsByPeerId: [String: UInt64] = [:]
    private var startingGenerationsByPeerId: [String: UInt64] = [:]
    private var restartRequestedPeerIds: Set<String> = []

    mutating func beginAttempt(for peerId: String) -> UInt64 {
        let nextGeneration = (generationsByPeerId[peerId] ?? 0) &+ 1
        generationsByPeerId[peerId] = nextGeneration
        return nextGeneration
    }

    mutating func beginAttemptIfIdle(for peerId: String) -> UInt64? {
        if startingGenerationsByPeerId[peerId] != nil {
            return nil
        }
        let generation = beginAttempt(for: peerId)
        startingGenerationsByPeerId[peerId] = generation
        return generation
    }

    @discardableResult
    mutating func finishAttempt(_ generation: UInt64, for peerId: String) -> Bool {
        guard startingGenerationsByPeerId[peerId] == generation else { return false }
        startingGenerationsByPeerId.removeValue(forKey: peerId)
        return restartRequestedPeerIds.remove(peerId) != nil
    }

    /// Invalidates an in-flight start without releasing its serialization
    /// slot. The retiring attempt consumes this marker in `finishAttempt`, at
    /// which point the manager starts exactly one latest configuration.
    mutating func supersedeInFlightAttemptAndRequestRestart(for peerId: String) -> Bool {
        guard startingGenerationsByPeerId[peerId] != nil else { return false }
        generationsByPeerId[peerId] = (generationsByPeerId[peerId] ?? 0) &+ 1
        restartRequestedPeerIds.insert(peerId)
        return true
    }

    mutating func invalidateAttempts(for peerId: String) {
        generationsByPeerId[peerId] = (generationsByPeerId[peerId] ?? 0) &+ 1
        startingGenerationsByPeerId.removeValue(forKey: peerId)
        restartRequestedPeerIds.remove(peerId)
    }

    func isCurrentAttempt(_ generation: UInt64, for peerId: String) -> Bool {
        generationsByPeerId[peerId] == generation
    }
}
