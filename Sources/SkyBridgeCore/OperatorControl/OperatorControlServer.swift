import Foundation

#if os(macOS)
import Darwin

public enum OperatorControlServerError: Error, Equatable, LocalizedError, Sendable {
    case applicationSupportDirectoryUnavailable
    case socketPathTooLong(Int)
    case unsafeSocketPath(String)
    case posix(operation: String, errno: Int32)
    case cleanupAfterStartFailure(start: String, cleanup: String)

    public var errorDescription: String? {
        switch self {
        case .applicationSupportDirectoryUnavailable:
            return "Application Support directory is unavailable"
        case .socketPathTooLong(let byteCount):
            return "operator control socket path is too long: \(byteCount) bytes"
        case .unsafeSocketPath(let detail):
            return "unsafe operator control socket path: \(detail)"
        case .posix(let operation, let rawErrno):
            return "\(operation) failed with errno \(rawErrno)"
        case .cleanupAfterStartFailure(let start, let cleanup):
            return "operator control server start failed (\(start)); cleanup also failed (\(cleanup))"
        }
    }
}

public enum OperatorControlSocketPathPolicy {
    public static func defaultSocketURL(fileManager: FileManager = .default) throws -> URL {
        guard let baseURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw OperatorControlServerError.applicationSupportDirectoryUnavailable
        }
        return baseURL
            .appendingPathComponent("SkyBridge", isDirectory: true)
            .appendingPathComponent("crossnet-control.sock", isDirectory: false)
    }

    public static func prepareSocketURL(_ socketURL: URL, fileManager: FileManager = .default) throws {
        let directoryURL = socketURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try chmodPath(directoryURL.path, mode: S_IRWXU, operation: "chmod control socket directory")
        try validatePrivateDirectory(directoryURL.path)
        try removeSocketIfSafe(socketURL, operation: "unlink existing control socket")
    }

    public static func validateBoundSocket(_ socketURL: URL) throws {
        guard let status = try lstatStatus(socketURL.path) else {
            throw OperatorControlServerError.unsafeSocketPath("socket path is missing after bind")
        }
        guard isSocket(status.st_mode) else {
            throw OperatorControlServerError.unsafeSocketPath("bound path is not a socket")
        }
        guard status.st_uid == getuid() else {
            throw OperatorControlServerError.unsafeSocketPath("bound socket owner does not match current user")
        }
        try chmodPath(socketURL.path, mode: S_IRUSR | S_IWUSR, operation: "chmod control socket")
    }

    public static func removeSocketIfSafe(_ socketURL: URL, operation: String) throws {
        guard let status = try lstatStatus(socketURL.path) else { return }
        guard isSocket(status.st_mode) else {
            throw OperatorControlServerError.unsafeSocketPath("existing path is not a socket")
        }
        guard status.st_uid == getuid() else {
            throw OperatorControlServerError.unsafeSocketPath("existing socket owner does not match current user")
        }
        guard unlink(socketURL.path) == 0 else {
            throw OperatorControlServerError.posix(operation: operation, errno: errno)
        }
    }

    private static func validatePrivateDirectory(_ path: String) throws {
        guard let status = try lstatStatus(path) else {
            throw OperatorControlServerError.unsafeSocketPath("control socket directory is missing")
        }
        guard !isSymlink(status.st_mode) else {
            throw OperatorControlServerError.unsafeSocketPath("control socket parent is a symlink")
        }
        guard isDirectory(status.st_mode) else {
            throw OperatorControlServerError.unsafeSocketPath("control socket parent is not a directory")
        }
        guard status.st_uid == getuid() else {
            throw OperatorControlServerError.unsafeSocketPath("control socket parent owner does not match current user")
        }
        guard (status.st_mode & (S_IRWXG | S_IRWXO)) == 0 else {
            throw OperatorControlServerError.unsafeSocketPath("control socket parent is accessible by group or others")
        }
    }

    private static func chmodPath(_ path: String, mode: mode_t, operation: String) throws {
        guard chmod(path, mode) == 0 else {
            throw OperatorControlServerError.posix(operation: operation, errno: errno)
        }
    }

    private static func lstatStatus(_ path: String) throws -> stat? {
        var status = stat()
        if lstat(path, &status) == 0 {
            return status
        }
        if errno == ENOENT {
            return nil
        }
        throw OperatorControlServerError.posix(operation: "lstat \(path)", errno: errno)
    }

    private static func isDirectory(_ mode: mode_t) -> Bool {
        (mode & S_IFMT) == S_IFDIR
    }

    private static func isSocket(_ mode: mode_t) -> Bool {
        (mode & S_IFMT) == S_IFSOCK
    }

    private static func isSymlink(_ mode: mode_t) -> Bool {
        (mode & S_IFMT) == S_IFLNK
    }
}

public actor OperatorControlServer {
    private let socketURL: URL
    private let router: CrossnetControlRouter
    private var listenerDescriptor: Int32?
    private var acceptTask: Task<Void, Never>?

    public init(socketURL: URL, router: CrossnetControlRouter) {
        self.socketURL = socketURL
        self.router = router
    }

    public init(router: CrossnetControlRouter) throws {
        self.socketURL = try OperatorControlSocketPathPolicy.defaultSocketURL()
        self.router = router
    }

    public func start() throws {
        guard listenerDescriptor == nil else { return }
        try OperatorControlSocketPathPolicy.prepareSocketURL(socketURL)

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw OperatorControlServerError.posix(operation: "socket", errno: errno)
        }

        do {
            try Self.setCloseOnExec(descriptor)
            try Self.bindUnixSocket(descriptor, socketURL: socketURL)
            guard listen(descriptor, SOMAXCONN) == 0 else {
                throw OperatorControlServerError.posix(operation: "listen", errno: errno)
            }
            try OperatorControlSocketPathPolicy.validateBoundSocket(socketURL)

            listenerDescriptor = descriptor
            acceptTask = Task.detached(priority: .utility) { [router] in
                await Self.acceptLoop(
                    listenerDescriptor: descriptor,
                    router: router
                )
            }
        } catch {
            let startError = error
            close(descriptor)
            do {
                try OperatorControlSocketPathPolicy.removeSocketIfSafe(
                    socketURL,
                    operation: "unlink failed control socket"
                )
            } catch {
                throw OperatorControlServerError.cleanupAfterStartFailure(
                    start: String(describing: startError),
                    cleanup: String(describing: error)
                )
            }
            throw startError
        }
    }

    public func stop() throws {
        acceptTask?.cancel()
        acceptTask = nil
        if let listenerDescriptor {
            close(listenerDescriptor)
            self.listenerDescriptor = nil
        }
        try OperatorControlSocketPathPolicy.removeSocketIfSafe(
            socketURL,
            operation: "unlink control socket"
        )
    }

    private nonisolated static func acceptLoop(
        listenerDescriptor: Int32,
        router: CrossnetControlRouter
    ) async {
        while !Task.isCancelled {
            let clientDescriptor = accept(listenerDescriptor, nil, nil)
            if clientDescriptor < 0 {
                if errno == EINTR {
                    continue
                }
                break
            }
            guard configureAcceptedClientDescriptor(clientDescriptor) else {
                close(clientDescriptor)
                continue
            }
            Task.detached(priority: .utility) {
                await handleClient(clientDescriptor, router: router)
            }
        }
    }

    private nonisolated static func handleClient(
        _ descriptor: Int32,
        router: CrossnetControlRouter
    ) async {
        defer { close(descriptor) }
        guard verifyCurrentUserPeer(descriptor) else {
            return
        }

        switch readRequestLine(descriptor) {
        case .line(let line):
            let response = await router.handleLine(line)
            writeResponse(response, descriptor: descriptor)
        case .tooLarge:
            let response = CrossnetControlWire.failureData(id: nil, failure: .requestTooLarge)
            writeResponse(response, descriptor: descriptor)
        case .unterminated:
            let response = CrossnetControlWire.failureData(
                id: nil,
                failure: .malformedRequest("missing newline terminator")
            )
            writeResponse(response, descriptor: descriptor)
        case .empty, .ioFailure:
            return
        }
    }

    private nonisolated static func verifyCurrentUserPeer(_ descriptor: Int32) -> Bool {
        var effectiveUserID = uid_t()
        var effectiveGroupID = gid_t()
        guard getpeereid(descriptor, &effectiveUserID, &effectiveGroupID) == 0 else {
            return false
        }
        return effectiveUserID == getuid()
    }

    private enum ReadRequestLineResult {
        case line(Data)
        case tooLarge
        case unterminated
        case empty
        case ioFailure
    }

    private nonisolated static func readRequestLine(_ descriptor: Int32) -> ReadRequestLineResult {
        var buffer = [UInt8]()
        buffer.reserveCapacity(1024)
        var byte = UInt8()
        while true {
            let count = Darwin.read(descriptor, &byte, 1)
            if count == 1 {
                if byte == 0x0A {
                    return buffer.isEmpty ? .empty : .line(Data(buffer))
                }
                buffer.append(byte)
                if buffer.count > CrossnetControlWire.maxLineByteCount {
                    return .tooLarge
                }
                continue
            }
            if count == 0 {
                return buffer.isEmpty ? .empty : .unterminated
            }
            if errno == EINTR {
                continue
            }
            return .ioFailure
        }
    }

    private nonisolated static func writeResponse(_ response: Data, descriptor: Int32) {
        var framed = response
        framed.append(0x0A)
        framed.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0, errno == EINTR {
                    continue
                }
                return
            }
        }
    }

    private nonisolated static func setCloseOnExec(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFD)
        guard flags >= 0 else {
            throw OperatorControlServerError.posix(operation: "fcntl F_GETFD", errno: errno)
        }
        guard fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0 else {
            throw OperatorControlServerError.posix(operation: "fcntl F_SETFD", errno: errno)
        }
    }

    private nonisolated static func configureAcceptedClientDescriptor(_ descriptor: Int32) -> Bool {
        do {
            try setCloseOnExec(descriptor)
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            let result = setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_RCVTIMEO,
                &timeout,
                socklen_t(MemoryLayout<timeval>.size)
            )
            return result == 0
        } catch {
            return false
        }
    }

    private nonisolated static func bindUnixSocket(_ descriptor: Int32, socketURL: URL) throws {
        let pathBytes = Array(socketURL.path.utf8)
        var address = sockaddr_un()
        let maxPathBytes = MemoryLayout.size(ofValue: address.sun_path) - 1
        guard pathBytes.count <= maxPathBytes else {
            throw OperatorControlServerError.socketPathTooLong(pathBytes.count)
        }

        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: maxPathBytes + 1) { destination in
                for index in 0..<pathBytes.count {
                    destination[index] = CChar(bitPattern: pathBytes[index])
                }
                destination[pathBytes.count] = 0
            }
        }

        let length = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count + 1)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                Darwin.bind(descriptor, socketPointer, length)
            }
        }
        guard result == 0 else {
            throw OperatorControlServerError.posix(operation: "bind", errno: errno)
        }
    }
}
#endif
