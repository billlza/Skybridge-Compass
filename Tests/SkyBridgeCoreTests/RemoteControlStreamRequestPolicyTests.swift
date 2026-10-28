import XCTest
import SkyBridgeRealtimeMedia
import SkyBridgeProtocolCore
@testable import SkyBridgeCore

final class RemoteControlStreamRequestPolicyTests: XCTestCase {
    func testRequestUsesViewerConfigAndPreservesStrictExactVisibleSize() {
        var settings = DisplaySettings()
        settings.preferredCodec = .hevc
        settings.targetFrameRate = 60
        settings.keyFrameInterval = 60

        let config = streamConfiguration(
            width: 2056,
            height: 1329,
            preferredCodec: "h264",
            adaptiveResolutionEnabled: false,
            performanceValidationMode: "strict-extreme"
        )

        let request = RemoteControlStreamRequestPolicy.request(
            streamConfiguration: config,
            settings: settings,
            nativeDisplaySize: CGSize(width: 6016, height: 3384),
            isAppleSiliconRuntime: true
        )

        XCTAssertEqual(request.preferredSize, CGSize(width: 2056, height: 1329))
        XCTAssertEqual(request.preferredCodec, .h264)
        XCTAssertTrue(request.preserveExactVisibleSize)
    }

    func testRequestClampsFrameRateAndKeyFrameInterval() {
        var settings = DisplaySettings()
        settings.targetFrameRate = 240
        settings.keyFrameInterval = 500

        let request = RemoteControlStreamRequestPolicy.request(
            streamConfiguration: nil,
            settings: settings,
            nativeDisplaySize: CGSize(width: 1920, height: 1080),
            isAppleSiliconRuntime: true
        )

        XCTAssertEqual(request.targetFrameRate, 120)
        XCTAssertEqual(request.keyFrameInterval, 240)
    }

    func testBackgroundBudgetReachesCaptureAtTwoFramesPerSecond() {
        let budget = ControlledHostSessionPolicy.budget(
            for: .background,
            requestedFrameRate: 60,
            requestedAudio: true
        )
        let config = streamConfiguration(
            width: 1280,
            height: 720,
            targetFrameRate: budget.targetFrameRate
        )
        let request = RemoteControlStreamRequestPolicy.request(
            streamConfiguration: config,
            settings: DisplaySettings(),
            nativeDisplaySize: CGSize(width: 6016, height: 3384),
            isAppleSiliconRuntime: true
        )
        let policy = RemoteControlStreamPolicySelector.select(
            request: request,
            peerFormats: ["h264", "hevc", "jpeg"],
            thermalState: .nominal,
            isAppleSilicon: true
        )

        XCTAssertEqual(request.targetFrameRate, 2)
        XCTAssertEqual(policy.targetFrameRate, 2)
        XCTAssertEqual(policy.preferredSize, CGSize(width: 1280, height: 720))
    }

    func testFocusedAutoSizeRemainsAutomaticAndBackgroundHasAnExplicitCap() {
        XCTAssertNil(RemoteControlStreamRequestPolicy.viewerCaptureSize(for: .focused, requestedSize: nil))
        XCTAssertEqual(
            RemoteControlStreamRequestPolicy.viewerCaptureSize(for: .background, requestedSize: nil),
            CGSize(width: 1280, height: 720)
        )
        let explicitSize = CGSize(width: 6016, height: 3384)
        XCTAssertEqual(
            RemoteControlStreamRequestPolicy.viewerCaptureSize(for: .focused, requestedSize: explicitSize),
            explicitSize
        )
    }

    func testBackgroundSizePreservesPortraitAspectAndNeverUpscales() {
        XCTAssertEqual(
            RemoteControlStreamRequestPolicy.viewerCaptureSize(
                for: .background,
                requestedSize: CGSize(width: 1080, height: 1920)
            ),
            CGSize(width: 405, height: 720)
        )
        let smallSize = CGSize(width: 640, height: 360)
        XCTAssertEqual(
            RemoteControlStreamRequestPolicy.viewerCaptureSize(for: .background, requestedSize: smallSize),
            smallSize
        )
    }

    func testStreamAcknowledgementRequiresExactTransactionAndMediaSemantics() {
        let transaction = RemoteDesktopStreamConfigurationTransaction()
        let config = streamConfiguration(streamConfigurationTransaction: transaction)
        func receipt(
            acceptedAt: TimeInterval = 1,
            transaction: RemoteDesktopStreamConfigurationTransaction,
            refreshToken: UInt64? = nil,
            audioEndpointPresent: Bool = false,
            transport: String? = nil
        ) -> RemoteDesktopStreamConfigurationAcknowledgement {
            RemoteDesktopStreamConfigurationAcknowledgement(
                acceptedAt: acceptedAt,
                transaction: transaction,
                streamRefreshToken: refreshToken,
                audioEndpointPresent: audioEndpointPresent,
                screenFrameTransport: transport
            )
        }
        let matching = receipt(transaction: transaction)
        XCTAssertTrue(RemoteControlStreamRequestPolicy.acknowledgement(matching, matches: config))

        let invalidReceipts = [
            receipt(transaction: RemoteDesktopStreamConfigurationTransaction()),
            receipt(acceptedAt: .nan, transaction: transaction),
            receipt(acceptedAt: 0, transaction: transaction),
            receipt(transaction: transaction, refreshToken: 99),
            receipt(transaction: transaction, audioEndpointPresent: true),
            receipt(transaction: transaction, transport: "other-transport"),
        ]
        for receipt in invalidReceipts {
            XCTAssertFalse(RemoteControlStreamRequestPolicy.acknowledgement(receipt, matches: config))
        }
        XCTAssertFalse(
            RemoteControlStreamRequestPolicy.acknowledgement(matching, matches: streamConfiguration()),
            "A receipt cannot validate a request that never identified its transaction."
        )
    }

    @MainActor
    func testDuplicateCommittedReceiptCannotCompleteThePendingReplacement() throws {
        let previousTransaction = RemoteDesktopStreamConfigurationTransaction()
        let pendingTransaction = RemoteDesktopStreamConfigurationTransaction()
        let manager = RemoteControlManager(controlledHostStreamTier: .background)
        manager.testingSetViewerStreamConfigurations(
            pending: streamConfiguration(streamConfigurationTransaction: pendingTransaction),
            committed: streamConfiguration(streamConfigurationTransaction: previousTransaction)
        )
        let previousReceipt = RemoteDesktopStreamConfigurationAcknowledgement(
            acceptedAt: 1,
            transaction: previousTransaction,
            streamRefreshToken: nil,
            audioEndpointPresent: false,
            screenFrameTransport: nil
        )
        try manager.testingAcceptViewerStreamAcknowledgement(previousReceipt)
        XCTAssertNil(manager.testingAcknowledgedViewerStreamTransaction)

        let pendingReceipt = RemoteDesktopStreamConfigurationAcknowledgement(
            acceptedAt: 2,
            transaction: pendingTransaction,
            streamRefreshToken: nil,
            audioEndpointPresent: false,
            screenFrameTransport: nil
        )
        try manager.testingAcceptViewerStreamAcknowledgement(pendingReceipt)
        XCTAssertEqual(manager.testingAcknowledgedViewerStreamTransaction, pendingTransaction)
    }

    @MainActor
    func testUnexpectedReceiptFailsWithoutCommittingAnyConfiguration() {
        let manager = RemoteControlManager(controlledHostStreamTier: .background)
        manager.testingSetViewerStreamConfigurations(
            pending: streamConfiguration(streamConfigurationTransaction: RemoteDesktopStreamConfigurationTransaction())
        )
        let unrelatedReceipt = RemoteDesktopStreamConfigurationAcknowledgement(
            acceptedAt: 1,
            transaction: RemoteDesktopStreamConfigurationTransaction(),
            streamRefreshToken: nil,
            audioEndpointPresent: false,
            screenFrameTransport: nil
        )
        XCTAssertThrowsError(try manager.testingAcceptViewerStreamAcknowledgement(unrelatedReceipt)) { error in
            XCTAssertEqual(error as? ControlledHostSessionError, .invalidStreamConfigurationAcknowledgement)
        }
        XCTAssertNil(manager.testingAcknowledgedViewerStreamTransaction)
    }

    func testAdaptiveCaptureSizeUsesLowLatencyAndHardwareHeadroom() {
        let lowLatency = RemoteControlStreamRequestPolicy.adaptiveCaptureSizeForDirectDisplay(
            preferredCodec: .hevc,
            lowLatencyMode: true,
            enableHardwareAcceleration: true,
            enableAppleSiliconOptimization: true,
            nativeDisplaySize: CGSize(width: 6016, height: 3384),
            isAppleSiliconRuntime: true
        )
        XCTAssertEqual(lowLatency.width, 1920)
        XCTAssertEqual(lowLatency.height, 1080)

        let highFidelity = RemoteControlStreamRequestPolicy.adaptiveCaptureSizeForDirectDisplay(
            preferredCodec: .hevc,
            lowLatencyMode: false,
            enableHardwareAcceleration: true,
            enableAppleSiliconOptimization: true,
            nativeDisplaySize: CGSize(width: 6016, height: 3384),
            isAppleSiliconRuntime: true
        )
        XCTAssertEqual(highFidelity.width, 3200)
        XCTAssertEqual(highFidelity.height, 1800)
    }

    func testCaptureRestartIgnoresRefreshTokenOnlyButRestartsForStructuralChanges() {
        let endpoint = SkyBridgeMediaEndpoint(host: "127.0.0.1", port: 55_560)
        let previous = streamConfiguration(
            width: 1920,
            height: 1080,
            mediaAudioEndpoint: endpoint,
            streamRefreshToken: 1
        )
        let refreshOnly = streamConfiguration(
            width: 1920,
            height: 1080,
            mediaAudioEndpoint: endpoint,
            streamRefreshToken: 2
        )
        XCTAssertFalse(
            RemoteControlStreamRequestPolicy.shouldRestartCapture(
                previous: previous,
                current: refreshOnly
            )
        )

        XCTAssertTrue(
            RemoteControlStreamRequestPolicy.shouldRestartCapture(
                previous: previous,
                current: streamConfiguration(width: 2056, height: 1080, mediaAudioEndpoint: endpoint)
            )
        )
        XCTAssertTrue(
            RemoteControlStreamRequestPolicy.shouldRestartCapture(
                previous: previous,
                current: streamConfiguration(width: 1920, height: 1080, preferredCodec: "hevc", mediaAudioEndpoint: endpoint)
            )
        )
        XCTAssertTrue(
            RemoteControlStreamRequestPolicy.shouldRestartCapture(
                previous: previous,
                current: streamConfiguration(width: 1920, height: 1080, targetFrameRate: 30, mediaAudioEndpoint: endpoint)
            )
        )
        XCTAssertTrue(
            RemoteControlStreamRequestPolicy.shouldRestartCapture(
                previous: previous,
                current: streamConfiguration(
                    width: 1920,
                    height: 1080,
                    mediaAudioEndpoint: SkyBridgeMediaEndpoint(host: "127.0.0.1", port: 55_561)
                )
            )
        )
    }

    func testVideoRefreshWithoutEndpointPreservesRealtimeAudioEndpoint() {
        let endpoint = SkyBridgeMediaEndpoint(host: "127.0.0.1", port: 55_560)
        let previous = streamConfiguration(
            width: 2056,
            height: 1328,
            mediaAudioEndpoint: endpoint,
            streamRefreshToken: 10
        )
        let refresh = streamConfiguration(
            width: 2056,
            height: 1328,
            audioRedirectionEnabled: true,
            mediaAudioEndpoint: nil,
            mediaSessionId: nil,
            streamRefreshToken: 11
        )

        let effective = RemoteControlStreamRequestPolicy
            .streamConfigurationByPreservingAudioEndpointForVideoRefresh(
                refresh,
                previous: previous
            )

        XCTAssertEqual(effective.mediaAudioEndpoint, endpoint)
        XCTAssertEqual(effective.mediaSessionId, previous.mediaSessionId)
        XCTAssertFalse(
            RemoteControlStreamRequestPolicy.shouldRestartCapture(
                previous: previous,
                current: effective
            )
        )
    }

    func testVideoRefreshDoesNotPreserveAudioEndpointWhenAudioSemanticsChange() {
        let endpoint = SkyBridgeMediaEndpoint(host: "127.0.0.1", port: 55_560)
        let previous = streamConfiguration(
            width: 2056,
            height: 1328,
            mediaAudioEndpoint: endpoint,
            streamRefreshToken: 10
        )
        let refresh = streamConfiguration(
            width: 2056,
            height: 1328,
            audioRedirectionEnabled: true,
            audioMode: SkyBridgeMediaAudioMode.lowLatency.rawValue,
            mediaAudioEndpoint: nil,
            mediaSessionId: nil,
            streamRefreshToken: 11
        )

        let effective = RemoteControlStreamRequestPolicy
            .streamConfigurationByPreservingAudioEndpointForVideoRefresh(
                refresh,
                previous: previous
            )

        XCTAssertNil(effective.mediaAudioEndpoint)
    }

    private func streamConfiguration(
        width: Int? = nil,
        height: Int? = nil,
        preferredCodec: String? = "h264",
        adaptiveResolutionEnabled: Bool? = false,
        targetFrameRate: Int = 60,
        keyFrameInterval: Int = 60,
        performanceValidationMode: String? = nil,
        audioRedirectionEnabled: Bool? = nil,
        audioMode: String? = nil,
        mediaAudioEndpoint: SkyBridgeMediaEndpoint? = nil,
        mediaSessionId: String? = "media-session",
        streamRefreshToken: UInt64? = nil,
        streamConfigurationTransaction: RemoteDesktopStreamConfigurationTransaction? = nil
    ) -> RemoteDesktopStreamConfiguration {
        let requestsAudio = audioRedirectionEnabled ?? (mediaAudioEndpoint != nil)
        return RemoteDesktopStreamConfiguration(
            width: width,
            height: height,
            preferredCodec: preferredCodec,
            supportedVideoFormats: ["h264", "hevc", "jpeg"],
            adaptiveResolutionEnabled: adaptiveResolutionEnabled,
            targetFrameRate: targetFrameRate,
            keyFrameInterval: keyFrameInterval,
            lowLatencyMode: false,
            enableHardwareAcceleration: true,
            enableAppleSiliconOptimization: true,
            clipboardSyncEnabled: true,
            separateCursorChannelEnabled: true,
            audioRedirectionEnabled: requestsAudio,
            audioTransport: requestsAudio ? SkyBridgeRealtimeMediaConstants.audioTransportPQCv1 : nil,
            audioMode: requestsAudio ? (audioMode ?? SkyBridgeMediaAudioMode.highFidelity.rawValue) : nil,
            mediaSessionId: requestsAudio ? mediaSessionId : nil,
            mediaAudioEndpoint: mediaAudioEndpoint,
            performanceValidationMode: performanceValidationMode,
            streamRefreshToken: streamRefreshToken,
            streamConfigurationTransaction: streamConfigurationTransaction
        )
    }
}
