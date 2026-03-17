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
        exportAuthContextIfRequested()

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
        let requiresStreamEvidence = ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_REQUIRE_STREAM"] == "1"
        let requiresDirectPath = ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_REQUIRE_DIRECT"] == "1"
        let holdAfterSuccessSeconds = Double(ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_HOLD_AFTER_SUCCESS_SECONDS"] ?? "") ?? 0
        let timeoutSeconds = Double(ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_TIMEOUT_SECONDS"] ?? "") ?? 90
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var lastStatus = ""
        var lastReadiness = ""
        var lastRekeyEvent = ""
        var sawInitialHandshake = false
        var reportedSuccess = false
        var successAt: Date?

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
                    let evidence = smokeEvidence(statusURL: statusURL())
                    let streamSatisfied = !requiresStreamEvidence || evidence.hasStream
                    let directSatisfied = !requiresDirectPath || evidence.hasDirectPath
                    if streamSatisfied && directSatisfied {
                        reportedSuccess = true
                        successAt = Date()
                        reporter.append(
                            "success session=\(sessionId) suite=\(sanitize(negotiatedSuite)) stream=\(evidence.hasStream) direct=\(evidence.hasDirectPath)"
                        )
                    }
                }
            }

            if reportedSuccess {
                if let successAt, Date().timeIntervalSince(successAt) >= holdAfterSuccessSeconds {
                    exit(EXIT_SUCCESS)
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

    private static func smokeFileURL() -> URL? {
        guard let raw = ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_SEND_FILE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: raw)
    }

    private static func tokenURL() -> URL? {
        guard let raw = ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_TOKEN_FILE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: raw)
    }

    private static func tenantURL() -> URL? {
        guard let raw = ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_TENANT_FILE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: raw)
    }

    private static func exportAuthContextIfRequested() {
        let accessToken = AuthenticationService.shared.currentAccessToken()?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let tokenURL = tokenURL(), !accessToken.isEmpty {
            try? writeText(accessToken, to: tokenURL)
        }

        let explicitTenant = ProcessInfo.processInfo.environment["SKYBRIDGE_TENANT_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let effectiveTenant = !explicitTenant.isEmpty
            ? explicitTenant
            : (deriveTenantIdentifier(accessToken: accessToken) ?? "")
        if let tenantURL = tenantURL(), !effectiveTenant.isEmpty {
            try? writeText(effectiveTenant, to: tenantURL)
        }
    }

    private static func deriveTenantIdentifier(accessToken: String) -> String? {
        guard !accessToken.isEmpty else { return nil }
        guard let payload = accessToken.split(separator: ".").dropFirst().first else {
            return nil
        }
        var base64 = payload.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let appMetadata = object["app_metadata"] as? [String: Any]
        let userMetadata = object["user_metadata"] as? [String: Any]
        let candidates: [Any?] = [
            appMetadata?["tenant_id"],
            appMetadata?["tenantId"],
            appMetadata?["org_id"],
            appMetadata?["workspace_id"],
            userMetadata?["tenant_id"],
            userMetadata?["tenantId"],
            userMetadata?["org_id"],
            userMetadata?["workspace_id"],
            object["tenant_id"],
            object["tenantId"],
            object["sub"]
        ]
        for candidate in candidates {
            let value = String(describing: candidate ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty, value != "nil" {
                return value
            }
        }
        return nil
    }

    private static func writeText(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.appending("\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func sanitize(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }

    private static func smokeEvidence(statusURL: URL?) -> (hasStream: Bool, hasDirectPath: Bool) {
        guard let statusURL,
              let contents = try? String(contentsOf: statusURL, encoding: .utf8) else {
            return (false, false)
        }
        let hasStream = contents.contains("stream-format ")
            || contents.contains("stream-stats ")
        let hasDirectPath = contents.contains("stream-path ")
            && contents.contains("path=direct")
        return (hasStream, hasDirectPath)
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
