import Foundation

@available(iOS 17.0, *)
struct SmokeStatusReporter {
    let statusURL: URL?

    func reset() {
        guard let statusURL else { return }
        try? writeProtectedData(Data(), to: statusURL)
        SkyBridgeSmokeTraceWriter.resetListenerStatusIfConfigured()
    }

    func append(_ line: String) {
        guard let statusURL else { return }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let formatted = "[\(formatter.string(from: Date()))] \(line)\n"
        guard let data = formatted.data(using: .utf8) else { return }
        if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
            try? FileHandle.standardOutput.write(contentsOf: data)
        }
        if FileManager.default.fileExists(atPath: statusURL.path),
           let handle = try? FileHandle(forWritingTo: statusURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? writeProtectedData(data, to: statusURL)
        }
    }
}

@available(iOS 17.0, *)
func writeProtectedData(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: url.path
    )
}
