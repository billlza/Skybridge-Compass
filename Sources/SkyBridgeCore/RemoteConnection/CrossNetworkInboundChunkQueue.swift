import Foundation

extension CrossNetworkConnectionManager {
    actor InboundChunkQueue {
        private var pending: [Data] = []
        private var pendingBytes = 0
        private var waiters: [CheckedContinuation<Data, Error>] = []
        private var finished = false
        private var overflowed = false

 /// 未消费数据的字节高水位。生产端（WebRTC data channel 回调）是同步 push，
 /// 无法在此施加真正的背压；因此设置一个宽松上限作为 OOM/DoS 防线：
 /// 正常文件传输的瞬时积压远低于此值，仅当消费端长期停滞或对端恶意灌注时触发。
 /// 触发后 fail-closed（显式 overflow 错误中止该传输），优于整进程 OOM 崩溃。
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
            if let w = waiters.first {
                waiters.removeFirst()
                w.resume(returning: data)
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
            let ws = waiters
            waiters.removeAll()
            ws.forEach { $0.resume(throwing: QueueError.overflow) }
        }

        func finish() {
            finished = true
            let ws = waiters
            waiters.removeAll()
            ws.forEach { $0.resume(throwing: QueueError.finished) }
        }

        func next() async throws -> Data {
            if let first = pending.first {
                pending.removeFirst()
                pendingBytes -= first.count
                return first
            }
            if overflowed { throw QueueError.overflow }
            if finished { throw QueueError.finished }
            return try await withCheckedThrowingContinuation { c in
                waiters.append(c)
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
}
