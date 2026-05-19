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
    }

    struct SessionRefreshLease: Sendable, Equatable {
        let sessionID: String
        let role: String
        let sessionToken: String
        let turnAdmissionToken: String
        let mediaAdmissionToken: String?
        let expiresIn: TimeInterval
        let signalingServerOrigin: String?
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
    }

    struct ConnectionCodeLookup: Sendable, Equatable {
        let sessionID: String
        let sessionToken: String
        let turnAdmissionToken: String
        let mediaAdmissionToken: String?
        let expiresIn: TimeInterval
        let signalingServerOrigin: String
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
            case .requestTimedOut(let path):
                return "当前跨网请求超时: \(path)"
            case .serverRejected(let status, let body):
                return "信令服务器拒绝请求 (\(status)): \(body)"
            case .malformedResponse(let reason):
                return "信令服务器响应格式错误: \(reason)"
            }
        }
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
    }

    private struct LookupCodeResponseBody: Decodable {
        let found: Bool
        let sessionId: String
        let sessionToken: String
        let turnAdmissionToken: String
        let mediaAdmissionToken: String?
        let expiresIn: Int
        let signalingServerOrigin: String
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
            "🌐 current-path request start path=/api/webrtc/admission/challenge deviceId=\(binding.deviceId, privacy: .public) alg=\(binding.protocolSigningAlgorithm.rawValue, privacy: .public)"
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
            "🌐 current-path request ok path=/api/webrtc/admission/challenge challengeId=\(response.challengeId, privacy: .public)"
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
            "🌐 current-path request start path=/api/webrtc/admission deviceId=\(binding.deviceId, privacy: .public) alg=\(binding.protocolSigningAlgorithm.rawValue, privacy: .public)"
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
            "🌐 current-path request start path=/api/webrtc/register-session sessionId=\(sessionId ?? "-", privacy: .public)"
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
            "🌐 current-path request ok path=/api/webrtc/register-session sessionId=\(response.sessionId, privacy: .public)"
        )
        return SessionLease(
            sessionID: response.sessionId,
            sessionToken: response.sessionToken,
            qrBootstrapToken: response.qrBootstrapToken,
            turnAdmissionToken: response.turnAdmissionToken,
            mediaAdmissionToken: normalizedOptionalToken(response.mediaAdmissionToken),
            expiresIn: TimeInterval(response.expiresIn),
            signalingServerOrigin: response.signalingServerOrigin
        )
    }

    func redeemSession(
        admissionToken: String,
        sessionId: String,
        qrBootstrapToken: String
    ) async throws -> RedeemedSessionLease {
        logger.info(
            "🌐 current-path request start path=/api/webrtc/redeem-session sessionId=\(sessionId, privacy: .public)"
        )
        let body = RedeemSessionRequestBody(
            sessionId: sessionId,
            qrBootstrapToken: qrBootstrapToken
        )
        let response: RedeemSessionResponseBody = try await performJSONRequest(
            path: "/api/webrtc/redeem-session",
            method: "POST",
            body: try JSONEncoder().encode(body),
            extraHeaders: ["X-SkyBridge-Admission": admissionToken]
        )
        logger.info(
            "🌐 current-path request ok path=/api/webrtc/redeem-session sessionId=\(response.sessionId, privacy: .public)"
        )
        return RedeemedSessionLease(
            sessionID: response.sessionId,
            sessionToken: response.sessionToken,
            turnAdmissionToken: response.turnAdmissionToken,
            mediaAdmissionToken: normalizedOptionalToken(response.mediaAdmissionToken),
            expiresIn: TimeInterval(response.expiresIn),
            signalingServerOrigin: response.signalingServerOrigin,
            initiatorDeviceId: response.initiatorDeviceId,
            initiatorProtocolSigningAlgorithm: ProtocolSigningAlgorithm(rawValue: response.initiatorProtocolSigningAlgorithm) ?? .ed25519,
            initiatorProtocolPublicKeyFingerprint: response.initiatorProtocolPublicKeyFingerprint
        )
    }

    func refreshWebRTCSession(
        admissionToken: String,
        sessionId: String,
        role: String
    ) async throws -> SessionRefreshLease {
        logger.info(
            "🌐 current-path request start path=/api/webrtc/session/refresh sessionId=\(sessionId, privacy: .public) role=\(role, privacy: .public)"
        )
        let body = SessionRefreshRequestBody(sessionId: sessionId, role: role)
        let response: SessionRefreshResponseBody = try await performJSONRequest(
            path: "/api/webrtc/session/refresh",
            method: "POST",
            body: try JSONEncoder().encode(body),
            extraHeaders: ["X-SkyBridge-Admission": admissionToken]
        )
        guard response.sessionId == sessionId,
              response.role == role,
              !response.sessionToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !response.turnAdmissionToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClientError.malformedResponse("invalid session refresh response")
        }
        logger.info(
            "🌐 current-path request ok path=/api/webrtc/session/refresh sessionId=\(response.sessionId, privacy: .public) role=\(response.role, privacy: .public) serverBuild=\(response.serverBuildFingerprint ?? "-", privacy: .public) sessionTokenGeneration=\(response.sessionTokenGeneration ?? "-", privacy: .public) mediaTokenGeneration=\(response.mediaTokenGeneration ?? "-", privacy: .public)"
        )
        return SessionRefreshLease(
            sessionID: response.sessionId,
            role: response.role,
            sessionToken: response.sessionToken,
            turnAdmissionToken: response.turnAdmissionToken,
            mediaAdmissionToken: normalizedOptionalToken(response.mediaAdmissionToken),
            expiresIn: TimeInterval(response.expiresIn),
            signalingServerOrigin: response.signalingServerOrigin,
            serverBuildFingerprint: response.serverBuildFingerprint,
            sessionTokenGeneration: response.sessionTokenGeneration,
            mediaTokenGeneration: response.mediaTokenGeneration
        )
    }

    func registerConnectionCode(
        admissionToken: String,
        deviceName: String,
        validDuration: TimeInterval
    ) async throws -> ConnectionCodeLease {
        logger.info(
            "🌐 current-path request start path=/api/webrtc/register-code deviceName=\(deviceName, privacy: .public)"
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
            "🌐 current-path request ok path=/api/webrtc/register-code sessionId=\(response.sessionId, privacy: .public) code=<redacted>"
        )
        return ConnectionCodeLease(
            code: response.code,
            sessionID: response.sessionId,
            sessionToken: response.sessionToken,
            turnAdmissionToken: response.turnAdmissionToken,
            mediaAdmissionToken: normalizedOptionalToken(response.mediaAdmissionToken),
            expiresIn: TimeInterval(response.expiresIn),
            signalingServerOrigin: response.signalingServerOrigin
        )
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
        guard !response.sessionToken.isEmpty else {
            throw ClientError.malformedResponse("missing sessionToken")
        }
        logger.info(
            "🌐 current-path request ok path=/api/webrtc/lookup sessionId=\(response.sessionId, privacy: .public) found=\(response.found)"
        )
        return ConnectionCodeLookup(
            sessionID: response.sessionId,
            sessionToken: response.sessionToken,
            turnAdmissionToken: response.turnAdmissionToken,
            mediaAdmissionToken: normalizedOptionalToken(response.mediaAdmissionToken),
            expiresIn: TimeInterval(response.expiresIn),
            signalingServerOrigin: response.signalingServerOrigin,
            initiatorDeviceId: response.initiatorDeviceId,
            initiatorProtocolSigningAlgorithm: ProtocolSigningAlgorithm(rawValue: response.initiatorProtocolSigningAlgorithm) ?? .ed25519,
            initiatorProtocolPublicKeyFingerprint: response.initiatorProtocolPublicKeyFingerprint,
            initiatorDeviceName: response.initiatorDeviceName
        )
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
            "🌐 current-path request ok path=/api/media/lease sessionId=\(response.sessionId, privacy: .public) role=\(response.role, privacy: .public) serverBuild=\(response.serverBuildFingerprint ?? "-", privacy: .public) refreshSupported=\(response.supportsMediaAdmissionRefresh == true, privacy: .public) mediaTokenGeneration=\(response.mediaTokenGeneration ?? "-", privacy: .public)"
        )
        return MediaRelayLease(
            sessionID: response.sessionId,
            role: response.role,
            endpoint: SkyBridgeMediaEndpoint(
                host: response.endpoint.host,
                port: response.endpoint.port,
                relayToken: response.leaseToken,
                expiresAt: Self.normalizedMediaRelayExpiresAt(response.expiresAt)
            ),
            ttl: TimeInterval(response.ttl),
            maxPacketBytes: response.maxPacketBytes
        )
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
              !response.mediaAdmissionToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClientError.malformedResponse("invalid media admission refresh response")
        }
        logger.info(
            "🌐 current-path request ok path=/api/media/admission/refresh sessionId=\(response.sessionId, privacy: .public) role=\(response.role, privacy: .public) serverBuild=\(response.serverBuildFingerprint ?? "-", privacy: .public) refreshSupported=\(response.supportsMediaAdmissionRefresh == true, privacy: .public) mediaTokenGeneration=\(response.mediaTokenGeneration ?? "-", privacy: .public)"
        )
        return MediaAdmissionRefreshLease(
            token: response.mediaAdmissionToken,
            expiresIn: TimeInterval(max(0, response.expiresIn)),
            serverBuildFingerprint: response.serverBuildFingerprint,
            mediaTokenGeneration: response.mediaTokenGeneration
        )
    }

    private var accessTokenRefreshTask: Task<AuthSession, Error>?

    static func testOnlyDecodeMediaRelayLeaseResponse(_ data: Data) throws -> MediaRelayLease {
        let response = try JSONDecoder().decode(MediaLeaseResponseBody.self, from: data)
        return MediaRelayLease(
            sessionID: response.sessionId,
            role: response.role,
            endpoint: SkyBridgeMediaEndpoint(
                host: response.endpoint.host,
                port: response.endpoint.port,
                relayToken: response.leaseToken,
                expiresAt: Self.normalizedMediaRelayExpiresAt(response.expiresAt)
            ),
            ttl: TimeInterval(response.ttl),
            maxPacketBytes: response.maxPacketBytes
        )
    }

    private static func normalizedMediaRelayExpiresAt(_ rawValue: Int64) -> TimeInterval {
        let seconds = TimeInterval(rawValue)
        return seconds > 10_000_000_000 ? seconds / 1000 : seconds
    }

    nonisolated static func testOnlyRequestTimeoutSeconds() -> TimeInterval {
        requestTimeoutSeconds
    }

    private func normalizedOptionalToken(_ token: String?) -> String? {
        guard let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
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
        let tenantID = currentTenantID().trimmingCharacters(in: .whitespacesAndNewlines)
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
                "❌ current-path request failed method=\(method, privacy: .public) path=\(path, privacy: .public) err=\(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyString = String(data: data, encoding: .utf8) ?? ""
            logger.error(
                "❌ current-path request rejected method=\(method, privacy: .public) path=\(path, privacy: .public) status=\(http.statusCode) body=\(bodyString, privacy: .public)"
            )
            throw ClientError.serverRejected(http.statusCode, bodyString)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            logger.error(
                "❌ current-path response decode failed path=\(path, privacy: .public) err=\(error.localizedDescription, privacy: .public)"
            )
            throw ClientError.malformedResponse(error.localizedDescription)
        }
    }

    private func currentTenantID() -> String {
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
        if let session = KeychainManager.shared.loadAuthSession() {
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
        guard let session = KeychainManager.shared.loadAuthSession(),
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
            try? KeychainManager.shared.storeAuthSession(merged)
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
