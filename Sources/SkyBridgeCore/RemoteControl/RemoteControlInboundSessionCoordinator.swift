#if os(macOS)
import Foundation
import Network

@MainActor
protocol RemoteControlInboundSessionEngine: AnyObject {
    var onInboundSessionEnded: (@MainActor (NWConnection) -> Void)? { get set }
    func allowRemoteControl(from deviceId: String, connection: NWConnection, initialData: Data?) async
    func stopRemoteControl(from deviceId: String)
}

extension RemoteControlManager: RemoteControlInboundSessionEngine {}

enum RemoteControlInboundSessionError: Error, Equatable {
    case atCapacity(limit: Int)
    case connectionAlreadyOwned
}

/// Each accepted transport owns one existing single-host engine. Startup returning
/// does not retire an authenticated session; only its exact terminal callback does.
@MainActor
final class RemoteControlInboundSessionCoordinator {
    private final class Entry {
        let generation = UUID()
        let deviceId: String
        let connection: NWConnection
        let engine: any RemoteControlInboundSessionEngine
        let onEnded: @MainActor () -> Void
        var startup: Task<Void, Never>?

        init(
            deviceId: String,
            connection: NWConnection,
            engine: any RemoteControlInboundSessionEngine,
            onEnded: @escaping @MainActor () -> Void
        ) {
            self.deviceId = deviceId
            self.connection = connection
            self.engine = engine
            self.onEnded = onEnded
        }
    }

    private let limit: Int
    private let makeEngine: @MainActor () -> any RemoteControlInboundSessionEngine
    private var entries: [ObjectIdentifier: Entry] = [:]

    init(
        limit: Int,
        makeEngine: @escaping @MainActor () -> any RemoteControlInboundSessionEngine = {
            RemoteControlManager()
        }
    ) {
        precondition(limit > 0)
        self.limit = limit
        self.makeEngine = makeEngine
    }

    var activeSessionCount: Int { entries.count }

    func accept(
        connection: NWConnection,
        deviceId: String,
        initialData: Data?,
        onEnded: @escaping @MainActor () -> Void
    ) throws {
        let key = ObjectIdentifier(connection)
        guard entries[key] == nil else {
            throw RemoteControlInboundSessionError.connectionAlreadyOwned
        }
        guard entries.count < limit else {
            throw RemoteControlInboundSessionError.atCapacity(limit: limit)
        }
        let entry = Entry(
            deviceId: deviceId, connection: connection,
            engine: makeEngine(), onEnded: onEnded
        )
        entries[key] = entry
        let generation = entry.generation
        entry.engine.onInboundSessionEnded = { [weak self] endedConnection in
            self?.retire(connection: endedConnection, generation: generation)
        }
        entry.startup = Task { @MainActor [weak self, weak entry] in
            guard let self, let entry,
                  self.entries[key] === entry, !Task.isCancelled else { return }
            await entry.engine.allowRemoteControl(
                from: deviceId, connection: connection, initialData: initialData
            )
            if self.entries[key] === entry { entry.startup = nil }
        }
    }

    func stopAll() {
        let retired = Array(entries.values)
        entries.removeAll()
        for entry in retired {
            entry.engine.onInboundSessionEnded = nil
            entry.startup?.cancel()
            entry.engine.stopRemoteControl(from: entry.deviceId)
            entry.connection.cancel()
            entry.onEnded()
        }
    }

    private func retire(connection: NWConnection, generation: UUID) {
        let key = ObjectIdentifier(connection)
        guard let entry = entries[key], entry.generation == generation else { return }
        entries.removeValue(forKey: key)
        entry.engine.onInboundSessionEnded = nil
        entry.startup?.cancel()
        entry.connection.cancel()
        entry.onEnded()
    }
}
#endif
