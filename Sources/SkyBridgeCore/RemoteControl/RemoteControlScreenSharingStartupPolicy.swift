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

    mutating func beginAttempt(for peerId: String) -> UInt64 {
        let nextGeneration = (generationsByPeerId[peerId] ?? 0) &+ 1
        generationsByPeerId[peerId] = nextGeneration
        return nextGeneration
    }

    mutating func invalidateAttempts(for peerId: String) {
        generationsByPeerId[peerId] = (generationsByPeerId[peerId] ?? 0) &+ 1
    }

    func isCurrentAttempt(_ generation: UInt64, for peerId: String) -> Bool {
        generationsByPeerId[peerId] == generation
    }
}
