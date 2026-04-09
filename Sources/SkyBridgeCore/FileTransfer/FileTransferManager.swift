import Foundation
import Network
import OSLog
import Combine
import CryptoKit
#if canImport(UserNotifications)
import UserNotifications
#endif

/// 文件传输管理器 - 负责高速文件传输，支持分块传输和断点续传
@MainActor
public class FileTransferManager: BaseManager {
    private static let transferHistoryStore = CodablePersistenceStore<[PersistedFileTransferHistoryEntry]>(
        location: .protectedApplicationSupport(
            path: "FileTransfer/manager-history.json",
            legacyUserDefaultsKey: "FileTransferManager.History"
        )
    )

    /// Shared instance used across the app (so WebRTC / listeners can update the same model the UI observes).
    public static let shared = FileTransferManager()

 // MARK: - 发布的属性
    @Published public var activeTransfers: [String: FileTransfer] = [:]
    @Published public var transferHistory: [FileTransfer] = []
    @Published public var totalProgress: Double = 0.0
    @Published public var isTransferring: Bool = false

 // MARK: - 私有属性
    private let networkService = FileTransferNetworkService()
    private var chunkSize: Int = 1024 * 1024 // 1MB 分块大小
    private let maxChunkSizeBytes: Int = 512 * 1024
    private let maxMessageBytes: Int = 2_000_000
    private var maxConcurrentTransfers = 3
    private var compressionEnabled: Bool = true
    private var encryptionEnabled: Bool = true
    private var maxTransferSpeedBytesPerSecond: Double?
    private var receiveBaseDirectory: URL?
    private var transferQueue = DispatchQueue(label: "file.transfer.queue", qos: .userInitiated)
    private var transferRateLimitStates: [String: TransferRateLimitState] = [:]

    /// Last time we observed meaningful transfer activity (start/progress/finish).
    /// Used for a short UI grace period so the dashboard can show a visible "connected" signal even for fast transfers.
    @MainActor private var lastTransferActivityAt: Date?
    @MainActor private var activityGraceTask: Task<Void, Never>?
    private let transferActivityGraceSeconds: Double = 12.0
    private let historyStore: CodablePersistenceStore<[PersistedFileTransferHistoryEntry]>

    #if canImport(UserNotifications)
    private static func canUseUserNotificationsSafely() -> Bool {
        // `UNUserNotificationCenter.current()` can raise an Obj-C NSException if the current process
        // isn't running from a proper application bundle (e.g. running the binary directly from Build/Products).
        // Swift cannot catch NSException, so we must gate the call.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return false
        }
        let bundleURL = Bundle.main.bundleURL
        return bundleURL.pathExtension.lowercased() == "app"
    }
    #endif

 /// 初始化文件传输管理器
    public init() {
        self.historyStore = Self.transferHistoryStore
        super.init(category: "FileTransferManager")
        loadPersistedHistory()
        logger.info("📁 初始化文件传输管理器")
    }

    init(historyStore: CodablePersistenceStore<[PersistedFileTransferHistoryEntry]>) {
        self.historyStore = historyStore
        super.init(category: "FileTransferManager")
        loadPersistedHistory()
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
        logger.info("📁 文件传输管理器资源已清理（保留历史记录）")
    }

 // MARK: - 公共方法
 /// 更新传输设置（运行时可变）
    public func updateSettings(
        maxConcurrentTransfers: Int? = nil,
        chunkSize: Int? = nil,
        enableCompression: Bool? = nil,
        enableEncryption: Bool? = nil,
        maxTransferSpeedBytesPerSecond: Double? = nil
    ) {
        if let maxConcurrentTransfers { self.maxConcurrentTransfers = max(1, maxConcurrentTransfers) }
        if let chunkSize { self.chunkSize = min(maxChunkSizeBytes, max(64 * 1024, chunkSize)) }
        if let enableCompression { self.compressionEnabled = enableCompression }
        if let enableEncryption { self.encryptionEnabled = enableEncryption }
        if let maxTransferSpeedBytesPerSecond {
            self.maxTransferSpeedBytesPerSecond = maxTransferSpeedBytesPerSecond > 0 ? maxTransferSpeedBytesPerSecond : nil
        }
        logger.info("⚙️ 传输设置已更新：并发=\(self.maxConcurrentTransfers), 块=\(self.chunkSize), 压缩=\(self.compressionEnabled), 加密=\(self.encryptionEnabled), 限速=\(self.currentSpeedLimitDescription(), privacy: .public)")
    }

    /// 设置接收文件的基础目录
    public func setReceiveBaseDirectory(_ url: URL?) {
        receiveBaseDirectory = resolvedWritableReceiveDirectory(from: url)
        logger.info("📂 接收目录已更新: \(self.receiveBaseDirectory?.path ?? Self.defaultReceiveDirectory().path)")
    }

    private struct TransferRateLimitState {
        var windowStart: Date
        var bytesInWindow: Int64
    }

    @available(macOS 14.0, iOS 17.0, *)
    private struct ClassicTransferSecurityContext {
        let transferKey: SymmetricKey
    }

    private func currentSpeedLimitDescription() -> String {
        guard let limit = maxTransferSpeedBytesPerSecond, limit > 0 else {
            return "不限速"
        }

        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: Int64(limit)))/s"
    }

    private func applySpeedLimitIfNeeded(for transferId: String, transferredBytes: Int) async {
        guard transferredBytes > 0 else { return }
        guard let limit = maxTransferSpeedBytesPerSecond, limit > 0 else { return }

        let now = Date()
        var state = transferRateLimitStates[transferId] ?? TransferRateLimitState(windowStart: now, bytesInWindow: 0)

        if now.timeIntervalSince(state.windowStart) >= 1.0 {
            state.windowStart = now
            state.bytesInWindow = 0
        }

        state.bytesInWindow += Int64(transferredBytes)
        let elapsed = max(Date().timeIntervalSince(state.windowStart), 0.000_001)
        let expectedDuration = Double(state.bytesInWindow) / limit

        if expectedDuration > elapsed {
            let sleepSeconds = expectedDuration - elapsed
            if sleepSeconds > 0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(min(sleepSeconds, 5.0) * 1_000_000_000))
                } catch {
                    return
                }
            }
        }

        transferRateLimitStates[transferId] = state
    }

    private func clearSpeedLimitState(for transferId: String) {
        transferRateLimitStates.removeValue(forKey: transferId)
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func classicTransferSecurityContext(
        peerDeviceId: String,
        ipAddress: String?,
        transferId: String
    ) throws -> ClassicTransferSecurityContext {
        let candidateConnection = P2PNetworkManager.shared.activeConnections[peerDeviceId]
            ?? P2PNetworkManager.shared.activeConnections.values.first(where: { connection in
                connection.status == .authenticated &&
                (
                    connection.device.deviceId == peerDeviceId ||
                    (
                        ipAddress?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false &&
                        connection.device.address == ipAddress
                    )
                )
            })

        guard let connection = candidateConnection, connection.status == .authenticated else {
            throw FileTransferError.secureSessionRequired
        }

        return ClassicTransferSecurityContext(
            transferKey: try connection.deriveClassicFileTransferKey(transferId: transferId)
        )
    }

    private func shouldAttemptAutomaticOutgoingResume(for error: Error, transferredBytes: Int64) -> Bool {
        guard transferredBytes > 0 else { return false }
        guard let transferError = error as? FileTransferError else { return false }

        switch transferError {
        case .connectionClosed, .timeout:
            return true
        default:
            return false
        }
    }

    /// Sends a file to the currently active P2P peer.
    /// This resolves the peer from ConnectionPresenceService (Authenticated) or P2PConnectionService (UDP) as fallback.
    public func sendFileToFirstActivePeer(at url: URL) async throws {
        let routes = await resolveActivePeerRoutes()
        guard !routes.isEmpty else {
            throw NSError(
                domain: "SkyBridge.FileTransfer",
                code: -1001,
                userInfo: [NSLocalizedDescriptionKey: "未建立可用 P2P 连接 (No Authenticated Peer or UDP Link)"]
            )
        }

        var lastError: Error?
        for route in routes {
            do {
                logger.info(
                    "📡 尝试活跃会话文件路由: peer=\(route.deviceName) addr=\(route.ipAddress):\(route.port)"
                )
                try await sendFile(
                    at: url,
                    to: route.deviceId,
                    deviceName: route.deviceName,
                    ipAddress: route.ipAddress,
                    port: route.port
                )
                return
            } catch {
                lastError = error
                logger.warning(
                    "⚠️ 活跃会话文件路由失败，尝试下一条: peer=\(route.deviceName, privacy: .public) addr=\(route.ipAddress, privacy: .public):\(route.port) err=\(error.localizedDescription, privacy: .public)"
                )
            }
        }

        throw lastError ?? NSError(
            domain: "SkyBridge.FileTransfer",
            code: -1003,
            userInfo: [NSLocalizedDescriptionKey: "已发现活跃连接，但无法解析可用传输路由"]
        )
    }

    struct ActivePeerRoute: Sendable, Equatable {
        let deviceId: String
        let deviceName: String
        let ipAddress: String
        let port: Int
        let routeSource: String
    }

    func resolveActivePeerRoutes() async -> [ActivePeerRoute] {
        var routes: [ActivePeerRoute] = []
        var dedupe = Set<String>()
        var usedCompatibilityFallback = false

        func appendRoute(
            deviceId: String,
            deviceName: String,
            address: String?,
            port: Int = 8080,
            routeSource: String
        ) {
            guard let address = sanitizeAddress(address) else { return }
            guard (1...65535).contains(port) else { return }
            let key = "\(address.lowercased()):\(port)"
            guard !dedupe.contains(key) else { return }
            dedupe.insert(key)
            routes.append(
                ActivePeerRoute(
                    deviceId: deviceId,
                    deviceName: deviceName.isEmpty ? "P2P Device" : deviceName,
                    ipAddress: address,
                    port: port,
                    routeSource: routeSource
                )
            )
        }

        let routeDescriptors = ConnectionPresenceService.shared.activeRouteDescriptors()
        for route in routeDescriptors {
            appendRoute(
                deviceId: route.peerId,
                deviceName: route.deviceName,
                address: route.transferAddress,
                port: route.transferPort,
                routeSource: "presence:\(route.routeSource.rawValue)"
            )
        }

        if #available(macOS 14.0, *) {
            let connectedDevices = UnifiedOnlineDeviceManager.shared.onlineDevices
                .filter { !$0.isLocalDevice && $0.connectionStatus == .connected }
                .sorted { ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast) }
            for device in connectedDevices {
                guard let transferPort = device.portMap["_skybridge-transfer._tcp"],
                      (1...65535).contains(transferPort) else {
                    continue
                }
                usedCompatibilityFallback = true
                appendRoute(
                    deviceId: device.uniqueIdentifier,
                    deviceName: device.name,
                    address: device.ipv4 ?? device.ipv6,
                    port: transferPort,
                    routeSource: "unified"
                )
            }
        }

        if usedCompatibilityFallback, !routeDescriptors.isEmpty {
            logger.warning("⚠️ 文件传输路由解析回退到兼容路径；首选应来自 PresenceRouteDescriptor")
        }

        return routes
    }

    private func parseAddressFromEndpoint(_ endpoint: NWEndpoint?) -> String? {
        guard let endpoint else { return nil }
        guard case .hostPort(let host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let ipv4):
            return "\(ipv4)"
        case .ipv6(let ipv6):
            return "\(ipv6)"
        case .name(let name, _):
            return name
        @unknown default:
            return nil
        }
    }

    private func parseAddressFromPeerId(_ peerId: String) -> String? {
        guard peerId.hasPrefix("peer:") else { return nil }
        return sanitizeAddress(String(peerId.dropFirst("peer:".count)))
    }

    private func sanitizeAddress(_ raw: String?) -> String? {
        guard var token = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            return nil
        }

        if token.hasPrefix("host:") {
            token = String(token.dropFirst("host:".count))
        } else if token.hasPrefix("peer:") {
            token = String(token.dropFirst("peer:".count))
        } else if token.hasPrefix("ip:") {
            token = String(token.dropFirst("ip:".count))
        }

        if token.hasPrefix("[") && token.hasSuffix("]") {
            token = String(token.dropFirst().dropLast())
        }
        if token.contains(":"),
           let dot = token.lastIndex(of: "."),
           token[token.index(after: dot)...].allSatisfy({ $0.isNumber }) {
            token = String(token[..<dot])
        } else {
            let parts = token.split(separator: ".")
            if parts.count == 5,
               parts.dropLast().allSatisfy({ Int($0) != nil }),
               let port = Int(parts.last ?? ""),
               (0...65535).contains(port) {
                token = parts.dropLast().map(String.init).joined(separator: ".")
            }
        }

        let sanitized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? nil : sanitized
    }

    /// 发送文件到指定设备
    public func sendFile(at url: URL, to deviceId: String, deviceName: String, ipAddress: String, port: Int = 8080) async throws {
        logger.info("📤 开始发送文件: \(url.lastPathComponent) 到设备: \(deviceName)")
        lastTransferActivityAt = Date()

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

        let securityContext: ClassicTransferSecurityContext
        if #available(macOS 14.0, iOS 17.0, *) {
            securityContext = try classicTransferSecurityContext(
                peerDeviceId: deviceId,
                ipAddress: ipAddress,
                transferId: transfer.id
            )
        } else {
            transfer.status = .failed
            transfer.completedAt = Date()
            transfer.error = FileTransferError.secureSessionRequired.localizedDescription
            moveToHistory(transfer)
            updateTransferringStatus()
            throw FileTransferError.secureSessionRequired
        }

        do {
 // 建立网络连接
            let connection = try await networkService.connectToDevice(
                ipAddress: ipAddress,
                port: port,
                deviceId: deviceId,
                deviceName: deviceName
            )
            defer {
                connection.cancel()
                networkService.disconnectFromDevice(deviceId)
            }

 // 计算文件哈希（用于完整性验证）
            transfer.fileHash = try await calculateFileHash(at: url)

 // 发送文件元数据
            try await sendFileMetadata(transfer, securityContext: securityContext, to: connection)

 // 分块发送文件
            try await sendFileInChunks(from: url, transfer: transfer, securityContext: securityContext, to: connection)

            // 必须等待接收端“落盘回执”，否则不能判定为成功（避免假阳性）
            let receipt = try await waitForTransferReceipt(
                from: connection,
                securityContext: securityContext,
                expectedTransferId: transfer.id,
                expectedFileSize: fileSize,
                expectedFileHash: transfer.fileHash
            )
            logger.info("✅ 接收端已确认落盘: transfer=\(receipt.transferId) bytes=\(receipt.receivedBytes)")

 // 标记传输完成
            transfer.status = .completed
            transfer.completedAt = Date()
            transfer.progress = 1.0

            logger.info("✅ 文件发送完成: \(fileName)")
            lastTransferActivityAt = Date()

 // 发送传输完成通知
            NotificationCenter.default.post(
                name: Notification.Name("FileTransferCompleted"),
                object: nil,
                userInfo: [
                    "transferId": transfer.id,
                    "fileName": fileName,
                    "fileSize": fileSize,
                    "deviceName": deviceName,
                    "direction": "outgoing",
                    "localPath": url.path
                ]
            )

        } catch {
            if shouldAttemptAutomaticOutgoingResume(for: error, transferredBytes: transfer.transferredBytes) {
                transfer.resumeOffset = transfer.transferredBytes
                await saveResumeData(for: transfer)

                do {
                    try await continueSendingFile(transfer, securityContext: securityContext)
                    lastTransferActivityAt = Date()
                    NotificationCenter.default.post(
                        name: Notification.Name("FileTransferCompleted"),
                        object: nil,
                        userInfo: [
                            "transferId": transfer.id,
                            "fileName": fileName,
                            "fileSize": fileSize,
                            "deviceName": deviceName,
                            "direction": "outgoing",
                            "localPath": url.path
                        ]
                    )
                    moveToHistory(transfer)
                    updateTransferringStatus()
                    return
                } catch {
                    logger.error("❌ 文件自动续传失败: \(fileName) - \(error.localizedDescription, privacy: .public)")
                }
            }

            transfer.status = .failed
            transfer.completedAt = Date()
            transfer.error = error.localizedDescription
            logger.error("❌ 文件发送失败: \(fileName) - \(error)")
            lastTransferActivityAt = Date()

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

            moveToHistory(transfer)
            updateTransferringStatus()
            throw error
        }

	 // 移动到历史记录
        moveToHistory(transfer)
        updateTransferringStatus()
    }

 /// 接收文件
    public func receiveFile(from connection: NWConnection, fallbackDeviceId: String, fallbackDeviceName: String) async throws {
        logger.info("📥 开始接收文件从设备: \(fallbackDeviceName)")

        isTransferring = true
        lastTransferActivityAt = Date()

        do {
            switch try await receiveInitialTransferMessage(from: connection) {
            case .resume(let request):
                try await handleResumeRequest(request, from: connection)
                updateTransferringStatus()
                return
            case .metadata(let metadata):
                try await receiveIncomingTransfer(
                    metadata: metadata,
                    from: connection,
                    fallbackDeviceId: fallbackDeviceId,
                    fallbackDeviceName: fallbackDeviceName
                )
                updateTransferringStatus()
                return
            }
        } catch {
            logger.error("❌ 文件接收失败: \(error)")
            lastTransferActivityAt = Date()
            updateTransferringStatus()
            throw error
        }
    }

    private func receiveIncomingTransfer(
        metadata: FileMetadata,
        from connection: NWConnection,
        fallbackDeviceId: String,
        fallbackDeviceName: String
    ) async throws {
        let effectiveDeviceId = metadata.senderDeviceId ?? fallbackDeviceId
        let effectiveDeviceName = metadata.senderDeviceName ?? fallbackDeviceName
        let securityContext: ClassicTransferSecurityContext
        if #available(macOS 14.0, iOS 17.0, *) {
            securityContext = try classicTransferSecurityContext(
                peerDeviceId: effectiveDeviceId,
                ipAddress: fallbackDeviceId,
                transferId: metadata.transferId
            )
        } else {
            throw FileTransferError.secureSessionRequired
        }

        guard isValidAuthenticationTag(
            metadata.metadataAuthTag,
            payload: metadataAuthenticationInput(metadata),
            key: securityContext.transferKey
        ) else {
            throw FileTransferError.secureSessionRequired
        }

        // File transfer may surface an ephemeral approval prompt, but must not synthesize
        // empty trust records from unauthenticated self-reported metadata.
        #if os(macOS)
        if #available(macOS 14.0, *) {
            if let declaredId = metadata.senderDeviceId, !declaredId.isEmpty {
                let alreadyTrusted = TrustSyncService.shared.activeTrustRecords.contains { $0.deviceId == declaredId && !$0.isTombstone }
                if !alreadyTrusted {
                    let request = PairingTrustApprovalService.Request(
                        peerEndpoint: effectiveDeviceId,
                        declaredDeviceId: declaredId,
                        displayName: metadata.senderDeviceName ?? effectiveDeviceName,
                        model: metadata.senderModelName,
                        platform: metadata.senderPlatform,
                        osVersion: metadata.senderOSVersion,
                        kemKeyCount: 0
                    )
                    let decision = await PairingTrustApprovalService.shared.decide(for: request)
                    if decision == .reject {
                        throw FileTransferError.transferCancelled
                    }
                }
            }
        }
        #endif

        let transfer = FileTransfer(
            id: metadata.transferId,
            fileName: sanitizeIncomingFileName(metadata.fileName),
            fileSize: metadata.fileSize,
            deviceId: effectiveDeviceId,
            direction: .incoming,
            status: .transferring
        )
        transfer.fileHash = metadata.fileHash
        transfer.compression = metadata.compression
        transfer.deviceName = effectiveDeviceName
        activeTransfers[transfer.id] = transfer

        let receivePath = uniqueReceiveFileURL(for: metadata.fileName)
        transfer.localPath = receivePath

        do {
 // 开始接收文件块
            try await receiveFileInChunks(
                to: receivePath,
                transfer: transfer,
                securityContext: securityContext,
                from: connection
            )

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

            logger.info("✅ 文件接收完成: \(transfer.fileName)")
            logger.info("📁 已保存到: \(receivePath.path, privacy: .public)")
            lastTransferActivityAt = Date()

            // 发送“落盘完成”回执给发送端，用于发送端成功判定
            let receipt = FileTransferReceipt(
                transferId: transfer.id,
                success: true,
                receivedBytes: metadata.fileSize,
                fileHash: receivedHash,
                error: nil,
                securityVersion: metadata.securityVersion,
                authTag: nil
            )
            do {
                try await sendTransferReceipt(receipt, securityContext: securityContext, to: connection)
            } catch {
                logger.error("⚠️ 发送落盘回执失败: \(error.localizedDescription, privacy: .public)")
            }

 // 发送接收完成通知
            NotificationCenter.default.post(
                name: Notification.Name("FileTransferCompleted"),
                object: nil,
                userInfo: [
                    "transferId": transfer.id,
                    "fileName": transfer.fileName,
                    "fileSize": metadata.fileSize,
                    "deviceName": effectiveDeviceName,
                    "direction": "incoming",
                    "localPath": receivePath.path
                ]
            )

            // Show a system notification so the user sees it even if they are not on the File Transfer page.
            #if canImport(UserNotifications)
            if Self.canUseUserNotificationsSafely() {
                let content = UNMutableNotificationContent()
                content.title = LocalizationManager.shared.localizedString("notifications.fileReceived.completed")
                content.subtitle = effectiveDeviceName
                // Use the actual resolved path to avoid confusion when a custom receive directory is set.
                content.body = String(
                    format: LocalizationManager.shared.localizedString("notifications.fileReceived.savedTo"),
                    locale: LocalizationManager.shared.locale,
                    transfer.fileName,
                    receivePath.path
                )
                content.userInfo = [
                    "transferId": transfer.id,
                    "localPath": receivePath.path
                ]
                let req = UNNotificationRequest(identifier: "file-transfer-\(transfer.id)", content: content, trigger: nil)
                Task {
                    _ = try? await UNUserNotificationCenter.current().add(req)
                }
            }
            #endif

        } catch {
            logger.error("❌ 文件接收失败: \(error)")
            lastTransferActivityAt = Date()

            if transfer.transferredBytes > 0, transfer.localPath != nil {
                transfer.resumeOffset = transfer.transferredBytes
                await saveResumeData(for: transfer)
            }
            transfer.status = .failed
            transfer.completedAt = Date()
            transfer.error = error.localizedDescription
            moveToHistory(transfer)

            // 失败路径也尽量回执，避免发送端长时间等待直到超时
            let failureReceipt = FileTransferReceipt(
                transferId: metadata.transferId,
                success: false,
                receivedBytes: 0,
                fileHash: nil,
                error: error.localizedDescription,
                securityVersion: metadata.securityVersion,
                authTag: nil
            )
            try? await sendTransferReceipt(failureReceipt, securityContext: securityContext, to: connection)

 // 发送接收失败通知
            NotificationCenter.default.post(
                name: Notification.Name("FileTransferFailed"),
                object: nil,
                userInfo: [
                    "transferId": metadata.transferId,
                    "fileName": transfer.fileName,
                    "error": error.localizedDescription,
                    "deviceName": effectiveDeviceName
                ]
            )

            throw error
        }

        updateTransferringStatus()
    }

    private func handleResumeRequest(_ request: ResumeRequestPayload, from connection: NWConnection) async throws {
        guard #available(macOS 14.0, iOS 17.0, *) else {
            throw FileTransferError.secureSessionRequired
        }

        let securityContext = try classicTransferSecurityContext(
            peerDeviceId: request.senderDeviceId,
            ipAddress: nil,
            transferId: request.transferId
        )
        let unsignedRequest = ResumeRequestPayload(
            transferId: request.transferId,
            senderDeviceId: request.senderDeviceId,
            resumeOffset: request.resumeOffset,
            securityVersion: request.securityVersion,
            authTag: Data()
        )
        guard isValidAuthenticationTag(
            request.authTag,
            payload: resumeRequestAuthenticationInput(unsignedRequest),
            key: securityContext.transferKey
        ) else {
            throw FileTransferError.secureSessionRequired
        }

        guard let resumeData = await loadResumeData(for: request.transferId),
              let localPath = resumeData["localPath"] as? String,
              !localPath.isEmpty,
              let fileSize = resumeData["fileSize"] as? Int64,
              let fileName = resumeData["fileName"] as? String,
              FileManager.default.fileExists(atPath: localPath) else {
            try await sendResumeAcknowledgment(
                transferId: request.transferId,
                accepted: false,
                resumeOffset: 0,
                error: "resume_state_unavailable",
                securityContext: securityContext,
                to: connection
            )
            throw FileTransferError.receiverRejected
        }

        let localURL = URL(fileURLWithPath: localPath)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: localPath)
        let onDiskBytes = min((fileAttributes[.size] as? Int64) ?? 0, fileSize)
        let acceptedOffset = min(max(0, request.resumeOffset), onDiskBytes)

        let transfer: FileTransfer = activeTransfers[request.transferId] ?? {
            let restored = FileTransfer(
                id: request.transferId,
                fileName: sanitizeIncomingFileName(fileName),
                fileSize: fileSize,
                deviceId: request.senderDeviceId,
                direction: .incoming,
                status: .transferring
            )
            restored.deviceName = resumeData["deviceName"] as? String
            restored.deviceIPAddress = resumeData["deviceIPAddress"] as? String
            restored.devicePort = resumeData["devicePort"] as? Int ?? 8080
            restored.localPath = localURL
            restored.fileHash = resumeData["fileHash"] as? String
            let compression = (resumeData["compression"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            restored.compression = compression?.isEmpty == true ? nil : compression
            restored.updateProgress(transferredBytes: acceptedOffset)
            activeTransfers[restored.id] = restored
            return restored
        }()

        transfer.resumeOffset = acceptedOffset
        transfer.updateProgress(transferredBytes: acceptedOffset)

        try await sendResumeAcknowledgment(
            transferId: request.transferId,
            accepted: true,
            resumeOffset: acceptedOffset,
            error: nil,
            securityContext: securityContext,
            to: connection
        )

        do {
            try await receiveFileInChunks(
                to: localURL,
                transfer: transfer,
                securityContext: securityContext,
                from: connection,
                startOffset: acceptedOffset
            )

            if let expectedHash = transfer.fileHash, !expectedHash.isEmpty {
                let receivedHash = try await calculateFileHash(at: localURL)
                guard receivedHash == expectedHash else {
                    throw FileTransferError.integrityCheckFailed
                }
            }

            transfer.status = .completed
            transfer.completedAt = Date()
            transfer.progress = 1.0
            lastTransferActivityAt = Date()
            moveToHistory(transfer)
            NotificationCenter.default.post(
                name: Notification.Name("FileTransferCompleted"),
                object: nil,
                userInfo: [
                    "transferId": transfer.id,
                    "fileName": transfer.fileName,
                    "fileSize": transfer.fileSize,
                    "deviceName": transfer.deviceName ?? transfer.deviceId,
                    "direction": "incoming",
                    "localPath": localURL.path
                ]
            )
            await cleanupResumeData(for: request.transferId)

            let receipt = FileTransferReceipt(
                transferId: request.transferId,
                success: true,
                receivedBytes: transfer.fileSize,
                fileHash: transfer.fileHash,
                error: nil,
                securityVersion: request.securityVersion,
                authTag: nil
            )
            try await sendTransferReceipt(receipt, securityContext: securityContext, to: connection)
        } catch {
            if transfer.transferredBytes > 0 {
                transfer.resumeOffset = transfer.transferredBytes
                await saveResumeData(for: transfer)
            }
            transfer.status = .failed
            transfer.completedAt = Date()
            transfer.error = error.localizedDescription
            moveToHistory(transfer)
            let failureReceipt = FileTransferReceipt(
                transferId: request.transferId,
                success: false,
                receivedBytes: transfer.transferredBytes,
                fileHash: nil,
                error: error.localizedDescription,
                securityVersion: request.securityVersion,
                authTag: nil
            )
            try? await sendTransferReceipt(failureReceipt, securityContext: securityContext, to: connection)
            throw error
        }
    }

    private func sendResumeAcknowledgment(
        transferId: String,
        accepted: Bool,
        resumeOffset: Int64,
        error: String?,
        securityContext: ClassicTransferSecurityContext,
        to connection: NWConnection
    ) async throws {
        let unsigned = ResumeAckPayload(
            transferId: transferId,
            accepted: accepted,
            resumeOffset: resumeOffset,
            error: error,
            securityVersion: 1,
            authTag: Data()
        )
        let ack = ResumeAckPayload(
            transferId: transferId,
            accepted: accepted,
            resumeOffset: resumeOffset,
            error: error,
            securityVersion: 1,
            authTag: authenticationTag(
                for: resumeAckAuthenticationInput(unsigned),
                using: securityContext.transferKey
            )
        )
        let payload = try JSONEncoder().encode(ack)
        try await sendData(createHeader(type: .resumeAck, length: payload.count) + payload, to: connection)
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
                "compression": transfer.compression ?? "",
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
    }

 /// 继续发送文件（从暂停点恢复）- 利用macOS 26.x的改进网络性能
    private func continueSendingFile(_ transfer: FileTransfer) async {
        do {
            if #available(macOS 14.0, iOS 17.0, *) {
                let securityContext = try classicTransferSecurityContext(
                    peerDeviceId: transfer.deviceId,
                    ipAddress: transfer.deviceIPAddress,
                    transferId: transfer.id
                )
                try await continueSendingFile(transfer, securityContext: securityContext)
            } else {
                throw FileTransferError.secureSessionRequired
            }
        } catch {
            logger.error("恢复发送文件失败: \(error)")
            transfer.status = .failed
            transfer.error = error.localizedDescription
        }
    }

    private func continueSendingFile(
        _ transfer: FileTransfer,
        securityContext: ClassicTransferSecurityContext
    ) async throws {
        guard let localPath = transfer.localPath else {
            throw FileTransferError.fileNotFound
        }

        guard let ipAddress = transfer.deviceIPAddress, !ipAddress.isEmpty else {
            throw FileTransferError.invalidHeader
        }

        logger.info("🔄 恢复发送文件: \(transfer.fileName) (从 \(transfer.resumeOffset) 字节继续)")

 // 重新建立连接
        let connection = try await networkService.connectToDevice(
            ipAddress: ipAddress,
            port: transfer.devicePort,
            deviceId: transfer.deviceId,
            deviceName: transfer.deviceName ?? "Unknown Device"
        )
        defer {
            connection.cancel()
            networkService.disconnectFromDevice(transfer.deviceId)
        }

        let localDeviceId = await SelfIdentityProvider.shared.snapshot().deviceId
        // 发送断点续传请求（包含已传输字节数）
        try await sendResumeRequest(
            transferId: transfer.id,
            senderDeviceId: localDeviceId,
            resumeOffset: transfer.resumeOffset,
            securityContext: securityContext,
            to: connection
        )

        // 等待接收端确认实际偏移
        let acceptedOffset = try await waitForResumeAcknowledgment(
            transferId: transfer.id,
            securityContext: securityContext,
            from: connection
        )
        transfer.resumeOffset = acceptedOffset
        transfer.updateProgress(transferredBytes: acceptedOffset)

        // 从断点继续分块传输
        try await sendFileInChunks(
            from: localPath,
            transfer: transfer,
            securityContext: securityContext,
            to: connection,
            startOffset: acceptedOffset
        )

        let receipt = try await waitForTransferReceipt(
            from: connection,
            securityContext: securityContext,
            expectedTransferId: transfer.id,
            expectedFileSize: transfer.fileSize,
            expectedFileHash: transfer.fileHash
        )
        logger.info("✅ 接收端已确认恢复传输落盘: transfer=\(receipt.transferId) bytes=\(receipt.receivedBytes)")

        transfer.status = .completed
        transfer.completedAt = Date()
        transfer.progress = 1.0
        await cleanupResumeData(for: transfer.id)
        logger.info("✅ 文件发送恢复完成: \(transfer.fileName)")
    }

 /// 发送断点续传请求
    private func sendResumeRequest(
        transferId: String,
        senderDeviceId: String,
        resumeOffset: Int64,
        securityContext: ClassicTransferSecurityContext,
        to connection: NWConnection
    ) async throws {
        let unsigned = ResumeRequestPayload(
            transferId: transferId,
            senderDeviceId: senderDeviceId,
            resumeOffset: resumeOffset,
            securityVersion: 1,
            authTag: Data()
        )
        let authTag = authenticationTag(
            for: resumeRequestAuthenticationInput(unsigned),
            using: securityContext.transferKey
        )
        let request = ResumeRequestPayload(
            transferId: transferId,
            senderDeviceId: senderDeviceId,
            resumeOffset: resumeOffset,
            securityVersion: 1,
            authTag: authTag
        )
        let payload = try JSONEncoder().encode(request)
        try await sendData(createHeader(type: .resumeRequest, length: payload.count) + payload, to: connection)
        logger.debug("📤 发送断点续传请求: transferId=\(transferId), offset=\(resumeOffset)")
    }

 /// 等待断点续传确认
    private func waitForResumeAcknowledgment(
        transferId: String,
        securityContext: ClassicTransferSecurityContext,
        from connection: NWConnection
    ) async throws -> Int64 {
        let headerData = try await receiveData(length: 8, from: connection)
        let header = parseHeader(headerData)
        guard header.type == .resumeAck, header.length > 0, header.length <= maxMessageBytes else {
            throw FileTransferError.invalidHeader
        }
        let payload = try await receiveData(length: header.length, from: connection)
        let ack = try JSONDecoder().decode(ResumeAckPayload.self, from: payload)
        guard ack.transferId == transferId else {
            throw FileTransferError.invalidHeader
        }
        guard isValidAuthenticationTag(
            ack.authTag,
            payload: resumeAckAuthenticationInput(ResumeAckPayload(
                transferId: ack.transferId,
                accepted: ack.accepted,
                resumeOffset: ack.resumeOffset,
                error: ack.error,
                securityVersion: ack.securityVersion,
                authTag: Data()
            )),
            key: securityContext.transferKey
        ) else {
            throw FileTransferError.secureSessionRequired
        }
        guard ack.accepted else {
            throw FileTransferError.receiverRejected
        }
        logger.debug("✅ 断点续传确认已收到: offset=\(ack.resumeOffset)")
        return ack.resumeOffset
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

            guard #available(macOS 14.0, iOS 17.0, *) else {
                throw FileTransferError.secureSessionRequired
            }
            let securityContext = try classicTransferSecurityContext(
                peerDeviceId: transfer.deviceId,
                ipAddress: ipAddress,
                transferId: transfer.id
            )

 // 重新建立连接
            let connection = try await networkService.connectToDevice(
                ipAddress: ipAddress,
                port: transfer.devicePort,
                deviceId: transfer.deviceId,
                deviceName: transfer.deviceName ?? "Unknown Device"
            )
            defer {
                connection.cancel()
                networkService.disconnectFromDevice(transfer.deviceId)
            }

            let localDeviceId = await SelfIdentityProvider.shared.snapshot().deviceId
 // 发送断点续传请求
            try await sendResumeRequest(
                transferId: transfer.id,
                senderDeviceId: localDeviceId,
                resumeOffset: transfer.resumeOffset,
                securityContext: securityContext,
                to: connection
            )

 // 等待服务器确认
            let acceptedOffset = try await waitForResumeAcknowledgment(
                transferId: transfer.id,
                securityContext: securityContext,
                from: connection
            )

 // 从断点继续接收数据
            try await receiveFileInChunks(
                to: localPath,
                transfer: transfer,
                securityContext: securityContext,
                from: connection,
                startOffset: acceptedOffset
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
        persistTransferHistory(removeWhenEmpty: true)
        logger.info("🗑️ 清理传输历史记录")
    }

 // MARK: - 私有方法

 /// 获取文件大小
    private func getFileSize(at url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return attributes[.size] as? Int64 ?? 0
    }

    private enum InitialTransferMessage {
        case metadata(FileMetadata)
        case resume(ResumeRequestPayload)
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
    private func receiveInitialTransferMessage(from connection: NWConnection) async throws -> InitialTransferMessage {
        let headerData = try await receiveData(length: 8, from: connection)
        let header = parseHeader(headerData)
        guard header.length >= 0, header.length <= maxMessageBytes else {
            throw FileTransferError.invalidHeader
        }

        let payload = try await receiveData(length: header.length, from: connection)
        switch header.type {
        case .metadata:
            return .metadata(try JSONDecoder().decode(FileMetadata.self, from: payload))
        case .resumeRequest:
            return .resume(try JSONDecoder().decode(ResumeRequestPayload.self, from: payload))
        default:
            throw FileTransferError.invalidHeader
        }
    }

    private func sendFileMetadata(
        _ transfer: FileTransfer,
        securityContext: ClassicTransferSecurityContext,
        to connection: NWConnection
    ) async throws {
        // 记录本次传输使用的压缩算法，便于断点续传/解压路径复用
        transfer.compression = compressionEnabled ? "zlib" : nil

        var senderDeviceId: String? = nil
        var senderDeviceName: String? = nil
        var senderPlatform: String? = nil
        var senderOSVersion: String? = nil
        var senderModelName: String? = nil
        let senderChip: String? = nil
        #if os(macOS)
        if #available(macOS 14.0, *) {
            let snap = await SelfIdentityProvider.shared.snapshot()
            senderDeviceId = snap.deviceId
            senderDeviceName = Host.current().localizedName
            senderPlatform = "macOS"
            senderOSVersion = ProcessInfo.processInfo.operatingSystemVersionString
            senderModelName = "Mac"
        }
        #endif
        let unsignedMetadata = FileMetadata(
            transferId: transfer.id,
            fileName: transfer.fileName,
            fileSize: transfer.fileSize,
            fileHash: transfer.fileHash ?? "",
            chunkSize: chunkSize,
            securityVersion: 1,
            metadataAuthTag: nil,
            compression: transfer.compression,
            senderDeviceId: senderDeviceId,
            senderDeviceName: senderDeviceName,
            senderPlatform: senderPlatform,
            senderOSVersion: senderOSVersion,
            senderModelName: senderModelName,
            senderChip: senderChip
        )
        let metadata = FileMetadata(
            transferId: unsignedMetadata.transferId,
            fileName: unsignedMetadata.fileName,
            fileSize: unsignedMetadata.fileSize,
            fileHash: unsignedMetadata.fileHash,
            chunkSize: unsignedMetadata.chunkSize,
            securityVersion: unsignedMetadata.securityVersion,
            metadataAuthTag: authenticationTag(
                for: metadataAuthenticationInput(unsignedMetadata),
                using: securityContext.transferKey
            ),
            compression: unsignedMetadata.compression,
            senderDeviceId: unsignedMetadata.senderDeviceId,
            senderDeviceName: unsignedMetadata.senderDeviceName,
            senderPlatform: unsignedMetadata.senderPlatform,
            senderOSVersion: unsignedMetadata.senderOSVersion,
            senderModelName: unsignedMetadata.senderModelName,
            senderChip: unsignedMetadata.senderChip
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
        logger.info("📋 文件元数据头已到达: type=\(header.type.rawValue, privacy: .public) length=\(header.length, privacy: .public)")

        guard header.type == .metadata else {
            throw FileTransferError.invalidHeader
        }
        guard header.length >= 0, header.length <= maxMessageBytes else {
            throw FileTransferError.invalidHeader
        }

 // 接收元数据
        let metadataData = try await receiveData(length: header.length, from: connection)
        let metadata = try JSONDecoder().decode(FileMetadata.self, from: metadataData)
        if metadata.chunkSize > maxChunkSizeBytes {
            throw FileTransferError.invalidHeader
        }

        logger.info("📋 接收文件元数据: \(metadata.fileName)")
        return metadata
    }

 /// 分块发送文件 - 支持断点续传
    private func sendFileInChunks(
        from url: URL,
        transfer: FileTransfer,
        securityContext: ClassicTransferSecurityContext,
        to connection: NWConnection,
        startOffset: Int64 = 0
    ) async throws {
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer {
            fileHandle.closeFile()
            clearSpeedLimitState(for: transfer.id)
        }

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

            // 可选：压缩（通过 metadata.compression 协商；发送端以当前 compressionEnabled 决定）
            let payload: Data
            if compressionEnabled {
                payload = (try? compressData(chunkData)) ?? chunkData
            } else {
                payload = chunkData
            }
            let encrypted = try encryptChunkPayload(payload, using: securityContext.transferKey)

 // 创建文件块
            let chunk = FileChunk(
                index: chunkIndex,
                data: encrypted.ciphertext,
                size: chunkData.count,
                nonce: encrypted.nonce,
                authenticationTag: encrypted.tag
            )

 // 发送文件块
            try await sendFileChunk(chunk, to: connection)
            await applySpeedLimitIfNeeded(for: transfer.id, transferredBytes: chunkData.count)

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
        securityContext: ClassicTransferSecurityContext,
        from connection: NWConnection,
        startOffset: Int64 = 0
    ) async throws {
 // 创建或打开文件（如果存在则追加）
        if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        }

        let fileHandle = try FileHandle(forWritingTo: url)
        defer {
            fileHandle.closeFile()
            clearSpeedLimitState(for: transfer.id)
        }

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
            await applySpeedLimitIfNeeded(for: transfer.id, transferredBytes: chunk.size)

 // 写入文件
            fileHandle.seek(toFileOffset: UInt64(receivedBytes))
            // 可选：解压（通过 sendFileMetadata 的 compression 字段协商）
            let decrypted = try decryptChunkPayload(
                ciphertext: chunk.data,
                nonce: chunk.nonce,
                tag: chunk.authenticationTag,
                using: securityContext.transferKey
            )
            let bytesToWrite: Data
            if transfer.compression == "zlib" {
                bytesToWrite = try decompressData(decrypted)
            } else {
                bytesToWrite = decrypted
            }
            guard bytesToWrite.count == chunk.size, bytesToWrite.count <= maxChunkSizeBytes else {
                throw FileTransferError.invalidHeader
            }

            fileHandle.write(bytesToWrite)

            // receivedBytes 以“原始字节数”推进（chunk.size 是未压缩大小；与 fileSize 对齐）
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
        guard header.length >= 0, header.length <= maxMessageBytes else {
            throw FileTransferError.invalidHeader
        }

 // 接收块数据
        let chunkData = try await receiveData(length: header.length, from: connection)
        let chunk = try JSONDecoder().decode(FileChunk.self, from: chunkData)
        if chunk.size < 0 || chunk.size > maxChunkSizeBytes {
            throw FileTransferError.invalidHeader
        }
        guard let nonce = chunk.nonce, nonce.count == 12,
              let tag = chunk.authenticationTag, !tag.isEmpty else {
            throw FileTransferError.invalidHeader
        }
        return chunk
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

    /// 发送端等待接收端“落盘回执”
    private func waitForTransferReceipt(
        from connection: NWConnection,
        securityContext: ClassicTransferSecurityContext,
        expectedTransferId: String,
        expectedFileSize: Int64,
        expectedFileHash: String?
    ) async throws -> FileTransferReceipt {
        let headerData = try await receiveData(length: 8, from: connection, timeout: 15)
        let header = parseHeader(headerData)
        guard header.type == .receipt else {
            throw FileTransferError.receiverNotConfirmed
        }
        guard header.length > 0, header.length <= maxMessageBytes else {
            throw FileTransferError.invalidHeader
        }

        let payload = try await receiveData(length: header.length, from: connection, timeout: 15)
        let receipt = try JSONDecoder().decode(FileTransferReceipt.self, from: payload)
        let unsignedReceipt = FileTransferReceipt(
            transferId: receipt.transferId,
            success: receipt.success,
            receivedBytes: receipt.receivedBytes,
            fileHash: receipt.fileHash,
            error: receipt.error,
            securityVersion: receipt.securityVersion,
            authTag: nil
        )
        guard receipt.transferId == expectedTransferId else {
            throw FileTransferError.invalidHeader
        }
        guard isValidAuthenticationTag(
            receipt.authTag,
            payload: receiptAuthenticationInput(unsignedReceipt),
            key: securityContext.transferKey
        ) else {
            throw FileTransferError.secureSessionRequired
        }
        guard receipt.success else {
            logger.error("❌ 接收端拒绝传输: \(receipt.error ?? "unknown", privacy: .public)")
            throw FileTransferError.receiverRejected
        }
        guard receipt.receivedBytes == expectedFileSize else {
            logger.error("❌ 接收端字节数不一致: expected=\(expectedFileSize) got=\(receipt.receivedBytes)")
            throw FileTransferError.receiverNotConfirmed
        }

        if let expectedFileHash, !expectedFileHash.isEmpty,
           let peerHash = receipt.fileHash, !peerHash.isEmpty,
           peerHash.lowercased() != expectedFileHash.lowercased() {
            logger.error("❌ 接收端哈希不一致: expected=\(expectedFileHash, privacy: .public) got=\(peerHash, privacy: .public)")
            throw FileTransferError.integrityCheckFailed
        }

        return receipt
    }

    /// 接收端发送落盘回执
    private func sendTransferReceipt(
        _ receipt: FileTransferReceipt,
        securityContext: ClassicTransferSecurityContext,
        to connection: NWConnection
    ) async throws {
        let unsignedReceipt = FileTransferReceipt(
            transferId: receipt.transferId,
            success: receipt.success,
            receivedBytes: receipt.receivedBytes,
            fileHash: receipt.fileHash,
            error: receipt.error,
            securityVersion: receipt.securityVersion ?? 1,
            authTag: nil
        )
        let signedReceipt = FileTransferReceipt(
            transferId: unsignedReceipt.transferId,
            success: unsignedReceipt.success,
            receivedBytes: unsignedReceipt.receivedBytes,
            fileHash: unsignedReceipt.fileHash,
            error: unsignedReceipt.error,
            securityVersion: unsignedReceipt.securityVersion,
            authTag: authenticationTag(
                for: receiptAuthenticationInput(unsignedReceipt),
                using: securityContext.transferKey
            )
        )
        let payload = try JSONEncoder().encode(signedReceipt)
        let header = createHeader(type: .receipt, length: payload.count)
        try await sendData(header + payload, to: connection)
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
    private func receiveData(length: Int, from connection: NWConnection, timeout: TimeInterval? = nil) async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            final class Once: @unchecked Sendable {
                private let lock = NSLock()
                private var didResume = false
                func run(_ block: () -> Void) {
                    lock.lock()
                    defer { lock.unlock() }
                    guard !didResume else { return }
                    didResume = true
                    block()
                }
            }
            let once = Once()
            final class Accumulator: @unchecked Sendable {
                private let lock = NSLock()
                private var storage = Data()

                func append(_ data: Data) {
                    lock.lock()
                    storage.append(data)
                    lock.unlock()
                }

                func count() -> Int {
                    lock.lock()
                    defer { lock.unlock() }
                    return storage.count
                }

                func snapshot() -> Data {
                    lock.lock()
                    defer { lock.unlock() }
                    return storage
                }
            }
            let accumulator = Accumulator()

            if let timeout, timeout > 0 {
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                    once.run {
                        continuation.resume(throwing: FileTransferError.timeout)
                    }
                }
            }

            @Sendable func receiveMore() {
                let remaining = max(1, length - accumulator.count())
                connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, isComplete, error in
                    if let error = error {
                        once.run {
                            continuation.resume(throwing: error)
                        }
                        return
                    }
                    if let data, !data.isEmpty {
                        accumulator.append(data)
                    }
                    if accumulator.count() == length {
                        let completed = accumulator.snapshot()
                        once.run {
                            continuation.resume(returning: completed)
                        }
                        return
                    }
                    if isComplete {
                        once.run {
                            continuation.resume(throwing: FileTransferError.connectionClosed)
                        }
                        return
                    }
                    receiveMore()
                }
            }

            receiveMore()
        }
    }

    private func metadataAuthenticationInput(_ metadata: FileMetadata) -> Data {
        [
            metadata.transferId,
            metadata.fileName,
            String(metadata.fileSize),
            metadata.fileHash,
            String(metadata.chunkSize),
            String(metadata.securityVersion ?? 0),
            metadata.compression ?? "",
            metadata.senderDeviceId ?? "",
            metadata.senderDeviceName ?? "",
            metadata.senderPlatform ?? "",
            metadata.senderOSVersion ?? "",
            metadata.senderModelName ?? "",
            metadata.senderChip ?? ""
        ].joined(separator: "|").data(using: .utf8) ?? Data()
    }

    private func receiptAuthenticationInput(_ receipt: FileTransferReceipt) -> Data {
        [
            receipt.transferId,
            receipt.success ? "1" : "0",
            String(receipt.receivedBytes),
            receipt.fileHash ?? "",
            receipt.error ?? "",
            String(receipt.securityVersion ?? 0)
        ].joined(separator: "|").data(using: .utf8) ?? Data()
    }

    private func resumeRequestAuthenticationInput(_ request: ResumeRequestPayload) -> Data {
        [
            request.transferId,
            request.senderDeviceId,
            String(request.resumeOffset),
            String(request.securityVersion)
        ].joined(separator: "|").data(using: .utf8) ?? Data()
    }

    private func resumeAckAuthenticationInput(_ ack: ResumeAckPayload) -> Data {
        [
            ack.transferId,
            ack.accepted ? "1" : "0",
            String(ack.resumeOffset),
            ack.error ?? "",
            String(ack.securityVersion)
        ].joined(separator: "|").data(using: .utf8) ?? Data()
    }

    private func authenticationTag(for payload: Data, using key: SymmetricKey) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: payload, using: key))
    }

    private func isValidAuthenticationTag(_ tag: Data?, payload: Data, key: SymmetricKey) -> Bool {
        guard let tag else { return false }
        return authenticationTag(for: payload, using: key) == tag
    }

    private func encryptChunkPayload(_ plaintext: Data, using key: SymmetricKey) throws -> (ciphertext: Data, nonce: Data, tag: Data) {
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
        return (
            ciphertext: sealed.ciphertext,
            nonce: Data(nonce),
            tag: sealed.tag
        )
    }

    private func decryptChunkPayload(ciphertext: Data, nonce: Data?, tag: Data?, using key: SymmetricKey) throws -> Data {
        guard let nonce, let tag else {
            throw FileTransferError.invalidHeader
        }
        let sealed = try AES.GCM.SealedBox(
            nonce: try AES.GCM.Nonce(data: nonce),
            ciphertext: ciphertext,
            tag: tag
        )
        return try AES.GCM.open(sealed, using: key)
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

    private func sanitizeIncomingFileName(_ raw: String) -> String {
        FileTransferPathPolicy.sanitizedFileName(raw)
    }

    private func uniqueReceiveFileURL(for fileName: String, existingURL: URL? = nil) -> URL {
        if let existingURL {
            return existingURL
        }

        let baseDir = receiveBaseDirectory ?? Self.defaultReceiveDirectory()
        let skyBridgeFolder = baseDir
        try? FileManager.default.createDirectory(at: skyBridgeFolder, withIntermediateDirectories: true)

        return FileTransferPathPolicy.uniqueDestinationURL(
            baseDirectory: skyBridgeFolder,
            fileName: fileName
        )
    }

    private static func defaultReceiveDirectory() -> URL {
        let base = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        return base.appendingPathComponent("SkyBridge", isDirectory: true)
    }

    private func resolvedWritableReceiveDirectory(from preferred: URL?) -> URL {
        if let preferred, ensureWritableDirectory(at: preferred) {
            return preferred
        }

        let fallback = Self.defaultReceiveDirectory()
        _ = ensureWritableDirectory(at: fallback)
        return fallback
    }

    @discardableResult
    private func ensureWritableDirectory(at url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return FileManager.default.isWritableFile(atPath: url.path)
        } catch {
            logger.warning("⚠️ 无法使用接收目录 \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - External (non-NWConnection) transfers (WebRTC DataChannel)

    /// WebRTC 入站：创建一个“外部传输”的接收记录（用于 UI 展示与统计）。
    public func beginExternalInboundTransfer(
        transferId: String,
        fileName: String,
        fileSize: Int64,
        fromDeviceId: String,
        fromDeviceName: String?
    ) {
        if activeTransfers[transferId] != nil { return }

        let transfer = FileTransfer(
            id: transferId,
            fileName: fileName,
            fileSize: fileSize,
            deviceId: fromDeviceId,
            direction: .incoming,
            status: .preparing
        )
        transfer.deviceName = fromDeviceName
        activeTransfers[transferId] = transfer
        updateTransferringStatus()
    }

    /// WebRTC 入站：更新接收进度（由 CrossNetworkConnectionManager 推送）。
    public func updateExternalInboundProgress(transferId: String, transferredBytes: Int64) {
        guard let transfer = activeTransfers[transferId] else { return }
        transfer.status = .transferring
        transfer.updateProgress(transferredBytes: transferredBytes)
        lastTransferActivityAt = Date()
        postTransferProgressNotification(for: transfer)
        updateTransferringStatus()
    }

    /// WebRTC 入站：完成并落盘后调用。
    public func completeExternalInboundTransfer(transferId: String, savedTo url: URL) {
        guard let transfer = activeTransfers[transferId] else { return }
        transfer.status = .completed
        transfer.progress = 1.0
        transfer.completedAt = Date()
        transfer.localPath = url
        lastTransferActivityAt = Date()
        moveToHistory(transfer)
        postTransferCompletedNotification(for: transfer, direction: "incoming", localPath: url.path)
        updateTransferringStatus()
    }

    public func failExternalTransfer(transferId: String, errorMessage: String) {
        guard let transfer = activeTransfers[transferId] else { return }
        transfer.status = .failed
        transfer.error = errorMessage
        transfer.completedAt = Date()
        lastTransferActivityAt = Date()
        moveToHistory(transfer)
        postTransferFailedNotification(for: transfer, errorMessage: errorMessage)
        updateTransferringStatus()
    }

    /// WebRTC 出站：创建一个“外部传输”的发送记录（用于 UI 展示与统计）。
    public func beginExternalOutboundTransfer(
        transferId: String,
        fileURL: URL,
        fileSize: Int64,
        toDeviceId: String,
        toDeviceName: String?
    ) {
        if activeTransfers[transferId] != nil { return }

        let transfer = FileTransfer(
            id: transferId,
            fileName: fileURL.lastPathComponent,
            fileSize: fileSize,
            deviceId: toDeviceId,
            direction: .outgoing,
            status: .preparing
        )
        transfer.localPath = fileURL
        transfer.deviceName = toDeviceName
        activeTransfers[transferId] = transfer
        updateTransferringStatus()
    }

    public func updateExternalOutboundProgress(transferId: String, transferredBytes: Int64) {
        guard let transfer = activeTransfers[transferId] else { return }
        transfer.status = .transferring
        transfer.updateProgress(transferredBytes: transferredBytes)
        lastTransferActivityAt = Date()
        postTransferProgressNotification(for: transfer)
        updateTransferringStatus()
    }

    public func completeExternalOutboundTransfer(transferId: String) {
        guard let transfer = activeTransfers[transferId] else { return }
        transfer.status = .completed
        transfer.progress = 1.0
        transfer.completedAt = Date()
        lastTransferActivityAt = Date()
        moveToHistory(transfer)
        postTransferCompletedNotification(for: transfer, direction: "outgoing", localPath: transfer.localPath?.path)
        updateTransferringStatus()
    }

    public func failExternalOutboundTransfer(transferId: String, errorMessage: String) {
        failExternalTransfer(transferId: transferId, errorMessage: errorMessage)
    }

 /// 移动到历史记录
    private func moveToHistory(_ transfer: FileTransfer) {
        activeTransfers.removeValue(forKey: transfer.id)
        transferHistory.append(transfer)

 // 限制历史记录数量
        if transferHistory.count > 100 {
            transferHistory.removeFirst()
        }
        persistTransferHistory()
    }

    private func loadPersistedHistory() {
        guard let persisted = historyStore.load() else {
            transferHistory = []
            return
        }
        transferHistory = persisted.map(\.asRuntimeTransfer)
        logger.info("📚 已恢复传输历史记录: \(self.transferHistory.count, privacy: .public) 条")
    }

    private func persistTransferHistory(removeWhenEmpty: Bool = false) {
        if transferHistory.isEmpty, removeWhenEmpty {
            do {
                try historyStore.remove()
            } catch {
                logger.error("❌ 删除传输历史持久化文件失败: \(error.localizedDescription, privacy: .public)")
            }
            return
        }

        let persisted = transferHistory.map(PersistedFileTransferHistoryEntry.init)
        do {
            try historyStore.save(persisted)
        } catch {
            logger.error("❌ 持久化传输历史失败: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func postTransferProgressNotification(for transfer: FileTransfer) {
        let progress = max(0.0, min(1.0, transfer.progress))
        let transferredBytes = Int64(Double(transfer.fileSize) * progress)
        let userInfo: [String: Any] = [
            "transferId": transfer.id,
            "fileName": transfer.fileName,
            "progress": progress,
            "speed": 0.0,
            "transferredBytes": transferredBytes,
            "fileSize": transfer.fileSize,
            "deviceName": transfer.deviceName ?? transfer.deviceId
        ]
        NotificationCenter.default.post(
            name: Notification.Name("com.skybridge.fileTransfer.progressUpdated"),
            object: nil,
            userInfo: userInfo
        )
    }

    private func postTransferCompletedNotification(
        for transfer: FileTransfer,
        direction: String,
        localPath: String?
    ) {
        var userInfo: [String: Any] = [
            "transferId": transfer.id,
            "fileName": transfer.fileName,
            "fileSize": transfer.fileSize,
            "deviceName": transfer.deviceName ?? transfer.deviceId,
            "direction": direction
        ]
        if let localPath, !localPath.isEmpty {
            userInfo["localPath"] = localPath
        }

        NotificationCenter.default.post(
            name: Notification.Name("FileTransferCompleted"),
            object: nil,
            userInfo: userInfo
        )
        NotificationCenter.default.post(
            name: Notification.Name("com.skybridge.fileTransfer.completed"),
            object: nil,
            userInfo: userInfo
        )

        #if canImport(UserNotifications)
        if direction == "incoming", Self.canUseUserNotificationsSafely() {
            let content = UNMutableNotificationContent()
            content.title = LocalizationManager.shared.localizedString("notifications.fileReceived.completed")
            content.subtitle = transfer.deviceName ?? transfer.deviceId
            if let localPath, !localPath.isEmpty {
                content.body = String(
                    format: LocalizationManager.shared.localizedString("notifications.fileReceived.savedTo"),
                    locale: LocalizationManager.shared.locale,
                    transfer.fileName,
                    localPath
                )
            } else {
                content.body = String(
                    format: LocalizationManager.shared.localizedString("notifications.fileReceived.completedBody"),
                    locale: LocalizationManager.shared.locale,
                    transfer.fileName
                )
            }
            content.userInfo = userInfo
            let request = UNNotificationRequest(
                identifier: "file-transfer-\(transfer.id)",
                content: content,
                trigger: nil
            )
            Task {
                _ = try? await UNUserNotificationCenter.current().add(request)
            }
        }
        #endif
    }

    private func postTransferFailedNotification(for transfer: FileTransfer, errorMessage: String) {
        let userInfo: [String: Any] = [
            "transferId": transfer.id,
            "fileName": transfer.fileName,
            "error": errorMessage,
            "deviceName": transfer.deviceName ?? transfer.deviceId
        ]
        NotificationCenter.default.post(
            name: Notification.Name("FileTransferFailed"),
            object: nil,
            userInfo: userInfo
        )
        NotificationCenter.default.post(
            name: Notification.Name("com.skybridge.fileTransfer.failed"),
            object: nil,
            userInfo: userInfo
        )
    }

 /// 更新传输状态
    private func updateTransferringStatus() {
        // Base signal: we are transferring iff there are active transfers.
        if !activeTransfers.isEmpty {
            isTransferring = true
            activityGraceTask?.cancel()
            activityGraceTask = nil
        } else {
            // Grace period: keep isTransferring true briefly after completion so the dashboard has time to show it.
            if let last = lastTransferActivityAt {
                let elapsed = Date().timeIntervalSince(last)
                if elapsed < transferActivityGraceSeconds {
                    isTransferring = true
                    // Re-evaluate after the remaining grace window.
                    activityGraceTask?.cancel()
                    let remaining = transferActivityGraceSeconds - elapsed
                    activityGraceTask = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(remaining))
                        self.updateTransferringStatus()
                    }
                } else {
                    isTransferring = false
                }
            } else {
                isTransferring = false
            }
        }

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

struct PersistedFileTransferHistoryEntry: Codable, Sendable {
    let id: String
    let fileName: String
    let fileSize: Int64
    let deviceId: String
    let direction: TransferDirection
    let createdAt: Date
    let status: TransferStatus
    let progress: Double
    let transferredBytes: Int64
    let transferSpeed: Double
    let estimatedTimeRemaining: TimeInterval
    let networkQuality: NetworkQuality
    let averageSpeed: Double
    let peakSpeed: Double
    let completedAt: Date?
    let error: String?
    let fileHash: String?
    let localPath: URL?
    let compression: String?
    let scanResult: FileScanResult?
    let deviceIPAddress: String?
    let devicePort: Int
    let deviceName: String?
    let resumeOffset: Int64
    let resumeDataPath: URL?

    init(_ transfer: FileTransfer) {
        self.id = transfer.id
        self.fileName = transfer.fileName
        self.fileSize = transfer.fileSize
        self.deviceId = transfer.deviceId
        self.direction = transfer.direction
        self.createdAt = transfer.createdAt
        self.status = transfer.status
        self.progress = transfer.progress
        self.transferredBytes = transfer.transferredBytes
        self.transferSpeed = transfer.transferSpeed
        self.estimatedTimeRemaining = transfer.estimatedTimeRemaining
        self.networkQuality = transfer.networkQuality
        self.averageSpeed = transfer.averageSpeed
        self.peakSpeed = transfer.peakSpeed
        self.completedAt = transfer.completedAt
        self.error = transfer.error
        self.fileHash = transfer.fileHash
        self.localPath = transfer.localPath
        self.compression = transfer.compression
        self.scanResult = transfer.scanResult
        self.deviceIPAddress = transfer.deviceIPAddress
        self.devicePort = transfer.devicePort
        self.deviceName = transfer.deviceName
        self.resumeOffset = transfer.resumeOffset
        self.resumeDataPath = transfer.resumeDataPath
    }

    var asRuntimeTransfer: FileTransfer {
        let transfer = FileTransfer(
            id: id,
            fileName: fileName,
            fileSize: fileSize,
            deviceId: deviceId,
            direction: direction,
            status: status,
            createdAt: createdAt
        )
        transfer.progress = progress
        transfer.transferredBytes = transferredBytes
        transfer.transferSpeed = transferSpeed
        transfer.estimatedTimeRemaining = estimatedTimeRemaining
        transfer.networkQuality = networkQuality
        transfer.averageSpeed = averageSpeed
        transfer.peakSpeed = peakSpeed
        transfer.completedAt = completedAt
        transfer.error = error
        transfer.fileHash = fileHash
        transfer.localPath = localPath
        transfer.compression = compression
        transfer.scanResult = scanResult
        transfer.deviceIPAddress = deviceIPAddress
        transfer.devicePort = devicePort
        transfer.deviceName = deviceName
        transfer.resumeOffset = resumeOffset
        transfer.resumeDataPath = resumeDataPath
        return transfer
    }
}

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
    /// 压缩算法：nil/"" 表示不压缩；当前支持 "zlib"
    public var compression: String?

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

    public init(
        id: String,
        fileName: String,
        fileSize: Int64,
        deviceId: String,
        direction: TransferDirection,
        status: TransferStatus,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.fileName = fileName
        self.fileSize = fileSize
        self.deviceId = deviceId
        self.direction = direction
        self.status = status
        self.createdAt = createdAt
        self.lastUpdateTime = createdAt
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
public enum NetworkQuality: String, CaseIterable, Codable, Sendable {
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
    let securityVersion: Int?
    let metadataAuthTag: Data?
    /// 压缩算法：nil/"" 表示不压缩；当前支持 "zlib"
    let compression: String?

    // Sender metadata (optional; used for UI + trust flow)
    let senderDeviceId: String?
    let senderDeviceName: String?
    let senderPlatform: String?
    let senderOSVersion: String?
    let senderModelName: String?
    let senderChip: String?
}

/// 文件块
private struct FileChunk: Codable {
    let index: Int
    let data: Data
    let size: Int
    let nonce: Data?
    let authenticationTag: Data?
}

/// 传输完成回执（接收端 -> 发送端）
private struct FileTransferReceipt: Codable {
    let transferId: String
    let success: Bool
    let receivedBytes: Int64
    let fileHash: String?
    let error: String?
    let securityVersion: Int?
    let authTag: Data?
}

private struct ResumeRequestPayload: Codable {
    let transferId: String
    let senderDeviceId: String
    let resumeOffset: Int64
    let securityVersion: Int
    let authTag: Data
}

private struct ResumeAckPayload: Codable {
    let transferId: String
    let accepted: Bool
    let resumeOffset: Int64
    let error: String?
    let securityVersion: Int
    let authTag: Data
}

/// 传输方向
public enum TransferDirection: String, CaseIterable, Codable, Sendable {
    case incoming = "接收"
    case outgoing = "发送"
}

/// 传输状态
public enum TransferStatus: String, CaseIterable, Codable, Sendable {
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
    case receipt = 4
    case resumeRequest = 5
    case resumeAck = 6
    case unknown = 0
}

/// 文件传输错误
public enum FileTransferError: Error, LocalizedError {
    case invalidHeader
    case integrityCheckFailed
    case transferCancelled
    case connectionClosed
    case fileNotFound
    case timeout
    case receiverNotConfirmed
    case receiverRejected
    case secureSessionRequired

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
        case .timeout:
            return "等待超时"
        case .receiverNotConfirmed:
            return "接收端未确认文件已落盘"
        case .receiverRejected:
            return "接收端拒绝或处理失败"
        case .secureSessionRequired:
            return "经典文件传输需要已认证的安全会话"
        }
    }
}

// MARK: - Data扩展（支持resize操作）
// 注意：resize方法已在FileTransferEngine.swift中定义，避免重复声明

// MARK: - Compression helpers (zlib)

extension FileTransferManager {
    /// zlib 压缩（可选；失败则抛错，调用方可选择 fallback）
    fileprivate func compressData(_ data: Data) throws -> Data {
        return try (data as NSData).compressed(using: .zlib) as Data
    }

    /// zlib 解压（用于与 iOS 端 compression=zlib 协商）
    fileprivate func decompressData(_ data: Data) throws -> Data {
        return try (data as NSData).decompressed(using: .zlib) as Data
    }
}
