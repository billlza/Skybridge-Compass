import Foundation
import SkyBridgeProtocolCore
import SkyBridgeRealtimeMedia

struct RemoteClipboardMessagePayload: Codable, Sendable, Equatable {
    let mimeType: String
    let data: Data
    let sentAt: TimeInterval

    init(
        mimeType: String,
        data: Data,
        sentAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.mimeType = mimeType
        self.data = data
        self.sentAt = sentAt
    }
}

struct RemoteDesktopAudioChunkPayload: Codable, Sendable, Equatable {
    enum Encoding: String, Codable, Sendable {
        case pcmS16LE = "pcm_s16le"
        case aacLC = "aac_lc"
    }

    struct PacketDescription: Codable, Sendable, Equatable {
        let startOffset: Int
        let variableFramesInPacket: UInt32
        let dataByteSize: UInt32
    }

    let encoding: Encoding
    let sampleRate: Int
    let channelCount: Int
    let frameCount: Int
    let packetCount: Int?
    let packetDescriptions: [PacketDescription]?
    let magicCookie: Data?
    let sequenceNumber: UInt64
    let sentAt: TimeInterval
    let data: Data

    init(
        encoding: Encoding = .pcmS16LE,
        sampleRate: Int,
        channelCount: Int,
        frameCount: Int,
        packetCount: Int? = nil,
        packetDescriptions: [PacketDescription]? = nil,
        magicCookie: Data? = nil,
        sequenceNumber: UInt64,
        sentAt: TimeInterval = Date().timeIntervalSince1970,
        data: Data
    ) {
        self.encoding = encoding
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.frameCount = frameCount
        self.packetCount = packetCount
        self.packetDescriptions = packetDescriptions
        self.magicCookie = magicCookie
        self.sequenceNumber = sequenceNumber
        self.sentAt = sentAt
        self.data = data
    }
}

enum RemoteDesktopAudioChunkWire {
    private static let magic: UInt32 = 0x53425241 // "SBRA"
    private static let version: UInt8 = 2
    private static let version1HeaderSize = 36
    private static let headerSize = 48
    private static let packetDescriptionSize = 12

    private enum EncodingTag: UInt8 {
        case pcmS16LE = 1
        case aacLC = 2

        init?(encoding: RemoteDesktopAudioChunkPayload.Encoding) {
            switch encoding {
            case .pcmS16LE:
                self = .pcmS16LE
            case .aacLC:
                self = .aacLC
            }
        }

        var encoding: RemoteDesktopAudioChunkPayload.Encoding {
            switch self {
            case .pcmS16LE:
                return .pcmS16LE
            case .aacLC:
                return .aacLC
            }
        }
    }

    static func decodeIfPresent(_ data: Data) -> RemoteDesktopAudioChunkPayload? {
        guard data.count >= version1HeaderSize else { return nil }
        guard readUInt32(from: data, offset: 0) == magic else { return nil }
        switch byte(in: data, at: 4) {
        case 1:
            return decodeVersion1(data)
        case version:
            return decodeVersion2(data)
        default:
            return nil
        }
    }

    private static func decodeVersion1(_ data: Data) -> RemoteDesktopAudioChunkPayload? {
        guard data.count >= version1HeaderSize else { return nil }
        guard let encodingTag = EncodingTag(rawValue: byte(in: data, at: 5)) else { return nil }

        let channelCount = Int(byte(in: data, at: 6))
        let sampleRate = Int(readUInt32(from: data, offset: 8))
        let frameCount = Int(readUInt32(from: data, offset: 12))
        let sequenceNumber = readUInt64(from: data, offset: 16)
        let timestampMicros = readUInt64(from: data, offset: 24)
        let payloadLength = Int(readUInt32(from: data, offset: 32))

        guard channelCount > 0, sampleRate > 0, frameCount > 0 else { return nil }
        guard payloadLength >= 0, data.count == version1HeaderSize + payloadLength else { return nil }

        return RemoteDesktopAudioChunkPayload(
            encoding: encodingTag.encoding,
            sampleRate: sampleRate,
            channelCount: channelCount,
            frameCount: frameCount,
            sequenceNumber: sequenceNumber,
            sentAt: TimeInterval(timestampMicros) / 1_000_000.0,
            data: subdata(in: data, offsetRange: version1HeaderSize..<data.count)
        )
    }

    private static func decodeVersion2(_ data: Data) -> RemoteDesktopAudioChunkPayload? {
        guard data.count >= headerSize else { return nil }
        guard let encodingTag = EncodingTag(rawValue: byte(in: data, at: 5)) else { return nil }

        let channelCount = Int(byte(in: data, at: 6))
        let sampleRate = Int(readUInt32(from: data, offset: 8))
        let frameCount = Int(readUInt32(from: data, offset: 12))
        let packetCount = Int(readUInt32(from: data, offset: 16))
        let sequenceNumber = readUInt64(from: data, offset: 20)
        let timestampMicros = readUInt64(from: data, offset: 28)
        let magicCookieLength = Int(readUInt32(from: data, offset: 36))
        let packetDescriptionCount = Int(readUInt32(from: data, offset: 40))
        let payloadLength = Int(readUInt32(from: data, offset: 44))

        guard channelCount > 0, sampleRate > 0, frameCount > 0 else { return nil }
        guard magicCookieLength >= 0, packetDescriptionCount >= 0, payloadLength >= 0 else { return nil }

        let packetDescriptionsByteLength = packetDescriptionCount * packetDescriptionSize
        let metadataLength = magicCookieLength + packetDescriptionsByteLength
        guard data.count == headerSize + metadataLength + payloadLength else { return nil }

        let magicCookieRange = headerSize..<(headerSize + magicCookieLength)
        let packetDescriptionsStart = magicCookieRange.upperBound
        let packetDescriptionsEnd = packetDescriptionsStart + packetDescriptionsByteLength
        let payloadStart = packetDescriptionsEnd

        let magicCookie = magicCookieLength > 0
            ? subdata(in: data, offsetRange: magicCookieRange)
            : nil
        let packetDescriptions: [RemoteDesktopAudioChunkPayload.PacketDescription]? = {
            guard packetDescriptionCount > 0 else { return nil }
            return (0..<packetDescriptionCount).map { index in
                let offset = packetDescriptionsStart + (index * packetDescriptionSize)
                return RemoteDesktopAudioChunkPayload.PacketDescription(
                    startOffset: Int(readUInt32(from: data, offset: offset)),
                    variableFramesInPacket: readUInt32(from: data, offset: offset + 4),
                    dataByteSize: readUInt32(from: data, offset: offset + 8)
                )
            }
        }()

        return RemoteDesktopAudioChunkPayload(
            encoding: encodingTag.encoding,
            sampleRate: sampleRate,
            channelCount: channelCount,
            frameCount: frameCount,
            packetCount: packetCount > 0 ? packetCount : nil,
            packetDescriptions: packetDescriptions,
            magicCookie: magicCookie,
            sequenceNumber: sequenceNumber,
            sentAt: TimeInterval(timestampMicros) / 1_000_000.0,
            data: subdata(in: data, offsetRange: payloadStart..<(payloadStart + payloadLength))
        )
    }

    private static func readUInt32(from data: Data, offset: Int) -> UInt32 {
        data.withUnsafeBytes { rawBuffer in
            UInt32(
                bigEndian: rawBuffer.loadUnaligned(
                    fromByteOffset: offset,
                    as: UInt32.self
                )
            )
        }
    }

    private static func byte(in data: Data, at offset: Int) -> UInt8 {
        data[data.index(data.startIndex, offsetBy: offset)]
    }

    private static func subdata(in data: Data, offsetRange: Range<Int>) -> Data {
        let lowerBound = data.index(data.startIndex, offsetBy: offsetRange.lowerBound)
        let upperBound = data.index(data.startIndex, offsetBy: offsetRange.upperBound)
        return data.subdata(in: lowerBound..<upperBound)
    }

    private static func readUInt64(from data: Data, offset: Int) -> UInt64 {
        data.withUnsafeBytes { rawBuffer in
            UInt64(
                bigEndian: rawBuffer.loadUnaligned(
                    fromByteOffset: offset,
                    as: UInt64.self
                )
            )
        }
    }
}

struct RemoteDesktopDamageRectPayload: Codable, Sendable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct RemoteDesktopDamageReportPayload: Codable, Sendable, Equatable {
    let rects: [RemoteDesktopDamageRectPayload]
    let fullFrameFallback: Bool
    let sentAt: TimeInterval
}

struct RemoteDesktopCursorPayload: Codable, Sendable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let hotspotX: Double
    let hotspotY: Double
    let hidden: Bool
    let imageData: Data?
    let mimeType: String?
    let sentAt: TimeInterval
}

struct RemoteDesktopOverlayPayload: Codable, Sendable, Equatable {
    let selectionRects: [RemoteDesktopDamageRectPayload]
    let focusRect: RemoteDesktopDamageRectPayload?
    let sentAt: TimeInterval
}

struct RemoteDesktopSecurityIdentityPayload: Codable, Sendable, Equatable {
    let accountDisplayName: String?
    let nebulaId: String?
    let deviceId: String?
    let deviceName: String?

    init(
        accountDisplayName: String? = nil,
        nebulaId: String? = nil,
        deviceId: String? = nil,
        deviceName: String? = nil
    ) {
        self.accountDisplayName = Self.normalized(accountDisplayName)
        self.nebulaId = Self.normalized(nebulaId)
        self.deviceId = Self.normalized(deviceId)
        self.deviceName = Self.normalized(deviceName)
    }

    var isEmpty: Bool {
        accountDisplayName == nil
            && nebulaId == nil
            && deviceId == nil
            && deviceName == nil
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

struct RemoteDesktopStreamConfigurationPayload: Codable, Sendable, Equatable {
    let width: Int?
    let height: Int?
    let preferredCodec: String?
    let supportedVideoFormats: [String]
    let qualityPreset: String?
    let adaptiveResolutionEnabled: Bool?
    let targetFrameRate: Int
    let keyFrameInterval: Int
    let lowLatencyMode: Bool
    let enableHardwareAcceleration: Bool
    let enableAppleSiliconOptimization: Bool
    let clipboardSyncEnabled: Bool
    let damageTrackingEnabled: Bool?
    let separateCursorChannelEnabled: Bool?
    let interactionOverlayChannelEnabled: Bool?
    let refreshStrategy: String?
    let jitterBufferFrames: Int?
    let lossRecoveryMode: String?
    let screenFrameTransport: String?
    let screenDataChannelEnabled: Bool?
    let screenChannelWireFormat: String?
    let nativeVideoTrackReady: Bool?
    let nativeAudioTrackEnabled: Bool?
    let audioRedirectionEnabled: Bool?
    let audioTransport: String?
    let audioMode: String?
    let mediaSessionId: String?
    let mediaAudioEndpoint: SkyBridgeMediaEndpoint?
    let compatibilityAudioFallbackEnabled: Bool?
    let preferredAudioEncoding: String?
    let audioSampleRate: Int?
    let audioChannelCount: Int?
    let performanceValidationMode: String?
    let mediaFallbackPolicy: String?
    let streamRefreshToken: UInt64?
    let remoteControlSecurityIdentity: RemoteDesktopSecurityIdentityPayload?
    let framePresentationAckVersion: Int?
    var streamConfigurationTransaction: RemoteDesktopStreamConfigurationTransaction?
    let sentAt: TimeInterval

    init(
        width: Int? = nil,
        height: Int? = nil,
        preferredCodec: String? = nil,
        supportedVideoFormats: [String],
        qualityPreset: String? = nil,
        adaptiveResolutionEnabled: Bool? = nil,
        targetFrameRate: Int,
        keyFrameInterval: Int,
        lowLatencyMode: Bool,
        enableHardwareAcceleration: Bool,
        enableAppleSiliconOptimization: Bool,
        clipboardSyncEnabled: Bool,
        damageTrackingEnabled: Bool? = nil,
        separateCursorChannelEnabled: Bool? = nil,
        interactionOverlayChannelEnabled: Bool? = nil,
        refreshStrategy: String? = nil,
        jitterBufferFrames: Int? = nil,
        lossRecoveryMode: String? = nil,
        screenFrameTransport: String? = nil,
        screenDataChannelEnabled: Bool? = nil,
        screenChannelWireFormat: String? = nil,
        nativeVideoTrackReady: Bool? = nil,
        nativeAudioTrackEnabled: Bool? = nil,
        audioRedirectionEnabled: Bool? = nil,
        audioTransport: String? = nil,
        audioMode: String? = nil,
        mediaSessionId: String? = nil,
        mediaAudioEndpoint: SkyBridgeMediaEndpoint? = nil,
        compatibilityAudioFallbackEnabled: Bool? = nil,
        preferredAudioEncoding: String? = nil,
        audioSampleRate: Int? = nil,
        audioChannelCount: Int? = nil,
        performanceValidationMode: String? = nil,
        mediaFallbackPolicy: String? = nil,
        streamRefreshToken: UInt64? = nil,
        remoteControlSecurityIdentity: RemoteDesktopSecurityIdentityPayload? = nil,
        framePresentationAckVersion: Int? = nil,
        streamConfigurationTransaction: RemoteDesktopStreamConfigurationTransaction? = nil,
        sentAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.width = width
        self.height = height
        self.preferredCodec = preferredCodec
        self.supportedVideoFormats = supportedVideoFormats
        self.qualityPreset = qualityPreset
        self.adaptiveResolutionEnabled = adaptiveResolutionEnabled
        self.targetFrameRate = targetFrameRate
        self.keyFrameInterval = keyFrameInterval
        self.lowLatencyMode = lowLatencyMode
        self.enableHardwareAcceleration = enableHardwareAcceleration
        self.enableAppleSiliconOptimization = enableAppleSiliconOptimization
        self.clipboardSyncEnabled = clipboardSyncEnabled
        self.damageTrackingEnabled = damageTrackingEnabled
        self.separateCursorChannelEnabled = separateCursorChannelEnabled
        self.interactionOverlayChannelEnabled = interactionOverlayChannelEnabled
        self.refreshStrategy = refreshStrategy
        self.jitterBufferFrames = jitterBufferFrames
        self.lossRecoveryMode = lossRecoveryMode
        self.screenFrameTransport = screenFrameTransport
        self.screenDataChannelEnabled = screenDataChannelEnabled
        self.screenChannelWireFormat = screenChannelWireFormat
        self.nativeVideoTrackReady = nativeVideoTrackReady
        self.nativeAudioTrackEnabled = nativeAudioTrackEnabled
        self.audioRedirectionEnabled = audioRedirectionEnabled
        self.audioTransport = audioTransport
        self.audioMode = audioMode
        self.mediaSessionId = mediaSessionId
        self.mediaAudioEndpoint = mediaAudioEndpoint
        self.compatibilityAudioFallbackEnabled = compatibilityAudioFallbackEnabled
        self.preferredAudioEncoding = preferredAudioEncoding
        self.audioSampleRate = audioSampleRate
        self.audioChannelCount = audioChannelCount
        self.performanceValidationMode = performanceValidationMode
        self.mediaFallbackPolicy = mediaFallbackPolicy
        self.streamRefreshToken = streamRefreshToken
        self.remoteControlSecurityIdentity = remoteControlSecurityIdentity
        self.framePresentationAckVersion = framePresentationAckVersion
        self.streamConfigurationTransaction = streamConfigurationTransaction
        self.sentAt = sentAt
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.width == rhs.width
            && lhs.height == rhs.height
            && lhs.preferredCodec == rhs.preferredCodec
            && lhs.supportedVideoFormats == rhs.supportedVideoFormats
            && lhs.qualityPreset == rhs.qualityPreset
            && lhs.adaptiveResolutionEnabled == rhs.adaptiveResolutionEnabled
            && lhs.targetFrameRate == rhs.targetFrameRate
            && lhs.keyFrameInterval == rhs.keyFrameInterval
            && lhs.lowLatencyMode == rhs.lowLatencyMode
            && lhs.enableHardwareAcceleration == rhs.enableHardwareAcceleration
            && lhs.enableAppleSiliconOptimization == rhs.enableAppleSiliconOptimization
            && lhs.clipboardSyncEnabled == rhs.clipboardSyncEnabled
            && lhs.damageTrackingEnabled == rhs.damageTrackingEnabled
            && lhs.separateCursorChannelEnabled == rhs.separateCursorChannelEnabled
            && lhs.interactionOverlayChannelEnabled == rhs.interactionOverlayChannelEnabled
            && lhs.refreshStrategy == rhs.refreshStrategy
            && lhs.jitterBufferFrames == rhs.jitterBufferFrames
            && lhs.lossRecoveryMode == rhs.lossRecoveryMode
            && lhs.screenFrameTransport == rhs.screenFrameTransport
            && lhs.screenDataChannelEnabled == rhs.screenDataChannelEnabled
            && lhs.screenChannelWireFormat == rhs.screenChannelWireFormat
            && lhs.nativeVideoTrackReady == rhs.nativeVideoTrackReady
            && lhs.nativeAudioTrackEnabled == rhs.nativeAudioTrackEnabled
            && lhs.audioRedirectionEnabled == rhs.audioRedirectionEnabled
            && lhs.audioTransport == rhs.audioTransport
            && lhs.audioMode == rhs.audioMode
            && lhs.mediaSessionId == rhs.mediaSessionId
            && lhs.mediaAudioEndpoint == rhs.mediaAudioEndpoint
            && lhs.compatibilityAudioFallbackEnabled == rhs.compatibilityAudioFallbackEnabled
            && lhs.preferredAudioEncoding == rhs.preferredAudioEncoding
            && lhs.audioSampleRate == rhs.audioSampleRate
            && lhs.audioChannelCount == rhs.audioChannelCount
            && lhs.performanceValidationMode == rhs.performanceValidationMode
            && lhs.mediaFallbackPolicy == rhs.mediaFallbackPolicy
            && lhs.streamRefreshToken == rhs.streamRefreshToken
            && lhs.remoteControlSecurityIdentity == rhs.remoteControlSecurityIdentity
            && lhs.framePresentationAckVersion == rhs.framePresentationAckVersion
        // Transaction and timestamp identify a send attempt, not semantic
        // viewer settings. They intentionally do not affect coalescing.
    }
}
