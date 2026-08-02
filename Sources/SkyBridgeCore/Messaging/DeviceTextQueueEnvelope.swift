import Foundation

/// Stable legacy and current encoding for a queued text submission.
///
/// Keeping this type outside the service lets the migration boundary decode
/// the exact bytes that older releases persisted without duplicating a shadow
/// schema.
struct DeviceTextQueueEnvelope: Codable, Sendable, Equatable {
    let payload: AppMessage.TextMessagePayload
    let conversationFingerprint: String
}
