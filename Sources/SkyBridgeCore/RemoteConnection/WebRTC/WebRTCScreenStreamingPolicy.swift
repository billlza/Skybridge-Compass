import CoreGraphics
import Foundation

extension CrossNetworkConnectionManager {
    static func shouldStartWebRTCScreenStreaming(
        remoteStreamConfiguration: RemoteDesktopStreamConfiguration?
    ) -> Bool {
        guard let remoteStreamConfiguration else { return false }
        return !remoteStreamConfiguration.isStopRequest
    }

    struct WebRTCScreenChannelRoutePlan: Equatable {
        let state: String
        let useDedicatedScreenChannel: Bool
        let useChunkedScreenWire: Bool
        let shouldWaitForScreenChannel: Bool
        let allowsInteractionStreaming: Bool
    }

    enum NativeVideoHealthState: String {
        case negotiated
        case rawFramesSubmitted
        case rtpFlowing
        case rendered
        case degradedNoRTP
        case failedNoRTP
        case senderZero
        case recovering
    }

    struct NativeVideoFallbackDecision: Equatable {
        let fallbackShouldDriveMain: Bool
        let retryNativeCapture: Bool
        let retryReason: String
        let cooldownRemainingSeconds: TimeInterval
    }

    static let webRTCScreenChannelOpenGraceSeconds: TimeInterval = 2.0
    static let webRTCFallbackCGDisplayProducer = "cgdisplaySync"
    static let webRTCFallbackSCKLatestProducer = "sckLatest"
    static let webRTCFallbackCGDisplayEmergencyProducer = "cgdisplayEmergency"
    static let webRTCFallbackDirectEncoderProducer = "directEncoder"
    static let webRTCFallbackDegradedJPEGWarmupProducer = "degradedJPEGWarmupMain"
    static let webRTCFallbackBoundedJPEGWarmupProducer = "boundedJPEGWarmupMain"
    static let webRTCSCKLatestFallbackMaxAgeSeconds: TimeInterval = 0.5
    static let webRTCCGDisplayEmergencyFallbackHoldSeconds: TimeInterval = 10.0
    static let webRTCSCKLatestRecoveryMinimumFPS: Double = 12.0
    static let webRTCSCKLatestRecoveryRequiredFrames = 6
    static let webRTCNativeWarmupJPEGMaxLongEdge = 2_560
    static let webRTCNativeWarmupJPEGBackpressureLowWatermarkBytes =
        UInt64(WebRTCDegradedFallbackJPEGProfile.maxTransportFrameBytes)

    static func degradedWebRTCFallbackJPEGProfile(
        compressionLevel: Int = 6
    ) -> WebRTCDegradedFallbackJPEGProfile {
        jpegProfile(
            base: .emergency,
            compressionLevel: compressionLevel
        )
    }

    static func boundedWebRTCWarmupJPEGProfile(
        for sourceSize: CGSize,
        compressionLevel: Int = 6
    ) -> WebRTCDegradedFallbackJPEGProfile {
        let requestedLongEdge = max(
            Int(sourceSize.width.rounded()),
            Int(sourceSize.height.rounded())
        )
        let longEdge = min(
            max(requestedLongEdge, WebRTCDegradedFallbackJPEGProfile.maxLongEdge),
            webRTCNativeWarmupJPEGMaxLongEdge
        )
        let highResolutionBudget = longEdge > WebRTCDegradedFallbackJPEGProfile.maxLongEdge
        let base = WebRTCDegradedFallbackJPEGProfile(
            maxLongEdge: longEdge,
            targetFrameRate: highResolutionBudget
                ? 6
                : WebRTCDegradedFallbackJPEGProfile.targetFrameRate,
            maxEncodedFrameBytes: highResolutionBudget
                ? 640 * 1024
                : WebRTCDegradedFallbackJPEGProfile.maxEncodedFrameBytes,
            maxTransportFrameBytes: highResolutionBudget
                ? 896 * 1024
                : WebRTCDegradedFallbackJPEGProfile.maxTransportFrameBytes,
            qualityLadder: highResolutionBudget
                ? [0.60, 0.48, 0.36, 0.28, 0.22]
                : WebRTCDegradedFallbackJPEGProfile.qualityLadder
        )
        return jpegProfile(base: base, compressionLevel: compressionLevel)
    }

    private static func jpegProfile(
        base: WebRTCDegradedFallbackJPEGProfile,
        compressionLevel: Int
    ) -> WebRTCDegradedFallbackJPEGProfile {
        let level = max(0, min(compressionLevel, 9))
        guard level != 6 else { return base }

        let qualityScale = max(0.65, min(1.25, 1.0 - (CGFloat(level - 6) * 0.075)))
        let byteScale = max(0.65, min(1.30, 1.0 - (Double(level - 6) * 0.08)))
        let scaledQuality = base.qualityLadder.map { quality in
            max(0.18, min(0.92, quality * qualityScale))
        }
        return WebRTCDegradedFallbackJPEGProfile(
            maxLongEdge: base.maxLongEdge,
            targetFrameRate: base.targetFrameRate,
            maxEncodedFrameBytes: max(64 * 1024, Int(Double(base.maxEncodedFrameBytes) * byteScale)),
            maxTransportFrameBytes: max(96 * 1024, Int(Double(base.maxTransportFrameBytes) * byteScale)),
            qualityLadder: scaledQuality
        )
    }

    static func nativeWarmupJPEGBackpressureThreshold(maxBufferedAmountBytes: UInt64) -> UInt64 {
        guard maxBufferedAmountBytes > 0 else { return 0 }
        return min(maxBufferedAmountBytes, webRTCNativeWarmupJPEGBackpressureLowWatermarkBytes)
    }

    static func nativeVideoFallbackDecision(
        supportsNativeVideoTrack: Bool,
        nativeVideoTrackReady: Bool,
        nativeVideoHealthState: NativeVideoHealthState,
        cooldownRemainingSeconds: TimeInterval
    ) -> NativeVideoFallbackDecision {
        guard supportsNativeVideoTrack else {
            return NativeVideoFallbackDecision(
                fallbackShouldDriveMain: false,
                retryNativeCapture: false,
                retryReason: "native-video-unsupported",
                cooldownRemainingSeconds: 0
            )
        }
        guard nativeVideoTrackReady else {
            if nativeVideoHealthState == .rtpFlowing || nativeVideoHealthState == .rendered {
                return NativeVideoFallbackDecision(
                    fallbackShouldDriveMain: false,
                    retryNativeCapture: false,
                    retryReason: "native-rtp-flowing-awaiting-visible-render",
                    cooldownRemainingSeconds: max(0, cooldownRemainingSeconds)
                )
            }
            return NativeVideoFallbackDecision(
                fallbackShouldDriveMain: true,
                retryNativeCapture: nativeVideoHealthState != .recovering,
                retryReason: nativeVideoHealthState.rawValue,
                cooldownRemainingSeconds: max(0, cooldownRemainingSeconds)
            )
        }
        return NativeVideoFallbackDecision(
            fallbackShouldDriveMain: false,
            retryNativeCapture: nativeVideoHealthState != .rendered && nativeVideoHealthState != .recovering,
            retryReason: nativeVideoHealthState == .rendered ? "native-rtp-healthy" : nativeVideoHealthState.rawValue,
            cooldownRemainingSeconds: max(0, cooldownRemainingSeconds)
        )
    }

    static func shouldThrottleNativeWarmupJPEGFallback(
        supportsNativeVideoTrack: Bool,
        nativeVideoTrackReady: Bool,
        bufferedAmount: UInt64,
        maxBufferedAmountBytes: UInt64
    ) -> Bool {
        guard supportsNativeVideoTrack, !nativeVideoTrackReady else { return false }
        let threshold = nativeWarmupJPEGBackpressureThreshold(
            maxBufferedAmountBytes: maxBufferedAmountBytes
        )
        guard threshold > 0 else { return false }
        return bufferedAmount >= threshold
    }

    static func shouldRecoverWebRTCSCKLatestFallback(
        recentFrameCount: Int,
        windowStartedAt: Date?,
        now: Date
    ) -> Bool {
        guard recentFrameCount >= webRTCSCKLatestRecoveryRequiredFrames,
              let windowStartedAt else {
            return false
        }
        let elapsed = now.timeIntervalSince(windowStartedAt)
        guard elapsed > 0 else { return false }
        return Double(recentFrameCount) / elapsed >= webRTCSCKLatestRecoveryMinimumFPS
    }

    static func updateWebRTCSCKLatestRecoveryWindow(
        candidateFrame: WebRTCEncodedScreenFrame?,
        now: Date,
        windowStartedAt: inout Date?,
        recentFrameCount: inout Int,
        lastFrameIdentity: inout WebRTCEncodedScreenFrameIdentity?
    ) {
        guard let candidateFrame else {
            windowStartedAt = nil
            recentFrameCount = 0
            lastFrameIdentity = nil
            return
        }

        if windowStartedAt == nil {
            windowStartedAt = now
            recentFrameCount = 0
            lastFrameIdentity = nil
        }

        let frameIdentity = candidateFrame.recoveryIdentity
        guard lastFrameIdentity != frameIdentity else { return }
        lastFrameIdentity = frameIdentity
        recentFrameCount += 1
    }

    static func planWebRTCScreenChannelRoute(
        screenDataChannelEnabled: Bool,
        screenChannelWireFormat: String?,
        screenChannelOpen: Bool,
        waitElapsed: TimeInterval?
    ) -> WebRTCScreenChannelRoutePlan {
        guard screenDataChannelEnabled else {
            return WebRTCScreenChannelRoutePlan(
                state: "control",
                useDedicatedScreenChannel: false,
                useChunkedScreenWire: false,
                shouldWaitForScreenChannel: false,
                allowsInteractionStreaming: true
            )
        }

        let requestedWireFormat = screenChannelWireFormat?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if screenChannelOpen {
            return WebRTCScreenChannelRoutePlan(
                state: "open",
                useDedicatedScreenChannel: true,
                useChunkedScreenWire: requestedWireFormat == RemoteDesktopStreamConfiguration.screenChannelWireFormatSBC2ChunkedV1,
                shouldWaitForScreenChannel: false,
                allowsInteractionStreaming: true
            )
        }

        if (waitElapsed ?? 0) < webRTCScreenChannelOpenGraceSeconds {
            return WebRTCScreenChannelRoutePlan(
                state: "waiting",
                useDedicatedScreenChannel: false,
                useChunkedScreenWire: false,
                shouldWaitForScreenChannel: true,
                allowsInteractionStreaming: false
            )
        }

        return WebRTCScreenChannelRoutePlan(
            state: "failed-control-fallback",
            useDedicatedScreenChannel: false,
            useChunkedScreenWire: false,
            shouldWaitForScreenChannel: false,
            allowsInteractionStreaming: true
        )
    }

    static func requiredStableDirectEncoderFrames(targetFrameRate: Int) -> Int {
        max(3, min(12, Int((Double(max(targetFrameRate, 1)) * 0.25).rounded())))
    }

    static func shouldPromoteDirectEncoderFallback(
        nativeVideoWarmBackupEnabled: Bool,
        nativeVideoHasRenderEvidence: Bool,
        activeFallbackProducer: String,
        recoveryStreak: Int,
        targetFrameRate: Int
    ) -> Bool {
        guard nativeVideoWarmBackupEnabled else {
            return true
        }
        guard nativeVideoHasRenderEvidence else {
            return false
        }
        if activeFallbackProducer == webRTCFallbackDirectEncoderProducer {
            return true
        }
        return recoveryStreak >= requiredStableDirectEncoderFrames(targetFrameRate: targetFrameRate)
    }

    static func shouldDropNativeWarmupNonJPEGFallbackFrame(
        supportsNativeVideoTrack: Bool,
        nativeVideoTrackReady: Bool,
        format: String?
    ) -> Bool {
        supportsNativeVideoTrack && !nativeVideoTrackReady
    }

    static func streamConfigurationByPreservingAudioEndpointForVideoRefresh(
        _ config: RemoteDesktopStreamConfiguration,
        previousConfig: RemoteDesktopStreamConfiguration?
    ) -> RemoteDesktopStreamConfiguration {
        guard config.streamRefreshToken != nil,
              config.mediaAudioEndpoint == nil,
              config.mediaSessionId == nil,
              config.requestsRealtimeMediaAudio,
              let previousConfig,
              Self.hasUnchangedRealtimeAudioSemantics(config, previous: previousConfig),
              previousConfig.requestsRealtimeMediaAudio,
              let previousEndpoint = previousConfig.mediaAudioEndpoint else {
            return config
        }

        return RemoteDesktopStreamConfiguration(
            width: config.width,
            height: config.height,
            preferredCodec: config.preferredCodec,
            supportedVideoFormats: config.supportedVideoFormats,
            qualityPreset: config.qualityPreset,
            videoCompressionLevel: config.videoCompressionLevel,
            adaptiveResolutionEnabled: config.adaptiveResolutionEnabled,
            targetFrameRate: config.targetFrameRate,
            keyFrameInterval: config.keyFrameInterval,
            lowLatencyMode: config.lowLatencyMode,
            enableHardwareAcceleration: config.enableHardwareAcceleration,
            enableAppleSiliconOptimization: config.enableAppleSiliconOptimization,
            clipboardSyncEnabled: config.clipboardSyncEnabled,
            damageTrackingEnabled: config.damageTrackingEnabled,
            separateCursorChannelEnabled: config.separateCursorChannelEnabled,
            interactionOverlayChannelEnabled: config.interactionOverlayChannelEnabled,
            refreshStrategy: config.refreshStrategy,
            jitterBufferFrames: config.jitterBufferFrames,
            lossRecoveryMode: config.lossRecoveryMode,
            screenFrameTransport: config.screenFrameTransport,
            screenDataChannelEnabled: config.screenDataChannelEnabled,
            screenChannelWireFormat: config.screenChannelWireFormat,
            nativeVideoTrackReady: config.nativeVideoTrackReady,
            nativeAudioTrackEnabled: config.nativeAudioTrackEnabled,
            audioRedirectionEnabled: config.audioRedirectionEnabled,
            audioTransport: config.audioTransport,
            audioMode: config.audioMode ?? previousConfig.audioMode,
            mediaSessionId: config.mediaSessionId ?? previousConfig.mediaSessionId,
            mediaAudioEndpoint: previousEndpoint,
            compatibilityAudioFallbackEnabled: config.compatibilityAudioFallbackEnabled,
            preferredAudioEncoding: config.preferredAudioEncoding ?? previousConfig.preferredAudioEncoding,
            audioSampleRate: config.audioSampleRate ?? previousConfig.audioSampleRate,
            audioChannelCount: config.audioChannelCount ?? previousConfig.audioChannelCount,
            performanceValidationMode: config.performanceValidationMode ?? previousConfig.performanceValidationMode,
            mediaFallbackPolicy: config.mediaFallbackPolicy ?? previousConfig.mediaFallbackPolicy,
            streamRefreshToken: config.streamRefreshToken,
            sentAt: config.sentAt
        )
    }

    private static func hasUnchangedRealtimeAudioSemantics(
        _ config: RemoteDesktopStreamConfiguration,
        previous: RemoteDesktopStreamConfiguration
    ) -> Bool {
        func normalize(_ value: String?) -> String? {
            value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        return config.audioRedirectionEnabled == previous.audioRedirectionEnabled
            && normalize(config.audioTransport) == normalize(previous.audioTransport)
            && normalize(config.audioMode) == normalize(previous.audioMode)
            && config.nativeAudioTrackEnabled == previous.nativeAudioTrackEnabled
            && config.compatibilityAudioFallbackEnabled == previous.compatibilityAudioFallbackEnabled
            && normalize(config.preferredAudioEncoding) == normalize(previous.preferredAudioEncoding)
            && config.audioSampleRate == previous.audioSampleRate
            && config.audioChannelCount == previous.audioChannelCount
            && normalize(config.performanceValidationMode) == normalize(previous.performanceValidationMode)
            && normalize(config.mediaFallbackPolicy) == normalize(previous.mediaFallbackPolicy)
    }

    static func shouldUseWebRTCAudioFallback(
        audioRedirectionEnabled: Bool,
        nativeAudioTrackEnabled: Bool,
        legacyAudioFallbackEnabled: Bool = false
    ) -> Bool {
        audioRedirectionEnabled && !nativeAudioTrackEnabled && legacyAudioFallbackEnabled
    }

    static func shouldFailFastRemoteMediaFallbacks(
        remoteStreamConfiguration: RemoteDesktopStreamConfiguration?
    ) -> Bool {
        guard let remoteStreamConfiguration else { return false }
        return !remoteStreamConfiguration.isStopRequest
    }

    static func policyByEnforcingStrictMediaFrameRateFloor(
        _ policy: WebRTCRemoteDesktopVideoPolicy,
        remoteStreamConfiguration: RemoteDesktopStreamConfiguration?
    ) -> WebRTCRemoteDesktopVideoPolicy {
        guard let remoteStreamConfiguration,
              remoteStreamConfiguration.requiresExtremePerformanceValidation,
              policy.usesHardwareEncoder,
              policy.codec != .bgra else {
            return policy
        }

        let requestedFrameRate = max(1, min(remoteStreamConfiguration.targetFrameRate, 120))
        guard requestedFrameRate >= 59,
              policy.targetFrameRate < requestedFrameRate else {
            return policy
        }

        return WebRTCRemoteDesktopVideoPolicy(
            codec: policy.codec,
            targetFrameRate: requestedFrameRate,
            keyFrameInterval: min(policy.keyFrameInterval, max(10, requestedFrameRate * 2)),
            preferredSize: policy.preferredSize,
            usesHardwareEncoder: policy.usesHardwareEncoder,
            reason: "\(policy.reason)+strict-fps-floor"
        )
    }

    static func strictNativeVideoCodecFailureReason(
        _ codec: String?,
        requestedCodec: RemoteFrameType? = nil
    ) -> String? {
        let normalized = codec?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        guard !normalized.isEmpty, normalized != "-" else {
            return "native-video-codec-stats-unavailable"
        }
        if let requestedCodec {
            switch requestedCodec {
            case .hevc:
                guard normalized.contains("h265") || normalized.contains("hevc") else {
                    return "native-video-codec-mismatch-requested-hevc-actual-\(strictMediaReasonToken(normalized))"
                }
            case .h264:
                guard normalized.contains("h264") || normalized.contains("avc") else {
                    return "native-video-codec-mismatch-requested-h264-actual-\(strictMediaReasonToken(normalized))"
                }
            case .bgra:
                return "native-video-codec-mismatch-requested-bgra-actual-\(strictMediaReasonToken(normalized))"
            }
        }
        if normalized.contains("h264")
            || normalized.contains("avc")
            || normalized.contains("h265")
            || normalized.contains("hevc") {
            return nil
        }
        return "native-video-unacceptable-codec-\(strictMediaReasonToken(normalized))"
    }

    static func strictNativeVideoEncoderFailureReason(_ encoder: String?) -> String? {
        let normalized = encoder?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        guard !normalized.isEmpty, normalized != "-" else {
            return "native-video-encoder-stats-unavailable"
        }
        let softwareMarkers = ["libvpx", "openh264", "software", "ffmpeg", "x264", "x265"]
        if softwareMarkers.contains(where: { normalized.contains($0) }) {
            return "native-video-software-encoder-\(strictMediaReasonToken(normalized))"
        }
        return nil
    }

    static func nativeVideoNoRTPFailureGraceSeconds(
        failFastMediaFallbacks: Bool,
        codec: String?,
        encoder: String?,
        requestedCodec: RemoteFrameType? = nil
    ) -> TimeInterval {
        guard failFastMediaFallbacks,
              strictNativeVideoCodecFailureReason(codec, requestedCodec: requestedCodec) == nil,
              strictNativeVideoEncoderFailureReason(encoder) == nil else {
            return 2.0
        }
        return 6.0
    }

    static func strictNativeVideoNoRTPFailureReason(
        outboundStatsPresent: Bool,
        submittedFrames: UInt64,
        framesEncoded: UInt64,
        framesSent: UInt64,
        packetsSent: UInt64,
        bytesSent: UInt64
    ) -> String {
        if outboundStatsPresent, submittedFrames > 0, framesEncoded == 0 {
            return "native-video-encoder-no-output"
        }
        if framesEncoded > 0, framesSent == 0 {
            return "native-video-sender-no-frames-sent"
        }
        if framesSent > 0, packetsSent == 0 || bytesSent == 0 {
            return "native-video-rtp-packets-not-sent"
        }
        return "native-video-rtp-not-flowing"
    }

    private static func strictMediaReasonToken(_ value: String) -> String {
        let token = value.filter { character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
        }
        return token.isEmpty ? "unknown" : token
    }

    static func shouldUseWebRTCNativeAudio(
        audioRedirectionEnabled: Bool,
        remoteNativeAudioTrackEnabled: Bool,
        localNativeAudioTrackReady: Bool
    ) -> Bool {
        audioRedirectionEnabled && remoteNativeAudioTrackEnabled && localNativeAudioTrackReady
    }
}
