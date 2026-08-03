import Foundation

public enum P2PError: Error, LocalizedError {
    case noIPAddress
    case noConnectableEndpoint
    case noLiveControlRoute
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
    case missingPinnedProtocolIdentity
    case unexpectedAuthenticatedHandshakeFrame
    case authenticatedPongReplyFailed
    case handshakeAlreadyInProgress
    case staleConnectionIncarnation
    case authenticatedIdentityMismatch
    case noAuthenticatedClipboardRecipients
    case invalidClipboardPayload
    case pairingIdentityExchangeUnavailable(reason: String)

    public var errorDescription: String? {
        switch self {
        case .noIPAddress: return "设备没有 IP 地址"
        case .noConnectableEndpoint: return "设备缺少可连接地址（Bonjour/IP）"
        case .noLiveControlRoute: return "当前 Bonjour 浏览周期没有可拨控制路由"
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
        case .missingPinnedProtocolIdentity: return "严格 PQC 需要已固定的协议身份；当前不会自动降级或继续握手"
        case .unexpectedAuthenticatedHandshakeFrame: return "已认证业务通道收到意外的握手控制帧"
        case .authenticatedPongReplyFailed: return "已认证业务通道的 pong 回复发送失败"
        case .handshakeAlreadyInProgress: return "当前连接已有握手或密钥更新正在进行"
        case .staleConnectionIncarnation: return "认证连接已结束或被替换"
        case .authenticatedIdentityMismatch: return "认证连接的协议身份与目标会话不匹配"
        case .noAuthenticatedClipboardRecipients: return "没有可接收剪贴板的已认证设备"
        case .invalidClipboardPayload: return "远端剪贴板载荷无效或超过协议上限"
        case .pairingIdentityExchangeUnavailable(let reason):
            return "无法发送配对身份交换：\(reason)"
        }
    }
}
