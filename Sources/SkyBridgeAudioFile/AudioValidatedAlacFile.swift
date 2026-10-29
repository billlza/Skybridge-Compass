import Foundation
import SkyBridgeProtocolCore

public enum AudioAlacValidationError: Error, Equatable, Sendable {
    case invalidLimit, unsupportedDuration, timedOut, invalidSequence
}

/// A complete, bounded native pass over the same held source, before output admission. Only
/// this factory constructs the witness. Playback must still recheck authorization and source
/// ownership; the witness neither opens an output nor exempts later reads from those checks.
public struct AudioValidatedAlacFile: Sendable {
    public static let maximumValidationTime: Duration = .seconds(180)
    public static let maximumSourceSeconds: UInt64 = 14_400
    public var reader: PreparedOutboundFileReadSession { indexed.reader }
    public var metadata: AudioAlacMetadata { indexed.metadata }
    public let receipt: AudioAlacDecodeReceipt
    let indexed: AudioIndexedAlacFile

    private init(indexed: AudioIndexedAlacFile, receipt: AudioAlacDecodeReceipt) {
        self.indexed = indexed; self.receipt = receipt
    }

    public static func validate(reader: PreparedOutboundFileReadSession,
        requireAuthorization: @escaping @Sendable () throws -> Void,
        maximumTime: Duration = maximumValidationTime,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) async throws -> Self {
        guard maximumTime > .zero, maximumTime <= maximumValidationTime else { throw AudioAlacValidationError.invalidLimit }
        let deadline = now().advanced(by: maximumTime)
        let check: @Sendable () throws -> Void = {
            try Task.checkCancellation(); try requireAuthorization(); try Task.checkCancellation()
            guard now() < deadline else { throw AudioAlacValidationError.timedOut }
        }
        try check()
        let indexed = try await AudioIndexedAlacFile.inspect(reader: reader, requireAuthorization: check)
        let metadata = indexed.metadata
        guard metadata.totalFrames > 0,
              metadata.totalFrames <= UInt64(metadata.decodedFormat.sampleRate) * maximumSourceSeconds else {
            throw AudioAlacValidationError.unsupportedDuration
        }
        try check()
        let decoder = try AudioAlacPCMDecoder(file: indexed)
        defer { decoder.close() }
        // Exactly one native frame per indexed packet, then clean EOF. Decoded prefixes are
        // discarded here, even if a later packet fails; no whole-file PCM cache is retained.
        for packet in 0...metadata.packetCount {
            switch try await decoder.next(requireAuthorization: check) {
            case .frame:
                guard packet < metadata.packetCount else { throw AudioAlacValidationError.invalidSequence }
            case .complete(let receipt):
                guard packet == metadata.packetCount, receipt.sourceFrames == metadata.totalFrames,
                      receipt.packets == metadata.packetCount,
                      receipt.encodedAudioBytes == metadata.encodedAudioBytes else { throw AudioAlacValidationError.invalidSequence }
                try check()
                return .init(indexed: indexed, receipt: receipt)
            }
        }
        throw AudioAlacValidationError.invalidSequence
    }
}

public typealias AudioAlacPCMReadSession = AudioValidatedPCMReadSession
