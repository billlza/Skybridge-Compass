import Foundation
import SkyBridgeProtocolCore

extension CrossNetworkConnectionManager {
    enum WebRTCCommittedRemoteControlEffect: Sendable {
        case input
        case clipboard
    }

    /// Side effects from the viewer are admitted only after the host has sent the
    /// configuration acknowledgement and committed that exact configuration.
    /// Security-notice approval alone is intentionally insufficient.
    static func allowsWebRTCCommittedRemoteControlEffect(
        _ effect: WebRTCCommittedRemoteControlEffect,
        configuration: RemoteDesktopStreamConfiguration?
    ) -> Bool {
        guard let configuration, !configuration.isStopRequest else {
            return false
        }
        switch effect {
        case .input:
            return true
        case .clipboard:
            return configuration.clipboardSyncEnabled
        }
    }

    struct WebRTCStreamConfigurationIngressPlan: Equatable {
        struct Acknowledgement: Equatable {
            let transaction: RemoteDesktopStreamConfigurationTransaction
            let streamRefreshToken: UInt64?
            let audioEndpointPresent: Bool
            let screenFrameTransport: String?

            func payload(acceptedAt: TimeInterval) -> RemoteDesktopStreamConfigurationAcknowledgement {
                RemoteDesktopStreamConfigurationAcknowledgement(
                    acceptedAt: acceptedAt,
                    transaction: transaction,
                    streamRefreshToken: streamRefreshToken,
                    audioEndpointPresent: audioEndpointPresent,
                    screenFrameTransport: screenFrameTransport
                )
            }
        }

        let effectiveConfig: RemoteDesktopStreamConfiguration
        let transactionDecision: RemoteDesktopStreamConfigurationIngressDecision
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
        previousRawConfig: RemoteDesktopStreamConfiguration? = nil,
        advertisedFormats: Set<String>,
        hasSessionKeys: Bool
    ) -> WebRTCStreamConfigurationIngressPlan {
        let transactionDecision = RemoteDesktopStreamConfigurationTransactionPolicy
            .ingressDecision(
                incoming: config.streamConfigurationTransaction,
                lastAccepted: previousRawConfig?.streamConfigurationTransaction,
                payloadMatchesLastAccepted: previousRawConfig == config
            )
        if transactionDecision != .apply {
            let effectiveConfig = previousConfig ?? config
            let acknowledgement: WebRTCStreamConfigurationIngressPlan.Acknowledgement?
            if transactionDecision == .acknowledgeDuplicate,
               hasSessionKeys,
               let transaction = effectiveConfig.streamConfigurationTransaction {
                acknowledgement = .init(
                    transaction: transaction,
                    streamRefreshToken: effectiveConfig.streamRefreshToken,
                    audioEndpointPresent: effectiveConfig.mediaAudioEndpoint != nil,
                    screenFrameTransport: effectiveConfig.screenFrameTransport
                )
            } else {
                acknowledgement = nil
            }
            return WebRTCStreamConfigurationIngressPlan(
                effectiveConfig: effectiveConfig,
                transactionDecision: transactionDecision,
                remoteVideoFormats: [],
                isStopRequest: effectiveConfig.isStopRequest,
                shouldStopScreenStreaming: false,
                shouldClearPendingStreamRefresh: false,
                shouldClearAwaitingStreamConfiguration: false,
                shouldEnsureScreenDataChannel: false,
                shouldConfigureClipboard: false,
                shouldSendAcknowledgement: acknowledgement != nil,
                shouldMarkPendingStreamRefresh: false,
                shouldStartScreenStreamingIfNeeded: false,
                pendingRefreshTokenChanged: false,
                audioEndpointPreservedForVideoRefresh: false,
                acknowledgement: acknowledgement
            )
        }
        let shouldStopScreenStreaming = config.screenFrameTransport == "stopped"
            && config.audioRedirectionEnabled == false
        if shouldStopScreenStreaming {
            return WebRTCStreamConfigurationIngressPlan(
                effectiveConfig: config,
                transactionDecision: .apply,
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
            ? effectiveConfig.streamConfigurationTransaction.map { transaction in
                WebRTCStreamConfigurationIngressPlan.Acknowledgement(
                transaction: transaction,
                streamRefreshToken: effectiveConfig.streamRefreshToken,
                audioEndpointPresent: effectiveConfig.mediaAudioEndpoint != nil,
                screenFrameTransport: effectiveConfig.screenFrameTransport
                )
            }
            : nil

        return WebRTCStreamConfigurationIngressPlan(
            effectiveConfig: effectiveConfig,
            transactionDecision: .apply,
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
