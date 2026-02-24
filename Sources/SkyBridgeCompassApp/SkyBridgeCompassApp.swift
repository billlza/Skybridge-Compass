import SwiftUI
import WidgetKit
import UserNotifications
import os.log
import AppKit
import SkyBridgeCore
import SkyBridgeUI

@available(macOS 14.0, *)
@main
struct SkyBridgeCompassApp: App {
    @StateObject private var appModel = DashboardViewModel()
    @StateObject private var authModel = AuthenticationViewModel()
    @StateObject private var themeConfiguration = ThemeConfiguration.shared
    @StateObject private var supabaseConfiguration = SupabaseConfiguration.shared
    @StateObject private var vncLaunchContext = VNCLaunchContext.shared
    @StateObject private var sshLaunchContext = SSHLaunchContext.shared

 /// 天气服务 - 提供天气数据和位置服务
    @StateObject private var weatherDataService = WeatherDataService()
    @StateObject private var weatherLocationService = WeatherLocationService()
    @StateObject private var weatherIntegrationManager = WeatherIntegrationManager.shared
    @StateObject private var weatherEffectsSettings = WeatherEffectsSettings.shared

 /// 设置管理器（延迟初始化以避免阻塞）
    @StateObject private var settingsManager = SettingsManager.shared

 /// 启动协调器 - 管理分阶段加载
    @StateObject private var startupCoordinator = StartupCoordinator.shared

 /// 本地化管理器
    @StateObject private var localizationManager = LocalizationManager.shared

    private let renderConfig: DMGBackgroundRenderConfig?
    private let iconApplied: Bool

    var body: some Scene {
        WindowGroup(localizationManager.localizedString("app.name")) {
            Group {
                if let _ = renderConfig {
                    Color.clear
                        .frame(width: 1, height: 1)
                } else if startupCoordinator.isStartupComplete {
 // 启动完成后显示主界面
                    RootContainerView()
                        .environmentObject(appModel)
                        .environmentObject(authModel)
                        .environmentObject(themeConfiguration)
                        .environmentObject(supabaseConfiguration)
                        .environmentObject(weatherDataService)
                        .environmentObject(weatherLocationService)
                        .environmentObject(weatherIntegrationManager)
                        .environmentObject(weatherEffectsSettings)
                        .environmentObject(settingsManager)
                        .environmentObject(localizationManager)
                        .environment(\.iconMissingHint, !iconApplied)
                        .environment(\.locale, localizationManager.locale)
        } else {
 // 显示启动加载界面
            startupLoadingView
                .environmentObject(settingsManager)
                .environmentObject(localizationManager)
                .environment(\.locale, localizationManager.locale)
                .environmentObject(themeConfiguration)
                .environmentObject(supabaseConfiguration)
        }
            }
            .frame(minWidth: 1280, minHeight: 720)
            .preferredColorScheme(.dark)
            .onOpenURL { url in
 // 处理 Widget Deep Link
                DeepLinkRouter.shared.handleDeepLink(url)
            }
            .task {
                if renderConfig == nil {
 // 开始协调启动流程
                    await startupCoordinator.startCoordinatedLaunch()

 // 启动完成后配置Supabase
                    if supabaseConfiguration.isConfigured {
 // 启用AuthenticationService的Supabase模式
                        if let config = SupabaseService.Configuration.fromEnvironment() {
                            AuthenticationService.shared.enableSupabaseMode(supabaseConfig: config)
                            SkyBridgeLogger.ui.debugOnly("✅ Supabase模式已启用")
                        }
                    }
                }
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
 // 应用菜单命令
            SkyBridgeCommands()
        }
        .environmentObject(vncLaunchContext)
        .environmentObject(sshLaunchContext)

 // 偏好设置窗口
        Settings {
            PreferencesView()
                .environmentObject(appModel)
                .environmentObject(authModel)
                .environmentObject(weatherDataService)
                .environmentObject(weatherLocationService)
                .environmentObject(weatherIntegrationManager)
                .environmentObject(weatherEffectsSettings)
                .environmentObject(settingsManager)
                .environmentObject(localizationManager)
                .environment(\.locale, localizationManager.locale)
                .environmentObject(themeConfiguration)
                .environmentObject(supabaseConfiguration)
        }

// 近距硬件镜像窗口 - macOS 15/26 最佳实践
// 说明：macOS Tahoe 26 已于 2025-09-15 正式发布，CryptoKit 原生支持 HPKE X-Wing、ML-KEM、ML-DSA
        WindowGroup(id: "near-field-mirror") {
            NearFieldMirrorView()
                .environmentObject(appModel)
                .frame(minWidth: 800, minHeight: 600)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .defaultSize(width: 900, height: 650)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建近距连接") {
                    openNearFieldWindow()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }

 // 🆕 跨网络连接窗口 - 三维连接矩阵
 // 动态二维码 + iCloud 设备链 + 智能连接码
        WindowGroup(id: "cross-network-connection") {
            CrossNetworkConnectionView()
                .environmentObject(appModel)
                .frame(minWidth: 700, minHeight: 600)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .defaultSize(width: 800, height: 700)
        .commands {
            CommandGroup(after: .newItem) {
                Button("新建跨网络连接...") {
                    openCrossNetworkWindow()
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            }
        }

 // 🆕 VNC 查看器窗口
        WindowGroup(id: "vnc-viewer") {
            VNCViewerView()
                .environmentObject(vncLaunchContext)
                .frame(minWidth: 800, minHeight: 600)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
 // 🆕 SSH 终端窗口
        WindowGroup(id: "ssh-terminal") {
            SSHTerminalView()
                .environmentObject(sshLaunchContext)
                .frame(minWidth: 800, minHeight: 600)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }

 /// 打开跨网络连接窗口（已在 @available(macOS 14.0, *) 作用域内）
    @MainActor
    private func openCrossNetworkWindow() {
        #if os(macOS)
            NSWorkspace.shared.open(URL(string: "skybridge://cross-network")!)
        #endif
    }

 /// 打开近距镜像窗口（已在 @available(macOS 14.0, *) 作用域内）
    @MainActor
    private func openNearFieldWindow() {
        #if os(macOS)
 // 使用 SwiftUI 的 openWindow 环境动作
 // 这是 macOS 14+ 的标准方式
            NSWorkspace.shared.open(URL(string: "skybridge://near-field")!)
        #endif
    }

 // MARK: - 启动加载界面

 /// 启动加载界面 - 显示启动进度和当前加载的组件
    private var startupLoadingView: some View {
        ZStack {
 // 星空背景
            StarryBackground()
                .opacity(0.8)
                .ignoresSafeArea(.all)

            VStack(spacing: 32) {
 // 应用图标和标题
                VStack(spacing: 16) {
                    Image(systemName: "globe.americas.fill")
                        .font(.system(size: 64, weight: .light))
                        .foregroundColor(.blue)

                    Text("SkyBridge Compass Pro")
                        .font(.largeTitle.weight(.medium))
                        .foregroundColor(.white)

                    Text("正在启动应用程序...")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }

 // 启动进度
                VStack(spacing: 16) {
 // 进度条
                    ProgressView(value: startupCoordinator.progress)
                        .progressViewStyle(LinearProgressViewStyle())
                        .tint(.blue)
                        .frame(width: 300)

 // 当前阶段和组件
                    VStack(spacing: 8) {
                        Text(startupCoordinator.currentStage.description)
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(.white)

                        if !startupCoordinator.currentLoadingComponent.isEmpty {
                            Text("正在加载: \(startupCoordinator.currentLoadingComponent)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Text("\(Int(startupCoordinator.progress * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.blue)
                    }
                }

 // 错误信息（如果有）
                if let error = startupCoordinator.startupError {
                    Text("启动错误: \(error)")
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding()
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    init() {
        let renderConfig = DMGBackgroundRenderConfig.fromProcessInfo()
        self.renderConfig = renderConfig
        if let renderConfig {
            self.iconApplied = true
            DMGBackgroundRenderer.renderAndTerminate(config: renderConfig)
            return
        }

        // Phase C3: Boot self-test for SBP2 TrafficPadding + CSV stats.
        // This guarantees we can see DIAG/CSV path even if no handshake happens yet.
        // If you don't see these logs, you are not running the newly built binary.
        _ = TrafficPadding.wrapIfEnabled(Data("boot".utf8), label: "boot")
        Task { try? await TrafficPaddingStats.shared.flushToCSV() }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            WidgetCenter.shared.getCurrentConfigurations { result in
                guard case .success(let configurations) = result, !configurations.isEmpty else { return }
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
        BackgroundTaskCoordinator.shared.registerSystemTasks()
        Self.configureNotificationsUnified()
        let applied = Self.applyAppIconIfAvailable()
        self.iconApplied = applied

 // 🔧 修复命令行启动时的键盘输入问题
 // 确保应用能够接收键盘输入和焦点事件
        DispatchQueue.main.async {
            Self.activateApplicationForKeyboardInput()

 // 🖱️ 启动全局鼠标追踪器（苹果官方推荐方式）
 // 延迟 1 秒确保窗口已创建
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                GlobalMouseTracker.shared.startTracking()
            }

 // 🆕 初始化菜单栏图标
 // Requirements: 1.1 - 应用启动后在状态栏显示 SkyBridge 图标
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MenuBarController.shared.setup()
                Self.setupMenuBarNotificationHandlers()
            }
        }

 // 配置受信公钥白名单提供者（Supabase）
 // 🔒 安全改进：从安全配置加载凭据，不再硬编码
        if let supabaseURL = ProcessInfo.processInfo.environment["SUPABASE_URL"],
           let supabaseAnon = ProcessInfo.processInfo.environment["SUPABASE_ANON_KEY"] {
            RemoteDesktopManager.shared.bootstrapTrustedKeysFromSupabase(
                url: supabaseURL,
                anonKey: supabaseAnon
            )
        } else {
 // 从Keychain加载配置
            Task { @MainActor in
                if let config = try? KeychainManager.shared.retrieveSupabaseConfig() {
                    RemoteDesktopManager.shared.bootstrapTrustedKeysFromSupabase(
                        url: config.url,
                        anonKey: config.anonKey
                    )
                } else {
                    SkyBridgeLogger.ui.error("⚠️ Supabase配置未找到，请在设置中配置或通过环境变量提供")
                }
            }
        }

 // DEBUG 模式下：应用退出时打印 Deprecated API 使用报告
 // Requirements: 11.1
        #if DEBUG
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            DeprecationTracker.shared.printReport()
        }
        #endif

 // 前台分层恢复 - 避免应用激活时所有子系统同时抢占资源导致峰值
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in
 // 按图片最佳实践使用 而非 .detached，继承当前 actor 更安全
            Task(priority: .utility) {
 // 第1层：天气系统轻量刷新（延迟 600ms）
                try? await Task.sleep(nanoseconds: 600_000_000)
                await WeatherIntegrationManager.shared.refresh()
                // 第2层：设备发现（延迟 1200ms）
                try? await Task.sleep(nanoseconds: 600_000_000)
                let shouldAutoScan = await MainActor.run {
                    SettingsManager.shared.autoScanOnStartup
                }
                if shouldAutoScan {
                    await UnifiedOnlineDeviceManager.shared.startDiscoveryAsync()
                }
// 初始化 CloudKit 服务
                await CloudKitService.shared.checkAccountStatus()
 // 第3层：文件传输设置应用（延迟 1800ms）
                try? await Task.sleep(nanoseconds: 600_000_000)
                await FileTransferSettingsBridge.shared.applyAsync()
            }
        }
    }

 /// 激活应用以接收键盘输入
 /// 解决通过命令行启动时TextField无法输入的问题
    @MainActor
    private static func activateApplicationForKeyboardInput() {
 // 设置应用为常规应用类型（而非后台应用）
        NSApp.setActivationPolicy(.regular)

 // 激活应用，忽略其他应用的状态
 // 这对于命令行启动的GUI应用是必需的
        NSApp.activate(ignoringOtherApps: true)

 // 确保应用窗口获得焦点
 // Swift 6.2: 使用 + MainActor 替代 DispatchQueue 以保持 actor 隔离
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
            if let window = NSApp.keyWindow ?? NSApp.windows.first {
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(window.contentView)
            }
        }

        SkyBridgeLogger.ui.debugOnly("🎯 应用已激活，键盘输入功能已启用")
    }

 // MARK: - 静态配置方法

 /// 配置通知权限
    @MainActor
    private static func configureNotifications() {
 // 在macOS命令行应用中，通知中心可能不可用，需要安全处理
        guard Bundle.main.bundleURL.pathExtension != "" else {
            SkyBridgeLogger.ui.debugOnly("跳过通知配置：命令行环境")
            return
        }

        Task {
            do {
                let center = UNUserNotificationCenter.current()
                let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
                SkyBridgeLogger.ui.debugOnly("通知权限已\(granted ? "授予" : "拒绝")")
            } catch {
                SkyBridgeLogger.ui.error("通知权限请求失败: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

 /// 配置通知权限（统一入口）
 /// 说明：
 /// - 在应用启动阶段统一申请系统通知权限，并注册通知类别
 /// - 仅在有效的 .app Bundle 环境下执行，避免命令行/测试环境异常
 /// - 权限状态通过 SettingsManager 同步到应用设置，确保开关一致
    @MainActor
    private static func configureNotificationsUnified() {
 // 检查是否为有效的 .app Bundle
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.path.lowercased().hasSuffix(".app"),
              let bundleIdentifier = Bundle.main.bundleIdentifier else {
            SkyBridgeLogger.ui.debugOnly("跳过通知配置：当前环境无有效 App Bundle")
            return
        }

 // 使用异步任务以遵循严格并发控制与主线程安全
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()

 // 注册统一通知类别，便于后续分类管理（设备发现、天气建议、性能警报）
            let categories: Set<UNNotificationCategory> = [
                UNNotificationCategory(identifier: "DISCOVERY_ALERT", actions: [], intentIdentifiers: [], options: []),
                UNNotificationCategory(identifier: "WEATHER_ADVICE", actions: [], intentIdentifiers: [], options: []),
                UNNotificationCategory(identifier: "PERFORMANCE_ALERT", actions: [], intentIdentifiers: [], options: [])
            ]
            center.setNotificationCategories(categories)

 // 统一通过 SettingsManager 请求系统通知权限，并同步到应用设置
            let granted = await SettingsManager.shared.requestNotificationPermission()
            SkyBridgeLogger.ui.debugOnly("📣 [通知配置] 应用(\(bundleIdentifier))系统通知权限已\(granted ? "授予" : "拒绝")")
        }
    }

 /// 设置菜单栏通知处理器
 /// Requirements: 1.4, 2.4, 3.3, 3.4, 4.3
    @MainActor
    private static func setupMenuBarNotificationHandlers() {
 // 处理打开主窗口请求
 // Requirements: 1.4
 // Swift 6.2: 使用 queue: nil + @MainActor 保持 actor 隔离
        NotificationCenter.default.addObserver(
            forName: .menuBarOpenMainWindow,
            object: nil,
            queue: nil
        ) { _ in
            Task { @MainActor in
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first(where: { $0.title.contains("SkyBridge") || $0.isMainWindow }) {
                    window.makeKeyAndOrderFront(nil)
                }
            }
        }

 // 处理打开设备详情请求
 // Requirements: 2.4
        NotificationCenter.default.addObserver(
            forName: .menuBarOpenDeviceDetail,
            object: nil,
            queue: nil
        ) { _ in
            Task { @MainActor in
                NSApp.activate(ignoringOtherApps: true)
 // 设备详情由主窗口处理
                if let window = NSApp.windows.first(where: { $0.title.contains("SkyBridge") || $0.isMainWindow }) {
                    window.makeKeyAndOrderFront(nil)
                }
            }
        }

 // 处理打开屏幕镜像请求
 // Requirements: 3.4
        NotificationCenter.default.addObserver(
            forName: .menuBarOpenScreenMirror,
            object: nil,
            queue: nil
        ) { _ in
            Task { @MainActor in
                NSWorkspace.shared.open(URL(string: "skybridge://near-field")!)
            }
        }

 // 处理文件传输请求
 // Requirements: 3.3
        NotificationCenter.default.addObserver(
            forName: .menuBarOpenFileTransfer,
            object: nil,
            queue: nil
        ) { _ in
            Task { @MainActor in
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first(where: { $0.title.contains("SkyBridge") || $0.isMainWindow }) {
                    window.makeKeyAndOrderFront(nil)
                }
 // 文件 URL 由主窗口处理
            }
        }

 // 处理打开设置请求（回退方式）
 // Requirements: 3.5
        NotificationCenter.default.addObserver(
            forName: .menuBarOpenSettings,
            object: nil,
            queue: nil
        ) { _ in
            Task { @MainActor in
                NSApp.activate(ignoringOtherApps: true)
 // 尝试打开设置窗口
                if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
                    _ = NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                }
            }
        }

        SkyBridgeLogger.ui.debugOnly("✅ 菜单栏通知处理器已设置")
    }

 /// 应用应用图标（如果可用）
    @MainActor
    private static func applyAppIconIfAvailable() -> Bool {
 // 优先使用 .icns 文件（系统会自动应用圆角遮罩），PNG 作为回退
        let moduleICNS = Bundle.module.url(forResource: "AppIcon", withExtension: "icns")
        let mainICNS = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
        let modulePNG = Bundle.module.url(forResource: "AppIcon", withExtension: "png")
        let mainPNG = Bundle.main.url(forResource: "AppIcon", withExtension: "png")
        let chosenURL = moduleICNS ?? mainICNS ?? modulePNG ?? mainPNG
        guard let url = chosenURL else {
            SkyBridgeLogger.ui.debugOnly("⚠️ 未找到 AppIcon.png 或 AppIcon.icns（module/main 均为空）")
            return false
        }
        guard let icon = NSImage(contentsOf: url) else {
            SkyBridgeLogger.ui.error("⚠️ 无法加载图标文件: \(url.path, privacy: .private)")
            return false
        }
        DispatchQueue.main.async {
            NSApplication.shared.applicationIconImage = icon
            SkyBridgeLogger.ui.debugOnly("✅ 应用图标已设置: \(url.path.hasSuffix(".png") ? "PNG" : "ICNS") @ \(url.path)")
        }
        return true
    }
}

// MARK: - 根容器视图

/// 根容器视图 - 根据认证状态显示不同界面
@available(macOS 14.0, *)
private struct RootContainerView: View {
    @EnvironmentObject private var dashboardModel: DashboardViewModel
    @EnvironmentObject private var authModel: AuthenticationViewModel
    @Environment(\.iconMissingHint) private var iconMissingHint
    @StateObject private var pairingTrustApproval = PairingTrustApprovalService.shared

    var body: some View {
 // 移除调试日志以减少重复渲染的日志噪音
        Group {
            if authModel.currentSession != nil {
                DashboardView()
                    .onAppear {
                        SkyBridgeLogger.ui.debugOnly("📱 [RootContainerView] DashboardView 出现")
 // 认证状态更新由onChange统一处理，避免重复调用
                    }
                    .toolbar {
 // 游客模式工具栏
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
                        SkyBridgeLogger.ui.debugOnly("🔐 [RootContainerView] AuthenticationView 出现")
 // 认证状态清除由onChange统一处理，避免重复调用
                    }
            }
        }
        .onChange(of: authModel.currentSession) { _, newSession in
            SkyBridgeLogger.ui.debugOnly("🔄 [RootContainerView] currentSession 发生变化")
            SkyBridgeLogger.ui.debugOnly("   新会话: \(newSession?.userIdentifier ?? "无")")
            Task { await dashboardModel.updateAuthentication(session: newSession) }
        }
        .animation(.easeInOut(duration: 0.25), value: authModel.currentSession != nil)
        .overlay(alignment: .topTrailing) {
            if iconMissingHint {
                MissingIconHintView()
                    .allowsHitTesting(false)
                    .padding(12)
                    .zIndex(0) // 避免遮挡右上角工具按钮
            }
        }
        .sheet(item: Binding(get: { pairingTrustApproval.pendingRequest }, set: { newValue in
            if newValue == nil {
                pairingTrustApproval.userDismissedCurrentPrompt()
            }
        })) { req in
            PairingTrustApprovalSheet(
                request: req,
                onDecision: { decision in
                    pairingTrustApproval.resolve(req, decision: decision)
                }
            )
        }
    }
}

// MARK: - 环境值扩展

/// 图标缺失提示环境键
private struct IconMissingHintKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

/// 环境值扩展 - 图标缺失提示
private extension EnvironmentValues {
    var iconMissingHint: Bool {
        get { self[IconMissingHintKey.self] }
        set { self[IconMissingHintKey.self] = newValue }
    }
}
