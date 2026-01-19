import Foundation
import Network

// MARK: - STUN服务器配置
public struct P2PSTUNServer: Codable, Sendable {
 /// 服务器主机名
    public let host: String
 /// 服务器端口
    public let port: UInt16
    
    public init(host: String, port: UInt16 = 3478) {
        self.host = host
        self.port = port
    }
    
 /// 默认STUN服务器列表
    public static let defaultServers: [P2PSTUNServer] = [
        // SkyBridge 自建服务器 (首选)
        P2PSTUNServer(host: "54.92.79.99", port: 3478),
        // 公共备用服务器
        P2PSTUNServer(host: "stun.l.google.com", port: 19302),
        P2PSTUNServer(host: "stun1.l.google.com", port: 19302),
        P2PSTUNServer(host: "stun.cloudflare.com", port: 3478)
    ]
}

// MARK: - 穿透难度
public enum P2PTraversalDifficulty: String, Codable, CaseIterable, Sendable {
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
public enum P2PNATType: String, Codable, CaseIterable, Sendable {
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
    
    public var traversalDifficulty: P2PTraversalDifficulty {
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
public enum P2PNetworkProtocol: String, Codable, CaseIterable, Sendable {
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

// MARK: - P2P网络配置
public struct P2PNetworkConfiguration: Codable, Sendable {
 /// 监听端口
    public let listenPort: UInt16
 /// 使用的协议
    public let networkProtocol: P2PNetworkProtocol
 /// STUN服务器列表
    public let stunServers: [P2PSTUNServer]
 /// 连接超时时间（秒）
    public let connectionTimeout: TimeInterval
 /// 心跳间隔（秒）
    public let heartbeatInterval: TimeInterval
 /// 最大重试次数
    public let maxRetryCount: Int
    
    public init(
        listenPort: UInt16 = 8080,
        networkProtocol: P2PNetworkProtocol = .udp,
        stunServers: [P2PSTUNServer] = P2PSTUNServer.defaultServers,
        connectionTimeout: TimeInterval = 30.0,
        heartbeatInterval: TimeInterval = 10.0,
        maxRetryCount: Int = 3
    ) {
        self.listenPort = listenPort
        self.networkProtocol = networkProtocol
        self.stunServers = stunServers
        self.connectionTimeout = connectionTimeout
        self.heartbeatInterval = heartbeatInterval
        self.maxRetryCount = maxRetryCount
    }
    
 /// 默认配置
    public static let defaultConfiguration = P2PNetworkConfiguration()
}

// MARK: - NAT检测结果
public struct NATDetectionResult: Codable, Sendable {
 /// NAT类型
    public let natType: P2PNATType
 /// 公网IP地址
    public let publicIP: String?
 /// 公网端口
    public let publicPort: UInt16?
 /// 检测时间戳
    public let timestamp: Date
 /// 检测耗时（毫秒）
    public let detectionTime: TimeInterval
    
    public init(
        natType: P2PNATType,
        publicIP: String? = nil,
        publicPort: UInt16? = nil,
        timestamp: Date = Date(),
        detectionTime: TimeInterval = 0
    ) {
        self.natType = natType
        self.publicIP = publicIP
        self.publicPort = publicPort
        self.timestamp = timestamp
        self.detectionTime = detectionTime
    }
    
 /// 是否支持P2P连接
    public var supportsP2P: Bool {
        return natType != .symmetric && natType != .unknown
    }
    
 /// 连接成功率预估
    public var connectionSuccessRate: Double {
        switch natType.traversalDifficulty {
        case .easy: return 0.95
        case .medium: return 0.75
        case .hard: return 0.35
        case .unknown: return 0.10
        }
    }
}

// MARK: - 网络连接状态
public enum P2PNetworkState: String, Codable, CaseIterable, Sendable {
    case idle = "idle"
    case discovering = "discovering"
    case connecting = "connecting"
    case connected = "connected"
    case disconnected = "disconnected"
    case error = "error"
    
    public var displayName: String {
        switch self {
        case .idle: return "空闲"
        case .discovering: return "发现中"
        case .connecting: return "连接中"
        case .connected: return "已连接"
        case .disconnected: return "已断开"
        case .error: return "错误"
        }
    }
    
    public var isActive: Bool {
        return self == .discovering || self == .connecting || self == .connected
    }
}

// MARK: - 连接质量指标
public struct P2PConnectionQuality: Codable, Sendable {
 /// 延迟（毫秒）
    public let latency: TimeInterval
 /// 丢包率（0-1）
    public let packetLoss: Double
 /// 带宽（字节/秒）
    public let bandwidth: UInt64
 /// 连接稳定性评分（0-100）
    public let stabilityScore: Int
 /// 测量时间戳
    public let timestamp: Date
    
    public init(
        latency: TimeInterval,
        packetLoss: Double,
        bandwidth: UInt64,
        stabilityScore: Int,
        timestamp: Date = Date()
    ) {
        self.latency = latency
        self.packetLoss = packetLoss
        self.bandwidth = bandwidth
        self.stabilityScore = stabilityScore
        self.timestamp = timestamp
    }
    
 /// 连接质量等级
    public var qualityLevel: ConnectionQualityLevel {
        if stabilityScore >= 80 && latency < 50 && packetLoss < 0.01 {
            return .excellent
        } else if stabilityScore >= 60 && latency < 100 && packetLoss < 0.05 {
            return .good
        } else if stabilityScore >= 40 && latency < 200 && packetLoss < 0.10 {
            return .fair
        } else {
            return .poor
        }
    }
}

// MARK: - 连接质量等级
public enum ConnectionQualityLevel: String, Codable, CaseIterable, Sendable {
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

// MARK: - 网络质量等级（用于P2PNetworkLayer）
public enum NetworkQualityLevel: String, Codable, CaseIterable, Sendable {
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
}

// MARK: - P2P网络统计信息
public struct P2PNetworkStatistics: Codable, Sendable {
 /// 活跃连接数
    public let activeConnections: Int
 /// 总接收字节数
    public let totalBytesReceived: UInt64
 /// 总发送字节数
    public let totalBytesSent: UInt64
 /// 总接收包数
    public let totalPacketsReceived: UInt64
 /// 总发送包数
    public let totalPacketsSent: UInt64
 /// 平均延迟（秒）
    public let averageLatency: TimeInterval
 /// 连接正常运行时间（秒）
    public let connectionUptime: TimeInterval
 /// 最后更新时间
    public let lastUpdated: Date
    
    public init(
        activeConnections: Int = 0,
        totalBytesReceived: UInt64 = 0,
        totalBytesSent: UInt64 = 0,
        totalPacketsReceived: UInt64 = 0,
        totalPacketsSent: UInt64 = 0,
        averageLatency: TimeInterval = 0,
        connectionUptime: TimeInterval = 0,
        lastUpdated: Date = Date()
    ) {
        self.activeConnections = activeConnections
        self.totalBytesReceived = totalBytesReceived
        self.totalBytesSent = totalBytesSent
        self.totalPacketsReceived = totalPacketsReceived
        self.totalPacketsSent = totalPacketsSent
        self.averageLatency = averageLatency
        self.connectionUptime = connectionUptime
        self.lastUpdated = lastUpdated
    }
}

// MARK: - P2P网络质量信息
public struct P2PNetworkQuality: Codable, Sendable {
 /// 延迟（秒）
    public let latency: TimeInterval
 /// 带宽（字节/秒）
    public let bandwidth: UInt64
 /// 丢包率（0-1）
    public let packetLoss: Double
 /// 抖动（秒）
    public let jitter: TimeInterval
 /// 质量等级
    public let quality: NetworkQualityLevel
 /// 测量时间戳
    public let timestamp: Date
    
    public init(
        latency: TimeInterval,
        bandwidth: UInt64,
        packetLoss: Double,
        jitter: TimeInterval,
        quality: NetworkQualityLevel,
        timestamp: Date = Date()
    ) {
        self.latency = latency
        self.bandwidth = bandwidth
        self.packetLoss = packetLoss
        self.jitter = jitter
        self.quality = quality
        self.timestamp = timestamp
    }
}

// MARK: - P2P连接指标

/// P2P连接指标 - 用于监控连接质量
public struct P2PConnectionMetrics: Codable, Sendable {
    /// 延迟（毫秒）
    public let latencyMs: Double
    /// 带宽（Mbps）
    public let bandwidthMbps: Double
    /// 丢包率（百分比）
    public let packetLossPercent: Double
    /// 加密模式
    public let encryptionMode: String
    /// 协议版本
    public let protocolVersion: String
    /// 对端能力
    public let peerCapabilities: [String]
    /// 是否启用后量子加密
    public let pqcEnabled: Bool

    public init(
        latencyMs: Double,
        bandwidthMbps: Double,
        packetLossPercent: Double,
        encryptionMode: String = "AES-256-GCM",
        protocolVersion: String = "1.0",
        peerCapabilities: [String] = [],
        pqcEnabled: Bool = false
    ) {
        self.latencyMs = latencyMs
        self.bandwidthMbps = bandwidthMbps
        self.packetLossPercent = packetLossPercent
        self.encryptionMode = encryptionMode
        self.protocolVersion = protocolVersion
        self.peerCapabilities = peerCapabilities
        self.pqcEnabled = pqcEnabled
    }
}

// MARK: - P2P视频编解码器类型

/// P2P视频编解码器
public enum P2PVideoCodec: String, Codable, CaseIterable, Sendable {
    case h264 = "H.264"
    case h265 = "H.265"
    case vp9 = "VP9"
    case av1 = "AV1"

    public var displayName: String {
        return rawValue
    }
}

// MARK: - P2P屏幕镜像配置

/// P2P屏幕镜像配置
public struct P2PScreenMirrorConfig: Sendable {
    /// 目标宽度
    public let targetWidth: Int
    /// 目标高度
    public let targetHeight: Int
    /// 目标帧率
    public let targetFPS: Int
    /// 目标比特率（bps）
    public let targetBitrate: Int
    /// 编解码器
    public let codec: P2PVideoCodec
    /// 是否使用硬件编码器
    public let useHardwareEncoder: Bool

    public init(
        targetWidth: Int = 1920,
        targetHeight: Int = 1080,
        targetFPS: Int = 60,
        targetBitrate: Int = 5_000_000,
        codec: P2PVideoCodec = .h264,
        useHardwareEncoder: Bool = true
    ) {
        self.targetWidth = targetWidth
        self.targetHeight = targetHeight
        self.targetFPS = targetFPS
        self.targetBitrate = targetBitrate
        self.codec = codec
        self.useHardwareEncoder = useHardwareEncoder
    }

    /// 默认配置
    public static let defaultConfig = P2PScreenMirrorConfig()

    /// 低延迟配置
    public static let lowLatencyConfig = P2PScreenMirrorConfig(
        targetWidth: 1280,
        targetHeight: 720,
        targetFPS: 60,
        targetBitrate: 2_500_000,
        codec: .h264,
        useHardwareEncoder: true
    )

    /// 高质量配置
    public static let highQualityConfig = P2PScreenMirrorConfig(
        targetWidth: 2560,
        targetHeight: 1440,
        targetFPS: 60,
        targetBitrate: 15_000_000,
        codec: .h265,
        useHardwareEncoder: true
    )
}

// MARK: - P2P协商加密配置

/// P2P协商后的加密配置
public struct P2PNegotiatedCryptoProfile: Codable, Sendable, Equatable {
    /// 密钥交换算法
    public let keyExchangeAlgorithm: String
    /// 对称加密算法
    public let symmetricCipher: String
    /// 哈希算法
    public let hashAlgorithm: String
    /// 是否启用后量子加密
    public let pqcEnabled: Bool
    /// 协商时间戳（毫秒）
    public let negotiatedAtMillis: Int64

    public init(
        keyExchangeAlgorithm: String = "X25519",
        symmetricCipher: String = "AES-256-GCM",
        hashAlgorithm: String = "SHA-256",
        pqcEnabled: Bool = false,
        negotiatedAtMillis: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        self.keyExchangeAlgorithm = keyExchangeAlgorithm
        self.symmetricCipher = symmetricCipher
        self.hashAlgorithm = hashAlgorithm
        self.pqcEnabled = pqcEnabled
        self.negotiatedAtMillis = negotiatedAtMillis
    }

    /// 默认配置（经典加密）
    public static let defaultProfile = P2PNegotiatedCryptoProfile()

    /// 后量子加密配置
    public static let pqcProfile = P2PNegotiatedCryptoProfile(
        keyExchangeAlgorithm: "ML-KEM-768",
        symmetricCipher: "AES-256-GCM",
        hashAlgorithm: "SHA-256",
        pqcEnabled: true
    )
}