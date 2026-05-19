import Foundation

@MainActor
final class CrossNetworkSignalingLifecycleCoordinator {
    typealias Phase = WebSocketSignalingClient.SignalingLifecyclePhase
    typealias HandleID = WebSocketSignalingClient.SignalingHandleID
    typealias LifecycleEvent = WebSocketSignalingClient.SignalingLifecycleEvent

    private var generationBySessionId: [String: Int] = [:]
    private var activeHandle: HandleID?
    private var recoveryTasksBySessionId: [String: Task<Void, Never>] = [:]

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
        recoveryTasksBySessionId[sessionID]?.cancel()
        recoveryTasksBySessionId.removeValue(forKey: sessionID)
    }

    func cancelAllRecovery() {
        for (_, task) in recoveryTasksBySessionId {
            task.cancel()
        }
        recoveryTasksBySessionId.removeAll()
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
        recoveryTasksBySessionId[sessionID] = Task { @MainActor [weak self] in
            guard let self else { return }
            let maxAttempts = tokenExpired ? 1 : 3
            for attempt in 0..<maxAttempts where !Task.isCancelled {
                if attempt > 0 {
                    try? await Task.sleep(for: .milliseconds(500 * (attempt + 1)))
                }
                do {
                    try await ensureConnected(sessionID)
                    if currentShardKey() == sessionID {
                        setHealth(.healthy)
                    }
                    self.recoveryTasksBySessionId.removeValue(forKey: sessionID)
                    return
                } catch is CancellationError {
                    self.recoveryTasksBySessionId.removeValue(forKey: sessionID)
                    logCancellation(sessionID, attempt + 1)
                    return
                } catch {
                    logFailure(sessionID, attempt + 1, error)
                }
            }
            if tokenExpired, isHandshakeComplete(sessionID) {
                setHealth(.degradedFatal)
            }
            self.recoveryTasksBySessionId.removeValue(forKey: sessionID)
        }
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
