import SwiftUI
import SkyBridgeCore

/// 增强的设备行组件
public struct EnhancedDeviceRow: View {
    let device: DiscoveredDevice
    let onConnect: () -> Void
    
    public init(device: DiscoveredDevice, onConnect: @escaping () -> Void) {
        self.device = device
        self.onConnect = onConnect
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
 // 设备图标
                Image(systemName: deviceIcon)
                    .font(.title2)
                    .foregroundColor(deviceColor)
                    .frame(width: 32, height: 32)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(device.name)
                        .font(.headline)
                        .foregroundColor(.white)
                    
                    Text(device.ipv4 ?? device.ipv6 ?? LocalizationManager.shared.localizedString("device.unknownIP"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
 // 连接状态指示器
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
            }
            
 // 连接类型标签（新增）
            if !device.connectionTypes.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(device.connectionTypes.sorted(by: { $0.rawValue < $1.rawValue })), id: \.self) { connectionType in
                        HStack(spacing: 4) {
                            Image(systemName: connectionType.iconName)
                                .font(.system(size: 10))
                            Text(connectionType.rawValue)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(connectionTypeColor(for: connectionType))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            
 // 设备信息
            HStack {
                Label(LocalizationManager.shared.localizedString("device.services"), systemImage: "info.circle")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Text("\(device.services.count) \(LocalizationManager.shared.localizedString("device.servicesCount"))")
                    .font(.caption)
                    .foregroundColor(.white)
            }
            
 // 连接按钮
            Button(action: onConnect) {
                HStack {
                    Image(systemName: "link")
                        .font(.caption)
                    Text(LocalizationManager.shared.localizedString("device.action.connect"))
                        .font(.caption.weight(.medium))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.blue.opacity(0.8))
                )
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(red: 20/255, green: 25/255, blue: 45/255))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
        )
    }
    
 /// 获取连接类型的颜色
    private func connectionTypeColor(for type: DeviceConnectionType) -> Color {
        switch type {
        case .wifi:
            return Color.blue.opacity(0.8)
        case .usb:
            return Color.green.opacity(0.8)
        case .ethernet:
            return Color.purple.opacity(0.8)
        case .thunderbolt:
            return Color.orange.opacity(0.8)
        case .bluetooth:
            return Color.cyan.opacity(0.8)
        case .unknown:
            return Color.gray.opacity(0.6)
        }
    }
    
    private var deviceIcon: String {
 // 根据服务类型推断设备类型
        if device.services.contains(where: { $0.contains("rdp") }) {
            return "desktopcomputer"
        } else if device.services.contains(where: { $0.contains("rfb") }) {
            return "laptopcomputer"
        } else if device.services.contains(where: { $0.contains("skybridge") }) {
            return "iphone"
        } else {
            return "display"
        }
    }
    
    private var deviceColor: Color {
 // 根据服务类型设置颜色
        if device.services.contains(where: { $0.contains("rdp") }) {
            return .blue
        } else if device.services.contains(where: { $0.contains("rfb") }) {
            return .green
        } else if device.services.contains(where: { $0.contains("skybridge") }) {
            return .orange
        } else {
            return .gray
        }
    }
    
    private var statusColor: Color {
 // 根据是否有IP地址判断在线状态
        (device.ipv4 != nil || device.ipv6 != nil) ? .green : .red
    }
}

