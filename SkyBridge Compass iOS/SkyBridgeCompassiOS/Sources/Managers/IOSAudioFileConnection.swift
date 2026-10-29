import Foundation
import Network

enum IOSAudioFileConnectionError: Error, Equatable, Sendable {
    case alreadyAttached, closed, closeUnconfirmed, timedOut, transferSlotRequired
}

struct IOSAudioFileTransferCleanupError: Error, Sendable {
    let primary: String
    let connectionFailure: String?
    let sourceFailure: String?
}

/// The caller retains this owner until close succeeds, including after a failed
/// send. A cancellation request alone is not a native connection-close receipt.
@MainActor
final class IOSAudioFileConnection {
    private var connection: NWConnection?
    private var listener: NWListener?
    private var connectionCancelled = false
    private var listenerCancelled = false
    private var nativeFailure: Error?
    private var terminal = false
    private var closing = false
    private var closeTask: Task<Void, Error>?
    private var closeContinuation: CheckedContinuation<Void, Error>?
    private var releaseTransferSlot: (@MainActor () -> Void)?

    var isClosed: Bool { terminal }

    func holdTransferSlot(release: @escaping @MainActor () -> Void) throws {
        guard !closing, !terminal, connection == nil, listener == nil, releaseTransferSlot == nil else { throw IOSAudioFileConnectionError.closed }
        releaseTransferSlot = release
    }

    func attach(_ connection: NWConnection) throws {
        try requireUnattached()
        self.connection = connection
    }

    /// Own the listener before the first suspension. Only loopback is exposed to
    /// usbmuxd; a peer must still prove the existing file approval MAC before any
    /// file chunk is sent. The port itself is not an authentication credential.
    func prepareUSBReturnListener(requireAuthorization: @MainActor () throws -> Void) async throws -> UInt16 {
        try requireUnattached(); try requireAuthorization()
        guard releaseTransferSlot != nil else { throw IOSAudioFileConnectionError.transferSlotRequired }
        guard listener == nil else { throw IOSAudioFileConnectionError.alreadyAttached }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let value = try NWListener(using: parameters)
        listener = value
        value.stateUpdateHandler = { [weak self, weak value] state in
            Task { @MainActor in
                guard let self, let value, self.listener === value else { return }
                switch state {
                case .cancelled: self.listenerCancelled = true; self.confirmClosedIfComplete()
                case .failed(let error): self.nativeFailure = error; self.cancel()
                default: break
                }
            }
        }
        value.newConnectionHandler = { [weak self, weak value] accepted in
            Task { @MainActor in
                guard let self, let value, self.listener === value, !self.closing, !self.terminal,
                      self.connection == nil else { accepted.cancel(); return }
                self.connection = accepted
                accepted.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor in self?.observe(state) }
                }
                accepted.start(queue: .main)
                value.cancel() // One native connection per offered file.
            }
        }
        value.start(queue: .main)
        try await waitForNativeState(timeout: .seconds(5), requireAuthorization: requireAuthorization) {
            if case .ready = value.state { return true }
            return value.port != nil && self.connection != nil
        }
        guard let port = value.port, port.rawValue > 0 else { throw IOSAudioFileConnectionError.closed }
        return port.rawValue
    }

    func waitForUSBReturnConnection(requireAuthorization: @MainActor () throws -> Void) async throws -> NWConnection {
        guard listener != nil else { throw IOSAudioFileConnectionError.closed }
        try await waitForNativeState(timeout: .seconds(15), requireAuthorization: requireAuthorization) {
            if case .ready? = self.connection?.state { return true }
            return false
        }
        guard let connection else { throw IOSAudioFileConnectionError.closed }
        try requireCurrent(connection); try requireAuthorization()
        return connection
    }

    private func waitForNativeState(timeout: Duration, requireAuthorization: @MainActor () throws -> Void,
                                    ready: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            try Task.checkCancellation(); try requireAuthorization()
            if let nativeFailure { throw nativeFailure }
            guard !closing, !terminal else { throw IOSAudioFileConnectionError.closed }
            if ready() { return }
            guard ContinuousClock.now < deadline else { throw IOSAudioFileConnectionError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func requireUnattached() throws {
        guard !closing, !terminal else { throw IOSAudioFileConnectionError.closed }
        guard self.connection == nil else { throw IOSAudioFileConnectionError.alreadyAttached }
    }

    func requireCurrent(_ expected: NWConnection) throws {
        try Task.checkCancellation()
        guard !closing, !terminal, connection === expected else { throw IOSAudioFileConnectionError.closed }
    }

    func observe(_ state: NWConnection.State) {
        switch state {
        case .cancelled:
            connectionCancelled = true; closing = true; listener?.cancel(); confirmClosedIfComplete()
        case .failed(let error):
            nativeFailure = error; cancel()
        default: break
        }
    }

    func cancel() {
        closing = true
        connection?.cancel(); listener?.cancel()
        confirmClosedIfComplete()
    }

    /// Coalesces concurrent closes. Cancellation of a caller does not cancel the
    /// cleanup task. A timeout retains the socket and permits an explicit retry.
    func close() async throws {
        if let closeTask { return try await closeTask.value }
        if terminal { return }
        closing = true
        if connection == nil, listener == nil { confirmClosedIfComplete(); return }
        let task = Task { @MainActor [self] in
            let timeout = Task { @MainActor [self] in
                do { try await Task.sleep(for: .seconds(5)) }
                catch is CancellationError { return }
                catch { finishClose(.failure(error)); return }
                finishClose(.failure(IOSAudioFileConnectionError.closeUnconfirmed))
            }
            defer { timeout.cancel() }
            try await withCheckedThrowingContinuation { continuation in
                if terminal { continuation.resume(); return }
                closeContinuation = continuation
                connection?.cancel(); listener?.cancel()
                confirmClosedIfComplete()
            }
        }
        closeTask = task
        do { try await task.value; closeTask = nil }
        catch { closeTask = nil; throw error }
    }

    private func finishClose(_ result: Result<Void, Error>) {
        let continuation = closeContinuation
        closeContinuation = nil
        continuation?.resume(with: result)
    }

    private func confirmClosedIfComplete() {
        guard closing, !terminal, (connection == nil || connectionCancelled),
              (listener == nil || listenerCancelled) else { return }
        terminal = true
        connection = nil; listener = nil
        let release = releaseTransferSlot
        releaseTransferSlot = nil
        release?()
        finishClose(.success(()))
    }

    deinit { connection?.cancel(); listener?.cancel() }
}
