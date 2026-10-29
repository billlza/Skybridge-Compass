#if os(macOS)
import Foundation
import SkyBridgeProtocolCore

struct AudioOpusPlaybackFailure: Error {
    let primary: any Error
    let cleanup: AudioOutputCleanupOutcome?
    let cleanupError: (any Error)?
}
enum AudioOpusPlaybackError: Error { case output(CoreAudioOpusOutputSnapshot) }

/// Serial playback consumer after exact Bluetooth/account/one-stream admission. This connects
/// the existing bounded decoder to the real compatible output; it does not grant admission or
/// advertise capabilities. The caller owns transport reads, deadlines and actual control writes.
/// Returned controls are generated only once; a failed write must end the session, never replay
/// it as successful delivery. Local completion is not a peer receipt or a physical DAC proof.
actor AudioOpusPlayback {
    private let flow: AudioOpusReceiveFlow
    private let output: CoreAudioOpusOutput
    private let endpointUID: String
    private let requireAuthorization: @Sendable () throws -> Void
    private var prepared = false, closed = false, completionGenerated = false
    private var failed = false
    private var lastCredit: UInt64 = 0

    init(offer: AudioStreamingMessage, endpointUID: String, output: CoreAudioOpusOutput,
         requireAuthorization: @escaping @Sendable () throws -> Void) throws {
        flow = try AudioOpusReceiveFlow(offer: offer)
        guard output.buffering == flow.buffering else { throw AudioOpusReceiveError.invalidConfiguration }
        self.output = output; self.endpointUID = endpointUID; self.requireAuthorization = requireAuthorization
    }

    func prepare() throws -> [AudioStreamingMessage] {
        try perform {
            guard !prepared else { throw AudioOpusReceiveError.invalidState }
            try output.prepare(endpointUID: endpointUID, channels: flow.format.channels)
            try requireAuthorization(); prepared = true
            return [message(.accept(receiveWindowBytes: flow.windowBytes)), message(.opusOutputReady)]
        }
    }

    func receive(_ incoming: AudioStreamingMessage) throws -> [AudioStreamingMessage] {
        try perform {
            guard prepared, !completionGenerated else { throw AudioOpusReceiveError.invalidState }
            var controls: [AudioStreamingMessage] = []
            switch incoming.body {
            case .opusConfiguration:
                try flow.configure(incoming)
            case .opusData:
                try flow.receive(incoming) { chunk in
                    try requireAuthorization()
                    try output.enqueue(chunk.pcm16LE, firstSourceFrame: chunk.firstPCMFrame, ownerID: output.ownerID)
                }
                try startIfReady(sealed: false)
            case .opusEnd:
                let frames = try flow.verifyEnd(incoming) { chunk in
                    try requireAuthorization()
                    try output.enqueue(chunk.pcm16LE, firstSourceFrame: chunk.firstPCMFrame, ownerID: output.ownerID)
                }
                try requireAuthorization()
                try output.finishInput(ownerID: output.ownerID, expectedSourceFrames: frames)
                try startIfReady(sealed: true)
                guard let digest = flow.verifiedDigest else { throw AudioOpusReceiveError.invalidState }
                controls.append(message(.contentVerified(totalBytes: flow.receivedEncodedBytes, sha256: digest)))
            default: throw AudioOpusReceiveError.invalidState
            }
            controls += try progress()
            return controls
        }
    }

    func poll() throws -> [AudioStreamingMessage] {
        try perform {
            guard prepared else { throw AudioOpusReceiveError.invalidState }
            return try progress()
        }
    }

    func close() throws -> AudioOutputCleanupOutcome {
        closed = true; flow.cancel()
        return try output.close(ownerID: output.ownerID)
    }

    private func startIfReady(sealed: Bool) throws {
        let state = try output.checkedSnapshot(ownerID: output.ownerID)
        if state.state == .prepared, sealed || state.acceptedSourceFrames >= output.buffering.minimumPrefillFrames {
            try requireAuthorization(); try output.start(ownerID: output.ownerID)
        }
    }
    private func progress() throws -> [AudioStreamingMessage] {
        if completionGenerated { return [] }
        let state = try output.checkedSnapshot(ownerID: output.ownerID)
        try requireAuthorization()
        guard state.failure == nil, state.state == .prepared || state.state == .running || state.state == .draining || state.state == .completed else {
            throw AudioOpusPlaybackError.output(state)
        }
        guard state.acceptedSourceFrames == flow.enqueuedSourceFrames else { throw AudioOpusReceiveError.invalidProgress }
        if flow.state == .awaitingConfiguration { return [] }
        var controls: [AudioStreamingMessage] = []
        _ = try flow.retire(sourceFrames: state.playedSourceFrames)
        if state.state == .completed {
            _ = try flow.didComplete(sourceFrames: state.playedSourceFrames)
            completionGenerated = true
        }
        if flow.retiredEncodedBytes > lastCredit {
            lastCredit = flow.retiredEncodedBytes
            controls.append(message(.credit(retiredBytes: lastCredit)))
        }
        if completionGenerated {
            // Every submitted buffer contains source PCM only. No application padding is queued;
            // this says nothing about system resampling, device latency or post-stream silence.
            controls.append(message(.playbackComplete(sourceFrames: state.playedSourceFrames, trailingPaddingFrames: 0)))
        }
        return controls
    }
    private func message(_ body: AudioStreamingMessage.Body) -> AudioStreamingMessage { .init(streamID: flow.streamID, body: body) }
    private func perform<T>(_ action: () throws -> T) throws -> T {
        guard !closed, !failed else { throw AudioOpusReceiveError.invalidState }
        do { try requireAuthorization(); return try action() }
        catch {
            failed = true; flow.cancel()
            let cleanup: AudioOutputCleanupOutcome
            do { cleanup = try output.close(ownerID: output.ownerID) }
            catch let closeError { throw AudioOpusPlaybackFailure(primary: error, cleanup: nil, cleanupError: closeError) }
            throw AudioOpusPlaybackFailure(primary: error, cleanup: cleanup, cleanupError: nil)
        }
    }
}
#endif
