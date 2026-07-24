//
// LegacyTrustPrecondition.swift
// SkyBridgeCore
//
// 13.1: Legacy Trust Precondition
// Requirements: 11.1, 11.2
//
// Legacy P-256 首次接触的安全前置条件：
// - 只有在认证通道（QR/PAKE/local）或已有 TrustRecord 时才允许 legacy P-256
// - 纯网络陌生人连接不允许 legacy P-256 作为首次身份锚点
//

import Foundation

// MARK: - LegacyTrustPreconditionType

/// Legacy 信任前置条件类型
///
/// **Requirements: 11.1, 11.2**
public enum LegacyTrustPreconditionType: String, Codable, Sendable, Equatable {
 /// 认证通道（QR/PAKE/local pairing）
    case authenticatedChannel
    
 /// 已有 TrustRecord（之前配对过）
    case existingTrustRecord
    
 /// 本地连接（同一网络/蓝牙）
    case localConnection
}

// MARK: - LegacyTrustPrecondition

/// Legacy 信任前置条件
///
/// 用于判断是否允许 legacy P-256 签名验证。
/// 只有满足安全前置条件时才允许 legacy fallback。
///
/// **Requirements: 11.1, 11.2**
public struct LegacyTrustPrecondition: Sendable, Equatable {
    
 /// 前置条件类型
    public let type: LegacyTrustPreconditionType
    
 /// 是否满足
    public let isSatisfied: Bool
    
 /// 附加上下文（用于日志和事件）
    public let context: [String: String]
    
    public init(
        type: LegacyTrustPreconditionType,
        isSatisfied: Bool,
        context: [String: String] = [:]
    ) {
        self.type = type
        self.isSatisfied = isSatisfied
        self.context = context
    }
    
 // MARK: - Factory Methods
    
 /// 创建认证通道前置条件
 /// - Parameters:
 /// - channelType: 通道类型（qr/pake/local）
 /// - verified: 是否已验证
 /// - Returns: 前置条件
    public static func authenticatedChannel(
        channelType: String,
        verified: Bool
    ) -> LegacyTrustPrecondition {
        LegacyTrustPrecondition(
            type: .authenticatedChannel,
            isSatisfied: verified,
            context: ["channelType": channelType]
        )
    }
    
 /// 创建已有 TrustRecord 前置条件
 /// - Parameters:
 /// - deviceId: 设备 ID
 /// - hasLegacyKey: 是否有 legacy P-256 公钥
 /// - Returns: 前置条件
    public static func existingTrustRecord(
        deviceId: String,
        hasLegacyKey: Bool
    ) -> LegacyTrustPrecondition {
        LegacyTrustPrecondition(
            type: .existingTrustRecord,
            isSatisfied: hasLegacyKey,
            context: ["deviceId": deviceId]
        )
    }
    
 /// 创建本地连接前置条件
 /// - Parameters:
 /// - connectionType: 连接类型（bluetooth/wifi-direct/local-network）
 /// - isLocal: 是否为本地连接
 /// - Returns: 前置条件
    public static func localConnection(
        connectionType: String,
        isLocal: Bool
    ) -> LegacyTrustPrecondition {
        LegacyTrustPrecondition(
            type: .localConnection,
            isSatisfied: isLocal,
            context: ["connectionType": connectionType]
        )
    }
    
 /// 不满足任何前置条件（纯网络陌生人）
    public static let unsatisfied = LegacyTrustPrecondition(
        type: .authenticatedChannel,
        isSatisfied: false,
        context: ["reason": "pure_network_stranger"]
    )
}

// MARK: - LegacyFallbackError

/// Legacy Fallback 错误
///
/// **Requirements: 11.1, 11.2**
public enum LegacyFallbackError: Error, LocalizedError, Sendable {
 /// Legacy fallback 不允许（纯网络陌生人）
    case legacyFallbackNotAllowed(reason: String)
    
 /// 缺少 legacy P-256 公钥
    case missingLegacyPublicKey(deviceId: String)
    
 /// Legacy 签名验证失败
    case legacyVerificationFailed(reason: String)
    
 /// 前置条件不满足
    case preconditionNotSatisfied(type: LegacyTrustPreconditionType)
    
    public var errorDescription: String? {
        switch self {
        case .legacyFallbackNotAllowed(let reason):
            return "Legacy P-256 fallback not allowed: \(reason)"
        case .missingLegacyPublicKey(let deviceId):
            return "Missing legacy P-256 public key for device: \(deviceId)"
        case .legacyVerificationFailed(let reason):
            return "Legacy signature verification failed: \(reason)"
        case .preconditionNotSatisfied(let type):
            return "Legacy precondition not satisfied: \(type.rawValue)"
        }
    }
}

// MARK: - LegacyTrustPreconditionChecker

/// Legacy 信任前置条件检查器
///
/// 检查是否满足 legacy P-256 fallback 的安全前置条件。
///
/// **Requirements: 11.1, 11.2**
@available(macOS 14.0, iOS 17.0, *)
public struct LegacyTrustPreconditionChecker: Sendable {
    
 /// 检查是否允许 legacy fallback
 /// - Parameters:
 /// - deviceId: 对端设备 ID
 /// - trustRecord: 已有的 TrustRecord（如果存在）
 /// - pairingContext: 配对上下文（如果在配对流程中）
 /// - Returns: 前置条件检查结果
    public static func check(
        deviceId: String,
        trustRecord: TrustRecord?,
        pairingContext: PairingContext?
    ) -> LegacyTrustPrecondition {
 // 1. 检查是否有已有 TrustRecord 且包含 legacy P-256 公钥
        if let record = trustRecord, record.allowsLegacyFallback {
            return .existingTrustRecord(
                deviceId: deviceId,
                hasLegacyKey: true
            )
        }
        
 // 2. 检查是否在认证配对流程中
        if let context = pairingContext {
            switch context.channelType {
            case .qrCode, .pake, .localPairing:
                return .authenticatedChannel(
                    channelType: context.channelType.rawValue,
                    verified: context.isVerified
                )
            case .networkDiscovery:
 // 网络发现不算认证通道
                break
            }
        }
        
 // 3. 不满足任何前置条件
        return .unsatisfied
    }
    
 /// 验证前置条件并抛出错误（如果不满足）
 /// - Parameter precondition: 前置条件
 /// - Throws: LegacyFallbackError 如果不满足
    public static func requireSatisfied(_ precondition: LegacyTrustPrecondition) throws {
        guard precondition.isSatisfied else {
            throw LegacyFallbackError.preconditionNotSatisfied(type: precondition.type)
        }
    }
}

// MARK: - PairingContext

/// 配对上下文
///
/// 描述当前配对流程的上下文信息。
public struct PairingContext: Sendable {
    
 /// 配对通道类型
    public enum ChannelType: String, Sendable {
 /// QR 码配对
        case qrCode = "qr_code"
        
 /// PAKE 配对（PIN 码）
        case pake = "pake"
        
 /// 本地配对（蓝牙/WiFi Direct）
        case localPairing = "local_pairing"
        
 /// 网络发现（不算认证通道）
        case networkDiscovery = "network_discovery"
    }
    
 /// 通道类型
    public let channelType: ChannelType
    
 /// 是否已验证（OOB 验证完成）
    public let isVerified: Bool
    
 /// 配对会话 ID
    public let sessionId: String
    
 /// 创建时间
    public let createdAt: Date
    
    public init(
        channelType: ChannelType,
        isVerified: Bool,
        sessionId: String = UUID().uuidString,
        createdAt: Date = Date()
    ) {
        self.channelType = channelType
        self.isVerified = isVerified
        self.sessionId = sessionId
        self.createdAt = createdAt
    }
}
