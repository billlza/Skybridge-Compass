import Compression
import CryptoKit
import Foundation
import Darwin

/// Shared resource and wire-contract safety policy for classic file transfers.
public enum ClassicTransferInboundPolicy {
    public static let currentSecurityVersion = 2
    public static let maximumConcurrentConnections = 5
    public static let maximumPendingTransfers = 32
    public static let initialHeaderTimeoutSeconds: TimeInterval = 5
    public static let metadataPayloadTimeoutSeconds: TimeInterval = 10
    public static let frameIdleTimeoutSeconds: TimeInterval = 30
    public static let frameSendTimeoutSeconds: TimeInterval = 30
    public static let maximumFileSizeBytes: Int64 = 2 * 1_024 * 1_024 * 1_024
    public static let minimumDeclaredChunkSizeBytes = 64 * 1_024
    public static let maximumDeclaredChunkSizeBytes = 512 * 1_024
    public static let maximumChunkCount = 65_536
}

public enum ClassicTransferResumeAcknowledgmentContractError: Error, Equatable, Sendable {
    case invalidFileSize
    case invalidDeclaredChunkSize
    case invalidRequestedOffset
    case invalidAcceptedOffset
}

/// Validates the authenticated resume response against the immutable outbound
/// transfer contract. Authentication proves who sent the ACK; this contract
/// separately proves that the accepted offset is safe to use for file I/O.
public enum ClassicTransferResumeAcknowledgmentContract {
    public static func validate(
        acceptedOffset: Int64,
        requestedOffset: Int64,
        fileSize: Int64,
        declaredChunkSize: Int
    ) throws {
        guard fileSize >= 0,
              fileSize <= ClassicTransferInboundPolicy.maximumFileSizeBytes else {
            throw ClassicTransferResumeAcknowledgmentContractError.invalidFileSize
        }
        guard declaredChunkSize >= ClassicTransferInboundPolicy.minimumDeclaredChunkSizeBytes,
              declaredChunkSize <= ClassicTransferInboundPolicy.maximumDeclaredChunkSizeBytes else {
            throw ClassicTransferResumeAcknowledgmentContractError.invalidDeclaredChunkSize
        }
        guard requestedOffset >= 0,
              requestedOffset <= fileSize,
              isAligned(offset: requestedOffset, fileSize: fileSize, chunkSize: declaredChunkSize) else {
            throw ClassicTransferResumeAcknowledgmentContractError.invalidRequestedOffset
        }
        guard acceptedOffset >= 0,
              acceptedOffset <= min(requestedOffset, fileSize),
              isAligned(offset: acceptedOffset, fileSize: fileSize, chunkSize: declaredChunkSize) else {
            throw ClassicTransferResumeAcknowledgmentContractError.invalidAcceptedOffset
        }
    }

    private static func isAligned(offset: Int64, fileSize: Int64, chunkSize: Int) -> Bool {
        offset == fileSize || offset % Int64(chunkSize) == 0
    }
}

public enum ClassicTransferAuthenticationContract {
    public static func isValidHMACSHA256(
        _ authenticationCode: Data?,
        authenticating payload: Data,
        using key: SymmetricKey
    ) -> Bool {
        guard let authenticationCode, authenticationCode.count == 32 else {
            return false
        }
        return HMAC<SHA256>.isValidAuthenticationCode(
            authenticationCode,
            authenticating: payload,
            using: key
        )
    }
}

public enum ClassicTransferReceiptContractError: Error, Equatable, Sendable {
    case missingExpectedFileHash
    case missingReceivedFileHash
    case fileHashMismatch
}

public enum ClassicTransferReceiptContract {
    public static func validateSuccessfulFileHash(
        _ receivedFileHash: String?,
        expected expectedFileHash: String?
    ) throws {
        guard let expectedFileHash else {
            throw ClassicTransferReceiptContractError.missingExpectedFileHash
        }
        do {
            try ClassicTransferMetadataContract.validateSHA256Hex(expectedFileHash)
        } catch {
            throw ClassicTransferReceiptContractError.missingExpectedFileHash
        }
        guard let receivedFileHash else {
            throw ClassicTransferReceiptContractError.missingReceivedFileHash
        }
        do {
            try ClassicTransferMetadataContract.validateSHA256Hex(receivedFileHash)
        } catch {
            throw ClassicTransferReceiptContractError.missingReceivedFileHash
        }
        guard receivedFileHash == expectedFileHash else {
            throw ClassicTransferReceiptContractError.fileHashMismatch
        }
    }
}

public enum ClassicTransferMetadataContractError: Error, Equatable, Sendable {
    case unsupportedSecurityVersion
    case invalidTransferIdentifier
    case invalidFileName
    case invalidFileSize
    case invalidFileHash
    case invalidChunkSize
    case excessiveChunkCount
    case invalidDisplayField
    case invalidCompression
}

public enum ClassicTransferMetadataContract {
    public static func validateSecurityVersion(_ version: Int?) throws {
        guard version == ClassicTransferInboundPolicy.currentSecurityVersion else {
            throw ClassicTransferMetadataContractError.unsupportedSecurityVersion
        }
    }

    public static func validate(
        transferID: String,
        fileName: String,
        fileSize: Int64,
        fileHash: String,
        declaredChunkSize: Int,
        compression: String?,
        displayFields: [String?] = []
    ) throws {
        try validateTransferIdentifier(transferID)

        try validateFileName(fileName)

        guard fileSize >= 0,
              fileSize <= ClassicTransferInboundPolicy.maximumFileSizeBytes else {
            throw ClassicTransferMetadataContractError.invalidFileSize
        }

        try validateSHA256Hex(fileHash)

        guard declaredChunkSize >= ClassicTransferInboundPolicy.minimumDeclaredChunkSizeBytes,
              declaredChunkSize <= ClassicTransferInboundPolicy.maximumDeclaredChunkSizeBytes else {
            throw ClassicTransferMetadataContractError.invalidChunkSize
        }
        let expectedChunkCount: Int64
        if fileSize == 0 {
            expectedChunkCount = 0
        } else {
            expectedChunkCount = ((fileSize - 1) / Int64(declaredChunkSize)) + 1
        }
        guard expectedChunkCount <= Int64(ClassicTransferInboundPolicy.maximumChunkCount) else {
            throw ClassicTransferMetadataContractError.excessiveChunkCount
        }

        guard compression == nil || compression == "zlib" else {
            throw ClassicTransferMetadataContractError.invalidCompression
        }
        guard displayFields.allSatisfy({ field in
            guard let field else { return true }
            return field.utf8.count <= 256
                && field.unicodeScalars.allSatisfy { !isUnsafeVisibleScalar($0) }
        }) else {
            throw ClassicTransferMetadataContractError.invalidDisplayField
        }
    }

    public static func validateTransferIdentifier(_ transferID: String) throws {
        guard (1...128).contains(transferID.utf8.count),
              transferID.unicodeScalars.allSatisfy({ scalar in
                  scalar.isASCII && (
                      CharacterSet.alphanumerics.contains(scalar)
                          || scalar == "-"
                          || scalar == "_"
                  )
              }) else {
            throw ClassicTransferMetadataContractError.invalidTransferIdentifier
        }
    }

    public static func validateFileName(_ fileName: String) throws {
        let trimmedFileName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFileName.isEmpty,
              trimmedFileName == fileName,
              fileName.utf8.count <= 255,
              fileName != ".",
              fileName != "..",
              !fileName.contains("/"),
              !fileName.contains("\\"),
              fileName.unicodeScalars.allSatisfy({ !isUnsafeVisibleScalar($0) }) else {
            throw ClassicTransferMetadataContractError.invalidFileName
        }
    }

    public static func validateSHA256Hex(_ digest: String) throws {
        guard digest.utf8.count == 64,
              digest.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 48...57, 97...102:
                      return true
                  default:
                      return false
                  }
              }) else {
            throw ClassicTransferMetadataContractError.invalidFileHash
        }
    }

    public static func validateVisibleField(_ field: String?, maximumUTF8Length: Int = 256) throws {
        guard maximumUTF8Length >= 0 else {
            throw ClassicTransferMetadataContractError.invalidDisplayField
        }
        guard let field else { return }
        guard field.utf8.count <= maximumUTF8Length,
              field.unicodeScalars.allSatisfy({ !isUnsafeVisibleScalar($0) }) else {
            throw ClassicTransferMetadataContractError.invalidDisplayField
        }
    }

    public static func validateResumeOffset(
        _ offset: Int64,
        fileSize: Int64,
        declaredChunkSize: Int
    ) throws {
        guard offset >= 0,
              offset <= fileSize,
              declaredChunkSize >= ClassicTransferInboundPolicy.minimumDeclaredChunkSizeBytes,
              declaredChunkSize <= ClassicTransferInboundPolicy.maximumDeclaredChunkSizeBytes,
              offset == fileSize || offset % Int64(declaredChunkSize) == 0 else {
            throw ClassicTransferMetadataContractError.invalidChunkSize
        }
    }

    private static func isUnsafeVisibleScalar(_ scalar: Unicode.Scalar) -> Bool {
        if CharacterSet.controlCharacters.contains(scalar) {
            return true
        }
        switch scalar.value {
        case 0x061C, 0x200E, 0x200F,
             0x202A...0x202E,
             0x2044, 0x2066...0x2069,
             0x2215, 0x29F5, 0x29F8, 0x29F9,
             0xFE68, 0xFF0F, 0xFF3C:
            return true
        default:
            return false
        }
    }
}

/// Collision-resistant v2 authentication transcripts shared by macOS and iOS.
/// Every field is named, presence-marked, and length-prefixed; no delimiter or
/// optional-value ambiguity is possible.
public enum ClassicTransferCanonicalTranscriptError: Error, Equatable, Sendable {
    case invalidSecurityVersion
    case fieldCountOverflow
    case fieldNameLengthOverflow
    case fieldValueLengthOverflow
}

public enum ClassicTransferCanonicalTranscript {
    public static func metadata(
        transferID: String,
        fileName: String,
        fileSize: Int64,
        fileHash: String,
        chunkSize: Int,
        securityVersion: Int,
        compression: String?,
        senderDeviceID: String?,
        senderDeviceName: String?,
        senderPlatform: String?,
        senderOSVersion: String?,
        senderModelName: String?,
        senderChip: String?
    ) throws -> Data {
        try ClassicTransferMetadataContract.validateSecurityVersion(securityVersion)
        return try transcript(
            purpose: 1,
            securityVersion: securityVersion,
            fields: [
                ("transfer_id", transferID),
                ("file_name", fileName),
                ("file_size", String(fileSize)),
                ("file_hash", fileHash),
                ("chunk_size", String(chunkSize)),
                ("compression", compression),
                ("sender_device_id", senderDeviceID),
                ("sender_device_name", senderDeviceName),
                ("sender_platform", senderPlatform),
                ("sender_os_version", senderOSVersion),
                ("sender_model_name", senderModelName),
                ("sender_chip", senderChip)
            ]
        )
    }

    public static func receipt(
        transferID: String,
        success: Bool,
        receivedBytes: Int64,
        fileHash: String?,
        error: String?,
        securityVersion: Int
    ) throws -> Data {
        try ClassicTransferMetadataContract.validateSecurityVersion(securityVersion)
        return try transcript(
            purpose: 2,
            securityVersion: securityVersion,
            fields: [
                ("transfer_id", transferID),
                ("success", success ? "1" : "0"),
                ("received_bytes", String(receivedBytes)),
                ("file_hash", fileHash),
                ("error", error)
            ]
        )
    }

    public static func resumeRequest(
        transferID: String,
        senderDeviceID: String,
        resumeOffset: Int64,
        securityVersion: Int
    ) throws -> Data {
        try ClassicTransferMetadataContract.validateSecurityVersion(securityVersion)
        return try transcript(
            purpose: 3,
            securityVersion: securityVersion,
            fields: [
                ("transfer_id", transferID),
                ("sender_device_id", senderDeviceID),
                ("resume_offset", String(resumeOffset))
            ]
        )
    }

    public static func resumeAcknowledgment(
        transferID: String,
        accepted: Bool,
        resumeOffset: Int64,
        error: String?,
        securityVersion: Int
    ) throws -> Data {
        try ClassicTransferMetadataContract.validateSecurityVersion(securityVersion)
        return try transcript(
            purpose: 4,
            securityVersion: securityVersion,
            fields: [
                ("transfer_id", transferID),
                ("accepted", accepted ? "1" : "0"),
                ("resume_offset", String(resumeOffset)),
                ("error", error)
            ]
        )
    }

    private static func transcript(
        purpose: UInt8,
        securityVersion: Int,
        fields: [(String, String?)]
    ) throws -> Data {
        guard let encodedSecurityVersion = UInt32(exactly: securityVersion) else {
            throw ClassicTransferCanonicalTranscriptError.invalidSecurityVersion
        }
        guard let encodedFieldCount = UInt16(exactly: fields.count) else {
            throw ClassicTransferCanonicalTranscriptError.fieldCountOverflow
        }
        var output = Data("SkyBridgeClassicTransfer\0".utf8)
        output.append(purpose)
        append(encodedSecurityVersion, to: &output)
        append(encodedFieldCount, to: &output)
        for (name, value) in fields {
            let nameBytes = Data(name.utf8)
            guard let encodedNameLength = UInt16(exactly: nameBytes.count) else {
                throw ClassicTransferCanonicalTranscriptError.fieldNameLengthOverflow
            }
            append(encodedNameLength, to: &output)
            output.append(nameBytes)
            if let value {
                output.append(1)
                let valueBytes = Data(value.utf8)
                guard let encodedValueLength = UInt64(exactly: valueBytes.count) else {
                    throw ClassicTransferCanonicalTranscriptError.fieldValueLengthOverflow
                }
                append(encodedValueLength, to: &output)
                output.append(valueBytes)
            } else {
                output.append(0)
                append(UInt64(0), to: &output)
            }
        }
        return output
    }

    private static func append(_ value: UInt16, to data: inout Data) {
        var bigEndianValue = value.bigEndian
        withUnsafeBytes(of: &bigEndianValue) { data.append(contentsOf: $0) }
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        var bigEndianValue = value.bigEndian
        withUnsafeBytes(of: &bigEndianValue) { data.append(contentsOf: $0) }
    }

    private static func append(_ value: UInt64, to data: inout Data) {
        var bigEndianValue = value.bigEndian
        withUnsafeBytes(of: &bigEndianValue) { data.append(contentsOf: $0) }
    }
}

public struct ClassicTransferInboundAdmission: Sendable {
    private let limit: Int
    private var connectionIDs: Set<String> = []

    public init(limit: Int = ClassicTransferInboundPolicy.maximumConcurrentConnections) {
        precondition(limit > 0, "Classic transfer inbound connection limit must be positive")
        self.limit = limit
    }

    public var count: Int {
        connectionIDs.count
    }

    public mutating func reserve(connectionID: String) -> Bool {
        guard !connectionID.isEmpty,
              !connectionIDs.contains(connectionID),
              connectionIDs.count < limit else {
            return false
        }
        connectionIDs.insert(connectionID)
        return true
    }

    public mutating func release(connectionID: String) {
        connectionIDs.remove(connectionID)
    }

    public mutating func removeAll() {
        connectionIDs.removeAll(keepingCapacity: true)
    }
}

public enum ClassicTransferSlotRequestDecision: Sendable, Equatable {
    case acquired
    case queued
    case capacityExceeded
}

/// Deterministic FIFO state machine shared by both platform managers. It owns no
/// continuations, so platform error types stay at the manager boundary while the
/// queue limit, cancellation removal, and release accounting remain identical.
public struct ClassicTransferSlotQueuePolicy: Sendable {
    public private(set) var inFlightCount = 0
    public private(set) var pendingCount = 0
    private var pendingIdentifiers: [UUID] = []

    public init() {}

    public mutating func request(
        identifier: UUID,
        configuredLimit: Int,
        maximumPending: Int = ClassicTransferInboundPolicy.maximumPendingTransfers
    ) -> ClassicTransferSlotRequestDecision {
        let limit = normalizedLimit(configuredLimit)
        guard !pendingIdentifiers.contains(identifier) else {
            return .capacityExceeded
        }
        if inFlightCount < limit {
            inFlightCount += 1
            return .acquired
        }
        let pendingLimit = min(
            ClassicTransferInboundPolicy.maximumPendingTransfers,
            max(0, maximumPending)
        )
        guard pendingIdentifiers.count < pendingLimit else {
            return .capacityExceeded
        }
        pendingIdentifiers.append(identifier)
        pendingCount = pendingIdentifiers.count
        return .queued
    }

    @discardableResult
    public mutating func cancelPending(identifier: UUID) -> Bool {
        guard let index = pendingIdentifiers.firstIndex(of: identifier) else {
            return false
        }
        pendingIdentifiers.remove(at: index)
        pendingCount = pendingIdentifiers.count
        return true
    }

    /// Removes every queued request without changing `inFlightCount`.
    ///
    /// Callers still owning an acquired slot must release it exactly once. This
    /// separation lets lifecycle shutdown fail all queued continuations without
    /// corrupting accounting for operations that are already unwinding.
    public mutating func cancelAllPending() -> [UUID] {
        let cancelledIdentifiers = pendingIdentifiers
        pendingIdentifiers.removeAll(keepingCapacity: true)
        pendingCount = 0
        return cancelledIdentifiers
    }

    public mutating func release(configuredLimit: Int) -> [UUID] {
        precondition(inFlightCount > 0, "Classic transfer slot released without acquisition")
        inFlightCount -= 1
        return drain(configuredLimit: configuredLimit)
    }

    public mutating func drain(configuredLimit: Int) -> [UUID] {
        let limit = normalizedLimit(configuredLimit)
        var resumed: [UUID] = []
        resumed.reserveCapacity(
            min(max(0, limit - inFlightCount), pendingIdentifiers.count)
        )
        while inFlightCount < limit, !pendingIdentifiers.isEmpty {
            resumed.append(pendingIdentifiers.removeFirst())
            inFlightCount += 1
        }
        pendingCount = pendingIdentifiers.count
        return resumed
    }

    private func normalizedLimit(_ configuredLimit: Int) -> Int {
        min(
            ClassicTransferInboundPolicy.maximumConcurrentConnections,
            max(1, configuredLimit)
        )
    }
}

public enum ClassicTransferReceiveAppendOutcome: Sendable, Equatable {
    case pending
    case completed
    case ignoredAfterCompletion
    case overflow
}

/// Thread-safe exactly-once gate for a single bounded NWConnection receive
/// operation. It deliberately owns no connection so transport cancellation stays
/// at the caller boundary, while stale callbacks can synchronously observe that
/// the operation completed and must not recurse into another receive.
public final class ClassicTransferReceiveOperation: @unchecked Sendable {
    private let lock = NSLock()
    private let expectedLength: Int
    private var storage = Data()
    private var continuation: CheckedContinuation<Data, Error>?
    private var pendingResult: Result<Data, Error>?
    private var completed = false

    public init(expectedLength: Int) {
        precondition(expectedLength >= 0, "Classic transfer receive length cannot be negative")
        self.expectedLength = expectedLength
        storage.reserveCapacity(min(expectedLength, 64 * 1_024))
    }

    public func install(_ continuation: CheckedContinuation<Data, Error>) {
        var pendingResult: Result<Data, Error>?
        lock.lock()
        precondition(self.continuation == nil, "Classic transfer continuation installed twice")
        if let storedResult = self.pendingResult {
            pendingResult = storedResult
            self.pendingResult = nil
        } else if expectedLength == 0, !completed {
            completed = true
            pendingResult = .success(Data())
        } else {
            self.continuation = continuation
        }
        lock.unlock()
        if let pendingResult {
            continuation.resume(with: pendingResult)
        }
    }

    public var isCompleted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return completed
    }

    public var receivedByteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }

    public func remainingLength() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return nil }
        return expectedLength - storage.count
    }

    @discardableResult
    public func append(_ data: Data) -> ClassicTransferReceiveAppendOutcome {
        var continuation: CheckedContinuation<Data, Error>?
        var completedData: Data?
        lock.lock()
        guard !completed else {
            lock.unlock()
            return .ignoredAfterCompletion
        }
        guard data.count <= expectedLength - storage.count else {
            lock.unlock()
            return .overflow
        }
        storage.append(data)
        guard storage.count == expectedLength else {
            lock.unlock()
            return .pending
        }
        completed = true
        completedData = storage
        continuation = self.continuation
        self.continuation = nil
        if continuation == nil, let completedData {
            pendingResult = .success(completedData)
        }
        lock.unlock()
        if let continuation, let completedData {
            continuation.resume(returning: completedData)
        }
        return .completed
    }

    @discardableResult
    public func fail(_ error: Error) -> Bool {
        var continuation: CheckedContinuation<Data, Error>?
        lock.lock()
        guard !completed else {
            lock.unlock()
            return false
        }
        completed = true
        continuation = self.continuation
        self.continuation = nil
        if continuation == nil {
            pendingResult = .failure(error)
        }
        lock.unlock()
        continuation?.resume(throwing: error)
        return true
    }
}

/// Thread-safe exactly-once completion gate for one `NWConnection.send` call.
/// The transport remains owned by the caller so the winner of an error,
/// deadline, or task-cancellation race can synchronously cancel it.
public final class ClassicTransferSendOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var pendingResult: Result<Void, Error>?
    private var completed = false

    public init() {}

    public func install(_ continuation: CheckedContinuation<Void, Error>) {
        var pendingResult: Result<Void, Error>?
        lock.lock()
        precondition(self.continuation == nil, "Classic transfer send continuation installed twice")
        if let storedResult = self.pendingResult {
            pendingResult = storedResult
            self.pendingResult = nil
        } else {
            self.continuation = continuation
        }
        lock.unlock()
        if let pendingResult {
            continuation.resume(with: pendingResult)
        }
    }

    public var isCompleted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return completed
    }

    @discardableResult
    public func succeed() -> Bool {
        finish(with: .success(()))
    }

    @discardableResult
    public func fail(_ error: Error) -> Bool {
        finish(with: .failure(error))
    }

    private func finish(with result: Result<Void, Error>) -> Bool {
        var continuation: CheckedContinuation<Void, Error>?
        lock.lock()
        guard !completed else {
            lock.unlock()
            return false
        }
        completed = true
        continuation = self.continuation
        self.continuation = nil
        if continuation == nil {
            pendingResult = result
        }
        lock.unlock()
        continuation?.resume(with: result)
        return true
    }
}

public enum ClassicTransferChunkContractError: Error, Equatable, Sendable {
    case invalidDeclaredFileSize
    case invalidReceivedByteCount
    case invalidDeclaredChunkSize
    case invalidChunkIndex
    case excessiveChunkCount
    case chunkExceedsRemainingFileSize
    case decodedChunkSizeMismatch
    case completedFileSizeMismatch
}

public enum ClassicTransferChunkContract {
    public static func decompressedOutputLimit(
        declaredChunkSize: Int,
        receivedBytes: Int64,
        declaredFileSize: Int64,
        negotiatedChunkSize: Int,
        maximumChunkSize: Int
    ) throws -> Int {
        guard declaredFileSize >= 0 else {
            throw ClassicTransferChunkContractError.invalidDeclaredFileSize
        }
        guard receivedBytes >= 0, receivedBytes <= declaredFileSize else {
            throw ClassicTransferChunkContractError.invalidReceivedByteCount
        }
        guard maximumChunkSize > 0,
              negotiatedChunkSize > 0,
              negotiatedChunkSize <= maximumChunkSize,
              declaredChunkSize > 0,
              declaredChunkSize <= negotiatedChunkSize else {
            throw ClassicTransferChunkContractError.invalidDeclaredChunkSize
        }
        let remainingBytes = declaredFileSize - receivedBytes
        guard Int64(declaredChunkSize) <= remainingBytes else {
            throw ClassicTransferChunkContractError.chunkExceedsRemainingFileSize
        }
        return declaredChunkSize
    }

    public static func validateSequence(
        chunkIndex: Int,
        expectedChunkIndex: Int
    ) throws {
        guard expectedChunkIndex >= 0,
              expectedChunkIndex < ClassicTransferInboundPolicy.maximumChunkCount else {
            throw ClassicTransferChunkContractError.excessiveChunkCount
        }
        guard chunkIndex == expectedChunkIndex else {
            throw ClassicTransferChunkContractError.invalidChunkIndex
        }
    }

    public static func validateDecodedChunkSize(
        _ decodedByteCount: Int,
        declaredChunkSize: Int
    ) throws {
        guard decodedByteCount == declaredChunkSize else {
            throw ClassicTransferChunkContractError.decodedChunkSizeMismatch
        }
    }

    public static func validateCompletion(
        receivedBytes: Int64,
        declaredFileSize: Int64
    ) throws {
        guard declaredFileSize >= 0, receivedBytes == declaredFileSize else {
            throw ClassicTransferChunkContractError.completedFileSizeMismatch
        }
    }
}

public enum ClassicTransferZlibDecompressionError: Error, Equatable, Sendable {
    case invalidOutputLimit
    case invalidCompressedData
    case outputLimitExceeded
}

public enum ClassicTransferZlibCompressionError: Error, Equatable, LocalizedError, Sendable {
    case invalidInputLimit
    case emptyInput
    case inputLimitExceeded
    case compressionFailed

    public var errorDescription: String? {
        switch self {
        case .invalidInputLimit:
            return "Classic transfer compression input limit is invalid"
        case .emptyInput:
            return "Classic transfer cannot compress an empty chunk"
        case .inputLimitExceeded:
            return "Classic transfer compression input exceeds the negotiated chunk limit"
        case .compressionFailed:
            return "Classic transfer zlib compression failed"
        }
    }
}

/// Serializes classic-transfer compression away from UI actors and refuses inputs
/// outside the negotiated chunk bound before Foundation can allocate output storage.
public actor ClassicTransferZlibCompressionWorker {
    public static let shared = ClassicTransferZlibCompressionWorker()

    public func compress(
        _ data: Data,
        maximumInputSize: Int
    ) throws -> Data {
        try Task.checkCancellation()
        guard maximumInputSize > 0 else {
            throw ClassicTransferZlibCompressionError.invalidInputLimit
        }
        guard !data.isEmpty else {
            throw ClassicTransferZlibCompressionError.emptyInput
        }
        guard data.count <= maximumInputSize else {
            throw ClassicTransferZlibCompressionError.inputLimitExceeded
        }
        do {
            return try (data as NSData).compressed(using: .zlib) as Data
        } catch {
            throw ClassicTransferZlibCompressionError.compressionFailed
        }
    }
}

public enum ClassicTransferOutboundFileReadError: Error, Equatable, LocalizedError, Sendable {
    case openFailed
    case closed
    case invalidReadLength
    case unexpectedEndOfFile(expected: Int, actual: Int)
    case readFailed
    case hashUnavailable
    case closeFailed

    public var errorDescription: String? {
        switch self {
        case .openFailed:
            return "Classic transfer source file could not be opened"
        case .closed:
            return "Classic transfer source file is already closed"
        case .invalidReadLength:
            return "Classic transfer source read length is invalid"
        case .unexpectedEndOfFile(let expected, let actual):
            return "Classic transfer source changed during transfer: expected=\(expected), actual=\(actual)"
        case .readFailed:
            return "Classic transfer source file read failed"
        case .hashUnavailable:
            return "Classic transfer source hashing was not enabled"
        case .closeFailed:
            return "Classic transfer source file close failed"
        }
    }
}

public enum ClassicTransferSourceFileInspectionError: Error, Equatable, LocalizedError, Sendable {
    case notFound
    case notRegularFile
    case invalidFileSize
    case inspectionFailed
    case directoryScanLimitExceeded

    public var errorDescription: String? {
        switch self {
        case .notFound:
            return "Classic transfer source file was not found"
        case .notRegularFile:
            return "Classic transfer source must be a regular file"
        case .invalidFileSize:
            return "Classic transfer source file size is outside the supported range"
        case .inspectionFailed:
            return "Classic transfer source file inspection failed"
        case .directoryScanLimitExceeded:
            return "Classic transfer recovery directory exceeds its bounded scan limit"
        }
    }
}

private final class ClassicTransferEnumerationErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?

    func record(_ error: Error) {
        lock.lock()
        storedError = error
        lock.unlock()
    }

    var hasError: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedError != nil
    }
}

/// Performs source metadata I/O away from application/UI actors and returns a
/// precise bounded size instead of silently coercing missing attributes to zero.
public actor ClassicTransferSourceFileInspectionWorker {
    public static let shared = ClassicTransferSourceFileInspectionWorker()

    public func regularFileSize(
        at url: URL,
        maximumSize: Int64 = ClassicTransferInboundPolicy.maximumFileSizeBytes
    ) throws -> Int64 {
        try Task.checkCancellation()
        guard maximumSize >= 0 else {
            throw ClassicTransferSourceFileInspectionError.invalidFileSize
        }
        do {
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            )
            guard values.isSymbolicLink != true,
                  values.isRegularFile == true else {
                throw ClassicTransferSourceFileInspectionError.notRegularFile
            }
            guard let fileSize = values.fileSize else {
                throw ClassicTransferSourceFileInspectionError.inspectionFailed
            }
            let boundedSize = Int64(fileSize)
            guard boundedSize >= 0, boundedSize <= maximumSize else {
                throw ClassicTransferSourceFileInspectionError.invalidFileSize
            }
            return boundedSize
        } catch let error as ClassicTransferSourceFileInspectionError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            throw ClassicTransferSourceFileInspectionError.notFound
        } catch {
            throw ClassicTransferSourceFileInspectionError.inspectionFailed
        }
    }

    public func resolveExistingFile(
        candidates: [URL],
        recoveryDirectory: URL,
        fileName: String,
        maximumDirectoryEntries: Int = 10_000
    ) throws -> URL? {
        try Task.checkCancellation()
        guard maximumDirectoryEntries > 0 else {
            throw ClassicTransferSourceFileInspectionError.directoryScanLimitExceeded
        }
        for candidate in candidates {
            do {
                let values = try candidate.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                )
                if values.isRegularFile == true, values.isSymbolicLink != true {
                    return candidate
                }
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                continue
            } catch {
                throw ClassicTransferSourceFileInspectionError.inspectionFailed
            }
        }

        let expectedStem = (fileName as NSString).deletingPathExtension
        let expectedExtension = (fileName as NSString).pathExtension.lowercased()
        let enumerationError = ClassicTransferEnumerationErrorBox()
        guard let enumerator = FileManager.default.enumerator(
            at: recoveryDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsSubdirectoryDescendants],
            errorHandler: { _, error in
                enumerationError.record(error)
                return false
            }
        ) else {
            throw ClassicTransferSourceFileInspectionError.inspectionFailed
        }

        var visitedEntries = 0
        while let entry = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            visitedEntries += 1
            guard visitedEntries <= maximumDirectoryEntries else {
                throw ClassicTransferSourceFileInspectionError.directoryScanLimitExceeded
            }
            let candidateName = entry.lastPathComponent
            guard (candidateName as NSString).deletingPathExtension == expectedStem,
                  (candidateName as NSString).pathExtension.lowercased() == expectedExtension else {
                continue
            }
            let values = try entry.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            if values.isRegularFile == true, values.isSymbolicLink != true {
                return entry
            }
        }
        if enumerationError.hasError {
            throw ClassicTransferSourceFileInspectionError.inspectionFailed
        }
        return nil
    }
}

/// Owns outbound source-file reads and hashing on a dedicated actor. Construction
/// performs no I/O; callers must use `open(url:)`, whose file open runs on this actor.
public actor ClassicTransferOutboundFileReadSession {
    private var handle: FileHandle?
    private var hasher: SHA256?
    private var initialDeviceIdentifier: UInt64?
    private var initialInodeIdentifier: UInt64?
    private var initialFileSize: Int64?
    private var hashedByteCount: Int64 = 0

    private init() {}

    public static func open(
        url: URL,
        tracksSHA256: Bool
    ) async throws -> ClassicTransferOutboundFileReadSession {
        let session = ClassicTransferOutboundFileReadSession()
        try await session.openFile(at: url, tracksSHA256: tracksSHA256)
        return session
    }

    private func openFile(at url: URL, tracksSHA256: Bool) throws {
        try Task.checkCancellation()
        guard handle == nil else {
            throw ClassicTransferOutboundFileReadError.openFailed
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw ClassicTransferOutboundFileReadError.openFailed
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_size >= 0 else {
            let closeResult = Darwin.close(descriptor)
            guard closeResult == 0 else {
                throw ClassicTransferOutboundFileReadError.closeFailed
            }
            throw ClassicTransferOutboundFileReadError.openFailed
        }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        hasher = tracksSHA256 ? SHA256() : nil
        initialDeviceIdentifier = UInt64(status.st_dev)
        initialInodeIdentifier = UInt64(status.st_ino)
        initialFileSize = Int64(status.st_size)
        hashedByteCount = 0
    }

    public func read(offset: UInt64, length: Int) throws -> Data {
        try Task.checkCancellation()
        guard length > 0 else {
            throw ClassicTransferOutboundFileReadError.invalidReadLength
        }
        guard let handle else {
            throw ClassicTransferOutboundFileReadError.closed
        }
        try validateOpenFileIdentity(handle)
        guard let initialFileSize,
              offset <= UInt64(Int64.max),
              Int64(offset) <= initialFileSize,
              Int64(length) <= initialFileSize - Int64(offset) else {
            throw ClassicTransferOutboundFileReadError.unexpectedEndOfFile(
                expected: length,
                actual: 0
            )
        }
        if hasher != nil, Int64(offset) != hashedByteCount {
            throw ClassicTransferOutboundFileReadError.readFailed
        }
        do {
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: length) ?? Data()
            guard data.count == length else {
                throw ClassicTransferOutboundFileReadError.unexpectedEndOfFile(
                    expected: length,
                    actual: data.count
                )
            }
            if var hasher {
                hasher.update(data: data)
                self.hasher = hasher
                hashedByteCount += Int64(data.count)
            }
            try validateOpenFileIdentity(handle)
            return data
        } catch let error as ClassicTransferOutboundFileReadError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ClassicTransferOutboundFileReadError.readFailed
        }
    }

    public func finalizeAndClose() throws -> Data {
        try Task.checkCancellation()
        guard let handle else {
            throw ClassicTransferOutboundFileReadError.closed
        }
        guard let hasher else {
            throw ClassicTransferOutboundFileReadError.hashUnavailable
        }
        try validateOpenFileIdentity(handle)
        guard hashedByteCount == initialFileSize else {
            throw ClassicTransferOutboundFileReadError.unexpectedEndOfFile(
                expected: Int(initialFileSize ?? 0),
                actual: Int(hashedByteCount)
            )
        }
        do {
            try handle.close()
        } catch {
            throw ClassicTransferOutboundFileReadError.closeFailed
        }
        self.handle = nil
        clearIdentity()
        return Data(hasher.finalize())
    }

    public func hashWholeFileAndClose() throws -> Data {
        try Task.checkCancellation()
        guard let handle else {
            throw ClassicTransferOutboundFileReadError.closed
        }
        var wholeFileHasher = SHA256()
        do {
            try validateOpenFileIdentity(handle)
            try handle.seek(toOffset: 0)
            var bytesHashed: Int64 = 0
            while true {
                try Task.checkCancellation()
                guard let chunk = try handle.read(upToCount: 256 * 1_024), !chunk.isEmpty else {
                    break
                }
                wholeFileHasher.update(data: chunk)
                bytesHashed += Int64(chunk.count)
            }
            try validateOpenFileIdentity(handle)
            guard bytesHashed == initialFileSize else {
                throw ClassicTransferOutboundFileReadError.readFailed
            }
            try handle.close()
            self.handle = nil
            clearIdentity()
            return Data(wholeFileHasher.finalize())
        } catch is CancellationError {
            do {
                try handle.close()
                self.handle = nil
                clearIdentity()
            } catch {
                throw ClassicTransferOutboundFileReadError.closeFailed
            }
            throw CancellationError()
        } catch {
            do {
                try handle.close()
                self.handle = nil
                clearIdentity()
            } catch {
                throw ClassicTransferOutboundFileReadError.closeFailed
            }
            throw ClassicTransferOutboundFileReadError.readFailed
        }
    }

    public func close() throws {
        guard let handle else { return }
        do {
            try handle.close()
            self.handle = nil
            hasher = nil
            clearIdentity()
        } catch {
            throw ClassicTransferOutboundFileReadError.closeFailed
        }
    }

    private func validateOpenFileIdentity(_ handle: FileHandle) throws {
        guard let initialDeviceIdentifier,
              let initialInodeIdentifier,
              let initialFileSize else {
            throw ClassicTransferOutboundFileReadError.readFailed
        }
        var status = stat()
        guard fstat(handle.fileDescriptor, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              UInt64(status.st_dev) == initialDeviceIdentifier,
              UInt64(status.st_ino) == initialInodeIdentifier,
              status.st_size == off_t(initialFileSize) else {
            throw ClassicTransferOutboundFileReadError.readFailed
        }
    }

    private func clearIdentity() {
        initialDeviceIdentifier = nil
        initialInodeIdentifier = nil
        initialFileSize = nil
        hashedByteCount = 0
    }
}

public enum ClassicTransferChunkCryptoError: Error, Equatable, LocalizedError, Sendable {
    case invalidPayloadLimit
    case emptyPayload
    case payloadLimitExceeded
    case invalidNonceLength
    case invalidTagLength
    case authenticationFailed
    case encryptionFailed

    public var errorDescription: String? {
        switch self {
        case .invalidPayloadLimit:
            return "Classic transfer cryptographic payload limit is invalid"
        case .emptyPayload:
            return "Classic transfer cryptographic payload is empty"
        case .payloadLimitExceeded:
            return "Classic transfer cryptographic payload exceeds its hard limit"
        case .invalidNonceLength:
            return "Classic transfer AES-GCM nonce length is invalid"
        case .invalidTagLength:
            return "Classic transfer AES-GCM authentication tag length is invalid"
        case .authenticationFailed:
            return "Classic transfer AES-GCM authentication failed"
        case .encryptionFailed:
            return "Classic transfer AES-GCM encryption failed"
        }
    }
}

public struct ClassicTransferEncryptedChunk: Sendable, Equatable {
    public let ciphertext: Data
    public let nonce: Data
    public let tag: Data
    public let plaintextSHA256Hex: String

    public init(
        ciphertext: Data,
        nonce: Data,
        tag: Data,
        plaintextSHA256Hex: String
    ) {
        self.ciphertext = ciphertext
        self.nonce = nonce
        self.tag = tag
        self.plaintextSHA256Hex = plaintextSHA256Hex
    }
}

/// Performs bounded per-chunk hashing and AES-GCM work away from application
/// lifecycle actors. The caller supplies the already-negotiated wire bound so
/// attacker-controlled ciphertext cannot trigger unbounded CryptoKit work.
public actor ClassicTransferChunkCryptoWorker {
    public static let shared = ClassicTransferChunkCryptoWorker()

    public func sealAndHash(
        payload: Data,
        plaintextChunk: Data,
        using key: SymmetricKey,
        maximumPayloadSize: Int,
        maximumPlaintextChunkSize: Int
    ) throws -> ClassicTransferEncryptedChunk {
        try Task.checkCancellation()
        guard maximumPayloadSize > 0, maximumPlaintextChunkSize > 0 else {
            throw ClassicTransferChunkCryptoError.invalidPayloadLimit
        }
        guard !payload.isEmpty, !plaintextChunk.isEmpty else {
            throw ClassicTransferChunkCryptoError.emptyPayload
        }
        guard payload.count <= maximumPayloadSize,
              plaintextChunk.count <= maximumPlaintextChunkSize else {
            throw ClassicTransferChunkCryptoError.payloadLimitExceeded
        }

        do {
            let sealedBox = try AES.GCM.seal(payload, using: key)
            let nonce = sealedBox.nonce.withUnsafeBytes { Data($0) }
            let checksum = SHA256.hash(data: plaintextChunk)
                .map { String(format: "%02x", $0) }
                .joined()
            return ClassicTransferEncryptedChunk(
                ciphertext: sealedBox.ciphertext,
                nonce: nonce,
                tag: sealedBox.tag,
                plaintextSHA256Hex: checksum
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ClassicTransferChunkCryptoError.encryptionFailed
        }
    }

    public func open(
        ciphertext: Data,
        nonce: Data,
        tag: Data,
        using key: SymmetricKey,
        maximumCiphertextSize: Int
    ) throws -> Data {
        try Task.checkCancellation()
        guard maximumCiphertextSize > 0 else {
            throw ClassicTransferChunkCryptoError.invalidPayloadLimit
        }
        guard !ciphertext.isEmpty else {
            throw ClassicTransferChunkCryptoError.emptyPayload
        }
        guard ciphertext.count <= maximumCiphertextSize else {
            throw ClassicTransferChunkCryptoError.payloadLimitExceeded
        }
        guard nonce.count == 12 else {
            throw ClassicTransferChunkCryptoError.invalidNonceLength
        }
        guard tag.count == 16 else {
            throw ClassicTransferChunkCryptoError.invalidTagLength
        }

        do {
            let sealedBox = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonce),
                ciphertext: ciphertext,
                tag: tag
            )
            return try AES.GCM.open(sealedBox, using: key)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ClassicTransferChunkCryptoError.authenticationFailed
        }
    }
}

public enum ClassicTransferJSONCodecError: Error, Equatable, LocalizedError, Sendable {
    case invalidSizeLimit
    case inputLimitExceeded
    case outputLimitExceeded
    case encodingFailed
    case decodingFailed

    public var errorDescription: String? {
        switch self {
        case .invalidSizeLimit:
            return "Classic transfer JSON size limit is invalid"
        case .inputLimitExceeded:
            return "Classic transfer JSON input exceeds its hard limit"
        case .outputLimitExceeded:
            return "Classic transfer JSON output exceeds its hard limit"
        case .encodingFailed:
            return "Classic transfer JSON encoding failed"
        case .decodingFailed:
            return "Classic transfer JSON decoding failed"
        }
    }
}

/// Serializes bounded classic-transfer JSON work and metadata validation away
/// from application lifecycle actors. Wire length must be checked before this
/// worker is invoked; the worker repeats the bound at the serialization edge.
public actor ClassicTransferJSONWorker {
    public static let shared = ClassicTransferJSONWorker()

    public func encode<Value: Encodable & Sendable>(
        _ value: Value,
        maximumOutputSize: Int
    ) throws -> Data {
        try Task.checkCancellation()
        guard maximumOutputSize > 0 else {
            throw ClassicTransferJSONCodecError.invalidSizeLimit
        }
        let encoded: Data
        do {
            encoded = try JSONEncoder().encode(value)
        } catch {
            throw ClassicTransferJSONCodecError.encodingFailed
        }
        guard encoded.count <= maximumOutputSize else {
            throw ClassicTransferJSONCodecError.outputLimitExceeded
        }
        return encoded
    }

    public func decode<Value: Decodable & Sendable>(
        _ type: Value.Type,
        from data: Data,
        maximumInputSize: Int
    ) throws -> Value {
        try Task.checkCancellation()
        guard maximumInputSize > 0 else {
            throw ClassicTransferJSONCodecError.invalidSizeLimit
        }
        guard !data.isEmpty, data.count <= maximumInputSize else {
            throw ClassicTransferJSONCodecError.inputLimitExceeded
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ClassicTransferJSONCodecError.decodingFailed
        }
    }

    public func validateMetadata(
        transferID: String,
        fileName: String,
        fileSize: Int64,
        fileHash: String,
        declaredChunkSize: Int,
        compression: String?,
        displayFields: [String?]
    ) throws {
        try Task.checkCancellation()
        try ClassicTransferMetadataContract.validate(
            transferID: transferID,
            fileName: fileName,
            fileSize: fileSize,
            fileHash: fileHash,
            declaredChunkSize: declaredChunkSize,
            compression: compression,
            displayFields: displayFields
        )
    }
}

public actor ClassicTransferZlibDecompressionWorker {
    public static let shared = ClassicTransferZlibDecompressionWorker()

    public func decompress(
        _ compressedData: Data,
        maximumOutputSize: Int
    ) throws -> Data {
        try ClassicTransferBoundedZlibDecompressor.decompress(
            compressedData,
            maximumOutputSize: maximumOutputSize
        )
    }
}

private enum ClassicTransferBoundedZlibDecompressor {
    private static let scratchBufferSize = 64 * 1024

    static func decompress(
        _ compressedData: Data,
        maximumOutputSize: Int
    ) throws -> Data {
        guard maximumOutputSize > 0 else {
            throw ClassicTransferZlibDecompressionError.invalidOutputLimit
        }
        guard !compressedData.isEmpty else {
            throw ClassicTransferZlibDecompressionError.invalidCompressedData
        }

        let scratchCapacity = min(scratchBufferSize, maximumOutputSize)
        let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, scratchCapacity))
        defer { scratch.deallocate() }

        var stream = compression_stream(
            dst_ptr: scratch,
            dst_size: 0,
            src_ptr: UnsafePointer(scratch),
            src_size: 0,
            state: nil
        )
        guard compression_stream_init(
            &stream,
            COMPRESSION_STREAM_DECODE,
            COMPRESSION_ZLIB
        ) != COMPRESSION_STATUS_ERROR else {
            throw ClassicTransferZlibDecompressionError.invalidCompressedData
        }
        defer { compression_stream_destroy(&stream) }

        return try compressedData.withUnsafeBytes { rawBuffer in
            guard let source = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                throw ClassicTransferZlibDecompressionError.invalidCompressedData
            }
            stream.src_ptr = source
            stream.src_size = rawBuffer.count

            var output = Data()
            output.reserveCapacity(min(maximumOutputSize, scratchBufferSize))

            while true {
                try Task.checkCancellation()

                let remainingOutputCapacity = maximumOutputSize - output.count
                // When the declared limit has been reached, one fixed scratch byte is used only
                // to distinguish an exact-size stream from an oversized stream. It is never
                // appended, so retained output remains hard-capped at maximumOutputSize.
                let writableCapacity = min(
                    max(1, scratchCapacity),
                    max(1, remainingOutputCapacity)
                )
                let sourceBytesBeforeProcessing = stream.src_size
                stream.dst_ptr = scratch
                stream.dst_size = writableCapacity

                let status = compression_stream_process(
                    &stream,
                    Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
                )
                let producedByteCount = writableCapacity - stream.dst_size

                guard producedByteCount <= remainingOutputCapacity else {
                    throw ClassicTransferZlibDecompressionError.outputLimitExceeded
                }
                if producedByteCount > 0 {
                    output.append(scratch, count: producedByteCount)
                }

                switch status {
                case COMPRESSION_STATUS_END:
                    guard stream.src_size == 0 else {
                        throw ClassicTransferZlibDecompressionError.invalidCompressedData
                    }
                    return output
                case COMPRESSION_STATUS_OK:
                    guard producedByteCount > 0 || stream.src_size < sourceBytesBeforeProcessing else {
                        throw ClassicTransferZlibDecompressionError.invalidCompressedData
                    }
                default:
                    throw ClassicTransferZlibDecompressionError.invalidCompressedData
                }
            }
        }
    }
}
