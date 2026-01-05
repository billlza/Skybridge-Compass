import Foundation
import Combine
import SwiftUI

/// 系统监控管理器 - 负责收集和管理系统性能数据
/// 符合macOS最佳实践，提供实时系统监控功能
@MainActor
public class SystemMonitorManager: ObservableObject, Sendable {
    
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
    
    private var monitoringTask: Task<Void, Never>? // 使用现代异步任务
    private var isMonitoring = false
    private let maxHistoryCount = 300 // 保留5分钟的数据（每秒一个数据点）
    
 // 简化的系统监控器实例（更安全，避免卡死）
    private let simpleSystemMonitor = SimpleSystemMonitor()
    
 // 用于计算趋势的历史数据
    private var previousCpuUsage: Double = 0.0
    private var previousMemoryUsed: Int64 = 0
    private var previousNetworkUpload: Double = 0.0
    private var previousNetworkDownload: Double = 0.0
    
 // 监控配置 - 使用协调的更新间隔
    private let updateInterval: TimeInterval = 2.0 // 2秒更新间隔，避免过于频繁
    private let staggerDelay: TimeInterval = 0.3   // 错开执行延迟
    
 // MARK: - 初始化
    
    public init() {
        initializeSystemInfo()
    }
    
 // MARK: - Lifecycle Management
    
 /// 启动系统监控管理器
    public func start() {
        SkyBridgeLogger.performance.debugOnly("🚀 启动系统监控管理器")
        startMonitoring()
    }
    
 /// 停止系统监控管理器
    public func stop() {
        SkyBridgeLogger.performance.debugOnly("⏹️ 停止系统监控管理器")
        stopMonitoring()
    }
    
 /// 清理系统监控管理器资源
    public func cleanup() {
        SkyBridgeLogger.performance.debugOnly("🧹 清理系统监控管理器资源")
        stopMonitoring()
        
 // 清理历史数据
        cpuHistory.removeAll()
        memoryHistory.removeAll()
        networkUploadHistory.removeAll()
        networkDownloadHistory.removeAll()
        diskUsages.removeAll()
        
 // 重置状态
        systemStatus = .normal
        cpuTrend = .stable
        memoryTrend = .stable
        networkUploadTrend = .stable
        networkDownloadTrend = .stable
    }
    
 // MARK: - 公共方法
    
 /// 启动监控
    public func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        
 // 使用现代异步任务替代定时器
        monitoringTask = Task { @MainActor in
            await runCoordinatedMonitoring()
        }
        
        SkyBridgeLogger.performance.debugOnly("🔍 系统监控已启动")
    }
    
 /// 停止监控
    public func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false
        
        monitoringTask?.cancel()
        monitoringTask = nil
        
        SkyBridgeLogger.performance.debugOnly("⏹️ 系统监控已停止")
    }
    
 /// 运行协调监控 - 优化版本，避免阻塞主线程
    private func runCoordinatedMonitoring() async {
        SkyBridgeLogger.performance.debugOnly("🔄 开始协调监控")
        
        while !Task.isCancelled && isMonitoring {
            do {
 // 使用后台队列执行监控任务，避免阻塞主线程
                await withTaskGroup(of: Void.self) { group in
 // CPU和网络指标更新（轻量级）
                    group.addTask { [weak self] in
                        await self?.updateCPUAndNetworkMetricsAsync()
                    }
                    
 // 内存指标更新（中等负载）
                    group.addTask { [weak self] in
                        await self?.updateMemoryMetricsAsync()
                    }
                }
                
 // 错开执行，避免同时进行多个重负载操作
                try await Task.sleep(nanoseconds: 1_000_000_000) // 1秒间隔
                
            } catch {
                if error is CancellationError {
                    break
                }
                SkyBridgeLogger.performance.error("❌ 协调监控出错: \(error.localizedDescription, privacy: .private)")
                
 // 出错时等待更长时间再重试，避免频繁失败
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3秒
            }
        }
        
        SkyBridgeLogger.performance.debugOnly("🛑 协调监控已停止")
    }
    
 /// 更新CPU和网络指标 - 异步版本
    public func updateCPUAndNetworkMetricsAsync() async {
 // 在后台队列执行系统API调用，避免阻塞主线程
        let (cpu, network, load, uptime, disks) = await Task.detached {
            let monitor = SimpleSystemMonitor()
            
 // 获取CPU使用率
            let cpuUsage = monitor.getCPUUsage()
            
 // 获取网络使用情况
            let networkInfo = monitor.getNetworkUsage()
            
 // 获取系统负载
            let systemLoadArray = monitor.getSystemLoad()
            let systemLoad = systemLoadArray.isEmpty ? 0.0 : systemLoadArray[0]
            
 // 获取系统运行时间
            let systemUptime = monitor.getSystemUptime()
            
 // 获取磁盘使用情况
            let diskUsageData = monitor.getDiskUsage()
            let diskUsages = diskUsageData.map { data in
                DiskUsage(
                    name: data.name,
                    totalSpace: data.totalSpace,
                    usedSpace: data.usedSpace,
                    freeSpace: data.freeSpace,
                    usagePercentage: data.usagePercentage
                )
            }
            
            return (cpuUsage, networkInfo, systemLoad, systemUptime, diskUsages)
        }.value
        
 // 在主线程更新UI
        await MainActor.run {
            self.cpuUsage = cpu
            self.networkUpload = network.upload
            self.networkDownload = network.download
            self.systemLoad = load
            self.systemUptime = uptime
            self.diskUsages = disks
            
 // 更新趋势和历史数据
            self.updateCPUAndNetworkTrends()
            self.updateCPUAndNetworkHistoryData()
            self.updateSystemStatus()
        }
    }
    
 /// 更新内存指标 - 异步版本
    public func updateMemoryMetricsAsync() async {
 // 在后台队列执行系统API调用
        let memoryInfo = await Task.detached { @Sendable in
            let monitor = SimpleSystemMonitor()
            return monitor.getMemoryUsage()
        }.value
        
 // 更新UI属性（已在MainActor上）
        self.memoryUsed = memoryInfo.used
        self.memoryTotal = memoryInfo.total
        
 // 更新内存趋势和历史数据
        self.updateMemoryTrend()
        self.updateMemoryHistoryData()
    }
    
 /// 更新所有指标 - 异步版本
    public func updateMetricsAsync() async {
        await updateCPUAndNetworkMetricsAsync()
        await updateMemoryMetricsAsync()
    }
    
 /// 获取当前监控状态
    public var isCurrentlyMonitoring: Bool {
        return isMonitoring
    }
    
 // MARK: - 私有方法
    
 /// 初始化系统信息
    private func initializeSystemInfo() {
 // 获取初始内存信息
        let memoryInfo = simpleSystemMonitor.getMemoryUsage()
        memoryUsed = memoryInfo.used
        memoryTotal = memoryInfo.total
        
 // 获取初始磁盘使用情况
        let diskUsageData = simpleSystemMonitor.getDiskUsage()
        diskUsages = diskUsageData.map { diskData in
            DiskUsage(
                name: diskData.name,
                totalSpace: diskData.totalSpace,
                usedSpace: diskData.usedSpace,
                freeSpace: diskData.freeSpace,
                usagePercentage: diskData.usagePercentage
            )
        }
        
 // 获取初始系统负载
        let loads = simpleSystemMonitor.getSystemLoad()
        systemLoad = loads.count > 0 ? loads[0] : 0.0
        
 // 获取系统运行时间
        systemUptime = simpleSystemMonitor.getSystemUptime()
        
        SkyBridgeLogger.performance.debugOnly("📊 系统信息初始化完成")
    }
    
 /// 更新CPU和网络趋势
    private func updateCPUAndNetworkTrends() {
        cpuTrend = calculateTrend(current: cpuUsage, previous: previousCpuUsage)
        networkUploadTrend = calculateTrend(current: networkUpload, previous: previousNetworkUpload)
        networkDownloadTrend = calculateTrend(current: networkDownload, previous: previousNetworkDownload)
        
        previousCpuUsage = cpuUsage
        previousNetworkUpload = networkUpload
        previousNetworkDownload = networkDownload
    }
    
 /// 更新内存趋势
    private func updateMemoryTrend() {
        let currentMemoryUsage = Double(memoryUsed)
        let previousMemoryUsage = Double(previousMemoryUsed)
        memoryTrend = calculateTrend(current: currentMemoryUsage, previous: previousMemoryUsage)
        previousMemoryUsed = memoryUsed
    }
    
 /// 计算趋势方向
    private func calculateTrend(current: Double, previous: Double) -> TrendDirection {
        let threshold = 0.1 // 1% 的变化阈值
        let change = current - previous
        
        if abs(change) < threshold {
            return .stable
        } else if change > 0 {
            return .up
        } else {
            return .down
        }
    }
    
 /// 更新CPU和网络历史数据
    private func updateCPUAndNetworkHistoryData() {
        cpuHistory.append(cpuUsage)
        networkUploadHistory.append(networkUpload)
        networkDownloadHistory.append(networkDownload)
        
 // 限制历史数据数量
        if cpuHistory.count > maxHistoryCount {
            cpuHistory.removeFirst()
        }
        if networkUploadHistory.count > maxHistoryCount {
            networkUploadHistory.removeFirst()
        }
        if networkDownloadHistory.count > maxHistoryCount {
            networkDownloadHistory.removeFirst()
        }
    }
    
 /// 更新内存历史数据
    private func updateMemoryHistoryData() {
        let memoryUsagePercentage = memoryTotal > 0 ? Double(memoryUsed) / Double(memoryTotal) * 100.0 : 0.0
        memoryHistory.append(memoryUsagePercentage)
        
        if memoryHistory.count > maxHistoryCount {
            memoryHistory.removeFirst()
        }
    }
    
 /// 更新系统状态
    private func updateSystemStatus() {
        let memoryUsagePercentage = memoryTotal > 0 ? Double(memoryUsed) / Double(memoryTotal) * 100.0 : 0.0
        
        if cpuUsage > 80.0 || memoryUsagePercentage > 80.0 || systemLoad > 2.0 {
            systemStatus = .critical
        } else if cpuUsage > 60.0 || memoryUsagePercentage > 60.0 || systemLoad > 1.0 {
            systemStatus = .warning
        } else {
            systemStatus = .normal
        }
    }
    
 // MARK: - 清理资源
    
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

// MARK: - 磁盘使用情况结构体

public struct DiskUsage: Identifiable, Sendable {
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