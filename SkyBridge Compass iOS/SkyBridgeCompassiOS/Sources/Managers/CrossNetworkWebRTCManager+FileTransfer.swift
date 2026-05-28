import Foundation
import CryptoKit

@available(iOS 17.0, *)
extension CrossNetworkWebRTCManager {
    struct InboundFileTransferState {
        let transferId: String
        let fileName: String
        let fileSize: Int64
        let chunkSize: Int
        let totalChunks: Int
        let senderDeviceId: String
        let senderDeviceName: String
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

    func cleanupInboundFileTransfers() {
        for (_, st) in inboundFileTransfers {
            try? st.handle.close()
            try? FileManager.default.removeItem(at: st.tempURL)
        }
        inboundFileTransfers.removeAll()
    }

    func sendFramed(_ data: Data, over session: WebRTCSession) async throws {
        try await session.sendFramedPayloadAsync(data)
    }

    func encrypt(
        plaintext: Data,
        with keys: SessionKeys,
        packetType: WebRTCAppSecurePacketType = .appControl
    ) throws -> Data {
        try sealWebRTCSecurePayload(
            plaintext,
            with: keys,
            sessionId: keys.sessionId,
            packetType: packetType
        )
    }
}

// MARK: - WebRTC file transfer helpers (iOS)

@available(iOS 17.0, *)
public extension CrossNetworkWebRTCManager {
    func sendFileTransferMessage(_ message: CrossNetworkFileTransferMessage) async throws {
        guard let session, let keys = sessionKeys else { throw RemoteDesktopError.disconnected }
        let data = try JSONEncoder().encode(message)
        let encrypted = try encrypt(plaintext: data, with: keys, packetType: .fileTransfer)
        let padded = TrafficPadding.wrapIfEnabled(encrypted, label: "tx/webrtc-file")
        try await sendFramed(padded, over: session)
    }

    func waitForFileTransferAck(
        transferId: String,
        op: CrossNetworkFileTransferOp,
        chunkIndex: Int? = nil,
        timeoutSeconds: TimeInterval = 20
    ) async throws -> CrossNetworkFileTransferMessage {
        let key = Self.fileTransferWaiterKey(transferId: transferId, op: op, chunkIndex: chunkIndex)
        if fileTransferWaiters[key] != nil {
            // Prevent accidental double-waits on the same key.
            throw FileTransferWaitError.cancelled
        }

        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<CrossNetworkFileTransferMessage, Error>) in
            fileTransferWaiters[key] = c

            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await Task.sleep(for: .seconds(timeoutSeconds))
                } catch {
                    return
                }
                // Timeout: if still pending, resume with error.
                if let pending = self.fileTransferWaiters.removeValue(forKey: key) {
                    pending.resume(throwing: FileTransferWaitError.timeout)
                }
            }
        }
    }
}

@available(iOS 17.0, *)
extension CrossNetworkWebRTCManager {
    func handleInboundFileTransferWire(_ msg: CrossNetworkFileTransferMessage) {
        // Resume any waiter matching (transferId, op, chunkIndex).
        let key = Self.fileTransferWaiterKey(transferId: msg.transferId, op: msg.op, chunkIndex: msg.chunkIndex)
        if let waiter = fileTransferWaiters.removeValue(forKey: key) {
            waiter.resume(returning: msg)
            return
        }

        // Also allow acks without chunkIndex to be awaited.
        let keyNoIdx = Self.fileTransferWaiterKey(transferId: msg.transferId, op: msg.op, chunkIndex: nil)
        if let waiter = fileTransferWaiters.removeValue(forKey: keyNoIdx) {
            waiter.resume(returning: msg)
            return
        }
    }

    func failAllFileTransferWaiters(_ error: Error) {
        let waiters = fileTransferWaiters
        fileTransferWaiters.removeAll()
        for (_, c) in waiters {
            c.resume(throwing: error)
        }
    }

    func failFileTransferWaiters(transferId: String, message: String) {
        let keys = fileTransferWaiters.keys.filter { $0.hasPrefix("\(transferId)|") }
        for key in keys {
            if let waiter = fileTransferWaiters.removeValue(forKey: key) {
                waiter.resume(throwing: FileTransferError.transferFailed(message))
            }
        }
    }

    // MARK: - Inbound file transfer (macOS -> iOS)

    private func hasRequiredIntegrityProof(_ state: InboundFileTransferState) -> Bool {
        CrossNetworkFileTransferIntegrityValidator.hasRequiredProof(
            fileSha256: state.expectedFileSha256,
            merkleRoot: state.expectedMerkleRoot,
            merkleRootSignature: state.expectedMerkleSig,
            merkleRootSignatureAlg: state.expectedMerkleSigAlg
        )
    }

    func handleInboundFileTransferFromMac(_ msg: CrossNetworkFileTransferMessage) async {
        guard let keys = sessionKeys else { return }

        func sendAck(_ ack: CrossNetworkFileTransferMessage, label: String) async {
            do {
                try await sendFileTransferMessage(ack)
            } catch {
                // Best-effort; ignore.
                _ = label
                _ = keys
            }
        }

        switch msg.op {
        case .metadata:
            // Idempotent: allow re-sending metadata for the same transferId (resume).
            if inboundFileTransfers[msg.transferId] != nil {
                await sendAck(.init(op: .metadataAck, transferId: msg.transferId), label: "metaAck")
                return
            }

            guard
                let fileName = msg.fileName,
                let fileSize = msg.fileSize,
                let chunkSize = msg.chunkSize,
                let totalChunks = msg.totalChunks
            else {
                await sendAck(.init(op: .error, transferId: msg.transferId, message: "Invalid metadata"), label: "metaError")
                return
            }
            if let validationError = Self.validateInboundMetadata(
                fileName: fileName,
                fileSize: fileSize,
                chunkSize: chunkSize,
                totalChunks: totalChunks
            ) {
                await sendAck(.init(op: .error, transferId: msg.transferId, message: validationError), label: "metaError")
                return
            }

            // Prepare paths
            let baseDir = Self.downloadsDirectoryURL()
            let finalURL = Self.makeUniqueDestinationURL(baseDir: baseDir, fileName: fileName)
            let tempURL = baseDir.appendingPathComponent(".skybridge-\(msg.transferId).partial")
            _ = FileManager.default.createFile(atPath: tempURL.path, contents: nil)

            do {
                let handle = try FileHandle(forWritingTo: tempURL)
                let senderId = msg.senderDeviceId ?? (remoteDeviceId ?? "mac")
                let senderName = msg.senderDeviceName ?? (remoteDeviceName ?? "macOS")

                inboundFileTransfers[msg.transferId] = InboundFileTransferState(
                    transferId: msg.transferId,
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

                // UI record
                FileTransferManager.instance.beginExternalInboundTransfer(
                    transferId: msg.transferId,
                    fileName: fileName,
                    fileSize: fileSize,
                    fromPeerName: senderName,
                    destinationURL: finalURL
                )

                await sendAck(.init(op: .metadataAck, transferId: msg.transferId), label: "metaAck")
            } catch {
                await sendAck(.init(op: .error, transferId: msg.transferId, message: "Open temp file failed"), label: "metaError")
            }

        case .chunk:
            guard let idx = msg.chunkIndex, let data = msg.chunkData else { return }
            guard var st = inboundFileTransfers[msg.transferId] else {
                await sendAck(.init(op: .error, transferId: msg.transferId, message: "Unknown transferId"), label: "chunkError")
                return
            }

            do {
                let actualHash: Data
                switch CrossNetworkFileTransferIntegrityValidator.verifiedChunkHash(
                    data: data,
                    expectedChunkSha256: msg.chunkSha256
                ) {
                case .success(let verifiedHash):
                    actualHash = verifiedHash
                case .failure(let failure):
                    // Backward compatible: only enforce if hash provided.
                    // Don't ACK corrupted chunk; sender will timeout/retry as appropriate.
                    await sendAck(.init(op: .error, transferId: msg.transferId, chunkIndex: idx, message: failure.rawValue), label: "chunkHashMismatch")
                    return
                }

                let rawSize = msg.rawSize ?? data.count
                guard idx >= 0, idx < st.totalChunks else {
                    await sendAck(.init(op: .error, transferId: msg.transferId, chunkIndex: idx, message: "chunk index out of range"), label: "chunkError")
                    return
                }
                guard rawSize >= 0, rawSize == data.count, rawSize <= st.chunkSize else {
                    await sendAck(.init(op: .error, transferId: msg.transferId, chunkIndex: idx, message: "invalid chunk size"), label: "chunkError")
                    return
                }
                guard let expectedChunkSize = Self.expectedInboundChunkSize(
                    fileSize: st.fileSize,
                    chunkSize: st.chunkSize,
                    totalChunks: st.totalChunks,
                    index: idx
                ),
                      expectedChunkSize == rawSize else {
                    await sendAck(.init(op: .error, transferId: msg.transferId, chunkIndex: idx, message: "chunk length does not match metadata"), label: "chunkError")
                    return
                }

                if let existingHash = st.chunkHashes[idx] {
                    guard existingHash == actualHash, st.receivedChunkSizes[idx] == rawSize else {
                        await sendAck(.init(op: .error, transferId: msg.transferId, chunkIndex: idx, message: "duplicate chunk content mismatch"), label: "chunkError")
                        return
                    }
                } else {
                    let offset = Int64(idx) * Int64(st.chunkSize)
                    guard offset >= 0, offset + Int64(rawSize) <= st.fileSize else {
                        await sendAck(.init(op: .error, transferId: msg.transferId, chunkIndex: idx, message: "chunk exceeds declared file size"), label: "chunkError")
                        return
                    }
                    try st.handle.seek(toOffset: UInt64(offset))
                    try st.handle.write(contentsOf: data)
                    st.chunkHashes[idx] = actualHash
                    st.receivedChunkSizes[idx] = rawSize
                    st.receivedBytes += Int64(rawSize)
                }
                inboundFileTransfers[msg.transferId] = st

                FileTransferManager.instance.updateExternalInboundProgress(
                    transferId: st.transferId,
                    transferredBytes: st.receivedBytes,
                    totalBytes: st.fileSize
                )

                // If complete was already requested earlier, finalize once we have enough.
                if st.completeRequestedAt != nil && st.receivedBytes >= st.fileSize {
                    do { try st.handle.close() } catch {}
                    do {
                        if let failure = CrossNetworkFileTransferIntegrityValidator.validateMerkleProof(
                            transferId: st.transferId,
                            totalChunks: st.totalChunks,
                            chunkHashes: st.chunkHashes,
                            expectedMerkleRoot: st.expectedMerkleRoot,
                            merkleRootSignature: st.expectedMerkleSig,
                            merkleRootSignatureAlg: st.expectedMerkleSigAlg,
                            expectedFileSha256: st.expectedFileSha256,
                            receiveKey: keys.receiveKey
                        ) {
                            FileTransferManager.instance.completeExternalInboundTransfer(
                                transferId: st.transferId,
                                success: false,
                                error: failure.rawValue
                            )
                            try? FileManager.default.removeItem(at: st.tempURL)
                            inboundFileTransfers.removeValue(forKey: st.transferId)
                            inboundFileTransferCompleteTimers[st.transferId]?.cancel()
                            inboundFileTransferCompleteTimers.removeValue(forKey: st.transferId)
                            await sendAck(.init(op: .error, transferId: st.transferId, message: failure.rawValue), label: "completeError")
                            return
                        }

                        if let expected = st.expectedFileSha256, let actual = Self.sha256File(st.tempURL), actual != expected {
                            FileTransferManager.instance.completeExternalInboundTransfer(
                                transferId: st.transferId,
                                success: false,
                                error: "file sha256 mismatch"
                            )
                            try? FileManager.default.removeItem(at: st.tempURL)
                            inboundFileTransfers.removeValue(forKey: st.transferId)
                            inboundFileTransferCompleteTimers[st.transferId]?.cancel()
                            inboundFileTransferCompleteTimers.removeValue(forKey: st.transferId)
                            await sendAck(.init(op: .error, transferId: st.transferId, message: "file sha256 mismatch"), label: "completeError")
                            return
                        }
                        if FileManager.default.fileExists(atPath: st.finalURL.path) {
                            try? FileManager.default.removeItem(at: st.finalURL)
                        }
                        try FileManager.default.moveItem(at: st.tempURL, to: st.finalURL)
                        FileTransferManager.instance.completeExternalInboundTransfer(
                            transferId: st.transferId,
                            success: true,
                            destinationURL: st.finalURL
                        )
                        inboundFileTransfers.removeValue(forKey: st.transferId)
                        inboundFileTransferCompleteTimers[st.transferId]?.cancel()
                        inboundFileTransferCompleteTimers.removeValue(forKey: st.transferId)
                        await sendAck(
                            .init(
                                op: .completeAck,
                                transferId: st.transferId,
                                receivedBytes: st.receivedBytes,
                                fileSha256: st.expectedFileSha256 ?? Self.sha256File(st.finalURL)
                            ),
                            label: "completeAck"
                        )
                        return
                    } catch {
                        FileTransferManager.instance.completeExternalInboundTransfer(
                            transferId: st.transferId,
                            success: false,
                            error: "Save failed"
                        )
                        try? FileManager.default.removeItem(at: st.tempURL)
                        inboundFileTransfers.removeValue(forKey: st.transferId)
                        inboundFileTransferCompleteTimers[st.transferId]?.cancel()
                        inboundFileTransferCompleteTimers.removeValue(forKey: st.transferId)
                        await sendAck(.init(op: .error, transferId: st.transferId, message: "Save failed"), label: "completeError")
                        return
                    }
                }

                await sendAck(
                    .init(op: .chunkAck, transferId: st.transferId, chunkIndex: idx, receivedBytes: st.receivedBytes),
                    label: "chunkAck"
                )
            } catch {
                FileTransferManager.instance.completeExternalInboundTransfer(
                    transferId: msg.transferId,
                    success: false,
                    error: error.localizedDescription
                )
                try? st.handle.close()
                try? FileManager.default.removeItem(at: st.tempURL)
                inboundFileTransfers.removeValue(forKey: msg.transferId)
                await sendAck(.init(op: .error, transferId: msg.transferId, message: "Write failed"), label: "chunkError")
            }

        case .complete:
            guard var st = inboundFileTransfers[msg.transferId] else { return }

            // Capture expected full-file hash (optional, backward compatible).
            if st.expectedFileSha256 == nil { st.expectedFileSha256 = msg.fileSha256 }
            if st.expectedMerkleRoot == nil { st.expectedMerkleRoot = msg.merkleRoot }
            if st.expectedMerkleSig == nil { st.expectedMerkleSig = msg.merkleRootSignature }
            if st.expectedMerkleSigAlg == nil { st.expectedMerkleSigAlg = msg.merkleRootSignatureAlg }
            guard hasRequiredIntegrityProof(st) else {
                try? st.handle.close()
                try? FileManager.default.removeItem(at: st.tempURL)
                inboundFileTransfers.removeValue(forKey: st.transferId)
                inboundFileTransferCompleteTimers[st.transferId]?.cancel()
                inboundFileTransferCompleteTimers.removeValue(forKey: st.transferId)
                FileTransferManager.instance.completeExternalInboundTransfer(
                    transferId: st.transferId,
                    success: false,
                    error: "missing integrity proof"
                )
                await sendAck(.init(op: .error, transferId: st.transferId, message: "missing integrity proof"), label: "completeError")
                return
            }

            if st.receivedBytes < st.fileSize {
                // Optional NACK: request missing chunks (backward compatible).
                let missing = (0..<st.totalChunks).filter { st.chunkHashes[$0] == nil }
                if !missing.isEmpty {
                    await sendAck(.init(op: .chunkAck, transferId: st.transferId, missingChunks: Array(missing.prefix(512)), message: "missingChunks"), label: "missingChunks")
                }

                // Don't fail immediately; mark complete requested and wait for retransmits.
                if st.completeRequestedAt == nil { st.completeRequestedAt = Date() }
                inboundFileTransfers[st.transferId] = st

                if inboundFileTransferCompleteTimers[st.transferId] == nil {
                    inboundFileTransferCompleteTimers[st.transferId] = Task { [weak self] in
                        try? await Task.sleep(for: .seconds(10))
                        guard let self else { return }
                        if let cur = self.inboundFileTransfers[st.transferId], cur.receivedBytes < cur.fileSize {
                            do { try cur.handle.close() } catch {}
                            try? FileManager.default.removeItem(at: cur.tempURL)
                            self.inboundFileTransfers.removeValue(forKey: cur.transferId)
                            self.inboundFileTransferCompleteTimers[cur.transferId]?.cancel()
                            self.inboundFileTransferCompleteTimers.removeValue(forKey: cur.transferId)
                            FileTransferManager.instance.completeExternalInboundTransfer(
                                transferId: cur.transferId,
                                success: false,
                                error: "Incomplete file (timeout)"
                            )
                        }
                    }
                }
                return
            }

            do { try st.handle.close() } catch {}

            do {
                if let failure = CrossNetworkFileTransferIntegrityValidator.validateMerkleProof(
                    transferId: st.transferId,
                    totalChunks: st.totalChunks,
                    chunkHashes: st.chunkHashes,
                    expectedMerkleRoot: st.expectedMerkleRoot,
                    merkleRootSignature: st.expectedMerkleSig,
                    merkleRootSignatureAlg: st.expectedMerkleSigAlg,
                    expectedFileSha256: st.expectedFileSha256,
                    receiveKey: keys.receiveKey
                ) {
                    FileTransferManager.instance.completeExternalInboundTransfer(
                        transferId: st.transferId,
                        success: false,
                        error: failure.rawValue
                    )
                    try? FileManager.default.removeItem(at: st.tempURL)
                    inboundFileTransfers.removeValue(forKey: st.transferId)
                    inboundFileTransferCompleteTimers[st.transferId]?.cancel()
                    inboundFileTransferCompleteTimers.removeValue(forKey: st.transferId)
                    await sendAck(.init(op: .error, transferId: st.transferId, message: failure.rawValue), label: "completeError")
                    return
                }

                if let expected = st.expectedFileSha256, let actual = Self.sha256File(st.tempURL), actual != expected {
                    FileTransferManager.instance.completeExternalInboundTransfer(
                        transferId: st.transferId,
                        success: false,
                        error: "file sha256 mismatch"
                    )
                    try? FileManager.default.removeItem(at: st.tempURL)
                    inboundFileTransfers.removeValue(forKey: st.transferId)
                    inboundFileTransferCompleteTimers[st.transferId]?.cancel()
                    inboundFileTransferCompleteTimers.removeValue(forKey: st.transferId)
                    await sendAck(.init(op: .error, transferId: st.transferId, message: "file sha256 mismatch"), label: "completeError")
                    return
                }
                if FileManager.default.fileExists(atPath: st.finalURL.path) {
                    try? FileManager.default.removeItem(at: st.finalURL)
                }
                try FileManager.default.moveItem(at: st.tempURL, to: st.finalURL)

                FileTransferManager.instance.completeExternalInboundTransfer(
                    transferId: st.transferId,
                    success: true,
                    destinationURL: st.finalURL
                )
                inboundFileTransfers.removeValue(forKey: st.transferId)
                inboundFileTransferCompleteTimers[st.transferId]?.cancel()
                inboundFileTransferCompleteTimers.removeValue(forKey: st.transferId)

                await sendAck(
                    .init(
                        op: .completeAck,
                        transferId: st.transferId,
                        receivedBytes: st.receivedBytes,
                        fileSha256: st.expectedFileSha256 ?? Self.sha256File(st.finalURL)
                    ),
                    label: "completeAck"
                )
            } catch {
                FileTransferManager.instance.completeExternalInboundTransfer(
                    transferId: st.transferId,
                    success: false,
                    error: "Save failed"
                )
                try? FileManager.default.removeItem(at: st.tempURL)
                inboundFileTransfers.removeValue(forKey: st.transferId)
                inboundFileTransferCompleteTimers[st.transferId]?.cancel()
                inboundFileTransferCompleteTimers.removeValue(forKey: st.transferId)
                await sendAck(.init(op: .error, transferId: st.transferId, message: "Save failed"), label: "completeError")
            }

        case .cancel:
            if let st = inboundFileTransfers[msg.transferId] {
                try? st.handle.close()
                try? FileManager.default.removeItem(at: st.tempURL)
                inboundFileTransfers.removeValue(forKey: msg.transferId)
                FileTransferManager.instance.completeExternalInboundTransfer(
                    transferId: msg.transferId,
                    success: false,
                    error: msg.message ?? "Cancelled"
                )
            }

        case .metadataAck, .chunkAck, .completeAck:
            // These are acks for iOS->macOS sending.
            handleInboundFileTransferWire(msg)

        case .error:
            // Fail any pending iOS->macOS sender waits for this transfer immediately.
            failFileTransferWaiters(
                transferId: msg.transferId,
                message: msg.message ?? "remote error"
            )
        }
    }
}
