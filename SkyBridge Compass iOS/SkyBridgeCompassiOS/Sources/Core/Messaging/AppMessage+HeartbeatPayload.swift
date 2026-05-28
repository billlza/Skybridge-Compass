import Foundation

@available(iOS 17.0, *)
public extension AppMessage {
    struct HeartbeatPayload: Codable, Sendable, Equatable {
        public let sentAt: Date
        /// Optional identity metadata (best-effort). Backwards compatible: older builds ignore new fields.
        public let deviceId: String?
        public let deviceName: String?
        public let modelName: String?
        public let platform: String?
        public let osVersion: String?
        public let chip: String?
        public let accountDisplayName: String?
        public let nebulaId: String?
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
            accountDisplayName: String? = nil,
            nebulaId: String? = nil,
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
            self.accountDisplayName = accountDisplayName
            self.nebulaId = nebulaId
            self.remoteVideoFormats = remoteVideoFormats
            self.capabilities = capabilities
            self.fileTransferPort = fileTransferPort
            self.remoteControlPort = remoteControlPort
            self.webrtcMedia = webrtcMedia
        }
    }

    struct WebRTCMediaHeartbeatDiagnostics: Codable, Sendable, Equatable {
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
}
