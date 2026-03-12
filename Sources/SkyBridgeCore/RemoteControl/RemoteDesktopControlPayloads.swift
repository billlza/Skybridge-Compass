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
        self.streamRefreshToken = streamRefreshToken
        self.sentAt = sentAt
    }
}
