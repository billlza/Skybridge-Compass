import Foundation

/// 连接状态枚举 - 符合Swift 6.2.1的Sendable和Codable要求
public enum ConnectionStatus: String, CaseIterable, Codable, Sendable {
    case disconnected = "未连接"
    case connecting = "连接中"
    case connected = "已连接"
    case reconnecting = "重连中"
    case failed = "连接失败"
    case timeout = "连接超时"
    case error = "连接错误"
    
 /// 状态显示名称
    public var displayName: String {
        return rawValue
    }
    
 /// 状态是否为活跃状态
    public var isActive: Bool {
        switch self {
        case .connected:
            return true
        default:
            return false
        }
    }
    
 /// 状态是否为过渡状态
    public var isTransitioning: Bool {
        switch self {
        case .connecting, .reconnecting:
            return true
        default:
            return false
        }
    }
}

// 为连接状态增加容错解码，未知或不匹配的 rawValue 降级为 .disconnected，避免枚举新增导致历史缓存解码失败。
extension ConnectionStatus {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode(String.self)) ?? ""
        self = ConnectionStatus(rawValue: raw) ?? .disconnected
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.rawValue)
    }
}
