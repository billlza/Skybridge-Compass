import Foundation

struct IOSDeviceTextQueueEnvelope: Codable, Sendable, Equatable {
    let payload: AppMessage.TextMessagePayload
    let conversationFingerprint: String
}
