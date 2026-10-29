import os.lock

/// Separates one-shot listener startup completion from later runtime state changes.
final class NetworkListenerStartupGate: @unchecked Sendable {
    enum TerminalState: Sendable, Equatable {
        case ready
        case failed
        case cancelled
    }

    enum Observation: Sendable, Equatable {
        case completesStartup
        case runtimeTransition
        case ignored
    }

    private enum State: Sendable {
        case pending
        case running
        case terminal
        case timedOut
    }

    private let state = OSAllocatedUnfairLock(initialState: State.pending)

    func observe(_ terminalState: TerminalState) -> Observation {
        state.withLock { state in
            switch state {
            case .pending:
                state = terminalState == .ready ? .running : .terminal
                return .completesStartup
            case .running:
                if terminalState != .ready {
                    state = .terminal
                }
                return .runtimeTransition
            case .terminal, .timedOut:
                return .ignored
            }
        }
    }

    func claimTimeout() -> Bool {
        state.withLock { state in
            guard state == .pending else { return false }
            state = .timedOut
            return true
        }
    }
}
