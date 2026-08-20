import Foundation
import Network
import OSLog
import Combine
import CryptoKit
import SkyBridgeProtocolCore
import Darwin
#if canImport(UserNotifications)
import UserNotifications
#endif

struct ClassicTransferResumeRecord: Codable, Equatable, Sendable {
    /// Immutable identity used for compare-and-delete. Records created before this
    /// field existed decode with `nil` and are still protected by full-record
    /// equality during cleanup.
    let recordNonce: UUID?
    let transferID: String
    let fileName: String
    let fileSize: Int64
    let transferredBytes: Int64
    let resumeOffset: Int64
    let deviceID: String
    let deviceIPAddress: String?
    let devicePort: Int
    let deviceName: String?
    let direction: String
    let localPath: String
    let fileHash: String
    let compression: String?
    let declaredChunkSize: Int
    let timestamp: Date

    init(
        recordNonce: UUID? = UUID(),
        transferID: String,
        fileName: String,
        fileSize: Int64,
        transferredBytes: Int64,
        resumeOffset: Int64,
        deviceID: String,
        deviceIPAddress: String?,
        devicePort: Int,
        deviceName: String?,
        direction: String,
        localPath: String,
        fileHash: String,
        compression: String?,
        declaredChunkSize: Int,
        timestamp: Date
    ) {
        self.recordNonce = recordNonce
        self.transferID = transferID
        self.fileName = fileName
        self.fileSize = fileSize
        self.transferredBytes = transferredBytes
        self.resumeOffset = resumeOffset
        self.deviceID = deviceID
        self.deviceIPAddress = deviceIPAddress
        self.devicePort = devicePort
        self.deviceName = deviceName
        self.direction = direction
        self.localPath = localPath
        self.fileHash = fileHash
        self.compression = compression
        self.declaredChunkSize = declaredChunkSize
        self.timestamp = timestamp
    }
}

actor ClassicTransferResumeStore {
    struct RetentionPolicy: Sendable {
        static let production = RetentionPolicy(
            recordTTL: 24 * 60 * 60,
            maximumRecordCount: ClassicTransferInboundPolicy.maximumPendingTransfers,
            maximumTotalInboundPartialBytes: ClassicTransferInboundPolicy.maximumFileSizeBytes
        )

        let recordTTL: TimeInterval
        let maximumRecordCount: Int
        let maximumTotalInboundPartialBytes: Int64

        init(
            recordTTL: TimeInterval,
            maximumRecordCount: Int,
            maximumTotalInboundPartialBytes: Int64
        ) {
            precondition(recordTTL.isFinite && recordTTL > 0)
            precondition(maximumRecordCount > 0)
            precondition(maximumTotalInboundPartialBytes > 0)
            self.recordTTL = recordTTL
            self.maximumRecordCount = maximumRecordCount
            self.maximumTotalInboundPartialBytes = maximumTotalInboundPartialBytes
        }
    }

    struct PruneReport: Equatable, Sendable {
        var removedRecordCount = 0
        var removedInboundPartialCount = 0
        var removedInboundPartialBytes: Int64 = 0
    }

    private struct StoredEntry {
        let recordFileName: String
        let record: ClassicTransferResumeRecord
        let partialFileName: String?
        let partialSize: Int64
    }

    private struct IsolatedPartialFile {
        let fileName: String
        let size: Int64
        let modifiedAt: Date
    }

    private enum PartialInspection {
        case notApplicable
        case valid(fileName: String, size: Int64)
        case invalidTrustedFile(fileName: String, size: Int64)
        case invalidUntrustedOrMissing
    }

    private enum StoredEntryInspection {
        case valid(StoredEntry)
        case invalid(partial: PartialInspection)
    }

    static let shared = ClassicTransferResumeStore()
    private static let maximumRecordSize = 64 * 1_024
    private static let maximumManagedDirectoryEntryCount = 256
    private static let privateDirectoryMode = mode_t(0o700)
    private static let privateFileMode = mode_t(0o600)
    private static let lockFileName = ".resume-store.lock"
    /// POSIX record locks are process-associated, so two descriptors opened by
    /// different store actors in this process do not serialize each other. Keep
    /// this process lock in addition to the on-disk lock, which still coordinates
    /// with other processes.
    private static let processLock = NSLock()
    private static let maximumFutureClockSkew: TimeInterval = 5 * 60
    private let baseDirectoryOverride: URL?
    private let partialDirectoryOverride: URL?
    private let retentionPolicy: RetentionPolicy
    private let now: @Sendable () -> Date

    init(
        baseDirectory: URL? = nil,
        partialDirectory: URL? = nil,
        retentionPolicy: RetentionPolicy = .production,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.baseDirectoryOverride = baseDirectory
        self.partialDirectoryOverride = partialDirectory
        self.retentionPolicy = retentionPolicy
        self.now = now
    }

    func save(_ record: ClassicTransferResumeRecord) async throws -> URL {
        try Task.checkCancellation()
        do {
            guard record.recordNonce != nil else {
                throw FileTransferError.resumeStatePersistenceFailed
            }
            let data = try await ClassicTransferJSONWorker.shared.encode(
                record,
                maximumOutputSize: Self.maximumRecordSize
            )
            try Task.checkCancellation()
            let operationDate = now()
            let fileName = resumeFileName(for: record.transferID)
            return try withResumeDirectory { directoryFD, directoryURL in
                let partialReservation = try partialReservationForSave(
                    record,
                    operationDate: operationDate
                )
                _ = try pruneInternal(
                    operationDate: operationDate,
                    excludingRecordFileName: fileName,
                    reservedRecordCount: 1,
                    reservedInboundPartialFileName: partialReservation.fileName,
                    reservedInboundPartialBytes: partialReservation.byteCount,
                    lockedDirectoryFD: directoryFD
                )
                try validateExistingRecordIfPresent(named: fileName, directoryFD: directoryFD)
                try atomicallyWrite(data, named: fileName, directoryFD: directoryFD)
                return directoryURL.appendingPathComponent(fileName, isDirectory: false)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw FileTransferError.resumeStatePersistenceFailed
        }
    }

    func load(transferID: String) async throws -> ClassicTransferResumeRecord? {
        try Task.checkCancellation()
        do {
            let operationDate = now()
            return try withResumeDirectory { directoryFD, _ in
                _ = try pruneInternal(
                    operationDate: operationDate,
                    lockedDirectoryFD: directoryFD
                )
                guard let data = try readRecordData(
                    named: resumeFileName(for: transferID),
                    directoryFD: directoryFD
                ) else {
                    return nil
                }
                let record = try JSONDecoder().decode(
                    ClassicTransferResumeRecord.self,
                    from: data
                )
                guard record.transferID == transferID else {
                    throw FileTransferError.resumeStatePersistenceFailed
                }
                _ = try validatedStoredEntry(
                    record,
                    recordFileName: resumeFileName(for: transferID),
                    operationDate: operationDate
                )
                return record
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw FileTransferError.resumeStatePersistenceFailed
        }
    }

    func prune() throws -> PruneReport {
        try Task.checkCancellation()
        do {
            return try pruneInternal(operationDate: now())
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw FileTransferError.resumeStatePersistenceFailed
        }
    }

    func remove(matching expectedRecord: ClassicTransferResumeRecord) throws {
        // Terminal cleanup is intentionally non-cancellable. A cancelled transfer
        // must not leave an authenticated resume record behind.
        do {
            try withResumeDirectory { directoryFD, _ in
                let fileName = resumeFileName(for: expectedRecord.transferID)
                guard let data = try readRecordData(
                    named: fileName,
                    directoryFD: directoryFD
                ) else {
                    return
                }
                let currentRecord = try JSONDecoder().decode(
                    ClassicTransferResumeRecord.self,
                    from: data
                )
                guard currentRecord == expectedRecord else {
                    throw FileTransferError.resumeStatePersistenceFailed
                }
                _ = try unlinkOwnedRecordIfPresent(
                    named: fileName,
                    directoryFD: directoryFD
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw FileTransferError.resumeStatePersistenceFailed
        }
    }

    private func partialReservationForSave(
        _ record: ClassicTransferResumeRecord,
        operationDate: Date
    ) throws -> (fileName: String?, byteCount: Int64) {
        let age = operationDate.timeIntervalSince(record.timestamp)
        guard age <= retentionPolicy.recordTTL else {
            throw FileTransferError.resumeStatePersistenceFailed
        }
        let entry = try validatedStoredEntry(
            record,
            recordFileName: resumeFileName(for: record.transferID),
            operationDate: operationDate
        )
        return (entry.partialFileName, entry.partialSize)
    }

    private func pruneInternal(
        operationDate: Date,
        excludingRecordFileName: String? = nil,
        reservedRecordCount: Int = 0,
        reservedInboundPartialFileName: String? = nil,
        reservedInboundPartialBytes: Int64 = 0,
        lockedDirectoryFD: Int32? = nil
    ) throws -> PruneReport {
        guard reservedRecordCount >= 0,
              reservedRecordCount <= retentionPolicy.maximumRecordCount,
              reservedInboundPartialBytes >= 0,
              reservedInboundPartialBytes <= retentionPolicy.maximumTotalInboundPartialBytes else {
            throw FileTransferError.resumeStatePersistenceFailed
        }

        let pruneOperation: (Int32, URL) throws -> (PruneReport, Bool) = { [self] directoryFD, _ in
            var report = PruneReport()
            var observedInvalidRecord = false
            var entries: [StoredEntry] = []
            for recordFileName in try resumeRecordFileNames(directoryFD: directoryFD) {
                try Task.checkCancellation()
                if recordFileName == excludingRecordFileName {
                    continue
                }
                guard let data = try readRecordData(
                    named: recordFileName,
                    directoryFD: directoryFD
                ) else {
                    continue
                }
                let record: ClassicTransferResumeRecord
                do {
                    record = try JSONDecoder().decode(ClassicTransferResumeRecord.self, from: data)
                } catch {
                    // A malformed record cannot safely identify an associated partial.
                    // Preserve it for diagnosis and fail the operation explicitly.
                    throw FileTransferError.resumeStatePersistenceFailed
                }

                switch try inspectStoredEntry(
                    record,
                    recordFileName: recordFileName,
                    operationDate: operationDate
                ) {
                case .invalid(let partial):
                    try cleanupInvalidEntry(
                        recordFileName: recordFileName,
                        partial: partial,
                        directoryFD: directoryFD,
                        report: &report
                    )
                    observedInvalidRecord = true
                case .valid(let entry):
                    if operationDate.timeIntervalSince(entry.record.timestamp)
                        > retentionPolicy.recordTTL {
                        try cleanup(
                            entry,
                            directoryFD: directoryFD,
                            report: &report
                        )
                    } else {
                        entries.append(entry)
                    }
                }
            }

            entries.sort {
                if $0.record.timestamp != $1.record.timestamp {
                    return $0.record.timestamp < $1.record.timestamp
                }
                return $0.recordFileName < $1.recordFileName
            }

            while entries.count + reservedRecordCount > retentionPolicy.maximumRecordCount {
                let oldest = entries.removeFirst()
                try cleanup(oldest, directoryFD: directoryFD, report: &report)
            }

            var retainedPartialBytes = reservedInboundPartialBytes
            for entry in entries {
                guard retainedPartialBytes <= Int64.max - entry.partialSize else {
                    throw FileTransferError.resumeStatePersistenceFailed
                }
                retainedPartialBytes += entry.partialSize
            }
            let referencedPartialFileNames = Set(
                entries.compactMap(\.partialFileName)
                    + [reservedInboundPartialFileName].compactMap { $0 }
            )
            for partial in try isolatedPartialFiles() {
                if referencedPartialFileNames.contains(partial.fileName) {
                    continue
                }
                if operationDate.timeIntervalSince(partial.modifiedAt)
                    > retentionPolicy.recordTTL {
                    try unlinkOwnedPartial(
                        named: partial.fileName,
                        expectedSize: partial.size
                    )
                    report.removedInboundPartialCount += 1
                    report.removedInboundPartialBytes += partial.size
                    continue
                }
                // A recent unreferenced partial may still belong to an active inbound
                // transfer. Count it against the quota, but never unlink it without a
                // record or TTL proof that it is stale.
                guard retainedPartialBytes <= Int64.max - partial.size else {
                    throw FileTransferError.resumeStatePersistenceFailed
                }
                retainedPartialBytes += partial.size
            }
            while retainedPartialBytes > retentionPolicy.maximumTotalInboundPartialBytes {
                guard let index = entries.firstIndex(where: { $0.partialSize > 0 }) else {
                    throw FileTransferError.resumeStatePersistenceFailed
                }
                let oldestPartial = entries.remove(at: index)
                retainedPartialBytes -= oldestPartial.partialSize
                try cleanup(oldestPartial, directoryFD: directoryFD, report: &report)
            }
            return (report, observedInvalidRecord)
        }
        let pruneResult: (PruneReport, Bool)
        if let lockedDirectoryFD {
            pruneResult = try pruneOperation(lockedDirectoryFD, try resumeDirectoryURL())
        } else {
            pruneResult = try withResumeDirectory(pruneOperation)
        }

        guard !pruneResult.1 else {
            // Invalid metadata is removed so it cannot pin storage forever, but the
            // triggering operation still fails so corruption is never silent.
            throw FileTransferError.resumeStatePersistenceFailed
        }
        return pruneResult.0
    }

    private func validatedStoredEntry(
        _ record: ClassicTransferResumeRecord,
        recordFileName: String,
        operationDate: Date
    ) throws -> StoredEntry {
        switch try inspectStoredEntry(
            record,
            recordFileName: recordFileName,
            operationDate: operationDate
        ) {
        case .valid(let entry):
            return entry
        case .invalid:
            throw FileTransferError.resumeStatePersistenceFailed
        }
    }

    private func inspectStoredEntry(
        _ record: ClassicTransferResumeRecord,
        recordFileName: String,
        operationDate: Date
    ) throws -> StoredEntryInspection {
        let partial = try inspectPartial(for: record)
        let age = operationDate.timeIntervalSince(record.timestamp)
        let directionIsKnown = record.direction == TransferDirection.incoming.rawValue
            || record.direction == TransferDirection.outgoing.rawValue
        let partialMatchesDirection: Bool
        let partialFileName: String?
        let partialSize: Int64
        switch partial {
        case .notApplicable:
            partialMatchesDirection = record.direction == TransferDirection.outgoing.rawValue
            partialFileName = nil
            partialSize = 0
        case .valid(let fileName, let size):
            partialMatchesDirection = record.direction == TransferDirection.incoming.rawValue
            partialFileName = fileName
            partialSize = size
        case .invalidTrustedFile, .invalidUntrustedOrMissing:
            return .invalid(partial: partial)
        }

        let commonContractIsValid = !record.transferID.isEmpty
            && resumeFileName(for: record.transferID) == recordFileName
            && directionIsKnown
            && partialMatchesDirection
            && record.fileSize > 0
            && record.fileSize <= ClassicTransferInboundPolicy.maximumFileSizeBytes
            && record.transferredBytes > 0
            && record.transferredBytes < record.fileSize
            && record.resumeOffset == record.transferredBytes
            && record.devicePort > 0
            && record.devicePort <= 65_535
            && record.timestamp.timeIntervalSinceReferenceDate.isFinite
            && age >= -Self.maximumFutureClockSkew
        guard commonContractIsValid else {
            return .invalid(partial: partial)
        }
        do {
            try ClassicTransferMetadataContract.validateResumeOffset(
                record.resumeOffset,
                fileSize: record.fileSize,
                declaredChunkSize: record.declaredChunkSize
            )
        } catch {
            return .invalid(partial: partial)
        }
        return .valid(StoredEntry(
            recordFileName: recordFileName,
            record: record,
            partialFileName: partialFileName,
            partialSize: partialSize
        ))
    }

    private func inspectPartial(
        for record: ClassicTransferResumeRecord
    ) throws -> PartialInspection {
        guard record.direction == TransferDirection.incoming.rawValue else {
            return .notApplicable
        }
        guard let fileName = try isolatedPartialFileName(for: record.localPath) else {
            return .invalidUntrustedOrMissing
        }
        guard let result = try withExistingPartialDirectory({ directoryFD in
            var status = stat()
            let statusResult = fileName.withCString {
                fstatat(directoryFD, $0, &status, AT_SYMLINK_NOFOLLOW)
            }
            if statusResult != 0, errno == ENOENT {
                return PartialInspection.invalidUntrustedOrMissing
            }
            guard statusResult == 0 else {
                throw FileTransferError.resumeStatePersistenceFailed
            }
            guard isRegularFile(status.st_mode),
                  status.st_uid == geteuid(),
                  status.st_nlink == 1,
                  status.st_mode & mode_t(0o077) == 0,
                  status.st_size >= 0 else {
                return PartialInspection.invalidUntrustedOrMissing
            }
            let size = Int64(status.st_size)
            guard size == record.transferredBytes,
                  size == record.resumeOffset,
                  size < record.fileSize,
                  size <= ClassicTransferInboundPolicy.maximumFileSizeBytes else {
                return PartialInspection.invalidTrustedFile(fileName: fileName, size: size)
            }
            return PartialInspection.valid(fileName: fileName, size: size)
        }) else {
            return .invalidUntrustedOrMissing
        }
        return result
    }

    private func cleanupInvalidEntry(
        recordFileName: String,
        partial: PartialInspection,
        directoryFD: Int32,
        report: inout PruneReport
    ) throws {
        switch partial {
        case .valid(let fileName, let size),
             .invalidTrustedFile(let fileName, let size):
            try unlinkOwnedPartial(named: fileName, expectedSize: size)
            report.removedInboundPartialCount += 1
            report.removedInboundPartialBytes += size
        case .notApplicable, .invalidUntrustedOrMissing:
            // A path that is not proven to be an owned direct child is never deleted.
            break
        }
        guard try unlinkOwnedRecordIfPresent(
            named: recordFileName,
            directoryFD: directoryFD
        ) else {
            throw FileTransferError.resumeStatePersistenceFailed
        }
        report.removedRecordCount += 1
    }

    private func cleanup(
        _ entry: StoredEntry,
        directoryFD: Int32,
        report: inout PruneReport
    ) throws {
        if let partialFileName = entry.partialFileName {
            try unlinkOwnedPartial(named: partialFileName, expectedSize: entry.partialSize)
            report.removedInboundPartialCount += 1
            report.removedInboundPartialBytes += entry.partialSize
        }
        guard try unlinkOwnedRecordIfPresent(
            named: entry.recordFileName,
            directoryFD: directoryFD
        ) else {
            throw FileTransferError.resumeStatePersistenceFailed
        }
        report.removedRecordCount += 1
    }

    private func withResumeDirectory<Result>(
        _ operation: (Int32, URL) throws -> Result
    ) throws -> Result {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }

        let directoryURL = try resumeDirectoryURL()
        let directoryFD = try openResumeDirectory()
        let lockFD: Int32
        do {
            lockFD = try openAndLockResumeStore(directoryFD: directoryFD)
        } catch {
            guard Darwin.close(directoryFD) == 0 else {
                throw FileTransferError.resumeStatePersistenceFailed
            }
            throw error
        }
        let result: Swift.Result<Result, Error>
        do {
            result = .success(try operation(directoryFD, directoryURL))
        } catch {
            result = .failure(error)
        }
        let unlockSucceeded = unlockResumeStore(lockFD: lockFD)
        let lockCloseSucceeded = Darwin.close(lockFD) == 0
        let directoryCloseSucceeded = Darwin.close(directoryFD) == 0
        guard unlockSucceeded, lockCloseSucceeded, directoryCloseSucceeded else {
            throw FileTransferError.resumeStatePersistenceFailed
        }
        return try result.get()
    }

    private func openAndLockResumeStore(directoryFD: Int32) throws -> Int32 {
        let flags = O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW
        let lockFD = Self.lockFileName.withCString {
            openat(directoryFD, $0, flags, Self.privateFileMode)
        }
        guard lockFD >= 0 else {
            throw FileTransferError.resumeStatePersistenceFailed
        }

        var status = stat()
        guard fstat(lockFD, &status) == 0,
              isRegularFile(status.st_mode),
              status.st_uid == geteuid(),
              status.st_nlink == 1,
              status.st_mode & mode_t(0o077) == 0,
              fchmod(lockFD, Self.privateFileMode) == 0 else {
            let closeResult = Darwin.close(lockFD)
            guard closeResult == 0 else {
                throw FileTransferError.resumeStatePersistenceFailed
            }
            throw FileTransferError.resumeStatePersistenceFailed
        }

        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        lock.l_start = 0
        lock.l_len = 0
        while Darwin.fcntl(lockFD, F_SETLKW, &lock) != 0 {
            if errno == EINTR { continue }
            let closeResult = Darwin.close(lockFD)
            guard closeResult == 0 else {
                throw FileTransferError.resumeStatePersistenceFailed
            }
            throw FileTransferError.resumeStatePersistenceFailed
        }
        return lockFD
    }

    private func unlockResumeStore(lockFD: Int32) -> Bool {
        var lock = flock()
        lock.l_type = Int16(F_UNLCK)
        lock.l_whence = Int16(SEEK_SET)
        lock.l_start = 0
        lock.l_len = 0
        while Darwin.fcntl(lockFD, F_SETLK, &lock) != 0 {
            if errno == EINTR { continue }
            return false
        }
        return true
    }

    private func resumeDirectoryURL() throws -> URL {
        try canonicalBaseDirectoryURL()
            .appendingPathComponent("SkyBridge", isDirectory: true)
            .appendingPathComponent("ResumeData", isDirectory: true)
    }

    private func partialDirectoryURL() throws -> URL {
        if let partialDirectoryOverride {
            do {
                return try DarwinSecurePathPolicy
                    .canonicalizingSystemRootAlias(partialDirectoryOverride)
            } catch {
                throw FileTransferError.resumeStatePersistenceFailed
            }
        }
        return try canonicalBaseDirectoryURL()
            .appendingPathComponent("SkyBridge", isDirectory: true)
            .appendingPathComponent("ClassicInboundPartials", isDirectory: true)
    }

    private func canonicalBaseDirectoryURL() throws -> URL {
        let baseDirectory: URL
        if let baseDirectoryOverride {
            baseDirectory = baseDirectoryOverride
        } else if let cachesDirectory = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first {
            baseDirectory = cachesDirectory
        } else {
            throw FileTransferError.resumeStatePersistenceFailed
        }
        do {
            return try DarwinSecurePathPolicy.canonicalizingSystemRootAlias(baseDirectory)
        } catch {
            throw FileTransferError.resumeStatePersistenceFailed
        }
    }

    private func openResumeDirectory() throws -> Int32 {
        let directoryURL = try resumeDirectoryURL()
        let baseDirectory = directoryURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        var currentFD = try openValidatedAbsoluteDirectory(baseDirectory)

        for component in ["SkyBridge", "ResumeData"] {
            let childFD: Int32
            do {
                childFD = try openOrCreatePrivateDirectory(named: component, parentFD: currentFD)
            } catch {
                let closeResult = Darwin.close(currentFD)
                guard closeResult == 0 else {
                    throw FileTransferError.resumeStatePersistenceFailed
                }
                throw error
            }
            guard Darwin.close(currentFD) == 0 else {
                let childCloseResult = Darwin.close(childFD)
                guard childCloseResult == 0 else {
                    throw FileTransferError.resumeStatePersistenceFailed
                }
                throw FileTransferError.resumeStatePersistenceFailed
            }
            currentFD = childFD
        }
        return currentFD
    }

    private func openValidatedAbsoluteDirectory(_ directory: URL) throws -> Int32 {
        let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        var currentFD = Darwin.open("/", flags)
        guard currentFD >= 0 else {
            throw FileTransferError.resumeStatePersistenceFailed
        }

        let canonicalDirectory: URL
        do {
            canonicalDirectory = try DarwinSecurePathPolicy
                .canonicalizingSystemRootAlias(directory)
        } catch {
            let closeResult = Darwin.close(currentFD)
            guard closeResult == 0 else {
                throw FileTransferError.resumeStatePersistenceFailed
            }
            throw FileTransferError.resumeStatePersistenceFailed
        }

        for component in canonicalDirectory.pathComponents.dropFirst() {
            guard !component.isEmpty, component != ".", component != "..", component != "/" else {
                let closeResult = Darwin.close(currentFD)
                guard closeResult == 0 else {
                    throw FileTransferError.resumeStatePersistenceFailed
                }
                throw FileTransferError.resumeStatePersistenceFailed
            }
            let childFD = component.withCString { openat(currentFD, $0, flags) }
            guard childFD >= 0 else {
                let closeResult = Darwin.close(currentFD)
                guard closeResult == 0 else {
                    throw FileTransferError.resumeStatePersistenceFailed
                }
                throw FileTransferError.resumeStatePersistenceFailed
            }
            var status = stat()
            guard fstat(childFD, &status) == 0, isDirectory(status.st_mode) else {
                let childCloseResult = Darwin.close(childFD)
                let currentCloseResult = Darwin.close(currentFD)
                guard childCloseResult == 0, currentCloseResult == 0 else {
                    throw FileTransferError.resumeStatePersistenceFailed
                }
                throw FileTransferError.resumeStatePersistenceFailed
            }
            guard Darwin.close(currentFD) == 0 else {
                let childCloseResult = Darwin.close(childFD)
                guard childCloseResult == 0 else {
                    throw FileTransferError.resumeStatePersistenceFailed
                }
                throw FileTransferError.resumeStatePersistenceFailed
            }
            currentFD = childFD
        }
        return currentFD
    }

    private func openOrCreatePrivateDirectory(named name: String, parentFD: Int32) throws -> Int32 {
        let createResult = name.withCString {
            mkdirat(parentFD, $0, Self.privateDirectoryMode)
        }
        guard createResult == 0 || errno == EEXIST else {
            throw FileTransferError.resumeStatePersistenceFailed
        }

        let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        let directoryFD = name.withCString { openat(parentFD, $0, flags) }
        guard directoryFD >= 0 else {
            throw FileTransferError.resumeStatePersistenceFailed
        }
        var status = stat()
        guard fstat(directoryFD, &status) == 0,
              isDirectory(status.st_mode),
              status.st_uid == geteuid(),
              fchmod(directoryFD, Self.privateDirectoryMode) == 0 else {
            let closeResult = Darwin.close(directoryFD)
            guard closeResult == 0 else {
                throw FileTransferError.resumeStatePersistenceFailed
            }
            throw FileTransferError.resumeStatePersistenceFailed
        }
        return directoryFD
    }

    private func validateExistingRecordIfPresent(named name: String, directoryFD: Int32) throws {
        var status = stat()
        let statusResult = name.withCString {
            fstatat(directoryFD, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        if statusResult != 0, errno == ENOENT {
            return
        }
        guard statusResult == 0,
              isRegularFile(status.st_mode),
              status.st_uid == geteuid() else {
            throw FileTransferError.resumeStatePersistenceFailed
        }
    }

    private func readRecordData(named name: String, directoryFD: Int32) throws -> Data? {
        let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        let fileFD = name.withCString { openat(directoryFD, $0, flags) }
        if fileFD < 0, errno == ENOENT {
            return nil
        }
        guard fileFD >= 0 else {
            throw FileTransferError.resumeStatePersistenceFailed
        }

        let readResult: Swift.Result<Data, Error>
        do {
            var status = stat()
            guard fstat(fileFD, &status) == 0,
                  isRegularFile(status.st_mode),
                  status.st_uid == geteuid(),
                  status.st_size > 0,
                  status.st_size <= off_t(Self.maximumRecordSize),
                  status.st_mode & mode_t(0o077) == 0 else {
                throw FileTransferError.resumeStatePersistenceFailed
            }

            let expectedSize = Int(status.st_size)
            var data = Data()
            data.reserveCapacity(expectedSize)
            var buffer = [UInt8](repeating: 0, count: min(16 * 1_024, expectedSize + 1))
            while true {
                let bytesRead = buffer.withUnsafeMutableBytes {
                    Darwin.read(fileFD, $0.baseAddress, $0.count)
                }
                if bytesRead < 0, errno == EINTR {
                    continue
                }
                guard bytesRead >= 0 else {
                    throw FileTransferError.resumeStatePersistenceFailed
                }
                guard bytesRead > 0 else { break }
                guard data.count <= Self.maximumRecordSize - bytesRead else {
                    throw FileTransferError.resumeStatePersistenceFailed
                }
                data.append(contentsOf: buffer.prefix(bytesRead))
            }

            var finalStatus = stat()
            guard data.count == expectedSize,
                  fstat(fileFD, &finalStatus) == 0,
                  finalStatus.st_size == status.st_size,
                  finalStatus.st_ino == status.st_ino,
                  finalStatus.st_dev == status.st_dev else {
                throw FileTransferError.resumeStatePersistenceFailed
            }
            readResult = .success(data)
        } catch {
            readResult = .failure(error)
        }
        guard Darwin.close(fileFD) == 0 else {
            throw FileTransferError.resumeStatePersistenceFailed
        }
        return try readResult.get()
    }

    private func atomicallyWrite(_ data: Data, named name: String, directoryFD: Int32) throws {
        guard !data.isEmpty, data.count <= Self.maximumRecordSize else {
            throw FileTransferError.resumeStatePersistenceFailed
        }
        let temporaryName = ".\(name).\(UUID().uuidString).tmp"
        let flags = O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW
        let fileFD = temporaryName.withCString {
            openat(directoryFD, $0, flags, Self.privateFileMode)
        }
        guard fileFD >= 0 else {
            throw FileTransferError.resumeStatePersistenceFailed
        }

        var installedFileStatus = stat()
        let writeResult: Swift.Result<Void, Error>
        do {
            try data.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else {
                    throw FileTransferError.resumeStatePersistenceFailed
                }
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(
                        fileFD,
                        baseAddress.advanced(by: offset),
                        bytes.count - offset
                    )
                    if written < 0, errno == EINTR {
                        continue
                    }
                    guard written > 0 else {
                        throw FileTransferError.resumeStatePersistenceFailed
                    }
                    offset += written
                }
            }
            guard fchmod(fileFD, Self.privateFileMode) == 0,
                  fsync(fileFD) == 0,
                  fstat(fileFD, &installedFileStatus) == 0,
                  isRegularFile(installedFileStatus.st_mode),
                  installedFileStatus.st_uid == geteuid() else {
                throw FileTransferError.resumeStatePersistenceFailed
            }
            writeResult = .success(())
        } catch {
            writeResult = .failure(error)
        }

        let closeResult = Darwin.close(fileFD)
        let writeFailed: Bool
        if case .failure = writeResult {
            writeFailed = true
        } else {
            writeFailed = false
        }
        if closeResult != 0 || writeFailed {
            let cleanupResult = temporaryName.withCString { unlinkat(directoryFD, $0, 0) }
            guard cleanupResult == 0 || errno == ENOENT else {
                throw FileTransferError.resumeStatePersistenceFailed
            }
            guard closeResult == 0 else {
                throw FileTransferError.resumeStatePersistenceFailed
            }
            return try writeResult.get()
        }

        let renameResult = temporaryName.withCString { temporaryPointer in
            name.withCString { finalPointer in
                renameat(directoryFD, temporaryPointer, directoryFD, finalPointer)
            }
        }
        guard renameResult == 0 else {
            let cleanupResult = temporaryName.withCString { unlinkat(directoryFD, $0, 0) }
            guard cleanupResult == 0 || errno == ENOENT else {
                throw FileTransferError.resumeStatePersistenceFailed
            }
            throw FileTransferError.resumeStatePersistenceFailed
        }
        guard fsync(directoryFD) == 0 else {
            // The rename may already have installed the new record. Remove only
            // the exact inode we created so a failed directory durability barrier
            // cannot leave an orphan record or delete a concurrent replacement.
            var currentStatus = stat()
            let statusResult = name.withCString {
                fstatat(directoryFD, $0, &currentStatus, AT_SYMLINK_NOFOLLOW)
            }
            guard statusResult == 0,
                  isRegularFile(currentStatus.st_mode),
                  currentStatus.st_uid == geteuid(),
                  currentStatus.st_dev == installedFileStatus.st_dev,
                  currentStatus.st_ino == installedFileStatus.st_ino,
                  name.withCString({ unlinkat(directoryFD, $0, 0) }) == 0,
                  fsync(directoryFD) == 0 else {
                throw FileTransferError.resumeStatePersistenceFailed
            }
            throw FileTransferError.resumeStatePersistenceFailed
        }
    }

    private func resumeRecordFileNames(directoryFD: Int32) throws -> [String] {
        var recordFileNames: [String] = []
        for name in try directoryEntryNames(directoryFD: directoryFD)
            where name.hasSuffix(".resume") {
            guard isResumeRecordFileName(name) else {
                throw FileTransferError.resumeStatePersistenceFailed
            }
            recordFileNames.append(name)
        }
        return recordFileNames
    }

    private func directoryEntryNames(directoryFD: Int32) throws -> [String] {
        let duplicatedFD = fcntl(directoryFD, F_DUPFD_CLOEXEC, 0)
        guard duplicatedFD >= 0 else {
            throw FileTransferError.resumeStatePersistenceFailed
        }
        guard let directoryStream = fdopendir(duplicatedFD) else {
            let closeResult = Darwin.close(duplicatedFD)
            guard closeResult == 0 else {
                throw FileTransferError.resumeStatePersistenceFailed
            }
            throw FileTransferError.resumeStatePersistenceFailed
        }

        var names: [String] = []
        var iterationFailed = false
        while true {
            errno = 0
            guard let entry = readdir(directoryStream) else {
                iterationFailed = errno != 0
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name.0) {
                String(cString: $0)
            }
            guard name != ".", name != ".." else { continue }
            guard names.count < Self.maximumManagedDirectoryEntryCount else {
                iterationFailed = true
                break
            }
            names.append(name)
        }
        let closeResult = closedir(directoryStream)
        guard !iterationFailed, closeResult == 0 else {
            throw FileTransferError.resumeStatePersistenceFailed
        }
        return names.sorted()
    }

    private func isolatedPartialFiles() throws -> [IsolatedPartialFile] {
        guard let files = try withExistingPartialDirectory({ directoryFD in
            var partials: [IsolatedPartialFile] = []
            for fileName in try directoryEntryNames(directoryFD: directoryFD) {
                guard isIsolatedPartialFileName(fileName) else { continue }
                var status = stat()
                let statusResult = fileName.withCString {
                    fstatat(directoryFD, $0, &status, AT_SYMLINK_NOFOLLOW)
                }
                guard statusResult == 0,
                      isRegularFile(status.st_mode),
                      status.st_uid == geteuid(),
                      status.st_nlink == 1,
                      status.st_mode & mode_t(0o077) == 0,
                      status.st_size >= 0 else {
                    throw FileTransferError.resumeStatePersistenceFailed
                }
                let modifiedAt = Date(
                    timeIntervalSince1970: TimeInterval(status.st_mtimespec.tv_sec)
                        + TimeInterval(status.st_mtimespec.tv_nsec) / 1_000_000_000
                )
                partials.append(IsolatedPartialFile(
                    fileName: fileName,
                    size: Int64(status.st_size),
                    modifiedAt: modifiedAt
                ))
            }
            return partials
        }) else {
            return []
        }
        return files
    }

    private func isResumeRecordFileName(_ name: String) -> Bool {
        guard name.count == 64 + ".resume".count,
              name.hasSuffix(".resume") else {
            return false
        }
        return name.dropLast(".resume".count).allSatisfy {
            ("0"..."9").contains($0) || ("a"..."f").contains($0)
        }
    }

    private func isolatedPartialFileName(for path: String) throws -> String? {
        guard path.hasPrefix("/") else { return nil }
        let candidate: URL
        do {
            candidate = try DarwinSecurePathPolicy.canonicalizingSystemRootAlias(
                URL(fileURLWithPath: path, isDirectory: false)
            )
        } catch {
            return nil
        }
        let isolatedDirectory = try partialDirectoryURL().standardizedFileURL
        guard candidate.standardizedFileURL.deletingLastPathComponent().path
                == isolatedDirectory.path else {
            return nil
        }
        let fileName = candidate.lastPathComponent
        guard isIsolatedPartialFileName(fileName) else { return nil }
        return fileName
    }

    private func isIsolatedPartialFileName(_ fileName: String) -> Bool {
        let prefix = ".skybridge-classic-"
        let suffix = ".partial"
        guard fileName.hasPrefix(prefix), fileName.hasSuffix(suffix) else {
            return false
        }
        let identifierStart = fileName.index(fileName.startIndex, offsetBy: prefix.count)
        let identifierEnd = fileName.index(fileName.endIndex, offsetBy: -suffix.count)
        guard identifierStart < identifierEnd,
              UUID(uuidString: String(fileName[identifierStart..<identifierEnd])) != nil else {
            return false
        }
        return true
    }

    private func withExistingPartialDirectory<Result>(
        _ operation: (Int32) throws -> Result
    ) throws -> Result? {
        guard let directoryFD = try openValidatedAbsoluteDirectoryIfPresent(
            try partialDirectoryURL()
        ) else {
            return nil
        }
        let operationResult: Swift.Result<Result, Error>
        do {
            operationResult = .success(try operation(directoryFD))
        } catch {
            operationResult = .failure(error)
        }
        guard Darwin.close(directoryFD) == 0 else {
            throw FileTransferError.resumeStatePersistenceFailed
        }
        return try operationResult.get()
    }

    private func openValidatedAbsoluteDirectoryIfPresent(_ directory: URL) throws -> Int32? {
        let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        var currentFD = Darwin.open("/", flags)
        guard currentFD >= 0 else {
            throw FileTransferError.resumeStatePersistenceFailed
        }
        let canonicalDirectory: URL
        do {
            canonicalDirectory = try DarwinSecurePathPolicy
                .canonicalizingSystemRootAlias(directory)
        } catch {
            let closeResult = Darwin.close(currentFD)
            guard closeResult == 0 else {
                throw FileTransferError.resumeStatePersistenceFailed
            }
            throw FileTransferError.resumeStatePersistenceFailed
        }
        let components = Array(canonicalDirectory.pathComponents.dropFirst())
        for (index, component) in components.enumerated() {
            guard !component.isEmpty, component != ".", component != "..", component != "/" else {
                let closeResult = Darwin.close(currentFD)
                guard closeResult == 0 else {
                    throw FileTransferError.resumeStatePersistenceFailed
                }
                throw FileTransferError.resumeStatePersistenceFailed
            }
            let childFD = component.withCString { openat(currentFD, $0, flags) }
            if childFD < 0, errno == ENOENT {
                let closeResult = Darwin.close(currentFD)
                guard closeResult == 0 else {
                    throw FileTransferError.resumeStatePersistenceFailed
                }
                return nil
            }
            guard childFD >= 0 else {
                let closeResult = Darwin.close(currentFD)
                guard closeResult == 0 else {
                    throw FileTransferError.resumeStatePersistenceFailed
                }
                throw FileTransferError.resumeStatePersistenceFailed
            }
            var status = stat()
            let isFinalComponent = index == components.count - 1
            guard fstat(childFD, &status) == 0,
                  isDirectory(status.st_mode),
                  !isFinalComponent || (
                    status.st_uid == geteuid()
                        && status.st_mode & mode_t(0o077) == 0
                  ) else {
                let childCloseResult = Darwin.close(childFD)
                let currentCloseResult = Darwin.close(currentFD)
                guard childCloseResult == 0, currentCloseResult == 0 else {
                    throw FileTransferError.resumeStatePersistenceFailed
                }
                throw FileTransferError.resumeStatePersistenceFailed
            }
            guard Darwin.close(currentFD) == 0 else {
                let childCloseResult = Darwin.close(childFD)
                guard childCloseResult == 0 else {
                    throw FileTransferError.resumeStatePersistenceFailed
                }
                throw FileTransferError.resumeStatePersistenceFailed
            }
            currentFD = childFD
        }
        return currentFD
    }

    private func unlinkOwnedPartial(named name: String, expectedSize: Int64) throws {
        guard let removed = try withExistingPartialDirectory({ directoryFD in
            var status = stat()
            let statusResult = name.withCString {
                fstatat(directoryFD, $0, &status, AT_SYMLINK_NOFOLLOW)
            }
            guard statusResult == 0,
                  isRegularFile(status.st_mode),
                  status.st_uid == geteuid(),
                  status.st_nlink == 1,
                  status.st_mode & mode_t(0o077) == 0,
                  status.st_size == off_t(expectedSize) else {
                throw FileTransferError.resumeStatePersistenceFailed
            }
            guard name.withCString({ unlinkat(directoryFD, $0, 0) }) == 0,
                  fsync(directoryFD) == 0 else {
                throw FileTransferError.resumeStatePersistenceFailed
            }
            return true
        }), removed else {
            throw FileTransferError.resumeStatePersistenceFailed
        }
    }

    @discardableResult
    private func unlinkOwnedRecordIfPresent(
        named name: String,
        directoryFD: Int32
    ) throws -> Bool {
        var status = stat()
        let statusResult = name.withCString {
            fstatat(directoryFD, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        if statusResult != 0, errno == ENOENT {
            return false
        }
        guard statusResult == 0,
              isRegularFile(status.st_mode),
              status.st_uid == geteuid(),
              status.st_mode & mode_t(0o077) == 0 else {
            throw FileTransferError.resumeStatePersistenceFailed
        }
        guard name.withCString({ unlinkat(directoryFD, $0, 0) }) == 0,
              fsync(directoryFD) == 0 else {
            throw FileTransferError.resumeStatePersistenceFailed
        }
        return true
    }

    private func resumeFileName(for transferID: String) -> String {
        let digest = SHA256.hash(data: Data(transferID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(digest).resume"
    }

    private func isDirectory(_ mode: mode_t) -> Bool {
        mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
    }

    private func isRegularFile(_ mode: mode_t) -> Bool {
        mode & mode_t(S_IFMT) == mode_t(S_IFREG)
    }
}

enum ClassicTransferRecoverableDisconnectPolicy {
    nonisolated static func isRecoverableEstablishedStreamInterruption(_ error: Error) -> Bool {
        if let transferError = error as? FileTransferError {
            switch transferError {
            case .connectionClosed, .timeout:
                return true
            default:
                return false
            }
        }

        guard let networkError = error as? NWError,
              case .posix(let code) = networkError else {
            return false
        }
        switch code {
        case .ECONNABORTED, .ECONNRESET, .EHOSTUNREACH, .ENETDOWN,
             .ENETRESET, .ENETUNREACH, .ENOTCONN, .EPIPE, .ETIMEDOUT:
            return true
        default:
            return false
        }
    }

    nonisolated static func shouldPreserveInboundPartial(
        receivedBytes: Int64,
        after error: Error
    ) -> Bool {
        receivedBytes > 0 && isRecoverableEstablishedStreamInterruption(error)
    }
}

enum ClassicTransferControlIntentPolicy {
    nonisolated static func normalized(
        _ underlyingError: Error,
        status: TransferStatus,
        controlFailure: FileTransferError?
    ) -> Error {
        guard isTransportFailure(underlyingError) else {
            return underlyingError
        }

        if let controlFailure {
            switch controlFailure {
            case .transferCancelled:
                break
            default:
                return controlFailure
            }
        }
        if controlFailure != nil || status == .cancelled || underlyingError is CancellationError {
            return FileTransferError.transferCancelled
        }
        return underlyingError
    }

    private nonisolated static func isTransportFailure(_ error: Error) -> Bool {
        if error is CancellationError || error is NWError || error is FileTransferNetworkError {
            return true
        }
        guard let transferError = error as? FileTransferError else {
            return false
        }
        switch transferError {
        case .transferCancelled,
             .connectionClosed,
             .inboundConnectionClosedBeforeMetadata,
             .timeout,
             .receiptWaitFailed,
             .receiverNotConfirmed:
            return true
        default:
            return false
        }
    }
}

enum ClassicTransferAutomaticResumePolicy {
    nonisolated static func shouldAttempt(
        isEnabled: Bool,
        peerSupportsResume: Bool,
        transferStatus: TransferStatus,
        transferredBytes: Int64,
        fileSize: Int64,
        error: Error
    ) -> Bool {
        guard isEnabled,
              peerSupportsResume,
              transferStatus == .transferring,
              transferredBytes > 0,
              transferredBytes < fileSize else {
            return false
        }

        return ClassicTransferRecoverableDisconnectPolicy
            .isRecoverableEstablishedStreamInterruption(error)
    }
}

enum ClassicTransferLoopControlDecision: Equatable {
    case proceed
    case waitForResume
    case cancel
    case failControlState
    case failInvalidState
}

enum ClassicTransferLoopControlPolicy {
    nonisolated static func decision(for status: TransferStatus) -> ClassicTransferLoopControlDecision {
        switch status {
        case .paused:
            return .waitForResume
        case .cancelled:
            return .cancel
        case .failed:
            return .failControlState
        case .transferring:
            return .proceed
        case .preparing, .completed:
            return .failInvalidState
        }
    }
}

@MainActor
final class ClassicTransferPauseRequest {
    enum Phase: Equatable {
        case awaitingSafeBoundary
        case persisting
        case paused
        case aborted
    }

    private(set) var phase: Phase = .awaitingSafeBoundary
    private var continuation: CheckedContinuation<Int64?, Never>?

    func waitForSafeBoundary() async -> Int64? {
        guard phase == .awaitingSafeBoundary else { return nil }
        return await withCheckedContinuation { continuation in
            precondition(self.continuation == nil)
            self.continuation = continuation
        }
    }

    @discardableResult
    func acknowledge(offset: Int64) -> Bool {
        guard phase == .awaitingSafeBoundary else { return false }
        phase = .persisting
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(returning: offset)
        return true
    }

    func markPaused() -> Bool {
        guard phase == .persisting else { return false }
        phase = .paused
        return true
    }

    func abort() {
        guard phase != .aborted else { return }
        phase = .aborted
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(returning: nil)
    }
}

enum ClassicTransferRouteRetryPolicy {
    nonisolated static func hasSingleTarget(deviceIDs: [String]) -> Bool {
        let normalized = Set(deviceIDs.compactMap { value -> String? in
            let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return candidate.isEmpty ? nil : candidate
        })
        return normalized.count == 1
    }

    nonisolated static func shouldTryNextRoute(after error: Error) -> Bool {
        if let transferError = error as? FileTransferError {
            switch transferError {
            case .connectionClosed, .timeout:
                return true
            default:
                return false
            }
        }
        if let networkError = error as? FileTransferNetworkError {
            switch networkError {
            case .connectionTimeout,
                 .connectionCancelled,
                 .localNetworkPermissionDenied,
                 .invalidEndpoint:
                return true
            case .invalidPort,
                 .invalidMessageType,
                 .incompleteData,
                 .maxConnectionsReached:
                return false
            }
        }

        guard let networkError = error as? NWError,
              case .posix(let code) = networkError else {
            return false
        }
        switch code {
        case .ECONNABORTED, .ECONNREFUSED, .ECONNRESET, .EADDRNOTAVAIL,
             .EHOSTUNREACH, .ENETDOWN, .ENETRESET, .ENETUNREACH, .ETIMEDOUT:
            return true
        default:
            return false
        }
    }

    nonisolated static func deliveryConfirmationIsUnknown(after error: Error) -> Bool {
        if let transferError = error as? FileTransferError {
            switch transferError {
            case .connectionClosed, .timeout:
                return true
            case .receiptWaitFailed(let stage, _):
                return stage == .headerTimeout || stage == .payloadTimeout
            default:
                return false
            }
        }
        return shouldTryNextRoute(after: error)
    }
}

private struct RetryableActiveRouteConnectionError: Error {
    let underlying: Error
}

public enum FileTransferRouteAvailabilityError:
    Error,
    LocalizedError,
    Sendable,
    Equatable
{
    case noAuthenticatedPeer
    case noLiveTransferRoute

    public var errorDescription: String? {
        switch self {
        case .noAuthenticatedPeer:
            return "未建立目标设备的已认证 P2P 会话"
        case .noLiveTransferRoute:
            return "已认证设备当前没有 authority-bound 文件传输路由"
        }
    }
}

/// 文件传输管理器 - 负责高速文件传输，支持分块传输和断点续传
@MainActor
public class FileTransferManager: BaseManager {
    /// Opaque capability binding an external transport callback to one concrete
    /// transfer object and manager lifecycle. Callers must retain and present it
    /// for every progress or terminal update.
    public struct ExternalTransferToken: Hashable, Sendable {
        let identifier: UUID
        let transferID: String
        let lifecycleGeneration: UUID
        let direction: TransferDirection
    }

    struct ExternalTransportOperationToken: Hashable, Sendable {
        let identifier: UUID
        let lifecycleGeneration: UUID
    }

    nonisolated static func externalTransferTokenOwnsCurrentSlot(
        currentToken: ExternalTransferToken?,
        expectedToken: ExternalTransferToken
    ) -> Bool {
        currentToken == expectedToken
    }

    private static let transferHistoryStore = CodablePersistenceStore<[PersistedFileTransferHistoryEntry]>(
        location: .protectedApplicationSupport(
            path: "FileTransfer/manager-history.json",
            legacyUserDefaultsKey: "FileTransferManager.History"
        ),
        maximumPayloadBytes: 2 * 1_024 * 1_024
    )
    private static let transferHistoryRepository = BoundedCodableHistoryRepository(
        store: transferHistoryStore,
        maximumEntryCount: 100
    )
    private static let defaultClassicTransferPort = 8080
    private static let recentInboundTransferRouteTTL: TimeInterval = 300

    /// Shared instance used across the app (so WebRTC / listeners can update the same model the UI observes).
    public static let shared = FileTransferManager()

 // MARK: - 发布的属性
    @Published public var activeTransfers: [String: FileTransfer] = [:]
    @Published public var transferHistory: [FileTransfer] = []
    @Published public var totalProgress: Double = 0.0
    @Published public var isTransferring: Bool = false
    @Published public private(set) var historyPersistenceError: FileTransferHistoryPersistenceFailure?

 // MARK: - 私有属性
    private let networkService = FileTransferNetworkService()
    private var chunkSize: Int = ClassicTransferInboundPolicy.maximumDeclaredChunkSizeBytes
    private let maxChunkSizeBytes: Int = 512 * 1024
    private let maxMessageBytes: Int = 2_000_000
    private var maxConcurrentTransfers = 3
    private var transferSlotPolicy = ClassicTransferSlotQueuePolicy()
    private var transferSlotContinuations: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var lifecycleGeneration = UUID()
    private var acceptsNewTransfers = true
    private var compressionEnabled: Bool = true
    private var maxTransferSpeedBytesPerSecond: Double?
    private var automaticResumeEnabled = true
    private var virusScanEnabled: Bool = false
    private var currentScanLevel: FileScanLevel = .standard
    private var keepTransferHistory: Bool = true
    private var keepSystemAwakeDuringTransfer: Bool = false
    private var receiveBaseDirectory: URL?
    private var transferRateLimitStates: [String: TransferRateLimitState] = [:]
    private var classicConnectionsByTransferID: [String: NWConnection] = [:]
    private var pendingClassicConnections: [ObjectIdentifier: NWConnection] = [:]
    private var classicPauseRequests: [String: ClassicTransferPauseRequest] = [:]
    private var terminalCleanupTasks: [String: Task<Void, Never>] = [:]
    private struct ProductFileTransferEvidenceContext {
        let transferObjectIdentifier: ObjectIdentifier
        let owner: ProductReleaseEvidenceSessionOwner
        let transferReference: String
        let direction: ProductReleaseEvidenceFileDirection
    }
    private var productFileTransferEvidenceContext: ProductFileTransferEvidenceContext?
    private var externalTransferTokensByTransferID: [String: ExternalTransferToken] = [:]
    private var externalTransferCancellationHandlersByTransferID: [String: @MainActor () -> Void] = [:]
    private var externalTransportOperations: [
        UUID: (token: ExternalTransportOperationToken, cancellationHandler: @MainActor () -> Void)
    ] = [:]
    private var activeClassicOperationIDs: Set<UUID> = []
    private var classicOperationDrainContinuations: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var externalOperationDrainContinuations: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var lifecycleTransitionOwnerID: UUID?
    private var lifecycleTransitionWaiters: [
        (id: UUID, continuation: CheckedContinuation<Void, Never>)
    ] = []

    /// Last time we observed meaningful transfer activity (start/progress/finish).
    /// Used for a short UI grace period so the dashboard can show a visible "connected" signal even for fast transfers.
    @MainActor private var lastTransferActivityAt: Date?
    @MainActor private var activityGraceTask: Task<Void, Never>?
    private let transferActivityGraceSeconds: Double = 12.0
    private let historyRepository: BoundedCodableHistoryRepository<PersistedFileTransferHistoryEntry>
    private var historyPersistenceTask: Task<Void, Never>?
    private var historyRequestGeneration: UInt64 = 0
    private var appliedHistoryRepositoryGeneration: UInt64 = 0
    private let receiptWaitTimeoutSeconds: TimeInterval = 60
    private let resumeAckTimeoutSeconds: TimeInterval = 15
    private let pauseQuiescenceTimeoutSeconds: TimeInterval = 15
    private let activeRouteReadinessTimeoutSeconds: TimeInterval = 8
    private let activeRouteReadinessPollIntervalSeconds: TimeInterval = 0.25
    private let powerAssertion: FileTransferPowerAssertionControlling
    private let resumeStore: ClassicTransferResumeStore
    public var localServiceHealthCheck: (@MainActor () async throws -> Void)?

    #if canImport(UserNotifications)
    private static func canUseUserNotificationsSafely() -> Bool {
        // `UNUserNotificationCenter.current()` can raise an Obj-C NSException if the current process
        // isn't running from a proper application bundle (e.g. running the binary directly from Build/Products).
        // Swift cannot catch NSException, so we must gate the call.
        #if DEBUG || SKYBRIDGE_TESTING
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return false
        }
        #endif
        let bundleURL = Bundle.main.bundleURL
        return bundleURL.pathExtension.lowercased() == "app"
    }
    #endif

    /// 初始化文件传输管理器
    public init() {
        self.historyRepository = Self.transferHistoryRepository
        self.powerAssertion = FileTransferPowerAssertionController()
        self.resumeStore = .shared
        super.init(category: "FileTransferManager")
        enqueueHistoryLoad()
        updateSecuritySettings(
            virusScanEnabled: SettingsManager.shared.scanTransferFilesForVirus,
            scanLevel: SettingsManager.shared.scanLevel
        )
        logger.info("📁 初始化文件传输管理器")
    }

    init(
        historyStore: CodablePersistenceStore<[PersistedFileTransferHistoryEntry]>,
        powerAssertion: FileTransferPowerAssertionControlling = FileTransferPowerAssertionController(),
        resumeStore: ClassicTransferResumeStore = .shared
    ) {
        self.historyRepository = BoundedCodableHistoryRepository(
            store: historyStore,
            maximumEntryCount: 100
        )
        self.powerAssertion = powerAssertion
        self.resumeStore = resumeStore
        super.init(category: "FileTransferManager")
        enqueueHistoryLoad()
        updateSecuritySettings(
            virusScanEnabled: SettingsManager.shared.scanTransferFilesForVirus,
            scanLevel: SettingsManager.shared.scanLevel
        )
        logger.info("📁 初始化文件传输管理器")
    }

 // MARK: - 生命周期管理方法

    /// 启动文件传输管理器
    public override func start() async throws {
        let requestedLifecycleGeneration = lifecycleGeneration
        let transitionID = await acquireLifecycleTransition()
        defer { releaseLifecycleTransition(transitionID) }
        try Task.checkCancellation()
        guard !acceptsNewTransfers else {
            logger.debug("📁 文件传输管理器已处于可接收状态")
            return
        }
        guard requestedLifecycleGeneration == lifecycleGeneration else {
            throw FileTransferError.transferCancelled
        }
        let expectedShutdownGeneration = lifecycleGeneration
        await waitForClassicOperationsToDrain()
        await waitForExternalOperationsToDrain()
        await awaitTerminalCleanupTasks()
        guard !acceptsNewTransfers,
              lifecycleGeneration == expectedShutdownGeneration else {
            return
        }
        resetStoppedTransferActivityState()
        lifecycleGeneration = UUID()
        acceptsNewTransfers = true
        logger.info("📁 文件传输管理器已启动")
    }

    /// 停止文件传输管理器
    public override func stop() async {
        let transitionID = await acquireLifecycleTransition()
        defer { releaseLifecycleTransition(transitionID) }
        beginLifecycleShutdown(removeActiveTransfers: false)
        let expectedShutdownGeneration = lifecycleGeneration
        await waitForClassicOperationsToDrain()
        await waitForExternalOperationsToDrain()
        await awaitTerminalCleanupTasks()
        guard !acceptsNewTransfers,
              lifecycleGeneration == expectedShutdownGeneration else {
            return
        }
        resetStoppedTransferActivityState()
        logger.info("📁 文件传输管理器已停止")
    }

    /// 清理资源
    public override func cleanup() {
        beginLifecycleShutdown(removeActiveTransfers: true)
        resetStoppedTransferActivityState()
        logger.info("📁 文件传输管理器资源已清理（保留历史记录）")
    }

    private func beginLifecycleShutdown(removeActiveTransfers: Bool) {
        acceptsNewTransfers = false
        lifecycleGeneration = UUID()
        retireCurrentProductFileTransferEvidence(reason: .user)

        let cancelledWaiters = transferSlotPolicy.cancelAllPending()
        for waiterID in cancelledWaiters {
            guard let continuation = transferSlotContinuations.removeValue(forKey: waiterID) else {
                preconditionFailure("Classic transfer slot continuation missing during shutdown")
            }
            continuation.resume(throwing: FileTransferError.transferCancelled)
        }

        for request in classicPauseRequests.values {
            request.abort()
        }
        classicPauseRequests.removeAll()
        InboundFileTransferApprovalService.shared.userDismissedCurrentPrompt()

        let externalCancellationHandlers = Array(
            externalTransferCancellationHandlersByTransferID.values
        )
        let externalTransportCancellationHandlers = externalTransportOperations.values.map(
            \.cancellationHandler
        )
        for cancellationHandler in externalCancellationHandlers
            + externalTransportCancellationHandlers {
            cancellationHandler()
        }

        let externalTransferIDs = Set(externalTransferTokensByTransferID.keys)
        let activeTransferSnapshot = Array(activeTransfers.values)
        let connectedTransferIDs = Set(classicConnectionsByTransferID.keys)
        for transfer in activeTransferSnapshot where !externalTransferIDs.contains(transfer.id) {
            transfer.status = .cancelled
            transfer.classicControlFailure = FileTransferError.transferCancelled
            transfer.error = FileTransferError.transferCancelled.localizedDescription
            transfer.completedAt = Date()
        }

        var connectionsByIdentity: [ObjectIdentifier: NWConnection] = [:]
        for connection in classicConnectionsByTransferID.values {
            connectionsByIdentity[ObjectIdentifier(connection)] = connection
        }
        for connection in pendingClassicConnections.values {
            connectionsByIdentity[ObjectIdentifier(connection)] = connection
        }
        for connection in connectionsByIdentity.values {
            connection.cancel()
        }
        classicConnectionsByTransferID.removeAll()
        pendingClassicConnections.removeAll()
        networkService.cancelAllConnections()

        transferRateLimitStates.removeAll()
        activityGraceTask?.cancel()
        activityGraceTask = nil
        for transfer in activeTransferSnapshot
            where !externalTransferIDs.contains(transfer.id)
                && !connectedTransferIDs.contains(transfer.id) {
            if transfer.resumeDataPath != nil
                || (transfer.direction == .incoming && transfer.classicResumeSourcePath != nil) {
                scheduleTerminalCancellationCleanup(for: transfer)
            } else if !removeActiveTransfers {
                moveToHistory(transfer)
            }
        }
        if removeActiveTransfers {
            for transfer in activeTransferSnapshot where !externalTransferIDs.contains(transfer.id) {
                activeTransfers.removeValue(forKey: transfer.id)
            }
        }
        updateTransferPowerAssertion()
        updateTransferringStatus()
    }

    private func acquireLifecycleTransition() async -> UUID {
        let transitionID = UUID()
        guard lifecycleTransitionOwnerID != nil else {
            lifecycleTransitionOwnerID = transitionID
            return transitionID
        }
        await withCheckedContinuation { continuation in
            lifecycleTransitionWaiters.append((transitionID, continuation))
        }
        precondition(
            lifecycleTransitionOwnerID == transitionID,
            "File transfer lifecycle transition resumed without ownership"
        )
        return transitionID
    }

    private func releaseLifecycleTransition(_ transitionID: UUID) {
        precondition(
            lifecycleTransitionOwnerID == transitionID,
            "File transfer lifecycle transition released by a non-owner"
        )
        guard !lifecycleTransitionWaiters.isEmpty else {
            lifecycleTransitionOwnerID = nil
            return
        }
        let next = lifecycleTransitionWaiters.removeFirst()
        lifecycleTransitionOwnerID = next.id
        next.continuation.resume()
    }

    private func resetStoppedTransferActivityState() {
        activityGraceTask?.cancel()
        activityGraceTask = nil
        lastTransferActivityAt = nil
        isTransferring = false
        totalProgress = 0
    }

    private func beginClassicOperation() -> UUID {
        let operationID = UUID()
        let inserted = activeClassicOperationIDs.insert(operationID).inserted
        precondition(inserted, "Classic transfer operation identifier collision")
        return operationID
    }

    private func endClassicOperation(_ operationID: UUID) {
        precondition(
            activeClassicOperationIDs.remove(operationID) != nil,
            "Classic transfer operation ended without registration"
        )
        guard activeClassicOperationIDs.isEmpty else { return }
        let continuations = Array(classicOperationDrainContinuations.values)
        classicOperationDrainContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    private func waitForClassicOperationsToDrain() async {
        guard !activeClassicOperationIDs.isEmpty else { return }
        let waiterID = UUID()
        await withCheckedContinuation { continuation in
            classicOperationDrainContinuations[waiterID] = continuation
        }
    }

    private func waitForExternalOperationsToDrain() async {
        guard !externalTransferTokensByTransferID.isEmpty
                || !externalTransportOperations.isEmpty else {
            return
        }
        let waiterID = UUID()
        await withCheckedContinuation { continuation in
            externalOperationDrainContinuations[waiterID] = continuation
        }
    }

 // MARK: - 公共方法
 /// 更新传输设置（运行时可变）
    public func updateSettings(
        maxConcurrentTransfers: Int? = nil,
        chunkSize: Int? = nil,
        enableCompression: Bool? = nil,
        maxTransferSpeedBytesPerSecond: Double? = nil,
        automaticResumeEnabled: Bool? = nil,
        keepTransferHistory: Bool? = nil,
        keepSystemAwakeDuringTransfer: Bool? = nil
    ) {
        if let maxConcurrentTransfers,
           !(1...ClassicTransferInboundPolicy.maximumConcurrentConnections)
            .contains(maxConcurrentTransfers) {
            reportInvalidRuntimeSetting("invalid_concurrent_transfer_limit")
            return
        }
        if let chunkSize,
           !(ClassicTransferInboundPolicy.minimumDeclaredChunkSizeBytes...ClassicTransferInboundPolicy.maximumDeclaredChunkSizeBytes).contains(chunkSize) {
            reportInvalidRuntimeSetting("invalid_transfer_chunk_size")
            return
        }
        var shouldUpdateSpeedLimit = false
        var validatedSpeedLimit: Double?
        if let maxTransferSpeedBytesPerSecond {
            let maximumSupportedSpeed = 500.0 * 1_024 * 1_024
            guard maxTransferSpeedBytesPerSecond.isFinite,
                  maxTransferSpeedBytesPerSecond >= 0,
                  maxTransferSpeedBytesPerSecond <= maximumSupportedSpeed else {
                reportInvalidRuntimeSetting("invalid_transfer_speed_limit")
                return
            }
            shouldUpdateSpeedLimit = true
            validatedSpeedLimit = maxTransferSpeedBytesPerSecond > 0
                ? maxTransferSpeedBytesPerSecond
                : nil
        }

        if let maxConcurrentTransfers {
            self.maxConcurrentTransfers = maxConcurrentTransfers
            let resumedIdentifiers = transferSlotPolicy.drain(
                configuredLimit: self.maxConcurrentTransfers
            )
            resumeTransferSlotContinuations(resumedIdentifiers)
        }
        if let chunkSize { self.chunkSize = chunkSize }
        if let enableCompression { self.compressionEnabled = enableCompression }
        if shouldUpdateSpeedLimit {
            self.maxTransferSpeedBytesPerSecond = validatedSpeedLimit
        }
        if let automaticResumeEnabled {
            self.automaticResumeEnabled = automaticResumeEnabled
        }
        if let keepTransferHistory {
            self.keepTransferHistory = keepTransferHistory
            if !keepTransferHistory {
                clearHistory()
            }
        }
        if let keepSystemAwakeDuringTransfer {
            self.keepSystemAwakeDuringTransfer = keepSystemAwakeDuringTransfer
            updateTransferPowerAssertion()
        }
        logger.info("⚙️ 传输设置已更新：并发=\(self.maxConcurrentTransfers), 块=\(self.chunkSize), 压缩=\(self.compressionEnabled), 经典传输加密=AES-256-GCM(required), 限速=\(self.currentSpeedLimitDescription(), privacy: .public), 自动续传=\(self.automaticResumeEnabled, privacy: .public), 历史=\(self.keepTransferHistory, privacy: .public), 保持唤醒=\(self.keepSystemAwakeDuringTransfer, privacy: .public)")
    }

    private func reportInvalidRuntimeSetting(_ code: String) {
        logger.error("拒绝无效的文件传输运行时设置: code=\(code, privacy: .public)")
        NotificationCenter.default.post(
            name: Notification.Name("FileTransferSettingsValidationFailure"),
            object: nil,
            userInfo: ["code": code]
        )
    }

    public func updateSecuritySettings(
        virusScanEnabled: Bool? = nil,
        scanLevel: FileScanLevel? = nil
    ) {
        if let virusScanEnabled {
            self.virusScanEnabled = virusScanEnabled
        }
        if let scanLevel {
            self.currentScanLevel = scanLevel
        }
        logger.info(
            "🛡️ 文件扫描设置已更新：启用=\(self.virusScanEnabled, privacy: .public) 级别=\(self.currentScanLevel.rawValue, privacy: .public)"
        )
    }

    /// 设置接收文件的基础目录
    public func setReceiveBaseDirectory(_ url: URL?) {
        receiveBaseDirectory = url?.standardizedFileURL
        logger.info("📂 接收目录设置已更新")
    }

    #if DEBUG || SKYBRIDGE_TESTING
    var configuredSpeedLimitBytesPerSecondForTesting: Double? {
        maxTransferSpeedBytesPerSecond
    }

    @MainActor
    func testingAuthenticatedClassicTransferSourceCount() async -> Int {
        let primary = P2PNetworkManager.shared.activeConnections.values.filter { $0.status == .authenticated }
        let discoveryAuthenticated = P2PDiscoveryService.shared.activeAuthenticatedConnectionsForClassicTransfer()
        let registryConnections = await ClassicTransferSessionRegistry.shared.activeConnections()
        var deduped: [ObjectIdentifier: P2PConnection] = [:]
        for connection in primary + discoveryAuthenticated + registryConnections where connection.status == .authenticated {
            deduped[ObjectIdentifier(connection)] = connection
        }
        return deduped.count
    }

    func testingAcquireTransferSlot() async throws -> UUID {
        try await acquireTransferSlot()
    }

    func testingReleaseTransferSlot() {
        releaseTransferSlot()
    }

    var testingTransferSlotCounts: (inFlight: Int, pending: Int) {
        (transferSlotPolicy.inFlightCount, transferSlotPolicy.pendingCount)
    }

    var testingLifecycleGeneration: UUID {
        lifecycleGeneration
    }

    func testingEnsureCurrentLifecycle(_ generation: UUID) throws {
        try ensureCurrentLifecycle(generation)
    }

    func testingAwaitTerminalCleanupTasks() async {
        await awaitTerminalCleanupTasks()
    }

    func testingBeginClassicOperation() -> UUID {
        beginClassicOperation()
    }

    func testingEndClassicOperation(_ operationID: UUID) {
        endClassicOperation(operationID)
    }

    var testingActiveClassicOperationCount: Int {
        activeClassicOperationIDs.count
    }

    var testingAcceptsNewTransfers: Bool {
        acceptsNewTransfers
    }

    var testingLifecycleTransitionWaiterCount: Int {
        lifecycleTransitionWaiters.count
    }
    #endif

    private struct TransferRateLimitState {
        var windowStart: Date
        var bytesInWindow: Int64
    }

    @available(macOS 14.0, iOS 17.0, *)
    private struct ClassicTransferSecurityContext {
        struct ProductEvidenceBinding {
            let sessionReference: String
            let routeClass: ProductReleaseEvidenceRouteClass
            let handshakeRole: ProductReleaseEvidenceHandshakeRole
            let negotiatedSuite: CryptoSuite
        }

        let transferKey: SymmetricKey
        let matchDeviceId: String
        let resolvedPeerDeviceId: String
        let matchedBy: ClassicTransferPeerResolutionBranch
        let declaredCandidates: [String]
        let endpointCandidates: [String]
        let supportsClassicResume: Bool
        let productEvidenceBinding: ProductEvidenceBinding?
    }

    private func currentSpeedLimitDescription() -> String {
        guard let limit = maxTransferSpeedBytesPerSecond,
              limit.isFinite,
              limit > 0,
              limit <= Double(Int64.max) else {
            return "不限速"
        }

        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: Int64(limit)))/s"
    }

    private func applySpeedLimitIfNeeded(for transferId: String, transferredBytes: Int) async throws {
        guard transferredBytes > 0 else { return }
        guard let limit = maxTransferSpeedBytesPerSecond, limit > 0 else { return }

        let now = Date()
        var state = transferRateLimitStates[transferId] ?? TransferRateLimitState(windowStart: now, bytesInWindow: 0)

        if now.timeIntervalSince(state.windowStart) >= 1.0 {
            state.windowStart = now
            state.bytesInWindow = 0
        }

        state.bytesInWindow += Int64(transferredBytes)
        let elapsed = max(Date().timeIntervalSince(state.windowStart), 0.000_001)
        let expectedDuration = Double(state.bytesInWindow) / limit

        if expectedDuration > elapsed {
            let sleepSeconds = expectedDuration - elapsed
            if sleepSeconds > 0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(min(sleepSeconds, 5.0) * 1_000_000_000))
                } catch is CancellationError {
                    throw FileTransferError.transferCancelled
                }
            }
        }

        transferRateLimitStates[transferId] = state
    }

    private func clearSpeedLimitState(for transferId: String) {
        transferRateLimitStates.removeValue(forKey: transferId)
    }

    private func acquireTransferSlot(expectedGeneration: UUID? = nil) async throws -> UUID {
        guard acceptsNewTransfers,
              expectedGeneration == nil || expectedGeneration == lifecycleGeneration,
              !Task.isCancelled else {
            throw FileTransferError.transferCancelled
        }
        let acquiredGeneration = lifecycleGeneration
        let waiterID = UUID()
        switch transferSlotPolicy.request(
            identifier: waiterID,
            configuredLimit: maxConcurrentTransfers
        ) {
        case .acquired:
            return acquiredGeneration
        case .capacityExceeded:
            throw FileTransferError.capacityExceeded
        case .queued:
            break
        }
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    _ = transferSlotPolicy.cancelPending(identifier: waiterID)
                    continuation.resume(throwing: FileTransferError.transferCancelled)
                    return
                }
                transferSlotContinuations[waiterID] = continuation
            }
        }, onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelTransferSlotWaiter(waiterID)
            }
        })
        if Task.isCancelled {
            releaseTransferSlot()
            throw FileTransferError.transferCancelled
        }
        guard acceptsNewTransfers, lifecycleGeneration == acquiredGeneration else {
            releaseTransferSlot()
            throw FileTransferError.transferCancelled
        }
        return acquiredGeneration
    }

    private func ensureCurrentLifecycle(_ generation: UUID) throws {
        guard isCurrentLifecycle(generation),
              !Task.isCancelled else {
            throw FileTransferError.transferCancelled
        }
    }

    private func isCurrentLifecycle(_ generation: UUID) -> Bool {
        acceptsNewTransfers && lifecycleGeneration == generation
    }

    private func releaseTransferSlot() {
        let resumedIdentifiers = transferSlotPolicy.release(
            configuredLimit: maxConcurrentTransfers
        )
        resumeTransferSlotContinuations(resumedIdentifiers)
    }

    private func resumeTransferSlotContinuations(_ identifiers: [UUID]) {
        for identifier in identifiers {
            guard let continuation = transferSlotContinuations.removeValue(forKey: identifier) else {
                preconditionFailure("Classic transfer slot continuation missing for queued waiter")
            }
            continuation.resume()
        }
    }

    private func cancelTransferSlotWaiter(_ waiterID: UUID) {
        guard transferSlotPolicy.cancelPending(identifier: waiterID) else {
            return
        }
        transferSlotContinuations.removeValue(forKey: waiterID)?
            .resume(throwing: FileTransferError.transferCancelled)
    }

    private func scanReceivedFileIfEnabled(_ url: URL) async -> FileScanResult? {
        guard virusScanEnabled else {
            logger.debug("🛡️ 病毒扫描未启用，跳过接收文件")
            return nil
        }

        logger.info(
            "🛡️ 开始扫描接收文件: level=\(self.currentScanLevel.rawValue, privacy: .public)"
        )
#if os(macOS)
        let configuration = FileScanConfiguration(level: self.currentScanLevel)
        let result = await FileScanService.shared.scanFile(at: url, configuration: configuration)
#else
        // 扫描器实现依赖 macOS 专属能力（隔离属性 xattr、SecCode 代码签名、Process），
        // 其它平台没有对应物。既然扫描是**用户已启用**的安全特性，这里必须 fail-closed：
        // 报 `.unknown`（既有语义为「无法确定」，`isSafe` 为 false），让文件按未通过扫描处理，
        // 而不是静默跳过 —— 静默跳过会让「开启扫描」与「未开启扫描」在本平台行为一致。
        logger.error(
            "⛔️ 已启用文件扫描，但本平台没有可用的扫描器实现；按未通过扫描处理"
        )
        let result = FileScanResult(
            fileURL: url,
            verdict: .unknown,
            methodsUsed: [],
            scanLevel: self.currentScanLevel
        )
#endif

        if case .block(let reason) = result.automaticTransferAdmission {
            switch reason {
            case .unsafe:
                logger.warning("🚨 接收文件扫描命中威胁")
            case .reviewRequired, .incomplete:
                logger.warning(
                    "⛔️ 接收文件扫描未满足自动放行条件: verdict=\(result.verdict.rawValue, privacy: .public)"
                )
            }
            postAutomaticTransferScanRejection(result: result, fileURL: url)
        }

        return result
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func classicTransferSecurityContext(
        peerContext: FileTransferPeerContext
    ) async throws -> ClassicTransferSecurityContext {
        let primary = P2PNetworkManager.shared.activeConnections.values.filter { connection in
            connection.status == .authenticated
        }
        let discoveryAuthenticated = P2PDiscoveryService.shared.activeAuthenticatedConnectionsForClassicTransfer()
        let registryConnections = await ClassicTransferSessionRegistry.shared.activeConnections()
        let registrySessions = await ClassicTransferSessionRegistry.shared.activeSessions()
        var deduped: [ObjectIdentifier: P2PConnection] = [:]
        for connection in primary + discoveryAuthenticated + registryConnections where connection.status == .authenticated {
            deduped[ObjectIdentifier(connection)] = connection
        }
        let authenticatedConnections = Array(deduped.values)
        enum KeyOrigin {
            case live(P2PConnection, exactSnapshot: ClassicTransferSessionSnapshot?)
            case snapshot(ClassicTransferSessionSnapshot)
        }
        struct UnkeyedSource {
            let sourceIdentifier: UUID
            let candidate: ClassicTransferAuthenticatedPeerCandidate
            let lastSeenAt: Date
            let sourceKind: ClassicTransferAuthenticatedSessionKind
            let keyOrigin: KeyOrigin
        }
        var sourcesByKey: [String: UnkeyedSource] = [:]
        func isPreferred(_ lhs: UnkeyedSource, over rhs: UnkeyedSource) -> Bool {
            if lhs.lastSeenAt != rhs.lastSeenAt {
                return lhs.lastSeenAt > rhs.lastSeenAt
            }
            if lhs.sourceKind != rhs.sourceKind {
                return lhs.sourceKind.rawValue > rhs.sourceKind.rawValue
            }
            if lhs.candidate.resolvedPeerDeviceId != rhs.candidate.resolvedPeerDeviceId {
                return lhs.candidate.resolvedPeerDeviceId.localizedCaseInsensitiveCompare(
                    rhs.candidate.resolvedPeerDeviceId
                ) == .orderedAscending
            }
            return lhs.candidate.matchDeviceId.localizedCaseInsensitiveCompare(
                rhs.candidate.matchDeviceId
            ) == .orderedAscending
        }
        func upsert(_ source: UnkeyedSource, dedupeKey: String) {
            if let existing = sourcesByKey[dedupeKey], !isPreferred(source, over: existing) {
                return
            }
            sourcesByKey[dedupeKey] = source
        }
        for connection in authenticatedConnections {
            let exactSnapshotPrefix = "p2p-\(connection.id.uuidString)-"
            let exactSnapshots = registrySessions.filter {
                $0.sessionId.hasPrefix(exactSnapshotPrefix)
            }
            let exactSnapshot = exactSnapshots.count == 1 ? exactSnapshots[0] : nil
            let candidate = Self.classicTransferAuthenticatedPeerCandidate(for: connection)
            let dedupeKey = [
                candidate.resolvedPeerDeviceId.lowercased(),
                candidate.endpointHostOrIP?.lowercased() ?? "-"
            ].joined(separator: "|")
            upsert(
                UnkeyedSource(
                    sourceIdentifier: UUID(),
                    candidate: candidate,
                    lastSeenAt: connection.lastActivity,
                    sourceKind: .liveConnection,
                    keyOrigin: .live(connection, exactSnapshot: exactSnapshot)
                ),
                dedupeKey: dedupeKey
            )
        }
        for snapshot in registrySessions {
            let candidate = Self.classicTransferAuthenticatedPeerCandidate(for: snapshot)
            let dedupeKey = [
                candidate.resolvedPeerDeviceId.lowercased(),
                candidate.endpointHostOrIP?.lowercased() ?? "-"
            ].joined(separator: "|")
            upsert(
                UnkeyedSource(
                    sourceIdentifier: UUID(),
                    candidate: candidate,
                    lastSeenAt: snapshot.lastSeenAt,
                    sourceKind: .sessionSnapshot,
                    keyOrigin: .snapshot(snapshot)
                ),
                dedupeKey: dedupeKey
            )
        }
        let authenticatedSources = Array(sourcesByKey.values)
        let selectionSources = authenticatedSources.map { source in
            ClassicTransferAuthenticatedSessionSource(
                sourceIdentifier: source.sourceIdentifier,
                candidate: source.candidate,
                lastSeenAt: source.lastSeenAt,
                sourceKind: source.sourceKind
            )
        }
        guard let selectedResolution = ClassicTransferPeerResolutionPolicy.resolveSessionSource(
            peerContext: peerContext,
            authenticatedSources: selectionSources
        ) else {
            logger.error(
                """
                ❌ 无法解析文件传输安全会话: \
                authenticatedConnections=\(authenticatedSources.count, privacy: .public) \
                matchedFallbackBranch=none
                """
            )
            throw FileTransferError.secureSessionRequired
        }
        let resolution = selectedResolution.resolution
        guard let selectedSource = authenticatedSources.first(where: {
            $0.sourceIdentifier == selectedResolution.source.sourceIdentifier
        }) else {
            throw FileTransferError.secureSessionRequired
        }

        let transferKey: SymmetricKey
        var productEvidenceBinding: ClassicTransferSecurityContext.ProductEvidenceBinding?
        switch selectedSource.keyOrigin {
        case .live(let connection, let exactSnapshot):
            transferKey = try connection.deriveClassicFileTransferKey(
                transferId: peerContext.transferId
            )
            if let exactSnapshot,
               Self.symmetricKeyMaterialEquals(
                transferKey,
                exactSnapshot.deriveClassicFileTransferKey(
                    transferId: peerContext.transferId
                )
               ),
               let sessionReference = P2PEvidenceReference.sessionIncarnation(
                sessionID: exactSnapshot.sessionKeys.sessionId,
                transcriptHash: exactSnapshot.sessionKeys.transcriptHash
               ),
               let routeClass = ProductReleaseEvidenceRouteClass.current(
                for: connection.connection
               ) {
                productEvidenceBinding = .init(
                    sessionReference: sessionReference,
                    routeClass: routeClass,
                    handshakeRole: exactSnapshot.sessionKeys.role == .initiator
                        ? .initiator
                        : .responder,
                    negotiatedSuite: exactSnapshot.sessionKeys.negotiatedSuite
                )
            }
        case .snapshot(let snapshot):
            transferKey = snapshot.deriveClassicFileTransferKey(
                transferId: peerContext.transferId
            )
            let exactLiveConnection = authenticatedConnections.first { connection in
                snapshot.sessionId.hasPrefix("p2p-\(connection.id.uuidString)-")
            }
            if let exactLiveConnection,
               let sessionReference = P2PEvidenceReference.sessionIncarnation(
                sessionID: snapshot.sessionKeys.sessionId,
                transcriptHash: snapshot.sessionKeys.transcriptHash
               ),
               let routeClass = ProductReleaseEvidenceRouteClass.current(
                for: exactLiveConnection.connection
               ) {
                productEvidenceBinding = .init(
                    sessionReference: sessionReference,
                    routeClass: routeClass,
                    handshakeRole: snapshot.sessionKeys.role == .initiator
                        ? .initiator
                        : .responder,
                    negotiatedSuite: snapshot.sessionKeys.negotiatedSuite
                )
            }
        }

        logger.info(
            """
            🔐 文件传输安全会话已解析: \
            sourceKind=\(selectedSource.sourceKind.logLabel, privacy: .public) \
            matchedBy=\(resolution.matchedBy.rawValue, privacy: .public)
            """
        )

        return ClassicTransferSecurityContext(
            transferKey: transferKey,
            matchDeviceId: resolution.matchDeviceId,
            resolvedPeerDeviceId: resolution.resolvedPeerDeviceId,
            matchedBy: resolution.matchedBy,
            declaredCandidates: resolution.declaredCandidates,
            endpointCandidates: resolution.endpointCandidates,
            supportsClassicResume: resolution.supportsClassicResume,
            productEvidenceBinding: productEvidenceBinding
        )
    }

    private nonisolated static func symmetricKeyMaterialEquals(
        _ lhs: SymmetricKey,
        _ rhs: SymmetricKey
    ) -> Bool {
        lhs.withUnsafeBytes { lhsBytes in
            rhs.withUnsafeBytes { rhsBytes in
                guard lhsBytes.count == rhsBytes.count else { return false }
                var difference: UInt8 = 0
                for index in lhsBytes.indices {
                    difference |= lhsBytes[index] ^ rhsBytes[index]
                }
                return difference == 0
            }
        }
    }

    private func beginProductFileTransferEvidenceIfPossible(
        for transfer: FileTransfer,
        securityContext: ClassicTransferSecurityContext
    ) {
        guard let binding = securityContext.productEvidenceBinding,
              let transferID = UUID(uuidString: transfer.id) else {
            return
        }
        let transferObjectIdentifier = ObjectIdentifier(transfer)
        if productFileTransferEvidenceContext?.transferObjectIdentifier
            == transferObjectIdentifier {
            return
        }
        retireCurrentProductFileTransferEvidence(reason: .sessionReplaced)

        guard let owner = ProductReleaseEvidenceRecorder.shared.beginSession(
            product: .macOSApp,
            transport: .p2p,
            sessionReference: binding.sessionReference,
            routeClass: binding.routeClass
        ) else {
            return
        }
        guard ProductReleaseEvidenceRecorder.shared.recordP2PSessionAuthenticated(
            owner: owner,
            role: binding.handshakeRole,
            negotiatedSuite: binding.negotiatedSuite
        ) else {
            _ = ProductReleaseEvidenceRecorder.shared.endSession(
                owner: owner,
                reason: .protocolFailure
            )
            return
        }
        let transferReference = P2PEvidenceReference.transaction(transferID)
        let direction: ProductReleaseEvidenceFileDirection = switch transfer.direction {
        case .outgoing: .send
        case .incoming: .receive
        }
        guard ProductReleaseEvidenceRecorder.shared.recordFileTransferStarted(
            owner: owner,
            transferReference: transferReference,
            direction: direction
        ) else {
            _ = ProductReleaseEvidenceRecorder.shared.endSession(
                owner: owner,
                reason: .protocolFailure
            )
            return
        }
        productFileTransferEvidenceContext = ProductFileTransferEvidenceContext(
            transferObjectIdentifier: transferObjectIdentifier,
            owner: owner,
            transferReference: transferReference,
            direction: direction
        )
    }

    private func retireProductFileTransferEvidence(
        for transfer: FileTransfer,
        reason: ProductReleaseEvidenceDisconnectReason
    ) {
        guard productFileTransferEvidenceContext?.transferObjectIdentifier
            == ObjectIdentifier(transfer) else {
            return
        }
        retireCurrentProductFileTransferEvidence(reason: reason)
    }

    private func retireCurrentProductFileTransferEvidence(
        reason: ProductReleaseEvidenceDisconnectReason
    ) {
        guard let context = productFileTransferEvidenceContext else { return }
        productFileTransferEvidenceContext = nil
        _ = ProductReleaseEvidenceRecorder.shared.endSession(
            owner: context.owner,
            reason: reason
        )
    }

    /// Called by the normal SwiftUI transfer row after a completed transfer is
    /// actually mounted. The manager revalidates exact object ownership and
    /// terminal success before allowing the visible UI effect to be recorded.
    @discardableResult
    public func recordProductFileTransferCompletionVisible(
        for transfer: FileTransfer
    ) -> Bool {
        guard let context = productFileTransferEvidenceContext,
              context.transferObjectIdentifier == ObjectIdentifier(transfer),
              transfer.status == .completed,
              transfer.completedAt != nil,
              transfer.error == nil,
              transfer.progress == 1,
              activeTransfers[transfer.id] === transfer
                || transferHistory.contains(where: { $0 === transfer }) else {
            return false
        }
        let recorded = ProductReleaseEvidenceRecorder.shared.recordFileTransferCompleted(
            owner: context.owner,
            transferReference: context.transferReference,
            direction: context.direction,
            uiEffectVisible: true
        )
        productFileTransferEvidenceContext = nil
        _ = ProductReleaseEvidenceRecorder.shared.endSession(
            owner: context.owner,
            reason: context.direction == .send ? .user : .peer
        )
        return recorded
    }

    @available(macOS 14.0, iOS 17.0, *)
    nonisolated static func classicTransferAuthenticatedPeerCandidate(
        for connection: P2PConnection
    ) -> ClassicTransferAuthenticatedPeerCandidate {
        return ClassicTransferAuthenticatedPeerCandidate(
            matchDeviceId: connection.classicTransferMatchDeviceId(),
            resolvedPeerDeviceId: connection.classicTransferResolvedPeerDeviceId(),
            aliases: ClassicTransferPeerResolutionPolicy.normalizedLookupCandidates(
                connection.classicTransferPeerLookupAliases()
            ),
            endpointHostOrIP: connection.classicTransferEndpointHostOrIP(),
            capabilities: connection.classicTransferCapabilities()
        )
    }

    @available(macOS 14.0, iOS 17.0, *)
    nonisolated static func classicTransferAuthenticatedPeerCandidate(
        for snapshot: ClassicTransferSessionSnapshot
    ) -> ClassicTransferAuthenticatedPeerCandidate {
        ClassicTransferAuthenticatedPeerCandidate(
            matchDeviceId: snapshot.matchDeviceId,
            resolvedPeerDeviceId: snapshot.resolvedPeerDeviceId,
            aliases: snapshot.aliases,
            endpointHostOrIP: snapshot.endpointHostOrIP,
            capabilities: snapshot.capabilities
        )
    }

    func shouldAttemptAutomaticOutgoingResume(
        peerSupportsResume: Bool,
        transferStatus: TransferStatus,
        transferredBytes: Int64,
        fileSize: Int64,
        error: Error
    ) -> Bool {
        ClassicTransferAutomaticResumePolicy.shouldAttempt(
            isEnabled: automaticResumeEnabled,
            peerSupportsResume: peerSupportsResume,
            transferStatus: transferStatus,
            transferredBytes: transferredBytes,
            fileSize: fileSize,
            error: error
        )
    }

    private func shouldPreserveInboundPartial(for error: Error, receivedBytes: Int64) -> Bool {
        ClassicTransferRecoverableDisconnectPolicy.shouldPreserveInboundPartial(
            receivedBytes: receivedBytes,
            after: error
        )
    }

    private func normalizedClassicOperationError(
        _ error: Error,
        for transfer: FileTransfer
    ) -> Error {
        ClassicTransferControlIntentPolicy.normalized(
            error,
            status: transfer.status,
            controlFailure: transfer.classicControlFailure
        )
    }

    private func isTransferCancellation(_ error: Error) -> Bool {
        guard let transferError = error as? FileTransferError else {
            return error is CancellationError
        }
        if case .transferCancelled = transferError {
            return true
        }
        return false
    }

    /// Sends a file to the currently active P2P peer.
    /// This resolves the peer from ConnectionPresenceService (Authenticated) or P2PConnectionService (UDP) as fallback.
    public func sendFileToFirstActivePeer(at url: URL) async throws {
        if let localServiceHealthCheck {
            try await localServiceHealthCheck()
        }

        let routes = try await resolveActivePeerRoutesWithReadinessWait()
        guard !routes.isEmpty else {
            throw await routeAvailabilityError()
        }

        try await sendFile(at: url, over: routes)
    }

    /// Sends a file to a specific active P2P peer, instead of whichever active route happens to sort first.
    public func sendFileToActivePeer(
        at url: URL,
        matchingPeerIds peerIds: [String],
        preferredDeviceName: String? = nil
    ) async throws {
        if let localServiceHealthCheck {
            try await localServiceHealthCheck()
        }

        let routes = try await resolveActivePeerRoutesWithReadinessWait(
            matchingPeerIds: peerIds,
            preferredDeviceName: preferredDeviceName
        )
        guard !routes.isEmpty else {
            throw await routeAvailabilityError(
                matchingPeerIds: peerIds
            )
        }

        try await sendFile(at: url, over: routes)
    }

    public struct ActivePeerRoute: Sendable, Equatable {
        public let deviceId: String
        public let deviceName: String
        public let ipAddress: String
        public let port: Int
        public let routeSource: String
        public let liveEndpoint: NWEndpoint?

        public init(
            deviceId: String,
            deviceName: String,
            ipAddress: String,
            port: Int,
            routeSource: String,
            liveEndpoint: NWEndpoint? = nil
        ) {
            self.deviceId = deviceId
            self.deviceName = deviceName
            self.ipAddress = ipAddress
            self.port = port
            self.routeSource = routeSource
            self.liveEndpoint = liveEndpoint
        }
    }

    nonisolated static func activeRouteSourcePriority(_ routeSource: String) -> Int {
        switch routeSource {
        case "live-bonjour-transfer":
            return 0
        case "authenticated-session":
            return 1
        case "recent-authenticated-inbound-transfer":
            return 2
        case "classic-session-registry":
            return 3
        case "presence:outbound":
            return 4
        case "presence:inbound":
            return 5
        case "unified":
            return 6
        default:
            return 7
        }
    }

    nonisolated static func sortedActivePeerRoutes(_ routes: [ActivePeerRoute]) -> [ActivePeerRoute] {
        routes.sorted { lhs, rhs in
            let lhsPriority = activeRouteSourcePriority(lhs.routeSource)
            let rhsPriority = activeRouteSourcePriority(rhs.routeSource)
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            if lhs.deviceId != rhs.deviceId {
                return lhs.deviceId.localizedCaseInsensitiveCompare(rhs.deviceId) == .orderedAscending
            }
            if lhs.ipAddress != rhs.ipAddress {
                return lhs.ipAddress.localizedCaseInsensitiveCompare(rhs.ipAddress) == .orderedAscending
            }
            return lhs.port < rhs.port
        }
    }

    nonisolated static func deduplicatedActivePeerRoutes(_ routes: [ActivePeerRoute]) -> [ActivePeerRoute] {
        var selectedIndexByEndpoint: [String: Int] = [:]
        var selectedRoutes: [ActivePeerRoute] = []

        for route in routes {
            let endpointKey = route.liveEndpoint?.debugDescription
                ?? "\(route.ipAddress.lowercased()):\(route.port)"
            let key = "\(route.deviceId.lowercased())|\(endpointKey)"
            if let existingIndex = selectedIndexByEndpoint[key] {
                let existing = selectedRoutes[existingIndex]
                if activeRouteSourcePriority(route.routeSource) < activeRouteSourcePriority(existing.routeSource) {
                    selectedRoutes[existingIndex] = route
                }
                continue
            }

            selectedIndexByEndpoint[key] = selectedRoutes.count
            selectedRoutes.append(route)
        }

        return selectedRoutes
    }

    nonisolated static func shouldAwaitLiveTransferRoute(
        routes: [ActivePeerRoute],
        matchingPeerIds targetPeerIds: [String],
        discoveredDevices: [DiscoveredDevice]
    ) -> Bool {
        guard !routes.contains(where: { $0.liveEndpoint != nil }) else {
            return false
        }
        let requestedAliases = normalizedActiveRouteAliases(for: targetPeerIds)
        let targetAliases = requestedAliases.isEmpty
            ? normalizedActiveRouteAliases(for: routes.map(\.deviceId))
            : requestedAliases
        guard !targetAliases.isEmpty else { return false }

        let transferServiceTypes = Set([
            BonjourInteropContract.fileTransferServiceType,
            BonjourInteropContract.legacyFileTransferServiceType
        ])
        return discoveredDevices.contains { device in
            guard !transferServiceTypes.isDisjoint(with: device.services) else {
                return false
            }
            let deviceAliases = normalizedActiveRouteAliases(for: [
                device.deviceId,
                device.uniqueIdentifier,
                device.id.uuidString,
                device.ipv4,
                device.ipv6
            ])
            return !deviceAliases.isDisjoint(with: targetAliases)
        }
    }

    public func resolveActivePeerRoutes(
        matchingPeerIds targetPeerIds: [String] = [],
        preferredDeviceName: String? = nil
    ) async -> [ActivePeerRoute] {
        var routes: [ActivePeerRoute] = []
        #if os(macOS)
        var usedCompatibilityFallback = false
        #endif
        let targetAliases = Self.normalizedActiveRouteAliases(for: targetPeerIds)
        let normalizedPreferredName = Self.normalizedRouteDisplayName(preferredDeviceName)

        func routeAliasMatchesTarget(_ route: ActivePeerRoute) -> Bool {
            guard !targetAliases.isEmpty else { return false }
            let routeAliases = Self.normalizedActiveRouteAliases(for: [
                route.deviceId,
                route.ipAddress
            ])
            return !routeAliases.isDisjoint(with: targetAliases)
        }

        func routeNameMatchesTarget(_ route: ActivePeerRoute) -> Bool {
            !normalizedPreferredName.isEmpty
                && Self.normalizedRouteDisplayName(route.deviceName) == normalizedPreferredName
        }

        func appendRoute(
            deviceId: String,
            deviceName: String,
            address: String?,
            port: Int = 8080,
            routeSource: String,
            liveEndpoint: NWEndpoint? = nil
        ) {
            let sanitizedAddress = sanitizeAddress(address)
            guard sanitizedAddress != nil || liveEndpoint != nil else { return }
            guard (1...65535).contains(port) else { return }
            routes.append(
                ActivePeerRoute(
                    deviceId: deviceId,
                    deviceName: deviceName.isEmpty ? "P2P Device" : deviceName,
                    ipAddress: sanitizedAddress
                        ?? liveEndpoint?.debugDescription
                        ?? "bonjour-service",
                    port: port,
                    routeSource: routeSource,
                    liveEndpoint: liveEndpoint
                )
            )
        }

        let routeDescriptors = ConnectionPresenceService.shared.activeRouteDescriptors()
        for route in routeDescriptors {
            appendRoute(
                deviceId: route.peerId,
                deviceName: route.deviceName,
                address: route.transferAddress,
                port: route.transferPort,
                routeSource: "presence:\(route.routeSource.rawValue)"
            )
        }

        func appendAuthenticatedRoute(
            from candidate: ClassicTransferAuthenticatedPeerCandidate,
            routeSource: String
        ) {
            let endpointAddress = sanitizeAddress(candidate.endpointHostOrIP)
            let resolved = P2PDiscoveryService.resolveInboundPresenceRoute(
                peerId: candidate.resolvedPeerDeviceId,
                endpointLabel: endpointAddress.map { "host:\($0)" } ?? candidate.matchDeviceId,
                discoveredDevices: P2PDiscoveryService.shared.discoveredDevices,
                unifiedDevices: UnifiedOnlineDeviceSnapshotAccess.snapshot()
            )
            let resolvedPort = ClassicTransferPeerResolutionPolicy.advertisedClassicTransferPort(in: candidate.capabilities)
                ?? (resolved.transferPort > 0 ? resolved.transferPort : nil)
            let peerCandidates = [
                candidate.resolvedPeerDeviceId,
                candidate.matchDeviceId
            ] + candidate.aliases
            for endpoint in P2PDiscoveryService.shared
                .liveFileTransferEndpointAttempts(
                    forPeerDeviceIds: peerCandidates
                ) {
                appendRoute(
                    deviceId: candidate.resolvedPeerDeviceId,
                    deviceName: resolved.name.isEmpty ? "P2P Device" : resolved.name,
                    address: resolved.displayAddress ?? endpointAddress,
                    port: resolvedPort ?? Self.defaultClassicTransferPort,
                    routeSource: "live-bonjour-transfer",
                    liveEndpoint: endpoint
                )
            }
            guard let resolvedPort else { return }
            appendRoute(
                deviceId: candidate.resolvedPeerDeviceId,
                deviceName: resolved.name.isEmpty ? "P2P Device" : resolved.name,
                address: resolved.displayAddress ?? endpointAddress,
                port: resolvedPort,
                routeSource: routeSource
            )
        }

        let primaryAuthenticated = Array(P2PNetworkManager.shared.activeConnections.values)
        let discoveryAuthenticated = P2PDiscoveryService.shared.activeAuthenticatedConnectionsForClassicTransfer()
        let registryConnections = await ClassicTransferSessionRegistry.shared.activeConnections()
        var seenConnections = Set<ObjectIdentifier>()
        for connection in primaryAuthenticated + discoveryAuthenticated + registryConnections
            where connection.status == .authenticated {
            guard seenConnections.insert(ObjectIdentifier(connection)).inserted else { continue }
            appendAuthenticatedRoute(
                from: Self.classicTransferAuthenticatedPeerCandidate(for: connection),
                routeSource: "authenticated-session"
            )
        }

        let registrySessions = await ClassicTransferSessionRegistry.shared.activeSessions()
        for snapshot in registrySessions {
            appendAuthenticatedRoute(
                from: Self.classicTransferAuthenticatedPeerCandidate(for: snapshot),
                routeSource: "classic-session-registry"
            )
        }

        let recentInboundCutoff = Date().addingTimeInterval(-Self.recentInboundTransferRouteTTL)
        let recentIncomingTransfers = (Array(activeTransfers.values) + transferHistory)
            .filter { transfer in
                transfer.direction == .incoming
                    && transfer.status == .completed
                    && (transfer.completedAt ?? transfer.createdAt) >= recentInboundCutoff
            }
        for transfer in recentIncomingTransfers {
            appendRoute(
                deviceId: transfer.deviceId,
                deviceName: transfer.deviceName ?? "P2P Device",
                address: transfer.deviceIPAddress,
                port: transfer.devicePort,
                routeSource: "recent-authenticated-inbound-transfer"
            )
        }

        #if os(macOS)
        if #available(macOS 14.0, *) {
            let connectedDevices = UnifiedOnlineDeviceSnapshotAccess.snapshot()
                .filter { !$0.isLocalDevice && $0.connectionStatus == .connected }
                .sorted { ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast) }
            for device in connectedDevices {
                guard let transferPort = device.portMap[BonjourInteropContract.fileTransferServiceType]
                        ?? device.portMap[BonjourInteropContract.legacyFileTransferServiceType],
                      (1...65535).contains(transferPort) else {
                    continue
                }
                usedCompatibilityFallback = true
                appendRoute(
                    deviceId: device.uniqueIdentifier,
                    deviceName: device.name,
                    address: device.ipv4 ?? device.ipv6,
                    port: transferPort,
                    routeSource: "unified"
                )
            }
        }
        #endif

        #if os(macOS)
        if usedCompatibilityFallback, !routeDescriptors.isEmpty {
            logger.warning("⚠️ 文件传输路由解析回退到兼容路径；首选应来自 PresenceRouteDescriptor")
        }
        #endif

        let deduplicatedRoutes = Self.deduplicatedActivePeerRoutes(routes)
        guard !targetAliases.isEmpty || !normalizedPreferredName.isEmpty else {
            return Self.sortedActivePeerRoutes(deduplicatedRoutes)
        }

        let aliasMatches = deduplicatedRoutes.filter(routeAliasMatchesTarget)
        if !aliasMatches.isEmpty {
            return Self.sortedActivePeerRoutes(aliasMatches)
        }

        if !targetAliases.isEmpty {
            logger.warning("⚠️ 指定 peer id 的文件传输路由未命中强身份，拒绝使用同名路由兜底")
            return []
        }

        return Self.sortedActivePeerRoutes(deduplicatedRoutes.filter(routeNameMatchesTarget))
    }

    private func resolveActivePeerRoutesWithReadinessWait(
        matchingPeerIds targetPeerIds: [String] = [],
        preferredDeviceName: String? = nil
    ) async throws -> [ActivePeerRoute] {
        let deadline = Date().addingTimeInterval(activeRouteReadinessTimeoutSeconds)
        var lastRoutes: [ActivePeerRoute] = []

        repeat {
            let routes = await resolveActivePeerRoutes(
                matchingPeerIds: targetPeerIds,
                preferredDeviceName: preferredDeviceName
            )
            lastRoutes = routes
            let shouldAwaitLiveRoute = Self.shouldAwaitLiveTransferRoute(
                routes: routes,
                matchingPeerIds: targetPeerIds,
                discoveredDevices: P2PDiscoveryService.shared.discoveredDevices
            )
            if !routes.isEmpty, !shouldAwaitLiveRoute {
                return routes
            }
            try await Task.sleep(for: .seconds(activeRouteReadinessPollIntervalSeconds))
        } while Date() < deadline

        return lastRoutes
    }

    private func routeAvailabilityError(
        matchingPeerIds targetPeerIds: [String] = []
    ) async -> FileTransferRouteAvailabilityError {
        let targetAliases = Self.normalizedActiveRouteAliases(
            for: targetPeerIds
        )
        let liveConnections =
            Array(P2PNetworkManager.shared.activeConnections.values)
                + P2PDiscoveryService.shared
                    .activeAuthenticatedConnectionsForClassicTransfer()
                + (await ClassicTransferSessionRegistry.shared.activeConnections())
        let liveCandidates = liveConnections
            .filter { $0.status == .authenticated }
            .map(Self.classicTransferAuthenticatedPeerCandidate(for:))
        let snapshotCandidates = await ClassicTransferSessionRegistry.shared
            .activeSessions()
            .map(Self.classicTransferAuthenticatedPeerCandidate(for:))
        let candidates = liveCandidates + snapshotCandidates

        let hasMatchingAuthenticatedPeer: Bool
        if targetAliases.isEmpty {
            hasMatchingAuthenticatedPeer = !candidates.isEmpty
        } else {
            hasMatchingAuthenticatedPeer = candidates.contains { candidate in
                let aliases = Self.normalizedActiveRouteAliases(
                    for: [
                        candidate.matchDeviceId,
                        candidate.resolvedPeerDeviceId,
                        candidate.endpointHostOrIP
                    ].compactMap { $0 } + candidate.aliases
                )
                return !aliases.isDisjoint(with: targetAliases)
            }
        }
        return hasMatchingAuthenticatedPeer
            ? .noLiveTransferRoute
            : .noAuthenticatedPeer
    }

    private func sendFile(at url: URL, over routes: [ActivePeerRoute]) async throws {
        guard ClassicTransferRouteRetryPolicy.hasSingleTarget(
            deviceIDs: routes.map(\.deviceId)
        ) else {
            throw FileTransferError.ambiguousTarget
        }

        var lastConnectionError: Error?
        for route in routes {
            do {
                logger.info(
                    "📡 尝试活跃会话文件路由: source=\(route.routeSource, privacy: .public)"
                )
                try await sendFileInternal(
                    at: url,
                    to: route.deviceId,
                    deviceName: route.deviceName,
                    ipAddress: route.ipAddress,
                    port: route.port,
                    liveEndpoint: route.liveEndpoint,
                    wrapRetryableConnectionFailure: routes.count > 1
                )
                return
            } catch let retryError as RetryableActiveRouteConnectionError {
                lastConnectionError = retryError.underlying
                let routeError = retryError.underlying as NSError
                logger.warning(
                    "⚠️ 活跃会话端点建连失败，尝试同一设备的下一端点: source=\(route.routeSource, privacy: .public) domain=\(routeError.domain, privacy: .private) code=\(routeError.code, privacy: .public)"
                )
            }
        }

        throw lastConnectionError ?? NSError(
            domain: "SkyBridge.FileTransfer",
            code: -1003,
            userInfo: [NSLocalizedDescriptionKey: "已发现活跃连接，但无法解析可用传输路由"]
        )
    }

    nonisolated static func normalizedActiveRouteAliases(for values: [String?]) -> Set<String> {
        var aliases = Set<String>()
        for value in values {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else {
                continue
            }
            aliases.insert(trimmed.lowercased())
            for candidate in PeerTrustLookup.lookupCandidates(for: trimmed) {
                let normalized = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !normalized.isEmpty else { continue }
                aliases.insert(normalized)
            }
        }
        return aliases
    }

    nonisolated static func normalizedRouteDisplayName(_ raw: String?) -> String {
        raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "") ?? ""
    }

    private func parseAddressFromEndpoint(_ endpoint: NWEndpoint?) -> String? {
        guard let endpoint else { return nil }
        guard case .hostPort(let host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let ipv4):
            return "\(ipv4)"
        case .ipv6(let ipv6):
            return "\(ipv6)"
        case .name(let name, _):
            return name
        @unknown default:
            return nil
        }
    }

    private func parseAddressFromPeerId(_ peerId: String) -> String? {
        guard peerId.hasPrefix("peer:") else { return nil }
        return sanitizeAddress(String(peerId.dropFirst("peer:".count)))
    }

    private func sanitizeAddress(_ raw: String?) -> String? {
        guard var token = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            return nil
        }

        if token.hasPrefix("host:") {
            token = String(token.dropFirst("host:".count))
        } else if token.hasPrefix("peer:") {
            token = String(token.dropFirst("peer:".count))
        } else if token.hasPrefix("ip:") {
            token = String(token.dropFirst("ip:".count))
        }

        if token.hasPrefix("[") && token.hasSuffix("]") {
            token = String(token.dropFirst().dropLast())
        }
        if token.contains(":"),
           let dot = token.lastIndex(of: "."),
           token[token.index(after: dot)...].allSatisfy({ $0.isNumber }) {
            token = String(token[..<dot])
        } else {
            let parts = token.split(separator: ".")
            if parts.count == 5,
               parts.dropLast().allSatisfy({ Int($0) != nil }),
               let port = Int(parts.last ?? ""),
               (0...65535).contains(port) {
                token = parts.dropLast().map(String.init).joined(separator: ".")
            }
        }

        let sanitized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? nil : sanitized
    }

    /// 发送文件到指定设备
    public func sendFile(at url: URL, to deviceId: String, deviceName: String, ipAddress: String, port: Int = 8080) async throws {
        try await sendFileInternal(
            at: url,
            to: deviceId,
            deviceName: deviceName,
            ipAddress: ipAddress,
            port: port,
            liveEndpoint: nil,
            wrapRetryableConnectionFailure: false
        )
    }

    private func sendFileInternal(
        at url: URL,
        to deviceId: String,
        deviceName: String,
        ipAddress: String,
        port: Int,
        liveEndpoint: NWEndpoint?,
        wrapRetryableConnectionFailure: Bool
    ) async throws {
        guard (1...65535).contains(port) else {
            throw FileTransferError.invalidPort
        }
        let operationID = beginClassicOperation()
        defer { endClassicOperation(operationID) }
        let transferLifecycleGeneration = try await acquireTransferSlot()
        defer { releaseTransferSlot() }
        logger.info("📤 开始发送文件")

        if let localServiceHealthCheck {
            try await localServiceHealthCheck()
            try ensureCurrentLifecycle(transferLifecycleGeneration)
        }

 // 获取文件信息
        let fileSize = try await getFileSize(at: url)
        try ensureCurrentLifecycle(transferLifecycleGeneration)
        let fileName = url.lastPathComponent
        let negotiatedChunkSize = chunkSize
        let negotiatedCompression = compressionEnabled ? "zlib" : nil

 // 创建传输记录
        let transfer = FileTransfer(
            id: UUID().uuidString,
            fileName: fileName,
            fileSize: fileSize,
            deviceId: deviceId,
            direction: .outgoing,
            status: .preparing
        )

        transfer.localPath = url
        transfer.negotiatedClassicChunkSize = negotiatedChunkSize
        transfer.compression = negotiatedCompression
        transfer.deviceIPAddress = ipAddress
        transfer.devicePort = port
        transfer.deviceName = deviceName
        registerActiveTransfer(transfer)
        var didStartNetworkTransfer = false

        do {
            guard #available(macOS 14.0, iOS 17.0, *) else {
                throw FileTransferError.secureSessionRequired
            }
            let securityContext = try await classicTransferSecurityContext(
                peerContext: FileTransferPeerContext(
                    declaredSenderDeviceId: deviceId,
                    endpointHostOrIP: ipAddress,
                    peerLabel: deviceName,
                    transferId: transfer.id
                )
            )
            try ensureCurrentLifecycle(transferLifecycleGeneration)

            do {
                let connection: NWConnection
                do {
                    if let liveEndpoint {
                        connection = try await networkService.connectToDevice(
                            endpoint: liveEndpoint,
                            deviceId: deviceId,
                            deviceName: deviceName
                        )
                    } else {
                        connection = try await networkService.connectToDevice(
                            ipAddress: ipAddress,
                            port: port,
                            deviceId: deviceId,
                            deviceName: deviceName
                        )
                    }
                } catch {
                    try ensureCurrentLifecycle(transferLifecycleGeneration)
                    if wrapRetryableConnectionFailure,
                       ClassicTransferRouteRetryPolicy.shouldTryNextRoute(after: error) {
                        throw RetryableActiveRouteConnectionError(underlying: error)
                    }
                    throw error
                }
                do {
                    try ensureCurrentLifecycle(transferLifecycleGeneration)
                } catch {
                    networkService.disconnect(connection)
                    throw error
                }
                didStartNetworkTransfer = true
                lastTransferActivityAt = Date()
                bindClassicConnection(connection, to: transfer.id)
                defer {
                    unbindClassicConnection(connection, from: transfer.id)
                    networkService.disconnect(connection)
                }

                transfer.fileHash = try await calculateFileHash(at: url)
                try ensureCurrentLifecycle(transferLifecycleGeneration)
                try await sendFileMetadata(
                    transfer,
                    negotiatedChunkSize: negotiatedChunkSize,
                    negotiatedCompression: negotiatedCompression,
                    securityContext: securityContext,
                    to: connection
                )
                try ensureCurrentLifecycle(transferLifecycleGeneration)
                beginProductFileTransferEvidenceIfPossible(
                    for: transfer,
                    securityContext: securityContext
                )
                try await sendFileInChunks(
                    from: url,
                    transfer: transfer,
                    negotiatedChunkSize: negotiatedChunkSize,
                    negotiatedCompression: negotiatedCompression,
                    securityContext: securityContext,
                    to: connection
                )
                try ensureCurrentLifecycle(transferLifecycleGeneration)

                let receipt = try await waitForTransferReceipt(
                    from: connection,
                    securityContext: securityContext,
                    expectedTransferId: transfer.id,
                    expectedFileSize: fileSize,
                    expectedFileHash: transfer.fileHash
                )
                try ensureCurrentLifecycle(transferLifecycleGeneration)
                logger.info("✅ 接收端已确认落盘: bytes=\(receipt.receivedBytes, privacy: .public)")
                try await cleanupResumeStateIfPresent(for: transfer)
                try ensureCurrentLifecycle(transferLifecycleGeneration)

                transfer.status = .completed
                transfer.classicControlFailure = nil
                transfer.completedAt = Date()
                transfer.progress = 1.0
                logger.info("✅ 文件发送完成")
                lastTransferActivityAt = Date()
                NotificationCenter.default.post(
                    name: Notification.Name("FileTransferCompleted"),
                    object: nil,
                    userInfo: [
                        "transferId": transfer.id,
                        "fileName": fileName,
                        "fileSize": fileSize,
                        "deviceName": deviceName,
                        "direction": "outgoing",
                        "localPath": url.path
                    ]
                )
            } catch let retryError as RetryableActiveRouteConnectionError {
                throw retryError
            } catch {
                let initialTransferError = normalizedClassicOperationError(error, for: transfer)
                var terminalTransferError: Error
                if transfer.transferredBytes >= fileSize,
                   ClassicTransferRouteRetryPolicy.deliveryConfirmationIsUnknown(
                    after: initialTransferError
                   ) {
                    terminalTransferError = FileTransferError.deliveryConfirmationUnknown
                } else {
                    terminalTransferError = initialTransferError
                }

                if shouldAttemptAutomaticOutgoingResume(
                    peerSupportsResume: securityContext.supportsClassicResume,
                    transferStatus: transfer.status,
                    transferredBytes: transfer.transferredBytes,
                    fileSize: fileSize,
                    error: initialTransferError
                ) {
                    transfer.resumeOffset = transfer.transferredBytes
                    do {
                        try await saveResumeData(
                            for: transfer,
                            declaredChunkSize: negotiatedChunkSize
                        )
                        try await continueSendingFile(
                            transfer,
                            negotiatedChunkSize: negotiatedChunkSize,
                            negotiatedCompression: negotiatedCompression,
                            securityContext: securityContext,
                            lifecycleGeneration: transferLifecycleGeneration
                        )
                        lastTransferActivityAt = Date()
                        NotificationCenter.default.post(
                            name: Notification.Name("FileTransferCompleted"),
                            object: nil,
                            userInfo: [
                                "transferId": transfer.id,
                                "fileName": fileName,
                                "fileSize": fileSize,
                                "deviceName": deviceName,
                                "direction": "outgoing",
                                "localPath": url.path
                            ]
                        )
                        moveToHistory(transfer)
                        updateTransferringStatus()
                        return
                    } catch {
                        let resumeError = normalizedClassicOperationError(error, for: transfer)
                        if transfer.transferredBytes >= fileSize,
                                  ClassicTransferRouteRetryPolicy.deliveryConfirmationIsUnknown(
                                    after: resumeError
                                  ) {
                            terminalTransferError = FileTransferError.deliveryConfirmationUnknown
                        } else {
                            terminalTransferError = resumeError
                        }
                        let resumeNSError = resumeError as NSError
                        logger.error(
                            "❌ 文件自动续传失败: domain=\(resumeNSError.domain, privacy: .private) code=\(resumeNSError.code, privacy: .public)"
                        )
                    }
                }
                throw terminalTransferError
            }
        } catch let retryError as RetryableActiveRouteConnectionError {
            if activeTransfers[transfer.id] === transfer {
                activeTransfers.removeValue(forKey: transfer.id)
            }
            updateTransferPowerAssertion()
            updateTransferringStatus()
            throw retryError
        } catch {
            var terminalTransferError = normalizedClassicOperationError(error, for: transfer)
            if case FileTransferError.deliveryConfirmationUnknown = terminalTransferError {
                transfer.receiptDeliveryStatus = .unknown
            }
            if let cleanupError = await terminalResumeRecordCleanupErrorIfNeeded(
                for: transfer,
                recordWasLoadedBeforeOperation: false,
                preservingFreshRecoverableState: false
            ) {
                terminalTransferError = cleanupError
            }
            if isTransferCancellation(terminalTransferError) {
                transfer.status = .cancelled
            } else {
                transfer.status = .failed
            }
            transfer.completedAt = Date()
            transfer.error = terminalTransferError.localizedDescription
            retireProductFileTransferEvidence(
                for: transfer,
                reason: isTransferCancellation(terminalTransferError)
                    ? .user
                    : .protocolFailure
            )
            logger.error("❌ 文件发送失败")
            if didStartNetworkTransfer {
                lastTransferActivityAt = Date()
            }

            let shouldPublishFailure = activeTransfers[transfer.id] === transfer
                && isCurrentLifecycle(transferLifecycleGeneration)
            if shouldPublishFailure {
                NotificationCenter.default.post(
                    name: Notification.Name("FileTransferFailed"),
                    object: nil,
                    userInfo: [
                        "transferId": transfer.id,
                        "fileName": fileName,
                        "error": terminalTransferError.localizedDescription,
                        "deviceName": deviceName
                    ]
                )
            }

            moveToHistory(transfer)
            updateTransferringStatus()
            throw terminalTransferError
        }

        moveToHistory(transfer)
        updateTransferringStatus()
    }

    /// 接收文件
    func receiveFile(from connection: NWConnection, peerContext: FileTransferPeerContext) async throws {
        guard acceptsNewTransfers else {
            connection.cancel()
            throw FileTransferError.transferCancelled
        }
        let operationID = beginClassicOperation()
        defer { endClassicOperation(operationID) }
        let connectionLifecycleGeneration = lifecycleGeneration
        let pendingConnectionID = ObjectIdentifier(connection)
        guard pendingClassicConnections[pendingConnectionID] == nil else {
            connection.cancel()
            throw FileTransferError.invalidTransferState
        }
        pendingClassicConnections[pendingConnectionID] = connection
        defer {
            if pendingClassicConnections[pendingConnectionID] === connection {
                pendingClassicConnections.removeValue(forKey: pendingConnectionID)
            }
        }
        logger.info("📥 开始接收文件")

        do {
            let initialMessage = try await receiveInitialTransferMessage(from: connection)
            try ensureCurrentLifecycle(connectionLifecycleGeneration)
            switch initialMessage {
            case .resume(let request):
                try await handleResumeRequest(
                    request,
                    from: connection,
                    lifecycleGeneration: connectionLifecycleGeneration
                )
                updateTransferringStatus()
                return
            case .metadata(let metadata):
                try await receiveIncomingTransfer(
                    metadata: metadata,
                    from: connection,
                    peerContext: peerContext.updating(
                        declaredSenderDeviceId: metadata.senderDeviceId,
                        transferId: metadata.transferId
                    ),
                    lifecycleGeneration: connectionLifecycleGeneration
                )
                updateTransferringStatus()
                return
            }
        } catch FileTransferError.inboundConnectionClosedBeforeMetadata {
            let error = FileTransferError.inboundConnectionClosedBeforeMetadata
            guard isCurrentLifecycle(connectionLifecycleGeneration) else {
                throw ClassicTransferControlIntentPolicy.normalized(
                    error,
                    status: .cancelled,
                    controlFailure: FileTransferError.transferCancelled
                )
            }
            logger.info("📥 inbound file-transfer connection closed before metadata")
            lastTransferActivityAt = Date()
            updateTransferringStatus()
            throw FileTransferError.inboundConnectionClosedBeforeMetadata
        } catch FileTransferError.inboundInvalidInitialHeader {
            let error = FileTransferError.inboundInvalidInitialHeader
            guard isCurrentLifecycle(connectionLifecycleGeneration) else {
                throw ClassicTransferControlIntentPolicy.normalized(
                    error,
                    status: .cancelled,
                    controlFailure: FileTransferError.transferCancelled
                )
            }
            logger.info("📥 inbound file-transfer connection rejected before metadata: invalid initial header")
            lastTransferActivityAt = Date()
            updateTransferringStatus()
            throw FileTransferError.inboundInvalidInitialHeader
        } catch {
            guard isCurrentLifecycle(connectionLifecycleGeneration) else {
                throw ClassicTransferControlIntentPolicy.normalized(
                    error,
                    status: .cancelled,
                    controlFailure: FileTransferError.transferCancelled
                )
            }
            let receiveError = error as NSError
            logger.error(
                "❌ 文件接收失败: domain=\(receiveError.domain, privacy: .private) code=\(receiveError.code, privacy: .public)"
            )
            lastTransferActivityAt = Date()
            updateTransferringStatus()
            throw error
        }
    }

    private func receiveIncomingTransfer(
        metadata: FileMetadata,
        from connection: NWConnection,
        peerContext: FileTransferPeerContext,
        lifecycleGeneration: UUID
    ) async throws {
        RemoteControlSmokeStatusWriter.append(
            """
            file-transfer metadata-received transfer=\(Self.sanitizeSmokeField(metadata.transferId)) \
            sender=\(Self.sanitizeSmokeField(metadata.senderDeviceId ?? "-")) \
            name=\(Self.sanitizeSmokeField(metadata.fileName)) bytes=\(metadata.fileSize)
            """
        )
        guard #available(macOS 14.0, iOS 17.0, *) else {
            throw FileTransferError.secureSessionRequired
        }
        do {
            try ClassicTransferMetadataContract.validateSecurityVersion(metadata.securityVersion)
            try await ClassicTransferJSONWorker.shared.validateMetadata(
                transferID: metadata.transferId,
                fileName: metadata.fileName,
                fileSize: metadata.fileSize,
                fileHash: metadata.fileHash,
                declaredChunkSize: metadata.chunkSize,
                compression: metadata.compression,
                displayFields: [
                    metadata.senderDeviceId,
                    metadata.senderDeviceName,
                    metadata.senderPlatform,
                    metadata.senderOSVersion,
                    metadata.senderModelName,
                    metadata.senderChip
                ]
            )
        } catch is CancellationError {
            throw FileTransferError.transferCancelled
        } catch {
            throw FileTransferError.invalidHeader
        }

        let resolvedSecurityContext: ClassicTransferSecurityContext
        do {
            resolvedSecurityContext = try await classicTransferSecurityContext(peerContext: peerContext)
        } catch {
            logger.error("⚠️ failure receipt 未发送: reason=no_security_context")
            RemoteControlSmokeStatusWriter.append(
                """
                failed stage=file-transfer phase=no_security_context \
                transfer=\(Self.sanitizeSmokeField(metadata.transferId)) \
                sender=\(Self.sanitizeSmokeField(peerContext.declaredSenderDeviceId ?? "-")) \
                endpoint=\(Self.sanitizeSmokeField(peerContext.endpointHostOrIP ?? "-")) \
                detail=\(Self.sanitizeSmokeField(error.localizedDescription))
                """
            )
            throw error
        }
        RemoteControlSmokeStatusWriter.append(
            """
            file-transfer security-context transfer=\(Self.sanitizeSmokeField(metadata.transferId)) \
            matchedBy=\(resolvedSecurityContext.matchedBy.rawValue) \
            peer=\(Self.sanitizeSmokeField(resolvedSecurityContext.resolvedPeerDeviceId))
            """
        )

        guard isValidAuthenticationTag(
            metadata.metadataAuthTag,
            payload: try metadataAuthenticationInput(metadata),
            key: resolvedSecurityContext.transferKey
        ) else {
            let error = FileTransferError.secureSessionRequired
            await sendFailureReceiptIfPossible(
                transferId: metadata.transferId,
                securityVersion: metadata.securityVersion,
                error: error,
                securityContext: resolvedSecurityContext,
                to: connection
            )
            throw error
        }

        let effectiveDeviceId = resolvedSecurityContext.resolvedPeerDeviceId
        let effectiveDeviceName = metadata.senderDeviceName
            ?? peerContext.peerLabel
            ?? peerContext.endpointHostOrIP
            ?? effectiveDeviceId

        // File transfer may surface an ephemeral approval prompt, but must not synthesize
        // empty trust records from unauthenticated self-reported metadata.
        #if os(macOS)
        if #available(macOS 14.0, *) {
            if let declaredId = metadata.senderDeviceId, !declaredId.isEmpty {
                let alreadyTrusted = TrustSyncService.shared.activeTrustRecords.contains { $0.deviceId == declaredId && !$0.isTombstone }
                if !alreadyTrusted {
                    let request = PairingTrustApprovalService.Request(
                        peerEndpoint: effectiveDeviceId,
                        declaredDeviceId: declaredId,
                        displayName: metadata.senderDeviceName ?? effectiveDeviceName,
                        model: metadata.senderModelName,
                        platform: metadata.senderPlatform,
                        osVersion: metadata.senderOSVersion,
                        kemKeyCount: 0
                    )
                    let decision = await PairingTrustApprovalService.shared.decide(for: request)
                    if decision == .reject {
                        let error = FileTransferError.transferCancelled
                        await sendFailureReceiptIfPossible(
                            transferId: metadata.transferId,
                            securityVersion: metadata.securityVersion,
                            error: error,
                            securityContext: resolvedSecurityContext,
                            to: connection
                        )
                        throw error
                    }
                }
            }
        }
        #endif

        try ensureCurrentLifecycle(lifecycleGeneration)
        _ = try await acquireTransferSlot(expectedGeneration: lifecycleGeneration)
        defer { releaseTransferSlot() }
        let destinationDirectory = try await preparedInboundDestinationDirectory()
        try ensureCurrentLifecycle(lifecycleGeneration)
        let stagingURL = try Self.classicInboundPartialURL()
        do {
            try await InboundFileTransferIOActor.shared.validateSameVolumeCommit(
                stagingURL: stagingURL,
                destinationDirectory: destinationDirectory
            )
        } catch {
            await sendFailureReceiptIfPossible(
                transferId: metadata.transferId,
                securityVersion: metadata.securityVersion,
                error: error,
                securityContext: resolvedSecurityContext,
                to: connection
            )
            throw error
        }
        try ensureCurrentLifecycle(lifecycleGeneration)

        guard activeTransfers[metadata.transferId] == nil else {
            let error = FileTransferError.invalidTransferState
            await sendFailureReceiptIfPossible(
                transferId: metadata.transferId,
                securityVersion: metadata.securityVersion,
                error: error,
                securityContext: resolvedSecurityContext,
                to: connection
            )
            throw error
        }

        let transfer = FileTransfer(
            id: metadata.transferId,
            fileName: sanitizeIncomingFileName(metadata.fileName),
            fileSize: metadata.fileSize,
            deviceId: effectiveDeviceId,
            direction: .incoming,
            status: .transferring
        )
        transfer.fileHash = metadata.fileHash
        transfer.compression = metadata.compression
        transfer.negotiatedClassicChunkSize = metadata.chunkSize
        transfer.deviceName = effectiveDeviceName
        if let inboundEndpointAddress = sanitizeAddress(peerContext.endpointHostOrIP) {
            transfer.deviceIPAddress = inboundEndpointAddress
            transfer.devicePort = Self.defaultClassicTransferPort
        }
        registerActiveTransfer(transfer)
        bindClassicConnection(connection, to: transfer.id)
        defer { unbindClassicConnection(connection, from: transfer.id) }
        beginProductFileTransferEvidenceIfPossible(
            for: transfer,
            securityContext: resolvedSecurityContext
        )

        var inboundIOHandle: InboundFileTransferIOHandle?
        var committedURL: URL?
        do {
            let ioHandle = try await InboundFileTransferIOActor.shared.createTemporaryFile(
                at: stagingURL,
                declaredFileSize: metadata.fileSize
            )
            inboundIOHandle = ioHandle
            try ensureCurrentLifecycle(lifecycleGeneration)
            transfer.classicResumeSourcePath = stagingURL
            let receivedDigest = try await receiveFileInChunks(
                transfer: transfer,
                securityContext: resolvedSecurityContext,
                from: connection,
                ioHandle: ioHandle,
                negotiatedChunkSize: metadata.chunkSize
            )
            try ensureCurrentLifecycle(lifecycleGeneration)

            let receivedHash = Self.sha256Hex(receivedDigest)
            guard receivedHash.lowercased() == metadata.fileHash.lowercased() else {
                throw FileTransferError.integrityCheckFailed
            }

            if virusScanEnabled {
                logClassicReceiptPhase("post_receive_scan_started", transferId: transfer.id)
            }
            if let scanResult = await scanReceivedFileIfEnabled(stagingURL) {
                transfer.scanResult = scanResult
                logClassicReceiptPhase("post_receive_scan_completed", transferId: transfer.id)
                if case .block(let reason) = scanResult.automaticTransferAdmission {
                    throw reason.managerError
                }
            } else if virusScanEnabled {
                logClassicReceiptPhase("post_receive_scan_completed", transferId: transfer.id)
            }
            try ensureCurrentLifecycle(lifecycleGeneration)

            try await cleanupResumeStateIfPresent(for: transfer)
            try ensureCurrentLifecycle(lifecycleGeneration)

            let receivePath = try await InboundFileTransferIOActor.shared.commit(
                using: ioHandle,
                destinationDirectory: destinationDirectory,
                fileName: metadata.fileName
            )
            committedURL = receivePath

            let receipt = FileTransferReceipt(
                transferId: transfer.id,
                success: true,
                receivedBytes: metadata.fileSize,
                fileHash: receivedHash,
                error: nil,
                securityVersion: metadata.securityVersion,
                authTag: nil
            )
            let receiptDeliveryStatus = await sendSuccessfulTransferReceiptAfterCommit(
                receipt,
                securityContext: resolvedSecurityContext,
                to: connection
            )
            transfer.localPath = receivePath
            transfer.classicResumeSourcePath = nil
            transfer.receiptDeliveryStatus = receiptDeliveryStatus
            try await InboundFileTransferIOActor.shared.releaseCommittedFile(using: ioHandle)
            inboundIOHandle = nil

            transfer.status = .completed
            transfer.classicControlFailure = nil
            transfer.completedAt = Date()
            transfer.progress = 1.0

 // 移动到历史记录
            let ownsActiveTransfer = activeTransfers[transfer.id] === transfer
            let shouldPublishCompletion = ownsActiveTransfer
                && isCurrentLifecycle(lifecycleGeneration)
            if ownsActiveTransfer {
                moveToHistory(transfer)
            }

            logger.info("✅ 文件接收完成并已落盘")
            lastTransferActivityAt = Date()

 // 发送接收完成通知
            if shouldPublishCompletion {
                if receiptDeliveryStatus == .unknown {
                    NotificationCenter.default.post(
                        name: Notification.Name("FileTransferReceiptDeliveryUnknown"),
                        object: nil,
                        userInfo: ["transferId": transfer.id]
                    )
                }
                NotificationCenter.default.post(
                    name: Notification.Name("FileTransferCompleted"),
                    object: nil,
                    userInfo: [
                        "transferId": transfer.id,
                        "fileName": transfer.fileName,
                        "fileSize": metadata.fileSize,
                        "deviceName": effectiveDeviceName,
                        "direction": "incoming",
                        "localPath": receivePath.path
                    ]
                )
            }

            // Show a system notification so the user sees it even if they are not on the File Transfer page.
            #if canImport(UserNotifications)
            if shouldPublishCompletion,
               Self.canUseUserNotificationsSafely(),
               SettingsManager.shared.showFileTransferNotifications {
                let content = UNMutableNotificationContent()
                content.title = LocalizationManager.shared.localizedString("notifications.fileReceived.completed")
                content.subtitle = effectiveDeviceName
                // Use the actual resolved path to avoid confusion when a custom receive directory is set.
                content.body = String(
                    format: LocalizationManager.shared.localizedString("notifications.fileReceived.savedTo"),
                    locale: LocalizationManager.shared.locale,
                    transfer.fileName,
                    receivePath.path
                )
                content.userInfo = [
                    "transferId": transfer.id,
                    "localPath": receivePath.path
                ]
                let req = UNNotificationRequest(identifier: "file-transfer-\(transfer.id)", content: content, trigger: nil)
                Task {
                    do {
                        try await UNUserNotificationCenter.current().add(req)
                    } catch {
                        let notificationError = error as NSError
                        self.logger.error(
                            "File receipt notification failed: domain=\(notificationError.domain, privacy: .private) code=\(notificationError.code)"
                        )
                    }
                }
            }
            #endif
        } catch {
            if let committedURL {
                let terminalError = FileTransferError.committedFileReleaseFailed
                transfer.localPath = committedURL
                transfer.classicResumeSourcePath = nil
                transfer.status = .failed
                transfer.completedAt = Date()
                transfer.error = terminalError.localizedDescription
                retireProductFileTransferEvidence(
                    for: transfer,
                    reason: .protocolFailure
                )
                moveToHistory(transfer)
                logger.error("❌ 文件已落盘，但入站 I/O 终态释放失败")
                throw terminalError
            }

            let resolution = await resolveClassicInboundFailure(
                for: transfer,
                underlyingError: error,
                ioHandle: inboundIOHandle,
                partialURL: stagingURL,
                declaredChunkSize: metadata.chunkSize,
                recordWasLoadedBeforeOperation: false
            )
            let terminalError = resolution.terminalError
            transfer.localPath = nil
            let receiveError = terminalError as NSError
            logger.error(
                "❌ 文件接收失败: domain=\(receiveError.domain, privacy: .private) code=\(receiveError.code, privacy: .public)"
            )
            lastTransferActivityAt = Date()
            transfer.status = isTransferCancellation(terminalError) ? .cancelled : .failed
            transfer.completedAt = Date()
            transfer.error = terminalError.localizedDescription
            retireProductFileTransferEvidence(
                for: transfer,
                reason: isTransferCancellation(terminalError)
                    ? .user
                    : .protocolFailure
            )

            // 失败路径也尽量回执，避免发送端长时间等待直到超时
            if isCurrentLifecycle(lifecycleGeneration) {
                await sendFailureReceiptIfPossible(
                    transferId: metadata.transferId,
                    receivedBytes: transfer.transferredBytes,
                    securityVersion: metadata.securityVersion,
                    error: terminalError,
                    securityContext: resolvedSecurityContext,
                    to: connection
                )
            }

            let shouldPublishFailure = activeTransfers[transfer.id] === transfer
            moveToHistory(transfer)

 // 发送接收失败通知
            if shouldPublishFailure && isCurrentLifecycle(lifecycleGeneration) {
                NotificationCenter.default.post(
                    name: Notification.Name("FileTransferFailed"),
                    object: nil,
                    userInfo: [
                        "transferId": metadata.transferId,
                        "fileName": transfer.fileName,
                        "error": terminalError.localizedDescription,
                        "deviceName": effectiveDeviceName
                    ]
                )
            }

            throw terminalError
        }

        updateTransferringStatus()
    }

    private func handleResumeRequest(
        _ request: ResumeRequestPayload,
        from connection: NWConnection,
        lifecycleGeneration: UUID
    ) async throws {
        guard #available(macOS 14.0, iOS 17.0, *) else {
            throw FileTransferError.secureSessionRequired
        }

        do {
            try ClassicTransferMetadataContract.validateSecurityVersion(request.securityVersion)
            try ClassicTransferMetadataContract.validateTransferIdentifier(request.transferId)
            try ClassicTransferMetadataContract.validateVisibleField(request.senderDeviceId)
        } catch {
            throw FileTransferError.secureSessionRequired
        }
        let securityContext = try await classicTransferSecurityContext(
            peerContext: FileTransferPeerContext(
                declaredSenderDeviceId: request.senderDeviceId,
                endpointHostOrIP: nil,
                peerLabel: nil,
                transferId: request.transferId
            )
        )
        let unsignedRequest = ResumeRequestPayload(
            transferId: request.transferId,
            senderDeviceId: request.senderDeviceId,
            resumeOffset: request.resumeOffset,
            securityVersion: request.securityVersion,
            authTag: Data()
        )
        guard isValidAuthenticationTag(
            request.authTag,
            payload: try resumeRequestAuthenticationInput(unsignedRequest),
            key: securityContext.transferKey
        ) else {
            throw FileTransferError.secureSessionRequired
        }
        try ensureCurrentLifecycle(lifecycleGeneration)
        _ = try await acquireTransferSlot(expectedGeneration: lifecycleGeneration)
        defer { releaseTransferSlot() }

        let resumeRecord: ClassicTransferResumeRecord
        do {
            guard let loadedRecord = try await loadResumeData(for: request.transferId) else {
                throw FileTransferError.receiverRejected
            }
            resumeRecord = loadedRecord
        } catch {
            try await sendResumeAcknowledgment(
                transferId: request.transferId,
                accepted: false,
                resumeOffset: 0,
                error: "resume_state_unavailable",
                securityContext: securityContext,
                to: connection
            )
            throw error
        }
        try ensureCurrentLifecycle(lifecycleGeneration)

        let localURL = URL(fileURLWithPath: resumeRecord.localPath)
        guard resumeRecord.direction == TransferDirection.incoming.rawValue,
              resumeRecord.deviceID == securityContext.resolvedPeerDeviceId,
              resumeRecord.transferredBytes == resumeRecord.resumeOffset,
              Self.isIsolatedClassicInboundPartial(localURL) else {
            try await sendResumeAcknowledgment(
                transferId: request.transferId,
                accepted: false,
                resumeOffset: 0,
                error: "resume_state_invalid",
                securityContext: securityContext,
                to: connection
            )
            throw FileTransferError.receiverRejected
        }
        do {
            try await ClassicTransferJSONWorker.shared.validateMetadata(
                transferID: resumeRecord.transferID,
                fileName: resumeRecord.fileName,
                fileSize: resumeRecord.fileSize,
                fileHash: resumeRecord.fileHash,
                declaredChunkSize: resumeRecord.declaredChunkSize,
                compression: resumeRecord.compression,
                displayFields: [resumeRecord.deviceID, resumeRecord.deviceName]
            )
            try ClassicTransferMetadataContract.validateResumeOffset(
                resumeRecord.resumeOffset,
                fileSize: resumeRecord.fileSize,
                declaredChunkSize: resumeRecord.declaredChunkSize
            )
            try ClassicTransferMetadataContract.validateResumeOffset(
                request.resumeOffset,
                fileSize: resumeRecord.fileSize,
                declaredChunkSize: resumeRecord.declaredChunkSize
            )
        } catch {
            try await sendResumeAcknowledgment(
                transferId: request.transferId,
                accepted: false,
                resumeOffset: 0,
                error: "resume_contract_invalid",
                securityContext: securityContext,
                to: connection
            )
            throw FileTransferError.receiverRejected
        }
        try ensureCurrentLifecycle(lifecycleGeneration)
        let acceptedOffset = min(request.resumeOffset, resumeRecord.resumeOffset)
        let destinationDirectory = try await preparedInboundDestinationDirectory()
        try ensureCurrentLifecycle(lifecycleGeneration)
        do {
            try await InboundFileTransferIOActor.shared.validateSameVolumeCommit(
                stagingURL: localURL,
                destinationDirectory: destinationDirectory
            )
        } catch {
            try await sendResumeAcknowledgment(
                transferId: request.transferId,
                accepted: false,
                resumeOffset: 0,
                error: "resume_destination_unavailable",
                securityContext: securityContext,
                to: connection
            )
            throw error
        }
        try ensureCurrentLifecycle(lifecycleGeneration)

        guard activeTransfers[request.transferId] == nil else {
            try await sendResumeAcknowledgment(
                transferId: request.transferId,
                accepted: false,
                resumeOffset: 0,
                error: "resume_transfer_already_active",
                securityContext: securityContext,
                to: connection
            )
            throw FileTransferError.invalidTransferState
        }
        let transfer = FileTransfer(
            id: request.transferId,
            fileName: resumeRecord.fileName,
            fileSize: resumeRecord.fileSize,
            deviceId: resumeRecord.deviceID,
            direction: .incoming,
            status: .transferring
        )
        transfer.deviceName = resumeRecord.deviceName
        transfer.deviceIPAddress = resumeRecord.deviceIPAddress
        transfer.devicePort = resumeRecord.devicePort
        transfer.fileHash = resumeRecord.fileHash
        transfer.compression = resumeRecord.compression
        transfer.negotiatedClassicChunkSize = resumeRecord.declaredChunkSize
        transfer.classicResumeRecord = resumeRecord
        transfer.updateProgress(transferredBytes: acceptedOffset)
        registerActiveTransfer(transfer)

        bindClassicConnection(connection, to: transfer.id)
        defer { unbindClassicConnection(connection, from: transfer.id) }
        transfer.resumeOffset = acceptedOffset
        publishActiveTransferProgress(transfer, transferredBytes: acceptedOffset)

        var inboundIOHandle: InboundFileTransferIOHandle?
        var committedURL: URL?
        do {
            let ioHandle = try await InboundFileTransferIOActor.shared.resumeTemporaryFile(
                at: localURL,
                isolatedDirectory: try Self.classicInboundPartialDirectory(),
                declaredFileSize: resumeRecord.fileSize,
                resumeOffset: acceptedOffset
            )
            inboundIOHandle = ioHandle
            try ensureCurrentLifecycle(lifecycleGeneration)
            transfer.classicResumeSourcePath = localURL
            try await sendResumeAcknowledgment(
                transferId: request.transferId,
                accepted: true,
                resumeOffset: acceptedOffset,
                error: nil,
                securityContext: securityContext,
                to: connection
            )
            try ensureCurrentLifecycle(lifecycleGeneration)

            let receivedDigest = try await receiveFileInChunks(
                transfer: transfer,
                securityContext: securityContext,
                from: connection,
                ioHandle: ioHandle,
                negotiatedChunkSize: resumeRecord.declaredChunkSize,
                startOffset: acceptedOffset
            )
            try ensureCurrentLifecycle(lifecycleGeneration)

            let receivedHash = Self.sha256Hex(receivedDigest)
            guard receivedHash == resumeRecord.fileHash else {
                throw FileTransferError.integrityCheckFailed
            }

            if virusScanEnabled {
                logClassicReceiptPhase("post_receive_scan_started", transferId: transfer.id)
            }
            if let scanResult = await scanReceivedFileIfEnabled(localURL) {
                transfer.scanResult = scanResult
                logClassicReceiptPhase("post_receive_scan_completed", transferId: transfer.id)
                if case .block(let reason) = scanResult.automaticTransferAdmission {
                    throw reason.managerError
                }
            } else if virusScanEnabled {
                logClassicReceiptPhase("post_receive_scan_completed", transferId: transfer.id)
            }
            try ensureCurrentLifecycle(lifecycleGeneration)

            try await cleanupResumeData(matching: resumeRecord)
            transfer.resumeDataPath = nil
            transfer.classicResumeRecord = nil
            try ensureCurrentLifecycle(lifecycleGeneration)

            let receivePath = try await InboundFileTransferIOActor.shared.commit(
                using: ioHandle,
                destinationDirectory: destinationDirectory,
                fileName: resumeRecord.fileName
            )
            committedURL = receivePath

            let receipt = FileTransferReceipt(
                transferId: request.transferId,
                success: true,
                receivedBytes: transfer.fileSize,
                fileHash: receivedHash,
                error: nil,
                securityVersion: request.securityVersion,
                authTag: nil
            )
            let receiptDeliveryStatus = await sendSuccessfulTransferReceiptAfterCommit(
                receipt,
                securityContext: securityContext,
                to: connection
            )
            transfer.localPath = receivePath
            transfer.classicResumeSourcePath = nil
            transfer.receiptDeliveryStatus = receiptDeliveryStatus
            try await InboundFileTransferIOActor.shared.releaseCommittedFile(using: ioHandle)
            inboundIOHandle = nil

            transfer.status = .completed
            transfer.classicControlFailure = nil
            transfer.completedAt = Date()
            transfer.progress = 1.0
            lastTransferActivityAt = Date()
            let ownsActiveTransfer = activeTransfers[transfer.id] === transfer
            let shouldPublishCompletion = ownsActiveTransfer
                && isCurrentLifecycle(lifecycleGeneration)
            if ownsActiveTransfer {
                moveToHistory(transfer)
            }
            if shouldPublishCompletion {
                if receiptDeliveryStatus == .unknown {
                    NotificationCenter.default.post(
                        name: Notification.Name("FileTransferReceiptDeliveryUnknown"),
                        object: nil,
                        userInfo: ["transferId": transfer.id]
                    )
                }
                NotificationCenter.default.post(
                    name: Notification.Name("FileTransferCompleted"),
                    object: nil,
                    userInfo: [
                        "transferId": transfer.id,
                        "fileName": transfer.fileName,
                        "fileSize": transfer.fileSize,
                        "deviceName": transfer.deviceName ?? transfer.deviceId,
                        "direction": "incoming",
                        "localPath": receivePath.path
                    ]
                )
            }
        } catch {
            if let committedURL {
                let terminalError = FileTransferError.committedFileReleaseFailed
                transfer.localPath = committedURL
                transfer.classicResumeSourcePath = nil
                transfer.status = .failed
                transfer.completedAt = Date()
                transfer.error = terminalError.localizedDescription
                moveToHistory(transfer)
                logger.error("❌ 续传文件已落盘，但入站 I/O 终态释放失败")
                throw terminalError
            }

            let resolution = await resolveClassicInboundFailure(
                for: transfer,
                underlyingError: error,
                ioHandle: inboundIOHandle,
                partialURL: localURL,
                declaredChunkSize: resumeRecord.declaredChunkSize,
                recordWasLoadedBeforeOperation: true
            )
            let terminalError = resolution.terminalError
            transfer.localPath = nil
            transfer.status = isTransferCancellation(terminalError) ? .cancelled : .failed
            transfer.completedAt = Date()
            transfer.error = terminalError.localizedDescription
            if isCurrentLifecycle(lifecycleGeneration) {
                await sendFailureReceiptIfPossible(
                    transferId: request.transferId,
                    receivedBytes: transfer.transferredBytes,
                    securityVersion: request.securityVersion,
                    error: terminalError,
                    securityContext: securityContext,
                    to: connection
                )
            }
            moveToHistory(transfer)
            throw terminalError
        }
    }

    private func sendResumeAcknowledgment(
        transferId: String,
        accepted: Bool,
        resumeOffset: Int64,
        error: String?,
        securityContext: ClassicTransferSecurityContext,
        to connection: NWConnection
    ) async throws {
        let unsigned = ResumeAckPayload(
            transferId: transferId,
            accepted: accepted,
            resumeOffset: resumeOffset,
            error: error,
            securityVersion: ClassicTransferInboundPolicy.currentSecurityVersion,
            authTag: Data()
        )
        let ack = ResumeAckPayload(
            transferId: transferId,
            accepted: accepted,
            resumeOffset: resumeOffset,
            error: error,
            securityVersion: ClassicTransferInboundPolicy.currentSecurityVersion,
            authTag: authenticationTag(
                for: try resumeAckAuthenticationInput(unsigned),
                using: securityContext.transferKey
            )
        )
        let payload = try await ClassicTransferJSONWorker.shared.encode(
            ack,
            maximumOutputSize: maxMessageBytes
        )
        try await sendData(createHeader(type: .resumeAck, length: payload.count) + payload, to: connection)
    }

 // MARK: - 传输控制方法

 /// 暂停传输 - 利用macOS 26.x的改进持久化保存断点信息
    @MainActor
    public func pauseTransfer(_ transferId: UUID) async {
        let transferIdString = transferId.uuidString
        guard let transfer = activeTransfers[transferIdString] else {
            logger.warning("尝试暂停不存在的传输")
            return
        }
        guard transfer.status == .transferring else {
            logger.warning("仅运行中的传输可以暂停: status=\(transfer.status.rawValue, privacy: .public)")
            return
        }
        guard transfer.transferredBytes < transfer.fileSize else {
            logger.warning("传输数据阶段已结束，拒绝暂停")
            return
        }
        guard classicConnectionsByTransferID[transferIdString] != nil else {
            logger.warning("仅已绑定经典传输连接支持暂停")
            return
        }
        guard classicPauseRequests[transferIdString] == nil else {
            logger.warning("暂停请求已在处理中")
            return
        }

        transfer.classicControlFailure = nil
        let pauseRequest = ClassicTransferPauseRequest()
        classicPauseRequests[transferIdString] = pauseRequest
        let timeoutTask = Task { @MainActor [weak self, weak pauseRequest] in
            do {
                try await Task.sleep(for: .seconds(self?.pauseQuiescenceTimeoutSeconds ?? 15))
            } catch is CancellationError {
                return
            } catch {
                guard let self, let pauseRequest else { return }
                self.failClassicPauseRequest(
                    transferID: transferIdString,
                    request: pauseRequest,
                    underlyingError: error
                )
                return
            }
            guard let self, let pauseRequest else { return }
            self.failClassicPauseRequest(
                transferID: transferIdString,
                request: pauseRequest,
                underlyingError: FileTransferError.timeout
            )
        }
        defer { timeoutTask.cancel() }

        guard let quiescedOffset = await pauseRequest.waitForSafeBoundary() else {
            return
        }
        timeoutTask.cancel()
        guard quiescedOffset > 0, quiescedOffset < transfer.fileSize else {
            failClassicPauseRequest(
                transferID: transferIdString,
                request: pauseRequest,
                underlyingError: FileTransferError.invalidTransferState
            )
            return
        }
        transfer.resumeOffset = quiescedOffset

        do {
            try await saveResumeData(for: transfer)
        } catch {
            failClassicPauseRequest(
                transferID: transferIdString,
                request: pauseRequest,
                underlyingError: error
            )
            return
        }

        guard classicPauseRequests[transferIdString] === pauseRequest,
              pauseRequest.markPaused() else {
            do {
                try await cleanupResumeStateIfPresent(for: transfer)
            } catch {
                let cleanupError = error as NSError
                logger.error(
                    "❌ 已中止暂停请求的状态清理失败: domain=\(cleanupError.domain, privacy: .private) code=\(cleanupError.code, privacy: .public)"
                )
            }
            return
        }

        logger.info("传输已暂停: 已传输=\(transfer.resumeOffset, privacy: .public) 字节")
    }

    private func failClassicPauseRequest(
        transferID: String,
        request: ClassicTransferPauseRequest,
        underlyingError: Error
    ) {
        guard classicPauseRequests[transferID] === request else {
            request.abort()
            return
        }
        classicPauseRequests.removeValue(forKey: transferID)
        request.abort()
        guard let transfer = activeTransfers[transferID] else { return }

        let failure = FileTransferError.resumeStatePersistenceFailed
        transfer.status = .failed
        transfer.classicControlFailure = failure
        transfer.error = failure.localizedDescription
        classicConnectionsByTransferID[transferID]?.cancel()
        let persistenceError = underlyingError as NSError
        logger.error(
            "❌ 暂停传输未能到达并持久化安全边界: domain=\(persistenceError.domain, privacy: .private) code=\(persistenceError.code, privacy: .public)"
        )
    }

    @discardableResult
    func acknowledgeClassicPauseRequestIfNeeded(for transfer: FileTransfer) -> Bool {
        guard let request = classicPauseRequests[transfer.id],
              transfer.status == .transferring else {
            return false
        }
        guard transfer.transferredBytes > 0,
              transfer.transferredBytes < transfer.fileSize else {
            classicPauseRequests.removeValue(forKey: transfer.id)
            request.abort()
            logger.info("暂停请求到达时数据阶段已完成，继续完成传输")
            return false
        }
        guard request.acknowledge(offset: transfer.transferredBytes) else {
            return false
        }
        transfer.resumeOffset = transfer.transferredBytes
        transfer.status = .paused
        return true
    }

 /// 保存断点续传数据 - 利用macOS 26.x的改进文件系统性能
    private func saveResumeData(
        for transfer: FileTransfer,
        localPath: URL? = nil,
        declaredChunkSize: Int? = nil
    ) async throws {
        guard let persistedPath = localPath ?? transfer.classicResumeSourcePath ?? transfer.localPath,
              let fileHash = transfer.fileHash,
              fileHash.utf8.count == 64 else {
            throw FileTransferError.resumeStatePersistenceFailed
        }
        guard let persistedChunkSize = declaredChunkSize ?? transfer.negotiatedClassicChunkSize else {
            throw FileTransferError.resumeStatePersistenceFailed
        }
        do {
            try ClassicTransferMetadataContract.validateResumeOffset(
                transfer.resumeOffset,
                fileSize: transfer.fileSize,
                declaredChunkSize: persistedChunkSize
            )
        } catch {
            throw FileTransferError.resumeStatePersistenceFailed
        }
        let record = ClassicTransferResumeRecord(
            transferID: transfer.id,
            fileName: transfer.fileName,
            fileSize: transfer.fileSize,
            transferredBytes: transfer.transferredBytes,
            resumeOffset: transfer.resumeOffset,
            deviceID: transfer.deviceId,
            deviceIPAddress: transfer.deviceIPAddress,
            devicePort: transfer.devicePort,
            deviceName: transfer.deviceName,
            direction: transfer.direction.rawValue,
            localPath: persistedPath.path,
            fileHash: fileHash,
            compression: transfer.compression,
            declaredChunkSize: persistedChunkSize,
            timestamp: Date()
        )
        let resumeFile = try await resumeStore.save(record)
        transfer.resumeDataPath = resumeFile
        transfer.classicResumeRecord = record
        logger.info("✅ 断点续传状态已保存")
    }

 /// 加载断点续传数据
    private func loadResumeData(for transferId: String) async throws -> ClassicTransferResumeRecord? {
        let record = try await resumeStore.load(transferID: transferId)
        if record != nil {
            logger.info("✅ 断点续传状态已加载")
        }
        return record
    }

 /// 恢复传输
    @MainActor
    public func resumeTransfer(_ transferId: UUID) async {
        let transferIdString = transferId.uuidString
        guard let transfer = activeTransfers[transferIdString] else {
            logger.warning("尝试恢复不存在的传输")
            return
        }

        guard transfer.status == TransferStatus.paused else {
            logger.warning("传输状态不是暂停状态，无法恢复: \(transfer.status.rawValue)")
            return
        }
        guard let pauseRequest = classicPauseRequests[transferIdString],
              pauseRequest.phase == .paused else {
            logger.warning("暂停状态尚未持久化完成，拒绝提前恢复")
            return
        }

 // 更新传输状态
        classicPauseRequests.removeValue(forKey: transferIdString)
        transfer.classicControlFailure = nil
        transfer.status = .transferring

        logger.info("传输已恢复")
    }

    private func continueSendingFile(
        _ transfer: FileTransfer,
        negotiatedChunkSize: Int,
        negotiatedCompression: String?,
        securityContext: ClassicTransferSecurityContext,
        lifecycleGeneration: UUID
    ) async throws {
        try ensureCurrentLifecycle(lifecycleGeneration)
        guard let localPath = transfer.localPath else {
            throw FileTransferError.fileNotFound
        }

        guard let ipAddress = transfer.deviceIPAddress, !ipAddress.isEmpty else {
            throw FileTransferError.invalidHeader
        }

        logger.info("🔄 恢复发送文件: offset=\(transfer.resumeOffset, privacy: .public)")

 // 重新建立连接
        let connection = try await networkService.connectToDevice(
            ipAddress: ipAddress,
            port: transfer.devicePort,
            deviceId: transfer.deviceId,
            deviceName: transfer.deviceName ?? "Unknown Device"
        )
        do {
            try ensureCurrentLifecycle(lifecycleGeneration)
        } catch {
            networkService.disconnect(connection)
            throw error
        }
        bindClassicConnection(connection, to: transfer.id)
        defer {
            unbindClassicConnection(connection, from: transfer.id)
            networkService.disconnect(connection)
        }

        let localDeviceId = try await SelfIdentityProvider.shared
            .protocolIdentityDeviceId(allowCreate: true)
        try ensureCurrentLifecycle(lifecycleGeneration)
        // 发送断点续传请求（包含已传输字节数）
        try await sendResumeRequest(
            transferId: transfer.id,
            senderDeviceId: localDeviceId,
            resumeOffset: transfer.resumeOffset,
            securityContext: securityContext,
            to: connection
        )

        // 等待接收端确认实际偏移
        let acceptedOffset = try await waitForResumeAcknowledgment(
            transferId: transfer.id,
            requestedOffset: transfer.resumeOffset,
            fileSize: transfer.fileSize,
            declaredChunkSize: negotiatedChunkSize,
            securityContext: securityContext,
            from: connection
        )
        try ensureCurrentLifecycle(lifecycleGeneration)
        transfer.resumeOffset = acceptedOffset
        publishActiveTransferProgress(transfer, transferredBytes: acceptedOffset)

        // 从断点继续分块传输
        try await sendFileInChunks(
            from: localPath,
            transfer: transfer,
            negotiatedChunkSize: negotiatedChunkSize,
            negotiatedCompression: negotiatedCompression,
            securityContext: securityContext,
            to: connection,
            startOffset: acceptedOffset
        )
        try ensureCurrentLifecycle(lifecycleGeneration)

        let receipt = try await waitForTransferReceipt(
            from: connection,
            securityContext: securityContext,
            expectedTransferId: transfer.id,
            expectedFileSize: transfer.fileSize,
            expectedFileHash: transfer.fileHash
        )
        try ensureCurrentLifecycle(lifecycleGeneration)
        logger.info("✅ 接收端已确认恢复传输落盘: transfer=\(receipt.transferId) bytes=\(receipt.receivedBytes)")

        try await cleanupResumeStateIfPresent(for: transfer)
        try ensureCurrentLifecycle(lifecycleGeneration)
        transfer.status = .completed
        transfer.completedAt = Date()
        transfer.progress = 1.0
        logger.info("✅ 文件发送恢复完成: \(transfer.fileName)")
    }

 /// 发送断点续传请求
    private func sendResumeRequest(
        transferId: String,
        senderDeviceId: String,
        resumeOffset: Int64,
        securityContext: ClassicTransferSecurityContext,
        to connection: NWConnection
    ) async throws {
        let unsigned = ResumeRequestPayload(
            transferId: transferId,
            senderDeviceId: senderDeviceId,
            resumeOffset: resumeOffset,
            securityVersion: ClassicTransferInboundPolicy.currentSecurityVersion,
            authTag: Data()
        )
        let authTag = authenticationTag(
            for: try resumeRequestAuthenticationInput(unsigned),
            using: securityContext.transferKey
        )
        let request = ResumeRequestPayload(
            transferId: transferId,
            senderDeviceId: senderDeviceId,
            resumeOffset: resumeOffset,
            securityVersion: ClassicTransferInboundPolicy.currentSecurityVersion,
            authTag: authTag
        )
        let payload = try await ClassicTransferJSONWorker.shared.encode(
            request,
            maximumOutputSize: maxMessageBytes
        )
        try await sendData(createHeader(type: .resumeRequest, length: payload.count) + payload, to: connection)
        logger.debug("📤 发送断点续传请求: offset=\(resumeOffset, privacy: .public)")
    }

 /// 等待断点续传确认
    private func waitForResumeAcknowledgment(
        transferId: String,
        requestedOffset: Int64,
        fileSize: Int64,
        declaredChunkSize: Int,
        securityContext: ClassicTransferSecurityContext,
        from connection: NWConnection
    ) async throws -> Int64 {
        let headerData: Data
        do {
            headerData = try await receiveData(length: 8, from: connection, timeout: resumeAckTimeoutSeconds)
        } catch FileTransferError.timeout {
            logger.error("❌ resume_ack_header_timeout")
            throw FileTransferError.timeout
        }
        let header = parseHeader(headerData)
        guard header.type == .resumeAck, header.length > 0, header.length <= maxMessageBytes else {
            throw FileTransferError.invalidHeader
        }
        let payload: Data
        do {
            payload = try await receiveData(length: header.length, from: connection, timeout: resumeAckTimeoutSeconds)
        } catch FileTransferError.timeout {
            logger.error("❌ resume_ack_payload_timeout")
            throw FileTransferError.timeout
        }
        let ack = try await ClassicTransferJSONWorker.shared.decode(
            ResumeAckPayload.self,
            from: payload,
            maximumInputSize: maxMessageBytes
        )
        do {
            try ClassicTransferMetadataContract.validateSecurityVersion(ack.securityVersion)
            try ClassicTransferMetadataContract.validateTransferIdentifier(ack.transferId)
            try ClassicTransferMetadataContract.validateVisibleField(
                ack.error,
                maximumUTF8Length: 1_024
            )
        } catch {
            throw FileTransferError.secureSessionRequired
        }
        guard ack.transferId == transferId else {
            throw FileTransferError.invalidHeader
        }
        guard isValidAuthenticationTag(
            ack.authTag,
            payload: try resumeAckAuthenticationInput(ResumeAckPayload(
                transferId: ack.transferId,
                accepted: ack.accepted,
                resumeOffset: ack.resumeOffset,
                error: ack.error,
                securityVersion: ack.securityVersion,
                authTag: Data()
            )),
            key: securityContext.transferKey
        ) else {
            throw FileTransferError.secureSessionRequired
        }
        guard ack.accepted else {
            throw FileTransferError.receiverRejected
        }
        do {
            try ClassicTransferResumeAcknowledgmentContract.validate(
                acceptedOffset: ack.resumeOffset,
                requestedOffset: requestedOffset,
                fileSize: fileSize,
                declaredChunkSize: declaredChunkSize
            )
        } catch {
            throw FileTransferError.invalidHeader
        }
        logger.debug("✅ 断点续传确认已收到: offset=\(ack.resumeOffset, privacy: .public)")
        return ack.resumeOffset
    }

 /// 清理断点续传数据
    private func cleanupResumeData(matching record: ClassicTransferResumeRecord) async throws {
        do {
            try await resumeStore.remove(matching: record)
        } catch {
            throw FileTransferError.resumeStateCleanupFailed
        }
        logger.debug("🗑️ 断点续传状态已清理")
    }

    func cleanupResumeStateIfPresent(for transfer: FileTransfer) async throws {
        guard transfer.resumeDataPath != nil else { return }
        guard let record = transfer.classicResumeRecord else {
            throw FileTransferError.resumeStateCleanupFailed
        }
        try await cleanupResumeData(matching: record)
        transfer.resumeDataPath = nil
        transfer.classicResumeSourcePath = nil
        transfer.classicResumeRecord = nil
    }

    private func terminalResumeRecordCleanupErrorIfNeeded(
        for transfer: FileTransfer,
        recordWasLoadedBeforeOperation: Bool,
        preservingFreshRecoverableState: Bool
    ) async -> FileTransferError? {
        guard !preservingFreshRecoverableState,
              recordWasLoadedBeforeOperation || transfer.resumeDataPath != nil else {
            return nil
        }
        guard let record = transfer.classicResumeRecord else {
            return FileTransferError.resumeStateCleanupFailed
        }
        do {
            try await cleanupResumeData(matching: record)
            transfer.resumeDataPath = nil
            transfer.classicResumeSourcePath = nil
            transfer.classicResumeRecord = nil
            return nil
        } catch {
            let cleanupError = error as NSError
            logger.error(
                "❌ 终态续传记录清理失败: domain=\(cleanupError.domain, privacy: .private) code=\(cleanupError.code, privacy: .public)"
            )
            return FileTransferError.resumeStateCleanupFailed
        }
    }

    private struct ClassicInboundFailureResolution {
        let terminalError: Error
        let didPersistFreshRecoverableState: Bool
    }

    private func resolveClassicInboundFailure(
        for transfer: FileTransfer,
        underlyingError: Error,
        ioHandle: InboundFileTransferIOHandle?,
        partialURL: URL,
        declaredChunkSize: Int,
        recordWasLoadedBeforeOperation: Bool
    ) async -> ClassicInboundFailureResolution {
        var terminalError = normalizedClassicOperationError(underlyingError, for: transfer)
        var didPersistFreshRecoverableState = false
        var didSuspendHandle = false
        var partialCleanupFailed = false

        if let ioHandle {
            if shouldPreserveInboundPartial(
                for: terminalError,
                receivedBytes: transfer.transferredBytes
            ) {
                do {
                    try await InboundFileTransferIOActor.shared.suspendForResume(ioHandle)
                    didSuspendHandle = true
                    transfer.resumeOffset = transfer.transferredBytes
                    do {
                        try await saveResumeData(
                            for: transfer,
                            localPath: partialURL,
                            declaredChunkSize: declaredChunkSize
                        )
                        terminalError = normalizedClassicOperationError(
                            underlyingError,
                            for: transfer
                        )
                        didPersistFreshRecoverableState = shouldPreserveInboundPartial(
                            for: terminalError,
                            receivedBytes: transfer.transferredBytes
                        )
                    } catch {
                        terminalError = normalizedClassicOperationError(error, for: transfer)
                    }
                } catch {
                    let currentOperationError = normalizedClassicOperationError(
                        underlyingError,
                        for: transfer
                    )
                    terminalError = isTransferCancellation(currentOperationError)
                        ? currentOperationError
                        : FileTransferError.resumeStatePersistenceFailed
                }
            }

            if !didPersistFreshRecoverableState {
                do {
                    if didSuspendHandle {
                        try await InboundFileTransferIOActor.shared.discardSuspendedPartial(
                            at: partialURL,
                            isolatedDirectory: try Self.classicInboundPartialDirectory()
                        )
                    } else {
                        try await InboundFileTransferIOActor.shared.discard(ioHandle)
                    }
                } catch {
                    partialCleanupFailed = true
                    let cleanupError = error as NSError
                    logger.error(
                        "❌ 入站未完成文件清理失败: domain=\(cleanupError.domain, privacy: .private) code=\(cleanupError.code, privacy: .public)"
                    )
                }
            }
        } else if recordWasLoadedBeforeOperation {
            do {
                try await InboundFileTransferIOActor.shared.discardSuspendedPartial(
                    at: partialURL,
                    isolatedDirectory: try Self.classicInboundPartialDirectory()
                )
            } catch {
                partialCleanupFailed = true
                let cleanupError = error as NSError
                logger.error(
                    "❌ 已加载续传文件清理失败: domain=\(cleanupError.domain, privacy: .private) code=\(cleanupError.code, privacy: .public)"
                )
            }
        }

        if let resumeCleanupError = await terminalResumeRecordCleanupErrorIfNeeded(
            for: transfer,
            recordWasLoadedBeforeOperation: recordWasLoadedBeforeOperation,
            preservingFreshRecoverableState: didPersistFreshRecoverableState
        ) {
            terminalError = resumeCleanupError
        } else if partialCleanupFailed {
            terminalError = FileTransferError.partialFileCleanupFailed
        }

        return ClassicInboundFailureResolution(
            terminalError: terminalError,
            didPersistFreshRecoverableState: didPersistFreshRecoverableState
        )
    }

    /// 取消传输
    public func cancelTransfer(_ transferId: String) {
        if let cancellationHandler = externalTransferCancellationHandlersByTransferID[transferId] {
            cancellationHandler()
            return
        }
        if let transfer = activeTransfers[transferId] {
            retireProductFileTransferEvidence(for: transfer, reason: .user)
            transfer.status = .cancelled
            transfer.classicControlFailure = FileTransferError.transferCancelled
            transfer.error = FileTransferError.transferCancelled.localizedDescription
            classicPauseRequests.removeValue(forKey: transferId)?.abort()
            let connection = classicConnectionsByTransferID[transferId]
            connection?.cancel()
            if connection == nil {
                if transfer.resumeDataPath != nil
                    || (transfer.direction == .incoming && transfer.classicResumeSourcePath != nil) {
                    scheduleTerminalCancellationCleanup(for: transfer)
                } else {
                    moveToHistory(transfer)
                }
            }
            updateTransferringStatus()
            logger.info("❌ 取消传输")
        }
    }

    private func scheduleTerminalCancellationCleanup(for transfer: FileTransfer) {
        guard terminalCleanupTasks[transfer.id] == nil else { return }
        terminalCleanupTasks[transfer.id] = Task { @MainActor [self, transfer] in
            await self.finalizeCancelledTransferWithoutConnection(transfer)
        }
    }

    private func finalizeCancelledTransferWithoutConnection(_ transfer: FileTransfer) async {
        defer { terminalCleanupTasks.removeValue(forKey: transfer.id) }
        var cleanupFailure: FileTransferError?

        if transfer.direction == .incoming,
           let partialURL = transfer.classicResumeSourcePath,
           Self.isIsolatedClassicInboundPartial(partialURL) {
            do {
                try await InboundFileTransferIOActor.shared.discardSuspendedPartial(
                    at: partialURL,
                    isolatedDirectory: try Self.classicInboundPartialDirectory()
                )
                transfer.classicResumeSourcePath = nil
            } catch {
                cleanupFailure = FileTransferError.partialFileCleanupFailed
                let partialCleanupError = error as NSError
                logger.error(
                    "❌ 取消传输的未完成文件清理失败: domain=\(partialCleanupError.domain, privacy: .private) code=\(partialCleanupError.code, privacy: .public)"
                )
            }
        }

        if let resumeCleanupFailure = await terminalResumeRecordCleanupErrorIfNeeded(
            for: transfer,
            recordWasLoadedBeforeOperation: false,
            preservingFreshRecoverableState: false
        ) {
            cleanupFailure = resumeCleanupFailure
        }

        guard activeTransfers[transfer.id] === transfer else { return }
        if let cleanupFailure {
            transfer.status = .failed
            transfer.classicControlFailure = cleanupFailure
            transfer.error = cleanupFailure.localizedDescription
        } else {
            transfer.status = .cancelled
            transfer.classicControlFailure = FileTransferError.transferCancelled
            transfer.error = FileTransferError.transferCancelled.localizedDescription
        }
        transfer.completedAt = Date()
        moveToHistory(transfer)
        updateTransferringStatus()
    }

    private func awaitTerminalCleanupTasks() async {
        while !terminalCleanupTasks.isEmpty {
            let tasks = Array(terminalCleanupTasks.values)
            for task in tasks {
                await task.value
            }
        }
    }

    func bindClassicConnection(_ connection: NWConnection, to transferID: String) {
        pendingClassicConnections.removeValue(forKey: ObjectIdentifier(connection))
        classicConnectionsByTransferID[transferID]?.cancel()
        classicConnectionsByTransferID[transferID] = connection
    }

    func unbindClassicConnection(_ connection: NWConnection, from transferID: String) {
        guard classicConnectionsByTransferID[transferID] === connection else { return }
        classicConnectionsByTransferID.removeValue(forKey: transferID)
    }

 /// 清理历史记录
    public func clearHistory() {
        retireCurrentProductFileTransferEvidence(reason: .user)
        transferHistory.removeAll()
        enqueueHistoryClear()
        logger.info("🗑️ 清理传输历史记录")
    }

 // MARK: - 私有方法

 /// 获取文件大小
    private func getFileSize(at url: URL) async throws -> Int64 {
        do {
            return try await ClassicTransferSourceFileInspectionWorker.shared.regularFileSize(
                at: url,
                maximumSize: ClassicTransferInboundPolicy.maximumFileSizeBytes
            )
        } catch ClassicTransferSourceFileInspectionError.notFound {
            throw FileTransferError.fileNotFound
        }
    }

    private enum InitialTransferMessage {
        case metadata(FileMetadata)
        case resume(ResumeRequestPayload)
    }

    /// 计算文件哈希；共享 reader actor 负责流式读取、取消和显式关闭。
    private func calculateFileHash(at url: URL) async throws -> String {
        let reader = try await ClassicTransferOutboundFileReadSession.open(
            url: url,
            tracksSHA256: false
        )
        do {
            let digest = try await reader.hashWholeFileAndClose()
            return digest.map { String(format: "%02x", $0) }.joined()
        } catch ClassicTransferOutboundFileReadError.closeFailed {
            throw FileTransferError.sourceFileCloseFailed
        }
    }

 /// 发送文件元数据
    private func receiveInitialTransferMessage(from connection: NWConnection) async throws -> InitialTransferMessage {
        let headerData = try await receiveData(
            length: 8,
            from: connection,
            timeout: ClassicTransferInboundPolicy.initialHeaderTimeoutSeconds,
            zeroByteDisconnectError: .inboundConnectionClosedBeforeMetadata
        )
        let header = parseHeader(headerData)
        guard header.length >= 0, header.length <= maxMessageBytes else {
            throw FileTransferError.inboundInvalidInitialHeader
        }

        let payload = try await receiveData(
            length: header.length,
            from: connection,
            timeout: ClassicTransferInboundPolicy.metadataPayloadTimeoutSeconds
        )
        do {
            switch header.type {
            case .metadata:
                return .metadata(try await ClassicTransferJSONWorker.shared.decode(
                    FileMetadata.self,
                    from: payload,
                    maximumInputSize: maxMessageBytes
                ))
            case .resumeRequest:
                return .resume(try await ClassicTransferJSONWorker.shared.decode(
                    ResumeRequestPayload.self,
                    from: payload,
                    maximumInputSize: maxMessageBytes
                ))
            default:
                throw FileTransferError.inboundInvalidInitialHeader
            }
        } catch FileTransferError.inboundInvalidInitialHeader {
            throw FileTransferError.inboundInvalidInitialHeader
        } catch is DecodingError {
            logger.info("📥 inbound file-transfer initial metadata rejected")
            throw FileTransferError.inboundInvalidInitialHeader
        }
    }

    private func sendFileMetadata(
        _ transfer: FileTransfer,
        negotiatedChunkSize: Int,
        negotiatedCompression: String?,
        securityContext: ClassicTransferSecurityContext,
        to connection: NWConnection
    ) async throws {
        var senderDeviceId: String? = nil
        var senderDeviceName: String? = nil
        var senderPlatform: String? = nil
        var senderOSVersion: String? = nil
        var senderModelName: String? = nil
        let senderChip: String? = nil
        #if os(macOS)
        if #available(macOS 14.0, *) {
            let snap = try await SelfIdentityProvider.shared
                .snapshotEnsuringProtocolDeviceId(allowCreate: true)
            senderDeviceId = snap.deviceId
            senderDeviceName = LocalHostName.localizedName
            senderPlatform = "macOS"
            senderOSVersion = ProcessInfo.processInfo.operatingSystemVersionString
            senderModelName = "Mac"
        }
        #endif
        let unsignedMetadata = FileMetadata(
            transferId: transfer.id,
            fileName: transfer.fileName,
            fileSize: transfer.fileSize,
            fileHash: transfer.fileHash ?? "",
            chunkSize: negotiatedChunkSize,
            securityVersion: ClassicTransferInboundPolicy.currentSecurityVersion,
            metadataAuthTag: nil,
            compression: negotiatedCompression,
            senderDeviceId: senderDeviceId,
            senderDeviceName: senderDeviceName,
            senderPlatform: senderPlatform,
            senderOSVersion: senderOSVersion,
            senderModelName: senderModelName,
            senderChip: senderChip
        )
        try ClassicTransferMetadataContract.validateSecurityVersion(unsignedMetadata.securityVersion)
        try await ClassicTransferJSONWorker.shared.validateMetadata(
            transferID: unsignedMetadata.transferId,
            fileName: unsignedMetadata.fileName,
            fileSize: unsignedMetadata.fileSize,
            fileHash: unsignedMetadata.fileHash,
            declaredChunkSize: unsignedMetadata.chunkSize,
            compression: unsignedMetadata.compression,
            displayFields: [
                unsignedMetadata.senderDeviceId,
                unsignedMetadata.senderDeviceName,
                unsignedMetadata.senderPlatform,
                unsignedMetadata.senderOSVersion,
                unsignedMetadata.senderModelName,
                unsignedMetadata.senderChip
            ]
        )
        let metadata = FileMetadata(
            transferId: unsignedMetadata.transferId,
            fileName: unsignedMetadata.fileName,
            fileSize: unsignedMetadata.fileSize,
            fileHash: unsignedMetadata.fileHash,
            chunkSize: unsignedMetadata.chunkSize,
            securityVersion: unsignedMetadata.securityVersion,
            metadataAuthTag: authenticationTag(
                for: try metadataAuthenticationInput(unsignedMetadata),
                using: securityContext.transferKey
            ),
            compression: unsignedMetadata.compression,
            senderDeviceId: unsignedMetadata.senderDeviceId,
            senderDeviceName: unsignedMetadata.senderDeviceName,
            senderPlatform: unsignedMetadata.senderPlatform,
            senderOSVersion: unsignedMetadata.senderOSVersion,
            senderModelName: unsignedMetadata.senderModelName,
            senderChip: unsignedMetadata.senderChip
        )

        let data = try await ClassicTransferJSONWorker.shared.encode(
            metadata,
            maximumOutputSize: maxMessageBytes
        )
        let header = createHeader(type: .metadata, length: data.count)

        try await sendData(header + data, to: connection)
        logger.info("📋 发送文件元数据: \(transfer.fileName)")
    }

 /// 分块发送文件 - 支持断点续传
    /// 在发送一个数据块前，向 BandwidthThrottleEngine 申请发送令牌，实现按设备/时段的带宽限速。
    /// 令牌桶为空时短暂等待补充后重试，从而把发送速率限制在配置上限；引擎未启用或无限速时立即返回，零额外开销。
    /// FileTransferManager 与 BandwidthThrottleEngine 均为 @MainActor，故此处为同 actor 同步访问、无跨 actor 跳转。
    private func awaitBandwidthPermit(bytes: Int64, transfer: FileTransfer) async throws {
        let throttle = BandwidthThrottleEngine.shared
        guard throttle.isEnabled else { return }
        var remaining = bytes
        while remaining > 0 {
            // The token bucket may legitimately remain empty longer than the
            // pause-quiescence deadline. The previous committed byte offset is a
            // safe boundary because this chunk has not been sent yet, so honor a
            // pending pause while waiting instead of timing it out as a false
            // persistence failure.
            _ = acknowledgeClassicPauseRequestIfNeeded(for: transfer)
            try await waitUntilTransferCanProceed(transfer)

            let granted = await throttle.requestPermission(
                bytes: remaining,
                deviceID: transfer.deviceId
            )
            if granted > 0 {
                throttle.reportUsage(bytes: granted, deviceID: transfer.deviceId)
                remaining -= granted
            } else {
                do {
                    try await Task.sleep(nanoseconds: 20_000_000)
                } catch is CancellationError {
                    throw FileTransferError.transferCancelled
                }
            }
        }
    }

    private func waitUntilTransferCanProceed(_ transfer: FileTransfer) async throws {
        while true {
            switch ClassicTransferLoopControlPolicy.decision(for: transfer.status) {
            case .proceed:
                return
            case .waitForResume:
                do {
                    try await Task.sleep(nanoseconds: 100_000_000)
                } catch is CancellationError {
                    throw FileTransferError.transferCancelled
                }
            case .cancel:
                throw FileTransferError.transferCancelled
            case .failControlState:
                throw transfer.classicControlFailure
                    ?? FileTransferError.resumeStatePersistenceFailed
            case .failInvalidState:
                throw FileTransferError.invalidTransferState
            }
        }
    }

    private func sendFileInChunks(
        from url: URL,
        transfer: FileTransfer,
        negotiatedChunkSize: Int,
        negotiatedCompression: String?,
        securityContext: ClassicTransferSecurityContext,
        to connection: NWConnection,
        startOffset: Int64 = 0
    ) async throws {
        let fileReader = try await ClassicTransferOutboundFileReadSession.open(
            url: url,
            tracksSHA256: startOffset == 0
        )
        defer { clearSpeedLimitState(for: transfer.id) }

        do {
            var sentBytes: Int64 = startOffset
            let totalBytes = transfer.fileSize
            var chunkIndex = Int(startOffset / Int64(negotiatedChunkSize)) // 计算起始块索引

            if startOffset > 0 {
                logger.info("📍 从断点继续: 偏移量=\(startOffset), 块索引=\(chunkIndex)")
            }

            transfer.status = .transferring

            while sentBytes < totalBytes {
                try await waitUntilTransferCanProceed(transfer)

                let remainingBytes = totalBytes - sentBytes
                let currentChunkSize = min(Int64(negotiatedChunkSize), remainingBytes)

                let chunkData = try await fileReader.read(
                    offset: UInt64(sentBytes),
                    length: Int(currentChunkSize)
                )

                let payload: Data
                if negotiatedCompression == "zlib" {
                    do {
                        payload = try await ClassicTransferZlibCompressionWorker.shared.compress(
                            chunkData,
                            maximumInputSize: maxChunkSizeBytes
                        )
                    } catch is CancellationError {
                        throw FileTransferError.transferCancelled
                    }
                } else {
                    payload = chunkData
                }
                let encrypted: ClassicTransferEncryptedChunk
                do {
                    encrypted = try await ClassicTransferChunkCryptoWorker.shared.sealAndHash(
                        payload: payload,
                        plaintextChunk: chunkData,
                        using: securityContext.transferKey,
                        maximumPayloadSize: maxMessageBytes,
                        maximumPlaintextChunkSize: maxChunkSizeBytes
                    )
                } catch is CancellationError {
                    throw FileTransferError.transferCancelled
                }

                let chunk = FileChunk(
                    index: chunkIndex,
                    data: encrypted.ciphertext,
                    size: chunkData.count,
                    nonce: encrypted.nonce,
                    authenticationTag: encrypted.tag
                )

                try await awaitBandwidthPermit(
                    bytes: Int64(chunkData.count),
                    transfer: transfer
                )
                try await sendFileChunk(chunk, to: connection)
                try await applySpeedLimitIfNeeded(for: transfer.id, transferredBytes: chunkData.count)

                sentBytes += Int64(chunkData.count)
                chunkIndex += 1

                publishActiveTransferProgress(transfer, transferredBytes: sentBytes)
                acknowledgeClassicPauseRequestIfNeeded(for: transfer)

                logger.debug("📤 发送块 \(chunkIndex): \(chunkData.count) 字节")
            }

            try await waitUntilTransferCanProceed(transfer)

            let sourceDigest: Data
            if startOffset == 0 {
                sourceDigest = try await fileReader.finalizeAndClose()
            } else {
                sourceDigest = try await fileReader.hashWholeFileAndClose()
            }
            guard let expectedFileHash = transfer.fileHash,
                  Self.sha256Hex(sourceDigest) == expectedFileHash else {
                throw FileTransferError.integrityCheckFailed
            }
            try await sendTransferComplete(to: connection)
            logClassicReceiptPhase("all_chunks_sent", transferId: transfer.id)
        } catch {
            let operationError = error
            do {
                try await fileReader.close()
            } catch {
                logger.error("Classic transfer source close failed after send failure")
                throw FileTransferError.sourceFileCloseFailed
            }
            throw operationError
        }
    }

 /// 分块接收文件 - 支持断点续传
    private func receiveFileInChunks(
        transfer: FileTransfer,
        securityContext: ClassicTransferSecurityContext,
        from connection: NWConnection,
        ioHandle: InboundFileTransferIOHandle,
        negotiatedChunkSize: Int,
        startOffset: Int64 = 0
    ) async throws -> Data {
        defer { clearSpeedLimitState(for: transfer.id) }
        var receivedBytes: Int64 = startOffset
        let totalBytes = transfer.fileSize
        do {
            try ClassicTransferMetadataContract.validateResumeOffset(
                startOffset,
                fileSize: totalBytes,
                declaredChunkSize: negotiatedChunkSize
            )
        } catch {
            throw FileTransferError.invalidHeader
        }
        var expectedChunkIndex = Int(startOffset / Int64(negotiatedChunkSize))

        transfer.status = .transferring

        while receivedBytes < totalBytes {
            try await waitUntilTransferCanProceed(transfer)

            let chunk = try await receiveFileChunk(from: connection)
            try await applySpeedLimitIfNeeded(for: transfer.id, transferredBytes: chunk.size)

            let decompressedOutputLimit: Int
            do {
                try ClassicTransferChunkContract.validateSequence(
                    chunkIndex: chunk.index,
                    expectedChunkIndex: expectedChunkIndex
                )
                decompressedOutputLimit = try ClassicTransferChunkContract.decompressedOutputLimit(
                    declaredChunkSize: chunk.size,
                    receivedBytes: receivedBytes,
                    declaredFileSize: totalBytes,
                    negotiatedChunkSize: negotiatedChunkSize,
                    maximumChunkSize: maxChunkSizeBytes
                )
            } catch {
                throw FileTransferError.invalidHeader
            }

            guard let nonce = chunk.nonce, let authenticationTag = chunk.authenticationTag else {
                throw FileTransferError.invalidHeader
            }
            let decrypted: Data
            do {
                decrypted = try await ClassicTransferChunkCryptoWorker.shared.open(
                    ciphertext: chunk.data,
                    nonce: nonce,
                    tag: authenticationTag,
                    using: securityContext.transferKey,
                    maximumCiphertextSize: maxMessageBytes
                )
            } catch is CancellationError {
                throw FileTransferError.transferCancelled
            } catch {
                throw FileTransferError.invalidHeader
            }
            let bytesToWrite: Data
            if transfer.compression == "zlib" {
                do {
                    bytesToWrite = try await ClassicTransferZlibDecompressionWorker.shared.decompress(
                        decrypted,
                        maximumOutputSize: decompressedOutputLimit
                    )
                } catch is CancellationError {
                    throw FileTransferError.transferCancelled
                } catch {
                    throw FileTransferError.invalidHeader
                }
            } else {
                bytesToWrite = decrypted
            }
            do {
                try ClassicTransferChunkContract.validateDecodedChunkSize(
                    bytesToWrite.count,
                    declaredChunkSize: chunk.size
                )
            } catch {
                throw FileTransferError.invalidHeader
            }

            _ = try await InboundFileTransferIOActor.shared.write(
                bytesToWrite,
                atOffset: UInt64(receivedBytes),
                using: ioHandle
            )
            receivedBytes += Int64(bytesToWrite.count)
            expectedChunkIndex += 1

            publishActiveTransferProgress(transfer, transferredBytes: receivedBytes)
            acknowledgeClassicPauseRequestIfNeeded(for: transfer)

            logger.debug("📥 接收块 \(chunk.index): \(chunk.size) 字节")
        }

        try await waitUntilTransferCanProceed(transfer)

        do {
            try ClassicTransferChunkContract.validateCompletion(
                receivedBytes: receivedBytes,
                declaredFileSize: totalBytes
            )
        } catch {
            throw FileTransferError.invalidHeader
        }

        logClassicReceiptPhase("all_chunks_received", transferId: transfer.id)

        try await receiveTransferComplete(from: connection)
        logClassicReceiptPhase("hash_verification_started", transferId: transfer.id)
        let digest = try await InboundFileTransferIOActor.shared.closeAndDigest(using: ioHandle)
        logClassicReceiptPhase("hash_verification_completed", transferId: transfer.id)
        return digest
    }

 /// 发送文件块
    private func sendFileChunk(_ chunk: FileChunk, to connection: NWConnection) async throws {
        let chunkData = try await ClassicTransferJSONWorker.shared.encode(
            chunk,
            maximumOutputSize: maxMessageBytes
        )
        let header = createHeader(type: .chunk, length: chunkData.count)

        try await sendData(header + chunkData, to: connection)
    }

 /// 接收文件块
    private func receiveFileChunk(from connection: NWConnection) async throws -> FileChunk {
 // 接收头部
        let headerData = try await receiveData(
            length: 8,
            from: connection,
            timeout: ClassicTransferInboundPolicy.frameIdleTimeoutSeconds
        )
        let header = parseHeader(headerData)

        guard header.type == .chunk else {
            throw FileTransferError.invalidHeader
        }
        guard header.length >= 0, header.length <= maxMessageBytes else {
            throw FileTransferError.invalidHeader
        }

 // 接收块数据
        let chunkData = try await receiveData(
            length: header.length,
            from: connection,
            timeout: ClassicTransferInboundPolicy.frameIdleTimeoutSeconds
        )
        let chunk = try await ClassicTransferJSONWorker.shared.decode(
            FileChunk.self,
            from: chunkData,
            maximumInputSize: maxMessageBytes
        )
        if chunk.size <= 0 || chunk.size > maxChunkSizeBytes {
            throw FileTransferError.invalidHeader
        }
        guard let nonce = chunk.nonce, nonce.count == 12,
              let tag = chunk.authenticationTag, !tag.isEmpty else {
            throw FileTransferError.invalidHeader
        }
        return chunk
    }

 /// 发送传输完成信号
    private func sendTransferComplete(to connection: NWConnection) async throws {
        let header = createHeader(type: .complete, length: 0)
        try await sendData(header, to: connection)
    }

 /// 接收传输完成信号
    private func receiveTransferComplete(from connection: NWConnection) async throws {
        let headerData = try await receiveData(
            length: 8,
            from: connection,
            timeout: ClassicTransferInboundPolicy.frameIdleTimeoutSeconds
        )
        let header = parseHeader(headerData)

        guard header.type == .complete, header.length == 0 else {
            throw FileTransferError.invalidHeader
        }
    }

    /// 发送端等待接收端“落盘回执”
    private func waitForTransferReceipt(
        from connection: NWConnection,
        securityContext: ClassicTransferSecurityContext,
        expectedTransferId: String,
        expectedFileSize: Int64,
        expectedFileHash: String?
    ) async throws -> FileTransferReceipt {
        let headerData: Data
        do {
            headerData = try await receiveData(length: 8, from: connection, timeout: receiptWaitTimeoutSeconds)
        } catch FileTransferError.timeout {
            logClassicReceiptPhase(FileTransferReceiptWaitStage.headerTimeout.rawValue, transferId: expectedTransferId)
            throw FileTransferError.receiptWaitFailed(stage: .headerTimeout, details: nil)
        }
        let header = parseHeader(headerData)
        guard header.type == .receipt else {
            throw FileTransferError.receiverNotConfirmed
        }
        guard header.length > 0, header.length <= maxMessageBytes else {
            throw FileTransferError.invalidHeader
        }

        let payload: Data
        do {
            payload = try await receiveData(length: header.length, from: connection, timeout: receiptWaitTimeoutSeconds)
        } catch FileTransferError.timeout {
            logClassicReceiptPhase(FileTransferReceiptWaitStage.payloadTimeout.rawValue, transferId: expectedTransferId)
            throw FileTransferError.receiptWaitFailed(stage: .payloadTimeout, details: nil)
        }
        let receipt = try await ClassicTransferJSONWorker.shared.decode(
            FileTransferReceipt.self,
            from: payload,
            maximumInputSize: maxMessageBytes
        )
        do {
            try ClassicTransferMetadataContract.validateSecurityVersion(receipt.securityVersion)
            try ClassicTransferMetadataContract.validateTransferIdentifier(receipt.transferId)
            try ClassicTransferMetadataContract.validateVisibleField(
                receipt.error,
                maximumUTF8Length: 1_024
            )
            if let fileHash = receipt.fileHash {
                try ClassicTransferMetadataContract.validateSHA256Hex(fileHash)
            }
        } catch {
            throw FileTransferError.receiptWaitFailed(stage: .authFailed, details: nil)
        }
        let unsignedReceipt = FileTransferReceipt(
            transferId: receipt.transferId,
            success: receipt.success,
            receivedBytes: receipt.receivedBytes,
            fileHash: receipt.fileHash,
            error: receipt.error,
            securityVersion: receipt.securityVersion,
            authTag: nil
        )
        guard receipt.transferId == expectedTransferId else {
            throw FileTransferError.invalidHeader
        }
        guard isValidAuthenticationTag(
            receipt.authTag,
            payload: try receiptAuthenticationInput(unsignedReceipt),
            key: securityContext.transferKey
        ) else {
            logClassicReceiptPhase(FileTransferReceiptWaitStage.authFailed.rawValue, transferId: expectedTransferId)
            throw FileTransferError.receiptWaitFailed(stage: .authFailed, details: nil)
        }
        guard receipt.success else {
            logger.error("❌ 接收端拒绝传输")
            logClassicReceiptPhase(FileTransferReceiptWaitStage.receiverRejected.rawValue, transferId: expectedTransferId)
            throw FileTransferError.receiptWaitFailed(stage: .receiverRejected, details: receipt.error)
        }
        guard receipt.receivedBytes == expectedFileSize else {
            logger.error("❌ 接收端字节数不一致: expected=\(expectedFileSize) got=\(receipt.receivedBytes)")
            throw FileTransferError.receiverNotConfirmed
        }

        do {
            try ClassicTransferReceiptContract.validateSuccessfulFileHash(
                receipt.fileHash,
                expected: expectedFileHash
            )
        } catch {
            logger.error("❌ 接收端哈希缺失或不一致")
            throw FileTransferError.integrityCheckFailed
        }

        return receipt
    }

    /// 接收端发送落盘回执
    private func sendTransferReceipt(
        _ receipt: FileTransferReceipt,
        securityContext: ClassicTransferSecurityContext,
        to connection: NWConnection
    ) async throws {
        logClassicReceiptPhase("receipt_send_attempted", transferId: receipt.transferId)
        let unsignedReceipt = FileTransferReceipt(
            transferId: receipt.transferId,
            success: receipt.success,
            receivedBytes: receipt.receivedBytes,
            fileHash: receipt.fileHash,
            error: receipt.error,
            securityVersion: receipt.securityVersion ?? ClassicTransferInboundPolicy.currentSecurityVersion,
            authTag: nil
        )
        let signedReceipt = FileTransferReceipt(
            transferId: unsignedReceipt.transferId,
            success: unsignedReceipt.success,
            receivedBytes: unsignedReceipt.receivedBytes,
            fileHash: unsignedReceipt.fileHash,
            error: unsignedReceipt.error,
            securityVersion: unsignedReceipt.securityVersion,
            authTag: authenticationTag(
                for: try receiptAuthenticationInput(unsignedReceipt),
                using: securityContext.transferKey
            )
        )
        let payload = try await ClassicTransferJSONWorker.shared.encode(
            signedReceipt,
            maximumOutputSize: maxMessageBytes
        )
        let header = createHeader(type: .receipt, length: payload.count)
        do {
            try await sendData(header + payload, to: connection)
            logClassicReceiptPhase("receipt_send_succeeded", transferId: receipt.transferId)
            RemoteControlSmokeStatusWriter.append(
                "file-transfer receipt-sent transfer=\(Self.sanitizeSmokeField(receipt.transferId)) success=\(receipt.success ? 1 : 0)"
            )
        } catch {
            logClassicReceiptPhase("receipt_send_failed", transferId: receipt.transferId, detail: error.localizedDescription)
            throw error
        }
    }

    private func sendTransferReceiptReliably(
        _ receipt: FileTransferReceipt,
        securityContext: ClassicTransferSecurityContext,
        to connection: NWConnection,
        maxAttempts: Int = 3,
        retryDelayNanoseconds: UInt64 = 250_000_000
    ) async throws {
        var lastError: Error?

        for attempt in 1...maxAttempts {
            do {
                try await sendTransferReceipt(receipt, securityContext: securityContext, to: connection)
                return
            } catch {
                lastError = error
                guard attempt < maxAttempts else { break }
                let receiptError = error as NSError
                logger.warning(
                    "⚠️ 落盘回执发送失败，准备重试: attempt=\(attempt, privacy: .public)/\(maxAttempts, privacy: .public) domain=\(receiptError.domain, privacy: .private) code=\(receiptError.code, privacy: .public)"
                )
                do {
                    try await Task.sleep(nanoseconds: retryDelayNanoseconds)
                } catch is CancellationError {
                    throw FileTransferError.transferCancelled
                }
            }
        }

        throw lastError ?? FileTransferError.connectionClosed
    }

    /// The file is already verified, scanned, and atomically committed when this
    /// method runs. Receipt delivery failure is therefore observable transport
    /// ambiguity, not permission to delete a durable user file.
    private func sendSuccessfulTransferReceiptAfterCommit(
        _ receipt: FileTransferReceipt,
        securityContext: ClassicTransferSecurityContext,
        to connection: NWConnection
    ) async -> FileTransferReceiptDeliveryStatus {
        do {
            try await sendTransferReceiptReliably(
                receipt,
                securityContext: securityContext,
                to: connection
            )
            return .delivered
        } catch {
            let receiptError = error as NSError
            logger.error(
                "❌ 文件已落盘，但成功回执投递失败: domain=\(receiptError.domain, privacy: .private) code=\(receiptError.code, privacy: .public)"
            )
            RemoteControlSmokeStatusWriter.append(
                "file-transfer committed-receipt-unknown transfer=\(Self.sanitizeSmokeField(receipt.transferId))"
            )
            return .unknown
        }
    }

    private func sendFailureReceiptIfPossible(
        transferId: String,
        receivedBytes: Int64 = 0,
        securityVersion: Int?,
        error: Error,
        securityContext: ClassicTransferSecurityContext,
        to connection: NWConnection
    ) async {
        let failureReceipt = FileTransferReceipt(
            transferId: transferId,
            success: false,
            receivedBytes: receivedBytes,
            fileHash: nil,
            error: error.localizedDescription,
            securityVersion: securityVersion,
            authTag: nil
        )

        do {
            try await sendTransferReceiptReliably(
                failureReceipt,
                securityContext: securityContext,
                to: connection
            )
        } catch {
            let receiptError = error as NSError
            logger.error(
                "⚠️ failure receipt 未发送: domain=\(receiptError.domain, privacy: .private) code=\(receiptError.code, privacy: .public)"
            )
        }
    }

    private func logClassicReceiptPhase(
        _ phase: String,
        transferId _: String,
        detail _: String? = nil
    ) {
        logger.info("📨 classic_receipt_phase=\(phase, privacy: .public)")
    }

    private nonisolated static func sanitizeSmokeField(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }

    /// 发送数据
    private func sendData(_ data: Data, to connection: NWConnection) async throws {
        let operation = ClassicTransferSendOperation()
        let timeoutTask = Task.detached(priority: .utility) {
            do {
                try await Task.sleep(
                    for: .seconds(ClassicTransferInboundPolicy.frameSendTimeoutSeconds)
                )
            } catch is CancellationError {
                return
            } catch {
                if operation.fail(error) {
                    connection.cancel()
                }
                return
            }
            if operation.fail(FileTransferError.timeout) {
                connection.cancel()
            }
        }
        defer { timeoutTask.cancel() }
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                operation.install(continuation)
                guard !operation.isCompleted else { return }

                connection.send(content: data, completion: .contentProcessed { error in
                    if let error {
                        if operation.fail(error) {
                            connection.cancel()
                        }
                    } else {
                        _ = operation.succeed()
                    }
                })
            }
        }, onCancel: {
            if operation.fail(FileTransferError.transferCancelled) {
                connection.cancel()
            }
        })
    }

 /// 接收数据
    private func receiveData(
        length: Int,
        from connection: NWConnection,
        timeout: TimeInterval? = nil,
        zeroByteDisconnectError: FileTransferError? = nil
    ) async throws -> Data {
        guard length >= 0 else {
            throw FileTransferError.invalidHeader
        }
        let operation = ClassicTransferReceiveOperation(expectedLength: length)
        let timeoutTask: Task<Void, Never>?
        if let timeout, timeout > 0 {
            timeoutTask = Task.detached(priority: .utility) {
                do {
                    try await Task.sleep(for: .seconds(timeout))
                } catch is CancellationError {
                    return
                } catch {
                    if operation.fail(error) {
                        connection.cancel()
                    }
                    return
                }
                if operation.fail(FileTransferError.timeout) {
                    connection.cancel()
                }
            }
        } else {
            timeoutTask = nil
        }
        defer { timeoutTask?.cancel() }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                operation.install(continuation)
                guard !operation.isCompleted else { return }

                @Sendable func mappedReceiveError(_ error: Error) -> Error {
                    if operation.receivedByteCount == 0,
                       let zeroByteDisconnectError,
                       ClassicTransferPeerResolutionPolicy.isInboundPreMetadataDisconnect(error) {
                        return zeroByteDisconnectError
                    }
                    return error
                }

                @Sendable func receiveMore() {
                    guard let remaining = operation.remainingLength(), remaining > 0 else { return }
                    connection.receive(
                        minimumIncompleteLength: 1,
                        maximumLength: remaining
                    ) { data, _, isComplete, error in
                        guard !operation.isCompleted else { return }
                        if let error {
                            _ = operation.fail(mappedReceiveError(error))
                            return
                        }
                        if let data, !data.isEmpty {
                            switch operation.append(data) {
                            case .completed, .ignoredAfterCompletion:
                                return
                            case .overflow:
                                if operation.fail(FileTransferError.invalidHeader) {
                                    connection.cancel()
                                }
                                return
                            case .pending:
                                break
                            }
                        }
                        if isComplete {
                            _ = operation.fail(mappedReceiveError(FileTransferError.connectionClosed))
                            return
                        }
                        guard !operation.isCompleted else { return }
                        receiveMore()
                    }
                }

                receiveMore()
            }
        }, onCancel: {
            if operation.fail(CancellationError()) {
                connection.cancel()
            }
        })
    }

    private func metadataAuthenticationInput(_ metadata: FileMetadata) throws -> Data {
        try ClassicTransferCanonicalTranscript.metadata(
            transferID: metadata.transferId,
            fileName: metadata.fileName,
            fileSize: metadata.fileSize,
            fileHash: metadata.fileHash,
            chunkSize: metadata.chunkSize,
            securityVersion: metadata.securityVersion ?? 0,
            compression: metadata.compression,
            senderDeviceID: metadata.senderDeviceId,
            senderDeviceName: metadata.senderDeviceName,
            senderPlatform: metadata.senderPlatform,
            senderOSVersion: metadata.senderOSVersion,
            senderModelName: metadata.senderModelName,
            senderChip: metadata.senderChip
        )
    }

    private func receiptAuthenticationInput(_ receipt: FileTransferReceipt) throws -> Data {
        try ClassicTransferCanonicalTranscript.receipt(
            transferID: receipt.transferId,
            success: receipt.success,
            receivedBytes: receipt.receivedBytes,
            fileHash: receipt.fileHash,
            error: receipt.error,
            securityVersion: receipt.securityVersion ?? 0
        )
    }

    private func resumeRequestAuthenticationInput(_ request: ResumeRequestPayload) throws -> Data {
        try ClassicTransferCanonicalTranscript.resumeRequest(
            transferID: request.transferId,
            senderDeviceID: request.senderDeviceId,
            resumeOffset: request.resumeOffset,
            securityVersion: request.securityVersion
        )
    }

    private func resumeAckAuthenticationInput(_ ack: ResumeAckPayload) throws -> Data {
        try ClassicTransferCanonicalTranscript.resumeAcknowledgment(
            transferID: ack.transferId,
            accepted: ack.accepted,
            resumeOffset: ack.resumeOffset,
            error: ack.error,
            securityVersion: ack.securityVersion
        )
    }

    private func authenticationTag(for payload: Data, using key: SymmetricKey) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: payload, using: key))
    }

    private func isValidAuthenticationTag(_ tag: Data?, payload: Data, key: SymmetricKey) -> Bool {
        ClassicTransferAuthenticationContract.isValidHMACSHA256(
            tag,
            authenticating: payload,
            using: key
        )
    }

 /// 创建协议头部
    private func createHeader(type: FileTransferWireMessageType, length: Int) -> Data {
        var header = Data()
        header.append(contentsOf: withUnsafeBytes(of: type.rawValue.bigEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt32(length).bigEndian) { Array($0) })
        return header
    }

 /// 解析协议头部
    private func parseHeader(_ data: Data) -> (type: FileTransferWireMessageType, length: Int) {
        let typeValue = data.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        let length = data.suffix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }

        let type = FileTransferWireMessageType(rawValue: typeValue) ?? .unknown
        return (type: type, length: Int(length))
    }

    private func sanitizeIncomingFileName(_ raw: String) -> String {
        FileTransferPathPolicy.sanitizedFileName(raw)
    }

    private static func classicInboundPartialDirectory() throws -> URL {
        guard let directory = FileTransferDirectoryLayout.classicInboundPartialDirectory() else {
            throw InboundFileTransferIOError.destinationUnavailable
        }
        return directory
    }

    private static func classicInboundPartialURL() throws -> URL {
        try classicInboundPartialDirectory().appendingPathComponent(
            ".skybridge-classic-\(UUID().uuidString).partial",
            isDirectory: false
        )
    }

    private static func isIsolatedClassicInboundPartial(_ url: URL) -> Bool {
        guard let directory = FileTransferDirectoryLayout.classicInboundPartialDirectory() else {
            return false
        }
        return url.standardizedFileURL.deletingLastPathComponent().path
            == directory.standardizedFileURL.path
            && url.lastPathComponent.hasPrefix(".skybridge-classic-")
            && url.pathExtension == "partial"
    }

    private func preparedInboundDestinationDirectory() async throws -> URL {
        let candidates = FileTransferDirectoryLayout.receiveDirectoryCandidates(
            explicitDirectory: receiveBaseDirectory,
            defaultDirectory: Self.defaultReceiveDirectory(),
            applicationSupportDirectory: Self.appSupportReceiveDirectory()
        )
        let directory = try await InboundFileTransferIOActor.shared.prepareFirstWritableDirectory(
            from: candidates
        )
        if receiveBaseDirectory?.standardizedFileURL.path != directory.standardizedFileURL.path {
            receiveBaseDirectory = directory
        }
        return directory
    }

    private nonisolated static func sha256Hex(_ digest: Data) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func defaultReceiveDirectory() -> URL? {
        FileTransferDirectoryLayout.defaultReceiveDirectory()
    }

    private static func appSupportReceiveDirectory() -> URL? {
        FileTransferDirectoryLayout.applicationSupportReceiveDirectory()
    }

    // MARK: - External (non-NWConnection) transfers (WebRTC DataChannel)

    /// Registers transport-owned work before any UI transfer record exists.
    /// The lease is released only after source descriptors, approval work, and
    /// partial-file cleanup have quiesced, allowing stop() to prove shutdown.
    func beginExternalTransportOperation(
        cancellationHandler: @escaping @MainActor () -> Void
    ) -> ExternalTransportOperationToken? {
        guard acceptsNewTransfers,
              externalTransportOperations.count < maxConcurrentTransfers else {
            return nil
        }
        let token = ExternalTransportOperationToken(
            identifier: UUID(),
            lifecycleGeneration: lifecycleGeneration
        )
        externalTransportOperations[token.identifier] = (token, cancellationHandler)
        return token
    }

    func endExternalTransportOperation(_ token: ExternalTransportOperationToken) {
        guard let current = externalTransportOperations[token.identifier],
              current.token == token else {
            preconditionFailure("External transport operation ended without exact registration")
        }
        externalTransportOperations.removeValue(forKey: token.identifier)
        resumeExternalOperationDrainIfNeeded()
    }

    /// WebRTC 入站：创建一个“外部传输”的接收记录（用于 UI 展示与统计）。
    @discardableResult
    public func beginExternalInboundTransfer(
        transferId: String,
        fileName: String,
        fileSize: Int64,
        fromDeviceId: String,
        fromDeviceName: String?,
        cancellationHandler: @escaping @MainActor () -> Void
    ) -> ExternalTransferToken? {
        guard acceptsNewTransfers,
              activeTransfers[transferId] == nil,
              externalTransferTokensByTransferID[transferId] == nil else {
            return nil
        }

        let transfer = FileTransfer(
            id: transferId,
            fileName: fileName,
            fileSize: fileSize,
            deviceId: fromDeviceId,
            direction: .incoming,
            status: .preparing
        )
        transfer.deviceName = fromDeviceName
        let token = ExternalTransferToken(
            identifier: UUID(),
            transferID: transferId,
            lifecycleGeneration: lifecycleGeneration,
            direction: .incoming
        )
        externalTransferTokensByTransferID[transferId] = token
        externalTransferCancellationHandlersByTransferID[transferId] = cancellationHandler
        registerActiveTransfer(transfer)
        updateTransferringStatus()
        return token
    }

    /// WebRTC 入站：更新接收进度（由 CrossNetworkConnectionManager 推送）。
    public func updateExternalInboundProgress(
        token: ExternalTransferToken,
        transferredBytes: Int64
    ) {
        guard let transfer = activeExternalTransferForProgress(
            matching: token,
            direction: .incoming
        ) else {
            return
        }
        transfer.status = .transferring
        publishActiveTransferProgress(transfer, transferredBytes: transferredBytes)
    }

    /// WebRTC 入站：完成并落盘后调用。
    public func completeExternalInboundTransfer(
        token: ExternalTransferToken,
        savedTo url: URL,
        receiptDeliveryStatus: FileTransferReceiptDeliveryStatus,
        operationalWarning: String? = nil
    ) {
        guard let transfer = activeExternalTransfer(matching: token, direction: .incoming) else {
            return
        }
        transfer.status = .completed
        transfer.progress = 1.0
        transfer.completedAt = Date()
        transfer.localPath = url
        transfer.receiptDeliveryStatus = receiptDeliveryStatus
        transfer.error = operationalWarning
        lastTransferActivityAt = Date()
        moveToHistory(transfer)
        postTransferCompletedNotification(for: transfer, direction: "incoming", localPath: url.path)
        updateTransferringStatus()
    }

    public func failExternalTransfer(
        token: ExternalTransferToken,
        errorMessage: String,
        receiptDeliveryStatus: FileTransferReceiptDeliveryStatus? = nil
    ) {
        guard let transfer = activeExternalTransfer(matching: token, direction: token.direction) else {
            return
        }
        transfer.status = .failed
        transfer.error = errorMessage
        transfer.receiptDeliveryStatus = receiptDeliveryStatus
        transfer.completedAt = Date()
        lastTransferActivityAt = Date()
        moveToHistory(transfer)
        postTransferFailedNotification(for: transfer, errorMessage: errorMessage)
        updateTransferringStatus()
    }

    @available(macOS 14.0, iOS 17.0, *)
    func approveInboundWebRTCFileTransfer(
        _ request: WebRTCInboundFileTransferApprovalRequest
    ) async -> WebRTCInboundFileTransferApprovalDecision {
        #if os(macOS)
        let senderDeviceId = request.senderDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !senderDeviceId.isEmpty else {
            return .rejected(reason: "inbound_file_transfer_missing_sender_identity")
        }

        let approvalRequest = InboundFileTransferApprovalService.Request(
            transferId: request.transferId,
            fileName: request.fileName,
            fileSize: request.fileSize,
            chunkSize: request.chunkSize,
            totalChunks: request.totalChunks,
            senderDeviceId: senderDeviceId,
            senderDeviceName: request.senderDeviceName,
            endpointDescription: request.endpointDescription,
            destinationDirectoryPath: request.destinationDirectoryPath,
            proposedSavePath: request.proposedSavePath
        )
        let decision = await InboundFileTransferApprovalService.shared.decide(for: approvalRequest)
        return Self.webRTCInboundFileTransferApprovalDecision(from: decision)
        #else
        return .rejected(reason: WebRTCInboundFileTransferSupport.explicitApprovalRequiredMessage)
        #endif
    }

    #if os(macOS)
    @available(macOS 14.0, *)
    static func webRTCInboundFileTransferApprovalDecision(
        from decision: InboundFileTransferApprovalService.Decision
    ) -> WebRTCInboundFileTransferApprovalDecision {
        switch decision {
        case .allowOnce:
            return .approved
        case .reject:
            return .rejected(reason: "operator_rejected_inbound_file_transfer")
        }
    }
    #endif

    /// WebRTC 出站：创建一个“外部传输”的发送记录（用于 UI 展示与统计）。
    @discardableResult
    public func beginExternalOutboundTransfer(
        transferId: String,
        fileURL: URL,
        fileSize: Int64,
        toDeviceId: String,
        toDeviceName: String?,
        cancellationHandler: @escaping @MainActor () -> Void
    ) -> ExternalTransferToken? {
        guard acceptsNewTransfers,
              activeTransfers[transferId] == nil,
              externalTransferTokensByTransferID[transferId] == nil else {
            return nil
        }

        let transfer = FileTransfer(
            id: transferId,
            fileName: fileURL.lastPathComponent,
            fileSize: fileSize,
            deviceId: toDeviceId,
            direction: .outgoing,
            status: .preparing
        )
        transfer.localPath = fileURL
        transfer.deviceName = toDeviceName
        let token = ExternalTransferToken(
            identifier: UUID(),
            transferID: transferId,
            lifecycleGeneration: lifecycleGeneration,
            direction: .outgoing
        )
        externalTransferTokensByTransferID[transferId] = token
        externalTransferCancellationHandlersByTransferID[transferId] = cancellationHandler
        registerActiveTransfer(transfer)
        updateTransferringStatus()
        return token
    }

    public func updateExternalOutboundProgress(
        token: ExternalTransferToken,
        transferredBytes: Int64
    ) {
        guard let transfer = activeExternalTransferForProgress(
            matching: token,
            direction: .outgoing
        ) else {
            return
        }
        transfer.status = .transferring
        publishActiveTransferProgress(transfer, transferredBytes: transferredBytes)
    }

    public func completeExternalOutboundTransfer(token: ExternalTransferToken) {
        guard let transfer = activeExternalTransfer(matching: token, direction: .outgoing) else {
            return
        }
        transfer.status = .completed
        transfer.progress = 1.0
        transfer.completedAt = Date()
        lastTransferActivityAt = Date()
        moveToHistory(transfer)
        postTransferCompletedNotification(for: transfer, direction: "outgoing", localPath: transfer.localPath?.path)
        updateTransferringStatus()
    }

    public func failExternalOutboundTransfer(
        token: ExternalTransferToken,
        errorMessage: String,
        receiptDeliveryStatus: FileTransferReceiptDeliveryStatus? = nil
    ) {
        failExternalTransfer(
            token: token,
            errorMessage: errorMessage,
            receiptDeliveryStatus: receiptDeliveryStatus
        )
    }

    public func cancelExternalOutboundTransfer(token: ExternalTransferToken) {
        guard let transfer = activeExternalTransfer(matching: token, direction: .outgoing) else {
            return
        }
        let cancellationMessage = FileTransferError.transferCancelled.localizedDescription
        transfer.status = .cancelled
        transfer.error = cancellationMessage
        transfer.completedAt = Date()
        lastTransferActivityAt = Date()
        moveToHistory(transfer)
        postTransferFailedNotification(for: transfer, errorMessage: cancellationMessage)
        updateTransferringStatus()
    }

    private func activeExternalTransferForProgress(
        matching token: ExternalTransferToken,
        direction: TransferDirection
    ) -> FileTransfer? {
        guard acceptsNewTransfers,
              token.lifecycleGeneration == lifecycleGeneration else {
            return nil
        }
        return activeExternalTransfer(matching: token, direction: direction)
    }

    private func activeExternalTransfer(
        matching token: ExternalTransferToken,
        direction: TransferDirection
    ) -> FileTransfer? {
        guard token.direction == direction,
              Self.externalTransferTokenOwnsCurrentSlot(
                currentToken: externalTransferTokensByTransferID[token.transferID],
                expectedToken: token
              ),
              let transfer = activeTransfers[token.transferID],
              transfer.direction == direction,
              transfer.status == .preparing || transfer.status == .transferring else {
            return nil
        }
        return transfer
    }

    /// 移动到历史记录
    private func moveToHistory(_ transfer: FileTransfer) {
        guard activeTransfers[transfer.id] === transfer else { return }
        activeTransfers.removeValue(forKey: transfer.id)
        let removedExternalToken = externalTransferTokensByTransferID.removeValue(
            forKey: transfer.id
        )
        externalTransferCancellationHandlersByTransferID.removeValue(forKey: transfer.id)
        classicPauseRequests.removeValue(forKey: transfer.id)?.abort()
        classicConnectionsByTransferID.removeValue(forKey: transfer.id)
        updateTransferPowerAssertion()
        if removedExternalToken != nil {
            resumeExternalOperationDrainIfNeeded()
        }
        guard keepTransferHistory else { return }
        transferHistory.append(transfer)

 // 限制历史记录数量
        if transferHistory.count > 100 {
            transferHistory = Array(transferHistory.suffix(100))
        }
        enqueueHistoryAppend(PersistedFileTransferHistoryEntry(transfer))
    }

    private func resumeExternalOperationDrainIfNeeded() {
        guard externalTransferTokensByTransferID.isEmpty,
              externalTransportOperations.isEmpty else {
            return
        }
        let continuations = Array(externalOperationDrainContinuations.values)
        externalOperationDrainContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    private func registerActiveTransfer(_ transfer: FileTransfer) {
        precondition(
            activeTransfers[transfer.id] == nil || activeTransfers[transfer.id] === transfer,
            "Classic transfer identifier already belongs to another active transfer"
        )
        activeTransfers[transfer.id] = transfer
        updateTransferPowerAssertion()
        updateTransferringStatus()
    }

    private func publishActiveTransferProgress(_ transfer: FileTransfer, transferredBytes: Int64) {
        guard activeTransfers[transfer.id] === transfer else { return }
        transfer.updateProgress(transferredBytes: transferredBytes)
        activeTransfers[transfer.id] = transfer
        lastTransferActivityAt = Date()
        updateTransferringStatus()
        postTransferProgressNotification(for: transfer)
    }

    private func updateTransferPowerAssertion() {
        powerAssertion.update(
            shouldKeepAwake: keepSystemAwakeDuringTransfer,
            hasActiveTransfers: !activeTransfers.isEmpty
        )
    }

    func awaitHistoryPersistence() async {
        while true {
            let expectedGeneration = historyRequestGeneration
            let task = historyPersistenceTask
            await task?.value
            guard expectedGeneration != historyRequestGeneration else { return }
        }
    }

    private func enqueueHistoryLoad() {
        let requestGeneration = nextHistoryRequestGeneration()
        let previousTask = historyPersistenceTask
        let repository = historyRepository
        historyPersistenceTask = Task { @MainActor [weak self] in
            await previousTask?.value
            do {
                let snapshot = try await repository.load()
                self?.applyHistorySnapshot(snapshot, requestGeneration: requestGeneration)
            } catch {
                self?.recordHistoryPersistenceFailure(
                    operation: .load,
                    error: error,
                    requestGeneration: requestGeneration
                )
            }
        }
    }

    private func enqueueHistoryAppend(_ entry: PersistedFileTransferHistoryEntry) {
        let requestGeneration = nextHistoryRequestGeneration()
        let previousTask = historyPersistenceTask
        let repository = historyRepository
        historyPersistenceTask = Task { @MainActor [weak self] in
            await previousTask?.value
            do {
                let snapshot = try await repository.append(entry)
                self?.applyHistorySnapshot(snapshot, requestGeneration: requestGeneration)
            } catch {
                self?.recordHistoryPersistenceFailure(
                    operation: .append,
                    error: error,
                    requestGeneration: requestGeneration
                )
            }
        }
    }

    private func enqueueHistoryClear() {
        let requestGeneration = nextHistoryRequestGeneration()
        let previousTask = historyPersistenceTask
        let repository = historyRepository
        historyPersistenceTask = Task { @MainActor [weak self] in
            await previousTask?.value
            do {
                let snapshot = try await repository.clear()
                self?.applyHistorySnapshot(snapshot, requestGeneration: requestGeneration)
            } catch {
                self?.recordHistoryPersistenceFailure(
                    operation: .clear,
                    error: error,
                    requestGeneration: requestGeneration
                )
            }
        }
    }

    private func nextHistoryRequestGeneration() -> UInt64 {
        historyRequestGeneration += 1
        return historyRequestGeneration
    }

    private func applyHistorySnapshot(
        _ snapshot: BoundedHistorySnapshot<PersistedFileTransferHistoryEntry>,
        requestGeneration: UInt64
    ) {
        guard requestGeneration == historyRequestGeneration,
              snapshot.generation >= appliedHistoryRepositoryGeneration else {
            return
        }
        appliedHistoryRepositoryGeneration = snapshot.generation
        transferHistory = snapshot.entries.map(\.asRuntimeTransfer)
        historyPersistenceError = nil
        logger.info("📚 传输历史持久化已同步: \(self.transferHistory.count, privacy: .public) 条")
    }

    private func recordHistoryPersistenceFailure(
        operation: FileTransferHistoryPersistenceOperation,
        error: Error,
        requestGeneration: UInt64
    ) {
        guard requestGeneration == historyRequestGeneration else { return }
        let failure = FileTransferHistoryPersistenceFailure(operation: operation, error: error)
        historyPersistenceError = failure
        logger.error(
            "❌ 传输历史持久化失败: operation=\(failure.operation, privacy: .public) domain=\(failure.domain, privacy: .private) code=\(failure.code, privacy: .public)"
        )
    }

    private func postTransferProgressNotification(for transfer: FileTransfer) {
        let progress = max(0.0, min(1.0, transfer.progress))
        let transferredBytes = max(0, min(transfer.transferredBytes, transfer.fileSize))
        let userInfo: [String: Any] = [
            "transferId": transfer.id,
            "fileName": transfer.fileName,
            "progress": progress,
            "speed": transfer.transferSpeed,
            "speedBytesPerSecond": transfer.transferSpeed,
            "transferredBytes": transferredBytes,
            "fileSize": transfer.fileSize,
            "totalBytes": transfer.fileSize,
            "direction": transfer.direction == .outgoing ? "outgoing" : "incoming",
            "deviceName": transfer.deviceName ?? transfer.deviceId
        ]
        NotificationCenter.default.post(
            name: Notification.Name("com.skybridge.fileTransfer.progressUpdated"),
            object: nil,
            userInfo: userInfo
        )
    }

    private func postTransferCompletedNotification(
        for transfer: FileTransfer,
        direction: String,
        localPath: String?
    ) {
        var userInfo: [String: Any] = [
            "transferId": transfer.id,
            "fileName": transfer.fileName,
            "fileSize": transfer.fileSize,
            "deviceName": transfer.deviceName ?? transfer.deviceId,
            "direction": direction
        ]
        if let localPath, !localPath.isEmpty {
            userInfo["localPath"] = localPath
        }

        NotificationCenter.default.post(
            name: Notification.Name("FileTransferCompleted"),
            object: nil,
            userInfo: userInfo
        )
        NotificationCenter.default.post(
            name: Notification.Name("com.skybridge.fileTransfer.completed"),
            object: nil,
            userInfo: userInfo
        )

        #if canImport(UserNotifications)
        if direction == "incoming", Self.canUseUserNotificationsSafely() {
            let content = UNMutableNotificationContent()
            content.title = LocalizationManager.shared.localizedString("notifications.fileReceived.completed")
            content.subtitle = transfer.deviceName ?? transfer.deviceId
            if let localPath, !localPath.isEmpty {
                content.body = String(
                    format: LocalizationManager.shared.localizedString("notifications.fileReceived.savedTo"),
                    locale: LocalizationManager.shared.locale,
                    transfer.fileName,
                    localPath
                )
            } else {
                content.body = String(
                    format: LocalizationManager.shared.localizedString("notifications.fileReceived.completedBody"),
                    locale: LocalizationManager.shared.locale,
                    transfer.fileName
                )
            }
            content.userInfo = userInfo
            let request = UNNotificationRequest(
                identifier: "file-transfer-\(transfer.id)",
                content: content,
                trigger: nil
            )
            Task {
                do {
                    try await UNUserNotificationCenter.current().add(request)
                } catch {
                    let notificationError = error as NSError
                    self.logger.error(
                        "File completion notification failed: domain=\(notificationError.domain, privacy: .private) code=\(notificationError.code)"
                    )
                }
            }
        }
        #endif
    }

    private func postTransferFailedNotification(for transfer: FileTransfer, errorMessage: String) {
        let userInfo: [String: Any] = [
            "transferId": transfer.id,
            "fileName": transfer.fileName,
            "error": errorMessage,
            "deviceName": transfer.deviceName ?? transfer.deviceId
        ]
        NotificationCenter.default.post(
            name: Notification.Name("FileTransferFailed"),
            object: nil,
            userInfo: userInfo
        )
        NotificationCenter.default.post(
            name: Notification.Name("com.skybridge.fileTransfer.failed"),
            object: nil,
            userInfo: userInfo
        )
    }

 /// 更新传输状态
    private func updateTransferringStatus() {
        // Base signal: we are transferring iff there are active transfers.
        if !activeTransfers.isEmpty {
            isTransferring = true
            activityGraceTask?.cancel()
            activityGraceTask = nil
        } else {
            // Grace period: keep isTransferring true briefly after completion so the dashboard has time to show it.
            if let last = lastTransferActivityAt {
                let elapsed = Date().timeIntervalSince(last)
                if elapsed < transferActivityGraceSeconds {
                    isTransferring = true
                    // Re-evaluate after the remaining grace window.
                    activityGraceTask?.cancel()
                    let remaining = transferActivityGraceSeconds - elapsed
                    activityGraceTask = Task { @MainActor in
                        do {
                            try await Task.sleep(for: .seconds(remaining))
                        } catch is CancellationError {
                            return
                        } catch {
                            self.logger.error("Transfer activity grace timer failed")
                            return
                        }
                        self.updateTransferringStatus()
                    }
                } else {
                    isTransferring = false
                }
            } else {
                isTransferring = false
            }
        }

 // 计算总体进度
        if activeTransfers.isEmpty {
            totalProgress = 0.0
        } else {
            let totalBytes = activeTransfers.values.reduce(Int64(0)) { total, transfer in
                total + max(0, transfer.fileSize)
            }
            if totalBytes > 0 {
                let transferredBytes = activeTransfers.values.reduce(Int64(0)) { total, transfer in
                    total + max(0, min(transfer.transferredBytes, transfer.fileSize))
                }
                totalProgress = Double(transferredBytes) / Double(totalBytes)
            } else {
                totalProgress = activeTransfers.values.allSatisfy { $0.progress >= 1.0 } ? 1.0 : 0.0
            }
        }
    }
}

// MARK: - Data扩展（支持resize操作）
// 注意：resize方法已在FileTransferEngine.swift中定义，避免重复声明
