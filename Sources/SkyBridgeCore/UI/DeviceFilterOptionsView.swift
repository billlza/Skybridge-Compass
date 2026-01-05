import SwiftUI

/// 设备过滤选项视图 - 允许用户配置设备显示偏好
struct DeviceFilterOptionsView: View {
    @ObservedObject var filterManager: DeviceFilterManager
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 20) {
 // 标题说明
                VStack(alignment: .leading, spacing: 8) {
                    Text("设备显示设置")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Text("配置哪些类型的设备需要显示或隐藏")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
                
                Divider()
                
 // 设备类型过滤选项
                VStack(alignment: .leading, spacing: 16) {
                    Text("设备类型显示")
                        .font(.headline)
                    
                    ForEach(DeviceClassifier.DeviceType.allCases, id: \.self) { deviceType in
                        if deviceType != .unknown {
                            DeviceTypeToggleRow(
                                deviceType: deviceType,
                                isVisible: !filterManager.filterSettings.hiddenDeviceTypes.contains(deviceType),
                                onToggle: { isVisible in
                                    if isVisible {
                                        filterManager.showDeviceType(deviceType)
                                    } else {
                                        filterManager.hideDeviceType(deviceType)
                                    }
                                }
                            )
                        }
                    }
                }
                
                Divider()
                
 // 默认展开设置
                VStack(alignment: .leading, spacing: 16) {
                    Text("默认展开设置")
                        .font(.headline)
                    
                    Toggle("计算机设备默认展开", isOn: Binding(
                        get: { !filterManager.filterSettings.autoCollapseNonConnectable },
                        set: { isOn in
                            filterManager.filterSettings.autoCollapseNonConnectable = !isOn
                            filterManager.saveUserPreferences()
                        }
                    ))
                    
                    Toggle("显示非连接设备", isOn: Binding(
                        get: { filterManager.filterSettings.showNonConnectableDevices },
                        set: { isOn in
                            filterManager.filterSettings.showNonConnectableDevices = isOn
                            filterManager.saveUserPreferences()
                        }
                    ))
                }
                
                Spacer()
                
 // 重置按钮
                HStack {
                    Button("重置为默认设置") {
                        filterManager.resetFilters()
                    }
                    .buttonStyle(.bordered)
                    
                    Spacer()
                }
            }
            .padding(20)
            .navigationTitle("过滤设置")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }
}

/// 设备类型切换行
struct DeviceTypeToggleRow: View {
    let deviceType: DeviceClassifier.DeviceType
    let isVisible: Bool
    let onToggle: (Bool) -> Void
    
    var body: some View {
        HStack {
 // 设备类型图标
            Image(systemName: deviceTypeIcon)
                .font(.title2)
                .foregroundColor(deviceTypeColor)
                .frame(width: 32, height: 32)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(deviceTypeDisplayName)
                    .font(.body)
                    .foregroundColor(.primary)
                
                Text(deviceTypeDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Toggle("", isOn: Binding(
                get: { isVisible },
                set: { @Sendable newValue in onToggle(newValue) }
            ))
        }
        .padding(.vertical, 4)
    }
    
 // MARK: - 计算属性
    
 /// 设备类型图标
    private var deviceTypeIcon: String {
        switch deviceType {
        case .computer:
            return "desktopcomputer"
        case .camera:
            return "video"
        case .router:
            return "wifi.router"
        case .printer:
            return "printer"
        case .speaker:
            return "speaker.wave.2"
        case .tv:
            return "tv"
        case .nas:
            return "externaldrive.connected.to.line.below"
        case .iot:
            return "homekit"
        case .unknown:
            return "questionmark.circle"
        }
    }
    
 /// 设备类型颜色
    private var deviceTypeColor: Color {
        switch deviceType {
        case .computer:
            return .blue
        case .camera:
            return .orange
        case .router:
            return .green
        case .printer:
            return .purple
        case .speaker:
            return .green
        case .tv:
            return .indigo
        case .nas:
            return .cyan
        case .iot:
            return .pink
        case .unknown:
            return .gray
        }
    }
    
 /// 设备类型显示名称
    private var deviceTypeDisplayName: String {
        switch deviceType {
        case .computer:
            return "计算机设备"
        case .camera:
            return "摄像头设备"
        case .router:
            return "网络设备"
        case .printer:
            return "打印设备"
        case .speaker:
            return "音响设备"
        case .tv:
            return "电视设备"
        case .nas:
            return "存储设备"
        case .iot:
            return "智能设备"
        case .unknown:
            return "未知设备"
        }
    }
    
 /// 设备类型描述
    private var deviceTypeDescription: String {
        switch deviceType {
        case .computer:
            return "台式机、笔记本电脑等计算设备"
        case .camera:
            return "网络摄像头、监控设备等"
        case .router:
            return "路由器、交换机等网络设备"
        case .printer:
            return "打印机、扫描仪等办公设备"
        case .speaker:
            return "智能音响、蓝牙音箱等音频设备"
        case .tv:
            return "智能电视、网络电视盒等显示设备"
        case .nas:
            return "网络存储、文件服务器等"
        case .iot:
            return "智能家居、物联网设备等"
        case .unknown:
            return "无法识别的设备类型"
        }
    }
}

struct DeviceFilterOptionsView_Previews: PreviewProvider {
    static var previews: some View {
        DeviceFilterOptionsView(filterManager: DeviceFilterManager())
    }
}