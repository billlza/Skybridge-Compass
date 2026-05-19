import Foundation

public enum P2PError: Error, LocalizedError {
    case noIPAddress
    case noConnectableEndpoint
    case noData
    case handshakeFailed
    case connectionFailed
    case noSessionKey
    case encryptionFailed
    case decryptionFailed
    case tooManyConcurrentConnections
    case alreadyConnected
    case selfConnectionBlocked
    case pqcRequiredUnavailable

    public var errorDescription: String? {
        switch self {
        case .noIPAddress: return "设备没有 IP 地址"
        case .noConnectableEndpoint: return "设备缺少可连接地址（Bonjour/IP）"
        case .noData: return "没有接收到数据"
        case .handshakeFailed: return "PQC 握手失败"
        case .connectionFailed: return "连接失败"
        case .noSessionKey: return "没有会话密钥"
        case .encryptionFailed: return "加密失败"
        case .decryptionFailed: return "解密失败"
        case .tooManyConcurrentConnections: return "连接过于频繁，请稍后再试（已达到并发上限）"
        case .alreadyConnected: return "设备已建立连接"
        case .selfConnectionBlocked: return "已阻止自连接目标"
        case .pqcRequiredUnavailable: return "严格 PQC 已启用，但当前构建/设备不具备 PQC 能力；已拒绝自动降级到 Classic"
        }
    }
}
