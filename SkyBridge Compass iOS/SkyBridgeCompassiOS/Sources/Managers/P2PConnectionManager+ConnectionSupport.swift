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
        private var finished = false
        private var lastState: NWConnection.State?

        func onState(_ state: NWConnection.State) {
            lock.lock()
            defer { lock.unlock() }
            lastState = state
            guard !finished, let continuation else { return }

            switch state {
            case .ready:
                finished = true
                continuation.resume()
                self.continuation = nil
            case .failed(let error):
                finished = true
                continuation.resume(throwing: error)
                self.continuation = nil
            default:
                break
            }
        }

        func waitReady(timeoutSeconds: Double) async throws {
            let gate = self
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await gate.awaitReadyOrFail()
                }

                group.addTask {
                    try? await Task.sleep(for: .seconds(timeoutSeconds))
                    throw P2PError.connectionFailed
                }

                do {
                    _ = try await group.next()
                    group.cancelAll()
                } catch {
                    group.cancelAll()
                    throw error
                }
            }
        }

        private func awaitReadyOrFail() async throws {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                lock.lock()
                // 如果 ready/fail 已经先到，直接返回，避免错过 stateUpdate
                if let last = lastState, !finished {
                    switch last {
                    case .ready:
                        finished = true
                        lock.unlock()
                        cont.resume()
                        return
                    case .failed(let error):
                        finished = true
                        lock.unlock()
                        cont.resume(throwing: error)
                        return
                    default:
                        break
                    }
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
            let gate = self
            return try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask {
                    try await gate.awaitResult()
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(timeoutSeconds))
                    throw P2PConnectionManager.signedLANRefreshFailure("receive timeout")
                }

                do {
                    guard let data = try await group.next() else {
                        throw P2PConnectionManager.signedLANRefreshFailure("receive cancelled")
                    }
                    group.cancelAll()
                    return data
                } catch {
                    group.cancelAll()
                    throw error
                }
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
