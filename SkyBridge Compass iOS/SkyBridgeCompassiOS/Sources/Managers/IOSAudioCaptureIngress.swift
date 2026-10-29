import Foundation
import CoreMedia
import os
import SkyBridgeProtocolCore

enum IOSAudioCaptureError: Error, Equatable, Sendable {
    case unavailable, busy, alreadyStarted, invalidState, invalidLimits
    case cancelled, timedOut, cleanupPending, duplicateConsumer, overflow, alreadyBound
    case unexpectedSelection, unexpectedStream, nativeStopped, concurrentProducer
    case notAdmitted, formatUnavailable, formatMismatch
}

/// The native callback never dispatches a CMSampleBuffer to another executor.
/// It copies synchronously into this bounded owner. There is at most one waiting
/// consumer; a failure discards queued samples and cannot turn into a clean EOF.
final class IOSAudioCaptureIngress: Sendable {
    enum Admission: Equatable, Sendable { case awaitingReceiver, streamFromFirstBuffer }
    struct Limits: Sendable {
        var bytes = 1_048_576
        var blocks = 64
        func validate() throws {
            guard bytes > 0, bytes <= 4_194_304, blocks > 0, blocks <= 64 else {
                throw IOSAudioCaptureError.invalidLimits
            }
        }
    }
    struct Snapshot: Sendable {
        let bufferedBytes: Int
        let bufferedBlocks: Int
        let frames: UInt64
        let sealed: Bool
        let failed: Bool
        let waiting: Bool
        let format: AudioStreamingPCMFormat?
        let preparationFrames: UInt64
        let isTransmitting: Bool
    }
    private struct State: Sendable {
        var owner: ObjectIdentifier?
        var sequence: IOSCapturedPCMSequence
        var blocks: [IOSCapturedPCMSequence.Chunk] = []
        var bytes = 0
        var sealed = false
        var failure: (any Error)?
        var waiter: CheckedContinuation<IOSCapturedPCMSequence.Chunk?, Error>?
        var failureHandler: (@Sendable (any Error) -> Void)?
        var producer: UUID?
        var reader: UUID?
        var transmitting: Bool
        var format: AudioStreamingPCMFormat?
        var preparationFrames: UInt64 = 0
    }
    private struct FailureDelivery: Sendable {
        let error: any Error
        let waiter: CheckedContinuation<IOSCapturedPCMSequence.Chunk?, Error>?
        let handler: (@Sendable (any Error) -> Void)?
        func deliver() { waiter?.resume(throwing: error); handler?(error) }
    }
    private enum Reservation: Sendable {
        case ignored, failed(FailureDelivery), copy(UUID, IOSCapturedPCMSequence, Bool)
    }
    private enum Delivery: Sendable {
        case none, failed(FailureDelivery)
        case block(CheckedContinuation<IOSCapturedPCMSequence.Chunk?, Error>, IOSCapturedPCMSequence.Chunk)
    }
    private let state: OSAllocatedUnfairLock<State>
    private let limits: Limits
    private let profile: IOSScreenCaptureAudioProfile
    private let maximumTimestampDeviation: CMTime

    init(profile: IOSScreenCaptureAudioProfile, admission: Admission,
         maximumTimestampDeviation: CMTime = .zero,
         limits: Limits = Limits()) throws {
        try limits.validate()
        self.limits = limits; self.profile = profile
        self.maximumTimestampDeviation = maximumTimestampDeviation
        state = OSAllocatedUnfairLock(initialState: State(sequence: .init(profile: profile,
            maximumTimestampDeviation: maximumTimestampDeviation), transmitting: admission == .streamFromFirstBuffer))
    }

    var snapshot: Snapshot {
        state.withLock { Snapshot(bufferedBytes: $0.bytes, bufferedBlocks: $0.blocks.count,
            frames: $0.sequence.frames, sealed: $0.sealed, failed: $0.failure != nil, waiting: $0.waiter != nil,
            format: $0.format, preparationFrames: $0.preparationFrames, isTransmitting: $0.transmitting) }
    }

    /// Preparation never queues or transmits audio. Admission establishes one
    /// explicit stream boundary: callbacks reserved before it stay preparation,
    /// even if their copy finishes later. The first later callback starts at zero.
    func beginTransmission(expectedFormat: AudioStreamingPCMFormat) throws {
        try state.withLock {
            if let failure = $0.failure { throw failure }
            guard !$0.transmitting, !$0.sealed, $0.owner != nil else { throw IOSAudioCaptureError.invalidState }
            guard let format = $0.format else { throw IOSAudioCaptureError.formatUnavailable }
            guard format == expectedFormat else { throw IOSAudioCaptureError.formatMismatch }
            $0.transmitting = true
        }
    }

    func belongs(to owner: ObjectIdentifier) -> Bool { state.withLock { $0.owner == owner } }

    func requireHealthy() throws { try state.withLock { if let failure = $0.failure { throw failure } } }

    func retireOwner() { state.withLock { $0.owner = nil } }

    /// A delayed delegate callback cannot fail the successfully retired source.
    @discardableResult
    func reportNativeStop(_ error: any Error, from owner: ObjectIdentifier) -> Bool {
        let result = state.withLock { value -> (Bool, FailureDelivery?) in
            guard value.owner == owner else { return (false, nil) }
            return (true, Self.fail(error, state: &value))
        }
        result.1?.deliver()
        return result.0
    }

    func installFailureHandler(_ handler: @escaping @Sendable (any Error) -> Void) throws {
        let failure = try state.withLock { value -> (any Error)? in
            guard value.failureHandler == nil else { throw IOSAudioCaptureError.alreadyBound }
            value.failureHandler = handler
            return value.failure
        }
        if let failure { handler(failure) }
    }

    func bind(_ owner: ObjectIdentifier) throws {
        try state.withLock {
            guard $0.owner == nil, !$0.sealed, $0.failure == nil else { throw IOSAudioCaptureError.alreadyBound }
            $0.owner = owner
        }
    }

    /// Reserve the serial producer, copy on this same callback stack, then
    /// recheck ownership before publication. Raw CoreMedia objects never enter a
    /// Sendable lock closure. Stop can invalidate an in-progress copy.
    func receive(_ sample: CMSampleBuffer, from owner: ObjectIdentifier) {
        let reservation = state.withLock { value -> Reservation in
            guard value.owner == owner, !value.sealed, value.failure == nil else { return .ignored }
            guard value.producer == nil else {
                if let failure = Self.fail(IOSAudioCaptureError.concurrentProducer, state: &value) { return .failed(failure) }
                return .ignored
            }
            let id = UUID(); value.producer = id
            return .copy(id, value.sequence, value.transmitting)
        }
        let id: UUID
        let transmitting: Bool
        var sequence: IOSCapturedPCMSequence
        switch reservation {
        case .ignored: return
        case .failed(let failure): failure.deliver(); return
        case .copy(let token, let initial, let admitted): id = token; sequence = initial; transmitting = admitted
        }
        let result = Result {
            if transmitting { return try sequence.consume(sample) }
            let block = try IOSCapturedPCMBlock.copy(from: sample, profile: profile,
                maximumTimestampDeviation: maximumTimestampDeviation)
            return IOSCapturedPCMSequence.Chunk(block: block, frameOffset: 0)
        }
        let completedSequence = sequence
        let delivery = state.withLock { value -> Delivery in
            guard value.producer == id else { return .none }
            value.producer = nil
            guard value.owner == owner, !value.sealed, value.failure == nil else { return .none }
            do {
                let block = try result.get()
                if let format = value.format, format != block.block.format { throw IOSAudioCaptureError.formatMismatch }
                value.format = block.block.format
                if !transmitting {
                    let next = value.preparationFrames.addingReportingOverflow(block.block.frameCount)
                    guard !next.overflow, next.partialValue <= AudioStreamingWire.maximumCounter else {
                        throw IOSCapturedPCMError.counterOverflow
                    }
                    value.preparationFrames = next.partialValue
                    return .none
                }
                value.sequence = completedSequence
                if let waiter = value.waiter {
                    value.waiter = nil
                    return .block(waiter, block)
                } else {
                    guard value.blocks.count < limits.blocks, block.block.bytes.count <= limits.bytes - value.bytes else {
                        throw IOSAudioCaptureError.overflow
                    }
                    value.blocks.append(block); value.bytes += block.block.bytes.count
                }
                return .none
            } catch {
                if let failure = Self.fail(error, state: &value) { return .failed(failure) }
                return .none
            }
        }
        switch delivery {
        case .none: break
        case .failed(let failure): failure.deliver()
        case .block(let waiter, let block): waiter.resume(returning: block)
        }
    }

    func next(isolation: isolated (any Actor)? = #isolation) async throws -> IOSCapturedPCMSequence.Chunk? {
        let id = UUID()
        try state.withLock {
            if let failure = $0.failure { throw failure }
            guard $0.transmitting else { throw IOSAudioCaptureError.notAdmitted }
            guard $0.reader == nil else { throw IOSAudioCaptureError.duplicateConsumer }
            $0.reader = id
        }
        defer { state.withLock { if $0.reader == id { $0.reader = nil } } }
        return try await withTaskCancellationHandler {
            if Task.isCancelled { abortRead(id) }
            let block: IOSCapturedPCMSequence.Chunk? = try await withCheckedThrowingContinuation { continuation in
                let immediate = state.withLock { value -> Result<IOSCapturedPCMSequence.Chunk?, Error>? in
                    if let failure = value.failure { return .failure(failure) }
                    guard value.waiter == nil else { return .failure(IOSAudioCaptureError.duplicateConsumer) }
                    if !value.blocks.isEmpty {
                        let block = value.blocks.removeFirst(); value.bytes -= block.block.bytes.count
                        return .success(block)
                    }
                    if value.sealed { return .success(nil) }
                    value.waiter = continuation
                    return nil
                }
                if let immediate { continuation.resume(with: immediate) }
            }
            try requireHealthy()
            return block
        } onCancel: { self.abortRead(id) }
    }

    private func abortRead(_ id: UUID) {
        state.withLock { value -> FailureDelivery? in
            guard value.reader == id else { return nil }
            return Self.fail(IOSAudioCaptureError.cancelled, state: &value)
        }?.deliver()
    }

    /// Called after native stop and the serial callback queue barrier. Successful
    /// stop preserves accepted data for draining; failure/cancellation does not.
    func seal() {
        let waiter = state.withLock { value -> CheckedContinuation<IOSCapturedPCMSequence.Chunk?, Error>? in
            guard value.failure == nil, !value.sealed else { return nil }
            value.sealed = true
            let waiter = value.waiter; value.waiter = nil
            return waiter
        }
        waiter?.resume(returning: nil)
    }

    func abort(_ error: any Error) { state.withLock { Self.fail(error, state: &$0) }?.deliver() }

    private static func fail(_ error: any Error, state: inout State) -> FailureDelivery? {
        guard state.failure == nil else { return nil }
        state.failure = error; state.sealed = true
        state.blocks.removeAll(keepingCapacity: false); state.bytes = 0
        let waiter = state.waiter; state.waiter = nil
        return FailureDelivery(error: error, waiter: waiter, handler: state.failureHandler)
    }
}
