import Foundation
import Network
import os
import SkyBridgeProtocolCore
import SkyBridgeAppleTransport

enum ClassicFileTransferByteError: Error, Equatable, Sendable {
    case operationInProgress, cleanupUnconfirmed, invalidCarrier
}

/// One file byte owner. Identity and playback grants remain outside this transport.
/// A non-IP route cannot be projected into general network/resume reception.
protocol ClassicFileTransferByteChannel: AnyObject, Sendable {
    var identity: ObjectIdentifier { get }
    var networkConnection: NWConnection? { get }
    func send(_ data: Data, requireEffectAuthorization: @escaping @Sendable () throws -> Void) async throws
    func receive(length: Int, timeout: TimeInterval?, zeroByteDisconnectError: FileTransferError?) async throws -> Data
    func cancel()
    /// Normal file completion. Logical carriers exchange both FIN directions before abort-style
    /// cleanup can discard queued receipt bytes. This is transport settlement, not a file MAC.
    func completeAndClose(timeout: Duration) async throws
    func closeAndAwait(timeout: Duration) async throws
}

private final class ClassicFileByteState: Sendable {
    private struct State: Sendable {
        var reading = false, writing = false
        var nativeCallbacks = 0
        var failure: (any Error)?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    func begin(reading: Bool) throws {
        try state.withLock {
            if let failure = $0.failure { throw failure }
            guard reading ? !$0.reading : !$0.writing else { throw ClassicFileTransferByteError.operationInProgress }
            if reading { $0.reading = true } else { $0.writing = true }
        }
    }
    func end(reading: Bool) { state.withLock { if reading { $0.reading = false } else { $0.writing = false } } }
    func requireCurrent() throws { try state.withLock { if let failure = $0.failure { throw failure } } }
    @discardableResult func fail(_ error: any Error) -> any Error {
        state.withLock { if $0.failure == nil { $0.failure = error }; return $0.failure ?? error }
    }
    func beginNativeCallback() throws {
        try state.withLock { if let failure = $0.failure { throw failure }; $0.nativeCallbacks += 1 }
    }
    func endNativeCallback() { state.withLock { $0.nativeCallbacks -= 1 } }
    var idle: Bool { state.withLock { !$0.reading && !$0.writing && $0.nativeCallbacks == 0 } }
}

/// Reuses the existing Network.framework byte-operation contracts, retaining native callbacks
/// separately from logical cancellation so an early continuation cannot prove cleanup.
final class NetworkClassicFileTransferByteChannel: ClassicFileTransferByteChannel {
    let connection: NWConnection
    private let state = ClassicFileByteState()
    private let completionCloseRequested = OSAllocatedUnfairLock(initialState: false)
    init(_ connection: NWConnection) { self.connection = connection }
    var identity: ObjectIdentifier { ObjectIdentifier(connection) }
    var networkConnection: NWConnection? { connection }
    /// Only the file consumer can mark settlement after its authenticated receipt write.
    /// The listener must not cancel that consumer when this exact local close is observed.
    var isClosingAfterCompletion: Bool { completionCloseRequested.withLock { $0 } }
    func cancel() { retire(FileTransferError.transferCancelled) }
    private func retire(_ error: any Error) { state.fail(error); connection.cancel() }

    func send(_ data: Data, requireEffectAuthorization: @escaping @Sendable () throws -> Void) async throws {
        guard (1...2_000_008).contains(data.count) else { throw FileTransferError.invalidHeader }
        try state.begin(reading: false)
        defer { state.end(reading: false) }
        let operation = ClassicTransferSendOperation()
        let timeoutTask = Task.detached { [self] in
            do { try await Task.sleep(for: .seconds(ClassicTransferInboundPolicy.frameSendTimeoutSeconds)) }
            catch is CancellationError { return }
            catch { if operation.fail(error) { retire(error) }; return }
            if operation.fail(FileTransferError.timeout) { retire(FileTransferError.timeout) }
        }
        defer { timeoutTask.cancel() }
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    operation.install(continuation)
                    guard !operation.isCompleted else { return }
                    do {
                        try requireEffectAuthorization()
                        try state.beginNativeCallback()
                    } catch { _ = operation.fail(error); return }
                    connection.send(content: data, completion: .contentProcessed { [self] error in
                        defer { state.endNativeCallback() }
                        if let error { if operation.fail(error) { retire(error) } }
                        else { _ = operation.succeed() }
                    })
                }
            } onCancel: {
                if operation.fail(FileTransferError.transferCancelled) { self.retire(FileTransferError.transferCancelled) }
            }
            try state.requireCurrent()
        } catch { retire(error); throw state.fail(error) }
    }

    func receive(length: Int, timeout: TimeInterval?, zeroByteDisconnectError: FileTransferError?) async throws -> Data {
        guard (0...2_000_000).contains(length) else { throw FileTransferError.invalidHeader }
        try state.begin(reading: true)
        defer { state.end(reading: true) }
        let operation = ClassicTransferReceiveOperation(expectedLength: length)
        let timer: Task<Void, Never>?
        if let timeout, timeout > 0 {
            timer = Task.detached { [self] in
                do { try await Task.sleep(for: .seconds(timeout)) }
                catch is CancellationError { return }
                catch { if operation.fail(error) { retire(error) }; return }
                if operation.fail(FileTransferError.timeout) { retire(FileTransferError.timeout) }
            }
        } else { timer = nil }
        defer { timer?.cancel() }
        do {
            let bytes: Data = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    operation.install(continuation)
                    guard !operation.isCompleted else { return }
                    @Sendable func mapped(_ error: any Error) -> any Error {
                        if operation.receivedByteCount == 0, let zeroByteDisconnectError,
                           ClassicTransferPeerResolutionPolicy.isInboundPreMetadataDisconnect(error) { return zeroByteDisconnectError }
                        return error
                    }
                    @Sendable func receiveMore() {
                        guard let remaining = operation.remainingLength(), remaining > 0 else { return }
                        do { try self.state.beginNativeCallback() }
                        catch { _ = operation.fail(error); return }
                        self.connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { [self] data, _, complete, error in
                            defer { state.endNativeCallback() }
                            guard !operation.isCompleted else { return }
                            if let error { _ = operation.fail(mapped(error)); return }
                            if let data, !data.isEmpty {
                                switch operation.append(data) {
                                case .completed, .ignoredAfterCompletion: return
                                case .overflow:
                                    if operation.fail(FileTransferError.invalidHeader) { retire(FileTransferError.invalidHeader) }
                                    return
                                case .pending: break
                                }
                            }
                            if complete { _ = operation.fail(mapped(FileTransferError.connectionClosed)); return }
                            guard !operation.isCompleted else { return }
                            receiveMore()
                        }
                    }
                    receiveMore()
                }
            } onCancel: {
                if operation.fail(CancellationError()) { self.retire(CancellationError()) }
            }
            try state.requireCurrent()
            return bytes
        } catch { retire(error); throw state.fail(error) }
    }

    func completeAndClose(timeout: Duration) async throws {
        // Preserve the existing single-file TCP lifetime; its socket close is owned by Network.
        guard timeout > .zero && timeout <= .seconds(60) else { throw FileTransferError.timeout }
        try Task.checkCancellation()
        try state.requireCurrent()
        guard case .ready = connection.state else { throw FileTransferError.connectionClosed }
        completionCloseRequested.withLock { $0 = true }
        try await closeAndAwait(timeout: timeout)
    }

    func closeAndAwait(timeout: Duration) async throws {
        guard timeout > .zero && timeout <= .seconds(60) else { throw FileTransferError.timeout }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        cancel()
        let observer = Task.detached { [self] in
            while true {
                if state.idle, case .cancelled = connection.state { return }
                guard ContinuousClock.now < deadline else { throw ClassicFileTransferByteError.cleanupUnconfirmed }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        try await observer.value
    }
}

#if os(macOS)
/// The dispatcher must supply one admitted stream from the exact v2/MAIN owner. This adapter
/// grants no identity or audio authority and never dials a network endpoint or reopens USB.
final class USBClassicFileTransferByteChannel: ClassicFileTransferByteChannel {
    private let stream: USBHostMultiplexConnection.Stream
    private let requireParentCurrent: @Sendable () throws -> Void
    private let requireParentWriteAuthorization: @Sendable () throws -> Void
    private let state = ClassicFileByteState()
    var identity: ObjectIdentifier { ObjectIdentifier(stream) }
    var networkConnection: NWConnection? { nil }

    init(connection: USBHostMultiplexConnection, stream: USBHostMultiplexConnection.Stream,
         requireParentCurrent: @escaping @Sendable () throws -> Void,
         requireParentWriteAuthorization: @escaping @Sendable () throws -> Void) throws {
        guard stream.belongs(to: connection), connection.terminalFailure == nil,
              connection.epochSnapshot?.phase == .ready, !stream.isClosed else { throw ClassicFileTransferByteError.invalidCarrier }
        try requireParentCurrent()
        self.stream = stream; self.requireParentCurrent = requireParentCurrent
        self.requireParentWriteAuthorization = requireParentWriteAuthorization
    }

    func cancel() { state.fail(FileTransferError.transferCancelled); stream.close() }

    func send(_ data: Data, requireEffectAuthorization: @escaping @Sendable () throws -> Void) async throws {
        try state.begin(reading: false)
        defer { state.end(reading: false) }
        do {
            try requireParentCurrent()
            try await stream.writeBytes(data, timeout: .seconds(ClassicTransferInboundPolicy.frameSendTimeoutSeconds)) { [self] in
                try state.requireCurrent()
                try requireParentWriteAuthorization()
                try requireEffectAuthorization()
            }
            try state.requireCurrent(); try requireParentCurrent()
        } catch { let first = state.fail(error); stream.close(); throw first }
    }

    func receive(length: Int, timeout: TimeInterval?, zeroByteDisconnectError: FileTransferError?) async throws -> Data {
        guard (0...2_000_000).contains(length) else { throw FileTransferError.invalidHeader }
        let seconds = timeout ?? ClassicTransferInboundPolicy.frameIdleTimeoutSeconds
        guard seconds.isFinite, seconds > 0, seconds <= 120 else { throw FileTransferError.timeout }
        try state.begin(reading: true)
        defer { state.end(reading: true) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        do {
            var bytes = Data(); bytes.reserveCapacity(length)
            try requireParentCurrent(); try state.requireCurrent()
            while bytes.count < length {
                let remaining = ContinuousClock.now.duration(to: deadline)
                guard remaining > .zero else { throw FileTransferError.timeout }
                try Task.checkCancellation(); try requireParentCurrent(); try state.requireCurrent()
                switch try await stream.readBytes(maximumBytes: min(length - bytes.count, USBLogicalStreamWire.initialWindow), timeout: remaining) {
                case .bytes(let next): bytes.append(next)
                case .end: throw bytes.isEmpty ? (zeroByteDisconnectError ?? .connectionClosed) : .connectionClosed
                }
            }
            try state.requireCurrent(); try requireParentCurrent()
            return bytes
        } catch { let first = state.fail(error); stream.close(); throw first }
    }

    func completeAndClose(timeout: Duration) async throws {
        guard timeout > .zero && timeout <= .seconds(60) else { throw FileTransferError.timeout }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        func remaining() throws -> Duration {
            let value = ContinuousClock.now.duration(to: deadline)
            guard value > .zero else { throw FileTransferError.timeout }
            return value
        }
        try state.begin(reading: false)
        do { try state.begin(reading: true) }
        catch { state.end(reading: false); throw error }
        do {
            try requireParentCurrent(); try state.requireCurrent()
            try await stream.finishSending(timeout: remaining())
            guard case .end = try await stream.readBytes(maximumBytes: 1, timeout: remaining()) else {
                throw FileTransferError.invalidHeader
            }
            try requireParentCurrent(); try state.requireCurrent()
        } catch {
            state.end(reading: true); state.end(reading: false)
            let first = state.fail(error); stream.close(); throw first
        }
        state.end(reading: true); state.end(reading: false)
        try await closeAndAwait(timeout: remaining())
    }

    func closeAndAwait(timeout: Duration) async throws {
        guard timeout > .zero && timeout <= .seconds(60) else { throw FileTransferError.timeout }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        cancel()
        let observer = Task.detached { [self] in
            while !state.idle {
                guard ContinuousClock.now < deadline else { throw ClassicFileTransferByteError.cleanupUnconfirmed }
                try await Task.sleep(for: .milliseconds(5))
            }
            try await stream.closeAndAwait(timeout: ContinuousClock.now.duration(to: deadline))
        }
        try await observer.value
    }
}
#endif
