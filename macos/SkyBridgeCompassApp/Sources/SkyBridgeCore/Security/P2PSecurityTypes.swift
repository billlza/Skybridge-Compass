import Foundation
import CryptoKit

// MARK: - P2P权限类型

/// P2P权限枚举
public enum P2PPermission: String, CaseIterable, Codable {
    case screenShare = "screen_share"           // 屏幕共享权限
    case remoteControl = "remote_control"       // 远程控制权限
    case fileTransfer = "file_transfer"         // 文件传输权限
    case clipboard = "clipboard"                // 剪贴板访问权限
    case systemInfo = "system_info"             // 系统信息访问权限
    case networkAccess = "network_access"       // 网络访问权限
    case audioCapture = "audio_capture"         // 音频捕获权限
    case videoCapture = "video_capture"         // 视频捕获权限
    case keyboardInput = "keyboard_input"       // 键盘输入权限
    case mouseInput = "mouse_input"             // 鼠标输入权限
    case fullAccess = "full_access"             // 完全访问权限
    
    /// 权限显示名称
    public var displayName: String {
        switch self {
        case .screenShare: return "屏幕共享"
        case .remoteControl: return "远程控制"
        case .fileTransfer: return "文件传输"
        case .clipboard: return "剪贴板访问"
        case .systemInfo: return "系统信息"
        case .networkAccess: return "网络访问"
        case .audioCapture: return "音频捕获"
        case .videoCapture: return "视频捕获"
        case .keyboardInput: return "键盘输入"
        case .mouseInput: return "鼠标输入"
        case .fullAccess: return "完全访问"
        }
    }
    
    /// 权限描述
    public var description: String {
        switch self {
        case .screenShare: return "允许查看您的屏幕内容"
        case .remoteControl: return "允许远程控制您的设备"
        case .fileTransfer: return "允许传输和接收文件"
        case .clipboard: return "允许访问剪贴板内容"
        case .systemInfo: return "允许获取系统信息"
        case .networkAccess: return "允许访问网络资源"
        case .audioCapture: return "允许捕获音频"
        case .videoCapture: return "允许捕获视频"
        case .keyboardInput: return "允许模拟键盘输入"
        case .mouseInput: return "允许模拟鼠标操作"
        case .fullAccess: return "允许完全访问设备功能"
        }
    }
    
    /// 权限风险级别
    public var riskLevel: PermissionRiskLevel {
        switch self {
        case .systemInfo, .networkAccess:
            return .low
        case .clipboard, .fileTransfer, .audioCapture, .videoCapture:
            return .medium
        case .screenShare, .keyboardInput, .mouseInput:
            return .high
        case .remoteControl, .fullAccess:
            return .critical
        }
    }
}

/// 权限风险级别
public enum PermissionRiskLevel: String, Codable {
    case low = "low"
    case medium = "medium"
    case high = "high"
    case critical = "critical"
    
    public var displayName: String {
        switch self {
        case .low: return "低风险"
        case .medium: return "中等风险"
        case .high: return "高风险"
        case .critical: return "严重风险"
        }
    }
    
    public var color: String {
        switch self {
        case .low: return "green"
        case .medium: return "yellow"
        case .high: return "orange"
        case .critical: return "red"
        }
    }
}

// MARK: - P2P权限管理器

/// P2P权限管理器
public class P2PPermissionManager: ObservableObject {
    
    /// 设备权限映射表
    @Published public private(set) var devicePermissions: [String: Set<P2PPermission>] = [:]
    
    /// 权限请求历史
    @Published public private(set) var permissionHistory: [P2PPermissionRequest] = []
    
    public init() {
        loadPermissions()
    }
    
    /// 检查设备是否拥有指定权限
    public func hasPermission(_ permission: P2PPermission, for deviceId: String) -> Bool {
        return devicePermissions[deviceId]?.contains(permission) ?? false
    }
    
    /// 授予权限
    public func grantPermission(_ permission: P2PPermission, to deviceId: String) {
        if devicePermissions[deviceId] == nil {
            devicePermissions[deviceId] = Set<P2PPermission>()
        }
        devicePermissions[deviceId]?.insert(permission)
        
        // 记录权限变更历史
        let request = P2PPermissionRequest(
            deviceId: deviceId,
            permission: permission,
            action: .granted,
            timestamp: Date()
        )
        permissionHistory.append(request)
        
        savePermissions()
        print("✅ 已授予权限 \(permission.displayName) 给设备: \(deviceId)")
    }
    
    /// 撤销权限
    public func revokePermission(_ permission: P2PPermission, from deviceId: String) {
        devicePermissions[deviceId]?.remove(permission)
        
        // 如果设备没有任何权限，移除设备记录
        if devicePermissions[deviceId]?.isEmpty == true {
            devicePermissions.removeValue(forKey: deviceId)
        }
        
        // 记录权限变更历史
        let request = P2PPermissionRequest(
            deviceId: deviceId,
            permission: permission,
            action: .revoked,
            timestamp: Date()
        )
        permissionHistory.append(request)
        
        savePermissions()
        print("🚫 已撤销权限 \(permission.displayName) 从设备: \(deviceId)")
    }
    
    /// 获取设备的所有权限
    public func getPermissions(for deviceId: String) -> Set<P2PPermission> {
        return devicePermissions[deviceId] ?? Set<P2PPermission>()
    }
    
    /// 批量授予权限
    public func grantPermissions(_ permissions: Set<P2PPermission>, to deviceId: String) {
        for permission in permissions {
            grantPermission(permission, to: deviceId)
        }
    }
    
    /// 清除设备的所有权限
    public func clearAllPermissions(for deviceId: String) {
        let permissions = getPermissions(for: deviceId)
        for permission in permissions {
            revokePermission(permission, from: deviceId)
        }
    }
    
    /// 获取权限请求历史
    public func getPermissionHistory(for deviceId: String? = nil) -> [P2PPermissionRequest] {
        if let deviceId = deviceId {
            return permissionHistory.filter { $0.deviceId == deviceId }
        }
        return permissionHistory
    }
    
    /// 清理权限历史（保留最近100条记录）
    public func cleanupPermissionHistory() {
        if permissionHistory.count > 100 {
            permissionHistory = Array(permissionHistory.suffix(100))
            savePermissions()
        }
    }
    
    // MARK: - 私有方法
    
    /// 加载权限配置
    private func loadPermissions() {
        // 加载设备权限
        if let permissionsData = UserDefaults.standard.data(forKey: "SkyBridge.DevicePermissions"),
           let permissions = try? JSONDecoder().decode([String: Set<P2PPermission>].self, from: permissionsData) {
            self.devicePermissions = permissions
        }
        
        // 加载权限历史
        if let historyData = UserDefaults.standard.data(forKey: "SkyBridge.PermissionHistory"),
           let history = try? JSONDecoder().decode([P2PPermissionRequest].self, from: historyData) {
            self.permissionHistory = history
        }
    }
    
    /// 保存权限配置
    private func savePermissions() {
        // 保存设备权限
        if let permissionsData = try? JSONEncoder().encode(devicePermissions) {
            UserDefaults.standard.set(permissionsData, forKey: "SkyBridge.DevicePermissions")
        }
        
        // 保存权限历史
        if let historyData = try? JSONEncoder().encode(permissionHistory) {
            UserDefaults.standard.set(historyData, forKey: "SkyBridge.PermissionHistory")
        }
    }
}

// MARK: - P2P权限请求

/// P2P权限请求记录
public struct P2PPermissionRequest: Codable, Identifiable {
    public let id: UUID
    public let deviceId: String
    public let permission: P2PPermission
    public let action: PermissionAction
    public let timestamp: Date
    
    public init(deviceId: String, permission: P2PPermission, action: PermissionAction, timestamp: Date) {
        self.id = UUID()
        self.deviceId = deviceId
        self.permission = permission
        self.action = action
        self.timestamp = timestamp
    }
}

/// 权限操作类型
public enum PermissionAction: String, Codable {
    case requested = "requested"    // 请求权限
    case granted = "granted"        // 授予权限
    case denied = "denied"          // 拒绝权限
    case revoked = "revoked"        // 撤销权限
    
    public var displayName: String {
        switch self {
        case .requested: return "请求"
        case .granted: return "授予"
        case .denied: return "拒绝"
        case .revoked: return "撤销"
        }
    }
}

// MARK: - P2P认证相关类型

/// P2P设备证书
public struct P2PDeviceCertificate: Codable {
    public let deviceId: String
    public let publicKey: Data
    public let fingerprint: String
    public let timestamp: Date
    public let signature: Data
    
    public init(deviceId: String, publicKey: Data, fingerprint: String, timestamp: Date, signature: Data) {
        self.deviceId = deviceId
        self.publicKey = publicKey
        self.fingerprint = fingerprint
        self.timestamp = timestamp
        self.signature = signature
    }
}

/// P2P认证响应
public struct P2PAuthResponse: Codable {
    public let challenge: Data
    public let certificate: P2PDeviceCertificate
    public let timestamp: Date
    
    public init(challenge: Data, certificate: P2PDeviceCertificate, timestamp: Date) {
        self.challenge = challenge
        self.certificate = certificate
        self.timestamp = timestamp
    }
}

// MARK: - P2P加密相关类型

/// P2P加密数据
public struct P2PEncryptedData: Codable {
    public let encryptedData: Data
    public let nonce: Data
    public let tag: Data
    public let timestamp: Date
    
    public init(encryptedData: Data, nonce: Data, tag: Data, timestamp: Date) {
        self.encryptedData = encryptedData
        self.nonce = nonce
        self.tag = tag
        self.timestamp = timestamp
    }
}

/// P2P安全错误
public enum P2PSecurityError: Error, LocalizedError {
    case noSessionKey
    case dataExpired
    case invalidSignature
    case invalidCertificate
    case authenticationFailed
    case permissionDenied
    case encryptionFailed
    case decryptionFailed
    
    public var errorDescription: String? {
        switch self {
        case .noSessionKey:
            return "会话密钥不存在"
        case .dataExpired:
            return "数据已过期"
        case .invalidSignature:
            return "签名无效"
        case .invalidCertificate:
            return "证书无效"
        case .authenticationFailed:
            return "认证失败"
        case .permissionDenied:
            return "权限被拒绝"
        case .encryptionFailed:
            return "加密失败"
        case .decryptionFailed:
            return "解密失败"
        }
    }
}

// MARK: - P2P安全配置

/// P2P安全配置
public struct P2PSecurityConfiguration: Codable, Sendable {
    /// 会话密钥有效期（秒）
    public let sessionKeyLifetime: TimeInterval
    /// 认证挑战有效期（秒）
    public let challengeLifetime: TimeInterval
    /// 数据加密有效期（秒）
    public let dataLifetime: TimeInterval
    /// 是否启用设备指纹验证
    public let enableDeviceFingerprint: Bool
    /// 是否启用权限管理
    public let enablePermissionManagement: Bool
    /// 最大信任设备数量
    public let maxTrustedDevices: Int
    
    public init(
        sessionKeyLifetime: TimeInterval = 3600,        // 1小时
        challengeLifetime: TimeInterval = 300,          // 5分钟
        dataLifetime: TimeInterval = 3600,              // 1小时
        enableDeviceFingerprint: Bool = true,
        enablePermissionManagement: Bool = true,
        maxTrustedDevices: Int = 10
    ) {
        self.sessionKeyLifetime = sessionKeyLifetime
        self.challengeLifetime = challengeLifetime
        self.dataLifetime = dataLifetime
        self.enableDeviceFingerprint = enableDeviceFingerprint
        self.enablePermissionManagement = enablePermissionManagement
        self.maxTrustedDevices = maxTrustedDevices
    }
    
    /// 默认安全配置
    public static let `default` = P2PSecurityConfiguration()
    
    /// 高安全级别配置
    public static let highSecurity = P2PSecurityConfiguration(
        sessionKeyLifetime: 1800,       // 30分钟
        challengeLifetime: 120,         // 2分钟
        dataLifetime: 1800,             // 30分钟
        enableDeviceFingerprint: true,
        enablePermissionManagement: true,
        maxTrustedDevices: 5
    )
    
    /// 低安全级别配置（用于开发测试）
    public static let lowSecurity = P2PSecurityConfiguration(
        sessionKeyLifetime: 7200,       // 2小时
        challengeLifetime: 600,         // 10分钟
        dataLifetime: 7200,             // 2小时
        enableDeviceFingerprint: false,
        enablePermissionManagement: false,
        maxTrustedDevices: 20
    )
}