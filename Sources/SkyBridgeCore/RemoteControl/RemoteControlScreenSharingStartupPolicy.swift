import Foundation

enum RemoteControlScreenSharingStartupDecision: Equatable, Sendable {
    case startImmediately
    case awaitViewerConfiguration(fallbackAfter: Duration)
}

enum RemoteControlScreenSharingStartupPolicy {
    static let initialConfigurationGrace: Duration = .milliseconds(900)
    static let legacyFallbackDelay: Duration = .seconds(15)

    static func decision(
        hasInitialStreamConfiguration: Bool
    ) -> RemoteControlScreenSharingStartupDecision {
        if hasInitialStreamConfiguration {
            return .startImmediately
        }
        return .awaitViewerConfiguration(fallbackAfter: legacyFallbackDelay)
    }
}

struct RemoteControlScreenSharingAttemptGate: Sendable {
    private var generationsByPeerId: [String: UInt64] = [:]
    private var startingGenerationsByPeerId: [String: UInt64] = [:]

    mutating func beginAttempt(for peerId: String) -> UInt64 {
        let nextGeneration = (generationsByPeerId[peerId] ?? 0) &+ 1
        generationsByPeerId[peerId] = nextGeneration
        return nextGeneration
    }

    mutating func beginAttemptIfIdle(for peerId: String) -> UInt64? {
        if let activeGeneration = startingGenerationsByPeerId[peerId],
           generationsByPeerId[peerId] == activeGeneration {
            return nil
        }
        let generation = beginAttempt(for: peerId)
        startingGenerationsByPeerId[peerId] = generation
        return generation
    }

    mutating func finishAttempt(_ generation: UInt64, for peerId: String) {
        guard startingGenerationsByPeerId[peerId] == generation else { return }
        startingGenerationsByPeerId.removeValue(forKey: peerId)
    }

    mutating func invalidateAttempts(for peerId: String) {
        generationsByPeerId[peerId] = (generationsByPeerId[peerId] ?? 0) &+ 1
        startingGenerationsByPeerId.removeValue(forKey: peerId)
    }

    func isCurrentAttempt(_ generation: UInt64, for peerId: String) -> Bool {
        generationsByPeerId[peerId] == generation
    }
}
