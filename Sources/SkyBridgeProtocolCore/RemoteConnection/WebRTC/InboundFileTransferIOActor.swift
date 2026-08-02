import CryptoKit
import Foundation
import Darwin

/// Canonicalizes only Darwin's fixed, system-owned root aliases before secure
/// descriptor traversal. It deliberately does not resolve deeper symbolic links:
/// those remain visible to `O_NOFOLLOW` and are rejected at the I/O boundary.
@available(macOS 14.0, iOS 17.0, *)
public enum DarwinSecurePathPolicy {
    public enum PolicyError: Error, Sendable, Equatable {
        case invalidAbsoluteFileURL
    }

    public static func canonicalizingSystemRootAlias(_ url: URL) throws -> URL {
        let standardized = url.standardizedFileURL
        guard standardized.isFileURL, standardized.path.hasPrefix("/") else {
            throw PolicyError.invalidAbsoluteFileURL
        }

        let path = standardized.path
        let systemRootAliases = ["/var", "/tmp", "/etc"]
        guard let alias = systemRootAliases.first(where: {
            path == $0 || path.hasPrefix($0 + "/")
        }) else {
            return standardized
        }

        let suffix = path.dropFirst(alias.count)
        return URL(
            fileURLWithPath: "/private\(alias)\(suffix)",
            isDirectory: standardized.hasDirectoryPath
        )
    }

    struct DirectoryTraversalPlan: Equatable {
        let anchorURL: URL
        let relativeComponents: [String]
        let requiresOwnedAnchor: Bool
    }

    /// Mobile application sandboxes grant access to the app container without granting
    /// directory traversal across every ancestor above that container. Anchor descriptor
    /// traversal at the system-provided container root, then keep `O_NOFOLLOW` for every
    /// application-controlled descendant. Targets outside the trusted root retain the
    /// stricter filesystem-root traversal and therefore fail closed when the sandbox denies it.
    static func directoryTraversalPlan(
        targetURL: URL,
        trustedContainerRootURL: URL?
    ) throws -> DirectoryTraversalPlan {
        let target = try canonicalizingSystemRootAlias(targetURL)
        if let trustedContainerRootURL {
            let trustedRoot = try canonicalizingSystemRootAlias(trustedContainerRootURL)
            let trustedRootPath = trustedRoot.path == "/"
                ? "/"
                : trustedRoot.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    .withLeadingSlash
            let targetPath = target.path
            if targetPath == trustedRootPath
                || targetPath.hasPrefix(trustedRootPath + "/") {
                let suffix = targetPath.dropFirst(trustedRootPath.count)
                return DirectoryTraversalPlan(
                    anchorURL: URL(
                        fileURLWithPath: trustedRootPath,
                        isDirectory: true
                    ),
                    relativeComponents: suffix.split(separator: "/").map(String.init),
                    requiresOwnedAnchor: true
                )
            }
        }

        return DirectoryTraversalPlan(
            anchorURL: URL(fileURLWithPath: "/", isDirectory: true),
            relativeComponents: Array(target.pathComponents.dropFirst()),
            requiresOwnedAnchor: false
        )
    }
}

private extension String {
    var withLeadingSlash: String {
        hasPrefix("/") ? self : "/\(self)"
    }
}

@available(macOS 14.0, iOS 17.0, *)
public struct InboundFileTransferIOHandle: Hashable, Sendable {
    fileprivate let rawValue: UUID

    fileprivate init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

@available(macOS 14.0, iOS 17.0, *)
public enum InboundFileTransferIOError: Error, LocalizedError, Sendable, Equatable {
    case capacityExceeded
    case destinationUnavailable
    case crossDeviceCommitUnsupported
    case invalidDestination(String)
    case temporaryFileAlreadyExists
    case unknownHandle
    case writeAfterClose
    case writeOutOfBounds
    case dataDigestMismatch
    case createFailed(String)
    case writeFailed(String)
    case closeFailed(String)
    case hashFailed(String)
    case commitBeforeClose
    case releaseBeforeCommit
    case moveFailed(String)
    case cleanupFailed(String)

    public var errorDescription: String? {
        switch self {
        case .capacityExceeded:
            return "Inbound file I/O capacity exceeded"
        case .destinationUnavailable:
            return "Inbound file destination is unavailable or not writable"
        case .crossDeviceCommitUnsupported:
            return "Inbound staging and destination directories are on different file systems"
        case .invalidDestination(let reason):
            return "Invalid inbound file destination: \(reason)"
        case .temporaryFileAlreadyExists:
            return "Inbound temporary file already exists"
        case .unknownHandle:
            return "Unknown inbound file I/O handle"
        case .writeAfterClose:
            return "Inbound file write attempted after close"
        case .writeOutOfBounds:
            return "Inbound file write exceeds declared size"
        case .dataDigestMismatch:
            return "Inbound file data digest mismatch"
        case .createFailed(let details):
            return "Inbound temporary file creation failed: \(details)"
        case .writeFailed(let details):
            return "Inbound file write failed: \(details)"
        case .closeFailed(let details):
            return "Inbound file close failed: \(details)"
        case .hashFailed(let details):
            return "Inbound file hash failed: \(details)"
        case .commitBeforeClose:
            return "Inbound file commit attempted before close and digest"
        case .releaseBeforeCommit:
            return "Inbound file I/O state release attempted before commit"
        case .moveFailed(let details):
            return "Inbound file commit failed: \(details)"
        case .cleanupFailed(let details):
            return "Inbound file cleanup failed: \(details)"
        }
    }
}

/// Owns every blocking inbound file operation away from UI actors.
///
/// The actor is deliberately bounded and serial: each transfer has an opaque
/// handle, while one executor owns all FileHandle and FileManager access. This
/// prevents UI-thread blocking and prevents concurrent seek/write races.
@available(macOS 14.0, iOS 17.0, *)
public actor InboundFileTransferIOActor {
    public static let shared = InboundFileTransferIOActor()

    private struct TransferState {
        let temporaryURL: URL
        let declaredFileSize: Int64
        let deviceIdentifier: UInt64
        let inodeIdentifier: UInt64
        var writer: FileHandle?
        var digest: Data?
        var closeFailure: String?
        var committedURL: URL?
    }

    private let maxOpenTransfers: Int
    private var transfers: [InboundFileTransferIOHandle: TransferState] = [:]

    public init(maxOpenTransfers: Int = 32) {
        precondition(maxOpenTransfers > 0, "Inbound file I/O capacity must be positive")
        self.maxOpenTransfers = maxOpenTransfers
    }

    /// Fails before any payload is received when an atomic rename cannot be
    /// guaranteed because staging and destination reside on different devices.
    public func validateSameVolumeCommit(
        stagingURL: URL,
        destinationDirectory: URL
    ) throws {
        try Task.checkCancellation()
        try Self.withDirectoryDescriptor(
            at: stagingURL.deletingLastPathComponent(),
            createIfMissing: true,
            makeFinalComponentPrivate: true
        ) { stagingDirectoryFD in
            var stagingStatus = stat()
            guard fstat(stagingDirectoryFD, &stagingStatus) == 0,
                  Self.isDirectory(stagingStatus.st_mode) else {
                throw InboundFileTransferIOError.invalidDestination(
                    "staging directory identity unavailable"
                )
            }
            try Self.withDirectoryDescriptor(
                at: destinationDirectory,
                createIfMissing: true,
                makeFinalComponentPrivate: false
            ) { destinationDirectoryFD in
                var destinationStatus = stat()
                guard fstat(destinationDirectoryFD, &destinationStatus) == 0,
                      Self.isDirectory(destinationStatus.st_mode) else {
                    throw InboundFileTransferIOError.invalidDestination(
                        "destination directory identity unavailable"
                    )
                }
                guard stagingStatus.st_dev == destinationStatus.st_dev else {
                    throw InboundFileTransferIOError.crossDeviceCommitUnsupported
                }
            }
        }
    }

    public func createTemporaryFile(
        at temporaryURL: URL,
        declaredFileSize: Int64
    ) throws -> InboundFileTransferIOHandle {
        try Task.checkCancellation()
        guard declaredFileSize >= 0 else {
            throw InboundFileTransferIOError.writeOutOfBounds
        }
        guard transfers.count < maxOpenTransfers else {
            throw InboundFileTransferIOError.capacityExceeded
        }
        let fileName = try Self.validatedDirectChildFileName(
            temporaryURL,
            errorReason: "temporary file must be a direct child"
        )
        let directoryURL = temporaryURL.deletingLastPathComponent()
        let directoryFD = try Self.openDirectory(
            at: directoryURL,
            createIfMissing: true,
            makeFinalComponentPrivate: true
        )
        let flags = O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC
        let fileFD = fileName.withCString { pointer in
            openat(directoryFD, pointer, flags, mode_t(0o600))
        }
        guard fileFD >= 0 else {
            let openError = errno
            let closeResult = Darwin.close(directoryFD)
            guard closeResult == 0 else {
                throw InboundFileTransferIOError.createFailed("temporary directory close failed")
            }
            if openError == EEXIST || openError == ELOOP {
                throw InboundFileTransferIOError.temporaryFileAlreadyExists
            }
            throw InboundFileTransferIOError.createFailed("exclusive temporary file open failed")
        }

        var status = stat()
        guard fstat(fileFD, &status) == 0,
              Self.isRegularFile(status.st_mode),
              status.st_uid == geteuid(),
              status.st_size == 0,
              fchmod(fileFD, mode_t(0o600)) == 0 else {
            let fileCloseResult = Darwin.close(fileFD)
            let cleanupResult = fileName.withCString { unlinkat(directoryFD, $0, 0) }
            let cleanupError = errno
            let directoryCloseResult = Darwin.close(directoryFD)
            guard fileCloseResult == 0,
                  cleanupResult == 0 || cleanupError == ENOENT,
                  directoryCloseResult == 0 else {
                throw InboundFileTransferIOError.createFailed("temporary file validation cleanup failed")
            }
            throw InboundFileTransferIOError.createFailed("temporary file validation failed")
        }
        guard Darwin.close(directoryFD) == 0 else {
            let fileCloseResult = Darwin.close(fileFD)
            guard fileCloseResult == 0 else {
                throw InboundFileTransferIOError.createFailed("temporary file cleanup failed")
            }
            throw InboundFileTransferIOError.createFailed("temporary directory close failed")
        }

        let writer = FileHandle(fileDescriptor: fileFD, closeOnDealloc: true)
        let handle = InboundFileTransferIOHandle()
        transfers[handle] = TransferState(
            temporaryURL: temporaryURL,
            declaredFileSize: declaredFileSize,
            deviceIdentifier: UInt64(status.st_dev),
            inodeIdentifier: UInt64(status.st_ino),
            writer: writer,
            digest: nil,
            closeFailure: nil,
            committedURL: nil
        )
        return handle
    }

    /// Reopens an explicitly isolated partial file for classic-transfer resume.
    /// The file is truncated to the authenticated/negotiated resume offset so stale
    /// trailing bytes can never survive into the resumed transfer.
    public func resumeTemporaryFile(
        at temporaryURL: URL,
        isolatedDirectory: URL,
        declaredFileSize: Int64,
        resumeOffset: Int64
    ) throws -> InboundFileTransferIOHandle {
        try Task.checkCancellation()
        guard declaredFileSize >= 0,
              resumeOffset >= 0,
              resumeOffset <= declaredFileSize else {
            throw InboundFileTransferIOError.writeOutOfBounds
        }
        guard transfers.count < maxOpenTransfers else {
            throw InboundFileTransferIOError.capacityExceeded
        }
        guard Self.isDirectChild(temporaryURL, of: isolatedDirectory) else {
            throw InboundFileTransferIOError.invalidDestination("resume partial escaped isolation directory")
        }

        let fileName = try Self.validatedDirectChildFileName(
            temporaryURL,
            errorReason: "resume partial must be a direct child"
        )
        let directoryFD = try Self.openDirectory(
            at: isolatedDirectory,
            createIfMissing: false,
            makeFinalComponentPrivate: true
        )
        let flags = O_RDWR | O_NOFOLLOW | O_CLOEXEC
        let fileFD = fileName.withCString { openat(directoryFD, $0, flags) }
        guard fileFD >= 0 else {
            let closeResult = Darwin.close(directoryFD)
            guard closeResult == 0 else {
                throw InboundFileTransferIOError.createFailed("resume directory close failed")
            }
            throw InboundFileTransferIOError.createFailed("resume partial open failed")
        }

        var status = stat()
        guard fstat(fileFD, &status) == 0,
              Self.isRegularFile(status.st_mode),
              status.st_uid == geteuid(),
              status.st_size >= off_t(resumeOffset),
              status.st_size <= off_t(declaredFileSize),
              status.st_mode & mode_t(0o077) == 0 else {
            let fileCloseResult = Darwin.close(fileFD)
            let directoryCloseResult = Darwin.close(directoryFD)
            guard fileCloseResult == 0, directoryCloseResult == 0 else {
                throw InboundFileTransferIOError.createFailed("resume validation close failed")
            }
            throw InboundFileTransferIOError.createFailed("resume partial contract mismatch")
        }
        guard ftruncate(fileFD, off_t(resumeOffset)) == 0,
              fsync(fileFD) == 0 else {
            let fileCloseResult = Darwin.close(fileFD)
            let directoryCloseResult = Darwin.close(directoryFD)
            guard fileCloseResult == 0, directoryCloseResult == 0 else {
                throw InboundFileTransferIOError.createFailed("resume truncate close failed")
            }
            throw InboundFileTransferIOError.createFailed("resume partial truncate failed")
        }
        guard Darwin.close(directoryFD) == 0 else {
            let fileCloseResult = Darwin.close(fileFD)
            guard fileCloseResult == 0 else {
                throw InboundFileTransferIOError.createFailed("resume descriptor close failed")
            }
            throw InboundFileTransferIOError.createFailed("resume directory close failed")
        }

        let writer = FileHandle(fileDescriptor: fileFD, closeOnDealloc: true)

        let handle = InboundFileTransferIOHandle()
        transfers[handle] = TransferState(
            temporaryURL: temporaryURL,
            declaredFileSize: declaredFileSize,
            deviceIdentifier: UInt64(status.st_dev),
            inodeIdentifier: UInt64(status.st_ino),
            writer: writer,
            digest: nil,
            closeFailure: nil,
            committedURL: nil
        )
        return handle
    }

    public func prepareFirstWritableDirectory(from candidates: [URL]) throws -> URL {
        try Task.checkCancellation()
        var seenPaths = Set<String>()
        for candidate in candidates {
            let standardized = candidate.standardizedFileURL
            guard seenPaths.insert(standardized.path).inserted else { continue }
            do {
                try Self.withDirectoryDescriptor(
                    at: standardized,
                    createIfMissing: true,
                    makeFinalComponentPrivate: false
                ) { directoryFD in
                    try Self.verifyWritableDirectory(directoryFD)
                }
                return standardized
            } catch is CancellationError {
                throw CancellationError()
            } catch InboundFileTransferIOError.destinationUnavailable {
                continue
            } catch {
                throw error
            }
        }
        throw InboundFileTransferIOError.invalidDestination("no writable receive directory")
    }

    public func write(
        _ data: Data,
        atOffset offset: UInt64,
        using handle: InboundFileTransferIOHandle,
        expectedSHA256: Data? = nil
    ) throws -> Data {
        try Task.checkCancellation()
        let digest = Data(SHA256.hash(data: data))
        if let expectedSHA256, digest != expectedSHA256 {
            throw InboundFileTransferIOError.dataDigestMismatch
        }
        guard var state = transfers[handle] else {
            throw InboundFileTransferIOError.unknownHandle
        }
        if let closeFailure = state.closeFailure {
            throw InboundFileTransferIOError.closeFailed(closeFailure)
        }
        guard let writer = state.writer else {
            throw InboundFileTransferIOError.writeAfterClose
        }
        guard offset <= UInt64(Int64.max),
              Int64(offset) <= state.declaredFileSize,
              Int64(data.count) <= state.declaredFileSize - Int64(offset) else {
            throw InboundFileTransferIOError.writeOutOfBounds
        }

        do {
            try writer.seek(toOffset: offset)
            try writer.write(contentsOf: data)
            state.digest = nil
            transfers[handle] = state
            return digest
        } catch {
            throw InboundFileTransferIOError.writeFailed(error.localizedDescription)
        }
    }

    public func digest(
        _ data: Data,
        expectedSHA256: Data? = nil
    ) throws -> Data {
        try Task.checkCancellation()
        let digest = Data(SHA256.hash(data: data))
        if let expectedSHA256, digest != expectedSHA256 {
            throw InboundFileTransferIOError.dataDigestMismatch
        }
        return digest
    }

    public func closeAndDigest(using handle: InboundFileTransferIOHandle) throws -> Data {
        try Task.checkCancellation()
        guard var state = transfers[handle] else {
            throw InboundFileTransferIOError.unknownHandle
        }
        if let closeFailure = state.closeFailure {
            throw InboundFileTransferIOError.closeFailed(closeFailure)
        }
        if let digest = state.digest {
            return digest
        }
        guard let writer = state.writer else {
            throw InboundFileTransferIOError.hashFailed("temporary file descriptor unavailable")
        }

        var status = stat()
        guard fstat(writer.fileDescriptor, &status) == 0,
              Self.isRegularFile(status.st_mode),
              status.st_uid == geteuid(),
              UInt64(status.st_dev) == state.deviceIdentifier,
              UInt64(status.st_ino) == state.inodeIdentifier,
              status.st_size == off_t(state.declaredFileSize) else {
            throw InboundFileTransferIOError.hashFailed("temporary file identity or size changed")
        }

        var hasher = SHA256()
        var bytesHashed: Int64 = 0
        do {
            guard fsync(writer.fileDescriptor) == 0 else {
                throw InboundFileTransferIOError.hashFailed("temporary file sync failed")
            }
            try writer.seek(toOffset: 0)
            while true {
                try Task.checkCancellation()
                guard let chunk = try writer.read(upToCount: 256 * 1_024), !chunk.isEmpty else {
                    break
                }
                guard bytesHashed <= state.declaredFileSize - Int64(chunk.count) else {
                    throw InboundFileTransferIOError.hashFailed("temporary file grew while hashing")
                }
                hasher.update(data: chunk)
                bytesHashed += Int64(chunk.count)
            }
            guard bytesHashed == state.declaredFileSize else {
                throw InboundFileTransferIOError.hashFailed("temporary file size changed while hashing")
            }
            try writer.close()
            state.writer = nil
            let digest = Data(hasher.finalize())
            state.digest = digest
            transfers[handle] = state
            return digest
        } catch {
            let originalError = error
            let closeResult: Swift.Result<Void, Error>
            do {
                try writer.close()
                closeResult = .success(())
            } catch {
                closeResult = .failure(error)
            }
            state.writer = nil
            if case .failure(let closeError) = closeResult {
                let combinedFailure = [
                    "hash: \(originalError.localizedDescription)",
                    "close: \(closeError.localizedDescription)"
                ].joined(separator: "; ")
                state.closeFailure = combinedFailure
                transfers[handle] = state
                throw InboundFileTransferIOError.closeFailed(combinedFailure)
            }
            transfers[handle] = state
            if originalError is CancellationError {
                throw CancellationError()
            }
            if let typedError = originalError as? InboundFileTransferIOError {
                throw typedError
            }
            throw InboundFileTransferIOError.hashFailed(originalError.localizedDescription)
        }
    }

    public func commit(
        using handle: InboundFileTransferIOHandle,
        destinationDirectory: URL,
        fileName: String
    ) throws -> URL {
        try Task.checkCancellation()
        guard let state = transfers[handle] else {
            throw InboundFileTransferIOError.unknownHandle
        }
        if let closeFailure = state.closeFailure {
            throw InboundFileTransferIOError.closeFailed(closeFailure)
        }
        guard state.writer == nil, state.digest != nil else {
            throw InboundFileTransferIOError.commitBeforeClose
        }
        if let committedURL = state.committedURL {
            return committedURL
        }

        do {
            let validatedFileName = try Self.validatedDestinationFileName(fileName)
            let temporaryName = try Self.validatedDirectChildFileName(
                state.temporaryURL,
                errorReason: "temporary file is not a direct child"
            )
            return try Self.withDirectoryDescriptor(
                at: state.temporaryURL.deletingLastPathComponent(),
                createIfMissing: false,
                makeFinalComponentPrivate: true
            ) { temporaryDirectoryFD in
                var status = stat()
                let statusResult = temporaryName.withCString {
                    fstatat(temporaryDirectoryFD, $0, &status, AT_SYMLINK_NOFOLLOW)
                }
                guard statusResult == 0,
                      Self.isRegularFile(status.st_mode),
                      status.st_uid == geteuid(),
                      UInt64(status.st_dev) == state.deviceIdentifier,
                      UInt64(status.st_ino) == state.inodeIdentifier,
                      status.st_size == off_t(state.declaredFileSize) else {
                    throw InboundFileTransferIOError.moveFailed(
                        "temporary file identity changed before commit"
                    )
                }

                return try Self.withDirectoryDescriptor(
                    at: destinationDirectory,
                    createIfMissing: true,
                    makeFinalComponentPrivate: false
                ) { destinationDirectoryFD in
                    var destinationStatus = stat()
                    guard fstat(destinationDirectoryFD, &destinationStatus) == 0,
                          Self.isDirectory(destinationStatus.st_mode) else {
                        throw InboundFileTransferIOError.invalidDestination(
                            "destination directory identity unavailable at commit"
                        )
                    }
                    guard UInt64(destinationStatus.st_dev) == state.deviceIdentifier else {
                        throw InboundFileTransferIOError.crossDeviceCommitUnsupported
                    }
                    for suffix in 0..<10_000 {
                        let candidateName = Self.destinationFileName(
                            validatedFileName,
                            suffix: suffix
                        )
                        let renameResult = temporaryName.withCString { sourcePointer in
                            candidateName.withCString { destinationPointer in
                                renameatx_np(
                                    temporaryDirectoryFD,
                                    sourcePointer,
                                    destinationDirectoryFD,
                                    destinationPointer,
                                    UInt32(RENAME_EXCL)
                                )
                            }
                        }
                        if renameResult == 0 {
                            let destinationURL = destinationDirectory.standardizedFileURL
                                .appendingPathComponent(candidateName, isDirectory: false)
                            var committedState = state
                            committedState.committedURL = destinationURL
                            transfers[handle] = committedState

                            var committedStatus = stat()
                            let committedStatusResult = candidateName.withCString {
                                fstatat(
                                    destinationDirectoryFD,
                                    $0,
                                    &committedStatus,
                                    AT_SYMLINK_NOFOLLOW
                                )
                            }
                            guard committedStatusResult == 0,
                                  Self.isRegularFile(committedStatus.st_mode),
                                  committedStatus.st_uid == geteuid(),
                                  UInt64(committedStatus.st_dev) == state.deviceIdentifier,
                                  UInt64(committedStatus.st_ino) == state.inodeIdentifier,
                                  committedStatus.st_size == off_t(state.declaredFileSize) else {
                                throw InboundFileTransferIOError.moveFailed(
                                    "committed file identity changed after rename"
                                )
                            }
                            guard fsync(temporaryDirectoryFD) == 0,
                                  fsync(destinationDirectoryFD) == 0 else {
                                throw InboundFileTransferIOError.moveFailed(
                                    "committed directory sync failed"
                                )
                            }
                            return destinationURL
                        }
                        guard errno == EEXIST else {
                            throw InboundFileTransferIOError.moveFailed(
                                "exclusive temporary file rename failed"
                            )
                        }
                    }
                    throw InboundFileTransferIOError.moveFailed(
                        "destination collision limit exceeded"
                    )
                }
            }
        } catch let error as InboundFileTransferIOError {
            throw error
        } catch {
            throw InboundFileTransferIOError.moveFailed(error.localizedDescription)
        }
    }

    /// Releases actor bookkeeping after the caller has atomically published a
    /// successful terminal receipt on its lifecycle actor.
    public func releaseCommittedFile(using handle: InboundFileTransferIOHandle) throws {
        guard let state = transfers[handle] else {
            throw InboundFileTransferIOError.unknownHandle
        }
        guard state.committedURL != nil else {
            throw InboundFileTransferIOError.releaseBeforeCommit
        }
        transfers.removeValue(forKey: handle)
    }

    public func discard(_ handle: InboundFileTransferIOHandle) throws {
        try discard(handle, preservingCommittedFile: false)
    }

    /// Cancels an in-flight receive without ever rolling back an atomic commit.
    /// This is the only cancellation primitive WebRTC lifecycles should use: a
    /// channel-close task can race the actor's `commit`, and once that commit has
    /// won the file is durable even if the UI lifecycle has already changed.
    public func discardUncommittedFile(_ handle: InboundFileTransferIOHandle) throws {
        try discard(handle, preservingCommittedFile: true)
    }

    private func discard(
        _ handle: InboundFileTransferIOHandle,
        preservingCommittedFile: Bool
    ) throws {
        guard var state = transfers[handle] else { return }

        if preservingCommittedFile, state.committedURL != nil {
            transfers.removeValue(forKey: handle)
            return
        }

        var failures: [String] = []
        if let writer = state.writer {
            do {
                try writer.close()
                state.writer = nil
            } catch {
                failures.append("close: \(error.localizedDescription)")
            }
        }
        let fileURL = state.committedURL ?? state.temporaryURL
        do {
            try Self.removeIdentityBoundFileIfPresent(
                at: fileURL,
                deviceIdentifier: state.deviceIdentifier,
                inodeIdentifier: state.inodeIdentifier,
                requiresPrivateDirectory: state.committedURL == nil
            )
        } catch {
            failures.append("remove: \(error.localizedDescription)")
        }
        if !failures.isEmpty {
            // Preserve ownership until every cleanup step succeeds. A close or
            // unlink failure is retryable; dropping the handle here would leak an
            // unreachable partial and permanently block the same transfer ID.
            transfers[handle] = state
            throw InboundFileTransferIOError.cleanupFailed(failures.joined(separator: "; "))
        }
        transfers.removeValue(forKey: handle)
    }

    /// Closes and releases actor bookkeeping while intentionally preserving the
    /// isolated partial file for an authenticated classic-transfer resume.
    public func suspendForResume(_ handle: InboundFileTransferIOHandle) throws {
        guard let state = transfers[handle] else {
            throw InboundFileTransferIOError.unknownHandle
        }
        guard state.committedURL == nil else {
            throw InboundFileTransferIOError.releaseBeforeCommit
        }
        if let writer = state.writer {
            do {
                var descriptorStatus = stat()
                guard fstat(writer.fileDescriptor, &descriptorStatus) == 0,
                      Self.isRegularFile(descriptorStatus.st_mode),
                      descriptorStatus.st_uid == geteuid(),
                      descriptorStatus.st_mode & mode_t(0o077) == 0,
                      UInt64(descriptorStatus.st_dev) == state.deviceIdentifier,
                      UInt64(descriptorStatus.st_ino) == state.inodeIdentifier,
                      descriptorStatus.st_size >= 0,
                      descriptorStatus.st_size <= off_t(state.declaredFileSize) else {
                    throw InboundFileTransferIOError.closeFailed(
                        "resume partial descriptor identity changed"
                    )
                }
                let fileName = try Self.validatedDirectChildFileName(
                    state.temporaryURL,
                    errorReason: "resume partial is not a direct child"
                )
                try Self.withDirectoryDescriptor(
                    at: state.temporaryURL.deletingLastPathComponent(),
                    createIfMissing: false,
                    makeFinalComponentPrivate: true
                ) { directoryFD in
                    var pathStatus = stat()
                    let statusResult = fileName.withCString {
                        fstatat(directoryFD, $0, &pathStatus, AT_SYMLINK_NOFOLLOW)
                    }
                    guard statusResult == 0,
                          Self.isRegularFile(pathStatus.st_mode),
                          pathStatus.st_uid == geteuid(),
                          UInt64(pathStatus.st_dev) == state.deviceIdentifier,
                          UInt64(pathStatus.st_ino) == state.inodeIdentifier else {
                        throw InboundFileTransferIOError.closeFailed(
                            "resume partial path identity changed"
                        )
                    }
                }
                guard fsync(writer.fileDescriptor) == 0 else {
                    throw InboundFileTransferIOError.closeFailed("resume partial sync failed")
                }
                try writer.close()
            } catch let error as InboundFileTransferIOError {
                throw error
            } catch {
                throw InboundFileTransferIOError.closeFailed(error.localizedDescription)
            }
        }
        transfers.removeValue(forKey: handle)
    }

    public func discardSuspendedPartial(
        at temporaryURL: URL,
        isolatedDirectory: URL
    ) throws {
        // Terminal cleanup is intentionally non-cancellable. Transport task
        // cancellation must not strand an owned partial file on disk.
        guard Self.isDirectChild(temporaryURL, of: isolatedDirectory) else {
            throw InboundFileTransferIOError.invalidDestination("partial cleanup escaped isolation directory")
        }
        do {
            let fileName = try Self.validatedDirectChildFileName(
                temporaryURL,
                errorReason: "partial cleanup target is not a direct child"
            )
            try Self.withDirectoryDescriptor(
                at: isolatedDirectory,
                createIfMissing: false,
                makeFinalComponentPrivate: true
            ) { directoryFD in
                var status = stat()
                let statusResult = fileName.withCString {
                    fstatat(directoryFD, $0, &status, AT_SYMLINK_NOFOLLOW)
                }
                if statusResult != 0, errno == ENOENT {
                    return
                }
                guard statusResult == 0,
                      Self.isRegularFile(status.st_mode),
                      status.st_uid == geteuid() else {
                    throw InboundFileTransferIOError.invalidDestination(
                        "partial cleanup target is not an owned regular file"
                    )
                }
                guard fileName.withCString({ unlinkat(directoryFD, $0, 0) }) == 0,
                      fsync(directoryFD) == 0 else {
                    throw InboundFileTransferIOError.cleanupFailed(
                        "partial cleanup unlink failed"
                    )
                }
            }
        } catch let error as InboundFileTransferIOError {
            throw error
        } catch {
            throw InboundFileTransferIOError.cleanupFailed(error.localizedDescription)
        }
    }

    public func activeTransferCount() -> Int {
        transfers.count
    }

    private static func validatedDestinationFileName(_ fileName: String) throws -> String {
        do {
            try ClassicTransferMetadataContract.validateFileName(fileName)
        } catch {
            throw InboundFileTransferIOError.invalidDestination("unsafe file name")
        }
        return fileName
    }

    private static func destinationFileName(_ fileName: String, suffix: Int) -> String {
        guard suffix > 0 else { return fileName }
        let suffixText = " (\(suffix))"
        let fileExtension = (fileName as NSString).pathExtension
        let originalStem = (fileName as NSString).deletingPathExtension
        var extensionText = fileExtension.isEmpty ? "" : ".\(fileExtension)"
        let availableBytes = 255 - suffixText.utf8.count
        if extensionText.utf8.count >= availableBytes {
            extensionText = ""
        }
        var stem = utf8SafePrefix(
            originalStem,
            maximumByteCount: availableBytes - extensionText.utf8.count
        )
        if stem.isEmpty {
            extensionText = ""
            stem = utf8SafePrefix(fileName, maximumByteCount: availableBytes)
        }
        return stem + suffixText + extensionText
    }

    private static func utf8SafePrefix(
        _ value: String,
        maximumByteCount: Int
    ) -> String {
        guard maximumByteCount > 0 else { return "" }
        var result = ""
        var usedBytes = 0
        for character in value {
            let characterBytes = String(character).utf8.count
            guard usedBytes + characterBytes <= maximumByteCount else { break }
            result.append(character)
            usedBytes += characterBytes
        }
        return result
    }

    private static func validatedDirectChildFileName(
        _ fileURL: URL,
        errorReason: String
    ) throws -> String {
        let standardized = fileURL.standardizedFileURL
        let fileName = standardized.lastPathComponent
        guard standardized.isFileURL,
              !fileName.isEmpty,
              fileName != ".",
              fileName != "..",
              fileName == (fileName as NSString).lastPathComponent else {
            throw InboundFileTransferIOError.invalidDestination(errorReason)
        }
        return fileName
    }

    private static func withDirectoryDescriptor<Result>(
        at directoryURL: URL,
        createIfMissing: Bool,
        makeFinalComponentPrivate: Bool,
        _ operation: (Int32) throws -> Result
    ) throws -> Result {
        let directoryFD = try openDirectory(
            at: directoryURL,
            createIfMissing: createIfMissing,
            makeFinalComponentPrivate: makeFinalComponentPrivate
        )
        let result: Swift.Result<Result, Error>
        do {
            result = .success(try operation(directoryFD))
        } catch {
            result = .failure(error)
        }
        guard Darwin.close(directoryFD) == 0 else {
            throw InboundFileTransferIOError.invalidDestination("directory descriptor close failed")
        }
        return try result.get()
    }

    private static func openDirectory(
        at directoryURL: URL,
        createIfMissing: Bool,
        makeFinalComponentPrivate: Bool
    ) throws -> Int32 {
        let standardized: URL
        do {
            standardized = try DarwinSecurePathPolicy.canonicalizingSystemRootAlias(directoryURL)
        } catch {
            throw InboundFileTransferIOError.invalidDestination("directory must be an absolute file URL")
        }
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        let trustedContainerRoot: URL?
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        trustedContainerRoot = URL(
            fileURLWithPath: NSHomeDirectory(),
            isDirectory: true
        )
        #else
        trustedContainerRoot = nil
        #endif
        let traversalPlan: DarwinSecurePathPolicy.DirectoryTraversalPlan
        do {
            traversalPlan = try DarwinSecurePathPolicy.directoryTraversalPlan(
                targetURL: standardized,
                trustedContainerRootURL: trustedContainerRoot
            )
        } catch {
            throw InboundFileTransferIOError.invalidDestination(
                "directory traversal anchor is invalid"
            )
        }
        var currentFD = Darwin.open(traversalPlan.anchorURL.path, flags)
        guard currentFD >= 0 else {
            throw InboundFileTransferIOError.invalidDestination(
                traversalPlan.requiresOwnedAnchor
                    ? "trusted container root open failed"
                    : "root directory open failed"
            )
        }

        if traversalPlan.requiresOwnedAnchor {
            var anchorStatus = stat()
            guard fstat(currentFD, &anchorStatus) == 0,
                  isDirectory(anchorStatus.st_mode),
                  anchorStatus.st_uid == geteuid() else {
                let closeResult = Darwin.close(currentFD)
                guard closeResult == 0 else {
                    throw InboundFileTransferIOError.invalidDestination(
                        "trusted container root validation close failed"
                    )
                }
                throw InboundFileTransferIOError.invalidDestination(
                    "trusted container root validation failed"
                )
            }
        }

        let components = traversalPlan.relativeComponents
        for (index, component) in components.enumerated() {
            guard !component.isEmpty, component != ".", component != "..", component != "/" else {
                let closeResult = Darwin.close(currentFD)
                guard closeResult == 0 else {
                    throw InboundFileTransferIOError.invalidDestination("invalid path close failed")
                }
                throw InboundFileTransferIOError.invalidDestination("unsafe directory component")
            }
            var childFD = component.withCString { openat(currentFD, $0, flags) }
            if childFD < 0, errno == ENOENT, createIfMissing {
                let createResult = component.withCString {
                    mkdirat(currentFD, $0, mode_t(0o700))
                }
                let createError = errno
                guard createResult == 0 || createError == EEXIST else {
                    let closeResult = Darwin.close(currentFD)
                    guard closeResult == 0 else {
                        throw InboundFileTransferIOError.invalidDestination(
                            "directory creation close failed"
                        )
                    }
                    if isUnavailableErrno(createError) {
                        throw InboundFileTransferIOError.destinationUnavailable
                    }
                    throw InboundFileTransferIOError.invalidDestination("directory creation failed")
                }
                childFD = component.withCString { openat(currentFD, $0, flags) }
            }
            let childOpenError = errno
            guard childFD >= 0 else {
                let closeResult = Darwin.close(currentFD)
                guard closeResult == 0 else {
                    throw InboundFileTransferIOError.invalidDestination("directory open close failed")
                }
                if isUnavailableErrno(childOpenError) {
                    throw InboundFileTransferIOError.destinationUnavailable
                }
                throw InboundFileTransferIOError.invalidDestination(
                    "directory component \(index) open failed (errno \(childOpenError))"
                )
            }
            var status = stat()
            let isFinalComponent = index == components.count - 1
            guard fstat(childFD, &status) == 0,
                  isDirectory(status.st_mode),
                  !isFinalComponent || !makeFinalComponentPrivate || (
                      status.st_uid == geteuid() && fchmod(childFD, mode_t(0o700)) == 0
                  ) else {
                let childCloseResult = Darwin.close(childFD)
                let currentCloseResult = Darwin.close(currentFD)
                guard childCloseResult == 0, currentCloseResult == 0 else {
                    throw InboundFileTransferIOError.invalidDestination(
                        "directory validation cleanup failed"
                    )
                }
                throw InboundFileTransferIOError.invalidDestination("directory validation failed")
            }
            guard Darwin.close(currentFD) == 0 else {
                let childCloseResult = Darwin.close(childFD)
                guard childCloseResult == 0 else {
                    throw InboundFileTransferIOError.invalidDestination(
                        "directory descriptor cleanup failed"
                    )
                }
                throw InboundFileTransferIOError.invalidDestination("directory descriptor close failed")
            }
            currentFD = childFD
        }
        return currentFD
    }

    private static func verifyWritableDirectory(_ directoryFD: Int32) throws {
        let probeName = ".skybridge-write-probe-\(UUID().uuidString)"
        let probeFD = probeName.withCString {
            openat(
                directoryFD,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        let probeError = errno
        guard probeFD >= 0 else {
            if isUnavailableErrno(probeError) {
                throw InboundFileTransferIOError.destinationUnavailable
            }
            throw InboundFileTransferIOError.invalidDestination("directory is not writable")
        }
        let closeResult = Darwin.close(probeFD)
        let unlinkResult = probeName.withCString { unlinkat(directoryFD, $0, 0) }
        guard closeResult == 0, unlinkResult == 0 else {
            throw InboundFileTransferIOError.invalidDestination("writability probe cleanup failed")
        }
    }

    private static func removeIdentityBoundFileIfPresent(
        at fileURL: URL,
        deviceIdentifier: UInt64,
        inodeIdentifier: UInt64,
        requiresPrivateDirectory: Bool
    ) throws {
        let fileName = try validatedDirectChildFileName(
            fileURL,
            errorReason: "cleanup target is not a direct child"
        )
        try withDirectoryDescriptor(
            at: fileURL.deletingLastPathComponent(),
            createIfMissing: false,
            makeFinalComponentPrivate: requiresPrivateDirectory
        ) { directoryFD in
            var status = stat()
            let statusResult = fileName.withCString {
                fstatat(directoryFD, $0, &status, AT_SYMLINK_NOFOLLOW)
            }
            if statusResult != 0, errno == ENOENT {
                return
            }
            guard statusResult == 0,
                  isRegularFile(status.st_mode),
                  UInt64(status.st_dev) == deviceIdentifier,
                  UInt64(status.st_ino) == inodeIdentifier else {
                throw InboundFileTransferIOError.cleanupFailed(
                    "cleanup target identity changed"
                )
            }
            guard fileName.withCString({ unlinkat(directoryFD, $0, 0) }) == 0,
                  fsync(directoryFD) == 0 else {
                throw InboundFileTransferIOError.cleanupFailed("cleanup unlink failed")
            }
        }
    }

    private static func isDirectory(_ mode: mode_t) -> Bool {
        mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
    }

    private static func isRegularFile(_ mode: mode_t) -> Bool {
        mode & mode_t(S_IFMT) == mode_t(S_IFREG)
    }

    private static func isUnavailableErrno(_ code: Int32) -> Bool {
        switch code {
        case ENOENT, EACCES, EPERM, EROFS, ENOSPC, EDQUOT:
            return true
        default:
            return false
        }
    }

    private static func isDirectChild(_ candidate: URL, of directory: URL) -> Bool {
        candidate.standardizedFileURL.deletingLastPathComponent().path
            == directory.standardizedFileURL.path
    }
}
