// 权限状态。定义在此处而不是 DevicePermissionManager（AppKit/CoreWLAN，macOS 专属）内部，
// 因为 DiscoveryDiagnosticsService 等共享诊断路径引用它。
//
// 抽取自 Device/DevicePermissionManager.swift，属于 iOS/SkyBridgeCore 统一化的分层修复：
// 模型类型不应与平台专属实现耦合在同一文件。

import Foundation

/// 权限状态枚举
public enum PermissionStatus: String, Sendable {
    case notDetermined = "未确定"
    case denied = "已拒绝"
    case authorized = "已授权"
    case restricted = "受限制"
    case unavailable = "不可用"
    
    public var isAuthorized: Bool {
        return self == .authorized
    }
    
    public var color: String {
        switch self {
        case .authorized:
            return "green"
        case .denied, .restricted:
            return "red"
        case .notDetermined:
            return "orange"
        case .unavailable:
            return "gray"
        }
    }
}
