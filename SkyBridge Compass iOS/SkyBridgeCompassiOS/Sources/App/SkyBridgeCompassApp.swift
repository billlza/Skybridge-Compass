import SwiftUI
import ActivityKit
import SkyBridgeRealtimeMedia
#if os(iOS)
import UserNotifications
import UIKit
#endif
#if canImport(WebRTC)
import WebRTC
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
#if DEBUG || SKYBRIDGE_TESTING
    @State private var didInstallUITestFixtures = false

    private var isUITesting: Bool {
        SkyBridgeRuntimeEnvironment.isUITesting
    }
#endif

    private var shouldSkipInteractiveStartup: Bool {
#if DEBUG || SKYBRIDGE_TESTING
        SkyBridgeRuntimeEnvironment.shouldSkipInteractiveStartup
#else
        false
#endif
    }

#if DEBUG || SKYBRIDGE_TESTING
    private var shouldDisableAnimationsForUITests: Bool {
        SkyBridgeRuntimeEnvironment.shouldDisableAnimationsForUITests
    }
#endif

#if DEBUG || SKYBRIDGE_TESTING
    private var shouldShowSmokeNativeRenderHost: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["SKYBRIDGE_SMOKE_ROLE"] == "ios-client"
            && environment["SKYBRIDGE_SMOKE_REQUIRE_NATIVE_VIDEO"] == "1"
            && environment["SKYBRIDGE_SMOKE_USE_NATIVE_RENDER_OVERLAY"] == "1"
    }
#endif
    
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
#if DEBUG || SKYBRIDGE_TESTING
                .overlay {
#if canImport(WebRTC)
                    if shouldShowSmokeNativeRenderHost {
                        LocalWebRTCSmokeNativeRenderHost()
                    }
#endif
                }
#endif
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
                .task(id: authManager.currentPathAuthenticationPrincipal) {
                    let principal = shouldSkipInteractiveStartup
                        ? nil
                        : authManager.currentPathAuthenticationPrincipal
                    await IOSCurrentPathDeviceActivationCoordinator.shared.syncIfNeeded(
                        authenticationPrincipal: principal
                    )
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
#if DEBUG || SKYBRIDGE_TESTING
        if isUITesting && shouldDisableAnimationsForUITests {
            UIView.setAnimationsEnabled(false)
        }
#endif

        if shouldSkipInteractiveStartup {
            SettingsManager.instance.enableRealTimeWeather = false
        }

#if DEBUG || SKYBRIDGE_TESTING
        installUITestFixturesIfNeeded()
#endif

        // BUILD FINGERPRINT (must be unmistakable in device logs)
        SkyBridgeLogger.shared.info("🧪 BUILD_FINGERPRINT 2026-01-25 iOS Supabase-config-fix v2")
        print("🧪 BUILD_FINGERPRINT 2026-01-25 iOS Supabase-config-fix v2")

        // 配置日志系统
        SkyBridgeLogger.shared.configure(level: .debug)

#if DEBUG || SKYBRIDGE_TESTING
        if LocalWebRTCSmokeHarness.shared.isEnabled
            || LocalP2PSmokeHarness.shared.isEnabled
            || shouldSkipInteractiveStartup {
            var smokeDefaults = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            smokeDefaults["pqc_allow_classic_fallback"] = false
            UserDefaults.standard.setVolatileDomain(smokeDefaults, forName: UserDefaults.argumentDomain)
            UserDefaults.standard.set(false, forKey: "pqc_allow_classic_fallback")
        }

        // 请求必要的权限
        if shouldSkipInteractiveStartup {
            SkyBridgeLogger.shared.info("🧪 Test host mode: 跳过交互式权限弹窗")
        } else if LocalWebRTCSmokeHarness.shared.isEnabled || LocalP2PSmokeHarness.shared.isEnabled {
            SkyBridgeLogger.shared.info("🧪 Local WebRTC smoke: 跳过交互式权限弹窗")
        } else {
            requestPermissions()
        }
#else
        requestPermissions()
#endif
        
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

        // Supabase config quick sanity without blocking launch on Security.framework I/O.
        Task { @MainActor in
            do {
                if try await SupabaseService.shared.availableConfiguration(logIfMissing: false) != nil {
                    SkyBridgeLogger.shared.info("🔐 Supabase 配置状态=present")
                } else {
                    SkyBridgeLogger.shared.info("ℹ️ Supabase 未配置（当前为离线认证模式，可在设置页填写 SUPABASE_URL/SUPABASE_ANON_KEY）")
                }
            } catch {
                SkyBridgeLogger.shared.error("❌ Supabase 安全配置读取失败: \(error.localizedDescription)")
            }
        }
    }

#if DEBUG || SKYBRIDGE_TESTING
    private func installUITestFixturesIfNeeded() {
        guard isUITesting, !didInstallUITestFixtures else { return }
        didInstallUITestFixtures = true

        let arguments = Set(ProcessInfo.processInfo.arguments)
        SkyBridgeLogger.shared.info("🧪 Installing UI test fixtures: \(Array(arguments).sorted().joined(separator: ","))")
        var fixtureConnections: [Connection] = []

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
            do {
                try FileTransferManager.instance.installUITestHistoryFixture(
                    for: fileConnection.device.name
                )
            } catch {
                preconditionFailure("UI test file-transfer fixture installation failed")
            }
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
                    purpose: .kemIdentityExchange,
                    peerId: "uitest-pairing-peer",
                    declaredDeviceId: "uitest-pairing-device",
                    deviceName: "SkyBridge Mac",
                    platform: .macOS,
                    modelName: "MacBook Pro",
                    osVersion: "macOS 26.0",
                    kemKeyCount: 1,
                    verificationCode: nil,
                    protocolIdentityFingerprint: nil,
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
#endif
    
    /// 初始化核心服务
    private func initializeServices() async {
        if shouldSkipInteractiveStartup {
            SkyBridgeLogger.shared.info("🧪 Test host mode: 跳过后台服务初始化")
            return
        }

        do {
            _ = try await IOSCurrentPathAuthorityReadinessGate.shared.ensureReady()
        } catch {
            SkyBridgeLogger.shared.error(
                "❌ Current-path authority 恢复失败；监听、发现与能力广告保持停用: \(error.localizedDescription)"
            )
            return
        }

        do {
            switch try await QPeriaptIOSRuntime.prepareProductionSession() {
            case .unprovisioned:
                SkyBridgeLogger.shared.info(
                    "ℹ️ Q-Periapt ABI2 未配置生产信任根；套件 0x0012 保持停用且不广告"
                )
            case .activated:
                SkyBridgeLogger.shared.info("✅ Q-Periapt ABI2 生产策略会话已激活")
            }
        } catch is CancellationError {
            SkyBridgeLogger.shared.info("ℹ️ Q-Periapt ABI2 启动准备已取消；套件保持停用")
        } catch {
            SkyBridgeLogger.shared.error(
                "❌ Q-Periapt ABI2 生产策略会话激活失败；套件保持停用: \(error.localizedDescription)"
            )
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

        // 3. KVS 在线态必须来自真实可拨号的控制监听器，而不是 App 进程存活状态。
        configureICloudPresenceReadiness()

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

        // 5. 监听器启动完成后再发布 KVS presence。启动失败时会显式发布离线，
        // 避免 Mac 将心跳存活误判为 P2P 控制端口可达。
        ICloudDevicePresenceService.shared.start()

        // 6. CloudKit 信任同步异步启动，不阻塞其余启动服务。
        if SettingsManager.instance.enableCloudKitSync {
            scheduleCloudKitTrustedDeviceSync(trigger: .startup)
        } else {
            SkyBridgeLogger.shared.info("ℹ️ CloudKit 同步未开启（SettingsManager.enableCloudKitSync = false）")
        }

        // 7. Clipboard Sync wiring（最小闭环）：本地剪贴板变化 -> 广播给已握手连接
        ClipboardManager.shared.onLocalClipboardChanged = { data, mimeType in
            Task { @MainActor in
                await P2PConnectionManager.instance.broadcastClipboard(data: data, mimeType: mimeType)
            }
        }

        // 8. 应用剪贴板设置（启用/图片/URL/大小/历史/轮询/限速）
        applyClipboardSettings()

        // 9. 启动文件传输监听（iOS 作为接收端：macOS -> iOS）
        SkyBridgeLogger.shared.info("⏱️ 启动步骤开始：文件传输监听")
        let fileTransferStartedAt = Date()
        do {
            try await FileTransferRuntime.shared.startIfNeeded()
            let fileTransferElapsedMs = Int(Date().timeIntervalSince(fileTransferStartedAt) * 1000)
            SkyBridgeLogger.shared.info("✅ 文件传输监听步骤完成 (\(fileTransferElapsedMs)ms)")
        } catch {
            SkyBridgeLogger.shared.error(
                "❌ 文件传输监听不可用，已撤销本机文件传输能力广告: \(error.localizedDescription)"
            )
        }

        // 10. 启动灵动岛 Live Activity（显示天气或连接状态）
        SkyBridgeLogger.shared.info("⏱️ 启动步骤开始：Live Activity")
        let liveActivityStartedAt = Date()
        await initializeLiveActivity()
        let liveActivityElapsedMs = Int(Date().timeIntervalSince(liveActivityStartedAt) * 1000)
        SkyBridgeLogger.shared.info("✅ Live Activity 启动步骤完成 (\(liveActivityElapsedMs)ms)")
        SkyBridgeLogger.shared.info("✅ 启动服务初始化流程已完成")
#if DEBUG || SKYBRIDGE_TESTING
        await LocalP2PSmokeHarness.shared.startIfNeeded()
        await LocalWebRTCSmokeHarness.shared.startIfNeeded()
#endif
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
            SkyBridgeLogger.shared.info("ℹ️ 灵动岛 Live Activity 未启动（请检查系统开关或 Info.plist 配置）")
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
            do {
                try await discoveryManager.startDiscovery(mode: mode)
                if !wasRunning {
                    SkyBridgeLogger.shared.info("✅ 设备发现服务已启动（preset=\(settings.discoveryModePreset)）")
                } else {
                    SkyBridgeLogger.shared.debug("ℹ️ 设备发现已在运行（preset=\(settings.discoveryModePreset)）")
                }
            } catch {
                SkyBridgeLogger.shared.error("❌ 设备发现服务启动失败（preset=\(settings.discoveryModePreset)）: \(error.localizedDescription)")
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
        if shouldSkipInteractiveStartup {
            SkyBridgeLogger.shared.info("🧪 Test host mode: 跳过 scenePhase 交互式服务处理 (\(phase))")
            return
        }

        let settings = SettingsManager.instance

        switch phase {
        case .active:
            backgroundTeardownTask?.cancel()
            backgroundTeardownTask = nil
            discoveryManager.retryAuthorizationBlockedBrowsers()
            // 前台：确保按设置启动
            applyDiscoverySettings()
            do {
                try await connectionManager.startListening()
            } catch {
                SkyBridgeLogger.shared.error("❌ 前台恢复 P2P 监听器失败: \(error.localizedDescription)")
            }
            // 回到前台：在监听器启动结果确定后重启 presence。start() 会立即发布一次。
            ICloudDevicePresenceService.shared.start()
            applyClipboardSettings()
            scheduleCloudKitTrustedDeviceSync(trigger: .foreground)

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

                let hasActiveP2P = connectionManager.shouldPreserveReachabilityInBackground
                let isTransferring = FileTransferManager.instance.isTransferring
                let hasCrossNetwork: Bool = {
                    if case .connected = CrossNetworkWebRTCManager.instance.state { return true }
                    return false
                }()

                if !hasActiveP2P && !isTransferring && !hasCrossNetwork {
                    discoveryManager.stopDiscovery()
                    connectionManager.stopListening()
                    // 同时停止 iCloud 在线心跳定时器（30s/次 + iCloud KVS 同步），后台空闲时持续运行会显著耗电。
                    // 回到前台时由 .active 分支的 start() 重新拉起。
                    ICloudDevicePresenceService.shared.stop()
                    SkyBridgeLogger.shared.info("⏹️ 后台空闲超过 30s，已停止 discovery/listener/在线心跳")
                } else {
                    SkyBridgeLogger.shared.info("ℹ️ 后台仍有活动连接/传输，保持 discovery/listener")
                }
                backgroundTeardownTask = nil
            }

        default:
            break
        }
    }

    private func scheduleCloudKitTrustedDeviceSync(
        trigger: CloudKitSyncManager.TrustedDeviceSyncTrigger
    ) {
        guard SettingsManager.instance.enableCloudKitSync else { return }

        // CloudKit APIs are async; the utility-priority lifecycle task lets
        // startup/foreground work continue while the manager single-flights
        // overlapping requests and publishes completion/error state.
        Task(priority: .utility) { @MainActor in
            do {
                try await CloudKitSyncManager.instance.refreshTrustedDevices(
                    trigger: trigger
                )
            } catch {
                SkyBridgeLogger.shared.error(
                    "⛔️ CloudKit 生命周期同步失败: trigger=\(trigger.rawValue) error=\(CloudKitSyncManager.safeErrorSummary(error))"
                )
            }
        }
    }

    private func configureICloudPresenceReadiness() {
        ICloudDevicePresenceService.shared.configureControlListenerReadinessProvider {
            let snapshot = DeviceDiscoveryManager.instance.advertisingReadinessSnapshot
            return ICloudDevicePresenceService.ControlListenerReadiness(
                isReady: snapshot.isReady(for: 9527),
                controlPort: snapshot.actualPort
            )
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
            ),
            UNNotificationCategory(
                identifier: "IDLE_CONNECTION",
                actions: [
                    UNNotificationAction(
                        identifier: "KEEP_CONNECTION",
                        title: localizationManager.localized("idleConnection.keep"),
                        options: []
                    ),
                    UNNotificationAction(
                        identifier: "DISCONNECT_CONNECTION",
                        title: localizationManager.localized("idleConnection.disconnect"),
                        options: .destructive
                    )
                ],
                intentIdentifiers: [],
                options: []
            ),
            UNNotificationCategory(
                identifier: NotificationManager.remoteDesktopSessionCategoryIdentifier,
                actions: [],
                intentIdentifiers: [],
                options: []
            )
        ]
        
        UNUserNotificationCenter.current().setNotificationCategories(categories)
    }
}
