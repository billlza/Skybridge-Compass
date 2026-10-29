import Foundation

@available(iOS 17.0, *)
public extension AppMessage {
    struct ClipboardPayload: Codable, Sendable, Equatable {
        public let mimeType: String
        public let dataBase64: String
        public let sentAt: Date

        public init(mimeType: String, dataBase64: String, sentAt: Date = Date()) {
            self.mimeType = mimeType
            self.dataBase64 = dataBase64
            self.sentAt = sentAt
        }

        public var decodedData: Data? {
            Data(base64Encoded: dataBase64)
        }
    }
}
