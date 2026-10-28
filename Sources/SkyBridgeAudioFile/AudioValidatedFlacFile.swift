#if os(macOS) || os(iOS)
import Foundation
import SkyBridgeProtocolCore

public enum AudioFlacValidationError: Error, Equatable, Sendable {
    case invalidLimit, unsupportedDuration, timedOut, invalidSequence
}

/// A complete decoder pass over one committed reader, before any output device is opened. Only
/// this factory can construct the witness. Playback makes a fresh sequential decoder over the
/// same reader; it retains at most one decoded frame, not an unbounded whole-file PCM cache.
public struct AudioValidatedFlacFile: Sendable {
    public static let maximumValidationTime: Duration = .seconds(180)
    public static let maximumSourceSeconds: UInt64 = 14_400
    public let reader: PreparedOutboundFileReadSession
    public let metadata: AudioFlacMetadata
    public let receipt: AudioFlacDecodeReceipt

    private init(reader: PreparedOutboundFileReadSession, metadata: AudioFlacMetadata, receipt: AudioFlacDecodeReceipt) {
        self.reader = reader; self.metadata = metadata; self.receipt = receipt
    }

    public static func validate(reader: PreparedOutboundFileReadSession,
        requireAuthorization: @escaping @Sendable () throws -> Void,
        maximumTime: Duration = maximumValidationTime,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) async throws -> Self {
        guard maximumTime > .zero, maximumTime <= maximumValidationTime else { throw AudioFlacValidationError.invalidLimit }
        let deadline = now().advanced(by: maximumTime)
        let check: @Sendable () throws -> Void = {
            try Task.checkCancellation(); try requireAuthorization(); try Task.checkCancellation()
            guard now() < deadline else { throw AudioFlacValidationError.timedOut }
        }
        try check()
        // Derive every declaration, including the channel-mask tag, from this exact held reader.
        // Callers cannot pair another file's metadata with a valid decode witness.
        let metadata = try await AudioFlacFile.inspect(fileSize: UInt64(reader.metadata.fileSize)) { offset, length in
            try check()
            let bytes = try await reader.read(offset: offset, length: length)
            try check()
            return bytes
        }
        guard let frames = metadata.totalFrames, frames > 0,
              frames <= UInt64(metadata.decodedFormat.sampleRate) * maximumSourceSeconds else {
            throw AudioFlacValidationError.unsupportedDuration
        }
        try check()
        let decoder = try AudioFlacPCMDecoder(reader: reader, metadata: metadata)
        defer { decoder.close() }
        while true {
            switch try await decoder.next(requireAuthorization: check) {
            case .frame: break // Discard the validated PCM immediately; no output effect is permitted here.
            case .complete(let receipt):
                try check()
                return .init(reader: reader, metadata: metadata, receipt: receipt)
            }
        }
    }
}

/// Existing FLAC API name; both lossless codecs use the same bounded, authorized frame adapter.
public typealias AudioFlacPCMReadSession = AudioValidatedPCMReadSession
#endif
