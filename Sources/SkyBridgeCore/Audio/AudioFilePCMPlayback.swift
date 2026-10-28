#if os(macOS)
import Foundation
import SkyBridgeProtocolCore
import SkyBridgeAudioFile

struct AudioFilePCMPlaybackReceipt: Sendable, Equatable {
    let sourceFrames: UInt64
    let trailingPaddingFrames: UInt32
}

enum AudioFilePCMPlaybackError: Error, Sendable, Equatable {
    enum Wait: Sendable, Equatable { case enqueue, start, finishInput, outputProgress, drain }
    case invalidDescriptor, invalidPreparedOutput, invalidProgress, outputLost
    case nonFiniteSample(byteOffset: UInt64)
    case timedOut(Wait)
}

/// One sequential producer over an already verified file and prepared native owner. Metadata must
/// have been inspected through this same reader. This pump neither prepares nor closes resources;
/// its outer session owns cancellation cleanup, including any queued prefix after a later failure.
/// WAVE supplies its original PCM; validated FLAC/ALAC supply exact integer PCM through their decoder.
/// The shared pump performs no resampling, gain, numerical normalization, or output fallback.
enum AudioFilePCMPlayback {
    static let maximumReadBytes = 65_536

    struct Timing: Sendable {
        let now: @Sendable () -> ContinuousClock.Instant
        let pause: @Sendable (Duration) async throws -> Void
        static func live() -> Self {
            .init(now: { .now }, pause: { try await Task.sleep(for: $0) })
        }
    }

    static func play(reader: PreparedOutboundFileReadSession, metadata: AudioWavePCMMetadata,
        output: any AudioCaptureOutput, prepared: CoreAudioExactPcmPreparedOutput, ownerID: UUID,
        requireAuthorization: @escaping @Sendable () throws -> Void,
        onOutputProgress: (@Sendable (UInt64) -> Void)? = nil
    ) async throws -> AudioFilePCMPlaybackReceipt {
        try await play(reader: reader, metadata: metadata, output: output, prepared: prepared,
                       ownerID: ownerID, requireAuthorization: requireAuthorization, timing: .live(),
                       onOutputProgress: onOutputProgress)
    }

    // The substitute clock only controls failure deadlines/polling in tests. Native observations,
    // never elapsed time, determine successful completion. There is no additional worker runtime.
    static func play(reader: PreparedOutboundFileReadSession, metadata: AudioWavePCMMetadata,
        output: any AudioCaptureOutput, prepared: CoreAudioExactPcmPreparedOutput, ownerID: UUID,
        requireAuthorization: @escaping @Sendable () throws -> Void, timing: Timing,
        onOutputProgress: (@Sendable (UInt64) -> Void)? = nil
    ) async throws -> AudioFilePCMPlaybackReceipt {
        try check(requireAuthorization)
        let frameBytes = UInt64(metadata.format.bytesPerFrame)
        guard reader.metadata.fileSize >= 0, frameBytes > 0,
              metadata.pcmByteOffset <= UInt64(reader.metadata.fileSize),
              metadata.pcmByteCount <= UInt64(reader.metadata.fileSize) - metadata.pcmByteOffset,
              metadata.pcmByteCount % frameBytes == 0,
              ownerID != UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)) else {
            throw AudioFilePCMPlaybackError.invalidDescriptor
        }
        return try await pump(format: metadata.format, totalFrames: metadata.frameCount,
            readFrames: { frameOffset, frames in
                let offset = metadata.pcmByteOffset + frameOffset * frameBytes
                let bytes = try await reader.read(offset: offset, length: frames * Int(frameBytes))
                try requireFiniteSamples(bytes, encoding: metadata.format.encoding, byteOffset: offset)
                return bytes
            }, verifyEnd: {}, output: output, prepared: prepared, ownerID: ownerID,
            requireAuthorization: requireAuthorization, timing: timing, onOutputProgress: onOutputProgress)
    }

    static func play(file: AudioValidatedFlacFile,
        output: any AudioCaptureOutput, prepared: CoreAudioExactPcmPreparedOutput, ownerID: UUID,
        requireAuthorization: @escaping @Sendable () throws -> Void, timing: Timing = .live(),
        onOutputProgress: (@Sendable (UInt64) -> Void)? = nil
    ) async throws -> AudioFilePCMPlaybackReceipt {
        try check(requireAuthorization)
        let source = try AudioFlacPCMReadSession(file: file)
        return try await playValidated(format: file.metadata.decodedFormat, frames: file.receipt.sourceFrames,
            source: source, output: output, prepared: prepared, ownerID: ownerID,
            requireAuthorization: requireAuthorization, timing: timing, onOutputProgress: onOutputProgress)
    }

    static func play(file: AudioValidatedAlacFile,
        output: any AudioCaptureOutput, prepared: CoreAudioExactPcmPreparedOutput, ownerID: UUID,
        requireAuthorization: @escaping @Sendable () throws -> Void, timing: Timing = .live(),
        onOutputProgress: (@Sendable (UInt64) -> Void)? = nil
    ) async throws -> AudioFilePCMPlaybackReceipt {
        try check(requireAuthorization)
        let source = try AudioAlacPCMReadSession(file: file)
        return try await playValidated(format: file.metadata.decodedFormat, frames: file.receipt.sourceFrames,
            source: source, output: output, prepared: prepared, ownerID: ownerID,
            requireAuthorization: requireAuthorization, timing: timing, onOutputProgress: onOutputProgress)
    }

    private static func playValidated(format: AudioStreamingPCMFormat, frames: UInt64,
        source: SkyBridgeAudioFile.AudioValidatedPCMReadSession,
        output: any AudioCaptureOutput, prepared: CoreAudioExactPcmPreparedOutput, ownerID: UUID,
        requireAuthorization: @escaping @Sendable () throws -> Void, timing: Timing,
        onOutputProgress: (@Sendable (UInt64) -> Void)?
    ) async throws -> AudioFilePCMPlaybackReceipt {
        do {
            let result = try await pump(format: format, totalFrames: frames,
                readFrames: { offset, frames in
                    try await source.read(frameOffset: offset, frames: frames, requireAuthorization: requireAuthorization)
                }, verifyEnd: { try await source.finish(requireAuthorization: requireAuthorization) },
                output: output, prepared: prepared, ownerID: ownerID,
                requireAuthorization: requireAuthorization, timing: timing, onOutputProgress: onOutputProgress)
            await source.close()
            return result
        } catch {
            await source.close()
            throw error
        }
    }

    private static func pump(format: AudioStreamingPCMFormat, totalFrames: UInt64,
        readFrames readFramesOperation: @Sendable (UInt64, Int) async throws -> Data,
        verifyEnd: @Sendable () async throws -> Void,
        output: any AudioCaptureOutput, prepared: CoreAudioExactPcmPreparedOutput, ownerID: UUID,
        requireAuthorization: @escaping @Sendable () throws -> Void, timing: Timing,
        onOutputProgress: (@Sendable (UInt64) -> Void)?
    ) async throws -> AudioFilePCMPlaybackReceipt {
        try check(requireAuthorization)
        let frameBytes = UInt64(format.bytesPerFrame)
        guard frameBytes > 0, ownerID != UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)) else {
            throw AudioFilePCMPlaybackError.invalidDescriptor
        }
        guard prepared.format == format, !prepared.endpointUID.isEmpty,
              prepared.receiveCapacityBytes > 0, prepared.receiveCapacityBytes <= 1_048_576,
              UInt64(prepared.receiveCapacityBytes) % frameBytes == 0,
              prepared.minimumPrefillFrames > 0,
              UInt64(prepared.minimumPrefillFrames) <= UInt64(prepared.receiveCapacityBytes) / frameBytes,
              frameBytes <= UInt64(maximumReadBytes) else {
            throw AudioFilePCMPlaybackError.invalidPreparedOutput
        }
        let capacityFrames = UInt64(prepared.receiveCapacityBytes) / frameBytes
        let readFrames = UInt64(maximumReadBytes) / frameBytes
        let prefill = min(capacityFrames, max(UInt64(prepared.minimumPrefillFrames), UInt64(format.sampleRate) / 10))
        var accepted: UInt64 = 0
        var submitted: UInt64 = 0
        var padding: UInt32 = 0
        var started = false
        var progressDeadline = timing.now().advanced(by: .seconds(5))

        func observe(finishing: Bool) throws -> AudioCaptureOutputObservation {
            try check(requireAuthorization)
            let value = try output.observe()
            try check(requireAuthorization)
            guard value.state != .failed else { throw AudioFilePCMPlaybackError.outputLost }
            guard value.acceptedSourceFrames == accepted,
                  value.submittedSourceFrames >= submitted, value.submittedSourceFrames <= accepted,
                  accepted - value.submittedSourceFrames <= capacityFrames,
                  value.trailingPaddingFrames >= padding else { throw AudioFilePCMPlaybackError.invalidProgress }
            if finishing {
                guard value.state == .draining || value.state == .completed else { throw AudioFilePCMPlaybackError.invalidProgress }
            } else {
                guard value.state == (started ? .running : .prepared), value.trailingPaddingFrames == 0 else {
                    throw AudioFilePCMPlaybackError.invalidProgress
                }
            }
            if value.submittedSourceFrames > submitted {
                progressDeadline = timing.now().advanced(by: .seconds(5))
                // A bounded synchronous observer runs on the producer, never in the HAL callback.
                // It sees validated source submissions only; padding and drain remain separate.
                if started || finishing { onOutputProgress?(value.submittedSourceFrames) }
            }
            submitted = value.submittedSourceFrames; padding = value.trailingPaddingFrames
            return value
        }

        _ = try observe(finishing: false) // Reject a nonempty/reused output before reading or effecting it.
        while accepted < totalFrames {
            let observation = try observe(finishing: false)
            let free = capacityFrames - (accepted - observation.submittedSourceFrames)
            if free == 0 {
                guard timing.now() < progressDeadline else { throw AudioFilePCMPlaybackError.timedOut(.outputProgress) }
                try await pause(timing, authorization: requireAuthorization)
                continue
            }
            let frames = min(readFrames, free, totalFrames - accepted)
            let length = Int(frames * frameBytes) // At most maximumReadBytes, whole frames only.
            try check(requireAuthorization)
            let bytes = try await readFramesOperation(accepted, Int(frames))
            try check(requireAuthorization)
            guard bytes.count == length else { throw AudioFilePCMPlaybackError.invalidDescriptor }
            try await effect(.enqueue, timing: timing, authorization: requireAuthorization) {
                try output.enqueue(bytes, ownerID: ownerID)
            }
            accepted += frames
            if accepted == totalFrames { break }
            if !started, accepted >= prefill {
                try await effect(.start, timing: timing, authorization: requireAuthorization) {
                    try output.start(ownerID: ownerID)
                }
                started = true; progressDeadline = timing.now().advanced(by: .seconds(5))
            }
        }

        // FLAC must finish the second exact decoder pass before sealing native input. WAVE has
        // no decoder finalizer. Neither successful decoding nor submitted frames prove drain.
        try check(requireAuthorization)
        try await verifyEnd()
        try check(requireAuthorization)

        // Native finishInput starts a short/unstarted file, and treats zero frames as no audio.
        // It also retains the final source timestamp when EOF follows a full native callback.
        let drainDeadline = timing.now().advanced(by: .seconds(180))
        try await effect(.finishInput, timing: timing, authorization: requireAuthorization) {
            try output.finishInput(ownerID: ownerID, expectedSourceFrames: totalFrames)
        }
        while true {
            guard timing.now() < drainDeadline else { throw AudioFilePCMPlaybackError.timedOut(.drain) }
            let observation = try observe(finishing: true)
            if observation.state == .completed {
                guard accepted == totalFrames, submitted == totalFrames else {
                    throw AudioFilePCMPlaybackError.invalidProgress
                }
                try check(requireAuthorization)
                return .init(sourceFrames: submitted, trailingPaddingFrames: padding)
            }
            try await pause(timing, authorization: requireAuthorization)
        }
    }

    private static func check(_ authorization: @Sendable () throws -> Void) throws {
        try Task.checkCancellation()
        try authorization()
    }

    private static func pause(_ timing: Timing, authorization: @Sendable () throws -> Void) async throws {
        try check(authorization)
        try await timing.pause(.milliseconds(2))
        try check(authorization)
    }

    private static func effect(_ operation: AudioFilePCMPlaybackError.Wait, timing: Timing,
        authorization: @Sendable () throws -> Void, perform: @Sendable () throws -> Void
    ) async throws {
        let deadline = timing.now().advanced(by: .milliseconds(500))
        while true {
            try check(authorization)
            guard timing.now() < deadline else { throw AudioFilePCMPlaybackError.timedOut(operation) }
            do { try perform() }
            catch CoreAudioExactPcmOutputError.busy {
                guard timing.now() < deadline else { throw AudioFilePCMPlaybackError.timedOut(operation) }
                try await pause(timing, authorization: authorization)
                continue
            }
            // Authorization errors are never mistaken for a retryable native busy result: the
            // effect may already have accepted bytes, so replaying it could duplicate samples.
            try check(authorization)
            return
        }
    }

    private static func requireFiniteSamples(_ bytes: Data, encoding: AudioStreamingPCMFormat.Encoding,
                                             byteOffset: UInt64) throws {
        guard encoding.isFloatingPoint else { return }
        let width = Int(encoding.containerBits / 8)
        try bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for offset in stride(from: 0, to: raw.count, by: width) {
                // IEEE binary32/binary64: an all-ones exponent means NaN or infinity. Inspect
                // bits only; even negative zero and subnormal payloads remain byte-identical.
                let nonFinite: Bool
                if encoding == .float32 {
                    nonFinite = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) & 0x7f80_0000 == 0x7f80_0000
                } else {
                    nonFinite = UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) & 0x7ff0_0000_0000_0000 == 0x7ff0_0000_0000_0000
                }
                if nonFinite { throw AudioFilePCMPlaybackError.nonFiniteSample(byteOffset: byteOffset + UInt64(offset)) }
            }
        }
    }
}
#endif
