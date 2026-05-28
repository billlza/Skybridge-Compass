import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import ScreenCaptureKit
import VideoToolbox

extension ScreenCaptureKitStreamer {
    private static let lowLatencyHEVC2K60BurstWindowSeconds = 1.0 / 60.0
    private static let lowLatencyHEVC2K60BurstHeadroomMultiplier = 8.0

    static func videoEncoderSpecification(
        codec: CMVideoCodecType,
        lowLatencyMode: Bool,
        requiresHardwareEncoder: Bool,
        preferredProfile: EncodingProfile
    ) -> CFDictionary? {
        var specification: [String: Any] = [:]
        if requiresHardwareEncoder {
            specification[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String] = kCFBooleanTrue
        }
        if shouldEnableLowLatencyRateControl(
            codec: codec,
            lowLatencyMode: lowLatencyMode,
            preferredProfile: preferredProfile
        ) {
            specification[kVTVideoEncoderSpecification_EnableLowLatencyRateControl as String] = kCFBooleanTrue
        }
        return specification.isEmpty ? nil : specification as CFDictionary
    }

    static func shouldEnableLowLatencyRateControl(
        codec: CMVideoCodecType,
        lowLatencyMode: Bool,
        preferredProfile: EncodingProfile
    ) -> Bool {
        guard lowLatencyMode else {
            return false
        }
        if codec == kCMVideoCodecType_HEVC {
            return false
        }
        guard codec == kCMVideoCodecType_H264 else {
            return false
        }
        switch preferredProfile {
        case .auto, .h264High:
            return true
        case .h264Baseline, .h264Main, .hevcMain:
            return false
        }
    }

    static func videoToolboxKeyFrameInterval(
        configuredKeyInterval: Int,
        configuredFPS: Int,
        lowLatencyEnabled: Bool,
        codec: CMVideoCodecType
    ) -> Int {
        let requestedInterval = max(1, configuredKeyInterval)
        guard lowLatencyEnabled else { return requestedInterval }

        if codec == kCMVideoCodecType_HEVC, configuredFPS >= 55 {
            return max(10, min(requestedInterval, max(30, configuredFPS)))
        }
        return max(10, min(requestedInterval, 30))
    }

    static func videoToolboxKeyFrameIntervalDuration(
        configuredKeyInterval: Int,
        configuredFPS: Int,
        lowLatencyEnabled: Bool,
        codec: CMVideoCodecType
    ) -> Double {
        let selectedInterval = videoToolboxKeyFrameInterval(
            configuredKeyInterval: configuredKeyInterval,
            configuredFPS: configuredFPS,
            lowLatencyEnabled: lowLatencyEnabled,
            codec: codec
        )
        let frameRate = max(1, configuredFPS)
        let intervalDuration = Double(selectedInterval) / Double(frameRate)
        return lowLatencyEnabled ? max(0.5, intervalDuration) : max(1.0, intervalDuration)
    }

    static func videoToolboxDataRateLimits(
        codec: CMVideoCodecType,
        averageBitRate: Int,
        width: Int,
        height: Int,
        fps: Int,
        lowLatencyEnabled: Bool
    ) -> (
        limits: [NSNumber],
        hardLimitBytesPerSecond: Int,
        burstLimitBytes: Int?,
        burstWindowSeconds: Double?
    ) {
        let hardLimitBytesPerSecond = max(Int(Double(averageBitRate) / 8.0), 512_000)
        var limits = [NSNumber(value: hardLimitBytesPerSecond), NSNumber(value: 1)]
        guard codec == kCMVideoCodecType_HEVC,
              lowLatencyEnabled,
              fps >= 55,
              width * height >= 2_500_000 else {
            return (limits, hardLimitBytesPerSecond, nil, nil)
        }

        let burstLimitBytes = Self.lowLatencyHEVC2K60BurstLimitBytes(
            hardLimitBytesPerSecond: hardLimitBytesPerSecond
        )
        limits.append(NSNumber(value: burstLimitBytes))
        limits.append(NSNumber(value: Self.lowLatencyHEVC2K60BurstWindowSeconds))
        return (
            limits,
            hardLimitBytesPerSecond,
            burstLimitBytes,
            Self.lowLatencyHEVC2K60BurstWindowSeconds
        )
    }

    static func lowLatencyHEVC2K60BurstLimitBytes(hardLimitBytesPerSecond: Int) -> Int {
        let rateWindowBytes = Int(
            (Double(max(1, hardLimitBytesPerSecond)) * lowLatencyHEVC2K60BurstWindowSeconds)
                .rounded(.up)
        )
        let burstHeadroomBytes = Int(
            (Double(rateWindowBytes) * lowLatencyHEVC2K60BurstHeadroomMultiplier)
                .rounded(.up)
        )
        return min(
            max(burstHeadroomBytes, 128 * 1024),
            Self.lowLatencyHEVC2K60SingleChunkEncodedPayloadBudgetBytes
        )
    }

    static func videoToolboxDataRateLimitsReadback(from value: CFTypeRef?) -> [NSNumber] {
        if let numbers = value as? [NSNumber] {
            return numbers
        }
        if let values = value as? [Any] {
            return values.compactMap { $0 as? NSNumber }
        }
        return []
    }

    static func videoToolboxMaxFrameDelayCount(
        codec: CMVideoCodecType,
        width: Int,
        height: Int,
        fps: Int,
        lowLatencyEnabled: Bool
    ) -> Int {
        let pixelCount = max(width, 1) * max(height, 1)
        if lowLatencyEnabled,
           codec == kCMVideoCodecType_HEVC,
           fps >= 55,
           pixelCount >= 2_000_000 {
            return 3
        }
        return 1
    }

    static func videoToolboxMaximumRealTimeFrameRate(
        codec: CMVideoCodecType,
        width: Int,
        height: Int,
        fps: Int,
        lowLatencyEnabled: Bool
    ) -> Int {
        let configuredFPS = max(1, fps)
        let pixelCount = max(width, 1) * max(height, 1)
        guard lowLatencyEnabled,
              codec == kCMVideoCodecType_HEVC,
              configuredFPS >= 55,
              pixelCount >= 2_000_000 else {
            return configuredFPS
        }
        let boundedCatchUpRate = configuredFPS * cadenceCatchUpFrameLimit(forConfiguredFPS: configuredFPS)
        return min(max(configuredFPS, boundedCatchUpRate), 120)
    }

    static func encodePresentationTimeStamp(from sampleBuffer: CMSampleBuffer) -> CMTime {
        CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    }

    static func encodeFrameDuration(forConfiguredFPS fps: Int) -> CMTime {
        CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
    }

    static func screenCaptureMinimumFrameInterval(forConfiguredFPS fps: Int) -> CMTime {
        guard fps >= 55 else {
            return encodeFrameDuration(forConfiguredFPS: fps)
        }
        return CMTime(value: 1, timescale: CMTimeScale(min(120, max(fps, fps * 2))))
    }

    static func captureQueueDepth(
        lowLatencyEnabled: Bool,
        targetFPS: Int,
        width: Int,
        height: Int
    ) -> Int {
        let pixelCount = max(width, 1) * max(height, 1)
        let highFrameRate = targetFPS >= 55
        let highResolution = pixelCount >= 2_000_000
        let depth: Int
        if highFrameRate && highResolution {
            depth = 8
        } else if highFrameRate {
            depth = lowLatencyEnabled ? 4 : 5
        } else {
            depth = lowLatencyEnabled ? 3 : 5
        }
        return min(8, max(1, depth))
    }

    static func shouldRunDisplayCadenceEncoder(
        jpegMode: Bool,
        hasEncodedFrameSink: Bool,
        targetFPS: Int
    ) -> Bool {
        !jpegMode && hasEncodedFrameSink && targetFPS >= 55
    }

    static func shouldProcessFrame(
        with status: SCFrameStatus?,
        includeIdleFrames: Bool = false
    ) -> Bool {
        guard let status else { return true }
        switch status {
        case .idle:
            return includeIdleFrames
        case .blank, .suspended, .stopped:
            return false
        case .started, .complete:
            return true
        @unknown default:
            return false
        }
    }

    static func shouldReuseLatestFrameForCadence(with status: SCFrameStatus?) -> Bool {
        status == .idle
    }

    static func shouldRegisterScreenOutput(
        captureVideoOutput: Bool,
        requestedSystemAudio: Bool
    ) -> Bool {
        // ScreenCaptureKit still drives a display stream for audio capture. Register a
        // screen output for audio-only streams so SCK does not drop internal video queue frames.
        captureVideoOutput || requestedSystemAudio
    }

    static func startSmokeStatusPrefix(captureVideoOutput: Bool, requestedSystemAudio: Bool) -> String {
        captureVideoOutput ? "mac-sck-start" : (requestedSystemAudio ? "mac-sck-audio-start" : "mac-sck-idle-start")
    }

    static func presentationTimeFromUptimeNanoseconds(_ nanoseconds: UInt64) -> CMTime {
        let clamped = min(nanoseconds, UInt64(Int64.max))
        return CMTime(value: CMTimeValue(clamped), timescale: 1_000_000_000)
    }

    static func firstEncodedFrameTimeoutSeconds(targetFPS: Int, width: Int, height: Int) -> TimeInterval {
        let megapixels = Double(max(1, width * height)) / 1_000_000.0
        let frameBudget = 1.0 / Double(max(1, targetFPS))
        return max(3.0, min(6.0, (frameBudget * 90.0) + (megapixels * 0.25)))
    }

    static func cadenceTimerIntervalNanoseconds(forConfiguredFPS fps: Int) -> UInt64 {
        frameIntervalNanoseconds(forConfiguredFPS: fps)
    }

    static func cadenceCatchUpFrameLimit(forConfiguredFPS fps: Int) -> Int {
        fps >= 55 ? 2 : 1
    }

    static func cadenceSubmissionTargetUptimes(
        lastSubmittedAt: UInt64,
        nowNanos: UInt64,
        configuredFPS fps: Int,
        maxCatchUpFrames: Int
    ) -> [UInt64] {
        guard lastSubmittedAt > 0 else { return [nowNanos] }
        guard nowNanos >= lastSubmittedAt else { return [] }
        let frameIntervalNanos = frameIntervalNanoseconds(forConfiguredFPS: fps)
        let elapsed = nowNanos - lastSubmittedAt
        guard elapsed >= frameIntervalNanos else { return [] }
        let dueFrames = max(1, Int(elapsed / frameIntervalNanos))
        let catchUpCount = min(max(1, maxCatchUpFrames), dueFrames)
        let firstDueFrameIndex = dueFrames - catchUpCount + 1
        return (firstDueFrameIndex...dueFrames).map { frameIndex in
            let target = lastSubmittedAt + (UInt64(frameIndex) * frameIntervalNanos)
            return min(target, nowNanos)
        }
    }

    private static func frameIntervalNanoseconds(forConfiguredFPS fps: Int) -> UInt64 {
        max(1, 1_000_000_000 / UInt64(max(1, fps)))
    }
}
