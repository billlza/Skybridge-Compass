#if os(macOS)
import Foundation
import SkyBridgeProtocolCore

/// Adapter used by the actual captured-PCM session. It neither converts samples
/// nor substitutes a different output endpoint when strict preparation fails.
final class CoreAudioCaptureOutput: AudioCaptureOutput {
    private let native: CoreAudioExactPcmOutput
    init(ownerID: UUID, authorization: @escaping @Sendable () -> Bool) throws {
        native = try CoreAudioExactPcmOutput(ownerID: ownerID, isAuthorizationCurrent: authorization)
    }
    func prepare(endpointUID: String, format: AudioStreamingPCMFormat) throws -> CoreAudioExactPcmPreparedOutput {
        try native.prepare(endpointUID: endpointUID, format: format)
    }
    func enqueue(_ bytes: Data, ownerID: UUID) throws { _ = try native.enqueue(bytes, ownerID: ownerID) }
    func start(ownerID: UUID) throws { try native.start(ownerID: ownerID) }
    func finishInput(ownerID: UUID, expectedSourceFrames: UInt64) throws {
        try native.finishInput(ownerID: ownerID, expectedSourceFrames: expectedSourceFrames)
    }
    func observe() throws -> AudioCaptureOutputObservation {
        let value = native.snapshot()
        let state: AudioCaptureOutputObservation.State
        if value.failure != nil || !value.cleanupFailures.isEmpty || !value.skippedRestorations.isEmpty || value.drainStatus == .failed {
            state = .failed
        } else if value.drainStatus == .completed || value.drainStatus == .emptyCompleted {
            guard value.state == .closed, value.finalCountersVerified,
                  value.expectedSourceFrames == value.acceptedFrames,
                  value.submittedFrames == value.acceptedFrames, value.queuedFrames == 0 else {
                throw AudioCaptureReceiveError.invalidProgress
            }
            state = .completed
        } else {
            switch value.state {
            case .prepared: state = .prepared
            case .running: state = .running
            case .draining: state = .draining
            default: state = .failed
            }
        }
        return .init(state: state, acceptedSourceFrames: value.acceptedFrames,
                     submittedSourceFrames: value.submittedFrames, trailingPaddingFrames: value.trailingPaddingFrames)
    }
    func close(ownerID: UUID) -> AudioOutputCleanupOutcome {
        var closeError: Error?
        do { try native.close(ownerID: ownerID) }
        catch { closeError = error }
        // close can keep throwing a historical diagnostic after all resources have been released.
        // Only the native lifecycle state establishes whether a live cleanup obligation remains.
        return Self.cleanupOutcome(snapshot: native.snapshot(), closeError: closeError)
    }

    static func cleanupOutcome(snapshot: CoreAudioExactPcmOutputSnapshot, closeError: Error?) -> AudioOutputCleanupOutcome {
        var diagnostics = snapshot.cleanupFailures
        if let closeError {
            let description = "output_close: " + String(describing: closeError)
            if !diagnostics.contains(description) { diagnostics.append(description) }
        }
        return .init(state: snapshot.state == .closed ? .released : .pending,
                     diagnostics: diagnostics, preservedExternalChanges: snapshot.skippedRestorations)
    }
}
#endif
