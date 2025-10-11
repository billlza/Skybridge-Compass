import SwiftUI
import Charts
import SkyBridgeCore
#if canImport(OrderedCollections)
import OrderedCollections
#endif
import os.log

/// 导航项目枚举
enum NavigationItem: String, CaseIterable, Identifiable {
    case dashboard = "主控制台"
    case deviceManagement = "设备发现"
    case fileTransfer = "文件传输"
    case remoteDesktop = "远程桌面"
    case systemMonitor = "系统监控"
    case appleSiliconTest = "Apple Silicon 测试"
    case performanceDemo = "性能演示"
    case weatherTest = "天气测试"
    case settings = "设置"
    
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .dashboard: return "house"
        case .deviceManagement: return "magnifyingglass"
        case .fileTransfer: return "folder"
        case .remoteDesktop: return "display"
        case .systemMonitor: return "speedometer"
        case .appleSiliconTest: return "cpu"
        case .performanceDemo: return "play.circle"
        case .weatherTest: return "cloud.fog.fill"
        case .settings: return "gearshape"
        }
    }
    
    /// 导航项目对应的主题色彩
    var color: Color {
        switch self {
        case .dashboard: return .blue
        case .deviceManagement: return .green
        case .fileTransfer: return .orange
        case .remoteDesktop: return .cyan
        case .systemMonitor: return .orange
        case .appleSiliconTest: return .red
        case .performanceDemo: return .purple
        case .weatherTest: return .brown
        case .settings: return .secondary
        }
    }
}

// MARK: - 辅助组件

/// 空状态视图组件
struct EmptyStateView: View {
    let title: String
    let subtitle: String
    
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            
            Text(title)
                .font(.headline)
                .foregroundColor(.secondary)
            
            Text(subtitle)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(red: 20/255, green: 25/255, blue: 45/255))
        )
    }
}

/// 增强的设备行组件
struct EnhancedDeviceRow: View {
    let device: DiscoveredDevice
    let onConnect: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                // 设备图标
                Image(systemName: deviceIcon)
                    .font(.title2)
                    .foregroundColor(deviceColor)
                    .frame(width: 32, height: 32)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(device.name)
                        .font(.headline)
                        .foregroundColor(.white)
                    
                    Text(device.ipv4 ?? device.ipv6 ?? "未知IP")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // 连接状态指示器
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
            }
            
            // 设备信息
            HStack {
                Label("服务", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Text("\(device.services.count) 个服务")
                    .font(.caption)
                    .foregroundColor(.white)
            }
            
            // 连接按钮
            Button(action: onConnect) {
                HStack {
                    Image(systemName: "link")
                        .font(.caption)
                    Text("连接")
                        .font(.caption.weight(.medium))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.blue.opacity(0.8))
                )
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(red: 20/255, green: 25/255, blue: 45/255))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
        )
    }
    
    private var deviceIcon: String {
        // 根据服务类型推断设备类型
        if device.services.contains(where: { $0.contains("rdp") }) {
            return "desktopcomputer"
        } else if device.services.contains(where: { $0.contains("rfb") }) {
            return "laptopcomputer"
        } else if device.services.contains(where: { $0.contains("skybridge") }) {
            return "iphone"
        } else {
            return "display"
        }
    }
    
    private var deviceColor: Color {
        // 根据服务类型设置颜色
        if device.services.contains(where: { $0.contains("rdp") }) {
            return .blue
        } else if device.services.contains(where: { $0.contains("rfb") }) {
            return .green
        } else if device.services.contains(where: { $0.contains("skybridge") }) {
            return .orange
        } else {
            return .gray
        }
    }
    
    private var statusColor: Color {
        // 根据是否有IP地址判断在线状态
        (device.ipv4 != nil || device.ipv6 != nil) ? .green : .red
    }
}
struct NavigationItemView: View {
    let item: NavigationItem
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                // 图标
                Image(systemName: item.icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(isSelected ? .white : item.color)
                    .frame(width: 20, height: 20)
                
                // 标题
                Text(item.rawValue)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(isSelected ? .white : .primary)
                
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? item.color : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.clear : Color.primary.opacity(0.1), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.2), value: isSelected)
    }
}

/// 主仪表盘界面，展示来自真实环境的遥测信息与操作入口。
@available(macOS 14.0, *)
struct DashboardView: View {
    @EnvironmentObject var appModel: DashboardViewModel
    @EnvironmentObject var authModel: AuthenticationViewModel
    @EnvironmentObject var themeConfiguration: ThemeConfiguration
    @EnvironmentObject var weatherLocationService: WeatherLocationService
    @EnvironmentObject var weatherDataService: WeatherDataService
    @State private var selectedSession: RemoteSessionSummary?
    @State private var selectedNavigation: NavigationItem = .dashboard

    private let cardSpacing: CGFloat = 20
    private let sectionSpacing: CGFloat = 24
    
    // 添加Apple Silicon优化器
    @available(macOS 14.0, *)
    private var optimizer: AppleSiliconOptimizer? {
        return AppleSiliconOptimizer.shared
    }
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "DashboardView")

    var body: some View {
        ZStack {
            // 星空背景 - 使用主题配置的背景强度
            StarryBackground()
                .opacity(themeConfiguration.backgroundIntensity)
                .ignoresSafeArea(.all)
            
            NavigationSplitView {
                // 使用液态玻璃侧边栏替换原有侧边栏
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
                        // 根据侧边栏选择的tab更新导航状态
                        if let navigationItem = NavigationItem.allCases.first(where: { $0.rawValue == newTab.id }) {
                            selectedNavigation = navigationItem
                        }
                    }
                ))
                .opacity(themeConfiguration.glassOpacity)
            } detail: {
                VStack(spacing: 0) {
                    // 顶部导航栏
                    topNavigationBar
                    
                    // 主内容区域
                    mainContent
                        .padding(.horizontal, 32)
                        .padding(.vertical, 24)
                        .background(Color.clear) // 移除原有背景色，让星空背景透过
                }
            }
            .navigationSplitViewStyle(.prominentDetail)
            .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 400)
        }
        .animation(themeConfiguration.springAnimation, value: themeConfiguration.currentTheme)
        .animation(themeConfiguration.easeAnimation, value: themeConfiguration.backgroundIntensity)
        .animation(themeConfiguration.easeAnimation, value: themeConfiguration.glassOpacity)
        .task {
            // 使用优化的任务启动
            await loadDashboardDataOptimized()
            await appModel.start()
        }
        .onDisappear {
            appModel.stop()
        }
        .onAppear {
            // 设置界面显示状态的回调
            appModel.onNavigateToSettings = {
                selectedNavigation = .settings
            }
        }
    }
    
    // MARK: - 顶部导航栏
    private var topNavigationBar: some View {
        HStack {
            // 应用图标和标题
            HStack(spacing: 12) {
                // 使用Bundle.module加载PNG图标文件
                Group {
                    #if SWIFT_PACKAGE
                    if let iconURL = Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
                       let nsImage = NSImage(contentsOf: iconURL) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .frame(width: 28, height: 28)
                    } else {
                        Image(systemName: "globe.americas.fill")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundColor(.blue)
                    }
                    #else
                    if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
                       let nsImage = NSImage(contentsOf: iconURL) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .frame(width: 28, height: 28)
                    } else {
                        Image(systemName: "globe.americas.fill")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundColor(.blue)
                    }
                    #endif
                }
                
                Text("SkyBridge Compass")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundColor(themeConfiguration.primaryTextColor)
            }
            
            Spacer()
            
            // 连接状态指示器
            connectionStatusIndicator
            
            // 主题切换按钮
            themeToggleButton
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(themeConfiguration.cardBackgroundMaterial, in: Rectangle())
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(themeConfiguration.borderColor),
            alignment: .bottom
        )
    }
    
    // MARK: - 连接状态指示器
    private var connectionStatusIndicator: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(appModel.metrics.onlineDevices > 0 ? Color.green : Color.red)
                .frame(width: 8, height: 8)
                .animation(themeConfiguration.easeAnimation, value: appModel.metrics.onlineDevices)
            
            Text(appModel.metrics.onlineDevices > 0 ? "已连接" : "未连接")
                .font(.caption)
                .foregroundColor(themeConfiguration.secondaryTextColor)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(themeConfiguration.cardBackgroundColor, in: Capsule())
        .overlay(
            Capsule()
                .stroke(themeConfiguration.borderColor, lineWidth: 1)
        )
    }
    
    // MARK: - 主题切换按钮
    private var themeToggleButton: some View {
        Menu {
            ForEach(ThemeConfiguration.AppTheme.allCases) { theme in
                Button(action: {
                    themeConfiguration.switchToTheme(theme)
                }) {
                    HStack {
                        Text(theme.rawValue)
                        if theme == themeConfiguration.currentTheme {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
            
            Divider()
            
            Button(action: {
                themeConfiguration.toggleAnimations()
            }) {
                HStack {
                    Text("动画效果")
                    if themeConfiguration.enableAnimations {
                        Image(systemName: "checkmark")
                    }
                }
            }
            
            Button(action: {
                themeConfiguration.toggleGlassEffects()
            }) {
                HStack {
                    Text("玻璃效果")
                    if themeConfiguration.enableGlassEffect {
                        Image(systemName: "checkmark")
                    }
                }
            }
        } label: {
            Image(systemName: "paintbrush.fill")
                .font(.title3)
                .foregroundColor(themeConfiguration.currentTheme.primaryColor)
                .padding(8)
                .background(themeConfiguration.cardBackgroundColor, in: Circle())
                .overlay(
                    Circle()
                        .stroke(themeConfiguration.borderColor, lineWidth: 1)
                )
        }
        .menuStyle(.borderlessButton)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            // 顶部标题区域
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: "globe.asia.australia")
                        .font(.title2)
                        .foregroundColor(.blue)
                        .frame(width: 24, height: 24)
                    
                    Text("云桥司南")
                        .font(.title2.bold())
                        .foregroundColor(.primary)
                    
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                
                Divider()
                    .background(Color.primary.opacity(0.2))
                    .padding(.horizontal, 20)
            }
            
            // 主导航菜单
            VStack(spacing: 4) {
                ForEach(NavigationItem.allCases) { item in
                    NavigationItemView(
                        item: item,
                        isSelected: selectedNavigation == item,
                        action: {
                            selectedNavigation = item
                        }
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 16)
            
            Spacer()
            
            // 底部用户信息区域
            VStack(spacing: 12) {
                Divider()
                    .background(Color.primary.opacity(0.2))
                    .padding(.horizontal, 20)
                
                HStack(spacing: 12) {
                    Circle()
                        .fill(Color.blue.gradient)
                        .frame(width: 32, height: 32)
                        .overlay(
                            Text("用")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.white)
                        )
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("用户")
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(.primary)
                        Text("已连接")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Button(action: appModel.openSettings) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 16))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .frame(minWidth: 280, maxWidth: 320)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var mainContent: some View {
        Group {
            switch selectedNavigation {
            case .dashboard:
                // 主控制台内容
                ScrollView {
                    LazyVStack(spacing: sectionSpacing) {
                        dashboardContent
                    }
                    .padding(.bottom, 32)
                }
                .scrollIndicators(.hidden)
            case .deviceManagement:
                ScrollView {
                    LazyVStack(spacing: sectionSpacing) {
                        deviceManagementContent
                    }
                    .padding(.bottom, 32)
                }
                .scrollIndicators(.hidden)
            case .fileTransfer:
                // 使用新的文件传输视图
                FileTransferView()
            case .remoteDesktop:
                // 使用新的远程桌面视图
                RemoteDesktopView()
            case .systemMonitor:
                // 系统监控界面
                SystemMonitorView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .appleSiliconTest:
                // Apple Silicon 性能测试界面
                PerformanceTestView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .performanceDemo:
                // 性能演示界面
                PerformanceTestDemoView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .weatherTest:
                // 天气测试界面
                WeatherTestView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .settings:
                // 设置界面直接在主内容区域平铺显示，保持侧边栏不动
                SettingsView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
    
    // MARK: - 各个页面内容
    private var dashboardContent: some View {
        ScrollView {
            VStack(spacing: sectionSpacing) {
                // 顶部统计卡片行 - 4个卡片等宽排列
                topStatsRow
                
                // 主要内容区域 - 2x2网格布局
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: cardSpacing) {
                    deviceDiscoveryPanel
                    remoteSessionsPanel
                    quickActionsPanel
                    appleSiliconInfoCard
                }
            }
            .padding(.bottom, 24)
        }
    }
    

    
    private var fileTransferContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("文件传输")
                .font(.largeTitle.bold())
                .foregroundColor(.white)
            
            fileTransferPanel
        }
    }
    
    // 文件传输面板
    private var fileTransferPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("传输任务", systemImage: "folder")
                    .font(.headline)
                    .foregroundStyle(themeConfiguration.primaryTextColor)
                Spacer()
            }
            
            VStack(spacing: 12) {
                if appModel.transferTasks.isEmpty {
                    EmptyStateView(
                        title: "暂无传输任务",
                        subtitle: "文件传输任务将在此处显示"
                    )
                } else {
                    ForEach(appModel.transferTasks, id: \.id) { transfer in
                        FileTransferRow(transfer: transfer)
                    }
                }
            }
        }
        .padding(20)
        .background(themeConfiguration.cardBackgroundMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(themeConfiguration.borderColor, lineWidth: 1)
        )
    }
    
    private var deviceManagementContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("设备管理")
                .font(.largeTitle.bold())
                .foregroundColor(.white)
            
            // 集成新的设备管理界面
            DeviceManagementView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            Spacer()
        }
    }
    
    private var remoteDesktopContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("远程桌面")
                .font(.largeTitle.bold())
                .foregroundColor(.white)
            
            // 远程桌面内容 - 使用现有的远程会话面板
            remoteSessionsPanel
            
            Spacer()
        }
    }
    
    // MARK: - 顶部统计卡片行
    private var topStatsRow: some View {
        HStack(spacing: cardSpacing) {
            StatCard(
                title: "在线设备",
                value: "\(appModel.metrics.onlineDevices)",
                icon: "laptopcomputer",
                color: .blue
            )
            
            StatCard(
                title: "活跃会话", 
                value: "\(appModel.metrics.activeSessions)",
                icon: "display",
                color: .green
            )
            
            StatCard(
                title: "传输任务",
                value: "\(appModel.metrics.fileTransfers)", 
                icon: "folder",
                color: .orange
            )
            
            // 新增：天气信息卡片
            WeatherStatCard(
                weatherService: weatherDataService,
                locationService: weatherLocationService
            )
            
            // 新增：性能状态卡片
            StatCard(
                title: "性能状态",
                value: performanceStatusValue,
                icon: performanceStatusIcon,
                color: performanceStatusColor
            )
        }
        .frame(height: 120)
    }
    
    // 性能状态计算属性
    private var performanceStatusValue: String {
        if appModel.thermalState == .nominal && appModel.powerState == .normal {
            return "优秀"
        } else if appModel.thermalState == .fair || appModel.powerState == .lowPower {
            return "良好"
        } else {
            return "注意"
        }
    }
    
    private var performanceStatusIcon: String {
        switch performanceStatusValue {
        case "优秀": return "checkmark.circle.fill"
        case "良好": return "exclamationmark.circle.fill"
        default: return "xmark.circle.fill"
        }
    }
    
    private var performanceStatusColor: Color {
        switch performanceStatusValue {
        case "优秀": return .green
        case "良好": return .orange
        default: return .red
        }
    }
    
    // MARK: - 主要内容网格
    // 性能监控面板
    private var performanceMonitoringPanel: some View {
        themedCard(title: "性能监控", iconName: "speedometer") {
            VStack(spacing: 16) {
                // 热量状态
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("热量状态")
                            .font(.caption)
                            .foregroundColor(themeConfiguration.secondaryTextColor)
                        Text(thermalStateDescription)
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(thermalStateColor)
                    }
                    
                    Spacer()
                    
                    Image(systemName: thermalStateIcon)
                        .font(.title2)
                        .foregroundColor(thermalStateColor)
                }
                
                Divider()
                    .background(themeConfiguration.borderColor)
                
                // 电源状态
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("电源状态")
                            .font(.caption)
                            .foregroundColor(themeConfiguration.secondaryTextColor)
                        Text(powerStateDescription)
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(powerStateColor)
                    }
                    
                    Spacer()
                    
                    Image(systemName: powerStateIcon)
                        .font(.title2)
                        .foregroundColor(powerStateColor)
                }
                
                Divider()
                    .background(themeConfiguration.borderColor)
                
                // 性能建议
                if !appModel.performanceRecommendations.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("性能建议")
                            .font(.caption)
                            .foregroundColor(themeConfiguration.secondaryTextColor)
                        
                        ForEach(Array(appModel.performanceRecommendations.prefix(3)), id: \.self) { recommendation in
                            HStack(spacing: 8) {
                                Image(systemName: "lightbulb.fill")
                                    .font(.caption)
                                    .foregroundColor(.yellow)
                                
                                Text(recommendation.rawValue)
                                    .font(.caption)
                                    .foregroundColor(themeConfiguration.primaryTextColor)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
            }
        }
        .frame(minHeight: 200)
    }
    
    // 系统指标面板
    private var systemMetricsPanel: some View {
        themedCard(title: "系统指标", iconName: "chart.line.uptrend.xyaxis") {
            VStack(spacing: 16) {
                // CPU使用率图表
                MetricChartView(
                    title: "CPU使用率",
                    value: appModel.systemMetricsService.cpuUsage,
                    color: .orange,
                    timeline: appModel.systemMetricsService.cpuTimeline
                )
                
                Divider()
                    .background(themeConfiguration.borderColor)
                
                // 内存使用率图表
                MetricChartView(
                    title: "内存使用率", 
                    value: appModel.systemMetricsService.memoryUsage,
                    color: .blue,
                    timeline: appModel.systemMetricsService.memoryTimeline
                )
                
                Divider()
                    .background(themeConfiguration.borderColor)
                
                // 网络速度图表 (真实数据)
                MetricChartView(
                    title: "网络速度",
                    value: appModel.systemMetricsService.networkSpeed,
                    color: .green,
                    timeline: appModel.systemMetricsService.networkTimeline,
                    unit: "Mbps"
                )
            }
        }
        .frame(minHeight: 320)
    }
    
    // 设备发现面板
    private var deviceDiscoveryPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("设备发现", systemImage: "magnifyingglass")
                    .font(.headline)
                    .foregroundStyle(themeConfiguration.primaryTextColor)
                Spacer()
            }
            
            VStack(spacing: 16) {
                // 搜索栏和刷新按钮
                HStack {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        TextField("搜索设备...", text: .constant(""))
                            .textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    
                    Button(action: {
                        appModel.triggerDiscoveryRefresh()
                    }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                }
                
                // 设备列表
                if appModel.discoveredDevices.isEmpty {
                    EmptyStateView(
                        title: "未发现设备",
                        subtitle: "确保设备在同一网络并启用了相应服务"
                    )
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(appModel.discoveredDevices, id: \.id) { device in
                            CompactDeviceRow(device: device) {
                                Task {
                                    await appModel.connect(to: device)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(20)
        .background(themeConfiguration.cardBackgroundMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(themeConfiguration.borderColor, lineWidth: 1)
        )
    }
    
    // 远程会话面板
    private var remoteSessionsPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("远程会话", systemImage: "display.2")
                    .font(.headline)
                    .foregroundStyle(themeConfiguration.primaryTextColor)
                Spacer()
            }
            
            VStack(spacing: 16) {
                if appModel.sessions.isEmpty {
                    EmptyStateView(
                        title: "暂无活动会话",
                        subtitle: "连接到设备后会话将在此处显示"
                    )
                } else {
                    ForEach(appModel.sessions, id: \.id) { session in
                        RemoteSessionStatusView(
                            session: session,
                            action: { selectedSession = session },
                            endAction: { 
                                Task {
                                    await appModel.terminate(session: session)
                                }
                            }
                        )
                    }
                }
            }
        }
        .padding(20)
        .background(themeConfiguration.cardBackgroundMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(themeConfiguration.borderColor, lineWidth: 1)
        )
    }
    
    // 快捷操作面板
    private var quickActionsPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("快捷操作", systemImage: "square.grid.2x2")
                    .font(.headline)
                    .foregroundStyle(themeConfiguration.primaryTextColor)
                Spacer()
            }
            
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 12) {
                QuickActionButton(
                    title: "扫描设备",
                    icon: "magnifyingglass",
                    color: .blue
                ) {
                    appModel.triggerDiscoveryRefresh()
                }
                
                QuickActionButton(
                    title: "文件传输",
                    icon: "folder",
                    color: .orange
                ) {
                    selectedNavigation = .fileTransfer
                }
                
                QuickActionButton(
                    title: "系统监控",
                    icon: "speedometer",
                    color: .green
                ) {
                    selectedNavigation = .systemMonitor
                }
                
                QuickActionButton(
                    title: "设置",
                    icon: "gearshape",
                    color: .gray
                ) {
                    selectedNavigation = .settings
                }
            }
        }
        .padding(20)
        .background(themeConfiguration.cardBackgroundMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(themeConfiguration.borderColor, lineWidth: 1)
        )
    }

    // 新增：Apple Silicon系统信息卡片
    private var appleSiliconInfoCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("系统性能", systemImage: "cpu.fill")
                    .font(.headline)
                    .foregroundStyle(themeConfiguration.primaryTextColor)
                Spacer()
            }
            
            VStack(alignment: .leading, spacing: 12) {
                if #available(macOS 14.0, *), let optimizer = optimizer {
                    let systemInfo = optimizer.getSystemInfo()
                    
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("处理器架构")
                                .font(.caption)
                                .foregroundColor(themeConfiguration.secondaryTextColor)
                            Text(optimizer.isAppleSilicon ? "Apple Silicon" : "Intel")
                                .font(.title3.bold())
                                .foregroundColor(optimizer.isAppleSilicon ? .green : .blue)
                        }
                        
                        Spacer()
                        
                        if optimizer.isAppleSilicon {
                            HStack(spacing: 4) {
                                Image(systemName: "bolt.fill")
                                    .foregroundColor(.yellow)
                                    .font(.caption)
                                Text("优化已启用")
                                    .font(.caption)
                                    .foregroundColor(.yellow)
                            }
                        }
                    }
                    
                    if optimizer.isAppleSilicon {
                        HStack(spacing: 20) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("性能核心")
                                    .font(.caption)
                                    .foregroundColor(themeConfiguration.secondaryTextColor)
                                Text("\(systemInfo.performanceCoreCount)")
                                    .font(.title3.bold())
                                    .foregroundColor(.blue)
                            }
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("效率核心")
                                    .font(.caption)
                                    .foregroundColor(themeConfiguration.secondaryTextColor)
                                Text("\(systemInfo.efficiencyCoreCount)")
                                    .font(.title3.bold())
                                    .foregroundColor(.green)
                            }
                        
                        Spacer()
                    }
                    
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                        Text("Apple Silicon 多核优化")
                            .font(.caption)
                            .foregroundColor(themeConfiguration.secondaryTextColor)
                    }
                } else {
                    HStack {
                        Image(systemName: "info.circle")
                            .foregroundColor(.orange)
                            .font(.caption)
                        Text("标准模式运行")
                            .font(.caption)
                            .foregroundColor(themeConfiguration.secondaryTextColor)
                    }
                }
            }
        }
        .padding(20)
        .background(themeConfiguration.cardBackgroundMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(themeConfiguration.borderColor, lineWidth: 1)
        )
    }
    }

    // 状态卡片组件
    func statusCard(title: String, value: Int, icon: String, color: Color) -> some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(color)
                Spacer()
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text("\(value)")
                    .font(.title.bold())
                    .foregroundColor(.white)
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
    }
    
    // MARK: - 热量和电源状态相关计算属性
    
    /// 获取热量状态的描述文本
    private var thermalStateDescription: String {
        switch appModel.thermalState {
        case .nominal: return "正常"
        case .fair: return "良好"
        case .serious: return "较高"
        case .critical: return "严重"
        @unknown default: return "未知"
        }
    }
    
    /// 获取热量状态对应的颜色
    private var thermalStateColor: Color {
        switch appModel.thermalState {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return .orange
        case .critical: return .red
        @unknown default: return .gray
        }
    }
    
    /// 获取热量状态对应的图标
    private var thermalStateIcon: String {
        switch appModel.thermalState {
        case .nominal: return "thermometer.low"
        case .fair: return "thermometer.medium"
        case .serious: return "thermometer.high"
        case .critical: return "thermometer.high.fill"
        @unknown default: return "thermometer"
        }
    }
    
    /// 获取电源状态的描述文本
    private var powerStateDescription: String {
        switch appModel.powerState {
        case .normal: return "正常"
        case .lowPower: return "低功耗"
        case .powerSaving: return "节能模式"
        case .critical: return "严重"
        case .thermalThrottling: return "热量限制"
        case .batteryOptimized: return "电池优化"
        @unknown default: return "未知"
        }
    }
    
    /// 获取电源状态对应的颜色
    private var powerStateColor: Color {
        switch appModel.powerState {
        case .normal: return .green
        case .lowPower: return .blue
        case .powerSaving: return .yellow
        case .critical: return .red
        case .thermalThrottling: return .orange
        case .batteryOptimized: return .blue
        @unknown default: return .gray
        }
    }
    
    /// 获取电源状态对应的图标
    /// 支持所有PowerState枚举成员，包括新增的热量限制和电池优化状态
    private var powerStateIcon: String {
        switch appModel.powerState {
        case .normal: return "bolt.fill"
        case .lowPower: return "battery.25"
        case .powerSaving: return "battery.0"
        case .critical: return "battery.0.fill"
        case .thermalThrottling: return "slowmo"
        case .batteryOptimized: return "leaf.fill"
        @unknown default: return "questionmark"
        }
    }
    
    // MARK: - 私有方法
    
    /// 使用Apple Silicon优化的数据加载策略
    /// 针对macOS 26.x和Swift 6.2进行优化
    func loadDashboardDataOptimized() async {
        guard let optimizer = optimizer, optimizer.isAppleSilicon else {
            // 非Apple Silicon设备使用标准加载
            logger.info("使用标准数据加载模式")
            return
        }
        
        // 使用Apple Silicon优化的并行加载
        let loadTasks = [
            ("网络状态", TaskType.networkRequest),
            ("系统监控", TaskType.dataAnalysis),
            ("设备信息", TaskType.fileIO),
            ("性能指标", TaskType.dataAnalysis)
        ]
        
        await withTaskGroup(of: Void.self) { group in
            for (taskName, taskType) in loadTasks {
                group.addTask {
                    let qos = optimizer.recommendedQoS(for: taskType)
                    let _ = DispatchQueue.appleSiliconOptimized(
                        label: "dashboard.\(taskName.lowercased().replacingOccurrences(of: " ", with: ""))",
                        for: taskType
                    )
                    
                    do {
                        // 模拟数据加载，使用优化的块大小
                        let dataSize = 1024 * 1024 // 1MB 模拟数据
                        let chunkSize = optimizer.recommendedChunkSize(for: dataSize)
                        
                        self.logger.debug("加载\(taskName)数据 - QoS: \(String(describing: qos)), 块大小: \(chunkSize)")
                        
                        // 使用异步延迟替代阻塞线程，符合Apple Silicon最佳实践
                        try await Task.sleep(nanoseconds: 50_000_000) // 0.05秒
                    } catch {
                        self.logger.error("加载\(taskName)数据失败: \(error.localizedDescription)")
                    }
                }
            }
        }
        
        logger.info("仪表板数据加载完成 - 使用Apple Silicon优化")
    }
}
    


// MARK: - 统计卡片组件
/// 统计卡片视图，用于显示数值统计信息
/// 针对macOS 14.0+进行优化，充分利用现代化SwiftUI特性
@available(macOS 14.0, *)
struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(color)
                Spacer()
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                Text(value)
                    .font(.title.bold())
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

// MARK: - 天气统计卡片组件
/// 天气统计卡片视图，用于显示当前天气信息
/// 集成WeatherDataService和WeatherLocationService，实时显示天气状况
@available(macOS 14.0, *)
struct WeatherStatCard: View {
    @ObservedObject var weatherService: WeatherDataService
    @ObservedObject var locationService: WeatherLocationService
    
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: weatherIcon)
                    .font(.title2)
                    .foregroundColor(weatherColor)
                Spacer()
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text("天气状况")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                HStack(spacing: 4) {
                    Text(weatherDescription)
                        .font(.title3.bold())
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    if let currentWeather = weatherService.currentWeather {
                        Text("\(Int(currentWeather.currentWeather.temperature.value))°")
                            .font(.title3.bold())
                            .foregroundColor(.white)
                    }
                }
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
    
    /// 获取天气描述文本
    private var weatherDescription: String {
        guard weatherService.currentWeather != nil else {
            return locationService.isLocationAuthorized ? "获取中..." : "未授权"
        }
        
        // 根据天气条件返回中文描述
        let weatherType = weatherService.getCurrentWeatherType()
        switch weatherType {
        case .clear:
            return "晴朗"
        case .partlyCloudy:
            return "多云"
        case .cloudy:
            return "阴天"
        case .fog:
            return "雾天"
        case .rain:
            return "雨天"
        case .heavyRain:
            return "大雨"
        case .snow:
            return "雪天"
        case .heavySnow:
            return "大雪"
        case .hail:
            return "冰雹"
        case .thunderstorm:
            return "雷暴"
        case .haze:
            return "雾霾"
        case .wind:
            return "大风"
        case .unknown:
            return "未知"
        }
    }
    
    /// 获取天气图标
    private var weatherIcon: String {
        guard weatherService.currentWeather != nil else {
            return locationService.isLocationAuthorized ? "cloud.fill" : "location.slash"
        }
        
        // 使用WeatherDataService的方法获取天气类型
        let weatherType = weatherService.getCurrentWeatherType()
        
        // 根据天气类型返回对应的SF Symbol图标
        switch weatherType {
        case .clear:
            return "sun.max.fill"
        case .partlyCloudy:
            return "cloud.sun.fill"
        case .cloudy:
            return "cloud.fill"
        case .fog:
            return "cloud.fog.fill"
        case .rain:
            return "cloud.rain.fill"
        case .heavyRain:
            return "cloud.heavyrain.fill"
        case .snow:
            return "cloud.snow.fill"
        case .heavySnow:
            return "cloud.snow.fill"
        case .hail:
            return "cloud.hail.fill"
        case .thunderstorm:
            return "cloud.bolt.fill"
        case .haze:
            return "cloud.fog.fill"
        case .wind:
            return "wind"
        case .unknown:
            return "cloud.fill"
        }
    }
    
    /// 获取天气颜色
    private var weatherColor: Color {
        guard weatherService.currentWeather != nil else {
            return locationService.isLocationAuthorized ? .gray : .red
        }
        
        // 使用WeatherDataService的方法获取天气类型
        let weatherType = weatherService.getCurrentWeatherType()
        
        // 根据天气类型返回对应的颜色
        switch weatherType {
        case .clear:
            return .yellow
        case .partlyCloudy:
            return .orange
        case .cloudy:
            return .gray
        case .fog:
            return .brown
        case .rain:
            return .blue
        case .heavyRain:
            return .indigo
        case .snow, .heavySnow, .hail:
            return .cyan
        case .thunderstorm:
            return .purple
        case .haze:
            return .brown
        case .wind:
            return .mint
        case .unknown:
            return .secondary
        }
    }
}

// MARK: - 指标图表组件
struct MetricChartView: View {
    let title: String
    let value: Double
    let color: Color
    let timeline: [Date: Double]
    let unit: String
    
    init(title: String, value: Double, color: Color, timeline: [Date: Double], unit: String = "%") {
        self.title = title
        self.value = value
        self.color = color
        self.timeline = timeline
        self.unit = unit
    }
    
    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text("\(value * (unit == "%" ? 100 : 1), specifier: "%.1f")\(unit)")
                    .font(.title3.bold())
                    .foregroundColor(color)
            }
            
            Spacer()
            
            // 简化的图表显示
            Chart {
                let sortedData = timeline.sorted(by: { $0.key < $1.key })
                ForEach(Array(sortedData.enumerated()), id: \.offset) { index, point in
                    LineMark(
                        x: .value("Time", index),
                        y: .value("Value", point.value * (unit == "%" ? 100 : 1))
                    )
                    .foregroundStyle(color)
                }
            }
            .frame(width: 120, height: 40)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
        }
    }
}

// MARK: - 紧凑设备行组件
struct CompactDeviceRow: View {
    let device: DiscoveredDevice
    let connectAction: () -> Void
    @State private var isConnecting = false
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: deviceIcon)
                .font(.title3)
                .foregroundColor(deviceColor)
                .frame(width: 24, height: 24)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                
                Text(device.ipv4 ?? device.ipv6 ?? "未知IP")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button(action: {
                isConnecting = true
                connectAction()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    isConnecting = false
                }
            }) {
                if isConnecting {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 50, height: 24)
                } else {
                    Text("连接")
                        .font(.caption.weight(.medium))
                        .frame(width: 50, height: 24)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isConnecting)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    
    private var deviceIcon: String {
        if device.services.contains("_ssh._tcp") {
            return "terminal"
        } else if device.services.contains("_vnc._tcp") {
            return "display"
        } else if device.services.contains("_rdp._tcp") {
            return "desktopcomputer"
        } else {
            return "laptopcomputer"
        }
    }
    
    private var deviceColor: Color {
        if device.services.contains("_ssh._tcp") {
            return .green
        } else if device.services.contains("_vnc._tcp") {
            return .blue
        } else if device.services.contains("_rdp._tcp") {
            return .purple
        } else {
            return .gray
        }
    }
}

// MARK: - 快捷操作按钮组件
struct QuickActionButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(color)
                
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 80)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 主题化组件方法
/// 提供主题化卡片组件
/// 确保与主视图的主题配置保持一致
@available(macOS 14.0, *)
extension DashboardView {
    func themedCard<Content: View>(title: String, iconName: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: HorizontalAlignment.leading, spacing: 16) {
            HStack {
                Label(title, systemImage: iconName)
                    .font(.headline)
                    .foregroundStyle(themeConfiguration.primaryTextColor)
                Spacer()
            }
            content()
        }
        .padding(20)
        .background(themeConfiguration.cardBackgroundMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(themeConfiguration.borderColor, lineWidth: 1)
        )
    }
}

struct MetricView: View {
    let title: String
    let value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(value)")
                .font(.title3.bold())
                .foregroundStyle(.white)
        }
    }
}

struct MetricsTimelineView: View {
    let dataPoints: OrderedDictionary<Date, Double>

    var body: some View {
        GeometryReader { geometry in
            let sorted = dataPoints.sorted(by: { $0.key < $1.key })
            Path { path in
                guard !sorted.isEmpty else { return }
                let width = geometry.size.width
                let height = geometry.size.height
                let times = sorted.map { $0.key.timeIntervalSince1970 }
                guard let minTime = times.min(), let maxTime = times.max(), let minValue = sorted.map({ $0.value }).min(), let maxValue = sorted.map({ $0.value }).max(), maxTime > minTime, maxValue > minValue else {
                    return
                }

                func position(for index: Int) -> CGPoint {
                    let timeRatio = (times[index] - minTime) / (maxTime - minTime)
                    let valueRatio = (sorted[index].value - minValue) / (maxValue - minValue)
                    let x = width * timeRatio
                    let y = height * (1 - valueRatio)
                    return CGPoint(x: x, y: y)
                }

                path.move(to: position(for: 0))
                for idx in sorted.indices {
                    path.addLine(to: position(for: idx))
                }
            }
            .stroke(Color.green, lineWidth: 2)
        }
    }
}

struct RemoteSessionRow: View {
    let session: RemoteSessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.targetName)
                .font(.headline)
            Text(session.protocolDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct RemoteSessionStatusView: View {
    let session: RemoteSessionSummary
    let action: () -> Void
    let endAction: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(session.targetName)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("\(session.protocolDescription) • 带宽 \(session.bandwidthMbps, specifier: "%.1f") Mbps")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ProgressView(value: session.frameLatencyMilliseconds, total: 80)
                    .progressViewStyle(.linear)
                    .tint(.cyan)
            }
            Spacer()
            VStack(spacing: 8) {
                Button("查看") { action() }
                    .buttonStyle(.borderedProminent)
                Button("断开") { endAction() }
                    .buttonStyle(.bordered)
                    .tint(.red)
            }
        }
    }
}

struct FileTransferRow: View {
    let transfer: FileTransferTask

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(transfer.fileName)
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Text(transfer.progress.formatted(.percent.precision(.fractionLength(1))))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: transfer.progress)
                .tint(.purple)
            Text("速度: \(transfer.throughputMbps, specifier: "%.2f") Mbps · 剩余: \(transfer.remainingTimeDescription)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - DispatchQueue异步支持
/// 扩展DispatchQueue以支持async/await模式
/// 针对Swift 6.2进行优化，确保类型安全和并发性能
@available(macOS 14.0, *)
private func asyncExecuteOnQueue<T: Sendable>(_ queue: DispatchQueue, _ work: @escaping @Sendable () throws -> T) async throws -> T {
    return try await withCheckedThrowingContinuation { continuation in
        queue.async {
            do {
                let result = try work()
                continuation.resume(returning: result)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
