import Foundation
import Combine
import SwiftUI

/// 系统监控管理器 - 负责收集和管理系统性能数据
/// 符合macOS最佳实践，提供实时系统监控功能
@MainActor
public class SystemMonitorManager: ObservableObject {
    
    // MARK: - 发布属性
    
    @Published public var cpuUsage: Double = 0.0
    @Published public var memoryUsed: Int64 = 0
    @Published public var memoryTotal: Int64 = 0
    @Published public var networkUpload: Double = 0.0
    @Published public var networkDownload: Double = 0.0
    @Published public var systemLoad: Double = 0.0
    @Published public var systemUptime: TimeInterval = 0.0
    @Published public var systemStatus: SystemStatus = .normal
    @Published public var diskUsages: [DiskUsage] = []
    
    // 趋势数据
    @Published public var cpuTrend: TrendDirection = .stable
    @Published public var memoryTrend: TrendDirection = .stable
    @Published public var networkUploadTrend: TrendDirection = .stable
    @Published public var networkDownloadTrend: TrendDirection = .stable
    
    // 历史数据
    @Published public var cpuHistory: [Double] = []
    @Published public var memoryHistory: [Double] = []
    @Published public var networkUploadHistory: [Double] = []
    @Published public var networkDownloadHistory: [Double] = []
    
    // MARK: - 私有属性
    
    @MainActor private var monitoringTimer: Timer?
    private var isMonitoring = false
    private let maxHistoryCount = 300 // 保留5分钟的数据（每秒一个数据点）
    
    // 真实系统监控器实例
    private let realSystemMonitor = RealSystemMonitor()
    
    // 用于计算趋势的历史数据
    private var previousCpuUsage: Double = 0.0
    private var previousMemoryUsed: Int64 = 0
    private var previousNetworkUpload: Double = 0.0
    private var previousNetworkDownload: Double = 0.0
    
    // MARK: - 初始化
    
    public init() {
        initializeSystemInfo()
    }
    
    // MARK: - 公共方法
    
    /// 开始系统监控
    public func startMonitoring() {
        guard !isMonitoring else { return }
        
        isMonitoring = true
        updateMetrics()
        
        // 每秒更新一次数据
        monitoringTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateMetrics()
            }
        }
        
        print("🔍 系统监控已启动")
    }
    
    /// 停止系统监控
    public func stopMonitoring() {
        guard isMonitoring else { return }
        
        isMonitoring = false
        monitoringTimer?.invalidate()
        monitoringTimer = nil
        
        print("⏹️ 系统监控已停止")
    }
    
    /// 更新系统指标
    public func updateMetrics() {
        // 更新CPU使用率
        updateCPUUsage()
        
        // 更新内存使用情况
        updateMemoryUsage()
        
        // 更新网络使用情况
        updateNetworkUsage()
        
        // 更新系统负载
        updateSystemLoad()
        
        // 更新系统运行时间
        updateSystemUptime()
        
        // 更新磁盘使用情况
        updateDiskUsage()
        
        // 更新系统状态
        updateSystemStatus()
        
        // 更新趋势
        updateTrends()
        
        // 更新历史数据
        updateHistoryData()
    }
    
    // MARK: - 私有方法
    
    private func initializeSystemInfo() {
        // 获取物理内存总量
        memoryTotal = realSystemMonitor.getPhysicalMemory()
        
        // 初始化系统运行时间
        systemUptime = realSystemMonitor.getSystemUptime()
        
        // 初始化磁盘使用情况
        let diskUsageData = realSystemMonitor.getDiskUsage()
        diskUsages = diskUsageData.map { diskData in
            DiskUsage(
                name: diskData.name,
                totalSpace: diskData.totalSpace,
                usedSpace: diskData.usedSpace,
                freeSpace: diskData.freeSpace,
                usagePercentage: diskData.usagePercentage
            )
        }
        
        print("💾 系统信息初始化完成 - 总内存: \(ByteCountFormatter.string(fromByteCount: memoryTotal, countStyle: .memory))")
    }
    
    private func updateCPUUsage() {
        // 使用真实系统监控器获取CPU使用率
        cpuUsage = realSystemMonitor.getCPUUsage()
    }
    
    private func updateMemoryUsage() {
        // 使用真实系统监控器获取内存使用情况
        let memoryInfo = realSystemMonitor.getMemoryUsage()
        memoryUsed = memoryInfo.used
        memoryTotal = memoryInfo.total
    }
    
    private func updateNetworkUsage() {
        // 使用真实系统监控器获取网络使用情况
        let networkInfo = realSystemMonitor.getNetworkUsage()
        networkUpload = networkInfo.upload
        networkDownload = networkInfo.download
    }
    
    private func updateSystemLoad() {
        // 使用真实系统监控器获取系统负载
        let loadAverage = realSystemMonitor.getSystemLoad()
        systemLoad = loadAverage[0] // 使用1分钟平均负载
    }
    
    private func updateSystemUptime() {
        // 使用真实系统监控器获取系统运行时间
        systemUptime = realSystemMonitor.getSystemUptime()
    }
    
    private func updateDiskUsage() {
        // 使用真实系统监控器获取磁盘使用情况
        let diskUsageData = realSystemMonitor.getDiskUsage()
        diskUsages = diskUsageData.map { diskData in
            DiskUsage(
                name: diskData.name,
                totalSpace: diskData.totalSpace,
                usedSpace: diskData.usedSpace,
                freeSpace: diskData.freeSpace,
                usagePercentage: diskData.usagePercentage
            )
        }
    }
    
    private func updateSystemStatus() {
        // 根据系统指标确定系统状态
        let memoryUsagePercentage = Double(memoryUsed) / Double(memoryTotal) * 100.0
        
        if cpuUsage > 90 || memoryUsagePercentage > 90 || systemLoad > 3.0 {
            systemStatus = .critical
        } else if cpuUsage > 70 || memoryUsagePercentage > 70 || systemLoad > 2.0 {
            systemStatus = .warning
        } else {
            systemStatus = .normal
        }
    }
    
    private func updateTrends() {
        // 计算CPU趋势
        cpuTrend = calculateTrend(current: cpuUsage, previous: previousCpuUsage)
        previousCpuUsage = cpuUsage
        
        // 计算内存趋势
        memoryTrend = calculateTrend(current: Double(memoryUsed), previous: Double(previousMemoryUsed))
        previousMemoryUsed = memoryUsed
        
        // 计算网络趋势
        networkUploadTrend = calculateTrend(current: networkUpload, previous: previousNetworkUpload)
        previousNetworkUpload = networkUpload
        
        networkDownloadTrend = calculateTrend(current: networkDownload, previous: previousNetworkDownload)
        previousNetworkDownload = networkDownload
    }
    
    private func calculateTrend(current: Double, previous: Double) -> TrendDirection {
        let threshold = 0.05 // 5%的变化阈值
        let change = (current - previous) / max(previous, 1.0)
        
        if change > threshold {
            return .up
        } else if change < -threshold {
            return .down
        } else {
            return .stable
        }
    }
    
    private func updateHistoryData() {
        // 添加新数据点
        cpuHistory.append(cpuUsage)
        memoryHistory.append(Double(memoryUsed) / Double(memoryTotal) * 100.0)
        networkUploadHistory.append(networkUpload)
        networkDownloadHistory.append(networkDownload)
        
        // 保持历史数据在限制范围内
        if cpuHistory.count > maxHistoryCount {
            cpuHistory.removeFirst()
        }
        if memoryHistory.count > maxHistoryCount {
            memoryHistory.removeFirst()
        }
        if networkUploadHistory.count > maxHistoryCount {
            networkUploadHistory.removeFirst()
        }
        if networkDownloadHistory.count > maxHistoryCount {
            networkDownloadHistory.removeFirst()
        }
    }
    
    deinit {
        // 在deinit中直接清理资源，避免主actor隔离问题
        // Timer会在对象销毁时自动失效，无需手动处理
    }
}

// MARK: - 系统状态枚举

public enum SystemStatus: String, CaseIterable {
    case normal = "正常"
    case warning = "警告"
    case critical = "严重"
    
    public var displayName: String {
        return rawValue
    }
    
    public var color: Color {
        switch self {
        case .normal:
            return Color.green
        case .warning:
            return Color.orange
        case .critical:
            return Color.red
        }
    }
}

// MARK: - 趋势方向枚举

public enum TrendDirection: String, CaseIterable {
    case up = "上升"
    case down = "下降"
    case stable = "稳定"
    
    public var iconName: String {
        switch self {
        case .up:
            return "arrow.up"
        case .down:
            return "arrow.down"
        case .stable:
            return "minus"
        }
    }
    
    public var color: Color {
        switch self {
        case .up:
            return Color.red
        case .down:
            return Color.green
        case .stable:
            return Color.gray
        }
    }
}

// MARK: - 磁盘使用情况结构

public struct DiskUsage: Identifiable {
    public let id = UUID()
    public let name: String
    public let totalSpace: Int64
    public let usedSpace: Int64
    public let freeSpace: Int64
    public let usagePercentage: Double
    
    public init(name: String, totalSpace: Int64, usedSpace: Int64, freeSpace: Int64, usagePercentage: Double) {
        self.name = name
        self.totalSpace = totalSpace
        self.usedSpace = usedSpace
        self.freeSpace = freeSpace
        self.usagePercentage = usagePercentage
    }
}