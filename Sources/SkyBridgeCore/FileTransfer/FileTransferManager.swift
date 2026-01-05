import Foundation
import Network
import OSLog
import Combine
import CryptoKit

/// 文件传输管理器 - 负责高速文件传输，支持分块传输和断点续传
@MainActor
public class FileTransferManager: BaseManager {
    
 // MARK: - 发布的属性
    @Published public var activeTransfers: [String: FileTransfer] = [:]
    @Published public var transferHistory: [FileTransfer] = []
    @Published public var totalProgress: Double = 0.0
    @Published public var isTransferring: Bool = false
    
 // MARK: - 私有属性
    private let networkService = FileTransferNetworkService()
    private var chunkSize: Int = 1024 * 1024 // 1MB 分块大小
    private var maxConcurrentTransfers = 3
    private var compressionEnabled: Bool = true
    private var encryptionEnabled: Bool = true
    private var receiveBaseDirectory: URL?
    private var transferQueue = DispatchQueue(label: "file.transfer.queue", qos: .userInitiated)
    
 /// 初始化文件传输管理器
    public init() {
        super.init(category: "FileTransferManager")
        logger.info("📁 初始化文件传输管理器")
    }
    
 // MARK: - 生命周期管理方法
    
 /// 启动文件传输管理器
    public override func start() async throws {
        logger.info("📁 文件传输管理器已启动")
    }
    
 /// 停止文件传输管理器
    public override func stop() async {
 // 取消所有活跃的传输
        for (transferId, _) in activeTransfers {
            cancelTransfer(transferId)
        }
        logger.info("📁 文件传输管理器已停止")
    }
    
 /// 清理资源
    public override func cleanup() {
 // 清理所有传输记录
        activeTransfers.removeAll()
        transferHistory.removeAll()
        logger.info("📁 文件传输管理器资源已清理")
    }
    
 // MARK: - 公共方法
 /// 更新传输设置（运行时可变）
    public func updateSettings(
        maxConcurrentTransfers: Int? = nil,
        chunkSize: Int? = nil,
        enableCompression: Bool? = nil,
        enableEncryption: Bool? = nil
    ) {
        if let maxConcurrentTransfers { self.maxConcurrentTransfers = max(1, maxConcurrentTransfers) }
        if let chunkSize { self.chunkSize = max(64 * 1024, chunkSize) }
        if let enableCompression { self.compressionEnabled = enableCompression }
        if let enableEncryption { self.encryptionEnabled = enableEncryption }
        logger.info("⚙️ 传输设置已更新：并发=\(self.maxConcurrentTransfers), 块=\(self.chunkSize), 压缩=\(self.compressionEnabled), 加密=\(self.encryptionEnabled)")
    }

 /// 设置接收文件的基础目录
    public func setReceiveBaseDirectory(_ url: URL?) {
        receiveBaseDirectory = url
        logger.info("📂 接收目录已更新: \(url?.path ?? "默认Downloads/SkyBridge")")
    }
    
 /// 发送文件到指定设备
    public func sendFile(at url: URL, to deviceId: String, deviceName: String, ipAddress: String, port: Int = 8080) async throws {
        logger.info("📤 开始发送文件: \(url.lastPathComponent) 到设备: \(deviceName)")
        
 // 检查文件是否存在
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FileTransferError.fileNotFound
        }
        
 // 获取文件信息
        let fileSize = try getFileSize(at: url)
        let fileName = url.lastPathComponent
        
 // 创建传输记录
        let transfer = FileTransfer(
            id: UUID().uuidString,
            fileName: fileName,
            fileSize: fileSize,
            deviceId: deviceId,
            direction: .outgoing,
            status: .preparing
        )
        
        transfer.localPath = url
        transfer.deviceIPAddress = ipAddress
        transfer.devicePort = port
        transfer.deviceName = deviceName
        activeTransfers[transfer.id] = transfer
        isTransferring = true
        
        do {
 // 建立网络连接
            let connection = try await networkService.connectToDevice(
                ipAddress: ipAddress,
                port: port,
                deviceId: deviceId,
                deviceName: deviceName
            )
            
 // 计算文件哈希（用于完整性验证）
            transfer.fileHash = try await calculateFileHash(at: url)
            
 // 发送文件元数据
            try await sendFileMetadata(transfer, to: connection)
            
 // 分块发送文件
            try await sendFileInChunks(from: url, transfer: transfer, to: connection)
            
 // 标记传输完成
            transfer.status = .completed
            transfer.completedAt = Date()
            transfer.progress = 1.0
            
            logger.info("✅ 文件发送完成: \(fileName)")
            
 // 发送传输完成通知
            NotificationCenter.default.post(
                name: Notification.Name("FileTransferCompleted"),
                object: nil,
                userInfo: [
                    "transferId": transfer.id,
                    "fileName": fileName,
                    "fileSize": fileSize,
                    "deviceName": deviceName
                ]
            )
            
        } catch {
            transfer.status = .failed
            transfer.error = error.localizedDescription
            logger.error("❌ 文件发送失败: \(fileName) - \(error)")
            
 // 发送传输失败通知
            NotificationCenter.default.post(
                name: Notification.Name("FileTransferFailed"),
                object: nil,
                userInfo: [
                    "transferId": transfer.id,
                    "fileName": fileName,
                    "error": error.localizedDescription,
                    "deviceName": deviceName
                ]
            )
            
            throw error
        }
        
 // 移动到历史记录
        moveToHistory(transfer)
        updateTransferringStatus()
    }
    
 /// 接收文件
    public func receiveFile(from connection: NWConnection, deviceId: String, deviceName: String) async throws {
        logger.info("📥 开始接收文件从设备: \(deviceName)")
        
        isTransferring = true
        
        let metadata: FileMetadata
        do {
 // 接收文件元数据
            metadata = try await receiveFileMetadata(from: connection)
        } catch {
            logger.error("❌ 接收元数据失败: \(error)")
            throw error
        }
        
        do {
 // 创建文件传输对象
            let transfer = FileTransfer(
                id: metadata.transferId,
                fileName: metadata.fileName,
                fileSize: metadata.fileSize,
                deviceId: deviceId,
                direction: .incoming,
                status: .transferring
            )
            
            transfer.fileHash = metadata.fileHash
            activeTransfers[transfer.id] = transfer
            
 // 创建接收文件路径
            let receivePath = getReceiveFilePath(for: metadata.fileName)
            
 // 开始接收文件块
            try await receiveFileInChunks(to: receivePath, transfer: transfer, from: connection)
            
 // 验证文件完整性
            let receivedHash = try await calculateFileHash(at: receivePath)
            guard receivedHash == metadata.fileHash else {
                throw FileTransferError.integrityCheckFailed
            }
            
 // 传输完成
            transfer.status = .completed
            transfer.completedAt = Date()
            transfer.localPath = receivePath
            transfer.progress = 1.0
            
 // 移动到历史记录
            moveToHistory(transfer)
            
            logger.info("✅ 文件接收完成: \(metadata.fileName)")
            
 // 发送接收完成通知
            NotificationCenter.default.post(
                name: Notification.Name("FileTransferCompleted"),
                object: nil,
                userInfo: [
                    "transferId": transfer.id,
                    "fileName": metadata.fileName,
                    "fileSize": metadata.fileSize,
                    "deviceName": deviceName
                ]
            )
            
        } catch {
            logger.error("❌ 文件接收失败: \(error)")
            
 // 发送接收失败通知
            NotificationCenter.default.post(
                name: Notification.Name("FileTransferFailed"),
                object: nil,
                userInfo: [
                    "transferId": metadata.transferId,
                    "fileName": metadata.fileName,
                    "error": error.localizedDescription,
                    "deviceName": deviceName
                ]
            )
            
            throw error
        }
        
        updateTransferringStatus()
    }
    
 // MARK: - 传输控制方法
    
 /// 暂停传输 - 利用macOS 26.x的改进持久化保存断点信息
    @MainActor
    public func pauseTransfer(_ transferId: UUID) async {
        let transferIdString = transferId.uuidString
        guard let transfer = activeTransfers[transferIdString] else {
            logger.warning("尝试暂停不存在的传输: \(transferId)")
            return
        }
        
 // 保存断点续传信息
        transfer.resumeOffset = transfer.transferredBytes
        transfer.status = .paused
        
 // 保存断点信息到磁盘（利用macOS 26.x的改进文件系统性能）
        await saveResumeData(for: transfer)
        
        logger.info("传输已暂停: \(transfer.fileName) (已传输: \(transfer.resumeOffset) 字节)")
    }
    
 /// 保存断点续传数据 - 利用macOS 26.x的改进文件系统性能
    private func saveResumeData(for transfer: FileTransfer) async {
        let resumeDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SkyBridge/ResumeData")
        
        do {
            try FileManager.default.createDirectory(at: resumeDir, withIntermediateDirectories: true)
            let resumeFile = resumeDir.appendingPathComponent("\(transfer.id).resume")
            
            let resumeData: [String: Any] = [
                "transferId": transfer.id,
                "fileName": transfer.fileName,
                "fileSize": transfer.fileSize,
                "transferredBytes": transfer.transferredBytes,
                "resumeOffset": transfer.resumeOffset,
                "deviceId": transfer.deviceId,
                "deviceIPAddress": transfer.deviceIPAddress ?? "",
                "devicePort": transfer.devicePort,
                "deviceName": transfer.deviceName ?? "",
                "direction": transfer.direction.rawValue,
                "localPath": transfer.localPath?.path ?? "",
                "fileHash": transfer.fileHash ?? "",
                "timestamp": Date().timeIntervalSince1970
            ]
            
            let data = try JSONSerialization.data(withJSONObject: resumeData, options: .prettyPrinted)
            try data.write(to: resumeFile)
            
            transfer.resumeDataPath = resumeFile
            logger.info("✅ 断点续传数据已保存: \(resumeFile.path)")
        } catch {
            logger.error("❌ 保存断点续传数据失败: \(error.localizedDescription)")
        }
    }
    
 /// 加载断点续传数据
    private func loadResumeData(for transferId: String) async -> [String: Any]? {
        let resumeDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SkyBridge/ResumeData")
        let resumeFile = resumeDir.appendingPathComponent("\(transferId).resume")
        
        guard FileManager.default.fileExists(atPath: resumeFile.path) else {
            return nil
        }
        
        do {
            let data = try Data(contentsOf: resumeFile)
            let resumeData = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            logger.info("✅ 断点续传数据已加载: \(transferId)")
            return resumeData
        } catch {
            logger.error("❌ 加载断点续传数据失败: \(error.localizedDescription)")
            return nil
        }
    }
    
 /// 恢复传输
    @MainActor
    public func resumeTransfer(_ transferId: UUID) async {
        let transferIdString = transferId.uuidString
        guard let transfer = activeTransfers[transferIdString] else {
            logger.warning("尝试恢复不存在的传输: \(transferId)")
            return
        }
        
        guard transfer.status == TransferStatus.paused else {
            logger.warning("传输状态不是暂停状态，无法恢复: \(transfer.status.rawValue)")
            return
        }
        
 // 更新传输状态
        transfer.status = .transferring
        
        logger.info("传输已恢复: \(transfer.fileName)")
        
 // 根据传输方向继续传输
        if transfer.direction == .outgoing {
            await continueSendingFile(transfer)
        } else {
            await continueReceivingFile(transfer)
        }
    }
    
 /// 继续发送文件（从暂停点恢复）- 利用macOS 26.x的改进网络性能
    private func continueSendingFile(_ transfer: FileTransfer) async {
        guard let localPath = transfer.localPath else {
            logger.error("无法恢复发送：文件路径为空")
            transfer.status = .failed
            transfer.error = "文件路径为空"
            return
        }
        
        guard let ipAddress = transfer.deviceIPAddress, !ipAddress.isEmpty else {
            logger.error("无法恢复发送：设备IP地址为空")
            transfer.status = .failed
            transfer.error = "设备IP地址为空"
            return
        }
        
        do {
            logger.info("🔄 恢复发送文件: \(transfer.fileName) (从 \(transfer.resumeOffset) 字节继续)")
            
 // 重新建立连接
            let connection = try await networkService.connectToDevice(
                ipAddress: ipAddress,
                port: transfer.devicePort,
                deviceId: transfer.deviceId,
                deviceName: transfer.deviceName ?? "Unknown Device"
            )
            
 // 发送断点续传请求（包含已传输字节数）
            try await sendResumeRequest(transferId: transfer.id, resumeOffset: transfer.resumeOffset, to: connection)
            
 // 等待服务器确认
            try await waitForResumeAcknowledgment(from: connection)
            
 // 从断点继续分块传输
            try await sendFileInChunks(
                from: localPath,
                transfer: transfer,
                to: connection,
                startOffset: transfer.resumeOffset
            )
            
 // 清理断点数据
            await cleanupResumeData(for: transfer.id)
            
            logger.info("✅ 文件发送恢复完成: \(transfer.fileName)")
        } catch {
            logger.error("恢复发送文件失败: \(error)")
            transfer.status = .failed
            transfer.error = error.localizedDescription
        }
    }
    
 /// 发送断点续传请求
    private func sendResumeRequest(transferId: String, resumeOffset: Int64, to connection: NWConnection) async throws {
        var request = Data()
        
 // 请求类型：0x04 = RESUME_REQUEST
        request.append(0x04)
        
 // transferId (36字节)
        var transferIdBytes = transferId.data(using: .utf8) ?? Data()
        transferIdBytes.resize(to: 36, padding: 0)
        request.append(transferIdBytes)
        
 // resumeOffset (8字节)
        request.append(contentsOf: withUnsafeBytes(of: resumeOffset.bigEndian) { Array($0) })
        
        try await sendData(request, to: connection)
        logger.debug("📤 发送断点续传请求: transferId=\(transferId), offset=\(resumeOffset)")
    }
    
 /// 等待断点续传确认
    private func waitForResumeAcknowledgment(from connection: NWConnection) async throws {
        let ackData = try await receiveData(length: 1, from: connection)
        guard ackData.count == 1, ackData[0] == 0x05 else { // 0x05 = RESUME_ACK
            throw FileTransferError.connectionClosed
        }
        logger.debug("✅ 断点续传确认已收到")
    }
    
 /// 清理断点续传数据
    private func cleanupResumeData(for transferId: String) async {
        guard let resumePath = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SkyBridge/ResumeData/\(transferId).resume") else {
            return
        }
        
        try? FileManager.default.removeItem(at: resumePath)
        logger.debug("🗑️ 断点续传数据已清理: \(transferId)")
    }
    
 /// 继续接收文件（从暂停点恢复）- 利用macOS 26.x的改进网络性能
    private func continueReceivingFile(_ transfer: FileTransfer) async {
        guard let localPath = transfer.localPath else {
            logger.error("无法恢复接收：文件路径为空")
            transfer.status = .failed
            transfer.error = "文件路径为空"
            return
        }
        
        guard let ipAddress = transfer.deviceIPAddress, !ipAddress.isEmpty else {
            logger.error("无法恢复接收：设备IP地址为空")
            transfer.status = .failed
            transfer.error = "设备IP地址为空"
            return
        }
        
        do {
            logger.info("🔄 恢复接收文件: \(transfer.fileName) (从 \(transfer.resumeOffset) 字节继续)")
            
 // 重新建立连接
            let connection = try await networkService.connectToDevice(
                ipAddress: ipAddress,
                port: transfer.devicePort,
                deviceId: transfer.deviceId,
                deviceName: transfer.deviceName ?? "Unknown Device"
            )
            
 // 发送断点续传请求
            try await sendResumeRequest(transferId: transfer.id, resumeOffset: transfer.resumeOffset, to: connection)
            
 // 等待服务器确认
            try await waitForResumeAcknowledgment(from: connection)
            
 // 从断点继续接收数据
            try await receiveFileInChunks(
                to: localPath,
                transfer: transfer,
                from: connection,
                startOffset: transfer.resumeOffset
            )
            
 // 清理断点数据
            await cleanupResumeData(for: transfer.id)
            
            logger.info("✅ 文件接收恢复完成: \(transfer.fileName)")
        } catch {
            logger.error("恢复接收文件失败: \(error)")
            transfer.status = .failed
            transfer.error = error.localizedDescription
        }
    }
    
 /// 取消传输
    public func cancelTransfer(_ transferId: String) {
        if let transfer = activeTransfers[transferId] {
            transfer.status = .cancelled
            moveToHistory(transfer)
            updateTransferringStatus()
            logger.info("❌ 取消传输: \(transferId)")
        }
    }
    
 /// 清理历史记录
    public func clearHistory() {
        transferHistory.removeAll()
        logger.info("🗑️ 清理传输历史记录")
    }
    
 // MARK: - 私有方法
    
 /// 获取文件大小
    private func getFileSize(at url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return attributes[.size] as? Int64 ?? 0
    }
    
 /// 计算文件哈希（流式处理，避免大文件内存溢出）
 ///
 /// ⚠️ 重要：遵循项目规则 - 禁止 Data(contentsOf:) 读取整文件
 /// ✅ 使用 FileHandle 分块读取，支持任意大小文件
    private func calculateFileHash(at url: URL) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
 // 使用流式哈希计算，避免大文件内存峰值
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    
                    var hasher = SHA256()
                    let chunkSize = 1_048_576 // 1MB 分块
                    
                    while true {
                        let chunk = try autoreleasepool {
                            try handle.read(upToCount: chunkSize)
                        }
                        guard let chunk, !chunk.isEmpty else { break }
                        hasher.update(data: chunk)
                    }
                    
                    let digest = hasher.finalize()
                    let hashString = digest.map { String(format: "%02x", $0) }.joined()
                    continuation.resume(returning: hashString)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
 /// 发送文件元数据
    private func sendFileMetadata(_ transfer: FileTransfer, to connection: NWConnection) async throws {
        let metadata = FileMetadata(
            transferId: transfer.id,
            fileName: transfer.fileName,
            fileSize: transfer.fileSize,
            fileHash: transfer.fileHash ?? "",
            chunkSize: chunkSize
        )
        
        let data = try JSONEncoder().encode(metadata)
        let header = createHeader(type: .metadata, length: data.count)
        
        try await sendData(header + data, to: connection)
        logger.info("📋 发送文件元数据: \(transfer.fileName)")
    }
    
 /// 接收文件元数据
    private func receiveFileMetadata(from connection: NWConnection) async throws -> FileMetadata {
 // 接收头部
        let headerData = try await receiveData(length: 8, from: connection)
        let header = parseHeader(headerData)
        
        guard header.type == .metadata else {
            throw FileTransferError.invalidHeader
        }
        
 // 接收元数据
        let metadataData = try await receiveData(length: header.length, from: connection)
        let metadata = try JSONDecoder().decode(FileMetadata.self, from: metadataData)
        
        logger.info("📋 接收文件元数据: \(metadata.fileName)")
        return metadata
    }
    
 /// 分块发送文件 - 支持断点续传
    private func sendFileInChunks(
        from url: URL,
        transfer: FileTransfer,
        to connection: NWConnection,
        startOffset: Int64 = 0
    ) async throws {
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { fileHandle.closeFile() }
        
        var sentBytes: Int64 = startOffset
        let totalBytes = transfer.fileSize
        var chunkIndex = Int(startOffset / Int64(chunkSize)) // 计算起始块索引
        
 // 移动到断点位置
        if startOffset > 0 {
            fileHandle.seek(toFileOffset: UInt64(startOffset))
            logger.info("📍 从断点继续: 偏移量=\(startOffset), 块索引=\(chunkIndex)")
        }
        
        transfer.status = .transferring
        
        while sentBytes < totalBytes {
 // 检查是否暂停或取消
            if transfer.status == .paused {
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
                continue
            }
            
            if transfer.status == .cancelled {
                throw FileTransferError.transferCancelled
            }
            
 // 读取文件块
            let remainingBytes = totalBytes - sentBytes
            let currentChunkSize = min(Int64(chunkSize), remainingBytes)
            
            fileHandle.seek(toFileOffset: UInt64(sentBytes))
            let chunkData = fileHandle.readData(ofLength: Int(currentChunkSize))
            
 // 创建文件块
            let chunk = FileChunk(
                index: chunkIndex,
                data: chunkData,
                size: chunkData.count
            )
            
 // 发送文件块
            try await sendFileChunk(chunk, to: connection)
            
            sentBytes += Int64(chunkData.count)
            chunkIndex += 1
            
 // 使用新的统计功能更新进度
            transfer.updateProgress(transferredBytes: sentBytes)
            
            logger.debug("📤 发送块 \(chunkIndex): \(chunkData.count) 字节")
        }
        
 // 发送传输完成信号
        try await sendTransferComplete(to: connection)
    }
    
 /// 分块接收文件 - 支持断点续传
    private func receiveFileInChunks(
        to url: URL,
        transfer: FileTransfer,
        from connection: NWConnection,
        startOffset: Int64 = 0
    ) async throws {
 // 创建或打开文件（如果存在则追加）
        if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        
        let fileHandle = try FileHandle(forWritingTo: url)
        defer { fileHandle.closeFile() }
        
 // 移动到断点位置（如果存在）
        if startOffset > 0 {
            fileHandle.seek(toFileOffset: UInt64(startOffset))
            logger.info("📍 从断点继续接收: 偏移量=\(startOffset)")
        }
        
        var receivedBytes: Int64 = startOffset
        let totalBytes = transfer.fileSize
        
        transfer.status = .transferring
        
        while receivedBytes < totalBytes {
 // 检查是否取消
            if transfer.status == .cancelled {
                throw FileTransferError.transferCancelled
            }
            
 // 接收文件块
            let chunk = try await receiveFileChunk(from: connection)
            
 // 写入文件
            fileHandle.seek(toFileOffset: UInt64(receivedBytes))
            fileHandle.write(chunk.data)
            
            receivedBytes += Int64(chunk.size)
            
 // 使用新的统计功能更新进度
            transfer.updateProgress(transferredBytes: receivedBytes)
            
            logger.debug("📥 接收块 \(chunk.index): \(chunk.size) 字节")
        }
        
 // 等待传输完成信号
        try await receiveTransferComplete(from: connection)
    }
    
 /// 发送文件块
    private func sendFileChunk(_ chunk: FileChunk, to connection: NWConnection) async throws {
        let chunkData = try JSONEncoder().encode(chunk)
        let header = createHeader(type: .chunk, length: chunkData.count)
        
        try await sendData(header + chunkData, to: connection)
    }
    
 /// 接收文件块
    private func receiveFileChunk(from connection: NWConnection) async throws -> FileChunk {
 // 接收头部
        let headerData = try await receiveData(length: 8, from: connection)
        let header = parseHeader(headerData)
        
        guard header.type == .chunk else {
            throw FileTransferError.invalidHeader
        }
        
 // 接收块数据
        let chunkData = try await receiveData(length: header.length, from: connection)
        return try JSONDecoder().decode(FileChunk.self, from: chunkData)
    }
    
 /// 发送传输完成信号
    private func sendTransferComplete(to connection: NWConnection) async throws {
        let header = createHeader(type: .complete, length: 0)
        try await sendData(header, to: connection)
    }
    
 /// 接收传输完成信号
    private func receiveTransferComplete(from connection: NWConnection) async throws {
        let headerData = try await receiveData(length: 8, from: connection)
        let header = parseHeader(headerData)
        
        guard header.type == .complete else {
            throw FileTransferError.invalidHeader
        }
    }
    
 /// 发送数据
    private func sendData(_ data: Data, to connection: NWConnection) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
    
 /// 接收数据
    private func receiveData(length: Int, from connection: NWConnection) async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { data, _, isComplete, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: FileTransferError.connectionClosed)
                }
            }
        }
    }
    
 /// 创建协议头部
    private func createHeader(type: MessageType, length: Int) -> Data {
        var header = Data()
        header.append(contentsOf: withUnsafeBytes(of: type.rawValue.bigEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt32(length).bigEndian) { Array($0) })
        return header
    }
    
 /// 解析协议头部
    private func parseHeader(_ data: Data) -> (type: MessageType, length: Int) {
        let typeValue = data.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        let length = data.suffix(4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        
        let type = MessageType(rawValue: typeValue) ?? .unknown
        return (type: type, length: Int(length))
    }
    
 /// 获取接收文件路径
    private func getReceiveFilePath(for fileName: String) -> URL {
        let baseDir = receiveBaseDirectory ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!.appendingPathComponent("SkyBridge")
        let skyBridgeFolder = baseDir
        
 // 创建文件夹
        try? FileManager.default.createDirectory(at: skyBridgeFolder, withIntermediateDirectories: true)
        
        return skyBridgeFolder.appendingPathComponent(fileName)
    }
    
 /// 移动到历史记录
    private func moveToHistory(_ transfer: FileTransfer) {
        activeTransfers.removeValue(forKey: transfer.id)
        transferHistory.append(transfer)
        
 // 限制历史记录数量
        if transferHistory.count > 100 {
            transferHistory.removeFirst()
        }
    }
    
 /// 更新传输状态
    private func updateTransferringStatus() {
        isTransferring = !activeTransfers.isEmpty
        
 // 计算总体进度
        if activeTransfers.isEmpty {
            totalProgress = 0.0
        } else {
            let totalProgress = activeTransfers.values.reduce(0.0) { $0 + $1.progress }
            self.totalProgress = totalProgress / Double(activeTransfers.count)
        }
    }
}

// MARK: - 数据模型

/// 文件传输对象
public class FileTransfer: ObservableObject, Identifiable {
    public let id: String
    public let fileName: String
    public let fileSize: Int64
    public let deviceId: String
    public let direction: TransferDirection
    public let createdAt: Date
    
    @Published public var status: TransferStatus = .preparing
    @Published public var progress: Double = 0.0
    @Published public var transferredBytes: Int64 = 0
    
 // 新增传输统计属性
    @Published public var transferSpeed: Double = 0.0 // 字节/秒
    @Published public var estimatedTimeRemaining: TimeInterval = 0.0 // 剩余时间（秒）
    @Published public var networkQuality: NetworkQuality = .unknown // 网络质量
    @Published public var averageSpeed: Double = 0.0 // 平均传输速度
    @Published public var peakSpeed: Double = 0.0 // 峰值传输速度
    
    public var completedAt: Date?
    public var error: String?
    public var fileHash: String?
    public var localPath: URL?
    
 // 扫描结果 - 用于 UI 显示扫描状态
    @Published public var scanResult: FileScanResult?
    
 // 断点续传支持 - 利用macOS 26.x的改进持久化
    public var deviceIPAddress: String? // 设备IP地址
    public var devicePort: Int = 8080 // 设备端口
    public var deviceName: String? // 设备名称
    public var resumeOffset: Int64 = 0 // 断点续传偏移量（已传输字节数）
    public var resumeDataPath: URL? // 断点续传数据保存路径
    
 // 内部统计数据
    private var lastUpdateTime: Date = Date()
    private var lastTransferredBytes: Int64 = 0
    private var speedSamples: [Double] = []
    private let maxSpeedSamples = 10 // 保留最近10个速度样本用于平均值计算
    
    public init(id: String, fileName: String, fileSize: Int64, deviceId: String, direction: TransferDirection, status: TransferStatus) {
        self.id = id
        self.fileName = fileName
        self.fileSize = fileSize
        self.deviceId = deviceId
        self.direction = direction
        self.status = status
        self.createdAt = Date()
        self.lastUpdateTime = Date()
    }
    
 /// 更新传输进度和统计信息
    public func updateProgress(transferredBytes: Int64) {
        let now = Date()
        let timeDelta = now.timeIntervalSince(lastUpdateTime)
        
 // 避免过于频繁的更新
        guard timeDelta >= 0.1 else { return }
        
        let bytesDelta = transferredBytes - lastTransferredBytes
        
 // 计算当前传输速度
        if timeDelta > 0 {
            let currentSpeed = Double(bytesDelta) / timeDelta
            self.transferSpeed = currentSpeed
            
 // 更新峰值速度
            if currentSpeed > peakSpeed {
                peakSpeed = currentSpeed
            }
            
 // 添加到速度样本中
            speedSamples.append(currentSpeed)
            if speedSamples.count > maxSpeedSamples {
                speedSamples.removeFirst()
            }
            
 // 计算平均速度
            if !speedSamples.isEmpty {
                averageSpeed = speedSamples.reduce(0, +) / Double(speedSamples.count)
            }
        }
        
 // 更新基本信息
        self.transferredBytes = transferredBytes
        self.progress = Double(transferredBytes) / Double(fileSize)
        
 // 计算剩余时间
        if averageSpeed > 0 {
            let remainingBytes = fileSize - transferredBytes
            estimatedTimeRemaining = Double(remainingBytes) / averageSpeed
        }
        
 // 评估网络质量
        updateNetworkQuality()
        
 // 更新时间戳
        lastUpdateTime = now
        lastTransferredBytes = transferredBytes
    }
    
 /// 评估网络质量
    private func updateNetworkQuality() {
        guard !speedSamples.isEmpty else {
            networkQuality = .unknown
            return
        }
        
        let avgSpeed = averageSpeed
        let speedVariance = calculateSpeedVariance()
        
 // 基于平均速度和稳定性评估网络质量
        if avgSpeed > 10_000_000 && speedVariance < 0.3 { // > 10MB/s 且稳定
            networkQuality = .excellent
        } else if avgSpeed > 5_000_000 && speedVariance < 0.5 { // > 5MB/s 且较稳定
            networkQuality = .good
        } else if avgSpeed > 1_000_000 && speedVariance < 0.7 { // > 1MB/s
            networkQuality = .fair
        } else if avgSpeed > 100_000 { // > 100KB/s
            networkQuality = .poor
        } else {
            networkQuality = .veryPoor
        }
    }
    
 /// 计算速度方差（用于评估网络稳定性）
    private func calculateSpeedVariance() -> Double {
        guard speedSamples.count > 1 else { return 0.0 }
        
        let mean = averageSpeed
        let variance = speedSamples.reduce(0) { sum, speed in
            let diff = speed - mean
            return sum + (diff * diff)
        } / Double(speedSamples.count)
        
        return sqrt(variance) / mean // 变异系数
    }
    
 /// 重置统计信息
    public func resetStatistics() {
        transferSpeed = 0.0
        estimatedTimeRemaining = 0.0
        networkQuality = .unknown
        averageSpeed = 0.0
        peakSpeed = 0.0
        speedSamples.removeAll()
        lastUpdateTime = Date()
        lastTransferredBytes = 0
    }
    
 /// 格式化传输速度显示
    public var formattedSpeed: String {
        return formatSpeed(transferSpeed)
    }
    
 /// 格式化平均速度显示
    public var formattedAverageSpeed: String {
        return formatSpeed(averageSpeed)
    }
    
 /// 格式化峰值速度显示
    public var formattedPeakSpeed: String {
        return formatSpeed(peakSpeed)
    }
    
 /// 格式化剩余时间显示
    public var formattedTimeRemaining: String {
        return formatTimeInterval(estimatedTimeRemaining)
    }
    
 /// 格式化速度
    private func formatSpeed(_ speed: Double) -> String {
        if speed >= 1_000_000_000 { // GB/s
            return String(format: "%.1f GB/s", speed / 1_000_000_000)
        } else if speed >= 1_000_000 { // MB/s
            return String(format: "%.1f MB/s", speed / 1_000_000)
        } else if speed >= 1_000 { // KB/s
            return String(format: "%.1f KB/s", speed / 1_000)
        } else { // B/s
            return String(format: "%.0f B/s", speed)
        }
    }
    
 /// 格式化时间间隔
    private func formatTimeInterval(_ interval: TimeInterval) -> String {
        guard interval > 0 && interval.isFinite else { return "计算中..." }
        
        let hours = Int(interval) / 3600
        let minutes = Int(interval) % 3600 / 60
        let seconds = Int(interval) % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else if minutes > 0 {
            return String(format: "%d:%02d", minutes, seconds)
        } else {
            return String(format: "%d秒", seconds)
        }
    }
}

/// 网络质量枚举
public enum NetworkQuality: String, CaseIterable {
    case excellent = "优秀"
    case good = "良好"
    case fair = "一般"
    case poor = "较差"
    case veryPoor = "很差"
    case unknown = "未知"
    
 /// 获取对应的颜色
    public var color: String {
        switch self {
        case .excellent:
            return "green"
        case .good:
            return "blue"
        case .fair:
            return "orange"
        case .poor:
            return "red"
        case .veryPoor:
            return "red"
        case .unknown:
            return "gray"
        }
    }
    
 /// 获取对应的图标
    public var icon: String {
        switch self {
        case .excellent:
            return "wifi"
        case .good:
            return "wifi"
        case .fair:
            return "wifi"
        case .poor:
            return "wifi.slash"
        case .veryPoor:
            return "wifi.slash"
        case .unknown:
            return "questionmark.circle"
        }
    }
}

/// 文件元数据
private struct FileMetadata: Codable {
    let transferId: String
    let fileName: String
    let fileSize: Int64
    let fileHash: String
    let chunkSize: Int
}

/// 文件块
private struct FileChunk: Codable {
    let index: Int
    let data: Data
    let size: Int
}

/// 传输方向
public enum TransferDirection: String, CaseIterable {
    case incoming = "接收"
    case outgoing = "发送"
}

/// 传输状态
public enum TransferStatus: String, CaseIterable {
    case preparing = "准备中"
    case transferring = "传输中"
    case paused = "已暂停"
    case completed = "已完成"
    case failed = "失败"
    case cancelled = "已取消"
}

/// 消息类型
private enum MessageType: UInt32 {
    case metadata = 1
    case chunk = 2
    case complete = 3
    case unknown = 0
}

/// 文件传输错误
public enum FileTransferError: Error, LocalizedError {
    case invalidHeader
    case integrityCheckFailed
    case transferCancelled
    case connectionClosed
    case fileNotFound
    
    public var errorDescription: String? {
        switch self {
        case .invalidHeader:
            return "无效的协议头部"
        case .integrityCheckFailed:
            return "文件完整性检查失败"
        case .transferCancelled:
            return "传输已取消"
        case .connectionClosed:
            return "连接已关闭"
        case .fileNotFound:
            return "文件未找到"
        }
    }
}

// MARK: - Data扩展（支持resize操作）
// 注意：resize方法已在FileTransferEngine.swift中定义，避免重复声明
