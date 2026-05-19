import Foundation

public enum RemoteDesktopViewerResolution: String, CaseIterable, Codable, Sendable {
    case auto
    case hd720
    case fullHD1080
    case qhd1440
    case uhd4k
    case uhd5k

    public var displayName: String {
        switch self {
        case .auto: return "自动"
        case .hd720: return "1280 × 720"
        case .fullHD1080: return "1920 × 1080"
        case .qhd1440: return "2560 × 1440"
        case .uhd4k: return "3840 × 2160"
        case .uhd5k: return "5120 × 2880"
        }
    }

    var dimensions: (width: Int, height: Int)? {
        switch self {
        case .auto:
            return nil
        case .hd720:
            return (1280, 720)
        case .fullHD1080:
            return (1920, 1080)
        case .qhd1440:
            return (2560, 1440)
        case .uhd4k:
            return (3840, 2160)
        case .uhd5k:
            return (5120, 2880)
        }
    }
}

public enum RemoteDesktopViewerFrameRate: String, CaseIterable, Codable, Sendable {
    case adaptive
    case fps30
    case fps60
    case fps120

    public var displayName: String {
        switch self {
        case .adaptive: return "自适应"
        case .fps30: return "30 FPS"
        case .fps60: return "60 FPS"
        case .fps120: return "120 FPS"
        }
    }

    var targetFPS: Int {
        switch self {
        case .adaptive: return 60
        case .fps30: return 30
        case .fps60: return 60
        case .fps120: return 120
        }
    }
}

public enum RemoteDesktopViewerCodec: String, CaseIterable, Codable, Sendable {
    case automatic
    case hevc
    case h264
    case jpeg

    public var displayName: String {
        switch self {
        case .automatic: return "自动"
        case .hevc: return "HEVC"
        case .h264: return "H.264"
        case .jpeg: return "JPEG"
        }
    }

    var wireValue: String? {
        switch self {
        case .automatic: return nil
        case .hevc: return "hevc"
        case .h264: return "h264"
        case .jpeg: return "jpeg"
        }
    }

    func resolvedWireValue(supportedFormats: [String]) -> String? {
        switch self {
        case .automatic:
            if supportedFormats.contains("h264") {
                return "h264"
            }
            if supportedFormats.contains("hevc") {
                return "hevc"
            }
            return supportedFormats.first
        case .jpeg:
            return supportedFormats.first { $0 == "h264" || $0 == "hevc" }
                ?? supportedFormats.first
        default:
            guard let raw = wireValue else { return nil }
            return supportedFormats.contains(raw) ? raw : nil
        }
    }
}

private struct RemoteDesktopViewerStrategySignature: Equatable, Sendable {
    let resolution: RemoteDesktopViewerResolution
    let frameRate: RemoteDesktopViewerFrameRate
    let preferredCodec: RemoteDesktopViewerCodec
    let lowLatencyMode: Bool
}

private struct RemoteDesktopViewerPresetTemplate: Equatable, Sendable {
    let resolution: RemoteDesktopViewerResolution
    let frameRate: RemoteDesktopViewerFrameRate
    let preferredCodec: RemoteDesktopViewerCodec
    let lowLatencyMode: Bool

    var signature: RemoteDesktopViewerStrategySignature {
        .init(
            resolution: resolution,
            frameRate: frameRate,
            preferredCodec: preferredCodec,
            lowLatencyMode: lowLatencyMode
        )
    }
}

struct RemoteDesktopTransportTuning: Equatable, Sendable {
    let qualityPresetWireValue: String
    let damageTrackingEnabled: Bool
    let separateCursorChannelEnabled: Bool
    let interactionOverlayChannelEnabled: Bool
    let refreshStrategy: String
    let jitterBufferFrames: Int
    let lossRecoveryMode: String
}

public enum RemoteDesktopViewerPreset: String, CaseIterable, Codable, Sendable {
    case automatic
    case clarity
    case fluid
    case pro4k120
    case pro5k120
    case custom

    public var displayName: String {
        switch self {
        case .automatic: return "自动"
        case .clarity: return "清晰优先"
        case .fluid: return "流畅优先"
        case .pro4k120: return "Pro 4K 120"
        case .pro5k120: return "Pro 5K 120"
        case .custom: return "自定义"
        }
    }

    public var detailText: String {
        switch self {
        case .automatic:
            return "稳定优先 H.264，自适应 60 FPS，链路稳定后再探测更激进编码"
        case .clarity:
            return "4K 60 HEVC，优先保住细节与文字锐度"
        case .fluid:
            return "720p 60 H.264 低延迟，弱网下更稳"
        case .pro4k120:
            return "4K 120 HEVC 低延迟，适合高刷直连"
        case .pro5k120:
            return "5K 120 HEVC 低延迟，面向极客旗舰模式"
        case .custom:
            return "手动组合分辨率、帧率、编码器与延迟策略"
        }
    }

    fileprivate var template: RemoteDesktopViewerPresetTemplate? {
        switch self {
        case .automatic:
            return .init(
                resolution: .auto,
                frameRate: .adaptive,
                preferredCodec: .automatic,
                lowLatencyMode: false
            )
        case .clarity:
            return .init(
                resolution: .uhd4k,
                frameRate: .fps60,
                preferredCodec: .hevc,
                lowLatencyMode: false
            )
        case .fluid:
            return .init(
                resolution: .hd720,
                frameRate: .fps60,
                preferredCodec: .h264,
                lowLatencyMode: true
            )
        case .pro4k120:
            return .init(
                resolution: .uhd4k,
                frameRate: .fps120,
                preferredCodec: .hevc,
                lowLatencyMode: true
            )
        case .pro5k120:
            return .init(
                resolution: .uhd5k,
                frameRate: .fps120,
                preferredCodec: .hevc,
                lowLatencyMode: true
            )
        case .custom:
            return nil
        }
    }

    fileprivate var transportTuning: RemoteDesktopTransportTuning {
        switch self {
        case .automatic:
            return .init(
                qualityPresetWireValue: "automatic",
                damageTrackingEnabled: true,
                separateCursorChannelEnabled: true,
                interactionOverlayChannelEnabled: false,
                refreshStrategy: "balanced",
                jitterBufferFrames: 2,
                lossRecoveryMode: "balanced"
            )
        case .clarity:
            return .init(
                qualityPresetWireValue: "clarity",
                damageTrackingEnabled: true,
                separateCursorChannelEnabled: true,
                interactionOverlayChannelEnabled: false,
                refreshStrategy: "quality-biased",
                jitterBufferFrames: 2,
                lossRecoveryMode: "balanced"
            )
        case .fluid:
            return .init(
                qualityPresetWireValue: "fluid",
                damageTrackingEnabled: true,
                separateCursorChannelEnabled: true,
                interactionOverlayChannelEnabled: false,
                refreshStrategy: "aggressive",
                jitterBufferFrames: 3,
                lossRecoveryMode: "resilient"
            )
        case .pro4k120:
            return .init(
                qualityPresetWireValue: "geek4k120",
                damageTrackingEnabled: true,
                separateCursorChannelEnabled: true,
                interactionOverlayChannelEnabled: false,
                refreshStrategy: "instant",
                jitterBufferFrames: 1,
                lossRecoveryMode: "fast-retransmit"
            )
        case .pro5k120:
            return .init(
                qualityPresetWireValue: "geek5k120",
                damageTrackingEnabled: true,
                separateCursorChannelEnabled: true,
                interactionOverlayChannelEnabled: false,
                refreshStrategy: "instant",
                jitterBufferFrames: 1,
                lossRecoveryMode: "fast-retransmit"
            )
        case .custom:
            return .init(
                qualityPresetWireValue: "custom",
                damageTrackingEnabled: true,
                separateCursorChannelEnabled: true,
                interactionOverlayChannelEnabled: false,
                refreshStrategy: "balanced",
                jitterBufferFrames: 2,
                lossRecoveryMode: "balanced"
            )
        }
    }
}

public struct RemoteDesktopViewerSettings: Codable, Sendable, Equatable {
    public var resolution: RemoteDesktopViewerResolution = .auto
    public var frameRate: RemoteDesktopViewerFrameRate = .adaptive
    public var preferredCodec: RemoteDesktopViewerCodec = .automatic
    public var clipboardSyncEnabled: Bool = true
    public var audioRedirectionEnabled: Bool = true
    public var lowLatencyMode: Bool = false

    private enum CodingKeys: String, CodingKey {
        case resolution
        case frameRate
        case preferredCodec
        case clipboardSyncEnabled
        case audioRedirectionEnabled
        case lowLatencyMode
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        resolution = try container.decodeIfPresent(RemoteDesktopViewerResolution.self, forKey: .resolution) ?? .auto
        frameRate = try container.decodeIfPresent(RemoteDesktopViewerFrameRate.self, forKey: .frameRate) ?? .adaptive
        preferredCodec = try container.decodeIfPresent(RemoteDesktopViewerCodec.self, forKey: .preferredCodec) ?? .automatic
        clipboardSyncEnabled = try container.decodeIfPresent(Bool.self, forKey: .clipboardSyncEnabled) ?? true
        audioRedirectionEnabled = try container.decodeIfPresent(Bool.self, forKey: .audioRedirectionEnabled) ?? true
        lowLatencyMode = try container.decodeIfPresent(Bool.self, forKey: .lowLatencyMode) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(resolution, forKey: .resolution)
        try container.encode(frameRate, forKey: .frameRate)
        try container.encode(preferredCodec, forKey: .preferredCodec)
        try container.encode(clipboardSyncEnabled, forKey: .clipboardSyncEnabled)
        try container.encode(audioRedirectionEnabled, forKey: .audioRedirectionEnabled)
        try container.encode(lowLatencyMode, forKey: .lowLatencyMode)
    }

    var targetFrameRate: Int {
        frameRate.targetFPS
    }

    var keyFrameInterval: Int {
        lowLatencyMode ? max(15, targetFrameRate / 2) : max(30, targetFrameRate)
    }

    fileprivate var strategySignature: RemoteDesktopViewerStrategySignature {
        .init(
            resolution: resolution,
            frameRate: frameRate,
            preferredCodec: preferredCodec,
            lowLatencyMode: lowLatencyMode
        )
    }

    var activePreset: RemoteDesktopViewerPreset {
        RemoteDesktopViewerPreset.allCases.first { preset in
            guard let template = preset.template else { return false }
            return template.signature == strategySignature
        } ?? .custom
    }

    mutating func applyPreset(_ preset: RemoteDesktopViewerPreset) {
        guard let template = preset.template else { return }
        resolution = template.resolution
        frameRate = template.frameRate
        preferredCodec = template.preferredCodec
        lowLatencyMode = template.lowLatencyMode
    }

    var transportTuning: RemoteDesktopTransportTuning {
        let preset = activePreset
        guard preset == .custom else { return preset.transportTuning }
        return .init(
            qualityPresetWireValue: "custom",
            damageTrackingEnabled: true,
            separateCursorChannelEnabled: true,
            interactionOverlayChannelEnabled: false,
            refreshStrategy: lowLatencyMode ? "instant" : "balanced",
            jitterBufferFrames: lowLatencyMode ? 1 : 2,
            lossRecoveryMode: lowLatencyMode ? "fast-retransmit" : "balanced"
        )
    }
}
