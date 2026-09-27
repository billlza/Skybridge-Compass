import Foundation
import SkyBridgeProtocolCore

/// One explicit workspace pause/resume waits for the existing exact-transaction ACK path.
@MainActor
final class RemoteDesktopConfigurationWaiter {
    enum Failure: Error { case superseded }
    private struct Pending {
        let id: UUID
        let transaction: RemoteDesktopStreamConfigurationTransaction
        let continuation: CheckedContinuation<Void, any Error>
        let timeout: Task<Void, Never>
    }
    private var pending: Pending?

    func wait(for transaction: RemoteDesktopStreamConfigurationTransaction,
              timeout: Duration = .seconds(10)) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                fail(CancellationError())
                let task = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) }
                    catch { return }
                    guard self?.pending?.id == id else { return }
                    self?.fail(RemoteDesktopError.timeout)
                }
                pending = Pending(id: id, transaction: transaction,
                                  continuation: continuation, timeout: task)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.pending?.id == id else { return }
                self?.fail(CancellationError())
            }
        }
    }

    func acknowledge(_ transaction: RemoteDesktopStreamConfigurationTransaction) {
        guard let pending, pending.transaction == transaction else { return }
        self.pending = nil
        pending.timeout.cancel()
        pending.continuation.resume()
    }

    func fail(_ error: any Error) {
        guard let pending else { return }
        self.pending = nil
        pending.timeout.cancel()
        pending.continuation.resume(throwing: error)
    }
}
