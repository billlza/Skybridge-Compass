#if os(macOS)
import CoreMedia
import ScreenCaptureKit
import VideoToolbox
import XCTest
@testable import SkyBridgeCore

final class ScreenCaptureKitStreamerFrameStatusTests: XCTestCase {
    func testStartedAndCompleteFramesRemainProcessable() {
        XCTAssertTrue(ScreenCaptureKitStreamer.shouldProcessFrame(with: nil))
        XCTAssertTrue(ScreenCaptureKitStreamer.shouldProcessFrame(with: .started))
        XCTAssertTrue(ScreenCaptureKitStreamer.shouldProcessFrame(with: .complete))
    }

    func testIdleBlankSuspendedAndStoppedFramesAreDropped() {
        XCTAssertFalse(ScreenCaptureKitStreamer.shouldProcessFrame(with: .idle))
        XCTAssertFalse(ScreenCaptureKitStreamer.shouldProcessFrame(with: .blank))
        XCTAssertFalse(ScreenCaptureKitStreamer.shouldProcessFrame(with: .suspended))
        XCTAssertFalse(ScreenCaptureKitStreamer.shouldProcessFrame(with: .stopped))
    }

    func testEncodeFrameDurationUsesRequestedFPSAndNeverZero() {
        let duration = ScreenCaptureKitStreamer.encodeFrameDuration(forConfiguredFPS: 60)

        XCTAssertEqual(duration.value, 1)
        XCTAssertEqual(duration.timescale, 60)
        XCTAssertTrue(CMTimeCompare(duration, .zero) > 0)

        let clamped = ScreenCaptureKitStreamer.encodeFrameDuration(forConfiguredFPS: 0)
        XCTAssertEqual(clamped.value, 1)
        XCTAssertEqual(clamped.timescale, 1)
        XCTAssertTrue(CMTimeCompare(clamped, .zero) > 0)
    }

    func testEncodeLatencyPercentilesAreDeterministic() {
        let empty = ScreenCaptureKitStreamer.encodeLatencyPercentiles([])
        XCTAssertNil(empty.p50)
        XCTAssertNil(empty.p95)
        XCTAssertNil(empty.max)

        let single = ScreenCaptureKitStreamer.encodeLatencyPercentiles([7.25])
        XCTAssertEqual(single.p50, 7.25)
        XCTAssertEqual(single.p95, 7.25)
        XCTAssertEqual(single.max, 7.25)

        let spread = ScreenCaptureKitStreamer.encodeLatencyPercentiles([10, 1, 7, 3])
        XCTAssertEqual(spread.p50, 7)
        XCTAssertEqual(spread.p95, 10)
        XCTAssertEqual(spread.max, 10)
    }

    func testStrictEncoderSpecificationRequiresHardwareEncoder() throws {
        let specification = try XCTUnwrap(
            ScreenCaptureKitStreamer.videoEncoderSpecification(
                codec: kCMVideoCodecType_H264,
                lowLatencyMode: false,
                requiresHardwareEncoder: true,
                preferredProfile: .auto
            ) as NSDictionary?
        )

        XCTAssertEqual(
            specification[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String] as? Bool,
            true
        )
    }

    func testLowLatencyRateControlOnlyAppliesToCompatibleH264Profiles() throws {
        XCTAssertTrue(
            ScreenCaptureKitStreamer.shouldEnableLowLatencyRateControl(
                codec: kCMVideoCodecType_H264,
                lowLatencyMode: true,
                preferredProfile: .auto
            )
        )
        XCTAssertFalse(
            ScreenCaptureKitStreamer.shouldEnableLowLatencyRateControl(
                codec: kCMVideoCodecType_HEVC,
                lowLatencyMode: true,
                preferredProfile: .auto
            )
        )
        XCTAssertFalse(
            ScreenCaptureKitStreamer.shouldEnableLowLatencyRateControl(
                codec: kCMVideoCodecType_H264,
                lowLatencyMode: true,
                preferredProfile: .h264Baseline
            )
        )

        let specification = try XCTUnwrap(
            ScreenCaptureKitStreamer.videoEncoderSpecification(
                codec: kCMVideoCodecType_H264,
                lowLatencyMode: true,
                requiresHardwareEncoder: false,
                preferredProfile: .auto
            ) as NSDictionary?
        )
        XCTAssertEqual(
            specification[kVTVideoEncoderSpecification_EnableLowLatencyRateControl as String] as? Bool,
            true
        )
    }
}
#endif
