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
        public let remoteVideoFormats: [String]?
        public let sentAt: Date

        public init(
            deviceId: String,
            kemPublicKeys: [KEMPublicKeyInfo],
            deviceName: String? = nil,
            modelName: String? = nil,
            platform: String? = nil,
            osVersion: String? = nil,
            chip: String? = nil,
            remoteVideoFormats: [String]? = nil,
            sentAt: Date = Date()
        ) {
            self.deviceId = deviceId
            self.kemPublicKeys = kemPublicKeys
            self.deviceName = deviceName
            self.modelName = modelName
            self.platform = platform
            self.osVersion = osVersion
            self.chip = chip
            self.remoteVideoFormats = remoteVideoFormats
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
        public let remoteVideoFormats: [String]?

        public init(
            sentAt: Date = Date(),
            deviceId: String? = nil,
            deviceName: String? = nil,
            modelName: String? = nil,
            platform: String? = nil,
            osVersion: String? = nil,
            chip: String? = nil,
            remoteVideoFormats: [String]? = nil
        ) {
            self.sentAt = sentAt
            self.deviceId = deviceId
            self.deviceName = deviceName
            self.modelName = modelName
            self.platform = platform
            self.osVersion = osVersion
            self.chip = chip
            self.remoteVideoFormats = remoteVideoFormats
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

    private enum CodingKeys: String, CodingKey {
        case clipboard
        case pairingIdentityExchange
        case heartbeat
        case ping
        case pong
    }

    private struct LegacyAssociatedValueBox<Value: Decodable>: Decodable {
        let _0: Value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let payload = try container.decodeIfPresent(ClipboardPayload.self, forKey: .clipboard) {
            self = .clipboard(payload)
            return
        }
        if let payload = try container.decodeIfPresent(PairingIdentityExchangePayload.self, forKey: .pairingIdentityExchange) {
            self = .pairingIdentityExchange(payload)
            return
        }
        if let payload = try container.decodeIfPresent(HeartbeatPayload.self, forKey: .heartbeat) {
            self = .heartbeat(payload)
            return
        }
        if let payload = try container.decodeIfPresent(PingPayload.self, forKey: .ping) {
            self = .ping(payload)
            return
        }
        if let payload = try container.decodeIfPresent(PongPayload.self, forKey: .pong) {
            self = .pong(payload)
            return
        }

        if let payload = try container.decodeIfPresent(LegacyAssociatedValueBox<ClipboardPayload>.self, forKey: .clipboard)?._0 {
            self = .clipboard(payload)
            return
        }
        if let payload = try container.decodeIfPresent(LegacyAssociatedValueBox<PairingIdentityExchangePayload>.self, forKey: .pairingIdentityExchange)?._0 {
            self = .pairingIdentityExchange(payload)
            return
        }
        if let payload = try container.decodeIfPresent(LegacyAssociatedValueBox<HeartbeatPayload>.self, forKey: .heartbeat)?._0 {
            self = .heartbeat(payload)
            return
        }
        if let payload = try container.decodeIfPresent(LegacyAssociatedValueBox<PingPayload>.self, forKey: .ping)?._0 {
            self = .ping(payload)
            return
        }
        if let payload = try container.decodeIfPresent(LegacyAssociatedValueBox<PongPayload>.self, forKey: .pong)?._0 {
            self = .pong(payload)
            return
        }

        throw DecodingError.dataCorrupted(
            .init(
                codingPath: decoder.codingPath,
                debugDescription: "Unsupported AppMessage payload"
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .clipboard(let payload):
            try container.encode(payload, forKey: .clipboard)
        case .pairingIdentityExchange(let payload):
            try container.encode(payload, forKey: .pairingIdentityExchange)
        case .heartbeat(let payload):
            try container.encode(payload, forKey: .heartbeat)
        case .ping(let payload):
            try container.encode(payload, forKey: .ping)
        case .pong(let payload):
            try container.encode(payload, forKey: .pong)
        }
    }
}
