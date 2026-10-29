import Foundation

@available(iOS 17.0, *)
public extension AppMessage {
    struct PeerDisconnectingPayload: Codable, Sendable, Equatable {
        public let deviceId: String?
        public let deviceName: String?
        public let sentAt: Date

        public init(
            deviceId: String? = nil,
            deviceName: String? = nil,
            sentAt: Date = Date()
        ) {
            self.deviceId = deviceId
            self.deviceName = deviceName
            self.sentAt = sentAt
        }
    }

    /// Ping request payload. Receiver should respond with `pong(id:)` as fast as possible.
    struct PingPayload: Codable, Sendable, Equatable {
        public let id: UInt64

        public init(id: UInt64) {
            self.id = id
        }
    }

    /// Pong response payload (echoes `PingPayload.id`).
    struct PongPayload: Codable, Sendable, Equatable {
        public let id: UInt64

        public init(id: UInt64) {
            self.id = id
        }
    }
}
