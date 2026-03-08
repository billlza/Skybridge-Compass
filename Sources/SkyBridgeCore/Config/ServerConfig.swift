import Foundation

// MARK: - SkyBridge 服务器配置
/// 集中管理所有服务器地址配置
public enum SkyBridgeServerConfig {

    private static func environmentValue(_ name: String) -> String? {
        guard let raw = ProcessInfo.processInfo.environment[name] else { return nil }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func environmentValue(_ name: String, default defaultValue: String) -> String {
        guard let value = environmentValue(name), !value.isEmpty else { return defaultValue }
        return value
    }

    private static func environmentList(_ name: String, default defaultValue: [String]) -> [String] {
        guard let raw = ProcessInfo.processInfo.environment[name] else {
            return defaultValue
        }
        return raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - 生产环境服务器

    /// 主信令服务器地址（走 Cloudflare / Nginx TLS 入口）
    /// 注意：STUN/TURN 不走此域名（Cloudflare 不代理 UDP），仍然直连 EC2 IP。
    public static var signalingServerURL: String {
        environmentValue("SKYBRIDGE_SIGNALING_SERVER_URL", default: "https://api.nebula-technologies.net")
    }

    /// WebSocket 信令地址（走 Cloudflare / Nginx TLS 入口）
    public static var signalingWebSocketURL: String {
        environmentValue("SKYBRIDGE_SIGNALING_WEBSOCKET_URL", default: "wss://api.nebula-technologies.net/ws")
    }

    /// STUN 服务器地址
    public static let stunServerHost = "54.92.79.99"
    public static let stunServerPort: UInt16 = 3478

    /// TURN 服务器配置
    public static let turnServerHost = "54.92.79.99"
    public static let turnServerPort: UInt16 = 3478
    public static let turnTLSServerPort: UInt16 = 5349

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
        environmentValue("SKYBRIDGE_STUN_URL", default: "stun:\(stunServerHost):\(stunServerPort)")
    }

    /// 完整的 TURN URL
    public static var turnURL: String {
        environmentValue("SKYBRIDGE_TURN_URL", default: "turn:\(turnServerHost):\(turnServerPort)?transport=udp")
    }

    /// 优先使用的 TURN over TLS URL（5349/TCP）
    public static var turnTLSURL: String {
        environmentValue("SKYBRIDGE_TURN_TLS_URL", default: "turns:\(turnServerHost):\(turnTLSServerPort)?transport=tcp")
    }

    /// 推荐的 TURN URL 列表（按优先级排序：TLS → UDP）
    public static var turnURLs: [String] {
        environmentList("SKYBRIDGE_TURN_URLS", default: [turnTLSURL, turnURL])
    }

    /// TURN URL（不包含凭据，避免在日志/URL 中泄露密码）
    public static var turnURLRedacted: String {
        turnURLs.first ?? environmentValue("SKYBRIDGE_TURN_URL_REDACTED", default: "turn:\(turnServerHost):\(turnServerPort)")
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
