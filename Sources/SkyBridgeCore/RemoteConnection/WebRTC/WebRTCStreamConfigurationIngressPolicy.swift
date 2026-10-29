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
        enum CommitMode: Equatable {
            case none
            case afterAcknowledgement
            case exactStopWithoutAcknowledgement
        }

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
                    screenFrameTransport: screenFrameTransport,
                    framePresentationAckVersion: nil
                )
            }
        }

        let effectiveConfig: RemoteDesktopStreamConfiguration
        let transactionDecision: RemoteDesktopStreamConfigurationIngressDecision
        let commitMode: CommitMode
        let isExactStopRequest: Bool
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

    enum WebRTCStreamConfigurationIngressAcknowledgementPurpose: Equatable {
        case duplicate
        case commitAfterAcknowledgement
    }

    struct WebRTCStreamConfigurationIngressAcknowledgementAction: Equatable {
        let acknowledgement: WebRTCStreamConfigurationIngressPlan.Acknowledgement
        let purpose: WebRTCStreamConfigurationIngressAcknowledgementPurpose
    }

    enum WebRTCStreamConfigurationIngressCoordination: Equatable {
        case handled
        case rejected
        case acknowledgementRequired(WebRTCStreamConfigurationIngressAcknowledgementAction)
    }

    enum WebRTCStreamConfigurationIngressRejection: Equatable {
        case invalidTransaction(RemoteDesktopStreamConfigurationIngressDecision)
        case missingAcknowledgement
    }

    /// Coordinates the pre-ACK control flow shared by both WebRTC ingress paths.
    /// Exact stop commits synchronously here; every other applied configuration
    /// must leave as an explicit acknowledgement action before callers may commit.
    static func coordinateWebRTCStreamConfigurationIngress(
        _ plan: WebRTCStreamConfigurationIngressPlan,
        commitExactStop: () -> Void,
        reject: (WebRTCStreamConfigurationIngressRejection) -> Void
    ) -> WebRTCStreamConfigurationIngressCoordination {
        switch plan.transactionDecision {
        case .rejectMissingTransaction, .rejectConflictingDuplicate:
            reject(.invalidTransaction(plan.transactionDecision))
            return .rejected
        case .acknowledgeDuplicate:
            guard !plan.isExactStopRequest else {
                return .handled
            }
            guard plan.shouldSendAcknowledgement,
                  let acknowledgement = plan.acknowledgement else {
                reject(.missingAcknowledgement)
                return .rejected
            }
            return .acknowledgementRequired(
                .init(
                    acknowledgement: acknowledgement,
                    purpose: .duplicate
                )
            )
        case .apply:
            switch plan.commitMode {
            case .exactStopWithoutAcknowledgement:
                guard plan.isExactStopRequest,
                      plan.shouldStopScreenStreaming,
                      !plan.shouldSendAcknowledgement,
                      plan.acknowledgement == nil else {
                    reject(.missingAcknowledgement)
                    return .rejected
                }
                commitExactStop()
                return .handled
            case .afterAcknowledgement:
                guard !plan.isExactStopRequest,
                      plan.shouldSendAcknowledgement,
                      let acknowledgement = plan.acknowledgement else {
                    reject(.missingAcknowledgement)
                    return .rejected
                }
                return .acknowledgementRequired(
                    .init(
                        acknowledgement: acknowledgement,
                        purpose: .commitAfterAcknowledgement
                    )
                )
            case .none:
                reject(.missingAcknowledgement)
                return .rejected
            }
        }
    }

    static func planWebRTCStreamConfigurationIngress(
        _ config: RemoteDesktopStreamConfiguration,
        previousConfig: RemoteDesktopStreamConfiguration?,
        previousRawConfig: RemoteDesktopStreamConfiguration? = nil,
        advertisedFormats: Set<String>,
        hasSessionKeys: Bool
    ) -> WebRTCStreamConfigurationIngressPlan {
        let isExactStopRequest = config.screenFrameTransport == "stopped"
            && config.audioRedirectionEnabled == false
        let transactionDecision = RemoteDesktopStreamConfigurationTransactionPolicy
            .ingressDecision(
                incoming: config.streamConfigurationTransaction,
                lastAccepted: previousRawConfig?.streamConfigurationTransaction,
                payloadMatchesLastAccepted: previousRawConfig == config
            )
        if transactionDecision != .apply {
            let effectiveConfig = previousConfig ?? config
            let acknowledgement: WebRTCStreamConfigurationIngressPlan.Acknowledgement?
            // The viewer retires its stream-configuration ACK owner before it
            // sends exact stop. Replaying that already-committed stop remains a
            // no-op and must not introduce an ACK the sender cannot correlate.
            if transactionDecision == .acknowledgeDuplicate,
               !isExactStopRequest,
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
                commitMode: .none,
                isExactStopRequest: isExactStopRequest,
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
        if isExactStopRequest {
            return WebRTCStreamConfigurationIngressPlan(
                effectiveConfig: config,
                transactionDecision: .apply,
                commitMode: .exactStopWithoutAcknowledgement,
                isExactStopRequest: true,
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
            commitMode: .afterAcknowledgement,
            isExactStopRequest: false,
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
