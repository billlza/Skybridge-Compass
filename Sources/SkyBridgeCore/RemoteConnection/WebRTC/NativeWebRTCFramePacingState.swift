import CoreVideo
import Foundation

@available(macOS 14.0, iOS 17.0, *)
final class NativeWebRTCFramePacingState: @unchecked Sendable {
    struct RawFramePlan: Sendable {
        let timestampsNs: [Int64]
        let rawDeltaNs: Int64
        let submittedFrames: Int
        let duplicateFrames: UInt64
        let shouldLogBurst: Bool
    }

    struct TimerFrame: @unchecked Sendable {
        let pixelBuffer: CVPixelBuffer
        let rawTimestampNs: Int64
        let timestampNs: Int64
        let timerPacedFrames: UInt64
        let lastRawAgeMs: Int
        let shouldLog: Bool
    }

    private let lock = NSLock()
    private let frameIntervalNs: Int64
    private let maxFramesPerRawFrame: Int
    private let stallGraceSeconds: TimeInterval

    private var lastRawTimestampNs: Int64?
    private var lastSubmittedTimestampNs: Int64?
    private var accumulatorNs: Int64 = 0
    private var duplicateFrames: UInt64 = 0
    private var timerPacedFrames: UInt64 = 0
    private var timerPacedFramesSinceLastRaw: UInt64 = 0
    private var lastBurstDiagnosticAt = Date.distantPast
    private var lastTimerDiagnosticAt = Date.distantPast
    private var latestPixelBuffer: CVPixelBuffer?
    private var latestRawTimestampNs: Int64?
    private var latestRawArrivedAt = Date.distantPast

    init(frameIntervalNs: Int64, maxFramesPerRawFrame: Int) {
        self.frameIntervalNs = max(1, frameIntervalNs)
        self.maxFramesPerRawFrame = max(1, maxFramesPerRawFrame)
        self.stallGraceSeconds = max(
            0.025,
            (Double(max(1, frameIntervalNs)) / 1_000_000_000.0) * 1.5
        )
    }

    func planForRawFrame(
        pixelBuffer: CVPixelBuffer,
        rawTimestampNs: Int64,
        now: Date = Date()
    ) -> RawFramePlan {
        lock.lock()
        defer { lock.unlock() }

        latestPixelBuffer = pixelBuffer
        latestRawTimestampNs = rawTimestampNs
        latestRawArrivedAt = now

        guard let previousRawTimestampNs = lastRawTimestampNs,
              let previousSubmittedTimestampNs = lastSubmittedTimestampNs else {
            lastRawTimestampNs = rawTimestampNs
            lastSubmittedTimestampNs = rawTimestampNs
            accumulatorNs = 0
            timerPacedFramesSinceLastRaw = 0
            return RawFramePlan(
                timestampsNs: [rawTimestampNs],
                rawDeltaNs: 0,
                submittedFrames: 1,
                duplicateFrames: duplicateFrames,
                shouldLogBurst: false
            )
        }

        let rawDeltaNs: Int64
        if timerPacedFramesSinceLastRaw > 0 {
            rawDeltaNs = frameIntervalNs
            timerPacedFramesSinceLastRaw = 0
        } else {
            rawDeltaNs = rawTimestampNs > previousRawTimestampNs
                ? rawTimestampNs - previousRawTimestampNs
                : frameIntervalNs
        }
        let boundedRawDeltaNs = min(
            max(rawDeltaNs, frameIntervalNs / 2),
            frameIntervalNs * Int64(maxFramesPerRawFrame)
        )
        accumulatorNs += boundedRawDeltaNs

        var framesToSubmit = 0
        while accumulatorNs >= frameIntervalNs,
              framesToSubmit < maxFramesPerRawFrame {
            framesToSubmit += 1
            accumulatorNs -= frameIntervalNs
        }
        if framesToSubmit == maxFramesPerRawFrame,
           accumulatorNs >= frameIntervalNs {
            accumulatorNs = 0
        }

        lastRawTimestampNs = rawTimestampNs
        guard framesToSubmit > 0 else {
            return RawFramePlan(
                timestampsNs: [],
                rawDeltaNs: rawDeltaNs,
                submittedFrames: 0,
                duplicateFrames: duplicateFrames,
                shouldLogBurst: false
            )
        }

        var nextSubmittedTimestampNs = previousSubmittedTimestampNs
        var timestampsNs: [Int64] = []
        timestampsNs.reserveCapacity(framesToSubmit)
        for frameIndex in 0..<framesToSubmit {
            nextSubmittedTimestampNs += frameIntervalNs
            if frameIndex < framesToSubmit - 1 {
                duplicateFrames &+= 1
            }
            timestampsNs.append(nextSubmittedTimestampNs)
        }
        lastSubmittedTimestampNs = nextSubmittedTimestampNs

        let shouldLogBurst = framesToSubmit > 1
            && now.timeIntervalSince(lastBurstDiagnosticAt) >= 2.0
        if shouldLogBurst {
            lastBurstDiagnosticAt = now
        }
        return RawFramePlan(
            timestampsNs: timestampsNs,
            rawDeltaNs: rawDeltaNs,
            submittedFrames: framesToSubmit,
            duplicateFrames: duplicateFrames,
            shouldLogBurst: shouldLogBurst
        )
    }

    func nextTimerFrame(now: Date = Date()) -> TimerFrame? {
        lock.lock()
        defer { lock.unlock() }

        guard let pixelBuffer = latestPixelBuffer,
              let rawTimestampNs = latestRawTimestampNs,
              let previousSubmittedTimestampNs = lastSubmittedTimestampNs,
              now.timeIntervalSince(latestRawArrivedAt) >= stallGraceSeconds else {
            return nil
        }

        let nextSubmittedTimestampNs = previousSubmittedTimestampNs + frameIntervalNs
        lastSubmittedTimestampNs = nextSubmittedTimestampNs
        timerPacedFrames &+= 1
        timerPacedFramesSinceLastRaw &+= 1
        let shouldLog = now.timeIntervalSince(lastTimerDiagnosticAt) >= 2.0
        if shouldLog {
            lastTimerDiagnosticAt = now
        }
        return TimerFrame(
            pixelBuffer: pixelBuffer,
            rawTimestampNs: rawTimestampNs,
            timestampNs: nextSubmittedTimestampNs,
            timerPacedFrames: timerPacedFrames,
            lastRawAgeMs: max(0, Int((now.timeIntervalSince(latestRawArrivedAt) * 1000).rounded())),
            shouldLog: shouldLog
        )
    }
}
