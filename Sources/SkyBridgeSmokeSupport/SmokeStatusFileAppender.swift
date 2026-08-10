import Darwin
import Foundation

public enum SmokeStatusFileAppender {
    private static let maximumPrivateDataByteCount = 1_048_576

    /// Atomically replaces a smoke artifact inside an existing private directory.
    ///
    /// The directory is part of the security boundary: this method never creates it or changes
    /// its permissions. The caller must provide a directory owned by the current effective user
    /// with no group/other access. Existing destinations are accepted only when they are
    /// single-link regular files owned by that user; links and special files fail closed.
    public static func replacePrivateData(
        _ data: Data,
        at url: URL,
        protection: FileProtectionType? = nil
    ) throws {
        guard data.count <= maximumPrivateDataByteCount else {
            throw posixError(code: EFBIG, path: url.path)
        }
        guard url.isFileURL else {
            throw posixError(code: EINVAL, path: url.absoluteString)
        }

        let directoryURL = url.deletingLastPathComponent()
        let filename = url.lastPathComponent
        guard isSinglePathComponent(filename) else {
            throw posixError(code: EINVAL, path: url.path)
        }

        let directoryDescriptor = Darwin.open(
            directoryURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directoryDescriptor >= 0 else {
            throw posixError(path: directoryURL.path)
        }
        defer { _ = Darwin.close(directoryDescriptor) }
        try validatePrivateDirectory(directoryDescriptor, path: directoryURL.path)

        let originalDestination = try inspectDestination(
            named: filename,
            directoryDescriptor: directoryDescriptor,
            path: url.path
        )
        let temporaryName = ".\(filename).\(UUID().uuidString).tmp"
        let temporaryURL = directoryURL.appendingPathComponent(
            temporaryName,
            isDirectory: false
        )
        var shouldRemoveTemporaryFile = true
        defer {
            if shouldRemoveTemporaryFile {
                _ = Darwin.unlinkat(directoryDescriptor, temporaryName, 0)
            }
        }

        let fileDescriptor = Darwin.openat(
            directoryDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard fileDescriptor >= 0 else {
            throw posixError(path: temporaryURL.path)
        }

        var fileDescriptorIsOpen = true
        defer {
            if fileDescriptorIsOpen {
                _ = Darwin.close(fileDescriptor)
            }
        }

        try data.withUnsafeBytes { rawBuffer in
            try writeAll(rawBuffer, to: fileDescriptor, path: temporaryURL.path)
        }
        if let protection {
            try FileManager.default.setAttributes(
                [.protectionKey: protection],
                ofItemAtPath: temporaryURL.path
            )
        }
        guard Darwin.fchmod(fileDescriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw posixError(path: temporaryURL.path)
        }
        let temporaryMetadata = try validatedPrivateRegularFile(
            fileDescriptor,
            expectedByteCount: data.count,
            path: temporaryURL.path
        )
        guard Darwin.fsync(fileDescriptor) == 0 else {
            throw posixError(path: temporaryURL.path)
        }
        guard Darwin.close(fileDescriptor) == 0 else {
            fileDescriptorIsOpen = false
            throw posixError(path: temporaryURL.path)
        }
        fileDescriptorIsOpen = false

        try verifyDestinationUnchanged(
            originalDestination,
            named: filename,
            directoryDescriptor: directoryDescriptor,
            path: url.path
        )
        let renameResult: Int32
        switch originalDestination {
        case .missing:
            renameResult = temporaryName.withCString { temporaryPointer in
                filename.withCString { destinationPointer in
                    Darwin.renameatx_np(
                        directoryDescriptor,
                        temporaryPointer,
                        directoryDescriptor,
                        destinationPointer,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
        case .regular:
            renameResult = Darwin.renameat(
                directoryDescriptor,
                temporaryName,
                directoryDescriptor,
                filename
            )
        }
        guard renameResult == 0 else {
            throw posixError(path: url.path)
        }
        shouldRemoveTemporaryFile = false

        guard Darwin.fsync(directoryDescriptor) == 0 else {
            throw posixError(path: directoryURL.path)
        }
        try verifyCommittedDestination(
            named: filename,
            directoryDescriptor: directoryDescriptor,
            expectedMetadata: temporaryMetadata,
            expectedByteCount: data.count,
            path: url.path
        )
    }

    public static func append(
        _ data: Data,
        to url: URL,
        protection: FileProtectionType? = nil
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        try data.withUnsafeBytes { rawBuffer in
            let fd = try openRegularFile(at: url, flags: O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC)
            defer { _ = close(fd) }
            _ = fchmod(fd, mode_t(S_IRUSR | S_IWUSR))
            try writeAll(rawBuffer, to: fd, path: url.path)
        }

        if let protection {
            try? FileManager.default.setAttributes(
                [.protectionKey: protection],
                ofItemAtPath: url.path
            )
        }
    }

    public static func reset(
        at url: URL,
        protection: FileProtectionType? = nil
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let fd = try openRegularFile(at: url, flags: O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC)
        _ = fchmod(fd, mode_t(S_IRUSR | S_IWUSR))
        _ = close(fd)

        if let protection {
            try? FileManager.default.setAttributes(
                [.protectionKey: protection],
                ofItemAtPath: url.path
            )
        }
    }

    private static func openRegularFile(at url: URL, flags: Int32) throws -> Int32 {
        let fd = Darwin.open(url.path, flags | O_NOFOLLOW, mode_t(S_IRUSR | S_IWUSR))
        if fd < 0 {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: url.path]
            )
        }
        do {
            try validateRegularFile(fd, path: url.path)
        } catch {
            _ = close(fd)
            throw error
        }
        return fd
    }

    private static func validateRegularFile(_ fd: Int32, path: String) throws {
        var statBuffer = stat()
        guard Darwin.fstat(fd, &statBuffer) == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: path]
            )
        }
        guard (statBuffer.st_mode & S_IFMT) == S_IFREG else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(EINVAL),
                userInfo: [NSFilePathErrorKey: path]
            )
        }
    }

    private enum DestinationMetadata {
        case missing
        case regular(device: dev_t, inode: ino_t)
    }

    private static func isSinglePathComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/")
    }

    private static func validatePrivateDirectory(_ descriptor: Int32, path: String) throws {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw posixError(path: path)
        }
        guard (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == Darwin.geteuid(),
              metadata.st_mode & mode_t(0o077) == 0 else {
            throw posixError(code: EACCES, path: path)
        }
    }

    private static func inspectDestination(
        named filename: String,
        directoryDescriptor: Int32,
        path: String
    ) throws -> DestinationMetadata {
        var metadata = stat()
        let result = filename.withCString {
            Darwin.fstatat(directoryDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        if result == -1, errno == ENOENT {
            return .missing
        }
        guard result == 0 else {
            throw posixError(path: path)
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == Darwin.geteuid(),
              metadata.st_nlink == 1 else {
            throw posixError(code: EACCES, path: path)
        }
        return .regular(device: metadata.st_dev, inode: metadata.st_ino)
    }

    private static func verifyDestinationUnchanged(
        _ expected: DestinationMetadata,
        named filename: String,
        directoryDescriptor: Int32,
        path: String
    ) throws {
        let current = try inspectDestination(
            named: filename,
            directoryDescriptor: directoryDescriptor,
            path: path
        )
        switch (expected, current) {
        case (.missing, .missing):
            return
        case (
            .regular(let expectedDevice, let expectedInode),
            .regular(let currentDevice, let currentInode)
        ) where expectedDevice == currentDevice && expectedInode == currentInode:
            return
        default:
            throw posixError(code: EBUSY, path: path)
        }
    }

    private static func validatedPrivateRegularFile(
        _ descriptor: Int32,
        expectedByteCount: Int,
        path: String
    ) throws -> stat {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw posixError(path: path)
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == Darwin.geteuid(),
              metadata.st_nlink == 1,
              metadata.st_mode & mode_t(0o7777) == mode_t(0o600),
              metadata.st_size == off_t(expectedByteCount) else {
            throw posixError(code: EACCES, path: path)
        }
        return metadata
    }

    private static func verifyCommittedDestination(
        named filename: String,
        directoryDescriptor: Int32,
        expectedMetadata: stat,
        expectedByteCount: Int,
        path: String
    ) throws {
        var metadata = stat()
        let result = filename.withCString {
            Darwin.fstatat(directoryDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0 else {
            throw posixError(path: path)
        }
        guard metadata.st_dev == expectedMetadata.st_dev,
              metadata.st_ino == expectedMetadata.st_ino,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == Darwin.geteuid(),
              metadata.st_nlink == 1,
              metadata.st_mode & mode_t(0o7777) == mode_t(0o600),
              metadata.st_size == off_t(expectedByteCount) else {
            throw posixError(code: EACCES, path: path)
        }
    }

    private static func posixError(code: Int32 = errno, path: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSFilePathErrorKey: path]
        )
    }

    private static func writeAll(
        _ rawBuffer: UnsafeRawBufferPointer,
        to fd: Int32,
        path: String
    ) throws {
        guard let baseAddress = rawBuffer.baseAddress else { return }
        var offset = 0
        while offset < rawBuffer.count {
            let written = Darwin.write(
                fd,
                baseAddress.advanced(by: offset),
                rawBuffer.count - offset
            )
            if written > 0 {
                offset += written
            } else if written == -1, errno == EINTR {
                continue
            } else {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(errno),
                    userInfo: [NSFilePathErrorKey: path]
                )
            }
        }
    }
}
