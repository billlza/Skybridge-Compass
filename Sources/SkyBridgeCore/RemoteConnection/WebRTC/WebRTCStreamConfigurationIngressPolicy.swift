import Foundation

extension CrossNetworkConnectionManager {
    struct WebRTCStreamConfigurationIngressPlan: Equatable {
        struct Acknowledgement: Equatable {
            let streamRefreshToken: UInt64?
            let audioEndpointPresent: Bool
            let screenFrameTransport: String?

            func payload(acceptedAt: TimeInterval) -> RemoteDesktopStreamConfigurationAckWire {
                RemoteDesktopStreamConfigurationAckWire(
                    acceptedAt: acceptedAt,
                    streamRefreshToken: streamRefreshToken,
                    audioEndpointPresent: audioEndpointPresent,
                    screenFrameTransport: screenFrameTransport
                )
            }
        }

        let effectiveConfig: RemoteDesktopStreamConfiguration
        let remoteVideoFormats: Set<String>
        let isStopRequest: Bool
        let shouldStopScreenStreaming: Bool
        let shouldClearPendingStreamRefresh: Bool
        let shouldClearAwaitingStreamConfiguration: Bool
        let shouldEnsureScreenDataChannel: Bool
        let shouldConfigureClipboard: Bool
        let shouldSendAcknowledgement: Bool
        let shouldMarkPendingStreamRefresh: Bool
        let shouldStartScreenStreamingIfNeeded: Bool
        let pendingRefreshTokenChanged: Bool
        let audioEndpointPreservedForVideoRefresh: Bool
        let acknowledgement: Acknowledgement?
    }

    static func planWebRTCStreamConfigurationIngress(
        _ config: RemoteDesktopStreamConfiguration,
        previousConfig: RemoteDesktopStreamConfiguration?,
        advertisedFormats: Set<String>,
        hasSessionKeys: Bool
    ) -> WebRTCStreamConfigurationIngressPlan {
        let shouldStopScreenStreaming = config.screenFrameTransport == "stopped"
            && config.audioRedirectionEnabled == false
        if shouldStopScreenStreaming {
            return WebRTCStreamConfigurationIngressPlan(
                effectiveConfig: config,
                remoteVideoFormats: [],
                isStopRequest: config.isStopRequest,
                shouldStopScreenStreaming: true,
                shouldClearPendingStreamRefresh: true,
                shouldClearAwaitingStreamConfiguration: true,
                shouldEnsureScreenDataChannel: false,
                shouldConfigureClipboard: true,
                shouldSendAcknowledgement: false,
                shouldMarkPendingStreamRefresh: false,
                shouldStartScreenStreamingIfNeeded: false,
                pendingRefreshTokenChanged: false,
                audioEndpointPreservedForVideoRefresh: false,
                acknowledgement: nil
            )
        }

        let effectiveConfig = streamConfigurationByPreservingAudioEndpointForVideoRefresh(
            config,
            previousConfig: previousConfig
        )
        let pendingRefreshTokenChanged = effectiveConfig.streamRefreshToken != previousConfig?.streamRefreshToken
        let acknowledgement = hasSessionKeys
            ? WebRTCStreamConfigurationIngressPlan.Acknowledgement(
                streamRefreshToken: effectiveConfig.streamRefreshToken,
                audioEndpointPresent: effectiveConfig.mediaAudioEndpoint != nil,
                screenFrameTransport: effectiveConfig.screenFrameTransport
            )
            : nil

        return WebRTCStreamConfigurationIngressPlan(
            effectiveConfig: effectiveConfig,
            remoteVideoFormats: WebRTCRemoteDesktopVideoFormatPolicy.effectiveRemoteVideoFormats(
                advertisedFormats: advertisedFormats,
                streamConfiguration: effectiveConfig
            ),
            isStopRequest: config.isStopRequest,
            shouldStopScreenStreaming: false,
            shouldClearPendingStreamRefresh: false,
            shouldClearAwaitingStreamConfiguration: true,
            shouldEnsureScreenDataChannel: effectiveConfig.screenDataChannelEnabled == true,
            shouldConfigureClipboard: true,
            shouldSendAcknowledgement: acknowledgement != nil,
            shouldMarkPendingStreamRefresh: pendingRefreshTokenChanged,
            shouldStartScreenStreamingIfNeeded: hasSessionKeys,
            pendingRefreshTokenChanged: pendingRefreshTokenChanged,
            audioEndpointPreservedForVideoRefresh: config.mediaAudioEndpoint == nil
                && effectiveConfig.mediaAudioEndpoint != nil
                && config.streamRefreshToken != nil,
            acknowledgement: acknowledgement
        )
    }
}
