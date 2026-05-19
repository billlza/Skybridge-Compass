import Foundation

@available(iOS 17.0, *)
public extension AppMessage {
    /// Diagnostic-only negative response for SKR-1. It is intentionally not a
    /// trust-bearing message: clients may use it to surface a fail-fast stage,
    /// but must never import KEM material or continue the handshake from it.
    struct KEMRefreshFailurePayload: Codable, Sendable, Equatable {
        public static let currentVersion = 1

        public let version: Int
        public let requesterDeviceId: String
        public let targetDeviceId: String
        public let stage: String
        public let reasonCode: String
        public let reason: String
        public let requestHashHex: String?
        public let sentAt: Date

        public init(
            version: Int = Self.currentVersion,
            requesterDeviceId: String,
            targetDeviceId: String,
            stage: String,
            reasonCode: String,
            reason: String,
            requestHashHex: String? = nil,
            sentAt: Date = Date()
        ) {
            self.version = version
            self.requesterDeviceId = requesterDeviceId
            self.targetDeviceId = targetDeviceId
            self.stage = stage
            self.reasonCode = reasonCode
            self.reason = reason
            self.requestHashHex = requestHashHex
            self.sentAt = sentAt
        }
    }
}
