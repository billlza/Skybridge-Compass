import CryptoKit
import Darwin
import Foundation
import Security

extension BoundSessionEvidenceDirectionV2 {
    var rawName: String {
        switch self {
        case .initiatorToResponder:
            "initiator_to_responder"
        case .responderToInitiator:
            "responder_to_initiator"
        }
    }
}

enum BoundSessionEvidenceJournalEventTypeV2: UInt8, CaseIterable, Sendable, Equatable {
    case wireMessageAVerified = 1
    case wireMessageBVerified = 2
    case wireFinishedVerified = 3
    case wireGrantReadyVerified = 4
    case sessionEnabled = 5
    case transferStarted = 6
    case durableCommit = 7
    case receiptIssued = 8
    case receiptVerified = 9
    case transferCompleted = 10

    var rawName: String {
        switch self {
        case .wireMessageAVerified:
            "wire_message_a_verified"
        case .wireMessageBVerified:
            "wire_message_b_verified"
        case .wireFinishedVerified:
            "wire_finished_verified"
        case .wireGrantReadyVerified:
            "wire_grant_ready_verified"
        case .sessionEnabled:
            "session_enabled"
        case .transferStarted:
            "transfer_started"
        case .durableCommit:
            "durable_commit"
        case .receiptIssued:
            "receipt_issued"
        case .receiptVerified:
            "receipt_verified"
        case .transferCompleted:
            "transfer_completed"
        }
    }
}

struct BoundSessionEvidenceJournalEventV2: Sendable, Equatable {
    let sequence: UInt64
    let previousEventSHA256: Data?
    let eventType: BoundSessionEvidenceJournalEventTypeV2
    let direction: BoundSessionEvidenceDirectionV2
    let subjectSHA256: Data
    let wireSHA256: Data?
    let describedAt: String
    let eventSHA256: Data

    fileprivate init(
        sequence: UInt64,
        previousEventSHA256: Data?,
        eventType: BoundSessionEvidenceJournalEventTypeV2,
        direction: BoundSessionEvidenceDirectionV2,
        subjectSHA256: Data,
        wireSHA256: Data?,
        describedAt: String,
        eventSHA256: Data
    ) {
        self.sequence = sequence
        self.previousEventSHA256 = previousEventSHA256
        self.eventType = eventType
        self.direction = direction
        self.subjectSHA256 = subjectSHA256
        self.wireSHA256 = wireSHA256
        self.describedAt = describedAt
        self.eventSHA256 = eventSHA256
    }
}

struct BoundSessionEvidenceJournalSnapshotV2: Sendable, Equatable {
    let endpointID: String
    let journalInstanceSHA256: Data
    let events: [BoundSessionEvidenceJournalEventV2]

    fileprivate init(
        endpointID: String,
        journalInstanceSHA256: Data,
        events: [BoundSessionEvidenceJournalEventV2]
    ) {
        self.endpointID = endpointID
        self.journalInstanceSHA256 = journalInstanceSHA256
        self.events = events
    }
}

enum BoundSessionEvidenceJournalV2Error: Error, LocalizedError, Equatable {
    case invalidConfiguration(String)
    case invalidRoot(String)
    case corruptJournal(String)
    case capacityExceeded
    case pendingCommitRequiresExactRetry
    case io(operation: String, errno: Int32)
    case injectedFault(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let reason):
            "Invalid BoundSession evidence journal configuration: \(reason)"
        case .invalidRoot(let reason):
            "Invalid BoundSession evidence journal root: \(reason)"
        case .corruptJournal(let reason):
            "Corrupt BoundSession evidence journal: \(reason)"
        case .capacityExceeded:
            "BoundSession evidence journal reached its 128-event capacity"
        case .pendingCommitRequiresExactRetry:
            "BoundSession evidence journal has an unresolved exact commit"
        case .io(let operation, let code):
            "BoundSession evidence journal I/O failed during \(operation) (errno \(code))"
        case .injectedFault(let operation):
            "Injected BoundSession evidence journal fault during \(operation)"
        }
    }
}

/// Crash-durable, bounded event journal for the exact V2 event-digest contract.
///
/// One immutable file is committed per event. The retained directory descriptor
/// prevents path replacement after construction. An `EEXIST` retry succeeds only
/// when the existing single-linked regular file is byte-for-byte identical; it
/// then repeats both file and directory `fsync` before reporting success.
final class BoundSessionEvidenceJournalV2: @unchecked Sendable {
    enum FaultForTesting: Sendable, Equatable {
        case eventFileSync(sequence: UInt64)
        case eventDirectorySync(sequence: UInt64)
    }

    private struct InstanceRecord {
        let nonce: Data
        let digest: Data
        let encoded: Data
    }

    private struct PendingEventCommit {
        let event: BoundSessionEvidenceJournalEventV2
        let encoded: Data
    }

    private static let instanceFileName = "journal-instance.bsjv2"
    private static let eventFilePrefix = "event-"
    private static let eventFileSuffix = ".bsev2"
    private static let instanceMagic = Data([0x42, 0x53, 0x4A, 0x49, 0x56, 0x32, 0, 0])
    private static let eventMagic = Data([0x42, 0x53, 0x45, 0x56, 0x32, 0, 0, 0])
    private static let formatVersion: UInt32 = 2
    private static let eventEncodedByteCount = 176
    private static let maximumEventCount = 128
    private static let eventDigestDomain = Data(
        "policy-purpose-bound-session/endpoint-event/v2\0".utf8
    )
    private static let instanceDigestDomain = Data(
        "policy-purpose-bound-session/journal-instance/v2\0".utf8
    )

    private let lock = NSLock()
    private let rootDescriptor: Int32
    private let endpointID: String
    private let identityFingerprint: Data
    private var instance: InstanceRecord
    private var events: [BoundSessionEvidenceJournalEventV2]
    private var pendingCommit: PendingEventCommit?
    private var faultsForTesting: [FaultForTesting]

    init(
        rootURL: URL,
        identityFingerprint: Data,
        faultsForTesting: [FaultForTesting] = []
    ) throws {
        guard identityFingerprint.count == SHA256.byteCount,
              identityFingerprint.contains(where: { $0 != 0 }) else {
            throw BoundSessionEvidenceJournalV2Error.invalidConfiguration(
                "identity fingerprint must be one nonzero SHA-256 value"
            )
        }
        let standardizedRoot = rootURL.standardizedFileURL
        guard standardizedRoot.isFileURL,
              standardizedRoot.path.hasPrefix("/"),
              !standardizedRoot.path.utf8.contains(0) else {
            throw BoundSessionEvidenceJournalV2Error.invalidConfiguration(
                "journal root must be an absolute file URL without NUL"
            )
        }
        let descriptor = Darwin.open(
            standardizedRoot.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw BoundSessionEvidenceJournalV2Error.io(
                operation: "open root",
                errno: errno
            )
        }
        do {
            try Self.validateDirectoryDescriptor(descriptor)
            let endpointID = Self.endpointID(for: identityFingerprint)
            let recovered = try Self.recover(
                rootDescriptor: descriptor,
                endpointID: endpointID,
                identityFingerprint: identityFingerprint
            )
            rootDescriptor = descriptor
            self.endpointID = endpointID
            self.identityFingerprint = identityFingerprint
            instance = recovered.instance
            events = recovered.events
            pendingCommit = nil
            self.faultsForTesting = faultsForTesting
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    deinit {
        _ = Darwin.close(rootDescriptor)
    }

    func append(
        eventType: BoundSessionEvidenceJournalEventTypeV2,
        direction: BoundSessionEvidenceDirectionV2,
        subjectSHA256: Data,
        wireSHA256: Data?,
        describedAt: Date = Date()
    ) throws -> BoundSessionEvidenceJournalEventV2 {
        try lock.withLock {
            guard pendingCommit == nil else {
                throw BoundSessionEvidenceJournalV2Error.pendingCommitRequiresExactRetry
            }
            guard events.count < Self.maximumEventCount else {
                throw BoundSessionEvidenceJournalV2Error.capacityExceeded
            }
            try Self.requireDigest(subjectSHA256, name: "subject")
            if let wireSHA256 {
                try Self.requireDigest(wireSHA256, name: "wire")
            }
            let sequence = UInt64(events.count + 1)
            let previous = events.last?.eventSHA256
            let timestamp = Self.encodeTimestamp(describedAt)
            let digest = Self.eventDigest(
                endpointID: endpointID,
                sequence: sequence,
                previousEventSHA256: previous,
                eventType: eventType,
                direction: direction,
                subjectSHA256: subjectSHA256,
                wireSHA256: wireSHA256
            )
            let event = BoundSessionEvidenceJournalEventV2(
                sequence: sequence,
                previousEventSHA256: previous,
                eventType: eventType,
                direction: direction,
                subjectSHA256: subjectSHA256,
                wireSHA256: wireSHA256,
                describedAt: timestamp,
                eventSHA256: digest
            )
            let encoded = Self.encode(event)
            let pending = PendingEventCommit(event: event, encoded: encoded)
            pendingCommit = pending
            do {
                try commit(pending)
                events.append(event)
                pendingCommit = nil
                return event
            } catch {
                throw error
            }
        }
    }

    /// Resolves only the exact bytes retained after an unknown file/directory
    /// durability outcome. No new event, timestamp, sequence, or filename is used.
    func retryPendingCommit() throws -> BoundSessionEvidenceJournalEventV2 {
        try lock.withLock {
            guard let pendingCommit else {
                throw BoundSessionEvidenceJournalV2Error.invalidConfiguration(
                    "there is no pending journal commit"
                )
            }
            try commit(pendingCommit)
            events.append(pendingCommit.event)
            self.pendingCommit = nil
            return pendingCommit.event
        }
    }

    func snapshot() -> BoundSessionEvidenceJournalSnapshotV2 {
        lock.withLock {
            BoundSessionEvidenceJournalSnapshotV2(
                endpointID: endpointID,
                journalInstanceSHA256: instance.digest,
                events: events
            )
        }
    }

    private func commit(_ pending: PendingEventCommit) throws {
        try commitExactFile(
            named: Self.instanceFileName,
            bytes: instance.encoded,
            eventSequence: nil
        )
        try commitExactFile(
            named: Self.eventFileName(sequence: pending.event.sequence),
            bytes: pending.encoded,
            eventSequence: pending.event.sequence
        )
    }

    private func commitExactFile(
        named fileName: String,
        bytes: Data,
        eventSequence: UInt64?
    ) throws {
        let descriptor = fileName.withCString {
            openat(
                rootDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        if descriptor >= 0 {
            do {
                try Self.writeAll(bytes, to: descriptor)
                try Self.validateFileDescriptor(descriptor, expectedByteCount: bytes.count)
                if let eventSequence,
                   faultsForTesting.first == .eventFileSync(sequence: eventSequence) {
                    faultsForTesting.removeFirst()
                    throw BoundSessionEvidenceJournalV2Error.injectedFault(
                        "event file sync"
                    )
                }
                try Self.sync(descriptor, operation: "file sync")
                try Self.close(descriptor, operation: "file close")
            } catch {
                _ = Darwin.close(descriptor)
                throw error
            }
        } else if errno == EEXIST {
            let existing = try openAndReadExactFile(
                named: fileName,
                maximumByteCount: max(bytes.count, Self.eventEncodedByteCount)
            )
            guard existing.bytes == bytes else {
                _ = Darwin.close(existing.descriptor)
                throw BoundSessionEvidenceJournalV2Error.corruptJournal(
                    "existing exact-retry file differs: \(fileName)"
                )
            }
            do {
                try Self.sync(existing.descriptor, operation: "existing file retry sync")
                try Self.close(existing.descriptor, operation: "existing file retry close")
            } catch {
                _ = Darwin.close(existing.descriptor)
                throw error
            }
        } else {
            throw BoundSessionEvidenceJournalV2Error.io(
                operation: "exclusive file create",
                errno: errno
            )
        }

        if let eventSequence,
           faultsForTesting.first == .eventDirectorySync(sequence: eventSequence) {
            faultsForTesting.removeFirst()
            throw BoundSessionEvidenceJournalV2Error.injectedFault(
                "event directory sync"
            )
        }
        try Self.sync(rootDescriptor, operation: "parent directory sync")
    }

    private func openAndReadExactFile(
        named fileName: String,
        maximumByteCount: Int
    ) throws -> (descriptor: Int32, bytes: Data) {
        let descriptor = fileName.withCString {
            openat(rootDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw BoundSessionEvidenceJournalV2Error.io(
                operation: "open existing file",
                errno: errno
            )
        }
        do {
            let bytes = try Self.readAll(
                from: descriptor,
                maximumByteCount: maximumByteCount
            )
            try Self.validateFileDescriptor(descriptor, expectedByteCount: bytes.count)
            return (descriptor, bytes)
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private static func recover(
        rootDescriptor: Int32,
        endpointID: String,
        identityFingerprint: Data
    ) throws -> (instance: InstanceRecord, events: [BoundSessionEvidenceJournalEventV2]) {
        let names = try directoryEntryNames(rootDescriptor)
        let allowedNames = names.filter { $0 != instanceFileName }
        for name in allowedNames where eventSequence(from: name) == nil {
            throw BoundSessionEvidenceJournalV2Error.corruptJournal(
                "unexpected entry in dedicated journal root: \(name)"
            )
        }
        guard names.count <= maximumEventCount + 1 else {
            throw BoundSessionEvidenceJournalV2Error.capacityExceeded
        }
        guard names.contains(instanceFileName) else {
            guard allowedNames.isEmpty else {
                throw BoundSessionEvidenceJournalV2Error.corruptJournal(
                    "event exists without journal instance"
                )
            }
            let nonce = try secureRandom(byteCount: SHA256.byteCount)
            return (
                makeInstance(
                    endpointID: endpointID,
                    identityFingerprint: identityFingerprint,
                    nonce: nonce
                ),
                []
            )
        }

        let instanceBytes = try readExactFile(
            rootDescriptor: rootDescriptor,
            name: instanceFileName,
            maximumByteCount: 256
        )
        let instance = try decodeInstance(
            instanceBytes,
            expectedEndpointID: endpointID,
            expectedIdentityFingerprint: identityFingerprint
        )
        let sequencedNames = try allowedNames.map { name in
            guard let sequence = eventSequence(from: name) else {
                throw BoundSessionEvidenceJournalV2Error.corruptJournal(
                    "invalid event filename"
                )
            }
            return (sequence: sequence, name: name)
        }
        let orderedNames = sequencedNames.sorted { $0.sequence < $1.sequence }
        var events: [BoundSessionEvidenceJournalEventV2] = []
        events.reserveCapacity(orderedNames.count)
        for (index, item) in orderedNames.enumerated() {
            let expectedSequence = UInt64(index + 1)
            guard item.sequence == expectedSequence else {
                throw BoundSessionEvidenceJournalV2Error.corruptJournal(
                    "event filenames are not contiguous from sequence one"
                )
            }
            let bytes = try readExactFile(
                rootDescriptor: rootDescriptor,
                name: item.name,
                maximumByteCount: eventEncodedByteCount
            )
            let event = try decodeEvent(
                bytes,
                endpointID: endpointID,
                expectedSequence: expectedSequence,
                expectedPrevious: events.last?.eventSHA256
            )
            events.append(event)
        }
        try sync(rootDescriptor, operation: "recovered parent directory sync")
        return (instance, events)
    }

    private static func makeInstance(
        endpointID: String,
        identityFingerprint: Data,
        nonce: Data
    ) -> InstanceRecord {
        let endpointBytes = Data(endpointID.utf8)
        var digestInput = instanceDigestDomain
        appendUInt16(UInt16(endpointBytes.count), to: &digestInput)
        digestInput.append(endpointBytes)
        digestInput.append(identityFingerprint)
        digestInput.append(nonce)
        let digest = Data(SHA256.hash(data: digestInput))

        var encoded = instanceMagic
        appendUInt32(formatVersion, to: &encoded)
        appendUInt32(UInt32(16 + 4 + 32 + 32 + 32 + endpointBytes.count), to: &encoded)
        appendUInt16(UInt16(endpointBytes.count), to: &encoded)
        appendUInt16(0, to: &encoded)
        encoded.append(identityFingerprint)
        encoded.append(nonce)
        encoded.append(digest)
        encoded.append(endpointBytes)
        return InstanceRecord(nonce: nonce, digest: digest, encoded: encoded)
    }

    private static func decodeInstance(
        _ encoded: Data,
        expectedEndpointID: String,
        expectedIdentityFingerprint: Data
    ) throws -> InstanceRecord {
        let fixedByteCount = 16 + 4 + 32 + 32 + 32
        guard encoded.count >= fixedByteCount,
              encoded.prefix(8) == instanceMagic,
              readUInt32(encoded, at: 8) == formatVersion,
              Int(readUInt32(encoded, at: 12)) == encoded.count else {
            throw BoundSessionEvidenceJournalV2Error.corruptJournal(
                "invalid instance envelope"
            )
        }
        let endpointByteCount = Int(readUInt16(encoded, at: 16))
        guard readUInt16(encoded, at: 18) == 0,
              endpointByteCount > 0,
              endpointByteCount <= 64,
              fixedByteCount + endpointByteCount == encoded.count else {
            throw BoundSessionEvidenceJournalV2Error.corruptJournal(
                "invalid instance endpoint length or reserved field"
            )
        }
        let fingerprint = encoded.subdata(in: 20..<52)
        let nonce = encoded.subdata(in: 52..<84)
        let storedDigest = encoded.subdata(in: 84..<116)
        let endpointBytes = encoded.subdata(in: 116..<encoded.count)
        guard let endpointID = String(data: endpointBytes, encoding: .utf8),
              endpointID == expectedEndpointID,
              fingerprint == expectedIdentityFingerprint else {
            throw BoundSessionEvidenceJournalV2Error.corruptJournal(
                "instance identity projection mismatch"
            )
        }
        let expected = makeInstance(
            endpointID: endpointID,
            identityFingerprint: fingerprint,
            nonce: nonce
        )
        guard storedDigest == expected.digest,
              encoded == expected.encoded else {
            throw BoundSessionEvidenceJournalV2Error.corruptJournal(
                "instance digest or canonical bytes mismatch"
            )
        }
        return expected
    }

    private static func encode(_ event: BoundSessionEvidenceJournalEventV2) -> Data {
        var encoded = eventMagic
        appendUInt32(formatVersion, to: &encoded)
        appendUInt32(UInt32(eventEncodedByteCount), to: &encoded)
        appendUInt64(event.sequence, to: &encoded)
        encoded.append(event.previousEventSHA256 ?? Data(repeating: 0, count: 32))
        encoded.append(event.eventType.rawValue)
        encoded.append(UInt8(event.direction.rawValue))
        encoded.append(event.wireSHA256 == nil ? 0 : 1)
        encoded.append(0)
        encoded.append(event.subjectSHA256)
        encoded.append(event.wireSHA256 ?? Data(repeating: 0, count: 32))
        encoded.append(Data(event.describedAt.utf8))
        encoded.append(event.eventSHA256)
        precondition(encoded.count == eventEncodedByteCount)
        return encoded
    }

    private static func decodeEvent(
        _ encoded: Data,
        endpointID: String,
        expectedSequence: UInt64,
        expectedPrevious: Data?
    ) throws -> BoundSessionEvidenceJournalEventV2 {
        guard encoded.count == eventEncodedByteCount,
              encoded.prefix(8) == eventMagic,
              readUInt32(encoded, at: 8) == formatVersion,
              readUInt32(encoded, at: 12) == UInt32(eventEncodedByteCount),
              readUInt64(encoded, at: 16) == expectedSequence,
              let eventType = BoundSessionEvidenceJournalEventTypeV2(
                rawValue: encoded[56]
              ),
              let direction = BoundSessionEvidenceDirectionV2(
                  rawValue: UInt32(encoded[57])
              ),
              encoded[58] == 0 || encoded[58] == 1,
              encoded[59] == 0 else {
            throw BoundSessionEvidenceJournalV2Error.corruptJournal(
                "invalid event envelope or closed enum"
            )
        }
        let previousBytes = encoded.subdata(in: 24..<56)
        let expectedPreviousBytes = expectedPrevious ?? Data(repeating: 0, count: 32)
        guard previousBytes == expectedPreviousBytes else {
            throw BoundSessionEvidenceJournalV2Error.corruptJournal(
                "event hash chain mismatch"
            )
        }
        let subject = encoded.subdata(in: 60..<92)
        let wireBytes = encoded.subdata(in: 92..<124)
        let wire = encoded[58] == 1 ? wireBytes : nil
        guard encoded[58] == 1 || wireBytes == Data(repeating: 0, count: 32) else {
            throw BoundSessionEvidenceJournalV2Error.corruptJournal(
                "absent event wire field is nonzero"
            )
        }
        let timestampBytes = encoded.subdata(in: 124..<144)
        guard let timestamp = String(data: timestampBytes, encoding: .ascii),
              isCanonicalTimestamp(timestamp) else {
            throw BoundSessionEvidenceJournalV2Error.corruptJournal(
                "event timestamp is not canonical UTC seconds"
            )
        }
        let storedDigest = encoded.subdata(in: 144..<176)
        let computedDigest = eventDigest(
            endpointID: endpointID,
            sequence: expectedSequence,
            previousEventSHA256: expectedPrevious,
            eventType: eventType,
            direction: direction,
            subjectSHA256: subject,
            wireSHA256: wire
        )
        guard storedDigest == computedDigest else {
            throw BoundSessionEvidenceJournalV2Error.corruptJournal(
                "event digest was not recomputed"
            )
        }
        return BoundSessionEvidenceJournalEventV2(
            sequence: expectedSequence,
            previousEventSHA256: expectedPrevious,
            eventType: eventType,
            direction: direction,
            subjectSHA256: subject,
            wireSHA256: wire,
            describedAt: timestamp,
            eventSHA256: storedDigest
        )
    }

    static func eventDigest(
        endpointID: String,
        sequence: UInt64,
        previousEventSHA256: Data?,
        eventType: BoundSessionEvidenceJournalEventTypeV2,
        direction: BoundSessionEvidenceDirectionV2,
        subjectSHA256: Data,
        wireSHA256: Data?
    ) -> Data {
        let endpointBytes = Data(endpointID.utf8)
        let eventTypeBytes = Data(eventType.rawName.utf8)
        var input = eventDigestDomain
        appendUInt16(UInt16(endpointBytes.count), to: &input)
        input.append(endpointBytes)
        appendUInt64(sequence, to: &input)
        input.append(previousEventSHA256 ?? Data(repeating: 0, count: 32))
        appendUInt16(UInt16(eventTypeBytes.count), to: &input)
        input.append(eventTypeBytes)
        input.append(UInt8(direction.rawValue))
        input.append(subjectSHA256)
        input.append(wireSHA256 ?? Data(repeating: 0, count: 32))
        return Data(SHA256.hash(data: input))
    }

    static func endpointID(for identityFingerprint: Data) -> String {
        let hex = identityFingerprint.map { String(format: "%02x", $0) }.joined()
        return "endpoint-" + String(hex.prefix(55))
    }

    private static func eventFileName(sequence: UInt64) -> String {
        String(format: "event-%020llu.bsev2", sequence)
    }

    private static func eventSequence(from fileName: String) -> UInt64? {
        guard fileName.hasPrefix(eventFilePrefix),
              fileName.hasSuffix(eventFileSuffix) else {
            return nil
        }
        let start = fileName.index(fileName.startIndex, offsetBy: eventFilePrefix.count)
        let end = fileName.index(fileName.endIndex, offsetBy: -eventFileSuffix.count)
        let digits = fileName[start..<end]
        guard digits.count == 20,
              digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let sequence = UInt64(digits),
              sequence > 0 else {
            return nil
        }
        return sequence
    }

    private static func directoryEntryNames(_ descriptor: Int32) throws -> [String] {
        let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0 else {
            throw BoundSessionEvidenceJournalV2Error.io(
                operation: "duplicate root descriptor",
                errno: errno
            )
        }
        guard let directory = fdopendir(duplicate) else {
            let code = errno
            _ = Darwin.close(duplicate)
            throw BoundSessionEvidenceJournalV2Error.io(
                operation: "open directory stream",
                errno: code
            )
        }
        defer { closedir(directory) }
        var names: [String] = []
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: 1) {
                    String(cString: $0)
                }
            }
            if name != ".", name != ".." {
                names.append(name)
            }
            errno = 0
        }
        guard errno == 0 else {
            throw BoundSessionEvidenceJournalV2Error.io(
                operation: "read directory entries",
                errno: errno
            )
        }
        return names
    }

    private static func readExactFile(
        rootDescriptor: Int32,
        name: String,
        maximumByteCount: Int
    ) throws -> Data {
        let descriptor = name.withCString {
            openat(rootDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw BoundSessionEvidenceJournalV2Error.io(
                operation: "open recovered file",
                errno: errno
            )
        }
        do {
            let bytes = try readAll(from: descriptor, maximumByteCount: maximumByteCount)
            try validateFileDescriptor(descriptor, expectedByteCount: bytes.count)
            try sync(descriptor, operation: "recovered file sync")
            try close(descriptor, operation: "recovered file close")
            return bytes
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private static func validateDirectoryDescriptor(_ descriptor: Int32) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw BoundSessionEvidenceJournalV2Error.io(
                operation: "stat root",
                errno: errno
            )
        }
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              status.st_uid == geteuid(),
              status.st_mode & mode_t(0o077) == 0 else {
            throw BoundSessionEvidenceJournalV2Error.invalidRoot(
                "root must be an owned private directory"
            )
        }
    }

    private static func validateFileDescriptor(
        _ descriptor: Int32,
        expectedByteCount: Int
    ) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw BoundSessionEvidenceJournalV2Error.io(
                operation: "stat journal file",
                errno: errno
            )
        }
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_uid == geteuid(),
              status.st_nlink == 1,
              status.st_mode & mode_t(0o077) == 0,
              status.st_size == off_t(expectedByteCount) else {
            throw BoundSessionEvidenceJournalV2Error.corruptJournal(
                "journal file identity, mode, link count, or size mismatch"
            )
        }
    }

    private static func readAll(
        from descriptor: Int32,
        maximumByteCount: Int
    ) throws -> Data {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw BoundSessionEvidenceJournalV2Error.io(
                operation: "stat before read",
                errno: errno
            )
        }
        guard status.st_size >= 0,
              status.st_size <= off_t(maximumByteCount),
              let byteCount = Int(exactly: status.st_size) else {
            throw BoundSessionEvidenceJournalV2Error.corruptJournal(
                "journal file exceeds its fixed admission bound"
            )
        }
        var bytes = Data(count: byteCount)
        var offset = 0
        while offset < byteCount {
            let result = bytes.withUnsafeMutableBytes { buffer in
                Darwin.pread(
                    descriptor,
                    buffer.baseAddress?.advanced(by: offset),
                    byteCount - offset,
                    off_t(offset)
                )
            }
            if result < 0, errno == EINTR { continue }
            guard result > 0 else {
                throw BoundSessionEvidenceJournalV2Error.io(
                    operation: "bounded file read",
                    errno: result == 0 ? EIO : errno
                )
            }
            offset += result
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              after.st_dev == status.st_dev,
              after.st_ino == status.st_ino,
              after.st_size == status.st_size,
              after.st_mtimespec.tv_sec == status.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == status.st_mtimespec.tv_nsec else {
            throw BoundSessionEvidenceJournalV2Error.corruptJournal(
                "journal file changed while reading"
            )
        }
        return bytes
    }

    private static func writeAll(_ bytes: Data, to descriptor: Int32) throws {
        var offset = 0
        while offset < bytes.count {
            let result = bytes.withUnsafeBytes { buffer in
                Darwin.write(
                    descriptor,
                    buffer.baseAddress?.advanced(by: offset),
                    bytes.count - offset
                )
            }
            if result < 0, errno == EINTR { continue }
            guard result > 0 else {
                throw BoundSessionEvidenceJournalV2Error.io(
                    operation: "bounded file write",
                    errno: result == 0 ? EIO : errno
                )
            }
            offset += result
        }
    }

    private static func sync(_ descriptor: Int32, operation: String) throws {
        while Darwin.fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw BoundSessionEvidenceJournalV2Error.io(
                operation: operation,
                errno: errno
            )
        }
    }

    private static func close(_ descriptor: Int32, operation: String) throws {
        guard Darwin.close(descriptor) == 0 else {
            throw BoundSessionEvidenceJournalV2Error.io(
                operation: operation,
                errno: errno
            )
        }
    }

    private static func secureRandom(byteCount: Int) throws -> Data {
        var bytes = Data(count: byteCount)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, byteCount, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw BoundSessionEvidenceJournalV2Error.io(
                operation: "secure random",
                errno: Int32(status)
            )
        }
        return bytes
    }

    private static func requireDigest(_ digest: Data, name: String) throws {
        guard digest.count == SHA256.byteCount,
              digest.contains(where: { $0 != 0 }) else {
            throw BoundSessionEvidenceJournalV2Error.invalidConfiguration(
                "\(name) digest must be one nonzero SHA-256 value"
            )
        }
    }

    private static func encodeTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let value = formatter.string(from: date)
        precondition(value.utf8.count == 20)
        return value
    }

    private static func isCanonicalTimestamp(_ value: String) -> Bool {
        guard value.utf8.count == 20 else { return false }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        guard let date = formatter.date(from: value) else { return false }
        return encodeTimestamp(date) == value
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private static func appendUInt64(_ value: UInt64, to data: inout Data) {
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }

    private static func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
        var value = UInt64(0)
        for index in 0..<8 {
            value = (value << 8) | UInt64(data[offset + index])
        }
        return value
    }
}
