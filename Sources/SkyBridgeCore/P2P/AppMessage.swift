import Foundation

/// App-level encrypted message sent over an established P2P session (after handshake).
/// This is distinct from handshake frames.
@available(macOS 14.0, iOS 17.0, *)
public enum AppMessage: Codable, Sendable, Equatable {
    case clipboard(ClipboardPayload)
    case pairingIdentityExchange(PairingIdentityExchangePayload)
    case heartbeat(HeartbeatPayload)
    /// Lightweight RTT probe (request).
    case ping(PingPayload)
    /// Lightweight RTT probe (response).
    case pong(PongPayload)

    public struct ClipboardPayload: Codable, Sendable, Equatable {
        public let mimeType: String
        public let dataBase64: String
        public let sentAt: Date

        public init(mimeType: String, dataBase64: String, sentAt: Date = Date()) {
            self.mimeType = mimeType
            self.dataBase64 = dataBase64
            self.sentAt = sentAt
        }

        public var decodedData: Data? {
            Data(base64Encoded: dataBase64)
        }
    }

    /// Minimal identity bundle used to bootstrap PQC handshake:
    /// - provides peer KEM identity public keys (suiteWireId -> publicKey)
    /// - provides stable deviceId for trust store indexing
    public struct PairingIdentityExchangePayload: Codable, Sendable, Equatable {
        public let deviceId: String
        public let kemPublicKeys: [KEMPublicKeyInfo]
        /// Optional UI metadata (best-effort). Used to populate “Trusted Devices” UI and approval prompts.
        public let deviceName: String?
        public let modelName: String?
        public let platform: String?
        public let osVersion: String?
        public let chip: String?
        public let sentAt: Date

        public init(
            deviceId: String,
            kemPublicKeys: [KEMPublicKeyInfo],
            deviceName: String? = nil,
            modelName: String? = nil,
            platform: String? = nil,
            osVersion: String? = nil,
            chip: String? = nil,
            sentAt: Date = Date()
        ) {
            self.deviceId = deviceId
            self.kemPublicKeys = kemPublicKeys
            self.deviceName = deviceName
            self.modelName = modelName
            self.platform = platform
            self.osVersion = osVersion
            self.chip = chip
            self.sentAt = sentAt
        }
    }

    public struct HeartbeatPayload: Codable, Sendable, Equatable {
        public let sentAt: Date
        /// Optional identity metadata (best-effort). Backwards compatible: older builds ignore new fields.
        public let deviceId: String?
        public let deviceName: String?
        public let modelName: String?
        public let platform: String?
        public let osVersion: String?
        public let chip: String?

        public init(
            sentAt: Date = Date(),
            deviceId: String? = nil,
            deviceName: String? = nil,
            modelName: String? = nil,
            platform: String? = nil,
            osVersion: String? = nil,
            chip: String? = nil
        ) {
            self.sentAt = sentAt
            self.deviceId = deviceId
            self.deviceName = deviceName
            self.modelName = modelName
            self.platform = platform
            self.osVersion = osVersion
            self.chip = chip
        }
    }

    /// Ping request payload. Receiver should respond with `pong(id:)` as fast as possible.
    public struct PingPayload: Codable, Sendable, Equatable {
        public let id: UInt64

        public init(id: UInt64) {
            self.id = id
        }
    }

    /// Pong response payload (echoes `PingPayload.id`).
    public struct PongPayload: Codable, Sendable, Equatable {
        public let id: UInt64

        public init(id: UInt64) {
            self.id = id
        }
    }
}
