//
// AttestationService.swift
// SkyBridgeCore
//
// iOS/iPadOS P2P Integration - Attestation Verification Service
// Requirements: 2.6 (attestationLevel)
//
// 设备证明验证服务：
// 1. App Attest / DeviceCheck 客户端请求
// 2. 证明数据缓存和刷新策略
// 3. 离线策略：attestationLevel 仅作为历史证据，不阻断连接
// 4. 风险评分影响：rate limit 阈值 / UI 警告文本
//

import Foundation
import CryptoKit
import DeviceCheck

// MARK: - Attestation Status

/// 证明验证状态
public enum AttestationStatus: String, Codable, Sendable {
 /// 未验证
    case unverified = "unverified"
    
 /// 验证中
    case verifying = "verifying"
    
 /// 已验证（有效）
    case verified = "verified"
    
 /// 验证失败
    case failed = "failed"
    
 /// 已过期（需要刷新）
    case expired = "expired"
    
 /// 不可用（设备不支持）
    case unavailable = "unavailable"
}

// MARK: - Attestation Result

/// 证明验证结果
public struct AttestationResult: Codable, Sendable {
 /// 证明等级
    public let level: P2PAttestationLevel
    
 /// 验证状态
    public let status: AttestationStatus
    
 /// 证明数据（Base64 编码）
    public let attestationData: Data?
    
 /// 验证时间
    public let verifiedAt: Date?
    
 /// 过期时间
    public let expiresAt: Date?
    
 /// 风险评分 (0.0 - 1.0, 越低越安全)
    public let riskScore: Double
    
 /// 错误信息（如果验证失败）
    public let errorMessage: String?
    
    public init(
        level: P2PAttestationLevel,
        status: AttestationStatus,
        attestationData: Data? = nil,
        verifiedAt: Date? = nil,
        expiresAt: Date? = nil,
        riskScore: Double = 0.5,
        errorMessage: String? = nil
    ) {
        self.level = level
        self.status = status
        self.attestationData = attestationData
        self.verifiedAt = verifiedAt
        self.expiresAt = expiresAt
        self.riskScore = riskScore
        self.errorMessage = errorMessage
    }
    
 /// 是否有效
    public var isValid: Bool {
        guard status == .verified else { return false }
        if let expiresAt = expiresAt {
            return Date() < expiresAt
        }
        return true
    }
    
 /// 是否需要刷新
    public var needsRefresh: Bool {
        switch status {
        case .expired, .failed, .unverified:
            return true
        case .verified:
            if let expiresAt = expiresAt {
 // 提前 1 小时刷新
                return Date().addingTimeInterval(3600) > expiresAt
            }
            return false
        default:
            return false
        }
    }
}

// MARK: - Attestation Cache Entry

/// 证明缓存条目
struct AttestationCacheEntry: Codable, Sendable {
    let deviceId: String
    let result: AttestationResult
    let cachedAt: Date
    
    var isExpired: Bool {
 // 缓存有效期 24 小时
        Date().timeIntervalSince(cachedAt) > 24 * 60 * 60
    }
}

// MARK: - Attestation Error

/// 证明验证错误
public enum AttestationError: Error, LocalizedError, Sendable {
    case deviceNotSupported
    case attestationGenerationFailed(String)
    case serverVerificationFailed(String)
    case networkError(String)
    case invalidResponse
    case cacheError(String)
    case rateLimited
    
    public var errorDescription: String? {
        switch self {
        case .deviceNotSupported:
            return "Device does not support attestation"
        case .attestationGenerationFailed(let reason):
            return "Attestation generation failed: \(reason)"
        case .serverVerificationFailed(let reason):
            return "Server verification failed: \(reason)"
        case .networkError(let reason):
            return "Network error: \(reason)"
        case .invalidResponse:
            return "Invalid server response"
        case .cacheError(let reason):
            return "Cache error: \(reason)"
        case .rateLimited:
            return "Rate limited, please try again later"
        }
    }
}

// MARK: - Risk Assessment

/// 风险评估结果
public struct RiskAssessment: Sendable {
 /// 风险评分 (0.0 - 1.0)
    public let score: Double
    
 /// 建议的 rate limit 阈值倍数
    public let rateLimitMultiplier: Double
    
 /// UI 警告级别
    public let warningLevel: WarningLevel
    
 /// 警告消息
    public let warningMessage: String?
    
 /// 是否允许连接（始终为 true，attestation 不阻断连接）
    public let allowConnection: Bool = true
    
    public enum WarningLevel: Int, Sendable {
        case none = 0
        case info = 1
        case warning = 2
        case critical = 3
    }
    
    public init(
        score: Double,
        rateLimitMultiplier: Double,
        warningLevel: WarningLevel,
        warningMessage: String?
    ) {
        self.score = score
        self.rateLimitMultiplier = rateLimitMultiplier
        self.warningLevel = warningLevel
        self.warningMessage = warningMessage
    }
}

// MARK: - Attestation Configuration

/// 证明服务配置
public struct AttestationConfiguration: Sendable {
 /// 服务器验证端点 URL
    public let serverEndpoint: URL?
    
 /// 证明有效期（秒）
    public let attestationValiditySeconds: TimeInterval
    
 /// 缓存有效期（秒）
    public let cacheValiditySeconds: TimeInterval
    
 /// 刷新提前量（秒）
    public let refreshLeadTimeSeconds: TimeInterval
    
 /// 是否启用 App Attest
    public let appAttestEnabled: Bool
    
 /// 是否启用 DeviceCheck
    public let deviceCheckEnabled: Bool
    
    public static let `default` = AttestationConfiguration(
        serverEndpoint: nil, // 需要配置实际服务器地址
        attestationValiditySeconds: 7 * 24 * 60 * 60, // 7 天
        cacheValiditySeconds: 24 * 60 * 60, // 24 小时
        refreshLeadTimeSeconds: 60 * 60, // 1 小时
        appAttestEnabled: true,
        deviceCheckEnabled: true
    )
    
    public init(
        serverEndpoint: URL?,
        attestationValiditySeconds: TimeInterval,
        cacheValiditySeconds: TimeInterval,
        refreshLeadTimeSeconds: TimeInterval,
        appAttestEnabled: Bool,
        deviceCheckEnabled: Bool
    ) {
        self.serverEndpoint = serverEndpoint
        self.attestationValiditySeconds = attestationValiditySeconds
        self.cacheValiditySeconds = cacheValiditySeconds
        self.refreshLeadTimeSeconds = refreshLeadTimeSeconds
        self.appAttestEnabled = appAttestEnabled
        self.deviceCheckEnabled = deviceCheckEnabled
    }
}


// MARK: - Attestation Service

/// 证明验证服务
///
/// 设计原则：
/// 1. 离线优先：attestationLevel 仅作为"历史证据"，不阻断连接
/// 2. 风险评估：影响 rate limit 阈值和 UI 警告，不影响连接决策
/// 3. 缓存策略：减少服务器请求，支持离线场景
@available(macOS 14.0, iOS 17.0, *)
public actor AttestationService {
    
 // MARK: - Singleton
    
 /// 共享实例
    public static let shared = AttestationService()
    
 // MARK: - Properties
    
 /// 配置
    private var configuration: AttestationConfiguration
    
 /// 缓存
    private var cache: [String: AttestationCacheEntry] = [:]
    
 /// 正在进行的验证任务
    private var pendingVerifications: [String: Task<AttestationResult, Error>] = [:]
    
 // MARK: - Initialization
    
    private init(configuration: AttestationConfiguration = .default) {
        self.configuration = configuration
    }
    
 /// 更新配置
    public func updateConfiguration(_ config: AttestationConfiguration) {
        self.configuration = config
    }
    
 // MARK: - Public API
    
 /// 检查设备是否支持 App Attest
    public nonisolated var isAppAttestSupported: Bool {
        if #available(iOS 14.0, macOS 11.0, *) {
            return DCAppAttestService.shared.isSupported
        }
        return false
    }
    
 /// 检查设备是否支持 DeviceCheck
    public nonisolated var isDeviceCheckSupported: Bool {
        DCDevice.current.isSupported
    }
    
 /// 获取设备支持的最高证明等级
    public nonisolated var maxSupportedLevel: P2PAttestationLevel {
        if isAppAttestSupported {
            return .appAttest
        } else if isDeviceCheckSupported {
            return .deviceCheck
        }
        return .none
    }
    
 /// 请求证明
 /// - Parameters:
 /// - deviceId: 设备 ID
 /// - level: 请求的证明等级
 /// - challenge: 服务器提供的挑战值
 /// - Returns: 证明结果
    public func requestAttestation(
        deviceId: String,
        level: P2PAttestationLevel,
        challenge: Data? = nil
    ) async throws -> AttestationResult {
 // 检查缓存
        if let cached = cache[deviceId], !cached.isExpired, cached.result.isValid {
            SkyBridgeLogger.p2p.debug("Using cached attestation for device: \(deviceId)")
            return cached.result
        }
        
 // 检查是否有正在进行的验证
        if let pending = pendingVerifications[deviceId] {
            return try await pending.value
        }
        
 // 创建新的验证任务
        let task = Task<AttestationResult, Error> {
            defer { pendingVerifications.removeValue(forKey: deviceId) }
            return try await performAttestation(deviceId: deviceId, level: level, challenge: challenge)
        }
        
        pendingVerifications[deviceId] = task
        return try await task.value
    }
    
 /// 验证远程设备的证明数据
 /// - Parameters:
 /// - attestationData: 证明数据
 /// - deviceId: 设备 ID
 /// - level: 声称的证明等级
 /// - Returns: 验证结果
    public func verifyRemoteAttestation(
        attestationData: Data,
        deviceId: String,
        level: P2PAttestationLevel
    ) async -> AttestationResult {
 // 离线场景：将证明数据作为"历史证据"
 // 不阻断连接，仅影响风险评分
        
        guard level != .none else {
            return AttestationResult(
                level: .none,
                status: .verified,
                riskScore: 0.5
            )
        }
        
 // 如果有服务器端点，尝试在线验证
        if let endpoint = configuration.serverEndpoint {
            do {
                let result = try await verifyWithServer(
                    attestationData: attestationData,
                    deviceId: deviceId,
                    level: level,
                    endpoint: endpoint
                )
                
 // 缓存结果
                cacheResult(deviceId: deviceId, result: result)
                return result
            } catch {
                SkyBridgeLogger.p2p.warning("Server verification failed, using offline mode: \(error.localizedDescription)")
            }
        }
        
 // 离线模式：接受证明数据作为历史证据
        let result = AttestationResult(
            level: level,
            status: .verified,
            attestationData: attestationData,
            verifiedAt: Date(),
            expiresAt: Date().addingTimeInterval(configuration.attestationValiditySeconds),
            riskScore: calculateOfflineRiskScore(level: level),
            errorMessage: nil
        )
        
        cacheResult(deviceId: deviceId, result: result)
        return result
    }
    
 /// 评估风险
 /// - Parameter result: 证明结果
 /// - Returns: 风险评估
    public func assessRisk(from result: AttestationResult) -> RiskAssessment {
        let score = result.riskScore
        
 // 根据风险评分确定 rate limit 倍数
 // 高风险设备使用更严格的 rate limit
        let rateLimitMultiplier: Double
        let warningLevel: RiskAssessment.WarningLevel
        let warningMessage: String?
        
        switch score {
        case 0..<0.2:
 // 低风险：已验证的 App Attest
            rateLimitMultiplier = 1.0
            warningLevel = .none
            warningMessage = nil
            
        case 0.2..<0.4:
 // 中低风险：已验证的 DeviceCheck
            rateLimitMultiplier = 1.2
            warningLevel = .info
            warningMessage = "设备已通过基础验证"
            
        case 0.4..<0.6:
 // 中等风险：离线验证或无证明
            rateLimitMultiplier = 1.5
            warningLevel = .warning
            warningMessage = "设备证明未能在线验证"
            
        case 0.6..<0.8:
 // 中高风险：验证失败或过期
            rateLimitMultiplier = 2.0
            warningLevel = .warning
            warningMessage = "设备证明已过期或验证失败"
            
        default:
 // 高风险：无法验证
            rateLimitMultiplier = 3.0
            warningLevel = .critical
            warningMessage = "无法验证设备身份，请谨慎操作"
        }
        
        return RiskAssessment(
            score: score,
            rateLimitMultiplier: rateLimitMultiplier,
            warningLevel: warningLevel,
            warningMessage: warningMessage
        )
    }
    
 /// 刷新证明（如果需要）
 /// - Parameter deviceId: 设备 ID
 /// - Returns: 是否需要刷新
    public func refreshIfNeeded(deviceId: String) async -> Bool {
        guard let cached = cache[deviceId] else { return false }
        
        if cached.result.needsRefresh {
            do {
                _ = try await requestAttestation(
                    deviceId: deviceId,
                    level: cached.result.level
                )
                return true
            } catch {
                SkyBridgeLogger.p2p.warning("Attestation refresh failed: \(error.localizedDescription)")
            }
        }
        
        return false
    }
    
 /// 清除缓存
    public func clearCache() {
        cache.removeAll()
    }
    
 /// 清除指定设备的缓存
    public func clearCache(for deviceId: String) {
        cache.removeValue(forKey: deviceId)
    }
    
 // MARK: - Private Methods
    
 /// 执行证明请求
    private func performAttestation(
        deviceId: String,
        level: P2PAttestationLevel,
        challenge: Data?
    ) async throws -> AttestationResult {
        switch level {
        case .none:
            return AttestationResult(
                level: .none,
                status: .verified,
                riskScore: 0.5
            )
            
        case .deviceCheck:
            return try await performDeviceCheck(deviceId: deviceId)
            
        case .appAttest:
            return try await performAppAttest(deviceId: deviceId, challenge: challenge)
        }
    }
    
 /// 执行 DeviceCheck
    private func performDeviceCheck(deviceId: String) async throws -> AttestationResult {
        guard isDeviceCheckSupported else {
            return AttestationResult(
                level: .deviceCheck,
                status: .unavailable,
                riskScore: 0.7,
                errorMessage: "DeviceCheck not supported on this device"
            )
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            DCDevice.current.generateToken { token, error in
                if let error = error {
                    continuation.resume(returning: AttestationResult(
                        level: .deviceCheck,
                        status: .failed,
                        riskScore: 0.7,
                        errorMessage: error.localizedDescription
                    ))
                    return
                }
                
                guard let token = token else {
                    continuation.resume(returning: AttestationResult(
                        level: .deviceCheck,
                        status: .failed,
                        riskScore: 0.7,
                        errorMessage: "Failed to generate DeviceCheck token"
                    ))
                    return
                }
                
 // DeviceCheck token 生成成功
 // 实际验证需要发送到服务器
                continuation.resume(returning: AttestationResult(
                    level: .deviceCheck,
                    status: .verified,
                    attestationData: token,
                    verifiedAt: Date(),
                    expiresAt: Date().addingTimeInterval(7 * 24 * 60 * 60), // 7 天
                    riskScore: 0.3
                ))
            }
        }
    }
    
 /// 执行 App Attest
    private func performAppAttest(deviceId: String, challenge: Data?) async throws -> AttestationResult {
        guard isAppAttestSupported else {
            return AttestationResult(
                level: .appAttest,
                status: .unavailable,
                riskScore: 0.6,
                errorMessage: "App Attest not supported on this device"
            )
        }
        
        let service = DCAppAttestService.shared
        
 // 生成或获取 key ID
        let keyId: String
        do {
            keyId = try await service.generateKey()
        } catch {
            return AttestationResult(
                level: .appAttest,
                status: .failed,
                riskScore: 0.6,
                errorMessage: "Failed to generate App Attest key: \(error.localizedDescription)"
            )
        }
        
 // 生成挑战值（如果未提供）
        let attestChallenge = challenge ?? generateChallenge()
        let clientDataHash = SHA256.hash(data: attestChallenge)
        
 // 请求证明
        do {
            let attestation = try await service.attestKey(keyId, clientDataHash: Data(clientDataHash))
            
            return AttestationResult(
                level: .appAttest,
                status: .verified,
                attestationData: attestation,
                verifiedAt: Date(),
                expiresAt: Date().addingTimeInterval(configuration.attestationValiditySeconds),
                riskScore: 0.1
            )
        } catch {
            return AttestationResult(
                level: .appAttest,
                status: .failed,
                riskScore: 0.6,
                errorMessage: "App Attest failed: \(error.localizedDescription)"
            )
        }
    }
    
 /// 服务器验证
    private func verifyWithServer(
        attestationData: Data,
        deviceId: String,
        level: P2PAttestationLevel,
        endpoint: URL
    ) async throws -> AttestationResult {
 // 构建请求
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "deviceId": deviceId,
            "level": level.rawValue,
            "attestationData": attestationData.base64EncodedString(),
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
 // 发送请求
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AttestationError.invalidResponse
        }
        
        switch httpResponse.statusCode {
        case 200:
 // 解析响应
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            
            struct ServerResponse: Codable {
                let verified: Bool
                let riskScore: Double
                let expiresAt: Date?
                let message: String?
            }
            
            let serverResponse = try decoder.decode(ServerResponse.self, from: data)
            
            return AttestationResult(
                level: level,
                status: serverResponse.verified ? .verified : .failed,
                attestationData: attestationData,
                verifiedAt: Date(),
                expiresAt: serverResponse.expiresAt,
                riskScore: serverResponse.riskScore,
                errorMessage: serverResponse.message
            )
            
        case 429:
            throw AttestationError.rateLimited
            
        default:
            throw AttestationError.serverVerificationFailed("HTTP \(httpResponse.statusCode)")
        }
    }
    
 /// 缓存结果
    private func cacheResult(deviceId: String, result: AttestationResult) {
        cache[deviceId] = AttestationCacheEntry(
            deviceId: deviceId,
            result: result,
            cachedAt: Date()
        )
    }
    
 /// 计算离线风险评分
    private func calculateOfflineRiskScore(level: P2PAttestationLevel) -> Double {
        switch level {
        case .none:
            return 0.5
        case .deviceCheck:
            return 0.4 // 离线 DeviceCheck 风险略高
        case .appAttest:
            return 0.3 // 离线 App Attest 风险略高
        }
    }
    
 /// 生成挑战值
    private func generateChallenge() -> Data {
        var bytes = [UInt8](repeating: 0, count: P2PConstants.challengeSize)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }
}

// MARK: - TrustRecord Extension

@available(macOS 14.0, iOS 17.0, *)
extension TrustRecord {
 /// 获取证明验证结果
    public func getAttestationResult() -> AttestationResult {
        AttestationResult(
            level: attestationLevel,
            status: attestationData != nil ? .verified : .unverified,
            attestationData: attestationData,
            verifiedAt: createdAt,
            expiresAt: nil,
            riskScore: calculateRiskScore()
        )
    }
    
 /// 计算风险评分
    private func calculateRiskScore() -> Double {
        switch attestationLevel {
        case .appAttest:
            return attestationData != nil ? 0.1 : 0.5
        case .deviceCheck:
            return attestationData != nil ? 0.3 : 0.5
        case .none:
            return 0.5
        }
    }
}
