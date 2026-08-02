import Combine
import Foundation
import SkyBridgeMessagePersistence
import SkyBridgeProtocolCore

@available(iOS 17.0, *)
public enum DeviceMessagingError: Error, LocalizedError, Sendable {
    case emptyText
    case textTooLong(maxCharacters: Int)
    case missingTrustedConversationFingerprint([String])
    case ambiguousTrustedConversationFingerprint([String])
    case invalidQueuedPayload(UUID)
    case authenticatedIdentityMismatch
    case transportFailed(String)
    case persistenceFailed

    public var errorDescription: String? {
        switch self {
        case .emptyText:
            return "Device message text is empty"
        case .textTooLong(let maxCharacters):
            return "Device message text exceeds \(maxCharacters) characters"
        case .missingTrustedConversationFingerprint:
            return "No trusted conversation fingerprint for the selected device"
        case .ambiguousTrustedConversationFingerprint:
            return "Multiple trusted conversation fingerprints matched the selected device"
        case .invalidQueuedPayload(let id):
            return "Queued device message payload is invalid: \(id.uuidString)"
        case .authenticatedIdentityMismatch:
            return "The authenticated peer identity does not match this conversation"
        case .transportFailed:
            return "Device message transport failed"
        case .persistenceFailed:
            return "Device message persistence failed"
        }
    }
}

@available(iOS 17.0, *)
@MainActor
protocol DeviceTextMessageTransport: AnyObject {
    var deviceMessagingActiveConnections: AnyPublisher<[Connection], Never> { get }

    func sendTextMessage(
        to deviceId: String,
        payload: AppMessage.TextMessagePayload,
        expectedConversationFingerprint: String
    ) async throws
}

@available(iOS 17.0, *)
extension P2PConnectionManager: DeviceTextMessageTransport {
    var deviceMessagingActiveConnections: AnyPublisher<[Connection], Never> {
        $activeConnections.eraseToAnyPublisher()
    }
}

@available(iOS 17.0, *)
@MainActor
public final class DeviceMessagingService: ObservableObject {
    public static let shared = DeviceMessagingService()
    public static let maxTextCharacters = DeviceTextMessagePolicy.maximumCharacterCount

    private var started = false
    private var cancellables = Set<AnyCancellable>()
    private var onlineDeviceIds: Set<String> = []
    private struct UnifiedWorker {
        let lifecycleToken: UUID
        let task: Task<Void, Never>
    }

    private let messageStore: DeviceMessageStore
    private let offlineQueue: OfflineMessageQueue
    private let transport: any DeviceTextMessageTransport
    private let usesUnifiedRepository: Bool
    private let unifiedRuntime: IOSUnifiedDeviceMessagingRuntime
    private let unifiedWorkerQuiesceTimeout: Duration
    private var unifiedWorkers: [String: UnifiedWorker] = [:]
    private var unifiedQueueMutationToken: UUID?
    private var unifiedMaintenanceTask: Task<Void, Never>?

    private static let receiptTimeout: TimeInterval = 60
    private static let maintenanceIntervalNanoseconds: UInt64 = 15_000_000_000

    private convenience init() {
        self.init(
            messageStore: .shared,
            offlineQueue: .shared,
            transport: P2PConnectionManager.instance,
            usesUnifiedRepository: true,
            unifiedRuntime: .shared
        )
    }

    init(
        messageStore: DeviceMessageStore,
        offlineQueue: OfflineMessageQueue,
        transport: any DeviceTextMessageTransport,
        usesUnifiedRepository: Bool = false,
        unifiedRuntime: IOSUnifiedDeviceMessagingRuntime = .shared,
        unifiedWorkerQuiesceTimeout: Duration = .seconds(5)
    ) {
        self.messageStore = messageStore
        self.offlineQueue = offlineQueue
        self.transport = transport
        self.usesUnifiedRepository = usesUnifiedRepository
        self.unifiedRuntime = unifiedRuntime
        self.unifiedWorkerQuiesceTimeout = unifiedWorkerQuiesceTimeout
        if usesUnifiedRepository {
            offlineQueue.installUnifiedMutationHandler { [weak self] mutation in
                guard let self else { throw DeviceMessagingError.persistenceFailed }
                try await self.performUnifiedQueueMutation(mutation)
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
        }

        transport.deviceMessagingActiveConnections
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connections in
                self?.syncOnlineDevices(connections)
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
            case .emptyText:
                return "empty_text"
            case .textTooLong:
                return "text_too_long"
            case .missingTrustedConversationFingerprint:
                return "missing_trusted_conversation_fingerprint"
            case .ambiguousTrustedConversationFingerprint:
                return "ambiguous_trusted_conversation_fingerprint"
            case .invalidQueuedPayload:
                return "invalid_queued_payload"
            case .authenticatedIdentityMismatch:
                return "authenticated_identity_mismatch"
            case .transportFailed:
                return "transport_failed"
            case .persistenceFailed:
                return "persistence_failed"
            }
        }

        if let error = error as? DeviceMessageStoreError {
            switch error {
            case .invalidConversationFingerprint:
                return "invalid_conversation_fingerprint"
            case .invalidMessageContent:
                return OfflineDeliveryFailureCode.invalidPayload.rawValue
            case .messageStateConflict:
                return OfflineDeliveryFailureCode.stateConflict.rawValue
            case .messageNotFound:
                return "message_not_found"
            case .conversationCapacityExceeded,
                    .pendingOutgoingMessagesPreventClear:
                return OfflineDeliveryFailureCode.stateConflict.rawValue
            case .storageCapacityExceeded:
                return OfflineDeliveryFailureCode.storageCapacityExceeded.rawValue
            case .persistenceFailed:
                return "persistence_failed"
            }
        }

        if let error = error as? P2PError {
            switch error {
            case .connectionFailed:
                return "connection_failed"
            case .noSessionKey:
                return "no_session_key"
            case .encryptionFailed:
                return "encryption_failed"
            case .authenticatedIdentityMismatch:
                return "authenticated_identity_mismatch"
            default:
                return "p2p_error"
            }
        }

        if let error = error as? OfflineMessageQueueError {
            switch error {
            case .capacityExceeded:
                return OfflineDeliveryFailureCode.queueCapacityExceeded.rawValue
            case .invalidTargetDeviceIdentifier:
                return "invalid_target_device_identifier"
            case .messageTooLarge:
                return "offline_queue_message_too_large"
            case .messageNotFound:
                return "offline_queue_message_not_found"
            case .storageCapacityExceeded:
                return OfflineDeliveryFailureCode.storageCapacityExceeded.rawValue
            case .persistenceFailed:
                return "offline_queue_persistence_failed"
            case .stateConflict:
                return "offline_queue_state_conflict"
            }
        }

        return String(describing: type(of: error))
    }

    public func conversationFingerprint(for device: DiscoveredDevice) throws -> String {
        var identifiers = [device.id]
        if let ipAddress = device.ipAddress {
            identifiers.append(ipAddress)
        }
        if let bonjourServiceName = device.bonjourServiceName {
            identifiers.append(bonjourServiceName)
        }
        return try uniqueConversationFingerprint(forAny: identifiers)
    }

    public func send(text rawText: String, to device: DiscoveredDevice) async throws {
        let fingerprint = try conversationFingerprint(for: device)
        try await send(text: rawText, toDeviceId: device.id, conversationFingerprint: fingerprint)
    }

    public func send(
        text rawText: String,
        toDeviceId rawDeviceId: String,
        conversationFingerprint rawFingerprint: String
    ) async throws {
        let text = try validatedText(rawText)
        let deviceId = try DeviceTextMessagePolicy.normalizedTargetDeviceIdentifier(rawDeviceId)
        let conversationFingerprint = try validConversationFingerprint(rawFingerprint)
        let payload = AppMessage.TextMessagePayload(text: text)
        let queuedPayload = try encodedQueuePayload(
            payload,
            conversationFingerprint: conversationFingerprint
        )

        if usesUnifiedRepository {
            try await stageUsingUnifiedRepository(
                text: text,
                deviceId: deviceId,
                conversationFingerprint: conversationFingerprint,
                payload: payload,
                queuedPayload: queuedPayload
            )
            return
        }

        try messageStore.appendOutgoing(
            text: text,
            conversationFingerprint: conversationFingerprint,
            messageId: payload.id,
            sentAt: payload.sentAt
        )

        do {
            try await transport.sendTextMessage(
                to: deviceId,
                payload: payload,
                expectedConversationFingerprint: conversationFingerprint
            )
        } catch is CancellationError {
            try markOutgoingFailedAfterTerminalSendError(
                messageId: payload.id,
                conversationFingerprint: conversationFingerprint
            )
            throw CancellationError()
        } catch P2PError.connectionFailed,
                P2PError.noSessionKey,
                P2PError.staleConnectionIncarnation {
            try enqueueOfflineTextMessage(
                deviceId: deviceId,
                queuedPayload: queuedPayload,
                messageId: payload.id,
                conversationFingerprint: conversationFingerprint
            )
            return
        } catch P2PError.authenticatedIdentityMismatch {
            try markOutgoingFailedAfterTerminalSendError(
                messageId: payload.id,
                conversationFingerprint: conversationFingerprint
            )
            throw DeviceMessagingError.authenticatedIdentityMismatch
        } catch {
            try markOutgoingFailedAfterTerminalSendError(
                messageId: payload.id,
                conversationFingerprint: conversationFingerprint
            )
            throw DeviceMessagingError.transportFailed(Self.logSafeErrorSummary(error))
        }

        try messageStore.markSent(
            messageId: payload.id,
            conversationFingerprint: conversationFingerprint
        )
    }

    private func enqueueOfflineTextMessage(
        deviceId: String,
        queuedPayload: Data,
        messageId: UUID,
        conversationFingerprint: String
    ) throws {
        do {
            try offlineQueue.enqueue(
                targetDeviceId: deviceId,
                messageType: .text,
                payload: queuedPayload
            )
        } catch let queueError as OfflineMessageQueueError {
            try markOutgoingFailedAfterTerminalSendError(
                messageId: messageId,
                conversationFingerprint: conversationFingerprint
            )
            throw queueError
        } catch {
            try markOutgoingFailedAfterTerminalSendError(
                messageId: messageId,
                conversationFingerprint: conversationFingerprint
            )
            throw DeviceMessagingError.transportFailed(Self.logSafeErrorSummary(error))
        }
    }

    private func markOutgoingFailedAfterTerminalSendError(
        messageId: UUID,
        conversationFingerprint: String
    ) throws {
        try messageStore.markFailed(
            messageId: messageId,
            conversationFingerprint: conversationFingerprint
        )
    }

    public func handleIncoming(
        _ payload: AppMessage.TextMessagePayload,
        conversationFingerprint rawFingerprint: String
    ) async throws {
        let text = try validatedText(payload.text)
        let conversationFingerprint = try validConversationFingerprint(rawFingerprint)
        if usesUnifiedRepository {
            do {
                try applyUnifiedSnapshot(
                    try await unifiedRuntime.recordIncoming(PersistedMessageRecord(
                        id: payload.id,
                        conversationFingerprint: conversationFingerprint,
                        targetDeviceID: nil,
                        direction: .incoming,
                        text: text,
                        timestamp: payload.sentAt,
                        deliveryState: .delivered
                    ))
                )
                return
            } catch {
                throw DeviceMessagingError.persistenceFailed
            }
        }
        try messageStore.receiveIncoming(
            text: text,
            conversationFingerprint: conversationFingerprint,
            messageId: payload.id,
            sentAt: payload.sentAt
        )
    }

    public func handleAuthenticatedReceipt(
        _ payload: AppMessage.TextMessageReceiptPayload,
        conversationFingerprint rawFingerprint: String
    ) async throws {
        guard usesUnifiedRepository else {
            throw DeviceMessagingError.persistenceFailed
        }
        let fingerprint = try validConversationFingerprint(rawFingerprint)
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

    private func syncOnlineDevices(_ connections: [Connection]) {
        let connected = Set(connections.filter { $0.status == .connected }.map(\.device.id))
        let newlyOnline = connected.subtracting(onlineDeviceIds)
        let wentOffline = onlineDeviceIds.subtracting(connected)
        onlineDeviceIds = connected

        if usesUnifiedRepository {
            for deviceId in wentOffline {
                unifiedWorkers[deviceId]?.task.cancel()
            }
            for deviceId in newlyOnline {
                scheduleUnifiedWorker(for: deviceId)
            }
            return
        }

        for deviceId in newlyOnline {
            do {
                try offlineQueue.onDeviceOnline(deviceId) { [weak self] message in
                    await self?.deliverQueuedMessage(message) ?? .cancelled
                }
            } catch {
                SkyBridgeLogger.shared.error(
                    "Device message online flush refused: \(Self.logSafeErrorSummary(error))"
                )
            }
        }

        for deviceId in wentOffline {
            do {
                try offlineQueue.onDeviceOffline(deviceId)
                try offlineQueue.cleanupExpiredMessages()
            } catch {
                SkyBridgeLogger.shared.error(
                    "Device message offline cleanup failed: \(Self.logSafeErrorSummary(error))"
                )
            }
            SkyBridgeLogger.shared.info("Device message peer offline")
        }
    }

    private var unifiedRetryPolicy: MessageDeliveryRetryPolicy {
        MessageDeliveryRetryPolicy(
            maximumRetryCount: OfflineMessageQueue.maximumRetryCount,
            retryInterval: 60,
            backoffFactor: 2
        )
    }

    private func bootstrapUnifiedRepository() async {
        do {
            try applyUnifiedSnapshot(try await unifiedRuntime.bootstrap())
            startUnifiedMaintenanceLoop()
            for deviceId in onlineDeviceIds {
                scheduleUnifiedWorker(for: deviceId)
            }
        } catch {
            SkyBridgeLogger.shared.error("Unified device-message repository bootstrap failed")
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
                    for deviceId in self.onlineDeviceIds {
                        self.scheduleUnifiedWorker(for: deviceId)
                    }
                } catch {
                    SkyBridgeLogger.shared.error(
                        "Unified device-message receipt maintenance failed"
                    )
                }
            }
        }
    }

    private func performUnifiedQueueMutation(
        _ mutation: IOSUnifiedOfflineQueueMutation
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

            case .retryFailed(let now):
                let current = try await unifiedRuntime.currentSnapshot()
                let failedDeviceIDs = Set(
                    current.deliveryIntents.lazy
                        .filter { $0.state == .failed }
                        .map(\.targetDeviceID)
                )
                try await quiesceUnifiedWorkers(for: failedDeviceIDs)
                snapshot = try await unifiedRuntime.retryFailedDeliveries(now: now)
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
        for deviceID in onlineDeviceIds {
            scheduleUnifiedWorker(for: deviceID)
        }
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

    func retryFailedUnifiedQueuedDeliveries(now: Date = Date()) async throws {
        guard usesUnifiedRepository else { throw DeviceMessagingError.persistenceFailed }
        try await performUnifiedQueueMutation(.retryFailed(now: now))
    }

    func clearUnifiedConversation(_ fingerprint: String) async throws {
        guard usesUnifiedRepository else { throw DeviceMessagingError.persistenceFailed }
        let normalized = try validConversationFingerprint(fingerprint)
        try applyUnifiedSnapshot(
            try await unifiedRuntime.clearConversation(normalized)
        )
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

    private func stageUsingUnifiedRepository(
        text: String,
        deviceId: String,
        conversationFingerprint: String,
        payload: AppMessage.TextMessagePayload,
        queuedPayload: Data
    ) async throws {
        guard unifiedQueueMutationToken == nil else {
            throw DeviceMessagingError.persistenceFailed
        }
        guard !offlineQueue.isPersistenceBlocked else {
            throw DeviceMessagingError.persistenceFailed
        }
        let message = PersistedMessageRecord(
            id: payload.id,
            conversationFingerprint: conversationFingerprint,
            targetDeviceID: deviceId,
            direction: .outgoing,
            text: text,
            timestamp: payload.sentAt,
            deliveryState: .pending
        )
        let intent = PersistedDeliveryIntent(
            queueID: payload.id.uuidString.lowercased(),
            messageID: payload.id,
            targetDeviceID: deviceId,
            messageType: OfflineMessageType.text.rawValue,
            priority: 1,
            payload: queuedPayload,
            createdAt: payload.sentAt,
            expiresAt: payload.sentAt.addingTimeInterval(24 * 60 * 60)
        )
        do {
            try applyUnifiedSnapshot(
                try await unifiedRuntime.stageOutgoing(message: message, intent: intent)
            )
        } catch {
            throw DeviceMessagingError.persistenceFailed
        }
        if onlineDeviceIds.contains(deviceId) {
            scheduleUnifiedWorker(for: deviceId)
        }
    }

    private func scheduleUnifiedWorker(for deviceId: String) {
        guard usesUnifiedRepository,
              onlineDeviceIds.contains(deviceId),
              unifiedQueueMutationToken == nil,
              unifiedWorkers[deviceId] == nil else {
            return
        }
        let lifecycleToken = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runUnifiedWorker(
                deviceId: deviceId,
                lifecycleToken: lifecycleToken
            )
        }
        unifiedWorkers[deviceId] = UnifiedWorker(
            lifecycleToken: lifecycleToken,
            task: task
        )
    }

    private func runUnifiedWorker(deviceId: String, lifecycleToken: UUID) async {
        defer {
            if unifiedWorkers[deviceId]?.lifecycleToken == lifecycleToken {
                unifiedWorkers.removeValue(forKey: deviceId)
                if Task.isCancelled,
                   onlineDeviceIds.contains(deviceId),
                   unifiedQueueMutationToken == nil {
                    scheduleUnifiedWorker(for: deviceId)
                }
            }
        }
        while onlineDeviceIds.contains(deviceId), !Task.isCancelled {
            let claim: MessageDeliveryClaim
            do {
                let deliveryAttemptID = UUID()
                guard let next = try await unifiedRuntime.claimNextReady(
                    targetDeviceID: deviceId,
                    ownerToken: deliveryAttemptID,
                    retryPolicy: unifiedRetryPolicy
                ) else {
                    try applyUnifiedSnapshot(try await unifiedRuntime.currentSnapshot())
                    return
                }
                claim = next
                try applyUnifiedSnapshot(try await unifiedRuntime.currentSnapshot())
            } catch {
                SkyBridgeLogger.shared.error("Unified device-message claim failed")
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
                SkyBridgeLogger.shared.error("Unified device-message disposition failed")
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
        let envelope: IOSDeviceTextQueueEnvelope
        do {
            envelope = try JSONDecoder().decode(
                IOSDeviceTextQueueEnvelope.self,
                from: claim.intent.payload
            )
            guard envelope.payload.id == claim.intent.messageID,
                  try validConversationFingerprint(envelope.conversationFingerprint)
                    == envelope.conversationFingerprint,
                  try DeviceTextMessagePolicy.normalizedTargetDeviceIdentifier(
                    claim.intent.targetDeviceID
                  ) == claim.intent.targetDeviceID else {
                return .permanentFailure(failureCode: "invalid_payload")
            }
            _ = try validatedText(envelope.payload.text)
        } catch {
            return .permanentFailure(failureCode: "invalid_payload")
        }

        let wirePayload = AppMessage.TextMessagePayload(
            id: envelope.payload.id,
            text: envelope.payload.text,
            sentAt: envelope.payload.sentAt,
            deliveryAttemptID: claim.ownerToken
        )
        do {
            try await transport.sendTextMessage(
                to: claim.intent.targetDeviceID,
                payload: wirePayload,
                expectedConversationFingerprint: envelope.conversationFingerprint
            )
            return .submitted(
                receiptDeadline: Date().addingTimeInterval(Self.receiptTimeout)
            )
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else {
                return .interrupted
            }
            if let p2pError = error as? P2PError {
                switch p2pError {
                case .connectionFailed,
                        .noSessionKey,
                        .staleConnectionIncarnation:
                    return .retryable(failureCode: "transport_unavailable")
                case .authenticatedIdentityMismatch:
                    return .permanentFailure(
                        failureCode: "authenticated_identity_mismatch"
                    )
                default:
                    break
                }
            }
            return .retryable(failureCode: "transport_failure")
        }
    }

    private func applyUnifiedSnapshot(_ snapshot: MessageRepositorySnapshot) throws {
        try messageStore.applyUnifiedSnapshot(snapshot)
        try offlineQueue.applyUnifiedSnapshot(snapshot)
    }

    private func deliverQueuedMessage(
        _ message: OfflineMessage
    ) async -> OfflineDeliveryDisposition {
        guard message.messageType == .text else {
            return .permanentFailure(.invalidMessageType)
        }
        let envelope: IOSDeviceTextQueueEnvelope
        do {
            envelope = try JSONDecoder().decode(
                IOSDeviceTextQueueEnvelope.self,
                from: message.payload
            )
        } catch {
            SkyBridgeLogger.shared.error("Invalid queued device text message payload")
            return .permanentFailure(.invalidPayload)
        }

        let targetDeviceId: String
        let conversationFingerprint: String
        do {
            targetDeviceId = try DeviceTextMessagePolicy.normalizedTargetDeviceIdentifier(
                message.targetDeviceId
            )
            conversationFingerprint = try DeviceTextMessagePolicy
                .normalizedConversationFingerprint(envelope.conversationFingerprint)
            _ = try DeviceTextMessagePolicy.validatedText(envelope.payload.text)
        } catch DeviceTextMessagePolicyError.invalidTargetDeviceIdentifier {
            return .permanentFailure(.invalidTargetDeviceIdentifier)
        } catch DeviceTextMessagePolicyError.invalidConversationFingerprint {
            return .permanentFailure(.invalidConversationFingerprint)
        } catch {
            return .permanentFailure(.invalidPayload)
        }

        do {
            try await transport.sendTextMessage(
                to: targetDeviceId,
                payload: envelope.payload,
                expectedConversationFingerprint: conversationFingerprint
            )
        } catch is CancellationError {
            return .cancelled
        } catch P2PError.connectionFailed,
                P2PError.noSessionKey,
                P2PError.staleConnectionIncarnation {
            guard !Task.isCancelled else { return .cancelled }
            if message.retryCount >= OfflineMessageQueue.maximumRetryCount - 1 {
                do {
                    try markOutgoingFailedAfterTerminalSendError(
                        messageId: envelope.payload.id,
                        conversationFingerprint: conversationFingerprint
                    )
                } catch {
                    return .permanentFailure(.persistenceFailure)
                }
            }
            return .retryable(.transportUnavailable)
        } catch P2PError.authenticatedIdentityMismatch {
            guard !Task.isCancelled else { return .cancelled }
            do {
                try markOutgoingFailedAfterTerminalSendError(
                    messageId: envelope.payload.id,
                    conversationFingerprint: conversationFingerprint
                )
            } catch {
                return .permanentFailure(.persistenceFailure)
            }
            return .permanentFailure(.authenticatedIdentityMismatch)
        } catch {
            guard !Task.isCancelled else { return .cancelled }
            if message.retryCount >= OfflineMessageQueue.maximumRetryCount - 1 {
                do {
                    try markOutgoingFailedAfterTerminalSendError(
                        messageId: envelope.payload.id,
                        conversationFingerprint: conversationFingerprint
                    )
                } catch {
                    return .permanentFailure(.persistenceFailure)
                }
            }
            return .retryable(.transportFailure)
        }

        do {
            try messageStore.markSent(
                messageId: envelope.payload.id,
                conversationFingerprint: conversationFingerprint
            )
            return .delivered
        } catch {
            SkyBridgeLogger.shared.error(
                "Queued device message sent-state persistence failed: \(Self.logSafeErrorSummary(error))"
            )
            return .permanentFailure(.persistenceFailure)
        }
    }

    func deliverQueuedMessageForTesting(
        _ message: OfflineMessage
    ) async -> OfflineDeliveryDisposition {
        await deliverQueuedMessage(message)
    }

    private func encodedQueuePayload(
        _ payload: AppMessage.TextMessagePayload,
        conversationFingerprint: String
    ) throws -> Data {
        try JSONEncoder().encode(
            IOSDeviceTextQueueEnvelope(payload: payload, conversationFingerprint: conversationFingerprint)
        )
    }

    private func uniqueConversationFingerprint(forAny rawIdentifiers: [String]) throws -> String {
        let identifiers = rawIdentifiers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let fingerprints = TrustedDeviceStore.shared.currentPathFingerprints(forAny: identifiers)
        if fingerprints.isEmpty {
            throw DeviceMessagingError.missingTrustedConversationFingerprint(identifiers)
        }
        if fingerprints.count > 1 {
            throw DeviceMessagingError.ambiguousTrustedConversationFingerprint(fingerprints.sorted())
        }
        guard let fingerprint = fingerprints.first else {
            throw DeviceMessagingError.missingTrustedConversationFingerprint(identifiers)
        }
        return try validConversationFingerprint(fingerprint)
    }

    private func validConversationFingerprint(_ raw: String) throws -> String {
        guard let fingerprint = DeviceMessageStore.normalizedConversationFingerprint(raw) else {
            throw DeviceMessageStoreError.invalidConversationFingerprint
        }
        return fingerprint
    }

    private func validatedText(_ raw: String) throws -> String {
        do {
            return try DeviceTextMessagePolicy.validatedText(raw)
        } catch DeviceTextMessagePolicyError.emptyText {
            throw DeviceMessagingError.emptyText
        } catch DeviceTextMessagePolicyError.textTooLong,
                DeviceTextMessagePolicyError.textTooLarge {
            throw DeviceMessagingError.textTooLong(maxCharacters: Self.maxTextCharacters)
        } catch {
            throw DeviceMessagingError.transportFailed("invalid_text_payload")
        }
    }
}
