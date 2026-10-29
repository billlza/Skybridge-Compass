import Darwin
import Foundation

protocol SSHKnownHostsPersistenceBackend: Sendable {
    func loadData() throws -> Data?
    func commitAndReload(_ data: Data) throws -> Data
}

struct SSHKnownHostsIntegrityState: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1

    let formatVersion: Int
    let generation: UInt64
    let databaseSHA256: String

    init(generation: UInt64, databaseSHA256: String) {
        formatVersion = Self.currentFormatVersion
        self.generation = generation
        self.databaseSHA256 = databaseSHA256
    }

    func validate() throws {
        guard formatVersion == Self.currentFormatVersion,
              generation > 0,
              databaseSHA256.utf8.count == 64,
              databaseSHA256.utf8.allSatisfy({
                  ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
              }) else {
            throw SSHKnownHostsStoreError.invalidPersistedData
        }
    }
}

protocol SSHKnownHostsIntegrityPersistenceBackend: Sendable {
    func loadState() throws -> SSHKnownHostsIntegrityState?
    func commitAndReload(_ state: SSHKnownHostsIntegrityState) throws -> SSHKnownHostsIntegrityState
}

/// Keychain-backed rollback marker for the file authority.
///
/// The file is committed first and this protected digest/generation is committed second. A crash
/// between the two writes therefore produces a fail-closed mismatch instead of trusting an
/// operation whose protected commit was never acknowledged.
struct SSHKnownHostsKeychainIntegrityPersistence: SSHKnownHostsIntegrityPersistenceBackend, Sendable {
    private static let service = "com.skybridge.compass.ssh-known-hosts"
    private static let account = "authority-integrity-v1"

    func loadState() throws -> SSHKnownHostsIntegrityState? {
        guard let data = try KeychainManager.shared.exportKeyStrict(
            service: Self.service,
            account: Self.account
        ) else {
            return nil
        }
        let state: SSHKnownHostsIntegrityState
        do {
            state = try JSONDecoder().decode(SSHKnownHostsIntegrityState.self, from: data)
        } catch {
            throw SSHKnownHostsStoreError.invalidPersistedData
        }
        try state.validate()
        return state
    }

    func commitAndReload(
        _ state: SSHKnownHostsIntegrityState
    ) throws -> SSHKnownHostsIntegrityState {
        try state.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        guard KeychainManager.shared.importKey(
            data: data,
            service: Self.service,
            account: Self.account
        ) else {
            throw SSHKnownHostsStoreError.persistenceUnavailable
        }
        guard let committed = try loadState(), committed == state else {
            throw SSHKnownHostsStoreError.persistenceVerificationFailed
        }
        return committed
    }
}

/// File-backed authority storage for SSH host keys.
///
/// Temporary bytes are verified before the atomic rename. The successful directory `fsync` after
/// `renameat` is the only commit point; no fallible verification is performed after that point.
/// All authority file operations are relative to a validated private directory descriptor.
struct SSHKnownHostsFilePersistence: SSHKnownHostsPersistenceBackend, Sendable {
    static let maximumDatabaseBytes = 2 * 1_024 * 1_024

    let fileURL: URL

    func loadData() throws -> Data? {
        let directoryURL = fileURL.deletingLastPathComponent()
        guard let directoryDescriptor = try Self.openPrivateDirectoryIfPresent(at: directoryURL) else {
            return nil
        }
        defer { _ = Darwin.close(directoryDescriptor) }
        return try Self.readRegularFile(
            relativePath: fileURL.lastPathComponent,
            directoryDescriptor: directoryDescriptor,
            maximumBytes: Self.maximumDatabaseBytes,
            requirePrivateAuthorityMetadata: true
        )
    }

    func commitAndReload(_ data: Data) throws -> Data {
        guard !data.isEmpty, data.count <= Self.maximumDatabaseBytes else {
            throw SSHKnownHostsStoreError.persistenceUnavailable
        }

        let directoryURL = fileURL.deletingLastPathComponent()
        try Self.ensurePrivateDirectory(at: directoryURL)
        guard let directoryDescriptor = try Self.openPrivateDirectoryIfPresent(at: directoryURL) else {
            throw SSHKnownHostsStoreError.persistenceUnavailable
        }
        defer { _ = Darwin.close(directoryDescriptor) }

        let targetName = fileURL.lastPathComponent
        guard Self.isSinglePathComponent(targetName) else {
            throw SSHKnownHostsStoreError.persistenceUnavailable
        }
        let temporaryName = ".\(targetName).\(UUID().uuidString).tmp"
        var shouldRemoveTemporaryFile = true
        defer {
            if shouldRemoveTemporaryFile {
                _ = Darwin.unlinkat(directoryDescriptor, temporaryName, 0)
            }
        }

        let descriptor = Darwin.openat(
            directoryDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw Self.posixError()
        }

        var descriptorIsOpen = true
        defer {
            if descriptorIsOpen {
                _ = Darwin.close(descriptor)
            }
        }

        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                throw SSHKnownHostsStoreError.persistenceUnavailable
            }
            var written = 0
            while written < bytes.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    bytes.count - written
                )
                if result > 0 {
                    written += result
                } else if result < 0, errno == EINTR {
                    continue
                } else {
                    throw Self.posixError(result == 0 ? EIO : errno)
                }
            }
        }

        guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw Self.posixError()
        }
        try Self.synchronizeDescriptor(descriptor)
        guard Darwin.close(descriptor) == 0 else {
            descriptorIsOpen = false
            throw Self.posixError()
        }
        descriptorIsOpen = false

        guard let verifiedTemporaryData = try Self.readRegularFile(
            relativePath: temporaryName,
            directoryDescriptor: directoryDescriptor,
            maximumBytes: Self.maximumDatabaseBytes,
            requirePrivateAuthorityMetadata: true
        ), verifiedTemporaryData == data else {
            throw SSHKnownHostsStoreError.persistenceVerificationFailed
        }

        guard Darwin.renameat(
            directoryDescriptor,
            temporaryName,
            directoryDescriptor,
            targetName
        ) == 0 else {
            throw Self.posixError()
        }
        shouldRemoveTemporaryFile = false

        // Commit point: after this succeeds, the renamed directory entry is durably acknowledged.
        try Self.synchronizeDescriptor(directoryDescriptor)
        return data
    }

    private static func ensurePrivateDirectory(at directoryURL: URL) throws {
        var missingDirectories: [URL] = []
        var currentURL = directoryURL.standardizedFileURL

        while true {
            var metadata = stat()
            if lstat(currentURL.path, &metadata) == 0 {
                guard (metadata.st_mode & S_IFMT) == S_IFDIR else {
                    throw SSHKnownHostsStoreError.persistenceUnavailable
                }
                break
            }
            guard errno == ENOENT else {
                throw posixError()
            }
            missingDirectories.append(currentURL)
            let parentURL = currentURL.deletingLastPathComponent()
            guard parentURL.path != currentURL.path else {
                throw SSHKnownHostsStoreError.persistenceUnavailable
            }
            currentURL = parentURL
        }

        for newDirectoryURL in missingDirectories.reversed() {
            let parentURL = newDirectoryURL.deletingLastPathComponent()
            let parentDescriptor = Darwin.open(
                parentURL.path,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
            guard parentDescriptor >= 0 else {
                throw posixError()
            }
            defer { _ = Darwin.close(parentDescriptor) }

            let component = newDirectoryURL.lastPathComponent
            guard isSinglePathComponent(component),
                  Darwin.mkdirat(parentDescriptor, component, S_IRWXU) == 0 else {
                throw posixError()
            }
            // Persist every newly created parent entry, not only the final Security directory.
            try synchronizeDescriptor(parentDescriptor)

            let newDirectoryDescriptor = Darwin.openat(
                parentDescriptor,
                component,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
            guard newDirectoryDescriptor >= 0 else {
                throw posixError()
            }
            do {
                try validatePrivateDirectoryDescriptor(newDirectoryDescriptor)
                try synchronizeDescriptor(newDirectoryDescriptor)
            } catch {
                _ = Darwin.close(newDirectoryDescriptor)
                throw error
            }
            _ = Darwin.close(newDirectoryDescriptor)
        }

        guard let finalDescriptor = try openPrivateDirectoryIfPresent(at: directoryURL) else {
            throw SSHKnownHostsStoreError.persistenceUnavailable
        }
        _ = Darwin.close(finalDescriptor)
    }

    private static func openPrivateDirectoryIfPresent(at url: URL) throws -> Int32? {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        if descriptor < 0, errno == ENOENT {
            return nil
        }
        guard descriptor >= 0 else {
            throw posixError()
        }
        do {
            try validatePrivateDirectoryDescriptor(descriptor)
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private static func validatePrivateDirectoryDescriptor(_ descriptor: Int32) throws {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw posixError()
        }
        guard (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == geteuid(),
              (metadata.st_mode & 0o077) == 0,
              metadata.st_nlink > 0 else {
            throw SSHKnownHostsStoreError.invalidPersistedData
        }
    }

    /// Reads a user-selected import. Authority-file metadata is checked by `loadData()` instead;
    /// imports may legitimately be read-only or group-readable OpenSSH files.
    static func readRegularFile(at url: URL, maximumBytes: Int) throws -> Data? {
        guard maximumBytes > 0 else {
            throw SSHKnownHostsStoreError.persistenceUnavailable
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT {
            return nil
        }
        guard descriptor >= 0 else {
            throw posixError()
        }
        defer { _ = Darwin.close(descriptor) }
        return try readRegularFile(
            descriptor: descriptor,
            maximumBytes: maximumBytes,
            requirePrivateAuthorityMetadata: false
        )
    }

    private static func readRegularFile(
        relativePath: String,
        directoryDescriptor: Int32,
        maximumBytes: Int,
        requirePrivateAuthorityMetadata: Bool
    ) throws -> Data? {
        guard maximumBytes > 0, isSinglePathComponent(relativePath) else {
            throw SSHKnownHostsStoreError.persistenceUnavailable
        }
        let descriptor = Darwin.openat(
            directoryDescriptor,
            relativePath,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        if descriptor < 0, errno == ENOENT {
            return nil
        }
        guard descriptor >= 0 else {
            throw posixError()
        }
        defer { _ = Darwin.close(descriptor) }
        return try readRegularFile(
            descriptor: descriptor,
            maximumBytes: maximumBytes,
            requirePrivateAuthorityMetadata: requirePrivateAuthorityMetadata
        )
    }

    private static func readRegularFile(
        descriptor: Int32,
        maximumBytes: Int,
        requirePrivateAuthorityMetadata: Bool
    ) throws -> Data {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw posixError()
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size >= 0,
              metadata.st_size <= maximumBytes else {
            throw SSHKnownHostsStoreError.invalidPersistedData
        }
        if requirePrivateAuthorityMetadata {
            guard metadata.st_uid == geteuid(),
                  (metadata.st_mode & 0o077) == 0,
                  metadata.st_nlink == 1 else {
                throw SSHKnownHostsStoreError.invalidPersistedData
            }
        }

        let expectedCount = Int(metadata.st_size)
        var data = Data(count: expectedCount)
        try data.withUnsafeMutableBytes { bytes in
            guard expectedCount == 0 || bytes.baseAddress != nil else {
                throw SSHKnownHostsStoreError.persistenceUnavailable
            }
            var offset = 0
            while offset < expectedCount {
                let result = Darwin.read(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    expectedCount - offset
                )
                if result > 0 {
                    offset += result
                } else if result < 0, errno == EINTR {
                    continue
                } else if result == 0 {
                    throw SSHKnownHostsStoreError.invalidPersistedData
                } else {
                    throw posixError()
                }
            }
        }

        var trailingByte: UInt8 = 0
        while true {
            let result = withUnsafeMutablePointer(to: &trailingByte) { pointer in
                Darwin.read(descriptor, pointer, 1)
            }
            if result == 0 {
                break
            }
            if result < 0, errno == EINTR {
                continue
            }
            if result > 0 {
                throw SSHKnownHostsStoreError.invalidPersistedData
            }
            throw posixError()
        }

        var finalMetadata = stat()
        guard fstat(descriptor, &finalMetadata) == 0 else {
            throw posixError()
        }
        guard finalMetadata.st_dev == metadata.st_dev,
              finalMetadata.st_ino == metadata.st_ino,
              finalMetadata.st_size == metadata.st_size,
              finalMetadata.st_mtimespec.tv_sec == metadata.st_mtimespec.tv_sec,
              finalMetadata.st_mtimespec.tv_nsec == metadata.st_mtimespec.tv_nsec else {
            throw SSHKnownHostsStoreError.invalidPersistedData
        }
        return data
    }

    private static func synchronizeDescriptor(_ descriptor: Int32) throws {
        while Darwin.fsync(descriptor) != 0 {
            if errno == EINTR {
                continue
            }
            throw posixError()
        }
    }

    private static func isSinglePathComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/")
    }

    private static func posixError(_ code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}
