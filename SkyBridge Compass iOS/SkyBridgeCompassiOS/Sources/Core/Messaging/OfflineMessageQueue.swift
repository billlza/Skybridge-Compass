import Foundation
import SkyBridgeMessagePersistence
import SkyBridgeProtocolCore

enum IOSUnifiedOfflineQueueMutation: Sendable {
    case cancel(queueID: String)
    case cancelAll(targetDeviceID: String)
    case clear
    case retryFailed(now: Date)
}

public enum OfflineMessageQueueError: Error, LocalizedError, Sendable, Equatable {
    case capacityExceeded(maxMessages: Int)
    case invalidTargetDeviceIdentifier
    case messageTooLarge(size: Int, maxSize: Int)
    case messageNotFound(String)
    case storageCapacityExceeded(actualBytes: Int, maximumBytes: Int)
    case persistenceFailed
    case stateConflict

    public var errorDescription: String? {
        switch self {
        case .capacityExceeded(let maxMessages):
            return "Offline message queue exceeds \(maxMessages) pending messages"
        case .invalidTargetDeviceIdentifier:
            return "Offline message target device identifier is invalid"
        case .messageTooLarge(let size, let maxSize):
            return "Offline message payload contains \(size) bytes; maximum is \(maxSize) bytes"
        case .messageNotFound:
            return "Offline message was not found"
        case .storageCapacityExceeded(let actualBytes, let maximumBytes):
            return "Offline message storage requires \(actualBytes) bytes; maximum is \(maximumBytes) bytes"
        case .persistenceFailed:
            return "Offline message queue persistence failed"
        case .stateConflict:
            return "Offline message queue state conflict"
        }
    }
}

public struct OfflineMessage: Codable, Identifiable, Sendable, Equatable {
    public static let maximumPayloadBytes = 1_048_576

    public let id: String
    public let targetDeviceId: String
    public let messageType: OfflineMessageType
    public let payload: Data
    public let createdAt: Date
    public let expiresAt: Date?
    public var retryCount: Int
    public var lastRetryAt: Date?
    public var status: OfflineMessageStatus
    public var lastFailureCode: OfflineDeliveryFailureCode?

    public init(
        id: String = UUID().uuidString,
        targetDeviceId: String,
        messageType: OfflineMessageType,
        payload: Data,
        createdAt: Date = Date(),
        expiresAt: Date? = nil,
        retryCount: Int = 0,
        lastRetryAt: Date? = nil,
        status: OfflineMessageStatus = .pending,
        lastFailureCode: OfflineDeliveryFailureCode? = nil
    ) {
        self.id = id
        self.targetDeviceId = targetDeviceId
        self.messageType = messageType
        self.payload = payload
        self.createdAt = createdAt
        self.expiresAt = expiresAt ?? createdAt.addingTimeInterval(24 * 60 * 60)
        self.retryCount = retryCount
        self.lastRetryAt = lastRetryAt
        self.status = status
        self.lastFailureCode = lastFailureCode
    }

    public var isExpired: Bool {
        isExpired(at: Date())
    }

    func isExpired(at date: Date) -> Bool {
        guard let expiresAt else { return false }
        return date > expiresAt
    }
}

public enum OfflineMessageType: String, Codable, Sendable {
    case text = "text"
    case fileTransferRequest = "file_transfer_request"
    case connectionRequest = "connection_request"
    case notification = "notification"
    case system = "system"
    case custom = "custom"
}

public enum OfflineMessageStatus: String, Codable, Sendable {
    case pending = "pending"
    case sending = "sending"
    case awaitingReceipt = "awaiting_receipt"
    case sent = "sent"
    case failed = "failed"
    case expired = "expired"

    var isTerminal: Bool {
        switch self {
        case .sent, .failed, .expired:
            return true
        case .pending, .sending, .awaitingReceipt:
            return false
        }
    }
}

@available(iOS 17.0, *)
@MainActor
public final class OfflineMessageQueue: ObservableObject {
    public typealias DeliveryHandler = @MainActor (OfflineMessage) async -> OfflineDeliveryDisposition

    struct StoredMessages: Codable, Equatable {
        let pending: [OfflineMessage]
        let failed: [OfflineMessage]
    }

    private struct DeviceFlushOwner {
        let token: UUID
        let task: Task<Void, Never>
    }

    private struct CapacitySuspension {
        let actualBytes: Int
        let maximumBytes: Int
    }

    public static let shared = OfflineMessageQueue()

    static let maximumPendingMessages = 500
    static let maximumRetainedFailedMessages = 100
    static let maximumRetryCount = 3
    static let maximumPersistenceBytes = 4 * 1_024 * 1_024
    /// Reserved for the retry timestamp, failure code, status, and retry-count
    /// growth that can be persisted after a network submission. Admission and
    /// claim paths reserve this space before any external send side effect.
    static let completionMetadataReserveBytesPerPendingMessage = 256
    private static let maximumIdentifierBytes = 512
    private static let retryInterval: TimeInterval = 60
    private static let defaultPersistence = MessagingPersistence(
        store: CodablePersistenceStore<StoredMessages>(
            location: .protectedApplicationSupport(
                path: "Messaging/offline-message-queue.json",
                legacyUserDefaultsKey: "offline_message_queue"
            ),
            maximumPayloadBytes: maximumPersistenceBytes
        )
    )

    @Published public private(set) var pendingMessages: [OfflineMessage] = []
    @Published public private(set) var failedMessages: [OfflineMessage] = []
    @Published public private(set) var totalCount = 0
    @Published public private(set) var lastPersistenceError: String?
    @Published public private(set) var isPersistenceBlocked = false

    private let persistence: MessagingPersistence<StoredMessages>
    private let usesUnifiedRepository: Bool
    private let now: () -> Date
    private let retryTimerEnabled: Bool
    private var latestRepositoryGeneration: UInt64 = 0
    private var retryTimer: Timer?
    private var onlineDeviceIds: Set<String> = []
    private var flushOwnerByDeviceId: [String: DeviceFlushOwner] = [:]
    private var ownersCancelledForOffline: Set<UUID> = []
    private var capacitySuspensionByDeviceId: [String: CapacitySuspension] = [:]
    private var deliveryHandlerByDeviceId: [String: DeliveryHandler] = [:]
    private var unifiedMutationHandler: (@MainActor @Sendable (
        IOSUnifiedOfflineQueueMutation
    ) async throws -> Void)?

    private init() {
        persistence = Self.defaultPersistence
        usesUnifiedRepository = true
        now = Date.init
        retryTimerEnabled = false
        Task { @MainActor [weak self] in
            await self?.bootstrapUnifiedRepository()
        }
    }

    init(
        testingPersistence: MessagingPersistence<StoredMessages>,
        now: @escaping () -> Date = Date.init,
        startRetryTimer: Bool = false
    ) {
        persistence = testingPersistence
        usesUnifiedRepository = false
        self.now = now
        retryTimerEnabled = startRetryTimer
        loadFromStorage()
        if startRetryTimer, !isPersistenceBlocked {
            self.startRetryTimer()
        }
    }

    public func enqueue(_ message: OfflineMessage) throws {
        guard !usesUnifiedRepository else {
            throw OfflineMessageQueueError.stateConflict
        }
        let targetDeviceId = try normalizedTargetDeviceId(message.targetDeviceId)
        guard targetDeviceId == message.targetDeviceId else {
            throw OfflineMessageQueueError.invalidTargetDeviceIdentifier
        }
        try Self.validateMessageMetadata(message)
        guard pendingMessages.count < Self.maximumPendingMessages else {
            throw OfflineMessageQueueError.capacityExceeded(
                maxMessages: Self.maximumPendingMessages
            )
        }
        guard !containsMessage(id: message.id) else {
            throw OfflineMessageQueueError.stateConflict
        }

        var candidate = message
        candidate.status = .pending
        candidate.retryCount = 0
        candidate.lastRetryAt = nil
        candidate.lastFailureCode = nil
        var nextPending = pendingMessages
        nextPending.append(candidate)
        try requireCompletionPersistenceCapacity(
            pending: nextPending,
            failed: failedMessages
        )
        try commit(pending: nextPending, failed: failedMessages)
        SkyBridgeLogger.shared.info("📬 消息已加入离线队列")
    }

    public func enqueue(
        targetDeviceId: String,
        messageType: OfflineMessageType,
        payload: Data,
        expiresIn: TimeInterval? = nil
    ) throws {
        let targetDeviceId = try normalizedTargetDeviceId(targetDeviceId)
        try enqueue(
            OfflineMessage(
                targetDeviceId: targetDeviceId,
                messageType: messageType,
                payload: payload,
                createdAt: now(),
                expiresAt: expiresIn.map { now().addingTimeInterval($0) }
            )
        )
    }

    public func getMessages(for deviceId: String) -> [OfflineMessage] {
        pendingMessages.filter {
            $0.targetDeviceId == deviceId
                && $0.status == .pending
                && !$0.isExpired(at: now())
        }
    }

    func markAsSent(_ messageId: String) throws {
        guard !usesUnifiedRepository else {
            throw OfflineMessageQueueError.stateConflict
        }
        guard let index = pendingMessages.firstIndex(where: { $0.id == messageId }) else {
            throw OfflineMessageQueueError.messageNotFound(messageId)
        }
        guard pendingMessages[index].status != .sending else {
            throw OfflineMessageQueueError.stateConflict
        }
        var nextPending = pendingMessages
        nextPending.remove(at: index)
        try commit(pending: nextPending, failed: failedMessages)
    }

    /// Compatibility entry point for explicit retryable failure recording.
    func markAsFailed(_ messageId: String) throws {
        guard !usesUnifiedRepository else {
            throw OfflineMessageQueueError.stateConflict
        }
        guard let message = pendingMessages.first(where: { $0.id == messageId }) else {
            throw OfflineMessageQueueError.messageNotFound(messageId)
        }
        guard message.status != .sending else {
            throw OfflineMessageQueueError.stateConflict
        }
        try recordRetryableFailure(messageId, code: .transportFailure)
    }

    func retryFailedMessages() throws {
        guard !usesUnifiedRepository else {
            throw OfflineMessageQueueError.stateConflict
        }
        // Text delivery has a second durable projection in DeviceMessageStore.
        // Retrying it here alone would leave that projection terminal and make
        // the next successful transport submission impossible to reconcile.
        guard failedMessages.allSatisfy({ $0.messageType != .text }) else {
            throw OfflineMessageQueueError.stateConflict
        }
        let available = Self.maximumPendingMessages - pendingMessages.count
        guard failedMessages.count <= available else {
            throw OfflineMessageQueueError.capacityExceeded(
                maxMessages: Self.maximumPendingMessages
            )
        }
        let recovered = failedMessages.map { message -> OfflineMessage in
            var message = message
            message.retryCount = 0
            message.lastRetryAt = nil
            message.status = .pending
            message.lastFailureCode = nil
            return message
        }
        try requireCompletionPersistenceCapacity(
            pending: pendingMessages + recovered,
            failed: []
        )
        try commit(pending: pendingMessages + recovered, failed: [])
    }

    /// Unified production mutation APIs are asynchronous because SQLite is
    /// actor-isolated. The legacy synchronous methods above remain only for the
    /// injected JSON test backend and cannot become a second production writer.
    public func cancelUnifiedDelivery(queueID: String) async throws {
        guard usesUnifiedRepository else {
            throw OfflineMessageQueueError.stateConflict
        }
        try await performUnifiedMutation(.cancel(queueID: queueID))
    }

    public func cancelAllUnifiedDeliveries(for rawDeviceID: String) async throws {
        guard usesUnifiedRepository else {
            throw OfflineMessageQueueError.stateConflict
        }
        let deviceID = try normalizedTargetDeviceId(rawDeviceID)
        try await performUnifiedMutation(.cancelAll(targetDeviceID: deviceID))
    }

    public func clearUnifiedDeliveries() async throws {
        guard usesUnifiedRepository else {
            throw OfflineMessageQueueError.stateConflict
        }
        try await performUnifiedMutation(.clear)
    }

    public func retryUnifiedFailedDeliveries() async throws {
        guard usesUnifiedRepository else {
            throw OfflineMessageQueueError.stateConflict
        }
        try await performUnifiedMutation(.retryFailed(now: now()))
    }

    func remove(_ messageId: String) throws {
        guard !usesUnifiedRepository else {
            throw OfflineMessageQueueError.stateConflict
        }
        if pendingMessages.contains(where: { $0.id == messageId && $0.status == .sending }) {
            throw OfflineMessageQueueError.stateConflict
        }
        let nextPending = pendingMessages.filter { $0.id != messageId }
        let nextFailed = failedMessages.filter { $0.id != messageId }
        guard nextPending.count != pendingMessages.count
                || nextFailed.count != failedMessages.count else {
            throw OfflineMessageQueueError.messageNotFound(messageId)
        }
        try commit(pending: nextPending, failed: nextFailed)
    }

    func clear() throws {
        guard !usesUnifiedRepository else {
            throw OfflineMessageQueueError.stateConflict
        }
        let owners = Array(flushOwnerByDeviceId.values)
        try commit(pending: [], failed: [])
        flushOwnerByDeviceId.removeAll()
        ownersCancelledForOffline.removeAll()
        capacitySuspensionByDeviceId.removeAll()
        deliveryHandlerByDeviceId.removeAll()
        onlineDeviceIds.removeAll()
        for owner in owners {
            owner.task.cancel()
        }
    }

    /// Explicit destructive recovery boundary. The corrupt primary is first
    /// quarantined; ordinary queue operations can never overwrite it.
    public func resetAfterQuarantiningUnreadableState() throws {
        guard !usesUnifiedRepository else {
            throw OfflineMessageQueueError.stateConflict
        }
        guard isPersistenceBlocked else { return }
        let owners = Array(flushOwnerByDeviceId.values)
        flushOwnerByDeviceId.removeAll()
        ownersCancelledForOffline.removeAll()
        capacitySuspensionByDeviceId.removeAll()
        deliveryHandlerByDeviceId.removeAll()
        onlineDeviceIds.removeAll()
        for owner in owners {
            owner.task.cancel()
        }
        let empty = StoredMessages(pending: [], failed: [])
        do {
            try persistence.quarantine()
            try persistence.save(empty)
        } catch {
            lastPersistenceError = "offline_queue_persistence_recovery_failed"
            throw OfflineMessageQueueError.persistenceFailed
        }
        pendingMessages = []
        failedMessages = []
        totalCount = 0
        lastPersistenceError = nil
        isPersistenceBlocked = false
        if retryTimerEnabled, retryTimer == nil {
            startRetryTimer()
        }
    }

    func cleanupExpiredMessages() throws {
        guard !usesUnifiedRepository else {
            throw OfflineMessageQueueError.stateConflict
        }
        let currentDate = now()
        // An exact owner is solely responsible for resolving an in-flight
        // claim. Expiry may remove it only after completion returns it to a
        // non-sending state; otherwise the external side effect would outlive
        // the canonical claim and its completion would become stale.
        let nextPending = pendingMessages.filter {
            $0.status == .sending || !$0.isExpired(at: currentDate)
        }
        let nextFailed = failedMessages.filter { !$0.isExpired(at: currentDate) }
        guard nextPending.count != pendingMessages.count
                || nextFailed.count != failedMessages.count else { return }
        try commit(pending: nextPending, failed: nextFailed)
    }

    /// Starts at most one exact-owner worker for a device. Repeated online
    /// notifications return the current worker instead of snapshotting and
    /// sending the same messages a second time.
    @discardableResult
    public func onDeviceOnline(
        _ deviceId: String,
        sendHandler: @escaping DeliveryHandler
    ) throws -> Task<Void, Never> {
        guard !usesUnifiedRepository else {
            throw OfflineMessageQueueError.stateConflict
        }
        let normalized = try normalizedTargetDeviceId(deviceId)
        try requirePersistenceAvailable()
        onlineDeviceIds.insert(normalized)
        deliveryHandlerByDeviceId[normalized] = sendHandler
        if let existing = flushOwnerByDeviceId[normalized] {
            return existing.task
        }
        if let suspension = capacitySuspensionByDeviceId[normalized] {
            throw OfflineMessageQueueError.storageCapacityExceeded(
                actualBytes: suspension.actualBytes,
                maximumBytes: suspension.maximumBytes
            )
        }
        return startFlush(for: normalized, sendHandler: sendHandler)
    }

    public func onDeviceOffline(_ deviceId: String) throws {
        guard !usesUnifiedRepository else {
            throw OfflineMessageQueueError.stateConflict
        }
        let normalized = try normalizedTargetDeviceId(deviceId)
        onlineDeviceIds.remove(normalized)
        deliveryHandlerByDeviceId.removeValue(forKey: normalized)
        if let owner = flushOwnerByDeviceId[normalized] {
            ownersCancelledForOffline.insert(owner.token)
            owner.task.cancel()
        }
    }

    private func startFlush(
        for deviceId: String,
        sendHandler: @escaping DeliveryHandler
    ) -> Task<Void, Never> {
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.flush(deviceId: deviceId, ownerToken: token, sendHandler: sendHandler)
        }
        flushOwnerByDeviceId[deviceId] = DeviceFlushOwner(token: token, task: task)
        return task
    }

    private func flush(
        deviceId: String,
        ownerToken: UUID,
        sendHandler: @escaping DeliveryHandler
    ) async {
        var permitsAutomaticReschedule = true
        defer {
            finishFlush(
                deviceId: deviceId,
                ownerToken: ownerToken,
                permitsAutomaticReschedule: permitsAutomaticReschedule
            )
        }

        while ownsFlush(deviceId: deviceId, token: ownerToken),
              onlineDeviceIds.contains(deviceId),
              !isPersistenceBlocked {
            let message: OfflineMessage
            do {
                guard let claimed = try claimNextReadyMessage(
                    for: deviceId,
                    ownerToken: ownerToken
                ) else { return }
                message = claimed
            } catch let queueError as OfflineMessageQueueError {
                if case let .storageCapacityExceeded(actualBytes, maximumBytes) = queueError {
                    capacitySuspensionByDeviceId[deviceId] = CapacitySuspension(
                        actualBytes: actualBytes,
                        maximumBytes: maximumBytes
                    )
                }
                // A reset may invalidate this owner while it is suspended. The
                // resulting state conflict is an expected stale completion,
                // not evidence that persistence is unhealthy.
                permitsAutomaticReschedule = false
                return
            } catch {
                permitsAutomaticReschedule = false
                return
            }

            let disposition: OfflineDeliveryDisposition
            if Task.isCancelled {
                disposition = .cancelled
            } else {
                let attemptedDisposition = await sendHandler(message)
                if Task.isCancelled, attemptedDisposition != .delivered {
                    disposition = .cancelled
                } else {
                    disposition = attemptedDisposition
                }
            }

            do {
                try completeClaim(
                    messageId: message.id,
                    deviceId: deviceId,
                    ownerToken: ownerToken,
                    disposition: disposition
                )
            } catch {
                // `commit` records real persistence failures itself. Other
                // errors mean this worker no longer owns the claimed state.
                permitsAutomaticReschedule = false
                return
            }

            switch disposition {
            case .delivered, .permanentFailure:
                continue
            case .retryable:
                permitsAutomaticReschedule = false
                return
            case .cancelled:
                // A handler-declared cancellation remains pending until a
                // later explicit trigger. Only a worker cancelled by an
                // offline transition may hand off to the replacement handler
                // that arrived after the peer came back online.
                permitsAutomaticReschedule = ownersCancelledForOffline.contains(
                    ownerToken
                )
                return
            }
        }
    }

    private func claimNextReadyMessage(
        for deviceId: String,
        ownerToken: UUID
    ) throws -> OfflineMessage? {
        guard ownsFlush(deviceId: deviceId, token: ownerToken) else {
            throw OfflineMessageQueueError.stateConflict
        }
        let currentDate = now()
        if pendingMessages.contains(where: { $0.isExpired(at: currentDate) }) {
            try cleanupExpiredMessages()
        }
        guard let index = pendingMessages.indices
            .filter({ index in
                let message = pendingMessages[index]
                guard message.targetDeviceId == deviceId,
                      message.status == .pending,
                      !message.isExpired(at: currentDate) else { return false }
                guard let lastRetryAt = message.lastRetryAt else { return true }
                return currentDate.timeIntervalSince(lastRetryAt) >= Self.retryInterval
            })
            .min(by: { pendingMessages[$0].createdAt < pendingMessages[$1].createdAt }) else {
            return nil
        }

        // A legacy state may fit the old 4 MiB limit with no room left for a
        // retry timestamp or failure code. Refuse the claim before invoking
        // the transport so completion can always be durably represented.
        try requireCompletionPersistenceCapacity(
            pending: pendingMessages,
            failed: failedMessages
        )
        var nextPending = pendingMessages
        nextPending[index].status = .sending
        try commit(pending: nextPending, failed: failedMessages)
        return nextPending[index]
    }

    private func completeClaim(
        messageId: String,
        deviceId: String,
        ownerToken: UUID,
        disposition: OfflineDeliveryDisposition
    ) throws {
        guard ownsFlush(deviceId: deviceId, token: ownerToken),
              let index = pendingMessages.firstIndex(where: {
                  $0.id == messageId
                      && $0.targetDeviceId == deviceId
                      && $0.status == .sending
              }) else {
            throw OfflineMessageQueueError.stateConflict
        }

        switch disposition {
        case .delivered:
            var nextPending = pendingMessages
            nextPending.remove(at: index)
            try commit(pending: nextPending, failed: failedMessages)

        case .retryable(let code):
            try recordRetryableFailure(messageId, code: code)

        case .permanentFailure(let code):
            var nextPending = pendingMessages
            var message = nextPending.remove(at: index)
            message.status = .failed
            message.lastFailureCode = code
            try commit(pending: nextPending, failed: failedMessages + [message])

        case .cancelled:
            var nextPending = pendingMessages
            nextPending[index].status = .pending
            try commit(pending: nextPending, failed: failedMessages)
        }
    }

    private func recordRetryableFailure(
        _ messageId: String,
        code: OfflineDeliveryFailureCode
    ) throws {
        guard let index = pendingMessages.firstIndex(where: { $0.id == messageId }) else {
            throw OfflineMessageQueueError.messageNotFound(messageId)
        }
        var nextPending = pendingMessages
        var nextFailed = failedMessages
        var message = nextPending[index]
        guard message.status == .pending || message.status == .sending,
              message.retryCount < Self.maximumRetryCount else {
            throw OfflineMessageQueueError.stateConflict
        }
        let incrementedRetryCount = message.retryCount.addingReportingOverflow(1)
        guard !incrementedRetryCount.overflow else {
            throw OfflineMessageQueueError.stateConflict
        }
        message.retryCount = incrementedRetryCount.partialValue
        message.lastRetryAt = now()
        message.lastFailureCode = code
        if message.retryCount >= Self.maximumRetryCount {
            message.status = .failed
            nextPending.remove(at: index)
            nextFailed.append(message)
        } else {
            message.status = .pending
            nextPending[index] = message
        }
        try commit(pending: nextPending, failed: nextFailed)
    }

    private func finishFlush(
        deviceId: String,
        ownerToken: UUID,
        permitsAutomaticReschedule: Bool
    ) {
        guard ownsFlush(deviceId: deviceId, token: ownerToken) else { return }
        flushOwnerByDeviceId.removeValue(forKey: deviceId)
        ownersCancelledForOffline.remove(ownerToken)
        if permitsAutomaticReschedule,
           onlineDeviceIds.contains(deviceId),
           !isPersistenceBlocked,
           hasImmediatelyReadyMessage(for: deviceId),
           let currentHandler = deliveryHandlerByDeviceId[deviceId] {
            _ = startFlush(for: deviceId, sendHandler: currentHandler)
        }
    }

    private func hasImmediatelyReadyMessage(for deviceId: String) -> Bool {
        let currentDate = now()
        return pendingMessages.contains { message in
            guard message.targetDeviceId == deviceId,
                  message.status == .pending,
                  !message.isExpired(at: currentDate) else { return false }
            guard let lastRetryAt = message.lastRetryAt else { return true }
            return currentDate.timeIntervalSince(lastRetryAt) >= Self.retryInterval
        }
    }

    private func ownsFlush(deviceId: String, token: UUID) -> Bool {
        flushOwnerByDeviceId[deviceId]?.token == token
    }

    private func containsMessage(id: String) -> Bool {
        pendingMessages.contains(where: { $0.id == id })
            || failedMessages.contains(where: { $0.id == id })
    }

    private func requireCompletionPersistenceCapacity(
        pending: [OfflineMessage],
        failed: [OfflineMessage]
    ) throws {
        let retainedFailed = Array(failed.suffix(Self.maximumRetainedFailedMessages))
        let state = StoredMessages(pending: pending, failed: retainedFailed)
        let encodedBytes: Int
        do {
            encodedBytes = try JSONEncoder().encode(state).count
        } catch {
            recordPersistenceFailure()
            throw OfflineMessageQueueError.persistenceFailed
        }
        let reserve = pending.count.multipliedReportingOverflow(
            by: Self.completionMetadataReserveBytesPerPendingMessage
        )
        guard !reserve.overflow else {
            recordPersistenceFailure()
            throw OfflineMessageQueueError.persistenceFailed
        }
        let requiredBytes = encodedBytes.addingReportingOverflow(reserve.partialValue)
        guard !requiredBytes.overflow else {
            recordPersistenceFailure()
            throw OfflineMessageQueueError.persistenceFailed
        }
        guard requiredBytes.partialValue <= Self.maximumPersistenceBytes else {
            lastPersistenceError = OfflineDeliveryFailureCode.storageCapacityExceeded.rawValue
            SkyBridgeLogger.shared.error(
                "Offline message completion metadata capacity was exceeded"
            )
            throw OfflineMessageQueueError.storageCapacityExceeded(
                actualBytes: requiredBytes.partialValue,
                maximumBytes: Self.maximumPersistenceBytes
            )
        }
    }

    private func normalizedTargetDeviceId(_ raw: String) throws -> String {
        do {
            return try DeviceTextMessagePolicy.normalizedTargetDeviceIdentifier(raw)
        } catch {
            throw OfflineMessageQueueError.invalidTargetDeviceIdentifier
        }
    }

    private func commit(
        pending nextPending: [OfflineMessage],
        failed nextFailed: [OfflineMessage]
    ) throws {
        try requirePersistenceAvailable()
        guard nextPending.count <= Self.maximumPendingMessages else {
            throw OfflineMessageQueueError.capacityExceeded(
                maxMessages: Self.maximumPendingMessages
            )
        }
        let retainedFailed = Array(nextFailed.suffix(Self.maximumRetainedFailedMessages))
        let state = StoredMessages(pending: nextPending, failed: retainedFailed)
        do {
            try persistence.save(state)
        } catch let error as CodablePersistenceStoreError {
            switch error {
            case let .payloadTooLarge(actualBytes, maximumBytes):
                lastPersistenceError = OfflineDeliveryFailureCode
                    .storageCapacityExceeded.rawValue
                SkyBridgeLogger.shared.error("Offline message storage capacity exceeded")
                throw OfflineMessageQueueError.storageCapacityExceeded(
                    actualBytes: actualBytes,
                    maximumBytes: maximumBytes
                )
            }
        } catch {
            recordPersistenceFailure()
            throw OfflineMessageQueueError.persistenceFailed
        }
        pendingMessages = nextPending
        failedMessages = retainedFailed
        totalCount = nextPending.count + retainedFailed.count
        lastPersistenceError = nil
        let resumesCapacitySuspensions = !capacitySuspensionByDeviceId.isEmpty
        capacitySuspensionByDeviceId.removeAll()
        if resumesCapacitySuspensions {
            Task { @MainActor [weak self] in
                self?.runRetryMaintenance()
            }
        }
    }

    private func loadFromStorage() {
        do {
            let stored = try persistence.loadOrThrow() ?? StoredMessages(pending: [], failed: [])
            let normalized = try normalizedLoadedState(stored)
            if normalized != stored {
                try persistence.save(normalized)
            }
            pendingMessages = normalized.pending
            failedMessages = normalized.failed
            totalCount = normalized.pending.count + normalized.failed.count
            lastPersistenceError = nil
            isPersistenceBlocked = false
        } catch {
            pendingMessages = []
            failedMessages = []
            totalCount = 0
            recordPersistenceFailure(loadFailure: true)
        }
    }

    private func bootstrapUnifiedRepository() async {
        do {
            try applyUnifiedSnapshot(
                try await IOSUnifiedDeviceMessagingRuntime.shared.bootstrap()
            )
        } catch {
            pendingMessages = []
            failedMessages = []
            totalCount = 0
            lastPersistenceError = "unified_persistence_bootstrap_failed"
            isPersistenceBlocked = true
        }
    }

    func installUnifiedMutationHandler(
        _ handler: @escaping @MainActor @Sendable (
            IOSUnifiedOfflineQueueMutation
        ) async throws -> Void
    ) {
        guard usesUnifiedRepository else { return }
        unifiedMutationHandler = handler
    }

    private func performUnifiedMutation(
        _ mutation: IOSUnifiedOfflineQueueMutation
    ) async throws {
        guard let unifiedMutationHandler else {
            throw OfflineMessageQueueError.stateConflict
        }
        do {
            try await unifiedMutationHandler(mutation)
        } catch let error as DeviceMessagingRepositoryError {
            switch error {
            case .intentNotFound(let queueID):
                throw OfflineMessageQueueError.messageNotFound(queueID)
            case .invalidRecord(let reasonCode)
                    where reasonCode == "in_flight_delivery_prevents_cancel":
                throw OfflineMessageQueueError.stateConflict
            case .invalidRecord(let reasonCode)
                    where reasonCode == "delivery_intent_capacity_exceeded":
                throw OfflineMessageQueueError.capacityExceeded(
                    maxMessages: Self.maximumPendingMessages
                )
            default:
                throw OfflineMessageQueueError.persistenceFailed
            }
        } catch let error as OfflineMessageQueueError {
            throw error
        } catch {
            throw OfflineMessageQueueError.persistenceFailed
        }
    }

    func applyUnifiedSnapshot(_ snapshot: MessageRepositorySnapshot) throws {
        guard snapshot.generation >= latestRepositoryGeneration else { return }
        var pending: [OfflineMessage] = []
        var failed: [OfflineMessage] = []
        for intent in snapshot.deliveryIntents {
            guard let type = OfflineMessageType(rawValue: intent.messageType) else {
                throw OfflineMessageQueueError.stateConflict
            }
            let status: OfflineMessageStatus
            switch intent.state {
            case .pending: status = .pending
            case .sending: status = .sending
            case .awaitingReceipt: status = .awaitingReceipt
            case .failed: status = .failed
            }
            let failureCode = intent.failureCode.flatMap(OfflineDeliveryFailureCode.init(rawValue:))
                ?? (intent.failureCode == nil ? nil : .stateConflict)
            let message = OfflineMessage(
                id: intent.queueID,
                targetDeviceId: intent.targetDeviceID,
                messageType: type,
                payload: intent.payload,
                createdAt: intent.createdAt,
                expiresAt: intent.expiresAt,
                retryCount: intent.retryCount,
                lastRetryAt: intent.lastAttemptAt,
                status: status,
                lastFailureCode: failureCode
            )
            if status == .failed {
                failed.append(message)
            } else {
                pending.append(message)
            }
        }
        latestRepositoryGeneration = snapshot.generation
        pendingMessages = pending.sorted { $0.createdAt < $1.createdAt }
        failedMessages = failed.sorted { $0.createdAt < $1.createdAt }
        totalCount = pendingMessages.count + failedMessages.count
        lastPersistenceError = nil
        isPersistenceBlocked = false
    }

    private func normalizedLoadedState(_ stored: StoredMessages) throws -> StoredMessages {
        let allIds = stored.pending.map(\.id) + stored.failed.map(\.id)
        guard Set(allIds).count == allIds.count,
              stored.pending.count <= Self.maximumPendingMessages else {
            throw OfflineMessageQueueError.stateConflict
        }
        let currentDate = now()
        var pending: [OfflineMessage] = []
        var failed: [OfflineMessage] = []

        for var message in stored.pending {
            try Self.validateMessageMetadata(message)
            guard try normalizedTargetDeviceId(message.targetDeviceId) == message.targetDeviceId else {
                throw OfflineMessageQueueError.stateConflict
            }
            if message.isExpired(at: currentDate) || message.status == .expired {
                continue
            }
            switch message.status {
            case .pending:
                pending.append(message)
            case .sending, .awaitingReceipt:
                message.status = .pending
                pending.append(message)
            case .failed:
                failed.append(message)
            case .sent, .expired:
                continue
            }
        }

        for message in stored.failed {
            try Self.validateMessageMetadata(message)
            guard try normalizedTargetDeviceId(message.targetDeviceId) == message.targetDeviceId,
                  message.status == .failed else {
                throw OfflineMessageQueueError.stateConflict
            }
            if !message.isExpired(at: currentDate) {
                failed.append(message)
            }
        }

        return StoredMessages(
            pending: pending,
            failed: Array(failed.suffix(Self.maximumRetainedFailedMessages))
        )
    }

    private func requirePersistenceAvailable() throws {
        guard !isPersistenceBlocked else {
            throw OfflineMessageQueueError.persistenceFailed
        }
    }

    private static func validateMessageMetadata(_ message: OfflineMessage) throws {
        guard !message.id.isEmpty,
              message.id.utf8.count <= maximumIdentifierBytes,
              !message.id.unicodeScalars.contains(
                  where: CharacterSet.controlCharacters.contains
              ),
              message.retryCount >= 0,
              message.retryCount <= maximumRetryCount,
              message.createdAt.timeIntervalSinceReferenceDate.isFinite else {
            throw OfflineMessageQueueError.stateConflict
        }
        switch message.status {
        case .pending, .sending, .awaitingReceipt:
            guard message.retryCount < maximumRetryCount else {
                throw OfflineMessageQueueError.stateConflict
            }
        case .sent, .failed, .expired:
            break
        }
        if let expiresAt = message.expiresAt {
            guard expiresAt.timeIntervalSinceReferenceDate.isFinite,
                  expiresAt >= message.createdAt else {
                throw OfflineMessageQueueError.stateConflict
            }
        }
        if let lastRetryAt = message.lastRetryAt {
            guard lastRetryAt.timeIntervalSinceReferenceDate.isFinite else {
                throw OfflineMessageQueueError.stateConflict
            }
        }
        guard message.payload.count <= OfflineMessage.maximumPayloadBytes else {
            throw OfflineMessageQueueError.messageTooLarge(
                size: message.payload.count,
                maxSize: OfflineMessage.maximumPayloadBytes
            )
        }
    }

    private func recordPersistenceFailure(loadFailure: Bool = false) {
        lastPersistenceError = loadFailure
            ? "offline_queue_persistence_load_failed"
            : "offline_queue_persistence_failed"
        isPersistenceBlocked = true
        SkyBridgeLogger.shared.error("Offline message queue persistence unavailable")
    }

    private func startRetryTimer() {
        retryTimer = Timer.scheduledTimer(
            withTimeInterval: Self.retryInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.runRetryMaintenance()
            }
        }
    }

    private func runRetryMaintenance() {
        do {
            try cleanupExpiredMessages()
            for deviceId in onlineDeviceIds
            where flushOwnerByDeviceId[deviceId] == nil
                && capacitySuspensionByDeviceId[deviceId] == nil
                && hasImmediatelyReadyMessage(for: deviceId) {
                guard let handler = deliveryHandlerByDeviceId[deviceId] else {
                    continue
                }
                _ = startFlush(for: deviceId, sendHandler: handler)
            }
        } catch {
            // `commit` records actual persistence failures before throwing.
            SkyBridgeLogger.shared.error("Offline message retry maintenance stopped")
        }
    }

    func runRetryMaintenanceForTesting() {
        runRetryMaintenance()
    }
}
