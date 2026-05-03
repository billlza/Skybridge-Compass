import XCTest
@testable import SkyBridgeCore

final class RemoteControlStreamPolicyTests: XCTestCase {
    private func makeRequest(
        size: CGSize,
        codec: PreferredVideoCodec = .hevc,
        fps: Int = 60,
        gop: Int = 60,
        lowLatency: Bool = false,
        hardware: Bool = true,
        appleSiliconOptimization: Bool = true
    ) -> RemoteControlStreamRequest {
        RemoteControlStreamRequest(
            preferredSize: size,
            preferredCodec: codec,
            targetFrameRate: fps,
            keyFrameInterval: gop,
            lowLatencyMode: lowLatency,
            enableHardwareAcceleration: hardware,
            enableAppleSiliconOptimization: appleSiliconOptimization
        )
    }

    func testSelectorUsesHevcFor5KPeerThatSupportsHevc() {
        let policy = RemoteControlStreamPolicySelector.select(
            request: makeRequest(size: CGSize(width: 5120, height: 2880), codec: .hevc, fps: 120),
            peerFormats: ["jpeg", "h264", "hevc"],
            thermalState: .nominal,
            isAppleSilicon: true
        )

        XCTAssertEqual(policy.codec, .hevc)
        XCTAssertEqual(policy.targetFrameRate, 120)
    }

    func testSelectorFallsBackToH264ForUnknownLegacyPeer() {
        let policy = RemoteControlStreamPolicySelector.select(
            request: makeRequest(size: CGSize(width: 1920, height: 1080), codec: .hevc, fps: 60),
            peerFormats: [],
            thermalState: .nominal,
            isAppleSilicon: true
        )

        XCTAssertEqual(policy.codec, .h264)
        XCTAssertEqual(policy.targetFrameRate, 60)
    }

    func testSelectorPrefersH264WhenLowLatencyIsEnabled() {
        let policy = RemoteControlStreamPolicySelector.select(
            request: makeRequest(
                size: CGSize(width: 2560, height: 1440),
                codec: .hevc,
                fps: 120,
                gop: 120,
                lowLatency: true
            ),
            peerFormats: ["jpeg", "h264", "hevc"],
            thermalState: .nominal,
            isAppleSilicon: true
        )

        XCTAssertEqual(policy.codec, .h264)
        XCTAssertEqual(policy.targetFrameRate, 60)
        XCTAssertLessThanOrEqual(policy.keyFrameInterval, 30)
    }

    func testSelectorReducesFrameRateUnderThermalPressure() {
        let policy = RemoteControlStreamPolicySelector.select(
            request: makeRequest(size: CGSize(width: 5120, height: 2880), codec: .hevc, fps: 120),
            peerFormats: ["jpeg", "hevc"],
            thermalState: .serious,
            isAppleSilicon: true
        )

        XCTAssertEqual(policy.codec, .hevc)
        XCTAssertEqual(policy.targetFrameRate, 45)
    }

    func testSelectorNormalizesEncodedStreamDimensions() {
        let policy = RemoteControlStreamPolicySelector.select(
            request: makeRequest(size: CGSize(width: 2056, height: 1329), codec: .h264, fps: 60),
            peerFormats: ["jpeg", "h264"],
            thermalState: .nominal,
            isAppleSilicon: true
        )

        XCTAssertEqual(policy.codec, .h264)
        XCTAssertEqual(policy.preferredSize.width, 2056)
        XCTAssertEqual(policy.preferredSize.height, 1328)
    }

    func testSelectorProbesHEVCForHighResolutionHighFPSLANWhenPeerSupportsIt() {
        let policy = RemoteControlStreamPolicySelector.select(
            request: makeRequest(size: CGSize(width: 2056, height: 1328), codec: .h264, fps: 60),
            peerFormats: ["jpeg", "h264", "hevc"],
            thermalState: .nominal,
            isAppleSilicon: true
        )

        XCTAssertEqual(policy.codec, .hevc)
        XCTAssertEqual(policy.targetFrameRate, 60)
        XCTAssertEqual(policy.reason, "high-fps-lan-hevc-probe")
    }

    func testSharedAudioFallbackProtectionCapsVideoLoad() {
        let policy = RemoteControlStreamPolicySelector.select(
            request: makeRequest(size: CGSize(width: 2056, height: 1328), codec: .h264, fps: 60, gop: 120),
            peerFormats: ["jpeg", "h264"],
            thermalState: .nominal,
            isAppleSilicon: true
        ).protectingRealtimeAudio()

        XCTAssertEqual(policy.codec, .h264)
        XCTAssertEqual(policy.targetFrameRate, 24)
        XCTAssertEqual(policy.keyFrameInterval, 48)
        XCTAssertEqual(policy.preferredSize.width, 1920)
        XCTAssertEqual(policy.preferredSize.height, 1240)
        XCTAssertTrue(policy.reason.contains("+audio-protect"))
    }

    func testSharedAudioFallbackProtectionCapsFrameRateWithoutResizingConservativePolicy() {
        let policy = RemoteControlStreamPolicySelector.select(
            request: makeRequest(size: CGSize(width: 1280, height: 720), codec: .h264, fps: 30),
            peerFormats: ["jpeg", "h264"],
            thermalState: .nominal,
            isAppleSilicon: true
        )

        let protectedPolicy = policy.protectingRealtimeAudio()

        XCTAssertEqual(protectedPolicy.targetFrameRate, 24)
        XCTAssertEqual(protectedPolicy.keyFrameInterval, 48)
        XCTAssertEqual(protectedPolicy.preferredSize, policy.preferredSize)
        XCTAssertTrue(protectedPolicy.reason.contains("+audio-protect"))
    }
}
