import CoreGraphics
import XCTest
@testable import SkyBridgeCore

final class WebRTCRemoteDesktopVideoPolicyTests: XCTestCase {
    private func makeRequest(
        size: CGSize,
        codec: PreferredVideoCodec = .hevc,
        fps: Int = 60,
        gop: Int = 60,
        lowLatency: Bool = false,
        hardware: Bool = true,
        appleSiliconOptimization: Bool = true
    ) -> WebRTCRemoteDesktopVideoRequest {
        WebRTCRemoteDesktopVideoRequest(
            preferredSize: size,
            preferredCodec: codec,
            requestedFrameRate: fps,
            keyFrameInterval: gop,
            lowLatencyMode: lowLatency,
            enableHardwareAcceleration: hardware,
            enableAppleSiliconOptimization: appleSiliconOptimization
        )
    }

    func testDirectPathSelectsHevcWhenPeerSupportsIt() {
        let policy = WebRTCRemoteDesktopVideoPolicySelector.select(
            request: makeRequest(size: CGSize(width: 5120, height: 2880), codec: .hevc, fps: 120),
            transportPath: .direct,
            peerFormats: ["jpeg", "h264", "hevc"],
            thermalState: .nominal,
            isAppleSilicon: true
        )

        XCTAssertEqual(policy.codec, .hevc)
        XCTAssertTrue(policy.usesHardwareEncoder)
        XCTAssertEqual(policy.targetFrameRate, 120)
    }

    func testDirectPathFallsBackToJpegForLegacyPeer() {
        let policy = WebRTCRemoteDesktopVideoPolicySelector.select(
            request: makeRequest(size: CGSize(width: 1920, height: 1080), codec: .hevc, fps: 60),
            transportPath: .direct,
            peerFormats: ["jpeg"],
            thermalState: .nominal,
            isAppleSilicon: true
        )

        XCTAssertEqual(policy.codec, .bgra)
        XCTAssertFalse(policy.usesHardwareEncoder)
    }

    func testRelayPathKeepsConservativeJpegFallback() {
        let policy = WebRTCRemoteDesktopVideoPolicySelector.select(
            request: makeRequest(size: CGSize(width: 3840, height: 2160), codec: .hevc, fps: 120),
            transportPath: .relay,
            peerFormats: ["jpeg", "h264", "hevc"],
            thermalState: .nominal,
            isAppleSilicon: true
        )

        XCTAssertEqual(policy.codec, .bgra)
        XCTAssertFalse(policy.usesHardwareEncoder)
        XCTAssertTrue(policy.reason.contains("relay"))
    }

    func testSharedAudioFallbackProtectionCapsDirectHardwarePolicy() {
        let policy = WebRTCRemoteDesktopVideoPolicySelector.select(
            request: makeRequest(size: CGSize(width: 2056, height: 1328), codec: .h264, fps: 60, gop: 120),
            transportPath: .direct,
            peerFormats: ["jpeg", "h264"],
            thermalState: .nominal,
            isAppleSilicon: true
        ).protectingRealtimeAudio()

        XCTAssertEqual(policy.codec, .h264)
        XCTAssertTrue(policy.usesHardwareEncoder)
        XCTAssertEqual(policy.targetFrameRate, 24)
        XCTAssertEqual(policy.keyFrameInterval, 48)
        XCTAssertEqual(policy.preferredSize.width, 1920)
        XCTAssertEqual(policy.preferredSize.height, 1240)
        XCTAssertTrue(policy.reason.contains("+audio-protect"))
    }
}
