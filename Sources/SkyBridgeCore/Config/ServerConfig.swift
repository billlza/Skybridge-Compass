import Foundation

// MARK: - SkyBridge 服务器配置
/// 集中管理所有服务器地址配置
public enum SkyBridgeServerConfig {

    // MARK: - 生产环境服务器

    /// 主信令服务器地址
    public static let signalingServerURL = "https://54.92.79.99:8443"

    /// WebSocket 信令地址
    public static let signalingWebSocketURL = "wss://54.92.79.99:8443/ws"

    /// STUN 服务器地址
    public static let stunServerHost = "54.92.79.99"
    public static let stunServerPort: UInt16 = 3478

    /// TURN 服务器配置
    public static let turnServerHost = "54.92.79.99"
    public static let turnServerPort: UInt16 = 3478
    public static let turnUsername = "skybridge"
    public static let turnPassword = "SkyBridge2026!"

    // MARK: - 服务器 URL 构造

    /// 完整的 STUN URL
    public static var stunURL: String {
        "stun:\(stunServerHost):\(stunServerPort)"
    }

    /// 完整的 TURN URL
    public static var turnURL: String {
        "turn:\(turnServerHost):\(turnServerPort)"
    }

    /// TURN URL (带认证)
    public static var turnURLWithCredentials: String {
        "turn:\(turnUsername):\(turnPassword)@\(turnServerHost):\(turnServerPort)"
    }

    // MARK: - API 端点

    /// 注册连接码
    public static var registerEndpoint: String {
        "\(signalingServerURL)/api/register"
    }

    /// 查找连接码
    public static func lookupEndpoint(code: String) -> String {
        "\(signalingServerURL)/api/lookup/\(code)"
    }

    /// 提交 Answer
    public static func answerEndpoint(code: String) -> String {
        "\(signalingServerURL)/api/answer/\(code)"
    }

    /// ICE 候选人
    public static func iceEndpoint(sessionId: String) -> String {
        "\(signalingServerURL)/api/ice/\(sessionId)"
    }

    /// 健康检查
    public static var healthEndpoint: String {
        "\(signalingServerURL)/health"
    }
}
