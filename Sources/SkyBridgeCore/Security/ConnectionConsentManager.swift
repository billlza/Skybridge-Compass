import Foundation
import OSLog

/// 连接授权中心：统一管理“是否允许建立连接”的决策
/// - 设计目标：默认拒绝陌生设备；仅在用户操作或已建立信任关系时放行
@MainActor
public final class ConnectionConsentManager {
    
    public static let shared = ConnectionConsentManager()
    
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "Consent")
    
 /// 简化的信任表与封禁表（持久化可后续扩展）
    private var trustedDeviceIds: Set<String> = []
    private var blockedDeviceIds: Set<String> = []
    
    private init() {}
    
 /// 记录用户决策
    public func recordDecision(deviceId: String, allow: Bool, remember: Bool) {
        if allow {
            if remember { trustedDeviceIds.insert(deviceId) }
            blockedDeviceIds.remove(deviceId)
        } else {
            if remember { blockedDeviceIds.insert(deviceId) }
            trustedDeviceIds.remove(deviceId)
        }
        logger.info("Consent updated: id=\(deviceId, privacy: .public) allow=\(allow) remember=\(remember)")
    }
    
 /// 是否可以主动发起连接（出站）
    public func canInitiate(to deviceId: String) -> Bool {
        if blockedDeviceIds.contains(deviceId) { return false }
        if SettingsManager.shared.requireAuthorizationForConnection {
            return trustedDeviceIds.contains(deviceId)
        }
        return true
    }
    
 /// 查询是否可信（用于 UI 展示）
    public func isTrusted(deviceId: String) -> Bool {
        trustedDeviceIds.contains(deviceId)
    }
}


