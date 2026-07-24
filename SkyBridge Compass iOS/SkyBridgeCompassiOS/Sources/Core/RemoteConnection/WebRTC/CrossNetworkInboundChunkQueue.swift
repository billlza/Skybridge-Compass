import Foundation

@available(iOS 17.0, *)
actor InboundChunkQueue {
    private var pending: [Data] = []
    private var pendingBytes = 0
    private var waiters: [CheckedContinuation<Data, Error>] = []
    private var finished = false
    private var overflowed = false
    private let maxPendingBytes: Int
    private let maxPendingChunks: Int

    init(
        maxPendingBytes: Int = 32 * 1024 * 1024,
        maxPendingChunks: Int = 1_024
    ) {
        precondition(maxPendingBytes > 0)
        precondition(maxPendingChunks > 0)
        self.maxPendingBytes = maxPendingBytes
        self.maxPendingChunks = maxPendingChunks
    }

    enum QueueError: Error {
        case finished
        case invalidReadLimit
        case overflow
    }

    @discardableResult
    func push(_ data: Data) -> Bool {
        guard !finished, !overflowed else { return false }
        guard !data.isEmpty else {
            failOverflow()
            return false
        }
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume(returning: data)
            return true
        }
        if pending.count >= maxPendingChunks
            || data.count > maxPendingBytes - pendingBytes {
            failOverflow()
            return false
        }
        pending.append(data)
        pendingBytes += data.count
        return true
    }

    func failOverflow() {
        guard !overflowed, !finished else { return }
        overflowed = true
        pending.removeAll()
        pendingBytes = 0
        let activeWaiters = waiters
        waiters.removeAll()
        activeWaiters.forEach { $0.resume(throwing: QueueError.overflow) }
    }

    func finish() {
        finished = true
        let activeWaiters = waiters
        waiters.removeAll()
        activeWaiters.forEach { $0.resume(throwing: QueueError.finished) }
    }

    func next() async throws -> Data {
        if let first = pending.first {
            pending.removeFirst()
            pendingBytes -= first.count
            return first
        }
        if overflowed { throw QueueError.overflow }
        if finished { throw QueueError.finished }
        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func next(max: Int) async throws -> Data {
        guard max > 0 else {
            throw QueueError.invalidReadLimit
        }
        let chunk = try await next()
        if chunk.count <= max {
            return chunk
        }
        let head = Data(chunk.prefix(max))
        let tail = Data(chunk.dropFirst(max))
        pending.insert(tail, at: 0)
        pendingBytes += tail.count
        return head
    }
}
