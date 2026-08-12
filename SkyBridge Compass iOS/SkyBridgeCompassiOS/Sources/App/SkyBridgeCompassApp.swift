import SwiftUI
import ActivityKit
import CryptoKit
#if os(iOS)
import UserNotifications
import UIKit
import Darwin
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

    private var isSmokeHarnessEnabled: Bool {
        LocalWebRTCSmokeHarness.shared.isEnabled || LocalP2PSmokeHarness.shared.isEnabled
    }

    private var shouldDisableAnimationsForUITests: Bool {
        ProcessInfo.processInfo.arguments.contains("UITEST_DISABLE_ANIMATIONS")
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
                            guard !shouldSkipInteractiveStartup, !isSmokeHarnessEnabled else { return }
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
        
        // 请求必要的权限
        if shouldSkipInteractiveStartup {
            SkyBridgeLogger.shared.info("🧪 Test host mode: 跳过交互式权限弹窗")
        } else if isSmokeHarnessEnabled {
            SkyBridgeLogger.shared.info("🧪 Local WebRTC smoke: 跳过交互式权限弹窗")
        } else {
            requestPermissions()
        }
        
        // 配置通知
        if !shouldSkipInteractiveStartup, !isSmokeHarnessEnabled {
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
        if isSmokeHarnessEnabled {
            SkyBridgeLogger.shared.info("🧪 Smoke harness mode: 仅启动显式 smoke 路径")
            await LocalP2PSmokeHarness.shared.startIfNeeded()
            await LocalWebRTCSmokeHarness.shared.startIfNeeded()
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
        guard !isSmokeHarnessEnabled else { return }
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

    private func environmentValue(_ name: String) -> String? {
        guard let raw = ProcessInfo.processInfo.environment[name] else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func startIfNeeded() async {
        guard isEnabled, !didStart else { return }
        didStart = true

        let reporter = SmokeStatusReporter(statusURL: statusURL())
        reporter.reset()
        guard await preseedPeerKEMTrustIfNeeded(reporter: reporter) else { return }

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
        var xwingStableSince: Date?

        while Date() < deadline {
            let handshakeState = connectionManager.currentHandshakeState
            if handshakeState != lastHandshakeState {
                lastHandshakeState = handshakeState
                reporter.append("state \(Self.sanitize(handshakeState))")
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

            if let target = selectedDevice {
                if let suite = connectionManager.getNegotiatedSuite(for: target.id)?.rawValue,
                   suite != lastSuite {
                    lastSuite = suite
                    reporter.append("suite \(Self.sanitize(suite))")

                    let normalizedSuite = suite.uppercased()
                    if normalizedSuite.contains("X25519") {
                        sawClassicHandshake = true
                        xwingStableSince = nil
                    } else if normalizedSuite == "X-WING" {
                        xwingStableSince = xwingStableSince ?? Date()
                    } else {
                        xwingStableSince = nil
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
                            reporter.append("success suite=X-Wing bootstrapRekey=1")
                            return
                        }
                    } else if normalizedSuite == "X-WING",
                              !sawRekey,
                              let stableSince = xwingStableSince,
                              Date().timeIntervalSince(stableSince) >= 1.0 {
                        reporter.append("success suite=X-Wing handshakeOnly=1")
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

    private func preseedPeerKEMTrustIfNeeded(reporter: SmokeStatusReporter) async -> Bool {
        guard let peerDeviceID = environmentValue("SKYBRIDGE_PQC_PEER_DEVICE_ID") else {
            return true
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
            reporter.append("failed stage=pqc-preseed error=missing_keys")
            return false
        }

        do {
            if smokeRequiresExistingTrustWithoutMutation {
                try await KEMTrustStore.shared.requireExactExisting(
                    deviceId: peerDeviceID,
                    kemPublicKeys: keys
                )
            } else {
                await KEMTrustStore.shared.upsert(deviceId: peerDeviceID, kemPublicKeys: keys)
            }
        } catch {
            reporter.append("failed stage=pqc-preseed error=existing_trust_mismatch")
            return false
        }
        let suites = keys.map { String(format: "0x%04x", $0.suiteWireId) }.joined(separator: ",")
        reporter.append(
            "pqc-preseed device=\(Self.sanitize(peerDeviceID)) suites=\(suites) mode=\(smokeRequiresExistingTrustWithoutMutation ? "existing-read-only" : "persistent")"
        )
        return true
    }

    private static func sanitize(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }

}

@available(iOS 17.0, *)
@MainActor
struct FormalInteropTerminalBinding: Equatable {
    let owner: CrossNetworkFileTransferSessionOwner
    let sessionID: String
    let negotiatedSuite: String
    let suiteWireID: String
    let selectedICE: WebRTCSession.SelectedICECandidateEvidence
    let peerDeviceID: String

    func validate(
        currentOwner: CrossNetworkFileTransferSessionOwner,
        currentSessionID: String,
        currentNegotiatedSuite: String,
        currentSuiteWireID: String,
        currentSelectedICE: WebRTCSession.SelectedICECandidateEvidence,
        currentPeerDeviceID: String?
    ) throws {
        guard currentOwner == owner,
              currentSessionID == sessionID,
              currentNegotiatedSuite == negotiatedSuite,
              currentSuiteWireID == suiteWireID,
              currentSelectedICE == selectedICE,
              currentPeerDeviceID?.trimmingCharacters(in: .whitespacesAndNewlines) == peerDeviceID else {
            throw FormalInteropFileTransferError.invalidBinding
        }
    }
}

@available(iOS 17.0, *)
@MainActor
enum FormalInteropCleanupAuthority: Equatable {
    case preparedOnly(runRef: String)
    case connection(runRef: String, CrossNetworkFormalInteropConnectionContext)
    case outbound(runRef: String, CrossNetworkFileTransferOutboundContext)

    var runRef: String {
        switch self {
        case .preparedOnly(let runRef),
             .connection(let runRef, _),
             .outbound(let runRef, _):
            return runRef
        }
    }
}

@available(iOS 17.0, *)
@MainActor
enum FormalInteropCleanupCoordinator {
    static func execute(
        authority: FormalInteropCleanupAuthority,
        quiesce: (FormalInteropCleanupAuthority) async throws -> Void,
        removeOwnedArtifacts: (FormalInteropCleanupAuthority) throws -> Void
    ) async throws {
        try await quiesce(authority)
        try removeOwnedArtifacts(authority)
    }
}

@available(iOS 17.0, *)
@MainActor
final class LocalWebRTCSmokeHarness {
    static let shared = LocalWebRTCSmokeHarness()
    private static let xwingSuiteWireID: UInt16 = 0x0001
    private static let mlkem768SuiteWireID: UInt16 = 0x0101
    private static let mlkem768FSSuiteWireID: UInt16 = 0x0102

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

    private var expectsBidirectionalFileTransfer: Bool {
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_EXPECT_BIDIRECTIONAL_FILE_TRANSFER"] == "1"
    }

    private func environmentValue(_ name: String) -> String? {
        guard let raw = ProcessInfo.processInfo.environment[name] else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func smokeRunRefForEvidence() throws -> String? {
        guard let value = environmentValue("SKYBRIDGE_SMOKE_RUN_REF") else {
            if smokeRequiresExistingTrustWithoutMutation {
                throw SmokeEvidenceError.invalidRunReference
            }
            return nil
        }
        guard value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw SmokeEvidenceError.invalidRunReference
        }
        return value
    }

    private func sessionRef(_ sessionID: String) -> String {
        SHA256.hash(data: Data(sessionID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private enum SmokeEvidenceError: Error {
        case invalidRunReference
    }

    private func existingSmokeIdentityMaterialDigest() async throws -> String {
        let identity = try await ExistingReadOnlyIdentityMaterialProvider.loadProtocolIdentity()
        let kemKeys = try await ExistingReadOnlyIdentityMaterialProvider.loadPQCIdentityPublicKeys()

        var canonical = Data("SkyBridge-Smoke-Identity-Material-v2\n".utf8)
        func appendField(_ name: String, _ value: Data) {
            canonical.append(Data("\(name):\(value.count):".utf8))
            canonical.append(value)
            canonical.append(0x0A)
        }
        appendField("device-id", Data(identity.deviceId.utf8))
        appendField(
            "protocol-signing-algorithm",
            Data(identity.protocolSigningAlgorithm.rawValue.utf8)
        )
        appendField("protocol-signing-public", identity.protocolPublicKey)
        for key in kemKeys.sorted(by: { $0.suiteWireId < $1.suiteWireId }) {
            appendField(String(format: "kem-public-%04x", key.suiteWireId), key.publicKey)
        }
        return Data(SHA256.hash(data: canonical)).map { String(format: "%02x", $0) }.joined()
    }

    func startIfNeeded() async {
        guard isEnabled, !didStart else { return }
        didStart = true

        let reporter = SmokeStatusReporter(statusURL: statusURL())
        reporter.reset()
        let smokeRunRef: String?
        do {
            smokeRunRef = try smokeRunRefForEvidence()
        } catch {
            reporter.append("failed stage=bootstrap error=invalid_run_reference")
            return
        }
        let existingIdentityDigest: String?
        if smokeRequiresExistingTrustWithoutMutation {
            do {
                let digest = try await existingSmokeIdentityMaterialDigest()
                existingIdentityDigest = digest
                reporter.append("identity-material phase=before digest=\(digest)")
            } catch {
                reporter.append("failed stage=identity-preflight error=missing_or_inconsistent_existing_identity")
                return
            }
        } else {
            existingIdentityDigest = nil
        }
        guard await exportLocalPQCIdentityIfNeeded(reporter: reporter) else { return }
        guard await preseedPeerKEMTrustIfNeeded(reporter: reporter) else { return }

        let manager = CrossNetworkWebRTCManager.instance
        await manager.disconnect()
        var formalCleanupAuthority: FormalInteropCleanupAuthority?
        if expectsBidirectionalFileTransfer {
            guard smokeRequiresExistingTrustWithoutMutation,
                  let runRef = smokeRunRef,
                  let androidToPeerTransferID = environmentValue(
                    "SKYBRIDGE_SMOKE_ANDROID_TO_PEER_TRANSFER_ID"
                  ),
                  let peerToAndroidTransferID = environmentValue(
                    "SKYBRIDGE_SMOKE_PEER_TO_ANDROID_TRANSFER_ID"
                  ) else {
                reporter.append("failed stage=file-transfer-bootstrap error=missing_formal_binding")
                return
            }
            do {
                try FileTransferManager.instance.prepareFormalInteropRun(
                    runRef: runRef,
                    androidToPeerTransferID: androidToPeerTransferID,
                    peerToAndroidTransferID: peerToAndroidTransferID
                )
                formalCleanupAuthority = .preparedOnly(runRef: runRef)
                reporter.append("file-transfer-run prepared runRef=\(runRef)")
            } catch {
                reporter.append("failed stage=file-transfer-bootstrap error=invalid_formal_binding")
                return
            }
        }

        switch role {
        case "ios-client":
            reporter.append("boot role=ios-client")
            guard !connectCode.isEmpty else {
                if let authority = formalCleanupAuthority {
                    _ = await cleanupFormalInteropRun(
                        manager: manager,
                        reporter: reporter,
                        authority: authority
                    )
                    formalCleanupAuthority = nil
                }
                reporter.append("failed stage=bootstrap error=missing_connect_code")
                return
            }
            reporter.append("connect <redacted>")
            await manager.connect(withCode: connectCode)
            if let preparedAuthority = formalCleanupAuthority {
                do {
                    formalCleanupAuthority = .connection(
                        runRef: preparedAuthority.runRef,
                        try manager.makeFormalInteropConnectionContext()
                    )
                } catch {
                    do {
                        try manager.requireNoActiveFormalInteropConnection()
                    } catch {
                        reporter.append(
                            "failed stage=file-transfer-cleanup error=connection_owner_unavailable"
                        )
                        return
                    }
                }
            }
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
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var lastState = ""
        var lastReadiness = ""
        var lastRekeyEvent = ""
        var heartbeatStarted = false
        var streamConfigurationSent = false
        var bidirectionalTransferStarted = false

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
                if let authority = formalCleanupAuthority {
                    _ = await cleanupFormalInteropRun(
                        manager: manager,
                        reporter: reporter,
                        authority: authority
                    )
                    formalCleanupAuthority = nil
                }
                reporter.append("failed stage=handshake error=\(Self.sanitize(message))")
                return
            }

            if case .handshakeComplete(let sessionId, let negotiatedSuite) = manager.readiness,
               !heartbeatStarted {
                heartbeatStarted = true
                reporter.append(
                    "handshake session=\(sessionId) suite=\(Self.sanitize(negotiatedSuite))"
                )
                if role == "ios-client" {
                    if !streamConfigurationSent {
                        streamConfigurationSent = await sendSmokeViewerStreamConfiguration(
                            manager: manager,
                            reporter: reporter
                        )
                    }
                    manager.startRemoteDesktopHeartbeat()
                }
            }

            if role == "ios-client", !expectsBidirectionalFileTransfer {
                let successDescriptor: (width: Int, height: Int, bytes: Int, transport: String)? = {
                    if let screenData = manager.lastScreenData {
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
                        reporter.append(
                            "success session=\(sessionId) suite=\(suiteLabel) bootstrapRekey=\(expectsPQCRekey ? 1 : 0) frame=\(successDescriptor.width)x\(successDescriptor.height) bytes=\(successDescriptor.bytes) transport=\(successDescriptor.transport)"
                        )
                        return
                    }
                }

                if let screenData = manager.lastScreenData {
                    reporter.append(
                        "success frame=\(screenData.width)x\(screenData.height) bytes=\(screenData.imageData.count) transport=fallback-screen"
                    )
                    return
                }

                let nativeFrameSize = manager.remoteVideoTrackFrameSize
                if manager.remoteVideoTrackHasRenderedFrame,
                   nativeFrameSize.width > 0,
                   nativeFrameSize.height > 0 {
                    reporter.append(
                        "success frame=\(Int(nativeFrameSize.width))x\(Int(nativeFrameSize.height)) bytes=0 transport=webrtc-native"
                    )
                    return
                }

                if manager.remoteVideoTrackReadyForPromotion,
                   nativeFrameSize.width > 0,
                   nativeFrameSize.height > 0 {
                    reporter.append(
                        "success frame=\(Int(nativeFrameSize.width))x\(Int(nativeFrameSize.height)) bytes=0 transport=webrtc-native-ready"
                    )
                    return
                }
            }

            if role == "ios-client",
               !expectsBidirectionalFileTransfer,
               expectsPQCRekey,
               case .handshakeComplete(let sessionId, let negotiatedSuite) = manager.readiness,
               negotiatedSuite.caseInsensitiveCompare("X-Wing") == .orderedSame,
               let rekeyDescription = manager.lastRekeyEvent,
               rekeyDescription.caseInsensitiveCompare("complete suite=X-Wing") == .orderedSame {
                reporter.append(
                    "success session=\(sessionId) suite=\(Self.sanitize(negotiatedSuite)) bootstrapRekey=1"
                )
                return
            }

            if role == "ios-client",
               expectsBidirectionalFileTransfer,
               !bidirectionalTransferStarted,
               case .handshakeComplete(let sessionId, let negotiatedSuite) = manager.readiness {
                bidirectionalTransferStarted = true
                let canonicalSuiteWireID = Self.canonicalSuiteWireID(negotiatedSuite)
                guard canonicalSuiteWireID == "0x0101",
                      let runRef = smokeRunRef,
                      let androidToPeerTransferID = environmentValue(
                        "SKYBRIDGE_SMOKE_ANDROID_TO_PEER_TRANSFER_ID"
                      ),
                      let peerToAndroidTransferID = environmentValue(
                        "SKYBRIDGE_SMOKE_PEER_TO_ANDROID_TRANSFER_ID"
                      ),
                      let expectedPeerDeviceID = environmentValue(
                        "SKYBRIDGE_PQC_PEER_DEVICE_ID"
                      ) else {
                    if let authority = formalCleanupAuthority {
                        _ = await cleanupFormalInteropRun(
                            manager: manager,
                            reporter: reporter,
                            authority: authority
                        )
                        formalCleanupAuthority = nil
                    }
                    reporter.append("failed stage=file-transfer error=formal_binding_or_suite_mismatch")
                    return
                }
                let sessionRef = sessionRef(sessionId)
                do {
                    let outboundContext = try manager.makeFileTransferOutboundContext()
                    formalCleanupAuthority = .outbound(
                        runRef: runRef,
                        outboundContext
                    )
                    try FileTransferManager.instance.bindFormalInteropSession(
                        sessionRef: sessionRef,
                        owner: outboundContext.owner
                    )
                    let selectedICE = try await manager.formalSelectedICECandidateEvidence(
                        requiredOwner: outboundContext.owner
                    )
                    let terminalBinding = FormalInteropTerminalBinding(
                        owner: outboundContext.owner,
                        sessionID: sessionId,
                        negotiatedSuite: negotiatedSuite,
                        suiteWireID: canonicalSuiteWireID,
                        selectedICE: selectedICE,
                        peerDeviceID: expectedPeerDeviceID
                    )
                    let evidence = try await runBidirectionalFormalFileTransfer(
                        runRef: runRef,
                        sessionRef: sessionRef,
                        androidToPeerTransferID: androidToPeerTransferID,
                        peerToAndroidTransferID: peerToAndroidTransferID,
                        expectedPeerDeviceID: expectedPeerDeviceID,
                        timeoutSeconds: timeoutSeconds
                    )
                    let selectedICEAfter = try await manager.formalSelectedICECandidateEvidence(
                        requiredOwner: outboundContext.owner
                    )
                    guard selectedICEAfter == selectedICE else {
                        throw FormalInteropFileTransferError.invalidBinding
                    }
                    let holdSeconds = min(
                        30,
                        max(
                            1,
                            Double(
                                ProcessInfo.processInfo.environment[
                                    "SKYBRIDGE_SMOKE_HOLD_AFTER_SUCCESS_SECONDS"
                                ] ?? ""
                            ) ?? 5
                        )
                    )
                    try await Task.sleep(for: .seconds(holdSeconds))
                    try manager.validateFileTransferOutboundContext(outboundContext)
                    let terminalOutboundContext = try manager.makeFileTransferOutboundContext()
                    let terminalSelectedICE = try await manager.formalSelectedICECandidateEvidence(
                        requiredOwner: outboundContext.owner
                    )
                    guard case .handshakeComplete(
                            let terminalSessionID,
                            let terminalNegotiatedSuite
                          ) = manager.readiness else {
                        throw FormalInteropFileTransferError.invalidBinding
                    }
                    try terminalBinding.validate(
                        currentOwner: terminalOutboundContext.owner,
                        currentSessionID: terminalSessionID,
                        currentNegotiatedSuite: terminalNegotiatedSuite,
                        currentSuiteWireID: Self.canonicalSuiteWireID(terminalNegotiatedSuite),
                        currentSelectedICE: terminalSelectedICE,
                        currentPeerDeviceID: manager.remoteDeviceId
                    )
                    try manager.validateFormalFileTransferPeer(
                        requiredOwner: outboundContext.owner,
                        expectedDeviceID: expectedPeerDeviceID
                    )
                    guard let cleanupAuthority = formalCleanupAuthority,
                          await cleanupFormalInteropRun(
                        manager: manager,
                        reporter: reporter,
                        authority: cleanupAuthority
                    ) else {
                        formalCleanupAuthority = nil
                        reporter.append("failed stage=file-transfer-cleanup error=run_owned_cleanup_failed")
                        return
                    }
                    formalCleanupAuthority = nil
                    if let existingIdentityDigest {
                        let afterDigest = try await existingSmokeIdentityMaterialDigest()
                        guard afterDigest == existingIdentityDigest else {
                            reporter.append("failed stage=identity-freeze error=identity_material_changed")
                            return
                        }
                        reporter.append("identity-material phase=after digest=\(afterDigest)")
                    }
                    reporter.append(
                        "success session_ref=\(sessionRef) "
                            + "runRef=\(runRef) "
                            + "suite=\(Self.sanitize(negotiatedSuite)) "
                            + "suiteWireId=\(canonicalSuiteWireID) "
                            + "selectedIceRoute=\(selectedICE.route) "
                            + "selectedIceLocalType=\(selectedICE.localCandidateType) "
                            + "selectedIceRemoteType=\(selectedICE.remoteCandidateType) "
                            + "selectedIceProtocol=\(selectedICE.networkProtocol) "
                            + "handshakeOnly=0 bidirectionalFileTransfer=true "
                            + "androidToPeerTransferId=\(androidToPeerTransferID) "
                            + "androidToPeerBytes=\(evidence.androidToPeerBytes) "
                            + "androidToPeerSha256=\(evidence.androidToPeerSHA256) "
                            + "androidToPeerDurableStorage=caches "
                            + "androidToPeerCompleteAck=true "
                            + "peerToAndroidTransferId=\(peerToAndroidTransferID) "
                            + "peerToAndroidBytes=\(evidence.peerToAndroidBytes) "
                            + "peerToAndroidSha256=\(evidence.peerToAndroidSHA256) "
                            + "peerToAndroidCompleteAck=true "
                            + "iosRunOwnedPayloadCleaned=true"
                    )
                    return
                } catch {
                    if let authority = formalCleanupAuthority {
                        _ = await cleanupFormalInteropRun(
                            manager: manager,
                            reporter: reporter,
                            authority: authority
                        )
                        formalCleanupAuthority = nil
                    }
                    reporter.append("failed stage=file-transfer error=bidirectional_transfer_failed")
                    return
                }
            }

            if role == "ios-client",
               expectsHandshakeOnly,
               !expectsBidirectionalFileTransfer,
               case .handshakeComplete(let sessionId, let negotiatedSuite) = manager.readiness {
                if let existingIdentityDigest {
                    do {
                        let afterDigest = try await existingSmokeIdentityMaterialDigest()
                        guard afterDigest == existingIdentityDigest else {
                            reporter.append("failed stage=identity-freeze error=identity_material_changed")
                            return
                        }
                        reporter.append("identity-material phase=after digest=\(afterDigest)")
                    } catch {
                        reporter.append("failed stage=identity-freeze error=identity_material_unreadable")
                        return
                    }
                }
                reporter.append(
                    "success session_ref=\(sessionRef(sessionId)) "
                        + "runRef=\(smokeRunRef ?? "diagnostic-unbound") "
                        + "suite=\(Self.sanitize(negotiatedSuite)) "
                        + "suiteWireId=\(Self.canonicalSuiteWireID(negotiatedSuite)) handshakeOnly=1"
                )
                return
            }

            if role == "ios-host",
               case .handshakeComplete(let sessionId, let negotiatedSuite) = manager.readiness {
                if expectsPQCRekey {
                    if let rekeyDescription = manager.lastRekeyEvent,
                       rekeyDescription.starts(with: "complete suite=") {
                        reporter.append(
                            "success session=\(sessionId) suite=\(Self.sanitize(negotiatedSuite)) rekey=\(Self.sanitize(rekeyDescription))"
                        )
                        return
                    }
                } else {
                    reporter.append(
                        "success session=\(sessionId) suite=\(Self.sanitize(negotiatedSuite))"
                    )
                    return
                }
            }

            try? await Task.sleep(for: .milliseconds(250))
        }

        if let authority = formalCleanupAuthority {
            _ = await cleanupFormalInteropRun(
                manager: manager,
                reporter: reporter,
                authority: authority
            )
            formalCleanupAuthority = nil
        }
        reporter.append("failed stage=timeout error=ios_smoke_timeout")
    }

    private func cleanupFormalInteropRun(
        manager: CrossNetworkWebRTCManager,
        reporter: SmokeStatusReporter,
        authority: FormalInteropCleanupAuthority
    ) async -> Bool {
        do {
            try await FormalInteropCleanupCoordinator.execute(
                authority: authority,
                quiesce: { authority in
                    switch authority {
                    case .preparedOnly:
                        try manager.requireNoActiveFormalInteropConnection()
                    case .connection(_, let context):
                        try await manager.disconnectFormalInteropSession(
                            requiredContext: context
                        )
                    case .outbound(_, let context):
                        try await manager.disconnectFormalInteropSession(
                            requiredOwner: context.owner
                        )
                    }
                },
                removeOwnedArtifacts: { authority in
                    switch authority {
                    case .preparedOnly(let runRef), .connection(let runRef, _):
                        try FileTransferManager.instance
                            .cleanupPreparedFormalInteropRunOwnedArtifacts(runRef: runRef)
                    case .outbound(let runRef, let context):
                        try FileTransferManager.instance
                            .cleanupQuiescedFormalInteropRunOwnedArtifacts(
                                runRef: runRef,
                                requiredOwner: context.owner
                            )
                    }
                }
            )
            reporter.append("file-transfer-cleanup outcome=run-owned-only")
            return true
        } catch {
            reporter.append("file-transfer-cleanup outcome=failed")
            return false
        }
    }

    private struct BidirectionalFileTransferEvidence {
        let androidToPeerBytes: Int
        let androidToPeerSHA256: String
        let peerToAndroidBytes: Int
        let peerToAndroidSHA256: String
    }

    private func runBidirectionalFormalFileTransfer(
        runRef: String,
        sessionRef: String,
        androidToPeerTransferID: String,
        peerToAndroidTransferID: String,
        expectedPeerDeviceID: String,
        timeoutSeconds: Double
    ) async throws -> BidirectionalFileTransferEvidence {
        let inboundPayload = try FileTransferManager.formalInteropPayload(
            direction: "android-to-peer",
            runRef: runRef,
            sessionRef: sessionRef,
            transferID: androidToPeerTransferID
        )
        let inboundName = FileTransferManager.formalInteropFileName(
            direction: "android-to-peer",
            runRef: runRef
        )
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var inboundURL: URL?
        while Date() < deadline {
            if let completed = try FileTransferManager.instance
                .formalInteropInboundCompletionURL(transferID: androidToPeerTransferID) {
                inboundURL = completed
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let inboundURL,
              inboundURL.lastPathComponent == inboundName else {
            throw FormalInteropFileTransferError.invalidBinding
        }
        let inboundValues = try inboundURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard inboundValues.isRegularFile == true,
              inboundValues.isSymbolicLink != true else {
            throw FormalInteropFileTransferError.invalidBinding
        }
        let committedInbound = try Data(contentsOf: inboundURL, options: .mappedIfSafe)
        guard committedInbound == inboundPayload else {
            throw FormalInteropFileTransferError.invalidBinding
        }
        let inboundDigest = Data(SHA256.hash(data: committedInbound))

        let outboundPayload = try FileTransferManager.formalInteropPayload(
            direction: "peer-to-android",
            runRef: runRef,
            sessionRef: sessionRef,
            transferID: peerToAndroidTransferID
        )
        let outboundName = FileTransferManager.formalInteropFileName(
            direction: "peer-to-android",
            runRef: runRef
        )
        let outboundEvidence = try await FileTransferManager.instance
            .createAndSendFormalInteropPayload(
                outboundPayload,
                transferID: peerToAndroidTransferID,
                fileName: outboundName,
                expectedPeerDeviceID: expectedPeerDeviceID
            )
        guard outboundEvidence.bytes == outboundPayload.count,
              outboundEvidence.sha256 == Data(SHA256.hash(data: outboundPayload)) else {
            throw FormalInteropFileTransferError.invalidBinding
        }
        return BidirectionalFileTransferEvidence(
            androidToPeerBytes: committedInbound.count,
            androidToPeerSHA256: inboundDigest.map { String(format: "%02x", $0) }.joined(),
            peerToAndroidBytes: outboundEvidence.bytes,
            peerToAndroidSHA256: outboundEvidence.sha256
                .map { String(format: "%02x", $0) }
                .joined()
        )
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
        if smokeRequiresExistingTrustWithoutMutation {
            return KeychainManager.shared.loadDeviceId() ?? ""
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

    private func preseedPeerKEMTrustIfNeeded(reporter: SmokeStatusReporter) async -> Bool {
        guard let peerDeviceID = environmentValue("SKYBRIDGE_PQC_PEER_DEVICE_ID") else {
            return true
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
            reporter.append("failed stage=pqc-preseed error=missing_keys")
            return false
        }

        do {
            if smokeRequiresExistingTrustWithoutMutation {
                try await KEMTrustStore.shared.requireExactExisting(
                    deviceId: peerDeviceID,
                    kemPublicKeys: keys
                )
            } else {
                await KEMTrustStore.shared.upsert(deviceId: peerDeviceID, kemPublicKeys: keys)
            }
        } catch {
            reporter.append("failed stage=pqc-preseed error=existing_trust_mismatch")
            return false
        }
        let suites = keys.map { String(format: "0x%04x", $0.suiteWireId) }.joined(separator: ",")
        reporter.append(
            "pqc-preseed device=\(Self.sanitize(peerDeviceID)) suites=\(suites) mode=\(smokeRequiresExistingTrustWithoutMutation ? "existing-read-only" : "persistent")"
        )
        return true
    }

    private func exportLocalPQCIdentityIfNeeded(reporter: SmokeStatusReporter) async -> Bool {
        guard let reportURL = pqcReportURL() else { return true }

        struct LocalPQCReport: Encodable {
            struct PublicKeyEntry: Encodable {
                let suiteWireId: UInt16
                let publicKeyBase64: String
            }

            let deviceId: String
            let keys: [PublicKeyEntry]
        }

        do {
            let deviceId: String
            let keys: [KEMPublicKeyInfo]
            if smokeRequiresExistingTrustWithoutMutation {
                let identity = try await ExistingReadOnlyIdentityMaterialProvider.loadProtocolIdentity()
                deviceId = identity.deviceId
                keys = try await ExistingReadOnlyIdentityMaterialProvider.loadPQCIdentityPublicKeys()
            } else {
                deviceId = resolvedLocalDeviceID()
                keys = try await P2PKEMIdentityKeyStore.shared.getOrCreateBootstrapPublicKeys()
            }
            let report = LocalPQCReport(
                deviceId: deviceId,
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
            return true
        } catch {
            reporter.append("failed stage=pqc-report error=\(Self.sanitize(error.localizedDescription))")
            return false
        }
    }

    private func sendSmokeViewerStreamConfiguration(
        manager: CrossNetworkWebRTCManager,
        reporter: SmokeStatusReporter
    ) async -> Bool {
        let supportedFormats = RemoteDesktopManager.supportedRemoteVideoFormats()
        let preferredCodec = supportedFormats.first {
            $0.caseInsensitiveCompare("hevc") == .orderedSame
                || $0.caseInsensitiveCompare("h264") == .orderedSame
        } ?? supportedFormats.first ?? "jpeg"

        let payload = RemoteDesktopStreamConfigurationPayload(
            preferredCodec: preferredCodec,
            supportedVideoFormats: supportedFormats,
            qualityPreset: "fluid",
            adaptiveResolutionEnabled: true,
            targetFrameRate: 30,
            keyFrameInterval: 30,
            lowLatencyMode: false,
            enableHardwareAcceleration: true,
            enableAppleSiliconOptimization: true,
            clipboardSyncEnabled: false,
            damageTrackingEnabled: true,
            separateCursorChannelEnabled: true,
            interactionOverlayChannelEnabled: true,
            jitterBufferFrames: 2,
            screenFrameTransport: "webrtc-native-main+sbrf-fallback",
            screenDataChannelEnabled: false,
            nativeVideoTrackReady: false,
            streamRefreshToken: UInt64(Date().timeIntervalSince1970 * 1_000)
        )

        do {
            let encoded = try JSONEncoder().encode(payload)
            try await manager.sendRemoteDesktopMessage(
                RemoteMessage(type: .streamConfiguration, payload: encoded)
            )
            reporter.append(
                "stream-config preferred=\(preferredCodec) formats=\(supportedFormats.joined(separator: ","))"
            )
            return true
        } catch {
            reporter.append(
                "stream-config failed error=\(Self.sanitize(error.localizedDescription))"
            )
            return false
        }
    }

    private static func sanitize(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }

    static func canonicalSuiteWireID(_ suiteLabel: String) -> String {
        let suite = suiteLabel.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        switch suite {
        case "X-WING": return "0x0001"
        case "ML-KEM-768": return "0x0101"
        case "ML-KEM-768-FS": return "0x0102"
        case "X25519": return "0x1001"
        case "P-256": return "0x1002"
        default: return "unknown"
        }
    }
}

private var smokeRequiresExistingTrustWithoutMutation: Bool {
    ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil
        && ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_EXISTING_TRUST_ONLY"] == "1"
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
