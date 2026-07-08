import Combine
import Foundation

@available(iOS 17.0, *)
public enum DeviceMessageStoreError: Error, LocalizedError, Sendable {
    case invalidConversationFingerprint
    case messageNotFound(UUID)
    case persistenceFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConversationFingerprint:
            return "Missing or invalid device message conversation fingerprint"
        case .messageNotFound(let id):
            return "Device message not found: \(id.uuidString)"
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

    private static let store = CodablePersistenceStore<[String: [Message]]>(
        location: .protectedApplicationSupport(path: "Messaging/device-conversations.json")
    )
    private static let maxMessagesPerConversation = 500

    private init() {
        conversations = Self.store.load() ?? [:]
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
        let key = try Self.validConversationFingerprint(conversationFingerprint)
        var next = conversations
        var messages = next[key] ?? []
        messages.append(
            Message(
                id: messageId,
                direction: .outgoing,
                text: text,
                timestamp: sentAt,
                deliveryState: .pending
            )
        )
        next[key] = Self.trimmed(messages)
        try commit(next)
    }

    public func markSent(messageId: UUID, conversationFingerprint: String) throws {
        try updateDeliveryState(
            messageId: messageId,
            conversationFingerprint: conversationFingerprint,
            deliveryState: .sent
        )
    }

    public func markFailed(messageId: UUID, conversationFingerprint: String) throws {
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
        let key = try Self.validConversationFingerprint(conversationFingerprint)
        var next = conversations
        guard var messages = next[key],
              let index = messages.firstIndex(where: { $0.id == messageId }) else {
            throw DeviceMessageStoreError.messageNotFound(messageId)
        }
        guard messages[index].deliveryState != deliveryState else { return }
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
        let key = try Self.validConversationFingerprint(conversationFingerprint)
        var next = conversations
        var messages = next[key] ?? []
        guard !messages.contains(where: { $0.id == messageId }) else { return }
        messages.append(
            Message(
                id: messageId,
                direction: .incoming,
                text: text,
                timestamp: sentAt,
                deliveryState: .delivered
            )
        )
        next[key] = Self.trimmed(messages)
        try commit(next)
    }

    public func clearConversation(conversationFingerprint: String) throws {
        let key = try Self.validConversationFingerprint(conversationFingerprint)
        guard conversations[key] != nil else { return }
        var next = conversations
        next[key] = nil
        try commit(next)
    }

    public static func normalizedConversationFingerprint(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.count == 64, value.allSatisfy(\.isHexDigit) else { return nil }
        return value
    }

    private static func validConversationFingerprint(_ raw: String) throws -> String {
        guard let value = normalizedConversationFingerprint(raw) else {
            throw DeviceMessageStoreError.invalidConversationFingerprint
        }
        return value
    }

    private static func trimmed(_ messages: [Message]) -> [Message] {
        guard messages.count > maxMessagesPerConversation else { return messages }
        return Array(messages.suffix(maxMessagesPerConversation))
    }

    private func commit(_ next: [String: [Message]]) throws {
        let previous = conversations
        conversations = next
        do {
            try Self.store.save(next)
            lastPersistenceError = nil
        } catch {
            conversations = previous
            let reason = "persistence_failed"
            lastPersistenceError = reason
            SkyBridgeLogger.shared.error("Device message persistence failed")
            throw DeviceMessageStoreError.persistenceFailed(reason)
        }
    }
}
