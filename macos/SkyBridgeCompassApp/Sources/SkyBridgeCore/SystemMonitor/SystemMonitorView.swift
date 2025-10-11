import SwiftUI
import Foundation

/// 系统监控主视图 - 符合Apple设计规范的系统监控界面
/// 提供实时系统性能监控和详细的系统信息展示
@available(macOS 14.0, *)
public struct SystemMonitorView: View {
    
    // MARK: - 初始化器
    
    /// 公共初始化器，允许外部模块创建实例
    public init() {}
    
    // MARK: - 状态管理
    
    @StateObject private var monitorManager = SystemMonitorManager()
    @State private var showSettings = false
    @State private var selectedTimeRange: TimeRange = .oneHour
    @State private var isMonitoring = true
    
    // MARK: - 视图主体
    
    public var body: some View {
        NavigationSplitView {
            // 侧边栏
            sidebarView
        } detail: {
            // 主内容区域
            mainContentView
        }
        .navigationTitle("系统监控")
        .toolbar {
            toolbarContent
        }
        .onAppear {
            startMonitoring()
        }
        .onDisappear {
            stopMonitoring()
        }
        .sheet(isPresented: $showSettings) {
            SystemMonitorSettingsView(isPresented: $showSettings)
        }
    }
    
    // MARK: - 侧边栏视图
    
    private var sidebarView: some View {
        List {
            Section("监控概览") {
                NavigationLink(destination: overviewDetailView) {
                    Label("系统概览", systemImage: "gauge")
                }
                
                NavigationLink(destination: cpuDetailView) {
                    Label("处理器", systemImage: "cpu")
                }
                
                NavigationLink(destination: memoryDetailView) {
                    Label("内存", systemImage: "memorychip")
                }
                
                NavigationLink(destination: networkDetailView) {
                    Label("网络", systemImage: "network")
                }
                
                NavigationLink(destination: diskDetailView) {
                    Label("存储", systemImage: "internaldrive")
                }
            }
            
            Section("系统信息") {
                NavigationLink(destination: processDetailView) {
                    Label("进程", systemImage: "list.bullet.rectangle")
                }
                
                NavigationLink(destination: systemInfoView) {
                    Label("系统信息", systemImage: "info.circle")
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 200)
    }
    
    // MARK: - 主内容视图
    
    private var mainContentView: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: 20) {
                // CPU使用率卡片
                SystemMetricCard(
                    title: "CPU使用率",
                    value: String(format: "%.1f%%", monitorManager.cpuUsage),
                    subtitle: "系统处理器负载",
                    icon: "cpu",
                    color: Color.blue,
                    trend: monitorManager.cpuTrend
                )
                
                // 内存使用卡片
                SystemMetricCard(
                    title: "内存使用",
                    value: formatBytes(monitorManager.memoryUsed),
                    subtitle: "共 \(formatBytes(monitorManager.memoryTotal))",
                    icon: "memorychip",
                    color: Color.green,
                    trend: monitorManager.memoryTrend
                )
                
                // 系统负载卡片
                SystemMetricCard(
                    title: "系统负载",
                    value: String(format: "%.2f", monitorManager.systemLoad),
                    subtitle: "1分钟平均负载",
                    icon: "gauge",
                    color: systemLoadColor,
                    trend: TrendDirection.stable
                )
                
                // 运行时间卡片
                SystemMetricCard(
                    title: "运行时间",
                    value: formatUptime(monitorManager.systemUptime),
                    subtitle: "系统启动时间",
                    icon: "clock",
                    color: Color.purple
                )
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            
            // 性能图表区域
            VStack(spacing: 20) {
                // CPU使用率图表
                PerformanceChartCard(
                    title: "CPU使用率趋势",
                    data: createChartData(from: monitorManager.cpuHistory),
                    color: Color.blue,
                    unit: "%",
                    maxValue: 100
                )
                
                // 内存使用图表
                PerformanceChartCard(
                    title: "内存使用趋势",
                    data: createChartData(from: monitorManager.memoryHistory),
                    color: Color.green,
                    unit: "%",
                    maxValue: 100
                )
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            
            // 网络和磁盘监控
            HStack(alignment: .top, spacing: 20) {
                // 网络监控卡片
                NetworkMonitorCard(
                    uploadSpeed: monitorManager.networkUpload,
                    downloadSpeed: monitorManager.networkDownload,
                    totalUploaded: 1024 * 1024 * 1024 * 2, // 模拟数据
                    totalDownloaded: 1024 * 1024 * 1024 * 8, // 模拟数据
                    connectionCount: 5, // 模拟数据
                    isConnected: true
                )
                
                // 磁盘使用卡片
                DiskUsageCard(diskUsages: monitorManager.diskUsages)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 40)
        }
        .background(.regularMaterial)
    }
    
    // MARK: - 工具栏内容
    
    private var toolbarContent: some ToolbarContent {
        Group {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 12) {
                    // 监控状态指示器
                    HStack(spacing: 6) {
                        Circle()
                            .fill(isMonitoring ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        
                        Text(isMonitoring ? "监控中" : "已停止")
                            .font(.caption)
                            .foregroundColor(isMonitoring ? Color.green : Color.red)
                    }
                    
                    // 时间范围选择器
                    Picker("时间范围", selection: $selectedTimeRange) {
                        ForEach(TimeRange.allCases, id: \.self) { range in
                            Text(range.displayName).tag(range)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 120)
                    
                    // 刷新按钮
                    Button(action: refreshData) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("刷新数据")
                    
                    // 设置按钮
                    Button(action: { showSettings = true }) {
                        Image(systemName: "gearshape")
                    }
                    .help("设置")
                }
            }
        }
    }
    
    // MARK: - 详细视图（占位符）
    
    private var overviewDetailView: some View {
        Text("系统概览详细信息")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial)
    }
    
    private var cpuDetailView: some View {
        Text("CPU详细信息")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial)
    }
    
    private var memoryDetailView: some View {
        Text("内存详细信息")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial)
    }
    
    private var networkDetailView: some View {
        Text("网络详细信息")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial)
    }
    
    private var diskDetailView: some View {
        Text("存储详细信息")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial)
    }
    
    private var processDetailView: some View {
        Text("进程详细信息")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial)
    }
    
    private var systemInfoView: some View {
        Text("系统信息")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial)
    }
    
    // MARK: - 计算属性
    
    private var gridColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 20),
            GridItem(.flexible(), spacing: 20),
            GridItem(.flexible(), spacing: 20),
            GridItem(.flexible(), spacing: 20)
        ]
    }
    
    private var systemLoadColor: Color {
        if monitorManager.systemLoad > 2.0 {
            return Color.red
        } else if monitorManager.systemLoad > 1.0 {
            return Color.orange
        } else {
            return Color.green
        }
    }
    
    // 加载颜色
    private func loadColor(for value: Double, threshold: Double) -> Color {
        if value > threshold * 0.8 {
            return Color.red
        } else if value > threshold * 0.6 {
            return Color.orange
        } else {
            return Color.green
        }
    }
    
    // MARK: - 私有方法
    
    private func startMonitoring() {
        monitorManager.startMonitoring()
        isMonitoring = true
    }
    
    private func stopMonitoring() {
        monitorManager.stopMonitoring()
        isMonitoring = false
    }
    
    private func refreshData() {
        monitorManager.updateMetrics()
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.includesUnit = true
        formatter.isAdaptive = true
        
        return formatter.string(fromByteCount: bytes)
    }
    
    private func formatUptime(_ uptime: TimeInterval) -> String {
        let days = Int(uptime) / 86400
        let hours = (Int(uptime) % 86400) / 3600
        let minutes = (Int(uptime) % 3600) / 60
        
        if days > 0 {
            return "\(days)天 \(hours)小时"
        } else if hours > 0 {
            return "\(hours)小时 \(minutes)分钟"
        } else {
            return "\(minutes)分钟"
        }
    }
    
    private func createChartData(from values: [Double]) -> [ChartDataPoint] {
        let now = Date()
        return values.enumerated().map { index, value in
            ChartDataPoint(
                timestamp: now.addingTimeInterval(TimeInterval(-values.count + index)),
                value: value
            )
        }
    }
}

// MARK: - 时间范围枚举

enum TimeRange: String, CaseIterable {
    case fifteenMinutes = "15m"
    case oneHour = "1h"
    case sixHours = "6h"
    case oneDay = "24h"
    
    var displayName: String {
        switch self {
        case .fifteenMinutes: return "15分钟"
        case .oneHour: return "1小时"
        case .sixHours: return "6小时"
        case .oneDay: return "24小时"
        }
    }
    
    var seconds: TimeInterval {
        switch self {
        case .fifteenMinutes: return 15 * 60
        case .oneHour: return 60 * 60
        case .sixHours: return 6 * 60 * 60
        case .oneDay: return 24 * 60 * 60
        }
    }
}

// MARK: - 图表数据点结构（已移除，使用PerformanceChartCard中的定义）

// MARK: - 预览

#Preview {
    if #available(macOS 14.0, *) {
        SystemMonitorView()
            .frame(width: 1200, height: 800)
    }
}