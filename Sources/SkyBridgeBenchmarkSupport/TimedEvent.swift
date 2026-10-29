import Dispatch
import Foundation
import os.lock

struct ReadyStamp: Sendable {
    let instant: ContinuousClock.Instant
    let epoch: TimeInterval
}

enum TerminalState: Sendable {
    case cancelled
    case failed(String)
}

final class TimedEvent<Value: Sendable>: Sendable {
    private enum Resolution: Sendable {
        case pending
        case waiting(CheckedContinuation<Value, Error>)
        case resolved(Result<Value, NetworkLoopbackLifecycleError>)
    }

    private struct State: Sendable {
        var resolution: Resolution = .pending
        var timer: DispatchSourceTimer?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    @discardableResult
    func resolve(_ result: Result<Value, NetworkLoopbackLifecycleError>) -> Bool {
        let action = state.withLock { state -> (
            won: Bool,
            timer: DispatchSourceTimer?,
            continuation: CheckedContinuation<Value, Error>?
        ) in
            let continuation: CheckedContinuation<Value, Error>?
            switch state.resolution {
            case .pending:
                continuation = nil
            case .waiting(let waiting):
                continuation = waiting
            case .resolved:
                return (false, nil, nil)
            }
            let timer = state.timer
            state.timer = nil
            state.resolution = .resolved(result)
            return (true, timer, continuation)
        }
        action.timer?.cancel()
        action.continuation?.resume(with: result.mapError { $0 as Error })
        return action.won
    }

    func armTimeout(
        queue: DispatchQueue,
        timeoutSeconds: Double,
        error: NetworkLoopbackLifecycleError,
        onTimeout: @escaping @Sendable () -> Void
    ) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + timeoutSeconds)
        timer.setEventHandler { [weak self] in
            guard self?.resolve(.failure(error)) == true else { return }
            onTimeout()
        }
        timer.activate()

        let retained = state.withLock { state -> Bool in
            guard state.timer == nil else { return false }
            guard case .resolved = state.resolution else {
                state.timer = timer
                return true
            }
            return false
        }
        if !retained {
            timer.cancel()
        }
    }

    func value() async throws -> Value {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, Error>) in
            let immediate = state.withLock { state -> Result<Value, NetworkLoopbackLifecycleError>? in
                switch state.resolution {
                case .pending:
                    state.resolution = .waiting(continuation)
                    return nil
                case .waiting:
                    return .failure(.invariantViolation("event has more than one waiter"))
                case .resolved(let result):
                    return result
                }
            }
            immediate.map { continuation.resume(with: $0.mapError { $0 as Error }) }
        }
    }
}
