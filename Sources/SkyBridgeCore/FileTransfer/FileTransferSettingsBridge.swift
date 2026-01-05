import Foundation
import Combine

/// 桥接“设置-文件传输”到实际后端（非侵入式）：
/// - 仅在显式调用 apply() 时下推到引擎，避免日常 UI 修改影响实际功能
/// - 去抖/合并多项更改
@MainActor
public final class FileTransferSettingsBridge: ObservableObject {
    public static let shared = FileTransferSettingsBridge()
    
    private let videoSettings = VideoTransferSettingsManager.shared
    private let settings = SettingsManager.shared
    private let fileTransferManager = FileTransferManager()
    private var cancellables = Set<AnyCancellable>()
    
    private var pendingApplyWorkItem: DispatchWorkItem?
    private let debounceInterval: TimeInterval = 0.0 // 仅手动触发，默认不自动
    
    private init() {}
    
 /// 手动应用当前设置到后端（安全合并）
    public func apply() {
        pendingApplyWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.applyFileTransferSettings()
                self.applyVideoSettings()
            }
        }
        pendingApplyWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

 /// 异步版本的应用接口，供需要 `await` 的调用场景（例如前台分层恢复）
    public func applyAsync() async {
        await MainActor.run {
            self.apply()
        }
    }
    
 /// 更新接收目录
    public func updateReceiveDirectory(_ url: URL?) {
        fileTransferManager.setReceiveBaseDirectory(url)
    }
    
    private func applyFileTransferSettings() {
 // 并发、缓冲区等运行时设置
        fileTransferManager.updateSettings(
            maxConcurrentTransfers: Int(settings.maxConcurrentConnections),
            chunkSize: settings.transferBufferSize,
            enableCompression: settings.enableConnectionEncryption, // 保持与UI一致的命名：这里代表传输层开关
            enableEncryption: settings.enableConnectionEncryption
        )
 // 通知开关、自动重试等策略在下一步扩展（需要在 FileTransferManager 增加策略接口）
    }
    
    private func applyVideoSettings() {
 // 将视频传输设置同步到远程桌面设置管理器
        let rd = RemoteDesktopSettingsManager.shared
        rd.settings.displaySettings.refreshRate = videoSettings.selectedFrameRate.refreshRate
        rd.settings.displaySettings.videoQuality = videoSettings.compressionQuality.videoQuality
        rd.saveSettings()
        
 // 通知活动会话应用新设置
        Task { @MainActor in
 // 通过RemoteDesktopManager通知活动会话更新设置
 // 会话会自动从RemoteDesktopSettingsManager读取最新设置
            NotificationCenter.default.post(name: NSNotification.Name("RemoteDesktopSettingsDidUpdate"), object: nil)
        }
    }
}

private extension VideoFrameRate {
    var refreshRate: RefreshRate {
        switch self {
        case .fps30: return .hz30
        case .fps60: return .hz60
        case .fps120: return .hz120
        }
    }
}

private extension VideoCompressionQuality {
    var videoQuality: VideoQuality {
        switch self {
        case .none: return .ultra
        case .fast: return .low
        case .balanced: return .medium
        case .maximum: return .high
        }
    }
}
