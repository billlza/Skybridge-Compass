import Foundation
import Dispatch
import SkyBridgeSmokeSupport

enum RemoteControlSmokeStatusWriter {
    private final class WriterState: @unchecked Sendable {
        private let timestampFormatter: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()

        func timestamp() -> String {
            timestampFormatter.string(from: Date())
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
        try? SmokeStatusFileAppender.append(data, to: statusURL)
    }
}
