import SwiftUI
import UIKit

struct ActivityStatusView: View {
    @Environment(DashboardViewModel.self) private var viewModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("灵动岛与 Live Activity")
                .font(.largeTitle.bold())
            Text("在 iPhone 的灵动岛和锁屏显示实时的 CPU、内存和电池状态。")
                .font(.body)
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Image(systemName: viewModel.isActivityRunning ? "circle.fill" : "circle")
                    .foregroundStyle(viewModel.isActivityRunning ? .green : .secondary)
                Text(viewModel.isActivityRunning ? "Live Activity 已开启" : "Live Activity 已关闭")
                    .font(.headline)
            }
            HStack(spacing: 12) {
                Button(viewModel.isActivityRunning ? "停止" : "立即启动") {
                    Task {
                        if viewModel.isActivityRunning {
                            await viewModel.stopActivity()
                        } else {
                            await viewModel.refreshOnce()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                Button("打开系统设置") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                        openURL(url)
                    }
                }
            }
            .buttonStyle(.bordered)
            VStack(alignment: .leading, spacing: 12) {
                Text("提示")
                    .font(.headline)
                Label("请确保允许云桥司南显示通知以启用 Live Activity", systemImage: "bell")
                Label("在灵动岛上将以液态玻璃风格展示核心指标", systemImage: "sparkles")
            }
            .padding()
            .liquidGlass()
            Spacer()
        }
        .padding(24)
        .navigationTitle("灵动岛")
    }
}
