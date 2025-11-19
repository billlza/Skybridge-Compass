import SwiftUI
import RemoteDesktopKit
import SkyBridgeDesignSystem

struct RemoteDesktopTabView: View {
    let sessions: [RemoteSessionSummary]

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 16) {
                ForEach(sessions) { session in
                    SessionRow(session: session)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 180)
        }
        .overlay(alignment: .bottom) {
            LiquidBottomBar {
                VStack(alignment: .leading, spacing: 12) {
                    Text("远程操作")
                        .font(.headline)
                    HStack(spacing: 12) {
                        PrimaryActionButton(title: "快速连接", icon: "bolt.fill") {}
                        PrimaryActionButton(title: "性能预设", icon: "speedometer") {}
                    }
                }
            }
        }
    }
}

private struct SessionRow: View {
    let session: RemoteSessionSummary
    var body: some View {
        GlassCard {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.deviceName)
                        .font(.headline)
                    Text("\(session.resolution) · \(session.fps) FPS")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("延迟 \(session.latency) ms · 模式 \(session.mode)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                    .frame(width: 96, height: 64)
                    .overlay(
                        Text(session.thumbnail.prefix(2).uppercased())
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    )
            }
        }
    }
}
