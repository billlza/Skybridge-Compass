import Foundation
import CryptoKit
import Darwin

public struct PreparedOutboundFileMetadata: Equatable, Sendable {
    public let fileSize: Int64
    public let contentSHA256: Data

    fileprivate init(fileSize: Int64, contentSHA256: Data) {
        self.fileSize = fileSize
        self.contentSHA256 = contentSHA256
    }
}

public enum PreparedOutboundSourcePolicy: Sendable {
    /// Preserve the regular-file contract of the shared classic/iOS reader.
    case regularFile
    /// Preserve the stricter owner, single-link and mtime contract of the Mac WebRTC reader.
    case ownedSingleLinkStableMetadata
}

public enum PreparedOutboundFileReadError: Error, Equatable, LocalizedError, Sendable {
    case invalidBounds
    case invalidExpectedDigest
    case openFailed(Int32)
    case sourceChanged
    case readFailed(Int32)
    case unexpectedEndOfFile
    case contentChanged
    case closed
    case closeFailed(String)
    case cleanupFailed(primary: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidBounds: "Prepared source exceeds its file or read bounds"
        case .invalidExpectedDigest: "Prepared source requires an exact SHA-256 digest"
        case .openFailed(let code): "Prepared source could not be opened (errno=\(code))"
        case .sourceChanged: "Prepared source file identity changed"
        case .readFailed(let code): "Prepared source read failed (errno=\(code))"
        case .unexpectedEndOfFile: "Prepared source ended before its declared length"
        case .contentChanged: "File content changed after selection; no changed bytes were returned"
        case .closed: "Prepared source is closed"
        case .closeFailed(let reason): "Prepared source close failed: \(reason)"
        case .cleanupFailed(let primary, let code): "Prepared source failed (\(primary)); descriptor cleanup also failed (errno=\(code))"
        }
    }
}

/// One held descriptor and bounded private block commitments. Preparation is not authorization.
/// Reads return only bytes from verified copies of the earlier selected content. They do not
/// attest a filesystem-wide snapshot, prove transmission, or imply a receiver accepted the file.
public actor PreparedOutboundFileReadSession {
    public typealias PReadOperation = @Sendable (Int32, UnsafeMutableRawPointer, Int, off_t) -> Int
    public nonisolated let metadata: PreparedOutboundFileMetadata
    public static let maximumFileSize: Int64 = 16 * 1_024 * 1_024 * 1_024
    public static let maximumReadSize = 4 * 1_024 * 1_024
    private static let blockSize = 256 * 1_024

    private struct Identity: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let owner: uid_t
        let links: nlink_t
        let modificationSeconds: Int
        let modificationNanoseconds: Int
    }

    private var handle: FileHandle?
    private let identity: Identity
    private let policy: PreparedOutboundSourcePolicy
    private let blockDigests: [SHA256.Digest]
    private var cachedBlock: (index: Int, bytes: Data)?

    private init(
        descriptor: Int32,
        identity: Identity,
        policy: PreparedOutboundSourcePolicy,
        blockDigests: [SHA256.Digest],
        digest: Data
    ) {
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        self.identity = identity
        self.policy = policy
        self.blockDigests = blockDigests
        metadata = PreparedOutboundFileMetadata(fileSize: Int64(identity.size), contentSHA256: digest)
    }

    /// A nil expected digest explicitly selects the content read during preparation. When a
    /// prior selection already has a digest, supply it: mismatch fails before returning a reader.
    /// The callback is cancellation/lifetime bookkeeping, not an authorization oracle.
    public static func prepare(
        url: URL,
        maximumSize: Int64,
        sourcePolicy: PreparedOutboundSourcePolicy,
        expectedSHA256: Data? = nil,
        validateLifetime: @escaping @Sendable () async throws -> Void = { try Task.checkCancellation() }
    ) async throws -> PreparedOutboundFileReadSession {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.utf8.contains(0),
              maximumSize >= 0, maximumSize <= maximumFileSize else {
            throw PreparedOutboundFileReadError.invalidBounds
        }
        if let expectedSHA256, expectedSHA256.count != 32 {
            throw PreparedOutboundFileReadError.invalidExpectedDigest
        }
        let preparation = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            try await validateLifetime()
            let descriptor = url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard descriptor >= 0 else { throw PreparedOutboundFileReadError.openFailed(errno) }
            do {
                let identity = try inspect(descriptor, policy: sourcePolicy)
                guard identity.size <= maximumSize else { throw PreparedOutboundFileReadError.invalidBounds }
                let size = Int64(identity.size)
                let count = Int((size + Int64(blockSize) - 1) / Int64(blockSize))
                var blocks: [SHA256.Digest] = []
                blocks.reserveCapacity(count) // At most 65,536 fixed 32-byte digests (2 MiB).
                var whole = SHA256()
                var offset: Int64 = 0
                while offset < size {
                    try Task.checkCancellation()
                    try await validateLifetime()
                    let length = Int(min(Int64(blockSize), size - offset))
                    let bytes = try readExactly(descriptor, offset: offset, length: length)
                    blocks.append(SHA256.hash(data: bytes))
                    whole.update(data: bytes)
                    offset += Int64(length)
                }
                try validate(descriptor, expected: identity, policy: sourcePolicy)
                let digest = Data(whole.finalize())
                if let expectedSHA256, digest != expectedSHA256 {
                    throw PreparedOutboundFileReadError.contentChanged
                }
                try Task.checkCancellation()
                try await validateLifetime()
                return PreparedOutboundFileReadSession(descriptor: descriptor, identity: identity,
                    policy: sourcePolicy, blockDigests: blocks, digest: digest)
            } catch {
                let primary = error
                if Darwin.close(descriptor) != 0 {
                    throw PreparedOutboundFileReadError.cleanupFailed(primary: String(describing: primary), code: errno)
                }
                throw primary
            }
        }
        return try await withTaskCancellationHandler {
            let session = try await preparation.value
            if Task.isCancelled {
                try await session.close()
                throw CancellationError()
            }
            return session
        } onCancel: {
            preparation.cancel()
        }
    }

    /// Supports bounded ranges and resume. Every returned byte comes from an earlier committed
    /// block copy; an error in any covered block returns none of this read's accumulated bytes.
    public func read(offset: UInt64, length: Int) throws -> Data {
        try Task.checkCancellation()
        guard let handle else { throw PreparedOutboundFileReadError.closed }
        guard length > 0, length <= Self.maximumReadSize, offset <= UInt64(metadata.fileSize),
              UInt64(length) <= UInt64(metadata.fileSize) - offset else {
            throw PreparedOutboundFileReadError.invalidBounds
        }
        try Self.validate(handle.fileDescriptor, expected: identity, policy: policy)
        var result = Data()
        result.reserveCapacity(length)
        var position = Int64(offset)
        var remaining = length
        while remaining > 0 {
            try Task.checkCancellation()
            let index = Int(position / Int64(Self.blockSize))
            let start = Int64(index) * Int64(Self.blockSize)
            let bytes: Data
            if let cachedBlock, cachedBlock.index == index {
                bytes = cachedBlock.bytes
            } else {
                let count = Int(min(Int64(Self.blockSize), metadata.fileSize - start))
                let read = try Self.readExactly(handle.fileDescriptor, offset: start, length: count)
                guard SHA256.hash(data: read) == blockDigests[index] else {
                    throw PreparedOutboundFileReadError.contentChanged
                }
                try Self.validate(handle.fileDescriptor, expected: identity, policy: policy)
                cachedBlock = (index, read)
                bytes = read
            }
            let localOffset = Int(position - start)
            let count = min(remaining, bytes.count - localOffset)
            result.append(bytes.subdata(in: localOffset..<(localOffset + count)))
            position += Int64(count)
            remaining -= count
        }
        try Self.validate(handle.fileDescriptor, expected: identity, policy: policy)
        try Task.checkCancellation()
        return result
    }

    public func close() throws {
        guard let handle else { return }
        do { try handle.close() }
        catch { throw PreparedOutboundFileReadError.closeFailed(String(describing: error)) }
        self.handle = nil
        cachedBlock = nil
    }

    public func validateSourceIdentity() throws {
        guard let handle else { throw PreparedOutboundFileReadError.closed }
        try Self.validate(handle.fileDescriptor, expected: identity, policy: policy)
    }

    private static func inspect(_ descriptor: Int32, policy: PreparedOutboundSourcePolicy) throws -> Identity {
        var value = stat()
        guard fstat(descriptor, &value) == 0, value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              value.st_size >= 0 else { throw PreparedOutboundFileReadError.sourceChanged }
        if policy == .ownedSingleLinkStableMetadata,
           (value.st_uid != geteuid() || value.st_nlink != 1 || value.st_ino == 0) {
            throw PreparedOutboundFileReadError.sourceChanged
        }
        return Identity(device: value.st_dev, inode: value.st_ino, size: value.st_size,
            owner: value.st_uid, links: value.st_nlink,
            modificationSeconds: value.st_mtimespec.tv_sec, modificationNanoseconds: value.st_mtimespec.tv_nsec)
    }

    private static func validate(_ descriptor: Int32, expected: Identity, policy: PreparedOutboundSourcePolicy) throws {
        let current = try inspect(descriptor, policy: policy)
        guard current.device == expected.device, current.inode == expected.inode, current.size == expected.size else {
            throw PreparedOutboundFileReadError.sourceChanged
        }
        if policy == .ownedSingleLinkStableMetadata, current != expected {
            throw PreparedOutboundFileReadError.sourceChanged
        }
    }

    /// Bounded POSIX read utility; this function alone does not verify a prepared commitment.
    public nonisolated static func readExactly(
        _ descriptor: Int32,
        offset: Int64,
        length: Int,
        readOperation: PReadOperation = { descriptor, buffer, count, offset in
            Darwin.pread(descriptor, buffer, count, offset)
        }
    ) throws -> Data {
        guard descriptor >= 0, offset >= 0, length > 0, length <= maximumReadSize,
              offset <= Int64.max - Int64(length) else {
            throw PreparedOutboundFileReadError.invalidBounds
        }
        var result = Data(count: length)
        try result.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { throw PreparedOutboundFileReadError.invalidBounds }
            var used = 0
            while used < length {
                try Task.checkCancellation()
                let count = readOperation(descriptor, base.advanced(by: used), length - used, off_t(offset) + off_t(used))
                if count > 0 {
                    guard count <= length - used else { throw PreparedOutboundFileReadError.readFailed(EINVAL) }
                    used += count
                }
                else if count == 0 { throw PreparedOutboundFileReadError.unexpectedEndOfFile }
                else if errno != EINTR { throw PreparedOutboundFileReadError.readFailed(errno) }
            }
        }
        return result
    }
}
