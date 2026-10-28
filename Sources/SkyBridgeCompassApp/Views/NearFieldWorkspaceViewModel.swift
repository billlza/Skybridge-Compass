import Foundation
import Combine
import SkyBridgeCore

/// Owns window actions and discovery. Session ownership lives in the workspace.
@MainActor
final class NearFieldWorkspaceViewModel: ObservableObject {
    let discoveryManager: DeviceDiscoveryManagerOptimized
    let workspace: ControlledHostWorkspace
    @Published var showsDevicePicker = true
    @Published var errorMessage: String?
    private struct Action {
        let id: UUID
        let task: Task<Void, Never>
    }
    private var actions: [String: Action] = [:]
    private var lifetime = UUID()

    init(
        discoveryManager: DeviceDiscoveryManagerOptimized = DeviceDiscoveryManagerOptimized(),
        workspace: ControlledHostWorkspace = .shared
    ) {
        self.discoveryManager = discoveryManager
        self.workspace = workspace
    }

    func startDiscovery() { discoveryManager.startScanning() }

    func refreshDiscovery() {
        discoveryManager.stopScanning()
        discoveryManager.startScanning()
    }

    func connect(to device: DiscoveredDevice) {
        let key = RemoteControlManager.controlPeerIdentifier(for: device)
        runAction(key: key) { [self] in
            try await workspace.connect(to: device) { [discoveryManager] in
                let connection = try await discoveryManager.makeRemoteControlConnection(to: device)
                return ControlledHostConnection(connection: connection, onAbandon: { connection.cancel() })
            }
            try Task.checkCancellation()
            showsDevicePicker = false
        }
    }

    func focus(on sessionId: String) {
        runAction(key: "focus") { [self] in
            try await workspace.focus(sessionId: sessionId)
            try Task.checkCancellation()
            showsDevicePicker = false
        }
    }

    func disconnect(_ sessionId: String) {
        actions.removeValue(forKey: sessionId)?.task.cancel()
        runAction(key: "disconnect:\(sessionId)") { [workspace] in
            try await workspace.disconnect(sessionId: sessionId)
        }
    }

    func submitMouseEvent(_ event: RemoteMouseEvent, to sessionId: String) {
        // Focus transitions own the release barrier. AppKit may later release
        // the removed canvas again; never route those duplicate ups to a new host.
        if (event.type == .leftMouseUp || event.type == .rightMouseUp),
           !workspace.canSendInput(to: sessionId) { return }
        do {
            try workspace.submitMouseEvent(event, to: sessionId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func submitKeyboardEvent(_ event: RemoteKeyboardEvent, to sessionId: String) {
        if event.type == .keyUp,
           !workspace.canSendInput(to: sessionId) { return }
        do {
            try workspace.submitKeyboardEvent(event, to: sessionId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func close() {
        lifetime = UUID()
        for action in actions.values { action.task.cancel() }
        actions.removeAll()
        workspace.stopAll()
        discoveryManager.stopScanning()
        showsDevicePicker = true
    }

    private func runAction(key: String, operation: @escaping @MainActor () async throws -> Void) {
        guard actions[key] == nil else { return }
        let generation = lifetime
        errorMessage = nil
        let actionId = UUID()
        let task = Task { @MainActor [weak self] in
            defer {
                if let self, self.lifetime == generation, self.actions[key]?.id == actionId {
                    self.actions.removeValue(forKey: key)
                }
            }
            do {
                try Task.checkCancellation()
                try await operation()
            } catch is CancellationError {
                // Closing the window or cancelling this reservation is explicit.
            } catch {
                guard let self, self.lifetime == generation, self.actions[key]?.id == actionId, !Task.isCancelled else { return }
                self.errorMessage = error.localizedDescription
            }
        }
        actions[key] = Action(id: actionId, task: task)
    }
}
