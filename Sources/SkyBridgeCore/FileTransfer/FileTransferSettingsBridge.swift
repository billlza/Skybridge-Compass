import Foundation

/// 桥接“设置-文件传输”到实际后端（非侵入式）：
/// - 仅在显式调用 apply() 时下推到引擎，避免日常 UI 修改影响实际功能
/// - 去抖/合并多项更改
@MainActor
public final class FileTransferSettingsBridge: ObservableObject {
    public static let shared = FileTransferSettingsBridge()

    private let settings = SettingsManager.shared
    private let fileTransferManager = FileTransferManager.shared

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
        if let url, let normalized = normalizedDirectory(from: url.path) {
            fileTransferManager.setReceiveBaseDirectory(normalized)
            settings.defaultTransferPath = normalized.path
            return
        }

        let fallback = fallbackReceiveDirectory()
        _ = try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        fileTransferManager.setReceiveBaseDirectory(fallback)
        settings.defaultTransferPath = fallback.path

        let message = "默认接收目录不可用，已回退到 \(fallback.path)"
        SkyBridgeLogger.fileTransfer.warning("⚠️ \(message, privacy: .public)")
        NetworkActivityLogStore.shared.record(category: "file-transfer", message: message, level: "WARN")
        NotificationCenter.default.post(
            name: NSNotification.Name("FileTransferReceivePathFallback"),
            object: nil,
            userInfo: ["path": fallback.path]
        )
    }

    private func applyFileTransferSettings() {
        let resolvedDirectory = resolvedReceiveDirectory()
        fileTransferManager.setReceiveBaseDirectory(resolvedDirectory.url)

        if resolvedDirectory.usedFallback {
            settings.defaultTransferPath = resolvedDirectory.url.path
            let message = "默认接收目录不可用，已回退到 \(resolvedDirectory.url.path)"
            SkyBridgeLogger.fileTransfer.warning("⚠️ \(message, privacy: .public)")
            NetworkActivityLogStore.shared.record(category: "file-transfer", message: message, level: "WARN")
            NotificationCenter.default.post(
                name: NSNotification.Name("FileTransferReceivePathFallback"),
                object: nil,
                userInfo: ["path": resolvedDirectory.url.path]
            )
        }

        let speedLimitBytesPerSecond: Double? = settings.transferSpeedLimitMBps > 0
            ? settings.transferSpeedLimitMBps * 1024 * 1024
            : nil

        // 并发、缓冲区等运行时设置
        fileTransferManager.updateSettings(
            maxConcurrentTransfers: Int(settings.maxConcurrentConnections),
            chunkSize: settings.transferBufferSize,
            enableCompression: settings.enableConnectionEncryption, // 保持与UI一致的命名：这里代表传输层开关
            enableEncryption: settings.enableConnectionEncryption,
            maxTransferSpeedBytesPerSecond: speedLimitBytesPerSecond
        )
        fileTransferManager.updateSecuritySettings(
            virusScanEnabled: settings.scanTransferFilesForVirus,
            scanLevel: settings.scanLevel
        )
        NetworkActivityLogStore.shared.record(
            category: "file-transfer",
            message: "应用文件传输设置: 并发=\(settings.maxConcurrentConnections), 分片=\(settings.transferBufferSize), 限速MBps=\(settings.transferSpeedLimitMBps)"
        )
    }

    private func resolvedReceiveDirectory() -> (url: URL, usedFallback: Bool) {
        if let candidate = normalizedDirectory(from: settings.defaultTransferPath) {
            return (candidate, false)
        }

        let fallback = fallbackReceiveDirectory()
        _ = try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return (fallback, true)
    }

    private func normalizedDirectory(from rawPath: String) -> URL? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let expandedPath = (trimmed as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            guard FileManager.default.isWritableFile(atPath: url.path) else {
                return nil
            }
            return url
        } catch {
            return nil
        }
    }

    private func fallbackReceiveDirectory() -> URL {
        let base = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        return base.appendingPathComponent("SkyBridge", isDirectory: true)
    }
}
