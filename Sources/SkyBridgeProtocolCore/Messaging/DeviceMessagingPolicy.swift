import Foundation

/// Stable, payload-free reason codes for offline-delivery decisions.
///
/// These values are safe to persist or log. They deliberately contain no peer
/// identifiers, message contents, paths, or underlying error descriptions.
public enum OfflineDeliveryFailureCode: String, Codable, CaseIterable, Sendable, Equatable {
    case invalidMessageType = "invalid_message_type"
    case invalidPayload = "invalid_payload"
    case invalidTargetDeviceIdentifier = "invalid_target_device_identifier"
    case invalidConversationFingerprint = "invalid_conversation_fingerprint"
    case authenticatedIdentityMismatch = "authenticated_identity_mismatch"
    case transportUnavailable = "transport_unavailable"
    case transportFailure = "transport_failure"
    case queueCapacityExceeded = "queue_capacity_exceeded"
    case storageCapacityExceeded = "storage_capacity_exceeded"
    case persistenceFailure = "persistence_failure"
    case stateConflict = "state_conflict"
}

/// The complete result of one offline-delivery attempt.
///
/// Only `retryable` consumes retry budget. Cancellation preserves the pending
/// item, while permanent failures are retained for explicit operator recovery.
public enum OfflineDeliveryDisposition: Sendable, Equatable {
    case delivered
    case retryable(OfflineDeliveryFailureCode)
    case permanentFailure(OfflineDeliveryFailureCode)
    case cancelled
}

public enum DeviceTextMessagePolicyError: String, Error, Sendable, Equatable {
    case emptyText = "empty_text"
    case textTooLong = "text_too_long"
    case textTooLarge = "text_too_large"
    case invalidTargetDeviceIdentifier = "invalid_target_device_identifier"
    case invalidConversationFingerprint = "invalid_conversation_fingerprint"
}

/// Cross-platform validation for device text messages and their identity keys.
public enum DeviceTextMessagePolicy {
    public static let maximumCharacterCount = 8_000
    public static let maximumUTF8ByteCount = 64 * 1_024
    public static let maximumTargetDeviceIdentifierUTF8ByteCount = 512

    public static func validatedText(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw DeviceTextMessagePolicyError.emptyText
        }
        guard value.count <= maximumCharacterCount else {
            throw DeviceTextMessagePolicyError.textTooLong
        }
        guard value.utf8.count <= maximumUTF8ByteCount else {
            throw DeviceTextMessagePolicyError.textTooLarge
        }
        return value
    }

    public static func normalizedTargetDeviceIdentifier(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.count <= maximumTargetDeviceIdentifierUTF8ByteCount,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw DeviceTextMessagePolicyError.invalidTargetDeviceIdentifier
        }
        return value
    }

    public static func normalizedConversationFingerprint(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.utf8.count == 64,
              value.utf8.allSatisfy(Self.isLowercaseASCIIHexDigit) else {
            throw DeviceTextMessagePolicyError.invalidConversationFingerprint
        }
        return value
    }

    private static func isLowercaseASCIIHexDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
    }
}
