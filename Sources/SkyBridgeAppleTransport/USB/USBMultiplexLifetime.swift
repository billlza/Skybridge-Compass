#if os(macOS)
import Foundation
import os

public enum USBHostMultiplexError: Error, Equatable, Sendable {
    case closed, notStarted, alreadyStarted, invalidTimeout, invalidConfiguration
    case readInProgress, writeInProgress, acceptInProgress, cleanupInProgress
    case timedOut, unexpectedEnd, cleanupUnconfirmed, ownerRetired, invalidByteCount
    case concurrentWakeWaiter, missingWriteLease, invalidPingAcknowledgement
}

/// One coalesced notification and one cancellable waiter. Cancellation removes only its
/// exact waiter and does not finish the reusable signal (unlike cancelling AsyncStream.next).
final class USBMultiplexWake: Sendable {
    private final class Waiter: Sendable {
        private struct State: Sendable {
            var result: Result<Void, any Error>?
            var continuation: CheckedContinuation<Void, any Error>?
        }
        private let state = OSAllocatedUnfairLock(initialState: State())
        var resolved: Bool { state.withLock { $0.result != nil } }
        func install(_ continuation: CheckedContinuation<Void, any Error>) {
            let result = state.withLock { value -> Result<Void, any Error>? in
                if let result = value.result { return result }
                precondition(value.continuation == nil); value.continuation = continuation; return nil
            }
            if let result { continuation.resume(with: result) }
        }
        func resolve(_ result: Result<Void, any Error>) -> Completion? {
            state.withLock { value in
                guard value.result == nil else { return nil }
                value.result = result
                guard let continuation = value.continuation else { return nil }
                value.continuation = nil
                return Completion(continuation: continuation, result: result)
            }
        }
    }
    private struct Completion: Sendable {
        let continuation: CheckedContinuation<Void, any Error>
        let result: Result<Void, any Error>
        func resume() { continuation.resume(with: result) }
    }
    private struct State: Sendable { var pending = false; var waiter: Waiter? }
    private let state = OSAllocatedUnfairLock(initialState: State())
    func signal() {
        let completion = state.withLock { value -> Completion? in
            guard let waiter = value.waiter else { value.pending = true; return nil }
            value.waiter = nil; return waiter.resolve(.success(()))
        }
        completion?.resume()
    }
    func wait() async throws {
        let waiter = Waiter()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                waiter.install(continuation)
                let completion = state.withLock { value -> Completion? in
                    guard !waiter.resolved else { return nil }
                    if value.pending { value.pending = false; return waiter.resolve(.success(())) }
                    guard value.waiter == nil else { return waiter.resolve(.failure(USBHostMultiplexError.concurrentWakeWaiter)) }
                    value.waiter = waiter; return nil
                }
                completion?.resume()
            }
        } onCancel: {
            let completion = self.state.withLock { value -> Completion? in
                if value.waiter === waiter { value.waiter = nil }
                return waiter.resolve(.failure(CancellationError()))
            }
            completion?.resume()
        }
    }
    /// Both children are cancellation-responsive; the losing child is joined before reuse.
    /// true means a notification, false means this observation deadline, never I/O success.
    func wait(until deadline: ContinuousClock.Instant) async throws -> Bool {
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { try await self.wait(); return true }
            group.addTask { try await Task.sleep(until: deadline, clock: .continuous); return false }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw USBHostMultiplexError.cleanupUnconfirmed }
            return result
        }
    }
}

struct USBMultiplexBudget: Sendable {
    let deadline: ContinuousClock.Instant
    init(_ timeout: Duration) throws {
        guard timeout > .zero && timeout <= .seconds(300) else { throw USBHostMultiplexError.invalidTimeout }
        deadline = ContinuousClock.now.advanced(by: timeout)
    }
    func check() throws { _ = try remaining() }
    func remaining() throws -> Duration {
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else { throw USBHostMultiplexError.timedOut }; return remaining
    }
}

final class USBMultiplexLease: Sendable {
    let budget: USBMultiplexBudget
    let wake = USBMultiplexWake()
    private let failure = OSAllocatedUnfairLock<(any Error)?>(initialState: nil)
    private let effect: @Sendable () throws -> Void
    init(budget: USBMultiplexBudget, effect: @escaping @Sendable () throws -> Void = {}) {
        self.budget = budget; self.effect = effect
    }
    func retire(_ cause: any Error = USBHostMultiplexError.ownerRetired) { failure.withLock { if $0 == nil { $0 = cause } } }
    func check() throws {
        if let error = failure.withLock({ $0 }) { throw error }
        try budget.check()
    }
    func authorize() throws {
        try check(); try effect(); try check()
    }
    func wait() async throws {
        try check()
        guard try await wake.wait(until: budget.deadline) else { throw USBHostMultiplexError.timedOut }
        try check()
    }
}

/// Pump closures retain the core, but the core does not retain this task container. A join
/// observer awaits the actual task values. Timing out a caller never abandons those tasks.
final class USBMultiplexTasks: Sendable {
    private struct State: Sendable {
        var started = false
        var tasks: [Task<Void, Never>] = []
        var joinObserver: Task<Void, Never>?
        var joinStarted = false, joined = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let completed = USBMultiplexWake()
    func start(_ bodies: [@Sendable () async -> Void]) {
        state.withLock { value in
            precondition(!value.started && !value.joinStarted, "USB pumps are owned and single-use")
            value.started = true
            value.tasks = bodies.map { body in Task.detached { await body() } }
        }
    }
    /// The caller first retires admission and waits for start publication to finish. It also
    /// serializes cleanup observers, so the completion signal has exactly one consumer.
    func join(budget: USBMultiplexBudget) async throws {
        state.withLock { value in
            guard !value.joinStarted else { return }
            value.joinStarted = true
            let tasks = value.tasks
            let state = state, completed = completed
            value.joinObserver = Task.detached {
                for task in tasks { await task.value }
                state.withLock { $0.tasks.removeAll(); $0.joined = true }
                completed.signal()
            }
        }
        while !state.withLock({ $0.joined }) {
            guard try await completed.wait(until: budget.deadline) else { throw USBHostMultiplexError.cleanupUnconfirmed }
        }
    }
    var joined: Bool { state.withLock { $0.joined } }
}
#endif
