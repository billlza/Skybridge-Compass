import Foundation
import CryptoKit
import OSLog
#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif
#if canImport(UIKit)
import UIKit
import UserNotifications
#endif

// MARK: - iOS-local server config (file-local, to avoid target membership issues)

// MARK: - iOS-local crypto helpers (file-local, to avoid target membership issues)

/// Minimal SHA-256 helper used by WebRTC chunking / integrity checks.
@available(iOS 17.0, *)
private enum CrossNetworkCryptoCompat {
    static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }
}

/// Deterministic SHA-256 Merkle tree helper for chunk root computation.
@available(iOS 17.0, *)
private enum CrossNetworkMerkleCompat {
    /// Deterministic SHA-256 Merkle root:
    /// - Leaves are per-chunk SHA-256 digests (32B), ordered by chunkIndex.
    /// - Parent = SHA256(left || right)
    /// - Odd count: duplicate last.
    static func root(leaves: [Data]) -> Data? {
        guard !leaves.isEmpty else { return nil }
        guard leaves.allSatisfy({ $0.count == 32 }) else { return nil }

        var level = leaves
        while level.count > 1 {
            var next: [Data] = []
            next.reserveCapacity((level.count + 1) / 2)
            var i = 0
            while i < level.count {
                let left = level[i]
                let right = (i + 1 < level.count) ? level[i + 1] : left
                next.append(CrossNetworkCryptoCompat.sha256(left + right))
                i += 2
            }
            level = next
        }
        return level.first
    }
}

/// Auth helper for Merkle root verification (HMAC over deterministic preimage).
@available(iOS 17.0, *)
private enum CrossNetworkMerkleAuthCompat {
    static let signatureAlgV1 = "hmac-sha256-session-v1"

    // Must match Android MerkleRootAuthV1.preimage
    static func preimage(transferId: String, merkleRoot: Data, fileSha256: Data?) -> Data {
        var out = Data()
        out.append(Data("SkyBridge-MerkleRoot|v1|".utf8))

        let tid = transferId.data(using: .utf8) ?? Data()
        out.append(u16le(tid.count))
        out.append(tid)

        out.append(u16le(merkleRoot.count))
        out.append(merkleRoot)

        let f = fileSha256 ?? Data()
        out.append(u16le(f.count))
        out.append(f)
        return out
    }

    static func hmacSha256(key: Data, data: Data) -> Data {
        let k = SymmetricKey(data: key)
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: k)
        return Data(mac)
    }

    private static func u16le(_ v: Int) -> Data {
        var x = UInt16(max(0, min(65535, v))).littleEndian
        return Data(bytes: &x, count: 2)
    }
}

private let currentPathWebRTCHandshakeMaxChunkBytes = 1024
private let currentPathWebRTCHandshakeMaxPaddedPayloadBytes = (8 * 1024) - 4

@available(iOS 17.0, *)
private struct CurrentPathWebRTCHandshakeTransportCompat: DiscoveryTransport {
    let sendFramed: @Sendable (Data) async throws -> Void

    func send(to peer: PeerIdentifier, data: Data) async throws {
        try await sendFramed(data)
    }
}

@available(iOS 17.0, *)
private enum CrossNetworkServerConfig {
    private static func environmentValue(_ name: String) -> String? {
        guard let raw = ProcessInfo.processInfo.environment[name] else { return nil }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func environmentValue(_ name: String, default defaultValue: String) -> String {
        guard let value = environmentValue(name), !value.isEmpty else { return defaultValue }
        return value
    }

    private static func environmentList(_ name: String, default defaultValue: [String]) -> [String] {
        guard let raw = ProcessInfo.processInfo.environment[name] else {
            return defaultValue
        }
        return raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static var signalingWebSocketURL: String {
        environmentValue("SKYBRIDGE_SIGNALING_WEBSOCKET_URL", default: "wss://api.nebula-technologies.net/ws")
    }

    static var signalingServerURL: String {
        environmentValue("SKYBRIDGE_SIGNALING_SERVER_URL", default: "https://api.nebula-technologies.net")
    }

    static var stunURL: String {
        environmentValue("SKYBRIDGE_STUN_URL", default: "stun:54.92.79.99:3478")
    }

    static var turnURL: String {
        environmentValue("SKYBRIDGE_TURN_URL", default: "turn:54.92.79.99:3478?transport=udp")
    }

    static var turnTLSURL: String {
        environmentValue("SKYBRIDGE_TURN_TLS_URL", default: "turns:54.92.79.99:5349?transport=tcp")
    }

    static var turnURLs: [String] {
        environmentList("SKYBRIDGE_TURN_URLS", default: [turnTLSURL, turnURL])
    }

    static var clientAPIKey: String {
        ProcessInfo.processInfo.environment["SKYBRIDGE_CLIENT_API_KEY"] ?? "skybridge-client-v1"
    }

    static func dynamicICEConfig(turnAdmissionToken: String?) async -> WebRTCSession.ICEConfig {
        let creds = await CrossNetworkTURNCredentialService.shared.getCredentials(turnAdmissionToken: turnAdmissionToken)
        let turnUsername = normalizedValue(creds.username)
        let turnPassword = normalizedValue(creds.password)
        let turnURIs = preferredTurnURIs(from: creds.uris, fallback: turnURLs)
        let shouldUseTURN = !turnUsername.isEmpty && !turnPassword.isEmpty && !turnURIs.isEmpty

        return WebRTCSession.ICEConfig(
            stunURL: stunURL,
            turnURLs: shouldUseTURN ? turnURIs : [],
            turnUsername: shouldUseTURN ? turnUsername : "",
            turnPassword: shouldUseTURN ? turnPassword : ""
        )
    }

    private static func normalizedValue(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    fileprivate static func normalizedTurnURIs(_ uris: [String]) -> [String] {
        var seen = Set<String>()
        return uris
            .map { normalizedValue($0) }
            .filter { uri in
                let lower = uri.lowercased()
                guard lower.hasPrefix("turn:") || lower.hasPrefix("turns:") else {
                    return false
                }
                if seen.contains(lower) {
                    return false
                }
                seen.insert(lower)
                return true
            }
    }

    fileprivate static func turnPriority(_ uri: String) -> Int {
        let lower = uri.lowercased()
        if lower.hasPrefix("turns:") { return 0 }
        if lower.contains("transport=tcp") { return 1 }
        return 2
    }

    fileprivate static func preferredTurnURIs(from uris: [String], fallback: [String]) -> [String] {
        let candidates = normalizedTurnURIs(uris)
        let effective = candidates.isEmpty ? normalizedTurnURIs(fallback) : candidates
        return effective
            .enumerated()
            .sorted { lhs, rhs in
                let lp = turnPriority(lhs.element)
                let rp = turnPriority(rhs.element)
                if lp == rp { return lhs.offset < rhs.offset }
                return lp < rp
            }
            .map(\.element)
    }
}

@available(iOS 17.0, *)
private enum CurrentPathSecurityCompat {
    static let allowedDeviceIdScalars = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:-")

    static func normalizeDeviceId(_ raw: String) throws -> String {
        let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (16...128).contains(candidate.count) else {
            throw NSError(domain: "CurrentPathSecurityCompat", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid deviceId length"])
        }
        guard candidate.unicodeScalars.allSatisfy({ scalar in
            scalar.isASCII && allowedDeviceIdScalars.contains(scalar)
        }) else {
            throw NSError(domain: "CurrentPathSecurityCompat", code: 2, userInfo: [NSLocalizedDescriptionKey: "invalid deviceId characters"])
        }
        return candidate
    }

    static func canonicalOrigin(_ raw: String) throws -> String {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              (scheme == "https" || scheme == "http")
        else {
            throw NSError(domain: "CurrentPathSecurityCompat", code: 3, userInfo: [NSLocalizedDescriptionKey: "invalid signaling origin"])
        }
        guard url.path.isEmpty || url.path == "/" else {
            throw NSError(domain: "CurrentPathSecurityCompat", code: 4, userInfo: [NSLocalizedDescriptionKey: "invalid signaling origin"])
        }
        guard url.query == nil, url.fragment == nil else {
            throw NSError(domain: "CurrentPathSecurityCompat", code: 5, userInfo: [NSLocalizedDescriptionKey: "invalid signaling origin"])
        }
        let port = url.port
        switch (scheme, port) {
        case ("https", nil), ("https", 443), ("http", nil), ("http", 80):
            return "\(scheme)://\(host)"
        default:
            guard let port else {
                return "\(scheme)://\(host)"
            }
            return "\(scheme)://\(host):\(port)"
        }
    }

    static func validateKeyEncoding(bytes: Data, algorithm: ProtocolSigningAlgorithm) throws {
        switch algorithm {
        case .ed25519:
            guard bytes.count == 32 else {
                throw NSError(domain: "CurrentPathSecurityCompat", code: 6, userInfo: [NSLocalizedDescriptionKey: "ed25519 public key must be 32 bytes"])
            }
        case .mlDSA65:
            guard !bytes.isEmpty else {
                throw NSError(domain: "CurrentPathSecurityCompat", code: 7, userInfo: [NSLocalizedDescriptionKey: "mlDSA65 public key must not be empty"])
            }
        }
    }

    static func computeFingerprint(algorithm: ProtocolSigningAlgorithm, publicKeyBytes: Data) -> String {
        let tagBytes = Array(algorithm.rawValue.utf8)
        var data = Data()
        var tagLength = UInt16(tagBytes.count).littleEndian
        withUnsafeBytes(of: &tagLength) { data.append(contentsOf: $0) }
        data.append(contentsOf: tagBytes)
        var keyLength = UInt32(publicKeyBytes.count).littleEndian
        withUnsafeBytes(of: &keyLength) { data.append(contentsOf: $0) }
        data.append(publicKeyBytes)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

@available(iOS 17.0, *)
private struct ProtocolIdentityBindingCompat: Sendable, Equatable {
    let deviceId: String
    let protocolSigningAlgorithm: ProtocolSigningAlgorithm
    let protocolPublicKeyBytes: Data
    let protocolPublicKeyFingerprint: String

    init(
        deviceId: String,
        protocolSigningAlgorithm: ProtocolSigningAlgorithm,
        protocolPublicKeyBytes: Data,
        protocolPublicKeyFingerprint: String? = nil
    ) throws {
        self.deviceId = try CurrentPathSecurityCompat.normalizeDeviceId(deviceId)
        try CurrentPathSecurityCompat.validateKeyEncoding(bytes: protocolPublicKeyBytes, algorithm: protocolSigningAlgorithm)
        self.protocolSigningAlgorithm = protocolSigningAlgorithm
        self.protocolPublicKeyBytes = protocolPublicKeyBytes
        self.protocolPublicKeyFingerprint = (protocolPublicKeyFingerprint
            ?? CurrentPathSecurityCompat.computeFingerprint(
                algorithm: protocolSigningAlgorithm,
                publicKeyBytes: protocolPublicKeyBytes
            )
        ).lowercased()
    }
}

@available(iOS 17.0, *)
private struct CurrentPathRemoteAuthorityCompat: Sendable, Equatable {
    let deviceId: String
    let protocolSigningAlgorithm: ProtocolSigningAlgorithm
    let protocolPublicKeyFingerprint: String
    let protocolPublicKeyBytes: Data?
    let deviceName: String?
}

@available(iOS 17.0, *)
private struct CurrentPathHandshakeTrustProviderCompat: HandshakeTrustProvider, Sendable {
    let expectedRemoteAuthority: CurrentPathRemoteAuthorityCompat?
    let fallbackPeerIDs: [String]

    func trustedFingerprint(for deviceId: String) async -> String? {
        if let expectedRemoteAuthority,
           deviceId == expectedRemoteAuthority.deviceId || fallbackPeerIDs.contains(deviceId) {
            return expectedRemoteAuthority.protocolPublicKeyFingerprint
        }
        return nil
    }

    func trustedKEMPublicKeys(for deviceId: String) async -> [CryptoSuite: Data] {
        await KEMTrustStore.shared.kemPublicKeys(for: deviceId)
    }

    func trustedSecureEnclavePublicKey(for deviceId: String) async -> Data? {
        nil
    }
}

@available(iOS 17.0, macOS 14.0, *)
private actor SignalServerClientCompat {
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
        let expiresIn: TimeInterval
        let signalingServerOrigin: String
    }

    struct RedeemedSessionLease: Sendable, Equatable {
        let sessionID: String
        let sessionToken: String
        let turnAdmissionToken: String
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
        let expiresIn: TimeInterval
        let signalingServerOrigin: String
    }

    struct ConnectionCodeLookup: Sendable, Equatable {
        let sessionID: String
        let sessionToken: String
        let turnAdmissionToken: String
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
        let expiresIn: Int
        let signalingServerOrigin: String
    }

    private struct RedeemSessionRequestBody: Encodable {
        let sessionId: String
        let qrBootstrapToken: String
    }

    private struct RedeemSessionResponseBody: Decodable {
        let sessionId: String
        let sessionToken: String
        let turnAdmissionToken: String
        let expiresIn: Int
        let signalingServerOrigin: String
        let initiatorDeviceId: String
        let initiatorProtocolSigningAlgorithm: String
        let initiatorProtocolPublicKeyFingerprint: String
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
        let expiresIn: Int
        let signalingServerOrigin: String
    }

    private struct LookupCodeResponseBody: Decodable {
        let found: Bool
        let sessionId: String
        let sessionToken: String
        let turnAdmissionToken: String
        let expiresIn: Int
        let signalingServerOrigin: String
        let initiatorDeviceId: String
        let initiatorProtocolSigningAlgorithm: String
        let initiatorProtocolPublicKeyFingerprint: String
        let initiatorDeviceName: String?
    }

    private let urlSession: URLSession

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    func requestAdmissionChallenge(binding: ProtocolIdentityBindingCompat) async throws -> AdmissionChallenge {
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
        return SessionLease(
            sessionID: response.sessionId,
            sessionToken: response.sessionToken,
            qrBootstrapToken: response.qrBootstrapToken,
            turnAdmissionToken: response.turnAdmissionToken,
            expiresIn: TimeInterval(response.expiresIn),
            signalingServerOrigin: response.signalingServerOrigin
        )
    }

    func redeemSession(
        admissionToken: String,
        sessionId: String,
        qrBootstrapToken: String
    ) async throws -> RedeemedSessionLease {
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
        return RedeemedSessionLease(
            sessionID: response.sessionId,
            sessionToken: response.sessionToken,
            turnAdmissionToken: response.turnAdmissionToken,
            expiresIn: TimeInterval(response.expiresIn),
            signalingServerOrigin: response.signalingServerOrigin,
            initiatorDeviceId: response.initiatorDeviceId,
            initiatorProtocolSigningAlgorithm: ProtocolSigningAlgorithm(rawValue: response.initiatorProtocolSigningAlgorithm) ?? .ed25519,
            initiatorProtocolPublicKeyFingerprint: response.initiatorProtocolPublicKeyFingerprint
        )
    }

    func registerConnectionCode(
        admissionToken: String,
        deviceName: String,
        validDuration: TimeInterval
    ) async throws -> ConnectionCodeLease {
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
        return ConnectionCodeLease(
            code: response.code,
            sessionID: response.sessionId,
            sessionToken: response.sessionToken,
            turnAdmissionToken: response.turnAdmissionToken,
            expiresIn: TimeInterval(response.expiresIn),
            signalingServerOrigin: response.signalingServerOrigin
        )
    }

    func lookupConnectionCode(admissionToken: String, code: String) async throws -> ConnectionCodeLookup {
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
        return ConnectionCodeLookup(
            sessionID: response.sessionId,
            sessionToken: response.sessionToken,
            turnAdmissionToken: response.turnAdmissionToken,
            expiresIn: TimeInterval(response.expiresIn),
            signalingServerOrigin: response.signalingServerOrigin,
            initiatorDeviceId: response.initiatorDeviceId,
            initiatorProtocolSigningAlgorithm: ProtocolSigningAlgorithm(rawValue: response.initiatorProtocolSigningAlgorithm) ?? .ed25519,
            initiatorProtocolPublicKeyFingerprint: response.initiatorProtocolPublicKeyFingerprint,
            initiatorDeviceName: response.initiatorDeviceName
        )
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

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyString = String(data: data, encoding: .utf8) ?? ""
            throw ClientError.serverRejected(http.statusCode, bodyString)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
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
        if let session = KeychainManager.shared.loadAuthSession(),
           !session.userIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return session.userIdentifier
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
        return merged.accessToken
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

@available(iOS 17.0, *)
private actor CrossNetworkTURNCredentialService {
    static let shared = CrossNetworkTURNCredentialService()

    private let logger = Logger(subsystem: "com.skybridge.turn", category: "CrossNetwork-iOS")
    private var cachedByTokenKey: [String: TURNCredentials] = [:]
    private let minimumRefreshBuffer: TimeInterval = 10

    struct TURNCredentials: Sendable, Codable {
        let username: String
        let password: String
        let ttl: Int
        let uris: [String]
        let expiresAt: Date

        func isValid(buffer: TimeInterval) -> Bool {
            Date().addingTimeInterval(buffer) < expiresAt
        }
    }

    private struct ServerResponse: Codable {
        let username: String
        let password: String
        let ttl: Int
        let uris: [String]?
        let expiresAt: Int?
        let mode: String?
    }

    func getCredentials(turnAdmissionToken: String?) async -> TURNCredentials {
        let tokenKey = cacheKey(for: turnAdmissionToken)
        if let cached = cachedByTokenKey[tokenKey],
           cached.isValid(buffer: refreshBuffer(for: cached)) {
            return cached
        }
        do {
            let fresh = try await fetchFromServer(turnAdmissionToken: turnAdmissionToken)
            cachedByTokenKey[tokenKey] = fresh
            return fresh
        } catch {
            if let cached = cachedByTokenKey[tokenKey],
               cached.isValid(buffer: minimumRefreshBuffer) {
                logger.info("ℹ️ TURN credentials fetch failed; reusing cached credentials. err=\(error.localizedDescription, privacy: .public)")
                return cached
            }
            logger.warning("⚠️ TURN credentials fetch failed; falling back. err=\(error.localizedDescription, privacy: .public)")
            return fallback()
        }
    }

    private func cacheKey(for turnAdmissionToken: String?) -> String {
        let trimmed = turnAdmissionToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "__anonymous__" : trimmed
    }

    private func refreshBuffer(for credentials: TURNCredentials) -> TimeInterval {
        min(30, max(minimumRefreshBuffer, TimeInterval(credentials.ttl) * 0.15))
    }

    private func fetchFromServer(turnAdmissionToken: String?) async throws -> TURNCredentials {
        guard let url = URL(string: "\(CrossNetworkServerConfig.signalingServerURL)/api/turn/credentials") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(CrossNetworkServerConfig.clientAPIKey, forHTTPHeaderField: "X-API-Key")
        if let turnAdmissionToken = turnAdmissionToken?.trimmingCharacters(in: .whitespacesAndNewlines),
           !turnAdmissionToken.isEmpty {
            req.setValue(turnAdmissionToken, forHTTPHeaderField: "X-SkyBridge-Turn-Admission")
        }
        if let deviceId = resolvedDeviceIdentifier() {
            req.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
        }
        req.timeoutInterval = 10

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let instance = http.value(forHTTPHeaderField: "X-SkyBridge-Instance") ?? "unknown"
        let backend = http.value(forHTTPHeaderField: "X-SkyBridge-State-Backend") ?? "unknown"
        let prefixes = http.value(forHTTPHeaderField: "X-SkyBridge-Code-Prefixes") ?? "-"
        logger.info("🌐 TURN credentials served by instance=\(instance, privacy: .public) backend=\(backend, privacy: .public) prefixes=\(prefixes, privacy: .public)")
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "TURN", code: http.statusCode, userInfo: ["body": body])
        }
        let decoded = try JSONDecoder().decode(ServerResponse.self, from: data)
        let ttl = max(60, decoded.ttl)
        let expiresAt: Date
        if let expiresAtEpoch = decoded.expiresAt, expiresAtEpoch > 0 {
            expiresAt = Date(timeIntervalSince1970: TimeInterval(expiresAtEpoch))
        } else {
            expiresAt = Date().addingTimeInterval(TimeInterval(ttl))
        }
        let uris = CrossNetworkServerConfig.preferredTurnURIs(
            from: decoded.uris ?? [],
            fallback: CrossNetworkServerConfig.turnURLs
        )
        return TURNCredentials(
            username: decoded.username,
            password: decoded.password,
            ttl: ttl,
            uris: uris,
            expiresAt: expiresAt
        )
    }

    private func fallback() -> TURNCredentials {
        // Safe fallback: do not embed secrets in the app.
        let username = (ProcessInfo.processInfo.environment["SKYBRIDGE_TURN_USERNAME"] ?? "skybridge")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let password = (ProcessInfo.processInfo.environment["SKYBRIDGE_TURN_PASSWORD"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !username.isEmpty, !password.isEmpty else {
            logger.warning("⚠️ TURN fallback credentials incomplete, will use STUN-only.")
            return TURNCredentials(
                username: "",
                password: "",
                ttl: 3600,
                uris: [],
                expiresAt: Date().addingTimeInterval(3600)
            )
        }

        return TURNCredentials(
            username: username,
            password: password,
            ttl: 3600,
            uris: CrossNetworkServerConfig.turnURLs,
            expiresAt: Date().addingTimeInterval(3600)
        )
    }

    private func resolvedDeviceIdentifier() -> String? {
        let envID = ProcessInfo.processInfo.environment["SKYBRIDGE_DEVICE_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !envID.isEmpty {
            return envID
        }
        let keychainID = KeychainManager.shared.getOrGenerateDeviceId()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return keychainID.isEmpty ? nil : keychainID
    }
}

private enum SignalingSessionHealth: String, Sendable, Equatable {
    case healthy
    case degradedRecoverable = "degraded_recoverable"
    case degradedFatal = "degraded_fatal"
}

#if canImport(WebRTC)
private final class RemoteVideoTrackHeartbeatRenderer: NSObject, RTCVideoRenderer {
    var onFrame: (@Sendable (CGSize) -> Void)?
    private var lastKnownSize: CGSize = .zero

    func setSize(_ size: CGSize) {
        lastKnownSize = size
    }

    func renderFrame(_ frame: RTCVideoFrame?) {
        let measuredSize: CGSize
        if let frame {
            measuredSize = CGSize(width: CGFloat(frame.width), height: CGFloat(frame.height))
        } else {
            measuredSize = lastKnownSize
        }
        guard measuredSize.width > 0, measuredSize.height > 0 else { return }
        let handler = onFrame
        DispatchQueue.main.async {
            handler?(measuredSize)
        }
    }
}
#endif

@available(iOS 17.0, *)
extension CrossNetworkWebRTCManager {
    public enum ConnectionCodeLeaseMode: String, CaseIterable, Sendable {
        case shortLived
        case dayStable

        var validDuration: TimeInterval {
            switch self {
            case .shortLived:
                return 10 * 60
            case .dayStable:
                return 24 * 60 * 60
            }
        }
    }

    public struct IdleConnectionPrompt: Identifiable, Equatable, Sendable {
        public let id = UUID()
        public let sessionId: String
        public let deviceName: String
    }
}

/// iOS 跨网连接管理器（WebRTC DataChannel + ICE + WebSocket signaling）
///
/// 目标：让 iPhone 在 P2P/Bonjour 不可用时，仍可通过扫码（skybridge://connect/…）完成跨网连接。
@available(iOS 17.0, *)
@MainActor
public final class CrossNetworkWebRTCManager: ObservableObject {
    
    public enum State: Sendable, Equatable {
        case idle
        case connecting(sessionId: String)
        case connected(sessionId: String)
        case failed(String)
    }

    public enum Readiness: Sendable, Equatable {
        case idle
        case transportReady(sessionId: String)
        case handshakeComplete(sessionId: String, negotiatedSuite: String)
    }
    
    @Published public private(set) var state: State = .idle
    @Published public private(set) var readiness: Readiness = .idle
    @Published public private(set) var lastError: String?
    @Published public private(set) var lastScreenData: ScreenData?
    @Published public private(set) var lastRekeyEvent: String?
    @Published public private(set) var remoteDeviceName: String?
    @Published public private(set) var remoteDeviceId: String?
#if canImport(WebRTC)
    @Published public private(set) var remoteVideoTrack: RTCVideoTrack?
    @Published public private(set) var remoteVideoTrackHasRenderedFrame = false
    @Published public private(set) var remoteVideoTrackFrameSize: CGSize = .zero
#endif
    @Published public private(set) var localConnectionCode: String?
    @Published public private(set) var localConnectionCodeExpiresAt: Date?
    @Published public var connectionCodeLeaseMode: ConnectionCodeLeaseMode = .shortLived {
        didSet {
            UserDefaults.standard.set(connectionCodeLeaseMode.rawValue, forKey: Self.connectionCodeLeaseModeDefaultsKey)
        }
    }
    @Published public private(set) var currentConnectLink: String?
    @Published public private(set) var activeSessionSnapshot: ActiveSessionSnapshot?
    @Published public private(set) var idleConnectionPrompt: IdleConnectionPrompt?
    private static let shortCodeAlphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    private static let shortCodeAllowedCharacters = Set(shortCodeAlphabet)
    public static let legacyConnectionCodeLength = 6
    public static let preferredConnectionCodeLength = 8
    public static let maximumConnectionCodeLength = 16
    private static let connectionCodeLeaseModeDefaultsKey = "cross_network_connection_code_lease_mode"
    private static let idleConnectionReminderDelay: TimeInterval = 180
    
    private var signaling: WebSocketSignalingClient?
    private var signalingShardKey: String?
    private let signalServer = SignalServerClientCompat()
    private let signalingRetryController = SignalingRetryController()
    private var signalingRecoveryTasksBySessionId: [String: Task<Void, Never>] = [:]
    private enum SignalingHealth {
        case healthy
        case degradedRecoverable
        case degradedFatal
    }
    private var signalingHealth: SignalingHealth = .healthy
    private var session: WebRTCSession?
    private var currentSessionId: String?
#if canImport(WebRTC)
    private var remoteVideoHeartbeatRenderer: RemoteVideoTrackHeartbeatRenderer?
#endif
    private let localDeviceId: String = {
        let envID = ProcessInfo.processInfo.environment["SKYBRIDGE_DEVICE_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !envID.isEmpty {
            return envID
        }
        return KeychainManager.shared.getOrGenerateDeviceId()
    }()
    private var currentPathExpectedRemoteAuthorityBySessionId: [String: CurrentPathRemoteAuthorityCompat] = [:]
    private var currentPathSignalingOriginBySessionId: [String: String] = [:]
    private var handshakeDriver: HandshakeDriver?
    private var handshakePeerId: String?
    private var sessionKeys: SessionKeys?
    private var inboundQueue: InboundChunkQueue?
    private var screenInboundQueue: InboundChunkQueue?
    private var receiveTask: Task<Void, Never>?
    private var screenReceiveTask: Task<Void, Never>?
    private var currentRole: WebRTCSession.Role?
    private var handshakeStartedSessionIds: Set<String> = []
    private var rekeyInProgressSessionIds: Set<String> = []
    private var rekeyCompletedSessionIds: Set<String> = []
    private var inboundRekeyResponderSessionIds: Set<String> = []
    private var strictPQCRequestedBySessionId: [String: Bool] = [:]
    private var lastPairingIdentityExchangeSentAtByPeerId: [String: Date] = [:]
    private var connectionCodeBootstrapTask: Task<Void, Never>?
    private var idleConnectionReminderTask: Task<Void, Never>?
    private var activeConnectionCodeLeaseMode: ConnectionCodeLeaseMode?
    private var localConnectionSessionId: String?
    private var activeSessionReconnectTimeoutTask: Task<Void, Never>?
    private var webrtcSignalingAuthTokenBySessionId: [String: String] = [:]
    private var webrtcTurnAdmissionTokenBySessionId: [String: String] = [:]
    private var latestLocalOfferBySessionId: [String: String] = [:]
    private var latestLocalAnswerBySessionId: [String: String] = [:]
    private var localICECandidatesBySessionId: [String: [WebRTCSignalingEnvelope.Payload]] = [:]
    private var joinHeartbeatTask: Task<Void, Never>?
    private var offerResendTask: Task<Void, Never>?
    private var remoteDesktopHeartbeatTask: Task<Void, Never>?
    private var remotePeerPingTask: Task<Void, Never>?
    private var remotePeerLivenessWatchdogTask: Task<Void, Never>?
    private var remoteAppActivityAtBySessionId: [String: Date] = [:]
    private var nextRemotePeerPingID: UInt64 = 1
    private var inFlightScannedConnectLink: String?
    
    // File transfer waiters (transferId|op|chunkIndex -> continuation)
    private var fileTransferWaiters: [String: CheckedContinuation<CrossNetworkFileTransferMessage, Error>] = [:]

    private struct SessionSnapshotMetadata: Sendable {
        let snapshotToken: UUID
        let source: ActiveSessionSnapshotSource
        let deviceId: String?
        let deviceName: String?
    }
    private var sessionSnapshotMetadataBySessionId: [String: SessionSnapshotMetadata] = [:]

    private struct InboundFileTransferState {
        let transferId: String
        let fileName: String
        let fileSize: Int64
        let chunkSize: Int
        let totalChunks: Int
        let senderDeviceId: String
        let senderDeviceName: String
        let tempURL: URL
        let finalURL: URL
        let handle: FileHandle
        var receivedBytes: Int64
        var completeRequestedAt: Date? = nil
        var expectedFileSha256: Data? = nil
        var expectedMerkleRoot: Data? = nil
        var expectedMerkleSig: Data? = nil
        var expectedMerkleSigAlg: String? = nil
        var chunkHashes: [Int: Data] = [:]
        var receivedChunkSizes: [Int: Int] = [:]
    }
    private var inboundFileTransfers: [String: InboundFileTransferState] = [:]
    private var inboundFileTransferCompleteTimers: [String: Task<Void, Never>] = [:]
    
    private enum FileTransferWaitError: LocalizedError {
        case timeout
        case cancelled
        
        var errorDescription: String? {
            switch self {
            case .timeout: return "跨网文件传输等待超时"
            case .cancelled: return "跨网文件传输已取消"
            }
        }
    }
    
    public static let instance = CrossNetworkWebRTCManager()
    private init() {
        if let rawMode = UserDefaults.standard.string(forKey: Self.connectionCodeLeaseModeDefaultsKey),
           let mode = ConnectionCodeLeaseMode(rawValue: rawMode) {
            connectionCodeLeaseMode = mode
        }
    }

    public var isTransportReady: Bool {
        switch readiness {
        case .transportReady, .handshakeComplete:
            return true
        case .idle:
            return false
        }
    }

    public var isHandshakeComplete: Bool {
        if case .handshakeComplete = readiness { return true }
        return false
    }

    @discardableResult
    private func prepareSessionSnapshotMetadata(
        sessionId: String,
        source: ActiveSessionSnapshotSource,
        deviceId: String?,
        deviceName: String?
    ) -> SessionSnapshotMetadata {
        let metadata = SessionSnapshotMetadata(
            snapshotToken: UUID(),
            source: source,
            deviceId: deviceId,
            deviceName: deviceName
        )
        sessionSnapshotMetadataBySessionId[sessionId] = metadata
        return metadata
    }

    @discardableResult
    private func activatePreparedSessionSnapshot(
        sessionId: String,
        phase: ActiveSessionSnapshotPhase,
        negotiatedSuite: String? = nil
    ) -> UUID? {
        guard let metadata = sessionSnapshotMetadataBySessionId[sessionId] else { return nil }
        activeSessionReconnectTimeoutTask?.cancel()
        activeSessionSnapshot = ActiveSessionSnapshotContract.activate(
            sessionId: sessionId,
            source: metadata.source,
            phase: phase,
            deviceId: metadata.deviceId,
            deviceName: metadata.deviceName,
            negotiatedSuite: negotiatedSuite,
            snapshotToken: metadata.snapshotToken
        )
        return metadata.snapshotToken
    }

    private func updatePreparedSessionSnapshot(
        sessionId: String,
        phase: ActiveSessionSnapshotPhase,
        deviceId: String? = nil,
        deviceName: String? = nil,
        negotiatedSuite: String? = nil,
        snapshotToken: UUID? = nil
    ) {
        let token = snapshotToken ?? sessionSnapshotMetadataBySessionId[sessionId]?.snapshotToken
        guard let token else { return }
        activeSessionReconnectTimeoutTask?.cancel()
        activeSessionSnapshot = ActiveSessionSnapshotContract.update(
            current: activeSessionSnapshot,
            sessionId: sessionId,
            snapshotToken: token,
            phase: phase,
            deviceId: deviceId,
            deviceName: deviceName,
            negotiatedSuite: negotiatedSuite
        )
    }

    private func applyActiveSessionDisconnect(
        sessionId: String,
        kind: SessionDisconnectKind,
        snapshotToken: UUID? = nil
    ) {
        let token = snapshotToken ?? sessionSnapshotMetadataBySessionId[sessionId]?.snapshotToken
        guard let token else { return }

        let nextSnapshot = ActiveSessionSnapshotContract.disconnect(
            current: activeSessionSnapshot,
            sessionId: sessionId,
            snapshotToken: token,
            kind: kind
        )
        activeSessionSnapshot = nextSnapshot

        switch kind {
        case .transient:
            if let nextSnapshot {
                scheduleActiveSessionReconnectTimeout(for: nextSnapshot)
            }
        case .explicit, .remoteLeave:
            activeSessionReconnectTimeoutTask?.cancel()
            sessionSnapshotMetadataBySessionId.removeValue(forKey: sessionId)
        }
    }

    private func scheduleActiveSessionReconnectTimeout(for snapshot: ActiveSessionSnapshot) {
        activeSessionReconnectTimeoutTask?.cancel()
        activeSessionReconnectTimeoutTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(5))
            guard let current = self.activeSessionSnapshot,
                  current.snapshotToken == snapshot.snapshotToken,
                  current.phase == .reconnecting else {
                return
            }
            self.activeSessionSnapshot = nil
            self.sessionSnapshotMetadataBySessionId.removeValue(forKey: snapshot.sessionId)
        }
    }

    private func noteRemoteAppActivity(sessionId: String) {
        remoteAppActivityAtBySessionId[sessionId] = Date()
    }

    private func startRemotePeerPingLoop(sessionId: String, session: WebRTCSession) {
        remotePeerPingTask?.cancel()
        remotePeerPingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard self.currentSessionId == sessionId,
                      self.session === session else { break }
                guard case .connected(let activeSessionId) = self.state, activeSessionId == sessionId else {
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }
                guard self.sessionKeys != nil else {
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }
                if self.rekeyInProgressSessionIds.contains(sessionId) {
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }

                let pingId = self.nextRemotePeerPingID
                self.nextRemotePeerPingID &+= 1

                do {
                    try await self.sendAppMessageOverWebRTC(
                        .ping(.init(id: pingId)),
                        sessionId: sessionId,
                        session: session,
                        label: "tx/webrtc-ping"
                    )
                } catch {
                    SkyBridgeLogger.shared.debug("ℹ️ WebRTC ping send failed: \(error.localizedDescription)")
                    break
                }

                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func startRemotePeerLivenessWatchdog(sessionId: String, session: WebRTCSession) {
        remotePeerLivenessWatchdogTask?.cancel()
        remotePeerLivenessWatchdogTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let timeoutSeconds: TimeInterval = 12.0
            while !Task.isCancelled {
                guard self.currentSessionId == sessionId,
                      self.session === session else { break }
                guard case .connected(let activeSessionId) = self.state, activeSessionId == sessionId else {
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }

                let lastActivityAt = self.remoteAppActivityAtBySessionId[sessionId] ?? .distantPast
                if Date().timeIntervalSince(lastActivityAt) > timeoutSeconds {
                    let msg = "远端连接已失活"
                    SkyBridgeLogger.shared.warning("⚠️ WebRTC remote peer timeout: session=\(sessionId)")
                    self.lastError = msg
                    self.applyActiveSessionDisconnect(sessionId: sessionId, kind: .transient)
                    await self.disconnect(clearSnapshot: false)
                    self.lastError = msg
                    self.state = .failed(msg)
                    self.readiness = .idle
                    break
                }

                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func currentPathLocalBinding() throws -> ProtocolIdentityBindingCompat {
        let tag = "CrossNetwork.CurrentPath.Authority.Ed25519"
        let keychain = KeychainManager.shared
        let publicKey: Data
        if let existing = keychain.loadCurve25519SigningPublicKey(tag: tag) {
            publicKey = existing.rawRepresentation
        } else if let generated = keychain.generateCurve25519SigningKeypair(tag: tag) {
            publicKey = generated.public.rawRepresentation
        } else {
            throw NSError(domain: "CrossNetworkWebRTCManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "failed to create current-path protocol signing key"])
        }
        return try ProtocolIdentityBindingCompat(
            deviceId: localDeviceId,
            protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyBytes: publicKey
        )
    }

    private func enforceCurrentPathTrustBinding(
        deviceId: String,
        protocolPublicKeyFingerprint: String
    ) throws {
        if let conflict = TrustedDeviceStore.shared.evaluateCurrentPathBinding(
            deviceId: deviceId,
            protocolPublicKeyFingerprint: protocolPublicKeyFingerprint
        ) {
            switch conflict {
            case .identityConflict:
                throw NSError(domain: "CrossNetworkWebRTCManager", code: 21, userInfo: [NSLocalizedDescriptionKey: "二维码 authoritative key 与现有 deviceId 绑定冲突"])
            case .deviceIdMigrationRequired:
                throw NSError(domain: "CrossNetworkWebRTCManager", code: 22, userInfo: [NSLocalizedDescriptionKey: "二维码 deviceId 与已 pinned authoritative key 不匹配"])
            case .quarantinedIdentity:
                throw NSError(domain: "CrossNetworkWebRTCManager", code: 23, userInfo: [NSLocalizedDescriptionKey: "二维码身份处于隔离/待重新验证状态"])
            case .revokedIdentity:
                throw NSError(domain: "CrossNetworkWebRTCManager", code: 24, userInfo: [NSLocalizedDescriptionKey: "二维码身份已撤销"])
            }
        }
    }

    private func persistCurrentPathTrust(sessionId: String) {
        guard let authority = currentPathExpectedRemoteAuthorityBySessionId[sessionId] else { return }
        TrustedDeviceStore.shared.upsertCurrentPathAuthority(
            deviceId: authority.deviceId,
            name: authority.deviceName ?? authority.deviceId,
            protocolSigningAlgorithm: authority.protocolSigningAlgorithm.rawValue,
            protocolPublicKeyFingerprint: authority.protocolPublicKeyFingerprint
        )
    }

    private func validateCurrentPathOrigin(_ rawOrigin: String) throws -> String {
        let configured = try CurrentPathSecurityCompat.canonicalOrigin(CrossNetworkServerConfig.signalingServerURL)
        let claimed = try CurrentPathSecurityCompat.canonicalOrigin(rawOrigin)
        guard configured == claimed else {
            throw NSError(domain: "CrossNetworkWebRTCManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "signaling origin mismatch"])
        }
        return claimed
    }

    private func requestAdmissionLease(for binding: ProtocolIdentityBindingCompat) async throws -> SignalServerClientCompat.AdmissionLease {
        let challenge = try await signalServer.requestAdmissionChallenge(binding: binding)
        let signatureKeyTag = "CrossNetwork.CurrentPath.Authority.Ed25519"
        guard let privateKey = KeychainManager.shared.loadCurve25519SigningPrivateKey(tag: signatureKeyTag) else {
            throw NSError(domain: "CrossNetworkWebRTCManager", code: 14, userInfo: [NSLocalizedDescriptionKey: "missing current-path signing key"])
        }
        let signature = try privateKey.signature(for: challenge.signaturePayload())
        return try await signalServer.completeAdmission(challenge: challenge, binding: binding, signature: signature)
    }
    
    public func connect(fromScannedString string: String) async {
        disarmIdleConnectionReminder(clearPrompt: true)
        let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            lastError = ConnectLinkError.invalidFormat.localizedDescription
            state = .failed(lastError ?? "二维码格式无效")
            readiness = .idle
            return
        }
        if inFlightScannedConnectLink == normalized {
            SkyBridgeLogger.shared.info("ℹ️ 忽略重复扫码连接请求（同一二维码仍在处理中）")
            return
        }
        inFlightScannedConnectLink = normalized
        defer {
            if inFlightScannedConnectLink == normalized {
                inFlightScannedConnectLink = nil
            }
        }
        do {
            let payload = try await parseSkybridgeConnectLink(normalized)
            try await connect(from: payload)
        } catch {
            let msg = error.localizedDescription
            lastError = msg
            state = .failed(msg)
            readiness = .idle
        }
    }
    
    /// 通过智能连接码连接（与 macOS 侧共享同一字母表与长度语义）
    /// - Note: 当前实现直接把 code 当作 WebRTC sessionId（同 signaling room）。
    public func connect(withCode rawCode: String) async {
        disarmIdleConnectionReminder(clearPrompt: true)
        do {
            let code = try normalizeConnectionCode(rawCode)
            let localBinding = try currentPathLocalBinding()
            let admission = try await requestAdmissionLease(for: localBinding)
            let lookup = try await signalServer.lookupConnectionCode(admissionToken: admission.token, code: code)
            _ = try validateCurrentPathOrigin(lookup.signalingServerOrigin)
            try enforceCurrentPathTrustBinding(
                deviceId: lookup.initiatorDeviceId,
                protocolPublicKeyFingerprint: lookup.initiatorProtocolPublicKeyFingerprint
            )
            webrtcSignalingAuthTokenBySessionId[lookup.sessionID] = lookup.sessionToken
            webrtcTurnAdmissionTokenBySessionId[lookup.sessionID] = lookup.turnAdmissionToken
            currentPathSignalingOriginBySessionId[lookup.sessionID] = lookup.signalingServerOrigin
            currentPathExpectedRemoteAuthorityBySessionId[lookup.sessionID] = CurrentPathRemoteAuthorityCompat(
                deviceId: lookup.initiatorDeviceId,
                protocolSigningAlgorithm: lookup.initiatorProtocolSigningAlgorithm,
                protocolPublicKeyFingerprint: lookup.initiatorProtocolPublicKeyFingerprint,
                protocolPublicKeyBytes: nil,
                deviceName: lookup.initiatorDeviceName
            )
            try await connect(
                sessionId: lookup.sessionID,
                remoteName: lookup.initiatorDeviceName,
                remotePeerDeviceId: lookup.initiatorDeviceId,
                source: .code,
                role: .answerer
            )
        } catch {
            let msg = error.localizedDescription
            lastError = msg
            state = .failed(msg)
            readiness = .idle
        }
    }

    /// 生成本机连接码并等待对端（例如 macOS）输入连接。
    /// - Returns: 服务端签发的短期连接码；失败时返回 `nil` 且更新 `state/.failed`。
    @discardableResult
    public func generateConnectionCode() async -> String? {
        disarmIdleConnectionReminder(clearPrompt: true)
        let requestedLeaseMode = connectionCodeLeaseMode

        if let existing = localConnectionCode,
           activeConnectionCodeLeaseMode == requestedLeaseMode,
           currentRole == .offerer,
           case .connecting(let sid) = state, sid == (localConnectionSessionId ?? existing) {
            return existing
        }
        if let existing = localConnectionCode,
           activeConnectionCodeLeaseMode == requestedLeaseMode,
           currentRole == .offerer,
           case .connected(let sid) = state, sid == (localConnectionSessionId ?? existing) {
            return existing
        }
        do {
            if localConnectionCode != nil,
               currentRole == .offerer,
               activeConnectionCodeLeaseMode != requestedLeaseMode {
                await disconnect()
            }
            let localBinding = try currentPathLocalBinding()
            let admission = try await requestAdmissionLease(for: localBinding)
            #if canImport(UIKit)
            let localDeviceName = UIDevice.current.name
            #else
            let localDeviceName = Host.current().localizedName ?? "Apple Device"
            #endif
            let lease = try await signalServer.registerConnectionCode(
                admissionToken: admission.token,
                deviceName: localDeviceName,
                validDuration: requestedLeaseMode.validDuration
            )
            webrtcSignalingAuthTokenBySessionId[lease.sessionID] = lease.sessionToken
            webrtcTurnAdmissionTokenBySessionId[lease.sessionID] = lease.turnAdmissionToken
            currentPathSignalingOriginBySessionId[lease.sessionID] = lease.signalingServerOrigin
            localConnectionCode = lease.code
            localConnectionCodeExpiresAt = Date().addingTimeInterval(lease.expiresIn)
            activeConnectionCodeLeaseMode = requestedLeaseMode
            localConnectionSessionId = lease.sessionID
            currentRole = .offerer
            state = .connecting(sessionId: lease.sessionID)
            readiness = .idle
            lastError = nil

            connectionCodeBootstrapTask?.cancel()
            connectionCodeBootstrapTask = Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.localConnectionCode == lease.code,
                      self.localConnectionSessionId == lease.sessionID,
                      self.currentRole == .offerer else { return }
                do {
                    try await self.connect(
                        sessionId: lease.sessionID,
                        remoteName: nil,
                        remotePeerDeviceId: nil,
                        source: .code,
                        role: .offerer
                    )
                    self.localConnectionCode = lease.code
                    self.localConnectionSessionId = lease.sessionID
                } catch is CancellationError {
                    // Cancellation is expected during regenerate/disconnect.
                } catch {
                    guard self.localConnectionCode == lease.code else { return }
                    let msg = error.localizedDescription
                    self.lastError = msg
                    self.state = .failed(msg)
                    self.readiness = .idle
                }
                if self.connectionCodeBootstrapTask?.isCancelled == false {
                    self.connectionCodeBootstrapTask = nil
                }
            }

            return lease.code
        } catch {
            let msg = error.localizedDescription
            lastError = msg
            state = .failed(msg)
            readiness = .idle
            return nil
        }
    }

    @discardableResult
    public func generateConnectLink(validDuration: TimeInterval = 300) async -> String? {
        disarmIdleConnectionReminder(clearPrompt: true)
        do {
            let localBinding = try currentPathLocalBinding()
            let admission = try await requestAdmissionLease(for: localBinding)
            #if canImport(UIKit)
            let localDeviceName = UIDevice.current.name
            #else
            let localDeviceName = Host.current().localizedName ?? "Apple Device"
            #endif
            let lease = try await signalServer.registerSession(
                admissionToken: admission.token,
                validDuration: validDuration
            )
            _ = try validateCurrentPathOrigin(lease.signalingServerOrigin)
            webrtcSignalingAuthTokenBySessionId[lease.sessionID] = lease.sessionToken
            webrtcTurnAdmissionTokenBySessionId[lease.sessionID] = lease.turnAdmissionToken
            currentPathSignalingOriginBySessionId[lease.sessionID] = lease.signalingServerOrigin

            let signatureKeyTag = "CrossNetwork.CurrentPath.Authority.Ed25519"
            guard let privateKey = KeychainManager.shared.loadCurve25519SigningPrivateKey(tag: signatureKeyTag) else {
                throw NSError(domain: "CrossNetworkWebRTCManager", code: 13, userInfo: [NSLocalizedDescriptionKey: "missing current-path signing key"])
            }

            let qrData = DynamicQRCodeData(
                version: 6,
                sessionID: lease.sessionID,
                qrBootstrapToken: lease.qrBootstrapToken,
                signalingServerOrigin: lease.signalingServerOrigin,
                deviceID: localBinding.deviceId,
                deviceName: localDeviceName,
                deviceType: P2PDeviceType.iOS.rawValue,
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                capabilities: ["cross-network", "p2p"],
                protocolSigningAlgorithm: localBinding.protocolSigningAlgorithm,
                protocolPublicKeyBytes: localBinding.protocolPublicKeyBytes,
                protocolPublicKeyFingerprint: localBinding.protocolPublicKeyFingerprint,
                signature: nil,
                signatureTimestampMs: Int64(Date().timeIntervalSince1970 * 1000),
                expiresAt: Date().addingTimeInterval(validDuration)
            )
            let signature = try privateKey.signature(for: buildCanonicalQRCodePayload(for: qrData))
            let signed = DynamicQRCodeData(
                version: qrData.version,
                sessionID: qrData.sessionID,
                qrBootstrapToken: qrData.qrBootstrapToken,
                signalingServerOrigin: qrData.canonicalSignalingServerOrigin,
                deviceID: qrData.deviceID,
                deviceName: qrData.deviceName,
                deviceType: qrData.deviceType,
                osVersion: qrData.osVersion,
                capabilities: qrData.normalizedCapabilities,
                protocolSigningAlgorithm: qrData.protocolSigningAlgorithm,
                protocolPublicKeyBytes: qrData.protocolPublicKeyBytes,
                protocolPublicKeyFingerprint: qrData.protocolPublicKeyFingerprint,
                signature: signature,
                signatureTimestampMs: qrData.signatureTimestampMs,
                expiresAt: qrData.expiresAt
            )
            let jsonData = try JSONEncoder().encode(signed)
            let payload = jsonData.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            let link = "skybridge://connect/\(payload)"

            currentConnectLink = link
            currentRole = .offerer
            state = .connecting(sessionId: lease.sessionID)
            readiness = .idle
            lastError = nil

            connectionCodeBootstrapTask?.cancel()
            connectionCodeBootstrapTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.connect(
                        sessionId: lease.sessionID,
                        remoteName: nil,
                        remotePeerDeviceId: nil,
                        source: .code,
                        role: .offerer
                    )
                } catch is CancellationError {
                } catch {
                    self.lastError = error.localizedDescription
                    self.state = .failed(error.localizedDescription)
                    self.readiness = .idle
                }
            }

            return link
        } catch {
            lastError = error.localizedDescription
            state = .failed(error.localizedDescription)
            readiness = .idle
            return nil
        }
    }
    
    public func disconnect(clearSnapshot: Bool = true) async {
        disarmIdleConnectionReminder(clearPrompt: true)
        for (_, task) in signalingRecoveryTasksBySessionId {
            task.cancel()
        }
        signalingRecoveryTasksBySessionId.removeAll()
        if let signaling {
            await signaling.close()
        }
        signaling = nil
        signalingShardKey = nil
        signalingHealth = .healthy
        session?.close()
        session = nil
        currentSessionId = nil
#if canImport(WebRTC)
        installRemoteVideoTrack(nil)
#endif
        handshakeDriver = nil
        handshakePeerId = nil
        sessionKeys = nil
        remoteDeviceName = nil
        remoteDeviceId = nil
        localConnectionCode = nil
        localConnectionCodeExpiresAt = nil
        activeConnectionCodeLeaseMode = nil
        currentConnectLink = nil
        localConnectionSessionId = nil
        currentRole = nil
        connectionCodeBootstrapTask?.cancel()
        connectionCodeBootstrapTask = nil
        joinHeartbeatTask?.cancel()
        joinHeartbeatTask = nil
        offerResendTask?.cancel()
        offerResendTask = nil
        remoteDesktopHeartbeatTask?.cancel()
        remoteDesktopHeartbeatTask = nil
        remotePeerPingTask?.cancel()
        remotePeerPingTask = nil
        remotePeerLivenessWatchdogTask?.cancel()
        remotePeerLivenessWatchdogTask = nil
        latestLocalOfferBySessionId.removeAll()
        latestLocalAnswerBySessionId.removeAll()
        localICECandidatesBySessionId.removeAll()
        webrtcSignalingAuthTokenBySessionId.removeAll()
        webrtcTurnAdmissionTokenBySessionId.removeAll()
        currentPathExpectedRemoteAuthorityBySessionId.removeAll()
        currentPathSignalingOriginBySessionId.removeAll()
        remoteAppActivityAtBySessionId.removeAll()
        handshakeStartedSessionIds.removeAll()
        rekeyInProgressSessionIds.removeAll()
        rekeyCompletedSessionIds.removeAll()
        inboundRekeyResponderSessionIds.removeAll()
        strictPQCRequestedBySessionId.removeAll()
        lastPairingIdentityExchangeSentAtByPeerId.removeAll()
        failAllFileTransferWaiters(FileTransferWaitError.cancelled)
        cleanupInboundFileTransfers()
        if let inboundQueue {
            await inboundQueue.finish()
        }
        inboundQueue = nil
        if let screenInboundQueue {
            await screenInboundQueue.finish()
        }
        screenInboundQueue = nil
        receiveTask?.cancel()
        receiveTask = nil
        screenReceiveTask?.cancel()
        screenReceiveTask = nil
        if clearSnapshot {
            activeSessionReconnectTimeoutTask?.cancel()
            activeSessionReconnectTimeoutTask = nil
            activeSessionSnapshot = nil
            sessionSnapshotMetadataBySessionId.removeAll()
        }
        state = .idle
        readiness = .idle
    }

#if canImport(WebRTC)
    private func installRemoteVideoTrack(_ track: RTCVideoTrack?) {
        if let currentTrack = remoteVideoTrack,
           let heartbeatRenderer = remoteVideoHeartbeatRenderer {
            currentTrack.remove(heartbeatRenderer)
        }

        remoteVideoTrack = track
        remoteVideoTrackHasRenderedFrame = false
        remoteVideoTrackFrameSize = .zero
        remoteVideoHeartbeatRenderer = nil

        guard let track else { return }

        let heartbeatRenderer = RemoteVideoTrackHeartbeatRenderer()
        heartbeatRenderer.onFrame = { [weak self] size in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard size.width > 0, size.height > 0 else { return }
                self.remoteVideoTrackFrameSize = size
                if !self.remoteVideoTrackHasRenderedFrame {
                    self.remoteVideoTrackHasRenderedFrame = true
                    SkyBridgeLogger.shared.info(
                        "🎬 WebRTC 原生视频轨已收到首帧: \(Int(size.width))x\(Int(size.height))"
                    )
                }
            }
        }
        remoteVideoHeartbeatRenderer = heartbeatRenderer
        track.add(heartbeatRenderer)
    }
#endif

    public func dismissIdleConnectionPrompt() {
        idleConnectionPrompt = nil
    }

    public func disarmIdleConnectionReminder(clearPrompt: Bool = true) {
        idleConnectionReminderTask?.cancel()
        idleConnectionReminderTask = nil
        if clearPrompt {
            idleConnectionPrompt = nil
        }
    }

    public func armIdleConnectionReminderIfNeeded(after delay: TimeInterval = 180) {
        disarmIdleConnectionReminder(clearPrompt: true)

        guard let sessionId = currentSessionId else { return }
        guard isTransportReady || isHandshakeComplete || activeSessionSnapshot != nil else { return }

        let trimmedDeviceName = remoteDeviceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let deviceName = trimmedDeviceName.isEmpty
            ? RuntimeLocalization.string("idleConnection.notification.defaultDevice")
            : trimmedDeviceName

        idleConnectionReminderTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }

            guard self.currentSessionId == sessionId else { return }
            guard self.isTransportReady || self.isHandshakeComplete || self.activeSessionSnapshot != nil else { return }

            if UIApplication.shared.applicationState == .active {
                self.idleConnectionPrompt = IdleConnectionPrompt(
                    sessionId: sessionId,
                    deviceName: deviceName
                )
            } else {
                let content = UNMutableNotificationContent()
                content.title = RuntimeLocalization.string("idleConnection.notification.title")
                content.body = String(
                    format: RuntimeLocalization.string("idleConnection.notification.body"),
                    deviceName
                )
                content.sound = .default
                content.categoryIdentifier = "IDLE_CONNECTION"
                content.userInfo = [
                    "kind": "IDLE_CONNECTION",
                    "sessionId": sessionId,
                    "deviceName": deviceName
                ]
                let request = UNNotificationRequest(
                    identifier: "idle-connection-\(sessionId)",
                    content: content,
                    trigger: nil
                )
                do {
                    try await UNUserNotificationCenter.current().add(request)
                } catch {
                    SkyBridgeLogger.shared.warning(
                        "⚠️ 发送闲置连接提醒失败: \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    private func signalingURL(shardKey: String? = nil) throws -> URL {
        guard let wsURL = SignalingRetryController.validatedWebSocketURL(
            CrossNetworkServerConfig.signalingWebSocketURL
        ) else {
            throw SignalingRetryControllerError.invalidWebSocketURL(
                CrossNetworkServerConfig.signalingWebSocketURL
            )
        }
        guard let shardKey = shardKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !shardKey.isEmpty else {
            return wsURL
        }
        guard var components = URLComponents(url: wsURL, resolvingAgainstBaseURL: false) else {
            return wsURL
        }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == "shard" }
        queryItems.removeAll { $0.name == "st" }
        queryItems.removeAll { $0.name == "cv" }
        queryItems.removeAll { $0.name == "pv" }
        queryItems.append(URLQueryItem(name: "shard", value: shardKey))
        if let token = webrtcSignalingAuthTokenBySessionId[shardKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty {
            queryItems.append(URLQueryItem(name: "st", value: token))
        }
        if let envVersion = ProcessInfo.processInfo.environment["SKYBRIDGE_CLIENT_VERSION"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !envVersion.isEmpty {
            queryItems.append(URLQueryItem(name: "cv", value: envVersion))
        } else if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                queryItems.append(URLQueryItem(name: "cv", value: trimmed))
            }
        }
        let protocolVersion = ProcessInfo.processInfo.environment["SKYBRIDGE_PROTOCOL_VERSION"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "1"
        queryItems.append(URLQueryItem(name: "pv", value: protocolVersion.isEmpty ? "1" : protocolVersion))
        components.queryItems = queryItems
        return components.url ?? wsURL
    }

    private func ensureSignalingConnected(shardKey: String? = nil) async throws {
        let effectiveShardKey = (shardKey ?? currentSessionId)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedShardKey = (effectiveShardKey?.isEmpty == false) ? effectiveShardKey : nil

        if let signaling, signalingShardKey != normalizedShardKey {
            appendSmokeTrace("signaling reset shard=\(signalingShardKey ?? "-")->\(normalizedShardKey ?? "-")")
            await signaling.close()
            self.signaling = nil
            signalingShardKey = nil
            signalingHealth = .healthy
        }

        if let signaling {
            try await signaling.connectOrThrow()
            return
        }

        guard let sessionId = normalizedShardKey else {
            throw WebSocketSignalingClient.SignalingError.notConnected
        }

        let wsURL = try signalingURL(shardKey: sessionId)
        let newSignaling = WebSocketSignalingClient(url: wsURL, sessionId: sessionId, generation: 0)
        signaling = newSignaling
        signalingShardKey = sessionId
        signalingHealth = .healthy

        await newSignaling.setOnTrace { [weak self] (line: String) in
            Task { @MainActor in
                guard let self, self.signaling === newSignaling else { return }
                self.appendSmokeTrace("ws \(line)")
            }
        }
        await newSignaling.setOnEnvelope { [weak self] (env: WebRTCSignalingEnvelope) in
            Task { @MainActor in
                guard let self, self.signaling === newSignaling else { return }
                self.handleEnvelope(env)
            }
        }
        await newSignaling.setOnServerFrame { [weak self] (frame: WebSocketSignalingClient.SignalingServerFrame) in
            Task { @MainActor in
                guard let self, self.signaling === newSignaling else { return }
                self.handleServerFrame(frame)
            }
        }
        await newSignaling.setOnLifecycleEvent { [weak self] (event: WebSocketSignalingClient.SignalingLifecycleEvent) in
            Task { @MainActor in
                guard let self, self.signaling === newSignaling else { return }
                let failureKind = event.failureClass.map { failure -> SignalingFailureKind in
                    switch failure {
                    case .authBindRejected:
                        return .authBindRejected
                    case .invalidShardOrSessionMismatch:
                        return .invalidShardOrSessionMismatch
                    case .tokenExpired:
                        return .tokenExpired
                    case .transientNetwork:
                        return .transientNetwork
                    case .transientServer:
                        return .transientServer
                    case .protocolViolation:
                        return .protocolViolation
                    }
                } ?? .transientServer

                switch event.phase {
                case .bound:
                    self.signalingHealth = .healthy
                case .closed:
                    if self.isTransportEstablished(for: sessionId) {
                        self.signalingHealth = .degradedRecoverable
                        self.scheduleSignalingRecovery(for: sessionId)
                    }
                case .failed:
                    if self.isTransportEstablished(for: sessionId) {
                        if failureKind == .tokenExpired {
                            self.signalingHealth = .degradedRecoverable
                            self.scheduleSignalingRecovery(for: sessionId, tokenExpired: true)
                        } else if self.isFatalPostTransportFailure(failureKind) {
                            self.signalingHealth = .degradedFatal
                        } else {
                            self.signalingHealth = .degradedRecoverable
                            self.scheduleSignalingRecovery(for: sessionId)
                        }
                    } else if self.isFatalPreTransportFailure(failureKind) {
                        self.signalingHealth = .degradedFatal
                    } else {
                        self.signalingHealth = .degradedRecoverable
                    }
                default:
                    break
                }
            }
        }
        appendSmokeTrace("signaling connect shard=\(sessionId) url=\(WebSocketSignalingClient.redactedURLString(wsURL))")
        try await newSignaling.connectOrThrow()
    }

    private func authenticatedEnvelope(_ envelope: WebRTCSignalingEnvelope) -> WebRTCSignalingEnvelope? {
        if envelope.authToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return envelope
        }
        guard let token = webrtcSignalingAuthTokenBySessionId[envelope.sessionId],
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastError = "缺少 signaling auth token"
            state = .failed("Missing signaling authorization")
            readiness = .idle
            return nil
        }
        return WebRTCSignalingEnvelope(
            sessionId: envelope.sessionId,
            from: envelope.from,
            to: envelope.to,
            type: envelope.type,
            payload: envelope.payload,
            authToken: token,
            sentAt: envelope.sentAt
        )
    }

    private func sendEnvelope(_ envelope: WebRTCSignalingEnvelope, retries: Int = 2) async {
        let directedEnvelope: WebRTCSignalingEnvelope = {
            guard envelope.to == nil,
                  let remoteId = remoteDeviceId?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !remoteId.isEmpty,
                  remoteId != envelope.from else {
                return envelope
            }
            return WebRTCSignalingEnvelope(
                sessionId: envelope.sessionId,
                from: envelope.from,
                to: remoteId,
                type: envelope.type,
                payload: envelope.payload,
                authToken: envelope.authToken,
                sentAt: envelope.sentAt
            )
        }()

        guard let authorizedEnvelope = authenticatedEnvelope(directedEnvelope) else { return }
        appendSmokeTrace("tx \(describeEnvelope(authorizedEnvelope)) retries=\(retries)")
        do {
            try await signalingRetryController.sendWithRetry(
                retries: retries,
                reconnectIfNeeded: { [weak self] in
                    try? await self?.signaling?.connectOrThrow()
                },
                send: { [weak self] in
                    guard let self else { throw CancellationError() }
                    try await self.ensureSignalingConnected(shardKey: authorizedEnvelope.sessionId)
                    guard let signaling = self.signaling else {
                        throw WebSocketSignalingClient.SignalingError.notConnected
                    }
                    try await signaling.send(authorizedEnvelope)
                }
            )
            appendSmokeTrace("tx-ok \(describeEnvelope(authorizedEnvelope))")
        } catch SignalingRetryControllerError.invalidWebSocketURL {
            lastError = "信令服务 URL 无效"
            appendSmokeTrace("tx-fail \(describeEnvelope(authorizedEnvelope)) error=invalid_websocket_url")
        } catch SignalingRetryControllerError.attemptTimedOut {
            lastError = "信令发送失败: 请求超时"
            appendSmokeTrace("tx-fail \(describeEnvelope(authorizedEnvelope)) error=attempt_timed_out")
        } catch is CancellationError {
            appendSmokeTrace("tx-cancel \(describeEnvelope(authorizedEnvelope))")
            return
        } catch {
            lastError = "信令发送失败: \(error.localizedDescription)"
            appendSmokeTrace("tx-fail \(describeEnvelope(authorizedEnvelope)) error=\(error.localizedDescription)")
        }
    }

    private func handleServerFrame(_ frame: WebSocketSignalingClient.SignalingServerFrame) {
        appendSmokeTrace(
            "server-frame type=\(frame.type) session=\(frame.sessionId ?? "-") error=\(frame.error ?? "-") what=\(frame.what ?? "-")"
        )
        guard frame.isError else { return }
        let sessionId = frame.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = frame.error ?? "unknown_signaling_error"
        let failureClass = classifySignalingFailureReason(reason)
        SkyBridgeLogger.shared.error("❌ signaling server rejected frame: session=\(sessionId ?? "-") error=\(reason)")

        if sessionId == nil,
           reason == "server_error",
           isTransportEstablished {
            SkyBridgeLogger.shared.warning("ℹ️ ignore unscoped signaling server_error after transport establishment")
            return
        }

        guard let sessionId else {
            lastError = "Signaling error: \(reason)"
            state = .failed(lastError ?? "Signaling error")
            readiness = .idle
            return
        }

        guard currentSessionId == sessionId else { return }

        if isTransportEstablished(for: sessionId) {
            if failureClass == .tokenExpired {
                signalingHealth = .degradedRecoverable
                scheduleSignalingRecovery(for: sessionId, tokenExpired: true)
            } else if isFatalPostTransportFailure(failureClass) {
                signalingHealth = .degradedFatal
            } else {
                signalingHealth = .degradedRecoverable
                scheduleSignalingRecovery(for: sessionId)
            }
            return
        }

        if isFatalPreTransportFailure(failureClass) {
            applyActiveSessionDisconnect(sessionId: sessionId, kind: .transient)
            lastError = "Signaling error: \(reason)"
            state = .failed(lastError ?? "Signaling error")
            readiness = .idle
            return
        }

        signalingHealth = .degradedRecoverable
        scheduleSignalingRecovery(for: sessionId, tokenExpired: failureClass == .tokenExpired)
        lastError = "Signaling error: \(reason)"
    }

    private var isTransportEstablished: Bool {
        switch readiness {
        case .transportReady:
            return true
        case .handshakeComplete:
            return true
        default:
            return false
        }
    }

    private func isTransportEstablished(for sessionId: String) -> Bool {
        switch readiness {
        case .transportReady(let activeSessionId):
            return activeSessionId == sessionId
        case .handshakeComplete(let activeSessionId, _):
            return activeSessionId == sessionId
        default:
            return false
        }
    }

    private enum SignalingFailureKind {
        case authBindRejected
        case invalidShardOrSessionMismatch
        case tokenExpired
        case transientNetwork
        case transientServer
        case protocolViolation
    }

    private func classifySignalingFailureReason(_ reason: String) -> SignalingFailureKind {
        let reason = reason.lowercased()
        if reason.contains("token") && reason.contains("expired") {
            return .tokenExpired
        }
        if reason.contains("auth")
            || reason.contains("unauthorized")
            || reason.contains("forbidden")
            || reason.contains("bind_rejected") {
            return .authBindRejected
        }
        if reason.contains("invalid shard")
            || reason.contains("invalid session")
            || reason.contains("session mismatch")
            || reason.contains("scope mismatch")
            || reason.contains("unknown shard") {
            return .invalidShardOrSessionMismatch
        }
        if reason.contains("protocol") || reason.contains("malformed") {
            return .protocolViolation
        }
        if reason.contains("socket is not connected")
            || reason.contains("socket未连接")
            || reason.contains("not connected") {
            return .transientNetwork
        }
        return .transientServer
    }

    private func isFatalPreTransportFailure(
        _ failureClass: SignalingFailureKind
    ) -> Bool {
        switch failureClass {
        case .authBindRejected, .invalidShardOrSessionMismatch, .protocolViolation:
            return true
        case .tokenExpired, .transientNetwork, .transientServer:
            return false
        }
    }

    private func isFatalPostTransportFailure(
        _ failureClass: SignalingFailureKind
    ) -> Bool {
        switch failureClass {
        case .authBindRejected, .invalidShardOrSessionMismatch, .protocolViolation:
            return true
        case .tokenExpired, .transientNetwork, .transientServer:
            return false
        }
    }

    private func scheduleSignalingRecovery(for sessionId: String, tokenExpired: Bool = false) {
        signalingRecoveryTasksBySessionId[sessionId]?.cancel()
        signalingRecoveryTasksBySessionId[sessionId] = Task { @MainActor [weak self] in
            guard let self else { return }
            let maxAttempts = tokenExpired ? 1 : 3
            for attempt in 0..<maxAttempts where !Task.isCancelled {
                if attempt > 0 {
                    try? await Task.sleep(for: .milliseconds(500 * (attempt + 1)))
                }
                do {
                    try await self.ensureSignalingConnected(shardKey: sessionId)
                    if self.signalingShardKey == sessionId {
                        self.signalingHealth = .healthy
                    }
                    self.signalingRecoveryTasksBySessionId.removeValue(forKey: sessionId)
                    return
                } catch is CancellationError {
                    self.signalingRecoveryTasksBySessionId.removeValue(forKey: sessionId)
                    SkyBridgeLogger.shared.debug(
                        "ℹ️ signaling recovery cancelled: session=\(sessionId) attempt=\(attempt + 1)"
                    )
                    return
                } catch {
                    SkyBridgeLogger.shared.error(
                        "⚠️ signaling recovery failed: session=\(sessionId) attempt=\(attempt + 1) err=\(error.localizedDescription)"
                    )
                }
            }
            if tokenExpired, self.isTransportEstablished(for: sessionId) {
                self.signalingHealth = .degradedFatal
            }
            self.signalingRecoveryTasksBySessionId.removeValue(forKey: sessionId)
        }
    }

    private func stopJoinHeartbeat() {
        joinHeartbeatTask?.cancel()
        joinHeartbeatTask = nil
    }

    private func startJoinHeartbeat(
        sessionId: String,
        localId: String,
        signaling expectedSignaling: WebSocketSignalingClient,
        attempts: Int = 30
    ) {
        stopJoinHeartbeat()
        joinHeartbeatTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var remaining = max(0, attempts)
            while remaining > 0,
                  !Task.isCancelled,
                  self.currentSessionId == sessionId,
                  self.signaling === expectedSignaling {
                if case .transportReady(let activeSessionID) = self.readiness, activeSessionID == sessionId {
                    break
                }
                if case .handshakeComplete(let activeSessionID, _) = self.readiness, activeSessionID == sessionId {
                    break
                }
                await self.sendEnvelope(
                    WebRTCSignalingEnvelope(sessionId: sessionId, from: localId, type: .join, payload: nil),
                    retries: 2
                )
                remaining -= 1
                if remaining == 0 { break }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func stopOfferResendLoop() {
        offerResendTask?.cancel()
        offerResendTask = nil
    }

    private func resendCachedOfferIfNeeded(sessionId: String, localId: String, reason: String) async {
        guard let sdp = latestLocalOfferBySessionId[sessionId] else { return }
        let enrichedSDP = sdpWithCachedLocalICECandidates(sessionId: sessionId, sdp: sdp)
        await sendEnvelope(
            WebRTCSignalingEnvelope(
                sessionId: sessionId,
                from: localId,
                type: .offer,
                payload: WebRTCSignalingEnvelope.Payload(sdp: enrichedSDP)
            ),
            retries: 2
        )
        if reason != "periodic" {
            lastError = nil
        }
    }

    private func startOfferResendLoop(
        sessionId: String,
        localId: String,
        signaling expectedSignaling: WebSocketSignalingClient,
        attempts: Int = 40
    ) {
        stopOfferResendLoop()
        offerResendTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var remaining = max(0, attempts)
            while remaining > 0,
                  !Task.isCancelled,
                  self.currentSessionId == sessionId,
                  self.signaling === expectedSignaling {
                if case .connected = self.state { break }
                await self.resendCachedOfferIfNeeded(sessionId: sessionId, localId: localId, reason: "periodic")
                await self.resendCachedLocalICECandidatesIfNeeded(sessionId: sessionId, localId: localId)
                remaining -= 1
                if remaining == 0 { break }
                try? await Task.sleep(for: .milliseconds(1500))
            }
        }
    }

    private func cacheLocalICECandidate(_ payload: WebRTCSignalingEnvelope.Payload, for sessionId: String) {
        guard let candidate = payload.candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !candidate.isEmpty else {
            return
        }

        var cached = localICECandidatesBySessionId[sessionId] ?? []
        if let existingIndex = cached.firstIndex(where: {
            $0.candidate == candidate &&
            $0.sdpMid == payload.sdpMid &&
            $0.sdpMLineIndex == payload.sdpMLineIndex
        }) {
            cached[existingIndex] = payload
        } else {
            cached.append(payload)
            let maxCachedCandidates = 32
            if cached.count > maxCachedCandidates {
                cached.removeFirst(cached.count - maxCachedCandidates)
            }
        }
        localICECandidatesBySessionId[sessionId] = cached
    }

    private func resendCachedAnswerIfNeeded(sessionId: String, localId: String) async {
        guard let sdp = latestLocalAnswerBySessionId[sessionId] else { return }
        let enrichedSDP = sdpWithCachedLocalICECandidates(sessionId: sessionId, sdp: sdp)
        let env = WebRTCSignalingEnvelope(
            sessionId: sessionId,
            from: localId,
            type: .answer,
            payload: WebRTCSignalingEnvelope.Payload(sdp: enrichedSDP)
        )
        await sendEnvelope(env, retries: 2)
    }

    private func sdpWithCachedLocalICECandidates(sessionId: String, sdp: String) -> String {
        guard let candidates = localICECandidatesBySessionId[sessionId], !candidates.isEmpty else {
            return sdp
        }
        return Self.injectLocalICECandidates(candidates, into: sdp)
    }

    private static func injectLocalICECandidates(
        _ candidates: [WebRTCSignalingEnvelope.Payload],
        into sdp: String
    ) -> String {
        let newline = sdp.contains("\r\n") ? "\r\n" : "\n"
        let normalizedLines = sdp
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        var prefix: [String] = []
        var sections: [[String]] = []
        var currentSection: [String]? = nil

        for line in normalizedLines {
            if line.hasPrefix("m=") {
                if let currentSection {
                    sections.append(currentSection)
                }
                currentSection = [line]
            } else if currentSection != nil {
                currentSection?.append(line)
            } else {
                prefix.append(line)
            }
        }
        if let currentSection {
            sections.append(currentSection)
        }
        guard !sections.isEmpty else { return sdp }

        for payload in candidates {
            guard let candidateLine = normalizedCandidateSDPLine(from: payload) else { continue }
            let targetIndex = targetMediaSectionIndex(for: payload, sections: sections) ?? 0
            guard sections.indices.contains(targetIndex) else { continue }
            insertSDPLine(candidateLine, into: &sections[targetIndex])
        }

        var flattened = prefix
        for section in sections {
            flattened.append(contentsOf: section)
        }

        var rendered = flattened.joined(separator: newline)
        if sdp.hasSuffix("\r\n") || sdp.hasSuffix("\n") {
            rendered.append(newline)
        }
        return rendered
    }

    private static func normalizedCandidateSDPLine(from payload: WebRTCSignalingEnvelope.Payload) -> String? {
        guard let raw = payload.candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        if raw.hasPrefix("a=") {
            return raw
        }
        if raw.hasPrefix("candidate:") {
            return "a=\(raw)"
        }
        return raw
    }

    private static func targetMediaSectionIndex(
        for payload: WebRTCSignalingEnvelope.Payload,
        sections: [[String]]
    ) -> Int? {
        if let index = payload.sdpMLineIndex, index >= 0, Int(index) < sections.count {
            return Int(index)
        }
        if let mid = payload.sdpMid?.trimmingCharacters(in: .whitespacesAndNewlines),
           !mid.isEmpty,
           let match = sections.firstIndex(where: { section in
               section.contains(where: { $0 == "a=mid:\(mid)" })
           }) {
            return match
        }
        return sections.isEmpty ? nil : max(0, sections.count - 1)
    }

    private static func insertSDPLine(_ line: String, into section: inout [String]) {
        guard !section.contains(line) else { return }
        if let insertionIndex = section.firstIndex(of: "a=end-of-candidates") {
            section.insert(line, at: insertionIndex)
        } else {
            section.append(line)
        }
    }

    private func resendCachedLocalICECandidatesIfNeeded(sessionId: String, localId: String) async {
        guard let candidates = localICECandidatesBySessionId[sessionId], !candidates.isEmpty else { return }
        for payload in candidates {
            let env = WebRTCSignalingEnvelope(
                sessionId: sessionId,
                from: localId,
                type: .iceCandidate,
                payload: payload
            )
            await sendEnvelope(env, retries: 2)
        }
    }
    
    /// 发送远程桌面消息（鼠标/键盘/屏幕）到 macOS（通过已建立的 WebRTC DataChannel + 会话密钥）
    public func sendRemoteDesktopMessage(_ message: RemoteMessage) async throws {
        guard let session, let keys = sessionKeys else { throw RemoteDesktopError.disconnected }
        let data = try JSONEncoder().encode(message)
        let encrypted = try encrypt(plaintext: data, with: keys)
        let padded = TrafficPadding.wrapIfEnabled(encrypted, label: "tx/webrtc-remote")
        try await sendFramed(padded, over: session)
    }

    public func startRemoteDesktopHeartbeat() {
        remoteDesktopHeartbeatTask?.cancel()
        remoteDesktopHeartbeatTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.appendSmokeTrace("heartbeat-loop start session=\(self.currentSessionId ?? "-")")
            while !Task.isCancelled {
                guard let session = self.session,
                      let sessionId = self.currentSessionId,
                      case .connected(let activeSessionId) = self.state,
                      activeSessionId == sessionId
                else { break }

                if self.rekeyInProgressSessionIds.contains(sessionId) {
                    do {
                        try await Task.sleep(for: .milliseconds(250))
                    } catch {
                        break
                    }
                    continue
                }

                #if canImport(UIKit)
                let localName = UIDevice.current.name
                let localModel = UIDevice.current.model
                #else
                let localName: String? = nil
                let localModel: String? = nil
                #endif

                let heartbeat = AppMessage.heartbeat(.init(
                    sentAt: Date(),
                    deviceId: self.localDeviceId,
                    deviceName: localName,
                    modelName: localModel,
                    platform: "iOS",
                    osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                    chip: nil,
                    remoteVideoFormats: RemoteDesktopManager.supportedRemoteVideoFormats()
                ))

                do {
                    self.appendSmokeTrace("heartbeat-send session=\(sessionId)")
                    try await self.sendAppMessageOverWebRTC(
                        heartbeat,
                        sessionId: sessionId,
                        session: session,
                        label: "tx/webrtc-heartbeat"
                    )
                    self.appendSmokeTrace("heartbeat-send-ok session=\(sessionId)")
                } catch {
                    self.appendSmokeTrace("heartbeat-send-failed session=\(sessionId) error=\(error.localizedDescription)")
                    SkyBridgeLogger.shared.debug("ℹ️ WebRTC heartbeat send failed: \(error.localizedDescription)")
                    break
                }

                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    break
                }
            }
        }
    }

    private func shouldAutoStartRemoteDesktopHeartbeat() -> Bool {
        if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] == "ios-client" {
            return true
        }
        return currentRole == .answerer
    }

    public func stopRemoteDesktopHeartbeat() {
        remoteDesktopHeartbeatTask?.cancel()
        remoteDesktopHeartbeatTask = nil
    }

    private func cleanupInboundFileTransfers() {
        for (_, st) in inboundFileTransfers {
            try? st.handle.close()
            try? FileManager.default.removeItem(at: st.tempURL)
        }
        inboundFileTransfers.removeAll()
    }
    
    // MARK: - Internals
    
    private struct DynamicQRCodeData: Codable {
        let version: Int
        let sessionID: String
        let qrBootstrapToken: String
        let signalingServerOrigin: String
        let deviceID: String
        let deviceName: String
        let deviceType: String
        let osVersion: String
        let capabilities: [String]
        let protocolSigningAlgorithm: ProtocolSigningAlgorithm
        let protocolPublicKeyBytes: Data
        let protocolPublicKeyFingerprint: String
        let signature: Data?
        let signatureTimestampMs: Int64
        let expiresAt: Date

        init(
            version: Int,
            sessionID: String,
            qrBootstrapToken: String,
            signalingServerOrigin: String,
            deviceID: String,
            deviceName: String,
            deviceType: String,
            osVersion: String,
            capabilities: [String],
            protocolSigningAlgorithm: ProtocolSigningAlgorithm,
            protocolPublicKeyBytes: Data,
            protocolPublicKeyFingerprint: String,
            signature: Data?,
            signatureTimestampMs: Int64,
            expiresAt: Date
        ) {
            self.version = version
            self.sessionID = sessionID
            self.qrBootstrapToken = qrBootstrapToken
            self.signalingServerOrigin = signalingServerOrigin
            self.deviceID = deviceID
            self.deviceName = deviceName
            self.deviceType = deviceType
            self.osVersion = osVersion
            self.capabilities = capabilities
            self.protocolSigningAlgorithm = protocolSigningAlgorithm
            self.protocolPublicKeyBytes = protocolPublicKeyBytes
            self.protocolPublicKeyFingerprint = protocolPublicKeyFingerprint.lowercased()
            self.signature = signature
            self.signatureTimestampMs = signatureTimestampMs
            self.expiresAt = expiresAt
        }

        init(from decoder: Decoder) throws {
            let compact = try CompactDynamicQRCodeData(from: decoder)
            self = try compact.expanded()
        }

        func encode(to encoder: Encoder) throws {
            try CompactDynamicQRCodeData(from: self).encode(to: encoder)
        }

        var normalizedCapabilities: [String] {
            Array(Set(
                capabilities
                    .map { $0.precomposedStringWithCanonicalMapping.lowercased() }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            ))
            .sorted { lhs, rhs in
                Data(lhs.utf8).lexicographicallyPrecedes(Data(rhs.utf8))
            }
        }

        var canonicalSignalingServerOrigin: String {
            (try? CurrentPathSecurityCompat.canonicalOrigin(signalingServerOrigin)) ?? signalingServerOrigin
        }
    }

    private struct CompactDynamicQRCodeData: Codable {
        let v: Int
        let s: String
        let q: String
        let r: String
        let d: String
        let n: String
        let y: String
        let o: String
        let c: [String]
        let a: String
        let k: String
        let f: String
        let g: String?
        let t: Int64
        let e: Int64

        init(from qrData: DynamicQRCodeData) {
            self.v = qrData.version
            self.s = qrData.sessionID
            self.q = qrData.qrBootstrapToken
            self.r = qrData.canonicalSignalingServerOrigin
            self.d = qrData.deviceID
            self.n = qrData.deviceName.precomposedStringWithCanonicalMapping
            self.y = qrData.deviceType
            self.o = qrData.osVersion.precomposedStringWithCanonicalMapping
            self.c = qrData.normalizedCapabilities
            self.a = qrData.protocolSigningAlgorithm.rawValue
            self.k = Self.base64URLEncodedString(qrData.protocolPublicKeyBytes)
            self.f = qrData.protocolPublicKeyFingerprint.lowercased()
            self.g = qrData.signature.map(Self.base64URLEncodedString)
            self.t = qrData.signatureTimestampMs
            self.e = Int64(qrData.expiresAt.timeIntervalSince1970 * 1000)
        }

        private static func base64URLEncodedString(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }

        func expanded() throws -> DynamicQRCodeData {
            guard let algorithm = ProtocolSigningAlgorithm(rawValue: a) else {
                throw NSError(domain: "CrossNetworkWebRTCManager", code: 10, userInfo: [NSLocalizedDescriptionKey: "invalid signing algorithm"])
            }
            guard let keyData = CrossNetworkWebRTCManager.decodeConnectPayload(k) else {
                throw NSError(domain: "CrossNetworkWebRTCManager", code: 11, userInfo: [NSLocalizedDescriptionKey: "invalid public key encoding"])
            }
            let signatureData: Data?
            if let g {
                guard let decoded = CrossNetworkWebRTCManager.decodeConnectPayload(g) else {
                    throw NSError(domain: "CrossNetworkWebRTCManager", code: 12, userInfo: [NSLocalizedDescriptionKey: "invalid signature encoding"])
                }
                signatureData = decoded
            } else {
                signatureData = nil
            }
            return DynamicQRCodeData(
                version: v,
                sessionID: s,
                qrBootstrapToken: q,
                signalingServerOrigin: r,
                deviceID: d,
                deviceName: n,
                deviceType: y,
                osVersion: o,
                capabilities: c,
                protocolSigningAlgorithm: algorithm,
                protocolPublicKeyBytes: keyData,
                protocolPublicKeyFingerprint: f,
                signature: signatureData,
                signatureTimestampMs: t,
                expiresAt: Date(timeIntervalSince1970: TimeInterval(e) / 1000.0)
            )
        }
    }
    
    private enum ConnectLinkError: LocalizedError {
        case invalidFormat
        case invalidBase64
        case expired
        case invalidSignature
        
        var errorDescription: String? {
            switch self {
            case .invalidFormat: return "二维码格式无效"
            case .invalidBase64: return "二维码内容损坏"
            case .expired: return "二维码已过期"
            case .invalidSignature: return "二维码签名或绑定字段无效"
            }
        }
    }
    
    private enum ConnectionCodeError: LocalizedError {
        case invalid
        
        var errorDescription: String? {
            switch self {
            case .invalid:
                return "连接码无效（需要 8 位，兼容 6 位旧码）"
            }
        }
    }

    public static func sanitizeConnectionCodeInput(_ raw: String) -> String {
        String(
            raw
                .uppercased()
                .filter { shortCodeAllowedCharacters.contains($0) }
                .prefix(maximumConnectionCodeLength)
        )
    }

    public static func isSupportedConnectionCodeLength(_ count: Int) -> Bool {
        count == legacyConnectionCodeLength || (preferredConnectionCodeLength...maximumConnectionCodeLength).contains(count)
    }

    public static func canSubmitConnectionCode(_ raw: String) -> Bool {
        isSupportedConnectionCodeLength(sanitizeConnectionCodeInput(raw).count)
    }

    nonisolated static func canonicalPQCRekeyElectionDeviceId(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.lowercased().hasPrefix("webrtc-") else { return nil }
        return trimmed.lowercased()
    }

    nonisolated static func shouldInitiatePQCRekey(localDeviceId: String?, remoteDeviceId: String?) -> Bool? {
        guard let local = canonicalPQCRekeyElectionDeviceId(localDeviceId),
              let remote = canonicalPQCRekeyElectionDeviceId(remoteDeviceId) else {
            return nil
        }
        guard local != remote else { return nil }
        return local.lexicographicallyPrecedes(remote)
    }
    
    private func normalizeConnectionCode(_ raw: String) throws -> String {
        let code = Self.sanitizeConnectionCodeInput(raw)
        guard Self.isSupportedConnectionCodeLength(code.count) else { throw ConnectionCodeError.invalid }
        return code
    }

    private static func generateShortCode() -> String {
        String((0..<preferredConnectionCodeLength).compactMap { _ in shortCodeAlphabet.randomElement() })
    }

    public static func isConnectLinkString(_ raw: String) -> Bool {
        extractConnectPayloadString(from: raw.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }
    
    private func parseSkybridgeConnectLink(_ string: String) async throws -> DynamicQRCodeData {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let payload = Self.extractConnectPayloadString(from: trimmed) else {
            throw ConnectLinkError.invalidFormat
        }

        guard let jsonData = Self.decodeConnectPayload(payload) else {
            throw ConnectLinkError.invalidBase64
        }
        let qr = try decodeDynamicQRCodePayload(from: jsonData)
        guard qr.expiresAt > Date() else { throw ConnectLinkError.expired }
        _ = try validateCurrentPathOrigin(qr.signalingServerOrigin)
        let verifyResult = try await verifyDynamicQRCode(qr)
        guard verifyResult.ok else {
            let reason = verifyResult.reason ?? "二维码校验失败"
            SkyBridgeLogger.shared.error("❌ iOS QR 校验失败: \(reason)")
            throw NSError(
                domain: "CrossNetworkWebRTCManager",
                code: 25,
                userInfo: [NSLocalizedDescriptionKey: reason]
            )
        }
        try enforceCurrentPathTrustBinding(
            deviceId: qr.deviceID,
            protocolPublicKeyFingerprint: qr.protocolPublicKeyFingerprint
        )
        let localBinding = try currentPathLocalBinding()
        let admission = try await requestAdmissionLease(for: localBinding)
        let redeemed = try await signalServer.redeemSession(
            admissionToken: admission.token,
            sessionId: qr.sessionID,
            qrBootstrapToken: qr.qrBootstrapToken
        )
        _ = try validateCurrentPathOrigin(redeemed.signalingServerOrigin)
        guard redeemed.initiatorDeviceId == qr.deviceID,
              redeemed.initiatorProtocolSigningAlgorithm == qr.protocolSigningAlgorithm,
              redeemed.initiatorProtocolPublicKeyFingerprint == qr.protocolPublicKeyFingerprint else {
            throw ConnectLinkError.invalidSignature
        }
        webrtcSignalingAuthTokenBySessionId[qr.sessionID] = redeemed.sessionToken
        webrtcTurnAdmissionTokenBySessionId[qr.sessionID] = redeemed.turnAdmissionToken
        currentPathSignalingOriginBySessionId[qr.sessionID] = redeemed.signalingServerOrigin
        currentPathExpectedRemoteAuthorityBySessionId[qr.sessionID] = CurrentPathRemoteAuthorityCompat(
            deviceId: qr.deviceID,
            protocolSigningAlgorithm: qr.protocolSigningAlgorithm,
            protocolPublicKeyFingerprint: qr.protocolPublicKeyFingerprint,
            protocolPublicKeyBytes: qr.protocolPublicKeyBytes,
            deviceName: qr.deviceName
        )
        SkyBridgeLogger.shared.debug("ℹ️ iOS QR 仅完成内容完整性校验；设备来源认证仍依赖后续握手/pinning")
        return qr
    }

    private func decodeDynamicQRCodePayload(from jsonData: Data) throws -> DynamicQRCodeData {
        try JSONDecoder().decode(DynamicQRCodeData.self, from: jsonData)
    }

    private static func extractConnectPayloadString(from raw: String) -> String? {
        let prefix = "skybridge://connect/"
        if raw.hasPrefix(prefix) {
            return String(raw.dropFirst(prefix.count))
        }

        guard let url = URL(string: raw), url.scheme == "skybridge", url.host == "connect" else {
            return nil
        }
        let pathPayload = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !pathPayload.isEmpty {
            return pathPayload
        }
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let queryPayload = components.queryItems?.first(where: { $0.name == "data" })?.value,
           !queryPayload.isEmpty {
            return queryPayload
        }
        return nil
    }

    nonisolated static func decodeConnectPayload(_ rawPayload: String) -> Data? {
        for candidate in strictBase64URLCandidates(from: rawPayload) {
            if let data = Data(base64Encoded: candidate) {
                return data
            }
        }
        return nil
    }

    nonisolated private static func strictBase64URLCandidates(from rawPayload: String) -> [String] {
        let rawCandidates = [rawPayload, rawPayload.removingPercentEncoding]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let allowedCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_+/=")
        var normalizedCandidates: [String] = []
        var seen = Set<String>()

        for rawCandidate in rawCandidates {
            let compactScalars = rawCandidate.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
            guard !compactScalars.isEmpty else { continue }
            guard compactScalars.allSatisfy({ allowedCharacters.contains($0) }) else { continue }

            let normalized = String(String.UnicodeScalarView(compactScalars))
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            let padded = normalized + String(repeating: "=", count: (4 - (normalized.count % 4)) % 4)
            if seen.insert(padded).inserted {
                normalizedCandidates.append(padded)
            }
        }

        return normalizedCandidates
    }

    private func buildCanonicalQRCodePayload(for qrData: DynamicQRCodeData) -> Data {
        var data = Data()

        func appendUInt16(_ value: UInt16) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }

        func appendUInt32(_ value: UInt32) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }

        func appendInt64(_ value: Int64) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }

        func appendString(_ value: String) {
            let bytes = Data(value.precomposedStringWithCanonicalMapping.utf8)
            appendUInt32(UInt32(bytes.count))
            data.append(bytes)
        }

        func appendData(_ value: Data) {
            appendUInt32(UInt32(value.count))
            data.append(value)
        }

        appendUInt16(UInt16(max(0, qrData.version)))
        appendString(qrData.sessionID)
        appendString(qrData.qrBootstrapToken)
        appendInt64(Int64(qrData.expiresAt.timeIntervalSince1970 * 1000))
        appendString(qrData.canonicalSignalingServerOrigin)
        appendString(qrData.deviceID)
        appendString(qrData.deviceName)
        appendString(qrData.deviceType)
        appendString(qrData.osVersion)
        appendUInt32(UInt32(qrData.normalizedCapabilities.count))
        for capability in qrData.normalizedCapabilities {
            appendString(capability)
        }
        appendString(qrData.protocolSigningAlgorithm.rawValue)
        appendData(qrData.protocolPublicKeyBytes)
        appendString(qrData.protocolPublicKeyFingerprint)
        appendInt64(qrData.signatureTimestampMs)
        return data
    }

    private func verifyDynamicQRCode(_ qrData: DynamicQRCodeData) async throws -> (ok: Bool, reason: String?) {
        guard qrData.version >= 6 else {
            return (false, "二维码协议版本过旧")
        }
        guard !qrData.sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (false, "二维码缺少 sessionID")
        }
        guard !qrData.qrBootstrapToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (false, "二维码缺少 bootstrap token")
        }
        guard (try? CurrentPathSecurityCompat.normalizeDeviceId(qrData.deviceID)) != nil else {
            return (false, "二维码 deviceId 格式无效")
        }
        guard (try? CurrentPathSecurityCompat.canonicalOrigin(qrData.signalingServerOrigin)) != nil else {
            return (false, "二维码 signaling origin 无效")
        }
        guard !qrData.deviceType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (false, "二维码缺少 deviceType")
        }
        guard !qrData.osVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (false, "二维码缺少 osVersion")
        }
        guard !qrData.normalizedCapabilities.isEmpty else {
            return (false, "二维码缺少能力列表")
        }
        guard let signature = qrData.signature else {
            return (false, "二维码缺少签名")
        }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let skewMs: Int64 = 120_000
        guard qrData.signatureTimestampMs <= nowMs + skewMs else {
            return (false, "二维码签名时间过于超前")
        }
        guard Int64(qrData.expiresAt.timeIntervalSince1970 * 1000) >= nowMs - skewMs else {
            return (false, "二维码已过期")
        }
        guard qrData.signatureTimestampMs <= Int64(qrData.expiresAt.timeIntervalSince1970 * 1000) else {
            return (false, "二维码时间戳与过期时间矛盾")
        }
        do {
            try CurrentPathSecurityCompat.validateKeyEncoding(bytes: qrData.protocolPublicKeyBytes, algorithm: qrData.protocolSigningAlgorithm)
        } catch {
            return (false, error.localizedDescription)
        }
        let computedFingerprint = CurrentPathSecurityCompat.computeFingerprint(
            algorithm: qrData.protocolSigningAlgorithm,
            publicKeyBytes: qrData.protocolPublicKeyBytes
        )
        guard computedFingerprint == qrData.protocolPublicKeyFingerprint else {
            return (false, "二维码长期协议公钥指纹不匹配")
        }
        let provider = ProtocolSignatureProviderSelector.select(for: qrData.protocolSigningAlgorithm)
        let canonicalPayload = buildCanonicalQRCodePayload(for: qrData)
        let isValid = try await provider.verify(
            canonicalPayload,
            signature: signature,
            publicKey: qrData.protocolPublicKeyBytes
        )
        return isValid ? (true, nil) : (false, "二维码签名验证失败")
    }
    
    private func connect(from qr: DynamicQRCodeData) async throws {
        try await connect(
            sessionId: qr.sessionID,
            remoteName: qr.deviceName,
            remotePeerDeviceId: qr.deviceID,
            source: .qr,
            role: .answerer
        )
    }
    
    private func connect(
        sessionId: String,
        remoteName: String?,
        remotePeerDeviceId: String?,
        source: ActiveSessionSnapshotSource,
        role: WebRTCSession.Role
    ) async throws {
        if currentSessionId == sessionId {
            switch state {
            case .connecting(let activeSessionId) where activeSessionId == sessionId:
                return
            case .connected(let activeSessionId) where activeSessionId == sessionId:
                return
            default:
                break
            }
        }

        let preservedSignalingToken = webrtcSignalingAuthTokenBySessionId[sessionId]
        let preservedTurnAdmissionToken = webrtcTurnAdmissionTokenBySessionId[sessionId]
        let preservedSignalingOrigin = currentPathSignalingOriginBySessionId[sessionId]
        let preservedRemoteAuthority = currentPathExpectedRemoteAuthorityBySessionId[sessionId]

        if signaling != nil || session != nil || currentSessionId != nil {
            await disconnect()
            if let preservedSignalingToken {
                webrtcSignalingAuthTokenBySessionId[sessionId] = preservedSignalingToken
            }
            if let preservedTurnAdmissionToken {
                webrtcTurnAdmissionTokenBySessionId[sessionId] = preservedTurnAdmissionToken
            }
            if let preservedSignalingOrigin {
                currentPathSignalingOriginBySessionId[sessionId] = preservedSignalingOrigin
            }
            if let preservedRemoteAuthority {
                currentPathExpectedRemoteAuthorityBySessionId[sessionId] = preservedRemoteAuthority
            }
        }

        currentSessionId = sessionId
        state = .connecting(sessionId: sessionId)
        readiness = .idle
        lastError = nil
#if canImport(WebRTC)
        installRemoteVideoTrack(nil)
#endif
        handshakePeerId = remotePeerDeviceId ?? "webrtc-\(sessionId)"
        remoteDeviceName = remoteName
        remoteDeviceId = remotePeerDeviceId
        currentRole = role
        appendSmokeTrace(
            "connect session=\(sessionId) role=\(role == .offerer ? "offerer" : "answerer") source=\(String(describing: source)) remoteId=\(remotePeerDeviceId ?? "-") remoteName=\(remoteName ?? "-")"
        )
        prepareSessionSnapshotMetadata(
            sessionId: sessionId,
            source: source,
            deviceId: remotePeerDeviceId,
            deviceName: remoteName
        )
        activatePreparedSessionSnapshot(sessionId: sessionId, phase: .connecting)
        if role != .offerer {
            localConnectionCode = nil
            localConnectionSessionId = nil
        }
        
        // 1) WebSocket signaling
        do {
            try await ensureSignalingConnected(shardKey: sessionId)
        } catch {
            applyActiveSessionDisconnect(sessionId: sessionId, kind: .explicit)
            state = .failed(error.localizedDescription)
            readiness = .idle
            throw error
        }
        guard let signaling = self.signaling else {
            let error = WebSocketSignalingClient.SignalingError.notConnected
            applyActiveSessionDisconnect(sessionId: sessionId, kind: .explicit)
            state = .failed(error.localizedDescription)
            readiness = .idle
            throw error
        }
        
        // 2) WebRTC session (offerer / answerer)
        let localId = localDeviceId

        // SECURITY: Never hardcode TURN credentials in the client app.
        // Use short-lived TURN REST credentials fetched from backend (with safe fallback).
        let ice = await CrossNetworkServerConfig.dynamicICEConfig(
            turnAdmissionToken: webrtcTurnAdmissionTokenBySessionId[sessionId]
        )
        appendSmokeTrace(
            "ice session=\(sessionId) role=\(role == .offerer ? "offerer" : "answerer") stun=\(ice.stunURL.isEmpty ? 0 : 1) turnUrls=\(ice.turnURLs.count) turnCreds=\((ice.turnUsername.isEmpty || ice.turnPassword.isEmpty) ? 0 : 1)"
        )
        
        let s = WebRTCSession(sessionId: sessionId, localDeviceId: localId, role: role, ice: ice)
        self.session = s
        s.onTrace = { [weak self] line in
            self?.appendSmokeTrace("webrtc \(line)")
        }
#if canImport(WebRTC)
        s.onRemoteVideoTrack = { [weak self] track in
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.currentSessionId == sessionId,
                      self.session === s else { return }
                self.installRemoteVideoTrack(track)
            }
        }
#endif

        s.onLocalOffer = { [weak self] (sdp: String) in
            guard let self else { return }
            Task {
                let isCurrentSession = await MainActor.run { self.session === s }
                guard isCurrentSession else { return }
                await MainActor.run {
                    self.latestLocalOfferBySessionId[sessionId] = sdp
                    self.appendSmokeTrace("local-offer session=\(sessionId) \(Self.describeSDPCandidates(sdp))")
                }
                let env = WebRTCSignalingEnvelope(
                    sessionId: sessionId,
                    from: localId,
                    type: .offer,
                    payload: WebRTCSignalingEnvelope.Payload(sdp: sdp)
                )
                await self.sendEnvelope(env, retries: 2)
            }
        }
        
        s.onLocalAnswer = { [weak self] (sdp: String) in
            guard let self else { return }
            Task {
                let isCurrentSession = await MainActor.run { self.session === s }
                guard isCurrentSession else { return }
                await MainActor.run {
                    self.latestLocalAnswerBySessionId[sessionId] = sdp
                    self.appendSmokeTrace("local-answer session=\(sessionId) \(Self.describeSDPCandidates(sdp))")
                }
                let env = WebRTCSignalingEnvelope(
                    sessionId: sessionId,
                    from: localId,
                    type: .answer,
                    payload: WebRTCSignalingEnvelope.Payload(sdp: sdp)
                )
                await self.sendEnvelope(env, retries: 2)
            }
        }
        
        s.onLocalICECandidate = { [weak self] (payload: WebRTCSignalingEnvelope.Payload) in
            guard let self else { return }
            Task {
                let isCurrentSession = await MainActor.run { self.session === s }
                guard isCurrentSession else { return }
                let candidateKind = Self.describeCandidateKind(payload.candidate)
                await MainActor.run {
                    self.cacheLocalICECandidate(payload, for: sessionId)
                    self.appendSmokeTrace("local-ice session=\(sessionId) kind=\(candidateKind) mid=\(payload.sdpMid ?? "-") index=\(payload.sdpMLineIndex ?? -1)")
                }
                let env = WebRTCSignalingEnvelope(
                    sessionId: sessionId,
                    from: localId,
                    type: .iceCandidate,
                    payload: payload
                )
                await self.sendEnvelope(env, retries: 1)
            }
        }

        // Inbound frames from DataChannel
        let inbound = InboundChunkQueue()
        let screenInbound = InboundChunkQueue()
        self.inboundQueue = inbound
        self.screenInboundQueue = screenInbound
        s.onData = { data in
            Task { [weak self] in
                guard let self else { return }
                let isCurrentSession = await MainActor.run { self.session === s }
                guard isCurrentSession else { return }
                let rekeyInProgress = await MainActor.run {
                    self.rekeyInProgressSessionIds.contains(sessionId)
                }
                if rekeyInProgress {
                    await MainActor.run {
                        self.lastRekeyEvent = "chunk bytes=\(data.count)"
                        self.appendSmokeTrace("rx chunk bytes=\(data.count)")
                    }
                    if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                        print("🧪 WebRTC rekey rx chunk bytes=\(data.count)")
                    }
                }
                await inbound.push(data)
            }
        }
        s.onScreenData = { data in
            Task { [weak self] in
                guard let self else { return }
                let isCurrentSession = await MainActor.run {
                    self.currentSessionId == sessionId && self.session === s
                }
                guard isCurrentSession else { return }
                await screenInbound.push(data)
            }
        }

        s.onDisconnected = { [weak self] reason in
            Task {
                guard let self else { return }
                let isCurrentSession = await MainActor.run {
                    self.currentSessionId == sessionId && self.session === s
                }
                guard isCurrentSession else { return }
                let msg = "WebRTC 传输已断开: \(reason)"
                await MainActor.run {
                    self.appendSmokeTrace("transport-disconnected session=\(sessionId) reason=\(reason)")
                    self.lastError = msg
                    self.applyActiveSessionDisconnect(sessionId: sessionId, kind: .transient)
                }
                await self.disconnect(clearSnapshot: false)
                await MainActor.run {
                    self.lastError = msg
                    self.state = .failed(msg)
                    self.readiness = .idle
                }
            }
        }
        
        s.onReady = { [weak self] in
            Task {
                guard let self else { return }
                let isCurrentSession = await MainActor.run {
                    self.currentSessionId == sessionId && self.session === s
                }
                guard isCurrentSession else { return }

                let shouldStartHandshake: Bool = await MainActor.run {
                    self.stopJoinHeartbeat()
                    self.stopOfferResendLoop()
                    self.appendSmokeTrace("transport-ready session=\(sessionId) role=\(role == .offerer ? "offerer" : "answerer")")
                    self.readiness = .transportReady(sessionId: sessionId)
                    self.updatePreparedSessionSnapshot(
                        sessionId: sessionId,
                        phase: .transportReady,
                        deviceId: self.remoteDeviceId,
                        deviceName: self.remoteDeviceName
                    )
                    SkyBridgeLogger.shared.info("✅ WebRTC transport ready: session=\(sessionId), role=\(String(describing: role))")

                    if !self.handshakeStartedSessionIds.contains(sessionId) {
                        self.handshakeStartedSessionIds.insert(sessionId)
                        return true
                    }
                    return false
                }

                if shouldStartHandshake {
                    let peerDeviceId = await MainActor.run {
                        self.remoteDeviceId ?? self.handshakePeerId ?? "webrtc-\(sessionId)"
                    }
                    await self.startHandshakeOverWebRTC(
                        sessionId: sessionId,
                        peerDeviceId: peerDeviceId,
                        session: s,
                        inbound: inbound
                    )
                } else {
                    SkyBridgeLogger.shared.debug("ℹ️ skip duplicate WebRTC handshake start: session=\(sessionId)")
                }
            }
        }

        try s.start()
        appendSmokeTrace("session-started session=\(sessionId) role=\(role == .offerer ? "offerer" : "answerer")")

        screenReceiveTask?.cancel()
        screenReceiveTask = Task {
            await self.receiveScreenLoop(sessionId: sessionId, session: s, inbound: screenInbound)
        }

        // 3) Join room + heartbeat to mask websocket timing jitters.
        await sendEnvelope(WebRTCSignalingEnvelope(sessionId: sessionId, from: localId, type: .join, payload: nil), retries: 2)
        startJoinHeartbeat(sessionId: sessionId, localId: localId, signaling: signaling)
        if role == .offerer {
            startOfferResendLoop(sessionId: sessionId, localId: localId, signaling: signaling)
        }
    }
    
    private func handleEnvelope(_ env: WebRTCSignalingEnvelope) {
        guard env.sessionId == currentSessionId else { return }
        // Ignore self-echo
        let localId = localDeviceId
        if env.from == localId { return }
        appendSmokeTrace("rx \(describeEnvelope(env))")
        
        // If we don't know the remote id yet (e.g., code mode), learn it from signaling.
        if remoteDeviceId == nil || remoteDeviceId?.hasPrefix("webrtc-") == true {
            remoteDeviceId = env.from
            handshakePeerId = env.from
            updatePreparedSessionSnapshot(
                sessionId: env.sessionId,
                phase: .connecting,
                deviceId: env.from
            )
        }
        
        switch env.type {
        case .offer:
            if let sdp = env.payload?.sdp {
                appendSmokeTrace("remote-offer session=\(env.sessionId) \(Self.describeSDPCandidates(sdp))")
                session?.setRemoteOffer(sdp)
            }
            let localId = localDeviceId
            Task { @MainActor [weak self] in
                await self?.resendCachedAnswerIfNeeded(sessionId: env.sessionId, localId: localId)
                await self?.resendCachedLocalICECandidatesIfNeeded(sessionId: env.sessionId, localId: localId)
            }
        case .answer:
            stopOfferResendLoop()
            if let sdp = env.payload?.sdp {
                appendSmokeTrace("remote-answer session=\(env.sessionId) \(Self.describeSDPCandidates(sdp))")
                session?.setRemoteAnswer(sdp)
            }
            let localId = localDeviceId
            Task { @MainActor [weak self] in
                await self?.resendCachedLocalICECandidatesIfNeeded(sessionId: env.sessionId, localId: localId)
            }
        case .iceCandidate:
            if let p = env.payload, let c = p.candidate {
                appendSmokeTrace(
                    "remote-ice session=\(env.sessionId) kind=\(Self.describeCandidateKind(p.candidate)) mid=\(p.sdpMid ?? "-") index=\(p.sdpMLineIndex ?? -1)"
                )
                session?.addRemoteICECandidate(candidate: c, sdpMid: p.sdpMid, sdpMLineIndex: p.sdpMLineIndex)
            }
        case .join:
            appendSmokeTrace("remote-join session=\(env.sessionId) from=\(env.from)")
            if currentRole == .offerer, let sid = currentSessionId, sid == env.sessionId {
                let localId = localDeviceId
                Task { @MainActor [weak self] in
                    await self?.resendCachedOfferIfNeeded(sessionId: sid, localId: localId, reason: "remote-join")
                    await self?.resendCachedAnswerIfNeeded(sessionId: sid, localId: localId)
                    await self?.resendCachedLocalICECandidatesIfNeeded(sessionId: sid, localId: localId)
                }
            }
        case .leave:
            stopJoinHeartbeat()
            stopOfferResendLoop()
            appendSmokeTrace("remote-leave session=\(env.sessionId) from=\(env.from)")
            applyActiveSessionDisconnect(sessionId: env.sessionId, kind: .remoteLeave)
            Task { @MainActor [weak self] in
                await self?.disconnect(clearSnapshot: false)
            }
        }
    }
}

// MARK: - WebRTC file transfer helpers (iOS)

@available(iOS 17.0, *)
public extension CrossNetworkWebRTCManager {
    func sendFileTransferMessage(_ message: CrossNetworkFileTransferMessage) async throws {
        guard let session, let keys = sessionKeys else { throw RemoteDesktopError.disconnected }
        let data = try JSONEncoder().encode(message)
        let encrypted = try encrypt(plaintext: data, with: keys)
        let padded = TrafficPadding.wrapIfEnabled(encrypted, label: "tx/webrtc-file")
        try await sendFramed(padded, over: session)
    }
    
    func waitForFileTransferAck(
        transferId: String,
        op: CrossNetworkFileTransferOp,
        chunkIndex: Int? = nil,
        timeoutSeconds: TimeInterval = 20
    ) async throws -> CrossNetworkFileTransferMessage {
        let key = fileTransferWaiterKey(transferId: transferId, op: op, chunkIndex: chunkIndex)
        if fileTransferWaiters[key] != nil {
            // Prevent accidental double-waits on the same key.
            throw FileTransferWaitError.cancelled
        }
        
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<CrossNetworkFileTransferMessage, Error>) in
            fileTransferWaiters[key] = c
            
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await Task.sleep(for: .seconds(timeoutSeconds))
                } catch {
                    return
                }
                // Timeout: if still pending, resume with error.
                if let pending = self.fileTransferWaiters.removeValue(forKey: key) {
                    pending.resume(throwing: FileTransferWaitError.timeout)
                }
            }
        }
    }
}

@available(iOS 17.0, *)
private extension CrossNetworkWebRTCManager {
    func fileTransferWaiterKey(transferId: String, op: CrossNetworkFileTransferOp, chunkIndex: Int?) -> String {
        let idx = chunkIndex ?? -1
        return "\(transferId)|\(op.rawValue)|\(idx)"
    }
    
    func handleInboundFileTransferWire(_ msg: CrossNetworkFileTransferMessage) {
        // Resume any waiter matching (transferId, op, chunkIndex).
        let key = fileTransferWaiterKey(transferId: msg.transferId, op: msg.op, chunkIndex: msg.chunkIndex)
        if let waiter = fileTransferWaiters.removeValue(forKey: key) {
            waiter.resume(returning: msg)
            return
        }
        
        // Also allow acks without chunkIndex to be awaited.
        let keyNoIdx = fileTransferWaiterKey(transferId: msg.transferId, op: msg.op, chunkIndex: nil)
        if let waiter = fileTransferWaiters.removeValue(forKey: keyNoIdx) {
            waiter.resume(returning: msg)
            return
        }
    }
    
    func failAllFileTransferWaiters(_ error: Error) {
        let waiters = fileTransferWaiters
        fileTransferWaiters.removeAll()
        for (_, c) in waiters {
            c.resume(throwing: error)
        }
    }

    func failFileTransferWaiters(transferId: String, message: String) {
        let keys = fileTransferWaiters.keys.filter { $0.hasPrefix("\(transferId)|") }
        for key in keys {
            if let waiter = fileTransferWaiters.removeValue(forKey: key) {
                waiter.resume(throwing: FileTransferError.transferFailed(message))
            }
        }
    }
    
    // MARK: - Inbound file transfer (macOS -> iOS)
    
    func downloadsDirectoryURL() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    
    func sanitizeFileName(_ name: String) -> String {
        let last = (name as NSString).lastPathComponent
        let trimmed = last.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "SkyBridgeFile" : trimmed
    }
    
    func makeUniqueDestinationURL(baseDir: URL, fileName: String) -> URL {
        let safe = sanitizeFileName(fileName)
        let ext = (safe as NSString).pathExtension
        let stem = (safe as NSString).deletingPathExtension
        
        var candidate = baseDir.appendingPathComponent(safe)
        var idx = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let altName: String
            if ext.isEmpty {
                altName = "\(stem) (\(idx))"
            } else {
                altName = "\(stem) (\(idx)).\(ext)"
            }
            candidate = baseDir.appendingPathComponent(altName)
            idx += 1
        }
        return candidate
    }

    private func expectedInboundChunkCount(fileSize: Int64, chunkSize: Int) -> Int? {
        guard chunkSize > 0 else { return nil }
        if fileSize == 0 { return 0 }
        let total = (fileSize + Int64(chunkSize) - 1) / Int64(chunkSize)
        guard total >= 0, total <= Int64(Int.max) else { return nil }
        return Int(total)
    }

    private func validateInboundMetadata(fileName: String, fileSize: Int64, chunkSize: Int, totalChunks: Int) -> String? {
        guard !fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Invalid metadata (empty fileName)"
        }
        guard fileSize >= 0 else {
            return "Invalid metadata (negative fileSize)"
        }
        let maxInboundChunkSize = 512 * 1024
        guard chunkSize > 0, chunkSize <= maxInboundChunkSize else {
            return "Invalid metadata (chunkSize out of range)"
        }
        guard totalChunks >= 0 else {
            return "Invalid metadata (negative totalChunks)"
        }
        guard let expectedTotalChunks = expectedInboundChunkCount(fileSize: fileSize, chunkSize: chunkSize),
              expectedTotalChunks == totalChunks else {
            return "Invalid metadata (fileSize/chunkSize/totalChunks mismatch)"
        }
        return nil
    }

    private func expectedInboundChunkSize(state: InboundFileTransferState, index: Int) -> Int? {
        guard index >= 0, index < state.totalChunks else { return nil }
        let offset = Int64(index) * Int64(state.chunkSize)
        guard offset >= 0, offset <= state.fileSize else { return nil }
        let remaining = state.fileSize - offset
        guard remaining >= 0 else { return nil }
        return Int(min(Int64(state.chunkSize), remaining))
    }

    private func hasRequiredIntegrityProof(_ state: InboundFileTransferState) -> Bool {
        if state.expectedFileSha256 != nil {
            return true
        }
        return state.expectedMerkleRoot != nil
            && state.expectedMerkleSig != nil
            && state.expectedMerkleSigAlg == CrossNetworkMerkleAuthCompat.signatureAlgV1
    }
    
    func handleInboundFileTransferFromMac(_ msg: CrossNetworkFileTransferMessage) async {
	        guard let keys = sessionKeys else { return }

	        func sha256File(_ url: URL) -> Data? {
	            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
	            defer { try? handle.close() }
	            var hasher = SHA256()
	            while true {
                let chunk = handle.readData(ofLength: 256 * 1024)
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
            }
            return Data(hasher.finalize())
        }
        
        func sendAck(_ ack: CrossNetworkFileTransferMessage, label: String) async {
            do {
                try await sendFileTransferMessage(ack)
            } catch {
                // Best-effort; ignore.
                _ = label
                _ = keys
            }
        }
        
        switch msg.op {
        case .metadata:
            // Idempotent: allow re-sending metadata for the same transferId (resume).
            if inboundFileTransfers[msg.transferId] != nil {
                await sendAck(.init(op: .metadataAck, transferId: msg.transferId), label: "metaAck")
                return
            }

            guard
                let fileName = msg.fileName,
                let fileSize = msg.fileSize,
                let chunkSize = msg.chunkSize,
                let totalChunks = msg.totalChunks
            else {
                await sendAck(.init(op: .error, transferId: msg.transferId, message: "Invalid metadata"), label: "metaError")
                return
            }
            if let validationError = validateInboundMetadata(
                fileName: fileName,
                fileSize: fileSize,
                chunkSize: chunkSize,
                totalChunks: totalChunks
            ) {
                await sendAck(.init(op: .error, transferId: msg.transferId, message: validationError), label: "metaError")
                return
            }
            
            // Prepare paths
            let baseDir = downloadsDirectoryURL()
            let finalURL = makeUniqueDestinationURL(baseDir: baseDir, fileName: fileName)
            let tempURL = baseDir.appendingPathComponent(".skybridge-\(msg.transferId).partial")
            _ = FileManager.default.createFile(atPath: tempURL.path, contents: nil)
            
            do {
                let handle = try FileHandle(forWritingTo: tempURL)
                let senderId = msg.senderDeviceId ?? (remoteDeviceId ?? "mac")
                let senderName = msg.senderDeviceName ?? (remoteDeviceName ?? "macOS")
                
                inboundFileTransfers[msg.transferId] = InboundFileTransferState(
                    transferId: msg.transferId,
                    fileName: fileName,
                    fileSize: fileSize,
                    chunkSize: chunkSize,
                    totalChunks: totalChunks,
                    senderDeviceId: senderId,
                    senderDeviceName: senderName,
                    tempURL: tempURL,
                    finalURL: finalURL,
                    handle: handle,
                    receivedBytes: 0
                )
                
                // UI record
                FileTransferManager.instance.beginExternalInboundTransfer(
                    transferId: msg.transferId,
                    fileName: fileName,
                    fileSize: fileSize,
                    fromPeerName: senderName,
                    destinationURL: finalURL
                )
                
                await sendAck(.init(op: .metadataAck, transferId: msg.transferId), label: "metaAck")
            } catch {
                await sendAck(.init(op: .error, transferId: msg.transferId, message: "Open temp file failed"), label: "metaError")
            }
            
        case .chunk:
            guard let idx = msg.chunkIndex, let data = msg.chunkData else { return }
            guard var st = inboundFileTransfers[msg.transferId] else {
                await sendAck(.init(op: .error, transferId: msg.transferId, message: "Unknown transferId"), label: "chunkError")
                return
            }
            
            do {
                let actualHash = CrossNetworkCryptoCompat.sha256(data)
                if let expected = msg.chunkSha256, actualHash != expected {
                    // Backward compatible: only enforce if hash provided.
                    // Don't ACK corrupted chunk; sender will timeout/retry as appropriate.
                    await sendAck(.init(op: .error, transferId: msg.transferId, chunkIndex: idx, message: "chunk hash mismatch"), label: "chunkHashMismatch")
                    return
                }

                let rawSize = msg.rawSize ?? data.count
                guard idx >= 0, idx < st.totalChunks else {
                    await sendAck(.init(op: .error, transferId: msg.transferId, chunkIndex: idx, message: "chunk index out of range"), label: "chunkError")
                    return
                }
                guard rawSize >= 0, rawSize == data.count, rawSize <= st.chunkSize else {
                    await sendAck(.init(op: .error, transferId: msg.transferId, chunkIndex: idx, message: "invalid chunk size"), label: "chunkError")
                    return
                }
                guard let expectedChunkSize = expectedInboundChunkSize(state: st, index: idx),
                      expectedChunkSize == rawSize else {
                    await sendAck(.init(op: .error, transferId: msg.transferId, chunkIndex: idx, message: "chunk length does not match metadata"), label: "chunkError")
                    return
                }

                if let existingHash = st.chunkHashes[idx] {
                    guard existingHash == actualHash, st.receivedChunkSizes[idx] == rawSize else {
                        await sendAck(.init(op: .error, transferId: msg.transferId, chunkIndex: idx, message: "duplicate chunk content mismatch"), label: "chunkError")
                        return
                    }
                } else {
                    let offset = Int64(idx) * Int64(st.chunkSize)
                    guard offset >= 0, offset + Int64(rawSize) <= st.fileSize else {
                        await sendAck(.init(op: .error, transferId: msg.transferId, chunkIndex: idx, message: "chunk exceeds declared file size"), label: "chunkError")
                        return
                    }
                    try st.handle.seek(toOffset: UInt64(offset))
                    try st.handle.write(contentsOf: data)
                    st.chunkHashes[idx] = actualHash
                    st.receivedChunkSizes[idx] = rawSize
                    st.receivedBytes += Int64(rawSize)
                }
                inboundFileTransfers[msg.transferId] = st
                
                FileTransferManager.instance.updateExternalInboundProgress(
                    transferId: st.transferId,
                    transferredBytes: st.receivedBytes,
                    totalBytes: st.fileSize
                )
                
                // If complete was already requested earlier, finalize once we have enough.
                if st.completeRequestedAt != nil && st.receivedBytes >= st.fileSize {
                    do { try st.handle.close() } catch {}
                    do {
                        if let expectedMerkle = st.expectedMerkleRoot {
                            let leaves: [Data] = (0..<st.totalChunks).compactMap { st.chunkHashes[$0] }
                            if leaves.count != st.totalChunks || CrossNetworkMerkleCompat.root(leaves: leaves) != expectedMerkle {
                                FileTransferManager.instance.completeExternalInboundTransfer(
                                    transferId: st.transferId,
                                    success: false,
                                    error: "merkle root mismatch"
                                )
                                try? FileManager.default.removeItem(at: st.tempURL)
                                inboundFileTransfers.removeValue(forKey: st.transferId)
                                inboundFileTransferCompleteTimers[st.transferId]?.cancel()
                                inboundFileTransferCompleteTimers.removeValue(forKey: st.transferId)
                                await sendAck(.init(op: .error, transferId: st.transferId, message: "merkle root mismatch"), label: "completeError")
                                return
                            }

                            if let sig = st.expectedMerkleSig {
                                if st.expectedMerkleSigAlg != CrossNetworkMerkleAuthCompat.signatureAlgV1 {
                                    FileTransferManager.instance.completeExternalInboundTransfer(
                                        transferId: st.transferId,
                                        success: false,
                                        error: "unknown merkle sig alg"
                                    )
                                    try? FileManager.default.removeItem(at: st.tempURL)
                                    inboundFileTransfers.removeValue(forKey: st.transferId)
                                    inboundFileTransferCompleteTimers[st.transferId]?.cancel()
                                    inboundFileTransferCompleteTimers.removeValue(forKey: st.transferId)
                                    await sendAck(.init(op: .error, transferId: st.transferId, message: "unknown merkle sig alg"), label: "completeError")
                                    return
                                }
                                let pre = CrossNetworkMerkleAuthCompat.preimage(
                                    transferId: st.transferId,
                                    merkleRoot: expectedMerkle,
                                    fileSha256: st.expectedFileSha256
                                )
                                let expectSig = CrossNetworkMerkleAuthCompat.hmacSha256(key: keys.receiveKey, data: pre)
                                if sig != expectSig {
                                    FileTransferManager.instance.completeExternalInboundTransfer(
                                        transferId: st.transferId,
                                        success: false,
                                        error: "merkle signature mismatch"
                                    )
                                    try? FileManager.default.removeItem(at: st.tempURL)
                                    inboundFileTransfers.removeValue(forKey: st.transferId)
                                    inboundFileTransferCompleteTimers[st.transferId]?.cancel()
                                    inboundFileTransferCompleteTimers.removeValue(forKey: st.transferId)
                                    await sendAck(.init(op: .error, transferId: st.transferId, message: "merkle signature mismatch"), label: "completeError")
                                    return
                                }
                            }
                        }

                        if let expected = st.expectedFileSha256, let actual = sha256File(st.tempURL), actual != expected {
                            FileTransferManager.instance.completeExternalInboundTransfer(
                                transferId: st.transferId,
                                success: false,
                                error: "file sha256 mismatch"
                            )
                            try? FileManager.default.removeItem(at: st.tempURL)
                            inboundFileTransfers.removeValue(forKey: st.transferId)
                            inboundFileTransferCompleteTimers[st.transferId]?.cancel()
                            inboundFileTransferCompleteTimers.removeValue(forKey: st.transferId)
                            await sendAck(.init(op: .error, transferId: st.transferId, message: "file sha256 mismatch"), label: "completeError")
                            return
                        }
                        if FileManager.default.fileExists(atPath: st.finalURL.path) {
                            try? FileManager.default.removeItem(at: st.finalURL)
                        }
                        try FileManager.default.moveItem(at: st.tempURL, to: st.finalURL)
                        FileTransferManager.instance.completeExternalInboundTransfer(
                            transferId: st.transferId,
                            success: true,
                            destinationURL: st.finalURL
                        )
                        inboundFileTransfers.removeValue(forKey: st.transferId)
                        inboundFileTransferCompleteTimers[st.transferId]?.cancel()
                        inboundFileTransferCompleteTimers.removeValue(forKey: st.transferId)
                        await sendAck(.init(op: .completeAck, transferId: st.transferId), label: "completeAck")
                        return
                    } catch {
                        FileTransferManager.instance.completeExternalInboundTransfer(
                            transferId: st.transferId,
                            success: false,
                            error: "Save failed"
                        )
                        try? FileManager.default.removeItem(at: st.tempURL)
                        inboundFileTransfers.removeValue(forKey: st.transferId)
                        inboundFileTransferCompleteTimers[st.transferId]?.cancel()
                        inboundFileTransferCompleteTimers.removeValue(forKey: st.transferId)
                        await sendAck(.init(op: .error, transferId: st.transferId, message: "Save failed"), label: "completeError")
                        return
                    }
                }
                
                await sendAck(
                    .init(op: .chunkAck, transferId: st.transferId, chunkIndex: idx, receivedBytes: st.receivedBytes),
                    label: "chunkAck"
                )
            } catch {
                FileTransferManager.instance.completeExternalInboundTransfer(
                    transferId: msg.transferId,
                    success: false,
                    error: error.localizedDescription
                )
                try? st.handle.close()
                try? FileManager.default.removeItem(at: st.tempURL)
                inboundFileTransfers.removeValue(forKey: msg.transferId)
                await sendAck(.init(op: .error, transferId: msg.transferId, message: "Write failed"), label: "chunkError")
            }
            
        case .complete:
            guard var st = inboundFileTransfers[msg.transferId] else { return }

            // Capture expected full-file hash (optional, backward compatible).
            if st.expectedFileSha256 == nil { st.expectedFileSha256 = msg.fileSha256 }
            if st.expectedMerkleRoot == nil { st.expectedMerkleRoot = msg.merkleRoot }
            if st.expectedMerkleSig == nil { st.expectedMerkleSig = msg.merkleRootSignature }
            if st.expectedMerkleSigAlg == nil { st.expectedMerkleSigAlg = msg.merkleRootSignatureAlg }
            guard hasRequiredIntegrityProof(st) else {
                try? st.handle.close()
                try? FileManager.default.removeItem(at: st.tempURL)
                inboundFileTransfers.removeValue(forKey: st.transferId)
                inboundFileTransferCompleteTimers[st.transferId]?.cancel()
                inboundFileTransferCompleteTimers.removeValue(forKey: st.transferId)
                FileTransferManager.instance.completeExternalInboundTransfer(
                    transferId: st.transferId,
                    success: false,
                    error: "missing integrity proof"
                )
                await sendAck(.init(op: .error, transferId: st.transferId, message: "missing integrity proof"), label: "completeError")
                return
            }
            
            if st.receivedBytes < st.fileSize {
                // Optional NACK: request missing chunks (backward compatible).
                let missing = (0..<st.totalChunks).filter { st.chunkHashes[$0] == nil }
                if !missing.isEmpty {
                    await sendAck(.init(op: .chunkAck, transferId: st.transferId, missingChunks: Array(missing.prefix(512)), message: "missingChunks"), label: "missingChunks")
                }

                // Don't fail immediately; mark complete requested and wait for retransmits.
                if st.completeRequestedAt == nil { st.completeRequestedAt = Date() }
                inboundFileTransfers[st.transferId] = st
                
                if inboundFileTransferCompleteTimers[st.transferId] == nil {
                    inboundFileTransferCompleteTimers[st.transferId] = Task { [weak self] in
                        try? await Task.sleep(for: .seconds(10))
                        guard let self else { return }
                        if let cur = self.inboundFileTransfers[st.transferId], cur.receivedBytes < cur.fileSize {
                            do { try cur.handle.close() } catch {}
                            try? FileManager.default.removeItem(at: cur.tempURL)
                            self.inboundFileTransfers.removeValue(forKey: cur.transferId)
                            self.inboundFileTransferCompleteTimers[cur.transferId]?.cancel()
                            self.inboundFileTransferCompleteTimers.removeValue(forKey: cur.transferId)
                            FileTransferManager.instance.completeExternalInboundTransfer(
                                transferId: cur.transferId,
                                success: false,
                                error: "Incomplete file (timeout)"
                            )
                        }
                    }
                }
                return
            }
            
            do { try st.handle.close() } catch {}
            
            do {
                if let expectedMerkle = st.expectedMerkleRoot {
                    let leaves: [Data] = (0..<st.totalChunks).compactMap { st.chunkHashes[$0] }
                    if leaves.count != st.totalChunks || CrossNetworkMerkleCompat.root(leaves: leaves) != expectedMerkle {
                        FileTransferManager.instance.completeExternalInboundTransfer(
                            transferId: st.transferId,
                            success: false,
                            error: "merkle root mismatch"
                        )
                        try? FileManager.default.removeItem(at: st.tempURL)
                        inboundFileTransfers.removeValue(forKey: st.transferId)
                        inboundFileTransferCompleteTimers[st.transferId]?.cancel()
                        inboundFileTransferCompleteTimers.removeValue(forKey: st.transferId)
                        await sendAck(.init(op: .error, transferId: st.transferId, message: "merkle root mismatch"), label: "completeError")
                        return
                    }

                    if let sig = st.expectedMerkleSig {
                        if st.expectedMerkleSigAlg != CrossNetworkMerkleAuthCompat.signatureAlgV1 {
                            FileTransferManager.instance.completeExternalInboundTransfer(
                                transferId: st.transferId,
                                success: false,
                                error: "unknown merkle sig alg"
                            )
                            try? FileManager.default.removeItem(at: st.tempURL)
                            inboundFileTransfers.removeValue(forKey: st.transferId)
                            inboundFileTransferCompleteTimers[st.transferId]?.cancel()
                            inboundFileTransferCompleteTimers.removeValue(forKey: st.transferId)
                            await sendAck(.init(op: .error, transferId: st.transferId, message: "unknown merkle sig alg"), label: "completeError")
                            return
                        }
                        let pre = CrossNetworkMerkleAuthCompat.preimage(
                            transferId: st.transferId,
                            merkleRoot: expectedMerkle,
                            fileSha256: st.expectedFileSha256
                        )
                        let expectSig = CrossNetworkMerkleAuthCompat.hmacSha256(key: keys.receiveKey, data: pre)
                        if sig != expectSig {
                            FileTransferManager.instance.completeExternalInboundTransfer(
                                transferId: st.transferId,
                                success: false,
                                error: "merkle signature mismatch"
                            )
                            try? FileManager.default.removeItem(at: st.tempURL)
                            inboundFileTransfers.removeValue(forKey: st.transferId)
                            inboundFileTransferCompleteTimers[st.transferId]?.cancel()
                            inboundFileTransferCompleteTimers.removeValue(forKey: st.transferId)
                            await sendAck(.init(op: .error, transferId: st.transferId, message: "merkle signature mismatch"), label: "completeError")
                            return
                        }
                    }
                }

                if let expected = st.expectedFileSha256, let actual = sha256File(st.tempURL), actual != expected {
                    FileTransferManager.instance.completeExternalInboundTransfer(
                        transferId: st.transferId,
                        success: false,
                        error: "file sha256 mismatch"
                    )
                    try? FileManager.default.removeItem(at: st.tempURL)
                    inboundFileTransfers.removeValue(forKey: st.transferId)
                    inboundFileTransferCompleteTimers[st.transferId]?.cancel()
                    inboundFileTransferCompleteTimers.removeValue(forKey: st.transferId)
                    await sendAck(.init(op: .error, transferId: st.transferId, message: "file sha256 mismatch"), label: "completeError")
                    return
                }
                if FileManager.default.fileExists(atPath: st.finalURL.path) {
                    try? FileManager.default.removeItem(at: st.finalURL)
                }
                try FileManager.default.moveItem(at: st.tempURL, to: st.finalURL)
                
                FileTransferManager.instance.completeExternalInboundTransfer(
                    transferId: st.transferId,
                    success: true,
                    destinationURL: st.finalURL
                )
                inboundFileTransfers.removeValue(forKey: st.transferId)
                inboundFileTransferCompleteTimers[st.transferId]?.cancel()
                inboundFileTransferCompleteTimers.removeValue(forKey: st.transferId)
                
                await sendAck(.init(op: .completeAck, transferId: st.transferId), label: "completeAck")
            } catch {
                FileTransferManager.instance.completeExternalInboundTransfer(
                    transferId: st.transferId,
                    success: false,
                    error: "Save failed"
                )
                try? FileManager.default.removeItem(at: st.tempURL)
                inboundFileTransfers.removeValue(forKey: st.transferId)
                inboundFileTransferCompleteTimers[st.transferId]?.cancel()
                inboundFileTransferCompleteTimers.removeValue(forKey: st.transferId)
                await sendAck(.init(op: .error, transferId: st.transferId, message: "Save failed"), label: "completeError")
            }
            
        case .cancel:
            if let st = inboundFileTransfers[msg.transferId] {
                try? st.handle.close()
                try? FileManager.default.removeItem(at: st.tempURL)
                inboundFileTransfers.removeValue(forKey: msg.transferId)
                FileTransferManager.instance.completeExternalInboundTransfer(
                    transferId: msg.transferId,
                    success: false,
                    error: msg.message ?? "Cancelled"
                )
            }
            
        case .metadataAck, .chunkAck, .completeAck:
            // These are acks for iOS->macOS sending.
            handleInboundFileTransferWire(msg)
            
        case .error:
            // Fail any pending iOS->macOS sender waits for this transfer immediately.
            failFileTransferWaiters(
                transferId: msg.transferId,
                message: msg.message ?? "remote error"
            )
        }
    }
}

// MARK: - WebRTC framed handshake (iOS)

@available(iOS 17.0, *)
private actor InboundChunkQueue {
    private var pending: [Data] = []
    private var waiters: [CheckedContinuation<Data, Error>] = []
    private var finished = false
    
    enum QueueError: Error {
        case finished
        case invalidReadLimit
    }
    
    func push(_ data: Data) {
        guard !finished else { return }
        if let w = waiters.first {
            waiters.removeFirst()
            w.resume(returning: data)
            return
        }
        pending.append(data)
    }
    
    func finish() {
        finished = true
        let ws = waiters
        waiters.removeAll()
        ws.forEach { $0.resume(throwing: QueueError.finished) }
    }
    
    func next() async throws -> Data {
        if let first = pending.first {
            pending.removeFirst()
            return first
        }
        if finished { throw QueueError.finished }
        return try await withCheckedThrowingContinuation { c in
            waiters.append(c)
        }
    }

    func next(max: Int) async throws -> Data {
        guard max > 0 else {
            throw QueueError.invalidReadLimit
        }
        let chunk = try await next()
        if chunk.count <= max {
            return chunk
        }
        let head = Data(chunk.prefix(max))
        let tail = Data(chunk.dropFirst(max))
        pending.insert(tail, at: 0)
        return head
    }
}

@available(iOS 17.0, *)
private extension CrossNetworkWebRTCManager {
    func startHandshakeOverWebRTC(
        sessionId: String,
        peerDeviceId: String,
        session: WebRTCSession,
        inbound: InboundChunkQueue
    ) async {
        do {
            let compatibilityModeEnabled = UserDefaults.standard.bool(forKey: "Settings.EnableCompatibilityMode")
            let strictPQCRequested = shouldRequestStrictPQC(compatibilityModeEnabled: compatibilityModeEnabled)
            strictPQCRequestedBySessionId[sessionId] = strictPQCRequested
            let capability = CryptoProviderFactory.detectCapability()
            var peerIdCandidates: [String] = []
            for raw in [
                currentPathExpectedRemoteAuthorityBySessionId[sessionId]?.deviceId,
                peerDeviceId,
                remoteDeviceId,
                handshakePeerId
            ] {
                guard let id = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { continue }
                if !peerIdCandidates.contains(id) {
                    peerIdCandidates.append(id)
                }
            }
            if peerIdCandidates.isEmpty {
                peerIdCandidates = [peerDeviceId]
            }

            var trustedPeerKEMKeys: [CryptoSuite: Data] = [:]
            var trustLookupPeerId = peerDeviceId
            for candidate in peerIdCandidates {
                let keys = await KEMTrustStore.shared.kemPublicKeys(for: candidate)
                guard !keys.isEmpty else { continue }
                trustedPeerKEMKeys = keys
                trustLookupPeerId = candidate
                break
            }
            let hasTrustedPeerKEMKey = !trustedPeerKEMKeys.isEmpty
            let selection: CryptoProviderFactory.SelectionPolicy
            if !hasTrustedPeerKEMKey {
                selection = .classicOnly
                if strictPQCRequested {
                    SkyBridgeLogger.shared.warning(
                        "⚠️ WebRTC strictPQC requested but peer KEM trust key missing; " +
                        "fallback to classic bootstrap. peer=\(peerDeviceId)"
                    )
                }
            } else if strictPQCRequested {
                if capability.hasApplePQC || capability.hasLiboqs {
                    selection = .requirePQC
                } else {
                    selection = .preferPQC
                    SkyBridgeLogger.shared.warning(
                        "⚠️ WebRTC strictPQC requested but local PQC provider unavailable; fallback to preferPQC. " +
                        "hasApplePQC=\(capability.hasApplePQC), hasLiboqs=\(capability.hasLiboqs)"
                    )
                }
            } else {
                selection = .preferPQC
            }
            SkyBridgeLogger.shared.info(
                "🤝 WebRTC handshake bootstrap: session=\(sessionId), policy=\(selection.rawValue), " +
                "compatMode=\(compatibilityModeEnabled), hasApplePQC=\(capability.hasApplePQC), hasLiboqs=\(capability.hasLiboqs), " +
                "peer=\(peerDeviceId), trustedKEM=\(hasTrustedPeerKEMKey), trustPeer=\(trustLookupPeerId)"
            )
            let transport = makeHandshakeTransport(over: session)
            let peer = PeerIdentifier(deviceId: peerDeviceId)
            let currentPathTrustProvider = CurrentPathHandshakeTrustProviderCompat(
                expectedRemoteAuthority: currentPathExpectedRemoteAuthorityBySessionId[sessionId],
                fallbackPeerIDs: peerIdCandidates
            )

            // Start a single long-lived receive loop (handshake + post-handshake remote desktop).
            receiveTask?.cancel()
            receiveTask = Task {
                await self.receiveLoop(
                    sessionId: sessionId,
                    session: session,
                    inbound: inbound,
                    peer: peer,
                    strictPQCRequested: strictPQCRequested
                )
            }

            func attemptInitialHandshake(
                selection: CryptoProviderFactory.SelectionPolicy,
                bootstrapMode: String
            ) async throws -> SessionKeys {
                try await SkyBridgeiOSCore.shared.initialize(policy: selection)
                let driver = try SkyBridgeiOSCore.shared.createHandshakeDriver(
                    transport: transport,
                    trustProvider: selection == .classicOnly ? currentPathTrustProvider : nil
                )
                self.handshakeDriver = driver
                SkyBridgeLogger.shared.info(
                    "🤝 WebRTC initiating handshake: session=\(sessionId), peer=\(peerDeviceId), mode=\(bootstrapMode), policy=\(selection.rawValue)"
                )
                return try await driver.initiateHandshake(with: peer)
            }

            let keys: SessionKeys
            do {
                keys = try await attemptInitialHandshake(
                    selection: selection,
                    bootstrapMode: hasTrustedPeerKEMKey ? "trusted_kem" : "classic_bootstrap"
                )
            } catch {
                self.handshakeDriver = nil
                if hasTrustedPeerKEMKey,
                   selection != .classicOnly,
                   Self.shouldRetryClassicBootstrap(after: error) {
                    for candidate in peerIdCandidates {
                        await KEMTrustStore.shared.clear(deviceId: candidate)
                    }
                    self.appendSmokeTrace("bootstrap retry classic peer=\(peerDeviceId)")
                    SkyBridgeLogger.shared.warning(
                        "⚠️ WebRTC trusted KEM bootstrap failed; cleared cached peer KEM keys and retrying classic bootstrap. " +
                        "session=\(sessionId), peer=\(peerDeviceId), error=\(Self.describeHandshakeError(error))"
                    )
                    keys = try await attemptInitialHandshake(
                        selection: .classicOnly,
                        bootstrapMode: "classic_retry_after_stale_kem"
                    )
                } else {
                    throw error
                }
            }

            guard self.currentSessionId == sessionId, self.session === session else {
                self.appendSmokeTrace("drop stale handshake-complete session=\(sessionId)")
                return
            }

            self.sessionKeys = keys
            self.handshakeDriver = nil
            if self.currentSessionId == sessionId {
                // Paper-aligned contract:
                // WebRTC DataChannel ready is only transportReady; connected must wait for handshakeComplete.
                self.state = .connected(sessionId: sessionId)
                self.readiness = .handshakeComplete(
                    sessionId: sessionId,
                    negotiatedSuite: keys.negotiatedSuite.rawValue
                )
                self.noteRemoteAppActivity(sessionId: sessionId)
                self.startRemotePeerPingLoop(sessionId: sessionId, session: session)
                self.startRemotePeerLivenessWatchdog(sessionId: sessionId, session: session)
                self.updatePreparedSessionSnapshot(
                    sessionId: sessionId,
                    phase: .handshakeComplete,
                    deviceId: self.remoteDeviceId,
                    deviceName: self.remoteDeviceName,
                    negotiatedSuite: keys.negotiatedSuite.rawValue
                )
                if self.shouldAutoStartRemoteDesktopHeartbeat() {
                    self.startRemoteDesktopHeartbeat()
                }
            }
            self.persistCurrentPathTrust(sessionId: sessionId)
            SkyBridgeLogger.shared.info(
                "✅ WebRTC 握手完成（DataChannel） session=\(sessionId) suite=\(keys.negotiatedSuite.rawValue)"
            )

            do {
                try await sendPairingIdentityExchangeOverWebRTC(
                    sessionId: sessionId,
                    peerDeviceId: peerDeviceId,
                    session: session,
                    force: true
                )
            } catch {
                SkyBridgeLogger.shared.warning(
                    "⚠️ WebRTC pairingIdentityExchange send failed: session=\(sessionId) peer=\(peerDeviceId) err=\(error.localizedDescription)"
                )
            }

            await maybeStartPQCRekeyOverWebRTC(
                sessionId: sessionId,
                peerDeviceId: peerDeviceId,
                session: session,
                strictPQCRequested: strictPQCRequested,
                trigger: "post_bootstrap"
            )
        } catch {
            let reason: String
            if let hs = error as? HandshakeError {
                switch hs {
                case .alreadyInProgress:
                    reason = "alreadyInProgress"
                case .noSigningCapability:
                    reason = "noSigningCapability"
                case .failed(let failure):
                    reason = String(describing: failure)
                case .emptyOfferedSuites:
                    reason = "emptyOfferedSuites"
                case .homogeneityViolation(let message):
                    reason = "homogeneityViolation(\(message))"
                case .providerAlgorithmMismatch(let provider, let algorithm):
                    reason = "providerAlgorithmMismatch(provider=\(provider), algorithm=\(algorithm))"
                case .signatureAlgorithmMismatch(let algorithm, let keyHandleType):
                    reason = "signatureAlgorithmMismatch(algorithm=\(algorithm), keyHandle=\(keyHandleType))"
                case .contextZeroized:
                    reason = "contextZeroized"
                }
            } else {
                reason = error.localizedDescription
            }
            SkyBridgeLogger.shared.error("❌ WebRTC 握手失败（DataChannel） session=\(sessionId): \(reason)")
            await MainActor.run {
                self.lastError = "WebRTC 握手失败: \(reason)"
                self.applyActiveSessionDisconnect(sessionId: sessionId, kind: .explicit)
                self.state = .failed(self.lastError ?? "WebRTC handshake failed")
                self.readiness = .idle
                self.handshakeDriver = nil
                self.sessionKeys = nil
                self.handshakeStartedSessionIds.remove(sessionId)
                self.rekeyInProgressSessionIds.remove(sessionId)
                self.rekeyCompletedSessionIds.remove(sessionId)
                self.strictPQCRequestedBySessionId.removeValue(forKey: sessionId)
            }
        }
    }

    func shouldRequestStrictPQC(compatibilityModeEnabled: Bool) -> Bool {
        if compatibilityModeEnabled { return false }
        if #available(iOS 26.0, *) { return true }
        return false
    }

    private static func shouldRetryClassicBootstrap(after error: Error) -> Bool {
        if let handshakeError = error as? HandshakeError {
            if case .failed(let reason) = handshakeError,
               case .cryptoError = reason {
                return true
            }
            return false
        }
        return error.localizedDescription.localizedCaseInsensitiveContains("cryptokit")
    }

    private static func describeHandshakeError(_ error: Error) -> String {
        if let hs = error as? HandshakeError {
            switch hs {
            case .alreadyInProgress:
                return "alreadyInProgress"
            case .noSigningCapability:
                return "noSigningCapability"
            case .failed(let failure):
                return String(describing: failure)
            case .emptyOfferedSuites:
                return "emptyOfferedSuites"
            case .homogeneityViolation(let message):
                return "homogeneityViolation(\(message))"
            case .providerAlgorithmMismatch(let provider, let algorithm):
                return "providerAlgorithmMismatch(provider=\(provider), algorithm=\(algorithm))"
            case .signatureAlgorithmMismatch(let algorithm, let keyHandleType):
                return "signatureAlgorithmMismatch(algorithm=\(algorithm), keyHandle=\(keyHandleType))"
            case .contextZeroized:
                return "contextZeroized"
            }
        }
        return error.localizedDescription
    }

    private func resolvedPQCRekeyElectionRemoteDeviceId(
        sessionId: String,
        peerDeviceId: String
    ) -> String? {
        for raw in [
            currentPathExpectedRemoteAuthorityBySessionId[sessionId]?.deviceId,
            remoteDeviceId,
            handshakePeerId,
            peerDeviceId
        ] {
            guard let raw else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.canonicalPQCRekeyElectionDeviceId(trimmed) != nil else { continue }
            return trimmed
        }
        return nil
    }

    private func sendHandshakeFrameOverWebRTC(
        _ data: Data,
        over session: WebRTCSession
    ) async throws {
        let rawHandshake = HandshakePadding.unwrapIfNeeded(data, label: "tx/webrtc")
        let tunedHandshake = HandshakePadding.wrapIfEnabled(
            rawHandshake,
            label: "tx/webrtc",
            maxTotalBytes: currentPathWebRTCHandshakeMaxPaddedPayloadBytes
        )
        if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
            if let messageA = try? HandshakeMessageA.decode(from: rawHandshake) {
                let suites = messageA.supportedSuites.map(\.rawValue).joined(separator: ",")
                appendSmokeTrace("tx messageA suites=\(suites) raw=\(rawHandshake.count)")
                print("🧪 WebRTC rekey tx MessageA raw=\(rawHandshake.count) padded=\(tunedHandshake.count) suites=\(suites)")
            } else if let messageB = try? HandshakeMessageB.decode(from: rawHandshake) {
                appendSmokeTrace("tx messageB suite=\(messageB.selectedSuite.rawValue) raw=\(rawHandshake.count)")
                print("🧪 WebRTC rekey tx MessageB raw=\(rawHandshake.count) padded=\(tunedHandshake.count) suite=\(messageB.selectedSuite.rawValue)")
            } else if (try? HandshakeFinished.decode(from: rawHandshake)) != nil {
                appendSmokeTrace("tx finished raw=\(rawHandshake.count)")
                print("🧪 WebRTC rekey tx Finished raw=\(rawHandshake.count) padded=\(tunedHandshake.count)")
            }
        }
        try await session.sendFramedPayloadAsync(
            tunedHandshake,
            maxChunkBytes: currentPathWebRTCHandshakeMaxChunkBytes,
            maxBufferedAmountBytes: 0
        )
    }

    private func makeHandshakeTransport(
        over session: WebRTCSession
    ) -> CurrentPathWebRTCHandshakeTransportCompat {
        CurrentPathWebRTCHandshakeTransportCompat(
            sendFramed: { [weak self] data in
                guard let self else { return }
                try await self.sendHandshakeFrameOverWebRTC(data, over: session)
            }
        )
    }

    private func ensureInboundPQCRekeyDriverIfNeeded(
        sessionId: String,
        frame: Data,
        peer: PeerIdentifier,
        session: WebRTCSession,
        strictPQCRequested: Bool
    ) async -> HandshakeDriver? {
        guard currentSessionId == sessionId else { return nil }
        if inboundRekeyResponderSessionIds.contains(sessionId) {
            return handshakeDriver
        }
        guard handshakeDriver == nil else { return nil }
        guard sessionKeys != nil else { return nil }
        guard let messageA = try? HandshakeMessageA.decode(from: frame),
              !messageA.supportedSuites.isEmpty else {
            return nil
        }

        let hasPQCGroup = messageA.supportedSuites.contains { $0.isPQCGroup }
        let selection: CryptoProviderFactory.SelectionPolicy = {
            if hasPQCGroup {
                return strictPQCRequested ? .requirePQC : .preferPQC
            }
            return .classicOnly
        }()

        var fallbackPeerIDs: [String] = []
        for raw in [
            peer.deviceId,
            remoteDeviceId,
            handshakePeerId,
            currentPathExpectedRemoteAuthorityBySessionId[sessionId]?.deviceId
        ] {
            guard let raw else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if !fallbackPeerIDs.contains(trimmed) {
                fallbackPeerIDs.append(trimmed)
            }
        }

        do {
            try await SkyBridgeiOSCore.shared.initialize(policy: selection)
            let trustProvider = CurrentPathHandshakeTrustProviderCompat(
                expectedRemoteAuthority: currentPathExpectedRemoteAuthorityBySessionId[sessionId],
                fallbackPeerIDs: fallbackPeerIDs
            )
            let driver = try SkyBridgeiOSCore.shared.createHandshakeDriver(
                transport: makeHandshakeTransport(over: session),
                trustProvider: hasPQCGroup ? nil : trustProvider
            )
            handshakeDriver = driver
        } catch {
            SkyBridgeLogger.shared.warning(
                "⚠️ inbound WebRTC rekey driver 初始化失败: session=\(sessionId), err=\(error.localizedDescription)"
            )
            return nil
        }

        inboundRekeyResponderSessionIds.insert(sessionId)
        rekeyInProgressSessionIds.insert(sessionId)
        lastRekeyEvent = "received peer=\(peer.deviceId)"
        SkyBridgeLogger.shared.info(
            "🔁 收到对端 WebRTC rekey 请求，切换 responder: session=\(sessionId), peer=\(peer.deviceId), suites=\(messageA.supportedSuites.map(\.rawValue).joined(separator: ","))"
        )
        return handshakeDriver
    }

    private func syncInboundPQCRekeyState(sessionId: String) async {
        guard inboundRekeyResponderSessionIds.contains(sessionId),
              let driver = handshakeDriver else {
            return
        }

        let currentState = await driver.getCurrentState()
        switch currentState {
        case .established(let keys):
            sessionKeys = keys
            handshakeDriver = nil
            inboundRekeyResponderSessionIds.remove(sessionId)
            rekeyInProgressSessionIds.remove(sessionId)
            rekeyCompletedSessionIds.insert(sessionId)
            lastRekeyEvent = "complete suite=\(keys.negotiatedSuite.rawValue)"

            if currentSessionId == sessionId {
                state = .connected(sessionId: sessionId)
                readiness = .handshakeComplete(
                    sessionId: sessionId,
                    negotiatedSuite: keys.negotiatedSuite.rawValue
                )
                noteRemoteAppActivity(sessionId: sessionId)
                if let activeSession = self.session {
                    startRemotePeerPingLoop(sessionId: sessionId, session: activeSession)
                }
                if let activeSession = self.session {
                    startRemotePeerLivenessWatchdog(sessionId: sessionId, session: activeSession)
                }
                updatePreparedSessionSnapshot(
                    sessionId: sessionId,
                    phase: .handshakeComplete,
                    deviceId: remoteDeviceId,
                    deviceName: remoteDeviceName,
                    negotiatedSuite: keys.negotiatedSuite.rawValue
                )
                if shouldAutoStartRemoteDesktopHeartbeat() {
                    startRemoteDesktopHeartbeat()
                }
            }
            persistCurrentPathTrust(sessionId: sessionId)
            SkyBridgeLogger.shared.info(
                "✅ inbound WebRTC rekey 完成: session=\(sessionId), suite=\(keys.negotiatedSuite.rawValue)"
            )

        case .failed(let reason):
            handshakeDriver = nil
            inboundRekeyResponderSessionIds.remove(sessionId)
            rekeyInProgressSessionIds.remove(sessionId)
            lastRekeyEvent = "failed reason=\(reason)"
            SkyBridgeLogger.shared.warning(
                "⚠️ inbound WebRTC rekey 失败，保留既有会话: session=\(sessionId), reason=\(reason)"
            )

        default:
            break
        }
    }

    func sendAppMessageOverWebRTC(
        _ message: AppMessage,
        sessionId: String,
        session: WebRTCSession,
        label: String
    ) async throws {
        guard currentSessionId == sessionId else { return }
        guard let keys = sessionKeys else { throw RemoteDesktopError.disconnected }
        let payload = try JSONEncoder().encode(message)
        let ciphertext = try encrypt(plaintext: payload, with: keys)
        let padded = TrafficPadding.wrapIfEnabled(ciphertext, label: label)
        try await sendFramed(padded, over: session)
    }

    func sendPairingIdentityExchangeOverWebRTC(
        sessionId: String,
        peerDeviceId: String,
        session: WebRTCSession,
        force: Bool = false
    ) async throws {
        guard currentSessionId == sessionId else { return }
        if !force,
           let last = lastPairingIdentityExchangeSentAtByPeerId[peerDeviceId],
           Date().timeIntervalSince(last) < 10 {
            return
        }

        let kemKeys = try await P2PKEMIdentityKeyStore.shared.getOrCreateBootstrapPublicKeys()
        guard !kemKeys.isEmpty else { return }

        let message = AppMessage.pairingIdentityExchange(.init(
            deviceId: localDeviceId,
            kemPublicKeys: kemKeys,
            deviceName: nil,
            modelName: nil,
            platform: "iOS",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            chip: nil,
            remoteVideoFormats: RemoteDesktopManager.supportedRemoteVideoFormats()
        ))
        try await sendAppMessageOverWebRTC(
            message,
            sessionId: sessionId,
            session: session,
            label: "tx/webrtc-bootstrap"
        )
        lastPairingIdentityExchangeSentAtByPeerId[peerDeviceId] = Date()
        SkyBridgeLogger.shared.info(
            "📤 WebRTC pairingIdentityExchange sent: session=\(sessionId), peer=\(peerDeviceId), keys=\(kemKeys.count)"
        )
    }

    func handleInboundAppMessageOverWebRTC(
        _ message: AppMessage,
        sessionId: String,
        peerDeviceId: String,
        session: WebRTCSession,
        strictPQCRequested: Bool
    ) async {
        switch message {
        case .pairingIdentityExchange(let payload):
            noteRemoteAppActivity(sessionId: sessionId)
            await KEMTrustStore.shared.upsert(deviceId: payload.deviceId, kemPublicKeys: payload.kemPublicKeys)
            await KEMTrustStore.shared.upsert(deviceId: peerDeviceId, kemPublicKeys: payload.kemPublicKeys)
            if remoteDeviceId == nil || remoteDeviceId?.hasPrefix("webrtc-") == true {
                remoteDeviceId = payload.deviceId
                updatePreparedSessionSnapshot(
                    sessionId: sessionId,
                    phase: .transportReady,
                    deviceId: payload.deviceId,
                    deviceName: remoteDeviceName
                )
            }
            if handshakePeerId == nil || handshakePeerId?.hasPrefix("webrtc-") == true {
                handshakePeerId = payload.deviceId
            }
            SkyBridgeLogger.shared.info(
                "🔑 WebRTC bootstrap KEM cache updated: peer=\(peerDeviceId), declared=\(payload.deviceId), keys=\(payload.kemPublicKeys.count)"
            )

            do {
                try await sendPairingIdentityExchangeOverWebRTC(
                    sessionId: sessionId,
                    peerDeviceId: peerDeviceId,
                    session: session,
                    force: false
                )
            } catch {
                SkyBridgeLogger.shared.debug("ℹ️ pairingIdentityExchange reply failed (ignored): \(error.localizedDescription)")
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.maybeStartPQCRekeyOverWebRTC(
                    sessionId: sessionId,
                    peerDeviceId: peerDeviceId,
                    session: session,
                    strictPQCRequested: strictPQCRequested,
                    trigger: "pairing_exchange"
                )
            }
        case .heartbeat(let payload):
            noteRemoteAppActivity(sessionId: sessionId)
            if let deviceId = payload.deviceId?.trimmingCharacters(in: .whitespacesAndNewlines),
               !deviceId.isEmpty,
               (remoteDeviceId == nil || remoteDeviceId?.hasPrefix("webrtc-") == true) {
                remoteDeviceId = deviceId
            }
            if let deviceName = payload.deviceName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !deviceName.isEmpty,
               (remoteDeviceName == nil || remoteDeviceName?.isEmpty == true) {
                remoteDeviceName = deviceName
            }
            updatePreparedSessionSnapshot(
                sessionId: sessionId,
                phase: {
                    if case .handshakeComplete = readiness {
                        return .handshakeComplete
                    }
                    return .transportReady
                }(),
                deviceId: remoteDeviceId,
                deviceName: remoteDeviceName,
                negotiatedSuite: {
                    if case .handshakeComplete(_, let suite) = readiness {
                        return suite
                    }
                    return nil
                }()
            )
        case .peerDisconnecting:
            noteRemoteAppActivity(sessionId: sessionId)
        case .ping(let payload):
            noteRemoteAppActivity(sessionId: sessionId)
            do {
                try await sendAppMessageOverWebRTC(
                    .pong(.init(id: payload.id)),
                    sessionId: sessionId,
                    session: session,
                    label: "tx/webrtc-pong"
                )
            } catch {
                // Best-effort reply.
            }
        case .pong:
            noteRemoteAppActivity(sessionId: sessionId)
        case .clipboard:
            noteRemoteAppActivity(sessionId: sessionId)
        }
    }

    func maybeStartPQCRekeyOverWebRTC(
        sessionId: String,
        peerDeviceId: String,
        session: WebRTCSession,
        strictPQCRequested: Bool,
        trigger: String
    ) async {
        guard currentSessionId == sessionId else { return }
        guard strictPQCRequested else { return }
        guard let establishedKeys = sessionKeys else { return }
        guard !establishedKeys.negotiatedSuite.isPQCGroup else { return }
        guard !rekeyInProgressSessionIds.contains(sessionId) else { return }
        guard !rekeyCompletedSessionIds.contains(sessionId) else { return }

        guard let electionRemoteDeviceId = resolvedPQCRekeyElectionRemoteDeviceId(
            sessionId: sessionId,
            peerDeviceId: peerDeviceId
        ) else {
            lastRekeyEvent = "waiting peer=unknown election"
            SkyBridgeLogger.shared.info(
                "⏳ WebRTC rekey waiting for concrete remote device id: session=\(sessionId), trigger=\(trigger)"
            )
            return
        }
        guard let shouldInitiate = Self.shouldInitiatePQCRekey(
            localDeviceId: localDeviceId,
            remoteDeviceId: electionRemoteDeviceId
        ) else {
            lastRekeyEvent = "waiting peer=\(electionRemoteDeviceId) election"
            SkyBridgeLogger.shared.info(
                "⏳ WebRTC rekey waiting for stable initiator election: session=\(sessionId), trigger=\(trigger), peer=\(electionRemoteDeviceId)"
            )
            return
        }
        guard shouldInitiate else {
            lastRekeyEvent = "await inbound peer=\(electionRemoteDeviceId)"
            SkyBridgeLogger.shared.info(
                "ℹ️ WebRTC rekey elected peer as initiator; waiting inbound rekey: session=\(sessionId), trigger=\(trigger), peer=\(electionRemoteDeviceId)"
            )
            return
        }

        let capability = CryptoProviderFactory.detectCapability()
        let selection: CryptoProviderFactory.SelectionPolicy
        if capability.hasApplePQC || capability.hasLiboqs {
            selection = .requirePQC
        } else {
            SkyBridgeLogger.shared.warning(
                "⚠️ skip WebRTC rekey: strictPQC requested but local PQC provider unavailable. " +
                "session=\(sessionId), trigger=\(trigger), hasApplePQC=\(capability.hasApplePQC), hasLiboqs=\(capability.hasLiboqs)"
            )
            return
        }

        var candidateIds: [String] = []
        for raw in [
            currentPathExpectedRemoteAuthorityBySessionId[sessionId]?.deviceId,
            peerDeviceId,
            remoteDeviceId,
            handshakePeerId
        ] {
            guard let id = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { continue }
            if !candidateIds.contains(id) {
                candidateIds.append(id)
            }
        }
        if candidateIds.isEmpty { return }

        let provider = CryptoProviderFactory.make(policy: selection)
        let requiredSuites = provider.supportedSuites.filter { $0.isPQCGroup }
        guard !requiredSuites.isEmpty else { return }

        var selectedPeerId = peerDeviceId
        var trustedPeerKEM: [CryptoSuite: Data] = [:]
        for candidate in candidateIds {
            let keys = await KEMTrustStore.shared.kemPublicKeys(for: candidate)
            guard !keys.isEmpty else { continue }
            if trustedPeerKEM.isEmpty {
                selectedPeerId = candidate
                trustedPeerKEM = keys
            }
            let missing = requiredSuites.filter { keys[$0] == nil }
            if missing.isEmpty {
                selectedPeerId = candidate
                trustedPeerKEM = keys
                break
            }
        }

        let missingSuites = requiredSuites.filter { trustedPeerKEM[$0] == nil }
        guard missingSuites.isEmpty else {
            let missing = missingSuites.map(\.rawValue).joined(separator: ",")
            lastRekeyEvent = "waiting peer=\(selectedPeerId) missing=\(missing)"
            SkyBridgeLogger.shared.info(
                "⏳ WebRTC rekey waiting for peer KEM keys: session=\(sessionId), peer=\(selectedPeerId), missing=\(missing)"
            )
            return
        }

        rekeyInProgressSessionIds.insert(sessionId)
        defer {
            rekeyInProgressSessionIds.remove(sessionId)
            handshakeDriver = nil
        }

        do {
            try await SkyBridgeiOSCore.shared.initialize(policy: selection)
            let transport = makeHandshakeTransport(over: session)
            let peer = PeerIdentifier(deviceId: selectedPeerId)
            let driver = try SkyBridgeiOSCore.shared.createHandshakeDriver(transport: transport)
            handshakeDriver = driver

            lastRekeyEvent = "start peer=\(selectedPeerId) policy=\(selection.rawValue)"
            SkyBridgeLogger.shared.info(
                "🔁 WebRTC rekey start: session=\(sessionId), trigger=\(trigger), peer=\(selectedPeerId), policy=\(selection.rawValue)"
            )
            let rekeyed = try await driver.initiateHandshake(with: peer)
            sessionKeys = rekeyed
            rekeyCompletedSessionIds.insert(sessionId)
            lastRekeyEvent = "complete suite=\(rekeyed.negotiatedSuite.rawValue)"

            if currentSessionId == sessionId {
                state = .connected(sessionId: sessionId)
                readiness = .handshakeComplete(
                    sessionId: sessionId,
                    negotiatedSuite: rekeyed.negotiatedSuite.rawValue
                )
                noteRemoteAppActivity(sessionId: sessionId)
                startRemotePeerPingLoop(sessionId: sessionId, session: session)
                startRemotePeerLivenessWatchdog(sessionId: sessionId, session: session)
                updatePreparedSessionSnapshot(
                    sessionId: sessionId,
                    phase: .handshakeComplete,
                    deviceId: remoteDeviceId,
                    deviceName: remoteDeviceName,
                    negotiatedSuite: rekeyed.negotiatedSuite.rawValue
                )
                if shouldAutoStartRemoteDesktopHeartbeat() {
                    startRemoteDesktopHeartbeat()
                }
            }
            persistCurrentPathTrust(sessionId: sessionId)

            SkyBridgeLogger.shared.info(
                "✅ WebRTC rekey complete: session=\(sessionId), suite=\(rekeyed.negotiatedSuite.rawValue)"
            )
        } catch {
            lastRekeyEvent = "failed error=\(error.localizedDescription)"
            SkyBridgeLogger.shared.error(
                "❌ WebRTC rekey failed: session=\(sessionId), trigger=\(trigger), err=\(error.localizedDescription)"
            )
        }
    }
}

@available(iOS 17.0, *)
private extension CrossNetworkWebRTCManager {
    private func compactInboundFrameBuffer(
        _ buffer: inout Data,
        readOffset: inout Int,
        maxInboundFrameBytes: Int
    ) {
        if readOffset >= buffer.count {
            buffer.removeAll(keepingCapacity: true)
            readOffset = 0
            return
        }

        if readOffset > 0, (readOffset >= 4096 || readOffset * 2 >= buffer.count) {
            buffer.removeSubrange(0..<readOffset)
            readOffset = 0
        }

        if buffer.count > maxInboundFrameBytes * 2 {
            buffer.removeAll(keepingCapacity: true)
            readOffset = 0
        }
    }

    private func nextInboundFramePayload(
        from buffer: inout Data,
        readOffset: inout Int,
        maxInboundFrameBytes: Int,
        sessionId: String,
        logLabel: String
    ) -> Data? {
        while buffer.count - readOffset >= 4 {
            let length: Int = buffer.withUnsafeBytes { ptr in
                let b0 = ptr.load(fromByteOffset: readOffset, as: UInt8.self)
                let b1 = ptr.load(fromByteOffset: readOffset + 1, as: UInt8.self)
                let b2 = ptr.load(fromByteOffset: readOffset + 2, as: UInt8.self)
                let b3 = ptr.load(fromByteOffset: readOffset + 3, as: UInt8.self)
                return (Int(b0) << 24) | (Int(b1) << 16) | (Int(b2) << 8) | Int(b3)
            }

            guard length > 0 && length < maxInboundFrameBytes else {
                SkyBridgeLogger.shared.warning(
                    "⚠️ drop invalid \(logLabel) frame length: len=\(length) max=\(maxInboundFrameBytes) session=\(sessionId)"
                )
                readOffset += 1
                compactInboundFrameBuffer(
                    &buffer,
                    readOffset: &readOffset,
                    maxInboundFrameBytes: maxInboundFrameBytes
                )
                continue
            }

            guard buffer.count - readOffset >= 4 + length else {
                compactInboundFrameBuffer(
                    &buffer,
                    readOffset: &readOffset,
                    maxInboundFrameBytes: maxInboundFrameBytes
                )
                return nil
            }

            let start = readOffset + 4
            let end = start + length
            let payload = buffer.subdata(in: start..<end)
            readOffset = end
            compactInboundFrameBuffer(
                &buffer,
                readOffset: &readOffset,
                maxInboundFrameBytes: maxInboundFrameBytes
            )
            return payload
        }

        compactInboundFrameBuffer(
            &buffer,
            readOffset: &readOffset,
            maxInboundFrameBytes: maxInboundFrameBytes
        )
        return nil
    }

    func receiveLoop(
        sessionId: String,
        session: WebRTCSession,
        inbound: InboundChunkQueue,
        peer: PeerIdentifier,
        strictPQCRequested: Bool
    ) async {
        let maxInboundFrameBytes = 8_000_000
        do {
                self.appendSmokeTrace("receiveLoop start session=\(sessionId)")
	            var buffer = Data()
	            var readOffset = 0
            while !Task.isCancelled {
	                // pull chunk
	                let chunk = try await inbound.next()
	                buffer.append(chunk)
	                
	                while let payload = nextInboundFramePayload(
                        from: &buffer,
                        readOffset: &readOffset,
                        maxInboundFrameBytes: maxInboundFrameBytes,
                        sessionId: sessionId,
                        logLabel: "WebRTC"
                    ) {
                        let length = payload.count
	                    let trafficUnwrapped = TrafficPadding.unwrapIfNeeded(payload, label: "rx/webrtc")
                        if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                            print("🧪 WebRTC rekey rx frame len=\(length)")
                        }
                        self.appendSmokeTrace(
                            "rx frame len=\(length) rekey=\(self.rekeyInProgressSessionIds.contains(sessionId)) driver=\(self.handshakeDriver != nil) keys=\(self.sessionKeys != nil)"
                        )
	                    
	                    if let keys = self.sessionKeys {
	                        // Business payload: decrypt and route RemoteDesktop messages.
                        do {
                            let plaintext = try decrypt(ciphertext: trafficUnwrapped, with: keys)

                            if let appMessage = try? JSONDecoder().decode(AppMessage.self, from: plaintext) {
                                await handleInboundAppMessageOverWebRTC(
                                    appMessage,
                                    sessionId: sessionId,
                                    peerDeviceId: peer.deviceId,
                                    session: session,
                                    strictPQCRequested: strictPQCRequested
                                )
                                continue
                            }
                            
                            // Cross-network file transfer (acks/errors or inbound transfers from macOS)
                            if let ft = try? JSONDecoder().decode(CrossNetworkFileTransferMessage.self, from: plaintext),
                               ft.version == 1 {
                                await self.handleInboundFileTransferFromMac(ft)
                                continue
                            }
                            
                            if let screenData = RemoteDesktopScreenFrameWire.decodeIfPresent(plaintext) {
                                await MainActor.run {
                                    self.lastScreenData = screenData
                                    NotificationCenter.default.post(name: Notification.Name("CrossNetworkScreenDataUpdated"), object: nil)
                                }
                            } else if let msg = try? JSONDecoder().decode(RemoteMessage.self, from: plaintext) {
                                if msg.type == .screenData,
                                   let sd = try? JSONDecoder().decode(ScreenData.self, from: msg.payload) {
                                    await MainActor.run {
                                        self.lastScreenData = sd
                                        NotificationCenter.default.post(name: Notification.Name("CrossNetworkScreenDataUpdated"), object: nil)
                                    }
                                } else if msg.type == .damageReport,
                                          let report = try? JSONDecoder().decode(RemoteDesktopDamageReportPayload.self, from: msg.payload) {
                                    await MainActor.run {
                                        RemoteDesktopManager.instance.handleInboundDamageReport(report)
                                    }
                                } else if msg.type == .cursorUpdate,
                                          let payload = try? JSONDecoder().decode(RemoteDesktopCursorPayload.self, from: msg.payload) {
                                    await MainActor.run {
                                        RemoteDesktopManager.instance.handleInboundCursorUpdate(payload)
                                    }
                                } else if msg.type == .overlayUpdate,
                                          let payload = try? JSONDecoder().decode(RemoteDesktopOverlayPayload.self, from: msg.payload) {
                                    await MainActor.run {
                                        RemoteDesktopManager.instance.handleInboundOverlayUpdate(payload)
                                    }
                                } else if msg.type == .clipboard,
                                          let payload = try? JSONDecoder().decode(RemoteClipboardMessagePayload.self, from: msg.payload) {
                                    await MainActor.run {
                                        RemoteDesktopManager.instance.handleInboundRemoteClipboard(
                                            data: payload.data,
                                            mimeType: payload.mimeType,
                                            fromDeviceId: self.remoteDeviceId
                                        )
                                    }
                                }
                            }
                        } catch {
                            // If it isn't decryptable business data, it might still be a handshake control frame; fall through.
                            if let inboundDriver = await self.ensureInboundPQCRekeyDriverIfNeeded(
                                sessionId: sessionId,
                                frame: trafficUnwrapped,
                                peer: peer,
                                session: session,
                                strictPQCRequested: strictPQCRequested
                            ) {
                                if let messageA = try? HandshakeMessageA.decode(from: trafficUnwrapped) {
                                    let suites = messageA.supportedSuites.map(\.rawValue).joined(separator: ",")
                                    self.appendSmokeTrace("rx messageA raw=\(trafficUnwrapped.count) suites=\(suites)")
                                    if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                                        print("🧪 WebRTC rekey rx MessageA raw=\(trafficUnwrapped.count) suites=\(suites)")
                                    }
                                }
                                await inboundDriver.handleMessage(trafficUnwrapped, from: peer)
                                await self.syncInboundPQCRekeyState(sessionId: sessionId)
                                continue
                            }
                            if let driver = self.handshakeDriver {
                                if let messageB = try? HandshakeMessageB.decode(from: trafficUnwrapped) {
                                    self.lastRekeyEvent = "messageB suite=\(messageB.selectedSuite.rawValue)"
                                    self.appendSmokeTrace("rx messageB raw=\(trafficUnwrapped.count) suite=\(messageB.selectedSuite.rawValue)")
                                    if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                                        print("🧪 WebRTC rekey rx MessageB raw=\(trafficUnwrapped.count) suite=\(messageB.selectedSuite.rawValue)")
                                    }
                                } else if (try? HandshakeFinished.decode(from: trafficUnwrapped)) != nil {
                                    self.lastRekeyEvent = "finished"
                                    self.appendSmokeTrace("rx finished raw=\(trafficUnwrapped.count)")
                                    if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                                        print("🧪 WebRTC rekey rx Finished raw=\(trafficUnwrapped.count)")
                                    }
                                }
                                await driver.handleMessage(trafficUnwrapped, from: peer)
                                await self.syncInboundPQCRekeyState(sessionId: sessionId)
                            }
                        }
                    } else {
                        if let driver = self.handshakeDriver {
                            if let messageB = try? HandshakeMessageB.decode(from: trafficUnwrapped) {
                                self.lastRekeyEvent = "messageB suite=\(messageB.selectedSuite.rawValue)"
                                self.appendSmokeTrace("rx messageB raw=\(trafficUnwrapped.count) suite=\(messageB.selectedSuite.rawValue)")
                                if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                                    print("🧪 WebRTC rekey rx MessageB raw=\(trafficUnwrapped.count) suite=\(messageB.selectedSuite.rawValue)")
                                }
                            } else if (try? HandshakeFinished.decode(from: trafficUnwrapped)) != nil {
                                self.lastRekeyEvent = "finished"
                                self.appendSmokeTrace("rx finished raw=\(trafficUnwrapped.count)")
                                if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                                    print("🧪 WebRTC rekey rx Finished raw=\(trafficUnwrapped.count)")
                                }
                            }
                            await driver.handleMessage(trafficUnwrapped, from: peer)
                            await self.syncInboundPQCRekeyState(sessionId: sessionId)
                        }
                    }
                }
            }
        } catch {
            self.appendSmokeTrace("receiveLoop ended error=\(error.localizedDescription)")
        }
    }

    func receiveScreenLoop(
        sessionId: String,
        session: WebRTCSession,
        inbound: InboundChunkQueue
    ) async {
        let maxInboundFrameBytes = 8_000_000
        do {
            self.appendSmokeTrace("screen-receiveLoop start session=\(sessionId)")
            var buffer = Data()
            var readOffset = 0

            while !Task.isCancelled {
                let chunk = try await inbound.next()
                buffer.append(chunk)

                while let payload = nextInboundFramePayload(
                    from: &buffer,
                    readOffset: &readOffset,
                    maxInboundFrameBytes: maxInboundFrameBytes,
                    sessionId: sessionId,
                    logLabel: "screen-channel"
                ) {
                    guard currentSessionId == sessionId,
                          self.session === session,
                          let keys = sessionKeys else {
                        continue
                    }

                    do {
                        let trafficUnwrapped = TrafficPadding.unwrapIfNeeded(payload, label: "rx/webrtc-screen")
                        let plaintext = try decrypt(ciphertext: trafficUnwrapped, with: keys)
                        if let screenData = RemoteDesktopScreenFrameWire.decodeIfPresent(plaintext) {
                            lastScreenData = screenData
                            NotificationCenter.default.post(
                                name: Notification.Name("CrossNetworkScreenDataUpdated"),
                                object: nil
                            )
                        } else if let msg = try? JSONDecoder().decode(RemoteMessage.self, from: plaintext),
                                  msg.type == .screenData,
                                  let sd = try? JSONDecoder().decode(ScreenData.self, from: msg.payload) {
                            lastScreenData = sd
                            NotificationCenter.default.post(
                                name: Notification.Name("CrossNetworkScreenDataUpdated"),
                                object: nil
                            )
                        }
                    } catch {
                        SkyBridgeLogger.shared.debug(
                            "ℹ️ screen-channel payload 解密/解析失败: \(error.localizedDescription)"
                        )
                    }
                }
            }
        } catch {
            self.appendSmokeTrace("screen-receiveLoop ended error=\(error.localizedDescription)")
        }
    }
    
    func sendFramed(_ data: Data, over session: WebRTCSession) async throws {
        try await session.sendFramedPayloadAsync(data)
    }
    
    func encrypt(plaintext: Data, with keys: SessionKeys) throws -> Data {
        let key = SymmetricKey(data: keys.sendKey)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        return sealed.combined ?? Data()
    }
    
    func decrypt(ciphertext: Data, with keys: SessionKeys) throws -> Data {
        let key = SymmetricKey(data: keys.receiveKey)
        let box = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(box, using: key)
    }

    nonisolated func appendSmokeTrace(_ line: String) {
        guard ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil else { return }
        let fileName = ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_STATUS_BASENAME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "skybridge-smoke-status.log"
        guard !fileName.isEmpty,
              let baseCaches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return
        }
        let url = baseCaches.appendingPathComponent("\(fileName).trace.log")
        let formatted = "[\(ISO8601DateFormatter().string(from: Date()))] \(line)\n"
        guard let data = formatted.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
        }
    }

    nonisolated private func describeEnvelope(_ envelope: WebRTCSignalingEnvelope) -> String {
        Self.describeEnvelope(envelope)
    }

    nonisolated private static func describeEnvelope(_ envelope: WebRTCSignalingEnvelope) -> String {
        let payloadSummary: String
        switch envelope.type {
        case .offer, .answer:
            if let sdp = envelope.payload?.sdp {
                payloadSummary = describeSDPCandidates(sdp)
            } else {
                payloadSummary = "sdp=0"
            }
        case .iceCandidate:
            payloadSummary = "kind=\(describeCandidateKind(envelope.payload?.candidate))"
        case .join, .leave:
            payloadSummary = "payload=0"
        }
        return "session=\(envelope.sessionId) type=\(envelope.type.rawValue) from=\(envelope.from) to=\(envelope.to ?? "-") auth=\(envelope.authToken == nil ? 0 : 1) \(payloadSummary)"
    }

    nonisolated private static func describeCandidateKind(_ candidate: String?) -> String {
        guard let candidate = candidate?.lowercased() else { return "unknown" }
        if candidate.contains(" typ relay") { return "relay" }
        if candidate.contains(" typ srflx") { return "srflx" }
        if candidate.contains(" typ prflx") { return "prflx" }
        if candidate.contains(" typ host") { return "host" }
        return "unknown"
    }

    nonisolated private static func describeSDPCandidates(_ sdp: String) -> String {
        var total = 0
        var host = 0
        var srflx = 0
        var relay = 0
        var prflx = 0

        for rawLine in sdp.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("a=candidate:") else { continue }
            total += 1
            let lower = line.lowercased()
            if lower.contains(" typ relay") {
                relay += 1
            } else if lower.contains(" typ srflx") {
                srflx += 1
            } else if lower.contains(" typ prflx") {
                prflx += 1
            } else if lower.contains(" typ host") {
                host += 1
            }
        }

        return "candidates total=\(total) host=\(host) srflx=\(srflx) relay=\(relay) prflx=\(prflx)"
    }
}
