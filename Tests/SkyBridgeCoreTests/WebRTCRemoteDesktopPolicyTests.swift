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
        XCTAssertLessThanOrEqual(policy.targetFrameRate, 15)
        XCTAssertEqual(policy.preferredSize, CGSize(width: 1920, height: 1200))
        XCTAssertTrue(policy.reason.contains("relay"))
    }

    func testRelayPathAllowsNativeRTPMainWhenNativeScreenTrackIsEnabled() {
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
            isAppleSilicon: true,
            nativeVideoTrackEnabled: true
        )

        XCTAssertEqual(policy.codec, .h264)
        XCTAssertTrue(policy.usesHardwareEncoder)
        XCTAssertGreaterThan(policy.targetFrameRate, 15)
        XCTAssertEqual(policy.preferredSize, CGSize(width: 2560, height: 1600))
        XCTAssertTrue(policy.reason.contains("relay-native-rtp"))
    }

    func testLowLatencyRelayNativeRTPKeepsRequestedResolutionAtThirtyFPS() {
        let policy = WebRTCRemoteDesktopVideoPolicySelector.select(
            request: .init(
                preferredSize: CGSize(width: 2056, height: 1329),
                preferredCodec: .h264,
                requestedFrameRate: 30,
                keyFrameInterval: 30,
                lowLatencyMode: true,
                enableHardwareAcceleration: true,
                enableAppleSiliconOptimization: true
            ),
            transportPath: .relay,
            peerFormats: ["jpeg", "h264"],
            thermalState: .nominal,
            isAppleSilicon: true,
            nativeVideoTrackEnabled: true
        )

        XCTAssertEqual(policy.codec, .h264)
        XCTAssertEqual(policy.targetFrameRate, 30)
        XCTAssertEqual(policy.preferredSize, CGSize(width: 2056, height: 1329))
        XCTAssertTrue(policy.usesHardwareEncoder)
    }

    func testNativeFailureFallbackUsesBoundedDegradedEmergencyProfile() {
        let policy = WebRTCRemoteDesktopVideoPolicy(
            codec: .hevc,
            targetFrameRate: 60,
            keyFrameInterval: 120,
            preferredSize: CGSize(width: 2056, height: 1328),
            usesHardwareEncoder: true,
            reason: "direct-high-fps-lan-hevc-probe"
        )

        let degraded = WebRTCRemoteDesktopVideoPolicySelector.degradedFallbackPolicy(from: policy)

        XCTAssertEqual(degraded.codec, .bgra)
        XCTAssertFalse(degraded.usesHardwareEncoder)
        XCTAssertEqual(degraded.targetFrameRate, WebRTCDegradedFallbackJPEGProfile.targetFrameRate)
        XCTAssertLessThanOrEqual(max(degraded.preferredSize.width, degraded.preferredSize.height), 1280)
        XCTAssertTrue(degraded.reason.contains("degraded-emergency-jpeg"))
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

        XCTAssertGreaterThanOrEqual(h264Budget.frameRate, jpegBudget.frameRate)
        XCTAssertEqual(jpegBudget.maxBufferedAmountBytes, 384_000)
        XCTAssertEqual(h264Budget.maxBufferedAmountBytes, jpegBudget.maxBufferedAmountBytes)
    }

    func testRelayFallbackBudgetUsesEmergencyCeilingOnlyWhenNativeTrackIsEnabled() {
        let fallbackBudget = WebRTCRemoteDesktopBudgetSelector.select(
            requestedFrameRate: 60,
            transportPath: .relay,
            thermalState: .nominal,
            longEdge: 1920,
            lowLatencyMode: true,
            codec: .bgra,
            nativeVideoTrackEnabled: true,
            enableHardwareAcceleration: true,
            enableAppleSiliconOptimization: true,
            isAppleSilicon: true
        )

        XCTAssertLessThanOrEqual(fallbackBudget.frameRate, WebRTCDegradedFallbackJPEGProfile.targetFrameRate)
        XCTAssertLessThan(
            WebRTCDegradedFallbackJPEGProfile.maxEncodedFrameBytes,
            WebRTCDegradedFallbackJPEGProfile.maxTransportFrameBytes
        )
        XCTAssertEqual(
            fallbackBudget.maxBufferedAmountBytes,
            UInt64(WebRTCDegradedFallbackJPEGProfile.maxTransportFrameBytes)
        )
        XCTAssertEqual(fallbackBudget.reason, "relay-degraded-emergency-jpeg")
    }

    func testRelayNativeRTPBudgetDoesNotInheritJPEGFallbackCeiling() {
        let nativeBudget = WebRTCRemoteDesktopBudgetSelector.select(
            requestedFrameRate: 60,
            transportPath: .relay,
            thermalState: .nominal,
            longEdge: 1920,
            lowLatencyMode: true,
            codec: .h264,
            nativeVideoTrackEnabled: true,
            enableHardwareAcceleration: true,
            enableAppleSiliconOptimization: true,
            isAppleSilicon: true
        )

        XCTAssertGreaterThan(nativeBudget.frameRate, WebRTCDegradedFallbackJPEGProfile.targetFrameRate)
        XCTAssertGreaterThan(nativeBudget.maxBufferedAmountBytes, UInt64(WebRTCDegradedFallbackJPEGProfile.maxEncodedFrameBytes))
        XCTAssertTrue(nativeBudget.reason.contains("relay-native-rtp"))
    }

    func testScreenCaptureKitJPEGModeUsesDegradedFallbackBudgetProfile() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent(
            "Sources/SkyBridgeCore/RemoteControl/ScreenCaptureKitStreamer.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("jpegFallbackProfile.constrainedSize"))
        XCTAssertTrue(source.contains("emitsDegradedFallbackJPEGFrames"))
        XCTAssertTrue(source.contains("degradedFallbackJPEGProfile: WebRTCDegradedFallbackJPEGProfile? = nil"))
        XCTAssertTrue(source.contains("failFastOnMediaFallbacks: Bool = false"))
        XCTAssertTrue(source.contains("strict-audio-start-failed"))
        XCTAssertTrue(source.contains("strict-video-codec-fallback-forbidden"))
        XCTAssertTrue(source.contains("strict-aac-encode-failed"))
        XCTAssertTrue(source.contains("encodeDegradedFallbackJPEG"))
        XCTAssertTrue(source.contains("profile.maxEncodedFrameBytes"))
        XCTAssertTrue(source.contains("profile.qualityLadder"))
        let rawFrameCallbackIndex = try XCTUnwrap(source.range(of: "guard let owner, let onRawFrame = owner.onRawFrame")?.lowerBound)
        let jpegModeIndex = try XCTUnwrap(source.range(of: "if owner.jpegMode")?.lowerBound)
        XCTAssertLessThan(
            source.distance(from: source.startIndex, to: rawFrameCallbackIndex),
            source.distance(from: source.startIndex, to: jpegModeIndex),
            "JPEG fallback mode must still submit raw pixel buffers to the native WebRTC video sender."
        )
        XCTAssertFalse(
            source.contains("kCGImageDestinationLossyCompressionQuality: 0.65"),
            "SCK JPEG fallback must not bypass the degraded profile with a fixed high quality."
        )
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
