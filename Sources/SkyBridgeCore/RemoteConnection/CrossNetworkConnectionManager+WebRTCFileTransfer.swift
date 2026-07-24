import CryptoKit
import Foundation
import OSLog

@available(macOS 14.0, iOS 17.0, *)
@MainActor
extension CrossNetworkConnectionManager {
    private static let fileTransferLogger = Logger(
        subsystem: "com.skybridge.filetransfer",
        category: "WebRTCOutbound"
    )

    func resumeFileTransferWaiter(sessionID: String, message: CrossNetworkFileTransferMessage) {
        let key = WebRTCOutboundFileTransferSupport.waiterKey(
            sessionID: sessionID,
            transferId: message.transferId,
            op: message.op,
            chunkIndex: message.chunkIndex
        )
        if let waiter = webrtcFileTransferWaiters.removeValue(forKey: key) {
            waiter.timeoutTask.cancel()
            waiter.continuation.resume(returning: message)
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
            waiter.timeoutTask.cancel()
            waiter.continuation.resume(returning: message)
            return
        }
    }

    func failFileTransferWaiters(sessionID: String, transferId: String, message: String) {
        let keys = webrtcFileTransferWaiters.keys.filter {
            $0.sessionID == sessionID && $0.transferID == transferId
        }
        for k in keys {
            if let w = webrtcFileTransferWaiters.removeValue(forKey: k) {
                w.timeoutTask.cancel()
                w.continuation.resume(throwing: WebRTCFileTransferWaitError.remoteRejected(message))
            }
        }
    }

    func failAllFileTransferWaitersForSession(sessionID: String, message: String) {
        let keys = webrtcFileTransferWaiters.keys.filter { $0.sessionID == sessionID }
        for k in keys {
            if let w = webrtcFileTransferWaiters.removeValue(forKey: k) {
                w.timeoutTask.cancel()
                w.sendTask?.cancel()
                w.continuation.resume(throwing: WebRTCFileTransferWaitError.transportClosed(message))
            }
        }
    }

    private func cancelFileTransferWaiters(sessionID: String, transferId: String) {
        let keys = webrtcFileTransferWaiters.keys.filter {
            $0.sessionID == sessionID && $0.transferID == transferId
        }
        for key in keys {
            if let waiter = webrtcFileTransferWaiters.removeValue(forKey: key) {
                waiter.timeoutTask.cancel()
                waiter.continuation.resume(throwing: CancellationError())
            }
        }
    }

    private func takeFileTransferWaiter(
        forKey key: WebRTCOutboundFileTransferWaiterKey,
        token: UUID
    ) -> WebRTCFileTransferWaiter? {
        guard let waiter = webrtcFileTransferWaiters[key], waiter.token == token else {
            return nil
        }
        webrtcFileTransferWaiters.removeValue(forKey: key)
        waiter.timeoutTask.cancel()
        return waiter
    }

    private func cancelFileTransferWaiter(
        forKey key: WebRTCOutboundFileTransferWaiterKey,
        token: UUID
    ) {
        guard let waiter = takeFileTransferWaiter(forKey: key, token: token) else { return }
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func sendFileTransferMessageAndWait(
        sessionID: String,
        session: WebRTCSession,
        keys: SessionKeys,
        message: CrossNetworkFileTransferMessage,
        expectedOperation: CrossNetworkFileTransferOp,
        cancellationFlag: WebRTCOutboundFileTransferCancellationFlag,
        chunkIndex: Int? = nil,
        timeoutSeconds: TimeInterval
    ) async throws -> CrossNetworkFileTransferMessage {
        try Task.checkCancellation()
        try cancellationFlag.check()
        let key = WebRTCOutboundFileTransferSupport.waiterKey(
            sessionID: sessionID,
            transferId: message.transferId,
            op: expectedOperation,
            chunkIndex: chunkIndex
        )
        guard webrtcFileTransferWaiters[key] == nil else {
            throw WebRTCFileTransferWaitError.cancelled
        }

        let token = UUID()
        var ownedSendTask: Task<Void, Error>?
        do {
            let response = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                let timeoutTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        try await Task.sleep(for: .seconds(timeoutSeconds))
                    } catch is CancellationError {
                        return
                    } catch {
                        guard let pending = self.takeFileTransferWaiter(forKey: key, token: token) else {
                            return
                        }
                        pending.continuation.resume(throwing: error)
                        return
                    }
                    guard let pending = self.takeFileTransferWaiter(forKey: key, token: token) else {
                        return
                    }
                    pending.continuation.resume(throwing: WebRTCFileTransferWaitError.timeout)
                }

                webrtcFileTransferWaiters[key] = WebRTCFileTransferWaiter(
                    token: token,
                    continuation: continuation,
                    timeoutTask: timeoutTask,
                    sendTask: nil
                )

                    let sendTask = Task { @MainActor [weak self] in
                        guard let self else {
                            throw WebRTCFileTransferWaitError.transportClosed(
                                "file-transfer manager released during send"
                            )
                        }
                        do {
                            try await self.sendFileTransferMessage(
                                sessionID: sessionID,
                                session: session,
                                keys: keys,
                                message: message
                            )
                        } catch {
                            guard let pending = self.takeFileTransferWaiter(forKey: key, token: token) else {
                                throw error
                            }
                            pending.continuation.resume(throwing: error)
                            throw error
                        }
                    }
                    ownedSendTask = sendTask
                    if var pending = webrtcFileTransferWaiters[key], pending.token == token {
                        pending.sendTask = sendTask
                        webrtcFileTransferWaiters[key] = pending
                    } else {
                        sendTask.cancel()
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.cancelFileTransferWaiter(forKey: key, token: token)
                }
            }
            // ACK success cannot publish before the frame reaches the peer, but
            // explicitly joining the sender also covers injected/malformed replies
            // and makes transport quiescence a structural property.
            guard let ownedSendTask else {
                throw WebRTCFileTransferWaitError.transportClosed(
                    "file-transfer send task was not created"
                )
            }
            try await ownedSendTask.value
            try Task.checkCancellation()
            return response
        } catch let responseError {
            // Cancellation is safe at any point: the frame gate removes a queued
            // waiter before its first fragment, while WebRTCSession closes the
            // channel if cancellation interrupts a frame after its first fragment.
            if let ownedSendTask {
                ownedSendTask.cancel()
                if case .failure(let sendError) = await ownedSendTask.result,
                   !(sendError is CancellationError),
                   sendError.localizedDescription != responseError.localizedDescription {
                    Self.fileTransferLogger.error(
                        "WebRTC file-transfer waiter and frame send both failed: response=\(responseError.localizedDescription, privacy: .public) send=\(sendError.localizedDescription, privacy: .public)"
                    )
                }
            }
            throw responseError
        }
    }

    func encryptAppPayload(
        _ plaintext: Data,
        with keys: SessionKeys,
        sessionID: String,
        packetType: WebRTCAppSecurePacketType
    ) throws -> Data {
        try sealWebRTCSecurePayload(
            plaintext,
            with: keys,
            sessionID: sessionID,
            packetType: packetType
        )
    }

    func sendFramed(_ payload: Data, over session: WebRTCSession) async throws {
        try await session.sendFramedPayloadAsync(payload)
    }

    private func sendFileTransferMessage(sessionID: String, session: WebRTCSession, keys: SessionKeys, message: CrossNetworkFileTransferMessage) async throws {
        let plain = try JSONEncoder().encode(message)
        let enc = try encryptAppPayload(
            plain,
            with: keys,
            sessionID: sessionID,
            packetType: .fileTransfer
        )
        let padded = TrafficPadding.wrapIfEnabled(enc, label: "tx/webrtc-file")
        try await sendFramed(padded, over: session)
    }

    /// Send a local file to the currently connected iOS peer over WebRTC DataChannel (zero-config cross-network).
    public func sendFileToConnectedPeer(_ url: URL) async throws {
        guard RemoteDesktopSettingsManager.shared.settings.interactionSettings.enableFileTransfer else {
            throw WebRTCFileTransferWaitError.failed("远程桌面文件传输已在设置中关闭")
        }

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

        let senderDeviceId = try await SelfIdentityProvider.shared
            .protocolIdentityDeviceId(allowCreate: false)
        guard senderDeviceId == session.localDeviceId else {
            throw DeviceIdentityKeyError.corruptIdentityAuthority(
                "WebRTC file-transfer session is not bound to the current local authority"
            )
        }

        let transferId = UUID().uuidString
        let remoteId = webrtcRemoteIdBySessionId[sessionID] ?? "webrtc-peer"
        let remoteName = conn.deviceName

        var fileReader: WebRTCOutboundFileReader?
        var didBeginTransfer = false
        var didAttemptMetadata = false
        var didAttemptCompletion = false
        var presentationToken: FileTransferManager.ExternalTransferToken?
        let cancellationFlag = WebRTCOutboundFileTransferCancellationFlag()
        guard let transportOperationToken = FileTransferManager.shared.beginExternalTransportOperation(
            cancellationHandler: { [weak self, cancellationFlag] in
                cancellationFlag.cancel()
                self?.cancelFileTransferWaiters(
                    sessionID: sessionID,
                    transferId: transferId
                )
            }
        ) else {
            throw WebRTCFileTransferWaitError.cancelled
        }
        defer {
            FileTransferManager.shared.endExternalTransportOperation(
                transportOperationToken
            )
        }
        do {
            let reader = try await WebRTCOutboundFileReader.open(url: url)
            fileReader = reader
            try Task.checkCancellation()
            let fileSize = reader.fileSize

            guard let token = FileTransferManager.shared.beginExternalOutboundTransfer(
                transferId: transferId,
                fileURL: url,
                fileSize: fileSize,
                toDeviceId: remoteId,
                toDeviceName: remoteName,
                cancellationHandler: { [weak self, cancellationFlag] in
                    cancellationFlag.cancel()
                    self?.cancelFileTransferWaiters(
                        sessionID: sessionID,
                        transferId: transferId
                    )
                }
            ) else {
                throw WebRTCFileTransferWaitError.failed(
                    "File-transfer presentation lifecycle rejected the operation"
                )
            }
            presentationToken = token
            didBeginTransfer = true
            try cancellationFlag.check()

            // DataChannel payload should stay conservative to avoid SCTP message-size rejection on mixed endpoints.
            guard let chunkSize = WebRTCOutboundFileTransferSupport.dataChannelChunkSize(
                forFileSize: fileSize
            ) else {
                throw WebRTCFileTransferWaitError.failed("文件大小超出跨网传输协议容量")
            }
            guard let totalChunks = WebRTCOutboundFileTransferSupport.totalChunks(
                fileSize: fileSize,
                chunkSize: chunkSize
            ) else {
                throw WebRTCFileTransferWaitError.failed("文件分块规划失败")
            }
            if let metadataError = WebRTCInboundFileTransferSupport.validateMetadata(
                fileName: url.lastPathComponent,
                fileSize: fileSize,
                chunkSize: chunkSize,
                totalChunks: totalChunks
            ) {
                throw WebRTCFileTransferWaitError.failed(metadataError)
            }

            try cancellationFlag.check()
            let meta = CrossNetworkFileTransferMessage(
                op: .metadata,
                transferId: transferId,
                senderDeviceId: senderDeviceId,
                senderDeviceName: Host.current().localizedName,
                fileName: url.lastPathComponent,
                fileSize: fileSize,
                chunkSize: chunkSize,
                totalChunks: totalChunks,
                mimeType: nil
            )
            didAttemptMetadata = true
            _ = try await sendFileTransferMessageAndWait(
                sessionID: sessionID,
                session: session,
                keys: keys,
                message: meta,
                expectedOperation: .metadataAck,
                cancellationFlag: cancellationFlag,
                timeoutSeconds: 15
            )
            try cancellationFlag.check()

            var sentBytes: Int64 = 0
            var chunkIndex = 0

            while sentBytes < fileSize {
                try cancellationFlag.check()
                let remaining = Int(fileSize - sentBytes)
                let readLen = min(chunkSize, max(0, remaining))
                if readLen <= 0 { break }

                let data = try await reader.read(
                    offset: UInt64(sentBytes),
                    length: readLen
                )
                try cancellationFlag.check()
                let msg = CrossNetworkFileTransferMessage(
                    op: .chunk,
                    transferId: transferId,
                    chunkIndex: chunkIndex,
                    chunkData: data,
                    chunkSha256: CrossNetworkCrypto.sha256(data),
                    rawSize: data.count
                )
                let ack: CrossNetworkFileTransferMessage = try await {
                    () async throws -> CrossNetworkFileTransferMessage in
                    var lastError: Error?
                    for _ in 0..<3 {
                        try Task.checkCancellation()
                        do {
                            return try await sendFileTransferMessageAndWait(
                                sessionID: sessionID,
                                session: session,
                                keys: keys,
                                message: msg,
                                expectedOperation: .chunkAck,
                                cancellationFlag: cancellationFlag,
                                chunkIndex: chunkIndex,
                                timeoutSeconds: 30
                            )
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            guard WebRTCOutboundFileTransferSupport
                                .shouldRetryChunkAcknowledgment(after: error) else {
                                throw error
                            }
                            lastError = error
                        }
                    }
                    throw lastError ?? WebRTCFileTransferWaitError.timeout
                }()
                try cancellationFlag.check()

                if ack.op == .error {
                    throw WebRTCFileTransferWaitError.failed(ack.message ?? "remote error")
                }

                let expectedReceivedBytes = sentBytes + Int64(data.count)
                try WebRTCOutboundFileTransferSupport.validateChunkAck(
                    ack,
                    expectedReceivedBytes: expectedReceivedBytes
                )
                sentBytes = expectedReceivedBytes
                chunkIndex += 1

                FileTransferManager.shared.updateExternalOutboundProgress(
                    token: token,
                    transferredBytes: sentBytes
                )
            }

            let fileSha = try await reader.finalizeAndClose()
            fileReader = nil
            try cancellationFlag.check()
            let done = CrossNetworkFileTransferMessage(
                op: .complete,
                transferId: transferId,
                receivedBytes: fileSize,
                fileSha256: fileSha
            )
            let completionAck: CrossNetworkFileTransferMessage
            do {
                didAttemptCompletion = true
                completionAck = try await sendFileTransferMessageAndWait(
                    sessionID: sessionID,
                    session: session,
                    keys: keys,
                    message: done,
                    expectedOperation: .completeAck,
                    cancellationFlag: cancellationFlag,
                    timeoutSeconds: 30
                )
            } catch {
                throw WebRTCOutboundFileTransferSupport.normalizedCompletionWaitError(error)
            }
            try WebRTCOutboundFileTransferSupport.validateCompletionAck(
                completionAck,
                expectedFileSize: fileSize,
                expectedFileSha256: fileSha
            )

            FileTransferManager.shared.completeExternalOutboundTransfer(token: token)
        } catch {
            let operationError = error
            var reportedError = operationError
            if let fileReader {
                do {
                    try await fileReader.close()
                } catch {
                    reportedError = WebRTCFileTransferWaitError.failed(
                        "传输失败（\(operationError.localizedDescription)），且本地文件句柄关闭失败（\(error.localizedDescription)）"
                    )
                }
            }
            if didAttemptMetadata, !didAttemptCompletion {
                let cancellationNoticeTask = Task { @MainActor in
                    try await self.sendFileTransferMessage(
                        sessionID: sessionID,
                        session: session,
                        keys: keys,
                        message: CrossNetworkFileTransferMessage(
                            op: .cancel,
                            transferId: transferId,
                            message: "sender terminated before commit request"
                        )
                    )
                }
                do {
                    try await cancellationNoticeTask.value
                } catch {
                    Self.fileTransferLogger.error(
                        "WebRTC outbound cancellation notice failed after pre-commit termination: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            if didBeginTransfer, let presentationToken {
                if !didAttemptCompletion,
                   operationError is CancellationError || cancellationFlag.isCancelled {
                    reportedError = FileTransferError.transferCancelled
                    FileTransferManager.shared.cancelExternalOutboundTransfer(
                        token: presentationToken
                    )
                } else {
                    FileTransferManager.shared.failExternalOutboundTransfer(
                        token: presentationToken,
                        errorMessage: reportedError.localizedDescription,
                        receiptDeliveryStatus: Self.receiptDeliveryStatus(for: operationError)
                    )
                }
            }
            throw reportedError
        }
    }

    private static func receiptDeliveryStatus(
        for error: Error
    ) -> FileTransferReceiptDeliveryStatus? {
        guard let transferError = error as? FileTransferError,
              case .deliveryConfirmationUnknown = transferError else {
            return nil
        }
        return .unknown
    }
}
