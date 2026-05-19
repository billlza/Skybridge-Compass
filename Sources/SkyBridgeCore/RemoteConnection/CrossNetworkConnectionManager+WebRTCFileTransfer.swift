import CryptoKit
import Foundation

@available(macOS 14.0, iOS 17.0, *)
@MainActor
extension CrossNetworkConnectionManager {
    func resumeFileTransferWaiter(sessionID: String, message: CrossNetworkFileTransferMessage) {
        let key = WebRTCOutboundFileTransferSupport.waiterKey(
            sessionID: sessionID,
            transferId: message.transferId,
            op: message.op,
            chunkIndex: message.chunkIndex
        )
        if let waiter = webrtcFileTransferWaiters.removeValue(forKey: key) {
            waiter.resume(returning: message)
            return
        }

        // Also allow awaiting without chunkIndex.
        let keyNoIdx = WebRTCOutboundFileTransferSupport.waiterKey(
            sessionID: sessionID,
            transferId: message.transferId,
            op: message.op,
            chunkIndex: nil
        )
        if let waiter = webrtcFileTransferWaiters.removeValue(forKey: keyNoIdx) {
            waiter.resume(returning: message)
            return
        }
    }

    func failFileTransferWaiters(sessionID: String, transferId: String, message: String) {
        let prefix = WebRTCOutboundFileTransferSupport.waiterPrefix(
            sessionID: sessionID,
            transferId: transferId
        )
        let keys = webrtcFileTransferWaiters.keys.filter { $0.hasPrefix(prefix) }
        for k in keys {
            if let w = webrtcFileTransferWaiters.removeValue(forKey: k) {
                w.resume(throwing: WebRTCFileTransferWaitError.failed(message))
            }
        }
    }

    func failAllFileTransferWaitersForSession(sessionID: String, message: String) {
        let prefix = WebRTCOutboundFileTransferSupport.sessionWaiterPrefix(sessionID: sessionID)
        let keys = webrtcFileTransferWaiters.keys.filter { $0.hasPrefix(prefix) }
        for k in keys {
            if let w = webrtcFileTransferWaiters.removeValue(forKey: k) {
                w.resume(throwing: WebRTCFileTransferWaitError.failed(message))
            }
        }
    }

    private func waitForFileTransferMessage(
        sessionID: String,
        transferId: String,
        op: CrossNetworkFileTransferOp,
        chunkIndex: Int? = nil,
        timeoutSeconds: TimeInterval = 20
    ) async throws -> CrossNetworkFileTransferMessage {
        let key = WebRTCOutboundFileTransferSupport.waiterKey(
            sessionID: sessionID,
            transferId: transferId,
            op: op,
            chunkIndex: chunkIndex
        )
        if webrtcFileTransferWaiters[key] != nil {
            throw WebRTCFileTransferWaitError.cancelled
        }

        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<CrossNetworkFileTransferMessage, Error>) in
            webrtcFileTransferWaiters[key] = c

            Task { @MainActor [weak self] in
                guard let self else { return }
                do { try await Task.sleep(for: .seconds(timeoutSeconds)) } catch { return }
                if let pending = self.webrtcFileTransferWaiters.removeValue(forKey: key) {
                    pending.resume(throwing: WebRTCFileTransferWaitError.timeout)
                }
            }
        }
    }

    func encryptAppPayload(_ plaintext: Data, with keys: SessionKeys) throws -> Data {
        try WebRTCControlChannelCodec.encryptAppPayload(plaintext, with: keys)
    }

    func sendFramed(_ payload: Data, over session: WebRTCSession) async throws {
        try await session.sendFramedPayloadAsync(payload)
    }

    private func sendFileTransferMessage(sessionID: String, session: WebRTCSession, keys: SessionKeys, message: CrossNetworkFileTransferMessage) async throws {
        let plain = try JSONEncoder().encode(message)
        let enc = try encryptAppPayload(plain, with: keys)
        let padded = TrafficPadding.wrapIfEnabled(enc, label: "tx/webrtc-file")
        try await sendFramed(padded, over: session)
    }

    /// Send a local file to the currently connected iOS peer over WebRTC DataChannel (zero-config cross-network).
    public func sendFileToConnectedPeer(_ url: URL) async throws {
        guard case .connected = connectionStatus,
              let conn = currentConnection,
              case .webrtc(let session) = conn.transport
        else {
            throw WebRTCFileTransferWaitError.failed("未建立跨网连接")
        }

        let sessionID = conn.id
        guard let keys = webrtcSessionKeysBySessionId[sessionID] else {
            throw WebRTCFileTransferWaitError.failed("握手未完成（会话密钥不可用）")
        }

        // Validate file
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        if let type = attrs[.type] as? FileAttributeType, type == .typeDirectory {
            throw WebRTCFileTransferWaitError.failed("暂不支持直接发送文件夹")
        }
        let fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard fileSize > 0 else {
            throw WebRTCFileTransferWaitError.failed("文件大小无效")
        }

        let transferId = UUID().uuidString
        let remoteId = webrtcRemoteIdBySessionId[sessionID] ?? "webrtc-peer"
        let remoteName = conn.deviceName

        FileTransferManager.shared.beginExternalOutboundTransfer(
            transferId: transferId,
            fileURL: url,
            fileSize: fileSize,
            toDeviceId: remoteId,
            toDeviceName: remoteName
        )

        do {
            // DataChannel payload should stay conservative to avoid SCTP message-size rejection on mixed endpoints.
            let chunkSize = WebRTCOutboundFileTransferSupport.dataChannelChunkSize
            guard let totalChunks = WebRTCOutboundFileTransferSupport.totalChunks(
                fileSize: fileSize,
                chunkSize: chunkSize
            ) else {
                throw WebRTCFileTransferWaitError.failed("文件分块规划失败")
            }

            let snap = await SelfIdentityProvider.shared.snapshot()
            let meta = CrossNetworkFileTransferMessage(
                op: .metadata,
                transferId: transferId,
                senderDeviceId: snap.deviceId.isEmpty ? deviceFingerprint : snap.deviceId,
                senderDeviceName: Host.current().localizedName,
                fileName: url.lastPathComponent,
                fileSize: fileSize,
                chunkSize: chunkSize,
                totalChunks: totalChunks,
                mimeType: nil
            )
            try await sendFileTransferMessage(sessionID: sessionID, session: session, keys: keys, message: meta)

            _ = try await waitForFileTransferMessage(sessionID: sessionID, transferId: transferId, op: .metadataAck, timeoutSeconds: 15)

            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }

            var sentBytes: Int64 = 0
            var chunkIndex = 0
            var fileHasher = SHA256()

            while sentBytes < fileSize {
                let remaining = Int(fileSize - sentBytes)
                let readLen = min(chunkSize, max(0, remaining))
                if readLen <= 0 { break }

                try handle.seek(toOffset: UInt64(sentBytes))
                let data = handle.readData(ofLength: readLen)
                if data.isEmpty { break }

                fileHasher.update(data: data)
                let msg = CrossNetworkFileTransferMessage(
                    op: .chunk,
                    transferId: transferId,
                    chunkIndex: chunkIndex,
                    chunkData: data,
                    chunkSha256: CrossNetworkCrypto.sha256(data),
                    rawSize: data.count
                )
                try await sendFileTransferMessage(sessionID: sessionID, session: session, keys: keys, message: msg)

                let ack: CrossNetworkFileTransferMessage = try await {
                    () async throws -> CrossNetworkFileTransferMessage in
                    var lastError: Error?
                    for _ in 0..<3 {
                        do {
                            return try await waitForFileTransferMessage(
                                sessionID: sessionID,
                                transferId: transferId,
                                op: .chunkAck,
                                chunkIndex: chunkIndex,
                                timeoutSeconds: 30
                            )
                        } catch {
                            lastError = error
                            // Best-effort resend: safe because receiver writes at fixed offset.
                            do {
                                try await sendFileTransferMessage(sessionID: sessionID, session: session, keys: keys, message: msg)
                            } catch {
                                lastError = error
                                break
                            }
                        }
                    }
                    throw lastError ?? WebRTCFileTransferWaitError.timeout
                }()

                if ack.op == .error {
                    throw WebRTCFileTransferWaitError.failed(ack.message ?? "remote error")
                }

                let progressed = ack.receivedBytes ?? (sentBytes + Int64(data.count))
                sentBytes = min(fileSize, max(sentBytes + Int64(data.count), progressed))
                chunkIndex += 1

                FileTransferManager.shared.updateExternalOutboundProgress(
                    transferId: transferId,
                    transferredBytes: sentBytes
                )
            }

            let fileSha = Data(fileHasher.finalize())
            let done = CrossNetworkFileTransferMessage(
                op: .complete,
                transferId: transferId,
                receivedBytes: fileSize,
                fileSha256: fileSha
            )
            try await sendFileTransferMessage(sessionID: sessionID, session: session, keys: keys, message: done)
            let completionAck = try await waitForFileTransferMessage(
                sessionID: sessionID,
                transferId: transferId,
                op: .completeAck,
                timeoutSeconds: 30
            )
            try WebRTCOutboundFileTransferSupport.validateCompletionAck(
                completionAck,
                expectedFileSize: fileSize,
                expectedFileSha256: fileSha
            )

            FileTransferManager.shared.completeExternalOutboundTransfer(transferId: transferId)
        } catch {
            FileTransferManager.shared.failExternalOutboundTransfer(transferId: transferId, errorMessage: error.localizedDescription)
            throw error
        }
    }
}
