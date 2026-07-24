import Foundation

@available(iOS 17.0, *)
enum CrossNetworkWebRTCInboundFileTransferPathError: Error {
    case emptyFileName
    case traversalComponent
    case pathSeparator
    case destinationEscapesBaseDirectory
}

@available(iOS 17.0, *)
extension CrossNetworkWebRTCManager {
    nonisolated static let inboundFileTransferExplicitApprovalRequiredMessage = "inbound_file_transfer_requires_explicit_approval"
    nonisolated static let inboundFileTransferMissingSenderIdentityMessage = "inbound_file_transfer_missing_sender_identity"
    nonisolated static let maxInboundWebRTCFileSize: Int64 = 2 * 1024 * 1024 * 1024
    nonisolated static let maxInboundWebRTCFileTransferChunks = 65_536
    nonisolated static let maxConcurrentInboundWebRTCFileTransfersPerSession = 8
    nonisolated static let maxConcurrentInboundWebRTCFileTransfersGlobal = 16
    nonisolated static let inboundWebRTCFileTransferIdleTimeout: Duration = .seconds(120)

    struct InboundFileTransferApprovalRequest: Sendable, Equatable {
        let transferId: String
        let fileName: String
        let fileSize: Int64
        let chunkSize: Int
        let totalChunks: Int
        let senderDeviceId: String
        let senderDeviceName: String
    }

    enum InboundFileTransferApprovalDecision: Sendable, Equatable {
        case approved
        case rejected(reason: String)
    }

    struct InboundFileTransferMetadataBinding: Sendable, Equatable {
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

    struct InboundFileTransferCompletionBinding: Sendable, Equatable {
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

    struct InboundFileTransferTerminalReceipt: Sendable {
        let metadataBinding: InboundFileTransferMetadataBinding
        let completionBinding: InboundFileTransferCompletionBinding
        let response: CrossNetworkFileTransferMessage
        let label: String
        let expiresAt: Date
    }

    struct InboundFileTransferTerminalReceiptCache {
        private struct SessionReceipts {
            var receiptsByTransferId: [String: InboundFileTransferTerminalReceipt] = [:]
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
        ) -> InboundFileTransferTerminalReceipt? {
            pruneExpired(sessionID: sessionID, now: now)
            touchSession(sessionID)
            return receiptsBySessionId[sessionID]?.receiptsByTransferId[transferID]
        }

        mutating func store(
            sessionID: String,
            transferID: String,
            metadataBinding: InboundFileTransferMetadataBinding,
            completionBinding: InboundFileTransferCompletionBinding,
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
            session.receiptsByTransferId[transferID] = InboundFileTransferTerminalReceipt(
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

    nonisolated static func fileTransferWaiterKey(
        transferId: String,
        op: CrossNetworkFileTransferOp,
        chunkIndex: Int?
    ) -> FileTransferWaiterKey {
        FileTransferWaiterKey(
            transferID: transferId,
            operation: op,
            chunkIndex: chunkIndex
        )
    }

    static func downloadsDirectoryURL() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Downloads", isDirectory: true)
    }

    nonisolated static func validateInboundTransferId(_ transferId: String) -> String? {
        guard transferId.count == 36,
              transferId.trimmingCharacters(in: .whitespacesAndNewlines) == transferId,
              UUID(uuidString: transferId) != nil else {
            return "Invalid metadata (invalid transferId)"
        }
        return nil
    }

    nonisolated static func normalizedRemoteFileTransferStatusMessage(
        _ raw: String?,
        fallback: String
    ) -> String {
        let maximumUTF8Bytes = 512
        guard let raw else { return fallback }
        var normalized = String()
        normalized.reserveCapacity(maximumUTF8Bytes)
        var utf8ByteCount = 0
        for scalar in raw.unicodeScalars {
            let selected: UnicodeScalar = CharacterSet.controlCharacters.contains(scalar)
                ? UnicodeScalar(0x20)!
                : scalar
            let selectedByteCount = String(selected).utf8.count
            guard utf8ByteCount + selectedByteCount <= maximumUTF8Bytes else { break }
            normalized.unicodeScalars.append(selected)
            utf8ByteCount += selectedByteCount
        }
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    nonisolated static func normalizedInboundApprovalRejectionMessage(_ reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? inboundFileTransferExplicitApprovalRequiredMessage : trimmed
    }

    nonisolated static func requiredInboundSenderDeviceId(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated static func makeUniqueDestinationURL(baseDir: URL, fileName: String) throws -> URL {
        let safe = try validatedInboundFileName(fileName)
        let ext = (safe as NSString).pathExtension
        let stem = (safe as NSString).deletingPathExtension
        let canonicalBaseDir = baseDir
            .resolvingSymlinksInPath()
            .standardizedFileURL

        var candidate = canonicalBaseDir.appendingPathComponent(safe, isDirectory: false)
        var idx = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let altName: String
            if ext.isEmpty {
                altName = "\(stem) (\(idx))"
            } else {
                altName = "\(stem) (\(idx)).\(ext)"
            }
            candidate = canonicalBaseDir.appendingPathComponent(altName, isDirectory: false)
            idx += 1
        }
        guard isInboundDestination(candidate, containedIn: canonicalBaseDir) else {
            throw CrossNetworkWebRTCInboundFileTransferPathError.destinationEscapesBaseDirectory
        }
        return candidate
    }

    nonisolated static func expectedInboundChunkCount(fileSize: Int64, chunkSize: Int) -> Int? {
        guard chunkSize > 0 else { return nil }
        if fileSize == 0 { return 0 }
        let total = (fileSize + Int64(chunkSize) - 1) / Int64(chunkSize)
        guard total >= 0, total <= Int64(Int.max) else { return nil }
        return Int(total)
    }

    nonisolated static func validateInboundMetadata(
        fileName: String,
        fileSize: Int64,
        chunkSize: Int,
        totalChunks: Int
    ) -> String? {
        guard !fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Invalid metadata (empty fileName)"
        }
        do {
            _ = try validatedInboundFileName(fileName)
        } catch {
            return "Invalid metadata (unsafe fileName)"
        }
        guard fileSize >= 0 else {
            return "Invalid metadata (negative fileSize)"
        }
        guard fileSize <= maxInboundWebRTCFileSize else {
            return "Invalid metadata (fileSize out of range)"
        }
        let maxInboundChunkSize = 512 * 1024
        guard chunkSize > 0, chunkSize <= maxInboundChunkSize else {
            return "Invalid metadata (chunkSize out of range)"
        }
        guard totalChunks >= 0 else {
            return "Invalid metadata (negative totalChunks)"
        }
        guard totalChunks <= maxInboundWebRTCFileTransferChunks else {
            return "Invalid metadata (totalChunks out of range)"
        }
        guard let expectedTotalChunks = expectedInboundChunkCount(fileSize: fileSize, chunkSize: chunkSize),
              expectedTotalChunks == totalChunks else {
            return "Invalid metadata (fileSize/chunkSize/totalChunks mismatch)"
        }
        return nil
    }

    nonisolated static func expectedInboundChunkSize(
        fileSize: Int64,
        chunkSize: Int,
        totalChunks: Int,
        index: Int
    ) -> Int? {
        guard index >= 0, index < totalChunks else { return nil }
        let offset = Int64(index) * Int64(chunkSize)
        guard offset >= 0, offset <= fileSize else { return nil }
        let remaining = fileSize - offset
        guard remaining >= 0 else { return nil }
        return Int(min(Int64(chunkSize), remaining))
    }

    private nonisolated static func validatedInboundFileName(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CrossNetworkWebRTCInboundFileTransferPathError.emptyFileName
        }
        guard trimmed != "." && trimmed != ".." else {
            throw CrossNetworkWebRTCInboundFileTransferPathError.traversalComponent
        }
        guard !containsInboundPathSeparator(trimmed) else {
            throw CrossNetworkWebRTCInboundFileTransferPathError.pathSeparator
        }
        return trimmed
    }

    private nonisolated static func containsInboundPathSeparator(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x00, 0x2F, 0x5C, 0x2044, 0x2215:
                return true
            default:
                return false
            }
        }
    }

    private nonisolated static func isInboundDestination(_ candidate: URL, containedIn baseDirectory: URL) -> Bool {
        let candidatePath = candidate
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        let basePath = baseDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        let normalizedBasePath = basePath.hasSuffix("/") ? basePath : basePath + "/"
        return candidatePath.hasPrefix(normalizedBasePath)
    }
}
