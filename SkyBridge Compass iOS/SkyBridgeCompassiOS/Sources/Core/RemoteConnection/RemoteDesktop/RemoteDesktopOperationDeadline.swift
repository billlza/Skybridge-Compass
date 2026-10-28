import Foundation

/// Completes one controller I/O operation once, including cancellation before a late callback.
/// Cancellation closes only the resource captured by the caller at operation creation.
@MainActor
final class RemoteDesktopOperationDeadline {
    enum Phase: Sendable, Equatable { case lanWrite, inputRelease }
    enum Failure: Error, LocalizedError, Equatable {
        case expired(Phase)
        var errorDescription: String? {
            switch self {
            case .expired(.lanWrite): return "远程控制消息发送超时，连接已关闭。"
            case .expired(.inputRelease): return "释放远程输入超时，连接已关闭。"
            }
        }
    }

    private var started = false
    private var continuation: CheckedContinuation<Void, any Error>?
    private var timer: Task<Void, Never>?
    private let cancelResource: @MainActor () -> Void

    init(cancelResource: @escaping @MainActor () -> Void) { self.cancelResource = cancelResource }

    func run(timeout: Duration, phase: Phase,
             begin: @MainActor (@escaping @Sendable (Result<Void, any Error>) -> Void) -> Void) async throws {
        precondition(!started, "A deadline owns exactly one operation")
        started = true
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                timer = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) }
                    catch { return }
                    self?.cancel(with: Failure.expired(phase))
                }
                begin { [weak self] result in
                    Task { @MainActor in self?.finish(result) }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(with: CancellationError()) }
        }
    }

    private func cancel(with error: any Error) {
        guard continuation != nil else { return }
        cancelResource()
        finish(.failure(error))
    }

    private func finish(_ result: Result<Void, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timer?.cancel()
        timer = nil
        continuation.resume(with: result)
    }
}
