import SwiftUI
import AppKit

struct MissingIconHintView: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text("未检测到 AppIcon 资源。请添加 AppIcon.icns 或 AppIcon.png 并重新构建。")
                .font(.subheadline)
            Button("查看指南") {
                openResourcesREADME()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.windowBackgroundColor)).opacity(0.9)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        )
    }

    private func openResourcesREADME() {
        let path = "macos/SkyBridgeCompassApp/Sources/SkyBridgeCompassApp/Resources/README.md"
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(path)
        NSWorkspace.shared.open(url)
    }
}