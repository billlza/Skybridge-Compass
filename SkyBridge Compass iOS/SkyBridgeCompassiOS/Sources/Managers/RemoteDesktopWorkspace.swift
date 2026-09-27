import Combine
import Foundation
import SkyBridgeProtocolCore

@MainActor
protocol RemoteDesktopWorkspaceRuntime: AnyObject {
    var objectWillChange: ObservableObjectPublisher { get }
    var isStreaming: Bool { get }
    func startStreaming(from connection: Connection, routeIntent: PeerTransportRouteIntent) async throws
    func pauseWorkspaceStream() async throws
    func waitForWorkspaceConfigurationAcknowledgement() async throws
    func setWorkspaceInputFocus(_ focused: Bool)
    func disconnect(tearDownTransport: Bool) async
}

@available(iOS 17.0, *)
extension RemoteDesktopManager: RemoteDesktopWorkspaceRuntime {}

/// A small mobile workspace: independent LAN transports, one visible media/input lane.
/// Background streams pause after a peer ACK; reconnecting is unnecessary when focus returns.
@MainActor
class RemoteDesktopWorkspaceCoordinator<Runtime: RemoteDesktopWorkspaceRuntime>: ObservableObject {
    struct Session: Identifiable {
        let id: String
        let connection: Connection
        let runtime: Runtime
    }

    enum Failure: Error, LocalizedError, Equatable {
        case atCapacity(Int)
        case operationInProgress
        case sessionUnavailable

        var errorDescription: String? {
            switch self {
            case .atCapacity(let limit): return "最多同时保留 \(limit) 台主机，请先关闭一个会话。"
            case .operationInProgress: return "正在切换远程会话，请等待主机确认。"
            case .sessionUnavailable: return "所选远程会话已结束。"
            }
        }
    }

    @Published private(set) var sessions: [Session] = []
    @Published private(set) var focusedSessionID: String?
    @Published private(set) var isChangingFocus = false
    @Published private(set) var errorMessage: String?
    private let makeRuntime: @MainActor () -> Runtime
    private let reservedExternalHostKeys: @MainActor () -> Set<String>
    private var observations: [String: AnyCancellable] = [:]
    private var isPresentationActive = true

    init(makeRuntime: @escaping @MainActor () -> Runtime,
         reservedExternalHostKeys: @escaping @MainActor () -> Set<String> = { [] }) {
        self.makeRuntime = makeRuntime
        self.reservedExternalHostKeys = reservedExternalHostKeys
    }

    func requireExternalAdmission(hostKey: String) throws {
        let reserved = Set(sessions.map(\.id)).union(reservedExternalHostKeys())
        if case .refusedAtCapacity(let limit, _) = ControlledHostSessionPolicy.admit(hostKey: hostKey, activeHostKeys: reserved) {
            throw Failure.atCapacity(limit)
        }
    }

    var focusedSession: Session? { sessions.first { $0.id == focusedSessionID } }
    func clearError() { errorMessage = nil }

    func hasSession(for deviceID: String) -> Bool { sessions.contains { $0.id == deviceID } }

    func setPresentationActive(_ active: Bool) {
        isPresentationActive = active
        if !active {
            for session in sessions { session.runtime.setWorkspaceInputFocus(false) }
        }
    }


    func connect(_ connection: Connection) async throws {
        guard !isChangingFocus else { throw Failure.operationInProgress }
        let key = connection.device.id
        switch ControlledHostSessionPolicy.admit(hostKey: key, activeHostKeys: Set(sessions.map(\.id)).union(reservedExternalHostKeys())) {
        case .alreadyControlled:
            try await focus(key)
            return
        case .refusedAtCapacity(let limit, _): throw Failure.atCapacity(limit)
        case .admitted: break
        }
        isChangingFocus = true
        defer { isChangingFocus = false }
        // Reserve before the first suspension: connecting attempts count toward the shared limit.
        let runtime = makeRuntime()
        let session = Session(id: key, connection: connection, runtime: runtime)
        sessions.append(session)
        observations[key] = runtime.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        do {
            try await pauseFocusedSession()
            focusedSessionID = key
            try await runtime.startStreaming(from: connection, routeIntent: .directLAN)
            try await runtime.waitForWorkspaceConfigurationAcknowledgement()
            if isPresentationActive {
                runtime.setWorkspaceInputFocus(true)
            } else {
                try await runtime.pauseWorkspaceStream()
                focusedSessionID = nil
            }
            errorMessage = nil
        } catch {
            runtime.setWorkspaceInputFocus(false)
            await runtime.disconnect(tearDownTransport: true)
            sessions.removeAll { $0.id == key }
            observations.removeValue(forKey: key)
            if focusedSessionID == key { focusedSessionID = nil }
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func focus(_ id: String) async throws {
        guard !isChangingFocus else { throw Failure.operationInProgress }
        guard let selected = sessions.first(where: { $0.id == id }) else { throw Failure.sessionUnavailable }
        isChangingFocus = true
        defer { isChangingFocus = false }
        do {
            if focusedSessionID != id { try await pauseFocusedSession() }
            focusedSessionID = id
            if !selected.runtime.isStreaming {
                try await selected.runtime.startStreaming(from: selected.connection, routeIntent: .directLAN)
            }
            try await selected.runtime.waitForWorkspaceConfigurationAcknowledgement()
            if isPresentationActive {
                selected.runtime.setWorkspaceInputFocus(true)
            } else {
                try await selected.runtime.pauseWorkspaceStream()
                focusedSessionID = nil
            }
            errorMessage = nil
        } catch {
            selected.runtime.setWorkspaceInputFocus(false)
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func suspend() async throws {
        guard !isChangingFocus else { throw Failure.operationInProgress }
        isChangingFocus = true
        defer { isChangingFocus = false }
        do {
            try await pauseFocusedSession()
            focusedSessionID = nil
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func close(_ id: String) async throws {
        guard !isChangingFocus else { throw Failure.operationInProgress }
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        isChangingFocus = true
        defer { isChangingFocus = false }
        session.runtime.setWorkspaceInputFocus(false)
        await session.runtime.disconnect(tearDownTransport: true)
        sessions.removeAll { $0.id == id }
        observations.removeValue(forKey: id)
        if focusedSessionID == id { focusedSessionID = nil }
    }

    private func pauseFocusedSession() async throws {
        guard let focusedSession else { return }
        focusedSession.runtime.setWorkspaceInputFocus(false)
        try await focusedSession.runtime.pauseWorkspaceStream()
    }
}

@available(iOS 17.0, *)
@MainActor
final class RemoteDesktopWorkspace: RemoteDesktopWorkspaceCoordinator<RemoteDesktopManager> {
    static let instance = RemoteDesktopWorkspace()

    private init() {
        super.init(makeRuntime: RemoteDesktopManager.makeLANViewer, reservedExternalHostKeys: {
            let primary = RemoteDesktopManager.instance
            guard !primary.isReadOnlyCameraSession, let connection = primary.currentConnection else { return [] }
            return ["primary:\(connection.device.id)"]
        })
    }
}
