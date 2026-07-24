import Foundation
import Network

public extension Notification.Name {
    static let connectableDeviceDiscovered = Notification.Name("ConnectableDeviceDiscovered")
    static let fileTransferStarted = Notification.Name("FileTransferStarted")
    static let fileTransferProgress = Notification.Name("FileTransferProgress")
    static let fileTransferCompleted = Notification.Name("FileTransferCompleted")
    static let fileTransferFailed = Notification.Name("FileTransferFailed")
    static let fileTransferReceiptDeliveryUnknown = Notification.Name(
        "FileTransferReceiptDeliveryUnknown"
    )
    static let quantumCertValidationEvent = Notification.Name("QuantumCertValidationEvent")
}

// MARK: - File Transfer Constants

/// 文件传输常量
public enum FileTransferConstants {
    /// 默认分块大小 (1MB)
    public static let defaultChunkSize: Int = 1024 * 1024

    /// 最大并发传输数
    public static let maxConcurrentTransfers: Int = 3

    /// 传输超时时间（秒）
    public static let transferTimeout: TimeInterval = 300

    /// 单个 LAN 连接候选端点的建立超时（秒）
    public static let connectionTimeout: TimeInterval = 12

    /// 默认传输端口
    public static let defaultPort: UInt16 = 8080
}

struct FileTransferPeerContext: Sendable, Equatable {
    let declaredSenderDeviceId: String?
    let endpointHostOrIP: String?
    let peerLabel: String?
    let transferId: String

    init(
        declaredSenderDeviceId: String?,
        endpointHostOrIP: String?,
        peerLabel: String?,
        transferId: String
    ) {
        self.declaredSenderDeviceId = declaredSenderDeviceId
        self.endpointHostOrIP = endpointHostOrIP
        self.peerLabel = peerLabel
        self.transferId = transferId
    }

    func updating(
        declaredSenderDeviceId: String? = nil,
        transferId: String? = nil
    ) -> Self {
        Self(
            declaredSenderDeviceId: declaredSenderDeviceId ?? self.declaredSenderDeviceId,
            endpointHostOrIP: endpointHostOrIP,
            peerLabel: peerLabel,
            transferId: transferId ?? self.transferId
        )
    }
}

public enum FileTransferReceiptWaitStage: String, Sendable, Equatable {
    case headerTimeout = "receipt_wait_header_timeout"
    case payloadTimeout = "receipt_wait_payload_timeout"
    case authFailed = "receipt_wait_auth_failed"
    case receiverRejected = "receipt_wait_receiver_rejected"
}

enum ClassicTransferCapability {
    static let classicResume = "classic_resume"

    static func supportsClassicResume(in capabilities: [String]) -> Bool {
        capabilities.contains { capability in
            capability.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == classicResume
        }
    }
}

// MARK: - File Chunk

/// 文件块
public struct FileChunk: Codable, Sendable {
    public let index: Int
    public let data: Data
    public let size: Int
    public let checksum: String?
    public let nonce: Data?
    public let authenticationTag: Data?

    public init(
        index: Int,
        data: Data,
        size: Int,
        checksum: String? = nil,
        nonce: Data? = nil,
        authenticationTag: Data? = nil
    ) {
        self.index = index
        self.data = data
        self.size = size
        self.checksum = checksum
        self.nonce = nonce
        self.authenticationTag = authenticationTag
    }
}

// MARK: - File Metadata (wire-compatible with macOS SkyBridgeCore FileTransferManager)

/// 文件元数据（与 macOS 端字段对齐：transferId/fileName/fileSize/fileHash/chunkSize）
public struct FileMetadata: Codable, Sendable {
    public let transferId: String
    public let fileName: String
    public let fileSize: Int64
    public let fileHash: String
    public let chunkSize: Int
    public let securityVersion: Int?
    public let metadataAuthTag: Data?

    // iOS 端附加字段（macOS 端会忽略额外字段）
    public let mimeType: String?
    /// 压缩算法：nil/"" 表示不压缩；当前支持 "zlib"
    public let compression: String?
    public let totalChunks: Int?
    public let resumeOffset: Int64?

    // Sender metadata (optional; used by macOS to show device info & drive trust UI)
    public let senderDeviceId: String?
    public let senderDeviceName: String?
    public let senderPlatform: String?
    public let senderOSVersion: String?
    public let senderModelName: String?
    public let senderChip: String?

    public init(
        transferId: String,
        fileName: String,
        fileSize: Int64,
        fileHash: String,
        chunkSize: Int = FileTransferConstants.defaultChunkSize,
        securityVersion: Int? = nil,
        metadataAuthTag: Data? = nil,
        mimeType: String? = nil,
        compression: String? = nil,
        totalChunks: Int? = nil,
        resumeOffset: Int64? = nil,
        senderDeviceId: String? = nil,
        senderDeviceName: String? = nil,
        senderPlatform: String? = nil,
        senderOSVersion: String? = nil,
        senderModelName: String? = nil,
        senderChip: String? = nil
    ) {
        self.transferId = transferId
        self.fileName = fileName
        self.fileSize = fileSize
        self.fileHash = fileHash
        self.chunkSize = chunkSize
        self.securityVersion = securityVersion
        self.metadataAuthTag = metadataAuthTag
        self.mimeType = mimeType
        self.compression = compression
        self.totalChunks = totalChunks
        self.resumeOffset = resumeOffset
        self.senderDeviceId = senderDeviceId
        self.senderDeviceName = senderDeviceName
        self.senderPlatform = senderPlatform
        self.senderOSVersion = senderOSVersion
        self.senderModelName = senderModelName
        self.senderChip = senderChip
    }
}

// MARK: - Transfer Message

/// 传输消息类型（与 macOS 端对齐：UInt32 + big-endian header）
public enum TransferMessageType: UInt32, Codable, Sendable {
    case metadata = 1
    case chunk = 2
    case complete = 3
    case receipt = 4
    case resumeRequest = 5
    case resumeAck = 6
    case unknown = 0
}

/// 传输消息头
public struct TransferHeader: Sendable {
    public let type: TransferMessageType
    public let length: Int

    public init(type: TransferMessageType, length: Int) {
        self.type = type
        self.length = length
    }

    public var encoded: Data {
        var data = Data()
        var typeBE = type.rawValue.bigEndian
        var lenBE = UInt32(length).bigEndian
        data.append(Data(bytes: &typeBE, count: 4))
        data.append(Data(bytes: &lenBE, count: 4))
        return data
    }

		    public static func decode(from data: Data) -> TransferHeader? {
		        guard data.count >= 8 else { return nil }
		        let (typeValue, lengthValue) = data.withUnsafeBytes { raw -> (UInt32, UInt32) in
		            let type = raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self).bigEndian
		            let length = raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self).bigEndian
		            return (type, length)
		        }
	        let type = TransferMessageType(rawValue: typeValue) ?? .unknown
	        return TransferHeader(type: type, length: Int(lengthValue))
	    }
	}

/// 接收端落盘回执（用于发送端最终成功判定）
public struct TransferReceipt: Codable, Sendable {
    public let transferId: String
    public let success: Bool
    public let receivedBytes: Int64
    public let fileHash: String?
    public let error: String?
    public let securityVersion: Int?
    public let authTag: Data?

    public init(
        transferId: String,
        success: Bool,
        receivedBytes: Int64,
        fileHash: String? = nil,
        error: String? = nil,
        securityVersion: Int? = nil,
        authTag: Data? = nil
    ) {
        self.transferId = transferId
        self.success = success
        self.receivedBytes = receivedBytes
        self.fileHash = fileHash
        self.error = error
        self.securityVersion = securityVersion
        self.authTag = authTag
    }
}

// MARK: - File Transfer Error

/// 文件传输错误
public enum FileTransferError: Error, LocalizedError, Sendable {
    case fileNotFound
    case transferFailed(String)
    case invalidDestination
    case connectionFailed
    case transferCancelled
    case checksumMismatch
    case invalidMetadata
    case diskFull
    case permissionDenied
    case networkError(String)
    case networkStageFailed(stage: String, endpoint: String?, details: String)
    case timeout
    case receiptWaitFailed(stage: FileTransferReceiptWaitStage, details: String?)
    case deliveryConfirmationUnknown
    case partialFileCleanupFailed
    case committedFileReleaseFailed
    case encryptionFailed
    case secureSessionRequired
    case capacityExceeded
    case invalidTransferState

    public var errorDescription: String? {
        switch self {
        case .fileNotFound: return "文件不存在"
        case .transferFailed(let reason): return "传输失败: \(reason)"
        case .invalidDestination: return "无效的目标"
        case .connectionFailed: return "连接失败"
        case .transferCancelled: return "传输已取消"
        case .checksumMismatch: return "校验和不匹配"
        case .invalidMetadata: return "无效的元数据"
        case .diskFull: return "磁盘空间不足"
        case .permissionDenied: return "权限被拒绝"
        case .networkError(let reason): return "网络错误: \(reason)"
        case .networkStageFailed(let stage, let endpoint, let details):
            let endpointSuffix = endpoint.map { " endpoint=\($0)" } ?? ""
            return "网络错误(stage=\(stage)\(endpointSuffix)): \(details)"
        case .timeout: return "传输超时"
        case .receiptWaitFailed(let stage, let details):
            let suffix = details.map { ": \($0)" } ?? ""
            return "等待接收端落盘回执失败(\(stage.rawValue))\(suffix)"
        case .deliveryConfirmationUnknown:
            return "文件数据已发送，但未收到落盘确认；为避免重复文件，系统不会自动重发"
        case .partialFileCleanupFailed:
            return "文件传输失败，且未完成文件清理失败"
        case .committedFileReleaseFailed:
            return "文件已安全落盘，但入站文件句柄释放失败"
        case .encryptionFailed: return "加密失败"
        case .secureSessionRequired: return "需要已认证的安全会话"
        case .capacityExceeded: return "文件传输并发等待队列已满"
        case .invalidTransferState: return "文件传输标识已被另一活动传输占用"
        }
    }
}

enum ClassicTransferDeliveryConfirmationPolicy {
    static func normalizedReceiptWaitError(_ error: Error) -> Error {
        guard let transferError = error as? FileTransferError else {
            return error
        }
        switch transferError {
        case .receiptWaitFailed(let stage, _)
            where stage == .headerTimeout || stage == .payloadTimeout:
            return FileTransferError.deliveryConfirmationUnknown
        case .networkStageFailed(let stage, _, _)
            where stage == "receipt_header"
                || stage == "receipt_header_connection_closed"
                || stage == "receipt_payload"
                || stage == "receipt_payload_connection_closed":
            return FileTransferError.deliveryConfirmationUnknown
        case .timeout:
            return FileTransferError.deliveryConfirmationUnknown
        default:
            return transferError
        }
    }

    static func isUnknown(_ error: Error) -> Bool {
        guard let transferError = error as? FileTransferError,
              case .deliveryConfirmationUnknown = transferError else {
            return false
        }
        return true
    }
}

enum WebRTCCompletionConfirmationPolicy {
    static func normalizedWaitError(_ error: Error) -> Error {
        if error is CancellationError {
            // The complete frame may have committed remotely before cancellation
            // interrupted only the local confirmation wait.
            return FileTransferError.deliveryConfirmationUnknown
        }
        if let waitError = error as? CrossNetworkWebRTCManager.FileTransferWaitError {
            switch waitError {
            case .cancelled:
                return FileTransferError.transferCancelled
            case .timeout, .transportClosed:
                return FileTransferError.deliveryConfirmationUnknown
            }
        }
        if let transferError = error as? FileTransferError {
            return transferError
        }
        return FileTransferError.deliveryConfirmationUnknown
    }
}

enum WebRTCChunkAcknowledgmentRetryPolicy {
    static func shouldRetry(after error: Error) -> Bool {
        guard let waitError = error as? CrossNetworkWebRTCManager.FileTransferWaitError else {
            return false
        }
        if case .timeout = waitError {
            return true
        }
        return false
    }
}

// MARK: - File Transfer Direction

/// 传输方向
public enum TransferDirection: String, Codable, Sendable {
    case outgoing
    case incoming
}

// MARK: - Transfer State

/// 传输状态（内部使用）
public struct TransferState: Sendable {
    public var transferId: String
    public var metadata: FileMetadata?
    public var localURL: URL?
    public var connection: NWConnection?
    public var transferredBytes: Int64 = 0
    public var startTime: Date?
    public var lastUpdateTime: Date?
    public var isCancelled: Bool = false
}
