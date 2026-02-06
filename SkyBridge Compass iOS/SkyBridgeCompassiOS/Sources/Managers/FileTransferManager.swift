//
// FileTransferManager.swift
// SkyBridgeCompassiOS
//
// 文件传输管理器 - 支持高速分块传输、断点续传、加密传输
// 与 macOS SkyBridge 完全兼容的传输协议
//

import Foundation
import Network
import CryptoKit
import ActivityKit
#if canImport(UIKit)
import UIKit
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif

// MARK: - File Transfer Constants

/// 文件传输常量
public enum FileTransferConstants {
    /// 默认分块大小 (1MB)
    public static let defaultChunkSize: Int = 1024 * 1024
    
    /// 最大并发传输数
    public static let maxConcurrentTransfers: Int = 3
    
    /// 传输超时时间（秒）
    public static let transferTimeout: TimeInterval = 300
    
    /// 默认传输端口
    public static let defaultPort: UInt16 = 8080
}

// MARK: - Local Device Info (best-effort, for sender metadata)
private func SBFT_currentModelIdentifier() -> String {
    var systemInfo = utsname()
    uname(&systemInfo)
    return withUnsafePointer(to: &systemInfo.machine) {
        $0.withMemoryRebound(to: CChar.self, capacity: 1) { ptr in
            String(cString: ptr)
        }
    }
}

private func SBFT_currentModelDisplayName() -> String {
    switch SBFT_currentModelIdentifier() {
    case "iPhone17,1": return "iPhone 16 Pro"
    case "iPhone17,2": return "iPhone 16 Pro Max"
    case "iPhone17,3": return "iPhone 16"
    case "iPhone17,4": return "iPhone 16 Plus"
    default: return SBFT_currentModelIdentifier()
    }
}

private func SBFT_currentChipDisplayName() -> String {
    switch SBFT_currentModelIdentifier() {
    case "iPhone17,1", "iPhone17,2": return "A18 Pro"
    case "iPhone17,3", "iPhone17,4": return "A18"
    default: return "Apple Silicon"
    }
}

// MARK: - File Chunk

/// 文件块
public struct FileChunk: Codable, Sendable {
    public let index: Int
    public let data: Data
    public let size: Int
    public let checksum: String?
    
    public init(index: Int, data: Data, size: Int, checksum: String? = nil) {
        self.index = index
        self.data = data
        self.size = size
        self.checksum = checksum
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
        let typeValue = data.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        let lengthValue = data.suffix(4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        let type = TransferMessageType(rawValue: typeValue) ?? .unknown
        return TransferHeader(type: type, length: Int(lengthValue))
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
    case timeout
    case encryptionFailed
    
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
        case .timeout: return "传输超时"
        case .encryptionFailed: return "加密失败"
        }
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

// MARK: - FileTransferManager

/// 文件传输管理器 - 支持高速分块传输、断点续传、加密传输
@available(iOS 17.0, *)
@MainActor
public class FileTransferManager: ObservableObject {
    public static let instance = FileTransferManager()
    
    // MARK: - Published Properties
    
    /// 活跃的传输
    @Published public private(set) var activeTransfers: [FileTransfer] = []
    
    /// 传输历史
    @Published public private(set) var transferHistory: [FileTransfer] = []
    
    /// 总进度
    @Published public private(set) var totalProgress: Double = 0.0
    
    /// 是否正在传输
    @Published public private(set) var isTransferring: Bool = false
    
    // MARK: - Private Properties
    
    private let fileManager = FileManager.default
    private let documentsDirectory: URL
    private let downloadsDirectory: URL
    private var transferStates: [String: TransferState] = [:]
    private var chunkSize: Int = FileTransferConstants.defaultChunkSize
    private let maxChunkSizeBytes: Int = 512 * 1024
    private let maxMessageBytes: Int = 2_000_000
    private let queue = DispatchQueue(label: "com.skybridge.filetransfer", qos: .userInitiated)

    private var inFlightTransferCount: Int = 0
    private var transferWaiters: [CheckedContinuation<Void, Never>] = []
    
    /// P2P 连接管理器
    private var connectionManager: P2PConnectionManager { P2PConnectionManager.instance }
    
    /// Cross-network (WebRTC) manager
    private var crossNetwork: CrossNetworkWebRTCManager { CrossNetworkWebRTCManager.instance }
    
    /// 加密是否启用
    public var encryptionEnabled: Bool = true
    
    /// 压缩是否启用
    /// ⚠️ 兼容性：旧版 macOS 端不会对入站 chunk 解压，默认关闭可避免跨版本互通失败。
    /// 若你同时使用本仓库更新后的 macOS 端（支持 compression=zlib），可以在设置里开启。
    public var compressionEnabled: Bool = false
    
    private init() {
        documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        downloadsDirectory = documentsDirectory.appendingPathComponent("Downloads", isDirectory: true)
        
        // 创建下载目录
        try? fileManager.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        
        loadHistory()
    }
    
    // MARK: - Public Methods
    
    /// 发送文件到设备
    /// - Parameters:
    ///   - url: 文件 URL
    ///   - device: 目标设备
    public func sendFile(at url: URL, to device: DiscoveredDevice) async throws {
        await acquireTransferSlot()
        defer { releaseTransferSlot() }

        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }

        guard fileManager.fileExists(atPath: url.path) else {
            throw FileTransferError.fileNotFound
        }
        
        SkyBridgeLogger.shared.info("📤 开始发送文件: \(url.lastPathComponent) 到设备: \(device.name)")
        
        // 获取文件信息
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let fileSize = attributes[.size] as? Int64 ?? 0
        let fileName = url.lastPathComponent
        let fileType = determineFileType(from: url)
        
        // 计算文件哈希（SHA256，流式处理）
        let fileHash = try await calculateFileHash(at: url)
        
        let effectiveChunkSize = min(maxChunkSizeBytes, max(64 * 1024, chunkSize))
        
        // 计算分块数
        let totalChunks = Int(ceil(Double(fileSize) / Double(effectiveChunkSize)))
        
        // 创建传输记录
        let transfer = FileTransfer(
            fileName: fileName,
            fileSize: fileSize,
            fileType: fileType,
            isIncoming: false,
            remotePeer: device.name,
            localPath: url.path
        )
        
        activeTransfers.append(transfer)
        isTransferring = true
        
        // 创建传输状态
        var state = TransferState(transferId: transfer.id)
        state.localURL = url
        state.startTime = Date()
        #if canImport(UIKit)
        let senderDeviceId = UIDevice.current.identifierForVendor?.uuidString
        let senderDeviceName = UIDevice.current.name
        let senderPlatform = UIDevice.current.systemName
        let senderOSVersion = UIDevice.current.systemVersion
        #else
        let senderDeviceId: String? = nil
        let senderDeviceName: String? = nil
        let senderPlatform: String? = nil
        let senderOSVersion: String? = nil
        #endif
        let senderModelName = SBFT_currentModelDisplayName()
        let senderChip = SBFT_currentChipDisplayName()
        state.metadata = FileMetadata(
            transferId: transfer.id,
            fileName: fileName,
            fileSize: fileSize,
            fileHash: fileHash,
            chunkSize: effectiveChunkSize,
            mimeType: getMimeType(for: url),
            compression: compressionEnabled ? "zlib" : nil,
            totalChunks: totalChunks,
            senderDeviceId: senderDeviceId,
            senderDeviceName: senderDeviceName,
            senderPlatform: senderPlatform,
            senderOSVersion: senderOSVersion,
            senderModelName: senderModelName,
            senderChip: senderChip
        )
        transferStates[transfer.id] = state
        
        do {
            // Cross-network path (WebRTC DataChannel): zero-config, no ports required.
            if case .connected = crossNetwork.state,
               let remoteId = crossNetwork.remoteDeviceId,
               device.id == remoteId {
                try await sendFileOverWebRTC(from: url, transfer: transfer, metadata: state.metadata!, to: device)
                await completeTransfer(transfer.id, success: true)
                SkyBridgeLogger.shared.info("✅ 文件发送完成(WebRTC): \(fileName)")
                return
            }
            
            // 建立连接：优先 Bonjour service（不依赖 IP/默认端口）
            //
            // ⚠️ 重要：activeConnections 里的 `DiscoveredDevice` 有时是“连接时快照”，services/ip 可能不完整。
            // 这里尝试用发现管理器的最新记录补全（尤其是 `_skybridge-transfer._tcp`）。
            let resolvedDevice: DiscoveredDevice = {
                if device.services.contains(DiscoveredDevice.fileTransferServiceType) { return device }
                if let fresh = DeviceDiscoveryManager.instance.discoveredDevices.first(where: { $0.id == device.id }) {
                    return fresh
                }
                return device
            }()

            let endpoint: NWEndpoint
            if resolvedDevice.services.contains(DiscoveredDevice.fileTransferServiceType) {
                endpoint = .service(
                    name: resolvedDevice.bonjourServiceName ?? resolvedDevice.name,
                    type: DiscoveredDevice.fileTransferServiceType,
                    domain: resolvedDevice.bonjourServiceDomain ?? "local.",
                    interface: nil
                )
            } else if let ip = resolvedDevice.ipAddress, !ip.isEmpty {
                let port = resolvedDevice.fileTransferPort ?? FileTransferConstants.defaultPort
                endpoint = .hostPort(host: .init(ip), port: .init(integerLiteral: port))
            } else {
                throw FileTransferError.invalidDestination
            }

            let connection = try await createConnection(to: endpoint)
            transferStates[transfer.id]?.connection = connection
            
            // 发送元数据
            try await sendMetadata(state.metadata!, over: connection)
            
            // 分块发送文件
            try await sendFileInChunks(from: url, transfer: transfer, over: connection, chunkSize: effectiveChunkSize)
            
            // 完成传输
            await completeTransfer(transfer.id, success: true)
            
            SkyBridgeLogger.shared.info("✅ 文件发送完成: \(fileName)")
            
        } catch {
            await completeTransfer(transfer.id, success: false, error: error)
            throw error
        }
    }

    // MARK: - Cross-network (WebRTC DataChannel) send
    
    private func sendFileOverWebRTC(
        from url: URL,
        transfer: FileTransfer,
        metadata: FileMetadata,
        to device: DiscoveredDevice
    ) async throws {
        // Use a smaller chunk size for DataChannel to keep per-message size stable.
        let dcChunkSize = min(64 * 1024, max(8 * 1024, metadata.chunkSize))
        let totalChunks = Int(ceil(Double(metadata.fileSize) / Double(dcChunkSize)))
        
        let senderDeviceId = KeychainManager.shared.getOrGenerateDeviceId()
        let senderDeviceName: String? = {
            #if canImport(UIKit)
            return UIDevice.current.name
            #else
            return nil
            #endif
        }()
        
        let meta = CrossNetworkFileTransferMessage(
            op: .metadata,
            transferId: transfer.id,
            senderDeviceId: senderDeviceId,
            senderDeviceName: senderDeviceName,
            fileName: metadata.fileName,
            fileSize: metadata.fileSize,
            chunkSize: dcChunkSize,
            totalChunks: totalChunks,
            mimeType: metadata.mimeType
        )
        try await crossNetwork.sendFileTransferMessage(meta)
        _ = try await crossNetwork.waitForFileTransferAck(
            transferId: transfer.id,
            op: .metadataAck,
            timeoutSeconds: 15
        )
        
        guard let fileHandle = FileHandle(forReadingAtPath: url.path) else {
            throw FileTransferError.fileNotFound
        }
        defer { try? fileHandle.close() }
        
        var sentBytes: Int64 = 0
        var chunkIndex = 0
        
        while sentBytes < metadata.fileSize {
            // Cancel check
            if let st = transferStates[transfer.id], st.isCancelled {
                let cancel = CrossNetworkFileTransferMessage(op: .cancel, transferId: transfer.id, message: "cancelled")
                try? await crossNetwork.sendFileTransferMessage(cancel)
                throw FileTransferError.transferCancelled
            }
            
            let remainingBytes = metadata.fileSize - sentBytes
            let currentChunkSize = min(Int64(dcChunkSize), remainingBytes)
            
            try fileHandle.seek(toOffset: UInt64(sentBytes))
            let chunkData = fileHandle.readData(ofLength: Int(currentChunkSize))
            let rawSize = chunkData.count
            
            let msg = CrossNetworkFileTransferMessage(
                op: .chunk,
                transferId: transfer.id,
                chunkIndex: chunkIndex,
                chunkData: chunkData,
                // Avoid cross-target helper type drift: compute SHA-256 locally.
                chunkSha256: Data(SHA256.hash(data: chunkData)),
                rawSize: rawSize
            )
            try await crossNetwork.sendFileTransferMessage(msg)
            
            let ack: CrossNetworkFileTransferMessage = try await { () async throws -> CrossNetworkFileTransferMessage in
                var lastError: Error?
                for _ in 0..<3 {
                    do {
                        return try await crossNetwork.waitForFileTransferAck(
                            transferId: transfer.id,
                            op: .chunkAck,
                            chunkIndex: chunkIndex,
                            timeoutSeconds: 20
                        )
                    } catch {
                        lastError = error
                        // Best-effort resend: safe because receiver writes at fixed offset.
                        try? await crossNetwork.sendFileTransferMessage(msg)
                    }
                }
                if let lastError { throw lastError }
                throw FileTransferError.networkError("chunk ack retries exhausted")
            }()
            
            // Use receiver-reported progress if present (more accurate than "sent").
            if let rb = ack.receivedBytes {
                sentBytes = max(sentBytes + Int64(rawSize), rb)
            } else {
                sentBytes += Int64(rawSize)
            }
            chunkIndex += 1
            
            await updateProgress(transfer.id, transferredBytes: sentBytes, totalBytes: metadata.fileSize)
        }
        
        let done = CrossNetworkFileTransferMessage(op: .complete, transferId: transfer.id)
        try await crossNetwork.sendFileTransferMessage(done)
        _ = try await crossNetwork.waitForFileTransferAck(
            transferId: transfer.id,
            op: .completeAck,
            timeoutSeconds: 20
        )
    }
    
    /// 接收文件
    /// - Parameters:
    ///   - metadata: 文件元数据
    ///   - connection: 网络连接
    public func receiveFile(metadata: FileMetadata, from connection: NWConnection, peer: String) async throws -> URL {
        await acquireTransferSlot()
        defer { releaseTransferSlot() }

        SkyBridgeLogger.shared.info("📥 开始接收文件: \(metadata.fileName) 从设备: \(peer)")
        if metadata.chunkSize > maxChunkSizeBytes {
            throw FileTransferError.invalidMetadata
        }

        let targetURL = makeUniqueDestinationURL(fileName: metadata.fileName)
        
        // 创建传输记录
        let transfer = FileTransfer(
            fileName: metadata.fileName,
            fileSize: metadata.fileSize,
            fileType: determineFileType(fromName: metadata.fileName),
            isIncoming: true,
            remotePeer: peer,
            localPath: targetURL.path
        )
        
        activeTransfers.append(transfer)
        isTransferring = true
        postLocalFileTransferNotification(
            title: "正在接收文件",
            body: "\(metadata.fileName) 来自 \(peer)",
            transferId: transfer.id,
            fileName: metadata.fileName,
            localPath: targetURL.path
        )
        
        // 创建传输状态
        var state = TransferState(transferId: transfer.id)
        state.metadata = metadata
        state.connection = connection
        state.startTime = Date()
        
        // 创建目标文件
        state.localURL = targetURL
        transferStates[transfer.id] = state
        
        do {
            // 分块接收文件
            try await receiveFileInChunks(to: targetURL, transfer: transfer, from: connection, metadata: metadata)
            
            // 验证哈希
            let receivedHash = try await calculateFileHash(at: targetURL)
            guard receivedHash == metadata.fileHash else {
                throw FileTransferError.checksumMismatch
            }
            
            // 完成传输
            await completeTransfer(transfer.id, success: true)
            
            SkyBridgeLogger.shared.info("✅ 文件接收完成: \(metadata.fileName)")
            
            return targetURL
            
        } catch {
            await completeTransfer(transfer.id, success: false, error: error)
            throw error
        }
    }
    
    /// 取消传输
    public func cancelTransfer(_ transferId: String) {
        if var state = transferStates[transferId] {
            state.isCancelled = true
            state.connection?.cancel()
            transferStates[transferId] = state
        }
        
        if let index = activeTransfers.firstIndex(where: { $0.id == transferId }) {
            activeTransfers[index].status = .failed
            activeTransfers.remove(at: index)
        }
        
        updateTransferringState()
    }
    
    /// 清空历史
    public func clearHistory() {
        transferHistory.removeAll()
        saveHistory()
    }
    
    /// 获取下载目录
    public func getDownloadsDirectory() -> URL {
        downloadsDirectory
    }

    private func makeUniqueDestinationURL(fileName: String) -> URL {
        let safeName = (fileName as NSString).lastPathComponent
        let ext = (safeName as NSString).pathExtension
        let stem = (safeName as NSString).deletingPathExtension

        var candidate = downloadsDirectory.appendingPathComponent(safeName)
        var index = 1
        while fileManager.fileExists(atPath: candidate.path) {
            let nextName: String
            if ext.isEmpty {
                nextName = "\(stem) (\(index))"
            } else {
                nextName = "\(stem) (\(index)).\(ext)"
            }
            candidate = downloadsDirectory.appendingPathComponent(nextName)
            index += 1
        }
        return candidate
    }
    
    // MARK: - Private Methods - Sending
    
    /// 分块发送文件
    private func sendFileInChunks(from url: URL, transfer: FileTransfer, over connection: NWConnection, chunkSize: Int) async throws {
        guard let fileHandle = FileHandle(forReadingAtPath: url.path) else {
            throw FileTransferError.fileNotFound
        }
        defer { try? fileHandle.close() }
        
        let fileSize = transfer.fileSize
        var sentBytes: Int64 = 0
        var chunkIndex = 0
        
        while sentBytes < fileSize {
            // 检查是否取消
            if let state = transferStates[transfer.id], state.isCancelled {
                throw FileTransferError.transferCancelled
            }
            
            // 读取分块
            let remainingBytes = fileSize - sentBytes
            let currentChunkSize = min(Int64(chunkSize), remainingBytes)
            
            try fileHandle.seek(toOffset: UInt64(sentBytes))
            let chunkData = fileHandle.readData(ofLength: Int(currentChunkSize))
            
            // 可选：压缩数据
            let processedData: Data
            if compressionEnabled {
                processedData = (try? compressData(chunkData)) ?? chunkData
            } else {
                processedData = chunkData
            }
            
            // 计算分块校验和
            let chunkChecksum = SHA256.hash(data: chunkData).compactMap { String(format: "%02x", $0) }.joined()
            
            // 创建分块
            let chunk = FileChunk(
                index: chunkIndex,
                data: processedData,
                size: chunkData.count,
                checksum: chunkChecksum
            )
            
            // 发送分块
            try await sendChunk(chunk, over: connection)
            
            sentBytes += Int64(chunkData.count)
            chunkIndex += 1
            
            // 更新进度
            await updateProgress(transfer.id, transferredBytes: sentBytes, totalBytes: fileSize)
        }
        
        // 发送完成信号
        try await sendComplete(over: connection)
    }
    
    /// 发送元数据
    private func sendMetadata(_ metadata: FileMetadata, over connection: NWConnection) async throws {
        let data = try JSONEncoder().encode(metadata)
        if data.count > maxMessageBytes {
            throw FileTransferError.invalidMetadata
        }
        let header = TransferHeader(type: .metadata, length: data.count)
        try await sendData(header.encoded + data, over: connection)
    }
    
    /// 发送分块
    private func sendChunk(_ chunk: FileChunk, over connection: NWConnection) async throws {
        let data = try JSONEncoder().encode(chunk)
        if data.count > maxMessageBytes {
            throw FileTransferError.invalidMetadata
        }
        let header = TransferHeader(type: .chunk, length: data.count)
        try await sendData(header.encoded + data, over: connection)
    }
    
    /// 发送完成信号
    private func sendComplete(over connection: NWConnection) async throws {
        let header = TransferHeader(type: .complete, length: 0)
        try await sendData(header.encoded, over: connection)
    }
    
    // MARK: - Private Methods - Receiving
    
    /// 分块接收文件
    private func receiveFileInChunks(
        to url: URL,
        transfer: FileTransfer,
        from connection: NWConnection,
        metadata: FileMetadata
    ) async throws {
        // 创建或打开文件
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        
        guard let fileHandle = FileHandle(forWritingAtPath: url.path) else {
            throw FileTransferError.permissionDenied
        }
        defer { try? fileHandle.close() }
        
        var receivedBytes: Int64 = 0
        let totalBytes = metadata.fileSize
        
        while receivedBytes < totalBytes {
            // 检查是否取消
            if let state = transferStates[transfer.id], state.isCancelled {
                throw FileTransferError.transferCancelled
            }
            
            // 接收分块
            let chunk = try await receiveChunk(from: connection)
            
            // 可选：解压数据（按 metadata.compression 协商；为兼容旧实现，未声明时可做“尝试解压+回退”）
            let processedData: Data
            if metadata.compression == "zlib" {
                processedData = try decompressData(chunk.data)
            } else if compressionEnabled {
                // 旧互通策略：对端未声明但本地开启时尝试解压
                processedData = (try? decompressData(chunk.data)) ?? chunk.data
            } else {
                processedData = chunk.data
            }
            if processedData.count > maxChunkSizeBytes {
                throw FileTransferError.invalidMetadata
            }
            
            // 写入文件
            try fileHandle.seek(toOffset: UInt64(receivedBytes))
            fileHandle.write(processedData)
            
            receivedBytes += Int64(processedData.count)
            
            // 更新进度
            await updateProgress(transfer.id, transferredBytes: receivedBytes, totalBytes: totalBytes)
        }
        
        // 等待完成信号
        _ = try await receiveHeader(from: connection)
    }
    
    /// 接收分块
    private func receiveChunk(from connection: NWConnection) async throws -> FileChunk {
        let header = try await receiveHeader(from: connection)
        guard header.type == .chunk else {
            throw FileTransferError.invalidMetadata
        }
        
        let data = try await receiveData(length: header.length, from: connection)
        let chunk = try JSONDecoder().decode(FileChunk.self, from: data)
        if chunk.size > maxChunkSizeBytes {
            throw FileTransferError.invalidMetadata
        }
        return chunk
    }
    
    /// 接收头部
    private func receiveHeader(from connection: NWConnection) async throws -> TransferHeader {
        let headerData = try await receiveData(length: 8, from: connection)
        guard let header = TransferHeader.decode(from: headerData) else {
            throw FileTransferError.invalidMetadata
        }
        guard header.length >= 0, header.length <= maxMessageBytes else {
            throw FileTransferError.invalidMetadata
        }
        return header
    }
    
    // MARK: - Private Methods - Network
    
    /// 创建连接
    private func createConnection(to endpoint: NWEndpoint) async throws -> NWConnection {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 30
            tcp.keepaliveInterval = 15
            tcp.keepaliveCount = 4
        }
        
        let connection = NWConnection(to: endpoint, using: parameters)
        
        return try await withCheckedThrowingContinuation { continuation in
            // Prevent SWIFT TASK CONTINUATION MISUSE: NWConnection may emit multiple state transitions
            // (e.g., .ready then later .cancelled) and `withCheckedThrowingContinuation` must be resumed exactly once.
            final class Once: @unchecked Sendable {
                private let lock = NSLock()
                private var done = false
                func run(_ block: () -> Void) {
                    lock.lock()
                    defer { lock.unlock() }
                    guard !done else { return }
                    done = true
                    block()
                }
            }
            let once = Once()
            
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.run {
                        connection.stateUpdateHandler = nil
                        continuation.resume(returning: connection)
                    }
                case .failed(let error):
                    once.run {
                        connection.stateUpdateHandler = nil
                        continuation.resume(throwing: FileTransferError.networkError(error.localizedDescription))
                    }
                case .cancelled:
                    once.run {
                        connection.stateUpdateHandler = nil
                        continuation.resume(throwing: FileTransferError.transferCancelled)
                    }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }
    
    /// 发送数据
    private func sendData(_ data: Data, over connection: NWConnection) async throws {
        // 上传限速（KB/s），0 表示不限制
        let kbps = SettingsManager.instance.fileTransferUploadLimitKBps
        if kbps <= 0 {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error = error {
                        continuation.resume(throwing: FileTransferError.networkError(error.localizedDescription))
                    } else {
                        continuation.resume()
                    }
                })
            }
            return
        }

        let bytesPerSecond = max(1024, kbps * 1024)
        let chunkBytes = max(8 * 1024, min(256 * 1024, bytesPerSecond / 4)) // 4 chunks/s

        var offset = 0
        while offset < data.count {
            let end = min(data.count, offset + chunkBytes)
            let slice = data.subdata(in: offset..<end)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: slice, completion: .contentProcessed { error in
                    if let error = error {
                        continuation.resume(throwing: FileTransferError.networkError(error.localizedDescription))
                    } else {
                        continuation.resume()
                    }
                })
            }

            offset = end

            // 粗粒度节流：按 chunk 大小估算 sleep
            let seconds = Double(slice.count) / Double(bytesPerSecond)
            if seconds > 0 {
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }
    
    /// 接收数据
    private func receiveData(length: Int, from connection: NWConnection) async throws -> Data {
        let data: Data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { data, _, _, error in
                if let error = error {
                    continuation.resume(throwing: FileTransferError.networkError(error.localizedDescription))
                } else if let data = data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: FileTransferError.transferFailed("No data received"))
                }
            }
        }

        // 下载限速（KB/s），0 表示不限制。仅做“消费端节流”，减少写盘/处理速度。
        let kbps = SettingsManager.instance.fileTransferDownloadLimitKBps
        if kbps > 0 {
            let bytesPerSecond = max(1024, kbps * 1024)
            let seconds = Double(data.count) / Double(bytesPerSecond)
            if seconds > 0 {
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
        return data
    }

    private func acquireTransferSlot() async {
        let limit = max(1, SettingsManager.instance.fileTransferMaxConcurrentTransfers)
        if inFlightTransferCount < limit {
            inFlightTransferCount += 1
            return
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            transferWaiters.append(continuation)
        }
        inFlightTransferCount += 1
    }

    private func releaseTransferSlot() {
        inFlightTransferCount = max(0, inFlightTransferCount - 1)
        if !transferWaiters.isEmpty, inFlightTransferCount < max(1, SettingsManager.instance.fileTransferMaxConcurrentTransfers) {
            let c = transferWaiters.removeFirst()
            c.resume()
        }
    }
    
    // MARK: - Private Methods - Utilities
    
    /// 计算文件哈希（SHA256，流式处理，避免大文件内存峰值）
    private func calculateFileHash(at url: URL) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    var hasher = SHA256()
                    let chunkSize = 1_048_576 // 1MB
                    while true {
                        let chunk = try handle.read(upToCount: chunkSize)
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
    
    /// 压缩数据
    private func compressData(_ data: Data) throws -> Data {
        // 使用 zlib 压缩
        return try (data as NSData).compressed(using: .zlib) as Data
    }
    
    /// 解压数据
    private func decompressData(_ data: Data) throws -> Data {
        return try (data as NSData).decompressed(using: .zlib) as Data
    }
    
    /// 更新进度
    private func updateProgress(_ transferId: String, transferredBytes: Int64, totalBytes: Int64) async {
        let progress = Double(transferredBytes) / Double(totalBytes)
        let speed = calculateSpeed(transferId: transferId, transferredBytes: transferredBytes)
        
        var fileName: String?
        var direction: SkyBridgeActivityAttributes.TransferDirection = .none

        if let index = activeTransfers.firstIndex(where: { $0.id == transferId }) {
            activeTransfers[index].progress = progress
            activeTransfers[index].speed = speed
            activeTransfers[index].status = .transferring
            fileName = activeTransfers[index].fileName
            direction = activeTransfers[index].isIncoming ? .download : .upload
        }
        
        transferStates[transferId]?.transferredBytes = transferredBytes
        transferStates[transferId]?.lastUpdateTime = Date()
        
        // 更新总进度
        updateTotalProgress()

        // 更新灵动岛传输进度（iOS 17+）
        if let name = fileName {
            let speedStr = formatSpeed(speed)
            Task {
                await LiveActivityManager.shared.updateTransferProgress(
                    fileName: name,
                    progress: progress,
                    direction: direction,
                    speed: speedStr
                )
            }
        }
    }

    private func formatSpeed(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1_000_000_000 {
            return String(format: "%.1f GB/s", bytesPerSecond / 1_000_000_000)
        } else if bytesPerSecond >= 1_000_000 {
            return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
        } else if bytesPerSecond >= 1_000 {
            return String(format: "%.1f KB/s", bytesPerSecond / 1_000)
        } else {
            return String(format: "%.0f B/s", bytesPerSecond)
        }
    }

    private func storageLocationHint(localPath: String?) -> String? {
        guard let localPath else { return nil }
        let url = URL(fileURLWithPath: localPath)
        return "Downloads/\(url.lastPathComponent)"
    }

    private func upsertLocalPath(_ localPath: String?, for transferId: String) {
        guard let localPath else { return }
        if let idx = activeTransfers.firstIndex(where: { $0.id == transferId }) {
            activeTransfers[idx].localPath = localPath
        }
        if let idx = transferHistory.firstIndex(where: { $0.id == transferId }) {
            transferHistory[idx].localPath = localPath
            saveHistory()
        }
    }

    private func postLocalFileTransferNotification(
        title: String,
        body: String,
        transferId: String,
        fileName: String,
        localPath: String? = nil
    ) {
        #if canImport(UserNotifications)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = "FILE_TRANSFER"
        var userInfo: [String: String] = [
            "transferId": transferId,
            "fileName": fileName
        ]
        if let localPath {
            userInfo["localPath"] = localPath
        }
        content.userInfo = userInfo

        let request = UNNotificationRequest(
            identifier: "file-transfer-\(transferId)-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                SkyBridgeLogger.shared.debug("ℹ️ 文件通知发送失败: \(error.localizedDescription)")
            }
        }
        #endif
    }
    
    /// 计算传输速度
    private func calculateSpeed(transferId: String, transferredBytes: Int64) -> Double {
        guard let state = transferStates[transferId],
              let startTime = state.startTime else {
            return 0
        }
        
        let elapsed = Date().timeIntervalSince(startTime)
        guard elapsed > 0 else { return 0 }
        
        return Double(transferredBytes) / elapsed
    }
    
    /// 更新总进度
    private func updateTotalProgress() {
        guard !activeTransfers.isEmpty else {
            totalProgress = 0
            return
        }
        
        let total = activeTransfers.reduce(0.0) { $0 + $1.progress }
        totalProgress = total / Double(activeTransfers.count)
    }
    
    /// 完成传输
    private func completeTransfer(_ transferId: String, success: Bool, error: Error? = nil) async {
        let savedURL = transferStates[transferId]?.localURL
        var finalizedTransfer: FileTransfer?

        if let index = activeTransfers.firstIndex(where: { $0.id == transferId }) {
            activeTransfers[index].status = success ? .completed : .failed
            activeTransfers[index].progress = success ? 1.0 : activeTransfers[index].progress
            if let savedURL {
                activeTransfers[index].localPath = savedURL.path
            }
            
            // 移动到历史
            let completedTransfer = activeTransfers[index]
            activeTransfers.remove(at: index)
            transferHistory.insert(completedTransfer, at: 0)
            saveHistory()
            finalizedTransfer = completedTransfer
        }

        if let finalizedTransfer {
            if success {
                if finalizedTransfer.isIncoming {
                    let location = storageLocationHint(localPath: finalizedTransfer.localPath) ?? "Downloads"
                    postLocalFileTransferNotification(
                        title: "文件接收完成",
                        body: "\(finalizedTransfer.fileName) 已保存到 \(location)",
                        transferId: finalizedTransfer.id,
                        fileName: finalizedTransfer.fileName,
                        localPath: finalizedTransfer.localPath
                    )
                } else {
                    postLocalFileTransferNotification(
                        title: "文件发送完成",
                        body: "\(finalizedTransfer.fileName) 已发送到 \(finalizedTransfer.remotePeer)",
                        transferId: finalizedTransfer.id,
                        fileName: finalizedTransfer.fileName
                    )
                }
            } else {
                let reason = error?.localizedDescription ?? "未知错误"
                postLocalFileTransferNotification(
                    title: "文件传输失败",
                    body: "\(finalizedTransfer.fileName) · \(reason)",
                    transferId: finalizedTransfer.id,
                    fileName: finalizedTransfer.fileName,
                    localPath: finalizedTransfer.localPath
                )
            }
        }

        // 更新灵动岛：传输完成（iOS 17+）
        Task {
            await LiveActivityManager.shared.transferCompleted()
        }
        
        // 清理状态
        transferStates[transferId]?.connection?.cancel()
        transferStates.removeValue(forKey: transferId)
        
        updateTransferringState()
    }
    
    /// 更新传输状态
    private func updateTransferringState() {
        isTransferring = !activeTransfers.isEmpty
        updateTotalProgress()
    }

    // MARK: - External inbound (WebRTC DataChannel) helpers
    
    /// Begin an inbound transfer delivered via an external transport (e.g. WebRTC DataChannel).
    public func beginExternalInboundTransfer(
        transferId: String,
        fileName: String,
        fileSize: Int64,
        fromPeerName: String,
        destinationURL: URL? = nil
    ) {
        if activeTransfers.contains(where: { $0.id == transferId }) { return }
        
        let transfer = FileTransfer(
            id: transferId,
            fileName: fileName,
            fileSize: fileSize,
            fileType: determineFileType(fromName: fileName),
            progress: 0.0,
            speed: 0.0,
            status: .pending,
            isIncoming: true,
            remotePeer: fromPeerName,
            localPath: destinationURL?.path
        )
        activeTransfers.append(transfer)
        updateTransferringState()
        postLocalFileTransferNotification(
            title: "收到文件传输请求",
            body: "\(fileName) 来自 \(fromPeerName)",
            transferId: transferId,
            fileName: fileName,
            localPath: destinationURL?.path
        )
    }

    public func markExternalInboundSavedLocation(transferId: String, destinationURL: URL) {
        upsertLocalPath(destinationURL.path, for: transferId)
    }
    
    public func updateExternalInboundProgress(
        transferId: String,
        transferredBytes: Int64,
        totalBytes: Int64
    ) {
        Task { @MainActor in
            await self.updateProgress(transferId, transferredBytes: transferredBytes, totalBytes: totalBytes)
        }
    }
    
    public func completeExternalInboundTransfer(
        transferId: String,
        success: Bool,
        error: String? = nil,
        destinationURL: URL? = nil
    ) {
        if let destinationURL {
            upsertLocalPath(destinationURL.path, for: transferId)
        }

        var completedTransfer: FileTransfer?
        if let idx = activeTransfers.firstIndex(where: { $0.id == transferId }) {
            activeTransfers[idx].status = success ? .completed : .failed
            if success { activeTransfers[idx].progress = 1.0 }
            if let destinationURL {
                activeTransfers[idx].localPath = destinationURL.path
            }
            let finalized = activeTransfers[idx]
            completedTransfer = finalized
            activeTransfers.remove(at: idx)
            transferHistory.insert(finalized, at: 0)
            saveHistory()
        }

        if let completedTransfer {
            if success {
                let location = storageLocationHint(localPath: completedTransfer.localPath) ?? "Downloads"
                postLocalFileTransferNotification(
                    title: "文件接收完成",
                    body: "\(completedTransfer.fileName) 已保存到 \(location)",
                    transferId: completedTransfer.id,
                    fileName: completedTransfer.fileName,
                    localPath: completedTransfer.localPath
                )
            } else {
                postLocalFileTransferNotification(
                    title: "文件接收失败",
                    body: "\(completedTransfer.fileName) · \(error ?? "未知错误")",
                    transferId: completedTransfer.id,
                    fileName: completedTransfer.fileName,
                    localPath: completedTransfer.localPath
                )
            }
        }

        Task {
            await LiveActivityManager.shared.transferCompleted()
        }
        updateTransferringState()
    }
    
    /// 确定文件类型
    private func determineFileType(from url: URL) -> FileType {
        determineFileType(fromName: url.lastPathComponent)
    }
    
    private func determineFileType(fromName name: String) -> FileType {
        let ext = (name as NSString).pathExtension.lowercased()
        
        switch ext {
        case "jpg", "jpeg", "png", "gif", "heic", "webp", "bmp", "tiff":
            return .image
        case "mp4", "mov", "avi", "mkv", "m4v", "wmv", "flv":
            return .video
        case "mp3", "m4a", "wav", "aac", "flac", "ogg":
            return .audio
        case "pdf", "doc", "docx", "txt", "pages", "rtf", "xls", "xlsx", "ppt", "pptx":
            return .document
        case "zip", "rar", "7z", "tar", "gz", "bz2":
            return .archive
        default:
            return .other
        }
    }
    
    /// 获取 MIME 类型
    private func getMimeType(for url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        
        let mimeTypes: [String: String] = [
            "jpg": "image/jpeg",
            "jpeg": "image/jpeg",
            "png": "image/png",
            "gif": "image/gif",
            "pdf": "application/pdf",
            "mp4": "video/mp4",
            "mov": "video/quicktime",
            "mp3": "audio/mpeg",
            "zip": "application/zip",
            "txt": "text/plain"
        ]
        
        return mimeTypes[ext]
    }
    
    // MARK: - Persistence
    
    private func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: "transfer_history"),
              let history = try? JSONDecoder().decode([FileTransfer].self, from: data) else {
            return
        }
        transferHistory = history
    }
    
    private func saveHistory() {
        // 只保留最近 100 条记录
        let historyToSave = Array(transferHistory.prefix(100))
        guard let data = try? JSONEncoder().encode(historyToSave) else { return }
        UserDefaults.standard.set(data, forKey: "transfer_history")
    }
}
