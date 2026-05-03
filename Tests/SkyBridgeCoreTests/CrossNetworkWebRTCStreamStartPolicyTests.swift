import XCTest
@testable import SkyBridgeCore

final class CrossNetworkWebRTCStreamStartPolicyTests: XCTestCase {
    @MainActor
    func testScreenStreamingWaitsForViewerStreamConfiguration() {
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldStartWebRTCScreenStreaming(
                remoteStreamConfiguration: nil
            )
        )
    }

    @MainActor
    func testScreenStreamingStartsOnceViewerStreamConfigurationArrives() {
        let config = RemoteDesktopStreamConfiguration(
            preferredCodec: "h264",
            supportedVideoFormats: ["h264", "jpeg"],
            targetFrameRate: 30,
            keyFrameInterval: 30,
            lowLatencyMode: true,
            enableHardwareAcceleration: true,
            enableAppleSiliconOptimization: false,
            clipboardSyncEnabled: false,
            screenDataChannelEnabled: true
        )

        XCTAssertTrue(
            CrossNetworkConnectionManager.shouldStartWebRTCScreenStreaming(
                remoteStreamConfiguration: config
            )
        )
    }

    @MainActor
    func testScreenChannelRouteWaitsBrieflyThenFallsBackToControl() {
        let waiting = CrossNetworkConnectionManager.planWebRTCScreenChannelRoute(
            screenDataChannelEnabled: true,
            screenChannelWireFormat: RemoteDesktopStreamConfiguration.screenChannelWireFormatSBC2ChunkedV1,
            screenChannelOpen: false,
            waitElapsed: 0.25
        )
        XCTAssertEqual(waiting.state, "waiting")
        XCTAssertTrue(waiting.shouldWaitForScreenChannel)
        XCTAssertFalse(waiting.useDedicatedScreenChannel)
        XCTAssertFalse(waiting.allowsInteractionStreaming)

        let fallback = CrossNetworkConnectionManager.planWebRTCScreenChannelRoute(
            screenDataChannelEnabled: true,
            screenChannelWireFormat: RemoteDesktopStreamConfiguration.screenChannelWireFormatSBC2ChunkedV1,
            screenChannelOpen: false,
            waitElapsed: CrossNetworkConnectionManager.webRTCScreenChannelOpenGraceSeconds + 0.1
        )
        XCTAssertEqual(fallback.state, "failed-control-fallback")
        XCTAssertFalse(fallback.shouldWaitForScreenChannel)
        XCTAssertFalse(fallback.useDedicatedScreenChannel)
        XCTAssertFalse(fallback.useChunkedScreenWire)
        XCTAssertTrue(fallback.allowsInteractionStreaming)
    }

    @MainActor
    func testScreenChannelRouteUsesSBC2OnlyWhenDedicatedChannelIsOpen() {
        let open = CrossNetworkConnectionManager.planWebRTCScreenChannelRoute(
            screenDataChannelEnabled: true,
            screenChannelWireFormat: RemoteDesktopStreamConfiguration.screenChannelWireFormatSBC2ChunkedV1,
            screenChannelOpen: true,
            waitElapsed: nil
        )
        XCTAssertEqual(open.state, "open")
        XCTAssertTrue(open.useDedicatedScreenChannel)
        XCTAssertTrue(open.useChunkedScreenWire)
        XCTAssertFalse(open.shouldWaitForScreenChannel)
        XCTAssertTrue(open.allowsInteractionStreaming)
    }

    @MainActor
    func testNativeWarmupFallbackKeepsSCKLatestAndOnlyPromotesDirectEncoderAfterNativeEvidence() {
        let required = CrossNetworkConnectionManager.requiredStableDirectEncoderFrames(targetFrameRate: 60)

        XCTAssertEqual(CrossNetworkConnectionManager.webRTCFallbackCGDisplayProducer, "cgdisplaySync")
        XCTAssertEqual(CrossNetworkConnectionManager.webRTCFallbackSCKLatestProducer, "sckLatest")
        XCTAssertEqual(CrossNetworkConnectionManager.webRTCFallbackCGDisplayEmergencyProducer, "cgdisplayEmergency")
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldPromoteDirectEncoderFallback(
                nativeVideoWarmBackupEnabled: true,
                nativeVideoHasRenderEvidence: false,
                activeFallbackProducer: CrossNetworkConnectionManager.webRTCFallbackSCKLatestProducer,
                recoveryStreak: required,
                targetFrameRate: 60
            ),
            "Direct encoder frames must stay prewarm-only while native RTP/render evidence is still zero."
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldPromoteDirectEncoderFallback(
                nativeVideoWarmBackupEnabled: true,
                nativeVideoHasRenderEvidence: true,
                activeFallbackProducer: CrossNetworkConnectionManager.webRTCFallbackSCKLatestProducer,
                recoveryStreak: max(0, required - 1),
                targetFrameRate: 60
            )
        )
        XCTAssertTrue(
            CrossNetworkConnectionManager.shouldPromoteDirectEncoderFallback(
                nativeVideoWarmBackupEnabled: true,
                nativeVideoHasRenderEvidence: true,
                activeFallbackProducer: CrossNetworkConnectionManager.webRTCFallbackSCKLatestProducer,
                recoveryStreak: required,
                targetFrameRate: 60
            )
        )
    }

    @MainActor
    func testScreenStreamingDoesNotRestartForViewerStopConfiguration() {
        let config = RemoteDesktopStreamConfiguration(
            supportedVideoFormats: [],
            targetFrameRate: 0,
            keyFrameInterval: 0,
            lowLatencyMode: false,
            enableHardwareAcceleration: false,
            enableAppleSiliconOptimization: false,
            clipboardSyncEnabled: false,
            refreshStrategy: "stop",
            screenFrameTransport: "stopped",
            screenDataChannelEnabled: false,
            audioRedirectionEnabled: false
        )

        XCTAssertTrue(config.isStopRequest)
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldStartWebRTCScreenStreaming(
                remoteStreamConfiguration: config
            )
        )
    }

    @MainActor
    func testWebRTCAudioFallbackRequiresExplicitLegacyModeAndNativeAudioOff() {
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldUseWebRTCAudioFallback(
                audioRedirectionEnabled: true,
                nativeAudioTrackEnabled: false
            ),
            "WebRTC audio must not silently fall back to the shared DataChannel unless compatibility mode is explicit."
        )
        XCTAssertTrue(
            CrossNetworkConnectionManager.shouldUseWebRTCAudioFallback(
                audioRedirectionEnabled: true,
                nativeAudioTrackEnabled: false,
                legacyAudioFallbackEnabled: true
            )
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldUseWebRTCAudioFallback(
                audioRedirectionEnabled: true,
                nativeAudioTrackEnabled: true,
                legacyAudioFallbackEnabled: true
            )
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldUseWebRTCAudioFallback(
                audioRedirectionEnabled: false,
                nativeAudioTrackEnabled: false,
                legacyAudioFallbackEnabled: true
            )
        )
    }

    @MainActor
    func testWebRTCNativeAudioRequiresLocalTrackReadiness() {
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldUseWebRTCNativeAudio(
                audioRedirectionEnabled: true,
                remoteNativeAudioTrackEnabled: true,
                localNativeAudioTrackReady: false
            )
        )
        XCTAssertTrue(
            CrossNetworkConnectionManager.shouldUseWebRTCNativeAudio(
                audioRedirectionEnabled: true,
                remoteNativeAudioTrackEnabled: true,
                localNativeAudioTrackReady: true
            )
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldUseWebRTCNativeAudio(
                audioRedirectionEnabled: false,
                remoteNativeAudioTrackEnabled: true,
                localNativeAudioTrackReady: true
            )
        )
    }
}
