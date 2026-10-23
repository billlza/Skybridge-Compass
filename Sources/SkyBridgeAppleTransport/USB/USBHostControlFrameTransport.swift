#if os(macOS)
import Foundation
import os
import SkyBridgeProtocolCore

public enum USBHostControlFrameError: Error, Equatable, Sendable {
    case invalidFrame, queueFull, invalidConfiguration
}

/// Existing MAIN frames over one already-open native USB logical stream. All
/// callers share a finite FIFO and the same actual write owner. A cable or ACK
/// provides no identity: callers capture the authority for each enqueue, and
/// that authority is checked again at native dispatch, including each chunk.
/// The attachment owner retains/closes the physical multiplexer separately.
public final class USBHostControlFrameTransport: Sendable {
    public typealias Authorization = @Sendable () throws -> Void
    public typealias Completion = @Sendable (Result<Void, any Error>) -> Void
    private let core: USBControlFrameCore
    private let tasks = USBMultiplexTasks()
    private let cleaning = OSAllocatedUnfairLock(initialState: false)

    public init(stream: USBHostMultiplexConnection.Stream, maximumPendingFrames: Int = 8,
                maximumPendingBytes: Int = 2 * (P2PControlFramePolicy.maximumBodyByteCount + 4),
                readTimeout: Duration = .seconds(120)) throws {
        guard (1...32).contains(maximumPendingFrames),
              ((P2PControlFramePolicy.maximumBodyByteCount + 4)...(32 * (P2PControlFramePolicy.maximumBodyByteCount + 4))).contains(maximumPendingBytes),
              readTimeout > .zero && readTimeout <= .seconds(300) else {
            throw USBHostControlFrameError.invalidConfiguration
        }
        core = USBControlFrameCore(stream: stream, frameLimit: maximumPendingFrames,
                                   byteLimit: maximumPendingBytes, readTimeout: readTimeout)
        let core = core
        tasks.start([{ await core.writeLoop() }, { await core.deadlineLoop() }])
    }
    deinit { core.retire(USBHostMultiplexError.closed) }
    public var isReady: Bool { core.isReady }
    public var terminalFailure: (any Error)? { core.failure }
    var pendingFrameCount: Int { core.pendingFrameCount }
    var readInProgress: Bool { core.readInProgress }

    /// The complete, canonical length-prefixed frame is admitted synchronously.
    /// Native effects happen on the owned writer, outside the caller's state lock.
    public func enqueueFramedBytes(_ bytes: Data, timeout: Duration = .seconds(5),
                                   requireEffectAuthorization: @escaping Authorization,
                                   completion: @escaping Completion) throws {
        try core.enqueue(USBControlFramePending(bytes: bytes, timeout: timeout,
            authorization: requireEffectAuthorization, completion: completion))
    }

    public func sendFrame(_ body: Data, timeout: Duration = .seconds(5),
                          requireEffectAuthorization: @escaping Authorization) async throws {
        defer { withExtendedLifetime(self) {} }
        let reply = USBControlFrameReply()
        let pending = try USBControlFramePending(bytes: P2PControlFramePolicy.frame(body: body), timeout: timeout,
                                                authorization: requireEffectAuthorization, completion: reply.finish)
        try await withTaskCancellationHandler {
            do { try Task.checkCancellation(); try core.enqueue(pending) }
            catch { pending.finish(.failure(error)) }
            try await reply.value()
        } onCancel: { self.core.cancel(pending) }
    }

    public func receiveFrame(maximumBytes: Int = P2PControlFramePolicy.maximumBodyByteCount) async throws -> Data {
        defer { withExtendedLifetime(self) {} }
        return try await core.receiveFrame(maximumBytes: maximumBytes)
    }
    public func close() { core.retire(USBHostMultiplexError.closed) }
    public func closeAndAwait(timeout: Duration = .seconds(5)) async throws {
        defer { withExtendedLifetime(self) {} }
        let budget = try USBMultiplexBudget(timeout)
        try cleaning.withLock { active in
            guard !active else { throw USBHostMultiplexError.cleanupInProgress }; active = true
        }
        defer { cleaning.withLock { $0 = false } }
        close()
        try await tasks.join(budget: budget)
        try await core.awaitReadExit(budget: budget)
        try await core.stream.closeAndAwait(timeout: budget.remaining())
    }
}

private final class USBControlFrameReply: Sendable {
    private let result = OSAllocatedUnfairLock<Result<Void, any Error>?>(initialState: nil)
    private let wake = USBMultiplexWake()
    func finish(_ value: Result<Void, any Error>) {
        let changed = result.withLock { current in
            guard current == nil else { return false }; current = value; return true
        }
        if changed { wake.signal() }
    }
    func value() async throws {
        while true {
            if let value = result.withLock({ $0 }) { return try value.get() }
            do { try await wake.wait() }
            catch {
                if let value = result.withLock({ $0 }) { return try value.get() }
                throw error
            }
        }
    }
}

private final class USBControlFramePending: Sendable {
    let bytes: Data
    let lease: USBMultiplexLease
    private let completion: USBHostControlFrameTransport.Completion
    private let finished = OSAllocatedUnfairLock(initialState: false)
    init(bytes: Data, timeout: Duration, authorization: @escaping USBHostControlFrameTransport.Authorization,
         completion: @escaping USBHostControlFrameTransport.Completion) throws {
        guard bytes.count >= 4 else { throw USBHostControlFrameError.invalidFrame }
        let length = bytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard let count = try? P2PControlFramePolicy.inboundBodyByteCount(from: length),
              count + 4 == bytes.count else { throw USBHostControlFrameError.invalidFrame }
        guard timeout > .zero && timeout <= .seconds(5) else { throw USBHostMultiplexError.invalidTimeout }
        self.bytes = Data(bytes)
        lease = try USBMultiplexLease(budget: USBMultiplexBudget(timeout), effect: authorization)
        self.completion = completion
    }
    func finish(_ result: Result<Void, any Error>) {
        let deliver = finished.withLock { done in guard !done else { return false }; done = true; return true }
        if deliver { completion(result) }
    }
}

private final class USBControlFrameCore: Sendable {
    private struct State: Sendable {
        var queue: [USBControlFramePending] = []
        var active: USBControlFramePending?
        var bytes = 0
        var reading = false
        var failure: (any Error)?
    }
    let stream: USBHostMultiplexConnection.Stream
    private let frameLimit: Int, byteLimit: Int
    private let readTimeout: Duration
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let writerWake = USBMultiplexWake(), deadlineWake = USBMultiplexWake(), readExit = USBMultiplexWake()
    init(stream: USBHostMultiplexConnection.Stream, frameLimit: Int, byteLimit: Int, readTimeout: Duration) {
        self.stream = stream; self.frameLimit = frameLimit; self.byteLimit = byteLimit; self.readTimeout = readTimeout
    }
    var failure: (any Error)? { state.withLock { $0.failure } }
    var isReady: Bool { failure == nil && !stream.isClosed }
    var pendingFrameCount: Int { state.withLock { $0.queue.count + ($0.active == nil ? 0 : 1) } }
    var readInProgress: Bool { state.withLock { $0.reading } }

    func enqueue(_ pending: USBControlFramePending) throws {
        try state.withLock { value in
            if let error = value.failure { throw error }
            guard !stream.isClosed else { throw USBHostMultiplexError.closed }
            try pending.lease.check()
            guard value.queue.count + (value.active == nil ? 0 : 1) < frameLimit,
                  pending.bytes.count <= byteLimit - value.bytes else { throw USBHostControlFrameError.queueFull }
            value.queue.append(pending); value.bytes += pending.bytes.count
        }
        writerWake.signal(); deadlineWake.signal()
    }

    func cancel(_ pending: USBControlFramePending) {
        pending.lease.retire(CancellationError())
        let active = state.withLock { value in
            if value.active === pending { return true }
            if let index = value.queue.firstIndex(where: { $0 === pending }) {
                value.queue.remove(at: index); value.bytes -= pending.bytes.count
            }
            return false
        }
        if active { retire(CancellationError()) }
        pending.finish(.failure(CancellationError()))
        writerWake.signal(); deadlineWake.signal()
    }

    func retire(_ cause: any Error) {
        let owned = state.withLock { value -> [USBControlFramePending]? in
            guard value.failure == nil else { return nil }
            value.failure = cause
            let owned = value.queue + (value.active.map { [$0] } ?? [])
            value.queue.removeAll(); value.bytes = value.active?.bytes.count ?? 0
            return owned
        }
        guard let owned else { return }
        // Publish failure before native cancellation/cleanup, which is a separate fact.
        for pending in owned { pending.lease.retire(cause); pending.finish(.failure(cause)) }
        stream.close(); writerWake.signal(); deadlineWake.signal(); readExit.signal()
    }

    func writeLoop() async {
        while failure == nil {
            let pending = state.withLock { value -> USBControlFramePending? in
                guard value.failure == nil, !value.queue.isEmpty else { return nil }
                let pending = value.queue.removeFirst(); value.active = pending; return pending
            }
            guard let pending else {
                do { try await writerWake.wait() } catch { retire(error) }
                continue
            }
            var nativeStarted = false
            let result: Result<Void, any Error>
            do {
                try pending.lease.authorize()
                nativeStarted = true
                try await stream.writeBytes(pending.bytes, timeout: pending.lease.budget.remaining(),
                                            requireEffectAuthorization: pending.lease.authorize)
                try pending.lease.check()
                result = .success(())
            } catch {
                if nativeStarted { retire(error) }
                result = .failure(error)
            }
            let outcome = state.withLock { value -> Result<Void, any Error> in
                value.active = nil; value.bytes -= pending.bytes.count
                return value.failure.map { .failure($0) } ?? result
            }
            pending.finish(outcome); deadlineWake.signal()
        }
    }

    func deadlineLoop() async {
        while failure == nil {
            let now = ContinuousClock.now
            let outcome = state.withLock { value -> (activeExpired: Bool, expired: [USBControlFramePending], next: ContinuousClock.Instant?) in
                let expired = value.queue.filter { $0.lease.budget.deadline <= now }
                value.queue.removeAll { $0.lease.budget.deadline <= now }
                value.bytes -= expired.reduce(0) { $0 + $1.bytes.count }
                let activeExpired = value.active.map { $0.lease.budget.deadline <= now } ?? false
                let next = (value.queue.map { $0.lease.budget.deadline } + (value.active.map { [$0.lease.budget.deadline] } ?? [])).min()
                return (activeExpired, expired, next)
            }
            for pending in outcome.expired {
                pending.lease.retire(USBHostMultiplexError.timedOut)
                pending.finish(.failure(USBHostMultiplexError.timedOut))
            }
            if outcome.activeExpired { retire(USBHostMultiplexError.timedOut); return }
            do {
                if let next = outcome.next { _ = try await deadlineWake.wait(until: next) }
                else { try await deadlineWake.wait() }
            } catch { retire(error) }
        }
    }

    func receiveFrame(maximumBytes: Int) async throws -> Data {
        guard (1...P2PControlFramePolicy.maximumBodyByteCount).contains(maximumBytes) else {
            throw USBHostControlFrameError.invalidFrame
        }
        try state.withLock { value in
            if let error = value.failure { throw error }
            guard !value.reading else { throw USBHostMultiplexError.readInProgress }
            value.reading = true
        }
        defer { state.withLock { $0.reading = false }; readExit.signal() }
        do {
            let bytes = try await stream.readFrame(maximumBytes: maximumBytes, timeout: readTimeout)
            if let error = failure { throw error }
            return bytes
        } catch { retire(error); throw failure ?? error }
    }
    func awaitReadExit(budget: USBMultiplexBudget) async throws {
        while state.withLock({ $0.reading }) {
            guard try await readExit.wait(until: budget.deadline) else { throw USBHostMultiplexError.cleanupUnconfirmed }
        }
    }
}
#endif
