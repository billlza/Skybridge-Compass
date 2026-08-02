import Combine
import SkyBridgeMessagePersistence
import SkyBridgeProtocolCore
import XCTest
@testable import SkyBridgeCompass_iOS

private enum DeviceMessagingTestFailure: Error {
    case injectedLoadFailure
    case injectedSaveFailure
    case deliveryTimeout
}

@MainActor
private final class QueuePersistenceProbe {
    var stored: OfflineMessageQueue.StoredMessages?
    var loadError: Error?
    var saveError: Error?
    var maximumEncodedBytes: Int?
    var lastEncodedByteCount: Int?
    var loadCount = 0
    var saveCount = 0
    var quarantineCount = 0
    var now = Date(timeIntervalSince1970: 10_000)

    func persistence() -> MessagingPersistence<OfflineMessageQueue.StoredMessages> {
        MessagingPersistence(
            load: { [self] in
                loadCount += 1
                if let loadError { throw loadError }
                return stored
            },
            save: { [self] state in
                saveCount += 1
                if let saveError { throw saveError }
                let encodedByteCount = try JSONEncoder().encode(state).count
                lastEncodedByteCount = encodedByteCount
                if let maximumEncodedBytes,
                   encodedByteCount > maximumEncodedBytes {
                    throw CodablePersistenceStoreError.payloadTooLarge(
                        actualBytes: encodedByteCount,
                        maximumBytes: maximumEncodedBytes
                    )
                }
                stored = state
            },
            quarantine: { [self] in
                quarantineCount += 1
                stored = nil
                loadError = nil
            }
        )
    }
}

@MainActor
private final class MessageStorePersistenceProbe {
    typealias State = [String: [DeviceMessageStore.Message]]

    var stored: State?
    var loadError: Error?
    var saveError: Error?
    var maximumEncodedBytes: Int?
    var lastEncodedByteCount: Int?
    var saveCount = 0
    var quarantineCount = 0

    func persistence() -> MessagingPersistence<State> {
        MessagingPersistence(
            load: { [self] in
                if let loadError { throw loadError }
                return stored
            },
            save: { [self] state in
                saveCount += 1
                if let saveError { throw saveError }
                let encodedByteCount = try JSONEncoder().encode(state).count
                lastEncodedByteCount = encodedByteCount
                if let maximumEncodedBytes,
                   encodedByteCount > maximumEncodedBytes {
                    throw CodablePersistenceStoreError.payloadTooLarge(
                        actualBytes: encodedByteCount,
                        maximumBytes: maximumEncodedBytes
                    )
                }
                stored = state
            },
            quarantine: { [self] in
                quarantineCount += 1
                stored = nil
                loadError = nil
            }
        )
    }
}

@MainActor
private final class DeviceTextMessageTransportProbe: DeviceTextMessageTransport {
    struct Submission: Equatable {
        let deviceId: String
        let messageId: UUID
        let expectedFingerprint: String
        let deliveryAttemptID: UUID?
    }

    let connections = CurrentValueSubject<[Connection], Never>([])
    var submissions: [Submission] = []
    var sendImplementation: () async throws -> Void = {}

    var deviceMessagingActiveConnections: AnyPublisher<[Connection], Never> {
        connections.eraseToAnyPublisher()
    }

    func sendTextMessage(
        to deviceId: String,
        payload: AppMessage.TextMessagePayload,
        expectedConversationFingerprint: String
    ) async throws {
        submissions.append(
            Submission(
                deviceId: deviceId,
                messageId: payload.id,
                expectedFingerprint: expectedConversationFingerprint,
                deliveryAttemptID: payload.deliveryAttemptID
            )
        )
        try await sendImplementation()
    }
}

private actor DeliverySuspensionProbe {
    private var callCount = 0
    private var observedCancellation = false
    private var continuation: CheckedContinuation<Void, Never>?

    func deliver(as disposition: OfflineDeliveryDisposition) async -> OfflineDeliveryDisposition {
        callCount += 1
        await withCheckedContinuation { continuation = $0 }
        observedCancellation = Task.isCancelled
        return disposition
    }

    func waitUntilCalled(maximumAttempts: Int = 5_000) async throws {
        for _ in 0..<maximumAttempts {
            if callCount > 0 { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw DeviceMessagingTestFailure.deliveryTimeout
    }

    func calls() -> Int { callCount }
    func wasCancelled() -> Bool { observedCancellation }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor DeliveryCounter {
    private var value = 0
    func increment() { value += 1 }
    func count() -> Int { value }
}

@MainActor
@available(iOS 17.0, *)
final class DeviceMessagingServiceTests: XCTestCase {
    private let fingerprint = String(repeating: "a", count: 64)

    private func makeQueue(
        _ probe: QueuePersistenceProbe = QueuePersistenceProbe()
    ) -> OfflineMessageQueue {
        OfflineMessageQueue(
            testingPersistence: probe.persistence(),
            now: { probe.now },
            startRetryTimer: false
        )
    }

    private func makeMessageStore(
        _ probe: MessageStorePersistenceProbe = MessageStorePersistenceProbe()
    ) -> DeviceMessageStore {
        DeviceMessageStore(testingPersistence: probe.persistence())
    }

    private func message(
        id: String = UUID().uuidString,
        target: String = "peer-a",
        payload: Data = Data("payload".utf8),
        status: OfflineMessageStatus = .pending,
        retryCount: Int = 0,
        createdAt: Date = Date(timeIntervalSince1970: 9_000)
    ) -> OfflineMessage {
        OfflineMessage(
            id: id,
            targetDeviceId: target,
            messageType: .text,
            payload: payload,
            createdAt: createdAt,
            expiresAt: Date(timeIntervalSince1970: 20_000),
            retryCount: retryCount,
            status: status
        )
    }

    private func legacyQueuedText(
        queueID: String,
        text: String,
        createdAt: Date = Date(timeIntervalSince1970: 9_000)
    ) throws -> OfflineMessage {
        let payload = AppMessage.TextMessagePayload(
            id: UUID(),
            text: text,
            sentAt: createdAt
        )
        let envelope = try JSONEncoder().encode(IOSDeviceTextQueueEnvelope(
            payload: payload,
            conversationFingerprint: fingerprint
        ))
        return message(
            id: queueID,
            target: "linux-peer-legacy",
            payload: envelope,
            createdAt: createdAt
        )
    }

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
        let storeCapacity = DeviceMessageStoreError.storageCapacityExceeded(
            actualBytes: 4_194_305,
            maximumBytes: 4_194_304
        )
        let pendingClear = DeviceMessageStoreError
            .pendingOutgoingMessagesPreventClear(count: 1)
        let oversizedMessage = OfflineMessageQueueError.messageTooLarge(
            size: 1_048_577,
            maxSize: 1_048_576
        )
        let queueStorageCapacity = OfflineMessageQueueError.storageCapacityExceeded(
            actualBytes: 4_194_305,
            maximumBytes: 4_194_304
        )

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
            OfflineDeliveryFailureCode.queueCapacityExceeded.rawValue
        )
        XCTAssertEqual(
            DeviceMessagingService.logSafeErrorSummary(storeCapacity),
            OfflineDeliveryFailureCode.storageCapacityExceeded.rawValue
        )
        XCTAssertEqual(
            DeviceMessagingService.logSafeErrorSummary(pendingClear),
            OfflineDeliveryFailureCode.stateConflict.rawValue
        )
        XCTAssertEqual(
            DeviceMessagingService.logSafeErrorSummary(oversizedMessage),
            "offline_queue_message_too_large"
        )
        XCTAssertEqual(
            DeviceMessagingService.logSafeErrorSummary(queueStorageCapacity),
            OfflineDeliveryFailureCode.storageCapacityExceeded.rawValue
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
        let store = makeMessageStore()

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
    }

    func testMessageStoreRejectsDuplicateOutgoingIdentifierWithoutWritingInvalidState() throws {
        let probe = MessageStorePersistenceProbe()
        let store = makeMessageStore(probe)
        let messageId = UUID()

        try store.appendOutgoing(
            text: "first",
            conversationFingerprint: fingerprint,
            messageId: messageId,
            sentAt: Date(timeIntervalSince1970: 1)
        )
        let committed = store.messages(conversationFingerprint: fingerprint)
        let saveCount = probe.saveCount

        XCTAssertThrowsError(
            try store.appendOutgoing(
                text: "collision",
                conversationFingerprint: fingerprint,
                messageId: messageId,
                sentAt: Date(timeIntervalSince1970: 2)
            )
        ) { error in
            XCTAssertEqual(error as? DeviceMessageStoreError, .messageStateConflict)
        }

        XCTAssertEqual(probe.saveCount, saveCount)
        XCTAssertEqual(store.messages(conversationFingerprint: fingerprint), committed)
        XCTAssertEqual(probe.stored?[fingerprint], committed)
        XCTAssertFalse(store.isPersistenceBlocked)
    }

    func testIncomingReplayIsIdempotentOnlyForTheExactCanonicalMessage() throws {
        let probe = MessageStorePersistenceProbe()
        let store = makeMessageStore(probe)
        let messageId = UUID()
        let sentAt = Date(timeIntervalSince1970: 10)

        try store.receiveIncoming(
            text: "authenticated payload",
            conversationFingerprint: fingerprint,
            messageId: messageId,
            sentAt: sentAt
        )
        let saveCount = probe.saveCount
        try store.receiveIncoming(
            text: "authenticated payload",
            conversationFingerprint: fingerprint,
            messageId: messageId,
            sentAt: sentAt
        )
        XCTAssertEqual(probe.saveCount, saveCount)

        XCTAssertThrowsError(
            try store.receiveIncoming(
                text: "changed payload",
                conversationFingerprint: fingerprint,
                messageId: messageId,
                sentAt: sentAt
            )
        ) { error in
            XCTAssertEqual(error as? DeviceMessageStoreError, .messageStateConflict)
        }
        XCTAssertEqual(probe.saveCount, saveCount)
        XCTAssertEqual(
            store.messages(conversationFingerprint: fingerprint).map(\.text),
            ["authenticated payload"]
        )
    }

    func testMessageStoreRejectsIncomingStateMutationAndIllegalPersistedDirectionState() throws {
        let incoming = DeviceMessageStore.Message(
            direction: .incoming,
            text: "delivered",
            timestamp: Date(timeIntervalSince1970: 1),
            deliveryState: .delivered
        )
        let liveProbe = MessageStorePersistenceProbe()
        liveProbe.stored = [fingerprint: [incoming]]
        let liveStore = makeMessageStore(liveProbe)

        XCTAssertThrowsError(
            try liveStore.markFailed(
                messageId: incoming.id,
                conversationFingerprint: fingerprint
            )
        ) { error in
            XCTAssertEqual(error as? DeviceMessageStoreError, .messageStateConflict)
        }
        XCTAssertEqual(liveProbe.saveCount, 0)
        XCTAssertEqual(liveStore.messages(conversationFingerprint: fingerprint), [incoming])

        let illegal = DeviceMessageStore.Message(
            direction: .incoming,
            text: "impossible pending inbound",
            timestamp: Date(timeIntervalSince1970: 2),
            deliveryState: .pending
        )
        let invalidProbe = MessageStorePersistenceProbe()
        invalidProbe.stored = [fingerprint: [illegal]]
        let invalidStore = makeMessageStore(invalidProbe)

        XCTAssertTrue(invalidStore.isPersistenceBlocked)
        XCTAssertTrue(invalidStore.messages(conversationFingerprint: fingerprint).isEmpty)
        XCTAssertEqual(invalidProbe.saveCount, 0)
    }

    func testQueueCancellationRestoresPendingWithoutConsumingRetryBudget() async throws {
        let queue = makeQueue()
        let queued = message()
        try queue.enqueue(queued)

        let worker = try queue.onDeviceOnline(queued.targetDeviceId) { _ in .cancelled }
        await worker.value

        XCTAssertEqual(queue.pendingMessages.count, 1)
        XCTAssertEqual(queue.pendingMessages.first?.status, .pending)
        XCTAssertEqual(queue.pendingMessages.first?.retryCount, 0)
        XCTAssertTrue(queue.failedMessages.isEmpty)
    }

    func testQueuePermanentFailureIsTerminalWithoutRetryOrFalseSentState() async throws {
        let queue = makeQueue()
        let queued = message()
        try queue.enqueue(queued)

        let worker = try queue.onDeviceOnline(queued.targetDeviceId) { _ in
            .permanentFailure(.invalidPayload)
        }
        await worker.value

        XCTAssertTrue(queue.pendingMessages.isEmpty)
        XCTAssertEqual(queue.failedMessages.count, 1)
        XCTAssertEqual(queue.failedMessages.first?.status, .failed)
        XCTAssertEqual(queue.failedMessages.first?.retryCount, 0)
        XCTAssertEqual(queue.failedMessages.first?.lastFailureCode, .invalidPayload)
    }

    func testQueueRetryableFailureConsumesExactlyOneAttemptAndStaysPending() async throws {
        let queue = makeQueue()
        let queued = message()
        try queue.enqueue(queued)

        let worker = try queue.onDeviceOnline(queued.targetDeviceId) { _ in
            .retryable(.transportUnavailable)
        }
        await worker.value

        XCTAssertEqual(queue.pendingMessages.first?.status, .pending)
        XCTAssertEqual(queue.pendingMessages.first?.retryCount, 1)
        XCTAssertEqual(queue.pendingMessages.first?.lastFailureCode, .transportUnavailable)
        XCTAssertTrue(queue.failedMessages.isEmpty)
    }

    func testRepeatedOnlineNotificationUsesOneExactOwnerAndSendsOnce() async throws {
        let queue = makeQueue()
        let queued = message()
        let delivery = DeliverySuspensionProbe()
        try queue.enqueue(queued)

        let first = try queue.onDeviceOnline(queued.targetDeviceId) { _ in
            await delivery.deliver(as: .delivered)
        }
        try await delivery.waitUntilCalled()
        _ = try queue.onDeviceOnline(queued.targetDeviceId) { _ in
            XCTFail("A second online notification must not install a competing sender")
            return .delivered
        }
        await Task.yield()
        let callsBeforeRelease = await delivery.calls()
        XCTAssertEqual(callsBeforeRelease, 1)

        await delivery.release()
        await first.value
        let callsAfterRelease = await delivery.calls()
        XCTAssertEqual(callsAfterRelease, 1)
        XCTAssertTrue(queue.pendingMessages.isEmpty)
    }

    func testClearDuringInflightDeliveryInvalidatesOwnerWithoutBlockingPersistence() async throws {
        let queue = makeQueue()
        let queued = message()
        let delivery = DeliverySuspensionProbe()
        try queue.enqueue(queued)

        let worker = try queue.onDeviceOnline(queued.targetDeviceId) { _ in
            await delivery.deliver(as: .delivered)
        }
        try await delivery.waitUntilCalled()
        try queue.clear()
        await delivery.release()
        await worker.value

        XCTAssertFalse(queue.isPersistenceBlocked)
        XCTAssertNil(queue.lastPersistenceError)
        XCTAssertTrue(queue.pendingMessages.isEmpty)
        XCTAssertTrue(queue.failedMessages.isEmpty)
    }

    func testFailedClearPreservesInflightOwnerAndRuntimeDeliveryState() async throws {
        let probe = QueuePersistenceProbe()
        let queue = makeQueue(probe)
        let queued = message()
        let delivery = DeliverySuspensionProbe()
        try queue.enqueue(queued)

        let worker = try queue.onDeviceOnline(queued.targetDeviceId) { _ in
            await delivery.deliver(as: .delivered)
        }
        try await delivery.waitUntilCalled()
        XCTAssertEqual(queue.pendingMessages.first?.status, .sending)

        probe.saveError = DeviceMessagingTestFailure.injectedSaveFailure
        XCTAssertThrowsError(try queue.clear()) { error in
            XCTAssertEqual(error as? OfflineMessageQueueError, .persistenceFailed)
        }
        XCTAssertTrue(queue.isPersistenceBlocked)
        XCTAssertEqual(queue.pendingMessages.first?.status, .sending)

        // The failed clear must not cancel or invalidate the exact owner. The
        // persistence block intentionally prevents any further completion
        // write until explicit recovery, but the suspended handler remains the
        // same single in-flight operation and can be released deterministically.
        await delivery.release()
        await worker.value
        let calls = await delivery.calls()
        let wasCancelled = await delivery.wasCancelled()
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(wasCancelled)
    }

    func testPublicRemovalCannotInvalidateAnInflightSendingClaim() async throws {
        let queue = makeQueue()
        let queued = message()
        let delivery = DeliverySuspensionProbe()
        try queue.enqueue(queued)

        let worker = try queue.onDeviceOnline(queued.targetDeviceId) { _ in
            await delivery.deliver(as: .delivered)
        }
        try await delivery.waitUntilCalled()
        XCTAssertEqual(queue.pendingMessages.first?.status, .sending)

        XCTAssertThrowsError(try queue.remove(queued.id)) { error in
            XCTAssertEqual(error as? OfflineMessageQueueError, .stateConflict)
        }
        XCTAssertThrowsError(try queue.markAsSent(queued.id)) { error in
            XCTAssertEqual(error as? OfflineMessageQueueError, .stateConflict)
        }
        XCTAssertThrowsError(try queue.markAsFailed(queued.id)) { error in
            XCTAssertEqual(error as? OfflineMessageQueueError, .stateConflict)
        }

        await delivery.release()
        await worker.value
        XCTAssertTrue(queue.pendingMessages.isEmpty)
        let calls = await delivery.calls()
        XCTAssertEqual(calls, 1)
    }

    func testExpiryCleanupCannotInvalidateAnInflightSendingClaim() async throws {
        let probe = QueuePersistenceProbe()
        let queue = makeQueue(probe)
        let queued = message()
        let delivery = DeliverySuspensionProbe()
        try queue.enqueue(queued)

        let worker = try queue.onDeviceOnline(queued.targetDeviceId) { _ in
            await delivery.deliver(as: .delivered)
        }
        try await delivery.waitUntilCalled()
        XCTAssertEqual(queue.pendingMessages.first?.status, .sending)

        probe.now = Date(timeIntervalSince1970: 30_000)
        try queue.cleanupExpiredMessages()
        XCTAssertEqual(queue.pendingMessages.first?.id, queued.id)
        XCTAssertEqual(queue.pendingMessages.first?.status, .sending)

        await delivery.release()
        await worker.value
        XCTAssertTrue(queue.pendingMessages.isEmpty)
        let deliveryCalls = await delivery.calls()
        XCTAssertEqual(deliveryCalls, 1)
    }

    func testOfflineThenReonlineCancelsOldAttemptAndStartsOneReplacement() async throws {
        let queue = makeQueue()
        let queued = message()
        let firstDelivery = DeliverySuspensionProbe()
        let replacementCount = DeliveryCounter()
        try queue.enqueue(queued)

        let firstWorker = try queue.onDeviceOnline(queued.targetDeviceId) { _ in
            await firstDelivery.deliver(as: .retryable(.transportFailure))
        }
        try await firstDelivery.waitUntilCalled()
        try queue.onDeviceOffline(queued.targetDeviceId)
        _ = try queue.onDeviceOnline(queued.targetDeviceId) { _ in
            await replacementCount.increment()
            return .delivered
        }
        await firstDelivery.release()
        await firstWorker.value

        for _ in 0..<200 where !queue.pendingMessages.isEmpty {
            await Task.yield()
        }
        let firstCalls = await firstDelivery.calls()
        let replacementCalls = await replacementCount.count()
        XCTAssertEqual(firstCalls, 1)
        XCTAssertEqual(replacementCalls, 1)
        XCTAssertTrue(queue.pendingMessages.isEmpty)
        XCTAssertFalse(queue.isPersistenceBlocked)
    }

    func testOfflineCancellationForOneDeviceDoesNotInvalidateAnotherDeviceOwner() async throws {
        let queue = makeQueue()
        let messageA = message(id: "device-a-message", target: "peer-a")
        let messageB = message(id: "device-b-message", target: "peer-b")
        let deliveryA = DeliverySuspensionProbe()
        let deliveryB = DeliverySuspensionProbe()
        let replacementA = DeliveryCounter()
        try queue.enqueue(messageA)
        try queue.enqueue(messageB)

        let workerA = try queue.onDeviceOnline(messageA.targetDeviceId) { _ in
            await deliveryA.deliver(as: .retryable(.transportFailure))
        }
        let workerB = try queue.onDeviceOnline(messageB.targetDeviceId) { _ in
            await deliveryB.deliver(as: .delivered)
        }
        try await deliveryA.waitUntilCalled()
        try await deliveryB.waitUntilCalled()

        try queue.onDeviceOffline(messageA.targetDeviceId)
        _ = try queue.onDeviceOnline(messageA.targetDeviceId) { _ in
            await replacementA.increment()
            return .delivered
        }

        await deliveryB.release()
        await workerB.value
        XCTAssertFalse(queue.pendingMessages.contains(where: { $0.id == messageB.id }))
        XCTAssertTrue(queue.pendingMessages.contains(where: { $0.id == messageA.id }))

        await deliveryA.release()
        await workerA.value
        for _ in 0..<2_000 where !queue.pendingMessages.isEmpty {
            await Task.yield()
        }

        let aInitialCalls = await deliveryA.calls()
        let bCalls = await deliveryB.calls()
        let aReplacementCalls = await replacementA.count()
        XCTAssertEqual(aInitialCalls, 1)
        XCTAssertEqual(bCalls, 1)
        XCTAssertEqual(aReplacementCalls, 1)
        XCTAssertTrue(queue.pendingMessages.isEmpty)
        XCTAssertFalse(queue.isPersistenceBlocked)
    }

    func testRetryMaintenanceReschedulesReadyOnlineMessage() async throws {
        let probe = QueuePersistenceProbe()
        let queue = makeQueue(probe)
        let attempts = DeliveryCounter()
        let queued = message()
        try queue.enqueue(queued)

        let first = try queue.onDeviceOnline(queued.targetDeviceId) { _ in
            await attempts.increment()
            return await attempts.count() == 1
                ? .retryable(.transportUnavailable)
                : .delivered
        }
        await first.value
        XCTAssertEqual(queue.pendingMessages.first?.retryCount, 1)

        probe.now = probe.now.addingTimeInterval(61)
        queue.runRetryMaintenanceForTesting()
        for _ in 0..<200 where !queue.pendingMessages.isEmpty {
            await Task.yield()
        }

        let attemptCount = await attempts.count()
        XCTAssertEqual(attemptCount, 2)
        XCTAssertTrue(queue.pendingMessages.isEmpty)
    }

    func testQueueCorruptLoadBlocksMutationUntilExplicitQuarantineReset() throws {
        let probe = QueuePersistenceProbe()
        probe.loadError = DeviceMessagingTestFailure.injectedLoadFailure
        let queue = makeQueue(probe)

        XCTAssertTrue(queue.isPersistenceBlocked)
        XCTAssertNotNil(queue.lastPersistenceError)
        XCTAssertThrowsError(try queue.enqueue(message()))
        XCTAssertEqual(probe.saveCount, 0)
        XCTAssertEqual(probe.quarantineCount, 0)

        try queue.resetAfterQuarantiningUnreadableState()
        XCTAssertEqual(probe.quarantineCount, 1)
        XCTAssertFalse(queue.isPersistenceBlocked)
        try queue.enqueue(message())
        XCTAssertEqual(queue.pendingMessages.count, 1)
    }

    func testQueueSaveFailureRollsBackPublishedStateAndBlocksLaterOverwrite() throws {
        let probe = QueuePersistenceProbe()
        probe.saveError = DeviceMessagingTestFailure.injectedSaveFailure
        let queue = makeQueue(probe)

        XCTAssertThrowsError(try queue.enqueue(message()))
        XCTAssertTrue(queue.pendingMessages.isEmpty)
        XCTAssertTrue(queue.failedMessages.isEmpty)
        XCTAssertTrue(queue.isPersistenceBlocked)
        let saveCount = probe.saveCount
        XCTAssertThrowsError(try queue.enqueue(message()))
        XCTAssertEqual(probe.saveCount, saveCount)
    }

    func testPersistedSendingStateRecoversAsPendingAndIsDurablyNormalized() {
        let probe = QueuePersistenceProbe()
        probe.stored = OfflineMessageQueue.StoredMessages(
            pending: [message(status: .sending)],
            failed: []
        )
        let queue = makeQueue(probe)

        XCTAssertFalse(queue.isPersistenceBlocked)
        XCTAssertEqual(queue.pendingMessages.first?.status, .pending)
        XCTAssertEqual(probe.stored?.pending.first?.status, .pending)
        XCTAssertEqual(probe.saveCount, 1)
    }

    func testFailedTerminalHistoryCannotConsumePendingCapacity() throws {
        let probe = QueuePersistenceProbe()
        let failed = (0..<(OfflineMessageQueue.maximumRetainedFailedMessages + 20)).map {
            message(id: "failed-\($0)", status: .failed)
        }
        let pending = (0..<(OfflineMessageQueue.maximumPendingMessages - 1)).map {
            message(id: "pending-\($0)")
        }
        probe.stored = OfflineMessageQueue.StoredMessages(pending: pending, failed: failed)
        let queue = makeQueue(probe)

        XCTAssertEqual(queue.failedMessages.count, OfflineMessageQueue.maximumRetainedFailedMessages)
        try queue.enqueue(message(id: "last-pending"))
        XCTAssertEqual(queue.pendingMessages.count, OfflineMessageQueue.maximumPendingMessages)
        XCTAssertThrowsError(try queue.enqueue(message(id: "over-capacity")))
    }

    func testTextFailureCannotBeRetriedWithoutCoordinatingConversationState() {
        let failedText = message(id: "failed-text", status: .failed)
        let probe = QueuePersistenceProbe()
        probe.stored = OfflineMessageQueue.StoredMessages(
            pending: [],
            failed: [failedText]
        )
        let queue = makeQueue(probe)
        let saveCount = probe.saveCount

        XCTAssertThrowsError(try queue.retryFailedMessages()) { error in
            XCTAssertEqual(error as? OfflineMessageQueueError, .stateConflict)
        }
        XCTAssertTrue(queue.pendingMessages.isEmpty)
        XCTAssertEqual(queue.failedMessages, [failedText])
        XCTAssertEqual(probe.saveCount, saveCount)
    }

    func testMessagingPersistenceAndPayloadLimitsAreExplicit() {
        XCTAssertEqual(DeviceMessageStore.maximumMessagesPerConversation, 500)
        XCTAssertEqual(DeviceMessageStore.maximumPersistenceBytes, 4 * 1_024 * 1_024)
        XCTAssertEqual(OfflineMessageQueue.maximumPendingMessages, 500)
        XCTAssertEqual(OfflineMessageQueue.maximumPersistenceBytes, 4 * 1_024 * 1_024)
        XCTAssertEqual(OfflineMessage.maximumPayloadBytes, 1_048_576)
    }

    func testCompletionMetadataReserveCoversEveryPersistedDispositionShape() throws {
        let baseline = message(id: "reserve-baseline", status: .sending)
        let baselineBytes = try JSONEncoder().encode(
            OfflineMessageQueue.StoredMessages(pending: [baseline], failed: [])
        ).count
        let representativeDates = [
            Date.distantPast,
            Date(timeIntervalSinceReferenceDate: 0),
            Date.distantFuture
        ]
        var maximumGrowth = 0

        for code in OfflineDeliveryFailureCode.allCases {
            for retryDate in representativeDates {
                var retryable = baseline
                retryable.status = .pending
                retryable.retryCount = 1
                retryable.lastRetryAt = retryDate
                retryable.lastFailureCode = code
                let retryableBytes = try JSONEncoder().encode(
                    OfflineMessageQueue.StoredMessages(
                        pending: [retryable],
                        failed: []
                    )
                ).count

                var terminal = retryable
                terminal.status = .failed
                terminal.retryCount = OfflineMessageQueue.maximumRetryCount
                let terminalBytes = try JSONEncoder().encode(
                    OfflineMessageQueue.StoredMessages(
                        pending: [],
                        failed: [terminal]
                    )
                ).count
                maximumGrowth = max(
                    maximumGrowth,
                    retryableBytes - baselineBytes,
                    terminalBytes - baselineBytes
                )
            }
        }

        XCTAssertGreaterThan(maximumGrowth, 0)
        XCTAssertLessThanOrEqual(
            maximumGrowth,
            OfflineMessageQueue.completionMetadataReserveBytesPerPendingMessage
        )
    }

    func testMessageStoreBoundingRetainsOldPendingOutgoingAndNewestIncoming() throws {
        let pendingID = UUID()
        let terminalIDs = (0..<499).map { _ in UUID() }
        let incomingID = UUID()
        let pending = DeviceMessageStore.Message(
            id: pendingID,
            direction: .outgoing,
            text: "queued",
            timestamp: Date(timeIntervalSince1970: 1),
            deliveryState: .pending
        )
        let terminal = terminalIDs.enumerated().map { index, id in
            DeviceMessageStore.Message(
                id: id,
                direction: .incoming,
                text: "delivered-\(index)",
                timestamp: Date(timeIntervalSince1970: TimeInterval(index + 2)),
                deliveryState: .delivered
            )
        }
        let probe = MessageStorePersistenceProbe()
        probe.stored = [fingerprint: [pending] + terminal]
        let store = makeMessageStore(probe)

        try store.receiveIncoming(
            text: "newest",
            conversationFingerprint: fingerprint,
            messageId: incomingID,
            sentAt: Date(timeIntervalSince1970: 1_000)
        )

        let retained = store.messages(conversationFingerprint: fingerprint)
        XCTAssertEqual(retained.count, DeviceMessageStore.maximumMessagesPerConversation)
        XCTAssertTrue(retained.contains(where: { $0.id == pendingID }))
        XCTAssertTrue(retained.contains(where: { $0.id == incomingID }))
        XCTAssertFalse(retained.contains(where: { $0.id == terminalIDs[0] }))
        XCTAssertEqual(probe.stored?[fingerprint], retained)
    }

    func testMessageStoreRejectsFiveHundredFirstPendingWithoutSavingOrMutation() throws {
        let pending = (0..<DeviceMessageStore.maximumMessagesPerConversation).map { index in
            DeviceMessageStore.Message(
                direction: .outgoing,
                text: "pending-\(index)",
                timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
                deliveryState: .pending
            )
        }
        let probe = MessageStorePersistenceProbe()
        probe.stored = [fingerprint: pending]
        let store = makeMessageStore(probe)

        XCTAssertThrowsError(
            try store.appendOutgoing(
                text: "over-capacity",
                conversationFingerprint: fingerprint,
                messageId: UUID(),
                sentAt: Date(timeIntervalSince1970: 1_000)
            )
        ) { error in
            XCTAssertEqual(
                error as? DeviceMessageStoreError,
                .conversationCapacityExceeded
            )
        }

        XCTAssertEqual(probe.saveCount, 0)
        XCTAssertEqual(store.messages(conversationFingerprint: fingerprint), pending)
        XCTAssertEqual(probe.stored?[fingerprint], pending)
        XCTAssertFalse(store.isPersistenceBlocked)
    }

    func testMessageStoreNeverEvictsFiveHundredPendingMessagesForNewIncomingHistory() throws {
        let pending = (0..<DeviceMessageStore.maximumMessagesPerConversation).map { index in
            DeviceMessageStore.Message(
                direction: .outgoing,
                text: "pending-\(index)",
                timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
                deliveryState: .pending
            )
        }
        let probe = MessageStorePersistenceProbe()
        probe.stored = [fingerprint: pending]
        let store = makeMessageStore(probe)

        XCTAssertThrowsError(
            try store.receiveIncoming(
                text: "must not evict queued work",
                conversationFingerprint: fingerprint,
                messageId: UUID(),
                sentAt: Date(timeIntervalSince1970: 1_000)
            )
        ) { error in
            XCTAssertEqual(
                error as? DeviceMessageStoreError,
                .conversationCapacityExceeded
            )
        }

        XCTAssertEqual(probe.saveCount, 0)
        XCTAssertEqual(store.messages(conversationFingerprint: fingerprint), pending)
        XCTAssertEqual(probe.stored?[fingerprint], pending)
    }

    func testMessageStoreRefusesToClearPendingOutgoingMessages() throws {
        let pending = DeviceMessageStore.Message(
            direction: .outgoing,
            text: "pending",
            deliveryState: .pending
        )
        let delivered = DeviceMessageStore.Message(
            direction: .incoming,
            text: "delivered",
            deliveryState: .delivered
        )
        let probe = MessageStorePersistenceProbe()
        probe.stored = [fingerprint: [pending, delivered]]
        let store = makeMessageStore(probe)

        XCTAssertThrowsError(
            try store.clearConversation(conversationFingerprint: fingerprint)
        ) { error in
            XCTAssertEqual(
                error as? DeviceMessageStoreError,
                .pendingOutgoingMessagesPreventClear(count: 1)
            )
        }
        XCTAssertEqual(probe.saveCount, 0)
        XCTAssertEqual(
            store.messages(conversationFingerprint: fingerprint),
            [pending, delivered]
        )

        try store.markFailed(messageId: pending.id, conversationFingerprint: fingerprint)
        try store.clearConversation(conversationFingerprint: fingerprint)
        XCTAssertTrue(store.messages(conversationFingerprint: fingerprint).isEmpty)
    }

    func testMessageStorePublicBoundaryRejectsInvalidContentWithoutSaving() {
        let probe = MessageStorePersistenceProbe()
        let store = makeMessageStore(probe)
        let oversizedText = String(
            repeating: "x",
            count: DeviceTextMessagePolicy.maximumCharacterCount + 1
        )

        XCTAssertThrowsError(
            try store.appendOutgoing(
                text: oversizedText,
                conversationFingerprint: fingerprint,
                messageId: UUID(),
                sentAt: Date()
            )
        ) { error in
            XCTAssertEqual(error as? DeviceMessageStoreError, .invalidMessageContent)
        }
        XCTAssertThrowsError(
            try store.receiveIncoming(
                text: "valid",
                conversationFingerprint: fingerprint,
                messageId: UUID(),
                sentAt: Date(timeIntervalSinceReferenceDate: .infinity)
            )
        ) { error in
            XCTAssertEqual(error as? DeviceMessageStoreError, .invalidMessageContent)
        }

        XCTAssertEqual(probe.saveCount, 0)
        XCTAssertTrue(store.messages(conversationFingerprint: fingerprint).isEmpty)
        XCTAssertFalse(store.isPersistenceBlocked)
    }

    func testMessageStoreInvalidCanonicalMessageBlocksLoad() {
        let invalid = DeviceMessageStore.Message(
            direction: .incoming,
            text: "valid",
            timestamp: Date(timeIntervalSinceReferenceDate: .infinity),
            deliveryState: .delivered
        )
        let probe = MessageStorePersistenceProbe()
        probe.stored = [fingerprint: [invalid]]

        let store = makeMessageStore(probe)

        XCTAssertTrue(store.isPersistenceBlocked)
        XCTAssertTrue(store.messages(conversationFingerprint: fingerprint).isEmpty)
        XCTAssertEqual(store.lastPersistenceError, "persistence_load_failed")
        XCTAssertEqual(probe.saveCount, 0)
    }

    func testOfflineMessagePayloadLimitIsEnforcedBeforePersistence() throws {
        let probe = QueuePersistenceProbe()
        let queue = makeQueue(probe)
        let maximumPayload = Data(
            repeating: 0x41,
            count: OfflineMessage.maximumPayloadBytes
        )
        try queue.enqueue(message(id: "maximum-payload", payload: maximumPayload))
        let saveCountBeforeRejection = probe.saveCount

        let oversizedPayload = Data(
            repeating: 0x42,
            count: OfflineMessage.maximumPayloadBytes + 1
        )
        XCTAssertThrowsError(
            try queue.enqueue(message(id: "oversized-payload", payload: oversizedPayload))
        ) { error in
            XCTAssertEqual(
                error as? OfflineMessageQueueError,
                .messageTooLarge(
                    size: OfflineMessage.maximumPayloadBytes + 1,
                    maxSize: OfflineMessage.maximumPayloadBytes
                )
            )
        }

        XCTAssertEqual(probe.saveCount, saveCountBeforeRejection)
        XCTAssertEqual(queue.pendingMessages.map(\.id), ["maximum-payload"])
        XCTAssertFalse(queue.isPersistenceBlocked)
    }

    func testOfflineQueueRejectsInvalidMetadataBeforePersistence() {
        let probe = QueuePersistenceProbe()
        let queue = makeQueue(probe)
        let invalidLifetime = OfflineMessage(
            id: "invalid-lifetime",
            targetDeviceId: "peer-a",
            messageType: .text,
            payload: Data([0x01]),
            createdAt: Date(timeIntervalSince1970: 200),
            expiresAt: Date(timeIntervalSince1970: 100)
        )
        let invalidIdentifier = message(id: "invalid\nidentifier")

        XCTAssertThrowsError(try queue.enqueue(invalidLifetime)) { error in
            XCTAssertEqual(error as? OfflineMessageQueueError, .stateConflict)
        }
        XCTAssertThrowsError(try queue.enqueue(invalidIdentifier)) { error in
            XCTAssertEqual(error as? OfflineMessageQueueError, .stateConflict)
        }

        XCTAssertEqual(probe.saveCount, 0)
        XCTAssertTrue(queue.pendingMessages.isEmpty)
        XCTAssertFalse(queue.isPersistenceBlocked)
    }

    func testOfflineQueueInvalidCanonicalMetadataBlocksLoad() {
        let invalid = OfflineMessage(
            id: "invalid\nidentifier",
            targetDeviceId: "peer-a",
            messageType: .text,
            payload: Data([0x01]),
            createdAt: Date(timeIntervalSince1970: 100),
            expiresAt: Date(timeIntervalSince1970: 200)
        )
        let probe = QueuePersistenceProbe()
        probe.stored = OfflineMessageQueue.StoredMessages(pending: [invalid], failed: [])

        let queue = makeQueue(probe)

        XCTAssertTrue(queue.isPersistenceBlocked)
        XCTAssertTrue(queue.pendingMessages.isEmpty)
        XCTAssertTrue(queue.failedMessages.isEmpty)
        XCTAssertEqual(queue.lastPersistenceError, "offline_queue_persistence_load_failed")
        XCTAssertEqual(probe.saveCount, 0)
    }

    func testOfflineQueueRejectsOverflowingRetryCountBeforeAnyTransportSubmission() async {
        let probe = QueuePersistenceProbe()
        probe.stored = OfflineMessageQueue.StoredMessages(
            pending: [message(id: "overflowing-retry", retryCount: .max)],
            failed: []
        )
        let queue = makeQueue(probe)
        let submissions = DeliveryCounter()

        XCTAssertTrue(queue.isPersistenceBlocked)
        XCTAssertTrue(queue.pendingMessages.isEmpty)
        XCTAssertThrowsError(
            try queue.onDeviceOnline("peer-a") { _ in
                await submissions.increment()
                return .delivered
            }
        ) { error in
            XCTAssertEqual(error as? OfflineMessageQueueError, .persistenceFailed)
        }
        let submissionCount = await submissions.count()
        XCTAssertEqual(submissionCount, 0)
        XCTAssertEqual(probe.saveCount, 0)
    }

    func testOversizedPayloadInPendingCanonicalStateBlocksLoad() {
        let probe = QueuePersistenceProbe()
        probe.stored = OfflineMessageQueue.StoredMessages(
            pending: [
                message(
                    id: "oversized-pending",
                    payload: Data(
                        repeating: 0x43,
                        count: OfflineMessage.maximumPayloadBytes + 1
                    )
                )
            ],
            failed: []
        )

        let queue = makeQueue(probe)

        XCTAssertTrue(queue.isPersistenceBlocked)
        XCTAssertTrue(queue.pendingMessages.isEmpty)
        XCTAssertTrue(queue.failedMessages.isEmpty)
        XCTAssertEqual(queue.lastPersistenceError, "offline_queue_persistence_load_failed")
        XCTAssertEqual(probe.saveCount, 0)
    }

    func testOversizedPayloadInFailedCanonicalStateBlocksLoad() {
        let probe = QueuePersistenceProbe()
        probe.stored = OfflineMessageQueue.StoredMessages(
            pending: [],
            failed: [
                message(
                    id: "oversized-failed",
                    payload: Data(
                        repeating: 0x44,
                        count: OfflineMessage.maximumPayloadBytes + 1
                    ),
                    status: .failed
                )
            ]
        )

        let queue = makeQueue(probe)

        XCTAssertTrue(queue.isPersistenceBlocked)
        XCTAssertTrue(queue.pendingMessages.isEmpty)
        XCTAssertTrue(queue.failedMessages.isEmpty)
        XCTAssertEqual(queue.lastPersistenceError, "offline_queue_persistence_load_failed")
        XCTAssertEqual(probe.saveCount, 0)
    }

    func testQueueAggregateCapacityFailureIsRecoverableAndPreservesOldState() throws {
        let probe = QueuePersistenceProbe()
        probe.maximumEncodedBytes = OfflineMessageQueue.maximumPersistenceBytes
        let queue = makeQueue(probe)
        let largePayload = Data(repeating: 0x45, count: 850 * 1_024)
        for index in 0..<3 {
            try queue.enqueue(message(id: "large-\(index)", payload: largePayload))
        }
        let committed = queue.pendingMessages

        XCTAssertThrowsError(
            try queue.enqueue(message(id: "aggregate-over-capacity", payload: largePayload))
        ) { error in
            guard let queueError = error as? OfflineMessageQueueError,
                  case let .storageCapacityExceeded(actualBytes, maximumBytes) = queueError else {
                return XCTFail("Expected a typed storage-capacity error, got \(error)")
            }
            XCTAssertGreaterThan(actualBytes, maximumBytes)
            XCTAssertEqual(maximumBytes, OfflineMessageQueue.maximumPersistenceBytes)
        }

        XCTAssertEqual(queue.pendingMessages, committed)
        XCTAssertEqual(probe.stored?.pending, committed)
        XCTAssertFalse(queue.isPersistenceBlocked)
        XCTAssertEqual(
            queue.lastPersistenceError,
            OfflineDeliveryFailureCode.storageCapacityExceeded.rawValue
        )

        try queue.enqueue(message(id: "small-after-capacity", payload: Data([0x46])))
        XCTAssertEqual(queue.pendingMessages.count, committed.count + 1)
        XCTAssertNil(queue.lastPersistenceError)
        XCTAssertFalse(queue.isPersistenceBlocked)
    }

    func testLegacyNearCapacityQueueRefusesClaimBeforeTransportSubmission() async throws {
        func storedState(payloadByteCount: Int) -> OfflineMessageQueue.StoredMessages {
            let payload = Data(repeating: 0x47, count: payloadByteCount)
            let messages = (0..<3).map { index in
                message(id: "near-capacity-\(index)", payload: payload)
            }
            return OfflineMessageQueue.StoredMessages(pending: messages, failed: [])
        }

        var lowerBound = 0
        var upperBound = OfflineMessage.maximumPayloadBytes
        var largestPersistableState = storedState(payloadByteCount: 0)
        var largestEncodedByteCount = try JSONEncoder().encode(largestPersistableState).count
        while lowerBound <= upperBound {
            let candidateSize = lowerBound + (upperBound - lowerBound) / 2
            let candidate = storedState(payloadByteCount: candidateSize)
            let encodedByteCount = try JSONEncoder().encode(candidate).count
            if encodedByteCount <= OfflineMessageQueue.maximumPersistenceBytes {
                largestPersistableState = candidate
                largestEncodedByteCount = encodedByteCount
                lowerBound = candidateSize + 1
            } else {
                upperBound = candidateSize - 1
            }
        }
        let requiredCompletionBytes = largestEncodedByteCount
            + largestPersistableState.pending.count
            * OfflineMessageQueue.completionMetadataReserveBytesPerPendingMessage
        XCTAssertLessThanOrEqual(
            largestEncodedByteCount,
            OfflineMessageQueue.maximumPersistenceBytes
        )
        XCTAssertGreaterThan(
            requiredCompletionBytes,
            OfflineMessageQueue.maximumPersistenceBytes
        )

        let probe = QueuePersistenceProbe()
        probe.stored = largestPersistableState
        let queue = makeQueue(probe)
        let submissions = DeliveryCounter()
        let worker = try queue.onDeviceOnline("peer-a") { _ in
            await submissions.increment()
            return .delivered
        }
        await worker.value

        let submissionCount = await submissions.count()
        XCTAssertEqual(submissionCount, 0)
        XCTAssertEqual(queue.pendingMessages, largestPersistableState.pending)
        XCTAssertEqual(
            queue.lastPersistenceError,
            OfflineDeliveryFailureCode.storageCapacityExceeded.rawValue
        )
        XCTAssertFalse(queue.isPersistenceBlocked)

        queue.runRetryMaintenanceForTesting()
        for _ in 0..<200 {
            await Task.yield()
        }
        let countAfterMaintenance = await submissions.count()
        XCTAssertEqual(countAfterMaintenance, 0)

        try queue.remove(largestPersistableState.pending[0].id)
        for _ in 0..<2_000 where !queue.pendingMessages.isEmpty {
            await Task.yield()
        }
        let countAfterRecovery = await submissions.count()
        XCTAssertEqual(countAfterRecovery, 2)
        XCTAssertTrue(queue.pendingMessages.isEmpty)
        XCTAssertNil(queue.lastPersistenceError)
    }

    func testMessageStoreAggregateCapacityFailureIsRecoverableAndPreservesOldState() throws {
        let maximumText = String(
            repeating: "🧪",
            count: DeviceTextMessagePolicy.maximumCharacterCount
        )
        var existing: [DeviceMessageStore.Message] = []
        var nextEncodedByteCount = 0
        while existing.count < DeviceMessageStore.maximumMessagesPerConversation {
            let candidate = existing + [
                DeviceMessageStore.Message(
                    direction: .incoming,
                    text: maximumText,
                    timestamp: Date(
                        timeIntervalSince1970: TimeInterval(existing.count + 1)
                    ),
                    deliveryState: .delivered
                )
            ]
            nextEncodedByteCount = try JSONEncoder().encode([fingerprint: candidate]).count
            if nextEncodedByteCount > DeviceMessageStore.maximumPersistenceBytes {
                break
            }
            existing = candidate
        }
        XCTAssertFalse(existing.isEmpty)
        XCTAssertLessThan(existing.count, DeviceMessageStore.maximumMessagesPerConversation)
        XCTAssertGreaterThan(
            nextEncodedByteCount,
            DeviceMessageStore.maximumPersistenceBytes
        )

        let probe = MessageStorePersistenceProbe()
        probe.maximumEncodedBytes = DeviceMessageStore.maximumPersistenceBytes
        probe.stored = [fingerprint: existing]
        let store = makeMessageStore(probe)

        XCTAssertThrowsError(
            try store.appendOutgoing(
                text: maximumText,
                conversationFingerprint: fingerprint,
                messageId: UUID(),
                sentAt: Date()
            )
        ) { error in
            guard let storeError = error as? DeviceMessageStoreError,
                  case let .storageCapacityExceeded(actualBytes, maximumBytes) = storeError else {
                return XCTFail("Expected a typed storage-capacity error, got \(error)")
            }
            XCTAssertGreaterThan(actualBytes, maximumBytes)
            XCTAssertEqual(maximumBytes, DeviceMessageStore.maximumPersistenceBytes)
        }

        XCTAssertEqual(store.messages(conversationFingerprint: fingerprint), existing)
        XCTAssertEqual(probe.stored?[fingerprint], existing)
        XCTAssertFalse(store.isPersistenceBlocked)
        XCTAssertEqual(
            store.lastPersistenceError,
            OfflineDeliveryFailureCode.storageCapacityExceeded.rawValue
        )

        probe.maximumEncodedBytes = nil
        try store.receiveIncoming(
            text: "small-after-capacity",
            conversationFingerprint: fingerprint,
            messageId: UUID(),
            sentAt: Date()
        )
        XCTAssertEqual(
            store.messages(conversationFingerprint: fingerprint).count,
            existing.count + 1
        )
        XCTAssertNil(store.lastPersistenceError)
        XCTAssertFalse(store.isPersistenceBlocked)
    }

    func testAggregateOversizedCanonicalLoadsRemainBlocked() {
        let oversized = CodablePersistenceStoreError.payloadTooLarge(
            actualBytes: 4 * 1_024 * 1_024 + 1,
            maximumBytes: 4 * 1_024 * 1_024
        )
        let queueProbe = QueuePersistenceProbe()
        queueProbe.loadError = oversized
        let messageStoreProbe = MessageStorePersistenceProbe()
        messageStoreProbe.loadError = oversized

        let queue = makeQueue(queueProbe)
        let store = makeMessageStore(messageStoreProbe)

        XCTAssertTrue(queue.isPersistenceBlocked)
        XCTAssertTrue(store.isPersistenceBlocked)
        XCTAssertEqual(queue.lastPersistenceError, "offline_queue_persistence_load_failed")
        XCTAssertEqual(store.lastPersistenceError, "persistence_load_failed")
        XCTAssertEqual(queueProbe.saveCount, 0)
        XCTAssertEqual(messageStoreProbe.saveCount, 0)
    }

    func testMessageStoreCorruptLoadBlocksWritesAndExplicitResetPreservesBoundary() throws {
        let probe = MessageStorePersistenceProbe()
        probe.loadError = DeviceMessagingTestFailure.injectedLoadFailure
        let store = makeMessageStore(probe)

        XCTAssertTrue(store.isPersistenceBlocked)
        XCTAssertNotNil(store.lastPersistenceError)
        XCTAssertThrowsError(
            try store.appendOutgoing(
                text: "blocked",
                conversationFingerprint: fingerprint,
                messageId: UUID(),
                sentAt: Date()
            )
        )
        XCTAssertEqual(probe.saveCount, 0)

        try store.resetAfterQuarantiningUnreadableState()
        XCTAssertEqual(probe.quarantineCount, 1)
        XCTAssertFalse(store.isPersistenceBlocked)
        XCTAssertNil(store.lastPersistenceError)
    }

    func testMessageStoreSaveFailureNeverPublishesUncommittedMutation() throws {
        let existing = DeviceMessageStore.Message(
            direction: .incoming,
            text: "existing",
            deliveryState: .delivered
        )
        let probe = MessageStorePersistenceProbe()
        probe.stored = [fingerprint: [existing]]
        let store = makeMessageStore(probe)
        probe.saveError = DeviceMessagingTestFailure.injectedSaveFailure

        XCTAssertThrowsError(
            try store.appendOutgoing(
                text: "must roll back",
                conversationFingerprint: fingerprint,
                messageId: UUID(),
                sentAt: Date()
            )
        )
        XCTAssertEqual(store.messages(conversationFingerprint: fingerprint), [existing])
        XCTAssertTrue(store.isPersistenceBlocked)
    }

    func testMalformedQueuedPayloadBecomesPermanentFailureWithoutTransportSubmission() async throws {
        let queue = makeQueue()
        let store = makeMessageStore()
        let transport = DeviceTextMessageTransportProbe()
        let service = DeviceMessagingService(
            messageStore: store,
            offlineQueue: queue,
            transport: transport
        )
        let malformed = message(payload: Data("not-json".utf8))
        try queue.enqueue(malformed)

        let worker = try queue.onDeviceOnline(malformed.targetDeviceId) { message in
            await service.deliverQueuedMessageForTesting(message)
        }
        await worker.value

        XCTAssertTrue(transport.submissions.isEmpty)
        XCTAssertTrue(queue.pendingMessages.isEmpty)
        XCTAssertEqual(queue.failedMessages.first?.lastFailureCode, .invalidPayload)
        XCTAssertNotEqual(queue.failedMessages.first?.status, .sent)
    }

    func testUnsupportedQueuedMessageTypeIsPermanentAndNeverSubmitted() async {
        let queue = makeQueue()
        let store = makeMessageStore()
        let transport = DeviceTextMessageTransportProbe()
        let service = DeviceMessagingService(
            messageStore: store,
            offlineQueue: queue,
            transport: transport
        )
        let unsupported = OfflineMessage(
            targetDeviceId: "peer-a",
            messageType: .custom,
            payload: Data("opaque".utf8)
        )

        let disposition = await service.deliverQueuedMessageForTesting(unsupported)

        XCTAssertEqual(disposition, .permanentFailure(.invalidMessageType))
        XCTAssertTrue(transport.submissions.isEmpty)
    }

    func testQueuedIdentityMismatchIsPermanentAndMarksConversationFailed() async throws {
        let queue = makeQueue()
        let store = makeMessageStore()
        let transport = DeviceTextMessageTransportProbe()
        let service = DeviceMessagingService(
            messageStore: store,
            offlineQueue: queue,
            transport: transport
        )
        transport.sendImplementation = { throw P2PError.noSessionKey }
        try await service.send(
            text: "identity-bound",
            toDeviceId: "peer-a",
            conversationFingerprint: fingerprint
        )
        XCTAssertEqual(queue.pendingMessages.count, 1)
        transport.sendImplementation = { throw P2PError.authenticatedIdentityMismatch }

        let worker = try queue.onDeviceOnline("peer-a") { message in
            await service.deliverQueuedMessageForTesting(message)
        }
        await worker.value

        XCTAssertTrue(queue.pendingMessages.isEmpty)
        XCTAssertEqual(queue.failedMessages.first?.lastFailureCode, .authenticatedIdentityMismatch)
        XCTAssertEqual(
            store.messages(conversationFingerprint: fingerprint).first?.deliveryState,
            .failed
        )
        XCTAssertEqual(transport.submissions.last?.expectedFingerprint, fingerprint)
    }

    func testCancelledStaleAttemptCannotMarkConversationFailedAtRetryLimit() async throws {
        let probe = QueuePersistenceProbe()
        let queue = makeQueue(probe)
        let store = makeMessageStore()
        let transport = DeviceTextMessageTransportProbe()
        let service = DeviceMessagingService(
            messageStore: store,
            offlineQueue: queue,
            transport: transport
        )
        transport.sendImplementation = { throw P2PError.noSessionKey }
        try await service.send(
            text: "cancelled stale attempt",
            toDeviceId: "peer-a",
            conversationFingerprint: fingerprint
        )
        let queuedID = try XCTUnwrap(queue.pendingMessages.first?.id)
        try queue.markAsFailed(queuedID)
        try queue.markAsFailed(queuedID)
        let retryLimitMessage = try XCTUnwrap(queue.pendingMessages.first)
        XCTAssertEqual(
            retryLimitMessage.retryCount,
            OfflineMessageQueue.maximumRetryCount - 1
        )

        let suspension = DeliverySuspensionProbe()
        transport.sendImplementation = {
            _ = await suspension.deliver(as: .delivered)
            throw P2PError.connectionFailed
        }
        let deliveryTask = Task { @MainActor in
            await service.deliverQueuedMessageForTesting(retryLimitMessage)
        }
        try await suspension.waitUntilCalled()
        deliveryTask.cancel()
        await suspension.release()

        let disposition = await deliveryTask.value
        XCTAssertEqual(disposition, .cancelled)
        XCTAssertEqual(
            store.messages(conversationFingerprint: fingerprint).first?.deliveryState,
            .pending
        )
    }

    func testInjectedServiceDoesNotObserveProductionOrInjectedConnectionsBeforeStart() async throws {
        let queue = makeQueue()
        let store = makeMessageStore()
        let transport = DeviceTextMessageTransportProbe()
        let service = DeviceMessagingService(
            messageStore: store,
            offlineQueue: queue,
            transport: transport
        )
        let malformed = message(payload: Data("not-json".utf8))
        try queue.enqueue(malformed)
        let device = DiscoveredDevice(
            id: malformed.targetDeviceId,
            name: "Test Peer",
            modelName: "Test",
            platform: .macOS,
            osVersion: "TestOS"
        )
        transport.connections.send([Connection(device: device, status: .connected)])
        await Task.yield()

        XCTAssertEqual(queue.pendingMessages.count, 1)
        XCTAssertTrue(queue.failedMessages.isEmpty)

        service.start()
        for _ in 0..<200 where queue.failedMessages.isEmpty {
            await Task.yield()
        }
        XCTAssertTrue(queue.pendingMessages.isEmpty)
        XCTAssertEqual(queue.failedMessages.first?.lastFailureCode, .invalidPayload)
    }

    func testDirectSendForwardsExactFingerprintAndMarksSentOnlyAfterSuccess() async throws {
        let queue = makeQueue()
        let store = makeMessageStore()
        let transport = DeviceTextMessageTransportProbe()
        let service = DeviceMessagingService(
            messageStore: store,
            offlineQueue: queue,
            transport: transport
        )

        try await service.send(
            text: "hello",
            toDeviceId: "peer-a",
            conversationFingerprint: fingerprint
        )

        XCTAssertEqual(transport.submissions.count, 1)
        XCTAssertEqual(transport.submissions.first?.expectedFingerprint, fingerprint)
        XCTAssertEqual(
            store.messages(conversationFingerprint: fingerprint).first?.deliveryState,
            .sent
        )
    }

    func testUnifiedSendRequiresOwnerBoundAuthenticatedReceipt() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("skybridge-ios-unified-\(UUID().uuidString)")
        let suiteName = "SkyBridgeIOSUnified.\(UUID().uuidString)"
        defer {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: rootURL)
        }
        let runtime = try IOSUnifiedDeviceMessagingRuntime(
            defaultsSuiteName: suiteName,
            rootURLOverride: rootURL
        )
        let queue = makeQueue()
        let store = makeMessageStore()
        let transport = DeviceTextMessageTransportProbe()
        let service = DeviceMessagingService(
            messageStore: store,
            offlineQueue: queue,
            transport: transport,
            usesUnifiedRepository: true,
            unifiedRuntime: runtime
        )
        try await service.prepare()
        service.start()
        let targetDeviceID = "linux-peer-01"
        let device = DiscoveredDevice(
            id: targetDeviceID,
            name: "Linux Peer",
            modelName: "Cloud Bare Metal",
            platform: .linux,
            osVersion: "TestOS"
        )
        transport.connections.send([Connection(device: device, status: .connected)])

        try await service.send(
            text: "owner-bound",
            toDeviceId: targetDeviceID,
            conversationFingerprint: fingerprint
        )
        var submittedSnapshot: MessageRepositorySnapshot?
        for _ in 0..<500 {
            let snapshot = try await runtime.currentSnapshot()
            if snapshot.messages.first?.deliveryState == .sent,
               snapshot.deliveryIntents.first?.state == .awaitingReceipt {
                submittedSnapshot = snapshot
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let submitted = try XCTUnwrap(submittedSnapshot)
        XCTAssertEqual(transport.submissions.count, 1)
        let submission = try XCTUnwrap(transport.submissions.first)
        let attemptID = try XCTUnwrap(submission.deliveryAttemptID)
        XCTAssertEqual(submission.deviceId, targetDeviceID)
        XCTAssertEqual(submission.expectedFingerprint, fingerprint)
        XCTAssertEqual(submitted.messages.first?.id, submission.messageId)

        do {
            try await service.handleAuthenticatedReceipt(
                AppMessage.TextMessageReceiptPayload(
                    messageID: submission.messageId,
                    deliveryAttemptID: UUID()
                ),
                conversationFingerprint: fingerprint
            )
            XCTFail("A different delivery owner must not complete the message")
        } catch let error as DeviceMessagingError {
            guard case .persistenceFailed = error else {
                return XCTFail("Unexpected receipt error: \(error)")
            }
        }

        try await service.handleAuthenticatedReceipt(
            AppMessage.TextMessageReceiptPayload(
                messageID: submission.messageId,
                deliveryAttemptID: attemptID
            ),
            conversationFingerprint: fingerprint
        )
        let delivered = try await runtime.currentSnapshot()
        XCTAssertEqual(delivered.messages.first?.deliveryState, .delivered)
        XCTAssertTrue(delivered.deliveryIntents.isEmpty)
        XCTAssertEqual(
            store.messages(conversationFingerprint: fingerprint).first?.deliveryState,
            .delivered
        )
        XCTAssertEqual(transport.submissions.count, 1)
    }

    func testUnifiedLegacyQueueCanonicalizesUppercaseUUID() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("skybridge-ios-legacy-queue-\(UUID().uuidString)")
        let suiteName = "SkyBridgeIOSLegacyQueue.\(UUID().uuidString)"
        defer {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: rootURL)
        }
        let queueDirectory = rootURL.appendingPathComponent("Messaging", isDirectory: true)
        let queueURL = queueDirectory.appendingPathComponent(
            "offline-message-queue.json",
            isDirectory: false
        )
        try FileManager.default.createDirectory(
            at: queueDirectory,
            withIntermediateDirectories: true
        )
        let queueUUID = UUID()
        let legacy = try legacyQueuedText(
            queueID: queueUUID.uuidString.uppercased(),
            text: "canonicalize legacy queue"
        )
        let legacyBytes = try JSONEncoder().encode(
            OfflineMessageQueue.StoredMessages(pending: [legacy], failed: [])
        )
        try legacyBytes.write(to: queueURL, options: .atomic)

        let runtime = try IOSUnifiedDeviceMessagingRuntime(
            defaultsSuiteName: suiteName,
            rootURLOverride: rootURL
        )
        let snapshot = try await runtime.bootstrap()

        XCTAssertEqual(
            snapshot.deliveryIntents.first?.queueID,
            queueUUID.uuidString.lowercased()
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: queueURL.path))
    }

    func testUnifiedLegacyQueueAliasesFailClosedWithoutChangingSource() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("skybridge-ios-legacy-alias-\(UUID().uuidString)")
        let suiteName = "SkyBridgeIOSLegacyAlias.\(UUID().uuidString)"
        defer {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: rootURL)
        }
        let queueDirectory = rootURL.appendingPathComponent("Messaging", isDirectory: true)
        let queueURL = queueDirectory.appendingPathComponent(
            "offline-message-queue.json",
            isDirectory: false
        )
        try FileManager.default.createDirectory(
            at: queueDirectory,
            withIntermediateDirectories: true
        )
        let queueUUID = UUID()
        let canonicalQueueID = queueUUID.uuidString.lowercased()
        let aliases = try [
            legacyQueuedText(queueID: canonicalQueueID, text: "canonical"),
            legacyQueuedText(
                queueID: queueUUID.uuidString.uppercased(),
                text: "case alias",
                createdAt: Date(timeIntervalSince1970: 9_001)
            )
        ]
        let legacyBytes = try JSONEncoder().encode(
            OfflineMessageQueue.StoredMessages(pending: aliases, failed: [])
        )
        try legacyBytes.write(to: queueURL, options: .atomic)

        let runtime = try IOSUnifiedDeviceMessagingRuntime(
            defaultsSuiteName: suiteName,
            rootURLOverride: rootURL
        )
        do {
            _ = try await runtime.bootstrap()
            XCTFail("Case-only legacy queue aliases must block migration")
        } catch let error as DeviceMessagingRepositoryError {
            XCTAssertEqual(error, .legacySourceConflict(canonicalQueueID))
        }

        XCTAssertEqual(try Data(contentsOf: queueURL), legacyBytes)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: queueDirectory.appendingPathComponent("device-messaging.sqlite3").path
        ))
    }

    func testUnifiedInvalidLegacyQueueIDFailsClosedWithoutChangingSource() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("skybridge-ios-legacy-invalid-\(UUID().uuidString)")
        let suiteName = "SkyBridgeIOSLegacyInvalid.\(UUID().uuidString)"
        defer {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: rootURL)
        }
        let queueDirectory = rootURL.appendingPathComponent("Messaging", isDirectory: true)
        let queueURL = queueDirectory.appendingPathComponent(
            "offline-message-queue.json",
            isDirectory: false
        )
        try FileManager.default.createDirectory(
            at: queueDirectory,
            withIntermediateDirectories: true
        )
        let legacy = try legacyQueuedText(queueID: "not-a-uuid", text: "invalid queue")
        let legacyBytes = try JSONEncoder().encode(
            OfflineMessageQueue.StoredMessages(pending: [legacy], failed: [])
        )
        try legacyBytes.write(to: queueURL, options: .atomic)

        let runtime = try IOSUnifiedDeviceMessagingRuntime(
            defaultsSuiteName: suiteName,
            rootURLOverride: rootURL
        )
        do {
            _ = try await runtime.bootstrap()
            XCTFail("An invalid legacy queue identifier must block migration")
        } catch let error as DeviceMessagingRepositoryError {
            XCTAssertEqual(error, .invalidRecord(reasonCode: "invalid_legacy_queue_id"))
        }

        XCTAssertEqual(try Data(contentsOf: queueURL), legacyBytes)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: queueDirectory.appendingPathComponent("device-messaging.sqlite3").path
        ))
    }

    func testUnifiedProjectionsIgnoreOlderRepositoryGeneration() throws {
        let queue = makeQueue()
        let store = makeMessageStore()
        let messageID = UUID()
        let timestamp = Date(timeIntervalSince1970: 80_000)
        let delivered = PersistedMessageRecord(
            id: messageID,
            conversationFingerprint: fingerprint,
            targetDeviceID: "peer-a",
            direction: .outgoing,
            text: "generation-bound",
            timestamp: timestamp,
            deliveryState: .delivered
        )
        try store.applyUnifiedSnapshot(MessageRepositorySnapshot(
            messages: [delivered],
            deliveryIntents: [],
            migrationIssues: [],
            generation: 2
        ))
        try queue.applyUnifiedSnapshot(MessageRepositorySnapshot(
            messages: [delivered],
            deliveryIntents: [],
            migrationIssues: [],
            generation: 2
        ))

        var staleMessage = delivered
        staleMessage.deliveryState = .pending
        let staleIntent = PersistedDeliveryIntent(
            queueID: UUID().uuidString.lowercased(),
            messageID: messageID,
            targetDeviceID: "peer-a",
            messageType: OfflineMessageType.text.rawValue,
            priority: 1,
            payload: Data("payload".utf8),
            createdAt: timestamp,
            expiresAt: timestamp.addingTimeInterval(3_600)
        )
        let stale = MessageRepositorySnapshot(
            messages: [staleMessage],
            deliveryIntents: [staleIntent],
            migrationIssues: [],
            generation: 1
        )
        try store.applyUnifiedSnapshot(stale)
        try queue.applyUnifiedSnapshot(stale)

        XCTAssertEqual(
            store.messages(conversationFingerprint: fingerprint).first?.deliveryState,
            .delivered
        )
        XCTAssertTrue(queue.pendingMessages.isEmpty)
        XCTAssertTrue(queue.failedMessages.isEmpty)
    }

    func testSharedMessageStoreRejectsLegacyIncomingWriter() throws {
        XCTAssertThrowsError(try DeviceMessageStore.shared.receiveIncoming(
            text: "must use the coordinated repository",
            conversationFingerprint: fingerprint,
            messageId: UUID(),
            sentAt: Date()
        )) { error in
            XCTAssertEqual(
                error as? DeviceMessageStoreError,
                .persistenceFailed("coordinated_repository_required")
            )
        }
    }

    func testUnifiedWorkerCancellationWrappedAsTransportFailureKeepsRetryBudget() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("skybridge-ios-unified-cancel-\(UUID().uuidString)")
        let suiteName = "SkyBridgeIOSUnifiedCancel.\(UUID().uuidString)"
        defer {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: rootURL)
        }
        let runtime = try IOSUnifiedDeviceMessagingRuntime(
            defaultsSuiteName: suiteName,
            rootURLOverride: rootURL
        )
        let queue = makeQueue()
        let store = makeMessageStore()
        let transport = DeviceTextMessageTransportProbe()
        transport.sendImplementation = {
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                throw P2PError.connectionFailed
            }
        }
        let service = DeviceMessagingService(
            messageStore: store,
            offlineQueue: queue,
            transport: transport,
            usesUnifiedRepository: true,
            unifiedRuntime: runtime
        )
        try await service.prepare()
        service.start()

        let targetDeviceID = "linux-peer-cancel"
        try await service.send(
            text: "preserve retry budget",
            toDeviceId: targetDeviceID,
            conversationFingerprint: fingerprint
        )
        let staged = try await runtime.currentSnapshot()
        let queueID = try XCTUnwrap(staged.deliveryIntents.first?.queueID)
        XCTAssertEqual(staged.deliveryIntents.first?.retryCount, 0)

        let device = DiscoveredDevice(
            id: targetDeviceID,
            name: "Linux Cancellation Peer",
            modelName: "Cloud Bare Metal",
            platform: .linux,
            osVersion: "TestOS"
        )
        transport.connections.send([Connection(device: device, status: .connected)])
        for _ in 0..<500 where transport.submissions.isEmpty {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(transport.submissions.count, 1)

        transport.connections.send([])
        var interruptedIntent: PersistedDeliveryIntent?
        for _ in 0..<500 {
            let snapshot = try await runtime.currentSnapshot()
            if let intent = snapshot.deliveryIntents.first(where: {
                $0.queueID == queueID && $0.state == .pending
            }) {
                interruptedIntent = intent
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        let intent = try XCTUnwrap(interruptedIntent)
        XCTAssertEqual(intent.retryCount, 0)
        XCTAssertNil(intent.failureCode)
    }

    func testUnifiedManualRetryCoordinatesHistoryQueueAndOnlineWorker() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("skybridge-ios-unified-retry-\(UUID().uuidString)")
        let suiteName = "SkyBridgeIOSUnifiedRetry.\(UUID().uuidString)"
        defer {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: rootURL)
        }
        let runtime = try IOSUnifiedDeviceMessagingRuntime(
            defaultsSuiteName: suiteName,
            rootURLOverride: rootURL
        )
        _ = try await runtime.bootstrap()

        let targetDeviceID = "linux-peer-retry"
        let sentAt = Date()
        let payload = AppMessage.TextMessagePayload(
            id: UUID(),
            text: "retry owner-bound",
            sentAt: sentAt
        )
        let envelope = try JSONEncoder().encode(IOSDeviceTextQueueEnvelope(
            payload: payload,
            conversationFingerprint: fingerprint
        ))
        let message = PersistedMessageRecord(
            id: payload.id,
            conversationFingerprint: fingerprint,
            targetDeviceID: targetDeviceID,
            direction: .outgoing,
            text: payload.text,
            timestamp: sentAt,
            deliveryState: .pending
        )
        let intent = PersistedDeliveryIntent(
            queueID: UUID().uuidString.lowercased(),
            messageID: payload.id,
            targetDeviceID: targetDeviceID,
            messageType: OfflineMessageType.text.rawValue,
            priority: 1,
            payload: envelope,
            createdAt: sentAt,
            expiresAt: sentAt.addingTimeInterval(86_400)
        )
        _ = try await runtime.stageOutgoing(message: message, intent: intent)
        let failedClaim = try await runtime.claimNextReady(
            targetDeviceID: targetDeviceID,
            ownerToken: UUID(),
            retryPolicy: MessageDeliveryRetryPolicy(
                maximumRetryCount: 3,
                retryInterval: 1,
                backoffFactor: 2
            ),
            now: sentAt
        )
        _ = try await runtime.resolve(
            try XCTUnwrap(failedClaim),
            disposition: .permanentFailure(failureCode: "transport_failure"),
            retryPolicy: MessageDeliveryRetryPolicy(
                maximumRetryCount: 3,
                retryInterval: 1,
                backoffFactor: 2
            ),
            now: sentAt
        )

        let queue = makeQueue()
        let store = makeMessageStore()
        let transport = DeviceTextMessageTransportProbe()
        let service = DeviceMessagingService(
            messageStore: store,
            offlineQueue: queue,
            transport: transport,
            usesUnifiedRepository: true,
            unifiedRuntime: runtime
        )
        try await service.prepare()
        service.start()
        XCTAssertEqual(
            store.messages(conversationFingerprint: fingerprint).first?.deliveryState,
            .failed
        )
        XCTAssertEqual(queue.failedMessages.count, 1)

        let device = DiscoveredDevice(
            id: targetDeviceID,
            name: "Linux Retry Peer",
            modelName: "Cloud Bare Metal",
            platform: .linux,
            osVersion: "TestOS"
        )
        transport.connections.send([Connection(device: device, status: .connected)])
        try await Task.sleep(for: .milliseconds(10))
        try await service.retryFailedUnifiedQueuedDeliveries(now: Date())

        var submittedSnapshot: MessageRepositorySnapshot?
        for _ in 0..<500 {
            let snapshot = try await runtime.currentSnapshot()
            if snapshot.deliveryIntents.first?.state == .awaitingReceipt {
                submittedSnapshot = snapshot
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = try XCTUnwrap(submittedSnapshot)
        XCTAssertEqual(transport.submissions.count, 1)
        XCTAssertEqual(queue.pendingMessages.first?.status, .awaitingReceipt)
        XCTAssertEqual(
            store.messages(conversationFingerprint: fingerprint).first?.deliveryState,
            .sent
        )

        let submission = try XCTUnwrap(transport.submissions.first)
        try await service.handleAuthenticatedReceipt(
            AppMessage.TextMessageReceiptPayload(
                messageID: submission.messageId,
                deliveryAttemptID: try XCTUnwrap(submission.deliveryAttemptID)
            ),
            conversationFingerprint: fingerprint
        )
        XCTAssertTrue(queue.pendingMessages.isEmpty)
        XCTAssertTrue(queue.failedMessages.isEmpty)
        XCTAssertEqual(
            store.messages(conversationFingerprint: fingerprint).first?.deliveryState,
            .delivered
        )
    }

    func testDirectSendCancellationTransitionsOutgoingMessageOutOfPending() async throws {
        let queue = makeQueue()
        let store = makeMessageStore()
        let transport = DeviceTextMessageTransportProbe()
        transport.sendImplementation = { throw CancellationError() }
        let service = DeviceMessagingService(
            messageStore: store,
            offlineQueue: queue,
            transport: transport
        )

        do {
            try await service.send(
                text: "cancel me",
                toDeviceId: "peer-a",
                conversationFingerprint: fingerprint
            )
            XCTFail("Cancellation must be rethrown")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertEqual(
            store.messages(conversationFingerprint: fingerprint).first?.deliveryState,
            .failed
        )
        XCTAssertTrue(queue.pendingMessages.isEmpty)
    }

    func testMessagingSourcesRequireExactAuthenticatedAuthorityWithoutAliasFallback() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Repository source inspection runs only on the simulator/host test lane")
#else
        let iosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let p2p = try String(
            contentsOf: iosRoot.appendingPathComponent(
                "SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
            ),
            encoding: .utf8
        )
        let webRTC = try String(
            contentsOf: iosRoot.appendingPathComponent(
                "SkyBridgeCompassiOS/Sources/Managers/CrossNetworkWebRTCManager.swift"
            ),
            encoding: .utf8
        )
        let view = try String(
            contentsOf: iosRoot.appendingPathComponent(
                "SkyBridgeCompassiOS/Sources/Views/DeviceMessagingView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(p2p.contains("expectedConversationFingerprint: String"))
        XCTAssertTrue(p2p.contains("authenticatedTextMessageAuthority("))
        XCTAssertTrue(p2p.contains("requireCurrentTextMessageAuthority(authorityReceipt)"))
        XCTAssertTrue(p2p.contains("authenticatedConversationFingerprint("))
        XCTAssertFalse(p2p.contains("textMessageConversationLookupCandidates"))
        XCTAssertTrue(webRTC.contains("authenticatedHandshakePeerBindingBySessionId[sessionId]"))
        XCTAssertTrue(webRTC.contains("authenticatedConversationFingerprint("))
        XCTAssertFalse(webRTC.contains("fromPeerIds: ["))
        XCTAssertTrue(view.contains("store.isPersistenceBlocked"))
        XCTAssertTrue(view.contains("&& !offlineQueue.isPersistenceBlocked"))
        XCTAssertTrue(view.contains("offlineQueue.lastPersistenceError"))
        XCTAssertTrue(view.contains("if draft == submittedDraft"))
        XCTAssertTrue(view.contains("为避免覆盖损坏数据"))
#endif
    }
}
