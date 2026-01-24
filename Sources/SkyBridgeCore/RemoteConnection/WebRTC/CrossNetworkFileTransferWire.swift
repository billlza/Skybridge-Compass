import Foundation

/// Wire messages for cross-network (WebRTC DataChannel) file transfer.
///
/// This is intentionally **JSON Codable** to keep iOS/macOS interop simple and debuggable.
/// Payload frames are still protected by:
/// - WebRTC DTLS transport security
/// - SkyBridge sessionKeys (AES-GCM) at the application layer
public enum CrossNetworkFileTransferOp: String, Codable, Sendable {
    case metadata
    case metadataAck
    case chunk
    case chunkAck
    case complete
    case completeAck
    case cancel
    case error
}

public struct CrossNetworkFileTransferMessage: Codable, Sendable {
    public let version: Int
    public let op: CrossNetworkFileTransferOp
    public let transferId: String
    
    // Peer info (optional, used for UI/logging)
    public let senderDeviceId: String?
    public let senderDeviceName: String?
    
    // Metadata (for .metadata / .metadataAck)
    public let fileName: String?
    public let fileSize: Int64?
    public let chunkSize: Int?
    public let totalChunks: Int?
    public let mimeType: String?
    
    // Chunk (for .chunk / .chunkAck)
    public let chunkIndex: Int?
    public let chunkData: Data?
    /// Uncompressed/raw size in bytes (used for progress/offset; optional for compatibility).
    public let rawSize: Int?
    public let receivedBytes: Int64?
    
    // Error/cancel (for .error / .cancel)
    public let message: String?
    
    public init(
        version: Int = 1,
        op: CrossNetworkFileTransferOp,
        transferId: String,
        senderDeviceId: String? = nil,
        senderDeviceName: String? = nil,
        fileName: String? = nil,
        fileSize: Int64? = nil,
        chunkSize: Int? = nil,
        totalChunks: Int? = nil,
        mimeType: String? = nil,
        chunkIndex: Int? = nil,
        chunkData: Data? = nil,
        rawSize: Int? = nil,
        receivedBytes: Int64? = nil,
        message: String? = nil
    ) {
        self.version = version
        self.op = op
        self.transferId = transferId
        self.senderDeviceId = senderDeviceId
        self.senderDeviceName = senderDeviceName
        self.fileName = fileName
        self.fileSize = fileSize
        self.chunkSize = chunkSize
        self.totalChunks = totalChunks
        self.mimeType = mimeType
        self.chunkIndex = chunkIndex
        self.chunkData = chunkData
        self.rawSize = rawSize
        self.receivedBytes = receivedBytes
        self.message = message
    }
}


