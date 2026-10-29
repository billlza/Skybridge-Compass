import Foundation
import SQLite3
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private final class SQLiteConnectionHandle: @unchecked Sendable {
    private(set) var pointer: OpaquePointer?

    init(_ pointer: OpaquePointer) {
        self.pointer = pointer
    }

    func close() {
        guard let pointer else { return }
        sqlite3_close_v2(pointer)
        self.pointer = nil
    }

    deinit {
        close()
    }
}

private final class SQLiteRepositoryProcessLease: @unchecked Sendable {
    let processIdentifier: UUID
    let instanceIdentifier: UUID

    private let lockPath: String
    private let coordinator: SQLiteRepositoryProcessCoordinator

    init(
        processIdentifier: UUID,
        instanceIdentifier: UUID,
        lockPath: String,
        coordinator: SQLiteRepositoryProcessCoordinator
    ) {
        self.processIdentifier = processIdentifier
        self.instanceIdentifier = instanceIdentifier
        self.lockPath = lockPath
        self.coordinator = coordinator
    }

    deinit {
        coordinator.release(lockPath: lockPath, instanceIdentifier: instanceIdentifier)
    }
}

/// Serializes database ownership across processes while allowing multiple
/// repository actors in one process. The OS releases `flock` on process death,
/// so a new process can prove that claims stamped by the previous process are
/// interrupted without relying on a wall-clock lease timeout.
private final class SQLiteRepositoryProcessCoordinator: @unchecked Sendable {
    static let shared = SQLiteRepositoryProcessCoordinator()

    private struct Entry {
        let descriptor: Int32
        let bootstrapLock: NSLock
        var liveInstances: Set<UUID>
    }

    let processIdentifier = UUID()

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func acquire(lockPath: String, instanceIdentifier: UUID) throws
        -> SQLiteRepositoryProcessLease {
        lock.lock()
        defer { lock.unlock() }

        if var entry = entries[lockPath] {
            entry.liveInstances.insert(instanceIdentifier)
            entries[lockPath] = entry
            return SQLiteRepositoryProcessLease(
                processIdentifier: processIdentifier,
                instanceIdentifier: instanceIdentifier,
                lockPath: lockPath,
                coordinator: self
            )
        }

        let flags = O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK
        #if canImport(Darwin)
        let descriptor = Darwin.open(lockPath, flags, S_IRUSR | S_IWUSR)
        #elseif canImport(Glibc)
        let descriptor = Glibc.open(lockPath, flags, S_IRUSR | S_IWUSR)
        #endif
        guard descriptor >= 0 else {
            throw DeviceMessagingRepositoryError.invalidRecord(
                reasonCode: "database_process_lock_unavailable"
            )
        }

        var metadata = stat()
        #if canImport(Darwin)
        let metadataResult = Darwin.fstat(descriptor, &metadata)
        #elseif canImport(Glibc)
        let metadataResult = Glibc.fstat(descriptor, &metadata)
        #endif
        guard metadataResult == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              metadata.st_nlink == 1 else {
            Self.close(descriptor)
            throw DeviceMessagingRepositoryError.invalidDatabaseLocation
        }

        #if canImport(Darwin)
        let lockResult = Darwin.lockf(descriptor, F_TLOCK, 0)
        #elseif canImport(Glibc)
        let lockResult = Glibc.lockf(descriptor, F_TLOCK, 0)
        #endif
        guard lockResult == 0 else {
            Self.close(descriptor)
            throw DeviceMessagingRepositoryError.invalidRecord(
                reasonCode: "database_owned_by_another_process"
            )
        }

        entries[lockPath] = Entry(
            descriptor: descriptor,
            bootstrapLock: NSLock(),
            liveInstances: [instanceIdentifier]
        )
        return SQLiteRepositoryProcessLease(
            processIdentifier: processIdentifier,
            instanceIdentifier: instanceIdentifier,
            lockPath: lockPath,
            coordinator: self
        )
    }

    func isLive(
        lockPath: String,
        processIdentifier: UUID,
        instanceIdentifier: UUID
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard processIdentifier == self.processIdentifier else { return false }
        return entries[lockPath]?.liveInstances.contains(instanceIdentifier) == true
    }

    func performSerializedBootstrap<Result>(
        lockPath: String,
        _ operation: () throws -> Result
    ) throws -> Result {
        let bootstrapLock: NSLock
        lock.lock()
        guard let entry = entries[lockPath] else {
            lock.unlock()
            throw DeviceMessagingRepositoryError.invalidRecord(
                reasonCode: "database_process_lock_not_held"
            )
        }
        bootstrapLock = entry.bootstrapLock
        lock.unlock()

        bootstrapLock.lock()
        defer { bootstrapLock.unlock() }
        return try operation()
    }

    fileprivate func release(lockPath: String, instanceIdentifier: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[lockPath] else { return }
        entry.liveInstances.remove(instanceIdentifier)
        guard entry.liveInstances.isEmpty else {
            entries[lockPath] = entry
            return
        }
        #if canImport(Darwin)
        _ = Darwin.lockf(entry.descriptor, F_ULOCK, 0)
        #elseif canImport(Glibc)
        _ = Glibc.lockf(entry.descriptor, F_ULOCK, 0)
        #endif
        Self.close(entry.descriptor)
        entries.removeValue(forKey: lockPath)
    }

    private static func close(_ descriptor: Int32) {
        #if canImport(Darwin)
        _ = Darwin.close(descriptor)
        #elseif canImport(Glibc)
        _ = Glibc.close(descriptor)
        #endif
    }
}

/// Collects the exact rows one write transaction touches. Later records for
/// the same key replace earlier ones, and a removal cancels a pending upsert
/// (and vice versa), so the emitted change always reflects the transaction's
/// net effect in a deterministic order.
private struct RepositoryChangeCollector {
    private var messageUpserts: [UUID: PersistedMessageRecord] = [:]
    private var messageRemovals: [UUID: String] = [:]
    private var intentUpserts: [String: PersistedDeliveryIntent] = [:]
    private var intentRemovals: Set<String> = []

    var hasRows: Bool {
        !messageUpserts.isEmpty || !messageRemovals.isEmpty
            || !intentUpserts.isEmpty || !intentRemovals.isEmpty
    }

    mutating func upsert(_ message: PersistedMessageRecord) {
        messageRemovals.removeValue(forKey: message.id)
        messageUpserts[message.id] = message
    }

    mutating func removeMessage(id: UUID, conversationFingerprint: String) {
        messageUpserts.removeValue(forKey: id)
        messageRemovals[id] = conversationFingerprint
    }

    mutating func upsert(_ intent: PersistedDeliveryIntent) {
        intentRemovals.remove(intent.queueID)
        intentUpserts[intent.queueID] = intent
    }

    mutating func removeIntent(queueID: String) {
        intentUpserts.removeValue(forKey: queueID)
        intentRemovals.insert(queueID)
    }

    func change(
        basisGeneration: UInt64,
        generation: UInt64
    ) -> MessageRepositoryChange {
        MessageRepositoryChange(
            upsertedMessages: messageUpserts.values.sorted { lhs, rhs in
                if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
                return lhs.id.uuidString < rhs.id.uuidString
            },
            removedMessages: messageRemovals
                .map {
                    MessageRepositoryMessageRemoval(
                        id: $0.key,
                        conversationFingerprint: $0.value
                    )
                }
                .sorted { lhs, rhs in
                    if lhs.conversationFingerprint != rhs.conversationFingerprint {
                        return lhs.conversationFingerprint < rhs.conversationFingerprint
                    }
                    return lhs.id.uuidString < rhs.id.uuidString
                },
            upsertedDeliveryIntents: intentUpserts.values.sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.queueID < rhs.queueID
            },
            removedDeliveryIntentQueueIDs: intentRemovals.sorted(),
            basisGeneration: basisGeneration,
            generation: generation
        )
    }
}

/// The single durable authority for conversation history and delivery intent.
///
/// SQLite owns crash recovery and cross-table atomicity. The actor owns the
/// connection and guarantees that no SQLite handle escapes its isolation.
public actor SQLiteDeviceMessagingRepository {
    private static let schemaVersion = 2
    private static let maximumTextBytes = 64 * 1_024
    private static let maximumPayloadBytes = 1_024 * 1_024
    private static let maximumIdentifierBytes = 512
    private static let maximumFailureCodeBytes = 128
    static let maximumMessagesPerConversation = 500
    static let maximumActiveDeliveryIntents = 1_000
    static let maximumActiveDeliveryIntentsPerDevice = 100
    /// Global bounds. Conversation count and terminal history grow with normal
    /// use and previously had no ceiling, and failed intents are excluded from
    /// the active-intent budget so they previously accumulated forever.
    /// Compaction runs inside the same write transaction that would exceed a
    /// bound and only ever evicts fully terminal, intent-free rows (or, for
    /// the failed-intent bound, the oldest failed intents while their failed
    /// messages stay visible). If nothing is evictable the write fails closed.
    static let maximumConversations = 128
    static let maximumTotalMessageRows = 20_000
    static let maximumFailedDeliveryIntents = 256
    static let maximumMigrationIssues = 512

    private let databaseURL: URL
    private let instanceIdentifier = UUID()
    private var database: SQLiteConnectionHandle?
    private var processLease: SQLiteRepositoryProcessLease?
    private var processLockPath: String?
    private var isBootstrapped = false

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    public func bootstrap(
        legacyMigration: LegacyMessageMigration? = nil
    ) throws -> MessageRepositorySnapshot {
        if isBootstrapped {
            if let legacyMigration {
                try verifyLegacySources(legacyMigration.sources)
            }
            return try makeSnapshot()
        }

        try openDatabase()
        do {
            guard let processLockPath else {
                throw DeviceMessagingRepositoryError.invalidRecord(
                    reasonCode: "database_process_lock_not_held"
                )
            }
            return try SQLiteRepositoryProcessCoordinator.shared.performSerializedBootstrap(
                lockPath: processLockPath
            ) {
                try configureDatabase()
                try applyFileProtection()
                try ensureIncrementalVacuum()
                try createOrValidateSchema()
                try runIntegrityCheck()
                try applyLegacyMigrationIfNeeded(legacyMigration ?? .empty)
                if let legacyMigration {
                    try verifyLegacySources(legacyMigration.sources)
                }
                _ = try recoverInterruptedClaims()
                isBootstrapped = true
                return try makeSnapshot()
            }
        } catch {
            closeDatabase()
            throw error
        }
    }

    public func currentSnapshot() throws -> MessageRepositorySnapshot {
        try requireBootstrapped()
        return try makeSnapshot()
    }

    private func openDatabase() throws {
        guard database == nil,
              databaseURL.isFileURL,
              databaseURL.path.hasPrefix("/") else {
            throw DeviceMessagingRepositoryError.invalidDatabaseLocation
        }
        let fileManager = FileManager.default
        let parent = databaseURL.deletingLastPathComponent().standardizedFileURL
        guard parent.path != "/" else {
            throw DeviceMessagingRepositoryError.invalidDatabaseLocation
        }
        try fileManager.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: Self.directoryAttributes
        )
        let parentAttributes = try fileManager.attributesOfItem(atPath: parent.path)
        guard parentAttributes[.type] as? FileAttributeType == .typeDirectory else {
            throw DeviceMessagingRepositoryError.invalidDatabaseLocation
        }
        try fileManager.setAttributes(Self.directoryAttributes, ofItemAtPath: parent.path)
        let canonicalDatabaseURL = URL(fileURLWithPath: try canonicalExistingPath(parent.path))
            .appendingPathComponent(databaseURL.lastPathComponent, isDirectory: false)
        let lockPath = canonicalDatabaseURL.path + ".process-lock"
        let lease = try SQLiteRepositoryProcessCoordinator.shared.acquire(
            lockPath: lockPath,
            instanceIdentifier: instanceIdentifier
        )
        try validateSQLiteFileIfPresent(canonicalDatabaseURL)
        try validateSQLiteFileIfPresent(URL(fileURLWithPath: canonicalDatabaseURL.path + "-wal"))
        try validateSQLiteFileIfPresent(URL(fileURLWithPath: canonicalDatabaseURL.path + "-shm"))

        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
            | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW
        let code = sqlite3_open_v2(canonicalDatabaseURL.path, &opened, flags, nil)
        guard code == SQLITE_OK, let opened else {
            if let opened { sqlite3_close_v2(opened) }
            throw sqliteError(operation: "open", code: code)
        }
        database = SQLiteConnectionHandle(opened)
        processLease = lease
        processLockPath = lockPath
        try validateSQLiteFileIfPresent(canonicalDatabaseURL)
    }

    private func validateSQLiteFileIfPresent(_ fileURL: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              ((attributes[.referenceCount] as? NSNumber)?.intValue ?? 1) == 1 else {
            throw DeviceMessagingRepositoryError.invalidDatabaseLocation
        }
    }

    private func canonicalExistingPath(_ path: String) throws -> String {
        guard let resolved = realpath(path, nil) else {
            throw DeviceMessagingRepositoryError.invalidDatabaseLocation
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func closeDatabase() {
        guard let database else { return }
        database.close()
        self.database = nil
        processLease = nil
        processLockPath = nil
        isBootstrapped = false
    }

    private func configureDatabase() throws {
        // Install the busy handler before WAL/schema pragmas so concurrent
        // first-open repository actors wait for each other's short setup lock.
        try execute("PRAGMA busy_timeout = 5000")
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = FULL")
        try execute("PRAGMA fullfsync = ON")
        try execute("PRAGMA trusted_schema = OFF")
        try execute("PRAGMA recursive_triggers = OFF")
    }

    /// Compaction deletes rows; incremental auto-vacuum lets the freed pages
    /// return to the filesystem in small bounded steps after each compacting
    /// commit instead of the file growing forever. Databases created before
    /// this policy require one full VACUUM to adopt it; that runs once during
    /// bootstrap, outside any transaction, while this process holds the
    /// exclusive sidecar lock.
    private func ensureIncrementalVacuum() throws {
        let incrementalMode = 2
        guard try scalarInt("PRAGMA auto_vacuum", bindings: []) != incrementalMode else {
            return
        }
        try execute("PRAGMA auto_vacuum = INCREMENTAL")
        try execute("VACUUM")
        guard try scalarInt("PRAGMA auto_vacuum", bindings: []) == incrementalMode else {
            throw DeviceMessagingRepositoryError.invalidRecord(
                reasonCode: "auto_vacuum_conversion_failed"
            )
        }
    }

    /// Returns freed pages to the filesystem after a commit that removed rows.
    /// The page budget bounds the extra I/O added to any one mutation.
    private func reclaimStorage(after change: MessageRepositoryChange) throws {
        guard !change.removedMessages.isEmpty
            || !change.removedDeliveryIntentQueueIDs.isEmpty else {
            return
        }
        try execute("PRAGMA incremental_vacuum(256)")
    }

    /// Runs one write transaction and returns the caller's value together with
    /// the exact change the transaction committed. The generation is read
    /// inside the transaction, so the change is provably paired with the basis
    /// it applies to even when other repository instances interleave writes.
    private func withChangeTransaction<Value>(
        _ operation: (inout RepositoryChangeCollector) throws -> Value
    ) throws -> (value: Value, change: MessageRepositoryChange) {
        var collector = RepositoryChangeCollector()
        let outcome: (value: Value, basis: UInt64, result: UInt64) =
            try withTransaction(mode: "IMMEDIATE") {
                let basis = try readGeneration()
                let value = try operation(&collector)
                let result = try readGeneration()
                guard result > basis || !collector.hasRows else {
                    throw DeviceMessagingRepositoryError.invalidRecord(
                        reasonCode: "change_without_generation_advance"
                    )
                }
                return (value, basis, result)
            }
        let change = collector.change(
            basisGeneration: outcome.basis,
            generation: outcome.result
        )
        try reclaimStorage(after: change)
        return (outcome.value, change)
    }

    private func withChangeTransaction(
        _ operation: (inout RepositoryChangeCollector) throws -> Void
    ) throws -> MessageRepositoryChange {
        let outcome: (value: Void, change: MessageRepositoryChange) =
            try withChangeTransaction(operation)
        return outcome.change
    }

    private func createOrValidateSchema() throws {
        try withTransaction(mode: "EXCLUSIVE") {
            try execute(
                """
                CREATE TABLE IF NOT EXISTS schema_metadata (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL
                ) STRICT
                """
            )
            try execute(
                """
                CREATE TABLE IF NOT EXISTS messages (
                    message_id TEXT PRIMARY KEY NOT NULL,
                    conversation_fingerprint TEXT NOT NULL,
                    target_device_id TEXT,
                    direction INTEGER NOT NULL CHECK(direction IN (0, 1)),
                    text TEXT NOT NULL,
                    timestamp REAL NOT NULL,
                    delivery_state INTEGER NOT NULL CHECK(delivery_state IN (0, 1, 2, 3))
                ) STRICT
                """
            )
            try execute(
                """
                CREATE TABLE IF NOT EXISTS delivery_intents (
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
                    claim_process_id TEXT,
                    claim_instance_id TEXT,
                    claim_generation INTEGER NOT NULL CHECK(claim_generation >= 0),
                    FOREIGN KEY(message_id) REFERENCES messages(message_id) ON DELETE CASCADE
                ) STRICT
                """
            )
            try execute(
                """
                CREATE TABLE IF NOT EXISTS receipt_confirmations (
                    message_id TEXT PRIMARY KEY NOT NULL,
                    delivery_attempt_id TEXT NOT NULL,
                    received_at REAL NOT NULL,
                    FOREIGN KEY(message_id) REFERENCES messages(message_id) ON DELETE CASCADE
                ) STRICT
                """
            )
            try execute(
                """
                CREATE TABLE IF NOT EXISTS migration_sources (
                    source_id TEXT PRIMARY KEY NOT NULL,
                    content_digest TEXT NOT NULL
                ) STRICT
                """
            )
            try execute(
                """
                CREATE TABLE IF NOT EXISTS migration_issues (
                    issue_id TEXT PRIMARY KEY NOT NULL,
                    source_id TEXT NOT NULL,
                    message_id TEXT,
                    reason_code TEXT NOT NULL
                ) STRICT
                """
            )
            try execute(
                "CREATE INDEX IF NOT EXISTS messages_conversation_order ON messages(conversation_fingerprint, timestamp, message_id)"
            )
            try execute(
                "CREATE INDEX IF NOT EXISTS delivery_ready_order ON delivery_intents(target_device_id, state, priority DESC, created_at, queue_id)"
            )

            if let rawVersion = try metadataValue(for: "schema_version") {
                guard let version = Int(rawVersion) else {
                    throw DeviceMessagingRepositoryError.schemaVersionUnsupported(
                        -1
                    )
                }
                switch version {
                case Self.schemaVersion:
                    break
                case 1:
                    try migrateSchemaVersionOneToTwo()
                default:
                    throw DeviceMessagingRepositoryError.schemaVersionUnsupported(version)
                }
            } else {
                try setMetadataValue(String(Self.schemaVersion), for: "schema_version")
                try setMetadataValue("0", for: "repository_generation")
            }
        }
    }

    private func migrateSchemaVersionOneToTwo() throws {
        try execute("ALTER TABLE delivery_intents ADD COLUMN claim_process_id TEXT")
        try execute("ALTER TABLE delivery_intents ADD COLUMN claim_instance_id TEXT")
        let interruptedProcess = "00000000-0000-0000-0000-000000000000"
        let statement = try prepare(
            """
            UPDATE delivery_intents
               SET claim_process_id = ?, claim_instance_id = ?
             WHERE state IN (?, ?)
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(interruptedProcess, to: statement, index: 1)
        try bind(interruptedProcess, to: statement, index: 2)
        try bind(Int(PersistedDeliveryIntentState.sending.rawValue), to: statement, index: 3)
        try bind(
            Int(PersistedDeliveryIntentState.awaitingReceipt.rawValue),
            to: statement,
            index: 4
        )
        try stepDone(statement, operation: "migrate_claim_instance_identity")
        try setMetadataValue(String(Self.schemaVersion), for: "schema_version")
    }

    private func runIntegrityCheck() throws {
        let statement = try prepare("PRAGMA quick_check")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              textColumn(statement, index: 0) == "ok" else {
            throw sqliteError(operation: "quick_check", code: sqlite3_errcode(requiredDatabase()))
        }

        let foreignKeys = try prepare("PRAGMA foreign_key_check")
        defer { sqlite3_finalize(foreignKeys) }
        switch sqlite3_step(foreignKeys) {
        case SQLITE_DONE:
            break
        case SQLITE_ROW:
            throw DeviceMessagingRepositoryError.invalidRecord(
                reasonCode: "foreign_key_violation"
            )
        default:
            throw currentSQLiteError(operation: "foreign_key_check")
        }

        let owners = try prepare(
            """
            SELECT state, claim_owner, claim_process_id, claim_instance_id
              FROM delivery_intents
             ORDER BY queue_id
            """
        )
        defer { sqlite3_finalize(owners) }
        validateOwners: while true {
            switch sqlite3_step(owners) {
            case SQLITE_ROW:
                guard let state = PersistedDeliveryIntentState(
                    rawValue: sqlite3_column_int(owners, 0)
                ) else {
                    throw DeviceMessagingRepositoryError.invalidRecord(
                        reasonCode: "invalid_persisted_intent_state"
                    )
                }
                let owner = textColumn(owners, index: 1)
                let process = textColumn(owners, index: 2)
                let instance = textColumn(owners, index: 3)
                switch state {
                case .sending, .awaitingReceipt:
                    guard owner.flatMap(UUID.init(uuidString:)) != nil,
                          process.flatMap(UUID.init(uuidString:)) != nil,
                          instance.flatMap(UUID.init(uuidString:)) != nil else {
                        throw DeviceMessagingRepositoryError.invalidRecord(
                            reasonCode: "missing_persisted_claim_identity"
                        )
                    }
                case .pending, .failed:
                    guard owner == nil, process == nil, instance == nil else {
                        throw DeviceMessagingRepositoryError.invalidRecord(
                            reasonCode: "unexpected_persisted_claim_identity"
                        )
                    }
                }
            case SQLITE_DONE:
                break validateOwners
            default:
                throw currentSQLiteError(operation: "validate_claim_owners")
            }
        }

        let receipts = try prepare(
            """
            SELECT delivery_attempt_id, received_at
              FROM receipt_confirmations
             ORDER BY message_id
            """
        )
        defer { sqlite3_finalize(receipts) }
        validateReceipts: while true {
            switch sqlite3_step(receipts) {
            case SQLITE_ROW:
                let receivedAt = sqlite3_column_double(receipts, 1)
                guard textColumn(receipts, index: 0).flatMap(UUID.init(uuidString:)) != nil,
                      receivedAt.isFinite else {
                    throw DeviceMessagingRepositoryError.invalidRecord(
                        reasonCode: "invalid_receipt_confirmation"
                    )
                }
            case SQLITE_DONE:
                break validateReceipts
            default:
                throw currentSQLiteError(operation: "validate_receipt_confirmations")
            }
        }

        let invalidIntentRelationships = try scalarInt(
            """
            SELECT COUNT(*)
              FROM delivery_intents AS intent
              JOIN messages AS message ON message.message_id = intent.message_id
             WHERE message.direction != 1
                OR message.target_device_id IS NULL
                OR message.target_device_id != intent.target_device_id
                OR (intent.state IN (0, 1) AND message.delivery_state != 0)
                OR (intent.state = 2 AND message.delivery_state != 1)
                OR (intent.state = 3 AND message.delivery_state != 3)
            """,
            bindings: []
        )
        let invalidMessageRelationships = try scalarInt(
            """
            SELECT COUNT(*)
              FROM messages AS message
              LEFT JOIN delivery_intents AS intent
                ON intent.message_id = message.message_id
             WHERE (message.direction = 0 AND (
                        message.target_device_id IS NOT NULL
                     OR message.delivery_state != 2
                     OR intent.message_id IS NOT NULL
                   ))
                OR (message.direction = 1 AND (
                        (message.target_device_id IS NULL AND NOT (
                            intent.message_id IS NULL
                            AND (
                                message.delivery_state IN (2, 3)
                                OR (message.delivery_state = 1 AND EXISTS (
                                    SELECT 1
                                      FROM migration_issues AS issue
                                     WHERE issue.message_id = message.message_id
                                       AND issue.reason_code = 'legacy_sent_without_authenticated_receipt'
                                ))
                            )
                        ))
                     OR (message.delivery_state = 0 AND COALESCE(intent.state, -1) NOT IN (0, 1))
                     OR (message.delivery_state = 1 AND NOT (
                            COALESCE(intent.state, -1) = 2
                            OR (intent.message_id IS NULL AND EXISTS (
                                SELECT 1
                                  FROM migration_issues AS issue
                                 WHERE issue.message_id = message.message_id
                                   AND issue.reason_code = 'legacy_sent_without_authenticated_receipt'
                            ))
                        ))
                     OR (message.delivery_state = 2 AND intent.message_id IS NOT NULL)
                     OR (message.delivery_state = 3 AND intent.message_id IS NOT NULL AND intent.state != 3)
                   ))
            """,
            bindings: []
        )
        let invalidReceiptRelationships = try scalarInt(
            """
            SELECT COUNT(*)
              FROM receipt_confirmations AS receipt
              JOIN messages AS message ON message.message_id = receipt.message_id
              LEFT JOIN delivery_intents AS intent ON intent.message_id = receipt.message_id
             WHERE message.direction != 1
                OR message.delivery_state != 2
                OR intent.message_id IS NOT NULL
            """,
            bindings: []
        )
        guard invalidIntentRelationships == 0,
              invalidMessageRelationships == 0,
              invalidReceiptRelationships == 0 else {
            throw DeviceMessagingRepositoryError.invalidRecord(
                reasonCode: "message_intent_relationship_violation"
            )
        }
    }

    /// Synthetic source for issues the repository itself generates while
    /// bounding an imported legacy store. Exact eviction counts live in
    /// `schema_metadata` under the `legacy_*_compacted_count` and
    /// `migration_issue_overflow_count` keys.
    static let compactionIssueSourceID = "repository_compaction"

    private func applyLegacyMigrationIfNeeded(
        _ migration: LegacyMessageMigration
    ) throws {
        try withTransaction(mode: "IMMEDIATE") {
            guard try metadataValue(for: "legacy_migration_complete") == nil else {
                return
            }
            try validateMigration(migration)
            guard try rowCount(table: "messages") == 0,
                  try rowCount(table: "delivery_intents") == 0,
                  try rowCount(table: "migration_sources") == 0 else {
                throw DeviceMessagingRepositoryError.legacySourceConflict(
                    "partially_initialized_database"
                )
            }

            // A valid legacy store predates the global bounds, so the bounds
            // are applied to it here, exactly once, with the same deterministic
            // eviction rules the runtime uses, instead of failing the import.
            let failedIntents = migration.deliveryIntents
                .filter { $0.state == .failed }
                .sorted { lhs, rhs in
                    if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
                    return lhs.queueID > rhs.queueID
                }
            let droppedFailedIntentQueueIDs = Set(
                failedIntents.dropFirst(Self.maximumFailedDeliveryIntents).map(\.queueID)
            )

            for message in migration.messages {
                try insertMessage(message)
            }
            for intent in migration.deliveryIntents
            where !droppedFailedIntentQueueIDs.contains(intent.queueID) {
                try insertIntent(intent, claimOwner: nil)
            }

            // Pre-existing active state is never dropped: when the excess is
            // not evictable the import keeps it and records the exact overage,
            // and the strict bounds then apply to every write that follows.
            var compactionCollector = RepositoryChangeCollector()

            var evictedConversationMessages = 0
            var conversationMessagesOverCapacity = 0
            for overflowing in try loadOverCapacityConversations() {
                let excess = overflowing.rowCount - Self.maximumMessagesPerConversation
                let removals = try loadEvictableTerminalMessages(
                    conversationFingerprint: overflowing.fingerprint,
                    limit: excess
                )
                try evictTerminalMessages(removals, into: &compactionCollector)
                evictedConversationMessages += removals.count
                conversationMessagesOverCapacity += excess - removals.count
            }

            var evictedConversations = 0
            var conversationsOverCapacity = 0
            let conversationCount = try scalarInt(
                "SELECT COUNT(DISTINCT conversation_fingerprint) FROM messages",
                bindings: []
            )
            if conversationCount > Self.maximumConversations {
                let excess = conversationCount - Self.maximumConversations
                let evictable = try loadEvictableConversationFingerprints(limit: excess)
                try evictConversations(evictable, into: &compactionCollector)
                evictedConversations = evictable.count
                conversationsOverCapacity = excess - evictable.count
            }
            var evictedMessages = 0
            var messagesOverCapacity = 0
            let totalRows = try rowCount(table: "messages")
            if totalRows > Self.maximumTotalMessageRows {
                let excess = totalRows - Self.maximumTotalMessageRows
                let removals = try loadEvictableTerminalMessages(
                    conversationFingerprint: nil,
                    limit: excess
                )
                try evictTerminalMessages(removals, into: &compactionCollector)
                evictedMessages = removals.count
                messagesOverCapacity = excess - removals.count
            }

            // Active delivery intents are user messages that have not been
            // delivered; they are imported whole even beyond the runtime
            // admission bounds, with the exact overage recorded. The strict
            // bounds then gate every admission that follows.
            let activeIntentCount = try scalarInt(
                "SELECT COUNT(*) FROM delivery_intents WHERE state IN (0, 1, 2)",
                bindings: []
            )
            let activeIntentsOverCapacity = max(
                0,
                activeIntentCount - Self.maximumActiveDeliveryIntents
            )
            let deviceActiveIntentsOverCapacity = try scalarInt(
                """
                SELECT COALESCE(SUM(excess), 0) FROM (
                    SELECT COUNT(*) - ? AS excess
                      FROM delivery_intents
                     WHERE state IN (0, 1, 2)
                     GROUP BY target_device_id
                    HAVING COUNT(*) > ?
                )
                """,
                bindings: [
                    .integer(Self.maximumActiveDeliveryIntentsPerDevice),
                    .integer(Self.maximumActiveDeliveryIntentsPerDevice),
                ]
            )

            let retainedIssues = migration.issues.prefix(Self.maximumMigrationIssues)
            let truncatedIssueCount = migration.issues.count - retainedIssues.count
            for issue in retainedIssues {
                try insertMigrationIssue(issue)
            }
            let compactionCounts: [(key: String, count: Int, reasonCode: String)] = [
                (
                    "legacy_failed_intents_compacted_count",
                    droppedFailedIntentQueueIDs.count,
                    "legacy_failed_intents_compacted"
                ),
                (
                    "legacy_conversation_messages_compacted_count",
                    evictedConversationMessages,
                    "legacy_conversation_messages_compacted"
                ),
                (
                    "legacy_conversation_messages_over_capacity_count",
                    conversationMessagesOverCapacity,
                    "legacy_conversation_messages_over_capacity"
                ),
                (
                    "legacy_active_intents_over_capacity_count",
                    activeIntentsOverCapacity,
                    "legacy_active_intents_over_capacity"
                ),
                (
                    "legacy_device_active_intents_over_capacity_count",
                    deviceActiveIntentsOverCapacity,
                    "legacy_device_active_intents_over_capacity"
                ),
                (
                    "legacy_conversations_compacted_count",
                    evictedConversations,
                    "legacy_conversations_compacted"
                ),
                (
                    "legacy_messages_compacted_count",
                    evictedMessages,
                    "legacy_messages_compacted"
                ),
                (
                    "legacy_conversations_over_capacity_count",
                    conversationsOverCapacity,
                    "legacy_conversations_over_capacity"
                ),
                (
                    "legacy_messages_over_capacity_count",
                    messagesOverCapacity,
                    "legacy_messages_over_capacity"
                ),
                (
                    "migration_issue_overflow_count",
                    truncatedIssueCount,
                    "migration_issue_overflow"
                ),
            ]
            for entry in compactionCounts where entry.count > 0 {
                try setMetadataValue(String(entry.count), for: entry.key)
                try insertMigrationIssue(MessageRepositoryMigrationIssue(
                    sourceID: Self.compactionIssueSourceID,
                    messageID: nil,
                    reasonCode: entry.reasonCode
                ))
            }

            for source in migration.sources.sorted(by: { $0.sourceID < $1.sourceID }) {
                let statement = try prepare(
                    "INSERT INTO migration_sources(source_id, content_digest) VALUES(?, ?)"
                )
                defer { sqlite3_finalize(statement) }
                try bind(source.sourceID, to: statement, index: 1)
                try bind(source.contentDigest, to: statement, index: 2)
                try stepDone(statement, operation: "insert_migration_source")
            }
            try setMetadataValue("1", for: "legacy_migration_complete")
        }
    }

    private func verifyLegacySources(_ sources: [LegacyMessageSource]) throws {
        let persisted = try loadMigrationSources()
        let supplied = Dictionary(uniqueKeysWithValues: sources.map {
            ($0.sourceID, $0.contentDigest)
        })
        guard supplied.allSatisfy({ persisted[$0.key] == $0.value }) else {
            let changed = supplied.keys.sorted().first {
                persisted[$0] != supplied[$0]
            } ?? "unknown_source"
            throw DeviceMessagingRepositoryError.legacySourceChanged(changed)
        }
    }

    private func validateMigration(_ migration: LegacyMessageMigration) throws {
        let quarantinedLegacySentMessageIDs = Set(migration.issues.compactMap { issue in
            issue.reasonCode == "legacy_sent_without_authenticated_receipt"
                ? issue.messageID
                : nil
        })
        var sourceIDs = Set<String>()
        for source in migration.sources {
            try validateIdentifier(source.sourceID, reasonCode: "invalid_migration_source")
            guard sourceIDs.insert(source.sourceID).inserted,
                  isLowercaseHexDigest(source.contentDigest) else {
                throw DeviceMessagingRepositoryError.legacySourceConflict(source.sourceID)
            }
        }

        // Capacity is deliberately not validated here: a legacy store predates
        // every bound, so the import transaction compacts evictable overflow
        // and records what remains over capacity instead of stranding the
        // user's history behind a fail-closed size gate.
        var messageIDs = Set<UUID>()
        var messagesByID: [UUID: PersistedMessageRecord] = [:]
        for message in migration.messages {
            try validateMessage(message)
            guard messageIDs.insert(message.id).inserted else {
                throw DeviceMessagingRepositoryError.duplicateMessage(message.id)
            }
            messagesByID[message.id] = message
        }

        var queueIDs = Set<String>()
        var intentMessageIDs = Set<UUID>()
        for intent in migration.deliveryIntents {
            try validateIntent(intent)
            guard intent.state == .pending || intent.state == .failed else {
                throw DeviceMessagingRepositoryError.legacySourceConflict(intent.queueID)
            }
            guard queueIDs.insert(intent.queueID).inserted else {
                throw DeviceMessagingRepositoryError.duplicateQueueID(intent.queueID)
            }
            guard intentMessageIDs.insert(intent.messageID).inserted,
                  let message = messagesByID[intent.messageID],
                  message.direction == .outgoing,
                  message.targetDeviceID == intent.targetDeviceID,
                  (intent.state == .pending && message.deliveryState == .pending)
                    || (intent.state == .failed && message.deliveryState == .failed) else {
                throw DeviceMessagingRepositoryError.legacySourceConflict(intent.queueID)
            }
        }

        for message in migration.messages {
            if message.direction == .incoming {
                guard message.targetDeviceID == nil,
                      message.deliveryState == .delivered else {
                    throw DeviceMessagingRepositoryError.legacySourceConflict(
                        message.id.uuidString.lowercased()
                    )
                }
            } else {
                switch message.deliveryState {
                case .pending:
                    guard intentMessageIDs.contains(message.id) else {
                        throw DeviceMessagingRepositoryError.legacySourceConflict(
                            message.id.uuidString.lowercased()
                        )
                    }
                case .sent:
                    // Preserve ambiguous old history without inventing a retry:
                    // it is admissible only with an explicit migration issue and
                    // never receives a delivery intent.
                    guard !intentMessageIDs.contains(message.id),
                          quarantinedLegacySentMessageIDs.contains(message.id) else {
                        throw DeviceMessagingRepositoryError.legacySourceConflict(
                            message.id.uuidString.lowercased()
                        )
                    }
                case .delivered, .failed:
                    break
                }
            }
        }

        var issueIDs = Set<UUID>()
        for issue in migration.issues {
            guard issueIDs.insert(issue.id).inserted,
                  sourceIDs.contains(issue.sourceID) else {
                throw DeviceMessagingRepositoryError.legacySourceConflict(issue.sourceID)
            }
            try validateIdentifier(issue.reasonCode, reasonCode: "invalid_migration_issue")
            if issue.reasonCode == "legacy_sent_without_authenticated_receipt" {
                guard let messageID = issue.messageID,
                      let message = messagesByID[messageID],
                      message.direction == .outgoing,
                      message.deliveryState == .sent,
                      !intentMessageIDs.contains(messageID) else {
                    throw DeviceMessagingRepositoryError.legacySourceConflict(
                        issue.sourceID
                    )
                }
            }
        }
    }

    // MARK: - Transactional messaging operations

    /// Atomically creates the visible outgoing message and its durable delivery
    /// intent. No network side effect may happen before this returns.
    public func stageOutgoing(
        message: PersistedMessageRecord,
        intent: PersistedDeliveryIntent
    ) throws -> MessageRepositoryChange {
        try requireBootstrapped()
        try validateMessage(message)
        try validateIntent(intent)
        guard message.direction == .outgoing,
              message.deliveryState == .pending,
              message.id == intent.messageID,
              message.targetDeviceID == intent.targetDeviceID,
              intent.state == .pending,
              intent.retryCount == 0,
              intent.lastAttemptAt == nil,
              intent.receiptDeadline == nil,
              intent.failureCode == nil else {
            throw DeviceMessagingRepositoryError.invalidRecord(
                reasonCode: "invalid_outgoing_transaction"
            )
        }

        return try withChangeTransaction { collector in
            if try messageExists(message.id) {
                throw DeviceMessagingRepositoryError.duplicateMessage(message.id)
            }
            if try intentExists(queueID: intent.queueID) {
                throw DeviceMessagingRepositoryError.duplicateQueueID(intent.queueID)
            }
            try admitDeliveryIntent(
                targetDeviceID: intent.targetDeviceID,
                admissionTime: intent.createdAt,
                into: &collector
            )
            try makeRoomForMessage(
                in: message.conversationFingerprint,
                into: &collector
            )
            _ = try compactGlobalMessageHistory(admitting: message, into: &collector)
            try insertMessage(message)
            collector.upsert(message)
            try insertIntent(intent, claimOwner: nil)
            collector.upsert(intent)
            try advanceGeneration()
        }
    }

    /// Inserts an incoming message idempotently. Reusing an identifier with
    /// different content is a state conflict, not a duplicate success.
    public func recordIncoming(
        _ message: PersistedMessageRecord
    ) throws -> MessageRepositoryChange {
        try requireBootstrapped()
        try validateMessage(message)
        guard message.direction == .incoming,
              message.targetDeviceID == nil,
              message.deliveryState == .delivered else {
            throw DeviceMessagingRepositoryError.invalidRecord(
                reasonCode: "invalid_incoming_record"
            )
        }

        return try withChangeTransaction { collector in
            if let existing = try loadMessage(id: message.id) {
                guard existing == message else {
                    throw DeviceMessagingRepositoryError.duplicateMessage(message.id)
                }
                return
            }
            try makeRoomForMessage(
                in: message.conversationFingerprint,
                into: &collector
            )
            _ = try compactGlobalMessageHistory(admitting: message, into: &collector)
            try insertMessage(message)
            collector.upsert(message)
            try advanceGeneration()
        }
    }

    public func claim(
        messageID: UUID,
        ownerToken: UUID,
        now: Date = Date()
    ) throws -> MessageDeliveryClaimOutcome {
        try requireBootstrapped()
        try validateDate(now, reasonCode: "invalid_claim_time")
        let outcome = try withChangeTransaction { collector in
            _ = try recoverInterruptedClaimsWithinTransaction(into: &collector)
            guard var intent = try loadIntent(messageID: messageID) else {
                throw DeviceMessagingRepositoryError.messageNotFound(messageID)
            }
            guard intent.state == .pending,
                  intent.expiresAt.map({ now <= $0 }) ?? true else {
                throw DeviceMessagingRepositoryError.staleClaim(intent.queueID)
            }
            let next = intent.claimGeneration.addingReportingOverflow(1)
            guard !next.overflow, next.partialValue <= UInt64(Int64.max) else {
                throw DeviceMessagingRepositoryError.invalidRecord(
                    reasonCode: "claim_generation_overflow"
                )
            }
            intent.state = .sending
            intent.lastAttemptAt = now
            intent.receiptDeadline = nil
            intent.claimGeneration = next.partialValue
            try updateIntent(intent, claimOwner: ownerToken)
            collector.upsert(intent)
            try advanceGeneration()
            return MessageDeliveryClaim(
                intent: intent,
                ownerToken: ownerToken,
                generation: intent.claimGeneration
            )
        }
        return MessageDeliveryClaimOutcome(claim: outcome.value, change: outcome.change)
    }

    public func claimNextReady(
        targetDeviceID: String,
        ownerToken: UUID,
        retryPolicy: MessageDeliveryRetryPolicy,
        now: Date = Date()
    ) throws -> MessageDeliveryPollOutcome {
        try requireBootstrapped()
        try validateIdentifier(targetDeviceID, reasonCode: "invalid_target_device_id")
        try validateRetryPolicy(retryPolicy)
        try validateDate(now, reasonCode: "invalid_claim_time")

        let outcome = try withChangeTransaction {
            collector -> MessageDeliveryClaim? in
            _ = try recoverInterruptedClaimsWithinTransaction(into: &collector)
            var candidates = try loadPendingIntents(targetDeviceID: targetDeviceID)
            let expired = candidates.filter { intent in
                intent.expiresAt.map { $0 < now } == true
            }
            for var intent in expired {
                intent.state = .failed
                intent.lastAttemptAt = now
                intent.receiptDeadline = nil
                intent.failureCode = "message_expired"
                try updateIntent(intent, claimOwner: nil)
                collector.upsert(intent)
                let failedMessage = try updateMessageState(
                    id: intent.messageID,
                    state: .failed,
                    expectedDirection: .outgoing
                )
                collector.upsert(failedMessage)
            }
            if !expired.isEmpty {
                try compactFailedDeliveryIntents(into: &collector)
                let expiredIDs = Set(expired.map(\.queueID))
                candidates.removeAll { expiredIDs.contains($0.queueID) }
            }
            guard let candidate = candidates.first(where: { intent in
                guard let lastAttemptAt = intent.lastAttemptAt else { return true }
                let exponent = max(0, intent.retryCount - 1)
                let delay = retryPolicy.retryInterval
                    * pow(retryPolicy.backoffFactor, Double(exponent))
                return delay.isFinite && now >= lastAttemptAt.addingTimeInterval(delay)
            }) else {
                // Interrupted-claim recovery advances the generation itself;
                // only an expiry settled here needs its own advance.
                if !expired.isEmpty { try advanceGeneration() }
                return nil
            }

            let next = candidate.claimGeneration.addingReportingOverflow(1)
            guard !next.overflow, next.partialValue <= UInt64(Int64.max) else {
                throw DeviceMessagingRepositoryError.invalidRecord(
                    reasonCode: "claim_generation_overflow"
                )
            }
            var claimed = candidate
            claimed.state = .sending
            claimed.lastAttemptAt = now
            claimed.receiptDeadline = nil
            claimed.claimGeneration = next.partialValue
            try updateIntent(claimed, claimOwner: ownerToken)
            collector.upsert(claimed)
            try advanceGeneration()
            return MessageDeliveryClaim(
                intent: claimed,
                ownerToken: ownerToken,
                generation: claimed.claimGeneration
            )
        }
        return MessageDeliveryPollOutcome(claim: outcome.value, change: outcome.change)
    }

    public func isClaimCurrent(_ claim: MessageDeliveryClaim) throws -> Bool {
        try requireBootstrapped()
        guard let stored = try loadIntentWithOwner(queueID: claim.intent.queueID) else {
            return false
        }
        return stored.intent.state == .sending
            && stored.intent.messageID == claim.intent.messageID
            && stored.intent.claimGeneration == claim.generation
            && stored.ownerToken == claim.ownerToken
    }

    /// Commits the local projection and delivery intent in one transaction.
    /// `.submitted` is intentionally distinct from `.delivered`: only an
    /// authenticated peer receipt may remove the intent.
    public func resolve(
        _ claim: MessageDeliveryClaim,
        disposition: MessageDeliveryDisposition,
        retryPolicy: MessageDeliveryRetryPolicy,
        now: Date = Date()
    ) throws -> MessageRepositoryChange {
        try requireBootstrapped()
        try validateRetryPolicy(retryPolicy)
        try validateDate(now, reasonCode: "invalid_resolution_time")

        return try withChangeTransaction { collector in
            guard var stored = try loadIntentWithOwner(queueID: claim.intent.queueID),
                  stored.intent.state == .sending,
                  stored.intent.messageID == claim.intent.messageID,
                  stored.intent.claimGeneration == claim.generation,
                  stored.ownerToken == claim.ownerToken else {
                throw DeviceMessagingRepositoryError.staleClaim(claim.intent.queueID)
            }

            switch disposition {
            case .submitted(let receiptDeadline):
                try validateDate(receiptDeadline, reasonCode: "invalid_receipt_deadline")
                guard receiptDeadline > now else {
                    throw DeviceMessagingRepositoryError.invalidRecord(
                        reasonCode: "expired_receipt_deadline"
                    )
                }
                stored.intent.state = .awaitingReceipt
                stored.intent.receiptDeadline = receiptDeadline
                stored.intent.failureCode = nil
                try updateIntent(stored.intent, claimOwner: claim.ownerToken)
                collector.upsert(stored.intent)
                collector.upsert(try updateMessageState(
                    id: stored.intent.messageID,
                    state: .sent,
                    expectedDirection: .outgoing
                ))

            case .retryable(let failureCode):
                try validateFailureCode(failureCode)
                let nextRetry = stored.intent.retryCount.addingReportingOverflow(1)
                guard !nextRetry.overflow else {
                    throw DeviceMessagingRepositoryError.invalidRecord(
                        reasonCode: "retry_count_overflow"
                    )
                }
                stored.intent.retryCount = nextRetry.partialValue
                stored.intent.lastAttemptAt = now
                stored.intent.receiptDeadline = nil
                stored.intent.failureCode = failureCode
                let exhausted = stored.intent.retryCount >= retryPolicy.maximumRetryCount
                stored.intent.state = exhausted ? .failed : .pending
                collector.upsert(try updateMessageState(
                    id: stored.intent.messageID,
                    state: exhausted ? .failed : .pending,
                    expectedDirection: .outgoing
                ))
                try updateIntent(stored.intent, claimOwner: nil)
                collector.upsert(stored.intent)
                if exhausted {
                    try compactFailedDeliveryIntents(into: &collector)
                }

            case .permanentFailure(let failureCode):
                try validateFailureCode(failureCode)
                stored.intent.state = .failed
                stored.intent.lastAttemptAt = now
                stored.intent.receiptDeadline = nil
                stored.intent.failureCode = failureCode
                try updateIntent(stored.intent, claimOwner: nil)
                collector.upsert(stored.intent)
                collector.upsert(try updateMessageState(
                    id: stored.intent.messageID,
                    state: .failed,
                    expectedDirection: .outgoing
                ))
                try compactFailedDeliveryIntents(into: &collector)

            case .interrupted:
                stored.intent.state = .pending
                stored.intent.receiptDeadline = nil
                try updateIntent(stored.intent, claimOwner: nil)
                collector.upsert(stored.intent)
                collector.upsert(try updateMessageState(
                    id: stored.intent.messageID,
                    state: .pending,
                    expectedDirection: .outgoing
                ))
            }
            try advanceGeneration()
        }
    }

    /// Confirms remote processing only from an authenticated frame that echoes
    /// the exact claim owner's attempt token. It intentionally supports the
    /// receipt-before-local-submit race by accepting both `.sending` and
    /// `.awaitingReceipt` for the same owner.
    public func confirmAuthenticatedReceipt(
        _ receipt: AuthenticatedMessageReceipt
    ) throws -> MessageRepositoryChange {
        try requireBootstrapped()
        try validateConversationFingerprint(
            receipt.conversationFingerprint,
            reasonCode: "invalid_receipt_conversation_fingerprint"
        )
        try validateDate(receipt.receivedAt, reasonCode: "invalid_receipt_time")

        return try withChangeTransaction { collector in
            guard let message = try loadMessage(id: receipt.messageID),
                  message.direction == .outgoing,
                  message.conversationFingerprint == receipt.conversationFingerprint else {
                throw DeviceMessagingRepositoryError.receiptBindingMismatch(
                    receipt.messageID
                )
            }
            if message.deliveryState == .delivered,
               try loadIntent(messageID: receipt.messageID) == nil {
                guard try loadReceiptConfirmation(messageID: receipt.messageID)
                    == receipt.deliveryAttemptID else {
                    throw DeviceMessagingRepositoryError.receiptBindingMismatch(
                        receipt.messageID
                    )
                }
                return
            }
            guard let stored = try loadIntentWithOwner(messageID: receipt.messageID),
                  stored.intent.state == .sending
                    || stored.intent.state == .awaitingReceipt,
                  stored.ownerToken == receipt.deliveryAttemptID else {
                throw DeviceMessagingRepositoryError.receiptBindingMismatch(
                    receipt.messageID
                )
            }
            collector.upsert(try updateMessageState(
                id: receipt.messageID,
                state: .delivered,
                expectedDirection: .outgoing
            ))
            try insertReceiptConfirmation(receipt)
            try deleteIntent(queueID: stored.intent.queueID)
            collector.removeIntent(queueID: stored.intent.queueID)
            try advanceGeneration()
        }
    }

    /// Receipt timeouts become retryable with the same stable message ID. This
    /// may retransmit a frame, but a conforming receiver deduplicates the
    /// business effect and returns the same authenticated receipt.
    public func requeueExpiredReceipts(
        now: Date = Date(),
        failureCode: String = "receipt_timeout",
        retryPolicy: MessageDeliveryRetryPolicy
    ) throws -> MessageRepositoryChange {
        try requireBootstrapped()
        try validateDate(now, reasonCode: "invalid_receipt_recovery_time")
        try validateFailureCode(failureCode)
        try validateRetryPolicy(retryPolicy)
        return try withChangeTransaction { collector in
            let expired = try loadIntents(
                where: "state = ? AND receipt_deadline IS NOT NULL AND receipt_deadline <= ?",
                bindings: [
                    .integer(Int(PersistedDeliveryIntentState.awaitingReceipt.rawValue)),
                    .double(now.timeIntervalSince1970),
                ]
            )
            guard !expired.isEmpty else { return }
            var anyTerminal = false
            for var intent in expired {
                let nextRetry = intent.retryCount.addingReportingOverflow(1)
                guard !nextRetry.overflow else {
                    throw DeviceMessagingRepositoryError.invalidRecord(
                        reasonCode: "retry_count_overflow"
                    )
                }
                intent.retryCount = nextRetry.partialValue
                intent.lastAttemptAt = now
                intent.receiptDeadline = nil
                intent.failureCode = failureCode
                let lifetimeExpired = intent.expiresAt.map { $0 < now } == true
                let exhausted = intent.retryCount >= retryPolicy.maximumRetryCount
                let terminal = exhausted || lifetimeExpired
                if lifetimeExpired {
                    intent.failureCode = "message_expired"
                }
                intent.state = terminal ? .failed : .pending
                anyTerminal = anyTerminal || terminal
                try updateIntent(intent, claimOwner: nil)
                collector.upsert(intent)
                collector.upsert(try updateMessageState(
                    id: intent.messageID,
                    state: terminal ? .failed : .pending,
                    expectedDirection: .outgoing
                ))
            }
            if anyTerminal {
                try compactFailedDeliveryIntents(into: &collector)
            }
            try advanceGeneration()
        }
    }

    public func clearConversation(
        _ conversationFingerprint: String
    ) throws -> MessageRepositoryChange {
        try requireBootstrapped()
        try validateConversationFingerprint(
            conversationFingerprint,
            reasonCode: "invalid_conversation_fingerprint"
        )
        return try withChangeTransaction { collector in
            let pending = try scalarInt(
                """
                SELECT COUNT(*)
                  FROM messages AS message
                  JOIN delivery_intents AS intent
                    ON intent.message_id = message.message_id
                 WHERE message.conversation_fingerprint = ?
                   AND intent.state IN (0, 1, 2)
                """,
                bindings: [.text(conversationFingerprint)]
            )
            guard pending == 0 else {
                throw DeviceMessagingRepositoryError.invalidRecord(
                    reasonCode: "pending_messages_prevent_clear"
                )
            }
            // Failed intents referencing this conversation are removed by the
            // foreign-key cascade, so the change must name them explicitly.
            let cascadedIntents = try prepare(
                """
                SELECT intent.queue_id
                  FROM delivery_intents AS intent
                  JOIN messages AS message
                    ON message.message_id = intent.message_id
                 WHERE message.conversation_fingerprint = ?
                """
            )
            defer { sqlite3_finalize(cascadedIntents) }
            try bind(conversationFingerprint, to: cascadedIntents, index: 1)
            var cascadedQueueIDs: [String] = []
            loadCascadedIntents: while true {
                switch sqlite3_step(cascadedIntents) {
                case SQLITE_ROW:
                    cascadedQueueIDs.append(requiredTextColumn(cascadedIntents, index: 0))
                case SQLITE_DONE:
                    break loadCascadedIntents
                default:
                    throw currentSQLiteError(operation: "load_cascaded_intents")
                }
            }
            let members = try prepare(
                "SELECT message_id FROM messages WHERE conversation_fingerprint = ?"
            )
            defer { sqlite3_finalize(members) }
            try bind(conversationFingerprint, to: members, index: 1)
            var memberIDs: [UUID] = []
            loadMembers: while true {
                switch sqlite3_step(members) {
                case SQLITE_ROW:
                    guard let memberID = UUID(
                        uuidString: requiredTextColumn(members, index: 0)
                    ) else {
                        throw DeviceMessagingRepositoryError.invalidRecord(
                            reasonCode: "invalid_persisted_message_id"
                        )
                    }
                    memberIDs.append(memberID)
                case SQLITE_DONE:
                    break loadMembers
                default:
                    throw currentSQLiteError(operation: "load_cleared_conversation")
                }
            }
            let statement = try prepare(
                "DELETE FROM messages WHERE conversation_fingerprint = ?"
            )
            defer { sqlite3_finalize(statement) }
            try bind(conversationFingerprint, to: statement, index: 1)
            try stepDone(statement, operation: "clear_conversation")
            if sqlite3_changes(requiredDatabase()) > 0 {
                for memberID in memberIDs {
                    collector.removeMessage(
                        id: memberID,
                        conversationFingerprint: conversationFingerprint
                    )
                }
                for queueID in cascadedQueueIDs {
                    collector.removeIntent(queueID: queueID)
                }
                try advanceGeneration()
            }
        }
    }

    /// Cancels one delivery that has not crossed the local network side-effect
    /// boundary. Sending and receipt-waiting intents remain owner-bound and must
    /// first be resolved by their exact worker or receipt timeout.
    public func cancelDelivery(
        queueID: String
    ) throws -> MessageRepositoryChange {
        try requireBootstrapped()
        try validateIdentifier(queueID, reasonCode: "invalid_queue_id")
        return try withChangeTransaction { collector in
            guard let intent = try loadIntentWithOwner(queueID: queueID)?.intent else {
                throw DeviceMessagingRepositoryError.intentNotFound(queueID)
            }
            guard intent.state == .pending || intent.state == .failed else {
                throw DeviceMessagingRepositoryError.invalidRecord(
                    reasonCode: "in_flight_delivery_prevents_cancel"
                )
            }
            try removeCancelledDelivery(intent, into: &collector)
            try advanceGeneration()
        }
    }

    /// Cancels every non-in-flight delivery for one target as one transaction.
    /// The whole operation fails before mutation if any matching delivery has
    /// already entered the network side-effect boundary.
    public func cancelDeliveries(
        targetDeviceID: String
    ) throws -> MessageRepositoryChange {
        try requireBootstrapped()
        try validateIdentifier(targetDeviceID, reasonCode: "invalid_target_device_id")
        return try withChangeTransaction { collector in
            let intents = try loadIntents(
                where: "target_device_id = ?",
                bindings: [.text(targetDeviceID)]
            )
            guard intents.allSatisfy({ $0.state == .pending || $0.state == .failed }) else {
                throw DeviceMessagingRepositoryError.invalidRecord(
                    reasonCode: "in_flight_delivery_prevents_cancel"
                )
            }
            guard !intents.isEmpty else { return }
            for intent in intents {
                try removeCancelledDelivery(intent, into: &collector)
            }
            try advanceGeneration()
        }
    }

    /// Clears the delivery queue without inventing a transport failure. Pending
    /// messages are removed with their intents; genuine failed history remains
    /// visible while its retry intent is removed.
    public func clearDeliveries() throws -> MessageRepositoryChange {
        try requireBootstrapped()
        return try withChangeTransaction { collector in
            let intents = try loadIntents()
            guard intents.allSatisfy({ $0.state == .pending || $0.state == .failed }) else {
                throw DeviceMessagingRepositoryError.invalidRecord(
                    reasonCode: "in_flight_delivery_prevents_cancel"
                )
            }
            guard !intents.isEmpty else { return }
            for intent in intents {
                try removeCancelledDelivery(intent, into: &collector)
            }
            try advanceGeneration()
        }
    }

    /// Reactivates non-expired failed deliveries and their visible messages in
    /// one transaction. Claim generations remain monotonic so stale owners and
    /// receipts can never become current again.
    public func retryFailedDeliveries(
        now: Date = Date()
    ) throws -> MessageRepositoryChange {
        try requireBootstrapped()
        try validateDate(now, reasonCode: "invalid_retry_time")
        return try withChangeTransaction { collector in
            let failed = try loadIntents(
                where: "state = ?",
                bindings: [.integer(Int(PersistedDeliveryIntentState.failed.rawValue))]
            )
            let retryable = failed.filter { $0.expiresAt.map { now <= $0 } ?? true }
            guard !retryable.isEmpty else { return }

            let active = try loadIntents(
                where: "state IN (0, 1, 2)",
                bindings: []
            )
            let activeTotal = active.count + retryable.count
            var activePerDevice: [String: Int] = [:]
            for intent in active + retryable {
                activePerDevice[intent.targetDeviceID, default: 0] += 1
            }
            guard activeTotal <= Self.maximumActiveDeliveryIntents,
                  activePerDevice.values.allSatisfy({
                      $0 <= Self.maximumActiveDeliveryIntentsPerDevice
                  }) else {
                throw DeviceMessagingRepositoryError.invalidRecord(
                    reasonCode: "delivery_intent_capacity_exceeded"
                )
            }

            for var intent in retryable {
                intent.state = .pending
                intent.retryCount = 0
                intent.lastAttemptAt = nil
                intent.receiptDeadline = nil
                intent.failureCode = nil
                try updateIntent(intent, claimOwner: nil)
                collector.upsert(intent)
                collector.upsert(try updateMessageState(
                    id: intent.messageID,
                    state: .pending,
                    expectedDirection: .outgoing
                ))
            }
            try advanceGeneration()
        }
    }

    // MARK: - Snapshot decoding

    private func makeSnapshot() throws -> MessageRepositorySnapshot {
        try withTransaction(mode: "DEFERRED") {
            // Reading generation first establishes one WAL read snapshot. Every
            // projection below is therefore paired with the exact generation
            // that committed it, even when another repository instance writes.
            let snapshotGeneration = try readGeneration()
            return MessageRepositorySnapshot(
                messages: try loadMessages(),
                deliveryIntents: try loadIntents(),
                migrationIssues: try loadMigrationIssues(),
                generation: snapshotGeneration
            )
        }
    }

    private func loadMessages() throws -> [PersistedMessageRecord] {
        let statement = try prepare(
            """
            SELECT message_id, conversation_fingerprint, target_device_id,
                   direction, text, timestamp, delivery_state
              FROM messages
             ORDER BY timestamp, message_id
            """
        )
        defer { sqlite3_finalize(statement) }
        var result: [PersistedMessageRecord] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                result.append(try decodeMessage(statement))
            case SQLITE_DONE:
                return result
            default:
                throw currentSQLiteError(operation: "load_messages")
            }
        }
    }

    private func loadIntents() throws -> [PersistedDeliveryIntent] {
        try loadIntents(where: nil, bindings: [])
    }

    /// The filter must be a compile-time constant WHERE clause with `?`
    /// placeholders; every value flows through `bindings`.
    private func loadIntents(
        where filter: String?,
        bindings: [ScalarBinding]
    ) throws -> [PersistedDeliveryIntent] {
        let whereClause = filter.map { "WHERE \($0)" } ?? ""
        let statement = try prepare(
            """
            SELECT queue_id, message_id, target_device_id, message_type,
                   priority, payload, created_at, expires_at, state,
                   retry_count, last_attempt_at, receipt_deadline,
                   failure_code, claim_generation
              FROM delivery_intents
             \(whereClause)
             ORDER BY created_at, queue_id
            """
        )
        defer { sqlite3_finalize(statement) }
        for (offset, binding) in bindings.enumerated() {
            switch binding {
            case .text(let value):
                try bind(value, to: statement, index: Int32(offset + 1))
            case .integer(let value):
                try bind(value, to: statement, index: Int32(offset + 1))
            case .double(let value):
                try bind(value, to: statement, index: Int32(offset + 1))
            }
        }
        var result: [PersistedDeliveryIntent] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                result.append(try decodeIntent(statement))
            case SQLITE_DONE:
                return result
            default:
                throw currentSQLiteError(operation: "load_intents")
            }
        }
    }

    private func loadMigrationIssues() throws -> [MessageRepositoryMigrationIssue] {
        let statement = try prepare(
            """
            SELECT issue_id, source_id, message_id, reason_code
              FROM migration_issues
             ORDER BY source_id, issue_id
            """
        )
        defer { sqlite3_finalize(statement) }
        var result: [MessageRepositoryMigrationIssue] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let issueID = UUID(uuidString: requiredTextColumn(statement, index: 0)),
                      let sourceID = textColumn(statement, index: 1),
                      let reasonCode = textColumn(statement, index: 3) else {
                    throw DeviceMessagingRepositoryError.invalidRecord(
                        reasonCode: "invalid_migration_issue_row"
                    )
                }
                let messageID = textColumn(statement, index: 2).flatMap(UUID.init(uuidString:))
                result.append(MessageRepositoryMigrationIssue(
                    id: issueID,
                    sourceID: sourceID,
                    messageID: messageID,
                    reasonCode: reasonCode
                ))
            case SQLITE_DONE:
                return result
            default:
                throw currentSQLiteError(operation: "load_migration_issues")
            }
        }
    }

    private func loadMessage(id: UUID) throws -> PersistedMessageRecord? {
        let statement = try prepare(
            """
            SELECT message_id, conversation_fingerprint, target_device_id,
                   direction, text, timestamp, delivery_state
              FROM messages WHERE message_id = ?
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(canonicalUUID(id), to: statement, index: 1)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return try decodeMessage(statement)
        case SQLITE_DONE:
            return nil
        default:
            throw currentSQLiteError(operation: "load_message")
        }
    }

    private func loadIntent(messageID: UUID) throws -> PersistedDeliveryIntent? {
        let statement = try prepare(
            """
            SELECT queue_id, message_id, target_device_id, message_type,
                   priority, payload, created_at, expires_at, state,
                   retry_count, last_attempt_at, receipt_deadline,
                   failure_code, claim_generation
              FROM delivery_intents WHERE message_id = ?
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(canonicalUUID(messageID), to: statement, index: 1)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return try decodeIntent(statement)
        case SQLITE_DONE:
            return nil
        default:
            throw currentSQLiteError(operation: "load_intent")
        }
    }

    private func loadIntentWithOwner(
        queueID: String
    ) throws -> (intent: PersistedDeliveryIntent, ownerToken: UUID?)? {
        let statement = try prepare(
            """
            SELECT queue_id, message_id, target_device_id, message_type,
                   priority, payload, created_at, expires_at, state,
                   retry_count, last_attempt_at, receipt_deadline,
                   failure_code, claim_generation, claim_owner
              FROM delivery_intents WHERE queue_id = ?
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(queueID, to: statement, index: 1)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            let intent = try decodeIntent(statement)
            let owner = textColumn(statement, index: 14).flatMap(UUID.init(uuidString:))
            return (intent, owner)
        case SQLITE_DONE:
            return nil
        default:
            throw currentSQLiteError(operation: "load_intent_owner")
        }
    }

    private func loadIntentWithOwner(
        messageID: UUID
    ) throws -> (intent: PersistedDeliveryIntent, ownerToken: UUID?)? {
        let statement = try prepare(
            """
            SELECT queue_id, message_id, target_device_id, message_type,
                   priority, payload, created_at, expires_at, state,
                   retry_count, last_attempt_at, receipt_deadline,
                   failure_code, claim_generation, claim_owner
              FROM delivery_intents WHERE message_id = ?
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(canonicalUUID(messageID), to: statement, index: 1)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            let intent = try decodeIntent(statement)
            let owner = textColumn(statement, index: 14).flatMap(UUID.init(uuidString:))
            return (intent, owner)
        case SQLITE_DONE:
            return nil
        default:
            throw currentSQLiteError(operation: "load_intent_owner_by_message")
        }
    }

    private func loadReceiptConfirmation(messageID: UUID) throws -> UUID? {
        let statement = try prepare(
            "SELECT delivery_attempt_id FROM receipt_confirmations WHERE message_id = ?"
        )
        defer { sqlite3_finalize(statement) }
        try bind(canonicalUUID(messageID), to: statement, index: 1)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            guard let attemptID = textColumn(statement, index: 0)
                .flatMap(UUID.init(uuidString:)) else {
                throw DeviceMessagingRepositoryError.invalidRecord(
                    reasonCode: "invalid_receipt_confirmation"
                )
            }
            return attemptID
        case SQLITE_DONE:
            return nil
        default:
            throw currentSQLiteError(operation: "load_receipt_confirmation")
        }
    }

    private func loadPendingIntents(
        targetDeviceID: String
    ) throws -> [PersistedDeliveryIntent] {
        let statement = try prepare(
            """
            SELECT queue_id, message_id, target_device_id, message_type,
                   priority, payload, created_at, expires_at, state,
                   retry_count, last_attempt_at, receipt_deadline,
                   failure_code, claim_generation
              FROM delivery_intents
             WHERE target_device_id = ? AND state = ?
             ORDER BY priority DESC, created_at, queue_id
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(targetDeviceID, to: statement, index: 1)
        try bind(Int(PersistedDeliveryIntentState.pending.rawValue), to: statement, index: 2)
        var result: [PersistedDeliveryIntent] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                result.append(try decodeIntent(statement))
            case SQLITE_DONE:
                return result
            default:
                throw currentSQLiteError(operation: "load_pending_intents")
            }
        }
    }

    private func decodeMessage(_ statement: OpaquePointer) throws -> PersistedMessageRecord {
        guard let id = UUID(uuidString: requiredTextColumn(statement, index: 0)),
              let fingerprint = textColumn(statement, index: 1),
              let direction = PersistedMessageDirection(
                  rawValue: Int32(sqlite3_column_int(statement, 3))
              ),
              let text = textColumn(statement, index: 4),
              let deliveryState = PersistedMessageDeliveryState(
                  rawValue: Int32(sqlite3_column_int(statement, 6))
              ) else {
            throw DeviceMessagingRepositoryError.invalidRecord(
                reasonCode: "invalid_message_row"
            )
        }
        let record = PersistedMessageRecord(
            id: id,
            conversationFingerprint: fingerprint,
            targetDeviceID: textColumn(statement, index: 2),
            direction: direction,
            text: text,
            timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
            deliveryState: deliveryState
        )
        try validateMessage(record)
        return record
    }

    private func decodeIntent(_ statement: OpaquePointer) throws -> PersistedDeliveryIntent {
        guard let queueID = textColumn(statement, index: 0),
              let messageID = UUID(uuidString: requiredTextColumn(statement, index: 1)),
              let targetDeviceID = textColumn(statement, index: 2),
              let messageType = textColumn(statement, index: 3),
              let payload = blobColumn(statement, index: 5),
              let state = PersistedDeliveryIntentState(
                  rawValue: Int32(sqlite3_column_int(statement, 8))
              ) else {
            throw DeviceMessagingRepositoryError.invalidRecord(
                reasonCode: "invalid_delivery_intent_row"
            )
        }
        let claimRaw = sqlite3_column_int64(statement, 13)
        guard claimRaw >= 0 else {
            throw DeviceMessagingRepositoryError.invalidRecord(
                reasonCode: "invalid_claim_generation"
            )
        }
        let record = PersistedDeliveryIntent(
            queueID: queueID,
            messageID: messageID,
            targetDeviceID: targetDeviceID,
            messageType: messageType,
            priority: Int(sqlite3_column_int64(statement, 4)),
            payload: payload,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
            expiresAt: optionalDateColumn(statement, index: 7),
            state: state,
            retryCount: Int(sqlite3_column_int64(statement, 9)),
            lastAttemptAt: optionalDateColumn(statement, index: 10),
            receiptDeadline: optionalDateColumn(statement, index: 11),
            failureCode: textColumn(statement, index: 12),
            claimGeneration: UInt64(claimRaw)
        )
        try validateIntent(record)
        return record
    }

    // MARK: - Row mutations

    private func insertMessage(_ message: PersistedMessageRecord) throws {
        let statement = try prepare(
            """
            INSERT INTO messages(
                message_id, conversation_fingerprint, target_device_id,
                direction, text, timestamp, delivery_state
            ) VALUES(?, ?, ?, ?, ?, ?, ?)
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(canonicalUUID(message.id), to: statement, index: 1)
        try bind(message.conversationFingerprint, to: statement, index: 2)
        try bind(message.targetDeviceID, to: statement, index: 3)
        try bind(Int(message.direction.rawValue), to: statement, index: 4)
        try bind(message.text, to: statement, index: 5)
        try bind(message.timestamp.timeIntervalSince1970, to: statement, index: 6)
        try bind(Int(message.deliveryState.rawValue), to: statement, index: 7)
        try stepDone(statement, operation: "insert_message")
    }

    private func insertIntent(
        _ intent: PersistedDeliveryIntent,
        claimOwner: UUID?
    ) throws {
        let claimIdentity = try persistedClaimIdentity(for: claimOwner)
        let statement = try prepare(
            """
            INSERT INTO delivery_intents(
                queue_id, message_id, target_device_id, message_type,
                priority, payload, created_at, expires_at, state,
                retry_count, last_attempt_at, receipt_deadline,
                failure_code, claim_owner, claim_process_id,
                claim_instance_id, claim_generation
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(intent.queueID, to: statement, index: 1)
        try bind(canonicalUUID(intent.messageID), to: statement, index: 2)
        try bind(intent.targetDeviceID, to: statement, index: 3)
        try bind(intent.messageType, to: statement, index: 4)
        try bind(intent.priority, to: statement, index: 5)
        try bind(intent.payload, to: statement, index: 6)
        try bind(intent.createdAt.timeIntervalSince1970, to: statement, index: 7)
        try bind(intent.expiresAt?.timeIntervalSince1970, to: statement, index: 8)
        try bind(Int(intent.state.rawValue), to: statement, index: 9)
        try bind(intent.retryCount, to: statement, index: 10)
        try bind(intent.lastAttemptAt?.timeIntervalSince1970, to: statement, index: 11)
        try bind(intent.receiptDeadline?.timeIntervalSince1970, to: statement, index: 12)
        try bind(intent.failureCode, to: statement, index: 13)
        try bind(claimOwner.map(canonicalUUID), to: statement, index: 14)
        try bind(claimIdentity?.processIdentifier, to: statement, index: 15)
        try bind(claimIdentity?.instanceIdentifier, to: statement, index: 16)
        try bind(Int64(intent.claimGeneration), to: statement, index: 17)
        try stepDone(statement, operation: "insert_delivery_intent")
    }

    private func updateIntent(
        _ intent: PersistedDeliveryIntent,
        claimOwner: UUID?
    ) throws {
        let claimIdentity = try persistedClaimIdentity(for: claimOwner)
        let statement = try prepare(
            """
            UPDATE delivery_intents
               SET target_device_id = ?, message_type = ?, priority = ?,
                   payload = ?, created_at = ?, expires_at = ?, state = ?,
                   retry_count = ?, last_attempt_at = ?, receipt_deadline = ?,
                   failure_code = ?, claim_owner = ?, claim_process_id = ?,
                   claim_instance_id = ?, claim_generation = ?
             WHERE queue_id = ? AND message_id = ?
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(intent.targetDeviceID, to: statement, index: 1)
        try bind(intent.messageType, to: statement, index: 2)
        try bind(intent.priority, to: statement, index: 3)
        try bind(intent.payload, to: statement, index: 4)
        try bind(intent.createdAt.timeIntervalSince1970, to: statement, index: 5)
        try bind(intent.expiresAt?.timeIntervalSince1970, to: statement, index: 6)
        try bind(Int(intent.state.rawValue), to: statement, index: 7)
        try bind(intent.retryCount, to: statement, index: 8)
        try bind(intent.lastAttemptAt?.timeIntervalSince1970, to: statement, index: 9)
        try bind(intent.receiptDeadline?.timeIntervalSince1970, to: statement, index: 10)
        try bind(intent.failureCode, to: statement, index: 11)
        try bind(claimOwner.map(canonicalUUID), to: statement, index: 12)
        try bind(claimIdentity?.processIdentifier, to: statement, index: 13)
        try bind(claimIdentity?.instanceIdentifier, to: statement, index: 14)
        try bind(Int64(intent.claimGeneration), to: statement, index: 15)
        try bind(intent.queueID, to: statement, index: 16)
        try bind(canonicalUUID(intent.messageID), to: statement, index: 17)
        try stepDone(statement, operation: "update_delivery_intent")
        guard sqlite3_changes(requiredDatabase()) == 1 else {
            throw DeviceMessagingRepositoryError.intentNotFound(intent.queueID)
        }
    }

    private func persistedClaimIdentity(
        for claimOwner: UUID?
    ) throws -> (processIdentifier: String, instanceIdentifier: String)? {
        guard claimOwner != nil else { return nil }
        guard let processLease else {
            throw DeviceMessagingRepositoryError.notBootstrapped
        }
        return (
            canonicalUUID(processLease.processIdentifier),
            canonicalUUID(processLease.instanceIdentifier)
        )
    }

    /// Returns the post-update row so callers can report the exact projected
    /// record in a change without a full snapshot read.
    @discardableResult
    private func updateMessageState(
        id: UUID,
        state: PersistedMessageDeliveryState,
        expectedDirection: PersistedMessageDirection
    ) throws -> PersistedMessageRecord {
        let statement = try prepare(
            "UPDATE messages SET delivery_state = ? WHERE message_id = ? AND direction = ?"
        )
        defer { sqlite3_finalize(statement) }
        try bind(Int(state.rawValue), to: statement, index: 1)
        try bind(canonicalUUID(id), to: statement, index: 2)
        try bind(Int(expectedDirection.rawValue), to: statement, index: 3)
        try stepDone(statement, operation: "update_message_state")
        guard sqlite3_changes(requiredDatabase()) == 1,
              let updated = try loadMessage(id: id) else {
            throw DeviceMessagingRepositoryError.messageNotFound(id)
        }
        return updated
    }

    private func deleteIntent(queueID: String) throws {
        let statement = try prepare("DELETE FROM delivery_intents WHERE queue_id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(queueID, to: statement, index: 1)
        try stepDone(statement, operation: "delete_delivery_intent")
        guard sqlite3_changes(requiredDatabase()) == 1 else {
            throw DeviceMessagingRepositoryError.intentNotFound(queueID)
        }
    }

    private func removeCancelledDelivery(
        _ intent: PersistedDeliveryIntent,
        into collector: inout RepositoryChangeCollector
    ) throws {
        switch intent.state {
        case .pending:
            guard let message = try loadMessage(id: intent.messageID) else {
                throw DeviceMessagingRepositoryError.messageNotFound(intent.messageID)
            }
            let statement = try prepare(
                "DELETE FROM messages WHERE message_id = ? AND direction = ?"
            )
            defer { sqlite3_finalize(statement) }
            try bind(canonicalUUID(intent.messageID), to: statement, index: 1)
            try bind(Int(PersistedMessageDirection.outgoing.rawValue), to: statement, index: 2)
            try stepDone(statement, operation: "delete_cancelled_pending_message")
            guard sqlite3_changes(requiredDatabase()) == 1 else {
                throw DeviceMessagingRepositoryError.messageNotFound(intent.messageID)
            }
            // ON DELETE CASCADE removes the paired delivery intent atomically.
            collector.removeMessage(
                id: message.id,
                conversationFingerprint: message.conversationFingerprint
            )
            collector.removeIntent(queueID: intent.queueID)
        case .failed:
            try deleteIntent(queueID: intent.queueID)
            collector.removeIntent(queueID: intent.queueID)
        case .sending, .awaitingReceipt:
            throw DeviceMessagingRepositoryError.invalidRecord(
                reasonCode: "in_flight_delivery_prevents_cancel"
            )
        }
    }

    private func insertMigrationIssue(_ issue: MessageRepositoryMigrationIssue) throws {
        let statement = try prepare(
            """
            INSERT INTO migration_issues(issue_id, source_id, message_id, reason_code)
            VALUES(?, ?, ?, ?)
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(canonicalUUID(issue.id), to: statement, index: 1)
        try bind(issue.sourceID, to: statement, index: 2)
        try bind(issue.messageID.map(canonicalUUID), to: statement, index: 3)
        try bind(issue.reasonCode, to: statement, index: 4)
        try stepDone(statement, operation: "insert_migration_issue")
    }

    private func insertReceiptConfirmation(
        _ receipt: AuthenticatedMessageReceipt
    ) throws {
        let statement = try prepare(
            """
            INSERT INTO receipt_confirmations(
                message_id, delivery_attempt_id, received_at
            ) VALUES(?, ?, ?)
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(canonicalUUID(receipt.messageID), to: statement, index: 1)
        try bind(canonicalUUID(receipt.deliveryAttemptID), to: statement, index: 2)
        try bind(receipt.receivedAt.timeIntervalSince1970, to: statement, index: 3)
        try stepDone(statement, operation: "insert_receipt_confirmation")
    }

    private func recoverInterruptedClaims() throws -> Int {
        try withTransaction(mode: "IMMEDIATE") {
            // Bootstrap discards the collector: its caller returns a full
            // snapshot that already contains every recovered row.
            var collector = RepositoryChangeCollector()
            return try recoverInterruptedClaimsWithinTransaction(into: &collector)
        }
    }

    private func recoverInterruptedClaimsWithinTransaction(
        into collector: inout RepositoryChangeCollector
    ) throws -> Int {
        guard let processLease, let processLockPath else {
            throw DeviceMessagingRepositoryError.notBootstrapped
        }
        let candidates = try prepare(
            """
            SELECT queue_id, claim_process_id, claim_instance_id
              FROM delivery_intents
             WHERE state = ?
             ORDER BY queue_id
            """
        )
        defer { sqlite3_finalize(candidates) }
        try bind(
            Int(PersistedDeliveryIntentState.sending.rawValue),
            to: candidates,
            index: 1
        )
        var interruptedQueueIDs: [String] = []
        loadCandidates: while true {
            switch sqlite3_step(candidates) {
            case SQLITE_ROW:
                guard let queueID = textColumn(candidates, index: 0),
                      let processID = textColumn(candidates, index: 1)
                        .flatMap(UUID.init(uuidString:)),
                      let instanceID = textColumn(candidates, index: 2)
                        .flatMap(UUID.init(uuidString:)) else {
                    throw DeviceMessagingRepositoryError.invalidRecord(
                        reasonCode: "missing_persisted_claim_identity"
                    )
                }
                let isLive = SQLiteRepositoryProcessCoordinator.shared.isLive(
                    lockPath: processLockPath,
                    processIdentifier: processID,
                    instanceIdentifier: instanceID
                )
                if processID != processLease.processIdentifier || !isLive {
                    interruptedQueueIDs.append(queueID)
                }
            case SQLITE_DONE:
                break loadCandidates
            default:
                throw currentSQLiteError(operation: "load_interrupted_claims")
            }
        }

        for queueID in interruptedQueueIDs {
            let recovery = try prepare(
                """
                UPDATE delivery_intents
                   SET state = ?, claim_owner = NULL,
                       claim_process_id = NULL, claim_instance_id = NULL,
                       receipt_deadline = NULL
                 WHERE queue_id = ? AND state = ?
                """
            )
            defer { sqlite3_finalize(recovery) }
            try bind(
                Int(PersistedDeliveryIntentState.pending.rawValue),
                to: recovery,
                index: 1
            )
            try bind(queueID, to: recovery, index: 2)
            try bind(
                Int(PersistedDeliveryIntentState.sending.rawValue),
                to: recovery,
                index: 3
            )
            try stepDone(recovery, operation: "recover_interrupted_claim")
            guard sqlite3_changes(requiredDatabase()) == 1,
                  let recovered = try loadIntentWithOwner(queueID: queueID)?.intent else {
                throw DeviceMessagingRepositoryError.invalidRecord(
                    reasonCode: "interrupted_claim_recovery_conflict"
                )
            }
            collector.upsert(recovered)
        }
        let changed = interruptedQueueIDs.count
        if changed > 0 { try advanceGeneration() }
        return changed
    }

    private func messageExists(_ id: UUID) throws -> Bool {
        try scalarInt(
            "SELECT COUNT(*) FROM messages WHERE message_id = ?",
            bindings: [.text(canonicalUUID(id))]
        ) == 1
    }

    private func intentExists(queueID: String) throws -> Bool {
        try scalarInt(
            "SELECT COUNT(*) FROM delivery_intents WHERE queue_id = ?",
            bindings: [.text(queueID)]
        ) == 1
    }

    private func admitDeliveryIntent(
        targetDeviceID: String,
        admissionTime: Date,
        into collector: inout RepositoryChangeCollector
    ) throws {
        try expirePendingDeliveryIntents(asOf: admissionTime, into: &collector)
        let activeTotal = try scalarInt(
            "SELECT COUNT(*) FROM delivery_intents WHERE state IN (0, 1, 2)",
            bindings: []
        )
        let activeForDevice = try scalarInt(
            """
            SELECT COUNT(*) FROM delivery_intents
             WHERE target_device_id = ? AND state IN (0, 1, 2)
            """,
            bindings: [.text(targetDeviceID)]
        )
        guard activeTotal < Self.maximumActiveDeliveryIntents,
              activeForDevice < Self.maximumActiveDeliveryIntentsPerDevice else {
            throw DeviceMessagingRepositoryError.invalidRecord(
                reasonCode: "delivery_intent_capacity_exceeded"
            )
        }
    }

    /// Expiry is evaluated against the admitted intent's creation time so the
    /// whole admission decision is deterministic and replayable during tests
    /// or migration. Expired rows remain visible as failed history but no
    /// longer consume active global/per-device queue capacity.
    private func expirePendingDeliveryIntents(
        asOf now: Date,
        into collector: inout RepositoryChangeCollector
    ) throws {
        // The affected set is fixed before the bulk updates run; nothing can
        // interleave inside the surrounding IMMEDIATE transaction.
        let expiring = try loadIntents(
            where: "state = ? AND expires_at IS NOT NULL AND expires_at < ?",
            bindings: [
                .integer(Int(PersistedDeliveryIntentState.pending.rawValue)),
                .double(now.timeIntervalSince1970),
            ]
        )
        guard !expiring.isEmpty else { return }

        let messages = try prepare(
            """
            UPDATE messages
               SET delivery_state = ?
             WHERE message_id IN (
                    SELECT message_id
                      FROM delivery_intents
                     WHERE state = ? AND expires_at IS NOT NULL AND expires_at < ?
             )
            """
        )
        defer { sqlite3_finalize(messages) }
        try bind(Int(PersistedMessageDeliveryState.failed.rawValue), to: messages, index: 1)
        try bind(Int(PersistedDeliveryIntentState.pending.rawValue), to: messages, index: 2)
        try bind(now.timeIntervalSince1970, to: messages, index: 3)
        try stepDone(messages, operation: "expire_pending_messages_for_admission")

        let intents = try prepare(
            """
            UPDATE delivery_intents
               SET state = ?, last_attempt_at = ?, failure_code = ?
             WHERE state = ? AND expires_at IS NOT NULL AND expires_at < ?
            """
        )
        defer { sqlite3_finalize(intents) }
        try bind(Int(PersistedDeliveryIntentState.failed.rawValue), to: intents, index: 1)
        try bind(now.timeIntervalSince1970, to: intents, index: 2)
        try bind("message_expired", to: intents, index: 3)
        try bind(Int(PersistedDeliveryIntentState.pending.rawValue), to: intents, index: 4)
        try bind(now.timeIntervalSince1970, to: intents, index: 5)
        try stepDone(intents, operation: "expire_pending_intents_for_admission")

        for expired in expiring {
            guard let updatedIntent = try loadIntentWithOwner(
                queueID: expired.queueID
            )?.intent,
                  let updatedMessage = try loadMessage(id: expired.messageID) else {
                throw DeviceMessagingRepositoryError.intentNotFound(expired.queueID)
            }
            collector.upsert(updatedIntent)
            collector.upsert(updatedMessage)
        }
        try compactFailedDeliveryIntents(into: &collector)
    }

    private func makeRoomForMessage(
        in conversationFingerprint: String,
        into collector: inout RepositoryChangeCollector
    ) throws {
        let currentCount = try scalarInt(
            "SELECT COUNT(*) FROM messages WHERE conversation_fingerprint = ?",
            bindings: [.text(conversationFingerprint)]
        )
        guard currentCount >= Self.maximumMessagesPerConversation else { return }
        let requiredRemovalCount = currentCount - Self.maximumMessagesPerConversation + 1
        let removals = try loadEvictableTerminalMessages(
            conversationFingerprint: conversationFingerprint,
            limit: requiredRemovalCount
        )
        guard removals.count == requiredRemovalCount else {
            throw DeviceMessagingRepositoryError.invalidRecord(
                reasonCode: "conversation_capacity_exceeded"
            )
        }
        try evictTerminalMessages(removals, into: &collector)
    }

    /// Fully terminal, intent-free rows in deterministic eviction order.
    /// Passing nil scans every conversation for the global bound.
    private func loadEvictableTerminalMessages(
        conversationFingerprint: String?,
        limit: Int
    ) throws -> [MessageRepositoryMessageRemoval] {
        guard limit > 0 else { return [] }
        let conversationFilter = conversationFingerprint == nil
            ? ""
            : "AND message.conversation_fingerprint = ?"
        let statement = try prepare(
            """
            SELECT message.message_id, message.conversation_fingerprint
              FROM messages AS message
             WHERE message.delivery_state IN (2, 3)
               \(conversationFilter)
               AND NOT EXISTS (
                    SELECT 1 FROM delivery_intents AS intent
                     WHERE intent.message_id = message.message_id
               )
             ORDER BY message.timestamp, message.message_id
             LIMIT ?
            """
        )
        defer { sqlite3_finalize(statement) }
        if let conversationFingerprint {
            try bind(conversationFingerprint, to: statement, index: 1)
            try bind(limit, to: statement, index: 2)
        } else {
            try bind(limit, to: statement, index: 1)
        }
        var removals: [MessageRepositoryMessageRemoval] = []
        loadRemovableMessages: while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let rawID = textColumn(statement, index: 0),
                      let messageID = UUID(uuidString: rawID),
                      let fingerprint = textColumn(statement, index: 1) else {
                    throw DeviceMessagingRepositoryError.invalidRecord(
                        reasonCode: "invalid_persisted_message_id"
                    )
                }
                removals.append(MessageRepositoryMessageRemoval(
                    id: messageID,
                    conversationFingerprint: fingerprint
                ))
            case SQLITE_DONE:
                break loadRemovableMessages
            default:
                throw currentSQLiteError(operation: "load_capacity_evictions")
            }
        }
        return removals
    }

    private func evictTerminalMessages(
        _ removals: [MessageRepositoryMessageRemoval],
        into collector: inout RepositoryChangeCollector
    ) throws {
        for removal in removals {
            let deletion = try prepare("DELETE FROM messages WHERE message_id = ?")
            defer { sqlite3_finalize(deletion) }
            try bind(canonicalUUID(removal.id), to: deletion, index: 1)
            try stepDone(deletion, operation: "evict_terminal_message")
            guard sqlite3_changes(requiredDatabase()) == 1 else {
                throw DeviceMessagingRepositoryError.invalidRecord(
                    reasonCode: "capacity_eviction_conflict"
                )
            }
            collector.removeMessage(
                id: removal.id,
                conversationFingerprint: removal.conversationFingerprint
            )
        }
    }

    /// Enforces the global conversation-count and total-row bounds before one
    /// new message row is admitted. Whole conversations are evicted least
    /// recently active first, and only when every row in them is terminal and
    /// intent-free; single terminal rows across all conversations absorb the
    /// total-row bound. An unmeetable bound fails the write closed.
    private func compactGlobalMessageHistory(
        admitting message: PersistedMessageRecord,
        into collector: inout RepositoryChangeCollector
    ) throws -> (evictedConversations: Int, evictedMessages: Int) {
        var evictedConversations = 0
        let conversationExists = try scalarInt(
            "SELECT COUNT(*) FROM messages WHERE conversation_fingerprint = ?",
            bindings: [.text(message.conversationFingerprint)]
        ) > 0
        if !conversationExists {
            let conversationCount = try scalarInt(
                "SELECT COUNT(DISTINCT conversation_fingerprint) FROM messages",
                bindings: []
            )
            if conversationCount >= Self.maximumConversations {
                evictedConversations = try evictOldestTerminalConversations(
                    count: conversationCount - Self.maximumConversations + 1,
                    into: &collector
                )
            }
        }
        var evictedMessages = 0
        let totalRows = try scalarInt("SELECT COUNT(*) FROM messages", bindings: [])
        if totalRows >= Self.maximumTotalMessageRows {
            let required = totalRows - Self.maximumTotalMessageRows + 1
            let removals = try loadEvictableTerminalMessages(
                conversationFingerprint: nil,
                limit: required
            )
            guard removals.count == required else {
                throw DeviceMessagingRepositoryError.invalidRecord(
                    reasonCode: "global_message_capacity_exceeded"
                )
            }
            try evictTerminalMessages(removals, into: &collector)
            evictedMessages = removals.count
        }
        return (evictedConversations, evictedMessages)
    }

    /// Conversations whose imported row count exceeds the per-conversation
    /// bound, in deterministic order. Only legacy migration can produce these;
    /// runtime writes enforce the bound before every insert.
    private func loadOverCapacityConversations() throws
        -> [(fingerprint: String, rowCount: Int)] {
        let statement = try prepare(
            """
            SELECT conversation_fingerprint, COUNT(*)
              FROM messages
             GROUP BY conversation_fingerprint
            HAVING COUNT(*) > ?
             ORDER BY conversation_fingerprint
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(Self.maximumMessagesPerConversation, to: statement, index: 1)
        var overflowing: [(fingerprint: String, rowCount: Int)] = []
        loadOverflowingConversations: while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                overflowing.append((
                    fingerprint: requiredTextColumn(statement, index: 0),
                    rowCount: Int(sqlite3_column_int64(statement, 1))
                ))
            case SQLITE_DONE:
                break loadOverflowingConversations
            default:
                throw currentSQLiteError(operation: "load_over_capacity_conversations")
            }
        }
        return overflowing
    }

    /// Least-recently-active conversations in which every message is terminal
    /// and no delivery intent (active or failed) references any row.
    private func loadEvictableConversationFingerprints(limit: Int) throws -> [String] {
        guard limit > 0 else { return [] }
        let statement = try prepare(
            """
            SELECT candidate.conversation_fingerprint
              FROM messages AS candidate
             GROUP BY candidate.conversation_fingerprint
            HAVING SUM(CASE WHEN candidate.delivery_state IN (0, 1) THEN 1 ELSE 0 END) = 0
               AND NOT EXISTS (
                    SELECT 1
                      FROM delivery_intents AS intent
                      JOIN messages AS referenced
                        ON referenced.message_id = intent.message_id
                     WHERE referenced.conversation_fingerprint
                           = candidate.conversation_fingerprint
               )
             ORDER BY MAX(candidate.timestamp), candidate.conversation_fingerprint
             LIMIT ?
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(limit, to: statement, index: 1)
        var fingerprints: [String] = []
        loadEvictableConversations: while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                fingerprints.append(requiredTextColumn(statement, index: 0))
            case SQLITE_DONE:
                break loadEvictableConversations
            default:
                throw currentSQLiteError(operation: "load_evictable_conversations")
            }
        }
        return fingerprints
    }

    /// Evicts exactly `count` least-recently-active fully terminal
    /// conversations. Anything less evictable fails the write closed.
    @discardableResult
    private func evictOldestTerminalConversations(
        count: Int,
        into collector: inout RepositoryChangeCollector
    ) throws -> Int {
        guard count > 0 else { return 0 }
        let fingerprints = try loadEvictableConversationFingerprints(limit: count)
        guard fingerprints.count == count else {
            throw DeviceMessagingRepositoryError.invalidRecord(
                reasonCode: "global_conversation_capacity_exceeded"
            )
        }
        try evictConversations(fingerprints, into: &collector)
        return fingerprints.count
    }

    private func evictConversations(
        _ fingerprints: [String],
        into collector: inout RepositoryChangeCollector
    ) throws {
        for fingerprint in fingerprints {
            let members = try prepare(
                "SELECT message_id FROM messages WHERE conversation_fingerprint = ?"
            )
            defer { sqlite3_finalize(members) }
            try bind(fingerprint, to: members, index: 1)
            var memberIDs: [UUID] = []
            loadMembers: while true {
                switch sqlite3_step(members) {
                case SQLITE_ROW:
                    guard let memberID = UUID(
                        uuidString: requiredTextColumn(members, index: 0)
                    ) else {
                        throw DeviceMessagingRepositoryError.invalidRecord(
                            reasonCode: "invalid_persisted_message_id"
                        )
                    }
                    memberIDs.append(memberID)
                case SQLITE_DONE:
                    break loadMembers
                default:
                    throw currentSQLiteError(operation: "load_evicted_conversation_members")
                }
            }
            let deletion = try prepare(
                "DELETE FROM messages WHERE conversation_fingerprint = ?"
            )
            defer { sqlite3_finalize(deletion) }
            try bind(fingerprint, to: deletion, index: 1)
            try stepDone(deletion, operation: "evict_terminal_conversation")
            guard sqlite3_changes(requiredDatabase()) == memberIDs.count else {
                throw DeviceMessagingRepositoryError.invalidRecord(
                    reasonCode: "capacity_eviction_conflict"
                )
            }
            for memberID in memberIDs {
                collector.removeMessage(
                    id: memberID,
                    conversationFingerprint: fingerprint
                )
            }
        }
    }

    /// Bounds retained failed intents. The oldest failed intents are deleted
    /// first; their failed messages stay visible as history and become
    /// evictable by the message bounds afterwards.
    @discardableResult
    private func compactFailedDeliveryIntents(
        into collector: inout RepositoryChangeCollector
    ) throws -> Int {
        let failedState = Int(PersistedDeliveryIntentState.failed.rawValue)
        let failedCount = try scalarInt(
            "SELECT COUNT(*) FROM delivery_intents WHERE state = ?",
            bindings: [.integer(failedState)]
        )
        guard failedCount > Self.maximumFailedDeliveryIntents else { return 0 }
        let excess = failedCount - Self.maximumFailedDeliveryIntents
        let statement = try prepare(
            """
            SELECT queue_id FROM delivery_intents
             WHERE state = ?
             ORDER BY created_at, queue_id
             LIMIT ?
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(failedState, to: statement, index: 1)
        try bind(excess, to: statement, index: 2)
        var queueIDs: [String] = []
        loadCompactableIntents: while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                queueIDs.append(requiredTextColumn(statement, index: 0))
            case SQLITE_DONE:
                break loadCompactableIntents
            default:
                throw currentSQLiteError(operation: "load_compactable_failed_intents")
            }
        }
        guard queueIDs.count == excess else {
            throw DeviceMessagingRepositoryError.invalidRecord(
                reasonCode: "capacity_eviction_conflict"
            )
        }
        for queueID in queueIDs {
            try deleteIntent(queueID: queueID)
            collector.removeIntent(queueID: queueID)
        }
        return queueIDs.count
    }

    // MARK: - Validation

    private func validateMessage(_ message: PersistedMessageRecord) throws {
        try validateConversationFingerprint(
            message.conversationFingerprint,
            reasonCode: "invalid_conversation_fingerprint"
        )
        if let targetDeviceID = message.targetDeviceID {
            try validateIdentifier(targetDeviceID, reasonCode: "invalid_target_device_id")
        }
        guard !message.text.isEmpty,
              message.text.utf8.count <= Self.maximumTextBytes,
              !message.text.unicodeScalars.contains(where: { $0.value == 0 }),
              message.timestamp.timeIntervalSince1970.isFinite else {
            throw DeviceMessagingRepositoryError.invalidRecord(
                reasonCode: "invalid_message_content"
            )
        }
        switch message.direction {
        case .incoming:
            guard message.targetDeviceID == nil,
                  message.deliveryState == .delivered else {
                throw DeviceMessagingRepositoryError.invalidRecord(
                    reasonCode: "invalid_incoming_state"
                )
            }
        case .outgoing:
            guard message.targetDeviceID != nil || message.deliveryState != .pending else {
                throw DeviceMessagingRepositoryError.invalidRecord(
                    reasonCode: "invalid_outgoing_state"
                )
            }
        }
    }

    private func validateIntent(_ intent: PersistedDeliveryIntent) throws {
        try validateIdentifier(intent.queueID, reasonCode: "invalid_queue_id")
        try validateIdentifier(intent.targetDeviceID, reasonCode: "invalid_target_device_id")
        try validateIdentifier(intent.messageType, reasonCode: "invalid_message_type")
        guard let parsedQueueID = UUID(uuidString: intent.queueID) else {
            throw DeviceMessagingRepositoryError.invalidRecord(
                reasonCode: "invalid_queue_id"
            )
        }
        guard intent.queueID == canonicalUUID(parsedQueueID) else {
            throw DeviceMessagingRepositoryError.invalidRecord(
                reasonCode: "noncanonical_queue_id"
            )
        }
        guard intent.messageType == "text" else {
            throw DeviceMessagingRepositoryError.invalidRecord(
                reasonCode: "unsupported_delivery_intent_contract"
            )
        }
        try validateDate(intent.createdAt, reasonCode: "invalid_intent_created_at")
        if let expiresAt = intent.expiresAt {
            try validateDate(expiresAt, reasonCode: "invalid_intent_expiry")
            guard expiresAt >= intent.createdAt else {
                throw DeviceMessagingRepositoryError.invalidRecord(
                    reasonCode: "intent_expiry_precedes_creation"
                )
            }
        }
        if let lastAttemptAt = intent.lastAttemptAt {
            try validateDate(lastAttemptAt, reasonCode: "invalid_last_attempt_at")
        }
        if let receiptDeadline = intent.receiptDeadline {
            try validateDate(receiptDeadline, reasonCode: "invalid_receipt_deadline")
        }
        if let failureCode = intent.failureCode {
            try validateFailureCode(failureCode)
        }
        guard !intent.payload.isEmpty,
              intent.payload.count <= Self.maximumPayloadBytes,
              (0...3).contains(intent.priority),
              intent.retryCount >= 0,
              intent.claimGeneration <= UInt64(Int64.max) else {
            throw DeviceMessagingRepositoryError.invalidRecord(
                reasonCode: "invalid_delivery_intent"
            )
        }
        switch intent.state {
        case .pending:
            guard intent.receiptDeadline == nil else {
                throw DeviceMessagingRepositoryError.invalidRecord(
                    reasonCode: "pending_intent_has_receipt_deadline"
                )
            }
        case .sending:
            guard intent.lastAttemptAt != nil,
                  intent.receiptDeadline == nil,
                  intent.claimGeneration > 0 else {
                throw DeviceMessagingRepositoryError.invalidRecord(
                    reasonCode: "invalid_sending_intent"
                )
            }
        case .awaitingReceipt:
            guard intent.lastAttemptAt != nil,
                  intent.receiptDeadline != nil,
                  intent.claimGeneration > 0 else {
                throw DeviceMessagingRepositoryError.invalidRecord(
                    reasonCode: "invalid_awaiting_receipt_intent"
                )
            }
        case .failed:
            guard intent.failureCode != nil else {
                throw DeviceMessagingRepositoryError.invalidRecord(
                    reasonCode: "failed_intent_missing_reason"
                )
            }
        }
    }

    private func validateRetryPolicy(_ policy: MessageDeliveryRetryPolicy) throws {
        guard policy.maximumRetryCount > 0,
              policy.retryInterval.isFinite,
              policy.retryInterval > 0,
              policy.backoffFactor.isFinite,
              policy.backoffFactor >= 1 else {
            throw DeviceMessagingRepositoryError.invalidRecord(
                reasonCode: "invalid_retry_policy"
            )
        }
    }

    private func validateIdentifier(_ value: String, reasonCode: String) throws {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.utf8.count <= Self.maximumIdentifierBytes,
              !value.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw DeviceMessagingRepositoryError.invalidRecord(reasonCode: reasonCode)
        }
    }

    private func validateConversationFingerprint(
        _ value: String,
        reasonCode: String
    ) throws {
        guard isLowercaseHexDigest(value) else {
            throw DeviceMessagingRepositoryError.invalidRecord(reasonCode: reasonCode)
        }
    }

    private func validateFailureCode(_ value: String) throws {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.utf8.count <= Self.maximumFailureCodeBytes,
              value.unicodeScalars.allSatisfy({ scalar in
                  scalar.isASCII
                      && ((scalar.value >= 0x61 && scalar.value <= 0x7a)
                          || (scalar.value >= 0x30 && scalar.value <= 0x39)
                          || scalar.value == 0x5f)
              }) else {
            throw DeviceMessagingRepositoryError.invalidRecord(
                reasonCode: "invalid_failure_code"
            )
        }
    }

    private func validateDate(_ value: Date, reasonCode: String) throws {
        guard value.timeIntervalSince1970.isFinite else {
            throw DeviceMessagingRepositoryError.invalidRecord(reasonCode: reasonCode)
        }
    }

    private func isLowercaseHexDigest(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.unicodeScalars.allSatisfy { scalar in
                (scalar.value >= 0x30 && scalar.value <= 0x39)
                    || (scalar.value >= 0x61 && scalar.value <= 0x66)
            }
    }

    // MARK: - Metadata and transaction helpers

    private func readGeneration() throws -> UInt64 {
        guard let raw = try metadataValue(for: "repository_generation"),
              let value = UInt64(raw),
              value <= UInt64(Int64.max) else {
            throw DeviceMessagingRepositoryError.invalidRecord(
                reasonCode: "invalid_repository_generation"
            )
        }
        return value
    }

    private func advanceGeneration() throws {
        let current = try readGeneration()
        let next = current.addingReportingOverflow(1)
        guard !next.overflow, next.partialValue <= UInt64(Int64.max) else {
            throw DeviceMessagingRepositoryError.invalidRecord(
                reasonCode: "repository_generation_overflow"
            )
        }
        try setMetadataValue(String(next.partialValue), for: "repository_generation")
    }

    private func metadataValue(for key: String) throws -> String? {
        let statement = try prepare("SELECT value FROM schema_metadata WHERE key = ?")
        defer { sqlite3_finalize(statement) }
        try bind(key, to: statement, index: 1)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return textColumn(statement, index: 0)
        case SQLITE_DONE:
            return nil
        default:
            throw currentSQLiteError(operation: "read_metadata")
        }
    }

    private func setMetadataValue(_ value: String, for key: String) throws {
        let statement = try prepare(
            """
            INSERT INTO schema_metadata(key, value) VALUES(?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(key, to: statement, index: 1)
        try bind(value, to: statement, index: 2)
        try stepDone(statement, operation: "write_metadata")
    }

    private func loadMigrationSources() throws -> [String: String] {
        let statement = try prepare(
            "SELECT source_id, content_digest FROM migration_sources ORDER BY source_id"
        )
        defer { sqlite3_finalize(statement) }
        var result: [String: String] = [:]
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let sourceID = textColumn(statement, index: 0),
                      let digest = textColumn(statement, index: 1),
                      result.updateValue(digest, forKey: sourceID) == nil else {
                    throw DeviceMessagingRepositoryError.legacySourceConflict(
                        "duplicate_migration_source"
                    )
                }
            case SQLITE_DONE:
                return result
            default:
                throw currentSQLiteError(operation: "load_migration_sources")
            }
        }
    }

    private func rowCount(table: String) throws -> Int {
        let allowed = [
            "messages", "delivery_intents", "migration_sources", "migration_issues"
        ]
        guard allowed.contains(table) else {
            throw DeviceMessagingRepositoryError.invalidRecord(
                reasonCode: "invalid_count_table"
            )
        }
        return try scalarInt("SELECT COUNT(*) FROM \(table)", bindings: [])
    }

    private enum ScalarBinding {
        case text(String)
        case integer(Int)
        case double(Double)
    }

    private func scalarInt(
        _ sql: String,
        bindings: [ScalarBinding]
    ) throws -> Int {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for (offset, binding) in bindings.enumerated() {
            switch binding {
            case .text(let value):
                try bind(value, to: statement, index: Int32(offset + 1))
            case .integer(let value):
                try bind(value, to: statement, index: Int32(offset + 1))
            case .double(let value):
                try bind(value, to: statement, index: Int32(offset + 1))
            }
        }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw currentSQLiteError(operation: "read_scalar")
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func withTransaction<Result>(
        mode: String,
        _ operation: () throws -> Result
    ) throws -> Result {
        guard ["DEFERRED", "IMMEDIATE", "EXCLUSIVE"].contains(mode) else {
            throw DeviceMessagingRepositoryError.invalidRecord(
                reasonCode: "invalid_transaction_mode"
            )
        }
        try execute("BEGIN \(mode)")
        var commitAttempted = false
        do {
            let result = try operation()
            commitAttempted = true
            try execute("COMMIT")
            return result
        } catch {
            if commitAttempted, sqlite3_get_autocommit(requiredDatabase()) != 0 {
                closeDatabase()
                throw DeviceMessagingRepositoryError.transactionOutcomeUnknown
            }
            do {
                try execute("ROLLBACK")
            } catch {
                closeDatabase()
            }
            throw error
        }
    }

    // MARK: - SQLite boundary

    private func requiredDatabase() -> OpaquePointer {
        guard let pointer = database?.pointer else {
            preconditionFailure("database must be open")
        }
        return pointer
    }

    private func requireBootstrapped() throws {
        guard isBootstrapped, database != nil else {
            throw DeviceMessagingRepositoryError.notBootstrapped
        }
    }

    private func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(requiredDatabase(), sql, nil, nil, &errorMessage)
        if let errorMessage {
            sqlite3_free(errorMessage)
        }
        guard code == SQLITE_OK else {
            throw sqliteError(operation: "execute", code: code)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(requiredDatabase(), sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else {
            throw sqliteError(operation: "prepare", code: code)
        }
        return statement
    }

    private func stepDone(_ statement: OpaquePointer, operation: String) throws {
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE else {
            if code & 0xff == SQLITE_CONSTRAINT {
                throw DeviceMessagingRepositoryError.invalidRecord(
                    reasonCode: "database_constraint"
                )
            }
            throw sqliteError(operation: operation, code: code)
        }
    }

    private func bind(_ value: String, to statement: OpaquePointer, index: Int32) throws {
        let code = value.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, Self.sqliteTransient)
        }
        guard code == SQLITE_OK else {
            throw sqliteError(operation: "bind_text", code: code)
        }
    }

    private func bind(_ value: String?, to statement: OpaquePointer, index: Int32) throws {
        guard let value else {
            let code = sqlite3_bind_null(statement, index)
            guard code == SQLITE_OK else {
                throw sqliteError(operation: "bind_null", code: code)
            }
            return
        }
        try bind(value, to: statement, index: index)
    }

    private func bind(_ value: Data, to statement: OpaquePointer, index: Int32) throws {
        let code = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(
                statement,
                index,
                bytes.baseAddress,
                Int32(bytes.count),
                Self.sqliteTransient
            )
        }
        guard code == SQLITE_OK else {
            throw sqliteError(operation: "bind_blob", code: code)
        }
    }

    private func bind(_ value: Int, to statement: OpaquePointer, index: Int32) throws {
        guard let exact = Int64(exactly: value) else {
            throw DeviceMessagingRepositoryError.invalidRecord(
                reasonCode: "integer_out_of_range"
            )
        }
        try bind(exact, to: statement, index: index)
    }

    private func bind(_ value: Int64, to statement: OpaquePointer, index: Int32) throws {
        let code = sqlite3_bind_int64(statement, index, value)
        guard code == SQLITE_OK else {
            throw sqliteError(operation: "bind_integer", code: code)
        }
    }

    private func bind(_ value: Double, to statement: OpaquePointer, index: Int32) throws {
        guard value.isFinite else {
            throw DeviceMessagingRepositoryError.invalidRecord(
                reasonCode: "non_finite_number"
            )
        }
        let code = sqlite3_bind_double(statement, index, value)
        guard code == SQLITE_OK else {
            throw sqliteError(operation: "bind_double", code: code)
        }
    }

    private func bind(_ value: Double?, to statement: OpaquePointer, index: Int32) throws {
        guard let value else {
            let code = sqlite3_bind_null(statement, index)
            guard code == SQLITE_OK else {
                throw sqliteError(operation: "bind_null", code: code)
            }
            return
        }
        try bind(value, to: statement, index: index)
    }

    private func textColumn(_ statement: OpaquePointer, index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: pointer)
    }

    private func requiredTextColumn(_ statement: OpaquePointer, index: Int32) -> String {
        textColumn(statement, index: index) ?? ""
    }

    private func blobColumn(_ statement: OpaquePointer, index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count >= 0 else { return nil }
        if count == 0 { return Data() }
        guard let pointer = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: pointer, count: count)
    }

    private func optionalDateColumn(_ statement: OpaquePointer, index: Int32) -> Date? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        let raw = sqlite3_column_double(statement, index)
        guard raw.isFinite else { return nil }
        return Date(timeIntervalSince1970: raw)
    }

    private func sqliteError(operation: String, code: Int32) -> DeviceMessagingRepositoryError {
        DeviceMessagingRepositoryError.sqliteFailure(operation: operation, code: code)
    }

    private func currentSQLiteError(operation: String) -> DeviceMessagingRepositoryError {
        sqliteError(operation: operation, code: sqlite3_errcode(requiredDatabase()))
    }

    private static let sqliteTransient = unsafeBitCast(
        -1,
        to: sqlite3_destructor_type.self
    )

    private func canonicalUUID(_ value: UUID) -> String {
        value.uuidString.lowercased()
    }

    private func applyFileProtection() throws {
        let fileManager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let path = databaseURL.path + suffix
            guard fileManager.fileExists(atPath: path) else { continue }
            try fileManager.setAttributes(Self.fileAttributes, ofItemAtPath: path)
        }
    }

    private static var directoryAttributes: [FileAttributeKey: Any] {
#if canImport(UIKit) && !os(macOS)
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
#else
        [.posixPermissions: 0o700]
#endif
    }

    private static var fileAttributes: [FileAttributeKey: Any] {
#if canImport(UIKit) && !os(macOS)
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
#else
        [.posixPermissions: 0o600]
#endif
    }
}
