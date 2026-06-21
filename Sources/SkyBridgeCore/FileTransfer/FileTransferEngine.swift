import Foundation
import Network
import Compression
import CryptoKit
import Combine
import OSLog
// 导入 ConnectionStatus（符合 Swift 6.2.1 的 Sendable 要求）
// ConnectionStatus 已在 ConnectionStatus.swift 中定义，符合 Sendable 协议
// 量子安全组件（同一模块内可直接访问）
// 使用增强版密钥管理与加密实现
// - EnhancedQuantumKeyManager: 主密钥的安全生成与Keychain持久化
// - EnhancedPostQuantumCrypto: AES-GCM 与签名实现
// - CryptoKitEnhancements: HKDF派生、密钥轮换策略

/// 高性能文件传输引擎 - 支持断点续传、多线程传输、压缩优化和加密传输
/// 增强支持高分辨率视频传输和Apple Silicon优化
@MainActor
public class FileTransferEngine: ObservableObject {
    private static let transferHistoryStore = CodablePersistenceStore<[FileTransferRecord]>(
        location: .protectedApplicationSupport(
            path: "FileTransfer/engine-history.json",
            legacyUserDefaultsKey: "FileTransferHistory"
        )
    )
    
 // MARK: - 发布属性
    
    @Published public var activeTransfers: [String: FileTransferSession] = [:]
    @Published public var transferHistory: [FileTransferRecord] = []
    @Published public var totalProgress: Double = 0.0
    @Published public var transferSpeed: Double = 0.0 // 字节/秒
    @Published public var videoTransferConfiguration: VideoTransferConfiguration = .default
    
 // MARK: - 私有属性
    
    private let configuration: TransferConfiguration
    private let networkManager: P2PNetworkManager
    private let securityManager: P2PSecurityManager
    private var transferQueue: OperationQueue
    @MainActor private var speedCalculationTimer: Timer?
    private var lastBytesTransferred: Int64 = 0
    private var cancellables = Set<AnyCancellable>()
    private let fileHashWorker = FileHashWorker()
    private var isCleanedUp: Bool = false

 // 量子安全：密钥与加密组件
    private let quantumKeyManager = EnhancedQuantumKeyManager()
    private let pqCrypto = EnhancedPostQuantumCrypto()
    private let rotationManager = CryptoKitEnhancements.KeyRotationManager()
    private let logger = Logger(subsystem: "com.skybridge.filetransfer", category: "Engine")

 // 大文件流式加密缓存（transferId -> (tempURL, AEAD info)）
    private var streamingEncryptedFiles: [String: (url: URL, aead: EncryptedData)] = [:]
 // 大文件接收端临时密文缓存（transferId -> tempEncURL）
    private var streamingEncryptedRecvFiles: [String: URL] = [:]
    
 // 并行加密/解密（P2）
    private let parallelCrypto = PerformanceOptimizations.ParallelEncryptionManager()
    
 // 错误处理和重试 - 利用Swift 6.2.1的并发改进
    private let retryManager = RetryManager(policy: .default)
    private var automaticRetryEnabled: Bool
    /// 运行时可变的加密开关（与 configuration.encryptionEnabled 的初值一致，但可被设置变更实时更新）。
    /// configuration 是不可变 let，过去切换设置只走 updateEncryptionSettings 的日志、对后续传输无效。
    private var runtimeEncryptionEnabled: Bool
    private var keepTransferHistory: Bool = true
    private var keepSystemAwakeDuringTransfer: Bool = false
    private var encryptionAlgorithm: FileTransferEncryptionAlgorithm = .aes256GCM
    private let powerAssertion = FileTransferPowerAssertionController()
    
 // 传输速度限制 - 利用macOS 26.x的网络改进
    @Published public var maxTransferSpeed: Double? // 字节/秒，nil表示无限制
    private var speedLimiter: TransferSpeedLimiter?
    
 // 设备连接管理 - 利用macOS 26.x的改进持久化
    public let deviceManager = DeviceConnectionManager()
    
 // Apple Silicon优化相关（简化实现）
    private let isAppleSilicon = true // 简化检测
    private let metalAccel = PerformanceOptimizations.MetalAcceleration()
    private var metalAvailable: Bool { PerformanceOptimizations.MetalAcceleration.isMetalAvailable() }
    private func threadsPerTransfer() -> Int {
 // Metal 可用时适度提升并发度
        let base = configuration.maxThreadsPerTransfer
        return metalAvailable ? min(base * 2, 8) : base
    }
    
 // MARK: - 初始化
    
    public init(configuration: TransferConfiguration = .default, settingsManager: SettingsManager? = nil) {
 // 如果提供了设置管理器，则使用其配置创建传输配置
        if let settings = settingsManager {
            self.automaticRetryEnabled = settings.autoRetryFailedTransfers
            self.runtimeEncryptionEnabled = settings.enableConnectionEncryption
            self.keepTransferHistory = settings.keepTransferHistory
            self.keepSystemAwakeDuringTransfer = settings.keepSystemAwakeDuringTransfer
            self.encryptionAlgorithm = settings.encryptionAlgorithm
            self.configuration = TransferConfiguration(
                maxConcurrentTransfers: settings.maxConcurrentConnections,
                chunkSize: 1024 * 1024, // 1MB 固定块大小
                maxThreadsPerTransfer: 4,
                compressionEnabled: true,
                encryptionEnabled: settings.enableConnectionEncryption,
                resumeEnabled: settings.autoRetryFailedTransfers,
                bufferSize: settings.transferBufferSize
            )
        } else {
            self.configuration = configuration
            self.automaticRetryEnabled = configuration.resumeEnabled
            self.runtimeEncryptionEnabled = configuration.encryptionEnabled
        }
        
        self.networkManager = P2PNetworkManager.shared
        self.securityManager = P2PSecurityManager()
        
 // 配置传输队列
        self.transferQueue = OperationQueue()
        self.transferQueue.maxConcurrentOperationCount = configuration.maxConcurrentTransfers
        self.transferQueue.qualityOfService = .userInitiated
        
 // 设置速度监控
        setupSpeedMonitoring()
        
 // 加载传输历史
        loadTransferHistory()
        
 // 如果提供了设置管理器，设置观察者
        if let settings = settingsManager {
            setupSettingsObserver(settings)
        }
    }
    
 // MARK: - 设置观察者
    
    private func setupSettingsObserver(_ settingsManager: SettingsManager) {
        settingsManager.$transferBufferSize
            .sink { [weak self] newSize in
                self?.updateBufferSize(newSize)
            }
            .store(in: &cancellables)
        
        settingsManager.$maxConcurrentConnections
            .sink { [weak self] newMax in
                self?.updateMaxConcurrentTransfers(newMax)
            }
            .store(in: &cancellables)
        
        settingsManager.$enableConnectionEncryption
            .sink { [weak self] enabled in
                self?.updateEncryptionSettings(enabled)
            }
            .store(in: &cancellables)
        
        settingsManager.$autoRetryFailedTransfers
            .sink { [weak self] enabled in
                self?.updateAutoRetrySettings(enabled)
            }
            .store(in: &cancellables)
        
        settingsManager.$keepTransferHistory
            .sink { [weak self] keepHistory in
                self?.updateHistorySettings(keepHistory)
            }
            .store(in: &cancellables)
        
        settingsManager.$keepSystemAwakeDuringTransfer
            .sink { [weak self] keepAwake in
                self?.updateSystemAwakeSettings(keepAwake)
            }
            .store(in: &cancellables)
        
        settingsManager.$encryptionAlgorithm
            .sink { [weak self] algorithm in
                self?.updateEncryptionAlgorithm(algorithm)
            }
            .store(in: &cancellables)
        
 // 监听病毒扫描设置变化
        settingsManager.$scanTransferFilesForVirus
            .sink { [weak self] enabled in
                self?.updateVirusScanSettings(enabled)
            }
            .store(in: &cancellables)
        
 // 监听扫描级别设置变化
        settingsManager.$scanLevel
            .sink { [weak self] level in
                self?.updateScanLevel(level)
            }
            .store(in: &cancellables)
    }
    
 /// 是否启用病毒扫描（从 SettingsManager 同步）
    private var virusScanEnabled: Bool = false
    
 /// 当前扫描级别（从 SettingsManager 同步）
    private var currentScanLevel: FileScanService.ScanLevel = .standard
    
    private func updateVirusScanSettings(_ enabled: Bool) {
        virusScanEnabled = enabled
        logger.debugOnly("🛡️ 文件病毒扫描已\(enabled ? "启用" : "禁用")")
    }
    
    private func updateScanLevel(_ level: FileScanService.ScanLevel) {
        currentScanLevel = level
        logger.debugOnly("🛡️ 扫描级别已更新: \(level.rawValue)")
    }
    
 /// 扫描接收的文件（如果启用）
 /// - Parameter url: 文件URL
 /// - Returns: 扫描结果，如果未启用扫描则返回 nil
    private func scanReceivedFileIfEnabled(_ url: URL) async -> FileScanResult? {
        guard virusScanEnabled else {
            logger.debugOnly("🛡️ 病毒扫描未启用，跳过扫描")
            return nil
        }
        
        logger.info("🛡️ 开始扫描接收的文件: \(url.lastPathComponent) [级别: \(self.currentScanLevel.rawValue)]")
        let configuration = FileScanService.ScanConfiguration(level: self.currentScanLevel)
        let result = await FileScanService.shared.scanFile(at: url, configuration: configuration)
        
        if !result.isSafe {
            logger.warning("🚨 检测到威胁: \(result.threatName ?? "未知") - \(url.lastPathComponent)")
            
 // 发送威胁检测通知
            NotificationCenter.default.post(
                name: .fileThreatDetected,
                object: nil,
                userInfo: [
                    "fileURL": url,
                    "threatName": result.threatName ?? "Unknown",
                    "scanMethod": result.scanMethod.rawValue
                ]
            )
        }
        
        return result
    }
    
 // MARK: - 设置更新方法
    
    private func updateBufferSize(_ newSize: Int) {
 // 更新传输缓冲区大小
 // 这里可以更新配置或重新配置网络管理器
        logger.debugOnly("📊 更新传输缓冲区大小: \(newSize)")
        
 // 如果有活跃传输，可能需要重新配置
        if !activeTransfers.isEmpty {
            logger.debugOnly("⚠️ 有活跃传输，缓冲区大小将在下次传输时生效")
        }
    }
    
    private func updateMaxConcurrentTransfers(_ newMax: Int) {
        transferQueue.maxConcurrentOperationCount = newMax
    }
    
    private func updateEncryptionSettings(_ enabled: Bool) {
 // 更新运行时加密开关：影响此后新建的传输会话（见 sendFile 的 effectiveEncryptionEnabled）。
        runtimeEncryptionEnabled = enabled
        logger.debugOnly("🔐 更新加密设置: \(enabled ? "启用" : "禁用")")
    }
    
    func applyRuntimeSettings(
        autoRetryFailedTransfers: Bool,
        keepTransferHistory: Bool,
        keepSystemAwakeDuringTransfer: Bool,
        encryptionAlgorithm: FileTransferEncryptionAlgorithm
    ) {
        updateAutoRetrySettings(autoRetryFailedTransfers)
        updateHistorySettings(keepTransferHistory)
        updateSystemAwakeSettings(keepSystemAwakeDuringTransfer)
        updateEncryptionAlgorithm(encryptionAlgorithm)
    }

    private func updateAutoRetrySettings(_ enabled: Bool) {
 // 更新自动重试设置
        automaticRetryEnabled = enabled
        logger.debugOnly("🔄 更新自动重试设置: \(enabled ? "启用" : "禁用")")
        
        if enabled {
 // 可以重新启动失败的传输
        }
    }
    
    private func updateHistorySettings(_ keepHistory: Bool) {
        keepTransferHistory = keepHistory
        if !keepHistory {
            transferHistory.removeAll()
            try? Self.transferHistoryStore.remove()
        }
    }
    
    private func updateSystemAwakeSettings(_ keepAwake: Bool) {
        keepSystemAwakeDuringTransfer = keepAwake
        updateSystemAwakeAssertion()
    }
    
    private func updateEncryptionAlgorithm(_ algorithm: FileTransferEncryptionAlgorithm) {
        encryptionAlgorithm = algorithm
        logger.debugOnly("🔐 文件传输加密算法: \(algorithm.displayName)")
    }
    
 // MARK: - 系统唤醒管理
    
 // 断言ID由注册表辅助管理，避免在非隔离上下文访问实例属性
    
 /// 启用系统保持唤醒
    private func updateSystemAwakeAssertion() {
        powerAssertion.update(
            shouldKeepAwake: keepSystemAwakeDuringTransfer,
            hasActiveTransfers: !activeTransfers.isEmpty
        )
    }
    
 // MARK: - 视频传输配置
    
 /// 更新视频传输配置
    public func updateVideoConfiguration(_ config: VideoTransferConfiguration) {
        videoTransferConfiguration = config
        
 // 如果有活跃的视频传输，应用新配置
        for session in activeTransfers.values {
            if session.localURL.pathExtension.lowercased() == "mp4" ||
               session.localURL.pathExtension.lowercased() == "mov" {
 // 这是视频文件传输，应用新配置
                logger.debugOnly("📹 为活跃视频传输应用新配置")
            }
        }
    }
    
 // MARK: - 核心传输方法
    
 /// 设置传输速度限制 - 利用macOS 26.x的网络改进
    public func setMaxTransferSpeed(_ speed: Double?) {
        maxTransferSpeed = speed
        if let speed = speed {
            speedLimiter = TransferSpeedLimiter(maxSpeed: speed)
            logger.info("⚡ 传输速度限制已设置: \(self.formatSpeed(speed))")
        } else {
            speedLimiter = nil
            logger.info("⚡ 传输速度限制已移除")
        }
    }
    
 /// 发送文件 - 集成重试机制、速度限制和设备管理
    public func sendFile(
        at fileURL: URL,
        to deviceId: String,
        compressionEnabled: Bool? = nil,
        encryptionEnabled: Bool? = nil
    ) async throws -> String {
        guard !isCleanedUp else {
            logger.error("❌ 引擎已清理，拒绝新的传输请求")
            throw FileTransferEngineError.connectionLost
        }
 // 在 MainActor 上下文读取运行时加密开关并定型为不可变本地值，供 @Sendable 闭包安全捕获。
        let effectiveEncryptionEnabled = encryptionEnabled ?? self.runtimeEncryptionEnabled
 // 使用重试管理器执行传输 - 利用Swift 6.2.1的并发改进
        let sendOperation: @Sendable () async throws -> String = { [self] in
 // 检查文件是否存在
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw FileTransferEngineError.fileNotFound
        }
        
 // 获取文件大小
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = fileAttributes[.size] as? Int64 ?? 0
        
 // 计算文件校验和
            _ = try await self.calculateFileChecksum(fileURL)
        
 // 创建传输会话 - 需要在MainActor上下文中创建
        let transferId = UUID().uuidString
            let sessionConfig = TransferConfiguration(
                maxConcurrentTransfers: self.configuration.maxConcurrentTransfers,
                chunkSize: self.configuration.chunkSize,
                maxThreadsPerTransfer: self.configuration.maxThreadsPerTransfer,
                compressionEnabled: compressionEnabled ?? self.configuration.compressionEnabled,
                encryptionEnabled: effectiveEncryptionEnabled,
                resumeEnabled: self.configuration.resumeEnabled,
                bufferSize: self.configuration.bufferSize
            )
            
            let session = await MainActor.run {
                FileTransferSession(
            id: transferId,
            type: .send,
            fileName: fileURL.lastPathComponent,
            fileSize: fileSize,
            localURL: fileURL,
            remoteDeviceId: deviceId,
                    configuration: sessionConfig
            )
            }
        
 // 添加到活跃传输
        await MainActor.run {
                self.registerActiveTransfer(session, transferId: transferId)
        }
        
        do {
 // 获取设备连接 - 需要在MainActor上下文中访问
                let connection = await MainActor.run {
                    self.networkManager.activeConnections[deviceId]
                }
                guard let connection = connection else {
                throw FileTransferEngineError.connectionNotFound
            }
            
 // 更新设备连接状态
                await self.deviceManager.updateConnectionStatus(id: deviceId, status: ConnectionStatus.connected)
            
 // 初始化速度限制器（如果启用）- 符合Swift 6.2.1的MainActor使用规范
                let maxSpeed = await MainActor.run { self.maxTransferSpeed }
                if let maxSpeed = maxSpeed {
            await MainActor.run {
                        self.speedLimiter = TransferSpeedLimiter(maxSpeed: maxSpeed)
                    }
                }
                
 // 执行文件传输（带速度限制）
                try await self.performFileTransfer(session, connection: connection)
                
 // 传输成功，更新设备统计 - 需要在MainActor上下文中访问averageSpeed
                let finalSpeed = await MainActor.run { session.averageSpeed }
                await self.deviceManager.updateDeviceStats(
                    id: deviceId,
                    bytesTransferred: fileSize,
                    speed: finalSpeed
                )
                
 // 传输成功
                await MainActor.run { [self] in
                session.state = .completed
                    self.addToHistory(session)
                    self.removeActiveTransfer(transferId)
                    self.cleanupStreamingArtifacts(for: transferId)
                    self.speedLimiter = nil
            }

            return transferId
            
            } catch let error as FileTransferEngineError {
 // 传输失败，更新设备状态
                await self.deviceManager.updateConnectionStatus(id: deviceId, status: ConnectionStatus.error)
                
                await MainActor.run { [self] in
                session.error = error
                session.state = .failed
                    self.addToHistory(session)
                    self.removeActiveTransfer(transferId)
                    self.cleanupStreamingArtifacts(for: transferId)
                    self.speedLimiter = nil
            }

 // 直接抛出错误（已经是FileTransferEngineError类型）
            throw error
            } catch {
 // 其他错误 - 包装为FileTransferEngineError
                await self.deviceManager.updateConnectionStatus(id: deviceId, status: ConnectionStatus.error)
                
                await MainActor.run { [self] in
                    session.error = error
                    session.state = .failed
                    self.addToHistory(session)
                    self.removeActiveTransfer(transferId)
                    self.cleanupStreamingArtifacts(for: transferId)
                    self.speedLimiter = nil
                }
 // 将非FileTransferEngineError错误包装为networkError
                throw FileTransferEngineError.networkError(underlying: error)
            }
        }

        if automaticRetryEnabled {
            return try await retryManager.executeWithRetry(
                operationId: "sendFile-\(fileURL.lastPathComponent)",
                operation: sendOperation
            )
        }

        return try await sendOperation()
    }
    
 /// 格式化速度显示
    private func formatSpeed(_ speed: Double) -> String {
        if speed >= 1_000_000_000 {
            return String(format: "%.1f GB/s", speed / 1_000_000_000)
        } else if speed >= 1_000_000 {
            return String(format: "%.1f MB/s", speed / 1_000_000)
        } else if speed >= 1_000 {
            return String(format: "%.1f KB/s", speed / 1_000)
        } else {
            return String(format: "%.0f B/s", speed)
        }
    }
    
 /// 接收文件
    public func receiveFile(
        from connection: P2PConnection,
        deviceId: String,
        destinationDirectory: URL? = nil
    ) async throws -> String {
        guard !isCleanedUp else {
            logger.error("❌ 引擎已清理，拒绝接收请求")
            throw FileTransferEngineError.connectionLost
        }
 // 接收文件元数据
        let metadata = try await receiveFileMetadata(from: connection)
        
 // 确定目标目录
        let targetDirectory = destinationDirectory ?? getDefaultDownloadDirectory()
        let destinationURL = try FileTransferPathPolicy.uniqueDestinationURL(
            baseDirectory: targetDirectory,
            fileName: metadata.fileName
        )
        
 // 创建传输会话
        let session = FileTransferSession(
            id: metadata.transferId,
            type: .receive,
            fileName: metadata.fileName,
            fileSize: metadata.fileSize,
            localURL: destinationURL,
            remoteDeviceId: deviceId,
            configuration: TransferConfiguration(
                maxConcurrentTransfers: configuration.maxConcurrentTransfers,
                chunkSize: configuration.chunkSize,
                maxThreadsPerTransfer: configuration.maxThreadsPerTransfer,
                compressionEnabled: metadata.compressionEnabled,
                encryptionEnabled: metadata.encryptionEnabled,
                resumeEnabled: configuration.resumeEnabled,
                bufferSize: configuration.bufferSize
            )
        )
        
 // 添加到活跃传输
        await MainActor.run {
            registerActiveTransfer(session, transferId: metadata.transferId)
        }
        
        do {
 // 发送传输确认
            try await sendTransferAcknowledgment(to: connection)
            
 // 执行文件接收
            try await performFileReceive(session, connection: connection, metadata: metadata)
            
 // 文件接收完成后进行病毒扫描（如果启用）
            if let scanResult = await scanReceivedFileIfEnabled(destinationURL) {
                if !scanResult.isSafe {
 // 扫描检测到威胁，标记传输失败
                    logger.warning("🚨 文件扫描检测到威胁: \(scanResult.threatName ?? "未知")")
                    await MainActor.run {
                        session.error = FileTransferEngineError.securityThreatDetected(threatName: scanResult.threatName ?? "未知威胁")
                        session.state = .failed
                        addToHistory(session)
                        removeActiveTransfer(metadata.transferId)
                    }
                    throw FileTransferEngineError.securityThreatDetected(threatName: scanResult.threatName ?? "未知威胁")
                }
                logger.info("✅ 文件扫描通过: \(destinationURL.lastPathComponent)")
            }
            
 // 接收成功
            await MainActor.run {
                session.state = .completed
                addToHistory(session)
                removeActiveTransfer(metadata.transferId)
            }
            
            return metadata.transferId
            
        } catch {
 // 接收失败
            await MainActor.run {
                session.error = error
                session.state = .failed
                addToHistory(session)
                removeActiveTransfer(metadata.transferId)
                cleanupStreamingArtifacts(for: metadata.transferId)
            }
            throw error
        }
    }
    
 // MARK: - 私有传输方法
    
 /// 执行文件传输
    private func performFileTransfer(_ session: FileTransferSession, connection: P2PConnection) async throws {
 // 创建文件元数据
        let merkleStart = Date()
        let merkle = try? computeMerkleRoot(for: session.localURL, chunkSize: configuration.chunkSize)
        let merkleElapsedMs = Date().timeIntervalSince(merkleStart) * 1000
        NotificationCenter.default.post(name: .fileMerkleTiming, object: nil, userInfo: [
            "phase": "compute",
            "fileName": session.localURL.lastPathComponent,
            "fileSize": session.fileSize,
            "chunkSize": configuration.chunkSize,
            "elapsedMs": merkleElapsedMs,
            "metalAvailable": self.metalAvailable
        ])
        let checksum = try await calculateFileChecksum(session.localURL)
        let signerPeerId = securityManager.getDeviceId()
        let pqcAlgo = await MainActor.run {
            SettingsManager.normalizedPQCSignatureAlgorithm(SettingsManager.shared.pqcSignatureAlgorithm)
        }
        let signature = try await pqCrypto.signPQCRequired(Data(checksum.utf8), for: signerPeerId)
        let metadata = FileTransferMetadata(
            transferId: session.id,
            fileName: session.localURL.lastPathComponent,
            fileSize: session.fileSize,
            checksum: checksum,
            merkleRoot: merkle,
            hashAlgorithm: "SHA256",
            compressionEnabled: session.configuration.compressionEnabled,
            encryptionEnabled: session.configuration.encryptionEnabled,
            chunkSize: configuration.chunkSize,
            fileSignature: signature,
            signatureAlgorithm: pqcAlgo,
            signerPeerId: signerPeerId
        )
        
 // 发送文件元数据
        try await sendFileMetadata(metadata, to: connection)
        
 // 等待传输确认
        try await waitForTransferAcknowledgment(from: connection)
        
 // 若启用加密且文件较大，先进行流式加密到临时文件
        if session.configuration.encryptionEnabled && session.fileSize > 32 * 1024 * 1024 { // >32MB
            do {
                let (tempURL, aead) = try await prepareStreamingEncryptedFile(for: session)
                streamingEncryptedFiles[session.id] = (tempURL, aead)
                logger.info("🔒 已对大文件执行流式预加密: \(session.fileName)")
            } catch {
                logger.error("❌ 流式预加密失败，回退到块内加密: \(error.localizedDescription)")
            }
        }

 // 分块发送文件
        try await sendFileInChunks(session, connection: connection)
        
 // 等待传输完成确认
        try await waitForTransferComplete(from: connection)
    }
    
 /// 执行文件接收
    private func performFileReceive(_ session: FileTransferSession, connection: P2PConnection, metadata: FileTransferMetadata) async throws {
 // 创建目标文件
        try createDestinationFile(at: session.localURL)
        
 // 分块接收文件（若为大文件加密流，先写入临时密文文件，结束后再流式解密到最终目标）
        try await receiveFileInChunks(session, connection: connection, metadata: metadata)

 // 流式解密（接收端）：如果之前采用临时密文路径，现将其解密到目标文件
        if metadata.encryptionEnabled, metadata.fileSize > 32 * 1024 * 1024, let encURL = streamingEncryptedRecvFiles[session.id] {
            let key = try await deriveSessionKey(for: session.remoteDeviceId)
            guard let inStream = InputStream(url: encURL),
                  let outStream = OutputStream(url: session.localURL, append: false) else {
                throw FileTransferEngineError.encryptionError(underlying: nil)
            }
            let decryptor = PerformanceOptimizations.StreamingDecryptor(key: key, chunkSize: configuration.bufferSize)
            try await decryptor.decryptStream(from: inStream, to: outStream)
 // 清理临时密文
            try? FileManager.default.removeItem(at: encURL)
            streamingEncryptedRecvFiles.removeValue(forKey: session.id)
        }
        
 // 验证文件完整性
        let receivedChecksum = try await calculateFileChecksum(session.localURL)
        guard receivedChecksum == metadata.checksum else {
            throw FileTransferEngineError.checksumMismatch
        }
 // 校验整文件签名；strict PQC 下缺签名、缺 signer 或算法不明都必须失败关闭。
        guard let sig = metadata.fileSignature,
              let signerId = metadata.signerPeerId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !signerId.isEmpty else {
            NotificationCenter.default.post(name: Notification.Name("fileSignatureVerified"), object: nil, userInfo: [
                "transferId": session.id,
                "ok": false,
                "error": "missing_strict_pqc_signature"
            ])
            throw FileTransferEngineError.checksumMismatch
        }

        do {
            let ok = try await pqCrypto.verifyPQCRequired(
                Data(receivedChecksum.utf8),
                signature: sig,
                for: signerId,
                algorithm: metadata.signatureAlgorithm
            )
            NotificationCenter.default.post(name: Notification.Name("fileSignatureVerified"), object: nil, userInfo: [
                "transferId": session.id,
                "signerId": signerId,
                "algorithm": metadata.signatureAlgorithm ?? "",
                "ok": ok
            ])
            if !ok { throw FileTransferEngineError.checksumMismatch }
        } catch {
            NotificationCenter.default.post(name: Notification.Name("fileSignatureVerified"), object: nil, userInfo: [
                "transferId": session.id,
                "signerId": signerId,
                "algorithm": metadata.signatureAlgorithm ?? "",
                "ok": false,
                "error": String(describing: error)
            ])
            throw FileTransferEngineError.checksumMismatch
        }
 // 可选：Merkle 根校验
        if let merkleRoot = metadata.merkleRoot {
            let merkleStart2 = Date()
            let localMerkle = try? computeMerkleRoot(for: session.localURL, chunkSize: metadata.chunkSize)
            let verifyElapsedMs = Date().timeIntervalSince(merkleStart2) * 1000
            NotificationCenter.default.post(name: .fileMerkleTiming,
                                            object: nil,
                                            userInfo: [
                                                "phase": "verify",
                                                "fileName": session.fileName,
                                                "fileSize": session.fileSize,
                                                "chunkSize": metadata.chunkSize,
                                                "elapsedMs": verifyElapsedMs,
                                                "metalAvailable": self.metalAvailable
                                            ])
            if localMerkle != merkleRoot {
                NotificationCenter.default.post(name: .fileMerkleVerified,
                                                object: nil,
                                                userInfo: [
                                                    "transferId": session.id,
                                                    "ok": false,
                                                    "expected": merkleRoot,
                                                    "actual": localMerkle ?? "",
                                                    "fileName": session.fileName
                                                ])
                throw FileTransferEngineError.checksumMismatch
            } else {
                NotificationCenter.default.post(name: .fileMerkleVerified,
                                                object: nil,
                                                userInfo: [
                                                    "transferId": session.id,
                                                    "ok": true,
                                                    "expected": merkleRoot,
                                                    "actual": localMerkle ?? merkleRoot,
                                                    "fileName": session.fileName
                                                ])
            }
        }
        
 // 发送最终确认（携带整文件 HMAC 标记，便于与签名对比调试）
        var hmacTag: Data? = nil
        if metadata.encryptionEnabled, metadata.fileSize > 32 * 1024 * 1024, let encURL = streamingEncryptedRecvFiles[session.id] {
            let key = try await deriveSessionKey(for: session.remoteDeviceId)
            hmacTag = try computeFileHMACTag(url: encURL, key: key, chunkSize: metadata.chunkSize)
        }
        try await sendFinalAcknowledgment(to: connection, transferId: session.id, hmacTag: hmacTag)
    }
    
 /// 分块发送文件
    private func sendFileInChunks(_ session: FileTransferSession, connection: P2PConnection) async throws {
 // 若存在流式预加密临时文件，从该文件读取；wire chunk 本身不再声明 per-chunk AEAD。
        let readingURL = streamingEncryptedFiles[session.id]?.url ?? session.localURL
        let fileHandle = try FileHandle(forReadingFrom: readingURL)
        defer { fileHandle.closeFile() }
        
        let totalChunks = Int((session.fileSize + Int64(configuration.chunkSize) - 1) / Int64(configuration.chunkSize))
        var chunkIndex = 0
        
        while chunkIndex < totalChunks {
            if session.state == .cancelled { throw FileTransferEngineError.transferCancelled }
 // 批处理窗口，提升加密/压缩并发
            let window = max(1, threadsPerTransfer())
            var batch: [(idx: Int, raw: Data)] = []
            batch.reserveCapacity(window)
            var readCount = 0
            while readCount < window && chunkIndex + readCount < totalChunks {
                let raw = fileHandle.readData(ofLength: configuration.chunkSize)
                if raw.isEmpty { break }
                batch.append((idx: chunkIndex + readCount, raw: raw))
                readCount += 1
            }
            if batch.isEmpty { break }
 // 预先读取Actor隔离状态（避免在并发闭包内直接访问）
            let compressionOn = session.configuration.compressionEnabled
            let encryptionOn = session.configuration.encryptionEnabled
            let hasPreEncrypted = (self.streamingEncryptedFiles[session.id] != nil)

 // 并发处理批次中的数据块（P2：利用并行管理器加速加密）
            let processed: [(idx: Int, data: Data, aead: EncryptedData?, isCompressed: Bool, isEncrypted: Bool)] = try await {
 // 1) 先处理压缩（保持顺序映射）。流式预加密文件已经是密文，不能再压缩。
                var plainChunks: [(idx: Int, data: Data, isCompressed: Bool)] = []
                plainChunks.reserveCapacity(batch.count)
                if hasPreEncrypted {
                    plainChunks = batch.map { ($0.idx, $0.raw, false) }
                } else if compressionOn {
                    for item in batch {
                        let payload = try Self.compressDataIfBeneficial(item.raw)
                        plainChunks.append((idx: item.idx, data: payload.data, isCompressed: payload.isCompressed))
                    }
                } else {
                    plainChunks = batch.map { ($0.idx, $0.raw, false) }
                }

 // 2) 加密分支：使用并行加密；否则按原逻辑处理（含预加密路径）
                if encryptionOn && !hasPreEncrypted {
                    let key = try await deriveSessionKey(for: session.remoteDeviceId)
                    let keys = Array(repeating: key, count: plainChunks.count)
 // 避免捕获 MainActor 隔离的 self 成员，使用局部实例
                    let pem = PerformanceOptimizations.ParallelEncryptionManager()
                    let encrypted = try await pem.encryptInParallel(
                        chunks: plainChunks.map { $0.data },
                        using: keys,
                        maxConcurrency: threadsPerTransfer()
                    )
 // 组装结果（保持索引顺序）
                    return zip(plainChunks, encrypted).map { (p, e) in
                        (idx: p.idx, data: e.ciphertext, aead: e, isCompressed: p.isCompressed, isEncrypted: true)
                    }
                        .sorted { $0.0 < $1.0 }
                } else {
 // 无加密或已预加密：直接发送明文/流式密文，wire flags 必须反映每个 chunk 的实际编码。
                    return plainChunks.map {
                        (idx: $0.idx, data: $0.data, aead: nil, isCompressed: $0.isCompressed, isEncrypted: false)
                    }
                    .sorted { $0.idx < $1.idx }
                }
            }()
 // 顺序发送并等待确认
            for (idx, dataOut, aead, isCompressed, isEncrypted) in processed {
                let packet = FileChunkPacket(
                    transferId: session.id,
                    chunkIndex: idx,
                    totalChunks: totalChunks,
                    data: dataOut,
                    aeadNonce: aead?.nonce,
                    aeadTag: aead?.tag,
                    isCompressed: isCompressed,
                    isEncrypted: isEncrypted,
                    checksum: calculateChecksum(dataOut)
                )
                try await sendChunkPacket(packet, to: connection)
                try await waitForChunkAcknowledgment(session.id, chunkIndex: idx, from: connection)
                let sentRaw = batch.first(where: { $0.idx == idx })?.raw.count ?? dataOut.count
                session.updateBytesTransferred(Int64(sentRaw))
            }
            chunkIndex += processed.count
            let progress = Double(chunkIndex) / Double(totalChunks)
            await updateProgress(for: session.id, progress: progress)
        }
    }
    
 /// 分块接收文件
    private func receiveFileInChunks(_ session: FileTransferSession, connection: P2PConnection, metadata: FileTransferMetadata) async throws {
 // 若是大文件加密流，则写入到临时密文文件
        let writingURL: URL
        if metadata.encryptionEnabled, metadata.fileSize > 32 * 1024 * 1024 {
            let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ft_recv_enc_\(session.id).bin")
            if FileManager.default.fileExists(atPath: tempURL.path) {
                try? FileManager.default.removeItem(at: tempURL)
            }
            FileManager.default.createFile(atPath: tempURL.path, contents: nil)
            streamingEncryptedRecvFiles[session.id] = tempURL
            writingURL = tempURL
        } else {
            writingURL = session.localURL
        }

        let fileHandle = try FileHandle(forWritingTo: writingURL)
        defer { fileHandle.closeFile() }
        
 // 分解复杂表达式以避免类型检查问题
        let chunkSizeInt64 = Int64(metadata.chunkSize)
        let totalChunks = Int((metadata.fileSize + chunkSizeInt64 - 1) / chunkSizeInt64)
        var receivedChunks = 0
        
        while receivedChunks < totalChunks {
 // 检查传输状态
            if session.state == .cancelled {
                throw FileTransferEngineError.transferCancelled
            }
            
 // 接收数据包
            let packet = try await receiveChunkPacket(from: connection)
            
 // 验证数据包
            guard packet.transferId == session.id else {
                throw FileTransferEngineError.networkError(underlying: nil)
            }
            
 // 验证校验和
            let calculatedChecksum = calculateChecksum(packet.data)
            guard calculatedChecksum == packet.checksum else {
                throw FileTransferEngineError.checksumMismatch
            }
            
 // 处理数据块（解密/解压）
            let processedData: Data
            if metadata.encryptionEnabled, metadata.fileSize > 32 * 1024 * 1024 {
 // 大文件加密流：包内数据已是密文，直接写入，解密在完成后统一进行
                guard !packet.isEncrypted, packet.aeadNonce == nil, packet.aeadTag == nil else {
                    throw FileTransferEngineError.encryptionError(underlying: nil)
                }
                guard !packet.isCompressed else {
                    throw FileTransferEngineError.compressionError(underlying: nil)
                }
                processedData = packet.data
            } else {
                var payload = packet.data
                if packet.isEncrypted {
 // 分块AEAD校验与解密
                    do {
                        guard let nonce = packet.aeadNonce, let tag = packet.aeadTag else {
                            throw FileTransferEngineError.encryptionError(underlying: nil)
                        }
                        let enc = EncryptedData(ciphertext: payload, nonce: nonce, tag: tag)
                        payload = try await decryptDataDetailed(enc, fromPeer: session.remoteDeviceId)
                        NotificationCenter.default.post(name: .fileChunkVerified, object: nil, userInfo: [
                            "transferId": session.id,
                            "chunkIndex": packet.chunkIndex,
                            "ok": true
                        ])
                    } catch {
                        NotificationCenter.default.post(name: .fileChunkVerifyFailed, object: nil, userInfo: [
                            "transferId": session.id,
                            "chunkIndex": packet.chunkIndex,
                            "error": String(describing: error)
                        ])
                        throw error
                    }
                } else if metadata.encryptionEnabled {
                    throw FileTransferEngineError.encryptionError(underlying: nil)
                }
                if packet.isCompressed {
                    payload = try Self.decompressData(payload, maxOutputSize: metadata.chunkSize)
                }
                processedData = payload
            }
            
 // 写入文件
            fileHandle.write(processedData)
            
 // 发送块确认
            try await sendChunkAcknowledgment(session.id, chunkIndex: packet.chunkIndex, to: connection)
            
 // 更新进度
            receivedChunks += 1
            let progress = Double(receivedChunks) / Double(totalChunks)
            await updateProgress(for: session.id, progress: progress)
            
 // 更新传输字节数
            session.updateBytesTransferred(Int64(processedData.count))
        }
    }
    
 // MARK: - 辅助方法
    
 /// 获取默认下载目录
 /// - Returns: 下载目录 URL，如果无法获取则返回 nil
 /// - Note: 18.1 - 移除 force unwrap，返回 Optional 并发射 SecurityEvent
    private func getDefaultDownloadDirectory() -> URL {
        guard let downloadDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
 // 发射安全事件 (Requirements 8.1, 8.4)
            SecurityEventEmitter.emitDetached(SecurityEvent(
                type: .symlinkResolutionFailed,  // 复用现有类型，表示文件系统访问失败
                severity: .warning,
                message: "无法获取默认下载目录",
                context: [
                    "reason": "FileManager.urls(for:in:) 返回空数组",
                    "searchPath": "downloadsDirectory",
                    "domain": "userDomainMask"
                ]
            ))
            logger.error("❌ 无法获取默认下载目录，回退到临时目录")
 // 回退到临时目录
            return FileManager.default.temporaryDirectory
        }
        return downloadDir
    }
    
 /// 创建目标文件
    private func createDestinationFile(at url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    
 /// 计算文件校验和
    private func calculateFileChecksum(_ url: URL) async throws -> String {
        return try await fileHashWorker.sha256Hex(url: url)
    }

 /// 计算文件的 Merkle 根（基于分块 SHA256），在可用时使用 Metal 进行哈希预处理
    private func computeMerkleRoot(for url: URL, chunkSize: Int) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { handle.closeFile() }
        var leafHashes: [Data] = []
        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            if let fast = metalAccel.acceleratedHashingIfAvailable(data: chunk) {
                leafHashes.append(fast)
            } else {
                let h = SHA256.hash(data: chunk)
                leafHashes.append(Data(h))
            }
        }
 // 空文件的根
        if leafHashes.isEmpty {
            if let fast = metalAccel.acceleratedHashingIfAvailable(data: Data()) {
                return fast.map { String(format: "%02x", $0) }.joined()
            }
            return SHA256.hash(data: Data()).compactMap { String(format: "%02x", $0) }.joined()
        }
        var level = leafHashes
        while level.count > 1 {
            var next: [Data] = []
            var i = 0
            while i < level.count {
                let left = level[i]
                let right = (i + 1 < level.count) ? level[i + 1] : left // 尾部补齐
                var combined = Data()
                combined.append(left)
                combined.append(right)
                if let fast = metalAccel.acceleratedHashingIfAvailable(data: combined) {
                    next.append(fast)
                } else {
                    next.append(Data(SHA256.hash(data: combined)))
                }
                i += 2
            }
            level = next
        }
        return level[0].map { String(format: "%02x", $0) }.joined()
    }
    
 // MARK: - 网络通信方法（完整实现 - 利用macOS 26.x Network Framework改进）
    
 /// 获取NWConnection（从P2PConnection提取）- 符合Swift 6.2.1的并发安全要求
    private func getNWConnection(from connection: P2PConnection) -> NWConnection {
 // P2PConnection包含一个NWConnection属性，直接访问
        return connection.connection
    }
    
 /// 发送文件元数据 - 利用macOS 26.x的改进网络性能
    private func sendFileMetadata(_ metadata: FileTransferMetadata, to connection: P2PConnection) async throws {
        let nwConnection = getNWConnection(from: connection)
        
        logger.info("📤 发送文件元数据: \(metadata.fileName)")
        
        do {
 // 编码元数据
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let metadataData = try encoder.encode(metadata)
            
 // 创建消息头（类型 + 长度）
            let messageType: UInt32 = 0x01 // METADATA
            var header = Data()
            header.append(contentsOf: withUnsafeBytes(of: messageType.bigEndian) { Array($0) })
            header.append(contentsOf: withUnsafeBytes(of: UInt32(metadataData.count).bigEndian) { Array($0) })
            
 // 发送消息头
            try await sendData(header, to: nwConnection)
            
 // 发送元数据（分块发送，利用macOS 26.x的大数据优化）
            let chunkSize = 64 * 1024 // 64KB chunks for large metadata
            var offset = 0
            while offset < metadataData.count {
                let remaining = metadataData.count - offset
                let currentChunkSize = min(chunkSize, remaining)
                let chunk = metadataData.subdata(in: offset..<(offset + currentChunkSize))
                try await sendData(chunk, to: nwConnection)
                offset += currentChunkSize
            }
            
            logger.info("✅ 文件元数据发送完成: \(metadata.fileName)")
        } catch {
            logger.error("❌ 发送文件元数据失败: \(error.localizedDescription)")
            throw error
        }
    }
    
 /// 接收文件元数据 - 利用macOS 26.x的改进网络性能
    private func receiveFileMetadata(from connection: P2PConnection) async throws -> FileTransferMetadata {
        let nwConnection = getNWConnection(from: connection)
        
        logger.info("📥 接收文件元数据")
        
        do {
 // 接收消息头（8字节：4字节类型 + 4字节长度）
            let headerData = try await receiveData(length: 8, from: nwConnection)
            
            guard headerData.count == 8 else {
                throw FileTransferEngineError.networkError(underlying: nil)
            }
            
            let messageType = headerData.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
            let dataLength = headerData.suffix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
            
            guard messageType == 0x01 else { // METADATA
                throw FileTransferEngineError.networkError(underlying: nil)
            }
            
 // 接收元数据（分块接收）
            var metadataData = Data()
            var received = 0
            let totalLength = Int(dataLength)
            
            while received < totalLength {
                let remaining = totalLength - received
                let chunkSize = min(64 * 1024, remaining) // 64KB chunks
                let chunk = try await receiveData(length: chunkSize, from: nwConnection)
                metadataData.append(chunk)
                received += chunk.count
            }
            
 // 解码元数据
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let metadata = try decoder.decode(FileTransferMetadata.self, from: metadataData)
            
            logger.info("✅ 文件元数据接收完成: \(metadata.fileName)")
            return metadata
        } catch {
            logger.error("❌ 接收文件元数据失败: \(error.localizedDescription)")
            throw error
        }
    }
    
 /// 等待传输确认
    private func waitForTransferAcknowledgment(from connection: P2PConnection) async throws {
        let nwConnection = getNWConnection(from: connection)
        
        logger.debug("⏳ 等待传输确认")
        
 // 接收确认消息（1字节：0x01 = ACK, 0x00 = NAK）
        let ackData = try await receiveData(length: 1, from: nwConnection)
        
        guard ackData.count == 1, ackData[0] == 0x01 else {
            logger.error("❌ 传输被拒绝")
            throw FileTransferEngineError.transferRejected
        }
        
        logger.debug("✅ 传输确认已收到")
    }
    
 /// 发送传输确认
    private func sendTransferAcknowledgment(to connection: P2PConnection) async throws {
        let nwConnection = getNWConnection(from: connection)
        
        logger.debug("📤 发送传输确认")
        
 // 发送确认消息（1字节：0x01 = ACK）
        let ackData = Data([0x01])
        try await sendData(ackData, to: nwConnection)
    }
    
 /// 接收数据包 - 完整实现
    private func receiveChunkPacket(from connection: P2PConnection) async throws -> FileChunkPacket {
        let nwConnection = getNWConnection(from: connection)
        
 // 接收数据包头（固定大小）
 // 结构：transferId(36字节UUID字符串) + chunkIndex(4字节) + totalChunks(4字节) +
 // dataLength(8字节) + checksum(64字节SHA256) + flags(1字节) + timestamp(8字节) = 125字节
        let headerSize = 36 + 4 + 4 + 8 + 64 + 1 + 8
        let headerData = try await receiveData(length: headerSize, from: nwConnection)
        
        var offset = 0
        
 // 解析transferId (UUID字符串，36字节)
        let transferIdData = headerData.subdata(in: offset..<(offset + 36))
        guard let transferId = String(data: transferIdData, encoding: .utf8) else {
            throw FileTransferEngineError.networkError(underlying: nil)
        }
        offset += 36
        
 // 解析chunkIndex (4字节)
        let chunkIndex = headerData.subdata(in: offset..<(offset + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        offset += 4
        
 // 解析totalChunks (4字节)
        let totalChunks = headerData.subdata(in: offset..<(offset + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        offset += 4
        
 // 解析dataLength (8字节)
        let dataLength = headerData.subdata(in: offset..<(offset + 8)).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).bigEndian }
        offset += 8
        
 // 解析checksum (64字节，SHA256 hex字符串)
        let checksumData = headerData.subdata(in: offset..<(offset + 64))
        guard let checksum = String(data: checksumData, encoding: .utf8) else {
            throw FileTransferEngineError.networkError(underlying: nil)
        }
        offset += 64
        
 // 解析flags (1字节)
        let flags = headerData[offset]
        let isCompressed = (flags & 0x01) != 0
        let isEncrypted = (flags & 0x02) != 0
        offset += 1
        
 // 解析timestamp (8字节) - 符合Swift 6.2.1最佳实践：未使用的值使用 _ 忽略
        let _ = headerData.subdata(in: offset..<(offset + 8)).withUnsafeBytes { $0.loadUnaligned(as: TimeInterval.self) }
        
 // 接收数据块
        let dataLengthInt = Int(dataLength)
        var chunkData = Data()
        var received = 0
        
        while received < dataLengthInt {
            let remaining = dataLengthInt - received
            let chunkSize = min(64 * 1024, remaining) // 64KB chunks
            let chunk = try await receiveData(length: chunkSize, from: nwConnection)
            chunkData.append(chunk)
            received += chunk.count
        }
        
 // 接收AEAD信息（如果加密）
        var aeadNonce: Data? = nil
        var aeadTag: Data? = nil
        if isEncrypted {
 // Nonce: 12字节, Tag: 16字节
            aeadNonce = try await receiveData(length: 12, from: nwConnection)
            aeadTag = try await receiveData(length: 16, from: nwConnection)
        }
        
        return FileChunkPacket(
            transferId: transferId,
            chunkIndex: Int(chunkIndex),
            totalChunks: Int(totalChunks),
            data: chunkData,
            aeadNonce: aeadNonce,
            aeadTag: aeadTag,
            isCompressed: isCompressed,
            isEncrypted: isEncrypted,
            checksum: checksum.trimmingCharacters(in: .whitespaces)
        )
    }
    
 /// 发送块确认
    private func sendChunkAcknowledgment(_ transferId: String, chunkIndex: Int, to connection: P2PConnection) async throws {
        let nwConnection = getNWConnection(from: connection)
        
 // 发送确认消息：transferId(36字节) + chunkIndex(4字节) + status(1字节: 0x01=ACK)
        var ackData = Data()
        
 // transferId (36字节，固定长度)
        var transferIdBytes = transferId.data(using: .utf8) ?? Data()
        transferIdBytes.resize(to: 36, padding: 0)
        ackData.append(transferIdBytes)
        
 // chunkIndex (4字节)
        ackData.append(contentsOf: withUnsafeBytes(of: UInt32(chunkIndex).bigEndian) { Array($0) })
        
 // status (1字节: 0x01 = ACK)
        ackData.append(0x01)
        
        try await sendData(ackData, to: nwConnection)
    }
    
 /// 等待块确认 - 完整实现
    private func waitForChunkAcknowledgment(_ transferId: String, chunkIndex: Int, from connection: P2PConnection) async throws {
        let nwConnection = getNWConnection(from: connection)
        
 // 接收确认消息（41字节：transferId 36字节 + chunkIndex 4字节 + status 1字节）
        let ackData = try await receiveData(length: 41, from: nwConnection)
        
 // 验证transferId
        let receivedTransferId = String(data: ackData.prefix(36), encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""
        guard receivedTransferId == transferId else {
            throw FileTransferEngineError.networkError(underlying: nil)
        }
        
 // 验证chunkIndex
        let receivedChunkIndex = ackData.subdata(in: 36..<40).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        guard Int(receivedChunkIndex) == chunkIndex else {
            throw FileTransferEngineError.networkError(underlying: nil)
        }
        
 // 检查状态
        let status = ackData[40]
            guard status == 0x01 else { // ACK
            logger.error("❌ 块确认失败: chunkIndex=\(chunkIndex)")
            throw FileTransferEngineError.networkError(underlying: nil)
        }
    }
    
 /// 等待传输完成
    private func waitForTransferComplete(from connection: P2PConnection) async throws {
        let nwConnection = getNWConnection(from: connection)
        
        logger.debug("⏳ 等待传输完成确认")
        
 // 接收完成消息（扩展格式：0x02 | transferId(36) | tagLen(2) | tag）
        let code = try await receiveData(length: 1, from: nwConnection)
        guard code.count == 1, code[0] == 0x02 else { throw FileTransferEngineError.networkError(underlying: nil) }
 // 尝试读取扩展信息（若旧版本未发送则读取会失败，容错）
        do {
            let extHeader = try await receiveData(length: 38, from: nwConnection)
            let tid = String(data: extHeader.prefix(36), encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""
            let tagLen = extHeader.suffix(2).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self).bigEndian }
            var tag = Data()
            if tagLen > 0 { tag = try await receiveData(length: Int(tagLen), from: nwConnection) }
            let hex = hexString(tag)
            logger.info("📎 完成确认包含 HMAC 标记: transferId=\(tid), tagLen=\(tag.count), tagHex=\(hex)")
            NotificationCenter.default.post(name: Notification.Name("fileHmacTagReported"), object: nil, userInfo: [
                "transferId": tid,
                "hmacTagHex": hex
            ])
        } catch {
            logger.debug("ℹ️ 完成确认不包含扩展 HMAC 标记（兼容旧版本）")
        }
        logger.debug("✅ 传输完成确认已收到")
    }
    
 /// 发送最终确认
    private func sendFinalAcknowledgment(to connection: P2PConnection, transferId: String, hmacTag: Data?) async throws {
        let nwConnection = getNWConnection(from: connection)
        
        logger.debug("📤 发送最终确认")
        
 // 扩展完成消息：0x02 | transferId(36) | tagLen(2) | tag
        var payload = Data([0x02])
        var tidBytes = transferId.data(using: .utf8) ?? Data()
        tidBytes.resize(to: 36, padding: 0)
        payload.append(tidBytes)
        let tagLen = UInt16(hmacTag?.count ?? 0).bigEndian
        payload.append(contentsOf: withUnsafeBytes(of: tagLen) { Array($0) })
        if let tag = hmacTag { payload.append(tag) }
        try await sendData(payload, to: nwConnection)
    }
    
 /// 等待最终确认
    private func waitForFinalAcknowledgment(from connection: P2PConnection) async throws {
        let nwConnection = getNWConnection(from: connection)
        
        logger.debug("⏳ 等待最终确认")
        
 // 接收最终确认（1字节：0x03 = FINAL_ACK）
        let finalAckData = try await receiveData(length: 1, from: nwConnection)
        
        guard finalAckData.count == 1, finalAckData[0] == 0x03 else {
            throw FileTransferEngineError.networkError(underlying: nil)
        }
        
        logger.debug("✅ 最终确认已收到")
    }
    
 /// 发送数据包 - 完整实现，利用macOS 26.x的大数据优化
    private func sendChunkPacket(_ packet: FileChunkPacket, to connection: P2PConnection) async throws {
        let nwConnection = getNWConnection(from: connection)
        
 // 构建数据包头
        var header = Data()
        
 // transferId (36字节，固定长度)
        var transferIdBytes = packet.transferId.data(using: .utf8) ?? Data()
        transferIdBytes.resize(to: 36, padding: 0)
        header.append(transferIdBytes)
        
 // chunkIndex (4字节)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(packet.chunkIndex).bigEndian) { Array($0) })
        
 // totalChunks (4字节)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(packet.totalChunks).bigEndian) { Array($0) })
        
 // dataLength (8字节)
        header.append(contentsOf: withUnsafeBytes(of: UInt64(packet.data.count).bigEndian) { Array($0) })
        
 // checksum (64字节，SHA256 hex字符串，固定长度)
        var checksumBytes = packet.checksum.data(using: .utf8) ?? Data()
        checksumBytes.resize(to: 64, padding: 0x20) // 用空格填充
        header.append(checksumBytes)
        
 // flags (1字节)
        var flags: UInt8 = 0
        if packet.isCompressed { flags |= 0x01 }
        if packet.isEncrypted { flags |= 0x02 }
        header.append(flags)
        
 // timestamp (8字节)
        header.append(contentsOf: withUnsafeBytes(of: packet.timestamp.timeIntervalSince1970) { Array($0) })
        
 // 发送消息头
        try await sendData(header, to: nwConnection)
        
 // 分块发送数据（利用macOS 26.x的大数据优化 + 速度限制）
        let chunkSize = 64 * 1024 // 64KB chunks
        var offset = 0
        while offset < packet.data.count {
            let remaining = packet.data.count - offset
            let currentChunkSize = min(chunkSize, remaining)
            let chunk = packet.data.subdata(in: offset..<(offset + currentChunkSize))
            
 // 应用速度限制（如果启用）- 符合Swift 6.2.1的MainActor使用规范
            let limiter = await MainActor.run { speedLimiter }
            if let limiter = limiter {
                await limiter.waitIfNeeded(for: chunk.count)
            }
            
            try await sendData(chunk, to: nwConnection)
            offset += currentChunkSize
        }
        
 // 如果加密，发送AEAD信息
        if packet.isEncrypted {
            if let nonce = packet.aeadNonce {
                try await sendData(nonce, to: nwConnection)
            }
            if let tag = packet.aeadTag {
                try await sendData(tag, to: nwConnection)
            }
        }
    }
    
 // MARK: - 底层网络辅助方法（利用macOS 26.x Network Framework改进）
    
 /// 发送数据到NWConnection - 利用macOS 26.x的性能优化
    private func sendData(_ data: Data, to connection: NWConnection) async throws {
        return try await withCheckedThrowingContinuation { continuation in
 // macOS 26.x改进了NWConnection的send性能，特别是大数据传输
            connection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
    
 /// 从NWConnection接收数据 - 利用macOS 26.x的性能优化
    private func receiveData(length: Int, from connection: NWConnection) async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
 // macOS 26.x改进了NWConnection的receive性能
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { data, _, isComplete, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data, data.count == length {
                    continuation.resume(returning: data)
                } else if let data = data, data.count < length {
 // 部分数据，继续接收
                    Task {
                        do {
                            var fullData = data
                            var received = data.count
                            while received < length {
                                let remaining = length - received
                                let chunk = try await self.receiveData(length: remaining, from: connection)
                                fullData.append(chunk)
                                received += chunk.count
                            }
                            continuation.resume(returning: fullData)
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                } else {
                    continuation.resume(throwing: FileTransferEngineError.networkError(underlying: nil))
                }
            }
        }
    }
    
 /// 计算校验和
    private func calculateChecksum(_ data: Data) -> String {
        return SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }
    
    private struct ChunkCompressionResult: Sendable {
        let data: Data
        let isCompressed: Bool
    }

 /// 压缩数据 - 利用macOS 26.x的Compression framework改进
    nonisolated private static func compressDataIfBeneficial(_ data: Data) throws -> ChunkCompressionResult {
        guard !data.isEmpty else {
            return ChunkCompressionResult(data: data, isCompressed: false)
        }
        guard data.count > 128 else {
            return ChunkCompressionResult(data: data, isCompressed: false)
        }
        
 // macOS 26.x改进了Compression framework的性能，特别是lzfse算法
 // 使用lzfse算法，在macOS 26.x上性能提升约30%
        let algorithm: Compression.Algorithm = .lzfse
        
        let bufferSize = data.count + (data.count / 8) + 16 // 预留额外空间
        var compressedData = Data(count: bufferSize)
        
        let compressedSize = data.withUnsafeBytes { inputBuffer in
            compressedData.withUnsafeMutableBytes { outputBuffer in
                guard let outputBase = outputBuffer.bindMemory(to: UInt8.self).baseAddress,
                      let inputBase = inputBuffer.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }
                return compression_encode_buffer(
                    outputBase,
                    outputBuffer.count,
                    inputBase,
                    inputBuffer.count,
                    nil,
                    algorithm.rawValue
                )
            }
        }
        
        guard compressedSize > 0 else {
            throw FileTransferEngineError.compressionError(underlying: nil)
        }
    
 // 如果压缩后数据更大，返回原始数据
        if compressedSize >= data.count {
            return ChunkCompressionResult(data: data, isCompressed: false)
        }
        
        compressedData.count = compressedSize
        
        return ChunkCompressionResult(data: compressedData, isCompressed: true)
    }
    
 /// 解压数据 - 利用macOS 26.x的Compression framework改进
    nonisolated private static func decompressData(_ data: Data, maxOutputSize: Int) throws -> Data {
        guard !data.isEmpty else { return data }
        guard maxOutputSize > 0 else {
            throw FileTransferEngineError.compressionError(underlying: nil)
        }
        
 // 尝试检测压缩算法（简化实现，假设使用lzfse）
 // macOS 26.x改进了多算法检测性能
        let algorithm: Compression.Algorithm = .lzfse
        
        var capacity = min(max(max(data.count * 4, 1), 4 * 1024), maxOutputSize)
        while true {
            var decompressedData = Data(count: capacity)
            let result = data.withUnsafeBytes { inputBuffer in
                decompressedData.withUnsafeMutableBytes { outputBuffer in
                    guard let outputBase = outputBuffer.bindMemory(to: UInt8.self).baseAddress,
                          let inputBase = inputBuffer.bindMemory(to: UInt8.self).baseAddress else {
                        return 0
                    }
                    return compression_decode_buffer(
                        outputBase,
                        outputBuffer.count,
                        inputBase,
                        inputBuffer.count,
                        nil,
                        algorithm.rawValue
                    )
                }
            }
            
            if result > 0 {
                decompressedData.count = result
                return decompressedData
            }

            guard capacity < maxOutputSize else {
                throw FileTransferEngineError.compressionError(underlying: nil)
            }
            capacity = min(capacity * 2, maxOutputSize)
        }
    }
    
 /// 获取或创建对等方的主密钥（持久化在Keychain）
    private func getOrCreateMasterKey(for peerId: String) async throws -> SymmetricKey {
        let keychainKey = "ft-master-\(peerId)"
        if let storedData = try? quantumKeyManager.retrieveKeyFromKeychain(identifier: keychainKey) {
            return SymmetricKey(data: storedData)
        }
        let newKey = try await quantumKeyManager.generateQuantumKey()
        let keyData = newKey.withUnsafeBytes { Data($0) }
        try quantumKeyManager.storeKeyInKeychain(keyData, identifier: keychainKey)
        return newKey
    }

 /// 基于主密钥派生会话密钥（HKDF）
    private func deriveSessionKey(for peerId: String) async throws -> SymmetricKey {
        let master = try await getOrCreateMasterKey(for: peerId)
        let sessionId = "file-transfer-\(peerId)"
 // 轮换策略：若建议轮换则派生并记录新密钥
        if rotationManager.shouldRotateKey(for: sessionId) || rotationManager.getCurrentKey(for: sessionId) == nil {
            let newKey = try rotationManager.rotateKey(for: sessionId, masterKey: master, salt: Data())
            return newKey
        }
        if let current = rotationManager.getCurrentKey(for: sessionId) {
            rotationManager.recordKeyUsage(for: sessionId)
            return current
        } else {
            let derived = try CryptoKitEnhancements.deriveSessionKey(for: sessionId, from: master, salt: Data())
 // 通过rotateKey来登记，该方法内部也会登记并重置计数
            _ = try rotationManager.rotateKey(for: sessionId, masterKey: master, salt: Data())
            return derived
        }
    }

 /// 组合密文格式：nonce(12) | ciphertext | tag(16)
    private func combineEncryptedData(_ enc: EncryptedData) -> Data {
        var out = Data()
        out.append(enc.nonce)
        out.append(enc.ciphertext)
        out.append(enc.tag)
        return out
    }

 /// 拆分组合密文
    private func splitEncryptedData(_ data: Data) throws -> EncryptedData {
 // AES.GCM 标准 nonce 12 字节，tag 16 字节
        guard data.count >= 12 + 16 else { throw FileTransferEngineError.encryptionError(underlying: nil) }
        let nonce = data.prefix(12)
        let tag = data.suffix(16)
        let ciphertext = data.dropFirst(12).dropLast(16)
        return EncryptedData(ciphertext: Data(ciphertext), nonce: Data(nonce), tag: Data(tag))
    }

 /// 加密数据（使用派生的会话密钥）
    private func encryptData(_ data: Data, forPeer peerId: String) async throws -> Data {
        let sessionKey = try await deriveSessionKey(for: peerId)
        let base64 = data.base64EncodedString()
        let enc = try await pqCrypto.encrypt(base64, using: sessionKey)
        return enc.combined
    }
    
 /// 加密数据（详细版，返回AEAD字段）
    private func encryptDataDetailed(_ data: Data, forPeer peerId: String) async throws -> EncryptedData {
        let sessionKey = try await deriveSessionKey(for: peerId)
        let base64 = data.base64EncodedString()
        return try await pqCrypto.encrypt(base64, using: sessionKey)
    }
    
 /// 解密数据（使用派生的会话密钥）
    private func decryptData(_ data: Data, fromPeer peerId: String) async throws -> Data {
        let enc = try EncryptedData.from(combined: data)
        let sessionKey = try await deriveSessionKey(for: peerId)
        let base64 = try await pqCrypto.decrypt(enc, using: sessionKey)
        guard let decoded = Data(base64Encoded: base64) else { throw FileTransferEngineError.encryptionError(underlying: nil) }
        return decoded
    }
    
 /// 解密数据（详细版，使用AEAD字段）
    private func decryptDataDetailed(_ enc: EncryptedData, fromPeer peerId: String) async throws -> Data {
        let sessionKey = try await deriveSessionKey(for: peerId)
        let base64 = try await pqCrypto.decrypt(enc, using: sessionKey)
        guard let decoded = Data(base64Encoded: base64) else { throw FileTransferEngineError.encryptionError(underlying: nil) }
        return decoded
    }

 // MARK: - 流式预加密（针对大文件）
    private func prepareStreamingEncryptedFile(for session: FileTransferSession) async throws -> (URL, EncryptedData) {
        let key = try await deriveSessionKey(for: session.remoteDeviceId)
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        let tempURL = tempDir.appendingPathComponent("ft_enc_\(session.id).bin")
        if FileManager.default.fileExists(atPath: tempURL.path) {
            try? FileManager.default.removeItem(at: tempURL)
        }
        guard let inStream = InputStream(url: session.localURL),
              let outStream = OutputStream(url: tempURL, append: false) else {
            throw FileTransferEngineError.encryptionError(underlying: nil)
        }
        let streamer = PerformanceOptimizations.StreamingEncryptor(key: key, chunkSize: configuration.bufferSize)
        try await streamer.encryptStream(from: inStream, to: outStream)
 // 生成整文件级 HMAC-SHA256 标记，作为汇总 AEAD tag（ciphertext/nonce为空）
        let finalTag = try computeFileHMACTag(url: tempURL, key: key, chunkSize: configuration.bufferSize)
        let aead = EncryptedData(ciphertext: Data(), nonce: Data(), tag: finalTag)
        return (tempURL, aead)
    }

 /// 计算整文件 HMAC-SHA256（用于流式加密的汇总标记）
    private func computeFileHMACTag(url: URL, key: SymmetricKey, chunkSize: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { handle.closeFile() }
        var hmac = HMAC<SHA256>.init(key: key)
        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            hmac.update(data: chunk)
        }
        let mac = hmac.finalize()
        return Data(mac)
    }

 /// 将二进制数据转换为十六进制字符串（调试用）
    private func hexString(_ data: Data) -> String {
        return data.map { String(format: "%02x", $0) }.joined()
    }
    
 /// 更新传输进度
    private func updateProgress(for transferId: String, progress: Double) async {
        await MainActor.run {
            if let session = activeTransfers[transferId] {
                session.progress = progress
            }
            updateTotalProgress()
        }
    }
    
 /// 更新总进度
    private func updateTotalProgress() {
        let totalSessions = activeTransfers.count
        if totalSessions == 0 {
            totalProgress = 0.0
        } else {
            let totalProgressSum = activeTransfers.values.reduce(0.0) { $0 + $1.progress }
            totalProgress = totalProgressSum / Double(totalSessions)
        }
    }
    
 /// 设置速度监控
    private func setupSpeedMonitoring() {
        speedCalculationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            Task { @MainActor in
                self.calculateTransferSpeed()
            }
        }
    }
    
 /// 计算传输速度
    private func calculateTransferSpeed() {
        let totalBytes = activeTransfers.values.reduce(0) { $0 + Int64($1.progress * Double($1.fileSize)) }
        let bytesPerSecond = totalBytes - lastBytesTransferred
        transferSpeed = Double(bytesPerSecond)
        lastBytesTransferred = totalBytes
    }

 /// 清理单次传输产生的流式临时密文（发送端预加密文件 / 接收端临时密文文件）
 /// 在每个传输的终止点调用，避免大文件加密传输在临时目录中永久泄漏密文副本。
    private func cleanupStreamingArtifacts(for transferId: String) {
        if let info = streamingEncryptedFiles.removeValue(forKey: transferId) {
            try? FileManager.default.removeItem(at: info.url)
        }
        if let recvURL = streamingEncryptedRecvFiles.removeValue(forKey: transferId) {
            try? FileManager.default.removeItem(at: recvURL)
        }
    }
    
 /// 添加到历史记录
    private func addToHistory(_ session: FileTransferSession) {
        guard keepTransferHistory else { return }
        let record = FileTransferRecord(
            id: session.id,
            fileName: session.fileName,
            fileSize: session.fileSize,
            type: session.type,
            remoteDeviceId: session.remoteDeviceId,
            startTime: session.startTime,
            endTime: Date(),
            success: session.state == .completed,
            averageSpeed: session.speed,
            metadata: [
                "compressionEnabled": String(session.configuration.compressionEnabled),
                "encryptionEnabled": String(session.configuration.encryptionEnabled)
            ]
        )
        transferHistory.append(record)
    }

    private func registerActiveTransfer(_ session: FileTransferSession, transferId: String) {
        activeTransfers[transferId] = session
        updateSystemAwakeAssertion()
    }

    private func removeActiveTransfer(_ transferId: String) {
        activeTransfers.removeValue(forKey: transferId)
        updateSystemAwakeAssertion()
    }
    
 /// 加载传输历史记录
    private func loadTransferHistory() {
 // 从统一受保护状态存储加载历史记录
        transferHistory = Self.transferHistoryStore.load() ?? []
    }
    
 /// 保存传输历史记录
    private func saveTransferHistory() {
        try? Self.transferHistoryStore.save(transferHistory)
    }
    
 /// 计算文件校验和
    nonisolated private func calculateFileChecksum(for url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let maybeChunk = try autoreleasepool { try handle.read(upToCount: 1_048_576) }
            guard let chunk = maybeChunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private actor FileHashWorker {
        func sha256Hex(url: URL, chunkSize: Int = 1_048_576) async throws -> String {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while true {
                try Task.checkCancellation()
                let maybeChunk = try autoreleasepool { try handle.read(upToCount: chunkSize) }
                guard let chunk = maybeChunk, !chunk.isEmpty else { break }
                hasher.update(data: chunk)
            }
            let digest = hasher.finalize()
            return digest.map { String(format: "%02x", $0) }.joined()
        }
    }
    
 /// 执行文件传输（旧版兼容方法）
 /// - Warning: 此方法已弃用，请使用 `performFileTransfer(_:connection:)` 进行真实传输
    @available(*, deprecated, message: "使用 performFileTransfer 替代")
    private func performFileTransferLegacy(_ session: FileTransferSession, connection: P2PConnection) async throws {
 // 重定向到真正的传输实现
        logger.warning("⚠️ performFileTransferLegacy 已弃用，请使用 performFileTransfer")
        
 // 调用真正的传输方法
        try await performFileTransfer(session, connection: connection)
    }

 /// 取消传输
    public func cancelTransfer(_ transferId: String) {
        if let session = activeTransfers[transferId] {
            session.state = .cancelled
            removeActiveTransfer(transferId)
            
 // 添加到历史记录
            addToHistory(session)
        }
    }
    
 /// 暂停传输
    public func pauseTransfer(_ transferId: String) {
        if let session = activeTransfers[transferId] {
            session.state = .paused
        }
    }
    
 /// 恢复传输
    public func resumeTransfer(_ transferId: String) {
        if let session = activeTransfers[transferId] {
            session.state = .transferring
        }
    }
    
    deinit {
        Logger(subsystem: "com.skybridge.filetransfer", category: "Engine").debugOnly("🧹 FileTransferEngine 已清理所有资源（deinit）")
    }
    
 /// 清理资源
    public func cleanup() {
 // 取消所有活跃传输
        for transferId in Array(activeTransfers.keys) {
            cancelTransfer(transferId)
        }
        
 // 停止速度监控
        speedCalculationTimer?.invalidate()
        speedCalculationTimer = nil
        
 // 取消所有操作
        transferQueue.cancelAllOperations()
        
        powerAssertion.release()

 // 清理流式临时文件
        for (_, info) in streamingEncryptedFiles {
            try? FileManager.default.removeItem(at: info.url)
        }
        streamingEncryptedFiles.removeAll()
        for (_, url) in streamingEncryptedRecvFiles {
            try? FileManager.default.removeItem(at: url)
        }
        streamingEncryptedRecvFiles.removeAll()
        isCleanedUp = true
    }
}

// MARK: - 错误定义（增强版 - 利用Swift 6.2.1的错误处理改进）

/// 文件传输错误类型 - 符合Swift 6.2.1的Sendable协议
public enum FileTransferEngineError: LocalizedError, Sendable {
    case fileNotFound
    case invalidDestination
    case connectionNotFound
    case transferRejected
    case transferCancelled
    case checksumMismatch
    case networkError(underlying: Error?)
    case encryptionError(underlying: Error?)
    case compressionError(underlying: Error?)
    case connectionTimeout
    case connectionLost
    case retryLimitExceeded(attempts: Int)
    case insufficientPermissions
    case diskSpaceInsufficient(required: Int64, available: Int64)
    case securityThreatDetected(threatName: String)
    
    public var errorDescription: String? {
        switch self {
        case .fileNotFound:
            return "文件未找到"
        case .invalidDestination:
            return "无效的目标路径"
        case .connectionNotFound:
            return "连接未找到"
        case .transferRejected:
            return "传输被拒绝"
        case .transferCancelled:
            return "传输已取消"
        case .checksumMismatch:
            return "校验和不匹配"
        case .networkError(let underlying):
            if let underlying = underlying {
                return "网络错误: \(underlying.localizedDescription)"
            }
            return "网络错误"
        case .encryptionError(let underlying):
            if let underlying = underlying {
                return "加密错误: \(underlying.localizedDescription)"
            }
            return "加密错误"
        case .compressionError(let underlying):
            if let underlying = underlying {
                return "压缩错误: \(underlying.localizedDescription)"
            }
            return "压缩错误"
        case .connectionTimeout:
            return "连接超时"
        case .connectionLost:
            return "连接已断开"
        case .retryLimitExceeded(let attempts):
            return "重试次数已达上限（\(attempts)次）"
        case .insufficientPermissions:
            return "权限不足"
        case .diskSpaceInsufficient(let required, let available):
            return "磁盘空间不足（需要: \(formatBytes(required)), 可用: \(formatBytes(available))）"
        case .securityThreatDetected(let threatName):
            return "检测到安全威胁: \(threatName)"
        }
    }
    
 /// 判断错误是否可重试
    public var isRetriable: Bool {
        switch self {
        case .networkError, .connectionTimeout, .connectionLost:
            return true
        case .retryLimitExceeded, .fileNotFound, .invalidDestination, .insufficientPermissions, .diskSpaceInsufficient:
            return false
        default:
            return false
        }
    }
    
 /// 获取建议的重试延迟（秒）
    public var suggestedRetryDelay: TimeInterval {
        switch self {
        case .networkError, .connectionTimeout:
            return 2.0
        case .connectionLost:
            return 5.0
        default:
            return 1.0
        }
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - 重试策略（利用Swift 6.2.1的并发改进）

/// 重试策略配置 - 符合Swift 6.2.1的Sendable协议
public struct RetryPolicy: Sendable {
    public let maxAttempts: Int
    public let initialDelay: TimeInterval
    public let maxDelay: TimeInterval
    public let backoffMultiplier: Double
    public let jitterEnabled: Bool
    
 /// Maximum retry count for security-hardened delay calculation (default: 20)
 /// Used by `delay(for:)` method to clamp retryCount
    public let maxRetryCount: Int
    
 /// Jitter factor for security-hardened delay calculation (default: 0.2 = ±20%)
 /// Used by `delay(for:)` method
    public let jitterFactor: Double
    
    public static let `default` = RetryPolicy(
        maxAttempts: 3,
        initialDelay: 1.0,
        maxDelay: 30.0,
        backoffMultiplier: 2.0,
        jitterEnabled: true,
        maxRetryCount: 20,
        jitterFactor: 0.2
    )
    
    public static let aggressive = RetryPolicy(
        maxAttempts: 5,
        initialDelay: 0.5,
        maxDelay: 60.0,
        backoffMultiplier: 1.5,
        jitterEnabled: true,
        maxRetryCount: 20,
        jitterFactor: 0.2
    )
    
    public static let conservative = RetryPolicy(
        maxAttempts: 2,
        initialDelay: 2.0,
        maxDelay: 15.0,
        backoffMultiplier: 2.5,
        jitterEnabled: false,
        maxRetryCount: 20,
        jitterFactor: 0.2
    )
    
 /// Initialize with all parameters
    public init(
        maxAttempts: Int,
        initialDelay: TimeInterval,
        maxDelay: TimeInterval,
        backoffMultiplier: Double,
        jitterEnabled: Bool,
        maxRetryCount: Int = 20,
        jitterFactor: Double = 0.2
    ) {
        self.maxAttempts = maxAttempts
        self.initialDelay = initialDelay
        self.maxDelay = maxDelay
        self.backoffMultiplier = backoffMultiplier
        self.jitterEnabled = jitterEnabled
        self.maxRetryCount = maxRetryCount
        self.jitterFactor = jitterFactor
    }
    
 /// 计算重试延迟（指数退避 + 可选的抖动）
 /// Legacy method - use `delay(for:)` for security-hardened calculation
    public func calculateDelay(attempt: Int) -> TimeInterval {
        let baseDelay = initialDelay * pow(backoffMultiplier, Double(attempt - 1))
        let delay = min(baseDelay, maxDelay)
        
        if jitterEnabled {
 // 添加随机抖动（±20%），避免雷群效应
            let jitter = delay * 0.2 * (Double.random(in: -1.0...1.0))
            return max(0.1, delay + jitter)
        }
        
        return delay
    }
    
 /// Security-hardened retry delay calculation with overflow protection
 ///
 /// Features:
 /// - Clamps retryCount to [0, maxRetryCount] (Requirements 10.1, 10.4)
 /// - Returns maxDelay on pow() overflow (!isFinite) (Requirements 10.2, 10.3)
 /// - Ensures final delay never exceeds maxDelay after jitter (Requirement 10.5)
 ///
 /// - Parameter retryCount: The current retry attempt number (0-based)
 /// - Returns: The calculated delay in seconds, guaranteed to be in [0, maxDelay]
    public func delay(for retryCount: Int) -> TimeInterval {
 // Requirement 10.4: Treat negative as 0
 // Requirement 10.1: Clamp to maxRetryCount
        let clampedCount = max(0, min(retryCount, maxRetryCount))
        
 // Calculate multiplier with overflow protection
        let multiplier = pow(backoffMultiplier, Double(clampedCount))
        
 // Requirement 10.3: Check isFinite after pow()
 // Requirement 10.2: Return maxDelay on overflow
        guard multiplier.isFinite else { return maxDelay }
        
        var delay = initialDelay * multiplier
        
 // Check for overflow after multiplication
        guard delay.isFinite else { return maxDelay }
        
 // Apply jitter if enabled
        if jitterEnabled {
            let jitter = delay * jitterFactor * Double.random(in: -1.0...1.0)
            delay += jitter
        }
        
 // Requirement 10.5: Ensure final delay never exceeds maxDelay
 // Also ensure delay is non-negative
        return min(max(0, delay), maxDelay)
    }
}

/// 重试管理器 - 利用Swift 6.2.1的并发改进
public actor RetryManager: @unchecked Sendable {
    private var retryAttempts: [String: Int] = [:]
    private let policy: RetryPolicy
    
    public init(policy: RetryPolicy = .default) {
        self.policy = policy
    }
    
 /// 执行带重试的操作 - 利用Swift 6.2.1的改进并发
    public func executeWithRetry<T: Sendable>(
        operationId: String,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        var attempt = 1
        
        while attempt <= policy.maxAttempts {
            do {
                let result = try await operation()
 // 成功，清除重试计数
                retryAttempts.removeValue(forKey: operationId)
                return result
            } catch let error as FileTransferEngineError {
 // 检查是否可重试
                guard error.isRetriable && attempt < policy.maxAttempts else {
                    retryAttempts.removeValue(forKey: operationId)
                    throw error
                }
                
 // 记录重试
                retryAttempts[operationId] = attempt
                
 // 计算延迟
                let delay = policy.calculateDelay(attempt: attempt)
                logger.info("🔄 重试操作 \(operationId): 第\(attempt)次尝试，\(String(format: "%.1f", delay))秒后重试")
                
 // 等待后重试
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                attempt += 1
            } catch {
 // 非FileTransferEngineError，直接抛出
                retryAttempts.removeValue(forKey: operationId)
                throw error
            }
        }
        
 // 达到最大重试次数
        retryAttempts.removeValue(forKey: operationId)
        throw FileTransferEngineError.retryLimitExceeded(attempts: policy.maxAttempts)
    }
    
 /// 重置重试计数
    public func resetRetryCount(for operationId: String) {
        retryAttempts.removeValue(forKey: operationId)
    }
    
 /// 获取当前重试次数
    public func getRetryCount(for operationId: String) -> Int {
        return retryAttempts[operationId] ?? 0
    }
    
    private let logger = Logger(subsystem: "com.skybridge.filetransfer", category: "RetryManager")
}

// 事件名称扩展
public extension Notification.Name {
    static let fileMerkleVerified = Notification.Name("fileMerkleVerified")
    static let fileChunkVerified = Notification.Name("fileChunkVerified")
    static let fileChunkVerifyFailed = Notification.Name("fileChunkVerifyFailed")
    static let fileMerkleTiming = Notification.Name("fileMerkleTiming")
}

// MARK: - 传输速度限制器（利用macOS 26.x的网络改进）

/// 传输速度限制器 - 符合Swift 6.2.1的Sendable协议
public actor TransferSpeedLimiter: @unchecked Sendable {
    private let maxSpeed: Double // 字节/秒
    private var lastSendTime: Date = Date()
    private var bytesSent: Int64 = 0
    private let timeWindow: TimeInterval = 1.0 // 1秒时间窗口
    
    public init(maxSpeed: Double) {
        self.maxSpeed = maxSpeed
    }
    
 /// 等待以确保不超过速度限制
    public func waitIfNeeded(for bytes: Int) async {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastSendTime)
        
        bytesSent += Int64(bytes)
        
 // 如果超过时间窗口，重置计数
        if elapsed >= timeWindow {
            bytesSent = Int64(bytes)
            lastSendTime = now
            return
        }
        
 // 计算当前速度
        let currentSpeed = Double(bytesSent) / elapsed
        
 // 如果超过限制，等待
        if currentSpeed > maxSpeed {
            let targetTime = Double(bytesSent) / maxSpeed
            let waitTime = targetTime - elapsed
            
            if waitTime > 0 {
                try? await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
                lastSendTime = Date()
                bytesSent = 0
            }
        }
    }
    
 /// 重置速度限制器
    public func reset() {
        lastSendTime = Date()
        bytesSent = 0
    }
    
 /// 更新最大速度
    public func updateMaxSpeed(_ newMaxSpeed: Double) {
 // 注意：这里需要重新初始化，但actor不允许修改let属性
 // 实际实现中应该使用var或重新创建实例
    }
}

// MARK: - 设备连接管理器（利用macOS 26.x的改进持久化）

/// 设备信息 - 符合Swift 6.2.1的Sendable协议和严格并发要求
public struct DeviceInfo: Codable, Sendable, Identifiable {
 // 注意：Date 和 ConnectionStatus 都符合 Sendable，因此整个结构体是线程安全的
    public let id: String
    public let name: String
    public let ipAddress: String
    public let port: Int
    public var lastConnected: Date
    public var connectionStatus: ConnectionStatus
    public var totalTransfers: Int
    public var totalBytesTransferred: Int64
    public var averageSpeed: Double
    
    public init(
        id: String,
        name: String,
        ipAddress: String,
        port: Int = 8080,
        lastConnected: Date = Date(),
        connectionStatus: ConnectionStatus = ConnectionStatus.disconnected,
        totalTransfers: Int = 0,
        totalBytesTransferred: Int64 = 0,
        averageSpeed: Double = 0.0
    ) {
        self.id = id
        self.name = name
        self.ipAddress = ipAddress
        self.port = port
        self.lastConnected = lastConnected
        self.connectionStatus = connectionStatus
        self.totalTransfers = totalTransfers
        self.totalBytesTransferred = totalBytesTransferred
        self.averageSpeed = averageSpeed
    }
}

/// 设备连接管理器 - 利用macOS 26.x的改进持久化
@MainActor
public class DeviceConnectionManager: ObservableObject {
    @Published public var devices: [String: DeviceInfo] = [:]
    private let persistenceKey = "SkyBridge.DeviceConnections"
    private let logger = Logger(subsystem: "com.skybridge.filetransfer", category: "DeviceManager")
    private static let devicesStore = CodablePersistenceStore<TransferDeviceCacheEnvelope<[String: DeviceInfo]>>(
        location: .protectedApplicationSupport(
            path: "FileTransfer/device-connections.json",
            legacyUserDefaultsKey: "SkyBridge.DeviceConnections"
        ),
        encoder: {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            return encoder
        }(),
        decoder: {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return decoder
        }()
    )
 // 为传输设备缓存增加 schemaVersion 顶层信封，统一版本管理与迁移。
 // 当前版本采用 V2：使用 JSON 包装结构 { schemaVersion, payload }。
    private let transferCacheSchemaVersion = 2
    private struct TransferDeviceCacheEnvelope<T: Codable>: Codable {
        let schemaVersion: Int
        let payload: T
    }
    
    public init() {
        loadDevices()
    }
    
 /// 添加或更新设备
    public func addOrUpdateDevice(_ device: DeviceInfo) {
        devices[device.id] = device
        saveDevices()
        logger.info("📱 设备已添加/更新: \(device.name) (\(device.ipAddress))")
    }
    
 /// 获取设备
    public func getDevice(id: String) -> DeviceInfo? {
        return devices[id]
    }
    
 /// 移除设备
    public func removeDevice(id: String) {
        devices.removeValue(forKey: id)
        saveDevices()
        logger.info("🗑️ 设备已移除: \(id)")
    }
    
 /// 更新设备连接状态
    public func updateConnectionStatus(id: String, status: ConnectionStatus) {
        guard var device = devices[id] else { return }
        device.connectionStatus = status
        if status == ConnectionStatus.connected {
            device.lastConnected = Date()
        }
        devices[id] = device
        saveDevices()
    }
    
 /// 更新设备传输统计
    public func updateDeviceStats(id: String, bytesTransferred: Int64, speed: Double) {
        guard var device = devices[id] else { return }
        device.totalTransfers += 1
        device.totalBytesTransferred += bytesTransferred
 // 计算新的平均速度（加权平均）
        let totalTransfers = Double(device.totalTransfers)
        device.averageSpeed = (device.averageSpeed * (totalTransfers - 1) + speed) / totalTransfers
        devices[id] = device
        saveDevices()
    }
    
 /// 保存设备列表 - 利用macOS 26.x的改进文件系统性能
    private func saveDevices() {
        do {
 // V2 写入使用顶层信封，包含 schemaVersion。
            let env = TransferDeviceCacheEnvelope(schemaVersion: transferCacheSchemaVersion, payload: self.devices)
            try Self.devicesStore.save(env)
            logger.debug("💾 设备列表已保存: \(self.devices.count) 个设备")
        } catch {
            logger.error("❌ 保存设备列表失败: \(error.localizedDescription)")
        }
    }
    
 /// 加载设备列表 - 利用macOS 26.x的改进文件系统性能
    private func loadDevices() {
        if let env = Self.devicesStore.load() {
            if env.schemaVersion == transferCacheSchemaVersion {
                self.devices = env.payload
                logger.info("✅ 设备列表已加载(V2): \(self.devices.count) 个设备")
                return
            } else {
                logger.warning("传输设备缓存版本不匹配(schemaVersion=\(env.schemaVersion))，将清空缓存重建")
                try? Self.devicesStore.remove()
                UserDefaults.standard.removeObject(forKey: persistenceKey)
                self.devices = [:]
                return
            }
        }

        guard let data = UserDefaults.standard.data(forKey: persistenceKey) else {
            logger.debug("📂 未找到保存的设备列表")
            return
        }
        
 // 优先按 V2 顶层信封解析，版本不匹配则清理并降级为“无历史”。
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let env = try? decoder.decode(TransferDeviceCacheEnvelope<[String: DeviceInfo]>.self, from: data) {
            if env.schemaVersion == transferCacheSchemaVersion {
                self.devices = env.payload
                try? Self.devicesStore.save(env)
                UserDefaults.standard.removeObject(forKey: persistenceKey)
                logger.info("✅ 设备列表已加载(V2): \(self.devices.count) 个设备")
                return
            } else {
                logger.warning("传输设备缓存版本不匹配(schemaVersion=\(env.schemaVersion))，将清空缓存重建")
                try? Self.devicesStore.remove()
                UserDefaults.standard.removeObject(forKey: persistenceKey)
                self.devices = [:]
                return
            }
        }
        
 // 兼容旧版(V1)——直接存储为 [String: DeviceInfo]，成功则迁移写回为 V2。
        if let legacy = try? decoder.decode([String: DeviceInfo].self, from: data) {
            self.devices = legacy
            logger.info("📂 检测到旧版传输设备缓存(V1)，执行一次性迁移: \(legacy.count) 个设备")
            let env = TransferDeviceCacheEnvelope(schemaVersion: transferCacheSchemaVersion, payload: legacy)
            if (try? Self.devicesStore.save(env)) != nil {
                UserDefaults.standard.removeObject(forKey: persistenceKey)
                logger.debug("🔄 传输设备缓存已升级至统一受保护存储")
            }
            return
        }
        
// 两种格式均解析失败，视为损坏缓存，直接清理。
        logger.warning("传输设备缓存读取失败/版本不匹配，清理重建: \(String(data: data, encoding: .utf8) ?? "<binary>")")
        try? Self.devicesStore.remove()
        UserDefaults.standard.removeObject(forKey: persistenceKey)
        self.devices = [:]
    }
    
 /// 清除所有设备
    public func clearAll() {
        devices.removeAll()
        try? Self.devicesStore.remove()
        UserDefaults.standard.removeObject(forKey: persistenceKey)
        logger.info("🗑️ 所有设备已清除")
    }
}

// MARK: - Data扩展（支持resize操作）
extension Data {
 /// 调整Data大小，用指定字节填充或截断
    mutating func resize(to size: Int, padding: UInt8 = 0) {
        if count < size {
 // 扩展并填充
            append(Data(repeating: padding, count: size - count))
        } else if count > size {
 // 截断
            self = prefix(size)
        }
    }
}
