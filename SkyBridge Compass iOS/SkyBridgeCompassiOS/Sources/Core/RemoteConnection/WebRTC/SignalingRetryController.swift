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
enum SignalingRetryOutcome: Equatable {
    case sent
    case superseded
}

@available(iOS 17.0, *)
struct SignalingRetryController {
    typealias SleepClosure = @Sendable (Duration) async throws -> Void
    typealias AttemptValidator = @MainActor @Sendable () throws -> Void
    typealias SupersessionCheck = @MainActor @Sendable () -> Bool

    private let retryDelay: Duration
    private let attemptTimeout: Duration
    private let sleep: SleepClosure

    init(
        retryDelay: Duration = .milliseconds(350),
        attemptTimeout: Duration = .seconds(15),
        sleep: @escaping SleepClosure = { duration in
            try await Task.sleep(for: duration)
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
    @discardableResult
    func sendWithRetry(
        retries: Int,
        validateCurrentAttempt: @escaping AttemptValidator = {},
        shouldSupersedeCurrentAttempt: @escaping SupersessionCheck = { false },
        reconnectIfNeeded: @MainActor @Sendable () async throws -> Void,
        send: @escaping @MainActor @Sendable () async throws -> Void
    ) async throws -> SignalingRetryOutcome {
        var attemptsLeft = max(0, retries)
        while true {
            try Task.checkCancellation()
            try validateCurrentAttempt()
            try Task.checkCancellation()
            let shouldSupersedeBeforeAttempt = shouldSupersedeCurrentAttempt()
            try Task.checkCancellation()
            if shouldSupersedeBeforeAttempt {
                return .superseded
            }
            do {
                try await runAttempt(
                    validateCurrentAttempt: validateCurrentAttempt,
                    send: send
                )
                try Task.checkCancellation()
                try validateCurrentAttempt()
                try Task.checkCancellation()
                return .sent
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                try validateCurrentAttempt()
                try Task.checkCancellation()
                let shouldSupersedeAfterFailure = shouldSupersedeCurrentAttempt()
                try Task.checkCancellation()
                if shouldSupersedeAfterFailure {
                    return .superseded
                }
                if let controllerError = error as? SignalingRetryControllerError,
                   case .invalidWebSocketURL = controllerError {
                    throw controllerError
                }

                if let signalingError = error as? WebSocketSignalingClient.SignalingError,
                   case .notConnected = signalingError {
                    try await reconnectIfNeeded()
                    try Task.checkCancellation()
                    try validateCurrentAttempt()
                    try Task.checkCancellation()
                    let shouldSupersedeAfterReconnect = shouldSupersedeCurrentAttempt()
                    try Task.checkCancellation()
                    if shouldSupersedeAfterReconnect {
                        return .superseded
                    }
                }
                guard attemptsLeft > 0 else {
                    throw error
                }
                attemptsLeft -= 1
                try await sleep(retryDelay)
                try Task.checkCancellation()
                try validateCurrentAttempt()
                try Task.checkCancellation()
                let shouldSupersedeAfterDelay = shouldSupersedeCurrentAttempt()
                try Task.checkCancellation()
                if shouldSupersedeAfterDelay {
                    return .superseded
                }
            }
        }
    }

#if DEBUG || SKYBRIDGE_TESTING
    static func testOnlyDefaultAttemptTimeoutSeconds() -> Double {
        durationSeconds(.seconds(15))
    }
#endif

    @MainActor
    private func runAttempt(
        validateCurrentAttempt: @escaping AttemptValidator,
        send: @escaping @MainActor @Sendable () async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await validateCurrentAttempt()
                try Task.checkCancellation()
                try await send()
                try Task.checkCancellation()
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
