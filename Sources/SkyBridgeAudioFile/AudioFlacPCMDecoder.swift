#if os(macOS) || os(iOS)
import CSkyBridgeFLAC
import Foundation
import SkyBridgeProtocolCore
import os

public enum AudioFlacDecodeError: Error, Equatable, Sendable {
    case invalidMetadata, invalidNativeResult, closed
    case native(status: UInt32, codecError: Int32)
}

public struct AudioFlacDecodeReceipt: Equatable, Sendable {
    public let sourceFrames: UInt64
    public let encodedBytes: UInt64
    public let md5Available: Bool
    public let md5Verified: Bool
}

public enum AudioFlacDecodeStep: Sendable {
    case frame(firstIndex: UInt64, frameCount: UInt32, bytes: Data)
    case complete(AudioFlacDecodeReceipt)
}

/// One sequential decoder over the caller's held, commitment-verified reader. Each step lends a
/// synchronous reader callback only for the native call, and produces at most one FLAC frame.
/// This owner closes only codec state. Its outer file-transfer owner must close the reader.
/// A decoded prefix is not a validated file or an authorization to play it.
public final class AudioFlacPCMDecoder: Sendable {
    public let metadata: AudioFlacMetadata
    public let frameCount: UInt64
    private let reader: PreparedOutboundFileReadSession
    private let fileBytes: UInt64
    private let outputCapacity: Int
    // All pointer and borrowed-callback access is serialized by this SDK lock. C callbacks run
    // synchronously within that same critical section; they never reacquire it or escape it.
    private let state: OSAllocatedUnfairLock<State>
    private struct CallState { var thread: ObjectIdentifier?; var closing = false }
    // This short-lived flag lock is never held while waiting for the native-state lock.
    // It lets a synchronous authorization callback request close without recursively locking it.
    private let calls = OSAllocatedUnfairLock(initialState: CallState())

    private final class State {
        var decoder: OpaquePointer?
        var read: ((UInt64, Int) throws -> Data)?
        var authorize: (() throws -> Void)?
        var callbackFailure: (any Error)?
        var failure: (any Error)?
        var frames: UInt64 = 0
        var encodedBytes: UInt64 = 0
        var receipt: AudioFlacDecodeReceipt?

        init(_ decoder: OpaquePointer) { self.decoder = decoder }
        deinit { if let decoder { sbflac_decoder_destroy(decoder) } }
    }

    public init(reader: PreparedOutboundFileReadSession, metadata: AudioFlacMetadata) throws {
        guard reader.metadata.fileSize > 0, let frames = metadata.totalFrames, frames > 0,
              (4...32).contains(metadata.decodedFormat.declaredValidBits),
              (1...8).contains(metadata.decodedFormat.channels),
              !metadata.decodedFormat.encoding.isFloatingPoint,
              metadata.decodedFormat.encoding.containerBits == ((metadata.decodedFormat.declaredValidBits + 7) / 8) * 8 else {
            throw AudioFlacDecodeError.invalidMetadata
        }
        var description = SBFLACSourceDescription()
        description.sample_rate = metadata.decodedFormat.sampleRate
        description.channels = UInt32(metadata.decodedFormat.channels)
        description.valid_bits = UInt32(metadata.decodedFormat.declaredValidBits)
        description.minimum_block_frames = UInt32(metadata.minimumBlockFrames)
        description.maximum_block_frames = UInt32(metadata.maximumBlockFrames)
        description.minimum_frame_bytes = metadata.minimumFrameBytes ?? 0
        description.maximum_frame_bytes = metadata.maximumFrameBytes ?? 0
        description.total_frames = frames
        description.first_frame_byte_offset = metadata.firstFrameByteOffset
        if let hex = metadata.pcmMD5Hex {
            let characters = Array(hex.utf8)
            guard characters.count == 32 else { throw AudioFlacDecodeError.invalidMetadata }
            try withUnsafeMutableBytes(of: &description.pcm_md5) { digest in
                for index in 0..<16 {
                    guard let byte = UInt8(String(decoding: characters[(index * 2)..<(index * 2 + 2)], as: UTF8.self), radix: 16) else {
                        throw AudioFlacDecodeError.invalidMetadata
                    }
                    digest[index] = byte
                }
            }
        }
        let capacity = Int(metadata.maximumBlockFrames) * Int(metadata.decodedFormat.bytesPerFrame)
        guard (1...2_097_120).contains(capacity) else { throw AudioFlacDecodeError.invalidMetadata }
        var decoder: OpaquePointer?
        let status = sbflac_decoder_create(&description, UInt64(reader.metadata.fileSize), frames, &decoder)
        guard status == SBFLAC_READY, let decoder else {
            if let decoder { sbflac_decoder_destroy(decoder) }
            throw AudioFlacDecodeError.native(status: status.rawValue, codecError: -1)
        }
        self.reader = reader
        self.metadata = metadata
        frameCount = frames
        fileBytes = UInt64(reader.metadata.fileSize)
        outputCapacity = capacity
        state = OSAllocatedUnfairLock(uncheckedState: State(decoder))
    }

    public func next(requireAuthorization: @escaping @Sendable () throws -> Void) async throws -> AudioFlacDecodeStep {
        let authorize: @Sendable () throws -> Void = { try self.requireCallCurrent(requireAuthorization) }
        return try await reader.withSynchronousVerifiedReads { read, validateSource in
            try self.step(read: read, validateSource: validateSource, requireAuthorization: authorize)
        }
    }

    /// External callers wait for the borrowed native step. Reentrant callback close marks that
    /// same step cancelled and defers destruction until it returns; no PCM/completion is emitted.
    public func close() {
        let thread = ObjectIdentifier(Thread.current)
        let deferred = calls.withLock { call in call.closing = true; return call.thread == thread }
        if deferred { return }
        state.withLockUnchecked { state in
            if let decoder = state.decoder { sbflac_decoder_destroy(decoder); state.decoder = nil }
        }
    }

    private func requireCallCurrent(_ authorize: @Sendable () throws -> Void) throws {
        try Task.checkCancellation()
        guard !calls.withLock({ $0.closing }) else { throw AudioFlacDecodeError.closed }
        try authorize()
        try Task.checkCancellation()
        guard !calls.withLock({ $0.closing }) else { throw AudioFlacDecodeError.closed }
    }

    private func step(read: (UInt64, Int) throws -> Data,
                      validateSource: () throws -> Void,
                      requireAuthorization: @Sendable () throws -> Void) throws -> AudioFlacDecodeStep {
        try state.withLockUnchecked { state in
            guard let decoder = state.decoder else { throw AudioFlacDecodeError.closed }
            if let failure = state.failure { throw failure }
            calls.withLock { $0.thread = ObjectIdentifier(Thread.current) }
            defer {
                let close = calls.withLock { call in call.thread = nil; return call.closing }
                if close, let decoder = state.decoder { sbflac_decoder_destroy(decoder); state.decoder = nil }
            }
            do {
                try validateSource()
                try Task.checkCancellation()
                try requireAuthorization()
                if let receipt = state.receipt { return .complete(receipt) }
                guard state.read == nil, state.authorize == nil else { throw AudioFlacDecodeError.invalidNativeResult }
                return try withoutActuallyEscaping(read) { borrowedRead in
                    try withoutActuallyEscaping(requireAuthorization) { borrowedAuthorization in
                        state.read = borrowedRead
                        state.authorize = borrowedAuthorization
                        state.callbackFailure = nil
                        defer { state.read = nil; state.authorize = nil; state.callbackFailure = nil }
                        var access = SBFLACReadAccess(context: Unmanaged.passUnretained(state).toOpaque(),
                                                      read_at: Self.readCallback, is_cancelled: Self.cancelCallback)
                        var result = SBFLACResult()
                        var output = Data(count: outputCapacity)
                        let status = output.withUnsafeMutableBytes { raw in
                            sbflac_decoder_next(decoder, &access, raw.bindMemory(to: UInt8.self).baseAddress,
                                                raw.count, &result)
                        }
                        if let failure = state.callbackFailure { throw failure }
                        try validateSource()
                        try Task.checkCancellation()
                        try requireAuthorization()
                        guard status == SBFLAC_FRAME || status == SBFLAC_COMPLETE else {
                            throw AudioFlacDecodeError.native(status: status.rawValue, codecError: result.codec_error)
                        }
                        guard result.status == status, result.codec_error == -1,
                              result.total_frames <= frameCount,
                              result.encoded_bytes_consumed >= state.encodedBytes,
                              result.encoded_bytes_consumed <= fileBytes,
                              result.md5_available == (metadata.pcmMD5Hex == nil ? 0 : 1) else {
                            throw AudioFlacDecodeError.invalidNativeResult
                        }
                        if status == SBFLAC_FRAME {
                            guard result.first_frame_index == state.frames, result.frame_count > 0,
                                  result.frame_count <= UInt32(metadata.maximumBlockFrames),
                                  result.total_frames == state.frames + UInt64(result.frame_count),
                                  result.byte_count == Int(result.frame_count) * Int(metadata.decodedFormat.bytesPerFrame),
                                  result.byte_count <= output.count, result.md5_verified == 0 else {
                                throw AudioFlacDecodeError.invalidNativeResult
                            }
                            output.count = result.byte_count
                            state.frames = result.total_frames
                            state.encodedBytes = result.encoded_bytes_consumed
                            return .frame(firstIndex: result.first_frame_index, frameCount: result.frame_count, bytes: output)
                        }
                        guard result.total_frames == frameCount, state.frames == frameCount,
                              result.encoded_bytes_consumed == fileBytes, result.byte_count == 0,
                              result.frame_count == 0, result.md5_verified == result.md5_available else {
                            throw AudioFlacDecodeError.invalidNativeResult
                        }
                        let receipt = AudioFlacDecodeReceipt(sourceFrames: frameCount, encodedBytes: fileBytes,
                            md5Available: result.md5_available == 1, md5Verified: result.md5_verified == 1)
                        state.receipt = receipt
                        return .complete(receipt)
                    }
                }
            } catch {
                state.failure = error
                throw error
            }
        }
    }

    private static let readCallback: SBFLACReadAt = { opaque, offset, buffer, capacity, bytesRead in
        guard let opaque, let buffer, let bytesRead else { return -1 }
        bytesRead.pointee = 0
        let state = Unmanaged<State>.fromOpaque(opaque).takeUnretainedValue()
        do {
            guard let read = state.read, let authorize = state.authorize, (1...65_536).contains(capacity) else {
                throw AudioFlacDecodeError.invalidNativeResult
            }
            try Task.checkCancellation(); try authorize()
            let data = try read(offset, capacity)
            try Task.checkCancellation(); try authorize()
            guard data.count == capacity else { throw AudioFlacDecodeError.invalidNativeResult }
            data.copyBytes(to: buffer, count: capacity)
            bytesRead.pointee = data.count
            return 0
        } catch { state.callbackFailure = error; return -1 }
    }

    private static let cancelCallback: SBFLACIsCancelled = { opaque in
        guard let opaque else { return 1 }
        let state = Unmanaged<State>.fromOpaque(opaque).takeUnretainedValue()
        if state.callbackFailure != nil { return 1 }
        do {
            guard let authorize = state.authorize else { throw AudioFlacDecodeError.invalidNativeResult }
            try Task.checkCancellation(); try authorize()
            return 0
        } catch { state.callbackFailure = error; return 1 }
    }
}
#endif
