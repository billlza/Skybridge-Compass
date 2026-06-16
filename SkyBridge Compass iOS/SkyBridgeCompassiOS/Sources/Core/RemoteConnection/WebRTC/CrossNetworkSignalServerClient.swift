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

    enum ClientError: LocalizedError {
        case invalidBaseURL
        case invalidResponse
        case missingAuthentication
        case missingTenantID
        case missingIdempotencyKey
        case authenticationStorageUnavailable(String)
        case requestTimedOut(String)
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
            case .missingIdempotencyKey:
                return "缺少幂等键，无法安全执行当前跨网请求"
            case .authenticationStorageUnavailable(let reason):
                return "认证会话存储不可用: \(reason)"
            case .requestTimedOut(let path):
                return "当前跨网请求超时: \(path)"
            case .serverRejected(let status, _):
                return "信令服务器拒绝请求 (\(status)): \(SignalServerClientCompat.redactedServerRejectedBodyDescription)"
            case .malformedResponse(let reason):
                return "信令服务器响应格式错误: \(reason)"
            }
        }
    }

    nonisolated private static let sensitiveLogRedaction = "<redacted>"
    nonisolated private static let redactedServerRejectedBodyDescription = "<redacted-server-error-body>"
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

    private let urlSession: URLSession
    private let logger = Logger(subsystem: "com.skybridge.crossnetwork", category: "SignalServerClientCompat")
    private static let requestTimeout: Duration = .seconds(30)
    private static let requestTimeoutSeconds: TimeInterval = 30

    private static func defaultURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = requestTimeoutSeconds
        configuration.timeoutIntervalForResource = max(45, requestTimeoutSeconds)
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    init(urlSession: URLSession? = nil) {
        self.urlSession = urlSession ?? Self.defaultURLSession()
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

    private var accessTokenRefreshTask: Task<AuthSession, Error>?

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

    private static func normalizedMediaRelayExpiresAt(_ rawValue: Int64) -> TimeInterval {
        let seconds = TimeInterval(rawValue)
        return seconds > 10_000_000_000 ? seconds / 1000 : seconds
    }

    nonisolated static func testOnlyRequestTimeoutSeconds() -> TimeInterval {
        requestTimeoutSeconds
    }

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
        body: Data? = nil
        ,
        requiresUserAuthentication: Bool = false,
        extraHeaders: [String: String] = [:]
    ) async throws -> Response {
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
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let apiKey = CrossNetworkServerConfig.clientAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        }
        let tenantID = try currentTenantID().trimmingCharacters(in: .whitespacesAndNewlines)
        if requiresUserAuthentication && tenantID.isEmpty {
            throw ClientError.missingTenantID
        }
        if !tenantID.isEmpty {
            request.setValue(tenantID, forHTTPHeaderField: "X-SkyBridge-Tenant-Id")
        }
        if requiresUserAuthentication {
            let bearerToken = try await validAccessToken().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bearerToken.isEmpty else {
                throw ClientError.missingAuthentication
            }
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        for (field, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }

        logger.debug(
            "🌐 performJSONRequest method=\(method, privacy: .public) path=\(path, privacy: .public) auth=\(requiresUserAuthentication ? 1 : 0)"
        )

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
                group.addTask { [urlSession, request] in
                    try await urlSession.data(for: request)
                }
                group.addTask {
                    try await Task.sleep(for: Self.requestTimeout)
                    throw ClientError.requestTimedOut(path)
                }

                guard let first = try await group.next() else {
                    throw ClientError.requestTimedOut(path)
                }
                group.cancelAll()
                return first
            }
        } catch {
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

    private func currentTenantID() throws -> String {
        let explicitTenantID = ProcessInfo.processInfo.environment["SKYBRIDGE_TENANT_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !explicitTenantID.isEmpty {
            return explicitTenantID
        }
        let envAccessToken = ProcessInfo.processInfo.environment["SKYBRIDGE_ACCESS_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !envAccessToken.isEmpty,
           let derived = deriveTenantIdentifier(accessToken: envAccessToken),
           !derived.isEmpty {
            return derived
        }
        if let session = try loadPersistedAuthSession() {
            let sessionAccessToken = session.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sessionAccessToken.isEmpty,
               let derived = deriveTenantIdentifier(accessToken: sessionAccessToken),
               !derived.isEmpty {
                return derived
            }
            let sessionUserIdentifier = session.userIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sessionUserIdentifier.isEmpty {
                return sessionUserIdentifier
            }
        }
        return ""
    }

    private func loadPersistedAuthSession() throws -> AuthSession? {
        do {
            return try KeychainManager.shared.loadAuthSessionStrict()
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

    private func validAccessToken(forceRefresh: Bool = false) async throws -> String {
        let envAccessToken = ProcessInfo.processInfo.environment["SKYBRIDGE_ACCESS_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !envAccessToken.isEmpty {
            return envAccessToken
        }
        guard let session = try loadPersistedAuthSession(),
              session.accessToken != "pending_verification",
              !session.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClientError.missingAuthentication
        }

        guard let refreshToken = session.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !refreshToken.isEmpty else {
            return session.accessToken
        }

        if !forceRefresh && !shouldRefreshAccessToken(session.accessToken) {
            return session.accessToken
        }

        if let existingRefreshTask = accessTokenRefreshTask {
            let refreshed = try await existingRefreshTask.value
            return refreshed.accessToken
        }

        let refreshTask = Task<AuthSession, Error> { @MainActor [session, refreshToken] in
            let refreshed = try await SupabaseService.shared.refreshSession(refreshToken: refreshToken)
            let merged = AuthSession(
                accessToken: refreshed.accessToken,
                refreshToken: refreshed.refreshToken ?? session.refreshToken,
                userIdentifier: session.userIdentifier,
                displayName: session.displayName,
                email: session.email,
                avatarURL: session.avatarURL,
                nebulaId: session.nebulaId,
                issuedAt: Date()
            )
            try KeychainManager.shared.storeAuthSession(merged)
            return merged
        }

        accessTokenRefreshTask = refreshTask
        defer {
            if accessTokenRefreshTask == refreshTask {
                accessTokenRefreshTask = nil
            }
        }

        let refreshed = try await refreshTask.value
        return refreshed.accessToken
    }

    private func shouldRefreshAccessToken(_ token: String, skewSeconds: TimeInterval = 300) -> Bool {
        guard let claims = decodeJWTClaims(token),
              let exp = claims["exp"] as? TimeInterval else {
            return false
        }
        let expiryDate = Date(timeIntervalSince1970: exp)
        return expiryDate.timeIntervalSinceNow <= skewSeconds
    }

    private func decodeJWTClaims(_ token: String) -> [String: Any]? {
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

    private func deriveTenantIdentifier(accessToken: String) -> String? {
        guard let claims = decodeJWTClaims(accessToken) else { return nil }
        let appMetadata = claims["app_metadata"] as? [String: Any]
        let userMetadata = claims["user_metadata"] as? [String: Any]
        let candidates: [Any?] = [
            appMetadata?["tenant_id"],
            appMetadata?["tenantId"],
            appMetadata?["org_id"],
            appMetadata?["workspace_id"],
            userMetadata?["tenant_id"],
            userMetadata?["tenantId"],
            userMetadata?["org_id"],
            userMetadata?["workspace_id"],
            claims["tenant_id"],
            claims["tenantId"],
            claims["sub"]
        ]
        for candidate in candidates {
            let value = String(describing: candidate ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty, value != "nil" {
                return value
            }
        }
        return nil
    }
}
