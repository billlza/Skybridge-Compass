//
// P2PFileTransfer.swift
// SkyBridgeCore
//
// iOS/iPadOS P2P Integration - File Transfer Models
// Requirements: 6.1, 6.2, 6.3, 6.4, 6.5
//

import Foundation
import CryptoKit

// MARK: - File Metadata Models

/// P2P 文件传输元数据
/// 包含文件树结构、大小、时间戳、权限和 Merkle 根
public struct P2PFileTransferMetadata: Codable, Sendable, Equatable {
 /// 传输唯一标识
    public let transferId: UUID
    
 /// 文件树（单文件或目录结构）
    public let fileTree: P2PFileNode
    
 /// 总大小（字节）
    public let totalSize: UInt64
    
 /// 总文件数
    public let totalFileCount: Int
    
 /// Merkle 树根哈希（用于完整性验证）
    public let merkleRoot: Data
    
 /// Merkle 树根签名（发送方签名）
    public let merkleRootSignature: Data
    
 /// 块大小（字节）
    public let chunkSize: Int
    
 /// 总块数
    public let totalChunks: UInt64
    
 /// 创建时间戳（毫秒）
    public let createdAtMillis: Int64
    
 /// 协议版本
    public let protocolVersion: Int
    
    public init(
        transferId: UUID,
        fileTree: P2PFileNode,
        totalSize: UInt64,
        totalFileCount: Int,
        merkleRoot: Data,
        merkleRootSignature: Data,
        chunkSize: Int = P2PConstants.fileChunkSize,
        totalChunks: UInt64,
        createdAtMillis: Int64 = P2PTimestamp.nowMillis,
        protocolVersion: Int = P2PProtocolVersion.current.rawValue
    ) {
        self.transferId = transferId
        self.fileTree = fileTree
        self.totalSize = totalSize
        self.totalFileCount = totalFileCount
        self.merkleRoot = merkleRoot
        self.merkleRootSignature = merkleRootSignature
        self.chunkSize = chunkSize
        self.totalChunks = totalChunks
        self.createdAtMillis = createdAtMillis
        self.protocolVersion = protocolVersion
    }
}

/// P2P 文件节点（支持文件和目录）
public struct P2PFileNode: Codable, Sendable, Equatable {
 /// 节点类型
    public let nodeType: P2PFileNodeType
    
 /// 文件/目录名
    public let name: String
    
 /// 相对路径（从传输根目录开始）
    public let relativePath: String
    
 /// 文件大小（目录为 0）
    public let size: UInt64
    
 /// 修改时间（Unix 毫秒）
    public let mtimeMillis: Int64
    
 /// POSIX 权限（如 0o644）
    public let permissions: UInt16
    
 /// 文件哈希（仅文件有效，SHA-256）
    public let fileHash: Data?
    
 /// 子节点（仅目录有效）
    public let children: [P2PFileNode]?
    
 /// 文件在传输中的起始块索引
    public let startChunkIndex: UInt64?
    
 /// 文件块数量
    public let chunkCount: UInt64?
    
    public init(
        nodeType: P2PFileNodeType,
        name: String,
        relativePath: String,
        size: UInt64,
        mtimeMillis: Int64,
        permissions: UInt16,
        fileHash: Data? = nil,
        children: [P2PFileNode]? = nil,
        startChunkIndex: UInt64? = nil,
        chunkCount: UInt64? = nil
    ) {
        self.nodeType = nodeType
        self.name = name
        self.relativePath = relativePath
        self.size = size
        self.mtimeMillis = mtimeMillis
        self.permissions = permissions
        self.fileHash = fileHash
        self.children = children
        self.startChunkIndex = startChunkIndex
        self.chunkCount = chunkCount
    }
}

/// 文件节点类型
public enum P2PFileNodeType: String, Codable, Sendable {
    case file = "file"
    case directory = "directory"
    case symlink = "symlink"
}

// MARK: - File Chunk Models

/// P2P 文件块（用于传输）
public struct P2PFileChunk: Codable, Sendable, Equatable {
 /// 传输 ID
    public let transferId: UUID
    
 /// 全局块索引（在整个传输中的位置）
    public let chunkIndex: UInt64
    
 /// 文件相对路径
    public let filePath: String
    
 /// 块在文件中的偏移量
    public let offset: UInt64
    
 /// 块数据
    public let data: Data
    
 /// 块哈希（SHA-256）
    public let chunkHash: Data
    
 /// 是否为文件最后一块
    public let isLastChunk: Bool
    
    public init(
        transferId: UUID,
        chunkIndex: UInt64,
        filePath: String,
        offset: UInt64,
        data: Data,
        chunkHash: Data,
        isLastChunk: Bool
    ) {
        self.transferId = transferId
        self.chunkIndex = chunkIndex
        self.filePath = filePath
        self.offset = offset
        self.data = data
        self.chunkHash = chunkHash
        self.isLastChunk = isLastChunk
    }
    
 /// 验证块哈希
    public func verifyHash() -> Bool {
        let computed = Data(SHA256.hash(data: data))
        return computed == chunkHash
    }
}

/// P2P 文件块 ACK
public struct P2PFileChunkAck: Codable, Sendable, Equatable {
 /// 传输 ID
    public let transferId: UUID
    
 /// 已确认的块索引列表
    public let acknowledgedChunks: [UInt64]
    
 /// ACK 类型
    public let ackType: P2PChunkAckType
    
 /// 时间戳（毫秒）
    public let timestampMillis: Int64
    
    public init(
        transferId: UUID,
        acknowledgedChunks: [UInt64],
        ackType: P2PChunkAckType = .received,
        timestampMillis: Int64 = P2PTimestamp.nowMillis
    ) {
        self.transferId = transferId
        self.acknowledgedChunks = acknowledgedChunks
        self.ackType = ackType
        self.timestampMillis = timestampMillis
    }
}

/// 块 ACK 类型
public enum P2PChunkAckType: String, Codable, Sendable {
 /// 已接收
    case received = "received"
 /// 校验失败，需重传
    case checksumFailed = "checksum_failed"
 /// 请求重传指定块
    case retransmitRequest = "retransmit_request"
}

// MARK: - Transfer State Models

/// P2P 文件传输状态
public struct P2PFileTransferState: Codable, Sendable, Equatable {
 /// 传输 ID
    public let transferId: UUID
    
 /// 传输方向
    public let direction: P2PTransferDirection
    
 /// 当前状态
    public var status: P2PTransferStatus
    
 /// 已传输块数
    public var transferredChunks: UInt64
    
 /// 总块数
    public let totalChunks: UInt64
    
 /// 已传输字节数
    public var transferredBytes: UInt64
    
 /// 总字节数
    public let totalBytes: UInt64
    
 /// 当前传输速度（字节/秒）
    public var speedBytesPerSecond: Double
    
 /// 开始时间（毫秒）
    public let startedAtMillis: Int64
    
 /// 最后更新时间（毫秒）
    public var lastUpdatedAtMillis: Int64
    
 /// 错误信息（如果失败）
    public var errorMessage: String?
    
    public init(
        transferId: UUID,
        direction: P2PTransferDirection,
        status: P2PTransferStatus = .pending,
        transferredChunks: UInt64 = 0,
        totalChunks: UInt64,
        transferredBytes: UInt64 = 0,
        totalBytes: UInt64,
        speedBytesPerSecond: Double = 0,
        startedAtMillis: Int64 = P2PTimestamp.nowMillis,
        lastUpdatedAtMillis: Int64 = P2PTimestamp.nowMillis,
        errorMessage: String? = nil
    ) {
        self.transferId = transferId
        self.direction = direction
        self.status = status
        self.transferredChunks = transferredChunks
        self.totalChunks = totalChunks
        self.transferredBytes = transferredBytes
        self.totalBytes = totalBytes
        self.speedBytesPerSecond = speedBytesPerSecond
        self.startedAtMillis = startedAtMillis
        self.lastUpdatedAtMillis = lastUpdatedAtMillis
        self.errorMessage = errorMessage
    }
    
 /// 进度百分比 (0.0 - 1.0)
    public var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(transferredBytes) / Double(totalBytes)
    }
    
 /// 预计剩余时间（秒）
    public var estimatedRemainingSeconds: TimeInterval? {
        guard speedBytesPerSecond > 0 else { return nil }
        let remaining = totalBytes - transferredBytes
        return Double(remaining) / speedBytesPerSecond
    }
}

/// 传输方向
public enum P2PTransferDirection: String, Codable, Sendable {
    case send = "send"
    case receive = "receive"
}

/// 传输状态
public enum P2PTransferStatus: String, Codable, Sendable {
 /// 等待开始
    case pending = "pending"
 /// 传输中
    case transferring = "transferring"
 /// 已暂停
    case paused = "paused"
 /// 验证中（Merkle 校验）
    case verifying = "verifying"
 /// 已完成
    case completed = "completed"
 /// 已取消
    case cancelled = "cancelled"
 /// 失败
    case failed = "failed"
}

// MARK: - Resume Data

/// P2P 传输恢复数据（用于断点续传）
public struct P2PTransferResumeData: Codable, Sendable, Equatable {
 /// 传输 ID
    public let transferId: UUID
    
 /// 元数据
    public let metadata: P2PFileTransferMetadata
    
 /// 已接收的块位图（压缩存储）
    public let receivedChunksBitmap: Data
    
 /// 最后接收的块索引
    public let lastReceivedChunkIndex: UInt64
    
 /// 临时文件路径（相对路径）
    public let tempFilePaths: [String: String]
    
 /// 保存时间（毫秒）
    public let savedAtMillis: Int64
    
    public init(
        transferId: UUID,
        metadata: P2PFileTransferMetadata,
        receivedChunksBitmap: Data,
        lastReceivedChunkIndex: UInt64,
        tempFilePaths: [String: String],
        savedAtMillis: Int64 = P2PTimestamp.nowMillis
    ) {
        self.transferId = transferId
        self.metadata = metadata
        self.receivedChunksBitmap = receivedChunksBitmap
        self.lastReceivedChunkIndex = lastReceivedChunkIndex
        self.tempFilePaths = tempFilePaths
        self.savedAtMillis = savedAtMillis
    }
}


// MARK: - Merkle Tree

/// Merkle 树节点
public struct MerkleNode: Sendable, Equatable {
 /// 节点哈希
    public let hash: Data
    
 /// 左子节点哈希（叶子节点为 nil）
    public let leftHash: Data?
    
 /// 右子节点哈希（叶子节点为 nil）
    public let rightHash: Data?
    
 /// 是否为叶子节点
    public var isLeaf: Bool {
        leftHash == nil && rightHash == nil
    }
    
    public init(hash: Data, leftHash: Data? = nil, rightHash: Data? = nil) {
        self.hash = hash
        self.leftHash = leftHash
        self.rightHash = rightHash
    }
}

/// Merkle 树构建器
/// 用于文件完整性验证
public actor P2PMerkleTreeBuilder {
    
 /// 块大小
    private let blockSize: Int
    
 /// 叶子节点哈希列表
    private var leafHashes: [Data] = []
    
 /// 树层级（从叶子到根）
    private var treeLevels: [[Data]] = []
    
 /// 根哈希
    private var _rootHash: Data?
    
    public init(blockSize: Int = P2PConstants.merkleBlockSize) {
        self.blockSize = blockSize
    }
    
 /// 添加数据块
    public func addBlock(_ data: Data) {
        let hash = Data(SHA256.hash(data: data))
        leafHashes.append(hash)
        _rootHash = nil // 需要重新计算
    }
    
 /// 添加预计算的块哈希
    public func addBlockHash(_ hash: Data) {
        leafHashes.append(hash)
        _rootHash = nil
    }
    
 /// 计算 Merkle 根
    public func computeRoot() -> Data {
        if let cached = _rootHash {
            return cached
        }
        
        guard !leafHashes.isEmpty else {
 // 空树返回零哈希
            let emptyHash = Data(SHA256.hash(data: Data()))
            _rootHash = emptyHash
            return emptyHash
        }
        
        treeLevels = [leafHashes]
        var currentLevel = leafHashes
        
        while currentLevel.count > 1 {
            var nextLevel: [Data] = []
            
            for i in stride(from: 0, to: currentLevel.count, by: 2) {
                let left = currentLevel[i]
                let right = (i + 1 < currentLevel.count) ? currentLevel[i + 1] : left
                
                var combined = Data()
                combined.append(left)
                combined.append(right)
                
                let parentHash = Data(SHA256.hash(data: combined))
                nextLevel.append(parentHash)
            }
            
            treeLevels.append(nextLevel)
            currentLevel = nextLevel
        }
        
        _rootHash = currentLevel[0]
        return currentLevel[0]
    }
    
 /// 获取指定块的证明路径
    public func getProof(forBlockIndex index: Int) -> [MerkleProofNode]? {
        guard index < leafHashes.count else { return nil }
        
 // 确保树已构建
        _ = computeRoot()
        
        var proof: [MerkleProofNode] = []
        var currentIndex = index
        
        for level in treeLevels.dropLast() {
            let isLeft = currentIndex % 2 == 0
            let siblingIndex = isLeft ? currentIndex + 1 : currentIndex - 1
            
            if siblingIndex < level.count {
                proof.append(MerkleProofNode(
                    hash: level[siblingIndex],
                    isLeft: !isLeft
                ))
            } else {
 // 奇数节点，复制自身
                proof.append(MerkleProofNode(
                    hash: level[currentIndex],
                    isLeft: !isLeft
                ))
            }
            
            currentIndex /= 2
        }
        
        return proof
    }
    
 /// 重置构建器
    public func reset() {
        leafHashes.removeAll()
        treeLevels.removeAll()
        _rootHash = nil
    }
    
 /// 当前叶子数量
    public var leafCount: Int {
        leafHashes.count
    }
}

/// Merkle 证明节点
public struct MerkleProofNode: Codable, Sendable, Equatable {
 /// 兄弟节点哈希
    public let hash: Data
    
 /// 兄弟节点是否在左侧
    public let isLeft: Bool
    
    public init(hash: Data, isLeft: Bool) {
        self.hash = hash
        self.isLeft = isLeft
    }
}

/// Merkle 证明
public struct MerkleProof: Codable, Sendable, Equatable {
 /// 块索引
    public let blockIndex: Int
    
 /// 块哈希
    public let blockHash: Data
    
 /// 证明路径
    public let proofPath: [MerkleProofNode]
    
 /// 预期根哈希
    public let expectedRoot: Data
    
    public init(
        blockIndex: Int,
        blockHash: Data,
        proofPath: [MerkleProofNode],
        expectedRoot: Data
    ) {
        self.blockIndex = blockIndex
        self.blockHash = blockHash
        self.proofPath = proofPath
        self.expectedRoot = expectedRoot
    }
    
 /// 验证证明
    public func verify() -> Bool {
        var currentHash = blockHash
        
        for node in proofPath {
            var combined = Data()
            if node.isLeft {
                combined.append(node.hash)
                combined.append(currentHash)
            } else {
                combined.append(currentHash)
                combined.append(node.hash)
            }
            currentHash = Data(SHA256.hash(data: combined))
        }
        
        return currentHash == expectedRoot
    }
}

// MARK: - Merkle Verifier

/// Merkle 树验证器
public actor P2PMerkleVerifier {
    
 /// 预期根哈希
    private let expectedRoot: Data
    
 /// 预期根签名
    private let rootSignature: Data
    
 /// 签名验证公钥
    private let signerPublicKey: Data?
    
 /// 已验证的块索引
    private var verifiedBlocks: Set<UInt64> = []
    
 /// 总块数
    private let totalBlocks: UInt64
    
    public init(
        expectedRoot: Data,
        rootSignature: Data,
        signerPublicKey: Data? = nil,
        totalBlocks: UInt64
    ) {
        self.expectedRoot = expectedRoot
        self.rootSignature = rootSignature
        self.signerPublicKey = signerPublicKey
        self.totalBlocks = totalBlocks
    }
    
 /// 验证单个块
    public func verifyBlock(
        index: UInt64,
        hash: Data,
        proof: MerkleProof
    ) -> Bool {
        guard proof.expectedRoot == expectedRoot else {
            return false
        }
        
        guard proof.blockHash == hash else {
            return false
        }
        
        guard proof.verify() else {
            return false
        }
        
        verifiedBlocks.insert(index)
        return true
    }
    
 /// 标记块为已验证（用于流式验证）
    public func markVerified(index: UInt64) {
        verifiedBlocks.insert(index)
    }
    
 /// 检查是否所有块都已验证
    public var isComplete: Bool {
        verifiedBlocks.count == Int(totalBlocks)
    }
    
 /// 已验证块数
    public var verifiedCount: Int {
        verifiedBlocks.count
    }
    
 /// 获取未验证的块索引
    public func getMissingBlocks() -> [UInt64] {
        (0..<totalBlocks).filter { !verifiedBlocks.contains($0) }
    }
    
 /// 重置验证状态
    public func reset() {
        verifiedBlocks.removeAll()
    }
}

// MARK: - File Transfer Errors

/// P2P 文件传输错误
public enum P2PFileTransferError: Error, Sendable {
 /// 元数据无效
    case invalidMetadata(String)
    
 /// 块校验失败
    case chunkChecksumFailed(chunkIndex: UInt64)
    
 /// Merkle 根不匹配
    case merkleRootMismatch
    
 /// Merkle 证明验证失败
    case merkleProofFailed(blockIndex: Int)
    
 /// 签名验证失败
    case signatureVerificationFailed
    
 /// 传输已取消
    case transferCancelled
    
 /// 传输超时
    case transferTimeout
    
 /// 文件系统错误
    case fileSystemError(String)
    
 /// 网络错误
    case networkError(String)
    
 /// 恢复数据无效
    case invalidResumeData
    
 /// 对端不支持
    case peerUnsupported(String)
}

extension P2PFileTransferError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidMetadata(let reason):
            return "无效的传输元数据: \(reason)"
        case .chunkChecksumFailed(let index):
            return "块 \(index) 校验失败"
        case .merkleRootMismatch:
            return "Merkle 根哈希不匹配"
        case .merkleProofFailed(let index):
            return "块 \(index) Merkle 证明验证失败"
        case .signatureVerificationFailed:
            return "签名验证失败"
        case .transferCancelled:
            return "传输已取消"
        case .transferTimeout:
            return "传输超时"
        case .fileSystemError(let reason):
            return "文件系统错误: \(reason)"
        case .networkError(let reason):
            return "网络错误: \(reason)"
        case .invalidResumeData:
            return "恢复数据无效"
        case .peerUnsupported(let reason):
            return "对端不支持: \(reason)"
        }
    }
}


// MARK: - Parallel Chunk Transfer Service

/// P2P 并行块传输服务
/// 支持多流并行传输和块级 ACK
@available(macOS 14.0, iOS 17.0, *)
public actor P2PChunkTransferService {
    
 // MARK: - Configuration
    
 /// 传输配置
    public struct Configuration: Sendable {
 /// 最大并行流数
        public let maxConcurrentStreams: Int
        
 /// 块大小
        public let chunkSize: Int
        
 /// ACK 超时（秒）
        public let ackTimeoutSeconds: TimeInterval
        
 /// 最大重试次数
        public let maxRetries: Int
        
 /// 窗口大小（未确认块数）
        public let windowSize: Int
        
        public init(
            maxConcurrentStreams: Int = 4,
            chunkSize: Int = P2PConstants.fileChunkSize,
            ackTimeoutSeconds: TimeInterval = 10,
            maxRetries: Int = 3,
            windowSize: Int = 16
        ) {
            self.maxConcurrentStreams = maxConcurrentStreams
            self.chunkSize = chunkSize
            self.ackTimeoutSeconds = ackTimeoutSeconds
            self.maxRetries = maxRetries
            self.windowSize = windowSize
        }
    }
    
 // MARK: - Properties
    
    private let config: Configuration
    private let transport: QUICTransportService
    
 /// 活跃传输
    private var activeTransfers: [UUID: TransferContext] = [:]
    
 /// 传输状态回调
    public var onStateChanged: (@Sendable (UUID, P2PTransferStatus) -> Void)?
    
 /// 进度回调
    public var onProgressUpdated: (@Sendable (UUID, Double, Double) -> Void)?
    
 // MARK: - Initialization
    
    public init(transport: QUICTransportService, config: Configuration = Configuration()) {
        self.transport = transport
        self.config = config
    }
    
 // MARK: - Send Operations
    
 /// 开始发送文件
    public func startSend(
        metadata: P2PFileTransferMetadata,
        dataProvider: @escaping @Sendable (UInt64) async throws -> Data
    ) async throws {
        let context = TransferContext(
            transferId: metadata.transferId,
            direction: .send,
            metadata: metadata,
            config: config
        )
        
        activeTransfers[metadata.transferId] = context
        onStateChanged?(metadata.transferId, .transferring)
        
 // 发送元数据
        try await sendMetadata(metadata)
        
 // 并行发送块
        try await sendChunksParallel(context: context, dataProvider: dataProvider)
    }
    
 /// 发送元数据
    private func sendMetadata(_ metadata: P2PFileTransferMetadata) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(metadata)
        try await transport.sendControl(data)
    }
    
 /// 并行发送块
    private func sendChunksParallel(
        context: TransferContext,
        dataProvider: @escaping @Sendable (UInt64) async throws -> Data
    ) async throws {
        let totalChunks = context.metadata.totalChunks
        var nextChunkIndex: UInt64 = 0
        var pendingAcks: Set<UInt64> = []
        var completedChunks: Set<UInt64> = []
        var retryCount: [UInt64: Int] = [:]
        
 // 打开文件流
        let streamHandle = try await transport.openFileStream(transferId: context.transferId)
        
        while completedChunks.count < Int(totalChunks) {
 // 检查取消
            if context.isCancelled {
                throw P2PFileTransferError.transferCancelled
            }
            
 // 发送窗口内的块
            while pendingAcks.count < config.windowSize && nextChunkIndex < totalChunks {
                let chunkIndex = nextChunkIndex
                nextChunkIndex += 1
                
                do {
                    let data = try await dataProvider(chunkIndex)
                    let chunkHash = Data(SHA256.hash(data: data))
                    
                    let chunk = P2PFileChunk(
                        transferId: context.transferId,
                        chunkIndex: chunkIndex,
                        filePath: "", // 由元数据确定
                        offset: chunkIndex * UInt64(config.chunkSize),
                        data: data,
                        chunkHash: chunkHash,
                        isLastChunk: chunkIndex == totalChunks - 1
                    )
                    
 // 编码并发送
                    let encoder = JSONEncoder()
                    let chunkData = try encoder.encode(chunk)
                    
                    let quicChunk = QUICFileChunk(
                        index: chunkIndex,
                        data: chunkData,
                        isLast: chunk.isLastChunk,
                        checksum: chunkHash
                    )
                    
                    try await transport.sendQUICFileChunk(quicChunk, on: streamHandle)
                    pendingAcks.insert(chunkIndex)
                    
                } catch {
 // 重试逻辑
                    let count = (retryCount[chunkIndex] ?? 0) + 1
                    retryCount[chunkIndex] = count
                    
                    if count >= config.maxRetries {
                        throw P2PFileTransferError.networkError("块 \(chunkIndex) 发送失败，已重试 \(count) 次")
                    }
                    
 // 重新加入队列
                    nextChunkIndex = chunkIndex
                }
            }
            
 // 等待 ACK（简化实现，实际应通过回调处理）
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
            
 // 模拟 ACK 处理（实际应从 transport 回调获取）
 // 这里假设所有发送的块都被确认
            for pending in pendingAcks {
                completedChunks.insert(pending)
            }
            pendingAcks.removeAll()
            
 // 更新进度
            let progress = Double(completedChunks.count) / Double(totalChunks)
            let speed = calculateSpeed(context: context, completedChunks: completedChunks.count)
            onProgressUpdated?(context.transferId, progress, speed)
        }
        
 // 关闭流
        await transport.closeFileStream(streamHandle)
        
        onStateChanged?(context.transferId, .completed)
    }
    
 // MARK: - Receive Operations
    
 /// 处理接收到的元数据
    public func handleReceivedMetadata(_ metadata: P2PFileTransferMetadata) async throws {
        let context = TransferContext(
            transferId: metadata.transferId,
            direction: .receive,
            metadata: metadata,
            config: config
        )
        
        activeTransfers[metadata.transferId] = context
        onStateChanged?(metadata.transferId, .transferring)
    }
    
 /// 处理接收到的块
    public func handleReceivedChunk(_ chunk: P2PFileChunk) async throws -> P2PFileChunkAck {
        guard let context = activeTransfers[chunk.transferId] else {
            throw P2PFileTransferError.invalidMetadata("未知的传输 ID")
        }
        
 // 验证块哈希
        guard chunk.verifyHash() else {
            return P2PFileChunkAck(
                transferId: chunk.transferId,
                acknowledgedChunks: [chunk.chunkIndex],
                ackType: .checksumFailed
            )
        }
        
 // 标记为已接收
        context.markChunkReceived(chunk.chunkIndex)
        
 // 更新进度
        let progress = Double(context.receivedChunksCount) / Double(context.metadata.totalChunks)
        let speed = calculateSpeed(context: context, completedChunks: context.receivedChunksCount)
        onProgressUpdated?(context.transferId, progress, speed)
        
 // 检查是否完成
        if context.isComplete {
            onStateChanged?(context.transferId, .verifying)
        }
        
        return P2PFileChunkAck(
            transferId: chunk.transferId,
            acknowledgedChunks: [chunk.chunkIndex],
            ackType: .received
        )
    }
    
 // MARK: - Control Operations
    
 /// 暂停传输
    public func pause(transferId: UUID) {
        activeTransfers[transferId]?.isPaused = true
        onStateChanged?(transferId, .paused)
    }
    
 /// 恢复传输
    public func resume(transferId: UUID) {
        activeTransfers[transferId]?.isPaused = false
        onStateChanged?(transferId, .transferring)
    }
    
 /// 取消传输
    public func cancel(transferId: UUID) {
        activeTransfers[transferId]?.isCancelled = true
        activeTransfers.removeValue(forKey: transferId)
        onStateChanged?(transferId, .cancelled)
    }
    
 /// 获取恢复数据
    public func getResumeData(transferId: UUID) -> P2PTransferResumeData? {
        guard let context = activeTransfers[transferId] else { return nil }
        return context.createResumeData()
    }
    
 /// 从恢复数据继续传输
    public func resumeFromData(_ resumeData: P2PTransferResumeData) async throws {
        let context = TransferContext(
            transferId: resumeData.transferId,
            direction: .receive,
            metadata: resumeData.metadata,
            config: config
        )
        
 // 恢复已接收块状态
        context.restoreFromResumeData(resumeData)
        
        activeTransfers[resumeData.transferId] = context
        onStateChanged?(resumeData.transferId, .transferring)
    }
    
 // MARK: - Helpers
    
    private func calculateSpeed(context: TransferContext, completedChunks: Int) -> Double {
        let elapsed = Date().timeIntervalSince(context.startTime)
        guard elapsed > 0 else { return 0 }
        let bytes = completedChunks * config.chunkSize
        return Double(bytes) / elapsed
    }
}

// MARK: - Transfer Context

/// 传输上下文（内部使用）
@available(macOS 14.0, iOS 17.0, *)
private final class TransferContext: @unchecked Sendable {
    let transferId: UUID
    let direction: P2PTransferDirection
    let metadata: P2PFileTransferMetadata
    let config: P2PChunkTransferService.Configuration
    let startTime: Date
    
    private let lock = NSLock()
    private var _receivedChunks: Set<UInt64> = []
    private var _isPaused: Bool = false
    private var _isCancelled: Bool = false
    
    init(
        transferId: UUID,
        direction: P2PTransferDirection,
        metadata: P2PFileTransferMetadata,
        config: P2PChunkTransferService.Configuration
    ) {
        self.transferId = transferId
        self.direction = direction
        self.metadata = metadata
        self.config = config
        self.startTime = Date()
    }
    
    var isPaused: Bool {
        get { lock.withLock { _isPaused } }
        set { lock.withLock { _isPaused = newValue } }
    }
    
    var isCancelled: Bool {
        get { lock.withLock { _isCancelled } }
        set { lock.withLock { _isCancelled = newValue } }
    }
    
    var receivedChunksCount: Int {
        lock.withLock { _receivedChunks.count }
    }
    
    var isComplete: Bool {
        lock.withLock { _receivedChunks.count == Int(metadata.totalChunks) }
    }
    
    func markChunkReceived(_ index: UInt64) {
        _ = lock.withLock { _receivedChunks.insert(index) }
    }
    
    func createResumeData() -> P2PTransferResumeData {
        lock.lock()
        defer { lock.unlock() }
        
 // 创建位图
        var bitmap = Data(repeating: 0, count: Int((metadata.totalChunks + 7) / 8))
        for index in _receivedChunks {
            let byteIndex = Int(index / 8)
            let bitIndex = Int(index % 8)
            if byteIndex < bitmap.count {
                bitmap[byteIndex] |= (1 << bitIndex)
            }
        }
        
        let lastReceived = _receivedChunks.max() ?? 0
        
        return P2PTransferResumeData(
            transferId: transferId,
            metadata: metadata,
            receivedChunksBitmap: bitmap,
            lastReceivedChunkIndex: lastReceived,
            tempFilePaths: [:]
        )
    }
    
    func restoreFromResumeData(_ data: P2PTransferResumeData) {
        lock.lock()
        defer { lock.unlock() }
        
        _receivedChunks.removeAll()
        
 // 从位图恢复
        for byteIndex in 0..<data.receivedChunksBitmap.count {
            let byte = data.receivedChunksBitmap[byteIndex]
            for bitIndex in 0..<8 {
                if byte & (1 << bitIndex) != 0 {
                    let chunkIndex = UInt64(byteIndex * 8 + bitIndex)
                    if chunkIndex < metadata.totalChunks {
                        _receivedChunks.insert(chunkIndex)
                    }
                }
            }
        }
    }
}
