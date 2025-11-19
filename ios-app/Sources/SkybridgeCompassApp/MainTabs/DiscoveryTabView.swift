import SwiftUI
import DeviceDiscoveryKit
import SkyBridgeDesignSystem

struct DiscoveryTabView: View {
    let devices: [DiscoveredDevice]

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 16) {
                ForEach(devices) { device in
                    DeviceRow(device: device)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 180)
        }
        .overlay(alignment: .bottom) {
            LiquidBottomBar {
                VStack(alignment: .leading, spacing: 12) {
                    Text("设备操作区")
                        .font(.headline)
                    HStack(spacing: 12) {
                        PrimaryActionButton(title: "扫描设备", icon: "dot.radiowaves.left.right") {}
                        PrimaryActionButton(title: "添加配对", icon: "qrcode.viewfinder") {}
                    }
                }
            }
        }
    }
}

private struct DeviceRow: View {
    let device: DiscoveredDevice
    var body: some View {
        GlassCard {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(device.name)
                        .font(.headline)
                    Text("\(device.location) · \(device.medium.rawValue)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Label("服务 \(device.services)", systemImage: "point.3.filled.connected.trianglepath.dotted")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Label("\(device.latency)", systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Label(device.isSecure ? "PQC" : "TLS", systemImage: device.isSecure ? "lock.shield" : "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(device.isSecure ? SkyBridgeColors.successGreen : .yellow)
                }
            }
        }
    }
}
