import Foundation
import Darwin

public enum SmokeStatusFileAppender {
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
