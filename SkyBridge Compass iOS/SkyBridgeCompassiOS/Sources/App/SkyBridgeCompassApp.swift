import SwiftUI
import ActivityKit
#if os(iOS)
import UserNotifications
import UIKit
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
    @State private var backgroundTeardownTask: Task<Void, Never>?
    @State private var didStartServices = false
    @State private var didInstallUITestFixtures = false

    private var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("UITEST_MODE")
    }

    private var isRunningUnderXCTest: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil
    }

    private var shouldSkipInteractiveStartup: Bool {
        isUITesting || isRunningUnderXCTest
    }

    private var shouldDisableAnimationsForUITests: Bool {
        ProcessInfo.processInfo.arguments.contains("UITEST_DISABLE_ANIMATIONS")
    }
    
    // MARK: - Scene Configuration
    
    var body: some Scene {
        WindowGroup {
            ContentView()

                .id(localizationManager.currentLanguage.rawValue)
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
                    if !didStartServices {
                        didStartServices = true
                        SkyBridgeLogger.shared.info("🧭 启动流程：服务初始化任务已创建")
                        Task(priority: .userInitiated) {
                            SkyBridgeLogger.shared.info("🧭 启动流程：服务初始化任务开始执行")
                            await initializeServices()
                        }
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    Task { @MainActor in
                        await handleScenePhaseChange(newPhase)
                    }
                }
                .onChange(of: localizationManager.currentLanguage) { _, _ in
                    guard !shouldSkipInteractiveStartup else { return }
                    configureNotifications()
                }
        }
    }
    
    // MARK: - Application Setup
    
    /// 设置应用初始化
    private func setupApplication() {
        if isUITesting && shouldDisableAnimationsForUITests {
            UIView.setAnimationsEnabled(false)
        }

        if shouldSkipInteractiveStartup {
            SettingsManager.instance.enableRealTimeWeather = false
        }

        installUITestFixturesIfNeeded()

        // BUILD FINGERPRINT (must be unmistakable in device logs)
        SkyBridgeLogger.shared.info("🧪 BUILD_FINGERPRINT 2026-01-25 iOS Supabase-config-fix v2")
        print("🧪 BUILD_FINGERPRINT 2026-01-25 iOS Supabase-config-fix v2")

        // 配置日志系统
        SkyBridgeLogger.shared.configure(level: .debug)
        
        // 请求必要的权限
        if shouldSkipInteractiveStartup {
            SkyBridgeLogger.shared.info("🧪 Test host mode: 跳过交互式权限弹窗")
        } else if LocalWebRTCSmokeHarness.shared.isEnabled {
            SkyBridgeLogger.shared.info("🧪 Local WebRTC smoke: 跳过交互式权限弹窗")
        } else {
            requestPermissions()
        }
        
        // 配置通知
        if !shouldSkipInteractiveStartup {
            configureNotifications()
        }
        
        SkyBridgeLogger.shared.info("🚀 SkyBridge Compass iOS 已启动")
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        SkyBridgeLogger.shared.info("🏷️ App Version: \(version) (\(build))")
        let allowClassicFallback = UserDefaults.standard.bool(forKey: "pqc_allow_classic_fallback")
        SkyBridgeLogger.shared.info("🔧 Settings: allowClassicFallback=\(allowClassicFallback ? "1" : "0")")
        SkyBridgeLogger.shared.info("📱 iOS 版本: \(UIDevice.current.systemVersion)")
        SkyBridgeLogger.shared.info("📲 设备类型: \(UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone")")

        // Supabase config quick sanity (prints in device logs even if user profile refresh hasn't run yet)
        if let cfg = SupabaseService.Configuration.fromEnvironment(logIfMissing: false) {
            let host = cfg.url.host ?? "unknown"
            SkyBridgeLogger.shared.info("🔐 Supabase resolved host=\(host)")
            print("🔐 Supabase resolved host=\(host)")
        } else {
            SkyBridgeLogger.shared.info("ℹ️ Supabase 未配置（当前为离线认证模式，可在设置页填写 SUPABASE_URL/SUPABASE_ANON_KEY）")
            print("ℹ️ Supabase 未配置（当前为离线认证模式，可在设置页填写 SUPABASE_URL/SUPABASE_ANON_KEY）")
        }
    }

    private func installUITestFixturesIfNeeded() {
        guard isUITesting, !didInstallUITestFixtures else { return }
        didInstallUITestFixtures = true

        let arguments = Set(ProcessInfo.processInfo.arguments)
        SkyBridgeLogger.shared.info("🧪 Installing UI test fixtures: \(Array(arguments).sorted().joined(separator: ","))")
        var fixtureConnections: [Connection] = []

        if arguments.contains("UITEST_SCENARIO_FILES") || arguments.contains("UITEST_SCENARIO_REMOTE") {
            SettingsManager.instance.enableExperimentalFeatures = true
        }

        if arguments.contains("UITEST_SCENARIO_FILES") {
            let fileConnection = makeUITestConnection(
                id: "uitest-files-connection",
                deviceID: "uitest-files-device",
                name: "MacBook Pro",
                modelName: "macOS Test Host",
                capabilities: ["file_transfer"],
                services: [DiscoveredDevice.fileTransferServiceType],
                portMap: [DiscoveredDevice.fileTransferServiceType: 8080]
            )
            fixtureConnections.append(fileConnection)
            FileTransferManager.instance.installUITestHistoryFixture(for: fileConnection.device.name)
        }

        if arguments.contains("UITEST_SCENARIO_REMOTE") {
            let remoteConnection = makeUITestConnection(
                id: "uitest-remote-connection",
                deviceID: "uitest-remote-device",
                name: "Studio Mac",
                modelName: "macOS Remote Host",
                capabilities: ["remote_desktop"],
                services: [DiscoveredDevice.remoteControlServiceType],
                portMap: [DiscoveredDevice.remoteControlServiceType: RemoteDesktopConstants.defaultPort]
            )
            fixtureConnections.append(remoteConnection)
        }

        if !fixtureConnections.isEmpty {
            connectionManager.installUITestActiveConnections(fixtureConnections)
            SkyBridgeLogger.shared.info("🧪 Installed UI test connections: \(fixtureConnections.map { $0.device.id }.joined(separator: ","))")
        }

        if arguments.contains("UITEST_SCENARIO_PAIRING") {
            connectionManager.installUITestPairingPrompt(
                request: .init(
                    id: UUID(uuidString: "11111111-2222-3333-4444-555555555555") ?? UUID(),
                    peerId: "uitest-pairing-peer",
                    declaredDeviceId: "uitest-pairing-device",
                    deviceName: "SkyBridge Mac",
                    platform: .macOS,
                    modelName: "MacBook Pro",
                    osVersion: "macOS 26.0",
                    kemKeyCount: 1,
                    receivedAt: Date()
                )
            )
            SkyBridgeLogger.shared.info("🧪 Installed UI test pairing prompt")
        }
    }

    private func makeUITestConnection(
        id: String,
        deviceID: String,
        name: String,
        modelName: String,
        capabilities: [String],
        services: [String],
        portMap: [String: UInt16]
    ) -> Connection {
        let device = DiscoveredDevice(
            id: deviceID,
            name: name,
            bonjourServiceName: name,
            modelName: modelName,
            platform: .macOS,
            osVersion: "26.0",
            ipAddress: "192.168.1.10",
            bonjourServiceType: services.first,
            bonjourServiceDomain: "local.",
            services: services,
            portMap: portMap,
            signalStrength: -42,
            lastSeen: Date(),
            isConnected: true,
            isTrusted: true,
            publicKey: nil,
            advertisedCapabilities: capabilities,
            capabilities: capabilities
        )
        return Connection(
            id: id,
            device: device,
            status: .connected,
            encryptionType: .pqc,
            latency: 0.012,
            bandwidth: 250_000_000,
            connectedAt: Date()
        )
    }
    
    /// 初始化核心服务
    private func initializeServices() async {
        if shouldSkipInteractiveStartup {
            SkyBridgeLogger.shared.info("🧪 Test host mode: 跳过后台服务初始化")
            return
        }

        do {
            // 1. 初始化 PQC 加密系统
            SkyBridgeLogger.shared.info("⏱️ 启动步骤开始：PQC 初始化")
            let pqcStartedAt = Date()
            try await PQCCryptoManager.instance.initialize()
            let pqcElapsedMs = Int(Date().timeIntervalSince(pqcStartedAt) * 1000)
            SkyBridgeLogger.shared.info("✅ PQC 加密系统初始化完成 (\(pqcElapsedMs)ms)")
        } catch {
            SkyBridgeLogger.shared.error("❌ PQC 初始化失败: \(error.localizedDescription)")
        }

        // 2. 启动设备发现服务（按设置：模式/自定义服务/扫描周期）
        SkyBridgeLogger.shared.info("⏱️ 启动步骤开始：Discovery 配置")
        let discoveryStartedAt = Date()
        applyDiscoverySettings()
        let discoveryElapsedMs = Int(Date().timeIntervalSince(discoveryStartedAt) * 1000)
        SkyBridgeLogger.shared.info("✅ Discovery 配置完成 (\(discoveryElapsedMs)ms)")

        // 3. 初始化 CloudKit 同步（默认关闭；需要在设置中开启且配置 iCloud 能力）
        if SettingsManager.instance.enableCloudKitSync {
            SkyBridgeLogger.shared.info("⏱️ 启动步骤开始：CloudKit 初始化")
            let cloudKitStartedAt = Date()
            await CloudKitSyncManager.instance.initialize()
            let cloudKitElapsedMs = Int(Date().timeIntervalSince(cloudKitStartedAt) * 1000)
            SkyBridgeLogger.shared.info("✅ CloudKit 同步已初始化 (\(cloudKitElapsedMs)ms)")
        } else {
            SkyBridgeLogger.shared.info("ℹ️ CloudKit 同步未开启（SettingsManager.enableCloudKitSync = false）")
        }

        // 4. 启动 P2P 监听器（按后台策略）
        if SettingsManager.instance.allowBackgroundConnection || scenePhase == .active {
            do {
                SkyBridgeLogger.shared.info("⏱️ 启动步骤开始：P2P 监听器")
                let p2pStartedAt = Date()
                try await connectionManager.startListening()
                let p2pElapsedMs = Int(Date().timeIntervalSince(p2pStartedAt) * 1000)
                SkyBridgeLogger.shared.info("✅ P2P 监听器已启动 (\(p2pElapsedMs)ms)")
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
        SkyBridgeLogger.shared.info("⏱️ 启动步骤开始：文件传输监听")
        let fileTransferStartedAt = Date()
        await FileTransferRuntime.shared.startIfNeeded()
        let fileTransferElapsedMs = Int(Date().timeIntervalSince(fileTransferStartedAt) * 1000)
        SkyBridgeLogger.shared.info("✅ 文件传输监听步骤完成 (\(fileTransferElapsedMs)ms)")

        // 8. 启动灵动岛 Live Activity（显示天气或连接状态）
        SkyBridgeLogger.shared.info("⏱️ 启动步骤开始：Live Activity")
        let liveActivityStartedAt = Date()
        await initializeLiveActivity()
        let liveActivityElapsedMs = Int(Date().timeIntervalSince(liveActivityStartedAt) * 1000)
        SkyBridgeLogger.shared.info("✅ Live Activity 启动步骤完成 (\(liveActivityElapsedMs)ms)")
        SkyBridgeLogger.shared.info("✅ 启动服务初始化流程已完成")
        await LocalWebRTCSmokeHarness.shared.startIfNeeded()
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
        let started = await liveActivity.startActivity()
        if started {
            SkyBridgeLogger.shared.info("✅ 灵动岛 Live Activity 已启动")
        } else {
            SkyBridgeLogger.shared.warning("ℹ️ 灵动岛 Live Activity 未启动（请检查系统开关或 Info.plist 配置）")
        }
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
            backgroundTeardownTask?.cancel()
            backgroundTeardownTask = nil
            // 前台：确保按设置启动
            applyDiscoverySettings()
            if !connectionManager.isListening {
                try? await connectionManager.startListening()
            }
            applyClipboardSettings()

        case .background:
            // 后台：若不允许后台连接，则关掉 discovery + listener（省电）
            guard !settings.allowBackgroundConnection else { return }
            backgroundTeardownTask?.cancel()
            backgroundTeardownTask = Task { @MainActor in
                // Grace period: allow users to switch from iPhone -> Mac and initiate connection without
                // instantly tearing down iOS listener/discovery.
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                guard scenePhase == .background else { return }

                let hasActiveP2P = !connectionManager.activeConnections.isEmpty
                let isTransferring = FileTransferManager.instance.isTransferring
                let hasCrossNetwork: Bool = {
                    if case .connected = CrossNetworkWebRTCManager.instance.state { return true }
                    return false
                }()

                if !hasActiveP2P && !isTransferring && !hasCrossNetwork {
                    discoveryManager.stopDiscovery()
                    connectionManager.stopListening()
                    SkyBridgeLogger.shared.info("⏹️ 后台空闲超过 30s，已停止 discovery/listener")
                } else {
                    SkyBridgeLogger.shared.info("ℹ️ 后台仍有活动连接/传输，保持 discovery/listener")
                }
                backgroundTeardownTask = nil
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
                        title: localizationManager.localized("notifications.accept"),
                        options: .authenticationRequired
                    ),
                    UNNotificationAction(
                        identifier: "REJECT",
                        title: localizationManager.localized("notifications.reject"),
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
        
        @MainActor
        var title: String {
            let l10n = LocalizationManager.instance
            switch self {
            case .discovery: return l10n.localized("tab.discovery")
            case .remoteDesktop: return l10n.localized("tab.remote")
            case .fileTransfer: return l10n.localized("tab.files")
            case .settings: return l10n.localized("tab.settings")
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

@available(iOS 17.0, *)
@MainActor
private final class LocalWebRTCSmokeHarness {
    static let shared = LocalWebRTCSmokeHarness()

    private var didStart = false

    private init() {}

    var isEnabled: Bool {
        role == "ios-client"
    }

    private var role: String {
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var connectCode: String {
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_CONNECT_CODE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func startIfNeeded() async {
        guard isEnabled, !didStart else { return }
        didStart = true

        let reporter = SmokeStatusReporter(statusURL: statusURL())
        reporter.reset()
        reporter.append("boot role=ios-client")

        guard !connectCode.isEmpty else {
            reporter.append("failed stage=bootstrap error=missing_connect_code")
            return
        }

        let manager = CrossNetworkWebRTCManager.instance
        await manager.disconnect()

        reporter.append("connect \(connectCode)")
        await manager.connect(withCode: connectCode)

        let timeoutSeconds = Double(ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_TIMEOUT_SECONDS"] ?? "") ?? 90
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var lastState = ""
        var lastReadiness = ""
        var lastRekeyEvent = ""
        var heartbeatStarted = false

        while Date() < deadline {
            let stateDescription = String(describing: manager.state)
            if stateDescription != lastState {
                lastState = stateDescription
                reporter.append("state \(Self.sanitize(stateDescription))")
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

            if case .failed(let message) = manager.state {
                reporter.append("failed stage=handshake error=\(Self.sanitize(message))")
                return
            }

            if case .handshakeComplete(let sessionId, let negotiatedSuite) = manager.readiness,
               !heartbeatStarted {
                heartbeatStarted = true
                reporter.append(
                    "handshake session=\(sessionId) suite=\(Self.sanitize(negotiatedSuite))"
                )
                manager.startRemoteDesktopHeartbeat()
            }

            if let screenData = manager.lastScreenData {
                reporter.append(
                    "success frame=\(screenData.width)x\(screenData.height) bytes=\(screenData.imageData.count)"
                )
                return
            }

            try? await Task.sleep(for: .milliseconds(250))
        }

        reporter.append("failed stage=timeout error=ios_smoke_timeout")
    }

    private func statusURL() -> URL? {
        let fileName = ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_STATUS_BASENAME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "skybridge-smoke-status.log"
        guard !fileName.isEmpty else { return nil }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent(fileName)
    }

    private static func sanitize(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }
}

@available(iOS 17.0, *)
private struct SmokeStatusReporter {
    let statusURL: URL?

    func reset() {
        guard let statusURL else { return }
        try? FileManager.default.createDirectory(at: statusURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "".write(to: statusURL, atomically: true, encoding: .utf8)
    }

    func append(_ line: String) {
        guard let statusURL else { return }
        let formatted = "[\(ISO8601DateFormatter().string(from: Date()))] \(line)\n"
        guard let data = formatted.data(using: .utf8) else { return }
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
