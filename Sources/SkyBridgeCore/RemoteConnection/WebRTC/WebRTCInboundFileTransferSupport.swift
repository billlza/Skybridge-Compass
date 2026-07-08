import CryptoKit
import Foundation

@available(macOS 14.0, iOS 17.0, *)
struct WebRTCInboundFileTransferState {
    let transferId: String
    let fileName: String
    let fileSize: Int64
    let chunkSize: Int
    let totalChunks: Int
    let senderDeviceId: String
    let senderDeviceName: String?
    let tempURL: URL
    let finalURL: URL
    let handle: FileHandle
    var receivedBytes: Int64
    var completeRequestedAt: Date? = nil
    var expectedFileSha256: Data? = nil
    var expectedMerkleRoot: Data? = nil
    var expectedMerkleSig: Data? = nil
    var expectedMerkleSigAlg: String? = nil
    var chunkHashes: [Int: Data] = [:]
    var receivedChunkSizes: [Int: Int] = [:]
}

@available(macOS 14.0, iOS 17.0, *)
struct WebRTCInboundFileTransferApprovalRequest: Sendable, Equatable {
    let transferId: String
    let fileName: String
    let fileSize: Int64
    let chunkSize: Int
    let totalChunks: Int
    let senderDeviceId: String
    let senderDeviceName: String
    let endpointDescription: String
    let destinationDirectoryPath: String
    let proposedSavePath: String
}

@available(macOS 14.0, iOS 17.0, *)
enum WebRTCInboundFileTransferApprovalDecision: Sendable, Equatable {
    case approved
    case rejected(reason: String)
}

@available(macOS 14.0, iOS 17.0, *)
enum WebRTCInboundFileTransferIntegrityFailure: Equatable {
    case merkleRootMismatch
    case unknownMerkleSignatureAlgorithm
    case merkleSignatureMismatch
    case fileSHA256Unavailable
    case fileSHA256Mismatch
    case fileHandleCloseFailed

    var message: String {
        switch self {
        case .merkleRootMismatch:
            return "merkle root mismatch"
        case .unknownMerkleSignatureAlgorithm:
            return "unknown merkle sig alg"
        case .merkleSignatureMismatch:
            return "merkle signature mismatch"
        case .fileSHA256Unavailable:
            return "file sha256 unavailable"
        case .fileSHA256Mismatch:
            return "file sha256 mismatch"
        case .fileHandleCloseFailed:
            return "file handle close failed"
        }
    }
}

@available(macOS 14.0, iOS 17.0, *)
enum WebRTCInboundFileTransferSupport {
    static let maxChunkSize = 512 * 1024
    static let transferIdLength = 36
    static let explicitApprovalRequiredMessage = "inbound_file_transfer_requires_explicit_approval"
    static let missingSenderIdentityMessage = "inbound_file_transfer_missing_sender_identity"

    static func normalizedApprovalRejectionMessage(_ reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? explicitApprovalRequiredMessage : trimmed
    }

    static func requiredSenderDeviceId(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func sanitizedFileName(_ name: String) -> String {
        FileTransferPathPolicy.sanitizedFileName(name)
    }

    static func uniqueDestinationURL(baseDirectory: URL, fileName: String) throws -> URL {
        try FileTransferPathPolicy.uniqueDestinationURL(
            baseDirectory: baseDirectory,
            fileName: fileName
        )
    }

    static func sha256File(at url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)

        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 256 * 1024)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = Data(hasher.finalize())
        try handle.close()
        return digest
    }

    static func expectedChunkCount(fileSize: Int64, chunkSize: Int) -> Int? {
        guard chunkSize > 0 else { return nil }
        if fileSize == 0 { return 0 }
        let total = (fileSize + Int64(chunkSize) - 1) / Int64(chunkSize)
        guard total >= 0, total <= Int64(Int.max) else { return nil }
        return Int(total)
    }

    static func validateTransferId(_ transferId: String) -> String? {
        guard transferId.count == transferIdLength,
              transferId.trimmingCharacters(in: .whitespacesAndNewlines) == transferId,
              UUID(uuidString: transferId) != nil else {
            return "Invalid metadata (invalid transferId)"
        }
        return nil
    }

    static func validateMetadata(
        fileName: String,
        fileSize: Int64,
        chunkSize: Int,
        totalChunks: Int
    ) -> String? {
        guard !fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Invalid metadata (empty fileName)"
        }
        do {
            _ = try FileTransferPathPolicy.validatedFileName(fileName)
        } catch {
            return "Invalid metadata (unsafe fileName)"
        }
        guard fileSize >= 0 else {
            return "Invalid metadata (negative fileSize)"
        }
        guard chunkSize > 0, chunkSize <= maxChunkSize else {
            return "Invalid metadata (chunkSize out of range)"
        }
        guard totalChunks >= 0 else {
            return "Invalid metadata (negative totalChunks)"
        }
        guard let expectedTotalChunks = expectedChunkCount(fileSize: fileSize, chunkSize: chunkSize),
              expectedTotalChunks == totalChunks else {
            return "Invalid metadata (fileSize/chunkSize/totalChunks mismatch)"
        }
        return nil
    }

    static func expectedChunkSize(state: WebRTCInboundFileTransferState, index: Int) -> Int? {
        guard index >= 0, index < state.totalChunks else { return nil }
        let offset = Int64(index) * Int64(state.chunkSize)
        guard offset >= 0, offset <= state.fileSize else { return nil }
        let remaining = state.fileSize - offset
        guard remaining >= 0 else { return nil }
        return Int(min(Int64(state.chunkSize), remaining))
    }

    static func hasRequiredIntegrityProof(_ state: WebRTCInboundFileTransferState) -> Bool {
        if state.expectedFileSha256 != nil {
            return true
        }
        return state.expectedMerkleRoot != nil
            && state.expectedMerkleSig != nil
            && state.expectedMerkleSigAlg == CrossNetworkMerkleAuth.signatureAlgV1
    }

    static func integrityFailure(
        state: WebRTCInboundFileTransferState,
        receiveKey: Data
    ) -> WebRTCInboundFileTransferIntegrityFailure? {
        if let expectedMerkleRoot = state.expectedMerkleRoot {
            let leaves: [Data] = (0..<state.totalChunks).compactMap { state.chunkHashes[$0] }
            if leaves.count != state.totalChunks
                || CrossNetworkMerkle.root(leaves: leaves) != expectedMerkleRoot {
                return .merkleRootMismatch
            }

            if let expectedSignature = state.expectedMerkleSig {
                guard state.expectedMerkleSigAlg == CrossNetworkMerkleAuth.signatureAlgV1 else {
                    return .unknownMerkleSignatureAlgorithm
                }

                let preimage = CrossNetworkMerkleAuth.preimage(
                    transferId: state.transferId,
                    merkleRoot: expectedMerkleRoot,
                    fileSha256: state.expectedFileSha256
                )
                let actualSignature = CrossNetworkMerkleAuth.hmacSha256(
                    key: receiveKey,
                    data: preimage
                )
                guard expectedSignature == actualSignature else {
                    return .merkleSignatureMismatch
                }
            }
        }

        if let expectedFileSha256 = state.expectedFileSha256 {
            do {
                let actualFileSha256 = try sha256File(at: state.tempURL)
                if actualFileSha256 != expectedFileSha256 {
                    return .fileSHA256Mismatch
                }
            } catch {
                return .fileSHA256Unavailable
            }
        }

        return nil
    }
}
