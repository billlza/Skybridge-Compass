import CryptoKit
import Foundation
import OSLog
import enum SkyBridgeProtocolCore.CrossNetworkFileTransferWireEncoder

@available(macOS 14.0, iOS 17.0, *)
@MainActor
extension CrossNetworkConnectionManager {
    private static let fileTransferLogger = Logger(
        subsystem: "com.skybridge.filetransfer",
        category: "WebRTCOutbound"
    )

    func resumeFileTransferWaiter(
        owner: WebRTCFileTransferOperationOwner,
        message: CrossNetworkFileTransferMessage
    ) {
        guard isCurrentWebRTCFileTransferOperationOwner(owner) else { return }
        let key = WebRTCOutboundFileTransferSupport.waiterKey(
            sessionID: owner.sessionID,
            transferId: message.transferId,
            op: message.op,
            chunkIndex: message.chunkIndex
        )
        if let waiter = takeFileTransferWaiter(forKey: key, matching: owner) {
            waiter.timeoutTask.cancel()
            waiter.continuation.resume(returning: message)
            return
        }

        // Also allow awaiting without chunkIndex.
        let keyNoIdx = WebRTCOutboundFileTransferSupport.waiterKey(
            sessionID: owner.sessionID,
            transferId: message.transferId,
            op: message.op,
            chunkIndex: nil
        )
        if let waiter = takeFileTransferWaiter(forKey: keyNoIdx, matching: owner) {
            waiter.timeoutTask.cancel()
            waiter.continuation.resume(returning: message)
            return
        }
    }

    func failFileTransferWaiters(
        owner: WebRTCFileTransferOperationOwner,
        transferId: String,
        message: String
    ) {
        guard isCurrentWebRTCFileTransferOperationOwner(owner) else { return }
        let keys = webrtcFileTransferWaiters.keys.filter {
            $0.sessionID == owner.sessionID && $0.transferID == transferId
        }
        for k in keys {
            if let w = takeFileTransferWaiter(forKey: k, matching: owner) {
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

    private func cancelFileTransferWaiters(
        owner: WebRTCFileTransferOperationOwner,
        transferId: String
    ) {
        let keys = webrtcFileTransferWaiters.keys.filter {
            $0.sessionID == owner.sessionID && $0.transferID == transferId
        }
        for key in keys {
            if let waiter = takeFileTransferWaiter(forKey: key, matching: owner) {
                waiter.timeoutTask.cancel()
                waiter.continuation.resume(throwing: CancellationError())
            }
        }
    }

    private func takeFileTransferWaiter(
        forKey key: WebRTCOutboundFileTransferWaiterKey,
        token: UUID,
        matching owner: WebRTCFileTransferOperationOwner
    ) -> WebRTCFileTransferWaiter? {
        guard let waiter = webrtcFileTransferWaiters[key],
              waiter.token == token,
              Self.isSameWebRTCFileTransferOperationOwner(waiter.owner, owner) else {
            return nil
        }
        webrtcFileTransferWaiters.removeValue(forKey: key)
        waiter.timeoutTask.cancel()
        return waiter
    }

    private func cancelFileTransferWaiter(
        forKey key: WebRTCOutboundFileTransferWaiterKey,
        token: UUID,
        owner: WebRTCFileTransferOperationOwner
    ) {
        guard let waiter = takeFileTransferWaiter(
            forKey: key,
            token: token,
            matching: owner
        ) else { return }
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func takeFileTransferWaiter(
        forKey key: WebRTCOutboundFileTransferWaiterKey,
        matching owner: WebRTCFileTransferOperationOwner
    ) -> WebRTCFileTransferWaiter? {
        guard let waiter = webrtcFileTransferWaiters[key],
              Self.isSameWebRTCFileTransferOperationOwner(waiter.owner, owner) else {
            return nil
        }
        webrtcFileTransferWaiters.removeValue(forKey: key)
        waiter.timeoutTask.cancel()
        return waiter
    }

    private func sendFileTransferMessageAndWait(
        owner: WebRTCFileTransferOperationOwner,
        message: CrossNetworkFileTransferMessage,
        expectedOperation: CrossNetworkFileTransferOp,
        cancellationFlag: WebRTCOutboundFileTransferCancellationFlag,
        chunkIndex: Int? = nil,
        timeoutSeconds: TimeInterval
    ) async throws -> CrossNetworkFileTransferMessage {
        try requireCurrentWebRTCFileTransferOperationOwner(owner)
        try cancellationFlag.check()
        let key = WebRTCOutboundFileTransferSupport.waiterKey(
            sessionID: owner.sessionID,
            transferId: message.transferId,
            op: expectedOperation,
            chunkIndex: chunkIndex
        )
        if let existing = webrtcFileTransferWaiters[key] {
            guard !Self.isSameWebRTCFileTransferOperationOwner(existing.owner, owner) else {
                throw WebRTCFileTransferWaitError.cancelled
            }
            webrtcFileTransferWaiters.removeValue(forKey: key)
            existing.timeoutTask.cancel()
            existing.sendTask?.cancel()
            existing.continuation.resume(throwing: CancellationError())
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
                        guard let pending = self.takeFileTransferWaiter(
                            forKey: key,
                            token: token,
                            matching: owner
                        ) else {
                            return
                        }
                        pending.continuation.resume(throwing: error)
                        return
                    }
                    guard self.isCurrentWebRTCFileTransferOperationOwner(owner) else {
                        guard let pending = self.takeFileTransferWaiter(
                            forKey: key,
                            token: token,
                            matching: owner
                        ) else { return }
                        pending.continuation.resume(throwing: CancellationError())
                        return
                    }
                    guard let pending = self.takeFileTransferWaiter(
                        forKey: key,
                        token: token,
                        matching: owner
                    ) else {
                        return
                    }
                    pending.continuation.resume(throwing: WebRTCFileTransferWaitError.timeout)
                }

                webrtcFileTransferWaiters[key] = WebRTCFileTransferWaiter(
                    token: token,
                    owner: owner,
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
                                owner: owner,
                                message: message
                            )
                        } catch {
                            guard let pending = self.takeFileTransferWaiter(
                                forKey: key,
                                token: token,
                                matching: owner
                            ) else {
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
                    self?.cancelFileTransferWaiter(
                        forKey: key,
                        token: token,
                        owner: owner
                    )
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
            try requireCurrentWebRTCFileTransferOperationOwner(owner)
            return response
        } catch let responseError {
            // Cancellation is safe at any point: the frame gate removes a queued
            // waiter before its first fragment, while WebRTCSession closes the
            // channel if cancellation interrupts a frame after its first fragment.
            if let ownedSendTask {
                ownedSendTask.cancel()
                if case .failure(let sendError) = await ownedSendTask.result,
                   isCurrentWebRTCFileTransferOperationOwner(owner),
                   !(sendError is CancellationError),
                   sendError.localizedDescription != responseError.localizedDescription {
                    Self.fileTransferLogger.error(
                        "WebRTC file-transfer waiter and frame send both failed: response=\(responseError.localizedDescription, privacy: .public) send=\(sendError.localizedDescription, privacy: .public)"
                    )
                }
            }
            guard isCurrentWebRTCFileTransferOperationOwner(owner) else {
                throw CancellationError()
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

    private func sendFileTransferMessage(
        owner: WebRTCFileTransferOperationOwner,
        message: CrossNetworkFileTransferMessage
    ) async throws {
        try requireCurrentWebRTCFileTransferOperationOwner(owner)
        let plain = try CrossNetworkFileTransferWireEncoder.encode(message)
        try requireCurrentWebRTCFileTransferOperationOwner(owner)
        let enc = try encryptAppPayload(
            plain,
            with: owner.keys,
            sessionID: owner.sessionID,
            packetType: .fileTransfer
        )
        try requireCurrentWebRTCFileTransferOperationOwner(owner)
        let padded = try TrafficPadding.wrapIfEnabled(enc, label: "tx/webrtc-file")
        try requireCurrentWebRTCFileTransferOperationOwner(owner)
        try await sendFramed(padded, over: owner.session)
        try requireCurrentWebRTCFileTransferOperationOwner(owner)
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
        guard let operationOwner = currentWebRTCFileTransferOperationOwner(
            sessionID: sessionID,
            session: session,
            keys: keys
        ) else {
            throw CancellationError()
        }

        try requireCurrentWebRTCFileTransferOperationOwner(operationOwner)
        let senderDeviceId = try await SelfIdentityProvider.shared
            .protocolIdentityDeviceId(allowCreate: false)
        try requireCurrentWebRTCFileTransferOperationOwner(operationOwner)
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
        func terminalizeStalePresentationIfNeeded() {
            guard didBeginTransfer, let presentationToken else { return }
            FileTransferManager.shared.cancelExternalOutboundTransfer(
                token: presentationToken
            )
        }
        try requireCurrentWebRTCFileTransferOperationOwner(operationOwner)
        guard let transportOperationToken = FileTransferManager.shared.beginExternalTransportOperation(
            cancellationHandler: { [weak self, cancellationFlag] in
                cancellationFlag.cancel()
                self?.cancelFileTransferWaiters(
                    owner: operationOwner,
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
            try requireCurrentWebRTCFileTransferOperationOwner(operationOwner)
            let reader = try await WebRTCOutboundFileReader.open(url: url)
            fileReader = reader
            try requireCurrentWebRTCFileTransferOperationOwner(operationOwner)
            let fileSize = reader.fileSize

            try requireCurrentWebRTCFileTransferOperationOwner(operationOwner)
            guard let token = FileTransferManager.shared.beginExternalOutboundTransfer(
                transferId: transferId,
                fileURL: url,
                fileSize: fileSize,
                toDeviceId: remoteId,
                toDeviceName: remoteName,
                cancellationHandler: { [weak self, cancellationFlag] in
                    cancellationFlag.cancel()
                    self?.cancelFileTransferWaiters(
                        owner: operationOwner,
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
            try requireCurrentWebRTCFileTransferOperationOwner(operationOwner)
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
            try requireCurrentWebRTCFileTransferOperationOwner(operationOwner)
            let meta = CrossNetworkFileTransferMessage(
                op: .metadata,
                transferId: transferId,
                senderDeviceId: senderDeviceId,
                senderDeviceName: LocalHostName.localizedName,
                fileName: url.lastPathComponent,
                fileSize: fileSize,
                chunkSize: chunkSize,
                totalChunks: totalChunks,
                mimeType: nil
            )
            didAttemptMetadata = true
            _ = try await sendFileTransferMessageAndWait(
                owner: operationOwner,
                message: meta,
                expectedOperation: .metadataAck,
                cancellationFlag: cancellationFlag,
                timeoutSeconds: 15
            )
            try requireCurrentWebRTCFileTransferOperationOwner(operationOwner)
            try cancellationFlag.check()

            var sentBytes: Int64 = 0
            var chunkIndex = 0

            while sentBytes < fileSize {
                try requireCurrentWebRTCFileTransferOperationOwner(operationOwner)
                try cancellationFlag.check()
                let remaining = Int(fileSize - sentBytes)
                let readLen = min(chunkSize, max(0, remaining))
                if readLen <= 0 { break }

                let data = try await reader.read(
                    offset: UInt64(sentBytes),
                    length: readLen
                )
                try requireCurrentWebRTCFileTransferOperationOwner(operationOwner)
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
                        try requireCurrentWebRTCFileTransferOperationOwner(operationOwner)
                        do {
                            return try await sendFileTransferMessageAndWait(
                                owner: operationOwner,
                                message: msg,
                                expectedOperation: .chunkAck,
                                cancellationFlag: cancellationFlag,
                                chunkIndex: chunkIndex,
                                timeoutSeconds: 30
                            )
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            try requireCurrentWebRTCFileTransferOperationOwner(operationOwner)
                            guard WebRTCOutboundFileTransferSupport
                                .shouldRetryChunkAcknowledgment(after: error) else {
                                throw error
                            }
                            lastError = error
                        }
                    }
                    throw lastError ?? WebRTCFileTransferWaitError.timeout
                }()
                try requireCurrentWebRTCFileTransferOperationOwner(operationOwner)
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

                try requireCurrentWebRTCFileTransferOperationOwner(operationOwner)
                FileTransferManager.shared.updateExternalOutboundProgress(
                    token: token,
                    transferredBytes: sentBytes
                )
            }

            try requireCurrentWebRTCFileTransferOperationOwner(operationOwner)
            let fileSha = try await reader.finalizeAndClose()
            fileReader = nil
            try requireCurrentWebRTCFileTransferOperationOwner(operationOwner)
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
                    owner: operationOwner,
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

            try requireCurrentWebRTCFileTransferOperationOwner(operationOwner)
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
            guard isCurrentWebRTCFileTransferOperationOwner(operationOwner) else {
                cancelFileTransferWaiters(
                    owner: operationOwner,
                    transferId: transferId
                )
                terminalizeStalePresentationIfNeeded()
                throw CancellationError()
            }
            if didAttemptMetadata, !didAttemptCompletion {
                let cancellationNoticeTask = Task { @MainActor in
                    try await self.sendFileTransferMessage(
                        owner: operationOwner,
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
                    guard isCurrentWebRTCFileTransferOperationOwner(operationOwner) else {
                        cancelFileTransferWaiters(
                            owner: operationOwner,
                            transferId: transferId
                        )
                        terminalizeStalePresentationIfNeeded()
                        throw CancellationError()
                    }
                    Self.fileTransferLogger.error(
                        "WebRTC outbound cancellation notice failed after pre-commit termination: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            try requireCurrentWebRTCFileTransferOperationOwner(operationOwner)
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
