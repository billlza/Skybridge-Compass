import Foundation
import CoreGraphics
import Security
import SkyBridgeCore
import SkyBridgeSmokeSupport

private func sanitizeLocalWebRTCSmokeStatusLine(_ value: String) -> String {
    let lineSafe = value
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\r", with: " ")
    return localWebRTCSmokeStatusRedactionPatterns.reduce(lineSafe) { current, rule in
        rule.regex.stringByReplacingMatches(
            in: current,
            range: NSRange(current.startIndex..<current.endIndex, in: current),
            withTemplate: rule.replacement
        )
    }
}

private let localWebRTCSmokeStatusRedactionPatterns: [(regex: NSRegularExpression, replacement: String)] = [
    (
        try! NSRegularExpression(pattern: #"(session|sessionId|code|deviceId|peerId|fingerprint|from|to)=("[^"\s]+"|[^"\s]+)"#),
        "$1=<redacted>"
    ),
    (
        try! NSRegularExpression(pattern: #"(sessionId|code): "[^"]+""#),
        "$1: \"<redacted>\""
    ),
    (
        try! NSRegularExpression(pattern: #"\bcode [A-Za-z0-9_-]{6,}\b"#),
        "code <redacted>"
    )
]

@available(macOS 14.0, *)
@MainActor
@main
struct LocalWebRTCSmokeHost {
    private static let xwingSuiteWireID: UInt16 = 0x0001
    private static let mlkem768SuiteWireID: UInt16 = 0x0101
    private static let mlkem768FSSuiteWireID: UInt16 = 0x0102

    static func main() async {
        let reporter = SmokeStatusReporter(statusURL: statusURL())
        reporter.reset()
        reporter.append("boot role=mac-host")
        reporter.append(currentDisplayModeStatus())
        do {
            reporter.append("auth-start")
            try await configureAuthContext(reporter: reporter)
            reporter.append("auth-configured")
            await SelfIdentityProvider.shared.loadOrCreate()
            reporter.append("self-identity-ready")
            try await exportLocalPQCIdentityIfRequested(reporter: reporter)
            try await preseedPeerKEMTrustIfRequested(reporter: reporter)
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
        if expectsPQCRekey {
            var smokeDefaults = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            smokeDefaults["pqc_allow_classic_fallback"] = true
            UserDefaults.standard.setVolatileDomain(smokeDefaults, forName: UserDefaults.argumentDomain)
        }
        let allowsClassicMediaSuccess =
            ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ALLOW_CLASSIC_MEDIA_SUCCESS"] == "1"
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
                if !reportedSuccess && (!expectsPQCRekey || !isClassicBootstrap || allowsClassicMediaSuccess) {
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
                    await manager.disconnect()
                    reporter.append("disconnected stage=success")
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

    private static func currentDisplayModeStatus() -> String {
        guard let mode = CGDisplayCopyDisplayMode(CGMainDisplayID()) else {
            return "display-mode current=unavailable"
        }
        return "display-mode current=\(mode.width)x\(mode.height) pixels=\(mode.pixelWidth)x\(mode.pixelHeight)"
    }

    private static func codeURL() -> URL? {
        guard let raw = ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_CODE_FILE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: raw)
    }

    private static func pqcReportURL() -> URL? {
        guard let raw = ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_PQC_REPORT_FILE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: raw)
    }

    private static func environmentValue(_ name: String) -> String? {
        guard let raw = ProcessInfo.processInfo.environment[name] else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
        try validateRegistrySmokeAuthSessionIfNeeded(session, reporter: reporter)
        reporter.append("auth-session-loaded")
        if shouldConfigureSupabaseForSmokeAuth() {
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
        } else {
            reporter.append("auth-supabase-skip-smoke")
        }
        reporter.append("auth-update-session-start")
        try await AuthenticationService.shared.updateSession(session)
        reporter.append("auth-update-session-done")
        reporter.append("auth-bind-tenant-start")
        await TenantAccessController.shared.bindAuthentication(session: session)
        reporter.append("auth-bind-tenant-done")
        configureRemoteControlNoticeIdentity(session: session, reporter: reporter)
    }

    private static func configureRemoteControlNoticeIdentity(
        session: AuthSession,
        reporter: SmokeStatusReporter
    ) {
        let displayName = session.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = displayName.isEmpty ? session.userIdentifier : displayName
        RemoteControlSecurityNoticeCenter.shared.setLocalIdentityProvider {
            RemoteControlSecurityIdentity(
                accountDisplayName: account,
                nebulaId: session.nebulaId,
                deviceId: nil,
                deviceName: Host.current().localizedName
            )
        }
        _ = RemoteControlSecurityNoticeCenter.shared.localIdentitySnapshot()
        reporter.append("remote-control-notice-identity account=\(sanitize(account)) nebula=\(sanitize(session.nebulaId ?? "missing"))")
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
        if shouldSkipStoredSessionRefreshForSmoke() {
            reporter.append("auth-refresh-skipped-smoke")
            return stored
        }
        if let refreshToken = stored.refreshToken,
           !refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           shouldRefreshAccessToken(
            stored.accessToken,
            forceRefresh: ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_FORCE_AUTH_REFRESH"] == "1"
           ) {
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

    private static func shouldConfigureSupabaseForSmokeAuth() -> Bool {
        let env = ProcessInfo.processInfo.environment
        let explicit = env["SKYBRIDGE_SMOKE_SKIP_SUPABASE_AUTH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        if ["1", "true", "yes"].contains(explicit) {
            return false
        }
        return true
    }

    private static func shouldSkipStoredSessionRefreshForSmoke() -> Bool {
        let env = ProcessInfo.processInfo.environment
        let explicit = env["SKYBRIDGE_SMOKE_SKIP_AUTH_REFRESH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        if ["1", "true", "yes"].contains(explicit) {
            return true
        }
        return false
    }

    private static func injectedAuthSession() -> AuthSession? {
        if let session = injectedAuthSessionFromJSON() {
            return session
        }
        let env = ProcessInfo.processInfo.environment
        let accessToken = (
            env["SKYBRIDGE_BEARER_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? env["SKYBRIDGE_ACCESS_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        )
        guard !accessToken.isEmpty else {
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

    private static func injectedAuthSessionFromJSON() -> AuthSession? {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["SKYBRIDGE_AUTH_SESSION_JSON"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty,
           let data = raw.data(using: .utf8),
           let session = try? JSONDecoder().decode(AuthSession.self, from: data) {
            return session
        }

        guard let rawPath = env["SKYBRIDGE_AUTH_SESSION_FILE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPath.isEmpty else {
            return nil
        }
        let url = URL(fileURLWithPath: rawPath)
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(AuthSession.self, from: data)
    }

    private static func loadStoredAuthSession() -> AuthSession? {
        if let data = loadKeychainDataViaSecurityCLI(
            service: "com.skybridge.compass.authsession",
            account: "primary"
        ) {
            return try? JSONDecoder().decode(AuthSession.self, from: data)
        }

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

    private static func validateRegistrySmokeAuthSessionIfNeeded(
        _ session: AuthSession,
        reporter: SmokeStatusReporter
    ) throws {
        guard shouldConfigureSupabaseForSmokeAuth() else {
            reporter.append("auth-registry-jwt-validation-skipped")
            return
        }
        if let error = smokeAuthJWTValidationError(session.accessToken) {
            throw NSError(
                domain: "LocalWebRTCSmokeHost",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "registry smoke auth requires a usable signed Supabase JWT: \(error)"
                ]
            )
        }
        reporter.append("auth-registry-jwt-validated")
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

    private static func shouldRefreshAccessToken(
        _ token: String,
        forceRefresh: Bool,
        skewSeconds: TimeInterval = 300
    ) -> Bool {
        if forceRefresh {
            return true
        }
        guard let claims = decodeJWTClaims(token),
              let exp = claims["exp"] as? TimeInterval else {
            return false
        }
        let expiryDate = Date(timeIntervalSince1970: exp)
        return expiryDate.timeIntervalSinceNow <= skewSeconds
    }

    private static func smokeAuthJWTValidationError(
        _ token: String,
        minimumLifetimeSeconds: TimeInterval = 300
    ) -> String? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else {
            return "expected 3 JWT segments, found \(parts.count)"
        }
        if let emptyIndex = parts.firstIndex(where: { $0.isEmpty }) {
            let labels = ["header", "payload", "signature"]
            return "\(labels[min(emptyIndex, labels.count - 1)]) segment is empty"
        }
        guard let header = decodeJWTJSONObject(parts[0]) else {
            return "JWT header is not valid base64url JSON"
        }
        guard let payload = decodeJWTJSONObject(parts[1]) else {
            return "JWT payload is not valid base64url JSON"
        }
        guard let alg = (header["alg"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !alg.isEmpty else {
            return "JWT header is missing alg"
        }
        if alg.lowercased() == "none" {
            return "JWT header alg=none is a compatibility smoke token, not a signed Supabase JWT"
        }
        guard let expiration = numericJWTClaim(payload["exp"]) else {
            return "JWT payload is missing numeric exp"
        }
        let secondsRemaining = expiration - Date().timeIntervalSince1970
        if secondsRemaining <= minimumLifetimeSeconds {
            return "JWT expires too soon for registry smoke (\(Int(secondsRemaining))s remaining)"
        }
        return nil
    }

    private static func decodeJWTClaims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        return decodeJWTJSONObject(parts[1])
    }

    private static func decodeJWTJSONObject(_ segment: Substring) -> [String: Any]? {
        var base64 = String(segment)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func numericJWTClaim(_ value: Any?) -> TimeInterval? {
        if value is Bool {
            return nil
        }
        if let value = value as? TimeInterval {
            return value
        }
        if let value = value as? Int {
            return TimeInterval(value)
        }
        if let value = value as? NSNumber {
            return value.doubleValue
        }
        return nil
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

    private struct LocalPQCReport: Encodable {
        struct PublicKeyEntry: Encodable {
            let suiteWireId: UInt16
            let publicKeyBase64: String
        }

        let deviceId: String
        let keys: [PublicKeyEntry]
    }

    private static func exportLocalPQCIdentityIfRequested(
        reporter: SmokeStatusReporter
    ) async throws {
        guard let reportURL = pqcReportURL() else { return }

        let provider = CryptoProviderFactory.make(policy: .preferPQC)
        let deviceId = await DeviceIdentityKeyManager.shared.getDeviceId()
        let keys = try await DeviceIdentityKeyManager.shared.pairingIdentityKEMPublicKeys(
            using: provider
        )
        let report = LocalPQCReport(
            deviceId: deviceId,
            keys: keys.map { key in
                LocalPQCReport.PublicKeyEntry(
                    suiteWireId: key.suiteWireId,
                    publicKeyBase64: key.publicKey.base64EncodedString()
                )
            }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        try writePrivateData(data, to: reportURL)
        reporter.append(
            "pqc-report device=\(sanitize(deviceId)) keys=\(report.keys.count) file=\(sanitize(reportURL.lastPathComponent))"
        )
    }

    private static func preseedPeerKEMTrustIfRequested(
        reporter: SmokeStatusReporter
    ) async throws {
        guard let peerDeviceID = environmentValue("SKYBRIDGE_PQC_PEER_DEVICE_ID") else {
            return
        }

        var keysBySuite: [UInt16: KEMPublicKeyInfo] = [:]
        if let xwing = try decodeBase64Key("SKYBRIDGE_PQC_PEER_XWING_PUBLIC_KEY_BASE64") {
            keysBySuite[xwingSuiteWireID] = KEMPublicKeyInfo(
                suiteWireId: xwingSuiteWireID,
                publicKey: xwing
            )
        }
        if let mlkem768 = try decodeBase64Key("SKYBRIDGE_PQC_PEER_MLKEM768_PUBLIC_KEY_BASE64") {
            keysBySuite[mlkem768SuiteWireID] = KEMPublicKeyInfo(
                suiteWireId: mlkem768SuiteWireID,
                publicKey: mlkem768
            )
            if environmentValue("SKYBRIDGE_PQC_PEER_MLKEM768FS_PUBLIC_KEY_BASE64") == nil {
                keysBySuite[mlkem768FSSuiteWireID] = KEMPublicKeyInfo(
                    suiteWireId: mlkem768FSSuiteWireID,
                    publicKey: mlkem768
                )
            }
        }
        if let mlkem768fs = try decodeBase64Key("SKYBRIDGE_PQC_PEER_MLKEM768FS_PUBLIC_KEY_BASE64") {
            keysBySuite[mlkem768FSSuiteWireID] = KEMPublicKeyInfo(
                suiteWireId: mlkem768FSSuiteWireID,
                publicKey: mlkem768fs
            )
        }

        let keys = keysBySuite.keys.sorted().compactMap { keysBySuite[$0] }
        guard !keys.isEmpty else {
            throw NSError(
                domain: "LocalWebRTCSmokeHost",
                code: 913,
                userInfo: [NSLocalizedDescriptionKey: "PQC peer preseed requested but no valid peer KEM public keys were supplied"]
            )
        }

        await PeerKEMBootstrapStore.shared.clear(deviceIds: [peerDeviceID])
        await PeerKEMBootstrapStore.shared.upsert(deviceIds: [peerDeviceID], kemPublicKeys: keys)
        let suites = keys.map { String(format: "0x%04x", $0.suiteWireId) }.joined(separator: ",")
        reporter.append("pqc-preseed device=\(sanitize(peerDeviceID)) suites=\(suites)")
    }

    private static func decodeBase64Key(_ name: String) throws -> Data? {
        guard let raw = environmentValue(name) else { return nil }
        guard let data = Data(base64Encoded: raw, options: [.ignoreUnknownCharacters]), !data.isEmpty else {
            throw NSError(
                domain: "LocalWebRTCSmokeHost",
                code: 914,
                userInfo: [NSLocalizedDescriptionKey: "Invalid base64 KEM public key in \(name)"]
            )
        }
        return data
    }

    private static func writeText(_ text: String, to url: URL) throws {
        guard let data = text.appending("\n").data(using: .utf8) else { return }
        try writePrivateData(data, to: url)
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
            || hasNativeVideoRTPEvidence(in: contents)
        let hasDirectPath = contents.contains("stream-path ")
            && contents.contains("path=direct")
        return (hasStream, hasDirectPath)
    }

    private static func hasNativeVideoRTPEvidence(in contents: String) -> Bool {
        contents.split(separator: "\n").contains { line in
            guard line.contains("native-video-tx "),
                  line.contains("state=rtpFlowing") else {
                return false
            }
            return positiveMetric("submitted", in: line)
                && (positiveMetric("framesSent", in: line)
                    || positiveMetric("packetsSent", in: line)
                    || positiveMetric("bytesSent", in: line))
        }
    }

    private static func positiveMetric(_ key: String, in line: Substring) -> Bool {
        let prefix = "\(key)="
        guard let range = line.range(of: prefix) else { return false }
        let suffix = line[range.upperBound...]
        let digits = suffix.prefix { $0 >= "0" && $0 <= "9" }
        guard let value = Int(digits) else { return false }
        return value > 0
    }
}

@available(macOS 14.0, *)
private struct SmokeStatusReporter {
    let statusURL: URL?

    func reset() {
        guard let statusURL else { return }
        try? SmokeStatusFileAppender.reset(
            at: statusURL,
            protection: .completeUntilFirstUserAuthentication
        )
    }

    func append(_ line: String) {
        guard let statusURL else { return }
        let sanitizedLine = "[\(ISO8601DateFormatter().string(from: Date()))] \(sanitizeLocalWebRTCSmokeStatusLine(line))\n"
        if let data = sanitizedLine.data(using: .utf8) {
            try? SmokeStatusFileAppender.append(
                data,
                to: statusURL,
                protection: .completeUntilFirstUserAuthentication
            )
        }
    }
}

private func writePrivateData(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: url.path
    )
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
