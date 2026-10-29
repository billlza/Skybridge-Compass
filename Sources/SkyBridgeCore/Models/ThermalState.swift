// 热状态。定义在此处而不是 ThermalManager（IOKit，macOS 专属）内部，因为共享逻辑
// （QoSManager、WebRTC 远程桌面码率预算/策略）需要它。
//
// 抽取自 Performance/ThermalManager.swift，属于 iOS/SkyBridgeCore 统一化的分层修复：
// 模型类型不应与平台专属实现耦合在同一文件。

import Foundation

/// 热量状态
public enum ThermalState: String, CaseIterable {
    case nominal = "正常"
    case fair = "良好"
    case serious = "严重"
    case critical = "危险"
    
 /// 获取状态颜色
    public var color: String {
        switch self {
        case .nominal:
            return "绿色"
        case .fair:
            return "黄色"
        case .serious:
            return "橙色"
        case .critical:
            return "红色"
        }
    }
}
