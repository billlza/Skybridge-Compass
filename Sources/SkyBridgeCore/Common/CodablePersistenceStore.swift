import Foundation
#if canImport(UIKit)
import UIKit
#endif

enum PersistenceStoreLocation: Sendable {
    case userDefaults(key: String)
    case protectedApplicationSupport(path: String, legacyUserDefaultsKey: String? = nil)
}

struct CodablePersistenceStore<Value: Codable>: @unchecked Sendable {
    private let location: PersistenceStoreLocation
    private let rootDirectoryName: String
    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        location: PersistenceStoreLocation,
        rootDirectoryName: String = "SkyBridgeState",
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.location = location
        self.rootDirectoryName = rootDirectoryName
        self.defaults = defaults
        self.fileManager = fileManager
        self.encoder = encoder
        self.decoder = decoder
    }

    func load() -> Value? {
        switch location {
        case let .userDefaults(key):
            guard let data = defaults.data(forKey: key) else { return nil }
            return try? decoder.decode(Value.self, from: data)

        case let .protectedApplicationSupport(path, legacyUserDefaultsKey):
            if let data = try? Data(contentsOf: try resolvedURL(for: path)) {
                if let value = try? decoder.decode(Value.self, from: data) {
                    return value
                }
            }

            guard let legacyUserDefaultsKey,
                  let legacyData = defaults.data(forKey: legacyUserDefaultsKey),
                  let migratedValue = try? decoder.decode(Value.self, from: legacyData) else {
                return nil
            }

            if (try? save(migratedValue)) != nil {
                defaults.removeObject(forKey: legacyUserDefaultsKey)
            }

            return migratedValue
        }
    }

    func save(_ value: Value) throws {
        let data = try encoder.encode(value)

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
}
