import Foundation

// MARK: - 连接请求类型
public enum ConnectionRequestType: String, Codable, CaseIterable {
    case remoteDesktop = "remote_desktop"
    case fileTransfer = "file_transfer"
    case screenSharing = "screen_sharing"
    case systemControl = "system_control"
    
    public var displayName: String {
        switch self {
        case .remoteDesktop: return "远程桌面"
        case .fileTransfer: return "文件传输"
        case .screenSharing: return "屏幕共享"
        case .systemControl: return "系统控制"
        }
    }
    
    public var iconName: String {
        switch self {
        case .remoteDesktop: return "display"
        case .fileTransfer: return "folder"
        case .screenSharing: return "rectangle.on.rectangle"
        case .systemControl: return "gear"
        }
    }
}

// MARK: - P2P连接请求
public struct P2PConnectionRequest: Codable, Identifiable {
    public let id: String
    public let sourceDevice: P2PDeviceInfo
    public let targetDevice: P2PDevice
    public let timestamp: Date
    public let signature: Data
    public let requestType: ConnectionRequestType
    public let message: String?
    
    public init(sourceDevice: P2PDeviceInfo, targetDevice: P2PDevice, timestamp: Date, signature: Data, requestType: ConnectionRequestType = .remoteDesktop, message: String? = nil) {
        self.id = UUID().uuidString
        self.sourceDevice = sourceDevice
        self.targetDevice = targetDevice
        self.timestamp = timestamp
        self.signature = signature
        self.requestType = requestType
        self.message = message
    }
    
 /// 请求是否已过期
    public var isExpired: Bool {
        return Date().timeIntervalSince(timestamp) > 300
    }
}

// MARK: - P2P连接状态
public enum P2PConnectionStatus: String, Codable {
    case connecting = "connecting"
    case connected = "connected"
    case authenticating = "authenticating"
    case authenticated = "authenticated"
    case disconnected = "disconnected"
    case failed = "failed"
    case listening = "listening"
    case networkUnavailable = "networkUnavailable"
    
    public var displayName: String {
        switch self {
        case .connecting: return "连接中"
        case .connected: return "已连接"
        case .authenticating: return "认证中"
        case .authenticated: return "已认证"
        case .disconnected: return "已断开"
        case .failed: return "连接失败"
        case .listening: return "监听中"
        case .networkUnavailable: return "网络不可用"
        }
    }
    
    public var isActive: Bool {
        return self == .connected || self == .authenticated
    }
}

// MARK: - 会话安全保证级别
@available(macOS 14.0, iOS 17.0, *)
public enum P2PSessionAssuranceLevel: String, Codable, Sendable {
    case pqcStrict = "pqc_strict"
    case bootstrapAssisted = "bootstrap_assisted"
    case legacyClassic = "legacy_classic"
    case unknown = "unknown"

    public var displayName: String {
        switch self {
        case .pqcStrict:
            return "PQC严格模式"
        case .bootstrapAssisted:
            return "引导恢复模式"
        case .legacyClassic:
            return "经典兼容模式"
        case .unknown:
            return "未知"
        }
    }
}
