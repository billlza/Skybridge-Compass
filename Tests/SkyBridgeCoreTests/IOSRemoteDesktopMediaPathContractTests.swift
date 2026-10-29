import XCTest

final class IOSRemoteDesktopMediaPathContractTests: XCTestCase {
    func testCrossNetworkViewerAdvertisesNativeVideoMainPathWithoutScreenDataFallback() throws {
        let factory = try repositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/RemoteConnection/RemoteDesktop/RemoteDesktopViewerStreamConfigurationFactory.swift"
        )
        let runtimeConfig = try repositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/RemoteConnection/RemoteDesktop/RemoteDesktopManagerRuntimeModels.swift"
        )
        let remoteDesktopManager = try repositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/RemoteDesktopManager.swift"
        )
        let crossNetworkManager = try repositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/CrossNetworkWebRTCManager.swift"
        )
        let webRTCSession = try repositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/RemoteConnection/WebRTC/WebRTCSession.swift"
        )

        XCTAssertTrue(factory.contains("screenFrameTransport: activeTransportMode == .crossNetwork"))
        XCTAssertTrue(factory.contains("? \"webrtc-native-main\""))
        XCTAssertTrue(factory.contains(": \"sbrf-v1\""))
        XCTAssertTrue(factory.contains("screenDataChannelEnabled: activeTransportMode != .crossNetwork"))
        XCTAssertTrue(factory.contains("nativeVideoTrackReady: activeTransportMode == .crossNetwork"))
        XCTAssertTrue(factory.contains("? input.hasRenderedCrossNetworkNativeFrame"))
        XCTAssertTrue(factory.contains(": nil"))
        XCTAssertTrue(factory.contains("let realtimeMediaAudioReady = viewerSettings.audioRedirectionEnabled"))
        XCTAssertTrue(factory.contains("audioRedirectionEnabled: effectiveAudioRedirectionEnabled"))
        XCTAssertTrue(factory.contains("? SkyBridgeRealtimeMediaConstants.audioTransportPQCv1"))
        XCTAssertTrue(factory.contains(": SkyBridgeRealtimeMediaConstants.audioTransportDisabled"))
        XCTAssertTrue(factory.contains("compatibilityAudioFallbackEnabled: false"))
        XCTAssertTrue(runtimeConfig.contains("static let crossNetworkNativeAudioReceiveEnabled = false"))
        XCTAssertTrue(remoteDesktopManager.contains("crossNetwork.nativeAudioReceiveEnabled = RemoteDesktopManagerRuntimeConfig.crossNetworkNativeAudioReceiveEnabled"))
        XCTAssertTrue(remoteDesktopManager.contains("hasRenderedCrossNetworkNativeFrame: crossNetwork.remoteVideoTrackHasRenderedFrame"))
        XCTAssertTrue(remoteDesktopManager.contains("nativeAudioReceiveEnabled: RemoteDesktopManagerRuntimeConfig.crossNetworkNativeAudioReceiveEnabled"))
        XCTAssertTrue(remoteDesktopManager.contains("ensureRealtimeMediaAudioReceiverStartedIfNeeded(mode: mediaAudioMode)"))
        XCTAssertFalse(remoteDesktopManager.contains("shouldDeferUntilAudioEndpointReady"))
        XCTAssertTrue(remoteDesktopManager.contains("let allowsNativeWarmupJPEGFallback = Self.shouldAllowNativeWarmupJPEGFallbackFrame"))
        XCTAssertTrue(remoteDesktopManager.contains("if strictCrossNetworkMediaValidationActive && !allowsNativeWarmupJPEGFallback"))
        XCTAssertTrue(crossNetworkManager.contains("let nativeAudioReceiveEnabled = self.nativeAudioReceiveEnabled"))
        XCTAssertTrue(webRTCSession.contains("\"OfferToReceiveAudio\": nativeAudioReceiveEnabled ? \"true\" : \"false\""))
    }

    func testNativeVideoReadyRequiresVisibleRTCMTLVideoViewRenderFrame() throws {
        let manager = try repositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/CrossNetworkWebRTCManager.swift"
        )
        let policy = try repositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/RemoteConnection/WebRTC/CrossNetworkWebRTCNativeVideoPolicy.swift"
        )
        let rtcView = try repositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Views/RemoteDesktopRTCVideoView.swift"
        )
        let remoteView = try repositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Views/RemoteDesktopView.swift"
        )

        XCTAssertTrue(policy.contains("case \"rtc-mtl-video-view\":"))
        XCTAssertTrue(policy.contains("return true"))
        XCTAssertTrue(policy.contains("default:"))
        XCTAssertTrue(policy.contains("return false"))

        let renderedFrameBody = try sourceSlice(
            in: manager,
            from: "func noteRemoteVideoTrackRenderedFrame(\n        _ size: CGSize,",
            to: "@MainActor\n    private func finishNativeRenderProbeAfterVisibleFrame()"
        )
        try assertOrder(
            in: renderedFrameBody,
            first: "guard CrossNetworkWebRTCNativeVideoPolicy.isActualNativeRenderEvidence(source: source) else { return }",
            second: "remoteVideoTrackHasRenderedFrame = true"
        )
        XCTAssertTrue(renderedFrameBody.contains("guard let renderEpoch,"))
        XCTAssertTrue(renderedFrameBody.contains("renderEpoch == remoteVideoTrackRenderEpoch"))
        XCTAssertTrue(renderedFrameBody.contains("observedTrackId == expectedTrackId"))
        XCTAssertTrue(renderedFrameBody.contains("nativeRenderUISurface = uiSurface"))
        XCTAssertTrue(renderedFrameBody.contains("RemoteDesktopManager.instance.noteCrossNetworkNativeVideoFrame(visibleSize)"))
        XCTAssertTrue(manager.contains("self?.noteRemoteVideoTrackRenderedFrame(size, source: \"heartbeat-renderer\")"))
        XCTAssertTrue(manager.contains("native-receiver-frame"))
        XCTAssertTrue(manager.contains("native-render-probe-timeout"))

        XCTAssertTrue(rtcView.contains("final class ObservableRTCMTLVideoView: RTCMTLVideoView"))
        XCTAssertTrue(rtcView.contains("override func renderFrame(_ frame: RTCVideoFrame?)"))
        XCTAssertTrue(rtcView.contains("super.renderFrame(frame)"))
        XCTAssertTrue(rtcView.contains("view.renderFrame(frame)"))
        XCTAssertTrue(rtcView.contains("CrossNetworkWebRTCManager.instance.noteRemoteVideoTrackRenderedFrame("))
        XCTAssertTrue(rtcView.contains("source: ObservableRTCMTLVideoView.nativeRenderEvidenceSource"))
        XCTAssertTrue(rtcView.contains("uiSurface: uiSurface"))
        XCTAssertTrue(rtcView.contains("renderEpoch: renderEpoch"))
        XCTAssertTrue(rtcView.contains("acceptsNativeRenderEvidence\n                && window != nil"))

        XCTAssertTrue(remoteView.contains("acceptsRenderEvidence: nativeVideoOwnsSurface"))
        XCTAssertTrue(remoteView.contains(".zIndex(nativeVideoOwnsSurface ? 2 : 0)"))
        XCTAssertTrue(remoteView.contains("crossNetworkManager.nativeVideoProbeActive"))
        XCTAssertTrue(remoteView.contains("crossNetworkManager.remoteVideoTrackHasReceiverFrameEvidence"))
        XCTAssertTrue(remoteView.contains("&& !crossNetworkManager.remoteVideoTrackHasRenderedFrame"))
    }

    private func repositorySource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func sourceSlice(
        in source: String,
        from start: String,
        to end: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Substring {
        guard let startRange = source.range(of: start),
              let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex) else {
            XCTFail("Missing source slice from \(start) to \(end)", file: file, line: line)
            throw URLError(.cannotParseResponse)
        }
        return source[startRange.lowerBound..<endRange.lowerBound]
    }

    private func assertOrder(
        in source: Substring,
        first: String,
        second: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        guard let firstRange = source.range(of: first),
              let secondRange = source.range(of: second) else {
            XCTFail("Missing ordered source markers", file: file, line: line)
            throw URLError(.cannotParseResponse)
        }
        XCTAssertLessThan(firstRange.lowerBound, secondRange.lowerBound, file: file, line: line)
    }
}
