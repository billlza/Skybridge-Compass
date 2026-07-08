import Foundation

@available(macOS 14.0, iOS 17.0, *)
@MainActor
final class WebRTCInboundFileTransferReceiver {
    typealias SendMessage = (CrossNetworkFileTransferMessage, String) async throws -> Void
    typealias FailSenderWaiters = (String, String) -> Void
    typealias ResumeSenderWaiter = (CrossNetworkFileTransferMessage) -> Void
    typealias ApprovalProvider = @MainActor (WebRTCInboundFileTransferApprovalRequest) async -> WebRTCInboundFileTransferApprovalDecision

    private static let defaultMaxConcurrentInboundTransfers = 8
    private static let defaultTransferIdleTimeout: Duration = .seconds(120)

    private let destinationBaseDirectory: () -> URL?
    private let approvalProvider: ApprovalProvider
    private let maxConcurrentInboundTransfers: Int
    private let transferIdleTimeout: Duration
    private var transfers: [String: WebRTCInboundFileTransferState] = [:]
    private var completeTimers: [String: Task<Void, Never>] = [:]
    private var idleTimers: [String: Task<Void, Never>] = [:]

    init(
        destinationBaseDirectory: @escaping () -> URL? = {
            FileManager.default
                .urls(for: .downloadsDirectory, in: .userDomainMask)
                .first?
                .appendingPathComponent("SkyBridge", isDirectory: true)
        },
        maxConcurrentInboundTransfers: Int = WebRTCInboundFileTransferReceiver.defaultMaxConcurrentInboundTransfers,
        transferIdleTimeout: Duration = WebRTCInboundFileTransferReceiver.defaultTransferIdleTimeout,
        approvalProvider: @escaping ApprovalProvider = { _ in
            .rejected(reason: WebRTCInboundFileTransferSupport.explicitApprovalRequiredMessage)
        }
    ) {
        self.destinationBaseDirectory = destinationBaseDirectory
        self.approvalProvider = approvalProvider
        self.maxConcurrentInboundTransfers = max(1, maxConcurrentInboundTransfers)
        self.transferIdleTimeout = transferIdleTimeout
    }

    func cleanupOnChannelClosed() {
        for (_, task) in completeTimers {
            task.cancel()
        }
        completeTimers.removeAll()
        for (_, task) in idleTimers {
            task.cancel()
        }
        idleTimers.removeAll()

        if !transfers.isEmpty {
            for state in transfers.values {
                try? state.handle.close()
                try? FileManager.default.removeItem(at: state.tempURL)
                FileTransferManager.shared.failExternalTransfer(
                    transferId: state.transferId,
                    errorMessage: "WebRTC channel closed before transfer completion"
                )
            }
            transfers.removeAll()
        }
    }

    func handle(
        _ message: CrossNetworkFileTransferMessage,
        sessionID: String,
        endpointDescription: String,
        keys: SessionKeys,
        sendMessage: SendMessage,
        failSenderWaiters: FailSenderWaiters,
        resumeSenderWaiter: ResumeSenderWaiter
    ) async throws {
        switch message.op {
        case .metadata:
            try await handleMetadata(
                message,
                endpointDescription: endpointDescription,
                sendMessage: sendMessage
            )
        case .chunk:
            try await handleChunk(
                message,
                keys: keys,
                sendMessage: sendMessage
            )
        case .complete:
            try await handleComplete(
                message,
                keys: keys,
                sendMessage: sendMessage
            )
        case .cancel:
            handleCancel(message)
        case .error:
            failSenderWaiters(message.transferId, message.message ?? "unknown")
        case .metadataAck, .chunkAck, .completeAck:
            resumeSenderWaiter(message)
        }
    }

    private func handleMetadata(
        _ message: CrossNetworkFileTransferMessage,
        endpointDescription: String,
        sendMessage: SendMessage
    ) async throws {
        if let validationError = WebRTCInboundFileTransferSupport.validateTransferId(message.transferId) {
            try await sendMessage(
                CrossNetworkFileTransferMessage(
                    op: .error,
                    transferId: message.transferId,
                    message: validationError
                ),
                "tx/webrtc-ft-error"
            )
            return
        }

        if transfers[message.transferId] != nil {
            try await sendMessage(
                CrossNetworkFileTransferMessage(op: .metadataAck, transferId: message.transferId),
                "tx/webrtc-ft-metaAck"
            )
            return
        }

        guard transfers.count < maxConcurrentInboundTransfers else {
            try await sendMessage(
                CrossNetworkFileTransferMessage(
                    op: .error,
                    transferId: message.transferId,
                    message: "Too many concurrent inbound file transfers"
                ),
                "tx/webrtc-ft-error"
            )
            return
        }

        guard
            let fileName = message.fileName,
            let fileSize = message.fileSize,
            let chunkSize = message.chunkSize,
            let totalChunks = message.totalChunks
        else {
            try await sendMessage(
                CrossNetworkFileTransferMessage(
                    op: .error,
                    transferId: message.transferId,
                    message: "Invalid metadata (missing fileName/fileSize/chunkSize/totalChunks)"
                ),
                "tx/webrtc-ft-error"
            )
            return
        }

        if let validationError = WebRTCInboundFileTransferSupport.validateMetadata(
            fileName: fileName,
            fileSize: fileSize,
            chunkSize: chunkSize,
            totalChunks: totalChunks
        ) {
            try await sendMessage(
                CrossNetworkFileTransferMessage(
                    op: .error,
                    transferId: message.transferId,
                    message: validationError
                ),
                "tx/webrtc-ft-error"
            )
            return
        }

        guard let baseDirectory = destinationBaseDirectory() else {
            try await sendMessage(
                CrossNetworkFileTransferMessage(
                    op: .error,
                    transferId: message.transferId,
                    message: "Downloads directory unavailable"
                ),
                "tx/webrtc-ft-error"
            )
            return
        }

        do {
            try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        } catch {
            try await sendMessage(
                CrossNetworkFileTransferMessage(
                    op: .error,
                    transferId: message.transferId,
                    message: "Downloads directory unavailable"
                ),
                "tx/webrtc-ft-error"
            )
            return
        }

        let finalURL: URL
        do {
            finalURL = try WebRTCInboundFileTransferSupport.uniqueDestinationURL(
                baseDirectory: baseDirectory,
                fileName: fileName
            )
        } catch {
            try await sendMessage(
                CrossNetworkFileTransferMessage(
                    op: .error,
                    transferId: message.transferId,
                    message: "Destination file unavailable"
                ),
                "tx/webrtc-ft-error"
            )
            return
        }

        guard let senderId = WebRTCInboundFileTransferSupport.requiredSenderDeviceId(message.senderDeviceId) else {
            try await sendMessage(
                CrossNetworkFileTransferMessage(
                    op: .error,
                    transferId: message.transferId,
                    message: WebRTCInboundFileTransferSupport.missingSenderIdentityMessage
                ),
                "tx/webrtc-ft-error"
            )
            return
        }
        let senderName = message.senderDeviceName ?? senderId
        let approvalRequest = WebRTCInboundFileTransferApprovalRequest(
            transferId: message.transferId,
            fileName: fileName,
            fileSize: fileSize,
            chunkSize: chunkSize,
            totalChunks: totalChunks,
            senderDeviceId: senderId,
            senderDeviceName: senderName,
            endpointDescription: endpointDescription,
            destinationDirectoryPath: baseDirectory.path,
            proposedSavePath: finalURL.path
        )
        switch await approvalProvider(approvalRequest) {
        case .approved:
            break
        case .rejected(let reason):
            try await sendMessage(
                CrossNetworkFileTransferMessage(
                    op: .error,
                    transferId: message.transferId,
                    message: WebRTCInboundFileTransferSupport.normalizedApprovalRejectionMessage(reason)
                ),
                "tx/webrtc-ft-error"
            )
            return
        }

        let tempURL = baseDirectory.appendingPathComponent(".skybridge-\(message.transferId).partial")
        guard !FileManager.default.fileExists(atPath: tempURL.path),
              FileManager.default.createFile(atPath: tempURL.path, contents: nil) else {
            try await sendMessage(
                CrossNetworkFileTransferMessage(
                    op: .error,
                    transferId: message.transferId,
                    message: "Partial file unavailable"
                ),
                "tx/webrtc-ft-error"
            )
            return
        }

        let handle = try FileHandle(forWritingTo: tempURL)

        transfers[message.transferId] = WebRTCInboundFileTransferState(
            transferId: message.transferId,
            fileName: fileName,
            fileSize: fileSize,
            chunkSize: chunkSize,
            totalChunks: totalChunks,
            senderDeviceId: senderId,
            senderDeviceName: senderName,
            tempURL: tempURL,
            finalURL: finalURL,
            handle: handle,
            receivedBytes: 0
        )

        scheduleIdleTimeout(transferId: message.transferId)

        FileTransferManager.shared.beginExternalInboundTransfer(
            transferId: message.transferId,
            fileName: fileName,
            fileSize: fileSize,
            fromDeviceId: senderId,
            fromDeviceName: senderName
        )

        try await sendMessage(
            CrossNetworkFileTransferMessage(op: .metadataAck, transferId: message.transferId),
            "tx/webrtc-ft-metaAck"
        )
    }

    private func handleChunk(
        _ message: CrossNetworkFileTransferMessage,
        keys: SessionKeys,
        sendMessage: SendMessage
    ) async throws {
        guard
            let index = message.chunkIndex,
            let data = message.chunkData
        else { return }

        guard var state = transfers[message.transferId] else {
            try await sendMessage(
                CrossNetworkFileTransferMessage(
                    op: .error,
                    transferId: message.transferId,
                    message: "Unknown transferId (no metadata)"
                ),
                "tx/webrtc-ft-error"
            )
            return
        }

        if let expected = message.chunkSha256, CrossNetworkCrypto.sha256(data) != expected {
            try await sendMessage(
                CrossNetworkFileTransferMessage(
                    op: .error,
                    transferId: message.transferId,
                    chunkIndex: index,
                    message: "chunk hash mismatch"
                ),
                "tx/webrtc-ft-error"
            )
            return
        }

        let rawSize = message.rawSize ?? data.count
        guard index >= 0, index < state.totalChunks else {
            try await sendMessage(
                CrossNetworkFileTransferMessage(
                    op: .error,
                    transferId: message.transferId,
                    chunkIndex: index,
                    message: "chunk index out of range"
                ),
                "tx/webrtc-ft-error"
            )
            return
        }

        guard rawSize >= 0, rawSize == data.count, rawSize <= state.chunkSize else {
            try await sendMessage(
                CrossNetworkFileTransferMessage(
                    op: .error,
                    transferId: message.transferId,
                    chunkIndex: index,
                    message: "invalid chunk size"
                ),
                "tx/webrtc-ft-error"
            )
            return
        }

        guard let expectedChunkSize = WebRTCInboundFileTransferSupport.expectedChunkSize(
            state: state,
            index: index
        ),
              expectedChunkSize == rawSize else {
            try await sendMessage(
                CrossNetworkFileTransferMessage(
                    op: .error,
                    transferId: message.transferId,
                    chunkIndex: index,
                    message: "chunk length does not match metadata"
                ),
                "tx/webrtc-ft-error"
            )
            return
        }

        let actualHash = CrossNetworkCrypto.sha256(data)
        if let existingHash = state.chunkHashes[index] {
            guard existingHash == actualHash, state.receivedChunkSizes[index] == rawSize else {
                try await sendMessage(
                    CrossNetworkFileTransferMessage(
                        op: .error,
                        transferId: message.transferId,
                        chunkIndex: index,
                        message: "duplicate chunk content mismatch"
                    ),
                    "tx/webrtc-ft-error"
                )
                return
            }
        } else {
            let offset = Int64(index) * Int64(state.chunkSize)
            guard offset >= 0, offset + Int64(rawSize) <= state.fileSize else {
                try await sendMessage(
                    CrossNetworkFileTransferMessage(
                        op: .error,
                        transferId: message.transferId,
                        chunkIndex: index,
                        message: "chunk exceeds declared file size"
                    ),
                    "tx/webrtc-ft-error"
                )
                return
            }
            try state.handle.seek(toOffset: UInt64(offset))
            try state.handle.write(contentsOf: data)
            state.chunkHashes[index] = actualHash
            state.receivedChunkSizes[index] = rawSize
            state.receivedBytes += Int64(rawSize)
        }

        scheduleIdleTimeout(transferId: state.transferId)

        if state.completeRequestedAt != nil && state.receivedBytes >= state.fileSize {
            do {
                try state.handle.close()
            } catch {
                try await failIntegrityValidation(
                    state,
                    failure: .fileHandleCloseFailed,
                    sendMessage: sendMessage
                )
                return
            }
            do {
                if let integrityFailure = WebRTCInboundFileTransferSupport.integrityFailure(
                    state: state,
                    receiveKey: keys.receiveKey
                ) {
                    try await failIntegrityValidation(
                        state,
                        failure: integrityFailure,
                        sendMessage: sendMessage
                    )
                    return
                }
                let savedURL = try saveCompletedTransfer(state)
                FileTransferManager.shared.completeExternalInboundTransfer(
                    transferId: state.transferId,
                    savedTo: savedURL
                )
                removeTransfer(state.transferId)
                try await sendCompleteAck(for: state, savedTo: savedURL, sendMessage: sendMessage)
                return
            } catch {
                FileTransferManager.shared.failExternalTransfer(
                    transferId: state.transferId,
                    errorMessage: "Save failed: \(error.localizedDescription)"
                )
                try? FileManager.default.removeItem(at: state.tempURL)
                removeTransfer(state.transferId)
                try? await sendMessage(
                    CrossNetworkFileTransferMessage(
                        op: .error,
                        transferId: state.transferId,
                        message: "Save failed"
                    ),
                    "tx/webrtc-ft-error"
                )
                return
            }
        }

        transfers[message.transferId] = state

        FileTransferManager.shared.updateExternalInboundProgress(
            transferId: state.transferId,
            transferredBytes: state.receivedBytes
        )

        try await sendMessage(
            CrossNetworkFileTransferMessage(
                op: .chunkAck,
                transferId: state.transferId,
                chunkIndex: index,
                receivedBytes: state.receivedBytes
            ),
            "tx/webrtc-ft-chunkAck"
        )
    }

    private func handleComplete(
        _ message: CrossNetworkFileTransferMessage,
        keys: SessionKeys,
        sendMessage: SendMessage
    ) async throws {
        guard var state = transfers[message.transferId] else { return }

        if state.expectedFileSha256 == nil { state.expectedFileSha256 = message.fileSha256 }
        if state.expectedMerkleRoot == nil { state.expectedMerkleRoot = message.merkleRoot }
        if state.expectedMerkleSig == nil { state.expectedMerkleSig = message.merkleRootSignature }
        if state.expectedMerkleSigAlg == nil { state.expectedMerkleSigAlg = message.merkleRootSignatureAlg }

        guard WebRTCInboundFileTransferSupport.hasRequiredIntegrityProof(state) else {
            try await sendMessage(
                CrossNetworkFileTransferMessage(
                    op: .error,
                    transferId: state.transferId,
                    message: "missing integrity proof"
                ),
                "tx/webrtc-ft-error"
            )
            removeTransfer(state.transferId)
            try? state.handle.close()
            try? FileManager.default.removeItem(at: state.tempURL)
            FileTransferManager.shared.failExternalTransfer(
                transferId: state.transferId,
                errorMessage: "Missing integrity proof"
            )
            return
        }

        if state.receivedBytes < state.fileSize {
            let missingChunks = (0..<state.totalChunks).filter { state.chunkHashes[$0] == nil }
            if !missingChunks.isEmpty {
                try await sendMessage(
                    CrossNetworkFileTransferMessage(
                        op: .chunkAck,
                        transferId: state.transferId,
                        missingChunks: missingChunks.prefix(512).map { Int($0) },
                        message: "missingChunks"
                    ),
                    "tx/webrtc-ft-missingChunks"
                )
            }

            if state.completeRequestedAt == nil { state.completeRequestedAt = Date() }
            transfers[state.transferId] = state
            scheduleIdleTimeout(transferId: state.transferId)
            scheduleIncompleteTimeoutIfNeeded(transferId: state.transferId)
            return
        }

        do {
            try state.handle.close()
        } catch {
            try await failIntegrityValidation(
                state,
                failure: .fileHandleCloseFailed,
                sendMessage: sendMessage
            )
            return
        }

        do {
            if let integrityFailure = WebRTCInboundFileTransferSupport.integrityFailure(
                state: state,
                receiveKey: keys.receiveKey
            ) {
                try await failIntegrityValidation(
                    state,
                    failure: integrityFailure,
                    sendMessage: sendMessage
                )
                return
            }
            let savedURL = try saveCompletedTransfer(state)
            FileTransferManager.shared.completeExternalInboundTransfer(
                transferId: state.transferId,
                savedTo: savedURL
            )
            removeTransfer(state.transferId)

            try await sendCompleteAck(for: state, savedTo: savedURL, sendMessage: sendMessage)
            return
        } catch {
            FileTransferManager.shared.failExternalTransfer(
                transferId: state.transferId,
                errorMessage: "Save failed: \(error.localizedDescription)"
            )
            try? FileManager.default.removeItem(at: state.tempURL)
            removeTransfer(state.transferId)
            try await sendMessage(
                CrossNetworkFileTransferMessage(
                    op: .error,
                    transferId: state.transferId,
                    message: "Save failed"
                ),
                "tx/webrtc-ft-error"
            )
            return
        }
    }

    private func handleCancel(_ message: CrossNetworkFileTransferMessage) {
        if let state = transfers[message.transferId] {
            try? state.handle.close()
            try? FileManager.default.removeItem(at: state.tempURL)
            FileTransferManager.shared.failExternalTransfer(
                transferId: state.transferId,
                errorMessage: message.message ?? "Cancelled"
            )
            removeTransfer(state.transferId)
        }
    }

    private func scheduleIncompleteTimeoutIfNeeded(transferId: String) {
        guard completeTimers[transferId] == nil else { return }
        completeTimers[transferId] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self,
                  let current = self.transfers[transferId],
                  current.receivedBytes < current.fileSize else {
                return
            }
            do { try current.handle.close() } catch {}
            try? FileManager.default.removeItem(at: current.tempURL)
            FileTransferManager.shared.failExternalTransfer(
                transferId: current.transferId,
                errorMessage: "Incomplete file (timeout): \(current.receivedBytes)/\(current.fileSize)"
            )
            self.removeTransfer(current.transferId)
        }
    }

    private func scheduleIdleTimeout(transferId: String) {
        let timeout = transferIdleTimeout
        idleTimers[transferId]?.cancel()
        idleTimers[transferId] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            guard let self,
                  let current = self.transfers[transferId] else {
                return
            }
            do { try current.handle.close() } catch {}
            try? FileManager.default.removeItem(at: current.tempURL)
            FileTransferManager.shared.failExternalTransfer(
                transferId: current.transferId,
                errorMessage: "Inbound file transfer idle timeout"
            )
            self.removeTransfer(current.transferId)
        }
    }

    private func failIntegrityValidation(
        _ state: WebRTCInboundFileTransferState,
        failure: WebRTCInboundFileTransferIntegrityFailure,
        sendMessage: SendMessage
    ) async throws {
        let message = failure.message
        FileTransferManager.shared.failExternalTransfer(
            transferId: state.transferId,
            errorMessage: message
        )
        removeTransfer(state.transferId)
        try? FileManager.default.removeItem(at: state.tempURL)

        try await sendMessage(
            CrossNetworkFileTransferMessage(
                op: .error,
                transferId: state.transferId,
                message: message
            ),
            "tx/webrtc-ft-error"
        )
    }

    private func sendCompleteAck(
        for state: WebRTCInboundFileTransferState,
        savedTo savedURL: URL,
        sendMessage: SendMessage
    ) async throws {
        try await sendMessage(
            CrossNetworkFileTransferMessage(
                op: .completeAck,
                transferId: state.transferId,
                receivedBytes: state.receivedBytes,
                fileSha256: state.expectedFileSha256
                    ?? (try? WebRTCInboundFileTransferSupport.sha256File(at: savedURL))
            ),
            "tx/webrtc-ft-completeAck"
        )
    }

    private func saveCompletedTransfer(_ state: WebRTCInboundFileTransferState) throws -> URL {
        let destinationURL = try WebRTCInboundFileTransferSupport.uniqueDestinationURL(
            baseDirectory: state.finalURL.deletingLastPathComponent(),
            fileName: state.fileName
        )
        try FileManager.default.moveItem(at: state.tempURL, to: destinationURL)
        return destinationURL
    }

    private func removeTransfer(_ transferId: String) {
        transfers.removeValue(forKey: transferId)
        completeTimers[transferId]?.cancel()
        completeTimers.removeValue(forKey: transferId)
        idleTimers[transferId]?.cancel()
        idleTimers.removeValue(forKey: transferId)
    }
}
