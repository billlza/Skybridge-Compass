import SwiftUI
import Combine
import UserNotifications

/// 设置界面 - 提供完整的应用配置和设备管理设置
/// 适配平铺显示模式，符合macOS设计规范
@available(macOS 14.0, *)
public struct SettingsView: View {
    
 // MARK: - 状态管理
    @StateObject private var settingsManager = SettingsManager.shared
    @StateObject private var localizationManager = LocalizationManager.shared
    @StateObject private var permissionManager = DevicePermissionManager()
    @StateObject private var wifiManager = WiFiManager()
    @StateObject private var bluetoothManager = BluetoothManager()
    @StateObject private var airplayManager = AirPlayManager()
    @StateObject private var videoSettingsManager = VideoTransferSettingsManager.shared
    @StateObject private var remoteDesktopSettingsManager = RemoteDesktopSettingsManager.shared
 // 启用性能模式管理器
    @StateObject private var performanceModeManager = PerformanceModeManager.shared
 // Metal Performance HUD
    @StateObject private var hud: MetalPerformanceHUD = {
        if let device = MTLCreateSystemDefaultDevice(),
           let hudInstance = try? MetalPerformanceHUD(device: device) {
            return hudInstance
        } else {
            return MetalPerformanceHUD.fallback()
        }
    }()
    
    @State private var selectedTab: SettingsTab = .general
    @StateObject private var ftBridge = FileTransferSettingsBridge.shared
    @State private var showingPermissionAlert = false
    @State private var showingResetAlert = false
    @State private var showingExportDialog = false
    @State private var showingImportDialog = false
    @State private var newCustomServiceType = ""
    
 // MARK: - 设置标签页
    enum SettingsTab: String, CaseIterable {
        case general
        case network
        case devices
        case fileTransfer
        case remoteDesktop
        case systemMonitor
        case permissions
        case advanced
        
        @MainActor var localizedName: String {
            switch self {
            case .general:
                return LocalizationManager.shared.localizedString("settings.tab.general")
            case .network:
                return LocalizationManager.shared.localizedString("settings.tab.network")
            case .devices:
                return LocalizationManager.shared.localizedString("settings.tab.devices")
            case .fileTransfer:
                return LocalizationManager.shared.localizedString("settings.tab.fileTransfer")
            case .remoteDesktop:
                return LocalizationManager.shared.localizedString("settings.tab.remoteDesktop")
            case .systemMonitor:
                return LocalizationManager.shared.localizedString("settings.tab.systemMonitor")
            case .permissions:
                return LocalizationManager.shared.localizedString("settings.tab.permissions")
            case .advanced:
                return LocalizationManager.shared.localizedString("settings.tab.advanced")
            }
        }
        
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
                
 // 右侧详细设置内容（大块液态玻璃面板）
                VStack {
                    settingsDetail
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .padding(16)
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(.primary.opacity(0.1), lineWidth: 1)
                )
                .padding(.horizontal, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert(localizationManager.localizedString("alert.permissions.title"), isPresented: $showingPermissionAlert) {
            Button(localizationManager.localizedString("action.openSystemPreferences")) {
                permissionManager.openSystemPreferences()
            }
            Button(localizationManager.localizedString("action.cancel"), role: .cancel) {}
        } message: {
            Text(localizationManager.localizedString("alert.permissions.message"))
        }
        .alert(localizationManager.localizedString("alert.reset.title"), isPresented: $showingResetAlert) {
            Button(localizationManager.localizedString("action.reset"), role: .destructive) {
                resetAllSettings()
            }
            Button(localizationManager.localizedString("action.cancel"), role: .cancel) {}
        } message: {
            Text(localizationManager.localizedString("alert.reset.message"))
        }
        .fileExporter(
            isPresented: $showingExportDialog,
            document: SettingsDocument(data: Data()), // 临时空数据，实际导出在回调中处理
            contentType: .json,
            defaultFilename: localizationManager.localizedString("settings.general.export.defaultFilename")
        ) { result in
            switch result {
            case .success(let url):
 // 使用Task来处理异步导出操作，遵循Swift并发最佳实践
                Task { @MainActor in
                    do {
                        let exportedURL = try await settingsManager.exportSettings()
 // 将导出的文件复制到用户选择的位置
                        try FileManager.default.copyItem(at: exportedURL, to: url)
                    } catch {
 // 导出失败处理
                    }
                }
            case .failure(_):
 // 导出失败处理
                SkyBridgeLogger.ui.error("导出设置失败")
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
                        } catch {
 // 设置导入失败处理
                        }
                    }
                }
            case .failure(_):
 // 导入失败处理
                SkyBridgeLogger.ui.error("导入设置失败")
            }
        }
    }
    
 // MARK: - 顶部标题栏
    private var settingsHeader: some View {
        HStack {
            Image(systemName: "gearshape")
                .font(.title2)
                .foregroundColor(.blue)
            
            Text(localizationManager.localizedString("settings.header.title"))
                .font(.title2.bold())
                .foregroundColor(.primary)
            
            Spacer()
            
 // 快速操作按钮
            HStack(spacing: 8) {
                Button(action: { showingExportDialog = true }) {
                    Image(systemName: "square.and.arrow.up")
                }
                .help(localizationManager.localizedString("settings.general.exportSettings"))
                
                Button(action: { showingImportDialog = true }) {
                    Image(systemName: "square.and.arrow.down")
                }
                .help(localizationManager.localizedString("settings.general.importSettings"))
                
                Button(action: { showingResetAlert = true }) {
                    Image(systemName: "arrow.clockwise")
                }
                .help(localizationManager.localizedString("settings.general.resetSettings"))
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

 // MARK: - 侧边栏
    private var settingsSidebar: some View {
        VStack(spacing: 0) {
 // 顶部标题
            HStack {
                Text(localizationManager.localizedString("settings.header.title"))
                    .font(.title2.bold())
                    .foregroundColor(.primary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
            
            Divider()
            
 // 设置选项列表
            List(SettingsTab.allCases, id: \.self, selection: $selectedTab) { tab in
                Label(tab.localizedName, systemImage: tab.iconName)
                    .tag(tab)
                    .font(.system(size: 13, weight: .medium))
                    .padding(.vertical, 2)
            }
            .listStyle(SidebarListStyle())
            .scrollContentBackground(.hidden)
            
            Spacer()
        }
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
    }
    
 // MARK: - 通用设置
    private var generalSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                settingsSection(localizationManager.localizedString("settings.general.language.sectionTitle")) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(localizationManager.localizedString("settings.general.language.label"))
                            Spacer()
                            Picker("", selection: Binding(
                                get: { localizationManager.currentLanguage },
                                set: { newValue in
                                    localizationManager.setLanguage(newValue)
                                }
                            )) {
                                ForEach(AppLanguage.allCases) { language in
                                    if language == .system {
                                        Text(localizationManager.localizedString("settings.language.system")).tag(language)
                                    } else {
                                        Text(language.displayName).tag(language)
                                    }
                                }
                            }
                            .pickerStyle(MenuPickerStyle())
                            .frame(width: 120)
                        }
                        
                        Text(localizationManager.localizedString("settings.general.language.description"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                settingsSection(localizationManager.localizedString("settings.general.preferences")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(localizationManager.localizedString("settings.general.autoScan"), isOn: $settingsManager.autoScanOnStartup)
                            .onChange(of: settingsManager.autoScanOnStartup) { _, newValue in
 // 保存到UserDefaults
                                UserDefaults.standard.set(newValue, forKey: "AutoScanOnStartup")
                            }
                        
                        Toggle(localizationManager.localizedString("settings.general.systemNotifications"), isOn: $settingsManager.showSystemNotifications)
                            .onChange(of: settingsManager.showSystemNotifications) { _, newValue in
 // 请求通知权限
                                if newValue {
                                    requestNotificationPermission()
                                }
                                UserDefaults.standard.set(newValue, forKey: "ShowSystemNotifications")
                            }
                        
                        Toggle(localizationManager.localizedString("settings.general.darkMode"), isOn: $settingsManager.useDarkMode)
                            .onChange(of: settingsManager.useDarkMode) { _, newValue in
 // 应用主题模式
                                applyThemeMode(newValue ? "dark" : "light")
                                UserDefaults.standard.set(newValue, forKey: "UseDarkMode")
                            }
                        
                        HStack {
                            Text(localizationManager.localizedString("settings.general.scanInterval"))
                            Picker("", selection: $settingsManager.scanInterval) {
                                Text(localizationManager.localizedString("unit.seconds.15")).tag(15)
                                Text(localizationManager.localizedString("unit.seconds.30")).tag(30)
                                Text(localizationManager.localizedString("unit.seconds.60")).tag(60)
                                Text(localizationManager.localizedString("unit.seconds.120")).tag(120)
                            }
                            .pickerStyle(MenuPickerStyle())
                            .frame(width: 100)
                            .onChange(of: settingsManager.scanInterval) { _, newValue in
 // 更新扫描定时器
                                updateScanInterval(newValue)
                                UserDefaults.standard.set(newValue, forKey: "ScanInterval")
                            }
                        }
                    }
                }
                
                settingsSection(localizationManager.localizedString("settings.general.interface")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(localizationManager.localizedString("settings.general.showDeviceDetails"), isOn: $settingsManager.showDeviceDetails)
                            .onChange(of: settingsManager.showDeviceDetails) { _, _ in
                                UserDefaults.standard.set(settingsManager.showDeviceDetails, forKey: "ShowDeviceDetails")
 // 通知其他组件更新显示模式
                                NotificationCenter.default.post(name: NSNotification.Name("DeviceDisplayModeChanged"), object: nil)
                            }
                        
                        Toggle(localizationManager.localizedString("settings.general.showConnectionStats"), isOn: $settingsManager.showConnectionStats)
                            .onChange(of: settingsManager.showConnectionStats) { _, _ in
                                UserDefaults.standard.set(settingsManager.showConnectionStats, forKey: "ShowConnectionStats")
                                NotificationCenter.default.post(name: NSNotification.Name("ConnectionStatsDisplayChanged"), object: nil)
                            }
                        
                        Toggle(localizationManager.localizedString("settings.general.compactMode"), isOn: $settingsManager.compactMode)
                            .onChange(of: settingsManager.compactMode) { _, _ in
                                UserDefaults.standard.set(settingsManager.compactMode, forKey: "CompactMode")
 // 实际切换布局模式
                                switchLayoutMode(isCompact: settingsManager.compactMode)
                            }
                        
                        HStack {
                            Text(localizationManager.localizedString("settings.general.themeColor"))
                            ColorPicker("", selection: $settingsManager.themeColor)
                                .frame(width: 50)
                                .onChange(of: settingsManager.themeColor) { _, newColor in
 // 实际应用主题色彩
                                    applyThemeColor(newColor)
 // 保存颜色到UserDefaults
                                    if let colorData = try? NSKeyedArchiver.archivedData(withRootObject: NSColor(newColor), requiringSecureCoding: false) {
                                        UserDefaults.standard.set(colorData, forKey: "ThemeColor")
                                    }
                                }
                        }
                    }
                }
                
                settingsSection(localizationManager.localizedString("settings.general.dataManagement")) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Button(localizationManager.localizedString("settings.general.clearCache")) {
 // 实际清除缓存操作
                                clearApplicationCache()
                            }
                            .buttonStyle(.bordered)
                            
                            Spacer()
                            
                            Text(String(format: localizationManager.localizedString("settings.general.cacheSize"), getFormattedCacheSize()))
                                .foregroundColor(.secondary)
                        }
                        
                        HStack {
                            Button(localizationManager.localizedString("settings.general.exportSettings")) {
                                showingExportDialog = true
                            }
                            .buttonStyle(.bordered)
                            
                            Button(localizationManager.localizedString("settings.general.importSettings")) {
                                showingImportDialog = true
                            }
                            .buttonStyle(.bordered)
                            
                            Spacer()
                        }
                        
                        HStack {
                            Button(localizationManager.localizedString("settings.general.resetSettings")) {
                                showingResetAlert = true
                            }
                            .buttonStyle(.bordered)
                            .foregroundColor(.red)
                            
                            Spacer()
                        }

                        HStack {
                            Button(localizationManager.localizedString("settings.general.deduplicateKeychain")) {
 // deduplicate 是 nonisolated 方法，可以直接同步调用
                                KeychainManager.shared.deduplicate(servicePrefix: "SkyBridge.")
                            }
                            .buttonStyle(.borderedProminent)
                            
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
                settingsSection(localizationManager.localizedString("settings.network.wifi.title")) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(localizationManager.localizedString("settings.network.wifi.currentNetwork"))
                            Text(wifiManager.currentNetwork?.ssid ?? localizationManager.localizedString("settings.network.wifi.notConnected"))
                                .fontWeight(.medium)
                            Spacer()
                            Button(localizationManager.localizedString("action.refresh")) {
                                Task {
                                    await wifiManager.refreshNetworks()
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                        
                        Toggle(localizationManager.localizedString("settings.network.wifi.autoConnectKnown"), isOn: $settingsManager.autoConnectKnownNetworks)
                        Toggle(localizationManager.localizedString("settings.network.wifi.showHidden"), isOn: $settingsManager.showHiddenNetworks)
                        Toggle(localizationManager.localizedString("settings.network.wifi.prefer5GHz"), isOn: $settingsManager.prefer5GHz)
                        
                        HStack {
                            Text(localizationManager.localizedString("settings.network.wifi.scanTimeout"))
                            Picker("", selection: $settingsManager.wifiScanTimeout) {
                                Text(localizationManager.localizedString("unit.seconds.5")).tag(5)
                                Text(localizationManager.localizedString("unit.seconds.10")).tag(10)
                                Text(localizationManager.localizedString("unit.seconds.15")).tag(15)
                                Text(localizationManager.localizedString("unit.seconds.30")).tag(30)
                            }
                            .pickerStyle(MenuPickerStyle())
                            .frame(width: 100)
                        }
                    }
                }
                
                settingsSection(localizationManager.localizedString("settings.network.discovery.title")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(localizationManager.localizedString("settings.network.discovery.enableBonjour"), isOn: $settingsManager.enableBonjourDiscovery)
                        Toggle(localizationManager.localizedString("settings.network.discovery.enableMDNS"), isOn: $settingsManager.enableMDNSResolution)
                        Toggle(localizationManager.localizedString("settings.network.discovery.scanCustomPorts"), isOn: $settingsManager.scanCustomPorts)
                        
                        HStack {
                            Text(localizationManager.localizedString("settings.network.discovery.timeout"))
                            TextField(localizationManager.localizedString("unit.second.short"), value: $settingsManager.discoveryTimeout, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                        }
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text(localizationManager.localizedString("settings.network.discovery.customServiceType"))
                                .fontWeight(.medium)
                            
 // 显示已添加的自定义服务类型
                            if !settingsManager.customServiceTypes.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(Array(settingsManager.customServiceTypes.enumerated()), id: \.offset) { index, serviceType in
                                        HStack {
                                            Text(serviceType)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                            Spacer()
                                            Button(action: {
                                                settingsManager.removeCustomServiceType(serviceType)
                                            }) {
                                                Image(systemName: "minus.circle.fill")
                                                    .foregroundColor(.red)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 2)
                                        .background(Color(NSColor.controlBackgroundColor))
                                        .cornerRadius(4)
                                    }
                                }
                                .padding(.bottom, 8)
                            }
                            
                            HStack {
                                TextField(localizationManager.localizedString("settings.network.discovery.customServiceTypeExample"), text: $newCustomServiceType)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit {
                                        addCustomServiceType()
                                    }
                                
                                Button(localizationManager.localizedString("action.add")) {
                                    addCustomServiceType()
                                }
                                .buttonStyle(.bordered)
                                .disabled(newCustomServiceType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                    }
                }
                
                settingsSection(localizationManager.localizedString("settings.network.connection.title")) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(localizationManager.localizedString("settings.network.connection.timeout"))
                            TextField(localizationManager.localizedString("unit.second.short"), value: $settingsManager.connectionTimeout, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                        }
                        
                        HStack {
                            Text(localizationManager.localizedString("settings.network.connection.retryCount"))
                            TextField(localizationManager.localizedString("unit.times.short"), value: $settingsManager.retryCount, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                        }
                        
                        Toggle(localizationManager.localizedString("settings.network.connection.enableEncryption"), isOn: $settingsManager.enableConnectionEncryption)
                        Toggle(localizationManager.localizedString("settings.network.connection.verifyCertificates"), isOn: $settingsManager.verifyCertificates)
                    }
                }
            }
        }
    }
    
 // MARK: - 设备设置
    private var deviceSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                settingsSection(localizationManager.localizedString("settings.devices.bluetooth.title")) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(localizationManager.localizedString("settings.devices.bluetooth.status"))
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
                            Button(bluetoothManager.isScanning ? localizationManager.localizedString("discovery.stopScan") : localizationManager.localizedString("discovery.startScan")) {
                                if bluetoothManager.isScanning {
                                    bluetoothManager.stopScanning()
                                } else {
                                    bluetoothManager.startScanning()
                                }
                            }
                            .buttonStyle(.bordered)
                            
                            Spacer()
                            
                            Text(String(format: localizationManager.localizedString("settings.devices.bluetooth.discoveredCount"), bluetoothManager.discoveredDevices.count))
                                .foregroundColor(.secondary)
                        }
                        
                        Toggle(localizationManager.localizedString("settings.devices.bluetooth.autoConnectPaired"), isOn: $settingsManager.autoConnectPairedDevices)
                        Toggle(localizationManager.localizedString("settings.devices.bluetooth.showRSSI"), isOn: $settingsManager.showDeviceRSSI)
                        Toggle(localizationManager.localizedString("settings.devices.bluetooth.showConnectableOnly"), isOn: $settingsManager.showConnectableDevicesOnly)
                    }
                }
                
                settingsSection(localizationManager.localizedString("settings.devices.airplay.title")) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(localizationManager.localizedString("settings.devices.airplay.status"))
                            Text(airplayManager.isScanning ? localizationManager.localizedString("status.scanning") : localizationManager.localizedString("status.idle"))
                                .fontWeight(.medium)
                                .foregroundColor(airplayManager.isScanning ? .blue : .secondary)
                            Spacer()
                            
                            if airplayManager.isScanning {
                                ProgressView()
                                    .scaleEffect(0.8)
                            }
                        }
                        
                        HStack {
                            Button(airplayManager.isScanning ? localizationManager.localizedString("discovery.stopScan") : localizationManager.localizedString("discovery.startScan")) {
                                if airplayManager.isScanning {
                                    airplayManager.stopScanning()
                                } else {
                                    airplayManager.startScanning()
                                }
                            }
                            .buttonStyle(.bordered)
                            
                            Spacer()
                            
                            Text(String(format: localizationManager.localizedString("settings.devices.airplay.discoveredCount"), airplayManager.discoveredDevices.count))
                                .foregroundColor(.secondary)
                        }
                        
                        Toggle(localizationManager.localizedString("settings.devices.airplay.autoDiscoverAppleTV"), isOn: $settingsManager.autoDiscoverAppleTV)
                        Toggle(localizationManager.localizedString("settings.devices.airplay.showHomePodDevices"), isOn: $settingsManager.showHomePodDevices)
                        Toggle(localizationManager.localizedString("settings.devices.airplay.showThirdPartyAirPlayDevices"), isOn: $settingsManager.showThirdPartyAirPlayDevices)
                    }
                }
                
                settingsSection(localizationManager.localizedString("settings.devices.filters.title")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(localizationManager.localizedString("settings.devices.filters.hideOffline"), isOn: $settingsManager.hideOfflineDevices)
                        Toggle(localizationManager.localizedString("settings.devices.filters.sortBySignal"), isOn: $settingsManager.sortBySignalStrength)
                        Toggle(localizationManager.localizedString("settings.devices.filters.showIcons"), isOn: $settingsManager.showDeviceIcons)
                        
                        HStack {
                            Text(localizationManager.localizedString("settings.devices.filters.minSignalStrength"))
                            Slider(value: $settingsManager.minimumSignalStrength, in: -100...(-30))
                            Text("\(Int(settingsManager.minimumSignalStrength)) \(localizationManager.localizedString("unit.dbm"))")
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
                settingsSection(localizationManager.localizedString("settings.permissions.status.title")) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(localizationManager.localizedString("settings.permissions.summary"))
                            Text(permissionManager.permissionSummary)
                                .fontWeight(.medium)
                            Spacer()
                            
                            Button(localizationManager.localizedString("action.refreshStatus")) {
                                permissionManager.checkAllPermissions()
                            }
                            .buttonStyle(.bordered)
                        }
                        
                        if !permissionManager.allRequiredPermissionsGranted {
                            HStack {
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundColor(.orange)
                                Text(localizationManager.localizedString("settings.permissions.warning.notAuthorized"))
                                    .foregroundColor(.orange)
                                Spacer()
                                
                                Button(localizationManager.localizedString("action.requestPermissions")) {
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
                
                settingsSection(localizationManager.localizedString("settings.permissions.details.title")) {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(permissionManager.permissions) { permission in
                            permissionRow(permission)
                        }
                    }
                }
                
                settingsSection(localizationManager.localizedString("settings.permissions.help.title")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(localizationManager.localizedString("settings.permissions.help.description.title"))
                            .fontWeight(.medium)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text(localizationManager.localizedString("settings.permissions.help.wifiAccess"))
                            Text(localizationManager.localizedString("settings.permissions.help.bluetoothAccess"))
                            Text(localizationManager.localizedString("settings.permissions.help.locationAccess"))
                            Text(localizationManager.localizedString("settings.permissions.help.systemConfigAccess"))
                        }
                        .foregroundColor(.secondary)
                        
                        HStack {
                            Button(localizationManager.localizedString("action.openSystemPreferences")) {
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
                settingsSection(localizationManager.localizedString("settings.advanced.debug.title")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(localizationManager.localizedString("settings.advanced.debug.enableVerboseLogging"), isOn: $settingsManager.enableVerboseLogging)
                        Toggle(localizationManager.localizedString("settings.advanced.debug.showDebugInfo"), isOn: $settingsManager.showDebugInfo)
                        Toggle(localizationManager.localizedString("settings.advanced.debug.saveNetworkLogs"), isOn: $settingsManager.saveNetworkLogs)
                        
                        HStack {
                            Text(localizationManager.localizedString("settings.advanced.debug.logLevel"))
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
                
                settingsSection(localizationManager.localizedString("settings.advanced.performance.title")) {
                    VStack(alignment: .leading, spacing: 12) {
 // 性能模式选择
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(localizationManager.localizedString("settings.advanced.performance.mode"))
                                    .font(.system(size: 13, weight: .medium))
                                Spacer()
                                Text(String(format: localizationManager.localizedString("settings.advanced.currentMode"), performanceModeManager.currentMode.displayName))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
 // MetalFX 性能模式选择器
                            Picker(localizationManager.localizedString("settings.advanced.performance.mode"), selection: $performanceModeManager.currentMode) {
                                ForEach(PerformanceModeType.allCases, id: \.self) { mode in
                                    HStack {
                                        Image(systemName: mode.iconName)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(mode.displayName)
                                                .font(.system(size: 12, weight: .medium))
                                            Text(mode.description)
                                                .font(.system(size: 10))
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    .tag(mode)
                                }
                            }
                            .pickerStyle(MenuPickerStyle())
                            .onChange(of: performanceModeManager.currentMode) { _, newMode in
                                performanceModeManager.switchToMode(newMode)
                            }
                            
 // 配置详情显示
                            VStack(alignment: .leading, spacing: 6) {
                                Text(localizationManager.localizedString("settings.advanced.performance.details.title"))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                
 // 根据模式显示不同的配置信息
                                if performanceModeManager.currentMode == .adaptive {
 // 自适应模式显示性能范围
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(localizationManager.localizedString("settings.advanced.performance.renderScale.range"))
                                            Text(localizationManager.localizedString("settings.advanced.performance.maxParticles.range"))
                                            Text(localizationManager.localizedString("settings.advanced.performance.targetFPS.range"))
                                        }
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                        
                                        Spacer()
                                        
                                        VStack(alignment: .trailing, spacing: 2) {
                                            Text(localizationManager.localizedString("settings.advanced.performance.metalFXQuality.range"))
                                            Text(localizationManager.localizedString("settings.advanced.performance.shadowQuality.dynamic"))
                                            Text(localizationManager.localizedString("settings.advanced.performance.postProcessing.smart"))
                                        }
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                                    .cornerRadius(4)
                                    
 // 显示当前自适应状态
                                    HStack {
                                        Text(localizationManager.localizedString("settings.advanced.performance.currentStatus"))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        Spacer()
                                        Text(localizationManager.localizedString("status.adaptiveTuning"))
                                            .font(.caption)
                                            .foregroundColor(.blue)
                                    }
                                    .padding(.top, 4)
                                } else {
 // 其他模式显示具体配置值
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(String(format: localizationManager.localizedString("settings.advanced.performance.renderScale.formatPercent"), Int(performanceModeManager.currentConfiguration.renderScale * 100)))
                                            Text(String(format: localizationManager.localizedString("settings.advanced.performance.maxParticles.format"), performanceModeManager.currentConfiguration.maxParticles))
                                            Text(String(format: localizationManager.localizedString("settings.advanced.performance.targetFPS.format"), performanceModeManager.currentConfiguration.targetFrameRate))
                                        }
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                        
                                        Spacer()
                                        
                                        VStack(alignment: .trailing, spacing: 2) {
                                            Text(String(format: localizationManager.localizedString("settings.advanced.performance.metalFXQuality.formatPercent"), Int(performanceModeManager.currentConfiguration.metalFXQuality * 100)))
                                            Text("阴影质量: \(performanceModeManager.currentConfiguration.shadowQuality == 2 ? "高" : performanceModeManager.currentConfiguration.shadowQuality == 1 ? "中" : "低")")
                                            Text("后处理: \(performanceModeManager.currentConfiguration.postProcessingLevel > 0 ? "启用" : "禁用")")
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
                        }
                        
                        Divider()
                        
 // 实时天气API设置
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(localizationManager.localizedString("settings.advanced.weather.api.title"))
                                    .font(.system(size: 13, weight: .medium))
                                Spacer()
                                Text(settingsManager.enableRealTimeWeather ? localizationManager.localizedString("status.enabled") : localizationManager.localizedString("status.disabled"))
                                    .font(.caption)
                                    .foregroundColor(settingsManager.enableRealTimeWeather ? .green : .orange)
                            }
                            
                            Toggle(localizationManager.localizedString("settings.advanced.weather.enable"), isOn: $settingsManager.enableRealTimeWeather)
                            
                            HStack {
                                Text(localizationManager.localizedString("settings.common.status"))
                                Spacer()
                                Text(settingsManager.enableRealTimeWeather ? localizationManager.localizedString("status.enabled") : localizationManager.localizedString("status.disabled"))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        Divider()
                        
 // 显示实时FPS（顶部导航全局显示，开启后无数据时显示占位 — FPS）
                        Toggle(localizationManager.localizedString("settings.advanced.performance.showRealtimeFPS"), isOn: $settingsManager.showRealtimeFPS)
                            .help(localizationManager.localizedString("settings.advanced.performance.showRealtimeFPS.help"))
                        
                        Toggle(localizationManager.localizedString("settings.advanced.hardware.enableAcceleration"), isOn: $settingsManager.enableHardwareAcceleration)
                        Toggle(localizationManager.localizedString("settings.advanced.memory.optimize"), isOn: $settingsManager.optimizeMemoryUsage)
                        Toggle(localizationManager.localizedString("settings.advanced.backgroundScanning"), isOn: $settingsManager.enableBackgroundScanning)
                        
 // Metal Performance HUD 设置
                        if hud.isEnabled {
                            Divider()
                            
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Metal Performance HUD")
                                        .font(.system(size: 13, weight: .medium))
                                    Spacer()
                                    if hud.isEnabled {
                                        Text(localizationManager.localizedString("status.enabled"))
                                            .font(.caption)
                                            .foregroundColor(.green)
                                    } else {
                                        Text(localizationManager.localizedString("status.disabled"))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                
                                Toggle(localizationManager.localizedString("settings.hud.enableRealtimeMonitoring"), isOn: Binding(
                                    get: { hud.isEnabled },
                                    set: { enabled in
                                        if enabled {
                                            hud.enable()
                                        } else {
                                            hud.disable()
                                        }
                                    }
                                ))
                                .help(localizationManager.localizedString("settings.hud.enableRealtimeMonitoring.help"))
                                
                                if hud.isEnabled {
                                    Toggle(localizationManager.localizedString("settings.hud.showHUD"), isOn: Binding(
                                         get: { hud.isVisible },
                                         set: { visible in
                                             if visible {
                                                 self.hud.isVisible = true
                            } else {
                                self.hud.isVisible = false
                                             }
                                         }
                                     ))
                                    .help(localizationManager.localizedString("settings.hud.showHUD.help"))
                                    
                                    HStack {
                                        Text(localizationManager.localizedString("settings.hud.position"))
                                        Picker("", selection: Binding(
                                            get: { hud.hudConfiguration.position },
                                            set: { position in
                                                var config = hud.hudConfiguration
                                                config.position = position
                                                hud.updateConfiguration(config)
                                            }
                                        )) {
                                            Text(localizationManager.localizedString("position.topLeft")).tag(HUDPosition.topLeft)
                                            Text(localizationManager.localizedString("position.topRight")).tag(HUDPosition.topRight)
                                            Text(localizationManager.localizedString("position.bottomLeft")).tag(HUDPosition.bottomLeft)
                                            Text(localizationManager.localizedString("position.bottomRight")).tag(HUDPosition.bottomRight)
                                        }
                                        .pickerStyle(MenuPickerStyle())
                                        .frame(width: 100)
                                    }
                                    
 // 性能指标显示选项
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(localizationManager.localizedString("settings.hud.metrics.title"))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        
                                        HStack {
                                            Toggle(localizationManager.localizedString("metric.frameRate"), isOn: Binding(
                                                get: { hud.hudConfiguration.showFrameRate },
                                                set: { show in
                                                    var config = hud.hudConfiguration
                                                    config.showFrameRate = show
                                                    hud.updateConfiguration(config)
                                                }
                                            ))
                                            .toggleStyle(.checkbox)
                                            
                                            Toggle(localizationManager.localizedString("metric.gpuTime"), isOn: Binding(
                                                get: { hud.hudConfiguration.showGPUTime },
                                                set: { show in
                                                    var config = hud.hudConfiguration
                                                    config.showGPUTime = show
                                                    hud.updateConfiguration(config)
                                                }
                                            ))
                                            .toggleStyle(.checkbox)
                                            
                                            Toggle(localizationManager.localizedString("metric.memory"), isOn: Binding(
                                                get: { hud.hudConfiguration.showMemoryUsage },
                                                set: { show in
                                                    var config = hud.hudConfiguration
                                                    config.showMemoryUsage = show
                                                    hud.updateConfiguration(config)
                                                }
                                            ))
                                            .toggleStyle(.checkbox)
                                        }
                                        .font(.caption)
                                    }
                                }
                            }
                        }
                        
                        Divider()
                        
                        HStack {
                            Text(localizationManager.localizedString("settings.common.maxConcurrentConnections"))
                            TextField(localizationManager.localizedString("unit.count.short"), value: $settingsManager.maxConcurrentConnections, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                        }
                    }
                }
                
                settingsSection(localizationManager.localizedString("settings.advanced.experimental.title")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(localizationManager.localizedString("settings.advanced.experimental.enableIPv6"), isOn: $settingsManager.enableIPv6Support)
                        Toggle(localizationManager.localizedString("settings.advanced.experimental.useNewDiscovery"), isOn: $settingsManager.useNewDiscoveryAlgorithm)
                        Toggle(localizationManager.localizedString("settings.advanced.experimental.enableP2P"), isOn: $settingsManager.enableP2PDirectConnection)
                        
                        Text(localizationManager.localizedString("settings.advanced.experimental.warning"))
                            .foregroundColor(.orange)
                            .font(.caption)
                    }
                }
                
                settingsSection(localizationManager.localizedString("settings.advanced.pqc.title")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(localizationManager.localizedString("settings.advanced.pqc.enableAppLayer"), isOn: $settingsManager.enablePQC)
                        Toggle(localizationManager.localizedString("settings.advanced.pqc.enableHybridTLS"), isOn: $settingsManager.enablePQCHybridTLS)
                        HStack {
                            Text(localizationManager.localizedString("settings.advanced.pqc.signatureAlgorithm"))
                            Picker("", selection: $settingsManager.pqcSignatureAlgorithm) {
                                Text("ML-DSA").tag("ML-DSA")
                                Text("SLH-DSA").tag("SLH-DSA")
                                Text("Falcon").tag("Falcon")
                            }
                            .pickerStyle(MenuPickerStyle())
                            .frame(width: 120)
                        }
                        Toggle(localizationManager.localizedString("settings.advanced.pqc.useSecureEnclaveMLDSA"), isOn: $settingsManager.useSecureEnclaveMLDSA)
                        Toggle(localizationManager.localizedString("settings.advanced.pqc.useSecureEnclaveMLKEM"), isOn: $settingsManager.useSecureEnclaveMLKEM)
                        Text(localizationManager.localizedString("settings.advanced.pqc.note"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                settingsSection(localizationManager.localizedString("settings.advanced.smoothing.title")) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(localizationManager.localizedString("settings.advanced.smoothing.alpha"))
                                .font(.system(size: 13, weight: .medium))
                            Spacer()
                            Text(String(format: "%.2f", settingsManager.signalStrengthAlpha))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $settingsManager.signalStrengthAlpha, in: 0.10...0.95, step: 0.05)
                            .help(localizationManager.localizedString("settings.advanced.smoothing.alpha.help"))
                        Text(localizationManager.localizedString("settings.advanced.smoothing.alpha.desc"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                settingsSection(localizationManager.localizedString("settings.advanced.reset.title")) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Button(localizationManager.localizedString("action.resetAllSettings")) {
                                showingResetAlert = true
                            }
                            .buttonStyle(.bordered)
                            .foregroundColor(.red)
                            
                            Button(localizationManager.localizedString("action.resetNetworkSettings")) {
                                settingsManager.resetNetworkSettings()
                            }
                            .buttonStyle(.bordered)
                            
                            Spacer()
                        }
                        
                        Text(localizationManager.localizedString("settings.advanced.reset.warning"))
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
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.primary.opacity(0.1), lineWidth: 1)
                )
        }
        .padding(.horizontal, 20)
    }
    
 /// 权限行
    private func permissionRow(_ permission: PermissionInfo) -> some View {
        HStack {
 // 使用通用符号视图，确保蓝牙等符号在 macOS 14+ 上可靠显示
            SystemSymbolIcon(name: permission.type.iconName, color: .blue, size: 16)
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
                    Button(localizationManager.localizedString("action.request")) {
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
                
                settingsSection(localizationManager.localizedString("settings.fileTransfer.config.title")) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(localizationManager.localizedString("settings.fileTransfer.defaultPath"))
                            TextField(localizationManager.localizedString("unit.path"), text: $settingsManager.defaultTransferPath)
                                .textFieldStyle(.roundedBorder)
                            Button(localizationManager.localizedString("action.select")) {
                                let panel = NSOpenPanel()
                                panel.canChooseDirectories = true
                                panel.canChooseFiles = false
                                panel.allowsMultipleSelection = false
                                panel.begin { response in
                                    if response == .OK, let url = panel.url {
                                        settingsManager.defaultTransferPath = url.path
                                        ftBridge.updateReceiveDirectory(url)
                                    }
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                        
                        HStack {
                            Text(localizationManager.localizedString("settings.fileTransfer.maxConcurrentTransfers"))
                            TextField(localizationManager.localizedString("unit.count.short"), value: $settingsManager.maxConcurrentConnections, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                        }
                        
                        HStack {
                            Text(localizationManager.localizedString("settings.fileTransfer.bufferSize"))
                            Picker("", selection: $settingsManager.transferBufferSize) {
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
                
                settingsSection(localizationManager.localizedString("settings.fileTransfer.options.title")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(localizationManager.localizedString("settings.fileTransfer.options.showNotification"), isOn: $settingsManager.showSystemNotifications)
                        Toggle(localizationManager.localizedString("settings.fileTransfer.options.autoRetryFailed"), isOn: $settingsManager.autoRetryFailedTransfers)
                        Toggle(localizationManager.localizedString("settings.fileTransfer.options.keepHistory"), isOn: $settingsManager.keepTransferHistory)
                        Toggle(localizationManager.localizedString("settings.fileTransfer.options.keepAwake"), isOn: $settingsManager.keepSystemAwakeDuringTransfer)
                        
                        HStack {
                            Text(localizationManager.localizedString("settings.common.retryCount"))
                            TextField(localizationManager.localizedString("unit.times.short"), value: $settingsManager.retryCount, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                        }
                    }
                }
                
                settingsSection(localizationManager.localizedString("settings.fileTransfer.security.title")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(localizationManager.localizedString("settings.fileTransfer.security.enableEncrypt"), isOn: $settingsManager.enableConnectionEncryption)
                        Toggle(localizationManager.localizedString("settings.fileTransfer.security.verifyIntegrity"), isOn: $settingsManager.verifyCertificates)
                        Toggle(localizationManager.localizedString("settings.fileTransfer.security.scanVirus"), isOn: $settingsManager.scanTransferFilesForVirus)
                        
                        HStack {
                            Text(localizationManager.localizedString("settings.fileTransfer.security.scanLevel"))
                            Picker("", selection: $settingsManager.scanLevel) {
                                Text(localizationManager.localizedString("settings.fileTransfer.security.scanLevel.quick"))
                                    .tag(FileScanService.ScanLevel.quick)
                                Text(localizationManager.localizedString("settings.fileTransfer.security.scanLevel.standard"))
                                    .tag(FileScanService.ScanLevel.standard)
                                Text(localizationManager.localizedString("settings.fileTransfer.security.scanLevel.deep"))
                                    .tag(FileScanService.ScanLevel.deep)
                            }
                            .pickerStyle(MenuPickerStyle())
                            .frame(width: 120)
                            .disabled(!settingsManager.scanTransferFilesForVirus)
                        }
                        
                        HStack {
                            Text(localizationManager.localizedString("settings.fileTransfer.security.algorithm"))
                            Picker("", selection: $settingsManager.encryptionAlgorithm) {
                                Text("AES-256").tag("AES-256")
                                Text("ChaCha20").tag("ChaCha20")
                                Text("AES-128").tag("AES-128")
                            }
                            .pickerStyle(MenuPickerStyle())
                            .frame(width: 120)
                        }
                    }
                }

                HStack {
                    Spacer()
                    Button(localizationManager.localizedString("action.applySettings")) {
                        ftBridge.apply()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }
    
 // MARK: - 视频传输配置部分
    
    private var videoTransferConfigurationSection: some View {
        settingsSection(localizationManager.localizedString("settings.videoTransfer.title")) {
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
                            Text(localizationManager.localizedString("settings.videoTransfer.currentConfig"))
                                .font(.headline)
                            
 // 配置状态徽章
                            Text(videoSettingsManager.isConfigurationOptimal ? localizationManager.localizedString("status.optimized") : localizationManager.localizedString("status.needsAdjust"))
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
                            
                            Text(localizationManager.localizedString("settings.videoTransfer.estimatedRate"))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        HStack(spacing: 4) {
                            Text(String(format: "%.1f", videoSettingsManager.estimatedDataRate))
                                .font(.headline.monospacedDigit())
                                .foregroundColor(.blue)
                                .contentTransition(.numericText())
                                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: videoSettingsManager.estimatedDataRate)
                            
                            Text(localizationManager.localizedString("unit.mbPerSecond"))
                                .font(.caption)
                                .foregroundColor(.blue)
                        }
                        
 // 传输率等级指示
                        Text(videoSettingsManager.estimatedDataRate > 10 ? localizationManager.localizedString("status.load.high") : 
                             videoSettingsManager.estimatedDataRate > 5 ? localizationManager.localizedString("status.load.medium") : localizationManager.localizedString("status.load.low"))
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
                        Text(localizationManager.localizedString("settings.videoTransfer.resolution.title"))
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Text(localizationManager.localizedString("settings.videoTransfer.resolution.desc"))
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
                        Text(localizationManager.localizedString("settings.videoTransfer.frameRate.title"))
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Text(localizationManager.localizedString("settings.videoTransfer.frameRate.desc"))
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
                        Text(localizationManager.localizedString("settings.videoTransfer.presets.title"))
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Text(localizationManager.localizedString("settings.videoTransfer.presets.desc"))
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
                DisclosureGroup(localizationManager.localizedString("settings.videoTransfer.advancedOptions.title"), isExpanded: $videoSettingsManager.showAdvancedOptions) {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(localizationManager.localizedString("settings.videoTransfer.enableHardwareAcceleration"), isOn: $videoSettingsManager.enableHardwareAcceleration)
                            .help(localizationManager.localizedString("settings.videoTransfer.enableHardwareAcceleration.help"))
                        
                        Toggle(localizationManager.localizedString("settings.videoTransfer.enableAppleSiliconOptimization"), isOn: $videoSettingsManager.enableAppleSiliconOptimization)
                            .help(localizationManager.localizedString("settings.videoTransfer.enableAppleSiliconOptimization.help"))
                        
                        Toggle(localizationManager.localizedString("settings.videoTransfer.enableAdaptiveBitrate"), isOn: $videoSettingsManager.enableAdaptiveBitrate)
                            .help(localizationManager.localizedString("settings.videoTransfer.enableAdaptiveBitrate.help"))
                        
                        HStack {
                            Text(localizationManager.localizedString("settings.videoTransfer.compressionQuality"))
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
                settingsSection(localizationManager.localizedString("settings.remote.display.title")) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(localizationManager.localizedString("settings.remote.display.videoQuality"))
                            Picker("", selection: $remoteDesktopSettingsManager.settings.displaySettings.videoQuality) {
                                Text(localizationManager.localizedString("quality.low")).tag(VideoQuality.low)
                                Text(localizationManager.localizedString("quality.medium")).tag(VideoQuality.medium)
                                Text(localizationManager.localizedString("quality.high")).tag(VideoQuality.high)
                                Text(localizationManager.localizedString("quality.ultra")).tag(VideoQuality.ultra)
                            }
                            .pickerStyle(MenuPickerStyle())
                            .frame(width: 100)
                        }
                        
                        HStack {
                            Text(localizationManager.localizedString("settings.remote.display.compressionLevel"))
                            Slider(
                                value: $remoteDesktopSettingsManager.settings.displaySettings.compressionLevel,
                                in: 1...100,
                                step: 1
                            )
                            Text("\(Int(remoteDesktopSettingsManager.settings.displaySettings.compressionLevel))")
                                .foregroundColor(.secondary)
                                .frame(width: 20)
                        }
                        
                        HStack {
                            Text(localizationManager.localizedString("settings.remote.display.refreshRate"))
                            Picker("", selection: $remoteDesktopSettingsManager.settings.displaySettings.refreshRate) {
                                Text("30 Hz").tag(RefreshRate.hz30)
                                Text("60 Hz").tag(RefreshRate.hz60)
                                Text("75 Hz").tag(RefreshRate.hz75)
                                Text("120 Hz").tag(RefreshRate.hz120)
                                Text("144 Hz").tag(RefreshRate.hz144)
                            }
                            .pickerStyle(MenuPickerStyle())
                            .frame(width: 100)
                        }
                        
                        Toggle(localizationManager.localizedString("settings.remote.network.enableAdaptiveQuality"), isOn: $remoteDesktopSettingsManager.settings.networkSettings.enableAdaptiveQuality)
                        Toggle(localizationManager.localizedString("settings.remote.display.fullScreenMode"), isOn: $remoteDesktopSettingsManager.settings.displaySettings.fullScreenMode)
                    }
                }
                
                settingsSection(localizationManager.localizedString("settings.remote.interaction.title")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(localizationManager.localizedString("settings.remote.interaction.clipboardSync"), isOn: $remoteDesktopSettingsManager.settings.interactionSettings.enableClipboardSync)
                        Toggle(localizationManager.localizedString("settings.remote.interaction.audioRedirection"), isOn: $remoteDesktopSettingsManager.settings.interactionSettings.enableAudioRedirection)
                        Toggle(localizationManager.localizedString("settings.remote.interaction.fileTransfer"), isOn: $remoteDesktopSettingsManager.settings.interactionSettings.enableFileTransfer)
                        Toggle(localizationManager.localizedString("settings.remote.interaction.trackpadGestures"), isOn: $remoteDesktopSettingsManager.settings.interactionSettings.enableTrackpadGestures)
                        
                        HStack {
                            Text(localizationManager.localizedString("settings.remote.interaction.mouseSensitivity"))
                            Slider(
                                value: $remoteDesktopSettingsManager.settings.interactionSettings.mouseSensitivity,
                                in: 0.1...3.0,
                                step: 0.1
                            )
                            Text("\(remoteDesktopSettingsManager.settings.interactionSettings.mouseSensitivity, specifier: "%.1f")")
                                .foregroundColor(.secondary)
                                .frame(width: 30)
                        }
                        
                        HStack {
                            Text(localizationManager.localizedString("settings.remote.interaction.doubleClickInterval"))
                            TextField(localizationManager.localizedString("unit.millisecond.short"), 
                                value: Binding(
                                    get: { remoteDesktopSettingsManager.settings.interactionSettings.doubleClickInterval },
                                    set: { remoteDesktopSettingsManager.settings.interactionSettings.doubleClickInterval = $0 }
                                ),
                                format: .number
                            )
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                        }
                    }
                }
                
                settingsSection(localizationManager.localizedString("settings.remote.network.title")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(localizationManager.localizedString("settings.remote.network.enableBandwidthAdaptive"), isOn: $remoteDesktopSettingsManager.settings.networkSettings.enableAdaptiveQuality)
                        Toggle(localizationManager.localizedString("settings.remote.network.enableUDP"), isOn: $remoteDesktopSettingsManager.settings.networkSettings.enableUDPTransport)
                        Toggle(localizationManager.localizedString("settings.remote.network.enableCompression"), isOn: $remoteDesktopSettingsManager.settings.networkSettings.enableEncryption)
                        
                        HStack {
                            Text(localizationManager.localizedString("settings.remote.network.bandwidthLimit"))
                            TextField(localizationManager.localizedString("unit.bandwidth"), 
                                value: Binding(
                                    get: { remoteDesktopSettingsManager.settings.networkSettings.bandwidthLimit },
                                    set: { remoteDesktopSettingsManager.settings.networkSettings.bandwidthLimit = $0 }
                                ),
                                format: .number
                            )
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                        }
                        
                        HStack {
                            Text(localizationManager.localizedString("settings.remote.network.bufferSize"))
                            Picker("", selection: $remoteDesktopSettingsManager.settings.networkSettings.bufferSize) {
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
                
 // 添加设置操作按钮
                HStack {
                    Button(localizationManager.localizedString("action.resetToDefaults")) {
                        remoteDesktopSettingsManager.resetToDefaults()
                    }
                    .buttonStyle(.bordered)
                    
                    Spacer()
                    
                    Button(localizationManager.localizedString("action.applySettings")) {
                        applyRemoteDesktopSettings()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.top, 20)
            }
        }
    }
    
 // MARK: - 系统监控设置
    private var systemMonitorSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                settingsSection(localizationManager.localizedString("settings.systemMonitor.config.title")) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(localizationManager.localizedString("settings.systemMonitor.config.refreshInterval"))
                            Picker("", selection: Binding(
                                get: { Int(settingsManager.systemMonitorRefreshInterval) },
                                set: { settingsManager.systemMonitorRefreshInterval = Double($0) }
                            )) {
                                Text(localizationManager.localizedString("unit.seconds.1")).tag(1)
                                Text(localizationManager.localizedString("unit.seconds.5")).tag(5)
                                Text(localizationManager.localizedString("unit.seconds.10")).tag(10)
                                Text(localizationManager.localizedString("unit.seconds.30")).tag(30)
                            }
                            .pickerStyle(MenuPickerStyle())
                            .frame(width: 80)
                        }
                        
                        Toggle(localizationManager.localizedString("settings.systemMonitor.config.enableRealtime"), isOn: $settingsManager.enableAutoRefresh)
                        Toggle(localizationManager.localizedString("settings.systemMonitor.config.enableHistory"), isOn: $settingsManager.showTrendIndicators)
                        Toggle(localizationManager.localizedString("settings.systemMonitor.config.enablePerformanceAlerts"), isOn: $settingsManager.enableSystemNotifications)
                        
                        HStack {
                            Text(localizationManager.localizedString("settings.systemMonitor.config.retentionDays"))
                            TextField(localizationManager.localizedString("unit.days.short"), value: Binding(
                                get: { Int(settingsManager.maxHistoryPoints / 24) }, // 假设每小时一个点，转换为天数
                                set: { settingsManager.maxHistoryPoints = Double($0 * 24) }
                            ), format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                        }
                    }
                }
                
                settingsSection(localizationManager.localizedString("settings.systemMonitor.display.title")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(localizationManager.localizedString("settings.systemMonitor.display.cpu"), isOn: $settingsManager.showDeviceDetails)
                        Toggle(localizationManager.localizedString("settings.systemMonitor.display.memory"), isOn: $settingsManager.showConnectionStats)
                        Toggle(localizationManager.localizedString("settings.systemMonitor.display.disk"), isOn: $settingsManager.showTrendIndicators)
                        Toggle(localizationManager.localizedString("settings.systemMonitor.display.network"), isOn: $settingsManager.enableSystemNotifications)
                        Toggle(localizationManager.localizedString("settings.systemMonitor.display.temperature"), isOn: $settingsManager.showDebugInfo)
                        Toggle(localizationManager.localizedString("settings.systemMonitor.display.fanSpeed"), isOn: $settingsManager.enableVerboseLogging)
                        
                        HStack {
                            Text(localizationManager.localizedString("settings.systemMonitor.display.chartType"))
                            Picker("", selection: $settingsManager.logLevel) {
                                Text(localizationManager.localizedString("chart.line")).tag("Info")
                                Text(localizationManager.localizedString("chart.bar")).tag("Warning")
                                Text(localizationManager.localizedString("chart.area")).tag("Debug")
                            }
                            .pickerStyle(MenuPickerStyle())
                            .frame(width: 100)
                        }
                    }
                }
                
                settingsSection(localizationManager.localizedString("settings.systemMonitor.alerts.title")) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(localizationManager.localizedString("settings.systemMonitor.alerts.cpuThreshold"))
                            Slider(value: $settingsManager.cpuThreshold, in: 50...95, step: 5)
                            Text("\(Int(settingsManager.cpuThreshold))%")
                                .foregroundColor(.secondary)
                                .frame(width: 40)
                        }
                        
                        HStack {
                            Text(localizationManager.localizedString("settings.systemMonitor.alerts.memoryThreshold"))
                            Slider(value: $settingsManager.memoryThreshold, in: 50...95, step: 5)
                            Text("\(Int(settingsManager.memoryThreshold))%")
                                .foregroundColor(.secondary)
                                .frame(width: 40)
                        }
                        
                        HStack {
                            Text(localizationManager.localizedString("settings.systemMonitor.alerts.diskThreshold"))
                            Slider(value: $settingsManager.diskThreshold, in: 70...95, step: 5)
                            Text("\(Int(settingsManager.diskThreshold))%")
                                .foregroundColor(.secondary)
                                .frame(width: 40)
                        }
                        
                        Toggle(localizationManager.localizedString("settings.systemMonitor.alerts.enableSound"), isOn: $settingsManager.enableSoundAlerts)
                        Toggle(localizationManager.localizedString("settings.systemMonitor.alerts.enableNotificationCenter"), isOn: $settingsManager.enableSystemNotifications)
                    }
                }
                
                settingsSection(localizationManager.localizedString("settings.systemMonitor.advanced.title")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(localizationManager.localizedString("settings.systemMonitor.advanced.enableVerboseLogging"), isOn: $settingsManager.enableVerboseLogging)
                        Toggle(localizationManager.localizedString("settings.systemMonitor.advanced.exportData"), isOn: $settingsManager.saveNetworkLogs)
                        Toggle(localizationManager.localizedString("settings.systemMonitor.advanced.enableRemoteMonitoring"), isOn: $settingsManager.enableBackgroundScanning)
                        
                        HStack {
                            Text(localizationManager.localizedString("settings.systemMonitor.advanced.samplingPrecision"))
                            Picker("", selection: $settingsManager.logLevel) {
                                Text(localizationManager.localizedString("precision.low")).tag("Error")
                                Text(localizationManager.localizedString("precision.normal")).tag("Info")
                                Text(localizationManager.localizedString("precision.high")).tag("Debug")
                            }
                            .pickerStyle(MenuPickerStyle())
                            .frame(width: 80)
                        }
                        
                        Button(localizationManager.localizedString("action.resetMonitorData")) {
 // 重置监控数据的逻辑
                            Task { @MainActor in
                                settingsManager.cpuThreshold = 80.0
                                settingsManager.memoryThreshold = 80.0
                                settingsManager.diskThreshold = 90.0
                                settingsManager.systemMonitorRefreshInterval = 1.0
                                settingsManager.maxHistoryPoints = 300.0
                            }
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
    
 /// 请求通知权限（统一入口）
 /// 说明：通过 SettingsManager 统一申请系统通知权限，并同步开关状态
    private func requestNotificationPermission() {
        Task { @MainActor in
            let granted = await settingsManager.requestNotificationPermission()
 // 将最终授权结果写入用户偏好，确保下次启动保持一致
            UserDefaults.standard.set(granted, forKey: "ShowSystemNotifications")
        SkyBridgeLogger.ui.debugOnly("🔔 [设置] 通知权限已\(granted ? "授予" : "拒绝")")
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
            } catch {
 // 静默处理错误，避免在生产环境中输出调试信息
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
    
 /// 应用远程桌面设置
    private func applyRemoteDesktopSettings() {
        Task { @MainActor in
 // 保存设置到持久化存储
            remoteDesktopSettingsManager.saveSettings()
            
 // 注意：设置将在下次创建新会话时自动应用
 // 如需立即应用到现有会话，请使用各会话的 applySettings 方法
        }
    }
    
 /// 添加自定义服务类型
    private func addCustomServiceType() {
 // 去除首尾空格
        let trimmedType = newCustomServiceType.trimmingCharacters(in: .whitespacesAndNewlines)
        
 // 验证输入
        guard !trimmedType.isEmpty else {
            return
        }
        
 // 检查是否已存在
        guard !settingsManager.customServiceTypes.contains(trimmedType) else {
            return
        }
        
 // 添加到设置管理器
        settingsManager.addCustomServiceType(trimmedType)
        
 // 清空输入框
        newCustomServiceType = ""
    }
}
