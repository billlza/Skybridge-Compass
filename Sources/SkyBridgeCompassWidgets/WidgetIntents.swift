// MARK: - Widget App Intents
// Interactive Widget 支持 - macOS 14+
// Requirements: 2.1, 2.2

import AppIntents
import WidgetKit
import SwiftUI

// MARK: - Scan Devices Intent

/// 扫描设备 Intent - 在后台触发设备发现
@available(macOS 14.0, *)
struct ScanDevicesIntent: AppIntent {
    static let title: LocalizedStringResource = "扫描设备"
    static let description = IntentDescription("扫描局域网内的设备")
    
 /// 是否在锁屏时可用
    static let isDiscoverable: Bool = true
    
 /// 执行 Intent
    func perform() async throws -> some IntentResult {
 // 发送通知触发主应用扫描
        await MainActor.run {
            NotificationCenter.default.post(
                name: .widgetIntentScanDevices,
                object: nil
            )
        }
        
 // 刷新 widget
        WidgetCenter.shared.reloadTimelines(ofKind: "DeviceStatusWidget")
        
        return .result()
    }
}

// MARK: - Open App Intent

/// 打开应用 Intent
@available(macOS 14.0, *)
struct OpenAppIntent: AppIntent {
    static let title: LocalizedStringResource = "打开应用"
    static let description = IntentDescription("打开 SkyBridge Compass 主应用")
    
    static let openAppWhenRun: Bool = true
    
    func perform() async throws -> some IntentResult {
        return .result()
    }
}

// MARK: - Open Device Detail Intent

/// 打开设备详情 Intent
@available(macOS 14.0, *)
struct OpenDeviceDetailIntent: AppIntent {
    static let title: LocalizedStringResource = "查看设备详情"
    static let description = IntentDescription("打开指定设备的详情页面")
    
    static let openAppWhenRun: Bool = true
    
    @Parameter(title: "设备 ID")
    var deviceId: String
    
    init() {
        self.deviceId = ""
    }
    
    init(deviceId: String) {
        self.deviceId = deviceId
    }
    
    func perform() async throws -> some IntentResult {
 // 发送通知导航到设备详情
        await MainActor.run {
            NotificationCenter.default.post(
                name: .widgetIntentOpenDeviceDetail,
                object: nil,
                userInfo: ["deviceId": deviceId]
            )
        }
        return .result()
    }
}

// MARK: - Open Monitor Intent

/// 打开系统监控 Intent
@available(macOS 14.0, *)
struct OpenMonitorIntent: AppIntent {
    static let title: LocalizedStringResource = "打开系统监控"
    static let description = IntentDescription("打开系统监控页面")
    
    static let openAppWhenRun: Bool = true
    
    func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(
                name: .widgetIntentOpenMonitor,
                object: nil
            )
        }
        return .result()
    }
}

// MARK: - Open Transfers Intent

/// 打开文件传输 Intent
@available(macOS 14.0, *)
struct OpenTransfersIntent: AppIntent {
    static let title: LocalizedStringResource = "打开文件传输"
    static let description = IntentDescription("打开文件传输页面")
    
    static let openAppWhenRun: Bool = true
    
    func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(
                name: .widgetIntentOpenTransfers,
                object: nil
            )
        }
        return .result()
    }
}

// MARK: - Refresh Widget Intent

/// 刷新 Widget Intent - 手动触发刷新
@available(macOS 14.0, *)
struct RefreshWidgetIntent: AppIntent {
    static let title: LocalizedStringResource = "刷新"
    static let description = IntentDescription("刷新小组件数据")
    
    @Parameter(title: "Widget 类型")
    var widgetKind: String
    
    init() {
        self.widgetKind = "DeviceStatusWidget"
    }
    
    init(widgetKind: String) {
        self.widgetKind = widgetKind
    }
    
    func perform() async throws -> some IntentResult {
 // 刷新指定的 widget
        WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
        return .result()
    }
}

// MARK: - Notification Names

public extension Notification.Name {
 /// Widget Intent: 扫描设备
    static let widgetIntentScanDevices = Notification.Name("widgetIntentScanDevices")
    
 /// Widget Intent: 打开设备详情
    static let widgetIntentOpenDeviceDetail = Notification.Name("widgetIntentOpenDeviceDetail")
    
 /// Widget Intent: 打开系统监控
    static let widgetIntentOpenMonitor = Notification.Name("widgetIntentOpenMonitor")
    
 /// Widget Intent: 打开文件传输
    static let widgetIntentOpenTransfers = Notification.Name("widgetIntentOpenTransfers")
}

// MARK: - Intent Button Views

/// 扫描按钮视图（使用 AppIntent）
@available(macOS 14.0, *)
struct ScanDevicesButton: View {
    var body: some View {
        Button(intent: ScanDevicesIntent()) {
            Label("扫描设备", systemImage: "antenna.radiowaves.left.and.right")
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(8)
                .background(.blue.opacity(0.2))
                .foregroundStyle(.blue)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// 打开应用按钮视图（使用 AppIntent）
@available(macOS 14.0, *)
struct OpenAppButton: View {
    var body: some View {
        Button(intent: OpenAppIntent()) {
            Label("打开应用", systemImage: "arrow.up.forward.app")
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(8)
                .background(.secondary.opacity(0.2))
                .foregroundStyle(.primary)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// 刷新按钮视图（使用 AppIntent）
@available(macOS 14.0, *)
struct RefreshWidgetButton: View {
    let widgetKind: String
    
    var body: some View {
        Button(intent: RefreshWidgetIntent(widgetKind: widgetKind)) {
            Image(systemName: "arrow.clockwise")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }
}
