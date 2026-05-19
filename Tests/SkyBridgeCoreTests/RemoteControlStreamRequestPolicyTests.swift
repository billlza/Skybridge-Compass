import XCTest
import SkyBridgeRealtimeMedia
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

    private func streamConfiguration(
        width: Int? = nil,
        height: Int? = nil,
        preferredCodec: String? = "h264",
        adaptiveResolutionEnabled: Bool? = false,
        targetFrameRate: Int = 60,
        keyFrameInterval: Int = 60,
        performanceValidationMode: String? = nil,
        mediaAudioEndpoint: SkyBridgeMediaEndpoint? = nil,
        streamRefreshToken: UInt64? = nil
    ) -> RemoteDesktopStreamConfiguration {
        RemoteDesktopStreamConfiguration(
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
            audioRedirectionEnabled: mediaAudioEndpoint != nil,
            audioTransport: mediaAudioEndpoint == nil ? nil : SkyBridgeRealtimeMediaConstants.audioTransportPQCv1,
            audioMode: mediaAudioEndpoint == nil ? nil : SkyBridgeMediaAudioMode.highFidelity.rawValue,
            mediaSessionId: mediaAudioEndpoint == nil ? nil : "media-session",
            mediaAudioEndpoint: mediaAudioEndpoint,
            performanceValidationMode: performanceValidationMode,
            streamRefreshToken: streamRefreshToken
        )
    }
}
