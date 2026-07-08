import XCTest
@testable import SkyBridgeCompass_iOS

@MainActor
@available(iOS 17.0, *)
final class DeviceMessagingServiceTests: XCTestCase {
    func testConversationFingerprintRequiresCanonicalSHA256Hex() {
        let valid = String(repeating: "a", count: 64)

        XCTAssertEqual(DeviceMessageStore.normalizedConversationFingerprint(valid.uppercased()), valid)
        XCTAssertNil(DeviceMessageStore.normalizedConversationFingerprint(String(repeating: "a", count: 63)))
        XCTAssertNil(DeviceMessageStore.normalizedConversationFingerprint(String(repeating: "g", count: 64)))
        XCTAssertNil(DeviceMessageStore.normalizedConversationFingerprint(" device-id "))
    }

    func testLogSafeSummaryDoesNotExposeIdentifiersOrFingerprints() {
        let fingerprint = String(repeating: "b", count: 64)

        let missing = DeviceMessagingError.missingTrustedConversationFingerprint(["peer-secret-id"])
        let ambiguous = DeviceMessagingError.ambiguousTrustedConversationFingerprint([fingerprint])
        let persistence = DeviceMessageStoreError.persistenceFailed("path=/private/device-conversations.json")
        let queuePersistence = OfflineMessageQueueError.persistenceFailed
        let queueCapacity = OfflineMessageQueueError.capacityExceeded(maxMessages: 500)

        XCTAssertEqual(
            DeviceMessagingService.logSafeErrorSummary(missing),
            "missing_trusted_conversation_fingerprint"
        )
        XCTAssertEqual(
            DeviceMessagingService.logSafeErrorSummary(ambiguous),
            "ambiguous_trusted_conversation_fingerprint"
        )
        XCTAssertEqual(DeviceMessagingService.logSafeErrorSummary(persistence), "persistence_failed")
        XCTAssertEqual(
            DeviceMessagingService.logSafeErrorSummary(queuePersistence),
            "offline_queue_persistence_failed"
        )
        XCTAssertEqual(
            DeviceMessagingService.logSafeErrorSummary(queueCapacity),
            "offline_queue_capacity_exceeded"
        )

        XCTAssertFalse(DeviceMessagingService.logSafeErrorSummary(missing).contains("peer-secret-id"))
        XCTAssertFalse(DeviceMessagingService.logSafeErrorSummary(ambiguous).contains(fingerprint))
        XCTAssertFalse(DeviceMessagingService.logSafeErrorSummary(persistence).contains("/private"))
        XCTAssertFalse(missing.localizedDescription.contains("peer-secret-id"))
        XCTAssertFalse(ambiguous.localizedDescription.contains(fingerprint))
        XCTAssertFalse(persistence.localizedDescription.contains("/private"))
    }

    func testOutgoingMessageCanBeMarkedFailedWithoutDroppingConversation() throws {
        let fingerprint = String(repeating: "c", count: 64)
        let messageId = UUID()
        let store = DeviceMessageStore.shared

        try store.clearConversation(conversationFingerprint: fingerprint)
        try store.appendOutgoing(
            text: "queued hello",
            conversationFingerprint: fingerprint,
            messageId: messageId,
            sentAt: Date(timeIntervalSince1970: 1)
        )
        try store.markFailed(messageId: messageId, conversationFingerprint: fingerprint)

        let messages = store.messages(conversationFingerprint: fingerprint)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.id, messageId)
        XCTAssertEqual(messages.first?.deliveryState, .failed)

        try store.clearConversation(conversationFingerprint: fingerprint)
    }
}
