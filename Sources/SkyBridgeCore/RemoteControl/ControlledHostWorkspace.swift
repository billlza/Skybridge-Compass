#if os(macOS)
import Combine
import Foundation
import Network
import SkyBridgeProtocolCore

public enum ControlledHostSessionState: Sendable, Equatable {
    case connecting
    case connected
    case disconnecting
    case failed
}

public struct ControlledHostSessionSnapshot: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let state: ControlledHostSessionState
    public let error: String?
}

/// A connection awaiting transfer to its session engine. The provider retains
/// responsibility for abandoning this exact connection until that transfer.
@MainActor
public struct ControlledHostConnection {
    public let connection: NWConnection
    private let onAbandon: @MainActor () -> Void

    public init(connection: NWConnection, onAbandon: @escaping @MainActor () -> Void) {
        self.connection = connection
        self.onAbandon = onAbandon
    }

    fileprivate func abandon() { onAbandon() }
}

public enum ControlledHostWorkspaceError: LocalizedError, Equatable {
    case atCapacity(limit: Int)
    case sessionUnavailable(String)
    case inputUnavailable
    case focusQueueFull
    case connectionIdentityMismatch

    public var errorDescription: String? {
        switch self {
        case .atCapacity(let limit):
            return "最多同时连接 \(limit) 台主机，请先断开一个会话。"
        case .sessionUnavailable(let name):
            return "主机会话不可用：\(name)"
        case .inputUnavailable:
            return "当前主机尚未获得输入焦点。"
        case .focusQueueFull:
            return "正在切换主机，请等待当前操作完成。"
        case .connectionIdentityMismatch:
            return "连接返回的主机标识与请求不一致。"
        }
    }
}

/// The workspace owns admission, focus and session lifetimes. Each engine keeps
/// its existing single-host transport, decoder, frame feed and audio ownership.
@MainActor
public final class ControlledHostWorkspace: ObservableObject {
    public static let shared = ControlledHostWorkspace()

    @Published public private(set) var sessions: [ControlledHostSessionSnapshot] = []
    @Published public private(set) var focusedSessionId: String?
    @Published public private(set) var isSwitchingFocus = false
    @Published public private(set) var lastError: String?
    public let concurrentHostLimit: Int

    public var focusedManager: RemoteControlManager? {
        guard let focusedSessionId else { return nil }
        return entries[focusedSessionId]?.engine.remoteControlManager
    }

    @MainActor
    private final class Entry {
        let id: String
        let incarnation: UUID
        let device: DiscoveredDevice
        let engine: any ControlledHostSessionEngine
        var state: ControlledHostSessionState = .connecting
        var error: String?
        var input: RemoteControlViewerInputDispatcher?
        var inputAccess = RemoteControlAccessTracker()
        var connectionTask: Task<Void, Error>?
        var failureSubscription: AnyCancellable?
        var inputAccessSubscription: AnyCancellable?
        let onInputFailure: @MainActor (UUID, String) -> Void

        init(
            id: String,
            device: DiscoveredDevice,
            engine: any ControlledHostSessionEngine,
            onFailure: @escaping @MainActor (UUID, String) -> Void
        ) {
            let incarnation = UUID()
            self.id = id
            self.incarnation = incarnation
            self.device = device
            self.engine = engine
            self.onInputFailure = onFailure
        }
    }

    private let makeEngine: @MainActor () -> any ControlledHostSessionEngine
    private var entries: [String: Entry] = [:]
    private var sessionOrder: [String] = []
    private var recentFocusOrder: [String] = []
    private var focusTasks: [UUID: Task<Void, Error>] = [:]
    private var lastFocusTask: Task<Void, Error>?
    private static let maximumPendingFocusChanges = 16

    public convenience init(
        concurrentHostLimit: Int = ControlledHostSessionPolicy.defaultConcurrentHostLimit
    ) {
        self.init(concurrentHostLimit: concurrentHostLimit) {
            RemoteControlManager(controlledHostStreamTier: .background)
        }
    }

    init(
        concurrentHostLimit: Int,
        makeEngine: @escaping @MainActor () -> any ControlledHostSessionEngine
    ) {
        self.concurrentHostLimit = max(1, concurrentHostLimit)
        self.makeEngine = makeEngine
    }

    /// Reserves capacity before awaiting discovery or connection establishment.
    /// Repeated requests for the same host join the existing attempt.
    public func connect(
        to device: DiscoveredDevice,
        connectionProvider: @escaping @MainActor () async throws -> ControlledHostConnection
    ) async throws {
        try Task.checkCancellation()
        let id = RemoteControlManager.controlPeerIdentifier(for: device)
        if let existing = entries[id], existing.state != .failed {
            if let task = existing.connectionTask { try await task.value }
            try Task.checkCancellation()
            guard isCurrent(existing), existing.state == .connected else {
                throw ControlledHostWorkspaceError.sessionUnavailable(device.name)
            }
            try await focus(sessionId: id)
            return
        }

        switch ControlledHostSessionPolicy.admit(
            hostKey: id,
            activeHostKeys: activeHostKeys,
            limit: concurrentHostLimit
        ) {
        case .admitted:
            break
        case .alreadyControlled:
            throw ControlledHostWorkspaceError.sessionUnavailable(device.name)
        case .refusedAtCapacity(let limit, _):
            let error = ControlledHostWorkspaceError.atCapacity(limit: limit)
            lastError = error.localizedDescription
            throw error
        }

        if let failed = entries[id] { remove(failed) }
        let entry = Entry(id: id, device: device, engine: makeEngine()) { [weak self] incarnation, message in
            guard let self, let entry = self.entries[id], entry.incarnation == incarnation else { return }
            self.handleEngineFailure(message, for: entry)
        }
        entries[id] = entry
        sessionOrder.append(id)
        entry.failureSubscription = entry.engine.failurePublisher
            .compactMap { $0 }
            .sink { [weak self, weak entry] message in
                MainActor.assumeIsolated {
                    guard let self, let entry else { return }
                    self.handleEngineFailure(message, for: entry)
                }
            }
        entry.inputAccessSubscription = entry.engine.inputAccessPublisher
            .removeDuplicates()
            .sink { [weak self, weak entry] access in
                MainActor.assumeIsolated {
                    guard let self, let entry else { return }
                    self.updateInputAccess(access, for: entry)
                }
            }
        lastError = nil
        publishSessions()

        let task = Task { @MainActor [weak self, entry] in
            guard let self else { throw CancellationError() }
            try await self.establish(entry, connectionProvider: connectionProvider)
        }
        entry.connectionTask = task
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard isCurrent(entry), entry.state == .connected else {
                throw CancellationError()
            }
            try Task.checkCancellation()
            try await focus(sessionId: id)
        } catch {
            if error is CancellationError, isCurrent(entry) {
                remove(entry)
                publishSessions()
            }
            throw error
        }
    }

    /// All focus changes share one bounded serial barrier. The old host releases
    /// held input and acknowledges its background budget before the next host
    /// can receive input or audio.
    public func focus(sessionId: String) async throws {
        try Task.checkCancellation()
        guard let target = entries[sessionId], target.state == .connected else {
            throw ControlledHostWorkspaceError.sessionUnavailable(sessionId)
        }
        if focusedSessionId == sessionId, focusTasks.isEmpty { return }
        guard focusTasks.count < Self.maximumPendingFocusChanges else {
            let error = ControlledHostWorkspaceError.focusQueueFull
            lastError = error.localizedDescription
            throw error
        }
        let operationId = UUID()
        let previous = lastFocusTask
        let task = Task { @MainActor [weak self, target] in
            // Each caller receives its own command's error. An earlier command's
            // completion releases this barrier even when that command failed.
            if let previous { _ = await previous.result }
            try Task.checkCancellation()
            guard let self else { throw CancellationError() }
            try await self.changeFocus(to: target)
        }
        focusTasks[operationId] = task
        lastFocusTask = task
        isSwitchingFocus = true
        defer {
            focusTasks.removeValue(forKey: operationId)
            if focusTasks.isEmpty {
                lastFocusTask = nil
                isSwitchingFocus = false
            }
        }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    public func disconnect(sessionId: String) async throws {
        guard let entry = entries[sessionId] else { return }
        let removedFocus = focusedSessionId == sessionId
        entry.state = .disconnecting
        publishSessions()
        remove(entry)
        publishSessions()
        if removedFocus, let next = nextConnectedHost(afterRemoving: sessionId) {
            try await focus(sessionId: next)
        }
    }

    /// Window closure retires all exact engines synchronously. Cancelled
    /// providers that return later still abandon their own untransferred socket.
    public func stopAll() {
        for task in focusTasks.values { task.cancel() }
        focusTasks.removeAll()
        lastFocusTask = nil
        isSwitchingFocus = false
        for entry in Array(entries.values) { remove(entry) }
        focusedSessionId = nil
        recentFocusOrder.removeAll()
        lastError = nil
        publishSessions()
    }

    public func submitMouseEvent(_ event: RemoteMouseEvent, to sessionId: String) throws {
        try focusedInput(for: sessionId).submitMouse(event)
    }

    public func submitKeyboardEvent(_ event: RemoteKeyboardEvent, to sessionId: String) throws {
        try focusedInput(for: sessionId).submitKeyboard(event)
    }

    public func clearError() { lastError = nil }

    public func canSendInput(to sessionId: String) -> Bool {
        !isSwitchingFocus && focusedSessionId == sessionId
            && entries[sessionId]?.state == .connected
            && entries[sessionId]?.inputAccess.canSendInput == true
            && entries[sessionId]?.input != nil
    }

    private var activeHostKeys: Set<String> {
        Set(entries.values.filter { $0.state != .failed }.map(\.id))
    }

    private func establish(
        _ entry: Entry,
        connectionProvider: @MainActor () async throws -> ControlledHostConnection
    ) async throws {
        defer { if isCurrent(entry) { entry.connectionTask = nil } }
        do {
            try Task.checkCancellation()
            let offered = try await connectionProvider()
            guard isCurrent(entry), !Task.isCancelled, entry.state == .connecting else {
                offered.abandon()
                throw CancellationError()
            }
            // The engine owns transport teardown from this call onward.
            let resolvedId = try await entry.engine.startControlledHostSession(
                device: entry.device,
                connection: offered.connection
            )
            guard isCurrent(entry), !Task.isCancelled, entry.state == .connecting else {
                entry.engine.stopControlling(deviceId: entry.id)
                throw CancellationError()
            }
            guard resolvedId == entry.id else {
                throw ControlledHostWorkspaceError.connectionIdentityMismatch
            }
            entry.state = .connected
            publishSessions()
        } catch {
            if isCurrent(entry), entry.state != .failed {
                if error is CancellationError {
                    remove(entry)
                    publishSessions()
                } else {
                    fail(entry, message: error.localizedDescription)
                }
            }
            throw error
        }
    }

    private func changeFocus(to target: Entry) async throws {
        guard isCurrent(target), target.state == .connected else {
            throw ControlledHostWorkspaceError.sessionUnavailable(target.device.name)
        }
        if focusedSessionId == target.id { return }
        if let oldId = focusedSessionId, let old = entries[oldId] {
            focusedSessionId = nil
            do {
                do {
                    try await old.input?.deactivate()
                } catch RemoteControlViewerInputFailure.accessRevoked {
                    // The authenticated host handoff already released that
                    // grant; it is safe to continue demoting its viewing stream.
                }
                guard isCurrent(old), old.state == .connected else { throw CancellationError() }
                try await old.engine.setControlledHostStreamTier(.background, deviceId: old.id)
            } catch {
                if isCurrent(old), old.state != .failed {
                    fail(old, message: error.localizedDescription)
                }
                throw error
            }
        }
        try Task.checkCancellation()
        guard isCurrent(target), target.state == .connected else { throw CancellationError() }
        do {
            try await target.engine.setControlledHostStreamTier(.focused, deviceId: target.id)
            guard isCurrent(target), target.state == .connected, !Task.isCancelled else {
                throw CancellationError()
            }
            try target.input?.activate()
            focusedSessionId = target.id
            recentFocusOrder.removeAll { $0 == target.id }
            recentFocusOrder.insert(target.id, at: 0)
            lastError = nil
        } catch {
            if isCurrent(target), target.state != .failed {
                fail(target, message: error.localizedDescription)
            }
            throw error
        }
    }

    private func focusedInput(for sessionId: String) throws -> RemoteControlViewerInputDispatcher {
        guard canSendInput(to: sessionId), let input = entries[sessionId]?.input else {
            throw ControlledHostWorkspaceError.inputUnavailable
        }
        return input
    }

    private func updateInputAccess(_ access: RemoteControlAccessTracker, for entry: Entry) {
        guard isCurrent(entry), entry.state != .failed,
              entry.inputAccess != access else { return }
        entry.input?.revokeAccess()
        entry.input = nil
        entry.inputAccess = access
        guard access.canSendInput else { return }

        // This queue lifetime is bound to an immutable grant. In-flight sends
        // retain the same lease even when a new grant arrives while suspended.
        let lease = access.access?.lease
        let engine = entry.engine
        let id = entry.id
        let incarnation = entry.incarnation
        let onFailure = entry.onInputFailure
        let input = RemoteControlViewerInputDispatcher(
            send: { event in
                switch event {
                case .mouse(let event):
                    try await engine.sendMouseEvent(event, to: id, inputControlLease: lease)
                case .keyboard(let event):
                    try await engine.sendKeyboardEvent(event, to: id, inputControlLease: lease)
                }
            },
            onFailure: { failure in onFailure(incarnation, failure.localizedDescription) }
        )
        entry.input = input
        if focusedSessionId == entry.id {
            do {
                try input.activate()
            } catch {
                fail(entry, message: error.localizedDescription)
            }
        }
    }

    private func handleEngineFailure(_ message: String, for entry: Entry) {
        guard isCurrent(entry), entry.state != .failed else { return }
        let lostFocus = focusedSessionId == entry.id
        fail(entry, message: message)
        if lostFocus,
           let nextId = nextConnectedHost(afterRemoving: entry.id),
           let next = entries[nextId] {
            Task { @MainActor [weak self, next] in
                guard let self, self.isCurrent(next), next.state == .connected else { return }
                do {
                    try await self.focus(sessionId: next.id)
                } catch {
                    guard self.isCurrent(next), !Task.isCancelled else { return }
                    if !(error is CancellationError) { self.lastError = error.localizedDescription }
                }
            }
        }
    }

    private func fail(_ entry: Entry, message: String) {
        guard isCurrent(entry) else { return }
        entry.state = .failed
        entry.error = message
        entry.connectionTask?.cancel()
        entry.input?.close()
        entry.input = nil
        entry.engine.stopControlling(deviceId: entry.id)
        if focusedSessionId == entry.id { focusedSessionId = nil }
        lastError = message
        // Failed rows are reviewable, but the workspace is not a connection
        // history store. Retain at most one capacity's worth of failed rows.
        let failed = sessionOrder.compactMap { entries[$0] }.filter { $0.state == .failed }
        for expired in failed.prefix(max(0, failed.count - concurrentHostLimit)) { remove(expired) }
        publishSessions()
    }

    private func remove(_ entry: Entry) {
        guard isCurrent(entry) else { return }
        entries.removeValue(forKey: entry.id)
        sessionOrder.removeAll { $0 == entry.id }
        recentFocusOrder.removeAll { $0 == entry.id }
        entry.failureSubscription?.cancel()
        entry.inputAccessSubscription?.cancel()
        entry.connectionTask?.cancel()
        entry.input?.close()
        entry.input = nil
        entry.engine.stopControlling(deviceId: entry.id)
        if focusedSessionId == entry.id { focusedSessionId = nil }
    }

    private func nextConnectedHost(afterRemoving id: String) -> String? {
        let connected = recentFocusOrder + sessionOrder.filter { !recentFocusOrder.contains($0) }
        return ControlledHostSessionPolicy.focusedHost(
            afterRemoving: id,
            remaining: connected.filter { entries[$0]?.state == .connected },
            currentFocus: focusedSessionId
        )
    }

    private func isCurrent(_ entry: Entry) -> Bool { entries[entry.id] === entry }

    private func publishSessions() {
        sessions = sessionOrder.compactMap { id in
            guard let entry = entries[id] else { return nil }
            return ControlledHostSessionSnapshot(
                id: id, name: entry.device.name, state: entry.state, error: entry.error
            )
        }
    }
}

@MainActor
protocol ControlledHostSessionEngine: AnyObject {
    var remoteControlManager: RemoteControlManager? { get }
    var failurePublisher: AnyPublisher<String?, Never> { get }
    var viewerInputAccess: RemoteControlAccessTracker { get }
    var inputAccessPublisher: AnyPublisher<RemoteControlAccessTracker, Never> { get }
    func startControlledHostSession(device: DiscoveredDevice, connection: NWConnection) async throws -> String
    func setControlledHostStreamTier(_ tier: ControlledHostSessionPolicy.StreamTier, deviceId: String) async throws
    func sendMouseEvent(_ event: RemoteMouseEvent, to deviceId: String, inputControlLease: UUID?) async throws
    func sendKeyboardEvent(_ event: RemoteKeyboardEvent, to deviceId: String, inputControlLease: UUID?) async throws
    func stopControlling(deviceId: String)
}

extension RemoteControlManager: ControlledHostSessionEngine {
    var remoteControlManager: RemoteControlManager? { self }
    var failurePublisher: AnyPublisher<String?, Never> { $controllingSessionError.eraseToAnyPublisher() }
    var inputAccessPublisher: AnyPublisher<RemoteControlAccessTracker, Never> { $viewerInputAccess.eraseToAnyPublisher() }
}
#endif
