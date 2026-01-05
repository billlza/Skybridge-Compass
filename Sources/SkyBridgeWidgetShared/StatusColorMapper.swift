// MARK: - Status Color Mapper
// 状态颜色映射
// Requirements: 7.5

import Foundation

/// 状态颜色枚举
public enum StatusColor: String, Sendable {
    case green   // online
    case red     // offline
    case yellow  // warning/stale
    case gray    // unknown
}

/// 状态颜色映射器
public enum StatusColorMapper {
 /// 根据在线状态映射颜色
 /// - Parameter isOnline: 是否在线
 /// - Returns: green 表示在线，red 表示离线
    public static func colorForOnlineStatus(_ isOnline: Bool) -> StatusColor {
        isOnline ? .green : .red
    }
    
 /// 根据数据新鲜度映射颜色
 /// - Parameter isStale: 数据是否过期
 /// - Returns: yellow 表示过期，green 表示新鲜
    public static func colorForStaleness(_ isStale: Bool) -> StatusColor {
        isStale ? .yellow : .green
    }
    
 /// 根据设备信息映射颜色
 /// - Parameter device: 设备信息
 /// - Returns: 对应的状态颜色
    public static func colorForDevice(_ device: WidgetDeviceInfo) -> StatusColor {
        device.isOnline ? .green : .red
    }
}
