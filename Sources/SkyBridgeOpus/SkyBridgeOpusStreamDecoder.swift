import Foundation
import CSkyBridgeOpusShim

public enum SkyBridgeOpusStreamError: Error, Equatable, Sendable {
    case unsupportedFormat
    case invalidState
    case unexpectedSequence(expected: UInt64, actual: UInt64)
    case invalidPacketSize(Int)
    case invalidPacketDuration(Int32)
    case invalidDecodedFrameCount
    case counterExhausted
    case invalidEnd
}

/// Bounded CBR profile for an explicitly compressed audio stream. The PCM frame
/// counters below use this 48 kHz format, not a file's pre-conversion frame count.
/// Creating a profile does not negotiate a capability or grant playback access.
public struct SkyBridgeOpusStreamFormat: Equatable, Sendable {
    public let sampleRate: Int
    public let channels: Int
    public let frameSamples: Int
    public let bitrate: Int
    public let preSkipFrames: Int
    public var packetBytes: Int { bitrate / 400 }

    public init(sampleRate: Int = 48_000, channels: Int = 2, frameSamples: Int = 960,
                bitrate: Int, preSkipFrames: Int) throws {
        guard sampleRate == 48_000, (1...2).contains(channels), frameSamples == 960,
              [128_000, 192_000, 256_000].contains(bitrate), (0...3840).contains(preSkipFrames) else {
            throw SkyBridgeOpusStreamError.unsupportedFormat
        }
        self.sampleRate = sampleRate; self.channels = channels; self.frameSamples = frameSamples
        self.bitrate = bitrate; self.preSkipFrames = preSkipFrames
    }
}

public struct SkyBridgeOpusDecodedChunk: Equatable, Sendable {
    public let firstPCMFrame: UInt64
    public let frameCount: Int
    public let pcm16LE: Data
}

/// Codec completion only. Native output acceptance, consumption and drain must
/// be checked separately before a caller can report playback completion.
public struct SkyBridgeOpusDecodeCompletion: Equatable, Sendable {
    public let finalChunk: SkyBridgeOpusDecodedChunk
    public let totalPCMFrames: UInt64
    public let discardedDelayFrames: Int
    public let trailingPaddingFrames: Int
}

/// Serial, single-stream owner; deliberately not Sendable. The caller owns
/// authentication, stream routing, consent and output scheduling. Every packet
/// is independently bounded before the native decoder runs. Missing, reordered
/// or malformed packets terminate this owner; they never invoke PLC or a reset.
///
/// At most one decoded 20 ms packet is retained. Leading codec delay is removed
/// immediately, while the last packet stays here until an authenticated end
/// count arrives. This prevents encoder drain padding from reaching the output.
public final class SkyBridgeOpusStreamDecoder {
    public enum State: Equatable, Sendable { case receiving, finished, cancelled, failed }
    public let format: SkyBridgeOpusStreamFormat
    public private(set) var state = State.receiving
    public private(set) var acceptedPackets: UInt64 = 0
    public private(set) var decodedFramesIncludingDelay: UInt64 = 0
    public private(set) var emittedPCMFrames: UInt64 = 0
    public var bufferedPCMFrames: Int { pending.count / format.channels }
    private var native: SkyBridgeOpusDecoder?
    private var delayRemaining: Int
    private var pending: [Int16] = []

    public init(format: SkyBridgeOpusStreamFormat) throws {
        self.format = format
        delayRemaining = format.preSkipFrames
        native = try SkyBridgeOpusDecoder(sampleRate: format.sampleRate, channels: format.channels, frameDurationMs: 20)
    }

    /// Nil has one defined meaning: all decoded data is still delay or the held
    /// final packet. Returned bytes are handed to the caller, not already played.
    public func append(packet: Data, sequence: UInt64) throws -> SkyBridgeOpusDecodedChunk? {
        guard state == .receiving else { throw SkyBridgeOpusStreamError.invalidState }
        do {
            guard sequence == acceptedPackets else {
                throw SkyBridgeOpusStreamError.unexpectedSequence(expected: acceptedPackets, actual: sequence)
            }
            guard packet.count == format.packetBytes else { throw SkyBridgeOpusStreamError.invalidPacketSize(packet.count) }
            guard decodedFramesIncludingDelay <= UInt64(Int64.max) - UInt64(format.frameSamples) else {
                throw SkyBridgeOpusStreamError.counterExhausted
            }
            let duration = packet.withUnsafeBytes { raw -> Int32 in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return OPUS_BAD_ARG }
                return opus_packet_get_nb_samples(base, Int32(packet.count), Int32(format.sampleRate))
            }
            guard duration == format.frameSamples else { throw SkyBridgeOpusStreamError.invalidPacketDuration(duration) }
            guard let native else { throw SkyBridgeOpusStreamError.invalidState }
            let decoded = try native.decode(packet: packet, frameSamplesPerChannel: format.frameSamples, useFEC: false)
            guard decoded.count == format.frameSamples * format.channels else {
                throw SkyBridgeOpusStreamError.invalidDecodedFrameCount
            }
            let skip = min(delayRemaining, format.frameSamples)
            delayRemaining -= skip
            decodedFramesIncludingDelay += UInt64(format.frameSamples)
            acceptedPackets += 1
            let previous = pending
            pending = Array(decoded.dropFirst(skip * format.channels))
            guard !previous.isEmpty else { return nil }
            let chunk = makeChunk(previous)
            emittedPCMFrames += UInt64(chunk.frameCount)
            return chunk
        } catch {
            terminate(.failed)
            throw error
        }
    }

    /// expectedPCMFrames excludes both the reported Opus delay and explicitly
    /// added encoder drain samples. This profile permits less than one packet of
    /// trailing padding, matching its qualified finite input/output accounting.
    public func finish(expectedPCMFrames: UInt64) throws -> SkyBridgeOpusDecodeCompletion {
        guard state == .receiving else { throw SkyBridgeOpusStreamError.invalidState }
        do {
            guard acceptedPackets > 0, delayRemaining == 0, expectedPCMFrames > 0,
                  decodedFramesIncludingDelay >= UInt64(format.preSkipFrames) else {
                throw SkyBridgeOpusStreamError.invalidEnd
            }
            let available = decodedFramesIncludingDelay - UInt64(format.preSkipFrames)
            guard expectedPCMFrames <= available, expectedPCMFrames >= emittedPCMFrames else {
                throw SkyBridgeOpusStreamError.invalidEnd
            }
            let padding = available - expectedPCMFrames
            let remaining = expectedPCMFrames - emittedPCMFrames
            guard padding < UInt64(format.frameSamples), remaining > 0,
                  remaining <= UInt64(bufferedPCMFrames),
                  UInt64(bufferedPCMFrames) - remaining == padding else {
                throw SkyBridgeOpusStreamError.invalidEnd
            }
            let chunk = makeChunk(Array(pending.prefix(Int(remaining) * format.channels)))
            emittedPCMFrames += remaining
            terminate(.finished)
            return SkyBridgeOpusDecodeCompletion(finalChunk: chunk, totalPCMFrames: emittedPCMFrames,
                discardedDelayFrames: format.preSkipFrames, trailingPaddingFrames: Int(padding))
        } catch {
            terminate(.failed)
            throw error
        }
    }

    public func cancel() {
        if state == .receiving { terminate(.cancelled) }
    }

    private func terminate(_ terminal: State) {
        pending.removeAll(keepingCapacity: false)
        native = nil
        state = terminal
    }

    private func makeChunk(_ samples: [Int16]) -> SkyBridgeOpusDecodedChunk {
        let littleEndian = samples.map(\.littleEndian)
        let data = littleEndian.withUnsafeBufferPointer { Data(buffer: $0) }
        return SkyBridgeOpusDecodedChunk(firstPCMFrame: emittedPCMFrames,
            frameCount: samples.count / format.channels, pcm16LE: data)
    }
}
