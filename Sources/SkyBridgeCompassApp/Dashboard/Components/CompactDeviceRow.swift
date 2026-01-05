import SwiftUI
import SkyBridgeCore

/// 紧凑设备行组件
public struct CompactDeviceRow: View {
    let device: DiscoveredDevice
    let connectAction: () -> Void
    @State private var isConnecting = false
    
    public init(device: DiscoveredDevice, connectAction: @escaping () -> Void) {
        self.device = device
        self.connectAction = connectAction
    }
    
    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: deviceIcon)
                .font(.title3)
                .foregroundColor(deviceColor)
                .frame(width: 24, height: 24)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                
                Text(device.ipv4 ?? device.ipv6 ?? LocalizationManager.shared.localizedString("dashboard.unknownIP"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button(action: {
                isConnecting = true
                connectAction()
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_000_000_000) // 2秒（Task.sleep 可能抛出 CancellationError）
                    isConnecting = false
                }
            }) {
                if isConnecting {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 50, height: 24)
                } else {
                    Text(LocalizationManager.shared.localizedString("dashboard.action.connect"))
                        .font(.caption.weight(.medium))
                        .frame(width: 50, height: 24)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isConnecting)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    
    private var deviceIcon: String {
        if device.services.contains("_ssh._tcp") {
            return "terminal"
        } else if device.services.contains("_vnc._tcp") {
            return "display"
        } else if device.services.contains("_rdp._tcp") {
            return "desktopcomputer"
        } else {
            return "laptopcomputer"
        }
    }
    
    private var deviceColor: Color {
        if device.services.contains("_ssh._tcp") {
            return .green
        } else if device.services.contains("_vnc._tcp") {
            return .blue
        } else if device.services.contains("_rdp._tcp") {
            return .purple
        } else {
            return .gray
        }
    }
}

