import Foundation

public enum SkyBridgeRealtimeMediaConstants {
    public static let audioTransportPQCv1 = "pqc-media-v1"
    public static let audioTransportLegacyChunkV1 = "legacy-chunk-v1"
    public static let audioTransportDisabled = "disabled"
    public static let defaultStreamId: UInt32 = 1
}

public enum SkyBridgeMediaAudioMode: String, Codable, CaseIterable, Sendable {
    case lowLatency = "low-latency"
    case highFidelity = "high-fidelity"
}

public struct SkyBridgeMediaAudioProfile: Codable, Equatable, Sendable {
    public let sampleRate: Int
    public let channels: Int
    public let frameDurationMs: Int
    public let minBitrate: Int
    public let targetBitrate: Int
    public let maxBitrate: Int
    public let jitterTargetMs: Int
    public let jitterMaxMs: Int
    public let opusComplexity: Int
    public let inBandFECEnabled: Bool

    public init(
        sampleRate: Int = 48_000,
        channels: Int = 2,
        frameDurationMs: Int = 20,
        minBitrate: Int,
        targetBitrate: Int,
        maxBitrate: Int,
        jitterTargetMs: Int,
        jitterMaxMs: Int,
        opusComplexity: Int,
        inBandFECEnabled: Bool = true
    ) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.frameDurationMs = frameDurationMs
        self.minBitrate = minBitrate
        self.targetBitrate = targetBitrate
        self.maxBitrate = maxBitrate
        self.jitterTargetMs = jitterTargetMs
        self.jitterMaxMs = jitterMaxMs
        self.opusComplexity = opusComplexity
        self.inBandFECEnabled = inBandFECEnabled
    }

    public static func profile(for mode: SkyBridgeMediaAudioMode) -> SkyBridgeMediaAudioProfile {
        switch mode {
        case .lowLatency:
            return SkyBridgeMediaAudioProfile(
                minBitrate: 96_000,
                targetBitrate: 128_000,
                maxBitrate: 160_000,
                jitterTargetMs: 40,
                jitterMaxMs: 100,
                opusComplexity: 7
            )
        case .highFidelity:
            return SkyBridgeMediaAudioProfile(
                minBitrate: 160_000,
                targetBitrate: 224_000,
                maxBitrate: 256_000,
                jitterTargetMs: 80,
                jitterMaxMs: 180,
                opusComplexity: 10
            )
        }
    }

    public var samplesPerPacket: Int {
        sampleRate * frameDurationMs / 1_000
    }
}

public struct SkyBridgeMediaTelemetrySnapshot: Codable, Equatable, Sendable {
    public var capturedPackets: UInt64
    public var encodedPackets: UInt64
    public var sentPackets: UInt64
    public var relayedPackets: UInt64
    public var receivedPackets: UInt64
    public var decodedPackets: UInt64
    public var playedPackets: UInt64
    public var lostPackets: UInt64
    public var latePackets: UInt64
    public var replayRejectedPackets: UInt64
    public var plcFrames: UInt64
    public var jitterMs: Double
    public var playbackRoute: String

    public init(
        capturedPackets: UInt64 = 0,
        encodedPackets: UInt64 = 0,
        sentPackets: UInt64 = 0,
        relayedPackets: UInt64 = 0,
        receivedPackets: UInt64 = 0,
        decodedPackets: UInt64 = 0,
        playedPackets: UInt64 = 0,
        lostPackets: UInt64 = 0,
        latePackets: UInt64 = 0,
        replayRejectedPackets: UInt64 = 0,
        plcFrames: UInt64 = 0,
        jitterMs: Double = 0,
        playbackRoute: String = "unknown"
    ) {
        self.capturedPackets = capturedPackets
        self.encodedPackets = encodedPackets
        self.sentPackets = sentPackets
        self.relayedPackets = relayedPackets
        self.receivedPackets = receivedPackets
        self.decodedPackets = decodedPackets
        self.playedPackets = playedPackets
        self.lostPackets = lostPackets
        self.latePackets = latePackets
        self.replayRejectedPackets = replayRejectedPackets
        self.plcFrames = plcFrames
        self.jitterMs = jitterMs
        self.playbackRoute = playbackRoute
    }
}
