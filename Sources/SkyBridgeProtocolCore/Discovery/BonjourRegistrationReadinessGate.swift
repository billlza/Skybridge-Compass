import os.lock

/// Platform-neutral reducer for one Bonjour listener startup.
///
/// Apple adapters feed it socket readiness and process-local registration keys;
/// startup completes only after both have been observed. Keeping this reducer in
/// ProtocolCore lets macOS and iOS share the same race semantics without making
/// the protocol layer depend on Network.framework.
public final class BonjourRegistrationReadinessGate: @unchecked Sendable {
    public enum Observation: Sendable, Equatable {
        case pending
        case completesStartup
        case runtimeReady
        case runtimeDegraded
        case runtimeTerminal
        case ignored
    }

    private enum State: Sendable {
        case pending(socketReady: Bool, registrations: Set<String>)
        case running(socketReady: Bool, registrations: Set<String>)
        case terminal
        case timedOut
    }

    private let state = OSAllocatedUnfairLock(
        initialState: State.pending(socketReady: false, registrations: [])
    )

    public init() {}

    public func observeSocketReady() -> Observation {
        state.withLock { state in
            switch state {
            case .pending(_, let registrations):
                if registrations.isEmpty {
                    state = .pending(socketReady: true, registrations: registrations)
                    return .pending
                }
                state = .running(socketReady: true, registrations: registrations)
                return .completesStartup
            case .running(let socketReady, let registrations):
                guard !socketReady else { return .ignored }
                state = .running(socketReady: true, registrations: registrations)
                return registrations.isEmpty ? .ignored : .runtimeReady
            case .terminal, .timedOut:
                return .ignored
            }
        }
    }

    public func observeSocketUnavailable() -> Observation {
        state.withLock { state in
            switch state {
            case .pending(_, let registrations):
                state = .pending(socketReady: false, registrations: registrations)
                return .pending
            case .running(let socketReady, let registrations):
                guard socketReady else { return .ignored }
                state = .running(socketReady: false, registrations: registrations)
                return registrations.isEmpty ? .ignored : .runtimeDegraded
            case .terminal, .timedOut:
                return .ignored
            }
        }
    }

    public func observeRegistrationAdded(_ key: String) -> Observation {
        state.withLock { state in
            switch state {
            case .pending(let socketReady, var registrations):
                guard registrations.insert(key).inserted else { return .ignored }
                if socketReady {
                    state = .running(socketReady: true, registrations: registrations)
                    return .completesStartup
                }
                state = .pending(socketReady: socketReady, registrations: registrations)
                return .pending
            case .running(let socketReady, var registrations):
                let wasEmpty = registrations.isEmpty
                guard registrations.insert(key).inserted else { return .ignored }
                state = .running(socketReady: socketReady, registrations: registrations)
                return wasEmpty && socketReady ? .runtimeReady : .ignored
            case .terminal, .timedOut:
                return .ignored
            }
        }
    }

    public func observeRegistrationRemoved(_ key: String) -> Observation {
        state.withLock { state in
            switch state {
            case .pending(let socketReady, var registrations):
                guard registrations.remove(key) != nil else { return .ignored }
                state = .pending(socketReady: socketReady, registrations: registrations)
                return .pending
            case .running(let socketReady, var registrations):
                guard registrations.remove(key) != nil else { return .ignored }
                state = .running(socketReady: socketReady, registrations: registrations)
                return registrations.isEmpty && socketReady ? .runtimeDegraded : .ignored
            case .terminal, .timedOut:
                return .ignored
            }
        }
    }

    public func observeTerminal() -> Observation {
        state.withLock { state in
            switch state {
            case .pending:
                state = .terminal
                return .completesStartup
            case .running:
                state = .terminal
                return .runtimeTerminal
            case .terminal, .timedOut:
                return .ignored
            }
        }
    }

    public func claimTimeout() -> Bool {
        state.withLock { state in
            guard case .pending = state else { return false }
            state = .timedOut
            return true
        }
    }
}
