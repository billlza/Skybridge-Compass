import Foundation

/// App-level encrypted message sent over an established P2P session (after handshake).
/// This is distinct from handshake frames.
@available(macOS 14.0, iOS 17.0, *)
public enum AppMessage: Codable, Sendable, Equatable {
    case clipboard(ClipboardPayload)
    case pairingIdentityExchange(PairingIdentityExchangePayload)
    case heartbeat(HeartbeatPayload)
    case peerDisconnecting(PeerDisconnectingPayload)
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
        public let protocolIdentityPublicKeys: [ProtocolIdentityPublicKeyInfo]?
        /// Optional UI metadata (best-effort). Used to populate “Trusted Devices” UI and approval prompts.
        public let deviceName: String?
        public let modelName: String?
        public let platform: String?
        public let osVersion: String?
        public let chip: String?
        public let remoteVideoFormats: [String]?
        public let capabilities: [String]?
        public let fileTransferPort: UInt16?
        public let remoteControlPort: UInt16?
        public let sentAt: Date

        public init(
            deviceId: String,
            kemPublicKeys: [KEMPublicKeyInfo],
            protocolIdentityPublicKeys: [ProtocolIdentityPublicKeyInfo]? = nil,
            deviceName: String? = nil,
            modelName: String? = nil,
            platform: String? = nil,
            osVersion: String? = nil,
            chip: String? = nil,
            remoteVideoFormats: [String]? = nil,
            capabilities: [String]? = nil,
            fileTransferPort: UInt16? = nil,
            remoteControlPort: UInt16? = nil,
            sentAt: Date = Date()
        ) {
            self.deviceId = deviceId
            self.kemPublicKeys = kemPublicKeys
            self.protocolIdentityPublicKeys = ProtocolIdentityPublicKeyInfo.normalizedValidKeys(protocolIdentityPublicKeys)
            self.deviceName = deviceName
            self.modelName = modelName
            self.platform = platform
            self.osVersion = osVersion
            self.chip = chip
            self.remoteVideoFormats = remoteVideoFormats
            self.capabilities = capabilities
            self.fileTransferPort = fileTransferPort
            self.remoteControlPort = remoteControlPort
            self.sentAt = sentAt
        }

        public var normalizedBootstrapPayload: PairingIdentityExchangePayload? {
            let trimmedDeviceId = deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedDeviceId.isEmpty else { return nil }
            let validKEMKeys = KEMPublicKeyInfo.normalizedValidKeys(kemPublicKeys)
            guard !validKEMKeys.isEmpty else { return nil }
            return .init(
                deviceId: trimmedDeviceId,
                kemPublicKeys: validKEMKeys,
                protocolIdentityPublicKeys: ProtocolIdentityPublicKeyInfo.normalizedValidKeys(protocolIdentityPublicKeys),
                deviceName: deviceName,
                modelName: modelName,
                platform: platform,
                osVersion: osVersion,
                chip: chip,
                remoteVideoFormats: remoteVideoFormats,
                capabilities: capabilities,
                fileTransferPort: fileTransferPort,
                remoteControlPort: remoteControlPort,
                sentAt: sentAt
            )
        }
    }

    public struct ProtocolIdentityPublicKeyInfo: Codable, Sendable, Equatable {
        public let protocolSigningAlgorithm: String
        public let publicKey: Data

        public init(protocolSigningAlgorithm: String, publicKey: Data) {
            self.protocolSigningAlgorithm = protocolSigningAlgorithm
            self.publicKey = publicKey
        }

        public var normalizedAlgorithm: ProtocolSigningAlgorithm? {
            let raw = protocolSigningAlgorithm.trimmingCharacters(in: .whitespacesAndNewlines)
            return ProtocolSigningAlgorithm(rawValue: raw)
        }

        public var authoritativeFingerprint: String? {
            guard let algorithm = normalizedAlgorithm, !publicKey.isEmpty else { return nil }
            return ProtocolIdentityPublicKeys(
                protocolPublicKey: publicKey,
                protocolAlgorithm: algorithm
            ).authoritativeFingerprint.lowercased()
        }

        public static func normalizedValidKeys(_ rawKeys: [ProtocolIdentityPublicKeyInfo]?) -> [ProtocolIdentityPublicKeyInfo]? {
            var byFingerprint: [String: ProtocolIdentityPublicKeyInfo] = [:]
            for key in rawKeys ?? [] {
                guard let algorithm = key.normalizedAlgorithm,
                      let fingerprint = key.authoritativeFingerprint,
                      !fingerprint.isEmpty else {
                    continue
                }
                byFingerprint[fingerprint] = ProtocolIdentityPublicKeyInfo(
                    protocolSigningAlgorithm: algorithm.rawValue,
                    publicKey: key.publicKey
                )
            }
            guard !byFingerprint.isEmpty else { return nil }
            return byFingerprint.keys.sorted().compactMap { byFingerprint[$0] }
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
        public let capabilities: [String]?
        public let fileTransferPort: UInt16?
        public let remoteControlPort: UInt16?
        public let webrtcMedia: WebRTCMediaHeartbeatDiagnostics?

        public init(
            sentAt: Date = Date(),
            deviceId: String? = nil,
            deviceName: String? = nil,
            modelName: String? = nil,
            platform: String? = nil,
            osVersion: String? = nil,
            chip: String? = nil,
            remoteVideoFormats: [String]? = nil,
            capabilities: [String]? = nil,
            fileTransferPort: UInt16? = nil,
            remoteControlPort: UInt16? = nil,
            webrtcMedia: WebRTCMediaHeartbeatDiagnostics? = nil
        ) {
            self.sentAt = sentAt
            self.deviceId = deviceId
            self.deviceName = deviceName
            self.modelName = modelName
            self.platform = platform
            self.osVersion = osVersion
            self.chip = chip
            self.remoteVideoFormats = remoteVideoFormats
            self.capabilities = capabilities
            self.fileTransferPort = fileTransferPort
            self.remoteControlPort = remoteControlPort
            self.webrtcMedia = webrtcMedia
        }
    }

    public struct WebRTCMediaHeartbeatDiagnostics: Codable, Sendable, Equatable {
        public let nativeVideoRendered: Bool
        public let nativeVideoWidth: Int?
        public let nativeVideoHeight: Int?
        public let audioRxDatagrams: UInt64?
        public let audioRxRecv: UInt64?
        public let audioRxDecoded: UInt64?
        public let audioRxPlayed: UInt64?
        public let audioRxRejected: UInt64?
        public let audioRxAuthRejected: UInt64?
        public let audioRxSessionHashRejected: UInt64?
        public let audioRxReplayRejected: UInt64?
        public let audioRxJitterEvicted: UInt64?
        public let audioRxPlaybackDropped: UInt64?
        public let audioRenderedFrames: UInt64?
        public let audioUnderflow: UInt64?
        public let audioRebuffer: UInt64?
        public let audioStartupSilenceFrames: UInt64?
        public let audioEngineRunning: Bool?

        public init(
            nativeVideoRendered: Bool,
            nativeVideoWidth: Int? = nil,
            nativeVideoHeight: Int? = nil,
            audioRxDatagrams: UInt64? = nil,
            audioRxRecv: UInt64? = nil,
            audioRxDecoded: UInt64? = nil,
            audioRxPlayed: UInt64? = nil,
            audioRxRejected: UInt64? = nil,
            audioRxAuthRejected: UInt64? = nil,
            audioRxSessionHashRejected: UInt64? = nil,
            audioRxReplayRejected: UInt64? = nil,
            audioRxJitterEvicted: UInt64? = nil,
            audioRxPlaybackDropped: UInt64? = nil,
            audioRenderedFrames: UInt64? = nil,
            audioUnderflow: UInt64? = nil,
            audioRebuffer: UInt64? = nil,
            audioStartupSilenceFrames: UInt64? = nil,
            audioEngineRunning: Bool? = nil
        ) {
            self.nativeVideoRendered = nativeVideoRendered
            self.nativeVideoWidth = nativeVideoWidth
            self.nativeVideoHeight = nativeVideoHeight
            self.audioRxDatagrams = audioRxDatagrams
            self.audioRxRecv = audioRxRecv
            self.audioRxDecoded = audioRxDecoded
            self.audioRxPlayed = audioRxPlayed
            self.audioRxRejected = audioRxRejected
            self.audioRxAuthRejected = audioRxAuthRejected
            self.audioRxSessionHashRejected = audioRxSessionHashRejected
            self.audioRxReplayRejected = audioRxReplayRejected
            self.audioRxJitterEvicted = audioRxJitterEvicted
            self.audioRxPlaybackDropped = audioRxPlaybackDropped
            self.audioRenderedFrames = audioRenderedFrames
            self.audioUnderflow = audioUnderflow
            self.audioRebuffer = audioRebuffer
            self.audioStartupSilenceFrames = audioStartupSilenceFrames
            self.audioEngineRunning = audioEngineRunning
        }
    }

    public struct PeerDisconnectingPayload: Codable, Sendable, Equatable {
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
        case peerDisconnecting
        case ping
        case pong
    }

    private struct LegacyAssociatedValueBox<Value: Decodable>: Decodable {
        let _0: Value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let payload = try? container.decode(ClipboardPayload.self, forKey: .clipboard) {
            self = .clipboard(payload)
            return
        }
        if let payload = try? container.decode(PairingIdentityExchangePayload.self, forKey: .pairingIdentityExchange) {
            self = .pairingIdentityExchange(payload)
            return
        }
        if let payload = try? container.decode(HeartbeatPayload.self, forKey: .heartbeat) {
            self = .heartbeat(payload)
            return
        }
        if let payload = try? container.decode(PeerDisconnectingPayload.self, forKey: .peerDisconnecting) {
            self = .peerDisconnecting(payload)
            return
        }
        if let payload = try? container.decode(PingPayload.self, forKey: .ping) {
            self = .ping(payload)
            return
        }
        if let payload = try? container.decode(PongPayload.self, forKey: .pong) {
            self = .pong(payload)
            return
        }

        if let payload = (try? container.decode(LegacyAssociatedValueBox<ClipboardPayload>.self, forKey: .clipboard))?._0 {
            self = .clipboard(payload)
            return
        }
        if let payload = (try? container.decode(LegacyAssociatedValueBox<PairingIdentityExchangePayload>.self, forKey: .pairingIdentityExchange))?._0 {
            self = .pairingIdentityExchange(payload)
            return
        }
        if let payload = (try? container.decode(LegacyAssociatedValueBox<HeartbeatPayload>.self, forKey: .heartbeat))?._0 {
            self = .heartbeat(payload)
            return
        }
        if let payload = (try? container.decode(LegacyAssociatedValueBox<PeerDisconnectingPayload>.self, forKey: .peerDisconnecting))?._0 {
            self = .peerDisconnecting(payload)
            return
        }
        if let payload = (try? container.decode(LegacyAssociatedValueBox<PingPayload>.self, forKey: .ping))?._0 {
            self = .ping(payload)
            return
        }
        if let payload = (try? container.decode(LegacyAssociatedValueBox<PongPayload>.self, forKey: .pong))?._0 {
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
        case .peerDisconnecting(let payload):
            try container.encode(payload, forKey: .peerDisconnecting)
        case .ping(let payload):
            try container.encode(payload, forKey: .ping)
        case .pong(let payload):
            try container.encode(payload, forKey: .pong)
        }
    }
}
