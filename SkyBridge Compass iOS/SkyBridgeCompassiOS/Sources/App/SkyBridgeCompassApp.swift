import SwiftUI
import ActivityKit
#if os(iOS)
import UserNotifications
#endif

/// SkyBridge Compass iOS 主应用入口
/// 支持 iOS 17, 18, 26+
/// 与 macOS 版本完全兼容的 PQC 加密通信
@main
@available(iOS 17.0, *)
struct SkyBridgeCompassApp: App {
    // MARK: - State Objects
    
    /// 应用状态管理器
    @StateObject private var appState = AppStateManager()
    
    /// 设备发现管理器
    @StateObject private var discoveryManager = DeviceDiscoveryManager.instance
    
    /// P2P 连接管理器
    @StateObject private var connectionManager = P2PConnectionManager.instance
    
    /// 认证管理器
    @StateObject private var authManager = AuthenticationManager.instance
    
    /// 主题配置
    @StateObject private var themeConfiguration = ThemeConfiguration.instance
    
    /// 本地化管理器
    @StateObject private var localizationManager = LocalizationManager.instance

    @Environment(\.scenePhase) private var scenePhase
    
    // MARK: - Scene Configuration
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(discoveryManager)
                .environmentObject(connectionManager)
                .environmentObject(authManager)
                .environmentObject(themeConfiguration)
                .environmentObject(localizationManager)
                .environment(\.locale, localizationManager.locale)
                .preferredColorScheme(themeConfiguration.isDarkMode ? .dark : .light)
                .onAppear {
                    setupApplication()
                }
                .task {
                    await initializeServices()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    Task { @MainActor in
                        await handleScenePhaseChange(newPhase)
                    }
                }
        }
    }
    
    // MARK: - Application Setup
    
    /// 设置应用初始化
    private func setupApplication() {
        // BUILD FINGERPRINT (must be unmistakable in device logs)
        SkyBridgeLogger.shared.info("🧪 BUILD_FINGERPRINT 2026-01-25 iOS Supabase-config-fix v2")
        print("🧪 BUILD_FINGERPRINT 2026-01-25 iOS Supabase-config-fix v2")

        // 配置日志系统
        SkyBridgeLogger.shared.configure(level: .debug)
        
        // 请求必要的权限
        requestPermissions()
        
        // 配置通知
        configureNotifications()
        
        SkyBridgeLogger.shared.info("🚀 SkyBridge Compass iOS 已启动")
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        SkyBridgeLogger.shared.info("🏷️ App Version: \(version) (\(build))")
        SkyBridgeLogger.shared.info("🔧 Settings: enforcePQC=\(PQCCryptoManager.instance.enforcePQCHandshake ? "1" : "0"), allowClassicFallback=\(PQCCryptoManager.instance.allowClassicFallbackForCompatibility ? "1" : "0")")
        SkyBridgeLogger.shared.info("📱 iOS 版本: \(UIDevice.current.systemVersion)")
        SkyBridgeLogger.shared.info("📲 设备类型: \(UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone")")

        // Supabase config quick sanity (prints in device logs even if user profile refresh hasn't run yet)
        if let cfg = SupabaseService.Configuration.fromEnvironment() {
            let host = cfg.url.host ?? "unknown"
            SkyBridgeLogger.shared.info("🔐 Supabase resolved host=\(host)")
            print("🔐 Supabase resolved host=\(host)")
        } else {
            SkyBridgeLogger.shared.warning("⚠️ Supabase 未配置（启动时未解析到有效配置）")
            print("⚠️ Supabase 未配置（启动时未解析到有效配置）")
        }
    }
    
    /// 初始化核心服务
    private func initializeServices() async {
        do {
            // 1. 初始化 PQC 加密系统
            try await PQCCryptoManager.instance.initialize()
            SkyBridgeLogger.shared.info("✅ PQC 加密系统初始化完成")
        } catch {
            SkyBridgeLogger.shared.error("❌ PQC 初始化失败: \(error.localizedDescription)")
        }

        // 2. 启动设备发现服务（按设置：模式/自定义服务/扫描周期）
        applyDiscoverySettings()

        // 3. 初始化 CloudKit 同步（默认关闭；需要在设置中开启且配置 iCloud 能力）
        if SettingsManager.instance.enableCloudKitSync {
            await CloudKitSyncManager.instance.initialize()
            SkyBridgeLogger.shared.info("✅ CloudKit 同步已初始化")
        } else {
            SkyBridgeLogger.shared.info("ℹ️ CloudKit 同步未开启（SettingsManager.enableCloudKitSync = false）")
        }

        // 4. 启动 P2P 监听器（按后台策略）
        if SettingsManager.instance.allowBackgroundConnection || scenePhase == .active {
            do {
                try await connectionManager.startListening()
                SkyBridgeLogger.shared.info("✅ P2P 监听器已启动")
            } catch {
                SkyBridgeLogger.shared.error("❌ P2P 监听器启动失败: \(error.localizedDescription)")
            }
        } else {
            SkyBridgeLogger.shared.info("ℹ️ 后台连接未开启：P2P 监听器延迟到前台启动")
        }

        // 5. Clipboard Sync wiring（最小闭环）：本地剪贴板变化 -> 广播给已握手连接
        ClipboardManager.shared.onLocalClipboardChanged = { data, mimeType in
            Task { @MainActor in
                await P2PConnectionManager.instance.broadcastClipboard(data: data, mimeType: mimeType)
            }
        }

        // 6. 应用剪贴板设置（启用/图片/URL/大小/历史/轮询/限速）
        applyClipboardSettings()

        // 7. 启动文件传输监听（iOS 作为接收端：macOS -> iOS）
        await FileTransferRuntime.shared.startIfNeeded()

        // 8. 启动灵动岛 Live Activity（显示天气或连接状态）
        await initializeLiveActivity()
    }

    /// 初始化灵动岛 Live Activity
    ///
    /// Note: App entrypoint is iOS 17+, so this must not be annotated as available on a wider range.
    private func initializeLiveActivity() async {
        let liveActivity = LiveActivityManager.shared

        // 获取初始天气数据（best-effort：优先使用 WeatherService 的缓存/currentWeather）
        if let weather = WeatherService.shared.currentWeather {
            await liveActivity.updateWeather(from: weather)
        }

        // 启动 Live Activity
        await liveActivity.startActivity()
        SkyBridgeLogger.shared.info("✅ 灵动岛 Live Activity 已启动")
    }

    private func applyDiscoverySettings() {
        let settings = SettingsManager.instance

        // 扫描周期（省电：周期 refresh；0 表示持续发现）
        discoveryManager.setPeriodicRefreshInterval(seconds: settings.discoveryRefreshIntervalSeconds)

        guard settings.discoveryEnabled else {
            discoveryManager.stopDiscovery()
            SkyBridgeLogger.shared.info("ℹ️ 设备发现未开启（SettingsManager.discoveryEnabled = false）")
            return
        }

        let mode: DiscoveryMode
        switch settings.discoveryModePreset {
        case 1: mode = .extended
        case 2: mode = .full
        case 3:
            let types = settings.discoveryCustomServiceTypes.compactMap { DiscoveryServiceType(rawValue: $0) }
            mode = .custom(types.isEmpty ? [.skybridge, .skybridgeQUIC] : types)
        default:
            mode = .skybridgeOnly
        }

        Task { @MainActor in
            let wasRunning = discoveryManager.isDiscovering
            try? await discoveryManager.startDiscovery(mode: mode)
            if !wasRunning {
                SkyBridgeLogger.shared.info("✅ 设备发现服务已启动（preset=\(settings.discoveryModePreset)）")
            } else {
                SkyBridgeLogger.shared.debug("ℹ️ 设备发现已在运行（preset=\(settings.discoveryModePreset)）")
            }
        }
    }

    private func applyClipboardSettings() {
        let settings = SettingsManager.instance
        let clipboard = ClipboardManager.shared

        clipboard.syncImages = settings.clipboardSyncImages
        clipboard.syncFileURLs = settings.clipboardSyncFileURLs
        clipboard.maxContentSizeBytes = settings.clipboardMaxContentSize
        clipboard.historyLimit = settings.clipboardHistoryLimit
        clipboard.pollIntervalSeconds = settings.clipboardPollIntervalSeconds
        clipboard.minSendIntervalSeconds = settings.clipboardMinSendIntervalSeconds

        if settings.clipboardSyncEnabled, !clipboard.isEnabled {
            clipboard.enable()
        } else if !settings.clipboardSyncEnabled, clipboard.isEnabled {
            clipboard.disable()
        }
    }

    private func handleScenePhaseChange(_ phase: ScenePhase) async {
        let settings = SettingsManager.instance

        switch phase {
        case .active:
            // 前台：确保按设置启动
            applyDiscoverySettings()
            if !connectionManager.isListening {
                try? await connectionManager.startListening()
            }
            applyClipboardSettings()

        case .background:
            // 后台：若不允许后台连接，则关掉 discovery + listener（省电）
            guard !settings.allowBackgroundConnection else { return }
            // UX fix:
            // Avoid stopping discovery/listener immediately on background transitions (lock screen, app switch),
            // which can interrupt ongoing handshakes/transfers and create reconnect loops.
            // If we are truly idle, we can stop; otherwise keep running.
            let hasActiveP2P = !connectionManager.activeConnections.isEmpty
            let isTransferring = FileTransferManager.instance.isTransferring
            let hasCrossNetwork: Bool = {
                if case .connected = CrossNetworkWebRTCManager.instance.state { return true }
                return false
            }()
            if !hasActiveP2P && !isTransferring && !hasCrossNetwork {
                discoveryManager.stopDiscovery()
                connectionManager.stopListening()
            }

        default:
            break
        }
    }
    
    /// 请求必要的权限
    private func requestPermissions() {
        Task { @MainActor in
            // 通知权限
            await NotificationManager.requestAuthorization()
            
            // 生物识别权限（用于敏感操作）
            await BiometricAuthManager.checkAvailability()
        }
    }
    
    /// 配置推送通知
    private func configureNotifications() {
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        
        // 注册通知类别
        let categories: Set<UNNotificationCategory> = [
            UNNotificationCategory(
                identifier: "DEVICE_DISCOVERY",
                actions: [],
                intentIdentifiers: [],
                options: []
            ),
            UNNotificationCategory(
                identifier: "CONNECTION_REQUEST",
                actions: [
                    UNNotificationAction(
                        identifier: "ACCEPT",
                        title: "接受",
                        options: .authenticationRequired
                    ),
                    UNNotificationAction(
                        identifier: "REJECT",
                        title: "拒绝",
                        options: .destructive
                    )
                ],
                intentIdentifiers: [],
                options: []
            ),
            UNNotificationCategory(
                identifier: "FILE_TRANSFER",
                actions: [],
                intentIdentifiers: [],
                options: []
            )
        ]
        
        UNUserNotificationCenter.current().setNotificationCategories(categories)
    }
}

// MARK: - App State Manager

/// 应用状态管理器
@MainActor
class AppStateManager: ObservableObject {
    @Published var isSetupComplete: Bool = false
    @Published var currentTab: Tab = .discovery
    @Published var isConnected: Bool = false
    @Published var activeConnections: [Connection] = []
    
    enum Tab: Int, CaseIterable {
        case discovery = 0
        case remoteDesktop = 1
        case fileTransfer = 2
        case settings = 3
        
        var title: String {
            switch self {
            case .discovery: return "发现"
            case .remoteDesktop: return "远程"
            case .fileTransfer: return "文件"
            case .settings: return "设置"
            }
        }
        
        var icon: String {
            switch self {
            case .discovery: return "wifi.circle.fill"
            case .remoteDesktop: return "display"
            case .fileTransfer: return "doc.on.doc.fill"
            case .settings: return "gearshape.fill"
            }
        }
    }
}

// MARK: - Notification Delegate

/// 通知代理
#if os(iOS)
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationDelegate()
    
    private override init() {
        super.init()
    }
    
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // 前台显示通知
        completionHandler([.banner, .sound, .badge])
    }
    
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let actionIdentifier = response.actionIdentifier
        let deviceID = userInfo["deviceID"] as? String

        // 处理通知响应（仅捕获 Sendable 数据，避免 Swift 6.2 并发发送检查报错）
        Task { @MainActor [actionIdentifier, deviceID] in
            await handleNotificationResponse(actionIdentifier, deviceID: deviceID)
        }
        
        completionHandler()
    }
    
    private func handleNotificationResponse(_ actionIdentifier: String, deviceID: String?) async {
        switch actionIdentifier {
        case "ACCEPT":
            // 处理连接请求接受
            if let deviceID {
                await P2PConnectionManager.instance.acceptConnection(from: deviceID)
            }
            
        case "REJECT":
            // 处理连接请求拒绝
            if let deviceID {
                await P2PConnectionManager.instance.rejectConnection(from: deviceID)
            }
            
        default:
            break
        }
    }
}
#else
@MainActor
class NotificationDelegate: NSObject {
    static let shared = NotificationDelegate()
    private override init() { super.init() }
}
#endif

// MARK: - Notification Manager

/// 通知管理器
@MainActor
class NotificationManager {
    static func requestAuthorization() async {
#if os(iOS)
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            
            if granted {
                SkyBridgeLogger.shared.info("✅ 通知权限已授予")
            } else {
                SkyBridgeLogger.shared.warning("⚠️ 通知权限被拒绝")
            }
        } catch {
            SkyBridgeLogger.shared.error("❌ 通知权限请求失败: \(error.localizedDescription)")
        }
#else
        SkyBridgeLogger.shared.info("ℹ️ Notification authorization not applicable on this platform build")
#endif
    }
}

// MARK: - Biometric Auth Manager

/// 生物识别认证管理器
import LocalAuthentication

@MainActor
class BiometricAuthManager {
    static func checkAvailability() async {
        let context = LAContext()
        var error: NSError?
        
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            let biometryType = context.biometryType
            switch biometryType {
            case .faceID:
                SkyBridgeLogger.shared.info("✅ Face ID 可用")
            case .touchID:
                SkyBridgeLogger.shared.info("✅ Touch ID 可用")
            case .opticID:
                SkyBridgeLogger.shared.info("✅ Optic ID 可用")
            default:
                SkyBridgeLogger.shared.info("ℹ️ 无生物识别硬件")
            }
        } else {
            SkyBridgeLogger.shared.warning("⚠️ 生物识别不可用: \(error?.localizedDescription ?? "未知错误")")
        }
    }
    
    static func authenticate(reason: String) async throws -> Bool {
        let context = LAContext()
        
        do {
            return try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            )
        } catch {
            throw error
        }
    }
}
