import Foundation

final class OrderedInboundChunkRelay: @unchecked Sendable {
    private let lock = NSLock()
    private let maxPendingOperations: Int
    private let maxPendingBytes: Int
    private var tailTask: Task<Void, Never>?
    private var pendingOperationCount = 0
    private var pendingBytes = 0
    private var generation: UInt64 = 0
    private var acceptingSubmissions = true

    init(
        maxPendingOperations: Int = 128,
        maxPendingBytes: Int = 32 * 1024 * 1024
    ) {
        precondition(maxPendingOperations > 0)
        precondition(maxPendingBytes > 0)
        self.maxPendingOperations = maxPendingOperations
        self.maxPendingBytes = maxPendingBytes
    }

    @discardableResult
    func submit(
        byteCount: Int,
        _ operation: @escaping @Sendable () async -> Void
    ) -> Bool {
        precondition(byteCount >= 0)
        lock.lock()
        guard acceptingSubmissions,
              byteCount > 0,
              pendingOperationCount < maxPendingOperations,
              byteCount <= maxPendingBytes - pendingBytes else {
            acceptingSubmissions = false
            lock.unlock()
            return false
        }

        let previous = tailTask
        let submissionGeneration = generation
        pendingOperationCount += 1
        pendingBytes += byteCount
        let next = Task { [weak self] in
            _ = await previous?.result
            defer {
                self?.completeSubmission(
                    byteCount: byteCount,
                    generation: submissionGeneration
                )
            }
            guard !Task.isCancelled else { return }
            await operation()
        }
        tailTask = next
        lock.unlock()
        return true
    }

    private func completeSubmission(byteCount: Int, generation completedGeneration: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard generation == completedGeneration else { return }
        pendingOperationCount -= 1
        pendingBytes -= byteCount
    }

    func cancel() {
        lock.lock()
        let task = tailTask
        tailTask = nil
        generation &+= 1
        pendingOperationCount = 0
        pendingBytes = 0
        acceptingSubmissions = false
        lock.unlock()
        task?.cancel()
    }
}
