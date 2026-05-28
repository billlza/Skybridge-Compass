import Foundation
import SkyBridgeRealtimeMedia

@available(iOS 17.0, *)
enum RemoteDesktopViewerStreamConfigurationFactory {
    struct Input {
        let viewerSettings: RemoteDesktopViewerSettings
        let supportedVideoFormats: [String]
        let preferredCodec: String?
        let activeTransportMode: RemoteDesktopManager.ActiveTransportMode
        let strictMediaValidationEnabled: Bool
        let hasRenderedCrossNetworkNativeFrame: Bool
        let nativeAudioReceiveEnabled: Bool
        let realtimeMediaAudioMode: SkyBridgeMediaAudioMode
        let mediaAudioEndpoint: SkyBridgeMediaEndpoint?
        let mediaSessionId: String?
        let streamRefreshToken: UInt64?
        let securityIdentity: RemoteDesktopSecurityIdentityPayload?
        let smokeDimensions: (width: Int, height: Int)?
        let smokeTargetFrameRate: Int?
    }

    static func stopPayload() -> RemoteDesktopStreamConfigurationPayload {
        RemoteDesktopStreamConfigurationPayload(
            supportedVideoFormats: [],
            targetFrameRate: 0,
            keyFrameInterval: 0,
            lowLatencyMode: false,
            enableHardwareAcceleration: false,
            enableAppleSiliconOptimization: false,
            clipboardSyncEnabled: false,
            damageTrackingEnabled: false,
            separateCursorChannelEnabled: false,
            interactionOverlayChannelEnabled: false,
            refreshStrategy: "stop",
            jitterBufferFrames: 0,
            lossRecoveryMode: "stop",
            screenFrameTransport: "stopped",
            screenDataChannelEnabled: false,
            nativeVideoTrackReady: false,
            nativeAudioTrackEnabled: false,
            audioRedirectionEnabled: false,
            audioTransport: "disabled",
            audioMode: nil,
            compatibilityAudioFallbackEnabled: false,
            preferredAudioEncoding: nil,
            audioSampleRate: nil,
            audioChannelCount: nil,
            streamRefreshToken: nil
        )
    }

    static func makePayload(_ input: Input) -> RemoteDesktopStreamConfigurationPayload {
        let viewerSettings = input.viewerSettings
        let supportedFormats = input.supportedVideoFormats
        let preferredCodec = input.preferredCodec
        let activeTransportMode = input.activeTransportMode
        let strictMediaValidationEnabled = input.strictMediaValidationEnabled
        let realtimeMediaAudioMode = input.realtimeMediaAudioMode
        let transportTuning = viewerSettings.transportTuning
        let strictVideoMainPathFormats = ["hevc"]
        let advertisedSupportedFormats = strictMediaValidationEnabled ? strictVideoMainPathFormats : supportedFormats
        let advertisedPreferredCodec = strictMediaValidationEnabled ? "hevc" : preferredCodec
        let smokeDimensions = input.smokeDimensions
        let dimensions = smokeDimensions ?? viewerSettings.resolution.dimensions
        let targetFrameRate = input.smokeTargetFrameRate ?? viewerSettings.targetFrameRate
        let videoLowLatencyMode = viewerSettings.lowLatencyMode || strictMediaValidationEnabled
        let keyFrameInterval = keyFrameInterval(
            strictMediaValidationEnabled: strictMediaValidationEnabled,
            videoLowLatencyMode: videoLowLatencyMode,
            targetFrameRate: targetFrameRate
        )

        return RemoteDesktopStreamConfigurationPayload(
            width: dimensions?.width,
            height: dimensions?.height,
            preferredCodec: advertisedPreferredCodec,
            supportedVideoFormats: advertisedSupportedFormats,
            qualityPreset: transportTuning.qualityPresetWireValue,
            adaptiveResolutionEnabled: smokeDimensions == nil && viewerSettings.resolution == .auto,
            targetFrameRate: targetFrameRate,
            keyFrameInterval: keyFrameInterval,
            lowLatencyMode: videoLowLatencyMode,
            enableHardwareAcceleration: true,
            enableAppleSiliconOptimization: true,
            clipboardSyncEnabled: viewerSettings.clipboardSyncEnabled,
            damageTrackingEnabled: strictMediaValidationEnabled ? false : transportTuning.damageTrackingEnabled,
            separateCursorChannelEnabled: transportTuning.separateCursorChannelEnabled,
            interactionOverlayChannelEnabled: transportTuning.interactionOverlayChannelEnabled,
            refreshStrategy: transportTuning.refreshStrategy,
            jitterBufferFrames: transportTuning.jitterBufferFrames,
            lossRecoveryMode: transportTuning.lossRecoveryMode,
            screenFrameTransport: activeTransportMode == .crossNetwork
                ? "webrtc-native-main"
                : "sbrf-v1",
            screenDataChannelEnabled: activeTransportMode != .crossNetwork,
            screenChannelWireFormat: activeTransportMode == .crossNetwork || activeTransportMode == .lan
                ? "sbc2-chunked-v1"
                : nil,
            nativeVideoTrackReady: activeTransportMode == .crossNetwork
                ? input.hasRenderedCrossNetworkNativeFrame
                : nil,
            // Keep iOS viewer on the transport-owned fallback audio path for now.
            // Native WebRTC audio on iOS still competes for AVAudioSession ownership
            // during startup and has been causing crashy/privacy-sensitive behavior.
            nativeAudioTrackEnabled: input.nativeAudioReceiveEnabled,
            audioRedirectionEnabled: viewerSettings.audioRedirectionEnabled,
            audioTransport: viewerSettings.audioRedirectionEnabled ? "pqc-media-v1" : "disabled",
            audioMode: realtimeMediaAudioMode.rawValue,
            mediaSessionId: input.mediaSessionId,
            mediaAudioEndpoint: input.mediaAudioEndpoint,
            compatibilityAudioFallbackEnabled: false,
            preferredAudioEncoding: nil,
            audioSampleRate: 48_000,
            audioChannelCount: 2,
            performanceValidationMode: strictMediaValidationEnabled ? "extreme" : nil,
            mediaFallbackPolicy: activeTransportMode == .crossNetwork ? "forbidden" : "fail-fast",
            streamRefreshToken: input.streamRefreshToken,
            remoteControlSecurityIdentity: input.securityIdentity?.isEmpty == true ? nil : input.securityIdentity
        )
    }

    private static func keyFrameInterval(
        strictMediaValidationEnabled: Bool,
        videoLowLatencyMode: Bool,
        targetFrameRate: Int
    ) -> Int {
        if strictMediaValidationEnabled {
            return max(60, targetFrameRate)
        }
        if videoLowLatencyMode {
            return max(15, targetFrameRate / 2)
        }
        return max(30, targetFrameRate)
    }
}
