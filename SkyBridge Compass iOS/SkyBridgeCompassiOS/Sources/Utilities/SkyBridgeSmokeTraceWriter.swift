import Foundation

enum SkyBridgeSmokeTraceWriter {
    private struct Destination {
        let baseCaches: URL
        let fileName: String

        func url(suffix: String) -> URL {
            baseCaches.appendingPathComponent("\(fileName)\(suffix)")
        }
    }

    private struct MediaDiagnosticFields: @unchecked Sendable {
        let values: [String: Any]
    }

    private final class WriterState: @unchecked Sendable {
        private let timestampFormatter: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()
        private var cachedHandles: [String: FileHandle] = [:]

        func timestamp() -> String {
            timestampFormatter.string(from: Date())
        }

        func cachedHandle(for url: URL) -> FileHandle? {
            let key = url.path
            if let handle = cachedHandles[key] {
                return handle
            }
            guard let handle = try? FileHandle(forWritingTo: url) else {
                return nil
            }
            _ = try? handle.seekToEnd()
            cachedHandles[key] = handle
            return handle
        }
    }

    private static let writerQueue = DispatchQueue(
        label: "com.skybridge.compass.smoke-trace-writer",
        qos: .utility
    )
    private static let destination: Destination? = {
        guard ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil else { return nil }
        let fileName = ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_STATUS_BASENAME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "skybridge-smoke-status.log"
        guard !fileName.isEmpty,
              let baseCaches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        return Destination(baseCaches: baseCaches, fileName: fileName)
    }()
    private static let writerState = WriterState()

    static func appendStatus(_ line: String) {
        enqueueLine(line, suffix: "")
    }

    static func append(_ line: String) {
        enqueueLine(line, suffix: ".trace.log")
    }

    private static func enqueueLine(_ line: String, suffix: String) {
        guard let destination else { return }
        let url = destination.url(suffix: suffix)
        writerQueue.async {
            let formatted = "[\(writerState.timestamp())] \(line)\n"
            guard let data = formatted.data(using: .utf8) else { return }
            write(data, to: url)
        }
    }

    static func appendMediaDiagnostic(_ fields: [String: Any]) {
        guard let destination else { return }
        let url = destination.url(suffix: ".webrtc-media.jsonl")
        let snapshot = MediaDiagnosticFields(values: fields)
        writerQueue.async {
            var payload = snapshot.values
            payload["schema_version"] = payload["schema_version"] ?? 1
            payload["timestamp"] = payload["timestamp"] ?? writerState.timestamp()
            guard JSONSerialization.isValidJSONObject(payload),
                  let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
                return
            }
            var line = data
            line.append(0x0a)
            write(line, to: url)
        }
    }

    private static func write(_ data: Data, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path),
           let handle = cachedHandle(for: url) {
            try? handle.write(contentsOf: data)
        } else {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
            if let handle = cachedHandle(for: url) {
                try? handle.write(contentsOf: data)
            }
        }
    }

    private static func cachedHandle(for url: URL) -> FileHandle? {
        writerState.cachedHandle(for: url)
    }
}
