import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HTTPS client for the SkyBridge signaling control plane.
///
/// Why this lives in `SkyBridgeProtocolCore`:
/// - It only depends on Foundation networking primitives.
/// - It is part of the cross-platform session bootstrap path, not an Apple-only transport.
/// - It is off the media hot path, so modularizing it does not affect Apple-to-Apple throughput.
public actor SignalServerClient {
    public struct RegisterSessionRequestBody: Encodable, Sendable {
        public let sessionId: String?
        public let deviceId: String
        public let protocolSigningAlgorithm: ProtocolSigningAlgorithm
        public let protocolPublicKeyFingerprint: String
        public let ttlSeconds: Int

        public init(
            sessionId: String?,
            deviceId: String,
            protocolSigningAlgorithm: ProtocolSigningAlgorithm,
            protocolPublicKeyFingerprint: String,
            ttlSeconds: Int
        ) {
            self.sessionId = sessionId
            self.deviceId = deviceId
            self.protocolSigningAlgorithm = protocolSigningAlgorithm
            self.protocolPublicKeyFingerprint = protocolPublicKeyFingerprint
            self.ttlSeconds = ttlSeconds
        }
    }

    public struct RegisterSessionResponseBody: Codable, Sendable {
        public let sessionId: String
        public let initiatorSignalingToken: String
        public let qrBootstrapToken: String
        public let expiresIn: Int
        public let signalingServerOrigin: String

        public init(
            sessionId: String,
            initiatorSignalingToken: String,
            qrBootstrapToken: String,
            expiresIn: Int,
            signalingServerOrigin: String
        ) {
            self.sessionId = sessionId
            self.initiatorSignalingToken = initiatorSignalingToken
            self.qrBootstrapToken = qrBootstrapToken
            self.expiresIn = expiresIn
            self.signalingServerOrigin = signalingServerOrigin
        }
    }

    public struct RegisterCodeRequestBody: Encodable, Sendable {
        public let deviceId: String
        public let deviceName: String
        public let protocolSigningAlgorithm: ProtocolSigningAlgorithm
        public let protocolPublicKeyFingerprint: String
        public let ttlSeconds: Int

        public init(
            deviceId: String,
            deviceName: String,
            protocolSigningAlgorithm: ProtocolSigningAlgorithm,
            protocolPublicKeyFingerprint: String,
            ttlSeconds: Int
        ) {
            self.deviceId = deviceId
            self.deviceName = deviceName
            self.protocolSigningAlgorithm = protocolSigningAlgorithm
            self.protocolPublicKeyFingerprint = protocolPublicKeyFingerprint
            self.ttlSeconds = ttlSeconds
        }
    }

    public struct RegisterCodeResponseBody: Codable, Sendable {
        public let code: String
        public let sessionId: String
        public let initiatorToken: String
        public let expiresIn: Int
        public let signalingServerOrigin: String

        public init(
            code: String,
            sessionId: String,
            initiatorToken: String,
            expiresIn: Int,
            signalingServerOrigin: String
        ) {
            self.code = code
            self.sessionId = sessionId
            self.initiatorToken = initiatorToken
            self.expiresIn = expiresIn
            self.signalingServerOrigin = signalingServerOrigin
        }
    }

    public struct LookupCodeResponseBody: Codable, Sendable {
        public let found: Bool
        public let sessionId: String
        public let responderToken: String
        public let expiresIn: Int
        public let signalingServerOrigin: String
        public let initiatorDeviceId: String
        public let initiatorProtocolSigningAlgorithm: ProtocolSigningAlgorithm
        public let initiatorProtocolPublicKeyFingerprint: String
        public let initiatorDeviceName: String?

        public init(
            found: Bool,
            sessionId: String,
            responderToken: String,
            expiresIn: Int,
            signalingServerOrigin: String,
            initiatorDeviceId: String,
            initiatorProtocolSigningAlgorithm: ProtocolSigningAlgorithm,
            initiatorProtocolPublicKeyFingerprint: String,
            initiatorDeviceName: String? = nil
        ) {
            self.found = found
            self.sessionId = sessionId
            self.responderToken = responderToken
            self.expiresIn = expiresIn
            self.signalingServerOrigin = signalingServerOrigin
            self.initiatorDeviceId = initiatorDeviceId
            self.initiatorProtocolSigningAlgorithm = initiatorProtocolSigningAlgorithm
            self.initiatorProtocolPublicKeyFingerprint = initiatorProtocolPublicKeyFingerprint
            self.initiatorDeviceName = initiatorDeviceName
        }
    }

    public struct RedeemSessionRequestBody: Encodable, Sendable {
        public let sessionId: String
        public let qrBootstrapToken: String
        public let deviceId: String
        public let protocolSigningAlgorithm: ProtocolSigningAlgorithm
        public let protocolPublicKeyFingerprint: String

        public init(
            sessionId: String,
            qrBootstrapToken: String,
            deviceId: String,
            protocolSigningAlgorithm: ProtocolSigningAlgorithm,
            protocolPublicKeyFingerprint: String
        ) {
            self.sessionId = sessionId
            self.qrBootstrapToken = qrBootstrapToken
            self.deviceId = deviceId
            self.protocolSigningAlgorithm = protocolSigningAlgorithm
            self.protocolPublicKeyFingerprint = protocolPublicKeyFingerprint
        }
    }

    public struct RedeemSessionResponseBody: Codable, Sendable {
        public let sessionId: String
        public let responderSignalingToken: String
        public let expiresIn: Int
        public let signalingServerOrigin: String
        public let initiatorDeviceId: String
        public let initiatorProtocolSigningAlgorithm: ProtocolSigningAlgorithm
        public let initiatorProtocolPublicKeyFingerprint: String

        public init(
            sessionId: String,
            responderSignalingToken: String,
            expiresIn: Int,
            signalingServerOrigin: String,
            initiatorDeviceId: String,
            initiatorProtocolSigningAlgorithm: ProtocolSigningAlgorithm,
            initiatorProtocolPublicKeyFingerprint: String
        ) {
            self.sessionId = sessionId
            self.responderSignalingToken = responderSignalingToken
            self.expiresIn = expiresIn
            self.signalingServerOrigin = signalingServerOrigin
            self.initiatorDeviceId = initiatorDeviceId
            self.initiatorProtocolSigningAlgorithm = initiatorProtocolSigningAlgorithm
            self.initiatorProtocolPublicKeyFingerprint = initiatorProtocolPublicKeyFingerprint
        }
    }

    public struct ConnectionCodeLease: Sendable, Equatable {
        public let code: String
        public let sessionID: String
        public let initiatorToken: String
        public let expiresIn: TimeInterval
        public let signalingServerOrigin: String

        public init(
            code: String,
            sessionID: String,
            initiatorToken: String,
            expiresIn: TimeInterval,
            signalingServerOrigin: String
        ) {
            self.code = code
            self.sessionID = sessionID
            self.initiatorToken = initiatorToken
            self.expiresIn = expiresIn
            self.signalingServerOrigin = signalingServerOrigin
        }
    }

    public struct ConnectionCodeLookup: Sendable, Equatable {
        public let sessionID: String
        public let responderToken: String
        public let expiresIn: TimeInterval
        public let signalingServerOrigin: String
        public let initiatorDeviceId: String
        public let initiatorProtocolSigningAlgorithm: ProtocolSigningAlgorithm
        public let initiatorProtocolPublicKeyFingerprint: String
        public let initiatorDeviceName: String?

        public init(
            sessionID: String,
            responderToken: String,
            expiresIn: TimeInterval,
            signalingServerOrigin: String,
            initiatorDeviceId: String,
            initiatorProtocolSigningAlgorithm: ProtocolSigningAlgorithm,
            initiatorProtocolPublicKeyFingerprint: String,
            initiatorDeviceName: String? = nil
        ) {
            self.sessionID = sessionID
            self.responderToken = responderToken
            self.expiresIn = expiresIn
            self.signalingServerOrigin = signalingServerOrigin
            self.initiatorDeviceId = initiatorDeviceId
            self.initiatorProtocolSigningAlgorithm = initiatorProtocolSigningAlgorithm
            self.initiatorProtocolPublicKeyFingerprint = initiatorProtocolPublicKeyFingerprint
            self.initiatorDeviceName = initiatorDeviceName
        }
    }

    public struct SessionLease: Sendable, Equatable {
        public let sessionID: String
        public let initiatorSignalingToken: String
        public let qrBootstrapToken: String
        public let expiresIn: TimeInterval
        public let signalingServerOrigin: String

        public init(
            sessionID: String,
            initiatorSignalingToken: String,
            qrBootstrapToken: String,
            expiresIn: TimeInterval,
            signalingServerOrigin: String
        ) {
            self.sessionID = sessionID
            self.initiatorSignalingToken = initiatorSignalingToken
            self.qrBootstrapToken = qrBootstrapToken
            self.expiresIn = expiresIn
            self.signalingServerOrigin = signalingServerOrigin
        }

        public var signalingToken: String { initiatorSignalingToken }
    }

    public struct RedeemedSessionLease: Sendable, Equatable {
        public let sessionID: String
        public let responderSignalingToken: String
        public let expiresIn: TimeInterval
        public let signalingServerOrigin: String
        public let initiatorDeviceId: String
        public let initiatorProtocolSigningAlgorithm: ProtocolSigningAlgorithm
        public let initiatorProtocolPublicKeyFingerprint: String

        public init(
            sessionID: String,
            responderSignalingToken: String,
            expiresIn: TimeInterval,
            signalingServerOrigin: String,
            initiatorDeviceId: String,
            initiatorProtocolSigningAlgorithm: ProtocolSigningAlgorithm,
            initiatorProtocolPublicKeyFingerprint: String
        ) {
            self.sessionID = sessionID
            self.responderSignalingToken = responderSignalingToken
            self.expiresIn = expiresIn
            self.signalingServerOrigin = signalingServerOrigin
            self.initiatorDeviceId = initiatorDeviceId
            self.initiatorProtocolSigningAlgorithm = initiatorProtocolSigningAlgorithm
            self.initiatorProtocolPublicKeyFingerprint = initiatorProtocolPublicKeyFingerprint
        }
    }

    public enum ClientError: LocalizedError {
        case invalidBaseURL
        case invalidResponse
        case serverRejected(Int, String)
        case malformedResponse(String)

        public var errorDescription: String? {
            switch self {
            case .invalidBaseURL:
                return "信令服务器地址无效"
            case .invalidResponse:
                return "信令服务器返回了非 HTTP 响应"
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

    public static let registerCodePath = "/api/webrtc/register-code"
    public static let registerSessionPath = "/api/webrtc/register-session"
    public static let redeemSessionPath = "/api/webrtc/redeem-session"

    public init(
        urlSession: URLSession = .shared,
        baseURLProvider: @escaping @Sendable () -> String = { SkyBridgeServerConfig.signalingServerURL },
        apiKeyProvider: @escaping @Sendable () -> String = { SkyBridgeServerConfig.clientAPIKey }
    ) {
        self.urlSession = urlSession
        self.baseURLProvider = baseURLProvider
        self.apiKeyProvider = apiKeyProvider
    }

    public func registerSession(
        sessionID: String? = nil,
        binding: ProtocolIdentityBinding,
        validDuration: TimeInterval
    ) async throws -> SessionLease {
        let requestBody = Self.makeRegisterSessionRequestBody(
            sessionId: sessionID,
            binding: binding,
            ttlSeconds: max(60, Int(validDuration.rounded()))
        )
        let response: RegisterSessionResponseBody = try await performJSONRequest(
            path: Self.registerSessionPath,
            method: "POST",
            body: try JSONEncoder().encode(requestBody)
        )
        return try Self.decodeRegisterSessionResponse(from: try JSONEncoder().encode(response))
    }

    public func registerConnectionCode(
        binding: ProtocolIdentityBinding,
        deviceName: String,
        validDuration: TimeInterval
    ) async throws -> ConnectionCodeLease {
        let requestBody = Self.makeRegisterCodeRequestBody(
            binding: binding,
            deviceName: deviceName,
            ttlSeconds: max(60, Int(validDuration.rounded()))
        )
        let response: RegisterCodeResponseBody = try await performJSONRequest(
            path: Self.registerCodePath,
            method: "POST",
            body: try JSONEncoder().encode(requestBody)
        )
        return try Self.decodeRegisterCodeResponse(from: try JSONEncoder().encode(response))
    }

    public func lookupConnectionCode(code: String, binding: ProtocolIdentityBinding) async throws -> ConnectionCodeLookup {
        let response: LookupCodeResponseBody = try await performJSONRequest(
            path: Self.lookupCodePath(for: code),
            queryItems: [
                URLQueryItem(name: "deviceId", value: binding.deviceId),
                URLQueryItem(name: "protocolSigningAlgorithm", value: binding.protocolSigningAlgorithm.rawValue),
                URLQueryItem(name: "protocolPublicKeyFingerprint", value: binding.protocolPublicKeyFingerprint)
            ]
        )
        return try Self.decodeLookupCodeResponse(from: try JSONEncoder().encode(response))
    }

    public func redeemSession(
        sessionID: String,
        qrBootstrapToken: String,
        binding: ProtocolIdentityBinding
    ) async throws -> RedeemedSessionLease {
        let requestBody = RedeemSessionRequestBody(
            sessionId: sessionID,
            qrBootstrapToken: qrBootstrapToken,
            deviceId: binding.deviceId,
            protocolSigningAlgorithm: binding.protocolSigningAlgorithm,
            protocolPublicKeyFingerprint: binding.protocolPublicKeyFingerprint
        )
        let response: RedeemSessionResponseBody = try await performJSONRequest(
            path: Self.redeemSessionPath,
            method: "POST",
            body: try JSONEncoder().encode(requestBody)
        )
        return RedeemedSessionLease(
            sessionID: response.sessionId,
            responderSignalingToken: response.responderSignalingToken,
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

    public static func makeRegisterCodeRequestBody(
        binding: ProtocolIdentityBinding,
        deviceName: String,
        ttlSeconds: Int
    ) -> RegisterCodeRequestBody {
        RegisterCodeRequestBody(
            deviceId: binding.deviceId,
            deviceName: deviceName,
            protocolSigningAlgorithm: binding.protocolSigningAlgorithm,
            protocolPublicKeyFingerprint: binding.protocolPublicKeyFingerprint,
            ttlSeconds: ttlSeconds
        )
    }

    public static func makeRegisterSessionRequestBody(
        sessionId: String? = nil,
        binding: ProtocolIdentityBinding,
        ttlSeconds: Int
    ) -> RegisterSessionRequestBody {
        RegisterSessionRequestBody(
            sessionId: sessionId,
            deviceId: binding.deviceId,
            protocolSigningAlgorithm: binding.protocolSigningAlgorithm,
            protocolPublicKeyFingerprint: binding.protocolPublicKeyFingerprint,
            ttlSeconds: ttlSeconds
        )
    }

    public static func decodeRegisterCodeResponse(from data: Data) throws -> ConnectionCodeLease {
        let response = try JSONDecoder().decode(RegisterCodeResponseBody.self, from: data)
        return ConnectionCodeLease(
            code: response.code,
            sessionID: response.sessionId,
            initiatorToken: response.initiatorToken,
            expiresIn: TimeInterval(response.expiresIn),
            signalingServerOrigin: response.signalingServerOrigin
        )
    }

    public static func decodeLookupCodeResponse(from data: Data) throws -> ConnectionCodeLookup {
        let response = try JSONDecoder().decode(LookupCodeResponseBody.self, from: data)
        guard response.found else {
            throw ClientError.serverRejected(404, "code_not_found")
        }
        guard !response.responderToken.isEmpty else {
            throw ClientError.malformedResponse("missing responderToken")
        }
        return ConnectionCodeLookup(
            sessionID: response.sessionId,
            responderToken: response.responderToken,
            expiresIn: TimeInterval(response.expiresIn),
            signalingServerOrigin: response.signalingServerOrigin,
            initiatorDeviceId: response.initiatorDeviceId,
            initiatorProtocolSigningAlgorithm: response.initiatorProtocolSigningAlgorithm,
            initiatorProtocolPublicKeyFingerprint: response.initiatorProtocolPublicKeyFingerprint,
            initiatorDeviceName: response.initiatorDeviceName
        )
    }

    public static func decodeRegisterSessionResponse(from data: Data) throws -> SessionLease {
        let response = try JSONDecoder().decode(RegisterSessionResponseBody.self, from: data)
        return SessionLease(
            sessionID: response.sessionId,
            initiatorSignalingToken: response.initiatorSignalingToken,
            qrBootstrapToken: response.qrBootstrapToken,
            expiresIn: TimeInterval(response.expiresIn),
            signalingServerOrigin: response.signalingServerOrigin
        )
    }

    private func performJSONRequest<Response: Decodable>(
        path: String,
        method: String = "GET",
        queryItems: [URLQueryItem] = [],
        body: Data? = nil
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
        let apiKey = apiKeyProvider()
        if !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
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
