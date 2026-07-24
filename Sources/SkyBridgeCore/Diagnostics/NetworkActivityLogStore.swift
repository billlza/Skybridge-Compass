import Foundation
import OSLog

public actor NetworkActivityLogStore {
    public static let shared = NetworkActivityLogStore()

    private let logger = Logger(subsystem: "com.skybridge.compass", category: "NetworkActivityLogStore")
    private let iso8601Formatter: ISO8601DateFormatter
    private let logsDirectory: URL
    private let logFileURL: URL
    private var isEnabled = false

    private let maxFileSizeBytes: Int64 = 2 * 1024 * 1024
    private let maxRotatedFiles = 3

    public init() {
        iso8601Formatter = ISO8601DateFormatter()
        iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        logsDirectory = documentsDirectory
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("SkyBridge", isDirectory: true)
        logFileURL = logsDirectory.appendingPathComponent("network-activity.log")
    }

    nonisolated public func setEnabled(_ enabled: Bool) {
        Task { await self.setEnabledInternal(enabled) }
    }

    nonisolated public func record(category: String, message: String, level: String = "INFO") {
        Task { await self.recordInternal(category: category, message: message, level: level) }
    }

    nonisolated public func clearLogs() {
        Task { await self.clearLogsInternal() }
    }

    private func setEnabledInternal(_ enabled: Bool) {
        isEnabled = enabled
        if enabled {
            recordInternal(category: "settings", message: "网络日志已启用", level: "INFO")
        } else {
            recordInternal(category: "settings", message: "网络日志已禁用", level: "INFO")
        }
    }

    private func clearLogsInternal() {
        let manager = FileManager.default
        let candidates = (0...maxRotatedFiles).map { index in
            index == 0 ? logFileURL : logsDirectory.appendingPathComponent("network-activity.log.\(index)")
        }

        for url in candidates where manager.fileExists(atPath: url.path) {
            do {
                try manager.removeItem(at: url)
            } catch {
                let removalError = error as NSError
                logger.error(
                    "清理网络日志失败: domain=\(removalError.domain, privacy: .private) code=\(removalError.code, privacy: .public)"
                )
            }
        }
    }

    private func recordInternal(category: String, message: String, level: String) {
        guard isEnabled else { return }

        do {
            try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
            try rotateIfNeeded()

            let timestamp = iso8601Formatter.string(from: Date())
            let line = "[\(timestamp)] [\(level)] [\(category)] \(message)\n"
            let data = Data(line.utf8)

            if FileManager.default.fileExists(atPath: logFileURL.path) {
                let handle = try FileHandle(forWritingTo: logFileURL)
                let writeResult: Result<Void, Error>
                do {
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                    writeResult = .success(())
                } catch {
                    writeResult = .failure(error)
                }
                do {
                    try handle.close()
                } catch {
                    let closeError = error as NSError
                    logger.error(
                        "关闭网络日志文件失败: domain=\(closeError.domain, privacy: .private) code=\(closeError.code, privacy: .public)"
                    )
                    if case .success = writeResult {
                        throw error
                    }
                }
                try writeResult.get()
            } else {
                try data.write(to: logFileURL, options: .atomic)
            }
        } catch {
            let writeError = error as NSError
            logger.error(
                "写入网络日志失败: domain=\(writeError.domain, privacy: .private) code=\(writeError.code, privacy: .public)"
            )
        }
    }

    private func rotateIfNeeded() throws {
        guard FileManager.default.fileExists(atPath: logFileURL.path) else { return }

        let attributes = try FileManager.default.attributesOfItem(atPath: logFileURL.path)
        let fileSize = attributes[.size] as? NSNumber
        guard let fileSize else { return }
        guard fileSize.int64Value >= maxFileSizeBytes else { return }

        let manager = FileManager.default

        for index in stride(from: maxRotatedFiles, through: 1, by: -1) {
            let source = logsDirectory.appendingPathComponent("network-activity.log.\(index)")
            let destination = logsDirectory.appendingPathComponent("network-activity.log.\(index + 1)")
            if manager.fileExists(atPath: source.path) {
                if manager.fileExists(atPath: destination.path) {
                    try? manager.removeItem(at: destination)
                }
                try manager.moveItem(at: source, to: destination)
            }
        }

        let firstBackup = logsDirectory.appendingPathComponent("network-activity.log.1")
        if manager.fileExists(atPath: firstBackup.path) {
            try? manager.removeItem(at: firstBackup)
        }
        try manager.moveItem(at: logFileURL, to: firstBackup)
    }
}
