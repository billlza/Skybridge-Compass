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
    @StateObject private var localPeerServices = LocalPeerServiceCoordinator.shared
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
    private let localWebRTCSmokeHarness = LocalWebRTCSmokeHarness()

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
                        .environmentObject(localPeerServices)
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
                if url.scheme == "skybridge", url.host == "auth" {
                    Task { @MainActor in
                        _ = await authModel.handleSupabaseAuthCallback(url)
                    }
                    return
                }
 // 处理 Widget Deep Link
                DeepLinkRouter.shared.handleDeepLink(url)
            }
            .sheet(isPresented: $authModel.showPasswordResetSheet) {
                SupabasePasswordResetSheet()
                    .environmentObject(authModel)
            }
            .task {
                if renderConfig == nil {
                    await localPeerServices.startIfNeeded()

                    await MainActor.run {
                        appModel.bootstrapConnectionPresentationBindings()
                    }

                    if localWebRTCSmokeHarness.isEnabledForCurrentEnvironment {
                        localWebRTCSmokeHarness.startIfNeeded()
                        return
                    }

 // 开始协调启动流程
                    await startupCoordinator.startCoordinatedLaunch()

 // 启动完成后配置Supabase
                    if let config = supabaseConfiguration.resolvedConfiguration
                        ?? SupabaseService.Configuration.fromEnvironment() {
                        AuthenticationService.shared.enableSupabaseMode(supabaseConfig: config)
                        SkyBridgeLogger.ui.debugOnly("✅ Supabase模式已启用")
                    }

                    localWebRTCSmokeHarness.startIfNeeded()
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
            guard let url = URL(string: "skybridge://cross-network") else { return }
            NSWorkspace.shared.open(url)
        #endif
    }

 /// 打开近距镜像窗口（已在 @available(macOS 14.0, *) 作用域内）
    @MainActor
    private func openNearFieldWindow() {
        #if os(macOS)
 // 使用 SwiftUI 的 openWindow 环境动作
 // 这是 macOS 14+ 的标准方式
            guard let url = URL(string: "skybridge://near-field") else { return }
            NSWorkspace.shared.open(url)
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
                    BrandAppIconView(
                        contentMode: .fit,
                        safeInset: 0,
                        clipCornerRadius: 24
                    )
                    .frame(width: 72, height: 72)
                    .shadow(color: .blue.opacity(0.28), radius: 18, x: 0, y: 10)

                    Text(startupText("startup.productName"))
                        .font(.largeTitle.weight(.medium))
                        .foregroundColor(.white)

                    Text(startupText("startup.subtitle.launching"))
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
                        .animation(.easeOut(duration: 0.2), value: startupCoordinator.progress)

 // 当前阶段和组件
                    VStack(spacing: 8) {
                        Text(startupText(startupCoordinator.currentStage.localizationKey))
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(.white)

                        if let currentStep = startupCoordinator.currentStep {
                            Text(
                                startupText(
                                    "startup.loading.format",
                                    startupText(currentStep.localizationKey)
                                )
                            )
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Text(
                            startupText(
                                "startup.progress.steps",
                                String(startupCoordinator.completedStepCount),
                                String(startupCoordinator.totalStepCount)
                            )
                        )
                        .font(.caption)
                        .foregroundColor(.secondary)

                        Text("\(Int(startupCoordinator.progress * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.blue)
                    }
                }

 // 错误信息（如果有）
                if let error = startupCoordinator.startupError {
                    Text(startupText("startup.error.format", error))
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

    private func startupText(_ key: String) -> String {
        localizationManager.localizedString(key)
    }

    private func startupText(_ key: String, _ arguments: CVarArg...) -> String {
        String(
            format: localizationManager.localizedString(key),
            locale: localizationManager.locale,
            arguments: arguments
        )
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
        if let config = SupabaseService.Configuration.fromEnvironment() {
            RemoteDesktopManager.shared.bootstrapTrustedKeysFromSupabase(
                url: config.url.absoluteString,
                anonKey: config.anonKey
            )
        } else {
            SkyBridgeLogger.ui.error("⚠️ Supabase配置未找到，请在设置中配置、提供环境变量或检查包内配置")
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
                guard let url = URL(string: "skybridge://near-field") else { return }
                NSWorkspace.shared.open(url)
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
 // On macOS, the Finder/static app icon and the running Dock icon should come
 // from the same bundle contract. Loading the raw .icns here causes the Dock
 // to bypass LaunchServices' packaged icon rendering, which is exactly how
 // static and runtime icons drift apart.
        if Bundle.main.bundleURL.pathExtension == "app" {
            let hasBundledIcon =
                Bundle.main.url(forResource: "AppIconDock", withExtension: "icns") != nil ||
                Bundle.main.url(forResource: "AppIconDock", withExtension: "png") != nil ||
                Bundle.main.url(forResource: "AppIcon", withExtension: "icns") != nil ||
                Bundle.main.url(forResource: "AppIcon", withExtension: "png") != nil
            if hasBundledIcon {
                SkyBridgeLogger.ui.debugOnly("✅ 使用 bundle 静态应用图标，避免运行态与未启动态图标分叉")
                return true
            }
        }

 // Fallback for non-bundled/debug launches where the process has no packaged
 // app icon for LaunchServices to resolve.
        func resolveIconURL(named baseName: String) -> URL? {
            let moduleICNS = Bundle.module.url(forResource: baseName, withExtension: "icns")
            let mainICNS = Bundle.main.url(forResource: baseName, withExtension: "icns")
            let modulePNG = Bundle.module.url(forResource: baseName, withExtension: "png")
            let mainPNG = Bundle.main.url(forResource: baseName, withExtension: "png")
            return moduleICNS ?? mainICNS ?? modulePNG ?? mainPNG
        }

        let chosenURL = resolveIconURL(named: "AppIconDock") ?? resolveIconURL(named: "AppIcon")
        guard let url = chosenURL else {
            SkyBridgeLogger.ui.debugOnly("⚠️ 未找到 AppIconDock/AppIcon 图标资源（module/main 均为空）")
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
    @EnvironmentObject private var localPeerServices: LocalPeerServiceCoordinator
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
                    .environmentObject(authModel)
                    .onAppear {
                        SkyBridgeLogger.ui.debugOnly("🔐 [RootContainerView] AuthenticationView 出现")
 // 认证状态清除由onChange统一处理，避免重复调用
                    }
            }
        }
        .task(id: authModel.currentSession) {
            await localPeerServices.startIfNeeded()
            await dashboardModel.updateAuthentication(session: authModel.currentSession)
            await CurrentPathDeviceActivationCoordinator.shared.syncIfNeeded(session: authModel.currentSession)
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

@available(macOS 14.0, *)
private struct SupabasePasswordResetSheet: View {
    @EnvironmentObject private var authModel: AuthenticationViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("重置密码")
                .font(.title2.weight(.semibold))

            Text("请输入新的登录密码。完成后将继续使用当前恢复会话进入应用。")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            SecureField("新密码", text: $authModel.resetPasswordValue)
            SecureField("确认新密码", text: $authModel.resetPasswordConfirmation)

            if let message = authModel.errorMessage, !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("取消") {
                    authModel.cancelPendingPasswordReset()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("更新密码") {
                    Task { await authModel.submitPasswordReset() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(authModel.isProcessing)
            }
        }
        .padding(24)
        .frame(width: 420)
        .interactiveDismissDisabled(authModel.isProcessing)
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

@available(macOS 14.0, *)
@MainActor
private final class LocalWebRTCSmokeHarness {
    private var didStart = false

    private var role: String {
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var isEnabled: Bool {
        role == "mac-host"
    }

    var isEnabledForCurrentEnvironment: Bool {
        isEnabled
    }

    private var expectsPQCRekey: Bool {
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_EXPECT_PQC_REKEY"] == "1"
    }

    func startIfNeeded() {
        guard isEnabled, !didStart else { return }
        didStart = true

        let expectsPQCRekey = self.expectsPQCRekey
        let requiresStreamEvidence = ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_REQUIRE_STREAM"] == "1"
        let requiresDirectPath = ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_REQUIRE_DIRECT"] == "1"
        let statusURL = self.statusURL()
        let codeURL = self.codeURL()

        Task { @MainActor in
            let reporter = SmokeStatusReporter(statusURL: statusURL)
            reporter.reset()
            reporter.append("boot role=mac-host")

            let manager = CrossNetworkConnectionManager.shared
            await manager.disconnect()

            do {
                let code = try await manager.generateConnectionCode()
                if let codeURL {
                    try Self.writeText(code, to: codeURL)
                }
                reporter.append("code \(code)")
            } catch {
                reporter.append("failed stage=generate error=\(Self.sanitize(error.localizedDescription))")
                self.terminateIfNeeded()
                return
            }

            let timeoutSeconds = Double(ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_TIMEOUT_SECONDS"] ?? "") ?? 90
            let deadline = Date().addingTimeInterval(timeoutSeconds)
            var lastStatus = ""
            var lastReadiness = ""
            var lastRekeyEvent = ""
            var sawInitialHandshake = false

            while Date() < deadline {
                let statusDescription = String(describing: manager.connectionStatus)
                if statusDescription != lastStatus {
                    lastStatus = statusDescription
                    reporter.append("status \(Self.sanitize(statusDescription))")
                }

                let readinessDescription = String(describing: manager.readiness)
                if readinessDescription != lastReadiness {
                    lastReadiness = readinessDescription
                    reporter.append("readiness \(Self.sanitize(readinessDescription))")
                }

                let rekeyDescription = manager.lastRekeyEvent ?? ""
                if rekeyDescription != lastRekeyEvent, !rekeyDescription.isEmpty {
                    lastRekeyEvent = rekeyDescription
                    reporter.append("rekey \(Self.sanitize(rekeyDescription))")
                }

                if case .failed(let message) = manager.connectionStatus {
                    reporter.append("failed stage=handshake error=\(Self.sanitize(message))")
                    self.terminateIfNeeded()
                    return
                }

                if case .handshakeComplete(let sessionId, let negotiatedSuite) = manager.readiness {
                    if !sawInitialHandshake {
                        sawInitialHandshake = true
                        reporter.append(
                            "handshake session=\(sessionId) suite=\(Self.sanitize(negotiatedSuite))"
                        )
                    }

                    let suiteName = negotiatedSuite.uppercased()
                    let isClassicBootstrap = suiteName == "X25519" || suiteName == "X25519-ED25519"
                    let evidence = Self.smokeEvidence(statusURL: statusURL)
                    let streamSatisfied = !requiresStreamEvidence || evidence.hasStream
                    let directSatisfied = !requiresDirectPath || evidence.hasDirectPath
                    if (!expectsPQCRekey || !isClassicBootstrap) && streamSatisfied && directSatisfied {
                        reporter.append(
                            "success session=\(sessionId) suite=\(Self.sanitize(negotiatedSuite)) stream=\(evidence.hasStream) direct=\(evidence.hasDirectPath)"
                        )
                        self.terminateIfNeeded()
                        return
                    }
                }

                try? await Task.sleep(for: .milliseconds(250))
            }

            reporter.append("failed stage=timeout error=mac_smoke_timeout")
            self.terminateIfNeeded()
        }
    }

    private func terminateIfNeeded() {
        guard ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_AUTO_EXIT"] == "1" else { return }
        NSApp.terminate(nil)
    }

    private func statusURL() -> URL? {
        guard let raw = ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_STATUS_FILE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: raw)
    }

    private func codeURL() -> URL? {
        guard let raw = ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_CODE_FILE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: raw)
    }

    private static func writeText(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.appending("\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func sanitize(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }

    private static func smokeEvidence(statusURL: URL?) -> (hasStream: Bool, hasDirectPath: Bool) {
        guard let statusURL,
              let contents = try? String(contentsOf: statusURL, encoding: .utf8) else {
            return (false, false)
        }
        let hasStream = contents.contains("stream-format ")
            || contents.contains("stream-stats ")
        let hasDirectPath = contents.contains("stream-path ")
            && contents.contains("path=direct")
        return (hasStream, hasDirectPath)
    }
}

@available(macOS 14.0, *)
private struct SmokeStatusReporter {
    let statusURL: URL?

    func reset() {
        guard let statusURL else { return }
        try? FileManager.default.createDirectory(at: statusURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "".write(to: statusURL, atomically: true, encoding: .utf8)
    }

    func append(_ line: String) {
        guard let statusURL else { return }
        let sanitizedLine = "[\(ISO8601DateFormatter().string(from: Date()))] \(line)\n"
        if let data = sanitizedLine.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: statusURL.path),
               let handle = try? FileHandle(forWritingTo: statusURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? FileManager.default.createDirectory(at: statusURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: statusURL, options: .atomic)
            }
        }
    }
}
