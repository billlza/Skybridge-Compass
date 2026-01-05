import SwiftUI
import SkyBridgeCore

/// 主仪表盘内容视图 - Dashboard Tab 的主要内容
@available(macOS 14.0, *)
public struct DashboardContentView: View {
    @EnvironmentObject var appModel: DashboardViewModel
    @EnvironmentObject var themeConfiguration: ThemeConfiguration
    
    @Binding var selectedNavigation: NavigationItem
    @Binding var selectedSession: RemoteSessionSummary?
    @Binding var deviceSearchText: String
    @Binding var filteredDevices: [DiscoveredDevice]
    @Binding var isSearching: Bool
    @Binding var showManualConnectSheet: Bool
    @Binding var extendedSearchCountdown: Int
    @Binding var systemPerformanceMonitor: SystemPerformanceMonitor?
    
    private let cardSpacing: CGFloat = 20
    private let sectionSpacing: CGFloat = 24
    
    public init(
        selectedNavigation: Binding<NavigationItem>,
        selectedSession: Binding<RemoteSessionSummary?>,
        deviceSearchText: Binding<String>,
        filteredDevices: Binding<[DiscoveredDevice]>,
        isSearching: Binding<Bool>,
        showManualConnectSheet: Binding<Bool>,
        extendedSearchCountdown: Binding<Int>,
        systemPerformanceMonitor: Binding<SystemPerformanceMonitor?>
    ) {
        self._selectedNavigation = selectedNavigation
        self._selectedSession = selectedSession
        self._deviceSearchText = deviceSearchText
        self._filteredDevices = filteredDevices
        self._isSearching = isSearching
        self._showManualConnectSheet = showManualConnectSheet
        self._extendedSearchCountdown = extendedSearchCountdown
        self._systemPerformanceMonitor = systemPerformanceMonitor
    }
    
    public var body: some View {
        ScrollView {
            VStack(spacing: sectionSpacing) {
 // 顶部统计卡片行 - 4个卡片等宽排列
                topStatsRow
                
 // 🌦️ 液态玻璃天气卡片（全宽）
                WeatherDashboardCard()
                    .frame(height: 180)
                
 // 主要内容区域 - 2x2网格布局
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: cardSpacing) {
                    DeviceDiscoveryPanelView(
                        deviceSearchText: $deviceSearchText,
                        filteredDevices: $filteredDevices,
                        isSearching: $isSearching,
                        showManualConnectSheet: $showManualConnectSheet,
                        extendedSearchCountdown: $extendedSearchCountdown
                    )
                    
                    RemoteSessionsPanelView(selectedSession: $selectedSession)
                    
                    QuickActionsPanelView(selectedNavigation: $selectedNavigation)
                    
                    AppleSiliconInfoCardView()
                }
            }
            .padding(.bottom, 24)
        }
    }
    
 // MARK: - 顶部统计卡片行
    private var topStatsRow: some View {
        HStack(spacing: cardSpacing) {
            StatCard(
                title: LocalizationManager.shared.localizedString("dashboard.onlineDevices"),
                value: "\(appModel.metrics.onlineDevices)",
                icon: "laptopcomputer",
                color: .blue
            )
            
            StatCard(
                title: LocalizationManager.shared.localizedString("dashboard.activeSessions"), 
                value: "\(appModel.metrics.activeSessions)",
                icon: "display",
                color: .green
            )
            
            StatCard(
                title: LocalizationManager.shared.localizedString("dashboard.transferTasks"),
                value: "\(appModel.metrics.fileTransfers)", 
                icon: "folder",
                color: .orange
            )
            
 // 新增：性能状态卡片
            StatCard(
                title: LocalizationManager.shared.localizedString("dashboard.performanceStatus"),
                value: performanceStatusValue,
                icon: performanceStatusIcon,
                color: performanceStatusColor
            )
        }
        .frame(height: 120)
    }
    
 // ✅ 性能状态计算属性（使用真实性能监控数据）
    private var performanceStatusValue: String {
 // 优先使用SystemPerformanceMonitor的真实数据
        if let monitor = systemPerformanceMonitor, monitor.isMonitoring {
            let cpuUsage = monitor.cpuUsage
            let cpuTemp = monitor.cpuTemperature
            let gpuTemp = monitor.gpuTemperature
            let memoryUsage = monitor.memoryUsage
            
 // 综合评估性能状态
            if cpuUsage < 50 && cpuTemp < 70 && gpuTemp < 70 && memoryUsage < 70 {
                return LocalizationManager.shared.localizedString("status.excellent")
            } else if cpuUsage < 80 && cpuTemp < 85 && gpuTemp < 85 && memoryUsage < 85 {
                return LocalizationManager.shared.localizedString("status.good")
            } else {
                return LocalizationManager.shared.localizedString("status.attention")
            }
        }
        
 // 回退到原有逻辑
        if appModel.thermalState == .nominal && appModel.powerState == .normal {
            return LocalizationManager.shared.localizedString("status.excellent")
        } else if appModel.thermalState == .fair || appModel.powerState == .lowPower {
            return LocalizationManager.shared.localizedString("status.good")
        } else {
            return LocalizationManager.shared.localizedString("status.attention")
        }
    }
    
    private var performanceStatusIcon: String {
        switch performanceStatusValue {
        case LocalizationManager.shared.localizedString("status.excellent"): return "checkmark.circle.fill"
        case LocalizationManager.shared.localizedString("status.good"): return "exclamationmark.circle.fill"
        default: return "xmark.circle.fill"
        }
    }
    
    private var performanceStatusColor: Color {
        switch performanceStatusValue {
        case LocalizationManager.shared.localizedString("status.excellent"): return .green
        case LocalizationManager.shared.localizedString("status.good"): return .orange
        default: return .red
        }
    }
}

