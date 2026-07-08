import Combine
import Foundation

@available(iOS 17.0, *)
public enum DeviceMessagingError: Error, LocalizedError, Sendable {
    case emptyText
    case textTooLong(maxCharacters: Int)
    case missingTrustedConversationFingerprint([String])
    case ambiguousTrustedConversationFingerprint([String])
    case invalidQueuedPayload(UUID)
    case transportFailed(String)

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
        case .transportFailed:
            return "Device message transport failed"
        }
    }
}

@available(iOS 17.0, *)
@MainActor
public final class DeviceMessagingService: ObservableObject {
    public static let shared = DeviceMessagingService()
    public static let maxTextCharacters = 8_000

    private struct QueuedTextEnvelope: Codable, Sendable {
        let payload: AppMessage.TextMessagePayload
        let conversationFingerprint: String
    }

    private var started = false
    private var cancellables = Set<AnyCancellable>()
    private var onlineDeviceIds: Set<String> = []

    private init() {}

    public func start() {
        guard !started else { return }
        started = true

        P2PConnectionManager.instance.$activeConnections
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connections in
                self?.syncOnlineDevices(connections)
            }
            .store(in: &cancellables)
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
            case .transportFailed:
                return "transport_failed"
            }
        }

        if let error = error as? DeviceMessageStoreError {
            switch error {
            case .invalidConversationFingerprint:
                return "invalid_conversation_fingerprint"
            case .messageNotFound:
                return "message_not_found"
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
            default:
                return "p2p_error"
            }
        }

        if let error = error as? OfflineMessageQueueError {
            switch error {
            case .capacityExceeded:
                return "offline_queue_capacity_exceeded"
            case .persistenceFailed:
                return "offline_queue_persistence_failed"
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
        toDeviceId deviceId: String,
        conversationFingerprint rawFingerprint: String
    ) async throws {
        let text = try validatedText(rawText)
        let conversationFingerprint = try validConversationFingerprint(rawFingerprint)
        let payload = AppMessage.TextMessagePayload(text: text)
        let queuedPayload = try encodedQueuePayload(
            payload,
            conversationFingerprint: conversationFingerprint
        )

        try DeviceMessageStore.shared.appendOutgoing(
            text: text,
            conversationFingerprint: conversationFingerprint,
            messageId: payload.id,
            sentAt: payload.sentAt
        )

        do {
            try await P2PConnectionManager.instance.sendTextMessage(to: deviceId, payload: payload)
            try DeviceMessageStore.shared.markSent(
                messageId: payload.id,
                conversationFingerprint: conversationFingerprint
            )
        } catch P2PError.connectionFailed {
            try enqueueOfflineTextMessage(
                deviceId: deviceId,
                queuedPayload: queuedPayload,
                messageId: payload.id,
                conversationFingerprint: conversationFingerprint
            )
        } catch P2PError.noSessionKey {
            try enqueueOfflineTextMessage(
                deviceId: deviceId,
                queuedPayload: queuedPayload,
                messageId: payload.id,
                conversationFingerprint: conversationFingerprint
            )
        } catch {
            throw DeviceMessagingError.transportFailed(Self.logSafeErrorSummary(error))
        }
    }

    private func enqueueOfflineTextMessage(
        deviceId: String,
        queuedPayload: Data,
        messageId: UUID,
        conversationFingerprint: String
    ) throws {
        do {
            try OfflineMessageQueue.shared.enqueue(
                targetDeviceId: deviceId,
                messageType: .text,
                payload: queuedPayload
            )
        } catch {
            let queueError = error
            do {
                try DeviceMessageStore.shared.markFailed(
                    messageId: messageId,
                    conversationFingerprint: conversationFingerprint
                )
            } catch {
                SkyBridgeLogger.shared.error(
                    "Device message failed-state update failed: \(Self.logSafeErrorSummary(error))"
                )
            }
            throw DeviceMessagingError.transportFailed(Self.logSafeErrorSummary(queueError))
        }
    }

    private func markQueuedTextMessageFailed(
        messageId: UUID,
        conversationFingerprint: String
    ) {
        do {
            try DeviceMessageStore.shared.markFailed(
                messageId: messageId,
                conversationFingerprint: conversationFingerprint
            )
        } catch {
            SkyBridgeLogger.shared.error(
                "Queued device message failed-state update failed: \(Self.logSafeErrorSummary(error))"
            )
        }
    }

    public func handleIncoming(
        _ payload: AppMessage.TextMessagePayload,
        conversationFingerprint rawFingerprint: String
    ) throws {
        let text = try validatedText(payload.text)
        let conversationFingerprint = try validConversationFingerprint(rawFingerprint)
        try DeviceMessageStore.shared.receiveIncoming(
            text: text,
            conversationFingerprint: conversationFingerprint,
            messageId: payload.id,
            sentAt: payload.sentAt
        )
    }

    public func handleIncoming(
        _ payload: AppMessage.TextMessagePayload,
        fromPeerIds peerIds: [String]
    ) throws {
        let conversationFingerprint = try uniqueConversationFingerprint(forAny: peerIds)
        try handleIncoming(payload, conversationFingerprint: conversationFingerprint)
    }

    private func syncOnlineDevices(_ connections: [Connection]) {
        let connected = Set(connections.filter { $0.status == .connected }.map(\.device.id))
        let newlyOnline = connected.subtracting(onlineDeviceIds)
        let wentOffline = onlineDeviceIds.subtracting(connected)
        onlineDeviceIds = connected

        for deviceId in newlyOnline {
            OfflineMessageQueue.shared.onDeviceOnline(deviceId) { [weak self] message in
                await self?.deliverQueuedMessage(message) ?? false
            }
        }

        for _ in wentOffline {
            do {
                try OfflineMessageQueue.shared.cleanupExpiredMessages()
            } catch {
                SkyBridgeLogger.shared.error(
                    "Device message offline cleanup failed: \(Self.logSafeErrorSummary(error))"
                )
            }
            SkyBridgeLogger.shared.info("Device message peer offline")
        }
    }

    private func deliverQueuedMessage(_ message: OfflineMessage) async -> Bool {
        guard message.messageType == .text,
              let envelope = try? JSONDecoder().decode(QueuedTextEnvelope.self, from: message.payload) else {
            SkyBridgeLogger.shared.error("Invalid queued device text message payload: \(message.id)")
            return false
        }

        do {
            try await P2PConnectionManager.instance.sendTextMessage(
                to: message.targetDeviceId,
                payload: envelope.payload
            )
            try DeviceMessageStore.shared.markSent(
                messageId: envelope.payload.id,
                conversationFingerprint: envelope.conversationFingerprint
            )
            return true
        } catch P2PError.connectionFailed {
            return false
        } catch P2PError.noSessionKey {
            return false
        } catch {
            markQueuedTextMessageFailed(
                messageId: envelope.payload.id,
                conversationFingerprint: envelope.conversationFingerprint
            )
            SkyBridgeLogger.shared.error(
                "Queued device message delivery failed: \(Self.logSafeErrorSummary(error))"
            )
            return false
        }
    }

    private func encodedQueuePayload(
        _ payload: AppMessage.TextMessagePayload,
        conversationFingerprint: String
    ) throws -> Data {
        try JSONEncoder().encode(
            QueuedTextEnvelope(payload: payload, conversationFingerprint: conversationFingerprint)
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
        return fingerprints.first!
    }

    private func validConversationFingerprint(_ raw: String) throws -> String {
        guard let fingerprint = DeviceMessageStore.normalizedConversationFingerprint(raw) else {
            throw DeviceMessageStoreError.invalidConversationFingerprint
        }
        return fingerprint
    }

    private func validatedText(_ raw: String) throws -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw DeviceMessagingError.emptyText }
        guard text.count <= Self.maxTextCharacters else {
            throw DeviceMessagingError.textTooLong(maxCharacters: Self.maxTextCharacters)
        }
        return text
    }
}
