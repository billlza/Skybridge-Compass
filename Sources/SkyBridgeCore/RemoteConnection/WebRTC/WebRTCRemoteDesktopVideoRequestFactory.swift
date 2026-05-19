import CoreGraphics
import Foundation

enum WebRTCRemoteDesktopVideoRequestFactory {
    static func request(
        from settings: DisplaySettings,
        isAppleSiliconRuntime: Bool
    ) -> WebRTCRemoteDesktopVideoRequest {
        let preferredCodec = settings.preferredCodec
        return WebRTCRemoteDesktopVideoRequest(
            preferredSize: hardwareCompatibleCaptureSize(
                preferredCaptureSize(
                    for: settings.resolution,
                    displaySettings: settings,
                    isAppleSiliconRuntime: isAppleSiliconRuntime
                ),
                preferredCodec: preferredCodec
            ),
            preferredCodec: preferredCodec,
            requestedFrameRate: settings.targetFrameRate,
            keyFrameInterval: settings.keyFrameInterval,
            lowLatencyMode: settings.lowLatencyMode,
            enableHardwareAcceleration: settings.enableHardwareAcceleration,
            enableAppleSiliconOptimization: settings.enableAppleSiliconOptimization,
            preserveExactVisibleSize: false
        )
    }

    static func request(
        from settings: DisplaySettings,
        remoteStreamConfiguration config: RemoteDesktopStreamConfiguration?,
        transportPath: WebRTCSession.ICETransportPath,
        isAppleSiliconRuntime: Bool
    ) -> WebRTCRemoteDesktopVideoRequest {
        guard let config else {
            let preferredCodec = settings.preferredCodec
            return WebRTCRemoteDesktopVideoRequest(
                preferredSize: hardwareCompatibleCaptureSize(
                    adaptiveCaptureSize(
                        for: transportPath,
                        preferredCodec: preferredCodec,
                        lowLatencyMode: settings.lowLatencyMode,
                        enableHardwareAcceleration: settings.enableHardwareAcceleration,
                        enableAppleSiliconOptimization: settings.enableAppleSiliconOptimization,
                        isAppleSiliconRuntime: isAppleSiliconRuntime
                    ),
                    preferredCodec: preferredCodec
                ),
                preferredCodec: preferredCodec,
                requestedFrameRate: settings.targetFrameRate,
                keyFrameInterval: settings.keyFrameInterval,
                lowLatencyMode: settings.lowLatencyMode,
                enableHardwareAcceleration: settings.enableHardwareAcceleration,
                enableAppleSiliconOptimization: settings.enableAppleSiliconOptimization,
                preserveExactVisibleSize: false
            )
        }

        let preferredCodec = preferredCodec(from: config, fallback: settings.preferredCodec)
        let adaptiveResolutionEnabled = config.adaptiveResolutionEnabled
            ?? (config.width == nil || config.height == nil)
        let explicitResolutionRequested =
            !adaptiveResolutionEnabled &&
            config.width != nil &&
            config.height != nil
        let preferredSize: CGSize = {
            if !adaptiveResolutionEnabled,
               let width = config.width,
               let height = config.height,
               width > 0,
               height > 0 {
                return CGSize(width: width, height: height)
            }
            if adaptiveResolutionEnabled {
                return adaptiveCaptureSize(
                    for: transportPath,
                    preferredCodec: preferredCodec,
                    lowLatencyMode: config.lowLatencyMode,
                    enableHardwareAcceleration: config.enableHardwareAcceleration,
                    enableAppleSiliconOptimization: config.enableAppleSiliconOptimization,
                    isAppleSiliconRuntime: isAppleSiliconRuntime
                )
            }
            return preferredCaptureSize(
                for: settings.resolution,
                displaySettings: settings,
                isAppleSiliconRuntime: isAppleSiliconRuntime
            )
        }()

        return WebRTCRemoteDesktopVideoRequest(
            preferredSize: hardwareCompatibleCaptureSize(
                preferredSize,
                preferredCodec: preferredCodec,
                preserveExactVisibleSize: explicitResolutionRequested
                    && config.requiresExtremePerformanceValidation
            ),
            preferredCodec: preferredCodec,
            requestedFrameRate: max(12, min(config.targetFrameRate, 120)),
            keyFrameInterval: max(10, min(config.keyFrameInterval, 240)),
            lowLatencyMode: config.lowLatencyMode,
            enableHardwareAcceleration: config.enableHardwareAcceleration,
            enableAppleSiliconOptimization: config.enableAppleSiliconOptimization,
            preserveExactVisibleSize: explicitResolutionRequested
                && config.requiresExtremePerformanceValidation
        )
    }

    static func hardwareCompatibleCaptureSize(
        _ size: CGSize,
        preferredCodec: PreferredVideoCodec,
        preserveExactVisibleSize: Bool = false
    ) -> CGSize {
        if preserveExactVisibleSize {
            return size
        }
        let alignment: CGFloat = 2
        func alignedDown(_ value: CGFloat) -> CGFloat {
            let positive = max(alignment, value)
            return max(alignment, floor(positive / alignment) * alignment)
        }
        return CGSize(
            width: alignedDown(size.width),
            height: alignedDown(size.height)
        )
    }

    static func adaptiveCaptureSize(
        for transportPath: WebRTCSession.ICETransportPath,
        preferredCodec: PreferredVideoCodec,
        lowLatencyMode: Bool,
        enableHardwareAcceleration: Bool,
        enableAppleSiliconOptimization: Bool,
        isAppleSiliconRuntime: Bool,
        displayMode: CGDisplayMode? = CGDisplayCopyDisplayMode(CGMainDisplayID())
    ) -> CGSize {
        let fallback = CGSize(width: 1600, height: 900)
        guard let mode = displayMode else {
            return fallback
        }

        let nativeWidth = CGFloat(mode.width)
        let nativeHeight = CGFloat(mode.height)
        guard nativeWidth > 0, nativeHeight > 0 else {
            return fallback
        }

        let longEdge = max(nativeWidth, nativeHeight)
        let prefersHEVC = preferredCodec == .hevc
        let canPushHighRes = prefersHEVC && enableHardwareAcceleration
            && enableAppleSiliconOptimization && isAppleSiliconRuntime

        let targetLongEdge: CGFloat
        switch transportPath {
        case .direct:
            if longEdge <= 1920 {
                return CGSize(width: nativeWidth, height: nativeHeight)
            } else if longEdge <= 2560 {
                targetLongEdge = lowLatencyMode ? 1920 : longEdge
            } else if longEdge <= 3840 {
                targetLongEdge = lowLatencyMode ? 1920 : (canPushHighRes ? 2560 : 1920)
            } else {
                targetLongEdge = lowLatencyMode ? 1920 : (canPushHighRes ? 3200 : 2560)
            }
        case .unknown:
            targetLongEdge = lowLatencyMode ? 1280 : 1600
        case .relay:
            targetLongEdge = lowLatencyMode ? 960 : 1280
        }

        let scale = min(1.0, targetLongEdge / longEdge)
        return CGSize(
            width: max(960, floor(nativeWidth * scale)),
            height: max(540, floor(nativeHeight * scale))
        )
    }

    private static func preferredCaptureSize(
        for resolution: ResolutionSetting,
        displaySettings settings: DisplaySettings,
        isAppleSiliconRuntime: Bool
    ) -> CGSize {
        if let dim = resolution.dimensions {
            return CGSize(width: dim.width, height: dim.height)
        }

        return adaptiveCaptureSize(
            for: .unknown,
            preferredCodec: settings.preferredCodec,
            lowLatencyMode: settings.lowLatencyMode,
            enableHardwareAcceleration: settings.enableHardwareAcceleration,
            enableAppleSiliconOptimization: settings.enableAppleSiliconOptimization,
            isAppleSiliconRuntime: isAppleSiliconRuntime
        )
    }

    private static func preferredCodec(
        from config: RemoteDesktopStreamConfiguration,
        fallback: PreferredVideoCodec
    ) -> PreferredVideoCodec {
        switch config.preferredCodec?.lowercased() {
        case "h264":
            return .h264
        case "hevc":
            return .hevc
        default:
            return fallback
        }
    }
}
