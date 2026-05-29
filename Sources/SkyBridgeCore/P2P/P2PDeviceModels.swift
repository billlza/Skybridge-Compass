import Foundation

// MARK: - 设备类型枚举
public enum P2PDeviceType: String, Codable, CaseIterable, Sendable {
    case macOS = "macOS"
    case iOS = "iOS"
    case iPadOS = "iPadOS"
    case android = "Android"
    case windows = "Windows"
    case linux = "Linux"
    
 /// 设备类型显示名称
    public var displayName: String {
        switch self {
        case .macOS: return "Mac"
        case .iOS: return "iPhone"
        case .iPadOS: return "iPad"
        case .android: return "Android"
        case .windows: return "Windows"
        case .linux: return "Linux"
        }
    }
    
 /// 设备图标名称
    public var iconName: String {
        switch self {
        case .macOS: return "desktopcomputer"
        case .iOS: return "iphone"
        case .iPadOS: return "ipad"
        case .android: return "smartphone"
        case .windows: return "pc"
        case .linux: return "server.rack"
        }
    }
}

// MARK: - 设备信息
public struct P2PDeviceInfo: Codable, Identifiable, Sendable {
    private static let protocolIdentityMirrorDefaultsKey = "SkyBridge.P2P.DeviceIdentity.DeviceID"
    private static let legacyDeviceDefaultsKey = "SkyBridge.DeviceId"

    public let id: String
    public let name: String
    public let type: P2PDeviceType
    public let address: String
    public let port: UInt16
    public let osVersion: String
    public let capabilities: [String]
    public let publicKeyFingerprint: String
    
 /// 获取当前设备信息
    public static func current() -> P2PDeviceInfo {
        return P2PDeviceInfo(
            id: getOrCreateDeviceId(),
            name: getDeviceName(),
            type: getCurrentDeviceType(),
            address: "0.0.0.0", // 将在网络发现时更新
            port: 8080,
            osVersion: getOSVersion(),
            capabilities: getSupportedCapabilities(),
            publicKeyFingerprint: "" // 将在安全管理器初始化时设置
        )
    }
    
 /// 获取或创建设备ID
    private static func getOrCreateDeviceId() -> String {
        if let protocolIdentity = UserDefaults.standard.string(forKey: protocolIdentityMirrorDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !protocolIdentity.isEmpty {
            mirrorDeviceIdToLegacyDefaultsIfNeeded(protocolIdentity)
            return protocolIdentity
        }

        if let legacyIdentity = UserDefaults.standard.string(forKey: legacyDeviceDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !legacyIdentity.isEmpty {
            UserDefaults.standard.set(legacyIdentity, forKey: protocolIdentityMirrorDefaultsKey)
            return legacyIdentity
        }

        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: protocolIdentityMirrorDefaultsKey)
        mirrorDeviceIdToLegacyDefaultsIfNeeded(newId)
        return newId
    }

    private static func mirrorDeviceIdToLegacyDefaultsIfNeeded(_ raw: String) {
        let deviceId = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !deviceId.isEmpty else { return }
        if UserDefaults.standard.string(forKey: legacyDeviceDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) != deviceId {
            UserDefaults.standard.set(deviceId, forKey: legacyDeviceDefaultsKey)
        }
    }
    
    private static func getDeviceName() -> String {
        let snapshot = LocalDevicePresentation.current()
        return snapshot.deviceName ?? snapshot.modelName ?? "Unknown Device"
    }
    
    private static func getCurrentDeviceType() -> P2PDeviceType {
        #if os(macOS)
        return .macOS
        #elseif os(iOS)
        return LocalDevicePresentation.current().platformName == "iPadOS" ? .iPadOS : .iOS
        #else
        return .macOS
        #endif
    }
    
    private static func getOSVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
    
    private static func getSupportedCapabilities() -> [String] {
        var capabilities = [
            "remote_desktop",
            "file_transfer",
            "screen_sharing"
        ]
        
        #if os(macOS)
        capabilities.append("system_control")
        capabilities.append("hardware_acceleration")
        capabilities.append("metal_rendering")
        #endif
        
        #if os(iOS) || os(iPadOS)
        capabilities.append("touch_input")
        capabilities.append("camera_access")
        #endif
        
        return capabilities
    }
}

// MARK: - 组播设备发现消息契约

/// 设备发现消息（UDP组播）统一契约
/// 必需字段：id、name、type、address、port、osVersion、capabilities、publicKeyFingerprint、timestamp
/// 可选字段：publicKeyBase64、signatureBase64（用于验签）
/// 强身份字段：deviceId、pubKeyFP（用于本机判定）
public struct P2PDiscoveryMessage: Codable, Sendable {
    public let id: String
    public let name: String
    public let type: P2PDeviceType
    public let address: String
    public let port: UInt16
    public let osVersion: String
    public let capabilities: [String]
    public let publicKeyFingerprint: String
    public let timestamp: Double
    public let publicKeyBase64: String?
    public let signatureBase64: String?
    
 // MARK: - 强身份字段（用于本机判定）
 /// 设备持久化 ID（UUID）
    public let deviceId: String?
 /// P-256 公钥 SHA256 指纹（hex 小写）
    public let pubKeyFP: String?
 /// MAC 地址集合（以逗号分隔的字符串）
    public let macAddresses: String?
}

// MARK: - P2P设备
public struct P2PDevice: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let type: P2PDeviceType
    public let address: String
    public let port: UInt16
    public let osVersion: String
    public let capabilities: [String]
    public let publicKey: Data
    public let lastSeen: Date
 /// 发现消息原始时间戳（用于UI展示原始时效），可能为空
    public let lastMessageTimestamp: Date?
 /// 验签是否通过（基于发现消息签名），默认false
    public let isVerified: Bool
 /// 验签失败原因（中文），当验签未通过时可用于UI显示
    public let verificationFailedReason: String?
 /// 网络端点列表，用于连接建立
    public let endpoints: [String] // 存储为字符串数组，实际使用时转换为NWEndpoint
    
 // MARK: - 强身份字段（用于本机判定）
 /// 设备持久化 ID（UUID）
    public let persistentDeviceId: String?
 /// P-256 公钥指纹
    public let pubKeyFingerprint: String?
 /// MAC 地址集合
    public let macAddresses: Set<String>?
    
 /// 设备ID的便捷访问器
    public var deviceId: String { return id }
    public var deviceType: P2PDeviceType { return type }

    public init(from deviceInfo: P2PDeviceInfo) {
        self.id = deviceInfo.id
        self.name = deviceInfo.name
        self.type = deviceInfo.type
        self.address = deviceInfo.address
        self.port = deviceInfo.port
        self.osVersion = deviceInfo.osVersion
        self.capabilities = deviceInfo.capabilities
 // Swift 6.2.1：公钥数据在发现阶段暂不可用，将在协议握手阶段获取
 // 实际的公钥/身份绑定发生在 HandshakeDriver / TwoAttemptHandshakeManager 主路径中
        self.publicKey = Data()
        self.lastSeen = Date()
        self.lastMessageTimestamp = nil
 // 未获取公钥时标记为未验证，连接前需进行密钥交换
        self.isVerified = false
        self.verificationFailedReason = deviceInfo.publicKeyFingerprint.isEmpty ? "等待公钥交换" : nil
        self.endpoints = ["\(deviceInfo.address):\(deviceInfo.port)"]
 // 强身份字段：从 deviceInfo 中提取公钥指纹
        self.persistentDeviceId = nil
        self.pubKeyFingerprint = deviceInfo.publicKeyFingerprint.isEmpty ? nil : deviceInfo.publicKeyFingerprint
        self.macAddresses = nil
    }

    public init(id: String, name: String, type: P2PDeviceType, address: String, port: UInt16, osVersion: String, capabilities: [String], publicKey: Data, lastSeen: Date, endpoints: [String] = [], lastMessageTimestamp: Date? = nil, isVerified: Bool = false, verificationFailedReason: String? = nil, persistentDeviceId: String? = nil, pubKeyFingerprint: String? = nil, macAddresses: Set<String>? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.address = address
        self.port = port
        self.osVersion = osVersion
        self.capabilities = capabilities
        self.publicKey = publicKey
        self.lastSeen = lastSeen
        self.lastMessageTimestamp = lastMessageTimestamp
        self.isVerified = isVerified
        self.verificationFailedReason = verificationFailedReason
        self.endpoints = endpoints.isEmpty ? ["\(address):\(port)"] : endpoints
        self.persistentDeviceId = persistentDeviceId
        self.pubKeyFingerprint = pubKeyFingerprint
        self.macAddresses = macAddresses
    }
    
 /// 检查设备是否支持指定功能
    public func supports(_ capability: String) -> Bool {
        return capabilities.contains(capability)
    }
    
 /// 设备是否在线
    public var isOnline: Bool {
        return Date().timeIntervalSince(lastSeen) < 30 // 30秒内视为在线
    }
    
 /// 状态描述
    public var statusDescription: String {
        if isOnline {
            return "在线"
        } else {
            let interval = Date().timeIntervalSince(lastSeen)
            if interval < 300 { // 5分钟内
                return "刚刚离线"
            } else if interval < 3600 { // 1小时内
                return "\(Int(interval / 60))分钟前在线"
            } else {
                return "\(Int(interval / 3600))小时前在线"
            }
        }
    }
}
