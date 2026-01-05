// MARK: - Deep Link Router
// Widget Deep Link 路由处理
// Requirements: 1.4, 2.2, 2.3, 3.5

import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Deep Link 路由目标
public enum DeepLinkDestination: Equatable, Sendable {
    case home
    case devices
    case deviceDetail(deviceId: String)
    case monitor
    case transfers
    case scan
    case nearField
    case crossNetwork
    case settings
    case unknown(path: String)
}

/// Deep Link 路由器
/// 负责解析 skybridge:// URL 并路由到对应目标
@MainActor
public final class DeepLinkRouter: ObservableObject {
    
 // MARK: - Singleton
    
    public static let shared = DeepLinkRouter()
    
 // MARK: - Published State
    
 /// 当前路由目标（供 UI 观察）
    @Published public private(set) var currentDestination: DeepLinkDestination?
    
 /// 待处理的设备 ID（用于设备详情导航）
    @Published public private(set) var pendingDeviceId: String?
    
 // MARK: - Constants
    
    public static let scheme = "skybridge"
    
 // MARK: - Initialization
    
    private init() {}
    
 // MARK: - Public API
    
 /// 处理 Deep Link URL
 /// - Parameter url: 要处理的 URL
 /// - Returns: 解析后的目标，如果 URL 无效则返回 nil
    @discardableResult
    public func handleDeepLink(_ url: URL) -> DeepLinkDestination? {
        guard url.scheme == Self.scheme else {
            SkyBridgeLogger.ui.debugOnly("DeepLinkRouter: Invalid scheme \(url.scheme ?? "nil")")
            return nil
        }
        
        let destination = parseDestination(from: url)
        currentDestination = destination
        
 // 处理特定目标
        switch destination {
        case .deviceDetail(let deviceId):
            pendingDeviceId = deviceId
        default:
            pendingDeviceId = nil
        }
        
        SkyBridgeLogger.ui.debugOnly("DeepLinkRouter: Navigating to \(destination)")
        
 // 执行导航
        performNavigation(to: destination)
        
        return destination
    }
    
 /// 清除当前目标（导航完成后调用）
    public func clearDestination() {
        currentDestination = nil
        pendingDeviceId = nil
    }
    
 // MARK: - URL Parsing
    
 /// 解析 URL 到目标
    private func parseDestination(from url: URL) -> DeepLinkDestination {
        let host = url.host ?? ""
        let pathComponents = url.pathComponents.filter { $0 != "/" }
        
        switch host {
        case "devices":
            if let deviceId = pathComponents.first, !deviceId.isEmpty {
                return .deviceDetail(deviceId: deviceId)
            }
            return .devices
            
        case "monitor":
            return .monitor
            
        case "transfers":
            return .transfers
            
        case "scan":
            return .scan
            
        case "near-field":
            return .nearField
            
        case "cross-network":
            return .crossNetwork
            
        case "settings":
            return .settings
            
        case "", "home":
            return .home
            
        default:
 // 兜底：未知路径回到首页
            SkyBridgeLogger.ui.debugOnly("DeepLinkRouter: Unknown path '\(host)', falling back to home")
            return .unknown(path: host)
        }
    }
    
 // MARK: - Navigation
    
 /// 执行导航到目标
    private func performNavigation(to destination: DeepLinkDestination) {
        #if canImport(AppKit)
 // 激活应用
        NSApp.activate(ignoringOtherApps: true)
        
        switch destination {
        case .home, .devices, .deviceDetail, .monitor, .transfers, .unknown:
 // 打开主窗口
            activateMainWindow()
            
        case .scan:
 // 打开主窗口并触发扫描
            activateMainWindow()
 // 发送扫描通知
            NotificationCenter.default.post(name: .deepLinkTriggerScan, object: nil)
            
        case .nearField:
 // 打开近距镜像窗口
            if let url = URL(string: "skybridge://near-field") {
                NSWorkspace.shared.open(url)
            }
            
        case .crossNetwork:
 // 打开跨网络连接窗口
            if let url = URL(string: "skybridge://cross-network") {
                NSWorkspace.shared.open(url)
            }
            
        case .settings:
 // 打开设置窗口
            if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
                _ = NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            }
        }
        #endif
    }
    
    #if canImport(AppKit)
 /// 激活主窗口
    private func activateMainWindow() {
        if let window = NSApp.windows.first(where: { $0.title.contains("SkyBridge") || $0.isMainWindow }) {
            window.makeKeyAndOrderFront(nil)
        }
    }
    #endif
}

// MARK: - Notification Names

public extension Notification.Name {
 /// Deep Link 触发扫描
    static let deepLinkTriggerScan = Notification.Name("deepLinkTriggerScan")
    
 /// Deep Link 导航到设备详情
    static let deepLinkNavigateToDevice = Notification.Name("deepLinkNavigateToDevice")
    
 /// Deep Link 导航到监控
    static let deepLinkNavigateToMonitor = Notification.Name("deepLinkNavigateToMonitor")
    
 /// Deep Link 导航到传输
    static let deepLinkNavigateToTransfers = Notification.Name("deepLinkNavigateToTransfers")
}
