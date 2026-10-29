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
    /// Optional: integrity hash for chunkData (SHA-256). Backward compatible.
    public let chunkSha256: Data?
    /// Optional: future encryption nonce (for encrypted chunks). Backward compatible.
    public let nonce: Data?
    /// Uncompressed/raw size in bytes (used for progress/offset; optional for compatibility).
    public let rawSize: Int?
    public let receivedBytes: Int64?
    
    /// Optional: future encryption descriptor (e.g. "aes-gcm-256-v1"). Backward compatible.
    public let encryption: String?
    /// Optional: future full-file digest (SHA-256). Backward compatible.
    public let fileSha256: Data?

    /// Optional: Merkle root over per-chunk SHA-256 leaves. Backward compatible.
    public let merkleRoot: Data?
    /// Optional: Signature/MAC over merkleRoot. Backward compatible.
    public let merkleRootSignature: Data?
    /// Optional: Algorithm identifier for merkleRootSignature (e.g. "hmac-sha256-session-v1"). Backward compatible.
    public let merkleRootSignatureAlg: String?

    /// Optional: missing chunk indices requested by receiver. Backward compatible.
    public let missingChunks: [Int]?

    /// Optional: batch transfer grouping. Backward compatible.
    public let batchId: String?
    public let batchIndex: Int?
    public let batchTotal: Int?
    public let relativePath: String?
    
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
        chunkSha256: Data? = nil,
        nonce: Data? = nil,
        rawSize: Int? = nil,
        receivedBytes: Int64? = nil,
        encryption: String? = nil,
        fileSha256: Data? = nil,
        merkleRoot: Data? = nil,
        merkleRootSignature: Data? = nil,
        merkleRootSignatureAlg: String? = nil,
        missingChunks: [Int]? = nil,
        batchId: String? = nil,
        batchIndex: Int? = nil,
        batchTotal: Int? = nil,
        relativePath: String? = nil,
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
        self.chunkSha256 = chunkSha256
        self.nonce = nonce
        self.rawSize = rawSize
        self.receivedBytes = receivedBytes
        self.encryption = encryption
        self.fileSha256 = fileSha256
        self.merkleRoot = merkleRoot
        self.merkleRootSignature = merkleRootSignature
        self.merkleRootSignatureAlg = merkleRootSignatureAlg
        self.missingChunks = missingChunks
        self.batchId = batchId
        self.batchIndex = batchIndex
        self.batchTotal = batchTotal
        self.relativePath = relativePath
        self.message = message
    }
}


