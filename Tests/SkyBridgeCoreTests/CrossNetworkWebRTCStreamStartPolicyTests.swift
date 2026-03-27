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
}
