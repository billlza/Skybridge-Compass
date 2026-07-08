import CryptoKit
import Foundation

public struct WebRTCMediaDiagnosticEvent: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let timestamp: String
    public let sessionId: String
    public let kind: String
    public let probable: String?
    public let videoFPS: Double?
    public let fallbackProducer: String?
    public let nativeVideoHealth: String?
    public let screenBuffered: Int?
    public let submitted: UInt64?
    public let framesEncoded: UInt64?
    public let framesSent: UInt64?
    public let keyFramesEncoded: UInt64?
    public let packetsSent: UInt64?
    public let bytesSent: UInt64?
    public let codec: String?
    public let encoder: String?
    public let qualityLimit: String?
    public let encodeWidth: UInt64?
    public let encodeHeight: UInt64?
    public let encodeFPS: UInt64?
    public let totalEncodeTime: Double?
    public let targetBitrate: UInt64?
    public let availableOutgoingBitrate: UInt64?
    public let currentRTT: Double?
    public let remoteRTT: Double?
    public let remotePacketsLost: Int64?
    public let remoteJitter: Double?
    public let nack: UInt64?
    public let pli: UInt64?
    public let fir: UInt64?
    public let audioTxCaptured: UInt64?
    public let audioTxEncoded: UInt64?
    public let audioTxSent: UInt64?
    public let audioDrops: UInt64?
    public let audioTxCapturedTotal: UInt64?
    public let audioTxEncodedTotal: UInt64?
    public let audioTxSentTotal: UInt64?
    public let audioDropsTotal: UInt64?
    public let audioRxRecv: UInt64?
    public let audioRxDecoded: UInt64?
    public let audioRxPlayed: UInt64?
    public let audioRxRejected: UInt64?
    public let engineRunning: Bool?
    public let renderedFrames: UInt64?
    public let underflow: UInt64?
    public let startupSilenceFrames: UInt64?
    public let sckCaptured: UInt64?
    public let sckMeaningful: UInt64?
    public let sckEncoded: UInt64?
    public let sckEncodedBytes: UInt64?
    public let sckCaptureFPS: Double?
    public let sckMeaningfulFPS: Double?
    public let sckEncodedFPS: Double?
    public let sckTargetFPS: UInt64?
    public let sckWidth: UInt64?
    public let sckHeight: UInt64?
    public let sckCapturesAudio: Bool?
    public let sckEncodeLatencyP50Ms: Double?
    public let sckEncodeLatencyP95Ms: Double?
    public let sckEncodeLatencyMaxMs: Double?
    public let sckEncodeFailures: UInt64?
    public let validationMode: String?
    public let failureReason: String?

    public init(
        timestamp: Date = Date(),
        sessionId: String,
        kind: String,
        probable: String? = nil,
        videoFPS: Double? = nil,
        fallbackProducer: String? = nil,
        nativeVideoHealth: String? = nil,
        screenBuffered: Int? = nil,
        submitted: UInt64? = nil,
        framesEncoded: UInt64? = nil,
        framesSent: UInt64? = nil,
        keyFramesEncoded: UInt64? = nil,
        packetsSent: UInt64? = nil,
        bytesSent: UInt64? = nil,
        codec: String? = nil,
        encoder: String? = nil,
        qualityLimit: String? = nil,
        encodeWidth: UInt64? = nil,
        encodeHeight: UInt64? = nil,
        encodeFPS: UInt64? = nil,
        totalEncodeTime: Double? = nil,
        targetBitrate: UInt64? = nil,
        availableOutgoingBitrate: UInt64? = nil,
        currentRTT: Double? = nil,
        remoteRTT: Double? = nil,
        remotePacketsLost: Int64? = nil,
        remoteJitter: Double? = nil,
        nack: UInt64? = nil,
        pli: UInt64? = nil,
        fir: UInt64? = nil,
        audioTxCaptured: UInt64? = nil,
        audioTxEncoded: UInt64? = nil,
        audioTxSent: UInt64? = nil,
        audioDrops: UInt64? = nil,
        audioTxCapturedTotal: UInt64? = nil,
        audioTxEncodedTotal: UInt64? = nil,
        audioTxSentTotal: UInt64? = nil,
        audioDropsTotal: UInt64? = nil,
        audioRxRecv: UInt64? = nil,
        audioRxDecoded: UInt64? = nil,
        audioRxPlayed: UInt64? = nil,
        audioRxRejected: UInt64? = nil,
        engineRunning: Bool? = nil,
        renderedFrames: UInt64? = nil,
        underflow: UInt64? = nil,
        startupSilenceFrames: UInt64? = nil,
        sckCaptured: UInt64? = nil,
        sckMeaningful: UInt64? = nil,
        sckEncoded: UInt64? = nil,
        sckEncodedBytes: UInt64? = nil,
        sckCaptureFPS: Double? = nil,
        sckMeaningfulFPS: Double? = nil,
        sckEncodedFPS: Double? = nil,
        sckTargetFPS: UInt64? = nil,
        sckWidth: UInt64? = nil,
        sckHeight: UInt64? = nil,
        sckCapturesAudio: Bool? = nil,
        sckEncodeLatencyP50Ms: Double? = nil,
        sckEncodeLatencyP95Ms: Double? = nil,
        sckEncodeLatencyMaxMs: Double? = nil,
        sckEncodeFailures: UInt64? = nil,
        validationMode: String? = nil,
        failureReason: String? = nil
    ) {
        self.schemaVersion = 1
        self.timestamp = ISO8601DateFormatter().string(from: timestamp)
        self.sessionId = sessionId
        self.kind = kind
        self.probable = probable
        self.videoFPS = videoFPS
        self.fallbackProducer = fallbackProducer
        self.nativeVideoHealth = nativeVideoHealth
        self.screenBuffered = screenBuffered
        self.submitted = submitted
        self.framesEncoded = framesEncoded
        self.framesSent = framesSent
        self.keyFramesEncoded = keyFramesEncoded
        self.packetsSent = packetsSent
        self.bytesSent = bytesSent
        self.codec = codec
        self.encoder = encoder
        self.qualityLimit = qualityLimit
        self.encodeWidth = encodeWidth
        self.encodeHeight = encodeHeight
        self.encodeFPS = encodeFPS
        self.totalEncodeTime = totalEncodeTime
        self.targetBitrate = targetBitrate
        self.availableOutgoingBitrate = availableOutgoingBitrate
        self.currentRTT = currentRTT
        self.remoteRTT = remoteRTT
        self.remotePacketsLost = remotePacketsLost
        self.remoteJitter = remoteJitter
        self.nack = nack
        self.pli = pli
        self.fir = fir
        self.audioTxCaptured = audioTxCaptured
        self.audioTxEncoded = audioTxEncoded
        self.audioTxSent = audioTxSent
        self.audioDrops = audioDrops
        self.audioTxCapturedTotal = audioTxCapturedTotal
        self.audioTxEncodedTotal = audioTxEncodedTotal
        self.audioTxSentTotal = audioTxSentTotal
        self.audioDropsTotal = audioDropsTotal
        self.audioRxRecv = audioRxRecv
        self.audioRxDecoded = audioRxDecoded
        self.audioRxPlayed = audioRxPlayed
        self.audioRxRejected = audioRxRejected
        self.engineRunning = engineRunning
        self.renderedFrames = renderedFrames
        self.underflow = underflow
        self.startupSilenceFrames = startupSilenceFrames
        self.sckCaptured = sckCaptured
        self.sckMeaningful = sckMeaningful
        self.sckEncoded = sckEncoded
        self.sckEncodedBytes = sckEncodedBytes
        self.sckCaptureFPS = sckCaptureFPS
        self.sckMeaningfulFPS = sckMeaningfulFPS
        self.sckEncodedFPS = sckEncodedFPS
        self.sckTargetFPS = sckTargetFPS
        self.sckWidth = sckWidth
        self.sckHeight = sckHeight
        self.sckCapturesAudio = sckCapturesAudio
        self.sckEncodeLatencyP50Ms = sckEncodeLatencyP50Ms
        self.sckEncodeLatencyP95Ms = sckEncodeLatencyP95Ms
        self.sckEncodeLatencyMaxMs = sckEncodeLatencyMaxMs
        self.sckEncodeFailures = sckEncodeFailures
        self.validationMode = validationMode
        self.failureReason = failureReason
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case timestamp
        case sessionId = "session_id"
        case kind
        case probable
        case videoFPS = "video_fps"
        case fallbackProducer
        case nativeVideoHealth
        case screenBuffered
        case submitted
        case framesEncoded
        case framesSent
        case keyFramesEncoded
        case packetsSent
        case bytesSent
        case codec
        case encoder
        case qualityLimit
        case encodeWidth
        case encodeHeight
        case encodeFPS
        case totalEncodeTime
        case targetBitrate
        case availableOutgoingBitrate
        case currentRTT
        case remoteRTT
        case remotePacketsLost
        case remoteJitter
        case nack
        case pli
        case fir
        case audioTxCaptured
        case audioTxEncoded
        case audioTxSent
        case audioDrops
        case audioTxCapturedTotal
        case audioTxEncodedTotal
        case audioTxSentTotal
        case audioDropsTotal
        case audioRxRecv
        case audioRxDecoded
        case audioRxPlayed
        case audioRxRejected
        case engineRunning
        case renderedFrames
        case underflow
        case startupSilenceFrames
        case sckCaptured
        case sckMeaningful
        case sckEncoded
        case sckEncodedBytes
        case sckCaptureFPS
        case sckMeaningfulFPS
        case sckEncodedFPS
        case sckTargetFPS
        case sckWidth
        case sckHeight
        case sckCapturesAudio
        case sckEncodeLatencyP50Ms
        case sckEncodeLatencyP95Ms
        case sckEncodeLatencyMaxMs
        case sckEncodeFailures
        case validationMode
        case failureReason
    }
}

public enum WebRTCMediaDiagnosticWriter {
    public static func append(_ event: WebRTCMediaDiagnosticEvent) {
#if os(macOS)
        let safeSessionRef = safeSessionReference(event.sessionId)
        let logsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("SkyBridge", isDirectory: true)
        let logURL = logsDirectory.appendingPathComponent("webrtc-media-\(safeSessionRef).jsonl")
        guard let encoded = publicDiagnosticJSONData(for: event) else { return }
        var line = encoded
        line.append(0x0a)
        try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: logURL.path),
           let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: logURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: logURL.path
            )
        }
#else
        _ = event
#endif
    }

#if os(macOS)
    private static func safeSessionReference(_ sessionId: String) -> String {
        let value = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return "ref-missing"
        }
        let digest = SHA256.hash(data: Data(value.utf8))
        let prefix = digest.prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        return "ref-\(prefix)"
    }

    private static func publicDiagnosticJSONData(for event: WebRTCMediaDiagnosticEvent) -> Data? {
        guard let encoded = try? JSONEncoder().encode(event),
              let jsonObject = try? JSONSerialization.jsonObject(with: encoded),
              var payload = jsonObject as? [String: Any] else {
            return nil
        }
        payload.removeValue(forKey: "session_id")
        payload["session_ref"] = safeSessionReference(event.sessionId)
        guard JSONSerialization.isValidJSONObject(payload) else {
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }
#endif
}

public struct RealtimeMediaAudioSenderDiagnosticSnapshot: Codable, Equatable, Sendable {
    public let capturedPackets: UInt64
    public let encodedPackets: UInt64
    public let sentPackets: UInt64
    public let droppedPackets: UInt64
    public let invalidDroppedPackets: UInt64
    public let overflowDroppedPackets: UInt64
    public let staleDroppedPackets: UInt64
    public let sendFailedPackets: UInt64
    public let emptyPacingTicks: UInt64
    public let queuedFrames: Int
    public let queuedMs: Int
    public let mode: String
}

public struct RealtimeMediaAudioReceiverDiagnosticSnapshot: Codable, Equatable, Sendable {
    public let receivedPackets: UInt64
    public let decodedPackets: UInt64
    public let playedPackets: UInt64
    public let rejectedPackets: UInt64
    public let plcFrames: UInt64
    public let mode: String
}
