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
            8
        )
        XCTAssertEqual(
            ScreenCaptureKitStreamer.captureQueueDepth(
                lowLatencyEnabled: false,
                targetFPS: 60,
                width: 2560,
                height: 1600
            ),
            8
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

    func testAudioOnlyCaptureUsesDistinctSmokeStatusPrefix() {
        XCTAssertEqual(
            ScreenCaptureKitStreamer.startSmokeStatusPrefix(
                captureVideoOutput: true,
                requestedSystemAudio: true
            ),
            "mac-sck-start"
        )
        XCTAssertEqual(
            ScreenCaptureKitStreamer.startSmokeStatusPrefix(
                captureVideoOutput: false,
                requestedSystemAudio: true
            ),
            "mac-sck-audio-start"
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
                lastSubmittedAt + 166_666_660,
                lastSubmittedAt + 183_333_326,
                lastSubmittedAt + 199_999_992
            ]
        )
        XCTAssertTrue(targets.allSatisfy { $0 <= lastSubmittedAt + 200_000_000 })
    }

    func testCadenceSubmissionSkipsExpiredHighFpsProducerCatchUp() {
        let lastSubmittedAt: UInt64 = 1_000_000_000

        let oneTimerSlip = ScreenCaptureKitStreamer.cadenceSubmissionTargetUptimes(
            lastSubmittedAt: lastSubmittedAt,
            nowNanos: lastSubmittedAt + 35_000_000,
            configuredFPS: 60,
            maxCatchUpFrames: ScreenCaptureKitStreamer.cadenceCatchUpFrameLimit(forConfiguredFPS: 60)
        )

        XCTAssertEqual(
            oneTimerSlip,
            [
                lastSubmittedAt + 16_666_666,
                lastSubmittedAt + 33_333_332
            ]
        )

        let longStall = ScreenCaptureKitStreamer.cadenceSubmissionTargetUptimes(
            lastSubmittedAt: lastSubmittedAt,
            nowNanos: lastSubmittedAt + 200_000_000,
            configuredFPS: 60,
            maxCatchUpFrames: ScreenCaptureKitStreamer.cadenceCatchUpFrameLimit(forConfiguredFPS: 60)
        )

        XCTAssertEqual(
            longStall,
            [
                lastSubmittedAt + 183_333_326,
                lastSubmittedAt + 199_999_992
            ]
        )
    }

    func testHighFpsDisplayCadenceUsesBoundedTwoFrameProducerCatchUp() {
        XCTAssertEqual(
            ScreenCaptureKitStreamer.cadenceCatchUpFrameLimit(forConfiguredFPS: 60),
            2
        )
        XCTAssertEqual(
            ScreenCaptureKitStreamer.cadenceCatchUpFrameLimit(forConfiguredFPS: 120),
            2
        )
        XCTAssertEqual(
            ScreenCaptureKitStreamer.cadenceCatchUpFrameLimit(forConfiguredFPS: 30),
            1
        )
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

    func testLowLatencyRateControlStaysOnKnownProducingProfiles() throws {
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
        let hevcSpecification = try XCTUnwrap(
            ScreenCaptureKitStreamer.videoEncoderSpecification(
                codec: kCMVideoCodecType_HEVC,
                lowLatencyMode: true,
                requiresHardwareEncoder: true,
                preferredProfile: .hevcMain
            ) as NSDictionary?
        )
        XCTAssertNil(hevcSpecification[kVTVideoEncoderSpecification_EnableLowLatencyRateControl as String])
        XCTAssertEqual(
            hevcSpecification[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String] as? Bool,
            true
        )
    }

    func testLowLatencyHEVCHighFpsKeepsOneSecondGOP() {
        XCTAssertEqual(
            ScreenCaptureKitStreamer.videoToolboxKeyFrameInterval(
                configuredKeyInterval: 60,
                configuredFPS: 60,
                lowLatencyEnabled: true,
                codec: kCMVideoCodecType_HEVC
            ),
            60
        )
        XCTAssertEqual(
            ScreenCaptureKitStreamer.videoToolboxKeyFrameIntervalDuration(
                configuredKeyInterval: 60,
                configuredFPS: 60,
                lowLatencyEnabled: true,
                codec: kCMVideoCodecType_HEVC
            ),
            1.0,
            accuracy: 0.0001
        )
    }

    func testLowLatencyH264KeepsShortRecoveryGOP() {
        XCTAssertEqual(
            ScreenCaptureKitStreamer.videoToolboxKeyFrameInterval(
                configuredKeyInterval: 60,
                configuredFPS: 60,
                lowLatencyEnabled: true,
                codec: kCMVideoCodecType_H264
            ),
            30
        )
        XCTAssertEqual(
            ScreenCaptureKitStreamer.videoToolboxKeyFrameIntervalDuration(
                configuredKeyInterval: 60,
                configuredFPS: 60,
                lowLatencyEnabled: true,
                codec: kCMVideoCodecType_H264
            ),
            0.5,
            accuracy: 0.0001
        )
    }

    func testLowLatencyHEVC2K60CapsBitrateForTransportCadence() throws {
        let source = try screenCaptureKitStreamerSource()
        let limits = ScreenCaptureKitStreamer.videoToolboxDataRateLimits(
            codec: kCMVideoCodecType_HEVC,
            averageBitRate: 12_000_000,
            width: 2056,
            height: 1330,
            fps: 60,
            lowLatencyEnabled: true
        )

        XCTAssertTrue(source.contains("quality = min(quality, 0.30)"))
        XCTAssertTrue(source.contains("maximum = 12_000_000"))
        XCTAssertTrue(source.contains("averageBitRate=\\(averageBitRate)"))
        XCTAssertTrue(source.contains("dataRateLimitBytesPerSecond=\\(hardLimitBytesPerSecond)"))
        XCTAssertTrue(source.contains("dataRateBurstLimitBytes=\\(burstLimitBytes)"))
        XCTAssertTrue(source.contains("dataRateBurstWindowMs=\\(burstWindowMs)"))
        XCTAssertTrue(source.contains("lowLatencyHEVC2K60BurstHeadroomMultiplier = 8.0"))
        XCTAssertTrue(source.contains("lowLatencyHEVC2K60SingleChunkEncodedPayloadBudgetBytes"))
        XCTAssertTrue(source.contains("dataRateLimitsStatus=\\(dataRateLimitsStatus)"))
        XCTAssertTrue(source.contains("dataRateLimitsApplied=\\(dataRateLimitsApplied ? 1 : 0)"))
        XCTAssertTrue(source.contains("strict-video-rate-limit-unapplied"))
        XCTAssertTrue(source.contains("Double(averageBitRate) / 8.0"))
        XCTAssertTrue(source.contains("queueDepth=\\(selectedQueueDepth)"))
        XCTAssertEqual(limits.hardLimitBytesPerSecond, 1_500_000)
        XCTAssertEqual(
            limits.burstLimitBytes,
            Optional(ScreenCaptureKitStreamer.lowLatencyHEVC2K60BurstLimitBytes(hardLimitBytesPerSecond: 1_500_000))
        )
        XCTAssertLessThan(
            limits.burstLimitBytes ?? Int.max,
            ScreenCaptureKitStreamer.lowLatencyHEVC2K60SingleChunkEncodedPayloadBudgetBytes
        )
        XCTAssertEqual(limits.burstWindowSeconds ?? 0, 1.0 / 60.0, accuracy: 0.0001)
        XCTAssertEqual(limits.limits.count, 4)
    }

    func testFirstFrameWatchdogTimeoutIsBoundedFor2K60() {
        let timeout = ScreenCaptureKitStreamer.firstEncodedFrameTimeoutSeconds(
            targetFPS: 60,
            width: 2056,
            height: 1330
        )

        XCTAssertGreaterThanOrEqual(timeout, 3.0)
        XCTAssertLessThanOrEqual(timeout, 6.0)
    }

    func testCadenceEncoderSerializesCompressionSessionInvalidation() throws {
        let source = try screenCaptureKitStreamerSource()

        XCTAssertTrue(source.contains("compressionSessionLock"))
        XCTAssertTrue(source.contains("takeCompressionSessionForInvalidation()"))
        XCTAssertTrue(source.contains("drainVideoCadenceQueueIfNeeded()"))
        XCTAssertTrue(source.contains("videoCadenceQueue.setSpecific"))
    }

    private func screenCaptureKitStreamerSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcePaths = [
            "Sources/SkyBridgeCore/RemoteControl/ScreenCaptureKitStreamer.swift",
            "Sources/SkyBridgeCore/RemoteControl/ScreenCaptureKitStreamer+CaptureTypes.swift",
            "Sources/SkyBridgeCore/RemoteControl/ScreenCaptureKitStreamer+VideoPolicy.swift",
            "Sources/SkyBridgeCore/RemoteControl/ScreenCaptureKitStreamer+JPEGEncoding.swift",
            "Sources/SkyBridgeCore/RemoteControl/ScreenCaptureTelemetrySnapshot.swift"
        ]
        return try sourcePaths.map { path in
            try String(
                contentsOf: root.appendingPathComponent(path),
                encoding: .utf8
            )
        }.joined(separator: "\n")
    }
}
#endif
