import Foundation
import SkyBridgeProtocolCore

/// Input ownership for already-authorized viewers. Admission and visible user
/// decisions belong to the notice center; transport/HID effects stay in engines.
@MainActor
final class RemoteControlHostAccessCoordinator {
    struct Handlers {
        let releaseInput: @MainActor () throws -> Void
        let publishAccess: @MainActor (RemoteControlAccess) async throws -> Void
    }

    enum Failure: Error, LocalizedError {
        case atCapacity
        case unavailable
        case handoffInProgress
        case localInputReclaimed

        var errorDescription: String? {
            switch self {
            case .atCapacity: "远程观看会话已达到上限"
            case .unavailable: "远程控制会话已结束"
            case .handoffInProgress: "正在交接输入权，请等待完成"
            case .localInputReclaimed: "本机已收回键盘和鼠标控制权"
            }
        }
    }

    private final class Entry {
        let handlers: Handlers
        var access: RemoteControlAccess?
        var isReady = false
        init(handlers: Handlers) { self.handlers = handlers }
    }

    private let limit: Int
    private let changed: @MainActor () -> Void
    private var entries: [UUID: Entry] = [:]
    private var operation: UUID?
    private var localInputGeneration = UUID()
    private(set) var controllerID: UUID?
    var isTransferring: Bool { operation != nil }

    init(limit: Int, changed: @escaping @MainActor () -> Void) {
        precondition(limit > 0)
        self.limit = limit
        self.changed = changed
    }

    func register(id: UUID, handlers: Handlers) throws {
        guard entries[id] == nil else { throw Failure.unavailable }
        guard entries.count < limit else { throw Failure.atCapacity }
        entries[id] = Entry(handlers: handlers)
    }

    func isRegistered(_ id: UUID) -> Bool { entries[id] != nil }
    func access(for id: UUID) -> RemoteControlAccess? { entries[id]?.access }
    func isReady(_ id: UUID) -> Bool { entries[id]?.isReady == true }
    func markReady(_ id: UUID) {
        guard let entry = entries[id], entry.access != nil else { return }
        entry.isReady = true
        changed()
    }

    func approve(id: UUID, allowsInitialInput: Bool) throws {
        guard let entry = entries[id], entry.access == nil else { throw Failure.unavailable }
        let isFirstViewer = entries.values.allSatisfy { $0.access == nil }
        let grantsInput = isFirstViewer && operation == nil && allowsInitialInput
        entry.access = try RemoteControlAccess(
            revision: 1,
            role: grantsInput ? .controller : .observer,
            lease: grantsInput ? UUID() : nil
        )
        if grantsInput { controllerID = id }
        changed()
    }

    func permitsInput(id: UUID, lease: UUID?) -> Bool {
        guard controllerID == id, let expected = entries[id]?.access?.lease else { return false }
        return lease == expected
    }

    /// Local input invalidates the lease and releases held HID state before
    /// returning to event dispatch. Publishing the observer receipt may suspend;
    /// neither queued input nor a suspended handoff can restore this old lease.
    func reclaimForLocalInput() throws -> UUID? {
        localInputGeneration = UUID()
        guard let id = controllerID, let entry = entries[id] else { return nil }
        controllerID = nil
        entry.access = try nextAccess(for: entry, role: .observer)
        changed()
        try entry.handlers.releaseInput()
        return id
    }

    func publishLocalReclamation(for id: UUID) async throws {
        guard let entry = entries[id], let access = entry.access, access.role == .observer else {
            throw Failure.unavailable
        }
        try await entry.handlers.publishAccess(access)
    }

    /// The old grant is invalidated before any suspension or release. Failure
    /// leaves no new controller; it never restores a possibly-observed grant.
    func transfer(to id: UUID) async throws {
        guard operation == nil else { throw Failure.handoffInProgress }
        guard let target = entries[id], target.access != nil, target.isReady else { throw Failure.unavailable }
        if controllerID == id { return }
        let token = UUID()
        let localGeneration = localInputGeneration
        operation = token
        changed()
        defer {
            if operation == token { operation = nil }
            changed()
        }

        let previousID = controllerID
        let previous = previousID.flatMap { entries[$0] }
        controllerID = nil
        if let previous {
            previous.access = try nextAccess(for: previous, role: .observer)
            changed()
            try previous.handlers.releaseInput()
            if let access = previous.access { try await previous.handlers.publishAccess(access) }
        }
        try Task.checkCancellation()
        guard localInputGeneration == localGeneration else { throw Failure.localInputReclaimed }
        let previousIsCurrent = previousID.map { entries[$0] === previous } ?? true
        guard operation == token, entries[id] === target, previousIsCurrent else {
            throw Failure.unavailable
        }

        let granted = try nextAccess(for: target, role: .controller)
        target.access = granted
        controllerID = id
        changed()
        do {
            try await target.handlers.publishAccess(granted)
            try Task.checkCancellation()
            guard localInputGeneration == localGeneration else { throw Failure.localInputReclaimed }
            guard operation == token, entries[id] === target, controllerID == id else {
                throw Failure.unavailable
            }
        } catch {
            if localInputGeneration != localGeneration { throw Failure.localInputReclaimed }
            if entries[id] === target, controllerID == id {
                controllerID = nil
                target.access = try nextAccess(for: target, role: .observer)
                changed()
                try target.handlers.releaseInput()
            }
            throw error
        }
    }

    /// Engines release their exact HID state as part of terminal retirement.
    /// Removing any participant also fences a suspended handoff.
    func remove(id: UUID) {
        guard entries.removeValue(forKey: id) != nil else { return }
        if controllerID == id { controllerID = nil }
        operation = nil
        changed()
    }

    private func nextAccess(for entry: Entry, role: RemoteControlAccess.Role) throws -> RemoteControlAccess {
        guard let previous = entry.access, previous.revision < UInt64(Int64.max) else {
            throw RemoteControlAccess.ValidationError.invalidGrant
        }
        return try RemoteControlAccess(
            revision: previous.revision + 1,
            role: role,
            lease: role == .controller ? UUID() : nil
        )
    }
}
