// MARK: - SecurityEvent.swift
// SkyBridge Compass - Security Hardening
// Copyright © 2024 SkyBridge. All rights reserved.

import Foundation

/// Security event types for unified logging, UI alerts, and statistics.
/// Defined per requirements document Security Event Types table.
public enum SecurityEventType: String, Sendable, CaseIterable {
 /// Batch scan exceeded file count/bytes/time limits
    case limitExceeded = "limit_exceeded"

 /// Agent connection closed due to rate limiting
    case rateLimitDisconnect = "rate_limit_disconnect"

 /// Signature database using non-production key
    case signatureDBKeyInvalid = "signature_db_key_invalid"

 /// Pairing SAS confirmation failed
    case pairingSASMismatch = "pairing_sas_mismatch"

 /// Authentication token format invalid or empty
    case authTokenInvalid = "auth_token_invalid"

 /// Regex pattern rejected due to security rules
    case regexPatternRejected = "regex_pattern_rejected"

 /// Symbolic link resolution failed
    case symlinkResolutionFailed = "symlink_resolution_failed"

 /// Archive extraction aborted due to limits
    case archiveExtractionAborted = "archive_extraction_aborted"

 /// File read operation timed out
    case fileReadTimeout = "file_read_timeout"

 /// Scan detail file corrupted or mismatched
    case detailFileCorrupted = "detail_file_corrupted"

 /// Crypto provider selected (PQC architecture)
    case cryptoProviderSelected = "crypto_provider_selected"

 /// P2P handshake failed
    case handshakeFailed = "handshake_failed"

 /// P2P handshake established (explicit key confirmation complete)
    case handshakeEstablished = "handshake_established"

 /// Crypto downgrade occurred ( 14.3)
 /// Requirement 14.3: classic fallback 时发射此事件
    case cryptoDowngrade = "crypto_downgrade"

 /// Secure Enclave 签名验证失败
    case secureEnclaveSignatureInvalid = "secure_enclave_signature_invalid"

 // MARK: - Signature Mechanism Alignment Events ( 3.1)
 // Requirements: 1.3

 /// 签名 Provider 已选择（记录选择的签名算法）
    case signatureProviderSelected = "signature_provider_selected"

 /// Legacy 签名已接受（向后兼容期间接受 P-256 ECDSA）
    case legacySignatureAccepted = "legacy_signature_accepted"

 /// 签名算法不匹配（selectedSuite 与 sigA 算法不兼容）
    case signatureAlgorithmMismatch = "signature_algorithm_mismatch"

 /// 握手回退（PQC 失败后回退到 Classic）
    case handshakeFallback = "handshake_fallback"

 /// 密钥迁移完成（P-256 身份密钥迁移到 SE PoP 角色）
    case keyMigrationCompleted = "key_migration_completed"

 /// 签名验证失败（ 7.1）
    case signatureVerificationFailed = "signature_verification_failed"

 /// SE PoP 不一致状态检测（iOS Handshake Entry Alignment）
 /// handle 和 publicKey 不成对时发射
    case sePoPInconsistentStateDetected = "se_pop_inconsistent_state_detected"
}

/// Severity levels for security events.
public enum SecurityEventSeverity: String, Sendable, Comparable {
    case info
    case warning
    case high
    case critical

 /// Numeric value for comparison (higher = more severe)
    private var numericValue: Int {
        switch self {
        case .info: return 0
        case .warning: return 1
        case .high: return 2
        case .critical: return 3
        }
    }

    public static func < (lhs: SecurityEventSeverity, rhs: SecurityEventSeverity) -> Bool {
        lhs.numericValue < rhs.numericValue
    }
}

/// A security event with type, severity, message, context, and timestamp.
public struct SecurityEvent: Sendable {
 /// The type of security event
    public let type: SecurityEventType

 /// Severity level of the event
    public let severity: SecurityEventSeverity

 /// Human-readable message describing the event
    public let message: String

 /// Additional context as key-value pairs
    public let context: [String: String]

 /// When the event occurred
    public let timestamp: Date

 /// Unique identifier for this event instance
    public let id: UUID

 /// Whether this is a meta-event (e.g., queue overflow notification)
 /// Meta-events bypass the normal queue to prevent recursion
    internal let isMetaEvent: Bool

    public init(
        type: SecurityEventType,
        severity: SecurityEventSeverity,
        message: String,
        context: [String: String] = [:],
        timestamp: Date = Date(),
        id: UUID = UUID(),
        isMetaEvent: Bool = false
    ) {
        self.type = type
        self.severity = severity
        self.message = message
        self.context = context
        self.timestamp = timestamp
        self.id = id
        self.isMetaEvent = isMetaEvent
    }
}

// MARK: - Default Severity Mapping

extension SecurityEventType {
 /// Default severity for each event type (per requirements)
    public var defaultSeverity: SecurityEventSeverity {
        switch self {
        case .limitExceeded: return .high
        case .rateLimitDisconnect: return .high
        case .signatureDBKeyInvalid: return .critical
        case .pairingSASMismatch: return .high
        case .authTokenInvalid: return .high
        case .regexPatternRejected: return .warning
        case .symlinkResolutionFailed: return .warning
        case .archiveExtractionAborted: return .warning
        case .fileReadTimeout: return .warning
        case .detailFileCorrupted: return .info
        case .cryptoProviderSelected: return .info
        case .handshakeFailed: return .warning
        case .handshakeEstablished: return .info
        case .cryptoDowngrade: return .warning
        case .secureEnclaveSignatureInvalid: return .warning
 // Signature Mechanism Alignment Events
        case .signatureProviderSelected: return .info
        case .legacySignatureAccepted: return .warning
        case .signatureAlgorithmMismatch: return .high
        case .handshakeFallback: return .warning
        case .keyMigrationCompleted: return .info
        case .signatureVerificationFailed: return .warning
        case .sePoPInconsistentStateDetected: return .warning
        }
    }
}

// MARK: - Convenience Initializers

extension SecurityEvent {
 /// Create a security event with default severity for the event type
    public static func create(
        type: SecurityEventType,
        message: String,
        context: [String: String] = [:]
    ) -> SecurityEvent {
        SecurityEvent(
            type: type,
            severity: type.defaultSeverity,
            message: message,
            context: context
        )
    }

 /// Create a limit exceeded event
    public static func limitExceeded(
        limitType: String,
        actual: Int64,
        max: Int64,
        context: [String: String] = [:]
    ) -> SecurityEvent {
        var ctx = context
        ctx["limitType"] = limitType
        ctx["actual"] = String(actual)
        ctx["max"] = String(max)
        return SecurityEvent(
            type: .limitExceeded,
            severity: .high,
            message: "Limit exceeded: \(limitType) (\(actual) > \(max))",
            context: ctx
        )
    }

 /// Create a rate limit disconnect event
    public static func rateLimitDisconnect(
        connectionId: String,
        droppedCount: Int,
        windowSeconds: TimeInterval
    ) -> SecurityEvent {
        SecurityEvent(
            type: .rateLimitDisconnect,
            severity: .high,
            message: "Connection \(connectionId) disconnected: \(droppedCount) messages dropped in \(windowSeconds)s",
            context: [
                "connectionId": connectionId,
                "droppedCount": String(droppedCount),
                "windowSeconds": String(windowSeconds)
            ]
        )
    }

 /// Create a regex pattern rejected event
    public static func regexPatternRejected(
        patternId: String,
        reason: String
    ) -> SecurityEvent {
        SecurityEvent(
            type: .regexPatternRejected,
            severity: .warning,
            message: "Regex pattern \(patternId) rejected: \(reason)",
            context: [
                "patternId": patternId,
                "reason": reason
            ]
        )
    }

 /// Create an auth token invalid event
    public static func authTokenInvalid(
        reason: String,
        connectionId: String? = nil
    ) -> SecurityEvent {
        var ctx: [String: String] = ["reason": reason]
        if let connId = connectionId {
            ctx["connectionId"] = connId
        }
        return SecurityEvent(
            type: .authTokenInvalid,
            severity: .high,
            message: "Auth token invalid: \(reason)",
            context: ctx
        )
    }

 /// Create a symlink resolution failed event
    public static func symlinkResolutionFailed(
        path: String,
        reason: String
    ) -> SecurityEvent {
        SecurityEvent(
            type: .symlinkResolutionFailed,
            severity: .warning,
            message: "Symlink resolution failed for \(path): \(reason)",
            context: [
                "path": path,
                "reason": reason
            ]
        )
    }

 /// Create an archive extraction aborted event
    public static func archiveExtractionAborted(
        archivePath: String,
        reason: String
    ) -> SecurityEvent {
        SecurityEvent(
            type: .archiveExtractionAborted,
            severity: .warning,
            message: "Archive extraction aborted for \(archivePath): \(reason)",
            context: [
                "archivePath": archivePath,
                "reason": reason
            ]
        )
    }

 /// Create a file read timeout event
    public static func fileReadTimeout(
        path: String,
        timeoutSeconds: TimeInterval
    ) -> SecurityEvent {
        SecurityEvent(
            type: .fileReadTimeout,
            severity: .warning,
            message: "File read timed out after \(timeoutSeconds)s: \(path)",
            context: [
                "path": path,
                "timeoutSeconds": String(timeoutSeconds)
            ]
        )
    }

 /// Create a detail file corrupted event
    public static func detailFileCorrupted(
        id: UUID,
        reason: String
    ) -> SecurityEvent {
        SecurityEvent(
            type: .detailFileCorrupted,
            severity: .info,
            message: "Detail file corrupted for \(id): \(reason)",
            context: [
                "id": id.uuidString,
                "reason": reason
            ]
        )
    }

 /// Create a signature DB key invalid event
    public static func signatureDBKeyInvalid(
        reason: String
    ) -> SecurityEvent {
        SecurityEvent(
            type: .signatureDBKeyInvalid,
            severity: .critical,
            message: "Signature database key invalid: \(reason)",
            context: ["reason": reason]
        )
    }

 /// Create a pairing SAS mismatch event
    public static func pairingSASMismatch(
        deviceId: String? = nil
    ) -> SecurityEvent {
        var ctx: [String: String] = [:]
        if let devId = deviceId {
            ctx["deviceId"] = devId
        }
        return SecurityEvent(
            type: .pairingSASMismatch,
            severity: .high,
            message: "Pairing SAS confirmation failed",
            context: ctx
        )
    }

 /// Create a meta-event for queue overflow (internal use)
    internal static func queueOverflow(
        queueType: String,
        droppedCount: Int
    ) -> SecurityEvent {
        SecurityEvent(
            type: .limitExceeded,
            severity: .warning,
            message: "Event queue overflow: \(droppedCount) events dropped from \(queueType)",
            context: [
                "queueType": queueType,
                "droppedCount": String(droppedCount)
            ],
            isMetaEvent: true
        )
    }

 // MARK: - Signature Mechanism Alignment Events ( 3.1)

 /// Create a signature provider selected event
 /// - Parameters:
 /// - algorithm: The selected signature algorithm
 /// - offeredSuiteCount: Number of suites offered
 /// - hasPQCSuite: Whether any PQC suite was offered
 /// - deviceId: Optional device ID
    public static func signatureProviderSelected(
        algorithm: String,
        offeredSuiteCount: Int,
        hasPQCSuite: Bool,
        deviceId: String? = nil
    ) -> SecurityEvent {
        var ctx: [String: String] = [
            "algorithm": algorithm,
            "offeredSuiteCount": String(offeredSuiteCount),
            "hasPQCSuite": String(hasPQCSuite)
        ]
        if let devId = deviceId {
            ctx["deviceId"] = devId
        }
        return SecurityEvent(
            type: .signatureProviderSelected,
            severity: .info,
            message: "Signature provider selected: \(algorithm)",
            context: ctx
        )
    }

 /// Create a legacy signature accepted event
 /// - Parameters:
 /// - expectedAlgorithm: The expected signature algorithm
 /// - actualAlgorithm: The actual algorithm used (P-256 ECDSA)
 /// - deviceId: The peer device ID
    public static func legacySignatureAccepted(
        expectedAlgorithm: String,
        actualAlgorithm: String,
        deviceId: String
    ) -> SecurityEvent {
        SecurityEvent(
            type: .legacySignatureAccepted,
            severity: .warning,
            message: "Accepted legacy \(actualAlgorithm) signature for \(expectedAlgorithm) suite (downgrade)",
            context: [
                "expectedAlgorithm": expectedAlgorithm,
                "actualAlgorithm": actualAlgorithm,
                "deviceId": deviceId
            ]
        )
    }

 /// Create a legacy signature accepted event with precondition context
 /// - Parameters:
 /// - preconditionType: The type of precondition that was satisfied
 /// - deviceId: The peer device ID
 /// - channelType: Optional channel type (for authenticated channel precondition)
 ///
 /// **Requirements: 11.7**
    public static func legacySignatureAcceptedWithPrecondition(
        preconditionType: String,
        deviceId: String,
        channelType: String? = nil
    ) -> SecurityEvent {
        var ctx: [String: String] = [
            "preconditionType": preconditionType,
            "deviceId": deviceId,
            "algorithm": "P-256-ECDSA"
        ]
        if let channel = channelType {
            ctx["channelType"] = channel
        }
        return SecurityEvent(
            type: .legacySignatureAccepted,
            severity: .warning,
            message: "Accepted legacy P-256 signature with precondition: \(preconditionType)",
            context: ctx
        )
    }

 /// Create a signature algorithm mismatch event
 /// - Parameters:
 /// - selectedSuite: The suite selected by responder
 /// - sigAAlgorithm: The algorithm used for sigA
 /// - deviceId: Optional device ID
    public static func signatureAlgorithmMismatch(
        selectedSuite: String,
        sigAAlgorithm: String,
        deviceId: String? = nil
    ) -> SecurityEvent {
        var ctx: [String: String] = [
            "selectedSuite": selectedSuite,
            "sigAAlgorithm": sigAAlgorithm
        ]
        if let devId = deviceId {
            ctx["deviceId"] = devId
        }
        return SecurityEvent(
            type: .signatureAlgorithmMismatch,
            severity: .high,
            message: "Suite-signature mismatch: \(selectedSuite) incompatible with sigA algorithm \(sigAAlgorithm)",
            context: ctx
        )
    }

 /// Create a crypto downgrade event
 /// - Parameters:
 /// - fromSuite: The original suite attempted
 /// - toSuite: The fallback suite
 /// - reason: Reason for fallback
 /// - deviceId: Optional device ID
    public static func cryptoDowngrade(
        fromSuite: String,
        toSuite: String,
        reason: String,
        deviceId: String? = nil
    ) -> SecurityEvent {
        var ctx: [String: String] = [
            "fromSuite": fromSuite,
            "toSuite": toSuite,
            "reason": reason
        ]
        if let devId = deviceId {
            ctx["deviceId"] = devId
        }
        return SecurityEvent(
            type: .cryptoDowngrade,
            severity: .warning,
            message: "Crypto downgrade from \(fromSuite) to \(toSuite): \(reason)",
            context: ctx
        )
    }

    @available(*, deprecated, message: "Use cryptoDowngrade(fromSuite:toSuite:reason:deviceId:)")
    public static func handshakeFallback(
        fromSuite: String,
        toSuite: String,
        reason: String,
        deviceId: String? = nil
    ) -> SecurityEvent {
        cryptoDowngrade(fromSuite: fromSuite, toSuite: toSuite, reason: reason, deviceId: deviceId)
    }

 /// Create a crypto downgrade event with full context
 /// - Parameters:
 /// - reason: Reason for fallback
 /// - deviceId: The peer device ID
 /// - cooldownSeconds: Cooldown period before next fallback allowed
 /// - fromStrategy: Original strategy (pqcOnly/classicOnly)
 /// - toStrategy: Fallback strategy
 ///
 /// **Requirements: 9.5, 11.7**
    public static func cryptoDowngradeWithContext(
        reason: String,
        deviceId: String,
        cooldownSeconds: Int,
        fromStrategy: String,
        toStrategy: String
    ) -> SecurityEvent {
        SecurityEvent(
            type: .cryptoDowngrade,
            severity: .warning,
            message: "Crypto downgrade: \(reason)",
            context: [
                // Paper terminology alignment:
                // - downgrade resistance: policy gate + no timeout-triggered fallback + per-peer rate limiting
                // - policy-in-transcript / transcript binding are enforced by TranscriptBuilder+HandshakeDriver
                "downgradeResistance": "policy_gate+no_timeout_fallback+rate_limited",
                "policyInTranscript": "1",
                "transcriptBinding": "1",
                "reason": reason,
                "deviceId": deviceId,
                "cooldownSeconds": String(cooldownSeconds),
                "fromStrategy": fromStrategy,
                "toStrategy": toStrategy
            ]
        )
    }

    @available(*, deprecated, message: "Use cryptoDowngradeWithContext(reason:deviceId:cooldownSeconds:fromStrategy:toStrategy:)")
    public static func handshakeFallbackWithContext(
        reason: String,
        deviceId: String,
        cooldownSeconds: Int,
        fromStrategy: String,
        toStrategy: String
    ) -> SecurityEvent {
        cryptoDowngradeWithContext(
            reason: reason,
            deviceId: deviceId,
            cooldownSeconds: cooldownSeconds,
            fromStrategy: fromStrategy,
            toStrategy: toStrategy
        )
    }

 /// Create a key migration completed event
 /// - Parameters:
 /// - fromTag: The original key tag
 /// - toTag: The new key tag
 /// - keyType: The type of key migrated
    public static func keyMigrationCompleted(
        fromTag: String,
        toTag: String,
        keyType: String
    ) -> SecurityEvent {
        SecurityEvent(
            type: .keyMigrationCompleted,
            severity: .info,
            message: "Key migration completed: \(keyType) from \(fromTag) to \(toTag)",
            context: [
                "fromTag": fromTag,
                "toTag": toTag,
                "keyType": keyType
            ]
        )
    }
}

// MARK: - Codable Storage Types

/// Codable representation for persisting security events
internal struct StoredSecurityEvent: Codable, Sendable {
    let id: String
    let type: String
    let severity: String
    let message: String
    let context: [String: String]
    let timestamp: Date

    init(from event: SecurityEvent) {
        self.id = event.id.uuidString
        self.type = event.type.rawValue
        self.severity = event.severity.rawValue
        self.message = event.message
        self.context = event.context
        self.timestamp = event.timestamp
    }

    func toSecurityEvent() -> SecurityEvent? {
        guard let type = SecurityEventType(rawValue: type),
              let severity = SecurityEventSeverity(rawValue: severity),
              let uuid = UUID(uuidString: id) else {
            return nil
        }
        return SecurityEvent(
            type: type,
            severity: severity,
            message: message,
            context: context,
            timestamp: timestamp,
            id: uuid
        )
    }
}

/// Log of security events for persistence
internal struct SecurityEventLog: Codable, Sendable {
    var events: [StoredSecurityEvent]
    var lastPurge: Date

    init(events: [StoredSecurityEvent] = [], lastPurge: Date = Date()) {
        self.events = events
        self.lastPurge = lastPurge
    }
}
