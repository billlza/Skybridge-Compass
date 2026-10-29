import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if canImport(UIKit) && !os(macOS)
import UIKit
#endif

/// Read-only access for the previous JSON stores.
///
/// The production JSON stores cap normal operation at 4 MiB, but a legacy
/// store is imported whole no matter how large it grew: rejecting it would
/// strand the user's history forever, because the source file is never
/// rewritten. Reads are memory-mapped, so peak resident memory is bounded by
/// the decoded rows rather than the raw file, and the store-level capacity
/// bounds are applied by the repository during the import transaction.
public enum LegacyJSONMigrationReader {
    public static func decode<Value: Decodable>(
        _ type: Value.Type = Value.self,
        from fileURL: URL,
        containedIn rootDirectoryURL: URL,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> Value? {
        guard let data = try readData(
            from: fileURL,
            containedIn: rootDirectoryURL
        ) else {
            return nil
        }
        return try decode(Value.self, from: data, sourceLabel: fileURL.lastPathComponent, decoder: decoder)
    }

    public static func decode<Value: Decodable>(
        _ type: Value.Type = Value.self,
        from data: Data,
        sourceLabel: String,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> Value {
        _ = type
        do {
            return try decoder.decode(Value.self, from: data)
        } catch {
            throw DeviceMessagingRepositoryError.legacyPayloadUnreadable(sourceLabel)
        }
    }

    /// Reads the exact legacy bytes once so callers can both hash and decode the
    /// same immutable payload. The source is never rewritten by this operation.
    /// The mapping is read-only and uncached, so file size does not translate
    /// into sustained resident memory.
    public static func readData(
        from fileURL: URL,
        containedIn rootDirectoryURL: URL
    ) throws -> Data? {
        let fileManager = FileManager.default
        let unresolvedRoot = rootDirectoryURL.standardizedFileURL
        let unresolvedFile = fileURL.standardizedFileURL
        let root = unresolvedRoot.resolvingSymlinksInPath()
        let file = unresolvedFile.resolvingSymlinksInPath()
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard file.path.hasPrefix(rootPath), file.path != root.path else {
            throw DeviceMessagingRepositoryError.invalidDatabaseLocation
        }
        guard fileManager.fileExists(atPath: unresolvedFile.path) else { return nil }

        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: unresolvedFile.path)
        } catch {
            throw DeviceMessagingRepositoryError.legacyPayloadUnreadable(
                unresolvedFile.lastPathComponent
            )
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              ((attributes[.referenceCount] as? NSNumber)?.intValue ?? 1) == 1 else {
            throw DeviceMessagingRepositoryError.legacyPayloadUnreadable(
                unresolvedFile.lastPathComponent
            )
        }
        let data: Data
        do {
            data = try Data(contentsOf: unresolvedFile, options: [.mappedIfSafe, .uncached])
        } catch {
            throw DeviceMessagingRepositoryError.legacyPayloadUnreadable(
                unresolvedFile.lastPathComponent
            )
        }
        return data
    }

    /// Verifies a previously committed in-place archive through the same
    /// bounded, contained, regular-file-only reader used for legacy sources.
    public static func archivedDataMatches(
        _ expectedData: Data,
        at archiveURL: URL,
        containedIn rootDirectoryURL: URL,
        sourceLabel: String
    ) throws -> Bool {
        guard let archivedData = try readData(
            from: archiveURL,
            containedIn: rootDirectoryURL
        ) else {
            return false
        }
        guard archivedData == expectedData else {
            throw DeviceMessagingRepositoryError.legacySourceConflict(sourceLabel)
        }
        return true
    }

    /// Creates an exact archive without following archive-file or directory
    /// symlinks. A temporary regular file is synced and atomically moved into
    /// place; a racing destination must contain the same bytes.
    @discardableResult
    public static func archive(
        data expectedData: Data,
        to archiveURL: URL,
        containedIn rootDirectoryURL: URL,
        sourceLabel: String
    ) throws -> URL {
        if try archivedDataMatches(
            expectedData,
            at: archiveURL,
            containedIn: rootDirectoryURL,
            sourceLabel: sourceLabel
        ) {
            try applyProtection(to: archiveURL)
            return archiveURL
        }

        let parentURL = archiveURL.deletingLastPathComponent()
        try createContainedDirectory(
            parentURL,
            containedIn: rootDirectoryURL,
            sourceLabel: sourceLabel
        )
        let temporaryURL = parentURL.appendingPathComponent(
            ".\(archiveURL.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        let descriptor = openExclusiveFile(at: temporaryURL)
        guard descriptor >= 0 else {
            throw DeviceMessagingRepositoryError.legacyPayloadUnreadable(sourceLabel)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: expectedData)
            try handle.synchronize()
            try handle.close()
            try applyProtection(to: temporaryURL)
            do {
                try FileManager.default.moveItem(at: temporaryURL, to: archiveURL)
            } catch {
                guard try archivedDataMatches(
                    expectedData,
                    at: archiveURL,
                    containedIn: rootDirectoryURL,
                    sourceLabel: sourceLabel
                ) else {
                    throw DeviceMessagingRepositoryError.legacyPayloadUnreadable(sourceLabel)
                }
                try? FileManager.default.removeItem(at: temporaryURL)
            }
            try applyProtection(to: archiveURL)
            return archiveURL
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    /// Archives a source only after its rows and digest have committed to the
    /// unified repository. A pre-existing archive must contain identical bytes;
    /// it is never overwritten.
    @discardableResult
    public static func archive(
        fileURL: URL,
        containedIn rootDirectoryURL: URL,
        contentDigest: String,
        expectedData: Data,
        migrationVersion: Int = 1
    ) throws -> URL? {
        guard migrationVersion > 0,
              contentDigest.utf8.count == 64,
              contentDigest.unicodeScalars.allSatisfy({ scalar in
                  (scalar.value >= 0x30 && scalar.value <= 0x39)
                      || (scalar.value >= 0x61 && scalar.value <= 0x66)
              }) else {
            throw DeviceMessagingRepositoryError.invalidRecord(
                reasonCode: "invalid_migration_archive_identity"
            )
        }
        let stem = fileURL.deletingPathExtension().lastPathComponent
        let suffix = fileURL.pathExtension
        let archiveName = "\(stem).migrated-v\(migrationVersion)-\(contentDigest.prefix(16))"
            + (suffix.isEmpty ? "" : ".\(suffix)")
        let archiveURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(archiveName, isDirectory: false)
        let fileManager = FileManager.default

        guard let sourceData = try readData(
            from: fileURL,
            containedIn: rootDirectoryURL
        ) else {
            guard let archiveData = try readData(
                from: archiveURL,
                containedIn: rootDirectoryURL
            ), archiveData == expectedData else {
                throw DeviceMessagingRepositoryError.legacySourceChanged(
                    fileURL.lastPathComponent
                )
            }
            try applyProtection(to: archiveURL)
            return archiveURL
        }
        guard sourceData == expectedData else {
            throw DeviceMessagingRepositoryError.legacySourceChanged(
                fileURL.lastPathComponent
            )
        }

        if fileManager.fileExists(atPath: archiveURL.path) {
            guard let archiveData = try readData(
                from: archiveURL,
                containedIn: rootDirectoryURL
            ), archiveData == sourceData else {
                throw DeviceMessagingRepositoryError.legacySourceConflict(
                    fileURL.lastPathComponent
                )
            }
            try applyProtection(to: archiveURL)
            try fileManager.removeItem(at: fileURL)
            return archiveURL
        }

        try applyProtection(to: fileURL)
        do {
            try fileManager.moveItem(at: fileURL, to: archiveURL)
            try applyProtection(to: archiveURL)
        } catch {
            throw DeviceMessagingRepositoryError.legacyPayloadUnreadable(
                fileURL.lastPathComponent
            )
        }
        return archiveURL
    }

    private static func applyProtection(to fileURL: URL) throws {
#if canImport(UIKit) && !os(macOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: fileURL.path
        )
#else
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
#endif
    }

    private static func createContainedDirectory(
        _ directoryURL: URL,
        containedIn rootDirectoryURL: URL,
        sourceLabel: String
    ) throws {
        let root = rootDirectoryURL.standardizedFileURL
        let directory = directoryURL.standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard directory.path.hasPrefix(rootPath), directory.path != root.path else {
            throw DeviceMessagingRepositoryError.invalidDatabaseLocation
        }
        let rootAttributes = try FileManager.default.attributesOfItem(atPath: root.path)
        guard rootAttributes[.type] as? FileAttributeType == .typeDirectory else {
            throw DeviceMessagingRepositoryError.invalidDatabaseLocation
        }

        let relativePath = String(directory.path.dropFirst(rootPath.count))
        var current = root
        for component in relativePath.split(separator: "/") {
            current.appendPathComponent(String(component), isDirectory: true)
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: current.path)
                guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                    throw DeviceMessagingRepositoryError.invalidDatabaseLocation
                }
            } catch let error as DeviceMessagingRepositoryError {
                throw error
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                do {
                    try FileManager.default.createDirectory(
                        at: current,
                        withIntermediateDirectories: false,
                        attributes: [.posixPermissions: 0o700]
                    )
                } catch {
                    throw DeviceMessagingRepositoryError.legacyPayloadUnreadable(sourceLabel)
                }
            } catch {
                throw DeviceMessagingRepositoryError.legacyPayloadUnreadable(sourceLabel)
            }
        }

        let resolvedRoot = root.resolvingSymlinksInPath()
        let resolvedDirectory = directory.resolvingSymlinksInPath()
        let resolvedRootPath = resolvedRoot.path.hasSuffix("/")
            ? resolvedRoot.path
            : resolvedRoot.path + "/"
        guard resolvedDirectory.path.hasPrefix(resolvedRootPath) else {
            throw DeviceMessagingRepositoryError.invalidDatabaseLocation
        }
    }

    private static func openExclusiveFile(at fileURL: URL) -> Int32 {
#if canImport(Darwin)
        Darwin.open(
            fileURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
#elseif canImport(Glibc)
        Glibc.open(
            fileURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
#else
        -1
#endif
    }
}
