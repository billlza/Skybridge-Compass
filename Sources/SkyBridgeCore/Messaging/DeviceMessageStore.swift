import Foundation
import Combine

/// 设备间文本消息的持久化会话存储。
///
/// 以稳定的公钥指纹（`TrustRecord.pubKeyFP`，与 F2 一致）为会话键，避免设备 id 轮换导致历史错位。
/// 跨平台（不依赖 AppKit），UI 与传输层共用。
@available(macOS 14.0, iOS 17.0, *)
@MainActor
public final class DeviceMessageStore: ObservableObject {
    public static let shared = DeviceMessageStore()

    public enum Direction: String, Codable, Sendable { case incoming, outgoing }
    public enum DeliveryState: String, Codable, Sendable { case pending, sent, delivered }

    public struct Message: Identifiable, Codable, Sendable, Equatable {
        public let id: UUID
        public let direction: Direction
        public let text: String
        public let timestamp: Date
        public var deliveryState: DeliveryState

        public init(id: UUID = UUID(), direction: Direction, text: String, timestamp: Date = Date(), deliveryState: DeliveryState) {
            self.id = id
            self.direction = direction
            self.text = text
            self.timestamp = timestamp
            self.deliveryState = deliveryState
        }
    }

    /// 会话表：pubKeyFP -> 该设备的消息列表（按时间）。
    @Published public private(set) var conversations: [String: [Message]] = [:]

    private let store = CodablePersistenceStore<[String: [Message]]>(
        location: .protectedApplicationSupport(path: "Messaging/conversations.json")
    )
    private let maxPerConversation = 500

    private init() {
        conversations = store.load() ?? [:]
    }

    public func messages(fingerprint: String) -> [Message] {
        conversations[fingerprint] ?? []
    }

    /// 记录一条发出的消息（初始 pending）。
    public func appendOutgoing(text: String, fingerprint: String, messageId: UUID) {
        guard !fingerprint.isEmpty else { return }
        append(Message(id: messageId, direction: .outgoing, text: text, deliveryState: .pending), fingerprint: fingerprint)
    }

    /// 标记某条发出的消息已成功投递（已通过 P2P 发出）。
    public func markDelivered(messageId: UUID, fingerprint: String) {
        guard var msgs = conversations[fingerprint],
              let idx = msgs.firstIndex(where: { $0.id == messageId }) else { return }
        guard msgs[idx].deliveryState != .sent else { return }
        msgs[idx].deliveryState = .sent
        conversations[fingerprint] = msgs
        persist()
    }

    /// 收到一条远端消息（按 id 去重）。
    public func receiveIncoming(text: String, fingerprint: String, messageId: UUID, sentAt: Date) {
        guard !fingerprint.isEmpty else { return }
        var msgs = conversations[fingerprint] ?? []
        guard !msgs.contains(where: { $0.id == messageId }) else { return }
        msgs.append(Message(id: messageId, direction: .incoming, text: text, timestamp: sentAt, deliveryState: .delivered))
        conversations[fingerprint] = trimmed(msgs)
        persist()
    }

    public func clearConversation(fingerprint: String) {
        guard conversations[fingerprint] != nil else { return }
        conversations[fingerprint] = nil
        persist()
    }

    private func append(_ msg: Message, fingerprint: String) {
        var msgs = conversations[fingerprint] ?? []
        msgs.append(msg)
        conversations[fingerprint] = trimmed(msgs)
        persist()
    }

    private func trimmed(_ msgs: [Message]) -> [Message] {
        msgs.count > maxPerConversation ? Array(msgs.suffix(maxPerConversation)) : msgs
    }

    private func persist() {
        try? store.save(conversations)
    }
}
