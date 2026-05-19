import Foundation

extension Notification.Name {
    static let crossNetworkScreenDataUpdated = Notification.Name("CrossNetworkScreenDataUpdated")
}

enum CrossNetworkNotificationUserInfoKey {
    static let sessionId = "sessionId"
    static let screenData = "screenData"
}

enum CrossNetworkWebRTCHandshakeLimits {
    static let maxChunkBytes = 1024
    static let maxPaddedPayloadBytes = (8 * 1024) - 4
    static let maxBufferedAmountBytes: UInt64 = 256 * 1024
    static let strictPQCClassicBootstrapTimeoutSeconds: TimeInterval = 30.0
    static let strictPQCClassicBootstrapMaxGraceSeconds: TimeInterval = 120.0
}

@available(iOS 17.0, *)
struct CurrentPathWebRTCHandshakeTransportCompat: DiscoveryTransport {
    let sendFramed: @Sendable (Data) async throws -> Void

    func send(to peer: PeerIdentifier, data: Data) async throws {
        try await sendFramed(data)
    }
}

enum SignalingSessionHealth: String, Sendable, Equatable {
    case healthy
    case degradedRecoverable = "degraded_recoverable"
    case degradedFatal = "degraded_fatal"
}
