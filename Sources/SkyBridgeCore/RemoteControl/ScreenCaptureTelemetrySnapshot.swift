import Foundation

struct ScreenCaptureTelemetrySnapshot: Sendable, Equatable {
    let interval: TimeInterval
    let capturedSamples: Int
    let meaningfulSamples: Int
    let encodedFrames: Int
    let encodedBytes: Int
    let targetFPS: Int
    let codec: String
    let width: Int
    let height: Int
    let visibleWidth: Int
    let visibleHeight: Int
    let capturesAudio: Bool
    let encodeLatencyP50Ms: Double?
    let encodeLatencyP95Ms: Double?
    let encodeLatencyMaxMs: Double?
    let actualEncodeLatencyP50Ms: Double?
    let actualEncodeLatencyP95Ms: Double?
    let actualEncodeLatencyMaxMs: Double?
    let encodeSubmissionDelayMaxMs: Double
    let encodeSubmissionBacklogMax: Int
    let encodeFailures: Int
    let cadenceTimerFires: Int
    let cadenceSubmittedFrames: Int
    let cadenceCatchUpFrames: Int
    let cadenceBatchMax: Int
    let sourceFrameRepeatMax: Int
    let sourceFrameAgeMaxMs: Double
    let encodedFrameBytesMax: Int
    let encodedSyncFrameBytesMax: Int
    let oversizedEncodedFrames: Int
    let oversizedSyncFrames: Int

    var captureFPS: Double { Double(capturedSamples) / max(interval, 0.001) }
    var meaningfulFPS: Double { Double(meaningfulSamples) / max(interval, 0.001) }
    var encodedFPS: Double { Double(encodedFrames) / max(interval, 0.001) }
}
