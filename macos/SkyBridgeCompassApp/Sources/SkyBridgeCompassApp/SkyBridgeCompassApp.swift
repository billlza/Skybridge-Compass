import SwiftUI
import WidgetKit
import UserNotifications
import os.log
import AppKit
import SkyBridgeCore

@available(macOS 14.0, *)
@main
struct SkyBridgeCompassApp: App {
    @StateObject private var appModel = DashboardViewModel()
    @StateObject private var authModel = AuthenticationViewModel()
    @StateObject private var themeConfiguration = ThemeConfiguration.shared
    @StateObject private var weatherLocationService = WeatherLocationService()
    @StateObject private var weatherDataService = WeatherDataService()
    private let iconApplied: Bool

    var body: some Scene {
        WindowGroup("云桥司南") {
            RootContainerView()
                .environmentObject(appModel)
                .environmentObject(authModel)
                .environmentObject(themeConfiguration)
                .environmentObject(weatherLocationService)
                .environmentObject(weatherDataService)
                .environment(\.iconMissingHint, !iconApplied)
                .frame(minWidth: 1280, minHeight: 720)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            // 应用菜单命令
            SkyBridgeCommands()
        }
        
        // 偏好设置窗口
        Settings {
            PreferencesView()
                .environmentObject(appModel)
                .environmentObject(authModel)
        }
    }
    init() {
        if #available(macOS 14.0, *), Bundle.main.bundleIdentifier != nil {
            WidgetCenter.shared.reloadAllTimelines()
        }
        BackgroundTaskCoordinator.shared.registerSystemTasks()
        Self.configureNotifications()
        let applied = Self.applyAppIconIfAvailable()
        self.iconApplied = applied
    }
    
    /// 初始化天气服务
    @MainActor
    private func initializeWeatherServices() async {
        // 启动位置服务
        weatherLocationService.startLocationUpdates()
        
        // 建立位置和天气数据的关联
        weatherDataService.locationService = weatherLocationService
        
        // 等待获取位置后启动天气数据服务
        if let location = weatherLocationService.currentLocation {
            weatherDataService.startWeatherUpdates(for: location)
        } else {
            // 监听位置更新，一旦获取到位置就启动天气服务
            let cancellable = weatherLocationService.$currentLocation
                .compactMap { $0 }
                .first()
                .sink { location in
                    weatherDataService.startWeatherUpdates(for: location)
                }
            
            // 保持引用避免被释放
            Task {
                _ = cancellable
            }
        }
    }

    @MainActor
    private static func configureNotifications() {
        // 在非 .app 打包场景（例如直接运行可执行文件）时，UNUserNotificationCenter 会因缺少 bundle 信息崩溃。
        guard Bundle.main.bundleIdentifier != nil else {
            Logger(subsystem: "com.skybridge.compass", category: "Notifications").info("Skip notification setup: missing bundle identifier (non-app bundle run)")
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                Logger(subsystem: "com.skybridge.compass", category: "Notifications").error("Notification authorization failed: \(error.localizedDescription)")
            } else {
                Logger(subsystem: "com.skybridge.compass", category: "Notifications").info("Notification authorization granted: \(String(granted))")
            }
        }
        DispatchQueue.main.async {
            NSApplication.shared.registerForRemoteNotifications()
        }
    }

    /// 从包资源中读取 `AppIcon.icns` 或 `AppIcon.png` 并设置应用图标。
    @MainActor
    private static func applyAppIconIfAvailable() -> Bool {
        let logger = Logger(subsystem: "com.skybridge.compass", category: "AppIcon")

        // 优先从 SwiftPM 的 module bundle 读取（Resources 目录打包）。
        // 在通过 Xcode 项目直接构建时，`Bundle.module` 不可用，因此使用条件编译切换。
        #if SWIFT_PACKAGE
        let moduleBundle = Bundle.module
        #else
        let moduleBundle = Bundle.main
        #endif
        if let icnsURL = moduleBundle.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: icnsURL) {
            NSApplication.shared.applicationIconImage = image
            logger.info("Applied app icon from Bundle.module: AppIcon.icns")
            return true
        }
        if let pngURL = moduleBundle.url(forResource: "AppIcon", withExtension: "png"),
           let image = NSImage(contentsOf: pngURL) {
            NSApplication.shared.applicationIconImage = image
            logger.info("Applied app icon from Bundle.module: AppIcon.png")
            return true
        }

        // 回退到主 bundle（例如通过 Xcode 运行或已手动拷贝）
        let mainBundle = Bundle.main
        if let icnsURL = mainBundle.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: icnsURL) {
            NSApplication.shared.applicationIconImage = image
            logger.info("Applied app icon from Bundle.main: AppIcon.icns")
            return true
        }
        if let pngURL = mainBundle.url(forResource: "AppIcon", withExtension: "png"),
           let image = NSImage(contentsOf: pngURL) {
            NSApplication.shared.applicationIconImage = image
            logger.info("Applied app icon from Bundle.main: AppIcon.png")
            return true
        }
        logger.info("No app icon found in resources; using default icon")
        return false
    }
}

/// 根容器视图，根据认证状态展示登录界面或主控面板。
@available(macOS 14.0, *)
private struct RootContainerView: View {
    @EnvironmentObject private var dashboardModel: DashboardViewModel
    @EnvironmentObject private var authModel: AuthenticationViewModel
    @EnvironmentObject private var weatherLocationService: WeatherLocationService
    @EnvironmentObject private var weatherDataService: WeatherDataService
    @Environment(\.iconMissingHint) private var iconMissingHint

    var body: some View {
        Group {
            if let session = authModel.currentSession {
                DashboardView()
                    .onAppear {
                        Task { 
                            await dashboardModel.updateAuthentication(session: session)
                            await initializeWeatherServices()
                        }
                    }
                    .toolbar {
                        // 如果是游客模式，显示登录按钮
                        if authModel.isGuestMode {
                            ToolbarItem(placement: .primaryAction) {
                                Button("登录账户") {
                                    authModel.signOut() // 退出游客模式，返回登录界面
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                    }
            } else {
                AuthenticationView()
                    .onAppear {
                        Task { await dashboardModel.updateAuthentication(session: nil) }
                    }
            }
        }
        .onChange(of: authModel.currentSession) { newSession in
            Task { await dashboardModel.updateAuthentication(session: newSession) }
        }
        .animation(.easeInOut(duration: 0.25), value: authModel.currentSession != nil)
        .overlay(alignment: .topTrailing) {
            if iconMissingHint {
                MissingIconHintView()
                    .allowsHitTesting(false)
                    .padding(12)
            }
        }
    }
    
    /// 初始化天气服务
    @MainActor
    private func initializeWeatherServices() async {
        // 启动位置服务
        weatherLocationService.startLocationUpdates()
        
        // 建立位置和天气数据的关联
        weatherDataService.locationService = weatherLocationService
        
        // 等待获取位置后启动天气数据服务
        if let location = weatherLocationService.currentLocation {
            weatherDataService.startWeatherUpdates(for: location)
        } else {
            // 监听位置更新，一旦获取到位置就启动天气服务
            let cancellable = weatherLocationService.$currentLocation
                .compactMap { $0 }
                .first()
                .sink { location in
                    weatherDataService.startWeatherUpdates(for: location)
                }
            
            // 保持引用避免被释放
            Task {
                _ = cancellable
            }
        }
    }
}

// 环境键用于在根视图显示缺失图标提示
private struct IconMissingHintKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

private extension EnvironmentValues {
    var iconMissingHint: Bool {
        get { self[IconMissingHintKey.self] }
        set { self[IconMissingHintKey.self] = newValue }
    }
}
