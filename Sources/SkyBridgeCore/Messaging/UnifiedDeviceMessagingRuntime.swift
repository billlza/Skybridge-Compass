import Crypto
import Foundation
import SkyBridgeMessagePersistence
import SkyBridgeProtocolCore

@available(macOS 14.0, iOS 17.0, *)
actor UnifiedDeviceMessagingRuntime {
    static let shared = UnifiedDeviceMessagingRuntime()

    private enum LegacySourceLocation: Sendable {
        case file(URL)
        case userDefaults(key: String, archiveURL: URL)
    }

    private struct LoadedLegacySource<Value: Decodable & Sendable>: Sendable {
        let source: LegacyMessageSource
        let value: Value
        let rawData: Data
        let location: LegacySourceLocation
    }

    private let fileManager: FileManager
    private let defaults: UserDefaults
    private let rootURLOverride: URL?
    private var repository: SQLiteDeviceMessagingRepository?
    private var bootstrapTask: Task<MessageRepositorySnapshot, Error>?
    private var bootstrapAttemptID: UUID?

    init(
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard,
        rootURLOverride: URL? = nil
    ) {
        self.fileManager = fileManager
        self.defaults = defaults
        self.rootURLOverride = rootURLOverride
    }

    init(
        fileManager: FileManager = .default,
        defaultsSuiteName: String,
        rootURLOverride: URL? = nil
    ) throws {
        guard let defaults = UserDefaults(suiteName: defaultsSuiteName) else {
            throw DeviceMessagingRepositoryError.invalidRecord(
                reasonCode: "unavailable_user_defaults_suite"
            )
        }
        self.fileManager = fileManager
        self.defaults = defaults
        self.rootURLOverride = rootURLOverride
    }

    func bootstrap() async throws -> MessageRepositorySnapshot {
        if let repository {
            return try await repository.currentSnapshot()
        }
        if let bootstrapTask {
            return try await bootstrapTask.value
        }

        let rootURL = try rootURLOverride
            ?? Self.applicationSupportRoot(fileManager: fileManager)
        let migrationInput = try Self.makeMigrationInput(
            rootURL: rootURL,
            fileManager: fileManager,
            defaults: defaults
        )
        let repository = SQLiteDeviceMessagingRepository(
            databaseURL: rootURL
                .appendingPathComponent("Messaging", isDirectory: true)
                .appendingPathComponent("device-messaging.sqlite3", isDirectory: false)
        )
        let migration = migrationInput.migration
        let sources = migrationInput.sources
        let attemptID = UUID()
        bootstrapAttemptID = attemptID
        let task = Task.detached { [self] in
            do {
                let snapshot = try await repository.bootstrap(legacyMigration: migration)
                try await completeBootstrap(
                    attemptID: attemptID,
                    repository: repository,
                    sources: sources,
                    rootURL: rootURL
                )
                return snapshot
            } catch {
                await failBootstrap(attemptID: attemptID)
                throw error
            }
        }
        bootstrapTask = task
        return try await task.value
    }

    private func completeBootstrap(
        attemptID: UUID,
        repository: SQLiteDeviceMessagingRepository,
        sources: [AnyLoadedLegacySource],
        rootURL: URL
    ) throws {
        guard self.repository == nil,
              bootstrapAttemptID == attemptID else {
            throw DeviceMessagingRepositoryError.invalidRecord(
                reasonCode: "superseded_bootstrap_attempt"
            )
        }
        try Self.archiveCommittedSources(
            sources,
            rootURL: rootURL,
            fileManager: fileManager,
            defaults: defaults
        )
        self.repository = repository
        bootstrapTask = nil
        bootstrapAttemptID = nil
    }

    private func failBootstrap(attemptID: UUID) {
        guard bootstrapAttemptID == attemptID else { return }
        bootstrapTask = nil
        bootstrapAttemptID = nil
    }

    func currentSnapshot() async throws -> MessageRepositorySnapshot {
        let repository = try await requiredRepository()
        return try await repository.currentSnapshot()
    }

    func stageOutgoing(
        message: PersistedMessageRecord,
        intent: PersistedDeliveryIntent
    ) async throws -> MessageRepositoryChange {
        let repository = try await requiredRepository()
        return try await repository.stageOutgoing(message: message, intent: intent)
    }

    func recordIncoming(
        _ message: PersistedMessageRecord
    ) async throws -> MessageRepositoryChange {
        let repository = try await requiredRepository()
        return try await repository.recordIncoming(message)
    }

    func claim(
        messageID: UUID,
        ownerToken: UUID,
        now: Date = Date()
    ) async throws -> MessageDeliveryClaimOutcome {
        let repository = try await requiredRepository()
        return try await repository.claim(
            messageID: messageID,
            ownerToken: ownerToken,
            now: now
        )
    }

    func claimNextReady(
        targetDeviceID: String,
        ownerToken: UUID,
        retryPolicy: MessageDeliveryRetryPolicy,
        now: Date = Date()
    ) async throws -> MessageDeliveryPollOutcome {
        let repository = try await requiredRepository()
        return try await repository.claimNextReady(
            targetDeviceID: targetDeviceID,
            ownerToken: ownerToken,
            retryPolicy: retryPolicy,
            now: now
        )
    }

    func isClaimCurrent(_ claim: MessageDeliveryClaim) async throws -> Bool {
        let repository = try await requiredRepository()
        return try await repository.isClaimCurrent(claim)
    }

    func resolve(
        _ claim: MessageDeliveryClaim,
        disposition: MessageDeliveryDisposition,
        retryPolicy: MessageDeliveryRetryPolicy,
        now: Date = Date()
    ) async throws -> MessageRepositoryMutationOutcome {
        let repository = try await requiredRepository()
        do {
            return .change(try await repository.resolve(
                claim,
                disposition: disposition,
                retryPolicy: retryPolicy,
                now: now
            ))
        } catch let firstError {
            if try await repository.isClaimCurrent(claim) {
                do {
                    return .change(try await repository.resolve(
                        claim,
                        disposition: disposition,
                        retryPolicy: retryPolicy,
                        now: now
                    ))
                } catch {
                    guard !(try await repository.isClaimCurrent(claim)) else {
                        throw error
                    }
                }
            }
            let snapshot = try await repository.currentSnapshot()
            guard Self.snapshot(
                snapshot,
                reflects: disposition,
                for: claim
            ) else {
                throw firstError
            }
            return .snapshot(snapshot)
        }
    }

    func requeueExpiredReceipts(
        now: Date = Date(),
        retryPolicy: MessageDeliveryRetryPolicy
    ) async throws -> MessageRepositoryChange {
        let repository = try await requiredRepository()
        return try await repository.requeueExpiredReceipts(
            now: now,
            retryPolicy: retryPolicy
        )
    }

    func confirmAuthenticatedReceipt(
        _ receipt: AuthenticatedMessageReceipt
    ) async throws -> MessageRepositoryChange {
        let repository = try await requiredRepository()
        return try await repository.confirmAuthenticatedReceipt(receipt)
    }

    func clearConversation(
        _ conversationFingerprint: String
    ) async throws -> MessageRepositoryChange {
        let repository = try await requiredRepository()
        return try await repository.clearConversation(conversationFingerprint)
    }

    func cancelDelivery(queueID: String) async throws -> MessageRepositoryChange {
        let repository = try await requiredRepository()
        return try await repository.cancelDelivery(queueID: queueID)
    }

    func cancelDeliveries(
        targetDeviceID: String
    ) async throws -> MessageRepositoryChange {
        let repository = try await requiredRepository()
        return try await repository.cancelDeliveries(targetDeviceID: targetDeviceID)
    }

    func clearDeliveries() async throws -> MessageRepositoryChange {
        let repository = try await requiredRepository()
        return try await repository.clearDeliveries()
    }

    func retryFailedDeliveries(
        now: Date = Date()
    ) async throws -> MessageRepositoryChange {
        let repository = try await requiredRepository()
        return try await repository.retryFailedDeliveries(now: now)
    }

    private func requiredRepository() async throws -> SQLiteDeviceMessagingRepository {
        if let repository { return repository }
        _ = try await bootstrap()
        guard let repository else {
            throw DeviceMessagingRepositoryError.notBootstrapped
        }
        return repository
    }

    private struct MigrationInput: Sendable {
        let migration: LegacyMessageMigration
        let sources: [AnyLoadedLegacySource]
    }

    private struct AnyLoadedLegacySource: Sendable {
        let source: LegacyMessageSource
        let rawData: Data
        let location: LegacySourceLocation
    }

    private static func makeMigrationInput(
        rootURL: URL,
        fileManager: FileManager,
        defaults: UserDefaults
    ) throws -> MigrationInput {
        let historyURL = rootURL
            .appendingPathComponent("Messaging", isDirectory: true)
            .appendingPathComponent("conversations.json", isDirectory: false)
        let queueURL = rootURL
            .appendingPathComponent("OfflineQueue", isDirectory: true)
            .appendingPathComponent("queue.json", isDirectory: false)

        let history: LoadedLegacySource<[String: [DeviceMessageStore.Message]]>? = try loadFileSource(
            sourceID: "mac_conversations_json",
            fileURL: historyURL,
            rootURL: rootURL
        )
        let queueFile: LoadedLegacySource<[QueuedMessage]>? = try loadFileSource(
            sourceID: "mac_offline_queue_json",
            fileURL: queueURL,
            rootURL: rootURL
        )
        let queueDefaults: LoadedLegacySource<[QueuedMessage]>? = try loadDefaultsSource(
            sourceID: "mac_offline_queue_user_defaults",
            defaultsKey: "com.skybridge.offline.queue",
            defaultsArchiveURL: queueURL
                .deletingLastPathComponent()
                .appendingPathComponent("queue.migrated-v1-user-defaults.json"),
            defaults: defaults
        )
        if let queueFile, let queueDefaults,
           queueFile.rawData != queueDefaults.rawData {
            throw DeviceMessagingRepositoryError.legacySourceConflict(
                "mac_offline_queue_dual_authority"
            )
        }
        let queue = queueFile ?? queueDefaults

        var sourceRecords: [LegacyMessageSource] = []
        var archives: [AnyLoadedLegacySource] = []
        if let history {
            sourceRecords.append(history.source)
            archives.append(AnyLoadedLegacySource(
                source: history.source,
                rawData: history.rawData,
                location: history.location
            ))
        }
        for source in [queueFile, queueDefaults].compactMap({ $0 }) {
            sourceRecords.append(source.source)
            archives.append(AnyLoadedLegacySource(
                source: source.source,
                rawData: source.rawData,
                location: source.location
            ))
        }

        var messagesByID: [UUID: PersistedMessageRecord] = [:]
        var intents: [PersistedDeliveryIntent] = []
        var issues: [MessageRepositoryMigrationIssue] = []

        if let history {
            for (rawFingerprint, legacyMessages) in history.value {
                let fingerprint = try normalizedFingerprint(rawFingerprint)
                for legacy in legacyMessages {
                    guard messagesByID[legacy.id] == nil else {
                        throw DeviceMessagingRepositoryError.duplicateMessage(legacy.id)
                    }
                    let targetDeviceID = try legacy.targetDeviceID.map(normalizedTarget)
                    let record = PersistedMessageRecord(
                        id: legacy.id,
                        conversationFingerprint: fingerprint,
                        targetDeviceID: targetDeviceID,
                        direction: try persistedDirection(legacy.direction),
                        text: try canonicalText(legacy.text),
                        timestamp: legacy.timestamp,
                        deliveryState: persistedDeliveryState(legacy.deliveryState)
                    )
                    messagesByID[legacy.id] = record
                    if legacy.direction == .outgoing,
                       legacy.deliveryState == .sent {
                        issues.append(MessageRepositoryMigrationIssue(
                            sourceID: history.source.sourceID,
                            messageID: legacy.id,
                            reasonCode: "legacy_sent_without_authenticated_receipt"
                        ))
                    }
                }
            }
        }

        var intentMessageIDs = Set<UUID>()
        if let queue {
            for legacy in queue.value {
                guard legacy.messageType == .text else {
                    throw DeviceMessagingRepositoryError.invalidRecord(
                        reasonCode: "unsupported_legacy_queue_message_type"
                    )
                }
                let envelope: DeviceTextQueueEnvelope = try LegacyJSONMigrationReader.decode(
                    from: legacy.payload,
                    sourceLabel: queue.source.sourceID
                )
                let fingerprint = try normalizedFingerprint(envelope.conversationFingerprint)
                let targetDeviceID = try normalizedTarget(legacy.targetDeviceID)
                let text = try canonicalText(envelope.payload.text)
                guard intentMessageIDs.insert(envelope.payload.id).inserted else {
                    throw DeviceMessagingRepositoryError.legacySourceConflict(
                        legacy.id.uuidString.lowercased()
                    )
                }

                let migratedQueueState: PersistedMessageDeliveryState
                switch legacy.status {
                case .failed, .expired:
                    migratedQueueState = .failed
                case .delivered:
                    migratedQueueState = .delivered
                case .pending, .sending, .awaitingReceipt:
                    migratedQueueState = .pending
                }

                if let existing = messagesByID[envelope.payload.id] {
                    guard existing.direction == .outgoing,
                          existing.conversationFingerprint == fingerprint,
                          existing.text == text,
                          existing.timestamp == envelope.payload.sentAt,
                          existing.deliveryState == migratedQueueState,
                          existing.targetDeviceID == nil
                            || existing.targetDeviceID == targetDeviceID else {
                        throw DeviceMessagingRepositoryError.legacySourceConflict(
                            legacy.id.uuidString.lowercased()
                        )
                    }
                    if existing.targetDeviceID == nil {
                        messagesByID[envelope.payload.id] = PersistedMessageRecord(
                            id: existing.id,
                            conversationFingerprint: existing.conversationFingerprint,
                            targetDeviceID: targetDeviceID,
                            direction: existing.direction,
                            text: existing.text,
                            timestamp: existing.timestamp,
                            deliveryState: existing.deliveryState
                        )
                    }
                } else {
                    messagesByID[envelope.payload.id] = PersistedMessageRecord(
                        id: envelope.payload.id,
                        conversationFingerprint: fingerprint,
                        targetDeviceID: targetDeviceID,
                        direction: .outgoing,
                        text: text,
                        timestamp: envelope.payload.sentAt,
                        deliveryState: migratedQueueState
                    )
                }

                switch legacy.status {
                case .delivered, .expired:
                    issues.append(MessageRepositoryMigrationIssue(
                        sourceID: queue.source.sourceID,
                        messageID: envelope.payload.id,
                        reasonCode: "terminal_legacy_queue_entry_not_reactivated"
                    ))
                    continue
                case .awaitingReceipt:
                    issues.append(MessageRepositoryMigrationIssue(
                        sourceID: queue.source.sourceID,
                        messageID: envelope.payload.id,
                        reasonCode: "legacy_awaiting_receipt_without_owner_requeued"
                    ))
                case .pending, .sending, .failed:
                    break
                }
                intents.append(PersistedDeliveryIntent(
                    queueID: legacy.id.uuidString.lowercased(),
                    messageID: envelope.payload.id,
                    targetDeviceID: targetDeviceID,
                    messageType: legacy.messageType.rawValue,
                    priority: legacy.priority.rawValue,
                    payload: legacy.payload,
                    createdAt: legacy.createdAt,
                    expiresAt: legacy.expiresAt,
                    state: legacy.status == .failed ? .failed : .pending,
                    retryCount: legacy.retryCount,
                    lastAttemptAt: legacy.lastAttemptAt,
                    receiptDeadline: nil,
                    failureCode: legacy.status == .failed
                        ? (legacy.lastFailureCode?.rawValue ?? "state_conflict")
                        : nil
                ))
            }
        }

        for (messageID, message) in messagesByID
        where message.direction == .outgoing
            && message.deliveryState == .pending
            && !intentMessageIDs.contains(messageID) {
            guard let targetDeviceID = message.targetDeviceID else {
                guard let sourceID = history?.source.sourceID else {
                    throw DeviceMessagingRepositoryError.invalidRecord(
                        reasonCode: "orphan_message_without_source"
                    )
                }
                issues.append(MessageRepositoryMigrationIssue(
                    sourceID: sourceID,
                    messageID: messageID,
                    reasonCode: "pending_message_missing_target_device_id"
                ))
                messagesByID[messageID]?.deliveryState = .failed
                continue
            }
            let payload = AppMessage.TextMessagePayload(
                id: message.id,
                text: message.text,
                sentAt: message.timestamp
            )
            let encoded = try JSONEncoder().encode(DeviceTextQueueEnvelope(
                payload: payload,
                conversationFingerprint: message.conversationFingerprint
            ))
            intents.append(PersistedDeliveryIntent(
                queueID: message.id.uuidString.lowercased(),
                messageID: message.id,
                targetDeviceID: targetDeviceID,
                messageType: OfflineMessageType.text.rawValue,
                priority: MessagePriority.normal.rawValue,
                payload: encoded,
                createdAt: message.timestamp,
                expiresAt: nil
            ))
        }

        return MigrationInput(
            migration: LegacyMessageMigration(
                sources: sourceRecords,
                messages: messagesByID.values.sorted(by: messageOrder),
                deliveryIntents: intents.sorted(by: intentOrder),
                issues: issues
            ),
            sources: archives
        )
    }

    private static func applicationSupportRoot(
        fileManager: FileManager
    ) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.skybridge.compass"
        return base
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("SkyBridgeState", isDirectory: true)
    }

    private static func loadFileSource<Value: Decodable & Sendable>(
        sourceID: String,
        fileURL: URL,
        rootURL: URL
    ) throws -> LoadedLegacySource<Value>? {
        guard let rawData = try LegacyJSONMigrationReader.readData(
            from: fileURL,
            containedIn: rootURL
        ) else {
            return nil
        }
        let value: Value = try LegacyJSONMigrationReader.decode(
            from: rawData,
            sourceLabel: sourceID
        )
        return LoadedLegacySource(
            source: LegacyMessageSource(
                sourceID: sourceID,
                contentDigest: sha256(rawData)
            ),
            value: value,
            rawData: rawData,
            location: .file(fileURL)
        )
    }

    private static func loadDefaultsSource<Value: Decodable & Sendable>(
        sourceID: String,
        defaultsKey: String,
        defaultsArchiveURL: URL,
        defaults: UserDefaults
    ) throws -> LoadedLegacySource<Value>? {
        guard let rawData = defaults.data(forKey: defaultsKey) else { return nil }
        let value: Value = try LegacyJSONMigrationReader.decode(
            from: rawData,
            sourceLabel: sourceID
        )
        return LoadedLegacySource(
            source: LegacyMessageSource(
                sourceID: sourceID,
                contentDigest: sha256(rawData)
            ),
            value: value,
            rawData: rawData,
            location: .userDefaults(key: defaultsKey, archiveURL: defaultsArchiveURL)
        )
    }

    private static func archiveCommittedSources(
        _ sources: [AnyLoadedLegacySource],
        rootURL: URL,
        fileManager: FileManager,
        defaults: UserDefaults
    ) throws {
        for source in sources {
            switch source.location {
            case .file(let url):
                _ = try LegacyJSONMigrationReader.archive(
                    fileURL: url,
                    containedIn: rootURL,
                    contentDigest: source.source.contentDigest,
                    expectedData: source.rawData
                )
            case .userDefaults(let key, let archiveURL):
                let currentData = defaults.data(forKey: key)
                if currentData == nil {
                    guard try LegacyJSONMigrationReader.archivedDataMatches(
                        source.rawData,
                        at: archiveURL,
                        containedIn: rootURL,
                        sourceLabel: source.source.sourceID
                    ) else {
                        throw DeviceMessagingRepositoryError.legacySourceChanged(
                            source.source.sourceID
                        )
                    }
                    try fileManager.setAttributes(
                        [.posixPermissions: 0o600],
                        ofItemAtPath: archiveURL.path
                    )
                    continue
                }
                guard currentData == source.rawData else {
                    throw DeviceMessagingRepositoryError.legacySourceChanged(
                        source.source.sourceID
                    )
                }
                _ = try LegacyJSONMigrationReader.archive(
                    data: source.rawData,
                    to: archiveURL,
                    containedIn: rootURL,
                    sourceLabel: source.source.sourceID
                )
                try fileManager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: archiveURL.path
                )
                guard defaults.data(forKey: key) == source.rawData else {
                    throw DeviceMessagingRepositoryError.legacySourceChanged(
                        source.source.sourceID
                    )
                }
                defaults.removeObject(forKey: key)
            }
        }
    }

    private static func normalizedFingerprint(_ raw: String) throws -> String {
        do {
            return try DeviceTextMessagePolicy.normalizedConversationFingerprint(raw)
        } catch {
            throw DeviceMessagingRepositoryError.invalidRecord(
                reasonCode: "invalid_legacy_conversation_fingerprint"
            )
        }
    }

    private static func normalizedTarget(_ raw: String) throws -> String {
        do {
            return try DeviceTextMessagePolicy.normalizedTargetDeviceIdentifier(raw)
        } catch {
            throw DeviceMessagingRepositoryError.invalidRecord(
                reasonCode: "invalid_legacy_target_device_id"
            )
        }
    }

    private static func canonicalText(_ raw: String) throws -> String {
        do {
            let value = try DeviceTextMessagePolicy.validatedText(raw)
            guard value == raw else {
                throw DeviceMessagingRepositoryError.invalidRecord(
                    reasonCode: "noncanonical_legacy_message_text"
                )
            }
            return value
        } catch let error as DeviceMessagingRepositoryError {
            throw error
        } catch {
            throw DeviceMessagingRepositoryError.invalidRecord(
                reasonCode: "invalid_legacy_message_text"
            )
        }
    }

    private static func persistedDirection(
        _ direction: DeviceMessageStore.Direction
    ) throws -> PersistedMessageDirection {
        switch direction {
        case .incoming: return .incoming
        case .outgoing: return .outgoing
        }
    }

    private static func persistedDeliveryState(
        _ state: DeviceMessageStore.DeliveryState
    ) -> PersistedMessageDeliveryState {
        switch state {
        case .pending: return .pending
        case .sent: return .sent
        case .delivered: return .delivered
        case .failed: return .failed
        }
    }

    private static func messageOrder(
        _ lhs: PersistedMessageRecord,
        _ rhs: PersistedMessageRecord
    ) -> Bool {
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func intentOrder(
        _ lhs: PersistedDeliveryIntent,
        _ rhs: PersistedDeliveryIntent
    ) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.queueID < rhs.queueID
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func snapshot(
        _ snapshot: MessageRepositorySnapshot,
        reflects disposition: MessageDeliveryDisposition,
        for claim: MessageDeliveryClaim
    ) -> Bool {
        let intent = snapshot.deliveryIntents.first {
            $0.queueID == claim.intent.queueID && $0.messageID == claim.intent.messageID
        }
        let message = snapshot.messages.first { $0.id == claim.intent.messageID }
        switch disposition {
        case .submitted(let receiptDeadline):
            return (intent?.state == .awaitingReceipt
                    && intent?.receiptDeadline == receiptDeadline
                    && message?.deliveryState == .sent)
                || (intent == nil && message?.deliveryState == .delivered)
        case .retryable(let failureCode):
            return (intent?.state == .pending || intent?.state == .failed)
                && intent?.failureCode == failureCode
                && (message?.deliveryState == .pending || message?.deliveryState == .failed)
        case .permanentFailure(let failureCode):
            return intent?.state == .failed
                && intent?.failureCode == failureCode
                && message?.deliveryState == .failed
        case .interrupted:
            return intent?.state == .pending && message?.deliveryState == .pending
        }
    }
}
