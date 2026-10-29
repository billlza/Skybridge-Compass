import Foundation

public enum SkyBridgeOpusEncodeError: Error, Equatable, Sendable {
    case invalidState
    case invalidSourceFrameCount
    case invalidPCMCount(Int)
    case sourceOverrun
    case incompleteSource
    case unexpectedPacketSize(Int)
}

public struct SkyBridgeOpusEncodedPacket: Equatable, Sendable {
    public let sequence: UInt64
    public let firstDecodedFrame: UInt64
    public let bytes: Data
}

/// Codec evidence only: the caller must separately verify source EOF/integrity,
/// authenticated delivery and receiver output before claiming playback completion.
public struct SkyBridgeOpusEncodeCompletion: Equatable, Sendable {
    public let sourceFrames: UInt64
    public let packetCount: UInt64
    public let encodedBytes: UInt64
    public let preSkipFrames: Int
    public let trailingPaddingFrames: Int
}

/// Serial finite-stream owner, deliberately not Sendable. Input is already converted
/// 48 kHz PCM16; this class does not change rate, channel order, gain or source policy.
/// Callers provide at most 4096 whole PCM frames per append and consume each emitted
/// packet synchronously. At most one 960-frame PCM block is retained; no track-sized
/// allocation, task, native callback thread, retry or implicit source completion exists.
///
/// Construct only after session admission/output readiness. The mandatory authority
/// predicate is checked around native work and packet delivery. An error is terminal,
/// including a sink error or a reentrant operation whose error a callback catches.
public final class SkyBridgeOpusStreamEncoder {
    public enum State: Equatable, Sendable { case encoding, finished, cancelled, failed }
    public static let maximumInputFrames = 4096
    public static let maximumSourceFrames = UInt64(Int64.max) - 3840 - 959
    public let format: SkyBridgeOpusStreamFormat
    public let expectedSourceFrames: UInt64
    public private(set) var state = State.encoding
    public private(set) var acceptedSourceFrames: UInt64 = 0
    public private(set) var emittedPackets: UInt64 = 0
    public var bufferedPCMFrames: Int { bufferedSamples / format.channels }
    public var resourcesReleased: Bool { native == nil && buffer.isEmpty && !operationActive }

    private var native: SkyBridgeOpusEncoder?
    private var buffer: [Int16]
    private var bufferedSamples = 0
    private var operationActive = false
    private var failure: (any Error)?
    private let requireAuthorization: () throws -> Void

    public init(channels: Int, bitrate: Int, expectedSourceFrames: UInt64,
                requireAuthorization: @escaping () throws -> Void) throws {
        guard expectedSourceFrames > 0, expectedSourceFrames <= Self.maximumSourceFrames else {
            throw SkyBridgeOpusEncodeError.invalidSourceFrameCount
        }
        // Validate the fixed profile before allocating the native owner.
        _ = try SkyBridgeOpusStreamFormat(channels: channels, bitrate: bitrate, preSkipFrames: 0)
        try requireAuthorization()
        let encoder = try SkyBridgeOpusEncoder(configuration: SkyBridgeOpusConfiguration(
            channels: channels, bitrate: bitrate, complexity: 8, expectedPacketLossPercent: 0,
            inBandFECEnabled: false, dtxEnabled: false, application: .audio, signal: .music,
            bitrateMode: .constant))
        format = try SkyBridgeOpusStreamFormat(channels: channels, bitrate: bitrate,
            preSkipFrames: encoder.lookaheadSamplesPerChannel())
        self.expectedSourceFrames = expectedSourceFrames
        self.requireAuthorization = requireAuthorization
        buffer = [Int16](repeating: 0, count: 960 * channels)
        native = encoder
        try requireAuthorization()
    }

    public func append(pcm16Interleaved input: [Int16],
                       emit: (SkyBridgeOpusEncodedPacket) throws -> Void) throws {
        try perform {
            guard !input.isEmpty, input.count % format.channels == 0,
                  input.count / format.channels <= Self.maximumInputFrames else {
                throw SkyBridgeOpusEncodeError.invalidPCMCount(input.count)
            }
            let frames = UInt64(input.count / format.channels)
            guard frames <= expectedSourceFrames - acceptedSourceFrames else {
                throw SkyBridgeOpusEncodeError.sourceOverrun
            }
            var offset = 0
            while offset < input.count {
                try requireCurrent()
                let count = min(buffer.count - bufferedSamples, input.count - offset)
                buffer.replaceSubrange(bufferedSamples..<(bufferedSamples + count), with: input[offset..<(offset + count)])
                bufferedSamples += count; offset += count
                acceptedSourceFrames += UInt64(count / format.channels)
                if bufferedSamples == buffer.count { try emitBlock(emit) }
            }
        }
    }

    /// Call only after the enclosing source has verified EOF. A short source is a
    /// failure; zeros are appended only for the actual native lookahead and final
    /// whole packet. The receiver must trim both according to this finite receipt.
    public func finish(emit: (SkyBridgeOpusEncodedPacket) throws -> Void) throws -> SkyBridgeOpusEncodeCompletion {
        try perform {
            guard acceptedSourceFrames == expectedSourceFrames else { throw SkyBridgeOpusEncodeError.incompleteSource }
            let packets = (expectedSourceFrames + UInt64(format.preSkipFrames) + 959) / 960
            while emittedPackets < packets {
                try requireCurrent()
                for index in bufferedSamples..<buffer.count { buffer[index] = 0 }
                bufferedSamples = buffer.count
                try emitBlock(emit)
            }
            let padding = Int(packets * 960 - expectedSourceFrames - UInt64(format.preSkipFrames))
            let receipt = SkyBridgeOpusEncodeCompletion(sourceFrames: acceptedSourceFrames,
                packetCount: emittedPackets, encodedBytes: emittedPackets * UInt64(format.packetBytes),
                preSkipFrames: format.preSkipFrames, trailingPaddingFrames: padding)
            release(); state = .finished
            return receipt
        }
    }

    public func cancel() {
        guard state == .encoding else { return }
        state = .cancelled; release()
    }

    private func perform<T>(_ action: () throws -> T) throws -> T {
        // Install the reentry fence before invoking caller-owned authorization.
        guard !operationActive else {
            let error = SkyBridgeOpusEncodeError.invalidState
            if state == .encoding { failure = error; state = .failed; release() }
            throw failure ?? error
        }
        operationActive = true
        defer { operationActive = false }
        do {
            try requireCurrent()
            return try action()
        } catch {
            if state == .encoding { failure = error; state = .failed; release() }
            throw failure ?? error
        }
    }

    private func requireCurrent() throws {
        if let failure { throw failure }
        guard state == .encoding else { throw SkyBridgeOpusEncodeError.invalidState }
        try requireAuthorization()
        // The authorization callback itself must not reenter/cancel this owner.
        if let failure { throw failure }
        guard state == .encoding else { throw SkyBridgeOpusEncodeError.invalidState }
    }

    private func emitBlock(_ emit: (SkyBridgeOpusEncodedPacket) throws -> Void) throws {
        try requireCurrent()
        guard let native else { throw SkyBridgeOpusEncodeError.invalidState }
        let bytes = try native.encode(pcm16Interleaved: buffer, maxPacketBytes: format.packetBytes)
        try requireCurrent()
        guard bytes.count == format.packetBytes else { throw SkyBridgeOpusEncodeError.unexpectedPacketSize(bytes.count) }
        try emit(SkyBridgeOpusEncodedPacket(sequence: emittedPackets, firstDecodedFrame: emittedPackets * 960, bytes: bytes))
        try requireCurrent()
        emittedPackets += 1
        for index in buffer.indices { buffer[index] = 0 }
        bufferedSamples = 0
    }

    private func release() {
        native = nil
        for index in buffer.indices { buffer[index] = 0 }
        buffer.removeAll(keepingCapacity: false); bufferedSamples = 0
    }
}
