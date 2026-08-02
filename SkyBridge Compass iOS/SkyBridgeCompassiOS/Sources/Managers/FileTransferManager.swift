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
import enum SkyBridgeProtocolCore.CrossNetworkFileTransferOp
import struct SkyBridgeProtocolCore.CrossNetworkFileTransferMessage
import class SkyBridgeProtocolCore.ClassicTransferChunkCryptoWorker
import class SkyBridgeProtocolCore.ClassicTransferJSONWorker
import class SkyBridgeProtocolCore.ClassicTransferOutboundFileReadSession
import class SkyBridgeProtocolCore.ClassicTransferReceiveOperation
import class SkyBridgeProtocolCore.ClassicTransferSendOperation
import class SkyBridgeProtocolCore.ClassicTransferSourceFileInspectionWorker
import class SkyBridgeProtocolCore.ClassicTransferZlibCompressionWorker
import class SkyBridgeProtocolCore.ClassicTransferZlibDecompressionWorker
import class SkyBridgeProtocolCore.InboundFileTransferIOActor
import enum SkyBridgeProtocolCore.ClassicTransferAuthenticationContract
import enum SkyBridgeProtocolCore.ClassicTransferCanonicalTranscript
import enum SkyBridgeProtocolCore.ClassicTransferChunkContract
import enum SkyBridgeProtocolCore.ClassicTransferInboundPolicy
import enum SkyBridgeProtocolCore.ClassicTransferMetadataContract
import enum SkyBridgeProtocolCore.ClassicTransferReceiptContract
import enum SkyBridgeProtocolCore.ClassicTransferSourceFileInspectionError
import struct SkyBridgeProtocolCore.ClassicTransferEncryptedChunk
import struct SkyBridgeProtocolCore.ClassicTransferSlotQueuePolicy
import struct SkyBridgeProtocolCore.InboundFileTransferIOHandle
#if canImport(UIKit)
import UIKit
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif

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

// MARK: - FileTransferManager

/// 文件传输管理器 - 支持高速分块传输、断点续传、加密传输
@available(iOS 17.0, *)
@MainActor
public class FileTransferManager: ObservableObject {
    /// Opaque capability binding external WebRTC callbacks to one concrete UI
    /// transfer record. A peer-controlled transfer identifier is not sufficient:
    /// identifiers can be reused after a terminal transition, while this token
    /// cannot accidentally address the replacement record.
    public struct ExternalTransferToken: Hashable, Sendable {
        fileprivate let identifier: UUID
        fileprivate let transferID: String
    }

    public static let instance = FileTransferManager()
    private static let historyStore = CodablePersistenceStore<[FileTransfer]>(
        location: .protectedApplicationSupport(
            path: "FileTransfer/history.json",
            legacyUserDefaultsKey: "transfer_history"
        ),
        maximumPayloadBytes: 1 * 1024 * 1024
    )
    private let historyRepository = FileTransferHistoryRepository(
        persistence: FileTransferHistoryPersistence(store: historyStore)
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

    @Published public private(set) var historyPersistenceError: String?
    
    // MARK: - Private Properties
    
    private let fileManager = FileManager.default
    private let documentsDirectory: URL
    private let downloadsDirectory: URL
    private var transferStates: [String: TransferState] = [:]
    private var externalTransferTokensByTransferID: [String: ExternalTransferToken] = [:]
    private var chunkSize: Int = FileTransferConstants.defaultChunkSize
    private let maxChunkSizeBytes: Int = 512 * 1024
    private let maxMessageBytes: Int = 2_000_000
    private let queue = DispatchQueue(label: "com.skybridge.filetransfer", qos: .userInitiated)
    private let receiptWaitTimeoutSeconds: TimeInterval = 60
    private var classicTransferIdentityBridgeConfirmedAtByDeviceId: [String: Date] = [:]

    private struct ClassicTransferSecurityContext {
        let transferKey: SymmetricKey
        let matchDeviceId: String
        let resolvedPeerDeviceId: String
        let matchedBy: ClassicTransferPeerResolutionBranch
        let declaredCandidates: [String]
        let endpointCandidates: [String]
    }

    private var transferSlotPolicy = ClassicTransferSlotQueuePolicy()
    private var transferSlotContinuations: [UUID: CheckedContinuation<Void, Error>] = [:]
    enum TransferSlotReleaseAction: Equatable {
        case decrementTo(Int)
        case resumeWaiter(nextInFlightCount: Int)
    }
    private var lastProgressEventAtByTransferId: [String: Date] = [:]
    private var lastProgressEventPercentByTransferId: [String: Int] = [:]
    private let progressEventMinInterval: TimeInterval = 0.25
    private let progressEventMinStepPercent: Int = 2
    private struct PendingHistoryCommand {
        let generation: UInt64
        let command: FileTransferHistoryCommand
    }
    private var pendingHistoryCommands: [PendingHistoryCommand] = []
    private var pendingHistoryCommandIndex = 0
    private var nextHistoryGeneration: UInt64 = 0
    private var latestHistoryIntentGeneration: UInt64 = 0
    private var historyDrainTask: Task<Void, Never>?
    
    /// P2P 连接管理器
    private var connectionManager: P2PConnectionManager { P2PConnectionManager.instance }
    
    /// Cross-network (WebRTC) manager
    private var crossNetwork: CrossNetworkWebRTCManager { CrossNetworkWebRTCManager.instance }
    
    /// 压缩是否启用
    /// ⚠️ 兼容性：旧版 macOS 端不会对入站 chunk 解压，默认关闭可避免跨版本互通失败。
    /// 若你同时使用本仓库更新后的 macOS 端（支持 compression=zlib），可以在设置里开启。
    public var compressionEnabled: Bool = false
    
    private init() {
        documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        downloadsDirectory = documentsDirectory.appendingPathComponent("Downloads", isDirectory: true)
        enqueueHistoryCommand(.bootstrap)
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

        SkyBridgeLogger.shared.info("📤 开始发送文件")

        // 获取文件信息
        let fileSize: Int64
        do {
            fileSize = try await ClassicTransferSourceFileInspectionWorker.shared.regularFileSize(
                at: url,
                maximumSize: ClassicTransferInboundPolicy.maximumFileSizeBytes
            )
        } catch ClassicTransferSourceFileInspectionError.notFound {
            throw FileTransferError.fileNotFound
        } catch ClassicTransferSourceFileInspectionError.notRegularFile {
            throw FileTransferError.invalidMetadata
        } catch ClassicTransferSourceFileInspectionError.invalidFileSize {
            throw FileTransferError.invalidMetadata
        }
        let fileName = url.lastPathComponent
        let fileType = determineFileType(from: url)
        
        // 计算文件哈希（SHA256，流式处理）
        let fileHash = try await calculateFileHash(at: url)
        
        let effectiveChunkSize = min(maxChunkSizeBytes, max(64 * 1024, chunkSize))
        
        // 计算分块数
        let totalChunks = Int(ceil(Double(fileSize) / Double(effectiveChunkSize)))

        // Resolve the complete protocol identity before publishing any
        // transfer state or "started" event. Cancellation or authority failure
        // must leave activeTransfers and isTransferring untouched.
        let localIdentity = AppleMobileDeviceIdentity.currentSnapshot()
        let protocolIdentity = try await SkyBridgeiOSCore.shared
            .currentProtocolIdentitySnapshot()
        let senderDeviceId = protocolIdentity.deviceId
        let senderDeviceName = localIdentity.deviceName
        let senderPlatform = localIdentity.platformName
        let senderOSVersion = localIdentity.osVersion
        let senderModelName = SBFT_currentModelDisplayName()
        let senderChip = SBFT_currentChipDisplayName()

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
        state.metadata = FileMetadata(
            transferId: transfer.id,
            fileName: fileName,
            fileSize: fileSize,
            fileHash: fileHash,
            chunkSize: effectiveChunkSize,
            securityVersion: ClassicTransferInboundPolicy.currentSecurityVersion,
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
                SkyBridgeLogger.shared.info("✅ 文件发送完成(WebRTC)")
                return
            }
            
            // 建立连接：优先 Bonjour service（不依赖 IP/默认端口）
            //
            // ⚠️ 重要：activeConnections 里的 `DiscoveredDevice` 有时是“连接时快照”，services/ip 可能不完整。
            // 这里尝试用发现管理器的最新记录补全（尤其是 `_skybridge-xfer._tcp`）。
            let resolvedDevice = resolveLatestTransferDevice(from: device)

            try await ensureClassicTransferIdentityBridgeReady(for: resolvedDevice)

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
                chunkSize: effectiveChunkSize,
                compression: state.metadata!.compression,
                expectedFileHash: fileHash
            )

            // 必须等待接收端“落盘回执”，否则不能标记发送成功
            do {
                _ = try await waitForTransferReceipt(
                    over: connection,
                    securityContext: securityContext,
                    expectedTransferId: transfer.id,
                    expectedFileSize: fileSize,
                    expectedFileHash: fileHash
                )
            } catch {
                let receiptError = ClassicTransferDeliveryConfirmationPolicy
                    .normalizedReceiptWaitError(error)
                if ClassicTransferDeliveryConfirmationPolicy.isUnknown(receiptError),
                   let index = activeTransfers.firstIndex(where: { $0.id == transfer.id }) {
                    activeTransfers[index].receiptDeliveryStatus = .unknown
                }
                throw receiptError
            }

            // 完成传输
            await completeTransfer(transfer.id, success: true)
            
            SkyBridgeLogger.shared.info("✅ 文件发送完成")
            
        } catch {
            if ClassicTransferDeliveryConfirmationPolicy.isUnknown(error),
               let index = activeTransfers.firstIndex(where: { $0.id == transfer.id }) {
                activeTransfers[index].receiptDeliveryStatus = .unknown
            }
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
                "📡 文件传输目标已补全: serviceCount=\(resolved.services.count) portCount=\(resolved.portMap.count)"
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
        let directIP = bestIPAddress(for: device)
        let resolvedIP = await resolveTransferIPAddress(for: device)

        if let port = explicitTransferPort {
            for ip in [directIP, resolvedIP]
                .compactMap({ $0 })
                .filter({ ConnectableAddressCanonicalizer.isRoutableLANAddress($0) }) {
                appendTransferHostEndpoint(
                    ip,
                    port: port,
                    reason: "lan-direct",
                    to: &endpoints,
                    seen: &seen
                )
            }
        }

        for endpoint in DeviceDiscoveryManager.instance.liveBonjourServiceEndpoints(
            for: device,
            serviceType: .skybridgeTransfer
        ) {
            appendTransferEndpoint(
                endpoint,
                to: &endpoints,
                seen: &seen
            )
        }

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

        if let port = explicitTransferPort {
            for ip in [directIP, resolvedIP]
                .compactMap({ $0 })
                .filter({ ConnectableAddressCanonicalizer.isLinkLocal($0) }) {
                appendTransferHostEndpoint(
                    ip,
                    port: port,
                    reason: "link-local-fallback",
                    to: &endpoints,
                    seen: &seen
                )
            }
        }

        if hasActivePeerSession,
           let activePeerIP = activePeerTransferAddress(for: device) {
            if let port = explicitTransferPort {
                SkyBridgeLogger.shared.warning(
                    "⚠️ 文件传输目标缺少独立服务公告，使用活跃 P2P 会话已声明的显式端口: port=\(port)"
                )
                appendTransferHostEndpoint(
                    activePeerIP,
                    port: port,
                    reason: "active-peer-fallback",
                    to: &endpoints,
                    seen: &seen
                )
            } else {
                SkyBridgeLogger.shared.warning(
                    "⚠️ 文件传输目标缺少独立端口，拒绝猜测默认端口"
                )
            }
        }

        if !endpoints.isEmpty {
            return endpoints
        }

        if device.supportsFileTransfer,
           await resolveTransferIPAddress(for: device) != nil {
            SkyBridgeLogger.shared.warning(
                "⚠️ 文件传输目标仅声明能力但未提供独立端口，拒绝猜测默认端口"
            )
        }

        if device.supportsFileTransfer {
            throw FileTransferError.networkStageFailed(
                stage: "route_resolution_missing_transfer_endpoint",
                endpoint: nil,
                details: "设备未声明独立文件传输端点，已拒绝对默认 8080 端口进行猜测连接"
            )
        }

        throw FileTransferError.networkStageFailed(
            stage: "route_resolution_invalid_destination",
            endpoint: nil,
            details: "目标设备未声明文件传输能力或可解析端点"
        )
    }

    private func appendTransferHostEndpoint(
        _ ip: String,
        port: UInt16,
        reason: String,
        to endpoints: inout [NWEndpoint],
        seen: inout Set<String>
    ) {
        SkyBridgeLogger.shared.info(
            "📡 文件传输候选地址: reason=\(reason) port=\(port) routeClass=\(ConnectableAddressCanonicalizer.routeClass(ip)) peerToPeer=\(ConnectableAddressCanonicalizer.prefersPeerToPeer(for: ip))"
        )
        appendTransferEndpoint(
            .hostPort(host: .init(ip), port: .init(integerLiteral: port)),
            to: &endpoints,
            seen: &seen
        )
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
        let candidates = transferIdentityCandidates(for: device)

        // Prefer the port carried by a candidate that advertises the explicit
        // `_skybridge-xfer._tcp` Bonjour service (the authoritative transfer
        // endpoint). A session/pairing-derived record can carry the live P2P
        // session port in `portMap[fileTransferServiceType]` (and even gets the
        // transfer service appended to its `services` list when merged), so it
        // must NEVER win over the real advertised transfer port.
        for candidate in candidates where advertisesExplicitTransferService(candidate) {
            if let port = candidate.fileTransferPort, port > 0 {
                return port
            }
        }

        // No explicit transfer-service advertisement exists: fall back to the
        // first candidate that carries any transfer port.
        for candidate in candidates {
            if let port = candidate.fileTransferPort, port > 0 {
                return port
            }
        }
        return nil
    }

    /// True when the candidate carries an explicit `_skybridge-xfer._tcp`
    /// advertisement, i.e. its port provenance is the real transfer-service
    /// Bonjour record (SRV/TXT) rather than a session/pairing heartbeat merge.
    ///
    /// `services` membership alone is NOT authoritative: `mergePeerServiceMetadata`
    /// appends `fileTransferServiceType` to `services` when it ingests the peer's
    /// pairing/heartbeat-reported port, so the discriminator is the Bonjour
    /// service-type itself (set only by transfer-service SRV resolution) or a
    /// `bonjour:`-prefixed identity tied to the transfer service.
    private func advertisesExplicitTransferService(_ candidate: DiscoveredDevice) -> Bool {
        if candidate.bonjourServiceType == DiscoveredDevice.fileTransferServiceType {
            return true
        }
        if candidate.id.hasPrefix("bonjour:"),
           parseBonjourIdentity(from: candidate.id) != nil,
           candidate.fileTransferPort != nil {
            return true
        }
        return false
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

    private func ensureClassicTransferIdentityBridgeReady(for device: DiscoveredDevice) async throws {
        let bridgeKey = Self.normalizedTransferIdentity(device.id)
        let wasPreviouslyConfirmed = classicTransferIdentityBridgeConfirmedAtByDeviceId[bridgeKey] != nil
        let since = Date()

        do {
            try await connectionManager.sendPairingIdentityExchange(to: device.id)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let resolved = connectionManager.resolvedPeerDevice(for: device)
            guard resolved.id != device.id else {
                throw FileTransferError.networkStageFailed(
                    stage: "identity_bridge_send_failed",
                    endpoint: device.id,
                    details: "P2P pairing identity exchange 发送失败，拒绝启动经典文件传输: \(error.localizedDescription)"
                )
            }

            do {
                try await connectionManager.sendPairingIdentityExchange(to: resolved.id)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw FileTransferError.networkStageFailed(
                    stage: "identity_bridge_send_failed",
                    endpoint: resolved.id,
                    details: "P2P pairing identity exchange 发送失败，拒绝启动经典文件传输: \(error.localizedDescription)"
                )
            }
        }

        if wasPreviouslyConfirmed {
            return
        }

        let confirmed = await connectionManager.waitForPairingIdentityExchangeActivity(
            with: device.id,
            since: since,
            timeout: .seconds(4)
        )
        if confirmed {
            classicTransferIdentityBridgeConfirmedAtByDeviceId[bridgeKey] = Date()
            return
        }

        let resolved = connectionManager.resolvedPeerDevice(for: device)
        if resolved.id != device.id {
            let resolvedConfirmed = await connectionManager.waitForPairingIdentityExchangeActivity(
                with: resolved.id,
                since: since,
                timeout: .seconds(2)
            )
            if resolvedConfirmed {
                classicTransferIdentityBridgeConfirmedAtByDeviceId[bridgeKey] = Date()
                classicTransferIdentityBridgeConfirmedAtByDeviceId[Self.normalizedTransferIdentity(resolved.id)] = Date()
                return
            }
        }

        throw FileTransferError.networkStageFailed(
            stage: "identity_bridge_not_confirmed",
            endpoint: device.id,
            details: "P2P pairing identity exchange 未被对端确认，拒绝启动经典文件传输"
        )
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
        ConnectableAddressCanonicalizer.bestLANAddress([
            device.ipAddress,
            addressFromIdentifier(device.id)
        ])
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

        var addresses: [String?] = []
        for candidate in candidates {
            addresses.append(bestIPAddress(for: candidate))
            addresses.append(connectionManager.activePeerHostAddress(for: candidate))
            addresses.append(await DeviceDiscoveryManager.instance.resolveEndpoint(candidate))
        }

        return ConnectableAddressCanonicalizer.bestLANAddress(addresses)
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
        let senderDeviceId = try await SkyBridgeiOSCore.shared
            .currentProtocolIdentitySnapshot().deviceId
        let senderDeviceName: String? = senderIdentity.deviceName
        var didAttemptMetadata = false
        var didAttemptCompletion = false
        var fileReader: ClassicTransferOutboundFileReadSession?

        do {
            try ensureWebRTCTransferMayContinue(transferID: transfer.id)
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
            didAttemptMetadata = true
            _ = try await crossNetwork.sendFileTransferMessageAwaitingAck(
                meta,
                expectedOperation: .metadataAck,
                timeoutSeconds: 15
            )
            try ensureWebRTCTransferMayContinue(transferID: transfer.id)

            let reader = try await ClassicTransferOutboundFileReadSession.open(
                url: url,
                tracksSHA256: true
            )
            fileReader = reader
            try ensureWebRTCTransferMayContinue(transferID: transfer.id)

            var sentBytes: Int64 = 0
            var chunkIndex = 0
            while sentBytes < metadata.fileSize {
                try ensureWebRTCTransferMayContinue(transferID: transfer.id)
                let remainingBytes = metadata.fileSize - sentBytes
                let currentChunkSize = min(Int64(dcChunkSize), remainingBytes)
                let chunkData = try await reader.read(
                    offset: UInt64(sentBytes),
                    length: Int(currentChunkSize)
                )
                try ensureWebRTCTransferMayContinue(transferID: transfer.id)
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
                let ack: CrossNetworkFileTransferMessage = try await {
                    () async throws -> CrossNetworkFileTransferMessage in
                    var lastError: Error?
                    for _ in 0..<3 {
                        try Task.checkCancellation()
                        try ensureWebRTCTransferMayContinue(transferID: transfer.id)
                        do {
                            return try await crossNetwork.sendFileTransferMessageAwaitingAck(
                                msg,
                                expectedOperation: .chunkAck,
                                chunkIndex: chunkIndex,
                                timeoutSeconds: 20
                            )
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            guard WebRTCChunkAcknowledgmentRetryPolicy
                                .shouldRetry(after: error) else {
                                throw error
                            }
                            lastError = error
                        }
                    }
                    if let lastError { throw lastError }
                    throw FileTransferError.networkStageFailed(
                        stage: "webrtc_chunk_ack_retries_exhausted",
                        endpoint: nil,
                        details: "chunkIndex=\(chunkIndex)"
                    )
                }()
                try ensureWebRTCTransferMayContinue(transferID: transfer.id)

                let expectedReceivedBytes = sentBytes + Int64(rawSize)
                guard ack.receivedBytes == expectedReceivedBytes else {
                    throw FileTransferError.transferFailed(
                        "接收端分块累计字节数不一致: \(ack.receivedBytes ?? -1)/\(expectedReceivedBytes)"
                    )
                }
                sentBytes = expectedReceivedBytes
                chunkIndex += 1
                await updateProgress(
                    transfer.id,
                    transferredBytes: sentBytes,
                    totalBytes: metadata.fileSize
                )
                try ensureWebRTCTransferMayContinue(transferID: transfer.id)
            }

            let fileSha256 = try await reader.finalizeAndClose()
            fileReader = nil
            try ensureWebRTCTransferMayContinue(transferID: transfer.id)
            let done = CrossNetworkFileTransferMessage(
                op: .complete,
                transferId: transfer.id,
                receivedBytes: metadata.fileSize,
                fileSha256: fileSha256
            )
            let completionAck: CrossNetworkFileTransferMessage
            do {
                didAttemptCompletion = true
                completionAck = try await crossNetwork.sendFileTransferMessageAwaitingAck(
                    done,
                    expectedOperation: .completeAck,
                    timeoutSeconds: 20
                )
            } catch {
                throw WebRTCCompletionConfirmationPolicy.normalizedWaitError(error)
            }
            guard completionAck.receivedBytes == metadata.fileSize else {
                throw FileTransferError.transferFailed(
                    "接收端落盘字节数不一致: \(completionAck.receivedBytes ?? -1)/\(metadata.fileSize)"
                )
            }
            guard completionAck.fileSha256 == fileSha256 else {
                throw FileTransferError.transferFailed("接收端落盘哈希不一致或缺少哈希回执")
            }
        } catch {
            let operationError = error
            var reportedError: Error
            if !didAttemptCompletion,
               operationError is CancellationError
                    || transferStates[transfer.id]?.isCancelled == true {
                reportedError = FileTransferError.transferCancelled
            } else {
                reportedError = operationError
            }
            if let fileReader {
                do {
                    try await fileReader.close()
                } catch {
                    reportedError = FileTransferError.transferFailed(
                        "WebRTC 文件发送失败且关闭源文件失败: operation=\(operationError), close=\(error)"
                    )
                }
            }
            if didAttemptMetadata, !didAttemptCompletion {
                let cancellationNoticeTask = Task { @MainActor [crossNetwork] in
                    try await crossNetwork.sendFileTransferMessage(
                        CrossNetworkFileTransferMessage(
                            op: .cancel,
                            transferId: transfer.id,
                            message: "sender terminated before commit request"
                        )
                    )
                }
                do {
                    try await cancellationNoticeTask.value
                } catch {
                    let cancellationNoticeError = error as NSError
                    SkyBridgeLogger.shared.error(
                        "Cross-network cancellation notice failed: domain=\(cancellationNoticeError.domain) code=\(cancellationNoticeError.code)"
                    )
                }
            }
            throw reportedError
        }
    }

    private func ensureWebRTCTransferMayContinue(transferID: String) throws {
        guard let state = transferStates[transferID] else {
            throw FileTransferError.invalidTransferState
        }
        guard !state.isCancelled else {
            throw FileTransferError.transferCancelled
        }
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
        // Nothing below this boundary may publish attacker-controlled metadata. In
        // particular, unauthenticated attempts must not enter active/history state or UI.
        let securityContext: ClassicTransferSecurityContext
        do {
            try ClassicTransferMetadataContract.validateSecurityVersion(metadata.securityVersion)
            try await ClassicTransferJSONWorker.shared.validateMetadata(
                transferID: metadata.transferId,
                fileName: metadata.fileName,
                fileSize: metadata.fileSize,
                fileHash: metadata.fileHash,
                declaredChunkSize: metadata.chunkSize,
                compression: metadata.compression,
                displayFields: [
                    metadata.senderDeviceId,
                    metadata.senderDeviceName,
                    metadata.senderPlatform,
                    metadata.senderOSVersion,
                    metadata.senderModelName,
                    metadata.senderChip
                ]
            )
            SignedKEMRefreshSmokeStatusWriter.append(
                "file-transfer inbound-metadata-contract-validated"
            )
            securityContext = try classicTransferSecurityContext(peerContext: peerContext)
            SignedKEMRefreshSmokeStatusWriter.append(
                "file-transfer inbound-security-context-resolved matchedBy=\(securityContext.matchedBy.rawValue)"
            )
            let unsignedMetadata = unsignedMetadataCopy(from: metadata)
            guard isValidAuthenticationTag(
                metadata.metadataAuthTag,
                payload: try metadataAuthenticationInput(unsignedMetadata),
                key: securityContext.transferKey
            ) else {
                SignedKEMRefreshSmokeStatusWriter.append(
                    "file-transfer inbound-metadata-hmac-rejected"
                )
                throw FileTransferError.secureSessionRequired
            }
        } catch {
            let authenticationError = error as NSError
            SignedKEMRefreshSmokeStatusWriter.append(
                "file-transfer inbound-auth-rejected domain=\(authenticationError.domain) code=\(authenticationError.code)"
            )
            SkyBridgeLogger.shared.error(
                "⚠️ classic inbound rejected: authenticationBoundary=pre_authentication domain=\(authenticationError.domain) code=\(authenticationError.code)"
            )
            throw error
        }

        SignedKEMRefreshSmokeStatusWriter.append(
            "file-transfer inbound-authenticated stage=metadata"
        )

        try await acquireTransferSlot()
        defer { releaseTransferSlot() }
        try await prepareClassicInboundDirectory()

        guard !activeTransfers.contains(where: { $0.id == metadata.transferId }),
              transferStates[metadata.transferId] == nil,
              externalTransferTokensByTransferID[metadata.transferId] == nil else {
            let duplicateError = FileTransferError.invalidTransferState
            await sendFailureReceiptIfPossible(
                transferId: metadata.transferId,
                securityVersion: metadata.securityVersion,
                error: duplicateError,
                securityContext: securityContext,
                over: connection
            )
            throw duplicateError
        }

        let peer = peerContext.peerLabel
            ?? peerContext.endpointHostOrIP
            ?? securityContext.resolvedPeerDeviceId
        SkyBridgeLogger.shared.info("📥 classic inbound authenticated; receiving file")

        let stagingURL = downloadsDirectory.appendingPathComponent(
            ".skybridge-classic-\(UUID().uuidString).partial",
            isDirectory: false
        )

        // 创建传输记录
        let transfer = FileTransfer(
            id: metadata.transferId,
            fileName: metadata.fileName,
            fileSize: metadata.fileSize,
            fileType: determineFileType(fromName: metadata.fileName),
            isIncoming: true,
            remotePeer: peer,
            localPath: nil
        )

        activeTransfers.append(transfer)
        isTransferring = true
        postInAppTransferEvent(name: "FileTransferStarted", transfer: transfer)
        postLocalFileTransferNotification(
            title: "正在接收文件",
            body: "\(metadata.fileName) 来自 \(peer)",
            transferId: transfer.id,
            fileName: metadata.fileName
        )

        // 创建传输状态
        var state = TransferState(transferId: transfer.id)
        state.metadata = metadata
        state.connection = connection
        state.startTime = Date()

        // 创建目标文件
        state.localURL = nil
        transferStates[transfer.id] = state

        var inboundIOHandle: InboundFileTransferIOHandle?
        var committedURL: URL?
        do {
            let ioHandle = try await InboundFileTransferIOActor.shared.createTemporaryFile(
                at: stagingURL,
                declaredFileSize: metadata.fileSize
            )
            inboundIOHandle = ioHandle

            // 分块接收文件
            let receivedDigest = try await receiveFileInChunks(
                transfer: transfer,
                securityContext: securityContext,
                from: connection,
                metadata: metadata,
                ioHandle: ioHandle
            )

            let receivedHash = receivedDigest.map { String(format: "%02x", $0) }.joined()
            guard receivedHash == metadata.fileHash else {
                throw FileTransferError.checksumMismatch
            }

            let targetURL = try await InboundFileTransferIOActor.shared.commit(
                using: ioHandle,
                destinationDirectory: downloadsDirectory,
                fileName: (metadata.fileName as NSString).lastPathComponent
            )
            committedURL = targetURL

            // The file is already verified and atomically committed. Receipt loss is
            // transport ambiguity; it must never authorize deletion or retransmission.
            let receipt = TransferReceipt(
                transferId: metadata.transferId,
                success: true,
                receivedBytes: metadata.fileSize,
                fileHash: receivedHash,
                securityVersion: metadata.securityVersion
            )
            let receiptDeliveryStatus = await sendSuccessfulReceiptAfterCommit(
                receipt,
                securityContext: securityContext,
                over: connection
            )
            transferStates[transfer.id]?.localURL = targetURL
            if let index = activeTransfers.firstIndex(where: { $0.id == transfer.id }) {
                activeTransfers[index].localPath = targetURL.path
                activeTransfers[index].receiptDeliveryStatus = receiptDeliveryStatus
            }
            try await InboundFileTransferIOActor.shared.releaseCommittedFile(using: ioHandle)
            inboundIOHandle = nil

            // 完成传输
            await completeTransfer(transfer.id, success: true)

            SkyBridgeLogger.shared.info("✅ classic inbound file receive completed")
            
            return targetURL

        } catch {
            let operationError = error
            if let committedURL {
                let terminalError = FileTransferError.committedFileReleaseFailed
                transferStates[transfer.id]?.localURL = committedURL
                if let index = activeTransfers.firstIndex(where: { $0.id == transfer.id }) {
                    activeTransfers[index].localPath = committedURL.path
                }
                await completeTransfer(transfer.id, success: false, error: terminalError)
                SkyBridgeLogger.shared.error(
                    "❌ classic inbound file committed but actor bookkeeping release failed"
                )
                throw terminalError
            }
            let receiveError: Error
            if let inboundIOHandle {
                do {
                    try await InboundFileTransferIOActor.shared.discard(inboundIOHandle)
                    receiveError = operationError
                } catch {
                    let cleanupNSError = error as NSError
                    SkyBridgeLogger.shared.error(
                        "❌ classic inbound partial cleanup failed: domain=\(cleanupNSError.domain) code=\(cleanupNSError.code)"
                    )
                    receiveError = FileTransferError.transferFailed(
                        "接收失败，且未完成文件关闭或删除失败"
                    )
                }
            } else {
                receiveError = operationError
            }
            transferStates[transfer.id]?.localURL = nil
            if let index = activeTransfers.firstIndex(where: { $0.id == transfer.id }) {
                activeTransfers[index].localPath = nil
            }
            await sendFailureReceiptIfPossible(
                transferId: metadata.transferId,
                securityVersion: metadata.securityVersion,
                error: receiveError,
                securityContext: securityContext,
                over: connection
            )
            await completeTransfer(transfer.id, success: false, error: receiveError)
            throw receiveError
        }
    }
    
    /// 取消传输
    public func cancelTransfer(_ transferId: String) {
        if let externalToken = externalTransferTokensByTransferID[transferId] {
            crossNetwork.requestCancelInboundFileTransfer(
                presentationToken: externalToken
            )
            return
        }

        if var state = transferStates[transferId] {
            state.isCancelled = true
            state.connection?.cancel()
            transferStates[transferId] = state
        }
        
        crossNetwork.cancelFileTransferWaiters(transferId: transferId)
        updateTransferringState()
    }
    
    /// 清空历史
    public func clearHistory() {
        transferHistory.removeAll()
        historyPersistenceError = nil
        enqueueHistoryCommand(.clear)
    }
    
    /// 获取下载目录
    public func getDownloadsDirectory() -> URL {
        downloadsDirectory
    }

    /// 解析当前仍然有效的本地文件 URL。
    /// 历史记录里的 `localPath` 可能来自旧的 iOS 沙盒容器路径；若路径失效，则回退到当前 Downloads 目录按文件名恢复。
    public func resolveExistingLocalFileURL(for transfer: FileTransfer) async throws -> URL? {
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

        if let recovered = try await ClassicTransferSourceFileInspectionWorker.shared.resolveExistingFile(
            candidates: candidates,
            recoveryDirectory: downloadsDirectory,
            fileName: safeFileName
        ) {
            upsertLocalPath(recovered.path, for: transfer.id)
            return recovered
        }

        return nil
    }

    private func prepareClassicInboundDirectory() async throws {
        let prepared = try await InboundFileTransferIOActor.shared.prepareFirstWritableDirectory(
            from: [downloadsDirectory]
        )
        guard prepared.standardizedFileURL.path == downloadsDirectory.standardizedFileURL.path else {
            throw FileTransferError.transferFailed("经典文件接收目录不可用")
        }
    }
    
    // MARK: - Private Methods - Sending
    
    /// 分块发送文件
    private func sendFileInChunks(
        from url: URL,
        transfer: FileTransfer,
        securityContext: ClassicTransferSecurityContext,
        over connection: NWConnection,
        chunkSize: Int,
        compression: String?,
        expectedFileHash: String
    ) async throws {
        let fileReader = try await ClassicTransferOutboundFileReadSession.open(
            url: url,
            tracksSHA256: true
        )
        do {
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
            
                let chunkData = try await fileReader.read(
                    offset: UInt64(sentBytes),
                    length: Int(currentChunkSize)
                )
            
            // 可选：压缩数据
            let processedData: Data
            if compression == "zlib" {
                // Metadata already declares zlib for this transfer. Compression failure must
                // abort instead of sending raw bytes under a zlib contract.
                do {
                    processedData = try await ClassicTransferZlibCompressionWorker.shared.compress(
                        chunkData,
                        maximumInputSize: maxChunkSizeBytes
                    )
                } catch is CancellationError {
                    throw FileTransferError.transferCancelled
                }
            } else {
                processedData = chunkData
            }
            let encrypted: ClassicTransferEncryptedChunk
            do {
                encrypted = try await ClassicTransferChunkCryptoWorker.shared.sealAndHash(
                    payload: processedData,
                    plaintextChunk: chunkData,
                    using: securityContext.transferKey,
                    maximumPayloadSize: maxMessageBytes,
                    maximumPlaintextChunkSize: maxChunkSizeBytes
                )
            } catch is CancellationError {
                throw FileTransferError.transferCancelled
            } catch {
                throw FileTransferError.encryptionFailed
            }

            // 创建分块
            let chunk = FileChunk(
                index: chunkIndex,
                data: encrypted.ciphertext,
                size: chunkData.count,
                checksum: encrypted.plaintextSHA256Hex,
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

            let sourceDigest = try await fileReader.finalizeAndClose()
            let sourceHash = sourceDigest.map { String(format: "%02x", $0) }.joined()
            guard sourceHash == expectedFileHash else {
                throw FileTransferError.checksumMismatch
            }
            // 发送完成信号
            try await sendComplete(over: connection)
            logClassicReceiptPhase("all_chunks_sent", transferId: transfer.id)
        } catch {
            let transferError = error
            do {
                try await fileReader.close()
            } catch {
                throw FileTransferError.transferFailed(
                    "经典文件发送失败且关闭源文件失败: operation=\(transferError), close=\(error)"
                )
            }
            throw transferError
        }
    }
    
    /// 发送元数据
    private func sendMetadata(
        _ metadata: FileMetadata,
        securityContext: ClassicTransferSecurityContext,
        over connection: NWConnection
    ) async throws {
        let unsignedMetadata = unsignedMetadataCopy(
            from: metadata,
            securityVersion: ClassicTransferInboundPolicy.currentSecurityVersion
        )
        try ClassicTransferMetadataContract.validateSecurityVersion(unsignedMetadata.securityVersion)
        try await ClassicTransferJSONWorker.shared.validateMetadata(
            transferID: unsignedMetadata.transferId,
            fileName: unsignedMetadata.fileName,
            fileSize: unsignedMetadata.fileSize,
            fileHash: unsignedMetadata.fileHash,
            declaredChunkSize: unsignedMetadata.chunkSize,
            compression: unsignedMetadata.compression,
            displayFields: [
                unsignedMetadata.senderDeviceId,
                unsignedMetadata.senderDeviceName,
                unsignedMetadata.senderPlatform,
                unsignedMetadata.senderOSVersion,
                unsignedMetadata.senderModelName,
                unsignedMetadata.senderChip
            ]
        )
        let signedMetadata = FileMetadata(
            transferId: unsignedMetadata.transferId,
            fileName: unsignedMetadata.fileName,
            fileSize: unsignedMetadata.fileSize,
            fileHash: unsignedMetadata.fileHash,
            chunkSize: unsignedMetadata.chunkSize,
            securityVersion: unsignedMetadata.securityVersion,
            metadataAuthTag: authenticationTag(
                for: try metadataAuthenticationInput(unsignedMetadata),
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
        let data = try await ClassicTransferJSONWorker.shared.encode(
            signedMetadata,
            maximumOutputSize: maxMessageBytes
        )
        if data.count > maxMessageBytes {
            throw FileTransferError.invalidMetadata
        }
        let header = TransferHeader(type: .metadata, length: data.count)
        try await sendData(header.encoded + data, over: connection, stage: "send_metadata")
    }
    
    /// 发送分块
    private func sendChunk(_ chunk: FileChunk, over connection: NWConnection) async throws {
        let data = try await ClassicTransferJSONWorker.shared.encode(
            chunk,
            maximumOutputSize: maxMessageBytes
        )
        if data.count > maxMessageBytes {
            throw FileTransferError.invalidMetadata
        }
        let header = TransferHeader(type: .chunk, length: data.count)
        try await sendData(header.encoded + data, over: connection, stage: "send_chunk_\(chunk.index)")
    }
    
    /// 发送完成信号
    private func sendComplete(over connection: NWConnection) async throws {
        let header = TransferHeader(type: .complete, length: 0)
        try await sendData(header.encoded, over: connection, stage: "send_complete")
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
            securityVersion: ClassicTransferInboundPolicy.currentSecurityVersion
        )
        let signedReceipt = TransferReceipt(
            transferId: unsignedReceipt.transferId,
            success: unsignedReceipt.success,
            receivedBytes: unsignedReceipt.receivedBytes,
            fileHash: unsignedReceipt.fileHash,
            error: unsignedReceipt.error,
            securityVersion: unsignedReceipt.securityVersion,
            authTag: authenticationTag(
                for: try receiptAuthenticationInput(unsignedReceipt),
                using: securityContext.transferKey
            )
        )
        let data = try await ClassicTransferJSONWorker.shared.encode(
            signedReceipt,
            maximumOutputSize: maxMessageBytes
        )
        if data.count > maxMessageBytes {
            throw FileTransferError.invalidMetadata
        }
        let header = TransferHeader(type: .receipt, length: data.count)
        do {
            try await sendData(header.encoded + data, over: connection, stage: "send_receipt")
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
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                guard attempt < maxAttempts else { break }
                let receiptError = error as NSError
                SkyBridgeLogger.shared.warning(
                    "⚠️ 落盘回执发送失败，准备重试: attempt=\(attempt)/\(maxAttempts) domain=\(receiptError.domain) code=\(receiptError.code)"
                )
                try await Task.sleep(nanoseconds: retryDelayNanoseconds)
            }
        }

        throw lastError ?? FileTransferError.connectionFailed
    }

    private func sendSuccessfulReceiptAfterCommit(
        _ receipt: TransferReceipt,
        securityContext: ClassicTransferSecurityContext,
        over connection: NWConnection
    ) async -> FileTransferReceiptDeliveryStatus {
        do {
            try await sendReceiptReliably(
                receipt,
                securityContext: securityContext,
                over: connection
            )
            return .delivered
        } catch {
            let receiptError = error as NSError
            SkyBridgeLogger.shared.error(
                "❌ classic inbound file committed but success receipt delivery is unknown: domain=\(receiptError.domain) code=\(receiptError.code)"
            )
            NotificationCenter.default.post(
                name: .fileTransferReceiptDeliveryUnknown,
                object: nil,
                userInfo: ["transferId": receipt.transferId]
            )
            return .unknown
        }
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
            error: Self.stableErrorIdentifier(error),
            securityVersion: securityVersion
        )

        do {
            try await sendReceiptReliably(
                failure,
                securityContext: securityContext,
                over: connection
            )
        } catch {
            let receiptError = error as NSError
            SkyBridgeLogger.shared.error(
                "⚠️ failure receipt 未发送: domain=\(receiptError.domain) code=\(receiptError.code)"
            )
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
            header = try await receiveHeader(
                from: connection,
                timeout: receiptWaitTimeoutSeconds,
                stage: "receipt_header"
            )
        } catch FileTransferError.networkStageFailed(let stage, let endpoint, let details) {
            if stage == "receipt_header_timeout" {
                logClassicReceiptPhase(
                    FileTransferReceiptWaitStage.headerTimeout.rawValue,
                    transferId: expectedTransferId
                )
                throw FileTransferError.receiptWaitFailed(stage: .headerTimeout, details: nil)
            }
            logClassicReceiptPhase(stage, transferId: expectedTransferId, detail: details)
            throw FileTransferError.networkStageFailed(stage: stage, endpoint: endpoint, details: details)
        }
        guard header.type == .receipt else {
            throw FileTransferError.transferFailed("接收端未返回落盘回执")
        }
        guard header.length > 0 else {
            throw FileTransferError.invalidMetadata
        }

        let payload: Data
        do {
            payload = try await receiveData(
                length: header.length,
                from: connection,
                timeout: receiptWaitTimeoutSeconds,
                stage: "receipt_payload"
            )
        } catch FileTransferError.networkStageFailed(let stage, let endpoint, let details) {
            if stage == "receipt_payload_timeout" {
                logClassicReceiptPhase(
                    FileTransferReceiptWaitStage.payloadTimeout.rawValue,
                    transferId: expectedTransferId
                )
                throw FileTransferError.receiptWaitFailed(stage: .payloadTimeout, details: nil)
            }
            logClassicReceiptPhase(stage, transferId: expectedTransferId, detail: details)
            throw FileTransferError.networkStageFailed(stage: stage, endpoint: endpoint, details: details)
        }
        let receipt = try await ClassicTransferJSONWorker.shared.decode(
            TransferReceipt.self,
            from: payload,
            maximumInputSize: maxMessageBytes
        )
        do {
            try ClassicTransferMetadataContract.validateSecurityVersion(receipt.securityVersion)
            try ClassicTransferMetadataContract.validateTransferIdentifier(receipt.transferId)
            try ClassicTransferMetadataContract.validateVisibleField(
                receipt.error,
                maximumUTF8Length: 1_024
            )
            if let fileHash = receipt.fileHash {
                try ClassicTransferMetadataContract.validateSHA256Hex(fileHash)
            }
        } catch {
            throw FileTransferError.receiptWaitFailed(stage: .authFailed, details: nil)
        }
        let unsignedReceipt = unsignedReceiptCopy(from: receipt)
        guard receipt.transferId == expectedTransferId else {
            throw FileTransferError.invalidMetadata
        }
        guard isValidAuthenticationTag(
            receipt.authTag,
            payload: try receiptAuthenticationInput(unsignedReceipt),
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
        do {
            try ClassicTransferReceiptContract.validateSuccessfulFileHash(
                receipt.fileHash,
                expected: expectedFileHash
            )
        } catch {
            throw FileTransferError.checksumMismatch
        }

        return receipt
    }
    
    // MARK: - Private Methods - Receiving
    
    /// 分块接收文件
    private func receiveFileInChunks(
        transfer: FileTransfer,
        securityContext: ClassicTransferSecurityContext,
        from connection: NWConnection,
        metadata: FileMetadata,
        ioHandle: InboundFileTransferIOHandle
    ) async throws -> Data {
        var receivedBytes: Int64 = 0
        let totalBytes = metadata.fileSize
        var expectedChunkIndex = 0

        while receivedBytes < totalBytes {
            if let state = transferStates[transfer.id], state.isCancelled {
                throw FileTransferError.transferCancelled
            }

            let chunk = try await receiveChunk(from: connection)
            let decompressedOutputLimit: Int
            do {
                try ClassicTransferChunkContract.validateSequence(
                    chunkIndex: chunk.index,
                    expectedChunkIndex: expectedChunkIndex
                )
                decompressedOutputLimit = try ClassicTransferChunkContract.decompressedOutputLimit(
                    declaredChunkSize: chunk.size,
                    receivedBytes: receivedBytes,
                    declaredFileSize: totalBytes,
                    negotiatedChunkSize: metadata.chunkSize,
                    maximumChunkSize: maxChunkSizeBytes
                )
            } catch {
                throw FileTransferError.invalidMetadata
            }
            guard let nonce = chunk.nonce, let authenticationTag = chunk.authenticationTag else {
                throw FileTransferError.secureSessionRequired
            }
            let decrypted: Data
            do {
                decrypted = try await ClassicTransferChunkCryptoWorker.shared.open(
                    ciphertext: chunk.data,
                    nonce: nonce,
                    tag: authenticationTag,
                    using: securityContext.transferKey,
                    maximumCiphertextSize: maxMessageBytes
                )
            } catch is CancellationError {
                throw FileTransferError.transferCancelled
            } catch {
                throw FileTransferError.encryptionFailed
            }

            // Compression is governed exclusively by the authenticated metadata contract.
            let processedData: Data
            if metadata.compression == "zlib" {
                do {
                    processedData = try await ClassicTransferZlibDecompressionWorker.shared.decompress(
                        decrypted,
                        maximumOutputSize: decompressedOutputLimit
                    )
                } catch is CancellationError {
                    throw FileTransferError.transferCancelled
                } catch {
                    throw FileTransferError.invalidMetadata
                }
            } else {
                processedData = decrypted
            }
            do {
                try ClassicTransferChunkContract.validateDecodedChunkSize(
                    processedData.count,
                    declaredChunkSize: chunk.size
                )
            } catch {
                throw FileTransferError.invalidMetadata
            }

            _ = try await InboundFileTransferIOActor.shared.write(
                processedData,
                atOffset: UInt64(receivedBytes),
                using: ioHandle
            )
            receivedBytes += Int64(processedData.count)
            expectedChunkIndex += 1

            await updateProgress(
                transfer.id,
                transferredBytes: receivedBytes,
                totalBytes: totalBytes
            )
        }

        do {
            try ClassicTransferChunkContract.validateCompletion(
                receivedBytes: receivedBytes,
                declaredFileSize: totalBytes
            )
        } catch {
            throw FileTransferError.invalidMetadata
        }

        logClassicReceiptPhase("all_chunks_received", transferId: transfer.id)

        let completeHeader = try await receiveHeader(
            from: connection,
            stage: "receive_complete_header"
        )
        guard completeHeader.type == .complete, completeHeader.length == 0 else {
            throw FileTransferError.invalidMetadata
        }
        logClassicReceiptPhase("hash_verification_started", transferId: transfer.id)
        let digest = try await InboundFileTransferIOActor.shared.closeAndDigest(using: ioHandle)
        logClassicReceiptPhase("hash_verification_completed", transferId: transfer.id)
        return digest
    }
    
    /// 接收分块
    private func receiveChunk(from connection: NWConnection) async throws -> FileChunk {
        let header = try await receiveHeader(from: connection, stage: "receive_chunk_header")
        guard header.type == .chunk else {
            throw FileTransferError.invalidMetadata
        }

        let data = try await receiveData(
            length: header.length,
            from: connection,
            timeout: ClassicTransferInboundPolicy.frameIdleTimeoutSeconds,
            stage: "receive_chunk_payload"
        )
        let chunk = try await ClassicTransferJSONWorker.shared.decode(
            FileChunk.self,
            from: data,
            maximumInputSize: maxMessageBytes
        )
        if chunk.size <= 0
            || chunk.size > maxChunkSizeBytes
            || chunk.nonce?.count != 12
            || chunk.authenticationTag?.isEmpty != false {
            throw FileTransferError.invalidMetadata
        }
        return chunk
    }
    
    /// 接收头部
    private func receiveHeader(
        from connection: NWConnection,
        timeout: TimeInterval? = ClassicTransferInboundPolicy.frameIdleTimeoutSeconds,
        stage: String = "receive_header"
    ) async throws -> TransferHeader {
        let headerData = try await receiveData(length: 8, from: connection, timeout: timeout, stage: stage)
        guard let header = TransferHeader.decode(from: headerData) else {
            throw FileTransferError.invalidMetadata
        }
        guard header.length >= 0, header.length <= maxMessageBytes else {
            throw FileTransferError.invalidMetadata
        }
        return header
    }

    private func logClassicReceiptPhase(
        _ phase: String,
        transferId _: String,
        detail _: String? = nil
    ) {
        SkyBridgeLogger.shared.info("📨 classic_receipt_phase=\(phase)")
    }

    private static func stableErrorIdentifier(_ error: Error) -> String {
        guard let transferError = error as? FileTransferError else {
            return "external_failure"
        }
        switch transferError {
        case .fileNotFound: return "file_not_found"
        case .transferFailed: return "transfer_failed"
        case .invalidDestination: return "invalid_destination"
        case .connectionFailed: return "connection_failed"
        case .transferCancelled: return "transfer_cancelled"
        case .checksumMismatch: return "checksum_mismatch"
        case .invalidMetadata: return "invalid_metadata"
        case .diskFull: return "disk_full"
        case .permissionDenied: return "permission_denied"
        case .networkError: return "network_error"
        case .networkStageFailed: return "network_stage_failed"
        case .timeout: return "timeout"
        case let .receiptWaitFailed(stage, _): return "receipt_\(stage.rawValue)"
        case .deliveryConfirmationUnknown: return "delivery_confirmation_unknown"
        case .partialFileCleanupFailed: return "partial_file_cleanup_failed"
        case .committedFileReleaseFailed: return "committed_file_release_failed"
        case .encryptionFailed: return "encryption_failed"
        case .secureSessionRequired: return "secure_session_required"
        case .capacityExceeded: return "capacity_exceeded"
        case .invalidTransferState: return "invalid_transfer_state"
        }
    }

    // MARK: - Private Methods - Network

    /// 创建连接
    private func createConnection(toAnyOf endpoints: [NWEndpoint]) async throws -> NWConnection {
        guard !endpoints.isEmpty else {
            throw FileTransferError.networkStageFailed(
                stage: "connect_no_endpoint_candidates",
                endpoint: nil,
                details: "文件传输没有可尝试的 LAN 端点"
            )
        }

        var lastError: Error?
        for (index, endpoint) in endpoints.enumerated() {
            let endpointDescription = String(describing: endpoint)
            let addressClass = FileTransferLANRoutePolicy.routeAddressClass(for: endpoint)
            let peerToPeer = FileTransferLANRoutePolicy.shouldIncludePeerToPeer(for: endpoint)
            SkyBridgeLogger.shared.info(
                "🔗 文件传输连接候选[\(index + 1)/\(endpoints.count)]: addressClass=\(addressClass) peerToPeer=\(peerToPeer)"
            )
            SkyBridgeDiagnosticTrace.appendStatus(
                "file-transfer-route candidate=\(index + 1)/\(endpoints.count) addressClass=\(addressClass) peerToPeer=\(peerToPeer) endpoint=\(FileTransferLANRoutePolicy.statusToken(endpointDescription))"
            )

            do {
                let connection = try await createConnection(to: endpoint)
                SkyBridgeLogger.shared.info(
                    "✅ 文件传输连接就绪: addressClass=\(addressClass) peerToPeer=\(peerToPeer)"
                )
                return connection
            } catch {
                lastError = error
                let connectionError = error as NSError
                SkyBridgeLogger.shared.warning(
                    "⚠️ 文件传输候选连接失败[\(index + 1)/\(endpoints.count)]: addressClass=\(addressClass) domain=\(connectionError.domain) code=\(connectionError.code)"
                )
            }
        }

        if let lastError {
            throw lastError
        }
        throw FileTransferError.networkStageFailed(
            stage: "connect_no_attempts_completed",
            endpoint: nil,
            details: "文件传输候选端点未产生可报告的连接结果"
        )
    }

    private func createConnection(to endpoint: NWEndpoint) async throws -> NWConnection {
        let endpointDescription = String(describing: endpoint)
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = FileTransferLANRoutePolicy.shouldIncludePeerToPeer(for: endpoint)
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
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
                    let resolvedEndpoint = connection.currentPath?.remoteEndpoint
                    let routeReadyLine = "file-transfer-route-ready requestedAddressClass=\(FileTransferLANRoutePolicy.routeAddressClass(for: endpoint)) resolvedAddressClass=\(FileTransferLANRoutePolicy.routeAddressClass(for: resolvedEndpoint)) resolvedPeerToPeer=\(FileTransferLANRoutePolicy.routePrefersPeerToPeer(for: resolvedEndpoint)) requested=\(FileTransferLANRoutePolicy.statusToken(endpointDescription)) resolved=\(FileTransferLANRoutePolicy.statusToken(FileTransferLANRoutePolicy.routeDescription(for: resolvedEndpoint)))"
                    SkyBridgeLogger.shared.info(routeReadyLine)
                    SkyBridgeDiagnosticTrace.appendStatus(routeReadyLine)
                    SkyBridgeDiagnosticTrace.append(routeReadyLine)
                    if let rejection = FileTransferLANRoutePolicy.resolvedRouteRejection(
                        requestedEndpoint: endpoint,
                        resolvedEndpoint: resolvedEndpoint
                    ) {
                        once.run {
                            connection.stateUpdateHandler = nil
                            connection.cancel()
                            continuation.resume(throwing: FileTransferError.networkStageFailed(
                                stage: "connect_route_rejected",
                                endpoint: endpointDescription,
                                details: rejection
                            ))
                        }
                        return
                    }
                    once.run {
                        connection.stateUpdateHandler = nil
                        continuation.resume(returning: connection)
                    }
                case .waiting(let error):
                    let waitingError = error as NSError
                    SkyBridgeLogger.shared.warning(
                        "⏳ 文件传输连接等待: addressClass=\(FileTransferLANRoutePolicy.routeAddressClass(for: endpoint)) domain=\(waitingError.domain) code=\(waitingError.code)"
                    )
                case .failed(let error):
                    once.run {
                        connection.stateUpdateHandler = nil
                        continuation.resume(throwing: FileTransferError.networkStageFailed(
                            stage: "connect_failed",
                            endpoint: endpointDescription,
                            details: error.localizedDescription
                        ))
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
                        "❌ 文件传输连接超时: timeout=\(Int(FileTransferConstants.connectionTimeout))s"
                    )
                    connection.cancel()
                    continuation.resume(throwing: FileTransferError.networkStageFailed(
                        stage: "connect_timeout",
                        endpoint: endpointDescription,
                        details: "\(Int(FileTransferConstants.connectionTimeout))s"
                    ))
                }
            }
        }
    }

    /// 发送数据
    private func sendData(_ data: Data, over connection: NWConnection, stage: String = "send_data") async throws {
        // 上传限速（KB/s），0 表示不限制
        let kbps = SettingsManager.instance.fileTransferUploadLimitKBps
        if kbps <= 0 {
            try await sendDataSlice(data, over: connection, stage: stage)
            return
        }

        let bytesPerSecond = max(1024, kbps * 1024)
        let chunkBytes = max(8 * 1024, min(256 * 1024, bytesPerSecond / 4)) // 4 chunks/s

        var offset = 0
        while offset < data.count {
            let end = min(data.count, offset + chunkBytes)
            let slice = data.subdata(in: offset..<end)
            try await sendDataSlice(slice, over: connection, stage: stage)

            offset = end

            // 粗粒度节流：按 chunk 大小估算 sleep
            let seconds = Double(slice.count) / Double(bytesPerSecond)
            if seconds > 0 {
                try await Task.sleep(for: .seconds(seconds))
            }
        }
    }
    
    /// 接收数据
    private func receiveData(
        length: Int,
        from connection: NWConnection,
        timeout: TimeInterval? = nil,
        stage: String = "receive_data"
    ) async throws -> Data {
        guard length >= 0 else {
            throw FileTransferError.invalidMetadata
        }
        let operation = ClassicTransferReceiveOperation(expectedLength: length)
        let timeoutTask: Task<Void, Never>?
        if let timeout, timeout > 0 {
            timeoutTask = Task.detached(priority: .utility) {
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
                let timeoutError = FileTransferError.networkStageFailed(
                    stage: "\(stage)_timeout",
                    endpoint: nil,
                    details: "\(timeout)s"
                )
                if operation.fail(timeoutError) {
                    connection.cancel()
                }
            }
        } else {
            timeoutTask = nil
        }
        defer { timeoutTask?.cancel() }
        let data: Data = try await withTaskCancellationHandler(operation: {
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
                            _ = operation.fail(FileTransferError.networkStageFailed(
                                stage: stage,
                                endpoint: nil,
                                details: error.localizedDescription
                            ))
                            return
                        }
                        if let data, !data.isEmpty {
                            switch operation.append(data) {
                            case .completed, .ignoredAfterCompletion:
                                return
                            case .overflow:
                                if operation.fail(FileTransferError.invalidMetadata) {
                                    connection.cancel()
                                }
                                return
                            case .pending:
                                break
                            }
                        }
                        if isComplete {
                            _ = operation.fail(FileTransferError.networkStageFailed(
                                stage: "\(stage)_connection_closed",
                                endpoint: nil,
                                details: "Connection closed before \(length) bytes were received"
                            ))
                            return
                        }
                        guard !operation.isCompleted else { return }
                        receiveMore()
                    }
                }

                receiveMore()
            }
        }, onCancel: {
            if operation.fail(FileTransferError.transferCancelled) {
                connection.cancel()
            }
        })

        // 下载限速（KB/s），0 表示不限制。仅做“消费端节流”，减少写盘/处理速度。
        let kbps = SettingsManager.instance.fileTransferDownloadLimitKBps
        if kbps > 0 {
            let bytesPerSecond = max(1024, kbps * 1024)
            let seconds = Double(data.count) / Double(bytesPerSecond)
            if seconds > 0 {
                try await Task.sleep(for: .seconds(seconds))
            }
        }
        return data
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

        guard let resolution = FileTransferClassicPeerResolutionPolicy.resolvePeer(
            peerContext: peerContext,
            authenticatedPeers: authenticatedPeers
        ) else {
            SkyBridgeLogger.shared.error(
                "❌ 无法解析文件传输安全会话: authenticatedConnections=\(authenticatedPeers.count) matchedFallbackBranch=none"
            )
            throw FileTransferError.secureSessionRequired
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

    private func metadataAuthenticationInput(_ metadata: FileMetadata) throws -> Data {
        try ClassicTransferCanonicalTranscript.metadata(
            transferID: metadata.transferId,
            fileName: metadata.fileName,
            fileSize: metadata.fileSize,
            fileHash: metadata.fileHash,
            chunkSize: metadata.chunkSize,
            securityVersion: metadata.securityVersion ?? 0,
            compression: metadata.compression,
            senderDeviceID: metadata.senderDeviceId,
            senderDeviceName: metadata.senderDeviceName,
            senderPlatform: metadata.senderPlatform,
            senderOSVersion: metadata.senderOSVersion,
            senderModelName: metadata.senderModelName,
            senderChip: metadata.senderChip
        )
    }

    private func receiptAuthenticationInput(_ receipt: TransferReceipt) throws -> Data {
        try ClassicTransferCanonicalTranscript.receipt(
            transferID: receipt.transferId,
            success: receipt.success,
            receivedBytes: receipt.receivedBytes,
            fileHash: receipt.fileHash,
            error: receipt.error,
            securityVersion: receipt.securityVersion ?? 0
        )
    }

    private func authenticationTag(for payload: Data, using key: SymmetricKey) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: payload, using: key))
    }

    private func isValidAuthenticationTag(_ tag: Data?, payload: Data, key: SymmetricKey) -> Bool {
        ClassicTransferAuthenticationContract.isValidHMACSHA256(
            tag,
            authenticating: payload,
            using: key
        )
    }

    private func acquireTransferSlot() async throws {
        let limit = min(
            ClassicTransferInboundPolicy.maximumConcurrentConnections,
            max(1, SettingsManager.instance.fileTransferMaxConcurrentTransfers)
        )
        let waiterId = UUID()
        switch transferSlotPolicy.request(
            identifier: waiterId,
            configuredLimit: limit
        ) {
        case .acquired:
            return
        case .capacityExceeded:
            throw FileTransferError.capacityExceeded
        case .queued:
            break
        }
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    _ = transferSlotPolicy.cancelPending(identifier: waiterId)
                    continuation.resume(throwing: CancellationError())
                    return
                }
                transferSlotContinuations[waiterId] = continuation
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

    private func sendDataSlice(
        _ data: Data,
        over connection: NWConnection,
        stage: String
    ) async throws {
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
            let timeoutError = FileTransferError.networkStageFailed(
                stage: "\(stage)_timeout",
                endpoint: nil,
                details: "\(ClassicTransferInboundPolicy.frameSendTimeoutSeconds)s"
            )
            if operation.fail(timeoutError) {
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
                        let mappedError = FileTransferError.networkStageFailed(
                            stage: stage,
                            endpoint: nil,
                            details: error.localizedDescription
                        )
                        if operation.fail(mappedError) {
                            connection.cancel()
                        }
                    } else {
                        _ = operation.succeed()
                    }
                })
            }
        }, onCancel: {
            if operation.fail(FileTransferError.transferCancelled) {
                connection.cancel()
            }
        })
    }

    private func releaseTransferSlot() {
        let limit = min(
            ClassicTransferInboundPolicy.maximumConcurrentConnections,
            max(1, SettingsManager.instance.fileTransferMaxConcurrentTransfers)
        )
        let resumedIdentifiers = transferSlotPolicy.release(configuredLimit: limit)
        for identifier in resumedIdentifiers {
            guard let continuation = transferSlotContinuations.removeValue(forKey: identifier) else {
                preconditionFailure("Classic transfer slot continuation missing for queued waiter")
            }
            continuation.resume(returning: ())
        }
    }

    private func cancelTransferWaiter(id: UUID) {
        guard transferSlotPolicy.cancelPending(identifier: id) else {
            return
        }
        transferSlotContinuations.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    nonisolated static func transferSlotReleaseAction(
        inFlightTransferCount: Int,
        waiterCount: Int,
        limit: Int
    ) -> TransferSlotReleaseAction {
        let normalizedLimit = min(
            ClassicTransferInboundPolicy.maximumConcurrentConnections,
            max(1, limit)
        )
        let decrementedCount = max(0, inFlightTransferCount - 1)

        if waiterCount > 0, decrementedCount < normalizedLimit {
            return .resumeWaiter(nextInFlightCount: decrementedCount + 1)
        }

        return .decrementTo(decrementedCount)
    }

    // MARK: - Private Methods - Utilities
    
    /// 计算文件哈希；共享 reader actor 负责流式读取、取消和显式关闭。
    private func calculateFileHash(at url: URL) async throws -> String {
        let reader = try await ClassicTransferOutboundFileReadSession.open(
            url: url,
            tracksSHA256: false
        )
        let digest = try await reader.hashWholeFileAndClose()
        return digest.map { String(format: "%02x", $0) }.joined()
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
            enqueueHistoryCommand(
                .updateLocalPath(transferID: transferId, localPath: localPath)
            )
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
                let notificationError = error as NSError
                SkyBridgeLogger.shared.debug(
                    "ℹ️ 文件通知发送失败: domain=\(notificationError.domain) code=\(notificationError.code)"
                )
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
            prependHistoryForPresentation(completedTransfer)
            enqueueHistoryCommand(.prepend(completedTransfer))
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
    @discardableResult
    public func beginExternalInboundTransfer(
        transferId: String,
        fileName: String,
        fileSize: Int64,
        fromPeerName: String,
        destinationURL: URL? = nil
    ) -> ExternalTransferToken? {
        guard !activeTransfers.contains(where: { $0.id == transferId }),
              transferStates[transferId] == nil,
              externalTransferTokensByTransferID[transferId] == nil else {
            return nil
        }

        let token = ExternalTransferToken(
            identifier: UUID(),
            transferID: transferId
        )

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
        externalTransferTokensByTransferID[transferId] = token
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
        return token
    }

    public func markExternalInboundSavedLocation(
        token: ExternalTransferToken,
        destinationURL: URL
    ) {
        guard activeExternalInboundTransferIndex(matching: token) != nil else { return }
        upsertLocalPath(destinationURL.path, for: token.transferID)
    }

    public func updateExternalInboundProgress(
        token: ExternalTransferToken,
        transferredBytes: Int64,
        totalBytes: Int64
    ) async {
        guard activeExternalInboundTransferIndex(matching: token) != nil else { return }
        await updateProgress(
            token.transferID,
            transferredBytes: transferredBytes,
            totalBytes: totalBytes
        )
    }

    public func completeExternalInboundTransfer(
        token: ExternalTransferToken,
        success: Bool,
        error: String? = nil,
        destinationURL: URL? = nil,
        receiptDeliveryStatus: FileTransferReceiptDeliveryStatus? = nil,
        operationalWarning: FileTransferOperationalWarning? = nil
    ) {
        guard let currentIndex = activeExternalInboundTransferIndex(matching: token) else {
            return
        }
        let transferId = token.transferID
        if let destinationURL {
            upsertLocalPath(destinationURL.path, for: transferId)
        }

        var completedTransfer: FileTransfer?
        if activeTransfers.indices.contains(currentIndex) {
            activeTransfers[currentIndex].status = success ? .completed : .failed
            if success { activeTransfers[currentIndex].progress = 1.0 }
            if let destinationURL {
                activeTransfers[currentIndex].localPath = destinationURL.path
            }
            activeTransfers[currentIndex].receiptDeliveryStatus = receiptDeliveryStatus
            activeTransfers[currentIndex].operationalWarning = operationalWarning
            let finalized = activeTransfers[currentIndex]
            completedTransfer = finalized
            activeTransfers.remove(at: currentIndex)
            externalTransferTokensByTransferID.removeValue(forKey: transferId)
            prependHistoryForPresentation(finalized)
            enqueueHistoryCommand(.prepend(finalized))
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

    private func activeExternalInboundTransferIndex(
        matching token: ExternalTransferToken
    ) -> Int? {
        guard externalTransferTokensByTransferID[token.transferID] == token,
              let index = activeTransfers.firstIndex(where: { $0.id == token.transferID }),
              activeTransfers[index].isIncoming,
              activeTransfers[index].status == .pending
                || activeTransfers[index].status == .transferring else {
            return nil
        }
        return index
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
    
    private func prependHistoryForPresentation(_ transfer: FileTransfer) {
        transferHistory.removeAll { $0.id == transfer.id }
        transferHistory.insert(transfer, at: 0)
        if transferHistory.count > FileTransferHistoryRepository.historyLimit {
            transferHistory.removeLast(
                transferHistory.count - FileTransferHistoryRepository.historyLimit
            )
        }
    }

    private func enqueueHistoryCommand(_ command: FileTransferHistoryCommand) {
        let incrementedGeneration = nextHistoryGeneration.addingReportingOverflow(1)
        precondition(!incrementedGeneration.overflow, "File-transfer history generation overflow")
        nextHistoryGeneration = incrementedGeneration.partialValue
        latestHistoryIntentGeneration = nextHistoryGeneration
        pendingHistoryCommands.append(
            PendingHistoryCommand(generation: nextHistoryGeneration, command: command)
        )

        guard historyDrainTask == nil else { return }
        historyDrainTask = Task { @MainActor [weak self] in
            await self?.drainHistoryCommands()
        }
    }

    private func drainHistoryCommands() async {
        while pendingHistoryCommandIndex < pendingHistoryCommands.count {
            let pending = pendingHistoryCommands[pendingHistoryCommandIndex]
            let snapshot = await historyRepository.apply(
                pending.command,
                generation: pending.generation
            )
            pendingHistoryCommandIndex += 1

            if pending.generation == latestHistoryIntentGeneration {
                applyHistorySnapshot(snapshot)
            }
        }

        pendingHistoryCommands.removeAll(keepingCapacity: true)
        pendingHistoryCommandIndex = 0
        historyDrainTask = nil
    }

    private func applyHistorySnapshot(_ snapshot: FileTransferHistorySnapshot) {
        transferHistory = Array(
            snapshot.history.prefix(FileTransferHistoryRepository.historyLimit)
        )
        historyPersistenceError = snapshot.failure?.presentationToken

        if let failure = snapshot.failure {
            SkyBridgeLogger.shared.error(
                "File transfer history persistence failed: domain=\(FileTransferHistoryPersistenceFailure.domain) code=\(failure.code.rawValue)"
            )
        }
    }
}

#if DEBUG || SKYBRIDGE_TESTING
@available(iOS 17.0, *)
extension FileTransferManager {
    func installUITestHistoryFixture(for deviceName: String) throws {
        let fixtureURL = downloadsDirectory.appendingPathComponent("UITest-Transfer-Guide.txt")
        let fixtureData = Data("SkyBridge UI test fixture file".utf8)
        if !fileManager.fileExists(atPath: fixtureURL.path) {
            try fixtureData.write(to: fixtureURL, options: [.atomic, .withoutOverwriting])
        }

        let fixture = FileTransfer(
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
        transferHistory = [fixture]
        activeTransfers = []
        isTransferring = false
        totalProgress = 0
        enqueueHistoryCommand(.replaceForTesting([fixture]))
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
#endif
