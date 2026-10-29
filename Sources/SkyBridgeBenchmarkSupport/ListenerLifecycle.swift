import Dispatch
import Network
import os.lock

final class ListenerLifecycle: Sendable {
    private struct State: Sendable {
        var started = false
    }

    private let protocolName: String
    private let listener: NWListener
    private let mailbox: AcceptedConnectionMailbox
    private let queue: DispatchQueue
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let readyEvent = TimedEvent<NWEndpoint.Port>()
    private let terminalEvent = TimedEvent<TerminalState>()

    init(
        protocolName: String,
        listener: NWListener,
        mailbox: AcceptedConnectionMailbox,
        queue: DispatchQueue
    ) {
        self.protocolName = protocolName
        self.listener = listener
        self.mailbox = mailbox
        self.queue = queue
    }

    func startAndWaitUntilReady(timeoutSeconds: Double) async throws -> NWEndpoint.Port {
        let shouldStart = state.withLock { state -> Bool in
            guard !state.started else { return false }
            state.started = true
            return true
        }
        guard shouldStart else {
            throw NetworkLoopbackLifecycleError.invariantViolation(
                "\(protocolName) listener started more than once"
            )
        }

        readyEvent.armTimeout(
            queue: queue,
            timeoutSeconds: timeoutSeconds,
            error: .listener(
                protocolName: protocolName,
                stage: "ready timeout",
                detail: "timed out after \(timeoutSeconds)s"
            ),
            onTimeout: { [weak self] in self?.listener.cancel() }
        )
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            if let overflow = self.mailbox.offer(connection) {
                self.readyEvent.resolve(.failure(overflow))
                self.listener.cancel()
            }
        }
        listener.stateUpdateHandler = { [weak self] listenerState in
            self?.observe(listenerState)
        }
        listener.start(queue: queue)

        return try await withTaskCancellationHandler {
            if Task.isCancelled {
                let error = NetworkLoopbackLifecycleError.listener(
                    protocolName: protocolName,
                    stage: "ready",
                    detail: "task cancelled"
                )
                readyEvent.resolve(.failure(error))
                listener.cancel()
            }
            return try await readyEvent.value()
        } onCancel: { [weak self] in
            guard let self else { return }
            self.readyEvent.resolve(.failure(.listener(
                protocolName: self.protocolName,
                stage: "ready",
                detail: "task cancelled"
            )))
            self.listener.cancel()
        }
    }

    func cancelAndWaitForTerminal(timeoutSeconds: Double) async throws {
        defer {
            listener.stateUpdateHandler = nil
            listener.newConnectionHandler = nil
        }
        mailbox.finish(.listener(
            protocolName: protocolName,
            stage: "teardown",
            detail: "listener closing"
        ))
        terminalEvent.armTimeout(
            queue: queue,
            timeoutSeconds: timeoutSeconds,
            error: .listener(
                protocolName: protocolName,
                stage: "terminal timeout",
                detail: "did not reach a terminal state after local cancellation within \(timeoutSeconds)s"
            ),
            onTimeout: { [weak self] in self?.listener.cancel() }
        )
        listener.cancel()
        let terminalState = try await terminalEvent.value()
        if case .failed(let detail) = terminalState {
            throw NetworkLoopbackLifecycleError.listener(
                protocolName: protocolName,
                stage: "terminal",
                detail: "entered failed state: \(detail)"
            )
        }
    }

    private func observe(_ listenerState: NWListener.State) {
        switch listenerState {
        case .ready:
            guard let port = listener.port else {
                readyEvent.resolve(.failure(.listener(
                    protocolName: protocolName,
                    stage: "ready",
                    detail: "listener has no bound port"
                )))
                listener.cancel()
                return
            }
            readyEvent.resolve(.success(port))
        case .failed(let error):
            let lifecycleError = NetworkLoopbackLifecycleError.listener(
                protocolName: protocolName,
                stage: "state",
                detail: String(describing: error)
            )
            readyEvent.resolve(.failure(lifecycleError))
            mailbox.finish(lifecycleError)
            terminalEvent.resolve(.success(.failed(String(describing: error))))
        case .cancelled:
            let lifecycleError = NetworkLoopbackLifecycleError.listener(
                protocolName: protocolName,
                stage: "state",
                detail: "cancelled before ready"
            )
            readyEvent.resolve(.failure(lifecycleError))
            mailbox.finish(lifecycleError)
            terminalEvent.resolve(.success(.cancelled))
        default:
            break
        }
    }
}
