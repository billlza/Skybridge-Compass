import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if canImport(UIKit)
import UIKit
#endif

enum PersistenceStoreLocation: Sendable {
    case userDefaults(key: String)
    case protectedApplicationSupport(path: String, legacyUserDefaultsKey: String? = nil)
}

enum CodablePersistenceStoreError: Error, CustomNSError, Sendable {
    case payloadTooLarge(actualBytes: Int, maximumBytes: Int)

    static var errorDomain: String { "com.skybridge.persistence" }

    var errorCode: Int {
        switch self {
        case .payloadTooLarge:
            return 1
        }
    }

    var errorUserInfo: [String: Any] {
        switch self {
        case let .payloadTooLarge(actualBytes, maximumBytes):
            return [
                "actualBytes": actualBytes,
                "maximumBytes": maximumBytes
            ]
        }
    }
}

/// Serializes read-modify-write transactions across repository instances that target the
/// same process. The repository actor remains the history owner; this coordinator prevents
/// two independently-created repositories from overwriting one another's canonical file.
actor CodablePersistenceStoreIOCoordinator {
    static let shared = CodablePersistenceStoreIOCoordinator()

    func perform<Result: Sendable>(
        identity: String,
        operation: @Sendable () throws -> Result
    ) rethrows -> Result {
        _ = identity
        return try operation()
    }
}

struct CodablePersistenceStore<Value: Codable>: @unchecked Sendable {
    static var defaultMaximumPayloadBytes: Int { 4 * 1_024 * 1_024 }

    private let location: PersistenceStoreLocation
    private let rootDirectoryName: String
    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let maximumPayloadBytes: Int

    init(
        location: PersistenceStoreLocation,
        rootDirectoryName: String = "SkyBridgeState",
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder(),
        maximumPayloadBytes: Int = Self.defaultMaximumPayloadBytes
    ) {
        precondition(maximumPayloadBytes > 0, "maximumPayloadBytes must be positive")
        self.location = location
        self.rootDirectoryName = rootDirectoryName
        self.defaults = defaults
        self.fileManager = fileManager
        self.encoder = encoder
        self.decoder = decoder
        self.maximumPayloadBytes = maximumPayloadBytes
    }

    var persistenceIdentity: String {
        switch location {
        case let .userDefaults(key):
            return "defaults|\(rootDirectoryName)|\(key)"
        case let .protectedApplicationSupport(path, _):
            let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.skybridge.compass"
            return "application-support|\(bundleIdentifier)|\(rootDirectoryName)|\(path)"
        }
    }

    func load() -> Value? {
        try? loadOrThrow()
    }

    func loadOrThrow() throws -> Value? {
        switch location {
        case let .userDefaults(key):
            guard let data = defaults.data(forKey: key) else { return nil }
            try validatePayloadSize(data.count)
            return try decoder.decode(Value.self, from: data)

        case let .protectedApplicationSupport(path, legacyUserDefaultsKey):
            let url = try resolvedURL(for: path)
            if fileManager.fileExists(atPath: url.path) {
                let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey])
                if let fileSize = resourceValues.fileSize {
                    try validatePayloadSize(fileSize)
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
            try replaceWithProtectedData(data, at: url)
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

    /// Moves unreadable canonical bytes out of the active location without
    /// decoding or rewriting them. Callers must persist a new canonical value
    /// after this succeeds; a failed replacement write remains a blocked state.
    @discardableResult
    func quarantineExistingPayload() throws -> Bool {
        let quarantineID = UUID().uuidString.lowercased()
        switch location {
        case let .userDefaults(key):
            guard let data = defaults.data(forKey: key) else { return false }
            let quarantineKey = "\(key).quarantine.\(quarantineID)"
            defaults.set(data, forKey: quarantineKey)
            guard defaults.data(forKey: quarantineKey) == data else {
                throw CocoaError(.fileWriteUnknown)
            }
            defaults.removeObject(forKey: key)
            return true

        case let .protectedApplicationSupport(path, legacyUserDefaultsKey):
            let url = try resolvedURL(for: path)
            if fileManager.fileExists(atPath: url.path) {
                let quarantineURL = url
                    .deletingLastPathComponent()
                    .appendingPathComponent(
                        "\(url.lastPathComponent).quarantine.\(quarantineID)",
                        isDirectory: false
                    )
                try applyFileProtection(to: url)
                try atomicallyReplace(quarantineURL, withPreparedFileAt: url)
                return true
            }
            guard let legacyUserDefaultsKey,
                  let data = defaults.data(forKey: legacyUserDefaultsKey) else {
                return false
            }
            let quarantineKey = "\(legacyUserDefaultsKey).quarantine.\(quarantineID)"
            defaults.set(data, forKey: quarantineKey)
            guard defaults.data(forKey: quarantineKey) == data else {
                throw CocoaError(.fileWriteUnknown)
            }
            defaults.removeObject(forKey: legacyUserDefaultsKey)
            return true
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

    /// Prepares a fully protected sibling file before a single atomic rename.
    /// No throwing operation is performed against the committed file after the
    /// rename, so a reported save failure cannot conceal a changed primary.
    private func replaceWithProtectedData(_ data: Data, at destinationURL: URL) throws {
        let temporaryURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(destinationURL.lastPathComponent).prepared-\(UUID().uuidString)",
                isDirectory: false
            )
        var preparedFileExists = false

        do {
            guard !fileManager.fileExists(atPath: temporaryURL.path) else {
                throw CocoaError(.fileWriteFileExists)
            }
            // From this point the UUID-scoped path belongs to this transaction.
            // Mark ownership before writing so a partial write is also cleaned.
            preparedFileExists = true
#if canImport(UIKit) && !os(macOS)
            try data.write(
                to: temporaryURL,
                options: [
                    .withoutOverwriting,
                    .completeFileProtectionUntilFirstUserAuthentication
                ]
            )
#else
            try data.write(to: temporaryURL, options: .withoutOverwriting)
#endif
            try applyFileProtection(to: temporaryURL)
            try atomicallyReplace(destinationURL, withPreparedFileAt: temporaryURL)
            preparedFileExists = false
        } catch {
            guard preparedFileExists,
                  fileManager.fileExists(atPath: temporaryURL.path) else {
                throw error
            }
            do {
                try fileManager.removeItem(at: temporaryURL)
            } catch let cleanupError {
                throw PreparedPersistenceFileCleanupError(
                    operationError: error,
                    cleanupError: cleanupError
                )
            }
            throw error
        }
    }

    private func atomicallyReplace(
        _ destinationURL: URL,
        withPreparedFileAt temporaryURL: URL
    ) throws {
        let result: Int32 = temporaryURL.withUnsafeFileSystemRepresentation { temporaryPath in
            destinationURL.withUnsafeFileSystemRepresentation { destinationPath in
                guard let temporaryPath, let destinationPath else {
                    errno = EINVAL
                    return Int32(-1)
                }
                return rename(temporaryPath, destinationPath)
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func validatePayloadSize(_ actualBytes: Int) throws {
        guard actualBytes <= maximumPayloadBytes else {
            throw CodablePersistenceStoreError.payloadTooLarge(
                actualBytes: actualBytes,
                maximumBytes: maximumPayloadBytes
            )
        }
    }
}

private struct PreparedPersistenceFileCleanupError: Error {
    let operationError: Error
    let cleanupError: Error
}
