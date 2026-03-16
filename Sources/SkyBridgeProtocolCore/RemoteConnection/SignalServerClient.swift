import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public actor SignalServerClient {
    public struct AdmissionChallengeRequestBody: Encodable, Sendable {
        public let deviceId: String
        public let protocolSigningAlgorithm: ProtocolSigningAlgorithm
        public let protocolPublicKeyFingerprint: String
        public let clientVersion: String
        public let protocolVersion: String
    }

    public struct AdmissionChallengeResponseBody: Decodable, Sendable {
        public let challengeId: String
        public let nonce: String
        public let tenantId: String
        public let userId: String
        public let deviceId: String
        public let clientIpHash: String
        public let clientVersion: String
        public let protocolVersion: String
        public let state: String
        public let issuedAt: Int64
        public let expiresAt: Int64
    }

    public struct AdmissionRequestBody: Encodable, Sendable {
        public let challengeId: String
        public let signature: Data
        public let deviceId: String
        public let protocolSigningAlgorithm: ProtocolSigningAlgorithm
        public let protocolPublicKeyFingerprint: String
        public let protocolPublicKeyBytes: Data
        public let clientVersion: String
        public let protocolVersion: String
    }

    public struct AdmissionResponseBody: Decodable, Sendable {
        public let admissionToken: String
        public let state: String
        public let issuedAt: Int64
        public let expiresAt: Int64
    }

    public struct RegisterSessionRequestBody: Encodable, Sendable {
        public let sessionId: String?
        public let ttlSeconds: Int
    }

    public struct RegisterSessionResponseBody: Decodable, Sendable {
        public let sessionId: String
        public let sessionToken: String
        public let qrBootstrapToken: String
        public let turnAdmissionToken: String
        public let expiresIn: Int
        public let signalingServerOrigin: String
    }

    public struct RegisterCodeRequestBody: Encodable, Sendable {
        public let deviceName: String
        public let ttlSeconds: Int
    }

    public struct RegisterCodeResponseBody: Decodable, Sendable {
        public let code: String
        public let sessionId: String
        public let sessionToken: String
        public let turnAdmissionToken: String
        public let expiresIn: Int
        public let signalingServerOrigin: String
    }

    public struct LookupCodeResponseBody: Decodable, Sendable {
        public let found: Bool
        public let sessionId: String
        public let sessionToken: String
        public let turnAdmissionToken: String
        public let expiresIn: Int
        public let signalingServerOrigin: String
        public let initiatorDeviceId: String
        public let initiatorProtocolSigningAlgorithm: ProtocolSigningAlgorithm
        public let initiatorProtocolPublicKeyFingerprint: String
        public let initiatorDeviceName: String?
    }

    public struct RedeemSessionRequestBody: Encodable, Sendable {
        public let sessionId: String
        public let qrBootstrapToken: String
    }

    public struct RedeemSessionResponseBody: Decodable, Sendable {
        public let sessionId: String
        public let sessionToken: String
        public let turnAdmissionToken: String
        public let expiresIn: Int
        public let signalingServerOrigin: String
        public let initiatorDeviceId: String
        public let initiatorProtocolSigningAlgorithm: ProtocolSigningAlgorithm
        public let initiatorProtocolPublicKeyFingerprint: String
    }

    public struct AdmissionChallenge: Sendable, Equatable {
        public let challengeID: String
        public let nonce: String
        public let tenantID: String
        public let userID: String
        public let deviceID: String
        public let clientIPHash: String
        public let clientVersion: String
        public let protocolVersion: String
        public let state: String
        public let issuedAt: Date
        public let expiresAt: Date

        public init(
            challengeID: String,
            nonce: String,
            tenantID: String,
            userID: String,
            deviceID: String,
            clientIPHash: String,
            clientVersion: String,
            protocolVersion: String,
            state: String,
            issuedAt: Date,
            expiresAt: Date
        ) {
            self.challengeID = challengeID
            self.nonce = nonce
            self.tenantID = tenantID
            self.userID = userID
            self.deviceID = deviceID
            self.clientIPHash = clientIPHash
            self.clientVersion = clientVersion
            self.protocolVersion = protocolVersion
            self.state = state
            self.issuedAt = issuedAt
            self.expiresAt = expiresAt
        }

        public func signaturePayload() -> Data {
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

    public struct AdmissionLease: Sendable, Equatable {
        public let token: String
        public let state: String
        public let issuedAt: Date
        public let expiresAt: Date

        public init(token: String, state: String, issuedAt: Date, expiresAt: Date) {
            self.token = token
            self.state = state
            self.issuedAt = issuedAt
            self.expiresAt = expiresAt
        }

        public var expiresIn: TimeInterval {
            max(0, expiresAt.timeIntervalSinceNow)
        }
    }

    public struct TurnAdmissionLease: Sendable, Equatable {
        public let token: String
        public let expiresIn: TimeInterval

        public init(token: String, expiresIn: TimeInterval) {
            self.token = token
            self.expiresIn = expiresIn
        }
    }

    public struct ConnectionCodeLease: Sendable, Equatable {
        public let code: String
        public let sessionID: String
        public let sessionToken: String
        public let turnAdmissionLease: TurnAdmissionLease
        public let expiresIn: TimeInterval
        public let signalingServerOrigin: String

        public var initiatorToken: String {
            sessionToken
        }
    }

    public struct ConnectionCodeLookup: Sendable, Equatable {
        public let sessionID: String
        public let sessionToken: String
        public let turnAdmissionLease: TurnAdmissionLease
        public let expiresIn: TimeInterval
        public let signalingServerOrigin: String
        public let initiatorDeviceId: String
        public let initiatorProtocolSigningAlgorithm: ProtocolSigningAlgorithm
        public let initiatorProtocolPublicKeyFingerprint: String
        public let initiatorDeviceName: String?

        public var responderToken: String {
            sessionToken
        }
    }

    public struct SessionLease: Sendable, Equatable {
        public let sessionID: String
        public let sessionToken: String
        public let qrBootstrapToken: String
        public let turnAdmissionLease: TurnAdmissionLease
        public let expiresIn: TimeInterval
        public let signalingServerOrigin: String

        public var signalingToken: String {
            sessionToken
        }
    }

    public struct RedeemedSessionLease: Sendable, Equatable {
        public let sessionID: String
        public let sessionToken: String
        public let turnAdmissionLease: TurnAdmissionLease
        public let expiresIn: TimeInterval
        public let signalingServerOrigin: String
        public let initiatorDeviceId: String
        public let initiatorProtocolSigningAlgorithm: ProtocolSigningAlgorithm
        public let initiatorProtocolPublicKeyFingerprint: String
    }

    public enum ClientError: LocalizedError {
        case invalidBaseURL
        case invalidResponse
        case missingAuthentication
        case missingTenantID
        case serverRejected(Int, String)
        case malformedResponse(String)

        public var errorDescription: String? {
            switch self {
            case .invalidBaseURL:
                return "信令服务器地址无效"
            case .invalidResponse:
                return "信令服务器返回了非 HTTP 响应"
            case .missingAuthentication:
                return "缺少上游登录态，无法申请 admission"
            case .missingTenantID:
                return "缺少租户标识，无法访问当前租户的公网能力"
            case .serverRejected(let status, let body):
                return "信令服务器拒绝请求 (\(status)): \(body)"
            case .malformedResponse(let reason):
                return "信令服务器响应格式错误: \(reason)"
            }
        }
    }

    private let urlSession: URLSession
    private let baseURLProvider: @Sendable () -> String
    private let apiKeyProvider: @Sendable () -> String
    private let bearerTokenProvider: @Sendable () async throws -> String
    private let tenantIDProvider: @Sendable () async -> String
    private let clientVersionProvider: @Sendable () -> String
    private let protocolVersionProvider: @Sendable () -> String

    public static let admissionChallengePath = "/api/webrtc/admission/challenge"
    public static let admissionPath = "/api/webrtc/admission"
    public static let registerCodePath = "/api/webrtc/register-code"
    public static let registerSessionPath = "/api/webrtc/register-session"
    public static let redeemSessionPath = "/api/webrtc/redeem-session"

    public init(
        urlSession: URLSession = .shared,
        baseURLProvider: @escaping @Sendable () -> String = { SkyBridgeServerConfig.signalingServerURL },
        apiKeyProvider: @escaping @Sendable () -> String = { SkyBridgeServerConfig.clientAPIKey },
        bearerTokenProvider: @escaping @Sendable () async throws -> String = { "" },
        tenantIDProvider: @escaping @Sendable () async -> String = { "" },
        clientVersionProvider: @escaping @Sendable () -> String = {
            if let value = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            return "0.0.0"
        },
        protocolVersionProvider: @escaping @Sendable () -> String = {
            if let value = ProcessInfo.processInfo.environment["SKYBRIDGE_PROTOCOL_VERSION"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
            return "1"
        }
    ) {
        self.urlSession = urlSession
        self.baseURLProvider = baseURLProvider
        self.apiKeyProvider = apiKeyProvider
        self.bearerTokenProvider = bearerTokenProvider
        self.tenantIDProvider = tenantIDProvider
        self.clientVersionProvider = clientVersionProvider
        self.protocolVersionProvider = protocolVersionProvider
    }

    public func requestAdmissionChallenge(binding: ProtocolIdentityBinding) async throws -> AdmissionChallenge {
        let requestBody = AdmissionChallengeRequestBody(
            deviceId: binding.deviceId,
            protocolSigningAlgorithm: binding.protocolSigningAlgorithm,
            protocolPublicKeyFingerprint: binding.protocolPublicKeyFingerprint,
            clientVersion: clientVersionProvider(),
            protocolVersion: protocolVersionProvider()
        )
        let response: AdmissionChallengeResponseBody = try await performJSONRequest(
            path: Self.admissionChallengePath,
            method: "POST",
            body: try JSONEncoder().encode(requestBody),
            requiresUserAuthentication: true
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

    public func completeAdmission(
        challenge: AdmissionChallenge,
        binding: ProtocolIdentityBinding,
        signature: Data
    ) async throws -> AdmissionLease {
        let requestBody = AdmissionRequestBody(
            challengeId: challenge.challengeID,
            signature: signature,
            deviceId: binding.deviceId,
            protocolSigningAlgorithm: binding.protocolSigningAlgorithm,
            protocolPublicKeyFingerprint: binding.protocolPublicKeyFingerprint,
            protocolPublicKeyBytes: binding.protocolPublicKeyBytes,
            clientVersion: challenge.clientVersion,
            protocolVersion: challenge.protocolVersion
        )
        let response: AdmissionResponseBody = try await performJSONRequest(
            path: Self.admissionPath,
            method: "POST",
            body: try JSONEncoder().encode(requestBody),
            requiresUserAuthentication: true
        )
        return AdmissionLease(
            token: response.admissionToken,
            state: response.state,
            issuedAt: Date(timeIntervalSince1970: TimeInterval(response.issuedAt) / 1000),
            expiresAt: Date(timeIntervalSince1970: TimeInterval(response.expiresAt) / 1000)
        )
    }

    public func registerSession(
        admissionToken: String,
        sessionID: String? = nil,
        validDuration: TimeInterval
    ) async throws -> SessionLease {
        let requestBody = RegisterSessionRequestBody(
            sessionId: sessionID,
            ttlSeconds: max(60, Int(validDuration.rounded()))
        )
        let response: RegisterSessionResponseBody = try await performJSONRequest(
            path: Self.registerSessionPath,
            method: "POST",
            body: try JSONEncoder().encode(requestBody),
            extraHeaders: [
                "X-SkyBridge-Admission": admissionToken
            ]
        )
        return SessionLease(
            sessionID: response.sessionId,
            sessionToken: response.sessionToken,
            qrBootstrapToken: response.qrBootstrapToken,
            turnAdmissionLease: TurnAdmissionLease(
                token: response.turnAdmissionToken,
                expiresIn: min(TimeInterval(response.expiresIn), 60)
            ),
            expiresIn: TimeInterval(response.expiresIn),
            signalingServerOrigin: response.signalingServerOrigin
        )
    }

    public func registerConnectionCode(
        admissionToken: String,
        deviceName: String,
        validDuration: TimeInterval
    ) async throws -> ConnectionCodeLease {
        let requestBody = RegisterCodeRequestBody(
            deviceName: deviceName,
            ttlSeconds: max(60, Int(validDuration.rounded()))
        )
        let response: RegisterCodeResponseBody = try await performJSONRequest(
            path: Self.registerCodePath,
            method: "POST",
            body: try JSONEncoder().encode(requestBody),
            extraHeaders: [
                "X-SkyBridge-Admission": admissionToken
            ]
        )
        return ConnectionCodeLease(
            code: response.code,
            sessionID: response.sessionId,
            sessionToken: response.sessionToken,
            turnAdmissionLease: TurnAdmissionLease(
                token: response.turnAdmissionToken,
                expiresIn: min(TimeInterval(response.expiresIn), 60)
            ),
            expiresIn: TimeInterval(response.expiresIn),
            signalingServerOrigin: response.signalingServerOrigin
        )
    }

    public func lookupConnectionCode(admissionToken: String, code: String) async throws -> ConnectionCodeLookup {
        let response: LookupCodeResponseBody = try await performJSONRequest(
            path: Self.lookupCodePath(for: code),
            extraHeaders: [
                "X-SkyBridge-Admission": admissionToken
            ]
        )
        guard response.found else {
            throw ClientError.serverRejected(404, "code_not_found")
        }
        return ConnectionCodeLookup(
            sessionID: response.sessionId,
            sessionToken: response.sessionToken,
            turnAdmissionLease: TurnAdmissionLease(
                token: response.turnAdmissionToken,
                expiresIn: min(TimeInterval(response.expiresIn), 60)
            ),
            expiresIn: TimeInterval(response.expiresIn),
            signalingServerOrigin: response.signalingServerOrigin,
            initiatorDeviceId: response.initiatorDeviceId,
            initiatorProtocolSigningAlgorithm: response.initiatorProtocolSigningAlgorithm,
            initiatorProtocolPublicKeyFingerprint: response.initiatorProtocolPublicKeyFingerprint,
            initiatorDeviceName: response.initiatorDeviceName
        )
    }

    public func redeemSession(
        admissionToken: String,
        sessionID: String,
        qrBootstrapToken: String,
        idempotencyKey: String? = nil
    ) async throws -> RedeemedSessionLease {
        let requestBody = RedeemSessionRequestBody(
            sessionId: sessionID,
            qrBootstrapToken: qrBootstrapToken
        )
        var headers = [
            "X-SkyBridge-Admission": admissionToken
        ]
        if let idempotencyKey, !idempotencyKey.isEmpty {
            headers["Idempotency-Key"] = idempotencyKey
        }
        let response: RedeemSessionResponseBody = try await performJSONRequest(
            path: Self.redeemSessionPath,
            method: "POST",
            body: try JSONEncoder().encode(requestBody),
            extraHeaders: headers
        )
        return RedeemedSessionLease(
            sessionID: response.sessionId,
            sessionToken: response.sessionToken,
            turnAdmissionLease: TurnAdmissionLease(
                token: response.turnAdmissionToken,
                expiresIn: min(TimeInterval(response.expiresIn), 60)
            ),
            expiresIn: TimeInterval(response.expiresIn),
            signalingServerOrigin: response.signalingServerOrigin,
            initiatorDeviceId: response.initiatorDeviceId,
            initiatorProtocolSigningAlgorithm: response.initiatorProtocolSigningAlgorithm,
            initiatorProtocolPublicKeyFingerprint: response.initiatorProtocolPublicKeyFingerprint
        )
    }

    public static func lookupCodePath(for code: String) -> String {
        let encoded = code.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? code
        return "/api/webrtc/lookup/\(encoded)"
    }

    public struct LegacyRegisterCodeRequestBody: Encodable, Sendable {
        public let deviceId: String
        public let deviceName: String
        public let protocolSigningAlgorithm: String
        public let protocolPublicKeyFingerprint: String
        public let ttlSeconds: Int
    }

    public static func makeRegisterCodeRequestBody(
        binding: ProtocolIdentityBinding,
        deviceName: String,
        ttlSeconds: Int
    ) -> LegacyRegisterCodeRequestBody {
        LegacyRegisterCodeRequestBody(
            deviceId: binding.deviceId,
            deviceName: deviceName,
            protocolSigningAlgorithm: binding.protocolSigningAlgorithm.rawValue,
            protocolPublicKeyFingerprint: binding.protocolPublicKeyFingerprint,
            ttlSeconds: ttlSeconds
        )
    }

    public static func decodeRegisterCodeResponse(from data: Data) throws -> ConnectionCodeLease {
        let object = try decodeJSONObject(from: data)
        let sessionToken = (object["sessionToken"] as? String) ?? (object["initiatorToken"] as? String) ?? ""
        let turnAdmissionToken = (object["turnAdmissionToken"] as? String) ?? ""
        let expiresIn = (object["expiresIn"] as? Int) ?? 0
        return ConnectionCodeLease(
            code: (object["code"] as? String) ?? "",
            sessionID: (object["sessionId"] as? String) ?? "",
            sessionToken: sessionToken,
            turnAdmissionLease: TurnAdmissionLease(
                token: turnAdmissionToken,
                expiresIn: min(TimeInterval(expiresIn), 60)
            ),
            expiresIn: TimeInterval(expiresIn),
            signalingServerOrigin: (object["signalingServerOrigin"] as? String) ?? ""
        )
    }

    public static func decodeLookupCodeResponse(from data: Data) throws -> ConnectionCodeLookup {
        let object = try decodeJSONObject(from: data)
        guard (object["found"] as? Bool) != false else {
            throw ClientError.serverRejected(404, "code_not_found")
        }
        let turnAdmissionToken = (object["turnAdmissionToken"] as? String) ?? ""
        let expiresIn = (object["expiresIn"] as? Int) ?? 0
        let rawAlgorithm = (object["initiatorProtocolSigningAlgorithm"] as? String) ?? ProtocolSigningAlgorithm.ed25519.rawValue
        return ConnectionCodeLookup(
            sessionID: (object["sessionId"] as? String) ?? "",
            sessionToken: (object["sessionToken"] as? String) ?? (object["responderToken"] as? String) ?? "",
            turnAdmissionLease: TurnAdmissionLease(
                token: turnAdmissionToken,
                expiresIn: min(TimeInterval(expiresIn), 60)
            ),
            expiresIn: TimeInterval(expiresIn),
            signalingServerOrigin: (object["signalingServerOrigin"] as? String) ?? "",
            initiatorDeviceId: (object["initiatorDeviceId"] as? String) ?? "",
            initiatorProtocolSigningAlgorithm: ProtocolSigningAlgorithm(rawValue: rawAlgorithm) ?? .ed25519,
            initiatorProtocolPublicKeyFingerprint: (object["initiatorProtocolPublicKeyFingerprint"] as? String) ?? "",
            initiatorDeviceName: object["initiatorDeviceName"] as? String
        )
    }

    public struct LegacyRegisterSessionRequestBody: Encodable, Sendable {
        public let sessionId: String
        public let deviceId: String
        public let protocolSigningAlgorithm: String
        public let protocolPublicKeyFingerprint: String
        public let ttlSeconds: Int
    }

    public static func makeRegisterSessionRequestBody(
        sessionId: String,
        binding: ProtocolIdentityBinding,
        ttlSeconds: Int
    ) -> LegacyRegisterSessionRequestBody {
        LegacyRegisterSessionRequestBody(
            sessionId: sessionId,
            deviceId: binding.deviceId,
            protocolSigningAlgorithm: binding.protocolSigningAlgorithm.rawValue,
            protocolPublicKeyFingerprint: binding.protocolPublicKeyFingerprint,
            ttlSeconds: ttlSeconds
        )
    }

    public static func decodeRegisterSessionResponse(from data: Data) throws -> SessionLease {
        let object = try decodeJSONObject(from: data)
        let sessionToken = (object["sessionToken"] as? String) ?? (object["initiatorSignalingToken"] as? String) ?? ""
        let turnAdmissionToken = (object["turnAdmissionToken"] as? String) ?? ""
        let expiresIn = (object["expiresIn"] as? Int) ?? 0
        return SessionLease(
            sessionID: (object["sessionId"] as? String) ?? "",
            sessionToken: sessionToken,
            qrBootstrapToken: (object["qrBootstrapToken"] as? String) ?? "",
            turnAdmissionLease: TurnAdmissionLease(
                token: turnAdmissionToken,
                expiresIn: min(TimeInterval(expiresIn), 60)
            ),
            expiresIn: TimeInterval(expiresIn),
            signalingServerOrigin: (object["signalingServerOrigin"] as? String) ?? ""
        )
    }

    private static func decodeJSONObject(from data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClientError.malformedResponse("expected_object")
        }
        return object
    }

    private func performJSONRequest<Response: Decodable>(
        path: String,
        method: String = "GET",
        queryItems: [URLQueryItem] = [],
        body: Data? = nil,
        requiresUserAuthentication: Bool = false,
        extraHeaders: [String: String] = [:]
    ) async throws -> Response {
        guard var components = URLComponents(string: baseURLProvider()) else {
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

        let apiKey = apiKeyProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        if !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        }

        let tenantID = await tenantIDProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        if requiresUserAuthentication && tenantID.isEmpty {
            throw ClientError.missingTenantID
        }
        if !tenantID.isEmpty {
            request.setValue(tenantID, forHTTPHeaderField: "X-SkyBridge-Tenant-Id")
        }

        if requiresUserAuthentication {
            let bearerToken = try await bearerTokenProvider().trimmingCharacters(in: .whitespacesAndNewlines)
            if bearerToken.isEmpty {
                throw ClientError.missingAuthentication
            }
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }

        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        for (field, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? "unknown_error"
            throw ClientError.serverRejected(httpResponse.statusCode, bodyText)
        }

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw ClientError.malformedResponse(error.localizedDescription)
        }
    }
}
