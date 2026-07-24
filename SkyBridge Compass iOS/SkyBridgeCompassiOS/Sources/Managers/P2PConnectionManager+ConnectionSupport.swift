import Foundation
import Network

@available(iOS 17.0, *)
extension P2PConnectionManager {
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

        func onState(_ state: NWConnection.State) {
            switch state {
            case .ready:
                finish(.success(()))
            case .failed(let error):
                finish(.failure(error))
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
                self?.finish(.failure(P2PError.connectionFailed))
            }
            defer { timeoutTask.cancel() }
            try await withTaskCancellationHandler {
                try await awaitReadyOrFail()
            } onCancel: { [weak self] in
                self?.finish(.failure(CancellationError()))
            }
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
