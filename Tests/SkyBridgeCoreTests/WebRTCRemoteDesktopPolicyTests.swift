import CoreGraphics
import XCTest
@testable import SkyBridgeCore

final class WebRTCRemoteDesktopPolicyTests: XCTestCase {
    func testRelayPathFallsBackToConservativeJPEGEvenWhenPeerSupportsH264() {
        let policy = WebRTCRemoteDesktopVideoPolicySelector.select(
            request: .init(
                preferredSize: CGSize(width: 2560, height: 1600),
                preferredCodec: .h264,
                requestedFrameRate: 60,
                keyFrameInterval: 60,
                lowLatencyMode: true,
                enableHardwareAcceleration: true,
                enableAppleSiliconOptimization: true
            ),
            transportPath: .relay,
            peerFormats: ["jpeg", "h264"],
            thermalState: .nominal,
            isAppleSilicon: true
        )

        XCTAssertEqual(policy.codec, .bgra)
        XCTAssertFalse(policy.usesHardwareEncoder)
        XCTAssertLessThanOrEqual(policy.targetFrameRate, 24)
        XCTAssertEqual(policy.preferredSize, CGSize(width: 1920, height: 1200))
        XCTAssertTrue(policy.reason.contains("relay"))
    }

    func testRelayBudgetKeepsSameConservativeLimitsAcrossCodecs() {
        let jpegBudget = WebRTCRemoteDesktopBudgetSelector.select(
            requestedFrameRate: 60,
            transportPath: .relay,
            thermalState: .nominal,
            longEdge: 1920,
            lowLatencyMode: true,
            codec: .bgra,
            enableHardwareAcceleration: true,
            enableAppleSiliconOptimization: true,
            isAppleSilicon: true
        )
        let h264Budget = WebRTCRemoteDesktopBudgetSelector.select(
            requestedFrameRate: 60,
            transportPath: .relay,
            thermalState: .nominal,
            longEdge: 1920,
            lowLatencyMode: true,
            codec: .h264,
            enableHardwareAcceleration: true,
            enableAppleSiliconOptimization: true,
            isAppleSilicon: true
        )

        XCTAssertEqual(h264Budget.frameRate, jpegBudget.frameRate)
        XCTAssertEqual(h264Budget.maxBufferedAmountBytes, jpegBudget.maxBufferedAmountBytes)
    }

    func testUnknownPathFallsBackToJPEGWhenHardwareEncodeUnavailable() {
        let policy = WebRTCRemoteDesktopVideoPolicySelector.select(
            request: .init(
                preferredSize: CGSize(width: 1920, height: 1080),
                preferredCodec: .hevc,
                requestedFrameRate: 60,
                keyFrameInterval: 60,
                lowLatencyMode: false,
                enableHardwareAcceleration: false,
                enableAppleSiliconOptimization: false
            ),
            transportPath: .unknown,
            peerFormats: ["jpeg", "h264", "hevc"],
            thermalState: .nominal,
            isAppleSilicon: true
        )

        XCTAssertEqual(policy.codec, .bgra)
        XCTAssertFalse(policy.usesHardwareEncoder)
    }
}
