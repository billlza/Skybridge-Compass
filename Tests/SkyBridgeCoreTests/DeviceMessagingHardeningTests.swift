import Foundation
import SkyBridgeProtocolCore
import XCTest
@testable import SkyBridgeCore

final class DeviceTextMessagePolicyTests: XCTestCase {
    func testTextAndIdentityValidationIsCanonicalAndBounded() throws {
        XCTAssertEqual(try DeviceTextMessagePolicy.validatedText("  hello  \n"), "hello")
        XCTAssertThrowsError(try DeviceTextMessagePolicy.validatedText(" \n\t "))
        XCTAssertThrowsError(
            try DeviceTextMessagePolicy.validatedText(
                String(repeating: "a", count: DeviceTextMessagePolicy.maximumCharacterCount + 1)
            )
        )

        let uppercaseFingerprint = String(repeating: "AB", count: 32)
        XCTAssertEqual(
            try DeviceTextMessagePolicy.normalizedConversationFingerprint(uppercaseFingerprint),
            uppercaseFingerprint.lowercased()
        )
        XCTAssertThrowsError(
            try DeviceTextMessagePolicy.normalizedConversationFingerprint(
                String(repeating: "g", count: 64)
            )
        )
        XCTAssertThrowsError(
            try DeviceTextMessagePolicy.normalizedTargetDeviceIdentifier("peer\u{0000}id")
        )
    }

    func testFailureCodesAreStablePayloadFreeWireValues() throws {
        let encoded = try JSONEncoder().encode(OfflineDeliveryFailureCode.authenticatedIdentityMismatch)
        XCTAssertEqual(
            try JSONDecoder().decode(OfflineDeliveryFailureCode.self, from: encoded),
            .authenticatedIdentityMismatch
        )
        XCTAssertEqual(
            OfflineDeliveryDisposition.cancelled,
            OfflineDeliveryDisposition.cancelled
        )
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("peer"))
    }
}

@MainActor
final class DeviceMessagingHardeningTests: XCTestCase {
    private static let fingerprint = String(repeating: "a", count: 64)

    func testQueueCancellationPreservesPendingWithoutConsumingRetryBudget() async throws {
        let fixture = try makeQueueFixture()
        defer { fixture.clear() }
        let probe = DeliveryProbe(queueDisposition: .cancelled)
        fixture.queue.sendHandler = { message in
            await probe.handleQueued(message)
        }

        let queued = try await fixture.queue.enqueue(
            targetDeviceID: "peer-one",
            messageType: .notification,
            payload: Data("payload".utf8)
        )
        await fixture.queue.deviceOnline("peer-one")
        try await waitUntil { !fixture.queue.isProcessing && probe.queueSendCount == 1 }

        let persisted = try XCTUnwrap(
            try fixture.queueStore.loadOrThrow()?.first(where: { $0.id == queued.id })
        )
        XCTAssertEqual(persisted.status, .pending)
        XCTAssertEqual(persisted.retryCount, 0)
        XCTAssertNil(persisted.lastFailureCode)
    }

    func testRepeatedOnlineTriggersUseOneExactOwnerAndSendOnce() async throws {
        let fixture = try makeQueueFixture()
        defer { fixture.clear() }
        let probe = DeliveryProbe(queueDisposition: .delivered, yieldsBeforeResult: true)
        fixture.queue.sendHandler = { message in
            await probe.handleQueued(message)
        }

        _ = try await fixture.queue.enqueue(
            targetDeviceID: "peer-one",
            messageType: .notification,
            payload: Data("payload".utf8)
        )
        await fixture.queue.deviceOnline("peer-one")
        await fixture.queue.deviceOnline("peer-one")
        try await waitUntil {
            probe.queueSendCount == 1 && fixture.queue.statistics.totalMessages == 0
        }

        XCTAssertEqual(probe.queueSendCount, 1)
        XCTAssertFalse(fixture.queue.isProcessing)
    }

    func testDeviceOfflineAfterClaimRestoresPendingBeforeTransportAdmission() async throws {
        let admissionGate = MessageGate()
        let fixture = try makeQueueFixture { claim in
            await admissionGate.pause(messageID: claim.message.id)
        }
        defer { fixture.clear() }
        let probe = DeliveryProbe(queueDisposition: .delivered)
        fixture.queue.sendHandler = { message in
            await probe.handleQueued(message)
        }
        let queued = try await fixture.queue.enqueue(
            targetDeviceID: "peer-one",
            messageType: .notification,
            payload: Data("payload".utf8)
        )
        await fixture.queue.deviceOnline("peer-one")
        let admittedMessageID = await admissionGate.waitUntilPaused()
        XCTAssertEqual(admittedMessageID, queued.id)

        fixture.queue.deviceOffline("peer-one")
        admissionGate.release()
        try await waitUntil { !fixture.queue.isProcessing }

        XCTAssertEqual(probe.queueSendCount, 0)
        let persisted = try XCTUnwrap(try fixture.queueStore.loadOrThrow()?.first)
        XCTAssertEqual(persisted.id, queued.id)
        XCTAssertEqual(persisted.status, .pending)
        XCTAssertEqual(persisted.retryCount, 0)
    }

    func testSingleMessageCancelAfterClaimPreventsTransportAdmission() async throws {
        let admissionGate = MessageGate()
        let fixture = try makeQueueFixture { claim in
            await admissionGate.pause(messageID: claim.message.id)
        }
        defer { fixture.clear() }
        let probe = DeliveryProbe(queueDisposition: .delivered)
        fixture.queue.sendHandler = { message in
            await probe.handleQueued(message)
        }
        let queued = try await fixture.queue.enqueue(
            targetDeviceID: "peer-one",
            messageType: .notification,
            payload: Data("payload".utf8)
        )
        await fixture.queue.deviceOnline("peer-one")
        let admittedMessageID = await admissionGate.waitUntilPaused()
        XCTAssertEqual(admittedMessageID, queued.id)

        try await fixture.queue.cancel(messageID: queued.id)
        admissionGate.release()
        try await waitUntil { !fixture.queue.isProcessing }

        XCTAssertEqual(probe.queueSendCount, 0)
        XCTAssertEqual(try fixture.queueStore.loadOrThrow(), [])
        XCTAssertEqual(fixture.queue.persistenceState, .ready)
    }

    func testDeliveredDispositionStillWinsWhenWorkerIsCancelledDuringSend() async throws {
        let deliveryGate = MessageGate()
        let fixture = try makeQueueFixture()
        defer { fixture.clear() }
        let probe = DeliveryProbe(
            queueDisposition: .delivered,
            resultGate: deliveryGate
        )
        fixture.queue.sendHandler = { message in
            await probe.handleQueued(message)
        }
        let queued = try await fixture.queue.enqueue(
            targetDeviceID: "peer-one",
            messageType: .notification,
            payload: Data("payload".utf8)
        )
        await fixture.queue.deviceOnline("peer-one")
        let sendingMessageID = await deliveryGate.waitUntilPaused()
        XCTAssertEqual(sendingMessageID, queued.id)

        fixture.queue.deviceOffline("peer-one")
        deliveryGate.release()
        try await waitUntil { !fixture.queue.isProcessing }

        XCTAssertEqual(probe.queueSendCount, 1)
        XCTAssertEqual(try fixture.queueStore.loadOrThrow(), [])
        XCTAssertEqual(fixture.queue.statistics.totalMessages, 0)
    }

    func testMalformedQueuedTextIsPermanentFailureWithoutTransportSend() async throws {
        let fixture = try makeQueueFixture()
        defer { fixture.clear() }
        let messageStoreFixture = try makeMessageStoreFixture()
        defer { messageStoreFixture.clear() }
        let probe = DeliveryProbe()
        let service = DeviceMessagingService(
            store: messageStoreFixture.store,
            queue: fixture.queue,
            transport: DeviceMessageTransport { deviceID, fingerprint, payload in
                try await probe.sendTransport(
                    deviceID: deviceID,
                    fingerprint: fingerprint,
                    payload: payload
                )
            },
            observesProductionConnections: false
        )
        service.start()

        _ = try await fixture.queue.enqueue(
            targetDeviceID: "peer-one",
            messageType: .text,
            payload: Data("not-an-envelope".utf8)
        )
        await fixture.queue.deviceOnline("peer-one")
        try await waitUntil { fixture.queue.statistics.failedMessages == 1 }

        XCTAssertEqual(probe.transportSendCount, 0)
        XCTAssertEqual(
            try fixture.queueStore.loadOrThrow()?.first?.lastFailureCode,
            .invalidPayload
        )
    }

    func testDirectCancellationIsNotQueuedAndIsVisibleAsFailedHistory() async throws {
        let fixture = try makeQueueFixture()
        defer { fixture.clear() }
        let messageStoreFixture = try makeMessageStoreFixture()
        defer { messageStoreFixture.clear() }
        let probe = DeliveryProbe(transportBehavior: .cancel)
        let service = DeviceMessagingService(
            store: messageStoreFixture.store,
            queue: fixture.queue,
            transport: DeviceMessageTransport { deviceID, fingerprint, payload in
                try await probe.sendTransport(
                    deviceID: deviceID,
                    fingerprint: fingerprint,
                    payload: payload
                )
            },
            observesProductionConnections: false
        )

        do {
            try await service.send(
                text: "cancel me",
                toDeviceID: "peer-one",
                fingerprint: Self.fingerprint
            )
            XCTFail("Cancellation must be observable")
        } catch is CancellationError {
            // Expected explicit cancellation.
        }

        let pendingQueue = try await fixture.queue.getAllPendingMessages()
        XCTAssertTrue(pendingQueue.isEmpty)
        let messages = try messageStoreFixture.store.messages(fingerprint: Self.fingerprint)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.deliveryState, .failed)
        XCTAssertEqual(probe.transportSendCount, 1)
    }

    func testRetryableTransportFailureQueuesAndLeavesHistoryPending() async throws {
        let fixture = try makeQueueFixture()
        defer { fixture.clear() }
        let messageStoreFixture = try makeMessageStoreFixture()
        defer { messageStoreFixture.clear() }
        let probe = DeliveryProbe(transportBehavior: .unavailable)
        let service = DeviceMessagingService(
            store: messageStoreFixture.store,
            queue: fixture.queue,
            transport: DeviceMessageTransport { deviceID, fingerprint, payload in
                try await probe.sendTransport(
                    deviceID: deviceID,
                    fingerprint: fingerprint,
                    payload: payload
                )
            },
            observesProductionConnections: false
        )

        try await service.send(
            text: "queue me",
            toDeviceID: "peer-one",
            fingerprint: Self.fingerprint
        )

        let pendingQueue = try await fixture.queue.getAllPendingMessages()
        XCTAssertEqual(pendingQueue.count, 1)
        let messages = try messageStoreFixture.store.messages(fingerprint: Self.fingerprint)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.deliveryState, .pending)
    }

    func testCancelledStaleQueuedAttemptCannotMarkHistoryFailed() async throws {
        let fixture = try makeQueueFixture()
        defer { fixture.clear() }
        let messageStoreFixture = try makeMessageStoreFixture()
        defer { messageStoreFixture.clear() }
        let transportGate = MessageGate()
        var transportSendCount = 0
        let service = DeviceMessagingService(
            store: messageStoreFixture.store,
            queue: fixture.queue,
            transport: DeviceMessageTransport { _, _, payload in
                transportSendCount += 1
                if transportSendCount == 1 {
                    throw DeviceMessagingError.transportUnavailable
                }
                await transportGate.pause(messageID: payload.id)
                throw P2PConnectionError.authenticatedIdentityMismatch
            },
            observesProductionConnections: false
        )
        service.start()
        try await service.send(
            text: "preserve exact owner",
            toDeviceID: "peer-one",
            fingerprint: Self.fingerprint
        )

        await fixture.queue.deviceOnline("peer-one")
        _ = await transportGate.waitUntilPaused()
        fixture.queue.deviceOffline("peer-one")
        transportGate.release()
        try await waitUntil { !fixture.queue.isProcessing }

        let messages = try messageStoreFixture.store.messages(fingerprint: Self.fingerprint)
        XCTAssertEqual(messages.first?.deliveryState, .pending)
        XCTAssertEqual(try fixture.queueStore.loadOrThrow()?.first?.status, .pending)
        XCTAssertEqual(transportSendCount, 2)
    }

    func testCorruptQueueBytesBlockUntilExplicitQuarantineAndClear() async throws {
        let corrupt = Data("{not-json".utf8)
        let fixture = try makeQueueFixture(corruptQueueBytes: corrupt)
        defer { fixture.clear() }

        do {
            _ = try await fixture.queue.getAllPendingMessages()
            XCTFail("Corrupt canonical queue must block reads")
        } catch let error as OfflineQueueError {
            guard case .persistenceBlocked = error else {
                return XCTFail("Unexpected queue error: \(error)")
            }
        }
        XCTAssertEqual(fixture.defaults.data(forKey: fixture.queueKey), corrupt)

        try await fixture.queue.clearAll()

        XCTAssertEqual(try fixture.queueStore.loadOrThrow(), [])
        XCTAssertEqual(fixture.quarantinedPayload(prefix: fixture.queueKey), corrupt)
        XCTAssertEqual(fixture.queue.persistenceState, .ready)
    }

    func testCorruptConfigurationCannotBeOverwrittenBeforeExplicitRecovery() async throws {
        let corrupt = Data("{bad-config".utf8)
        let fixture = try makeQueueFixture(corruptConfigurationBytes: corrupt)
        defer { fixture.clear() }
        var changed = OfflineQueueConfiguration.default
        changed.priorityOrdering = false

        XCTAssertThrowsError(try fixture.queue.updateConfiguration(changed))
        XCTAssertEqual(fixture.defaults.data(forKey: fixture.configurationKey), corrupt)
        guard case .blocked = fixture.queue.configurationPersistenceState else {
            return XCTFail("Corrupt configuration must remain blocked")
        }

        try await fixture.queue.resetConfigurationForRecovery()

        XCTAssertEqual(try fixture.configurationStore.loadOrThrow(), .default)
        XCTAssertEqual(
            fixture.quarantinedPayload(prefix: fixture.configurationKey),
            corrupt
        )
        XCTAssertEqual(fixture.queue.configurationPersistenceState, .ready)
    }

    func testQueueSaveCapacityFailureRollsBackAndKeepsRepositoryReady() async throws {
        let fixture = try makeQueueFixture(queueMaximumPayloadBytes: 2)
        defer { fixture.clear() }

        do {
            _ = try await fixture.queue.enqueue(
                targetDeviceID: "peer-one",
                messageType: .notification,
                payload: Data("payload".utf8)
            )
            XCTFail("Oversized canonical write must fail")
        } catch let error as OfflineQueueError {
            guard case .storageCapacityExceeded(let actualBytes, let maximumBytes) = error else {
                return XCTFail("Unexpected queue error: \(error)")
            }
            XCTAssertGreaterThan(actualBytes, maximumBytes)
            XCTAssertEqual(maximumBytes, 2)
        }

        XCTAssertEqual(fixture.queue.statistics.totalMessages, 0)
        XCTAssertNil(fixture.defaults.data(forKey: fixture.queueKey))
        XCTAssertEqual(fixture.queue.persistenceState, .ready)
    }

    func testAggregateCapacityAcceptsTwoMaximumItemsAndRejectsThirdRecoverably() async throws {
        let fixture = try makeQueueFixture()
        defer { fixture.clear() }
        let maximumItem = Data(
            repeating: 0x5A,
            count: QueuedMessage.maximumPayloadBytes
        )
        let first = try await fixture.queue.enqueue(
            targetDeviceID: "peer-one",
            messageType: .notification,
            payload: maximumItem
        )
        let second = try await fixture.queue.enqueue(
            targetDeviceID: "peer-two",
            messageType: .notification,
            payload: maximumItem
        )
        let canonicalBytesBeforeRejectedWrite = try XCTUnwrap(
            fixture.defaults.data(forKey: fixture.queueKey)
        )

        do {
            _ = try await fixture.queue.enqueue(
                targetDeviceID: "peer-three",
                messageType: .notification,
                payload: maximumItem
            )
            XCTFail("The third maximum-sized item must exceed the canonical file budget")
        } catch let error as OfflineQueueError {
            guard case .storageCapacityExceeded(let actualBytes, let maximumBytes) = error else {
                return XCTFail("Unexpected queue error: \(error)")
            }
            XCTAssertGreaterThan(actualBytes, maximumBytes)
            XCTAssertEqual(
                maximumBytes,
                CodablePersistenceStore<[QueuedMessage]>.defaultMaximumPayloadBytes
            )
        }

        let readable = try await fixture.queue.getAllPendingMessages()
        XCTAssertEqual(Set(readable.map(\.id)), Set([first.id, second.id]))
        XCTAssertTrue(readable.allSatisfy { $0.payload.count == maximumItem.count })
        XCTAssertEqual(try fixture.queueStore.loadOrThrow()?.count, 2)
        XCTAssertEqual(
            fixture.defaults.data(forKey: fixture.queueKey),
            canonicalBytesBeforeRejectedWrite
        )
        XCTAssertEqual(fixture.queue.persistenceState, .ready)
    }

    func testFailedRecoveryWriteRemainsBlockedAndPreservesQuarantine() async throws {
        let corrupt = Data("corrupt".utf8)
        let fixture = try makeQueueFixture(
            queueMaximumPayloadBytes: 1,
            corruptQueueBytes: corrupt
        )
        defer { fixture.clear() }

        do {
            try await fixture.queue.clearAll()
            XCTFail("Replacement write must fail when even an empty array exceeds the limit")
        } catch let error as OfflineQueueError {
            guard case .persistenceBlocked = error else {
                return XCTFail("Unexpected queue error: \(error)")
            }
        }

        XCTAssertNil(fixture.defaults.data(forKey: fixture.queueKey))
        XCTAssertEqual(fixture.quarantinedPayload(prefix: fixture.queueKey), corrupt)
        guard case .blocked = fixture.queue.persistenceState else {
            return XCTFail("Failed replacement must remain blocked")
        }
    }

    func testBatchEnqueueIsAtomicWhenPerDeviceCapacityWouldBeExceeded() async throws {
        var configuration = OfflineQueueConfiguration.default
        configuration.maxQueueSize = 10
        configuration.maxMessagesPerDevice = 1
        let fixture = try makeQueueFixture(configuration: configuration)
        defer { fixture.clear() }

        do {
            _ = try await fixture.queue.enqueueBatch([
                ("peer-one", .notification, .normal, Data("one".utf8)),
                ("peer-one", .notification, .normal, Data("two".utf8))
            ])
            XCTFail("Batch must reject the complete transaction")
        } catch let error as OfflineQueueError {
            guard case .deviceQueueFull = error else {
                return XCTFail("Unexpected queue error: \(error)")
            }
        }

        let pendingQueue = try await fixture.queue.getAllPendingMessages()
        XCTAssertTrue(pendingQueue.isEmpty)
        XCTAssertNil(fixture.defaults.data(forKey: fixture.queueKey))
        XCTAssertEqual(fixture.queue.persistenceState, .ready)
    }

    func testStaleClaimDoesNotBlockRepository() async throws {
        let fixture = try makeQueueFixture()
        defer { fixture.clear() }
        let repository = OfflineMessageQueueRepository(store: fixture.queueStore)
        let configuration = OfflineQueueConfiguration.default
        _ = try await repository.bootstrap(configuration: configuration)
        let message = QueuedMessage(
            targetDeviceID: "peer-one",
            messageType: .notification,
            payload: Data("payload".utf8)
        )
        _ = try await repository.enqueue(message, configuration: configuration)
        let optionalClaim = try await repository.claimNextReadyMessage(
            for: "peer-one",
            ownerToken: UUID(),
            configuration: configuration
        )
        let claim = try XCTUnwrap(optionalClaim)
        _ = try await repository.cancel(
            messageID: message.id,
            configuration: configuration
        )

        do {
            _ = try await repository.resolve(
                claim,
                disposition: .delivered,
                configuration: configuration
            )
            XCTFail("Cancelled claim must be stale")
        } catch let error as OfflineQueueError {
            guard case .staleClaim = error else {
                return XCTFail("Unexpected queue error: \(error)")
            }
        }
        let currentSnapshot = await repository.currentSnapshot()
        XCTAssertEqual(currentSnapshot.persistenceState, .ready)
    }

    func testExpiryCleanupCannotInvalidateAnInflightClaim() async throws {
        let fixture = try makeQueueFixture()
        defer { fixture.clear() }
        let repository = OfflineMessageQueueRepository(store: fixture.queueStore)
        let configuration = OfflineQueueConfiguration.default
        _ = try await repository.bootstrap(configuration: configuration)
        let message = QueuedMessage(
            targetDeviceID: "peer-one",
            messageType: .notification,
            payload: Data("payload".utf8),
            ttl: 60
        )
        _ = try await repository.enqueue(message, configuration: configuration)
        let optionalClaim = try await repository.claimNextReadyMessage(
            for: "peer-one",
            ownerToken: UUID(),
            configuration: configuration
        )
        let claim = try XCTUnwrap(optionalClaim)

        let cleanup = try await repository.cleanupExpired(
            configuration: configuration,
            now: message.expiresAt.addingTimeInterval(1)
        )

        XCTAssertEqual(cleanup.removedCount, 0)
        XCTAssertEqual(cleanup.snapshot.messages.first?.status, .sending)
        let resolved = try await repository.resolve(
            claim,
            disposition: .delivered,
            configuration: configuration
        )
        XCTAssertTrue(resolved.messages.isEmpty)
    }

    func testFailedTerminalMessageDoesNotConsumeActiveCapacity() async throws {
        var configuration = OfflineQueueConfiguration.default
        configuration.maxQueueSize = 1
        configuration.maxMessagesPerDevice = 1
        let fixture = try makeQueueFixture(configuration: configuration)
        defer { fixture.clear() }
        let repository = OfflineMessageQueueRepository(store: fixture.queueStore)
        _ = try await repository.bootstrap(configuration: configuration)
        let first = QueuedMessage(
            targetDeviceID: "peer-one",
            messageType: .notification,
            payload: Data("one".utf8)
        )
        _ = try await repository.enqueue(first, configuration: configuration)
        let optionalClaim = try await repository.claimNextReadyMessage(
            for: "peer-one",
            ownerToken: UUID(),
            configuration: configuration
        )
        let claim = try XCTUnwrap(optionalClaim)
        _ = try await repository.resolve(
            claim,
            disposition: .permanentFailure(.invalidPayload),
            configuration: configuration
        )

        let second = QueuedMessage(
            targetDeviceID: "peer-two",
            messageType: .notification,
            payload: Data("two".utf8)
        )
        let snapshot = try await repository.enqueue(second, configuration: configuration)

        XCTAssertEqual(snapshot.statistics.failedMessages, 1)
        XCTAssertEqual(snapshot.statistics.pendingMessages, 1)
        XCTAssertEqual(snapshot.statistics.totalMessages, 2)
    }

    func testTextFailureCannotBeRetriedWithoutCoordinatingConversationState() async throws {
        let fixture = try makeQueueFixture()
        defer { fixture.clear() }
        let repository = OfflineMessageQueueRepository(store: fixture.queueStore)
        let configuration = OfflineQueueConfiguration.default
        _ = try await repository.bootstrap(configuration: configuration)
        let message = QueuedMessage(
            targetDeviceID: "peer-one",
            messageType: .text,
            payload: Data("payload".utf8)
        )
        _ = try await repository.enqueue(message, configuration: configuration)
        let optionalClaim = try await repository.claimNextReadyMessage(
            for: "peer-one",
            ownerToken: UUID(),
            configuration: configuration
        )
        let claim = try XCTUnwrap(optionalClaim)
        _ = try await repository.resolve(
            claim,
            disposition: .permanentFailure(.transportFailure),
            configuration: configuration
        )
        let canonicalBeforeRetry = try fixture.queueStore.loadOrThrow()

        do {
            _ = try await repository.resetFailed(configuration: configuration)
            XCTFail("Text retry must be coordinated with DeviceMessageStore")
        } catch let error as OfflineQueueError {
            guard case .coordinatedRetryRequired = error else {
                return XCTFail("Unexpected queue error: \(error)")
            }
        }

        XCTAssertEqual(try fixture.queueStore.loadOrThrow(), canonicalBeforeRetry)
        XCTAssertEqual(try fixture.queueStore.loadOrThrow()?.first?.status, .failed)
    }

    func testInterruptedSendingStateRecoversToPendingOnBootstrap() async throws {
        let fixture = try makeQueueFixture()
        defer { fixture.clear() }
        var interrupted = QueuedMessage(
            targetDeviceID: "peer-one",
            messageType: .notification,
            payload: Data("payload".utf8)
        )
        interrupted.markSending()
        try fixture.queueStore.save([interrupted])
        let repository = OfflineMessageQueueRepository(store: fixture.queueStore)

        let snapshot = try await repository.bootstrap(configuration: .default)

        XCTAssertEqual(snapshot.messages.first?.status, .pending)
        XCTAssertEqual(try fixture.queueStore.loadOrThrow()?.first?.status, .pending)
    }

    func testConversationStoreCorruptionBlocksAndExplicitClearQuarantines() async throws {
        let fixture = try makeMessageStoreFixture(corruptBytes: Data("{bad-history".utf8))
        defer { fixture.clear() }
        let corrupt = try XCTUnwrap(fixture.defaults.data(forKey: fixture.key))

        do {
            try await fixture.store.appendOutgoing(
                text: "hello",
                fingerprint: Self.fingerprint,
                targetDeviceID: "peer-one",
                messageID: UUID(),
                sentAt: Date()
            )
            XCTFail("Corrupt history must block append")
        } catch let error as DeviceMessageStoreError {
            guard case .persistenceBlocked = error else {
                return XCTFail("Unexpected store error: \(error)")
            }
        }
        XCTAssertEqual(fixture.defaults.data(forKey: fixture.key), corrupt)

        try await fixture.store.clearAllForRecovery()

        XCTAssertEqual(try fixture.persistence.loadOrThrow(), [:])
        XCTAssertEqual(fixture.quarantinedPayload(), corrupt)
        XCTAssertEqual(fixture.store.persistenceState, .ready)
    }

    func testConversationSaveCapacityFailureRollsBackAndKeepsPublishedStateReady() async throws {
        let fixture = try makeMessageStoreFixture(maximumPayloadBytes: 1)
        defer { fixture.clear() }

        do {
            try await fixture.store.appendOutgoing(
                text: "hello",
                fingerprint: Self.fingerprint,
                targetDeviceID: "peer-one",
                messageID: UUID(),
                sentAt: Date()
            )
            XCTFail("History save must fail")
        } catch let error as DeviceMessageStoreError {
            guard case .storageCapacityExceeded(let actualBytes, let maximumBytes) = error else {
                return XCTFail("Unexpected store error: \(error)")
            }
            XCTAssertGreaterThan(actualBytes, maximumBytes)
            XCTAssertEqual(maximumBytes, 1)
        }

        XCTAssertTrue(fixture.store.conversations.isEmpty)
        XCTAssertNil(fixture.defaults.data(forKey: fixture.key))
        XCTAssertEqual(fixture.store.persistenceState, .ready)
    }

    func testConversationCapacityRejectsMutationWithoutChangingCanonicalBytes() async throws {
        let suiteName = "DeviceMessagingHardening.StoreCapacity.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "history"
        let base = Date(timeIntervalSinceReferenceDate: 5_000)
        let existing = DeviceMessageStore.Message(
            direction: .incoming,
            text: "existing",
            timestamp: base,
            deliveryState: .delivered
        )
        let rejected = DeviceMessageStore.Message(
            direction: .incoming,
            text: String(repeating: "r", count: 1_024),
            timestamp: base.addingTimeInterval(1),
            deliveryState: .delivered
        )
        let initial = [Self.fingerprint: [existing]]
        let candidate = [Self.fingerprint: [existing, rejected]]
        let encoder = JSONEncoder()
        let initialByteCount = try encoder.encode(initial).count
        XCTAssertGreaterThan(try encoder.encode(candidate).count, initialByteCount)
        let persistence = CodablePersistenceStore<[String: [DeviceMessageStore.Message]]>(
            location: .userDefaults(key: key),
            defaults: defaults,
            maximumPayloadBytes: initialByteCount
        )
        try persistence.save(initial)
        let canonicalBytesBeforeRejectedWrite = try XCTUnwrap(defaults.data(forKey: key))
        let repository = DeviceMessageConversationRepository(
            store: persistence,
            maximumMessagesPerConversation: 500
        )
        _ = try await repository.bootstrap()

        do {
            _ = try await repository.receiveIncoming(
                text: rejected.text,
                conversationFingerprint: Self.fingerprint,
                messageID: rejected.id,
                sentAt: rejected.timestamp
            )
            XCTFail("Aggregate history capacity must reject the candidate mutation")
        } catch let error as DeviceMessageStoreError {
            guard case .storageCapacityExceeded(let actualBytes, let maximumBytes) = error else {
                return XCTFail("Unexpected store error: \(error)")
            }
            XCTAssertGreaterThan(actualBytes, maximumBytes)
            XCTAssertEqual(maximumBytes, initialByteCount)
            XCTAssertEqual(
                DeviceMessagingService.logSafeErrorSummary(error),
                OfflineDeliveryFailureCode.storageCapacityExceeded.rawValue
            )
        }

        let snapshot = await repository.currentSnapshot()
        XCTAssertEqual(snapshot.persistenceState, .ready)
        XCTAssertEqual(snapshot.conversations[Self.fingerprint]?.map(\.id), [existing.id])
        XCTAssertEqual(defaults.data(forKey: key), canonicalBytesBeforeRejectedWrite)
        XCTAssertEqual(try persistence.loadOrThrow()?[Self.fingerprint]?.map(\.id), [existing.id])
    }

    func testConversationLoadTimeOversizeStillBlocksWithoutChangingBytes() async throws {
        let suiteName = "DeviceMessagingHardening.StoreOversizeLoad.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "history"
        let oversized = [
            Self.fingerprint: [
                DeviceMessageStore.Message(
                    direction: .incoming,
                    text: String(repeating: "x", count: 2_048),
                    timestamp: Date(timeIntervalSinceReferenceDate: 6_000),
                    deliveryState: .delivered
                )
            ]
        ]
        let oversizedBytes = try JSONEncoder().encode(oversized)
        defaults.set(oversizedBytes, forKey: key)
        let maximumBytes = max(1, oversizedBytes.count - 1)
        let persistence = CodablePersistenceStore<[String: [DeviceMessageStore.Message]]>(
            location: .userDefaults(key: key),
            defaults: defaults,
            maximumPayloadBytes: maximumBytes
        )
        let repository = DeviceMessageConversationRepository(
            store: persistence,
            maximumMessagesPerConversation: 500
        )

        do {
            _ = try await repository.bootstrap()
            XCTFail("Oversized canonical history must block load")
        } catch let error as DeviceMessageStoreError {
            guard case .persistenceBlocked = error else {
                return XCTFail("Unexpected store error: \(error)")
            }
        }

        let snapshot = await repository.currentSnapshot()
        guard case .blocked = snapshot.persistenceState else {
            return XCTFail("Load-time oversize must remain fail-closed")
        }
        XCTAssertTrue(snapshot.conversations.isEmpty)
        XCTAssertEqual(defaults.data(forKey: key), oversizedBytes)
    }

    func testConversationClearRejectsPendingOutgoingMessages() async throws {
        let fixture = try makeMessageStoreFixture()
        defer { fixture.clear() }
        let messageID = UUID()
        try await fixture.store.appendOutgoing(
            text: "pending",
            fingerprint: Self.fingerprint,
            targetDeviceID: "peer-one",
            messageID: messageID,
            sentAt: Date()
        )

        do {
            try await fixture.store.clearConversation(fingerprint: Self.fingerprint)
            XCTFail("Pending outgoing history must not be destructively cleared")
        } catch let error as DeviceMessageStoreError {
            guard case .pendingOutgoingMessagesPreventClear(let count) = error else {
                return XCTFail("Unexpected store error: \(error)")
            }
            XCTAssertEqual(count, 1)
        }
        XCTAssertEqual(
            try fixture.store.messages(fingerprint: Self.fingerprint).map(\.id),
            [messageID]
        )

        try await fixture.store.markSent(
            messageID: messageID,
            fingerprint: Self.fingerprint
        )
        try await fixture.store.clearConversation(fingerprint: Self.fingerprint)
        XCTAssertTrue(try fixture.store.messages(fingerprint: Self.fingerprint).isEmpty)
    }

    func testConversationBoundingRetainsOlderPendingOutgoingMessage() async throws {
        let suiteName = "DeviceMessagingHardening.StoreBound.\(UUID().uuidString)"
        let key = "history"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = CodablePersistenceStore<[String: [DeviceMessageStore.Message]]>(
            location: .userDefaults(key: key),
            defaults: defaults
        )
        let base = Date(timeIntervalSinceReferenceDate: 1_000)
        let pending = DeviceMessageStore.Message(
            direction: .outgoing,
            text: "pending",
            timestamp: base,
            deliveryState: .pending,
            targetDeviceID: "peer-one"
        )
        let delivered = (1...3).map { offset in
            DeviceMessageStore.Message(
                direction: .incoming,
                text: "delivered-\(offset)",
                timestamp: base.addingTimeInterval(Double(offset)),
                deliveryState: .delivered
            )
        }
        try persistence.save([Self.fingerprint: [pending] + delivered])
        let repository = DeviceMessageConversationRepository(
            store: persistence,
            maximumMessagesPerConversation: 2
        )

        let snapshot = try await repository.bootstrap()
        let retained = try XCTUnwrap(snapshot.conversations[Self.fingerprint])

        XCTAssertEqual(retained.count, 2)
        XCTAssertTrue(retained.contains(where: { $0.id == pending.id }))
        XCTAssertTrue(retained.contains(where: { $0.id == delivered.last?.id }))
        XCTAssertEqual(try persistence.loadOrThrow()?[Self.fingerprint]?.count, 2)
    }

    func testIdentityMismatchIsAReleaseBlockingPermanentFailure() {
        XCTAssertEqual(
            DeviceMessagingService.deliveryDisposition(
                for: P2PConnectionError.authenticatedIdentityMismatch
            ),
            .permanentFailure(.authenticatedIdentityMismatch)
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for asynchronous messaging state")
    }

    private func makeQueueFixture(
        configuration: OfflineQueueConfiguration = .default,
        queueMaximumPayloadBytes: Int = CodablePersistenceStore<[QueuedMessage]>.defaultMaximumPayloadBytes,
        corruptQueueBytes: Data? = nil,
        corruptConfigurationBytes: Data? = nil,
        claimAdmissionGate: OfflineMessageQueue.ClaimAdmissionGate? = nil
    ) throws -> QueueFixture {
        let suiteName = "DeviceMessagingHardening.Queue.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let queueKey = "queue"
        let configurationKey = "configuration"
        let queueStore = CodablePersistenceStore<[QueuedMessage]>(
            location: .userDefaults(key: queueKey),
            defaults: defaults,
            maximumPayloadBytes: queueMaximumPayloadBytes
        )
        let configurationStore = CodablePersistenceStore<OfflineQueueConfiguration>(
            location: .userDefaults(key: configurationKey),
            defaults: defaults
        )
        if let corruptQueueBytes {
            defaults.set(corruptQueueBytes, forKey: queueKey)
        }
        if let corruptConfigurationBytes {
            defaults.set(corruptConfigurationBytes, forKey: configurationKey)
        } else {
            try configurationStore.save(configuration)
        }
        let queue = OfflineMessageQueue(
            queueStore: queueStore,
            configurationStore: configurationStore,
            automaticallyStartsProcessing: false,
            claimAdmissionGate: claimAdmissionGate
        )
        return QueueFixture(
            suiteName: suiteName,
            defaults: defaults,
            queueKey: queueKey,
            configurationKey: configurationKey,
            queueStore: queueStore,
            configurationStore: configurationStore,
            queue: queue
        )
    }

    private func makeMessageStoreFixture(
        maximumPayloadBytes: Int = CodablePersistenceStore<
            [String: [DeviceMessageStore.Message]]
        >.defaultMaximumPayloadBytes,
        corruptBytes: Data? = nil
    ) throws -> MessageStoreFixture {
        let suiteName = "DeviceMessagingHardening.Store.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let key = "history"
        let persistence = CodablePersistenceStore<[String: [DeviceMessageStore.Message]]>(
            location: .userDefaults(key: key),
            defaults: defaults,
            maximumPayloadBytes: maximumPayloadBytes
        )
        if let corruptBytes {
            defaults.set(corruptBytes, forKey: key)
        }
        return MessageStoreFixture(
            suiteName: suiteName,
            defaults: defaults,
            key: key,
            persistence: persistence,
            store: DeviceMessageStore(store: persistence)
        )
    }
}

@MainActor
private final class DeliveryProbe {
    enum TransportBehavior {
        case succeed
        case cancel
        case unavailable
    }

    private let queueDisposition: OfflineDeliveryDisposition
    private let yieldsBeforeResult: Bool
    private let transportBehavior: TransportBehavior
    private let resultGate: MessageGate?
    private(set) var queueSendCount = 0
    private(set) var transportSendCount = 0

    init(
        queueDisposition: OfflineDeliveryDisposition = .delivered,
        yieldsBeforeResult: Bool = false,
        transportBehavior: TransportBehavior = .succeed,
        resultGate: MessageGate? = nil
    ) {
        self.queueDisposition = queueDisposition
        self.yieldsBeforeResult = yieldsBeforeResult
        self.transportBehavior = transportBehavior
        self.resultGate = resultGate
    }

    func handleQueued(_ message: QueuedMessage) async -> OfflineDeliveryDisposition {
        _ = message
        queueSendCount += 1
        if yieldsBeforeResult {
            await Task.yield()
        }
        if let resultGate {
            await resultGate.pause(messageID: message.id)
        }
        return queueDisposition
    }

    func sendTransport(
        deviceID: String,
        fingerprint: String,
        payload: AppMessage.TextMessagePayload
    ) async throws {
        _ = (deviceID, fingerprint, payload)
        transportSendCount += 1
        switch transportBehavior {
        case .succeed:
            return
        case .cancel:
            throw CancellationError()
        case .unavailable:
            throw DeviceMessagingError.transportUnavailable
        }
    }
}

@MainActor
private final class MessageGate {
    private var pausedMessageID: UUID?
    private var pausedWaiter: CheckedContinuation<UUID, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func pause(messageID: UUID) async {
        precondition(pausedMessageID == nil, "MessageGate supports one pause")
        pausedMessageID = messageID
        pausedWaiter?.resume(returning: messageID)
        pausedWaiter = nil
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func waitUntilPaused() async -> UUID {
        if let pausedMessageID { return pausedMessageID }
        return await withCheckedContinuation { continuation in
            pausedWaiter = continuation
        }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

@MainActor
private struct QueueFixture {
    let suiteName: String
    let defaults: UserDefaults
    let queueKey: String
    let configurationKey: String
    let queueStore: CodablePersistenceStore<[QueuedMessage]>
    let configurationStore: CodablePersistenceStore<OfflineQueueConfiguration>
    let queue: OfflineMessageQueue

    func quarantinedPayload(prefix: String) -> Data? {
        let quarantineKey = defaults.dictionaryRepresentation().keys.first {
            $0.hasPrefix("\(prefix).quarantine.")
        }
        guard let quarantineKey else { return nil }
        return defaults.data(forKey: quarantineKey)
    }

    func clear() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

@MainActor
private struct MessageStoreFixture {
    let suiteName: String
    let defaults: UserDefaults
    let key: String
    let persistence: CodablePersistenceStore<[String: [DeviceMessageStore.Message]]>
    let store: DeviceMessageStore

    func quarantinedPayload() -> Data? {
        let quarantineKey = defaults.dictionaryRepresentation().keys.first {
            $0.hasPrefix("\(key).quarantine.")
        }
        guard let quarantineKey else { return nil }
        return defaults.data(forKey: quarantineKey)
    }

    func clear() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
