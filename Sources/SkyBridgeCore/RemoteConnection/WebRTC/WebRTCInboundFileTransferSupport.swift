import Foundation
import SkyBridgeProtocolCore

@available(macOS 14.0, iOS 17.0, *)
struct WebRTCInboundFileTransferState {
    let stateToken: UUID
    let presentationToken: FileTransferManager.ExternalTransferToken
    let lifecycleToken: UUID
    let sessionID: String
    let transferId: String
    let metadataBinding: WebRTCInboundFileTransferMetadataBinding
    let fileName: String
    let fileSize: Int64
    let chunkSize: Int
    let totalChunks: Int
    let senderDeviceId: String
    let senderDeviceName: String?
    let tempURL: URL
    let finalURL: URL
    let ioHandle: InboundFileTransferIOHandle
    var revision: UInt64
    var receivedBytes: Int64
    var completeRequestedAt: Date? = nil
    var expectedFileSha256: Data? = nil
    var expectedMerkleRoot: Data? = nil
    var expectedMerkleSig: Data? = nil
    var expectedMerkleSigAlg: String? = nil
    var completionBinding: WebRTCInboundFileTransferCompletionBinding? = nil
    /// Linearization point after all bytes are present and close/hash/commit owns
    /// the terminal outcome. Early complete requests with missing chunks are not finalizing.
    var isFinalizing = false
    var chunkHashes: [Int: Data] = [:]
    var receivedChunkSizes: [Int: Int] = [:]
}

@available(macOS 14.0, iOS 17.0, *)
struct WebRTCInboundFileTransferMetadataBinding: Sendable, Equatable {
    let version: Int
    let senderDeviceId: String
    let senderDeviceName: String
    let fileName: String
    let fileSize: Int64
    let chunkSize: Int
    let totalChunks: Int
    let mimeType: String?
    let encryption: String?
    let batchId: String?
    let batchIndex: Int?
    let batchTotal: Int?
    let relativePath: String?
}

@available(macOS 14.0, iOS 17.0, *)
struct WebRTCInboundFileTransferCompletionBinding: Sendable, Equatable {
    let receivedBytes: Int64?
    let fileSha256: Data?
    let merkleRoot: Data?
    let merkleRootSignature: Data?
    let merkleRootSignatureAlg: String?

    init(message: CrossNetworkFileTransferMessage) {
        receivedBytes = message.receivedBytes
        fileSha256 = message.fileSha256
        merkleRoot = message.merkleRoot
        merkleRootSignature = message.merkleRootSignature
        merkleRootSignatureAlg = message.merkleRootSignatureAlg
    }
}

@available(macOS 14.0, iOS 17.0, *)
struct WebRTCInboundFileTransferTerminalReceipt: Sendable {
    let metadataBinding: WebRTCInboundFileTransferMetadataBinding
    let completionBinding: WebRTCInboundFileTransferCompletionBinding
    let response: CrossNetworkFileTransferMessage
    let label: String
    let expiresAt: Date
}

@available(macOS 14.0, iOS 17.0, *)
struct WebRTCInboundFileTransferTerminalReceiptCache {
    private struct SessionReceipts {
        var receiptsByTransferId: [String: WebRTCInboundFileTransferTerminalReceipt] = [:]
        var insertionOrder: [String] = []
    }

    private let maxReceiptsPerSession: Int
    private let maxSessions: Int
    private let timeToLive: TimeInterval
    private var receiptsBySessionId: [String: SessionReceipts] = [:]
    private var sessionInsertionOrder: [String] = []

    init(
        maxReceiptsPerSession: Int = 128,
        maxSessions: Int = 4,
        timeToLive: TimeInterval = 300
    ) {
        precondition(maxReceiptsPerSession > 0, "Terminal receipt capacity must be positive")
        precondition(maxSessions > 0, "Terminal receipt session capacity must be positive")
        precondition(timeToLive > 0, "Terminal receipt TTL must be positive")
        self.maxReceiptsPerSession = maxReceiptsPerSession
        self.maxSessions = maxSessions
        self.timeToLive = timeToLive
    }

    mutating func receipt(
        sessionID: String,
        transferID: String,
        now: Date = Date()
    ) -> WebRTCInboundFileTransferTerminalReceipt? {
        pruneExpired(sessionID: sessionID, now: now)
        touchSession(sessionID)
        return receiptsBySessionId[sessionID]?.receiptsByTransferId[transferID]
    }

    mutating func store(
        sessionID: String,
        transferID: String,
        metadataBinding: WebRTCInboundFileTransferMetadataBinding,
        completionBinding: WebRTCInboundFileTransferCompletionBinding,
        response: CrossNetworkFileTransferMessage,
        label: String,
        now: Date = Date()
    ) {
        pruneExpired(sessionID: sessionID, now: now)
        if receiptsBySessionId[sessionID] == nil {
            while receiptsBySessionId.count >= maxSessions,
                  let oldestSessionID = sessionInsertionOrder.first {
                sessionInsertionOrder.removeFirst()
                receiptsBySessionId.removeValue(forKey: oldestSessionID)
            }
        }
        var session = receiptsBySessionId[sessionID] ?? SessionReceipts()
        session.receiptsByTransferId.removeValue(forKey: transferID)
        session.insertionOrder.removeAll { $0 == transferID }
        while session.receiptsByTransferId.count >= maxReceiptsPerSession,
              let oldestTransferID = session.insertionOrder.first {
            session.insertionOrder.removeFirst()
            session.receiptsByTransferId.removeValue(forKey: oldestTransferID)
        }
        session.receiptsByTransferId[transferID] = WebRTCInboundFileTransferTerminalReceipt(
            metadataBinding: metadataBinding,
            completionBinding: completionBinding,
            response: response,
            label: label,
            expiresAt: now.addingTimeInterval(timeToLive)
        )
        session.insertionOrder.append(transferID)
        receiptsBySessionId[sessionID] = session
        touchSession(sessionID)
    }

    mutating func removeAll() {
        receiptsBySessionId.removeAll(keepingCapacity: false)
        sessionInsertionOrder.removeAll(keepingCapacity: false)
    }

    private mutating func pruneExpired(sessionID: String, now: Date) {
        guard var session = receiptsBySessionId[sessionID] else { return }
        let expiredTransferIDs = session.receiptsByTransferId.compactMap { transferID, receipt in
            receipt.expiresAt <= now ? transferID : nil
        }
        guard !expiredTransferIDs.isEmpty else { return }
        let expired = Set(expiredTransferIDs)
        for transferID in expired {
            session.receiptsByTransferId.removeValue(forKey: transferID)
        }
        session.insertionOrder.removeAll { expired.contains($0) }
        if session.receiptsByTransferId.isEmpty {
            receiptsBySessionId.removeValue(forKey: sessionID)
            sessionInsertionOrder.removeAll { $0 == sessionID }
        } else {
            receiptsBySessionId[sessionID] = session
        }
    }

    private mutating func touchSession(_ sessionID: String) {
        guard receiptsBySessionId[sessionID] != nil else { return }
        sessionInsertionOrder.removeAll { $0 == sessionID }
        sessionInsertionOrder.append(sessionID)
    }
}

@available(macOS 14.0, iOS 17.0, *)
@MainActor
final class WebRTCInboundFileTransferAdmissionLedger {
    static let shared = WebRTCInboundFileTransferAdmissionLedger()

    private var reservedTokens: Set<UUID> = []

    func reserve(_ token: UUID, globalLimit: Int) -> Bool {
        precondition(globalLimit > 0, "Inbound transfer global limit must be positive")
        guard reservedTokens.count < globalLimit else { return false }
        return reservedTokens.insert(token).inserted
    }

    func release(_ token: UUID) {
        reservedTokens.remove(token)
    }
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
struct WebRTCInboundFileTransferSenderAuthority: Sendable, Equatable {
    let deviceId: String
    let deviceName: String
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
    static let maxFileSize: Int64 = 2 * 1024 * 1024 * 1024
    static let maxTotalChunks = 65_536
    static let transferIdLength = 36
    static let explicitApprovalRequiredMessage = "inbound_file_transfer_requires_explicit_approval"
    static let missingSenderIdentityMessage = "inbound_file_transfer_missing_sender_identity"
    static let maximumRemoteStatusMessageBytes = 512

    static func normalizedRemoteStatusMessage(
        _ raw: String?,
        fallback: String
    ) -> String {
        guard let raw else { return fallback }
        var normalized = String()
        normalized.reserveCapacity(maximumRemoteStatusMessageBytes)
        var utf8ByteCount = 0
        for scalar in raw.unicodeScalars {
            let selected: UnicodeScalar = CharacterSet.controlCharacters.contains(scalar)
                ? UnicodeScalar(0x20)!
                : scalar
            let selectedByteCount = String(selected).utf8.count
            guard utf8ByteCount + selectedByteCount <= maximumRemoteStatusMessageBytes else {
                break
            }
            normalized.unicodeScalars.append(selected)
            utf8ByteCount += selectedByteCount
        }
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

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
        guard fileSize <= maxFileSize else {
            return "Invalid metadata (fileSize out of range)"
        }
        guard chunkSize > 0, chunkSize <= maxChunkSize else {
            return "Invalid metadata (chunkSize out of range)"
        }
        guard totalChunks >= 0 else {
            return "Invalid metadata (negative totalChunks)"
        }
        guard totalChunks <= maxTotalChunks else {
            return "Invalid metadata (totalChunks out of range)"
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
        receiveKey: Data,
        actualFileSha256: Data?
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
            guard let actualFileSha256 else {
                return .fileSHA256Unavailable
            }
            if actualFileSha256 != expectedFileSha256 {
                return .fileSHA256Mismatch
            }
        }

        return nil
    }
}
