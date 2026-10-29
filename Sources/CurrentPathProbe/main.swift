import Foundation
import Security
import SkyBridgeCore
import SkyBridgeProtocolCore
import SkyBridgeAppleTransport

@main
struct CurrentPathProbe {
    static func main() async {
        do {
            try await run()
        } catch {
            fputs("CurrentPathProbe error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func run() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            try printUsage()
            return
        }

        switch command {
        case "status":
            try await printStatus()
        case "auth-export":
            let includeSecrets = arguments.contains("--include-secrets")
            try await exportAuthSession(includeSecrets: includeSecrets)
        case "register-current":
            let deviceName = parseStringFlag("--device-name", from: arguments)
            try await registerCurrentDevice(deviceName: deviceName)
        case "code-create":
            let ttl = parseIntFlag("--ttl", from: arguments) ?? 300
            try await createCode(validDuration: TimeInterval(ttl))
        case "bridge-connect":
            guard arguments.count >= 2 else {
                throw ProbeError.invalidArguments("bridge-connect requires a code")
            }
            let code = arguments[1]
            let stateDir = parseStringFlag("--state-dir", from: arguments)
            let timeoutSeconds = parseIntFlag("--timeout-seconds", from: arguments) ?? 45
            let holdSeconds = parseIntFlag("--hold-seconds", from: arguments) ?? 0
            try await bridgeConnect(
                code: code,
                stateDir: stateDir,
                timeoutSeconds: timeoutSeconds,
                holdSeconds: holdSeconds
            )
        case "approve-device":
            guard arguments.count >= 2 else {
                throw ProbeError.invalidArguments("approve-device requires a pending device id")
            }
            let pendingDeviceID = arguments[1]
            let pendingFingerprint = parseStringFlag("--pending-fingerprint", from: arguments)
                ?? parseStringFlag("--fingerprint", from: arguments)
            guard let pendingFingerprint, !pendingFingerprint.isEmpty else {
                throw ProbeError.invalidArguments("approve-device requires --pending-fingerprint")
            }
            let pendingAlgorithm = parseStringFlag("--pending-algorithm", from: arguments) ?? "Ed25519"
            let deviceName = parseStringFlag("--device-name", from: arguments)
            try await approveDevice(
                pendingDeviceID: pendingDeviceID,
                pendingAlgorithmRaw: pendingAlgorithm,
                pendingFingerprint: pendingFingerprint,
                deviceName: deviceName
            )
        case "code-connect":
            guard arguments.count >= 2 else {
                throw ProbeError.invalidArguments("code-connect requires a code")
            }
            let code = arguments[1]
            let stateDir = parseStringFlag("--state-dir", from: arguments)
            try await connectCode(code: code, stateDir: stateDir)
        default:
            throw ProbeError.invalidArguments("unknown command: \(command)")
        }
    }

    private static func printUsage() throws {
        let usage = """
        Usage:
          swift run CurrentPathProbe status
          swift run CurrentPathProbe auth-export [--include-secrets]
          swift run CurrentPathProbe register-current [--device-name "Bill's Mac"]
          swift run CurrentPathProbe code-create [--ttl 300]
          swift run CurrentPathProbe bridge-connect <code> [--state-dir /path/to/state] [--timeout-seconds 45] [--hold-seconds 0]
          swift run CurrentPathProbe approve-device <pending-device-id> --pending-fingerprint <fp> [--pending-algorithm Ed25519] [--device-name "Ubuntu Node"]
          swift run CurrentPathProbe code-connect <code> [--state-dir /path/to/state]
        """
        print(usage)
    }

    private static func printStatus() async throws {
        let context = try await currentContext()
        let payload: [String: Any] = [
            "has_access_token": !context.accessToken.isEmpty,
            "user_id": context.userID,
            "tenant_id": context.tenantID,
            "device_id": context.binding.deviceId,
            "protocol_signing_algorithm": context.binding.protocolSigningAlgorithm.rawValue,
            "protocol_public_key_fingerprint": context.binding.protocolPublicKeyFingerprint
        ]
        try printJSONObject(payload)
    }

    private static func exportAuthSession(includeSecrets: Bool) async throws {
        let session = try await currentAuthSession()
        var payload: [String: Any] = [
            "user_identifier": session.userIdentifier,
            "nebula_id": session.nebulaId ?? NSNull(),
            "display_name": session.displayName,
            "issued_at": rfc3339String(session.issuedAt),
            "has_access_token": !session.accessToken.isEmpty,
            "has_refresh_token": !(session.refreshToken?.isEmpty ?? true)
        ]
        if includeSecrets {
            payload["access_token"] = session.accessToken
            payload["refresh_token"] = session.refreshToken ?? NSNull()
        }
        try printJSONObject(payload)
    }

    private static func createCode(validDuration: TimeInterval) async throws {
        let context = try await currentContext()
        let signalServer = makeSignalServer(
            accessToken: context.accessToken,
            tenantID: context.tenantID,
            userID: context.userID
        )
        let admission = try await requestAdmissionLease(
            signalServer: signalServer,
            binding: context.binding,
            signingKeyHandle: context.signingKeyHandle
        )
        let deviceName = Host.current().localizedName ?? "Mac"
        let lease = try await signalServer.registerConnectionCode(
            admissionToken: admission.token,
            deviceName: deviceName,
            validDuration: validDuration
        )
        guard let wsPath = lease.wsPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !wsPath.isEmpty else {
            throw ProbeError.invalidArguments("signaling server response is missing wsPath")
        }
        try printJSONObject([
            "code": lease.code,
            "session_id": lease.sessionID,
            "expires_in": Int(lease.expiresIn),
            "signaling_server_origin": lease.signalingServerOrigin,
            "signaling_ws_path": wsPath,
            "device_id": context.binding.deviceId,
            "protocol_public_key_fingerprint": context.binding.protocolPublicKeyFingerprint
        ])
    }

    private static func registerCurrentDevice(deviceName: String?) async throws {
        let context = try await currentContext()
        let signalServer = makeSignalServer(
            accessToken: context.accessToken,
            tenantID: context.tenantID,
            userID: context.userID
        )
        let registered = try await signalServer.registerCurrentDevice(
            binding: context.binding,
            deviceName: deviceName ?? Host.current().localizedName ?? "Mac",
            expectedScope: SignalServerClient.IdentityRotationAuthenticationScope(
                tenantID: context.tenantID,
                userID: context.userID
            )
        )
        try printJSONObject([
            "tenant_id": registered.tenantId,
            "user_id": registered.userId,
            "device_id": registered.deviceId,
            "protocol_signing_algorithm": registered.protocolSigningAlgorithm.rawValue,
            "protocol_public_key_fingerprint": registered.protocolPublicKeyFingerprint,
            "device_name": registered.deviceName ?? NSNull(),
            "status": registered.status,
            "approval_method": registered.approvalMethod ?? NSNull()
        ])
    }

    private static func connectCode(code: String, stateDir: String?) async throws {
        let context = try await currentContext()
        let signalServer = makeSignalServer(
            accessToken: context.accessToken,
            tenantID: context.tenantID,
            userID: context.userID
        )
        let admission = try await requestAdmissionLease(
            signalServer: signalServer,
            binding: context.binding,
            signingKeyHandle: context.signingKeyHandle
        )
        let lookup = try await signalServer.lookupConnectionCode(admissionToken: admission.token, code: code)
        let origin = try canonicalOrigin(lookup.signalingServerOrigin)
        guard let wsURL = signalingWebSocketURL(
            origin: origin,
            wsPath: lookup.wsPath,
            sessionID: lookup.sessionID,
            token: lookup.sessionToken
        ) else {
            throw ProbeError.invalidArguments("invalid signaling websocket url")
        }
        guard let headers = signalingWebSocketHeaders(
            sessionID: lookup.sessionID,
            token: lookup.sessionToken
        ) else {
            throw ProbeError.invalidArguments("invalid signaling websocket headers")
        }

        let client = WebSocketSignalingClient(
            url: wsURL,
            sessionId: lookup.sessionID,
            generation: 1,
            additionalHeaders: headers
        )
        final class LifecycleBox: @unchecked Sendable {
            var phases: [WebSocketSignalingClient.SignalingLifecycleEvent] = []
        }
        let lifecycle = LifecycleBox()
        await client.setOnLifecycleEvent { event in
            lifecycle.phases.append(event)
        }
        try await client.connectOrThrow(timeout: .seconds(5))
        let join = WebRTCSignalingEnvelope(
            sessionId: lookup.sessionID,
            from: context.binding.deviceId,
            type: .join,
            payload: nil,
            authToken: nil
        )
        try await client.send(join)
        try await Task.sleep(for: .milliseconds(250))

        let handle = await client.currentHandleID()
        let phase = await client.currentLifecyclePhase()

        if let stateDir {
            try writeRuntimeSessionSnapshot(
                stateDir: stateDir,
                sessionID: lookup.sessionID,
                localDeviceID: context.binding.deviceId,
                remoteDeviceID: lookup.initiatorDeviceId,
                remoteDeviceName: lookup.initiatorDeviceName,
                remoteFingerprint: lookup.initiatorProtocolPublicKeyFingerprint,
                signalingOrigin: origin,
                handle: handle,
                phase: phase
            )
        }

        let lifecycleEvents: [[String: Any]] = lifecycle.phases.map { event in
            [
                "phase": event.phase.rawValue,
                "generation": event.handleId.generation,
                "backend": event.handleId.backend.rawValue,
                "failure_class": event.failureClass?.rawValue ?? NSNull(),
                "error_description": event.errorDescription ?? NSNull()
            ]
        }
        let payload: [String: Any] = [
            "session_id": lookup.sessionID,
            "signaling_server_origin": origin,
            "lifecycle_phase": phase.rawValue,
            "bound": phase == .bound,
            "handle_backend": handle?.backend.rawValue ?? "unknown",
            "handle_generation": handle?.generation ?? 0,
            "remote_device_id": lookup.initiatorDeviceId,
            "remote_device_name": lookup.initiatorDeviceName ?? NSNull(),
            "remote_protocol_public_key_fingerprint": lookup.initiatorProtocolPublicKeyFingerprint,
            "lifecycle_events": lifecycleEvents
        ]
        try printJSONObject(payload)
    }

    private static func bridgeConnect(
        code: String,
        stateDir: String?,
        timeoutSeconds: Int,
        holdSeconds: Int
    ) async throws {
        setenv("SKYBRIDGE_CLIENT_VERSION", resolvedClientVersion(), 1)
        setenv("SKYBRIDGE_PROTOCOL_VERSION", resolvedProtocolVersion(), 1)
        let session = try await currentAuthSession()
        let localBinding = try await currentPathLocalBinding()
        try await configureCrossNetworkManagerAuth(session: session)

        let manager = await MainActor.run { CrossNetworkConnectionManager.shared }
        await manager.disconnect()

        let connection = try await manager.connectWithCode(code)
        let sessionID = connection.id
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        let holdDeadline: Date? = holdSeconds > 0 ? Date().addingTimeInterval(TimeInterval(holdSeconds)) : nil
        var readinessHistory: [String] = []
        var lastBridgeState: BridgeRuntimeState?
        var handshakeObserved = false

        while Date() < deadline {
            let bridgeState = await readBridgeRuntimeState(sessionID: sessionID)
            if readinessHistory.last != bridgeState.readinessLabel {
                readinessHistory.append(bridgeState.readinessLabel)
            }
            if let stateDir {
                try writeBridgeRuntimeSessionSnapshot(
                    stateDir: stateDir,
                    sessionID: sessionID,
                    localDeviceID: localBinding.deviceId,
                    signalingOrigin: bridgeState.signalingOrigin,
                    bridgeState: bridgeState
                )
            }
            lastBridgeState = bridgeState

            if bridgeState.handshakeComplete {
                handshakeObserved = true
                if holdDeadline == nil {
                    break
                }
            }
            if let failure = bridgeState.failureDescription {
                throw ProbeError.invalidArguments("bridge connect failed: \(failure)")
            }
            if let holdDeadline, handshakeObserved, Date() >= holdDeadline {
                break
            }
            try await Task.sleep(for: .milliseconds(250))
        }

        guard let lastBridgeState else {
            throw ProbeError.invalidArguments("bridge connect did not produce runtime state")
        }

        let payload: [String: Any] = [
            "session_id": sessionID,
            "transport_ready": lastBridgeState.transportReady,
            "handshake_complete": lastBridgeState.handshakeComplete,
            "negotiated_suite": lastBridgeState.negotiatedSuite ?? NSNull(),
            "remote_device_id": lastBridgeState.remoteDeviceID ?? NSNull(),
            "remote_device_name": lastBridgeState.remoteDeviceName ?? NSNull(),
            "signaling_health": normalizePhase(lastBridgeState.signalingHealth.rawValue),
            "lifecycle_phase": normalizePhase(lastBridgeState.signalingLifecyclePhase.rawValue),
            "readiness_history": readinessHistory,
            "hold_seconds": holdSeconds
        ]
        try printJSONObject(payload)
    }

    private static func approveDevice(
        pendingDeviceID: String,
        pendingAlgorithmRaw: String,
        pendingFingerprint: String,
        deviceName: String?
    ) async throws {
        let context = try await currentContext()
        guard let pendingAlgorithm = parseProtocolSigningAlgorithm(pendingAlgorithmRaw) else {
            throw ProbeError.invalidArguments("unsupported pending algorithm: \(pendingAlgorithmRaw)")
        }

        let endpoint = try confirmEnrollmentURL()
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(resolvedClientAPIKey(), forHTTPHeaderField: "X-API-Key")
        request.setValue(context.tenantID, forHTTPHeaderField: "X-SkyBridge-Tenant-Id")
        request.setValue("Bearer \(context.accessToken)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "deviceId": context.binding.deviceId,
            "protocolSigningAlgorithm": context.binding.protocolSigningAlgorithm.rawValue,
            "protocolPublicKeyFingerprint": context.binding.protocolPublicKeyFingerprint,
            "clientVersion": resolvedClientVersion(),
            "protocolVersion": resolvedProtocolVersion(),
            "pendingDeviceId": pendingDeviceID,
            "pendingProtocolSigningAlgorithm": pendingAlgorithm.rawValue,
            "pendingProtocolPublicKeyFingerprint": pendingFingerprint,
            "deviceName": deviceName ?? "Approved Device"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProbeError.invalidArguments("enroll confirm returned non-http response")
        }
        guard (200...299).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? "unknown_error"
            throw ProbeError.invalidArguments("enroll confirm failed (\(http.statusCode)): \(bodyText)")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProbeError.invalidArguments("enroll confirm returned malformed json")
        }
        try printJSONObject(object)
    }

    private struct BridgeReadinessState: Sendable {
        let type: String
        let sessionID: String?
        let negotiatedSuite: String?

        func asJSONObject() -> [String: Any] {
            var object: [String: Any] = ["type": type]
            if let sessionID {
                object["session_id"] = sessionID
            }
            if let negotiatedSuite {
                object["negotiated_suite"] = negotiatedSuite
            }
            return object
        }
    }

    private struct BridgeRuntimeState: Sendable {
        let signalingOrigin: String
        let readinessLabel: String
        let readiness: BridgeReadinessState
        let transportReady: Bool
        let handshakeComplete: Bool
        let negotiatedSuite: String?
        let remoteDeviceID: String?
        let remoteDeviceName: String?
        let signalingHealth: SignalingSessionHealth
        let signalingLifecyclePhase: WebSocketSignalingClient.SignalingLifecyclePhase
        let failureDescription: String?
    }

    private static func configureCrossNetworkManagerAuth(session: AuthSession) async throws {
        if let config = loadSupabaseConfig(),
           let url = URL(string: config.url) {
            await MainActor.run {
                AuthenticationService.shared.enableSupabaseMode(
                    supabaseConfig: SupabaseService.Configuration(url: url, anonKey: config.anonKey)
                )
            }
        }
        try await AuthenticationService.shared.updateSession(session)
        await TenantAccessController.shared.bindAuthentication(session: session)
    }

    private static func readBridgeRuntimeState(sessionID: String) async -> BridgeRuntimeState {
        await MainActor.run {
            let manager = CrossNetworkConnectionManager.shared
            let managerReadiness = manager.readiness
            let snapshot = manager.activeSessionSnapshot
            let signalingHealth = manager.signalingHealth
            let signalingLifecyclePhase = manager.signalingLifecyclePhase
            let signalingOrigin = resolvedSignalingServerBaseURL()

            let readiness: BridgeReadinessState
            let readinessLabel: String
            let transportReady: Bool
            let handshakeComplete: Bool
            let negotiatedSuite: String?
            switch managerReadiness {
            case .idle:
                readinessLabel = "idle"
                readiness = BridgeReadinessState(type: "idle", sessionID: nil, negotiatedSuite: nil)
                transportReady = false
                handshakeComplete = false
                negotiatedSuite = nil
            case .transportReady(let activeSessionID):
                readinessLabel = "transport_ready"
                readiness = BridgeReadinessState(
                    type: "transport_ready",
                    sessionID: activeSessionID,
                    negotiatedSuite: nil
                )
                transportReady = activeSessionID == sessionID
                handshakeComplete = false
                negotiatedSuite = nil
            case .handshakeComplete(let activeSessionID, let suite):
                readinessLabel = "handshake_complete"
                readiness = BridgeReadinessState(
                    type: "handshake_complete",
                    sessionID: activeSessionID,
                    negotiatedSuite: suite
                )
                transportReady = activeSessionID == sessionID
                handshakeComplete = activeSessionID == sessionID
                negotiatedSuite = activeSessionID == sessionID ? suite : nil
            }

            let failureDescription: String?
            switch manager.connectionStatus {
            case .failed(let message):
                failureDescription = message
            default:
                failureDescription = nil
            }

            return BridgeRuntimeState(
                signalingOrigin: signalingOrigin,
                readinessLabel: readinessLabel,
                readiness: readiness,
                transportReady: transportReady,
                handshakeComplete: handshakeComplete,
                negotiatedSuite: negotiatedSuite ?? snapshot?.negotiatedSuite,
                remoteDeviceID: snapshot?.deviceId,
                remoteDeviceName: snapshot?.deviceName ?? manager.currentConnection?.deviceName,
                signalingHealth: signalingHealth,
                signalingLifecyclePhase: signalingLifecyclePhase,
                failureDescription: failureDescription
            )
        }
    }

    private struct Context {
        let accessToken: String
        let userID: String
        let tenantID: String
        let binding: ProtocolIdentityBinding
        let signingKeyHandle: SigningKeyHandle
    }

    private struct CurrentPathLocalIdentity {
        let binding: ProtocolIdentityBinding
        let signingKeyHandle: SigningKeyHandle
    }

    private static func currentContext() async throws -> Context {
        debug("loading auth session")
        let authSession = try await currentAuthSession()
        let accessToken = authSession.accessToken
        debug("auth session loaded")
        let tenantID = deriveTenantIdentifier(accessToken: accessToken)
        guard !tenantID.isEmpty else {
            throw ProbeError.invalidArguments("failed to derive tenant id from current session")
        }
        debug("resolving local binding")
        let localIdentity = try await currentPathLocalIdentity()
        debug("local binding resolved")
        let userID = authSession.userIdentifier.isEmpty
            ? deriveUserIdentifier(accessToken: accessToken)
            : authSession.userIdentifier
        guard !userID.isEmpty else {
            throw ProbeError.invalidArguments("failed to derive user id from current session")
        }
        return Context(
            accessToken: accessToken,
            userID: userID,
            tenantID: tenantID,
            binding: localIdentity.binding,
            signingKeyHandle: localIdentity.signingKeyHandle
        )
    }

    private static func currentAuthSession() async throws -> AuthSession {
        guard let stored = loadStoredAuthSession() else {
            throw ProbeError.missingSession
        }
        debug("stored auth session found")
        if let refreshToken = stored.refreshToken,
           shouldRefreshAccessToken(stored.accessToken),
           let refreshed = try await refreshSupabaseSession(refreshToken: refreshToken, previous: stored) {
            debug("auth session refreshed through direct supabase token endpoint")
            try? persistStoredAuthSession(refreshed)
            return refreshed
        }
        return stored
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
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(AuthSession.self, from: data)
    }

    private static func persistStoredAuthSession(_ session: AuthSession) throws {
        let data = try JSONEncoder().encode(session)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.skybridge.compass.authsession",
            kSecAttrAccount as String: "primary"
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status: OSStatus
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        } else {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw ProbeError.invalidArguments("failed to persist refreshed auth session: \(status)")
        }
    }

    private struct StoredSupabaseConfig {
        let url: String
        let anonKey: String
    }

    private static func loadSupabaseConfig() -> StoredSupabaseConfig? {
        guard let url = loadKeychainString(service: "SkyBridge.Supabase", account: "URL"),
              let anonKey = loadKeychainString(service: "SkyBridge.Supabase", account: "AnonKey") else {
            return nil
        }
        return StoredSupabaseConfig(url: url, anonKey: anonKey)
    }

    private static func loadKeychainString(service: String, account: String) -> String? {
        if let data = loadKeychainDataViaSecurityCLI(service: service, account: account),
           let string = String(data: data, encoding: .utf8) {
            return string
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    private static func loadKeychainDataViaSecurityCLI(service: String, account: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "find-generic-password",
            "-s", service,
            "-a", account,
            "-w"
        ]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            debug("security CLI launch failed for \(service)/\(account): \(error.localizedDescription)")
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
        guard !raw.isEmpty else { return nil }

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

    private static func refreshSupabaseSession(refreshToken: String, previous: AuthSession) async throws -> AuthSession? {
        guard let config = loadSupabaseConfig(),
              var components = URLComponents(string: config.url + "/auth/v1/token") else {
            return nil
        }
        components.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token")]
        guard let endpoint = components.url else { return nil }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken])
        let (data, response) = try await URLSession.shared.data(for: request)
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

    private static func shouldRefreshAccessToken(_ token: String, skewSeconds: TimeInterval = 300) -> Bool {
        guard let claims = decodeJWTClaims(token),
              let exp = claims["exp"] as? TimeInterval else {
            return false
        }
        let expiryDate = Date(timeIntervalSince1970: exp)
        return expiryDate.timeIntervalSinceNow <= skewSeconds
    }

    private static func decodeJWTClaims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func currentPathLocalBinding() async throws -> ProtocolIdentityBinding {
        try await currentPathLocalIdentity().binding
    }

    private static func currentPathLocalIdentity() async throws -> CurrentPathLocalIdentity {
        let identity = try await CommittedLocalProtocolIdentitySnapshot.loadActive()
        let selfIdentity = try await SelfIdentityProvider.shared
            .snapshotEnsuringProtocolDeviceId(allowCreate: true)
        let binding = try ProtocolIdentityBinding(
            deviceId: selfIdentity.deviceId,
            protocolSigningAlgorithm: identity.algorithm,
            protocolPublicKeyBytes: identity.publicKey
        )
        return CurrentPathLocalIdentity(
            binding: binding,
            signingKeyHandle: identity.keyHandle
        )
    }

    private static func requestAdmissionLease(
        signalServer: SignalServerClient,
        binding: ProtocolIdentityBinding,
        signingKeyHandle: SigningKeyHandle
    ) async throws -> SignalServerClient.AdmissionLease {
        let challenge = try await signalServer.requestAdmissionChallenge(binding: binding)
        let signatureProvider = ProtocolSignatureProviderSelector.select(for: binding.protocolSigningAlgorithm)
        let signature = try await signatureProvider.sign(
            challenge.signaturePayload(),
            key: signingKeyHandle
        )
        return try await signalServer.completeAdmission(
            challenge: challenge,
            binding: binding,
            signature: signature
        )
    }

    private static func makeSignalServer(
        accessToken: String,
        tenantID: String,
        userID: String
    ) -> SignalServerClient {
        SignalServerClient(
            authenticatedRequestContextProvider: {
                SignalServerClient.AuthenticatedRequestContext(
                    bearerToken: accessToken,
                    tenantID: tenantID,
                    userID: userID
                )
            },
            tenantIDProvider: { tenantID },
            clientVersionProvider: { resolvedClientVersion() },
            protocolVersionProvider: { resolvedProtocolVersion() }
        )
    }

    private static func deriveTenantIdentifier(accessToken: String?) -> String {
        let explicit = ProcessInfo.processInfo.environment["SKYBRIDGE_TENANT_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !explicit.isEmpty { return explicit }
        guard let accessToken, !accessToken.isEmpty else { return "" }
        guard let payload = accessToken.split(separator: ".").dropFirst().first else { return "" }
        var base64 = payload.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ""
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
        return ""
    }

    private static func deriveUserIdentifier(accessToken: String?) -> String {
        guard let accessToken, !accessToken.isEmpty else { return "" }
        guard let payload = accessToken.split(separator: ".").dropFirst().first else { return "" }
        var base64 = payload.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ""
        }
        return (object["sub"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func confirmEnrollmentURL() throws -> URL {
        guard var components = URLComponents(string: resolvedSignalingServerBaseURL()) else {
            throw ProbeError.invalidArguments("invalid signaling base url")
        }
        components.path += "/api/devices/enroll/confirm"
        guard let url = components.url else {
            throw ProbeError.invalidArguments("invalid enroll confirm url")
        }
        return url
    }

    private static func resolvedSignalingServerBaseURL() -> String {
        if let value = ProcessInfo.processInfo.environment["SKYBRIDGE_SIGNALING_SERVER_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        if let value = ProcessInfo.processInfo.environment["SKYBRIDGE_SIGNALING_BASE_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        return "https://api.nebula-technologies.net"
    }

    private static func resolvedClientAPIKey() -> String {
        if let value = ProcessInfo.processInfo.environment["SKYBRIDGE_CLIENT_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        return "skybridge-client-v1"
    }

    private static func canonicalOrigin(_ raw: String) throws -> String {
        try CurrentPathOriginPolicy.canonicalOrigin(raw)
    }

    private static func signalingWebSocketURL(origin: String, wsPath: String?, sessionID: String, token: String) -> URL? {
        CrossNetworkConnectionManager.currentPathSignalingWebSocketURL(
            signalingServerOrigin: origin,
            wsPath: wsPath,
            sessionID: sessionID,
            sessionToken: token,
            clientVersion: resolvedClientVersion(),
            protocolVersion: resolvedProtocolVersion()
        )
    }

    private static func signalingWebSocketHeaders(sessionID: String, token: String) -> [String: String]? {
        CrossNetworkConnectionManager.currentPathSignalingWebSocketHeaders(
            sessionID: sessionID,
            sessionToken: token,
            clientVersion: resolvedClientVersion(),
            protocolVersion: resolvedProtocolVersion()
        )
    }

    private static func resolvedClientVersion() -> String {
        if let value = ProcessInfo.processInfo.environment["SKYBRIDGE_CLIENT_VERSION"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        if let value = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty,
               trimmed != "0.0.0",
               trimmed != "0.1.0" {
                return trimmed
            }
        }
        // SwiftPM probes do not carry the app Info.plist, so pin the release floor here.
        return "1.0.0"
    }

    private static func resolvedProtocolVersion() -> String {
        if let value = ProcessInfo.processInfo.environment["SKYBRIDGE_PROTOCOL_VERSION"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        return "1"
    }

    private static func parseStringFlag(_ name: String, from args: [String]) -> String? {
        guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else {
            return nil
        }
        return args[index + 1]
    }

    private static func parseIntFlag(_ name: String, from args: [String]) -> Int? {
        guard let raw = parseStringFlag(name, from: args) else { return nil }
        return Int(raw)
    }

    private static func printJSONObject(_ payload: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw ProbeError.invalidArguments("failed to encode json")
        }
        print(text)
    }

    private static func debug(_ message: String) {
        guard ProcessInfo.processInfo.environment["CURRENT_PATH_PROBE_DEBUG"] == "1" else { return }
        fputs("[CurrentPathProbe] \(message)\n", stderr)
    }

    private static func parseProtocolSigningAlgorithm(_ raw: String) -> ProtocolSigningAlgorithm? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = ProtocolSigningAlgorithm(rawValue: trimmed) {
            return exact
        }
        switch trimmed.lowercased() {
        case "ed25519":
            return .ed25519
        case "ml-dsa-65", "mldsa65":
            return .mlDSA65
        default:
            return nil
        }
    }

    private static func rfc3339String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func writeRuntimeSessionSnapshot(
        stateDir: String,
        sessionID: String,
        localDeviceID: String,
        remoteDeviceID: String,
        remoteDeviceName: String?,
        remoteFingerprint: String,
        signalingOrigin: String,
        handle: WebSocketSignalingClient.SignalingHandleID?,
        phase: WebSocketSignalingClient.SignalingLifecyclePhase
    ) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let backend = handle.map { normalizeBackend($0.backend.rawValue) }
        let record: [String: Any] = [
            "runtime_id": "current-path-probe-\(UUID().uuidString.lowercased())",
            "session_id": sessionID,
            "role": "responder",
            "source": "code",
            "signaling_server_origin": signalingOrigin,
            "local_device_id": localDeviceID,
            "remote_device_id": remoteDeviceID,
            "remote_device_name": remoteDeviceName ?? NSNull(),
            "remote_protocol_public_key_fingerprint": remoteFingerprint,
            "state": phase == .bound ? "bound" : "connecting",
            "lifecycle_phase": normalizePhase(phase.rawValue),
            "signaling_health": "healthy",
            "signaling_backend": backend ?? NSNull(),
            "signaling_generation": handle?.generation ?? NSNull(),
            "readiness": ["type": "idle"],
            "transport_preserved": false,
            "last_error": NSNull(),
            "last_transport_error": NSNull(),
            "created_at": now,
            "updated_at": now,
            "closed_at": NSNull()
        ]
        try mergeRuntimeSessionRecord(stateDir: stateDir, sessionID: sessionID, record: record)
    }

    private static func writeBridgeRuntimeSessionSnapshot(
        stateDir: String,
        sessionID: String,
        localDeviceID: String,
        signalingOrigin: String,
        bridgeState: BridgeRuntimeState
    ) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let lifecyclePhase = normalizePhase(bridgeState.signalingLifecyclePhase.rawValue)
        let signalingHealth = normalizePhase(bridgeState.signalingHealth.rawValue)
        let transportPreserved = bridgeState.transportReady && lifecyclePhase != "bound"
        let runtimeState: String
        if bridgeState.transportReady {
            runtimeState = lifecyclePhase == "bound" ? "bound" : "degraded"
        } else {
            switch lifecyclePhase {
            case "bound":
                runtimeState = "bound"
            case "failed":
                runtimeState = "failed"
            case "closed", "closing":
                runtimeState = "disconnected"
            case "connecting", "socket_open", "reconnecting":
                runtimeState = "connecting"
            default:
                runtimeState = "pending"
            }
        }

        let record: [String: Any] = [
            "runtime_id": "current-path-probe-\(UUID().uuidString.lowercased())",
            "session_id": sessionID,
            "role": "responder",
            "source": "code",
            "signaling_server_origin": signalingOrigin,
            "local_device_id": localDeviceID,
            "remote_device_id": bridgeState.remoteDeviceID ?? NSNull(),
            "remote_device_name": bridgeState.remoteDeviceName ?? NSNull(),
            "remote_protocol_public_key_fingerprint": NSNull(),
            "state": runtimeState,
            "lifecycle_phase": lifecyclePhase,
            "signaling_health": signalingHealth,
            "signaling_backend": NSNull(),
            "signaling_generation": NSNull(),
            "readiness": bridgeState.readiness.asJSONObject(),
            "transport_preserved": transportPreserved,
            "last_error": bridgeState.failureDescription ?? NSNull(),
            "last_transport_error": runtimeState == "disconnected" ? ((bridgeState.failureDescription ?? NSNull()) as Any) : NSNull(),
            "created_at": now,
            "updated_at": now,
            "closed_at": (runtimeState == "disconnected" || runtimeState == "failed") ? now : NSNull()
        ]
        try mergeRuntimeSessionRecord(stateDir: stateDir, sessionID: sessionID, record: record)
    }

    private static func mergeRuntimeSessionRecord(
        stateDir: String,
        sessionID: String,
        record: [String: Any]
    ) throws {
        let runtimeDir = URL(fileURLWithPath: stateDir, isDirectory: true).appendingPathComponent("runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeDir, withIntermediateDirectories: true)
        let sessionsURL = runtimeDir.appendingPathComponent("sessions.json")

        var root: [String: Any] = [
            "schema_version": 1,
            "sessions": [String: Any]()
        ]
        if let data = try? Data(contentsOf: sessionsURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = existing
        }

        var sessions = root["sessions"] as? [String: Any] ?? [:]
        let existingRecord = sessions[sessionID] as? [String: Any] ?? [:]
        var merged = existingRecord
        for (key, value) in record {
            merged[key] = value
        }
        if existingRecord["runtime_id"] != nil {
            merged["runtime_id"] = existingRecord["runtime_id"]
        }
        if existingRecord["created_at"] != nil {
            merged["created_at"] = existingRecord["created_at"]
        }
        sessions[sessionID] = merged
        root["schema_version"] = 1
        root["sessions"] = sessions
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try writePrivateData(data, to: sessionsURL)
    }

    private static func normalizePhase(_ raw: String) -> String {
        switch raw {
        case "socketOpen":
            return "socket_open"
        default:
            return raw.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1_$2", options: .regularExpression)
                .lowercased()
        }
    }

    private static func normalizeBackend(_ raw: String) -> String {
        switch raw {
        case "urlSession":
            return "url_session"
        default:
            return raw.lowercased()
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

private enum ProbeError: LocalizedError {
    case missingSession
    case invalidArguments(String)

    var errorDescription: String? {
        switch self {
        case .missingSession:
            return "No current authenticated session found in the app keychain"
        case .invalidArguments(let message):
            return message
        }
    }
}
