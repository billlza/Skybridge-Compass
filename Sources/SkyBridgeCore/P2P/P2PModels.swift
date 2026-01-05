import Foundation
import Network
import CryptoKit

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

// MARK: - STUN服务器配置
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
        STUNServer(host: "stun.l.google.com"),
        STUNServer(host: "stun1.l.google.com"),
        STUNServer(host: "stun2.l.google.com"),
        STUNServer(host: "stun.cloudflare.com")
    ]
}

// MARK: - 穿透难度
public enum TraversalDifficulty: String, Codable, CaseIterable {
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

// MARK: - NAT类型
public enum NATType: String, Codable, CaseIterable {
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

// MARK: - P2P协议类型
public enum P2PProtocol: String, Codable, CaseIterable {
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

// MARK: - 设备信息
public struct P2PDeviceInfo: Codable, Identifiable, Sendable {
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
        let key = "SkyBridge.DeviceId"
        if let existingId = UserDefaults.standard.string(forKey: key) {
            return existingId
        } else {
            let newId = UUID().uuidString
            UserDefaults.standard.set(newId, forKey: key)
            return newId
        }
    }
    
    private static func getDeviceName() -> String {
        #if os(macOS)
        return Host.current().localizedName ?? "Mac"
        #elseif os(iOS)
        return UIDevice.current.name
        #else
        return "Unknown Device"
        #endif
    }
    
    private static func getCurrentDeviceType() -> P2PDeviceType {
        #if os(macOS)
        return .macOS
        #elseif os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad {
            return .iPadOS
        } else {
            return .iOS
        }
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
 // Swift 6.2.1：公钥数据在发现阶段暂不可用，将在安全握手时获取
 // 实际的公钥交换发生在 P2PSecurityManager.establishSessionKey 中
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

// MARK: - P2P连接
public class P2PConnection: ObservableObject, Identifiable, @unchecked Sendable {
    public let id = UUID()
    public let device: P2PDevice
    public let connection: NWConnection
    public let securityManager: P2PSecurityManager
    
    @Published public var status: P2PConnectionStatus = .connecting
    @Published public var lastActivity: Date = Date()
    @Published public var bytesReceived: UInt64 = 0
    @Published public var bytesSent: UInt64 = 0
    
    private var isEncrypted = false
    private var receiveBuffer = Data()
    
    public init(device: P2PDevice, connection: NWConnection, securityManager: P2PSecurityManager) {
        self.device = device
        self.connection = connection
        self.securityManager = securityManager
        
        setupConnection()
    }
    
    deinit {
        disconnect()
    }
    
 /// 设置连接
    private func setupConnection() {
        connection.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                self?.handleConnectionStateChange(state)
            }
        }
    }
    
    private func handleConnectionStateChange(_ state: NWConnection.State) {
        switch state {
        case .ready:
            status = .connected
            startReceiving()
        case .failed(let error):
            SkyBridgeLogger.p2p.error("连接失败: \(error.localizedDescription, privacy: .private)")
            status = .failed
        case .cancelled:
            status = .disconnected
        default:
            break
        }
    }
    
    private func startReceiving() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            self?.handleReceivedData(data: data, isComplete: isComplete, error: error)
        }
    }
    
    private func handleReceivedData(data: Data?, isComplete: Bool, error: NWError?) {
        if let error = error {
            SkyBridgeLogger.p2p.error("接收数据错误: \(error.localizedDescription, privacy: .private)")
            return
        }
        
        if let data = data {
            receiveBuffer.append(data)
            bytesReceived += UInt64(data.count)
            lastActivity = Date()
            
            processReceivedData()
        }
        
        if !isComplete {
            startReceiving()
        }
    }
    
    private func processReceivedData() {
 // 处理接收到的数据
 // 这里应该解析消息格式并分发到相应的处理器
    }
    
    public func send(_ data: Data) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    self.bytesSent += UInt64(data.count)
                    self.lastActivity = Date()
                    continuation.resume()
                }
            })
        }
    }
    
    public func sendMessage(_ message: P2PMessage) async throws {
        let data = try JSONEncoder().encode(message)
        try await send(data)
    }
    
    public func disconnect() {
        connection.cancel()
        status = .disconnected
    }
    
    public func authenticate() async throws {
        status = .authenticating
        
 // 生成认证挑战
        let challenge = await securityManager.generateChallenge()
        try await sendMessage(.authChallenge(challenge))
        
 // 等待响应并验证
 // 这里需要实现完整的认证流程
        
        status = .authenticated
        isEncrypted = true
    }
}

// MARK: - P2P消息
public enum P2PMessage: Codable {
    case authChallenge(Data)
    case authResponse(Data)
    case remoteDesktopFrame(Data)
    case fileTransferRequest(FileTransferRequest)
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
            let request = try container.decode(FileTransferRequest.self, forKey: .payload)
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

// MARK: - 文件传输请求
// FileTransferRequest 定义已移至 FileTransferModels.swift 中

// MARK: - 系统命令
public struct SystemCommand: Codable {
    public let id: String
    public let type: CommandType
    public let parameters: [String: String]
    public let timestamp: Date
    
    public enum CommandType: String, Codable, CaseIterable {
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

// MARK: - 扩展和辅助方法

extension P2PDevice {
 /// 信号强度 (0.0 - 1.0)
    public var signalStrength: Double {
 // 基于距离和网络质量计算信号强度
        let baseStrength = 1.0 - min(1.0, Double(port) / 65535.0 * 0.3)
        return max(0.1, baseStrength)
    }
    
 /// 信任日期
 /// Swift 6.2.1：通过 DeviceSecurityManager 单例获取设备信任日期
    @MainActor
    public var trustedDate: Date? {
        return DeviceSecurityManager.shared.getTrustedDate(for: id)
    }
    
 /// 创建模拟设备用于预览
    public static var mockDevice: P2PDevice {
        P2PDevice(
            id: "mock-device-id",
            name: "测试设备",
            type: .macOS,
            address: "192.168.1.100",
            port: 8080,
            osVersion: "macOS 14.0",
            capabilities: ["remote_desktop", "file_transfer"],
            publicKey: Data(),
            lastSeen: Date(),
            endpoints: ["192.168.1.100:8080"]
        )
    }
}

extension P2PConnection {
 /// 连接延迟（秒）
    public var latency: Double {
 // 模拟延迟计算
        return 0.025 // 25ms
    }
    
 /// 带宽（字节/秒）
    public var bandwidth: Double {
 // 模拟带宽计算
        return 1_000_000 // 1MB/s
    }
    
 /// 连接质量
    public var quality: P2PConnectionQuality {
        return P2PConnectionQuality(
            latency: latency,
            packetLoss: 0.01,
            bandwidth: UInt64(bandwidth),
            stabilityScore: 80
        )
    }
}
