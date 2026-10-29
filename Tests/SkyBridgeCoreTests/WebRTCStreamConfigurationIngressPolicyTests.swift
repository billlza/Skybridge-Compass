import XCTest
import SkyBridgeProtocolCore
import SkyBridgeRealtimeMedia
@testable import SkyBridgeCore

final class WebRTCStreamConfigurationIngressPolicyTests: XCTestCase {
    @MainActor
    func testRemoteEffectsRequireCommittedActiveConfiguration() {
        XCTAssertFalse(
            CrossNetworkConnectionManager.allowsWebRTCCommittedRemoteControlEffect(
                .input,
                configuration: nil
            )
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.allowsWebRTCCommittedRemoteControlEffect(
                .clipboard,
                configuration: nil
            )
        )

        let stopped = streamConfiguration(
            targetFrameRate: 0,
            screenFrameTransport: "stopped",
            clipboardSyncEnabled: true,
            audioRedirectionEnabled: false
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.allowsWebRTCCommittedRemoteControlEffect(
                .input,
                configuration: stopped
            )
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.allowsWebRTCCommittedRemoteControlEffect(
                .clipboard,
                configuration: stopped
            )
        )
    }

    @MainActor
    func testCommittedConfigurationSeparatesInputAndClipboardAdmission() {
        let clipboardDisabled = streamConfiguration(clipboardSyncEnabled: false)
        XCTAssertTrue(
            CrossNetworkConnectionManager.allowsWebRTCCommittedRemoteControlEffect(
                .input,
                configuration: clipboardDisabled
            )
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.allowsWebRTCCommittedRemoteControlEffect(
                .clipboard,
                configuration: clipboardDisabled
            )
        )

        XCTAssertTrue(
            CrossNetworkConnectionManager.allowsWebRTCCommittedRemoteControlEffect(
                .clipboard,
                configuration: streamConfiguration(clipboardSyncEnabled: true)
            )
        )
    }

    @MainActor
    func testWebRTCRemoteControlSessionOwnerRequiresFullKeySnapshot() {
        let baseline = SessionKeys(
            sendKey: Data(repeating: 0x11, count: 32),
            receiveKey: Data(repeating: 0x22, count: 32),
            negotiatedSuite: .xwingMLDSA,
            role: .initiator,
            transcriptHash: Data(repeating: 0x33, count: 32),
            sessionId: "remote-config-session"
        )
        let exactCopy = SessionKeys(
            sendKey: baseline.sendKey,
            receiveKey: baseline.receiveKey,
            negotiatedSuite: baseline.negotiatedSuite,
            role: baseline.role,
            transcriptHash: baseline.transcriptHash,
            sessionId: baseline.sessionId
        )
        let rekeyed = SessionKeys(
            sendKey: Data(repeating: 0x44, count: 32),
            receiveKey: baseline.receiveKey,
            negotiatedSuite: baseline.negotiatedSuite,
            role: baseline.role,
            transcriptHash: Data(repeating: 0x55, count: 32),
            sessionId: baseline.sessionId
        )

        XCTAssertTrue(
            CrossNetworkConnectionManager.isSameWebRTCSecureSession(baseline, exactCopy)
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.isSameWebRTCSecureSession(baseline, rekeyed)
        )
    }

    @MainActor
    func testStopConfigurationPlansLocalShutdownWithoutAckOrRestart() {
        let previous = streamConfiguration(
            preferredCodec: "hevc",
            screenFrameTransport: "webrtc-native-main+sbrf-fallback",
            streamRefreshToken: 9
        )
        let stop = streamConfiguration(
            targetFrameRate: 0,
            screenFrameTransport: "stopped",
            audioRedirectionEnabled: false,
            streamRefreshToken: 10
        )

        let plan = CrossNetworkConnectionManager.planWebRTCStreamConfigurationIngress(
            stop,
            previousConfig: previous,
            advertisedFormats: ["hevc", "h264"],
            hasSessionKeys: true
        )

        XCTAssertEqual(plan.effectiveConfig, stop)
        XCTAssertEqual(plan.commitMode, .exactStopWithoutAcknowledgement)
        XCTAssertTrue(plan.isStopRequest)
        XCTAssertTrue(plan.shouldStopScreenStreaming)
        XCTAssertTrue(plan.shouldClearPendingStreamRefresh)
        XCTAssertTrue(plan.shouldClearAwaitingStreamConfiguration)
        XCTAssertTrue(plan.shouldConfigureClipboard)
        XCTAssertEqual(plan.remoteVideoFormats, [])
        XCTAssertFalse(plan.shouldEnsureScreenDataChannel)
        XCTAssertFalse(plan.shouldSendAcknowledgement)
        XCTAssertFalse(plan.shouldMarkPendingStreamRefresh)
        XCTAssertFalse(plan.shouldStartScreenStreamingIfNeeded)
        XCTAssertNil(plan.acknowledgement)
    }

    @MainActor
    func testWebRTCStopWireRoundTripCommitsExactStopWithoutAckAction() throws {
        let transaction = RemoteDesktopStreamConfigurationTransaction(
            id: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
        )
        let senderConfiguration = streamConfiguration(
            targetFrameRate: 0,
            screenFrameTransport: "stopped",
            audioRedirectionEnabled: false,
            streamConfigurationTransaction: transaction
        )
        let outboundMessage = RemoteMessageWire(
            type: .streamConfiguration,
            payload: try JSONEncoder().encode(senderConfiguration)
        )

        let inboundMessage = try JSONDecoder().decode(
            RemoteMessageWire.self,
            from: JSONEncoder().encode(outboundMessage)
        )
        let inboundConfiguration = try JSONDecoder().decode(
            RemoteDesktopStreamConfiguration.self,
            from: inboundMessage.payload
        )
        let hostPlan = CrossNetworkConnectionManager.planWebRTCStreamConfigurationIngress(
            inboundConfiguration,
            previousConfig: streamConfiguration(streamRefreshToken: 9),
            advertisedFormats: ["h264", "hevc"],
            hasSessionKeys: true
        )
        var events: [String] = []
        var rejections: [CrossNetworkConnectionManager.WebRTCStreamConfigurationIngressRejection] = []
        let coordination = CrossNetworkConnectionManager.coordinateWebRTCStreamConfigurationIngress(
            hostPlan,
            commitExactStop: {
                events.append("commit-exact-stop")
            },
            reject: { rejection in
                rejections.append(rejection)
            }
        )
        if case .acknowledgementRequired = coordination {
            events.append("acknowledgement-required")
        }

        XCTAssertEqual(inboundMessage.type.rawValue, RemoteMessageTypeWire.streamConfiguration.rawValue)
        XCTAssertEqual(inboundConfiguration.streamConfigurationTransaction, transaction)
        XCTAssertEqual(hostPlan.transactionDecision, .apply)
        XCTAssertEqual(hostPlan.commitMode, .exactStopWithoutAcknowledgement)
        XCTAssertTrue(hostPlan.shouldStopScreenStreaming)
        XCTAssertTrue(hostPlan.shouldClearPendingStreamRefresh)
        XCTAssertTrue(hostPlan.shouldClearAwaitingStreamConfiguration)
        XCTAssertFalse(hostPlan.shouldSendAcknowledgement)
        XCTAssertNil(hostPlan.acknowledgement)
        XCTAssertEqual(coordination, .handled)
        XCTAssertEqual(events, ["commit-exact-stop"])
        XCTAssertTrue(rejections.isEmpty)
    }

    @MainActor
    func testDuplicateExactStopIsIdempotentAndDoesNotIntroduceAckWireTraffic() {
        let transaction = RemoteDesktopStreamConfigurationTransaction(
            id: UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
        )
        let stopped = streamConfiguration(
            targetFrameRate: 0,
            screenFrameTransport: "stopped",
            audioRedirectionEnabled: false,
            streamConfigurationTransaction: transaction
        )

        let duplicatePlan = CrossNetworkConnectionManager.planWebRTCStreamConfigurationIngress(
            stopped,
            previousConfig: stopped,
            previousRawConfig: stopped,
            advertisedFormats: [],
            hasSessionKeys: true
        )
        var events: [String] = []
        var rejections: [CrossNetworkConnectionManager.WebRTCStreamConfigurationIngressRejection] = []
        let coordination = CrossNetworkConnectionManager.coordinateWebRTCStreamConfigurationIngress(
            duplicatePlan,
            commitExactStop: {
                events.append("commit-exact-stop")
            },
            reject: { rejection in
                rejections.append(rejection)
            }
        )
        if case .acknowledgementRequired = coordination {
            events.append("acknowledgement-required")
        }

        XCTAssertEqual(duplicatePlan.transactionDecision, .acknowledgeDuplicate)
        XCTAssertEqual(duplicatePlan.commitMode, .none)
        XCTAssertFalse(duplicatePlan.shouldStopScreenStreaming)
        XCTAssertFalse(duplicatePlan.shouldSendAcknowledgement)
        XCTAssertNil(duplicatePlan.acknowledgement)
        XCTAssertEqual(coordination, .handled)
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(rejections.isEmpty)
    }

    @MainActor
    func testExactStopCoordinatorRejectsMissingAndConflictingTransactionsWithoutCommit() {
        let transaction = RemoteDesktopStreamConfigurationTransaction(
            id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        )
        let accepted = streamConfiguration(
            streamConfigurationTransaction: transaction
        )
        let missingTransactionStop = streamConfiguration(
            targetFrameRate: 0,
            screenFrameTransport: "stopped",
            audioRedirectionEnabled: false,
            streamConfigurationTransaction: nil
        )
        let conflictingStop = streamConfiguration(
            targetFrameRate: 0,
            screenFrameTransport: "stopped",
            audioRedirectionEnabled: false,
            streamConfigurationTransaction: transaction
        )
        let cases: [(
            configuration: RemoteDesktopStreamConfiguration,
            expectedDecision: RemoteDesktopStreamConfigurationIngressDecision
        )] = [
            (missingTransactionStop, .rejectMissingTransaction),
            (conflictingStop, .rejectConflictingDuplicate)
        ]

        for testCase in cases {
            let plan = CrossNetworkConnectionManager.planWebRTCStreamConfigurationIngress(
                testCase.configuration,
                previousConfig: accepted,
                previousRawConfig: accepted,
                advertisedFormats: ["h264"],
                hasSessionKeys: true
            )
            var commitCount = 0
            var rejections: [CrossNetworkConnectionManager.WebRTCStreamConfigurationIngressRejection] = []
            let coordination = CrossNetworkConnectionManager.coordinateWebRTCStreamConfigurationIngress(
                plan,
                commitExactStop: {
                    commitCount += 1
                },
                reject: { rejection in
                    rejections.append(rejection)
                }
            )

            XCTAssertEqual(plan.transactionDecision, testCase.expectedDecision)
            XCTAssertEqual(coordination, .rejected)
            XCTAssertEqual(commitCount, 0)
            XCTAssertEqual(rejections, [.invalidTransaction(testCase.expectedDecision)])
        }
    }

    @MainActor
    func testNormalConfigurationCoordinatorRequiresAckBeforeCommitWithoutPrecommit() {
        let incoming = streamConfiguration(streamRefreshToken: 21)
        let plan = CrossNetworkConnectionManager.planWebRTCStreamConfigurationIngress(
            incoming,
            previousConfig: streamConfiguration(streamRefreshToken: 20),
            advertisedFormats: ["h264"],
            hasSessionKeys: true
        )
        var events: [String] = []
        var rejections: [CrossNetworkConnectionManager.WebRTCStreamConfigurationIngressRejection] = []
        let coordination = CrossNetworkConnectionManager.coordinateWebRTCStreamConfigurationIngress(
            plan,
            commitExactStop: {
                events.append("precommit")
            },
            reject: { rejection in
                rejections.append(rejection)
            }
        )

        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(rejections.isEmpty)
        switch coordination {
        case .handled:
            XCTFail("Normal configuration must require acknowledgement")
        case .rejected:
            XCTFail("Normal configuration must not be rejected")
        case .acknowledgementRequired(let action):
            XCTAssertEqual(action.purpose, .commitAfterAcknowledgement)
            XCTAssertEqual(action.acknowledgement.transaction, incoming.streamConfigurationTransaction)
            events.append("acknowledgement")
            events.append("commit")
        }
        XCTAssertEqual(events, ["acknowledgement", "commit"])
    }

    @MainActor
    func testStopLikeConfigurationThatMissesExactLegacyStopConditionKeepsNormalIngressPath() {
        let incoming = streamConfiguration(
            targetFrameRate: 0,
            screenFrameTransport: "webrtc-native-main+sbrf-fallback",
            audioRedirectionEnabled: false,
            streamRefreshToken: 11
        )

        let plan = CrossNetworkConnectionManager.planWebRTCStreamConfigurationIngress(
            incoming,
            previousConfig: streamConfiguration(streamRefreshToken: 10),
            advertisedFormats: ["h264"],
            hasSessionKeys: true
        )

        XCTAssertTrue(plan.isStopRequest)
        XCTAssertEqual(plan.commitMode, .afterAcknowledgement)
        XCTAssertFalse(plan.shouldStopScreenStreaming)
        XCTAssertFalse(plan.shouldClearPendingStreamRefresh)
        XCTAssertTrue(plan.shouldClearAwaitingStreamConfiguration)
        XCTAssertTrue(plan.shouldSendAcknowledgement)
        XCTAssertTrue(plan.shouldMarkPendingStreamRefresh)
        XCTAssertTrue(plan.shouldStartScreenStreamingIfNeeded)
    }

    @MainActor
    func testActiveConfigurationPlansAckScreenChannelAndStartAttempt() {
        let incoming = streamConfiguration(
            preferredCodec: "h264",
            supportedVideoFormats: ["hevc"],
            screenDataChannelEnabled: true,
            streamRefreshToken: 2
        )

        let plan = CrossNetworkConnectionManager.planWebRTCStreamConfigurationIngress(
            incoming,
            previousConfig: streamConfiguration(streamRefreshToken: 1),
            advertisedFormats: ["jpeg"],
            hasSessionKeys: true
        )

        XCTAssertEqual(plan.effectiveConfig, incoming)
        XCTAssertEqual(plan.commitMode, .afterAcknowledgement)
        XCTAssertEqual(plan.remoteVideoFormats, ["h264", "hevc", "jpeg"])
        XCTAssertFalse(plan.isStopRequest)
        XCTAssertFalse(plan.shouldStopScreenStreaming)
        XCTAssertFalse(plan.shouldClearPendingStreamRefresh)
        XCTAssertTrue(plan.shouldClearAwaitingStreamConfiguration)
        XCTAssertTrue(plan.shouldEnsureScreenDataChannel)
        XCTAssertTrue(plan.shouldConfigureClipboard)
        XCTAssertTrue(plan.shouldSendAcknowledgement)
        XCTAssertTrue(plan.shouldMarkPendingStreamRefresh)
        XCTAssertTrue(plan.pendingRefreshTokenChanged)
        XCTAssertTrue(plan.shouldStartScreenStreamingIfNeeded)

        let ack = plan.acknowledgement?.payload(acceptedAt: 1_770_000_000)
        XCTAssertEqual(ack?.acceptedAt, 1_770_000_000)
        XCTAssertEqual(ack?.transaction, incoming.streamConfigurationTransaction)
        XCTAssertEqual(ack?.streamRefreshToken, 2)
        XCTAssertFalse(ack?.audioEndpointPresent ?? true)
        XCTAssertEqual(ack?.screenFrameTransport, incoming.screenFrameTransport)
    }

    @MainActor
    func testRemoteVideoFormatsDropUnsupportedAdvertisedTokens() {
        let incoming = streamConfiguration(
            preferredCodec: "h264",
            supportedVideoFormats: ["vp9", "HEVC", "jpeg"],
            screenDataChannelEnabled: true,
            streamRefreshToken: 3
        )

        let plan = CrossNetworkConnectionManager.planWebRTCStreamConfigurationIngress(
            incoming,
            previousConfig: streamConfiguration(streamRefreshToken: 2),
            advertisedFormats: ["av1", "h264", "hevc", "path/escape"],
            hasSessionKeys: true
        )

        XCTAssertEqual(plan.remoteVideoFormats, ["h264", "hevc", "jpeg"])
    }

    @MainActor
    func testRefreshTokenRemovalStillMarksPendingRefreshLikeLegacyBranch() {
        let incoming = streamConfiguration(streamRefreshToken: nil)

        let plan = CrossNetworkConnectionManager.planWebRTCStreamConfigurationIngress(
            incoming,
            previousConfig: streamConfiguration(streamRefreshToken: 5),
            advertisedFormats: ["h264"],
            hasSessionKeys: true
        )

        XCTAssertTrue(plan.pendingRefreshTokenChanged)
        XCTAssertTrue(plan.shouldMarkPendingStreamRefresh)
        XCTAssertTrue(plan.shouldSendAcknowledgement)
        XCTAssertNil(plan.acknowledgement?.streamRefreshToken)
    }

    @MainActor
    func testVideoRefreshPreservesAudioEndpointAndReportsAckEndpointPresence() {
        let endpoint = SkyBridgeMediaEndpoint(
            host: "203.0.113.10",
            port: 34_789,
            relayToken: "relay-token",
            expiresAt: 1_770_000_010
        )
        let previous = streamConfiguration(
            audioRedirectionEnabled: true,
            audioTransport: SkyBridgeRealtimeMediaConstants.audioTransportPQCv1,
            audioMode: SkyBridgeMediaAudioMode.highFidelity.rawValue,
            mediaSessionId: "media-session",
            mediaAudioEndpoint: endpoint,
            streamRefreshToken: 41
        )
        let refresh = streamConfiguration(
            audioRedirectionEnabled: true,
            audioTransport: SkyBridgeRealtimeMediaConstants.audioTransportPQCv1,
            audioMode: SkyBridgeMediaAudioMode.highFidelity.rawValue,
            mediaAudioEndpoint: nil,
            streamRefreshToken: 42
        )

        let plan = CrossNetworkConnectionManager.planWebRTCStreamConfigurationIngress(
            refresh,
            previousConfig: previous,
            advertisedFormats: ["hevc"],
            hasSessionKeys: true
        )

        XCTAssertTrue(plan.audioEndpointPreservedForVideoRefresh)
        XCTAssertEqual(plan.effectiveConfig.mediaSessionId, "media-session")
        XCTAssertEqual(plan.effectiveConfig.mediaAudioEndpoint, endpoint)
        XCTAssertTrue(plan.acknowledgement?.audioEndpointPresent ?? false)
        XCTAssertTrue(plan.shouldMarkPendingStreamRefresh)
    }

    @MainActor
    func testMissingSessionKeysSuppressesAckAndStartButStillEnsuresScreenChannel() {
        let incoming = streamConfiguration(
            screenDataChannelEnabled: true,
            streamRefreshToken: 3
        )

        let plan = CrossNetworkConnectionManager.planWebRTCStreamConfigurationIngress(
            incoming,
            previousConfig: streamConfiguration(streamRefreshToken: 2),
            advertisedFormats: [],
            hasSessionKeys: false
        )

        XCTAssertTrue(plan.shouldEnsureScreenDataChannel)
        XCTAssertEqual(plan.commitMode, .afterAcknowledgement)
        XCTAssertFalse(plan.shouldSendAcknowledgement)
        XCTAssertFalse(plan.shouldStartScreenStreamingIfNeeded)
        XCTAssertNil(plan.acknowledgement)
        XCTAssertTrue(plan.shouldMarkPendingStreamRefresh)
    }

    @MainActor
    func testLogicalTransactionMakesDuplicateIdempotentAndConflictFailClosed() {
        let transaction = RemoteDesktopStreamConfigurationTransaction(
            id: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        )
        let accepted = streamConfiguration(
            preferredCodec: "hevc",
            streamRefreshToken: 12,
            streamConfigurationTransaction: transaction
        )

        let duplicate = CrossNetworkConnectionManager
            .planWebRTCStreamConfigurationIngress(
                accepted,
                previousConfig: accepted,
                previousRawConfig: accepted,
                advertisedFormats: ["hevc"],
                hasSessionKeys: true
            )
        XCTAssertEqual(duplicate.transactionDecision, .acknowledgeDuplicate)
        XCTAssertEqual(duplicate.commitMode, .none)
        XCTAssertTrue(duplicate.shouldSendAcknowledgement)
        XCTAssertEqual(duplicate.acknowledgement?.transaction, transaction)
        XCTAssertFalse(duplicate.shouldStartScreenStreamingIfNeeded)
        var duplicateCommitCount = 0
        var duplicateRejections: [CrossNetworkConnectionManager.WebRTCStreamConfigurationIngressRejection] = []
        let duplicateCoordination = CrossNetworkConnectionManager.coordinateWebRTCStreamConfigurationIngress(
            duplicate,
            commitExactStop: {
                duplicateCommitCount += 1
            },
            reject: { rejection in
                duplicateRejections.append(rejection)
            }
        )
        guard case .acknowledgementRequired(let duplicateAction) = duplicateCoordination else {
            XCTFail("An active duplicate must be acknowledged without recommitting")
            return
        }
        XCTAssertEqual(duplicateAction.purpose, .duplicate)
        XCTAssertEqual(duplicateAction.acknowledgement.transaction, transaction)
        XCTAssertEqual(duplicateCommitCount, 0)
        XCTAssertTrue(duplicateRejections.isEmpty)

        let conflicting = streamConfiguration(
            preferredCodec: "h264",
            streamRefreshToken: 13,
            streamConfigurationTransaction: transaction
        )
        let conflict = CrossNetworkConnectionManager
            .planWebRTCStreamConfigurationIngress(
                conflicting,
                previousConfig: accepted,
                previousRawConfig: accepted,
                advertisedFormats: ["h264"],
                hasSessionKeys: true
            )
        XCTAssertEqual(conflict.transactionDecision, .rejectConflictingDuplicate)
        XCTAssertEqual(conflict.commitMode, .none)
        XCTAssertFalse(conflict.shouldSendAcknowledgement)
        XCTAssertFalse(conflict.shouldStartScreenStreamingIfNeeded)

        let missing = streamConfiguration(
            streamConfigurationTransaction: nil
        )
        let missingPlan = CrossNetworkConnectionManager
            .planWebRTCStreamConfigurationIngress(
                missing,
                previousConfig: accepted,
                previousRawConfig: accepted,
                advertisedFormats: ["h264"],
                hasSessionKeys: true
            )
        XCTAssertEqual(missingPlan.transactionDecision, .rejectMissingTransaction)
        XCTAssertEqual(missingPlan.commitMode, .none)
    }

    private func streamConfiguration(
        preferredCodec: String? = "h264",
        supportedVideoFormats: [String] = ["h264"],
        targetFrameRate: Int = 60,
        screenFrameTransport: String? = "webrtc-native-main+sbrf-fallback",
        screenDataChannelEnabled: Bool? = false,
        clipboardSyncEnabled: Bool = true,
        audioRedirectionEnabled: Bool? = nil,
        audioTransport: String? = nil,
        audioMode: String? = nil,
        mediaSessionId: String? = nil,
        mediaAudioEndpoint: SkyBridgeMediaEndpoint? = nil,
        streamRefreshToken: UInt64? = nil,
        streamConfigurationTransaction: RemoteDesktopStreamConfigurationTransaction? = .init()
    ) -> RemoteDesktopStreamConfiguration {
        RemoteDesktopStreamConfiguration(
            preferredCodec: preferredCodec,
            supportedVideoFormats: supportedVideoFormats,
            targetFrameRate: targetFrameRate,
            keyFrameInterval: 60,
            lowLatencyMode: false,
            enableHardwareAcceleration: true,
            enableAppleSiliconOptimization: true,
            clipboardSyncEnabled: clipboardSyncEnabled,
            screenFrameTransport: screenFrameTransport,
            screenDataChannelEnabled: screenDataChannelEnabled,
            audioRedirectionEnabled: audioRedirectionEnabled,
            audioTransport: audioTransport,
            audioMode: audioMode,
            mediaSessionId: mediaSessionId,
            mediaAudioEndpoint: mediaAudioEndpoint,
            streamRefreshToken: streamRefreshToken,
            streamConfigurationTransaction: streamConfigurationTransaction,
            sentAt: 1_770_000_000
        )
    }
}
