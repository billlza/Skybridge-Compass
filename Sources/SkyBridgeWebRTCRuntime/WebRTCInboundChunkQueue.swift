import Foundation
import enum SkyBridgeProtocolCore.WebRTCFramedPayloadPolicy

/// A bounded, fail-closed byte queue for WebRTC data-channel callbacks.
///
/// Network callbacks cannot apply backpressure synchronously, so this queue
/// enforces both the shared per-message wire limit and an aggregate backlog
/// limit before waking a consumer or retaining the bytes.
@available(macOS 14.0, iOS 17.0, *)
public actor WebRTCInboundChunkQueue {
    public enum QueueError: Error, Sendable, Equatable {
        case finished
        case invalidReadLimit
        case overflow
    }

    public enum PushResult: Sendable, Equatable {
        case accepted
        case closed
        case overflow
    }

    private struct Waiter {
        let token: UUID
        let maximumReadByteCount: Int?
        let continuation: CheckedContinuation<Data, Error>
    }

    private var pending: [Data] = []
    private var pendingBytes = 0
    private var waiters: [Waiter] = []
    private var finished = false
    private var overflowed = false
    private let maximumChunkByteCount: Int
    private let maximumPendingByteCount: Int
    private let maximumPendingChunkCount: Int

    public init(
        maximumChunkByteCount: Int = WebRTCFramedPayloadPolicy.maximumPayloadByteCount,
        maxPendingBytes: Int = 32 * 1024 * 1024,
        maxPendingChunks: Int = 1_024
    ) {
        precondition(maximumChunkByteCount > 0)
        precondition(
            maximumChunkByteCount <= WebRTCFramedPayloadPolicy.maximumPayloadByteCount
        )
        precondition(maxPendingBytes > 0)
        precondition(maxPendingChunks > 0)
        precondition(maximumChunkByteCount <= maxPendingBytes)
        self.maximumChunkByteCount = maximumChunkByteCount
        self.maximumPendingByteCount = maxPendingBytes
        self.maximumPendingChunkCount = maxPendingChunks
    }

    public func push(_ data: Data) -> PushResult {
        guard !finished, !overflowed else { return .closed }
        guard !data.isEmpty, data.count <= maximumChunkByteCount else {
            failOverflow()
            return .overflow
        }
        if pending.count >= maximumPendingChunkCount
            || data.count > maximumPendingByteCount - pendingBytes {
            failOverflow()
            return .overflow
        }
        pending.append(data)
        pendingBytes += data.count
        resumeWaitingConsumersFromPendingData()
        return .accepted
    }

    public func failOverflow() {
        guard !overflowed, !finished else { return }
        overflowed = true
        pending.removeAll()
        pendingBytes = 0
        let activeWaiters = waiters
        waiters.removeAll()
        activeWaiters.forEach { $0.continuation.resume(throwing: QueueError.overflow) }
    }

    public func finish() {
        guard !finished else { return }
        finished = true
        pending.removeAll()
        pendingBytes = 0
        let activeWaiters = waiters
        waiters.removeAll()
        activeWaiters.forEach { $0.continuation.resume(throwing: QueueError.finished) }
    }

    public func next() async throws -> Data {
        try Task.checkCancellation()
        if !pending.isEmpty {
            let chunk = removeFirstPendingChunk(maximumReadByteCount: nil)
            try Task.checkCancellation()
            return chunk
        }
        if overflowed { throw QueueError.overflow }
        if finished { throw QueueError.finished }
        let token = UUID()
        let chunk = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(
                    Waiter(
                        token: token,
                        maximumReadByteCount: nil,
                        continuation: continuation
                    )
                )
            }
        } onCancel: {
            Task { await self.cancelWaiter(token: token) }
        }
        try Task.checkCancellation()
        return chunk
    }

    public func next(max: Int) async throws -> Data {
        guard max > 0 else {
            throw QueueError.invalidReadLimit
        }
        try Task.checkCancellation()
        if !pending.isEmpty {
            let chunk = removeFirstPendingChunk(maximumReadByteCount: max)
            resumeWaitingConsumersFromPendingData()
            try Task.checkCancellation()
            return chunk
        }
        if overflowed { throw QueueError.overflow }
        if finished { throw QueueError.finished }
        let token = UUID()
        let chunk = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(
                    Waiter(
                        token: token,
                        maximumReadByteCount: max,
                        continuation: continuation
                    )
                )
            }
        } onCancel: {
            Task { await self.cancelWaiter(token: token) }
        }
        try Task.checkCancellation()
        return chunk
    }

    private func cancelWaiter(token: UUID) {
        guard let index = waiters.firstIndex(where: { $0.token == token }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func removeFirstPendingChunk(maximumReadByteCount: Int?) -> Data {
        let first = pending.removeFirst()
        pendingBytes -= first.count
        guard let maximumReadByteCount, first.count > maximumReadByteCount else {
            return first
        }

        let head = Data(first.prefix(maximumReadByteCount))
        let tail = Data(first.dropFirst(maximumReadByteCount))
        pending.insert(tail, at: 0)
        pendingBytes += tail.count
        return head
    }

    private func resumeWaitingConsumersFromPendingData() {
        while !waiters.isEmpty, !pending.isEmpty {
            let waiter = waiters.removeFirst()
            let chunk = removeFirstPendingChunk(
                maximumReadByteCount: waiter.maximumReadByteCount
            )
            waiter.continuation.resume(returning: chunk)
        }
    }

#if DEBUG || SKYBRIDGE_TESTING
    public func testOnlyWaiterCount() -> Int {
        waiters.count
    }
#endif
}
