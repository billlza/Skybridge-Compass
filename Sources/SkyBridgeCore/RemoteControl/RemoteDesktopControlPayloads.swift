import Foundation

public struct RemoteClipboardPayload: Codable, Sendable, Equatable {
    public let mimeType: String
    public let data: Data
    public let sentAt: TimeInterval

    public init(
        mimeType: String,
        data: Data,
        sentAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.mimeType = mimeType
        self.data = data
        self.sentAt = sentAt
    }
}

public struct RemoteDesktopDamageRect: Codable, Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct RemoteDesktopDamageReport: Codable, Sendable, Equatable {
    public let rects: [RemoteDesktopDamageRect]
    public let fullFrameFallback: Bool
    public let sentAt: TimeInterval

    public init(
        rects: [RemoteDesktopDamageRect],
        fullFrameFallback: Bool = false,
        sentAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.rects = rects
        self.fullFrameFallback = fullFrameFallback
        self.sentAt = sentAt
    }
}

public struct RemoteDesktopCursorPayload: Codable, Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let hotspotX: Double
    public let hotspotY: Double
    public let hidden: Bool
    public let imageData: Data?
    public let mimeType: String?
    public let sentAt: TimeInterval

    public init(
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        hotspotX: Double = 0,
        hotspotY: Double = 0,
        hidden: Bool = false,
        imageData: Data? = nil,
        mimeType: String? = nil,
        sentAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.hotspotX = hotspotX
        self.hotspotY = hotspotY
        self.hidden = hidden
        self.imageData = imageData
        self.mimeType = mimeType
        self.sentAt = sentAt
    }
}

public struct RemoteDesktopOverlayPayload: Codable, Sendable, Equatable {
    public let selectionRects: [RemoteDesktopDamageRect]
    public let focusRect: RemoteDesktopDamageRect?
    public let sentAt: TimeInterval

    public init(
        selectionRects: [RemoteDesktopDamageRect] = [],
        focusRect: RemoteDesktopDamageRect? = nil,
        sentAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.selectionRects = selectionRects
        self.focusRect = focusRect
        self.sentAt = sentAt
    }
}

public struct RemoteDesktopAudioChunkPayload: Codable, Sendable, Equatable {
    public enum Encoding: String, Codable, Sendable {
        case pcmS16LE = "pcm_s16le"
        case aacLC = "aac_lc"
    }

    public struct PacketDescription: Codable, Sendable, Equatable {
        public let startOffset: Int
        public let variableFramesInPacket: UInt32
        public let dataByteSize: UInt32

        public init(
            startOffset: Int,
            variableFramesInPacket: UInt32,
            dataByteSize: UInt32
        ) {
            self.startOffset = startOffset
            self.variableFramesInPacket = variableFramesInPacket
            self.dataByteSize = dataByteSize
        }
    }

    public let encoding: Encoding
    public let sampleRate: Int
    public let channelCount: Int
    public let frameCount: Int
    public let packetCount: Int?
    public let packetDescriptions: [PacketDescription]?
    public let magicCookie: Data?
    public let sequenceNumber: UInt64
    public let sentAt: TimeInterval
    public let data: Data

    public init(
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

public struct RemoteDesktopStreamConfiguration: Codable, Sendable, Equatable {
    public let width: Int?
    public let height: Int?
    public let preferredCodec: String?
    public let supportedVideoFormats: [String]
    public let qualityPreset: String?
    public let adaptiveResolutionEnabled: Bool?
    public let targetFrameRate: Int
    public let keyFrameInterval: Int
    public let lowLatencyMode: Bool
    public let enableHardwareAcceleration: Bool
    public let enableAppleSiliconOptimization: Bool
    public let clipboardSyncEnabled: Bool
    public let damageTrackingEnabled: Bool?
    public let separateCursorChannelEnabled: Bool?
    public let interactionOverlayChannelEnabled: Bool?
    public let refreshStrategy: String?
    public let jitterBufferFrames: Int?
    public let lossRecoveryMode: String?
    public let screenFrameTransport: String?
    public let screenDataChannelEnabled: Bool?
    public let nativeVideoTrackReady: Bool?
    public let nativeAudioTrackEnabled: Bool?
    public let audioRedirectionEnabled: Bool?
    public let preferredAudioEncoding: String?
    public let audioSampleRate: Int?
    public let audioChannelCount: Int?
    public let streamRefreshToken: UInt64?
    public let sentAt: TimeInterval

    public init(
        width: Int? = nil,
        height: Int? = nil,
        preferredCodec: String? = nil,
        supportedVideoFormats: [String] = [],
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
        nativeVideoTrackReady: Bool? = nil,
        nativeAudioTrackEnabled: Bool? = nil,
        audioRedirectionEnabled: Bool? = nil,
        preferredAudioEncoding: String? = nil,
        audioSampleRate: Int? = nil,
        audioChannelCount: Int? = nil,
        streamRefreshToken: UInt64? = nil,
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
        self.nativeVideoTrackReady = nativeVideoTrackReady
        self.nativeAudioTrackEnabled = nativeAudioTrackEnabled
        self.audioRedirectionEnabled = audioRedirectionEnabled
        self.preferredAudioEncoding = preferredAudioEncoding
        self.audioSampleRate = audioSampleRate
        self.audioChannelCount = audioChannelCount
        self.streamRefreshToken = streamRefreshToken
        self.sentAt = sentAt
    }
}

public extension RemoteDesktopStreamConfiguration {
    var isStopRequest: Bool {
        if screenFrameTransport?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "stopped" {
            return true
        }
        if refreshStrategy?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "stop" {
            return true
        }
        return targetFrameRate <= 0
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

    static func encode(_ payload: RemoteDesktopAudioChunkPayload) -> Data {
        let encodingTag = EncodingTag(encoding: payload.encoding) ?? .pcmS16LE
        let sampleRate = UInt32(clamping: payload.sampleRate)
        let frameCount = UInt32(clamping: payload.frameCount)
        let packetCount = UInt32(clamping: payload.packetCount ?? 0)
        let packetDescriptions = payload.packetDescriptions ?? []
        let packetDescriptionCount = UInt32(clamping: packetDescriptions.count)
        let magicCookie = payload.magicCookie ?? Data()
        let magicCookieLength = UInt32(clamping: magicCookie.count)
        let payloadLength = UInt32(clamping: payload.data.count)
        let timestampMicros = UInt64(max(payload.sentAt, 0) * 1_000_000.0)

        var data = Data()
        data.reserveCapacity(
            headerSize
                + magicCookie.count
                + (packetDescriptions.count * packetDescriptionSize)
                + payload.data.count
        )
        appendUInt32(magic, to: &data)
        data.append(version)
        data.append(encodingTag.rawValue)
        data.append(UInt8(clamping: payload.channelCount))
        data.append(0)
        appendUInt32(sampleRate, to: &data)
        appendUInt32(frameCount, to: &data)
        appendUInt32(packetCount, to: &data)
        appendUInt64(payload.sequenceNumber, to: &data)
        appendUInt64(timestampMicros, to: &data)
        appendUInt32(magicCookieLength, to: &data)
        appendUInt32(packetDescriptionCount, to: &data)
        appendUInt32(payloadLength, to: &data)
        data.append(magicCookie)
        for packetDescription in packetDescriptions {
            appendUInt32(UInt32(clamping: packetDescription.startOffset), to: &data)
            appendUInt32(packetDescription.variableFramesInPacket, to: &data)
            appendUInt32(packetDescription.dataByteSize, to: &data)
        }
        data.append(payload.data)
        return data
    }

    static func decodeIfPresent(_ data: Data) -> RemoteDesktopAudioChunkPayload? {
        guard data.count >= version1HeaderSize else { return nil }
        guard readUInt32(from: data, offset: 0) == magic else { return nil }

        switch data[4] {
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
        guard let encodingTag = EncodingTag(rawValue: data[5]) else { return nil }

        let channelCount = Int(data[6])
        let sampleRate = Int(readUInt32(from: data, offset: 8))
        let frameCount = Int(readUInt32(from: data, offset: 12))
        let sequenceNumber = readUInt64(from: data, offset: 16)
        let timestampMicros = readUInt64(from: data, offset: 24)
        let payloadLength = Int(readUInt32(from: data, offset: 32))

        guard channelCount > 0, frameCount > 0, sampleRate > 0 else { return nil }
        guard payloadLength >= 0, data.count == version1HeaderSize + payloadLength else { return nil }

        return RemoteDesktopAudioChunkPayload(
            encoding: encodingTag.encoding,
            sampleRate: sampleRate,
            channelCount: channelCount,
            frameCount: frameCount,
            sequenceNumber: sequenceNumber,
            sentAt: TimeInterval(timestampMicros) / 1_000_000.0,
            data: data.subdata(in: version1HeaderSize..<data.count)
        )
    }

    private static func decodeVersion2(_ data: Data) -> RemoteDesktopAudioChunkPayload? {
        guard data.count >= headerSize else { return nil }
        guard let encodingTag = EncodingTag(rawValue: data[5]) else { return nil }

        let channelCount = Int(data[6])
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

        let magicCookie = magicCookieLength > 0 ? data.subdata(in: magicCookieRange) : nil
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
            data: data.subdata(in: payloadStart..<(payloadStart + payloadLength))
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

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { rawBuffer in
            data.append(contentsOf: rawBuffer)
        }
    }

    private static func appendUInt64(_ value: UInt64, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { rawBuffer in
            data.append(contentsOf: rawBuffer)
        }
    }
}
