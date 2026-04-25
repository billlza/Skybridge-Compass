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

public extension Notification.Name {
    static let connectableDeviceDiscovered = Notification.Name("ConnectableDeviceDiscovered")
    static let fileTransferStarted = Notification.Name("FileTransferStarted")
    static let fileTransferProgress = Notification.Name("FileTransferProgress")
    static let fileTransferCompleted = Notification.Name("FileTransferCompleted")
    static let fileTransferFailed = Notification.Name("FileTransferFailed")
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
    AppleMobileDeviceIdentity.currentSnapshot().modelName
}

private func SBFT_currentChipDisplayName() -> String {
    AppleMobileDeviceIdentity.currentSnapshot().chip
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
    case timeout
    case receiptWaitFailed(stage: FileTransferReceiptWaitStage, details: String?)
    case encryptionFailed
    case secureSessionRequired

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
        case .receiptWaitFailed(let stage, let details):
            let suffix = details.map { ": \($0)" } ?? ""
            return "等待接收端落盘回执失败(\(stage.rawValue))\(suffix)"
        case .encryptionFailed: return "加密失败"
        case .secureSessionRequired: return "需要已认证的安全会话"
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
    private static let historyStore = CodablePersistenceStore<[FileTransfer]>(
        location: .protectedApplicationSupport(
            path: "FileTransfer/history.json",
            legacyUserDefaultsKey: "transfer_history"
        )
    )
    
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
    private let receiptWaitTimeoutSeconds: TimeInterval = 60

    private struct ClassicTransferSecurityContext {
        let transferKey: SymmetricKey
        let matchDeviceId: String
        let resolvedPeerDeviceId: String
        let matchedBy: ClassicTransferPeerResolutionBranch
        let declaredCandidates: [String]
        let endpointCandidates: [String]
    }

    struct ClassicTransferAuthenticatedPeerCandidate: Sendable, Equatable {
        let matchDeviceId: String
        let resolvedPeerDeviceId: String
        let aliases: [String]
        let endpointHostOrIP: String?
        let capabilities: [String]
    }

    enum ClassicTransferPeerResolutionBranch: String, Sendable, Equatable {
        case declaredSenderDeviceId = "declared_sender_device_id"
        case aliasOrCanonicalDeviceId = "alias_or_canonical_device_id"
        case endpointHostOrIP = "endpoint_host_or_ip"
        case singleAuthenticatedFallback = "single_authenticated_fallback"
    }

    struct ClassicTransferPeerResolutionOutcome: Sendable, Equatable {
        let matchDeviceId: String
        let resolvedPeerDeviceId: String
        let matchedBy: ClassicTransferPeerResolutionBranch
        let declaredCandidates: [String]
        let endpointCandidates: [String]
    }

    private var inFlightTransferCount: Int = 0
    private struct TransferWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    enum TransferSlotReleaseAction: Equatable {
        case decrementTo(Int)
        case resumeWaiter(nextInFlightCount: Int)
    }
    private var transferWaiters: [TransferWaiter] = []
    private var lastProgressEventAtByTransferId: [String: Date] = [:]
    private var lastProgressEventPercentByTransferId: [String: Int] = [:]
    private let progressEventMinInterval: TimeInterval = 0.25
    private let progressEventMinStepPercent: Int = 2
    
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
        try await acquireTransferSlot()
        defer { releaseTransferSlot() }

        try await FileTransferRuntime.shared.ensureHealthy()

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
        postInAppTransferEvent(name: "FileTransferStarted", transfer: transfer)

        // 创建传输状态
        var state = TransferState(transferId: transfer.id)
        state.localURL = url
        state.startTime = Date()
        let localIdentity = AppleMobileDeviceIdentity.currentSnapshot()
        let senderDeviceId = Self.preferredClassicTransferSenderDeviceId(
            stableDeviceId: localIdentity.stableDeviceId,
            vendorDeviceId: localIdentity.vendorDeviceId
        )
        let senderDeviceName = localIdentity.deviceName
        let senderPlatform = localIdentity.platformName
        let senderOSVersion = localIdentity.osVersion
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
            if shouldUseCrossNetworkTransport(for: device) {
                try await sendFileOverWebRTC(from: url, transfer: transfer, metadata: state.metadata!, to: device)
                await completeTransfer(transfer.id, success: true)
                SkyBridgeLogger.shared.info("✅ 文件发送完成(WebRTC): \(fileName)")
                return
            }
            
            // 建立连接：优先 Bonjour service（不依赖 IP/默认端口）
            //
            // ⚠️ 重要：activeConnections 里的 `DiscoveredDevice` 有时是“连接时快照”，services/ip 可能不完整。
            // 这里尝试用发现管理器的最新记录补全（尤其是 `_skybridge-transfer._tcp`）。
            let resolvedDevice = resolveLatestTransferDevice(from: device)

            let endpoints = try await makeTransferEndpointCandidates(for: resolvedDevice)

            let connection = try await createConnection(toAnyOf: endpoints)
            defer { connection.cancel() }
            transferStates[transfer.id]?.connection = connection

            let securityContext = try classicTransferSecurityContext(
                peerContext: FileTransferPeerContext(
                    declaredSenderDeviceId: resolvedDevice.id,
                    endpointHostOrIP: resolvedDevice.ipAddress,
                    peerLabel: resolvedDevice.name,
                    transferId: transfer.id
                )
            )

            // 发送元数据
            try await sendMetadata(
                state.metadata!,
                securityContext: securityContext,
                over: connection
            )

            // 分块发送文件
            try await sendFileInChunks(
                from: url,
                transfer: transfer,
                securityContext: securityContext,
                over: connection,
                chunkSize: effectiveChunkSize
            )

            // 必须等待接收端“落盘回执”，否则不能标记发送成功
            _ = try await waitForTransferReceipt(
                over: connection,
                securityContext: securityContext,
                expectedTransferId: transfer.id,
                expectedFileSize: fileSize,
                expectedFileHash: fileHash
            )

            // 完成传输
            await completeTransfer(transfer.id, success: true)
            
            SkyBridgeLogger.shared.info("✅ 文件发送完成: \(fileName)")
            
        } catch {
            await completeTransfer(transfer.id, success: false, error: error)
            throw error
        }
    }

    // MARK: - Cross-network (WebRTC DataChannel) send

    func preferredQuickSendDevice(for device: DiscoveredDevice) -> DiscoveredDevice {
        resolveLatestTransferDevice(from: device)
    }

    private func resolveLatestTransferDevice(from device: DiscoveredDevice) -> DiscoveredDevice {
        var discovered = DeviceDiscoveryManager.instance.discoveredDevices
        discovered.append(contentsOf: connectionManager.activeConnections.map(\.device))
        let peerResolved = connectionManager.resolvedPeerDevice(for: device)
        if !discovered.contains(where: { Self.areEquivalentTransferDevices($0, peerResolved) }) {
            discovered.insert(peerResolved, at: 0)
        }
        if let canonical = DeviceDiscoveryManager.instance.canonicalDiscoveredDevice(for: device),
           !discovered.contains(where: { Self.areEquivalentTransferDevices($0, canonical) }) {
            discovered.insert(canonical, at: 0)
        }

        var resolved = Self.resolveBestTransferDevice(target: device, discovered: discovered)
        if shouldUseUniqueTransferCandidateFallback(for: resolved, original: device) {
            let platformHint = resolved.platform != .unknown ? resolved.platform : device.platform
            let uniqueTransferCandidates = discovered.filter { candidate in
                (Self.hasExplicitLANTransferService(candidate) || candidate.fileTransferPort != nil)
                    && (platformHint == .unknown || candidate.platform == platformHint)
            }
            if uniqueTransferCandidates.count == 1, let only = uniqueTransferCandidates.first {
                resolved = preferredTransferDevice(resolved, only)
            }
        }
        if resolved.id != device.id
            || resolved.bonjourServiceType != device.bonjourServiceType
            || resolved.portMap != device.portMap {
            SkyBridgeLogger.shared.info(
                "📡 文件传输目标已补全: target=\(device.name) original=\(device.id) resolved=\(resolved.id) services=\(resolved.services.joined(separator: ",")) portMap=\(resolved.portMap)"
            )
        }
        return resolved
    }

    private func makeTransferEndpointCandidates(for device: DiscoveredDevice) async throws -> [NWEndpoint] {
        let transferServiceType = DiscoveredDevice.fileTransferServiceType
        let explicitTransferPort = preferredTransferPort(for: device)
        let hasActivePeerSession = activePeerSessionExists(for: device)
        var endpoints: [NWEndpoint] = []
        var seen = Set<String>()

        if let bonjour = transferBonjourServiceIdentity(for: device) {
            appendTransferEndpoint(
                .service(
                    name: bonjour.name,
                    type: transferServiceType,
                    domain: bonjour.domain,
                    interface: nil
                ),
                to: &endpoints,
                seen: &seen
            )
        }

        if let ip = bestIPAddress(for: device), let port = explicitTransferPort {
            appendTransferEndpoint(
                .hostPort(host: .init(ip), port: .init(integerLiteral: port)),
                to: &endpoints,
                seen: &seen
            )
        }

        if let resolvedIP = await resolveTransferIPAddress(for: device),
           let port = explicitTransferPort {
            SkyBridgeLogger.shared.info(
                "📡 文件传输已解析到主服务地址: name=\(device.name) ip=\(resolvedIP) port=\(port)"
            )
            appendTransferEndpoint(
                .hostPort(host: .init(resolvedIP), port: .init(integerLiteral: port)),
                to: &endpoints,
                seen: &seen
            )
        }

        if hasActivePeerSession,
           let activePeerIP = activePeerTransferAddress(for: device) {
            if let port = explicitTransferPort {
                SkyBridgeLogger.shared.warning(
                    "⚠️ 文件传输目标缺少独立服务公告，已基于活跃 P2P 会话回退到显式端口 \(port): name=\(device.name) ip=\(activePeerIP)"
                )
                appendTransferEndpoint(
                    .hostPort(
                        host: .init(activePeerIP),
                        port: .init(integerLiteral: port)
                    ),
                    to: &endpoints,
                    seen: &seen
                )
            } else {
                SkyBridgeLogger.shared.warning(
                    "⚠️ 文件传输目标缺少独立端口，拒绝猜测默认端口: name=\(device.name) ip=\(activePeerIP)"
                )
            }
        }

        if !endpoints.isEmpty {
            return endpoints
        }

        if device.supportsFileTransfer, let resolvedIP = await resolveTransferIPAddress(for: device) {
            SkyBridgeLogger.shared.warning(
                "⚠️ 文件传输目标仅声明能力但未提供独立端口，拒绝猜测默认端口: name=\(device.name) ip=\(resolvedIP)"
            )
        }

        if device.supportsFileTransfer {
            throw FileTransferError.transferFailed("设备未声明独立文件传输端点，已拒绝对默认 8080 端口进行猜测连接")
        }

        throw FileTransferError.invalidDestination
    }

    private func appendTransferEndpoint(
        _ endpoint: NWEndpoint,
        to endpoints: inout [NWEndpoint],
        seen: inout Set<String>
    ) {
        let key = String(describing: endpoint)
        guard seen.insert(key).inserted else { return }
        endpoints.append(endpoint)
    }

    private func hasAdvertisedTransferService(for device: DiscoveredDevice) -> Bool {
        transferBonjourServiceIdentity(for: device) != nil
    }

    private func preferredTransferPort(for device: DiscoveredDevice) -> UInt16? {
        for candidate in transferIdentityCandidates(for: device) {
            if let port = candidate.fileTransferPort, port > 0 {
                return port
            }
        }
        return nil
    }

    private func activePeerTransferAddress(for device: DiscoveredDevice) -> String? {
        for candidate in transferIdentityCandidates(for: device) {
            if let activePeerIP = connectionManager.activePeerHostAddress(for: candidate) {
                return activePeerIP
            }
        }
        return nil
    }

    private func activePeerSessionExists(for device: DiscoveredDevice) -> Bool {
        if connectionManager.resolvedConnectionStatus(for: device) == .connected {
            return true
        }

        let resolvedDevice = connectionManager.resolvedPeerDevice(for: device)
        let targetAliases = Set(PeerIdentityAliasResolver.aliasKeys(for: resolvedDevice))
            .union(PeerIdentityAliasResolver.aliasKeys(for: device))

        guard !targetAliases.isEmpty else { return false }
        return connectionManager.activeConnections.contains { connection in
            let candidateAliases = Set(PeerIdentityAliasResolver.aliasKeys(for: connection.device))
            return !candidateAliases.isDisjoint(with: targetAliases)
        }
    }

    private func shouldUseCrossNetworkTransport(for device: DiscoveredDevice) -> Bool {
        let localActiveConnectionDeviceIds = Set(connectionManager.activeConnections.map(\.device.id))
        return Self.shouldPreferCrossNetworkTransfer(
            targetDeviceId: device.id,
            crossNetworkState: crossNetwork.state,
            crossNetworkRemoteDeviceId: crossNetwork.remoteDeviceId,
            localActiveConnectionDeviceIds: localActiveConnectionDeviceIds
        )
    }

    static func shouldPreferCrossNetworkTransfer(
        targetDeviceId: String,
        crossNetworkState: CrossNetworkWebRTCManager.State,
        crossNetworkRemoteDeviceId: String?,
        localActiveConnectionDeviceIds: Set<String>
    ) -> Bool {
        guard case .connected = crossNetworkState else { return false }

        let normalizedTarget = normalizedTransferIdentity(targetDeviceId)
        guard !normalizedTarget.isEmpty else { return false }

        let normalizedRemote = normalizedTransferIdentity(crossNetworkRemoteDeviceId)
        guard normalizedRemote == normalizedTarget else { return false }

        let normalizedLocalActiveIds = Set(localActiveConnectionDeviceIds.map(normalizedTransferIdentity))
        return !normalizedLocalActiveIds.contains(normalizedTarget)
    }

    static func resolveBestTransferDevice(
        target: DiscoveredDevice,
        discovered: [DiscoveredDevice]
    ) -> DiscoveredDevice {
        let targetScore = transferResolutionScore(candidate: target, target: target)
        let bestCandidate = discovered.max { lhs, rhs in
            let left = transferResolutionScore(candidate: lhs, target: target)
            let right = transferResolutionScore(candidate: rhs, target: target)
            if left != right { return left < right }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedDescending
        }

        guard let bestCandidate else { return target }
        let bestScore = transferResolutionScore(candidate: bestCandidate, target: target)
        return bestScore > targetScore ? bestCandidate : target
    }

    private static func areEquivalentTransferDevices(
        _ lhs: DiscoveredDevice,
        _ rhs: DiscoveredDevice
    ) -> Bool {
        if lhs.id == rhs.id {
            return true
        }

        let lhsAliases = Set(PeerIdentityAliasResolver.aliasKeys(for: lhs))
        let rhsAliases = Set(PeerIdentityAliasResolver.aliasKeys(for: rhs))
        return !lhsAliases.isEmpty && !rhsAliases.isEmpty && !lhsAliases.isDisjoint(with: rhsAliases)
    }

    private static func transferResolutionScore(candidate: DiscoveredDevice, target: DiscoveredDevice) -> Int {
        let targetIdentity = normalizedTransferIdentity(target.id)
        let candidateIdentity = normalizedTransferIdentity(candidate.id)
        let exactIdMatch = !targetIdentity.isEmpty && targetIdentity == candidateIdentity
        let stableExactIdMatch = exactIdMatch && isStableTransferIdentity(candidate.id)

        let targetIP = bestTransferIPAddress(for: target)
        let candidateIP = bestTransferIPAddress(for: candidate)
        let ipMatch = targetIP != nil && targetIP == candidateIP

        let targetBonjour = bonjourIdentityComponents(for: target)
        let candidateBonjour = bonjourIdentityComponents(for: candidate)
        let bonjourMatch = targetBonjour != nil && targetBonjour == candidateBonjour

        let targetName = normalizedTransferDeviceName(target.name)
        let candidateName = normalizedTransferDeviceName(candidate.name)
        let nameMatch = !targetName.isEmpty && targetName == candidateName

        let targetAliases = Set(PeerIdentityAliasResolver.aliasKeys(for: target))
        let candidateAliases = Set(PeerIdentityAliasResolver.aliasKeys(for: candidate))
        let aliasMatch = !targetAliases.isEmpty && !candidateAliases.isDisjoint(with: targetAliases)

        guard exactIdMatch || ipMatch || bonjourMatch || nameMatch || aliasMatch else {
            return 0
        }

        var score = 0
        if stableExactIdMatch {
            score += 300
        } else if exactIdMatch {
            score += 80
        }
        if ipMatch { score += 250 }
        if bonjourMatch { score += 220 }
        if nameMatch { score += 160 }
        if aliasMatch { score += 260 }

        if candidate.services.contains(DiscoveredDevice.fileTransferServiceType)
            || candidate.bonjourServiceType == DiscoveredDevice.fileTransferServiceType {
            score += 240
        }
        if candidate.fileTransferPort != nil { score += 160 }
        if candidateIP != nil { score += 120 }
        if !candidate.services.isEmpty { score += 40 }

        return score
    }

    private static func isStableTransferIdentity(_ raw: String?) -> Bool {
        let normalized = normalizedTransferIdentity(raw)
        guard !normalized.isEmpty else {
            return false
        }
        return !(normalized.hasPrefix("host:")
            || normalized.hasPrefix("peer:")
            || normalized.hasPrefix("bonjour:")
            || normalized.hasPrefix("recent:"))
    }

    private static func normalizedTransferIdentity(_ raw: String?) -> String {
        raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }

    private static func normalizedTransferDeviceName(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
    }

    private static func bonjourIdentityComponents(for device: DiscoveredDevice) -> String? {
        let name = device.bonjourServiceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let domain = device.bonjourServiceDomain?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name, !name.isEmpty {
            let normalizedDomain = (domain?.isEmpty == false ? domain! : "local.")
            return "\(name.lowercased())@\(normalizedDomain.lowercased())"
        }

        if let parsed = parseTransferBonjourIdentity(from: device.id) {
            return "\(parsed.name.lowercased())@\(parsed.domain.lowercased())"
        }

        return nil
    }

    private static func parseTransferBonjourIdentity(from identifier: String) -> (name: String, domain: String)? {
        guard identifier.hasPrefix("bonjour:") else { return nil }
        let payload = String(identifier.dropFirst("bonjour:".count))
        let parts = payload.split(separator: "@", maxSplits: 1).map(String.init)
        guard let name = parts.first, !name.isEmpty else { return nil }
        let domain = parts.count > 1 ? parts[1] : "local."
        return (name, domain)
    }

    private static func bestTransferIPAddress(for device: DiscoveredDevice) -> String? {
        sanitizeTransferAddress(device.ipAddress)
            ?? sanitizeTransferAddress(addressFromTransferIdentifier(device.id))
    }

    private static func addressFromTransferIdentifier(_ identifier: String) -> String? {
        if identifier.hasPrefix("host:") {
            return String(identifier.dropFirst("host:".count))
        }
        if identifier.hasPrefix("peer:") {
            return String(identifier.dropFirst("peer:".count))
        }
        return nil
    }

    private static func sanitizeTransferAddress(_ raw: String?) -> String? {
        ConnectableAddressCanonicalizer.lookupKey(raw)
    }

    private func preferredTransferDevice(_ lhs: DiscoveredDevice, _ rhs: DiscoveredDevice) -> DiscoveredDevice {
        transferDeviceScore(rhs) > transferDeviceScore(lhs) ? rhs : lhs
    }

    private func shouldUseUniqueTransferCandidateFallback(
        for device: DiscoveredDevice,
        original: DiscoveredDevice
    ) -> Bool {
        if Self.hasExplicitLANTransferService(device) || device.fileTransferPort != nil {
            return false
        }
        guard activePeerSessionExists(for: device) || activePeerSessionExists(for: original) else {
            return false
        }
        if device.id.hasPrefix("host:") || device.id.hasPrefix("peer:") {
            return true
        }
        if Self.sanitizeTransferAddress(device.name) != nil {
            return true
        }
        return normalizeDeviceName(device.name).contains(":")
    }

    static func hasExplicitLANTransferService(_ device: DiscoveredDevice) -> Bool {
        device.services.contains(DiscoveredDevice.fileTransferServiceType)
            || device.bonjourServiceType == DiscoveredDevice.fileTransferServiceType
    }

    private func preferredTransferServiceName(for device: DiscoveredDevice) -> String? {
        transferBonjourServiceIdentity(for: device)?.name
    }

    private func transferBonjourServiceIdentity(for device: DiscoveredDevice) -> (name: String, domain: String)? {
        for candidate in transferIdentityCandidates(for: device) {
            let hasTransferServiceEvidence = candidate.bonjourServiceType == DiscoveredDevice.fileTransferServiceType
                || candidate.services.contains(DiscoveredDevice.fileTransferServiceType)
                || candidate.id.hasPrefix("bonjour:")

            guard hasTransferServiceEvidence else { continue }

            if let bonjourServiceName = candidate.bonjourServiceName,
               isPlausibleServiceInstanceName(bonjourServiceName) {
                let domain = candidate.bonjourServiceDomain?.trimmingCharacters(in: .whitespacesAndNewlines)
                return (
                    name: bonjourServiceName.trimmingCharacters(in: .whitespacesAndNewlines),
                    domain: domain?.isEmpty == false ? domain! : "local."
                )
            }
            if let parsed = parseBonjourIdentity(from: candidate.id),
               isPlausibleServiceInstanceName(parsed.name) {
                return (name: parsed.name.trimmingCharacters(in: .whitespacesAndNewlines), domain: parsed.domain)
            }
        }
        return nil
    }

    private func preferredTransferServiceDomain(for device: DiscoveredDevice) -> String {
        for candidate in transferIdentityCandidates(for: device) {
            if let domain = candidate.bonjourServiceDomain?.trimmingCharacters(in: .whitespacesAndNewlines),
               !domain.isEmpty {
                return domain
            }
            if let parsed = parseBonjourIdentity(from: candidate.id) {
                return parsed.domain
            }
        }
        return "local."
    }

    private func transferIdentityCandidates(for device: DiscoveredDevice) -> [DiscoveredDevice] {
        var candidates: [DiscoveredDevice] = []

        func append(_ candidate: DiscoveredDevice?) {
            guard let candidate else { return }
            if candidates.contains(where: { Self.areEquivalentTransferDevices($0, candidate) }) {
                return
            }
            candidates.append(candidate)
        }

        append(device)
        append(connectionManager.resolvedPeerDevice(for: device))
        append(DeviceDiscoveryManager.instance.canonicalDiscoveredDevice(for: device))
        for active in connectionManager.activeConnections.map(\.device) where Self.areEquivalentTransferDevices(active, device) {
            append(active)
        }
        return candidates
    }

    private func isPlausibleServiceInstanceName(_ raw: String?) -> Bool {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return false
        }
        let lowercased = raw.lowercased()
        if lowercased == "unknown device" || lowercased == "未知设备" {
            return false
        }
        if lowercased.hasPrefix("id:")
            || lowercased.hasPrefix("host:")
            || lowercased.hasPrefix("peer:")
            || lowercased.hasPrefix("recent:") {
            return false
        }
        if UUID(uuidString: raw) != nil {
            return false
        }
        if let sanitized = sanitizeAddress(raw),
           sanitized == lowercased || sanitized == raw {
            return false
        }
        return true
    }

    private func transferDeviceScore(_ device: DiscoveredDevice) -> Int {
        var score = 0
        if device.services.contains(DiscoveredDevice.fileTransferServiceType)
            || device.bonjourServiceType == DiscoveredDevice.fileTransferServiceType {
            score += 120
        }
        if bestIPAddress(for: device) != nil {
            score += 80
        }
        if let serviceName = device.bonjourServiceName, !serviceName.isEmpty {
            score += 40
        }
        if !device.services.isEmpty {
            score += 20
        }
        if !normalizeDeviceName(device.name).isEmpty {
            score += 10
        }
        return score
    }

    private func normalizeDeviceName(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
    }

    private func parseBonjourIdentity(from identifier: String) -> (name: String, domain: String)? {
        guard identifier.hasPrefix("bonjour:") else { return nil }
        let payload = String(identifier.dropFirst("bonjour:".count))
        let parts = payload.split(separator: "@", maxSplits: 1).map(String.init)
        guard let name = parts.first, !name.isEmpty else { return nil }
        let domain = parts.count > 1 ? parts[1] : "local."
        return (name, domain)
    }

    private func bestIPAddress(for device: DiscoveredDevice) -> String? {
        sanitizeAddress(device.ipAddress)
            ?? sanitizeAddress(addressFromIdentifier(device.id))
    }

    private func resolveTransferIPAddress(for device: DiscoveredDevice) async -> String? {
        var candidates: [DiscoveredDevice] = []

        func append(_ candidate: DiscoveredDevice?) {
            guard let candidate else { return }
            if candidates.contains(where: { Self.areEquivalentTransferDevices($0, candidate) }) {
                return
            }
            candidates.append(candidate)
        }

        append(device)
        append(connectionManager.resolvedPeerDevice(for: device))
        append(DeviceDiscoveryManager.instance.canonicalDiscoveredDevice(for: device))
        append(resolveLatestTransferDevice(from: device))

        for candidate in candidates {
            if let ip = bestIPAddress(for: candidate) {
                return ip
            }
            if let activePeerIP = connectionManager.activePeerHostAddress(for: candidate),
               let sanitized = sanitizeAddress(activePeerIP) {
                return sanitized
            }
            if let resolved = await DeviceDiscoveryManager.instance.resolveEndpoint(candidate),
               let sanitized = sanitizeAddress(resolved) {
                return sanitized
            }
        }

        return nil
    }

    private func addressFromIdentifier(_ identifier: String) -> String? {
        if identifier.hasPrefix("host:") {
            return String(identifier.dropFirst("host:".count))
        }
        if identifier.hasPrefix("peer:") {
            return String(identifier.dropFirst("peer:".count))
        }
        return nil
    }

    private func sanitizeAddress(_ raw: String?) -> String? {
        ConnectableAddressCanonicalizer.connectionTarget(raw)
    }

    private func sendFileOverWebRTC(
        from url: URL,
        transfer: FileTransfer,
        metadata: FileMetadata,
        to device: DiscoveredDevice
    ) async throws {
        // Use a smaller chunk size for DataChannel to keep per-message size stable.
        let dcChunkSize = min(64 * 1024, max(8 * 1024, metadata.chunkSize))
        let totalChunks = Int(ceil(Double(metadata.fileSize) / Double(dcChunkSize)))
        
        let senderIdentity = AppleMobileDeviceIdentity.currentSnapshot()
        let senderDeviceId = senderIdentity.stableDeviceId
        let senderDeviceName: String? = senderIdentity.deviceName
        
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
        var fileHasher = SHA256()
        
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
            fileHasher.update(data: chunkData)
            
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
        
        let fileSha256 = Data(fileHasher.finalize())
        let done = CrossNetworkFileTransferMessage(
            op: .complete,
            transferId: transfer.id,
            receivedBytes: metadata.fileSize,
            fileSha256: fileSha256
        )
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
    func receiveFile(
        metadata: FileMetadata,
        from connection: NWConnection,
        peerContext: FileTransferPeerContext
    ) async throws -> URL {
        try await acquireTransferSlot()
        defer { releaseTransferSlot() }

        let peer = peerContext.peerLabel ?? peerContext.endpointHostOrIP ?? metadata.senderDeviceId ?? "Unknown"
        SkyBridgeLogger.shared.info("📥 开始接收文件: \(metadata.fileName) 从设备: \(peer)")
        if metadata.chunkSize > maxChunkSizeBytes {
            throw FileTransferError.invalidMetadata
        }

        let targetURL = makeUniqueDestinationURL(fileName: metadata.fileName)

        // 创建传输记录
        let transfer = FileTransfer(
            id: metadata.transferId,
            fileName: metadata.fileName,
            fileSize: metadata.fileSize,
            fileType: determineFileType(fromName: metadata.fileName),
            isIncoming: true,
            remotePeer: peer,
            localPath: targetURL.path
        )

        activeTransfers.append(transfer)
        isTransferring = true
        postInAppTransferEvent(name: "FileTransferStarted", transfer: transfer)
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

        var resolvedSecurityContext: ClassicTransferSecurityContext?

        do {
            let securityContext = try classicTransferSecurityContext(
                peerContext: peerContext
            )
            resolvedSecurityContext = securityContext

            let unsignedMetadata = unsignedMetadataCopy(from: metadata)
            guard isValidAuthenticationTag(
                metadata.metadataAuthTag,
                payload: metadataAuthenticationInput(unsignedMetadata),
                key: securityContext.transferKey
            ) else {
                throw FileTransferError.secureSessionRequired
            }

            // 分块接收文件
            try await receiveFileInChunks(
                to: targetURL,
                transfer: transfer,
                securityContext: securityContext,
                from: connection,
                metadata: metadata
            )

            logClassicReceiptPhase("hash_verification_started", transferId: transfer.id)
            let receivedHash = try await calculateFileHash(at: targetURL)
            logClassicReceiptPhase("hash_verification_completed", transferId: transfer.id)
            guard receivedHash == metadata.fileHash else {
                throw FileTransferError.checksumMismatch
            }

            // 向发送端发送落盘回执（失败不影响本地已完成结果）
            let receipt = TransferReceipt(
                transferId: metadata.transferId,
                success: true,
                receivedBytes: metadata.fileSize,
                fileHash: receivedHash,
                securityVersion: metadata.securityVersion
            )
            do {
                try await sendReceiptReliably(
                    receipt,
                    securityContext: securityContext,
                    over: connection
                )
            } catch {
                SkyBridgeLogger.shared.error("⚠️ 落盘回执发送失败: \(error.localizedDescription)")
            }

            // 完成传输
            await completeTransfer(transfer.id, success: true)

            SkyBridgeLogger.shared.info("✅ 文件接收完成: \(metadata.fileName)")
            
            return targetURL

        } catch {
            if let securityContext = resolvedSecurityContext {
                await sendFailureReceiptIfPossible(
                    transferId: metadata.transferId,
                    securityVersion: metadata.securityVersion,
                    error: error,
                    securityContext: securityContext,
                    over: connection
                )
            } else {
                SkyBridgeLogger.shared.error(
                    "⚠️ failure receipt 未发送: transferId=\(metadata.transferId) reason=no_security_context declaredSenderId=\(peerContext.declaredSenderDeviceId ?? "-") endpointHostOrIP=\(peerContext.endpointHostOrIP ?? "-")"
                )
            }
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
        clearProgressEventState(for: transferId)

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

    /// 解析当前仍然有效的本地文件 URL。
    /// 历史记录里的 `localPath` 可能来自旧的 iOS 沙盒容器路径；若路径失效，则回退到当前 Downloads 目录按文件名恢复。
    public func resolveExistingLocalFileURL(for transfer: FileTransfer) -> URL? {
        let safeFileName = (transfer.fileName as NSString).lastPathComponent
        let currentDownloadsURL = downloadsDirectory.appendingPathComponent(safeFileName, isDirectory: false)

        let candidates: [URL] = {
            var urls: [URL] = []
            if let localPath = transfer.localPath, !localPath.isEmpty {
                urls.append(URL(fileURLWithPath: localPath))
            }
            urls.append(currentDownloadsURL)
            return urls
        }()

        for candidate in candidates where fileManager.fileExists(atPath: candidate.path) {
            if transfer.localPath != candidate.path {
                upsertLocalPath(candidate.path, for: transfer.id)
            }
            return candidate
        }

        guard let contents = try? fileManager.contentsOfDirectory(
            at: downloadsDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return nil
        }

        let expectedStem = (safeFileName as NSString).deletingPathExtension
        let expectedExt = (safeFileName as NSString).pathExtension.lowercased()

        if let recovered = contents.first(where: { url in
            let candidateName = url.lastPathComponent
            let candidateStem = (candidateName as NSString).deletingPathExtension
            let candidateExt = (candidateName as NSString).pathExtension.lowercased()
            return candidateStem == expectedStem && candidateExt == expectedExt
        }) {
            upsertLocalPath(recovered.path, for: transfer.id)
            return recovered
        }

        return nil
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
    private func sendFileInChunks(
        from url: URL,
        transfer: FileTransfer,
        securityContext: ClassicTransferSecurityContext,
        over connection: NWConnection,
        chunkSize: Int
    ) async throws {
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
            let encrypted = try encryptChunkPayload(
                processedData,
                using: securityContext.transferKey
            )

            // 计算分块校验和
            let chunkChecksum = SHA256.hash(data: chunkData).compactMap { String(format: "%02x", $0) }.joined()

            // 创建分块
            let chunk = FileChunk(
                index: chunkIndex,
                data: encrypted.ciphertext,
                size: chunkData.count,
                checksum: chunkChecksum,
                nonce: encrypted.nonce,
                authenticationTag: encrypted.tag
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
        logClassicReceiptPhase("all_chunks_sent", transferId: transfer.id)
    }
    
    /// 发送元数据
    private func sendMetadata(
        _ metadata: FileMetadata,
        securityContext: ClassicTransferSecurityContext,
        over connection: NWConnection
    ) async throws {
        let unsignedMetadata = unsignedMetadataCopy(
            from: metadata,
            securityVersion: metadata.securityVersion ?? 1
        )
        let signedMetadata = FileMetadata(
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
            mimeType: unsignedMetadata.mimeType,
            compression: unsignedMetadata.compression,
            totalChunks: unsignedMetadata.totalChunks,
            resumeOffset: unsignedMetadata.resumeOffset,
            senderDeviceId: unsignedMetadata.senderDeviceId,
            senderDeviceName: unsignedMetadata.senderDeviceName,
            senderPlatform: unsignedMetadata.senderPlatform,
            senderOSVersion: unsignedMetadata.senderOSVersion,
            senderModelName: unsignedMetadata.senderModelName,
            senderChip: unsignedMetadata.senderChip
        )
        let data = try JSONEncoder().encode(signedMetadata)
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

    /// 发送接收端回执（落盘确认/失败原因）
    private func sendReceipt(
        _ receipt: TransferReceipt,
        securityContext: ClassicTransferSecurityContext,
        over connection: NWConnection
    ) async throws {
        logClassicReceiptPhase("receipt_send_attempted", transferId: receipt.transferId)
        let unsignedReceipt = unsignedReceiptCopy(
            from: receipt,
            securityVersion: receipt.securityVersion ?? 1
        )
        let signedReceipt = TransferReceipt(
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
        let data = try JSONEncoder().encode(signedReceipt)
        if data.count > maxMessageBytes {
            throw FileTransferError.invalidMetadata
        }
        let header = TransferHeader(type: .receipt, length: data.count)
        do {
            try await sendData(header.encoded + data, over: connection)
            logClassicReceiptPhase("receipt_send_succeeded", transferId: receipt.transferId)
        } catch {
            logClassicReceiptPhase("receipt_send_failed", transferId: receipt.transferId, detail: error.localizedDescription)
            throw error
        }
    }

    private func sendReceiptReliably(
        _ receipt: TransferReceipt,
        securityContext: ClassicTransferSecurityContext,
        over connection: NWConnection,
        maxAttempts: Int = 3,
        retryDelayNanoseconds: UInt64 = 250_000_000
    ) async throws {
        var lastError: Error?

        for attempt in 1...maxAttempts {
            do {
                try await sendReceipt(
                    receipt,
                    securityContext: securityContext,
                    over: connection
                )
                return
            } catch {
                lastError = error
                guard attempt < maxAttempts else { break }
                SkyBridgeLogger.shared.warning(
                    "⚠️ 落盘回执发送失败，准备重试: transferId=\(receipt.transferId) attempt=\(attempt)/\(maxAttempts) reason=\(error.localizedDescription)"
                )
                try? await Task.sleep(nanoseconds: retryDelayNanoseconds)
            }
        }

        throw lastError ?? FileTransferError.connectionFailed
    }

    private func sendFailureReceiptIfPossible(
        transferId: String,
        receivedBytes: Int64 = 0,
        securityVersion: Int?,
        error: Error,
        securityContext: ClassicTransferSecurityContext,
        over connection: NWConnection
    ) async {
        let failure = TransferReceipt(
            transferId: transferId,
            success: false,
            receivedBytes: receivedBytes,
            fileHash: nil,
            error: error.localizedDescription,
            securityVersion: securityVersion
        )

        do {
            try await sendReceiptReliably(
                failure,
                securityContext: securityContext,
                over: connection
            )
        } catch {
            SkyBridgeLogger.shared.error("⚠️ failure receipt 未发送: transferId=\(transferId) reason=\(error.localizedDescription)")
        }
    }

    /// 发送端等待接收端落盘回执，避免“仅发送完成即成功”的假阳性
    private func waitForTransferReceipt(
        over connection: NWConnection,
        securityContext: ClassicTransferSecurityContext,
        expectedTransferId: String,
        expectedFileSize: Int64,
        expectedFileHash: String
    ) async throws -> TransferReceipt {
        let header: TransferHeader
        do {
            header = try await receiveHeader(from: connection, timeout: receiptWaitTimeoutSeconds)
        } catch FileTransferError.timeout {
            logClassicReceiptPhase(FileTransferReceiptWaitStage.headerTimeout.rawValue, transferId: expectedTransferId)
            throw FileTransferError.receiptWaitFailed(stage: .headerTimeout, details: nil)
        }
        guard header.type == .receipt else {
            throw FileTransferError.transferFailed("接收端未返回落盘回执")
        }
        guard header.length > 0 else {
            throw FileTransferError.invalidMetadata
        }

        let payload: Data
        do {
            payload = try await receiveData(length: header.length, from: connection, timeout: receiptWaitTimeoutSeconds)
        } catch FileTransferError.timeout {
            logClassicReceiptPhase(FileTransferReceiptWaitStage.payloadTimeout.rawValue, transferId: expectedTransferId)
            throw FileTransferError.receiptWaitFailed(stage: .payloadTimeout, details: nil)
        }
        let receipt = try JSONDecoder().decode(TransferReceipt.self, from: payload)
        let unsignedReceipt = unsignedReceiptCopy(from: receipt)
        guard receipt.transferId == expectedTransferId else {
            throw FileTransferError.invalidMetadata
        }
        guard isValidAuthenticationTag(
            receipt.authTag,
            payload: receiptAuthenticationInput(unsignedReceipt),
            key: securityContext.transferKey
        ) else {
            logClassicReceiptPhase(FileTransferReceiptWaitStage.authFailed.rawValue, transferId: expectedTransferId)
            throw FileTransferError.receiptWaitFailed(stage: .authFailed, details: nil)
        }
        guard receipt.success else {
            logClassicReceiptPhase(FileTransferReceiptWaitStage.receiverRejected.rawValue, transferId: expectedTransferId)
            throw FileTransferError.receiptWaitFailed(stage: .receiverRejected, details: receipt.error)
        }
        guard receipt.receivedBytes == expectedFileSize else {
            throw FileTransferError.transferFailed("接收端字节数不一致: \(receipt.receivedBytes)/\(expectedFileSize)")
        }
        if let peerHash = receipt.fileHash, !peerHash.isEmpty,
           peerHash.lowercased() != expectedFileHash.lowercased() {
            throw FileTransferError.checksumMismatch
        }

        return receipt
    }
    
    // MARK: - Private Methods - Receiving
    
    /// 分块接收文件
    private func receiveFileInChunks(
        to url: URL,
        transfer: FileTransfer,
        securityContext: ClassicTransferSecurityContext,
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
            let decrypted = try decryptChunkPayload(
                ciphertext: chunk.data,
                nonce: chunk.nonce,
                tag: chunk.authenticationTag,
                using: securityContext.transferKey
            )

            // 可选：解压数据（按 metadata.compression 协商；为兼容旧实现，未声明时可做“尝试解压+回退”）
            let processedData: Data
            if metadata.compression == "zlib" {
                processedData = try decompressData(decrypted)
            } else if compressionEnabled {
                // 旧互通策略：对端未声明但本地开启时尝试解压
                processedData = (try? decompressData(decrypted)) ?? decrypted
            } else {
                processedData = decrypted
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

        logClassicReceiptPhase("all_chunks_received", transferId: transfer.id)

        // 等待完成信号
        let completeHeader = try await receiveHeader(from: connection)
        guard completeHeader.type == .complete else {
            throw FileTransferError.invalidMetadata
        }
    }
    
    /// 接收分块
    private func receiveChunk(from connection: NWConnection) async throws -> FileChunk {
        let header = try await receiveHeader(from: connection)
        guard header.type == .chunk else {
            throw FileTransferError.invalidMetadata
        }

        let data = try await receiveData(length: header.length, from: connection)
        let chunk = try JSONDecoder().decode(FileChunk.self, from: data)
        if chunk.size > maxChunkSizeBytes || chunk.nonce?.count != 12 || chunk.authenticationTag?.isEmpty != false {
            throw FileTransferError.invalidMetadata
        }
        return chunk
    }
    
    /// 接收头部
    private func receiveHeader(from connection: NWConnection, timeout: TimeInterval? = nil) async throws -> TransferHeader {
        let headerData = try await receiveData(length: 8, from: connection, timeout: timeout)
        guard let header = TransferHeader.decode(from: headerData) else {
            throw FileTransferError.invalidMetadata
        }
        guard header.length >= 0, header.length <= maxMessageBytes else {
            throw FileTransferError.invalidMetadata
        }
        return header
    }

    private func logClassicReceiptPhase(_ phase: String, transferId: String, detail: String? = nil) {
        if let detail, !detail.isEmpty {
            SkyBridgeLogger.shared.info("📨 classic_receipt_phase=\(phase) transferId=\(transferId) detail=\(detail)")
        } else {
            SkyBridgeLogger.shared.info("📨 classic_receipt_phase=\(phase) transferId=\(transferId)")
        }
    }

    // MARK: - Private Methods - Network

    /// 创建连接
    private func createConnection(toAnyOf endpoints: [NWEndpoint]) async throws -> NWConnection {
        guard !endpoints.isEmpty else {
            throw FileTransferError.invalidDestination
        }

        var lastError: Error?
        for (index, endpoint) in endpoints.enumerated() {
            let endpointDescription = String(describing: endpoint)
            SkyBridgeLogger.shared.info(
                "🔗 文件传输连接候选[\(index + 1)/\(endpoints.count)]: endpoint=\(endpointDescription)"
            )

            do {
                let connection = try await createConnection(to: endpoint)
                SkyBridgeLogger.shared.info(
                    "✅ 文件传输连接就绪: endpoint=\(endpointDescription)"
                )
                return connection
            } catch {
                lastError = error
                SkyBridgeLogger.shared.warning(
                    "⚠️ 文件传输候选连接失败[\(index + 1)/\(endpoints.count)]: endpoint=\(endpointDescription) error=\(error.localizedDescription)"
                )
            }
        }

        if let lastError {
            throw lastError
        }
        throw FileTransferError.connectionFailed
    }

    private func createConnection(to endpoint: NWEndpoint) async throws -> NWConnection {
        let endpointDescription = String(describing: endpoint)
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
                case .waiting(let error):
                    SkyBridgeLogger.shared.warning(
                        "⏳ 文件传输连接等待: endpoint=\(endpointDescription) error=\(error.localizedDescription)"
                    )
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

            queue.asyncAfter(deadline: .now() + FileTransferConstants.connectionTimeout) {
                once.run {
                    connection.stateUpdateHandler = nil
                    SkyBridgeLogger.shared.error(
                        "❌ 文件传输连接超时: endpoint=\(endpointDescription) timeout=\(Int(FileTransferConstants.connectionTimeout))s"
                    )
                    connection.cancel()
                    continuation.resume(throwing: FileTransferError.timeout)
                }
            }
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
    private func receiveData(length: Int, from connection: NWConnection, timeout: TimeInterval? = nil) async throws -> Data {
        let data: Data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
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
                queue.asyncAfter(deadline: .now() + timeout) {
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
                            continuation.resume(throwing: FileTransferError.networkError(error.localizedDescription))
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
                            continuation.resume(throwing: FileTransferError.transferFailed("Connection closed"))
                        }
                        return
                    }
                    receiveMore()
                }
            }

            receiveMore()
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

    nonisolated static func resolveClassicTransferPeer(
        peerContext: FileTransferPeerContext,
        authenticatedPeers: [ClassicTransferAuthenticatedPeerCandidate]
    ) -> ClassicTransferPeerResolutionOutcome? {
        let exactDeclared = peerContext.declaredSenderDeviceId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let declaredCandidates = normalizedTransferSecurityCandidates(
            PeerIdentityAliasResolver.lookupCandidates(for: exactDeclared),
            excluding: exactDeclared
        )
        let endpointCandidates = normalizedTransferSecurityCandidates(
            PeerIdentityAliasResolver.lookupCandidates(for: peerContext.endpointHostOrIP)
        )

        func exactDeclaredMatch() -> ClassicTransferAuthenticatedPeerCandidate? {
            guard let exactDeclared, !exactDeclared.isEmpty else { return nil }
            let exactLower = exactDeclared.lowercased()
            return authenticatedPeers.first { candidate in
                candidate.matchDeviceId.caseInsensitiveCompare(exactDeclared) == .orderedSame
                    || candidate.resolvedPeerDeviceId.caseInsensitiveCompare(exactDeclared) == .orderedSame
                    || candidate.aliases.contains(where: { $0.lowercased() == exactLower })
            }
        }

        func candidateMatch(for requestedCandidates: [String]) -> ClassicTransferAuthenticatedPeerCandidate? {
            guard !requestedCandidates.isEmpty else { return nil }
            let requestedLower = Set(requestedCandidates.map { $0.lowercased() })
            let matches = authenticatedPeers.filter { candidate in
                !requestedLower.isDisjoint(with: candidate.aliases.map { $0.lowercased() })
            }
            guard matches.count == 1 else { return nil }
            return matches.first
        }

        if let exactMatch = exactDeclaredMatch() {
            return ClassicTransferPeerResolutionOutcome(
                matchDeviceId: exactMatch.matchDeviceId,
                resolvedPeerDeviceId: exactMatch.resolvedPeerDeviceId,
                matchedBy: .declaredSenderDeviceId,
                declaredCandidates: declaredCandidates,
                endpointCandidates: endpointCandidates
            )
        }

        if let aliasMatch = candidateMatch(for: declaredCandidates) {
            return ClassicTransferPeerResolutionOutcome(
                matchDeviceId: aliasMatch.matchDeviceId,
                resolvedPeerDeviceId: aliasMatch.resolvedPeerDeviceId,
                matchedBy: .aliasOrCanonicalDeviceId,
                declaredCandidates: declaredCandidates,
                endpointCandidates: endpointCandidates
            )
        }

        if let endpointMatch = candidateMatch(for: endpointCandidates) {
            return ClassicTransferPeerResolutionOutcome(
                matchDeviceId: endpointMatch.matchDeviceId,
                resolvedPeerDeviceId: endpointMatch.resolvedPeerDeviceId,
                matchedBy: .endpointHostOrIP,
                declaredCandidates: declaredCandidates,
                endpointCandidates: endpointCandidates
            )
        }

        if authenticatedPeers.count == 1, let only = authenticatedPeers.first {
            return ClassicTransferPeerResolutionOutcome(
                matchDeviceId: only.matchDeviceId,
                resolvedPeerDeviceId: only.resolvedPeerDeviceId,
                matchedBy: .singleAuthenticatedFallback,
                declaredCandidates: declaredCandidates,
                endpointCandidates: endpointCandidates
            )
        }

        return nil
    }

    private func classicTransferSecurityContext(
        peerContext: FileTransferPeerContext
    ) throws -> ClassicTransferSecurityContext {
        let authenticatedPeers = connectionManager.activeClassicTransferAuthenticatedPeers().map { descriptor in
            ClassicTransferAuthenticatedPeerCandidate(
                matchDeviceId: descriptor.matchDeviceId,
                resolvedPeerDeviceId: descriptor.resolvedPeerDeviceId,
                aliases: descriptor.aliases,
                endpointHostOrIP: descriptor.endpointHostOrIP,
                capabilities: descriptor.capabilities
            )
        }

        guard let resolution = Self.resolveClassicTransferPeer(
            peerContext: peerContext,
            authenticatedPeers: authenticatedPeers
        ) else {
            SkyBridgeLogger.shared.error(
                "❌ 无法解析文件传输安全会话: transferId=\(peerContext.transferId) declaredSenderId=\(peerContext.declaredSenderDeviceId ?? "-") endpointHostOrIP=\(peerContext.endpointHostOrIP ?? "-") aliasCandidates=\((Self.normalizedTransferSecurityCandidates(PeerIdentityAliasResolver.lookupCandidates(for: peerContext.declaredSenderDeviceId), excluding: peerContext.declaredSenderDeviceId) + Self.normalizedTransferSecurityCandidates(PeerIdentityAliasResolver.lookupCandidates(for: peerContext.endpointHostOrIP))).joined(separator: ",")) authenticatedConnections=\(authenticatedPeers.count) matchedFallbackBranch=none"
            )
            throw FileTransferError.secureSessionRequired
        }

        if resolution.matchedBy == .singleAuthenticatedFallback {
            SkyBridgeLogger.shared.warning(
                "⚠️ 文件传输安全会话回退到唯一已认证连接: transferId=\(peerContext.transferId) declaredSenderId=\(peerContext.declaredSenderDeviceId ?? "-") endpointHostOrIP=\(peerContext.endpointHostOrIP ?? "-") aliasCandidates=\(resolution.declaredCandidates.joined(separator: ",")) authenticatedConnections=\(authenticatedPeers.count) matchedFallbackBranch=\(resolution.matchedBy.rawValue)"
            )
        }

        let transferKey = try connectionManager.deriveClassicFileTransferKey(
            transferId: peerContext.transferId,
            deviceId: resolution.matchDeviceId
        )

        return ClassicTransferSecurityContext(
            transferKey: transferKey,
            matchDeviceId: resolution.matchDeviceId,
            resolvedPeerDeviceId: resolution.resolvedPeerDeviceId,
            matchedBy: resolution.matchedBy,
            declaredCandidates: resolution.declaredCandidates,
            endpointCandidates: resolution.endpointCandidates
        )
    }

    nonisolated static func preferredClassicTransferSenderDeviceId(
        stableDeviceId: String,
        vendorDeviceId: String?
    ) -> String {
        let normalizedStable = stableDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedStable.isEmpty {
            return normalizedStable
        }

        return vendorDeviceId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    nonisolated static func normalizedTransferSecurityCandidates(
        _ candidates: [String],
        excluding exactMatch: String? = nil
    ) -> [String] {
        var normalized: [String] = []
        var seen = Set<String>()
        let excluded = exactMatch?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let lowered = trimmed.lowercased()
            guard lowered != excluded else { continue }
            guard seen.insert(lowered).inserted else { continue }
            normalized.append(trimmed)
        }
        return normalized
    }

    nonisolated static func singlePeerFallbackTransferDeviceId(
        requestedCandidates: [String],
        activeConnectionDeviceIDs: [String]
    ) -> String? {
        let normalizedActive = normalizedTransferSecurityCandidates(activeConnectionDeviceIDs)
        guard normalizedActive.count == 1,
              let only = normalizedActive.first else {
            return nil
        }

        return requestedCandidates.contains(only) ? nil : only
    }

    private func unsignedMetadataCopy(
        from metadata: FileMetadata,
        securityVersion: Int? = nil
    ) -> FileMetadata {
        FileMetadata(
            transferId: metadata.transferId,
            fileName: metadata.fileName,
            fileSize: metadata.fileSize,
            fileHash: metadata.fileHash,
            chunkSize: metadata.chunkSize,
            securityVersion: securityVersion ?? metadata.securityVersion,
            metadataAuthTag: nil,
            mimeType: metadata.mimeType,
            compression: metadata.compression,
            totalChunks: metadata.totalChunks,
            resumeOffset: metadata.resumeOffset,
            senderDeviceId: metadata.senderDeviceId,
            senderDeviceName: metadata.senderDeviceName,
            senderPlatform: metadata.senderPlatform,
            senderOSVersion: metadata.senderOSVersion,
            senderModelName: metadata.senderModelName,
            senderChip: metadata.senderChip
        )
    }

    private func unsignedReceiptCopy(
        from receipt: TransferReceipt,
        securityVersion: Int? = nil
    ) -> TransferReceipt {
        TransferReceipt(
            transferId: receipt.transferId,
            success: receipt.success,
            receivedBytes: receipt.receivedBytes,
            fileHash: receipt.fileHash,
            error: receipt.error,
            securityVersion: securityVersion ?? receipt.securityVersion,
            authTag: nil
        )
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

    private func receiptAuthenticationInput(_ receipt: TransferReceipt) -> Data {
        [
            receipt.transferId,
            receipt.success ? "1" : "0",
            String(receipt.receivedBytes),
            receipt.fileHash ?? "",
            receipt.error ?? "",
            String(receipt.securityVersion ?? 0)
        ].joined(separator: "|").data(using: .utf8) ?? Data()
    }

    private func authenticationTag(for payload: Data, using key: SymmetricKey) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: payload, using: key))
    }

    private func isValidAuthenticationTag(_ tag: Data?, payload: Data, key: SymmetricKey) -> Bool {
        guard let tag else { return false }
        return authenticationTag(for: payload, using: key) == tag
    }

    private func encryptChunkPayload(
        _ plaintext: Data,
        using key: SymmetricKey
    ) throws -> (ciphertext: Data, nonce: Data, tag: Data) {
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
        return (
            ciphertext: sealed.ciphertext,
            nonce: Data(nonce),
            tag: sealed.tag
        )
    }

    private func decryptChunkPayload(
        ciphertext: Data,
        nonce: Data?,
        tag: Data?,
        using key: SymmetricKey
    ) throws -> Data {
        guard let nonce, let tag else {
            throw FileTransferError.secureSessionRequired
        }
        let sealed = try AES.GCM.SealedBox(
            nonce: try AES.GCM.Nonce(data: nonce),
            ciphertext: ciphertext,
            tag: tag
        )
        return try AES.GCM.open(sealed, using: key)
    }

    private func acquireTransferSlot() async throws {
        let limit = max(1, SettingsManager.instance.fileTransferMaxConcurrentTransfers)
        if inFlightTransferCount < limit {
            inFlightTransferCount += 1
            return
        }

        let waiterId = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                transferWaiters.append(TransferWaiter(id: waiterId, continuation: continuation))
            }
        }, onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelTransferWaiter(id: waiterId)
            }
        })

        if Task.isCancelled {
            releaseTransferSlot()
            throw CancellationError()
        }
    }

    private func releaseTransferSlot() {
        let limit = max(1, SettingsManager.instance.fileTransferMaxConcurrentTransfers)
        switch Self.transferSlotReleaseAction(
            inFlightTransferCount: inFlightTransferCount,
            waiterCount: transferWaiters.count,
            limit: limit
        ) {
        case .resumeWaiter(let nextInFlightCount):
            let waiter = transferWaiters.removeFirst()
            inFlightTransferCount = nextInFlightCount
            waiter.continuation.resume(returning: ())
        case .decrementTo(let nextInFlightCount):
            inFlightTransferCount = nextInFlightCount
        }
    }

    private func cancelTransferWaiter(id: UUID) {
        guard let index = transferWaiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = transferWaiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    nonisolated static func transferSlotReleaseAction(
        inFlightTransferCount: Int,
        waiterCount: Int,
        limit: Int
    ) -> TransferSlotReleaseAction {
        let normalizedLimit = max(1, limit)
        let decrementedCount = max(0, inFlightTransferCount - 1)

        if waiterCount > 0, decrementedCount < normalizedLimit {
            return .resumeWaiter(nextInFlightCount: decrementedCount + 1)
        }

        return .decrementTo(decrementedCount)
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
        var transferSnapshot: FileTransfer?

        if let index = activeTransfers.firstIndex(where: { $0.id == transferId }) {
            activeTransfers[index].progress = progress
            activeTransfers[index].speed = speed
            activeTransfers[index].status = .transferring
            fileName = activeTransfers[index].fileName
            direction = activeTransfers[index].isIncoming ? .download : .upload
            transferSnapshot = activeTransfers[index]
        }
        
        transferStates[transferId]?.transferredBytes = transferredBytes
        transferStates[transferId]?.lastUpdateTime = Date()
        
        // 更新总进度
        updateTotalProgress()

        if let transferSnapshot {
            postInAppTransferProgressEventIfNeeded(
                transfer: transferSnapshot,
                transferredBytes: transferredBytes,
                totalBytes: totalBytes,
                progress: progress,
                speed: speed
            )
        }

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

    private func postInAppTransferEvent(
        name: String,
        transfer: FileTransfer,
        error: String? = nil
    ) {
        var userInfo: [String: Any] = [
            "transferId": transfer.id,
            "fileName": transfer.fileName,
            "fileSize": transfer.fileSize,
            "direction": transfer.isIncoming ? "incoming" : "outgoing",
            "remotePeer": transfer.remotePeer
        ]
        if let localPath = transfer.localPath, !localPath.isEmpty {
            userInfo["localPath"] = localPath
        }
        if let error, !error.isEmpty {
            userInfo["error"] = error
        }
        NotificationCenter.default.post(
            name: Notification.Name(name),
            object: nil,
            userInfo: userInfo
        )
    }

    private func postInAppTransferProgressEventIfNeeded(
        transfer: FileTransfer,
        transferredBytes: Int64,
        totalBytes: Int64,
        progress: Double,
        speed: Double
    ) {
        let transferId = transfer.id
        let now = Date()
        let clampedProgress = min(max(progress, 0), 1)
        let percent = Int((clampedProgress * 100).rounded(.down))
        let lastPercent = lastProgressEventPercentByTransferId[transferId] ?? -1
        let lastEventAt = lastProgressEventAtByTransferId[transferId] ?? .distantPast
        let intervalElapsed = now.timeIntervalSince(lastEventAt) >= progressEventMinInterval
        let stepAdvanced = percent >= lastPercent + progressEventMinStepPercent
        let isBoundary = percent == 0 || percent == 100

        guard intervalElapsed || stepAdvanced || isBoundary else {
            return
        }

        lastProgressEventAtByTransferId[transferId] = now
        lastProgressEventPercentByTransferId[transferId] = percent

        var userInfo: [String: Any] = [
            "transferId": transfer.id,
            "fileName": transfer.fileName,
            "fileSize": transfer.fileSize,
            "direction": transfer.isIncoming ? "incoming" : "outgoing",
            "remotePeer": transfer.remotePeer,
            "progress": clampedProgress,
            "progressPercent": percent,
            "transferredBytes": max(0, transferredBytes),
            "totalBytes": max(0, totalBytes),
            "speedBytesPerSecond": max(0, speed),
            "speedDisplay": formatSpeed(speed)
        ]
        if let localPath = transfer.localPath, !localPath.isEmpty {
            userInfo["localPath"] = localPath
        }
        NotificationCenter.default.post(
            name: .fileTransferProgress,
            object: nil,
            userInfo: userInfo
        )
    }

    private func clearProgressEventState(for transferId: String) {
        lastProgressEventAtByTransferId.removeValue(forKey: transferId)
        lastProgressEventPercentByTransferId.removeValue(forKey: transferId)
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
                    postInAppTransferEvent(name: "FileTransferCompleted", transfer: finalizedTransfer)
                } else {
                    postLocalFileTransferNotification(
                        title: "文件发送完成",
                        body: "\(finalizedTransfer.fileName) 已发送到 \(finalizedTransfer.remotePeer)",
                        transferId: finalizedTransfer.id,
                        fileName: finalizedTransfer.fileName
                    )
                    postInAppTransferEvent(name: "FileTransferCompleted", transfer: finalizedTransfer)
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
                postInAppTransferEvent(name: "FileTransferFailed", transfer: finalizedTransfer, error: reason)
            }
        }

        // 更新灵动岛：传输完成（iOS 17+）
        Task {
            await LiveActivityManager.shared.transferCompleted()
        }
        
        // 清理状态
        transferStates[transferId]?.connection?.cancel()
        transferStates.removeValue(forKey: transferId)
        clearProgressEventState(for: transferId)

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
        postInAppTransferEvent(name: "FileTransferStarted", transfer: transfer)
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
                postInAppTransferEvent(name: "FileTransferCompleted", transfer: completedTransfer)
            } else {
                postLocalFileTransferNotification(
                    title: "文件接收失败",
                    body: "\(completedTransfer.fileName) · \(error ?? "未知错误")",
                    transferId: completedTransfer.id,
                    fileName: completedTransfer.fileName,
                    localPath: completedTransfer.localPath
                )
                postInAppTransferEvent(name: "FileTransferFailed", transfer: completedTransfer, error: error ?? "未知错误")
            }
        }

        Task {
            await LiveActivityManager.shared.transferCompleted()
        }
        clearProgressEventState(for: transferId)
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
        transferHistory = Self.historyStore.load() ?? []
    }

    private func saveHistory() {
        // 只保留最近 100 条记录
        let historyToSave = Array(transferHistory.prefix(100))
        try? Self.historyStore.save(historyToSave)
    }
}

@available(iOS 17.0, *)
extension FileTransferManager {
    func installUITestHistoryFixture(for deviceName: String) {
        let fixtureURL = downloadsDirectory.appendingPathComponent("UITest-Transfer-Guide.txt")
        let fixtureData = Data("SkyBridge UI test fixture file".utf8)
        if !fileManager.fileExists(atPath: fixtureURL.path) {
            try? fixtureData.write(to: fixtureURL, options: .atomic)
        }

        transferHistory = [
            FileTransfer(
                id: "uitest-history-transfer",
                fileName: fixtureURL.lastPathComponent,
                fileSize: Int64(fixtureData.count),
                fileType: .document,
                progress: 1.0,
                speed: 0,
                status: .completed,
                isIncoming: true,
                remotePeer: deviceName,
                timestamp: Date().addingTimeInterval(-90),
                localPath: fixtureURL.path
            )
        ]
        activeTransfers = []
        isTransferring = false
        totalProgress = 0
        saveHistory()
    }

    func performUITestQuickSend(to device: DiscoveredDevice) {
        let transfer = FileTransfer(
            id: "uitest-active-transfer",
            fileName: "UITest-Smoke.pdf",
            fileSize: 1_048_576,
            fileType: .document,
            progress: 0.42,
            speed: 393_216,
            status: .transferring,
            isIncoming: false,
            remotePeer: device.name,
            timestamp: Date(),
            localPath: nil
        )
        activeTransfers = [transfer]
        isTransferring = true
        totalProgress = transfer.progress
    }
}
