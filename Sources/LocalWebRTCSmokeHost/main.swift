import Foundation
import CoreGraphics
import Darwin
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
            try await SelfIdentityProvider.shared.loadOrCreate()
            reporter.append("self-identity-ready")
            try await exportLocalPQCIdentityIfRequested(reporter: reporter)
            try await preseedPeerKEMTrustIfRequested(reporter: reporter)
        } catch {
            reporter.append("failed stage=auth error=\(sanitize(error.localizedDescription))")
            exit(EXIT_FAILURE)
        }
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
                    let evidence: (hasStream: Bool, hasDirectPath: Bool)
                    do {
                        evidence = try await smokeEvidence(statusURL: statusURL())
                    } catch {
                        reporter.append(
                            "failed stage=evidence-read error=\(sanitize(error.localizedDescription))"
                        )
                        exit(EXIT_FAILURE)
                    }
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

            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                reporter.append("failed stage=runtime error=smoke_task_cancelled")
                exit(EXIT_FAILURE)
            }
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

    private struct StoredSupabaseConfig {
        let url: String
        let anonKey: String
    }

    private static func configureAuthContext(reporter: SmokeStatusReporter) async throws {
        reporter.append("auth-session-load-start")
        let session = try await currentAuthSession(reporter: reporter)
        try validateRegistrySmokeAuthSessionIfNeeded(session, reporter: reporter)
        let effectiveTenantID = try CrossNetworkConnectionManager.resolveTenantIdentifier(
            accessToken: session.accessToken,
            explicitTenantID: ProcessInfo.processInfo.environment["SKYBRIDGE_TENANT_ID"],
            sessionTenantID: session.nebulaId,
            sessionUserIdentifier: session.userIdentifier
        )
        guard !effectiveTenantID.isEmpty else {
            throw NSError(
                domain: "LocalWebRTCSmokeHost",
                code: 925,
                userInfo: [NSLocalizedDescriptionKey: "authenticated smoke session has no bound tenant identity"]
            )
        }
        reporter.append("auth-session-loaded")
        if shouldConfigureSupabaseForSmokeAuth() {
            guard let config = try loadSupabaseConfig(),
                  let url = URL(string: config.url),
                  url.scheme?.lowercased() == "https",
                  url.host?.isEmpty == false else {
                throw NSError(
                    domain: "LocalWebRTCSmokeHost",
                    code: 931,
                    userInfo: [NSLocalizedDescriptionKey: "registry smoke requires a complete HTTPS Supabase configuration"]
                )
            }
            reporter.append("auth-supabase-enable-start")
            await MainActor.run {
                AuthenticationService.shared.enableSupabaseMode(
                    supabaseConfig: SupabaseService.Configuration(url: url, anonKey: config.anonKey)
                )
            }
            reporter.append("auth-supabase-enable-done")
        } else {
            reporter.append("auth-supabase-skip-smoke")
        }
        reporter.append("auth-update-session-start")
        try await AuthenticationService.shared.updateSession(session)
        reporter.append("auth-update-session-done")
        reporter.append("auth-bind-tenant-start")
        await TenantAccessController.shared.bindAuthentication(session: session)
        reporter.append("auth-bind-tenant-done")
        configureRemoteControlNoticeIdentity(
            session: session,
            effectiveTenantID: effectiveTenantID,
            reporter: reporter
        )
    }

    private static func configureRemoteControlNoticeIdentity(
        session: AuthSession,
        effectiveTenantID: String,
        reporter: SmokeStatusReporter
    ) {
        let displayName = session.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = displayName.isEmpty ? session.userIdentifier : displayName
        RemoteControlSecurityNoticeCenter.shared.setLocalIdentityProvider {
            RemoteControlSecurityIdentity(
                accountDisplayName: account,
                nebulaId: effectiveTenantID,
                deviceId: nil,
                deviceName: Host.current().localizedName
            )
        }
        _ = RemoteControlSecurityNoticeCenter.shared.localIdentitySnapshot()
        reporter.append("remote-control-notice-identity account=present nebula=present")
    }

    private static func currentAuthSession(reporter: SmokeStatusReporter) async throws -> AuthSession {
        if let injected = try injectedAuthSession() {
            reporter.append("auth-session-env-present")
            return injected
        }

        guard let stored = try loadStoredAuthSession() else {
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
            let refreshed = try await refreshSupabaseSession(
                refreshToken: refreshToken,
                previous: stored
            )
            reporter.append("auth-refresh-ok")
            return refreshed
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

    private static func injectedAuthSession() throws -> AuthSession? {
        if let session = try injectedAuthSessionFromJSON() {
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

    private static func injectedAuthSessionFromJSON() throws -> AuthSession? {
        let env = ProcessInfo.processInfo.environment
        let inlineJSON = env["SKYBRIDGE_AUTH_SESSION_JSON"]
        let filePath = env["SKYBRIDGE_AUTH_SESSION_FILE"]
        if inlineJSON != nil, filePath != nil {
            throw NSError(
                domain: "LocalWebRTCSmokeHost",
                code: 917,
                userInfo: [NSLocalizedDescriptionKey: "smoke auth session has multiple configured authorities"]
            )
        }
        if let inlineJSON {
            guard inlineJSON == inlineJSON.trimmingCharacters(in: .whitespacesAndNewlines),
                  !inlineJSON.isEmpty,
                  inlineJSON.utf8.count <= 1_048_576,
                  let data = inlineJSON.data(using: .utf8) else {
                throw NSError(
                    domain: "LocalWebRTCSmokeHost",
                    code: 918,
                    userInfo: [NSLocalizedDescriptionKey: "inline smoke auth session is malformed"]
                )
            }
            return try decodeInjectedAuthSession(data)
        }

        guard let filePath else { return nil }
        let rawPath = filePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPath.isEmpty, rawPath == filePath else {
            throw NSError(
                domain: "LocalWebRTCSmokeHost",
                code: 919,
                userInfo: [NSLocalizedDescriptionKey: "smoke auth-session file path is malformed"]
            )
        }
        let url = URL(fileURLWithPath: rawPath)
        let data = try readPrivateAuthSessionFile(at: url)
        return try decodeInjectedAuthSession(data)
    }

    private static func decodeInjectedAuthSession(_ data: Data) throws -> AuthSession {
        do {
            return try JSONDecoder().decode(AuthSession.self, from: data)
        } catch {
            throw NSError(
                domain: "LocalWebRTCSmokeHost",
                code: 920,
                userInfo: [NSLocalizedDescriptionKey: "smoke auth-session document is malformed"]
            )
        }
    }

    private static func readPrivateAuthSessionFile(at url: URL) throws -> Data {
        let maximumByteCount = 1_048_576
        var pathMetadata = stat()
        guard lstat(url.path, &pathMetadata) == 0,
              (pathMetadata.st_mode & S_IFMT) == S_IFREG,
              pathMetadata.st_uid == geteuid(),
              pathMetadata.st_nlink == 1,
              (pathMetadata.st_mode & mode_t(0o777)) == mode_t(0o600),
              pathMetadata.st_size > 0,
              pathMetadata.st_size <= maximumByteCount else {
            throw NSError(
                domain: "LocalWebRTCSmokeHost",
                code: 921,
                userInfo: [NSLocalizedDescriptionKey: "smoke auth-session file must be a private bounded regular file"]
            )
        }

        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw NSError(
                domain: "LocalWebRTCSmokeHost",
                code: 922,
                userInfo: [NSLocalizedDescriptionKey: "unable to open private smoke auth-session file"]
            )
        }
        defer { close(descriptor) }

        var openedMetadata = stat()
        guard fstat(descriptor, &openedMetadata) == 0,
              (openedMetadata.st_mode & S_IFMT) == S_IFREG,
              openedMetadata.st_dev == pathMetadata.st_dev,
              openedMetadata.st_ino == pathMetadata.st_ino,
              openedMetadata.st_uid == geteuid(),
              openedMetadata.st_nlink == 1,
              (openedMetadata.st_mode & mode_t(0o777)) == mode_t(0o600),
              openedMetadata.st_size == pathMetadata.st_size else {
            throw NSError(
                domain: "LocalWebRTCSmokeHost",
                code: 923,
                userInfo: [NSLocalizedDescriptionKey: "smoke auth-session file changed while it was opened"]
            )
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var data = Data()
        while data.count <= maximumByteCount {
            let remaining = maximumByteCount + 1 - data.count
            guard remaining > 0,
                  let chunk = try handle.read(upToCount: min(64 * 1_024, remaining)),
                  !chunk.isEmpty else {
                break
            }
            data.append(chunk)
        }
        guard data.count == Int(openedMetadata.st_size) else {
            throw NSError(
                domain: "LocalWebRTCSmokeHost",
                code: 924,
                userInfo: [NSLocalizedDescriptionKey: "smoke auth-session file changed while it was read"]
            )
        }
        return data
    }

    private static func loadStoredAuthSession() throws -> AuthSession? {
        guard let data = try loadKeychainData(
            service: "com.skybridge.compass.authsession",
            account: "primary"
        ) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(AuthSession.self, from: data)
        } catch {
            throw NSError(
                domain: "LocalWebRTCSmokeHost",
                code: 926,
                userInfo: [NSLocalizedDescriptionKey: "stored auth session is malformed"]
            )
        }
    }

    private static func loadSupabaseConfig() throws -> StoredSupabaseConfig? {
        let env = ProcessInfo.processInfo.environment
        let environmentURL = env["SKYBRIDGE_SMOKE_SUPABASE_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let environmentAnonKey = env["SKYBRIDGE_SMOKE_SUPABASE_ANON_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if environmentURL != nil || environmentAnonKey != nil {
            guard let url = environmentURL,
                  let anonKey = environmentAnonKey,
                  !url.isEmpty,
                  !anonKey.isEmpty else {
                throw NSError(
                    domain: "LocalWebRTCSmokeHost",
                    code: 927,
                    userInfo: [NSLocalizedDescriptionKey: "Supabase smoke configuration is incomplete"]
                )
            }
            return StoredSupabaseConfig(url: url, anonKey: anonKey)
        }

        let keychainURL = try loadKeychainString(service: "SkyBridge.Supabase", account: "URL")
        let keychainAnonKey = try loadKeychainString(service: "SkyBridge.Supabase", account: "AnonKey")
        if keychainURL == nil, keychainAnonKey == nil {
            return nil
        }
        guard let url = keychainURL,
              let anonKey = keychainAnonKey,
              !url.isEmpty,
              !anonKey.isEmpty else {
            throw NSError(
                domain: "LocalWebRTCSmokeHost",
                code: 928,
                userInfo: [NSLocalizedDescriptionKey: "stored Supabase configuration is incomplete"]
            )
        }
        return StoredSupabaseConfig(url: url, anonKey: anonKey)
    }

    private static func loadKeychainString(service: String, account: String) throws -> String? {
        guard let data = try loadKeychainData(service: service, account: account) else {
            return nil
        }
        guard let value = String(data: data, encoding: .utf8) else {
            throw NSError(
                domain: "LocalWebRTCSmokeHost",
                code: 929,
                userInfo: [NSLocalizedDescriptionKey: "stored Keychain text is not UTF-8"]
            )
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func loadKeychainData(service: String, account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Keychain lookup failed"]
            )
        }
        guard let data = item as? Data else {
            throw NSError(
                domain: "LocalWebRTCSmokeHost",
                code: 930,
                userInfo: [NSLocalizedDescriptionKey: "Keychain lookup returned an invalid value type"]
            )
        }
        guard !data.isEmpty, data.count <= 1_048_576 else {
            throw NSError(
                domain: "LocalWebRTCSmokeHost",
                code: 937,
                userInfo: [NSLocalizedDescriptionKey: "Keychain value size is invalid"]
            )
        }
        return data
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
        guard session.accessToken.utf8.count <= 64 * 1_024,
              (session.refreshToken?.utf8.count ?? 0) <= 64 * 1_024 else {
            throw NSError(
                domain: "LocalWebRTCSmokeHost",
                code: 938,
                userInfo: [NSLocalizedDescriptionKey: "registry smoke credentials exceed the size limit"]
            )
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
    ) async throws -> AuthSession {
        let normalizedRefreshToken = refreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedRefreshToken.isEmpty, normalizedRefreshToken.utf8.count <= 64 * 1_024 else {
            throw NSError(
                domain: "LocalWebRTCSmokeHost",
                code: 939,
                userInfo: [NSLocalizedDescriptionKey: "auth refresh token is malformed"]
            )
        }
        guard let config = try loadSupabaseConfig(),
              var components = URLComponents(string: config.url + "/auth/v1/token"),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false else {
            throw NSError(
                domain: "LocalWebRTCSmokeHost",
                code: 932,
                userInfo: [NSLocalizedDescriptionKey: "auth refresh requires a complete HTTPS Supabase configuration"]
            )
        }
        components.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token")]
        guard let endpoint = components.url else {
            throw NSError(
                domain: "LocalWebRTCSmokeHost",
                code: 933,
                userInfo: [NSLocalizedDescriptionKey: "auth refresh endpoint is malformed"]
            )
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["refresh_token": normalizedRefreshToken]
        )

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.waitsForConnectivity = false
        sessionConfig.timeoutIntervalForRequest = 15
        sessionConfig.timeoutIntervalForResource = 20
        let session = URLSession(configuration: sessionConfig)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(
                domain: "LocalWebRTCSmokeHost",
                code: 934,
                userInfo: [NSLocalizedDescriptionKey: "auth refresh was rejected"]
            )
        }
        guard !data.isEmpty, data.count <= 64 * 1_024 else {
            throw NSError(
                domain: "LocalWebRTCSmokeHost",
                code: 935,
                userInfo: [NSLocalizedDescriptionKey: "auth refresh response size is invalid"]
            )
        }

        let decoded = try JSONDecoder().decode(RefreshResponse.self, from: data)
        let refreshedAccessToken = decoded.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let refreshedRefreshToken = decoded.refreshToken?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !refreshedAccessToken.isEmpty,
              refreshedAccessToken.utf8.count <= 64 * 1_024,
              (refreshedRefreshToken?.utf8.count ?? 0) <= 64 * 1_024 else {
            throw NSError(
                domain: "LocalWebRTCSmokeHost",
                code: 936,
                userInfo: [NSLocalizedDescriptionKey: "auth refresh returned malformed credentials"]
            )
        }
        return AuthSession(
            accessToken: refreshedAccessToken,
            refreshToken: refreshedRefreshToken?.isEmpty == false
                ? refreshedRefreshToken
                : previous.refreshToken,
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
        let deviceId = try await DeviceIdentityKeyManager.shared.getDeviceId()
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
        if let xwing = try decodeBase64Key(
            "SKYBRIDGE_PQC_PEER_XWING_PUBLIC_KEY_BASE64",
            expectedByteCount: 1_216
        ) {
            keysBySuite[xwingSuiteWireID] = KEMPublicKeyInfo(
                suiteWireId: xwingSuiteWireID,
                publicKey: xwing
            )
        }
        if let mlkem768 = try decodeBase64Key(
            "SKYBRIDGE_PQC_PEER_MLKEM768_PUBLIC_KEY_BASE64",
            expectedByteCount: 1_184
        ) {
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
        if let mlkem768fs = try decodeBase64Key(
            "SKYBRIDGE_PQC_PEER_MLKEM768FS_PUBLIC_KEY_BASE64",
            expectedByteCount: 1_184
        ) {
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

    private static func decodeBase64Key(
        _ name: String,
        expectedByteCount: Int
    ) throws -> Data? {
        guard let raw = environmentValue(name) else { return nil }
        guard raw.utf8.count <= 4_096,
              let data = Data(base64Encoded: raw),
              data.count == expectedByteCount else {
            throw NSError(
                domain: "LocalWebRTCSmokeHost",
                code: 914,
                userInfo: [NSLocalizedDescriptionKey: "Invalid base64 or KEM public-key length in \(name)"]
            )
        }
        return data
    }

    private static func writeText(_ text: String, to url: URL) throws {
        guard let data = text.appending("\n").data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try writePrivateData(data, to: url)
    }

    private static func sanitize(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }

    private static func smokeEvidence(
        statusURL: URL?
    ) async throws -> (hasStream: Bool, hasDirectPath: Bool) {
        guard let statusURL else {
            return (false, false)
        }
        let contents = try await Task.detached(priority: .utility) {
            try readBoundedPrivateUTF8File(at: statusURL, maximumByteCount: 8 * 1_024 * 1_024)
        }.value
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
        do {
            try SmokeStatusFileAppender.reset(
                at: statusURL,
                protection: .completeUntilFirstUserAuthentication
            )
        } catch {
            failStatusWrite(operation: "reset", error: error)
        }
    }

    func append(_ line: String) {
        guard let statusURL else { return }
        let sanitizedLine = "[\(ISO8601DateFormatter().string(from: Date()))] \(sanitizeLocalWebRTCSmokeStatusLine(line))\n"
        guard let data = sanitizedLine.data(using: .utf8) else {
            failStatusWrite(
                operation: "encode",
                error: CocoaError(.fileWriteInapplicableStringEncoding)
            )
        }
        do {
            try SmokeStatusFileAppender.append(
                data,
                to: statusURL,
                protection: .completeUntilFirstUserAuthentication
            )
        } catch {
            failStatusWrite(operation: "append", error: error)
        }
    }

    private func failStatusWrite(operation: String, error: Error) -> Never {
        let message = "Local WebRTC smoke status \(operation) failed: \(String(reflecting: type(of: error)))\n"
        FileHandle.standardError.write(Data(message.utf8))
        exit(EXIT_FAILURE)
    }
}

private func writePrivateData(_ data: Data, to url: URL) throws {
    guard !data.isEmpty, data.count <= 1_048_576 else {
        throw POSIXError(.EFBIG)
    }
    try validatePrivateParentDirectory(url.deletingLastPathComponent())

    let descriptor = open(
        url.path,
        O_WRONLY | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
        mode_t(0o600)
    )
    guard descriptor >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { close(descriptor) }

    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
          (metadata.st_mode & S_IFMT) == S_IFREG,
          metadata.st_uid == geteuid(),
          metadata.st_nlink == 1,
          (metadata.st_mode & mode_t(0o777)) == mode_t(0o600),
          ftruncate(descriptor, 0) == 0,
          lseek(descriptor, 0, SEEK_SET) == 0 else {
        throw CocoaError(.fileWriteNoPermission)
    }
    try writeAll(data, to: descriptor)
    guard fsync(descriptor) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    var pathMetadata = stat()
    guard lstat(url.path, &pathMetadata) == 0,
          pathMetadata.st_dev == metadata.st_dev,
          pathMetadata.st_ino == metadata.st_ino else {
        throw CocoaError(.fileWriteUnknown)
    }
}

private func readBoundedPrivateUTF8File(at url: URL, maximumByteCount: Int) throws -> String {
    guard maximumByteCount > 0 else { throw POSIXError(.EINVAL) }
    try validatePrivateParentDirectory(url.deletingLastPathComponent())

    var pathMetadata = stat()
    guard lstat(url.path, &pathMetadata) == 0,
          (pathMetadata.st_mode & S_IFMT) == S_IFREG,
          pathMetadata.st_uid == geteuid(),
          pathMetadata.st_nlink == 1,
          (pathMetadata.st_mode & mode_t(0o777)) == mode_t(0o600),
          pathMetadata.st_size >= 0,
          pathMetadata.st_size <= off_t(maximumByteCount) else {
        throw CocoaError(.fileReadNoPermission)
    }

    let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { close(descriptor) }

    var openedMetadata = stat()
    guard fstat(descriptor, &openedMetadata) == 0,
          openedMetadata.st_dev == pathMetadata.st_dev,
          openedMetadata.st_ino == pathMetadata.st_ino,
          openedMetadata.st_uid == geteuid(),
          openedMetadata.st_nlink == 1,
          (openedMetadata.st_mode & mode_t(0o777)) == mode_t(0o600) else {
        throw CocoaError(.fileReadNoPermission)
    }

    let expectedByteCount = Int(openedMetadata.st_size)
    var data = Data()
    data.reserveCapacity(expectedByteCount)
    var buffer = [UInt8](repeating: 0, count: min(64 * 1_024, max(1, expectedByteCount)))
    while data.count < expectedByteCount {
        let requested = min(buffer.count, expectedByteCount - data.count)
        let count = buffer.withUnsafeMutableBytes { rawBuffer in
            Darwin.read(descriptor, rawBuffer.baseAddress, requested)
        }
        if count > 0 {
            data.append(contentsOf: buffer.prefix(count))
            continue
        }
        if count < 0, errno == EINTR { continue }
        throw CocoaError(.fileReadCorruptFile)
    }
    guard let contents = String(data: data, encoding: .utf8) else {
        throw CocoaError(.fileReadInapplicableStringEncoding)
    }
    return contents
}

private func validatePrivateParentDirectory(_ url: URL) throws {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0,
          (metadata.st_mode & S_IFMT) == S_IFDIR,
          metadata.st_uid == geteuid(),
          (metadata.st_mode & mode_t(0o777)) == mode_t(0o700) else {
        throw CocoaError(.fileWriteNoPermission)
    }
}

private func writeAll(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { buffer in
        guard let baseAddress = buffer.baseAddress else { return }
        var offset = 0
        while offset < buffer.count {
            let result = Darwin.write(
                descriptor,
                baseAddress.advanced(by: offset),
                buffer.count - offset
            )
            if result > 0 {
                offset += result
                continue
            }
            if result < 0, errno == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
