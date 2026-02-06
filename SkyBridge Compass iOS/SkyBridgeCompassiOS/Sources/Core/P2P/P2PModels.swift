//
// P2PModels.swift
// SkyBridgeCompassiOS
//
// P2P 网络模型 - 与 macOS 完全兼容
// 包含设备类型、NAT类型、STUN服务器、连接状态等定义
//

import Foundation
import Network
import CryptoKit
#if canImport(UIKit)
import UIKit
#endif

// MARK: - P2P Device Type

/// P2P 设备类型枚举
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

// MARK: - STUN Server

/// STUN服务器配置
public struct STUNServer: Codable, Sendable {
    /// 服务器主机名
    public let host: String
    /// 服务器端口
    public let port: UInt16
    
    public init(host: String, port: UInt16 = 3478) {
        self.host = host
        self.port = port
    }
    
    /// 默认STUN服务器列表
    public static let defaultServers = [
        // SkyBridge 自建服务器 (首选)
        STUNServer(host: "54.92.79.99", port: 3478),
        // 公共备用服务器
        STUNServer(host: "stun.l.google.com", port: 19302),
        STUNServer(host: "stun1.l.google.com", port: 19302),
        STUNServer(host: "stun.cloudflare.com", port: 3478)
    ]
}

// MARK: - NAT Type

/// NAT类型
public enum NATType: String, Codable, CaseIterable, Sendable {
    case fullCone = "full_cone"
    case restrictedCone = "restricted_cone"
    case portRestrictedCone = "port_restricted_cone"
    case symmetric = "symmetric"
    case noNAT = "no_nat"
    case unknown = "unknown"
    
    public var displayName: String {
        switch self {
        case .fullCone: return "完全锥形NAT"
        case .restrictedCone: return "限制锥形NAT"
        case .portRestrictedCone: return "端口限制锥形NAT"
        case .symmetric: return "对称NAT"
        case .noNAT: return "无NAT"
        case .unknown: return "未知"
        }
    }
    
    public var traversalDifficulty: TraversalDifficulty {
        switch self {
        case .noNAT, .fullCone:
            return .easy
        case .restrictedCone, .portRestrictedCone:
            return .medium
        case .symmetric:
            return .hard
        case .unknown:
            return .unknown
        }
    }
}

/// 穿透难度
public enum TraversalDifficulty: String, Codable, CaseIterable, Sendable {
    case easy = "easy"
    case medium = "medium"
    case hard = "hard"
    case unknown = "unknown"
    
    public var displayName: String {
        switch self {
        case .easy: return "简单"
        case .medium: return "中等"
        case .hard: return "困难"
        case .unknown: return "未知"
        }
    }
}

// MARK: - P2P Protocol

/// P2P协议类型
public enum P2PProtocol: String, Codable, CaseIterable, Sendable {
    case udp = "udp"
    case tcp = "tcp"
    case webrtc = "webrtc"
    
    public var displayName: String {
        switch self {
        case .udp: return "UDP"
        case .tcp: return "TCP"
        case .webrtc: return "WebRTC"
        }
    }
    
    public var defaultPort: UInt16 {
        switch self {
        case .udp: return 8080
        case .tcp: return 8081
        case .webrtc: return 8082
        }
    }
}

// MARK: - P2P Device Info

/// 设备信息
public struct P2PDeviceInfo: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let type: P2PDeviceType
    public let address: String
    public let port: UInt16
    public let osVersion: String
    public let capabilities: [String]
    public let publicKeyFingerprint: String
    
    public init(
        id: String,
        name: String,
        type: P2PDeviceType,
        address: String,
        port: UInt16,
        osVersion: String,
        capabilities: [String],
        publicKeyFingerprint: String
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.address = address
        self.port = port
        self.osVersion = osVersion
        self.capabilities = capabilities
        self.publicKeyFingerprint = publicKeyFingerprint
	    }
	    
	    /// 获取当前设备信息
	    @MainActor
	    public static func current() -> P2PDeviceInfo {
	        return P2PDeviceInfo(
	            id: getOrCreateDeviceId(),
	            name: getDeviceName(),
	            type: getCurrentDeviceType(),
            address: "0.0.0.0",
            port: 8080,
            osVersion: getOSVersion(),
            capabilities: getSupportedCapabilities(),
            publicKeyFingerprint: ""
        )
    }
    
    /// 获取或创建设备ID
    private static func getOrCreateDeviceId() -> String {
        let key = "SkyBridge.DeviceId"
        if let existingId = UserDefaults.standard.string(forKey: key) {
            return existingId
        } else {
            let newId = UUID().uuidString
            UserDefaults.standard.set(newId, forKey: key)
            return newId
	        }
	    }
	    
	    @MainActor
	    private static func getDeviceName() -> String {
	        #if canImport(UIKit)
	        return UIDevice.current.name
	        #else
	        return "Unknown Device"
	        #endif
	    }
	    
	    @MainActor
	    private static func getCurrentDeviceType() -> P2PDeviceType {
	        #if canImport(UIKit)
	        if UIDevice.current.userInterfaceIdiom == .pad {
	            return .iPadOS
        } else {
            return .iOS
        }
        #else
        return .iOS
        #endif
    }
    
    private static func getOSVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
    
    private static func getSupportedCapabilities() -> [String] {
        var capabilities = [
            "remote_desktop_viewer",
            "file_transfer",
            "screen_sharing_viewer",
            "touch_input",
            "clipboard_sync"
        ]
        
        #if canImport(UIKit)
        capabilities.append("camera_access")
        #endif
        
        return capabilities
    }
}

// MARK: - P2P Discovery Message

/// 设备发现消息（UDP组播）
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
    public let deviceId: String?
    public let pubKeyFP: String?
    public let macAddresses: String?
    
    public init(
        id: String,
        name: String,
        type: P2PDeviceType,
        address: String,
        port: UInt16,
        osVersion: String,
        capabilities: [String],
        publicKeyFingerprint: String,
        timestamp: Double = Date().timeIntervalSince1970,
        publicKeyBase64: String? = nil,
        signatureBase64: String? = nil,
        deviceId: String? = nil,
        pubKeyFP: String? = nil,
        macAddresses: String? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.address = address
        self.port = port
        self.osVersion = osVersion
        self.capabilities = capabilities
        self.publicKeyFingerprint = publicKeyFingerprint
        self.timestamp = timestamp
        self.publicKeyBase64 = publicKeyBase64
        self.signatureBase64 = signatureBase64
        self.deviceId = deviceId
        self.pubKeyFP = pubKeyFP
        self.macAddresses = macAddresses
    }
}

// MARK: - P2P Device

/// P2P设备
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
    public let lastMessageTimestamp: Date?
    public let isVerified: Bool
    public let verificationFailedReason: String?
    public let endpoints: [String]
    public let persistentDeviceId: String?
    public let pubKeyFingerprint: String?
    public let macAddresses: Set<String>?
    
    public var deviceId: String { id }
    public var deviceType: P2PDeviceType { type }
    
    public init(
        id: String,
        name: String,
        type: P2PDeviceType,
        address: String,
        port: UInt16,
        osVersion: String,
        capabilities: [String],
        publicKey: Data,
        lastSeen: Date,
        endpoints: [String] = [],
        lastMessageTimestamp: Date? = nil,
        isVerified: Bool = false,
        verificationFailedReason: String? = nil,
        persistentDeviceId: String? = nil,
        pubKeyFingerprint: String? = nil,
        macAddresses: Set<String>? = nil
    ) {
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
    
    public init(from deviceInfo: P2PDeviceInfo) {
        self.id = deviceInfo.id
        self.name = deviceInfo.name
        self.type = deviceInfo.type
        self.address = deviceInfo.address
        self.port = deviceInfo.port
        self.osVersion = deviceInfo.osVersion
        self.capabilities = deviceInfo.capabilities
        self.publicKey = Data()
        self.lastSeen = Date()
        self.lastMessageTimestamp = nil
        self.isVerified = false
        self.verificationFailedReason = deviceInfo.publicKeyFingerprint.isEmpty ? "等待公钥交换" : nil
        self.endpoints = ["\(deviceInfo.address):\(deviceInfo.port)"]
        self.persistentDeviceId = nil
        self.pubKeyFingerprint = deviceInfo.publicKeyFingerprint.isEmpty ? nil : deviceInfo.publicKeyFingerprint
        self.macAddresses = nil
    }
    
    /// 检查设备是否支持指定功能
    public func supports(_ capability: String) -> Bool {
        capabilities.contains(capability)
    }
    
    /// 设备是否在线
    public var isOnline: Bool {
        Date().timeIntervalSince(lastSeen) < 30
    }
    
    /// 状态描述
    public var statusDescription: String {
        if isOnline {
            return "在线"
        } else {
            let interval = Date().timeIntervalSince(lastSeen)
            if interval < 300 {
                return "刚刚离线"
            } else if interval < 3600 {
                return "\(Int(interval / 60))分钟前在线"
            } else {
                return "\(Int(interval / 3600))小时前在线"
            }
        }
    }
}

// MARK: - Connection Request Type

/// 连接请求类型
public enum ConnectionRequestType: String, Codable, CaseIterable, Sendable {
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

// MARK: - P2P Connection Status

/// P2P连接状态
public enum P2PConnectionStatus: String, Codable, Sendable {
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
        self == .connected || self == .authenticated
    }
}

// MARK: - P2P Connection Request

/// P2P连接请求
public struct P2PConnectionRequest: Codable, Identifiable, Sendable {
    public let id: String
    public let sourceDevice: P2PDeviceInfo
    public let targetDeviceId: String
    public let timestamp: Date
    public let signature: Data
    public let requestType: ConnectionRequestType
    public let message: String?
    
    public init(
        sourceDevice: P2PDeviceInfo,
        targetDeviceId: String,
        timestamp: Date = Date(),
        signature: Data,
        requestType: ConnectionRequestType = .remoteDesktop,
        message: String? = nil
    ) {
        self.id = UUID().uuidString
        self.sourceDevice = sourceDevice
        self.targetDeviceId = targetDeviceId
        self.timestamp = timestamp
        self.signature = signature
        self.requestType = requestType
        self.message = message
    }
    
    /// 请求是否已过期
    public var isExpired: Bool {
        Date().timeIntervalSince(timestamp) > 300
    }
}

// MARK: - P2P Message

/// P2P消息
public enum P2PMessage: Codable, Sendable {
    case authChallenge(Data)
    case authResponse(Data)
    case remoteDesktopFrame(Data)
    case fileTransferRequest(P2PFileTransferRequest)
    case fileTransferData(Data)
    case systemCommand(SystemCommand)
    case heartbeat
    
    private enum CodingKeys: String, CodingKey {
        case type, payload
    }
    
    private enum MessageType: String, Codable {
        case authChallenge, authResponse, remoteDesktopFrame
        case fileTransferRequest, fileTransferData, systemCommand, heartbeat
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(MessageType.self, forKey: .type)
        
        switch type {
        case .authChallenge:
            let data = try container.decode(Data.self, forKey: .payload)
            self = .authChallenge(data)
        case .authResponse:
            let data = try container.decode(Data.self, forKey: .payload)
            self = .authResponse(data)
        case .remoteDesktopFrame:
            let data = try container.decode(Data.self, forKey: .payload)
            self = .remoteDesktopFrame(data)
        case .fileTransferRequest:
            let request = try container.decode(P2PFileTransferRequest.self, forKey: .payload)
            self = .fileTransferRequest(request)
        case .fileTransferData:
            let data = try container.decode(Data.self, forKey: .payload)
            self = .fileTransferData(data)
        case .systemCommand:
            let command = try container.decode(SystemCommand.self, forKey: .payload)
            self = .systemCommand(command)
        case .heartbeat:
            self = .heartbeat
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        switch self {
        case .authChallenge(let data):
            try container.encode(MessageType.authChallenge, forKey: .type)
            try container.encode(data, forKey: .payload)
        case .authResponse(let data):
            try container.encode(MessageType.authResponse, forKey: .type)
            try container.encode(data, forKey: .payload)
        case .remoteDesktopFrame(let data):
            try container.encode(MessageType.remoteDesktopFrame, forKey: .type)
            try container.encode(data, forKey: .payload)
        case .fileTransferRequest(let request):
            try container.encode(MessageType.fileTransferRequest, forKey: .type)
            try container.encode(request, forKey: .payload)
        case .fileTransferData(let data):
            try container.encode(MessageType.fileTransferData, forKey: .type)
            try container.encode(data, forKey: .payload)
        case .systemCommand(let command):
            try container.encode(MessageType.systemCommand, forKey: .type)
            try container.encode(command, forKey: .payload)
        case .heartbeat:
            try container.encode(MessageType.heartbeat, forKey: .type)
        }
    }
}

// MARK: - P2P File Transfer Request

/// 文件传输请求
public struct P2PFileTransferRequest: Codable, Sendable {
    public let fileId: String
    public let fileName: String
    public let fileSize: Int64
    public let mimeType: String?
    public let checksum: String?
    
    public init(
        fileId: String = UUID().uuidString,
        fileName: String,
        fileSize: Int64,
        mimeType: String? = nil,
        checksum: String? = nil
    ) {
        self.fileId = fileId
        self.fileName = fileName
        self.fileSize = fileSize
        self.mimeType = mimeType
        self.checksum = checksum
    }
}

// MARK: - System Command

/// 系统命令
public struct SystemCommand: Codable, Sendable {
    public let id: String
    public let type: CommandType
    public let parameters: [String: String]
    public let timestamp: Date
    
    public enum CommandType: String, Codable, CaseIterable, Sendable {
        case shutdown = "shutdown"
        case restart = "restart"
        case sleep = "sleep"
        case lock = "lock"
        case screenshot = "screenshot"
        case volumeUp = "volume_up"
        case volumeDown = "volume_down"
        case mute = "mute"
        case brightness = "brightness"
        case custom = "custom"
    }
    
    public init(id: String = UUID().uuidString, type: CommandType, parameters: [String: String] = [:]) {
        self.id = id
        self.type = type
        self.parameters = parameters
        self.timestamp = Date()
    }
}

// MARK: - P2P Connection Quality

/// 连接质量
public struct P2PConnectionQuality: Codable, Sendable {
    public let latency: Double
    public let packetLoss: Double
    public let bandwidth: UInt64
    public let stabilityScore: Int
    
    public init(latency: Double, packetLoss: Double, bandwidth: UInt64, stabilityScore: Int) {
        self.latency = latency
        self.packetLoss = packetLoss
        self.bandwidth = bandwidth
        self.stabilityScore = stabilityScore
    }
    
    public var qualityLevel: QualityLevel {
        // latency is in seconds (TimeInterval semantics), consistent with macOS.
        if stabilityScore >= 80 && latency < 0.05 && packetLoss < 0.01 {
            return .excellent
        } else if stabilityScore >= 60 && latency < 0.10 && packetLoss < 0.05 {
            return .good
        } else if stabilityScore >= 40 && latency < 0.20 && packetLoss < 0.1 {
            return .fair
        } else {
            return .poor
        }
    }
    
    public enum QualityLevel: String, Sendable {
        case excellent = "excellent"
        case good = "good"
        case fair = "fair"
        case poor = "poor"
        
        public var displayName: String {
            switch self {
            case .excellent: return "优秀"
            case .good: return "良好"
            case .fair: return "一般"
            case .poor: return "较差"
            }
        }
        
        public var color: String {
            switch self {
            case .excellent: return "green"
            case .good: return "blue"
            case .fair: return "orange"
            case .poor: return "red"
            }
        }
    }
}

// MARK: - P2P Network Statistics

/// 网络统计
public struct P2PNetworkStatistics: Sendable {
    public var bytesSent: UInt64 = 0
    public var bytesReceived: UInt64 = 0
    public var packetsLost: UInt64 = 0
    public var averageLatency: Double = 0
    public var connectionUptime: TimeInterval = 0
    
    public init() {}
}
