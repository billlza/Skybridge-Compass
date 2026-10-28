import CSkyBridgeALAC
import Foundation
import SkyBridgeProtocolCore
import os

public enum AudioAlacDecodeError: Error, Equatable, Sendable {
    case invalidMetadata, invalidNativeResult, concurrentRead, closed
    case native(status: UInt32, codecError: Int32)

    /// Source/decoded-content contradictions, separate from allocation, provider and owner faults.
    public var isContentMismatch: Bool {
        guard case .native(let status, _) = self else { return false }
        switch status {
        case SBALAC_CODEC_ERROR.rawValue, SBALAC_MISSING_FRAME.rawValue, SBALAC_FORMAT_CHANGED.rawValue,
             SBALAC_FRAME_COUNT_MISMATCH.rawValue, SBALAC_EXTRA_OUTPUT.rawValue, SBALAC_SAMPLE_RANGE_ERROR.rawValue:
            return true
        default: return false
        }
    }
}

public struct AudioAlacDecodeReceipt: Equatable, Sendable {
    public let sourceFrames: UInt64
    public let packets: UInt64
    /// Indexed compressed payload bytes, not the entire M4A container length.
    public let encodedAudioBytes: UInt64
}

public enum AudioAlacDecodeStep: Sendable {
    case frame(firstIndex: UInt64, frameCount: UInt32, bytes: Data)
    case complete(AudioAlacDecodeReceipt)
}

/// Sequential, bounded ALAC decoding over the same held reader that produced the packet index.
/// A decoded prefix is not a validated file or playback permission. The transfer owner retains
/// the reader; this owner closes only its native decoder. No path is reopened or PCM converted.
public final class AudioAlacPCMDecoder: Sendable {
    public let metadata: AudioAlacMetadata
    private let reader: PreparedOutboundFileReadSession
    private let capacity: Int
    private struct CallState { var thread: ObjectIdentifier?; var closing = false; var consuming = false }
    private let calls = OSAllocatedUnfairLock(initialState: CallState())
    // Native pointers/callbacks are touched only inside this lock. The C callback is synchronous
    // and does not reacquire it. A reentrant close sets the separate short flag and defers free.
    private let state: OSAllocatedUnfairLock<State>

    private final class State {
        var decoder: OpaquePointer?
        var cursor: AudioAlacPacketCursor
        var authorize: (() throws -> Void)?
        var callbackFailure: (any Error)?
        var failure: (any Error)?
        var frames: UInt64 = 0
        var packets: UInt64 = 0
        var encodedBytes: UInt64 = 0
        var receipt: AudioAlacDecodeReceipt?
        init(_ decoder: OpaquePointer, _ cursor: AudioAlacPacketCursor) { self.decoder = decoder; self.cursor = cursor }
        func release() { if let decoder { sbalac_decoder_destroy(decoder); self.decoder = nil } }
        deinit { release() }
    }

    public init(file: AudioIndexedAlacFile) throws {
        let metadata = file.metadata
        let capacity = Int(metadata.maximumFramesPerPacket) * Int(metadata.decodedFormat.bytesPerFrame)
        guard metadata.configuration.count == 24, metadata.totalFrames > 0, metadata.packetCount > 0,
              metadata.encodedAudioBytes > 0, (1...524_288).contains(capacity) else {
            throw AudioAlacDecodeError.invalidMetadata
        }
        var description = SBALACSourceDescription()
        description.total_frames = metadata.totalFrames
        description.packet_count = metadata.packetCount
        withUnsafeMutableBytes(of: &description.configuration) { $0.copyBytes(from: metadata.configuration) }
        var native: OpaquePointer?
        var result = SBALACResult()
        let status = sbalac_decoder_create(&description, &native, &result)
        guard status == SBALAC_READY, let native else {
            if let native { sbalac_decoder_destroy(native) }
            throw AudioAlacDecodeError.native(status: status.rawValue, codecError: result.codec_error)
        }
        guard result.status == status, result.codec_error == 0 else {
            sbalac_decoder_destroy(native)
            throw AudioAlacDecodeError.invalidNativeResult
        }
        reader = file.reader; self.metadata = metadata; self.capacity = capacity
        state = OSAllocatedUnfairLock(uncheckedState: State(native, metadata.makePacketCursor()))
    }

    public func next(requireAuthorization: @escaping @Sendable () throws -> Void) async throws -> AudioAlacDecodeStep {
        try calls.withLock { call in
            guard !call.closing else { throw AudioAlacDecodeError.closed }
            guard !call.consuming else { throw AudioAlacDecodeError.concurrentRead }
            call.consuming = true
        }
        defer { calls.withLock { $0.consuming = false } }
        let check: @Sendable () throws -> Void = { try self.requireCurrent(requireAuthorization) }
        do {
            try check()
            let result = try await reader.withSynchronousVerifiedReads { read, validateSource in
                try self.step(read: read, validateSource: validateSource, check: check)
            }
            // The caller may resume on another executor after the borrowed reader scope ended.
            try check()
            return result
        } catch {
            state.withLockUnchecked { state in
                if state.failure == nil { state.failure = error }
                state.release()
            }
            throw error
        }
    }

    public func close() {
        let thread = ObjectIdentifier(Thread.current)
        let deferred = calls.withLock { call in call.closing = true; return call.thread == thread }
        if !deferred { state.withLockUnchecked { $0.release() } }
    }

    private func requireCurrent(_ authorize: @Sendable () throws -> Void) throws {
        try Task.checkCancellation()
        guard !calls.withLock({ $0.closing }) else { throw AudioAlacDecodeError.closed }
        try authorize()
        try Task.checkCancellation()
        guard !calls.withLock({ $0.closing }) else { throw AudioAlacDecodeError.closed }
    }

    private func step(read: (UInt64, Int) throws -> Data, validateSource: () throws -> Void,
                      check: @Sendable () throws -> Void) throws -> AudioAlacDecodeStep {
        try state.withLockUnchecked { state in
            if let failure = state.failure { throw failure }
            guard let native = state.decoder else { throw AudioAlacDecodeError.closed }
            calls.withLock { $0.thread = ObjectIdentifier(Thread.current) }
            defer {
                let closing = calls.withLock { call in call.thread = nil; return call.closing }
                if closing { state.release() }
            }
            do {
                try validateSource(); try check()
                if let receipt = state.receipt { return .complete(receipt) }
                let packet = try state.cursor.next(read: read, requireCurrent: check)
                let bytes: Data
                if let packet {
                    guard packet.index == state.packets, packet.firstFrameIndex == state.frames else {
                        throw AudioAlacDecodeError.invalidNativeResult
                    }
                    bytes = try read(packet.byteOffset, packet.byteCount)
                    guard bytes.count == packet.byteCount else { throw AudioAlacDecodeError.invalidNativeResult }
                } else { bytes = Data() } // No packet is the index's exact EOF, not a read-error fallback.
                try validateSource(); try check()
                guard state.authorize == nil else { throw AudioAlacDecodeError.invalidNativeResult }
                return try withoutActuallyEscaping(check) { borrowed in
                    state.authorize = borrowed; state.callbackFailure = nil
                    defer { state.authorize = nil; state.callbackFailure = nil }
                    var control = SBALACControl(context: Unmanaged.passUnretained(state).toOpaque(), is_cancelled: Self.cancelCallback)
                    var result = SBALACResult()
                    var output = Data(count: packet == nil ? 0 : capacity)
                    let status: SBALACStatus
                    if let packet {
                        status = try bytes.withUnsafeBytes { input in
                            try output.withUnsafeMutableBytes { output in
                                guard let compressed = input.bindMemory(to: UInt8.self).baseAddress,
                                      let pcm = output.bindMemory(to: UInt8.self).baseAddress else {
                                    throw AudioAlacDecodeError.invalidNativeResult
                                }
                                return sbalac_decoder_decode(native, &control, packet.index, packet.firstFrameIndex,
                                    compressed, input.count, packet.frameCount, pcm, output.count, &result)
                            }
                        }
                    } else { status = sbalac_decoder_finish(native, &control, &result) }
                    if let failure = state.callbackFailure { throw failure }
                    try validateSource(); try check()
                    guard status == (packet == nil ? SBALAC_COMPLETE : SBALAC_FRAME) else {
                        throw AudioAlacDecodeError.native(status: status.rawValue, codecError: result.codec_error)
                    }
                    guard result.status == status, result.codec_error == 0 else { throw AudioAlacDecodeError.invalidNativeResult }
                    if let packet {
                        guard result.packet_index == packet.index, result.first_frame_index == packet.firstFrameIndex,
                              result.frame_count == packet.frameCount, result.decoded_frames == state.frames + UInt64(packet.frameCount),
                              result.decoded_packets == state.packets + 1,
                              result.byte_count == Int(packet.frameCount) * Int(metadata.decodedFormat.bytesPerFrame),
                              result.byte_count <= output.count,
                              UInt64(packet.byteCount) <= metadata.encodedAudioBytes - state.encodedBytes else {
                            throw AudioAlacDecodeError.invalidNativeResult
                        }
                        output.count = result.byte_count
                        state.frames = result.decoded_frames; state.packets = result.decoded_packets
                        state.encodedBytes += UInt64(packet.byteCount)
                        return .frame(firstIndex: packet.firstFrameIndex, frameCount: packet.frameCount, bytes: output)
                    }
                    guard result.byte_count == 0, result.frame_count == 0,
                          result.decoded_frames == metadata.totalFrames, state.frames == metadata.totalFrames,
                          result.decoded_packets == metadata.packetCount, state.packets == metadata.packetCount,
                          state.encodedBytes == metadata.encodedAudioBytes else { throw AudioAlacDecodeError.invalidNativeResult }
                    let receipt = AudioAlacDecodeReceipt(sourceFrames: state.frames, packets: state.packets,
                                                        encodedAudioBytes: state.encodedBytes)
                    state.receipt = receipt
                    return .complete(receipt)
                }
            } catch {
                state.failure = error; state.release()
                throw error
            }
        }
    }

    private static let cancelCallback: SBALACIsCancelled = { opaque in
        guard let opaque else { return 1 }
        let state = Unmanaged<State>.fromOpaque(opaque).takeUnretainedValue()
        if state.callbackFailure != nil { return 1 }
        do {
            guard let authorize = state.authorize else { throw AudioAlacDecodeError.invalidNativeResult }
            try authorize()
            return 0
        } catch { state.callbackFailure = error; return 1 }
    }
}
