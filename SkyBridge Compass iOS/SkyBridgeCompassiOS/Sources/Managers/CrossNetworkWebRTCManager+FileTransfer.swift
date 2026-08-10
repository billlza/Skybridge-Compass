import Foundation
import enum SkyBridgeProtocolCore.CrossNetworkFileTransferInboundAdmissionError
import enum SkyBridgeProtocolCore.CrossNetworkFileTransferInboundAdmissionPolicy
import struct SkyBridgeProtocolCore.CrossNetworkFileTransferOperationReservationLedger
import enum SkyBridgeProtocolCore.CrossNetworkFileTransferOp
import struct SkyBridgeProtocolCore.CrossNetworkFileTransferMessage
import enum SkyBridgeProtocolCore.InboundFileTransferIOError
import struct SkyBridgeProtocolCore.InboundFileTransferIOHandle

@available(iOS 17.0, *)
extension CrossNetworkWebRTCManager {
    struct InboundFileTransferProgressOwner: Sendable, Equatable {
        let stateToken: UUID
        let lifecycleToken: UUID
        let sessionID: String
        let revision: UInt64
    }

    enum InboundFileTransferProgressResumeDecision: Sendable, Equatable {
        case resume
        case discardStaleIO
    }

    enum InboundFileTransferProgressResumePolicy {
        nonisolated static func decision(
            expectedOwner: InboundFileTransferProgressOwner,
            currentOwner: InboundFileTransferProgressOwner?,
            activeLifecycleToken: UUID,
            activeSessionID: String?
        ) -> InboundFileTransferProgressResumeDecision {
            guard currentOwner == expectedOwner,
                  activeLifecycleToken == expectedOwner.lifecycleToken,
                  activeSessionID == expectedOwner.sessionID else {
                return .discardStaleIO
            }
            return .resume
        }
    }

    struct InboundFileTransferCleanupReport: Sendable, Equatable {
        let workerDeadlineExceededCount: Int
        let workerJoinCancelledCount: Int
        let partialFileDiscardFailureCount: Int

        var hasFailures: Bool {
            workerDeadlineExceededCount > 0
                || workerJoinCancelledCount > 0
                || partialFileDiscardFailureCount > 0
        }
    }

    struct FileTransferWaiterKey: Hashable, Sendable {
        let transferID: String
        let operation: String
        let chunkIndex: Int?

        init(
            transferID: String,
            operation: CrossNetworkFileTransferOp,
            chunkIndex: Int?
        ) {
            self.transferID = transferID
            self.operation = operation.rawValue
            self.chunkIndex = chunkIndex
        }
    }

    struct FileTransferWaiter {
        let token: UUID
        let owner: WebRTCFileTransferOperationOwner
        let continuation: CheckedContinuation<CrossNetworkFileTransferMessage, Error>
        let timeoutTask: Task<Void, Never>
        var sendTask: Task<Void, Error>?
    }

    struct InboundFileTransferState {
        let stateToken: UUID
        let presentationToken: FileTransferManager.ExternalTransferToken
        let operationOwner: WebRTCFileTransferOperationOwner
        let lifecycleToken: UUID
        let sessionID: String
        let transferId: String
        let metadataBinding: InboundFileTransferMetadataBinding
        let fileName: String
        let fileSize: Int64
        let chunkSize: Int
        let totalChunks: Int
        let senderDeviceId: String
        let senderDeviceName: String
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
        var completionBinding: InboundFileTransferCompletionBinding? = nil
        /// True only after all bytes are present and terminal close/hash/commit
        /// owns the outcome. An early complete request alone is not finalization.
        var isFinalizing = false
        var chunkHashes: [Int: Data] = [:]
        var receivedChunkSizes: [Int: Int] = [:]

        var progressOwner: InboundFileTransferProgressOwner {
            InboundFileTransferProgressOwner(
                stateToken: stateToken,
                lifecycleToken: lifecycleToken,
                sessionID: sessionID,
                revision: revision
            )
        }
    }

    struct InboundFileTransferPendingAdmission {
        let token: UUID
        let operationOwner: WebRTCFileTransferOperationOwner
        let sessionID: String
        let metadataBinding: InboundFileTransferMetadataBinding
    }

    struct QueuedInboundFileTransferOperation {
        let message: CrossNetworkFileTransferMessage
        let reservation: CrossNetworkFileTransferOperationReservationLedger.Reservation
        let owner: WebRTCFileTransferOperationOwner
        let lifecycleToken: UUID
    }
    nonisolated private static let inboundFileTransferWorkerTeardownTimeoutSeconds: TimeInterval = 2

    /// Invalidates every file-transfer operation synchronously so teardown can
    /// call it before its first suspension point. The later bounded cleanup
    /// owns joins and exact I/O disposal.
    func invalidateInboundFileTransferOperationsForTeardown() {
        inboundFileTransferLifecycleToken = UUID()
        acceptsQueuedInboundFileTransferOperations = false
        inboundFileTransferChunkOperationsInFlight.removeAll(keepingCapacity: false)
        let queuedOperations = queuedInboundFileTransferOperationsByTransferID.values
            .flatMap { $0 }
        queuedInboundFileTransferOperationsByTransferID.removeAll(keepingCapacity: false)
        for operation in queuedOperations {
            _ = releaseInboundFileTransferOperationReservation(operation.reservation)
        }
        for operationWorker in inboundFileTransferOperationWorkers.values {
            operationWorker.task.cancel()
        }
        for timer in inboundFileTransferCompleteTimers.values {
            timer.cancel()
        }
        inboundFileTransferCompleteTimers.removeAll()
        for timer in inboundFileTransferIdleTimers.values {
            timer.cancel()
        }
        inboundFileTransferIdleTimers.removeAll()
    }

    func cleanupInboundFileTransfers() async -> InboundFileTransferCleanupReport {
        invalidateInboundFileTransferOperationsForTeardown()
        let operationWorkers = Array(inboundFileTransferOperationWorkers)
        let workerOutcomes = await withTaskGroup(
            of: CrossNetworkCancelledTaskTeardownJoiner.Outcome.self,
            returning: [CrossNetworkCancelledTaskTeardownJoiner.Outcome].self
        ) { group in
            for (_, operationWorker) in operationWorkers {
                group.addTask {
                    await CrossNetworkCancelledTaskTeardownJoiner.joinCancelledTask(
                        operationWorker.task,
                        timeoutSeconds: Self.inboundFileTransferWorkerTeardownTimeoutSeconds
                    )
                }
            }
            var outcomes: [CrossNetworkCancelledTaskTeardownJoiner.Outcome] = []
            for await outcome in group {
                outcomes.append(outcome)
            }
            return outcomes
        }
        for (transferID, operationWorker) in operationWorkers {
            CrossNetworkExactOwnerDictionary.removeValue(
                from: &inboundFileTransferOperationWorkers,
                key: transferID,
                expectedOwner: operationWorker.owner,
                owner: \.owner
            )
        }
        let workerDeadlineExceededCount = workerOutcomes.reduce(into: 0) { count, outcome in
            if outcome == .quarantined(.deadlineExceeded) {
                count += 1
            }
        }
        let workerJoinCancelledCount = workerOutcomes.reduce(into: 0) { count, outcome in
            if outcome == .quarantined(.joinCancelled) {
                count += 1
            }
        }
        if workerDeadlineExceededCount > 0 || workerJoinCancelledCount > 0 {
            SkyBridgeLogger.shared.error(
                "⛔️ WebRTC inbound file-transfer workers quarantined: deadline_exceeded=\(workerDeadlineExceededCount) join_cancelled=\(workerJoinCancelledCount)"
            )
        }
        let statesToDiscard = inboundFileTransfers.values.filter { !$0.isFinalizing }
        for state in statesToDiscard {
            inboundFileTransfers.removeValue(forKey: state.transferId)
        }
        inboundFileTransferPendingAdmissions.removeAll()
        inboundFileTransferTerminalReceipts.removeAll()
        var partialFileDiscardFailureCount = 0
        for state in statesToDiscard {
            var terminalMessage = "WebRTC channel closed before transfer completion"
            do {
                try await inboundFileTransferIO.discardUncommittedFile(state.ioHandle)
            } catch {
                partialFileDiscardFailureCount += 1
                terminalMessage = FileTransferError.partialFileCleanupFailed.localizedDescription
                let diagnosticError = error as NSError
                SkyBridgeLogger.shared.warning(
                    "⚠️ WebRTC inbound channel-close cleanup failed: transfer=<redacted> error_domain=\(diagnosticError.domain) code=\(diagnosticError.code)"
                )
            }
            FileTransferManager.instance.completeExternalInboundTransfer(
                token: state.presentationToken,
                success: false,
                error: terminalMessage
            )
        }
        return InboundFileTransferCleanupReport(
            workerDeadlineExceededCount: workerDeadlineExceededCount,
            workerJoinCancelledCount: workerJoinCancelledCount,
            partialFileDiscardFailureCount: partialFileDiscardFailureCount
        )
    }

    /// Keeps potentially slow approval/hash/fsync work off the strictly ordered
    /// control receive loop while preserving FIFO ordering for inbound requests.
    func dispatchInboundFileTransferFromMac(
        _ message: CrossNetworkFileTransferMessage,
        sessionID: String,
        keys: SessionKeys,
        sessionObjectIdentifier: ObjectIdentifier,
        encodedPayloadByteCount: Int
    ) async {
        guard let activeSession = session,
              ObjectIdentifier(activeSession) == sessionObjectIdentifier,
              let operationOwner = currentWebRTCFileTransferOperationOwner(
                sessionID: sessionID,
                session: activeSession,
                keys: keys
              ) else { return }
        switch message.op {
        case .error, .metadataAck, .chunkAck, .completeAck:
            do {
                try CrossNetworkFileTransferInboundAdmissionPolicy
                    .validateInboundResponse(message)
            } catch {
                let diagnosticError = error as NSError
                SkyBridgeLogger.shared.error(
                    "WebRTC inbound file-transfer response admission failed: error_domain=\(diagnosticError.domain) code=\(diagnosticError.code)"
                )
                await failInboundFileTransferControlChannel(
                    "Invalid inbound file-transfer response",
                    owner: operationOwner,
                    origin: .controlReceiveLoop
                )
                return
            }
            await handleInboundFileTransferFromMac(
                message,
                owner: operationOwner,
                failureOrigin: .controlReceiveLoop
            )
        case .metadata, .chunk, .complete, .cancel:
            guard sessionKeys?.sessionId == sessionID else { return }
            if !acceptsQueuedInboundFileTransferOperations,
               inboundFileTransferOperationWorkers.isEmpty,
               inboundFileTransfers.isEmpty,
               inboundFileTransferPendingAdmissions.isEmpty,
               inboundFileTransferOperationReservationLedger.isEmpty {
                acceptsQueuedInboundFileTransferOperations = true
            }
            guard acceptsQueuedInboundFileTransferOperations else { return }
            let retainedByteCount: Int
            do {
                retainedByteCount = try CrossNetworkFileTransferInboundAdmissionPolicy
                    .retainedByteCharge(
                        for: message,
                        encodedPayloadByteCount: encodedPayloadByteCount
                    )
            } catch {
                let diagnosticError = error as NSError
                SkyBridgeLogger.shared.error(
                    "WebRTC inbound file-transfer request admission failed: error_domain=\(diagnosticError.domain) code=\(diagnosticError.code)"
                )
                await failInboundFileTransferControlChannel(
                    "Invalid inbound file-transfer request",
                    owner: operationOwner,
                    origin: .controlReceiveLoop
                )
                return
            }
            let reservation: CrossNetworkFileTransferOperationReservationLedger.Reservation
            do {
                reservation = try inboundFileTransferOperationReservationLedger.reserve(
                    byteCount: retainedByteCount
                )
            } catch CrossNetworkFileTransferInboundAdmissionError
                .operationCapacityExceeded(_) {
                SkyBridgeLogger.shared.error(
                    "WebRTC inbound file-transfer operation count capacity exceeded"
                )
                await failInboundFileTransferControlChannel(
                    "Inbound file-transfer operation count capacity exceeded",
                    owner: operationOwner,
                    origin: .controlReceiveLoop
                )
                return
            } catch CrossNetworkFileTransferInboundAdmissionError
                .retainedByteCapacityExceeded(_) {
                SkyBridgeLogger.shared.error(
                    "WebRTC inbound file-transfer retained-byte capacity exceeded"
                )
                await failInboundFileTransferControlChannel(
                    "Inbound file-transfer retained-byte capacity exceeded",
                    owner: operationOwner,
                    origin: .controlReceiveLoop
                )
                return
            } catch {
                let diagnosticError = error as NSError
                SkyBridgeLogger.shared.error(
                    "WebRTC inbound file-transfer reservation invariant failed: error_domain=\(diagnosticError.domain) code=\(diagnosticError.code)"
                )
                await failInboundFileTransferControlChannel(
                    "Inbound file-transfer operation accounting failed",
                    owner: operationOwner,
                    origin: .controlReceiveLoop
                )
                return
            }
            queuedInboundFileTransferOperationsByTransferID[message.transferId, default: []].append(
                QueuedInboundFileTransferOperation(
                    message: message,
                    reservation: reservation,
                    owner: operationOwner,
                    lifecycleToken: inboundFileTransferLifecycleToken
                )
            )
            startInboundFileTransferOperationWorkersIfPossible(
                preferredTransferID: message.transferId
            )
        }
    }

    /// Same-transfer requests remain ordered, while independent transfers use
    /// separate bounded lanes so a user approval cannot stall active chunks.
    private func startInboundFileTransferOperationWorkersIfPossible(
        preferredTransferID: String? = nil
    ) {
        guard acceptsQueuedInboundFileTransferOperations else { return }

        if let preferredTransferID {
            startInboundFileTransferOperationWorkerIfPossible(for: preferredTransferID)
        }
        while inboundFileTransferOperationWorkers.count
                < Self.maxConcurrentInboundWebRTCFileTransfersPerSession,
              let transferID = queuedInboundFileTransferOperationsByTransferID.keys.first(where: {
                  inboundFileTransferOperationWorkers[$0] == nil
              }) {
            startInboundFileTransferOperationWorkerIfPossible(for: transferID)
        }
    }

    private func startInboundFileTransferOperationWorkerIfPossible(for transferID: String) {
        guard acceptsQueuedInboundFileTransferOperations,
              inboundFileTransferOperationWorkers[transferID] == nil,
              queuedInboundFileTransferOperationsByTransferID[transferID]?.isEmpty == false,
              inboundFileTransferOperationWorkers.count
                < Self.maxConcurrentInboundWebRTCFileTransfersPerSession else {
            return
        }

        let owner = InboundFileTransferOperationWorker.Owner(
            token: UUID(),
            lifecycleToken: inboundFileTransferLifecycleToken
        )
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled,
                  let operation = dequeueInboundFileTransferOperation(for: transferID) {
                guard operation.lifecycleToken == inboundFileTransferLifecycleToken,
                      isCurrentWebRTCFileTransferOperationOwner(operation.owner) else {
                    _ = releaseInboundFileTransferOperationReservation(
                        operation.reservation
                    )
                    continue
                }
                await handleInboundFileTransferFromMac(
                    operation.message,
                    owner: operation.owner,
                    failureOrigin: .worker
                )
                guard releaseInboundFileTransferOperationReservation(
                    operation.reservation
                ) else {
                    guard isCurrentWebRTCFileTransferOperationOwner(operation.owner) else {
                        return
                    }
                    await failInboundFileTransferControlChannel(
                        "Inbound file-transfer operation accounting failed",
                        owner: operation.owner,
                        origin: .worker
                    )
                    return
                }
            }
            guard CrossNetworkExactOwnerDictionary.removeValue(
                from: &inboundFileTransferOperationWorkers,
                key: transferID,
                expectedOwner: owner,
                owner: \.owner
            ) != nil else {
                return
            }
            startInboundFileTransferOperationWorkersIfPossible()
        }
        inboundFileTransferOperationWorkers[transferID] = InboundFileTransferOperationWorker(
            owner: owner,
            task: task
        )
    }

    private func dequeueInboundFileTransferOperation(
        for transferID: String
    ) -> QueuedInboundFileTransferOperation? {
        guard var operations = queuedInboundFileTransferOperationsByTransferID[transferID],
              !operations.isEmpty else {
            queuedInboundFileTransferOperationsByTransferID.removeValue(forKey: transferID)
            return nil
        }
        let operation = operations.removeFirst()
        if operations.isEmpty {
            queuedInboundFileTransferOperationsByTransferID.removeValue(forKey: transferID)
        } else {
            queuedInboundFileTransferOperationsByTransferID[transferID] = operations
        }
        return operation
    }

    @discardableResult
    private func releaseInboundFileTransferOperationReservation(
        _ reservation: CrossNetworkFileTransferOperationReservationLedger.Reservation
    ) -> Bool {
        guard inboundFileTransferOperationReservationLedger.release(reservation) else {
            acceptsQueuedInboundFileTransferOperations = false
            SkyBridgeLogger.shared.error(
                "WebRTC inbound file-transfer operation accounting invariant failed"
            )
            return false
        }
        return true
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
extension CrossNetworkWebRTCManager {
    func sendFileTransferMessage(
        _ message: CrossNetworkFileTransferMessage,
        owner: WebRTCFileTransferOperationOwner
    ) async throws {
        try requireCurrentWebRTCFileTransferOperationOwner(owner)
        let data = try JSONEncoder().encode(message)
        try requireCurrentWebRTCFileTransferOperationOwner(owner)
        let encrypted = try encrypt(
            plaintext: data,
            with: owner.keys,
            packetType: .fileTransfer
        )
        try requireCurrentWebRTCFileTransferOperationOwner(owner)
        let padded = try TrafficPadding.wrapIfEnabled(encrypted, label: "tx/webrtc-file")
        try requireCurrentWebRTCFileTransferOperationOwner(owner)
        try await sendFramed(padded, over: owner.session)
        try requireCurrentWebRTCFileTransferOperationOwner(owner)
    }

    func waitForFileTransferAck(
        owner: WebRTCFileTransferOperationOwner,
        transferId: String,
        op: CrossNetworkFileTransferOp,
        chunkIndex: Int? = nil,
        timeoutSeconds: TimeInterval = 20
    ) async throws -> CrossNetworkFileTransferMessage {
        try requireCurrentWebRTCFileTransferOperationOwner(owner)
        let key = Self.fileTransferWaiterKey(transferId: transferId, op: op, chunkIndex: chunkIndex)
        if let existing = fileTransferWaiters[key] {
            guard !Self.isSameWebRTCFileTransferOperationOwner(existing.owner, owner) else {
                throw FileTransferWaitError.cancelled
            }
            fileTransferWaiters.removeValue(forKey: key)
            existing.timeoutTask.cancel()
            existing.sendTask?.cancel()
            existing.continuation.resume(throwing: CancellationError())
        }

        let token = UUID()
        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<CrossNetworkFileTransferMessage, Error>) in
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
                    pending.continuation.resume(throwing: FileTransferWaitError.timeout)
                }
                fileTransferWaiters[key] = FileTransferWaiter(
                    token: token,
                    owner: owner,
                    continuation: c,
                    timeoutTask: timeoutTask,
                    sendTask: nil
                )
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
        try requireCurrentWebRTCFileTransferOperationOwner(owner)
        return response
    }

    func sendFileTransferMessageAwaitingAck(
        _ message: CrossNetworkFileTransferMessage,
        owner: WebRTCFileTransferOperationOwner,
        expectedOperation: CrossNetworkFileTransferOp,
        chunkIndex: Int? = nil,
        timeoutSeconds: TimeInterval = 20
    ) async throws -> CrossNetworkFileTransferMessage {
        try requireCurrentWebRTCFileTransferOperationOwner(owner)
        let key = Self.fileTransferWaiterKey(
            transferId: message.transferId,
            op: expectedOperation,
            chunkIndex: chunkIndex
        )
        if let existing = fileTransferWaiters[key] {
            guard !Self.isSameWebRTCFileTransferOperationOwner(existing.owner, owner) else {
                throw FileTransferWaitError.cancelled
            }
            fileTransferWaiters.removeValue(forKey: key)
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
                    pending.continuation.resume(throwing: FileTransferWaitError.timeout)
                }

                fileTransferWaiters[key] = FileTransferWaiter(
                    token: token,
                    owner: owner,
                    continuation: continuation,
                    timeoutTask: timeoutTask,
                    sendTask: nil
                )

                    let sendTask = Task { @MainActor [weak self] in
                        guard let self else { throw FileTransferWaitError.transportClosed }
                        do {
                            try await self.sendFileTransferMessage(
                                message,
                                owner: owner
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
                    if var pending = fileTransferWaiters[key], pending.token == token {
                        pending.sendTask = sendTask
                        fileTransferWaiters[key] = pending
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
            guard let ownedSendTask else { throw FileTransferWaitError.transportClosed }
            try await ownedSendTask.value
            try requireCurrentWebRTCFileTransferOperationOwner(owner)
            return response
        } catch let responseError {
            if let ownedSendTask {
                ownedSendTask.cancel()
                if case .failure(let sendError) = await ownedSendTask.result,
                   isCurrentWebRTCFileTransferOperationOwner(owner),
                   !(sendError is CancellationError),
                   sendError.localizedDescription != responseError.localizedDescription {
                    SkyBridgeLogger.shared.error(
                        "WebRTC file-transfer waiter and frame send both failed: response=\(responseError.localizedDescription) send=\(sendError.localizedDescription)"
                    )
                }
            }
            guard isCurrentWebRTCFileTransferOperationOwner(owner) else {
                throw CancellationError()
            }
            throw responseError
        }
    }
}

@available(iOS 17.0, *)
extension CrossNetworkWebRTCManager {
    private func takeFileTransferWaiter(
        forKey key: FileTransferWaiterKey,
        token: UUID,
        matching owner: WebRTCFileTransferOperationOwner
    ) -> FileTransferWaiter? {
        guard let waiter = fileTransferWaiters[key],
              waiter.token == token,
              Self.isSameWebRTCFileTransferOperationOwner(waiter.owner, owner) else {
            return nil
        }
        fileTransferWaiters.removeValue(forKey: key)
        waiter.timeoutTask.cancel()
        return waiter
    }

    private func cancelFileTransferWaiter(
        forKey key: FileTransferWaiterKey,
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
        forKey key: FileTransferWaiterKey,
        matching owner: WebRTCFileTransferOperationOwner
    ) -> FileTransferWaiter? {
        guard let waiter = fileTransferWaiters[key],
              Self.isSameWebRTCFileTransferOperationOwner(waiter.owner, owner) else {
            return nil
        }
        fileTransferWaiters.removeValue(forKey: key)
        waiter.timeoutTask.cancel()
        return waiter
    }

    func handleInboundFileTransferWire(
        _ msg: CrossNetworkFileTransferMessage,
        owner: WebRTCFileTransferOperationOwner
    ) {
        guard isCurrentWebRTCFileTransferOperationOwner(owner) else { return }
        // Resume any waiter matching (transferId, op, chunkIndex).
        let key = Self.fileTransferWaiterKey(transferId: msg.transferId, op: msg.op, chunkIndex: msg.chunkIndex)
        if let waiter = takeFileTransferWaiter(forKey: key, matching: owner) {
            waiter.timeoutTask.cancel()
            waiter.continuation.resume(returning: msg)
            return
        }

        // Also allow acks without chunkIndex to be awaited.
        let keyNoIdx = Self.fileTransferWaiterKey(transferId: msg.transferId, op: msg.op, chunkIndex: nil)
        if let waiter = takeFileTransferWaiter(forKey: keyNoIdx, matching: owner) {
            waiter.timeoutTask.cancel()
            waiter.continuation.resume(returning: msg)
            return
        }
    }

    func failAllFileTransferWaiters(_ error: Error) {
        let waiters = fileTransferWaiters
        fileTransferWaiters.removeAll()
        for (_, waiter) in waiters {
            waiter.timeoutTask.cancel()
            waiter.sendTask?.cancel()
            waiter.continuation.resume(throwing: error)
        }
    }

    func failFileTransferWaiters(
        owner: WebRTCFileTransferOperationOwner,
        transferId: String,
        message: String
    ) {
        guard isCurrentWebRTCFileTransferOperationOwner(owner) else { return }
        let keys = fileTransferWaiters.keys.filter { $0.transferID == transferId }
        for key in keys {
            if let waiter = takeFileTransferWaiter(forKey: key, matching: owner) {
                waiter.timeoutTask.cancel()
                waiter.continuation.resume(throwing: FileTransferError.transferFailed(message))
            }
        }
    }

    func cancelFileTransferWaiters(transferId: String) {
        let keys = fileTransferWaiters.keys.filter { $0.transferID == transferId }
        for key in keys {
            if let waiter = fileTransferWaiters.removeValue(forKey: key) {
                waiter.timeoutTask.cancel()
                waiter.continuation.resume(throwing: CancellationError())
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

    private func recordInboundFileTransferTerminalReceipt(
        state: InboundFileTransferState,
        response: CrossNetworkFileTransferMessage,
        label: String
    ) {
        guard let completionBinding = state.completionBinding else {
            preconditionFailure("Terminal file-transfer outcome requires a completion binding")
        }
        inboundFileTransferTerminalReceipts.store(
            sessionID: state.sessionID,
            transferID: state.transferId,
            metadataBinding: state.metadataBinding,
            completionBinding: completionBinding,
            response: response,
            label: label
        )
    }

    private func scheduleInboundFileTransferIdleTimeout(_ state: InboundFileTransferState) {
        let transferID = state.transferId
        inboundFileTransferIdleTimers[transferID]?.cancel()
        inboundFileTransferIdleTimers[transferID] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.inboundWebRTCFileTransferIdleTimeout)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  self.isCurrentWebRTCFileTransferOperationOwner(state.operationOwner),
                  let current = self.inboundFileTransfers[transferID],
                  current.stateToken == state.stateToken,
                  current.lifecycleToken == state.lifecycleToken,
                  current.sessionID == state.sessionID,
                  current.revision == state.revision else {
                return
            }
            self.inboundFileTransferIdleTimers.removeValue(forKey: current.transferId)
            await self.terminateInboundFileTransfer(
                current,
                publicMessage: "Inbound file transfer idle timeout",
                uiMessage: "Inbound file transfer idle timeout",
                label: "completeError"
            )
        }
    }

    private func inboundFileTransferStateMatches(_ expected: InboundFileTransferState) -> Bool {
        guard let current = inboundFileTransfers[expected.transferId] else { return false }
        return current.stateToken == expected.stateToken
            && Self.isSameWebRTCFileTransferOperationOwner(
                current.operationOwner,
                expected.operationOwner
            )
            && current.lifecycleToken == expected.lifecycleToken
            && current.sessionID == expected.sessionID
            && current.ioHandle == expected.ioHandle
            && current.revision == expected.revision
    }

    private func inboundStateSharingIOHandle(
        with expected: InboundFileTransferState
    ) -> InboundFileTransferState? {
        guard let current = inboundFileTransfers[expected.transferId],
              current.stateToken == expected.stateToken,
              current.ioHandle == expected.ioHandle else {
            return nil
        }
        return current
    }

    private func inboundSenderAuthorityMatches(_ state: InboundFileTransferState) -> Bool {
        guard isCurrentWebRTCFileTransferOperationOwner(state.operationOwner),
              let authority = authenticatedInboundFileTransferSenderAuthority() else {
            return false
        }
        return authority.deviceId == state.senderDeviceId
            && authority.deviceName == state.senderDeviceName
    }

    private func isAuthorizedCurrentInboundState(_ state: InboundFileTransferState) -> Bool {
        inboundFileTransferLifecycleToken == state.lifecycleToken
            && isCurrentWebRTCFileTransferOperationOwner(state.operationOwner)
            && inboundFileTransferStateMatches(state)
            && inboundSenderAuthorityMatches(state)
    }

    private func removeInboundFileTransferState(_ transferID: String) {
        inboundFileTransfers.removeValue(forKey: transferID)
        inboundFileTransferCompleteTimers[transferID]?.cancel()
        inboundFileTransferCompleteTimers.removeValue(forKey: transferID)
        inboundFileTransferIdleTimers[transferID]?.cancel()
        inboundFileTransferIdleTimers.removeValue(forKey: transferID)
    }

    private func discardStaleInboundIO(
        for state: InboundFileTransferState,
        context: String
    ) async {
        do {
            try await inboundFileTransferIO.discardUncommittedFile(state.ioHandle)
        } catch {
            let diagnosticError = error as NSError
            SkyBridgeLogger.shared.warning(
                "⚠️ WebRTC stale inbound I/O cleanup failed: context=\(context) transfer=<redacted> error_domain=\(diagnosticError.domain) code=\(diagnosticError.code)"
            )
        }
    }

    private func sendInboundFileTransferResponse(
        _ response: CrossNetworkFileTransferMessage,
        owner: WebRTCFileTransferOperationOwner,
        label: String
    ) async -> FileTransferReceiptDeliveryStatus {
        guard isCurrentWebRTCFileTransferOperationOwner(owner) else {
            return .unknown
        }
        do {
            try await sendFileTransferMessage(response, owner: owner)
            return .delivered
        } catch {
            guard isCurrentWebRTCFileTransferOperationOwner(owner) else {
                return .unknown
            }
            SkyBridgeLogger.shared.warning(
                "⚠️ WebRTC file-transfer response send failed: label=\(label) op=\(response.op.rawValue) transfer=<redacted> error=\(error.localizedDescription)"
            )
            return .unknown
        }
    }

    private func terminateInboundFileTransfer(
        _ state: InboundFileTransferState,
        publicMessage: String,
        uiMessage: String,
        label: String
    ) async {
        guard inboundFileTransferStateMatches(state) else {
            await discardStaleInboundIO(for: state, context: "terminal state mismatch")
            return
        }

        let response = CrossNetworkFileTransferMessage(
            op: .error,
            transferId: state.transferId,
            message: publicMessage
        )
        if state.completionBinding != nil {
            recordInboundFileTransferTerminalReceipt(
                state: state,
                response: response,
                label: label
            )
        }
        removeInboundFileTransferState(state.transferId)

        var terminalMessage = uiMessage
        do {
            try await inboundFileTransferIO.discardUncommittedFile(state.ioHandle)
        } catch {
            terminalMessage = FileTransferError.partialFileCleanupFailed.localizedDescription
            SkyBridgeLogger.shared.warning(
                "⚠️ WebRTC terminal inbound cleanup failed: transfer=<redacted> error=\(error.localizedDescription)"
            )
        }
        FileTransferManager.instance.completeExternalInboundTransfer(
            token: state.presentationToken,
            success: false,
            error: terminalMessage
        )
        guard inboundFileTransferLifecycleToken == state.lifecycleToken,
              inboundSenderAuthorityMatches(state) else {
            return
        }
        _ = await sendInboundFileTransferResponse(
            response,
            owner: state.operationOwner,
            label: label
        )
    }

    func requestCancelInboundFileTransfer(
        presentationToken: FileTransferManager.ExternalTransferToken
    ) {
        guard let state = inboundFileTransfers.values.first(where: {
            $0.presentationToken == presentationToken
        }) else {
            // A missing transport state means the transfer has already entered
            // its post-commit terminal sequence or was concurrently cleaned up.
            return
        }
        // Once terminal close/hash/commit starts outside MainActor, cancellation
        // is too late and the durable result owns the outcome.
        guard !state.isFinalizing else { return }

        removeInboundFileTransferState(state.transferId)
        let expectedLifecycleToken = state.lifecycleToken
        Task { @MainActor [self] in
            var terminalMessage = "Cancelled by receiver"
            do {
                try await inboundFileTransferIO.discardUncommittedFile(state.ioHandle)
            } catch {
                terminalMessage = FileTransferError.partialFileCleanupFailed.localizedDescription
                SkyBridgeLogger.shared.warning(
                    "⚠️ WebRTC cancelled inbound cleanup failed: transfer=<redacted> error=\(error.localizedDescription)"
                )
            }
            FileTransferManager.instance.completeExternalInboundTransfer(
                token: state.presentationToken,
                success: false,
                error: terminalMessage
            )
            guard inboundFileTransferLifecycleToken == expectedLifecycleToken,
                  inboundSenderAuthorityMatches(state) else {
                return
            }
            _ = await sendInboundFileTransferResponse(
                CrossNetworkFileTransferMessage(
                    op: .error,
                    transferId: state.transferId,
                    message: "Cancelled by receiver"
                ),
                owner: state.operationOwner,
                label: "cancelError"
            )
        }
    }

    private func finalizeInboundFileTransfer(
        _ state: InboundFileTransferState,
        receiveKey: Data
    ) async {
        precondition(state.isFinalizing, "Inbound finalization requires a linearized finalizing state")
        let actualFileSHA256: Data
        do {
            actualFileSHA256 = try await inboundFileTransferIO.closeAndDigest(using: state.ioHandle)
        } catch is CancellationError {
            if let current = inboundStateSharingIOHandle(with: state) {
                await terminateInboundFileTransfer(
                    current,
                    publicMessage: "File processing cancelled",
                    uiMessage: "File processing cancelled",
                    label: "completeError"
                )
            }
            return
        } catch {
            SkyBridgeLogger.shared.warning(
                "⚠️ WebRTC inbound close/hash failed: transfer=<redacted> error=\(error.localizedDescription)"
            )
            let publicMessage: String
            if case InboundFileTransferIOError.closeFailed = error {
                publicMessage = "file handle close failed"
            } else {
                publicMessage = "file sha256 unavailable"
            }
            if let current = inboundStateSharingIOHandle(with: state) {
                await terminateInboundFileTransfer(
                    current,
                    publicMessage: publicMessage,
                    uiMessage: "\(publicMessage): \(error.localizedDescription)",
                    label: "completeError"
                )
            } else {
                await discardStaleInboundIO(for: state, context: "close/hash failure")
            }
            return
        }

        guard inboundFileTransferStateMatches(state) else {
            if let current = inboundStateSharingIOHandle(with: state) {
                await terminateInboundFileTransfer(
                    current,
                    publicMessage: "Concurrent inbound transfer mutation",
                    uiMessage: "Concurrent inbound transfer mutation",
                    label: "completeError"
                )
            } else {
                await discardStaleInboundIO(for: state, context: "stale hash completion")
            }
            return
        }

        if let failure = CrossNetworkFileTransferIntegrityValidator.validateMerkleProof(
            transferId: state.transferId,
            totalChunks: state.totalChunks,
            chunkHashes: state.chunkHashes,
            expectedMerkleRoot: state.expectedMerkleRoot,
            merkleRootSignature: state.expectedMerkleSig,
            merkleRootSignatureAlg: state.expectedMerkleSigAlg,
            expectedFileSha256: state.expectedFileSha256,
            receiveKey: receiveKey
        ) {
            await terminateInboundFileTransfer(
                state,
                publicMessage: failure.rawValue,
                uiMessage: failure.rawValue,
                label: "completeError"
            )
            return
        }
        if let expected = state.expectedFileSha256, actualFileSHA256 != expected {
            await terminateInboundFileTransfer(
                state,
                publicMessage: "file sha256 mismatch",
                uiMessage: "file sha256 mismatch",
                label: "completeError"
            )
            return
        }

        let savedURL: URL
        do {
            savedURL = try await inboundFileTransferIO.commit(
                using: state.ioHandle,
                destinationDirectory: state.finalURL.deletingLastPathComponent(),
                fileName: state.fileName
            )
        } catch is CancellationError {
            if let current = inboundStateSharingIOHandle(with: state) {
                await terminateInboundFileTransfer(
                    current,
                    publicMessage: "Save cancelled",
                    uiMessage: "Save cancelled",
                    label: "completeError"
                )
            }
            return
        } catch {
            SkyBridgeLogger.shared.warning(
                "⚠️ WebRTC inbound commit failed: transfer=<redacted> error=\(error.localizedDescription)"
            )
            if let current = inboundStateSharingIOHandle(with: state) {
                await terminateInboundFileTransfer(
                    current,
                    publicMessage: "Save failed",
                    uiMessage: "Save failed: \(error.localizedDescription)",
                    label: "completeError"
                )
            } else {
                await discardStaleInboundIO(for: state, context: "commit failure")
            }
            return
        }

        guard inboundFileTransferStateMatches(state) else {
            if let current = inboundStateSharingIOHandle(with: state) {
                await terminateInboundFileTransfer(
                    current,
                    publicMessage: "Concurrent inbound transfer mutation",
                    uiMessage: "Concurrent inbound transfer mutation",
                    label: "completeError"
                )
            } else {
                await discardStaleInboundIO(for: state, context: "stale commit completion")
            }
            return
        }

        let response = CrossNetworkFileTransferMessage(
            op: .completeAck,
            transferId: state.transferId,
            receivedBytes: state.receivedBytes,
            fileSha256: actualFileSHA256
        )
        if inboundFileTransferLifecycleToken == state.lifecycleToken,
           inboundSenderAuthorityMatches(state) {
            recordInboundFileTransferTerminalReceipt(
                state: state,
                response: response,
                label: "completeAck"
            )
        }
        removeInboundFileTransferState(state.transferId)

        let receiptDeliveryStatus: FileTransferReceiptDeliveryStatus
        if inboundFileTransferLifecycleToken == state.lifecycleToken,
           inboundSenderAuthorityMatches(state) {
            receiptDeliveryStatus = await sendInboundFileTransferResponse(
                response,
                owner: state.operationOwner,
                label: "completeAck"
            )
        } else {
            receiptDeliveryStatus = .unknown
        }

        var operationalWarning: FileTransferOperationalWarning?
        do {
            try await inboundFileTransferIO.releaseCommittedFile(using: state.ioHandle)
        } catch {
            operationalWarning = .committedFileReleaseFailed
            SkyBridgeLogger.shared.error(
                "❌ WebRTC committed-file actor state release failed: transfer=<redacted> error=\(error.localizedDescription)"
            )
        }

        FileTransferManager.instance.completeExternalInboundTransfer(
            token: state.presentationToken,
            success: true,
            destinationURL: savedURL,
            receiptDeliveryStatus: receiptDeliveryStatus,
            operationalWarning: operationalWarning
        )
    }

    func handleInboundFileTransferFromMac(
        _ msg: CrossNetworkFileTransferMessage,
        owner: WebRTCFileTransferOperationOwner,
        failureOrigin: InboundFileTransferFailureOrigin
    ) async {
        guard isCurrentWebRTCFileTransferOperationOwner(owner) else { return }
        let keys = owner.keys
        let sessionID = owner.sessionID
        let expectedLifecycleToken = owner.fileTransferLifecycleToken

        func sendAck(_ ack: CrossNetworkFileTransferMessage, label: String) async {
            guard isCurrentWebRTCFileTransferOperationOwner(owner) else {
                return
            }
            do {
                try await sendFileTransferMessage(ack, owner: owner)
            } catch {
                let diagnosticError = error as NSError
                guard isCurrentWebRTCFileTransferOperationOwner(owner) else {
                    SkyBridgeLogger.shared.debug(
                        "ℹ️ stale WebRTC file-transfer ack failure quarantined: label=\(label) op=\(ack.op.rawValue) transfer=<redacted> error_domain=\(diagnosticError.domain) code=\(diagnosticError.code)"
                    )
                    return
                }
                SkyBridgeLogger.shared.error(
                    "WebRTC file-transfer ack send failed: label=\(label) op=\(ack.op.rawValue) transfer=<redacted> error_domain=\(diagnosticError.domain) code=\(diagnosticError.code)"
                )
                await failInboundFileTransferControlChannel(
                    "WebRTC file-transfer acknowledgement delivery failed",
                    owner: owner,
                    origin: failureOrigin
                )
            }
        }

        if let validationError = Self.validateInboundTransferId(msg.transferId) {
            switch msg.op {
            case .metadata, .chunk, .complete, .cancel:
                await sendAck(
                    .init(op: .error, transferId: msg.transferId, message: validationError),
                    label: "invalidTransferId"
                )
            case .error, .metadataAck, .chunkAck, .completeAck:
                break
            }
            return
        }

        if msg.op == .complete,
           let receipt = inboundFileTransferTerminalReceipts.receipt(
               sessionID: sessionID,
               transferID: msg.transferId
           ) {
            guard receipt.completionBinding == InboundFileTransferCompletionBinding(message: msg) else {
                await sendAck(
                    .init(op: .error, transferId: msg.transferId, message: "transferId completion conflict"),
                    label: "completeError"
                )
                return
            }
            await sendAck(receipt.response, label: receipt.label)
            return
        }

        switch msg.op {
        case .metadata:
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

            guard let senderId = Self.requiredInboundSenderDeviceId(msg.senderDeviceId) else {
                await sendAck(
                    .init(
                        op: .error,
                        transferId: msg.transferId,
                        message: Self.inboundFileTransferMissingSenderIdentityMessage
                    ),
                    label: "metaError"
                )
                return
            }
            guard let senderAuthority = authenticatedInboundFileTransferSenderAuthority(),
                  senderId.caseInsensitiveCompare(senderAuthority.deviceId) == .orderedSame else {
                await sendAck(
                    .init(op: .error, transferId: msg.transferId, message: "sender identity does not match authenticated session"),
                    label: "metaError"
                )
                return
            }
            if let claimedName = msg.senderDeviceName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !claimedName.isEmpty,
               claimedName.caseInsensitiveCompare(senderAuthority.deviceName) != .orderedSame {
                await sendAck(
                    .init(op: .error, transferId: msg.transferId, message: "sender name does not match authenticated session"),
                    label: "metaError"
                )
                return
            }
            let authenticatedSenderID = senderAuthority.deviceId
            let senderName = senderAuthority.deviceName
            let metadataBinding = InboundFileTransferMetadataBinding(
                version: msg.version,
                senderDeviceId: authenticatedSenderID,
                senderDeviceName: senderName,
                fileName: fileName,
                fileSize: fileSize,
                chunkSize: chunkSize,
                totalChunks: totalChunks,
                mimeType: msg.mimeType,
                encryption: msg.encryption,
                batchId: msg.batchId,
                batchIndex: msg.batchIndex,
                batchTotal: msg.batchTotal,
                relativePath: msg.relativePath
            )

            if let receipt = inboundFileTransferTerminalReceipts.receipt(
                sessionID: sessionID,
                transferID: msg.transferId
            ) {
                guard receipt.metadataBinding == metadataBinding else {
                    await sendAck(
                        .init(op: .error, transferId: msg.transferId, message: "transferId metadata conflict"),
                        label: "metaError"
                    )
                    return
                }
                await sendAck(receipt.response, label: receipt.label)
                return
            }

            if let active = inboundFileTransfers[msg.transferId] {
                guard Self.isSameWebRTCFileTransferOperationOwner(
                    active.operationOwner,
                    owner
                ), active.metadataBinding == metadataBinding else {
                    await sendAck(
                        .init(op: .error, transferId: msg.transferId, message: "transferId metadata conflict"),
                        label: "metaError"
                    )
                    return
                }
                await sendAck(.init(op: .metadataAck, transferId: msg.transferId), label: "metaAck")
                return
            }

            if let pending = inboundFileTransferPendingAdmissions[msg.transferId] {
                guard Self.isSameWebRTCFileTransferOperationOwner(
                    pending.operationOwner,
                    owner
                ), pending.metadataBinding == metadataBinding else {
                    await sendAck(
                        .init(op: .error, transferId: msg.transferId, message: "transferId metadata conflict"),
                        label: "metaError"
                    )
                    return
                }
                await sendAck(
                    .init(op: .error, transferId: msg.transferId, message: "Inbound file transfer approval pending"),
                    label: "metaError"
                )
                return
            }

            let activeTransfersForSession = inboundFileTransfers.values.reduce(into: 0) { count, state in
                if state.sessionID == sessionID {
                    count += 1
                }
            }
            let pendingTransfersForSession = inboundFileTransferPendingAdmissions.values.reduce(into: 0) { count, pending in
                if pending.sessionID == sessionID {
                    count += 1
                }
            }
            guard activeTransfersForSession + pendingTransfersForSession < Self.maxConcurrentInboundWebRTCFileTransfersPerSession,
                  inboundFileTransfers.count + inboundFileTransferPendingAdmissions.count < Self.maxConcurrentInboundWebRTCFileTransfersGlobal else {
                await sendAck(
                    .init(
                        op: .error,
                        transferId: msg.transferId,
                        message: "Too many concurrent inbound file transfers"
                    ),
                    label: "metaError"
                )
                return
            }

            let admissionToken = UUID()
            inboundFileTransferPendingAdmissions[msg.transferId] = InboundFileTransferPendingAdmission(
                token: admissionToken,
                operationOwner: owner,
                sessionID: sessionID,
                metadataBinding: metadataBinding
            )
            defer {
                if inboundFileTransferPendingAdmissions[msg.transferId]?.token == admissionToken {
                    inboundFileTransferPendingAdmissions.removeValue(forKey: msg.transferId)
                }
            }

            let approvalRequest = InboundFileTransferApprovalRequest(
                transferId: msg.transferId,
                fileName: fileName,
                fileSize: fileSize,
                chunkSize: chunkSize,
                totalChunks: totalChunks,
                senderDeviceId: authenticatedSenderID,
                senderDeviceName: senderName
            )
            switch await inboundFileTransferApprovalProvider(approvalRequest) {
            case .approved:
                break
            case .rejected(let reason):
                await sendAck(
                    .init(
                        op: .error,
                        transferId: msg.transferId,
                        message: Self.normalizedInboundApprovalRejectionMessage(reason)
                    ),
                    label: "metaError"
                )
                return
            }
            guard !Task.isCancelled,
                  isCurrentWebRTCFileTransferOperationOwner(owner),
                  let pendingAdmission = inboundFileTransferPendingAdmissions[msg.transferId],
                  pendingAdmission.token == admissionToken,
                  Self.isSameWebRTCFileTransferOperationOwner(
                    pendingAdmission.operationOwner,
                    owner
                  ) else {
                return
            }

            let baseDir = Self.downloadsDirectoryURL()
            let finalURL = baseDir.appendingPathComponent(fileName, isDirectory: false)
            let tempURL = baseDir.appendingPathComponent(".skybridge-\(msg.transferId).partial")
            let ioHandle: InboundFileTransferIOHandle
            do {
                ioHandle = try await inboundFileTransferIO.createTemporaryFile(
                    at: tempURL,
                    declaredFileSize: fileSize
                )
            } catch is CancellationError {
                return
            } catch {
                SkyBridgeLogger.shared.warning(
                    "⚠️ WebRTC inbound partial creation failed: transfer=<redacted> error=\(error.localizedDescription)"
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
                await sendAck(.init(op: .error, transferId: msg.transferId, message: publicMessage), label: "metaError")
                return
            }

            guard !Task.isCancelled,
                  isCurrentWebRTCFileTransferOperationOwner(owner),
                  let pendingAdmission = inboundFileTransferPendingAdmissions[msg.transferId],
                  pendingAdmission.token == admissionToken,
                  Self.isSameWebRTCFileTransferOperationOwner(
                    pendingAdmission.operationOwner,
                    owner
                  ),
                  let currentAuthority = authenticatedInboundFileTransferSenderAuthority(),
                  currentAuthority.deviceId == senderAuthority.deviceId,
                  currentAuthority.deviceName == senderAuthority.deviceName else {
                do {
                    try await inboundFileTransferIO.discardUncommittedFile(ioHandle)
                } catch {
                    SkyBridgeLogger.shared.warning(
                        "⚠️ WebRTC stale inbound admission cleanup failed: transfer=<redacted> error=\(error.localizedDescription)"
                    )
                }
                return
            }

            guard let presentationToken = FileTransferManager.instance.beginExternalInboundTransfer(
                transferId: msg.transferId,
                fileName: fileName,
                fileSize: fileSize,
                fromPeerName: senderName
            ) else {
                do {
                    try await inboundFileTransferIO.discardUncommittedFile(ioHandle)
                } catch {
                    SkyBridgeLogger.shared.warning(
                        "⚠️ WebRTC rejected-presentation cleanup failed: transfer=<redacted> error=\(error.localizedDescription)"
                    )
                }
                await sendAck(
                    .init(
                        op: .error,
                        transferId: msg.transferId,
                        message: "Inbound file transfer identifier is already active"
                    ),
                    label: "metaError"
                )
                return
            }

            inboundFileTransfers[msg.transferId] = InboundFileTransferState(
                    stateToken: admissionToken,
                    presentationToken: presentationToken,
                    operationOwner: owner,
                    lifecycleToken: expectedLifecycleToken,
                    sessionID: sessionID,
                    transferId: msg.transferId,
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
            inboundFileTransferPendingAdmissions.removeValue(forKey: msg.transferId)
            if let state = inboundFileTransfers[msg.transferId] {
                scheduleInboundFileTransferIdleTimeout(state)
            }

            await sendAck(.init(op: .metadataAck, transferId: msg.transferId), label: "metaAck")

        case .chunk:
            guard let idx = msg.chunkIndex, let data = msg.chunkData else { return }
            guard var st = inboundFileTransfers[msg.transferId] else {
                await sendAck(.init(op: .error, transferId: msg.transferId, message: "Unknown transferId"), label: "chunkError")
                return
            }
            guard st.sessionID == sessionID else {
                await sendAck(
                    .init(op: .error, transferId: msg.transferId, message: "transferId metadata conflict"),
                    label: "chunkError"
                )
                return
            }
            guard !st.isFinalizing else { return }
            guard inboundFileTransferChunkOperationsInFlight[msg.transferId] == nil else {
                await sendAck(
                    .init(
                        op: .error,
                        transferId: msg.transferId,
                        chunkIndex: msg.chunkIndex,
                        message: "chunk operation already in progress"
                    ),
                    label: "chunkError"
                )
                return
            }
            let chunkOperationOwner = InboundFileTransferChunkOperationOwner(
                token: UUID(),
                stateToken: st.stateToken,
                lifecycleToken: st.lifecycleToken,
                sessionID: st.sessionID
            )
            inboundFileTransferChunkOperationsInFlight[msg.transferId] = chunkOperationOwner
            defer {
                CrossNetworkExactOwnerDictionary.removeValue(
                    from: &inboundFileTransferChunkOperationsInFlight,
                    key: msg.transferId,
                    expectedOwner: chunkOperationOwner,
                    owner: { $0 }
                )
            }
            guard isAuthorizedCurrentInboundState(st) else {
                await terminateInboundFileTransfer(
                    st,
                    publicMessage: "authenticated sender authority changed",
                    uiMessage: "Authenticated sender authority changed",
                    label: "chunkError"
                )
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
            ), expectedChunkSize == rawSize else {
                await sendAck(.init(op: .error, transferId: msg.transferId, chunkIndex: idx, message: "chunk length does not match metadata"), label: "chunkError")
                return
            }

            let isDuplicate = st.chunkHashes[idx] != nil
            let actualHash: Data
            do {
                if isDuplicate {
                    actualHash = try await inboundFileTransferIO.digest(
                        data,
                        expectedSHA256: msg.chunkSha256
                    )
                } else {
                    let offset = Int64(idx) * Int64(st.chunkSize)
                    guard offset >= 0, offset + Int64(rawSize) <= st.fileSize else {
                        await sendAck(.init(op: .error, transferId: msg.transferId, chunkIndex: idx, message: "chunk exceeds declared file size"), label: "chunkError")
                        return
                    }
                    actualHash = try await inboundFileTransferIO.write(
                        data,
                        atOffset: UInt64(offset),
                        using: st.ioHandle,
                        expectedSHA256: msg.chunkSha256
                    )
                }
            } catch InboundFileTransferIOError.dataDigestMismatch {
                guard isAuthorizedCurrentInboundState(st) else { return }
                await sendAck(.init(op: .error, transferId: msg.transferId, chunkIndex: idx, message: "chunk hash mismatch"), label: "chunkHashMismatch")
                return
            } catch is CancellationError {
                if inboundFileTransferStateMatches(st) {
                    await terminateInboundFileTransfer(
                        st,
                        publicMessage: "Write cancelled",
                        uiMessage: "Inbound file write cancelled",
                        label: "chunkError"
                    )
                }
                return
            } catch {
                SkyBridgeLogger.shared.warning(
                    "⚠️ WebRTC inbound write failed: transfer=<redacted> error=\(error.localizedDescription)"
                )
                if let current = inboundStateSharingIOHandle(with: st) {
                    await terminateInboundFileTransfer(
                        current,
                        publicMessage: "Write failed",
                        uiMessage: "Write failed: \(error.localizedDescription)",
                        label: "chunkError"
                    )
                } else {
                    await discardStaleInboundIO(for: st, context: "write failure")
                }
                return
            }

            guard isAuthorizedCurrentInboundState(st) else {
                if !isDuplicate, let current = inboundStateSharingIOHandle(with: st) {
                    await terminateInboundFileTransfer(
                        current,
                        publicMessage: "Concurrent inbound transfer mutation",
                        uiMessage: "Concurrent inbound transfer mutation",
                        label: "chunkError"
                    )
                } else if !isDuplicate {
                    await discardStaleInboundIO(for: st, context: "stale write completion")
                }
                return
            }

            if let existingHash = st.chunkHashes[idx] {
                guard existingHash == actualHash, st.receivedChunkSizes[idx] == rawSize else {
                    await sendAck(.init(op: .error, transferId: msg.transferId, chunkIndex: idx, message: "duplicate chunk content mismatch"), label: "chunkError")
                    return
                }
            } else {
                st.chunkHashes[idx] = actualHash
                st.receivedChunkSizes[idx] = rawSize
                st.receivedBytes += Int64(rawSize)
                st.revision &+= 1
            }
            inboundFileTransfers[msg.transferId] = st

            await FileTransferManager.instance.updateExternalInboundProgress(
                token: st.presentationToken,
                transferredBytes: st.receivedBytes,
                totalBytes: st.fileSize
            )
            let progressResumeDecision = InboundFileTransferProgressResumePolicy.decision(
                expectedOwner: st.progressOwner,
                currentOwner: inboundFileTransfers[st.transferId]?.progressOwner,
                activeLifecycleToken: inboundFileTransferLifecycleToken,
                activeSessionID: sessionKeys?.sessionId
            )
            guard progressResumeDecision == .resume else {
                await discardStaleInboundIO(
                    for: st,
                    context: "stale progress completion"
                )
                return
            }
            guard inboundSenderAuthorityMatches(st) else {
                await terminateInboundFileTransfer(
                    st,
                    publicMessage: "authenticated sender authority changed",
                    uiMessage: "Authenticated sender authority changed",
                    label: "chunkError"
                )
                return
            }
            if st.completeRequestedAt != nil && st.receivedBytes >= st.fileSize {
                st.isFinalizing = true
                st.revision &+= 1
                inboundFileTransfers[st.transferId] = st
                inboundFileTransferCompleteTimers.removeValue(forKey: st.transferId)?.cancel()
                inboundFileTransferIdleTimers.removeValue(forKey: st.transferId)?.cancel()
                await finalizeInboundFileTransfer(st, receiveKey: keys.receiveKey)
                return
            }
            scheduleInboundFileTransferIdleTimeout(st)
            await sendAck(
                .init(op: .chunkAck, transferId: st.transferId, chunkIndex: idx, receivedBytes: st.receivedBytes),
                label: "chunkAck"
            )

        case .complete:
            guard var st = inboundFileTransfers[msg.transferId] else {
                await sendAck(
                    .init(op: .error, transferId: msg.transferId, message: "Unknown transferId"),
                    label: "completeError"
                )
                return
            }
            guard st.sessionID == sessionID else {
                await sendAck(
                    .init(op: .error, transferId: msg.transferId, message: "transferId metadata conflict"),
                    label: "completeError"
                )
                return
            }

            let completionBinding = InboundFileTransferCompletionBinding(message: msg)
            if let existingBinding = st.completionBinding, existingBinding != completionBinding {
                await sendAck(
                    .init(op: .error, transferId: msg.transferId, message: "transferId completion conflict"),
                    label: "completeError"
                )
                return
            }
            guard !st.isFinalizing else { return }
            guard isAuthorizedCurrentInboundState(st) else {
                await terminateInboundFileTransfer(
                    st,
                    publicMessage: "authenticated sender authority changed",
                    uiMessage: "Authenticated sender authority changed",
                    label: "completeError"
                )
                return
            }
            st.completionBinding = completionBinding

            // Capture expected full-file hash (optional, backward compatible).
            if st.expectedFileSha256 == nil { st.expectedFileSha256 = msg.fileSha256 }
            if st.expectedMerkleRoot == nil { st.expectedMerkleRoot = msg.merkleRoot }
            if st.expectedMerkleSig == nil { st.expectedMerkleSig = msg.merkleRootSignature }
            if st.expectedMerkleSigAlg == nil { st.expectedMerkleSigAlg = msg.merkleRootSignatureAlg }
            if st.completeRequestedAt == nil { st.completeRequestedAt = Date() }
            st.revision &+= 1
            inboundFileTransfers[st.transferId] = st
            guard hasRequiredIntegrityProof(st) else {
                await terminateInboundFileTransfer(
                    st,
                    publicMessage: "missing integrity proof",
                    uiMessage: "missing integrity proof",
                    label: "completeError"
                )
                return
            }

            if st.receivedBytes < st.fileSize {
                let missing = (0..<st.totalChunks).filter { st.chunkHashes[$0] == nil }
                scheduleInboundFileTransferIdleTimeout(st)

                if inboundFileTransferCompleteTimers[st.transferId] == nil {
                    let expected = st
                    inboundFileTransferCompleteTimers[st.transferId] = Task { @MainActor [weak self] in
                        do {
                            try await Task.sleep(for: .seconds(10))
                        } catch {
                            return
                        }
                        guard !Task.isCancelled else { return }
                        guard let self else { return }
                        self.inboundFileTransferCompleteTimers.removeValue(
                            forKey: expected.transferId
                        )
                        if let cur = self.inboundFileTransfers[expected.transferId],
                           cur.stateToken == expected.stateToken,
                           cur.lifecycleToken == expected.lifecycleToken,
                           cur.sessionID == expected.sessionID,
                           !cur.isFinalizing,
                           cur.receivedBytes < cur.fileSize {
                            await self.terminateInboundFileTransfer(
                                cur,
                                publicMessage: "Incomplete file (timeout)",
                                uiMessage: "Incomplete file (timeout): \(cur.receivedBytes)/\(cur.fileSize)",
                                label: "completeError"
                            )
                        }
                    }
                }
                if !missing.isEmpty {
                    await sendAck(
                        .init(
                            op: .chunkAck,
                            transferId: st.transferId,
                            missingChunks: Array(missing.prefix(512)),
                            message: "missingChunks"
                        ),
                        label: "missingChunks"
                    )
                }
                return
            }

            guard !st.isFinalizing else { return }
            st.isFinalizing = true
            st.revision &+= 1
            inboundFileTransfers[st.transferId] = st
            inboundFileTransferCompleteTimers.removeValue(forKey: st.transferId)?.cancel()
            inboundFileTransferIdleTimers.removeValue(forKey: st.transferId)?.cancel()
            await finalizeInboundFileTransfer(st, receiveKey: keys.receiveKey)

        case .cancel:
            guard let st = inboundFileTransfers[msg.transferId],
                  !st.isFinalizing else {
                return
            }
            guard st.sessionID == sessionID else {
                await sendAck(
                    .init(
                        op: .error,
                        transferId: msg.transferId,
                        message: "transferId metadata conflict"
                    ),
                    label: "cancelError"
                )
                return
            }
            guard isAuthorizedCurrentInboundState(st) else {
                await terminateInboundFileTransfer(
                    st,
                    publicMessage: "authenticated sender authority changed",
                    uiMessage: "Authenticated sender authority changed",
                    label: "cancelError"
                )
                return
            }
            removeInboundFileTransferState(msg.transferId)
            var terminalMessage = "Cancelled by sender"
            do {
                try await inboundFileTransferIO.discardUncommittedFile(st.ioHandle)
            } catch {
                terminalMessage = FileTransferError.partialFileCleanupFailed.localizedDescription
                SkyBridgeLogger.shared.warning(
                    "⚠️ WebRTC cancelled inbound cleanup failed: transfer=<redacted> error=\(error.localizedDescription)"
                )
            }
            FileTransferManager.instance.completeExternalInboundTransfer(
                token: st.presentationToken,
                success: false,
                error: terminalMessage
            )

        case .metadataAck, .chunkAck, .completeAck:
            // These are acks for iOS->macOS sending.
            handleInboundFileTransferWire(msg, owner: owner)

        case .error:
            // Fail any pending iOS->macOS sender waits for this transfer immediately.
            failFileTransferWaiters(
                owner: owner,
                transferId: msg.transferId,
                message: Self.normalizedRemoteFileTransferStatusMessage(
                    msg.message,
                    fallback: "remote rejected file transfer"
                )
            )
        }
    }
}
