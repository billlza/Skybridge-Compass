import SwiftUI
import Combine
import UserNotifications

/// 设置界面 - 提供完整的应用配置和设备管理设置
/// 适配平铺显示模式，符合macOS设计规范
@available(macOS 14.0, *)
public struct SettingsView: View {
    
    // MARK: - 状态管理
    @StateObject private var settingsManager = SettingsManager.shared
    @StateObject private var permissionManager = DevicePermissionManager()
    @StateObject private var wifiManager = WiFiManager()
    @StateObject private var bluetoothManager = BluetoothManager()
    @StateObject private var airplayManager = AirPlayManager()
    @StateObject private var videoSettingsManager = VideoTransferSettingsManager.shared
    // 注释掉跨模块依赖的管理器，避免循环依赖
    // @StateObject private var performanceModeManager = PerformanceModeManager.shared
    // @StateObject private var realTimeWeatherService = RealTimeWeatherService.shared
    
    @State private var selectedTab: SettingsTab = .general
    @State private var showingPermissionAlert = false
    @State private var showingResetAlert = false
    @State private var showingExportDialog = false
    @State private var showingImportDialog = false
    
    // MARK: - 设置标签页
    enum SettingsTab: String, CaseIterable {
        case general = "通用"
        case network = "网络"
        case devices = "设备"
        case fileTransfer = "文件传输"
        case remoteDesktop = "远程桌面"
        case systemMonitor = "系统监控"
        case permissions = "权限"
        case advanced = "高级"
        
        var iconName: String {
            switch self {
            case .general:
                return "gearshape"
            case .network:
                return "network"
            case .devices:
                return "externaldrive.connected.to.line.below"
            case .fileTransfer:
                return "folder.badge.gearshape"
            case .remoteDesktop:
                return "display"
            case .systemMonitor:
                return "chart.line.uptrend.xyaxis"
            case .permissions:
                return "lock.shield"
            case .advanced:
                return "slider.horizontal.3"
            }
        }
    }
    
    public init() {}
    
    public var body: some View {
        VStack(spacing: 0) {
            // 顶部标题栏
            settingsHeader
            
            Divider()
            
            // 主要内容区域 - 使用HStack布局
            HStack(spacing: 0) {
                // 左侧设置分类列表
                settingsSidebar
                    .frame(width: 200)
                
                Divider()
                
                // 右侧详细设置内容
                settingsDetail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
        .alert("权限提醒", isPresented: $showingPermissionAlert) {
            Button("打开系统偏好设置") {
                permissionManager.openSystemPreferences()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("某些功能需要系统权限才能正常工作。请在系统偏好设置中授权相关权限。")
        }
        .alert("重置确认", isPresented: $showingResetAlert) {
            Button("重置", role: .destructive) {
                resetAllSettings()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这将重置所有设置到默认值。此操作无法撤销。")
        }
        .fileExporter(
            isPresented: $showingExportDialog,
            document: SettingsDocument(data: Data()), // 临时空数据，实际导出在回调中处理
            contentType: .json,
            defaultFilename: "SkyBridge设置备份"
        ) { result in
            switch result {
            case .success(let url):
                // 使用Task来处理异步导出操作，遵循Swift并发最佳实践
                Task { @MainActor in
                    do {
                        let exportedURL = try await settingsManager.exportSettings()
                        // 将导出的文件复制到用户选择的位置
                        try FileManager.default.copyItem(at: exportedURL, to: url)
                        print("✅ 设置已导出到: \(url)")
                    } catch {
                        print("❌ 导出失败: \(error.localizedDescription)")
                    }
                }
            case .failure(let error):
                print("❌ 导出失败: \(error)")
            }
        }
        .fileImporter(
            isPresented: $showingImportDialog,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    // 使用Task来处理异步导入操作，遵循Swift并发最佳实践
                    Task { @MainActor in
                        do {
                            try await settingsManager.importSettings(from: url)
                            print("✅ 设置导入成功")
                        } catch {
                            print("❌ 设置导入失败: \(error.localizedDescription)")
                        }
                    }
                }
            case .failure(let error):
                print("❌ 导入失败: \(error)")
            }
        }
    }
    
    // MARK: - 顶部标题栏
    private var settingsHeader: some View {
        HStack {
            Image(systemName: "gearshape")
                .font(.title2)
                .foregroundColor(.blue)
            
            Text("设置")
                .font(.title2.bold())
                .foregroundColor(.primary)
            
            Spacer()
            
            // 快速操作按钮
            HStack(spacing: 8) {
                Button(action: { showingExportDialog = true }) {
                    Image(systemName: "square.and.arrow.up")
                }
                .help("导出设置")
                
                Button(action: { showingImportDialog = true }) {
                    Image(systemName: "square.and.arrow.down")
                }
                .help("导入设置")
                
                Button(action: { showingResetAlert = true }) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("重置设置")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - 侧边栏
    private var settingsSidebar: some View {
        VStack(spacing: 0) {
            // 顶部标题
            HStack {
                Text("设置")
                    .font(.title2.bold())
                    .foregroundColor(.primary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
            
            Divider()
            
            // 设置选项列表
            List(SettingsTab.allCases, id: \.self, selection: $selectedTab) { tab in
                Label(tab.rawValue, systemImage: tab.iconName)
                    .tag(tab)
                    .font(.system(size: 13, weight: .medium))
                    .padding(.vertical, 2)
            }
            .listStyle(SidebarListStyle())
            .scrollContentBackground(.hidden)
            
            Spacer()
        }
        .background(Color(NSColor.controlBackgroundColor))
    }
    
    // MARK: - 详细内容
    private var settingsDetail: some View {
        Group {
            switch selectedTab {
            case .general:
                generalSettings
            case .network:
                networkSettings
            case .devices:
                deviceSettings
            case .fileTransfer:
                fileTransferSettings
            case .remoteDesktop:
                remoteDesktopSettings
            case .systemMonitor:
                systemMonitorSettings
            case .permissions:
                permissionSettings
            case .advanced:
                advancedSettings
            }
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(NSColor.controlBackgroundColor))
    }
    
    // MARK: - 通用设置
    private var generalSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                settingsSection("应用偏好") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("启动时自动扫描设备", isOn: $settingsManager.autoScanOnStartup)
                            .onChange(of: settingsManager.autoScanOnStartup) { _, newValue in
                                // 实际保存设置到UserDefaults
                                UserDefaults.standard.set(newValue, forKey: "AutoScanOnStartup")
                                print("✅ 自动扫描设置已更新: \(newValue)")
                            }
                        
                        Toggle("显示系统通知", isOn: $settingsManager.showSystemNotifications)
                            .onChange(of: settingsManager.showSystemNotifications) { _, newValue in
                                // 请求通知权限
                                if newValue {
                                    requestNotificationPermission()
                                }
                                UserDefaults.standard.set(newValue, forKey: "ShowSystemNotifications")
                                print("✅ 系统通知设置已更新: \(newValue)")
                            }
                        
                        Toggle("深色模式", isOn: $settingsManager.useDarkMode)
                            .onChange(of: settingsManager.useDarkMode) { _, newValue in
                                // 应用主题模式
                                applyThemeMode(newValue ? "dark" : "light")
                                UserDefaults.standard.set(newValue, forKey: "UseDarkMode")
                                print("✅ 深色模式设置已更新: \(newValue)")
                            }
                        
                        HStack {
                            Text("扫描间隔:")
                            Picker("", selection: $settingsManager.scanInterval) {
                                Text("15秒").tag(15)
                                Text("30秒").tag(30)
                                Text("60秒").tag(60)
                                Text("120秒").tag(120)
                            }
                            .pickerStyle(MenuPickerStyle())
                            .frame(width: 100)
                            .onChange(of: settingsManager.scanInterval) { _, newValue in
                                // 更新扫描定时器
                                updateScanInterval(newValue)
                                UserDefaults.standard.set(newValue, forKey: "ScanInterval")
                                print("✅ 扫描间隔已更新: \(newValue)秒")
                            }
                        }
                    }
                }
                
                settingsSection("界面设置") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("显示设备详细信息", isOn: $settingsManager.showDeviceDetails)
                            .onChange(of: settingsManager.showDeviceDetails) { _, _ in
                                UserDefaults.standard.set(settingsManager.showDeviceDetails, forKey: "ShowDeviceDetails")
                                // 通知其他组件更新显示模式
                                NotificationCenter.default.post(name: NSNotification.Name("DeviceDisplayModeChanged"), object: nil)
                                print("✅ 设备详细信息显示设置已更新: \(settingsManager.showDeviceDetails)")
                            }
                        
                        Toggle("显示连接统计", isOn: $settingsManager.showConnectionStats)
                            .onChange(of: settingsManager.showConnectionStats) { _, _ in
                                UserDefaults.standard.set(settingsManager.showConnectionStats, forKey: "ShowConnectionStats")
                                NotificationCenter.default.post(name: NSNotification.Name("ConnectionStatsDisplayChanged"), object: nil)
                                print("✅ 连接统计显示设置已更新: \(settingsManager.showConnectionStats)")
                            }
                        
                        Toggle("紧凑模式", isOn: $settingsManager.compactMode)
                            .onChange(of: settingsManager.compactMode) { _, _ in
                                UserDefaults.standard.set(settingsManager.compactMode, forKey: "CompactMode")
                                // 实际切换布局模式
                                switchLayoutMode(isCompact: settingsManager.compactMode)
                                print("✅ 紧凑模式设置已更新: \(settingsManager.compactMode)")
                            }
                        
                        HStack {
                            Text("主题色彩:")
                            ColorPicker("", selection: $settingsManager.themeColor)
                                .frame(width: 50)
                                .onChange(of: settingsManager.themeColor) { _, newColor in
                                    // 实际应用主题色彩
                                    applyThemeColor(newColor)
                                    // 保存颜色到UserDefaults
                                    if let colorData = try? NSKeyedArchiver.archivedData(withRootObject: NSColor(newColor), requiringSecureCoding: false) {
                                        UserDefaults.standard.set(colorData, forKey: "ThemeColor")
                                    }
                                    print("✅ 主题色彩已更新")
                                }
                        }
                    }
                }
                
                settingsSection("数据管理") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Button("清除缓存") {
                                // 实际清除缓存操作
                                clearApplicationCache()
                            }
                            .buttonStyle(.bordered)
                            
                            Spacer()
                            
                            Text("缓存大小: \(getFormattedCacheSize())")
                                .foregroundColor(.secondary)
                        }
                        
                        HStack {
                            Button("导出设置") {
                                showingExportDialog = true
                            }
                            .buttonStyle(.bordered)
                            
                            Button("导入设置") {
                                showingImportDialog = true
                            }
                            .buttonStyle(.bordered)
                            
                            Spacer()
                        }
                        
                        HStack {
                            Button("重置所有设置") {
                                showingResetAlert = true
                            }
                            .buttonStyle(.bordered)
                            .foregroundColor(.red)
                            
                            Spacer()
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - 网络设置
    private var networkSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                settingsSection("WiFi配置") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("当前网络:")
                            Text(wifiManager.currentNetwork?.ssid ?? "未连接")
                                .fontWeight(.medium)
                            Spacer()
                            Button("刷新") {
                                Task {
                                    await wifiManager.refreshNetworks()
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                        
                        Toggle("自动连接已知网络", isOn: $settingsManager.autoConnectKnownNetworks)
                        Toggle("显示隐藏网络", isOn: $settingsManager.showHiddenNetworks)
                        Toggle("优先使用5GHz频段", isOn: $settingsManager.prefer5GHz)
                        
                        HStack {
                            Text("扫描超时:")
                            Picker("", selection: $settingsManager.wifiScanTimeout) {
                                Text("5秒").tag(5)
                                Text("10秒").tag(10)
                                Text("15秒").tag(15)
                                Text("30秒").tag(30)
                            }
                            .pickerStyle(MenuPickerStyle())
                            .frame(width: 100)
                        }
                    }
                }
                
                settingsSection("网络发现") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("启用Bonjour发现", isOn: $settingsManager.enableBonjourDiscovery)
                        Toggle("启用mDNS解析", isOn: $settingsManager.enableMDNSResolution)
                        Toggle("扫描自定义端口", isOn: $settingsManager.scanCustomPorts)
                        
                        HStack {
                            Text("发现超时:")
                            TextField("秒", value: $settingsManager.discoveryTimeout, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                        }
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("自定义服务类型:")
                                .fontWeight(.medium)
                            
                            HStack {
                                TextField("例如: _custom._tcp.", text: .constant(""))
                                    .textFieldStyle(.roundedBorder)
                                
                                Button("添加") {
                                    // 添加自定义服务类型
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }
                
                settingsSection("连接设置") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("连接超时:")
                            TextField("秒", value: $settingsManager.connectionTimeout, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                        }
                        
                        HStack {
                            Text("重试次数:")
                            TextField("次", value: $settingsManager.retryCount, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                        }
                        
                        Toggle("启用连接加密", isOn: $settingsManager.enableConnectionEncryption)
                        Toggle("验证证书", isOn: $settingsManager.verifyCertificates)
                    }
                }
            }
        }
    }
    
    // MARK: - 设备设置
    private var deviceSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                settingsSection("蓝牙设置") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("蓝牙状态:")
                            Text(bluetoothManager.managerState.description)
                                .fontWeight(.medium)
                                .foregroundColor(bluetoothManager.managerState == BluetoothManagerState.poweredOn ? .green : .red)
                            Spacer()
                            
                            if bluetoothManager.isScanning {
                                ProgressView()
                                    .scaleEffect(0.8)
                            }
                        }
                        
                        HStack {
                            Button(bluetoothManager.isScanning ? "停止扫描" : "开始扫描") {
                                if bluetoothManager.isScanning {
                                    bluetoothManager.stopScanning()
                                } else {
                                    bluetoothManager.startScanning()
                                }
                            }
                            .buttonStyle(.bordered)
                            
                            Spacer()
                            
                            Text("已发现: \(bluetoothManager.discoveredDevices.count) 设备")
                                .foregroundColor(.secondary)
                        }
                        
                        Toggle("自动连接已配对设备", isOn: $settingsManager.autoConnectPairedDevices)
                        Toggle("显示设备RSSI", isOn: $settingsManager.showDeviceRSSI)
                        Toggle("仅显示可连接设备", isOn: $settingsManager.showConnectableDevicesOnly)
                    }
                }
                
                settingsSection("AirPlay设置") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("AirPlay状态:")
                            Text(airplayManager.isScanning ? "扫描中" : "空闲")
                                .fontWeight(.medium)
                                .foregroundColor(airplayManager.isScanning ? .blue : .secondary)
                            Spacer()
                            
                            if airplayManager.isScanning {
                                ProgressView()
                                    .scaleEffect(0.8)
                            }
                        }
                        
                        HStack {
                            Button(airplayManager.isScanning ? "停止扫描" : "开始扫描") {
                                if airplayManager.isScanning {
                                    airplayManager.stopScanning()
                                } else {
                                    airplayManager.startScanning()
                                }
                            }
                            .buttonStyle(.bordered)
                            
                            Spacer()
                            
                            Text("已发现: \(airplayManager.discoveredDevices.count) 设备")
                                .foregroundColor(.secondary)
                        }
                        
                        Toggle("自动发现Apple TV", isOn: $settingsManager.autoDiscoverAppleTV)
                        Toggle("显示HomePod设备", isOn: $settingsManager.showHomePodDevices)
                        Toggle("显示第三方AirPlay设备", isOn: $settingsManager.showThirdPartyAirPlayDevices)
                    }
                }
                
                settingsSection("设备过滤") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("隐藏离线设备", isOn: $settingsManager.hideOfflineDevices)
                        Toggle("按信号强度排序", isOn: $settingsManager.sortBySignalStrength)
                        Toggle("显示设备图标", isOn: $settingsManager.showDeviceIcons)
                        
                        HStack {
                            Text("最小信号强度:")
                            Slider(value: $settingsManager.minimumSignalStrength, in: -100...(-30))
                            Text("\(Int(settingsManager.minimumSignalStrength)) dBm")
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - 权限设置
    private var permissionSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                settingsSection("权限状态") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("权限摘要:")
                            Text(permissionManager.permissionSummary)
                                .fontWeight(.medium)
                            Spacer()
                            
                            Button("刷新状态") {
                                permissionManager.checkAllPermissions()
                            }
                            .buttonStyle(.bordered)
                        }
                        
                        if !permissionManager.allRequiredPermissionsGranted {
                            HStack {
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundColor(.orange)
                                Text("某些必需权限未授权，可能影响功能正常使用")
                                    .foregroundColor(.orange)
                                Spacer()
                                
                                Button("请求权限") {
                                    Task {
                                        await permissionManager.requestAllRequiredPermissions()
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .padding()
                            .background(Color.orange.opacity(0.1))
                            .cornerRadius(8)
                        }
                    }
                }
                
                settingsSection("详细权限") {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(permissionManager.permissions) { permission in
                            permissionRow(permission)
                        }
                    }
                }
                
                settingsSection("权限帮助") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("权限说明:")
                            .fontWeight(.medium)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("• WiFi网络访问: 扫描和连接WiFi网络")
                            Text("• 蓝牙设备访问: 发现和连接蓝牙设备")
                            Text("• 位置服务: WiFi扫描可能需要位置权限")
                            Text("• 系统配置: 访问网络配置信息")
                        }
                        .foregroundColor(.secondary)
                        
                        HStack {
                            Button("打开系统偏好设置") {
                                permissionManager.openSystemPreferences()
                            }
                            .buttonStyle(.bordered)
                            
                            Spacer()
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - 高级设置
    private var advancedSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                settingsSection("调试选项") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("启用详细日志", isOn: $settingsManager.enableVerboseLogging)
                        Toggle("显示调试信息", isOn: $settingsManager.showDebugInfo)
                        Toggle("保存网络日志", isOn: $settingsManager.saveNetworkLogs)
                        
                        HStack {
                            Text("日志级别:")
                            Picker("", selection: $settingsManager.logLevel) {
                                Text("Error").tag("Error")
                                Text("Warning").tag("Warning")
                                Text("Info").tag("Info")
                                Text("Debug").tag("Debug")
                            }
                            .pickerStyle(MenuPickerStyle())
                            .frame(width: 100)
                        }
                    }
                }
                
                settingsSection("性能优化") {
                    VStack(alignment: .leading, spacing: 12) {
                        // 性能模式选择
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("性能模式:")
                                    .font(.system(size: 13, weight: .medium))
                                Spacer()
                                Text("当前: 平衡模式")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            // 注意：由于模块依赖问题，性能模式功能暂时禁用
                            VStack(alignment: .leading, spacing: 6) {
                                Text("配置详情:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("渲染缩放: 100%")
                                        Text("最大粒子: 1000")
                                        Text("目标帧率: 60 FPS")
                                    }
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                    
                                    Spacer()
                                    
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text("MetalFX: 100%")
                                        Text("阴影质量: 高")
                                        Text("后处理: 启用")
                                    }
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                                .cornerRadius(4)
                            }
                        }
                        
                        Divider()
                        
                        // 实时天气API设置
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("实时天气API:")
                                    .font(.system(size: 13, weight: .medium))
                                Spacer()
                                Text("已禁用")
                                        .font(.caption)
                                        .foregroundColor(.orange)
                            }
                            
                            Toggle("启用基于定位的实时天气", isOn: .constant(false))
                            
                            // 注意：由于模块依赖问题，实时天气功能暂时禁用
                            HStack {
                                Text("状态:")
                                Spacer()
                                Text("已禁用")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        Divider()
                        
                        Toggle("启用硬件加速", isOn: $settingsManager.enableHardwareAcceleration)
                        Toggle("优化内存使用", isOn: $settingsManager.optimizeMemoryUsage)
                        Toggle("后台扫描", isOn: $settingsManager.enableBackgroundScanning)
                        
                        HStack {
                            Text("最大并发连接:")
                            TextField("数量", value: $settingsManager.maxConcurrentConnections, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                        }
                    }
                }
                
                settingsSection("实验性功能") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("启用IPv6支持", isOn: $settingsManager.enableIPv6Support)
                        Toggle("使用新的发现算法", isOn: $settingsManager.useNewDiscoveryAlgorithm)
                        Toggle("启用P2P直连", isOn: $settingsManager.enableP2PDirectConnection)
                        
                        Text("⚠️ 实验性功能可能不稳定")
                            .foregroundColor(.orange)
                            .font(.caption)
                    }
                }
                
                settingsSection("重置选项") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Button("重置所有设置") {
                                showingResetAlert = true
                            }
                            .buttonStyle(.bordered)
                            .foregroundColor(.red)
                            
                            Button("重置网络设置") {
                                settingsManager.resetNetworkSettings()
                            }
                            .buttonStyle(.bordered)
                            
                            Spacer()
                        }
                        
                        Text("重置操作无法撤销，请谨慎操作")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                }
            }
        }
    }
    
    // MARK: - 辅助视图
    
    /// 设置分组
    private func settingsSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 4)
            
            content()
                .padding(16)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
                )
        }
        .padding(.horizontal, 20)
    }
    
    /// 权限行
    private func permissionRow(_ permission: PermissionInfo) -> some View {
        HStack {
            Image(systemName: permission.type.iconName)
                .foregroundColor(.blue)
                .frame(width: 20)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.type.description)
                    .fontWeight(.medium)
                
                Text(permission.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            VStack(alignment: .trailing, spacing: 2) {
                Text(permissionManager.statusDescription(for: permission.type))
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(Color(permission.status.color))
                
                if !permission.status.isAuthorized && permission.isRequired {
                    Button("请求") {
                        Task {
                            await permissionManager.requestPermission(for: permission.type)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
        }
        .padding(.vertical, 4)
    }
    
    // MARK: - 文件传输设置
    private var fileTransferSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // 视频传输配置部分
                videoTransferConfigurationSection
                
                settingsSection("传输配置") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("默认传输路径:")
                            TextField("路径", text: .constant("~/Downloads"))
                                .textFieldStyle(.roundedBorder)
                            Button("选择") {
                                // 选择文件夹逻辑
                            }
                            .buttonStyle(.bordered)
                        }
                        
                        HStack {
                            Text("最大并发传输:")
                            TextField("数量", value: $settingsManager.maxConcurrentConnections, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                        }
                        
                        HStack {
                            Text("传输缓冲区大小:")
                            Picker("", selection: .constant(131072)) {
                                Text("64KB").tag(65536)
                                Text("128KB").tag(131072)
                                Text("256KB").tag(262144)
                                Text("512KB").tag(524288)
                                Text("1MB").tag(1048576)
                            }
                            .pickerStyle(MenuPickerStyle())
                            .frame(width: 100)
                        }
                    }
                }
                
                settingsSection("传输选项") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("传输完成后显示通知", isOn: $settingsManager.showSystemNotifications)
                        Toggle("自动重试失败的传输", isOn: .constant(true))
                        Toggle("保持传输历史记录", isOn: .constant(true))
                        Toggle("传输时保持系统唤醒", isOn: .constant(false))
                        
                        HStack {
                            Text("重试次数:")
                            TextField("次", value: $settingsManager.retryCount, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                        }
                    }
                }
                
                settingsSection("安全设置") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("启用传输加密", isOn: $settingsManager.enableConnectionEncryption)
                        Toggle("验证文件完整性", isOn: $settingsManager.verifyCertificates)
                        Toggle("扫描传输文件病毒", isOn: .constant(false))
                        
                        HStack {
                            Text("加密算法:")
                            Picker("", selection: .constant("AES-256")) {
                                Text("AES-256").tag("AES-256")
                                Text("ChaCha20").tag("ChaCha20")
                                Text("AES-128").tag("AES-128")
                            }
                            .pickerStyle(MenuPickerStyle())
                            .frame(width: 120)
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - 视频传输配置部分
    
    private var videoTransferConfigurationSection: some View {
        settingsSection("视频传输配置") {
            VStack(alignment: .leading, spacing: 16) {
                // 当前配置状态显示 - 增强版本，包含实时状态指示器
                HStack {
                    // 动态状态指示器
                    ZStack {
                        Circle()
                            .fill(videoSettingsManager.isConfigurationOptimal ? Color.green.opacity(0.2) : Color.orange.opacity(0.2))
                            .frame(width: 40, height: 40)
                            .scaleEffect(videoSettingsManager.isConfigurationOptimal ? 1.0 : 1.1)
                            .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: videoSettingsManager.isConfigurationOptimal)
                        
                        Image(systemName: videoSettingsManager.isConfigurationOptimal ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(videoSettingsManager.isConfigurationOptimal ? .green : .orange)
                            .font(.title2)
                            .scaleEffect(videoSettingsManager.isConfigurationOptimal ? 1.0 : 0.9)
                            .animation(.spring(response: 0.5, dampingFraction: 0.6), value: videoSettingsManager.isConfigurationOptimal)
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("当前配置")
                                .font(.headline)
                            
                            // 配置状态徽章
                            Text(videoSettingsManager.isConfigurationOptimal ? "已优化" : "需调整")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(videoSettingsManager.isConfigurationOptimal ? Color.green : Color.orange)
                                )
                                .scaleEffect(videoSettingsManager.isConfigurationOptimal ? 1.0 : 1.05)
                                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: videoSettingsManager.isConfigurationOptimal)
                        }
                        
                        Text(videoSettingsManager.configurationStatus)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .transition(.opacity.combined(with: .slide))
                            .animation(.easeInOut(duration: 0.3), value: videoSettingsManager.configurationStatus)
                    }
                    
                    Spacer()
                    
                    // 预估数据传输率 - 增强版本，包含动态更新动画
                    VStack(alignment: .trailing, spacing: 2) {
                        HStack(spacing: 4) {
                            // 传输率指示器
                            Circle()
                                .fill(videoSettingsManager.estimatedDataRate > 10 ? Color.red : 
                                      videoSettingsManager.estimatedDataRate > 5 ? Color.orange : Color.green)
                                .frame(width: 8, height: 8)
                                .scaleEffect(1.2)
                                .animation(.easeInOut(duration: 0.5), value: videoSettingsManager.estimatedDataRate)
                            
                            Text("预估传输率")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        HStack(spacing: 4) {
                            Text(String(format: "%.1f", videoSettingsManager.estimatedDataRate))
                                .font(.headline.monospacedDigit())
                                .foregroundColor(.blue)
                                .contentTransition(.numericText())
                                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: videoSettingsManager.estimatedDataRate)
                            
                            Text("MB/s")
                                .font(.caption)
                                .foregroundColor(.blue)
                        }
                        
                        // 传输率等级指示
                        Text(videoSettingsManager.estimatedDataRate > 10 ? "高负载" : 
                             videoSettingsManager.estimatedDataRate > 5 ? "中等负载" : "轻负载")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(videoSettingsManager.estimatedDataRate > 10 ? .red : 
                                           videoSettingsManager.estimatedDataRate > 5 ? .orange : .green)
                            .transition(.opacity.combined(with: .scale))
                            .animation(.easeInOut(duration: 0.3), value: videoSettingsManager.estimatedDataRate)
                    }
                }
                .padding(.bottom, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(NSColor.controlBackgroundColor).opacity(0.5))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(videoSettingsManager.isConfigurationOptimal ? Color.green.opacity(0.3) : Color.orange.opacity(0.3), lineWidth: 1)
                        )
                )
                .padding(.horizontal, 4)
                
                Divider()
                
                // 分辨率选择 - 增强版本，包含选择动画效果
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("视频分辨率")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Text("选择传输视频的分辨率规格")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: 8) {
                        ForEach(VideoResolution.allCases, id: \.self) { resolution in
                            resolutionOptionCard(resolution)
                                .scaleEffect(videoSettingsManager.selectedResolution == resolution ? 1.02 : 1.0)
                                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: videoSettingsManager.selectedResolution)
                        }
                    }
                }
                
                Divider()
                
                // 帧率选择 - 增强版本，包含选择动画效果
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("视频帧率")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Text("选择传输视频的帧率")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    HStack(spacing: 12) {
                        ForEach(VideoFrameRate.allCases, id: \.self) { frameRate in
                            frameRateOptionButton(frameRate)
                                .scaleEffect(videoSettingsManager.selectedFrameRate == frameRate ? 1.05 : 1.0)
                                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: videoSettingsManager.selectedFrameRate)
                        }
                        Spacer()
                    }
                }
                
                Divider()
                
                // 快速预设配置
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("快速预设")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Text("一键应用预设配置")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    HStack(spacing: 8) {
                        ForEach(VideoTransferPreset.allCases, id: \.self) { preset in
                            presetButton(preset)
                        }
                    }
                }
                
                // 高级选项
                DisclosureGroup("高级选项", isExpanded: $videoSettingsManager.showAdvancedOptions) {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("启用硬件加速", isOn: $videoSettingsManager.enableHardwareAcceleration)
                            .help("使用硬件编码器提升性能")
                        
                        Toggle("启用Apple Silicon优化", isOn: $videoSettingsManager.enableAppleSiliconOptimization)
                            .help("针对Apple Silicon芯片进行优化")
                        
                        Toggle("自适应比特率", isOn: $videoSettingsManager.enableAdaptiveBitrate)
                            .help("根据网络状况自动调整比特率")
                        
                        HStack {
                            Text("压缩质量:")
                            Picker("", selection: $videoSettingsManager.compressionQuality) {
                                ForEach(VideoCompressionQuality.allCases, id: \.self) { quality in
                                    Text(quality.displayName).tag(quality)
                                }
                            }
                            .pickerStyle(MenuPickerStyle())
                            .frame(width: 120)
                        }
                        
                        // 配置验证警告
                        let validation = videoSettingsManager.validateConfiguration()
                        if !validation.isValid {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(validation.warnings, id: \.self) { warning in
                                    HStack {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundColor(.orange)
                                            .font(.caption)
                                        Text(warning)
                                            .font(.caption)
                                            .foregroundColor(.orange)
                                    }
                                }
                            }
                            .padding(.top, 8)
                        }
                    }
                    .padding(.top, 12)
                }
                .padding(.top, 8)
            }
        }
    }
    
    // MARK: - 视频配置辅助视图
    
    /// 分辨率选项卡片
    private func resolutionOptionCard(_ resolution: VideoResolution) -> some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.2)) {
                videoSettingsManager.selectedResolution = resolution
            }
        }) {
            VStack(spacing: 6) {
                HStack {
                    Text(resolution.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(videoSettingsManager.selectedResolution == resolution ? .white : .primary)
                    Spacer()
                    if videoSettingsManager.selectedResolution == resolution {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.white)
                            .font(.caption)
                    }
                }
                
                HStack {
                    let dimensions = resolution.dimensions
                    Text("\(dimensions.width)×\(dimensions.height)")
                        .font(.system(size: 10))
                        .foregroundColor(videoSettingsManager.selectedResolution == resolution ? .white.opacity(0.8) : .secondary)
                    Spacer()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(videoSettingsManager.selectedResolution == resolution ? Color.blue : Color(NSColor.controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(videoSettingsManager.selectedResolution == resolution ? Color.blue : Color(NSColor.separatorColor), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
    
    /// 帧率选项按钮
    private func frameRateOptionButton(_ frameRate: VideoFrameRate) -> some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.2)) {
                videoSettingsManager.selectedFrameRate = frameRate
            }
        }) {
            Text(frameRate.displayName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(videoSettingsManager.selectedFrameRate == frameRate ? .white : .primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(videoSettingsManager.selectedFrameRate == frameRate ? Color.blue : Color(NSColor.controlBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(videoSettingsManager.selectedFrameRate == frameRate ? Color.blue : Color(NSColor.separatorColor), lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
    }
    
    /// 预设配置按钮
    private func presetButton(_ preset: VideoTransferPreset) -> some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.3)) {
                videoSettingsManager.applyPresetConfiguration(preset)
            }
        }) {
            HStack(spacing: 4) {
                Image(systemName: preset.iconName)
                    .font(.caption)
                Text(preset.rawValue)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(.blue)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.blue.opacity(0.1))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.blue.opacity(0.3), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .help(preset.description)
    }
    
    // MARK: - 远程桌面设置
    private var remoteDesktopSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                settingsSection("显示设置") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("视频质量:")
                            Picker("", selection: .constant("medium")) {
                                Text("低").tag("low")
                                Text("中").tag("medium")
                                Text("高").tag("high")
                                Text("超高").tag("ultra")
                            }
                            .pickerStyle(MenuPickerStyle())
                            .frame(width: 100)
                        }
                        
                        HStack {
                            Text("压缩级别:")
                            Slider(value: .constant(5.0), in: 1...9, step: 1)
                            Text("5")
                                .foregroundColor(.secondary)
                                .frame(width: 20)
                        }
                        
                        HStack {
                            Text("帧率限制:")
                            Picker("", selection: .constant(30)) {
                                Text("15 FPS").tag(15)
                                Text("30 FPS").tag(30)
                                Text("60 FPS").tag(60)
                                Text("无限制").tag(0)
                            }
                            .pickerStyle(MenuPickerStyle())
                            .frame(width: 100)
                        }
                        
                        Toggle("自适应质量", isOn: .constant(true))
                        Toggle("全屏模式", isOn: .constant(false))
                    }
                }
                
                settingsSection("交互设置") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("启用剪贴板同步", isOn: .constant(true))
                        Toggle("启用音频重定向", isOn: .constant(true))
                        Toggle("启用文件拖放", isOn: .constant(true))
                        Toggle("启用多点触控", isOn: .constant(false))
                        
                        HStack {
                            Text("鼠标灵敏度:")
                            Slider(value: .constant(1.0), in: 0.1...3.0, step: 0.1)
                            Text("1.0")
                                .foregroundColor(.secondary)
                                .frame(width: 30)
                        }
                        
                        HStack {
                            Text("键盘延迟 (ms):")
                            TextField("毫秒", value: .constant(50), format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                        }
                    }
                }
                
                settingsSection("网络优化") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("启用带宽自适应", isOn: .constant(true))
                        Toggle("优先低延迟", isOn: .constant(false))
                        Toggle("启用数据压缩", isOn: $settingsManager.enableConnectionEncryption)
                        
                        HStack {
                            Text("最大带宽 (Mbps):")
                            TextField("带宽", value: .constant(100), format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                        }
                        
                        HStack {
                            Text("缓冲区大小:")
                            Picker("", selection: .constant(65536)) {
                                Text("32KB").tag(32768)
                                Text("64KB").tag(65536)
                                Text("128KB").tag(131072)
                                Text("256KB").tag(262144)
                            }
                            .pickerStyle(MenuPickerStyle())
                            .frame(width: 100)
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - 系统监控设置
    private var systemMonitorSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                settingsSection("监控配置") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("刷新间隔:")
                            Picker("", selection: .constant(5)) {
                                Text("1秒").tag(1)
                                Text("5秒").tag(5)
                                Text("10秒").tag(10)
                                Text("30秒").tag(30)
                            }
                            .pickerStyle(MenuPickerStyle())
                            .frame(width: 80)
                        }
                        
                        Toggle("启用实时监控", isOn: .constant(true))
                        Toggle("启用历史记录", isOn: .constant(true))
                        Toggle("启用性能警报", isOn: .constant(false))
                        
                        HStack {
                            Text("数据保留天数:")
                            TextField("天数", value: .constant(30), format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                        }
                    }
                }
                
                settingsSection("显示选项") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("显示CPU使用率", isOn: .constant(true))
                        Toggle("显示内存使用率", isOn: .constant(true))
                        Toggle("显示磁盘使用率", isOn: .constant(true))
                        Toggle("显示网络活动", isOn: .constant(true))
                        Toggle("显示温度信息", isOn: .constant(false))
                        Toggle("显示风扇转速", isOn: .constant(false))
                        
                        HStack {
                            Text("图表类型:")
                            Picker("", selection: .constant("line")) {
                                Text("线图").tag("line")
                                Text("柱状图").tag("bar")
                                Text("面积图").tag("area")
                            }
                            .pickerStyle(MenuPickerStyle())
                            .frame(width: 100)
                        }
                    }
                }
                
                settingsSection("警报设置") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("CPU警报阈值:")
                            Slider(value: .constant(80.0), in: 50...95, step: 5)
                            Text("80%")
                                .foregroundColor(.secondary)
                                .frame(width: 40)
                        }
                        
                        HStack {
                            Text("内存警报阈值:")
                            Slider(value: .constant(85.0), in: 50...95, step: 5)
                            Text("85%")
                                .foregroundColor(.secondary)
                                .frame(width: 40)
                        }
                        
                        HStack {
                            Text("磁盘警报阈值:")
                            Slider(value: .constant(90.0), in: 70...95, step: 5)
                            Text("90%")
                                .foregroundColor(.secondary)
                                .frame(width: 40)
                        }
                        
                        Toggle("启用声音警报", isOn: .constant(false))
                        Toggle("启用通知中心", isOn: .constant(true))
                    }
                }
                
                settingsSection("高级选项") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("启用详细日志", isOn: .constant(false))
                        Toggle("导出监控数据", isOn: .constant(false))
                        Toggle("启用远程监控", isOn: .constant(false))
                        
                        HStack {
                            Text("采样精度:")
                            Picker("", selection: .constant("normal")) {
                                Text("低").tag("low")
                                Text("正常").tag("normal")
                                Text("高").tag("high")
                            }
                            .pickerStyle(MenuPickerStyle())
                            .frame(width: 80)
                        }
                        
                        Button("重置监控数据") {
                            // 重置监控数据的逻辑
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    // MARK: - 私有方法
    
    /// 重置所有设置 - 使用异步方法遵循Swift并发最佳实践
    private func resetAllSettings() {
    // 使用Task来处理异步重置操作，确保在主线程上执行UI更新
    Task { @MainActor in
        await settingsManager.resetToDefaults()
        print("✅ 所有设置已重置为默认值")
    }
    }
    
    /// 更新扫描间隔
    private func updateScanInterval(_ interval: Int) {
        // 通知设备管理设置管理器更新扫描间隔
        let deviceSettingsManager = DeviceManagementSettingsManager.shared
        deviceSettingsManager.wifiScanInterval = Double(interval)
        deviceSettingsManager.bluetoothScanInterval = Double(interval)
        deviceSettingsManager.airplayScanInterval = Double(interval)
        
        // 如果正在扫描，重新启动扫描以应用新间隔
        if wifiManager.isScanning {
            Task {
                wifiManager.stopScanning()
                await wifiManager.startScanning()
            }
        }
        
        if bluetoothManager.isScanning {
            bluetoothManager.stopScanning()
            bluetoothManager.startScanning()
        }
        
        if airplayManager.isScanning {
            airplayManager.stopScanning()
            airplayManager.startScanning()
        }
    }
    
    /// 请求通知权限
    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            DispatchQueue.main.async {
                if granted {
                    print("✅ 通知权限已授予")
                } else {
                    print("❌ 通知权限被拒绝")
                }
            }
        }
    }
    
    /// 应用主题模式
    private func applyThemeMode(_ mode: String) {
        UserDefaults.standard.set(mode, forKey: "themeMode")
        
        // 发送通知更新界面主题
        NotificationCenter.default.post(
            name: NSNotification.Name("ThemeModeChanged"),
            object: nil,
            userInfo: ["mode": mode]
        )
        
        print("✅ 主题模式已切换为: \(mode)")
    }
    
    /// 清除应用缓存
    private func clearApplicationCache() {
        // 清除各种缓存
        let cacheURLs = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        for cacheURL in cacheURLs {
            do {
                let contents = try FileManager.default.contentsOfDirectory(at: cacheURL, includingPropertiesForKeys: nil)
                for fileURL in contents {
                    try FileManager.default.removeItem(at: fileURL)
                }
                print("✅ 缓存已清除")
            } catch {
                print("❌ 清除缓存失败: \(error)")
            }
        }
        
        // 清除设备管理器缓存
        DeviceManagementSettingsManager.shared.clearDeviceCache()
        
        // 刷新设备列表
        Task {
            await wifiManager.refreshNetworks()
        }
        bluetoothManager.refreshDevices()
        airplayManager.refreshDevices()
    }
    
    /// 获取格式化的缓存大小
    private func getFormattedCacheSize() -> String {
        let cacheURLs = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        var totalSize: Int64 = 0
        
        for cacheURL in cacheURLs {
            do {
                let contents = try FileManager.default.contentsOfDirectory(at: cacheURL, includingPropertiesForKeys: [.fileSizeKey])
                for fileURL in contents {
                    let resourceValues = try fileURL.resourceValues(forKeys: [.fileSizeKey])
                    totalSize += Int64(resourceValues.fileSize ?? 0)
                }
            } catch {
                // 忽略错误，继续计算其他文件
            }
        }
        
        // 格式化大小显示
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: totalSize)
    }
    
    /// 切换布局模式
    private func switchLayoutMode(isCompact: Bool) {
        // 发送通知给主界面切换布局
        NotificationCenter.default.post(
            name: NSNotification.Name("LayoutModeChanged"),
            object: nil,
            userInfo: ["isCompact": isCompact]
        )
    }
    
    /// 应用主题色彩
    private func applyThemeColor(_ color: Color) {
        // 更新全局主题色彩
        NotificationCenter.default.post(
            name: NSNotification.Name("ThemeColorChanged"),
            object: nil,
            userInfo: ["color": color]
        )
    }
}