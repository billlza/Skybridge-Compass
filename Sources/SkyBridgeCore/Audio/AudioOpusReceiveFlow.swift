import CryptoKit
import Foundation
import SkyBridgeOpus
import SkyBridgeProtocolCore

enum AudioOpusReceiveError: Error, Equatable {
    case wrongStream, invalidState, invalidConfiguration, discontinuity, windowExceeded
    case invalidProgress, contentMismatch
}

/// Codec and queue accounting for one already admitted compatible stream. The owning session
/// must enforce the actual Bluetooth route, account lease, permission and output owner before
/// every operation and inside enqueue. This class grants none of those authorities.
///
/// Single serial owner, not Sendable. enqueue must be synchronous and must not reenter the flow.
/// Bytes are committed only after native enqueue succeeds; any error retires the decoder. Credit
/// tracks complete encoded packets whose decoded source frames have left that same output queue,
/// not merely received packets or bytes submitted to an audio API. One final packet stays held
/// until OpusEnd supplies the exact source count. Completion still requires a native drain receipt.
final class AudioOpusReceiveFlow {
    enum State: Equatable { case awaitingConfiguration, receiving, contentVerified, completed, failed, cancelled }
    let streamID: UUID
    let source: AudioStreamingOpusSource
    let format: AudioStreamingOpusFormat
    let buffering: AudioStreamingOpusBuffering
    var windowPackets: UInt64 { UInt64(buffering.windowPackets) }
    var windowBytes: UInt32 { UInt32(windowPackets) * format.packetBytes }
    private(set) var state = State.awaitingConfiguration
    private(set) var receivedPackets: UInt64 = 0
    private(set) var retiredEncodedBytes: UInt64 = 0
    private(set) var enqueuedSourceFrames: UInt64 = 0
    private(set) var retiredSourceFrames: UInt64 = 0
    private(set) var expectedSourceFrames: UInt64?
    private(set) var verifiedDigest: Data?
    private(set) var trailingCodecPaddingFrames: UInt32?
    var receivedEncodedBytes: UInt64 { receivedPackets * UInt64(format.packetBytes) }
    var bufferedCodecFrames: Int { decoder?.bufferedPCMFrames ?? 0 }
    private var preSkipFrames: UInt16?
    private var decoder: SkyBridgeOpusStreamDecoder?
    private var digest = SHA256()

    init(offer: AudioStreamingMessage) throws {
        _ = try AudioStreamingWire.encode(offer)
        guard let parameters = offer.body.opusOfferParameters else { throw AudioOpusReceiveError.invalidConfiguration }
        self.streamID = offer.streamID; self.source = parameters.source; self.format = parameters.format
        self.buffering = parameters.buffering
    }

    func configure(_ message: AudioStreamingMessage) throws {
        try perform {
            try requireStream(message)
            guard state == .awaitingConfiguration else { throw AudioOpusReceiveError.invalidState }
            guard case let .opusConfiguration(skip) = message.body,
                  skip <= AudioStreamingWire.maximumOpusPreSkipFrames else { throw AudioOpusReceiveError.invalidConfiguration }
            decoder = try SkyBridgeOpusStreamDecoder(format: .init(channels: Int(format.channels),
                bitrate: Int(format.bitrate), preSkipFrames: Int(skip)))
            preSkipFrames = skip; state = .receiving
        }
    }

    func receive(_ message: AudioStreamingMessage, enqueue: (SkyBridgeOpusDecodedChunk) throws -> Void) throws {
        try perform {
            try requireStream(message)
            guard state == .receiving, let decoder else { throw AudioOpusReceiveError.invalidState }
            guard case let .opusData(sequence, bytes) = message.body, sequence == receivedPackets,
                  sequence < AudioStreamingWire.maximumOpusPacketCount, bytes.count == Int(format.packetBytes) else {
                throw AudioOpusReceiveError.discontinuity
            }
            guard receivedEncodedBytes >= retiredEncodedBytes,
                  receivedEncodedBytes - retiredEncodedBytes < UInt64(windowBytes) else { throw AudioOpusReceiveError.windowExceeded }
            if let chunk = try decoder.append(packet: bytes, sequence: sequence) { try deliver(chunk, enqueue: enqueue) }
            guard state == .receiving else { throw AudioOpusReceiveError.invalidState }
            digest.update(data: bytes)
            receivedPackets += 1
        }
    }

    /// Returns a changed absolute byte credit, or nil for unchanged native progress only.
    func retire(sourceFrames: UInt64) throws -> UInt64? {
        try perform {
            guard state == .receiving || state == .contentVerified, let skip = preSkipFrames else {
                throw AudioOpusReceiveError.invalidState
            }
            guard sourceFrames >= retiredSourceFrames, sourceFrames <= enqueuedSourceFrames,
                  sourceFrames <= AudioStreamingWire.maximumCounter - UInt64(skip) else {
                throw AudioOpusReceiveError.invalidProgress
            }
            // A verified end is necessarily nonempty. Keep its last encoded acknowledgement
            // pending until native completion, including the exact-boundary/no-padding case.
            let maximumRetirable = state == .contentVerified ? receivedPackets - 1 : receivedPackets
            let retiredPackets = min(maximumRetirable, (sourceFrames + UInt64(skip)) / 960)
            let bytes = retiredPackets * UInt64(format.packetBytes)
            guard bytes >= retiredEncodedBytes else { throw AudioOpusReceiveError.invalidProgress }
            retiredSourceFrames = sourceFrames
            guard bytes > retiredEncodedBytes else { return nil }
            retiredEncodedBytes = bytes
            return bytes
        }
    }

    /// Verifies compressed bytes and count, then delivers the trimmed final decoded chunk.
    /// The caller seals the native input only after this succeeds, under the same effect gate.
    func verifyEnd(_ message: AudioStreamingMessage, enqueue: (SkyBridgeOpusDecodedChunk) throws -> Void) throws -> UInt64 {
        try perform {
            try requireStream(message)
            guard state == .receiving, let decoder else { throw AudioOpusReceiveError.invalidState }
            _ = try AudioStreamingWire.encode(message)
            guard case let .opusEnd(frames, count, total, expectedHash) = message.body,
                  receivedPackets > 0, count == receivedPackets, total == receivedEncodedBytes,
                  Data(digest.finalize()) == expectedHash else { throw AudioOpusReceiveError.contentMismatch }
            let completion = try decoder.finish(expectedPCMFrames: frames)
            try deliver(completion.finalChunk, enqueue: enqueue)
            guard state == .receiving, enqueuedSourceFrames == frames else { throw AudioOpusReceiveError.invalidState }
            expectedSourceFrames = frames; verifiedDigest = expectedHash
            trailingCodecPaddingFrames = UInt32(completion.trailingPaddingFrames)
            self.decoder = nil
            state = .contentVerified
            return frames
        }
    }

    /// The owner must first observe actual native completion and matching source progress.
    /// Codec tail padding is already discarded, and is separate from device queue padding.
    @discardableResult
    func didComplete(sourceFrames: UInt64) throws -> UInt64 {
        try perform {
            guard state == .contentVerified, let expectedSourceFrames,
                  sourceFrames == expectedSourceFrames, enqueuedSourceFrames == expectedSourceFrames,
                  retiredSourceFrames == expectedSourceFrames else { throw AudioOpusReceiveError.invalidProgress }
            // Final source progress plus native completion retire the last encoded extent,
            // regardless of whether the last packet contained discarded codec padding.
            retiredEncodedBytes = receivedEncodedBytes
            state = .completed
            return retiredEncodedBytes
        }
    }

    func cancel() {
        guard state == .awaitingConfiguration || state == .receiving || state == .contentVerified else { return }
        decoder?.cancel(); decoder = nil; state = .cancelled
    }

    private func requireStream(_ message: AudioStreamingMessage) throws {
        guard message.streamID == streamID else { throw AudioOpusReceiveError.wrongStream }
    }

    private func deliver(_ chunk: SkyBridgeOpusDecodedChunk, enqueue: (SkyBridgeOpusDecodedChunk) throws -> Void) throws {
        guard chunk.firstPCMFrame == enqueuedSourceFrames, chunk.frameCount > 0,
              chunk.pcm16LE.count == chunk.frameCount * Int(format.channels) * 2,
              UInt64(chunk.frameCount) <= AudioStreamingWire.maximumCounter - enqueuedSourceFrames else {
            throw AudioOpusReceiveError.invalidProgress
        }
        try enqueue(chunk)
        guard state == .receiving else { throw AudioOpusReceiveError.invalidState }
        enqueuedSourceFrames += UInt64(chunk.frameCount)
    }

    private func perform<T>(_ action: () throws -> T) throws -> T {
        do { return try action() }
        catch {
            if state == .awaitingConfiguration || state == .receiving || state == .contentVerified {
                decoder?.cancel(); decoder = nil; state = .failed
            }
            throw error
        }
    }
}
