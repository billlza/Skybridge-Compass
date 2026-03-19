import Foundation
import Security
import SkyBridgeCore

@available(macOS 14.0, *)
@MainActor
@main
struct LocalWebRTCSmokeHost {
    static func main() async {
        let reporter = SmokeStatusReporter(statusURL: statusURL())
        reporter.reset()
        reporter.append("boot role=mac-host")
        do {
            reporter.append("auth-start")
            try await configureAuthContext(reporter: reporter)
            reporter.append("auth-configured")
            await SelfIdentityProvider.shared.loadOrCreate()
            reporter.append("self-identity-ready")
        } catch {
            reporter.append("failed stage=auth error=\(sanitize(error.localizedDescription))")
            exit(EXIT_FAILURE)
        }
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

    private struct StoredSupabaseConfig {
        let url: String
        let anonKey: String
    }

    private static func configureAuthContext(reporter: SmokeStatusReporter) async throws {
        reporter.append("auth-session-load-start")
        let session = try await currentAuthSession(reporter: reporter)
        reporter.append("auth-session-loaded")
        if let config = loadSupabaseConfig(),
           let url = URL(string: config.url) {
            reporter.append("auth-supabase-enable-start")
            await MainActor.run {
                AuthenticationService.shared.enableSupabaseMode(
                    supabaseConfig: SupabaseService.Configuration(url: url, anonKey: config.anonKey)
                )
            }
            reporter.append("auth-supabase-enable-done")
        }
        reporter.append("auth-update-session-start")
        try await MainActor.run {
            try AuthenticationService.shared.updateSession(session)
        }
        reporter.append("auth-update-session-done")
        reporter.append("auth-bind-tenant-start")
        await TenantAccessController.shared.bindAuthentication(session: session)
        reporter.append("auth-bind-tenant-done")
    }

    private static func currentAuthSession(reporter: SmokeStatusReporter) async throws -> AuthSession {
        if let injected = injectedAuthSession() {
            reporter.append("auth-session-env-present")
            return injected
        }

        guard let stored = loadStoredAuthSession() else {
            throw NSError(
                domain: "LocalWebRTCSmokeHost",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "missing auth session in keychain"]
            )
        }
        reporter.append("auth-session-keychain-present")
        if let refreshToken = stored.refreshToken,
           !refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            reporter.append("auth-refresh-start")
            do {
                if let refreshed = try await refreshSupabaseSession(refreshToken: refreshToken, previous: stored) {
                    reporter.append("auth-refresh-ok")
                    return refreshed
                }
                reporter.append("auth-refresh-empty")
            } catch {
                reporter.append("auth-refresh-fallback error=\(sanitize(error.localizedDescription))")
            }
        }
        reporter.append("auth-refresh-skip-using-stored")
        return stored
    }

    private static func injectedAuthSession() -> AuthSession? {
        let env = ProcessInfo.processInfo.environment
        guard let accessToken = env["SKYBRIDGE_BEARER_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty else {
            return nil
        }

        let refreshToken = env["SKYBRIDGE_REFRESH_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let userIdentifier = env["SKYBRIDGE_USER_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? deriveUserIdentifier(accessToken: accessToken)
            ?? deriveTenantIdentifier(accessToken: accessToken)
            ?? "smoke-user"
        let displayName = env["SKYBRIDGE_DISPLAY_NAME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "Smoke Host"
        let nebulaId = env["SKYBRIDGE_NEBULA_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return AuthSession(
            accessToken: accessToken,
            refreshToken: refreshToken?.isEmpty == true ? nil : refreshToken,
            userIdentifier: userIdentifier,
            nebulaId: nebulaId?.isEmpty == true ? nil : nebulaId,
            displayName: displayName,
            issuedAt: Date()
        )
    }

    private static func loadStoredAuthSession() -> AuthSession? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.skybridge.compass.authsession",
            kSecAttrAccount as String: "primary",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data {
            return try? JSONDecoder().decode(AuthSession.self, from: data)
        }

        if let data = loadKeychainDataViaSecurityCLI(
            service: "com.skybridge.compass.authsession",
            account: "primary"
        ) {
            return try? JSONDecoder().decode(AuthSession.self, from: data)
        }
        return nil
    }

    private static func loadSupabaseConfig() -> StoredSupabaseConfig? {
        let env = ProcessInfo.processInfo.environment
        if let url = env["SKYBRIDGE_SMOKE_SUPABASE_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let anonKey = env["SKYBRIDGE_SMOKE_SUPABASE_ANON_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !url.isEmpty,
           !anonKey.isEmpty {
            return StoredSupabaseConfig(url: url, anonKey: anonKey)
        }
        guard let url = loadKeychainString(service: "SkyBridge.Supabase", account: "URL"),
              let anonKey = loadKeychainString(service: "SkyBridge.Supabase", account: "AnonKey") else {
            return nil
        }
        return StoredSupabaseConfig(url: url, anonKey: anonKey)
    }

    private static func loadKeychainString(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess,
           let data = item as? Data,
           let value = String(data: data, encoding: .utf8) {
            return value
        }

        if let data = loadKeychainDataViaSecurityCLI(service: service, account: account),
           let value = String(data: data, encoding: .utf8) {
            return value
        }
        return nil
    }

    private static func loadKeychainDataViaSecurityCLI(service: String, account: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "find-generic-password",
            "-s", service,
            "-a", account,
            "-w",
        ]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return nil
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }

        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        return decodeSecurityCLIPasswordOutput(output)
    }

    private static func decodeSecurityCLIPasswordOutput(_ raw: Data) -> Data? {
        let trimmed = raw.trimmingTrailingWhitespaceAndNewlines()
        guard !trimmed.isEmpty else { return nil }

        if let text = String(data: trimmed, encoding: .utf8),
           isHexEncoded(text),
           let decoded = decodeHex(text) {
            return decoded
        }
        return trimmed
    }

    private static func isHexEncoded(_ text: String) -> Bool {
        !text.isEmpty
            && text.count.isMultiple(of: 2)
            && text.unicodeScalars.allSatisfy { scalar in
                CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains(scalar)
            }
    }

    private static func decodeHex(_ text: String) -> Data? {
        var bytes = Data(capacity: text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let value = UInt8(text[index..<next], radix: 16) else {
                return nil
            }
            bytes.append(value)
            index = next
        }
        return bytes
    }

    private struct RefreshResponse: Decodable {
        let accessToken: String
        let refreshToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
        }
    }

    private static func refreshSupabaseSession(
        refreshToken: String,
        previous: AuthSession
    ) async throws -> AuthSession? {
        guard let config = loadSupabaseConfig(),
              var components = URLComponents(string: config.url + "/auth/v1/token") else {
            return nil
        }
        components.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token")]
        guard let endpoint = components.url else { return nil }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["refresh_token": refreshToken]
        )

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.waitsForConnectivity = false
        sessionConfig.timeoutIntervalForRequest = 15
        sessionConfig.timeoutIntervalForResource = 20
        let session = URLSession(configuration: sessionConfig)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return nil
        }

        let decoded = try JSONDecoder().decode(RefreshResponse.self, from: data)
        return AuthSession(
            accessToken: decoded.accessToken,
            refreshToken: decoded.refreshToken ?? previous.refreshToken,
            userIdentifier: previous.userIdentifier,
            nebulaId: previous.nebulaId,
            displayName: previous.displayName,
            issuedAt: Date()
        )
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

    private static func deriveUserIdentifier(accessToken: String) -> String? {
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
        return (object["sub"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

private extension Data {
    func trimmingTrailingWhitespaceAndNewlines() -> Data {
        var slice = self[...]
        while let last = slice.last, last == 0x0a || last == 0x0d || last == 0x20 || last == 0x09 {
            slice = slice.dropLast()
        }
        return Data(slice)
    }
}
