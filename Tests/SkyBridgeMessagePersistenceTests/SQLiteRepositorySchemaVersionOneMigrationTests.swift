import Foundation
import XCTest

@testable import SkyBridgeMessagePersistence

/// Migration tests that bootstrap against a database file physically written
/// in the schema-v1 layout (no `claim_process_id` / `claim_instance_id`
/// columns), exactly as a v1 build of the app would have left it on disk.
final class SQLiteRepositorySchemaVersionOneMigrationTests: XCTestCase {
    private static let zeroUUID = "00000000-0000-0000-0000-000000000000"

    func testBootstrapMigratesVersionOneDatabasePreservingEveryRow() async throws {
        let fixture = try RepositoryTestFixture()
        defer { fixture.remove() }
        let rows = try Self.writeVersionOneDatabase(at: fixture.databaseURL)

        let repository = SQLiteDeviceMessagingRepository(databaseURL: fixture.databaseURL)
        let snapshot = try await repository.bootstrap()

        XCTAssertEqual(
            try rawSQLiteText(
                at: fixture.databaseURL,
                sql: "SELECT value FROM schema_metadata WHERE key = 'schema_version'"
            ),
            "2"
        )

        // Every v1 row survives the migration.
        XCTAssertEqual(
            Set(snapshot.messages.map(\.id)),
            Set(rows.allMessageIDs)
        )
        XCTAssertEqual(
            Set(snapshot.deliveryIntents.map(\.queueID)),
            Set(rows.allQueueIDs)
        )

        // The v1 claim that was mid-flight when the old process died is
        // recovered: back to pending with the claim identity cleared.
        let recovered = try XCTUnwrap(snapshot.deliveryIntents.first {
            $0.queueID == rows.sendingQueueID
        })
        XCTAssertEqual(recovered.state, .pending)
        XCTAssertNil(recovered.receiptDeadline)
        XCTAssertEqual(
            try rawSQLiteScalar(
                at: fixture.databaseURL,
                sql: """
                SELECT COUNT(*) FROM delivery_intents
                 WHERE queue_id = '\(rows.sendingQueueID)'
                   AND claim_owner IS NULL
                   AND claim_process_id IS NULL
                   AND claim_instance_id IS NULL
                """
            ),
            1
        )

        // The awaiting-receipt claim stays awaiting its receipt deadline but
        // is stamped with the sentinel identity of the dead v1 process, so a
        // later receipt timeout (not a false interruption) settles it.
        let awaiting = try XCTUnwrap(snapshot.deliveryIntents.first {
            $0.queueID == rows.awaitingReceiptQueueID
        })
        XCTAssertEqual(awaiting.state, .awaitingReceipt)
        XCTAssertNotNil(awaiting.receiptDeadline)
        XCTAssertEqual(
            try rawSQLiteText(
                at: fixture.databaseURL,
                sql: """
                SELECT claim_process_id FROM delivery_intents
                 WHERE queue_id = '\(rows.awaitingReceiptQueueID)'
                """
            ),
            Self.zeroUUID
        )

        // Terminal rows are untouched.
        let failed = try XCTUnwrap(snapshot.deliveryIntents.first {
            $0.queueID == rows.failedQueueID
        })
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.failureCode, "legacy_failure")
        let delivered = try XCTUnwrap(snapshot.messages.first {
            $0.id == rows.deliveredMessageID
        })
        XCTAssertEqual(delivered.deliveryState, .delivered)

        // The recovery of the interrupted claim advanced the persisted
        // generation exactly once past the v1 value.
        XCTAssertEqual(snapshot.generation, rows.generation + 1)

        // A v1 database predates incremental auto-vacuum; bootstrap must have
        // converted it.
        XCTAssertEqual(
            try rawSQLiteScalar(at: fixture.databaseURL, sql: "PRAGMA auto_vacuum"),
            2
        )

        // The migrated store is immediately writable: the recovered intent
        // can be claimed again by the new process.
        let outcome = try await repository.claim(
            messageID: recovered.messageID,
            ownerToken: UUID(),
            now: Date(timeIntervalSince1970: 2_000)
        )
        XCTAssertEqual(outcome.claim.intent.queueID, rows.sendingQueueID)
        XCTAssertEqual(outcome.claim.intent.state, .sending)
    }

    func testMigratedDatabaseReopensAsVersionTwoWithoutRerunningMigration() async throws {
        let fixture = try RepositoryTestFixture()
        defer { fixture.remove() }
        _ = try Self.writeVersionOneDatabase(at: fixture.databaseURL)

        var first: SQLiteDeviceMessagingRepository? =
            SQLiteDeviceMessagingRepository(databaseURL: fixture.databaseURL)
        let migrated = try await first?.bootstrap()
        first = nil

        let reopened = SQLiteDeviceMessagingRepository(databaseURL: fixture.databaseURL)
        let snapshot = try await reopened.bootstrap()
        XCTAssertEqual(snapshot.messages, migrated?.messages)
        // Reopening recovers nothing new: the generation only moves if a
        // sending claim is again attributed to a dead process, and migration
        // left none.
        XCTAssertEqual(snapshot.generation, migrated?.generation)
    }

    func testBootstrapRejectsUnsupportedFutureSchemaVersion() async throws {
        let fixture = try RepositoryTestFixture()
        defer { fixture.remove() }
        _ = try Self.writeVersionOneDatabase(at: fixture.databaseURL)
        try executeRawSQLiteScript(
            at: fixture.databaseURL,
            sql: "UPDATE schema_metadata SET value = '3' WHERE key = 'schema_version'"
        )

        let repository = SQLiteDeviceMessagingRepository(databaseURL: fixture.databaseURL)
        do {
            _ = try await repository.bootstrap()
            XCTFail("A future schema version must fail closed")
        } catch let error as DeviceMessagingRepositoryError {
            XCTAssertEqual(error, .schemaVersionUnsupported(3))
        }
    }

    func testBootstrapRejectsCorruptSchemaVersion() async throws {
        let fixture = try RepositoryTestFixture()
        defer { fixture.remove() }
        _ = try Self.writeVersionOneDatabase(at: fixture.databaseURL)
        try executeRawSQLiteScript(
            at: fixture.databaseURL,
            sql: "UPDATE schema_metadata SET value = 'v2' WHERE key = 'schema_version'"
        )

        let repository = SQLiteDeviceMessagingRepository(databaseURL: fixture.databaseURL)
        do {
            _ = try await repository.bootstrap()
            XCTFail("A non-numeric schema version must fail closed")
        } catch let error as DeviceMessagingRepositoryError {
            XCTAssertEqual(error, .schemaVersionUnsupported(-1))
        }
    }

    // MARK: - v1 database construction

    struct VersionOneRows {
        let generation: UInt64
        let deliveredMessageID: UUID
        let pendingQueueID: String
        let sendingQueueID: String
        let awaitingReceiptQueueID: String
        let failedQueueID: String
        let allMessageIDs: [UUID]
        let allQueueIDs: [String]
    }

    /// Writes a database byte-for-byte compatible with what the schema-v1
    /// repository produced: same DDL minus the two claim-identity columns,
    /// covering every delivery-intent state that existed in v1.
    private static func writeVersionOneDatabase(
        at databaseURL: URL
    ) throws -> VersionOneRows {
        let generation: UInt64 = 7
        let incomingID = uuid(0xA1)
        let pendingID = uuid(0xB1)
        let sendingID = uuid(0xC1)
        let awaitingID = uuid(0xD1)
        let failedID = uuid(0xE1)
        let deliveredID = uuid(0xF1)
        let fingerprint = String(repeating: "1", count: 64)
        let device = "device-target-0001"

        func messageRow(
            _ id: UUID,
            direction: Int,
            target: String?,
            state: Int,
            timestamp: Double
        ) -> String {
            let targetSQL = target.map { "'\($0)'" } ?? "NULL"
            return """
            INSERT INTO messages(
                message_id, conversation_fingerprint, target_device_id,
                direction, text, timestamp, delivery_state
            ) VALUES (
                '\(canonical(id))', '\(fingerprint)', \(targetSQL),
                \(direction), 'v1 payload', \(timestamp), \(state)
            );
            """
        }

        func intentRow(
            _ id: UUID,
            state: Int,
            retryCount: Int,
            lastAttemptAt: Double?,
            receiptDeadline: Double?,
            failureCode: String?,
            claimOwner: UUID?,
            claimGeneration: Int,
            createdAt: Double
        ) -> String {
            let lastAttemptSQL = lastAttemptAt.map { String($0) } ?? "NULL"
            let deadlineSQL = receiptDeadline.map { String($0) } ?? "NULL"
            let failureSQL = failureCode.map { "'\($0)'" } ?? "NULL"
            let ownerSQL = claimOwner.map { "'\(canonical($0))'" } ?? "NULL"
            return """
            INSERT INTO delivery_intents(
                queue_id, message_id, target_device_id, message_type, priority,
                payload, created_at, expires_at, state, retry_count,
                last_attempt_at, receipt_deadline, failure_code, claim_owner,
                claim_generation
            ) VALUES (
                '\(canonical(id))', '\(canonical(id))', '\(device)', 'text', 1,
                X'76310A', \(createdAt), NULL, \(state), \(retryCount),
                \(lastAttemptSQL), \(deadlineSQL), \(failureSQL), \(ownerSQL),
                \(claimGeneration)
            );
            """
        }

        try executeRawSQLiteScript(
            at: databaseURL,
            sql: """
            CREATE TABLE schema_metadata (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL
            ) STRICT;
            CREATE TABLE messages (
                message_id TEXT PRIMARY KEY NOT NULL,
                conversation_fingerprint TEXT NOT NULL,
                target_device_id TEXT,
                direction INTEGER NOT NULL CHECK(direction IN (0, 1)),
                text TEXT NOT NULL,
                timestamp REAL NOT NULL,
                delivery_state INTEGER NOT NULL CHECK(delivery_state IN (0, 1, 2, 3))
            ) STRICT;
            CREATE TABLE delivery_intents (
                queue_id TEXT PRIMARY KEY NOT NULL,
                message_id TEXT NOT NULL UNIQUE,
                target_device_id TEXT NOT NULL,
                message_type TEXT NOT NULL,
                priority INTEGER NOT NULL,
                payload BLOB NOT NULL,
                created_at REAL NOT NULL,
                expires_at REAL,
                state INTEGER NOT NULL CHECK(state IN (0, 1, 2, 3)),
                retry_count INTEGER NOT NULL CHECK(retry_count >= 0),
                last_attempt_at REAL,
                receipt_deadline REAL,
                failure_code TEXT,
                claim_owner TEXT,
                claim_generation INTEGER NOT NULL CHECK(claim_generation >= 0),
                FOREIGN KEY(message_id) REFERENCES messages(message_id) ON DELETE CASCADE
            ) STRICT;
            CREATE TABLE receipt_confirmations (
                message_id TEXT PRIMARY KEY NOT NULL,
                delivery_attempt_id TEXT NOT NULL,
                received_at REAL NOT NULL,
                FOREIGN KEY(message_id) REFERENCES messages(message_id) ON DELETE CASCADE
            ) STRICT;
            CREATE TABLE migration_sources (
                source_id TEXT PRIMARY KEY NOT NULL,
                content_digest TEXT NOT NULL
            ) STRICT;
            CREATE TABLE migration_issues (
                issue_id TEXT PRIMARY KEY NOT NULL,
                source_id TEXT NOT NULL,
                message_id TEXT,
                reason_code TEXT NOT NULL
            ) STRICT;
            CREATE INDEX messages_conversation_order
                ON messages(conversation_fingerprint, timestamp, message_id);
            CREATE INDEX delivery_ready_order
                ON delivery_intents(target_device_id, state, priority DESC, created_at, queue_id);
            INSERT INTO schema_metadata(key, value) VALUES ('schema_version', '1');
            INSERT INTO schema_metadata(key, value)
                VALUES ('repository_generation', '\(generation)');
            INSERT INTO schema_metadata(key, value)
                VALUES ('legacy_migration_complete', '1');

            \(messageRow(incomingID, direction: 0, target: nil, state: 2, timestamp: 1_001))
            \(messageRow(pendingID, direction: 1, target: device, state: 0, timestamp: 1_002))
            \(messageRow(sendingID, direction: 1, target: device, state: 0, timestamp: 1_003))
            \(messageRow(awaitingID, direction: 1, target: device, state: 1, timestamp: 1_004))
            \(messageRow(failedID, direction: 1, target: device, state: 3, timestamp: 1_005))
            \(messageRow(deliveredID, direction: 1, target: device, state: 2, timestamp: 1_006))

            \(intentRow(
                pendingID, state: 0, retryCount: 0, lastAttemptAt: nil,
                receiptDeadline: nil, failureCode: nil, claimOwner: nil,
                claimGeneration: 0, createdAt: 1_002
            ))
            \(intentRow(
                sendingID, state: 1, retryCount: 1, lastAttemptAt: 1_003,
                receiptDeadline: nil, failureCode: nil, claimOwner: uuid(0xAA),
                claimGeneration: 3, createdAt: 1_003
            ))
            \(intentRow(
                awaitingID, state: 2, retryCount: 0, lastAttemptAt: 1_004,
                receiptDeadline: 1_000_000, failureCode: nil, claimOwner: uuid(0xBB),
                claimGeneration: 2, createdAt: 1_004
            ))
            \(intentRow(
                failedID, state: 3, retryCount: 3, lastAttemptAt: 1_005,
                receiptDeadline: nil, failureCode: "legacy_failure", claimOwner: nil,
                claimGeneration: 3, createdAt: 1_005
            ))

            INSERT INTO receipt_confirmations(message_id, delivery_attempt_id, received_at)
                VALUES ('\(canonical(deliveredID))', '\(canonical(uuid(0xCC)))', 1_006);
            """
        )

        return VersionOneRows(
            generation: generation,
            deliveredMessageID: deliveredID,
            pendingQueueID: canonical(pendingID),
            sendingQueueID: canonical(sendingID),
            awaitingReceiptQueueID: canonical(awaitingID),
            failedQueueID: canonical(failedID),
            allMessageIDs: [
                incomingID, pendingID, sendingID, awaitingID, failedID, deliveredID,
            ],
            allQueueIDs: [
                canonical(pendingID), canonical(sendingID),
                canonical(awaitingID), canonical(failedID),
            ]
        )
    }

    private static func canonical(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }

    /// Deterministic UUIDs so failures reproduce byte-identically.
    private static func uuid(_ seed: UInt8) -> UUID {
        UUID(uuid: (
            seed, seed, seed, seed, seed, seed, seed, seed,
            seed, seed, seed, seed, seed, seed, seed, seed
        ))
    }
}
