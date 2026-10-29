import Dispatch
import Foundation
import Network
import os.lock

final class ConnectionLifecycle: Sendable {
    private struct State: Sendable {
        var started = false
        var readyStamp: ReadyStamp?
        var kickoffCompleted = false
    }

    private let protocolName: String
    private let iteration: Int
    private let role: String
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let readyEvent = TimedEvent<ReadyStamp>()
    private let terminalEvent = TimedEvent<TerminalState>()

    init(
        protocolName: String,
        iteration: Int,
        role: String,
        connection: NWConnection,
        queue: DispatchQueue
    ) {
        self.protocolName = protocolName
        self.iteration = iteration
        self.role = role
        self.connection = connection
        self.queue = queue
    }

    func start(timeoutSeconds: Double, kickoffBytes: Int) {
        let shouldStart = state.withLock { state -> Bool in
            guard !state.started else { return false }
            state.started = true
            state.kickoffCompleted = kickoffBytes == 0
            return true
        }
        guard shouldStart else {
            readyEvent.resolve(.failure(.invariantViolation(
                "\(protocolName) \(role) connection started more than once on iteration \(iteration)"
            )))
            requestCancel()
            return
        }

        readyEvent.armTimeout(
            queue: queue,
            timeoutSeconds: timeoutSeconds,
            error: .connection(
                protocolName: protocolName,
                iteration: iteration,
                role: role,
                stage: "ready timeout",
                detail: "timed out after \(timeoutSeconds)s"
            ),
            onTimeout: { [weak self] in self?.requestCancel() }
        )
        connection.stateUpdateHandler = { [weak self] state in
            self?.observe(state)
        }
        connection.start(queue: queue)

        guard kickoffBytes > 0 else { return }
        let payload = Data(repeating: 0, count: kickoffBytes)
        connection.send(content: payload, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                self.readyEvent.resolve(.failure(.connection(
                    protocolName: self.protocolName,
                    iteration: self.iteration,
                    role: self.role,
                    stage: "kickoff send",
                    detail: String(describing: error)
                )))
                self.requestCancel()
                return
            }
            if let readyStamp = self.recordKickoffCompletion() {
                self.readyEvent.resolve(.success(readyStamp))
            }
        })
    }

    func waitUntilReady() async throws -> ReadyStamp {
        try await withTaskCancellationHandler {
            if Task.isCancelled {
                let error = NetworkLoopbackLifecycleError.connection(
                    protocolName: protocolName,
                    iteration: iteration,
                    role: role,
                    stage: "ready",
                    detail: "task cancelled"
                )
                readyEvent.resolve(.failure(error))
                requestCancel()
            }
            return try await readyEvent.value()
        } onCancel: { [weak self] in
            guard let self else { return }
            self.readyEvent.resolve(.failure(.connection(
                protocolName: self.protocolName,
                iteration: self.iteration,
                role: self.role,
                stage: "ready",
                detail: "task cancelled"
            )))
            self.requestCancel()
        }
    }

    func requestCancel() {
        connection.cancel()
    }

    func waitForTerminal(timeoutSeconds: Double) async throws {
        defer { connection.stateUpdateHandler = nil }
        terminalEvent.armTimeout(
            queue: queue,
            timeoutSeconds: timeoutSeconds,
            error: .connection(
                protocolName: protocolName,
                iteration: iteration,
                role: role,
                stage: "terminal timeout",
                detail: "did not reach a terminal state after local cancellation within \(timeoutSeconds)s"
            ),
            onTimeout: { [weak self] in self?.requestCancel() }
        )
        let terminalState = try await terminalEvent.value()
        if case .failed(let detail) = terminalState {
            throw NetworkLoopbackLifecycleError.connection(
                protocolName: protocolName,
                iteration: iteration,
                role: role,
                stage: "terminal",
                detail: "entered failed state: \(detail)"
            )
        }
    }

    private func observe(_ connectionState: NWConnection.State) {
        switch connectionState {
        case .ready:
            let readyStamp = ReadyStamp(
                instant: ContinuousClock.now,
                epoch: Date().timeIntervalSince1970
            )
            if let completedStamp = recordReady(readyStamp) {
                readyEvent.resolve(.success(completedStamp))
            }
        case .failed(let error):
            readyEvent.resolve(.failure(.connection(
                protocolName: protocolName,
                iteration: iteration,
                role: role,
                stage: "state",
                detail: String(describing: error)
            )))
            terminalEvent.resolve(.success(.failed(String(describing: error))))
        case .cancelled:
            readyEvent.resolve(.failure(.connection(
                protocolName: protocolName,
                iteration: iteration,
                role: role,
                stage: "state",
                detail: "cancelled before ready"
            )))
            terminalEvent.resolve(.success(.cancelled))
        default:
            break
        }
    }

    private func recordReady(_ readyStamp: ReadyStamp) -> ReadyStamp? {
        state.withLock { state in
            if state.readyStamp == nil {
                state.readyStamp = readyStamp
            }
            return state.kickoffCompleted ? state.readyStamp : nil
        }
    }

    private func recordKickoffCompletion() -> ReadyStamp? {
        state.withLock { state in
            state.kickoffCompleted = true
            return state.readyStamp
        }
    }
}
