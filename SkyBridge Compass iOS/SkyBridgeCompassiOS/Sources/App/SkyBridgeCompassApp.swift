import SwiftUI
import ActivityKit
import SkyBridgeRealtimeMedia
#if os(iOS)
import UserNotifications
import UIKit
import Darwin
#endif
#if canImport(WebRTC)
import WebRTC
#endif

#if os(iOS)
struct UnsupportedIOSDevice: Equatable {
    let modelIdentifier: String
    let displayName: String
}

enum IOSDeviceSupportGate {
    // Keep the App Store plist gate broad (A12 floor), then explicitly block the
    // last pre-2020 A12/A12X devices that still slip through.
    private static let blockedModelIdentifiers: Set<String> = [
        "iPhone11,2", // iPhone XS
        "iPhone11,4", // iPhone XS Max (China)
        "iPhone11,6", // iPhone XS Max
        "iPhone11,8", // iPhone XR
        "iPad8,1",    // iPad Pro 11-inch (2018) Wi-Fi
        "iPad8,2",    // iPad Pro 11-inch (2018) Wi-Fi + Cellular
        "iPad8,3",    // iPad Pro 11-inch (2018) Wi-Fi
        "iPad8,4",    // iPad Pro 11-inch (2018) Wi-Fi + Cellular
        "iPad8,5",    // iPad Pro 12.9-inch (3rd gen, 2018) Wi-Fi
        "iPad8,6",    // iPad Pro 12.9-inch (3rd gen, 2018) Wi-Fi + Cellular
        "iPad8,7",    // iPad Pro 12.9-inch (3rd gen, 2018) Wi-Fi
        "iPad8,8",    // iPad Pro 12.9-inch (3rd gen, 2018) Wi-Fi + Cellular
        "iPad11,1",   // iPad mini (5th gen, 2019) Wi-Fi
        "iPad11,2",   // iPad mini (5th gen, 2019) Wi-Fi + Cellular
        "iPad11,3",   // iPad Air (3rd gen, 2019) Wi-Fi
        "iPad11,4"    // iPad Air (3rd gen, 2019) Wi-Fi + Cellular
    ]

    static func currentUnsupportedDevice(processInfo: ProcessInfo = .processInfo) -> UnsupportedIOSDevice? {
        guard let modelIdentifier = currentModelIdentifier(processInfo: processInfo) else {
            return nil
        }
        return unsupportedDevice(forModelIdentifier: modelIdentifier)
    }

    static func unsupportedDevice(forModelIdentifier modelIdentifier: String) -> UnsupportedIOSDevice? {
        let normalized = modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard blockedModelIdentifiers.contains(normalized) else {
            return nil
        }
        return UnsupportedIOSDevice(
            modelIdentifier: normalized,
            displayName: displayName(forModelIdentifier: normalized)
        )
    }

    static func isSupported(modelIdentifier: String) -> Bool {
        unsupportedDevice(forModelIdentifier: modelIdentifier) == nil
    }

    private static func currentModelIdentifier(processInfo: ProcessInfo) -> String? {
        #if targetEnvironment(simulator)
        if let simulatorModel = processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !simulatorModel.isEmpty {
            return simulatorModel
        }
        #endif

        var systemInfo = utsname()
        guard uname(&systemInfo) == 0 else {
            return nil
        }

        let identifier = withUnsafePointer(to: &systemInfo.machine) { machinePtr in
            machinePtr.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) {
                String(cString: $0)
            }
        }

        return identifier.isEmpty ? nil : identifier
    }

    private static func displayName(forModelIdentifier modelIdentifier: String) -> String {
        switch modelIdentifier {
        case "iPhone11,2": return "iPhone XS"
        case "iPhone11,4", "iPhone11,6": return "iPhone XS Max"
        case "iPhone11,8": return "iPhone XR"
        case "iPad8,1", "iPad8,2", "iPad8,3", "iPad8,4":
            return "iPad Pro 11-inch (2018)"
        case "iPad8,5", "iPad8,6", "iPad8,7", "iPad8,8":
            return "iPad Pro 12.9-inch (3rd generation)"
        case "iPad11,1", "iPad11,2":
            return "iPad mini (5th generation)"
        case "iPad11,3", "iPad11,4":
            return "iPad Air (3rd generation)"
        default:
            return modelIdentifier
        }
    }
}

private struct UnsupportedIOSDeviceView: View {
    let device: UnsupportedIOSDevice

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.95, green: 0.97, blue: 1.0),
                    Color(red: 0.90, green: 0.94, blue: 0.98)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "iphone.gen3.slash")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.blue)

                Text("This device is no longer supported.")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.primary)

                Text("SkyBridge Compass now requires 2020 or newer iPhone and iPad hardware.")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.secondary)

                Text("当前版本不再支持这台设备。SkyBridge Compass 现要求使用 2020 年及之后发布的 iPhone / iPad 硬件。")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Blocked model")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("\(device.displayName) (\(device.modelIdentifier))")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                }
            }
            .padding(28)
            .frame(maxWidth: 560, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .padding(24)
        }
    }
}
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
    @State private var unsupportedDevice = IOSDeviceSupportGate.currentUnsupportedDevice()

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

    private var shouldShowSmokeNativeRenderHost: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["SKYBRIDGE_SMOKE_ROLE"] == "ios-client"
            && environment["SKYBRIDGE_SMOKE_REQUIRE_NATIVE_VIDEO"] == "1"
            && environment["SKYBRIDGE_SMOKE_USE_NATIVE_RENDER_OVERLAY"] == "1"
    }
    
    // MARK: - Scene Configuration
    
    var body: some Scene {
        WindowGroup {
            Group {
                if let unsupportedDevice {
                    UnsupportedIOSDeviceView(device: unsupportedDevice)
                        .onAppear {
                            SkyBridgeLogger.shared.warning(
                                "⛔️ iOS startup blocked on unsupported device: \(unsupportedDevice.displayName) (\(unsupportedDevice.modelIdentifier))"
                            )
                        }
                } else {
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
                        .overlay {
#if canImport(WebRTC)
                            if shouldShowSmokeNativeRenderHost {
                                LocalWebRTCSmokeNativeRenderHost()
                            }
#endif
                        }
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

        if LocalWebRTCSmokeHarness.shared.isEnabled || LocalP2PSmokeHarness.shared.isEnabled || shouldSkipInteractiveStartup {
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
        await LocalP2PSmokeHarness.shared.startIfNeeded()
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
            discoveryManager.retryAuthorizationBlockedBrowsers()
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

                let hasActiveP2P = connectionManager.shouldPreserveReachabilityInBackground
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

        case "KEEP_CONNECTION":
            await CrossNetworkWebRTCManager.instance.disarmIdleConnectionReminder(clearPrompt: true)

        case "DISCONNECT_CONNECTION":
            await CrossNetworkWebRTCManager.instance.disconnect()
            
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
private final class LocalP2PSmokeHarness {
    static let shared = LocalP2PSmokeHarness()
    private static let xwingSuiteWireID: UInt16 = 0x0001
    private static let mlkem768SuiteWireID: UInt16 = 0x0101
    private static let mlkem768FSSuiteWireID: UInt16 = 0x0102

    private var didStart = false

    private init() {}

    var isEnabled: Bool {
        role == "ios-p2p-client"
    }

    private var role: String {
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var targetDeviceID: String {
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_TARGET_DEVICE_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var targetDeviceName: String {
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_TARGET_NAME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var expectsPQCRekey: Bool {
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_EXPECT_PQC_REKEY"] == "1"
    }

    private var expectsFileTransferSmoke: Bool {
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_EXPECT_FILE_TRANSFER"] == "1"
    }

    private var expectsRemoteDesktopSmoke: Bool {
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_EXPECT_REMOTE_DESKTOP"] == "1"
    }

    private var requiresAudio: Bool {
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_REQUIRE_AUDIO"] == "1"
    }

    private var requiresVisibleRemoteView: Bool {
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_REQUIRE_VISIBLE_REMOTE_VIEW"] == "1"
    }

    private var requiresExtremeMediaValidation: Bool {
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_EXTREME_MEDIA"] == "1"
            || ProcessInfo.processInfo.environment["SKYBRIDGE_WEBRTC_EXTREME_MEDIA"] == "1"
            || ProcessInfo.processInfo.environment["SKYBRIDGE_WEBRTC_FAIL_ON_MEDIA_FALLBACK"] == "1"
    }

    private var expectedHandshakeSuite: String {
        environmentValue("SKYBRIDGE_SMOKE_EXPECT_TARGET_SUITE") ?? "X-Wing"
    }

    private var fileTransferRunID: String {
        environmentValue("SKYBRIDGE_SMOKE_FILE_TRANSFER_RUN_ID") ?? "default"
    }

    private func environmentValue(_ name: String) -> String? {
        guard let raw = ProcessInfo.processInfo.environment[name] else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func positiveEnvironmentInteger(_ name: String) -> Int? {
        guard let raw = environmentValue(name),
              let value = Int(raw),
              value > 0 else {
            return nil
        }
        return value
    }

    private func positiveEnvironmentDouble(_ name: String) -> Double? {
        guard let raw = environmentValue(name),
              let value = Double(raw),
              value > 0 else {
            return nil
        }
        return value
    }

    func startIfNeeded() async {
        guard isEnabled, !didStart else { return }
        didStart = true

        let reporter = SmokeStatusReporter(statusURL: statusURL())
        reporter.reset()
        PQCCryptoManager.instance.allowClassicFallbackForCompatibility = false
        await preseedPeerKEMTrustIfNeeded(reporter: reporter)

        guard !targetDeviceID.isEmpty else {
            reporter.append("failed stage=bootstrap error=missing_target_device_id")
            return
        }

        let discoveryManager = DeviceDiscoveryManager.instance
        let connectionManager = P2PConnectionManager.instance
        reporter.append(
            "boot role=ios-p2p-client target=\(Self.sanitize(targetDeviceID)) name=\(Self.sanitize(targetDeviceName))"
        )

        do {
            try await discoveryManager.startDiscovery(mode: .skybridgeOnly)
            reporter.append("discovery started")
        } catch {
            reporter.append("failed stage=discovery error=\(Self.sanitize(error.localizedDescription))")
            return
        }

        let timeoutSeconds = Double(ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_TIMEOUT_SECONDS"] ?? "") ?? 90
        let deadline = Date().addingTimeInterval(timeoutSeconds)

        var selectedDevice: DiscoveredDevice?
        var connectAttempted = false
        var connectFailure = ""
        var lastHandshakeState = ""
        var lastError = ""
        var lastSuite = ""
        var lastRekey = ""
        var sawClassicHandshake = false
        var sawRekey = false
        var suiteStableSince: Date?
        var didPreseedResolvedTarget = false
        var lastDiscoverySummary = ""
        var lastDiscoveryHealAt = Date.distantPast
        let expectedNormalizedSuite = expectedHandshakeSuite.uppercased()

        while Date() < deadline {
            let handshakeState = connectionManager.currentHandshakeState
            if handshakeState != lastHandshakeState {
                lastHandshakeState = handshakeState
                reporter.append("state \(Self.sanitize(handshakeState))")
            }

            let discoveredSummary = summarizeDiscoveredDevices(discoveryManager.discoveredDevices)
            if discoveredSummary != lastDiscoverySummary {
                lastDiscoverySummary = discoveredSummary
                reporter.append("discovered \(discoveredSummary)")
            }

            let latestError = connectionManager.lastError?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !latestError.isEmpty, latestError != lastError {
                lastError = latestError
                reporter.append("error \(Self.sanitize(latestError))")
            }

            if selectedDevice == nil,
               let target = resolveTargetDevice(from: discoveryManager.discoveredDevices) {
                selectedDevice = target
                reporter.append(
                    "target id=\(Self.sanitize(target.id)) name=\(Self.sanitize(target.name))"
                )
            }

            if !didPreseedResolvedTarget, let target = selectedDevice {
                didPreseedResolvedTarget = true
                await preseedResolvedTargetKEMTrustIfNeeded(target: target, reporter: reporter)
            }

            if !connectAttempted, let target = selectedDevice {
                connectAttempted = true
                reporter.append("connect \(Self.sanitize(target.id))")
                Task { @MainActor in
                    do {
                        _ = expectsPQCRekey
                        try await connectionManager.connect(to: target)
                    } catch {
                        connectFailure = error.localizedDescription
                    }
                }
            }

            if !connectFailure.isEmpty {
                reporter.append("failed stage=connect error=\(Self.sanitize(connectFailure))")
                return
            }

            if selectedDevice == nil,
               Date().timeIntervalSince(lastDiscoveryHealAt) >= 5 {
                lastDiscoveryHealAt = Date()
                discoveryManager.retryAuthorizationBlockedBrowsers()
                await discoveryManager.refresh()
                reporter.append(
                    "discovery-heal count=\(discoveryManager.discoveredDevices.count)"
                )
            }

            if let target = selectedDevice {
                if let suite = connectionManager.getNegotiatedSuite(for: target.id)?.rawValue,
                   suite != lastSuite {
                    lastSuite = suite
                    suiteStableSince = Date()
                    reporter.append("suite \(Self.sanitize(suite))")

                    let normalizedSuite = suite.uppercased()
                    if normalizedSuite.contains("X25519") {
                        sawClassicHandshake = true
                    }
                }

                if let rekey = connectionManager.resolvedRekeyStatus(for: target) {
                    let description = "\(rekey.fromSuite)->\(rekey.toSuite)"
                    if description != lastRekey {
                        lastRekey = description
                        sawRekey = true
                        reporter.append(
                            "rekey \(Self.sanitize(rekey.fromSuite)) -> \(Self.sanitize(rekey.toSuite))"
                        )
                    }
                } else if !lastRekey.isEmpty {
                    lastRekey = ""
                    reporter.append("rekey cleared")
                }

                if let suite = connectionManager.getNegotiatedSuite(for: target.id)?.rawValue {
                    let normalizedSuite = suite.uppercased()

                    if expectsPQCRekey {
                        if sawClassicHandshake && sawRekey && normalizedSuite == "X-WING" {
                            if expectsRemoteDesktopSmoke {
                                do {
                                    try await performRemoteDesktopSmoke(
                                        to: target,
                                        suite: "X-Wing",
                                        reporter: reporter
                                    )
                                    reporter.append("success suite=X-Wing bootstrapRekey=1 remoteDesktop=1")
                                } catch {
                                    reporter.append("failed stage=remote-desktop error=\(Self.sanitize(error.localizedDescription))")
                                }
                            } else if expectsFileTransferSmoke {
                                do {
                                    try await performBidirectionalFileTransferSmoke(
                                        to: target,
                                        reporter: reporter
                                    )
                                    reporter.append("success suite=X-Wing bootstrapRekey=1 fileTransfer=1")
                                } catch {
                                    reporter.append("failed stage=file-transfer error=\(Self.sanitize(error.localizedDescription))")
                                }
                            } else {
                                reporter.append("success suite=X-Wing bootstrapRekey=1")
                            }
                            return
                        }
                    } else if normalizedSuite == expectedNormalizedSuite,
                              !sawRekey,
                              let stableSince = suiteStableSince,
                              Date().timeIntervalSince(stableSince) >= 1.0 {
                        if expectsRemoteDesktopSmoke {
                            do {
                                try await performRemoteDesktopSmoke(
                                    to: target,
                                    suite: suite,
                                    reporter: reporter
                                )
                                reporter.append(
                                    "success suite=\(Self.sanitize(suite)) handshakeOnly=1 remoteDesktop=1"
                                )
                            } catch {
                                reporter.append("failed stage=remote-desktop error=\(Self.sanitize(error.localizedDescription))")
                            }
                        } else if expectsFileTransferSmoke {
                            do {
                                try await performBidirectionalFileTransferSmoke(
                                    to: target,
                                    reporter: reporter
                                )
                                reporter.append(
                                    "success suite=\(Self.sanitize(suite)) handshakeOnly=1 fileTransfer=1"
                                )
                            } catch {
                                reporter.append("failed stage=file-transfer error=\(Self.sanitize(error.localizedDescription))")
                            }
                        } else {
                            reporter.append("success suite=\(Self.sanitize(suite)) handshakeOnly=1")
                        }
                        return
                    }
                }
            }

            if connectAttempted,
               (handshakeState.contains("握手失败") || handshakeState.contains("rekey失败")) {
                reporter.append("failed stage=handshake error=\(Self.sanitize(handshakeState))")
                return
            }

            try? await Task.sleep(for: .milliseconds(250))
        }

        reporter.append("failed stage=timeout error=ios_local_p2p_smoke_timeout")
    }

    private func summarizeDiscoveredDevices(_ devices: [DiscoveredDevice]) -> String {
        guard !devices.isEmpty else { return "count=0" }

        let preview = devices
            .prefix(3)
            .map { device in
                "\(Self.sanitize(device.id))|\(Self.sanitize(device.name))"
            }
            .joined(separator: ",")
        let suffix = devices.count > 3 ? ",more=\(devices.count - 3)" : ""
        return "count=\(devices.count) peers=\(preview)\(suffix)"
    }

    private func statusURL() -> URL? {
        let fileName = ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_STATUS_BASENAME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "skybridge-smoke-status.log"
        guard !fileName.isEmpty else { return nil }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent(fileName)
    }

    private func resolveTargetDevice(from devices: [DiscoveredDevice]) -> DiscoveredDevice? {
        let normalizedTarget = targetDeviceID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !normalizedTarget.isEmpty {
            for device in devices {
                let aliases = Set(PeerIdentityAliasResolver.lookupCandidates(for: device.id))
                    .union(PeerIdentityAliasResolver.aliasKeys(for: device))
                    .union([device.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()])
                if aliases.contains(normalizedTarget) || aliases.contains("id:\(normalizedTarget)") {
                    return device
                }
            }
        }

        let normalizedName = targetDeviceName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedName.isEmpty else { return nil }

        return devices.first { device in
            let deviceName = device.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let bonjourName = device.bonjourServiceName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""
            return deviceName == normalizedName
                || bonjourName == normalizedName
                || deviceName.contains(normalizedName)
                || bonjourName.contains(normalizedName)
        }
    }

    private func decodeBase64Key(
        _ name: String,
        reporter: SmokeStatusReporter
    ) -> Data? {
        guard let raw = environmentValue(name) else { return nil }
        guard let data = Data(base64Encoded: raw, options: [.ignoreUnknownCharacters]), !data.isEmpty else {
            reporter.append("failed stage=pqc-preseed error=invalid_base64_\(name)")
            return nil
        }
        return data
    }

    private func preseedPeerKEMTrustIfNeeded(reporter: SmokeStatusReporter) async {
        guard let peerDeviceID = environmentValue("SKYBRIDGE_PQC_PEER_DEVICE_ID") else {
            return
        }

        var keysBySuite: [UInt16: KEMPublicKeyInfo] = [:]
        if let xwing = decodeBase64Key("SKYBRIDGE_PQC_PEER_XWING_PUBLIC_KEY_BASE64", reporter: reporter) {
            keysBySuite[Self.xwingSuiteWireID] = KEMPublicKeyInfo(
                suiteWireId: Self.xwingSuiteWireID,
                publicKey: xwing
            )
        }
        if let mlkem768 = decodeBase64Key("SKYBRIDGE_PQC_PEER_MLKEM768_PUBLIC_KEY_BASE64", reporter: reporter) {
            keysBySuite[Self.mlkem768SuiteWireID] = KEMPublicKeyInfo(
                suiteWireId: Self.mlkem768SuiteWireID,
                publicKey: mlkem768
            )
            if environmentValue("SKYBRIDGE_PQC_PEER_MLKEM768FS_PUBLIC_KEY_BASE64") == nil {
                keysBySuite[Self.mlkem768FSSuiteWireID] = KEMPublicKeyInfo(
                    suiteWireId: Self.mlkem768FSSuiteWireID,
                    publicKey: mlkem768
                )
            }
        }
        if let mlkem768fs = decodeBase64Key("SKYBRIDGE_PQC_PEER_MLKEM768FS_PUBLIC_KEY_BASE64", reporter: reporter) {
            keysBySuite[Self.mlkem768FSSuiteWireID] = KEMPublicKeyInfo(
                suiteWireId: Self.mlkem768FSSuiteWireID,
                publicKey: mlkem768fs
            )
        }

        let keys = keysBySuite.keys.sorted().compactMap { keysBySuite[$0] }
        guard !keys.isEmpty else {
            reporter.append("pqc-preseed skipped device=\(Self.sanitize(peerDeviceID)) reason=missing_keys")
            return
        }

        await KEMTrustStore.shared.upsert(deviceId: peerDeviceID, kemPublicKeys: keys)
        let suites = keys.map { String(format: "0x%04x", $0.suiteWireId) }.joined(separator: ",")
        reporter.append("pqc-preseed device=\(Self.sanitize(peerDeviceID)) suites=\(suites)")
    }

    private func preseedResolvedTargetKEMTrustIfNeeded(
        target: DiscoveredDevice,
        reporter: SmokeStatusReporter
    ) async {
        var keysBySuite: [UInt16: KEMPublicKeyInfo] = [:]
        if let xwing = decodeBase64Key("SKYBRIDGE_PQC_PEER_XWING_PUBLIC_KEY_BASE64", reporter: reporter) {
            keysBySuite[Self.xwingSuiteWireID] = KEMPublicKeyInfo(
                suiteWireId: Self.xwingSuiteWireID,
                publicKey: xwing
            )
        }
        if let mlkem768 = decodeBase64Key("SKYBRIDGE_PQC_PEER_MLKEM768_PUBLIC_KEY_BASE64", reporter: reporter) {
            keysBySuite[Self.mlkem768SuiteWireID] = KEMPublicKeyInfo(
                suiteWireId: Self.mlkem768SuiteWireID,
                publicKey: mlkem768
            )
            if environmentValue("SKYBRIDGE_PQC_PEER_MLKEM768FS_PUBLIC_KEY_BASE64") == nil {
                keysBySuite[Self.mlkem768FSSuiteWireID] = KEMPublicKeyInfo(
                    suiteWireId: Self.mlkem768FSSuiteWireID,
                    publicKey: mlkem768
                )
            }
        }
        if let mlkem768fs = decodeBase64Key("SKYBRIDGE_PQC_PEER_MLKEM768FS_PUBLIC_KEY_BASE64", reporter: reporter) {
            keysBySuite[Self.mlkem768FSSuiteWireID] = KEMPublicKeyInfo(
                suiteWireId: Self.mlkem768FSSuiteWireID,
                publicKey: mlkem768fs
            )
        }

        let keys = keysBySuite.keys.sorted().compactMap { keysBySuite[$0] }
        guard !keys.isEmpty else { return }

        await KEMTrustStore.shared.upsert(deviceId: target.id, kemPublicKeys: keys)
        reporter.append("pqc-preseed target-alias id=\(Self.sanitize(target.id))")
    }

    private func performRemoteDesktopSmoke(
        to target: DiscoveredDevice,
        suite: String,
        reporter: SmokeStatusReporter
    ) async throws {
        let manager = RemoteDesktopManager.instance
        let minFPS = positiveEnvironmentDouble("SKYBRIDGE_SMOKE_MIN_FPS") ?? 30.0
        let passSeconds = max(
            1.0,
            positiveEnvironmentDouble("SKYBRIDGE_SMOKE_MIN_PASS_SECONDS")
                ?? positiveEnvironmentDouble("SKYBRIDGE_SMOKE_SOAK_SECONDS")
                ?? 10.0
        )
        let timeoutSeconds = positiveEnvironmentDouble("SKYBRIDGE_SMOKE_REMOTE_DESKTOP_TIMEOUT_SECONDS")
            ?? positiveEnvironmentDouble("SKYBRIDGE_SMOKE_TIMEOUT_SECONDS")
            ?? 120.0
        let requestedSize = requestedSmokeVideoSize()
        let expectedSize = requestedSize.map { size in
            requiresExtremeMediaValidation ? size : Self.normalizedVideoSizeForEncoder(size)
        }
        let expectedRenderOrientation = RemoteDesktopRenderOrientation(
            rawValue: environmentValue("SKYBRIDGE_SMOKE_EXPECT_RENDER_ORIENTATION") ?? "upright"
        ) ?? .upright
        let requestedSizeLabel = requestedSize.map { "\($0.width)x\($0.height)" } ?? "auto"
        let expectedSizeLabel = expectedSize.map { "\($0.width)x\($0.height)" } ?? "auto"

        reporter.append(
            """
            remote-desktop start target=\(Self.sanitize(target.id)) suite=\(Self.sanitize(suite)) \
            minFps=\(String(format: "%.1f", minFPS)) passSeconds=\(Int(passSeconds.rounded())) \
            requested=\(requestedSizeLabel) expected=\(expectedSizeLabel) audio=\(requiresAudio ? 1 : 0) \
            visibleRemoteView=\(requiresVisibleRemoteView ? 1 : 0) expectedRenderOrientation=\(expectedRenderOrientation.rawValue)
            """
        )
        reporter.append("remote-desktop p2p-active \(Self.sanitize(activeP2PSmokeSummary()))")

        if requiresVisibleRemoteView {
            reporter.append("remote-desktop ui-gate waiting-for-RemoteDesktopView")
        } else {
            try await manager.connect(to: target)
        }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var passStartedAt: Date?
        var lastDiagnosticAt = Date.distantPast
        var lastSummary = "remote desktop did not produce diagnostics"

        while Date() < deadline {
            let snapshot = await manager.smokeDiagnosticSnapshot()
            let audio = snapshot.realtimeAudio
            let audioPass = !requiresAudio || (
                (audio?.datagramsSeen ?? 0) > 0
                    && (audio?.receivedPackets ?? 0) > 0
                    && (audio?.decodedPackets ?? 0) > 0
                    && (audio?.playedPackets ?? 0) > 0
                    && (audio?.renderedFrames ?? 0) > 0
                    && (snapshot.audioChannelCount ?? 0) >= 2
                    && (audio?.rejectedPackets ?? 0) == 0
                    && (audio?.replayRejectedPackets ?? 0) == 0
                    && (audio?.jitterEvictedPackets ?? 0) == 0
                    && (audio?.playbackDroppedPackets ?? 0) == 0
                    && (audio?.underflowEvents ?? 0) == 0
                    && (audio?.rebufferEvents ?? 0) == 0
            )
            let resolutionPass: Bool = {
                guard let expectedSize else {
                    return snapshot.resolutionWidth > 0 && snapshot.resolutionHeight > 0
                }
                return snapshot.resolutionWidth == expectedSize.width
                    && snapshot.resolutionHeight == expectedSize.height
            }()
            let pipelinePass: Bool = {
                switch snapshot.renderPipeline {
                case .metalRenderer:
                    return true
                case .sampleBufferDisplayLayer:
                    return !self.requiresExtremeMediaValidation
                case .waiting, .webrtcNativeVideo, .stillImageFallback:
                    return false
                }
            }()
            let renderOrientationPass = snapshot.renderPipeline != .metalRenderer
                || snapshot.renderOrientation == expectedRenderOrientation
            let recentFramePass = (snapshot.lastDisplayedFrameAgeSeconds ?? .infinity) < 2.5
                || (snapshot.lastFrameArrivalAgeSeconds ?? .infinity) < 2.5
            let uiPass = !requiresVisibleRemoteView || snapshot.hasActivePresentationOwner
            let pass = snapshot.isStreaming
                && !snapshot.isUsingCrossNetworkTransport
                && uiPass
                && snapshot.frameRate >= minFPS
                && snapshot.receivedFramesInStream > 0
                && resolutionPass
                && pipelinePass
                && renderOrientationPass
                && recentFramePass
                && audioPass

            lastSummary = """
            fps=\(String(format: "%.1f", snapshot.frameRate)) rxFps=\(String(format: "%.1f", snapshot.receivedFrameRate)) \
            frame=\(snapshot.resolutionWidth)x\(snapshot.resolutionHeight) \
            pipeline=\(snapshot.renderPipeline.rawValue) renderOrientation=\(snapshot.renderOrientation.rawValue) streaming=\(snapshot.isStreaming ? 1 : 0) \
            crossNetwork=\(snapshot.isUsingCrossNetworkTransport ? 1 : 0) recvFrames=\(snapshot.receivedFramesInStream) \
            uiSurface=\(snapshot.hasActivePresentationOwner ? "remoteDesktopView" : "none") uiOwnerCount=\(snapshot.presentationOwnerCount) \
            audioRxRecv=\(audio?.receivedPackets ?? 0) audioRxDecoded=\(audio?.decodedPackets ?? 0) \
            audioRxPlayed=\(audio?.playedPackets ?? 0) audioRxRendered=\(audio?.renderedFrames ?? 0) \
            audioChannels=\(snapshot.audioChannelCount ?? 0) \
            audioRxRejected=\(audio?.rejectedPackets ?? 0) audioRxPlaybackDrop=\(audio?.playbackDroppedPackets ?? 0) \
            audioRxReplayRejected=\(audio?.replayRejectedPackets ?? 0) audioRxJitterEvicted=\(audio?.jitterEvictedPackets ?? 0) \
            audioRxUnderflow=\(audio?.underflowEvents ?? 0) audioRxRebuffer=\(audio?.rebufferEvents ?? 0)
            """

            if Date().timeIntervalSince(lastDiagnosticAt) >= 1.0 {
                lastDiagnosticAt = Date()
                reporter.append("remote-desktop status \(lastSummary) pass=\(pass ? 1 : 0)")
            }

            if pass {
                if passStartedAt == nil {
                    passStartedAt = Date()
                    reporter.append("remote-desktop pass-window-start \(lastSummary)")
                }
                if let passStartedAt,
                   Date().timeIntervalSince(passStartedAt) >= passSeconds {
                    reporter.append(
                        "remote-desktop-pass seconds=\(Int(passSeconds.rounded())) \(lastSummary)"
                    )
                    return
                }
            } else {
                passStartedAt = nil
            }

            try? await Task.sleep(for: .milliseconds(250))
        }

        throw NSError(
            domain: "SkyBridge.Smoke",
            code: 1200,
            userInfo: [NSLocalizedDescriptionKey: "P2P 远控 smoke 超时: \(lastSummary)"]
        )
    }

    private func requestedSmokeVideoSize() -> (width: Int, height: Int)? {
        guard let width = positiveEnvironmentInteger("SKYBRIDGE_SMOKE_VIDEO_WIDTH"),
              let height = positiveEnvironmentInteger("SKYBRIDGE_SMOKE_VIDEO_HEIGHT") else {
            return nil
        }
        return (width, height)
    }

    private static func normalizedVideoSizeForEncoder(
        _ size: (width: Int, height: Int)
    ) -> (width: Int, height: Int) {
        func evenDimension(_ value: Int) -> Int {
            let clamped = max(2, value)
            return clamped.isMultiple(of: 2) ? clamped : clamped - 1
        }
        return (evenDimension(size.width), evenDimension(size.height))
    }

    @MainActor
    private func activeP2PSmokeSummary() -> String {
        let connections = P2PConnectionManager.instance.activeConnections
        guard !connections.isEmpty else { return "none" }
        return connections.map { connection in
            [
                "id=\(connection.device.id)",
                "name=\(connection.device.name)",
                "status=\(connection.status.rawValue)",
                "ip=\(connection.device.ipAddress ?? "-")",
                "remotePort=\(connection.device.remoteControlPort.map(String.init) ?? "-")"
            ].joined(separator: ",")
        }.joined(separator: ";")
    }

    private func performBidirectionalFileTransferSmoke(
        to target: DiscoveredDevice,
        reporter: SmokeStatusReporter
    ) async throws {
        try await FileTransferRuntime.shared.ensureHealthy()

        let outboundName = "ios-smoke-\(fileTransferRunID).txt"
        let inboundName = "mac-smoke-\(fileTransferRunID).txt"
        let outboundURL = try makeSmokeTransferFile(
            fileName: outboundName,
            contents: """
            role=ios
            run=\(fileTransferRunID)
            sentAt=\(ISO8601DateFormatter().string(from: Date()))
            target=\(target.id)
            """
        )

        reporter.append("file-transfer outbound-start name=\(Self.sanitize(outboundName))")
        try await FileTransferManager.instance.sendFile(at: outboundURL, to: target)
        reporter.append("file-transfer outbound-complete name=\(Self.sanitize(outboundName))")

        let inboundTransfer = try await waitForCompletedTransfer(
            fileName: inboundName,
            isIncoming: true,
            timeoutSeconds: 90
        )
        guard let localURL = FileTransferManager.instance.resolveExistingLocalFileURL(for: inboundTransfer),
              FileManager.default.fileExists(atPath: localURL.path) else {
            throw NSError(
                domain: "SkyBridge.Smoke",
                code: 1001,
                userInfo: [NSLocalizedDescriptionKey: "iOS smoke 未找到接收到的文件 \(inboundName)"]
            )
        }

        reporter.append(
            "file-transfer inbound-complete name=\(Self.sanitize(inboundName)) path=\(Self.sanitize(localURL.lastPathComponent))"
        )
    }

    private func makeSmokeTransferFile(fileName: String, contents: String) throws -> URL {
        let baseDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SmokeTransfers", isDirectory: true)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let url = baseDirectory.appendingPathComponent(fileName, isDirectory: false)
        guard let data = contents.data(using: .utf8) else {
            throw NSError(
                domain: "SkyBridge.Smoke",
                code: 1002,
                userInfo: [NSLocalizedDescriptionKey: "无法编码 iOS smoke 文件内容"]
            )
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    private func waitForCompletedTransfer(
        fileName: String,
        isIncoming: Bool,
        timeoutSeconds: TimeInterval
    ) async throws -> FileTransfer {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let transfer = FileTransferManager.instance.transferHistory.first(where: { transfer in
                transfer.fileName == fileName
                    && transfer.isIncoming == isIncoming
                    && transfer.status == .completed
            }) {
                return transfer
            }

            try? await Task.sleep(for: .milliseconds(250))
        }

        throw NSError(
            domain: "SkyBridge.Smoke",
            code: 1000,
            userInfo: [NSLocalizedDescriptionKey: "等待传输完成超时: \(fileName)"]
        )
    }

    private nonisolated static func sanitize(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }

}

private func skyBridgeIsSameRealtimeMediaRelayAddress(
    _ lhs: SkyBridgeMediaEndpoint,
    _ rhs: SkyBridgeMediaEndpoint
) -> Bool {
    lhs.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        == rhs.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        && lhs.port == rhs.port
}

private final class SmokeAudioRelayTrafficCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var packets: UInt64 = 0

    func increment() {
        lock.lock()
        packets &+= 1
        lock.unlock()
    }

    func snapshot() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return packets
    }
}

#if canImport(WebRTC)
@available(iOS 17.0, *)
private struct LocalWebRTCSmokeNativeRenderHost: View {
    @ObservedObject private var manager = CrossNetworkWebRTCManager.instance

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.001)

                    if let track = manager.remoteVideoTrack {
                        RemoteDesktopRTCVideoView(
                            track: track,
                            acceptsRenderEvidence: true,
                            uiSurface: "smokeOverlay"
                        )
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .onAppear {
                        SkyBridgeSmokeTraceWriter.appendStatus(
                            "native-render-host trackId=\(track.trackId) visible=1 size=\(Int(geometry.size.width))x\(Int(geometry.size.height)) source=smoke-overlay"
                        )
                    }
                    .onChange(of: track.trackId) { _, newTrackId in
                        SkyBridgeSmokeTraceWriter.appendStatus(
                            "native-render-host trackId=\(newTrackId) visible=1 size=\(Int(geometry.size.width))x\(Int(geometry.size.height)) source=smoke-overlay"
                        )
                    }
                } else {
                    Color.clear
                        .onAppear {
                            SkyBridgeSmokeTraceWriter.appendStatus(
                                "native-render-host waitingForTrack=1 size=\(Int(geometry.size.width))x\(Int(geometry.size.height)) source=smoke-overlay"
                            )
                        }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityIdentifier("smoke.native-video.render-host")
    }
}
#endif

@available(iOS 17.0, *)
@MainActor
private final class LocalWebRTCSmokeHarness {
    static let shared = LocalWebRTCSmokeHarness()
    private static let xwingSuiteWireID: UInt16 = 0x0001
    private static let mlkem768SuiteWireID: UInt16 = 0x0101
    private static let mlkem768FSSuiteWireID: UInt16 = 0x0102
    private static let audioRelayRenewalLeadTime: TimeInterval = 12
    private static let audioRelayKeepaliveIntervalSeconds: TimeInterval = 10
    private static let audioRelayRolloverGraceDelaySeconds: TimeInterval = 15
    private static let audioRelayRolloverTrafficObservationTimeout: TimeInterval = 10
    private static let audioRelayRolloverTrafficObservationPollNanoseconds: UInt64 = 250_000_000
    private static let audioRelayRolloverMinimumObservedPackets: UInt64 = 4
    private static let audioDiagnosticsHeartbeatNanoseconds: UInt64 = 5_000_000_000
    private var smokeAudioReceiver: IOSRealtimeMediaAudioReceiver?
    private var smokeAudioRelayTransport: SkyBridgeUDPRealtimeMediaTransport?
    private var smokeAudioRelayRenewalTask: Task<Void, Never>?
    private var smokeAudioRelayKeepaliveTask: Task<Void, Never>?
    private var smokeAudioDiagnosticsTask: Task<Void, Never>?

    private var didStart = false

    private init() {}

    var isEnabled: Bool {
        role == "ios-client" || role == "ios-host"
    }

    private var role: String {
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var connectCode: String {
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_CONNECT_CODE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var expectsPQCRekey: Bool {
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_EXPECT_PQC_REKEY"] == "1"
    }

    private var expectsHandshakeOnly: Bool {
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_EXPECT_HANDSHAKE_ONLY"] == "1"
    }

    private var requiresAudio: Bool {
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_REQUIRE_AUDIO"] == "1"
    }

    private var requiresNativeVideo: Bool {
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_REQUIRE_NATIVE_VIDEO"] == "1"
    }

    private var usesRealRemoteDesktopViewForNativeVideo: Bool {
        requiresNativeVideo
            && ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_OPEN_REMOTE_TAB"] == "1"
    }

    private var requiresExtremeMediaValidation: Bool {
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_EXTREME_MEDIA"] == "1"
            || ProcessInfo.processInfo.environment["SKYBRIDGE_WEBRTC_EXTREME_MEDIA"] == "1"
            || ProcessInfo.processInfo.environment["SKYBRIDGE_WEBRTC_FAIL_ON_MEDIA_FALLBACK"] == "1"
    }

    private var requiresStrictAudioRelayRenewal: Bool {
        requiresAudio && requiresExtremeMediaValidation
    }

    private var initialSmokeAudioRelayBindPolicy: SkyBridgeRealtimeMediaRelayBindPolicy {
        requiresStrictAudioRelayRenewal ? .requireAcknowledgement : .optimisticAfterSend
    }

    private var smokeAudioRelayRenewalBindPolicy: SkyBridgeRealtimeMediaRelayBindPolicy {
        requiresStrictAudioRelayRenewal ? .requireAcknowledgement : .optimisticAfterSend
    }

    private var requestedSmokeVideoSize: (width: Int, height: Int)? {
        guard let width = positiveEnvironmentInteger("SKYBRIDGE_SMOKE_VIDEO_WIDTH"),
              let height = positiveEnvironmentInteger("SKYBRIDGE_SMOKE_VIDEO_HEIGHT") else {
            return nil
        }
        return (width, height)
    }

    private var requestedSmokeTargetFrameRate: Int {
        guard let value = positiveEnvironmentInteger("SKYBRIDGE_SMOKE_TARGET_FPS") else {
            return 30
        }
        return max(1, min(value, 120))
    }

    private func environmentValue(_ name: String) -> String? {
        guard let raw = ProcessInfo.processInfo.environment[name] else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func positiveEnvironmentInteger(_ name: String) -> Int? {
        guard let raw = environmentValue(name),
              let value = Int(raw),
              value > 0 else {
            return nil
        }
        return value
    }

    func startIfNeeded() async {
        guard isEnabled, !didStart else { return }
        didStart = true

        let reporter = SmokeStatusReporter(statusURL: statusURL())
        reporter.reset()
        stopSmokeAudioReceiver()
        PQCCryptoManager.instance.allowClassicFallbackForCompatibility = false
        if expectsPQCRekey {
            do {
                try await PQCCryptoManager.instance.initialize()
                reporter.append("pqc policy allowClassicBootstrap=0 targetRekey=X-Wing")
            } catch {
                reporter.append("failed stage=pqc-policy error=\(Self.sanitize(error.localizedDescription))")
                return
            }
        }
        await exportLocalPQCIdentityIfNeeded(reporter: reporter)
        await preseedPeerKEMTrustIfNeeded(reporter: reporter)

        let manager = CrossNetworkWebRTCManager.instance
        await manager.disconnect()

        switch role {
        case "ios-client":
            reporter.append("boot role=ios-client")
            guard !connectCode.isEmpty else {
                reporter.append("failed stage=bootstrap error=missing_connect_code")
                return
            }
            reporter.append("connect \(connectCode)")
            await manager.connect(withCode: connectCode)
        case "ios-host":
            reporter.append("boot role=ios-host")
            guard let code = await manager.generateConnectionCode(), !code.isEmpty else {
                reporter.append("failed stage=bootstrap error=missing_generated_code")
                return
            }
            writeGeneratedCode(code)
            reporter.append("code \(code)")
        default:
            reporter.append("failed stage=bootstrap error=unsupported_role_\(role)")
            return
        }

        let timeoutSeconds = Double(ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_TIMEOUT_SECONDS"] ?? "") ?? 90
        let holdAfterSuccessSeconds = max(
            0,
            Double(ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_HOLD_AFTER_SUCCESS_SECONDS"] ?? "") ?? 0
        )
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var lastState = ""
        var lastReadiness = ""
        var lastRekeyEvent = ""
        var heartbeatStarted = false
        var streamConfigurationSent = false
        var reportedPreRekeyNativeFrame = false
        var reportedPreRekeyNativeReady = false
        var reportedPQCRekeyComplete = false
        var successReported = false
        var successHoldUntil: Date?

        func shouldFinishAfterSuccess(_ line: String) -> Bool {
            if !successReported {
                successReported = true
                reporter.append(line)
                if holdAfterSuccessSeconds > 0 {
                    successHoldUntil = Date().addingTimeInterval(holdAfterSuccessSeconds)
                    reporter.append("success-hold seconds=\(Int(holdAfterSuccessSeconds.rounded()))")
                }
            }
            return successHoldUntil == nil
        }

        while Date() < deadline || successHoldUntil != nil {
            if successHoldUntil == nil, Date() >= deadline {
                break
            }
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
            if let successHoldUntil, Date() >= successHoldUntil {
                reporter.append("success-hold-complete")
                return
            }

            if case .handshakeComplete(let sessionId, let negotiatedSuite) = manager.readiness,
               !heartbeatStarted {
                heartbeatStarted = true
                reporter.append(
                    "handshake session=\(sessionId) suite=\(Self.sanitize(negotiatedSuite))"
                )
                if role == "ios-client" {
                    if usesRealRemoteDesktopViewForNativeVideo {
                        reporter.append(
                            "remote-view required=1 uiSurface=remoteDesktopView streamOwner=RemoteDesktopView"
                        )
                    } else if !streamConfigurationSent {
                        streamConfigurationSent = await sendSmokeViewerStreamConfiguration(
                            manager: manager,
                            reporter: reporter,
                            sessionId: sessionId
                        )
                    }
                    if !usesRealRemoteDesktopViewForNativeVideo {
                        manager.startRemoteDesktopHeartbeat()
                    }
                }
            }

            if role == "ios-client" {
                let successDescriptor: (width: Int, height: Int, bytes: Int, transport: String)? = {
                    if let screenData = manager.lastScreenData, !requiresNativeVideo {
                        return (
                            width: screenData.width,
                            height: screenData.height,
                            bytes: screenData.imageData.count,
                            transport: "fallback-screen"
                        )
                    }

                    let nativeFrameSize = manager.remoteVideoTrackFrameSize
                    if manager.remoteVideoTrackHasRenderedFrame,
                       nativeFrameSize.width > 0,
                       nativeFrameSize.height > 0 {
                        return (
                            width: Int(nativeFrameSize.width),
                            height: Int(nativeFrameSize.height),
                            bytes: 0,
                            transport: "webrtc-native"
                        )
                    }

                    if manager.remoteVideoTrackReadyForPromotion,
                       nativeFrameSize.width > 0,
                       nativeFrameSize.height > 0 {
                        if requiresNativeVideo {
                            return nil
                        }
                        return (
                            width: Int(nativeFrameSize.width),
                            height: Int(nativeFrameSize.height),
                            bytes: 0,
                            transport: "webrtc-native-ready"
                        )
                    }

                    return nil
                }()

                if let successDescriptor,
                   case .handshakeComplete(let sessionId, let negotiatedSuite) = manager.readiness {
                    let suiteLabel = Self.sanitize(negotiatedSuite)
                    let bootstrapSatisfied = !expectsPQCRekey
                        || suiteLabel.uppercased().contains("X-WING")
                    if bootstrapSatisfied {
                        if shouldFinishAfterSuccess(
                            "success session=\(sessionId) suite=\(suiteLabel) bootstrapRekey=\(expectsPQCRekey ? 1 : 0) frame=\(successDescriptor.width)x\(successDescriptor.height) bytes=\(successDescriptor.bytes) transport=\(successDescriptor.transport)"
                        ) {
                            return
                        }
                    }
                }

                if let screenData = manager.lastScreenData {
                    if !requiresNativeVideo {
                        if shouldFinishAfterSuccess(
                            "success frame=\(screenData.width)x\(screenData.height) bytes=\(screenData.imageData.count) transport=fallback-screen"
                        ) {
                            return
                        }
                    }
                    reporter.append(
                        "fallback-frame frame=\(screenData.width)x\(screenData.height) bytes=\(screenData.imageData.count) transport=fallback-screen"
                    )
                }

                let nativeFrameSize = manager.remoteVideoTrackFrameSize
                if manager.remoteVideoTrackHasRenderedFrame,
                   nativeFrameSize.width > 0,
                   nativeFrameSize.height > 0 {
                    if !expectsPQCRekey {
                        if shouldFinishAfterSuccess(
                            "success frame=\(Int(nativeFrameSize.width))x\(Int(nativeFrameSize.height)) bytes=0 transport=webrtc-native"
                        ) {
                            return
                        }
                    }
                    if !reportedPreRekeyNativeFrame {
                        reportedPreRekeyNativeFrame = true
                        reporter.append(
                            "native-frame-observed frame=\(Int(nativeFrameSize.width))x\(Int(nativeFrameSize.height)) bytes=0 transport=webrtc-native waitingForRekey=1"
                        )
                    }
                }

                if manager.remoteVideoTrackReadyForPromotion,
                   nativeFrameSize.width > 0,
                   nativeFrameSize.height > 0 {
                    if !expectsPQCRekey, !requiresNativeVideo {
                        if shouldFinishAfterSuccess(
                            "success frame=\(Int(nativeFrameSize.width))x\(Int(nativeFrameSize.height)) bytes=0 transport=webrtc-native-ready"
                        ) {
                            return
                        }
                    }
                    if !reportedPreRekeyNativeReady {
                        reportedPreRekeyNativeReady = true
                        reporter.append(
                            "native-frame-observed frame=\(Int(nativeFrameSize.width))x\(Int(nativeFrameSize.height)) bytes=0 transport=webrtc-native-ready waitingForRekey=1"
                        )
                    }
                }
            }

            if role == "ios-client",
               expectsPQCRekey,
               case .handshakeComplete(let sessionId, let negotiatedSuite) = manager.readiness,
               negotiatedSuite.caseInsensitiveCompare("X-Wing") == .orderedSame,
               let rekeyDescription = manager.lastRekeyEvent,
               rekeyDescription.caseInsensitiveCompare("complete suite=X-Wing") == .orderedSame {
                if requiresNativeVideo {
                    if !reportedPQCRekeyComplete {
                        reportedPQCRekeyComplete = true
                        reporter.append(
                            "rekey-complete session=\(sessionId) suite=\(Self.sanitize(negotiatedSuite)) awaitingNativeVideo=1"
                        )
                    }
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }
                if shouldFinishAfterSuccess(
                    "success session=\(sessionId) suite=\(Self.sanitize(negotiatedSuite)) bootstrapRekey=1"
                ) {
                    return
                }
            }

            if role == "ios-client",
               expectsHandshakeOnly,
               case .handshakeComplete(let sessionId, let negotiatedSuite) = manager.readiness {
                if shouldFinishAfterSuccess(
                    "success session=\(sessionId) suite=\(Self.sanitize(negotiatedSuite)) handshakeOnly=1"
                ) {
                    return
                }
            }

            if role == "ios-host",
               case .handshakeComplete(let sessionId, let negotiatedSuite) = manager.readiness {
                if expectsPQCRekey {
                    if let rekeyDescription = manager.lastRekeyEvent,
                       rekeyDescription.starts(with: "complete suite=") {
                        if shouldFinishAfterSuccess(
                            "success session=\(sessionId) suite=\(Self.sanitize(negotiatedSuite)) rekey=\(Self.sanitize(rekeyDescription))"
                        ) {
                            return
                        }
                    }
                } else {
                    if shouldFinishAfterSuccess(
                        "success session=\(sessionId) suite=\(Self.sanitize(negotiatedSuite))"
                    ) {
                        return
                    }
                }
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

    private func codeURL() -> URL? {
        let fileName = ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_CODE_BASENAME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "skybridge-smoke-code.txt"
        guard !fileName.isEmpty else { return nil }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent(fileName)
    }

    private func writeGeneratedCode(_ code: String) {
        guard let codeURL = codeURL() else { return }
        guard let data = code.appending("\n").data(using: .utf8) else { return }
        try? writeProtectedData(data, to: codeURL)
    }

    private func pqcReportURL() -> URL? {
        guard let fileName = environmentValue("SKYBRIDGE_SMOKE_PQC_REPORT_BASENAME") else {
            return nil
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent(fileName)
    }

    private func resolvedLocalDeviceID() -> String {
        if let explicit = environmentValue("SKYBRIDGE_DEVICE_ID") {
            return explicit
        }
        return KeychainManager.shared.getOrGenerateDeviceId()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func decodeBase64Key(
        _ name: String,
        reporter: SmokeStatusReporter
    ) -> Data? {
        guard let raw = environmentValue(name) else { return nil }
        guard let data = Data(base64Encoded: raw, options: [.ignoreUnknownCharacters]), !data.isEmpty else {
            reporter.append("failed stage=pqc-preseed error=invalid_base64_\(name)")
            return nil
        }
        return data
    }

    private func preseedPeerKEMTrustIfNeeded(reporter: SmokeStatusReporter) async {
        guard let peerDeviceID = environmentValue("SKYBRIDGE_PQC_PEER_DEVICE_ID") else {
            return
        }

        var keysBySuite: [UInt16: KEMPublicKeyInfo] = [:]
        if let xwing = decodeBase64Key("SKYBRIDGE_PQC_PEER_XWING_PUBLIC_KEY_BASE64", reporter: reporter) {
            keysBySuite[Self.xwingSuiteWireID] = KEMPublicKeyInfo(
                suiteWireId: Self.xwingSuiteWireID,
                publicKey: xwing
            )
        }
        if let mlkem768 = decodeBase64Key("SKYBRIDGE_PQC_PEER_MLKEM768_PUBLIC_KEY_BASE64", reporter: reporter) {
            keysBySuite[Self.mlkem768SuiteWireID] = KEMPublicKeyInfo(
                suiteWireId: Self.mlkem768SuiteWireID,
                publicKey: mlkem768
            )
            if environmentValue("SKYBRIDGE_PQC_PEER_MLKEM768FS_PUBLIC_KEY_BASE64") == nil {
                keysBySuite[Self.mlkem768FSSuiteWireID] = KEMPublicKeyInfo(
                    suiteWireId: Self.mlkem768FSSuiteWireID,
                    publicKey: mlkem768
                )
            }
        }
        if let mlkem768fs = decodeBase64Key("SKYBRIDGE_PQC_PEER_MLKEM768FS_PUBLIC_KEY_BASE64", reporter: reporter) {
            keysBySuite[Self.mlkem768FSSuiteWireID] = KEMPublicKeyInfo(
                suiteWireId: Self.mlkem768FSSuiteWireID,
                publicKey: mlkem768fs
            )
        }

        let keys = keysBySuite.keys.sorted().compactMap { keysBySuite[$0] }
        guard !keys.isEmpty else {
            reporter.append("pqc-preseed skipped device=\(Self.sanitize(peerDeviceID)) reason=missing_keys")
            return
        }

        await KEMTrustStore.shared.upsert(deviceId: peerDeviceID, kemPublicKeys: keys)
        let suites = keys.map { String(format: "0x%04x", $0.suiteWireId) }.joined(separator: ",")
        reporter.append("pqc-preseed device=\(Self.sanitize(peerDeviceID)) suites=\(suites)")
    }

    private func exportLocalPQCIdentityIfNeeded(reporter: SmokeStatusReporter) async {
        guard let reportURL = pqcReportURL() else { return }

        struct LocalPQCReport: Encodable {
            struct PublicKeyEntry: Encodable {
                let suiteWireId: UInt16
                let publicKeyBase64: String
            }

            let deviceId: String
            let keys: [PublicKeyEntry]
        }

        do {
            let keys = try await P2PKEMIdentityKeyStore.shared.getOrCreateBootstrapPublicKeys()
            let report = LocalPQCReport(
                deviceId: resolvedLocalDeviceID(),
                keys: keys.map { key in
                    LocalPQCReport.PublicKeyEntry(
                        suiteWireId: key.suiteWireId,
                        publicKeyBase64: key.publicKey.base64EncodedString()
                    )
                }
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            try writeProtectedData(data, to: reportURL)
            reporter.append(
                "pqc-report device=\(Self.sanitize(report.deviceId)) keys=\(report.keys.count) file=\(reportURL.lastPathComponent)"
            )
        } catch {
            reporter.append("failed stage=pqc-report error=\(Self.sanitize(error.localizedDescription))")
        }
    }

    private func stopSmokeAudioReceiver() {
        CrossNetworkWebRTCManager.instance.smokeMediaHeartbeatDiagnosticsProvider = nil
        smokeAudioDiagnosticsTask?.cancel()
        smokeAudioDiagnosticsTask = nil
        smokeAudioRelayRenewalTask?.cancel()
        smokeAudioRelayRenewalTask = nil
        smokeAudioRelayKeepaliveTask?.cancel()
        smokeAudioRelayKeepaliveTask = nil
        if let transport = smokeAudioRelayTransport {
            Task(priority: .utility) {
                await transport.stop()
            }
        }
        if let receiver = smokeAudioReceiver {
            Task(priority: .utility) {
                await receiver.close()
            }
        }
        smokeAudioRelayTransport = nil
        smokeAudioReceiver = nil
    }

    private func installSmokeMediaHeartbeatDiagnosticsProvider(manager: CrossNetworkWebRTCManager) {
        manager.smokeMediaHeartbeatDiagnosticsProvider = { [weak self, weak manager] in
            guard let self, let manager else { return nil }
            let nativeSize = manager.remoteVideoTrackFrameSize
            let nativeWidth = nativeSize.width > 0 ? Int(nativeSize.width) : nil
            let nativeHeight = nativeSize.height > 0 ? Int(nativeSize.height) : nil
            let audio = await self.smokeAudioReceiver?.heartbeatDiagnosticSnapshot()
            return AppMessage.WebRTCMediaHeartbeatDiagnostics(
                nativeVideoRendered: manager.remoteVideoTrackHasRenderedFrame,
                nativeVideoWidth: nativeWidth,
                nativeVideoHeight: nativeHeight,
                audioRxDatagrams: audio?.datagramsSeen,
                audioRxRecv: audio?.received,
                audioRxDecoded: audio?.decoded,
                audioRxPlayed: audio?.played,
                audioRxRejected: audio?.rejected,
                audioRxAuthRejected: audio?.authRejected,
                audioRxSessionHashRejected: audio?.sessionHashRejected,
                audioRxReplayRejected: audio?.replayRejected,
                audioRxJitterEvicted: audio?.jitterEvicted,
                audioRxPlaybackDropped: audio?.playbackDropped,
                audioRenderedFrames: audio?.renderedFrames,
                audioUnderflow: audio?.underflowEvents,
                audioRebuffer: audio?.rebufferEvents,
                audioStartupSilenceFrames: audio?.startupSilenceFrames,
                audioEngineRunning: audio?.engineRunning
            )
        }
    }

    private func startSmokeAudioDiagnosticsHeartbeat(
        receiver: IOSRealtimeMediaAudioReceiver,
        sessionId: String
    ) {
        smokeAudioDiagnosticsTask?.cancel()
        smokeAudioDiagnosticsTask = Task { @MainActor [weak self, weak receiver] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: Self.audioDiagnosticsHeartbeatNanoseconds)
                } catch {
                    return
                }
                guard let self, let receiver else { return }
                let snapshot = await receiver.heartbeatDiagnosticSnapshot()
                guard snapshot.datagramsSeen == 0,
                      snapshot.received == 0,
                      snapshot.decoded == 0,
                      snapshot.played == 0 else {
                    continue
                }
                self.appendSmokeAudioDiagnosticsSnapshot(
                    snapshot,
                    sessionId: sessionId,
                    source: "smoke-heartbeat"
                )
            }
        }
    }

    private func appendSmokeAudioDiagnosticsSnapshot(
        _ snapshot: IOSRealtimeMediaAudioReceiverHeartbeatSnapshot,
        sessionId: String,
        source: String
    ) {
        let renderedFrames = snapshot.renderedFrames.map(String.init) ?? "-"
        let underflow = snapshot.underflowEvents.map(String.init) ?? "-"
        let rebuffer = snapshot.rebufferEvents.map(String.init) ?? "-"
        let startupSilenceFrames = snapshot.startupSilenceFrames.map(String.init) ?? "-"
        let engineRunning = snapshot.engineRunning.map { $0 ? "true" : "false" } ?? "-"
        let probableSuffix = snapshot.datagramsSeen == 0
            ? " probable=audio-rx-zero-datagrams"
            : ""
        let line = "audio-rx session=\(sessionId) source=\(source) "
            + "audioRxDatagrams=\(snapshot.datagramsSeen) "
            + "audioRxRecv=\(snapshot.received) "
            + "audioRxDecoded=\(snapshot.decoded) "
            + "audioRxPlayed=\(snapshot.played) "
            + "recvTotal=\(snapshot.received) "
            + "decodeTotal=\(snapshot.decoded) "
            + "playTotal=\(snapshot.played) "
            + "rejected=\(snapshot.rejected) "
            + "authRejected=\(snapshot.authRejected) "
            + "sessionHashRejected=\(snapshot.sessionHashRejected) "
            + "replayRejected=\(snapshot.replayRejected) "
            + "jitterEvicted=\(snapshot.jitterEvicted) "
            + "playbackDrop=\(snapshot.playbackDropped) "
            + "renderedFrames=\(renderedFrames) "
            + "underflow=\(underflow) "
            + "rebuffer=\(rebuffer) "
            + "startupSilenceFrames=\(startupSilenceFrames) "
            + "engineRunning=\(engineRunning)"
            + probableSuffix
        SkyBridgeSmokeTraceWriter.appendStatus(line)
        SkyBridgeSmokeTraceWriter.append(line)
        var diagnosticFields: [String: Any] = [
            "kind": "audioRxHeartbeat",
            "session": sessionId,
            "session_id": sessionId,
            "source": source,
            "audioRxDatagrams": snapshot.datagramsSeen,
            "audioRxRecv": snapshot.received,
            "audioRxDecoded": snapshot.decoded,
            "audioRxPlayed": snapshot.played,
            "recvTotal": snapshot.received,
            "decodeTotal": snapshot.decoded,
            "playTotal": snapshot.played,
            "rejected": snapshot.rejected,
            "authRejected": snapshot.authRejected,
            "sessionHashRejected": snapshot.sessionHashRejected,
            "replayRejected": snapshot.replayRejected,
            "jitterEvicted": snapshot.jitterEvicted,
            "playbackDrop": snapshot.playbackDropped
        ]
        if let renderedFrames = snapshot.renderedFrames {
            diagnosticFields["renderedFrames"] = renderedFrames
        }
        if let underflowEvents = snapshot.underflowEvents {
            diagnosticFields["underflow"] = underflowEvents
        }
        if let rebufferEvents = snapshot.rebufferEvents {
            diagnosticFields["rebuffer"] = rebufferEvents
        }
        if let startupSilenceFrames = snapshot.startupSilenceFrames {
            diagnosticFields["startupSilenceFrames"] = startupSilenceFrames
        }
        if let engineRunning = snapshot.engineRunning {
            diagnosticFields["engineRunning"] = engineRunning
        }
        if snapshot.datagramsSeen == 0 {
            diagnosticFields["probable"] = "audio-rx-zero-datagrams"
        }
        SkyBridgeSmokeTraceWriter.appendMediaDiagnostic(diagnosticFields)
    }

    private func startSmokeAudioRelayKeepalive(
        endpoint: SkyBridgeMediaEndpoint,
        transport: SkyBridgeUDPRealtimeMediaTransport,
        sessionId: String
    ) {
        smokeAudioRelayKeepaliveTask?.cancel()
        smokeAudioRelayKeepaliveTask = nil
        guard requiresAudio,
              let relayToken = endpoint.relayToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !relayToken.isEmpty else {
            return
        }
        let relay = "\(endpoint.host):\(endpoint.port)"
        smokeAudioRelayKeepaliveTask = Task { @MainActor [weak self, weak transport] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(Self.audioRelayKeepaliveIntervalSeconds * 1_000_000_000)
                    )
                } catch {
                    return
                }
                guard let self,
                      let transport,
                      self.smokeAudioRelayTransport === transport else {
                    return
                }
                do {
                    try await transport.refreshRelayBinding(relayToken)
                    SkyBridgeSmokeTraceWriter.append(
                        "audio-rx relayKeepaliveSent session=\(sessionId) relay=\(relay)"
                    )
                    SkyBridgeSmokeTraceWriter.appendMediaDiagnostic(
                        [
                            "kind": "audioRxRelayKeepaliveSent",
                            "session": sessionId,
                            "session_id": sessionId,
                            "relay": relay
                        ]
                    )
                } catch {
                    SkyBridgeSmokeTraceWriter.append(
                        "audio-rx relayKeepaliveFailed session=\(sessionId) relay=\(relay) error=\(Self.sanitize(error.localizedDescription))"
                    )
                    SkyBridgeSmokeTraceWriter.appendMediaDiagnostic(
                        [
                            "kind": "audioRxRelayKeepaliveFailed",
                            "session": sessionId,
                            "session_id": sessionId,
                            "relay": relay,
                            "error": Self.sanitize(error.localizedDescription)
                        ]
                    )
                }
            }
        }
    }

    private func makeSmokeViewerStreamConfigurationPayload(
        sessionId: String,
        mediaAudioEndpoint: SkyBridgeMediaEndpoint?
    ) -> RemoteDesktopStreamConfigurationPayload {
        let supportedFormats = RemoteDesktopManager.supportedRemoteVideoFormats()
            .filter { $0 != "jpeg" && $0 != "jpg" && $0 != "bgra" }
        let preferredCodec = supportedFormats.first {
            $0.caseInsensitiveCompare("hevc") == .orderedSame
                || $0.caseInsensitiveCompare("h264") == .orderedSame
        } ?? supportedFormats.first ?? "jpeg"
        let audioEnabled = requiresAudio
        let targetFrameRate = requestedSmokeTargetFrameRate
        let screenFrameTransport = "webrtc-native-main"
        let requestedVideoSize = requestedSmokeVideoSize
        return RemoteDesktopStreamConfigurationPayload(
            width: requestedVideoSize?.width,
            height: requestedVideoSize?.height,
            preferredCodec: preferredCodec,
            supportedVideoFormats: supportedFormats,
            qualityPreset: "fluid",
            adaptiveResolutionEnabled: requestedVideoSize == nil,
            targetFrameRate: targetFrameRate,
            keyFrameInterval: targetFrameRate,
            lowLatencyMode: requiresExtremeMediaValidation,
            enableHardwareAcceleration: true,
            enableAppleSiliconOptimization: true,
            clipboardSyncEnabled: false,
            damageTrackingEnabled: true,
            separateCursorChannelEnabled: true,
            interactionOverlayChannelEnabled: false,
            jitterBufferFrames: 2,
            screenFrameTransport: screenFrameTransport,
            screenDataChannelEnabled: false,
            nativeVideoTrackReady: false,
            nativeAudioTrackEnabled: false,
            audioRedirectionEnabled: audioEnabled,
            audioTransport: audioEnabled ? SkyBridgeRealtimeMediaConstants.audioTransportPQCv1 : "disabled",
            audioMode: "low-latency",
            mediaSessionId: sessionId,
            mediaAudioEndpoint: mediaAudioEndpoint,
            compatibilityAudioFallbackEnabled: false,
            preferredAudioEncoding: nil,
            audioSampleRate: 48_000,
            audioChannelCount: 2,
            performanceValidationMode: requiresExtremeMediaValidation ? "extreme" : nil,
            mediaFallbackPolicy: "forbidden",
            streamRefreshToken: UInt64(Date().timeIntervalSince1970 * 1_000)
        )
    }

    private func scheduleSmokeAudioRelayRenewal(
        manager: CrossNetworkWebRTCManager,
        sessionId: String,
        endpoint: SkyBridgeMediaEndpoint
    ) {
        smokeAudioRelayRenewalTask?.cancel()
        smokeAudioRelayRenewalTask = nil
        guard requiresAudio, let expiresAt = endpoint.expiresAt else { return }
        let nowSeconds = Date().timeIntervalSince1970
        let renewalLeadTime = requiresStrictAudioRelayRenewal
            ? max(Self.audioRelayRenewalLeadTime, 35)
            : Self.audioRelayRenewalLeadTime
        let delaySeconds = max(1, expiresAt - nowSeconds - renewalLeadTime)
        let delayMs = Int((delaySeconds * 1000).rounded())
        let expiresInMs = Int(((expiresAt - nowSeconds) * 1000).rounded())
        SkyBridgeSmokeTraceWriter.append(
            "audio-rx relayLeaseRenewalScheduled session=\(sessionId) delayMs=\(delayMs) relay=\(endpoint.host):\(endpoint.port)"
        )
        SkyBridgeSmokeTraceWriter.appendMediaDiagnostic(
            [
                "kind": "audioRxEndpointRenewalScheduled",
                "session": sessionId,
                "session_id": sessionId,
                "relay": "\(endpoint.host):\(endpoint.port)",
                "delayMs": delayMs,
                "expiresInMs": expiresInMs
            ]
        )
        smokeAudioRelayRenewalTask = Task { @MainActor [weak self, manager] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            } catch {
                return
            }
            await self?.renewSmokeAudioRelayEndpoint(
                manager: manager,
                sessionId: sessionId,
                currentEndpoint: endpoint
            )
        }
    }

    private func renewSmokeAudioRelayEndpoint(
        manager: CrossNetworkWebRTCManager,
        sessionId: String,
        currentEndpoint: SkyBridgeMediaEndpoint
    ) async {
        guard requiresAudio,
              let currentTransport = smokeAudioRelayTransport,
              let receiver = smokeAudioReceiver else {
            return
        }
        SkyBridgeSmokeTraceWriter.append(
            "audio-rx relayLeaseRenewalStart session=\(sessionId) relay=\(currentEndpoint.host):\(currentEndpoint.port)"
        )
        manager.clearCachedRealtimeMediaRelayEndpointForActiveSession(reason: "smoke-lease-renewal")
        let endpointPair: CrossNetworkWebRTCManager.RealtimeMediaRelayEndpointPair?
        do {
            endpointPair = try await manager.requestRealtimeMediaRelayEndpointForActiveSession()
        } catch {
            SkyBridgeSmokeTraceWriter.append(
                "audio-rx relayLeaseRenewalFailed session=\(sessionId) stage=lease error=\(Self.sanitize(error.localizedDescription))"
            )
            scheduleSmokeAudioRelayRenewal(manager: manager, sessionId: sessionId, endpoint: currentEndpoint)
            return
        }
        guard let endpointPair else {
            let reason = manager.mediaRelayLeaseDiagnosticForActiveSession() ?? "missing_endpoint"
            SkyBridgeSmokeTraceWriter.append(
                "audio-rx relayLeaseRenewalFailed session=\(sessionId) stage=lease reason=\(Self.sanitize(reason))"
            )
            if reason.hasPrefix("missingSession") {
                return
            }
            scheduleSmokeAudioRelayRenewal(manager: manager, sessionId: sessionId, endpoint: currentEndpoint)
            return
        }

        let newEndpoint = endpointPair.localEndpoint
        let sameRelayAddress = skyBridgeIsSameRealtimeMediaRelayAddress(currentEndpoint, newEndpoint)
        if !requiresStrictAudioRelayRenewal,
           sameRelayAddress,
           let relayToken = newEndpoint.relayToken,
           let currentTransport = smokeAudioRelayTransport {
            let bindPolicy = smokeAudioRelayRenewalBindPolicy
            let bindPolicyDescription: String
            switch bindPolicy {
            case .requireAcknowledgement:
                bindPolicyDescription = "require-ack"
            case .optimisticAfterSend:
                bindPolicyDescription = "optimistic"
            }
            SkyBridgeSmokeTraceWriter.append(
                "audio-rx relayLeaseRenewalInPlaceStart session=\(sessionId) relay=\(newEndpoint.host):\(newEndpoint.port) bindPolicy=\(bindPolicyDescription)"
            )
            SkyBridgeSmokeTraceWriter.appendMediaDiagnostic(
                [
                    "kind": "audioRxEndpointRenewalInPlaceStart",
                    "session": sessionId,
                    "session_id": sessionId,
                    "relay": "\(newEndpoint.host):\(newEndpoint.port)",
                    "bindPolicy": bindPolicyDescription,
                    "probable": "same-relay-token-rebind"
                ]
            )
            do {
                try await currentTransport.rebindRelayToken(
                    relayToken,
                    relayBindPolicy: bindPolicy
                )
                SkyBridgeSmokeTraceWriter.append(
                    "audio-rx relayLeaseRenewed session=\(sessionId) relay=\(newEndpoint.host):\(newEndpoint.port) mode=in-place bindPolicy=\(bindPolicyDescription)"
                )
                SkyBridgeSmokeTraceWriter.appendMediaDiagnostic(
                    [
                        "kind": "audioRxEndpointRenewed",
                        "session": sessionId,
                        "session_id": sessionId,
                        "relay": "\(newEndpoint.host):\(newEndpoint.port)",
                        "relayTokenPresent": true,
                        "bindPolicy": bindPolicyDescription,
                        "probable": bindPolicy == .requireAcknowledgement
                            ? "smoke-relay-lease-renewed-in-place-ack"
                            : "smoke-relay-lease-renewed-in-place"
                    ]
                )
                scheduleSmokeAudioRelayRenewal(manager: manager, sessionId: sessionId, endpoint: newEndpoint)
                startSmokeAudioRelayKeepalive(
                    endpoint: newEndpoint,
                    transport: currentTransport,
                    sessionId: sessionId
                )
                return
            } catch {
                SkyBridgeSmokeTraceWriter.append(
                    "audio-rx relayLeaseRenewalFallback session=\(sessionId) stage=in-place error=\(Self.sanitize(error.localizedDescription))"
                )
            }
        }
        if requiresStrictAudioRelayRenewal,
           sameRelayAddress {
            SkyBridgeSmokeTraceWriter.append(
                "audio-rx relayLeaseRenewalRollover session=\(sessionId) relay=\(newEndpoint.host):\(newEndpoint.port) reason=strict-make-before-break"
            )
            SkyBridgeSmokeTraceWriter.appendMediaDiagnostic(
                [
                    "kind": "audioRxEndpointRenewalRollover",
                    "session": sessionId,
                    "session_id": sessionId,
                    "relay": "\(newEndpoint.host):\(newEndpoint.port)",
                    "probable": "strict-make-before-break"
                ]
            )
        }
        let renewalTrafficCounter = SmokeAudioRelayTrafficCounter()
        let relayTransport = SkyBridgeUDPRealtimeMediaTransport(
            endpoint: newEndpoint,
            receiveHandler: { [receiver, renewalTrafficCounter] datagram in
                renewalTrafficCounter.increment()
                Task.detached(priority: .utility) {
                    await receiver.handle(datagram: datagram)
                }
            },
            relayBindPolicy: smokeAudioRelayRenewalBindPolicy,
            startEventHandler: { event in
                SkyBridgeSmokeTraceWriter.append(
                    "audio-rx renewalTransportEvent session=\(sessionId) event=\(Self.sanitize(String(describing: event)))"
                )
            }
        )
        do {
            try await relayTransport.start()
        } catch {
            SkyBridgeSmokeTraceWriter.append(
                "audio-rx relayLeaseRenewalFailed session=\(sessionId) stage=transport error=\(Self.sanitize(error.localizedDescription))"
            )
            scheduleSmokeAudioRelayRenewal(manager: manager, sessionId: sessionId, endpoint: currentEndpoint)
            return
        }

        SkyBridgeSmokeTraceWriter.append(
            "audio-rx relayLeaseRenewalRolloverReady session=\(sessionId) relay=\(newEndpoint.host):\(newEndpoint.port)"
        )
        SkyBridgeSmokeTraceWriter.appendMediaDiagnostic(
            [
                "kind": "audioRxEndpointRolloverReady",
                "session": sessionId,
                "session_id": sessionId,
                "relay": "\(newEndpoint.host):\(newEndpoint.port)",
                "relayTokenPresent": newEndpoint.relayToken != nil,
                "probable": "smoke-relay-rollover-transport-ready"
            ]
        )

        let payload = makeSmokeViewerStreamConfigurationPayload(
            sessionId: sessionId,
            mediaAudioEndpoint: newEndpoint
        )
        do {
            let encoded = try JSONEncoder().encode(payload)
            try await manager.sendRemoteDesktopMessage(
                RemoteMessage(type: .streamConfiguration, payload: encoded)
            )
            SkyBridgeSmokeTraceWriter.append(
                "stream-config audioRenewalSent session=\(sessionId) relay=\(newEndpoint.host):\(newEndpoint.port)"
            )
        } catch {
            SkyBridgeSmokeTraceWriter.append(
                "stream-config audioRenewalFailed session=\(sessionId) error=\(Self.sanitize(error.localizedDescription))"
            )
        }
        promoteSmokeAudioRelayTransportAfterNewTraffic(
            newTransport: relayTransport,
            oldTransport: currentTransport,
            trafficCounter: renewalTrafficCounter,
            manager: manager,
            sessionId: sessionId,
            currentEndpoint: currentEndpoint,
            newEndpoint: newEndpoint
        )
    }

    private func promoteSmokeAudioRelayTransportAfterNewTraffic(
        newTransport: SkyBridgeUDPRealtimeMediaTransport,
        oldTransport: SkyBridgeUDPRealtimeMediaTransport,
        trafficCounter: SmokeAudioRelayTrafficCounter,
        manager: CrossNetworkWebRTCManager,
        sessionId: String,
        currentEndpoint: SkyBridgeMediaEndpoint,
        newEndpoint: SkyBridgeMediaEndpoint
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(Self.audioRelayRolloverTrafficObservationTimeout)
            var observedTotal: UInt64 = 0
            var observedTraffic = false
            while Date() < deadline {
                observedTotal = trafficCounter.snapshot()
                if observedTotal >= Self.audioRelayRolloverMinimumObservedPackets {
                    observedTraffic = true
                    break
                }
                try? await Task.sleep(nanoseconds: Self.audioRelayRolloverTrafficObservationPollNanoseconds)
            }

            let relay = "\(newEndpoint.host):\(newEndpoint.port)"
            if observedTraffic {
                if self.smokeAudioRelayTransport === oldTransport {
                    self.smokeAudioRelayTransport = newTransport
                }
                SkyBridgeSmokeTraceWriter.append(
                    "audio-rx relayLeaseRenewalTrafficObserved session=\(sessionId) relay=\(relay) newTransportRecvTotal=\(observedTotal)"
                )
                SkyBridgeSmokeTraceWriter.appendMediaDiagnostic(
                    [
                        "kind": "audioRxEndpointRenewalTrafficObserved",
                        "session": sessionId,
                        "session_id": sessionId,
                        "relay": relay,
                        "newTransportRecvTotal": observedTotal
                    ]
                )
                self.scheduleSmokeAudioRelayRenewal(manager: manager, sessionId: sessionId, endpoint: newEndpoint)
                self.startSmokeAudioRelayKeepalive(
                    endpoint: newEndpoint,
                    transport: newTransport,
                    sessionId: sessionId
                )
                try? await Task.sleep(
                    nanoseconds: UInt64(Self.audioRelayRolloverGraceDelaySeconds * 1_000_000_000)
                )
                if self.smokeAudioRelayTransport !== oldTransport {
                    await oldTransport.stop()
                }
            } else {
                SkyBridgeSmokeTraceWriter.append(
                    "audio-rx relayLeaseRenewalTrafficMissing session=\(sessionId) relay=\(relay) newTransportRecvTotal=\(observedTotal)"
                )
                SkyBridgeSmokeTraceWriter.appendMediaDiagnostic(
                    [
                        "kind": "audioRxEndpointRenewalTrafficMissing",
                        "session": sessionId,
                        "session_id": sessionId,
                        "relay": relay,
                        "newTransportRecvTotal": observedTotal,
                        "probable": "smoke-relay-renewal-no-post-renewal-rx"
                    ]
                )
                await newTransport.stop()
                self.scheduleSmokeAudioRelayRenewal(
                    manager: manager,
                    sessionId: sessionId,
                    endpoint: currentEndpoint
                )
            }
        }
    }

    private func sendSmokeViewerStreamConfiguration(
        manager: CrossNetworkWebRTCManager,
        reporter: SmokeStatusReporter,
        sessionId: String
    ) async -> Bool {
        let mediaAudioEndpoint: SkyBridgeMediaEndpoint?
        if requiresAudio {
            var endpointPair: CrossNetworkWebRTCManager.RealtimeMediaRelayEndpointPair?
            for _ in 0..<20 {
                do {
                    endpointPair = try await manager.requestRealtimeMediaRelayEndpointForActiveSession()
                } catch {
                    reporter.append("stream-config failed stage=audio-relay error=\(Self.sanitize(error.localizedDescription))")
                    return false
                }
                if endpointPair != nil { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard let endpointPair else {
                let reason = manager.mediaRelayLeaseDiagnosticForActiveSession() ?? "missing_endpoint"
                reporter.append("stream-config failed stage=audio-relay error=\(Self.sanitize(reason))")
                return false
            }
            let localEndpoint = endpointPair.localEndpoint
            guard let snapshot = manager.realtimeMediaKeySnapshot() else {
                reporter.append("stream-config failed stage=audio-relay error=missing_media_keys")
                return false
            }
            do {
                let receiver = try IOSRealtimeMediaAudioReceiver(snapshot: snapshot, mode: .lowLatency)
                let relayTransport = SkyBridgeUDPRealtimeMediaTransport(
                    endpoint: localEndpoint,
                    receiveHandler: { [receiver] datagram in
                        Task.detached(priority: .utility) {
                            await receiver.handle(datagram: datagram)
                        }
                    },
                    relayBindPolicy: initialSmokeAudioRelayBindPolicy,
                    startEventHandler: { event in
                        SkyBridgeSmokeTraceWriter.append(
                            "audio-rx transportEvent session=\(sessionId) event=\(Self.sanitize(String(describing: event)))"
                        )
                    }
                )
                try await relayTransport.start()
                smokeAudioReceiver = receiver
                smokeAudioRelayTransport = relayTransport
                installSmokeMediaHeartbeatDiagnosticsProvider(manager: manager)
                startSmokeAudioDiagnosticsHeartbeat(receiver: receiver, sessionId: sessionId)
                SkyBridgeSmokeTraceWriter.append(
                    "audio-rx receiverStarted session=\(sessionId) relay=\(localEndpoint.host):\(localEndpoint.port)"
                )
                startSmokeAudioRelayKeepalive(
                    endpoint: localEndpoint,
                    transport: relayTransport,
                    sessionId: sessionId
                )
                scheduleSmokeAudioRelayRenewal(
                    manager: manager,
                    sessionId: sessionId,
                    endpoint: localEndpoint
                )
            } catch {
                reporter.append("stream-config failed stage=audio-receiver error=\(Self.sanitize(error.localizedDescription))")
                return false
            }
            mediaAudioEndpoint = localEndpoint
        } else {
            mediaAudioEndpoint = nil
        }
        let payload = makeSmokeViewerStreamConfigurationPayload(
            sessionId: sessionId,
            mediaAudioEndpoint: mediaAudioEndpoint
        )

        do {
            let encoded = try JSONEncoder().encode(payload)
            try await manager.sendRemoteDesktopMessage(
                RemoteMessage(type: .streamConfiguration, payload: encoded)
            )
            reporter.append(
                "stream-config preferred=\(payload.preferredCodec ?? "auto") formats=\(payload.supportedVideoFormats.joined(separator: ",")) size=\(payload.width.map(String.init) ?? "auto")x\(payload.height.map(String.init) ?? "auto") adaptive=\(payload.adaptiveResolutionEnabled == true ? 1 : 0) fps=\(payload.targetFrameRate) lowLatency=\(requiresExtremeMediaValidation ? 1 : 0) audio=\(requiresAudio ? 1 : 0) relay=\(mediaAudioEndpoint == nil ? 0 : 1)"
            )
            return true
        } catch {
            reporter.append(
                "stream-config failed error=\(Self.sanitize(error.localizedDescription))"
            )
            return false
        }
    }

    private nonisolated static func sanitize(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }
}

@available(iOS 17.0, *)
private struct SmokeStatusReporter {
    let statusURL: URL?

    func reset() {
        guard let statusURL else { return }
        try? writeProtectedData(Data(), to: statusURL)
    }

    func append(_ line: String) {
        guard let statusURL else { return }
        let formatted = "[\(ISO8601DateFormatter().string(from: Date()))] \(line)\n"
        guard let data = formatted.data(using: .utf8) else { return }
        if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
            try? FileHandle.standardOutput.write(contentsOf: data)
        }
        if FileManager.default.fileExists(atPath: statusURL.path),
           let handle = try? FileHandle(forWritingTo: statusURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? writeProtectedData(data, to: statusURL)
        }
    }
}

@available(iOS 17.0, *)
private func writeProtectedData(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: url.path
    )
}
