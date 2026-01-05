import SwiftUI
import UniformTypeIdentifiers
import SkyBridgeCore

/// 现代化传输设置视图 - 符合Apple设计规范的设置界面
struct ModernTransferSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var transferManager: FileTransferManager
    
    @State private var maxConcurrentTransfers = 3
    @State private var chunkSize = 1024 * 1024 // 1MB
    @State private var enableCompression = true
    @State private var enableEncryption = true
    @State private var autoRetryFailedTransfers = true
    @State private var maxRetryAttempts = 3
    @State private var networkTimeout: Double = 30
    @State private var enableNotifications = true
    @State private var enableSoundEffects = true
    @State private var selectedQuality: TransferQuality = .balanced
    @State private var enableAutoDiscovery = true
    @State private var discoveryPort = 8080
    @State private var enableQRCodeSharing = true
    
    var body: some View {
        NavigationView {
            Form {
                Section("基本设置") {
                    HStack {
                        Text("并发传输数量")
                        Spacer()
                        Text("\(maxConcurrentTransfers)")
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("数据块大小")
                        Spacer()
                        Text(formatBytes(chunkSize))
                            .foregroundColor(.secondary)
                    }
                }
                
                Section("网络设置") {
                    Toggle("启用数据压缩", isOn: $enableCompression)
                    Toggle("端到端加密", isOn: $enableEncryption)
                    
                    HStack {
                        Text("网络超时")
                        Spacer()
                        Text("\(Int(networkTimeout))秒")
                            .foregroundColor(.secondary)
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
    
 /// 加载当前设置
    private func loadCurrentSettings() {
 // 从UserDefaults加载设置
        let defaults = UserDefaults.standard
        maxConcurrentTransfers = defaults.integer(forKey: "maxConcurrentTransfers") > 0 ? defaults.integer(forKey: "maxConcurrentTransfers") : 3
        chunkSize = defaults.integer(forKey: "chunkSize") > 0 ? defaults.integer(forKey: "chunkSize") : 1024 * 1024
        enableCompression = defaults.bool(forKey: "enableCompression")
        enableEncryption = defaults.bool(forKey: "enableEncryption")
        networkTimeout = defaults.double(forKey: "networkTimeout") > 0 ? defaults.double(forKey: "networkTimeout") : 30
    }
    
 /// 保存设置
    private func saveSettings() {
 // 保存设置到UserDefaults
        let defaults = UserDefaults.standard
        defaults.set(maxConcurrentTransfers, forKey: "maxConcurrentTransfers")
        defaults.set(chunkSize, forKey: "chunkSize")
        defaults.set(enableCompression, forKey: "enableCompression")
        defaults.set(enableEncryption, forKey: "enableEncryption")
        defaults.set(networkTimeout, forKey: "networkTimeout")
        
 // 同步到运行时传输管理器
        transferManager.updateSettings(
            maxConcurrentTransfers: maxConcurrentTransfers,
            chunkSize: chunkSize,
            enableCompression: enableCompression,
            enableEncryption: enableEncryption
        )
    }
    
 /// 重置为默认设置
    private func resetToDefaults() {
        maxConcurrentTransfers = 3
        chunkSize = 1024 * 1024
        enableCompression = true
        enableEncryption = true
        autoRetryFailedTransfers = true
        maxRetryAttempts = 3
        networkTimeout = 30
        enableNotifications = true
        enableSoundEffects = true
        selectedQuality = .balanced
        enableAutoDiscovery = true
        discoveryPort = 8080
        enableQRCodeSharing = true
    }
    
 /// 导出设置
    private func exportSettings() {
 // 使用 NSSavePanel 导出设置为 JSON 文件
 // 说明：为避免阻塞主线程，文件写入通过后台任务执行，完成后回到主线程提示
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "SkyBridge设置.json"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
 // 构造可编码的设置载荷
            let payload = SettingsPayload(
                maxConcurrentTransfers: maxConcurrentTransfers,
                chunkSize: chunkSize,
                enableCompression: enableCompression,
                enableEncryption: enableEncryption,
                autoRetryFailedTransfers: autoRetryFailedTransfers,
                maxRetryAttempts: maxRetryAttempts,
                networkTimeout: networkTimeout,
                enableNotifications: enableNotifications,
                enableSoundEffects: enableSoundEffects,
                selectedQuality: selectedQuality,
                enableAutoDiscovery: enableAutoDiscovery,
                discoveryPort: discoveryPort,
                enableQRCodeSharing: enableQRCodeSharing
            )

            Task.detached(priority: .utility) {
                do {
                    let data = try JSONEncoder().encode(payload)
                    try data.write(to: url, options: .atomic)
                } catch {
 // 如需提示用户，可在此处加入错误处理回到主线程展示
                }
            }
        }
    }
    
 /// 导入设置
    private func importSettings() {
 // 使用 NSOpenPanel 导入 JSON 设置文件
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false

        panel.begin { response in
            guard response == .OK, let url = panel.urls.first else { return }

            Task.detached(priority: .utility) {
                do {
                    let data = try Data(contentsOf: url)
                    let payload = try JSONDecoder().decode(SettingsPayload.self, from: data)
 // 回到主线程应用设置
                    await MainActor.run {
                        maxConcurrentTransfers = payload.maxConcurrentTransfers
                        chunkSize = payload.chunkSize
                        enableCompression = payload.enableCompression
                        enableEncryption = payload.enableEncryption
                        autoRetryFailedTransfers = payload.autoRetryFailedTransfers
                        maxRetryAttempts = payload.maxRetryAttempts
                        networkTimeout = payload.networkTimeout
                        enableNotifications = payload.enableNotifications
                        enableSoundEffects = payload.enableSoundEffects
                        selectedQuality = payload.selectedQuality
                        enableAutoDiscovery = payload.enableAutoDiscovery
                        discoveryPort = payload.discoveryPort
                        enableQRCodeSharing = payload.enableQRCodeSharing
 // 同步保存与应用到运行时
                        saveSettings()
                    }
                } catch {
 // 如需提示用户，可在此处加入错误处理回到主线程展示
                }
            }
        }
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

// MARK: - 传输质量枚举

enum TransferQuality: String, CaseIterable, Codable {
    case fast = "fast"
    case balanced = "balanced"
    case reliable = "reliable"
    
    var displayName: String {
        switch self {
        case .fast:
            return "快速"
        case .balanced:
            return "平衡"
        case .reliable:
            return "可靠"
        }
    }
    
    var description: String {
        switch self {
        case .fast:
            return "优先传输速度，适用于稳定网络"
        case .balanced:
            return "平衡速度和稳定性"
        case .reliable:
            return "优先传输稳定性，适用于不稳定网络"
        }
    }
}

/// 设置载荷结构体（用于导入导出），遵循 Codable
private struct SettingsPayload: Codable {
    let maxConcurrentTransfers: Int
    let chunkSize: Int
    let enableCompression: Bool
    let enableEncryption: Bool
    let autoRetryFailedTransfers: Bool
    let maxRetryAttempts: Int
    let networkTimeout: Double
    let enableNotifications: Bool
    let enableSoundEffects: Bool
    let selectedQuality: TransferQuality
    let enableAutoDiscovery: Bool
    let discoveryPort: Int
    let enableQRCodeSharing: Bool
}

struct ModernTransferSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        ModernTransferSettingsView(transferManager: FileTransferManager())
    }
}