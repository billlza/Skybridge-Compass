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
        ),
        maximumPayloadBytes: 2 * 1_024 * 1_024
    )
    private static let transferHistoryRepository = BoundedCodableHistoryRepository(
        store: transferHistoryStore,
        maximumEntryCount: 100
    )

 // MARK: - 发布属性

    @Published public var activeTransfers: [String: FileTransferSession] = [:]
    @Published public var transferHistory: [FileTransferRecord] = []
    @Published public var totalProgress: Double = 0.0
    @Published public var transferSpeed: Double = 0.0 // 字节/秒
    @Published public var videoTransferConfiguration: VideoTransferConfiguration = .default
    @Published public private(set) var historyPersistenceError: FileTransferHistoryPersistenceFailure?
    
 // MARK: - 私有属性
    
    private let configuration: TransferConfiguration
    private let networkManager: P2PNetworkManager
    private let securityManager: P2PSecurityManager
    private var transferQueue: OperationQueue
    @MainActor private var speedCalculationTimer: Timer?
    private var lastBytesTransferred: Int64 = 0
    private var cancellables = Set<AnyCancellable>()
    private let fileHashWorker = FileHashWorker()
    private let fileTransformWorker = FileTransformWorker()
    private var isCleanedUp: Bool = false
    private var historyPersistenceTask: Task<Void, Never>?
    private var historyRequestGeneration: UInt64 = 0
    private var appliedHistoryRepositoryGeneration: UInt64 = 0

 // 量子安全：密钥与加密组件
    private let quantumKeyManager = EnhancedQuantumKeyManager()
    private let pqCrypto = EnhancedPostQuantumCrypto()
    private let rotationManager = CryptoKitEnhancements.KeyRotationManager()
    private let logger = Logger(subsystem: "com.skybridge.filetransfer", category: "Engine")

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
        
        logger.info("🛡️ 开始扫描接收文件: level=\(self.currentScanLevel.rawValue, privacy: .public)")
        let configuration = FileScanService.ScanConfiguration(level: self.currentScanLevel)
        let result = await FileScanService.shared.scanFile(at: url, configuration: configuration)
        
        if !result.isSafe {
            logger.warning("🚨 接收文件扫描命中威胁")
            
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
            enqueueHistoryClear()
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
        let retryOperationID = "legacy-file-send-\(UUID().uuidString)"
 // 使用重试管理器执行传输 - 利用Swift 6.2.1的并发改进
        let sendOperation: @Sendable () async throws -> String = { [self] in
            let fileSize: Int64
            do {
                fileSize = try await ClassicTransferSourceFileInspectionWorker.shared.regularFileSize(
                    at: fileURL,
                    maximumSize: LegacyFileTransferWirePolicy.maximumFileSizeBytes
                )
            } catch ClassicTransferSourceFileInspectionError.notFound {
                throw FileTransferEngineError.fileNotFound
            } catch {
                throw FileTransferEngineError.invalidSourceFile
            }

 // 创建传输会话 - 需要在MainActor上下文中创建
            let transferId = UUID().uuidString
            do {
                try LegacyFileTransferWireContract.validatePreflight(
                    transferID: transferId,
                    fileName: fileURL.lastPathComponent,
                    fileSize: fileSize,
                    chunkSize: self.configuration.chunkSize,
                    encryptionEnabled: effectiveEncryptionEnabled
                )
            } catch LegacyFileTransferWireContractError.unsupportedEncryptedFileSize {
                throw FileTransferEngineError.unsupportedLegacyEncryptedFileSize(
                    maximumBytes: LegacyFileTransferWirePolicy.maximumEncryptedFileSizeBytes
                )
            } catch {
                throw FileTransferEngineError.invalidProtocolMetadata
            }

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
                    self.speedLimiter = nil
                }
 // 将非FileTransferEngineError错误包装为networkError
                throw FileTransferEngineError.networkError(underlying: error)
            }
        }

        if automaticRetryEnabled {
            return try await retryManager.executeWithRetry(
                operationId: retryOperationID,
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
        let resolvedDestinationDirectory: URL
        if let destinationDirectory {
            resolvedDestinationDirectory = destinationDirectory
        } else {
            resolvedDestinationDirectory = try getDefaultDownloadDirectory()
        }
        let targetDirectory = resolvedDestinationDirectory.standardizedFileURL
        let stagingDirectory = targetDirectory.appendingPathComponent(
            ".SkyBridgeLegacyInbound",
            isDirectory: true
        )
        let stagingURL = stagingDirectory.appendingPathComponent(
            "legacy-\(UUID().uuidString).partial",
            isDirectory: false
        )
        let proposedDestinationURL = targetDirectory.appendingPathComponent(
            metadata.fileName,
            isDirectory: false
        )
        
 // 创建传输会话
        let session = FileTransferSession(
            id: metadata.transferId,
            type: .receive,
            fileName: metadata.fileName,
            fileSize: metadata.fileSize,
            localURL: proposedDestinationURL,
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
        
        var inboundIOHandle: InboundFileTransferIOHandle?
        var committed = false
        do {
            try await InboundFileTransferIOActor.shared.validateSameVolumeCommit(
                stagingURL: stagingURL,
                destinationDirectory: targetDirectory
            )
            let ioHandle = try await InboundFileTransferIOActor.shared.createTemporaryFile(
                at: stagingURL,
                declaredFileSize: metadata.fileSize
            )
            inboundIOHandle = ioHandle

 // 发送传输确认
            try await sendTransferAcknowledgment(to: connection)
            
 // 执行文件接收
            try await performFileReceive(
                session,
                connection: connection,
                metadata: metadata,
                stagingURL: stagingURL,
                ioHandle: ioHandle
            )
            
 // 文件接收完成后进行病毒扫描（如果启用）
            if let scanResult = await scanReceivedFileIfEnabled(stagingURL) {
                if !scanResult.isSafe {
                    logger.warning("🚨 文件扫描检测到威胁")
                    throw FileTransferEngineError.securityThreatDetected(threatName: scanResult.threatName ?? "未知威胁")
                }
                logger.info("✅ 文件扫描通过")
            }

            _ = try await InboundFileTransferIOActor.shared.commit(
                using: ioHandle,
                destinationDirectory: targetDirectory,
                fileName: metadata.fileName
            )
            committed = true
            try await InboundFileTransferIOActor.shared.releaseCommittedFile(using: ioHandle)
            inboundIOHandle = nil

            // The terminal success is truthful only after verified bytes have
            // been atomically published and I/O ownership has been released.
            try await sendFinalAcknowledgment(
                to: connection,
                transferId: session.id
            )
            
 // 接收成功
            await MainActor.run {
                session.state = .completed
                addToHistory(session)
                removeActiveTransfer(metadata.transferId)
            }
            
            return metadata.transferId
            
        } catch {
            let primaryError = error
            connection.connection.cancel()
            var reportedError = primaryError
            if let ioHandle = inboundIOHandle {
                do {
                    if committed {
                        try await InboundFileTransferIOActor.shared.releaseCommittedFile(using: ioHandle)
                    } else {
                        try await InboundFileTransferIOActor.shared.discard(ioHandle)
                    }
                } catch {
                    reportedError = Self.resourceCleanupFailure(
                        primary: primaryError,
                        cleanup: error
                    )
                }
            }
 // 接收失败
            await MainActor.run {
                session.error = reportedError
                session.state = .failed
                addToHistory(session)
                removeActiveTransfer(metadata.transferId)
            }
            throw reportedError
        }
    }
    
 // MARK: - 私有传输方法
    
 /// 执行文件传输
    private func performFileTransfer(_ session: FileTransferSession, connection: P2PConnection) async throws {
 // 创建文件元数据
        let merkleStart = Date()
        let merkle = try await fileHashWorker.merkleRoot(
            url: session.localURL,
            chunkSize: configuration.chunkSize
        )
        let merkleElapsedMs = Date().timeIntervalSince(merkleStart) * 1000
        NotificationCenter.default.post(name: .fileMerkleTiming, object: nil, userInfo: [
            "phase": "compute",
            "fileSize": session.fileSize,
            "chunkSize": configuration.chunkSize,
            "elapsedMs": merkleElapsedMs
        ])
        let checksum = try await calculateFileChecksum(session.localURL)
        let signerPeerId = securityManager.getDeviceId()
        let requiredSignature = try await pqCrypto.signPQCRequiredWithAlgorithm(
            Data(checksum.utf8),
            for: signerPeerId
        )
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
            fileSignature: requiredSignature.bytes,
            signatureAlgorithm: requiredSignature.algorithm,
            signerPeerId: signerPeerId
        )
        do {
            try LegacyFileTransferWireContract.validate(metadata)
        } catch LegacyFileTransferWireContractError.unsupportedEncryptedFileSize {
            throw FileTransferEngineError.unsupportedLegacyEncryptedFileSize(
                maximumBytes: LegacyFileTransferWirePolicy.maximumEncryptedFileSizeBytes
            )
        } catch {
            throw FileTransferEngineError.invalidProtocolMetadata
        }
        
 // 发送文件元数据
        try await sendFileMetadata(metadata, to: connection)
        
 // 等待传输确认
        try await waitForTransferAcknowledgment(from: connection)
        
 // 分块发送文件
        try await sendFileInChunks(session, connection: connection)
        
 // 等待传输完成确认
        try await waitForTransferComplete(from: connection, expectedTransferId: session.id)
    }
    
 /// 执行文件接收
    private func performFileReceive(
        _ session: FileTransferSession,
        connection: P2PConnection,
        metadata: FileTransferMetadata,
        stagingURL: URL,
        ioHandle: InboundFileTransferIOHandle
    ) async throws {
        let receivedDigest = try await receiveFileInChunks(
            session,
            connection: connection,
            metadata: metadata,
            ioHandle: ioHandle
        )

 // 验证文件完整性
        let receivedChecksum = Self.lowercaseHex(receivedDigest)
        guard receivedChecksum == metadata.checksum else {
            throw FileTransferEngineError.checksumMismatch
        }
 // 校验整文件签名；strict PQC 下缺签名、缺 signer 或算法不明都必须失败关闭。
        guard let sig = metadata.fileSignature,
              let signerId = metadata.signerPeerId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !signerId.isEmpty else {
            NotificationCenter.default.post(name: Notification.Name("fileSignatureVerified"), object: nil, userInfo: [
                "ok": false
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
                "algorithm": metadata.signatureAlgorithm ?? "",
                "ok": ok
            ])
            if !ok { throw FileTransferEngineError.checksumMismatch }
        } catch {
            NotificationCenter.default.post(name: Notification.Name("fileSignatureVerified"), object: nil, userInfo: [
                "algorithm": metadata.signatureAlgorithm ?? "",
                "ok": false
            ])
            throw FileTransferEngineError.checksumMismatch
        }
 // 可选：Merkle 根校验
        if let merkleRoot = metadata.merkleRoot {
            let merkleStart2 = Date()
            let localMerkle = try await fileHashWorker.merkleRoot(
                url: stagingURL,
                chunkSize: metadata.chunkSize
            )
            let verifyElapsedMs = Date().timeIntervalSince(merkleStart2) * 1000
            NotificationCenter.default.post(name: .fileMerkleTiming,
                                            object: nil,
                                            userInfo: [
                                                "phase": "verify",
                                                "fileSize": session.fileSize,
                                                "chunkSize": metadata.chunkSize,
                                                "elapsedMs": verifyElapsedMs
                                            ])
            if localMerkle != merkleRoot {
                NotificationCenter.default.post(name: .fileMerkleVerified,
                                                object: nil,
                                                userInfo: [
                                                    "ok": false
                                                ])
                throw FileTransferEngineError.checksumMismatch
            } else {
                NotificationCenter.default.post(name: .fileMerkleVerified,
                                                object: nil,
                                                userInfo: [
                                                    "ok": true
                                                ])
            }
        }
    }
    
 /// 分块发送文件
    private func sendFileInChunks(_ session: FileTransferSession, connection: P2PConnection) async throws {
        let sourceReader = try await ClassicTransferOutboundFileReadSession.open(
            url: session.localURL,
            tracksSHA256: false
        )
        do {
            let totalChunks = try LegacyFileTransferWireContract.expectedChunkCount(
                fileSize: session.fileSize,
                chunkSize: configuration.chunkSize
            )
            var chunkIndex = 0

            while chunkIndex < totalChunks {
                try Task.checkCancellation()
                if session.state == .cancelled {
                    throw FileTransferEngineError.transferCancelled
                }
                let window = max(1, threadsPerTransfer())
                var batch: [(idx: Int, raw: Data)] = []
                batch.reserveCapacity(window)
                var readCount = 0
                while readCount < window && chunkIndex + readCount < totalChunks {
                    let index = chunkIndex + readCount
                    let offset = Int64(index) * Int64(configuration.chunkSize)
                    let expectedLength = Int(
                        min(Int64(configuration.chunkSize), session.fileSize - offset)
                    )
                    let raw = try await sourceReader.read(
                        offset: UInt64(offset),
                        length: expectedLength
                    )
                    batch.append((idx: index, raw: raw))
                    readCount += 1
                }

                let compressionOn = session.configuration.compressionEnabled
                let encryptionOn = session.configuration.encryptionEnabled
                let processed: [(idx: Int, data: Data, aead: EncryptedData?, isCompressed: Bool, isEncrypted: Bool)] = try await {
                    var plainChunks: [(idx: Int, data: Data, isCompressed: Bool)] = []
                    plainChunks.reserveCapacity(batch.count)
                    if compressionOn {
                        for item in batch {
                            let payload = try await fileTransformWorker.compressIfBeneficial(item.raw)
                            plainChunks.append((
                                idx: item.idx,
                                data: payload.data,
                                isCompressed: payload.isCompressed
                            ))
                        }
                    } else {
                        plainChunks = batch.map { ($0.idx, $0.raw, false) }
                    }

                    if encryptionOn {
                        let key = try await deriveSessionKey(for: session.remoteDeviceId)
                        let keys = Array(repeating: key, count: plainChunks.count)
                        let cryptoWorker = PerformanceOptimizations.ParallelEncryptionManager()
                        let encrypted = try await cryptoWorker.encryptInParallel(
                            chunks: plainChunks.map {
                                LegacyFileTransferWireContract.encryptionPlaintext(for: $0.data)
                            },
                            using: keys,
                            maxConcurrency: threadsPerTransfer()
                        )
                        guard encrypted.count == plainChunks.count else {
                            throw FileTransferEngineError.encryptionError(underlying: nil)
                        }
                        return zip(plainChunks, encrypted).map { plain, encryptedChunk in
                            (
                                idx: plain.idx,
                                data: encryptedChunk.ciphertext,
                                aead: encryptedChunk,
                                isCompressed: plain.isCompressed,
                                isEncrypted: true
                            )
                        }
                        .sorted { $0.idx < $1.idx }
                    }
                    return plainChunks.map {
                        (idx: $0.idx, data: $0.data, aead: nil, isCompressed: $0.isCompressed, isEncrypted: false)
                    }
                    .sorted { $0.idx < $1.idx }
                }()

                guard processed.count == batch.count else {
                    throw FileTransferEngineError.networkError(underlying: nil)
                }
                for (idx, dataOut, aead, isCompressed, isEncrypted) in processed {
                    guard let rawChunk = batch.first(where: { $0.idx == idx }) else {
                        throw FileTransferEngineError.networkError(underlying: nil)
                    }
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
                    try await waitForChunkAcknowledgment(
                        session.id,
                        chunkIndex: idx,
                        from: connection
                    )
                    session.updateBytesTransferred(Int64(rawChunk.raw.count))
                }
                chunkIndex += processed.count
                let progress = Double(chunkIndex) / Double(totalChunks)
                await updateProgress(for: session.id, progress: progress)
            }
            try await sourceReader.close()
        } catch {
            let primaryError = error
            do {
                try await sourceReader.close()
            } catch {
                throw Self.resourceCleanupFailure(primary: primaryError, cleanup: error)
            }
            throw primaryError
        }
    }
    
 /// 分块接收文件
    private func receiveFileInChunks(
        _ session: FileTransferSession,
        connection: P2PConnection,
        metadata: FileTransferMetadata,
        ioHandle: InboundFileTransferIOHandle
    ) async throws -> Data {
        let totalChunks = try LegacyFileTransferWireContract.expectedChunkCount(
            fileSize: metadata.fileSize,
            chunkSize: metadata.chunkSize
        )
        var receivedChunks = 0
        var receivedBytes: Int64 = 0
        
        while receivedChunks < totalChunks {
            try Task.checkCancellation()
            if session.state == .cancelled {
                throw FileTransferEngineError.transferCancelled
            }
            
            let packet = try await receiveChunkPacket(
                from: connection,
                metadata: metadata,
                expectedChunkIndex: receivedChunks
            )
            
 // 验证校验和
            let calculatedChecksum = calculateChecksum(packet.data)
            guard calculatedChecksum == packet.checksum else {
                throw FileTransferEngineError.checksumMismatch
            }
            
 // 处理数据块（解密/解压）
            var payload = packet.data
            if packet.isEncrypted {
 // 分块AEAD校验与解密
                do {
                    guard let nonce = packet.aeadNonce, let tag = packet.aeadTag else {
                        throw FileTransferEngineError.encryptionError(underlying: nil)
                    }
                    let encrypted = EncryptedData(ciphertext: payload, nonce: nonce, tag: tag)
                    payload = try await decryptDataDetailed(
                        encrypted,
                        fromPeer: session.remoteDeviceId
                    )
                    NotificationCenter.default.post(name: .fileChunkVerified, object: nil, userInfo: [
                        "chunkIndex": packet.chunkIndex,
                        "ok": true
                    ])
                } catch {
                    NotificationCenter.default.post(name: .fileChunkVerifyFailed, object: nil, userInfo: [
                        "chunkIndex": packet.chunkIndex,
                        "ok": false
                    ])
                    throw error
                }
            } else if metadata.encryptionEnabled {
                throw FileTransferEngineError.encryptionError(underlying: nil)
            }
            if packet.isCompressed {
                payload = try await fileTransformWorker.decompress(
                    payload,
                    maximumOutputSize: metadata.chunkSize
                )
            }

            do {
                try LegacyFileTransferWireContract.validateDecodedChunkLength(
                    payload.count,
                    metadata: metadata,
                    receivedBytes: receivedBytes
                )
            } catch {
                throw FileTransferEngineError.invalidProtocolChunk
            }
            _ = try await InboundFileTransferIOActor.shared.write(
                payload,
                atOffset: UInt64(receivedBytes),
                using: ioHandle
            )
            
 // 发送块确认
            try await sendChunkAcknowledgment(session.id, chunkIndex: packet.chunkIndex, to: connection)
            
 // 更新进度
            receivedChunks += 1
            let progress = Double(receivedChunks) / Double(totalChunks)
            await updateProgress(for: session.id, progress: progress)
            
 // 更新传输字节数
            receivedBytes += Int64(payload.count)
            session.updateBytesTransferred(Int64(payload.count))
        }
        do {
            try LegacyFileTransferWireContract.validateCompletion(
                receivedBytes: receivedBytes,
                metadata: metadata
            )
        } catch {
            throw FileTransferEngineError.invalidProtocolChunk
        }
        return try await InboundFileTransferIOActor.shared.closeAndDigest(using: ioHandle)
    }
    
 // MARK: - 辅助方法
    
 /// 获取默认下载目录
 /// - Returns: 下载目录 URL；系统未提供该目录时显式失败。
    private func getDefaultDownloadDirectory() throws -> URL {
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
            logger.error("❌ 无法获取默认下载目录")
            throw FileTransferEngineError.invalidDestination
        }
        return downloadDir
    }
    
 /// 计算文件校验和
    private func calculateFileChecksum(_ url: URL) async throws -> String {
        return try await fileHashWorker.sha256Hex(url: url)
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
        
        logger.info("📤 发送文件元数据")
        
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
            
            logger.info("✅ 文件元数据发送完成")
        } catch {
            let metadataError = error as NSError
            logger.error(
                "❌ 发送文件元数据失败: domain=\(metadataError.domain, privacy: .private) code=\(metadataError.code, privacy: .public)"
            )
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
            
            guard messageType == 0x01,
                  dataLength > 0,
                  dataLength <= LegacyFileTransferWirePolicy.maximumMetadataBytes else {
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
            do {
                try LegacyFileTransferWireContract.validate(metadata)
            } catch LegacyFileTransferWireContractError.unsupportedEncryptedFileSize {
                throw FileTransferEngineError.unsupportedLegacyEncryptedFileSize(
                    maximumBytes: LegacyFileTransferWirePolicy.maximumEncryptedFileSizeBytes
                )
            } catch {
                throw FileTransferEngineError.invalidProtocolMetadata
            }
            
            logger.info("✅ 文件元数据接收完成")
            return metadata
        } catch {
            let metadataError = error as NSError
            logger.error(
                "❌ 接收文件元数据失败: domain=\(metadataError.domain, privacy: .private) code=\(metadataError.code, privacy: .public)"
            )
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
    private func receiveChunkPacket(
        from connection: P2PConnection,
        metadata: FileTransferMetadata,
        expectedChunkIndex: Int
    ) async throws -> FileChunkPacket {
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
        let timestamp = headerData.subdata(in: offset..<(offset + 8)).withUnsafeBytes {
            $0.loadUnaligned(as: TimeInterval.self)
        }
        guard timestamp.isFinite else {
            throw FileTransferEngineError.invalidProtocolChunk
        }
        
        let normalizedChecksum = checksum.trimmingCharacters(in: .whitespaces)
        let dataLengthInt: Int
        do {
            dataLengthInt = try LegacyFileTransferWireContract.validatePacketHeader(
                transferID: transferId,
                chunkIndex: chunkIndex,
                totalChunks: totalChunks,
                dataLength: dataLength,
                checksum: normalizedChecksum,
                flags: flags,
                metadata: metadata,
                expectedChunkIndex: expectedChunkIndex
            )
        } catch {
            throw FileTransferEngineError.invalidProtocolChunk
        }

 // 接收数据块
        var chunkData = Data()
        chunkData.reserveCapacity(dataLengthInt)
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
            checksum: normalizedChecksum
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
    private func waitForTransferComplete(
        from connection: P2PConnection,
        expectedTransferId: String
    ) async throws {
        let nwConnection = getNWConnection(from: connection)
        
        logger.debug("⏳ 等待传输完成确认")
        
 // 接收完成消息（扩展格式：0x02 | transferId(36) | tagLen(2) | tag）
        let code = try await receiveData(length: 1, from: nwConnection)
        guard code.count == 1, code[0] == 0x02 else { throw FileTransferEngineError.networkError(underlying: nil) }
        let extHeader = try await receiveData(length: 38, from: nwConnection)
        guard let transferId = String(data: extHeader.prefix(36), encoding: .utf8)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0")),
              transferId == expectedTransferId else {
            throw FileTransferEngineError.networkError(underlying: nil)
        }
        let tagLength = Int(
            extHeader.suffix(2).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self).bigEndian }
        )
        guard tagLength == 0 else {
            throw FileTransferEngineError.networkError(underlying: nil)
        }
        logger.info("📎 完成确认扩展已校验: tagLength=\(tagLength, privacy: .public)")
        logger.debug("✅ 传输完成确认已收到")
    }
    
 /// 发送最终确认
    private func sendFinalAcknowledgment(to connection: P2PConnection, transferId: String) async throws {
        let nwConnection = getNWConnection(from: connection)
        
        logger.debug("📤 发送最终确认")
        
 // 扩展完成消息：0x02 | transferId(36) | tagLen(2) | tag
        var payload = Data([0x02])
        guard var tidBytes = transferId.data(using: .utf8), tidBytes.count <= 36 else {
            throw FileTransferEngineError.networkError(underlying: nil)
        }
        tidBytes.resize(to: 36, padding: 0)
        payload.append(tidBytes)
        let tagLen = UInt16(0).bigEndian
        payload.append(contentsOf: withUnsafeBytes(of: tagLen) { Array($0) })
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
        guard packet.transferId.utf8.count == 36,
              UUID(uuidString: packet.transferId)?.uuidString == packet.transferId,
              packet.chunkIndex >= 0,
              packet.totalChunks > 0,
              packet.chunkIndex < packet.totalChunks,
              packet.chunkIndex <= Int(UInt32.max),
              packet.totalChunks <= LegacyFileTransferWirePolicy.maximumChunkCount else {
            throw FileTransferEngineError.invalidProtocolChunk
        }
        do {
            try ClassicTransferMetadataContract.validateSHA256Hex(packet.checksum)
        } catch {
            throw FileTransferEngineError.invalidProtocolChunk
        }
        if packet.isEncrypted {
            guard packet.aeadNonce?.count == 12, packet.aeadTag?.count == 16 else {
                throw FileTransferEngineError.encryptionError(underlying: nil)
            }
        } else if packet.aeadNonce != nil || packet.aeadTag != nil {
            throw FileTransferEngineError.invalidProtocolChunk
        }
        
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
                try await limiter.waitIfNeeded(for: chunk.count)
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
        let operation = ClassicTransferSendOperation()
        let timeoutTask = Task.detached(priority: .utility) {
            do {
                try await Task.sleep(
                    for: .seconds(ClassicTransferInboundPolicy.frameSendTimeoutSeconds)
                )
            } catch is CancellationError {
                return
            } catch {
                if operation.fail(error) {
                    connection.cancel()
                }
                return
            }
            if operation.fail(FileTransferEngineError.connectionTimeout) {
                connection.cancel()
            }
        }
        defer { timeoutTask.cancel() }
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                operation.install(continuation)
                guard !operation.isCompleted else { return }
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error {
                        if operation.fail(FileTransferEngineError.networkError(underlying: error)) {
                            connection.cancel()
                        }
                    } else {
                        _ = operation.succeed()
                    }
                })
            }
        }, onCancel: {
            if operation.fail(FileTransferEngineError.transferCancelled) {
                connection.cancel()
            }
        })
    }
    
 /// 从NWConnection接收数据 - 利用macOS 26.x的性能优化
    private func receiveData(
        length: Int,
        from connection: NWConnection,
        timeout: TimeInterval = ClassicTransferInboundPolicy.frameIdleTimeoutSeconds
    ) async throws -> Data {
        guard length >= 0, timeout > 0 else {
            throw FileTransferEngineError.invalidProtocolChunk
        }
        let operation = ClassicTransferReceiveOperation(expectedLength: length)
        let timeoutTask = Task.detached(priority: .utility) {
            do {
                try await Task.sleep(for: .seconds(timeout))
            } catch is CancellationError {
                return
            } catch {
                if operation.fail(error) {
                    connection.cancel()
                }
                return
            }
            if operation.fail(FileTransferEngineError.connectionTimeout) {
                connection.cancel()
            }
        }
        defer { timeoutTask.cancel() }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                operation.install(continuation)
                guard !operation.isCompleted else { return }

                @Sendable func receiveMore() {
                    guard let remaining = operation.remainingLength(), remaining > 0 else { return }
                    connection.receive(
                        minimumIncompleteLength: 1,
                        maximumLength: remaining
                    ) { data, _, isComplete, error in
                        guard !operation.isCompleted else { return }
                        if let error {
                            _ = operation.fail(
                                FileTransferEngineError.networkError(underlying: error)
                            )
                            return
                        }
                        if let data, !data.isEmpty {
                            switch operation.append(data) {
                            case .completed, .ignoredAfterCompletion:
                                return
                            case .overflow:
                                if operation.fail(FileTransferEngineError.invalidProtocolChunk) {
                                    connection.cancel()
                                }
                                return
                            case .pending:
                                break
                            }
                        }
                        if isComplete {
                            _ = operation.fail(FileTransferEngineError.connectionLost)
                            return
                        }
                        guard !operation.isCompleted else { return }
                        receiveMore()
                    }
                }

                receiveMore()
            }
        }, onCancel: {
            if operation.fail(FileTransferEngineError.transferCancelled) {
                connection.cancel()
            }
        })
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
        if let storedData = try quantumKeyManager.retrieveKeyFromKeychainIfPresent(
            identifier: keychainKey
        ) {
            guard storedData.count == 32 else {
                throw EnhancedQuantumKeyManagerError.invalidKeychainPayload
            }
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

 /// 解密数据（详细版，使用AEAD字段）
    private func decryptDataDetailed(_ enc: EncryptedData, fromPeer peerId: String) async throws -> Data {
        let sessionKey = try await deriveSessionKey(for: peerId)
        let encodedPayload = try await pqCrypto.decrypt(enc, using: sessionKey)
        do {
            return try LegacyFileTransferWireContract.decodeEncryptionPlaintext(encodedPayload)
        } catch {
            throw FileTransferEngineError.encryptionError(underlying: error)
        }
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
        if transferHistory.count > 100 {
            transferHistory = Array(transferHistory.suffix(100))
        }
        enqueueHistoryAppend(record)
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
        enqueueHistoryLoad()
    }

    func awaitHistoryPersistence() async {
        while true {
            let expectedGeneration = historyRequestGeneration
            let task = historyPersistenceTask
            await task?.value
            guard expectedGeneration != historyRequestGeneration else { return }
        }
    }

    private func enqueueHistoryLoad() {
        let requestGeneration = nextHistoryRequestGeneration()
        let previousTask = historyPersistenceTask
        let repository = Self.transferHistoryRepository
        historyPersistenceTask = Task { @MainActor [weak self] in
            await previousTask?.value
            do {
                let snapshot = try await repository.load()
                self?.applyHistorySnapshot(snapshot, requestGeneration: requestGeneration)
            } catch {
                self?.recordHistoryPersistenceFailure(
                    operation: .load,
                    error: error,
                    requestGeneration: requestGeneration
                )
            }
        }
    }

    private func enqueueHistoryAppend(_ record: FileTransferRecord) {
        let requestGeneration = nextHistoryRequestGeneration()
        let previousTask = historyPersistenceTask
        let repository = Self.transferHistoryRepository
        historyPersistenceTask = Task { @MainActor [weak self] in
            await previousTask?.value
            do {
                let snapshot = try await repository.append(record)
                self?.applyHistorySnapshot(snapshot, requestGeneration: requestGeneration)
            } catch {
                self?.recordHistoryPersistenceFailure(
                    operation: .append,
                    error: error,
                    requestGeneration: requestGeneration
                )
            }
        }
    }

    private func enqueueHistoryClear() {
        let requestGeneration = nextHistoryRequestGeneration()
        let previousTask = historyPersistenceTask
        let repository = Self.transferHistoryRepository
        historyPersistenceTask = Task { @MainActor [weak self] in
            await previousTask?.value
            do {
                let snapshot = try await repository.clear()
                self?.applyHistorySnapshot(snapshot, requestGeneration: requestGeneration)
            } catch {
                self?.recordHistoryPersistenceFailure(
                    operation: .clear,
                    error: error,
                    requestGeneration: requestGeneration
                )
            }
        }
    }

    private func nextHistoryRequestGeneration() -> UInt64 {
        historyRequestGeneration += 1
        return historyRequestGeneration
    }

    private func applyHistorySnapshot(
        _ snapshot: BoundedHistorySnapshot<FileTransferRecord>,
        requestGeneration: UInt64
    ) {
        guard requestGeneration == historyRequestGeneration,
              snapshot.generation >= appliedHistoryRepositoryGeneration else {
            return
        }
        appliedHistoryRepositoryGeneration = snapshot.generation
        transferHistory = snapshot.entries
        historyPersistenceError = nil
    }

    private func recordHistoryPersistenceFailure(
        operation: FileTransferHistoryPersistenceOperation,
        error: Error,
        requestGeneration: UInt64
    ) {
        guard requestGeneration == historyRequestGeneration else { return }
        let failure = FileTransferHistoryPersistenceFailure(operation: operation, error: error)
        historyPersistenceError = failure
        logger.error(
            "❌ 旧版传输历史持久化失败: operation=\(failure.operation, privacy: .public) domain=\(failure.domain, privacy: .private) code=\(failure.code, privacy: .public)"
        )
    }

    private actor FileHashWorker {
        func sha256Hex(url: URL) async throws -> String {
            let reader = try await ClassicTransferOutboundFileReadSession.open(
                url: url,
                tracksSHA256: false
            )
            let digest = try await reader.hashWholeFileAndClose()
            return FileTransferEngine.lowercaseHex(digest)
        }

        func merkleRoot(url: URL, chunkSize: Int) async throws -> String {
            guard chunkSize >= LegacyFileTransferWirePolicy.minimumChunkSizeBytes,
                  chunkSize <= LegacyFileTransferWirePolicy.maximumChunkSizeBytes else {
                throw FileTransferEngineError.invalidProtocolMetadata
            }
            let fileSize = try await ClassicTransferSourceFileInspectionWorker.shared.regularFileSize(
                at: url,
                maximumSize: LegacyFileTransferWirePolicy.maximumFileSizeBytes
            )
            let reader = try await ClassicTransferOutboundFileReadSession.open(
                url: url,
                tracksSHA256: false
            )
            do {
                var leafHashes: [Data] = []
                if fileSize > 0 {
                    let chunkCount = try LegacyFileTransferWireContract.expectedChunkCount(
                        fileSize: fileSize,
                        chunkSize: chunkSize
                    )
                    leafHashes.reserveCapacity(chunkCount)
                    for index in 0..<chunkCount {
                        try Task.checkCancellation()
                        let offset = Int64(index) * Int64(chunkSize)
                        let length = Int(min(Int64(chunkSize), fileSize - offset))
                        let chunk = try await reader.read(
                            offset: UInt64(offset),
                            length: length
                        )
                        leafHashes.append(Data(SHA256.hash(data: chunk)))
                    }
                }
                try await reader.close()

                if leafHashes.isEmpty {
                    return FileTransferEngine.lowercaseHex(Data(SHA256.hash(data: Data())))
                }
                var level = leafHashes
                while level.count > 1 {
                    try Task.checkCancellation()
                    var nextLevel: [Data] = []
                    nextLevel.reserveCapacity((level.count + 1) / 2)
                    var index = 0
                    while index < level.count {
                        let left = level[index]
                        let right = index + 1 < level.count ? level[index + 1] : left
                        var combined = Data(capacity: left.count + right.count)
                        combined.append(left)
                        combined.append(right)
                        nextLevel.append(Data(SHA256.hash(data: combined)))
                        index += 2
                    }
                    level = nextLevel
                }
                return FileTransferEngine.lowercaseHex(level[0])
            } catch {
                let primaryError = error
                do {
                    try await reader.close()
                } catch {
                    throw FileTransferEngine.resourceCleanupFailure(
                        primary: primaryError,
                        cleanup: error
                    )
                }
                throw primaryError
            }
        }
    }

    private actor FileTransformWorker {
        func compressIfBeneficial(_ data: Data) throws -> ChunkCompressionResult {
            try Task.checkCancellation()
            return try FileTransferEngine.compressDataIfBeneficial(data)
        }

        func decompress(_ data: Data, maximumOutputSize: Int) throws -> Data {
            try Task.checkCancellation()
            return try FileTransferEngine.decompressData(
                data,
                maxOutputSize: maximumOutputSize
            )
        }
    }

    nonisolated private static func lowercaseHex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func resourceCleanupFailure(
        primary: Error,
        cleanup: Error
    ) -> FileTransferEngineError {
        let primaryError = primary as NSError
        let cleanupError = cleanup as NSError
        return .resourceCleanupFailed(
            primaryDomain: primaryError.domain,
            primaryCode: primaryError.code,
            cleanupDomain: cleanupError.domain,
            cleanupCode: cleanupError.code
        )
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

        isCleanedUp = true
    }
}

// MARK: - 错误定义（增强版 - 利用Swift 6.2.1的错误处理改进）

/// 文件传输错误类型 - 符合Swift 6.2.1的Sendable协议
public enum FileTransferEngineError: LocalizedError, Sendable {
    case fileNotFound
    case invalidSourceFile
    case invalidDestination
    case invalidProtocolMetadata
    case invalidProtocolChunk
    case unsupportedLegacyEncryptedFileSize(maximumBytes: Int64)
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
    case resourceCleanupFailed(
        primaryDomain: String,
        primaryCode: Int,
        cleanupDomain: String,
        cleanupCode: Int
    )
    
    public var errorDescription: String? {
        switch self {
        case .fileNotFound:
            return "文件未找到"
        case .invalidSourceFile:
            return "源文件不是可安全读取的普通文件"
        case .invalidDestination:
            return "无效的目标路径"
        case .invalidProtocolMetadata:
            return "文件传输元数据无效"
        case .invalidProtocolChunk:
            return "文件传输数据块违反协议约束"
        case .unsupportedLegacyEncryptedFileSize(let maximumBytes):
            return "旧版传输协议不支持超过 \(formatBytes(maximumBytes)) 的加密文件，请使用新版文件传输"
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
        case .resourceCleanupFailed(
            let primaryDomain,
            let primaryCode,
            let cleanupDomain,
            let cleanupCode
        ):
            return "文件传输失败且资源清理失败（primary=\(primaryDomain):\(primaryCode), cleanup=\(cleanupDomain):\(cleanupCode)）"
        }
    }
    
 /// 判断错误是否可重试
    public var isRetriable: Bool {
        switch self {
        case .networkError, .connectionTimeout, .connectionLost:
            return true
        case .retryLimitExceeded,
             .fileNotFound,
             .invalidSourceFile,
             .invalidDestination,
             .invalidProtocolMetadata,
             .invalidProtocolChunk,
             .unsupportedLegacyEncryptedFileSize,
             .insufficientPermissions,
             .diskSpaceInsufficient,
             .resourceCleanupFailed:
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

public enum TransferSpeedLimiterError: Error, Sendable {
    case invalidByteCount
}

/// 传输速度限制器 - 符合Swift 6.2.1的Sendable协议
public actor TransferSpeedLimiter {
    private let maxSpeed: Double // 字节/秒
    private var lastSendTime: Date = Date()
    private var bytesSent: Int64 = 0
    private let timeWindow: TimeInterval = 1.0 // 1秒时间窗口
    
    public init(maxSpeed: Double) {
        precondition(maxSpeed > 0, "maxSpeed must be positive")
        self.maxSpeed = maxSpeed
    }
    
 /// 等待以确保不超过速度限制
    public func waitIfNeeded(for bytes: Int) async throws {
        try Task.checkCancellation()
        guard bytes >= 0 else {
            throw TransferSpeedLimiterError.invalidByteCount
        }
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
                try await Task.sleep(for: .seconds(waitTime))
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
    @Published public private(set) var persistenceError: DeviceConnectionPersistenceFailure?
    private let logger = Logger(subsystem: "com.skybridge.filetransfer", category: "DeviceManager")
    private static let devicesStore = CodablePersistenceStore<TransferDeviceCacheEnvelope<[String: DeviceInfo]>>(
        location: .protectedApplicationSupport(
            path: "FileTransfer/device-connections.json"
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
        }(),
        maximumPayloadBytes: 2 * 1_024 * 1_024
    )
    private let repository: DeviceConnectionRepository
    private var persistenceTask: Task<Void, Never>?
    private var persistenceRequestGeneration: UInt64 = 0
    private var appliedRepositoryGeneration: UInt64 = 0
    private enum PersistenceCommand: Sendable {
        case load
        case upsert(DeviceInfo)
        case remove(String)
        case updateStatus(id: String, status: ConnectionStatus)
        case updateStatistics(id: String, bytesTransferred: Int64, speed: Double)
        case clear
    }
    
    public init() {
        repository = DeviceConnectionRepository(store: Self.devicesStore)
        enqueueLoad()
    }
    
 /// 添加或更新设备
    public func addOrUpdateDevice(_ device: DeviceInfo) {
        do {
            try DeviceConnectionRepository.validateInput(device)
        } catch {
            recordPersistenceFailure(operation: .upsert, error: error)
            return
        }
        guard devices[device.id] != nil || devices.count < DeviceConnectionRepository.maximumDeviceCount else {
            recordPersistenceFailure(
                operation: .upsert,
                error: DeviceConnectionRepositoryError.capacityExceeded
            )
            return
        }
        enqueue(.upsert(device), operation: .upsert)
        logger.info("📱 设备已添加/更新")
    }
    
 /// 获取设备
    public func getDevice(id: String) -> DeviceInfo? {
        return devices[id]
    }
    
 /// 移除设备
    public func removeDevice(id: String) {
        enqueue(.remove(id), operation: .remove)
        logger.info("🗑️ 设备已移除")
    }
    
 /// 更新设备连接状态
    public func updateConnectionStatus(id: String, status: ConnectionStatus) {
        enqueue(.updateStatus(id: id, status: status), operation: .updateStatus)
    }
    
 /// 更新设备传输统计
    public func updateDeviceStats(id: String, bytesTransferred: Int64, speed: Double) {
        guard bytesTransferred >= 0, speed.isFinite, speed >= 0 else {
            recordPersistenceFailure(
                operation: .updateStatistics,
                error: DeviceConnectionRepositoryError.invalidEntry
            )
            return
        }
        enqueue(
            .updateStatistics(id: id, bytesTransferred: bytesTransferred, speed: speed),
            operation: .updateStatistics
        )
    }
    
 /// 清除所有设备
    public func clearAll() {
        enqueue(.clear, operation: .clear)
        logger.info("🗑️ 所有设备已清除")
    }

    func awaitPersistence() async {
        while true {
            let expectedGeneration = persistenceRequestGeneration
            let task = persistenceTask
            await task?.value
            guard expectedGeneration == persistenceRequestGeneration else { continue }
            return
        }
    }

    private func enqueueLoad() {
        enqueue(.load, operation: .load)
    }

    private func enqueue(
        _ command: PersistenceCommand,
        operation: DeviceConnectionPersistenceOperation
    ) {
        let nextGeneration = persistenceRequestGeneration.addingReportingOverflow(1)
        precondition(!nextGeneration.overflow, "Device connection persistence generation overflow")
        persistenceRequestGeneration = nextGeneration.partialValue
        let requestGeneration = persistenceRequestGeneration
        let previousTask = persistenceTask
        let repository = self.repository
        persistenceTask = Task { @MainActor [weak self] in
            await previousTask?.value
            do {
                let snapshot: DeviceConnectionSnapshot
                switch command {
                case .load:
                    snapshot = try await repository.load()
                case let .upsert(device):
                    snapshot = try await repository.upsert(device)
                case let .remove(id):
                    snapshot = try await repository.remove(id: id)
                case let .updateStatus(id, status):
                    snapshot = try await repository.updateStatus(id: id, status: status)
                case let .updateStatistics(id, bytesTransferred, speed):
                    snapshot = try await repository.updateStatistics(
                        id: id,
                        bytesTransferred: bytesTransferred,
                        speed: speed
                    )
                case .clear:
                    snapshot = try await repository.clear()
                }
                self?.apply(snapshot, requestGeneration: requestGeneration)
            } catch {
                self?.recordPersistenceFailure(
                    operation: operation,
                    error: error,
                    requestGeneration: requestGeneration
                )
            }
        }
    }

    private func apply(_ snapshot: DeviceConnectionSnapshot, requestGeneration: UInt64) {
        guard requestGeneration == persistenceRequestGeneration,
              snapshot.generation >= appliedRepositoryGeneration else {
            return
        }
        appliedRepositoryGeneration = snapshot.generation
        devices = snapshot.devices
        persistenceError = nil
        logger.debug("💾 设备列表已同步: count=\(self.devices.count, privacy: .public)")
    }

    private func recordPersistenceFailure(
        operation: DeviceConnectionPersistenceOperation,
        error: Error,
        requestGeneration: UInt64? = nil
    ) {
        if let requestGeneration, requestGeneration != persistenceRequestGeneration {
            return
        }
        let failure = DeviceConnectionPersistenceFailure(operation: operation, error: error)
        persistenceError = failure
        logger.error(
            "❌ 设备列表持久化失败: operation=\(failure.operation, privacy: .public) domain=\(failure.domain, privacy: .private) code=\(failure.code, privacy: .public)"
        )
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
