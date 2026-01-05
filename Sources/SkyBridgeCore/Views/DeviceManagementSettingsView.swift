import SwiftUI
import Foundation

/// 设备管理设置视图
/// 提供设备扫描、显示、连接等相关设置的统一管理界面
public struct DeviceManagementSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var settingsManager = DeviceManagementSettingsManager.shared
    
 // 设置标签页枚举
    private enum SettingsTab: String, CaseIterable {
        case scanning = "扫描设置"
        case display = "显示设置"
        case connection = "连接设置"
        case permissions = "权限管理"
        case advanced = "高级设置"
        
        var iconName: String {
            switch self {
            case .scanning:
                return "magnifyingglass"
            case .display:
                return "eye"
            case .connection:
                return "network"
            case .permissions:
                return "lock.shield"
            case .advanced:
                return "gearshape.2"
            }
        }
    }
    
    @State private var selectedTab: SettingsTab = .scanning
    
    public var body: some View {
        NavigationView {
 // 侧边栏
            List(SettingsTab.allCases, id: \.self, selection: $selectedTab) { tab in
                Label(tab.rawValue, systemImage: tab.iconName)
                    .tag(tab)
            }
            .listStyle(SidebarListStyle())
            .frame(minWidth: 200)
            
 // 主内容区域
            Group {
                switch selectedTab {
                case .scanning:
                    ScanningSettingsView()
                case .display:
                    DisplaySettingsView()
                case .connection:
                    ConnectionSettingsView()
                case .permissions:
                    PermissionsSettingsView()
                case .advanced:
                    AdvancedSettingsView()
                }
            }
            .frame(minWidth: 500, minHeight: 400)
        }
        .navigationTitle("设备管理设置")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") {
                    dismiss()
                }
            }
            
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") {
                    settingsManager.saveSettings()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(width: 800, height: 600)
    }
}

// MARK: - 扫描设置视图
private struct ScanningSettingsView: View {
    @StateObject private var settingsManager = DeviceManagementSettingsManager.shared
    
    var body: some View {
        Form {
            Section("WiFi扫描设置") {
                HStack {
                    Text("扫描间隔")
                    Spacer()
                    Stepper(value: $settingsManager.wifiScanInterval, in: 1...60, step: 1) {
                        Text("\(settingsManager.wifiScanInterval, specifier: "%.0f")秒")
                            .frame(width: 60, alignment: .trailing)
                    }
                }
                
                HStack {
                    Text("扫描超时")
                    Spacer()
                    Stepper(value: $settingsManager.wifiScanTimeout, in: 5...120, step: 5) {
                        Text("\(settingsManager.wifiScanTimeout, specifier: "%.0f")秒")
                            .frame(width: 60, alignment: .trailing)
                    }
                }
                
                Toggle("自动扫描", isOn: $settingsManager.autoScanWiFi)
                    .help("应用启动时自动开始WiFi扫描")
            }
            
            Section("蓝牙扫描设置") {
                HStack {
                    Text("扫描间隔")
                    Spacer()
                    Stepper(value: $settingsManager.bluetoothScanInterval, in: 1...60, step: 1) {
                        Text("\(settingsManager.bluetoothScanInterval, specifier: "%.0f")秒")
                            .frame(width: 60, alignment: .trailing)
                    }
                }
                
                HStack {
                    Text("扫描超时")
                    Spacer()
                    Stepper(value: $settingsManager.bluetoothScanTimeout, in: 5...120, step: 5) {
                        Text("\(settingsManager.bluetoothScanTimeout, specifier: "%.0f")秒")
                            .frame(width: 60, alignment: .trailing)
                    }
                }
                
                Toggle("自动扫描", isOn: $settingsManager.autoScanBluetooth)
                    .help("应用启动时自动开始蓝牙扫描")
                
                Toggle("扫描低功耗设备", isOn: $settingsManager.scanBLEDevices)
                    .help("包含蓝牙低功耗(BLE)设备")
            }
            
            Section("AirPlay扫描设置") {
                HStack {
                    Text("扫描间隔")
                    Spacer()
                    Stepper(value: $settingsManager.airplayScanInterval, in: 1...60, step: 1) {
                        Text("\(settingsManager.airplayScanInterval, specifier: "%.0f")秒")
                            .frame(width: 60, alignment: .trailing)
                    }
                }
                
                Toggle("自动扫描", isOn: $settingsManager.autoScanAirPlay)
                    .help("应用启动时自动开始AirPlay扫描")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("扫描设置")
    }
}

// MARK: - 显示设置视图
private struct DisplaySettingsView: View {
    @StateObject private var settingsManager = DeviceManagementSettingsManager.shared
    
    var body: some View {
        Form {
            Section("设备列表显示") {
                Toggle("显示离线设备", isOn: $settingsManager.showOfflineDevices)
                    .help("在设备列表中显示已断开连接的设备")
                
                Toggle("显示信号强度", isOn: $settingsManager.showSignalStrength)
                    .help("显示WiFi和蓝牙设备的信号强度指示器")
                
                Toggle("显示设备图标", isOn: $settingsManager.showDeviceIcons)
                    .help("在设备列表中显示设备类型图标")
                
                HStack {
                    Text("列表刷新间隔")
                    Spacer()
                    Stepper(value: $settingsManager.listRefreshInterval, in: 1...30, step: 1) {
                        Text("\(settingsManager.listRefreshInterval, specifier: "%.0f")秒")
                            .frame(width: 60, alignment: .trailing)
                    }
                }
            }
            
            Section("设备信息显示") {
                Toggle("显示MAC地址", isOn: $settingsManager.showMACAddress)
                    .help("在设备详情中显示MAC地址")
                
                Toggle("显示制造商信息", isOn: $settingsManager.showManufacturer)
                    .help("显示设备制造商信息（如果可用）")
                
                Toggle("显示最后发现时间", isOn: $settingsManager.showLastSeen)
                    .help("显示设备最后一次被发现的时间")
            }
            
            Section("排序和过滤") {
                Picker("默认排序方式", selection: $settingsManager.defaultSortOption) {
                    Text("名称").tag("name")
                    Text("信号强度").tag("signalStrength")
                    Text("最近发现").tag("lastSeen")
                    Text("设备类型").tag("deviceType")
                }
                .pickerStyle(MenuPickerStyle())
                
                Toggle("记住过滤设置", isOn: $settingsManager.rememberFilterSettings)
                    .help("应用重启时保持上次的过滤设置")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("显示设置")
    }
}

// MARK: - 连接设置视图
private struct ConnectionSettingsView: View {
    @StateObject private var settingsManager = DeviceManagementSettingsManager.shared
    
    var body: some View {
        Form {
            Section("连接行为") {
                HStack {
                    Text("连接超时")
                    Spacer()
                    Stepper(value: $settingsManager.connectionTimeout, in: 5...120, step: 5) {
                        Text("\(settingsManager.connectionTimeout, specifier: "%.0f")秒")
                            .frame(width: 60, alignment: .trailing)
                    }
                }
                
                HStack {
                    Text("重试次数")
                    Spacer()
                    Stepper(value: $settingsManager.connectionRetryCount, in: 0...10, step: 1) {
                        Text("\(settingsManager.connectionRetryCount, specifier: "%.0f")次")
                            .frame(width: 60, alignment: .trailing)
                    }
                }
                
                Toggle("自动重连", isOn: $settingsManager.autoReconnect)
                    .help("连接断开时自动尝试重新连接")
            }
            
            Section("WiFi连接") {
                Toggle("记住WiFi密码", isOn: $settingsManager.rememberWiFiPasswords)
                    .help("在钥匙串中保存WiFi网络密码")
                
                Toggle("优先连接已知网络", isOn: $settingsManager.preferKnownNetworks)
                    .help("优先连接之前连接过的WiFi网络")
            }
            
            Section("蓝牙连接") {
                Toggle("自动配对", isOn: $settingsManager.autoBluetoothPairing)
                    .help("自动接受蓝牙设备的配对请求")
                
                Toggle("连接后保持活跃", isOn: $settingsManager.keepBluetoothActive)
                    .help("连接蓝牙设备后保持连接活跃状态")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("连接设置")
    }
}

// MARK: - 权限管理视图
private struct PermissionsSettingsView: View {
    @StateObject private var permissionManager = DevicePermissionManager()
    
    var body: some View {
        Form {
            Section("系统权限状态") {
                ForEach(permissionManager.permissions) { permission in
                    PermissionStatusRow(
                        title: permission.type.description,
                        description: permission.description,
                        status: permission.status,
                        action: {
                            Task {
                                await permissionManager.requestPermission(for: permission.type)
                            }
                        }
                    )
                }
            }
            
            Section("权限管理") {
                Button("打开系统偏好设置") {
                    openSystemPreferences()
                }
                .buttonStyle(.bordered)
                
                Button("重新检查权限") {
                    permissionManager.checkAllPermissions()
                }
                .buttonStyle(.bordered)
                
                Button("请求所有必需权限") {
                    Task {
                        await permissionManager.requestAllRequiredPermissions()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(permissionManager.allRequiredPermissionsGranted)
            }
            
            if !permissionManager.unauthorizedRequiredPermissions.isEmpty {
                Section("需要授权的权限") {
                    ForEach(permissionManager.unauthorizedRequiredPermissions) { permission in
                        HStack {
 // 使用通用符号视图，避免在权限提示中出现图标缺失
                            SystemSymbolIcon(name: permission.type.iconName, color: .orange, size: 16)
                            
                            VStack(alignment: .leading) {
                                Text(permission.type.description)
                                    .font(.headline)
                                Text(permissionManager.suggestion(for: permission.type))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Button("授权") {
                                Task {
                                    await permissionManager.requestPermission(for: permission.type)
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
        .navigationTitle("权限管理")
        .onAppear {
            permissionManager.checkAllPermissions()
        }
    }
    
 /// 打开系统偏好设置
    private func openSystemPreferences() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!
        NSWorkspace.shared.open(url)
    }
}

// MARK: - 权限状态行视图
private struct PermissionStatusRow: View {
    let title: String
    let description: String
    let status: PermissionStatus
    let action: () -> Void
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            HStack {
                statusIndicator
                
                if status != .authorized {
                    Button("授权") {
                        action()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 4)
    }
    
    @ViewBuilder
    private var statusIndicator: some View {
        switch status {
        case .authorized:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .denied, .restricted:
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(.red)
        case .notDetermined:
            Image(systemName: "questionmark.circle.fill")
                .foregroundColor(.orange)
        case .unavailable:
            Image(systemName: "minus.circle.fill")
                .foregroundColor(.gray)
        }
    }
}

// MARK: - 高级设置视图
private struct AdvancedSettingsView: View {
    @StateObject private var settingsManager = DeviceManagementSettingsManager.shared
    
    var body: some View {
        Form {
            Section("性能设置") {
                HStack {
                    Text("最大设备缓存数")
                    Spacer()
                    Stepper(value: $settingsManager.maxDeviceCache, in: 50...1000, step: 50) {
                        Text("\(settingsManager.maxDeviceCache, specifier: "%.0f")")
                            .frame(width: 60, alignment: .trailing)
                    }
                }
                
                HStack {
                    Text("缓存清理间隔")
                    Spacer()
                    Stepper(value: $settingsManager.cacheCleanupInterval, in: 1...24, step: 1) {
                        Text("\(settingsManager.cacheCleanupInterval, specifier: "%.0f")小时")
                            .frame(width: 80, alignment: .trailing)
                    }
                }
                
                Toggle("启用性能监控", isOn: $settingsManager.enablePerformanceMonitoring)
                    .help("监控扫描性能并记录统计信息")
            }
            
            Section("日志设置") {
                Picker("日志级别", selection: $settingsManager.logLevel) {
                    Text("关闭").tag("off")
                    Text("错误").tag("error")
                    Text("警告").tag("warning")
                    Text("信息").tag("info")
                    Text("调试").tag("debug")
                }
                .pickerStyle(MenuPickerStyle())
                
                Toggle("保存日志到文件", isOn: $settingsManager.saveLogsToFile)
                    .help("将日志保存到应用程序支持目录")
                
                HStack {
                    Text("日志文件保留天数")
                    Spacer()
                    Stepper(value: $settingsManager.logRetentionDays, in: 1...30, step: 1) {
                        Text("\(settingsManager.logRetentionDays, specifier: "%.0f")天")
                            .frame(width: 60, alignment: .trailing)
                    }
                }
            }
            
            Section("数据管理") {
                Button("清除设备缓存") {
                    settingsManager.clearDeviceCache()
                }
                .buttonStyle(.bordered)
                
                Button("重置所有设置") {
                    settingsManager.resetToDefaults()
                }
                .buttonStyle(.bordered)
                .foregroundColor(.red)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("高级设置")
    }
}

// MARK: - 预览
struct DeviceManagementSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        DeviceManagementSettingsView()
    }
}