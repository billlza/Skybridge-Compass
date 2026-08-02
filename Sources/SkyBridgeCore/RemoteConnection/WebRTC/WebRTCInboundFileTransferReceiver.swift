import Foundation
import OSLog
import SkyBridgeProtocolCore

@available(macOS 14.0, iOS 17.0, *)
@MainActor
final class WebRTCInboundFileTransferReceiver {
    typealias SendMessage = (CrossNetworkFileTransferMessage, String) async throws -> Void
    typealias FailSenderWaiters = (String, String) -> Void
    typealias ResumeSenderWaiter = (CrossNetworkFileTransferMessage) -> Void
    typealias ApprovalProvider = @MainActor (WebRTCInboundFileTransferApprovalRequest) async -> WebRTCInboundFileTransferApprovalDecision
    typealias SenderAuthorityProvider = @MainActor (String) -> WebRTCInboundFileTransferSenderAuthority?

    private struct QueuedInboundOperation {
        let message: CrossNetworkFileTransferMessage
        let reservation: CrossNetworkFileTransferOperationReservationLedger.Reservation
        let sessionID: String
        let endpointDescription: String
        let keys: SessionKeys
        let sendMessage: SendMessage
        let failSenderWaiters: FailSenderWaiters
        let resumeSenderWaiter: ResumeSenderWaiter
        let onFatalError: @MainActor (Error) -> Void
    }

    enum InboundOperationQueueError: LocalizedError {
        case capacityExceeded(maximum: Int)
        case retainedByteCapacityExceeded(maximum: Int)
        case accountingInvariantViolated
        case invalidRequestOperation(op: CrossNetworkFileTransferOp)

        var errorDescription: String? {
            switch self {
            case .capacityExceeded(let maximum):
                return "WebRTC inbound file-transfer operation queue exceeded maximum=\(maximum)"
            case .retainedByteCapacityExceeded(let maximum):
                return "WebRTC inbound file-transfer retained-byte budget exceeded maximum=\(maximum)"
            case .accountingInvariantViolated:
                return "WebRTC inbound file-transfer retained-byte accounting invariant failed"
            case .invalidRequestOperation(let op):
                return "WebRTC inbound file-transfer request queue rejected operation=\(op.rawValue)"
            }
        }
    }

    private struct PendingAdmission {
        let token: UUID
        let sessionID: String
        let metadataBinding: WebRTCInboundFileTransferMetadataBinding
    }

    private static let defaultMaxConcurrentInboundTransfers = 8
    private static let defaultMaxGlobalConcurrentInboundTransfers = 16
    private static let defaultTransferIdleTimeout: Duration = .seconds(120)
    private static let defaultMaxTerminalReceiptsPerSession = 128
    private static let defaultTerminalReceiptTTL: TimeInterval = 300
    private static let maximumQueuedInboundOperations =
        CrossNetworkFileTransferInboundAdmissionPolicy.maximumQueuedOperationCount

    private let destinationBaseDirectory: () -> URL?
    private let approvalProvider: ApprovalProvider
    private let senderAuthorityProvider: SenderAuthorityProvider
    private let maxConcurrentInboundTransfers: Int
    private let maxGlobalConcurrentInboundTransfers: Int
    private let admissionLedger: WebRTCInboundFileTransferAdmissionLedger
    private let transferIdleTimeout: Duration
    private let now: () -> Date
    private let ioActor: InboundFileTransferIOActor
    private let logger = Logger(subsystem: "com.skybridge.filetransfer", category: "WebRTCInbound")
    private var transfers: [String: WebRTCInboundFileTransferState] = [:]
    private var completeTimers: [String: Task<Void, Never>] = [:]
    private var idleTimers: [String: Task<Void, Never>] = [:]
    private var terminalReceipts: WebRTCInboundFileTransferTerminalReceiptCache
    private var pendingAdmissions: [String: PendingAdmission] = [:]
    private var chunkOperationsInFlight: Set<String> = []
    private var cancelledTransportOperationIDs: Set<UUID> = []
    private var queuedInboundOperationsByTransferID: [String: [QueuedInboundOperation]] = [:]
    private var inboundOperationReservationLedger =
        CrossNetworkFileTransferOperationReservationLedger()
    var retainedInboundOperationByteCount: Int {
        inboundOperationReservationLedger.retainedByteCount
    }
    var retainedInboundOperationCount: Int {
        inboundOperationReservationLedger.reservationCount
    }
    private var inboundOperationWorkers: [String: Task<Void, Never>] = [:]
    private var acceptsQueuedInboundOperations = true
    private var lifecycleToken = UUID()

    init(
        destinationBaseDirectory: @escaping () -> URL? = {
            FileManager.default
                .urls(for: .downloadsDirectory, in: .userDomainMask)
                .first?
                .appendingPathComponent("SkyBridge", isDirectory: true)
        },
        maxConcurrentInboundTransfers: Int = WebRTCInboundFileTransferReceiver.defaultMaxConcurrentInboundTransfers,
        maxGlobalConcurrentInboundTransfers: Int = WebRTCInboundFileTransferReceiver.defaultMaxGlobalConcurrentInboundTransfers,
        transferIdleTimeout: Duration = WebRTCInboundFileTransferReceiver.defaultTransferIdleTimeout,
        maxTerminalReceiptsPerSession: Int = WebRTCInboundFileTransferReceiver.defaultMaxTerminalReceiptsPerSession,
        terminalReceiptTTL: TimeInterval = WebRTCInboundFileTransferReceiver.defaultTerminalReceiptTTL,
        now: @escaping () -> Date = Date.init,
        admissionLedger: WebRTCInboundFileTransferAdmissionLedger = .shared,
        ioActor: InboundFileTransferIOActor = .shared,
        senderAuthorityProvider: @escaping SenderAuthorityProvider,
        approvalProvider: @escaping ApprovalProvider = { _ in
            .rejected(reason: WebRTCInboundFileTransferSupport.explicitApprovalRequiredMessage)
        }
    ) {
        precondition(maxConcurrentInboundTransfers > 0, "Inbound transfer session limit must be positive")
        precondition(maxGlobalConcurrentInboundTransfers > 0, "Inbound transfer global limit must be positive")
        self.destinationBaseDirectory = destinationBaseDirectory
        self.approvalProvider = approvalProvider
        self.senderAuthorityProvider = senderAuthorityProvider
        self.maxConcurrentInboundTransfers = maxConcurrentInboundTransfers
        self.maxGlobalConcurrentInboundTransfers = maxGlobalConcurrentInboundTransfers
        self.admissionLedger = admissionLedger
        self.transferIdleTimeout = transferIdleTimeout
        self.now = now
        self.ioActor = ioActor
        self.terminalReceipts = WebRTCInboundFileTransferTerminalReceiptCache(
            maxReceiptsPerSession: maxTerminalReceiptsPerSession,
            timeToLive: terminalReceiptTTL
        )
    }

    @discardableResult
    func cleanupOnChannelClosed() -> Task<Void, Never> {
        lifecycleToken = UUID()
        acceptsQueuedInboundOperations = false
        let queuedOperations = queuedInboundOperationsByTransferID.values.flatMap { $0 }
        queuedInboundOperationsByTransferID.removeAll(keepingCapacity: false)
        for operation in queuedOperations {
            _ = releaseRetainedInboundOperationReservation(operation.reservation)
        }
        let operationWorkers = Array(inboundOperationWorkers.values)
        for operationWorker in operationWorkers {
            operationWorker.cancel()
        }
        for (_, task) in completeTimers {
            task.cancel()
        }
        completeTimers.removeAll()
        for (_, task) in idleTimers {
            task.cancel()
        }
        idleTimers.removeAll()
        terminalReceipts.removeAll()

        for pending in pendingAdmissions.values {
            admissionLedger.release(pending.token)
        }
        pendingAdmissions.removeAll()

        let ioActor = self.ioActor
        let logger = self.logger
        return Task { @MainActor [self] in
            for operationWorker in operationWorkers {
                await operationWorker.value
            }
            inboundOperationWorkers.removeAll(keepingCapacity: false)

            let statesToDiscard = transfers.values.filter { !$0.isFinalizing }
            for state in statesToDiscard {
                admissionLedger.release(state.stateToken)
                transfers.removeValue(forKey: state.transferId)
            }
            for state in statesToDiscard {
                var terminalMessage = "WebRTC channel closed before transfer completion"
                do {
                    try await ioActor.discardUncommittedFile(state.ioHandle)
                } catch {
                    terminalMessage = FileTransferError.partialFileCleanupFailed.localizedDescription
                    logger.error(
                        "WebRTC channel-close partial cleanup failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
                // Keep the external presentation token active until its owned I/O
                // has quiesced. FileTransferManager.stop() uses that token as the
                // operation lease and therefore cannot return ahead of cleanup.
                FileTransferManager.shared.failExternalTransfer(
                    token: state.presentationToken,
                    errorMessage: terminalMessage
                )
            }
        }
    }

    /// Queues inbound request operations away from the control-channel receive
    /// loop. ACK/error routing stays synchronous in that loop, so a 60-second
    /// approval prompt or a large-file fsync cannot starve heartbeat, remote
    /// control, or the opposite-direction file sender.
    func enqueueInboundRequest(
        _ message: CrossNetworkFileTransferMessage,
        encodedPayloadByteCount: Int,
        sessionID: String,
        endpointDescription: String,
        keys: SessionKeys,
        sendMessage: @escaping SendMessage,
        failSenderWaiters: @escaping FailSenderWaiters,
        resumeSenderWaiter: @escaping ResumeSenderWaiter,
        onFatalError: @escaping @MainActor (Error) -> Void
    ) throws {
        switch message.op {
        case .metadata, .chunk, .complete, .cancel:
            break
        case .error, .metadataAck, .chunkAck, .completeAck:
            throw InboundOperationQueueError.invalidRequestOperation(op: message.op)
        }
        let retainedByteCount = try CrossNetworkFileTransferInboundAdmissionPolicy
            .retainedByteCharge(
                for: message,
                encodedPayloadByteCount: encodedPayloadByteCount
            )
        guard acceptsQueuedInboundOperations else {
            throw CancellationError()
        }
        let reservation: CrossNetworkFileTransferOperationReservationLedger.Reservation
        do {
            reservation = try inboundOperationReservationLedger.reserve(
                byteCount: retainedByteCount
            )
        } catch CrossNetworkFileTransferInboundAdmissionError
            .operationCapacityExceeded(let maximum) {
            throw InboundOperationQueueError.capacityExceeded(maximum: maximum)
        } catch CrossNetworkFileTransferInboundAdmissionError
            .retainedByteCapacityExceeded(let maximum) {
            throw InboundOperationQueueError.retainedByteCapacityExceeded(
                maximum: maximum
            )
        }
        queuedInboundOperationsByTransferID[message.transferId, default: []].append(
            QueuedInboundOperation(
                message: message,
                reservation: reservation,
                sessionID: sessionID,
                endpointDescription: endpointDescription,
                keys: keys,
                sendMessage: sendMessage,
                failSenderWaiters: failSenderWaiters,
                resumeSenderWaiter: resumeSenderWaiter,
                onFatalError: onFatalError
            )
        )
        startInboundOperationWorkersIfPossible(preferredTransferID: message.transferId)
    }

    private var maximumActiveInboundOperationLanes: Int {
        Self.activeInboundOperationLaneLimit(
            sessionLimit: maxConcurrentInboundTransfers,
            globalLimit: maxGlobalConcurrentInboundTransfers
        )
    }

    static func activeInboundOperationLaneLimit(
        sessionLimit: Int,
        globalLimit: Int
    ) -> Int {
        min(sessionLimit, globalLimit, 32)
    }

    /// Runs one FIFO lane per transfer so approval or fsync for transfer A
    /// cannot starve chunks and acknowledgements for transfer B. The global
    /// lane limit and queue capacity bound task and memory growth under attack.
    private func startInboundOperationWorkersIfPossible(preferredTransferID: String? = nil) {
        guard acceptsQueuedInboundOperations else { return }

        if let preferredTransferID {
            startInboundOperationWorkerIfPossible(for: preferredTransferID)
        }
        while inboundOperationWorkers.count < maximumActiveInboundOperationLanes,
              let transferID = queuedInboundOperationsByTransferID.keys.first(where: {
                  inboundOperationWorkers[$0] == nil
              }) {
            startInboundOperationWorkerIfPossible(for: transferID)
        }
    }

    private func startInboundOperationWorkerIfPossible(for transferID: String) {
        guard acceptsQueuedInboundOperations,
              inboundOperationWorkers[transferID] == nil,
              queuedInboundOperationsByTransferID[transferID]?.isEmpty == false,
              inboundOperationWorkers.count < maximumActiveInboundOperationLanes else {
            return
        }

        inboundOperationWorkers[transferID] = Task { @MainActor [weak self] in
            guard let self else { return }
            var encounteredFatalError = false
            while !Task.isCancelled,
                  let operation = dequeueInboundOperation(for: transferID) {
                var operationError: Error?
                do {
                    try await handle(
                        operation.message,
                        sessionID: operation.sessionID,
                        endpointDescription: operation.endpointDescription,
                        keys: operation.keys,
                        sendMessage: operation.sendMessage,
                        failSenderWaiters: operation.failSenderWaiters,
                        resumeSenderWaiter: operation.resumeSenderWaiter
                    )
                } catch is CancellationError {
                    operationError = CancellationError()
                } catch {
                    operationError = error
                }
                guard releaseRetainedInboundOperationReservation(operation.reservation) else {
                    operation.onFatalError(
                        InboundOperationQueueError.accountingInvariantViolated
                    )
                    encounteredFatalError = true
                    break
                }
                if let operationError {
                    if operationError is CancellationError {
                        break
                    }
                    operation.onFatalError(operationError)
                    encounteredFatalError = true
                    break
                }
            }
            if encounteredFatalError {
                discardQueuedInboundOperations(for: transferID)
            }
            inboundOperationWorkers.removeValue(forKey: transferID)
            startInboundOperationWorkersIfPossible()
        }
    }

    private func dequeueInboundOperation(for transferID: String) -> QueuedInboundOperation? {
        guard var operations = queuedInboundOperationsByTransferID[transferID],
              !operations.isEmpty else {
            queuedInboundOperationsByTransferID.removeValue(forKey: transferID)
            return nil
        }
        let operation = operations.removeFirst()
        if operations.isEmpty {
            queuedInboundOperationsByTransferID.removeValue(forKey: transferID)
        } else {
            queuedInboundOperationsByTransferID[transferID] = operations
        }
        return operation
    }

    private func discardQueuedInboundOperations(for transferID: String) {
        guard let operations = queuedInboundOperationsByTransferID.removeValue(forKey: transferID) else {
            return
        }
        for operation in operations {
            _ = releaseRetainedInboundOperationReservation(operation.reservation)
        }
    }

    @discardableResult
    private func releaseRetainedInboundOperationReservation(
        _ reservation: CrossNetworkFileTransferOperationReservationLedger.Reservation
    ) -> Bool {
        guard inboundOperationReservationLedger.release(reservation) else {
            acceptsQueuedInboundOperations = false
            logger.fault(
                "WebRTC inbound file-transfer retained-byte accounting invariant failed"
            )
            return false
        }
        return true
    }

    func handle(
        _ message: CrossNetworkFileTransferMessage,
        sessionID: String,
        endpointDescription: String,
        keys: SessionKeys,
        sendMessage: @escaping SendMessage,
        failSenderWaiters: FailSenderWaiters,
        resumeSenderWaiter: ResumeSenderWaiter
    ) async throws {
        guard keys.sessionId == sessionID else {
            try await sendMessage(
                CrossNetworkFileTransferMessage(
                    op: .error,
                    transferId: message.transferId,
                    message: "file transfer session binding mismatch"
                ),
                "tx/webrtc-ft-error"
            )
            return
        }
        if let validationError = WebRTCInboundFileTransferSupport.validateTransferId(
            message.transferId
        ) {
            switch message.op {
            case .metadata, .chunk, .complete, .cancel:
                try await sendMessage(
                    CrossNetworkFileTransferMessage(
                        op: .error,
                        transferId: message.transferId,
                        message: validationError
                    ),
                    "tx/webrtc-ft-error"
                )
            case .error, .metadataAck, .chunkAck, .completeAck:
                break
            }
            return
        }
        switch message.op {
        case .metadata:
            try await handleMetadata(
                message,
                sessionID: sessionID,
                endpointDescription: endpointDescription,
                sendMessage: sendMessage
            )
        case .chunk:
            try await handleChunk(
                message,
                sessionID: sessionID,
                keys: keys,
                sendMessage: sendMessage
            )
        case .complete:
            if try await replayTerminalReceiptIfAvailable(
                for: message,
                sessionID: sessionID,
                sendMessage: sendMessage
            ) {
                return
            }
            try await handleComplete(
                message,
                sessionID: sessionID,
                keys: keys,
                sendMessage: sendMessage
            )
        case .cancel:
            try await handleCancel(message, sessionID: sessionID, sendMessage: sendMessage)
        case .error:
            failSenderWaiters(
                message.transferId,
                WebRTCInboundFileTransferSupport.normalizedRemoteStatusMessage(
                    message.message,
                    fallback: "remote rejected file transfer"
                )
            )
        case .metadataAck, .chunkAck, .completeAck:
            resumeSenderWaiter(message)
        }
    }

    private func handleMetadata(
        _ message: CrossNetworkFileTransferMessage,
        sessionID: String,
        endpointDescription: String,
        sendMessage: @escaping SendMessage
    ) async throws {
        let expectedLifecycleToken = lifecycleToken
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

        let finalURL = baseDirectory.appendingPathComponent(fileName, isDirectory: false)

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
        guard let senderAuthority = normalizedSenderAuthority(for: sessionID) else {
            try await sendMessage(
                CrossNetworkFileTransferMessage(
                    op: .error,
                    transferId: message.transferId,
                    message: "authenticated sender authority unavailable"
                ),
                "tx/webrtc-ft-error"
            )
            return
        }
        guard senderId.caseInsensitiveCompare(senderAuthority.deviceId) == .orderedSame else {
            try await sendMessage(
                CrossNetworkFileTransferMessage(
                    op: .error,
                    transferId: message.transferId,
                    message: "sender identity does not match authenticated session"
                ),
                "tx/webrtc-ft-error"
            )
            return
        }
        if let claimedName = message.senderDeviceName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !claimedName.isEmpty,
           claimedName.caseInsensitiveCompare(senderAuthority.deviceName) != .orderedSame {
            try await sendMessage(
                CrossNetworkFileTransferMessage(
                    op: .error,
                    transferId: message.transferId,
                    message: "sender name does not match authenticated session"
                ),
                "tx/webrtc-ft-error"
            )
            return
        }
        let authenticatedSenderID = senderAuthority.deviceId
        let senderName = senderAuthority.deviceName
        let metadataBinding = WebRTCInboundFileTransferMetadataBinding(
            version: message.version,
            senderDeviceId: authenticatedSenderID,
            senderDeviceName: senderName,
            fileName: fileName,
            fileSize: fileSize,
            chunkSize: chunkSize,
            totalChunks: totalChunks,
            mimeType: message.mimeType,
            encryption: message.encryption,
            batchId: message.batchId,
            batchIndex: message.batchIndex,
            batchTotal: message.batchTotal,
            relativePath: message.relativePath
        )

        if let receipt = terminalReceipts.receipt(
            sessionID: sessionID,
            transferID: message.transferId,
            now: now()
        ) {
            guard receipt.metadataBinding == metadataBinding else {
                try await sendMetadataConflict(for: message.transferId, sendMessage: sendMessage)
                return
            }
            _ = await sendCachedTerminalResponse(
                receipt.response,
                label: receipt.label,
                sendMessage: sendMessage
            )
            return
        }

        if let active = transfers[message.transferId] {
            guard active.sessionID == sessionID, active.metadataBinding == metadataBinding else {
                try await sendMetadataConflict(for: message.transferId, sendMessage: sendMessage)
                return
            }
            try await sendMessage(
                CrossNetworkFileTransferMessage(op: .metadataAck, transferId: message.transferId),
                "tx/webrtc-ft-metaAck"
            )
            return
        }

        if let pending = pendingAdmissions[message.transferId] {
            guard pending.sessionID == sessionID, pending.metadataBinding == metadataBinding else {
                try await sendMetadataConflict(for: message.transferId, sendMessage: sendMessage)
                return
            }
            try await sendMessage(
                CrossNetworkFileTransferMessage(
                    op: .error,
                    transferId: message.transferId,
                    message: "Inbound file transfer approval pending"
                ),
                "tx/webrtc-ft-error"
            )
            return
        }

        guard transfers.count + pendingAdmissions.count < maxConcurrentInboundTransfers else {
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

        let admissionToken = UUID()
        guard admissionLedger.reserve(admissionToken, globalLimit: maxGlobalConcurrentInboundTransfers) else {
            try await sendMessage(
                CrossNetworkFileTransferMessage(
                    op: .error,
                    transferId: message.transferId,
                    message: "Global inbound file transfer limit reached"
                ),
                "tx/webrtc-ft-error"
            )
            return
        }
        pendingAdmissions[message.transferId] = PendingAdmission(
            token: admissionToken,
            sessionID: sessionID,
            metadataBinding: metadataBinding
        )
        var admissionCommitted = false
        defer {
            if !admissionCommitted {
                if pendingAdmissions[message.transferId]?.token == admissionToken {
                    pendingAdmissions.removeValue(forKey: message.transferId)
                }
                admissionLedger.release(admissionToken)
            }
        }

        let transportOperationID = UUID()
        guard let transportOperationToken = FileTransferManager.shared.beginExternalTransportOperation(
            cancellationHandler: { [weak self] in
                self?.cancelledTransportOperationIDs.insert(transportOperationID)
            }
        ) else {
            try await sendMessage(
                CrossNetworkFileTransferMessage(
                    op: .error,
                    transferId: message.transferId,
                    message: "Inbound file-transfer lifecycle is stopping"
                ),
                "tx/webrtc-ft-error"
            )
            return
        }
        defer {
            cancelledTransportOperationIDs.remove(transportOperationID)
            FileTransferManager.shared.endExternalTransportOperation(
                transportOperationToken
            )
        }

        let approvalRequest = WebRTCInboundFileTransferApprovalRequest(
            transferId: message.transferId,
            fileName: fileName,
            fileSize: fileSize,
            chunkSize: chunkSize,
            totalChunks: totalChunks,
            senderDeviceId: authenticatedSenderID,
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
        try Task.checkCancellation()
        guard !cancelledTransportOperationIDs.contains(transportOperationID),
              lifecycleToken == expectedLifecycleToken,
              pendingAdmissions[message.transferId]?.token == admissionToken,
              normalizedSenderAuthority(for: sessionID) == senderAuthority else {
            return
        }

        let tempURL = baseDirectory.appendingPathComponent(".skybridge-\(message.transferId).partial")
        let ioHandle: InboundFileTransferIOHandle
        do {
            ioHandle = try await ioActor.createTemporaryFile(
                at: tempURL,
                declaredFileSize: fileSize
            )
        } catch is CancellationError {
            return
        } catch {
            logger.error(
                "WebRTC inbound partial creation failed: \(error.localizedDescription, privacy: .public)"
            )
            let publicMessage: String
            switch error as? InboundFileTransferIOError {
            case .capacityExceeded:
                publicMessage = "Too many concurrent inbound file transfers"
            case .temporaryFileAlreadyExists:
                publicMessage = "Partial file already exists"
            default:
                publicMessage = "Partial file unavailable"
            }
            try await sendMessage(
                CrossNetworkFileTransferMessage(
                    op: .error,
                    transferId: message.transferId,
                    message: publicMessage
                ),
                "tx/webrtc-ft-error"
            )
            return
        }

        guard !Task.isCancelled,
              !cancelledTransportOperationIDs.contains(transportOperationID),
              lifecycleToken == expectedLifecycleToken,
              pendingAdmissions[message.transferId]?.token == admissionToken,
              normalizedSenderAuthority(for: sessionID) == senderAuthority else {
            do {
                try await ioActor.discardUncommittedFile(ioHandle)
            } catch {
                logger.error(
                    "WebRTC stale admission cleanup failed: \(error.localizedDescription, privacy: .public)"
                )
            }
            return
        }

        guard let presentationToken = FileTransferManager.shared.beginExternalInboundTransfer(
            transferId: message.transferId,
            fileName: fileName,
            fileSize: fileSize,
            fromDeviceId: authenticatedSenderID,
            fromDeviceName: senderName,
            cancellationHandler: { [weak self] in
                self?.requestCancelStoredTransfer(
                    transferID: message.transferId,
                    stateToken: admissionToken,
                    sendMessage: sendMessage
                )
            }
        ) else {
            do {
                try await ioActor.discardUncommittedFile(ioHandle)
            } catch {
                logger.error(
                    "WebRTC rejected-presentation cleanup failed: \(error.localizedDescription, privacy: .public)"
                )
            }
            try await sendMessage(
                CrossNetworkFileTransferMessage(
                    op: .error,
                    transferId: message.transferId,
                    message: "Inbound file transfer identifier is already active"
                ),
                "tx/webrtc-ft-error"
            )
            return
        }

        transfers[message.transferId] = WebRTCInboundFileTransferState(
            stateToken: admissionToken,
            presentationToken: presentationToken,
            lifecycleToken: expectedLifecycleToken,
            sessionID: sessionID,
            transferId: message.transferId,
            metadataBinding: metadataBinding,
            fileName: fileName,
            fileSize: fileSize,
            chunkSize: chunkSize,
            totalChunks: totalChunks,
            senderDeviceId: authenticatedSenderID,
            senderDeviceName: senderName,
            tempURL: tempURL,
            finalURL: finalURL,
            ioHandle: ioHandle,
            revision: 0,
            receivedBytes: 0
        )
        if pendingAdmissions[message.transferId]?.token == admissionToken {
            pendingAdmissions.removeValue(forKey: message.transferId)
        }
        admissionCommitted = true

        scheduleIdleTimeout(transferId: message.transferId, sendMessage: sendMessage)

        try await sendMessage(
            CrossNetworkFileTransferMessage(op: .metadataAck, transferId: message.transferId),
            "tx/webrtc-ft-metaAck"
        )
    }

    private func handleChunk(
        _ message: CrossNetworkFileTransferMessage,
        sessionID: String,
        keys: SessionKeys,
        sendMessage: @escaping SendMessage
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
        guard state.sessionID == sessionID else {
            try await sendMetadataConflict(for: message.transferId, sendMessage: sendMessage)
            return
        }
        guard !state.isFinalizing else { return }
        guard !chunkOperationsInFlight.contains(message.transferId) else {
            try await sendMessage(
                CrossNetworkFileTransferMessage(
                    op: .error,
                    transferId: message.transferId,
                    chunkIndex: message.chunkIndex,
                    message: "chunk operation already in progress"
                ),
                "tx/webrtc-ft-error"
            )
            return
        }
        chunkOperationsInFlight.insert(message.transferId)
        defer { chunkOperationsInFlight.remove(message.transferId) }

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

        guard isAuthorizedCurrentState(state) else {
            await terminateStoredTransfer(
                state,
                publicMessage: "authenticated sender authority changed",
                uiMessage: "Authenticated sender authority changed",
                sendMessage: sendMessage
            )
            return
        }

        let isDuplicate = state.chunkHashes[index] != nil
        let actualHash: Data
        do {
            if isDuplicate {
                actualHash = try await ioActor.digest(
                    data,
                    expectedSHA256: message.chunkSha256
                )
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
                actualHash = try await ioActor.write(
                    data,
                    atOffset: UInt64(offset),
                    using: state.ioHandle,
                    expectedSHA256: message.chunkSha256
                )
            }
        } catch InboundFileTransferIOError.dataDigestMismatch {
            guard isAuthorizedCurrentState(state) else { return }
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
        } catch is CancellationError {
            if hasSameStoredState(state) {
                await terminateStoredTransfer(
                    state,
                    publicMessage: "Write cancelled",
                    uiMessage: "Inbound file write cancelled",
                    sendMessage: sendMessage
                )
            }
            return
        } catch {
            logger.error(
                "WebRTC inbound file write failed: \(error.localizedDescription, privacy: .public)"
            )
            if let current = storedStateSharingIOHandle(with: state) {
                await terminateStoredTransfer(
                    current,
                    publicMessage: "Write failed",
                    uiMessage: "Write failed: \(error.localizedDescription)",
                    sendMessage: sendMessage
                )
            } else {
                await discardStaleIO(for: state, context: "write failure")
            }
            return
        }

        guard isAuthorizedCurrentState(state) else {
            if !isDuplicate, let current = storedStateSharingIOHandle(with: state) {
                await terminateStoredTransfer(
                    current,
                    publicMessage: "Concurrent inbound transfer mutation",
                    uiMessage: "Concurrent inbound transfer mutation",
                    sendMessage: sendMessage
                )
            } else if !isDuplicate {
                await discardStaleIO(for: state, context: "stale write completion")
            }
            return
        }

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
            state.chunkHashes[index] = actualHash
            state.receivedChunkSizes[index] = rawSize
            state.receivedBytes += Int64(rawSize)
            state.revision &+= 1
        }

        transfers[message.transferId] = state

        if state.completeRequestedAt != nil && state.receivedBytes >= state.fileSize {
            state.isFinalizing = true
            state.revision &+= 1
            transfers[state.transferId] = state
            completeTimers.removeValue(forKey: state.transferId)?.cancel()
            idleTimers.removeValue(forKey: state.transferId)?.cancel()
            await finalizeTransfer(state, keys: keys, sendMessage: sendMessage)
            return
        }

        scheduleIdleTimeout(transferId: state.transferId, sendMessage: sendMessage)

        FileTransferManager.shared.updateExternalInboundProgress(
            token: state.presentationToken,
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
        sessionID: String,
        keys: SessionKeys,
        sendMessage: @escaping SendMessage
    ) async throws {
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
        guard state.sessionID == sessionID else {
            try await sendMetadataConflict(for: message.transferId, sendMessage: sendMessage)
            return
        }
        let completionBinding = WebRTCInboundFileTransferCompletionBinding(message: message)
        if let existingBinding = state.completionBinding, existingBinding != completionBinding {
            try await sendCompletionConflict(for: message.transferId, sendMessage: sendMessage)
            return
        }
        // A duplicate terminal request must not mutate the revision while the
        // original finalizer is suspended in close/hash/commit I/O.
        guard !state.isFinalizing else { return }
        guard isAuthorizedCurrentState(state) else {
            await terminateStoredTransfer(
                state,
                publicMessage: "authenticated sender authority changed",
                uiMessage: "Authenticated sender authority changed",
                sendMessage: sendMessage
            )
            return
        }
        state.completionBinding = completionBinding

        if state.expectedFileSha256 == nil { state.expectedFileSha256 = message.fileSha256 }
        if state.expectedMerkleRoot == nil { state.expectedMerkleRoot = message.merkleRoot }
        if state.expectedMerkleSig == nil { state.expectedMerkleSig = message.merkleRootSignature }
        if state.expectedMerkleSigAlg == nil { state.expectedMerkleSigAlg = message.merkleRootSignatureAlg }
        if state.completeRequestedAt == nil { state.completeRequestedAt = Date() }
        state.revision &+= 1
        transfers[state.transferId] = state

        guard WebRTCInboundFileTransferSupport.hasRequiredIntegrityProof(state) else {
            await terminateStoredTransfer(
                state,
                publicMessage: "missing integrity proof",
                uiMessage: "Missing integrity proof",
                sendMessage: sendMessage
            )
            return
        }

        if state.receivedBytes < state.fileSize {
            let missingChunks = (0..<state.totalChunks).filter { state.chunkHashes[$0] == nil }
            scheduleIdleTimeout(transferId: state.transferId, sendMessage: sendMessage)
            scheduleIncompleteTimeoutIfNeeded(
                transferId: state.transferId,
                sendMessage: sendMessage
            )
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
            return
        }

        guard !state.isFinalizing else { return }
        state.isFinalizing = true
        state.revision &+= 1
        transfers[state.transferId] = state
        completeTimers.removeValue(forKey: state.transferId)?.cancel()
        idleTimers.removeValue(forKey: state.transferId)?.cancel()
        await finalizeTransfer(state, keys: keys, sendMessage: sendMessage)
    }

    private func handleCancel(
        _ message: CrossNetworkFileTransferMessage,
        sessionID: String,
        sendMessage: @escaping SendMessage
    ) async throws {
        guard let state = transfers[message.transferId] else { return }
        guard state.sessionID == sessionID else {
            try await sendMetadataConflict(
                for: message.transferId,
                sendMessage: sendMessage
            )
            return
        }
        guard isAuthorizedCurrentState(state) else {
            await terminateStoredTransfer(
                state,
                publicMessage: "authenticated sender authority changed",
                uiMessage: "Authenticated sender authority changed",
                sendMessage: sendMessage
            )
            return
        }
        // Once terminal close/hash/commit starts, it owns the outcome. A late or
        // malicious cancel cannot convert a durable save into failure.
        guard !state.isFinalizing else { return }

        removeTransfer(state.transferId)
        var terminalMessage = "Cancelled by sender"
        do {
            try await ioActor.discardUncommittedFile(state.ioHandle)
        } catch {
            terminalMessage = FileTransferError.partialFileCleanupFailed.localizedDescription
            logger.error(
                "WebRTC cancelled-transfer cleanup failed: \(error.localizedDescription, privacy: .public)"
            )
        }
        FileTransferManager.shared.failExternalTransfer(
            token: state.presentationToken,
            errorMessage: terminalMessage
        )
    }

    private func scheduleIncompleteTimeoutIfNeeded(
        transferId: String,
        sendMessage: @escaping SendMessage
    ) {
        guard completeTimers[transferId] == nil else { return }
        guard let expected = transfers[transferId] else { return }
        completeTimers[transferId] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.completeTimers.removeValue(forKey: transferId)
            guard let current = self.transfers[transferId],
                  current.stateToken == expected.stateToken,
                  current.lifecycleToken == expected.lifecycleToken,
                  !current.isFinalizing,
                  current.receivedBytes < current.fileSize else {
                return
            }
            await self.terminateStoredTransfer(
                current,
                publicMessage: "Incomplete file (timeout)",
                uiMessage: "Incomplete file (timeout): \(current.receivedBytes)/\(current.fileSize)",
                sendMessage: sendMessage
            )
        }
    }

    private func scheduleIdleTimeout(
        transferId: String,
        sendMessage: @escaping SendMessage
    ) {
        let timeout = transferIdleTimeout
        guard let expected = transfers[transferId] else { return }
        idleTimers[transferId]?.cancel()
        idleTimers[transferId] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard let self,
                  let current = self.transfers[transferId],
                  current.stateToken == expected.stateToken,
                  current.lifecycleToken == expected.lifecycleToken,
                  current.revision == expected.revision else {
                return
            }
            self.idleTimers.removeValue(forKey: current.transferId)
            await self.terminateStoredTransfer(
                current,
                publicMessage: "Inbound file transfer idle timeout",
                uiMessage: "Inbound file transfer idle timeout",
                sendMessage: sendMessage
            )
        }
    }

    private func finalizeTransfer(
        _ state: WebRTCInboundFileTransferState,
        keys: SessionKeys,
        sendMessage: SendMessage
    ) async {
        precondition(state.isFinalizing, "Inbound finalization requires a linearized finalizing state")
        let actualFileSHA256: Data
        do {
            actualFileSHA256 = try await ioActor.closeAndDigest(using: state.ioHandle)
        } catch is CancellationError {
            if let current = storedStateSharingIOHandle(with: state) {
                await terminateStoredTransfer(
                    current,
                    publicMessage: "File processing cancelled",
                    uiMessage: "File processing cancelled",
                    sendMessage: sendMessage
                )
            }
            return
        } catch {
            logger.error(
                "WebRTC inbound close/hash failed: \(error.localizedDescription, privacy: .public)"
            )
            let publicMessage: String
            if case InboundFileTransferIOError.closeFailed = error {
                publicMessage = WebRTCInboundFileTransferIntegrityFailure.fileHandleCloseFailed.message
            } else {
                publicMessage = WebRTCInboundFileTransferIntegrityFailure.fileSHA256Unavailable.message
            }
            if let current = storedStateSharingIOHandle(with: state) {
                await terminateStoredTransfer(
                    current,
                    publicMessage: publicMessage,
                    uiMessage: "\(publicMessage): \(error.localizedDescription)",
                    sendMessage: sendMessage
                )
            } else {
                await discardStaleIO(for: state, context: "close/hash failure")
            }
            return
        }

        guard hasSameStoredState(state) else {
            if let current = storedStateSharingIOHandle(with: state) {
                await terminateStoredTransfer(
                    current,
                    publicMessage: "Concurrent inbound transfer mutation",
                    uiMessage: "Concurrent inbound transfer mutation",
                    sendMessage: sendMessage
                )
            } else {
                await discardStaleIO(for: state, context: "stale hash completion")
            }
            return
        }

        if let failure = WebRTCInboundFileTransferSupport.integrityFailure(
            state: state,
            receiveKey: keys.receiveKey,
            actualFileSha256: actualFileSHA256
        ) {
            await terminateStoredTransfer(
                state,
                publicMessage: failure.message,
                uiMessage: failure.message,
                sendMessage: sendMessage
            )
            return
        }

        let savedURL: URL
        do {
            savedURL = try await ioActor.commit(
                using: state.ioHandle,
                destinationDirectory: state.finalURL.deletingLastPathComponent(),
                fileName: state.fileName
            )
        } catch is CancellationError {
            if let current = storedStateSharingIOHandle(with: state) {
                await terminateStoredTransfer(
                    current,
                    publicMessage: "Save cancelled",
                    uiMessage: "Save cancelled",
                    sendMessage: sendMessage
                )
            }
            return
        } catch {
            logger.error(
                "WebRTC inbound commit failed: \(error.localizedDescription, privacy: .public)"
            )
            if let current = storedStateSharingIOHandle(with: state) {
                await terminateStoredTransfer(
                    current,
                    publicMessage: "Save failed",
                    uiMessage: "Save failed: \(error.localizedDescription)",
                    sendMessage: sendMessage
                )
            } else {
                await discardStaleIO(for: state, context: "commit failure")
            }
            return
        }

        guard hasSameStoredState(state) else {
            if let current = storedStateSharingIOHandle(with: state) {
                await terminateStoredTransfer(
                    current,
                    publicMessage: "Concurrent inbound transfer mutation",
                    uiMessage: "Concurrent inbound transfer mutation",
                    sendMessage: sendMessage
                )
            } else {
                await discardStaleIO(for: state, context: "stale commit completion")
            }
            return
        }

        let response = CrossNetworkFileTransferMessage(
            op: .completeAck,
            transferId: state.transferId,
            receivedBytes: state.receivedBytes,
            fileSha256: actualFileSHA256
        )
        if lifecycleToken == state.lifecycleToken,
           senderAuthorityMatches(state) {
            recordTerminalReceiptAndRemoveActive(
                state: state,
                response: response,
                label: "tx/webrtc-ft-completeAck"
            )
        } else {
            removeTransfer(state.transferId)
        }

        let receiptDeliveryStatus: FileTransferReceiptDeliveryStatus
        if lifecycleToken == state.lifecycleToken,
           senderAuthorityMatches(state) {
            receiptDeliveryStatus = await sendCachedTerminalResponse(
                response,
                label: "tx/webrtc-ft-completeAck",
                sendMessage: sendMessage
            )
        } else {
            receiptDeliveryStatus = .unknown
        }

        var operationalWarning: String?
        do {
            try await ioActor.releaseCommittedFile(using: state.ioHandle)
        } catch {
            operationalWarning = FileTransferError.committedFileReleaseFailed.localizedDescription
            logger.fault(
                "WebRTC committed-file actor state release failed: \(error.localizedDescription, privacy: .public)"
            )
        }

        FileTransferManager.shared.completeExternalInboundTransfer(
            token: state.presentationToken,
            savedTo: savedURL,
            receiptDeliveryStatus: receiptDeliveryStatus,
            operationalWarning: operationalWarning
        )
    }

    private func terminateStoredTransfer(
        _ state: WebRTCInboundFileTransferState,
        publicMessage: String,
        uiMessage: String,
        sendMessage: SendMessage
    ) async {
        guard hasSameStoredState(state) else {
            await discardStaleIO(for: state, context: "terminal state mismatch")
            return
        }

        let response = CrossNetworkFileTransferMessage(
            op: .error,
            transferId: state.transferId,
            message: publicMessage
        )
        if state.completionBinding != nil {
            recordTerminalReceiptAndRemoveActive(
                state: state,
                response: response,
                label: "tx/webrtc-ft-error"
            )
        } else {
            removeTransfer(state.transferId)
        }

        var terminalMessage = uiMessage
        do {
            try await ioActor.discardUncommittedFile(state.ioHandle)
        } catch {
            terminalMessage = FileTransferError.partialFileCleanupFailed.localizedDescription
            logger.error(
                "WebRTC terminal partial cleanup failed: \(error.localizedDescription, privacy: .public)"
            )
        }
        FileTransferManager.shared.failExternalTransfer(
            token: state.presentationToken,
            errorMessage: terminalMessage
        )
        guard lifecycleToken == state.lifecycleToken,
              senderAuthorityMatches(state) else {
            return
        }
        _ = await sendCachedTerminalResponse(
            response,
            label: "tx/webrtc-ft-error",
            sendMessage: sendMessage
        )
    }

    private func requestCancelStoredTransfer(
        transferID: String,
        stateToken: UUID,
        sendMessage: @escaping SendMessage
    ) {
        guard let state = transfers[transferID],
              state.stateToken == stateToken else {
            // The state is already post-commit or was terminally cleaned up.
            return
        }
        // Once terminal close/hash/commit starts off-main, a late UI cancellation
        // must not turn a durable save into a reported failure or delete it.
        guard !state.isFinalizing else { return }

        removeTransfer(state.transferId)
        let expectedLifecycleToken = state.lifecycleToken
        Task { @MainActor [self] in
            var uiMessage = "Cancelled by receiver"
            do {
                try await ioActor.discardUncommittedFile(state.ioHandle)
            } catch {
                uiMessage = FileTransferError.partialFileCleanupFailed.localizedDescription
                logger.error(
                    "WebRTC cancelled-transfer partial cleanup failed: \(error.localizedDescription, privacy: .public)"
                )
            }

            FileTransferManager.shared.failExternalTransfer(
                token: state.presentationToken,
                errorMessage: uiMessage
            )
            guard lifecycleToken == expectedLifecycleToken,
                  senderAuthorityMatches(state) else {
                return
            }
            _ = await sendCachedTerminalResponse(
                CrossNetworkFileTransferMessage(
                    op: .error,
                    transferId: state.transferId,
                    message: "Cancelled by receiver"
                ),
                label: "tx/webrtc-ft-error",
                sendMessage: sendMessage
            )
        }
    }

    private func hasSameStoredState(_ expected: WebRTCInboundFileTransferState) -> Bool {
        guard let current = transfers[expected.transferId] else { return false }
        return current.stateToken == expected.stateToken
            && current.lifecycleToken == expected.lifecycleToken
            && current.sessionID == expected.sessionID
            && current.ioHandle == expected.ioHandle
            && current.revision == expected.revision
    }

    private func storedStateSharingIOHandle(
        with expected: WebRTCInboundFileTransferState
    ) -> WebRTCInboundFileTransferState? {
        guard let current = transfers[expected.transferId],
              current.stateToken == expected.stateToken,
              current.ioHandle == expected.ioHandle else {
            return nil
        }
        return current
    }

    private func senderAuthorityMatches(_ state: WebRTCInboundFileTransferState) -> Bool {
        normalizedSenderAuthority(for: state.sessionID) == WebRTCInboundFileTransferSenderAuthority(
            deviceId: state.senderDeviceId,
            deviceName: state.senderDeviceName ?? state.senderDeviceId
        )
    }

    private func isAuthorizedCurrentState(_ state: WebRTCInboundFileTransferState) -> Bool {
        lifecycleToken == state.lifecycleToken
            && hasSameStoredState(state)
            && senderAuthorityMatches(state)
    }

    private func discardStaleIO(
        for state: WebRTCInboundFileTransferState,
        context: String
    ) async {
        do {
            try await ioActor.discardUncommittedFile(state.ioHandle)
        } catch {
            logger.error(
                "WebRTC stale I/O cleanup failed (\(context, privacy: .public)): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func recordTerminalReceiptAndRemoveActive(
        state: WebRTCInboundFileTransferState,
        response: CrossNetworkFileTransferMessage,
        label: String
    ) {
        guard let completionBinding = state.completionBinding else {
            preconditionFailure("Terminal file-transfer outcome requires a completion binding")
        }
        terminalReceipts.store(
            sessionID: state.sessionID,
            transferID: state.transferId,
            metadataBinding: state.metadataBinding,
            completionBinding: completionBinding,
            response: response,
            label: label,
            now: now()
        )
        removeTransfer(state.transferId)
    }

    private func replayTerminalReceiptIfAvailable(
        for message: CrossNetworkFileTransferMessage,
        sessionID: String,
        sendMessage: SendMessage
    ) async throws -> Bool {
        guard let receipt = terminalReceipts.receipt(
            sessionID: sessionID,
            transferID: message.transferId,
            now: now()
        ) else {
            return false
        }
        guard receipt.completionBinding == WebRTCInboundFileTransferCompletionBinding(message: message) else {
            try await sendCompletionConflict(for: message.transferId, sendMessage: sendMessage)
            return true
        }
        _ = await sendCachedTerminalResponse(
            receipt.response,
            label: receipt.label,
            sendMessage: sendMessage
        )
        return true
    }

    @discardableResult
    private func sendCachedTerminalResponse(
        _ response: CrossNetworkFileTransferMessage,
        label: String,
        sendMessage: SendMessage
    ) async -> FileTransferReceiptDeliveryStatus {
        do {
            try await sendMessage(response, label)
            return .delivered
        } catch {
            logger.error(
                "WebRTC terminal receipt send failed; cached response remains replayable: \(error.localizedDescription, privacy: .public)"
            )
            return .unknown
        }
    }

    private func sendMetadataConflict(
        for transferID: String,
        sendMessage: SendMessage
    ) async throws {
        try await sendMessage(
            CrossNetworkFileTransferMessage(
                op: .error,
                transferId: transferID,
                message: "transferId metadata conflict"
            ),
            "tx/webrtc-ft-error"
        )
    }

    private func normalizedSenderAuthority(
        for sessionID: String
    ) -> WebRTCInboundFileTransferSenderAuthority? {
        guard let rawAuthority = senderAuthorityProvider(sessionID),
              let deviceID = WebRTCInboundFileTransferSupport.requiredSenderDeviceId(rawAuthority.deviceId) else {
            return nil
        }
        let deviceName = rawAuthority.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        return WebRTCInboundFileTransferSenderAuthority(
            deviceId: deviceID,
            deviceName: deviceName.isEmpty ? deviceID : deviceName
        )
    }

    private func sendCompletionConflict(
        for transferID: String,
        sendMessage: SendMessage
    ) async throws {
        try await sendMessage(
            CrossNetworkFileTransferMessage(
                op: .error,
                transferId: transferID,
                message: "transferId completion conflict"
            ),
            "tx/webrtc-ft-error"
        )
    }

    private func removeTransfer(_ transferId: String) {
        if let state = transfers.removeValue(forKey: transferId) {
            admissionLedger.release(state.stateToken)
        }
        completeTimers[transferId]?.cancel()
        completeTimers.removeValue(forKey: transferId)
        idleTimers[transferId]?.cancel()
        idleTimers.removeValue(forKey: transferId)
    }
}
