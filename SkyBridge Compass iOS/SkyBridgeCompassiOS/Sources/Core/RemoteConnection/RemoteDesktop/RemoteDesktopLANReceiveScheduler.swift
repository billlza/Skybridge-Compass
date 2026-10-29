import Foundation

@available(iOS 17.0, *)
struct LANSecureReceiveContext: @unchecked Sendable {
    let connectionID: ObjectIdentifier
    let generation: UInt64
    let keys: SessionKeys
    let pipeline: LANRemoteSecureReceivePipeline
}

@available(iOS 17.0, *)
struct LANSecureReceiveLoopContext: @unchecked Sendable {
    let receiveContext: LANSecureReceiveContext
    let scheduler: LANSecureReceiveScheduler
}

@available(iOS 17.0, *)
final class LANSecureReceiveScheduler: @unchecked Sendable {
    typealias Completion = @Sendable (
        Result<LANRemoteSecureReceiveResult, Error>,
        ObjectIdentifier,
        UInt64
    ) async -> Void

    private let lock = NSLock()
    private var tailTask: Task<Void, Never>?
    private var epoch: UInt64 = 0

    func cancel() {
        lock.lock()
        epoch &+= 1
        let task = tailTask
        tailTask = nil
        lock.unlock()
        task?.cancel()
    }

    func scheduleChunk(
        _ chunk: Data,
        receivedAt: Date,
        context: LANSecureReceiveContext,
        maxCompleteScreenFrames: Int,
        maxDrainBudgetMs: Double,
        completion: @escaping Completion
    ) {
        let scheduledEpoch = currentEpoch()
        let parseTaskScheduledAt = Date()
        enqueue(
            context: context,
            expectedEpoch: scheduledEpoch,
            maxCompleteScreenFrames: maxCompleteScreenFrames,
            maxDrainBudgetMs: maxDrainBudgetMs,
            completion: completion
        ) {
            let parseTaskStartedAt = Date()
            return try await context.pipeline.appendAndDrain(
                chunk: chunk,
                receivedAt: receivedAt,
                keys: context.keys,
                maxCompleteScreenFrames: maxCompleteScreenFrames,
                maxDrainBudgetMs: maxDrainBudgetMs,
                parseTaskScheduledAt: parseTaskScheduledAt,
                parseTaskStartedAt: parseTaskStartedAt
            )
        }
    }

    /// The terminal event follows all queued chunks and every bounded parser drain.
    /// The consumer also fences its application queue before retiring the connection.
    func scheduleTerminal(
        context: LANSecureReceiveContext,
        completion: @escaping @Sendable (ObjectIdentifier, UInt64) async -> Void
    ) {
        lock.lock()
        let expectedEpoch = epoch
        let previous = tailTask
        let task = Task.detached(priority: .high) { [weak self, previous] in
            await previous?.value
            guard !Task.isCancelled,
                  self?.isCurrentEpoch(expectedEpoch) == true else { return }
            await completion(context.connectionID, context.generation)
        }
        tailTask = task
        lock.unlock()
    }

    private func enqueue(
        context: LANSecureReceiveContext,
        expectedEpoch: UInt64,
        maxCompleteScreenFrames: Int,
        maxDrainBudgetMs: Double,
        completion: @escaping Completion,
        work: @escaping @Sendable () async throws -> LANRemoteSecureReceiveResult
    ) {
        lock.lock()
        guard epoch == expectedEpoch else {
            lock.unlock()
            return
        }
        let previous = tailTask
        let task = Task.detached(priority: .high) { [weak self, previous] in
            await previous?.value
            guard !Task.isCancelled,
                  self?.isCurrentEpoch(expectedEpoch) == true else { return }

            do {
                var result = try await work()
                while true {
                    guard !Task.isCancelled,
                          self?.isCurrentEpoch(expectedEpoch) == true else { return }
                    await completion(.success(result), context.connectionID, context.generation)
                    guard result.hasCompletePayloadPending else { break }
                    // Keep drains in this same ordered job; appending another tail task
                    // would let an already queued EOF overtake the remaining payloads.
                    await Task.yield()
                    guard !Task.isCancelled,
                          self?.isCurrentEpoch(expectedEpoch) == true else { return }
                    result = try await context.pipeline.drain(
                        keys: context.keys,
                        maxCompleteScreenFrames: maxCompleteScreenFrames,
                        maxDrainBudgetMs: maxDrainBudgetMs
                    )
                }
            } catch {
                guard self?.isCurrentEpoch(expectedEpoch) == true else { return }
                await completion(.failure(error), context.connectionID, context.generation)
            }
        }
        tailTask = task
        lock.unlock()
    }

    private func currentEpoch() -> UInt64 {
        lock.lock()
        let value = epoch
        lock.unlock()
        return value
    }

    private func isCurrentEpoch(_ expectedEpoch: UInt64) -> Bool {
        lock.lock()
        let isCurrent = epoch == expectedEpoch
        lock.unlock()
        return isCurrent
    }
}


/// One NWConnection receive-loop owner. State callbacks cannot overtake a final
/// read callback that has not yet queued its authenticated bytes for parsing.
final class LANReceiveReadFence: @unchecked Sendable {
    let connectionID: ObjectIdentifier
    private let lock = NSLock()
    private var pendingReads = 0

    init(connectionID: ObjectIdentifier) { self.connectionID = connectionID }
    func beginRead() { lock.lock(); pendingReads += 1; lock.unlock() }
    func endRead() { lock.lock(); pendingReads -= 1; lock.unlock() }
    private var isIdle: Bool {
        lock.lock(); defer { lock.unlock() }
        return pendingReads == 0
    }
    func waitUntilIdle() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !isIdle {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw ReadFenceError.deadlineExceeded }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    enum ReadFenceError: Error { case deadlineExceeded }
}
