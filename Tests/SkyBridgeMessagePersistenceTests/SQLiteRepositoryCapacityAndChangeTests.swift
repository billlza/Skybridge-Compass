import Foundation
import XCTest

@testable import SkyBridgeMessagePersistence

/// Contract tests for the per-mutation change protocol and the global
/// capacity bounds. Every mutation must name the exact rows it touched, pair
/// them with the generation span it committed, and keep the store inside the
/// documented global bounds without ever dropping active state.
final class SQLiteRepositoryCapacityAndChangeTests: XCTestCase {
    // MARK: - Change contract

    func testStageOutgoingChangeCarriesExactRowsAndGenerationSpan() async throws {
        let fixture = try RepositoryTestFixture()
        defer { fixture.remove() }
        let repository = SQLiteDeviceMessagingRepository(databaseURL: fixture.databaseURL)
        let bootstrapped = try await repository.bootstrap()

        let pair = Self.makeOutgoing()
        let change = try await repository.stageOutgoing(
            message: pair.message,
            intent: pair.intent
        )

        XCTAssertEqual(change.upsertedMessages, [pair.message])
        XCTAssertEqual(change.upsertedDeliveryIntents, [pair.intent])
        XCTAssertTrue(change.removedMessages.isEmpty)
        XCTAssertTrue(change.removedDeliveryIntentQueueIDs.isEmpty)
        XCTAssertEqual(change.basisGeneration, bootstrapped.generation)
        XCTAssertGreaterThan(change.generation, change.basisGeneration)

        let snapshot = try await repository.currentSnapshot()
        XCTAssertEqual(snapshot.messages, [pair.message])
        XCTAssertEqual(snapshot.deliveryIntents, [pair.intent])
        XCTAssertEqual(snapshot.generation, change.generation)
    }

    func testDuplicateIncomingRecordYieldsEmptyChange() async throws {
        let fixture = try RepositoryTestFixture()
        defer { fixture.remove() }
        let repository = SQLiteDeviceMessagingRepository(databaseURL: fixture.databaseURL)
        _ = try await repository.bootstrap()

        let incoming = Self.makeIncoming(fingerprint: String(repeating: "a", count: 64))
        let first = try await repository.recordIncoming(incoming)
        XCTAssertEqual(first.upsertedMessages, [incoming])

        let duplicate = try await repository.recordIncoming(incoming)
        XCTAssertTrue(duplicate.isEmpty)
        XCTAssertEqual(duplicate.basisGeneration, first.generation)
        XCTAssertEqual(duplicate.generation, first.generation)

        let snapshot = try await repository.currentSnapshot()
        XCTAssertEqual(snapshot.messages, [incoming])
        XCTAssertEqual(snapshot.generation, first.generation)
    }

    func testDeliveryLifecycleChangesNameEveryTouchedRow() async throws {
        let fixture = try RepositoryTestFixture()
        defer { fixture.remove() }
        let repository = SQLiteDeviceMessagingRepository(databaseURL: fixture.databaseURL)
        _ = try await repository.bootstrap()
        let pair = Self.makeOutgoing()
        let staged = try await repository.stageOutgoing(
            message: pair.message,
            intent: pair.intent
        )

        let claimOutcome = try await repository.claim(
            messageID: pair.message.id,
            ownerToken: UUID(),
            now: pair.intent.createdAt.addingTimeInterval(1)
        )
        XCTAssertEqual(claimOutcome.change.basisGeneration, staged.generation)
        XCTAssertEqual(
            claimOutcome.change.upsertedDeliveryIntents.map(\.queueID),
            [pair.intent.queueID]
        )
        XCTAssertEqual(claimOutcome.change.upsertedDeliveryIntents.first?.state, .sending)
        XCTAssertTrue(claimOutcome.change.upsertedMessages.isEmpty)

        let receiptDeadline = pair.intent.createdAt.addingTimeInterval(30)
        let submitted = try await repository.resolve(
            claimOutcome.claim,
            disposition: .submitted(receiptDeadline: receiptDeadline),
            retryPolicy: Self.retryPolicy,
            now: pair.intent.createdAt.addingTimeInterval(2)
        )
        XCTAssertEqual(submitted.basisGeneration, claimOutcome.change.generation)
        XCTAssertEqual(submitted.upsertedDeliveryIntents.first?.state, .awaitingReceipt)
        XCTAssertEqual(submitted.upsertedMessages.first?.deliveryState, .sent)

        let delivered = try await repository.confirmAuthenticatedReceipt(
            AuthenticatedMessageReceipt(
                messageID: pair.message.id,
                deliveryAttemptID: claimOutcome.claim.ownerToken,
                conversationFingerprint: pair.message.conversationFingerprint,
                receivedAt: pair.intent.createdAt.addingTimeInterval(3)
            )
        )
        XCTAssertEqual(delivered.basisGeneration, submitted.generation)
        XCTAssertEqual(delivered.upsertedMessages.first?.deliveryState, .delivered)
        XCTAssertEqual(delivered.removedDeliveryIntentQueueIDs, [pair.intent.queueID])

        let snapshot = try await repository.currentSnapshot()
        XCTAssertEqual(snapshot.messages.first?.deliveryState, .delivered)
        XCTAssertTrue(snapshot.deliveryIntents.isEmpty)
        XCTAssertEqual(snapshot.generation, delivered.generation)
    }

    func testConversationEvictionIsReportedAsRemoval() async throws {
        let fixture = try RepositoryTestFixture()
        defer { fixture.remove() }
        let repository = SQLiteDeviceMessagingRepository(databaseURL: fixture.databaseURL)
        _ = try await repository.bootstrap()
        let fingerprint = String(repeating: "d", count: 64)

        var oldestID: UUID?
        for index in 0..<500 {
            let message = Self.makeIncoming(
                fingerprint: fingerprint,
                timestamp: Date(timeIntervalSince1970: 1_000 + Double(index))
            )
            if index == 0 { oldestID = message.id }
            _ = try await repository.recordIncoming(message)
        }

        let overflow = Self.makeIncoming(
            fingerprint: fingerprint,
            timestamp: Date(timeIntervalSince1970: 2_000)
        )
        let change = try await repository.recordIncoming(overflow)
        XCTAssertEqual(
            change.removedMessages,
            [MessageRepositoryMessageRemoval(
                id: try XCTUnwrap(oldestID),
                conversationFingerprint: fingerprint
            )]
        )
        XCTAssertEqual(change.upsertedMessages, [overflow])

        let snapshot = try await repository.currentSnapshot()
        XCTAssertEqual(snapshot.messages.count, 500)
        XCTAssertFalse(snapshot.messages.contains { $0.id == oldestID })
    }

    // MARK: - Global bounds

    func testGlobalConversationBoundEvictsLeastRecentlyActiveTerminalConversation() async throws {
        let fixture = try RepositoryTestFixture()
        defer { fixture.remove() }
        let repository = SQLiteDeviceMessagingRepository(databaseURL: fixture.databaseURL)
        _ = try await repository.bootstrap()

        var firstConversationMessageID: UUID?
        for index in 0..<SQLiteDeviceMessagingRepository.maximumConversations {
            let message = Self.makeIncoming(
                fingerprint: Self.fingerprint(index: index),
                timestamp: Date(timeIntervalSince1970: 1_000 + Double(index))
            )
            if index == 0 { firstConversationMessageID = message.id }
            _ = try await repository.recordIncoming(message)
        }

        let overflow = Self.makeIncoming(
            fingerprint: Self.fingerprint(
                index: SQLiteDeviceMessagingRepository.maximumConversations
            ),
            timestamp: Date(timeIntervalSince1970: 10_000)
        )
        let change = try await repository.recordIncoming(overflow)
        XCTAssertEqual(
            change.removedMessages,
            [MessageRepositoryMessageRemoval(
                id: try XCTUnwrap(firstConversationMessageID),
                conversationFingerprint: Self.fingerprint(index: 0)
            )]
        )

        let snapshot = try await repository.currentSnapshot()
        let conversationCount = Set(snapshot.messages.map(\.conversationFingerprint)).count
        XCTAssertEqual(
            conversationCount,
            SQLiteDeviceMessagingRepository.maximumConversations
        )
        XCTAssertFalse(snapshot.messages.contains {
            $0.conversationFingerprint == Self.fingerprint(index: 0)
        })
    }

    func testGlobalConversationBoundFailsClosedWhenNothingIsEvictable() async throws {
        let fixture = try RepositoryTestFixture()
        defer { fixture.remove() }
        let repository = SQLiteDeviceMessagingRepository(databaseURL: fixture.databaseURL)
        _ = try await repository.bootstrap()

        // Every conversation keeps an active pending intent, so none of them
        // is evictable and the bound must reject new conversations loudly.
        for index in 0..<SQLiteDeviceMessagingRepository.maximumConversations {
            let pair = Self.makeOutgoing(
                fingerprint: Self.fingerprint(index: index),
                targetDeviceID: String(format: "device-target-%04d", index),
                createdAt: Date(timeIntervalSince1970: 1_000 + Double(index))
            )
            _ = try await repository.stageOutgoing(
                message: pair.message,
                intent: pair.intent
            )
        }

        do {
            _ = try await repository.recordIncoming(Self.makeIncoming(
                fingerprint: Self.fingerprint(
                    index: SQLiteDeviceMessagingRepository.maximumConversations
                )
            ))
            XCTFail("An unmeetable conversation bound must fail closed")
        } catch let error as DeviceMessagingRepositoryError {
            XCTAssertEqual(
                error,
                .invalidRecord(reasonCode: "global_conversation_capacity_exceeded")
            )
        }

        let snapshot = try await repository.currentSnapshot()
        XCTAssertEqual(
            Set(snapshot.messages.map(\.conversationFingerprint)).count,
            SQLiteDeviceMessagingRepository.maximumConversations
        )
    }

    func testFailedIntentBoundDropsOldestFailedIntentAndKeepsFailedHistory() async throws {
        let fixture = try RepositoryTestFixture()
        defer { fixture.remove() }
        let repository = SQLiteDeviceMessagingRepository(databaseURL: fixture.databaseURL)
        _ = try await repository.bootstrap()

        var failedQueueIDsInOrder: [String] = []
        let total = SQLiteDeviceMessagingRepository.maximumFailedDeliveryIntents + 1
        for index in 0..<total {
            let createdAt = Date(timeIntervalSince1970: 1_000 + Double(index))
            let pair = Self.makeOutgoing(
                fingerprint: Self.fingerprint(index: index % 8),
                targetDeviceID: "device-target-0001",
                createdAt: createdAt
            )
            _ = try await repository.stageOutgoing(
                message: pair.message,
                intent: pair.intent
            )
            let outcome = try await repository.claim(
                messageID: pair.message.id,
                ownerToken: UUID(),
                now: createdAt.addingTimeInterval(0.1)
            )
            let failed = try await repository.resolve(
                outcome.claim,
                disposition: .permanentFailure(failureCode: "probe_failure"),
                retryPolicy: Self.retryPolicy,
                now: createdAt.addingTimeInterval(0.2)
            )
            failedQueueIDsInOrder.append(pair.intent.queueID)
            if index == total - 1 {
                XCTAssertEqual(
                    failed.removedDeliveryIntentQueueIDs,
                    [failedQueueIDsInOrder[0]],
                    "The oldest failed intent must be compacted away"
                )
            }
        }

        let snapshot = try await repository.currentSnapshot()
        let failedIntents = snapshot.deliveryIntents.filter { $0.state == .failed }
        XCTAssertEqual(
            failedIntents.count,
            SQLiteDeviceMessagingRepository.maximumFailedDeliveryIntents
        )
        XCTAssertFalse(failedIntents.contains { $0.queueID == failedQueueIDsInOrder[0] })
        // The compacted intent's message stays visible as failed history.
        XCTAssertEqual(
            snapshot.messages.filter { $0.deliveryState == .failed }.count,
            total
        )
    }

    func testLegacyMigrationCompactsOverCapacityStoreAndRecordsEvidence() async throws {
        let fixture = try RepositoryTestFixture()
        defer { fixture.remove() }
        let repository = SQLiteDeviceMessagingRepository(databaseURL: fixture.databaseURL)

        let conversationTotal = SQLiteDeviceMessagingRepository.maximumConversations + 3
        var messages: [PersistedMessageRecord] = []
        for index in 0..<conversationTotal {
            messages.append(Self.makeIncoming(
                fingerprint: Self.fingerprint(index: index),
                timestamp: Date(timeIntervalSince1970: 1_000 + Double(index))
            ))
        }

        let failedTotal = SQLiteDeviceMessagingRepository.maximumFailedDeliveryIntents + 5
        var failedIntents: [PersistedDeliveryIntent] = []
        for index in 0..<failedTotal {
            let createdAt = Date(timeIntervalSince1970: 500 + Double(index))
            let id = UUID()
            messages.append(PersistedMessageRecord(
                id: id,
                conversationFingerprint: Self.fingerprint(index: index % 4),
                targetDeviceID: "device-target-0001",
                direction: .outgoing,
                text: "failed history",
                timestamp: createdAt,
                deliveryState: .failed
            ))
            failedIntents.append(PersistedDeliveryIntent(
                queueID: id.uuidString.lowercased(),
                messageID: id,
                targetDeviceID: "device-target-0001",
                messageType: "text",
                priority: 1,
                payload: Data("payload".utf8),
                createdAt: createdAt,
                expiresAt: nil,
                state: .failed,
                retryCount: 3,
                lastAttemptAt: createdAt,
                failureCode: "legacy_failure"
            ))
        }

        let migration = LegacyMessageMigration(
            sources: [LegacyMessageSource(
                sourceID: "legacy-history",
                contentDigest: String(repeating: "0", count: 64)
            )],
            messages: messages,
            deliveryIntents: failedIntents
        )
        let snapshot = try await repository.bootstrap(legacyMigration: migration)

        XCTAssertLessThanOrEqual(
            Set(snapshot.messages.map(\.conversationFingerprint)).count,
            SQLiteDeviceMessagingRepository.maximumConversations
        )
        let failedRemaining = snapshot.deliveryIntents.filter { $0.state == .failed }
        XCTAssertEqual(
            failedRemaining.count,
            SQLiteDeviceMessagingRepository.maximumFailedDeliveryIntents
        )
        // Newest failed intents survive; the oldest are compacted.
        let survivingCreation = Set(failedRemaining.map(\.createdAt))
        let expectedSurvivors = failedIntents
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(SQLiteDeviceMessagingRepository.maximumFailedDeliveryIntents)
        XCTAssertEqual(survivingCreation, Set(expectedSurvivors.map(\.createdAt)))

        let compactionIssues = snapshot.migrationIssues.filter {
            $0.sourceID == SQLiteDeviceMessagingRepository.compactionIssueSourceID
        }
        XCTAssertTrue(compactionIssues.contains {
            $0.reasonCode == "legacy_failed_intents_compacted"
        })
        XCTAssertTrue(compactionIssues.contains {
            $0.reasonCode == "legacy_conversations_compacted"
        })
    }

    func testLegacyMigrationImportsOversizedConversationTrimmingTerminalHistory() async throws {
        let fixture = try RepositoryTestFixture()
        defer { fixture.remove() }
        let repository = SQLiteDeviceMessagingRepository(databaseURL: fixture.databaseURL)

        let fingerprint = Self.fingerprint(index: 1)
        let overflowCount = SQLiteDeviceMessagingRepository.maximumMessagesPerConversation + 5
        var messages: [PersistedMessageRecord] = []
        for index in 0..<overflowCount {
            messages.append(Self.makeIncoming(
                fingerprint: fingerprint,
                timestamp: Date(timeIntervalSince1970: 1_000 + Double(index))
            ))
        }

        let snapshot = try await repository.bootstrap(legacyMigration: LegacyMessageMigration(
            sources: [LegacyMessageSource(
                sourceID: "legacy-oversized-conversation",
                contentDigest: String(repeating: "1", count: 64)
            )],
            messages: messages,
            deliveryIntents: []
        ))

        let survivors = snapshot.messages.filter {
            $0.conversationFingerprint == fingerprint
        }
        XCTAssertEqual(
            survivors.count,
            SQLiteDeviceMessagingRepository.maximumMessagesPerConversation
        )
        // The newest rows survive; the oldest five were evicted.
        XCTAssertEqual(
            Set(survivors.map(\.timestamp)),
            Set(messages.suffix(
                SQLiteDeviceMessagingRepository.maximumMessagesPerConversation
            ).map(\.timestamp))
        )
        XCTAssertTrue(snapshot.migrationIssues.contains {
            $0.sourceID == SQLiteDeviceMessagingRepository.compactionIssueSourceID
                && $0.reasonCode == "legacy_conversation_messages_compacted"
        })
        XCTAssertEqual(
            try rawSQLiteText(
                at: fixture.databaseURL,
                sql: """
                SELECT value FROM schema_metadata
                 WHERE key = 'legacy_conversation_messages_compacted_count'
                """
            ),
            "5"
        )
    }

    func testLegacyMigrationKeepsActiveIntentBacklogAndGatesLaterAdmissions() async throws {
        let fixture = try RepositoryTestFixture()
        defer { fixture.remove() }
        let repository = SQLiteDeviceMessagingRepository(databaseURL: fixture.databaseURL)

        let device = "device-target-0001"
        let backlog = SQLiteDeviceMessagingRepository.maximumActiveDeliveryIntentsPerDevice + 5
        var messages: [PersistedMessageRecord] = []
        var intents: [PersistedDeliveryIntent] = []
        for index in 0..<backlog {
            let id = UUID()
            let createdAt = Date(timeIntervalSince1970: 1_000 + Double(index))
            messages.append(PersistedMessageRecord(
                id: id,
                conversationFingerprint: Self.fingerprint(index: index % 4),
                targetDeviceID: device,
                direction: .outgoing,
                text: "undelivered backlog",
                timestamp: createdAt,
                deliveryState: .pending
            ))
            intents.append(PersistedDeliveryIntent(
                queueID: id.uuidString.lowercased(),
                messageID: id,
                targetDeviceID: device,
                messageType: "text",
                priority: 1,
                payload: Data("payload".utf8),
                createdAt: createdAt,
                expiresAt: nil
            ))
        }

        let snapshot = try await repository.bootstrap(legacyMigration: LegacyMessageMigration(
            sources: [LegacyMessageSource(
                sourceID: "legacy-active-backlog",
                contentDigest: String(repeating: "2", count: 64)
            )],
            messages: messages,
            deliveryIntents: intents
        ))

        // Undelivered user messages are never dropped, even over the
        // admission bound, and the overage is recorded as evidence.
        XCTAssertEqual(
            snapshot.deliveryIntents.filter { $0.state == .pending }.count,
            backlog
        )
        XCTAssertTrue(snapshot.migrationIssues.contains {
            $0.sourceID == SQLiteDeviceMessagingRepository.compactionIssueSourceID
                && $0.reasonCode == "legacy_device_active_intents_over_capacity"
        })
        XCTAssertEqual(
            try rawSQLiteText(
                at: fixture.databaseURL,
                sql: """
                SELECT value FROM schema_metadata
                 WHERE key = 'legacy_device_active_intents_over_capacity_count'
                """
            ),
            "5"
        )

        // The strict admission bound gates the first post-import send until
        // the imported backlog drains.
        let pair = Self.makeOutgoing(
            fingerprint: Self.fingerprint(index: 9),
            targetDeviceID: device,
            createdAt: Date(timeIntervalSince1970: 3_000)
        )
        do {
            _ = try await repository.stageOutgoing(
                message: pair.message,
                intent: pair.intent
            )
            XCTFail("Admission over an already saturated device must fail closed")
        } catch let error as DeviceMessagingRepositoryError {
            XCTAssertEqual(
                error,
                .invalidRecord(reasonCode: "delivery_intent_capacity_exceeded")
            )
        }
    }

    func testMigrationReaderImportsPayloadBeyondSixtyFourMiBWithoutRewritingIt() throws {
        let fixture = try RepositoryTestFixture()
        defer { fixture.remove() }
        let legacyURL = fixture.rootURL.appendingPathComponent("conversations.json")
        let value = [String(repeating: "y", count: 65 * 1_024 * 1_024)]
        let data = try JSONEncoder().encode(value)
        XCTAssertGreaterThan(data.count, 64 * 1_024 * 1_024)
        try data.write(to: legacyURL, options: .atomic)

        let decoded: [String]? = try LegacyJSONMigrationReader.decode(
            from: legacyURL,
            containedIn: fixture.rootURL
        )
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(try Data(contentsOf: legacyURL), data)
    }

    func testBootstrapEnablesIncrementalAutoVacuum() async throws {
        let fixture = try RepositoryTestFixture()
        defer { fixture.remove() }
        let repository = SQLiteDeviceMessagingRepository(databaseURL: fixture.databaseURL)
        _ = try await repository.bootstrap()
        _ = try await repository.recordIncoming(Self.makeIncoming(
            fingerprint: String(repeating: "e", count: 64)
        ))

        let mode = try rawSQLiteScalar(
            at: fixture.databaseURL,
            sql: "PRAGMA auto_vacuum"
        )
        XCTAssertEqual(mode, 2, "The store must run with incremental auto-vacuum")
    }

    // MARK: - Fixtures

    private static let retryPolicy = MessageDeliveryRetryPolicy(
        maximumRetryCount: 3,
        retryInterval: 1,
        backoffFactor: 2
    )

    private static func fingerprint(index: Int) -> String {
        let suffix = String(format: "%08x", index)
        return String(repeating: "f", count: 64 - suffix.count) + suffix
    }

    private static func makeIncoming(
        fingerprint: String,
        timestamp: Date = Date(timeIntervalSince1970: 1_000)
    ) -> PersistedMessageRecord {
        PersistedMessageRecord(
            id: UUID(),
            conversationFingerprint: fingerprint,
            targetDeviceID: nil,
            direction: .incoming,
            text: "hello",
            timestamp: timestamp,
            deliveryState: .delivered
        )
    }

    private static func makeOutgoing(
        fingerprint: String = String(repeating: "b", count: 64),
        targetDeviceID: String = "device-target-0001",
        createdAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> (message: PersistedMessageRecord, intent: PersistedDeliveryIntent) {
        let id = UUID()
        let message = PersistedMessageRecord(
            id: id,
            conversationFingerprint: fingerprint,
            targetDeviceID: targetDeviceID,
            direction: .outgoing,
            text: "hello",
            timestamp: createdAt,
            deliveryState: .pending
        )
        let intent = PersistedDeliveryIntent(
            queueID: id.uuidString.lowercased(),
            messageID: id,
            targetDeviceID: targetDeviceID,
            messageType: "text",
            priority: 1,
            payload: Data("payload".utf8),
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(3_600)
        )
        return (message, intent)
    }

}
