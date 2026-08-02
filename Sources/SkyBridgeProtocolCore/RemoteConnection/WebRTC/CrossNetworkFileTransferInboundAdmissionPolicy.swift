import Foundation

/// Fail-closed wire admission for authenticated inbound WebRTC file-transfer
/// requests. Both Apple products use this policy before retaining a decoded
/// request outside the control-channel receive loop.
public enum CrossNetworkFileTransferInboundAdmissionPolicy {
    public static let currentVersion = 1
    public static let maximumFileSize: Int64 = 2 * 1024 * 1024 * 1024
    public static let maximumChunkDataByteCount = 512 * 1024
    public static let maximumChunkCount = 65_536
    public static let maximumQueuedOperationCount = 128
    public static let maximumRetainedOperationBytes = 16 * 1024 * 1024
    public static let maximumStatusMessageUTF8ByteCount = 512
    public static let maximumMissingChunkCount = 512

    private static let maximumDeviceIdentityUTF8ByteCount = 256
    private static let maximumDisplayNameUTF8ByteCount = 256
    private static let maximumMIMETypeUTF8ByteCount = 256
    private static let sha256ByteCount = 32

    /// Validates the decoded request shape and returns the byte charge that must
    /// remain reserved until the operation has actually finished, not merely
    /// until it has been dequeued.
    public static func retainedByteCharge(
        for message: CrossNetworkFileTransferMessage,
        encodedPayloadByteCount: Int
    ) throws -> Int {
        guard encodedPayloadByteCount > 0,
              encodedPayloadByteCount <= CrossNetworkFileTransferWireDecoder
                .maximumEncodedPayloadByteCount else {
            throw CrossNetworkFileTransferInboundAdmissionError.encodedPayloadSizeOutOfRange(
                actual: encodedPayloadByteCount,
                maximum: CrossNetworkFileTransferWireDecoder
                    .maximumEncodedPayloadByteCount
            )
        }
        try validateEnvelope(message)

        switch message.op {
        case .metadata:
            try validateMetadata(message)
        case .chunk:
            try validateChunk(message)
        case .complete:
            try validateComplete(message)
        case .cancel:
            try validateCancel(message)
        case .error, .metadataAck, .chunkAck, .completeAck:
            throw CrossNetworkFileTransferInboundAdmissionError.responseOperationInRequestQueue(
                message.op
            )
        }
        return encodedPayloadByteCount
    }

    /// Validates synchronous sender-facing responses before either platform
    /// resumes a waiter. This mirrors the strict Rust v1 response shapes and
    /// prevents an authenticated peer from smuggling unrelated large fields
    /// through an ACK or error operation.
    public static func validateInboundResponse(
        _ message: CrossNetworkFileTransferMessage
    ) throws {
        try validateEnvelope(message)
        try validateNoResponseCrossOperationFields(message)

        switch message.op {
        case .metadataAck:
            guard message.chunkIndex == nil,
                  message.receivedBytes == nil,
                  message.fileSha256 == nil,
                  message.missingChunks == nil,
                  message.message == nil else {
                throw invalidShape(message.op, "metadata acknowledgement fields")
            }
        case .chunkAck:
            try validateChunkAcknowledgement(message)
        case .completeAck:
            guard message.chunkIndex == nil,
                  let receivedBytes = message.receivedBytes,
                  (0...maximumFileSize).contains(receivedBytes),
                  message.fileSha256?.count == sha256ByteCount,
                  message.missingChunks == nil,
                  message.message == nil else {
                throw invalidShape(message.op, "completion acknowledgement fields")
            }
        case .error:
            guard message.receivedBytes == nil,
                  message.fileSha256 == nil,
                  message.missingChunks == nil,
                  let statusMessage = message.message else {
                throw invalidShape(message.op, "error fields")
            }
            if let chunkIndex = message.chunkIndex,
               !(0..<maximumChunkCount).contains(chunkIndex) {
                throw CrossNetworkFileTransferInboundAdmissionError.invalidField(
                    "chunkIndex"
                )
            }
            try validateVisible(
                statusMessage,
                field: "message",
                maximumUTF8ByteCount: maximumStatusMessageUTF8ByteCount,
                requiresNonEmptyValue: true
            )
        case .metadata, .chunk, .complete, .cancel:
            throw CrossNetworkFileTransferInboundAdmissionError
                .requestOperationInResponsePath(message.op)
        }
    }

    /// Overflow-safe budget admission shared by both platform queue owners.
    public static func canReserve(
        currentRetainedByteCount: Int,
        additionalByteCount: Int
    ) -> Bool {
        guard currentRetainedByteCount >= 0,
              additionalByteCount > 0,
              currentRetainedByteCount <= maximumRetainedOperationBytes,
              additionalByteCount <= maximumRetainedOperationBytes else {
            return false
        }
        return currentRetainedByteCount
            <= maximumRetainedOperationBytes - additionalByteCount
    }

    private static func validateMetadata(
        _ message: CrossNetworkFileTransferMessage
    ) throws {
        guard let senderDeviceId = message.senderDeviceId,
              let fileName = message.fileName,
              let fileSize = message.fileSize,
              let chunkSize = message.chunkSize,
              let totalChunks = message.totalChunks else {
            throw invalidShape(message.op, "required metadata fields")
        }
        guard message.chunkIndex == nil,
              message.chunkData == nil,
              message.chunkSha256 == nil,
              message.nonce == nil,
              message.rawSize == nil,
              message.receivedBytes == nil,
              message.fileSha256 == nil,
              message.merkleRoot == nil,
              message.merkleRootSignature == nil,
              message.merkleRootSignatureAlg == nil,
              message.missingChunks == nil,
              message.encryption == nil,
              message.batchId == nil,
              message.batchIndex == nil,
              message.batchTotal == nil,
              message.relativePath == nil,
              message.message == nil else {
            throw invalidShape(message.op, "non-metadata fields")
        }

        try validateVisible(
            senderDeviceId,
            field: "senderDeviceId",
            maximumUTF8ByteCount: maximumDeviceIdentityUTF8ByteCount,
            requiresNonEmptyValue: true
        )
        try validateVisible(
            message.senderDeviceName,
            field: "senderDeviceName",
            maximumUTF8ByteCount: maximumDisplayNameUTF8ByteCount
        )
        do {
            try ClassicTransferMetadataContract.validateFileName(fileName)
        } catch {
            throw CrossNetworkFileTransferInboundAdmissionError.invalidField("fileName")
        }
        guard fileSize >= 0, fileSize <= maximumFileSize else {
            throw CrossNetworkFileTransferInboundAdmissionError.invalidField("fileSize")
        }
        guard chunkSize > 0, chunkSize <= maximumChunkDataByteCount else {
            throw CrossNetworkFileTransferInboundAdmissionError.invalidField("chunkSize")
        }
        guard totalChunks >= 0, totalChunks <= maximumChunkCount else {
            throw CrossNetworkFileTransferInboundAdmissionError.invalidField("totalChunks")
        }
        let expectedChunkCount = fileSize == 0
            ? 0
            : Int(((fileSize - 1) / Int64(chunkSize)) + 1)
        guard expectedChunkCount == totalChunks else {
            throw CrossNetworkFileTransferInboundAdmissionError.invalidField(
                "fileSize/chunkSize/totalChunks"
            )
        }

        try validateVisible(
            message.mimeType,
            field: "mimeType",
            maximumUTF8ByteCount: maximumMIMETypeUTF8ByteCount
        )
    }

    private static func validateChunk(
        _ message: CrossNetworkFileTransferMessage
    ) throws {
        guard let chunkIndex = message.chunkIndex,
              let chunkData = message.chunkData else {
            throw invalidShape(message.op, "chunkIndex/chunkData")
        }
        guard message.senderDeviceId == nil,
              message.senderDeviceName == nil,
              message.fileName == nil,
              message.fileSize == nil,
              message.chunkSize == nil,
              message.totalChunks == nil,
              message.mimeType == nil,
              message.nonce == nil,
              message.receivedBytes == nil,
              message.encryption == nil,
              message.fileSha256 == nil,
              message.merkleRoot == nil,
              message.merkleRootSignature == nil,
              message.merkleRootSignatureAlg == nil,
              message.missingChunks == nil,
              message.batchId == nil,
              message.batchIndex == nil,
              message.batchTotal == nil,
              message.relativePath == nil,
              message.message == nil else {
            throw invalidShape(message.op, "non-chunk fields")
        }
        guard chunkIndex >= 0, chunkIndex < maximumChunkCount else {
            throw CrossNetworkFileTransferInboundAdmissionError.invalidField("chunkIndex")
        }
        guard !chunkData.isEmpty,
              chunkData.count <= maximumChunkDataByteCount else {
            throw CrossNetworkFileTransferInboundAdmissionError.invalidField("chunkData")
        }
        if let rawSize = message.rawSize, rawSize != chunkData.count {
            throw CrossNetworkFileTransferInboundAdmissionError.invalidField("rawSize")
        }
        if let chunkSha256 = message.chunkSha256,
           chunkSha256.count != sha256ByteCount {
            throw CrossNetworkFileTransferInboundAdmissionError.invalidField("chunkSha256")
        }
    }

    private static func validateComplete(
        _ message: CrossNetworkFileTransferMessage
    ) throws {
        guard message.senderDeviceId == nil,
              message.senderDeviceName == nil,
              message.fileName == nil,
              message.fileSize == nil,
              message.chunkSize == nil,
              message.totalChunks == nil,
              message.mimeType == nil,
              message.chunkIndex == nil,
              message.chunkData == nil,
              message.chunkSha256 == nil,
              message.nonce == nil,
              message.rawSize == nil,
              message.encryption == nil,
              message.missingChunks == nil,
              message.batchId == nil,
              message.batchIndex == nil,
              message.batchTotal == nil,
              message.relativePath == nil,
              message.message == nil else {
            throw invalidShape(message.op, "non-completion fields")
        }
        if let receivedBytes = message.receivedBytes,
           !(0...maximumFileSize).contains(receivedBytes) {
            throw CrossNetworkFileTransferInboundAdmissionError.invalidField("receivedBytes")
        }
        if let fileSha256 = message.fileSha256,
           fileSha256.count != sha256ByteCount {
            throw CrossNetworkFileTransferInboundAdmissionError.invalidField("fileSha256")
        }

        let hasAnyMerkleField = message.merkleRoot != nil
            || message.merkleRootSignature != nil
            || message.merkleRootSignatureAlg != nil
        if hasAnyMerkleField {
            guard message.merkleRoot?.count == sha256ByteCount,
                  message.merkleRootSignature?.count == sha256ByteCount,
                  message.merkleRootSignatureAlg == CrossNetworkMerkleAuth.signatureAlgV1 else {
                throw CrossNetworkFileTransferInboundAdmissionError.invalidField(
                    "merkle integrity proof"
                )
            }
        }
    }

    private static func validateCancel(
        _ message: CrossNetworkFileTransferMessage
    ) throws {
        guard message.senderDeviceId == nil,
              message.senderDeviceName == nil,
              message.fileName == nil,
              message.fileSize == nil,
              message.chunkSize == nil,
              message.totalChunks == nil,
              message.mimeType == nil,
              message.chunkIndex == nil,
              message.chunkData == nil,
              message.chunkSha256 == nil,
              message.nonce == nil,
              message.rawSize == nil,
              message.receivedBytes == nil,
              message.encryption == nil,
              message.fileSha256 == nil,
              message.merkleRoot == nil,
              message.merkleRootSignature == nil,
              message.merkleRootSignatureAlg == nil,
              message.missingChunks == nil,
              message.batchId == nil,
              message.batchIndex == nil,
              message.batchTotal == nil,
              message.relativePath == nil else {
            throw invalidShape(message.op, "non-cancellation fields")
        }
        try validateVisible(
            message.message,
            field: "message",
            maximumUTF8ByteCount: maximumStatusMessageUTF8ByteCount
        )
    }

    public static func validateEnvelope(
        _ message: CrossNetworkFileTransferMessage
    ) throws {
        guard message.version == currentVersion else {
            throw CrossNetworkFileTransferInboundAdmissionError.unsupportedVersion(
                message.version
            )
        }
        let nilTransferIdentifier = UUID(
            uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        )
        guard message.transferId.utf8.count == 36,
              message.transferId.trimmingCharacters(in: .whitespacesAndNewlines)
                == message.transferId,
              let transferIdentifier = UUID(uuidString: message.transferId),
              transferIdentifier != nilTransferIdentifier else {
            throw CrossNetworkFileTransferInboundAdmissionError.invalidTransferIdentifier
        }
    }

    private static func validateNoResponseCrossOperationFields(
        _ message: CrossNetworkFileTransferMessage
    ) throws {
        guard message.senderDeviceId == nil,
              message.senderDeviceName == nil,
              message.fileName == nil,
              message.fileSize == nil,
              message.chunkSize == nil,
              message.totalChunks == nil,
              message.mimeType == nil,
              message.chunkData == nil,
              message.chunkSha256 == nil,
              message.nonce == nil,
              message.rawSize == nil,
              message.encryption == nil,
              message.merkleRoot == nil,
              message.merkleRootSignature == nil,
              message.merkleRootSignatureAlg == nil,
              message.batchId == nil,
              message.batchIndex == nil,
              message.batchTotal == nil,
              message.relativePath == nil else {
            throw invalidShape(message.op, "cross-operation response fields")
        }
    }

    private static func validateChunkAcknowledgement(
        _ message: CrossNetworkFileTransferMessage
    ) throws {
        let hasReceivedAcknowledgement = message.chunkIndex != nil
            || message.receivedBytes != nil
        let hasMissingChunkRequest = message.missingChunks != nil
            || message.message != nil

        switch (hasReceivedAcknowledgement, hasMissingChunkRequest) {
        case (true, false):
            guard let chunkIndex = message.chunkIndex,
                  (0..<maximumChunkCount).contains(chunkIndex),
                  let receivedBytes = message.receivedBytes,
                  (0...maximumFileSize).contains(receivedBytes),
                  message.fileSha256 == nil else {
                throw invalidShape(message.op, "received acknowledgement fields")
            }
        case (false, true):
            guard message.fileSha256 == nil,
                  message.message == "missingChunks",
                  let missingChunks = message.missingChunks,
                  !missingChunks.isEmpty,
                  missingChunks.count <= maximumMissingChunkCount,
                  missingChunks.allSatisfy({ (0..<maximumChunkCount).contains($0) }),
                  missingChunks.indices.dropFirst().allSatisfy({ index in
                      missingChunks[index - 1] < missingChunks[index]
                  }) else {
                throw invalidShape(message.op, "missing-chunk acknowledgement fields")
            }
        case (false, false), (true, true):
            throw invalidShape(message.op, "chunk acknowledgement variant")
        }
    }

    private static func validateVisible(
        _ value: String?,
        field: String,
        maximumUTF8ByteCount: Int,
        requiresNonEmptyValue: Bool = false
    ) throws {
        if requiresNonEmptyValue,
           value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            throw CrossNetworkFileTransferInboundAdmissionError.invalidField(field)
        }
        do {
            try ClassicTransferMetadataContract.validateVisibleField(
                value,
                maximumUTF8Length: maximumUTF8ByteCount
            )
        } catch {
            throw CrossNetworkFileTransferInboundAdmissionError.invalidField(field)
        }
    }

    private static func invalidShape(
        _ op: CrossNetworkFileTransferOp,
        _ fieldGroup: String
    ) -> CrossNetworkFileTransferInboundAdmissionError {
        .invalidOperationShape(operation: op, fieldGroup: fieldGroup)
    }
}

public enum CrossNetworkFileTransferInboundAdmissionError: Error, LocalizedError, Sendable {
    case encodedPayloadSizeOutOfRange(actual: Int, maximum: Int)
    case unsupportedVersion(Int)
    case invalidTransferIdentifier
    case responseOperationInRequestQueue(CrossNetworkFileTransferOp)
    case requestOperationInResponsePath(CrossNetworkFileTransferOp)
    case invalidOperationShape(operation: CrossNetworkFileTransferOp, fieldGroup: String)
    case invalidField(String)
    case retainedByteCapacityExceeded(maximum: Int)
    case operationCapacityExceeded(maximum: Int)
    case invalidReservationByteCount
    case reservationIdentifierCollision

    public var errorDescription: String? {
        switch self {
        case .encodedPayloadSizeOutOfRange(let actual, let maximum):
            return "WebRTC inbound file-transfer payload bytes=\(actual) exceed range=1...\(maximum)"
        case .unsupportedVersion(let version):
            return "WebRTC inbound file-transfer version=\(version) is unsupported"
        case .invalidTransferIdentifier:
            return "WebRTC inbound file-transfer request has an invalid transfer identifier"
        case .responseOperationInRequestQueue(let operation):
            return "WebRTC inbound file-transfer response operation=\(operation.rawValue) cannot enter the request queue"
        case .requestOperationInResponsePath(let operation):
            return "WebRTC inbound file-transfer request operation=\(operation.rawValue) cannot enter the response path"
        case .invalidOperationShape(let operation, let fieldGroup):
            return "WebRTC inbound file-transfer operation=\(operation.rawValue) has invalid \(fieldGroup)"
        case .invalidField(let field):
            return "WebRTC inbound file-transfer message has invalid field=\(field)"
        case .retainedByteCapacityExceeded(let maximum):
            return "WebRTC inbound file-transfer retained-byte budget exceeded maximum=\(maximum)"
        case .operationCapacityExceeded(let maximum):
            return "WebRTC inbound file-transfer operation capacity exceeded maximum=\(maximum)"
        case .invalidReservationByteCount:
            return "WebRTC inbound file-transfer reservation byte count is invalid"
        case .reservationIdentifierCollision:
            return "WebRTC inbound file-transfer reservation identifier collided"
        }
    }
}

/// Exact-owner ledger for every admitted operation, including operations that
/// have already been dequeued but have not actually returned from their handler.
/// Deliberately exposes no reset operation: teardown must release only the
/// queued reservations it truly removed, while quarantined workers retain their
/// reservations until they exit.
public struct CrossNetworkFileTransferOperationReservationLedger: Sendable {
    public struct Reservation: Hashable, Sendable {
        fileprivate let identifier: UUID
    }

    private var byteCountByReservationID: [UUID: Int] = [:]
    public private(set) var retainedByteCount = 0

    public init() {}

    public var reservationCount: Int {
        byteCountByReservationID.count
    }

    public var isEmpty: Bool {
        byteCountByReservationID.isEmpty
    }

    public mutating func reserve(byteCount: Int) throws -> Reservation {
        guard byteCount > 0 else {
            throw CrossNetworkFileTransferInboundAdmissionError
                .invalidReservationByteCount
        }
        guard reservationCount
                < CrossNetworkFileTransferInboundAdmissionPolicy
                    .maximumQueuedOperationCount else {
            throw CrossNetworkFileTransferInboundAdmissionError.operationCapacityExceeded(
                maximum: CrossNetworkFileTransferInboundAdmissionPolicy
                    .maximumQueuedOperationCount
            )
        }
        guard CrossNetworkFileTransferInboundAdmissionPolicy.canReserve(
            currentRetainedByteCount: retainedByteCount,
            additionalByteCount: byteCount
        ) else {
            throw CrossNetworkFileTransferInboundAdmissionError
                .retainedByteCapacityExceeded(
                    maximum: CrossNetworkFileTransferInboundAdmissionPolicy
                        .maximumRetainedOperationBytes
                )
        }
        let identifier = UUID()
        guard byteCountByReservationID[identifier] == nil else {
            throw CrossNetworkFileTransferInboundAdmissionError
                .reservationIdentifierCollision
        }
        byteCountByReservationID[identifier] = byteCount
        retainedByteCount += byteCount
        return Reservation(identifier: identifier)
    }

    /// Returns false for a stale, foreign, or already released token.
    @discardableResult
    public mutating func release(_ reservation: Reservation) -> Bool {
        guard let byteCount = byteCountByReservationID[reservation.identifier],
              retainedByteCount >= byteCount else {
            return false
        }
        byteCountByReservationID.removeValue(forKey: reservation.identifier)
        retainedByteCount -= byteCount
        return true
    }

    public func contains(_ reservation: Reservation) -> Bool {
        byteCountByReservationID[reservation.identifier] != nil
    }
}
