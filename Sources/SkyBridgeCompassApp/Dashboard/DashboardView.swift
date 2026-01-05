import SwiftUI
import Charts
import SkyBridgeCore
import SkyBridgeUI
#if canImport(OrderedCollections)
import OrderedCollections
#endif
import os.log
import OSLog
import os.lock
import Network
import UniformTypeIdentifiers
import QuartzCore

private let dashboardLogger = Logger(subsystem: "com.skybridge.SkyBridgeCompassApp", category: "Dashboard")

/// 主仪表盘界面，展示来自真实环境的遥测信息与操作入口。
/// 重构后的精简版本，主要负责布局和协调子视图
@available(macOS 14.0, *)
@MainActor
public struct DashboardView: View {
 // MARK: - 状态管理优化 - 使用最佳实践避免不必要的视图更新
    
 // 核心应用状态 - 使用@EnvironmentObject确保全局状态一致性
    @EnvironmentObject var appModel: DashboardViewModel
    @EnvironmentObject var authModel: AuthenticationViewModel
    @EnvironmentObject var themeConfiguration: ThemeConfiguration
    
 // 天气服务 - 使用@EnvironmentObject确保全局状态一致性
    @EnvironmentObject var weatherLocationService: WeatherLocationService
    @EnvironmentObject var weatherDataService: WeatherDataService
    @EnvironmentObject var weatherManager: WeatherIntegrationManager
    @EnvironmentObject var weatherSettings: WeatherEffectsSettings
    
 // 多语言管理器
    @ObservedObject private var localizationManager = LocalizationManager.shared
    
 // 实时天气服务状态
    @StateObject private var realTimeWeatherService = RealTimeWeatherService.shared
    
 // 雾霾交互管理器
    @StateObject private var hazeClearManager = InteractiveClearManager()
    
 // 数据服务
    @StateObject private var dataService = DashboardDataService()
    
 // ✅ 性能监控器 - 通过PerformanceModeManager获取真实的系统性能数据
    @State private var performanceModeManager: PerformanceModeManager?
    @State private var systemPerformanceMonitor: SystemPerformanceMonitor?
    
 // 本地UI状态 - 使用@State管理组件内部状态
    @State private var selectedSession: RemoteSessionSummary?
    @State private var selectedNavigation: NavigationItem = .dashboard
    @State private var showingUserProfile = false
    @State private var showingUserProfileOverlay = false
    @State private var signalSortTimerEnabled = false
    
 // 设备发现界面优化状态
    @State private var deviceSearchText = ""
    @State private var filteredDevices: [DiscoveredDevice] = []
    @State private var isSearching = false
    @State private var extendedSearchCountdown: Int = 0
    
 // 手动连接输入弹窗状态与字段
    @State private var showManualConnectSheet: Bool = false
    @State private var manualIP: String = ""
    @State private var manualPort: String = "11550"
    @State private var manualCode: String = ""
    
 // FPS显示
    @State private var realtimeFPS: String = ""
    @State private var fpsTimer: Timer?
    @State private var frameCount: Int = 0
    @State private var lastFPSUpdate: CFTimeInterval = 0
    
 // 应用前后台与窗口可见性监听器
    @State private var appDidBecomeActiveObserver: Any?
    @State private var appDidResignActiveObserver: Any?
    @State private var windowOcclusionObserver: Any?
    @State private var windowMiniObserver: Any?
    @State private var windowDeminiObserver: Any?
    @State private var wasPausedByInactive: Bool = false
    @State private var wasPausedByOcclusion: Bool = false
    
    private let logger = Logger(subsystem: "com.skybridge.SkyBridgeCompassApp", category: "Dashboard")
    
    public init() {}
    
    public var body: some View {
        ZStack {
 // 背景视图（主题 + 天气效果）
            DashboardBackgroundView(hazeClearManager: hazeClearManager)
            
            NavigationSplitView {
 // 侧边栏
                GlassSidebar(selectedTab: Binding(
                    get: {
                        SidebarTab(
                            id: selectedNavigation.rawValue,
                            title: selectedNavigation.rawValue,
                            icon: selectedNavigation.icon,
                            color: selectedNavigation.color
                        )
                    },
                    set: { newTab in
                        if let navigationItem = NavigationItem.allCases.first(where: { $0.rawValue == newTab.id }) {
                            DispatchQueue.main.async { [navigationItem] in
                                selectedNavigation = navigationItem
                            }
                        }
                    }
                ))
                .opacity(themeConfiguration.glassOpacity)
                .onReceive(NotificationCenter.default.publisher(for: .init("ShowUserProfile"))) { _ in
                    DispatchQueue.main.async {
                        showingUserProfileOverlay = true
                    }
                }
            } detail: {
                VStack(spacing: 0) {
 // 顶部导航栏
                    TopNavigationBarView(
                        showManualConnectSheet: $showManualConnectSheet,
                        manualIP: $manualIP,
                        manualPort: $manualPort,
                        manualCode: $manualCode,
                        realtimeFPS: $realtimeFPS
                    )
                    
 // 主内容区域
                    mainContent
                        .padding(.horizontal, 32)
                        .padding(.vertical, 24)
                        .background(Color.clear)
                }
            }
            .navigationSplitViewStyle(.prominentDetail)
            .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 400)
            .task {
 // 🚀 启动天气系统
                if !weatherManager.isInitialized {
                    await weatherManager.start()
                }
                
 // 🔍 初始化设备列表
                await filterDevices(with: deviceSearchText)
                
 // ✅ 初始化性能监控系统
                await initializePerformanceMonitoring()
            }
            .onReceive(appModel.$discoveredDevices
                .removeDuplicates()
                .throttle(for: .milliseconds(150), scheduler: DispatchQueue.main, latest: true)
            ) { devices in
                if deviceSearchText.isEmpty {
                    filteredDevices = mapOnlineToDiscovered(appModel.onlineDevices)
                } else {
                    Task { @MainActor in
                        await filterDevices(with: deviceSearchText)
                    }
                }
            }
            
 // 用户资料覆盖层
            if showingUserProfileOverlay {
                UserProfileOverlay(isPresented: $showingUserProfileOverlay)
                    .environmentObject(authModel)
                    .environmentObject(themeConfiguration)
                    .zIndex(1000)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
                    .animation(.spring(response: 0.6, dampingFraction: 0.8), value: showingUserProfileOverlay)
            }
        }
        .animation(themeConfiguration.springAnimation, value: themeConfiguration.currentTheme)
        .animation(themeConfiguration.easeAnimation, value: themeConfiguration.backgroundIntensity)
        .animation(themeConfiguration.easeAnimation, value: themeConfiguration.glassOpacity)
        .onReceive(NotificationCenter.default.publisher(for: GlobalMouseTracker.mouseMovedNotification)) { notification in
            if let locationValue = notification.userInfo?["location"] as? NSValue {
                let pt = locationValue.pointValue
                let flipped = CGPoint(x: pt.x, y: pt.y)
                hazeClearManager.handleMouseMove(flipped)
            }
        }
        .onReceive(Timer.publish(every: 30.0, on: .main, in: .common).autoconnect()) { _ in
            guard signalSortTimerEnabled else { return }
            guard !filteredDevices.isEmpty else { return }
            filteredDevices = sortDevicesBySignalStrength(filteredDevices)
        }
        .task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await dataService.loadDashboardDataOptimized()
                }
                group.addTask {
                    await appModel.start()
                }
            }
        }
        .onDisappear {
            appModel.stop()
            weatherDataService.stopWeatherUpdates()
            weatherLocationService.stopLocationUpdates()
            removeNotificationObservers()
            stopFPSMonitor()
        }
        .onAppear {
            setupOnAppear()
        }
        .onChange(of: weatherLocationService.authorizationStatus) { _, _ in
            if weatherLocationService.isLocationAuthorized {
                weatherLocationService.startLocationUpdates()
            } else {
                weatherDataService.stopWeatherUpdates()
            }
        }
        .onReceive(weatherLocationService.$currentLocation.compactMap { $0 }) { location in
            weatherDataService.startWeatherUpdates(for: location)
        }
    }
    
 // MARK: - Main Content
    
    private var mainContent: some View {
        Group {
            switch selectedNavigation {
            case .dashboard:
                ScrollView {
                    LazyVStack(spacing: 24) {
                        DashboardContentView(
                            selectedNavigation: $selectedNavigation,
                            selectedSession: $selectedSession,
                            deviceSearchText: $deviceSearchText,
                            filteredDevices: $filteredDevices,
                            isSearching: $isSearching,
                            showManualConnectSheet: $showManualConnectSheet,
                            extendedSearchCountdown: $extendedSearchCountdown,
                            systemPerformanceMonitor: $systemPerformanceMonitor
                        )
                    }
                    .padding(.bottom, 32)
                }
                .scrollIndicators(.hidden)
            case .deviceManagement:
                EnhancedDeviceDiscoveryView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .scrollIndicators(.hidden)
            case .usbDeviceManagement:
                USBDeviceManagementView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .fileTransfer:
                FileTransferView()
            case .remoteDesktop:
                RemoteDesktopView()
            case .quantumCommunication:
                EmptyStateView(title: LocalizationManager.shared.localizedString("quantum.title"),
                               subtitle: LocalizationManager.shared.localizedString("quantum.subtitle"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .systemMonitor:
                SystemMonitorView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .settings:
                SettingsView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
    
 // MARK: - Private Methods
    
    private func initializePerformanceMonitoring() async {
        let manager = PerformanceModeManager.shared
        performanceModeManager = manager
        systemPerformanceMonitor = manager.systemPerformanceMonitor
        systemPerformanceMonitor?.startMonitoring(afterDelay: 10.0)
        logger.info("✅ 性能监控系统初始化完成")
    }
    
    @MainActor
    private func filterDevices(with searchText: String) async {
        isSearching = true
        
        let devices = mapOnlineToDiscovered(appModel.onlineDevices)
        
        if searchText.isEmpty {
            filteredDevices = sortDevicesBySignalStrength(devices)
        } else {
            let lowercasedSearch = searchText.lowercased()
            let filtered = devices.filter { device in
                device.name.lowercased().contains(lowercasedSearch) ||
                (device.ipv4?.contains(lowercasedSearch) == true) ||
                (device.ipv6?.contains(lowercasedSearch) == true) ||
                device.services.contains { $0.lowercased().contains(lowercasedSearch) }
            }
            filteredDevices = sortDevicesBySignalStrength(filtered)
        }
        
        isSearching = false
    }
    
    @MainActor
    private func mapOnlineToDiscovered(_ online: [OnlineDevice]) -> [DiscoveredDevice] {
        online.map { od in
            DiscoveredDevice(
                id: od.id,
                name: od.name,
                ipv4: od.ipv4,
                ipv6: od.ipv6,
                services: od.services,
                portMap: od.portMap,
                connectionTypes: od.connectionTypes,
                uniqueIdentifier: od.uniqueIdentifier,
                signalStrength: nil,
                source: od.sources.first ?? .unknown,
                isLocalDevice: od.isLocalDevice,
                deviceId: nil,
                pubKeyFP: nil,
                macSet: od.macAddress.map { Set([$0]) } ?? []
            )
        }
    }
    
    private func sortDevicesBySignalStrength(_ devices: [DiscoveredDevice]) -> [DiscoveredDevice] {
        guard SettingsManager.shared.sortBySignalStrength else { return devices }
        return devices.sorted { a, b in
            let sa = Int(a.signalStrength ?? 0)
            let sb = Int(b.signalStrength ?? 0)
            if sa != sb { return sa > sb }
            return a.name.localizedCompare(b.name) == .orderedAscending
        }
    }
    
    private func setupOnAppear() {
        appModel.onNavigateToSettings = {
            selectedNavigation = .settings
        }
        weatherLocationService.requestLocationPermission()
        weatherLocationService.startLocationUpdates()
        GlobalMouseTracker.shared.startTracking()
        signalSortTimerEnabled = true
        
        setupNotificationObservers()
        startFPSMonitor()
    }
    
 /// 轻量级 FPS 监控（3秒刷新一次）
    private func startFPSMonitor() {
        guard SettingsManager.shared.showRealtimeFPS else { return }
        lastFPSUpdate = CACurrentMediaTime()
        frameCount = 0
        
 // 每3秒更新一次 FPS 显示
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [self] _ in
            Task { @MainActor in
                let now = CACurrentMediaTime()
                let elapsed = now - lastFPSUpdate
                guard elapsed > 0 else { return }
                
 // 使用屏幕刷新率作为基准（macOS 通常为 60Hz 或 120Hz ProMotion）
                let screenFPS = NSScreen.main?.maximumFramesPerSecond ?? 60
                realtimeFPS = "\(screenFPS) FPS"
                
                lastFPSUpdate = now
                frameCount = 0
            }
        }
    }
    
    private func stopFPSMonitor() {
        fpsTimer?.invalidate()
        fpsTimer = nil
    }
    
    private func setupNotificationObservers() {
        let center = NotificationCenter.default
        
        appDidResignActiveObserver = center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                self.wasPausedByInactive = true
                self.hazeClearManager.stopUpdateLoop()
                GlobalMouseTracker.shared.stopTracking()
            }
        }
        
        appDidBecomeActiveObserver = center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                GlobalMouseTracker.shared.startTracking()
                self.hazeClearManager.resumeUpdateLoop()
                self.wasPausedByInactive = false
            }
        }
        
        windowOcclusionObserver = center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow else { return }
            Task { @MainActor in
                let visible = window.occlusionState.contains(.visible)
                if visible {
                    self.hazeClearManager.resumeUpdateLoop()
                    GlobalMouseTracker.shared.startTracking()
                    self.wasPausedByOcclusion = false
                } else {
                    self.hazeClearManager.stopUpdateLoop()
                    self.wasPausedByOcclusion = true
                }
            }
        }
        
        windowMiniObserver = center.addObserver(forName: NSWindow.didMiniaturizeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                self.hazeClearManager.stopUpdateLoop()
            }
        }
        
        windowDeminiObserver = center.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                self.hazeClearManager.resumeUpdateLoop()
                GlobalMouseTracker.shared.startTracking()
            }
        }
    }
    
    private func removeNotificationObservers() {
        let center = NotificationCenter.default
        if let o = appDidBecomeActiveObserver { center.removeObserver(o) }
        if let o = appDidResignActiveObserver { center.removeObserver(o) }
        if let o = windowOcclusionObserver { center.removeObserver(o) }
        if let o = windowMiniObserver { center.removeObserver(o) }
        if let o = windowDeminiObserver { center.removeObserver(o) }
    }
}

