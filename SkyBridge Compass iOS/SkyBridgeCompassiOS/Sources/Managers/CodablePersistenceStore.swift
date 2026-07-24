import Foundation
#if canImport(UIKit)
import UIKit
#endif

enum PersistenceStoreLocation: Sendable {
    case userDefaults(key: String)
    case protectedApplicationSupport(path: String, legacyUserDefaultsKey: String? = nil)
}

enum CodablePersistenceStoreError: Error, CustomNSError, Sendable {
    case payloadTooLarge

    static let errorDomain = "SkyBridge.CodablePersistenceStore"

    var errorCode: Int {
        switch self {
        case .payloadTooLarge:
            return 1
        }
    }

    var errorUserInfo: [String: Any] { [:] }
}

struct CodablePersistenceStore<Value: Codable>: @unchecked Sendable {
    static var minimumMaximumPayloadBytes: Int { 64 * 1024 }
    static var maximumMaximumPayloadBytes: Int { 4 * 1024 * 1024 }

    private let location: PersistenceStoreLocation
    private let rootDirectoryName: String
    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let maximumPayloadBytes: Int?

    init(
        location: PersistenceStoreLocation,
        rootDirectoryName: String = "SkyBridgeState",
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder(),
        maximumPayloadBytes: Int? = nil
    ) {
        if let maximumPayloadBytes {
            precondition(
                Self.minimumMaximumPayloadBytes...Self.maximumMaximumPayloadBytes
                    ~= maximumPayloadBytes,
                "maximumPayloadBytes must be between 64 KiB and 4 MiB"
            )
        }
        self.location = location
        self.rootDirectoryName = rootDirectoryName
        self.defaults = defaults
        self.fileManager = fileManager
        self.encoder = encoder
        self.decoder = decoder
        self.maximumPayloadBytes = maximumPayloadBytes
    }

    func load() -> Value? {
        try? loadOrThrow()
    }

    /// Loads persisted state without conflating "missing" with unreadable or
    /// corrupt authority data. Security-sensitive stores must use this API so
    /// a damaged primary file cannot fall back to stale legacy state.
    func loadOrThrow() throws -> Value? {
        switch location {
        case let .userDefaults(key):
            guard let data = defaults.data(forKey: key) else { return nil }
            try validatePayloadSize(data.count)
            return try decoder.decode(Value.self, from: data)

        case let .protectedApplicationSupport(path, legacyUserDefaultsKey):
            let url = try resolvedURL(for: path)
            if fileManager.fileExists(atPath: url.path) {
                let attributes = try fileManager.attributesOfItem(atPath: url.path)
                if let fileSize = attributes[.size] as? NSNumber {
                    try validatePayloadSize(fileSize.intValue)
                }
                let data = try Data(contentsOf: url)
                try validatePayloadSize(data.count)
                return try decoder.decode(Value.self, from: data)
            }

            guard let legacyUserDefaultsKey,
                  let legacyData = defaults.data(forKey: legacyUserDefaultsKey) else {
                return nil
            }

            try validatePayloadSize(legacyData.count)
            let migratedValue = try decoder.decode(Value.self, from: legacyData)
            try save(migratedValue)
            defaults.removeObject(forKey: legacyUserDefaultsKey)

            return migratedValue
        }
    }

    func save(_ value: Value) throws {
        let data = try encoder.encode(value)
        try validatePayloadSize(data.count)

        switch location {
        case let .userDefaults(key):
            defaults.set(data, forKey: key)

        case let .protectedApplicationSupport(path, legacyUserDefaultsKey):
            let url = try resolvedURL(for: path)
            try ensureParentDirectory(for: url)
            try data.write(to: url, options: .atomic)
            try applyFileProtection(to: url)
            if let legacyUserDefaultsKey {
                defaults.removeObject(forKey: legacyUserDefaultsKey)
            }
        }
    }

    func remove() throws {
        switch location {
        case let .userDefaults(key):
            defaults.removeObject(forKey: key)

        case let .protectedApplicationSupport(path, legacyUserDefaultsKey):
            let url = try resolvedURL(for: path)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            if let legacyUserDefaultsKey {
                defaults.removeObject(forKey: legacyUserDefaultsKey)
            }
        }
    }

    private func resolvedURL(for relativePath: String) throws -> URL {
        try applicationSupportBaseURL().appendingPathComponent(relativePath, isDirectory: false)
    }

    private func applicationSupportBaseURL() throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.skybridge.compass"
        return base
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent(rootDirectoryName, isDirectory: true)
    }

    private func ensureParentDirectory(for fileURL: URL) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directoryURL.path) {
#if canImport(UIKit) && !os(macOS)
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
#else
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
#endif
        }

        try applyDirectoryProtection(to: directoryURL)
    }

    private func applyDirectoryProtection(to directoryURL: URL) throws {
#if canImport(UIKit) && !os(macOS)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directoryURL.path
        )
#else
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
#endif
    }

    private func applyFileProtection(to fileURL: URL) throws {
#if canImport(UIKit) && !os(macOS)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: fileURL.path
        )
#else
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
#endif
    }

    private func validatePayloadSize(_ byteCount: Int) throws {
        guard let maximumPayloadBytes else { return }
        guard byteCount <= maximumPayloadBytes else {
            throw CodablePersistenceStoreError.payloadTooLarge
        }
    }
}

struct FileTransferHistoryPersistence: Sendable {
    private let loadImplementation: @Sendable () throws -> [FileTransfer]?
    private let saveImplementation: @Sendable ([FileTransfer]) throws -> Void
    private let removeImplementation: @Sendable () throws -> Void

    init(store: CodablePersistenceStore<[FileTransfer]>) {
        loadImplementation = { try store.loadOrThrow() }
        saveImplementation = { try store.save($0) }
        removeImplementation = { try store.remove() }
    }

    init(
        load: @escaping @Sendable () throws -> [FileTransfer]?,
        save: @escaping @Sendable ([FileTransfer]) throws -> Void,
        remove: @escaping @Sendable () throws -> Void
    ) {
        loadImplementation = load
        saveImplementation = save
        removeImplementation = remove
    }

    func load() throws -> [FileTransfer]? {
        try loadImplementation()
    }

    func save(_ history: [FileTransfer]) throws {
        try saveImplementation(history)
    }

    func remove() throws {
        try removeImplementation()
    }
}

enum FileTransferHistoryCommand: Sendable {
    case bootstrap
    case prepend(FileTransfer)
    case updateLocalPath(transferID: String, localPath: String?)
    case clear
#if DEBUG || SKYBRIDGE_TESTING
    case replaceForTesting([FileTransfer])
#endif
}

struct FileTransferHistoryPersistenceFailure: Sendable, Equatable {
    static let domain = "SkyBridge.FileTransferHistory.Persistence"

    enum Code: Int, Sendable {
        case loadFailed = 1
        case saveFailed = 2
        case clearFailed = 3
        case invalidGeneration = 4
    }

    let code: Code

    var presentationToken: String {
        "\(Self.domain):\(code.rawValue)"
    }
}

struct FileTransferHistorySnapshot: Sendable {
    let history: [FileTransfer]
    let generation: UInt64
    let failure: FileTransferHistoryPersistenceFailure?
}

actor FileTransferHistoryRepository {
    static let historyLimit = 100

    private let persistence: FileTransferHistoryPersistence
    private var history: [FileTransfer] = []
    private var isLoaded = false
    private var isLoadBlocked = false
    private var latestGeneration: UInt64 = 0
    private var persistenceFailure: FileTransferHistoryPersistenceFailure?

    init(persistence: FileTransferHistoryPersistence) {
        self.persistence = persistence
    }

    func apply(
        _ command: FileTransferHistoryCommand,
        generation: UInt64
    ) -> FileTransferHistorySnapshot {
        let expectedGeneration = latestGeneration.addingReportingOverflow(1)
        guard !expectedGeneration.overflow, generation == expectedGeneration.partialValue else {
            return snapshot(
                failure: FileTransferHistoryPersistenceFailure(code: .invalidGeneration)
            )
        }
        latestGeneration = generation

        switch command {
        case .bootstrap:
            loadIfNeeded()

        case let .prepend(transfer):
            loadIfNeeded()
            history.removeAll { $0.id == transfer.id }
            history.insert(transfer, at: 0)
            constrainHistory()
            persistIfLoadAuthorityIsValid()

        case let .updateLocalPath(transferID, localPath):
            loadIfNeeded()
            if let index = history.firstIndex(where: { $0.id == transferID }) {
                history[index].localPath = localPath
                persistIfLoadAuthorityIsValid()
            }

        case .clear:
            clearPersistedHistory()

#if DEBUG || SKYBRIDGE_TESTING
        case let .replaceForTesting(replacement):
            loadIfNeeded()
            history = Array(replacement.prefix(Self.historyLimit))
            persistIfLoadAuthorityIsValid()
#endif
        }

        return snapshot()
    }

    private func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true

        do {
            let persistedHistory = try persistence.load() ?? []
            history = Array(persistedHistory.prefix(Self.historyLimit))
            isLoadBlocked = false
            persistenceFailure = nil

            if persistedHistory.count > Self.historyLimit {
                persistIfLoadAuthorityIsValid()
            }
        } catch {
            history = []
            isLoadBlocked = true
            persistenceFailure = FileTransferHistoryPersistenceFailure(code: .loadFailed)
        }
    }

    private func persistIfLoadAuthorityIsValid() {
        guard !isLoadBlocked else { return }

        do {
            try persistence.save(history)
            persistenceFailure = nil
        } catch {
            persistenceFailure = FileTransferHistoryPersistenceFailure(code: .saveFailed)
        }
    }

    private func clearPersistedHistory() {
        let previousHistory = history
        let previousIsLoaded = isLoaded
        let previousIsLoadBlocked = isLoadBlocked
        let previousFailure = persistenceFailure

        do {
            try persistence.remove()
            history = []
            isLoaded = true
            isLoadBlocked = false
            persistenceFailure = nil
        } catch {
            history = previousHistory
            isLoaded = previousIsLoaded
            isLoadBlocked = previousIsLoadBlocked
            persistenceFailure = FileTransferHistoryPersistenceFailure(code: .clearFailed)
            if !previousIsLoaded {
                loadIfNeeded()
                persistenceFailure = FileTransferHistoryPersistenceFailure(code: .clearFailed)
            } else if previousFailure?.code == .loadFailed {
                isLoadBlocked = true
            }
        }
    }

    private func constrainHistory() {
        if history.count > Self.historyLimit {
            history.removeLast(history.count - Self.historyLimit)
        }
    }

    private func snapshot(
        failure: FileTransferHistoryPersistenceFailure? = nil
    ) -> FileTransferHistorySnapshot {
        FileTransferHistorySnapshot(
            history: history,
            generation: latestGeneration,
            failure: failure ?? persistenceFailure
        )
    }
}
