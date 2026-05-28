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
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                guard !Task.isCancelled else { return }
                self?.finish(.failure(P2PError.connectionFailed))
            }
            defer { timeoutTask.cancel() }
            try await awaitReadyOrFail()
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
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                guard !Task.isCancelled else { return }
                self?.finish(.failure(P2PConnectionManager.signedLANRefreshFailure("receive timeout")))
            }
            defer { timeoutTask.cancel() }
            return try await awaitResult()
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
        guard ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil else { return }
        let fileName = ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_STATUS_BASENAME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let fileName, !fileName.isEmpty else { return }
        guard let statusURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent(fileName) else {
            return
        }

        let formatted = "[\(ISO8601DateFormatter().string(from: Date()))] \(line)\n"
        guard let data = formatted.data(using: .utf8) else { return }
        try? FileManager.default.createDirectory(
            at: statusURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: statusURL.path),
           let handle = try? FileHandle(forWritingTo: statusURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: statusURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }
}
