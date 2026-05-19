import Foundation
import Dispatch

enum RemoteControlSmokeStatusWriter {
    private final class WriterState: @unchecked Sendable {
        private let timestampFormatter: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()
        private var cachedHandle: FileHandle?

        func timestamp() -> String {
            timestampFormatter.string(from: Date())
        }

        func cachedFileHandle(for url: URL) -> FileHandle? {
            if let cachedHandle {
                return cachedHandle
            }
            guard let handle = try? FileHandle(forWritingTo: url) else {
                return nil
            }
            _ = try? handle.seekToEnd()
            cachedHandle = handle
            return handle
        }
    }

    private static let writerQueue = DispatchQueue(
        label: "com.skybridge.compass.remote-control-smoke-status-writer",
        qos: .utility
    )
    private static let writerState = WriterState()

    static func append(_ line: String) {
        guard ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil else { return }
        guard let statusURL = smokeStatusURL() else { return }

        writerQueue.async {
            print("🧪 \(line)")
            let rendered = "[\(writerState.timestamp())] \(line)\n"
            guard let data = rendered.data(using: .utf8) else { return }
            write(data, to: statusURL)
        }
    }

    private static func smokeStatusURL() -> URL? {
        guard let raw = ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_STATUS_FILE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: raw)
    }

    private static func write(_ data: Data, to statusURL: URL) {
        try? FileManager.default.createDirectory(
            at: statusURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: statusURL.path) {
            FileManager.default.createFile(atPath: statusURL.path, contents: nil)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: statusURL.path
            )
        }
        guard let handle = cachedFileHandle(for: statusURL) else { return }
        try? handle.write(contentsOf: data)
    }

    private static func cachedFileHandle(for url: URL) -> FileHandle? {
        writerState.cachedFileHandle(for: url)
    }
}
