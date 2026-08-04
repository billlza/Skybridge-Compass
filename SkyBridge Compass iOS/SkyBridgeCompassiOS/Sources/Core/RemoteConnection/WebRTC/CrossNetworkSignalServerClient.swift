import Foundation
import OSLog
import SkyBridgeRealtimeMedia

@available(iOS 17.0, macOS 14.0, *)
actor SignalServerClientCompat {
    struct AdmissionChallenge: Sendable, Equatable {
        let challengeID: String
        let nonce: String
        let tenantID: String
        let userID: String
        let deviceID: String
        let clientIPHash: String
        let clientVersion: String
        let protocolVersion: String
        let state: String
        let issuedAt: Date
        let expiresAt: Date

        func signaturePayload() -> Data {
            Data([
                "SkyBridge-Admission-Challenge",
                challengeID,
                nonce,
                tenantID,
                userID,
                deviceID,
                clientVersion,
                protocolVersion
            ].joined(separator: "\n").utf8)
        }
    }

    struct AdmissionLease: Sendable, Equatable {
        let token: String
        let state: String
        let issuedAt: Date
        let expiresAt: Date
    }

    struct SessionLease: Sendable, Equatable {
        let sessionID: String
        let sessionToken: String
        let qrBootstrapToken: String
        let turnAdmissionToken: String
        let mediaAdmissionToken: String?
        let expiresIn: TimeInterval
        let signalingServerOrigin: String
        let wsPath: String?
    }

    struct SessionRefreshLease: Sendable, Equatable {
        let sessionID: String
        let role: String
        let sessionToken: String
        let turnAdmissionToken: String
        let mediaAdmissionToken: String?
        let expiresIn: TimeInterval
        let signalingServerOrigin: String
        let wsPath: String
        let serverBuildFingerprint: String?
        let sessionTokenGeneration: String?
        let mediaTokenGeneration: String?
    }

    struct RedeemedSessionLease: Sendable, Equatable {
        let sessionID: String
        let sessionToken: String
        let turnAdmissionToken: String
        let mediaAdmissionToken: String?
        let expiresIn: TimeInterval
        let signalingServerOrigin: String
        let wsPath: String?
        let initiatorDeviceId: String
        let initiatorProtocolSigningAlgorithm: ProtocolSigningAlgorithm
        let initiatorProtocolPublicKeyFingerprint: String
    }

    struct ConnectionCodeLease: Sendable, Equatable {
        let code: String
        let sessionID: String
        let sessionToken: String
        let turnAdmissionToken: String
        let mediaAdmissionToken: String?
        let expiresIn: TimeInterval
        let signalingServerOrigin: String
        let wsPath: String?
    }

    struct ConnectionCodeLookup: Sendable, Equatable {
        let sessionID: String
        let sessionToken: String
        let turnAdmissionToken: String
        let mediaAdmissionToken: String?
        let expiresIn: TimeInterval
        let signalingServerOrigin: String
        let wsPath: String?
        let initiatorDeviceId: String
        let initiatorProtocolSigningAlgorithm: ProtocolSigningAlgorithm
        let initiatorProtocolPublicKeyFingerprint: String
        let initiatorDeviceName: String?
    }

    struct IdentityRotationChallenge: Sendable, Equatable {
        let transcript: DeviceIdentityRotationTranscriptCompat
        let issuedAtMilliseconds: Int64
        let clientVersion: String
        let protocolVersion: String

        init(
            transcript: DeviceIdentityRotationTranscriptCompat,
            issuedAtMilliseconds: Int64,
            clientVersion: String,
            protocolVersion: String
        ) throws {
            guard issuedAtMilliseconds > 0,
                  issuedAtMilliseconds < transcript.expiresAtMilliseconds,
                  Self.isCanonicalVersion(clientVersion),
                  Self.isCanonicalVersion(protocolVersion) else {
                throw ClientError.malformedResponse(
                    "invalid identity rotation challenge metadata"
                )
            }
            self.transcript = transcript
            self.issuedAtMilliseconds = issuedAtMilliseconds
            self.clientVersion = clientVersion
            self.protocolVersion = protocolVersion
        }

        private static func isCanonicalVersion(_ raw: String) -> Bool {
            raw == raw.trimmingCharacters(in: .whitespacesAndNewlines)
                && !raw.isEmpty
                && raw.utf8.count <= 128
                && !raw.unicodeScalars.contains(
                    where: CharacterSet.controlCharacters.contains
                )
        }
    }

    struct IdentityRotationCommitReceipt: Sendable, Equatable {
        let rotationID: String
        let committedAtMilliseconds: Int64
        let generation: UInt64
        let oldGraceExpiresAtMilliseconds: Int64
        let oldIdentity: ProtocolIdentityBindingCompat
        let newIdentity: ProtocolIdentityBindingCompat
    }

    struct IdentityRotationAuthenticationScope: Sendable, Equatable {
        let tenantID: String
        let userID: String
    }

    struct RegisteredCurrentDevice: Sendable, Equatable {
        let tenantID: String
        let userID: String
        let deviceID: String
        let protocolSigningAlgorithm: ProtocolSigningAlgorithm
        let protocolPublicKeyFingerprint: String
        let deviceName: String?
        let status: String
        let approvalMethod: String?
        let activated: Bool
    }

    enum ClientError: LocalizedError {
        case invalidBaseURL
        case invalidResponse
        case missingAuthentication
        case missingTenantID
        case missingTenantClaim
        case tenantIdentityMismatch
        case userIdentityMismatch
        case invalidAuthenticationClaims
        case conflictingTenantClaims
        case authenticationSessionChanged
        case missingIdempotencyKey
        case invalidDeviceName
        case authenticationStorageUnavailable(String)
        case invalidRequestLimits
        case requestTimedOut(String)
        case resourceDeadlineExceeded(String)
        case responseTooLarge(path: String, limitBytes: Int)
        case serverRejected(Int, String)
        case malformedResponse(String)

        var errorDescription: String? {
            switch self {
            case .invalidBaseURL:
                return "信令服务器地址无效"
            case .invalidResponse:
                return "信令服务器返回了非 HTTP 响应"
            case .missingAuthentication:
                return "缺少上游登录态，无法申请 admission"
            case .missingTenantID:
                return "缺少租户标识，无法访问当前租户的公网能力"
            case .missingTenantClaim:
                return "认证令牌缺少可绑定的租户声明"
            case .tenantIdentityMismatch:
                return "认证令牌与当前租户身份不一致"
            case .userIdentityMismatch:
                return "认证令牌与当前用户身份不一致"
            case .invalidAuthenticationClaims:
                return "认证令牌包含无效的身份声明"
            case .conflictingTenantClaims:
                return "认证令牌包含互相冲突的租户声明"
            case .authenticationSessionChanged:
                return "认证会话在令牌刷新期间发生变化，请重新发起请求"
            case .missingIdempotencyKey:
                return "缺少幂等键，无法安全执行当前跨网请求"
            case .invalidDeviceName:
                return "当前设备名称不是规范的可注册名称"
            case .authenticationStorageUnavailable(let reason):
                return "认证会话存储不可用: \(reason)"
            case .invalidRequestLimits:
                return "当前跨网请求资源边界配置无效"
            case .requestTimedOut(let path):
                return "当前跨网请求超时: \(path)"
            case .resourceDeadlineExceeded(let path):
                return "当前跨网请求超过总资源时限: \(path)"
            case .responseTooLarge(let path, let limitBytes):
                return "当前跨网响应超过大小上限: \(path) limit=\(limitBytes)"
            case .serverRejected(let status, _):
                return "信令服务器拒绝请求 (\(status)): \(SignalServerClientCompat.redactedServerRejectedBodyDescription)"
            case .malformedResponse(let reason):
                return "信令服务器响应格式错误: \(reason)"
            }
        }
    }

    nonisolated private static let sensitiveLogRedaction = "<redacted>"
    nonisolated private static let redactedServerRejectedBodyDescription = "<redacted-server-error-body>"
    nonisolated private static let maximumAuthenticationTokenBytes = 65_536
    nonisolated private static let safeServerRejectedBodyStringKeys: Set<String> = [
        "code",
        "error",
        "mediaTokenExpectedGeneration",
        "mediaTokenGeneration",
        "mediaTokenRequestGeneration",
        "mediaTokenRevokedReason",
        "mediaTokenState",
        "reason",
        "rejectReason",
        "serverBuildFingerprint"
    ]
    nonisolated private static let safeServerRejectedBodyBooleanKeys: Set<String> = [
        "mediaTokenExpectedPresent",
        "mediaTokenSessionPresent"
    ]

    nonisolated private static func redactedServerRejectedBodyLogSummary(byteCount: Int) -> String {
        "\(redactedServerRejectedBodyDescription) bytes=\(byteCount)"
    }

    nonisolated private static func sanitizedServerRejectedBodyDescription(from data: Data) -> String {
        let redactedSummary = redactedServerRejectedBodyLogSummary(byteCount: data.count)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return redactedSummary
        }

        var summary: [String: Any] = ["bodyBytes": data.count]
        for key in safeServerRejectedBodyStringKeys {
            guard let value = object[key] as? String,
                  isSafeServerRejectedBodyStringValue(key: key, value: value) else {
                continue
            }
            summary[key] = value
        }
        for key in safeServerRejectedBodyBooleanKeys {
            if let value = object[key] as? Bool {
                summary[key] = value
            }
        }

        guard summary.count > 1,
              let jsonData = try? JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]),
              let json = String(data: jsonData, encoding: .utf8) else {
            return redactedSummary
        }
        return json
    }

    nonisolated static func isUncommittedIdentityRotationExpired(
        _ error: Error
    ) -> Bool {
        guard let clientError = error as? ClientError,
              case ClientError.serverRejected(410, let summary) = clientError,
              let data = summary.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
            return false
        }
        return object["error"] as? String == "rotation_expired"
            || object["code"] as? String == "rotation_expired"
    }

    nonisolated private static func isSafeServerRejectedBodyStringValue(key: String, value: String) -> Bool {
        switch key {
        case "mediaTokenExpectedGeneration", "mediaTokenGeneration", "mediaTokenRequestGeneration":
            return isSafeMediaTokenGenerationPrefix(value)
        case "serverBuildFingerprint":
            return isSafeServerBuildFingerprint(value)
        default:
            return isSafeServerRejectedBodyToken(value)
        }
    }

    nonisolated private static func isSafeMediaTokenGenerationPrefix(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == value, value.count == 16 else { return false }
        return value.range(of: #"^[A-Fa-f0-9]{16}$"#, options: .regularExpression) != nil
    }

    nonisolated private static func isSafeServerBuildFingerprint(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == value, (1...128).contains(value.count) else { return false }
        return value.range(of: #"^[A-Za-z0-9_.:/@+-]+$"#, options: .regularExpression) != nil
    }

    nonisolated private static func isSafeServerRejectedBodyToken(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == value, (1...96).contains(value.count) else { return false }
        return value.range(of: #"^[A-Za-z0-9_.:-]+$"#, options: .regularExpression) != nil
    }

    private struct AdmissionChallengeRequestBody: Encodable {
        let deviceId: String
        let protocolSigningAlgorithm: String
        let protocolPublicKeyFingerprint: String
        let clientVersion: String
        let protocolVersion: String
    }

    private struct AdmissionChallengeResponseBody: Decodable {
        let challengeId: String
        let nonce: String
        let tenantId: String
        let userId: String
        let deviceId: String
        let clientIpHash: String
        let clientVersion: String
        let protocolVersion: String
        let state: String
        let issuedAt: Int64
        let expiresAt: Int64
    }

    private struct AdmissionRequestBody: Encodable {
        let challengeId: String
        let signature: Data
        let deviceId: String
        let protocolSigningAlgorithm: String
        let protocolPublicKeyFingerprint: String
        let protocolPublicKeyBytes: Data
        let clientVersion: String
        let protocolVersion: String
    }

    private struct AdmissionResponseBody: Decodable {
        let admissionToken: String
        let state: String
        let issuedAt: Int64
        let expiresAt: Int64
    }

    private struct RegisterCurrentDeviceRequestBody: Encodable {
        let deviceId: String
        let protocolSigningAlgorithm: String
        let protocolPublicKeyFingerprint: String
        let clientVersion: String
        let protocolVersion: String
        let deviceName: String
    }

    private struct RegisteredCurrentDeviceResponseBody: Decodable {
        struct Device: Decodable {
            let tenantID: String
            let userID: String
            let deviceID: String
            let protocolSigningAlgorithm: String
            let protocolPublicKeyFingerprint: String
            let deviceName: String?
            let status: String
            let approvalMethod: String?

            enum CodingKeys: String, CodingKey {
                case tenantID = "tenant_id"
                case userID = "user_id"
                case deviceID = "device_id"
                case protocolSigningAlgorithm = "protocol_signing_algorithm"
                case protocolPublicKeyFingerprint = "protocol_public_key_fingerprint"
                case deviceName = "device_name"
                case status
                case approvalMethod = "approval_method"
            }
        }

        let registered: Bool
        let activated: Bool
        let device: Device
    }

    private struct IdentityRotationChallengeRequestBody: Encodable {
        let deviceId: String
        let protocolSigningAlgorithm: String
        let protocolPublicKeyFingerprint: String
        let protocolPublicKeyBytes: Data
        let newProtocolSigningAlgorithm: String
        let newProtocolPublicKeyFingerprint: String
        let newProtocolPublicKeyBytes: Data
        let clientVersion: String
        let protocolVersion: String
    }

    private struct IdentityRotationChallengeResponseBody: Decodable {
        let requestId: String
        let rotationId: String
        let nonce: String
        let state: String
        let issuedAt: Int64
        let expiresAt: Int64
        let transcriptVersion: Int
        let transcriptHash: String
        let transcriptBase64: String
        let tenantId: String
        let userId: String
        let deviceId: String
        let oldGeneration: UInt64
        let oldProtocolSigningAlgorithm: String
        let oldProtocolPublicKeyFingerprint: String
        let newProtocolSigningAlgorithm: String
        let newProtocolPublicKeyFingerprint: String
    }

    private struct IdentityRotationCommitRequestBody: Encodable {
        let deviceId: String
        let protocolSigningAlgorithm: String
        let protocolPublicKeyFingerprint: String
        let rotationId: String
        let transcriptHash: String
        let oldSignature: Data
        let newSignature: Data
        let clientVersion: String
        let protocolVersion: String
    }

    private struct IdentityRotationCommitResponseBody: Decodable {
        struct Identity: Decodable {
            let protocolSigningAlgorithm: String
            let protocolPublicKeyFingerprint: String
            let state: String
            let graceExpiresAt: Int64?
        }

        let committed: Bool
        let rotationId: String
        let state: String
        let committedAt: Int64
        let generation: UInt64
        let deviceId: String
        let oldIdentity: Identity
        let newIdentity: Identity
    }

    private struct RegisterSessionRequestBody: Encodable {
        let sessionId: String?
        let ttlSeconds: Int
    }

    private struct RegisterSessionResponseBody: Decodable {
        let sessionId: String
        let sessionToken: String
        let qrBootstrapToken: String
        let turnAdmissionToken: String
        let mediaAdmissionToken: String?
        let expiresIn: Int
        let signalingServerOrigin: String
        let wsPath: String?
    }

    private struct RedeemSessionRequestBody: Encodable {
        let sessionId: String
        let qrBootstrapToken: String
    }

    private struct SessionRefreshRequestBody: Encodable {
        let sessionId: String
        let role: String
    }

    private struct RedeemSessionResponseBody: Decodable {
        let sessionId: String
        let sessionToken: String
        let turnAdmissionToken: String
        let mediaAdmissionToken: String?
        let expiresIn: Int
        let signalingServerOrigin: String
        let wsPath: String?
        let initiatorDeviceId: String
        let initiatorProtocolSigningAlgorithm: String
        let initiatorProtocolPublicKeyFingerprint: String
    }

    private struct SessionRefreshResponseBody: Decodable {
        let sessionId: String
        let role: String
        let sessionToken: String
        let turnAdmissionToken: String
        let mediaAdmissionToken: String?
        let expiresIn: Int
        let signalingServerOrigin: String?
        let wsPath: String?
        let serverBuildFingerprint: String?
        let sessionTokenGeneration: String?
        let mediaTokenGeneration: String?
    }

    private struct RegisterCodeRequestBody: Encodable {
        let deviceName: String
        let ttlSeconds: Int
    }

    private struct RegisterCodeResponseBody: Decodable {
        let code: String
        let sessionId: String
        let sessionToken: String
        let turnAdmissionToken: String
        let mediaAdmissionToken: String?
        let expiresIn: Int
        let signalingServerOrigin: String
        let wsPath: String?
    }

    private struct LookupCodeResponseBody: Decodable {
        let found: Bool
        let sessionId: String
        let sessionToken: String
        let turnAdmissionToken: String
        let mediaAdmissionToken: String?
        let expiresIn: Int
        let signalingServerOrigin: String
        let wsPath: String?
        let initiatorDeviceId: String
        let initiatorProtocolSigningAlgorithm: String
        let initiatorProtocolPublicKeyFingerprint: String
        let initiatorDeviceName: String?
    }

    struct MediaRelayLease: Sendable, Equatable {
        let sessionID: String
        let role: String
        let endpoint: SkyBridgeMediaEndpoint
        let ttl: TimeInterval
        let maxPacketBytes: Int
    }

    struct MediaAdmissionRefreshLease: Sendable, Equatable {
        let token: String
        let expiresIn: TimeInterval
        let serverBuildFingerprint: String?
        let mediaTokenGeneration: String?
    }

    private struct MediaLeaseEndpointResponseBody: Decodable {
        let host: String
        let port: UInt16
    }

    private struct MediaLeaseResponseBody: Decodable {
        let sessionId: String
        let role: String
        let endpoint: MediaLeaseEndpointResponseBody
        let leaseToken: String
        let expiresAt: Int64
        let ttl: Int
        let maxPacketBytes: Int
        let serverBuildFingerprint: String?
        let supportsMediaAdmissionRefresh: Bool?
        let mediaTokenGeneration: String?
    }

    private struct MediaAdmissionRefreshRequestBody: Encodable {
        let sessionId: String
        let role: String
    }

    private struct MediaAdmissionRefreshResponseBody: Decodable {
        let sessionId: String
        let role: String
        let mediaAdmissionToken: String
        let expiresIn: Int
        let serverBuildFingerprint: String?
        let supportsMediaAdmissionRefresh: Bool?
        let mediaTokenGeneration: String?
    }

    struct AuthenticationDependencies: Sendable {
        let accessTokenOverride: @Sendable () -> String
        let tenantIDOverride: @Sendable () -> String
        let loadPersistedSession: @Sendable () async throws -> AuthSession?
        let refreshSession: @Sendable (String) async throws -> AuthSession
        let validateRefreshedAccessToken: @Sendable (String) async throws -> Void
        let replacePersistedSession: @Sendable (AuthSession, AuthSession) async throws -> Bool

        nonisolated static func live() -> Self {
            Self(
                accessTokenOverride: {
                    ProcessInfo.processInfo.environment["SKYBRIDGE_ACCESS_TOKEN"] ?? ""
                },
                tenantIDOverride: {
                    ProcessInfo.processInfo.environment["SKYBRIDGE_TENANT_ID"] ?? ""
                },
                loadPersistedSession: {
                    try await KeychainManager.shared.loadAuthSessionStrict()
                },
                refreshSession: { refreshToken in
                    try await SupabaseService.shared.refreshSession(refreshToken: refreshToken)
                },
                validateRefreshedAccessToken: { accessToken in
                    guard await SupabaseService.shared.isSupabaseAccessToken(accessToken) else {
                        throw ClientError.invalidAuthenticationClaims
                    }
                },
                replacePersistedSession: { expected, replacement in
                    try await KeychainManager.shared.replaceAuthSession(
                        expected: expected,
                        with: replacement
                    )
                }
            )
        }
    }

    private struct AuthenticatedRequestContext: Sendable, Equatable {
        let bearerToken: String
        let tenantID: String
    }

    private struct AccessTokenRefreshBinding: Sendable, Equatable {
        let refreshToken: String
        let accessToken: String
        let userIdentifier: String
        let tenantID: String?
        let explicitTenantID: String?
    }

    private struct AccessTokenRefreshOperation: Sendable {
        let binding: AccessTokenRefreshBinding
        let task: Task<AuthSession, Error>
    }

    private let urlSession: URLSession
    private let authenticationDependencies: AuthenticationDependencies
    private let logger = Logger(subsystem: "com.skybridge.crossnetwork", category: "SignalServerClientCompat")
    nonisolated private static let defaultRequestTimeoutSeconds: TimeInterval = 30
    private static let absoluteMaximumResponseBytes = 1_024 * 1_024
    private let requestTimeoutSeconds: TimeInterval
    private let resourceTimeoutSeconds: TimeInterval
    private let maximumResponseBytes: Int

    private static func defaultURLSession(
        requestTimeoutSeconds: TimeInterval,
        resourceTimeoutSeconds: TimeInterval
    ) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = requestTimeoutSeconds
        configuration.timeoutIntervalForResource = resourceTimeoutSeconds
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    init(
        urlSession: URLSession? = nil,
        authenticationDependencies: AuthenticationDependencies = .live(),
        requestTimeoutSeconds: TimeInterval = 30,
        resourceTimeoutSeconds: TimeInterval = 45,
        maximumResponseBytes: Int = 256 * 1_024
    ) {
        self.urlSession = urlSession ?? Self.defaultURLSession(
            requestTimeoutSeconds: requestTimeoutSeconds,
            resourceTimeoutSeconds: resourceTimeoutSeconds
        )
        self.authenticationDependencies = authenticationDependencies
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.resourceTimeoutSeconds = resourceTimeoutSeconds
        self.maximumResponseBytes = maximumResponseBytes
    }

    func authenticatedIdentityRotationScope() async throws
        -> IdentityRotationAuthenticationScope {
        let context = try await authenticatedRequestContext()
        return try identityRotationScope(from: context)
    }

    private func identityRotationScope(
        from context: AuthenticatedRequestContext
    ) throws -> IdentityRotationAuthenticationScope {
        let identity = try Self.resolveAuthenticatedJWTIdentity(
            accessToken: context.bearerToken
        )
        guard identity.effectiveTenantID == context.tenantID else {
            throw ClientError.tenantIdentityMismatch
        }
        return IdentityRotationAuthenticationScope(
            tenantID: context.tenantID,
            userID: identity.subject
        )
    }

    private func authenticatedRequestContext(
        matching expectedScope: IdentityRotationAuthenticationScope
    ) async throws -> AuthenticatedRequestContext {
        let context = try await authenticatedRequestContext()
        guard try identityRotationScope(from: context) == expectedScope else {
            throw ClientError.authenticationSessionChanged
        }
        return context
    }

    func registerCurrentDevice(
        binding: ProtocolIdentityBindingCompat,
        deviceName: String,
        expectedScope: IdentityRotationAuthenticationScope
    ) async throws -> RegisteredCurrentDevice {
        let normalizedDeviceName = deviceName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedDeviceName.isEmpty,
              normalizedDeviceName == deviceName,
              normalizedDeviceName.utf8.count <= 128,
              !normalizedDeviceName.unicodeScalars.contains(
                  where: CharacterSet.controlCharacters.contains
              ) else {
            throw ClientError.invalidDeviceName
        }
        let authentication = try await authenticatedRequestContext(
            matching: expectedScope
        )
        let body = RegisterCurrentDeviceRequestBody(
            deviceId: binding.deviceId,
            protocolSigningAlgorithm: binding.protocolSigningAlgorithm.rawValue,
            protocolPublicKeyFingerprint: binding.protocolPublicKeyFingerprint,
            clientVersion: clientVersion(),
            protocolVersion: protocolVersion(),
            deviceName: normalizedDeviceName
        )
        let response: RegisteredCurrentDeviceResponseBody = try await performJSONRequest(
            path: "/api/devices/register-current",
            method: "POST",
            body: try JSONEncoder().encode(body),
            authenticationContext: authentication
        )
        guard response.registered,
              response.device.tenantID == expectedScope.tenantID,
              response.device.userID == expectedScope.userID,
              response.device.deviceID == binding.deviceId,
              response.device.protocolSigningAlgorithm
                == binding.protocolSigningAlgorithm.rawValue,
              response.device.protocolPublicKeyFingerprint
                == binding.protocolPublicKeyFingerprint,
              response.device.status == "active" else {
            throw ClientError.malformedResponse(
                "current device registration changed the authenticated authority"
            )
        }
        return RegisteredCurrentDevice(
            tenantID: response.device.tenantID,
            userID: response.device.userID,
            deviceID: response.device.deviceID,
            protocolSigningAlgorithm: binding.protocolSigningAlgorithm,
            protocolPublicKeyFingerprint: response.device.protocolPublicKeyFingerprint,
            deviceName: response.device.deviceName,
            status: response.device.status,
            approvalMethod: response.device.approvalMethod,
            activated: response.activated
        )
    }

    func requestAdmissionChallenge(binding: ProtocolIdentityBindingCompat) async throws -> AdmissionChallenge {
        logger.info(
            "🌐 current-path request start path=/api/webrtc/admission/challenge deviceId=\(Self.sensitiveLogRedaction, privacy: .public) alg=\(binding.protocolSigningAlgorithm.rawValue, privacy: .public)"
        )
        let body = AdmissionChallengeRequestBody(
            deviceId: binding.deviceId,
            protocolSigningAlgorithm: binding.protocolSigningAlgorithm.rawValue,
            protocolPublicKeyFingerprint: binding.protocolPublicKeyFingerprint,
            clientVersion: clientVersion(),
            protocolVersion: protocolVersion()
        )
        let response: AdmissionChallengeResponseBody = try await performJSONRequest(
            path: "/api/webrtc/admission/challenge",
            method: "POST",
            body: try JSONEncoder().encode(body),
            requiresUserAuthentication: true
        )
        logger.info(
            "🌐 current-path request ok path=/api/webrtc/admission/challenge challengeId=\(Self.sensitiveLogRedaction, privacy: .public)"
        )
        return AdmissionChallenge(
            challengeID: response.challengeId,
            nonce: response.nonce,
            tenantID: response.tenantId,
            userID: response.userId,
            deviceID: response.deviceId,
            clientIPHash: response.clientIpHash,
            clientVersion: response.clientVersion,
            protocolVersion: response.protocolVersion,
            state: response.state,
            issuedAt: Date(timeIntervalSince1970: TimeInterval(response.issuedAt) / 1000),
            expiresAt: Date(timeIntervalSince1970: TimeInterval(response.expiresAt) / 1000)
        )
    }

    func completeAdmission(
        challenge: AdmissionChallenge,
        binding: ProtocolIdentityBindingCompat,
        signature: Data
    ) async throws -> AdmissionLease {
        logger.info(
            "🌐 current-path request start path=/api/webrtc/admission deviceId=\(Self.sensitiveLogRedaction, privacy: .public) alg=\(binding.protocolSigningAlgorithm.rawValue, privacy: .public)"
        )
        let body = AdmissionRequestBody(
            challengeId: challenge.challengeID,
            signature: signature,
            deviceId: binding.deviceId,
            protocolSigningAlgorithm: binding.protocolSigningAlgorithm.rawValue,
            protocolPublicKeyFingerprint: binding.protocolPublicKeyFingerprint,
            protocolPublicKeyBytes: binding.protocolPublicKeyBytes,
            clientVersion: challenge.clientVersion,
            protocolVersion: challenge.protocolVersion
        )
        let response: AdmissionResponseBody = try await performJSONRequest(
            path: "/api/webrtc/admission",
            method: "POST",
            body: try JSONEncoder().encode(body),
            requiresUserAuthentication: true
        )
        logger.info(
            "🌐 current-path request ok path=/api/webrtc/admission state=\(response.state, privacy: .public)"
        )
        return AdmissionLease(
            token: response.admissionToken,
            state: response.state,
            issuedAt: Date(timeIntervalSince1970: TimeInterval(response.issuedAt) / 1000),
            expiresAt: Date(timeIntervalSince1970: TimeInterval(response.expiresAt) / 1000)
        )
    }

    func requestIdentityRotationChallenge(
        oldIdentity: ProtocolIdentityBindingCompat,
        newIdentity: ProtocolIdentityBindingCompat,
        idempotencyKey: String,
        expectedScope: IdentityRotationAuthenticationScope
    ) async throws -> IdentityRotationChallenge {
        guard oldIdentity.deviceId == newIdentity.deviceId else {
            throw ClientError.malformedResponse(
                "identity rotation requires one stable deviceId"
            )
        }
        guard let requestID = UUID(uuidString: idempotencyKey),
              requestID.uuidString.lowercased() == idempotencyKey else {
            throw ClientError.missingIdempotencyKey
        }
        let requestedClientVersion = clientVersion()
        let requestedProtocolVersion = protocolVersion()
        let body = IdentityRotationChallengeRequestBody(
            deviceId: oldIdentity.deviceId,
            protocolSigningAlgorithm: oldIdentity.protocolSigningAlgorithm.rawValue,
            protocolPublicKeyFingerprint: oldIdentity.protocolPublicKeyFingerprint,
            protocolPublicKeyBytes: oldIdentity.protocolPublicKeyBytes,
            newProtocolSigningAlgorithm: newIdentity.protocolSigningAlgorithm.rawValue,
            newProtocolPublicKeyFingerprint: newIdentity.protocolPublicKeyFingerprint,
            newProtocolPublicKeyBytes: newIdentity.protocolPublicKeyBytes,
            clientVersion: requestedClientVersion,
            protocolVersion: requestedProtocolVersion
        )
        let authentication = try await authenticatedRequestContext(
            matching: expectedScope
        )
        let response: IdentityRotationChallengeResponseBody = try await performJSONRequest(
            path: "/api/devices/identity-rotation/challenge",
            method: "POST",
            body: try JSONEncoder().encode(body),
            authenticationContext: authentication,
            extraHeaders: ["Idempotency-Key": idempotencyKey]
        )
        guard response.state == "issued",
              response.requestId == idempotencyKey,
              response.transcriptVersion == Int(DeviceIdentityRotationTranscriptCompat.version),
              response.issuedAt > 0,
              response.expiresAt > response.issuedAt,
              response.tenantId == expectedScope.tenantID,
              response.userId == expectedScope.userID,
              response.deviceId == oldIdentity.deviceId,
              response.oldProtocolSigningAlgorithm
                == oldIdentity.protocolSigningAlgorithm.rawValue,
              response.oldProtocolPublicKeyFingerprint
                == oldIdentity.protocolPublicKeyFingerprint,
              response.newProtocolSigningAlgorithm
                == newIdentity.protocolSigningAlgorithm.rawValue,
              response.newProtocolPublicKeyFingerprint
                == newIdentity.protocolPublicKeyFingerprint else {
            throw ClientError.malformedResponse(
                "identity rotation challenge changed the requested authority"
            )
        }
        let transcript = try DeviceIdentityRotationTranscriptCompat(
            rotationID: response.rotationId,
            nonce: DeviceIdentityRotationTranscriptCompat.decodeCanonicalBase64URLNonce(
                response.nonce
            ),
            expiresAtMilliseconds: response.expiresAt,
            tenantID: response.tenantId,
            userID: response.userId,
            deviceID: response.deviceId,
            oldGeneration: response.oldGeneration,
            oldIdentity: oldIdentity,
            newIdentity: newIdentity
        )
        try transcript.validateServerCommitment(
            transcriptBase64: response.transcriptBase64,
            transcriptHash: response.transcriptHash
        )
        return try IdentityRotationChallenge(
            transcript: transcript,
            issuedAtMilliseconds: response.issuedAt,
            clientVersion: requestedClientVersion,
            protocolVersion: requestedProtocolVersion
        )
    }

    func commitIdentityRotation(
        challenge: IdentityRotationChallenge,
        oldSignature: Data,
        newSignature: Data,
        expectedScope: IdentityRotationAuthenticationScope
    ) async throws -> IdentityRotationCommitReceipt {
        let transcript = challenge.transcript
        guard transcript.tenantID == expectedScope.tenantID,
              transcript.userID == expectedScope.userID else {
            throw ClientError.authenticationSessionChanged
        }
        guard oldSignature.count
                == transcript.oldIdentity.protocolSigningAlgorithm.signatureByteCount,
              newSignature.count
                == transcript.newIdentity.protocolSigningAlgorithm.signatureByteCount else {
            throw ClientError.malformedResponse(
                "identity rotation proof has a non-canonical signature length"
            )
        }
        let body = IdentityRotationCommitRequestBody(
            deviceId: transcript.deviceID,
            protocolSigningAlgorithm: transcript.oldIdentity.protocolSigningAlgorithm.rawValue,
            protocolPublicKeyFingerprint:
                transcript.oldIdentity.protocolPublicKeyFingerprint,
            rotationId: transcript.rotationID,
            transcriptHash: transcript.sha256Hex,
            oldSignature: oldSignature,
            newSignature: newSignature,
            clientVersion: challenge.clientVersion,
            protocolVersion: challenge.protocolVersion
        )
        let authentication = try await authenticatedRequestContext(
            matching: expectedScope
        )
        let response: IdentityRotationCommitResponseBody = try await performJSONRequest(
            path: "/api/devices/identity-rotation/commit",
            method: "POST",
            body: try JSONEncoder().encode(body),
            authenticationContext: authentication
        )
        guard response.committed,
              response.state == "committed",
              response.rotationId == transcript.rotationID,
              response.deviceId == transcript.deviceID,
              response.committedAt > 0,
              transcript.oldGeneration < UInt64.max,
              response.generation == transcript.oldGeneration + 1,
              response.oldIdentity.state == "grace",
              response.oldIdentity.protocolSigningAlgorithm
                == transcript.oldIdentity.protocolSigningAlgorithm.rawValue,
              response.oldIdentity.protocolPublicKeyFingerprint
                == transcript.oldIdentity.protocolPublicKeyFingerprint,
              let graceExpiresAt = response.oldIdentity.graceExpiresAt,
              graceExpiresAt > response.committedAt,
              response.newIdentity.state == "active",
              response.newIdentity.graceExpiresAt == nil,
              response.newIdentity.protocolSigningAlgorithm
                == transcript.newIdentity.protocolSigningAlgorithm.rawValue,
              response.newIdentity.protocolPublicKeyFingerprint
                == transcript.newIdentity.protocolPublicKeyFingerprint else {
            throw ClientError.malformedResponse(
                "identity rotation commit response does not match the signed transcript"
            )
        }
        return IdentityRotationCommitReceipt(
            rotationID: response.rotationId,
            committedAtMilliseconds: response.committedAt,
            generation: response.generation,
            oldGraceExpiresAtMilliseconds: graceExpiresAt,
            oldIdentity: transcript.oldIdentity,
            newIdentity: transcript.newIdentity
        )
    }

    func registerSession(
        admissionToken: String,
        sessionId: String? = nil,
        validDuration: TimeInterval
    ) async throws -> SessionLease {
        logger.info(
            "🌐 current-path request start path=/api/webrtc/register-session sessionId=\(Self.sensitiveLogRedaction, privacy: .public) requestedSession=\(Self.logPresence(sessionId), privacy: .public)"
        )
        let body = RegisterSessionRequestBody(
            sessionId: sessionId,
            ttlSeconds: max(60, Int(validDuration.rounded()))
        )
        let response: RegisterSessionResponseBody = try await performJSONRequest(
            path: "/api/webrtc/register-session",
            method: "POST",
            body: try JSONEncoder().encode(body),
            extraHeaders: ["X-SkyBridge-Admission": admissionToken]
        )
        logger.info(
            "🌐 current-path request ok path=/api/webrtc/register-session sessionId=\(Self.sensitiveLogRedaction, privacy: .public)"
        )
        return try Self.sessionLease(from: response)
    }

    func redeemSession(
        admissionToken: String,
        sessionId: String,
        qrBootstrapToken: String,
        idempotencyKey: String
    ) async throws -> RedeemedSessionLease {
        let normalizedIdempotencyKey = idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedIdempotencyKey.isEmpty else {
            throw ClientError.missingIdempotencyKey
        }
        logger.info(
            "🌐 current-path request start path=/api/webrtc/redeem-session sessionId=\(Self.sensitiveLogRedaction, privacy: .public)"
        )
        let body = RedeemSessionRequestBody(
            sessionId: sessionId,
            qrBootstrapToken: qrBootstrapToken
        )
        let response: RedeemSessionResponseBody = try await performJSONRequest(
            path: "/api/webrtc/redeem-session",
            method: "POST",
            body: try JSONEncoder().encode(body),
            extraHeaders: [
                "X-SkyBridge-Admission": admissionToken,
                "Idempotency-Key": normalizedIdempotencyKey
            ]
        )
        logger.info(
            "🌐 current-path request ok path=/api/webrtc/redeem-session sessionId=\(Self.sensitiveLogRedaction, privacy: .public)"
        )
        return try Self.redeemedSessionLease(from: response)
    }

    func refreshWebRTCSession(
        admissionToken: String,
        sessionId: String,
        role: String
    ) async throws -> SessionRefreshLease {
        logger.info(
            "🌐 current-path request start path=/api/webrtc/session/refresh sessionId=\(Self.sensitiveLogRedaction, privacy: .public) role=\(role, privacy: .public)"
        )
        let body = SessionRefreshRequestBody(sessionId: sessionId, role: role)
        let response: SessionRefreshResponseBody = try await performJSONRequest(
            path: "/api/webrtc/session/refresh",
            method: "POST",
            body: try JSONEncoder().encode(body),
            extraHeaders: ["X-SkyBridge-Admission": admissionToken]
        )
        logger.info(
            "🌐 current-path request ok path=/api/webrtc/session/refresh sessionId=\(Self.sensitiveLogRedaction, privacy: .public) role=\(response.role, privacy: .public) serverBuild=\(response.serverBuildFingerprint ?? "-", privacy: .public) sessionTokenGeneration=\(Self.logPresence(response.sessionTokenGeneration), privacy: .public) mediaTokenGeneration=\(Self.logPresence(response.mediaTokenGeneration), privacy: .public)"
        )
        return try Self.sessionRefreshLease(
            from: response,
            expectedSessionId: sessionId,
            expectedRole: role
        )
    }

    func registerConnectionCode(
        admissionToken: String,
        deviceName: String,
        validDuration: TimeInterval
    ) async throws -> ConnectionCodeLease {
        logger.info(
            "🌐 current-path request start path=/api/webrtc/register-code deviceName=\(Self.sensitiveLogRedaction, privacy: .public)"
        )
        let body = RegisterCodeRequestBody(
            deviceName: deviceName,
            ttlSeconds: max(60, Int(validDuration.rounded()))
        )
        let response: RegisterCodeResponseBody = try await performJSONRequest(
            path: "/api/webrtc/register-code",
            method: "POST",
            body: try JSONEncoder().encode(body),
            extraHeaders: ["X-SkyBridge-Admission": admissionToken]
        )
        logger.info(
            "🌐 current-path request ok path=/api/webrtc/register-code sessionId=\(Self.sensitiveLogRedaction, privacy: .public) code=<redacted>"
        )
        return try Self.connectionCodeLease(from: response)
    }

    func lookupConnectionCode(admissionToken: String, code: String) async throws -> ConnectionCodeLookup {
        logger.info(
            "🌐 current-path request start path=/api/webrtc/lookup code=<redacted>"
        )
        let response: LookupCodeResponseBody = try await performJSONRequest(
            path: "/api/webrtc/lookup/\(code.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? code)",
            extraHeaders: ["X-SkyBridge-Admission": admissionToken]
        )
        guard response.found else {
            throw ClientError.serverRejected(404, "code_not_found")
        }
        let websocketPathForLog = Self.normalizedOptionalToken(response.wsPath) ?? "<missing>"
        logger.info(
            "🌐 current-path request ok path=/api/webrtc/lookup sessionId=\(Self.sensitiveLogRedaction, privacy: .public) found=\(response.found) wsPath=\(websocketPathForLog, privacy: .public)"
        )
        return try Self.connectionCodeLookup(from: response)
    }

    func requestMediaRelayLease(mediaAdmissionToken: String) async throws -> MediaRelayLease {
        logger.info("🌐 current-path request start path=/api/media/lease")
        let response: MediaLeaseResponseBody = try await performJSONRequest(
            path: "/api/media/lease",
            method: "POST",
            body: Data("{}".utf8),
            extraHeaders: ["X-SkyBridge-Media-Admission": mediaAdmissionToken]
        )
        logger.info(
            "🌐 current-path request ok path=/api/media/lease sessionId=\(Self.sensitiveLogRedaction, privacy: .public) role=\(response.role, privacy: .public) serverBuild=\(response.serverBuildFingerprint ?? "-", privacy: .public) refreshSupported=\(response.supportsMediaAdmissionRefresh == true, privacy: .public) mediaTokenGeneration=\(Self.logPresence(response.mediaTokenGeneration), privacy: .public)"
        )
        return try Self.mediaRelayLease(from: response)
    }

    func refreshMediaAdmissionToken(
        sessionId: String,
        sessionToken: String,
        role: String,
        idempotencyKey: String? = nil
    ) async throws -> String {
        try await refreshMediaAdmissionLease(
            sessionId: sessionId,
            sessionToken: sessionToken,
            role: role,
            idempotencyKey: idempotencyKey
        ).token
    }

    func refreshMediaAdmissionLease(
        sessionId: String,
        sessionToken: String,
        role: String,
        idempotencyKey: String? = nil
    ) async throws -> MediaAdmissionRefreshLease {
        logger.info("🌐 current-path request start path=/api/media/admission/refresh")
        let body = MediaAdmissionRefreshRequestBody(sessionId: sessionId, role: role)
        var headers = ["X-SkyBridge-Session": sessionToken]
        if let idempotencyKey,
           !idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            headers["Idempotency-Key"] = idempotencyKey
        }
        let response: MediaAdmissionRefreshResponseBody = try await performJSONRequest(
            path: "/api/media/admission/refresh",
            method: "POST",
            body: try JSONEncoder().encode(body),
            extraHeaders: headers
        )
        guard response.sessionId == sessionId,
              response.role == role,
              !response.mediaAdmissionToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              response.expiresIn > 0 else {
            throw ClientError.malformedResponse("invalid media admission refresh response")
        }
        logger.info(
            "🌐 current-path request ok path=/api/media/admission/refresh sessionId=\(Self.sensitiveLogRedaction, privacy: .public) role=\(response.role, privacy: .public) serverBuild=\(response.serverBuildFingerprint ?? "-", privacy: .public) refreshSupported=\(response.supportsMediaAdmissionRefresh == true, privacy: .public) mediaTokenGeneration=\(Self.logPresence(response.mediaTokenGeneration), privacy: .public)"
        )
        return MediaAdmissionRefreshLease(
            token: response.mediaAdmissionToken,
            expiresIn: TimeInterval(response.expiresIn),
            serverBuildFingerprint: response.serverBuildFingerprint,
            mediaTokenGeneration: response.mediaTokenGeneration
        )
    }

    private var accessTokenRefreshOperation: AccessTokenRefreshOperation?

    private static func sessionRefreshLease(
        from response: SessionRefreshResponseBody,
        expectedSessionId sessionId: String,
        expectedRole role: String
    ) throws -> SessionRefreshLease {
        guard response.sessionId == sessionId,
              response.role == role,
              !response.sessionToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !response.turnAdmissionToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              response.expiresIn > 0,
              let signalingServerOrigin = response.signalingServerOrigin?.trimmingCharacters(in: .whitespacesAndNewlines),
              !signalingServerOrigin.isEmpty,
              let wsPath = response.wsPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !wsPath.isEmpty else {
            throw ClientError.malformedResponse("invalid session refresh response")
        }
        return SessionRefreshLease(
            sessionID: response.sessionId,
            role: response.role,
            sessionToken: response.sessionToken,
            turnAdmissionToken: response.turnAdmissionToken,
            mediaAdmissionToken: Self.normalizedOptionalToken(response.mediaAdmissionToken),
            expiresIn: TimeInterval(response.expiresIn),
            signalingServerOrigin: signalingServerOrigin,
            wsPath: wsPath,
            serverBuildFingerprint: response.serverBuildFingerprint,
            sessionTokenGeneration: response.sessionTokenGeneration,
            mediaTokenGeneration: response.mediaTokenGeneration
        )
    }

#if DEBUG || SKYBRIDGE_TESTING
    static func testOnlyDecodeMediaRelayLeaseResponse(_ data: Data) throws -> MediaRelayLease {
        let response = try decodeResponseBody(MediaLeaseResponseBody.self, from: data)
        return try Self.mediaRelayLease(from: response)
    }

    static func testOnlyDecodeRegisterCodeResponse(_ data: Data) throws -> ConnectionCodeLease {
        let response = try decodeResponseBody(RegisterCodeResponseBody.self, from: data)
        return try Self.connectionCodeLease(from: response)
    }

    static func testOnlyDecodeRegisterSessionResponse(_ data: Data) throws -> SessionLease {
        let response = try decodeResponseBody(RegisterSessionResponseBody.self, from: data)
        return try Self.sessionLease(from: response)
    }

    static func testOnlyDecodeSessionRefreshResponse(
        _ data: Data,
        sessionId: String,
        role: String
    ) throws -> SessionRefreshLease {
        let response = try decodeResponseBody(SessionRefreshResponseBody.self, from: data)
        return try Self.sessionRefreshLease(
            from: response,
            expectedSessionId: sessionId,
            expectedRole: role
        )
    }

    static func testOnlyDecodeLookupConnectionCodeResponse(_ data: Data) throws -> ConnectionCodeLookup {
        let response = try decodeResponseBody(LookupCodeResponseBody.self, from: data)
        return try Self.connectionCodeLookup(from: response)
    }
#endif

    private static func normalizedMediaRelayExpiresAt(_ rawValue: Int64) -> TimeInterval {
        let seconds = TimeInterval(rawValue)
        return seconds > 10_000_000_000 ? seconds / 1000 : seconds
    }

#if DEBUG || SKYBRIDGE_TESTING
    nonisolated static func testOnlyRequestTimeoutSeconds() -> TimeInterval {
        defaultRequestTimeoutSeconds
    }
#endif

    private static func normalizedOptionalToken(_ token: String?) -> String? {
        guard let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func decodeResponseBody<Response: Decodable>(
        _ type: Response.Type,
        from data: Data
    ) throws -> Response {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch let error as ClientError {
            throw error
        } catch {
            throw ClientError.malformedResponse(error.localizedDescription)
        }
    }

    private static func sessionLease(from response: RegisterSessionResponseBody) throws -> SessionLease {
        let expiresIn = try requiredPositiveTimeInterval(response.expiresIn, field: "expiresIn")
        return SessionLease(
            sessionID: try requiredToken(response.sessionId, field: "sessionId"),
            sessionToken: try requiredToken(response.sessionToken, field: "sessionToken"),
            qrBootstrapToken: try requiredToken(response.qrBootstrapToken, field: "qrBootstrapToken"),
            turnAdmissionToken: try requiredToken(response.turnAdmissionToken, field: "turnAdmissionToken"),
            mediaAdmissionToken: Self.normalizedOptionalToken(response.mediaAdmissionToken),
            expiresIn: expiresIn,
            signalingServerOrigin: try requiredToken(response.signalingServerOrigin, field: "signalingServerOrigin"),
            wsPath: try requiredWebSocketPath(response.wsPath)
        )
    }

    private static func redeemedSessionLease(from response: RedeemSessionResponseBody) throws -> RedeemedSessionLease {
        let expiresIn = try requiredPositiveTimeInterval(response.expiresIn, field: "expiresIn")
        return RedeemedSessionLease(
            sessionID: try requiredToken(response.sessionId, field: "sessionId"),
            sessionToken: try requiredToken(response.sessionToken, field: "sessionToken"),
            turnAdmissionToken: try requiredToken(response.turnAdmissionToken, field: "turnAdmissionToken"),
            mediaAdmissionToken: Self.normalizedOptionalToken(response.mediaAdmissionToken),
            expiresIn: expiresIn,
            signalingServerOrigin: try requiredToken(response.signalingServerOrigin, field: "signalingServerOrigin"),
            wsPath: try requiredWebSocketPath(response.wsPath),
            initiatorDeviceId: try requiredToken(response.initiatorDeviceId, field: "initiatorDeviceId"),
            initiatorProtocolSigningAlgorithm: try requiredProtocolSigningAlgorithm(
                response.initiatorProtocolSigningAlgorithm,
                field: "initiatorProtocolSigningAlgorithm"
            ),
            initiatorProtocolPublicKeyFingerprint: try requiredToken(
                response.initiatorProtocolPublicKeyFingerprint,
                field: "initiatorProtocolPublicKeyFingerprint"
            )
        )
    }

    private static func connectionCodeLease(from response: RegisterCodeResponseBody) throws -> ConnectionCodeLease {
        let expiresIn = try requiredPositiveTimeInterval(response.expiresIn, field: "expiresIn")
        return ConnectionCodeLease(
            code: try requiredToken(response.code, field: "code"),
            sessionID: try requiredToken(response.sessionId, field: "sessionId"),
            sessionToken: try requiredToken(response.sessionToken, field: "sessionToken"),
            turnAdmissionToken: try requiredToken(response.turnAdmissionToken, field: "turnAdmissionToken"),
            mediaAdmissionToken: Self.normalizedOptionalToken(response.mediaAdmissionToken),
            expiresIn: expiresIn,
            signalingServerOrigin: try requiredToken(response.signalingServerOrigin, field: "signalingServerOrigin"),
            wsPath: try requiredWebSocketPath(response.wsPath)
        )
    }

    private static func connectionCodeLookup(from response: LookupCodeResponseBody) throws -> ConnectionCodeLookup {
        guard response.found else {
            throw ClientError.serverRejected(404, "code_not_found")
        }
        let expiresIn = try requiredPositiveTimeInterval(response.expiresIn, field: "expiresIn")
        return ConnectionCodeLookup(
            sessionID: try requiredToken(response.sessionId, field: "sessionId"),
            sessionToken: try requiredToken(response.sessionToken, field: "sessionToken"),
            turnAdmissionToken: try requiredToken(response.turnAdmissionToken, field: "turnAdmissionToken"),
            mediaAdmissionToken: Self.normalizedOptionalToken(response.mediaAdmissionToken),
            expiresIn: expiresIn,
            signalingServerOrigin: try requiredToken(response.signalingServerOrigin, field: "signalingServerOrigin"),
            wsPath: try requiredWebSocketPath(response.wsPath),
            initiatorDeviceId: try requiredToken(response.initiatorDeviceId, field: "initiatorDeviceId"),
            initiatorProtocolSigningAlgorithm: try requiredProtocolSigningAlgorithm(
                response.initiatorProtocolSigningAlgorithm,
                field: "initiatorProtocolSigningAlgorithm"
            ),
            initiatorProtocolPublicKeyFingerprint: try requiredToken(
                response.initiatorProtocolPublicKeyFingerprint,
                field: "initiatorProtocolPublicKeyFingerprint"
            ),
            initiatorDeviceName: normalizedOptionalToken(response.initiatorDeviceName)
        )
    }

    private static func mediaRelayLease(from response: MediaLeaseResponseBody) throws -> MediaRelayLease {
        let ttl = try requiredPositiveTimeInterval(response.ttl, field: "ttl")
        let host = try requiredToken(response.endpoint.host, field: "endpoint.host")
        let relayToken = try requiredToken(response.leaseToken, field: "leaseToken")
        guard response.endpoint.port != 0 else {
            throw ClientError.malformedResponse("invalid endpoint.port")
        }
        guard response.maxPacketBytes > 0 else {
            throw ClientError.malformedResponse("invalid maxPacketBytes")
        }
        let expiresAt = Self.normalizedMediaRelayExpiresAt(response.expiresAt)
        guard expiresAt > 0 else {
            throw ClientError.malformedResponse("invalid expiresAt")
        }
        return MediaRelayLease(
            sessionID: try requiredToken(response.sessionId, field: "sessionId"),
            role: try requiredToken(response.role, field: "role"),
            endpoint: SkyBridgeMediaEndpoint(
                host: host,
                port: response.endpoint.port,
                relayToken: relayToken,
                expiresAt: expiresAt
            ),
            ttl: ttl,
            maxPacketBytes: response.maxPacketBytes
        )
    }

    private static func requiredToken(_ value: String?, field: String) throws -> String {
        guard let token = normalizedOptionalToken(value) else {
            throw ClientError.malformedResponse("missing \(field)")
        }
        return token
    }

    private static func requiredWebSocketPath(_ value: String?) throws -> String {
        try requiredToken(value, field: "wsPath")
    }

    private static func requiredPositiveTimeInterval(_ value: Int, field: String) throws -> TimeInterval {
        guard value > 0 else {
            throw ClientError.malformedResponse("invalid \(field)")
        }
        return TimeInterval(value)
    }

    private static func requiredProtocolSigningAlgorithm(
        _ value: String,
        field: String
    ) throws -> ProtocolSigningAlgorithm {
        let rawValue = try requiredToken(value, field: field)
        guard let algorithm = ProtocolSigningAlgorithm(rawValue: rawValue) else {
            throw ClientError.malformedResponse("invalid \(field)")
        }
        return algorithm
    }

    private static func logPresence(_ value: String?) -> String {
        normalizedOptionalToken(value) == nil ? "missing" : "present"
    }

    private func performJSONRequest<Response: Decodable>(
        path: String,
        method: String = "GET",
        queryItems: [URLQueryItem] = [],
        body: Data? = nil,
        requiresUserAuthentication: Bool = false,
        authenticationContext: AuthenticatedRequestContext? = nil,
        extraHeaders: [String: String] = [:]
    ) async throws -> Response {
        try validateRequestLimits()
        guard var components = URLComponents(string: CrossNetworkServerConfig.signalingServerURL) else {
            throw ClientError.invalidBaseURL
        }
        components.path += path
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw ClientError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = requestTimeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let apiKey = CrossNetworkServerConfig.clientAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        }
        if let authentication = authenticationContext {
            request.setValue(authentication.tenantID, forHTTPHeaderField: "X-SkyBridge-Tenant-Id")
            request.setValue("Bearer \(authentication.bearerToken)", forHTTPHeaderField: "Authorization")
        } else if requiresUserAuthentication {
            let authentication = try await authenticatedRequestContext()
            request.setValue(authentication.tenantID, forHTTPHeaderField: "X-SkyBridge-Tenant-Id")
            request.setValue("Bearer \(authentication.bearerToken)", forHTTPHeaderField: "Authorization")
        } else {
            let tenantID = try await currentTenantID()
            if !tenantID.isEmpty {
                request.setValue(tenantID, forHTTPHeaderField: "X-SkyBridge-Tenant-Id")
            }
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        for (field, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }

        try Task.checkCancellation()

        logger.debug(
            "🌐 performJSONRequest method=\(method, privacy: .public) path=\(path, privacy: .public) auth=\((requiresUserAuthentication || authenticationContext != nil) ? 1 : 0)"
        )

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await boundedResponse(for: request, path: path)
        } catch {
            if error is CancellationError {
                throw error
            }
            logger.error(
                "❌ current-path request failed method=\(method, privacy: .public) path=\(path, privacy: .public) err=\(error.localizedDescription, privacy: .private)"
            )
            throw error
        }
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodySummary = Self.redactedServerRejectedBodyLogSummary(byteCount: data.count)
            logger.error(
                "❌ current-path request rejected method=\(method, privacy: .public) path=\(path, privacy: .public) status=\(http.statusCode) body=\(bodySummary, privacy: .public)"
            )
            throw ClientError.serverRejected(
                http.statusCode,
                Self.sanitizedServerRejectedBodyDescription(from: data)
            )
        }
        do {
            return try Self.decodeResponseBody(Response.self, from: data)
        } catch {
            logger.error(
                "❌ current-path response decode failed path=\(path, privacy: .public) err=\(error.localizedDescription, privacy: .private)"
            )
            throw ClientError.malformedResponse(error.localizedDescription)
        }
    }

    private func validateRequestLimits() throws {
        guard requestTimeoutSeconds.isFinite,
              requestTimeoutSeconds > 0,
              resourceTimeoutSeconds.isFinite,
              resourceTimeoutSeconds > 0,
              (1...Self.absoluteMaximumResponseBytes).contains(maximumResponseBytes) else {
            throw ClientError.invalidRequestLimits
        }
    }

    private func boundedResponse(
        for request: URLRequest,
        path: String
    ) async throws -> (Data, URLResponse) {
        let urlSession = self.urlSession
        let maximumResponseBytes = self.maximumResponseBytes
        let resourceTimeoutSeconds = self.resourceTimeoutSeconds

        do {
            return try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
                group.addTask {
                    let (bytes, response) = try await urlSession.bytes(for: request)
                    if response.expectedContentLength > Int64(maximumResponseBytes) {
                        throw ClientError.responseTooLarge(
                            path: path,
                            limitBytes: maximumResponseBytes
                        )
                    }

                    var data = Data()
                    data.reserveCapacity(min(maximumResponseBytes, 4_096))
                    for try await byte in bytes {
                        guard data.count < maximumResponseBytes else {
                            throw ClientError.responseTooLarge(
                                path: path,
                                limitBytes: maximumResponseBytes
                            )
                        }
                        data.append(byte)
                    }
                    return (data, response)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(resourceTimeoutSeconds))
                    throw ClientError.resourceDeadlineExceeded(path)
                }

                guard let first = try await group.next() else {
                    throw ClientError.resourceDeadlineExceeded(path)
                }
                group.cancelAll()
                return first
            }
        } catch let error as ClientError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw ClientError.requestTimedOut(path)
        }
    }

    private func currentTenantID() async throws -> String {
        let explicitTenantID = normalized(authenticationDependencies.tenantIDOverride())
        let envAccessToken = normalized(authenticationDependencies.accessTokenOverride())
        let session = try await loadPersistedAuthSession()
        let sessionAccessToken = normalized(session?.accessToken)
        let accessToken = envAccessToken ?? sessionAccessToken ?? ""

        return try Self.resolveAuthenticatedTenantID(
            accessToken: accessToken,
            explicitTenantID: explicitTenantID,
            sessionTenantID: nil,
            legacyUserIdentifier: session?.userIdentifier
        )
    }

    /// Captures one immutable authentication snapshot for a request. The tenant header is
    /// resolved only after the final bearer has been selected/refreshed and is derived from
    /// that exact bearer, so a Keychain update cannot mix identities within one request.
    private func authenticatedRequestContext() async throws -> AuthenticatedRequestContext {
        let explicitTenantID = normalized(authenticationDependencies.tenantIDOverride())
        let accessTokenOverride = normalized(authenticationDependencies.accessTokenOverride())
        let persistedSession = try await loadPersistedAuthSession()

        let bearerToken: String
        let identitySession: AuthSession?
        if let accessTokenOverride {
            bearerToken = accessTokenOverride
            identitySession = persistedSession
        } else {
            guard let persistedSession,
                  persistedSession.accessToken != "pending_verification",
                  normalized(persistedSession.accessToken) != nil else {
                throw ClientError.missingAuthentication
            }
            let validSession = try await validAuthSession(
                persistedSession,
                explicitTenantID: explicitTenantID
            )
            guard let normalizedToken = normalized(validSession.accessToken) else {
                throw ClientError.missingAuthentication
            }
            bearerToken = normalizedToken
            identitySession = validSession
        }

        try Self.validateAuthenticatedRequestBearerFreshness(bearerToken)

        let tenantID = try Self.resolveAuthenticatedTenantID(
            accessToken: bearerToken,
            explicitTenantID: explicitTenantID,
            sessionTenantID: nil,
            legacyUserIdentifier: identitySession?.userIdentifier
        )
        guard !tenantID.isEmpty else {
            throw ClientError.missingTenantID
        }
        return AuthenticatedRequestContext(bearerToken: bearerToken, tenantID: tenantID)
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func loadPersistedAuthSession() async throws -> AuthSession? {
        do {
            return try await authenticationDependencies.loadPersistedSession()
        } catch {
            throw ClientError.authenticationStorageUnavailable(error.localizedDescription)
        }
    }

    private func clientVersion() -> String {
        if let value = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return "0.0.0"
    }

    private func protocolVersion() -> String {
        let value = ProcessInfo.processInfo.environment["SKYBRIDGE_PROTOCOL_VERSION"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "1" : value
    }

    private func validAuthSession(
        _ session: AuthSession,
        explicitTenantID: String?,
        forceRefresh: Bool = false
    ) async throws -> AuthSession {
        guard let refreshToken = session.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !refreshToken.isEmpty else {
            return session
        }

        if !forceRefresh && !shouldRefreshAccessToken(session.accessToken) {
            return session
        }

        let authenticatedTenantID = try Self.resolveAuthenticatedTenantID(
            accessToken: session.accessToken,
            explicitTenantID: explicitTenantID,
            sessionTenantID: nil,
            legacyUserIdentifier: session.userIdentifier
        )
        let refreshBinding = AccessTokenRefreshBinding(
            refreshToken: refreshToken,
            accessToken: session.accessToken,
            userIdentifier: session.userIdentifier,
            tenantID: authenticatedTenantID,
            explicitTenantID: explicitTenantID
        )
        if let existingRefreshOperation = accessTokenRefreshOperation {
            guard existingRefreshOperation.binding == refreshBinding else {
                throw ClientError.authenticationSessionChanged
            }
            return try await existingRefreshOperation.task.value
        }

        let dependencies = authenticationDependencies
        // The operation is fully dependency-bound and Sendable; detaching it avoids retaining
        // this client actor through inherited actor isolation while network refresh is in flight.
        let refreshTask = Task.detached(priority: nil) {
            let refreshed = try await dependencies.refreshSession(refreshToken)
            try await dependencies.validateRefreshedAccessToken(refreshed.accessToken)
            let merged = try Self.validatedRefreshedAuthSession(
                refreshed,
                replacing: session,
                explicitTenantID: explicitTenantID
            )
            let replaced = try await dependencies.replacePersistedSession(session, merged)
            guard replaced else {
                throw ClientError.authenticationSessionChanged
            }
            return merged
        }

        accessTokenRefreshOperation = AccessTokenRefreshOperation(
            binding: refreshBinding,
            task: refreshTask
        )
        defer {
            if accessTokenRefreshOperation?.task == refreshTask {
                accessTokenRefreshOperation = nil
            }
        }
        return try await refreshTask.value
    }

    private func shouldRefreshAccessToken(_ token: String, skewSeconds: TimeInterval = 300) -> Bool {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else {
            return false
        }
        guard let claims = Self.decodeJWTClaims(token),
              let exp = Self.numericJWTClaim(claims["exp"]) else {
            return true
        }
        let expiryDate = Date(timeIntervalSince1970: exp)
        return expiryDate.timeIntervalSinceNow <= skewSeconds
    }

    /// Opaque legacy bearer values keep their existing compatibility boundary. JWT-shaped
    /// values, however, must carry a numeric future expiration before an authenticated request.
    nonisolated private static func validateAuthenticatedRequestBearerFreshness(
        _ accessToken: String,
        now: Date = Date()
    ) throws {
        guard !accessToken.isEmpty,
              accessToken.utf8.count <= maximumAuthenticationTokenBytes,
              accessToken == accessToken.trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ClientError.invalidAuthenticationClaims
        }
        let segments = accessToken.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else { return }
        guard let claims = decodeJWTClaims(accessToken),
              let expiration = numericJWTClaim(claims["exp"]),
              expiration > now.timeIntervalSince1970 else {
            throw ClientError.invalidAuthenticationClaims
        }
    }

    /// Validates the identity continuity of a Supabase refresh response before it can replace
    /// the persisted session. This intentionally does not accept the opaque-token compatibility
    /// boundary: a refresh response must be a provider-classified, non-`none`, three-segment
    /// JWT-shaped access token.
    nonisolated static func validatedRefreshedAuthSession(
        _ refreshed: AuthSession,
        replacing original: AuthSession,
        explicitTenantID: String?,
        now: Date = Date()
    ) throws -> AuthSession {
        let accessToken = refreshed.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessToken.isEmpty,
              accessToken == refreshed.accessToken,
              accessToken.utf8.count <= maximumAuthenticationTokenBytes else {
            throw ClientError.invalidAuthenticationClaims
        }

        let segments = accessToken.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3,
              segments.allSatisfy({ !$0.isEmpty }),
              isBase64URLSegment(segments[0]),
              isBase64URLSegment(segments[1]),
              isBase64URLSegment(segments[2]),
              let header = decodeJWTJSONObject(segments[0]),
              let algorithm = try validatedIdentityClaim(header["alg"]),
              algorithm.caseInsensitiveCompare("none") != .orderedSame,
              let claims = decodeJWTJSONObject(segments[1]),
              let expiration = numericJWTClaim(claims["exp"]),
              expiration > now.timeIntervalSince1970 else {
            throw ClientError.invalidAuthenticationClaims
        }

        let originalUserIdentifier = try validatedIdentityClaim(original.userIdentifier)
        guard let originalUserIdentifier else {
            throw ClientError.invalidAuthenticationClaims
        }
        _ = try resolveAuthenticatedJWTIdentity(
            accessToken: accessToken,
            expectedUserIdentifier: originalUserIdentifier
        )
        guard refreshed.userIdentifier == originalUserIdentifier else {
            throw ClientError.userIdentityMismatch
        }

        let originalTenantID = try resolveAuthenticatedTenantID(
            accessToken: original.accessToken,
            explicitTenantID: explicitTenantID,
            sessionTenantID: nil,
            legacyUserIdentifier: original.userIdentifier
        )
        let refreshedTenantID = try resolveAuthenticatedTenantID(
            accessToken: accessToken,
            explicitTenantID: explicitTenantID,
            sessionTenantID: nil,
            legacyUserIdentifier: original.userIdentifier
        )
        guard !originalTenantID.isEmpty, refreshedTenantID == originalTenantID else {
            throw ClientError.tenantIdentityMismatch
        }

        let replacementRefreshToken: String?
        if let refreshedToken = refreshed.refreshToken {
            let normalizedRefreshToken = refreshedToken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedRefreshToken.isEmpty,
                  normalizedRefreshToken == refreshedToken,
                  normalizedRefreshToken.utf8.count <= maximumAuthenticationTokenBytes else {
                throw ClientError.invalidAuthenticationClaims
            }
            replacementRefreshToken = normalizedRefreshToken
        } else {
            replacementRefreshToken = original.refreshToken
        }

        return AuthSession(
            accessToken: accessToken,
            refreshToken: replacementRefreshToken,
            userIdentifier: original.userIdentifier,
            displayName: original.displayName,
            email: original.email,
            avatarURL: original.avatarURL,
            nebulaId: original.nebulaId,
            issuedAt: refreshed.issuedAt
        )
    }

    nonisolated private static func numericJWTClaim(_ rawValue: Any?) -> TimeInterval? {
        guard let number = rawValue as? NSNumber,
              String(cString: number.objCType) != "c" else {
            return nil
        }
        let value = number.doubleValue
        return value.isFinite ? value : nil
    }

    nonisolated private static func isBase64URLSegment(_ segment: Substring) -> Bool {
        guard !segment.isEmpty else { return false }
        return segment.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (
                CharacterSet.alphanumerics.contains(scalar)
                    || scalar == "-"
                    || scalar == "_"
            )
        }
    }

    nonisolated private static func decodeJWTJSONObject(_ segment: Substring) -> [String: Any]? {
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

    nonisolated private static func decodeJWTClaims(_ token: String) -> [String: Any]? {
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

    struct AuthenticatedJWTIdentity: Sendable, Equatable {
        let explicitTenantID: String?
        let subject: String

        var effectiveTenantID: String {
            explicitTenantID ?? subject
        }
    }

    nonisolated private static func validatedIdentityClaim(_ rawValue: Any?) throws -> String? {
        guard let rawValue else { return nil }
        guard let value = rawValue as? String,
              !value.isEmpty,
              value.utf8.count <= 256,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ClientError.invalidAuthenticationClaims
        }
        return value
    }

    /// Returns nil only for an opaque legacy token. A token with the three-segment JWT shape
    /// must decode into a coherent subject and server-controlled tenant claim set.
    nonisolated private static func validatedJWTIdentityClaims(
        accessToken: String
    ) throws -> AuthenticatedJWTIdentity? {
        let segments = accessToken.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else { return nil }
        guard let claims = decodeJWTClaims(accessToken) else {
            throw ClientError.invalidAuthenticationClaims
        }
        if claims["app_metadata"] != nil, !(claims["app_metadata"] is [String: Any]) {
            throw ClientError.invalidAuthenticationClaims
        }
        let appMetadata = claims["app_metadata"] as? [String: Any]
        let tenantCandidates: [Any?] = [
            appMetadata?["tenant_id"],
            appMetadata?["tenantId"],
            appMetadata?["org_id"],
            appMetadata?["workspace_id"]
        ]
        let tenantValues = try Set(tenantCandidates.compactMap(validatedIdentityClaim))
        guard tenantValues.count <= 1 else {
            throw ClientError.conflictingTenantClaims
        }
        guard let subject = try validatedIdentityClaim(claims["sub"]) else {
            throw ClientError.invalidAuthenticationClaims
        }
        return AuthenticatedJWTIdentity(
            explicitTenantID: tenantValues.first,
            subject: subject
        )
    }

    /// Resolves the server-controlled identity carried by a JWT-shaped access token.
    /// The caller may provide an expected local user only as a binding assertion; it is
    /// never used as an identity fallback. The signaling server remains the signature
    /// authority for the token.
    nonisolated static func resolveAuthenticatedJWTIdentity(
        accessToken: String,
        expectedUserIdentifier: String? = nil
    ) throws -> AuthenticatedJWTIdentity {
        let normalizedToken = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedToken.isEmpty,
              normalizedToken == accessToken,
              normalizedToken.utf8.count <= maximumAuthenticationTokenBytes,
              let identity = try validatedJWTIdentityClaims(accessToken: normalizedToken) else {
            throw ClientError.invalidAuthenticationClaims
        }

        if let expectedUserIdentifier {
            let normalizedExpectedUser = expectedUserIdentifier.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !normalizedExpectedUser.isEmpty,
                  normalizedExpectedUser == expectedUserIdentifier,
                  normalizedExpectedUser.utf8.count <= 256,
                  !normalizedExpectedUser.unicodeScalars.contains(
                    where: CharacterSet.controlCharacters.contains
                  ) else {
                throw ClientError.invalidAuthenticationClaims
            }
            guard normalizedExpectedUser == identity.subject else {
                throw ClientError.userIdentityMismatch
            }
        }
        return identity
    }

    /// Resolves the tenant used for authenticated signaling and binds every local tenant identity
    /// to the tenant carried by the bearer token. The server remains responsible for validating
    /// the JWT signature; this client-side check prevents a valid token from being sent alongside
    /// a stale or attacker-controlled tenant header.
    nonisolated static func resolveAuthenticatedTenantID(
        accessToken: String,
        explicitTenantID: String?,
        sessionTenantID: String?,
        legacyUserIdentifier: String?
    ) throws -> String {
        func normalized(_ value: String?) -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        guard let token = normalized(accessToken) else {
            throw ClientError.missingAuthentication
        }
        let identity = try resolveAuthenticatedJWTIdentity(
            accessToken: token,
            expectedUserIdentifier: normalized(legacyUserIdentifier)
        )
        let expectedTenants = Set(
            [explicitTenantID, sessionTenantID].compactMap(normalized)
        )
        guard expectedTenants.count <= 1 else {
            throw ClientError.tenantIdentityMismatch
        }
        if let expectedTenant = expectedTenants.first,
           expectedTenant != identity.effectiveTenantID {
            throw ClientError.tenantIdentityMismatch
        }
        return identity.effectiveTenantID
    }
}
