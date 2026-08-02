import Combine
import Foundation
import Network
import OSLog
import SkyBridgeMessagePersistence
import SkyBridgeProtocolCore

public enum DeviceMessagingError: Error, LocalizedError, Sendable, Equatable {
    case transportUnavailable
    case transportFailed(OfflineDeliveryFailureCode)
    case queueRejected(OfflineDeliveryFailureCode)
    case persistenceFailed

    public var errorDescription: String? {
        switch self {
        case .transportUnavailable:
            return "The selected device does not have an authenticated transport"
        case .transportFailed:
            return "The device message transport failed"
        case .queueRejected:
            return "The device message could not be queued"
        case .persistenceFailed:
            return "The device message could not be persisted"
        }
    }
}

@available(macOS 14.0, iOS 17.0, *)
struct DeviceMessageTransport: Sendable {
    let send: @MainActor @Sendable (
        _ deviceID: String,
        _ conversationFingerprint: String,
        _ payload: AppMessage.TextMessagePayload
    ) async throws -> Void
}

/// Binds conversation history and offline delivery to the exact authenticated
/// protocol identity of the current P2P connection.
@available(macOS 14.0, iOS 17.0, *)
@MainActor
public final class DeviceMessagingService: ObservableObject {
    public static let shared = DeviceMessagingService()

    private struct OnlineTransition {
        let token: UUID
        let task: Task<Void, Never>
    }

    private struct UnifiedWorker {
        let lifecycleToken: UUID
        let task: Task<Void, Never>
    }

    private let logger = Logger(subsystem: "com.skybridge.compass", category: "DeviceMessaging")
    private let store: DeviceMessageStore
    private let queue: OfflineMessageQueue
    private let transport: DeviceMessageTransport
    private let observesProductionConnections: Bool
    private let usesUnifiedRepository: Bool
    private let unifiedRuntime: UnifiedDeviceMessagingRuntime
    private let unifiedWorkerQuiesceTimeout: Duration
    private var started = false
    private var cancellables = Set<AnyCancellable>()
    private var onlineDeviceIDs: Set<String> = []
    private var onlineTransitions: [String: OnlineTransition] = [:]
    private var unifiedWorkers: [String: UnifiedWorker] = [:]
    private var unifiedQueueMutationToken: UUID?
    private var unifiedMaintenanceTask: Task<Void, Never>?

    private static let receiptTimeout: TimeInterval = 60
    private static let maintenanceIntervalNanoseconds: UInt64 = 15_000_000_000

    private convenience init() {
        self.init(
            store: .shared,
            queue: .shared,
            transport: DeviceMessageTransport { deviceID, fingerprint, payload in
                guard let connection = P2PNetworkManager.shared.activeConnections[deviceID],
                      connection.status == .authenticated else {
                    throw DeviceMessagingError.transportUnavailable
                }
                try await connection.sendAppMessage(
                    .textMessage(payload),
                    requiringRemoteProtocolFingerprint: fingerprint
                )
            },
            observesProductionConnections: true,
            usesUnifiedRepository: true,
            unifiedRuntime: .shared
        )
    }

    init(
        store: DeviceMessageStore,
        queue: OfflineMessageQueue,
        transport: DeviceMessageTransport,
        observesProductionConnections: Bool,
        usesUnifiedRepository: Bool = false,
        unifiedRuntime: UnifiedDeviceMessagingRuntime = .shared,
        initiallyOnlineDeviceIDs: Set<String> = [],
        unifiedWorkerQuiesceTimeout: Duration = .seconds(5)
    ) {
        self.store = store
        self.queue = queue
        self.transport = transport
        self.observesProductionConnections = observesProductionConnections
        self.usesUnifiedRepository = usesUnifiedRepository
        self.unifiedRuntime = unifiedRuntime
        self.unifiedWorkerQuiesceTimeout = unifiedWorkerQuiesceTimeout
        onlineDeviceIDs = initiallyOnlineDeviceIDs
        if usesUnifiedRepository {
            queue.installUnifiedMutationHandler { [weak self] mutation in
                guard let self else { throw DeviceMessagingError.persistenceFailed }
                try await self.performUnifiedQueueMutation(mutation)
            }
            store.installUnifiedMutationHandler { [weak self] mutation in
                guard let self else { throw DeviceMessagingError.persistenceFailed }
                try await self.performUnifiedStoreMutation(mutation)
            }
        }
    }

    public func start() {
        guard !started else { return }
        started = true

        if usesUnifiedRepository {
            Task { @MainActor [weak self] in
                await self?.bootstrapUnifiedRepository()
            }
        } else {
            queue.sendHandler = { [weak self] message in
                guard let self else { return .cancelled }
                return await self.deliverQueuedMessage(message)
            }
        }

        guard observesProductionConnections else { return }
        P2PNetworkManager.shared.$activeConnections
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connections in
                self?.syncOnlineConnections(connections)
            }
            .store(in: &cancellables)
    }

    public func prepare() async throws {
        guard usesUnifiedRepository else { return }
        try applyUnifiedSnapshot(try await unifiedRuntime.bootstrap())
    }

    public static func logSafeErrorSummary(_ error: Error) -> String {
        if let error = error as? DeviceMessagingError {
            switch error {
            case .transportUnavailable:
                return "transport_unavailable"
            case .transportFailed(let code), .queueRejected(let code):
                return code.rawValue
            case .persistenceFailed:
                return OfflineDeliveryFailureCode.persistenceFailure.rawValue
            }
        }
        if let error = error as? DeviceTextMessagePolicyError {
            return error.rawValue
        }
        if let error = error as? DeviceMessageStoreError {
            switch error {
            case .invalidConversationFingerprint:
                return OfflineDeliveryFailureCode.invalidConversationFingerprint.rawValue
            case .messageNotFound, .invalidPersistedState, .conversationCapacityExceeded,
                 .pendingOutgoingMessagesPreventClear:
                return OfflineDeliveryFailureCode.stateConflict.rawValue
            case .storageCapacityExceeded:
                return OfflineDeliveryFailureCode.storageCapacityExceeded.rawValue
            case .persistenceBlocked(let code):
                return code.rawValue
            }
        }
        if let error = error as? OfflineQueueError {
            switch error {
            case .persistenceBlocked(let code):
                return code.rawValue
            case .queueFull, .deviceQueueFull:
                return OfflineDeliveryFailureCode.queueCapacityExceeded.rawValue
            case .messageExpired:
                return "message_expired"
            case .messageTooLarge:
                return "message_too_large"
            case .storageCapacityExceeded:
                return OfflineDeliveryFailureCode.storageCapacityExceeded.rawValue
            case .invalidPayload:
                return OfflineDeliveryFailureCode.invalidPayload.rawValue
            case .deviceOffline:
                return OfflineDeliveryFailureCode.transportUnavailable.rawValue
            case .sendFailed:
                return OfflineDeliveryFailureCode.transportFailure.rawValue
            case .messageNotFound, .staleClaim:
                return OfflineDeliveryFailureCode.stateConflict.rawValue
            case .coordinatedRetryRequired:
                return OfflineDeliveryFailureCode.stateConflict.rawValue
            case .invalidConfiguration:
                return "invalid_configuration"
            }
        }
        if error is CancellationError {
            return "cancelled"
        }
        return String(describing: type(of: error))
    }

    public func send(
        text rawText: String,
        toDeviceID rawDeviceID: String,
        fingerprint rawFingerprint: String
    ) async throws {
        let text = try DeviceTextMessagePolicy.validatedText(rawText)
        let deviceID = try DeviceTextMessagePolicy
            .normalizedTargetDeviceIdentifier(rawDeviceID)
        let fingerprint = try DeviceTextMessagePolicy
            .normalizedConversationFingerprint(rawFingerprint)
        let payload = AppMessage.TextMessagePayload(text: text)
        let queuedPayload: Data
        do {
            queuedPayload = try JSONEncoder().encode(
                DeviceTextQueueEnvelope(
                    payload: payload,
                    conversationFingerprint: fingerprint
                )
            )
        } catch {
            throw DeviceMessagingError.queueRejected(.invalidPayload)
        }

        if usesUnifiedRepository {
            try await sendUsingUnifiedRepository(
                text: text,
                deviceID: deviceID,
                fingerprint: fingerprint,
                payload: payload,
                queuedPayload: queuedPayload
            )
            return
        }

        do {
            try await store.appendOutgoing(
                text: text,
                fingerprint: fingerprint,
                targetDeviceID: deviceID,
                messageID: payload.id,
                sentAt: payload.sentAt
            )
        } catch {
            throw DeviceMessagingError.persistenceFailed
        }

        do {
            try await transport.send(deviceID, fingerprint, payload)
        } catch {
            let disposition = Self.deliveryDisposition(for: error)
            switch disposition {
            case .cancelled:
                try await markFailedOrThrowPersistence(
                    messageID: payload.id,
                    fingerprint: fingerprint
                )
                throw CancellationError()
            case .retryable:
                try await enqueueOffline(
                    deviceID: deviceID,
                    queuedPayload: queuedPayload,
                    messageID: payload.id,
                    fingerprint: fingerprint
                )
                return
            case .permanentFailure(let code):
                try await markFailedOrThrowPersistence(
                    messageID: payload.id,
                    fingerprint: fingerprint
                )
                throw DeviceMessagingError.transportFailed(code)
            case .delivered:
                throw DeviceMessagingError.transportFailed(.stateConflict)
            }
        }

        do {
            try await store.markSent(messageID: payload.id, fingerprint: fingerprint)
        } catch {
            throw DeviceMessagingError.persistenceFailed
        }
    }

    public func handleIncoming(
        _ payload: AppMessage.TextMessagePayload,
        fingerprint rawFingerprint: String
    ) async throws {
        let text = try DeviceTextMessagePolicy.validatedText(payload.text)
        let fingerprint = try DeviceTextMessagePolicy
            .normalizedConversationFingerprint(rawFingerprint)
        do {
            try await store.receiveIncoming(
                text: text,
                fingerprint: fingerprint,
                messageID: payload.id,
                sentAt: payload.sentAt
            )
        } catch {
            throw DeviceMessagingError.persistenceFailed
        }
    }

    public func handleAuthenticatedReceipt(
        _ payload: AppMessage.TextMessageReceiptPayload,
        fingerprint rawFingerprint: String
    ) async throws {
        guard usesUnifiedRepository else {
            throw DeviceMessagingError.persistenceFailed
        }
        let fingerprint = try DeviceTextMessagePolicy
            .normalizedConversationFingerprint(rawFingerprint)
        do {
            try applyUnifiedSnapshot(
                try await unifiedRuntime.confirmAuthenticatedReceipt(
                    AuthenticatedMessageReceipt(
                        messageID: payload.messageID,
                        deliveryAttemptID: payload.deliveryAttemptID,
                        conversationFingerprint: fingerprint,
                        receivedAt: payload.receivedAt
                    )
                )
            )
        } catch {
            throw DeviceMessagingError.persistenceFailed
        }
    }

    static func deliveryDisposition(for error: Error) -> OfflineDeliveryDisposition {
        if error is CancellationError {
            return .cancelled
        }
        if let error = error as? DeviceMessagingError {
            switch error {
            case .transportUnavailable:
                return .retryable(.transportUnavailable)
            case .transportFailed(let code), .queueRejected(let code):
                return .permanentFailure(code)
            case .persistenceFailed:
                return .permanentFailure(.persistenceFailure)
            }
        }
        if let error = error as? P2PConnectionError {
            switch error {
            case .disconnected, .noSessionKeys, .bootstrapControlOnly,
                 .staleHandshakeOperation, .staleAuthenticatedFrame,
                 .sessionHandoffUnavailable, .handshakeOperationInProgress:
                return .retryable(.transportUnavailable)
            case .authenticatedBindingUnavailable, .authenticatedIdentityMismatch:
                return .permanentFailure(.authenticatedIdentityMismatch)
            case .handshakeUnavailable, .invalidFrameLength,
                 .invalidAuthenticatedPayload, .inboundFrameWithoutOwner,
                 .unexpectedAuthenticatedHandshakeFrame, .authenticatedPongReplyFailed,
                 .bootstrapKEMKeyTimeout, .postAuthPairingIdentityExchangeTimeout,
                 .arbiterLeaseUnavailable, .presenceLeaseUnavailable,
                 .classicTransferSessionLeaseUnavailable, .inboundRekeyRejected,
                 .handshakeOperationSequenceExhausted, .capacityExceeded:
                return .permanentFailure(.transportFailure)
            }
        }
        if error is NWError {
            return .retryable(.transportUnavailable)
        }
        if error is DeviceTextMessagePolicyError {
            return .permanentFailure(.invalidPayload)
        }
        return .permanentFailure(.transportFailure)
    }

    private func enqueueOffline(
        deviceID: String,
        queuedPayload: Data,
        messageID: UUID,
        fingerprint: String
    ) async throws {
        do {
            _ = try await queue.enqueue(
                targetDeviceID: deviceID,
                messageType: .text,
                priority: .normal,
                payload: queuedPayload
            )
        } catch {
            try await markFailedOrThrowPersistence(
                messageID: messageID,
                fingerprint: fingerprint
            )
            throw DeviceMessagingError.queueRejected(Self.queueFailureCode(for: error))
        }
    }

    private func deliverQueuedMessage(_ message: QueuedMessage) async -> OfflineDeliveryDisposition {
        guard message.messageType == .text else {
            return .permanentFailure(.invalidMessageType)
        }
        let envelope: DeviceTextQueueEnvelope
        do {
            envelope = try JSONDecoder().decode(DeviceTextQueueEnvelope.self, from: message.payload)
            _ = try DeviceTextMessagePolicy.validatedText(envelope.payload.text)
            let normalizedFingerprint = try DeviceTextMessagePolicy
                .normalizedConversationFingerprint(envelope.conversationFingerprint)
            guard normalizedFingerprint == envelope.conversationFingerprint else {
                return .permanentFailure(.invalidConversationFingerprint)
            }
            let normalizedTarget = try DeviceTextMessagePolicy
                .normalizedTargetDeviceIdentifier(message.targetDeviceID)
            guard normalizedTarget == message.targetDeviceID else {
                return .permanentFailure(.invalidTargetDeviceIdentifier)
            }
        } catch let error as DeviceTextMessagePolicyError {
            switch error {
            case .invalidConversationFingerprint:
                return .permanentFailure(.invalidConversationFingerprint)
            case .invalidTargetDeviceIdentifier:
                return .permanentFailure(.invalidTargetDeviceIdentifier)
            case .emptyText, .textTooLong, .textTooLarge:
                return .permanentFailure(.invalidPayload)
            }
        } catch {
            return .permanentFailure(.invalidPayload)
        }

        do {
            try await transport.send(
                message.targetDeviceID,
                envelope.conversationFingerprint,
                envelope.payload
            )
        } catch {
            let disposition = Self.deliveryDisposition(for: error)
            guard !Task.isCancelled else { return .cancelled }
            if case .permanentFailure = disposition {
                return await permanentDispositionAfterMarkingStoredMessageFailed(
                    disposition,
                    messageID: envelope.payload.id,
                    fingerprint: envelope.conversationFingerprint
                )
            }
            return disposition
        }

        do {
            try await store.markSent(
                messageID: envelope.payload.id,
                fingerprint: envelope.conversationFingerprint
            )
            return .delivered
        } catch {
            logger.error("Queued device-message sent-state persistence failed")
            return .permanentFailure(.persistenceFailure)
        }
    }

    private func permanentDispositionAfterMarkingStoredMessageFailed(
        _ disposition: OfflineDeliveryDisposition,
        messageID: UUID,
        fingerprint: String
    ) async -> OfflineDeliveryDisposition {
        do {
            try await store.markFailed(messageID: messageID, fingerprint: fingerprint)
            return disposition
        } catch {
            logger.error("Queued device-message failed-state persistence failed")
            return .permanentFailure(.persistenceFailure)
        }
    }

    private func markFailedOrThrowPersistence(
        messageID: UUID,
        fingerprint: String
    ) async throws {
        do {
            try await store.markFailed(messageID: messageID, fingerprint: fingerprint)
        } catch {
            throw DeviceMessagingError.persistenceFailed
        }
    }

    private static func queueFailureCode(for error: Error) -> OfflineDeliveryFailureCode {
        if let error = error as? OfflineQueueError {
            switch error {
            case .persistenceBlocked(let code):
                return code
            case .storageCapacityExceeded:
                return .storageCapacityExceeded
            case .queueFull, .deviceQueueFull:
                return .queueCapacityExceeded
            case .messageExpired, .messageTooLarge, .invalidPayload,
                 .deviceOffline, .sendFailed, .invalidConfiguration,
                 .coordinatedRetryRequired, .staleClaim, .messageNotFound:
                break
            }
        }
        if error is DeviceTextMessagePolicyError {
            return .invalidPayload
        }
        return .persistenceFailure
    }

    private func syncOnlineConnections(_ connections: [String: P2PConnection]) {
        let authenticated = Set(
            connections.lazy
                .filter { $0.value.status == .authenticated }
                .map(\.key)
        )
        let newlyOnline = authenticated.subtracting(onlineDeviceIDs)
        let wentOffline = onlineDeviceIDs.subtracting(authenticated)
        onlineDeviceIDs = authenticated

        if usesUnifiedRepository {
            for deviceID in wentOffline {
                unifiedWorkers[deviceID]?.task.cancel()
                queue.deviceOffline(deviceID)
            }
            for deviceID in newlyOnline {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.queue.deviceOnline(deviceID)
                    self.scheduleUnifiedWorker(for: deviceID)
                }
            }
            return
        }

        for deviceID in wentOffline {
            onlineTransitions.removeValue(forKey: deviceID)?.task.cancel()
            queue.deviceOffline(deviceID)
        }
        for deviceID in newlyOnline {
            onlineTransitions.removeValue(forKey: deviceID)?.task.cancel()
            let token = UUID()
            let task = Task { @MainActor [weak self] in
                guard let self, self.onlineDeviceIDs.contains(deviceID) else { return }
                await self.queue.deviceOnline(deviceID)
                guard self.onlineTransitions[deviceID]?.token == token else { return }
                self.onlineTransitions.removeValue(forKey: deviceID)
            }
            onlineTransitions[deviceID] = OnlineTransition(token: token, task: task)
        }
    }

    private var unifiedRetryPolicy: MessageDeliveryRetryPolicy {
        MessageDeliveryRetryPolicy(
            maximumRetryCount: queue.configuration.maxRetryCount,
            retryInterval: queue.configuration.retryInterval,
            backoffFactor: queue.configuration.retryBackoffFactor
        )
    }

    private func bootstrapUnifiedRepository() async {
        do {
            try applyUnifiedSnapshot(
                try await unifiedRuntime.bootstrap()
            )
            startUnifiedMaintenanceLoop()
            for deviceID in onlineDeviceIDs {
                scheduleUnifiedWorker(for: deviceID)
            }
        } catch {
            logger.error("Unified device-message repository bootstrap failed")
        }
    }

    private func startUnifiedMaintenanceLoop() {
        guard unifiedMaintenanceTask == nil else { return }
        unifiedMaintenanceTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(
                        nanoseconds: Self.maintenanceIntervalNanoseconds
                    )
                } catch {
                    return
                }
                guard let self else { return }
                do {
                    try self.applyUnifiedSnapshot(
                        try await self.unifiedRuntime.requeueExpiredReceipts(
                            retryPolicy: self.unifiedRetryPolicy
                        )
                    )
                    for deviceID in self.onlineDeviceIDs {
                        self.scheduleUnifiedWorker(for: deviceID)
                    }
                } catch {
                    self.logger.error(
                        "Unified device-message receipt maintenance failed"
                    )
                }
            }
        }
    }

    private func performUnifiedQueueMutation(
        _ mutation: UnifiedOfflineQueueMutation
    ) async throws {
        let mutationToken = try beginUnifiedQueueMutation()
        do {
            let snapshot: MessageRepositorySnapshot
            switch mutation {
            case .cancel(let queueID):
                let current = try await unifiedRuntime.currentSnapshot()
                if let targetDeviceID = current.deliveryIntents.first(where: {
                    $0.queueID == queueID
                })?.targetDeviceID {
                    try await quiesceUnifiedWorkers(for: Set([targetDeviceID]))
                }
                snapshot = try await unifiedRuntime.cancelDelivery(queueID: queueID)

            case .cancelAll(let targetDeviceID):
                try await quiesceUnifiedWorkers(for: Set([targetDeviceID]))
                snapshot = try await unifiedRuntime.cancelDeliveries(
                    targetDeviceID: targetDeviceID
                )

            case .clear:
                try await quiesceUnifiedWorkers(for: nil)
                snapshot = try await unifiedRuntime.clearDeliveries()

            case .retryFailed:
                let current = try await unifiedRuntime.currentSnapshot()
                let failedDeviceIDs = Set(
                    current.deliveryIntents.lazy
                        .filter { $0.state == .failed }
                        .map(\.targetDeviceID)
                )
                try await quiesceUnifiedWorkers(for: failedDeviceIDs)
                snapshot = try await unifiedRuntime.retryFailedDeliveries()
            }

            try applyUnifiedSnapshot(snapshot)
        } catch {
            finishUnifiedQueueMutation(mutationToken)
            throw error
        }
        finishUnifiedQueueMutation(mutationToken)
    }

    private func beginUnifiedQueueMutation() throws -> UUID {
        guard unifiedQueueMutationToken == nil else {
            throw DeviceMessagingRepositoryError.invalidRecord(
                reasonCode: "coordinated_mutation_in_progress"
            )
        }
        let token = UUID()
        unifiedQueueMutationToken = token
        return token
    }

    private func finishUnifiedQueueMutation(_ token: UUID) {
        guard unifiedQueueMutationToken == token else { return }
        unifiedQueueMutationToken = nil
        for deviceID in onlineDeviceIDs {
            scheduleUnifiedWorker(for: deviceID)
        }
    }

    private func performUnifiedStoreMutation(
        _ mutation: UnifiedDeviceMessageStoreMutation
    ) async throws {
        let snapshot: MessageRepositorySnapshot
        switch mutation {
        case .clearConversation(let fingerprint):
            snapshot = try await unifiedRuntime.clearConversation(fingerprint)
        }
        try applyUnifiedSnapshot(snapshot)
    }

    func cancelUnifiedQueuedDelivery(queueID: String) async throws {
        guard usesUnifiedRepository else { throw DeviceMessagingError.persistenceFailed }
        try await performUnifiedQueueMutation(.cancel(queueID: queueID))
    }

    func cancelAllUnifiedQueuedDeliveries(targetDeviceID: String) async throws {
        guard usesUnifiedRepository else { throw DeviceMessagingError.persistenceFailed }
        try await performUnifiedQueueMutation(.cancelAll(targetDeviceID: targetDeviceID))
    }

    func clearUnifiedQueuedDeliveries() async throws {
        guard usesUnifiedRepository else { throw DeviceMessagingError.persistenceFailed }
        try await performUnifiedQueueMutation(.clear)
    }

    func retryFailedUnifiedQueuedDeliveries() async throws {
        guard usesUnifiedRepository else { throw DeviceMessagingError.persistenceFailed }
        try await performUnifiedQueueMutation(.retryFailed)
    }

    private func quiesceUnifiedWorkers(for targetDeviceIDs: Set<String>?) async throws {
        let selected = unifiedWorkers
            .filter { targetDeviceIDs?.contains($0.key) ?? true }
            .map {
                (
                    deviceID: $0.key,
                    lifecycleToken: $0.value.lifecycleToken,
                    task: $0.value.task
                )
            }
        for worker in selected {
            worker.task.cancel()
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: unifiedWorkerQuiesceTimeout)
        while selected.contains(where: { worker in
            unifiedWorkers[worker.deviceID]?.lifecycleToken == worker.lifecycleToken
        }) {
            guard clock.now < deadline else {
                throw DeviceMessagingRepositoryError.invalidRecord(
                    reasonCode: "worker_quiesce_timeout"
                )
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func sendUsingUnifiedRepository(
        text: String,
        deviceID: String,
        fingerprint: String,
        payload: AppMessage.TextMessagePayload,
        queuedPayload: Data
    ) async throws {
        guard unifiedQueueMutationToken == nil else {
            throw DeviceMessagingError.persistenceFailed
        }
        guard case .ready = queue.configurationPersistenceState else {
            throw DeviceMessagingError.queueRejected(.persistenceFailure)
        }
        let expiresAt = payload.sentAt.addingTimeInterval(queue.configuration.defaultTTL)
        let message = PersistedMessageRecord(
            id: payload.id,
            conversationFingerprint: fingerprint,
            targetDeviceID: deviceID,
            direction: .outgoing,
            text: text,
            timestamp: payload.sentAt,
            deliveryState: .pending
        )
        let intent = PersistedDeliveryIntent(
            queueID: payload.id.uuidString.lowercased(),
            messageID: payload.id,
            targetDeviceID: deviceID,
            messageType: OfflineMessageType.text.rawValue,
            priority: MessagePriority.normal.rawValue,
            payload: queuedPayload,
            createdAt: payload.sentAt,
            expiresAt: expiresAt
        )

        do {
            try applyUnifiedSnapshot(
                try await unifiedRuntime.stageOutgoing(
                    message: message,
                    intent: intent
                )
            )
        } catch {
            throw DeviceMessagingError.persistenceFailed
        }
        if onlineDeviceIDs.contains(deviceID) {
            scheduleUnifiedWorker(for: deviceID)
        }
    }

    private func scheduleUnifiedWorker(for deviceID: String) {
        guard usesUnifiedRepository,
              onlineDeviceIDs.contains(deviceID),
              unifiedQueueMutationToken == nil,
              unifiedWorkers[deviceID] == nil else {
            return
        }
        let lifecycleToken = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runUnifiedWorker(
                deviceID: deviceID,
                lifecycleToken: lifecycleToken
            )
        }
        unifiedWorkers[deviceID] = UnifiedWorker(
            lifecycleToken: lifecycleToken,
            task: task
        )
    }

    private func runUnifiedWorker(deviceID: String, lifecycleToken: UUID) async {
        defer {
            if unifiedWorkers[deviceID]?.lifecycleToken == lifecycleToken {
                unifiedWorkers.removeValue(forKey: deviceID)
                if Task.isCancelled,
                   onlineDeviceIDs.contains(deviceID),
                   unifiedQueueMutationToken == nil {
                    scheduleUnifiedWorker(for: deviceID)
                }
            }
        }
        while onlineDeviceIDs.contains(deviceID), !Task.isCancelled {
            let claim: MessageDeliveryClaim
            do {
                let deliveryAttemptID = UUID()
                guard let next = try await unifiedRuntime.claimNextReady(
                    targetDeviceID: deviceID,
                    ownerToken: deliveryAttemptID,
                    retryPolicy: unifiedRetryPolicy
                ) else {
                    try applyUnifiedSnapshot(
                        try await unifiedRuntime.currentSnapshot()
                    )
                    return
                }
                claim = next
                try applyUnifiedSnapshot(
                    try await unifiedRuntime.currentSnapshot()
                )
            } catch {
                logger.error("Unified device-message claim failed")
                return
            }

            let disposition = await submitUnifiedClaim(claim)
            do {
                try applyUnifiedSnapshot(
                    try await unifiedRuntime.resolve(
                        claim,
                        disposition: disposition,
                        retryPolicy: unifiedRetryPolicy
                    )
                )
            } catch {
                logger.error("Unified device-message disposition persistence failed")
                return
            }
            if case .interrupted = disposition { return }
        }
    }

    private func submitUnifiedClaim(
        _ claim: MessageDeliveryClaim
    ) async -> MessageDeliveryDisposition {
        guard claim.intent.messageType == OfflineMessageType.text.rawValue else {
            return .permanentFailure(failureCode: "invalid_message_type")
        }
        let envelope: DeviceTextQueueEnvelope
        do {
            envelope = try JSONDecoder().decode(
                DeviceTextQueueEnvelope.self,
                from: claim.intent.payload
            )
            guard envelope.payload.id == claim.intent.messageID,
                  try DeviceTextMessagePolicy
                    .normalizedConversationFingerprint(envelope.conversationFingerprint)
                    == envelope.conversationFingerprint,
                  try DeviceTextMessagePolicy
                    .normalizedTargetDeviceIdentifier(claim.intent.targetDeviceID)
                    == claim.intent.targetDeviceID else {
                return .permanentFailure(failureCode: "invalid_payload")
            }
            _ = try DeviceTextMessagePolicy.validatedText(envelope.payload.text)
        } catch {
            return .permanentFailure(failureCode: "invalid_payload")
        }

        do {
            let wirePayload = AppMessage.TextMessagePayload(
                id: envelope.payload.id,
                text: envelope.payload.text,
                sentAt: envelope.payload.sentAt,
                deliveryAttemptID: claim.ownerToken
            )
            try await transport.send(
                claim.intent.targetDeviceID,
                envelope.conversationFingerprint,
                wirePayload
            )
            return .submitted(
                receiptDeadline: Date().addingTimeInterval(Self.receiptTimeout)
            )
        } catch {
            guard !Task.isCancelled else { return .interrupted }
            switch Self.deliveryDisposition(for: error) {
            case .retryable(let code):
                return .retryable(failureCode: code.rawValue)
            case .permanentFailure(let code):
                return .permanentFailure(failureCode: code.rawValue)
            case .cancelled:
                return .interrupted
            case .delivered:
                return .permanentFailure(failureCode: "state_conflict")
            }
        }
    }

    private func applyUnifiedSnapshot(
        _ snapshot: MessageRepositorySnapshot
    ) throws {
        try store.applyUnifiedSnapshot(snapshot)
        try queue.applyUnifiedSnapshot(snapshot)
    }
}
