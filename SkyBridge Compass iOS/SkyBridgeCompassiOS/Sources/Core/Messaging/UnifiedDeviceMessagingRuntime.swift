import CryptoKit
import Foundation
import SkyBridgeMessagePersistence
import SkyBridgeProtocolCore
#if canImport(UIKit)
import UIKit
#endif

@available(iOS 17.0, *)
actor IOSUnifiedDeviceMessagingRuntime {
    static let shared = IOSUnifiedDeviceMessagingRuntime()

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

    private struct AnyLoadedLegacySource: Sendable {
        let source: LegacyMessageSource
        let rawData: Data
        let location: LegacySourceLocation
    }

    private struct MigrationInput: Sendable {
        let migration: LegacyMessageMigration
        let sources: [AnyLoadedLegacySource]
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

        let rootURL: URL
        if let rootURLOverride {
            rootURL = rootURLOverride
        } else {
            rootURL = try Self.applicationSupportRoot(fileManager: fileManager)
        }
        let migrationInput = try Self.makeMigrationInput(
            rootURL: rootURL,
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

    func currentSnapshot() async throws -> MessageRepositorySnapshot {
        try await requiredRepository().currentSnapshot()
    }

    func stageOutgoing(
        message: PersistedMessageRecord,
        intent: PersistedDeliveryIntent
    ) async throws -> MessageRepositoryChange {
        try await requiredRepository().stageOutgoing(message: message, intent: intent)
    }

    func recordIncoming(
        _ message: PersistedMessageRecord
    ) async throws -> MessageRepositoryChange {
        try await requiredRepository().recordIncoming(message)
    }

    func claimNextReady(
        targetDeviceID: String,
        ownerToken: UUID,
        retryPolicy: MessageDeliveryRetryPolicy,
        now: Date = Date()
    ) async throws -> MessageDeliveryPollOutcome {
        try await requiredRepository().claimNextReady(
            targetDeviceID: targetDeviceID,
            ownerToken: ownerToken,
            retryPolicy: retryPolicy,
            now: now
        )
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
            guard Self.snapshot(snapshot, reflects: disposition, for: claim) else {
                throw firstError
            }
            return .snapshot(snapshot)
        }
    }

    func confirmAuthenticatedReceipt(
        _ receipt: AuthenticatedMessageReceipt
    ) async throws -> MessageRepositoryChange {
        try await requiredRepository().confirmAuthenticatedReceipt(receipt)
    }

    func requeueExpiredReceipts(
        now: Date = Date(),
        retryPolicy: MessageDeliveryRetryPolicy
    ) async throws -> MessageRepositoryChange {
        try await requiredRepository().requeueExpiredReceipts(
            now: now,
            retryPolicy: retryPolicy
        )
    }

    func clearConversation(
        _ conversationFingerprint: String
    ) async throws -> MessageRepositoryChange {
        try await requiredRepository().clearConversation(conversationFingerprint)
    }

    func cancelDelivery(queueID: String) async throws -> MessageRepositoryChange {
        try await requiredRepository().cancelDelivery(queueID: queueID)
    }

    func cancelDeliveries(
        targetDeviceID: String
    ) async throws -> MessageRepositoryChange {
        try await requiredRepository().cancelDeliveries(targetDeviceID: targetDeviceID)
    }

    func clearDeliveries() async throws -> MessageRepositoryChange {
        try await requiredRepository().clearDeliveries()
    }

    func retryFailedDeliveries(
        now: Date = Date()
    ) async throws -> MessageRepositoryChange {
        try await requiredRepository().retryFailedDeliveries(now: now)
    }

    private func requiredRepository() async throws -> SQLiteDeviceMessagingRepository {
        if let repository { return repository }
        _ = try await bootstrap()
        guard let repository else {
            throw DeviceMessagingRepositoryError.notBootstrapped
        }
        return repository
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

    private static func makeMigrationInput(
        rootURL: URL,
        defaults: UserDefaults
    ) throws -> MigrationInput {
        let historyURL = rootURL
            .appendingPathComponent("Messaging", isDirectory: true)
            .appendingPathComponent("device-conversations.json", isDirectory: false)
        let queueURL = rootURL
            .appendingPathComponent("Messaging", isDirectory: true)
            .appendingPathComponent("offline-message-queue.json", isDirectory: false)

        let history: LoadedLegacySource<[String: [DeviceMessageStore.Message]]>? = try loadFileSource(
            sourceID: "ios_conversations_json",
            fileURL: historyURL,
            rootURL: rootURL
        )
        let queueFile: LoadedLegacySource<OfflineMessageQueue.StoredMessages>? = try loadFileSource(
            sourceID: "ios_offline_queue_json",
            fileURL: queueURL,
            rootURL: rootURL
        )
        let queueDefaults: LoadedLegacySource<OfflineMessageQueue.StoredMessages>? = try loadDefaultsSource(
            sourceID: "ios_offline_queue_user_defaults",
            defaultsKey: "offline_message_queue",
            defaultsArchiveURL: queueURL
                .deletingLastPathComponent()
                .appendingPathComponent("offline-message-queue.migrated-v1-user-defaults.json"),
            defaults: defaults
        )
        if let queueFile, let queueDefaults,
           queueFile.rawData != queueDefaults.rawData {
            throw DeviceMessagingRepositoryError.legacySourceConflict(
                "ios_offline_queue_dual_authority"
            )
        }
        let queue = queueFile ?? queueDefaults

        let loadedSources: [AnyLoadedLegacySource] = ([history].compactMap { $0 }.map {
            AnyLoadedLegacySource(source: $0.source, rawData: $0.rawData, location: $0.location)
        }) + ([queueFile, queueDefaults].compactMap { $0 }.map {
            AnyLoadedLegacySource(source: $0.source, rawData: $0.rawData, location: $0.location)
        })
        let sources = loadedSources.map(\.source)

        var messagesByID: [UUID: PersistedMessageRecord] = [:]
        var issues: [MessageRepositoryMigrationIssue] = []
        if let history {
            for (rawFingerprint, legacyMessages) in history.value {
                let fingerprint = try normalizedFingerprint(rawFingerprint)
                for legacy in legacyMessages {
                    guard messagesByID[legacy.id] == nil else {
                        throw DeviceMessagingRepositoryError.duplicateMessage(legacy.id)
                    }
                    let state = persistedDeliveryState(legacy.deliveryState)
                    messagesByID[legacy.id] = PersistedMessageRecord(
                        id: legacy.id,
                        conversationFingerprint: fingerprint,
                        targetDeviceID: nil,
                        direction: persistedDirection(legacy.direction),
                        text: try canonicalText(legacy.text),
                        timestamp: legacy.timestamp,
                        deliveryState: state
                    )
                    if legacy.direction == .outgoing, legacy.deliveryState == .sent {
                        issues.append(MessageRepositoryMigrationIssue(
                            sourceID: history.source.sourceID,
                            messageID: legacy.id,
                            reasonCode: "legacy_sent_without_authenticated_receipt"
                        ))
                    }
                }
            }
        }

        var intents: [PersistedDeliveryIntent] = []
        var intentMessageIDs = Set<UUID>()
        var intentQueueIDs = Set<String>()
        if let queue {
            let pending = queue.value.pending
            let failed = queue.value.failed
            guard pending.allSatisfy({
                $0.status == .pending
                    || $0.status == .sending
                    || $0.status == .awaitingReceipt
            }),
                  failed.allSatisfy({ $0.status == .failed }) else {
                throw DeviceMessagingRepositoryError.invalidRecord(
                    reasonCode: "invalid_ios_legacy_queue_partition"
                )
            }
            for legacy in pending + failed {
                let canonicalQueueID = try canonicalLegacyQueueID(legacy.id)
                guard intentQueueIDs.insert(canonicalQueueID).inserted else {
                    throw DeviceMessagingRepositoryError.legacySourceConflict(
                        canonicalQueueID
                    )
                }
                guard legacy.messageType == .text else {
                    throw DeviceMessagingRepositoryError.invalidRecord(
                        reasonCode: "unsupported_legacy_queue_message_type"
                    )
                }
                let envelope: IOSDeviceTextQueueEnvelope = try LegacyJSONMigrationReader.decode(
                    from: legacy.payload,
                    sourceLabel: queue.source.sourceID
                )
                let fingerprint = try normalizedFingerprint(envelope.conversationFingerprint)
                let target = try normalizedTarget(legacy.targetDeviceId)
                let text = try canonicalText(envelope.payload.text)
                if legacy.status == .awaitingReceipt {
                    issues.append(MessageRepositoryMigrationIssue(
                        sourceID: queue.source.sourceID,
                        messageID: envelope.payload.id,
                        reasonCode: "legacy_awaiting_receipt_without_owner_requeued"
                    ))
                }
                guard intentMessageIDs.insert(envelope.payload.id).inserted else {
                    throw DeviceMessagingRepositoryError.legacySourceConflict(
                        canonicalQueueID
                    )
                }
                if let existing = messagesByID[envelope.payload.id] {
                    guard existing.direction == .outgoing,
                          existing.conversationFingerprint == fingerprint,
                          existing.text == text,
                          existing.timestamp == envelope.payload.sentAt,
                          existing.deliveryState == (legacy.status == .failed ? .failed : .pending)
                    else {
                        throw DeviceMessagingRepositoryError.legacySourceConflict(
                            canonicalQueueID
                        )
                    }
                    messagesByID[envelope.payload.id] = PersistedMessageRecord(
                        id: existing.id,
                        conversationFingerprint: existing.conversationFingerprint,
                        targetDeviceID: target,
                        direction: existing.direction,
                        text: existing.text,
                        timestamp: existing.timestamp,
                        deliveryState: existing.deliveryState
                    )
                } else {
                    messagesByID[envelope.payload.id] = PersistedMessageRecord(
                        id: envelope.payload.id,
                        conversationFingerprint: fingerprint,
                        targetDeviceID: target,
                        direction: .outgoing,
                        text: text,
                        timestamp: envelope.payload.sentAt,
                        deliveryState: legacy.status == .failed ? .failed : .pending
                    )
                }
                intents.append(PersistedDeliveryIntent(
                    queueID: canonicalQueueID,
                    messageID: envelope.payload.id,
                    targetDeviceID: target,
                    messageType: legacy.messageType.rawValue,
                    priority: 1,
                    payload: legacy.payload,
                    createdAt: legacy.createdAt,
                    expiresAt: legacy.expiresAt,
                    state: legacy.status == .failed ? .failed : .pending,
                    retryCount: legacy.retryCount,
                    lastAttemptAt: legacy.lastRetryAt,
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
            guard let history else {
                throw DeviceMessagingRepositoryError.invalidRecord(
                    reasonCode: "orphan_message_without_source"
                )
            }
            messagesByID[messageID]?.deliveryState = .failed
            issues.append(MessageRepositoryMigrationIssue(
                sourceID: history.source.sourceID,
                messageID: messageID,
                reasonCode: "pending_message_missing_target_device_id"
            ))
        }

        return MigrationInput(
            migration: LegacyMessageMigration(
                sources: sources,
                messages: messagesByID.values.sorted(by: messageOrder),
                deliveryIntents: intents.sorted(by: intentOrder),
                issues: issues
            ),
            sources: loadedSources
        )
    }

    private static func loadFileSource<Value: Decodable & Sendable>(
        sourceID: String,
        fileURL: URL,
        rootURL: URL
    ) throws -> LoadedLegacySource<Value>? {
        guard let rawData = try LegacyJSONMigrationReader.readData(
            from: fileURL,
            containedIn: rootURL
        ) else { return nil }
        let value: Value = try LegacyJSONMigrationReader.decode(
            from: rawData,
            sourceLabel: sourceID
        )
        return LoadedLegacySource(
            source: LegacyMessageSource(sourceID: sourceID, contentDigest: sha256(rawData)),
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
            source: LegacyMessageSource(sourceID: sourceID, contentDigest: sha256(rawData)),
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
                        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
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
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: archiveURL.path
                )
                guard defaults.data(forKey: key) == source.rawData else {
                    throw DeviceMessagingRepositoryError.legacySourceChanged(source.source.sourceID)
                }
                defaults.removeObject(forKey: key)
            }
        }
    }

    private static func applicationSupportRoot(fileManager: FileManager) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.skybridge.compass.ios"
        return base
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("SkyBridgeState", isDirectory: true)
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

    private static func canonicalLegacyQueueID(_ raw: String) throws -> String {
        guard let parsed = UUID(uuidString: raw) else {
            throw DeviceMessagingRepositoryError.invalidRecord(
                reasonCode: "invalid_legacy_queue_id"
            )
        }
        return parsed.uuidString.lowercased()
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
        _ value: DeviceMessageStore.Direction
    ) -> PersistedMessageDirection {
        switch value {
        case .incoming: .incoming
        case .outgoing: .outgoing
        }
    }

    private static func persistedDeliveryState(
        _ value: DeviceMessageStore.DeliveryState
    ) -> PersistedMessageDeliveryState {
        switch value {
        case .pending: .pending
        case .sent: .sent
        case .delivered: .delivered
        case .failed: .failed
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
        case .submitted(let deadline):
            return (intent?.state == .awaitingReceipt
                    && intent?.receiptDeadline == deadline
                    && message?.deliveryState == .sent)
                || (intent == nil && message?.deliveryState == .delivered)
        case .retryable(let code):
            return (intent?.state == .pending || intent?.state == .failed)
                && intent?.failureCode == code
                && (message?.deliveryState == .pending || message?.deliveryState == .failed)
        case .permanentFailure(let code):
            return intent?.state == .failed
                && intent?.failureCode == code
                && message?.deliveryState == .failed
        case .interrupted:
            return intent?.state == .pending && message?.deliveryState == .pending
        }
    }
}
