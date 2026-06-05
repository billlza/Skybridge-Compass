import SkyBridgeRealtimeMedia
import XCTest

@testable import SkyBridgeCompass_iOS

@available(iOS 17.0, *)
final class RemoteDesktopViewerStreamConfigurationFactoryTests: XCTestCase {
    func testStopPayloadDisablesAllViewerStreamChannels() {
        let payload = RemoteDesktopViewerStreamConfigurationFactory.stopPayload()

        XCTAssertEqual(payload.supportedVideoFormats, [])
        XCTAssertEqual(payload.targetFrameRate, 0)
        XCTAssertEqual(payload.keyFrameInterval, 0)
        XCTAssertEqual(payload.screenFrameTransport, "stopped")
        XCTAssertEqual(payload.screenDataChannelEnabled, false)
        XCTAssertEqual(payload.nativeVideoTrackReady, false)
        XCTAssertEqual(payload.nativeAudioTrackEnabled, false)
        XCTAssertEqual(payload.audioRedirectionEnabled, false)
        XCTAssertEqual(payload.audioTransport, "disabled")
        XCTAssertNil(payload.streamRefreshToken)
    }

    func testLANPayloadKeepsChunkedScreenChannelAndAudioEndpoint() {
        var settings = RemoteDesktopViewerSettings()
        settings.resolution = .fullHD1080
        settings.frameRate = .fps60
        settings.preferredCodec = .h264
        settings.audioRedirectionEnabled = true

        let endpoint = SkyBridgeMediaEndpoint(
            host: "relay.example.com",
            port: 34_78,
            relayToken: "relay-token",
            expiresAt: 1_700_000_120
        )
        let payload = RemoteDesktopViewerStreamConfigurationFactory.makePayload(
            .init(
                viewerSettings: settings,
                supportedVideoFormats: ["hevc", "h264"],
                preferredCodec: "h264",
                activeTransportMode: .lan,
                strictMediaValidationEnabled: false,
                hasRenderedCrossNetworkNativeFrame: false,
                nativeAudioReceiveEnabled: false,
                realtimeMediaAudioMode: .highFidelity,
                mediaAudioEndpoint: endpoint,
                mediaSessionId: "media-session-a",
                streamRefreshToken: 42,
                securityIdentity: nil,
                smokeDimensions: nil,
                smokeTargetFrameRate: nil
            )
        )

        XCTAssertEqual(payload.width, 1920)
        XCTAssertEqual(payload.height, 1080)
        XCTAssertEqual(payload.preferredCodec, "h264")
        XCTAssertEqual(payload.supportedVideoFormats, ["hevc", "h264"])
        XCTAssertEqual(payload.screenFrameTransport, "sbrf-v1")
        XCTAssertEqual(payload.screenDataChannelEnabled, true)
        XCTAssertEqual(payload.screenChannelWireFormat, "sbc2-chunked-v1")
        XCTAssertNil(payload.nativeVideoTrackReady)
        XCTAssertEqual(payload.audioTransport, "pqc-media-v1")
        XCTAssertEqual(payload.audioMode, SkyBridgeMediaAudioMode.highFidelity.rawValue)
        XCTAssertEqual(payload.mediaSessionId, "media-session-a")
        XCTAssertEqual(payload.mediaAudioEndpoint?.host, "relay.example.com")
        XCTAssertEqual(payload.mediaAudioEndpoint?.port, 34_78)
        XCTAssertEqual(payload.mediaFallbackPolicy, "fail-fast")
        XCTAssertEqual(payload.streamRefreshToken, 42)
    }

    func testCrossNetworkStrictPayloadForbidsFallbackAndAdvertisesNativeMainPath() {
        var settings = RemoteDesktopViewerSettings()
        settings.frameRate = .fps60
        settings.preferredCodec = .h264
        settings.lowLatencyMode = false

        let payload = RemoteDesktopViewerStreamConfigurationFactory.makePayload(
            .init(
                viewerSettings: settings,
                supportedVideoFormats: ["h264", "hevc"],
                preferredCodec: "h264",
                activeTransportMode: .crossNetwork,
                strictMediaValidationEnabled: true,
                hasRenderedCrossNetworkNativeFrame: true,
                nativeAudioReceiveEnabled: false,
                realtimeMediaAudioMode: .highFidelity,
                mediaAudioEndpoint: nil,
                mediaSessionId: nil,
                streamRefreshToken: nil,
                securityIdentity: nil,
                smokeDimensions: nil,
                smokeTargetFrameRate: nil
            )
        )

        XCTAssertEqual(payload.preferredCodec, "hevc")
        XCTAssertEqual(payload.supportedVideoFormats, ["hevc"])
        XCTAssertEqual(payload.screenFrameTransport, "webrtc-native-main")
        XCTAssertEqual(payload.screenDataChannelEnabled, false)
        XCTAssertEqual(payload.screenChannelWireFormat, "sbc2-chunked-v1")
        XCTAssertEqual(payload.nativeVideoTrackReady, true)
        XCTAssertEqual(payload.damageTrackingEnabled, false)
        XCTAssertEqual(payload.lowLatencyMode, true)
        XCTAssertEqual(payload.keyFrameInterval, 60)
        XCTAssertEqual(payload.performanceValidationMode, "extreme")
        XCTAssertEqual(payload.mediaFallbackPolicy, "forbidden")
        XCTAssertEqual(payload.audioRedirectionEnabled, false)
        XCTAssertEqual(payload.audioTransport, SkyBridgeRealtimeMediaConstants.audioTransportDisabled)
        XCTAssertNil(payload.audioMode)
        XCTAssertNil(payload.mediaSessionId)
        XCTAssertNil(payload.mediaAudioEndpoint)
    }

    func testCrossNetworkAudioIntentWithoutEndpointProducesExplicitVideoOnlyPayload() {
        var settings = RemoteDesktopViewerSettings()
        settings.audioRedirectionEnabled = true

        let payload = RemoteDesktopViewerStreamConfigurationFactory.makePayload(
            .init(
                viewerSettings: settings,
                supportedVideoFormats: ["h264", "hevc"],
                preferredCodec: "h264",
                activeTransportMode: .crossNetwork,
                strictMediaValidationEnabled: true,
                hasRenderedCrossNetworkNativeFrame: false,
                nativeAudioReceiveEnabled: false,
                realtimeMediaAudioMode: .highFidelity,
                mediaAudioEndpoint: nil,
                mediaSessionId: nil,
                streamRefreshToken: nil,
                securityIdentity: nil,
                smokeDimensions: nil,
                smokeTargetFrameRate: nil
            )
        )

        XCTAssertEqual(payload.screenFrameTransport, "webrtc-native-main")
        XCTAssertEqual(payload.mediaFallbackPolicy, "forbidden")
        XCTAssertEqual(payload.audioRedirectionEnabled, false)
        XCTAssertEqual(payload.audioTransport, SkyBridgeRealtimeMediaConstants.audioTransportDisabled)
        XCTAssertNil(payload.audioMode)
        XCTAssertNil(payload.mediaSessionId)
        XCTAssertNil(payload.mediaAudioEndpoint)
    }

    func testCrossNetworkAudioEndpointProducesPQCRealtimeAudioPayload() {
        var settings = RemoteDesktopViewerSettings()
        settings.audioRedirectionEnabled = true
        let endpoint = SkyBridgeMediaEndpoint(host: "relay.example.com", port: 44_44)

        let payload = RemoteDesktopViewerStreamConfigurationFactory.makePayload(
            .init(
                viewerSettings: settings,
                supportedVideoFormats: ["h264", "hevc"],
                preferredCodec: "h264",
                activeTransportMode: .crossNetwork,
                strictMediaValidationEnabled: true,
                hasRenderedCrossNetworkNativeFrame: false,
                nativeAudioReceiveEnabled: false,
                realtimeMediaAudioMode: .lowLatency,
                mediaAudioEndpoint: endpoint,
                mediaSessionId: "media-session-ready",
                streamRefreshToken: nil,
                securityIdentity: nil,
                smokeDimensions: nil,
                smokeTargetFrameRate: nil
            )
        )

        XCTAssertEqual(payload.audioRedirectionEnabled, true)
        XCTAssertEqual(payload.audioTransport, SkyBridgeRealtimeMediaConstants.audioTransportPQCv1)
        XCTAssertEqual(payload.audioMode, SkyBridgeMediaAudioMode.lowLatency.rawValue)
        XCTAssertEqual(payload.mediaSessionId, "media-session-ready")
        XCTAssertEqual(payload.mediaAudioEndpoint, endpoint)
    }

    func testSmokeOverridesWinAndRefreshTokenIsPassThrough() {
        var settings = RemoteDesktopViewerSettings()
        settings.resolution = .uhd4k
        settings.frameRate = .fps30

        let payload = RemoteDesktopViewerStreamConfigurationFactory.makePayload(
            .init(
                viewerSettings: settings,
                supportedVideoFormats: ["h264"],
                preferredCodec: "h264",
                activeTransportMode: .lan,
                strictMediaValidationEnabled: false,
                hasRenderedCrossNetworkNativeFrame: false,
                nativeAudioReceiveEnabled: false,
                realtimeMediaAudioMode: .highFidelity,
                mediaAudioEndpoint: nil,
                mediaSessionId: nil,
                streamRefreshToken: 99,
                securityIdentity: nil,
                smokeDimensions: (width: 1600, height: 900),
                smokeTargetFrameRate: 45
            )
        )

        XCTAssertEqual(payload.width, 1600)
        XCTAssertEqual(payload.height, 900)
        XCTAssertEqual(payload.targetFrameRate, 45)
        XCTAssertEqual(payload.adaptiveResolutionEnabled, false)
        XCTAssertEqual(payload.streamRefreshToken, 99)
    }
}
