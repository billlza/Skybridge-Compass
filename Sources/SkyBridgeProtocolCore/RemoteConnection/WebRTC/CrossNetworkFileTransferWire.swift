import Foundation
import Darwin

public enum CrossNetworkInboundFileCommitError: Error, Equatable, Sendable {
    case invalidTransferID
    case invalidTemporaryFile
    case invalidDestinationName
    case temporaryFileCreationFailed(Int32)
    case destinationCommitFailed(Int32)
    case destinationNameExhausted
    case directorySynchronizationFailed(Int32)
}

public struct CrossNetworkInboundTemporaryFile {
    public let url: URL
    public let handle: FileHandle

    fileprivate init(url: URL, handle: FileHandle) {
        self.url = url
        self.handle = handle
    }
}

/// Owns the filesystem boundary for inbound cross-network files.
///
/// Remote transfer identifiers are validated but never used as path components. Temporary files are
/// created with `O_EXCL`, and the final rename uses `RENAME_EXCL`, so a transfer cannot truncate a
/// pre-existing file or another concurrent transfer's destination.
public enum CrossNetworkInboundFileCommitter {
    private static let temporaryFilePrefix = ".skybridge-receive-"
    private static let temporaryFileSuffix = ".partial"
    private static let maximumTemporaryFileAttempts = 16
    private static let maximumDestinationAttempts = 1_000
    private static let maximumDestinationNameBytes = 220

    @discardableResult
    public static func requireCanonicalTransferID(_ transferID: String) throws -> String {
        guard transferID.utf8.count == 36,
              transferID.trimmingCharacters(in: .whitespacesAndNewlines) == transferID,
              let parsed = UUID(uuidString: transferID),
              parsed.uuidString.lowercased() == transferID else {
            throw CrossNetworkInboundFileCommitError.invalidTransferID
        }
        return transferID
    }

    public static func ensureDurableDirectory(_ directory: URL) throws {
        var isDirectory = ObjCBool(false)
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw CrossNetworkInboundFileCommitError.destinationCommitFailed(ENOTDIR)
            }
            return
        }

        let parent = directory.deletingLastPathComponent().standardizedFileURL
        var parentIsDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &parentIsDirectory),
              parentIsDirectory.boolValue else {
            throw CrossNetworkInboundFileCommitError.destinationCommitFailed(ENOENT)
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let parentDescriptor = try openDirectory(parent)
        defer { _ = Darwin.close(parentDescriptor) }
        guard Darwin.fsync(parentDescriptor) == 0 else {
            throw CrossNetworkInboundFileCommitError.directorySynchronizationFailed(errno)
        }
    }

    public static func createExclusiveTemporaryFile(
        in directory: URL
    ) throws -> CrossNetworkInboundTemporaryFile {
        let directoryDescriptor = try openDirectory(directory)
        defer { _ = Darwin.close(directoryDescriptor) }

        for _ in 0..<maximumTemporaryFileAttempts {
            let name = temporaryFilePrefix + UUID().uuidString.lowercased() + temporaryFileSuffix
            let descriptor = name.withCString { pointer in
                Darwin.openat(
                    directoryDescriptor,
                    pointer,
                    O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                    mode_t(S_IRUSR | S_IWUSR)
                )
            }
            if descriptor >= 0 {
                return CrossNetworkInboundTemporaryFile(
                    url: directory.appendingPathComponent(name, isDirectory: false),
                    handle: FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                )
            }
            if errno != EEXIST {
                throw CrossNetworkInboundFileCommitError.temporaryFileCreationFailed(errno)
            }
        }
        throw CrossNetworkInboundFileCommitError.temporaryFileCreationFailed(EEXIST)
    }

    public static func synchronizeAndClose(_ handle: FileHandle) throws {
        try handle.synchronize()
        try handle.close()
    }

    public static func commitWithoutReplacing(
        temporaryURL: URL,
        in directory: URL,
        preferredFileName: String
    ) throws -> URL {
        let directoryURL = directory.standardizedFileURL
        guard temporaryURL.deletingLastPathComponent().standardizedFileURL == directoryURL,
              isOwnedTemporaryFileName(temporaryURL.lastPathComponent) else {
            throw CrossNetworkInboundFileCommitError.invalidTemporaryFile
        }

        let safeName = try requireSafeDestinationName(preferredFileName)
        let directoryDescriptor = try openDirectory(directoryURL)
        defer { _ = Darwin.close(directoryDescriptor) }

        for index in 0..<maximumDestinationAttempts {
            let destinationName = destinationName(for: safeName, collisionIndex: index)
            let renameStatus = temporaryURL.lastPathComponent.withCString { sourcePointer in
                destinationName.withCString { destinationPointer in
                    Darwin.renameatx_np(
                        directoryDescriptor,
                        sourcePointer,
                        directoryDescriptor,
                        destinationPointer,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            if renameStatus == 0 {
                guard Darwin.fsync(directoryDescriptor) == 0 else {
                    throw CrossNetworkInboundFileCommitError.directorySynchronizationFailed(errno)
                }
                return directoryURL.appendingPathComponent(destinationName, isDirectory: false)
            }
            if errno != EEXIST {
                throw CrossNetworkInboundFileCommitError.destinationCommitFailed(errno)
            }
        }
        throw CrossNetworkInboundFileCommitError.destinationNameExhausted
    }

    private static func openDirectory(_ directory: URL) throws -> Int32 {
        let descriptor = directory.path.withCString { pointer in
            Darwin.open(pointer, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw CrossNetworkInboundFileCommitError.destinationCommitFailed(errno)
        }
        return descriptor
    }

    private static func isOwnedTemporaryFileName(_ name: String) -> Bool {
        guard name.hasPrefix(temporaryFilePrefix), name.hasSuffix(temporaryFileSuffix) else {
            return false
        }
        let identifierStart = name.index(name.startIndex, offsetBy: temporaryFilePrefix.count)
        let identifierEnd = name.index(name.endIndex, offsetBy: -temporaryFileSuffix.count)
        let identifier = String(name[identifierStart..<identifierEnd])
        return (try? requireCanonicalTransferID(identifier)) != nil
    }

    private static func requireSafeDestinationName(_ rawName: String) throws -> String {
        let name = (rawName as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              name != ".",
              name != "..",
              name.utf8.count <= maximumDestinationNameBytes,
              !name.contains("/"),
              !name.contains("\0") else {
            throw CrossNetworkInboundFileCommitError.invalidDestinationName
        }
        return name
    }

    private static func destinationName(for safeName: String, collisionIndex: Int) -> String {
        guard collisionIndex > 0 else { return safeName }
        let path = safeName as NSString
        let pathExtension = path.pathExtension
        let stem = path.deletingPathExtension
        if pathExtension.isEmpty {
            return "\(stem) (\(collisionIndex))"
        }
        return "\(stem) (\(collisionIndex)).\(pathExtension)"
    }
}

/// Wire messages for cross-network (WebRTC DataChannel) file transfer.
///
/// This is intentionally **JSON Codable** to keep iOS/macOS interop simple and debuggable.
/// Payload frames are still protected by:
/// - WebRTC DTLS transport security
/// - SkyBridge sessionKeys (AES-GCM) at the application layer
public enum CrossNetworkFileTransferOp: String, Codable, Hashable, Sendable {
    case metadata
    case metadataAck
    case chunk
    case chunkAck
    case complete
    case completeAck
    case cancel
    case error
}

public enum CrossNetworkFileTransferCompletionAcknowledgementError: Error, Equatable, Sendable {
    case emptyTransferID
    case invalidTransferID
    case negativeReceivedBytes
    case invalidFileSHA256Length(Int)
}

public enum CrossNetworkFileTransferCompletionEvidenceError: Error, Equatable, Sendable {
    case invalidVersion(Int)
    case invalidOperation(CrossNetworkFileTransferOp)
    case invalidTransferID
    case transferIDMismatch(expected: String, actual: String)
    case missingReceivedBytes
    case receivedBytesMismatch(expected: Int64, actual: Int64)
    case missingFileSHA256
    case invalidFileSHA256Length(Int)
    case fileSHA256Mismatch
}

/// Exact evidence required before an outbound transfer may become successful.
public struct CrossNetworkFileTransferCompletionAckExpectation: Equatable, Sendable {
    public static let protocolVersion = 1

    public let transferID: String
    public let receivedBytes: Int64
    public let fileSHA256: Data

    public init(transferID: String, receivedBytes: Int64, fileSHA256: Data) throws {
        do {
            try CrossNetworkInboundFileCommitter.requireCanonicalTransferID(transferID)
        } catch {
            throw CrossNetworkFileTransferCompletionEvidenceError.invalidTransferID
        }
        guard receivedBytes >= 0 else {
            throw CrossNetworkFileTransferCompletionAcknowledgementError.negativeReceivedBytes
        }
        guard fileSHA256.count == 32 else {
            throw CrossNetworkFileTransferCompletionEvidenceError.invalidFileSHA256Length(fileSHA256.count)
        }
        self.transferID = transferID
        self.receivedBytes = receivedBytes
        self.fileSHA256 = fileSHA256
    }

    public func validate(_ message: CrossNetworkFileTransferMessage) throws {
        guard message.version == Self.protocolVersion else {
            throw CrossNetworkFileTransferCompletionEvidenceError.invalidVersion(message.version)
        }
        guard message.op == .completeAck else {
            throw CrossNetworkFileTransferCompletionEvidenceError.invalidOperation(message.op)
        }
        do {
            try CrossNetworkInboundFileCommitter.requireCanonicalTransferID(message.transferId)
        } catch {
            throw CrossNetworkFileTransferCompletionEvidenceError.invalidTransferID
        }
        guard message.transferId == transferID else {
            throw CrossNetworkFileTransferCompletionEvidenceError.transferIDMismatch(
                expected: transferID,
                actual: message.transferId
            )
        }
        guard let actualReceivedBytes = message.receivedBytes else {
            throw CrossNetworkFileTransferCompletionEvidenceError.missingReceivedBytes
        }
        guard actualReceivedBytes == receivedBytes else {
            throw CrossNetworkFileTransferCompletionEvidenceError.receivedBytesMismatch(
                expected: receivedBytes,
                actual: actualReceivedBytes
            )
        }
        guard let actualFileSHA256 = message.fileSha256 else {
            throw CrossNetworkFileTransferCompletionEvidenceError.missingFileSHA256
        }
        guard actualFileSHA256.count == 32 else {
            throw CrossNetworkFileTransferCompletionEvidenceError.invalidFileSHA256Length(
                actualFileSHA256.count
            )
        }
        guard actualFileSHA256 == fileSHA256 else {
            throw CrossNetworkFileTransferCompletionEvidenceError.fileSHA256Mismatch
        }
    }
}

public struct CrossNetworkFileTransferCompletionRequestFingerprint: Hashable, Sendable {
    public let version: Int
    public let transferID: String
    public let receivedBytes: Int64
    public let fileSHA256: Data
    public let merkleRoot: Data?
    public let merkleRootSignature: Data?
    public let merkleRootSignatureAlgorithm: String?

    public init(message: CrossNetworkFileTransferMessage) throws {
        guard message.version == CrossNetworkFileTransferCompletionAckExpectation.protocolVersion else {
            throw CrossNetworkFileTransferCompletionEvidenceError.invalidVersion(message.version)
        }
        guard message.op == .complete else {
            throw CrossNetworkFileTransferCompletionEvidenceError.invalidOperation(message.op)
        }
        do {
            try CrossNetworkInboundFileCommitter.requireCanonicalTransferID(message.transferId)
        } catch {
            throw CrossNetworkFileTransferCompletionEvidenceError.invalidTransferID
        }
        guard let receivedBytes = message.receivedBytes else {
            throw CrossNetworkFileTransferCompletionEvidenceError.missingReceivedBytes
        }
        guard receivedBytes >= 0 else {
            throw CrossNetworkFileTransferCompletionAcknowledgementError.negativeReceivedBytes
        }
        guard let fileSHA256 = message.fileSha256 else {
            throw CrossNetworkFileTransferCompletionEvidenceError.missingFileSHA256
        }
        guard fileSHA256.count == 32 else {
            throw CrossNetworkFileTransferCompletionEvidenceError.invalidFileSHA256Length(fileSHA256.count)
        }
        self.version = message.version
        self.transferID = message.transferId
        self.receivedBytes = receivedBytes
        self.fileSHA256 = fileSHA256
        self.merkleRoot = message.merkleRoot
        self.merkleRootSignature = message.merkleRootSignature
        self.merkleRootSignatureAlgorithm = message.merkleRootSignatureAlg
    }
}

public enum CrossNetworkFileTransferSessionOwnerError: Error, Equatable, Sendable {
    case invalidSessionID
    case staleOwner
}

public struct CrossNetworkFileTransferSessionOwner: Hashable, Sendable {
    public let sessionID: String
    /// Connection generation. This is the session snapshot token and therefore changes on reconnect.
    public let sessionGeneration: UUID
    /// Application-key generation. This changes whenever new `SessionKeys` become authoritative.
    public let keyEpoch: UUID

    public var generation: UUID { sessionGeneration }

    public init(sessionID: String, generation: UUID, keyEpoch: UUID) throws {
        guard !sessionID.isEmpty,
              sessionID.trimmingCharacters(in: .whitespacesAndNewlines) == sessionID else {
            throw CrossNetworkFileTransferSessionOwnerError.invalidSessionID
        }
        self.sessionID = sessionID
        self.sessionGeneration = generation
        self.keyEpoch = keyEpoch
    }

    /// Convenience for isolated state-machine callers that have only one key epoch.
    public init(sessionID: String, generation: UUID) throws {
        try self.init(sessionID: sessionID, generation: generation, keyEpoch: generation)
    }
}

public enum CrossNetworkFileTransferCompletionAttemptFailure: Equatable, Sendable {
    case timeout
    case transientSend
    case terminal
}

/// Immutable owner ticket pinned for the full metadata/chunk/complete lifecycle.
public struct CrossNetworkFileTransferOutboundContext: Equatable, Sendable {
    public let owner: CrossNetworkFileTransferSessionOwner

    public init(owner: CrossNetworkFileTransferSessionOwner) {
        self.owner = owner
    }

    public func validate(currentOwner: CrossNetworkFileTransferSessionOwner?) throws {
        guard currentOwner == owner else { throw CrossNetworkFileTransferSessionOwnerError.staleOwner }
    }
}

/// Finite retry policy for an exact, immutable completion request.
public struct CrossNetworkFileTransferCompletionRetryPolicy: Equatable, Sendable {
    public let maximumAttempts: Int

    public init(maximumAttempts: Int = 2) {
        precondition(maximumAttempts > 0)
        self.maximumAttempts = maximumAttempts
    }

    public func permitsRetry(
        after failure: CrossNetworkFileTransferCompletionAttemptFailure,
        completedAttempts: Int
    ) -> Bool {
        guard completedAttempts > 0, completedAttempts < maximumAttempts else { return false }
        switch failure {
        case .timeout, .transientSend:
            return true
        case .terminal:
            return false
        }
    }
}

/// Identity for one live inbound transfer allocation. It prevents an old suspended handler from
/// mutating a replacement context that happens to use the same transfer identifier.
public struct CrossNetworkFileTransferInboundContextIdentity: Hashable, Sendable {
    public let owner: CrossNetworkFileTransferSessionOwner
    public let transferID: String
    public let token: UUID

    public init(
        owner: CrossNetworkFileTransferSessionOwner,
        transferID: String,
        token: UUID = UUID()
    ) throws {
        try CrossNetworkInboundFileCommitter.requireCanonicalTransferID(transferID)
        self.owner = owner
        self.transferID = transferID
        self.token = token
    }

    public func isCurrent(
        owner expectedOwner: CrossNetworkFileTransferSessionOwner,
        current: CrossNetworkFileTransferInboundContextIdentity?
    ) -> Bool {
        owner == expectedOwner && current == self
    }
}

public struct CrossNetworkFileTransferWaiterKey: Hashable, Sendable {
    public let owner: CrossNetworkFileTransferSessionOwner
    public let transferID: String
    public let operation: CrossNetworkFileTransferOp
    public let chunkIndex: Int?

    public init(
        owner: CrossNetworkFileTransferSessionOwner,
        transferID: String,
        operation: CrossNetworkFileTransferOp,
        chunkIndex: Int?
    ) throws {
        try CrossNetworkInboundFileCommitter.requireCanonicalTransferID(transferID)
        self.owner = owner
        self.transferID = transferID
        self.operation = operation
        self.chunkIndex = chunkIndex
    }
}

public struct CrossNetworkFileTransferWaiterToken: Hashable, Sendable {
    public let id: UUID
    public let key: CrossNetworkFileTransferWaiterKey
}

public enum CrossNetworkFileTransferWaiterRegistryError: Error, Equatable, Sendable {
    case duplicateWaiter(CrossNetworkFileTransferWaiterKey)
}

/// A continuation-free registry that makes waiter ownership and removal testable.
public struct CrossNetworkFileTransferWaiterRegistry: Sendable {
    private var tokenIDByKey: [CrossNetworkFileTransferWaiterKey: UUID] = [:]

    public init() {}

    public var count: Int { tokenIDByKey.count }

    public mutating func arm(
        owner: CrossNetworkFileTransferSessionOwner,
        transferID: String,
        operation: CrossNetworkFileTransferOp,
        chunkIndex: Int?
    ) throws -> CrossNetworkFileTransferWaiterToken {
        let key = try CrossNetworkFileTransferWaiterKey(
            owner: owner,
            transferID: transferID,
            operation: operation,
            chunkIndex: chunkIndex
        )
        guard tokenIDByKey[key] == nil else {
            throw CrossNetworkFileTransferWaiterRegistryError.duplicateWaiter(key)
        }
        let token = CrossNetworkFileTransferWaiterToken(id: UUID(), key: key)
        tokenIDByKey[key] = token.id
        return token
    }

    public mutating func consume(
        owner: CrossNetworkFileTransferSessionOwner,
        message: CrossNetworkFileTransferMessage
    ) -> CrossNetworkFileTransferWaiterToken? {
        guard let key = try? CrossNetworkFileTransferWaiterKey(
            owner: owner,
            transferID: message.transferId,
            operation: message.op,
            chunkIndex: message.chunkIndex
        ), let tokenID = tokenIDByKey.removeValue(forKey: key) else {
            return nil
        }
        return CrossNetworkFileTransferWaiterToken(id: tokenID, key: key)
    }

    @discardableResult
    public mutating func remove(_ token: CrossNetworkFileTransferWaiterToken) -> Bool {
        guard tokenIDByKey[token.key] == token.id else { return false }
        tokenIDByKey.removeValue(forKey: token.key)
        return true
    }

    public mutating func remove(
        owner: CrossNetworkFileTransferSessionOwner,
        transferID: String
    ) -> [CrossNetworkFileTransferWaiterToken] {
        let matchingKeys = tokenIDByKey.keys.filter {
            $0.owner == owner && $0.transferID == transferID
        }
        return matchingKeys.compactMap { key in
            guard let tokenID = tokenIDByKey.removeValue(forKey: key) else { return nil }
            return CrossNetworkFileTransferWaiterToken(id: tokenID, key: key)
        }
    }

    public mutating func remove(owner: CrossNetworkFileTransferSessionOwner) -> [CrossNetworkFileTransferWaiterToken] {
        let matchingKeys = tokenIDByKey.keys.filter { $0.owner == owner }
        return matchingKeys.compactMap { key in
            guard let tokenID = tokenIDByKey.removeValue(forKey: key) else { return nil }
            return CrossNetworkFileTransferWaiterToken(id: tokenID, key: key)
        }
    }
}

public enum CrossNetworkFileTransferReplayReservation: Equatable, Sendable {
    case reserved
    case alreadyActive
    case alreadyCompleted
    case capacityExceeded
}

public enum CrossNetworkFileTransferCompletionReplayLookup: Equatable, Sendable {
    case active
    case replay(CrossNetworkFileTransferMessage)
    case mismatch
    case tombstone
    case missing
}

public enum CrossNetworkFileTransferCompletionReplayError: Error, Equatable, Sendable {
    case missingActiveReservation
    case acknowledgementMismatch(CrossNetworkFileTransferCompletionEvidenceError)
}

public struct CrossNetworkFileTransferPreparedCompletion: Sendable {
    fileprivate let owner: CrossNetworkFileTransferSessionOwner
    fileprivate let fingerprint: CrossNetworkFileTransferCompletionRequestFingerprint
    fileprivate let acknowledgement: CrossNetworkFileTransferMessage
}

/// Bounded, process-local replay witness for durable completion acknowledgements.
///
/// This is intentionally Level 1 reliability state, not crash-durable security state. Active and
/// completed entries share one capacity budget. Expired replay payloads become fixed-size
/// tombstones so a transfer identifier can never be reused within the same session owner.
public struct CrossNetworkFileTransferCompletionReplayCache: Sendable {
    private struct Key: Hashable, Sendable {
        let owner: CrossNetworkFileTransferSessionOwner
        let transferID: String
    }

    private enum Entry: Sendable {
        case active
        case completed(
            fingerprint: CrossNetworkFileTransferCompletionRequestFingerprint,
            acknowledgement: CrossNetworkFileTransferMessage,
            completedAt: Date
        )
        case completedTombstone
    }

    private let capacity: Int
    private let timeToLive: TimeInterval
    private var entries: [Key: Entry] = [:]

    public init(capacity: Int, timeToLive: TimeInterval) {
        precondition(capacity > 0)
        precondition(timeToLive > 0)
        self.capacity = capacity
        self.timeToLive = timeToLive
    }

    public var count: Int { entries.count }

    public mutating func reserve(
        owner: CrossNetworkFileTransferSessionOwner,
        transferID: String,
        now: Date = Date()
    ) throws -> CrossNetworkFileTransferReplayReservation {
        try CrossNetworkInboundFileCommitter.requireCanonicalTransferID(transferID)
        pruneExpired(now: now)
        let key = Key(owner: owner, transferID: transferID)
        if let entry = entries[key] {
            switch entry {
            case .active:
                return .alreadyActive
            case .completed, .completedTombstone:
                return .alreadyCompleted
            }
        }
        guard entries.count < capacity else { return .capacityExceeded }
        entries[key] = .active
        return .reserved
    }

    public mutating func recordCompletion(
        owner: CrossNetworkFileTransferSessionOwner,
        fingerprint: CrossNetworkFileTransferCompletionRequestFingerprint,
        acknowledgement: CrossNetworkFileTransferMessage,
        now: Date = Date()
    ) throws {
        let prepared = try prepareCompletion(
            owner: owner,
            fingerprint: fingerprint,
            acknowledgement: acknowledgement
        )
        guard commitPreparedCompletion(prepared, now: now) else {
            throw CrossNetworkFileTransferCompletionReplayError.missingActiveReservation
        }
    }

    public func prepareCompletion(
        owner: CrossNetworkFileTransferSessionOwner,
        fingerprint: CrossNetworkFileTransferCompletionRequestFingerprint,
        acknowledgement: CrossNetworkFileTransferMessage
    ) throws -> CrossNetworkFileTransferPreparedCompletion {
        let key = Key(owner: owner, transferID: fingerprint.transferID)
        guard case .active? = entries[key] else {
            throw CrossNetworkFileTransferCompletionReplayError.missingActiveReservation
        }
        let expectation = try CrossNetworkFileTransferCompletionAckExpectation(
            transferID: fingerprint.transferID,
            receivedBytes: fingerprint.receivedBytes,
            fileSHA256: fingerprint.fileSHA256
        )
        do {
            try expectation.validate(acknowledgement)
        } catch let evidenceError as CrossNetworkFileTransferCompletionEvidenceError {
            throw CrossNetworkFileTransferCompletionReplayError.acknowledgementMismatch(evidenceError)
        }
        return CrossNetworkFileTransferPreparedCompletion(
            owner: owner,
            fingerprint: fingerprint,
            acknowledgement: acknowledgement
        )
    }

    @discardableResult
    public mutating func commitPreparedCompletion(
        _ prepared: CrossNetworkFileTransferPreparedCompletion,
        now: Date = Date()
    ) -> Bool {
        let key = Key(
            owner: prepared.owner,
            transferID: prepared.fingerprint.transferID
        )
        guard case .active? = entries[key] else { return false }
        entries[key] = .completed(
            fingerprint: prepared.fingerprint,
            acknowledgement: prepared.acknowledgement,
            completedAt: now
        )
        return true
    }

    public mutating func lookup(
        owner: CrossNetworkFileTransferSessionOwner,
        fingerprint: CrossNetworkFileTransferCompletionRequestFingerprint,
        now: Date = Date()
    ) -> CrossNetworkFileTransferCompletionReplayLookup {
        pruneExpired(now: now)
        let key = Key(owner: owner, transferID: fingerprint.transferID)
        guard let entry = entries[key] else { return .missing }
        switch entry {
        case .active:
            return .active
        case .completed(let storedFingerprint, let acknowledgement, _):
            return storedFingerprint == fingerprint ? .replay(acknowledgement) : .mismatch
        case .completedTombstone:
            return .tombstone
        }
    }

    public mutating func releaseActive(
        owner: CrossNetworkFileTransferSessionOwner,
        transferID: String
    ) {
        let key = Key(owner: owner, transferID: transferID)
        guard case .active? = entries[key] else { return }
        entries.removeValue(forKey: key)
    }

    /// Permanently retires an allocated identifier after a terminal receive failure. Unlike
    /// `releaseActive`, this preserves fail-closed transfer-ID uniqueness for the owner.
    public mutating func tombstoneActive(
        owner: CrossNetworkFileTransferSessionOwner,
        transferID: String
    ) {
        let key = Key(owner: owner, transferID: transferID)
        guard case .active? = entries[key] else { return }
        entries[key] = .completedTombstone
    }

    public mutating func remove(owner: CrossNetworkFileTransferSessionOwner) {
        entries = entries.filter { $0.key.owner != owner }
    }

    private mutating func pruneExpired(now: Date) {
        entries = entries.mapValues { entry in
            switch entry {
            case .active:
                return .active
            case .completed(_, _, let completedAt):
                return now.timeIntervalSince(completedAt) < timeToLive
                    ? entry
                    : .completedTombstone
            case .completedTombstone:
                return .completedTombstone
            }
        }
    }
}

public struct CrossNetworkFileTransferMessage: Codable, Equatable, Sendable {
    public let version: Int
    public let op: CrossNetworkFileTransferOp
    public let transferId: String
    
    // Peer info (optional, used for UI/logging)
    public let senderDeviceId: String?
    public let senderDeviceName: String?
    
    // Metadata (for .metadata / .metadataAck)
    public let fileName: String?
    public let fileSize: Int64?
    public let chunkSize: Int?
    public let totalChunks: Int?
    public let mimeType: String?
    
    // Chunk (for .chunk / .chunkAck)
    public let chunkIndex: Int?
    public let chunkData: Data?
    /// Optional: integrity hash for chunkData (SHA-256). Backward compatible.
    public let chunkSha256: Data?
    /// Optional: future encryption nonce (for encrypted chunks). Backward compatible.
    public let nonce: Data?
    /// Uncompressed/raw size in bytes (used for progress/offset; optional for compatibility).
    public let rawSize: Int?
    public let receivedBytes: Int64?
    
    /// Optional: future encryption descriptor (e.g. "aes-gcm-256-v1"). Backward compatible.
    public let encryption: String?
    /// Optional: future full-file digest (SHA-256). Backward compatible.
    public let fileSha256: Data?

    /// Optional: Merkle root over per-chunk SHA-256 leaves. Backward compatible.
    public let merkleRoot: Data?
    /// Optional: Signature/MAC over merkleRoot. Backward compatible.
    public let merkleRootSignature: Data?
    /// Optional: Algorithm identifier for merkleRootSignature (e.g. "hmac-sha256-session-v1"). Backward compatible.
    public let merkleRootSignatureAlg: String?

    /// Optional: missing chunk indices requested by receiver. Backward compatible.
    public let missingChunks: [Int]?

    /// Optional: batch transfer grouping. Backward compatible.
    public let batchId: String?
    public let batchIndex: Int?
    public let batchTotal: Int?
    public let relativePath: String?
    
    // Error/cancel (for .error / .cancel)
    public let message: String?
    
    public init(
        version: Int = 1,
        op: CrossNetworkFileTransferOp,
        transferId: String,
        senderDeviceId: String? = nil,
        senderDeviceName: String? = nil,
        fileName: String? = nil,
        fileSize: Int64? = nil,
        chunkSize: Int? = nil,
        totalChunks: Int? = nil,
        mimeType: String? = nil,
        chunkIndex: Int? = nil,
        chunkData: Data? = nil,
        chunkSha256: Data? = nil,
        nonce: Data? = nil,
        rawSize: Int? = nil,
        receivedBytes: Int64? = nil,
        encryption: String? = nil,
        fileSha256: Data? = nil,
        merkleRoot: Data? = nil,
        merkleRootSignature: Data? = nil,
        merkleRootSignatureAlg: String? = nil,
        missingChunks: [Int]? = nil,
        batchId: String? = nil,
        batchIndex: Int? = nil,
        batchTotal: Int? = nil,
        relativePath: String? = nil,
        message: String? = nil
    ) {
        self.version = version
        self.op = op
        self.transferId = transferId
        self.senderDeviceId = senderDeviceId
        self.senderDeviceName = senderDeviceName
        self.fileName = fileName
        self.fileSize = fileSize
        self.chunkSize = chunkSize
        self.totalChunks = totalChunks
        self.mimeType = mimeType
        self.chunkIndex = chunkIndex
        self.chunkData = chunkData
        self.chunkSha256 = chunkSha256
        self.nonce = nonce
        self.rawSize = rawSize
        self.receivedBytes = receivedBytes
        self.encryption = encryption
        self.fileSha256 = fileSha256
        self.merkleRoot = merkleRoot
        self.merkleRootSignature = merkleRootSignature
        self.merkleRootSignatureAlg = merkleRootSignatureAlg
        self.missingChunks = missingChunks
        self.batchId = batchId
        self.batchIndex = batchIndex
        self.batchTotal = batchTotal
        self.relativePath = relativePath
        self.message = message
    }
}

public extension CrossNetworkFileTransferMessage {
    static func completeAcknowledgement(
        transferId: String,
        receivedBytes: Int64,
        fileSha256: Data
    ) throws -> Self {
        guard !transferId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CrossNetworkFileTransferCompletionAcknowledgementError.emptyTransferID
        }
        do {
            try CrossNetworkInboundFileCommitter.requireCanonicalTransferID(transferId)
        } catch {
            throw CrossNetworkFileTransferCompletionAcknowledgementError.invalidTransferID
        }
        guard receivedBytes >= 0 else {
            throw CrossNetworkFileTransferCompletionAcknowledgementError.negativeReceivedBytes
        }
        guard fileSha256.count == 32 else {
            throw CrossNetworkFileTransferCompletionAcknowledgementError.invalidFileSHA256Length(
                fileSha256.count
            )
        }
        return Self(
            op: .completeAck,
            transferId: transferId,
            receivedBytes: receivedBytes,
            fileSha256: fileSha256
        )
    }
}
