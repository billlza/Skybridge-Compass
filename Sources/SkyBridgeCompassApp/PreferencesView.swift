import SwiftUI
import SkyBridgeCore
import UniformTypeIdentifiers
import UserNotifications

// 确保可以访问天气管理器
import Combine

/// macOS 偏好设置窗口 - 遵循 Apple 设计规范
struct PreferencesView: View {

 // MARK: - 状态管理
    @EnvironmentObject private var settingsManager: SettingsManager
    @EnvironmentObject private var weatherManager: WeatherIntegrationManager
    @EnvironmentObject private var weatherSettings: WeatherEffectsSettings

    @State private var selectedTab: PreferencesTab = .general

 // MARK: - 偏好设置标签页枚举
    enum PreferencesTab: String, CaseIterable {
        case general = "通用"
        case network = "网络"
        case devices = "设备"
        case permissions = "权限"
        case advanced = "高级"
        case about = "关于"

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
            case .about:
                return "info.circle"
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

 // 关于
            AboutPreferencesView()
                .tabItem {
                    Label(PreferencesTab.about.rawValue, systemImage: PreferencesTab.about.iconName)
                }
                .tag(PreferencesTab.about)
        }
        .frame(minWidth: 750, minHeight: 700)  // 增加最小高度以显示所有内容
 // EnvironmentObjects 已从 App 级别注入，子视图自动继承
    }
}

// MARK: - 通用偏好设置视图
struct GeneralPreferencesView: View {
    @EnvironmentObject private var settingsManager: SettingsManager
    @EnvironmentObject private var themeConfiguration: ThemeConfiguration
    @EnvironmentObject private var localizationManager: LocalizationManager

    var body: some View {
        Form {
            Section(header: Text("settings.general.language.sectionTitle", bundle: .module)) {
                Picker(
                    selection: Binding(
                        get: { localizationManager.currentLanguage },
                        set: { newValue in
                            localizationManager.setLanguage(newValue)
                        }
                    ),
                    label: Text("settings.general.language.label", bundle: .module)
                ) {
                    ForEach(AppLanguage.allCases) { language in
                        if language == .system {
                            Text("settings.language.system", bundle: .module).tag(language)
                        } else {
                            Text(language.displayName).tag(language)
                        }
                    }
                }
                .pickerStyle(.menu)
                Text("settings.general.language.description", bundle: .module)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

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

            Section("个性化背景") {
                HStack {
                    if let path = themeConfiguration.customBackgroundImagePath,
                       let image = NSImage(contentsOfFile: path) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 100, height: 60)
                            .cornerRadius(6)
                            .clipped()
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                            )
                    } else {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.1))
                            .frame(width: 100, height: 60)
                            .cornerRadius(6)
                            .overlay(
                                VStack {
                                    Image(systemName: "photo")
                                        .font(.system(size: 20))
                                    Text("无背景")
                                        .font(.caption2)
                                }
                                .foregroundColor(.secondary)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                            )
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Button("选择图片...") {
                            let panel = NSOpenPanel()
                            panel.allowedContentTypes = [.image]
                            panel.allowsMultipleSelection = false
                            panel.canChooseDirectories = false
                            panel.message = "选择一张图片作为自定义背景"

                            if panel.runModal() == .OK, let url = panel.url {
 // Save image to app sandbox
                                Task { @MainActor in
                                    do {
                                        let fileManager = FileManager.default
                                        let appSupport = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                                        let saveDir = appSupport.appendingPathComponent("CustomBackgrounds")

                                        if !fileManager.fileExists(atPath: saveDir.path) {
                                            try fileManager.createDirectory(at: saveDir, withIntermediateDirectories: true)
                                        }

                                        let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
                                        let destURL = saveDir.appendingPathComponent("background.\(ext)")

                                        if fileManager.fileExists(atPath: destURL.path) {
                                            try fileManager.removeItem(at: destURL)
                                        }

                                        try fileManager.copyItem(at: url, to: destURL)
                                        themeConfiguration.setCustomBackgroundImage(path: destURL.path)

                                    } catch {
                                        SkyBridgeLogger.ui.error("Failed to save background image: \(error.localizedDescription, privacy: .private)")
                                    }
                                }
                            }
                        }
                        .help("从本地选择一张图片作为背景")

                        if themeConfiguration.customBackgroundImagePath != nil {
                            Button("清除背景") {
                                themeConfiguration.customBackgroundImagePath = nil
 // Switch back to default if current is custom
                                if themeConfiguration.currentTheme == .custom {
                                    themeConfiguration.switchToTheme(.starryNight)
                                }
                            }
                            .foregroundColor(.red)
                            .buttonStyle(.link)
                        }
                    }
                    .padding(.leading, 8)
                }
                .padding(.vertical, 4)

                if themeConfiguration.customBackgroundImagePath != nil {
                    Text("提示: 选择图片后将自动切换到“自定义背景”主题。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
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
                                    SkyBridgeLogger.ui.error("导出设置失败: \(error.localizedDescription, privacy: .private)")
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
                                    SkyBridgeLogger.ui.error("导入设置失败: \(error.localizedDescription, privacy: .private)")
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

                Toggle("优先使用5GHz/6GHz频段", isOn: $settingsManager.prefer5GHz)
                    .help("在可用时优先连接5GHz/6GHz WiFi网络")

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

            Section("提醒设置") {
                Toggle("仅提醒已验签设备", isOn: $settingsManager.onlyNotifyVerifiedDevices)
                    .help("启用后，仅针对验签通过的设备触发“可连接设备”提醒。")
                Toggle("启用实时天气", isOn: $settingsManager.enableRealTimeWeather)
                    .help("启用后，将获取实时天气与AQI用于健康提醒。")
                Toggle("敏感人群更严格模式", isOn: $settingsManager.strictModeForSensitiveGroups)
                    .help("启用后，将适当下调AQI阈值以更严格地提示健康防护。")
            }

            Section("健康提醒阈值") {
                Group {
                    Text("AQI阈值（城市）").font(.subheadline).foregroundColor(.secondary)
                    HStack {
                        Text("提示(AQI)")
                        Spacer()
                        Stepper(value: $settingsManager.aqiThresholdCautionUrban, in: 50...200, step: 10) {
                            Text("\(settingsManager.aqiThresholdCautionUrban)")
                                .frame(width: 60, alignment: .trailing)
                        }
                    }
                    HStack {
                        Text("敏感人群(AQI)")
                        Spacer()
                        Stepper(value: $settingsManager.aqiThresholdSensitiveUrban, in: 80...250, step: 10) {
                            Text("\(settingsManager.aqiThresholdSensitiveUrban)")
                                .frame(width: 60, alignment: .trailing)
                        }
                    }
                    HStack {
                        Text("不健康(AQI)")
                        Spacer()
                        Stepper(value: $settingsManager.aqiThresholdUnhealthyUrban, in: 150...300, step: 10) {
                            Text("\(settingsManager.aqiThresholdUnhealthyUrban)")
                                .frame(width: 60, alignment: .trailing)
                        }
                    }
                    HStack {
                        Text("非常不健康(AQI)")
                        Spacer()
                        Stepper(value: $settingsManager.aqiThresholdVeryUnhealthyUrban, in: 200...400, step: 10) {
                            Text("\(settingsManager.aqiThresholdVeryUnhealthyUrban)")
                                .frame(width: 60, alignment: .trailing)
                        }
                    }
                }
                Group {
                    Text("AQI阈值（郊区）").font(.subheadline).foregroundColor(.secondary)
                    HStack {
                        Text("提示(AQI)")
                        Spacer()
                        Stepper(value: $settingsManager.aqiThresholdCautionSuburban, in: 60...220, step: 10) {
                            Text("\(settingsManager.aqiThresholdCautionSuburban)")
                                .frame(width: 60, alignment: .trailing)
                        }
                    }
                    HStack {
                        Text("敏感人群(AQI)")
                        Spacer()
                        Stepper(value: $settingsManager.aqiThresholdSensitiveSuburban, in: 90...260, step: 10) {
                            Text("\(settingsManager.aqiThresholdSensitiveSuburban)")
                                .frame(width: 60, alignment: .trailing)
                        }
                    }
                    HStack {
                        Text("不健康(AQI)")
                        Spacer()
                        Stepper(value: $settingsManager.aqiThresholdUnhealthySuburban, in: 160...320, step: 10) {
                            Text("\(settingsManager.aqiThresholdUnhealthySuburban)")
                                .frame(width: 60, alignment: .trailing)
                        }
                    }
                    HStack {
                        Text("非常不健康(AQI)")
                        Spacer()
                        Stepper(value: $settingsManager.aqiThresholdVeryUnhealthySuburban, in: 220...420, step: 10) {
                            Text("\(settingsManager.aqiThresholdVeryUnhealthySuburban)")
                                .frame(width: 60, alignment: .trailing)
                        }
                    }
                }

                Group {
                    Text("UV 阈值").font(.subheadline).foregroundColor(.secondary)
                    HStack {
                        Text("中等(UV)")
                        Spacer()
                        Stepper(value: $settingsManager.uvThresholdModerate, in: 3...10, step: 0.5) {
                            Text(String(format: "%.1f", settingsManager.uvThresholdModerate))
                                .frame(width: 60, alignment: .trailing)
                        }
                    }
                    HStack {
                        Text("强(UV)")
                        Spacer()
                        Stepper(value: $settingsManager.uvThresholdStrong, in: 5...12, step: 0.5) {
                            Text(String(format: "%.1f", settingsManager.uvThresholdStrong))
                                .frame(width: 60, alignment: .trailing)
                        }
                    }
                }
            }

            Section("设备排序权重") {
                HStack {
                    Text("验签通过权重")
                    Spacer()
                    Stepper(value: $settingsManager.sortWeightVerified, in: 0...5000, step: 100) {
                        Text("\(settingsManager.sortWeightVerified)")
                            .frame(width: 80, alignment: .trailing)
                    }
                }
                .help("验签通过的设备在列表排序中获得该分值，以提高优先级")

                HStack {
                    Text("已连接权重")
                    Spacer()
                    Stepper(value: $settingsManager.sortWeightConnected, in: 0...5000, step: 100) {
                        Text("\(settingsManager.sortWeightConnected)")
                            .frame(width: 80, alignment: .trailing)
                    }
                }
                .help("已连接设备在列表排序中获得该分值，以提高优先级")

                HStack {
                    Text("信号强度系数")
                    Spacer()
                    Stepper(value: $settingsManager.sortWeightSignalMultiplier, in: 0...200, step: 10) {
                        Text("\(settingsManager.sortWeightSignalMultiplier)")
                            .frame(width: 80, alignment: .trailing)
                    }
                }
                .help("信号强度分值 = 强度(0~1) × 系数；用于细化排序")
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
    @State private var isLocationAuthorized = false
    @State private var isNotificationAuthorized = false
    // macOS App Sandbox 的网络权限是 entitlement 级别，不存在运行时“授权/未授权”弹窗；
    // 这里用“已配置/未配置”表达（避免占位假数据）。
    @State private var isNetworkConfigured = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("权限管理")
                .font(.title2)
                .fontWeight(.semibold)

            Text("SkyBridge Compass 需要以下权限来正常工作:")
                .foregroundColor(.secondary)

 // 简化的权限列表
            VStack(spacing: 12) {
                PermissionSimpleRow(
                    title: "位置权限",
                    description: "用于获取天气信息",
                    isGranted: isLocationAuthorized,
                    icon: "location.fill"
                )

                PermissionSimpleRow(
                    title: "通知权限",
                    description: "用于设备连接提醒",
                    isGranted: isNotificationAuthorized,
                    icon: "bell.fill"
                )

                PermissionSimpleRow(
                    title: "网络权限",
                    description: "用于设备发现和连接",
                    isGranted: isNetworkConfigured,
                    icon: "network"
                )
            }

            Divider()

            HStack {
                Button("打开系统设置") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)

                Spacer()
            }

            Spacer()
        }
        .padding()
        .task {
            await refreshPermissionStatus()
        }
    }

    @MainActor
    private func refreshPermissionStatus() async {
        // Location: CLLocationManager.authorizationStatus() 需要 CoreLocation；如果项目已有 LocationManager，则复用其判断逻辑。
        // 这里做“最小侵入”实现：有 LocationManager 就用它；否则保持 false 并让用户去系统设置打开。
        if let lm = try? await LocationAuthorizationProbe.current() {
            isLocationAuthorized = lm
        }

        // Notifications: 使用 UNUserNotificationCenter 查询真实授权状态
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        isNotificationAuthorized = (settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional)

        // Network entitlement configured (best-effort): sandbox 默认有 network.client；如果 app-sandbox 关闭也视为可用
        isNetworkConfigured = true
    }
}

// MARK: - Best-effort location authorization probe
// 说明：主工程里有自己的 LocationManager/Weather 体系；这里不强依赖 CoreLocation，
// 只在可用时探测，避免引入新的 capability/编译依赖。
@MainActor
private enum LocationAuthorizationProbe {
    static func current() async throws -> Bool {
        // If CoreLocation is linked in this target, you can switch to CLLocationManager.authorizationStatus().
        // For now, return false so UI won't lie.
        return false
    }
}

// 简化的权限行视图
struct PermissionSimpleRow: View {
    let title: String
    let description: String
    let isGranted: Bool
    let icon: String

    var body: some View {
        HStack {
 // 使用通用符号视图以实现全局一致的符号兜底，避免图标缺失
            SystemSymbolIcon(name: icon,
                              color: isGranted ? .green : .orange,
                              size: 16,
                              weight: .regular)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Image(systemName: isGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(isGranted ? .green : .red)
        }
        .padding(.vertical, 4)
    }
}

// 暂时注释掉原来的复杂代码
/*
            GroupBox("快速引导（定位与天气验证）") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("一步完成定位授权并验证天气功能。")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    HStack(spacing: 8) {
                        Button("请求定位权限") {
                            locationService.requestLocationPermission()
                        }
                        .buttonStyle(.bordered)

                        Button("打开隐私设置") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.bordered)

                        Button("一键请求所有必需权限") {
                            Task {
                                await permissionManager.requestAllRequiredPermissions()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(permissionManager.allRequiredPermissionsGranted)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("定位状态:")
                            Spacer()
                            Text(locationService.isLocationAuthorized ? "已授权" : "未授权")
                                .foregroundColor(locationService.isLocationAuthorized ? .green : .red)
                        }
                        HStack {
                            Text("当前城市:")
                            Spacer()
                            Text(locationService.currentCity.isEmpty ? "未知" : locationService.currentCity)
                                .foregroundColor(.primary)
                        }
                        HStack {
                            Text("坐标:")
                            Spacer()
                            if let loc = locationService.currentLocation {
                                Text(String(format: "%.4f, %.4f", loc.coordinate.latitude, loc.coordinate.longitude))
                            } else {
                                Text("未获取").foregroundColor(.secondary)
                            }
                        }
                        HStack {
                            Text("服务状态:")
                            Spacer()
                            Text(realTimeWeatherService.serviceStatus.displayName)
                                .foregroundColor(serviceStatusColor)
                        }
                        if let error = realTimeWeatherService.lastError {
                            Text(error.localizedDescription)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }

                    HStack {
                        Button("开始位置更新") {
                            locationService.startLocationUpdates()
                        }
                        .disabled(!locationService.isLocationAuthorized)

                        Button("停止位置更新") {
                            locationService.stopLocationUpdates()
                        }

                        Spacer()

                        Button("拉取天气数据") {
                            if let loc = locationService.currentLocation {
                                isVerifyingWeather = true
                                Task {
                                    await weatherDataService.fetchWeather(for: loc)
                                    isVerifyingWeather = false
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(locationService.currentLocation == nil)
                    }

                    if isVerifyingWeather {
                        ProgressView("正在获取天气…")
                    } else {
                        HStack {
                            Text("天气概览:")
                            Spacer()
                            Text(weatherDataService.currentWeather != nil
                                 ? "\(weatherDataService.getCurrentWeatherType().displayName) · \(String(format: "%.1f℃", weatherDataService.currentWeather!.currentWeather.temperature.value))"
                                 : "\(weatherDataService.getCurrentWeatherType().displayName)")
                                .foregroundColor(weatherDataService.getCurrentWeatherType() == .unknown ? .secondary : .primary)
                        }
                    }
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
*/

// 注释掉原来的 PermissionRowView
/*
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
*/

// MARK: - 高级偏好设置视图
struct AdvancedPreferencesView: View {
    @EnvironmentObject private var settingsManager: SettingsManager
    @EnvironmentObject private var weatherManager: WeatherIntegrationManager
    @EnvironmentObject private var weatherSettings: WeatherEffectsSettings
    @AppStorage("ssh.trustOnFirstUse") private var trustOnFirstUse: Bool = false
    @State private var knownHosts: [SSHKnownHostEntry] = []
    @State private var showingKnownHostsImporter = false
    @State private var knownHostsMessage: String?

    var body: some View {
        ScrollView {
            Form {
                Section("性能设置") {
                    Picker("性能模式", selection: $settingsManager.performanceMode) {
                        ForEach(SettingsManager.PerformanceMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .help("调整背景动画的渲染帧率以平衡性能和功耗")

                    Text("目标帧率: \(Int(settingsManager.performanceMode.targetFPS)) FPS")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("调试选项") {
                Toggle("启用详细日志", isOn: $settingsManager.enableVerboseLogging)
                    .help("启用详细的调试日志记录")

                Toggle("显示调试信息", isOn: $settingsManager.showDebugInfo)
                    .help("在界面中显示调试信息")

                Toggle("保存网络日志", isOn: $settingsManager.saveNetworkLogs)
                    .help("将网络活动保存到日志文件")

 // 隐私诊断开关，用于采集TLS握手中的ALPN与SNI，仅供诊断使用，默认关闭以保护隐私
                Toggle("启用握手隐私诊断（ALPN/SNI）", isOn: $settingsManager.enableHandshakeDiagnostics)
                    .help("采集TLS握手期间的ALPN与SNI，仅用于诊断，默认关闭以保护隐私")

 // 实时FPS显示开关（默认关闭），开启后在仪表盘顶部显示渲染FPS
                Toggle("显示实时FPS", isOn: $settingsManager.showRealtimeFPS)
                    .help("在仪表盘顶部显示Metal渲染FPS（每0.5秒更新，发布频率2Hz）")

 // 兼容/更多设备发现开关（默认关闭）；开启后将扫描 AirPlay/SSH/RDP 等更多服务类型
                Toggle("兼容/更多设备", isOn: $settingsManager.enableCompatibilityMode)
                    .help("默认仅扫描 _skybridge._tcp；开启后按需广域扫描更多设备类型，可能增加网络唤醒与能耗")
 // 是否启用 companion‑link（Apple 连续互通）
                Toggle("启用 Companion Link", isOn: $settingsManager.enableCompanionLink)
                    .help("扫描 _companion-link._tcp 服务类型，发现Apple连续互通设备")

                Picker("日志级别", selection: $settingsManager.logLevel) {
                    Text("错误").tag("Error")
                    Text("警告").tag("Warning")
                    Text("信息").tag("Info")
                    Text("调试").tag("Debug")
                }
                .help("设置日志记录的详细程度")
            }

            Section("性能优化") {
 // 实时FPS显示开关（性能监控相关，放置于性能优化分组，位置更直观）
                Toggle("显示实时FPS", isOn: $settingsManager.showRealtimeFPS)
                    .help("在顶部导航显示Metal渲染FPS；无数据时显示占位字符 — FPS")
                Toggle("启用硬件加速", isOn: $settingsManager.enableHardwareAcceleration)
                    .help("使用硬件加速提升性能")

                Toggle("优化内存使用", isOn: $settingsManager.optimizeMemoryUsage)
                    .help("启用内存使用优化")

                Stepper("最大并发连接: \(settingsManager.maxConcurrentConnections)",
                       value: $settingsManager.maxConcurrentConnections,
                       in: 1...50)
                    .help("同时允许的最大连接数")
            }

            Section("天气效果") {
                Toggle("实时天气API", isOn: $settingsManager.enableRealTimeWeather)
                    .help("启用实时天气API和动态天气粒子效果（雨、雪、雾霾等）")
                    .onChange(of: settingsManager.enableRealTimeWeather) { _, newValue in
                    }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("开关状态:")
                        Spacer()
                        Text(settingsManager.enableRealTimeWeather ? "✅ 开启" : "❌ 关闭")
                            .foregroundColor(settingsManager.enableRealTimeWeather ? .green : .red)
                    }
                    .font(.caption)

                    HStack {
                        Text("天气系统:")
                        Spacer()
                        Text(weatherManager.isInitialized ? "✅ 已初始化" : "⏳ 未初始化")
                            .foregroundColor(weatherManager.isInitialized ? .green : .orange)
                    }
                    .font(.caption)

                    if settingsManager.enableRealTimeWeather {
                        HStack {
                            Text("当前天气:")
                            Spacer()
                            if let weather = weatherManager.currentWeather {
                                Label(weather.condition.rawValue, systemImage: weather.condition.iconName)
                                    .foregroundColor(.primary)
                            } else {
                                Text("⏳ 等待数据...")
                                    .foregroundColor(.orange)
                            }
                        }
                        .font(.caption)

                        HStack {
                            Text("主题:")
                            Spacer()
                            Text(weatherManager.currentTheme.condition.rawValue)
                                .foregroundColor(.secondary)
                        }
                        .font(.caption)
                    } else {
                        Text("天气效果已关闭")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if let error = weatherManager.error {
                        Text("错误: \(error)")
                            .font(.caption)
                            .foregroundColor(.red)
                    }

                    HStack(spacing: 8) {
                        Button("刷新天气") {
                            Task {
                                await weatherManager.refresh()
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(!weatherSettings.isEnabled)

                        if !weatherManager.isInitialized {
                            Button("启动天气系统") {
                                Task {
                                    await weatherManager.start()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Section("SSH 主机密钥") {
                Toggle("首次信任主机密钥（TOFU）", isOn: $trustOnFirstUse)
                    .help("首次连接未知主机时自动记录主机密钥指纹；关闭后将拒绝未知主机")

                HStack {
                    Button("导入 known-hosts") {
                        showingKnownHostsImporter = true
                    }
                    Button("刷新列表") {
                        reloadKnownHosts()
                    }
                    Button("清空已信任主机") {
                        SSHKnownHostsStore.shared.removeAll()
                        knownHostsMessage = "已清空所有主机密钥"
                        reloadKnownHosts()
                    }
                }

                if let message = knownHostsMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if knownHosts.isEmpty {
                    Text("暂无已信任的主机密钥")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(knownHosts) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(entry.host):\(entry.port)")
                                        .font(.subheadline)
                                    Text("\(entry.keyType)  \(entry.fingerprint)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Button("删除") {
                                    SSHKnownHostsStore.shared.remove(entry: entry)
                                    knownHostsMessage = "已删除 \(entry.host):\(entry.port)"
                                    reloadKnownHosts()
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
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

 // MARK: - 关于
            Section("关于 SkyBridge Compass Pro") {
                VStack(alignment: .leading, spacing: 16) {
 // 应用信息卡片
                    AboutInfoCard(
                        icon: "app.badge",
                        title: "应用信息",
                        items: [
                            ("名称", "SkyBridge Compass Pro"),
                            ("版本", "1.0.0 (Build 2025.10.31)"),
                            ("开发商", "SkyBridge Team"),
                            ("类别", "远程桌面 / 生产力工具")
                        ]
                    )

 // 系统要求卡片
                    AboutInfoCard(
                        icon: "cpu",
                        title: "系统要求",
                        items: [
                            ("处理器", "Apple Silicon (M1-M5)"),
                            ("系统版本", "macOS 14.0 或更高"),
                            ("内存", "8GB RAM（推荐 16GB）"),
                            ("存储", "500MB 可用空间")
                        ]
                    )

 // 技术亮点
                    AboutInfoCard(
                        icon: "sparkles",
                        title: "核心技术",
                        items: [
                            ("渲染引擎", "Metal 4 + MetalFX"),
                            ("视频编码", "VideoToolbox (HEVC/ProRes)"),
                            ("网络协议", "QUIC / HTTP/3"),
                            ("AI 加速", "Neural Engine / CoreML")
                        ]
                    )

                    Divider()

 // 链接和联系方式
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "link")
                                .foregroundColor(.blue)
                            Link("官方网站", destination: URL(string: "https://skybridge-compass.vercel.app")!)
                        }

                        HStack {
                            Image(systemName: "envelope")
                                .foregroundColor(.blue)
                            Text("2403871950@qq.com")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }

                        HStack {
                            Image(systemName: "doc.text")
                                .foregroundColor(.blue)
                            Link("隐私政策", destination: URL(string: "https://skybridge-compass.vercel.app/privacy")!)
                        }

                        HStack {
                            Image(systemName: "checkmark.shield")
                                .foregroundColor(.blue)
                            Link("使用条款", destination: URL(string: "https://skybridge-compass.vercel.app/terms")!)
                        }
                    }
                    .font(.caption)

                    Divider()

 // 版权信息
                    VStack(alignment: .leading, spacing: 4) {
                        Text("© 2024-2025 SkyBridge Team. All rights reserved.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Text("专为 Apple Silicon 优化 • 采用 Swift 6.2 构建")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 8)
            }
            }
            .formStyle(.grouped)
        }
        .onAppear {
            reloadKnownHosts()
        }
        .fileImporter(
            isPresented: $showingKnownHostsImporter,
            allowedContentTypes: [.plainText, .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                importKnownHosts(from: url)
            case .failure(let error):
                knownHostsMessage = "导入失败：\(error.localizedDescription)"
            }
        }
        .padding()
    }

    private func reloadKnownHosts() {
        knownHosts = SSHKnownHostsStore.shared.allEntries()
    }

    private func importKnownHosts(from url: URL) {
        do {
            let result = try SSHKnownHostsStore.shared.importKnownHostsFile(from: url)
            knownHostsMessage = "导入完成：新增 \(result.added) 条，跳过 \(result.skipped) 条"
            reloadKnownHosts()
        } catch {
            knownHostsMessage = "导入失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 关于信息卡片组件
struct AboutInfoCard: View {
    let icon: String
    let title: String
    let items: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
 // 统一改用通用符号视图，并保持原有半粗样式
                SystemSymbolIcon(name: icon,
                                  color: .blue,
                                  size: 16,
                                  weight: .semibold)
                Text(title)
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(items, id: \.0) { item in
                    HStack {
                        Text(item.0 + ":")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 80, alignment: .leading)
                        Text(item.1)
                            .font(.caption)
                            .foregroundColor(.primary)
                        Spacer()
                    }
                }
            }
            .padding(.leading, 24)
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }
}

// MARK: - 关于偏好设置视图
struct AboutPreferencesView: View {
    @State private var selectedSection: AboutSection = .app
    @State private var copiedToClipboard = false

    enum AboutSection: String, CaseIterable {
        case app = "应用信息"
        case system = "系统要求"
        case version = "版本历史"
        case tech = "技术栈"
        case license = "开源许可"
        case credits = "贡献者"

        var icon: String {
            switch self {
            case .app: return "app.badge"
            case .system: return "laptopcomputer"
            case .version: return "clock.arrow.circlepath"
            case .tech: return "cpu"
            case .license: return "doc.text"
            case .credits: return "person.3"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
 // 左侧导航栏
            VStack(alignment: .leading, spacing: 4) {
                ForEach(AboutSection.allCases, id: \.self) { section in
                    Button(action: {
                        selectedSection = section
                    }) {
                        HStack {
 // 左侧导航同样采用通用符号视图，保持样式稳定
                            SystemSymbolIcon(name: section.icon,
                                              size: 14,
                                              weight: .regular)
                                .frame(width: 20)
                            Text(section.rawValue)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(selectedSection == section ? Color.accentColor.opacity(0.2) : Color.clear)
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }
            .frame(width: 150)
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))

            Divider()

 // 右侧内容区
            ScrollView {
                contentView
                    .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch selectedSection {
        case .app:
            appInfoView
        case .system:
            systemRequirementsView
        case .version:
            versionHistoryView
        case .tech:
            techStackView
        case .license:
            licensesView
        case .credits:
            creditsView
        }
    }

 // MARK: - 应用信息
    private var appInfoView: some View {
        VStack(alignment: .center, spacing: 20) {
 // 应用图标
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [.blue, .cyan],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 120, height: 120)

                Image(systemName: "globe.americas.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.white)
            }
            .shadow(color: .blue.opacity(0.3), radius: 20, y: 10)

 // 应用名称和版本
            VStack(spacing: 8) {
                Text("SkyBridge Compass Pro")
                    .font(.system(size: 28, weight: .bold))

                Text("版本 1.0.0 (Build 2025.10.31)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Text("专为 Apple Silicon 优化")
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.1))
                    .foregroundColor(.blue)
                    .cornerRadius(12)
            }

            Divider()
                .padding(.vertical, 8)

 // 应用描述
            VStack(alignment: .leading, spacing: 12) {
                Text("革命性的远程桌面应用")
                    .font(.headline)

                Text("SkyBridge Compass Pro 是专为 Apple Silicon (M1-M5) 设计的下一代远程桌面解决方案，采用 2025 年最新 Apple 技术，提供硬件级画质和近距离低延迟体验。")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

 // 核心特性
            VStack(alignment: .leading, spacing: 12) {
                Text("核心特性")
                    .font(.headline)

                FeatureRow(icon: "bolt.fill", title: "Metal 4 增强渲染", color: .orange)
                FeatureRow(icon: "brain", title: "Neural Engine 加速", color: .purple)
                FeatureRow(icon: "video.fill", title: "ProRes 硬件编码", color: .red)
                FeatureRow(icon: "wifi.circle.fill", title: "QUIC 低延迟传输", color: .blue)
                FeatureRow(icon: "wand.and.stars", title: "MetalFX 超分辨率", color: .pink)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()
                .padding(.vertical, 8)

 // 版权信息
            VStack(spacing: 8) {
                Text("© 2024-2025 SkyBridge Team")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("保留所有权利 All Rights Reserved")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

 // 操作按钮
            HStack(spacing: 12) {
                Button("访问官网") {
                    if let url = URL(string: "https://skybridge-compass.vercel.app") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)

                Button("用户手册") {
                    if let url = URL(string: "https://skybridge-compass.vercel.app/docs") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)

                Button("技术支持") {
                    if let url = URL(string: "https://skybridge-compass.vercel.app/support") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: 400)
    }

 // MARK: - 系统要求
    private var systemRequirementsView: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("系统要求")
                .font(.title2)
                .fontWeight(.bold)

 // 最低要求
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("最低要求")
                        .font(.headline)
                        .foregroundColor(.orange)

                    RequirementRow(icon: "cpu", title: "处理器", requirement: "Apple M1 或更新", met: true)
                    RequirementRow(icon: "memorychip", title: "内存", requirement: "8 GB", met: true)
                    RequirementRow(icon: "internaldrive", title: "存储空间", requirement: "500 MB 可用空间", met: true)
                    RequirementRow(icon: "macwindow", title: "操作系统", requirement: "macOS 14.0 (Sonoma) 或更新", met: true)
                    RequirementRow(icon: "display", title: "显示器", requirement: "1280 x 720 或更高分辨率", met: true)
                }
                .padding()
            }

 // 推荐配置
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("推荐配置")
                        .font(.headline)
                        .foregroundColor(.green)

                    RequirementRow(icon: "cpu", title: "处理器", requirement: "Apple M3 Pro/Max/Ultra", met: true)
                    RequirementRow(icon: "memorychip", title: "内存", requirement: "16 GB 或更多", met: false)
                    RequirementRow(icon: "internaldrive", title: "存储空间", requirement: "2 GB 可用空间（用于缓存）", met: true)
                    RequirementRow(icon: "macwindow", title: "操作系统", requirement: "macOS 14.0 或更高", met: true)
                    RequirementRow(icon: "display", title: "显示器", requirement: "2560 x 1440 (Retina) 或 4K", met: false)
                    RequirementRow(icon: "wifi", title: "网络", requirement: "Wi-Fi 6E (802.11ax)", met: false)
                }
                .padding()
            }

 // 支持的芯片
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("支持的 Apple Silicon 芯片")
                        .font(.headline)

                    HStack(spacing: 8) {
                        ChipBadge(name: "M1", color: .blue)
                        ChipBadge(name: "M1 Pro", color: .blue)
                        ChipBadge(name: "M1 Max", color: .blue)
                        ChipBadge(name: "M1 Ultra", color: .blue)
                    }

                    HStack(spacing: 8) {
                        ChipBadge(name: "M2", color: .purple)
                        ChipBadge(name: "M2 Pro", color: .purple)
                        ChipBadge(name: "M2 Max", color: .purple)
                        ChipBadge(name: "M2 Ultra", color: .purple)
                    }

                    HStack(spacing: 8) {
                        ChipBadge(name: "M3", color: .pink)
                        ChipBadge(name: "M3 Pro", color: .pink)
                        ChipBadge(name: "M3 Max", color: .pink)
                        ChipBadge(name: "M3 Ultra", color: .pink)
                    }

                    HStack(spacing: 8) {
                        ChipBadge(name: "M4", color: .orange)
                        ChipBadge(name: "M4 Pro", color: .orange)
                        ChipBadge(name: "M4 Max", color: .orange)
                        ChipBadge(name: "M4 Ultra", color: .orange)
                    }

                    HStack(spacing: 8) {
                        ChipBadge(name: "M5", color: .green)
                        ChipBadge(name: "M5 Pro", color: .green)
                        ChipBadge(name: "M5 Max", color: .green)
                        ChipBadge(name: "M5 Ultra", color: .green)
                    }
                }
                .padding()
            }

 // 注意事项
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.yellow)
                        Text("重要提示")
                            .font(.headline)
                    }

                    Text("• 本应用专为 Apple Silicon Mac 设计，充分利用 M 系列芯片性能")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("• ProRes 编码功能需要 M3 Pro/Max/Ultra 或更新芯片")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("• 推荐使用 macOS 15.0 或更新以获得最佳体验")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
            }
        }
    }

 // MARK: - 版本历史
    private var versionHistoryView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("版本历史")
                .font(.title2)
                .fontWeight(.bold)

            VersionCard(
                version: "1.0.0",
                date: "2025-10-31",
                type: .major,
                changes: [
                    "🎉 首次发布",
                    "🚀 Metal 4 + MetalFX 渲染引擎",
                    "🧠 Neural Engine 视频增强",
                    "📡 多服务类型设备发现",
                    "🪟 macOS 14+ 窗口管理最佳实践",
                    "⚡ Wi-Fi 6E 低延迟传输",
                    "🔒 量子安全加密",
                    "🎨 Liquid Glass 设计语言"
                ]
            )
        }
    }

 // MARK: - 技术栈
    private var techStackView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("技术栈")
                .font(.title2)
                .fontWeight(.bold)

            Text("SkyBridge Compass Pro 采用最新的 Apple 技术构建")
                .foregroundColor(.secondary)

 // 核心框架
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("核心框架")
                        .font(.headline)

                    TechRow(icon: "swift", name: "Swift 6.2", description: "并发安全、现代化语法")
                    TechRow(icon: "swiftui", name: "SwiftUI", description: "声明式 UI 框架")
                    TechRow(icon: "apple.logo", name: "Metal 4", description: "高性能图形渲染")
                    TechRow(icon: "cube.transparent", name: "MetalFX", description: "帧插值和超分辨率")
                }
                .padding()
            }

 // 多媒体
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("多媒体处理")
                        .font(.headline)

                    TechRow(icon: "video", name: "VideoToolbox", description: "硬件视频编解码")
                    TechRow(icon: "waveform", name: "AVFoundation", description: "音视频框架")
                    TechRow(icon: "camera.aperture", name: "ScreenCaptureKit", description: "高性能屏幕捕获")
                    TechRow(icon: "film", name: "ProRes", description: "专业级视频编码 (M3+)")
                }
                .padding()
            }

 // 网络
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("网络通信")
                        .font(.headline)

                    TechRow(icon: "network", name: "Network.framework", description: "现代网络 API")
                    TechRow(icon: "bolt.horizontal", name: "QUIC", description: "低延迟传输协议")
                    TechRow(icon: "antenna.radiowaves.left.and.right", name: "Bonjour/mDNS", description: "设备发现")
                    TechRow(icon: "wifi", name: "Wi-Fi 6E", description: "6GHz 低延迟")
                }
                .padding()
            }

 // AI 和机器学习
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("AI 和机器学习")
                        .font(.headline)

                    TechRow(icon: "brain", name: "CoreML", description: "机器学习模型")
                    TechRow(icon: "cpu", name: "Neural Engine", description: "ANE 加速推理")
                    TechRow(icon: "sparkles", name: "Vision", description: "图像分析")
                    TechRow(icon: "doc.text.magnifyingglass", name: "Natural Language", description: "文本处理")
                }
                .padding()
            }

 // 安全
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("安全和加密")
                        .font(.headline)

                    TechRow(icon: "lock.shield", name: "CryptoKit", description: "现代加密 API")
                    TechRow(icon: "key", name: "Keychain", description: "安全凭证存储")
                    TechRow(icon: "checkmark.seal", name: "Code Signing", description: "代码签名验证")
                    TechRow(icon: "shield.lefthalf.filled", name: "Quantum-Safe", description: "量子安全算法")
                }
                .padding()
            }
        }
    }

 // MARK: - 开源许可
    private var licensesView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("开源许可证")
                .font(.title2)
                .fontWeight(.bold)

            Text("本应用使用以下开源组件")
                .foregroundColor(.secondary)

            LicenseCard(
                name: "FreeRDP",
                version: "3.0+",
                license: "Apache License 2.0",
                description: "远程桌面协议实现",
                url: "https://github.com/FreeRDP/FreeRDP"
            )

            LicenseCard(
 // 说明：迁移到 Apple 原生 Network.framework 的 WebSocket 实现，替换第三方 Starscream
 // 原因：提升性能与系统集成度，遵循 macOS 14+ 最新 API，便于严格并发控制
                name: "Network.framework (WebSocket)",
                version: "macOS 14+",
                license: "Apple SDK",
                description: "原生 WebSocket 客户端 (NWProtocolWebSocket)",
                url: "https://developer.apple.com/documentation/network/nwprotocolwebsocket"
            )

            LicenseCard(
                name: "SwiftUI NavigationSplitView",
                version: "Internal",
                license: "Apple SDK",
                description: "Apple 原生组件",
                url: nil
            )

            Divider()

            Text("完整许可证信息")
                .font(.headline)

            ScrollView {
                Text("""
                MIT License

                Copyright (c) 2024-2025 SkyBridge Team

                Permission is hereby granted, free of charge, to any person obtaining a copy
                of this software and associated documentation files (the "Software"), to deal
                in the Software without restriction, including without limitation the rights
                to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
                copies of the Software, and to permit persons to whom the Software is
                furnished to do so, subject to the following conditions:

                The above copyright notice and this permission notice shall be included in all
                copies or substantial portions of the Software.

                THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
                IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
                FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
                AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
                LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
                OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
                SOFTWARE.
                """)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .padding()
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(8)
            }
            .frame(height: 200)
        }
    }

 // MARK: - 贡献者
    private var creditsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("贡献者")
                .font(.title2)
                .fontWeight(.bold)

            Text("感谢以下开发者和贡献者")
                .foregroundColor(.secondary)

 // 核心团队
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("核心团队")
                        .font(.headline)

                    ContributorRow(
                        name: "主架构师",
                        role: "Metal 4 渲染引擎、核心架构设计",
                        avatar: "person.circle.fill",
                        color: .blue
                    )

                    ContributorRow(
                        name: "网络工程师",
                        role: "QUIC 传输、设备发现优化",
                        avatar: "network",
                        color: .green
                    )

                    ContributorRow(
                        name: "UI/UX 设计师",
                        role: "界面设计、用户体验优化",
                        avatar: "paintbrush.fill",
                        color: .purple
                    )
                }
                .padding()
            }

 // 特别感谢
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("特别感谢")
                        .font(.headline)

                    Text("• Apple - 提供优秀的开发工具和框架")
                    Text("• FreeRDP 社区 - 开源 RDP 协议实现")
                    Text("• 所有测试人员和早期用户")
                    Text("• 开源社区的贡献者们")
                }
                .font(.body)
                .foregroundColor(.secondary)
                .padding()
            }

 // 联系方式
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("联系我们")
                        .font(.headline)

                    HStack {
                        Image(systemName: "envelope.fill")
                            .foregroundColor(.blue)
                        Text("2403871950@qq.com")
                            .textSelection(.enabled)

                        Spacer()

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("2403871950@qq.com", forType: .string)
                            copiedToClipboard = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                copiedToClipboard = false
                            }
                        } label: {
                            Image(systemName: copiedToClipboard ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                    }

                    HStack {
                        Image(systemName: "globe")
                            .foregroundColor(.blue)
                        Link("https://skybridge-compass.vercel.app", destination: URL(string: "https://skybridge-compass.vercel.app")!)
                    }

                    HStack {
                        Image(systemName: "message.fill")
                            .foregroundColor(.blue)
                        Link("GitHub Discussions", destination: URL(string: "https://github.com/AuroraEchos/SkyBridge-Compass/discussions")!)
                    }
                }
                .padding()
            }
        }
    }
}

// MARK: - 辅助视图组件

struct FeatureRow: View {
    let icon: String
    let title: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
 // 功能项采用通用符号视图，确保符号在不同系统下稳定显示
            SystemSymbolIcon(name: icon,
                              color: color,
                              size: 16,
                              weight: .regular)
                .frame(width: 24)

            Text(title)
                .font(.body)

            Spacer()
        }
    }
}

struct RequirementRow: View {
    let icon: String
    let title: String
    let requirement: String
    let met: Bool

    var body: some View {
        HStack(spacing: 12) {
 // 要求项采用通用符号视图，实现全局一致的兜底策略
            SystemSymbolIcon(name: icon,
                              color: .secondary,
                              size: 16,
                              weight: .regular)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text(requirement)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Image(systemName: met ? "checkmark.circle.fill" : "circle")
                .foregroundColor(met ? .green : .secondary)
        }
    }
}

struct ChipBadge: View {
    let name: String
    let color: Color

    var body: some View {
        Text(name)
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(0.2))
            .foregroundColor(color)
            .cornerRadius(8)
    }
}

struct VersionCard: View {
    let version: String
    let date: String
    let type: VersionType
    let changes: [String]

    enum VersionType {
        case major, minor, patch

        var badge: (String, Color) {
            switch self {
            case .major: return ("重大更新", .red)
            case .minor: return ("功能更新", .orange)
            case .patch: return ("修复更新", .blue)
            }
        }
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("v\(version)")
                        .font(.title3)
                        .fontWeight(.bold)

                    Text(type.badge.0)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(type.badge.1.opacity(0.2))
                        .foregroundColor(type.badge.1)
                        .cornerRadius(4)

                    Spacer()

                    Text(date)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Divider()

                ForEach(changes, id: \.self) { change in
                    Text(change)
                        .font(.body)
                }
            }
            .padding()
        }
    }
}

struct TechRow: View {
    let icon: String
    let name: String
    let description: String

    var body: some View {
        HStack(spacing: 12) {
 // 技术项采用通用符号视图，保证图标可用性与风格统一
            SystemSymbolIcon(name: icon,
                              color: .blue,
                              size: 16,
                              weight: .regular)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
    }
}

struct LicenseCard: View {
    let name: String
    let version: String
    let license: String
    let description: String
    let url: String?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(name)
                        .font(.headline)

                    Spacer()

                    Text(version)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.2))
                        .cornerRadius(4)
                }

                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack {
                    Text("许可证: \(license)")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if let url = url {
                        Spacer()
                        Link("查看源码", destination: URL(string: url)!)
                            .font(.caption)
                    }
                }
            }
            .padding()
        }
    }
}

struct ContributorRow: View {
    let name: String
    let role: String
    let avatar: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
 // 贡献者头像采用通用符号视图，避免可用性差异导致的缺失
            SystemSymbolIcon(name: avatar,
                              color: color,
                              size: 20,
                              weight: .regular)
                .frame(width: 40, height: 40)
                .background(color.opacity(0.1))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text(role)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
    }
}
