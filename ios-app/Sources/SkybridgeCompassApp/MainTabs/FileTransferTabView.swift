import SwiftUI
import RemoteDesktopKit
import SkyBridgeDesignSystem

struct FileTransferTabView: View {
    let transfers: [TransferTask]

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 16) {
                ForEach(transfers) { task in
                    TransferRow(task: task)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 180)
        }
        .overlay(alignment: .bottom) {
            LiquidBottomBar {
                VStack(alignment: .leading, spacing: 12) {
                    Text("文件操作")
                        .font(.headline)
                    HStack(spacing: 12) {
                        PrimaryActionButton(title: "上传文件", icon: "square.and.arrow.up") {}
                        PrimaryActionButton(title: "发送剪贴板", icon: "doc.on.clipboard") {}
                    }
                }
            }
        }
    }
}

private struct TransferRow: View {
    let task: TransferTask
    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(task.fileName)
                            .font(.headline)
                        Text("\(task.direction.rawValue) · \(task.speed) · 剩余 \(task.eta)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(Int(task.progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: task.progress)
                    .progressViewStyle(.linear)
                    .tint(SkyBridgeColors.accentBlue)
            }
        }
    }
}
