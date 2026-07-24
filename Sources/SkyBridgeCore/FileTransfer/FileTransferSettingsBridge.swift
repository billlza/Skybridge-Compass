import Foundation
import Combine
import SkyBridgeProtocolCore

struct FileTransferReceiveDirectoryFailure: Sendable, Equatable {
    let domain: String
    let code: Int

    init(_ error: Error) {
        let nsError = error as NSError
        self.domain = nsError.domain
        self.code = nsError.code
    }
}

enum FileTransferReceiveDirectoryResolution: Sendable, Equatable {
    case success(
        url: URL,
        usedFallback: Bool,
        preferredFailure: FileTransferReceiveDirectoryFailure?
    )
    case failure(
        preferredFailure: FileTransferReceiveDirectoryFailure?,
        terminalFailure: FileTransferReceiveDirectoryFailure
    )
    case cancelled
}

enum FileTransferDirectoryResolutionCoalescingPolicy {
    nonisolated static func shouldReuseActiveRequest(
        requestKey: String,
        lastRequestedKey: String?,
        hasActiveTask: Bool,
        force: Bool
    ) -> Bool {
        !force && hasActiveTask && requestKey == lastRequestedKey
    }
}

/// 桥接“设置-文件传输”到权威的 `FileTransferManager` 运行时。
@MainActor
public final class FileTransferSettingsBridge: ObservableObject {
    private struct RuntimeSettingsSnapshot: Equatable {
        let concurrentTransfers: Int
        let chunkSize: Int
        let speedLimitMBps: Double
        let automaticResumeEnabled: Bool
        let keepTransferHistory: Bool
        let keepSystemAwake: Bool
        let virusScanEnabled: Bool
        let scanLevel: String
    }

    public static let shared = FileTransferSettingsBridge()

    private let settings = SettingsManager.shared
    private let fileTransferManager = FileTransferManager.shared
    private var directoryResolutionTask: Task<Void, Never>?
    private var directoryRevision: UInt64 = 0
    private var lastRequestedDirectoryKey: String?
    private var lastAppliedRuntimeSnapshot: RuntimeSettingsSnapshot?

    private init() {}

    /// 手动应用当前设置到后端。纯内存设置立即应用；目录 I/O 在专用 actor 上合并执行。
    public func apply() {
        applyRuntimeSettings()
        _ = scheduleDirectoryResolution(
            preferredPath: settings.defaultTransferPath,
            force: false
        )
    }

    /// 异步调用返回时，设置（包括真实目录验证）已经完整下推。
    public func applyAsync() async {
        applyRuntimeSettings()
        let task = scheduleDirectoryResolution(
            preferredPath: settings.defaultTransferPath,
            force: false
        )
        await task?.value
    }

    /// 更新接收目录。只有 descriptor-based 校验成功后才更新持久设置与运行时路径。
    public func updateReceiveDirectory(_ url: URL?) {
        _ = scheduleDirectoryResolution(
            preferredPath: url?.path ?? "",
            force: true
        )
    }

    private func applyRuntimeSettings() {
        let concurrentTransfers = settings.maxConcurrentFileTransfers
        let configuredChunkSize = settings.transferBufferSize
        let speedLimitMBps = settings.transferSpeedLimitMBps

        guard (1...ClassicTransferInboundPolicy.maximumConcurrentConnections)
            .contains(concurrentTransfers) else {
            reportRuntimeValidationFailure(code: "invalid_concurrent_transfer_limit")
            return
        }
        guard (ClassicTransferInboundPolicy.minimumDeclaredChunkSizeBytes...ClassicTransferInboundPolicy.maximumDeclaredChunkSizeBytes).contains(configuredChunkSize) else {
            reportRuntimeValidationFailure(code: "invalid_transfer_chunk_size")
            return
        }
        guard speedLimitMBps.isFinite,
              speedLimitMBps >= 0,
              speedLimitMBps <= SettingsManager.maximumTransferSpeedLimitMBps else {
            reportRuntimeValidationFailure(code: "invalid_transfer_speed_limit")
            return
        }

        let snapshot = RuntimeSettingsSnapshot(
            concurrentTransfers: concurrentTransfers,
            chunkSize: configuredChunkSize,
            speedLimitMBps: speedLimitMBps,
            automaticResumeEnabled: settings.autoRetryFailedTransfers,
            keepTransferHistory: settings.keepTransferHistory,
            keepSystemAwake: settings.keepSystemAwakeDuringTransfer,
            virusScanEnabled: settings.scanTransferFilesForVirus,
            scanLevel: settings.scanLevel.rawValue
        )
        guard snapshot != lastAppliedRuntimeSnapshot else { return }

        let speedLimitBytesPerSecond = speedLimitMBps * 1_024 * 1_024
        fileTransferManager.updateSettings(
            maxConcurrentTransfers: concurrentTransfers,
            chunkSize: configuredChunkSize,
            maxTransferSpeedBytesPerSecond: speedLimitBytesPerSecond,
            automaticResumeEnabled: settings.autoRetryFailedTransfers,
            keepTransferHistory: settings.keepTransferHistory,
            keepSystemAwakeDuringTransfer: settings.keepSystemAwakeDuringTransfer
        )
        fileTransferManager.updateSecuritySettings(
            virusScanEnabled: settings.scanTransferFilesForVirus,
            scanLevel: settings.scanLevel
        )
        lastAppliedRuntimeSnapshot = snapshot
        NetworkActivityLogStore.shared.record(
            category: "file-transfer",
            message: "应用文件传输设置: 并发=\(concurrentTransfers), 分片=\(configuredChunkSize), 限速MBps=\(speedLimitMBps)"
        )
    }

    @discardableResult
    private func scheduleDirectoryResolution(
        preferredPath: String,
        force: Bool
    ) -> Task<Void, Never>? {
        let requestKey = preferredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if FileTransferDirectoryResolutionCoalescingPolicy.shouldReuseActiveRequest(
            requestKey: requestKey,
            lastRequestedKey: lastRequestedDirectoryKey,
            hasActiveTask: directoryResolutionTask != nil,
            force: force
        ), let directoryResolutionTask {
            return directoryResolutionTask
        }

        directoryRevision &+= 1
        let revision = directoryRevision
        lastRequestedDirectoryKey = requestKey
        directoryResolutionTask?.cancel()

        let task = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }

            let result = await Self.resolveReceiveDirectory(preferredPath: requestKey)
            guard !Task.isCancelled,
                  let self,
                  revision == self.directoryRevision else {
                return
            }
            self.applyDirectoryResolution(result)
            if revision == self.directoryRevision {
                self.directoryResolutionTask = nil
            }
        }
        directoryResolutionTask = task
        return task
    }

    nonisolated static func resolveReceiveDirectory(
        preferredPath: String,
        fallbackURL: URL? = nil
    ) async -> FileTransferReceiveDirectoryResolution {
        do {
            try Task.checkCancellation()
        } catch {
            return .cancelled
        }

        let preferredURL = normalizedDirectoryURL(from: preferredPath)
        var preferredFailure: FileTransferReceiveDirectoryFailure?
        if let preferredURL {
            do {
                let resolved = try await InboundFileTransferIOActor.shared
                    .prepareFirstWritableDirectory(from: [preferredURL])
                return .success(
                    url: resolved,
                    usedFallback: false,
                    preferredFailure: nil
                )
            } catch is CancellationError {
                return .cancelled
            } catch {
                preferredFailure = FileTransferReceiveDirectoryFailure(error)
            }
        }

        let fallback = fallbackURL ?? fallbackReceiveDirectory()
        do {
            let resolved = try await InboundFileTransferIOActor.shared
                .prepareFirstWritableDirectory(from: [fallback])
            return .success(
                url: resolved,
                usedFallback: true,
                preferredFailure: preferredFailure
            )
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failure(
                preferredFailure: preferredFailure,
                terminalFailure: FileTransferReceiveDirectoryFailure(error)
            )
        }
    }

    private func applyDirectoryResolution(_ result: FileTransferReceiveDirectoryResolution) {
        switch result {
        case .success(let url, let usedFallback, let preferredFailure):
            if let preferredFailure {
                recordDirectoryCandidateFailure(preferredFailure)
            }
            fileTransferManager.setReceiveBaseDirectory(url)
            if settings.defaultTransferPath != url.path {
                settings.defaultTransferPath = url.path
            }
            guard usedFallback else { return }

            SkyBridgeLogger.fileTransfer.warning("⚠️ 默认接收目录不可用，已使用受验证的回退目录")
            NetworkActivityLogStore.shared.record(
                category: "file-transfer",
                message: "默认接收目录不可用，已使用受验证的回退目录",
                level: "WARN"
            )
            NotificationCenter.default.post(
                name: NSNotification.Name("FileTransferReceivePathFallback"),
                object: nil,
                userInfo: ["path": url.path]
            )
        case .failure(let preferredFailure, let terminalFailure):
            if let preferredFailure {
                recordDirectoryCandidateFailure(preferredFailure)
            }
            reportTerminalDirectoryFailure(terminalFailure)
        case .cancelled:
            break
        }
    }

    private func recordDirectoryCandidateFailure(_ failure: FileTransferReceiveDirectoryFailure) {
        SkyBridgeLogger.fileTransfer.warning(
            "候选文件接收目录不可用: domain=\(failure.domain, privacy: .private) code=\(failure.code, privacy: .public)"
        )
    }

    private func reportTerminalDirectoryFailure(_ failure: FileTransferReceiveDirectoryFailure) {
        SkyBridgeLogger.fileTransfer.error(
            "文件接收目录配置失败: domain=\(failure.domain, privacy: .private) code=\(failure.code, privacy: .public)"
        )
        NetworkActivityLogStore.shared.record(
            category: "file-transfer",
            message: "文件接收目录配置失败: domain=\(failure.domain) code=\(failure.code)",
            level: "ERROR"
        )
        NotificationCenter.default.post(
            name: NSNotification.Name("FileTransferReceivePathFailure"),
            object: nil,
            userInfo: ["domain": failure.domain, "code": failure.code]
        )
    }

    private func reportRuntimeValidationFailure(code: String) {
        SkyBridgeLogger.fileTransfer.error(
            "文件传输运行时设置校验失败: code=\(code, privacy: .public)"
        )
        NetworkActivityLogStore.shared.record(
            category: "file-transfer",
            message: "文件传输运行时设置校验失败: code=\(code)",
            level: "ERROR"
        )
        NotificationCenter.default.post(
            name: Notification.Name("FileTransferSettingsValidationFailure"),
            object: nil,
            userInfo: ["code": code]
        )
    }

    private nonisolated static func normalizedDirectoryURL(from rawPath: String) -> URL? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expandedPath = (trimmed as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expandedPath, isDirectory: true).standardizedFileURL
    }

    private nonisolated static func fallbackReceiveDirectory() -> URL {
        let base = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        return base.appendingPathComponent("SkyBridge", isDirectory: true)
    }
}
