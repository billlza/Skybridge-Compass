import XCTest
import SkyBridgeRealtimeMedia
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
    func testNativeWarmupFallbackUsesBoundedJPEGAndOnlyPromotesAfterNativeEvidence() {
        let required = CrossNetworkConnectionManager.requiredStableDirectEncoderFrames(targetFrameRate: 60)

        XCTAssertEqual(CrossNetworkConnectionManager.webRTCFallbackCGDisplayProducer, "cgdisplaySync")
        XCTAssertEqual(CrossNetworkConnectionManager.webRTCFallbackSCKLatestProducer, "sckLatest")
        XCTAssertEqual(CrossNetworkConnectionManager.webRTCFallbackCGDisplayEmergencyProducer, "cgdisplayEmergency")
        XCTAssertEqual(CrossNetworkConnectionManager.webRTCFallbackDegradedJPEGWarmupProducer, "degradedJPEGWarmupMain")
        XCTAssertEqual(CrossNetworkConnectionManager.webRTCFallbackBoundedJPEGWarmupProducer, "boundedJPEGWarmupMain")
        XCTAssertEqual(CrossNetworkConnectionManager.webRTCCGDisplayEmergencyFallbackHoldSeconds, 10.0)
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldPromoteDirectEncoderFallback(
                nativeVideoWarmBackupEnabled: true,
                nativeVideoHasRenderEvidence: false,
                activeFallbackProducer: CrossNetworkConnectionManager.webRTCFallbackDegradedJPEGWarmupProducer,
                recoveryStreak: required,
                targetFrameRate: 60
            ),
            "Direct encoder frames must stay prewarm-only while visible native render evidence is still zero."
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldPromoteDirectEncoderFallback(
                nativeVideoWarmBackupEnabled: true,
                nativeVideoHasRenderEvidence: true,
                activeFallbackProducer: CrossNetworkConnectionManager.webRTCFallbackDegradedJPEGWarmupProducer,
                recoveryStreak: max(0, required - 1),
                targetFrameRate: 60
            )
        )
        XCTAssertTrue(
            CrossNetworkConnectionManager.shouldPromoteDirectEncoderFallback(
                nativeVideoWarmBackupEnabled: true,
                nativeVideoHasRenderEvidence: true,
                activeFallbackProducer: CrossNetworkConnectionManager.webRTCFallbackDegradedJPEGWarmupProducer,
                recoveryStreak: required,
                targetFrameRate: 60
            )
        )
    }

    @MainActor
    func testNativeWarmupBoundedJPEGProfileAllowsTwoKDisplayLongEdge() {
        let profile = CrossNetworkConnectionManager.boundedWebRTCWarmupJPEGProfile(
            for: CGSize(width: 2_056, height: 1_328)
        )

        XCTAssertEqual(profile.maxLongEdge, 2_056)
        XCTAssertEqual(profile.targetFrameRate, 6)
        XCTAssertGreaterThan(profile.maxEncodedFrameBytes, WebRTCDegradedFallbackJPEGProfile.maxEncodedFrameBytes)
        XCTAssertGreaterThan(profile.maxTransportFrameBytes, WebRTCDegradedFallbackJPEGProfile.maxTransportFrameBytes)
        XCTAssertLessThanOrEqual(profile.maxTransportFrameBytes, 896 * 1024)
    }

    @MainActor
    func testNativeWarmupBoundedJPEGProfileCapsFourKDisplayBeforeItBackpressuresDataChannel() {
        let profile = CrossNetworkConnectionManager.boundedWebRTCWarmupJPEGProfile(
            for: CGSize(width: 3_840, height: 2_160)
        )

        XCTAssertEqual(profile.maxLongEdge, CrossNetworkConnectionManager.webRTCNativeWarmupJPEGMaxLongEdge)
        XCTAssertLessThan(profile.maxLongEdge, 3_840)
        XCTAssertGreaterThan(profile.maxEncodedFrameBytes, WebRTCDegradedFallbackJPEGProfile.maxEncodedFrameBytes)
        XCTAssertGreaterThan(profile.maxTransportFrameBytes, WebRTCDegradedFallbackJPEGProfile.maxTransportFrameBytes)
        XCTAssertLessThanOrEqual(profile.maxTransportFrameBytes, 896 * 1024)
    }

    @MainActor
    func testNativeWarmupJPEGBackpressureUsesLowWatermarkBeforeCapturingMoreFrames() {
        let maxBuffered = UInt64(896 * 1024)
        let threshold = CrossNetworkConnectionManager.nativeWarmupJPEGBackpressureThreshold(
            maxBufferedAmountBytes: maxBuffered
        )

        XCTAssertEqual(threshold, UInt64(WebRTCDegradedFallbackJPEGProfile.maxTransportFrameBytes))
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldThrottleNativeWarmupJPEGFallback(
                supportsNativeVideoTrack: true,
                nativeVideoTrackReady: false,
                bufferedAmount: threshold - 1,
                maxBufferedAmountBytes: maxBuffered
            )
        )
        XCTAssertTrue(
            CrossNetworkConnectionManager.shouldThrottleNativeWarmupJPEGFallback(
                supportsNativeVideoTrack: true,
                nativeVideoTrackReady: false,
                bufferedAmount: threshold,
                maxBufferedAmountBytes: maxBuffered
            )
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldThrottleNativeWarmupJPEGFallback(
                supportsNativeVideoTrack: true,
                nativeVideoTrackReady: true,
                bufferedAmount: threshold,
                maxBufferedAmountBytes: maxBuffered
            )
        )
    }

    @MainActor
    func testSCKLatestRecoveryRequiresSustainedHealthyWindow() {
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldRecoverWebRTCSCKLatestFallback(
                recentFrameCount: CrossNetworkConnectionManager.webRTCSCKLatestRecoveryRequiredFrames - 1,
                windowStartedAt: start,
                now: start.addingTimeInterval(0.25)
            )
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldRecoverWebRTCSCKLatestFallback(
                recentFrameCount: CrossNetworkConnectionManager.webRTCSCKLatestRecoveryRequiredFrames,
                windowStartedAt: start,
                now: start.addingTimeInterval(2.0)
            )
        )
        XCTAssertTrue(
            CrossNetworkConnectionManager.shouldRecoverWebRTCSCKLatestFallback(
                recentFrameCount: CrossNetworkConnectionManager.webRTCSCKLatestRecoveryRequiredFrames,
                windowStartedAt: start,
                now: start.addingTimeInterval(0.25)
            )
        )
    }

    @MainActor
    func testSCKLatestRecoveryCountsOnlyDistinctFrames() {
        var windowStartedAt: Date?
        var recentFrameCount = 0
        var lastFrameIdentity: WebRTCEncodedScreenFrameIdentity?
        let start = Date(timeIntervalSince1970: 1_000)
        let frame = WebRTCEncodedScreenFrame(
            width: 1920,
            height: 1080,
            imageData: Data([0x01, 0x02]),
            timestamp: 1_000,
            format: "h264",
            isSyncFrame: false,
            sequenceNumber: 1
        )

        for offset in stride(from: 0.0, through: 0.25, by: 0.05) {
            CrossNetworkConnectionManager.updateWebRTCSCKLatestRecoveryWindow(
                candidateFrame: frame,
                now: start.addingTimeInterval(offset),
                windowStartedAt: &windowStartedAt,
                recentFrameCount: &recentFrameCount,
                lastFrameIdentity: &lastFrameIdentity
            )
        }

        XCTAssertEqual(recentFrameCount, 1)
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldRecoverWebRTCSCKLatestFallback(
                recentFrameCount: recentFrameCount,
                windowStartedAt: windowStartedAt,
                now: start.addingTimeInterval(0.25)
            )
        )

        CrossNetworkConnectionManager.updateWebRTCSCKLatestRecoveryWindow(
            candidateFrame: nil,
            now: start.addingTimeInterval(0.3),
            windowStartedAt: &windowStartedAt,
            recentFrameCount: &recentFrameCount,
            lastFrameIdentity: &lastFrameIdentity
        )
        XCTAssertNil(windowStartedAt)
        XCTAssertEqual(recentFrameCount, 0)
        XCTAssertNil(lastFrameIdentity)
    }

    func testNativeVideoFailureUsesFastRetryBeforePersistentCooldown() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift"),
            encoding: .utf8
        )
        let policySource = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/RemoteConnection/WebRTC/WebRTCScreenStreamingPolicy.swift"),
            encoding: .utf8
        )
        let hostAndPolicySource = source + "\n" + policySource

        XCTAssertTrue(source.contains("nativeVideoFailureStrikeCount += 1"))
        XCTAssertTrue(source.contains("nativeVideoFailureStrikeCount >= 3 ? 10.0 : 1.25"))
        XCTAssertTrue(source.contains("nativeVideoFallbackDecision"))
        XCTAssertTrue(policySource.contains("static func nativeVideoFallbackDecision"))
        let fallbackDecisionBody = try sourceSlice(
            from: "static func nativeVideoFallbackDecision",
            to: "static func shouldThrottleNativeWarmupJPEGFallback",
            in: policySource
        )
        XCTAssertTrue(
            fallbackDecisionBody.contains("guard nativeVideoTrackReady else"),
            "Fallback main may drive the screen only while native RTP has not become the plausible main path."
        )
        XCTAssertTrue(
            fallbackDecisionBody.contains("native-rtp-flowing-awaiting-visible-render"),
            "Once outbound RTP is flowing, fallback must stop driving the main path even if the viewer is still waiting for visible RTCMTLVideoView evidence."
        )
        XCTAssertTrue(
            fallbackDecisionBody.contains("fallbackShouldDriveMain: false"),
            "Once nativeReady is acknowledged, ownership belongs to native video; fallback must stay heartbeat/warm-backup only."
        )
        XCTAssertTrue(source.contains("nativeVideoHealthState == .rtpFlowing"))
        XCTAssertTrue(source.contains("nativeVideoFallbackDrivingMain"))
        XCTAssertFalse(
            fallbackDecisionBody.contains("fallbackShouldDriveMain: !rtpIsHealthy"),
            "Host-side stats lag must not reopen fallback-main after the viewer has reported visible native rendering."
        )
        XCTAssertTrue(hostAndPolicySource.contains("webRTCFallbackBoundedJPEGWarmupProducer"))
        XCTAssertTrue(hostAndPolicySource.contains("boundedJPEGWarmupMain"))
        XCTAssertTrue(source.contains("native-warmup-bounded-jpeg"))
        XCTAssertTrue(hostAndPolicySource.contains("boundedWebRTCWarmupJPEGProfile"))
        XCTAssertTrue(hostAndPolicySource.contains("shouldThrottleNativeWarmupJPEGFallback"))
        XCTAssertTrue(source.contains("chunkDropReason=native-warmup-jpeg-backpressure"))
        XCTAssertTrue(source.contains("screenSendMaxBufferedAmountBytes"))
        XCTAssertTrue(source.contains("captureStreamer.onEncodedFrame = nil"))
        XCTAssertTrue(source.contains("degradedFallbackJPEGProfile: nil"))
        XCTAssertFalse(source.contains("let canUseSCKLatestFrame ="))
        XCTAssertFalse(source.contains("sck-latest-recovered"))
        XCTAssertFalse(
            source.contains("encodedFrameStore.takeLatest(\n                                        maxAge: Self.webRTCSCKLatestFallbackMaxAgeSeconds"),
            "Native warmup fallback must not consume SCK latest encoded frames; that path was mixing HEVC/H264 and JPEG into the same screen-channel topology."
        )
        XCTAssertTrue(source.contains("action=cooldown"))
        XCTAssertTrue(source.contains("fallback=heartbeat"))
        XCTAssertFalse(source.contains("fallback=main"))
        XCTAssertTrue(source.contains("native-video-rtp-flowing"))
        XCTAssertTrue(source.contains("rtcStats.rtpFlowing"))
        XCTAssertTrue(source.contains("nativeVideoTrackReadyForStats,"))
        XCTAssertTrue(source.contains("return .rtpFlowing"))
        XCTAssertTrue(source.contains("return .rendered"))
        XCTAssertTrue(source.contains("nativeVideoSenderRefreshAttempted = session.refreshOutgoingScreenVideoSender"))
        XCTAssertFalse(source.contains("action=recreate-transceiver"))
        XCTAssertTrue(source.contains("degradedFallbackPolicy"))
        XCTAssertTrue(source.contains("nativeWarmupFallbackJPEGProfile"))
        XCTAssertTrue(source.contains("let fallbackSendVideoPolicy ="))
        XCTAssertTrue(source.contains("let nativeCaptureVideoPolicy = session.supportsNativeScreenVideoTrack"))
        XCTAssertTrue(source.contains("currentNativeCaptureVideoPolicy(for: transportPath)"))
        XCTAssertTrue(source.contains("let encoderVideoPolicy = session.supportsNativeScreenVideoTrack"))
        XCTAssertTrue(source.contains("ensureDirectEncoder(for: encoderVideoPolicy)"))
        XCTAssertTrue(source.contains("try await captureStreamer.start(\n                            preferredCodec: videoPolicy.codec"))
        XCTAssertTrue(source.contains("let explicitStreamResolutionRequested ="))
        XCTAssertTrue(source.contains("preserveExactVisibleSize: preserveExactVisibleCaptureSize"))
        XCTAssertFalse(
            source.contains("ensureDirectEncoder(for: videoPolicy)"),
            "Native RTP warmup must use the native encoder policy; fallbackSendVideoPolicy may be BGRA for the SBRF/JPEG side path."
        )
        XCTAssertTrue(source.contains("ScreenCaptureKitStreamer"))
        XCTAssertTrue(source.contains("if framesSent == 1 {\n                            logWindowStart = Date()\n                        }"))
        XCTAssertFalse(
            source.contains("nativeVideoFailureCooldownUntil = Date().addingTimeInterval(30)"),
            "Transient native-video failures must retry quickly so fallback can recover inside the user-visible 2s target."
        )
        XCTAssertFalse(
            source.contains("format=webrtc-native-video-warmup"),
            "Strict WebRTC startup must wait for native video instead of advertising a warmup fallback format."
        )
        XCTAssertTrue(hostAndPolicySource.contains("shouldDropNativeWarmupNonJPEGFallbackFrame"))
        XCTAssertTrue(source.contains("dropReason=native-warmup-non-jpeg-fallback"))
        XCTAssertTrue(source.contains("effectiveWebRTCNativeCaptureVideoFormats"))
        XCTAssertTrue(source.contains("nativeCaptureCodec="))
        XCTAssertTrue(source.contains("audioEndpointPreservedForVideoRefresh"))
        XCTAssertTrue(hostAndPolicySource.contains("shouldFailFastRemoteMediaFallbacks"))
        XCTAssertTrue(source.contains("shouldUseFallbackAudioChunks && !failFastMediaFallbacks"))
        XCTAssertTrue(source.contains("screen-channel-control-fallback-forbidden"))
        XCTAssertTrue(source.contains("degraded-screen-fallback-forbidden"))
        XCTAssertTrue(source.contains("strict_media_validation_failed_\\(reason)"))
        XCTAssertTrue(source.contains("connectionStatus = .failed(\"WebRTC strict media validation failed: \\(reason)"))
        XCTAssertTrue(source.contains("screen-frame-whole-budget-exceeded"))
        XCTAssertTrue(source.contains("synthetic-screen-forbidden"))
        XCTAssertTrue(source.contains("synthetic-audio-forbidden"))
        XCTAssertTrue(source.contains("realtime-audio-main-path-unavailable"))
        XCTAssertTrue(source.contains("pqc-media-audio-sender-unavailable"))
        XCTAssertTrue(source.contains("if failFastMediaFallbacks {\n                            recordStrictMediaValidationFailure(\n                                reason: \"screen-frame-whole-budget-exceeded\""))
        XCTAssertTrue(source.contains("audioTxAttachRetryScheduled session="))
        XCTAssertTrue(source.contains("strictRealtimeAudioAttachRetryWindowSeconds"))
        XCTAssertTrue(source.contains("reason: \"realtime-audio-main-path-unavailable\""))
    }

    func testFallbackScreenDataCarriesSequenceNumberThroughSBRFV2() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift"),
            encoding: .utf8
        )
        let wireSource = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/RemoteConnection/WebRTC/RemoteDesktopWebRTCWire.swift"),
            encoding: .utf8
        )
        let frameStoreSource = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/RemoteConnection/WebRTC/WebRTCEncodedFrameStore.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(wireSource.contains("let sequenceNumber: UInt64?"))
        XCTAssertTrue(frameStoreSource.contains("let sequenceNumber: UInt64"))
        XCTAssertTrue(source.contains("let fallbackFrameSequence = RemoteControlFrameSequenceGenerator()"))
        XCTAssertTrue(source.contains("sequenceNumber: fallbackFrameSequence.next()"))
        XCTAssertTrue(source.contains("sequenceNumber: encodedFrame.sequenceNumber"))
        XCTAssertTrue(source.contains("sequenceNumber: sd.sequenceNumber"))
    }

    @MainActor
    func testNativeWarmupScreenChannelFinalGateDropsNonJPEGFallbackAndAllowsBoundedJPEG() {
        XCTAssertTrue(
            CrossNetworkConnectionManager.shouldDropNativeWarmupNonJPEGFallbackFrame(
                supportsNativeVideoTrack: true,
                nativeVideoTrackReady: false,
                format: "hevc"
            )
        )
        XCTAssertTrue(
            CrossNetworkConnectionManager.shouldDropNativeWarmupNonJPEGFallbackFrame(
                supportsNativeVideoTrack: true,
                nativeVideoTrackReady: false,
                format: "h264"
            )
        )
        XCTAssertTrue(
            CrossNetworkConnectionManager.shouldDropNativeWarmupNonJPEGFallbackFrame(
                supportsNativeVideoTrack: true,
                nativeVideoTrackReady: false,
                format: nil
            )
        )
        XCTAssertTrue(
            CrossNetworkConnectionManager.shouldDropNativeWarmupNonJPEGFallbackFrame(
                supportsNativeVideoTrack: true,
                nativeVideoTrackReady: false,
                format: " bgra "
            )
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldDropNativeWarmupNonJPEGFallbackFrame(
                supportsNativeVideoTrack: true,
                nativeVideoTrackReady: false,
                format: "jpeg"
            )
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldDropNativeWarmupNonJPEGFallbackFrame(
                supportsNativeVideoTrack: true,
                nativeVideoTrackReady: false,
                format: " JPG "
            )
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldDropNativeWarmupNonJPEGFallbackFrame(
                supportsNativeVideoTrack: true,
                nativeVideoTrackReady: true,
                format: "hevc"
            )
        )
    }

    @MainActor
    func testVideoRefreshStreamConfigPreservesPreviousAudioEndpointOnHost() {
        let endpoint = SkyBridgeMediaEndpoint(
            host: "203.0.113.10",
            port: 3478,
            relayToken: "relay-token",
            expiresAt: 1_770_000_000
        )
        let previous = RemoteDesktopStreamConfiguration(
            preferredCodec: "h264",
            supportedVideoFormats: ["hevc", "h264", "jpeg"],
            targetFrameRate: 60,
            keyFrameInterval: 60,
            lowLatencyMode: false,
            enableHardwareAcceleration: true,
            enableAppleSiliconOptimization: true,
            clipboardSyncEnabled: true,
            screenFrameTransport: "webrtc-native-main+sbrf-fallback",
            nativeVideoTrackReady: false,
            audioRedirectionEnabled: true,
            audioTransport: "pqc-media-v1",
            audioMode: "high-fidelity",
            mediaSessionId: "session-a",
            mediaAudioEndpoint: endpoint,
            audioSampleRate: 48_000,
            audioChannelCount: 2
        )
        let videoRefresh = RemoteDesktopStreamConfiguration(
            preferredCodec: "jpeg",
            supportedVideoFormats: ["jpeg"],
            targetFrameRate: 60,
            keyFrameInterval: 60,
            lowLatencyMode: false,
            enableHardwareAcceleration: true,
            enableAppleSiliconOptimization: true,
            clipboardSyncEnabled: true,
            screenFrameTransport: "webrtc-native-main+sbrf-fallback",
            nativeVideoTrackReady: false,
            audioRedirectionEnabled: true,
            audioTransport: "pqc-media-v1",
            audioMode: "high-fidelity",
            mediaAudioEndpoint: nil,
            audioSampleRate: 48_000,
            audioChannelCount: 2,
            streamRefreshToken: 42
        )

        let merged = CrossNetworkConnectionManager
            .streamConfigurationByPreservingAudioEndpointForVideoRefresh(
                videoRefresh,
                previousConfig: previous
            )

        XCTAssertEqual(merged.streamRefreshToken, 42)
        XCTAssertEqual(merged.mediaSessionId, "session-a")
        XCTAssertEqual(merged.mediaAudioEndpoint, endpoint)
        XCTAssertEqual(merged.audioMode, "high-fidelity")
        XCTAssertEqual(merged.preferredCodec, "jpeg")
        XCTAssertEqual(merged.supportedVideoFormats, ["jpeg"])

        let newEndpoint = SkyBridgeMediaEndpoint(
            host: "203.0.113.11",
            port: 3479,
            relayToken: "new-relay-token",
            expiresAt: 1_770_000_010
        )
        let endpointUpdate = RemoteDesktopStreamConfiguration(
            preferredCodec: "jpeg",
            supportedVideoFormats: ["jpeg"],
            targetFrameRate: 60,
            keyFrameInterval: 60,
            lowLatencyMode: false,
            enableHardwareAcceleration: true,
            enableAppleSiliconOptimization: true,
            clipboardSyncEnabled: true,
            screenFrameTransport: "webrtc-native-main+sbrf-fallback",
            nativeVideoTrackReady: false,
            audioRedirectionEnabled: true,
            audioTransport: "pqc-media-v1",
            mediaSessionId: "session-b",
            mediaAudioEndpoint: newEndpoint,
            streamRefreshToken: 43
        )
        XCTAssertEqual(
            CrossNetworkConnectionManager
                .streamConfigurationByPreservingAudioEndpointForVideoRefresh(
                    endpointUpdate,
                    previousConfig: previous
            )
                .mediaAudioEndpoint,
            newEndpoint
        )

        let staleSessionWithoutEndpoint = RemoteDesktopStreamConfiguration(
            preferredCodec: "jpeg",
            supportedVideoFormats: ["jpeg"],
            targetFrameRate: 60,
            keyFrameInterval: 60,
            lowLatencyMode: false,
            enableHardwareAcceleration: true,
            enableAppleSiliconOptimization: true,
            clipboardSyncEnabled: true,
            screenFrameTransport: "webrtc-native-main+sbrf-fallback",
            nativeVideoTrackReady: false,
            audioRedirectionEnabled: true,
            audioTransport: "pqc-media-v1",
            audioMode: "high-fidelity",
            mediaSessionId: "session-b",
            mediaAudioEndpoint: nil,
            audioSampleRate: 48_000,
            audioChannelCount: 2,
            streamRefreshToken: 44
        )
        XCTAssertNil(
            CrossNetworkConnectionManager
                .streamConfigurationByPreservingAudioEndpointForVideoRefresh(
                    staleSessionWithoutEndpoint,
                    previousConfig: previous
                )
                .mediaAudioEndpoint,
            "A refresh-like config with a new media session but no endpoint is an audio state change, not a video-only refresh."
        )

        let changedAudioModeWithoutEndpoint = RemoteDesktopStreamConfiguration(
            preferredCodec: "jpeg",
            supportedVideoFormats: ["jpeg"],
            targetFrameRate: 60,
            keyFrameInterval: 60,
            lowLatencyMode: true,
            enableHardwareAcceleration: true,
            enableAppleSiliconOptimization: true,
            clipboardSyncEnabled: true,
            screenFrameTransport: "webrtc-native-main+sbrf-fallback",
            nativeVideoTrackReady: false,
            audioRedirectionEnabled: true,
            audioTransport: "pqc-media-v1",
            audioMode: "low-latency",
            mediaAudioEndpoint: nil,
            audioSampleRate: 48_000,
            audioChannelCount: 2,
            streamRefreshToken: 45
        )
        XCTAssertNil(
            CrossNetworkConnectionManager
                .streamConfigurationByPreservingAudioEndpointForVideoRefresh(
                    changedAudioModeWithoutEndpoint,
                    previousConfig: previous
                )
                .mediaAudioEndpoint,
            "Audio semantic changes must not inherit a stale relay endpoint from an older video refresh."
        )

        let nonRefreshWithoutEndpoint = RemoteDesktopStreamConfiguration(
            preferredCodec: "jpeg",
            supportedVideoFormats: ["jpeg"],
            targetFrameRate: 60,
            keyFrameInterval: 60,
            lowLatencyMode: false,
            enableHardwareAcceleration: true,
            enableAppleSiliconOptimization: true,
            clipboardSyncEnabled: true,
            screenFrameTransport: "webrtc-native-main+sbrf-fallback",
            nativeVideoTrackReady: false,
            audioRedirectionEnabled: true,
            audioTransport: "pqc-media-v1",
            mediaAudioEndpoint: nil,
            streamRefreshToken: nil
        )
        XCTAssertNil(
            CrossNetworkConnectionManager
                .streamConfigurationByPreservingAudioEndpointForVideoRefresh(
                    nonRefreshWithoutEndpoint,
                    previousConfig: previous
                )
                .mediaAudioEndpoint,
            "Only explicit video refreshes preserve the previous endpoint; normal audio-absent configs intentionally clear it."
        )
    }

    private func sourceSlice(from startMarker: String, to endMarker: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker)?.lowerBound)
        let suffix = source[start...]
        let end = try XCTUnwrap(suffix.range(of: endMarker)?.lowerBound)
        return String(suffix[..<end])
    }

    func testWebRTCRealtimeAudioUsesLocalRoleRelayLeaseInsteadOfViewerToken() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let managerSource = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift"),
            encoding: .utf8
        )
        let audioSupportSource = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/RemoteConnection/WebRTC/WebRTCAudioFallbackSupport.swift"),
            encoding: .utf8
        )
        let mediaRelayPolicySource = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/RemoteConnection/WebRTC/WebRTCMediaRelayPolicy.swift"),
            encoding: .utf8
        )
        let diagnosticsSource = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/RemoteConnection/WebRTC/CrossNetworkWebRTCDiagnostics.swift"),
            encoding: .utf8
        )
        let realtimeAudioCoordinatorSource = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/RemoteConnection/WebRTC/WebRTCRealtimeAudioSenderCoordinator.swift"),
            encoding: .utf8
        )
        let source = managerSource
            + "\n" + audioSupportSource
            + "\n" + mediaRelayPolicySource
            + "\n" + diagnosticsSource
            + "\n" + realtimeAudioCoordinatorSource

        guard let functionStart = realtimeAudioCoordinatorSource.range(of: "func makeSenderIfNeeded"),
              let functionEnd = realtimeAudioCoordinatorSource.range(of: "func requestSenderEndpoint", range: functionStart.upperBound..<realtimeAudioCoordinatorSource.endIndex) else {
            XCTFail("WebRTC realtime audio sender helper should be present")
            return
        }
        let helper = String(realtimeAudioCoordinatorSource[functionStart.lowerBound..<functionEnd.lowerBound])

        XCTAssertTrue(
            helper.contains(
                "requestSenderEndpoint(\n                sessionID: sessionID,\n                validateOperationOwner: validateOperationOwner\n            )"
            )
        )
        XCTAssertTrue(helper.contains("leaseSource=localRoleLease"))
        XCTAssertTrue(helper.contains("relayBindPolicy: SkyBridgeRealtimeMediaRelayBindPolicy"))
        XCTAssertFalse(
            realtimeAudioCoordinatorSource.contains("@MainActor\nstruct WebRTCRealtimeAudioSenderCoordinator"),
            "Realtime audio relay admission, endpoint leasing, and sender startup must not be isolated to the UI actor."
        )
        XCTAssertTrue(realtimeAudioCoordinatorSource.contains("requestMediaRelayLease: @Sendable"))
        XCTAssertTrue(realtimeAudioCoordinatorSource.contains("refreshMediaAdmissionLease: @Sendable"))
        XCTAssertTrue(source.contains("failFastMediaFallbacks ? .requireAcknowledgement : .optimisticAfterSend"))
        XCTAssertTrue(source.contains("minimumRemainingTime: realtimeAudioRelayRenewalMargin"))
        XCTAssertTrue(source.contains("kind = \"audioTxRelayBindAccepted\""))
        XCTAssertTrue(source.contains("kind = \"audioTxRelayBindAckPending\""))
        XCTAssertTrue(source.contains("relay-bind-ack-pending-media-optimistic"))
        XCTAssertTrue(source.contains("audioTxRelayBindAckPending reason=relayBindAckTimedOut"))
        XCTAssertTrue(source.contains("kind = \"audioTxRelayBindTimedOut\""))
        XCTAssertFalse(helper.contains("let endpoint = viewerAudioEndpoint"))
        XCTAssertTrue(source.contains("signalServer.requestMediaRelayLease(mediaAdmissionToken:"))
        XCTAssertTrue(
            managerSource.contains(
                "makeWebRTCRealtimeAudioSenderCoordinator().refreshAdmissionLease(\n            sessionID: sessionID,\n            validateOperationOwner: validateOperationOwner\n        )"
            )
        )
        XCTAssertTrue(
            realtimeAudioCoordinatorSource.contains(
                "func requestSenderEndpoint(\n        sessionID: String,\n        validateOperationOwner: OperationOwnerValidator\n    )"
            )
        )
        XCTAssertTrue(
            realtimeAudioCoordinatorSource.contains(
                "func refreshAdmissionLease(\n        sessionID: String,\n        validateOperationOwner: OperationOwnerValidator\n    )"
            )
        )
        XCTAssertFalse(
            realtimeAudioCoordinatorSource.contains("func requestSenderEndpoint(sessionID: String)"),
            "Realtime audio endpoint acquisition must not retain a fail-open ownerless overload."
        )
        XCTAssertFalse(
            realtimeAudioCoordinatorSource.contains("func refreshAdmissionLease(sessionID: String)"),
            "Realtime audio lease refresh must not retain a fail-open ownerless overload."
        )
        XCTAssertTrue(source.contains("preserveRealtimeAudioSender"))
        XCTAssertTrue(source.contains("audioTxSenderPreserved"))
        XCTAssertTrue(source.contains("directRealtimeAudioAttachTask = Task(priority: .utility)"))
        XCTAssertTrue(source.contains("audioTxAttachStart session="))
        XCTAssertTrue(source.contains("audioTxAttachComplete session="))
        XCTAssertTrue(source.contains("audioTxCapturePipeReady session="))
        XCTAssertTrue(source.contains("WebRTCRealtimeAudioEndpointStableKey"))
        XCTAssertTrue(source.contains("lastRealtimeAudioEndpointStableKey == realtimeAudioEndpointStableKey"))
        XCTAssertTrue(source.contains("let viewerEndpointReady: Bool"))
        XCTAssertTrue(source.contains("let viewerEndpointHost: String"))
        XCTAssertTrue(source.contains("let viewerEndpointPort: UInt16"))
        XCTAssertFalse(
            source.contains("let viewerRelayToken: String?"),
            "Relay tokens rotate during renewal; stable sender preservation should be keyed by media session, mode, and relay socket only."
        )
        XCTAssertTrue(source.contains("leaseSource=viewerReceiverSignal"))
        XCTAssertTrue(source.contains("captureSystemAudio: shouldUseNativeAudioTrack\n                                || shouldUseFallbackAudioChunks\n                                || shouldUseRealtimeAudio"))
        XCTAssertFalse(source.contains("if shouldUseRealtimeAudio, directRealtimeAudioSender == nil {\n                        if let realtimeSender = await self.makeWebRTCRealtimeAudioSenderIfNeeded"))
        XCTAssertFalse(
            source.contains("lastRealtimeAudioEndpoint == realtimeAudioEndpoint,\n                       lastRealtimeAudioMode == realtimeAudioMode,\n                       lastRealtimeAudioMediaSessionId == realtimeAudioMediaSessionId"),
            "Video refresh configs should not tear down realtime audio just because SkyBridgeMediaEndpoint.expiresAt drifted."
        )
    }

    func testMacWebRTCOutboundHeartbeatKeepsViewerLivenessAlive() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift"),
            encoding: .utf8
        )
        let localAppMessageFactory = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/SkyBridgeCore/RemoteConnection/WebRTC/CrossNetworkWebRTCLocalAppMessageFactory.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("webrtcOutboundHeartbeatTasksBySessionId"))
        XCTAssertTrue(source.contains("startOutboundHeartbeatIfNeeded()"))
        XCTAssertTrue(source.contains("CrossNetworkWebRTCLocalAppMessageFactory.heartbeatMessage"))
        XCTAssertTrue(localAppMessageFactory.contains("AppMessage.heartbeat"))
        XCTAssertTrue(source.contains("label: \"tx/webrtc-heartbeat\""))
        XCTAssertTrue(source.contains("maxBufferedAmountBytes: 256 * 1024"))
        XCTAssertTrue(source.contains("webrtcRekeyInProgressSessionIds.contains(sessionID)"))
        XCTAssertTrue(source.contains("webrtcSessionKeysBySessionId[sessionID]"))
        XCTAssertTrue(source.contains("outboundHeartbeatTask.cancel()"))

        guard let heartbeatStart = source.range(of: "func startOutboundHeartbeatIfNeeded()"),
              let heartbeatEnd = source.range(of: "func orderedUniqueCandidateIds", range: heartbeatStart.upperBound..<source.endIndex) else {
            XCTFail("Heartbeat helper should stay local to the WebRTC control loop.")
            return
        }
        let heartbeatHelper = String(source[heartbeatStart.lowerBound..<heartbeatEnd.lowerBound])
        XCTAssertTrue(heartbeatHelper.contains("try await sendFramed(padded)"))
        XCTAssertFalse(heartbeatHelper.contains("sendScreenFramedPayloadAsync"))
        XCTAssertFalse(heartbeatHelper.contains("sendScreenChunkedPayloadAsync"))
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
    func testStrictNativeVideoRejectsSoftwareCodecAndEncoderEvidence() {
        XCTAssertNil(CrossNetworkConnectionManager.strictNativeVideoCodecFailureReason("video/H264"))
        XCTAssertNil(CrossNetworkConnectionManager.strictNativeVideoCodecFailureReason("video/HEVC"))
        XCTAssertNil(
            CrossNetworkConnectionManager.strictNativeVideoCodecFailureReason(
                "video/HEVC",
                requestedCodec: .hevc
            )
        )
        XCTAssertEqual(
            CrossNetworkConnectionManager.strictNativeVideoCodecFailureReason(
                "video/H264",
                requestedCodec: .hevc
            ),
            "native-video-codec-mismatch-requested-hevc-actual-videoh264"
        )
        XCTAssertEqual(
            CrossNetworkConnectionManager.strictNativeVideoCodecFailureReason("video/VP8"),
            "native-video-unacceptable-codec-videovp8"
        )
        XCTAssertEqual(
            CrossNetworkConnectionManager.strictNativeVideoCodecFailureReason(nil),
            "native-video-codec-stats-unavailable"
        )

        XCTAssertNil(CrossNetworkConnectionManager.strictNativeVideoEncoderFailureReason("VideoToolbox"))
        XCTAssertEqual(
            CrossNetworkConnectionManager.strictNativeVideoEncoderFailureReason("libvpx"),
            "native-video-software-encoder-libvpx"
        )
        XCTAssertEqual(
            CrossNetworkConnectionManager.strictNativeVideoEncoderFailureReason(nil),
            "native-video-encoder-stats-unavailable"
        )

        XCTAssertEqual(
            CrossNetworkConnectionManager.nativeVideoNoRTPFailureGraceSeconds(
                failFastMediaFallbacks: true,
                codec: "video/H264",
                encoder: "VideoToolbox",
                requestedCodec: .hevc
            ),
            2.0
        )
        XCTAssertGreaterThan(
            CrossNetworkConnectionManager.nativeVideoNoRTPFailureGraceSeconds(
                failFastMediaFallbacks: true,
                codec: "video/H264",
                encoder: "VideoToolbox",
                requestedCodec: .h264
            ),
            2.0
        )
        XCTAssertEqual(
            CrossNetworkConnectionManager.nativeVideoNoRTPFailureGraceSeconds(
                failFastMediaFallbacks: true,
                codec: "video/AV1",
                encoder: "VideoToolbox"
            ),
            2.0
        )
        XCTAssertEqual(
            CrossNetworkConnectionManager.nativeVideoNoRTPFailureGraceSeconds(
                failFastMediaFallbacks: true,
                codec: "video/H264",
                encoder: "libvpx"
            ),
            2.0
        )
        XCTAssertEqual(
            CrossNetworkConnectionManager.nativeVideoNoRTPFailureGraceSeconds(
                failFastMediaFallbacks: false,
                codec: "video/H264",
                encoder: "VideoToolbox"
            ),
            2.0
        )

        XCTAssertEqual(
            CrossNetworkConnectionManager.strictNativeVideoNoRTPFailureReason(
                outboundStatsPresent: true,
                submittedFrames: 120,
                framesEncoded: 0,
                framesSent: 0,
                packetsSent: 0,
                bytesSent: 0
            ),
            "native-video-encoder-no-output"
        )
        XCTAssertEqual(
            CrossNetworkConnectionManager.strictNativeVideoNoRTPFailureReason(
                outboundStatsPresent: true,
                submittedFrames: 120,
                framesEncoded: 12,
                framesSent: 0,
                packetsSent: 0,
                bytesSent: 0
            ),
            "native-video-sender-no-frames-sent"
        )
        XCTAssertEqual(
            CrossNetworkConnectionManager.strictNativeVideoNoRTPFailureReason(
                outboundStatsPresent: false,
                submittedFrames: 120,
                framesEncoded: 0,
                framesSent: 0,
                packetsSent: 0,
                bytesSent: 0
            ),
            "native-video-rtp-not-flowing"
        )
        XCTAssertEqual(
            CrossNetworkConnectionManager.strictNativeVideoNoRTPFailureReason(
                outboundStatsPresent: true,
                submittedFrames: 120,
                framesEncoded: 12,
                framesSent: 12,
                packetsSent: 0,
                bytesSent: 0
            ),
            "native-video-rtp-packets-not-sent"
        )
    }

    @MainActor
    func testWebRTCHardwareCompatibleCaptureSizeAlignsVideoToEvenDimensions() {
        XCTAssertEqual(
            CrossNetworkConnectionManager.webRTCHardwareCompatibleCaptureSize(
                CGSize(width: 1920, height: 1240),
                preferredCodec: .h264
            ),
            CGSize(width: 1920, height: 1240)
        )
        XCTAssertEqual(
            CrossNetworkConnectionManager.webRTCHardwareCompatibleCaptureSize(
                CGSize(width: 2056, height: 1329),
                preferredCodec: .h264
            ),
            CGSize(width: 2056, height: 1328)
        )
        XCTAssertEqual(
            CrossNetworkConnectionManager.webRTCHardwareCompatibleCaptureSize(
                CGSize(width: 2056, height: 1329),
                preferredCodec: .hevc
            ),
            CGSize(width: 2056, height: 1328)
        )
        XCTAssertEqual(
            CrossNetworkConnectionManager.webRTCHardwareCompatibleCaptureSize(
                CGSize(width: 2056, height: 1329),
                preferredCodec: .h264,
                preserveExactVisibleSize: true
            ),
            CGSize(width: 2056, height: 1329)
        )
    }

    @MainActor
    func testExtremeMediaValidationDisablesDegradedFallbacks() {
        let strictConfig = RemoteDesktopStreamConfiguration(
            supportedVideoFormats: ["h264", "hevc"],
            qualityPreset: "clarity",
            targetFrameRate: 60,
            keyFrameInterval: 60,
            lowLatencyMode: true,
            enableHardwareAcceleration: true,
            enableAppleSiliconOptimization: true,
            clipboardSyncEnabled: false,
            audioRedirectionEnabled: true,
            audioTransport: "pqc-media-v1",
            performanceValidationMode: "extreme",
            mediaFallbackPolicy: "fail-fast"
        )

        XCTAssertTrue(strictConfig.requiresExtremePerformanceValidation)
        XCTAssertFalse(strictConfig.allowsDegradedMediaFallbacks)
        XCTAssertTrue(
            CrossNetworkConnectionManager.shouldFailFastRemoteMediaFallbacks(
                remoteStreamConfiguration: strictConfig
            )
        )

        let explicitDegradedConfig = RemoteDesktopStreamConfiguration(
            supportedVideoFormats: ["h264"],
            qualityPreset: "fluid",
            targetFrameRate: 30,
            keyFrameInterval: 30,
            lowLatencyMode: false,
            enableHardwareAcceleration: true,
            enableAppleSiliconOptimization: true,
            clipboardSyncEnabled: false,
            audioRedirectionEnabled: false,
            mediaFallbackPolicy: "explicit-degraded"
        )
        XCTAssertFalse(explicitDegradedConfig.requiresExtremePerformanceValidation)
        XCTAssertTrue(explicitDegradedConfig.allowsDegradedMediaFallbacks)
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldFailFastRemoteMediaFallbacks(
                remoteStreamConfiguration: explicitDegradedConfig
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

    @MainActor
    func testExtremeMediaValidationKeepsNativeHardwarePolicyAtRequestedSixtyFPS() {
        let strictConfig = RemoteDesktopStreamConfiguration(
            supportedVideoFormats: ["h264", "hevc"],
            qualityPreset: "fluid",
            targetFrameRate: 60,
            keyFrameInterval: 30,
            lowLatencyMode: true,
            enableHardwareAcceleration: true,
            enableAppleSiliconOptimization: true,
            clipboardSyncEnabled: false,
            audioRedirectionEnabled: true,
            audioTransport: "pqc-media-v1",
            performanceValidationMode: "extreme",
            mediaFallbackPolicy: "fail-fast"
        )
        let downgradedHardwarePolicy = WebRTCRemoteDesktopVideoPolicy(
            codec: .h264,
            targetFrameRate: 45,
            keyFrameInterval: 30,
            preferredSize: CGSize(width: 960, height: 620),
            usesHardwareEncoder: true,
            reason: "relay-native-rtp-low-latency-h264"
        )

        let enforced = CrossNetworkConnectionManager.policyByEnforcingStrictMediaFrameRateFloor(
            downgradedHardwarePolicy,
            remoteStreamConfiguration: strictConfig
        )

        XCTAssertEqual(enforced.targetFrameRate, 60)
        XCTAssertEqual(enforced.keyFrameInterval, 30)
        XCTAssertTrue(enforced.reason.contains("strict-fps-floor"))
    }

    @MainActor
    func testStrictFrameRateFloorDoesNotPromoteJPEGFallbackPolicy() {
        let strictConfig = RemoteDesktopStreamConfiguration(
            supportedVideoFormats: ["jpeg", "h264"],
            qualityPreset: "fluid",
            targetFrameRate: 60,
            keyFrameInterval: 60,
            lowLatencyMode: true,
            enableHardwareAcceleration: true,
            enableAppleSiliconOptimization: true,
            clipboardSyncEnabled: false,
            performanceValidationMode: "extreme",
            mediaFallbackPolicy: "fail-fast"
        )
        let fallbackPolicy = WebRTCRemoteDesktopVideoPolicy(
            codec: .bgra,
            targetFrameRate: 12,
            keyFrameInterval: 24,
            preferredSize: CGSize(width: 960, height: 540),
            usesHardwareEncoder: false,
            reason: "relay-jpeg-conservative"
        )

        let enforced = CrossNetworkConnectionManager.policyByEnforcingStrictMediaFrameRateFloor(
            fallbackPolicy,
            remoteStreamConfiguration: strictConfig
        )

        XCTAssertEqual(enforced, fallbackPolicy)
    }

    func testExtremeMediaBudgetDoesNotSilentlyClampBelowSixtyFPS() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift"),
            encoding: .utf8
        )
        let realtimeAudioSenderSource = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/RemoteConnection/WebRTC/WebRTCRealtimeAudioSenderCoordinator.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("let strictHighFPS ="))
        XCTAssertTrue(source.contains("lowLatencyMode: settings.lowLatencyMode || strictHighFPS"))
        XCTAssertTrue(source.contains("reason: \"remote-video-fps-budget-below-target\""))
        XCTAssertTrue(source.contains("transportPath != .unknown"))
        XCTAssertTrue(source.contains("transport-or-system-budget-clamped-high-fps"))
        XCTAssertTrue(source.contains("strictNativeFramePacingEnabled"))
        XCTAssertTrue(source.contains("captureFPS >= 30 && failFastMediaFallbacks"))
        XCTAssertTrue(source.contains("DispatchTime.now().uptimeNanoseconds"))
        XCTAssertTrue(source.contains("nextDeadline = nextDeadline &+ frameIntervalNanoseconds"))
        XCTAssertTrue(source.contains("native-video-frame-pacing"))
        XCTAssertTrue(source.contains("native-video-last-frame-repeat"))
        XCTAssertTrue(source.contains("lastFailFastMediaFallbacks"))
        XCTAssertTrue(source.contains("realtimeAudioSenderLeaseReusable"))
        XCTAssertTrue(source.contains("audioTxSenderRenewing"))
        XCTAssertTrue(realtimeAudioSenderSource.contains("continuitySeq"))
    }

    func testWebRTCStreamingTeardownIsStructuredAndGenerationBound() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("@MainActor\nprivate final class WebRTCScreenStreamingRuntimeState"))
        XCTAssertTrue(source.contains("let streamingState = WebRTCScreenStreamingRuntimeState()"))
        XCTAssertTrue(source.contains("@MainActor [weak self, weak streamingState] in"))
        XCTAssertFalse(
            source.contains("let runStreamingLoop: @MainActor () async -> Void"),
            "The already-MainActor screen task must not send mutable loop state into another escaping closure."
        )
        XCTAssertFalse(source.contains("await runStreamingLoop()"))
        XCTAssertTrue(source.contains("await directSyntheticNativeVideoTask?.value"))
        XCTAssertTrue(source.contains("await directNativeFramePacingTask?.value"))
        XCTAssertTrue(source.contains("await streamingState.directRealtimeAudioAttachTask?.value"))
        XCTAssertTrue(source.contains("reason: \"stale-audio-attach-generation\""))
        XCTAssertTrue(source.contains("reason: \"streaming-state-released\""))
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy: "streamingState.directRealtimeAudioAttachGeneration == attachGeneration").count - 1,
            2,
            "Both successful and failed attach completions must be generation-bound."
        )
        XCTAssertTrue(source.contains("private struct WebRTCScreenStreamingTaskRecord"))
        XCTAssertTrue(source.contains("let callbackLease: WebRTCScreenCaptureCallbackLease"))
        XCTAssertTrue(source.contains("record.callbackLease.revoke(token: record.token)"))
        XCTAssertFalse(source.contains("webrtcScreenStreamingTaskTokensBySessionId"))
        XCTAssertTrue(source.contains("webrtcInteractionStreamingTaskTokensBySessionId"))
        XCTAssertTrue(source.contains("await task.value"))
        let stopStreamingBody = try sourceSlice(
            from: "private func stopWebRTCScreenStreaming(sessionID: String)",
            to: "#if os(macOS)",
            in: source
        )
        XCTAssertTrue(
            stopStreamingBody.contains("webrtcInteractionStreamingAllowedSessionIds.remove(sessionID)"),
            "Stopping or rekeying a stream must revoke the interaction capability before old tasks quiesce."
        )
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy: "self.stopWebRTCScreenStreaming(sessionID: sessionID)").count - 1,
            2,
            "Both inbound and outbound rekey paths must use the centralized stream stop boundary."
        )
        XCTAssertFalse(
            source.contains("defer {\n#if os(macOS)\n                    cgDisplayFrameWorker.stop()\n                    Task { @MainActor in"),
            "Streaming cleanup must not escape into an unowned task from defer."
        )
    }
}
