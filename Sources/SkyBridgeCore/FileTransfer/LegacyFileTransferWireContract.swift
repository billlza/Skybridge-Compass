import Foundation

/// Resource and semantic bounds for the pre-v2 `FileTransferEngine` wire format.
///
/// This protocol has no version negotiation for its former streaming-encryption
/// extension. Encrypted payloads above `maximumEncryptedFileSizeBytes` are
/// therefore rejected explicitly instead of emitting an ambiguous, truncated
/// ciphertext stream.
enum LegacyFileTransferWirePolicy {
    static let maximumMetadataBytes = 1 * 1_024 * 1_024
    static let maximumFileSizeBytes: Int64 = 2 * 1_024 * 1_024 * 1_024
    static let maximumEncryptedFileSizeBytes: Int64 = 32 * 1_024 * 1_024
    static let minimumChunkSizeBytes = 64 * 1_024
    static let maximumChunkSizeBytes = 16 * 1_024 * 1_024
    static let maximumChunkCount = 65_536
    static let maximumSignatureBytes = 64 * 1_024
}

enum LegacyFileTransferWireContractError: Error, Equatable, Sendable {
    case invalidTransferIdentifier
    case invalidFileName
    case invalidFileSize
    case unsupportedEncryptedFileSize
    case invalidFileHash
    case invalidMerkleRoot
    case unsupportedHashAlgorithm
    case invalidChunkSize
    case excessiveChunkCount
    case missingSignature
    case invalidSignature
    case invalidSignatureAlgorithm
    case invalidSignerIdentifier
    case invalidPacketFlags
    case invalidChunkSequence
    case invalidPacketEncryption
    case invalidPacketCompression
    case invalidPacketLength
    case invalidChunkHash
    case invalidEncryptedPayloadEncoding
    case invalidDecodedChunkLength
    case incompleteTransfer
}

enum LegacyFileTransferWireContract {
    static func validatePreflight(
        transferID: String,
        fileName: String,
        fileSize: Int64,
        chunkSize: Int,
        encryptionEnabled: Bool
    ) throws {
        try validateCanonicalTransferIdentifier(transferID)
        do {
            try ClassicTransferMetadataContract.validateFileName(fileName)
        } catch {
            throw LegacyFileTransferWireContractError.invalidFileName
        }
        guard fileSize >= 0,
              fileSize <= LegacyFileTransferWirePolicy.maximumFileSizeBytes else {
            throw LegacyFileTransferWireContractError.invalidFileSize
        }
        guard !encryptionEnabled
                || fileSize <= LegacyFileTransferWirePolicy.maximumEncryptedFileSizeBytes else {
            throw LegacyFileTransferWireContractError.unsupportedEncryptedFileSize
        }
        _ = try expectedChunkCount(fileSize: fileSize, chunkSize: chunkSize)
    }

    @discardableResult
    static func validate(_ metadata: FileTransferMetadata) throws -> Int {
        try validatePreflight(
            transferID: metadata.transferId,
            fileName: metadata.fileName,
            fileSize: metadata.fileSize,
            chunkSize: metadata.chunkSize,
            encryptionEnabled: metadata.encryptionEnabled
        )
        do {
            try ClassicTransferMetadataContract.validateSHA256Hex(metadata.checksum)
        } catch {
            throw LegacyFileTransferWireContractError.invalidFileHash
        }
        if let merkleRoot = metadata.merkleRoot {
            do {
                try ClassicTransferMetadataContract.validateSHA256Hex(merkleRoot)
            } catch {
                throw LegacyFileTransferWireContractError.invalidMerkleRoot
            }
        }
        guard metadata.hashAlgorithm == "SHA256" else {
            throw LegacyFileTransferWireContractError.unsupportedHashAlgorithm
        }
        guard let signature = metadata.fileSignature else {
            throw LegacyFileTransferWireContractError.missingSignature
        }
        guard !signature.isEmpty,
              signature.count <= LegacyFileTransferWirePolicy.maximumSignatureBytes else {
            throw LegacyFileTransferWireContractError.invalidSignature
        }
        guard let signatureAlgorithm = metadata.signatureAlgorithm,
              !signatureAlgorithm.isEmpty else {
            throw LegacyFileTransferWireContractError.invalidSignatureAlgorithm
        }
        do {
            try ClassicTransferMetadataContract.validateVisibleField(
                signatureAlgorithm,
                maximumUTF8Length: 128
            )
        } catch {
            throw LegacyFileTransferWireContractError.invalidSignatureAlgorithm
        }
        guard let signerIdentifier = metadata.signerPeerId,
              !signerIdentifier.isEmpty else {
            throw LegacyFileTransferWireContractError.invalidSignerIdentifier
        }
        do {
            try ClassicTransferMetadataContract.validateVisibleField(
                signerIdentifier,
                maximumUTF8Length: 256
            )
        } catch {
            throw LegacyFileTransferWireContractError.invalidSignerIdentifier
        }
        return try expectedChunkCount(fileSize: metadata.fileSize, chunkSize: metadata.chunkSize)
    }

    static func expectedChunkCount(fileSize: Int64, chunkSize: Int) throws -> Int {
        guard chunkSize >= LegacyFileTransferWirePolicy.minimumChunkSizeBytes,
              chunkSize <= LegacyFileTransferWirePolicy.maximumChunkSizeBytes else {
            throw LegacyFileTransferWireContractError.invalidChunkSize
        }
        guard fileSize >= 0,
              fileSize <= LegacyFileTransferWirePolicy.maximumFileSizeBytes else {
            throw LegacyFileTransferWireContractError.invalidFileSize
        }
        let chunkCount: Int64
        if fileSize == 0 {
            chunkCount = 0
        } else {
            chunkCount = ((fileSize - 1) / Int64(chunkSize)) + 1
        }
        guard chunkCount <= Int64(LegacyFileTransferWirePolicy.maximumChunkCount) else {
            throw LegacyFileTransferWireContractError.excessiveChunkCount
        }
        return Int(chunkCount)
    }

    static func validatePacketHeader(
        transferID: String,
        chunkIndex: UInt32,
        totalChunks: UInt32,
        dataLength: UInt64,
        checksum: String,
        flags: UInt8,
        metadata: FileTransferMetadata,
        expectedChunkIndex: Int
    ) throws -> Int {
        let expectedTotalChunks = try expectedChunkCount(
            fileSize: metadata.fileSize,
            chunkSize: metadata.chunkSize
        )
        guard transferID == metadata.transferId,
              Int(chunkIndex) == expectedChunkIndex,
              Int(totalChunks) == expectedTotalChunks else {
            throw LegacyFileTransferWireContractError.invalidChunkSequence
        }
        guard flags & ~UInt8(0x03) == 0 else {
            throw LegacyFileTransferWireContractError.invalidPacketFlags
        }
        let isCompressed = flags & 0x01 != 0
        let isEncrypted = flags & 0x02 != 0
        guard isEncrypted == metadata.encryptionEnabled else {
            throw LegacyFileTransferWireContractError.invalidPacketEncryption
        }
        guard metadata.compressionEnabled || !isCompressed else {
            throw LegacyFileTransferWireContractError.invalidPacketCompression
        }
        do {
            try ClassicTransferMetadataContract.validateSHA256Hex(checksum)
        } catch {
            throw LegacyFileTransferWireContractError.invalidChunkHash
        }

        let maximumLength = try maximumWireChunkLength(
            declaredChunkSize: metadata.chunkSize,
            encryptionEnabled: metadata.encryptionEnabled
        )
        guard dataLength > 0,
              dataLength <= maximumLength,
              dataLength <= UInt64(Int.max) else {
            throw LegacyFileTransferWireContractError.invalidPacketLength
        }
        return Int(dataLength)
    }

    static func expectedDecodedChunkLength(
        metadata: FileTransferMetadata,
        receivedBytes: Int64
    ) throws -> Int {
        guard receivedBytes >= 0,
              receivedBytes < metadata.fileSize else {
            throw LegacyFileTransferWireContractError.invalidDecodedChunkLength
        }
        let remaining = metadata.fileSize - receivedBytes
        return Int(min(Int64(metadata.chunkSize), remaining))
    }

    static func validateDecodedChunkLength(
        _ decodedLength: Int,
        metadata: FileTransferMetadata,
        receivedBytes: Int64
    ) throws {
        let expected = try expectedDecodedChunkLength(
            metadata: metadata,
            receivedBytes: receivedBytes
        )
        guard decodedLength == expected else {
            throw LegacyFileTransferWireContractError.invalidDecodedChunkLength
        }
    }

    static func validateCompletion(receivedBytes: Int64, metadata: FileTransferMetadata) throws {
        guard receivedBytes == metadata.fileSize else {
            throw LegacyFileTransferWireContractError.incompleteTransfer
        }
    }

    /// The legacy ABI authenticates an RFC 4648 Base64 representation rather
    /// than the raw chunk. Keep both directions here so sender and receiver
    /// cannot silently drift to different plaintext domains.
    static func encryptionPlaintext(for payload: Data) -> Data {
        payload.base64EncodedData()
    }

    static func decodeEncryptionPlaintext(_ encodedPayload: Data) throws -> Data {
        guard let payload = Data(base64Encoded: encodedPayload, options: []),
              payload.base64EncodedData() == encodedPayload else {
            throw LegacyFileTransferWireContractError.invalidEncryptedPayloadEncoding
        }
        return payload
    }

    static func decodeEncryptionPlaintext(_ encodedPayload: String) throws -> Data {
        try decodeEncryptionPlaintext(Data(encodedPayload.utf8))
    }

    private static func validateCanonicalTransferIdentifier(_ transferID: String) throws {
        guard transferID.utf8.count == 36,
              let identifier = UUID(uuidString: transferID),
              identifier.uuidString == transferID else {
            throw LegacyFileTransferWireContractError.invalidTransferIdentifier
        }
    }

    private static func maximumWireChunkLength(
        declaredChunkSize: Int,
        encryptionEnabled: Bool
    ) throws -> UInt64 {
        guard declaredChunkSize >= LegacyFileTransferWirePolicy.minimumChunkSizeBytes,
              declaredChunkSize <= LegacyFileTransferWirePolicy.maximumChunkSizeBytes else {
            throw LegacyFileTransferWireContractError.invalidChunkSize
        }
        guard encryptionEnabled else {
            return UInt64(declaredChunkSize)
        }
        // Legacy per-chunk encryption base64-encodes plaintext before AES-GCM;
        // AES-GCM ciphertext has the same byte count as that encoded input.
        let groups = (UInt64(declaredChunkSize) + 2) / 3
        return groups * 4
    }
}
