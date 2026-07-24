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
        public let mediaAdmissionToken: String?
        public let expiresIn: Int
        public let signalingServerOrigin: String
        public let wsPath: String?
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
        public let mediaAdmissionToken: String?
        public let expiresIn: Int
        public let signalingServerOrigin: String
        public let wsPath: String?
    }

    public struct LookupCodeResponseBody: Decodable, Sendable {
        public let found: Bool
        public let sessionId: String
        public let sessionToken: String
        public let turnAdmissionToken: String
        public let mediaAdmissionToken: String?
        public let expiresIn: Int
        public let signalingServerOrigin: String
        public let wsPath: String?
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
        public let mediaAdmissionToken: String?
        public let expiresIn: Int
        public let signalingServerOrigin: String
        public let wsPath: String?
        public let initiatorDeviceId: String
        public let initiatorProtocolSigningAlgorithm: ProtocolSigningAlgorithm
        public let initiatorProtocolPublicKeyFingerprint: String
    }

    public struct RegisterCurrentDeviceRequestBody: Encodable, Sendable {
        public let deviceId: String
        public let protocolSigningAlgorithm: ProtocolSigningAlgorithm
        public let protocolPublicKeyFingerprint: String
        public let clientVersion: String
        public let protocolVersion: String
        public let deviceName: String
    }

    public struct RegisteredDeviceResponseBody: Decodable, Sendable {
        public let registered: Bool
        public let activated: Bool
        public let device: RegisteredDeviceBody
    }

    public struct IdentityRotationChallengeRequestBody: Encodable, Sendable {
        public let deviceId: String
        public let protocolSigningAlgorithm: ProtocolSigningAlgorithm
        public let protocolPublicKeyFingerprint: String
        public let protocolPublicKeyBytes: Data
        public let newProtocolSigningAlgorithm: ProtocolSigningAlgorithm
        public let newProtocolPublicKeyFingerprint: String
        public let newProtocolPublicKeyBytes: Data
        public let clientVersion: String
        public let protocolVersion: String
    }

    public struct IdentityRotationChallengeResponseBody: Decodable, Sendable {
        public let requestId: String
        public let rotationId: String
        public let nonce: String
        public let state: String
        public let issuedAt: Int64
        public let expiresAt: Int64
        public let transcriptVersion: Int
        public let transcriptHash: String
        public let transcriptBase64: String
        public let tenantId: String
        public let userId: String
        public let deviceId: String
        public let oldGeneration: UInt64
        public let oldProtocolSigningAlgorithm: ProtocolSigningAlgorithm
        public let oldProtocolPublicKeyFingerprint: String
        public let newProtocolSigningAlgorithm: ProtocolSigningAlgorithm
        public let newProtocolPublicKeyFingerprint: String
    }

    public struct IdentityRotationCommitRequestBody: Encodable, Sendable {
        public let deviceId: String
        public let protocolSigningAlgorithm: ProtocolSigningAlgorithm
        public let protocolPublicKeyFingerprint: String
        public let rotationId: String
        public let transcriptHash: String
        public let oldSignature: Data
        public let newSignature: Data
        public let clientVersion: String
        public let protocolVersion: String
    }

    public struct IdentityRotationCommitResponseBody: Decodable, Sendable {
        public struct Identity: Decodable, Sendable {
            public let protocolSigningAlgorithm: ProtocolSigningAlgorithm
            public let protocolPublicKeyFingerprint: String
            public let state: String
            public let graceExpiresAt: Int64?
        }

        public let committed: Bool
        public let rotationId: String
        public let state: String
        public let committedAt: Int64
        public let generation: UInt64
        public let deviceId: String
        public let oldIdentity: Identity
        public let newIdentity: Identity
    }

    public struct PresenceRegisterResponseBody: Decodable, Sendable {
        public let online: Bool
        public let ttlMs: Int?
        public let expiresAt: Double?
    }

    public struct PresenceQueryResponseBody: Decodable, Sendable {
        public let online: [String]
    }

    public struct RegisteredDeviceBody: Decodable, Sendable, Equatable {
        public let tenantId: String
        public let userId: String
        public let deviceId: String
        public let protocolSigningAlgorithm: ProtocolSigningAlgorithm
        public let protocolPublicKeyFingerprint: String
        public let deviceName: String?
        public let status: String
        public let approvalMethod: String?

        enum CodingKeys: String, CodingKey {
            case tenantId = "tenant_id"
            case userId = "user_id"
            case deviceId = "device_id"
            case protocolSigningAlgorithm = "protocol_signing_algorithm"
            case protocolPublicKeyFingerprint = "protocol_public_key_fingerprint"
            case deviceName = "device_name"
            case status
            case approvalMethod = "approval_method"
        }
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

    public struct MediaAdmissionLease: Sendable, Equatable {
        public let token: String
        public let expiresIn: TimeInterval

        public init(token: String, expiresIn: TimeInterval) {
            self.token = token
            self.expiresIn = expiresIn
        }
    }

    public struct MediaRelayLease: Sendable, Equatable {
        public let sessionID: String
        public let role: String
        public let endpointHost: String
        public let endpointPort: UInt16
        public let leaseToken: String
        public let expiresAt: TimeInterval
        public let ttl: TimeInterval
        public let maxPacketBytes: Int

        public init(
            sessionID: String,
            role: String,
            endpointHost: String,
            endpointPort: UInt16,
            leaseToken: String,
            expiresAt: TimeInterval,
            ttl: TimeInterval,
            maxPacketBytes: Int
        ) {
            self.sessionID = sessionID
            self.role = role
            self.endpointHost = endpointHost
            self.endpointPort = endpointPort
            self.leaseToken = leaseToken
            self.expiresAt = expiresAt
            self.ttl = ttl
            self.maxPacketBytes = maxPacketBytes
        }
    }

    public struct ConnectionCodeLease: Sendable, Equatable {
        public let code: String
        public let sessionID: String
        public let sessionToken: String
        public let turnAdmissionLease: TurnAdmissionLease
        public let mediaAdmissionLease: MediaAdmissionLease?
        public let expiresIn: TimeInterval
        public let signalingServerOrigin: String
        public let wsPath: String?

        public var initiatorToken: String {
            sessionToken
        }
    }

    public struct ConnectionCodeLookup: Sendable, Equatable {
        public let sessionID: String
        public let sessionToken: String
        public let turnAdmissionLease: TurnAdmissionLease
        public let mediaAdmissionLease: MediaAdmissionLease?
        public let expiresIn: TimeInterval
        public let signalingServerOrigin: String
        public let wsPath: String?
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
        public let mediaAdmissionLease: MediaAdmissionLease?
        public let expiresIn: TimeInterval
        public let signalingServerOrigin: String
        public let wsPath: String?

        public var signalingToken: String {
            sessionToken
        }
    }

    public struct RedeemedSessionLease: Sendable, Equatable {
        public let sessionID: String
        public let sessionToken: String
        public let turnAdmissionLease: TurnAdmissionLease
        public let mediaAdmissionLease: MediaAdmissionLease?
        public let expiresIn: TimeInterval
        public let signalingServerOrigin: String
        public let wsPath: String?
        public let initiatorDeviceId: String
        public let initiatorProtocolSigningAlgorithm: ProtocolSigningAlgorithm
        public let initiatorProtocolPublicKeyFingerprint: String
    }

    public struct AuthenticatedRequestContext: Sendable, Equatable {
        public let bearerToken: String
        public let tenantID: String
        public let userID: String

        public init(bearerToken: String, tenantID: String, userID: String) {
            self.bearerToken = bearerToken
            self.tenantID = tenantID
            self.userID = userID
        }
    }

    public struct IdentityRotationAuthenticationScope: Sendable, Equatable {
        public let tenantID: String
        public let userID: String

        public init(tenantID: String, userID: String) {
            self.tenantID = tenantID
            self.userID = userID
        }
    }

    public struct IdentityRotationChallenge: Sendable, Equatable {
        public let transcript: DeviceIdentityRotationTranscript
        public let issuedAtMilliseconds: Int64
        public let clientVersion: String
        public let protocolVersion: String

        public var expiresAtMilliseconds: Int64 {
            transcript.expiresAtMilliseconds
        }

        public init(
            transcript: DeviceIdentityRotationTranscript,
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

    public struct IdentityRotationCommitReceipt: Sendable, Equatable {
        public let rotationID: String
        public let committedAtMilliseconds: Int64
        public let generation: UInt64
        public let oldGraceExpiresAtMilliseconds: Int64
        public let oldIdentity: ProtocolIdentityBinding
        public let newIdentity: ProtocolIdentityBinding
    }

    public enum ClientError: LocalizedError {
        case invalidBaseURL
        case invalidResponse
        case invalidRequestLimits
        case missingAuthentication
        case missingTenantID
        case missingUserID
        case authenticationSessionChanged
        case invalidIdempotencyKey
        case invalidDeviceName
        case requestTimedOut(String)
        case resourceDeadlineExceeded(String)
        case responseTooLarge(path: String, limitBytes: Int)
        case serverRejected(Int, String)
        case malformedResponse(String)

        public var errorDescription: String? {
            switch self {
            case .invalidBaseURL:
                return "信令服务器地址无效"
            case .invalidResponse:
                return "信令服务器返回了非 HTTP 响应"
            case .invalidRequestLimits:
                return "信令请求资源边界配置无效"
            case .missingAuthentication:
                return "缺少上游登录态，无法申请 admission"
            case .missingTenantID:
                return "缺少租户标识，无法访问当前租户的公网能力"
            case .missingUserID:
                return "缺少用户标识，无法绑定当前登录身份"
            case .authenticationSessionChanged:
                return "认证会话在请求期间发生变化，请重新发起"
            case .invalidIdempotencyKey:
                return "身份轮换请求缺少规范的幂等键"
            case .invalidDeviceName:
                return "当前设备名称不是规范的可注册名称"
            case .requestTimedOut(let path):
                return "信令请求超时: \(path)"
            case .resourceDeadlineExceeded(let path):
                return "信令请求超过总资源时限: \(path)"
            case .responseTooLarge(let path, let limitBytes):
                return "信令响应超过大小上限: \(path) limit=\(limitBytes)"
            case .serverRejected(let status, _):
                return "信令服务器拒绝请求 (\(status)): \(SignalServerClient.redactedServerRejectedBodyDescription)"
            case .malformedResponse(let reason):
                return "信令服务器响应格式错误: \(reason)"
            }
        }
    }

    public nonisolated static let redactedServerRejectedBodyDescription = "<redacted-server-error-body>"

    private nonisolated static let safeServerRejectedBodyStringKeys: Set<String> = [
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

    private nonisolated static let safeServerRejectedBodyBooleanKeys: Set<String> = [
        "mediaTokenExpectedPresent",
        "mediaTokenSessionPresent"
    ]

    public nonisolated static func sanitizedServerRejectedBodyDescription(from data: Data) -> String {
        let redactedSummary = "\(redactedServerRejectedBodyDescription) bytes=\(data.count)"
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

    public nonisolated static func isUncommittedIdentityRotationExpired(
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

    private nonisolated static func isSafeServerRejectedBodyStringValue(key: String, value: String) -> Bool {
        switch key {
        case "mediaTokenExpectedGeneration", "mediaTokenGeneration", "mediaTokenRequestGeneration":
            return isSafeMediaTokenGenerationPrefix(value)
        case "serverBuildFingerprint":
            return isSafeServerBuildFingerprint(value)
        default:
            return isSafeServerRejectedBodyToken(value)
        }
    }

    private nonisolated static func isSafeMediaTokenGenerationPrefix(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == value, value.count == 16 else { return false }
        return value.range(of: #"^[A-Fa-f0-9]{16}$"#, options: .regularExpression) != nil
    }

    private nonisolated static func isSafeServerBuildFingerprint(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == value, (1...128).contains(value.count) else { return false }
        return value.range(of: #"^[A-Za-z0-9_.:/@+-]+$"#, options: .regularExpression) != nil
    }

    private nonisolated static func isSafeServerRejectedBodyToken(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == value, (1...96).contains(value.count) else { return false }
        return value.range(of: #"^[A-Za-z0-9_.:-]+$"#, options: .regularExpression) != nil
    }

    private nonisolated static let absoluteMaximumResponseBytes = 1_024 * 1_024

    private let urlSession: URLSession
    private let baseURLProvider: @Sendable () -> String
    private let apiKeyProvider: @Sendable () -> String
    private let authenticatedRequestContextProvider: @Sendable () async throws -> AuthenticatedRequestContext
    private let tenantIDProvider: @Sendable () async throws -> String
    private let clientVersionProvider: @Sendable () -> String
    private let protocolVersionProvider: @Sendable () -> String
    private let requestTimeoutSeconds: TimeInterval
    private let resourceTimeoutSeconds: TimeInterval
    private let maximumResponseBytes: Int

    public static let admissionChallengePath = "/api/webrtc/admission/challenge"
    public static let admissionPath = "/api/webrtc/admission"
    public static let registerCodePath = "/api/webrtc/register-code"
    public static let registerSessionPath = "/api/webrtc/register-session"
    public static let redeemSessionPath = "/api/webrtc/redeem-session"
    public static let registerCurrentDevicePath = "/api/devices/register-current"
    public static let identityRotationChallengePath = "/api/devices/identity-rotation/challenge"
    public static let identityRotationCommitPath = "/api/devices/identity-rotation/commit"
    public static let presenceRegisterPath = "/api/presence/register"
    public static let presenceQueryPath = "/api/presence/query"
    public static let mediaLeasePath = "/api/media/lease"
    public static let mediaAdmissionRefreshPath = "/api/media/admission/refresh"

    public init(
        urlSession: URLSession? = nil,
        baseURLProvider: @escaping @Sendable () -> String = { SkyBridgeServerConfig.signalingServerURL },
        apiKeyProvider: @escaping @Sendable () -> String = { SkyBridgeServerConfig.clientAPIKey },
        authenticatedRequestContextProvider: @escaping @Sendable () async throws -> AuthenticatedRequestContext = {
            AuthenticatedRequestContext(bearerToken: "", tenantID: "", userID: "")
        },
        tenantIDProvider: @escaping @Sendable () async throws -> String = { "" },
        clientVersionProvider: @escaping @Sendable () -> String = {
            if let value = ProcessInfo.processInfo.environment["SKYBRIDGE_CLIENT_VERSION"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
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
        },
        requestTimeoutSeconds: TimeInterval = 30,
        resourceTimeoutSeconds: TimeInterval = 45,
        maximumResponseBytes: Int = 256 * 1_024
    ) {
        self.urlSession = urlSession ?? Self.makeDefaultURLSession(
            requestTimeoutSeconds: requestTimeoutSeconds,
            resourceTimeoutSeconds: resourceTimeoutSeconds
        )
        self.baseURLProvider = baseURLProvider
        self.apiKeyProvider = apiKeyProvider
        self.authenticatedRequestContextProvider = authenticatedRequestContextProvider
        self.tenantIDProvider = tenantIDProvider
        self.clientVersionProvider = clientVersionProvider
        self.protocolVersionProvider = protocolVersionProvider
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.resourceTimeoutSeconds = resourceTimeoutSeconds
        self.maximumResponseBytes = maximumResponseBytes
    }

    private nonisolated static func makeDefaultURLSession(
        requestTimeoutSeconds: TimeInterval,
        resourceTimeoutSeconds: TimeInterval
    ) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeoutSeconds
        configuration.timeoutIntervalForResource = resourceTimeoutSeconds
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
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
        return try Self.sessionLease(from: response)
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
        return try Self.connectionCodeLease(from: response)
    }

    public func lookupConnectionCode(admissionToken: String, code: String) async throws -> ConnectionCodeLookup {
        let response: LookupCodeResponseBody = try await performJSONRequest(
            path: Self.lookupCodePath(for: code),
            extraHeaders: [
                "X-SkyBridge-Admission": admissionToken
            ]
        )
        return try Self.connectionCodeLookup(from: response)
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
        return try Self.redeemedSessionLease(from: response)
    }

    public func authenticatedIdentityRotationScope() async throws
        -> IdentityRotationAuthenticationScope {
        let context = try await authenticatedRequestContext()
        return identityRotationScope(from: context)
    }

    public func registerCurrentDevice(
        binding: ProtocolIdentityBinding,
        deviceName: String,
        expectedScope: IdentityRotationAuthenticationScope
    ) async throws -> RegisteredDeviceBody {
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
        let requestBody = RegisterCurrentDeviceRequestBody(
            deviceId: binding.deviceId,
            protocolSigningAlgorithm: binding.protocolSigningAlgorithm,
            protocolPublicKeyFingerprint: binding.protocolPublicKeyFingerprint,
            clientVersion: clientVersionProvider(),
            protocolVersion: protocolVersionProvider(),
            deviceName: normalizedDeviceName
        )
        let response: RegisteredDeviceResponseBody = try await performJSONRequest(
            path: Self.registerCurrentDevicePath,
            method: "POST",
            body: try JSONEncoder().encode(requestBody),
            authenticationContext: authentication
        )
        guard response.registered,
              response.device.tenantId == expectedScope.tenantID,
              response.device.userId == expectedScope.userID,
              response.device.deviceId == binding.deviceId,
              response.device.protocolSigningAlgorithm
                == binding.protocolSigningAlgorithm,
              response.device.protocolPublicKeyFingerprint
                == binding.protocolPublicKeyFingerprint,
              response.device.status == "active" else {
            throw ClientError.malformedResponse(
                "current device registration changed the authenticated authority"
            )
        }
        return response.device
    }

    public func requestIdentityRotationChallenge(
        oldIdentity: ProtocolIdentityBinding,
        newIdentity: ProtocolIdentityBinding,
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
            throw ClientError.invalidIdempotencyKey
        }
        let clientVersion = clientVersionProvider()
        let protocolVersion = protocolVersionProvider()
        let authentication = try await authenticatedRequestContext(
            matching: expectedScope
        )
        let requestBody = IdentityRotationChallengeRequestBody(
            deviceId: oldIdentity.deviceId,
            protocolSigningAlgorithm: oldIdentity.protocolSigningAlgorithm,
            protocolPublicKeyFingerprint: oldIdentity.protocolPublicKeyFingerprint,
            protocolPublicKeyBytes: oldIdentity.protocolPublicKeyBytes,
            newProtocolSigningAlgorithm: newIdentity.protocolSigningAlgorithm,
            newProtocolPublicKeyFingerprint: newIdentity.protocolPublicKeyFingerprint,
            newProtocolPublicKeyBytes: newIdentity.protocolPublicKeyBytes,
            clientVersion: clientVersion,
            protocolVersion: protocolVersion
        )
        let response: IdentityRotationChallengeResponseBody = try await performJSONRequest(
            path: Self.identityRotationChallengePath,
            method: "POST",
            body: try JSONEncoder().encode(requestBody),
            authenticationContext: authentication,
            extraHeaders: ["Idempotency-Key": idempotencyKey]
        )
        guard response.state == "issued",
              response.requestId == idempotencyKey,
              response.transcriptVersion == Int(DeviceIdentityRotationTranscript.version),
              response.issuedAt > 0,
              response.expiresAt > response.issuedAt,
              response.deviceId == oldIdentity.deviceId,
              response.oldProtocolSigningAlgorithm == oldIdentity.protocolSigningAlgorithm,
              response.oldProtocolPublicKeyFingerprint
                == oldIdentity.protocolPublicKeyFingerprint,
              response.newProtocolSigningAlgorithm == newIdentity.protocolSigningAlgorithm,
              response.newProtocolPublicKeyFingerprint
                == newIdentity.protocolPublicKeyFingerprint,
              response.tenantId == expectedScope.tenantID,
              response.userId == expectedScope.userID else {
            throw ClientError.malformedResponse(
                "identity rotation challenge changed the requested authority"
            )
        }
        let transcript = try DeviceIdentityRotationTranscript(
            rotationID: response.rotationId,
            nonce: DeviceIdentityRotationTranscript.decodeCanonicalBase64URLNonce(
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
            clientVersion: clientVersion,
            protocolVersion: protocolVersion
        )
    }

    public func commitIdentityRotation(
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
        let requestBody = IdentityRotationCommitRequestBody(
            deviceId: transcript.deviceID,
            protocolSigningAlgorithm: transcript.oldIdentity.protocolSigningAlgorithm,
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
            path: Self.identityRotationCommitPath,
            method: "POST",
            body: try JSONEncoder().encode(requestBody),
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
                == transcript.oldIdentity.protocolSigningAlgorithm,
              response.oldIdentity.protocolPublicKeyFingerprint
                == transcript.oldIdentity.protocolPublicKeyFingerprint,
              let graceExpiresAt = response.oldIdentity.graceExpiresAt,
              graceExpiresAt > response.committedAt,
              response.newIdentity.state == "active",
              response.newIdentity.graceExpiresAt == nil,
              response.newIdentity.protocolSigningAlgorithm
                == transcript.newIdentity.protocolSigningAlgorithm,
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

    /// 注册/续约本设备在线状态（presence 心跳）。服务端从已验证 JWT + body 绑定派生身份。
    @discardableResult
    public func registerPresence(
        binding: ProtocolIdentityBinding,
        deviceName: String
    ) async throws -> Bool {
        let requestBody = RegisterCurrentDeviceRequestBody(
            deviceId: binding.deviceId,
            protocolSigningAlgorithm: binding.protocolSigningAlgorithm,
            protocolPublicKeyFingerprint: binding.protocolPublicKeyFingerprint,
            clientVersion: clientVersionProvider(),
            protocolVersion: protocolVersionProvider(),
            deviceName: deviceName
        )
        let response: PresenceRegisterResponseBody = try await performJSONRequest(
            path: Self.presenceRegisterPath,
            method: "POST",
            body: try JSONEncoder().encode(requestBody),
            requiresUserAuthentication: true
        )
        return response.online
    }

    /// 查询调用方自己的哪些设备 id 当前在线（绑定经 query 参数传递，与服务端 req.query 解析一致）。
    public func queryPresence(
        binding: ProtocolIdentityBinding,
        deviceIDs: [String]
    ) async throws -> [String] {
        let ids = Array(Set(deviceIDs.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })).prefix(200)
        guard !ids.isEmpty else { return [] }
        let response: PresenceQueryResponseBody = try await performJSONRequest(
            path: Self.presenceQueryPath,
            method: "GET",
            queryItems: [
                URLQueryItem(name: "deviceId", value: binding.deviceId),
                URLQueryItem(name: "protocolSigningAlgorithm", value: binding.protocolSigningAlgorithm.rawValue),
                URLQueryItem(name: "protocolPublicKeyFingerprint", value: binding.protocolPublicKeyFingerprint),
                URLQueryItem(name: "ids", value: ids.joined(separator: ","))
            ],
            requiresUserAuthentication: true
        )
        return response.online
    }

    public func requestMediaRelayLease(mediaAdmissionToken: String) async throws -> MediaRelayLease {
        let response: MediaLeaseResponseBody = try await performJSONRequest(
            path: Self.mediaLeasePath,
            method: "POST",
            body: Data("{}".utf8),
            extraHeaders: [
                "X-SkyBridge-Media-Admission": mediaAdmissionToken
            ]
        )
        return try Self.mediaRelayLease(from: response)
    }

    public func refreshMediaAdmissionToken(
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

    public func refreshMediaAdmissionLease(
        sessionId: String,
        sessionToken: String,
        role: String,
        idempotencyKey: String? = nil
    ) async throws -> MediaAdmissionLease {
        var headers = [
            "X-SkyBridge-Session": sessionToken
        ]
        if let idempotencyKey,
           !idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            headers["Idempotency-Key"] = idempotencyKey
        }
        let response: MediaAdmissionRefreshResponseBody = try await performJSONRequest(
            path: Self.mediaAdmissionRefreshPath,
            method: "POST",
            body: try JSONEncoder().encode(MediaAdmissionRefreshRequestBody(sessionId: sessionId, role: role)),
            extraHeaders: headers
        )
        guard response.sessionId == sessionId,
              response.role == role,
              !response.mediaAdmissionToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              response.expiresIn > 0 else {
            throw ClientError.malformedResponse("invalid media admission refresh response")
        }
        return MediaAdmissionLease(
            token: response.mediaAdmissionToken,
            expiresIn: TimeInterval(response.expiresIn)
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
        let expiresIn = try requiredPositiveInt(object["expiresIn"], field: "expiresIn")
        return ConnectionCodeLease(
            code: try requiredString(object["code"] as? String, field: "code"),
            sessionID: try requiredString(object["sessionId"] as? String, field: "sessionId"),
            sessionToken: try requiredString(object, keys: ["sessionToken", "initiatorToken"], field: "sessionToken"),
            turnAdmissionLease: try turnAdmissionLease(
                token: object["turnAdmissionToken"] as? String,
                expiresIn: expiresIn
            ),
            mediaAdmissionLease: try Self.mediaAdmissionLease(
                token: object["mediaAdmissionToken"] as? String,
                expiresIn: expiresIn
            ),
            expiresIn: TimeInterval(expiresIn),
            signalingServerOrigin: try requiredString(object["signalingServerOrigin"] as? String, field: "signalingServerOrigin"),
            wsPath: try requiredOptionalString(object["wsPath"] as? String, field: "wsPath")
        )
    }

    public static func decodeLookupCodeResponse(from data: Data) throws -> ConnectionCodeLookup {
        let object = try decodeJSONObject(from: data)
        guard (object["found"] as? Bool) != false else {
            throw ClientError.serverRejected(404, "code_not_found")
        }
        let expiresIn = try requiredPositiveInt(object["expiresIn"], field: "expiresIn")
        return ConnectionCodeLookup(
            sessionID: try requiredString(object["sessionId"] as? String, field: "sessionId"),
            sessionToken: try requiredString(object, keys: ["sessionToken", "responderToken"], field: "sessionToken"),
            turnAdmissionLease: try turnAdmissionLease(
                token: object["turnAdmissionToken"] as? String,
                expiresIn: expiresIn
            ),
            mediaAdmissionLease: try Self.mediaAdmissionLease(
                token: object["mediaAdmissionToken"] as? String,
                expiresIn: expiresIn
            ),
            expiresIn: TimeInterval(expiresIn),
            signalingServerOrigin: try requiredString(object["signalingServerOrigin"] as? String, field: "signalingServerOrigin"),
            wsPath: try requiredOptionalString(object["wsPath"] as? String, field: "wsPath"),
            initiatorDeviceId: try requiredString(object["initiatorDeviceId"] as? String, field: "initiatorDeviceId"),
            initiatorProtocolSigningAlgorithm: try requiredProtocolSigningAlgorithm(
                object["initiatorProtocolSigningAlgorithm"] as? String,
                field: "initiatorProtocolSigningAlgorithm"
            ),
            initiatorProtocolPublicKeyFingerprint: try requiredString(
                object["initiatorProtocolPublicKeyFingerprint"] as? String,
                field: "initiatorProtocolPublicKeyFingerprint"
            ),
            initiatorDeviceName: optionalString(object["initiatorDeviceName"] as? String)
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
        let expiresIn = try requiredPositiveInt(object["expiresIn"], field: "expiresIn")
        return SessionLease(
            sessionID: try requiredString(object["sessionId"] as? String, field: "sessionId"),
            sessionToken: try requiredString(
                object,
                keys: ["sessionToken", "initiatorSignalingToken"],
                field: "sessionToken"
            ),
            qrBootstrapToken: try requiredString(object["qrBootstrapToken"] as? String, field: "qrBootstrapToken"),
            turnAdmissionLease: try turnAdmissionLease(
                token: object["turnAdmissionToken"] as? String,
                expiresIn: expiresIn
            ),
            mediaAdmissionLease: try Self.mediaAdmissionLease(
                token: object["mediaAdmissionToken"] as? String,
                expiresIn: expiresIn
            ),
            expiresIn: TimeInterval(expiresIn),
            signalingServerOrigin: try requiredString(object["signalingServerOrigin"] as? String, field: "signalingServerOrigin"),
            wsPath: try requiredOptionalString(object["wsPath"] as? String, field: "wsPath")
        )
    }

    private static func sessionLease(from response: RegisterSessionResponseBody) throws -> SessionLease {
        let expiresIn = try requiredPositiveInt(response.expiresIn, field: "expiresIn")
        return SessionLease(
            sessionID: try requiredString(response.sessionId, field: "sessionId"),
            sessionToken: try requiredString(response.sessionToken, field: "sessionToken"),
            qrBootstrapToken: try requiredString(response.qrBootstrapToken, field: "qrBootstrapToken"),
            turnAdmissionLease: try turnAdmissionLease(token: response.turnAdmissionToken, expiresIn: expiresIn),
            mediaAdmissionLease: try mediaAdmissionLease(token: response.mediaAdmissionToken, expiresIn: expiresIn),
            expiresIn: TimeInterval(expiresIn),
            signalingServerOrigin: try requiredString(response.signalingServerOrigin, field: "signalingServerOrigin"),
            wsPath: try requiredOptionalString(response.wsPath, field: "wsPath")
        )
    }

    private static func redeemedSessionLease(from response: RedeemSessionResponseBody) throws -> RedeemedSessionLease {
        let expiresIn = try requiredPositiveInt(response.expiresIn, field: "expiresIn")
        return RedeemedSessionLease(
            sessionID: try requiredString(response.sessionId, field: "sessionId"),
            sessionToken: try requiredString(response.sessionToken, field: "sessionToken"),
            turnAdmissionLease: try turnAdmissionLease(token: response.turnAdmissionToken, expiresIn: expiresIn),
            mediaAdmissionLease: try mediaAdmissionLease(token: response.mediaAdmissionToken, expiresIn: expiresIn),
            expiresIn: TimeInterval(expiresIn),
            signalingServerOrigin: try requiredString(response.signalingServerOrigin, field: "signalingServerOrigin"),
            wsPath: try requiredOptionalString(response.wsPath, field: "wsPath"),
            initiatorDeviceId: try requiredString(response.initiatorDeviceId, field: "initiatorDeviceId"),
            initiatorProtocolSigningAlgorithm: response.initiatorProtocolSigningAlgorithm,
            initiatorProtocolPublicKeyFingerprint: try requiredString(
                response.initiatorProtocolPublicKeyFingerprint,
                field: "initiatorProtocolPublicKeyFingerprint"
            )
        )
    }

    private static func connectionCodeLease(from response: RegisterCodeResponseBody) throws -> ConnectionCodeLease {
        let expiresIn = try requiredPositiveInt(response.expiresIn, field: "expiresIn")
        return ConnectionCodeLease(
            code: try requiredString(response.code, field: "code"),
            sessionID: try requiredString(response.sessionId, field: "sessionId"),
            sessionToken: try requiredString(response.sessionToken, field: "sessionToken"),
            turnAdmissionLease: try turnAdmissionLease(token: response.turnAdmissionToken, expiresIn: expiresIn),
            mediaAdmissionLease: try mediaAdmissionLease(token: response.mediaAdmissionToken, expiresIn: expiresIn),
            expiresIn: TimeInterval(expiresIn),
            signalingServerOrigin: try requiredString(response.signalingServerOrigin, field: "signalingServerOrigin"),
            wsPath: try requiredOptionalString(response.wsPath, field: "wsPath")
        )
    }

    private static func connectionCodeLookup(from response: LookupCodeResponseBody) throws -> ConnectionCodeLookup {
        guard response.found else {
            throw ClientError.serverRejected(404, "code_not_found")
        }
        let expiresIn = try requiredPositiveInt(response.expiresIn, field: "expiresIn")
        return ConnectionCodeLookup(
            sessionID: try requiredString(response.sessionId, field: "sessionId"),
            sessionToken: try requiredString(response.sessionToken, field: "sessionToken"),
            turnAdmissionLease: try turnAdmissionLease(token: response.turnAdmissionToken, expiresIn: expiresIn),
            mediaAdmissionLease: try mediaAdmissionLease(token: response.mediaAdmissionToken, expiresIn: expiresIn),
            expiresIn: TimeInterval(expiresIn),
            signalingServerOrigin: try requiredString(response.signalingServerOrigin, field: "signalingServerOrigin"),
            wsPath: try requiredOptionalString(response.wsPath, field: "wsPath"),
            initiatorDeviceId: try requiredString(response.initiatorDeviceId, field: "initiatorDeviceId"),
            initiatorProtocolSigningAlgorithm: response.initiatorProtocolSigningAlgorithm,
            initiatorProtocolPublicKeyFingerprint: try requiredString(
                response.initiatorProtocolPublicKeyFingerprint,
                field: "initiatorProtocolPublicKeyFingerprint"
            ),
            initiatorDeviceName: optionalString(response.initiatorDeviceName)
        )
    }

    private static func mediaRelayLease(from response: MediaLeaseResponseBody) throws -> MediaRelayLease {
        let ttl = try requiredPositiveInt(response.ttl, field: "ttl")
        let endpointHost = try requiredString(response.endpoint.host, field: "endpoint.host")
        let leaseToken = try requiredString(response.leaseToken, field: "leaseToken")
        guard response.endpoint.port != 0 else {
            throw ClientError.malformedResponse("invalid endpoint.port")
        }
        guard response.maxPacketBytes > 0 else {
            throw ClientError.malformedResponse("invalid maxPacketBytes")
        }
        let expiresAt = normalizedMediaRelayExpiresAt(response.expiresAt)
        guard expiresAt > 0 else {
            throw ClientError.malformedResponse("invalid expiresAt")
        }
        return MediaRelayLease(
            sessionID: try requiredString(response.sessionId, field: "sessionId"),
            role: try requiredString(response.role, field: "role"),
            endpointHost: endpointHost,
            endpointPort: response.endpoint.port,
            leaseToken: leaseToken,
            expiresAt: expiresAt,
            ttl: TimeInterval(ttl),
            maxPacketBytes: response.maxPacketBytes
        )
    }

    private static func turnAdmissionLease(token: String?, expiresIn: Int) throws -> TurnAdmissionLease {
        TurnAdmissionLease(
            token: try requiredString(token, field: "turnAdmissionToken"),
            expiresIn: min(TimeInterval(expiresIn), 60)
        )
    }

    private static func mediaAdmissionLease(token: String?, expiresIn: Int) throws -> MediaAdmissionLease? {
        guard let token = optionalString(token) else {
            return nil
        }
        return MediaAdmissionLease(
            token: token,
            expiresIn: min(TimeInterval(expiresIn), 60)
        )
    }

    private static func requiredOptionalString(_ value: String?, field: String) throws -> String {
        try requiredString(value, field: field)
    }

    private static func requiredString(_ value: String?, field: String) throws -> String {
        guard let normalized = optionalString(value) else {
            throw ClientError.malformedResponse("missing \(field)")
        }
        return normalized
    }

    private static func requiredString(
        _ object: [String: Any],
        keys: [String],
        field: String
    ) throws -> String {
        for key in keys {
            if let normalized = optionalString(object[key] as? String) {
                return normalized
            }
        }
        throw ClientError.malformedResponse("missing \(field)")
    }

    private static func optionalString(_ value: String?) -> String? {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalized.isEmpty else {
            return nil
        }
        return normalized
    }

    private static func requiredPositiveInt(_ value: Any?, field: String) throws -> Int {
        guard let intValue = value as? Int,
              intValue > 0 else {
            throw ClientError.malformedResponse("invalid \(field)")
        }
        return intValue
    }

    private static func requiredProtocolSigningAlgorithm(
        _ value: String?,
        field: String
    ) throws -> ProtocolSigningAlgorithm {
        let rawValue = try requiredString(value, field: field)
        guard let algorithm = ProtocolSigningAlgorithm(rawValue: rawValue) else {
            throw ClientError.malformedResponse("invalid \(field)")
        }
        return algorithm
    }

    private static func normalizedMediaRelayExpiresAt(_ rawValue: Int64) -> TimeInterval {
        let seconds = TimeInterval(rawValue)
        return seconds > 10_000_000_000 ? seconds / 1000 : seconds
    }

    private static func decodeJSONObject(from data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClientError.malformedResponse("expected_object")
        }
        return object
    }

    private func authenticatedRequestContext() async throws
        -> AuthenticatedRequestContext {
        try validatedAuthenticationContext(
            await authenticatedRequestContextProvider()
        )
    }

    private func authenticatedRequestContext(
        matching expectedScope: IdentityRotationAuthenticationScope
    ) async throws -> AuthenticatedRequestContext {
        let context = try await authenticatedRequestContext()
        guard identityRotationScope(from: context) == expectedScope else {
            throw ClientError.authenticationSessionChanged
        }
        return context
    }

    private func validatedAuthenticationContext(
        _ context: AuthenticatedRequestContext
    ) throws -> AuthenticatedRequestContext {
        let bearerToken = context.bearerToken.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !bearerToken.isEmpty else {
            throw ClientError.missingAuthentication
        }
        guard bearerToken == context.bearerToken,
              bearerToken.utf8.count <= 1_048_576,
              !bearerToken.unicodeScalars.contains(
                where: CharacterSet.controlCharacters.contains
              ) else {
            throw ClientError.missingAuthentication
        }
        let tenantID = try validatedAuthenticationIdentity(
            context.tenantID,
            missingError: .missingTenantID
        )
        let userID = try validatedAuthenticationIdentity(
            context.userID,
            missingError: .missingUserID
        )
        return AuthenticatedRequestContext(
            bearerToken: bearerToken,
            tenantID: tenantID,
            userID: userID
        )
    }

    private func validatedAuthenticationIdentity(
        _ rawValue: String,
        missingError: ClientError
    ) throws -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw missingError }
        guard value == rawValue,
              value.utf8.count <= 256,
              !value.unicodeScalars.contains(
                where: CharacterSet.controlCharacters.contains
              ) else {
            throw missingError
        }
        return value
    }

    private func identityRotationScope(
        from context: AuthenticatedRequestContext
    ) -> IdentityRotationAuthenticationScope {
        IdentityRotationAuthenticationScope(
            tenantID: context.tenantID,
            userID: context.userID
        )
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
        request.timeoutInterval = requestTimeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let apiKey = apiKeyProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        if !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        }

        if let authenticationContext {
            let authentication = try validatedAuthenticationContext(
                authenticationContext
            )
            request.setValue(
                authentication.tenantID,
                forHTTPHeaderField: "X-SkyBridge-Tenant-Id"
            )
            request.setValue(
                "Bearer \(authentication.bearerToken)",
                forHTTPHeaderField: "Authorization"
            )
        } else if requiresUserAuthentication {
            let authentication = try await authenticatedRequestContext()
            request.setValue(
                authentication.tenantID,
                forHTTPHeaderField: "X-SkyBridge-Tenant-Id"
            )
            request.setValue(
                "Bearer \(authentication.bearerToken)",
                forHTTPHeaderField: "Authorization"
            )
        } else {
            let tenantID = try await tenantIDProvider()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !tenantID.isEmpty {
                request.setValue(tenantID, forHTTPHeaderField: "X-SkyBridge-Tenant-Id")
            }
        }

        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        for (field, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }

        let (data, response) = try await boundedResponse(for: request, path: path)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw ClientError.serverRejected(
                httpResponse.statusCode,
                Self.sanitizedServerRejectedBodyDescription(from: data)
            )
        }

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
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
}
