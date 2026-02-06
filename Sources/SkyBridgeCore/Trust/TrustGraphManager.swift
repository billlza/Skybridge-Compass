import Foundation
import OSLog
import Combine
import CryptoKit

// MARK: - 信任图谱管理器
/// 管理设备信任关系的图谱，支持信任链、撤销和过期管理
@MainActor
public final class TrustGraphManager: ObservableObject {
    
    // MARK: - 单例
    
    public static let shared = TrustGraphManager()
    
    // MARK: - 发布属性
    
    /// 所有信任的设备
    @Published public private(set) var trustedDevices: [TrustGraphDevice] = []
    
    /// 待处理的信任请求
    @Published public private(set) var pendingRequests: [TrustRequest] = []
    
    /// 最近的信任事件
    @Published public private(set) var recentEvents: [TrustEvent] = []
    
    /// 同步状态
    @Published public private(set) var syncStatus: TrustGraphSyncStatus = .idle
    
    // MARK: - 私有属性
    
    private let logger = Logger(subsystem: "com.skybridge.trust", category: "TrustGraph")
    private let trustSyncService = TrustSyncService.shared
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - 初始化
    
    private init() {
        Task {
            await loadTrustGraphDevices()
        }
    }
    
    // MARK: - 公开 API
    
    /// 刷新信任设备列表
    public func refresh() async {
        await loadTrustGraphDevices()
    }
    
    /// 添加信任设备
    public func trustDevice(
        _ deviceId: String,
        publicKey: Data,
        deviceName: String?,
        attestationLevel: P2PAttestationLevel = .none
    ) async throws {
        logger.info("🔐 添加信任设备: \(deviceId)")
        
        // 计算公钥指纹
        let pubKeyFP = computeFingerprint(publicKey)
        
        // 创建信任记录
        let record = TrustRecord(
            deviceId: deviceId,
            pubKeyFP: pubKeyFP,
            publicKey: publicKey,
            secureEnclavePublicKey: nil,
            protocolPublicKey: nil,
            legacyP256PublicKey: nil,
            signatureAlgorithm: nil,
            kemPublicKeys: nil,
            attestationLevel: attestationLevel,
            attestationData: nil,
            capabilities: [],
            createdAt: Date(),
            updatedAt: Date(),
            version: 1,
            signature: Data(), // 将在保存时签名
            recordType: .add,
            revokedAt: nil,
            deviceName: deviceName
        )
        
        // 保存到信任存储
        try await trustSyncService.addTrustRecord(record)
        
        // 更新本地列表
        await loadTrustGraphDevices()
        
        // 记录事件
        addEvent(.deviceTrusted(deviceId: deviceId, deviceName: deviceName))
        
        logger.info("✅ 设备已信任: \(deviceId)")
    }
    
    /// 撤销设备信任
    public func revokeDevice(_ deviceId: String) async throws {
        logger.info("🚫 撤销设备信任: \(deviceId)")
        
        guard let device = trustedDevices.first(where: { $0.deviceId == deviceId }) else {
            throw TrustGraphError.deviceNotFound
        }
        
        // 撤销信任
        try await trustSyncService.revokeTrustRecord(deviceId: deviceId)
        
        // 更新本地列表
        await loadTrustGraphDevices()
        
        // 记录事件
        addEvent(.deviceRevoked(deviceId: deviceId, deviceName: device.displayName))
        
        logger.info("✅ 设备信任已撤销: \(deviceId)")
    }

    /// 应用设备“身份密钥轮换”（将旧 deviceId 撤销，并信任新证书对应的 deviceId）
    ///
    /// 设计约束（安全默认）：
    /// - 不接受仅 self-signed 的新证书（无法证明与旧身份的连续性）
    /// - 允许：
    ///   - `pairing-confirmed` 且 signerId == oldDeviceId（旧身份对新证书背书）
    ///   - `user-domain-signed`（域 CA 背书；若未配置 CA，验证将失败）
    public func applyKeyRotation(oldDeviceId: String, newCertificate: P2PIdentityCertificate) async throws {
        guard trustedDevices.contains(where: { $0.deviceId == oldDeviceId }) else {
            throw TrustGraphError.deviceNotFound
        }

        guard newCertificate.deviceId != oldDeviceId else {
            throw TrustKeyRotationError.newDeviceIdUnchanged
        }

        switch newCertificate.signerType {
        case .selfSigned:
            throw TrustKeyRotationError.selfSignedNotAllowed
        case .pairingConfirmed:
            guard let signerId = newCertificate.signerId else {
                throw TrustKeyRotationError.missingSignerId
            }
            guard signerId == oldDeviceId else {
                throw TrustKeyRotationError.signerMismatch(expected: oldDeviceId, actual: signerId)
            }
        case .userDomainSigned:
            // 验证时会检查 CA 是否已配置
            break
        }

        // 证书签名/过期/指纹一致性验证
        _ = try await P2PIdentityCertificateIssuer.shared.verifyCertificate(newCertificate)

        let oldName = trustedDevices.first(where: { $0.deviceId == oldDeviceId })?.displayName

        // 更新 Keychain/iCloud Keychain 同步记录（tombstone + add）
        try await trustSyncService.handleKeyRotation(
            oldDeviceId: oldDeviceId,
            newDeviceId: newCertificate.deviceId,
            newCertificate: newCertificate
        )

        await loadTrustGraphDevices()

        // 事件：用已有事件类型表达“旧撤销 + 新信任”
        addEvent(.deviceRevoked(deviceId: oldDeviceId, deviceName: oldName))
        addEvent(.deviceTrusted(deviceId: newCertificate.deviceId, deviceName: oldName))
    }
    
    /// 更新设备信息
    public func updateDevice(_ deviceId: String, name: String?) async throws {
        logger.info("📝 更新设备信息: \(deviceId)")
        
        // 更新信任记录
        // 注意：TrustSyncService 可能需要扩展来支持更新
        
        // 更新本地列表
        await loadTrustGraphDevices()
    }
    
    /// 验证设备身份
    public func verifyDevice(_ deviceId: String, publicKey: Data) async -> VerificationResult {
        guard let device = trustedDevices.first(where: { $0.deviceId == deviceId }) else {
            return .notTrusted
        }
        
        // 检查公钥是否匹配
        let fingerprint = computeFingerprint(publicKey)
        if device.pubKeyFP != fingerprint {
            addEvent(.identityMismatch(deviceId: deviceId, expected: device.pubKeyFP, actual: fingerprint))
            return .keyMismatch(expected: device.pubKeyFP, actual: fingerprint)
        }
        
        // 检查是否被撤销
        if device.isRevoked {
            return .revoked
        }
        
        // 检查是否过期
        if device.isExpired {
            return .expired
        }
        
        return .verified(device: device)
    }
    
    /// 处理信任请求
    public func acceptRequest(_ requestId: UUID) async throws {
        guard let index = pendingRequests.firstIndex(where: { $0.id == requestId }) else {
            throw TrustGraphError.requestNotFound
        }
        
        let request = pendingRequests[index]
        
        // 添加信任
        try await trustDevice(
            request.deviceId,
            publicKey: request.publicKey,
            deviceName: request.deviceName,
            attestationLevel: request.attestationLevel
        )
        
        // 移除请求
        pendingRequests.remove(at: index)
    }
    
    /// 拒绝信任请求
    public func rejectRequest(_ requestId: UUID) {
        guard let index = pendingRequests.firstIndex(where: { $0.id == requestId }) else { return }
        
        let request = pendingRequests[index]
        addEvent(.requestRejected(deviceId: request.deviceId, deviceName: request.deviceName))
        pendingRequests.remove(at: index)
    }
    
    /// 添加待处理的信任请求
    public func addPendingRequest(_ request: TrustRequest) {
        guard !pendingRequests.contains(where: { $0.deviceId == request.deviceId }) else { return }
        pendingRequests.append(request)
        addEvent(.requestReceived(deviceId: request.deviceId, deviceName: request.deviceName))
    }
    
    /// 获取设备的信任链
    public func getTrustChain(for deviceId: String) -> [TrustGraphDevice] {
        // 简单实现：目前只返回直接信任的设备
        // 未来可以扩展为支持多级信任链
        guard let device = trustedDevices.first(where: { $0.deviceId == deviceId }) else {
            return []
        }
        return [device]
    }
    
    /// 清除所有信任
    public func clearAllTrust() async {
        logger.warning("⚠️ 清除所有信任记录")
        
        for device in trustedDevices {
            try? await revokeDevice(device.deviceId)
        }
        
        addEvent(.allTrustCleared)
    }
    
    /// 触发 iCloud 同步
    public func syncWithiCloud() async {
        syncStatus = .syncing
        
        // 从 Keychain 重新加载信任记录
        await loadTrustGraphDevices()
        syncStatus = .completed(Date())
        addEvent(.syncCompleted)
    }
    
    // MARK: - 私有方法
    
    private func loadTrustGraphDevices() async {
        let records = await trustSyncService.getActiveTrustRecords()
        
        trustedDevices = records
            .filter { !$0.isTombstone }
            .map { record in
                TrustGraphDevice(
                    deviceId: record.deviceId,
                    displayName: record.deviceName ?? record.shortId,
                    pubKeyFP: record.pubKeyFP,
                    attestationLevel: record.attestationLevel,
                    capabilities: record.capabilities,
                    trustedAt: record.createdAt,
                    lastSeenAt: record.updatedAt,
                    isRevoked: record.isTombstone,
                    revokedAt: record.revokedAt,
                    signatureAlgorithm: record.signatureAlgorithm
                )
            }
            .sorted { $0.trustedAt > $1.trustedAt }
        
        logger.info("📋 加载了 \(self.trustedDevices.count) 个信任设备")
    }
    
    private func computeFingerprint(_ publicKey: Data) -> String {
        let hash = SHA256.hash(data: publicKey)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
    
    private func addEvent(_ event: TrustEvent) {
        recentEvents.insert(event, at: 0)
        if recentEvents.count > 100 {
            recentEvents.removeLast()
        }
    }
}

// MARK: - Key rotation errors

enum TrustKeyRotationError: Error, LocalizedError, Sendable {
    case newDeviceIdUnchanged
    case selfSignedNotAllowed
    case missingSignerId
    case signerMismatch(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .newDeviceIdUnchanged:
            return "新证书的 deviceId 与旧 deviceId 相同，无法执行轮换。"
        case .selfSignedNotAllowed:
            return "出于安全原因，不接受仅 self-signed 的新证书。请使用 pairing-confirmed（由旧身份签名）或 user-domain-signed。"
        case .missingSignerId:
            return "证书缺少 signerId（无法验证 pairing-confirmed 证书的签名者）。"
        case .signerMismatch(let expected, let actual):
            return "证书 signerId 不匹配：期望 \(expected)，实际 \(actual)。"
        }
    }
}

// MARK: - 数据类型

/// 信任图谱设备信息
public struct TrustGraphDevice: Identifiable, Hashable, Sendable {
    public var id: String { deviceId }
    
    public let deviceId: String
    public let displayName: String
    public let pubKeyFP: String
    public let attestationLevel: P2PAttestationLevel
    public let capabilities: [String]
    public let trustedAt: Date
    public let lastSeenAt: Date
    public let isRevoked: Bool
    public let revokedAt: Date?
    public let signatureAlgorithm: SignatureAlgorithm?
    
    /// 短指纹（用于 UI 显示）
    public var shortFingerprint: String {
        String(pubKeyFP.prefix(16))
    }
    
    /// 是否过期（90 天未见）
    public var isExpired: Bool {
        Date().timeIntervalSince(lastSeenAt) > 90 * 24 * 60 * 60
    }
    
    /// 信任状态
    public var trustStatus: TrustStatus {
        if isRevoked {
            return .revoked
        } else if isExpired {
            return .expired
        } else {
            return .active
        }
    }
    
    /// 安全等级描述
    public var securityLevelDescription: String {
        // 与协议定义对齐：none / deviceCheck / appAttest
        switch attestationLevel {
        case .none:
            return "基础信任"
        case .deviceCheck:
            return "设备信号（DeviceCheck）"
        case .appAttest:
            return "硬件证明（App Attest）"
        }
    }
    
    public enum TrustStatus: String, Sendable {
        case active = "活跃"
        case expired = "已过期"
        case revoked = "已撤销"
        
        public var color: String {
            switch self {
            case .active: return "green"
            case .expired: return "orange"
            case .revoked: return "red"
            }
        }
    }

    // Hashable：对 UI selection 来说，用 deviceId 作为稳定主键即可
    public static func == (lhs: TrustGraphDevice, rhs: TrustGraphDevice) -> Bool {
        lhs.deviceId == rhs.deviceId
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(deviceId)
    }
}

/// 信任请求
public struct TrustRequest: Identifiable, Sendable {
    public let id: UUID
    public let deviceId: String
    public let deviceName: String?
    public let publicKey: Data
    public let pubKeyFP: String
    public let attestationLevel: P2PAttestationLevel
    public let receivedAt: Date
    
    public init(
        id: UUID = UUID(),
        deviceId: String,
        deviceName: String?,
        publicKey: Data,
        attestationLevel: P2PAttestationLevel = .none
    ) {
        self.id = id
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.publicKey = publicKey
        self.pubKeyFP = SHA256.hash(data: publicKey).map { String(format: "%02x", $0) }.joined()
        self.attestationLevel = attestationLevel
        self.receivedAt = Date()
    }
}

/// 信任事件
public enum TrustEvent: Identifiable, Sendable {
    case deviceTrusted(deviceId: String, deviceName: String?)
    case deviceRevoked(deviceId: String, deviceName: String?)
    case requestReceived(deviceId: String, deviceName: String?)
    case requestRejected(deviceId: String, deviceName: String?)
    case identityMismatch(deviceId: String, expected: String, actual: String)
    case syncCompleted
    case syncFailed(error: String)
    case allTrustCleared
    
    public var id: String {
        switch self {
        case .deviceTrusted(let id, _): return "trusted-\(id)-\(Date().timeIntervalSince1970)"
        case .deviceRevoked(let id, _): return "revoked-\(id)-\(Date().timeIntervalSince1970)"
        case .requestReceived(let id, _): return "request-\(id)-\(Date().timeIntervalSince1970)"
        case .requestRejected(let id, _): return "rejected-\(id)-\(Date().timeIntervalSince1970)"
        case .identityMismatch(let id, _, _): return "mismatch-\(id)-\(Date().timeIntervalSince1970)"
        case .syncCompleted: return "sync-\(Date().timeIntervalSince1970)"
        case .syncFailed: return "sync-failed-\(Date().timeIntervalSince1970)"
        case .allTrustCleared: return "cleared-\(Date().timeIntervalSince1970)"
        }
    }
    
    public var timestamp: Date { Date() }
    
    public var description: String {
        switch self {
        case .deviceTrusted(_, let name):
            return "已信任设备: \(name ?? "未命名")"
        case .deviceRevoked(_, let name):
            return "已撤销信任: \(name ?? "未命名")"
        case .requestReceived(_, let name):
            return "收到信任请求: \(name ?? "未命名")"
        case .requestRejected(_, let name):
            return "已拒绝请求: \(name ?? "未命名")"
        case .identityMismatch(let id, _, _):
            return "身份不匹配: \(id)"
        case .syncCompleted:
            return "iCloud 同步完成"
        case .syncFailed(let error):
            return "同步失败: \(error)"
        case .allTrustCleared:
            return "已清除所有信任"
        }
    }
    
    public var icon: String {
        switch self {
        case .deviceTrusted: return "checkmark.shield.fill"
        case .deviceRevoked: return "xmark.shield.fill"
        case .requestReceived: return "person.badge.plus"
        case .requestRejected: return "person.badge.minus"
        case .identityMismatch: return "exclamationmark.triangle.fill"
        case .syncCompleted: return "icloud.and.arrow.down"
        case .syncFailed: return "icloud.slash"
        case .allTrustCleared: return "trash"
        }
    }
}

/// 验证结果
public enum VerificationResult: Sendable {
    case verified(device: TrustGraphDevice)
    case notTrusted
    case revoked
    case expired
    case keyMismatch(expected: String, actual: String)
    
    public var isValid: Bool {
        if case .verified = self { return true }
        return false
    }
}

/// 信任图谱同步状态
public enum TrustGraphSyncStatus: Sendable {
    case idle
    case syncing
    case completed(Date)
    case failed(String)
}

/// 信任图谱错误
public enum TrustGraphError: Error, LocalizedError {
    case deviceNotFound
    case requestNotFound
    case invalidPublicKey
    case syncFailed(underlying: Error)
    
    public var errorDescription: String? {
        switch self {
        case .deviceNotFound:
            return "设备未找到"
        case .requestNotFound:
            return "请求未找到"
        case .invalidPublicKey:
            return "无效的公钥"
        case .syncFailed(let error):
            return "同步失败: \(error.localizedDescription)"
        }
    }
}

