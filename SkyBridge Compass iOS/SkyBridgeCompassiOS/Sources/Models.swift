import Foundation
import SwiftUI

// MARK: - Core Models

/// 设备平台枚举
public enum DevicePlatform: String, Codable, Sendable, CaseIterable {
    case iOS = "ios"
    case iPadOS = "ipados"
    case macOS = "macos"
    case android = "android"
    case linux = "linux"
    case windows = "windows"
    case unknown = "unknown"
    
    /// 平台显示名称
    public var displayName: String {
        switch self {
        case .iOS: return "iOS"
        case .iPadOS: return "iPadOS"
        case .macOS: return "macOS"
        case .android: return "Android"
        case .linux: return "Linux"
        case .windows: return "Windows"
        case .unknown: return "Unknown"
        }
    }
    
    /// 平台图标名称
    public var iconName: String {
        switch self {
        case .iOS: return "iphone"
        case .iPadOS: return "ipad"
        case .macOS: return "desktopcomputer"
        case .android: return "candybarphone"
        case .linux: return "pc"
        case .windows: return "laptopcomputer"
        case .unknown: return "questionmark.circle"
        }
    }
    
    /// 平台渐变色
    public var gradientColors: [Color] {
        switch self {
        case .iOS, .iPadOS:
            return [Color(red: 0.0, green: 0.48, blue: 1.0), Color(red: 0.35, green: 0.68, blue: 1.0)]
        case .macOS:
            return [Color(red: 0.5, green: 0.5, blue: 0.5), Color(red: 0.7, green: 0.7, blue: 0.7)]
        case .android:
            return [Color(red: 0.24, green: 0.73, blue: 0.31), Color(red: 0.55, green: 0.85, blue: 0.45)]
        case .linux:
            return [Color(red: 0.87, green: 0.68, blue: 0.13), Color(red: 0.95, green: 0.82, blue: 0.40)]
        case .windows:
            return [Color(red: 0.0, green: 0.47, blue: 0.84), Color(red: 0.0, green: 0.65, blue: 0.95)]
        case .unknown:
            return [Color.gray, Color.gray.opacity(0.7)]
        }
    }
    
    /// 平台徽章颜色
    public var badgeColor: Color {
        switch self {
        case .iOS, .iPadOS: return .blue
        case .macOS: return .gray
        case .android: return .green
        case .linux: return .orange
        case .windows: return .cyan
        case .unknown: return .gray
        }
    }
}

/// 发现的设备
public struct DiscoveredDevice: Identifiable, Codable, Sendable {
    public let id: String
    public var name: String
    /// Bonjour service instance name（用于 NWEndpoint.service 连接；通常等于对端 publish 的 serviceName）
    public var bonjourServiceName: String?
    public var modelName: String
    public var platform: DevicePlatform
    public var osVersion: String
    public var ipAddress: String?
    /// Bonjour 服务类型（例如：_skybridge._tcp / _skybridge._udp）。用于在无 IP 时仍可直接连接。
    public var bonjourServiceType: String?
    /// Bonjour 域（一般为 local.）。用于在无 IP 时构造 NWEndpoint.service 连接。
    public var bonjourServiceDomain: String?
    /// 该设备被发现到的所有 Bonjour 服务类型（用于能力推断与端口展示）
    public var services: [String]
    /// 端口映射：serviceType -> port（有些情况下端口无法直接从 NWBrowser 获得，需要依赖 TXT 记录或后续 resolve）
    public var portMap: [String: UInt16]
    public var signalStrength: Int // RSSI
    public var lastSeen: Date
    public var isConnected: Bool
    public var isTrusted: Bool
    public var publicKey: Data?
    /// 设备在 TXT 里声明的能力（comma-separated）
    public var advertisedCapabilities: [String]
    public var capabilities: [String]
    
    public init(
        id: String,
        name: String,
        bonjourServiceName: String? = nil,
        modelName: String,
        platform: DevicePlatform,
        osVersion: String,
        ipAddress: String? = nil,
        bonjourServiceType: String? = nil,
        bonjourServiceDomain: String? = nil,
        services: [String] = [],
        portMap: [String: UInt16] = [:],
        signalStrength: Int = -50,
        lastSeen: Date = Date(),
        isConnected: Bool = false,
        isTrusted: Bool = false,
        publicKey: Data? = nil,
        advertisedCapabilities: [String] = [],
        capabilities: [String] = []
    ) {
        self.id = id
        self.name = name
        self.bonjourServiceName = bonjourServiceName
        self.modelName = modelName
        self.platform = platform
        self.osVersion = osVersion
        self.ipAddress = ipAddress
        self.bonjourServiceType = bonjourServiceType
        self.bonjourServiceDomain = bonjourServiceDomain
        self.services = services
        self.portMap = portMap
        self.signalStrength = signalStrength
        self.lastSeen = lastSeen
        self.isConnected = isConnected
        self.isTrusted = isTrusted
        self.publicKey = publicKey
        self.advertisedCapabilities = advertisedCapabilities
        self.capabilities = capabilities
    }
    
    /// 便捷初始化器
    public init(
        id: String,
        name: String,
        platform: DevicePlatform,
        ipAddress: String?
    ) {
        self.id = id
        self.name = name
        self.bonjourServiceName = nil
        self.modelName = name
        self.platform = platform
        self.osVersion = ""
        self.ipAddress = ipAddress
        self.bonjourServiceType = nil
        self.bonjourServiceDomain = nil
        self.services = []
        self.portMap = [:]
        self.signalStrength = -50
        self.lastSeen = Date()
        self.isConnected = false
        self.isTrusted = false
        self.publicKey = nil
        self.advertisedCapabilities = []
        self.capabilities = []
    }
}

// MARK: - DiscoveredDevice helpers (capabilities/ports)

public extension DiscoveredDevice {
    /// SkyBridge File Transfer Bonjour service type
    static let fileTransferServiceType = "_skybridge-transfer._tcp"
    /// SkyBridge Remote Control Bonjour service type
    static let remoteControlServiceType = "_skybridge-remote._tcp"

    var supportsFileTransfer: Bool {
        capabilities.contains("file_transfer") || services.contains(Self.fileTransferServiceType)
    }

    var supportsRemoteControl: Bool {
        capabilities.contains("remote_desktop") ||
        capabilities.contains("remote_control") ||
        services.contains(Self.remoteControlServiceType)
    }

    func port(for serviceType: String) -> UInt16? {
        portMap[serviceType]
    }

    var fileTransferPort: UInt16? { port(for: Self.fileTransferServiceType) }
    var remoteControlPort: UInt16? { port(for: Self.remoteControlServiceType) }
}

/// P2P 连接
public struct Connection: Identifiable, Sendable {
    public let id: String
    public let device: DiscoveredDevice
    public var status: ConnectionStatus
    public var encryptionType: EncryptionType
    public var latency: TimeInterval
    public var bandwidth: Int64
    public var connectedAt: Date
    
    public init(
        id: String = UUID().uuidString,
        device: DiscoveredDevice,
        status: ConnectionStatus = .connected,
        encryptionType: EncryptionType = .pqc,
        latency: TimeInterval = 0.01,
        bandwidth: Int64 = 100_000_000,
        connectedAt: Date = Date()
    ) {
        self.id = id
        self.device = device
        self.status = status
        self.encryptionType = encryptionType
        self.latency = latency
        self.bandwidth = bandwidth
        self.connectedAt = connectedAt
    }
}

/// 连接状态
public enum ConnectionStatus: String, Codable, Sendable {
    case connecting = "connecting"
    case connected = "connected"
    case disconnecting = "disconnecting"
    case disconnected = "disconnected"
    case failed = "failed"
    case error = "error"
    
    /// 显示名称
    public var displayName: String {
        switch self {
        case .connecting: return "连接中"
        case .connected: return "已连接"
        case .disconnecting: return "断开中"
        case .disconnected: return "已断开"
        case .failed: return "连接失败"
        case .error: return "错误"
        }
    }
}

/// 加密类型
public enum EncryptionType: String, Codable, Sendable {
    case pqc = "pqc"          // 后量子加密
    case hybrid = "hybrid"     // 混合加密 (PQC + 经典)
    case classic = "classic"   // 经典加密
    case none = "none"
}

/// 文件传输
public struct FileTransfer: Identifiable, Codable, Sendable {
    public let id: String
    public var fileName: String
    public var fileSize: Int64
    public var fileType: FileType
    public var progress: Double
    public var speed: Double // bytes per second
    public var status: TransferStatus
    public var isIncoming: Bool
    public var remotePeer: String
    public var timestamp: Date
    
    public init(
        id: String = UUID().uuidString,
        fileName: String,
        fileSize: Int64,
        fileType: FileType = .other,
        progress: Double = 0.0,
        speed: Double = 0.0,
        status: TransferStatus = .pending,
        isIncoming: Bool,
        remotePeer: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.fileName = fileName
        self.fileSize = fileSize
        self.fileType = fileType
        self.progress = progress
        self.speed = speed
        self.status = status
        self.isIncoming = isIncoming
        self.remotePeer = remotePeer
        self.timestamp = timestamp
    }
}

/// 文件类型
public enum FileType: String, Codable, Sendable {
    case image
    case video
    case audio
    case document
    case archive
    case other
}

/// 传输状态
public enum TransferStatus: String, Codable, Sendable {
    case pending
    case transferring
    case completed
    case failed
}

/// 用户信息
public struct User: Identifiable, Codable, Sendable {
    public let id: String
    public var email: String
    public var displayName: String
    public var avatarURL: URL?
    public var nebulaId: String?
    public var createdAt: Date
    
    public init(
        id: String,
        email: String,
        displayName: String,
        avatarURL: URL? = nil,
        nebulaId: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.nebulaId = nebulaId
        self.createdAt = createdAt
    }
}

/// 应用语言
public enum AppLanguage: String, CaseIterable, Codable, Sendable {
    case english = "en"
    case chinese = "zh-Hans"
    case japanese = "ja"
    
    public var displayName: String {
        switch self {
        case .english: return "English"
        case .chinese: return "简体中文"
        case .japanese: return "日本語"
        }
    }
    
    public var locale: Locale {
        Locale(identifier: rawValue)
    }
}
