import Foundation

@MainActor
final class CrossNetworkSignalingLifecycleCoordinator {
    typealias Phase = WebSocketSignalingClient.SignalingLifecyclePhase
    typealias HandleID = WebSocketSignalingClient.SignalingHandleID
    typealias LifecycleEvent = WebSocketSignalingClient.SignalingLifecycleEvent

    private var generationBySessionId: [String: Int] = [:]
    private var activeHandle: HandleID?
    private var recoveryTasksBySessionId: [String: Task<Void, Never>] = [:]
    private var recoveryTaskTokensBySessionId: [String: UUID] = [:]

    func generation(for sessionID: String) -> Int {
        generationBySessionId[sessionID] ?? 0
    }

    func nextGeneration(for sessionID: String) -> Int {
        let next = generation(for: sessionID) + 1
        generationBySessionId[sessionID] = next
        return next
    }

    func resetActiveHandle() {
        activeHandle = nil
    }

    func resetAll() {
        cancelAllRecovery()
        generationBySessionId.removeAll()
        activeHandle = nil
    }

    func cancelRecovery(for sessionID: String) {
        recoveryTasksBySessionId.removeValue(forKey: sessionID)?.cancel()
        recoveryTaskTokensBySessionId.removeValue(forKey: sessionID)
    }

    /// Removes every signaling-lifecycle resource owned by one terminal session.
    /// Generation state must not survive a real session teardown because a later
    /// session reusing the identifier would otherwise inherit stale ordering.
    func teardown(sessionID: String) {
        cancelRecovery(for: sessionID)
        generationBySessionId.removeValue(forKey: sessionID)
        if activeHandle?.sessionId == sessionID {
            activeHandle = nil
        }
    }

    func cancelAllRecovery() {
        for (_, task) in recoveryTasksBySessionId {
            task.cancel()
        }
        recoveryTasksBySessionId.removeAll()
        recoveryTaskTokensBySessionId.removeAll()
    }

    func shouldAllowOperation(
        for sessionID: String,
        activeShardKey: String?,
        health: SignalingSessionHealth
    ) throws {
        guard !(health == .degradedFatal && activeShardKey == sessionID) else {
            throw CrossNetworkConnectionManager.SignalingOperationRejection.degradedFatal(sessionID)
        }
    }

    func scheduleRecovery(
        for sessionID: String,
        tokenExpired: Bool,
        maxAttempts: Int,
        reconnectDelayMilliseconds: @escaping @MainActor (_ attempt: Int) -> Int,
        currentShardKey: @escaping @MainActor () -> String?,
        isHandshakeComplete: @escaping @MainActor (String) -> Bool,
        ensureConnected: @escaping @MainActor (String) async throws -> Void,
        setHealth: @escaping @MainActor (SignalingSessionHealth) -> Void,
        logCancellation: @escaping @MainActor (_ sessionID: String, _ attempt: Int) -> Void,
        logFailure: @escaping @MainActor (_ sessionID: String, _ attempt: Int, _ error: Error) -> Void
    ) {
        if let existingTask = recoveryTasksBySessionId[sessionID],
           !existingTask.isCancelled {
            return
        }
        let taskToken = UUID()
        recoveryTaskTokensBySessionId[sessionID] = taskToken
        recoveryTasksBySessionId[sessionID] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishRecoveryTask(sessionID: sessionID, token: taskToken) }
            let effectiveMaxAttempts = tokenExpired ? 1 : max(1, maxAttempts)
            for attempt in 0..<effectiveMaxAttempts where !Task.isCancelled {
                if attempt > 0 {
                    do {
                        try await Task.sleep(for: .milliseconds(reconnectDelayMilliseconds(attempt - 1)))
                    } catch {
                        if self.recoveryTaskTokensBySessionId[sessionID] == taskToken {
                            logCancellation(sessionID, attempt + 1)
                        }
                        return
                    }
                }
                guard self.recoveryTaskTokensBySessionId[sessionID] == taskToken else { return }
                do {
                    try await ensureConnected(sessionID)
                    try Task.checkCancellation()
                    guard self.recoveryTaskTokensBySessionId[sessionID] == taskToken else { return }
                    if currentShardKey() == sessionID {
                        setHealth(.healthy)
                    }
                    return
                } catch is CancellationError {
                    if self.recoveryTaskTokensBySessionId[sessionID] == taskToken {
                        logCancellation(sessionID, attempt + 1)
                    }
                    return
                } catch {
                    guard self.recoveryTaskTokensBySessionId[sessionID] == taskToken else { return }
                    logFailure(sessionID, attempt + 1, error)
                }
            }
            guard self.recoveryTaskTokensBySessionId[sessionID] == taskToken else { return }
            if tokenExpired, isHandshakeComplete(sessionID) {
                setHealth(.degradedFatal)
            }
        }
    }

    private func finishRecoveryTask(sessionID: String, token: UUID) {
        guard recoveryTaskTokensBySessionId[sessionID] == token else { return }
        recoveryTasksBySessionId.removeValue(forKey: sessionID)
        recoveryTaskTokensBySessionId.removeValue(forKey: sessionID)
    }

    func handleLifecycleEvent(
        _ event: LifecycleEvent,
        activeShardKey: String?,
        isHandshakeComplete: (String) -> Bool,
        setPhase: (Phase) -> Void,
        setHealth: (SignalingSessionHealth) -> Void,
        noteDetached: (_ sessionID: String, _ source: String, _ failure: String?, _ fatal: Bool) -> Void
    ) {
        guard event.handleId.sessionId == activeShardKey else { return }

        if event.phase == .connecting || event.phase == .reconnecting {
            guard event.handleId.generation >= generation(for: event.handleId.sessionId) else { return }
            generationBySessionId[event.handleId.sessionId] = event.handleId.generation
            activeHandle = event.handleId
        }

        guard event.handleId.generation == generation(for: event.handleId.sessionId) else { return }
        guard activeHandle == event.handleId else { return }

        setPhase(event.phase)

        switch event.phase {
        case .bound:
            setHealth(.healthy)
        case .closed:
            if CrossNetworkConnectionManager.shouldUseOnDemandSignalingAfterTransportFailure(
                isHandshakeComplete: isHandshakeComplete(event.handleId.sessionId)
            ) {
                noteDetached(
                    event.handleId.sessionId,
                    "lifecycle_closed",
                    "transient_network",
                    false
                )
            }
        case .failed:
            let failureClass = event.failureClass ?? .transientServer
            let sessionID = event.handleId.sessionId
            if CrossNetworkConnectionManager.shouldUseOnDemandSignalingAfterTransportFailure(
                isHandshakeComplete: isHandshakeComplete(sessionID)
            ) {
                noteDetached(
                    sessionID,
                    "lifecycle_failed",
                    failureClass.rawValue,
                    CrossNetworkConnectionManager.isFatalPostTransportFailure(failureClass)
                )
            }
        default:
            break
        }
    }

    func seed(
        sessionID: String,
        generation: Int,
        handle: HandleID?
    ) {
        generationBySessionId[sessionID] = generation
        activeHandle = handle
    }

    func currentHandle() -> HandleID? {
        activeHandle
    }
}
