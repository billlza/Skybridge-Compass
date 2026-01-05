// FileTransferSignalingService.swift
// SkyBridgeCore
//
// 文件传输信令服务 - 处理文件传输相关的信令消息
// Created for web-agent-integration spec 12

import Foundation
import OSLog

// MARK: - File Transfer State

/// 文件传输状态
@available(macOS 14.0, *)
public enum FileTransferState: String, Sendable {
    case idle = "idle"
    case awaitingAck = "awaiting_ack"
    case transferring = "transferring"
    case completed = "completed"
    case failed = "failed"
    case cancelled = "cancelled"
}

/// 文件传输方向
@available(macOS 14.0, *)
public enum FileTransferDirection: String, Sendable {
    case sending = "sending"
    case receiving = "receiving"
}

/// 文件传输信息
@available(macOS 14.0, *)
public struct FileTransferInfo: Sendable, Equatable {
    public let fileId: String
    public let fileName: String
    public let fileSize: Int64
    public let mimeType: String?
    public let checksum: String?
    public let direction: FileTransferDirection
    public var state: FileTransferState
    public var bytesTransferred: Int64
    public let startTime: Date
    
    public init(
        fileId: String,
        fileName: String,
        fileSize: Int64,
        mimeType: String? = nil,
        checksum: String? = nil,
        direction: FileTransferDirection,
        state: FileTransferState = .idle,
        bytesTransferred: Int64 = 0
    ) {
        self.fileId = fileId
        self.fileName = fileName
        self.fileSize = fileSize
        self.mimeType = mimeType
        self.checksum = checksum
        self.direction = direction
        self.state = state
        self.bytesTransferred = bytesTransferred
        self.startTime = Date()
    }
    
 /// 传输进度 (0.0 - 1.0)
    public var progress: Double {
        guard fileSize > 0 else { return 0 }
        return Double(bytesTransferred) / Double(fileSize)
    }
}

// MARK: - File Transfer Signaling Service

/// 文件传输信令服务
@available(macOS 14.0, *)
@MainActor
public final class FileTransferSignalingService: ObservableObject {
    
 // MARK: - Properties
    
    private let logger = Logger(subsystem: "com.skybridge.transfer", category: "FileTransferSignaling")
    
 /// 当前活跃的文件传输
    @Published public private(set) var activeTransfers: [String: FileTransferInfo] = [:]
    
 /// 文件元数据接收回调
    public var onFileMetaReceived: ((FileMetaMessage) -> Bool)?
    
 /// 文件传输完成回调
    public var onFileTransferCompleted: ((String, Bool) -> Void)?
    
 // MARK: - Initialization
    
    public init() {}
    
 // MARK: - Sending Files
    
 /// 发送文件元数据
 /// - Parameters:
 /// - fileName: 文件名
 /// - fileSize: 文件大小
 /// - mimeType: MIME 类型
 /// - checksum: 校验和
 /// - Returns: 文件传输信息
    public func sendFileMeta(
        fileName: String,
        fileSize: Int64,
        mimeType: String? = nil,
        checksum: String? = nil
    ) -> (message: FileMetaMessage, transferInfo: FileTransferInfo) {
        let fileId = UUID().uuidString
        
        let message = FileMetaMessage(
            fileId: fileId,
            fileName: fileName,
            fileSize: fileSize,
            mimeType: mimeType,
            checksum: checksum
        )
        
        let transferInfo = FileTransferInfo(
            fileId: fileId,
            fileName: fileName,
            fileSize: fileSize,
            mimeType: mimeType,
            checksum: checksum,
            direction: .sending,
            state: .awaitingAck
        )
        
        activeTransfers[fileId] = transferInfo
        logger.info("📤 发送文件元数据: \(fileName, privacy: .public) (\(fileSize) bytes)")
        
        return (message, transferInfo)
    }
    
 /// 发送文件传输结束消息
 /// - Parameters:
 /// - fileId: 文件 ID
 /// - success: 是否成功
 /// - bytesTransferred: 已传输字节数
 /// - Returns: 文件结束消息
    public func sendFileEnd(
        fileId: String,
        success: Bool,
        bytesTransferred: Int64
    ) -> FileEndMessage {
        let message = FileEndMessage(
            fileId: fileId,
            success: success,
            bytesTransferred: bytesTransferred
        )
        
        if var transfer = activeTransfers[fileId] {
            transfer.state = success ? .completed : .failed
            transfer.bytesTransferred = bytesTransferred
            activeTransfers[fileId] = transfer
        }
        
        logger.info("📤 发送文件结束: fileId=\(fileId, privacy: .public) success=\(success)")
        
        return message
    }
    
 // MARK: - Receiving Files
    
 /// 处理接收到的文件元数据
 /// - Parameter message: 文件元数据消息
 /// - Returns: 确认消息
    public func handleFileMeta(_ message: FileMetaMessage) -> FileAckMetaMessage {
 // 检查是否接受文件
        let accepted = onFileMetaReceived?(message) ?? true
        
        if accepted {
            let transferInfo = FileTransferInfo(
                fileId: message.fileId,
                fileName: message.fileName,
                fileSize: message.fileSize,
                mimeType: message.mimeType,
                checksum: message.checksum,
                direction: .receiving,
                state: .transferring
            )
            
            activeTransfers[message.fileId] = transferInfo
            logger.info("📥 接受文件: \(message.fileName, privacy: .public) (\(message.fileSize) bytes)")
        } else {
            logger.info("📥 拒绝文件: \(message.fileName, privacy: .public)")
        }
        
        return FileAckMetaMessage(
            fileId: message.fileId,
            accepted: accepted,
            reason: accepted ? nil : "用户拒绝接收"
        )
    }
    
 /// 处理接收到的文件确认消息
 /// - Parameter message: 文件确认消息
    public func handleFileAckMeta(_ message: FileAckMetaMessage) {
        guard var transfer = activeTransfers[message.fileId] else {
            logger.warning("⚠️ 收到未知文件的确认: \(message.fileId, privacy: .public)")
            return
        }
        
        if message.accepted {
            transfer.state = .transferring
            logger.info("✅ 文件传输已确认: \(transfer.fileName, privacy: .public)")
        } else {
            transfer.state = .failed
            logger.warning("❌ 文件传输被拒绝: \(transfer.fileName, privacy: .public) - \(message.reason ?? "未知原因", privacy: .public)")
        }
        
        activeTransfers[message.fileId] = transfer
    }
    
 /// 处理接收到的文件结束消息
 /// - Parameter message: 文件结束消息
    public func handleFileEnd(_ message: FileEndMessage) {
        guard var transfer = activeTransfers[message.fileId] else {
            logger.warning("⚠️ 收到未知文件的结束消息: \(message.fileId, privacy: .public)")
            return
        }
        
        transfer.state = message.success ? .completed : .failed
        transfer.bytesTransferred = message.bytesTransferred
        activeTransfers[message.fileId] = transfer
        
        if message.success {
            logger.info("✅ 文件传输完成: \(transfer.fileName, privacy: .public)")
        } else {
            logger.warning("❌ 文件传输失败: \(transfer.fileName, privacy: .public)")
        }
        
 // 验证完整性
        if message.success && transfer.fileSize != message.bytesTransferred {
            logger.warning("⚠️ 文件大小不匹配: 预期 \(transfer.fileSize), 实际 \(message.bytesTransferred)")
        }
        
        onFileTransferCompleted?(message.fileId, message.success)
    }
    
 // MARK: - Progress Updates
    
 /// 更新传输进度
 /// - Parameters:
 /// - fileId: 文件 ID
 /// - bytesTransferred: 已传输字节数
    public func updateProgress(fileId: String, bytesTransferred: Int64) {
        guard var transfer = activeTransfers[fileId] else { return }
        transfer.bytesTransferred = bytesTransferred
        activeTransfers[fileId] = transfer
    }
    
 // MARK: - Transfer Management
    
 /// 取消文件传输
 /// - Parameter fileId: 文件 ID
    public func cancelTransfer(fileId: String) {
        guard var transfer = activeTransfers[fileId] else { return }
        transfer.state = .cancelled
        activeTransfers[fileId] = transfer
        logger.info("⏹️ 文件传输已取消: \(transfer.fileName, privacy: .public)")
    }
    
 /// 清理已完成的传输
    public func cleanupCompletedTransfers() {
        let completedIds = activeTransfers.filter { 
            $0.value.state == .completed || $0.value.state == .failed || $0.value.state == .cancelled
        }.keys
        
        for id in completedIds {
            activeTransfers.removeValue(forKey: id)
        }
        
        logger.debug("🧹 清理了 \(completedIds.count) 个已完成的传输")
    }
    
 /// 获取指定文件的传输信息
 /// - Parameter fileId: 文件 ID
 /// - Returns: 传输信息
    public func getTransferInfo(fileId: String) -> FileTransferInfo? {
        activeTransfers[fileId]
    }
}

// MARK: - Message Parsing Extension

@available(macOS 14.0, *)
extension FileTransferSignalingService {
    
 /// 解析并处理文件传输相关消息
 /// - Parameter data: JSON 数据
 /// - Returns: 响应消息（如果需要）
    public func handleMessage(_ data: Data) throws -> (any SkyBridgeMessage)? {
        let messageType = try SkyBridgeMessageCodec.extractMessageType(from: data)
        
        switch messageType {
        case .fileMeta:
            let message = try SkyBridgeMessageCodec.decode(FileMetaMessage.self, from: data)
            return handleFileMeta(message)
            
        case .fileAckMeta:
            let message = try SkyBridgeMessageCodec.decode(FileAckMetaMessage.self, from: data)
            handleFileAckMeta(message)
            return nil
            
        case .fileEnd:
            let message = try SkyBridgeMessageCodec.decode(FileEndMessage.self, from: data)
            handleFileEnd(message)
            return nil
            
        default:
            return nil
        }
    }
}
