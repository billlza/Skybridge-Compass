//
// DeviceCapabilities.swift
// SkyBridgeCore
//
// 设备能力和协议版本模型
// 跨平台统一的能力协商机制
//
// Requirements: 9.2, 9.3, 9.4, 9.6
//

import Foundation

// MARK: - Device Capabilities

/// 设备能力枚举 - 跨平台统一定义
public struct SBDeviceCapabilities: OptionSet, Codable, Sendable, Equatable {
    public let rawValue: UInt32
    
    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }
    
 /// 远程桌面控制
    public static let remoteDesktop = SBDeviceCapabilities(rawValue: 1 << 0)
 /// 文件传输
    public static let fileTransfer = SBDeviceCapabilities(rawValue: 1 << 1)
 /// 屏幕共享（只读）
    public static let screenSharing = SBDeviceCapabilities(rawValue: 1 << 2)
 /// 输入注入
    public static let inputInjection = SBDeviceCapabilities(rawValue: 1 << 3)
 /// 系统控制
    public static let systemControl = SBDeviceCapabilities(rawValue: 1 << 4)
 /// PQC 加密支持
    public static let pqcEncryption = SBDeviceCapabilities(rawValue: 1 << 5)
 /// 混合加密支持
    public static let hybridEncryption = SBDeviceCapabilities(rawValue: 1 << 6)
 /// 音频传输
    public static let audioTransfer = SBDeviceCapabilities(rawValue: 1 << 7)
 /// 剪贴板同步
    public static let clipboardSync = SBDeviceCapabilities(rawValue: 1 << 8)
    
 /// 所有能力
    public static let all: SBDeviceCapabilities = [
        .remoteDesktop, .fileTransfer, .screenSharing,
        .inputInjection, .systemControl, .pqcEncryption,
        .hybridEncryption, .audioTransfer, .clipboardSync
    ]
    
 /// 基础能力（所有平台都应支持）
    public static let basic: SBDeviceCapabilities = [
        .fileTransfer, .screenSharing
    ]
    
 /// 转换为字符串数组（用于 JSON 序列化）
    public var asStringArray: [String] {
        var result: [String] = []
        if contains(.remoteDesktop) { result.append("remote_desktop") }
        if contains(.fileTransfer) { result.append("file_transfer") }
        if contains(.screenSharing) { result.append("screen_sharing") }
        if contains(.inputInjection) { result.append("input_injection") }
        if contains(.systemControl) { result.append("system_control") }
        if contains(.pqcEncryption) { result.append("pqc_encryption") }
        if contains(.hybridEncryption) { result.append("hybrid_encryption") }
        if contains(.audioTransfer) { result.append("audio_transfer") }
        if contains(.clipboardSync) { result.append("clipboard_sync") }
        return result
    }
    
 /// 从字符串数组创建
    public static func from(strings: [String]) -> SBDeviceCapabilities {
        var caps = SBDeviceCapabilities()
        for str in strings {
            switch str {
            case "remote_desktop": caps.insert(.remoteDesktop)
            case "file_transfer": caps.insert(.fileTransfer)
            case "screen_sharing": caps.insert(.screenSharing)
            case "input_injection": caps.insert(.inputInjection)
            case "system_control": caps.insert(.systemControl)
            case "pqc_encryption": caps.insert(.pqcEncryption)
            case "hybrid_encryption": caps.insert(.hybridEncryption)
            case "audio_transfer": caps.insert(.audioTransfer)
            case "clipboard_sync": caps.insert(.clipboardSync)
            default: break
            }
        }
        return caps
    }
}


// MARK: - Protocol Version

/// 协议版本
public struct SBProtocolVersion: Codable, Sendable, Equatable, Comparable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    
    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }
    
 /// 当前协议版本
    public static let current = SBProtocolVersion(major: 1, minor: 0, patch: 0)
    
 /// 最低兼容版本
    public static let minimumCompatible = SBProtocolVersion(major: 1, minor: 0, patch: 0)
    
 /// 版本字符串
    public var versionString: String {
        "\(major).\(minor).\(patch)"
    }
    
 /// 检查是否兼容
    public func isCompatible(with other: SBProtocolVersion) -> Bool {
 // 主版本号必须相同
        return major == other.major
    }
    
    public static func < (lhs: SBProtocolVersion, rhs: SBProtocolVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

// MARK: - Connection State

/// 连接状态枚举
public enum SBConnectionState: String, Codable, Sendable {
    case disconnected = "disconnected"
    case connecting = "connecting"
    case connected = "connected"
    case authenticating = "authenticating"
    case authenticated = "authenticated"
    case failed = "failed"
    
 /// 是否处于活跃状态
    public var isActive: Bool {
        switch self {
        case .connected, .authenticating, .authenticated:
            return true
        default:
            return false
        }
    }
}

// MARK: - Platform Type

/// 平台类型枚举
public enum SBPlatformType: String, Codable, Sendable {
    case macOS = "macos"
    case iOS = "ios"
    case android = "android"
    case windows = "windows"
    case linux = "linux"
    case web = "web"
    case unknown = "unknown"
    
 /// 当前平台
    public static var current: SBPlatformType {
        #if os(macOS)
        return .macOS
        #elseif os(iOS)
        return .iOS
        #else
        return .unknown
        #endif
    }
}

// MARK: - Encryption Mode

/// 加密模式枚举
public enum SBEncryptionMode: String, Codable, Sendable {
    case classic = "classic"      // 经典加密（P-256, AES-GCM）
    case pqc = "pqc"              // 纯 PQC 加密
    case hybrid = "hybrid"        // 混合加密（经典 + PQC）
    
 /// 安全级别（数值越高越安全）
    public var securityLevel: Int {
        switch self {
        case .classic: return 1
        case .pqc: return 2
        case .hybrid: return 3
        }
    }
}

// MARK: - PQC Algorithm Suite

/// PQC 算法套件枚举
public enum SBPQCAlgorithmSuite: String, Codable, Sendable {
    case classicP256 = "classic-p256"
    case pqcMLKEMMLDSA = "pqc-mlkem-mldsa"
    case hybridXWingMLKEM768X25519 = "hybrid-xwing-mlkem768-x25519"
    
 /// KEM 算法
    public var kemAlgorithm: String? {
        switch self {
        case .classicP256: return nil
        case .pqcMLKEMMLDSA: return "ML-KEM-768"
        case .hybridXWingMLKEM768X25519: return "X-Wing"
        }
    }
    
 /// 签名算法
    public var signatureAlgorithm: String {
        switch self {
        case .classicP256: return "P-256"
        case .pqcMLKEMMLDSA: return "ML-DSA-65"
        case .hybridXWingMLKEM768X25519: return "P-256+ML-DSA-65"
        }
    }
}


// MARK: - Capability Negotiation

/// 能力协商请求
public struct SBCapabilityNegotiationRequest: Codable, Sendable, Equatable {
    public let protocolVersion: SBProtocolVersion
    public let deviceId: String
    public let platform: String
    public let capabilities: [String]
    public let encryptionModes: [String]
    public let pqcAlgorithms: [String]?
 /// PQC 签名是否支持 (Requirements: 6.2)
    public let pqcSignatureSupported: Bool
    
    public init(
        protocolVersion: SBProtocolVersion = .current,
        deviceId: String,
        platform: SBPlatformType = .current,
        capabilities: SBDeviceCapabilities,
        encryptionModes: [SBEncryptionMode],
        pqcAlgorithms: [String]? = nil,
        pqcSignatureSupported: Bool = false
    ) {
        self.protocolVersion = protocolVersion
        self.deviceId = deviceId
        self.platform = platform.rawValue
        self.capabilities = capabilities.asStringArray
        self.encryptionModes = encryptionModes.map { $0.rawValue }
        self.pqcAlgorithms = pqcAlgorithms
        self.pqcSignatureSupported = pqcSignatureSupported
    }
}

/// 能力协商响应
public struct SBCapabilityNegotiationResponse: Codable, Sendable, Equatable {
    public let protocolVersion: SBProtocolVersion
    public let negotiatedCapabilities: [String]
    public let negotiatedEncryptionMode: String
    public let negotiatedPQCAlgorithms: [String]?
 /// PQC 签名是否激活 (Requirements: 6.3)
    public let pqcSignatureActive: Bool
    public let success: Bool
    public let errorMessage: String?
    
    public init(
        protocolVersion: SBProtocolVersion = .current,
        negotiatedCapabilities: [String],
        negotiatedEncryptionMode: SBEncryptionMode,
        negotiatedPQCAlgorithms: [String]? = nil,
        pqcSignatureActive: Bool = false,
        success: Bool = true,
        errorMessage: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.negotiatedCapabilities = negotiatedCapabilities
        self.negotiatedEncryptionMode = negotiatedEncryptionMode.rawValue
        self.negotiatedPQCAlgorithms = negotiatedPQCAlgorithms
        self.pqcSignatureActive = pqcSignatureActive
        self.success = success
        self.errorMessage = errorMessage
    }
}

// MARK: - PQC Capability Integration

/// PQC 能力集成 - 连接 PQCProtocolAdapter 与能力协商
@available(macOS 14.0, *)
public enum SBPQCCapabilityIntegration {
    
 /// 从 PQCProtocolAdapter 生成 PQC 算法列表
    public static func getPQCAlgorithms(from adapter: PQCProtocolAdapter) async -> [String] {
        let declaration = await adapter.generateCapabilityDeclaration()
        var algorithms: [String] = []
        
 // 添加支持的 KEM 变体
        algorithms.append(contentsOf: declaration.supportedKEMVariants)
        
 // 添加支持的签名变体
        algorithms.append(contentsOf: declaration.supportedSignatureVariants)
        
 // 如果支持 hybrid，添加 X-Wing
        if declaration.supportedSuites.contains("hybrid") {
            algorithms.append("X-Wing")
        }
        
        return algorithms
    }
    
 /// 从 PQCProtocolAdapter 生成加密模式列表
    public static func getEncryptionModes(from adapter: PQCProtocolAdapter) async -> [SBEncryptionMode] {
        let suites = await adapter.getSupportedSuites()
        return suites.map { suite -> SBEncryptionMode in
            switch suite {
            case .classic: return .classic
            case .pqc: return .pqc
            case .hybrid: return .hybrid
            }
        }
    }
    
 /// 生成包含 PQC 信息的能力协商请求
    public static func createNegotiationRequest(
        deviceId: String,
        capabilities: SBDeviceCapabilities,
        pqcAdapter: PQCProtocolAdapter
    ) async -> SBCapabilityNegotiationRequest {
        let encryptionModes = await getEncryptionModes(from: pqcAdapter)
        let pqcAlgorithms = await getPQCAlgorithms(from: pqcAdapter)
        
 // 检查是否支持 PQC 签名 (Requirements: 6.2)
        let pqcSignatureSupported = pqcAlgorithms.contains { algo in
            algo.contains("ML-DSA") || algo.contains("MLDSA")
        }
        
        return SBCapabilityNegotiationRequest(
            deviceId: deviceId,
            capabilities: capabilities,
            encryptionModes: encryptionModes,
            pqcAlgorithms: pqcAlgorithms.isEmpty ? nil : pqcAlgorithms,
            pqcSignatureSupported: pqcSignatureSupported
        )
    }
    
 /// 根据协商结果配置 PQCProtocolAdapter
    public static func applyNegotiationResult(
        response: SBCapabilityNegotiationResponse,
        to adapter: PQCProtocolAdapter
    ) async throws {
        guard response.success else {
            throw PQCProtocolError.noCommonSuite
        }
        
 // 根据协商的加密模式设置套件
        if let mode = SBEncryptionMode(rawValue: response.negotiatedEncryptionMode) {
            let suite: CrossPlatformPQCSuite
            switch mode {
            case .classic: suite = .classic
            case .pqc: suite = .pqc
            case .hybrid: suite = .hybrid
            }
            try await adapter.setSuite(suite)
        }
    }
}

// MARK: - Capability Negotiator

/// 能力协商器
public enum SBCapabilityNegotiator {
    
 /// 协商能力集合（返回交集）
    public static func negotiate(
        local: SBDeviceCapabilities,
        remote: SBDeviceCapabilities
    ) -> SBDeviceCapabilities {
        return local.intersection(remote)
    }
    
 /// 协商能力字符串数组（返回交集）
    public static func negotiate(
        local: [String],
        remote: [String]
    ) -> [String] {
        let localSet = Set(local)
        let remoteSet = Set(remote)
        return Array(localSet.intersection(remoteSet)).sorted()
    }
    
 /// 协商加密模式（选择双方都支持的最高安全级别）
    public static func negotiateEncryptionMode(
        local: [SBEncryptionMode],
        remote: [SBEncryptionMode]
    ) -> SBEncryptionMode? {
        let localSet = Set(local)
        let remoteSet = Set(remote)
        let common = localSet.intersection(remoteSet)
        
 // 选择安全级别最高的
        return common.max { $0.securityLevel < $1.securityLevel }
    }
    
 /// 协商 PQC 算法（选择双方都支持的算法）
    public static func negotiatePQCAlgorithms(
        local: [String]?,
        remote: [String]?
    ) -> [String]? {
        guard let local = local, let remote = remote else {
            return nil
        }
        let localSet = Set(local)
        let remoteSet = Set(remote)
        let common = localSet.intersection(remoteSet)
        return common.isEmpty ? nil : Array(common).sorted()
    }
    
 /// 执行完整的能力协商
    public static func negotiate(
        request: SBCapabilityNegotiationRequest,
        localCapabilities: SBDeviceCapabilities,
        localEncryptionModes: [SBEncryptionMode],
        localPQCAlgorithms: [String]?,
        localPQCSignatureSupported: Bool = false
    ) -> SBCapabilityNegotiationResponse {
 // 检查协议版本兼容性
        guard request.protocolVersion.isCompatible(with: .current) else {
            return SBCapabilityNegotiationResponse(
                negotiatedCapabilities: [],
                negotiatedEncryptionMode: .classic,
                success: false,
                errorMessage: "协议版本不兼容: \(request.protocolVersion.versionString)"
            )
        }
        
 // 协商能力
        let negotiatedCaps = negotiate(
            local: localCapabilities.asStringArray,
            remote: request.capabilities
        )
        
 // 协商加密模式
        let remoteEncModes = request.encryptionModes.compactMap { SBEncryptionMode(rawValue: $0) }
        let negotiatedEncMode = negotiateEncryptionMode(
            local: localEncryptionModes,
            remote: remoteEncModes
        ) ?? .classic
        
 // 协商 PQC 算法
        let negotiatedPQC = negotiatePQCAlgorithms(
            local: localPQCAlgorithms,
            remote: request.pqcAlgorithms
        )
        
 // 确定 PQC 签名是否激活 (Requirements: 6.3)
 // 当双方都支持 PQC 签名且协商的加密模式是 PQC 或 Hybrid 时激活
        let pqcSignatureActive = localPQCSignatureSupported &&
                                  request.pqcSignatureSupported &&
                                  (negotiatedEncMode == .pqc || negotiatedEncMode == .hybrid)
        
        return SBCapabilityNegotiationResponse(
            negotiatedCapabilities: negotiatedCaps,
            negotiatedEncryptionMode: negotiatedEncMode,
            negotiatedPQCAlgorithms: negotiatedPQC,
            pqcSignatureActive: pqcSignatureActive
        )
    }
}
