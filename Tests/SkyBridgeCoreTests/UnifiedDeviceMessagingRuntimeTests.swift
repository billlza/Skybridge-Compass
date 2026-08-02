import Foundation
import Crypto
import SkyBridgeMessagePersistence
import SkyBridgeProtocolCore
import XCTest
@testable import SkyBridgeCore

@MainActor
final class UnifiedDeviceMessagingRuntimeTests: XCTestCase {
    private static let fingerprint = String(repeating: "a", count: 64)

    func testLegacyConversationAboveFourMiBMigratesWithoutDataLossAndReopens() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let historyDirectory = fixture.rootURL
            .appendingPathComponent("Messaging", isDirectory: true)
        let historyURL = historyDirectory
            .appendingPathComponent("conversations.json", isDirectory: false)
        try FileManager.default.createDirectory(
            at: historyDirectory,
            withIntermediateDirectories: true
        )

        let largeText = String(repeating: "🧭", count: 8_000)
        let base = Date(timeIntervalSince1970: 100_000)
        let messages = (0..<150).map { offset in
            DeviceMessageStore.Message(
                direction: .incoming,
                text: largeText,
                timestamp: base.addingTimeInterval(Double(offset)),
                deliveryState: .delivered
            )
        }
        let legacyBytes = try JSONEncoder().encode([Self.fingerprint: messages])
        XCTAssertGreaterThan(legacyBytes.count, 4 * 1_024 * 1_024)
        try legacyBytes.write(to: historyURL, options: .atomic)

        let runtime = try UnifiedDeviceMessagingRuntime(
            defaultsSuiteName: fixture.suiteName,
            rootURLOverride: fixture.rootURL
        )
        let imported = try await runtime.bootstrap()
        XCTAssertEqual(imported.messages.count, messages.count)
        XCTAssertEqual(imported.messages.map(\.id), messages.map(\.id))
        XCTAssertTrue(imported.deliveryIntents.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: historyURL.path))

        let archives = try FileManager.default.contentsOfDirectory(
            at: historyDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("conversations.migrated-v1-") }
        let archiveURL = try XCTUnwrap(archives.onlyElement)
        XCTAssertEqual(try Data(contentsOf: archiveURL), legacyBytes)

        let reopenedRuntime = try UnifiedDeviceMessagingRuntime(
            defaultsSuiteName: fixture.suiteName,
            rootURLOverride: fixture.rootURL
        )
        let reopened = try await reopenedRuntime.bootstrap()
        XCTAssertEqual(reopened.messages, imported.messages)
        XCTAssertEqual(reopened.generation, imported.generation)
        XCTAssertEqual(try Data(contentsOf: archiveURL), legacyBytes)
    }

    func testUnifiedServiceStagesOnceAndRequiresExactAuthenticatedReceipt() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let runtime = try UnifiedDeviceMessagingRuntime(
            defaultsSuiteName: fixture.suiteName,
            rootURLOverride: fixture.rootURL
        )
        _ = try await runtime.bootstrap()

        // Custom UI facades have their own test repositories. Advance the
        // unified generation first so switching their projection authority is
        // deterministic after those repositories finish bootstrapping.
        let seed = PersistedMessageRecord(
            id: UUID(),
            conversationFingerprint: Self.fingerprint,
            targetDeviceID: nil,
            direction: .incoming,
            text: "projection-seed",
            timestamp: Date(timeIntervalSince1970: 1),
            deliveryState: .delivered
        )
        _ = try await runtime.recordIncoming(seed)
        _ = try await runtime.clearConversation(Self.fingerprint)

        let projections = try ProjectionFixture()
        defer { projections.remove() }
        try await waitUntil {
            projections.store.persistenceState == .ready
                && projections.queue.persistenceState == .ready
        }

        let probe = UnifiedTransportProbe()
        let targetDeviceID = "linux-peer-01"
        let service = DeviceMessagingService(
            store: projections.store,
            queue: projections.queue,
            transport: DeviceMessageTransport { deviceID, fingerprint, payload in
                probe.record(
                    deviceID: deviceID,
                    fingerprint: fingerprint,
                    payload: payload
                )
            },
            observesProductionConnections: false,
            usesUnifiedRepository: true,
            unifiedRuntime: runtime,
            initiallyOnlineDeviceIDs: [targetDeviceID]
        )
        try await service.prepare()
        service.start()
        try await service.send(
            text: "durable hello",
            toDeviceID: targetDeviceID,
            fingerprint: Self.fingerprint
        )

        try await waitUntil {
            guard probe.payload != nil else { return false }
            let snapshot = try? await runtime.currentSnapshot()
            return snapshot?.messages.first?.deliveryState == .sent
                && snapshot?.deliveryIntents.first?.state == .awaitingReceipt
        }
        let sentPayload = try XCTUnwrap(probe.payload)
        let attemptID = try XCTUnwrap(sentPayload.deliveryAttemptID)
        XCTAssertEqual(probe.sendCount, 1)
        XCTAssertEqual(probe.deviceID, targetDeviceID)
        XCTAssertEqual(probe.fingerprint, Self.fingerprint)

        do {
            try await service.handleAuthenticatedReceipt(
                AppMessage.TextMessageReceiptPayload(
                    messageID: sentPayload.id,
                    deliveryAttemptID: UUID()
                ),
                fingerprint: Self.fingerprint
            )
            XCTFail("A receipt from a different delivery owner must fail")
        } catch let error as DeviceMessagingError {
            XCTAssertEqual(error, .persistenceFailed)
        }

        try await service.handleAuthenticatedReceipt(
            AppMessage.TextMessageReceiptPayload(
                messageID: sentPayload.id,
                deliveryAttemptID: attemptID
            ),
            fingerprint: Self.fingerprint
        )
        let delivered = try await runtime.currentSnapshot()
        XCTAssertEqual(delivered.messages.first?.deliveryState, .delivered)
        XCTAssertTrue(delivered.deliveryIntents.isEmpty)
        XCTAssertEqual(
            try projections.store.messages(fingerprint: Self.fingerprint)
                .first?.deliveryState,
            .delivered
        )
        XCTAssertEqual(probe.sendCount, 1)
    }

    func testCoordinatedManualRetryUpdatesBothProjectionsAndWakesOnlineWorker() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let runtime = try UnifiedDeviceMessagingRuntime(
            defaultsSuiteName: fixture.suiteName,
            rootURLOverride: fixture.rootURL
        )
        _ = try await runtime.bootstrap()

        let targetDeviceID = "linux-peer-retry"
        let sentAt = Date()
        let payload = AppMessage.TextMessagePayload(
            id: UUID(),
            text: "retry me",
            sentAt: sentAt
        )
        let queueID = UUID().uuidString.lowercased()
        let envelope = try JSONEncoder().encode(DeviceTextQueueEnvelope(
            payload: payload,
            conversationFingerprint: Self.fingerprint
        ))
        let message = PersistedMessageRecord(
            id: payload.id,
            conversationFingerprint: Self.fingerprint,
            targetDeviceID: targetDeviceID,
            direction: .outgoing,
            text: payload.text,
            timestamp: sentAt,
            deliveryState: .pending
        )
        let intent = PersistedDeliveryIntent(
            queueID: queueID,
            messageID: payload.id,
            targetDeviceID: targetDeviceID,
            messageType: OfflineMessageType.text.rawValue,
            priority: MessagePriority.normal.rawValue,
            payload: envelope,
            createdAt: sentAt,
            expiresAt: sentAt.addingTimeInterval(86_400)
        )
        _ = try await runtime.stageOutgoing(message: message, intent: intent)
        let failedClaim = try await runtime.claim(
            messageID: message.id,
            ownerToken: UUID(),
            now: sentAt
        )
        _ = try await runtime.resolve(
            failedClaim,
            disposition: .permanentFailure(failureCode: "transport_failure"),
            retryPolicy: MessageDeliveryRetryPolicy(
                maximumRetryCount: 3,
                retryInterval: 1,
                backoffFactor: 2
            ),
            now: sentAt
        )

        let projections = try ProjectionFixture()
        defer { projections.remove() }
        try await waitUntil {
            projections.store.persistenceState == .ready
                && projections.queue.persistenceState == .ready
        }
        let probe = UnifiedTransportProbe()
        let service = DeviceMessagingService(
            store: projections.store,
            queue: projections.queue,
            transport: DeviceMessageTransport { deviceID, fingerprint, submitted in
                probe.record(
                    deviceID: deviceID,
                    fingerprint: fingerprint,
                    payload: submitted
                )
            },
            observesProductionConnections: false,
            usesUnifiedRepository: true,
            unifiedRuntime: runtime,
            initiallyOnlineDeviceIDs: [targetDeviceID]
        )
        try await service.prepare()
        XCTAssertEqual(
            try projections.store.messages(fingerprint: Self.fingerprint).first?.deliveryState,
            .failed
        )
        XCTAssertEqual(projections.queue.statistics.failedMessages, 1)

        try await service.retryFailedUnifiedQueuedDeliveries()
        try await waitUntil {
            guard probe.payload != nil else { return false }
            let snapshot = try? await runtime.currentSnapshot()
            return snapshot?.deliveryIntents.first?.state == .awaitingReceipt
                && projections.queue.statistics.sendingMessages == 1
        }
        XCTAssertEqual(probe.sendCount, 1)
        XCTAssertEqual(probe.deviceID, targetDeviceID)
        XCTAssertEqual(
            try projections.store.messages(fingerprint: Self.fingerprint).first?.deliveryState,
            .sent
        )
        XCTAssertEqual(projections.queue.statistics.failedMessages, 0)

        let submitted = try XCTUnwrap(probe.payload)
        try await service.handleAuthenticatedReceipt(
            AppMessage.TextMessageReceiptPayload(
                messageID: submitted.id,
                deliveryAttemptID: try XCTUnwrap(submitted.deliveryAttemptID)
            ),
            fingerprint: Self.fingerprint
        )
        XCTAssertEqual(
            try projections.store.messages(fingerprint: Self.fingerprint).first?.deliveryState,
            .delivered
        )
        XCTAssertEqual(projections.queue.statistics.totalMessages, 0)
    }

    func testQueueMutationTimesOutWhenTransportIgnoresCancellation() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let runtime = try UnifiedDeviceMessagingRuntime(
            defaultsSuiteName: fixture.suiteName,
            rootURLOverride: fixture.rootURL
        )
        _ = try await runtime.bootstrap()
        let projections = try ProjectionFixture()
        defer { projections.remove() }
        try await waitUntil {
            projections.store.persistenceState == .ready
                && projections.queue.persistenceState == .ready
        }

        let probe = NonCooperativeTransportProbe()
        let targetDeviceID = "linux-peer-noncancel"
        let service = DeviceMessagingService(
            store: projections.store,
            queue: projections.queue,
            transport: DeviceMessageTransport { _, _, _ in
                await probe.suspendUntilReleased()
            },
            observesProductionConnections: false,
            usesUnifiedRepository: true,
            unifiedRuntime: runtime,
            initiallyOnlineDeviceIDs: [targetDeviceID],
            unifiedWorkerQuiesceTimeout: .milliseconds(50)
        )
        try await service.prepare()
        try await service.send(
            text: "bounded quiesce",
            toDeviceID: targetDeviceID,
            fingerprint: Self.fingerprint
        )
        await probe.waitUntilSuspended()
        let ownedSnapshot = try await runtime.currentSnapshot()
        let queueID = try XCTUnwrap(ownedSnapshot.deliveryIntents.first?.queueID)

        let clock = ContinuousClock()
        let startedAt = clock.now
        do {
            try await service.cancelUnifiedQueuedDelivery(queueID: queueID)
            XCTFail("A non-cooperative transport must not be mutated underneath its owner")
        } catch let error as DeviceMessagingRepositoryError {
            XCTAssertEqual(
                error,
                .invalidRecord(reasonCode: "worker_quiesce_timeout")
            )
        }
        XCTAssertLessThan(startedAt.duration(to: clock.now), .seconds(1))
        let stillOwned = try await runtime.currentSnapshot()
        XCTAssertEqual(stillOwned.deliveryIntents.first?.state, .sending)

        await probe.release()
        try await waitUntil {
            guard let snapshot = try? await runtime.currentSnapshot() else { return false }
            return snapshot.deliveryIntents.first?.state == .awaitingReceipt
        }
    }

    func testOneWorkerUsesFreshOwnerForEveryDeliveryAttempt() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let runtime = try UnifiedDeviceMessagingRuntime(
            defaultsSuiteName: fixture.suiteName,
            rootURLOverride: fixture.rootURL
        )
        _ = try await runtime.bootstrap()
        let targetDeviceID = "linux-peer-attempt-rotation"
        let base = Date()
        let firstPayload = AppMessage.TextMessagePayload(
            id: UUID(),
            text: "retry-first",
            sentAt: base
        )
        let secondPayload = AppMessage.TextMessagePayload(
            id: UUID(),
            text: "delay-second",
            sentAt: base.addingTimeInterval(0.001)
        )
        for payload in [firstPayload, secondPayload] {
            let queuedPayload = try JSONEncoder().encode(DeviceTextQueueEnvelope(
                payload: payload,
                conversationFingerprint: Self.fingerprint
            ))
            _ = try await runtime.stageOutgoing(
                message: PersistedMessageRecord(
                    id: payload.id,
                    conversationFingerprint: Self.fingerprint,
                    targetDeviceID: targetDeviceID,
                    direction: .outgoing,
                    text: payload.text,
                    timestamp: payload.sentAt,
                    deliveryState: .pending
                ),
                intent: PersistedDeliveryIntent(
                    queueID: UUID().uuidString.lowercased(),
                    messageID: payload.id,
                    targetDeviceID: targetDeviceID,
                    messageType: OfflineMessageType.text.rawValue,
                    priority: MessagePriority.normal.rawValue,
                    payload: queuedPayload,
                    createdAt: payload.sentAt,
                    expiresAt: payload.sentAt.addingTimeInterval(3_600)
                )
            )
        }

        var configuration = OfflineQueueConfiguration.default
        configuration.retryInterval = 0.01
        let projections = try ProjectionFixture(configuration: configuration)
        defer { projections.remove() }
        try await waitUntil {
            projections.store.persistenceState == .ready
                && projections.queue.persistenceState == .ready
        }
        let probe = AttemptRotationTransportProbe(firstMessageID: firstPayload.id)
        let service = DeviceMessagingService(
            store: projections.store,
            queue: projections.queue,
            transport: DeviceMessageTransport { _, _, payload in
                try await probe.submit(payload)
            },
            observesProductionConnections: false,
            usesUnifiedRepository: true,
            unifiedRuntime: runtime,
            initiallyOnlineDeviceIDs: [targetDeviceID]
        )
        try await service.prepare()
        service.start()

        try await waitUntil {
            await probe.attempts(for: firstPayload.id).count == 2
        }
        let attemptIDs = await probe.attempts(for: firstPayload.id)
        XCTAssertEqual(attemptIDs.count, 2)
        XCTAssertNotEqual(attemptIDs[0], attemptIDs[1])

        do {
            try await service.handleAuthenticatedReceipt(
                AppMessage.TextMessageReceiptPayload(
                    messageID: firstPayload.id,
                    deliveryAttemptID: attemptIDs[0]
                ),
                fingerprint: Self.fingerprint
            )
            XCTFail("A receipt from the prior attempt must be stale")
        } catch let error as DeviceMessagingError {
            XCTAssertEqual(error, .persistenceFailed)
        }
        try await service.handleAuthenticatedReceipt(
            AppMessage.TextMessageReceiptPayload(
                messageID: firstPayload.id,
                deliveryAttemptID: attemptIDs[1]
            ),
            fingerprint: Self.fingerprint
        )
        let delivered = try await runtime.currentSnapshot().messages.first {
            $0.id == firstPayload.id
        }
        XCTAssertEqual(delivered?.deliveryState, .delivered)
    }

    func testConflictingFileAndUserDefaultsQueueAuthoritiesRemainUntouched() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let queueDirectory = fixture.rootURL
            .appendingPathComponent("OfflineQueue", isDirectory: true)
        let queueURL = queueDirectory.appendingPathComponent("queue.json")
        try FileManager.default.createDirectory(
            at: queueDirectory,
            withIntermediateDirectories: true
        )
        let fileBytes = try JSONEncoder().encode([makeLegacyQueue(text: "file")])
        let defaultsBytes = try JSONEncoder().encode([makeLegacyQueue(text: "defaults")])
        XCTAssertNotEqual(fileBytes, defaultsBytes)
        try fileBytes.write(to: queueURL, options: .atomic)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: fixture.suiteName))
        defaults.set(defaultsBytes, forKey: "com.skybridge.offline.queue")

        let runtime = try UnifiedDeviceMessagingRuntime(
            defaultsSuiteName: fixture.suiteName,
            rootURLOverride: fixture.rootURL
        )
        do {
            _ = try await runtime.bootstrap()
            XCTFail("Conflicting legacy authorities must block migration")
        } catch let error as DeviceMessagingRepositoryError {
            XCTAssertEqual(
                error,
                .legacySourceConflict("mac_offline_queue_dual_authority")
            )
        }
        XCTAssertEqual(try Data(contentsOf: queueURL), fileBytes)
        XCTAssertEqual(
            UserDefaults(suiteName: fixture.suiteName)?.data(
                forKey: "com.skybridge.offline.queue"
            ),
            defaultsBytes
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: queueDirectory
                    .deletingLastPathComponent()
                    .appendingPathComponent("Messaging/device-messaging.sqlite3").path
            )
        )
    }

    func testIdenticalDualQueueAuthoritiesMigrateOnceAndArchiveExactBytes() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let queueDirectory = fixture.rootURL
            .appendingPathComponent("OfflineQueue", isDirectory: true)
        let queueURL = queueDirectory.appendingPathComponent("queue.json")
        try FileManager.default.createDirectory(
            at: queueDirectory,
            withIntermediateDirectories: true
        )
        let queue = try makeLegacyQueue(text: "same-authority")
        let queueBytes = try JSONEncoder().encode([queue])
        try queueBytes.write(to: queueURL, options: .atomic)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: fixture.suiteName))
        defaults.set(queueBytes, forKey: "com.skybridge.offline.queue")

        let runtime = try UnifiedDeviceMessagingRuntime(
            defaultsSuiteName: fixture.suiteName,
            rootURLOverride: fixture.rootURL
        )
        let snapshot = try await runtime.bootstrap()
        XCTAssertEqual(snapshot.messages.count, 1)
        XCTAssertEqual(snapshot.deliveryIntents.count, 1)
        XCTAssertEqual(snapshot.deliveryIntents.first?.queueID, queue.id.uuidString.lowercased())
        XCTAssertFalse(FileManager.default.fileExists(atPath: queueURL.path))
        XCTAssertNil(
            UserDefaults(suiteName: fixture.suiteName)?.data(
                forKey: "com.skybridge.offline.queue"
            )
        )

        let archives = try FileManager.default.contentsOfDirectory(
            at: queueDirectory,
            includingPropertiesForKeys: nil
        )
        let fileArchive = try XCTUnwrap(
            archives.first {
                $0.lastPathComponent.hasPrefix("queue.migrated-v1-")
                    && $0.lastPathComponent != "queue.migrated-v1-user-defaults.json"
            }
        )
        let defaultsArchive = queueDirectory
            .appendingPathComponent("queue.migrated-v1-user-defaults.json")
        XCTAssertEqual(try Data(contentsOf: fileArchive), queueBytes)
        XCTAssertEqual(try Data(contentsOf: defaultsArchive), queueBytes)
    }

    func testConcurrentBootstrapWaitersShareArchiveFailureAndCanRetry() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let queueDirectory = fixture.rootURL
            .appendingPathComponent("OfflineQueue", isDirectory: true)
        let queueURL = queueDirectory.appendingPathComponent("queue.json")
        try FileManager.default.createDirectory(
            at: queueDirectory,
            withIntermediateDirectories: true
        )
        let queueBytes = try JSONEncoder().encode([makeLegacyQueue(text: "archive-fault")])
        try queueBytes.write(to: queueURL, options: .atomic)
        let digest = SHA256.hash(data: queueBytes)
            .map { String(format: "%02x", $0) }
            .joined()
        let archiveURL = queueDirectory.appendingPathComponent(
            "queue.migrated-v1-\(digest.prefix(16)).json"
        )
        try Data("conflicting archive".utf8).write(to: archiveURL, options: .atomic)

        let runtime = try UnifiedDeviceMessagingRuntime(
            defaultsSuiteName: fixture.suiteName,
            rootURLOverride: fixture.rootURL
        )
        let gate = BootstrapStartGate(requiredArrivals: 3)
        let waiters = (0..<3).map { _ in
            Task {
                await gate.arriveAndWait()
                return try await runtime.bootstrap()
            }
        }
        for waiter in waiters {
            do {
                _ = try await waiter.value
                XCTFail("Every waiter must observe the shared archive failure")
            } catch let error as DeviceMessagingRepositoryError {
                XCTAssertEqual(error, .legacySourceConflict(queueURL.lastPathComponent))
            }
        }
        XCTAssertEqual(try Data(contentsOf: queueURL), queueBytes)

        try FileManager.default.removeItem(at: archiveURL)
        let recovered = try await runtime.bootstrap()
        XCTAssertEqual(recovered.messages.count, 1)
        XCTAssertEqual(recovered.deliveryIntents.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: queueURL.path))
        XCTAssertEqual(try Data(contentsOf: archiveURL), queueBytes)
    }

    func testHistoryAndQueueStateConflictBlocksMigrationWithoutChangingSources() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let historyDirectory = fixture.rootURL.appendingPathComponent(
            "Messaging",
            isDirectory: true
        )
        let queueDirectory = fixture.rootURL.appendingPathComponent(
            "OfflineQueue",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: historyDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: queueDirectory,
            withIntermediateDirectories: true
        )
        let queued = try makeLegacyQueue(text: "must-not-repeat")
        let envelope = try JSONDecoder().decode(DeviceTextQueueEnvelope.self, from: queued.payload)
        let history = DeviceMessageStore.Message(
            id: envelope.payload.id,
            direction: .outgoing,
            text: envelope.payload.text,
            timestamp: envelope.payload.sentAt,
            deliveryState: .delivered,
            targetDeviceID: queued.targetDeviceID
        )
        let historyBytes = try JSONEncoder().encode([Self.fingerprint: [history]])
        let queueBytes = try JSONEncoder().encode([queued])
        let historyURL = historyDirectory.appendingPathComponent("conversations.json")
        let queueURL = queueDirectory.appendingPathComponent("queue.json")
        try historyBytes.write(to: historyURL, options: .atomic)
        try queueBytes.write(to: queueURL, options: .atomic)

        let runtime = try UnifiedDeviceMessagingRuntime(
            defaultsSuiteName: fixture.suiteName,
            rootURLOverride: fixture.rootURL
        )
        do {
            _ = try await runtime.bootstrap()
            XCTFail("Delivered history must not be reactivated by a pending queue entry")
        } catch let error as DeviceMessagingRepositoryError {
            XCTAssertEqual(
                error,
                .legacySourceConflict(queued.id.uuidString.lowercased())
            )
        }
        XCTAssertEqual(try Data(contentsOf: historyURL), historyBytes)
        XCTAssertEqual(try Data(contentsOf: queueURL), queueBytes)
    }

    func testReceiptWireRoundTripAndLegacyTextPayloadWithoutAttemptID() throws {
        let legacyPayload = AppMessage.TextMessagePayload(
            id: UUID(),
            text: "legacy",
            sentAt: Date(timeIntervalSince1970: 50)
        )
        let legacyBytes = try JSONEncoder().encode(legacyPayload)
        XCTAssertNil(
            try JSONDecoder().decode(
                AppMessage.TextMessagePayload.self,
                from: legacyBytes
            ).deliveryAttemptID
        )

        let receipt = AppMessage.textMessageReceipt(
            AppMessage.TextMessageReceiptPayload(
                messageID: UUID(),
                deliveryAttemptID: UUID(),
                receivedAt: Date(timeIntervalSince1970: 51)
            )
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                AppMessage.self,
                from: JSONEncoder().encode(receipt)
            ),
            receipt
        )
    }

    private func makeLegacyQueue(text: String) throws -> QueuedMessage {
        let messageID = UUID()
        let sentAt = Date(timeIntervalSince1970: 70_000)
        let payload = AppMessage.TextMessagePayload(
            id: messageID,
            text: text,
            sentAt: sentAt
        )
        let envelope = try JSONEncoder().encode(DeviceTextQueueEnvelope(
            payload: payload,
            conversationFingerprint: Self.fingerprint
        ))
        return QueuedMessage(
            id: UUID(),
            targetDeviceID: "linux-peer-01",
            messageType: .text,
            priority: .normal,
            payload: envelope,
            createdAt: sentAt,
            expiresAt: sentAt.addingTimeInterval(86_400),
            status: .pending,
            retryCount: 0,
            lastAttemptAt: nil,
            lastFailureCode: nil
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        condition: @MainActor () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for unified messaging state")
    }
}

@MainActor
private final class UnifiedTransportProbe {
    private(set) var sendCount = 0
    private(set) var deviceID: String?
    private(set) var fingerprint: String?
    private(set) var payload: AppMessage.TextMessagePayload?

    func record(
        deviceID: String,
        fingerprint: String,
        payload: AppMessage.TextMessagePayload
    ) {
        sendCount += 1
        self.deviceID = deviceID
        self.fingerprint = fingerprint
        self.payload = payload
    }
}

@MainActor
private struct ProjectionFixture {
    let suiteName: String
    let defaults: UserDefaults
    let store: DeviceMessageStore
    let queue: OfflineMessageQueue

    init(configuration: OfflineQueueConfiguration = .default) throws {
        suiteName = "UnifiedDeviceMessagingProjection.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw FixtureError.unavailableUserDefaults
        }
        self.defaults = defaults
        let historyStore = CodablePersistenceStore<[String: [DeviceMessageStore.Message]]>(
            location: .userDefaults(key: "history"),
            defaults: defaults
        )
        let queueStore = CodablePersistenceStore<[QueuedMessage]>(
            location: .userDefaults(key: "queue"),
            defaults: defaults
        )
        let configurationStore = CodablePersistenceStore<OfflineQueueConfiguration>(
            location: .userDefaults(key: "configuration"),
            defaults: defaults
        )
        try configurationStore.save(configuration)
        store = DeviceMessageStore(store: historyStore)
        queue = OfflineMessageQueue(
            queueStore: queueStore,
            configurationStore: configurationStore,
            automaticallyStartsProcessing: false
        )
    }

    func remove() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

private struct RuntimeFixture {
    let rootURL: URL
    let suiteName: String

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("skybridge-unified-runtime-\(UUID().uuidString)")
        suiteName = "UnifiedDeviceMessagingRuntime.\(UUID().uuidString)"
        guard UserDefaults(suiteName: suiteName) != nil else {
            throw FixtureError.unavailableUserDefaults
        }
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
    }

    func remove() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private enum FixtureError: Error {
    case unavailableUserDefaults
}

private actor BootstrapStartGate {
    private let requiredArrivals: Int
    private var arrivals = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []

    init(requiredArrivals: Int) {
        self.requiredArrivals = requiredArrivals
    }

    func arriveAndWait() async {
        arrivals += 1
        if arrivals == requiredArrivals {
            let waiting = continuations
            continuations.removeAll()
            for continuation in waiting {
                continuation.resume()
            }
            return
        }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }
}

private actor NonCooperativeTransportProbe {
    private var isSuspended = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []

    func suspendUntilReleased() async {
        isSuspended = true
        let waiters = suspensionWaiters
        suspensionWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilSuspended() async {
        guard !isSuspended else { return }
        await withCheckedContinuation { continuation in
            suspensionWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor AttemptRotationTransportProbe {
    private let firstMessageID: UUID
    private var attemptsByMessageID: [UUID: [UUID]] = [:]
    private var submissionCount = 0

    init(firstMessageID: UUID) {
        self.firstMessageID = firstMessageID
    }

    func submit(_ payload: AppMessage.TextMessagePayload) async throws {
        let attemptID = try XCTUnwrap(payload.deliveryAttemptID)
        attemptsByMessageID[payload.id, default: []].append(attemptID)
        submissionCount += 1
        if submissionCount == 1 {
            XCTAssertEqual(payload.id, firstMessageID)
            throw DeviceMessagingError.transportUnavailable
        }
        if submissionCount == 2 {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func attempts(for messageID: UUID) -> [UUID] {
        attemptsByMessageID[messageID] ?? []
    }
}

private extension Array {
    var onlyElement: Element? {
        count == 1 ? self[0] : nil
    }
}
