import Foundation
import SkyBridgeCore

@available(macOS 14.0, *)
@MainActor
@main
struct LocalWebRTCSmokeHost {
    static func main() async {
        let reporter = SmokeStatusReporter(statusURL: statusURL())
        reporter.reset()
        reporter.append("boot role=mac-host")

        let manager = CrossNetworkConnectionManager.shared
        await manager.disconnect()

        do {
            let code = try await manager.generateConnectionCode()
            if let codeURL = codeURL() {
                try writeText(code, to: codeURL)
            }
            reporter.append("code \(code)")
        } catch {
            reporter.append("failed stage=generate error=\(sanitize(error.localizedDescription))")
            exit(EXIT_FAILURE)
        }

        let expectsPQCRekey = ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_EXPECT_PQC_REKEY"] == "1"
        let timeoutSeconds = Double(ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_TIMEOUT_SECONDS"] ?? "") ?? 90
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var lastStatus = ""
        var lastReadiness = ""
        var lastRekeyEvent = ""
        var sawInitialHandshake = false
        var reportedSuccess = false

        while reportedSuccess || Date() < deadline {
            let statusDescription = String(describing: manager.connectionStatus)
            if statusDescription != lastStatus {
                lastStatus = statusDescription
                reporter.append("status \(sanitize(statusDescription))")
            }

            let readinessDescription = String(describing: manager.readiness)
            if readinessDescription != lastReadiness {
                lastReadiness = readinessDescription
                reporter.append("readiness \(sanitize(readinessDescription))")
            }

            let rekeyDescription = manager.lastRekeyEvent ?? ""
            if rekeyDescription != lastRekeyEvent, !rekeyDescription.isEmpty {
                lastRekeyEvent = rekeyDescription
                reporter.append("rekey \(sanitize(rekeyDescription))")
            }

            if case .failed(let message) = manager.connectionStatus {
                reporter.append("failed stage=handshake error=\(sanitize(message))")
                exit(EXIT_FAILURE)
            }

            if case .handshakeComplete(let sessionId, let negotiatedSuite) = manager.readiness {
                if !sawInitialHandshake {
                    sawInitialHandshake = true
                    reporter.append("handshake session=\(sessionId) suite=\(sanitize(negotiatedSuite))")
                }

                let suiteName = negotiatedSuite.uppercased()
                let isClassicBootstrap = suiteName == "X25519" || suiteName == "X25519-ED25519"
                if !reportedSuccess && (!expectsPQCRekey || !isClassicBootstrap) {
                    reportedSuccess = true
                    reporter.append("success session=\(sessionId) suite=\(sanitize(negotiatedSuite))")
                }
            }

            try? await Task.sleep(for: .milliseconds(250))
        }

        reporter.append("failed stage=timeout error=mac_smoke_timeout")
        exit(EXIT_FAILURE)
    }

    private static func statusURL() -> URL? {
        guard let raw = ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_STATUS_FILE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: raw)
    }

    private static func codeURL() -> URL? {
        guard let raw = ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_CODE_FILE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: raw)
    }

    private static func writeText(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.appending("\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func sanitize(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }
}

@available(macOS 14.0, *)
private struct SmokeStatusReporter {
    let statusURL: URL?

    func reset() {
        guard let statusURL else { return }
        try? FileManager.default.createDirectory(at: statusURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "".write(to: statusURL, atomically: true, encoding: .utf8)
    }

    func append(_ line: String) {
        guard let statusURL else { return }
        let sanitizedLine = "[\(ISO8601DateFormatter().string(from: Date()))] \(line)\n"
        if let data = sanitizedLine.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: statusURL.path),
               let handle = try? FileHandle(forWritingTo: statusURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? FileManager.default.createDirectory(at: statusURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: statusURL, options: .atomic)
            }
        }
    }
}
