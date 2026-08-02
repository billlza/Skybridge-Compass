import Foundation

@available(macOS 14.0, iOS 17.0, *)
extension CrossNetworkConnectionManager {
    final class OrderedInboundChunkRelay: @unchecked Sendable {
        private let lock = NSLock()
        private let maxPendingOperations: Int
        private let maxPendingBytes: Int
        private var tailTask: Task<Void, Never>?
        private var tailTaskIdentifier: UUID?
        private var ownedTasksByIdentifier: [UUID: Task<Void, Never>] = [:]
        private var pendingOperationCount = 0
        private var pendingBytes = 0
        private var generation = UUID()
        private var acceptingSubmissions = true

        deinit {
            cancel()
        }

        init(
            maxPendingOperations: Int = 128,
            maxPendingBytes: Int = 32 * 1024 * 1024
        ) {
            precondition(maxPendingOperations > 0)
            precondition(maxPendingBytes > 0)
            self.maxPendingOperations = maxPendingOperations
            self.maxPendingBytes = maxPendingBytes
        }

        /// Returns `false` after the bounded backlog is exhausted. Rejection is
        /// terminal for this relay so callers can fail the owning session
        /// closed instead of silently dropping or reordering channel data.
        @discardableResult
        func submit(
            byteCount: Int,
            _ operation: @escaping @Sendable () async -> Void
        ) -> Bool {
            lock.lock()
            guard acceptingSubmissions,
                  byteCount > 0,
                  pendingOperationCount < maxPendingOperations,
                  byteCount <= maxPendingBytes - pendingBytes else {
                let tasksToCancel = transitionToTerminalStateLocked()
                lock.unlock()
                for task in tasksToCancel {
                    task.cancel()
                }
                return false
            }

            let previous = tailTask
            let submissionGeneration = generation
            let submissionIdentifier = UUID()
            pendingOperationCount += 1
            pendingBytes += byteCount
            let next = Task { [weak self] in
                _ = await previous?.result
                defer {
                    self?.completeSubmission(
                        identifier: submissionIdentifier,
                        byteCount: byteCount,
                        generation: submissionGeneration
                    )
                }
                guard !Task.isCancelled else { return }
                await operation()
            }
            tailTask = next
            tailTaskIdentifier = submissionIdentifier
            ownedTasksByIdentifier[submissionIdentifier] = next
            lock.unlock()
            return true
        }

        private func completeSubmission(
            identifier: UUID,
            byteCount: Int,
            generation completedGeneration: UUID
        ) {
            lock.lock()
            defer { lock.unlock() }
            guard ownedTasksByIdentifier.removeValue(forKey: identifier) != nil else {
                return
            }
            if tailTaskIdentifier == identifier {
                tailTask = nil
                tailTaskIdentifier = nil
            }
            guard generation == completedGeneration else { return }
            pendingOperationCount -= 1
            pendingBytes -= byteCount
        }

        func cancel() {
            lock.lock()
            let tasksToCancel = transitionToTerminalStateLocked()
            lock.unlock()
            for task in tasksToCancel {
                task.cancel()
            }
        }

        var ownedTaskCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return ownedTasksByIdentifier.count
        }

        /// Caller must hold `lock`. The task registry remains populated until
        /// each cancelled task actually exits, making uncooperative operations
        /// observable without allowing them to retain submission authority.
        private func transitionToTerminalStateLocked() -> [Task<Void, Never>] {
            acceptingSubmissions = false
            tailTask = nil
            tailTaskIdentifier = nil
            generation = UUID()
            pendingOperationCount = 0
            pendingBytes = 0
            return Array(ownedTasksByIdentifier.values)
        }
    }
}
