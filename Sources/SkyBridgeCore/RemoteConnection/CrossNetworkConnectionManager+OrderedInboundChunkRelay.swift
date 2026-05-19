import Foundation

@available(macOS 14.0, iOS 17.0, *)
extension CrossNetworkConnectionManager {
    final class OrderedInboundChunkRelay: @unchecked Sendable {
        private let lock = NSLock()
        private var tailTask: Task<Void, Never>?

        func submit(_ operation: @escaping @Sendable () async -> Void) {
            lock.lock()
            let previous = tailTask
            let next = Task {
                _ = await previous?.result
                guard !Task.isCancelled else { return }
                await operation()
            }
            tailTask = next
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            let task = tailTask
            tailTask = nil
            lock.unlock()
            task?.cancel()
        }
    }
}
