import SwiftUI

// 设备模型已在同一模块中，无需导入

/// 设备分组视图 - 显示同类型设备的折叠组
struct DeviceGroupView: View {
    let group: DeviceFilterManager.DeviceGroup
    let isExpanded: Bool
    let onToggleExpanded: () -> Void
    let onConnect: (DiscoveredDevice) -> Void
    let onDisconnect: (DiscoveredDevice) -> Void
    let getConnectionStatus: (DiscoveredDevice) -> ConnectionStatus
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
 // 分组头部
            groupHeader
            
 // 设备列表（展开时显示）
            if isExpanded {
                deviceList
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.1), radius: 2, x: 0, y: 1)
    }
    
 // MARK: - 子视图
    
 /// 分组头部
    private var groupHeader: some View {
        Button(action: onToggleExpanded) {
            HStack {
 // 设备类型图标
                Image(systemName: deviceTypeIcon)
                    .font(.title2)
                    .foregroundColor(deviceTypeColor)
                    .frame(width: 32, height: 32)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(deviceTypeDisplayName)
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    Text("\(group.devices.count) 台设备")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
 // 展开/折叠指示器
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .animation(.easeInOut(duration: 0.2), value: isExpanded)
                
 // 分组状态指示器
                if group.type != .computer {
                    Text(group.type == .camera ? "摄像头" : "其他设备")
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.2))
                        .foregroundColor(.orange)
                        .cornerRadius(8)
                }
            }
            .padding(16)
        }
        .buttonStyle(PlainButtonStyle())
    }
    
 /// 设备列表
    private var deviceList: some View {
        VStack(spacing: 8) {
            ForEach(group.devices) { device in
                DeviceCardView(
                    device: device,
                    connectionStatus: getConnectionStatus(device),
                    onConnect: {
                        onConnect(device)
                    },
                    onDisconnect: {
                        onDisconnect(device)
                    },
                    showDeviceType: true
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }
    
 // MARK: - 计算属性
    
 /// 设备类型图标
    private var deviceTypeIcon: String {
        switch group.type {
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
            return "sensor"
        case .unknown:
            return "questionmark.circle"
        }
    }
    
 /// 设备类型颜色
    private var deviceTypeColor: Color {
        switch group.type {
        case .computer:
            return .blue
        case .camera:
            return .red
        case .router:
            return .orange
        case .printer:
            return .purple
        case .speaker:
            return .green
        case .tv:
            return .indigo
        case .nas:
            return .cyan
        case .iot:
            return .yellow
        case .unknown:
            return .gray
        }
    }
    
 /// 设备类型显示名称
    private var deviceTypeDisplayName: String {
        switch group.type {
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
            return "物联网设备"
        case .unknown:
            return "未知设备"
        }
    }
}

struct DeviceGroupView_Previews: PreviewProvider {
    static var previews: some View {
        let sampleDevices = [
            DiscoveredDevice(
                id: UUID(),
                name: "海康威视摄像头",
                ipv4: "192.168.1.100",
                ipv6: nil,
                services: ["http", "rtsp"],
                portMap: ["http": 80, "rtsp": 554]
            ),
            DiscoveredDevice(
                id: UUID(),
                name: "大华摄像头",
                ipv4: "192.168.1.101",
                ipv6: nil,
                services: ["http", "onvif"],
                portMap: ["http": 80, "onvif": 8000]
            )
        ]
        
        let group = DeviceFilterManager.DeviceGroup(
            type: .camera,
            devices: sampleDevices
        )
        
        DeviceGroupView(
            group: group,
            isExpanded: true,
            onToggleExpanded: {},
            onConnect: { _ in },
            onDisconnect: { _ in },
            getConnectionStatus: { _ in .disconnected }
        )
        .padding()
    }
}