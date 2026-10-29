import Foundation
import Network
import SkyBridgeProtocolCore

@available(iOS 17.0, *)
enum NetworkContentProcessedError: Error, LocalizedError, Sendable, Equatable {
    case timedOut(operation: String, transport: String)
    case invalidTimeout
    case emptyOperation
    case emptyTransport
    case concurrentWaiter

    var errorDescription: String? {
        switch self {
        case .timedOut(let operation, let transport):
            return "\(operation) network submission over \(transport) timed out"
        case .invalidTimeout:
            return "Network submission timeout must be finite and greater than zero"
        case .emptyOperation:
            return "Network submission operation must not be empty"
        case .emptyTransport:
            return "Network submission transport must not be empty"
        case .concurrentWaiter:
            return "Network submission already has an active waiter"
        }
    }
}

/// Single-resolution gate for bounded `contentProcessed` submissions. The
/// first callback, timeout, or task cancellation wins; later callbacks are
/// ignored so a transport cannot resume the continuation twice.
@available(iOS 17.0, *)
final class NetworkContentProcessedGate: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    private var continuation: CheckedContinuation<Void, Error>?
    private var submissionClaimed = false

    @discardableResult
    func claimSubmission() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard result == nil, !submissionClaimed else { return false }
        submissionClaimed = true
        return true
    }

    @discardableResult
    func finish(_ result: Result<Void, Error>) -> Bool {
        let continuationToResume: CheckedContinuation<Void, Error>?
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return false
        }
        self.result = result
        continuationToResume = continuation
        continuation = nil
        lock.unlock()
        continuationToResume?.resume(with: result)
        return true
    }

    /// Resolves cancellation and reports whether a transport submission had
    /// already claimed ownership. `nil` means another terminal result won.
    func cancelSubmission() -> Bool? {
        let continuationToResume: CheckedContinuation<Void, Error>?
        let claimed: Bool
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return nil
        }
        claimed = submissionClaimed
        result = .failure(CancellationError())
        continuationToResume = continuation
        continuation = nil
        lock.unlock()
        continuationToResume?.resume(throwing: CancellationError())
        return claimed
    }

    var submissionWasClaimed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return submissionClaimed
    }

    var hasPendingWaiterForTesting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return continuation != nil && result == nil
    }

    func wait(
        timeoutSeconds: TimeInterval,
        operation: String,
        transport: String,
        resolvingTaskCancellation: Bool = true
    ) async throws {
        guard timeoutSeconds.isFinite, timeoutSeconds > 0 else {
            throw NetworkContentProcessedError.invalidTimeout
        }
        guard !operation.isEmpty else {
            throw NetworkContentProcessedError.emptyOperation
        }
        guard !transport.isEmpty else {
            throw NetworkContentProcessedError.emptyTransport
        }
        let timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(timeoutSeconds))
            } catch {
                return
            }
            self?.finish(
                .failure(
                    NetworkContentProcessedError.timedOut(
                        operation: operation,
                        transport: transport
                    )
                )
            )
        }
        defer { timeoutTask.cancel() }
        if resolvingTaskCancellation {
            try await withTaskCancellationHandler {
                try await waitForResult()
            } onCancel: { [weak self] in
                _ = self?.cancelSubmission()
            }
        } else {
            try await waitForResult()
        }
    }

    private func waitForResult() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
                return
            }
            guard self.continuation == nil else {
                lock.unlock()
                continuation.resume(
                    throwing: NetworkContentProcessedError.concurrentWaiter
                )
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }
}

@available(iOS 17.0, *)
private final class NetworkContentProcessedCancellationOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func run(_ action: @Sendable () -> Void) {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        lock.unlock()
        action()
    }
}

@available(iOS 17.0, *)
enum NetworkContentProcessedSubmission {
    static func perform(
        timeoutSeconds: TimeInterval,
        operation: String,
        transport: String,
        submit: @escaping (
            @escaping @Sendable (Result<Void, Error>) -> Void
        ) -> Void,
        cancel: @escaping @Sendable () -> Void
    ) async throws {
        let gate = NetworkContentProcessedGate()
        let cancellation = NetworkContentProcessedCancellationOnce()
        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                guard gate.claimSubmission() else {
                    try await gate.wait(
                        timeoutSeconds: timeoutSeconds,
                        operation: operation,
                        transport: transport,
                        resolvingTaskCancellation: false
                    )
                    return
                }
                submit { result in
                    gate.finish(result)
                }
                try await gate.wait(
                    timeoutSeconds: timeoutSeconds,
                    operation: operation,
                    transport: transport,
                    resolvingTaskCancellation: false
                )
            } onCancel: {
                guard let submissionClaimed = gate.cancelSubmission(),
                      submissionClaimed else { return }
                cancellation.run(cancel)
            }
        } catch {
            if gate.submissionWasClaimed {
                cancellation.run(cancel)
            }
            throw error
        }
    }

    static func send(
        _ content: Data,
        over connection: NWConnection,
        timeoutSeconds: TimeInterval,
        operation: String,
        transport: String
    ) async throws {
        try await perform(
            timeoutSeconds: timeoutSeconds,
            operation: operation,
            transport: transport,
            submit: { completion in
                connection.send(
                    content: content,
                    completion: .contentProcessed { error in
                        if let error {
                            completion(.failure(error))
                        } else {
                            completion(.success(()))
                        }
                    }
                )
            },
            cancel: {
                connection.cancel()
            }
        )
    }
}

@available(iOS 17.0, *)
final class NetworkContentProcessedTaskOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelled = false

    func install(_ task: Task<Void, Never>) {
        lock.lock()
        if cancelled {
            lock.unlock()
            task.cancel()
            return
        }
        self.task = task
        lock.unlock()
    }

    @discardableResult
    func cancel() -> Bool {
        let taskToCancel: Task<Void, Never>?
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return false
        }
        cancelled = true
        taskToCancel = task
        task = nil
        lock.unlock()
        taskToCancel?.cancel()
        return true
    }
}

@available(iOS 17.0, *)
extension P2PConnectionManager {
    enum ConnectionReadyState: String, Sendable, Equatable {
        case setup
        case preparing
        case waiting
        case ready
        case failed
        case cancelled
        case unknown
    }

    struct ConnectionReadyTimeoutError: Error, LocalizedError {
        let lastState: ConnectionReadyState
        let lastWaitingError: NWError?

        var errorDescription: String? {
            if lastWaitingError != nil {
                return "连接建立超时；最后状态为等待网络"
            }
            return "连接建立超时；最后状态为 \(lastState.rawValue)"
        }
    }

    struct ConnectionReadyCancelledError: Error, LocalizedError {
        var errorDescription: String? { "连接在建立完成前被网络栈取消" }
    }

    struct ConnectionAttemptFailure: Error, LocalizedError, Sendable {
        let code: ApplePeerConnectivityPolicy.ConnectionFailureCode

        var errorDescription: String? {
            switch code {
            case .localNetworkPermissionDenied:
                return "本地网络权限被系统拒绝"
            case .transportWaiting:
                return "网络路径仍在等待"
            case .transportFailed:
                return "网络传输连接失败"
            case .transportTimedOut:
                return "网络传输连接超时"
            case .noLiveControlRoute:
                return "当前 Bonjour 浏览周期没有可拨控制路由"
            case .noLiveFileTransferRoute:
                return "当前 Bonjour 浏览周期没有可拨文件传输路由"
            case .noAuthenticatedPeer:
                return "目标设备没有已认证会话"
            case .ambiguousTarget:
                return "目标设备不唯一"
            }
        }
    }

    struct ReadyConnectionResult {
        let connection: NWConnection
        let endpoint: NWEndpoint
        let attemptCount: Int
        let failedAttemptCount: Int
        let connectLatencyMs: Double
        let selectedEndpointPeerToPeer: Bool
        let attemptJitterMs: Double
    }

    // MARK: - Ready Gate (await connection.ready)

    final class ConnectionReadyGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        private var result: Result<Void, Error>?
        private var lastState: ConnectionReadyState = .setup
        private var lastWaitingError: NWError?

        func onState(_ state: NWConnection.State) {
            lock.lock()
            switch state {
            case .setup:
                lastState = .setup
            case .preparing:
                lastState = .preparing
            case .waiting(let error):
                lastState = .waiting
                lastWaitingError = error
            case .ready:
                lastState = .ready
            case .failed:
                lastState = .failed
            case .cancelled:
                lastState = .cancelled
            @unknown default:
                lastState = .unknown
            }
            lock.unlock()

            switch state {
            case .ready:
                finish(.success(()))
            case .failed(let error):
                finish(.failure(error))
            case .cancelled:
                finish(.failure(ConnectionReadyCancelledError()))
            default:
                break
            }
        }

        func waitReady(timeoutSeconds: Double) async throws {
            try Task.checkCancellation()
            let timeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(timeoutSeconds))
                } catch {
                    return
                }
                guard let self else { return }
                self.finish(.failure(self.timeoutError()))
            }
            defer { timeoutTask.cancel() }
            try await withTaskCancellationHandler {
                try await awaitReadyOrFail()
            } onCancel: { [weak self] in
                self?.finish(.failure(CancellationError()))
            }
        }

        private func timeoutError() -> ConnectionReadyTimeoutError {
            lock.lock()
            let error = ConnectionReadyTimeoutError(
                lastState: lastState,
                lastWaitingError: lastWaitingError
            )
            lock.unlock()
            return error
        }

        private func finish(_ result: Result<Void, Error>) {
            lock.lock()
            guard self.result == nil else {
                lock.unlock()
                return
            }
            self.result = result
            let continuation = continuation
            self.continuation = nil
            lock.unlock()

            guard let continuation else { return }
            switch result {
            case .success:
                continuation.resume()
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }

        private func awaitReadyOrFail() async throws {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                lock.lock()
                if let result {
                    lock.unlock()
                    switch result {
                    case .success:
                        cont.resume()
                    case .failure(let error):
                        cont.resume(throwing: error)
                    }
                    return
                }
                continuation = cont
                lock.unlock()
            }
        }
    }

    final class PlainFrameReceiveGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Data, Error>?
        private var result: Result<Data, Error>?

        func finish(_ result: Result<Data, Error>) {
            lock.lock()
            guard self.result == nil else {
                lock.unlock()
                return
            }
            self.result = result
            let continuation = continuation
            self.continuation = nil
            lock.unlock()

            guard let continuation else { return }
            switch result {
            case .success(let data):
                continuation.resume(returning: data)
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }

        func wait(timeoutSeconds: Double) async throws -> Data {
            try Task.checkCancellation()
            let timeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(timeoutSeconds))
                } catch {
                    return
                }
                self?.finish(.failure(P2PConnectionManager.signedLANRefreshFailure("receive timeout")))
            }
            defer { timeoutTask.cancel() }
            return try await withTaskCancellationHandler {
                try await awaitResult()
            } onCancel: { [weak self] in
                self?.finish(.failure(CancellationError()))
            }
        }

        private func awaitResult() async throws -> Data {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                lock.lock()
                if let result {
                    lock.unlock()
                    switch result {
                    case .success(let data):
                        cont.resume(returning: data)
                    case .failure(let error):
                        cont.resume(throwing: error)
                    }
                    return
                }
                continuation = cont
                lock.unlock()
            }
        }
    }
}

enum SignedKEMRefreshSmokeStatusWriter {
    static func append(_ line: String) {
        SkyBridgeDiagnosticTrace.appendStatus(line)
    }
}
