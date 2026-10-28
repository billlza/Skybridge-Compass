import Foundation
import os

public enum AudioStreamingChannelError: Error, Equatable, Sendable {
    case unavailable, staleOwner, alreadyRegistered, closed, queueOverflow
    case unsupportedPeer, unexpectedStream, offerRequired, duplicateConsumer, epochCapacity
    case sendInProgress, timedOut, fileTransferMismatch
    case peerStopped(AudioStreamingStopReason)
}

/// All operations are nonblocking. At most eight complete SBAU messages are
/// retained (under 96 KiB of wire payload); overflow terminates this audio stream.
public final class AudioStreamingMailbox: Sendable {
    private struct State: Sendable {
        var failure: AudioStreamingChannelError?
        var streamID: UUID?
        var consumerClaimed = false
        var pendingSend: AudioStreamingSendCompletion?
        var bluetooth: AudioBluetoothNegotiation?
        var receivedStop: AudioStreamingStopReason?
    }
    public let id = UUID()
    public let stream: AsyncThrowingStream<AudioStreamingMessage, Error>
    private let continuation: AsyncThrowingStream<AudioStreamingMessage, Error>.Continuation
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {
        let pair = AsyncThrowingStream<AudioStreamingMessage, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(8)
        )
        stream = pair.stream
        continuation = pair.continuation
    }

    public var streamID: UUID? { state.withLock { $0.streamID } }
    public var isTerminal: Bool { state.withLock { $0.failure != nil } }

    public func claimConsumer() -> Bool {
        state.withLock {
            guard !$0.consumerClaimed else { return false }
            $0.consumerClaimed = true
            return true
        }
    }

    public func requireActive() throws {
        try state.withLock { if let failure = $0.failure { throw failure } }
    }

    public func prepareSend(_ message: AudioStreamingMessage, peerCapabilities: Set<String>,
                     completion: AudioStreamingSendCompletion) throws {
        switch message.body {
        case .fileOffer:
            guard peerCapabilities.contains(AudioStreamingWire.fileReceiveCapability) else {
                throw AudioStreamingChannelError.unsupportedPeer
            }
        case .captureOffer:
            guard peerCapabilities.contains(AudioStreamingWire.captureReceiveCapability) else {
                throw AudioStreamingChannelError.unsupportedPeer
            }
        case .opusOffer:
            guard peerCapabilities.contains(AudioStreamingWire.opusReceiveCapability),
                  peerCapabilities.contains(AudioStreamingWire.bluetoothAttachmentCapability) else {
                throw AudioStreamingChannelError.unsupportedPeer
            }
        case .bufferedOpusFileOffer:
            guard peerCapabilities.contains(AudioStreamingWire.opusReceiveCapability),
                  peerCapabilities.contains(AudioStreamingWire.bluetoothAttachmentCapability),
                  peerCapabilities.contains(AudioStreamingWire.bufferedOpusFileReceiveCapability) else {
                throw AudioStreamingChannelError.unsupportedPeer
            }
        case .usbFileRoute:
            guard peerCapabilities.contains(AudioStreamingWire.usbFileReceiveCapability),
                  peerCapabilities.contains("classic_approval_v1") else {
                throw AudioStreamingChannelError.unsupportedPeer
            }
        case .fileOutputProgress:
            guard peerCapabilities.contains(AudioStreamingWire.fileOutputProgressReceiveCapability) else {
                throw AudioStreamingChannelError.unsupportedPeer
            }
        default: break
        }
        try state.withLock {
            guard $0.pendingSend == nil else { throw AudioStreamingChannelError.sendInProgress }
            try Self.bind(message, incoming: false, state: &$0)
            $0.pendingSend = completion
        }
    }

    public func finishSend(_ completion: AudioStreamingSendCompletion) {
        state.withLock { if $0.pendingSend === completion { $0.pendingSend = nil } }
    }

    public func commitSent(_ message: AudioStreamingMessage) throws {
        try state.withLock {
            if let failure = $0.failure { throw failure }
            // A peer may refuse the offer before the native write completion
            // resumes its sender. Preserve that authenticated terminal reason;
            // never publish a binding for the already retired negotiation.
            if $0.bluetooth != nil, let reason = $0.receivedStop { throw AudioStreamingChannelError.peerStopped(reason) }
            try $0.bluetooth?.commitSend(message)
        }
    }

    public func takeBluetoothBinding() throws -> AudioBluetoothBinding {
        try state.withLock {
            if let failure = $0.failure { throw failure }
            guard var negotiation = $0.bluetooth else { throw AudioBluetoothAttachmentError.notReady }
            let result = try negotiation.takeBinding()
            $0.bluetooth = negotiation
            return result
        }
    }

    /// Used by the child transport's synchronous effect check. This check shares
    /// the same lock that records incoming/outgoing Stop, so queued child effects
    /// cannot survive a retired negotiation while MAIN cleanup is still pending.
    public func requireBluetoothBindingCurrent() throws {
        try state.withLock {
            if let failure = $0.failure { throw failure }
            guard let negotiation = $0.bluetooth else { throw AudioBluetoothAttachmentError.notReady }
            try negotiation.requireIssuedBindingCurrent()
        }
    }

    public func receive(_ message: AudioStreamingMessage) throws {
        try state.withLock { value in
            try Self.bind(message, incoming: true, state: &value)
            if case .stop(let reason) = message.body { value.receivedStop = reason }
            switch continuation.yield(message) {
            case .enqueued: break
            case .dropped:
                value.failure = .queueOverflow
                value.pendingSend?.finish(.failure(AudioStreamingChannelError.queueOverflow))
                continuation.finish(throwing: AudioStreamingChannelError.queueOverflow)
                throw AudioStreamingChannelError.queueOverflow
            case .terminated:
                value.failure = .closed
                throw AudioStreamingChannelError.closed
            @unknown default:
                value.failure = .closed
                continuation.finish(throwing: AudioStreamingChannelError.closed)
                throw AudioStreamingChannelError.closed
            }
        }
    }

    public func finish(_ failure: AudioStreamingChannelError) {
        state.withLock {
            guard $0.failure == nil else { return }
            $0.failure = failure
            $0.pendingSend?.finish(.failure(failure))
            $0.pendingSend = nil
            continuation.finish(throwing: failure)
        }
    }

    private static func bind(_ message: AudioStreamingMessage, incoming: Bool, state: inout State) throws {
        if let failure = state.failure { throw failure }
        if let streamID = state.streamID {
            guard message.streamID == streamID else { throw AudioStreamingChannelError.unexpectedStream }
        } else {
            switch message.body {
            case .fileOffer, .captureOffer: state.streamID = message.streamID
            case .opusOffer, .bufferedOpusFileOffer:
                state.streamID = message.streamID
                state.bluetooth = .init(role: incoming ? .sink : .source, streamID: message.streamID)
            default: throw AudioStreamingChannelError.offerRequired
            }
        }
        if state.bluetooth != nil {
            if incoming { try state.bluetooth?.receive(message) }
            else { try state.bluetooth?.prepareSend(message) }
        } else {
            switch message.body {
            case .opusOffer, .bufferedOpusFileOffer, .opusConfiguration, .opusData, .opusEnd, .opusOutputReady, .bluetoothRoute:
                throw AudioBluetoothAttachmentError.unexpectedMessage
            default: break
            }
        }
    }
}

/// Caller retirement and actual NW I/O completion are distinct. Closing audio
/// may release its waiter while an enqueued write still owns its transport deadline.
public final class AudioStreamingSendCompletion: Sendable {
    private struct State: Sendable {
        var result: Result<Void, Error>?
        var continuation: CheckedContinuation<Void, Error>?
        var submitted = false
        var ioCompleted = false
        var deadline: Task<Void, Never>?
    }
    public init() {}

    private let state = OSAllocatedUnfairLock(initialState: State())
    public var isPending: Bool { state.withLock { $0.result == nil } }

    public func markSubmitted() -> Bool {
        state.withLock {
            guard $0.result == nil, !$0.submitted else { return false }
            $0.submitted = true
            return true
        }
    }

    /// Called only after connection.send has enqueued the bounded frame.
    public func startWriteDeadline(cancelTransport: @escaping @Sendable () -> Void) {
        state.withLock {
            guard $0.submitted, !$0.ioCompleted, $0.deadline == nil else { return }
            $0.deadline = Task {
                do { try await Task.sleep(for: .seconds(5)) }
                catch is CancellationError { return }
                catch { completeWrite(.failure(error)); return }
                expireWrite(cancelTransport: cancelTransport)
            }
        }
    }

    public func completeWrite(_ result: Result<Void, Error>) {
        let outcome = state.withLock { value -> (Bool, Task<Void, Never>?) in
            guard value.submitted, !value.ioCompleted else { return (false, nil) }
            value.ioCompleted = true
            let deadline = value.deadline
            value.deadline = nil
            return (true, deadline)
        }
        guard outcome.0 else { return }
        outcome.1?.cancel()
        finish(result)
    }

    public func expireWrite(cancelTransport: @Sendable () -> Void) {
        let outcome = state.withLock { value -> (Bool, Task<Void, Never>?) in
            guard value.submitted, !value.ioCompleted else { return (false, nil) }
            value.ioCompleted = true
            let deadline = value.deadline
            value.deadline = nil
            return (true, deadline)
        }
        guard outcome.0 else { return }
        outcome.1?.cancel()
        // This closure captures the NWConnection instance, never a lookup of the
        // current peer connection. A replacement socket cannot be cancelled here.
        cancelTransport()
        finish(.failure(AudioStreamingChannelError.timedOut))
    }

    public func install(_ continuation: CheckedContinuation<Void, Error>) {
        let result = state.withLock { value -> Result<Void, Error>? in
            if let result = value.result { return result }
            value.continuation = continuation
            return nil
        }
        if let result { continuation.resume(with: result) }
    }

    @discardableResult
    public func finish(_ result: Result<Void, Error>) -> Bool {
        let outcome = state.withLock { value -> (Bool, CheckedContinuation<Void, Error>?) in
            guard value.result == nil else { return (false, nil) }
            value.result = result
            let continuation = value.continuation
            value.continuation = nil
            return (true, continuation)
        }
        outcome.1?.resume(with: result)
        return outcome.0
    }
}

public struct AudioStreamingMessages: AsyncSequence, Sendable {
    public typealias Element = AudioStreamingMessage
    let mailbox: AudioStreamingMailbox
    let validateOwner: @Sendable () throws -> Void

    public init(mailbox: AudioStreamingMailbox, validateOwner: @escaping @Sendable () throws -> Void) {
        self.mailbox = mailbox
        self.validateOwner = validateOwner
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var base: AsyncThrowingStream<Element, Error>.Iterator
        let mailbox: AudioStreamingMailbox
        let validateOwner: @Sendable () throws -> Void
        let ownsConsumer: Bool

        public mutating func next() async throws -> Element? {
            guard ownsConsumer else { throw AudioStreamingChannelError.duplicateConsumer }
            try Task.checkCancellation()
            try mailbox.requireActive()
            try validateOwner()
            let value = try await base.next()
            // AsyncThrowingStream can retain buffered elements after finish.
            // Never deliver one after cancellation, rekey or permission teardown.
            try Task.checkCancellation()
            try mailbox.requireActive()
            try validateOwner()
            return value
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: mailbox.stream.makeAsyncIterator(), mailbox: mailbox,
                      validateOwner: validateOwner, ownsConsumer: mailbox.claimConsumer())
    }
}
