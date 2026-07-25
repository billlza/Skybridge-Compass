import Foundation
#if DEBUG || SKYBRIDGE_TESTING
import Dispatch
import Darwin
import SkyBridgeSmokeSupport
#endif

enum RemoteControlSmokeStatusWriter {
#if DEBUG || SKYBRIDGE_TESTING
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
#endif

    static func append(_ line: String) {
#if DEBUG || SKYBRIDGE_TESTING
        guard ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil else { return }
        guard let statusURL = smokeStatusURL() else { return }

        writerQueue.async {
            let rendered = "[\(writerState.timestamp())] \(line)\n"
            guard let data = rendered.data(using: .utf8) else { return }
            do {
                try write(data, to: statusURL)
            } catch {
                failStatusWrite(line: line, statusURL: statusURL, error: error)
            }
        }
#endif
    }

#if DEBUG || SKYBRIDGE_TESTING
    private static func smokeStatusURL() -> URL? {
        guard let raw = ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_STATUS_FILE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: raw)
    }

    private static func write(_ data: Data, to statusURL: URL) throws {
        try SmokeStatusFileAppender.append(data, to: statusURL)
    }

    private static func failStatusWrite(line: String, statusURL: URL, error: Error) -> Never {
        let message = [
            "SkyBridge remote-control smoke status write failed",
            "path=\(sanitize(statusURL.path))",
            "line=\(sanitize(line))",
            "error=\(sanitize(error.localizedDescription))"
        ].joined(separator: " ") + "\n"
        FileHandle.standardError.write(Data(message.utf8))
        Darwin.exit(74)
    }

    private static func sanitize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
#endif
}
