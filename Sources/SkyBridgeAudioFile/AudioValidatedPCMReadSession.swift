import Foundation
import SkyBridgeProtocolCore

/// Shared bounded frame adapter for fully validated lossless files. The typed initializers
/// require a complete codec-specific witness; raw metadata cannot create a playback reader.
/// Retains at most one native frame plus one <=64 KiB read result, never the entire decoded file.
public actor AudioValidatedPCMReadSession {
    public static let maximumReadBytes = 65_536
    private let reader: PreparedOutboundFileReadSession
    private let sourceFrames: UInt64
    private let frameBytes: Int
    private let backend: Backend
    private var position: UInt64 = 0
    private var pending = Data()
    private var pendingOffset = 0
    private var reading = false
    private var closed = false
    private var failure: (any Error)?

    private struct Frame: Sendable { let first: UInt64; let count: UInt32; let bytes: Data }
    private enum Backend: Sendable {
        case flac(AudioFlacPCMDecoder, AudioFlacDecodeReceipt)
        case alac(AudioAlacPCMDecoder, AudioAlacDecodeReceipt)
        var closedError: any Error {
            switch self { case .flac: AudioFlacDecodeError.closed; case .alac: AudioAlacDecodeError.closed }
        }
        var sequenceError: any Error {
            switch self { case .flac: AudioFlacValidationError.invalidSequence; case .alac: AudioAlacValidationError.invalidSequence }
        }
        func close() {
            switch self { case .flac(let decoder, _): decoder.close(); case .alac(let decoder, _): decoder.close() }
        }
        func next(_ authorize: @escaping @Sendable () throws -> Void) async throws -> Frame {
            switch self {
            case .flac(let decoder, _):
                guard case .frame(let first, let count, let bytes) = try await decoder.next(requireAuthorization: authorize) else { throw sequenceError }
                return .init(first: first, count: count, bytes: bytes)
            case .alac(let decoder, _):
                guard case .frame(let first, let count, let bytes) = try await decoder.next(requireAuthorization: authorize) else { throw sequenceError }
                return .init(first: first, count: count, bytes: bytes)
            }
        }
        func finish(_ authorize: @escaping @Sendable () throws -> Void) async throws {
            switch self {
            case .flac(let decoder, let expected):
                guard case .complete(let receipt) = try await decoder.next(requireAuthorization: authorize), receipt == expected else { throw sequenceError }
            case .alac(let decoder, let expected):
                guard case .complete(let receipt) = try await decoder.next(requireAuthorization: authorize), receipt == expected else { throw sequenceError }
            }
        }
    }

    public init(file: AudioValidatedFlacFile) throws {
        reader = file.reader; sourceFrames = file.receipt.sourceFrames
        frameBytes = Int(file.metadata.decodedFormat.bytesPerFrame)
        backend = .flac(try AudioFlacPCMDecoder(reader: file.reader, metadata: file.metadata), file.receipt)
    }

    public init(file: AudioValidatedAlacFile) throws {
        reader = file.reader; sourceFrames = file.receipt.sourceFrames
        frameBytes = Int(file.metadata.decodedFormat.bytesPerFrame)
        backend = .alac(try AudioAlacPCMDecoder(file: file.indexed), file.receipt)
    }

    public func close() {
        closed = true
        backend.close()
        pending = Data(); pendingOffset = 0
    }

    public func read(frameOffset: UInt64, frames: Int,
                     requireAuthorization: @escaping @Sendable () throws -> Void) async throws -> Data {
        guard !closed else { throw backend.closedError }
        if let failure { throw failure }
        guard !reading, frameOffset == position, frames > 0,
              frames <= Self.maximumReadBytes / frameBytes,
              position <= sourceFrames, UInt64(frames) <= sourceFrames - position else { throw backend.sequenceError }
        reading = true
        defer { reading = false }
        do {
            try await validateSource(requireAuthorization)
            let requestedBytes = frames * frameBytes
            var result = Data(); result.reserveCapacity(requestedBytes)
            while result.count < requestedBytes {
                if pendingOffset == pending.count {
                    pending = Data(); pendingOffset = 0
                    let frame = try await backend.next(requireAuthorization)
                    try check(requireAuthorization)
                    guard frame.first == position, frame.count > 0,
                          UInt64(frame.count) <= sourceFrames - position,
                          frame.bytes.count == Int(frame.count) * frameBytes,
                          frame.bytes.count <= 2_097_120 else { throw backend.sequenceError }
                    pending = frame.bytes
                }
                try check(requireAuthorization)
                let count = min(requestedBytes - result.count, pending.count - pendingOffset)
                guard count > 0, count % frameBytes == 0 else { throw backend.sequenceError }
                result.append(pending.subdata(in: pendingOffset..<(pendingOffset + count)))
                pendingOffset += count; position += UInt64(count / frameBytes)
            }
            try await validateSource(requireAuthorization)
            return result
        } catch {
            fail(error)
            throw error
        }
    }

    public func finish(requireAuthorization: @escaping @Sendable () throws -> Void) async throws {
        guard !closed else { throw backend.closedError }
        if let failure { throw failure }
        guard !reading, position == sourceFrames, pendingOffset == pending.count else { throw backend.sequenceError }
        reading = true
        defer { reading = false }
        do {
            try await validateSource(requireAuthorization)
            try await backend.finish(requireAuthorization)
            try await validateSource(requireAuthorization)
            pending = Data(); pendingOffset = 0
        } catch {
            fail(error)
            throw error
        }
    }

    private func check(_ authorize: @Sendable () throws -> Void) throws {
        guard !closed else { throw backend.closedError }
        try Task.checkCancellation(); try authorize(); try Task.checkCancellation()
        guard !closed else { throw backend.closedError }
    }

    /// A cached frame can satisfy a read without another native call. Its held source and
    /// authorization are still checked before and after that read, including after suspension.
    private func validateSource(_ authorize: @Sendable () throws -> Void) async throws {
        try check(authorize)
        try await reader.validateSourceIdentity()
        try check(authorize)
    }

    private func fail(_ error: any Error) {
        failure = error
        backend.close()
        pending = Data(); pendingOffset = 0
    }
}
