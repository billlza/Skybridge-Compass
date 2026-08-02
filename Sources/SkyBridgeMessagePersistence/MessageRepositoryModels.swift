import Foundation

public enum PersistedMessageDirection: Int32, Codable, Sendable, CaseIterable {
    case incoming = 0
    case outgoing = 1
}

public enum PersistedMessageDeliveryState: Int32, Codable, Sendable, CaseIterable {
    case pending = 0
    case sent = 1
    case delivered = 2
    case failed = 3
}

public enum PersistedDeliveryIntentState: Int32, Codable, Sendable, CaseIterable {
    case pending = 0
    case sending = 1
    case awaitingReceipt = 2
    case failed = 3
}

public struct PersistedMessageRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let conversationFingerprint: String
    public let targetDeviceID: String?
    public let direction: PersistedMessageDirection
    public let text: String
    public let timestamp: Date
    public var deliveryState: PersistedMessageDeliveryState

    public init(
        id: UUID,
        conversationFingerprint: String,
        targetDeviceID: String?,
        direction: PersistedMessageDirection,
        text: String,
        timestamp: Date,
        deliveryState: PersistedMessageDeliveryState
    ) {
        self.id = id
        self.conversationFingerprint = conversationFingerprint
        self.targetDeviceID = targetDeviceID
        self.direction = direction
        self.text = text
        self.timestamp = timestamp
        self.deliveryState = deliveryState
    }
}

public struct PersistedDeliveryIntent: Codable, Sendable, Equatable, Identifiable {
    public var id: String { queueID }

    public let queueID: String
    public let messageID: UUID
    public let targetDeviceID: String
    public let messageType: String
    public let priority: Int
    public let payload: Data
    public let createdAt: Date
    public let expiresAt: Date?
    public var state: PersistedDeliveryIntentState
    public var retryCount: Int
    public var lastAttemptAt: Date?
    public var receiptDeadline: Date?
    public var failureCode: String?
    public var claimGeneration: UInt64

    public init(
        queueID: String,
        messageID: UUID,
        targetDeviceID: String,
        messageType: String,
        priority: Int,
        payload: Data,
        createdAt: Date,
        expiresAt: Date?,
        state: PersistedDeliveryIntentState = .pending,
        retryCount: Int = 0,
        lastAttemptAt: Date? = nil,
        receiptDeadline: Date? = nil,
        failureCode: String? = nil,
        claimGeneration: UInt64 = 0
    ) {
        self.queueID = queueID
        self.messageID = messageID
        self.targetDeviceID = targetDeviceID
        self.messageType = messageType
        self.priority = priority
        self.payload = payload
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.state = state
        self.retryCount = retryCount
        self.lastAttemptAt = lastAttemptAt
        self.receiptDeadline = receiptDeadline
        self.failureCode = failureCode
        self.claimGeneration = claimGeneration
    }
}

public struct MessageRepositoryMigrationIssue: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let sourceID: String
    public let messageID: UUID?
    public let reasonCode: String

    public init(
        id: UUID = UUID(),
        sourceID: String,
        messageID: UUID?,
        reasonCode: String
    ) {
        self.id = id
        self.sourceID = sourceID
        self.messageID = messageID
        self.reasonCode = reasonCode
    }
}

public struct LegacyMessageSource: Codable, Sendable, Equatable {
    public let sourceID: String
    public let contentDigest: String

    public init(sourceID: String, contentDigest: String) {
        self.sourceID = sourceID
        self.contentDigest = contentDigest
    }
}

/// Fully decoded and validated legacy input. Callers retain the legacy files;
/// this value only describes the rows imported by one SQLite transaction.
public struct LegacyMessageMigration: Sendable, Equatable {
    public let sources: [LegacyMessageSource]
    public let messages: [PersistedMessageRecord]
    public let deliveryIntents: [PersistedDeliveryIntent]
    public let issues: [MessageRepositoryMigrationIssue]

    public init(
        sources: [LegacyMessageSource],
        messages: [PersistedMessageRecord],
        deliveryIntents: [PersistedDeliveryIntent],
        issues: [MessageRepositoryMigrationIssue] = []
    ) {
        self.sources = sources
        self.messages = messages
        self.deliveryIntents = deliveryIntents
        self.issues = issues
    }

    public static let empty = LegacyMessageMigration(
        sources: [],
        messages: [],
        deliveryIntents: []
    )
}

public struct MessageRepositorySnapshot: Sendable, Equatable {
    public let messages: [PersistedMessageRecord]
    public let deliveryIntents: [PersistedDeliveryIntent]
    public let migrationIssues: [MessageRepositoryMigrationIssue]
    public let generation: UInt64

    public init(
        messages: [PersistedMessageRecord],
        deliveryIntents: [PersistedDeliveryIntent],
        migrationIssues: [MessageRepositoryMigrationIssue],
        generation: UInt64
    ) {
        self.messages = messages
        self.deliveryIntents = deliveryIntents
        self.migrationIssues = migrationIssues
        self.generation = generation
    }
}

public struct MessageDeliveryClaim: Sendable, Equatable {
    public let intent: PersistedDeliveryIntent
    public let ownerToken: UUID
    public let generation: UInt64

    public init(
        intent: PersistedDeliveryIntent,
        ownerToken: UUID,
        generation: UInt64
    ) {
        self.intent = intent
        self.ownerToken = ownerToken
        self.generation = generation
    }
}

/// Evidence extracted from an already authenticated transport frame. The
/// attempt token is generated by the exact local claim owner and echoed by the
/// receiver; it is never accepted as identity authority by itself.
public struct AuthenticatedMessageReceipt: Sendable, Equatable {
    public let messageID: UUID
    public let deliveryAttemptID: UUID
    public let conversationFingerprint: String
    public let receivedAt: Date

    public init(
        messageID: UUID,
        deliveryAttemptID: UUID,
        conversationFingerprint: String,
        receivedAt: Date
    ) {
        self.messageID = messageID
        self.deliveryAttemptID = deliveryAttemptID
        self.conversationFingerprint = conversationFingerprint
        self.receivedAt = receivedAt
    }
}

public enum MessageDeliveryDisposition: Sendable, Equatable {
    /// The frame reached the local transport, but an authenticated peer receipt
    /// has not arrived. The intent stays durable and is not immediately retried.
    case submitted(receiptDeadline: Date)
    case retryable(failureCode: String)
    case permanentFailure(failureCode: String)
    /// The exact worker stopped before it could prove a remote side effect. The
    /// durable intent returns to pending; this is not a user cancellation.
    case interrupted
}

public struct MessageDeliveryRetryPolicy: Sendable, Equatable {
    public let maximumRetryCount: Int
    public let retryInterval: TimeInterval
    public let backoffFactor: Double

    public init(
        maximumRetryCount: Int,
        retryInterval: TimeInterval,
        backoffFactor: Double
    ) {
        self.maximumRetryCount = maximumRetryCount
        self.retryInterval = retryInterval
        self.backoffFactor = backoffFactor
    }
}

public enum DeviceMessagingRepositoryError: Error, LocalizedError, Sendable, Equatable {
    case notBootstrapped
    case invalidDatabaseLocation
    case invalidRecord(reasonCode: String)
    case duplicateMessage(UUID)
    case duplicateQueueID(String)
    case messageNotFound(UUID)
    case intentNotFound(String)
    case staleClaim(String)
    case receiptBindingMismatch(UUID)
    case legacySourceConflict(String)
    case legacySourceChanged(String)
    case legacyPayloadTooLarge(actualBytes: Int, maximumBytes: Int)
    case legacyPayloadUnreadable(String)
    case schemaVersionUnsupported(Int)
    case transactionOutcomeUnknown
    case sqliteFailure(operation: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .notBootstrapped:
            return "Device messaging repository has not been bootstrapped"
        case .invalidDatabaseLocation:
            return "Device messaging database location is invalid"
        case .invalidRecord(let reasonCode):
            return "Device messaging record is invalid: \(reasonCode)"
        case .duplicateMessage:
            return "Device messaging record already exists"
        case .duplicateQueueID:
            return "Device messaging delivery intent already exists"
        case .messageNotFound:
            return "Device messaging record was not found"
        case .intentNotFound:
            return "Device messaging delivery intent was not found"
        case .staleClaim:
            return "Device messaging delivery claim is stale"
        case .receiptBindingMismatch:
            return "Device messaging receipt does not match the authenticated delivery attempt"
        case .legacySourceConflict:
            return "Legacy device messaging sources conflict"
        case .legacySourceChanged:
            return "Legacy device messaging source changed after migration"
        case .legacyPayloadTooLarge(let actualBytes, let maximumBytes):
            return "Legacy device messaging payload is \(actualBytes) bytes; migration maximum is \(maximumBytes) bytes"
        case .legacyPayloadUnreadable:
            return "Legacy device messaging payload could not be read or decoded"
        case .schemaVersionUnsupported(let version):
            return "Device messaging database schema \(version) is not supported"
        case .transactionOutcomeUnknown:
            return "Device messaging transaction outcome could not be proven"
        case .sqliteFailure(let operation, let code):
            return "Device messaging database operation \(operation) failed with SQLite code \(code)"
        }
    }
}
