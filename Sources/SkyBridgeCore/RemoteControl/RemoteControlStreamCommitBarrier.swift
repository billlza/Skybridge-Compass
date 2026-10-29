#if os(macOS)
import Foundation
import SkyBridgeProtocolCore

/// One pump's ACK write/commit boundary. END follows a pending write even when the
/// main actor has already retired its peer. This is not an independent session owner.
final class RemoteControlStreamCommitBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private var epoch = UUID()
    private var acceptsAcknowledgements = true
    private var pending: (id: UUID, task: Task<Void, Error>)?
    private var committed: RemoteDesktopSessionTerminationContract?

    func closeAcknowledgementAdmission() { lock.withLock { acceptsAcknowledgements = false } }

    func reset() {
        let task = lock.withLock {
            epoch = UUID()
            committed = nil
            let previous = pending?.task
            pending = nil
            return previous
        }
        task?.cancel()
    }

    func acknowledge(_ acknowledgement: RemoteDesktopStreamConfigurationAcknowledgement,
                     write: @escaping @Sendable () async throws -> Void) async throws {
        let operation = try lock.withLock {
            guard acceptsAcknowledgements, pending == nil else { throw BoundaryError.notAcceptingAcknowledgements }
            let expectedEpoch = epoch
            let id = UUID()
            let task = Task { [weak self] in
                try Task.checkCancellation()
                try await write()
                try Task.checkCancellation()
                guard let self else { throw CancellationError() }
                try self.lock.withLock {
                    guard self.epoch == expectedEpoch else { throw CancellationError() }
                    self.committed = RemoteDesktopSessionTerminationContract(acknowledgement: acknowledgement)
                }
            }
            pending = (id, task)
            return (id, task)
        }
        try await operation.1.value
        lock.withLock { if pending?.id == operation.0 { pending = nil } }
    }

    func termination(reason: RemoteDesktopSessionTermination.Reason) async throws -> RemoteDesktopSessionTermination? {
        let snapshot = lock.withLock { (epoch, pending?.task) }
        try await snapshot.1?.value
        return try lock.withLock {
            guard epoch == snapshot.0 else { throw CancellationError() }
            return committed.map { RemoteDesktopSessionTermination(transaction: $0.transaction, reason: reason) }
        }
    }

    enum BoundaryError: Error { case notAcceptingAcknowledgements }
}
#endif
