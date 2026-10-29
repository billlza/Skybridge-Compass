import Foundation

/// 心跳/账号设备列表失败的分类（macOS `PresenceService` 与 iOS `AccountPresenceService` 共用）。
public enum AccountPresenceFailure: Sendable, Equatable {
    /// 未登录或会话不可用：不重试，等认证状态变化。
    case notAuthenticated
    /// 本机在注册表里不是 active（device_not_registered / device_not_active / device_frozen / device_revoked）。
    case deviceNotActive(code: String)
    case rateLimited
    /// 注册表不可用或 schema 落后（registry_not_configured / registry_schema_outdated / registry_unavailable）。
    case registryUnavailable(code: String)
    case serverRejected(status: Int, code: String?)
    case transport
    case malformedResponse
    /// 本机协议身份尚未就绪（例如首启未完成身份 authority 恢复）：等身份就绪，不算网络故障。
    case localIdentityUnavailable
    /// 本机认证状态不可用：钥匙串读取失败、会话声明自相矛盾等。**不是**"未登录"，
    /// UI 必须显示为错误而不是登录引导，否则一次本地存储故障会被当成用户没登录。
    case localAuthenticationUnavailable(code: String)
}

/// 各平台客户端在调用信令 API 前发现本机身份不可用时抛出的类型化错误。
public enum AccountPresenceClientError: Error, Equatable, Sendable {
    case localIdentityUnavailable(underlying: String)
}

/// 刷新节奏与退避规则（纯函数）。
public enum AccountPresenceRefreshPolicy {
    /// 正常心跳间隔（与服务端 90s TTL 配合：两次心跳丢失才会显示离线）。
    public static let heartbeatInterval: TimeInterval = 30
    public static let maximumBackoff: TimeInterval = 300
    /// 在线状态快照的有效期：超过后即使没有新结果也要视为失效（fail closed）。
    public static let snapshotTTL: TimeInterval = 90

    private static let deviceNotActiveCodes: Set<String> = [
        "device_not_registered", "device_not_active", "device_frozen", "device_revoked"
    ]
    private static let registryCodes: Set<String> = [
        "registry_not_configured", "registry_schema_outdated", "registry_unavailable"
    ]

    /// 把 HTTP 状态 + 服务端错误码归类为可决策的失败类型。
    public static func classify(status: Int, code: String?) -> AccountPresenceFailure {
        let normalizedCode = code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let normalizedCode, deviceNotActiveCodes.contains(normalizedCode) {
            return .deviceNotActive(code: normalizedCode)
        }
        if let normalizedCode, registryCodes.contains(normalizedCode) {
            return .registryUnavailable(code: normalizedCode)
        }
        switch status {
        case 401:
            return .notAuthenticated
        case 429:
            return .rateLimited
        default:
            return .serverRejected(status: status, code: normalizedCode)
        }
    }

    /// 下一次尝试前的等待时间。`consecutiveFailures` 从 1 开始计。
    public static func retryDelay(after failure: AccountPresenceFailure, consecutiveFailures: Int) -> TimeInterval {
        let attempts = max(1, consecutiveFailures)
        let exponential = min(maximumBackoff, heartbeatInterval * pow(2, Double(min(attempts - 1, 6))))
        switch failure {
        case .notAuthenticated, .localIdentityUnavailable:
            return 60
        case .localAuthenticationUnavailable:
            // 本地状态故障不会因为快速重试而好转，但也不该完全停下：用最长退避。
            return maximumBackoff
        case .deviceNotActive:
            return maximumBackoff
        case .rateLimited:
            return max(60, exponential)
        case .registryUnavailable, .transport, .malformedResponse:
            return exponential
        case .serverRejected(let status, _):
            return status >= 500 ? exponential : max(60, exponential)
        }
    }

    /// 失败后是否应保留上一次成功的快照（只要未超过 TTL）。
    /// 轮询循环的下一次唤醒间隔：既不能晚于下一次刷新，也不能晚于在线状态到期（到期必须及时失效，
    /// 即使刷新正处于长退避中）。`untilOnlineStateExpires == nil` 表示当前没有任何在线状态需要失效。
    public static func loopSleepInterval(untilRefresh: TimeInterval, untilOnlineStateExpires: TimeInterval?) -> TimeInterval {
        let bounded = max(0, untilRefresh)
        guard let untilOnlineStateExpires else { return bounded }
        return min(bounded, max(0, untilOnlineStateExpires))
    }

    public static func isSnapshotStale(lastSuccessAt: Date?, now: Date, ttl: TimeInterval = snapshotTTL) -> Bool {
        guard let lastSuccessAt else { return true }
        let age = now.timeIntervalSince(lastSuccessAt)
        // 时钟回拨不能成为"仍然在线"的证据：一律视为失效。
        return !(age >= 0 && age < ttl)
    }
}
