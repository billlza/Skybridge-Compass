import Foundation

public struct WebRTCSignalingEnvelope: Codable, Sendable, Equatable {
    public enum MessageType: String, Codable, Sendable {
        case join
        case offer
        case answer
        case iceCandidate
        case leave
    }
    
    public let sessionId: String
    public let from: String
    public let to: String?
    public let type: MessageType
    public let payload: Payload?
    public let authToken: String?
    public let sentAt: Double
    
    public init(
        sessionId: String,
        from: String,
        to: String? = nil,
        type: MessageType,
        payload: Payload? = nil,
        authToken: String? = nil,
        sentAt: Double = Date().timeIntervalSince1970
    ) {
        self.sessionId = sessionId
        self.from = from
        self.to = to
        self.type = type
        self.payload = payload
        self.authToken = authToken
        self.sentAt = sentAt
    }
    
    public struct Payload: Codable, Sendable, Equatable {
        /// Strict-PQC bootstrap KEM public key carried in the `.join` envelope.
        ///
        /// Wire-identical to macOS `SkyBridgeProtocolCore`
        /// `WebRTCSignalingEnvelope.Payload.BootstrapKEMPublicKey`:
        /// - `suiteWireId`: `UInt16` (plain integer in JSON)
        /// - `publicKey`: `Data` (default `JSONEncoder`/`JSONDecoder` → base64 string)
        public struct BootstrapKEMPublicKey: Codable, Sendable, Equatable {
            public let suiteWireId: UInt16
            public let publicKey: Data

            public init(suiteWireId: UInt16, publicKey: Data) {
                self.suiteWireId = suiteWireId
                self.publicKey = publicKey
            }
        }

        public var sdp: String?

        public var candidate: String?
        public var sdpMid: String?
        public var sdpMLineIndex: Int32?

        // MARK: Strict-PQC join bootstrap identity + KEM (Optional → omitted from
        // existing sdp/candidate envelopes so their wire format stays unchanged).
        // CodingKeys/value encodings are byte-identical to macOS protocol-core so its
        // `JSONDecoder` ingests them via `ingestWebRTCJoinBootstrapPayload`.
        public var protocolSigningAlgorithm: ProtocolSigningAlgorithm?
        public var protocolPublicKeyFingerprint: String?
        public var protocolPublicKeyBytes: Data?
        public var kemPublicKeys: [BootstrapKEMPublicKey]?
        public var platform: String?
        public var osVersion: String?

        public init(
            sdp: String? = nil,
            candidate: String? = nil,
            sdpMid: String? = nil,
            sdpMLineIndex: Int32? = nil,
            protocolSigningAlgorithm: ProtocolSigningAlgorithm? = nil,
            protocolPublicKeyFingerprint: String? = nil,
            protocolPublicKeyBytes: Data? = nil,
            kemPublicKeys: [BootstrapKEMPublicKey]? = nil,
            platform: String? = nil,
            osVersion: String? = nil
        ) {
            self.sdp = sdp
            self.candidate = candidate
            self.sdpMid = sdpMid
            self.sdpMLineIndex = sdpMLineIndex
            self.protocolSigningAlgorithm = protocolSigningAlgorithm
            self.protocolPublicKeyFingerprint = protocolPublicKeyFingerprint
            self.protocolPublicKeyBytes = protocolPublicKeyBytes
            self.kemPublicKeys = kemPublicKeys
            self.platform = platform
            self.osVersion = osVersion
        }
    }
}
