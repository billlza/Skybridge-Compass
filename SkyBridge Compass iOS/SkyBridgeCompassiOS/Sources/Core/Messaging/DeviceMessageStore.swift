import Combine
import Foundation
import SkyBridgeMessagePersistence
import SkyBridgeProtocolCore

/// Narrow persistence boundary for the device-messaging state machines.
/// A missing file and an unreadable file intentionally remain distinguishable.
struct MessagingPersistence<Value: Codable> {
    private let loadImplementation: () throws -> Value?
    private let saveImplementation: (Value) throws -> Void
    private let quarantineImplementation: () throws -> Void

    init(store: CodablePersistenceStore<Value>) {
        loadImplementation = { try store.loadOrThrow() }
        saveImplementation = { try store.save($0) }
        quarantineImplementation = { try store.quarantine() }
    }

    init(
        load: @escaping () throws -> Value?,
        save: @escaping (Value) throws -> Void,
        quarantine: @escaping () throws -> Void = {}
    ) {
        loadImplementation = load
        saveImplementation = save
        quarantineImplementation = quarantine
    }

    func loadOrThrow() throws -> Value? {
        try loadImplementation()
    }

    func save(_ value: Value) throws {
        try saveImplementation(value)
    }

    func quarantine() throws {
        try quarantineImplementation()
    }
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

@available(iOS 17.0, *)
public enum DeviceMessageStoreError: Error, LocalizedError, Sendable, Equatable {
    case invalidConversationFingerprint
    case invalidMessageContent
    case messageStateConflict
    case messageNotFound(UUID)
    case conversationCapacityExceeded
    case pendingOutgoingMessagesPreventClear(count: Int)
    case storageCapacityExceeded(actualBytes: Int, maximumBytes: Int)
    case persistenceFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConversationFingerprint:
            return "Missing or invalid device message conversation fingerprint"
        case .invalidMessageContent:
            return "Device message content or timestamp is invalid"
        case .messageStateConflict:
            return "Device message identifier or delivery state conflicts with existing state"
        case .messageNotFound(let id):
            return "Device message not found: \(id.uuidString)"
        case .conversationCapacityExceeded:
            return "Device message conversation capacity was exceeded"
        case .pendingOutgoingMessagesPreventClear(let count):
            return "Cannot clear a conversation with \(count) pending outgoing messages"
        case .storageCapacityExceeded(let actualBytes, let maximumBytes):
            return "Device message storage requires \(actualBytes) bytes; maximum is \(maximumBytes) bytes"
        case .persistenceFailed:
            return "Device message persistence failed"
        }
    }
}

@available(iOS 17.0, *)
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

        public init(
            id: UUID = UUID(),
            direction: Direction,
            text: String,
            timestamp: Date = Date(),
            deliveryState: DeliveryState
        ) {
            self.id = id
            self.direction = direction
            self.text = text
            self.timestamp = timestamp
            self.deliveryState = deliveryState
        }
    }

    @Published public private(set) var conversations: [String: [Message]] = [:]
    @Published public private(set) var lastPersistenceError: String?
    @Published public private(set) var migrationIssues: [MessageRepositoryMigrationIssue] = []

    /// A strict-load or save failure blocks all later mutations in this process.
    /// This prevents an empty in-memory value from overwriting unreadable state.
    @Published public private(set) var isPersistenceBlocked = false

    static let maximumMessagesPerConversation = 500
    static let maximumPersistenceBytes = 4 * 1_024 * 1_024

    private static let defaultPersistence = MessagingPersistence(
        store: CodablePersistenceStore<[String: [Message]]>(
            location: .protectedApplicationSupport(path: "Messaging/device-conversations.json"),
            maximumPayloadBytes: maximumPersistenceBytes
        )
    )
    private let persistence: MessagingPersistence<[String: [Message]]>
    private let usesUnifiedRepository: Bool
    private var latestRepositoryGeneration: UInt64 = 0

    private init() {
        persistence = Self.defaultPersistence
        usesUnifiedRepository = true
        Task { @MainActor [weak self] in
            await self?.bootstrapUnifiedRepository()
        }
    }

    init(testingPersistence: MessagingPersistence<[String: [Message]]>) {
        persistence = testingPersistence
        usesUnifiedRepository = false
        loadPersistedConversations()
    }

    public func messages(conversationFingerprint: String) -> [Message] {
        guard let key = Self.normalizedConversationFingerprint(conversationFingerprint) else {
            return []
        }
        return conversations[key] ?? []
    }

    public func appendOutgoing(
        text: String,
        conversationFingerprint: String,
        messageId: UUID,
        sentAt: Date
    ) throws {
        guard !usesUnifiedRepository else {
            throw DeviceMessageStoreError.persistenceFailed("coordinated_repository_required")
        }
        let key = try Self.validConversationFingerprint(conversationFingerprint)
        let text = try Self.validatedMessageText(text)
        try Self.validateTimestamp(sentAt)
        var next = conversations
        var messages = next[key] ?? []
        guard !messages.contains(where: { $0.id == messageId }) else {
            throw DeviceMessageStoreError.messageStateConflict
        }
        messages.append(
            Message(
                id: messageId,
                direction: .outgoing,
                text: text,
                timestamp: sentAt,
                deliveryState: .pending
            )
        )
        let bounded = try Self.bounded(messages)
        guard bounded.contains(where: { $0.id == messageId }) else {
            throw DeviceMessageStoreError.conversationCapacityExceeded
        }
        next[key] = bounded
        try commit(next)
    }

    public func markSent(messageId: UUID, conversationFingerprint: String) throws {
        guard !usesUnifiedRepository else {
            throw DeviceMessageStoreError.persistenceFailed("coordinated_repository_required")
        }
        try updateDeliveryState(
            messageId: messageId,
            conversationFingerprint: conversationFingerprint,
            deliveryState: .sent
        )
    }

    public func markFailed(messageId: UUID, conversationFingerprint: String) throws {
        guard !usesUnifiedRepository else {
            throw DeviceMessageStoreError.persistenceFailed("coordinated_repository_required")
        }
        try updateDeliveryState(
            messageId: messageId,
            conversationFingerprint: conversationFingerprint,
            deliveryState: .failed
        )
    }

    private func updateDeliveryState(
        messageId: UUID,
        conversationFingerprint: String,
        deliveryState: DeliveryState
    ) throws {
        guard !usesUnifiedRepository else {
            throw DeviceMessageStoreError.persistenceFailed("coordinated_repository_required")
        }
        let key = try Self.validConversationFingerprint(conversationFingerprint)
        var next = conversations
        guard var messages = next[key],
              let index = messages.firstIndex(where: { $0.id == messageId }) else {
            throw DeviceMessageStoreError.messageNotFound(messageId)
        }
        guard messages[index].direction == .outgoing,
              messages[index].deliveryState != .delivered else {
            throw DeviceMessageStoreError.messageStateConflict
        }
        guard messages[index].deliveryState != deliveryState else { return }
        guard messages[index].deliveryState == .pending else {
            throw DeviceMessageStoreError.messageStateConflict
        }
        messages[index].deliveryState = deliveryState
        next[key] = messages
        try commit(next)
    }

    public func receiveIncoming(
        text: String,
        conversationFingerprint: String,
        messageId: UUID,
        sentAt: Date
    ) throws {
        guard !usesUnifiedRepository else {
            throw DeviceMessageStoreError.persistenceFailed(
                "coordinated_repository_required"
            )
        }
        let key = try Self.validConversationFingerprint(conversationFingerprint)
        let text = try Self.validatedMessageText(text)
        try Self.validateTimestamp(sentAt)
        var next = conversations
        var messages = next[key] ?? []
        if let existing = messages.first(where: { $0.id == messageId }) {
            guard existing.direction == .incoming,
                  existing.deliveryState == .delivered,
                  existing.text == text,
                  existing.timestamp == sentAt else {
                throw DeviceMessageStoreError.messageStateConflict
            }
            return
        }
        messages.append(
            Message(
                id: messageId,
                direction: .incoming,
                text: text,
                timestamp: sentAt,
                deliveryState: .delivered
            )
        )
        let bounded = try Self.bounded(messages)
        guard bounded.contains(where: { $0.id == messageId }) else {
            throw DeviceMessageStoreError.conversationCapacityExceeded
        }
        next[key] = bounded
        try commit(next)
    }

    public func clearConversation(conversationFingerprint: String) throws {
        guard !usesUnifiedRepository else {
            throw DeviceMessageStoreError.persistenceFailed("coordinated_repository_required")
        }
        let key = try Self.validConversationFingerprint(conversationFingerprint)
        try requirePersistenceAvailable()
        guard let messages = conversations[key] else { return }
        let pendingOutgoingCount = messages.lazy.filter(Self.isPendingOutgoing).count
        guard pendingOutgoingCount == 0 else {
            throw DeviceMessageStoreError.pendingOutgoingMessagesPreventClear(
                count: pendingOutgoingCount
            )
        }
        var next = conversations
        next[key] = nil
        try commit(next)
    }

    /// Explicit destructive recovery boundary. The unreadable primary is moved
    /// aside before a new empty store is created; normal mutations cannot enter
    /// this path implicitly.
    public func resetAfterQuarantiningUnreadableState() throws {
        guard !usesUnifiedRepository else {
            throw DeviceMessageStoreError.persistenceFailed("coordinated_repository_required")
        }
        guard isPersistenceBlocked else { return }
        do {
            try persistence.quarantine()
            try persistence.save([:])
        } catch {
            lastPersistenceError = "persistence_recovery_failed"
            throw DeviceMessageStoreError.persistenceFailed("persistence_recovery_failed")
        }
        conversations = [:]
        lastPersistenceError = nil
        isPersistenceBlocked = false
    }

    public static func normalizedConversationFingerprint(_ raw: String?) -> String? {
        guard let raw else { return nil }
        do {
            return try DeviceTextMessagePolicy.normalizedConversationFingerprint(raw)
        } catch {
            return nil
        }
    }

    private static func validConversationFingerprint(_ raw: String) throws -> String {
        guard let value = normalizedConversationFingerprint(raw) else {
            throw DeviceMessageStoreError.invalidConversationFingerprint
        }
        return value
    }

    private static func validatedMessageText(_ raw: String) throws -> String {
        do {
            return try DeviceTextMessagePolicy.validatedText(raw)
        } catch {
            throw DeviceMessageStoreError.invalidMessageContent
        }
    }

    private static func validateTimestamp(_ timestamp: Date) throws {
        guard timestamp.timeIntervalSinceReferenceDate.isFinite else {
            throw DeviceMessageStoreError.invalidMessageContent
        }
    }

    private static func bounded(_ messages: [Message]) throws -> [Message] {
        guard messages.count > maximumMessagesPerConversation else { return messages }

        let pendingOutgoingCount = messages.lazy.filter(isPendingOutgoing).count
        guard pendingOutgoingCount <= maximumMessagesPerConversation else {
            throw DeviceMessageStoreError.conversationCapacityExceeded
        }

        var remainingRemovals = messages.count - maximumMessagesPerConversation
        var retained: [Message] = []
        retained.reserveCapacity(maximumMessagesPerConversation)
        for message in messages {
            if remainingRemovals > 0, !isPendingOutgoing(message) {
                remainingRemovals -= 1
            } else {
                retained.append(message)
            }
        }
        guard remainingRemovals == 0 else {
            throw DeviceMessageStoreError.conversationCapacityExceeded
        }
        return retained
    }

    private static func isPendingOutgoing(_ message: Message) -> Bool {
        message.direction == .outgoing && message.deliveryState == .pending
    }

    private func commit(_ next: [String: [Message]]) throws {
        try requirePersistenceAvailable()
        do {
            try persistence.save(next)
        } catch let error as CodablePersistenceStoreError {
            switch error {
            case let .payloadTooLarge(actualBytes, maximumBytes):
                lastPersistenceError = OfflineDeliveryFailureCode
                    .storageCapacityExceeded.rawValue
                SkyBridgeLogger.shared.error("Device message storage capacity exceeded")
                throw DeviceMessageStoreError.storageCapacityExceeded(
                    actualBytes: actualBytes,
                    maximumBytes: maximumBytes
                )
            }
        } catch {
            let reason = "persistence_failed"
            lastPersistenceError = reason
            isPersistenceBlocked = true
            SkyBridgeLogger.shared.error("Device message persistence failed")
            throw DeviceMessageStoreError.persistenceFailed(reason)
        }
        conversations = next
        lastPersistenceError = nil
    }

    private func loadPersistedConversations() {
        do {
            let loaded = try persistence.loadOrThrow() ?? [:]
            guard Self.isValidPersistedState(loaded) else {
                throw DeviceMessageStoreError.persistenceFailed("invalid_persisted_state")
            }
            conversations = loaded
            lastPersistenceError = nil
            isPersistenceBlocked = false
        } catch {
            conversations = [:]
            lastPersistenceError = "persistence_load_failed"
            isPersistenceBlocked = true
            SkyBridgeLogger.shared.error("Device message persistence load failed")
        }
    }

    private func bootstrapUnifiedRepository() async {
        do {
            try applyUnifiedSnapshot(
                try await IOSUnifiedDeviceMessagingRuntime.shared.bootstrap()
            )
        } catch {
            conversations = [:]
            lastPersistenceError = "unified_persistence_bootstrap_failed"
            isPersistenceBlocked = true
        }
    }

    func applyUnifiedSnapshot(_ snapshot: MessageRepositorySnapshot) throws {
        guard snapshot.generation >= latestRepositoryGeneration else { return }
        var next: [String: [Message]] = [:]
        for record in snapshot.messages {
            next[record.conversationFingerprint, default: []]
                .append(Self.projectedMessage(from: record))
        }
        guard next.values.allSatisfy({ $0.count <= Self.maximumMessagesPerConversation }) else {
            throw DeviceMessageStoreError.conversationCapacityExceeded
        }
        latestRepositoryGeneration = snapshot.generation
        conversations = next
        migrationIssues = snapshot.migrationIssues
        lastPersistenceError = nil
        isPersistenceBlocked = false
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
        guard change.basisGeneration == latestRepositoryGeneration else {
            return change.generation <= latestRepositoryGeneration
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
        guard touchedFingerprints.allSatisfy({
            (next[$0]?.count ?? 0) <= Self.maximumMessagesPerConversation
        }) else {
            throw DeviceMessageStoreError.conversationCapacityExceeded
        }
        latestRepositoryGeneration = change.generation
        conversations = next
        lastPersistenceError = nil
        isPersistenceBlocked = false
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
            deliveryState: deliveryState
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

    private func requirePersistenceAvailable() throws {
        guard !isPersistenceBlocked else {
            throw DeviceMessageStoreError.persistenceFailed(
                lastPersistenceError ?? "persistence_blocked"
            )
        }
    }

    private static func isValidPersistedState(_ state: [String: [Message]]) -> Bool {
        for (fingerprint, messages) in state {
            guard normalizedConversationFingerprint(fingerprint) == fingerprint,
                  messages.count <= maximumMessagesPerConversation,
                  Set(messages.map(\.id)).count == messages.count else {
                return false
            }
            for message in messages {
                guard message.timestamp.timeIntervalSinceReferenceDate.isFinite,
                      isValidDeliveryState(message) else {
                    return false
                }
                do {
                    guard try validatedMessageText(message.text) == message.text else {
                        return false
                    }
                } catch {
                    return false
                }
            }
        }
        return true
    }

    private static func isValidDeliveryState(_ message: Message) -> Bool {
        switch (message.direction, message.deliveryState) {
        case (.incoming, .delivered),
             (.outgoing, .pending),
             (.outgoing, .sent),
             (.outgoing, .failed):
            return true
        case (.incoming, .pending),
             (.incoming, .sent),
             (.incoming, .failed),
             (.outgoing, .delivered):
            return false
        }
    }
}
