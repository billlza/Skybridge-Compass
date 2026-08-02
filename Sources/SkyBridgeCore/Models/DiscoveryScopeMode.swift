// 发现范围模式。抽取自 DeviceDiscovery/UnifiedDeviceDiscoveryManager.swift（macOS 侧发现编排），
// 因为共享的 DeviceFilterManager 过滤逻辑引用它。
//
// 属于 iOS/SkyBridgeCore 统一化的分层修复：模型类型不应与平台专属实现耦合在同一文件。

import Foundation

/// 设备发现范围模式
///
/// 控制设备扫描和过滤的行为：
/// - skyBridgeOnly: 只关注 SkyBridge 对端设备（优化性能，减少网络负载）
/// - generalDevices: 扫描局域网设备，但 UI 默认隐藏打印机/摄像头等外设
/// - fullCompatible: 完全兼容模式，显示所有设备类型
public enum DiscoveryScopeMode: String, Codable, Sendable {
    case skyBridgeOnly = "仅 SkyBridge"
    case generalDevices = "常规设备"
    case fullCompatible = "完全兼容"
    
 /// 用户友好的描述
    public var description: String {
        switch self {
        case .skyBridgeOnly:
            return "只显示 SkyBridge 对端设备，性能最优"
        case .generalDevices:
            return "显示电脑、手机等常规设备，隐藏打印机和摄像头"
        case .fullCompatible:
            return "显示所有设备类型，包括打印机、摄像头和 IoT 设备"
        }
    }
}
