import Foundation
import Network

// MARK: - 视频配置模型

/// 视频分辨率枚举
public enum VideoResolution: String, CaseIterable, Codable, Sendable {
    case hd1080p = "1080p"      // 1920x1080
    case qhd2k = "2k"           // 2560x1440
    case uhd4k = "4k"           // 3840x2160
    case apple5k = "5k"         // 5120x2880 (Apple专属)
    
 /// 分辨率尺寸
    public var dimensions: (width: Int, height: Int) {
        switch self {
        case .hd1080p:
            return (1920, 1080)
        case .qhd2k:
            return (2560, 1440)
        case .uhd4k:
            return (3840, 2160)
        case .apple5k:
            return (5120, 2880)
        }
    }
    
 /// 显示名称
    public var displayName: String {
        switch self {
        case .hd1080p:
            return "1080P (Full HD)"
        case .qhd2k:
            return "2K (QHD)"
        case .uhd4k:
            return "4K (Ultra HD)"
        case .apple5k:
            return "5K (Apple Retina)"
        }
    }
    
 /// 像素总数
    public var totalPixels: Int {
        let dim = dimensions
        return dim.width * dim.height
    }
    
 /// 推荐的传输块大小（字节）
    public var recommendedChunkSize: Int {
        switch self {
        case .hd1080p:
            return 2 * 1024 * 1024  // 2MB
        case .qhd2k:
            return 4 * 1024 * 1024  // 4MB
        case .uhd4k:
            return 8 * 1024 * 1024  // 8MB
        case .apple5k:
            return 16 * 1024 * 1024 // 16MB
        }
    }
}

/// 视频帧率枚举
public enum VideoFrameRate: Int, CaseIterable, Codable, Sendable {
    case fps30 = 30
    case fps60 = 60
    case fps120 = 120
    
 /// 显示名称
    public var displayName: String {
        return "\(rawValue) fps"
    }
    
 /// 每秒数据量倍数（相对于30fps）
    public var dataRateMultiplier: Double {
        return Double(rawValue) / 30.0
    }
    
 /// 推荐的缓冲区大小（字节）
    public var recommendedBufferSize: Int {
        switch self {
        case .fps30:
            return 128 * 1024   // 128KB
        case .fps60:
            return 256 * 1024   // 256KB
        case .fps120:
            return 512 * 1024   // 512KB
        }
    }
}

/// 视频传输配置
public struct VideoTransferConfiguration: Codable, Sendable {
    public let resolution: VideoResolution
    public let frameRate: VideoFrameRate
    public let enableHardwareAcceleration: Bool
    public let enableAppleSiliconOptimization: Bool
    public let compressionQuality: VideoCompressionQuality
    public let adaptiveBitrate: Bool
    
 /// 默认配置
    public static let `default` = VideoTransferConfiguration(
        resolution: .hd1080p,
        frameRate: .fps30,
        enableHardwareAcceleration: true,
        enableAppleSiliconOptimization: true,
        compressionQuality: .balanced,
        adaptiveBitrate: true
    )
    
 /// 高性能配置（适用于Apple Silicon）
    public static let highPerformance = VideoTransferConfiguration(
        resolution: .apple5k,
        frameRate: .fps120,
        enableHardwareAcceleration: true,
        enableAppleSiliconOptimization: true,
        compressionQuality: .fast,
        adaptiveBitrate: true
    )
    
 /// 高质量配置
    public static let highQuality = VideoTransferConfiguration(
        resolution: .uhd4k,
        frameRate: .fps60,
        enableHardwareAcceleration: true,
        enableAppleSiliconOptimization: true,
        compressionQuality: .maximum,
        adaptiveBitrate: false
    )
    
 /// 计算预估数据传输率（字节/秒）
    public var estimatedDataRate: Int64 {
        let baseRate: Int64
        switch resolution {
        case .hd1080p:
            baseRate = 5_000_000    // 5MB/s 基准
        case .qhd2k:
            baseRate = 12_000_000   // 12MB/s
        case .uhd4k:
            baseRate = 25_000_000   // 25MB/s
        case .apple5k:
            baseRate = 40_000_000   // 40MB/s
        }
        
        let frameRateMultiplier = frameRate.dataRateMultiplier
        let compressionMultiplier = compressionQuality.compressionRatio
        
        return Int64(Double(baseRate) * frameRateMultiplier * compressionMultiplier)
    }
    
 /// 获取优化的传输配置
    public var optimizedTransferConfiguration: TransferConfiguration {
        return TransferConfiguration(
            maxConcurrentTransfers: enableAppleSiliconOptimization ? 8 : 4,
            chunkSize: resolution.recommendedChunkSize,
            maxThreadsPerTransfer: enableAppleSiliconOptimization ? 8 : 4,
            compressionEnabled: compressionQuality != .none,
            encryptionEnabled: true,
            resumeEnabled: true,
            bufferSize: frameRate.recommendedBufferSize
        )
    }
}

/// 视频压缩质量
public enum VideoCompressionQuality: String, CaseIterable, Codable, Sendable {
    case none = "none"          // 无压缩
    case fast = "fast"          // 快速压缩
    case balanced = "balanced"  // 平衡压缩
    case maximum = "maximum"    // 最大压缩
    
 /// 显示名称
    public var displayName: String {
        switch self {
        case .none:
            return "无压缩"
        case .fast:
            return "快速压缩"
        case .balanced:
            return "平衡压缩"
        case .maximum:
            return "最大压缩"
        }
    }
    
 /// 压缩比率（1.0表示无压缩）
    public var compressionRatio: Double {
        switch self {
        case .none:
            return 1.0
        case .fast:
            return 0.8
        case .balanced:
            return 0.6
        case .maximum:
            return 0.4
        }
    }
}

// MARK: - 传输配置

/// 传输配置结构
public struct TransferConfiguration: Codable, Sendable {
    public let maxConcurrentTransfers: Int
    public let chunkSize: Int
    public let maxThreadsPerTransfer: Int
    public let compressionEnabled: Bool
    public let encryptionEnabled: Bool
    public let resumeEnabled: Bool
    public let bufferSize: Int
    
    public static let `default` = TransferConfiguration(
        maxConcurrentTransfers: 5,
        chunkSize: 1024 * 1024, // 1MB
        maxThreadsPerTransfer: 4,
        compressionEnabled: true,
        encryptionEnabled: true,
        resumeEnabled: true,
        bufferSize: 64 * 1024 // 64KB
    )
}

// MARK: - 文件传输会话

/// 文件传输会话 - 管理单个文件的传输状态和进度
@MainActor
public class FileTransferSession: ObservableObject, Identifiable {
    
 // MARK: - 发布属性
    
    @Published public var progress: Double = 0.0
    @Published public var state: TransferState = .preparing
    @Published public var speed: Double = 0.0 // 字节/秒
    @Published public var estimatedTimeRemaining: TimeInterval = 0.0
    @Published public var error: Error?
    
 // MARK: - 基本属性
    
    public let id: String
    public let type: TransferType
    public let fileName: String
    public let fileSize: Int64
    public let localURL: URL
    public let remoteDeviceId: String
    public let startTime: Date
    public let configuration: TransferConfiguration
    
 // MARK: - 私有属性
    
    private var bytesTransferred: Int64 = 0
    private var lastProgressUpdate: Date = Date()
    private var speedSamples: [Double] = []
    private let maxSpeedSamples = 10
    
 // MARK: - 初始化
    
    public init(
        id: String,
        type: TransferType,
        fileName: String,
        fileSize: Int64,
        localURL: URL,
        remoteDeviceId: String,
        configuration: TransferConfiguration
    ) {
        self.id = id
        self.type = type
        self.fileName = fileName
        self.fileSize = fileSize
        self.localURL = localURL
        self.remoteDeviceId = remoteDeviceId
        self.configuration = configuration
        self.startTime = Date()
    }
    
 // MARK: - 状态管理
    
 /// 开始传输
    public func start() {
        state = .transferring
    }
    
 /// 暂停传输
    public func pause() {
        state = .paused
    }
    
 /// 恢复传输
    public func resume() async throws {
        guard state == .paused else { return }
        state = .transferring
    }
    
 /// 取消传输
    public func cancel() {
        state = .cancelled
    }
    
 /// 完成传输
    public func complete() {
        state = .completed
        progress = 1.0
    }
    
 /// 设置错误状态
    public func setError(_ error: Error) {
        self.error = error
        self.state = .failed
    }
    
 // MARK: - 进度更新
    
 /// 更新传输进度
    public func updateProgress(_ newProgress: Double) {
        let oldProgress = progress
        progress = min(max(newProgress, 0.0), 1.0)
        
 // 计算传输速度
        let now = Date()
        let timeDelta = now.timeIntervalSince(lastProgressUpdate)
        
        if timeDelta > 0.1 { // 每100ms更新一次速度
            let progressDelta = progress - oldProgress
            let bytesDelta = Int64(progressDelta * Double(fileSize))
            let currentSpeed = Double(bytesDelta) / timeDelta
            
 // 添加到速度样本
            speedSamples.append(currentSpeed)
            if speedSamples.count > maxSpeedSamples {
                speedSamples.removeFirst()
            }
            
 // 计算平均速度
            speed = speedSamples.reduce(0, +) / Double(speedSamples.count)
            
 // 估算剩余时间
            if speed > 0 {
                let remainingBytes = Double(fileSize) * (1.0 - progress)
                estimatedTimeRemaining = remainingBytes / speed
            }
            
            lastProgressUpdate = now
        }
    }
    
 /// 更新已传输字节数
    public func updateBytesTransferred(_ bytes: Int64) {
        bytesTransferred = bytes
        updateProgress(Double(bytes) / Double(fileSize))
    }
    
 // MARK: - 计算属性
    
 /// 已传输的字节数
    public var transferredBytes: Int64 {
        return Int64(Double(fileSize) * progress)
    }
    
 /// 剩余字节数
    public var remainingBytes: Int64 {
        return fileSize - transferredBytes
    }
    
 /// 传输持续时间
    public var duration: TimeInterval {
        return Date().timeIntervalSince(startTime)
    }
    
 /// 平均传输速度
    public var averageSpeed: Double {
        guard duration > 0 else { return 0 }
        return Double(transferredBytes) / duration
    }
}

// MARK: - 传输类型

/// 传输类型枚举
public enum TransferType: String, CaseIterable, Codable {
    case send = "send"      // 发送文件
    case receive = "receive" // 接收文件
    
 /// 显示名称
    public var displayName: String {
        switch self {
        case .send:
            return "发送"
        case .receive:
            return "接收"
        }
    }
    
 /// 图标名称
    public var iconName: String {
        switch self {
        case .send:
            return "arrow.up.circle"
        case .receive:
            return "arrow.down.circle"
        }
    }
}

// MARK: - 传输状态

/// 传输状态枚举
public enum TransferState: String, CaseIterable, Codable {
    case preparing = "preparing"     // 准备中
    case transferring = "transferring" // 传输中
    case paused = "paused"          // 已暂停
    case completed = "completed"     // 已完成
    case failed = "failed"          // 失败
    case cancelled = "cancelled"     // 已取消
    
 /// 显示名称
    public var displayName: String {
        switch self {
        case .preparing:
            return "准备中"
        case .transferring:
            return "传输中"
        case .paused:
            return "已暂停"
        case .completed:
            return "已完成"
        case .failed:
            return "失败"
        case .cancelled:
            return "已取消"
        }
    }
    
 /// 颜色
    public var color: String {
        switch self {
        case .preparing:
            return "orange"
        case .transferring:
            return "blue"
        case .paused:
            return "yellow"
        case .completed:
            return "green"
        case .failed:
            return "red"
        case .cancelled:
            return "gray"
        }
    }
    
 /// 是否为活跃状态
    public var isActive: Bool {
        return self == .preparing || self == .transferring
    }
    
 /// 是否为终止状态
    public var isTerminal: Bool {
        return self == .completed || self == .failed || self == .cancelled
    }
}

// MARK: - 文件传输请求

/// 文件传输请求结构
public struct FileTransferRequest: Codable, Identifiable {
    public let id: String
    public let fileName: String
    public let fileSize: Int64
    public let senderId: String
    public let compressionEnabled: Bool
    public let encryptionEnabled: Bool
    public let timestamp: Date
    public let metadata: [String: String]
    
    public init(
        id: String,
        fileName: String,
        fileSize: Int64,
        senderId: String,
        compressionEnabled: Bool = true,
        encryptionEnabled: Bool = true,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.fileName = fileName
        self.fileSize = fileSize
        self.senderId = senderId
        self.compressionEnabled = compressionEnabled
        self.encryptionEnabled = encryptionEnabled
        self.timestamp = Date()
        self.metadata = metadata
    }
    
 /// 格式化文件大小
    public var formattedFileSize: String {
        let formatter = ByteCountFormatter()
        return formatter.string(fromByteCount: fileSize)
    }
    
 /// 文件扩展名
    public var fileExtension: String {
        return (fileName as NSString).pathExtension.lowercased()
    }
    
 /// 文件类型
    public var fileType: FileType {
        return FileType.from(extension: fileExtension)
    }
}

// MARK: - 文件传输元数据

/// 文件传输元数据结构
public struct FileTransferMetadata: Codable {
    public let transferId: String
    public let fileName: String
    public let fileSize: Int64
    public let checksum: String
 // 可选：整文件Merkle根与哈希算法（用于分块AEAD完整性之外的全局校验/断点续传）
    public let merkleRoot: String?
    public let hashAlgorithm: String?
    public let compressionEnabled: Bool
    public let encryptionEnabled: Bool
    public let chunkSize: Int
    public let timestamp: Date
 /// 整文件校验签名（对 checksum 进行签名，避免大文件一次性读入内存）
    public let fileSignature: Data?
 /// 签名算法提示（如 ML-DSA / P256 等）
    public let signatureAlgorithm: String?
 /// 签名方标识（用于查找公钥）
    public let signerPeerId: String?
    
    public init(
        transferId: String,
        fileName: String,
        fileSize: Int64,
        checksum: String,
        merkleRoot: String? = nil,
        hashAlgorithm: String? = "SHA256",
        compressionEnabled: Bool = false,
        encryptionEnabled: Bool = false,
        chunkSize: Int = 1024 * 1024,
        fileSignature: Data? = nil,
        signatureAlgorithm: String? = nil,
        signerPeerId: String? = nil
    ) {
        self.transferId = transferId
        self.fileName = fileName
        self.fileSize = fileSize
        self.checksum = checksum
        self.merkleRoot = merkleRoot
        self.hashAlgorithm = hashAlgorithm
        self.compressionEnabled = compressionEnabled
        self.encryptionEnabled = encryptionEnabled
        self.chunkSize = chunkSize
        self.timestamp = Date()
        self.fileSignature = fileSignature
        self.signatureAlgorithm = signatureAlgorithm
        self.signerPeerId = signerPeerId
    }
    
 /// 格式化文件大小
    public var formattedFileSize: String {
        let formatter = ByteCountFormatter()
        return formatter.string(fromByteCount: fileSize)
    }
    
 /// 文件扩展名
    public var fileExtension: String {
        return (fileName as NSString).pathExtension.lowercased()
    }
    
 /// 预计传输块数
    public var estimatedChunkCount: Int {
        return Int((fileSize + Int64(chunkSize) - 1) / Int64(chunkSize))
    }
}

// MARK: - 文件数据块包

/// 文件数据块包结构
public struct FileChunkPacket: Codable {
    public let transferId: String
    public let chunkIndex: Int
    public let totalChunks: Int
    public let data: Data
 // AEAD 信息（可选）：若存在则 data 为纯密文，需要使用 nonce+tag 验证
    public let aeadNonce: Data?
    public let aeadTag: Data?
    public let isCompressed: Bool
    public let isEncrypted: Bool
    public let checksum: String
    public let timestamp: Date
    
    public init(
        transferId: String,
        chunkIndex: Int,
        totalChunks: Int,
        data: Data,
        aeadNonce: Data? = nil,
        aeadTag: Data? = nil,
        isCompressed: Bool = false,
        isEncrypted: Bool = false,
        checksum: String
    ) {
        self.transferId = transferId
        self.chunkIndex = chunkIndex
        self.totalChunks = totalChunks
        self.data = data
        self.aeadNonce = aeadNonce
        self.aeadTag = aeadTag
        self.isCompressed = isCompressed
        self.isEncrypted = isEncrypted
        self.checksum = checksum
        self.timestamp = Date()
    }
    
 /// 数据块大小
    public var chunkSize: Int {
        return data.count
    }
    
 /// 是否为最后一个数据块
    public var isLastChunk: Bool {
        return chunkIndex == totalChunks - 1
    }
    
 /// 进度百分比
    public var progressPercentage: Double {
        return Double(chunkIndex + 1) / Double(totalChunks)
    }
}

// MARK: - 传输记录

/// 文件传输历史记录
public struct FileTransferRecord: Codable, Identifiable {
    public let id: String
    public let fileName: String
    public let fileSize: Int64
    public let type: TransferType
    public let remoteDeviceId: String
    public let startTime: Date
    public let endTime: Date
    public let success: Bool
    public let averageSpeed: Double
    public let metadata: [String: String]
    
    public init(
        id: String,
        fileName: String,
        fileSize: Int64,
        type: TransferType,
        remoteDeviceId: String,
        startTime: Date,
        endTime: Date,
        success: Bool,
        averageSpeed: Double = 0.0,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.fileName = fileName
        self.fileSize = fileSize
        self.type = type
        self.remoteDeviceId = remoteDeviceId
        self.startTime = startTime
        self.endTime = endTime
        self.success = success
        self.averageSpeed = averageSpeed
        self.metadata = metadata
    }
    
 /// 传输持续时间
    public var duration: TimeInterval {
        return endTime.timeIntervalSince(startTime)
    }
    
 /// 格式化的持续时间
    public var formattedDuration: String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: duration) ?? "0秒"
    }
    
 /// 格式化的文件大小
    public var formattedFileSize: String {
        return ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
    
 /// 格式化的传输速度
    public var formattedSpeed: String {
        let formatter = ByteCountFormatter()
        return "\(formatter.string(fromByteCount: Int64(averageSpeed)))/s"
    }
}

// MARK: - 文件类型

/// 文件类型枚举
public enum FileType: String, CaseIterable {
    case document = "document"
    case image = "image"
    case video = "video"
    case audio = "audio"
    case archive = "archive"
    case application = "application"
    case unknown = "unknown"
    
 /// 从文件扩展名推断文件类型
    public static func from(extension ext: String) -> FileType {
        switch ext.lowercased() {
        case "txt", "doc", "docx", "pdf", "rtf", "pages":
            return .document
        case "jpg", "jpeg", "png", "gif", "bmp", "tiff", "svg", "webp":
            return .image
        case "mp4", "avi", "mov", "mkv", "wmv", "flv", "webm":
            return .video
        case "mp3", "wav", "aac", "flac", "ogg", "m4a":
            return .audio
        case "zip", "rar", "7z", "tar", "gz", "bz2":
            return .archive
        case "app", "dmg", "pkg", "exe", "msi":
            return .application
        default:
            return .unknown
        }
    }
    
 /// 显示名称
    public var displayName: String {
        switch self {
        case .document:
            return "文档"
        case .image:
            return "图片"
        case .video:
            return "视频"
        case .audio:
            return "音频"
        case .archive:
            return "压缩包"
        case .application:
            return "应用程序"
        case .unknown:
            return "未知"
        }
    }
    
 /// 图标名称
    public var iconName: String {
        switch self {
        case .document:
            return "doc.text"
        case .image:
            return "photo"
        case .video:
            return "video"
        case .audio:
            return "music.note"
        case .archive:
            return "archivebox"
        case .application:
            return "app"
        case .unknown:
            return "questionmark.circle"
        }
    }
    
 /// 颜色
    public var color: String {
        switch self {
        case .document:
            return "blue"
        case .image:
            return "green"
        case .video:
            return "purple"
        case .audio:
            return "orange"
        case .archive:
            return "brown"
        case .application:
            return "red"
        case .unknown:
            return "gray"
        }
    }
}

// MARK: - 传输统计

/// 传输统计信息
public struct TransferStatistics: Codable {
    public let totalTransfers: Int
    public let successfulTransfers: Int
    public let failedTransfers: Int
    public let totalBytesTransferred: Int64
    public let averageSpeed: Double
    public let totalDuration: TimeInterval
    
    public init(
        totalTransfers: Int = 0,
        successfulTransfers: Int = 0,
        failedTransfers: Int = 0,
        totalBytesTransferred: Int64 = 0,
        averageSpeed: Double = 0.0,
        totalDuration: TimeInterval = 0.0
    ) {
        self.totalTransfers = totalTransfers
        self.successfulTransfers = successfulTransfers
        self.failedTransfers = failedTransfers
        self.totalBytesTransferred = totalBytesTransferred
        self.averageSpeed = averageSpeed
        self.totalDuration = totalDuration
    }
    
 /// 成功率
    public var successRate: Double {
        guard totalTransfers > 0 else { return 0.0 }
        return Double(successfulTransfers) / Double(totalTransfers)
    }
    
 /// 格式化的成功率
    public var formattedSuccessRate: String {
        return String(format: "%.1f%%", successRate * 100)
    }
    
 /// 格式化的总传输量
    public var formattedTotalBytes: String {
        return ByteCountFormatter.string(fromByteCount: totalBytesTransferred, countStyle: .file)
    }
    
 /// 格式化的平均传输速度
    public var formattedAverageSpeed: String {
        let formatter = ByteCountFormatter()
        return "\(formatter.string(fromByteCount: Int64(averageSpeed)))/s"
    }
    
 /// 格式化的总持续时间
    public var formattedTotalDuration: String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: totalDuration) ?? "0分钟"
    }
}

// MARK: - 传输配置

/// 传输质量设置
public struct TransferQualitySettings: Codable, Sendable {
    public let priority: TransferPriority
    public let compressionLevel: CompressionLevel
    public let encryptionStrength: EncryptionStrength
    public let retryAttempts: Int
    public let timeoutInterval: TimeInterval
    
    public static let `default` = TransferQualitySettings(
        priority: .normal,
        compressionLevel: .balanced,
        encryptionStrength: .high,
        retryAttempts: 3,
        timeoutInterval: 30.0
    )
    
    public static let highSpeed = TransferQualitySettings(
        priority: .high,
        compressionLevel: .fast,
        encryptionStrength: .standard,
        retryAttempts: 1,
        timeoutInterval: 10.0
    )
    
    public static let highSecurity = TransferQualitySettings(
        priority: .normal,
        compressionLevel: .maximum,
        encryptionStrength: .maximum,
        retryAttempts: 5,
        timeoutInterval: 60.0
    )
}

/// 传输优先级
public enum TransferPriority: String, CaseIterable, Codable, Sendable {
    case low = "low"
    case normal = "normal"
    case high = "high"
    case urgent = "urgent"
    
    public var displayName: String {
        switch self {
        case .low: return "低"
        case .normal: return "普通"
        case .high: return "高"
        case .urgent: return "紧急"
        }
    }
}

/// 压缩级别
public enum CompressionLevel: String, CaseIterable, Codable, Sendable {
    case none = "none"
    case fast = "fast"
    case balanced = "balanced"
    case maximum = "maximum"
    
    public var displayName: String {
        switch self {
        case .none: return "无压缩"
        case .fast: return "快速"
        case .balanced: return "平衡"
        case .maximum: return "最大"
        }
    }
}

/// 加密强度
public enum EncryptionStrength: String, CaseIterable, Codable, Sendable {
    case none = "none"
    case standard = "standard"
    case high = "high"
    case maximum = "maximum"
    
    public var displayName: String {
        switch self {
        case .none: return "无加密"
        case .standard: return "标准"
        case .high: return "高强度"
        case .maximum: return "最大强度"
        }
    }
}

/// 传输完成包
public struct TransferCompletePacket: Codable {
    public let transferId: String
    public let timestamp: Date
    
    public init(transferId: String) {
        self.transferId = transferId
        self.timestamp = Date()
    }
}

/// 优化缓冲区类型
public struct OptimizedBuffer<T> {
    public let capacity: Int
    public let elementType: T.Type
    
    public init(capacity: Int, elementType: T.Type) {
        self.capacity = capacity
        self.elementType = elementType
    }
}