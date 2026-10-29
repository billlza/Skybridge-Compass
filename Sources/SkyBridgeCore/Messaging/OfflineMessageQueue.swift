import Foundation
import OSLog
import SkyBridgeMessagePersistence
import SkyBridgeProtocolCore

enum UnifiedOfflineQueueMutation: Sendable {
    case cancel(queueID: String)
    case cancelAll(targetDeviceID: String)
    case clear
    case retryFailed
}

/// Durable offline queue with one exact-owner worker per target device.
@MainActor
public final class OfflineMessageQueue: ObservableObject {
    public typealias SendHandler = @MainActor @Sendable (
        _ message: QueuedMessage
    ) async -> OfflineDeliveryDisposition
    typealias ClaimAdmissionGate = @MainActor @Sendable (
        _ claim: OfflineMessageClaim
    ) async -> Void

    public static let shared = OfflineMessageQueue()

    @Published public private(set) var configuration: OfflineQueueConfiguration
    @Published public private(set) var statistics: QueueStatistics = .empty
    @Published public private(set) var isProcessing = false
    @Published public private(set) var persistenceState: OfflineQueuePersistenceState = .loading
    @Published public private(set) var configurationPersistenceState: OfflineQueuePersistenceState

    public var sendHandler: SendHandler?

    private struct DeviceWorker {
        let ownerToken: UUID
        let task: Task<Void, Never>
        let activeClaimMessageID: UUID?
    }

    private static let defaultQueueStore = CodablePersistenceStore<[QueuedMessage]>(
        location: .protectedApplicationSupport(
            path: "OfflineQueue/queue.json",
            legacyUserDefaultsKey: "com.skybridge.offline.queue"
        )
    )
    private static let defaultConfigurationStore: CodablePersistenceStore<OfflineQueueConfiguration> = {
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        return CodablePersistenceStore<OfflineQueueConfiguration>(
            location: .protectedApplicationSupport(
                path: "OfflineQueue/configuration.json",
                legacyUserDefaultsKey: "com.skybridge.offline.config"
            ),
            encoder: encoder,
            decoder: decoder
        )
    }()

    private let logger = Logger(subsystem: "com.skybridge.compass", category: "OfflineQueue")
    private let repository: OfflineMessageQueueRepository
    private let usesUnifiedRepository: Bool
    private let configurationStore: CodablePersistenceStore<OfflineQueueConfiguration>
    private let automaticallyStartsProcessing: Bool
    private let claimAdmissionGate: ClaimAdmissionGate?
    private var unifiedMutationHandler: (@MainActor @Sendable (
        UnifiedOfflineQueueMutation
    ) async throws -> Void)?
    private var onlineDevices: Set<String> = []
    private var deviceWorkers: [String: DeviceWorker] = [:]
    private var cancellationRequestedMessageIDs: Set<UUID> = []
    private var cancellationRequestedDeviceIDs: Set<String> = []
    private var isClearingAll = false
    private var periodicProcessingTask: Task<Void, Never>?
    private var bootstrapTask: Task<Void, Never>?
    private var latestRepositoryGeneration: UInt64 = 0
    private var unifiedMessages: [UUID: QueuedMessage] = [:]

    private convenience init() {
        self.init(
            queueStore: Self.defaultQueueStore,
            configurationStore: Self.defaultConfigurationStore,
            automaticallyStartsProcessing: false,
            usesUnifiedRepository: true
        )
    }

    convenience init(
        queueStore: CodablePersistenceStore<[QueuedMessage]>,
        configurationStore: CodablePersistenceStore<OfflineQueueConfiguration>,
        automaticallyStartsProcessing: Bool,
        claimAdmissionGate: ClaimAdmissionGate? = nil
    ) {
        self.init(
            queueStore: queueStore,
            configurationStore: configurationStore,
            automaticallyStartsProcessing: automaticallyStartsProcessing,
            claimAdmissionGate: claimAdmissionGate,
            usesUnifiedRepository: false
        )
    }

    private init(
        queueStore: CodablePersistenceStore<[QueuedMessage]>,
        configurationStore: CodablePersistenceStore<OfflineQueueConfiguration>,
        automaticallyStartsProcessing: Bool,
        claimAdmissionGate: ClaimAdmissionGate? = nil,
        usesUnifiedRepository: Bool
    ) {
        self.repository = OfflineMessageQueueRepository(store: queueStore)
        self.usesUnifiedRepository = usesUnifiedRepository
        self.configurationStore = configurationStore
        self.automaticallyStartsProcessing = automaticallyStartsProcessing
        self.claimAdmissionGate = claimAdmissionGate

        do {
            let loadedConfiguration = try configurationStore.loadOrThrow() ?? .default
            try loadedConfiguration.validate()
            self.configuration = loadedConfiguration
            self.configurationPersistenceState = .ready
        } catch is OfflineQueueError {
            self.configuration = .default
            self.configurationPersistenceState = .blocked(.stateConflict)
        } catch {
            self.configuration = .default
            self.configurationPersistenceState = .blocked(.persistenceFailure)
        }

        bootstrapTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.bootstrap()
        }
    }

    @discardableResult
    public func enqueue(
        targetDeviceID rawTargetDeviceID: String,
        messageType: OfflineMessageType,
        priority: MessagePriority = .normal,
        payload: Data,
        ttl: TimeInterval? = nil
    ) async throws -> QueuedMessage {
        guard !usesUnifiedRepository else {
            throw OfflineQueueError.coordinatedRetryRequired
        }
        try requireConfigurationReady()
        let targetDeviceID = try DeviceTextMessagePolicy.normalizedTargetDeviceIdentifier(
            rawTargetDeviceID
        )
        guard !payload.isEmpty else {
            throw OfflineQueueError.invalidPayload
        }
        guard payload.count <= QueuedMessage.maximumPayloadBytes else {
            throw OfflineQueueError.messageTooLarge(
                size: payload.count,
                maxSize: QueuedMessage.maximumPayloadBytes
            )
        }
        let effectiveTTL = ttl
            ?? (priority == .urgent ? configuration.urgentTTL : configuration.defaultTTL)
        guard effectiveTTL > 0,
              effectiveTTL.isFinite || effectiveTTL == .infinity else {
            throw OfflineQueueError.invalidConfiguration
        }
        let message = QueuedMessage(
            targetDeviceID: targetDeviceID,
            messageType: messageType,
            priority: priority,
            payload: payload,
            ttl: effectiveTTL
        )
        try await applyRepositoryMutation {
            try await repository.enqueue(message, configuration: configuration)
        }
        logger.info("📬 offline message enqueued: message_ref=\(message.id.uuidString, privacy: .public)")
        if onlineDevices.contains(targetDeviceID) {
            scheduleProcessing(for: targetDeviceID)
        }
        return message
    }

    public func enqueueBatch(
        _ messages: [(
            targetDeviceID: String,
            messageType: OfflineMessageType,
            priority: MessagePriority,
            payload: Data
        )]
    ) async throws -> [QueuedMessage] {
        guard !usesUnifiedRepository else {
            throw OfflineQueueError.coordinatedRetryRequired
        }
        try requireConfigurationReady()
        var queuedMessages: [QueuedMessage] = []
        queuedMessages.reserveCapacity(messages.count)
        for message in messages {
            let deviceID = try DeviceTextMessagePolicy.normalizedTargetDeviceIdentifier(
                message.targetDeviceID
            )
            guard !message.payload.isEmpty else {
                throw OfflineQueueError.invalidPayload
            }
            guard message.payload.count <= QueuedMessage.maximumPayloadBytes else {
                throw OfflineQueueError.messageTooLarge(
                    size: message.payload.count,
                    maxSize: QueuedMessage.maximumPayloadBytes
                )
            }
            let ttl = message.priority == .urgent
                ? configuration.urgentTTL
                : configuration.defaultTTL
            queuedMessages.append(
                QueuedMessage(
                    targetDeviceID: deviceID,
                    messageType: message.messageType,
                    priority: message.priority,
                    payload: message.payload,
                    ttl: ttl
                )
            )
        }
        try await applyRepositoryMutation {
            try await repository.enqueueBatch(
                queuedMessages,
                configuration: configuration
            )
        }
        for deviceID in Set(queuedMessages.map(\.targetDeviceID))
        where onlineDevices.contains(deviceID) {
            scheduleProcessing(for: deviceID)
        }
        return queuedMessages
    }

    public func cancel(messageID: UUID) async throws {
        try requireConfigurationReady()
        if usesUnifiedRepository {
            try await performUnifiedMutation(
                .cancel(queueID: messageID.uuidString.lowercased())
            )
            logger.info("📬 unified offline message cancelled: message_ref=\(messageID.uuidString, privacy: .public)")
            return
        }
        cancellationRequestedMessageIDs.insert(messageID)
        cancelWorker(holdingClaimFor: messageID)
        defer { cancellationRequestedMessageIDs.remove(messageID) }
        try await applyRepositoryMutation {
            try await repository.cancel(
                messageID: messageID,
                configuration: configuration
            )
        }
        logger.info("📬 offline message cancelled: message_ref=\(messageID.uuidString, privacy: .public)")
    }

    public func cancelAllMessages(for rawDeviceID: String) async throws {
        try requireConfigurationReady()
        let deviceID = try DeviceTextMessagePolicy.normalizedTargetDeviceIdentifier(rawDeviceID)
        if usesUnifiedRepository {
            try await performUnifiedMutation(.cancelAll(targetDeviceID: deviceID))
            logger.info("📬 unified offline messages cancelled for peer")
            return
        }
        cancellationRequestedDeviceIDs.insert(deviceID)
        cancelWorker(for: deviceID)
        defer { cancellationRequestedDeviceIDs.remove(deviceID) }
        try await applyRepositoryMutation {
            try await repository.cancelAll(
                for: deviceID,
                configuration: configuration
            )
        }
        logger.info("📬 offline messages cancelled for peer")
    }

    /// Explicitly clears queued deliveries. Unified mode never treats this as a
    /// corruption-recovery escape hatch; an unavailable SQLite authority stays
    /// blocked and requires a separate quarantine workflow.
    public func clearAll() async throws {
        if usesUnifiedRepository {
            try requireConfigurationReady()
            try await performUnifiedMutation(.clear)
            logger.info("📬 unified offline queue explicitly cleared")
            return
        }
        isClearingAll = true
        cancelAllWorkers()
        defer { isClearingAll = false }
        do {
            apply(try await repository.bootstrap(configuration: configuration))
        } catch let error as OfflineQueueError {
            guard case .persistenceBlocked = error else {
                await refreshFromRepository()
                throw error
            }
            await refreshFromRepository()
        } catch {
            await refreshFromRepository()
            throw error
        }
        try await applyRepositoryMutation {
            try await repository.clearAll()
        }
        logger.info("📬 offline queue explicitly cleared")
    }

    public func getPendingMessages(for rawDeviceID: String) async throws -> [QueuedMessage] {
        try requireConfigurationReady()
        let deviceID = try DeviceTextMessagePolicy.normalizedTargetDeviceIdentifier(rawDeviceID)
        if usesUnifiedRepository {
            try applyUnifiedSnapshot(
                try await UnifiedDeviceMessagingRuntime.shared.currentSnapshot()
            )
            return unifiedMessages.values
                .filter { $0.targetDeviceID == deviceID && !$0.status.isTerminal }
                .sorted(by: Self.unifiedDeliveryOrder)
        }
        return try await readRepository {
            try await repository.messagesForDevice(deviceID, configuration: configuration)
        }
    }

    public func getAllPendingMessages() async throws -> [QueuedMessage] {
        try requireConfigurationReady()
        if usesUnifiedRepository {
            try applyUnifiedSnapshot(
                try await UnifiedDeviceMessagingRuntime.shared.currentSnapshot()
            )
            return unifiedMessages.values
                .filter { !$0.status.isTerminal }
                .sorted(by: Self.unifiedDeliveryOrder)
        }
        let messages = try await readRepository {
            try await repository.allMessages(configuration: configuration)
        }
        return messages.filter { !$0.status.isTerminal }
    }

    public func deviceOnline(_ rawDeviceID: String) async {
        if usesUnifiedRepository {
            do {
                let deviceID = try DeviceTextMessagePolicy
                    .normalizedTargetDeviceIdentifier(rawDeviceID)
                try applyUnifiedSnapshot(
                    try await UnifiedDeviceMessagingRuntime.shared.bootstrap()
                )
                onlineDevices.insert(deviceID)
            } catch {
                persistenceState = .blocked(.persistenceFailure)
                logger.error("📬 unified offline queue could not accept online transition")
            }
            return
        }
        do {
            try requireConfigurationReady()
            let deviceID = try DeviceTextMessagePolicy.normalizedTargetDeviceIdentifier(rawDeviceID)
            _ = try await repository.bootstrap(configuration: configuration)
            guard !Task.isCancelled else { return }
            onlineDevices.insert(deviceID)
            scheduleProcessing(for: deviceID)
            logger.info("📬 offline queue peer online")
        } catch {
            await refreshFromRepository()
            logger.error("📬 offline queue could not accept online transition")
        }
    }

    public func deviceOffline(_ rawDeviceID: String) {
        let deviceID: String
        do {
            deviceID = try DeviceTextMessagePolicy
                .normalizedTargetDeviceIdentifier(rawDeviceID)
        } catch {
            logger.error("📬 offline queue rejected invalid offline peer identifier")
            return
        }
        onlineDevices.remove(deviceID)
        if usesUnifiedRepository { return }
        cancelWorker(for: deviceID)
        logger.info("📬 offline queue peer offline")
    }

    public func retryFailed() async throws {
        try requireConfigurationReady()
        if usesUnifiedRepository {
            try await performUnifiedMutation(.retryFailed)
            return
        }
        try await applyRepositoryMutation {
            try await repository.resetFailed(configuration: configuration)
        }
        for deviceID in onlineDevices {
            scheduleProcessing(for: deviceID)
        }
    }

    private func bootstrap() async {
        if usesUnifiedRepository {
            do {
                try applyUnifiedSnapshot(
                    try await UnifiedDeviceMessagingRuntime.shared.bootstrap()
                )
                logger.info("📬 unified offline queue initialized")
            } catch {
                persistenceState = .blocked(.persistenceFailure)
                logger.error("📬 unified offline queue bootstrap blocked")
            }
            return
        }
        do {
            try requireConfigurationReady()
            let snapshot = try await repository.bootstrap(configuration: configuration)
            apply(snapshot)
            if automaticallyStartsProcessing {
                startPeriodicProcessing()
            }
            logger.info("📬 offline queue initialized")
        } catch {
            await refreshFromRepository()
            logger.error("📬 offline queue bootstrap blocked")
        }
    }

    private func startPeriodicProcessing() {
        periodicProcessingTask?.cancel()
        periodicProcessingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.periodicProcessing()
                do {
                    try await Task.sleep(for: .seconds(self.configuration.retryInterval))
                } catch is CancellationError {
                    return
                } catch {
                    self.logger.error("📬 offline queue retry timer failed")
                    return
                }
            }
        }
    }

    private func periodicProcessing() async {
        do {
            try requireConfigurationReady()
            let cleanup = try await repository.cleanupExpired(configuration: configuration)
            apply(cleanup.snapshot)
            if cleanup.removedCount > 0 {
                logger.info("📬 expired offline messages pruned: count=\(cleanup.removedCount, privacy: .public)")
            }
        } catch {
            await refreshFromRepository()
            logger.error("📬 offline queue expiry cleanup blocked")
            return
        }
        for deviceID in onlineDevices {
            scheduleProcessing(for: deviceID)
        }
    }

    private func scheduleProcessing(for deviceID: String) {
        guard !usesUnifiedRepository else { return }
        guard onlineDevices.contains(deviceID),
              !isClearingAll,
              !cancellationRequestedDeviceIDs.contains(deviceID),
              deviceWorkers[deviceID] == nil,
              sendHandler != nil else {
            return
        }
        let ownerToken = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runDeviceWorker(deviceID: deviceID, ownerToken: ownerToken)
        }
        deviceWorkers[deviceID] = DeviceWorker(
            ownerToken: ownerToken,
            task: task,
            activeClaimMessageID: nil
        )
        isProcessing = true
    }

    private func runDeviceWorker(deviceID: String, ownerToken: UUID) async {
        defer {
            let shouldReplaceCancelledWorker = Task.isCancelled
                && onlineDevices.contains(deviceID)
            if deviceWorkers[deviceID]?.ownerToken == ownerToken {
                deviceWorkers.removeValue(forKey: deviceID)
            }
            isProcessing = !deviceWorkers.isEmpty
            if shouldReplaceCancelledWorker {
                scheduleProcessing(for: deviceID)
            }
        }

        while onlineDevices.contains(deviceID), !Task.isCancelled {
            let claim: OfflineMessageClaim
            do {
                guard let nextClaim = try await repository.claimNextReadyMessage(
                    for: deviceID,
                    ownerToken: ownerToken,
                    configuration: configuration
                ) else {
                    await refreshFromRepository()
                    return
                }
                claim = nextClaim
                guard recordActiveClaim(
                    claim.message.id,
                    deviceID: deviceID,
                    ownerToken: ownerToken
                ) else {
                    await restorePendingIfCurrent(claim)
                    return
                }
                await refreshFromRepository()
            } catch {
                await refreshFromRepository()
                logger.error("📬 offline message claim failed")
                return
            }

            if let claimAdmissionGate {
                await claimAdmissionGate(claim)
            }

            let claimIsCurrent: Bool
            do {
                claimIsCurrent = try await repository.isClaimCurrent(
                    claim,
                    configuration: configuration
                )
            } catch {
                clearActiveClaim(
                    claim.message.id,
                    deviceID: deviceID,
                    ownerToken: ownerToken
                )
                await refreshFromRepository()
                logger.error("📬 offline message claim revalidation failed")
                return
            }

            guard claimIsCurrent else {
                clearActiveClaim(
                    claim.message.id,
                    deviceID: deviceID,
                    ownerToken: ownerToken
                )
                await refreshFromRepository()
                return
            }

            guard isSendAllowed(
                claim: claim,
                deviceID: deviceID,
                ownerToken: ownerToken
            ), let sendHandler else {
                await restorePendingIfCurrent(claim)
                clearActiveClaim(
                    claim.message.id,
                    deviceID: deviceID,
                    ownerToken: ownerToken
                )
                return
            }

            let disposition = await sendHandler(claim.message)
            do {
                let snapshot = try await repository.resolve(
                    claim,
                    disposition: disposition,
                    configuration: configuration
                )
                apply(snapshot)
                clearActiveClaim(
                    claim.message.id,
                    deviceID: deviceID,
                    ownerToken: ownerToken
                )
            } catch {
                clearActiveClaim(
                    claim.message.id,
                    deviceID: deviceID,
                    ownerToken: ownerToken
                )
                await refreshFromRepository()
                logger.error("📬 offline message disposition persistence failed")
                return
            }

            switch disposition {
            case .cancelled:
                return
            case .delivered, .retryable, .permanentFailure:
                continue
            }
        }
    }

    private func cancelWorker(for deviceID: String) {
        deviceWorkers[deviceID]?.task.cancel()
    }

    private func cancelWorker(holdingClaimFor messageID: UUID) {
        for worker in deviceWorkers.values where worker.activeClaimMessageID == messageID {
            worker.task.cancel()
        }
    }

    private func cancelAllWorkers() {
        for worker in deviceWorkers.values {
            worker.task.cancel()
        }
    }

    private func recordActiveClaim(
        _ messageID: UUID,
        deviceID: String,
        ownerToken: UUID
    ) -> Bool {
        guard let worker = deviceWorkers[deviceID],
              worker.ownerToken == ownerToken,
              worker.activeClaimMessageID == nil else {
            return false
        }
        deviceWorkers[deviceID] = DeviceWorker(
            ownerToken: ownerToken,
            task: worker.task,
            activeClaimMessageID: messageID
        )
        return true
    }

    private func clearActiveClaim(
        _ messageID: UUID,
        deviceID: String,
        ownerToken: UUID
    ) {
        guard let worker = deviceWorkers[deviceID],
              worker.ownerToken == ownerToken,
              worker.activeClaimMessageID == messageID else {
            return
        }
        deviceWorkers[deviceID] = DeviceWorker(
            ownerToken: ownerToken,
            task: worker.task,
            activeClaimMessageID: nil
        )
    }

    private func isSendAllowed(
        claim: OfflineMessageClaim,
        deviceID: String,
        ownerToken: UUID
    ) -> Bool {
        guard !Task.isCancelled,
              onlineDevices.contains(deviceID),
              !isClearingAll,
              !cancellationRequestedMessageIDs.contains(claim.message.id),
              !cancellationRequestedDeviceIDs.contains(deviceID),
              let worker = deviceWorkers[deviceID],
              worker.ownerToken == ownerToken,
              worker.activeClaimMessageID == claim.message.id else {
            return false
        }
        return true
    }

    private func restorePendingIfCurrent(_ claim: OfflineMessageClaim) async {
        do {
            guard try await repository.isClaimCurrent(
                claim,
                configuration: configuration
            ) else {
                await refreshFromRepository()
                return
            }
            apply(
                try await repository.resolve(
                    claim,
                    disposition: .cancelled,
                    configuration: configuration
                )
            )
        } catch let error as OfflineQueueError {
            if case .staleClaim = error {
                await refreshFromRepository()
                return
            }
            await refreshFromRepository()
            logger.error("📬 offline message cancellation persistence failed")
        } catch {
            await refreshFromRepository()
            logger.error("📬 offline message cancellation persistence failed")
        }
    }

    private func apply(_ snapshot: OfflineMessageQueueSnapshot) {
        guard snapshot.generation >= latestRepositoryGeneration else { return }
        latestRepositoryGeneration = snapshot.generation
        statistics = snapshot.statistics
        persistenceState = snapshot.persistenceState
    }

    func installUnifiedMutationHandler(
        _ handler: @escaping @MainActor @Sendable (
            UnifiedOfflineQueueMutation
        ) async throws -> Void
    ) {
        guard usesUnifiedRepository else { return }
        unifiedMutationHandler = handler
    }

    private func performUnifiedMutation(
        _ mutation: UnifiedOfflineQueueMutation
    ) async throws {
        guard let unifiedMutationHandler else {
            throw OfflineQueueError.coordinatedRetryRequired
        }
        do {
            try await unifiedMutationHandler(mutation)
        } catch let error as DeviceMessagingRepositoryError {
            switch error {
            case .messageNotFound(let messageID):
                throw OfflineQueueError.messageNotFound(id: messageID)
            case .intentNotFound(let queueID):
                guard let messageID = UUID(uuidString: queueID) else {
                    throw OfflineQueueError.persistenceBlocked(.stateConflict)
                }
                throw OfflineQueueError.messageNotFound(id: messageID)
            case .invalidRecord(let reasonCode)
                    where reasonCode == "in_flight_delivery_prevents_cancel":
                throw OfflineQueueError.coordinatedRetryRequired
            case .invalidRecord(let reasonCode)
                    where reasonCode == "delivery_intent_capacity_exceeded":
                throw OfflineQueueError.queueFull
            default:
                throw OfflineQueueError.persistenceBlocked(.persistenceFailure)
            }
        } catch let error as OfflineQueueError {
            throw error
        } catch {
            throw OfflineQueueError.persistenceBlocked(.persistenceFailure)
        }
    }

    func applyUnifiedSnapshot(_ snapshot: MessageRepositorySnapshot) throws {
        guard snapshot.generation >= latestRepositoryGeneration else { return }
        var mapped: [UUID: QueuedMessage] = [:]
        mapped.reserveCapacity(snapshot.deliveryIntents.count)
        for intent in snapshot.deliveryIntents {
            let message = try Self.projectedQueuedMessage(from: intent)
            mapped[message.id] = message
        }
        latestRepositoryGeneration = snapshot.generation
        unifiedMessages = mapped
        refreshUnifiedProjectionOutputs()
    }

    /// Applies the exact rows one committed repository transaction changed.
    /// A change whose basis matches the projection applies incrementally; a
    /// change that does not advance past the projection is already reflected;
    /// a generation gap or diverged content requires the caller to reapply a
    /// full snapshot, which is the defined repair protocol, not a fallback.
    func applyUnifiedChange(
        _ change: MessageRepositoryChange
    ) throws -> UnifiedProjectionApplication {
        guard change.basisGeneration == latestRepositoryGeneration else {
            return change.generation <= latestRepositoryGeneration
                ? .alreadyReflected
                : .requiresResynchronization
        }
        guard change.generation > change.basisGeneration || change.isEmpty else {
            return .requiresResynchronization
        }
        var mapped = unifiedMessages
        for queueID in change.removedDeliveryIntentQueueIDs {
            guard let id = UUID(uuidString: queueID) else {
                throw OfflineQueueError.persistenceBlocked(.stateConflict)
            }
            guard mapped.removeValue(forKey: id) != nil else {
                return .requiresResynchronization
            }
        }
        for intent in change.upsertedDeliveryIntents {
            let message = try Self.projectedQueuedMessage(from: intent)
            mapped[message.id] = message
        }
        latestRepositoryGeneration = change.generation
        unifiedMessages = mapped
        refreshUnifiedProjectionOutputs()
        return .applied
    }

    private func refreshUnifiedProjectionOutputs() {
        statistics = Self.unifiedStatistics(Array(unifiedMessages.values))
        isProcessing = unifiedMessages.values.contains { $0.status == .sending }
        persistenceState = .ready
    }

    private static func projectedQueuedMessage(
        from intent: PersistedDeliveryIntent
    ) throws -> QueuedMessage {
        guard let id = UUID(uuidString: intent.queueID),
              let messageType = OfflineMessageType(rawValue: intent.messageType),
              let priority = MessagePriority(rawValue: intent.priority) else {
            throw OfflineQueueError.persistenceBlocked(.stateConflict)
        }
        let status: MessageDeliveryStatus
        switch intent.state {
        case .pending: status = .pending
        case .sending: status = .sending
        case .awaitingReceipt: status = .awaitingReceipt
        case .failed: status = .failed
        }
        let failureCode = intent.failureCode.flatMap(OfflineDeliveryFailureCode.init(rawValue:))
            ?? (intent.failureCode == nil ? nil : .stateConflict)
        return QueuedMessage(
            id: id,
            targetDeviceID: intent.targetDeviceID,
            messageType: messageType,
            priority: priority,
            payload: intent.payload,
            createdAt: intent.createdAt,
            expiresAt: intent.expiresAt ?? .distantFuture,
            status: status,
            retryCount: intent.retryCount,
            lastAttemptAt: intent.lastAttemptAt,
            lastFailureCode: failureCode
        )
    }

    private static func unifiedDeliveryOrder(
        _ lhs: QueuedMessage,
        _ rhs: QueuedMessage
    ) -> Bool {
        if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func unifiedStatistics(_ messages: [QueuedMessage]) -> QueueStatistics {
        let now = Date()
        let pending = messages.filter { $0.status == .pending }
        let active = messages.filter { !$0.status.isTerminal }
        var deviceBreakdown: [String: Int] = [:]
        for message in active {
            deviceBreakdown[message.targetDeviceID, default: 0] += 1
        }
        return QueueStatistics(
            totalMessages: messages.count,
            pendingMessages: pending.count,
            sendingMessages: messages.filter {
                $0.status == .sending || $0.status == .awaitingReceipt
            }.count,
            deliveredMessages: messages.filter { $0.status == .delivered }.count,
            failedMessages: messages.filter { $0.status == .failed }.count,
            expiredMessages: messages.filter { $0.status == .expired }.count,
            deviceBreakdown: deviceBreakdown,
            averageWaitTime: pending.isEmpty
                ? 0
                : pending.reduce(0) { $0 + now.timeIntervalSince($1.createdAt) }
                    / Double(pending.count),
            oldestMessageAge: active.map { now.timeIntervalSince($0.createdAt) }.max()
        )
    }

    private func refreshFromRepository() async {
        apply(await repository.currentSnapshot())
    }

    private func applyRepositoryMutation(
        _ operation: @MainActor () async throws -> OfflineMessageQueueSnapshot
    ) async throws {
        do {
            apply(try await operation())
        } catch {
            await refreshFromRepository()
            throw error
        }
    }

    private func readRepository<Value: Sendable>(
        _ operation: @MainActor () async throws -> Value
    ) async throws -> Value {
        do {
            return try await operation()
        } catch {
            await refreshFromRepository()
            throw error
        }
    }

    public func updateConfiguration(_ updated: OfflineQueueConfiguration) throws {
        try requireConfigurationReady()
        do {
            try updated.validate()
            try configurationStore.save(updated)
            configuration = updated
            if automaticallyStartsProcessing {
                startPeriodicProcessing()
            }
        } catch let error as OfflineQueueError {
            throw error
        } catch {
            configurationPersistenceState = .blocked(.persistenceFailure)
            periodicProcessingTask?.cancel()
            cancelAllWorkers()
            logger.error("📬 offline queue configuration update rejected")
            throw OfflineQueueError.persistenceBlocked(.persistenceFailure)
        }
    }

    /// Explicit recovery for corrupt configuration bytes. The unreadable
    /// payload is quarantined before a validated default is written.
    public func resetConfigurationForRecovery() async throws {
        guard case .blocked = configurationPersistenceState else { return }
        configurationPersistenceState = .loading
        let store = configurationStore
        do {
            try await CodablePersistenceStoreIOCoordinator.shared.perform(
                identity: store.persistenceIdentity
            ) {
                _ = try store.quarantineExistingPayload()
                try store.save(.default)
            }
            configuration = .default
            configurationPersistenceState = .ready
            await bootstrap()
        } catch {
            configurationPersistenceState = .blocked(.persistenceFailure)
            throw OfflineQueueError.persistenceBlocked(.persistenceFailure)
        }
    }

    private func requireConfigurationReady() throws {
        guard case .ready = configurationPersistenceState else {
            let code: OfflineDeliveryFailureCode
            if case .blocked(let blockedCode) = configurationPersistenceState {
                code = blockedCode
            } else {
                code = .persistenceFailure
            }
            throw OfflineQueueError.persistenceBlocked(code)
        }
    }
}
