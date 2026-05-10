import Foundation

@available(iOS 17.0, *)
enum SignalingRetryControllerError: Error, LocalizedError, Equatable {
    case invalidWebSocketURL(String)
    case attemptTimedOut

    var errorDescription: String? {
        switch self {
        case .invalidWebSocketURL(let raw):
            return "Invalid WebSocket URL: \(raw)"
        case .attemptTimedOut:
            return "Signaling send attempt timed out"
        }
    }
}

@available(iOS 17.0, *)
struct SignalingRetryController {
    typealias SleepClosure = @Sendable (Duration) async -> Void

    private let retryDelay: Duration
    private let attemptTimeout: Duration
    private let sleep: SleepClosure

    init(
        retryDelay: Duration = .milliseconds(350),
        attemptTimeout: Duration = .seconds(15),
        sleep: @escaping SleepClosure = { duration in
            try? await Task.sleep(for: duration)
        }
    ) {
        self.retryDelay = retryDelay
        self.attemptTimeout = attemptTimeout
        self.sleep = sleep
    }

    static func validatedWebSocketURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              (scheme == "ws" || scheme == "wss"),
              let host = url.host,
              !host.isEmpty else {
            return nil
        }
        return url
    }

    @MainActor
    func sendWithRetry(
        retries: Int,
        reconnectIfNeeded: @MainActor @Sendable () async -> Void,
        send: @escaping @MainActor @Sendable () async throws -> Void
    ) async throws {
        var attemptsLeft = max(0, retries)
        while true {
            do {
                try await runAttempt(send: send)
                return
            } catch {
                if let controllerError = error as? SignalingRetryControllerError,
                   case .invalidWebSocketURL = controllerError {
                    throw controllerError
                }

                if let signalingError = error as? WebSocketSignalingClient.SignalingError,
                   case .notConnected = signalingError {
                    await reconnectIfNeeded()
                }
                guard attemptsLeft > 0 else {
                    throw error
                }
                attemptsLeft -= 1
                await sleep(retryDelay)
            }
        }
    }

    static func testOnlyDefaultAttemptTimeoutSeconds() -> Double {
        durationSeconds(.seconds(15))
    }

    @MainActor
    private func runAttempt(send: @escaping @MainActor @Sendable () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await send()
            }
            group.addTask {
                try await Task.sleep(for: attemptTimeout)
                throw SignalingRetryControllerError.attemptTimedOut
            }

            do {
                _ = try await group.next()
                group.cancelAll()
                while let _ = try? await group.next() {}
            } catch {
                group.cancelAll()
                while let _ = try? await group.next() {}
                throw error
            }
        }
    }

    private static func durationSeconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000.0
    }
}
