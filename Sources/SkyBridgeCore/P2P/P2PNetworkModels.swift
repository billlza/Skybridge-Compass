import Foundation

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
        // SkyBridge 自建服务器 (首选)
        STUNServer(host: "54.92.79.99", port: 3478),
        // 公共备用服务器
        STUNServer(host: "stun.l.google.com", port: 19302),
        STUNServer(host: "stun1.l.google.com", port: 19302),
        STUNServer(host: "stun.cloudflare.com", port: 3478)
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
