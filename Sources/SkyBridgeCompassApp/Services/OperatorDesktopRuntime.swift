import Foundation
import SkyBridgeCore

/// App adapter over the same workspace, decoder and input dispatcher as the UI.
/// Request acceptance, authenticated stream setup and visible frames are separate.
@MainActor
final class OperatorDesktopRuntime {
    static let methods = ["devices", "start", "status", "stop"].map { "crossnet.desktop." + $0 }
    @MainActor private final class Entry {
        let reference = UUID().uuidString
        let device: DiscoveredDevice
        let hostKey: String
        let created = Date()
        var incarnation: UUID?
        var ownsHost = false
        var phase: OperatorDesktopSession.Phase = .connecting
        var error: String?
        var task: Task<Void, Never>?
        init(device: DiscoveredDevice) {
            self.device = device
            hostKey = RemoteControlManager.controlPeerIdentifier(for: device)
        }
    }
    private let workspace: ControlledHostWorkspace
    private let discovery: DeviceDiscoveryManagerOptimized
    private let presentation: OperatorDesktopPresentation
    private var entries: [String: Entry] = [:]

    init(workspace: ControlledHostWorkspace, discovery: DeviceDiscoveryManagerOptimized,
         presentation: OperatorDesktopPresentation) {
        self.workspace = workspace; self.discovery = discovery; self.presentation = presentation
    }

    func execute(_ request: OperatorDesktopRequest) async throws -> OperatorDesktopResult {
        switch request.action {
        case .devices:
            discovery.startScanning()
            try await Task.sleep(for: .seconds(2))
            return OperatorDesktopResult(operation: "devices", devices: targets().map { target in
                let supported = discovery.supportsRemoteControl(target)
                return OperatorDesktopDevice(deviceRef: target.id.uuidString, name: target.name,
                    platform: target.platformName, available: supported,
                    reason: supported ? nil : "remote_host_not_advertised")
            })
        case .start:
            guard let reference = request.reference,
                  let target = targets().first(where: { $0.id.uuidString == reference }),
                  discovery.supportsRemoteControl(target) else {
                throw CrossnetControlFailure.sessionMutationRejected("desktop_target_unavailable")
            }
            let key = RemoteControlManager.controlPeerIdentifier(for: target)
            if let existing = entries.values.first(where: { $0.hostKey == key && !isTerminal(snapshot($0).phase) }) {
                try presentation.present()
                if existing.phase == .ready { try await workspace.focus(sessionId: key) }
                return OperatorDesktopResult(operation: "start", sessions: [snapshot(existing)])
            }
            if entries.count >= 32,
               let oldest = entries.values.filter({ isTerminal(snapshot($0).phase) }).min(by: { $0.created < $1.created }) {
                entries.removeValue(forKey: oldest.reference)
            }
            guard entries.count < 32 else { throw CrossnetControlFailure.sessionMutationRejected("desktop_capacity_reached") }
            try presentation.present()
            let entry = Entry(device: target)
            entry.incarnation = workspace.sessionIncarnation(key)
            entries[entry.reference] = entry
            entry.task = Task { @MainActor [weak self, entry] in
                guard let self else { return }
                await self.start(entry)
            }
            return OperatorDesktopResult(operation: "start", sessions: [snapshot(entry)])
        case .status:
            if let reference = request.reference {
                guard let entry = entries[reference] else {
                    throw CrossnetControlFailure.sessionMutationRejected("desktop_session_not_found")
                }
                return OperatorDesktopResult(operation: "status", sessions: [snapshot(entry)])
            }
            return OperatorDesktopResult(operation: "status", sessions: entries.values
                .sorted { $0.created < $1.created }.map(snapshot))
        case .stop:
            guard let reference = request.reference, let entry = entries[reference] else {
                throw CrossnetControlFailure.sessionMutationRejected("desktop_session_not_found")
            }
            entry.phase = .stopping
            entry.task?.cancel()
            try await retire(entry)
            entry.phase = .closed
            return OperatorDesktopResult(operation: "stop", sessions: [snapshot(entry)])
        }
    }

    private func start(_ entry: Entry) async {
        defer { entry.task = nil }
        do {
            try await workspace.connect(to: entry.device) { [self, entry] in
                try Task.checkCancellation()
                entry.incarnation = workspace.sessionIncarnation(entry.hostKey)
                entry.ownsHost = true
                let connection = try await discovery.makeRemoteControlConnection(to: entry.device)
                return ControlledHostConnection(connection: connection, onAbandon: { connection.cancel() })
            }
            try Task.checkCancellation()
            guard let incarnation = entry.incarnation,
                  workspace.sessionIncarnation(entry.hostKey) == incarnation else {
                throw CrossnetControlFailure.sessionMutationRejected("desktop_session_replaced")
            }
            entry.phase = .waiting_frame
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                let current = snapshot(entry)
                if current.phase == .failed || current.phase == .closed {
                    throw CrossnetControlFailure.sessionMutationRejected("desktop_stream_ended")
                }
                if current.frame_presented && current.window_visible {
                    entry.phase = .ready
                    return
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw CrossnetControlFailure.sessionMutationRejected("desktop_first_frame_timeout")
        } catch {
            // A user stop already owns the final state. A cancelled startup must
            // not subsequently replace that state with a failure or close a new host.
            guard entry.phase != .closed && entry.phase != .stopping else { return }
            entry.error = error is CancellationError ? "desktop_start_cancelled" : failureCode(error)
            do { if entry.ownsHost { try await retire(entry) } }
            catch { entry.error = "desktop_cleanup_failed" }
            entry.phase = .failed
        }
    }

    private func retire(_ entry: Entry) async throws {
        guard let incarnation = entry.incarnation else { return }
        guard workspace.sessionIncarnation(entry.hostKey) == incarnation else { return }
        try await workspace.disconnect(sessionId: entry.hostKey, incarnation: incarnation)
    }

    private func snapshot(_ entry: Entry) -> OperatorDesktopSession {
        let manager = entry.incarnation.flatMap { workspace.manager(for: entry.hostKey, incarnation: $0) }
        var phase = entry.phase
        var error = entry.error
        if !isTerminal(phase), phase != .stopping, entry.incarnation != nil, manager == nil {
            phase = .closed
        } else if manager?.controllingSessionError != nil {
            phase = .failed; error = "desktop_stream_failed"
        }
        let active = !isTerminal(phase)
        let visible = active && presentation.isVisible && workspace.focusedSessionId == entry.hostKey
        let presented = active && (manager?.textureFeed.presentedFrameCount ?? 0) > 0
        if phase == .ready && !presented { phase = .waiting_frame }
        return OperatorDesktopSession(sessionRef: entry.reference, deviceRef: entry.device.id.uuidString,
            name: entry.device.name, phase: phase, windowVisible: visible,
            framePresented: presented, inputAuthorized: active && manager?.viewerInputAccess.canSendInput == true,
            inputReady: visible && presented && workspace.canSendInput(to: entry.hostKey), errorCode: error)
    }

    private func targets() -> [DiscoveredDevice] {
        var seen = Set<String>()
        let account = UnifiedOnlineDeviceManager.shared.onlineDevices.flatMap {
            UnifiedOnlineDeviceManager.shared.resolvedConnectableDiscoveredCandidates(for: $0, limit: 3)
        }
        return (discovery.discoveredDevices + account + P2PDiscoveryService.shared.connectedUSBControlDevices
            + P2PDiscoveryService.shared.discoveredDevices)
            .filter { !$0.isLocalDevice && seen.insert(RemoteControlManager.controlPeerIdentifier(for: $0)).inserted }
    }

    private func isTerminal(_ phase: OperatorDesktopSession.Phase) -> Bool { phase == .closed || phase == .failed }
    private func failureCode(_ error: Error) -> String {
        if case CrossnetControlFailure.sessionMutationRejected(let reason) = error,
           ["desktop_session_replaced", "desktop_stream_ended", "desktop_first_frame_timeout"].contains(reason) { return reason }
        return "desktop_start_failed"
    }
}
