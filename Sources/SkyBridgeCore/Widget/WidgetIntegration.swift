// MARK: - Widget Integration
// 将 Widget 数据服务集成到主应用的各个组件
// Requirements: 1.3, 3.4, 4.2

import Foundation
import SkyBridgeWidgetShared

// MARK: - DiscoveredDevice → WidgetDeviceInfo 转换

@available(macOS 14.0, *)
extension DiscoveredDevice {
 /// 转换为 Widget 设备信息
    public func toWidgetInfo() -> WidgetDeviceInfo {
        WidgetDeviceInfo(
            id: id.uuidString,
            name: name,
            deviceType: inferDeviceType(),
            isOnline: true,  // 发现的设备默认在线
            lastSeen: Date(),
            ipAddress: ipv4 ?? ipv6
        )
    }
    
    private func inferDeviceType() -> WidgetDeviceType {
 // 根据服务和名称推断设备类型
        let nameLower = name.lowercased()
        let servicesLower = services.joined(separator: " ").lowercased()
        let combined = nameLower + " " + servicesLower
        
        if combined.contains("mac") || combined.contains("macos") || combined.contains("macbook") || combined.contains("imac") {
            return .mac
        } else if combined.contains("iphone") {
            return .iphone
        } else if combined.contains("ipad") {
            return .ipad
        } else if combined.contains("windows") || combined.contains("win") {
            return .windows
        } else if combined.contains("android") {
            return .android
        } else if combined.contains("linux") || combined.contains("ubuntu") || combined.contains("debian") {
            return .linux
        } else {
            return .unknown
        }
    }
}

// MARK: - Widget Update Helper

/// Widget 更新助手
/// 提供便捷方法将应用数据同步到 Widget
@available(macOS 14.0, *)
@MainActor
public enum WidgetUpdateHelper {
    
 /// 更新设备状态到 Widget
 /// - Parameters:
 /// - devices: 发现的设备列表
 /// - reason: 更新原因
    public static func updateDevices(
        _ devices: [DiscoveredDevice],
        reason: WidgetUpdateReason = .deviceStatusChanged
    ) {
        let widgetDevices = devices.map { $0.toWidgetInfo() }
        WidgetDataService.shared.updateDevices(widgetDevices, reason: reason)
    }
    
 /// 更新系统指标到 Widget
 /// - Parameters:
 /// - cpuUsage: CPU 使用率 (0-100)
 /// - memoryUsage: 内存使用率 (0-100)
 /// - networkUpload: 网络上传速度 (bytes/s)
 /// - networkDownload: 网络下载速度 (bytes/s)
    public static func updateMetrics(
        cpuUsage: Double,
        memoryUsage: Double,
        networkUpload: Double,
        networkDownload: Double
    ) {
        let metrics = WidgetSystemMetrics(
            cpuUsage: cpuUsage,
            memoryUsage: memoryUsage,
            networkUpload: networkUpload,
            networkDownload: networkDownload
        )
        WidgetDataService.shared.updateMetrics(metrics, reason: .metricsTick)
    }
    
 /// 更新文件传输状态到 Widget
 /// - Parameters:
 /// - transfers: 传输信息列表
 /// - reason: 更新原因
    public static func updateTransfers(
        _ transfers: [WidgetTransferInfo],
        reason: WidgetUpdateReason = .transferProgress
    ) {
        WidgetDataService.shared.updateTransfers(transfers, reason: reason)
    }
    
 /// 应用启动时初始化 Widget 数据
    public static func initializeOnAppLaunch() {
 // 写入空数据以确保 Widget 有初始状态
        WidgetDataService.shared.updateDevices([], reason: .appLaunch)
        WidgetDataService.shared.updateMetrics(.empty, reason: .appLaunch)
        WidgetDataService.shared.updateTransfers([], reason: .appLaunch)
    }
}

// MARK: - DeviceDiscoveryService Widget Integration

@available(macOS 14.0, *)
extension DeviceDiscoveryService {
 /// 同步当前设备列表到 Widget
 /// 在设备列表变化时调用此方法
    public func syncToWidget() {
        WidgetUpdateHelper.updateDevices(discoveredDevices, reason: .deviceStatusChanged)
    }
    
 /// 设备上线时更新 Widget
    public func notifyDeviceOnline(_ device: DiscoveredDevice) {
        WidgetUpdateHelper.updateDevices(discoveredDevices, reason: .deviceOnlineStatusChanged)
    }
    
 /// 设备下线时更新 Widget
    public func notifyDeviceOffline(_ device: DiscoveredDevice) {
        WidgetUpdateHelper.updateDevices(discoveredDevices, reason: .deviceOnlineStatusChanged)
    }
}
