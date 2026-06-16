import CoreGraphics
import Foundation
import VideoToolbox

enum RemoteControlStreamRequestPolicy {
    static var isAppleSiliconRuntime: Bool {
        #if arch(arm64) || arch(arm64e)
        true
        #else
        false
        #endif
    }

    static func supportedViewerVideoFormats() -> [String] {
        var formats = ["jpeg", "h264"]
        if VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) {
            formats.insert("hevc", at: 0)
        }
        var seen: Set<String> = []
        return formats.filter { seen.insert($0).inserted }
    }

    static func request(
        streamConfiguration: RemoteDesktopStreamConfiguration?,
        settings: DisplaySettings,
        nativeDisplaySize: CGSize? = mainDisplaySize(),
        isAppleSiliconRuntime: Bool = Self.isAppleSiliconRuntime
    ) -> RemoteControlStreamRequest {
        let adaptiveResolutionEnabled = streamConfiguration?.adaptiveResolutionEnabled
            ?? (streamConfiguration?.width == nil || streamConfiguration?.height == nil)
        let preferredCodec = preferredCodec(from: streamConfiguration, fallback: settings.preferredCodec)
        let preferredSize: CGSize = {
            if !adaptiveResolutionEnabled,
               let width = streamConfiguration?.width,
               let height = streamConfiguration?.height,
               width > 0,
               height > 0 {
                return CGSize(width: width, height: height)
            }
            if adaptiveResolutionEnabled {
                return adaptiveCaptureSizeForDirectDisplay(
                    preferredCodec: preferredCodec,
                    lowLatencyMode: streamConfiguration?.lowLatencyMode ?? settings.lowLatencyMode,
                    enableHardwareAcceleration: streamConfiguration?.enableHardwareAcceleration
                        ?? settings.enableHardwareAcceleration,
                    enableAppleSiliconOptimization: streamConfiguration?.enableAppleSiliconOptimization
                        ?? settings.enableAppleSiliconOptimization,
                    nativeDisplaySize: nativeDisplaySize,
                    isAppleSiliconRuntime: isAppleSiliconRuntime
                )
            }
            return preferredCaptureSize(
                for: settings.resolution,
                settings: settings,
                nativeDisplaySize: nativeDisplaySize,
                isAppleSiliconRuntime: isAppleSiliconRuntime
            )
        }()
        let exactResolutionRequested = !adaptiveResolutionEnabled
            && (streamConfiguration?.width ?? 0) > 0
            && (streamConfiguration?.height ?? 0) > 0
        let preserveExactVisibleSize = exactResolutionRequested
            && streamConfiguration?.requiresExtremePerformanceValidation == true

        return RemoteControlStreamRequest(
            preferredSize: preferredSize,
            preferredCodec: preferredCodec,
            targetFrameRate: max(12, min(streamConfiguration?.targetFrameRate ?? settings.targetFrameRate, 120)),
            keyFrameInterval: max(10, min(streamConfiguration?.keyFrameInterval ?? settings.keyFrameInterval, 240)),
            lowLatencyMode: streamConfiguration?.lowLatencyMode ?? settings.lowLatencyMode,
            enableHardwareAcceleration: streamConfiguration?.enableHardwareAcceleration
                ?? settings.enableHardwareAcceleration,
            enableAppleSiliconOptimization: streamConfiguration?.enableAppleSiliconOptimization
                ?? settings.enableAppleSiliconOptimization,
            preserveExactVisibleSize: preserveExactVisibleSize,
            preferredDisplayID: (streamConfiguration?.captureDisplayID).map { CGDirectDisplayID($0) }
                ?? settings.captureDisplayID.map { CGDirectDisplayID($0) }
        )
    }

    static func preferredCaptureSize(
        for resolution: ResolutionSetting,
        settings: DisplaySettings,
        nativeDisplaySize: CGSize? = mainDisplaySize(),
        isAppleSiliconRuntime: Bool = Self.isAppleSiliconRuntime
    ) -> CGSize {
        if let dim = resolution.dimensions {
            return CGSize(width: dim.width, height: dim.height)
        }

        return adaptiveCaptureSizeForDirectDisplay(
            preferredCodec: settings.preferredCodec,
            lowLatencyMode: settings.lowLatencyMode,
            enableHardwareAcceleration: settings.enableHardwareAcceleration,
            enableAppleSiliconOptimization: settings.enableAppleSiliconOptimization,
            nativeDisplaySize: nativeDisplaySize,
            isAppleSiliconRuntime: isAppleSiliconRuntime
        )
    }

    static func adaptiveCaptureSizeForDirectDisplay(
        preferredCodec: PreferredVideoCodec,
        lowLatencyMode: Bool,
        enableHardwareAcceleration: Bool,
        enableAppleSiliconOptimization: Bool,
        nativeDisplaySize: CGSize? = mainDisplaySize(),
        isAppleSiliconRuntime: Bool = Self.isAppleSiliconRuntime
    ) -> CGSize {
        let fallback = CGSize(width: 1920, height: 1080)
        guard let nativeDisplaySize else {
            return fallback
        }

        let nativeWidth = nativeDisplaySize.width
        let nativeHeight = nativeDisplaySize.height
        guard nativeWidth > 0, nativeHeight > 0 else {
            return fallback
        }

        let longEdge = max(nativeWidth, nativeHeight)
        let prefersHEVC = preferredCodec == .hevc
        let canPushHighRes = prefersHEVC && enableHardwareAcceleration
            && enableAppleSiliconOptimization && isAppleSiliconRuntime

        let targetLongEdge: CGFloat
        if longEdge <= 1920 {
            return CGSize(width: nativeWidth, height: nativeHeight)
        } else if longEdge <= 2560 {
            targetLongEdge = lowLatencyMode ? 1920 : longEdge
        } else if longEdge <= 3840 {
            targetLongEdge = lowLatencyMode ? 1920 : (canPushHighRes ? 2560 : 1920)
        } else {
            targetLongEdge = lowLatencyMode ? 1920 : (canPushHighRes ? 3200 : 2560)
        }

        let scale = min(1.0, targetLongEdge / longEdge)
        return CGSize(
            width: max(960, floor(nativeWidth * scale)),
            height: max(540, floor(nativeHeight * scale))
        )
    }

    static func shouldRestartCapture(
        previous: RemoteDesktopStreamConfiguration?,
        current: RemoteDesktopStreamConfiguration
    ) -> Bool {
        guard let previous else { return true }
        return previous.width != current.width
            || previous.height != current.height
            || previous.captureDisplayID != current.captureDisplayID
            || previous.preferredCodec != current.preferredCodec
            || previous.supportedVideoFormats != current.supportedVideoFormats
            || previous.videoCompressionLevel != current.videoCompressionLevel
            || previous.adaptiveResolutionEnabled != current.adaptiveResolutionEnabled
            || previous.targetFrameRate != current.targetFrameRate
            || previous.keyFrameInterval != current.keyFrameInterval
            || previous.lowLatencyMode != current.lowLatencyMode
            || previous.enableHardwareAcceleration != current.enableHardwareAcceleration
            || previous.enableAppleSiliconOptimization != current.enableAppleSiliconOptimization
            || previous.separateCursorChannelEnabled != current.separateCursorChannelEnabled
            || previous.audioRedirectionEnabled != current.audioRedirectionEnabled
            || previous.audioTransport != current.audioTransport
            || previous.audioMode != current.audioMode
            || previous.mediaSessionId != current.mediaSessionId
            || previous.mediaAudioEndpoint != current.mediaAudioEndpoint
    }

    static func streamConfigurationByPreservingAudioEndpointForVideoRefresh(
        _ current: RemoteDesktopStreamConfiguration,
        previous: RemoteDesktopStreamConfiguration?
    ) -> RemoteDesktopStreamConfiguration {
        guard current.streamRefreshToken != nil,
              current.mediaAudioEndpoint == nil,
              current.mediaSessionId == nil,
              current.requestsRealtimeMediaAudio,
              let previous,
              previous.requestsRealtimeMediaAudio,
              hasUnchangedRealtimeAudioSemantics(current, previous: previous),
              let previousEndpoint = previous.mediaAudioEndpoint else {
            return current
        }

        return RemoteDesktopStreamConfiguration(
            width: current.width,
            height: current.height,
            preferredCodec: current.preferredCodec,
            supportedVideoFormats: current.supportedVideoFormats,
            qualityPreset: current.qualityPreset,
            videoCompressionLevel: current.videoCompressionLevel,
            adaptiveResolutionEnabled: current.adaptiveResolutionEnabled,
            targetFrameRate: current.targetFrameRate,
            keyFrameInterval: current.keyFrameInterval,
            lowLatencyMode: current.lowLatencyMode,
            enableHardwareAcceleration: current.enableHardwareAcceleration,
            enableAppleSiliconOptimization: current.enableAppleSiliconOptimization,
            clipboardSyncEnabled: current.clipboardSyncEnabled,
            damageTrackingEnabled: current.damageTrackingEnabled,
            separateCursorChannelEnabled: current.separateCursorChannelEnabled,
            interactionOverlayChannelEnabled: current.interactionOverlayChannelEnabled,
            refreshStrategy: current.refreshStrategy,
            jitterBufferFrames: current.jitterBufferFrames,
            lossRecoveryMode: current.lossRecoveryMode,
            screenFrameTransport: current.screenFrameTransport,
            screenDataChannelEnabled: current.screenDataChannelEnabled,
            screenChannelWireFormat: current.screenChannelWireFormat,
            nativeVideoTrackReady: current.nativeVideoTrackReady,
            nativeAudioTrackEnabled: current.nativeAudioTrackEnabled,
            audioRedirectionEnabled: current.audioRedirectionEnabled,
            audioTransport: current.audioTransport,
            audioMode: current.audioMode ?? previous.audioMode,
            mediaSessionId: current.mediaSessionId ?? previous.mediaSessionId,
            mediaAudioEndpoint: previousEndpoint,
            compatibilityAudioFallbackEnabled: current.compatibilityAudioFallbackEnabled,
            preferredAudioEncoding: current.preferredAudioEncoding ?? previous.preferredAudioEncoding,
            audioSampleRate: current.audioSampleRate ?? previous.audioSampleRate,
            audioChannelCount: current.audioChannelCount ?? previous.audioChannelCount,
            performanceValidationMode: current.performanceValidationMode ?? previous.performanceValidationMode,
            mediaFallbackPolicy: current.mediaFallbackPolicy ?? previous.mediaFallbackPolicy,
            streamRefreshToken: current.streamRefreshToken,
            remoteControlSecurityIdentity: current.remoteControlSecurityIdentity ?? previous.remoteControlSecurityIdentity,
            sentAt: current.sentAt
        )
    }

    private static func hasUnchangedRealtimeAudioSemantics(
        _ current: RemoteDesktopStreamConfiguration,
        previous: RemoteDesktopStreamConfiguration
    ) -> Bool {
        current.audioRedirectionEnabled == previous.audioRedirectionEnabled
            && current.audioTransport == previous.audioTransport
            && (current.audioMode ?? previous.audioMode) == previous.audioMode
            && current.compatibilityAudioFallbackEnabled == previous.compatibilityAudioFallbackEnabled
            && (current.preferredAudioEncoding ?? previous.preferredAudioEncoding) == previous.preferredAudioEncoding
            && (current.audioSampleRate ?? previous.audioSampleRate) == previous.audioSampleRate
            && (current.audioChannelCount ?? previous.audioChannelCount) == previous.audioChannelCount
    }

    private static func preferredCodec(
        from streamConfiguration: RemoteDesktopStreamConfiguration?,
        fallback: PreferredVideoCodec
    ) -> PreferredVideoCodec {
        switch streamConfiguration?.preferredCodec?.lowercased() {
        case "h264":
            return .h264
        case "hevc":
            return .hevc
        default:
            return fallback
        }
    }

    private static func mainDisplaySize() -> CGSize? {
        guard let mode = CGDisplayCopyDisplayMode(CGMainDisplayID()) else {
            return nil
        }
        return CGSize(width: mode.width, height: mode.height)
    }
}
