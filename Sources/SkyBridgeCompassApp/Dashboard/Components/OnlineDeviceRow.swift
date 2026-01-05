import SwiftUI
import SkyBridgeCore

/// 在线设备行组件(支持新的统一设备模型)
public struct OnlineDeviceRow: View {
    let device: OnlineDevice
    let onConnect: () -> Void
    
    public init(device: OnlineDevice, onConnect: @escaping () -> Void) {
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
                    HStack(spacing: 8) {
                        Text(device.name)
                            .font(.headline)
                            .foregroundColor(.white)
                        
 // 本机标签
                        if device.isLocalDevice {
                            Text(LocalizationManager.shared.localizedString("device.local"))
                                .font(.caption2)
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.8))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        
 // 已授权标签
                        if device.isAuthorized {
                            Image(systemName: "checkmark.shield.fill")
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                    }
                    
                    Text(device.ipv4 ?? device.ipv6 ?? LocalizationManager.shared.localizedString("device.noIP"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
 // 连接状态指示器
                VStack(spacing: 4) {
                    Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    
                    Text(device.connectionStatus.rawValue)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            
 // 连接类型标签
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
 // 设备来源
                HStack(spacing: 4) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text(device.sources.map { $0.rawValue }.joined(separator: ", "))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
 // 服务数量
                if !device.services.isEmpty {
                    Text("\(device.services.count) \(LocalizationManager.shared.localizedString("device.servicesCount"))")
                        .font(.caption)
                        .foregroundColor(.white)
                }
            }
            
 // 连接按钮(仅对非本机、在线或已连接的设备显示)
            if !device.isLocalDevice && (device.connectionStatus == .online || device.connectionStatus == .connected) {
                Button(action: onConnect) {
                    HStack {
                        Image(systemName: device.connectionStatus == .connected ? "link" : "link.circle")
                            .font(.caption)
                        Text(device.connectionStatus == .connected ? LocalizationManager.shared.localizedString("device.status.connected") : LocalizationManager.shared.localizedString("device.action.connect"))
                            .font(.caption.weight(.medium))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(device.connectionStatus == .connected ? Color.green.opacity(0.8) : Color.blue.opacity(0.8))
                    )
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(device.connectionStatus == .connected)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(red: 20/255, green: 25/255, blue: 45/255))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(statusBorderColor, lineWidth: device.isLocalDevice ? 2 : 1)
                )
        )
    }
    
    private func connectionTypeColor(for type: DeviceConnectionType) -> Color {
        switch type {
        case .wifi: return Color.blue.opacity(0.8)
        case .usb: return Color.green.opacity(0.8)
        case .ethernet: return Color.purple.opacity(0.8)
        case .thunderbolt: return Color.orange.opacity(0.8)
        case .bluetooth: return Color.cyan.opacity(0.8)
        case .unknown: return Color.gray.opacity(0.6)
        }
    }
    
    private var deviceIcon: String {
        switch device.deviceType {
        case .computer: return "laptopcomputer"
        case .router: return "wifi.router"
        case .nas: return "externaldrive.connected.to.line.below"
        case .printer: return "printer"
        case .camera: return "video"
        case .speaker: return "hifispeaker"
        case .tv: return "tv"
        case .iot: return "sensor"
        case .unknown: return "questionmark.circle"
        }
    }
    
    private var deviceColor: Color {
        switch device.connectionStatus {
        case .connected: return .green
        case .online: return .blue
        case .offline: return .gray
        }
    }
    
    private var statusColor: Color {
        switch device.connectionStatus {
        case .connected: return .green
        case .online: return .blue
        case .offline: return .gray
        }
    }
    
    private var statusBorderColor: Color {
        if device.isLocalDevice {
            return .blue
        }
        return Color.white.opacity(0.1)
    }
}

