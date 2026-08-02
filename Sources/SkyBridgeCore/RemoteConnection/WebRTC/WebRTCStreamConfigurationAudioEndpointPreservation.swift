// 流配置的纯变换：在“仅视频刷新”的配置更新中保留既有实时音频端点。
//
// 抽取自 RemoteConnection/WebRTC/WebRTCScreenStreamingPolicy.swift（macOS 屏幕串流宿主策略），
// 因为**入站侧**的 WebRTCStreamConfigurationIngressPolicy 是跨平台的：它处理对端送来的配置更新，
// 与本机是否具备屏幕捕获能力无关。函数本身只读写 RemoteDesktopStreamConfiguration，没有平台依赖。
//
// 已知重复：RemoteControl/RemoteControlStreamRequestPolicy.swift 里还有一份同名实现
// （作用于 RemoteControlStreamRequestPolicy 类型）。合并这两份属于后续清理，本次不动，
// 以免把 macOS 宿主策略的语义改动混进可移植性改造。

import Foundation

extension CrossNetworkConnectionManager {
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
}
