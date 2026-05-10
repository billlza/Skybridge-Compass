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

    func testIdleFramesCanBeKeptForHighFpsVideoCadence() {
        XCTAssertTrue(ScreenCaptureKitStreamer.shouldProcessFrame(with: .idle, includeIdleFrames: true))
        XCTAssertFalse(ScreenCaptureKitStreamer.shouldProcessFrame(with: .blank, includeIdleFrames: true))
        XCTAssertFalse(ScreenCaptureKitStreamer.shouldProcessFrame(with: .suspended, includeIdleFrames: true))
        XCTAssertFalse(ScreenCaptureKitStreamer.shouldProcessFrame(with: .stopped, includeIdleFrames: true))
    }

    func testOnlyIdleFramesCanReuseLatestFrameForCadence() {
        XCTAssertTrue(ScreenCaptureKitStreamer.shouldReuseLatestFrameForCadence(with: .idle))
        XCTAssertFalse(ScreenCaptureKitStreamer.shouldReuseLatestFrameForCadence(with: nil))
        XCTAssertFalse(ScreenCaptureKitStreamer.shouldReuseLatestFrameForCadence(with: .blank))
        XCTAssertFalse(ScreenCaptureKitStreamer.shouldReuseLatestFrameForCadence(with: .suspended))
        XCTAssertFalse(ScreenCaptureKitStreamer.shouldReuseLatestFrameForCadence(with: .stopped))
        XCTAssertFalse(ScreenCaptureKitStreamer.shouldReuseLatestFrameForCadence(with: .complete))
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

    func testHighFps2KUsesDeeperScreenCaptureQueueWithoutExceedingAppleCap() {
        XCTAssertEqual(
            ScreenCaptureKitStreamer.captureQueueDepth(
                lowLatencyEnabled: true,
                targetFPS: 60,
                width: 2056,
                height: 1329
            ),
            6
        )
        XCTAssertEqual(
            ScreenCaptureKitStreamer.captureQueueDepth(
                lowLatencyEnabled: false,
                targetFPS: 60,
                width: 2560,
                height: 1600
            ),
            7
        )
        XCTAssertLessThanOrEqual(
            ScreenCaptureKitStreamer.captureQueueDepth(
                lowLatencyEnabled: false,
                targetFPS: 120,
                width: 6016,
                height: 3384
            ),
            8
        )
    }

    func testDisplayCadenceEncoderOnlyRunsForHighFpsEncodedVideo() {
        XCTAssertTrue(
            ScreenCaptureKitStreamer.shouldRunDisplayCadenceEncoder(
                jpegMode: false,
                hasEncodedFrameSink: true,
                targetFPS: 60
            )
        )
        XCTAssertFalse(
            ScreenCaptureKitStreamer.shouldRunDisplayCadenceEncoder(
                jpegMode: true,
                hasEncodedFrameSink: true,
                targetFPS: 60
            )
        )
        XCTAssertFalse(
            ScreenCaptureKitStreamer.shouldRunDisplayCadenceEncoder(
                jpegMode: false,
                hasEncodedFrameSink: false,
                targetFPS: 60
            )
        )
        XCTAssertFalse(
            ScreenCaptureKitStreamer.shouldRunDisplayCadenceEncoder(
                jpegMode: false,
                hasEncodedFrameSink: true,
                targetFPS: 30
            )
        )
    }

    func testAudioOnlyCaptureStillRegistersScreenOutputForSCKStability() {
        XCTAssertTrue(
            ScreenCaptureKitStreamer.shouldRegisterScreenOutput(
                captureVideoOutput: false,
                requestedSystemAudio: true
            )
        )
        XCTAssertTrue(
            ScreenCaptureKitStreamer.shouldRegisterScreenOutput(
                captureVideoOutput: true,
                requestedSystemAudio: false
            )
        )
        XCTAssertFalse(
            ScreenCaptureKitStreamer.shouldRegisterScreenOutput(
                captureVideoOutput: false,
                requestedSystemAudio: false
            )
        )
    }

    func testCadencePresentationTimeUsesHostClockScale() {
        let pts = ScreenCaptureKitStreamer.presentationTimeFromUptimeNanoseconds(1_500_000_000)

        XCTAssertEqual(pts.value, 1_500_000_000)
        XCTAssertEqual(pts.timescale, 1_000_000_000)
        XCTAssertTrue(pts.isValid)
    }

    func testHighFpsCadenceTimerPollsFasterThanTargetFrameInterval() {
        XCTAssertEqual(
            ScreenCaptureKitStreamer.cadenceTimerIntervalNanoseconds(forConfiguredFPS: 60),
            8_333_333
        )
        XCTAssertEqual(
            ScreenCaptureKitStreamer.cadenceTimerIntervalNanoseconds(forConfiguredFPS: 30),
            33_333_333
        )
    }

    func testCadenceSubmissionStartsFromCurrentHostTime() {
        XCTAssertEqual(
            ScreenCaptureKitStreamer.cadenceSubmissionTargetUptimes(
                lastSubmittedAt: 0,
                nowNanos: 1_000_000_000,
                configuredFPS: 60,
                maxCatchUpFrames: 3
            ),
            [1_000_000_000]
        )
    }

    func testCadenceSubmissionDoesNotRunBeforeFrameInterval() {
        let lastSubmittedAt: UInt64 = 1_000_000_000

        XCTAssertEqual(
            ScreenCaptureKitStreamer.cadenceSubmissionTargetUptimes(
                lastSubmittedAt: lastSubmittedAt,
                nowNanos: lastSubmittedAt + 8_000_000,
                configuredFPS: 60,
                maxCatchUpFrames: 3
            ),
            []
        )
    }

    func testCadenceSubmissionAdvancesOnIdealFrameBoundary() {
        let lastSubmittedAt: UInt64 = 1_000_000_000

        XCTAssertEqual(
            ScreenCaptureKitStreamer.cadenceSubmissionTargetUptimes(
                lastSubmittedAt: lastSubmittedAt,
                nowNanos: lastSubmittedAt + 20_000_000,
                configuredFPS: 60,
                maxCatchUpFrames: 3
            ),
            [lastSubmittedAt + 16_666_666]
        )
    }

    func testCadenceSubmissionSkipsExpiredCatchUpFrames() {
        let lastSubmittedAt: UInt64 = 1_000_000_000

        let targets = ScreenCaptureKitStreamer.cadenceSubmissionTargetUptimes(
            lastSubmittedAt: lastSubmittedAt,
            nowNanos: lastSubmittedAt + 200_000_000,
            configuredFPS: 60,
            maxCatchUpFrames: 3
        )

        XCTAssertEqual(
            targets,
            [
                lastSubmittedAt + 199_999_992
            ]
        )
        XCTAssertTrue(targets.allSatisfy { $0 <= lastSubmittedAt + 200_000_000 })
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
