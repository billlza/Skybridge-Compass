// MARK: - Widget Push Service
// 通过 APNS 触发 Widget 刷新
// Requirements: 1.3 (v2.2)

import Foundation
import WidgetKit
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Widget Push 更新服务
/// 支持通过 APNS 触发跨设备状态同步
@MainActor
public final class WidgetPushService: ObservableObject {
    
 // MARK: - Singleton
    
    public static let shared = WidgetPushService()
    
 // MARK: - Published State
    
 /// 是否已注册推送
    @Published public private(set) var isRegistered: Bool = false
    
 /// 上次推送刷新时间
    @Published public private(set) var lastPushRefreshTime: Date?
    
 // MARK: - Constants
    
 /// Widget Push 通知类别
    public static let widgetPushCategory = "WIDGET_PUSH_UPDATE"
    
 /// 最小推送刷新间隔（秒）- 避免过于频繁的推送刷新
    private let minPushRefreshInterval: TimeInterval = 60.0
    
 // MARK: - Initialization
    
    private init() {}
    
 // MARK: - Public API
    
 /// 注册 Widget Push 更新
 /// 需要在应用启动时调用
    public func registerForWidgetPush() async {
        #if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()
        
 // 注册 Widget Push 通知类别
        let category = UNNotificationCategory(
            identifier: Self.widgetPushCategory,
            actions: [],
            intentIdentifiers: [],
            options: [.hiddenPreviewsShowTitle]
        )
        
        let existingCategories = await center.notificationCategories()
        var categories = existingCategories
        categories.insert(category)
        center.setNotificationCategories(categories)
        
        isRegistered = true
        SkyBridgeLogger.ui.debugOnly("WidgetPushService: Registered for widget push updates")
        #endif
    }
    
 /// 处理收到的推送通知
 /// - Parameter userInfo: 推送通知的 userInfo
 /// - Returns: 是否成功处理
    @discardableResult
    public func handlePushNotification(userInfo: [AnyHashable: Any]) -> Bool {
 // 检查是否是 Widget Push 通知
        guard let category = userInfo["category"] as? String,
              category == Self.widgetPushCategory else {
            return false
        }
        
 // 检查刷新间隔
        if let lastTime = lastPushRefreshTime,
           Date().timeIntervalSince(lastTime) < minPushRefreshInterval {
            SkyBridgeLogger.ui.debugOnly("WidgetPushService: Push refresh throttled")
            return true
        }
        
 // 解析要刷新的 widget kinds
        let kinds = parseWidgetKinds(from: userInfo)
        
 // 刷新 widgets
        refreshWidgets(kinds: kinds)
        
        lastPushRefreshTime = Date()
        SkyBridgeLogger.ui.debugOnly("WidgetPushService: Handled push notification, refreshed \(kinds.count) widgets")
        
        return true
    }
    
 /// 手动触发 Widget 刷新（用于测试）
    public func triggerManualRefresh(kinds: Set<String>? = nil) {
        let kindsToRefresh = kinds ?? Set([
            WidgetKindConstants.deviceStatus,
            WidgetKindConstants.systemMonitor,
            WidgetKindConstants.fileTransfer
        ])
        
        refreshWidgets(kinds: kindsToRefresh)
        lastPushRefreshTime = Date()
    }
    
 // MARK: - Private Methods
    
 /// 解析推送通知中的 widget kinds
    private func parseWidgetKinds(from userInfo: [AnyHashable: Any]) -> Set<String> {
 // 如果指定了特定的 kinds
        if let kindsArray = userInfo["widget_kinds"] as? [String] {
            return Set(kindsArray)
        }
        
 // 如果指定了 "all"
        if let scope = userInfo["scope"] as? String, scope == "all" {
            return Set([
                WidgetKindConstants.deviceStatus,
                WidgetKindConstants.systemMonitor,
                WidgetKindConstants.fileTransfer
            ])
        }
        
 // 默认刷新设备状态
        return Set([WidgetKindConstants.deviceStatus])
    }
    
 /// 刷新指定的 widgets
    private func refreshWidgets(kinds: Set<String>) {
        for kind in kinds {
            WidgetCenter.shared.reloadTimelines(ofKind: kind)
        }
    }
}

// MARK: - Widget Kind Constants

/// Widget Kind 常量
public enum WidgetKindConstants {
    public static let deviceStatus = "DeviceStatusWidget"
    public static let systemMonitor = "SystemMonitorWidget"
    public static let fileTransfer = "FileTransferWidget"
}

// MARK: - Push Notification Payload Example

/*
 Widget Push 通知 Payload 示例：
 
 {
   "aps": {
     "content-available": 1,
     "category": "WIDGET_PUSH_UPDATE"
   },
   "category": "WIDGET_PUSH_UPDATE",
   "scope": "all",
   "widget_kinds": ["DeviceStatusWidget", "SystemMonitorWidget"]
 }
 
 说明：
 - content-available: 1 表示静默推送
 - category: WIDGET_PUSH_UPDATE 用于识别 Widget Push
 - scope: "all" 刷新所有 widgets
 - widget_kinds: 指定要刷新的 widget 类型
 */

// MARK: - Background Refresh Support

extension WidgetPushService {
    
 /// 处理后台刷新任务
 /// 在 AppDelegate 的 application(_:performFetchWithCompletionHandler:) 中调用
    public func handleBackgroundRefresh() async {
 // 刷新所有 widgets
        triggerManualRefresh()
        
        SkyBridgeLogger.ui.debugOnly("WidgetPushService: Background refresh completed")
    }
    
 /// 请求后台刷新权限
    public func requestBackgroundRefreshCapability() {
 // 注意：后台刷新需要在 Info.plist 中配置 UIBackgroundModes
 // 包含 "fetch" 和 "remote-notification"
        SkyBridgeLogger.ui.debugOnly("WidgetPushService: Background refresh capability requested")
    }
}
