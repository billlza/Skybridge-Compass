import Foundation

// MARK: - File transfer wire payloads

struct FileMetadata: Codable, Sendable {
    let transferId: String
    let fileName: String
    let fileSize: Int64
    let fileHash: String
    let chunkSize: Int
    let securityVersion: Int?
    let metadataAuthTag: Data?
    let compression: String?

    // Sender metadata (optional; used for UI + trust flow)
    let senderDeviceId: String?
    let senderDeviceName: String?
    let senderPlatform: String?
    let senderOSVersion: String?
    let senderModelName: String?
    let senderChip: String?
}

struct FileChunk: Codable, Sendable {
    let index: Int
    let data: Data
    let size: Int
    let nonce: Data?
    let authenticationTag: Data?
}

struct FileTransferReceipt: Codable, Sendable {
    let transferId: String
    let success: Bool
    let receivedBytes: Int64
    let fileHash: String?
    let error: String?
    let securityVersion: Int?
    let authTag: Data?
}

struct ResumeRequestPayload: Codable, Sendable {
    let transferId: String
    let senderDeviceId: String
    let resumeOffset: Int64
    let securityVersion: Int
    let authTag: Data
}

struct ResumeAckPayload: Codable, Sendable {
    let transferId: String
    let accepted: Bool
    let resumeOffset: Int64
    let error: String?
    let securityVersion: Int
    let authTag: Data
}

enum FileTransferWireMessageType: UInt32 {
    case metadata = 1
    case chunk = 2
    case complete = 3
    case receipt = 4
    case resumeRequest = 5
    case resumeAck = 6
    case unknown = 0
}
