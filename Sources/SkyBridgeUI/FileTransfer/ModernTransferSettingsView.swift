import SwiftUI
import SkyBridgeCore

/// 现代化传输设置视图 - 符合Apple设计规范的设置界面。
/// 核心设置（并发数 / 自动续传）绑定到权威的 SettingsManager，经 FileTransferSettingsBridge 在
/// 启动时应用并跨重启持久化（与主设置一致，避免此前“仅保存当次会话、重启失效”的并行 UserDefaults 存储）。
public struct ModernTransferSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var transferManager: FileTransferManager

    @State private var maxConcurrentTransfers = SettingsManager.defaultMaxConcurrentFileTransfers
    @State private var chunkSize = 128 * 1024
    @State private var autoRetryFailedTransfers = true

    public init(transferManager: FileTransferManager = .shared) {
        _transferManager = ObservedObject(initialValue: transferManager)
    }

    public var body: some View {
        NavigationView {
            Form {
                Section("基本设置") {
                    Stepper(
                        value: $maxConcurrentTransfers,
                        in: 1...SettingsManager.maximumConcurrentFileTransfers
                    ) {
                        HStack {
                            Text("并发传输数量")
                            Spacer()
                            Text("\(maxConcurrentTransfers)")
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                    }

                    HStack {
                        Text("数据块大小")
                        Spacer()
                        Picker("数据块大小", selection: $chunkSize) {
                            ForEach([64, 128, 256, 512], id: \.self) { kibibytes in
                                Text(formatBytes(kibibytes * 1_024))
                                    .tag(kibibytes * 1_024)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 120)
                    }
                }

                Section("网络设置") {
                    Toggle("连接中断时自动续传", isOn: $autoRetryFailedTransfers)

                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "lock.fill")
                            .foregroundColor(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("文件传输加密始终开启")
                                .font(.subheadline)
                            Text("经典传输协议固定要求 AES-256-GCM，不提供降级开关。")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Section("操作") {
                    Button("重置为默认设置") {
                        resetToDefaults()
                    }
                    .foregroundColor(.orange)

                    Button("清除传输历史") {
                        clearTransferHistory()
                    }
                    .foregroundColor(.red)
                }
            }
            .navigationTitle("传输设置")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("完成") {
                        saveSettings()
                        dismiss()
                    }
                }
            }
        }
        .frame(width: 600, height: 700)
        .onAppear {
            loadCurrentSettings()
        }
    }

 // MARK: - 私有方法

 /// 加载当前设置（读取权威 SettingsManager，跨重启持久化的值）
    private func loadCurrentSettings() {
        let settings = SettingsManager.shared
        maxConcurrentTransfers = settings.maxConcurrentFileTransfers
        chunkSize = settings.transferBufferSize
        autoRetryFailedTransfers = settings.autoRetryFailedTransfers
    }

 /// 保存设置：写入权威 SettingsManager（其 @Published sink 持久化 + 经 FileTransferSettingsBridge 在
 /// 启动时应用），并立即同步到运行时传输管理器（含当次会话的压缩/块大小）。
    private func saveSettings() {
        let settings = SettingsManager.shared
        settings.maxConcurrentFileTransfers = maxConcurrentTransfers
        settings.transferBufferSize = chunkSize
        settings.autoRetryFailedTransfers = autoRetryFailedTransfers
        FileTransferSettingsBridge.shared.apply()
    }

 /// 重置为默认设置
    private func resetToDefaults() {
        maxConcurrentTransfers = SettingsManager.defaultMaxConcurrentFileTransfers
        chunkSize = SettingsManager.defaultTransferBufferSize
        autoRetryFailedTransfers = true
    }

 /// 清除传输历史
    private func clearTransferHistory() {
        transferManager.clearHistory()
    }

 /// 格式化字节数
    private func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

struct ModernTransferSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        ModernTransferSettingsView(transferManager: FileTransferManager.shared)
    }
}
