import SwiftUI
import SkyBridgeCore

/// macOS 偏好设置窗口 - 遵循 Apple 设计规范
struct PreferencesView: View {
    
    // MARK: - 状态管理
    @StateObject private var settingsManager = SettingsManager.shared
    @StateObject private var permissionManager = DevicePermissionManager()
    @StateObject private var wifiManager = WiFiManager()
    @StateObject private var bluetoothManager = BluetoothManager()
    @StateObject private var airplayManager = AirPlayManager()
    
    @State private var selectedTab: PreferencesTab = .general
    
    // MARK: - 偏好设置标签页枚举
    enum PreferencesTab: String, CaseIterable {
        case general = "通用"
        case network = "网络"
        case devices = "设备"
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
            case .permissions:
                return "lock.shield"
            case .advanced:
                return "slider.horizontal.3"
            }
        }
    }
    
    var body: some View {
        TabView(selection: $selectedTab) {
            // 通用设置
            GeneralPreferencesView()
                .tabItem {
                    Label(PreferencesTab.general.rawValue, systemImage: PreferencesTab.general.iconName)
                }
                .tag(PreferencesTab.general)
            
            // 网络设置
            NetworkPreferencesView()
                .tabItem {
                    Label(PreferencesTab.network.rawValue, systemImage: PreferencesTab.network.iconName)
                }
                .tag(PreferencesTab.network)
            
            // 设备设置
            DevicePreferencesView()
                .tabItem {
                    Label(PreferencesTab.devices.rawValue, systemImage: PreferencesTab.devices.iconName)
                }
                .tag(PreferencesTab.devices)
            
            // 权限设置
            PermissionPreferencesView()
                .tabItem {
                    Label(PreferencesTab.permissions.rawValue, systemImage: PreferencesTab.permissions.iconName)
                }
                .tag(PreferencesTab.permissions)
            
            // 高级设置
            AdvancedPreferencesView()
                .tabItem {
                    Label(PreferencesTab.advanced.rawValue, systemImage: PreferencesTab.advanced.iconName)
                }
                .tag(PreferencesTab.advanced)
        }
        .frame(width: 600, height: 500)
        .environmentObject(settingsManager)
        .environmentObject(permissionManager)
        .environmentObject(wifiManager)
        .environmentObject(bluetoothManager)
        .environmentObject(airplayManager)
    }
}

// MARK: - 通用偏好设置视图
struct GeneralPreferencesView: View {
    @EnvironmentObject private var settingsManager: SettingsManager
    
    var body: some View {
        Form {
            Section("应用行为") {
                Toggle("启动时自动扫描设备", isOn: $settingsManager.autoScanOnStartup)
                    .help("应用启动时自动开始扫描可用设备")
                
                Toggle("显示系统通知", isOn: $settingsManager.showSystemNotifications)
                    .help("设备连接状态变化时显示系统通知")
                
                Toggle("启用后台扫描", isOn: $settingsManager.enableBackgroundScanning)
                    .help("在后台继续扫描设备")
            }
            
            Section("界面设置") {
                Toggle("使用深色模式", isOn: $settingsManager.useDarkMode)
                    .help("启用深色界面主题")
                
                Toggle("紧凑模式", isOn: $settingsManager.compactMode)
                    .help("使用更紧凑的界面布局")
                
                Toggle("显示设备详情", isOn: $settingsManager.showDeviceDetails)
                    .help("在设备列表中显示详细信息")
                
                Toggle("显示连接统计", isOn: $settingsManager.showConnectionStats)
                    .help("显示连接速度和质量统计")
            }
            
            Section("数据管理") {
                HStack {
                    Button("导出设置") {
                        Task {
                            do {
                                // exportSettings() 返回 URL，是异步方法
                                let exportedURL = try await settingsManager.exportSettings()
                                
                                // 显示保存面板让用户选择保存位置
                                let panel = NSSavePanel()
                                panel.allowedContentTypes = [.json]
                                panel.nameFieldStringValue = "SkyBridge设置.json"
                                
                                if panel.runModal() == .OK, let url = panel.url {
                                    // 将导出的临时文件复制到用户选择的位置
                                    try FileManager.default.copyItem(at: exportedURL, to: url)
                                }
                            } catch {
                                print("导出设置失败: \(error)")
                            }
                        }
                    }
                    .help("将当前设置导出到文件")
                    
                    Button("导入设置") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.json]
                        panel.allowsMultipleSelection = false
                        
                        if panel.runModal() == .OK, let url = panel.urls.first {
                            Task {
                                do {
                                    try await settingsManager.importSettings(from: url)
                                } catch {
                                    print("导入设置失败: \(error)")
                                }
                            }
                        }
                    }
                    .help("从文件导入设置")
                    
                    Spacer()
                    
                    Button("重置为默认") {
                        Task {
                            await settingsManager.resetToDefaults()
                        }
                    }
                    .foregroundColor(.red)
                    .help("将所有设置重置为默认值")
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - 网络偏好设置视图
struct NetworkPreferencesView: View {
    @EnvironmentObject private var settingsManager: SettingsManager
    
    var body: some View {
        Form {
            Section("WiFi 设置") {
                Toggle("自动连接已知网络", isOn: $settingsManager.autoConnectKnownNetworks)
                    .help("自动连接之前连接过的WiFi网络")
                
                Toggle("显示隐藏网络", isOn: $settingsManager.showHiddenNetworks)
                    .help("在WiFi列表中显示隐藏的网络")
                
                Toggle("优先使用5GHz频段", isOn: $settingsManager.prefer5GHz)
                    .help("在可用时优先连接5GHz WiFi网络")
                
                Stepper("WiFi扫描超时: \(settingsManager.wifiScanTimeout)秒", 
                       value: $settingsManager.wifiScanTimeout, 
                       in: 5...60, 
                       step: 5)
                    .help("WiFi网络扫描的超时时间")
            }
            
            Section("网络发现") {
                Toggle("启用Bonjour发现", isOn: $settingsManager.enableBonjourDiscovery)
                    .help("使用Bonjour协议发现网络设备")
                
                Toggle("启用mDNS解析", isOn: $settingsManager.enableMDNSResolution)
                    .help("启用多播DNS名称解析")
                
                Toggle("扫描自定义端口", isOn: $settingsManager.scanCustomPorts)
                    .help("扫描自定义服务端口")
                
                Stepper("发现超时: \(settingsManager.discoveryTimeout)秒", 
                       value: $settingsManager.discoveryTimeout, 
                       in: 10...120, 
                       step: 10)
                    .help("网络发现的超时时间")
            }
            
            Section("连接设置") {
                Stepper("连接超时: \(settingsManager.connectionTimeout)秒", 
                       value: $settingsManager.connectionTimeout, 
                       in: 5...60, 
                       step: 5)
                    .help("设备连接的超时时间")
                
                Stepper("重试次数: \(settingsManager.retryCount)", 
                       value: $settingsManager.retryCount, 
                       in: 1...10)
                    .help("连接失败时的最大重试次数")
                
                Toggle("启用连接加密", isOn: $settingsManager.enableConnectionEncryption)
                    .help("对连接数据进行加密")
                
                Toggle("验证证书", isOn: $settingsManager.verifyCertificates)
                    .help("验证服务器SSL证书")
            }
            
            Section("自定义服务") {
                VStack(alignment: .leading) {
                    Text("自定义服务类型:")
                        .font(.headline)
                    
                    ForEach(Array(settingsManager.customServiceTypes.enumerated()), id: \.offset) { index, serviceType in
                        HStack {
                            TextField("服务类型", text: Binding(
                                get: { serviceType },
                                set: { newValue in
                                    var types = settingsManager.customServiceTypes
                                    if index < types.count {
                                        types[index] = newValue
                                        settingsManager.customServiceTypes = types
                                    }
                                }
                            ))
                            
                            Button("删除") {
                                if index < settingsManager.customServiceTypes.count {
                                    settingsManager.customServiceTypes.remove(at: index)
                                }
                            }
                            .foregroundColor(.red)
                        }
                    }
                    
                    Button("添加服务类型") {
                        settingsManager.customServiceTypes.append("")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - 设备偏好设置视图
struct DevicePreferencesView: View {
    @EnvironmentObject private var settingsManager: SettingsManager
    
    var body: some View {
        Form {
            Section("设备显示") {
                Toggle("显示设备RSSI", isOn: $settingsManager.showDeviceRSSI)
                    .help("显示设备信号强度指示器")
                
                Toggle("仅显示可连接设备", isOn: $settingsManager.showConnectableDevicesOnly)
                    .help("隐藏不可连接的设备")
                
                Toggle("隐藏离线设备", isOn: $settingsManager.hideOfflineDevices)
                    .help("不显示离线或不可用的设备")
                
                Toggle("显示设备图标", isOn: $settingsManager.showDeviceIcons)
                    .help("在设备列表中显示设备类型图标")
                
                Toggle("按信号强度排序", isOn: $settingsManager.sortBySignalStrength)
                    .help("根据信号强度对设备进行排序")
            }
            
            Section("AirPlay 设置") {
                Toggle("自动发现Apple TV", isOn: $settingsManager.autoDiscoverAppleTV)
                    .help("自动发现网络中的Apple TV设备")
                
                Toggle("显示HomePod设备", isOn: $settingsManager.showHomePodDevices)
                    .help("在设备列表中显示HomePod")
                
                Toggle("显示第三方AirPlay设备", isOn: $settingsManager.showThirdPartyAirPlayDevices)
                    .help("显示非Apple的AirPlay兼容设备")
            }
            
            Section("设备管理") {
                Toggle("自动连接配对设备", isOn: $settingsManager.autoConnectPairedDevices)
                    .help("自动连接之前配对过的设备")
                
                Stepper("最小信号强度: \(Int(settingsManager.minimumSignalStrength)) dBm", 
                       value: $settingsManager.minimumSignalStrength, 
                       in: -100...0, 
                       step: 5)
                    .help("过滤掉信号强度低于此值的设备")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - 权限偏好设置视图
struct PermissionPreferencesView: View {
    @EnvironmentObject private var permissionManager: DevicePermissionManager
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("权限管理")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("SkyBridge Compass 需要以下权限来正常工作:")
                .foregroundColor(.secondary)
            
            LazyVStack(spacing: 12) {
                ForEach(permissionManager.permissions) { permission in
                    PermissionRowView(permission: permission)
                }
            }
            
            Divider()
            
            HStack {
                Button("刷新权限状态") {
                    permissionManager.checkAllPermissions()
                }
                
                Spacer()
                
                if !permissionManager.allRequiredPermissionsGranted {
                    Button("请求所需权限") {
                        Task {
                            await permissionManager.requestAllRequiredPermissions()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            
            Spacer()
        }
        .padding()
        .onAppear {
            permissionManager.checkAllPermissions()
        }
    }
}

// MARK: - 权限行视图
struct PermissionRowView: View {
    let permission: PermissionInfo
    
    var body: some View {
        HStack {
            Image(systemName: permission.type.iconName)
                .foregroundColor(permission.status == .authorized ? .green : .red)
                .frame(width: 20)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.type.description)
                    .font(.headline)
                
                Text(permission.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            VStack(alignment: .trailing) {
                Text(permission.status.rawValue)
                    .font(.caption)
                    .foregroundColor(permission.status == .authorized ? .green : .red)
                
                if permission.isRequired && !permission.status.isAuthorized {
                    Text("必需")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.red.opacity(0.2))
                        .foregroundColor(.red)
                        .cornerRadius(4)
                }
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
}

// MARK: - 高级偏好设置视图
struct AdvancedPreferencesView: View {
    @EnvironmentObject private var settingsManager: SettingsManager
    
    var body: some View {
        Form {
            Section("调试选项") {
                Toggle("启用详细日志", isOn: $settingsManager.enableVerboseLogging)
                    .help("启用详细的调试日志记录")
                
                Toggle("显示调试信息", isOn: $settingsManager.showDebugInfo)
                    .help("在界面中显示调试信息")
                
                Toggle("保存网络日志", isOn: $settingsManager.saveNetworkLogs)
                    .help("将网络活动保存到日志文件")
                
                Picker("日志级别", selection: $settingsManager.logLevel) {
                    Text("错误").tag("Error")
                    Text("警告").tag("Warning")
                    Text("信息").tag("Info")
                    Text("调试").tag("Debug")
                }
                .help("设置日志记录的详细程度")
            }
            
            Section("性能优化") {
                Toggle("启用硬件加速", isOn: $settingsManager.enableHardwareAcceleration)
                    .help("使用硬件加速提升性能")
                
                Toggle("优化内存使用", isOn: $settingsManager.optimizeMemoryUsage)
                    .help("启用内存使用优化")
                
                Stepper("最大并发连接: \(settingsManager.maxConcurrentConnections)", 
                       value: $settingsManager.maxConcurrentConnections, 
                       in: 1...50)
                    .help("同时允许的最大连接数")
            }
            
            Section("实验性功能") {
                Toggle("启用IPv6支持", isOn: $settingsManager.enableIPv6Support)
                    .help("启用IPv6网络协议支持")
                
                Toggle("使用新发现算法", isOn: $settingsManager.useNewDiscoveryAlgorithm)
                    .help("使用改进的设备发现算法")
                
                Toggle("启用P2P直连", isOn: $settingsManager.enableP2PDirectConnection)
                    .help("启用点对点直接连接功能")
            }
            
            Section("缓存和存储") {
                HStack {
                    Text("当前缓存大小:")
                    Spacer()
                    Text(settingsManager.getCacheSize())
                        .foregroundColor(.secondary)
                }
                
                Button("清除缓存") {
                    settingsManager.clearCache()
                }
                .help("清除所有缓存数据")
            }
            
            Section("网络设置重置") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("重置网络设置将清除所有WiFi、网络发现和连接配置。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Button("重置网络设置") {
                        settingsManager.resetNetworkSettings()
                    }
                    .foregroundColor(.red)
                    .help("重置所有网络相关设置为默认值")
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}