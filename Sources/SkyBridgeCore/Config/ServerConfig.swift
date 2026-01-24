import Foundation

// MARK: - SkyBridge 服务器配置
/// 集中管理所有服务器地址配置
public enum SkyBridgeServerConfig {

    // MARK: - 生产环境服务器

    /// 主信令服务器地址（走 Cloudflare / Nginx TLS 入口）
    /// 注意：STUN/TURN 不走此域名（Cloudflare 不代理 UDP），仍然直连 EC2 IP。
    public static let signalingServerURL = "https://api.nebula-technologies.net"

    /// WebSocket 信令地址（走 Cloudflare / Nginx TLS 入口）
    public static let signalingWebSocketURL = "wss://api.nebula-technologies.net/ws"

    /// STUN 服务器地址
    public static let stunServerHost = "54.92.79.99"
    public static let stunServerPort: UInt16 = 3478

    /// TURN 服务器配置
    public static let turnServerHost = "54.92.79.99"
    public static let turnServerPort: UInt16 = 3478

    /// TURN 用户名（非敏感；可选覆盖）
    public static var turnUsername: String {
        ProcessInfo.processInfo.environment["SKYBRIDGE_TURN_USERNAME"] ?? "skybridge"
    }

    /// TURN 密码（敏感：只允许通过环境变量注入；仓库中不应硬编码真实值）
    public static var turnPassword: String {
        ProcessInfo.processInfo.environment["SKYBRIDGE_TURN_PASSWORD"] ?? ""
    }

    // MARK: - 服务器 URL 构造

    /// 完整的 STUN URL
    public static var stunURL: String {
        "stun:\(stunServerHost):\(stunServerPort)"
    }

    /// 完整的 TURN URL
    public static var turnURL: String {
        "turn:\(turnServerHost):\(turnServerPort)"
    }

    /// TURN URL（不包含凭据，避免在日志/URL 中泄露密码）
    public static var turnURLRedacted: String {
        "turn:\(turnServerHost):\(turnServerPort)"
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
