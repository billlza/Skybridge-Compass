import Foundation
import SkyBridgeProtocolCore

struct OfflineMessageClaim: Sendable, Equatable {
    let message: QueuedMessage
    let ownerToken: UUID
}

struct OfflineMessageQueueSnapshot: Sendable {
    let messages: [QueuedMessage]
    let statistics: QueueStatistics
    let persistenceState: OfflineQueuePersistenceState
    let generation: UInt64
}

/// Canonical persistence and exact-owner state machine for the offline queue.
///
/// Every mutation reloads and validates the canonical file inside the existing
/// persistence coordinator before writing an atomic replacement. A corrupt file
/// blocks all mutations until an explicit clear; it is never treated as empty.
actor OfflineMessageQueueRepository {
    private struct TransactionResult<Value: Sendable>: Sendable {
        let messages: [QueuedMessage]
        let value: Value
    }

    private struct CanonicalStateError: Error, Sendable {
        let code: OfflineDeliveryFailureCode
    }

    private let store: CodablePersistenceStore<[QueuedMessage]>
    private var messages: [UUID: QueuedMessage] = [:]
    private var claimOwners: [UUID: UUID] = [:]
    private var persistenceState: OfflineQueuePersistenceState = .loading
    private var bootstrapTask: Task<[QueuedMessage], Error>?
    private var nextTransactionSequence: UInt64 = 0
    private var latestAppliedTransactionSequence: UInt64 = 0

    init(store: CodablePersistenceStore<[QueuedMessage]>) {
        self.store = store
    }

    func bootstrap(configuration: OfflineQueueConfiguration) async throws -> OfflineMessageQueueSnapshot {
        try configuration.validate()
        switch persistenceState {
        case .ready:
            return snapshot()
        case .blocked(let code):
            throw OfflineQueueError.persistenceBlocked(code)
        case .loading:
            break
        }

        let task: Task<[QueuedMessage], Error>
        if let bootstrapTask {
            task = bootstrapTask
        } else {
            let store = self.store
            task = Task {
                try await CodablePersistenceStoreIOCoordinator.shared.perform(
                    identity: store.persistenceIdentity
                ) {
                    let persisted = try store.loadOrThrow() ?? []
                    let normalized = try Self.validatedCanonicalMessages(
                        persisted,
                        recoverInterruptedDeliveries: true
                    )
                    if normalized != persisted {
                        try store.save(normalized)
                    }
                    return normalized
                }
            }
            bootstrapTask = task
        }

        let sequence = try issueTransactionSequence()
        do {
            let loaded = try await task.value
            bootstrapTask = nil
            if apply(loaded, transactionSequence: sequence) {
                claimOwners.removeAll(keepingCapacity: false)
                persistenceState = .ready
            }
            return snapshot()
        } catch {
            bootstrapTask = nil
            let code = Self.persistenceFailureCode(for: error)
            advanceGeneration(to: sequence)
            persistenceState = .blocked(code)
            throw OfflineQueueError.persistenceBlocked(code)
        }
    }

    func enqueue(
        _ message: QueuedMessage,
        configuration: OfflineQueueConfiguration
    ) async throws -> OfflineMessageQueueSnapshot {
        try await requireReady(configuration: configuration)
        let targetDeviceID = try DeviceTextMessagePolicy.normalizedTargetDeviceIdentifier(
            message.targetDeviceID
        )
        guard targetDeviceID == message.targetDeviceID else {
            throw OfflineQueueError.persistenceBlocked(.invalidTargetDeviceIdentifier)
        }

        let _: TransactionResult<Void> = try await transaction { canonical in
            let activeMessages = canonical.values.filter { !$0.status.isTerminal }
            guard activeMessages.count < configuration.maxQueueSize else {
                throw OfflineQueueError.queueFull
            }
            let deviceCount = activeMessages.lazy.filter {
                $0.targetDeviceID == targetDeviceID
            }.count
            guard deviceCount < configuration.maxMessagesPerDevice else {
                throw OfflineQueueError.deviceQueueFull(deviceID: targetDeviceID)
            }
            guard canonical[message.id] == nil else {
                throw CanonicalStateError(code: .stateConflict)
            }
            canonical[message.id] = message
        }
        return snapshot()
    }

    func enqueueBatch(
        _ newMessages: [QueuedMessage],
        configuration: OfflineQueueConfiguration
    ) async throws -> OfflineMessageQueueSnapshot {
        try await requireReady(configuration: configuration)
        guard !newMessages.isEmpty else { return snapshot() }

        let _: TransactionResult<Void> = try await transaction { canonical in
            let activeMessages = canonical.values.filter { !$0.status.isTerminal }
            guard activeMessages.count + newMessages.count <= configuration.maxQueueSize else {
                throw OfflineQueueError.queueFull
            }

            var additionsByDevice: [String: Int] = [:]
            var newMessageIDs = Set<UUID>()
            for message in newMessages {
                guard canonical[message.id] == nil,
                      newMessageIDs.insert(message.id).inserted else {
                    throw CanonicalStateError(code: .stateConflict)
                }
                guard !message.payload.isEmpty,
                      message.payload.count <= QueuedMessage.maximumPayloadBytes else {
                    throw CanonicalStateError(code: .invalidPayload)
                }
                additionsByDevice[message.targetDeviceID, default: 0] += 1
            }
            for (deviceID, additionCount) in additionsByDevice {
                let currentCount = activeMessages.lazy.filter {
                    $0.targetDeviceID == deviceID
                }.count
                guard currentCount + additionCount <= configuration.maxMessagesPerDevice else {
                    throw OfflineQueueError.deviceQueueFull(deviceID: deviceID)
                }
            }
            for message in newMessages {
                canonical[message.id] = message
            }
        }
        return snapshot()
    }

    func cancel(
        messageID: UUID,
        configuration: OfflineQueueConfiguration
    ) async throws -> OfflineMessageQueueSnapshot {
        try await requireReady(configuration: configuration)
        let _: TransactionResult<Void> = try await transaction { canonical in
            guard canonical.removeValue(forKey: messageID) != nil else {
                throw OfflineQueueError.messageNotFound(id: messageID)
            }
        }
        claimOwners.removeValue(forKey: messageID)
        return snapshot()
    }

    func cancelAll(
        for deviceID: String,
        configuration: OfflineQueueConfiguration
    ) async throws -> OfflineMessageQueueSnapshot {
        try await requireReady(configuration: configuration)
        let normalizedDeviceID = try DeviceTextMessagePolicy.normalizedTargetDeviceIdentifier(deviceID)
        let result: TransactionResult<Void> = try await transaction { canonical in
            canonical = canonical.filter { $0.value.targetDeviceID != normalizedDeviceID }
        }
        let retainedIDs = Set(result.messages.map(\.id))
        claimOwners = claimOwners.filter { retainedIDs.contains($0.key) }
        return snapshot()
    }

    /// Explicit destructive recovery. This is the only operation allowed while
    /// canonical storage is blocked by corruption.
    func clearAll() async throws -> OfflineMessageQueueSnapshot {
        let sequence = try issueTransactionSequence()
        let store = self.store
        let requiresQuarantine: Bool
        if case .blocked = persistenceState {
            requiresQuarantine = true
        } else {
            requiresQuarantine = false
        }
        do {
            try await CodablePersistenceStoreIOCoordinator.shared.perform(
                identity: store.persistenceIdentity
            ) {
                if requiresQuarantine {
                    _ = try store.quarantineExistingPayload()
                }
                try store.save([])
            }
            if apply([], transactionSequence: sequence) {
                claimOwners.removeAll(keepingCapacity: false)
                persistenceState = .ready
            }
            bootstrapTask = nil
            return snapshot()
        } catch {
            let code = Self.persistenceFailureCode(for: error)
            advanceGeneration(to: sequence)
            persistenceState = .blocked(code)
            throw OfflineQueueError.persistenceBlocked(code)
        }
    }

    func claimNextReadyMessage(
        for deviceID: String,
        ownerToken: UUID,
        configuration: OfflineQueueConfiguration,
        now: Date = Date()
    ) async throws -> OfflineMessageClaim? {
        try await requireReady(configuration: configuration)
        let result: TransactionResult<QueuedMessage?> = try await transaction { canonical in
            Self.pruneExpiredMessages(in: &canonical, now: now)
            let ready = canonical.values
                .filter { message in
                    guard message.targetDeviceID == deviceID,
                          message.status == .pending,
                          now <= message.expiresAt else {
                        return false
                    }
                    guard let lastAttempt = message.lastAttemptAt else { return true }
                    let exponent = max(0, message.retryCount - 1)
                    let backoff = configuration.retryInterval
                        * pow(configuration.retryBackoffFactor, Double(exponent))
                    return now >= lastAttempt.addingTimeInterval(backoff)
                }
                .sorted { lhs, rhs in
                    if configuration.priorityOrdering, lhs.priority != rhs.priority {
                        return lhs.priority > rhs.priority
                    }
                    if lhs.createdAt != rhs.createdAt {
                        return lhs.createdAt < rhs.createdAt
                    }
                    return lhs.id.uuidString < rhs.id.uuidString
                }

            guard var message = ready.first else { return nil }
            message.markSending()
            canonical[message.id] = message
            return message
        }
        guard let message = result.value,
              messages[message.id]?.status == .sending else {
            return nil
        }
        claimOwners[message.id] = ownerToken
        return OfflineMessageClaim(message: message, ownerToken: ownerToken)
    }

    func isClaimCurrent(
        _ claim: OfflineMessageClaim,
        configuration: OfflineQueueConfiguration
    ) async throws -> Bool {
        try await requireReady(configuration: configuration)
        guard claimOwners[claim.message.id] == claim.ownerToken,
              let current = messages[claim.message.id],
              current.status == .sending else {
            return false
        }
        return current == claim.message
    }

    func resolve(
        _ claim: OfflineMessageClaim,
        disposition: OfflineDeliveryDisposition,
        configuration: OfflineQueueConfiguration
    ) async throws -> OfflineMessageQueueSnapshot {
        try await requireReady(configuration: configuration)
        guard claimOwners[claim.message.id] == claim.ownerToken else {
            throw OfflineQueueError.staleClaim(id: claim.message.id)
        }

        let _: TransactionResult<Void> = try await transaction { canonical in
            guard var current = canonical[claim.message.id],
                  current.status == .sending else {
                throw OfflineQueueError.staleClaim(id: claim.message.id)
            }
            switch disposition {
            case .delivered:
                canonical.removeValue(forKey: current.id)
            case .retryable(let code):
                current.recordRetryableFailure(
                    code,
                    maximumRetryCount: configuration.maxRetryCount
                )
                canonical[current.id] = current
            case .permanentFailure(let code):
                current.markPermanentFailure(code)
                canonical[current.id] = current
            case .cancelled:
                current.preservePendingAfterCancellation()
                canonical[current.id] = current
            }
        }
        claimOwners.removeValue(forKey: claim.message.id)
        return snapshot()
    }

    func resetFailed(
        configuration: OfflineQueueConfiguration
    ) async throws -> OfflineMessageQueueSnapshot {
        try await requireReady(configuration: configuration)
        let _: TransactionResult<Void> = try await transaction { canonical in
            guard canonical.values.allSatisfy({ message in
                message.status != .failed || message.messageType != .text
            }) else {
                throw OfflineQueueError.coordinatedRetryRequired
            }
            for id in canonical.keys {
                guard var message = canonical[id], message.status == .failed else { continue }
                message.resetForManualRetry()
                canonical[id] = message
            }
        }
        return snapshot()
    }

    func cleanupExpired(
        configuration: OfflineQueueConfiguration,
        now: Date = Date()
    ) async throws -> (removedCount: Int, snapshot: OfflineMessageQueueSnapshot) {
        try await requireReady(configuration: configuration)
        let result: TransactionResult<Int> = try await transaction { canonical in
            Self.pruneExpiredMessages(in: &canonical, now: now)
        }
        let retainedIDs = Set(result.messages.map(\.id))
        claimOwners = claimOwners.filter { retainedIDs.contains($0.key) }
        return (result.value, snapshot())
    }

    func messagesForDevice(
        _ deviceID: String,
        configuration: OfflineQueueConfiguration
    ) async throws -> [QueuedMessage] {
        try await requireReady(configuration: configuration)
        return messages.values
            .filter { $0.targetDeviceID == deviceID && !$0.status.isTerminal }
            .sorted(by: Self.deliveryOrder)
    }

    func allMessages(
        configuration: OfflineQueueConfiguration
    ) async throws -> [QueuedMessage] {
        try await requireReady(configuration: configuration)
        return Self.persistedOrder(Array(messages.values))
    }

    func currentSnapshot() -> OfflineMessageQueueSnapshot {
        snapshot()
    }

    private func requireReady(configuration: OfflineQueueConfiguration) async throws {
        try configuration.validate()
        if case .loading = persistenceState {
            _ = try await bootstrap(configuration: configuration)
        }
        guard case .ready = persistenceState else {
            let code: OfflineDeliveryFailureCode
            if case .blocked(let blockedCode) = persistenceState {
                code = blockedCode
            } else {
                code = .persistenceFailure
            }
            throw OfflineQueueError.persistenceBlocked(code)
        }
    }

    private func transaction<Value: Sendable>(
        _ mutation: @escaping @Sendable (inout [UUID: QueuedMessage]) throws -> Value
    ) async throws -> TransactionResult<Value> {
        let sequence = try issueTransactionSequence()
        let store = self.store
        do {
            let result = try await CodablePersistenceStoreIOCoordinator.shared.perform(
                identity: store.persistenceIdentity
            ) {
                let persisted = try store.loadOrThrow() ?? []
                let validated = try Self.validatedCanonicalMessages(
                    persisted,
                    recoverInterruptedDeliveries: false
                )
                var canonical = Dictionary(uniqueKeysWithValues: validated.map { ($0.id, $0) })
                let value = try mutation(&canonical)
                let updated = try Self.validatedCanonicalMessages(
                    Array(canonical.values),
                    recoverInterruptedDeliveries: false
                )
                do {
                    try store.save(updated)
                } catch let error as CodablePersistenceStoreError {
                    switch error {
                    case .payloadTooLarge(let actualBytes, let maximumBytes):
                        throw OfflineQueueError.storageCapacityExceeded(
                            actualBytes: actualBytes,
                            maximumBytes: maximumBytes
                        )
                    }
                }
                return TransactionResult(messages: updated, value: value)
            }
            apply(result.messages, transactionSequence: sequence)
            return result
        } catch let error as OfflineQueueError {
            throw error
        } catch let error as DeviceTextMessagePolicyError {
            throw error
        } catch {
            let code = Self.persistenceFailureCode(for: error)
            advanceGeneration(to: sequence)
            persistenceState = .blocked(code)
            throw OfflineQueueError.persistenceBlocked(code)
        }
    }

    private func issueTransactionSequence() throws -> UInt64 {
        let increment = nextTransactionSequence.addingReportingOverflow(1)
        guard !increment.overflow else {
            persistenceState = .blocked(.stateConflict)
            throw OfflineQueueError.persistenceBlocked(.stateConflict)
        }
        nextTransactionSequence = increment.partialValue
        return nextTransactionSequence
    }

    @discardableResult
    private func apply(
        _ persisted: [QueuedMessage],
        transactionSequence: UInt64
    ) -> Bool {
        guard transactionSequence >= latestAppliedTransactionSequence else { return false }
        latestAppliedTransactionSequence = transactionSequence
        messages = Dictionary(uniqueKeysWithValues: persisted.map { ($0.id, $0) })
        return true
    }

    private func advanceGeneration(to transactionSequence: UInt64) {
        guard transactionSequence > latestAppliedTransactionSequence else { return }
        latestAppliedTransactionSequence = transactionSequence
    }

    private func snapshot() -> OfflineMessageQueueSnapshot {
        let ordered = Self.persistedOrder(Array(messages.values))
        return OfflineMessageQueueSnapshot(
            messages: ordered,
            statistics: Self.statistics(for: ordered),
            persistenceState: persistenceState,
            generation: latestAppliedTransactionSequence
        )
    }

    private nonisolated static func validatedCanonicalMessages(
        _ persisted: [QueuedMessage],
        recoverInterruptedDeliveries: Bool
    ) throws -> [QueuedMessage] {
        var seen = Set<UUID>()
        var normalized: [QueuedMessage] = []
        normalized.reserveCapacity(persisted.count)
        for var message in persisted {
            guard seen.insert(message.id).inserted else {
                throw CanonicalStateError(code: .stateConflict)
            }
            let normalizedTarget: String
            do {
                normalizedTarget = try DeviceTextMessagePolicy
                    .normalizedTargetDeviceIdentifier(message.targetDeviceID)
            } catch {
                throw CanonicalStateError(code: .invalidTargetDeviceIdentifier)
            }
            guard normalizedTarget == message.targetDeviceID,
                  !message.payload.isEmpty,
                  message.payload.count <= QueuedMessage.maximumPayloadBytes,
                  message.createdAt.timeIntervalSinceReferenceDate.isFinite,
                  message.expiresAt.timeIntervalSinceReferenceDate.isFinite,
                  message.expiresAt >= message.createdAt,
                  message.retryCount >= 0,
                  message.hasValidPersistedFailureCode else {
                throw CanonicalStateError(code: .invalidPayload)
            }
            if message.status == .delivered || message.status == .expired {
                continue
            }
            if recoverInterruptedDeliveries {
                message.recoverInterruptedDelivery()
            }
            normalized.append(message)
        }
        return persistedOrder(normalized)
    }

    @discardableResult
    private nonisolated static func pruneExpiredMessages(
        in canonical: inout [UUID: QueuedMessage],
        now: Date
    ) -> Int {
        let expiredIDs = canonical.values.compactMap { message in
            // Only the exact claim owner may resolve an in-flight submission.
            // Expiry can prune it after resolution returns it to a non-sending
            // state, never while the external side effect is still running.
            now > message.expiresAt && message.status != .sending
                ? message.id
                : nil
        }
        for id in expiredIDs {
            canonical.removeValue(forKey: id)
        }
        return expiredIDs.count
    }

    private nonisolated static func persistedOrder(_ messages: [QueuedMessage]) -> [QueuedMessage] {
        messages.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private nonisolated static func deliveryOrder(
        _ lhs: QueuedMessage,
        _ rhs: QueuedMessage
    ) -> Bool {
        if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private nonisolated static func statistics(for messages: [QueuedMessage]) -> QueueStatistics {
        let pending = messages.filter { $0.status == .pending }
        let active = messages.filter { !$0.status.isTerminal }
        var deviceBreakdown: [String: Int] = [:]
        for message in active {
            deviceBreakdown[message.targetDeviceID, default: 0] += 1
        }
        let averageWait = pending.isEmpty
            ? 0
            : pending.reduce(0.0) { $0 + $1.waitingDuration } / Double(pending.count)
        return QueueStatistics(
            totalMessages: messages.count,
            pendingMessages: pending.count,
            sendingMessages: messages.filter { $0.status == .sending }.count,
            deliveredMessages: 0,
            failedMessages: messages.filter { $0.status == .failed }.count,
            expiredMessages: 0,
            deviceBreakdown: deviceBreakdown,
            averageWaitTime: averageWait,
            oldestMessageAge: pending.map(\.waitingDuration).max()
        )
    }

    private nonisolated static func persistenceFailureCode(
        for error: Error
    ) -> OfflineDeliveryFailureCode {
        if let error = error as? CanonicalStateError {
            return error.code
        }
        if let error = error as? DeviceTextMessagePolicyError {
            switch error {
            case .invalidTargetDeviceIdentifier:
                return .invalidTargetDeviceIdentifier
            case .invalidConversationFingerprint:
                return .invalidConversationFingerprint
            case .emptyText, .textTooLong, .textTooLarge:
                return .invalidPayload
            }
        }
        return .persistenceFailure
    }
}
