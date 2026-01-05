// FileTransferSignalingTests.swift
// SkyBridgeCoreTests
//
// 文件传输信令测试
// Created for web-agent-integration spec 12

import Testing
import Foundation
@testable import SkyBridgeCore

// MARK: - File Transfer Message Tests

/// **Feature: web-agent-integration, 12.1: 文件传输消息类型**
/// **Validates: Requirements 8.1, 8.2, 8.3, 8.4**
@Suite("File Transfer Message Tests")
struct FileTransferMessageTests {
    
    @Test("FileMetaMessage 序列化/反序列化")
    func testFileMetaMessageRoundTrip() throws {
        let original = FileMetaMessage(
            fileId: UUID().uuidString,
            fileName: "test-file.txt",
            fileSize: 1024,
            mimeType: "text/plain",
            checksum: "abc123"
        )
        
 // 编码
        let data = try SkyBridgeMessageCodec.encode(original)
        
 // 解码
        let decoded = try SkyBridgeMessageCodec.decode(FileMetaMessage.self, from: data)
        
 // 验证
        #expect(decoded.type == "file-meta")
        #expect(decoded.fileId == original.fileId)
        #expect(decoded.fileName == original.fileName)
        #expect(decoded.fileSize == original.fileSize)
        #expect(decoded.mimeType == original.mimeType)
        #expect(decoded.checksum == original.checksum)
    }
    
    @Test("FileAckMetaMessage 序列化/反序列化")
    func testFileAckMetaMessageRoundTrip() throws {
        let original = FileAckMetaMessage(
            fileId: UUID().uuidString,
            accepted: true,
            reason: nil
        )
        
        let data = try SkyBridgeMessageCodec.encode(original)
        let decoded = try SkyBridgeMessageCodec.decode(FileAckMetaMessage.self, from: data)
        
        #expect(decoded.type == "file-ack-meta")
        #expect(decoded.fileId == original.fileId)
        #expect(decoded.accepted == original.accepted)
        #expect(decoded.reason == original.reason)
    }
    
    @Test("FileAckMetaMessage 拒绝场景")
    func testFileAckMetaMessageRejected() throws {
        let original = FileAckMetaMessage(
            fileId: UUID().uuidString,
            accepted: false,
            reason: "文件太大"
        )
        
        let data = try SkyBridgeMessageCodec.encode(original)
        let decoded = try SkyBridgeMessageCodec.decode(FileAckMetaMessage.self, from: data)
        
        #expect(decoded.accepted == false)
        #expect(decoded.reason == "文件太大")
    }
    
    @Test("FileEndMessage 序列化/反序列化")
    func testFileEndMessageRoundTrip() throws {
        let original = FileEndMessage(
            fileId: UUID().uuidString,
            success: true,
            bytesTransferred: 1024
        )
        
        let data = try SkyBridgeMessageCodec.encode(original)
        let decoded = try SkyBridgeMessageCodec.decode(FileEndMessage.self, from: data)
        
        #expect(decoded.type == "file-end")
        #expect(decoded.fileId == original.fileId)
        #expect(decoded.success == original.success)
        #expect(decoded.bytesTransferred == original.bytesTransferred)
    }
    
    @Test("FileEndMessage 失败场景")
    func testFileEndMessageFailed() throws {
        let original = FileEndMessage(
            fileId: UUID().uuidString,
            success: false,
            bytesTransferred: 512
        )
        
        let data = try SkyBridgeMessageCodec.encode(original)
        let decoded = try SkyBridgeMessageCodec.decode(FileEndMessage.self, from: data)
        
        #expect(decoded.success == false)
        #expect(decoded.bytesTransferred == 512)
    }
    
    @Test("消息类型提取")
    func testMessageTypeExtraction() throws {
        let fileMeta = FileMetaMessage(
            fileId: "test",
            fileName: "test.txt",
            fileSize: 100
        )
        let data = try SkyBridgeMessageCodec.encode(fileMeta)
        let messageType = try SkyBridgeMessageCodec.extractMessageType(from: data)
        
        #expect(messageType == .fileMeta)
    }
}

// MARK: - File Transfer Signaling Service Tests

/// **Feature: web-agent-integration, 12.2: 文件传输信令处理**
/// **Validates: Requirements 8.1, 8.2, 8.3**
@Suite("File Transfer Signaling Service Tests")
struct FileTransferSignalingServiceTests {
    
    @Test("发送文件元数据")
    @MainActor
    func testSendFileMeta() async {
        guard #available(macOS 14.0, *) else { return }
        
        let service = FileTransferSignalingService()
        
        let (message, transferInfo) = service.sendFileMeta(
            fileName: "test-file.txt",
            fileSize: 1024,
            mimeType: "text/plain",
            checksum: "abc123"
        )
        
 // 验证消息
        #expect(message.type == "file-meta")
        #expect(message.fileName == "test-file.txt")
        #expect(message.fileSize == 1024)
        #expect(message.mimeType == "text/plain")
        #expect(message.checksum == "abc123")
        
 // 验证传输信息
        #expect(transferInfo.direction == .sending)
        #expect(transferInfo.state == .awaitingAck)
        #expect(transferInfo.progress == 0)
        
 // 验证活跃传输
        #expect(service.activeTransfers.count == 1)
        #expect(service.activeTransfers[message.fileId] != nil)
    }
    
    @Test("处理文件元数据 - 接受")
    @MainActor
    func testHandleFileMetaAccepted() async {
        guard #available(macOS 14.0, *) else { return }
        
        let service = FileTransferSignalingService()
        service.onFileMetaReceived = { _ in true }
        
        let incomingMeta = FileMetaMessage(
            fileId: UUID().uuidString,
            fileName: "incoming.txt",
            fileSize: 2048
        )
        
        let ackMessage = service.handleFileMeta(incomingMeta)
        
 // 验证确认消息
        #expect(ackMessage.type == "file-ack-meta")
        #expect(ackMessage.fileId == incomingMeta.fileId)
        #expect(ackMessage.accepted == true)
        #expect(ackMessage.reason == nil)
        
 // 验证传输已添加
        let transfer = service.activeTransfers[incomingMeta.fileId]
        #expect(transfer != nil)
        #expect(transfer?.direction == .receiving)
        #expect(transfer?.state == .transferring)
    }
    
    @Test("处理文件元数据 - 拒绝")
    @MainActor
    func testHandleFileMetaRejected() async {
        guard #available(macOS 14.0, *) else { return }
        
        let service = FileTransferSignalingService()
        service.onFileMetaReceived = { _ in false }
        
        let incomingMeta = FileMetaMessage(
            fileId: UUID().uuidString,
            fileName: "rejected.txt",
            fileSize: 2048
        )
        
        let ackMessage = service.handleFileMeta(incomingMeta)
        
        #expect(ackMessage.accepted == false)
        #expect(ackMessage.reason != nil)
        
 // 传输不应被添加
        #expect(service.activeTransfers[incomingMeta.fileId] == nil)
    }
    
    @Test("处理文件确认消息 - 接受")
    @MainActor
    func testHandleFileAckMetaAccepted() async {
        guard #available(macOS 14.0, *) else { return }
        
        let service = FileTransferSignalingService()
        
 // 先发送文件元数据
        let (message, _) = service.sendFileMeta(
            fileName: "test.txt",
            fileSize: 1024
        )
        
 // 处理确认
        let ackMessage = FileAckMetaMessage(
            fileId: message.fileId,
            accepted: true
        )
        service.handleFileAckMeta(ackMessage)
        
 // 验证状态更新
        let transfer = service.activeTransfers[message.fileId]
        #expect(transfer?.state == .transferring)
    }
    
    @Test("处理文件确认消息 - 拒绝")
    @MainActor
    func testHandleFileAckMetaRejected() async {
        guard #available(macOS 14.0, *) else { return }
        
        let service = FileTransferSignalingService()
        
        let (message, _) = service.sendFileMeta(
            fileName: "test.txt",
            fileSize: 1024
        )
        
        let ackMessage = FileAckMetaMessage(
            fileId: message.fileId,
            accepted: false,
            reason: "存储空间不足"
        )
        service.handleFileAckMeta(ackMessage)
        
        let transfer = service.activeTransfers[message.fileId]
        #expect(transfer?.state == .failed)
    }
    
    @Test("处理文件结束消息 - 成功")
    @MainActor
    func testHandleFileEndSuccess() async {
        guard #available(macOS 14.0, *) else { return }
        
        let service = FileTransferSignalingService()
        service.onFileMetaReceived = { _ in true }
        
        var completedFileId: String?
        var completedSuccess: Bool?
        service.onFileTransferCompleted = { fileId, success in
            completedFileId = fileId
            completedSuccess = success
        }
        
 // 接收文件
        let incomingMeta = FileMetaMessage(
            fileId: UUID().uuidString,
            fileName: "test.txt",
            fileSize: 1024
        )
        _ = service.handleFileMeta(incomingMeta)
        
 // 处理结束消息
        let endMessage = FileEndMessage(
            fileId: incomingMeta.fileId,
            success: true,
            bytesTransferred: 1024
        )
        service.handleFileEnd(endMessage)
        
 // 验证状态
        let transfer = service.activeTransfers[incomingMeta.fileId]
        #expect(transfer?.state == .completed)
        #expect(transfer?.bytesTransferred == 1024)
        
 // 验证回调
        #expect(completedFileId == incomingMeta.fileId)
        #expect(completedSuccess == true)
    }
    
    @Test("处理文件结束消息 - 失败")
    @MainActor
    func testHandleFileEndFailed() async {
        guard #available(macOS 14.0, *) else { return }
        
        let service = FileTransferSignalingService()
        service.onFileMetaReceived = { _ in true }
        
        let incomingMeta = FileMetaMessage(
            fileId: UUID().uuidString,
            fileName: "test.txt",
            fileSize: 1024
        )
        _ = service.handleFileMeta(incomingMeta)
        
        let endMessage = FileEndMessage(
            fileId: incomingMeta.fileId,
            success: false,
            bytesTransferred: 512
        )
        service.handleFileEnd(endMessage)
        
        let transfer = service.activeTransfers[incomingMeta.fileId]
        #expect(transfer?.state == .failed)
    }
    
    @Test("更新传输进度")
    @MainActor
    func testUpdateProgress() async {
        guard #available(macOS 14.0, *) else { return }
        
        let service = FileTransferSignalingService()
        
        let (message, _) = service.sendFileMeta(
            fileName: "test.txt",
            fileSize: 1000
        )
        
 // 更新进度
        service.updateProgress(fileId: message.fileId, bytesTransferred: 500)
        
        let transfer = service.activeTransfers[message.fileId]
        #expect(transfer?.bytesTransferred == 500)
        #expect(transfer?.progress == 0.5)
    }
    
    @Test("取消传输")
    @MainActor
    func testCancelTransfer() async {
        guard #available(macOS 14.0, *) else { return }
        
        let service = FileTransferSignalingService()
        
        let (message, _) = service.sendFileMeta(
            fileName: "test.txt",
            fileSize: 1024
        )
        
        service.cancelTransfer(fileId: message.fileId)
        
        let transfer = service.activeTransfers[message.fileId]
        #expect(transfer?.state == .cancelled)
    }
    
    @Test("清理已完成的传输")
    @MainActor
    func testCleanupCompletedTransfers() async {
        guard #available(macOS 14.0, *) else { return }
        
        let service = FileTransferSignalingService()
        service.onFileMetaReceived = { _ in true }
        
 // 创建多个传输
        let (msg1, _) = service.sendFileMeta(fileName: "file1.txt", fileSize: 100)
        let (msg2, _) = service.sendFileMeta(fileName: "file2.txt", fileSize: 200)
        let meta3 = FileMetaMessage(fileId: UUID().uuidString, fileName: "file3.txt", fileSize: 300)
        _ = service.handleFileMeta(meta3)
        
 // 完成一些传输
        service.handleFileEnd(FileEndMessage(fileId: msg1.fileId, success: true, bytesTransferred: 100))
        service.cancelTransfer(fileId: msg2.fileId)
        
        #expect(service.activeTransfers.count == 3)
        
 // 清理
        service.cleanupCompletedTransfers()
        
 // 只剩下进行中的传输
        #expect(service.activeTransfers.count == 1)
        #expect(service.activeTransfers[meta3.fileId] != nil)
    }
}

// MARK: - Property Tests

@Suite("File Transfer Message Property Tests")
struct FileTransferMessagePropertyTests {
    
    @Test("FileMetaMessage Round-Trip", arguments: (0..<10).map { _ in UUID().uuidString })
    func testFileMetaRoundTrip(fileId: String) throws {
        let fileName = "test-\(Int.random(in: 1...1000)).txt"
        let fileSize = Int64.random(in: 1...1_000_000_000)
        
        let original = FileMetaMessage(
            fileId: fileId,
            fileName: fileName,
            fileSize: fileSize,
            mimeType: "application/octet-stream",
            checksum: UUID().uuidString
        )
        
        let data = try SkyBridgeMessageCodec.encode(original)
        let decoded = try SkyBridgeMessageCodec.decode(FileMetaMessage.self, from: data)
        
        #expect(decoded == original)
    }
    
    @Test("FileEndMessage Round-Trip", arguments: [true, false])
    func testFileEndRoundTrip(success: Bool) throws {
        let original = FileEndMessage(
            fileId: UUID().uuidString,
            success: success,
            bytesTransferred: Int64.random(in: 0...1_000_000)
        )
        
        let data = try SkyBridgeMessageCodec.encode(original)
        let decoded = try SkyBridgeMessageCodec.decode(FileEndMessage.self, from: data)
        
        #expect(decoded == original)
    }
}
