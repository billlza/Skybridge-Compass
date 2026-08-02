// macOS-exclusive: built on macOS-only APIs (AppKit / IOKit / ScreenCaptureKit / CoreWLAN /
// MetalFX / ServiceManagement / ApplicationServices / CoreGraphics display services).
// Excluded from other platforms so SkyBridgeCore can be the single shared core for iOS as
// well. No behaviour changes on macOS.
#if os(macOS)
import SwiftUI

/// 系统监控设置视图 - 提供监控配置选项
/// 符合macOS设计规范，提供直观的设置界面
public struct SystemMonitorSettingsView: View {

 // MARK: - 绑定属性

    @Binding var isPresented: Bool

 // MARK: - 状态属性

    @State private var refreshInterval: Double = 1.0
    @State private var enableNotifications: Bool = true
    @State private var cpuThreshold: Double = 80.0
    @State private var memoryThreshold: Double = 80.0
    @State private var diskThreshold: Double = 90.0
    @State private var enableAutoRefresh: Bool = true
    @State private var showTrendIndicators: Bool = true
    @State private var enableSoundAlerts: Bool = false
    @State private var maxHistoryPoints: Double = 300.0

 // 新增：性能警报设置
    @State private var enablePerformanceAlerts: Bool = true
    @State private var temperatureThreshold: Double = 80.0
    @State private var enableTemperatureMonitoring: Bool = true
    @State private var enableFanSpeedMonitoring: Bool = true
    @State private var fanSpeedThreshold: Double = 4000.0
    @State private var enableThermalThrottlingAlert: Bool = true

    @StateObject private var settingsManager = SettingsManager.shared

 // MARK: - 初始化

    public init(isPresented: Binding<Bool>) {
        self._isPresented = isPresented
    }

 // MARK: - 视图主体

    public var body: some View {
        NavigationView {
            Form {
 // 刷新设置
                refreshSettingsSection

 // 阈值设置
                thresholdSettingsSection

 // 新增：性能警报设置
                performanceAlertsSection

 // 显示设置
                displaySettingsSection

 // 通知设置
                notificationSettingsSection

 // 高级设置
                advancedSettingsSection
            }
            .formStyle(.grouped)
            .navigationTitle("监控设置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        isPresented = false
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        saveSettings()
                        isPresented = false
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(width: 500, height: 600)
        .onAppear {
            loadSettings()
        }
    }

 // MARK: - 设置分组

    private var refreshSettingsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("启用自动刷新", isOn: $enableAutoRefresh)

                if enableAutoRefresh {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("刷新间隔")
                            Spacer()
                            Text("\(refreshInterval, specifier: "%.1f")秒")
                                .foregroundColor(.secondary)
                        }

                        Slider(value: $refreshInterval, in: 0.5...10.0, step: 0.5) {
                            Text("刷新间隔")
                        }
                        .disabled(!enableAutoRefresh)
                    }
                }
            }
        } header: {
            Label("刷新设置", systemImage: "arrow.clockwise")
        } footer: {
            Text("设置系统监控数据的刷新频率。较高的频率会消耗更多系统资源。")
        }
    }

    private var thresholdSettingsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 16) {
 // CPU阈值
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("CPU使用率警告阈值")
                        Spacer()
                        Text("\(cpuThreshold, specifier: "%.0f")%")
                            .foregroundColor(.secondary)
                    }

                    Slider(value: $cpuThreshold, in: 50...95, step: 5) {
                        Text("CPU阈值")
                    }
                }

 // 内存阈值
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("内存使用率警告阈值")
                        Spacer()
                        Text("\(memoryThreshold, specifier: "%.0f")%")
                            .foregroundColor(.secondary)
                    }

                    Slider(value: $memoryThreshold, in: 50...95, step: 5) {
                        Text("内存阈值")
                    }
                }

 // 磁盘阈值
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("磁盘使用率警告阈值")
                        Spacer()
                        Text("\(diskThreshold, specifier: "%.0f")%")
                            .foregroundColor(.secondary)
                    }

                    Slider(value: $diskThreshold, in: 70...98, step: 2) {
                        Text("磁盘阈值")
                    }
                }
            }
        } header: {
            Label("警告阈值", systemImage: "exclamationmark.triangle")
        } footer: {
            Text("当系统资源使用率超过设定阈值时，将显示警告提示。")
        }
    }

 // MARK: - 新增：性能警报设置分组

    private var performanceAlertsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 16) {
 // 启用性能警报总开关
                Toggle("启用性能警报", isOn: $enablePerformanceAlerts)

                if enablePerformanceAlerts {
                    Divider()

 // 温度监控设置
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("启用温度监控", isOn: $enableTemperatureMonitoring)

                        if enableTemperatureMonitoring {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("温度警告阈值")
                                    Spacer()
                                    Text("\(temperatureThreshold, specifier: "%.0f")°C")
                                        .foregroundColor(.secondary)
                                }

                                Slider(value: $temperatureThreshold, in: 60...95, step: 5) {
                                    Text("温度阈值")
                                }
                            }
                        }
                    }

                    Divider()

 // 风扇转速监控设置
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("启用风扇转速监控", isOn: $enableFanSpeedMonitoring)

                        if enableFanSpeedMonitoring {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("风扇转速警告阈值")
                                    Spacer()
                                    Text("\(fanSpeedThreshold, specifier: "%.0f") RPM")
                                        .foregroundColor(.secondary)
                                }

                                Slider(value: $fanSpeedThreshold, in: 2000...8000, step: 200) {
                                    Text("风扇转速阈值")
                                }
                            }
                        }
                    }

                    Divider()

 // 热量节流警报
                    Toggle("启用热量节流警报", isOn: $enableThermalThrottlingAlert)
                }
            }
        } header: {
            Label("性能警报", systemImage: "thermometer")
        } footer: {
            Text("监控系统温度和风扇转速，当超过阈值或发生热量节流时发出警报。")
        }
    }

    private var displaySettingsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("显示趋势指示器", isOn: $showTrendIndicators)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("历史数据点数量")
                        Spacer()
                        Text("\(maxHistoryPoints, specifier: "%.0f")个")
                            .foregroundColor(.secondary)
                    }

                    Slider(value: $maxHistoryPoints, in: 60...600, step: 60) {
                        Text("历史数据点")
                    }
                }
            }
        } header: {
            Label("显示设置", systemImage: "eye")
        } footer: {
            Text("配置监控界面的显示选项。更多历史数据点会占用更多内存。")
        }
    }

    private var notificationSettingsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("启用通知提醒", isOn: $enableNotifications)

                Toggle("启用声音提醒", isOn: $enableSoundAlerts)
                    .disabled(!enableNotifications)
            }
        } header: {
            Label("通知设置", systemImage: "bell")
        } footer: {
            Text("当系统资源使用率超过阈值时发送通知提醒。")
        }
    }

    private var advancedSettingsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Button("重置为默认设置") {
                    resetToDefaults()
                }
                .foregroundColor(.red)

                Button("导出监控数据") {
                    exportMonitoringData()
                }

                Button("清除历史数据") {
                    clearHistoryData()
                }
                .foregroundColor(.orange)
            }
        } header: {
            Label("高级设置", systemImage: "gearshape.2")
        }
    }

 // MARK: - 私有方法

    private func loadSettings() {
        // 统一来源：以 SettingsManager 为准（它负责持久化/跨页面一致性）。
        refreshInterval = settingsManager.systemMonitorRefreshInterval
        enableNotifications = settingsManager.enableSystemNotifications
        cpuThreshold = settingsManager.cpuThreshold
        memoryThreshold = settingsManager.memoryThreshold
        diskThreshold = settingsManager.diskThreshold
        enableAutoRefresh = settingsManager.enableAutoRefresh
        showTrendIndicators = settingsManager.showTrendIndicators
        enableSoundAlerts = settingsManager.enableSoundAlerts
        maxHistoryPoints = settingsManager.maxHistoryPoints
        enablePerformanceAlerts = settingsManager.enablePerformanceAlerts
        temperatureThreshold = settingsManager.temperatureThreshold
        enableTemperatureMonitoring = settingsManager.enableTemperatureMonitoring
        enableFanSpeedMonitoring = settingsManager.enableFanSpeedMonitoring
        fanSpeedThreshold = settingsManager.fanSpeedThreshold
        enableThermalThrottlingAlert = settingsManager.enableThermalThrottlingAlert
    }

    private func saveSettings() {
        // 主存储：写回 SettingsManager（它会持久化到 UserDefaults.Settings.*）
        settingsManager.systemMonitorRefreshInterval = refreshInterval
        settingsManager.enableSystemNotifications = enableNotifications
        settingsManager.cpuThreshold = cpuThreshold
        settingsManager.memoryThreshold = memoryThreshold
        settingsManager.diskThreshold = diskThreshold
        settingsManager.enableAutoRefresh = enableAutoRefresh
        settingsManager.showTrendIndicators = showTrendIndicators
        settingsManager.enableSoundAlerts = enableSoundAlerts
        settingsManager.maxHistoryPoints = maxHistoryPoints
        settingsManager.enablePerformanceAlerts = enablePerformanceAlerts
        settingsManager.temperatureThreshold = temperatureThreshold
        settingsManager.enableTemperatureMonitoring = enableTemperatureMonitoring
        settingsManager.enableFanSpeedMonitoring = enableFanSpeedMonitoring
        settingsManager.fanSpeedThreshold = fanSpeedThreshold
        settingsManager.enableThermalThrottlingAlert = enableThermalThrottlingAlert

        // 兼容存储：旧 key 仍写一份，避免其他遗留模块读取不到
        let defaults = UserDefaults.standard
        defaults.set(refreshInterval, forKey: "SystemMonitor.RefreshInterval")
        defaults.set(enableNotifications, forKey: "SystemMonitor.EnableNotifications")
        defaults.set(cpuThreshold, forKey: "SystemMonitor.CPUThreshold")
        defaults.set(memoryThreshold, forKey: "SystemMonitor.MemoryThreshold")
        defaults.set(diskThreshold, forKey: "SystemMonitor.DiskThreshold")
        defaults.set(enableAutoRefresh, forKey: "SystemMonitor.EnableAutoRefresh")
        defaults.set(showTrendIndicators, forKey: "SystemMonitor.ShowTrendIndicators")
        defaults.set(enableSoundAlerts, forKey: "SystemMonitor.EnableSoundAlerts")
        defaults.set(maxHistoryPoints, forKey: "SystemMonitor.MaxHistoryPoints")
        defaults.set(enablePerformanceAlerts, forKey: "SystemMonitor.EnablePerformanceAlerts")
        defaults.set(temperatureThreshold, forKey: "SystemMonitor.TemperatureThreshold")
        defaults.set(enableTemperatureMonitoring, forKey: "SystemMonitor.EnableTemperatureMonitoring")
        defaults.set(enableFanSpeedMonitoring, forKey: "SystemMonitor.EnableFanSpeedMonitoring")
        defaults.set(fanSpeedThreshold, forKey: "SystemMonitor.FanSpeedThreshold")
        defaults.set(enableThermalThrottlingAlert, forKey: "SystemMonitor.EnableThermalThrottlingAlert")

        SkyBridgeLogger.ui.debugOnly("✅ 系统监控设置已保存")
    }

    private func resetToDefaults() {
        refreshInterval = 1.0
        enableNotifications = true
        cpuThreshold = 80.0
        memoryThreshold = 80.0
        diskThreshold = 90.0
        enableAutoRefresh = true
        showTrendIndicators = true
        enableSoundAlerts = false
        maxHistoryPoints = 300.0

 // 新增：重置性能警报设置为默认值
        enablePerformanceAlerts = true
        temperatureThreshold = 80.0
        enableTemperatureMonitoring = true
        enableFanSpeedMonitoring = true
        fanSpeedThreshold = 4000.0
        enableThermalThrottlingAlert = true

        SkyBridgeLogger.ui.debugOnly("🔄 已重置为默认设置")
    }

    private func exportMonitoringData() {
 // 发送导出通知，由 SystemMetricsService 执行导出到桌面。
        NotificationCenter.default.post(name: .systemMonitorExport, object: nil)
    }

    private func clearHistoryData() {
 // 发送清除历史通知，由 SystemMetricsService 清空时间线数据。
        NotificationCenter.default.post(name: .systemMonitorClearHistory, object: nil)
    }
}

// MARK: - 预览

struct SystemMonitorSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SystemMonitorSettingsView(isPresented: .constant(true))
    }
}
#endif
