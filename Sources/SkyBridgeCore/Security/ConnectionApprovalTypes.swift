//
// ConnectionApprovalTypes.swift
// SkyBridgeCore
//
// 多因素连接审批 - 类型定义
// 支持 macOS 14.0+
//

import Foundation

// MARK: - 审批请求

/// 连接审批请求
public struct ConnectionApprovalRequest: Identifiable, Codable, Sendable {
    public let id: UUID
    public let requestingDeviceID: String
    public let requestingDeviceName: String
    public let requestingDeviceType: DeviceType
    public let requestTime: Date
    public let expiresAt: Date
    public let verificationCode: String
    public let challengeData: Data
    public var status: ApprovalStatus

    /// 是否已过期
    public var isExpired: Bool {
        Date() > expiresAt
    }

    /// 剩余有效时间（秒）
    public var remainingTime: TimeInterval {
        max(0, expiresAt.timeIntervalSince(Date()))
    }

    public init(
        requestingDeviceID: String,
        requestingDeviceName: String,
        requestingDeviceType: DeviceType,
        verificationCode: String,
        challengeData: Data,
        ttl: TimeInterval = 120 // 2分钟有效期
    ) {
        self.id = UUID()
        self.requestingDeviceID = requestingDeviceID
        self.requestingDeviceName = requestingDeviceName
        self.requestingDeviceType = requestingDeviceType
        self.requestTime = Date()
        self.expiresAt = Date().addingTimeInterval(ttl)
        self.verificationCode = verificationCode
        self.challengeData = challengeData
        self.status = .pending
    }
}

// MARK: - 审批状态

/// 审批状态
public enum ApprovalStatus: String, Codable, Sendable {
    case pending = "pending"
    case approved = "approved"
    case rejected = "rejected"
    case expired = "expired"
    case cancelled = "cancelled"

    public var displayName: String {
        switch self {
        case .pending: return "等待审批"
        case .approved: return "已批准"
        case .rejected: return "已拒绝"
        case .expired: return "已过期"
        case .cancelled: return "已取消"
        }
    }
}

// MARK: - 设备类型

/// 设备类型
public enum DeviceType: String, Codable, Sendable {
    case mac = "mac"
    case iPhone = "iphone"
    case iPad = "ipad"
    case unknown = "unknown"

    public var displayName: String {
        switch self {
        case .mac: return "Mac"
        case .iPhone: return "iPhone"
        case .iPad: return "iPad"
        case .unknown: return "未知设备"
        }
    }

    public var icon: String {
        switch self {
        case .mac: return "desktopcomputer"
        case .iPhone: return "iphone"
        case .iPad: return "ipad"
        case .unknown: return "questionmark.circle"
        }
    }
}

// MARK: - 验证因素

/// 验证因素类型
public enum VerificationFactor: String, Codable, Sendable, CaseIterable {
    case verificationCode = "verification_code"  // 6位数字码
    case biometric = "biometric"                 // 生物识别
    case pushNotification = "push_notification"  // 推送通知确认
    case proximity = "proximity"                 // 近场感应

    public var displayName: String {
        switch self {
        case .verificationCode: return "验证码"
        case .biometric: return "生物识别"
        case .pushNotification: return "推送通知"
        case .proximity: return "近场感应"
        }
    }

    public var icon: String {
        switch self {
        case .verificationCode: return "number.circle"
        case .biometric: return "touchid"
        case .pushNotification: return "bell.badge"
        case .proximity: return "antenna.radiowaves.left.and.right"
        }
    }
}

// MARK: - 审批策略

/// 连接审批策略
public struct ApprovalPolicy: Codable, Sendable {
    /// 是否启用审批
    public var requireApproval: Bool

    /// 必需的验证因素数量
    public var requiredFactorCount: Int

    /// 启用的验证因素
    public var enabledFactors: Set<VerificationFactor>

    /// 自动批准已知设备
    public var autoApproveTrustedDevices: Bool

    /// 请求超时时间（秒）
    public var requestTimeout: TimeInterval

    /// 最大待处理请求数
    public var maxPendingRequests: Int

    /// 默认策略
    public static let `default` = ApprovalPolicy(
        requireApproval: true,
        requiredFactorCount: 1,
        enabledFactors: [.verificationCode, .biometric],
        autoApproveTrustedDevices: true,
        requestTimeout: 120,
        maxPendingRequests: 5
    )

    /// 严格策略
    public static let strict = ApprovalPolicy(
        requireApproval: true,
        requiredFactorCount: 2,
        enabledFactors: Set(VerificationFactor.allCases),
        autoApproveTrustedDevices: false,
        requestTimeout: 60,
        maxPendingRequests: 3
    )

    public init(
        requireApproval: Bool = true,
        requiredFactorCount: Int = 1,
        enabledFactors: Set<VerificationFactor> = [.verificationCode],
        autoApproveTrustedDevices: Bool = true,
        requestTimeout: TimeInterval = 120,
        maxPendingRequests: Int = 5
    ) {
        self.requireApproval = requireApproval
        self.requiredFactorCount = requiredFactorCount
        self.enabledFactors = enabledFactors
        self.autoApproveTrustedDevices = autoApproveTrustedDevices
        self.requestTimeout = requestTimeout
        self.maxPendingRequests = maxPendingRequests
    }
}

// MARK: - 审批响应

/// 审批响应
public struct ApprovalResponse: Codable, Sendable {
    public let requestID: UUID
    public let approved: Bool
    public let respondedAt: Date
    public let respondingDeviceID: String
    public let verificationFactorsUsed: [VerificationFactor]
    public let signature: Data?

    public init(
        requestID: UUID,
        approved: Bool,
        respondingDeviceID: String,
        verificationFactorsUsed: [VerificationFactor],
        signature: Data? = nil
    ) {
        self.requestID = requestID
        self.approved = approved
        self.respondedAt = Date()
        self.respondingDeviceID = respondingDeviceID
        self.verificationFactorsUsed = verificationFactorsUsed
        self.signature = signature
    }
}

// MARK: - 信任设备

/// 审批信任设备
public struct ApprovalTrustedDevice: Identifiable, Codable, Sendable {
    public let id: UUID
    public let deviceID: String
    public let deviceName: String
    public let deviceType: DeviceType
    public let trustedAt: Date
    public let lastConnectedAt: Date?
    public let trustLevel: ApprovalTrustLevel

    public init(
        deviceID: String,
        deviceName: String,
        deviceType: DeviceType,
        trustLevel: ApprovalTrustLevel = .standard
    ) {
        self.id = UUID()
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.deviceType = deviceType
        self.trustedAt = Date()
        self.lastConnectedAt = nil
        self.trustLevel = trustLevel
    }
}

/// 审批信任级别
public enum ApprovalTrustLevel: String, Codable, Sendable {
    case temporary = "temporary"  // 临时信任（单次会话）
    case standard = "standard"    // 标准信任
    case elevated = "elevated"    // 高级信任（无需再次审批）

    public var displayName: String {
        switch self {
        case .temporary: return "临时信任"
        case .standard: return "标准信任"
        case .elevated: return "高级信任"
        }
    }
}

// MARK: - 审批错误

/// 连接审批错误
public enum ConnectionApprovalError: Error, Sendable, LocalizedError {
    case requestExpired
    case requestNotFound
    case alreadyProcessed
    case verificationFailed
    case biometricFailed
    case tooManyPendingRequests
    case deviceNotTrusted
    case invalidSignature

    public var errorDescription: String? {
        switch self {
        case .requestExpired:
            return "审批请求已过期"
        case .requestNotFound:
            return "审批请求不存在"
        case .alreadyProcessed:
            return "审批请求已处理"
        case .verificationFailed:
            return "验证失败"
        case .biometricFailed:
            return "生物识别验证失败"
        case .tooManyPendingRequests:
            return "待处理请求过多"
        case .deviceNotTrusted:
            return "设备未受信任"
        case .invalidSignature:
            return "签名无效"
        }
    }
}
