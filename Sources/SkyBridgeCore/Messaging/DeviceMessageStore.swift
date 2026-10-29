import Combine
import Foundation
import SkyBridgeMessagePersistence
import SkyBridgeProtocolCore

enum UnifiedDeviceMessageStoreMutation: Sendable {
    case clearConversation(String)
}

/// How one repository change landed on a MainActor projection.
enum UnifiedProjectionApplication: Sendable, Equatable {
    /// The change applied cleanly on top of the projection's generation.
    case applied
    /// The change does not advance past the projection's generation, so its
    /// rows are provably already reflected; it was ignored.
    case alreadyReflected
    /// The change's basis is ahead of the projection, or the projection's
    /// content diverged from the rows the change expects. The caller must
    /// fetch a full snapshot from the repository and reapply it; that
    /// resynchronization is the defined repair protocol, not a fallback.
    case requiresResynchronization
}

public enum DeviceMessageStoreError: Error, LocalizedError, Sendable, Equatable {
    case invalidConversationFingerprint
    case messageNotFound(UUID)
    case persistenceBlocked(OfflineDeliveryFailureCode)
    case invalidPersistedState
    case conversationCapacityExceeded
    case pendingOutgoingMessagesPreventClear(count: Int)
    case storageCapacityExceeded(actualBytes: Int, maximumBytes: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidConversationFingerprint:
            return "Invalid device-message conversation fingerprint"
        case .messageNotFound:
            return "Device message was not found"
        case .persistenceBlocked:
            return "Device-message persistence is unavailable"
        case .invalidPersistedState:
            return "Device-message persistence contains invalid state"
        case .conversationCapacityExceeded:
            return "Device-message conversation capacity was exceeded"
        case .pendingOutgoingMessagesPreventClear:
            return "Pending outgoing messages must be resolved before clearing the conversation"
        case .storageCapacityExceeded(let actualBytes, let maximumBytes):
            return "Device-message storage capacity exceeded: \(actualBytes) bytes (maximum \(maximumBytes) bytes)"
        }
    }
}

public enum DeviceMessageStorePersistenceState: Sendable, Equatable {
    case loading
    case ready
    case blocked(OfflineDeliveryFailureCode)
}

@available(macOS 14.0, iOS 17.0, *)
actor DeviceMessageConversationRepository {
    typealias Conversations = [String: [DeviceMessageStore.Message]]

    struct Snapshot: Sendable {
        let conversations: Conversations
        let persistenceState: DeviceMessageStorePersistenceState
        let generation: UInt64
    }

    private let store: CodablePersistenceStore<Conversations>
    private let maximumMessagesPerConversation: Int
    private var conversations: Conversations = [:]
    private var persistenceState: DeviceMessageStorePersistenceState = .loading
    private var bootstrapTask: Task<Conversations, Error>?
    private var nextTransactionSequence: UInt64 = 0
    private var latestAppliedTransactionSequence: UInt64 = 0

    init(
        store: CodablePersistenceStore<Conversations>,
        maximumMessagesPerConversation: Int
    ) {
        precondition(maximumMessagesPerConversation > 0)
        self.store = store
        self.maximumMessagesPerConversation = maximumMessagesPerConversation
    }

    func bootstrap() async throws -> Snapshot {
        switch persistenceState {
        case .ready:
            return snapshot()
        case .blocked(let code):
            throw DeviceMessageStoreError.persistenceBlocked(code)
        case .loading:
            break
        }

        let task: Task<Conversations, Error>
        if let bootstrapTask {
            task = bootstrapTask
        } else {
            let store = self.store
            let maximum = maximumMessagesPerConversation
            task = Task {
                try await CodablePersistenceStoreIOCoordinator.shared.perform(
                    identity: store.persistenceIdentity
                ) {
                    let persisted = try store.loadOrThrow() ?? [:]
                    let normalized = try Self.validated(
                        persisted,
                        maximumMessagesPerConversation: maximum
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
                persistenceState = .ready
            }
            return snapshot()
        } catch {
            bootstrapTask = nil
            let code = Self.failureCode(for: error)
            advanceGeneration(to: sequence)
            persistenceState = .blocked(code)
            throw DeviceMessageStoreError.persistenceBlocked(code)
        }
    }

    func appendOutgoing(
        text: String,
        conversationFingerprint: String,
        targetDeviceID: String,
        messageID: UUID,
        sentAt: Date
    ) async throws -> Snapshot {
        let maximum = maximumMessagesPerConversation
        let message = DeviceMessageStore.Message(
            id: messageID,
            direction: .outgoing,
            text: text,
            timestamp: sentAt,
            deliveryState: .pending,
            targetDeviceID: targetDeviceID
        )
        return try await mutate { conversations in
            var messages = conversations[conversationFingerprint] ?? []
            guard !messages.contains(where: { $0.id == messageID }) else {
                throw DeviceMessageStoreError.invalidPersistedState
            }
            messages.append(message)
            conversations[conversationFingerprint] = try Self.bounded(
                messages,
                maximumMessagesPerConversation: maximum
            )
        }
    }

    func updateDeliveryState(
        messageID: UUID,
        conversationFingerprint: String,
        deliveryState: DeviceMessageStore.DeliveryState
    ) async throws -> Snapshot {
        try await mutate { conversations in
            guard var messages = conversations[conversationFingerprint],
                  let index = messages.firstIndex(where: { $0.id == messageID }) else {
                throw DeviceMessageStoreError.messageNotFound(messageID)
            }
            guard messages[index].deliveryState != deliveryState else { return }
            messages[index].deliveryState = deliveryState
            conversations[conversationFingerprint] = messages
        }
    }

    func receiveIncoming(
        text: String,
        conversationFingerprint: String,
        messageID: UUID,
        sentAt: Date
    ) async throws -> Snapshot {
        let maximum = maximumMessagesPerConversation
        return try await mutate { conversations in
            var messages = conversations[conversationFingerprint] ?? []
            guard !messages.contains(where: { $0.id == messageID }) else { return }
            messages.append(
                DeviceMessageStore.Message(
                    id: messageID,
                    direction: .incoming,
                    text: text,
                    timestamp: sentAt,
                    deliveryState: .delivered
                )
            )
            conversations[conversationFingerprint] = try Self.bounded(
                messages,
                maximumMessagesPerConversation: maximum
            )
        }
    }

    func clearConversation(_ conversationFingerprint: String) async throws -> Snapshot {
        try await mutate { conversations in
            let pendingOutgoingCount = conversations[conversationFingerprint, default: []]
                .lazy
                .filter { $0.direction == .outgoing && $0.deliveryState == .pending }
                .count
            guard pendingOutgoingCount == 0 else {
                throw DeviceMessageStoreError.pendingOutgoingMessagesPreventClear(
                    count: pendingOutgoingCount
                )
            }
            conversations.removeValue(forKey: conversationFingerprint)
        }
    }

    /// Explicit destructive recovery for an unreadable canonical file.
    func clearAll() async throws -> Snapshot {
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
                try store.save([:])
            }
            if apply([:], transactionSequence: sequence) {
                persistenceState = .ready
                bootstrapTask = nil
            }
            return snapshot()
        } catch {
            let code = Self.failureCode(for: error)
            advanceGeneration(to: sequence)
            persistenceState = .blocked(code)
            throw DeviceMessageStoreError.persistenceBlocked(code)
        }
    }

    func currentSnapshot() -> Snapshot {
        snapshot()
    }

    private func mutate(
        _ mutation: @escaping @Sendable (inout Conversations) throws -> Void
    ) async throws -> Snapshot {
        _ = try await bootstrap()
        let sequence = try issueTransactionSequence()
        let store = self.store
        let maximum = maximumMessagesPerConversation
        do {
            let result = try await CodablePersistenceStoreIOCoordinator.shared.perform(
                identity: store.persistenceIdentity
            ) {
                let persisted = try store.loadOrThrow() ?? [:]
                var canonical = try Self.validated(
                    persisted,
                    maximumMessagesPerConversation: maximum
                )
                try mutation(&canonical)
                canonical = try Self.validated(
                    canonical,
                    maximumMessagesPerConversation: maximum
                )
                do {
                    try store.save(canonical)
                } catch let error as CodablePersistenceStoreError {
                    switch error {
                    case .payloadTooLarge(let actualBytes, let maximumBytes):
                        throw DeviceMessageStoreError.storageCapacityExceeded(
                            actualBytes: actualBytes,
                            maximumBytes: maximumBytes
                        )
                    }
                }
                return canonical
            }
            apply(result, transactionSequence: sequence)
            return snapshot()
        } catch let error as DeviceMessageStoreError {
            switch error {
            case .invalidPersistedState:
                advanceGeneration(to: sequence)
                persistenceState = .blocked(.stateConflict)
                throw DeviceMessageStoreError.persistenceBlocked(.stateConflict)
            case .invalidConversationFingerprint, .messageNotFound,
                 .persistenceBlocked, .conversationCapacityExceeded,
                 .pendingOutgoingMessagesPreventClear, .storageCapacityExceeded:
                throw error
            }
        } catch let error as DeviceTextMessagePolicyError {
            throw error
        } catch {
            let code = Self.failureCode(for: error)
            advanceGeneration(to: sequence)
            persistenceState = .blocked(code)
            throw DeviceMessageStoreError.persistenceBlocked(code)
        }
    }

    private func snapshot() -> Snapshot {
        Snapshot(
            conversations: conversations,
            persistenceState: persistenceState,
            generation: latestAppliedTransactionSequence
        )
    }

    private func issueTransactionSequence() throws -> UInt64 {
        let increment = nextTransactionSequence.addingReportingOverflow(1)
        guard !increment.overflow else {
            persistenceState = .blocked(.stateConflict)
            throw DeviceMessageStoreError.persistenceBlocked(.stateConflict)
        }
        nextTransactionSequence = increment.partialValue
        return nextTransactionSequence
    }

    @discardableResult
    private func apply(_ value: Conversations, transactionSequence: UInt64) -> Bool {
        guard transactionSequence >= latestAppliedTransactionSequence else { return false }
        latestAppliedTransactionSequence = transactionSequence
        conversations = value
        return true
    }

    private func advanceGeneration(to transactionSequence: UInt64) {
        guard transactionSequence > latestAppliedTransactionSequence else { return }
        latestAppliedTransactionSequence = transactionSequence
    }

    private nonisolated static func validated(
        _ conversations: Conversations,
        maximumMessagesPerConversation: Int
    ) throws -> Conversations {
        var normalized: Conversations = [:]
        normalized.reserveCapacity(conversations.count)
        for (rawFingerprint, rawMessages) in conversations {
            let fingerprint: String
            do {
                fingerprint = try DeviceTextMessagePolicy
                    .normalizedConversationFingerprint(rawFingerprint)
            } catch {
                throw DeviceMessageStoreError.invalidPersistedState
            }
            guard fingerprint == rawFingerprint else {
                throw DeviceMessageStoreError.invalidPersistedState
            }
            var seen = Set<UUID>()
            var messages: [DeviceMessageStore.Message] = []
            messages.reserveCapacity(rawMessages.count)
            for message in rawMessages {
                guard seen.insert(message.id).inserted,
                      message.timestamp.timeIntervalSinceReferenceDate.isFinite else {
                    throw DeviceMessageStoreError.invalidPersistedState
                }
                do {
                    _ = try DeviceTextMessagePolicy.validatedText(message.text)
                    if let targetDeviceID = message.targetDeviceID {
                        let normalizedTarget = try DeviceTextMessagePolicy
                            .normalizedTargetDeviceIdentifier(targetDeviceID)
                        guard normalizedTarget == targetDeviceID else {
                            throw DeviceMessageStoreError.invalidPersistedState
                        }
                    }
                } catch {
                    throw DeviceMessageStoreError.invalidPersistedState
                }
                messages.append(message)
            }
            normalized[fingerprint] = try bounded(
                messages,
                maximumMessagesPerConversation: maximumMessagesPerConversation
            )
        }
        return normalized
    }

    private nonisolated static func bounded(
        _ messages: [DeviceMessageStore.Message],
        maximumMessagesPerConversation: Int
    ) throws -> [DeviceMessageStore.Message] {
        guard messages.count > maximumMessagesPerConversation else { return messages }
        let pendingIDs = Set(
            messages.lazy
                .filter { $0.direction == .outgoing && $0.deliveryState == .pending }
                .map(\.id)
        )
        guard pendingIDs.count <= maximumMessagesPerConversation else {
            throw DeviceMessageStoreError.conversationCapacityExceeded
        }
        var retained = Array(messages.suffix(maximumMessagesPerConversation))
        let retainedIDs = Set(retained.map(\.id))
        let missingPending = messages.filter {
            pendingIDs.contains($0.id) && !retainedIDs.contains($0.id)
        }
        if !missingPending.isEmpty {
            let removableIndexes = retained.indices.filter { index in
                !pendingIDs.contains(retained[index].id)
            }
            guard removableIndexes.count >= missingPending.count else {
                throw DeviceMessageStoreError.conversationCapacityExceeded
            }
            for (message, index) in zip(missingPending, removableIndexes) {
                retained[index] = message
            }
            retained.sort {
                if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
                return $0.id.uuidString < $1.id.uuidString
            }
        }
        return retained
    }

    private nonisolated static func failureCode(for error: Error) -> OfflineDeliveryFailureCode {
        if let error = error as? DeviceMessageStoreError,
           error == .invalidPersistedState {
            return .stateConflict
        }
        return .persistenceFailure
    }
}

/// Device-message conversation projection. The repository owns canonical I/O;
/// this main-actor facade only publishes committed snapshots to SwiftUI.
@available(macOS 14.0, iOS 17.0, *)
@MainActor
public final class DeviceMessageStore: ObservableObject {
    public static let shared = DeviceMessageStore()

    public enum Direction: String, Codable, Sendable {
        case incoming
        case outgoing
    }

    public enum DeliveryState: String, Codable, Sendable {
        case pending
        case sent
        case delivered
        case failed
    }

    public struct Message: Identifiable, Codable, Sendable, Equatable {
        public let id: UUID
        public let direction: Direction
        public let text: String
        public let timestamp: Date
        public var deliveryState: DeliveryState
        public let targetDeviceID: String?

        public init(
            id: UUID = UUID(),
            direction: Direction,
            text: String,
            timestamp: Date = Date(),
            deliveryState: DeliveryState,
            targetDeviceID: String? = nil
        ) {
            self.id = id
            self.direction = direction
            self.text = text
            self.timestamp = timestamp
            self.deliveryState = deliveryState
            self.targetDeviceID = targetDeviceID
        }
    }

    @Published public private(set) var conversations: [String: [Message]] = [:]
    @Published public private(set) var persistenceState: DeviceMessageStorePersistenceState = .loading
    @Published public private(set) var migrationIssues: [MessageRepositoryMigrationIssue] = []

    private static let defaultStore = CodablePersistenceStore<[String: [Message]]>(
        location: .protectedApplicationSupport(path: "Messaging/conversations.json")
    )
    private let repository: DeviceMessageConversationRepository
    private let usesUnifiedRepository: Bool
    private var latestGeneration: UInt64 = 0
    private var bootstrapTask: Task<Void, Never>?
    private var unifiedMutationHandler: (@MainActor @Sendable (
        UnifiedDeviceMessageStoreMutation
    ) async throws -> Void)?

    private convenience init() {
        self.init(store: Self.defaultStore, usesUnifiedRepository: true)
    }

    convenience init(store: CodablePersistenceStore<[String: [Message]]>) {
        self.init(store: store, usesUnifiedRepository: false)
    }

    private init(
        store: CodablePersistenceStore<[String: [Message]]>,
        usesUnifiedRepository: Bool
    ) {
        repository = DeviceMessageConversationRepository(
            store: store,
            maximumMessagesPerConversation: 500
        )
        self.usesUnifiedRepository = usesUnifiedRepository
        bootstrapTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.bootstrap()
        }
    }

    public func messages(fingerprint rawFingerprint: String) throws -> [Message] {
        let fingerprint = try normalizedFingerprint(rawFingerprint)
        return conversations[fingerprint] ?? []
    }

    public func appendOutgoing(
        text rawText: String,
        fingerprint rawFingerprint: String,
        targetDeviceID rawTargetDeviceID: String,
        messageID: UUID,
        sentAt: Date
    ) async throws {
        let text = try DeviceTextMessagePolicy.validatedText(rawText)
        let fingerprint = try normalizedFingerprint(rawFingerprint)
        let targetDeviceID = try DeviceTextMessagePolicy
            .normalizedTargetDeviceIdentifier(rawTargetDeviceID)
        guard !usesUnifiedRepository else {
            throw DeviceMessageStoreError.persistenceBlocked(.stateConflict)
        }
        try await applyRepositoryMutation {
            try await repository.appendOutgoing(
                text: text,
                conversationFingerprint: fingerprint,
                targetDeviceID: targetDeviceID,
                messageID: messageID,
                sentAt: sentAt
            )
        }
    }

    public func markSent(messageID: UUID, fingerprint rawFingerprint: String) async throws {
        let fingerprint = try normalizedFingerprint(rawFingerprint)
        guard !usesUnifiedRepository else {
            throw DeviceMessageStoreError.persistenceBlocked(.stateConflict)
        }
        try await applyRepositoryMutation {
            try await repository.updateDeliveryState(
                messageID: messageID,
                conversationFingerprint: fingerprint,
                deliveryState: .sent
            )
        }
    }

    public func markFailed(messageID: UUID, fingerprint rawFingerprint: String) async throws {
        let fingerprint = try normalizedFingerprint(rawFingerprint)
        guard !usesUnifiedRepository else {
            throw DeviceMessageStoreError.persistenceBlocked(.stateConflict)
        }
        try await applyRepositoryMutation {
            try await repository.updateDeliveryState(
                messageID: messageID,
                conversationFingerprint: fingerprint,
                deliveryState: .failed
            )
        }
    }

    public func receiveIncoming(
        text rawText: String,
        fingerprint rawFingerprint: String,
        messageID: UUID,
        sentAt: Date
    ) async throws {
        let text = try DeviceTextMessagePolicy.validatedText(rawText)
        let fingerprint = try normalizedFingerprint(rawFingerprint)
        if usesUnifiedRepository {
            let change = try await UnifiedDeviceMessagingRuntime.shared.recordIncoming(
                PersistedMessageRecord(
                    id: messageID,
                    conversationFingerprint: fingerprint,
                    targetDeviceID: nil,
                    direction: .incoming,
                    text: text,
                    timestamp: sentAt,
                    deliveryState: .delivered
                )
            )
            if try applyUnifiedChange(change) == .requiresResynchronization {
                try applyUnifiedSnapshot(
                    try await UnifiedDeviceMessagingRuntime.shared.currentSnapshot()
                )
            }
            return
        }
        try await applyRepositoryMutation {
            try await repository.receiveIncoming(
                text: text,
                conversationFingerprint: fingerprint,
                messageID: messageID,
                sentAt: sentAt
            )
        }
    }

    public func clearConversation(fingerprint rawFingerprint: String) async throws {
        let fingerprint = try normalizedFingerprint(rawFingerprint)
        if usesUnifiedRepository {
            guard let unifiedMutationHandler else {
                throw DeviceMessageStoreError.persistenceBlocked(.stateConflict)
            }
            try await unifiedMutationHandler(.clearConversation(fingerprint))
            return
        }
        try await applyRepositoryMutation {
            try await repository.clearConversation(fingerprint)
        }
    }

    public func clearAllForRecovery() async throws {
        guard !usesUnifiedRepository else {
            throw DeviceMessageStoreError.persistenceBlocked(.stateConflict)
        }
        try await applyRepositoryMutation {
            try await repository.clearAll()
        }
    }

    func installUnifiedMutationHandler(
        _ handler: @escaping @MainActor @Sendable (
            UnifiedDeviceMessageStoreMutation
        ) async throws -> Void
    ) {
        guard usesUnifiedRepository else { return }
        unifiedMutationHandler = handler
    }

    private func bootstrap() async {
        if usesUnifiedRepository {
            do {
                try applyUnifiedSnapshot(
                    try await UnifiedDeviceMessagingRuntime.shared.bootstrap()
                )
            } catch {
                persistenceState = .blocked(.persistenceFailure)
            }
            return
        }
        do {
            apply(try await repository.bootstrap())
        } catch {
            apply(await repository.currentSnapshot())
        }
    }

    private func normalizedFingerprint(_ raw: String) throws -> String {
        do {
            return try DeviceTextMessagePolicy.normalizedConversationFingerprint(raw)
        } catch {
            throw DeviceMessageStoreError.invalidConversationFingerprint
        }
    }

    private func applyRepositoryMutation(
        _ operation: @MainActor () async throws -> DeviceMessageConversationRepository.Snapshot
    ) async throws {
        do {
            apply(try await operation())
        } catch {
            apply(await repository.currentSnapshot())
            throw error
        }
    }

    private func apply(_ snapshot: DeviceMessageConversationRepository.Snapshot) {
        guard snapshot.generation >= latestGeneration else { return }
        latestGeneration = snapshot.generation
        conversations = snapshot.conversations
        persistenceState = snapshot.persistenceState
    }

    func applyUnifiedSnapshot(_ snapshot: MessageRepositorySnapshot) throws {
        guard snapshot.generation >= latestGeneration else { return }
        var next: [String: [Message]] = [:]
        for record in snapshot.messages {
            next[record.conversationFingerprint, default: []]
                .append(Self.projectedMessage(from: record))
        }
        guard next.values.allSatisfy({ $0.count <= 500 }) else {
            throw DeviceMessageStoreError.conversationCapacityExceeded
        }
        latestGeneration = snapshot.generation
        conversations = next
        migrationIssues = snapshot.migrationIssues
        persistenceState = .ready
    }

    /// Applies the exact rows one committed repository transaction changed.
    /// Repository generations advance monotonically, so a change whose basis
    /// matches the projection is applied, a change that does not advance past
    /// the projection is already reflected, and anything else requires a full
    /// snapshot resynchronization. Migration issues never change after
    /// bootstrap, so they are left untouched here.
    func applyUnifiedChange(
        _ change: MessageRepositoryChange
    ) throws -> UnifiedProjectionApplication {
        guard change.basisGeneration == latestGeneration else {
            return change.generation <= latestGeneration
                ? .alreadyReflected
                : .requiresResynchronization
        }
        guard change.generation > change.basisGeneration || change.isEmpty else {
            return .requiresResynchronization
        }
        var next = conversations
        var touchedFingerprints = Set<String>()
        for removal in change.removedMessages {
            guard var thread = next[removal.conversationFingerprint],
                  let index = thread.firstIndex(where: { $0.id == removal.id }) else {
                return .requiresResynchronization
            }
            thread.remove(at: index)
            if thread.isEmpty {
                next.removeValue(forKey: removal.conversationFingerprint)
            } else {
                next[removal.conversationFingerprint] = thread
            }
            touchedFingerprints.insert(removal.conversationFingerprint)
        }
        for record in change.upsertedMessages {
            var thread = next[record.conversationFingerprint] ?? []
            if let index = thread.firstIndex(where: { $0.id == record.id }) {
                thread.remove(at: index)
            }
            let message = Self.projectedMessage(from: record)
            thread.insert(message, at: Self.orderedInsertionIndex(of: message, in: thread))
            next[record.conversationFingerprint] = thread
            touchedFingerprints.insert(record.conversationFingerprint)
        }
        guard touchedFingerprints.allSatisfy({ (next[$0]?.count ?? 0) <= 500 }) else {
            throw DeviceMessageStoreError.conversationCapacityExceeded
        }
        latestGeneration = change.generation
        conversations = next
        persistenceState = .ready
        return .applied
    }

    private static func projectedMessage(from record: PersistedMessageRecord) -> Message {
        let direction: Direction
        switch record.direction {
        case .incoming: direction = .incoming
        case .outgoing: direction = .outgoing
        }
        let deliveryState: DeliveryState
        switch record.deliveryState {
        case .pending: deliveryState = .pending
        case .sent: deliveryState = .sent
        case .delivered: deliveryState = .delivered
        case .failed: deliveryState = .failed
        }
        return Message(
            id: record.id,
            direction: direction,
            text: record.text,
            timestamp: record.timestamp,
            deliveryState: deliveryState,
            targetDeviceID: record.targetDeviceID
        )
    }

    /// Binary search for the position that keeps the thread ordered exactly
    /// like the repository projection: timestamp, then identifier. Hex UUID
    /// strings order identically regardless of letter case, so comparing
    /// `uuidString` matches SQLite ordering the canonical lowercase form.
    private static func orderedInsertionIndex(
        of message: Message,
        in thread: [Message]
    ) -> Int {
        var low = 0
        var high = thread.count
        while low < high {
            let mid = (low + high) / 2
            if Self.orderedBefore(thread[mid], message) {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    private static func orderedBefore(_ lhs: Message, _ rhs: Message) -> Bool {
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
