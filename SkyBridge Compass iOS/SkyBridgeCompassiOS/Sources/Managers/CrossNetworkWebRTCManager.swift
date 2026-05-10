import Foundation
import CryptoKit
import OSLog
import SkyBridgeRealtimeMedia
#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif
#if canImport(UIKit)
import UIKit
import UserNotifications
#endif

extension Notification.Name {
    static let crossNetworkScreenDataUpdated = Notification.Name("CrossNetworkScreenDataUpdated")
}

enum CrossNetworkNotificationUserInfoKey {
    static let sessionId = "sessionId"
    static let screenData = "screenData"
}

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
private let currentPathWebRTCHandshakeMaxBufferedAmountBytes: UInt64 = 256 * 1024
private let strictPQCClassicBootstrapTimeoutSeconds: TimeInterval = 30.0
private let strictPQCClassicBootstrapMaxGraceSeconds: TimeInterval = 120.0

@available(iOS 17.0, *)
private struct CurrentPathWebRTCHandshakeTransportCompat: DiscoveryTransport {
    let sendFramed: @Sendable (Data) async throws -> Void

    func send(to peer: PeerIdentifier, data: Data) async throws {
        try await sendFramed(data)
    }
}

@available(iOS 17.0, *)
private enum CrossNetworkServerConfig {
    private static let truthyConfigValues: Set<String> = ["1", "true", "yes", "on"]

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

    static var allowStaticTurnFallback: Bool {
        if let value = environmentValue("SKYBRIDGE_ALLOW_STATIC_TURN_FALLBACK") {
            return truthyConfigValues.contains(value.lowercased())
        }
        if let value = Bundle.main.object(forInfoDictionaryKey: "SKYBRIDGE_ALLOW_STATIC_TURN_FALLBACK") as? Bool {
            return value
        }
        if let value = Bundle.main.object(forInfoDictionaryKey: "SKYBRIDGE_ALLOW_STATIC_TURN_FALLBACK") as? String {
            return truthyConfigValues.contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
        return false
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
private struct PendingVerifiedQRAuthorityCompat: Sendable, Equatable {
    let protocolPublicKeyFingerprint: String
    let verifiedAt: Date
}

@available(iOS 17.0, *)
private enum CurrentPathRebindSource: Sendable, Equatable {
    case none
    case verifiedQRCode
    case verifiedConnectionCode
}

@available(iOS 17.0, *)
private struct CurrentPathHandshakeTrustProviderCompat: MultiFingerprintHandshakeTrustProvider, Sendable {
    let expectedRemoteAuthority: CurrentPathRemoteAuthorityCompat?
    let fallbackPeerIDs: [String]
    let additionalTrustedFingerprints: Set<String>

    func trustedFingerprint(for deviceId: String) async -> String? {
        if let expectedRemoteAuthority,
           deviceId == expectedRemoteAuthority.deviceId || fallbackPeerIDs.contains(deviceId) {
            return expectedRemoteAuthority.protocolPublicKeyFingerprint
        }
        return nil
    }

    func trustedFingerprints(for deviceId: String) async -> Set<String> {
        guard let expected = await trustedFingerprint(for: deviceId) else {
            return []
        }
        var fingerprints = Set<String>()
        let normalizedExpected = expected.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !normalizedExpected.isEmpty {
            fingerprints.insert(normalizedExpected)
        }
        for fingerprint in additionalTrustedFingerprints {
            let normalized = fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !normalized.isEmpty {
                fingerprints.insert(normalized)
            }
        }
        return fingerprints
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
        let normalizedToken = normalizedTurnAdmissionToken(turnAdmissionToken)
        let tokenKey = cacheKey(for: normalizedToken)
        if let cached = cachedByTokenKey[tokenKey] {
            if cached.isValid(buffer: refreshBuffer(for: cached)) {
                return cached
            }
            if normalizedToken != nil {
                logger.info("ℹ️ TURN admission token is single-use; reusing cached credentials until expiry.")
                if cached.isValid(buffer: 0) {
                    return cached
                }
                logger.warning("⚠️ TURN admission token already consumed and cached credentials expired; falling back to STUN-only.")
                return fallback(allowStaticTURN: false)
            }
        }
        do {
            let fresh = try await fetchFromServer(turnAdmissionToken: normalizedToken)
            cachedByTokenKey[tokenKey] = fresh
            return fresh
        } catch {
            if let cached = cachedByTokenKey[tokenKey],
               cached.isValid(buffer: 0) {
                logger.info("ℹ️ TURN credentials fetch failed; reusing cached credentials. err=\(error.localizedDescription, privacy: .public)")
                return cached
            }
            let allowStaticTURN = normalizedToken == nil && CrossNetworkServerConfig.allowStaticTurnFallback
            logger.warning(
                "⚠️ TURN credentials fetch failed; falling back to \(allowStaticTURN ? "static-or-empty TURN" : "STUN-only"). err=\(error.localizedDescription, privacy: .public)"
            )
            return fallback(allowStaticTURN: allowStaticTURN)
        }
    }

    private func normalizedTurnAdmissionToken(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func cacheKey(for turnAdmissionToken: String?) -> String {
        turnAdmissionToken ?? "__anonymous__"
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

    private func fallback(allowStaticTURN: Bool = true) -> TURNCredentials {
        guard allowStaticTURN else {
            return TURNCredentials(
                username: "",
                password: "",
                ttl: 3600,
                uris: [],
                expiresAt: Date().addingTimeInterval(3600)
            )
        }

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
    var onSize: (@Sendable (CGSize) -> Void)?
    var trackId: String = "-"
    var sessionId: String = "-"
    private var lastKnownSize: CGSize = .zero
    private var loggedFirstFrame = false
    private var loggedFirstSize = false

    func setSize(_ size: CGSize) {
        lastKnownSize = size
        guard size.width > 0, size.height > 0 else { return }
        if !loggedFirstSize {
            loggedFirstSize = true
            SkyBridgeSmokeTraceWriter.appendStatus(
                "native-track-renderer-size session=\(sessionId) trackId=\(trackId) size=\(Int(size.width))x\(Int(size.height)) source=heartbeat-renderer"
            )
        }
        let handler = onSize
        DispatchQueue.main.async {
            handler?(size)
        }
    }

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        let measuredSize = CGSize(width: CGFloat(frame.width), height: CGFloat(frame.height))
        guard measuredSize.width > 0, measuredSize.height > 0 else { return }
        if !loggedFirstFrame {
            loggedFirstFrame = true
            SkyBridgeSmokeTraceWriter.appendStatus(
                "native-track-renderer-frame session=\(sessionId) trackId=\(trackId) size=\(Int(measuredSize.width))x\(Int(measuredSize.height)) source=heartbeat-renderer"
            )
        }
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
    @Published public private(set) var remoteVideoTrackReadyForPromotion = false
    @Published public private(set) var remoteVideoTrackHasRenderedFrame = false
    @Published public private(set) var remoteVideoTrackHasReceiverFrameEvidence = false
    @Published public private(set) var nativeRenderEvidenceSource: String?
    @Published public private(set) var nativeRenderUISurface: String?
    @Published public private(set) var nativePromotionState = "idle"
    @Published public private(set) var nativeVideoProbeActive = false
    @Published public private(set) var remoteVideoTrackFrameSize: CGSize = .zero
    @Published public private(set) var remoteVideoTrackRenderEpoch: UInt64 = 0
    @Published public private(set) var remoteAudioTrackHasReceivedFirstPacket = false
    private var remoteVideoTrackHasReceivedFirstPacket = false
    private var remoteVideoTrackConfirmationTask: Task<Void, Never>?
    private var nativeVideoProbeTask: Task<Void, Never>?
    private var nativeVideoProbeCooldownUntil = Date.distantPast
    private var remoteVideoTrackVisibleRenderTraceEpoch: UInt64?
    private var lastNativeReceiverFrameStatusAt = Date.distantPast
    private var remoteVideoTrackDetectedAt: Date?
    private var lastFallbackOnlyNativeVideoDiagnosticAt = Date.distantPast
    private var lastScreenDataAt: Date?
#endif
    public var nativeAudioReceiveEnabled = false
    public var smokeMediaHeartbeatDiagnosticsProvider: (@MainActor () async -> AppMessage.WebRTCMediaHeartbeatDiagnostics?)?
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
    nonisolated static let webRTCStartupJoinHeartbeatAttempts = 60

    public var activeRemoteDesktopSessionId: String? {
        if let sessionId = activeSessionSnapshot?.sessionId {
            return sessionId
        }
        switch state {
        case .connecting(let sessionId), .connected(let sessionId):
            return sessionId
        case .idle, .failed:
            return nil
        }
    }

    func realtimeMediaKeySnapshot() -> RemoteRealtimeMediaKeySnapshot? {
        guard let keys = sessionKeys,
              let sessionId = activeRemoteDesktopSessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionId.isEmpty else {
            return nil
        }
        return RemoteRealtimeMediaKeySnapshot(
            sessionId: sessionId,
            sendKey: keys.sendKey,
            receiveKey: keys.receiveKey,
            transcriptHash: keys.transcriptHash,
            mediaAdmissionToken: webrtcMediaAdmissionTokenBySessionId[sessionId]
        )
    }

    func mediaRelayLeaseDiagnosticForActiveSession() -> String? {
        guard let sessionId = activeRemoteDesktopSessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionId.isEmpty else {
            return "missingSession"
        }
        return mediaAdmissionLeaseFailureReasonBySessionId[sessionId]
    }

    func markRealtimeMediaRelayEndpointUnusableForActiveSession(reason: String) {
        guard let sessionId = activeRemoteDesktopSessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionId.isEmpty else {
            return
        }
        let countKey = "\(sessionId)|\(reason)"
        let failureCount = (mediaAdmissionEndpointUnusableCountsBySessionReason[countKey] ?? 0) + 1
        mediaAdmissionEndpointUnusableCountsBySessionReason[countKey] = failureCount
        let backoff = min(30.0, Double(1 << min(failureCount - 1, 3)) * 5.0)
        let token = Self.normalizedNonEmptyToken(webrtcMediaAdmissionTokenBySessionId[sessionId])
        recordMediaRelayLeaseFailure(
            sessionId: sessionId,
            token: token,
            reason: reason,
            backoff: backoff
        )
        SkyBridgeLogger.shared.warning(
            "🎧 PQC media relay endpoint invalidated: session=\(sessionId) reason=\(reason) failureCount=\(failureCount) backoffMs=\(Int((backoff * 1000).rounded()))"
        )
    }

    func clearCachedRealtimeMediaRelayEndpointForActiveSession(reason: String) {
        guard let sessionId = activeRemoteDesktopSessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionId.isEmpty else {
            return
        }
        mediaAdmissionRelayEndpointBySessionId.removeValue(forKey: sessionId)
        mediaAdmissionRelayRoleBySessionId.removeValue(forKey: sessionId)
        mediaAdmissionLeaseFailureReasonBySessionId.removeValue(forKey: sessionId)
        SkyBridgeLogger.shared.info(
            "🎧 PQC media relay endpoint cache cleared: session=\(sessionId) reason=\(reason)"
        )
    }

    struct RealtimeMediaRelayEndpointPair: Sendable, Equatable {
        let localEndpoint: SkyBridgeMediaEndpoint
        let localRole: String
    }

    func requestRealtimeMediaRelayEndpointForActiveSession() async throws -> RealtimeMediaRelayEndpointPair? {
        guard let sessionId = activeRemoteDesktopSessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionId.isEmpty else {
            return nil
        }
        if let cachedEndpoint = mediaAdmissionRelayEndpointBySessionId[sessionId] {
            if Self.isUsableMediaRelayEndpoint(cachedEndpoint) {
                return RealtimeMediaRelayEndpointPair(
                    localEndpoint: cachedEndpoint,
                    localRole: mediaAdmissionRelayRoleBySessionId[sessionId] ?? "unknown"
                )
            }
            mediaAdmissionRelayEndpointBySessionId.removeValue(forKey: sessionId)
            mediaAdmissionRelayRoleBySessionId.removeValue(forKey: sessionId)
        }
        let initialToken = Self.normalizedNonEmptyToken(webrtcMediaAdmissionTokenBySessionId[sessionId])
        if let backoffReason = activeMediaAdmissionLeaseBackoffReason(sessionId: sessionId, token: initialToken) {
            SkyBridgeLogger.shared.debug(
                "ℹ️ media admission lease retry suppressed: session=\(sessionId) reason=\(backoffReason)"
            )
            return nil
        }
        guard !mediaAdmissionLeaseInFlightSessionIds.contains(sessionId) else {
            recordMediaRelayLeaseFailure(sessionId: sessionId, token: nil, reason: "inFlight")
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(100))
                if let cachedEndpoint = mediaAdmissionRelayEndpointBySessionId[sessionId],
                   Self.isUsableMediaRelayEndpoint(cachedEndpoint) {
                    return RealtimeMediaRelayEndpointPair(
                        localEndpoint: cachedEndpoint,
                        localRole: mediaAdmissionRelayRoleBySessionId[sessionId] ?? "unknown"
                    )
                }
                if !mediaAdmissionLeaseInFlightSessionIds.contains(sessionId) {
                    break
                }
            }
            return nil
        }
        mediaAdmissionLeaseInFlightSessionIds.insert(sessionId)
        defer { mediaAdmissionLeaseInFlightSessionIds.remove(sessionId) }

        var token = initialToken
        if token == nil {
            guard Self.normalizedNonEmptyToken(webrtcSignalingAuthTokenBySessionId[sessionId]) != nil else {
                recordMediaRelayLeaseFailure(sessionId: sessionId, token: nil, reason: "missingSessionToken")
                return nil
            }
            guard currentRole != nil else {
                recordMediaRelayLeaseFailure(sessionId: sessionId, token: nil, reason: "missingRole")
                return nil
            }
            do {
                token = try await refreshMediaAdmissionToken(sessionId: sessionId, staleToken: nil)
            } catch {
                let reason = Self.mediaAdmissionRefreshFailureReason(for: error)
                if reason == "sessionTokenSuperseded" || reason == "sessionTokenExpired" {
                    do {
                        token = try await refreshWebRTCSessionAdmissionTokens(
                            sessionId: sessionId,
                            reason: reason
                        )
                    } catch {
                        let sessionReason = Self.sessionRefreshFailureReason(for: error)
                        recordMediaRelayLeaseFailure(
                            sessionId: sessionId,
                            token: nil,
                            reason: sessionReason,
                            backoff: 30
                        )
                        return nil
                    }
                } else {
                    recordMediaRelayLeaseFailure(sessionId: sessionId, token: nil, reason: reason, backoff: 5)
                    return nil
                }
            }
        }
        guard let token else {
            recordMediaRelayLeaseFailure(sessionId: sessionId, token: nil, reason: "missingToken")
            return nil
        }
        if let backoffReason = activeMediaAdmissionLeaseBackoffReason(sessionId: sessionId, token: token) {
            SkyBridgeLogger.shared.debug(
                "ℹ️ media admission lease retry suppressed: session=\(sessionId) reason=\(backoffReason)"
            )
            return nil
        }
        let lease: SignalServerClientCompat.MediaRelayLease
        do {
            lease = try await signalServer.requestMediaRelayLease(mediaAdmissionToken: token)
        } catch {
            guard Self.isMediaAdmissionTokenRefreshable(error) else {
                let reason = Self.mediaRelayLeaseFailureReason(for: error)
                recordMediaRelayLeaseFailure(sessionId: sessionId, token: token, reason: reason, backoff: 5)
                return nil
            }
            let refreshedToken: String
            do {
                guard let refreshed = try await refreshMediaAdmissionToken(
                    sessionId: sessionId,
                    staleToken: token
                ) else {
                    recordMediaRelayLeaseFailure(sessionId: sessionId, token: token, reason: "refreshFailed", backoff: 5)
                    return nil
                }
                refreshedToken = refreshed
            } catch {
                let reason = Self.mediaAdmissionRefreshFailureReason(for: error)
                if reason == "sessionTokenSuperseded" || reason == "sessionTokenExpired" {
                    do {
                        guard let refreshed = try await refreshWebRTCSessionAdmissionTokens(
                            sessionId: sessionId,
                            reason: reason
                        ) else {
                            recordMediaRelayLeaseFailure(
                                sessionId: sessionId,
                                token: token,
                                reason: "sessionReauthFailed",
                                backoff: 30
                            )
                            return nil
                        }
                        refreshedToken = refreshed
                    } catch {
                        let sessionReason = Self.sessionRefreshFailureReason(for: error)
                        recordMediaRelayLeaseFailure(
                            sessionId: sessionId,
                            token: token,
                            reason: sessionReason,
                            backoff: 30
                        )
                        return nil
                    }
                } else {
                    recordMediaRelayLeaseFailure(sessionId: sessionId, token: token, reason: reason, backoff: 5)
                    return nil
                }
            }
            SkyBridgeLogger.shared.info(
                "🎧 media admission token refreshed; retrying relay lease: session=\(sessionId)"
            )
            do {
                lease = try await signalServer.requestMediaRelayLease(mediaAdmissionToken: refreshedToken)
            } catch {
                let baseReason = Self.mediaRelayLeaseFailureReason(for: error)
                let reason = Self.mediaRelayLeaseFailureReasonAfterRefresh(for: error)
                if baseReason == "superseded" {
                    SkyBridgeLogger.shared.info(
                        "🎧 media admission refreshed token rejected by relay lease: session=\(sessionId) reason=refreshLeaseSuperseded localRetryGeneration=\(Self.tokenGenerationPrefix(refreshedToken) ?? "-") \(Self.mediaTokenDiagnosticSummary(for: error) ?? "")"
                    )
                }
                recordMediaRelayLeaseFailure(sessionId: sessionId, token: refreshedToken, reason: reason, backoff: 5)
                return nil
            }
        }
        mediaAdmissionRelayEndpointBySessionId[sessionId] = lease.endpoint
        mediaAdmissionRelayRoleBySessionId[sessionId] = lease.role
        mediaAdmissionLeaseBackoffBySessionId.removeValue(forKey: sessionId)
        mediaAdmissionLeaseFailureReasonBySessionId.removeValue(forKey: sessionId)
        mediaAdmissionEndpointUnusableCountsBySessionReason = mediaAdmissionEndpointUnusableCountsBySessionReason.filter {
            !$0.key.hasPrefix("\(sessionId)|")
        }
        mediaAdmissionAuthorityLostSessionIds.remove(sessionId)
        SkyBridgeLogger.shared.info(
            "🎧 PQC media relay lease ready: session=\(lease.sessionID) role=\(lease.role) relay=\(lease.endpoint.host):\(lease.endpoint.port) token=\(lease.endpoint.relayToken == nil ? "missing" : "present") event=leaseReady"
        )
        return RealtimeMediaRelayEndpointPair(
            localEndpoint: lease.endpoint,
            localRole: lease.role
        )
    }

    private func refreshMediaAdmissionToken(
        sessionId: String,
        staleToken: String?
    ) async throws -> String? {
        guard let sessionToken = Self.normalizedNonEmptyToken(webrtcSignalingAuthTokenBySessionId[sessionId]),
              let role = currentRole else {
            return nil
        }
        let roleName = role == .offerer ? "initiator" : "responder"
        if staleToken != nil {
            webrtcMediaAdmissionTokenBySessionId.removeValue(forKey: sessionId)
        }
        let staleGeneration = Self.tokenGenerationPrefix(staleToken) ?? "missing"
        let sessionGeneration = Self.tokenGenerationPrefix(sessionToken) ?? "missing"
        let idempotencyKey = "media-refresh-\(sessionId)-\(roleName)-\(sessionGeneration)-\(staleGeneration)"
        let refreshed = try await signalServer.refreshMediaAdmissionLease(
            sessionId: sessionId,
            sessionToken: sessionToken,
            role: roleName,
            idempotencyKey: idempotencyKey
        )
        let normalized = Self.normalizedNonEmptyToken(refreshed.token)
        if let normalized {
            webrtcMediaAdmissionTokenBySessionId[sessionId] = normalized
            SkyBridgeLogger.shared.info(
                "🎧 media admission token refresh accepted: session=\(sessionId) role=\(roleName) localStaleGeneration=\(staleGeneration) localRefreshedGeneration=\(Self.tokenGenerationPrefix(normalized) ?? "-") serverGeneration=\(refreshed.mediaTokenGeneration ?? "-") serverBuild=\(refreshed.serverBuildFingerprint ?? "-")"
            )
        } else {
            if let staleToken {
                webrtcMediaAdmissionTokenBySessionId[sessionId] = staleToken
            } else {
                webrtcMediaAdmissionTokenBySessionId.removeValue(forKey: sessionId)
            }
        }
        return normalized
    }

    private func refreshWebRTCSessionAdmissionTokens(
        sessionId: String,
        reason: String
    ) async throws -> String? {
        guard let role = currentRole else {
            throw NSError(
                domain: "CrossNetworkWebRTCManager",
                code: 41,
                userInfo: [NSLocalizedDescriptionKey: "missingRole"]
            )
        }
        let roleName = role == .offerer ? "initiator" : "responder"
        guard !mediaAdmissionSessionRefreshInFlightSessionIds.contains(sessionId) else {
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(100))
                if let token = Self.normalizedNonEmptyToken(webrtcMediaAdmissionTokenBySessionId[sessionId]) {
                    return token
                }
                if !mediaAdmissionSessionRefreshInFlightSessionIds.contains(sessionId) {
                    break
                }
            }
            return Self.normalizedNonEmptyToken(webrtcMediaAdmissionTokenBySessionId[sessionId])
        }

        mediaAdmissionSessionRefreshInFlightSessionIds.insert(sessionId)
        defer { mediaAdmissionSessionRefreshInFlightSessionIds.remove(sessionId) }

        let binding = try await currentPathLocalBinding()
        let admission = try await requestAdmissionLease(for: binding)
        let lease = try await signalServer.refreshWebRTCSession(
            admissionToken: admission.token,
            sessionId: sessionId,
            role: roleName
        )
        webrtcSignalingAuthTokenBySessionId[sessionId] = lease.sessionToken
        webrtcTurnAdmissionTokenBySessionId[sessionId] = lease.turnAdmissionToken
        if let mediaToken = Self.normalizedNonEmptyToken(lease.mediaAdmissionToken) {
            webrtcMediaAdmissionTokenBySessionId[sessionId] = mediaToken
        } else {
            webrtcMediaAdmissionTokenBySessionId.removeValue(forKey: sessionId)
        }
        if let origin = lease.signalingServerOrigin,
           let canonical = try? validateCurrentPathOrigin(origin) {
            currentPathSignalingOriginBySessionId[sessionId] = canonical
        }
        mediaAdmissionRelayEndpointBySessionId.removeValue(forKey: sessionId)
        mediaAdmissionRelayRoleBySessionId.removeValue(forKey: sessionId)
        mediaAdmissionLeaseBackoffBySessionId.removeValue(forKey: sessionId)
        mediaAdmissionLeaseFailureReasonBySessionId.removeValue(forKey: sessionId)
        SkyBridgeLogger.shared.info(
            "🎧 WebRTC session tokens refreshed for media lease: session=\(sessionId) role=\(roleName) reason=\(reason) serverBuild=\(lease.serverBuildFingerprint ?? "-") sessionTokenGeneration=\(lease.sessionTokenGeneration ?? "-") mediaTokenGeneration=\(lease.mediaTokenGeneration ?? "-")"
        )
        return Self.normalizedNonEmptyToken(lease.mediaAdmissionToken)
    }

    private func recordMediaRelayLeaseFailure(
        sessionId: String,
        token: String?,
        reason: String,
        backoff: TimeInterval? = nil
    ) {
        mediaAdmissionLeaseFailureReasonBySessionId[sessionId] = reason
        mediaAdmissionRelayEndpointBySessionId.removeValue(forKey: sessionId)
        mediaAdmissionRelayRoleBySessionId.removeValue(forKey: sessionId)
        if let backoff {
            mediaAdmissionLeaseBackoffBySessionId[sessionId] = (token, Date().addingTimeInterval(backoff), reason)
        }
        let backoffLabel = backoff.map { " backoffMs=\(Int(($0 * 1000).rounded()))" } ?? ""
        SkyBridgeLogger.shared.info(
            "🎧 PQC media relay lease unavailable: session=\(sessionId) reason=\(reason)\(backoffLabel)"
        )
        if Self.isSessionAuthorityLostReason(reason) {
            recordSessionAuthorityLost(sessionId: sessionId, reason: reason)
        }
    }

    private func recordSessionAuthorityLost(sessionId: String, reason: String) {
        guard mediaAdmissionAuthorityLostSessionIds.insert(sessionId).inserted else { return }
        mediaAdmissionLeaseBackoffBySessionId[sessionId] = (nil, Date().addingTimeInterval(30), "sessionAuthorityLost")
        mediaAdmissionRelayEndpointBySessionId.removeValue(forKey: sessionId)
        mediaAdmissionRelayRoleBySessionId.removeValue(forKey: sessionId)
        mediaAdmissionLeaseFailureReasonBySessionId[sessionId] = "sessionAuthorityLost"
        let sessionGeneration = Self.tokenGenerationPrefix(webrtcSignalingAuthTokenBySessionId[sessionId]) ?? "-"
        let mediaGeneration = Self.tokenGenerationPrefix(webrtcMediaAdmissionTokenBySessionId[sessionId]) ?? "-"
        SkyBridgeLogger.shared.warning(
            "🎧 WebRTC session authority lost: session=\(sessionId) event=sessionAuthorityLost reason=\(reason) localSessionGeneration=\(sessionGeneration) localMediaGeneration=\(mediaGeneration) action=fullRejoinRequired"
        )
        if currentSessionId == sessionId {
            applyActiveSessionDisconnect(sessionId: sessionId, kind: .transient)
            Task { @MainActor [weak self] in
                guard let self,
                      self.currentSessionId == sessionId else { return }
                await self.disconnect(clearSnapshot: false)
                self.lastError = "WebRTC session authority lost; full rejoin required"
                self.state = .failed("sessionAuthorityLost")
                self.readiness = .idle
            }
        }
    }

    private func activeMediaAdmissionLeaseBackoffReason(
        sessionId: String,
        token: String?,
        now: Date = Date()
    ) -> String? {
        guard let backoff = mediaAdmissionLeaseBackoffBySessionId[sessionId] else {
            return nil
        }
        guard backoff.until > now else {
            mediaAdmissionLeaseBackoffBySessionId.removeValue(forKey: sessionId)
            return nil
        }
        guard backoff.token == nil || backoff.token == token else {
            return nil
        }
        mediaAdmissionLeaseFailureReasonBySessionId[sessionId] = backoff.reason
        return backoff.reason
    }

    private static func isMediaAdmissionTokenRefreshable(_ error: Error) -> Bool {
        guard case SignalServerClientCompat.ClientError.serverRejected(let status, let body) = error else {
            return false
        }
        guard !mediaLeaseBodyIndicatesSessionAuthorityLost(body) else {
            return false
        }
        if status == 401 && (
            body.contains("media_admission_token_superseded")
                || body.contains("media_admission_token_expired")
        ) {
            return true
        }
        return status == 429 && body.contains("media_admission_token_lease_limit")
    }

    private static func isUsableMediaRelayEndpoint(_ endpoint: SkyBridgeMediaEndpoint, now: Date = Date()) -> Bool {
        guard let expiresAt = endpoint.expiresAt else { return true }
        return expiresAt - now.timeIntervalSince1970 > 10
    }

    nonisolated private static func mediaRelayLeaseFailureReason(for error: Error) -> String {
        guard case SignalServerClientCompat.ClientError.serverRejected(let status, let body) = error else {
            return "leaseRejected"
        }
        if mediaLeaseBodyIndicatesSessionAuthorityLost(body) {
            return "sessionAuthorityLost"
        }
        if body.contains("media_admission_token_superseded") {
            return "superseded"
        }
        if body.contains("media_admission_token_expired") {
            return "expired"
        }
        if body.contains("media_admission_token_lease_limit") {
            return "leaseLimit"
        }
        if body.contains("missing_session") || body.contains("session_inactive") {
            return "sessionAuthorityLost"
        }
        if status == 503 || body.contains("relay") {
            return "relayUnavailable"
        }
        return "leaseRejected"
    }

    nonisolated private static func mediaRelayLeaseFailureReasonAfterRefresh(for error: Error) -> String {
        let reason = mediaRelayLeaseFailureReason(for: error)
        return reason == "superseded" ? "serverStateMismatch" : reason
    }

    nonisolated private static func mediaTokenDiagnosticSummary(for error: Error) -> String? {
        guard case SignalServerClientCompat.ClientError.serverRejected(_, let body) = error,
              let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let request = object["mediaTokenRequestGeneration"] as? String
            ?? object["mediaTokenGeneration"] as? String
            ?? "-"
        let expected = object["mediaTokenExpectedGeneration"] as? String ?? "-"
        let expectedPresent: String = {
            if let bool = object["mediaTokenExpectedPresent"] as? Bool {
                return bool ? "true" : "false"
            }
            return "-"
        }()
        let sessionPresent: String = {
            if let bool = object["mediaTokenSessionPresent"] as? Bool {
                return bool ? "true" : "false"
            }
            return "-"
        }()
        let state = object["mediaTokenState"] as? String ?? "-"
        let revokedReason = object["mediaTokenRevokedReason"] as? String ?? "-"
        let build = object["serverBuildFingerprint"] as? String ?? "-"
        let rejectReason = object["rejectReason"] as? String ?? "-"
        return "requestGeneration=\(request) expectedGeneration=\(expected) expectedPresent=\(expectedPresent) sessionPresent=\(sessionPresent) tokenState=\(state) tokenRevokedReason=\(revokedReason) rejectReason=\(rejectReason) serverBuild=\(build)"
    }

    nonisolated private static func mediaAdmissionRefreshFailureReason(for error: Error) -> String {
        guard case SignalServerClientCompat.ClientError.serverRejected(let status, let body) = error else {
            return "refreshFailed"
        }
        if status == 404 || body.contains("Cannot POST /api/media/admission/refresh") {
            return "serverRefreshUnsupported"
        }
        if body.contains("session_token_superseded") {
            return "sessionTokenSuperseded"
        }
        if body.contains("session_token_expired") {
            return "sessionTokenExpired"
        }
        if body.contains("missing_session_token") {
            return "missingSessionToken"
        }
        if body.contains("missing_session") || body.contains("session_inactive") {
            return "sessionAuthorityLost"
        }
        if status == 503 {
            return "relayUnavailable"
        }
        return "refreshFailed"
    }

    nonisolated private static func sessionRefreshFailureReason(for error: Error) -> String {
        guard case SignalServerClientCompat.ClientError.serverRejected(let status, let body) = error else {
            let description = (error as NSError).localizedDescription
            if description == "missingRole" {
                return "missingRole"
            }
            return "sessionReauthFailed"
        }
        if status == 404 || body.contains("Cannot POST /api/webrtc/session/refresh") {
            return "serverUnsupported"
        }
        if body.contains("missing_session") || body.contains("session_inactive") {
            return "sessionAuthorityLost"
        }
        if body.contains("session_scope_mismatch") || body.contains("scope") || status == 403 {
            return "scopeMismatch"
        }
        if status == 503 {
            return "serverUnavailable"
        }
        return "sessionReauthFailed"
    }

    nonisolated private static func isSessionAuthorityLostReason(_ reason: String) -> Bool {
        reason == "sessionAuthorityLost"
    }

    nonisolated private static func mediaLeaseBodyIndicatesSessionAuthorityLost(_ body: String) -> Bool {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return body.contains("session_inactive") || body.contains("missing_session")
        }
        if let present = object["mediaTokenSessionPresent"] as? Bool, present == false {
            return true
        }
        if let error = object["error"] as? String,
           error == "session_inactive" || error == "missing_session" {
            return true
        }
        if let rejectReason = object["rejectReason"] as? String,
           ["missingRecord", "revoked", "activeExpired", "iceKilled", "remote_kill", "session_killed"].contains(rejectReason) {
            return true
        }
        if let state = object["mediaTokenState"] as? String,
           state.caseInsensitiveCompare("revoked") == .orderedSame {
            let expectedPresent = object["mediaTokenExpectedPresent"] as? Bool
            let sessionPresent = object["mediaTokenSessionPresent"] as? Bool
            return expectedPresent != true || sessionPresent == false
        }
        return false
    }

    private static let shortCodeAlphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    private static let shortCodeAllowedCharacters = Set(shortCodeAlphabet)
    public static let legacyConnectionCodeLength = 6
    public static let preferredConnectionCodeLength = 8
    public static let maximumConnectionCodeLength = 16
    nonisolated static let connectionCodeMinimumReusableTime: TimeInterval = 15
    private static let connectionCodeLeaseModeDefaultsKey = "cross_network_connection_code_lease_mode"
    private static let idleConnectionReminderDelay: TimeInterval = 180

    private var signaling: WebSocketSignalingClient?
    private var signalingShardKey: String?
    private let signalServer = SignalServerClientCompat()
    private let signalingRetryController = SignalingRetryController()
    private var signalingRecoveryTasksBySessionId: [String: Task<Void, Never>] = [:]
    private var signalingGenerationBySessionId: [String: Int] = [:]
    private var activeSignalingHandleBySessionId: [String: WebSocketSignalingClient.SignalingHandleID] = [:]
    private enum SignalingHealth: Equatable {
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
    private var currentPathAdditionalProtocolFingerprintsBySessionId: [String: Set<String>] = [:]
    private var currentPathSignalingOriginBySessionId: [String: String] = [:]
    private var pendingVerifiedQRAuthoritiesByDeviceId: [String: PendingVerifiedQRAuthorityCompat] = [:]
    private var handshakeDriver: HandshakeDriver?
    private var handshakePeerId: String?
    private var sessionKeys: SessionKeys?
    private var inboundQueue: InboundChunkQueue?
    private var screenInboundQueue: InboundChunkQueue?
    private var receiveTask: Task<Void, Never>?
    private var screenReceiveTask: Task<Void, Never>?
    private var currentRole: WebRTCSession.Role?
    private var handshakeStartedSessionIds: Set<String> = []
    private var inboundInitialHandshakeResponderSessionIds: Set<String> = []
    private var inboundClassicAuthorityBootstrapSessionIds: Set<String> = []
    private var strictPQCClassicBootstrapOnlySessionIds: Set<String> = []
    private var strictPQCClassicBootstrapTimeoutTasksBySessionId: [String: Task<Void, Never>] = [:]
    private var rekeyInProgressSessionIds: Set<String> = []
    private var rekeyCompletedSessionIds: Set<String> = []
    private var inboundRekeyResponderSessionIds: Set<String> = []
    private var strictPQCRequestedBySessionId: [String: Bool] = [:]
    private var lastPairingIdentityExchangeSentAtByPeerId: [String: Date] = [:]
    private var connectionCodeBootstrapTask: Task<Void, Never>?
    private var connectionCodeExpiryTask: Task<Void, Never>?
    private var idleConnectionReminderTask: Task<Void, Never>?
    private var activeConnectionCodeLeaseMode: ConnectionCodeLeaseMode?
    private var localConnectionSessionId: String?
    private var activeConnectionCodeAuthorityDeviceId: String?
    private var activeConnectionCodeAuthorityFingerprint: String?
    private var authorityBoundWebRTCBootstrapSessionIds = Set<String>()
    private var activeSessionReconnectTimeoutTask: Task<Void, Never>?
    private var webrtcSignalingAuthTokenBySessionId: [String: String] = [:]
    private var webrtcTurnAdmissionTokenBySessionId: [String: String] = [:]
    private var webrtcMediaAdmissionTokenBySessionId: [String: String] = [:]
    private var mediaAdmissionLeaseBackoffBySessionId: [String: (token: String?, until: Date, reason: String)] = [:]
    private var mediaAdmissionLeaseInFlightSessionIds = Set<String>()
    private var mediaAdmissionSessionRefreshInFlightSessionIds = Set<String>()
    private var mediaAdmissionLeaseFailureReasonBySessionId: [String: String] = [:]
    private var mediaAdmissionAuthorityLostSessionIds = Set<String>()
    private var mediaAdmissionRelayEndpointBySessionId: [String: SkyBridgeMediaEndpoint] = [:]
    private var mediaAdmissionRelayRoleBySessionId: [String: String] = [:]
    private var mediaAdmissionEndpointUnusableCountsBySessionReason: [String: Int] = [:]
    private var latestLocalOfferBySessionId: [String: String] = [:]
    private var latestLocalAnswerBySessionId: [String: String] = [:]
    private var localICECandidatesBySessionId: [String: [WebRTCSignalingEnvelope.Payload]] = [:]
    private var joinHeartbeatTask: Task<Void, Never>?
    private var offerResendTask: Task<Void, Never>?
    private var remoteDesktopHeartbeatTask: Task<Void, Never>?
    private var remotePeerPingTask: Task<Void, Never>?
    private var remotePeerLivenessWatchdogTask: Task<Void, Never>?
    private var remoteAppActivityAtBySessionId: [String: Date] = [:]
    private var suppressSignalingRecovery = false
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
                if self.strictPQCClassicBootstrapOnlySessionIds.contains(sessionId) {
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
                guard case .connected(let activeSessionId) = self.state, activeSessionId == sessionId else {
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }

                let lastActivityAt = self.remoteAppActivityAtBySessionId[sessionId] ?? .distantPast
                if Date().timeIntervalSince(lastActivityAt) > timeoutSeconds {
                    let msg = "远端连接已失活"
                    SkyBridgeLogger.shared.warning(
                        "⚠️ WebRTC remote peer timeout: session=\(sessionId) summary=\(self.remoteDesktopRecoveryDebugSummary())"
                    )
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

    private func markStrictPQCClassicBootstrapOnly(
        sessionId: String,
        session: WebRTCSession
    ) {
        strictPQCClassicBootstrapOnlySessionIds.insert(sessionId)
        startRemotePeerLivenessWatchdog(sessionId: sessionId, session: session)

        strictPQCClassicBootstrapTimeoutTasksBySessionId[sessionId]?.cancel()
        strictPQCClassicBootstrapTimeoutTasksBySessionId[sessionId] = Task { @MainActor [weak self, weak session] in
            let startedAt = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(strictPQCClassicBootstrapTimeoutSeconds))
                guard let self,
                      let session,
                      self.currentSessionId == sessionId,
                      self.session === session,
                      self.strictPQCClassicBootstrapOnlySessionIds.contains(sessionId),
                      self.sessionKeys?.negotiatedSuite.isPQCGroup != true else {
                    self?.strictPQCClassicBootstrapTimeoutTasksBySessionId.removeValue(forKey: sessionId)
                    return
                }

                let now = Date()
                let elapsed = now.timeIntervalSince(startedAt)
                let lastActivityAt = self.remoteAppActivityAtBySessionId[sessionId] ?? startedAt
                let hasFreshActivity = now.timeIntervalSince(lastActivityAt) <= strictPQCClassicBootstrapTimeoutSeconds
                let isRekeyActivelyProgressing = self.rekeyInProgressSessionIds.contains(sessionId)
                if elapsed < strictPQCClassicBootstrapMaxGraceSeconds,
                   (hasFreshActivity || isRekeyActivelyProgressing) {
                    SkyBridgeLogger.shared.warning(
                        "⏳ WebRTC strictPQC classic bootstrap timeout extended while rekey/liveness is active: session=\(sessionId), elapsed=\(Int(elapsed))s, active=\(hasFreshActivity), rekey=\(isRekeyActivelyProgressing)"
                    )
                    continue
                }

                self.strictPQCClassicBootstrapTimeoutTasksBySessionId.removeValue(forKey: sessionId)
                await self.failStrictPQCBootstrapSession(
                    sessionId: sessionId,
                    message: "strictPQC WebRTC rekey timed out after classic bootstrap"
                )
                return
            }
        }
    }

    private func clearStrictPQCClassicBootstrapOnly(sessionId: String) {
        strictPQCClassicBootstrapOnlySessionIds.remove(sessionId)
        strictPQCClassicBootstrapTimeoutTasksBySessionId.removeValue(forKey: sessionId)?.cancel()
    }

    private func localProtocolIdentityPublicKeysForPairing() async -> [AppMessage.ProtocolIdentityPublicKeyInfo] {
        var keys: [AppMessage.ProtocolIdentityPublicKeyInfo] = []
        for algorithm in [ProtocolSigningAlgorithm.ed25519, .mlDSA65] {
            do {
                let publicKey = try await SkyBridgeiOSCore.shared.getProtocolSigningPublicKey(for: algorithm)
                keys.append(.init(protocolSigningAlgorithm: algorithm.rawValue, publicKey: publicKey))
            } catch {
                SkyBridgeLogger.shared.debug(
                    "ℹ️ WebRTC pairingIdentityExchange skipped protocol identity key alg=\(algorithm.rawValue): \(error.localizedDescription)"
                )
            }
        }
        return AppMessage.ProtocolIdentityPublicKeyInfo.normalizedValidKeys(keys) ?? []
    }

    private func protocolIdentityFingerprints(
        from payload: AppMessage.PairingIdentityExchangePayload
    ) -> Set<String> {
        Set((AppMessage.ProtocolIdentityPublicKeyInfo.normalizedValidKeys(payload.protocolIdentityPublicKeys) ?? [])
            .compactMap { $0.authoritativeFingerprint?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty })
    }

    private func recordCurrentPathProtocolFingerprints(
        from payload: AppMessage.PairingIdentityExchangePayload,
        sessionId: String,
        peerDeviceId: String
    ) {
        let fingerprints = protocolIdentityFingerprints(from: payload)
        guard !fingerprints.isEmpty else { return }
        currentPathAdditionalProtocolFingerprintsBySessionId[sessionId, default: []].formUnion(fingerprints)
        appendSmokeTrace(
            "protocol-identity-pins session=\(sessionId) peer=\(peerDeviceId) declared=\(payload.deviceId) count=\(fingerprints.count)"
        )
        SkyBridgeLogger.shared.info(
            "🔐 WebRTC current-path protocol identity pins updated: session=\(sessionId), peer=\(peerDeviceId), declared=\(payload.deviceId), count=\(fingerprints.count)"
        )
    }

    private func additionalProtocolFingerprints(for sessionId: String) -> Set<String> {
        currentPathAdditionalProtocolFingerprintsBySessionId[sessionId] ?? []
    }

    private func currentPathLocalBinding() async throws -> ProtocolIdentityBindingCompat {
        let algorithm: ProtocolSigningAlgorithm = .ed25519
        let publicKey = try await SkyBridgeiOSCore.shared.getProtocolSigningPublicKey(for: algorithm)
        return try ProtocolIdentityBindingCompat(
            deviceId: localDeviceId,
            protocolSigningAlgorithm: algorithm,
            protocolPublicKeyBytes: publicKey
        )
    }

    private func signCurrentPathPayload(
        _ payload: Data,
        algorithm: ProtocolSigningAlgorithm
    ) async throws -> Data {
        let signatureProvider = ProtocolSignatureProviderSelector.select(for: algorithm)
        let signingHandle = try await SkyBridgeiOSCore.shared.getProtocolSigningKeyHandle(for: algorithm)
        return try await signatureProvider.sign(payload, key: signingHandle)
    }

    static func shouldAllowAuthenticatedAuthorityRebind(
        for conflict: TrustedDeviceStore.CurrentPathTrustConflict
    ) -> Bool {
        switch conflict {
        case .identityConflict, .deviceIdMigrationRequired:
            return false
        case .quarantinedIdentity, .revokedIdentity:
            return false
        }
    }

    static func shouldAllowAuthenticatedQRRebind(
        for conflict: TrustedDeviceStore.CurrentPathTrustConflict
    ) -> Bool {
        switch conflict {
        case .identityConflict, .deviceIdMigrationRequired:
            return true
        case .quarantinedIdentity, .revokedIdentity:
            return false
        }
    }

    static func shouldAllowAuthenticatedConnectionCodeRebind(
        for conflict: TrustedDeviceStore.CurrentPathTrustConflict
    ) -> Bool {
        switch conflict {
        case .identityConflict:
            return true
        case .deviceIdMigrationRequired, .quarantinedIdentity, .revokedIdentity:
            return false
        }
    }

    private func noteVerifiedQRCodeAuthority(
        deviceId: String,
        protocolPublicKeyFingerprint: String
    ) {
        pendingVerifiedQRAuthoritiesByDeviceId[deviceId] = PendingVerifiedQRAuthorityCompat(
            protocolPublicKeyFingerprint: protocolPublicKeyFingerprint.lowercased(),
            verifiedAt: Date()
        )
    }

    private func hasRecentVerifiedQRCodeAuthority(
        deviceId: String,
        protocolPublicKeyFingerprint: String,
        maxAge: TimeInterval = 10 * 60
    ) -> Bool {
        guard let pending = pendingVerifiedQRAuthoritiesByDeviceId[deviceId] else { return false }
        guard pending.protocolPublicKeyFingerprint == protocolPublicKeyFingerprint.lowercased() else { return false }
        return Date().timeIntervalSince(pending.verifiedAt) <= maxAge
    }

    private func activeConnectionCodeMatchesCurrentAuthority(_ binding: ProtocolIdentityBindingCompat) -> Bool {
        guard let activeConnectionCodeAuthorityDeviceId,
              let activeConnectionCodeAuthorityFingerprint else {
            return false
        }
        return activeConnectionCodeAuthorityDeviceId == binding.deviceId
            && activeConnectionCodeAuthorityFingerprint == binding.protocolPublicKeyFingerprint
    }

    private func enforceCurrentPathTrustBinding(
        deviceId: String,
        protocolPublicKeyFingerprint: String,
        rebindSource: CurrentPathRebindSource = .none
    ) throws {
        if let conflict = TrustedDeviceStore.shared.evaluateCurrentPathBinding(
            deviceId: deviceId,
            protocolPublicKeyFingerprint: protocolPublicKeyFingerprint
        ) {
            let shouldAllowRebind: Bool
            switch rebindSource {
            case .none:
                shouldAllowRebind = false
            case .verifiedQRCode:
                shouldAllowRebind = Self.shouldAllowAuthenticatedQRRebind(for: conflict)
            case .verifiedConnectionCode:
                shouldAllowRebind = Self.shouldAllowAuthenticatedConnectionCodeRebind(for: conflict)
            }

            if shouldAllowRebind {
                SkyBridgeLogger.shared.warning(
                    "⚠️ 允许受限 current-path authority 重绑定: source=\(String(describing: rebindSource)) deviceId=\(deviceId) fingerprint=\(protocolPublicKeyFingerprint) conflict=\(String(describing: conflict))"
                )
                return
            }
            let prefix = rebindSource == .verifiedConnectionCode ? "连接码" : "二维码"
            switch conflict {
            case .identityConflict:
                throw NSError(domain: "CrossNetworkWebRTCManager", code: 21, userInfo: [NSLocalizedDescriptionKey: "\(prefix) authoritative key 与现有 deviceId 绑定冲突"])
            case .deviceIdMigrationRequired:
                throw NSError(domain: "CrossNetworkWebRTCManager", code: 22, userInfo: [NSLocalizedDescriptionKey: "\(prefix) deviceId 与已 pinned authoritative key 不匹配"])
            case .quarantinedIdentity:
                throw NSError(domain: "CrossNetworkWebRTCManager", code: 23, userInfo: [NSLocalizedDescriptionKey: "\(prefix)身份处于隔离/待重新验证状态"])
            case .revokedIdentity:
                throw NSError(domain: "CrossNetworkWebRTCManager", code: 24, userInfo: [NSLocalizedDescriptionKey: "\(prefix)身份已撤销"])
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
        let signature = try await signCurrentPathPayload(
            challenge.signaturePayload(),
            algorithm: binding.protocolSigningAlgorithm
        )
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
            SkyBridgeLogger.shared.info("🌐 QR connect phase=start")
            let payload = try await parseSkybridgeConnectLink(normalized)
            SkyBridgeLogger.shared.info("🌐 QR connect phase=payload_parsed session=\(payload.sessionID) device=\(payload.deviceID)")
            try await connect(from: payload)
            SkyBridgeLogger.shared.info("🌐 QR connect phase=connect_dispatched session=\(payload.sessionID)")
        } catch {
            let msg = error.localizedDescription
            SkyBridgeLogger.shared.error("❌ QR connect phase=failed err=\(msg)")
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
            SkyBridgeLogger.shared.info("🌐 code connect phase=start code=<redacted>")
            let localBinding = try await currentPathLocalBinding()
            SkyBridgeLogger.shared.info("🌐 code connect phase=local_binding_ready device=\(localBinding.deviceId)")
            let admission = try await requestAdmissionLease(for: localBinding)
            SkyBridgeLogger.shared.info("🌐 code connect phase=admission_ready")
            let lookup = try await signalServer.lookupConnectionCode(admissionToken: admission.token, code: code)
            SkyBridgeLogger.shared.info("🌐 code connect phase=lookup_ready session=\(lookup.sessionID) initiator=\(lookup.initiatorDeviceId)")
            let canonicalOrigin = try validateCurrentPathOrigin(lookup.signalingServerOrigin)
            let codeRebindSource: CurrentPathRebindSource =
                hasRecentVerifiedQRCodeAuthority(
                    deviceId: lookup.initiatorDeviceId,
                    protocolPublicKeyFingerprint: lookup.initiatorProtocolPublicKeyFingerprint
                )
                ? .verifiedQRCode
                : .verifiedConnectionCode
            try enforceCurrentPathTrustBinding(
                deviceId: lookup.initiatorDeviceId,
                protocolPublicKeyFingerprint: lookup.initiatorProtocolPublicKeyFingerprint,
                rebindSource: codeRebindSource
            )
            webrtcSignalingAuthTokenBySessionId[lookup.sessionID] = lookup.sessionToken
            webrtcTurnAdmissionTokenBySessionId[lookup.sessionID] = lookup.turnAdmissionToken
            if let mediaAdmissionToken = lookup.mediaAdmissionToken {
                webrtcMediaAdmissionTokenBySessionId[lookup.sessionID] = mediaAdmissionToken
            }
            currentPathSignalingOriginBySessionId[lookup.sessionID] = canonicalOrigin
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
            SkyBridgeLogger.shared.info("🌐 code connect phase=connect_dispatched session=\(lookup.sessionID)")
        } catch {
            let msg = error.localizedDescription
            SkyBridgeLogger.shared.error("❌ code connect phase=failed err=\(msg)")
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

        do {
            let localBinding = try await currentPathLocalBinding()
            let canReuseCurrentAuthority = activeConnectionCodeMatchesCurrentAuthority(localBinding)
            if let existing = localConnectionCode,
               activeConnectionCodeLeaseMode == requestedLeaseMode,
               currentRole == .offerer,
               case .connecting(let sid) = state, sid == (localConnectionSessionId ?? existing),
               Self.isReusableConnectionCodeLease(expiresAt: localConnectionCodeExpiresAt),
               canReuseCurrentAuthority {
                return existing
            }
            if let existing = localConnectionCode,
               activeConnectionCodeLeaseMode == requestedLeaseMode,
               currentRole == .offerer,
               case .connected(let sid) = state, sid == (localConnectionSessionId ?? existing),
               Self.isReusableConnectionCodeLease(expiresAt: localConnectionCodeExpiresAt),
               canReuseCurrentAuthority {
                return existing
            }
            if let existing = localConnectionCode,
               activeConnectionCodeLeaseMode == requestedLeaseMode,
               currentRole == .offerer,
               (!Self.isReusableConnectionCodeLease(expiresAt: localConnectionCodeExpiresAt) || !canReuseCurrentAuthority) {
                let reason = canReuseCurrentAuthority ? "connection_code_lease_not_reusable" : "connection_code_authority_changed"
                SkyBridgeLogger.shared.info("ℹ️ 本地连接码不可复用，重新向信令服务注册: reason=\(reason) code=\(existing)")
                let staleSessionId = localConnectionSessionId
                localConnectionCode = nil
                localConnectionCodeExpiresAt = nil
                localConnectionSessionId = nil
                activeConnectionCodeLeaseMode = nil
                activeConnectionCodeAuthorityDeviceId = nil
                activeConnectionCodeAuthorityFingerprint = nil
                if let staleSessionId {
                    authorityBoundWebRTCBootstrapSessionIds.remove(staleSessionId)
                }
                connectionCodeExpiryTask?.cancel()
                connectionCodeExpiryTask = nil
                connectionCodeBootstrapTask?.cancel()
                connectionCodeBootstrapTask = nil
            }
            if localConnectionCode != nil,
               currentRole == .offerer,
               activeConnectionCodeLeaseMode != requestedLeaseMode {
                await disconnect()
            }
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
            let canonicalOrigin = try validateCurrentPathOrigin(lease.signalingServerOrigin)
            webrtcSignalingAuthTokenBySessionId[lease.sessionID] = lease.sessionToken
            webrtcTurnAdmissionTokenBySessionId[lease.sessionID] = lease.turnAdmissionToken
            if let mediaAdmissionToken = lease.mediaAdmissionToken {
                webrtcMediaAdmissionTokenBySessionId[lease.sessionID] = mediaAdmissionToken
            }
            currentPathSignalingOriginBySessionId[lease.sessionID] = canonicalOrigin
            localConnectionCode = lease.code
            localConnectionCodeExpiresAt = Date().addingTimeInterval(lease.expiresIn)
            activeConnectionCodeLeaseMode = requestedLeaseMode
            localConnectionSessionId = lease.sessionID
            activeConnectionCodeAuthorityDeviceId = localBinding.deviceId
            activeConnectionCodeAuthorityFingerprint = localBinding.protocolPublicKeyFingerprint
            authorityBoundWebRTCBootstrapSessionIds.insert(lease.sessionID)
            currentRole = .offerer
            state = .connecting(sessionId: lease.sessionID)
            readiness = .idle
            lastError = nil
            if let expiresAt = localConnectionCodeExpiresAt {
                scheduleConnectionCodeLeaseInvalidation(
                    code: lease.code,
                    sessionID: lease.sessionID,
                    expiresAt: expiresAt
                )
            }

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

    private func scheduleConnectionCodeLeaseInvalidation(
        code: String,
        sessionID: String,
        expiresAt: Date
    ) {
        connectionCodeExpiryTask?.cancel()
        let delay = max(
            0,
            expiresAt
                .addingTimeInterval(-Self.connectionCodeMinimumReusableTime)
                .timeIntervalSinceNow
        )
        connectionCodeExpiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled,
                  let self,
                  self.localConnectionCode == code,
                  self.localConnectionSessionId == sessionID,
                  !Self.isReusableConnectionCodeLease(expiresAt: self.localConnectionCodeExpiresAt) else {
                return
            }
            SkyBridgeLogger.shared.info("ℹ️ 本地连接码租约到期，已清理旧码: reason=connection_code_lease_expired code=\(code)")
            self.connectionCodeExpiryTask = nil
            self.localConnectionCode = nil
            self.localConnectionCodeExpiresAt = nil
            self.activeConnectionCodeLeaseMode = nil
            self.activeConnectionCodeAuthorityDeviceId = nil
            self.activeConnectionCodeAuthorityFingerprint = nil
            self.authorityBoundWebRTCBootstrapSessionIds.remove(sessionID)
        }
    }

    @discardableResult
    public func generateConnectLink(validDuration: TimeInterval = 300) async -> String? {
        disarmIdleConnectionReminder(clearPrompt: true)
        do {
            let localBinding = try await currentPathLocalBinding()
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
            let canonicalOrigin = try validateCurrentPathOrigin(lease.signalingServerOrigin)
            webrtcSignalingAuthTokenBySessionId[lease.sessionID] = lease.sessionToken
            webrtcTurnAdmissionTokenBySessionId[lease.sessionID] = lease.turnAdmissionToken
            if let mediaAdmissionToken = lease.mediaAdmissionToken {
                webrtcMediaAdmissionTokenBySessionId[lease.sessionID] = mediaAdmissionToken
            }
            currentPathSignalingOriginBySessionId[lease.sessionID] = canonicalOrigin

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
            let signature = try await signCurrentPathPayload(
                buildCanonicalQRCodePayload(for: qrData),
                algorithm: localBinding.protocolSigningAlgorithm
            )
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
            localConnectionSessionId = lease.sessionID
            authorityBoundWebRTCBootstrapSessionIds.insert(lease.sessionID)
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
        suppressSignalingRecovery = true
        defer { suppressSignalingRecovery = false }
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
        signalingGenerationBySessionId.removeAll()
        activeSignalingHandleBySessionId.removeAll()
        session?.close()
        session = nil
        currentSessionId = nil
        lastScreenData = nil
#if canImport(WebRTC)
        installRemoteVideoTrack(nil)
        remoteVideoTrackReadyForPromotion = false
        remoteVideoTrackHasRenderedFrame = false
        remoteVideoTrackHasReceiverFrameEvidence = false
        nativeRenderEvidenceSource = nil
        nativeRenderUISurface = nil
        nativePromotionState = "idle"
        nativeVideoProbeTask?.cancel()
        nativeVideoProbeTask = nil
        nativeVideoProbeActive = false
        nativeVideoProbeCooldownUntil = .distantPast
        remoteVideoTrackVisibleRenderTraceEpoch = nil
        lastNativeReceiverFrameStatusAt = .distantPast
        remoteVideoTrackFrameSize = .zero
        remoteAudioTrackHasReceivedFirstPacket = false
        remoteVideoTrackHasReceivedFirstPacket = false
        remoteVideoTrackDetectedAt = nil
        lastScreenDataAt = nil
#endif
        handshakeDriver = nil
        handshakePeerId = nil
        sessionKeys = nil
        remoteDeviceName = nil
        remoteDeviceId = nil
        localConnectionCode = nil
        localConnectionCodeExpiresAt = nil
        activeConnectionCodeLeaseMode = nil
        activeConnectionCodeAuthorityDeviceId = nil
        activeConnectionCodeAuthorityFingerprint = nil
        authorityBoundWebRTCBootstrapSessionIds.removeAll()
        currentConnectLink = nil
        localConnectionSessionId = nil
        currentRole = nil
        connectionCodeBootstrapTask?.cancel()
        connectionCodeBootstrapTask = nil
        connectionCodeExpiryTask?.cancel()
        connectionCodeExpiryTask = nil
        strictPQCClassicBootstrapTimeoutTasksBySessionId.values.forEach { $0.cancel() }
        strictPQCClassicBootstrapTimeoutTasksBySessionId.removeAll()
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
        webrtcMediaAdmissionTokenBySessionId.removeAll()
        mediaAdmissionLeaseBackoffBySessionId.removeAll()
        mediaAdmissionLeaseInFlightSessionIds.removeAll()
        mediaAdmissionLeaseFailureReasonBySessionId.removeAll()
        mediaAdmissionAuthorityLostSessionIds.removeAll()
        mediaAdmissionRelayEndpointBySessionId.removeAll()
        mediaAdmissionRelayRoleBySessionId.removeAll()
        mediaAdmissionEndpointUnusableCountsBySessionReason.removeAll()
        currentPathExpectedRemoteAuthorityBySessionId.removeAll()
        currentPathAdditionalProtocolFingerprintsBySessionId.removeAll()
        currentPathSignalingOriginBySessionId.removeAll()
        remoteAppActivityAtBySessionId.removeAll()
        handshakeStartedSessionIds.removeAll()
        inboundInitialHandshakeResponderSessionIds.removeAll()
        inboundClassicAuthorityBootstrapSessionIds.removeAll()
        strictPQCClassicBootstrapOnlySessionIds.removeAll()
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
    private static func remoteVideoTracksShareNativeBacking(_ lhs: RTCVideoTrack?, _ rhs: RTCVideoTrack?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            // RTCRtpReceiver.track may vend a fresh wrapper on each read; WebRTC requires isEqual for backing identity.
            return lhs === rhs || lhs.isEqual(rhs)
        default:
            return false
        }
    }

    private func installRemoteVideoTrack(_ track: RTCVideoTrack?) {
        let currentTrackId = WebRTCSession.normalizedRemoteVideoTrackId(remoteVideoTrack?.trackId)
        let incomingTrackId = WebRTCSession.normalizedRemoteVideoTrackId(track?.trackId)
        let tracksShareNativeBacking = Self.remoteVideoTracksShareNativeBacking(remoteVideoTrack, track)
        guard !tracksShareNativeBacking else {
            scheduleRemoteVideoTrackConfirmationIfNeeded(trigger: "track-unchanged")
            return
        }
        let isTrackRebind =
            !currentTrackId.isEmpty
            && currentTrackId == incomingTrackId
            && track != nil
        if !incomingTrackId.isEmpty, isTrackRebind {
            SkyBridgeLogger.shared.info(
                "🔁 WebRTC 原生视频轨实例已更换，重新绑定 renderer: trackId=\(incomingTrackId)"
            )
        }
        let preservedFrameSize = remoteVideoTrackFrameSize
        let preservedFirstPacket = remoteVideoTrackHasReceivedFirstPacket
        let preservedReceiverFrameEvidence = remoteVideoTrackHasReceiverFrameEvidence

        if let currentTrack = remoteVideoTrack,
           let heartbeatRenderer = remoteVideoHeartbeatRenderer {
            currentTrack.remove(heartbeatRenderer)
        }

        remoteVideoTrackConfirmationTask?.cancel()
        remoteVideoTrackConfirmationTask = nil
        nativeVideoProbeTask?.cancel()
        nativeVideoProbeTask = nil
        nativeVideoProbeActive = false
        nativeVideoProbeCooldownUntil = .distantPast
        remoteVideoTrackRenderEpoch &+= 1
        remoteVideoTrackVisibleRenderTraceEpoch = nil
        lastNativeReceiverFrameStatusAt = .distantPast
        remoteVideoTrack = track
        let shouldPreservePacketEvidence = track != nil && isTrackRebind && preservedFirstPacket
        remoteVideoTrackReadyForPromotion = false
        remoteVideoTrackHasRenderedFrame = false
        remoteVideoTrackHasReceiverFrameEvidence = shouldPreservePacketEvidence ? preservedReceiverFrameEvidence : false
        nativeRenderEvidenceSource = nil
        nativeRenderUISurface = nil
        nativePromotionState = shouldPreservePacketEvidence ? "track-rebound" : "track-installed"
        remoteVideoTrackFrameSize = shouldPreservePacketEvidence ? preservedFrameSize : .zero
        remoteVideoTrackHasReceivedFirstPacket = shouldPreservePacketEvidence ? preservedFirstPacket : false
        remoteVideoTrackDetectedAt = track == nil
            ? nil
            : (isTrackRebind ? remoteVideoTrackDetectedAt ?? Date() : Date())
        remoteVideoHeartbeatRenderer = nil

        guard let track else {
            remoteVideoTrackReadyForPromotion = false
            remoteVideoTrackHasReceiverFrameEvidence = false
            nativeRenderEvidenceSource = nil
            nativeRenderUISurface = nil
            nativePromotionState = "idle"
            remoteVideoTrackHasReceivedFirstPacket = false
            nativeVideoProbeActive = false
            return
        }

        track.isEnabled = true
        SkyBridgeSmokeTraceWriter.appendStatus(
            "native-video-track-install trackId=\(track.trackId) enabled=\(track.isEnabled ? 1 : 0) epoch=\(remoteVideoTrackRenderEpoch)"
        )

        let heartbeatRenderer = RemoteVideoTrackHeartbeatRenderer()
        heartbeatRenderer.trackId = track.trackId
        heartbeatRenderer.sessionId = currentSessionId ?? "-"
        heartbeatRenderer.onSize = { [weak self] size in
            Task { @MainActor [weak self] in
                self?.noteRemoteVideoTrackResolutionAvailable(size, source: "heartbeat-set-size")
            }
        }
        heartbeatRenderer.onFrame = { [weak self] size in
            Task { @MainActor [weak self] in
                self?.noteRemoteVideoTrackRenderedFrame(size, source: "heartbeat-renderer")
            }
        }
        remoteVideoHeartbeatRenderer = heartbeatRenderer
        track.add(heartbeatRenderer)
        scheduleRemoteVideoTrackConfirmationIfNeeded(trigger: "track-installed")
        RemoteDesktopManager.instance.handleCrossNetworkNativeVideoWarmupEvidence(
            reason: "native-track-installed"
        )
        if remoteVideoTrackHasReceiverFrameEvidence {
            scheduleNativeRenderProbeIfNeeded(trigger: "track-installed")
        }
    }

    @MainActor
    func currentRemoteVideoTrackRenderToken(trackId: String?) -> UInt64 {
        let observedTrackId = trackId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let expectedTrackId = remoteVideoTrack?.trackId.trimmingCharacters(in: .whitespacesAndNewlines),
           !expectedTrackId.isEmpty,
           observedTrackId != expectedTrackId {
            return remoteVideoTrackRenderEpoch
        }
        return remoteVideoTrackRenderEpoch
    }

    @MainActor
    private func scheduleRemoteVideoTrackConfirmationIfNeeded(trigger: String) {
        guard currentSessionId != nil, remoteVideoTrack != nil else { return }
        guard !remoteVideoTrackHasRenderedFrame else { return }
        let sessionIdAtStart = currentSessionId
        remoteVideoTrackConfirmationTask?.cancel()
        remoteVideoTrackConfirmationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
            guard self.currentSessionId != nil, self.remoteVideoTrack != nil else { return }
            guard !self.remoteVideoTrackHasRenderedFrame else { return }
            guard self.bestAvailableRemoteVideoEvidenceSize() != nil else { return }
            do {
                try await Task.sleep(for: .milliseconds(2_650))
            } catch {
                return
            }
            guard self.currentSessionId == sessionIdAtStart,
                  self.remoteVideoTrack != nil,
                  !self.remoteVideoTrackHasRenderedFrame else { return }
            let probable = self.remoteVideoTrackHasReceivedFirstPacket
                ? "renderer-bound-no-native-frame"
                : "receiver-stats-zero-or-track-muted"
            SkyBridgeLogger.shared.warning(
                "⚠️ WebRTC 原生视频轨 3 秒内无真实渲染帧: session=\(self.currentSessionId ?? "-") probable=\(probable) firstPacket=\(self.remoteVideoTrackHasReceivedFirstPacket) fallbackEvidence=\(trigger)"
            )
        }
    }

    @MainActor
    private func scheduleNativeRenderProbeIfNeeded(
        trigger: String,
        allowsPacketOnlyEvidence: Bool = false
    ) {
        guard let sessionId = currentSessionId,
              let track = remoteVideoTrack else { return }
        guard remoteVideoTrackHasReceiverFrameEvidence || allowsPacketOnlyEvidence else { return }
        guard !remoteVideoTrackHasRenderedFrame else { return }
        guard !nativeVideoProbeActive else { return }
        let now = Date()
        guard now >= nativeVideoProbeCooldownUntil else { return }

        let trackId = track.trackId.trimmingCharacters(in: .whitespacesAndNewlines)
        let epoch = remoteVideoTrackRenderEpoch
        let evidenceSize = bestAvailableRemoteVideoEvidenceSize()
        let evidenceSizeLabel = evidenceSize.map { "\(Int($0.width))x\(Int($0.height))" } ?? "-"
        nativeVideoProbeTask?.cancel()
        nativeVideoProbeActive = true
        nativePromotionState = remoteVideoTrackHasReceiverFrameEvidence
            ? "native-render-probe-active"
            : "native-render-probe-packet-active"
        SkyBridgeLogger.shared.info(
            "🎬 native-render-probe-start session=\(sessionId) trackId=\(trackId.isEmpty ? "-" : trackId) epoch=\(epoch) trigger=\(trigger) receiverEvidence=\(remoteVideoTrackHasReceiverFrameEvidence) evidenceSize=\(evidenceSizeLabel) action=raise-rtc-mtl-video-view"
        )
        SkyBridgeSmokeTraceWriter.appendStatus(
            "native-render-probe-start session=\(sessionId) trackId=\(trackId.isEmpty ? "-" : trackId) epoch=\(epoch) trigger=\(trigger)"
        )
        nativeVideoProbeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(2_500))
            } catch {
                return
            }
            guard self.currentSessionId == sessionId,
                  self.remoteVideoTrack != nil,
                  self.remoteVideoTrackRenderEpoch == epoch,
                  !self.remoteVideoTrackHasRenderedFrame else {
                return
            }
            self.nativeVideoProbeActive = false
            self.nativeVideoProbeTask = nil
            self.nativeVideoProbeCooldownUntil = Date().addingTimeInterval(2.0)
            self.nativePromotionState = "native-render-probe-timeout"
            let size = self.bestAvailableRemoteVideoEvidenceSize()
            let sizeLabel = size.map { "\(Int($0.width))x\(Int($0.height))" } ?? "-"
            SkyBridgeLogger.shared.warning(
                "⚠️ native-render-probe-timeout session=\(sessionId) trackId=\(trackId.isEmpty ? "-" : trackId) epoch=\(epoch) trigger=\(trigger) receiverEvidence=\(self.remoteVideoTrackHasReceiverFrameEvidence) evidenceSize=\(sizeLabel) fallback=source-jpeg"
            )
            SkyBridgeSmokeTraceWriter.appendStatus(
                "native-render-probe-timeout session=\(sessionId) trackId=\(trackId.isEmpty ? "-" : trackId) epoch=\(epoch) trigger=\(trigger)"
            )
            self.scheduleRemoteVideoTrackConfirmationIfNeeded(trigger: "native-render-probe-timeout")
        }
    }

    @MainActor
    func noteRemoteVideoTrackRenderedFrame(_ size: CGSize, source: String) {
        noteRemoteVideoTrackRenderedFrame(
            size,
            source: source,
            uiSurface: "unknown",
            trackId: nil,
            renderEpoch: nil
        )
    }

    @MainActor
    func noteRemoteVideoTrackRenderedFrame(_ size: CGSize, source: String, trackId: String?) {
        noteRemoteVideoTrackRenderedFrame(
            size,
            source: source,
            uiSurface: "unknown",
            trackId: trackId,
            renderEpoch: nil
        )
    }

    @MainActor
    func noteRemoteVideoTrackRenderedFrame(
        _ size: CGSize,
        source: String,
        uiSurface: String,
        trackId: String?,
        renderEpoch: UInt64?
    ) {
        guard size.width > 0, size.height > 0 else { return }
        guard currentSessionId != nil else { return }
        let codedSize = size
        let normalizedFrameSize = normalizedNativeVideoVisibleFrameSize(forCodedSize: codedSize)
        let visibleSize = normalizedFrameSize.visibleSize
        if Self.isActualNativeRenderEvidence(source: source) {
            let hasInboundRenderContext =
                remoteVideoTrackHasRenderedFrame
                || nativeVideoProbeActive
                || remoteVideoTrackHasReceiverFrameEvidence
                || remoteVideoTrackHasReceivedFirstPacket
            guard hasInboundRenderContext else {
                SkyBridgeLogger.shared.debug(
                    "ℹ️ ignore stale native render evidence: source=\(source) reason=probe-inactive trackId=\(trackId ?? "-") epoch=\(renderEpoch.map(String.init) ?? "-")"
                )
                return
            }
            guard let expectedTrackId = remoteVideoTrack?.trackId.trimmingCharacters(in: .whitespacesAndNewlines),
                  !expectedTrackId.isEmpty else {
                SkyBridgeLogger.shared.debug(
                    "ℹ️ ignore stale native render evidence: source=\(source) reason=no-current-track"
                )
                return
            }
            let observedTrackId = trackId?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard observedTrackId == expectedTrackId else {
                SkyBridgeLogger.shared.debug(
                    "ℹ️ ignore stale native render evidence: source=\(source) reason=track-mismatch observedTrack=\(observedTrackId ?? "-") expectedTrack=\(expectedTrackId)"
                )
                return
            }
            guard let renderEpoch,
                  renderEpoch == remoteVideoTrackRenderEpoch else {
                SkyBridgeLogger.shared.debug(
                    "ℹ️ ignore stale native render evidence: source=\(source) reason=epoch-mismatch observedTrack=\(observedTrackId ?? "-") expectedTrack=\(expectedTrackId) observedEpoch=\(renderEpoch.map(String.init) ?? "-") expectedEpoch=\(remoteVideoTrackRenderEpoch)"
                )
                return
            }
        }
        noteCurrentSessionActivity()
        remoteVideoTrackFrameSize = visibleSize
        remoteVideoTrackHasReceivedFirstPacket = true
        if source == "receiver-stats" || source == "heartbeat-renderer" {
            let isReceiverStatsEvidence = source == "receiver-stats"
            nativePromotionState = isReceiverStatsEvidence
                ? "receiver-frame-evidence"
                : "track-renderer-frame-evidence"
            let visibleSource = normalizedFrameSize.usedEvenPadding
                ? "inferred-even-padding-from-stream-config"
                : "coded-frame"
            let now = Date()
            let shouldAppendReceiverStatus = !remoteVideoTrackHasReceiverFrameEvidence
                || now.timeIntervalSince(lastNativeReceiverFrameStatusAt) >= 5
            if shouldAppendReceiverStatus {
                lastNativeReceiverFrameStatusAt = now
                SkyBridgeSmokeTraceWriter.appendStatus(
                    "native-receiver-frame session=\(currentSessionId ?? "-") size=\(Int(visibleSize.width))x\(Int(visibleSize.height)) visibleSize=\(Int(visibleSize.width))x\(Int(visibleSize.height)) codedSize=\(Int(codedSize.width))x\(Int(codedSize.height)) evenPadding=\(normalizedFrameSize.usedEvenPadding ? 1 : 0) visibleSource=\(visibleSource) source=\(source)"
                )
            }
            if !remoteVideoTrackHasReceiverFrameEvidence {
                remoteVideoTrackHasReceiverFrameEvidence = true
                let warmupReason = isReceiverStatsEvidence
                    ? "native-receiver-frame-evidence"
                    : "native-heartbeat-frame-evidence"
                RemoteDesktopManager.instance.handleCrossNetworkNativeVideoWarmupEvidence(
                    reason: warmupReason
                )
            }
            scheduleRemoteVideoTrackConfirmationIfNeeded(trigger: source)
            scheduleNativeRenderProbeIfNeeded(trigger: source)
        }
        guard Self.isActualNativeRenderEvidence(source: source) else { return }
        nativeRenderEvidenceSource = source
        nativeRenderUISurface = uiSurface
        nativePromotionState = "visible-render-evidence"
        finishNativeRenderProbeAfterVisibleFrame()
        appendNativeRenderFrameTraceIfNeeded(
            visibleSize: visibleSize,
            codedSize: codedSize,
            source: source,
            uiSurface: uiSurface
        )
        markRemoteVideoTrackReadyForPromotion(size: visibleSize, source: source)
        remoteVideoTrackConfirmationTask?.cancel()
        remoteVideoTrackConfirmationTask = nil
        RemoteDesktopManager.instance.noteCrossNetworkNativeVideoFrame(visibleSize)
        if !remoteVideoTrackHasRenderedFrame {
            remoteVideoTrackHasRenderedFrame = true
            nativePromotionState = "native-ready-advertised"
            SkyBridgeLogger.shared.info(
                "🎬 WebRTC 原生视频轨已收到首帧: visible=\(Int(visibleSize.width))x\(Int(visibleSize.height)) coded=\(Int(codedSize.width))x\(Int(codedSize.height)) source=\(source) nativeRenderEvidenceSource=\(source) nativePromotionState=\(nativePromotionState)"
            )
            RemoteDesktopManager.instance.handleCrossNetworkNativeVideoTrackRenderedFirstFrame()
        }
    }

    @MainActor
    private func finishNativeRenderProbeAfterVisibleFrame() {
        nativeVideoProbeTask?.cancel()
        nativeVideoProbeTask = nil
        nativeVideoProbeActive = false
        nativeVideoProbeCooldownUntil = .distantPast
    }

    @MainActor
    private func appendNativeRenderFrameTraceIfNeeded(
        visibleSize: CGSize,
        codedSize: CGSize,
        source: String,
        uiSurface: String
    ) {
        guard remoteVideoTrackVisibleRenderTraceEpoch != remoteVideoTrackRenderEpoch else { return }
        remoteVideoTrackVisibleRenderTraceEpoch = remoteVideoTrackRenderEpoch
        SkyBridgeSmokeTraceWriter.appendStatus(
            "native-render-frame session=\(currentSessionId ?? "-") size=\(Int(visibleSize.width))x\(Int(visibleSize.height)) visibleSize=\(Int(visibleSize.width))x\(Int(visibleSize.height)) codedSize=\(Int(codedSize.width))x\(Int(codedSize.height)) source=\(source) nativeRenderEvidenceSource=\(source) nativePromotionState=\(nativePromotionState) uiSurface=\(uiSurface)"
        )
    }

    @MainActor
    private func normalizedNativeVideoVisibleFrameSize(
        forCodedSize codedSize: CGSize
    ) -> (visibleSize: CGSize, usedEvenPadding: Bool) {
        guard let expectedVisibleSize = expectedNativeVideoVisibleFrameSize() else {
            return (codedSize, false)
        }
        let expectedWidth = Int(expectedVisibleSize.width)
        let expectedHeight = Int(expectedVisibleSize.height)
        guard expectedWidth > 0, expectedHeight > 0 else {
            return (codedSize, false)
        }
        let codedWidth = Int(codedSize.width)
        let codedHeight = Int(codedSize.height)
        let expectedCodedWidth = Self.evenNativeVideoBackingDimension(expectedWidth)
        let expectedCodedHeight = Self.evenNativeVideoBackingDimension(expectedHeight)
        if codedWidth == expectedCodedWidth, codedHeight == expectedCodedHeight {
            return (expectedVisibleSize, expectedCodedWidth != expectedWidth || expectedCodedHeight != expectedHeight)
        }
        if codedWidth == expectedWidth, codedHeight == expectedHeight {
            return (expectedVisibleSize, false)
        }
        return (codedSize, false)
    }

    @MainActor
    private func expectedNativeVideoVisibleFrameSize() -> CGSize? {
        if let expected = RemoteDesktopManager.instance.expectedCrossNetworkNativeVideoVisibleFrameSize() {
            return expected
        }
        return Self.requestedSmokeNativeVideoVisibleFrameSize()
    }

    private static func requestedSmokeNativeVideoVisibleFrameSize() -> CGSize? {
        guard let width = positiveEnvironmentInteger("SKYBRIDGE_SMOKE_VIDEO_WIDTH"),
              let height = positiveEnvironmentInteger("SKYBRIDGE_SMOKE_VIDEO_HEIGHT") else {
            return nil
        }
        return CGSize(width: CGFloat(width), height: CGFloat(height))
    }

    private static func positiveEnvironmentInteger(_ name: String) -> Int? {
        guard let rawValue = ProcessInfo.processInfo.environment[name],
              let value = Int(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              value > 0 else {
            return nil
        }
        return value
    }

    private static func evenNativeVideoBackingDimension(_ visibleDimension: Int) -> Int {
        let sanitized = max(1, visibleDimension)
        return sanitized.isMultiple(of: 2) ? sanitized : sanitized + 1
    }

    @MainActor
    func noteRemoteVideoTrackReceivedFirstPacket(source: String) {
        guard currentSessionId != nil else { return }
        noteCurrentSessionActivity()
        remoteVideoTrackHasReceivedFirstPacket = true
        if remoteVideoTrackHasRenderedFrame { return }
        SkyBridgeLogger.shared.debug("ℹ️ WebRTC 原生视频轨已收到首个 RTP 包，等待分辨率证据后确认首帧 source=\(source)")
        scheduleNativeRenderProbeIfNeeded(trigger: source, allowsPacketOnlyEvidence: true)
    }

    @MainActor
    func noteRemoteAudioTrackReceivedFirstPacket(source: String) {
        guard currentSessionId != nil else { return }
        noteCurrentSessionActivity()
        remoteAudioTrackHasReceivedFirstPacket = true
        SkyBridgeLogger.shared.info("🎧 WebRTC 原生音频轨已收到首个 RTP 包 source=\(source)")
        RemoteDesktopManager.instance.handleCrossNetworkNativeAudioTrackReceivedFirstPacket()
    }

    @MainActor
    func noteRemoteVideoTrackResolutionAvailable(_ size: CGSize, source: String) {
        guard size.width > 0, size.height > 0 else { return }
        remoteVideoTrackFrameSize = normalizedNativeVideoVisibleFrameSize(forCodedSize: size).visibleSize
        if remoteVideoTrackHasRenderedFrame {
            return
        }
        if remoteVideoTrack != nil, Self.isActualNativeRenderEvidence(source: source) {
            scheduleRemoteVideoTrackConfirmationIfNeeded(trigger: source)
        } else if remoteVideoTrackHasReceiverFrameEvidence {
            scheduleNativeRenderProbeIfNeeded(trigger: source)
        }
    }

    @MainActor
    private func bestAvailableRemoteVideoEvidenceSize() -> CGSize? {
        if remoteVideoTrackFrameSize.width > 0, remoteVideoTrackFrameSize.height > 0 {
            return remoteVideoTrackFrameSize
        }
        if let lastScreenData,
           lastScreenData.width > 0,
           lastScreenData.height > 0 {
            return CGSize(width: lastScreenData.width, height: lastScreenData.height)
        }
        let managerResolution = RemoteDesktopManager.instance.resolution
        if managerResolution.width > 0, managerResolution.height > 0 {
            return managerResolution
        }
        return nil
    }

    @MainActor
    private func maybeConfirmRemoteVideoTrackFromFallbackEvidence(
        now: Date = Date(),
        minimumTrackAge: TimeInterval = 0.5,
        maximumFallbackSilence: TimeInterval = 0.4
    ) {
        guard currentSessionId != nil else { return }
        guard remoteVideoTrack != nil else { return }
        guard !remoteVideoTrackHasRenderedFrame else { return }
        guard let remoteVideoTrackDetectedAt else { return }
        guard now.timeIntervalSince(remoteVideoTrackDetectedAt) >= minimumTrackAge else { return }
        guard let lastScreenDataAt else { return }
        guard now.timeIntervalSince(lastScreenDataAt) <= maximumFallbackSilence else { return }
        guard bestAvailableRemoteVideoEvidenceSize() != nil else { return }
        guard now.timeIntervalSince(lastFallbackOnlyNativeVideoDiagnosticAt) >= 2.0 else { return }
        lastFallbackOnlyNativeVideoDiagnosticAt = now
        SkyBridgeLogger.shared.debug(
            "ℹ️ fallback screen data confirms only degraded screen path; native promotion still waits for real RTP/render evidence session=\(currentSessionId ?? "-")"
        )
    }

    @MainActor
    private func markRemoteVideoTrackReadyForPromotion(size: CGSize, source: String) {
        guard size.width > 0, size.height > 0 else { return }
        remoteVideoTrackFrameSize = size
        if !remoteVideoTrackReadyForPromotion {
            remoteVideoTrackReadyForPromotion = true
            nativePromotionState = "promotion-ready"
            SkyBridgeLogger.shared.info(
                "🎬 WebRTC 原生视频轨已由真实渲染证据触发 promotion 条件: \(Int(size.width))x\(Int(size.height)) source=\(source)"
            )
            RemoteDesktopManager.instance.handleCrossNetworkNativeVideoTrackPromotionReady()
        }
    }

    nonisolated private static func isActualNativeRenderEvidence(source: String) -> Bool {
        switch source {
        case "rtc-mtl-video-view":
            return true
        default:
            return false
        }
    }
#endif

    public func dismissIdleConnectionPrompt() {
        idleConnectionPrompt = nil
    }

    func remoteDesktopRecoveryDebugSummary() -> String {
        let stateLabel: String = {
            switch state {
            case .idle:
                return "idle"
            case .connecting(let sessionId):
                return "connecting:\(sessionId)"
            case .connected(let sessionId):
                return "connected:\(sessionId)"
            case .failed(let message):
                return "failed:\(message)"
            }
        }()
        let readinessLabel: String = {
            switch readiness {
            case .idle:
                return "idle"
            case .transportReady(let sessionId):
                return "transport_ready:\(sessionId)"
            case .handshakeComplete(let sessionId, let suite):
                return "handshake_complete:\(sessionId):\(suite)"
            }
        }()
        let signalingLabel: String = {
            switch signalingHealth {
            case .healthy:
                return "healthy"
            case .degradedRecoverable:
                return "degraded_recoverable"
            case .degradedFatal:
                return "degraded_fatal"
            }
        }()
        return "session=\(currentSessionId ?? "-") state=\(stateLabel) readiness=\(readinessLabel) signaling=\(signalingLabel) suppressRecovery=\(suppressSignalingRecovery)"
    }

    private func noteCurrentSessionActivity() {
        guard let currentSessionId else { return }
        noteRemoteAppActivity(sessionId: currentSessionId)
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

    static func resolvedSignalingWebSocketURLString(
        signalingOrigin: String?,
        fallbackWebSocketURL: String
    ) -> String {
        guard let rawOrigin = signalingOrigin?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawOrigin.isEmpty,
              let originURL = URL(string: rawOrigin),
              let scheme = originURL.scheme?.lowercased(),
              let host = originURL.host,
              !host.isEmpty else {
            return fallbackWebSocketURL
        }

        let websocketScheme: String
        switch scheme {
        case "https":
            websocketScheme = "wss"
        case "http":
            websocketScheme = "ws"
        default:
            return fallbackWebSocketURL
        }

        var components = URLComponents()
        components.scheme = websocketScheme
        components.host = host
        components.port = originURL.port
        let originPath = originURL.path.trimmingCharacters(in: .whitespacesAndNewlines)
        if originPath.isEmpty || originPath == "/" {
            components.path = "/ws"
        } else if originPath.hasSuffix("/ws") {
            components.path = originPath
        } else {
            components.path = originPath + "/ws"
        }
        return components.url?.absoluteString ?? fallbackWebSocketURL
    }

    static func shouldScheduleSignalingRecovery(
        isTransportEstablished: Bool,
        isSessionConnecting: Bool,
        suppressRecovery: Bool
    ) -> Bool {
        (isTransportEstablished || isSessionConnecting) && !suppressRecovery
    }

    static func shouldDeferSignalingSendRecovery(
        isHandshakeComplete: Bool,
        suppressRecovery: Bool,
        messageType: WebRTCSignalingEnvelope.MessageType
    ) -> Bool {
        isHandshakeComplete && !suppressRecovery && messageType != .leave
    }

    static func shouldDeferSignalingSendRecovery(
        isTransportEstablished: Bool,
        suppressRecovery: Bool,
        messageType: WebRTCSignalingEnvelope.MessageType
    ) -> Bool {
        shouldDeferSignalingSendRecovery(
            isHandshakeComplete: isTransportEstablished,
            suppressRecovery: suppressRecovery,
            messageType: messageType
        )
    }

    static func shouldUseOnDemandSignalingAfterTransportFailure(
        isHandshakeComplete: Bool,
        suppressRecovery: Bool
    ) -> Bool {
        isHandshakeComplete && !suppressRecovery
    }

    private func shouldScheduleSignalingRecovery(for sessionId: String) -> Bool {
        Self.shouldScheduleSignalingRecovery(
            isTransportEstablished: isTransportEstablished(for: sessionId),
            isSessionConnecting: isSessionConnecting(for: sessionId),
            suppressRecovery: suppressSignalingRecovery
        )
    }

    private func isSessionConnecting(for sessionId: String) -> Bool {
        guard currentSessionId == sessionId else { return false }
        if case .connecting(let activeSessionId) = state {
            return activeSessionId == sessionId
        }
        return false
    }

    private func signalingURL(shardKey: String? = nil) throws -> URL {
        let baseWebSocketURLString = Self.resolvedSignalingWebSocketURLString(
            signalingOrigin: shardKey.flatMap { currentPathSignalingOriginBySessionId[$0] },
            fallbackWebSocketURL: CrossNetworkServerConfig.signalingWebSocketURL
        )
        guard let wsURL = SignalingRetryController.validatedWebSocketURL(
            baseWebSocketURLString
        ) else {
            throw SignalingRetryControllerError.invalidWebSocketURL(
                baseWebSocketURLString
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
            let previousShardKey = signalingShardKey
            appendSmokeTrace("signaling reset shard=\(signalingShardKey ?? "-")->\(normalizedShardKey ?? "-")")
            await signaling.close()
            self.signaling = nil
            signalingShardKey = nil
            signalingHealth = .healthy
            if let previousShardKey {
                signalingGenerationBySessionId.removeValue(forKey: previousShardKey)
                activeSignalingHandleBySessionId.removeValue(forKey: previousShardKey)
            }
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
                self.handleSignalingLifecycleEvent(event, sessionId: sessionId)
            }
        }
        appendSmokeTrace("signaling connect shard=\(sessionId) url=\(WebSocketSignalingClient.redactedURLString(wsURL))")
        try await newSignaling.connectOrThrow()
    }

    private func signalingGeneration(for sessionId: String) -> Int {
        signalingGenerationBySessionId[sessionId] ?? 0
    }

    private func handleSignalingLifecycleEvent(
        _ event: WebSocketSignalingClient.SignalingLifecycleEvent,
        sessionId: String
    ) {
        guard event.handleId.sessionId == sessionId else { return }

        if event.phase == .connecting || event.phase == .reconnecting {
            guard event.handleId.generation >= signalingGeneration(for: sessionId) else { return }
            signalingGenerationBySessionId[sessionId] = event.handleId.generation
            activeSignalingHandleBySessionId[sessionId] = event.handleId
        }

        guard event.handleId.generation == signalingGeneration(for: sessionId) else { return }
        guard activeSignalingHandleBySessionId[sessionId] == event.handleId else { return }

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
            signalingHealth = .healthy
            SkyBridgeLogger.shared.info(
                "♻️ signaling health recovered: session=\(sessionId) phase=bound summary=\(remoteDesktopRecoveryDebugSummary())"
            )
        case .closed:
            if Self.shouldUseOnDemandSignalingAfterTransportFailure(
                isHandshakeComplete: isHandshakeComplete(for: sessionId),
                suppressRecovery: suppressSignalingRecovery
            ) {
                noteDetachedSignalingAfterTransportEstablished(
                    sessionId: sessionId,
                    source: "lifecycle_closed",
                    failure: "transient_network"
                )
            }
        case .failed:
            if suppressSignalingRecovery {
                break
            }
            if Self.shouldUseOnDemandSignalingAfterTransportFailure(
                isHandshakeComplete: isHandshakeComplete(for: sessionId),
                suppressRecovery: suppressSignalingRecovery
            ) {
                noteDetachedSignalingAfterTransportEstablished(
                    sessionId: sessionId,
                    source: "lifecycle_failed",
                    failure: String(describing: failureKind),
                    fatal: isFatalPostTransportFailure(failureKind)
                )
            } else if isFatalPreTransportFailure(failureKind) {
                signalingHealth = .degradedFatal
                SkyBridgeLogger.shared.error(
                    "❌ signaling health fatal: session=\(sessionId) phase=failed preTransport=true summary=\(remoteDesktopRecoveryDebugSummary())"
                )
            } else {
                signalingHealth = .degradedRecoverable
                let recoveryScheduled = scheduleSignalingRecovery(
                    for: sessionId,
                    tokenExpired: failureKind == .tokenExpired
                )
                SkyBridgeLogger.shared.warning(
                    "⚠️ signaling health degraded: session=\(sessionId) phase=failed recoveryScheduled=\(recoveryScheduled) summary=\(remoteDesktopRecoveryDebugSummary())"
                )
            }
        default:
            break
        }
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
        let handshakeComplete = isHandshakeComplete(for: authorizedEnvelope.sessionId)
        let shouldDeferRecovery = Self.shouldDeferSignalingSendRecovery(
            isHandshakeComplete: handshakeComplete,
            suppressRecovery: suppressSignalingRecovery,
            messageType: authorizedEnvelope.type
        )
        appendSmokeTrace("tx \(describeEnvelope(authorizedEnvelope)) retries=\(retries)")
        if shouldDeferRecovery {
            guard let signaling else {
                signalingHealth = .degradedRecoverable
                appendSmokeTrace(
                    "tx-suppressed-detached \(describeEnvelope(authorizedEnvelope)) phase=missing_client"
                )
                SkyBridgeLogger.shared.debug(
                    "ℹ️ suppress detached post-transport signaling send: session=\(authorizedEnvelope.sessionId) type=\(authorizedEnvelope.type.rawValue) phase=missing_client"
                )
                return
            }

            let lifecyclePhase = await signaling.currentLifecyclePhase()
            guard lifecyclePhase == .bound else {
                signalingHealth = .degradedRecoverable
                appendSmokeTrace(
                    "tx-suppressed-detached \(describeEnvelope(authorizedEnvelope)) phase=\(lifecyclePhase.rawValue)"
                )
                SkyBridgeLogger.shared.debug(
                    "ℹ️ suppress detached post-transport signaling send: session=\(authorizedEnvelope.sessionId) type=\(authorizedEnvelope.type.rawValue) phase=\(lifecyclePhase.rawValue)"
                )
                return
            }

            do {
                try await signaling.send(authorizedEnvelope)
                appendSmokeTrace("tx-ok \(describeEnvelope(authorizedEnvelope))")
                return
            } catch {
                signalingHealth = .degradedRecoverable
                appendSmokeTrace(
                    "tx-suppressed-detached \(describeEnvelope(authorizedEnvelope)) phase=\(lifecyclePhase.rawValue) error=\(error.localizedDescription)"
                )
                SkyBridgeLogger.shared.debug(
                    "ℹ️ suppress detached post-transport signaling send: session=\(authorizedEnvelope.sessionId) type=\(authorizedEnvelope.type.rawValue) phase=\(lifecyclePhase.rawValue) error=\(error.localizedDescription)"
                )
                return
            }
        }
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
            failConnectingSessionIfNeeded(
                sessionId: authorizedEnvelope.sessionId,
                reason: lastError ?? "信令服务 URL 无效",
                trigger: "send_invalid_url_\(authorizedEnvelope.type.rawValue)"
            )
        } catch SignalingRetryControllerError.attemptTimedOut {
            lastError = "信令发送失败: 请求超时"
            appendSmokeTrace("tx-fail \(describeEnvelope(authorizedEnvelope)) error=attempt_timed_out")
            failConnectingSessionIfNeeded(
                sessionId: authorizedEnvelope.sessionId,
                reason: lastError ?? "信令发送失败: 请求超时",
                trigger: "send_timeout_\(authorizedEnvelope.type.rawValue)"
            )
        } catch is CancellationError {
            appendSmokeTrace("tx-cancel \(describeEnvelope(authorizedEnvelope))")
            return
        } catch {
            lastError = "信令发送失败: \(error.localizedDescription)"
            appendSmokeTrace("tx-fail \(describeEnvelope(authorizedEnvelope)) error=\(error.localizedDescription)")
            failConnectingSessionIfNeeded(
                sessionId: authorizedEnvelope.sessionId,
                reason: lastError ?? "信令发送失败",
                trigger: "send_error_\(authorizedEnvelope.type.rawValue)"
            )
        }
    }

    private func failConnectingSessionIfNeeded(
        sessionId: String,
        reason: String,
        trigger: String
    ) {
        guard currentSessionId == sessionId else { return }
        guard isSessionConnecting(for: sessionId) else { return }

        let message = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }

        SkyBridgeLogger.shared.error(
            "❌ cross-network connect failed before transportReady: session=\(sessionId) trigger=\(trigger) err=\(message)"
        )
        applyActiveSessionDisconnect(sessionId: sessionId, kind: .explicit)
        state = .failed(message)
        readiness = .idle
    }

    private func handleServerFrame(_ frame: WebSocketSignalingClient.SignalingServerFrame) {
        appendSmokeTrace(
            "server-frame type=\(frame.type) session=\(frame.sessionId ?? "-") error=\(frame.error ?? "-") what=\(frame.what ?? "-")"
        )
        guard frame.isError else { return }
        let sessionId = frame.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = frame.error ?? "unknown_signaling_error"
        let failureClass = classifySignalingFailureReason(reason)

        if sessionId == nil,
           reason == "server_error",
           isTransportEstablished {
            SkyBridgeLogger.shared.warning("ℹ️ ignore unscoped signaling server_error after transport establishment")
            return
        }

        guard let sessionId else {
            SkyBridgeLogger.shared.error("❌ signaling server rejected frame: session=- error=\(reason)")
            lastError = "Signaling error: \(reason)"
            state = .failed(lastError ?? "Signaling error")
            readiness = .idle
            return
        }

        guard currentSessionId == sessionId else { return }
        if suppressSignalingRecovery { return }

        if Self.shouldUseOnDemandSignalingAfterTransportFailure(
            isHandshakeComplete: isHandshakeComplete(for: sessionId),
            suppressRecovery: suppressSignalingRecovery
        ) {
            noteDetachedSignalingAfterTransportEstablished(
                sessionId: sessionId,
                source: "server_frame",
                failure: reason,
                fatal: isFatalPostTransportFailure(failureClass)
            )
            return
        }

        SkyBridgeLogger.shared.error("❌ signaling server rejected frame: session=\(sessionId) error=\(reason)")
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

    private func isHandshakeComplete(for sessionId: String) -> Bool {
        if case .handshakeComplete(let activeSessionId, _) = readiness {
            return activeSessionId == sessionId
        }
        return false
    }

    private func noteDetachedSignalingAfterTransportEstablished(
        sessionId: String,
        source: String,
        failure: String? = nil,
        fatal: Bool = false
    ) {
        let previousHealth = signalingHealth
        signalingHealth = fatal ? .degradedFatal : .degradedRecoverable

        let failureSuffix: String
        if let failure,
           !failure.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            failureSuffix = " failure=\(failure)"
        } else {
            failureSuffix = ""
        }

        let rendered =
            "ℹ️ signaling detached after transport establishment: session=\(sessionId) source=\(source) fatal=\(fatal ? 1 : 0)\(failureSuffix) summary=\(remoteDesktopRecoveryDebugSummary())"
        if previousHealth == .healthy {
            SkyBridgeLogger.shared.info(rendered)
        } else {
            SkyBridgeLogger.shared.debug(rendered)
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

    @discardableResult
    private func scheduleSignalingRecovery(for sessionId: String, tokenExpired: Bool = false) -> Bool {
        guard shouldScheduleSignalingRecovery(for: sessionId) else { return false }
        if let existingTask = signalingRecoveryTasksBySessionId[sessionId],
           !existingTask.isCancelled {
            return false
        }
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
                        SkyBridgeLogger.shared.info(
                            "♻️ signaling recovery succeeded: session=\(sessionId) attempt=\(attempt + 1) summary=\(self.remoteDesktopRecoveryDebugSummary())"
                        )
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
                        "⚠️ signaling recovery failed: session=\(sessionId) attempt=\(attempt + 1) err=\(error.localizedDescription) summary=\(self.remoteDesktopRecoveryDebugSummary())"
                    )
                }
            }
            if tokenExpired, self.isHandshakeComplete(for: sessionId) {
                self.signalingHealth = .degradedFatal
                SkyBridgeLogger.shared.error(
                    "❌ signaling recovery exhausted after token expiry: session=\(sessionId) summary=\(self.remoteDesktopRecoveryDebugSummary())"
                )
            }
            self.signalingRecoveryTasksBySessionId.removeValue(forKey: sessionId)
        }
        return true
    }

    private func stopJoinHeartbeat() {
        joinHeartbeatTask?.cancel()
        joinHeartbeatTask = nil
    }

    private func startJoinHeartbeat(
        sessionId: String,
        localId: String,
        signaling expectedSignaling: WebSocketSignalingClient,
        attempts: Int = CrossNetworkWebRTCManager.webRTCStartupJoinHeartbeatAttempts
    ) {
        stopJoinHeartbeat()
        joinHeartbeatTask = Task { @MainActor [weak self] in
            guard let self else { return }
            SkyBridgeLogger.shared.info("🌐 join heartbeat start: session=\(sessionId) attempts=\(attempts)")
            var remaining = max(0, attempts)
            while remaining > 0,
                  !Task.isCancelled,
                  self.currentSessionId == sessionId,
                  self.signaling === expectedSignaling {
                if self.isTransportEstablished(for: sessionId) {
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

            guard !Task.isCancelled,
                  self.currentSessionId == sessionId,
                  self.signaling === expectedSignaling else { return }

            if self.isTransportEstablished(for: sessionId) {
                SkyBridgeLogger.shared.info("🌐 join heartbeat stop after transport established: session=\(sessionId)")
                return
            }

            let message = "等待远端 offer / answer 超时"
            self.lastError = message
            SkyBridgeLogger.shared.error("❌ join heartbeat exhausted before transportReady: session=\(sessionId)")
            self.applyActiveSessionDisconnect(sessionId: sessionId, kind: .explicit)
            self.state = .failed(message)
            self.readiness = .idle
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
                let mediaDiagnostics = await self.smokeMediaHeartbeatDiagnosticsProvider?()

                let heartbeat = AppMessage.heartbeat(.init(
                    sentAt: Date(),
                    deviceId: self.localDeviceId,
                    deviceName: localName,
                    modelName: localModel,
                    platform: "iOS",
                    osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                    chip: nil,
                    remoteVideoFormats: RemoteDesktopManager.supportedRemoteVideoFormats(),
                    webrtcMedia: mediaDiagnostics
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

    nonisolated static func isReusableConnectionCodeLease(
        expiresAt: Date?,
        now: Date = Date(),
        minimumRemainingTime: TimeInterval = connectionCodeMinimumReusableTime
    ) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) > minimumRemainingTime
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

    private func reuseCachedRedeemedSessionArtifactsIfPossible(
        for qr: DynamicQRCodeData,
        canonicalOrigin: String
    ) -> Bool {
        let signalingToken = Self.normalizedNonEmptyToken(webrtcSignalingAuthTokenBySessionId[qr.sessionID])
        let turnAdmissionToken = Self.normalizedNonEmptyToken(webrtcTurnAdmissionTokenBySessionId[qr.sessionID])
        let mediaAdmissionToken = Self.normalizedNonEmptyToken(webrtcMediaAdmissionTokenBySessionId[qr.sessionID])
        let cachedOrigin = currentPathSignalingOriginBySessionId[qr.sessionID]
            .flatMap { try? validateCurrentPathOrigin($0) }
        let cachedAuthority = currentPathExpectedRemoteAuthorityBySessionId[qr.sessionID]

        guard mediaAdmissionToken != nil,
              Self.shouldReuseRedeemedQRSessionArtifacts(
            canonicalQRSignalingOrigin: canonicalOrigin,
            qrDeviceId: qr.deviceID,
            qrProtocolSigningAlgorithm: qr.protocolSigningAlgorithm,
            qrProtocolPublicKeyFingerprint: qr.protocolPublicKeyFingerprint,
            qrProtocolPublicKeyBytes: qr.protocolPublicKeyBytes,
            signalingToken: signalingToken,
            turnAdmissionToken: turnAdmissionToken,
            cachedSignalingOrigin: cachedOrigin,
            cachedAuthority: cachedAuthority
        ) else {
            return false
        }

        let effectivePublicKeyBytes: Data? = {
            if !qr.protocolPublicKeyBytes.isEmpty {
                return qr.protocolPublicKeyBytes
            }
            return cachedAuthority?.protocolPublicKeyBytes
        }()
        webrtcSignalingAuthTokenBySessionId[qr.sessionID] = signalingToken
        webrtcTurnAdmissionTokenBySessionId[qr.sessionID] = turnAdmissionToken
        webrtcMediaAdmissionTokenBySessionId[qr.sessionID] = mediaAdmissionToken
        currentPathSignalingOriginBySessionId[qr.sessionID] = canonicalOrigin
        currentPathExpectedRemoteAuthorityBySessionId[qr.sessionID] = CurrentPathRemoteAuthorityCompat(
            deviceId: qr.deviceID,
            protocolSigningAlgorithm: qr.protocolSigningAlgorithm,
            protocolPublicKeyFingerprint: qr.protocolPublicKeyFingerprint,
            protocolPublicKeyBytes: effectivePublicKeyBytes,
            deviceName: qr.deviceName
        )
        return true
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
        SkyBridgeLogger.shared.info("🌐 QR parse phase=decoded session=\(qr.sessionID) device=\(qr.deviceID)")
        let canonicalOrigin = try validateCurrentPathOrigin(qr.signalingServerOrigin)
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
        SkyBridgeLogger.shared.info("🌐 QR parse phase=verified session=\(qr.sessionID)")
        noteVerifiedQRCodeAuthority(
            deviceId: qr.deviceID,
            protocolPublicKeyFingerprint: qr.protocolPublicKeyFingerprint
        )
        try enforceCurrentPathTrustBinding(
            deviceId: qr.deviceID,
            protocolPublicKeyFingerprint: qr.protocolPublicKeyFingerprint,
            rebindSource: .verifiedQRCode
        )
        SkyBridgeLogger.shared.info("🌐 QR parse phase=trust_binding_ok session=\(qr.sessionID)")
        if reuseCachedRedeemedSessionArtifactsIfPossible(for: qr, canonicalOrigin: canonicalOrigin) {
            SkyBridgeLogger.shared.info(
                "♻️ 复用已兑换的 QR signaling artifacts: session=\(qr.sessionID) device=\(qr.deviceID)"
            )
            SkyBridgeLogger.shared.debug("ℹ️ iOS QR 仅完成内容完整性校验；设备来源认证仍依赖后续握手/pinning")
            return qr
        }
        let localBinding = try await currentPathLocalBinding()
        SkyBridgeLogger.shared.info("🌐 QR parse phase=local_binding_ready device=\(localBinding.deviceId)")
        let admission = try await requestAdmissionLease(for: localBinding)
        SkyBridgeLogger.shared.info("🌐 QR parse phase=admission_ready")
        let redeemed = try await signalServer.redeemSession(
            admissionToken: admission.token,
            sessionId: qr.sessionID,
            qrBootstrapToken: qr.qrBootstrapToken
        )
        SkyBridgeLogger.shared.info("🌐 QR parse phase=redeem_ready session=\(redeemed.sessionID) initiator=\(redeemed.initiatorDeviceId)")
        let redeemedOrigin = try validateCurrentPathOrigin(redeemed.signalingServerOrigin)
        guard redeemed.initiatorDeviceId == qr.deviceID,
              redeemed.initiatorProtocolSigningAlgorithm == qr.protocolSigningAlgorithm,
              redeemed.initiatorProtocolPublicKeyFingerprint == qr.protocolPublicKeyFingerprint else {
            throw ConnectLinkError.invalidSignature
        }
        webrtcSignalingAuthTokenBySessionId[qr.sessionID] = redeemed.sessionToken
        webrtcTurnAdmissionTokenBySessionId[qr.sessionID] = redeemed.turnAdmissionToken
        if let mediaAdmissionToken = redeemed.mediaAdmissionToken {
            webrtcMediaAdmissionTokenBySessionId[qr.sessionID] = mediaAdmissionToken
        }
        currentPathSignalingOriginBySessionId[qr.sessionID] = redeemedOrigin
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

    nonisolated private static func normalizedNonEmptyToken(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    nonisolated private static func tokenGenerationPrefix(_ token: String?) -> String? {
        guard let token = normalizedNonEmptyToken(token) else { return nil }
        return SHA256.hash(data: Data(token.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    nonisolated private static func shouldReuseRedeemedQRSessionArtifacts(
        canonicalQRSignalingOrigin: String,
        qrDeviceId: String,
        qrProtocolSigningAlgorithm: ProtocolSigningAlgorithm,
        qrProtocolPublicKeyFingerprint: String,
        qrProtocolPublicKeyBytes: Data,
        signalingToken: String?,
        turnAdmissionToken: String?,
        cachedSignalingOrigin: String?,
        cachedAuthority: CurrentPathRemoteAuthorityCompat?
    ) -> Bool {
        guard signalingToken != nil,
              turnAdmissionToken != nil,
              cachedSignalingOrigin == canonicalQRSignalingOrigin,
              let cachedAuthority else {
            return false
        }
        guard cachedAuthority.deviceId == qrDeviceId,
              cachedAuthority.protocolSigningAlgorithm == qrProtocolSigningAlgorithm,
              cachedAuthority.protocolPublicKeyFingerprint == qrProtocolPublicKeyFingerprint else {
            return false
        }
        if let cachedKeyBytes = cachedAuthority.protocolPublicKeyBytes,
           !qrProtocolPublicKeyBytes.isEmpty,
           !cachedKeyBytes.isEmpty,
           cachedKeyBytes != qrProtocolPublicKeyBytes {
            return false
        }
        return true
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
        let preservedMediaAdmissionToken = webrtcMediaAdmissionTokenBySessionId[sessionId]
        let preservedSignalingOrigin = currentPathSignalingOriginBySessionId[sessionId]
        let preservedRemoteAuthority = currentPathExpectedRemoteAuthorityBySessionId[sessionId]
        let preservedAdditionalFingerprints = currentPathAdditionalProtocolFingerprintsBySessionId[sessionId]

        if signaling != nil || session != nil || currentSessionId != nil {
            await disconnect()
            if let preservedSignalingToken {
                webrtcSignalingAuthTokenBySessionId[sessionId] = preservedSignalingToken
            }
            if let preservedTurnAdmissionToken {
                webrtcTurnAdmissionTokenBySessionId[sessionId] = preservedTurnAdmissionToken
            }
            if let preservedMediaAdmissionToken {
                webrtcMediaAdmissionTokenBySessionId[sessionId] = preservedMediaAdmissionToken
            }
            if let preservedSignalingOrigin {
                currentPathSignalingOriginBySessionId[sessionId] = preservedSignalingOrigin
            }
            if let preservedRemoteAuthority {
                currentPathExpectedRemoteAuthorityBySessionId[sessionId] = preservedRemoteAuthority
            }
            if let preservedAdditionalFingerprints {
                currentPathAdditionalProtocolFingerprintsBySessionId[sessionId] = preservedAdditionalFingerprints
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
            activeConnectionCodeAuthorityDeviceId = nil
            activeConnectionCodeAuthorityFingerprint = nil
            authorityBoundWebRTCBootstrapSessionIds.remove(sessionId)
            clearStrictPQCClassicBootstrapOnly(sessionId: sessionId)
        }

        // 1) WebSocket signaling
        do {
            try await ensureSignalingConnected(shardKey: sessionId)
            SkyBridgeLogger.shared.info("🌐 cross-network phase=signaling_bound session=\(sessionId)")
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

        let nativeAudioReceiveEnabled = self.nativeAudioReceiveEnabled
        let s = WebRTCSession(
            sessionId: sessionId,
            localDeviceId: localId,
            role: role,
            ice: ice,
            nativeAudioReceiveEnabled: nativeAudioReceiveEnabled
        )
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
        s.onRemoteVideoFrameEvidence = { [weak self] size, source in
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.currentSessionId == sessionId,
                      self.session === s else { return }
                self.noteRemoteVideoTrackRenderedFrame(size, source: source)
            }
        }
        s.onRemoteVideoFirstPacket = { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.currentSessionId == sessionId,
                      self.session === s else { return }
                self.noteRemoteVideoTrackReceivedFirstPacket(source: "receiver-first-packet")
            }
        }
        if nativeAudioReceiveEnabled {
            s.onRemoteAudioFirstPacket = { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.currentSessionId == sessionId,
                          self.session === s else { return }
                    self.noteRemoteAudioTrackReceivedFirstPacket(source: "receiver-first-packet")
                }
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
        let orderedInboundRelay = OrderedInboundChunkRelay()
        let orderedScreenInboundRelay = OrderedInboundChunkRelay()
        self.inboundQueue = inbound
        self.screenInboundQueue = screenInbound
        s.onData = { data in
            orderedInboundRelay.submit { [weak self] in
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
            orderedScreenInboundRelay.submit { [weak self] in
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

                let bootstrapPlan: (shouldConfigure: Bool, shouldInitiate: Bool) = await MainActor.run {
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
                        return (
                            true,
                            Self.shouldInitiateInitialWebRTCHandshake(role: role)
                        )
                    }
                    return (false, false)
                }

                if bootstrapPlan.shouldConfigure {
                    let peerDeviceId = await MainActor.run {
                        self.remoteDeviceId ?? self.handshakePeerId ?? "webrtc-\(sessionId)"
                    }
                    await self.startHandshakeOverWebRTC(
                        sessionId: sessionId,
                        peerDeviceId: peerDeviceId,
                        session: s,
                        inbound: inbound,
                        shouldInitiate: bootstrapPlan.shouldInitiate
                    )
                } else {
                    SkyBridgeLogger.shared.debug("ℹ️ skip duplicate WebRTC handshake start: session=\(sessionId)")
                }
            }
        }

        try s.start()
        SkyBridgeLogger.shared.info("🌐 cross-network phase=session_started session=\(sessionId) role=\(role == .offerer ? "offerer" : "answerer")")
        appendSmokeTrace("session-started session=\(sessionId) role=\(role == .offerer ? "offerer" : "answerer")")

        screenReceiveTask?.cancel()
        let screenSessionObjectIdentifier = ObjectIdentifier(s)
        screenReceiveTask = Task {
            defer { orderedScreenInboundRelay.cancel() }
            await self.receiveScreenLoop(
                sessionId: sessionId,
                sessionObjectIdentifier: screenSessionObjectIdentifier,
                inbound: screenInbound
            )
        }

        // 3) Join room + heartbeat to mask websocket timing jitters.
        await sendEnvelope(WebRTCSignalingEnvelope(sessionId: sessionId, from: localId, type: .join, payload: nil), retries: 2)
        SkyBridgeLogger.shared.info("🌐 cross-network phase=join_sent session=\(sessionId)")
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

enum SkyBridgeSmokeTraceWriter {
    static func appendStatus(_ line: String) {
        append(line, suffix: "")
    }

    static func append(_ line: String) {
        append(line, suffix: ".trace.log")
    }

    private static func append(_ line: String, suffix: String) {
        guard ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil else { return }
        let fileName = ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_STATUS_BASENAME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "skybridge-smoke-status.log"
        guard !fileName.isEmpty,
              let baseCaches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return
        }
        let url = baseCaches.appendingPathComponent("\(fileName)\(suffix)")
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

    static func appendMediaDiagnostic(_ fields: [String: Any]) {
        guard ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil else { return }
        let fileName = ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_STATUS_BASENAME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "skybridge-smoke-status.log"
        guard !fileName.isEmpty,
              let baseCaches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return
        }
        let url = baseCaches.appendingPathComponent("\(fileName).webrtc-media.jsonl")
        var payload = fields
        payload["schema_version"] = payload["schema_version"] ?? 1
        payload["timestamp"] = payload["timestamp"] ?? ISO8601DateFormatter().string(from: Date())
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return
        }
        var line = data
        line.append(0x0a)
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? line.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
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
private enum RemoteDesktopControlPayloadDecodeResult: Sendable {
    case screen(ScreenData)
    case audio(RemoteDesktopAudioChunkPayload)
}

final class OrderedInboundChunkRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var tailTask: Task<Void, Never>?

    func submit(_ operation: @escaping @Sendable () async -> Void) {
        lock.lock()
        let previous = tailTask
        let next = Task {
            _ = await previous?.result
            guard !Task.isCancelled else { return }
            await operation()
        }
        tailTask = next
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let task = tailTask
        tailTask = nil
        lock.unlock()
        task?.cancel()
    }
}

@available(iOS 17.0, *)
private extension CrossNetworkWebRTCManager {
    func startHandshakeOverWebRTC(
        sessionId: String,
        peerDeviceId: String,
        session: WebRTCSession,
        inbound: InboundChunkQueue,
        shouldInitiate: Bool
    ) async {
        do {
            let compatibilityModeEnabled = UserDefaults.standard.bool(forKey: "Settings.EnableCompatibilityMode")
            let strictPQCRequested = shouldRequestStrictPQC(compatibilityModeEnabled: compatibilityModeEnabled)
            strictPQCRequestedBySessionId[sessionId] = strictPQCRequested

            let peer = PeerIdentifier(deviceId: peerDeviceId)

            // Keep the control-channel receive loop alive for both the initial handshake
            // and any later rekey/app traffic. The answerer must install this before it
            // can respond to the offerer's first MessageA.
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

            guard shouldInitiate else {
                SkyBridgeLogger.shared.info(
                    "🤝 WebRTC 等待对端发起初始握手: session=\(sessionId), role=\(String(describing: session.role)), strictPQC=\(strictPQCRequested)"
                )
                return
            }

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
            let useClassicAuthorityBootstrap = false
            let selection: CryptoProviderFactory.SelectionPolicy
            if !hasTrustedPeerKEMKey {
                if strictPQCRequested {
                    let message =
                        "严格 PQC 已启用，但跨网对端缺少已信任的 KEM 公钥；当前已拒绝 classic bootstrap。peer=\(peerDeviceId)"
                    SkyBridgeLogger.shared.error("⛔️ \(message)")
                    throw NSError(
                        domain: "CrossNetworkWebRTCManager",
                        code: 41,
                        userInfo: [NSLocalizedDescriptionKey: message]
                    )
                }
                selection = .classicOnly
            } else if strictPQCRequested {
                if capability.hasApplePQC || capability.hasLiboqs {
                    selection = .requirePQC
                } else {
                    let message =
                        "严格 PQC 已启用，但当前设备没有可用的 PQC Provider；跨网路径不会再降级到 Classic/PreferPQC。"
                    SkyBridgeLogger.shared.error(
                        "⛔️ \(message) hasApplePQC=\(capability.hasApplePQC), hasLiboqs=\(capability.hasLiboqs)"
                    )
                    throw NSError(
                        domain: "CrossNetworkWebRTCManager",
                        code: 42,
                        userInfo: [NSLocalizedDescriptionKey: message]
                    )
                }
            } else {
                selection = .requirePQC
            }
            SkyBridgeLogger.shared.info(
                "🤝 WebRTC handshake bootstrap: session=\(sessionId), policy=\(selection.rawValue), " +
                "compatMode=\(compatibilityModeEnabled), hasApplePQC=\(capability.hasApplePQC), hasLiboqs=\(capability.hasLiboqs), " +
                "peer=\(peerDeviceId), trustedKEM=\(hasTrustedPeerKEMKey), trustPeer=\(trustLookupPeerId), authorityBootstrap=\(useClassicAuthorityBootstrap)"
            )
            let transport = makeHandshakeTransport(over: session)
            let currentPathTrustProvider = CurrentPathHandshakeTrustProviderCompat(
                expectedRemoteAuthority: currentPathExpectedRemoteAuthorityBySessionId[sessionId],
                fallbackPeerIDs: peerIdCandidates,
                additionalTrustedFingerprints: additionalProtocolFingerprints(for: sessionId)
            )

            func attemptInitialHandshake(
                selection: CryptoProviderFactory.SelectionPolicy,
                bootstrapMode: String
            ) async throws -> SessionKeys {
                try await SkyBridgeiOSCore.shared.initialize(policy: selection)
                let driver = try SkyBridgeiOSCore.shared.createHandshakeDriver(
                    transport: transport,
                    trustProvider: currentPathTrustProvider
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
                if !strictPQCRequested,
                   hasTrustedPeerKEMKey,
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
                self.inboundInitialHandshakeResponderSessionIds.remove(sessionId)
                self.inboundClassicAuthorityBootstrapSessionIds.remove(sessionId)
                self.clearStrictPQCClassicBootstrapOnly(sessionId: sessionId)
                self.rekeyInProgressSessionIds.remove(sessionId)
                self.rekeyCompletedSessionIds.remove(sessionId)
                self.strictPQCRequestedBySessionId.removeValue(forKey: sessionId)
            }
        }
    }

    func shouldRequestStrictPQC(compatibilityModeEnabled: Bool) -> Bool {
        true
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

    nonisolated static func resolveTrustedPeerKEMCoverage(
        requiredSuites: [CryptoSuite],
        trustedPeerKEM: [CryptoSuite: Data]
    ) -> (availableSuites: [CryptoSuite], missingSuites: [CryptoSuite]) {
        var keysByCanonicalWireId: [UInt16: Data] = [:]
        for (suite, publicKey) in trustedPeerKEM where !publicKey.isEmpty {
            keysByCanonicalWireId[suite.canonicalKEMSuite.wireId] = publicKey
        }

        var available: [CryptoSuite] = []
        var missing: [CryptoSuite] = []
        for suite in requiredSuites {
            if keysByCanonicalWireId[suite.canonicalKEMSuite.wireId] != nil {
                available.append(suite)
            } else {
                missing.append(suite)
            }
        }
        return (available, missing)
    }

    nonisolated static func webRTCPQCRekeyProviderPlans(
        capability: CryptoProviderFactory.Capability,
        prefersLiboqsForPeer: Bool,
        peerHasXWing: Bool,
        appleXWingAvailable: Bool
    ) -> [WebRTCPQCRekeyProviderPlan] {
        guard capability.hasApplePQC || capability.hasLiboqs else { return [] }

        var plans: [WebRTCPQCRekeyProviderPlan] = []
        if capability.hasApplePQC, peerHasXWing, appleXWingAvailable {
            plans.append(.init(label: "native-xwing", suites: [.xwing]))
        }
        if capability.hasApplePQC {
            plans.append(.init(label: "native-pqc", suites: [.mlkem768fs, .mlkem768]))
        }
        if capability.hasLiboqs {
            let label = prefersLiboqsForPeer && !capability.hasApplePQC ? "liboqs" : "liboqs-fallback"
            plans.append(.init(label: label, suites: [.mlkem768fs, .mlkem768]))
        }

        var seen = Set<String>()
        return plans.compactMap { plan in
            let key = "\(plan.label)|\(plan.suites.map(\.wireId))"
            guard seen.insert(key).inserted else { return nil }
            return plan
        }
    }

    nonisolated private static func webRTCPQCRekeyProvider(for plan: WebRTCPQCRekeyProviderPlan) -> (any CryptoProvider)? {
        switch plan.label {
        case "native-xwing":
            #if HAS_APPLE_PQC_SDK
            if #available(iOS 26.0, macOS 26.0, *) {
                return AppleXWingCryptoProvider()
            }
            #endif
            return nil
        case "native-pqc":
            #if HAS_APPLE_PQC_SDK
            if #available(iOS 26.0, macOS 26.0, *) {
                return ApplePQCCryptoProvider()
            }
            #endif
            return nil
        case "liboqs", "liboqs-fallback":
            return OQSPQCCryptoProvider()
        default:
            return nil
        }
    }

    nonisolated static func strictPQCRekeyCandidateSuites(
        capability: CryptoProviderFactory.Capability,
        selectedProviderSuites: [CryptoSuite],
        selectedProviderTier: CryptoTier,
        appleXWingAvailable: Bool
    ) -> [CryptoSuite] {
        guard capability.hasApplePQC || capability.hasLiboqs else { return [] }

        let selectedPQCSuites = selectedProviderSuites.filter(\.isPQCGroup)
        if capability.hasApplePQC || selectedProviderTier == .nativePQC {
            var suites: [CryptoSuite] = []
            let prefersXWing = selectedPQCSuites.contains { $0.isHybrid }
            if prefersXWing, appleXWingAvailable {
                suites.append(.xwing)
            }
            suites.append(.mlkem768fs)
            suites.append(.mlkem768)
            if !prefersXWing, appleXWingAvailable {
                suites.append(.xwing)
            }
            suites.append(contentsOf: selectedPQCSuites)
            return deduplicatedSuitesByWire(suites)
        }

        return deduplicatedSuitesByWire(selectedPQCSuites)
    }

    nonisolated private static func strictPQCRekeyCandidateSuites(
        capability: CryptoProviderFactory.Capability,
        selectedProvider: any CryptoProvider
    ) -> [CryptoSuite] {
        strictPQCRekeyCandidateSuites(
            capability: capability,
            selectedProviderSuites: selectedProvider.supportedSuites,
            selectedProviderTier: selectedProvider.tier,
            appleXWingAvailable: isAppleXWingRuntimeAvailableForRekey()
        )
    }

    nonisolated private static func isAppleXWingRuntimeAvailableForRekey() -> Bool {
        #if HAS_APPLE_PQC_SDK
        if #available(iOS 26.0, macOS 26.0, *) {
            return AppleXWingCryptoProvider.quickRuntimeProbe()
        }
        #endif
        return false
    }

    nonisolated private static func deduplicatedSuitesByWire(_ suites: [CryptoSuite]) -> [CryptoSuite] {
        var seen = Set<UInt16>()
        var result: [CryptoSuite] = []
        result.reserveCapacity(suites.count)
        for suite in suites where suite.isKnown && seen.insert(suite.wireId).inserted {
            result.append(suite)
        }
        return result
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
                let payloadBytes = messageB.encryptedPayload.combinedWithHeader(suite: messageB.selectedSuite).count
                let seBytes = messageB.secureEnclaveSignature?.count ?? 0
                appendSmokeTrace(
                    "tx messageB suite=\(messageB.selectedSuite.rawValue) raw=\(rawHandshake.count) share=\(messageB.responderShare.count) payload=\(payloadBytes) id=\(messageB.identityPublicKey.count) sig=\(messageB.signature.count) se=\(seBytes)"
                )
                print(
                    "🧪 WebRTC rekey tx MessageB raw=\(rawHandshake.count) padded=\(tunedHandshake.count) suite=\(messageB.selectedSuite.rawValue) share=\(messageB.responderShare.count) payload=\(payloadBytes) id=\(messageB.identityPublicKey.count) sig=\(messageB.signature.count) se=\(seBytes)"
                )
            } else if (try? HandshakeFinished.decode(from: rawHandshake)) != nil {
                appendSmokeTrace("tx finished raw=\(rawHandshake.count)")
                print("🧪 WebRTC rekey tx Finished raw=\(rawHandshake.count) padded=\(tunedHandshake.count)")
            }
        }
        do {
            try await session.sendFramedPayloadAsync(
                tunedHandshake,
                maxChunkBytes: currentPathWebRTCHandshakeMaxChunkBytes,
                maxBufferedAmountBytes: currentPathWebRTCHandshakeMaxBufferedAmountBytes
            )
            if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                appendSmokeTrace("tx handshake-sent raw=\(rawHandshake.count) padded=\(tunedHandshake.count)")
            }
        } catch {
            if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                appendSmokeTrace(
                    "tx handshake-send-failed raw=\(rawHandshake.count) padded=\(tunedHandshake.count) error=\(Self.smokeTraceToken(error.localizedDescription))"
                )
            }
            throw error
        }
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
        appendSmokeTrace("inbound-rekey messageA candidate session=\(sessionId) raw=\(frame.count)")

        let hasPQCGroup = messageA.supportedSuites.contains { $0.isPQCGroup }
        let localCapability = CryptoProviderFactory.detectCapability()
        let localPQCAvailable = localCapability.hasApplePQC || localCapability.hasLiboqs
        guard let selection = Self.inboundPQCRekeySelectionPolicy(
            supportedSuites: messageA.supportedSuites,
            strictPQCRequested: strictPQCRequested,
            localPQCAvailable: localPQCAvailable
        ) else {
            let message: String
            if strictPQCRequested && !hasPQCGroup {
                message =
                    "严格 PQC 已启用，但 WebRTC 入站 rekey 对端只提供 Classic suites；当前已拒绝降级。peer=\(peer.deviceId)"
            } else {
                message =
                    "严格 PQC 已启用，但当前设备没有可用的 PQC Provider；当前已拒绝入站 rekey。peer=\(peer.deviceId)"
            }
            lastRekeyEvent = "rejected inbound strict peer=\(peer.deviceId)"
            SkyBridgeLogger.shared.error(
                "⛔️ \(message) hasApplePQC=\(localCapability.hasApplePQC), hasLiboqs=\(localCapability.hasLiboqs)"
            )
            if strictPQCRequested,
               sessionKeys?.negotiatedSuite.isPQCGroup != true {
                await failStrictPQCBootstrapSession(
                    sessionId: sessionId,
                    message: message
                )
            }
            return nil
        }

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
            let provider = hasPQCGroup
                ? CryptoProviderFactory.makeInboundPQCResponderProvider(
                    policy: selection,
                    peerSupportedSuites: messageA.supportedSuites
                )
                : CryptoProviderFactory.make(policy: selection)
            appendSmokeTrace("inbound-rekey provider session=\(sessionId) provider=\(provider.providerName)")
            try await SkyBridgeiOSCore.shared.initialize(policy: selection, providerOverride: provider)
            appendSmokeTrace("inbound-rekey core-ready session=\(sessionId)")
            let trustProvider = CurrentPathHandshakeTrustProviderCompat(
                expectedRemoteAuthority: currentPathExpectedRemoteAuthorityBySessionId[sessionId],
                fallbackPeerIDs: fallbackPeerIDs,
                additionalTrustedFingerprints: additionalProtocolFingerprints(for: sessionId)
            )
            let driver = try SkyBridgeiOSCore.shared.createHandshakeDriver(
                transport: makeHandshakeTransport(over: session),
                peerSupportedSuites: messageA.supportedSuites,
                trustProvider: trustProvider
            )
            handshakeDriver = driver
            appendSmokeTrace("inbound-rekey driver-ready session=\(sessionId)")
        } catch {
            SkyBridgeLogger.shared.warning(
                "⚠️ inbound WebRTC rekey driver 初始化失败: session=\(sessionId), err=\(error.localizedDescription)"
            )
            if strictPQCRequested,
               sessionKeys?.negotiatedSuite.isPQCGroup != true {
                await failStrictPQCBootstrapSession(
                    sessionId: sessionId,
                    message: "strictPQC WebRTC inbound rekey driver init failed: \(error.localizedDescription)"
                )
            }
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

    private func ensureInboundInitialHandshakeDriverIfNeeded(
        sessionId: String,
        frame: Data,
        peer: PeerIdentifier,
        session: WebRTCSession,
        strictPQCRequested: Bool
    ) async -> HandshakeDriver? {
        guard currentSessionId == sessionId else { return nil }
        if inboundInitialHandshakeResponderSessionIds.contains(sessionId) {
            return handshakeDriver
        }
        guard handshakeDriver == nil else { return nil }
        guard sessionKeys == nil else { return nil }
        guard let messageA = try? HandshakeMessageA.decode(from: frame),
              !messageA.supportedSuites.isEmpty else {
            return nil
        }

        let hasPQCGroup = messageA.supportedSuites.contains { $0.isPQCGroup }
        let localCapability = CryptoProviderFactory.detectCapability()
        let localPQCAvailable = localCapability.hasApplePQC || localCapability.hasLiboqs
        let expectedAuthorityAlgorithm = currentPathExpectedRemoteAuthorityBySessionId[sessionId]?.protocolSigningAlgorithm
        let allowsClassicAuthorityBootstrap = Self.shouldAllowClassicAuthorityBootstrapForInboundInitialWebRTCHandshake(
            supportedSuites: messageA.supportedSuites,
            strictPQCRequested: strictPQCRequested,
            expectedRemoteAuthorityAlgorithm: expectedAuthorityAlgorithm
        )
        guard let selection = Self.inboundInitialHandshakeSelectionPolicy(
            supportedSuites: messageA.supportedSuites,
            strictPQCRequested: strictPQCRequested,
            localPQCAvailable: localPQCAvailable,
            expectedRemoteAuthorityAlgorithm: expectedAuthorityAlgorithm
        ) else {
            let message: String
            if strictPQCRequested && !hasPQCGroup {
                message =
                    "严格 PQC 已启用，但 WebRTC 对端初始握手只提供 Classic suites；当前已拒绝降级。peer=\(peer.deviceId)"
            } else {
                message =
                    "严格 PQC 已启用，但当前设备没有可用的 PQC Provider；当前已拒绝 WebRTC 入站初始握手。peer=\(peer.deviceId)"
            }
            SkyBridgeLogger.shared.error(
                "⛔️ \(message) hasApplePQC=\(localCapability.hasApplePQC), hasLiboqs=\(localCapability.hasLiboqs)"
            )
            if strictPQCRequested {
                await failStrictPQCBootstrapSession(
                    sessionId: sessionId,
                    message: message
                )
            }
            return nil
        }

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
                fallbackPeerIDs: fallbackPeerIDs,
                additionalTrustedFingerprints: additionalProtocolFingerprints(for: sessionId)
            )
            let driver = try SkyBridgeiOSCore.shared.createHandshakeDriver(
                transport: makeHandshakeTransport(over: session),
                peerSupportedSuites: messageA.supportedSuites,
                trustProvider: trustProvider
            )
            handshakeDriver = driver
        } catch {
            SkyBridgeLogger.shared.warning(
                "⚠️ inbound WebRTC 初始握手驱动初始化失败: session=\(sessionId), err=\(error.localizedDescription)"
            )
            if strictPQCRequested {
                await failStrictPQCBootstrapSession(
                    sessionId: sessionId,
                    message: "strictPQC WebRTC inbound initial handshake driver init failed: \(error.localizedDescription)"
                )
            }
            return nil
        }

        inboundInitialHandshakeResponderSessionIds.insert(sessionId)
        if allowsClassicAuthorityBootstrap {
            inboundClassicAuthorityBootstrapSessionIds.insert(sessionId)
            SkyBridgeLogger.shared.info(
                "🤝 WebRTC 入站初始握手允许 current-path authority classic bootstrap: session=\(sessionId), peer=\(peer.deviceId)"
            )
        }
        SkyBridgeLogger.shared.info(
            "🤝 收到对端 WebRTC 初始握手请求，切换 responder: session=\(sessionId), peer=\(peer.deviceId), suites=\(messageA.supportedSuites.map(\.rawValue).joined(separator: ","))"
        )
        return handshakeDriver
    }

    private func failStrictPQCBootstrapSession(
        sessionId: String,
        message: String
    ) async {
        lastError = message
        lastRekeyEvent = "failed strict reason=\(message)"
        handshakeDriver = nil
        sessionKeys = nil
        inboundInitialHandshakeResponderSessionIds.remove(sessionId)
        inboundClassicAuthorityBootstrapSessionIds.remove(sessionId)
        inboundRekeyResponderSessionIds.remove(sessionId)
        clearStrictPQCClassicBootstrapOnly(sessionId: sessionId)
        rekeyInProgressSessionIds.remove(sessionId)
        rekeyCompletedSessionIds.remove(sessionId)
        strictPQCRequestedBySessionId.removeValue(forKey: sessionId)
        applyActiveSessionDisconnect(sessionId: sessionId, kind: .explicit)
        await disconnect(clearSnapshot: false)
        lastError = message
        state = .failed(message)
        readiness = .idle
    }

    private func syncInboundPQCRekeyState(
        sessionId: String,
        strictPQCRequested: Bool
    ) async {
        guard inboundRekeyResponderSessionIds.contains(sessionId),
              let driver = handshakeDriver else {
            return
        }

        let currentState = await driver.getCurrentState()
        switch currentState {
        case .established(let keys):
            if strictPQCRequested,
               !Self.inboundPQCRekeyNegotiatedSuiteAllowed(
                    keys.negotiatedSuite,
                    strictPQCRequested: strictPQCRequested
               ) {
                let message =
                    "strictPQC WebRTC 入站 rekey 协商到了 Classic suite=\(keys.negotiatedSuite.rawValue)，当前关闭 classic bootstrap-only 会话。"
                SkyBridgeLogger.shared.error(
                    "⛔️ \(message) session=\(sessionId)"
                )
                await failStrictPQCBootstrapSession(sessionId: sessionId, message: message)
                return
            }
            sessionKeys = keys
            handshakeDriver = nil
            inboundRekeyResponderSessionIds.remove(sessionId)
            rekeyInProgressSessionIds.remove(sessionId)
            rekeyCompletedSessionIds.insert(sessionId)
            clearStrictPQCClassicBootstrapOnly(sessionId: sessionId)
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
                "✅ inbound WebRTC rekey 完成: session=\(sessionId), event=pqcRekeyComplete suite=\(keys.negotiatedSuite.rawValue)"
            )

        case .failed(let reason):
            handshakeDriver = nil
            inboundRekeyResponderSessionIds.remove(sessionId)
            rekeyInProgressSessionIds.remove(sessionId)
            lastRekeyEvent = "failed reason=\(reason)"
            if strictPQCRequested,
               sessionKeys?.negotiatedSuite.isPQCGroup != true {
                let message = "strictPQC WebRTC rekey failed after classic bootstrap: \(reason)"
                SkyBridgeLogger.shared.error(
                    "⛔️ \(message) session=\(sessionId), event=pqcRekeyFailed"
                )
                lastError = message
                applyActiveSessionDisconnect(sessionId: sessionId, kind: .explicit)
                await disconnect(clearSnapshot: false)
                lastError = message
                state = .failed(message)
                readiness = .idle
                return
            }
            SkyBridgeLogger.shared.warning(
                "⚠️ inbound WebRTC rekey 失败，保留既有会话: session=\(sessionId), event=pqcRekeyFailed reason=\(reason)"
            )

        default:
            break
        }
    }

    private func syncInboundInitialHandshakeState(
        sessionId: String,
        strictPQCRequested: Bool
    ) async {
        guard inboundInitialHandshakeResponderSessionIds.contains(sessionId),
              let driver = handshakeDriver else {
            return
        }

        let currentState = await driver.getCurrentState()
        switch currentState {
        case .established(let keys):
            let allowsClassicAuthorityBootstrap = inboundClassicAuthorityBootstrapSessionIds.contains(sessionId)
            if strictPQCRequested,
               !Self.inboundInitialHandshakeNegotiatedSuiteAllowed(
                    keys.negotiatedSuite,
                    strictPQCRequested: strictPQCRequested,
                    allowsClassicAuthorityBootstrap: allowsClassicAuthorityBootstrap
               ) {
                handshakeDriver = nil
                inboundInitialHandshakeResponderSessionIds.remove(sessionId)
                inboundClassicAuthorityBootstrapSessionIds.remove(sessionId)
                clearStrictPQCClassicBootstrapOnly(sessionId: sessionId)
                let message =
                    "strictPQC WebRTC 初始握手协商到了 Classic suite=\(keys.negotiatedSuite.rawValue)，当前已拒绝建立会话。"
                SkyBridgeLogger.shared.error("⛔️ \(message) session=\(sessionId)")
                lastError = message
                applyActiveSessionDisconnect(sessionId: sessionId, kind: .explicit)
                await disconnect(clearSnapshot: false)
                lastError = message
                state = .failed(message)
                readiness = .idle
                return
            }

            sessionKeys = keys
            handshakeDriver = nil
            inboundInitialHandshakeResponderSessionIds.remove(sessionId)
            inboundClassicAuthorityBootstrapSessionIds.remove(sessionId)
            if strictPQCRequested,
               allowsClassicAuthorityBootstrap,
               !keys.negotiatedSuite.isPQCGroup {
                lastRekeyEvent = "bootstrapOnly suite=\(keys.negotiatedSuite.rawValue)"
                if let activeSession = self.session {
                    markStrictPQCClassicBootstrapOnly(sessionId: sessionId, session: activeSession)
                } else {
                    strictPQCClassicBootstrapOnlySessionIds.insert(sessionId)
                }
                SkyBridgeLogger.shared.warning(
                    "⏳ inbound WebRTC strictPQC classic authority bootstrap is bootstrap-only: session=\(sessionId), event=pqcRekeyPending suite=\(keys.negotiatedSuite.rawValue)"
                )
                if currentSessionId == sessionId,
                   let activeSession = self.session {
                    do {
                        try await sendPairingIdentityExchangeOverWebRTC(
                            sessionId: sessionId,
                            peerDeviceId: remoteDeviceId ?? handshakePeerId ?? sessionId,
                            session: activeSession,
                            force: true
                        )
                    } catch {
                        SkyBridgeLogger.shared.warning(
                            "⚠️ inbound WebRTC strictPQC bootstrap pairingIdentityExchange send failed: session=\(sessionId), err=\(error.localizedDescription)"
                        )
                    }
                }
                if currentSessionId == sessionId,
                   let activeSession = self.session {
                    startRemotePeerLivenessWatchdog(sessionId: sessionId, session: activeSession)
                }
                return
            }
            clearStrictPQCClassicBootstrapOnly(sessionId: sessionId)

            if currentSessionId == sessionId {
                state = .connected(sessionId: sessionId)
                readiness = .handshakeComplete(
                    sessionId: sessionId,
                    negotiatedSuite: keys.negotiatedSuite.rawValue
                )
                noteRemoteAppActivity(sessionId: sessionId)
                if let activeSession = self.session {
                    startRemotePeerPingLoop(sessionId: sessionId, session: activeSession)
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
                "✅ inbound WebRTC 初始握手完成: session=\(sessionId), suite=\(keys.negotiatedSuite.rawValue)"
            )

        case .failed(let reason):
            handshakeDriver = nil
            inboundInitialHandshakeResponderSessionIds.remove(sessionId)
            inboundClassicAuthorityBootstrapSessionIds.remove(sessionId)
            let message = "WebRTC 握手失败: \(reason)"
            SkyBridgeLogger.shared.error(
                "❌ inbound WebRTC 初始握手失败: session=\(sessionId), reason=\(reason)"
            )
            lastError = message
            applyActiveSessionDisconnect(sessionId: sessionId, kind: .explicit)
            await disconnect(clearSnapshot: false)
            lastError = message
            state = .failed(message)
            readiness = .idle

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

        let kemKeys = KEMPublicKeyInfo.normalizedValidKeys(
            try await P2PKEMIdentityKeyStore.shared.getOrCreateBootstrapPublicKeys()
        )
        guard !kemKeys.isEmpty else { return }
        let localDeviceId = self.localDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !localDeviceId.isEmpty else {
            SkyBridgeLogger.shared.warning(
                "⚠️ WebRTC pairingIdentityExchange send skipped: empty localDeviceId session=\(sessionId)"
            )
            return
        }

        let message = AppMessage.pairingIdentityExchange(.init(
            deviceId: localDeviceId,
            kemPublicKeys: kemKeys,
            protocolIdentityPublicKeys: await localProtocolIdentityPublicKeysForPairing(),
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
            guard let payload = payload.normalizedBootstrapPayload else {
                SkyBridgeLogger.shared.warning(
                    "⚠️ WebRTC pairingIdentityExchange ignored: empty declaredDeviceId or empty KEM public key session=\(sessionId) peer=\(peerDeviceId)"
                )
                return
            }
            noteRemoteAppActivity(sessionId: sessionId)
            await KEMTrustStore.shared.upsert(deviceId: payload.deviceId, kemPublicKeys: payload.kemPublicKeys)
            await KEMTrustStore.shared.upsert(deviceId: peerDeviceId, kemPublicKeys: payload.kemPublicKeys)
            recordCurrentPathProtocolFingerprints(
                from: payload,
                sessionId: sessionId,
                peerDeviceId: peerDeviceId
            )
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

        func failStrictClassicBootstrap(reason: String, diagnostic: String) async {
            guard strictPQCRequested, sessionKeys?.negotiatedSuite.isPQCGroup != true else { return }
            let message = "strictPQC WebRTC rekey failed after classic bootstrap: \(diagnostic)"
            lastRekeyEvent = "failed strict reason=\(reason)"
            SkyBridgeLogger.shared.error(
                "⛔️ \(message) session=\(sessionId), event=pqcRekeyFailed trigger=\(trigger)"
            )
            lastError = message
            handshakeDriver = nil
            rekeyInProgressSessionIds.remove(sessionId)
            rekeyCompletedSessionIds.remove(sessionId)
            applyActiveSessionDisconnect(sessionId: sessionId, kind: .explicit)
            await disconnect(clearSnapshot: false)
            lastError = message
            state = .failed(message)
            readiness = .idle
        }
        let hasPeerKEMEvidence = trigger != "post_bootstrap"

        guard let electionRemoteDeviceId = resolvedPQCRekeyElectionRemoteDeviceId(
            sessionId: sessionId,
            peerDeviceId: peerDeviceId
        ) else {
            lastRekeyEvent = "waiting peer=unknown election"
            SkyBridgeLogger.shared.info(
                "⏳ WebRTC rekey waiting for concrete remote device id: session=\(sessionId), event=pqcRekeyPending trigger=\(trigger)"
            )
            if hasPeerKEMEvidence {
                await failStrictClassicBootstrap(
                    reason: "missing_remote_device_id",
                    diagnostic: "concrete remote device id unavailable"
                )
            }
            return
        }
        guard let shouldInitiate = Self.shouldInitiatePQCRekey(
            localDeviceId: localDeviceId,
            remoteDeviceId: electionRemoteDeviceId
        ) else {
            lastRekeyEvent = "waiting peer=\(electionRemoteDeviceId) election"
            SkyBridgeLogger.shared.info(
                "⏳ WebRTC rekey waiting for stable initiator election: session=\(sessionId), event=pqcRekeyPending trigger=\(trigger), peer=\(electionRemoteDeviceId)"
            )
            if hasPeerKEMEvidence {
                await failStrictClassicBootstrap(
                    reason: "unstable_rekey_election",
                    diagnostic: "stable initiator election unavailable for peer \(electionRemoteDeviceId)"
                )
            }
            return
        }
        guard shouldInitiate else {
            lastRekeyEvent = "await inbound peer=\(electionRemoteDeviceId)"
            SkyBridgeLogger.shared.info(
                "ℹ️ WebRTC rekey elected peer as initiator; waiting inbound rekey: session=\(sessionId), event=pqcRekeyPending trigger=\(trigger), peer=\(electionRemoteDeviceId)"
            )
            return
        }

        let capability = CryptoProviderFactory.detectCapability()
        let selection: CryptoProviderFactory.SelectionPolicy = .requirePQC
        if !(capability.hasApplePQC || capability.hasLiboqs) {
            SkyBridgeLogger.shared.warning(
                "⚠️ skip WebRTC rekey: strictPQC requested but local PQC provider unavailable. " +
                "session=\(sessionId), event=pqcRekeyFailed trigger=\(trigger), hasApplePQC=\(capability.hasApplePQC), hasLiboqs=\(capability.hasLiboqs)"
            )
            await failStrictClassicBootstrap(
                reason: "local_pqc_provider_unavailable",
                diagnostic: "local device has no available Apple PQC or liboqs provider"
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
        if candidateIds.isEmpty {
            await failStrictClassicBootstrap(
                reason: "missing_peer_candidates",
                diagnostic: "no peer id candidate available for trusted KEM lookup"
            )
            return
        }

        let defaultProvider = CryptoProviderFactory.make(policy: selection)
        let candidateSuites = Self.strictPQCRekeyCandidateSuites(
            capability: capability,
            selectedProvider: defaultProvider
        )
        guard !candidateSuites.isEmpty else {
            await failStrictClassicBootstrap(
                reason: "local_pqc_suites_unavailable",
                diagnostic: "local PQC provider advertised no usable PQC suites"
            )
            return
        }

        var trustedKeysByCandidateId: [String: [CryptoSuite: Data]] = [:]
        for candidateId in candidateIds {
            trustedKeysByCandidateId[candidateId] = await KEMTrustStore.shared.kemPublicKeys(for: candidateId)
        }

        let prefersLiboqsForPeer = false
        let peerHasXWing = trustedKeysByCandidateId.values.contains { keys in
            keys.keys.contains { $0.canonicalKEMSuite == .xwing }
        }
        let providerPlans = Self.webRTCPQCRekeyProviderPlans(
            capability: capability,
            prefersLiboqsForPeer: prefersLiboqsForPeer,
            peerHasXWing: peerHasXWing,
            appleXWingAvailable: Self.isAppleXWingRuntimeAvailableForRekey()
        )

        var selectedPeerId = peerDeviceId
        var trustedPeerKEM: [CryptoSuite: Data] = [:]
        var selectedAvailableSuites: [CryptoSuite] = []
        var selectedProvider: (any CryptoProvider)?
        var selectedProviderLabel = ""

        providerLoop: for plan in providerPlans {
            guard let planProvider = Self.webRTCPQCRekeyProvider(for: plan) else { continue }
            for candidate in candidateIds {
                let keys = trustedKeysByCandidateId[candidate] ?? [:]
                guard !keys.isEmpty else { continue }
                let coverage = Self.resolveTrustedPeerKEMCoverage(
                    requiredSuites: plan.suites,
                    trustedPeerKEM: keys
                )
                if trustedPeerKEM.isEmpty {
                    selectedPeerId = candidate
                    trustedPeerKEM = keys
                    selectedAvailableSuites = coverage.availableSuites
                }
                if !coverage.availableSuites.isEmpty {
                    selectedPeerId = candidate
                    trustedPeerKEM = keys
                    selectedAvailableSuites = coverage.availableSuites
                    selectedProvider = planProvider
                    selectedProviderLabel = plan.label
                    break providerLoop
                }
            }
        }

        let coverage = Self.resolveTrustedPeerKEMCoverage(
            requiredSuites: candidateSuites,
            trustedPeerKEM: trustedPeerKEM
        )
        let missingSuites = coverage.missingSuites
        let offeredSuites = selectedAvailableSuites.isEmpty ? coverage.availableSuites : selectedAvailableSuites
        guard !offeredSuites.isEmpty else {
            let missing = missingSuites.map(\.rawValue).joined(separator: ",")
            lastRekeyEvent = "waiting peer=\(selectedPeerId) missing=\(missing)"
            SkyBridgeLogger.shared.info(
                "⏳ WebRTC rekey waiting for peer KEM keys: session=\(sessionId), event=pqcRekeyPending peer=\(selectedPeerId), missing=\(missing)"
            )
            if hasPeerKEMEvidence {
                await failStrictClassicBootstrap(
                    reason: "missing_common_peer_kem",
                    diagnostic: missing.isEmpty
                        ? "no common trusted peer PQC KEM key"
                        : "missing common trusted peer PQC KEM key(s): \(missing)"
                )
            }
            return
        }
        guard let selectedProvider else {
            SkyBridgeLogger.shared.warning(
                "⚠️ skip WebRTC rekey: no suite-aware PQC provider selected. session=\(sessionId), event=pqcRekeyFailed trigger=\(trigger)"
            )
            await failStrictClassicBootstrap(
                reason: "suite_aware_provider_unavailable",
                diagnostic: "no suite-aware PQC provider matched the peer KEM material"
            )
            return
        }

        rekeyInProgressSessionIds.insert(sessionId)
        defer {
            rekeyInProgressSessionIds.remove(sessionId)
            handshakeDriver = nil
        }

        do {
            try await SkyBridgeiOSCore.shared.initialize(
                policy: selection,
                providerOverride: selectedProvider
            )
            let transport = makeHandshakeTransport(over: session)
            let peer = PeerIdentifier(deviceId: selectedPeerId)
            let trustProvider = CurrentPathHandshakeTrustProviderCompat(
                expectedRemoteAuthority: currentPathExpectedRemoteAuthorityBySessionId[sessionId],
                fallbackPeerIDs: candidateIds,
                additionalTrustedFingerprints: additionalProtocolFingerprints(for: sessionId)
            )
            let driver = try SkyBridgeiOSCore.shared.createHandshakeDriver(
                transport: transport,
                offeredSuites: offeredSuites,
                trustProvider: trustProvider
            )
            handshakeDriver = driver

            let suiteSummary = offeredSuites.map(\.rawValue).joined(separator: ",")
            lastRekeyEvent = "start peer=\(selectedPeerId) policy=\(selection.rawValue) suites=\(suiteSummary)"
            SkyBridgeLogger.shared.info(
                "🔁 WebRTC rekey start: session=\(sessionId), event=pqcRekeyStarted trigger=\(trigger), peer=\(selectedPeerId), policy=\(selection.rawValue), provider=\(selectedProviderLabel), offeredSuites=\(suiteSummary)"
            )
            let rekeyed = try await driver.initiateHandshake(with: peer)
            sessionKeys = rekeyed
            rekeyCompletedSessionIds.insert(sessionId)
            clearStrictPQCClassicBootstrapOnly(sessionId: sessionId)
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
                "✅ WebRTC rekey complete: session=\(sessionId), event=pqcRekeyComplete suite=\(rekeyed.negotiatedSuite.rawValue)"
            )
        } catch {
            lastRekeyEvent = "failed error=\(error.localizedDescription)"
            if strictPQCRequested,
               sessionKeys?.negotiatedSuite.isPQCGroup != true {
                let message = "strictPQC WebRTC rekey failed after classic bootstrap: \(error.localizedDescription)"
                SkyBridgeLogger.shared.error(
                    "⛔️ \(message) session=\(sessionId), event=pqcRekeyFailed trigger=\(trigger)"
                )
                lastError = message
                applyActiveSessionDisconnect(sessionId: sessionId, kind: .explicit)
                await disconnect(clearSnapshot: false)
                lastError = message
                state = .failed(message)
                readiness = .idle
                return
            }
            SkyBridgeLogger.shared.error(
                "❌ WebRTC rekey failed: session=\(sessionId), event=pqcRekeyFailed trigger=\(trigger), err=\(error.localizedDescription)"
            )
        }
    }
}

@available(iOS 17.0, *)
extension CrossNetworkWebRTCManager {
    struct WebRTCPQCRekeyProviderPlan: Equatable, Sendable {
        let label: String
        let suites: [CryptoSuite]
    }

    struct InboundFrameParser {
        private(set) var buffer = Data()
        private(set) var readOffset = 0
        let maxInboundFrameBytes: Int

        var canProbeDirectCompatibility: Bool {
            readOffset >= buffer.count
        }

        mutating func append(_ chunk: Data) {
            compact()
            buffer.append(chunk)
        }

        mutating func nextPayload(
            sessionId: String,
            logLabel: String
        ) -> Data? {
            while buffer.count - readOffset >= 4 {
                if Self.startsWithKnownDirectEnvelope(buffer, at: readOffset) {
                    let bufferedBytes = buffer.count - readOffset
                    let prefixEnd = min(buffer.count, readOffset + 8)
                    let prefix = buffer[readOffset..<prefixEnd]
                        .map { String(format: "%02x", $0) }
                        .joined()
                    let magic = Self.knownDirectEnvelopeName(buffer, at: readOffset) ?? "unknown"
                    SkyBridgeLogger.shared.warning(
                        "⚠️ drop wrong-channel or unframed direct \(logLabel) envelope before length parser: magic=\(magic) buffered=\(bufferedBytes) prefix=\(prefix) reset=direct-envelope session=\(sessionId)"
                    )
                    reset()
                    return nil
                }

                let length: Int = buffer.withUnsafeBytes { ptr in
                    let b0 = ptr.load(fromByteOffset: readOffset, as: UInt8.self)
                    let b1 = ptr.load(fromByteOffset: readOffset + 1, as: UInt8.self)
                    let b2 = ptr.load(fromByteOffset: readOffset + 2, as: UInt8.self)
                    let b3 = ptr.load(fromByteOffset: readOffset + 3, as: UInt8.self)
                    return (Int(b0) << 24) | (Int(b1) << 16) | (Int(b2) << 8) | Int(b3)
                }

                guard length > 0 && length < maxInboundFrameBytes else {
                    let bufferedBytes = buffer.count - readOffset
                    let prefixEnd = min(buffer.count, readOffset + 8)
                    let prefix = buffer[readOffset..<prefixEnd]
                        .map { String(format: "%02x", $0) }
                        .joined()
                    SkyBridgeLogger.shared.warning(
                        "⚠️ drop invalid \(logLabel) frame length: len=\(length) max=\(maxInboundFrameBytes) buffered=\(bufferedBytes) prefix=\(prefix) reset=invalid-length session=\(sessionId)"
                    )
                    // WebRTC DataChannel is reliable and ordered. If framing is poisoned, byte-by-byte
                    // resync can turn arbitrary ciphertext into a fake handshake packet. Drop the whole
                    // buffered frame state and wait for the next clean prefix instead.
                    reset()
                    return nil
                }

                guard buffer.count - readOffset >= 4 + length else {
                    compact()
                    return nil
                }

                let start = readOffset + 4
                let end = start + length
                let payload = buffer.subdata(in: start..<end)
                readOffset = end
                compact()
                return payload
            }

            compact()
            return nil
        }

        private mutating func compact() {
            if readOffset >= buffer.count {
                reset()
                return
            }

            if readOffset > 0, (readOffset >= 4096 || readOffset * 2 >= buffer.count) {
                buffer.removeSubrange(0..<readOffset)
                readOffset = 0
            }

            if buffer.count > maxInboundFrameBytes * 2 {
                reset()
            }
        }

        private mutating func reset() {
            buffer.removeAll(keepingCapacity: true)
            readOffset = 0
        }

        static func lengthPrefix(from data: Data) -> Int? {
            guard data.count >= 4 else { return nil }
            return data.withUnsafeBytes { ptr in
                let b0 = ptr.load(fromByteOffset: 0, as: UInt8.self)
                let b1 = ptr.load(fromByteOffset: 1, as: UInt8.self)
                let b2 = ptr.load(fromByteOffset: 2, as: UInt8.self)
                let b3 = ptr.load(fromByteOffset: 3, as: UInt8.self)
                return (Int(b0) << 24) | (Int(b1) << 16) | (Int(b2) << 8) | Int(b3)
            }
        }

        static func startsWithKnownDirectEnvelope(_ data: Data, at offset: Int = 0) -> Bool {
            knownDirectEnvelopeName(data, at: offset) != nil
        }

        static func knownDirectEnvelopeName(_ data: Data, at offset: Int = 0) -> String? {
            guard data.count - offset >= 4 else { return nil }
            let magic = data[offset..<offset + 4]
            if magic.elementsEqual([0x53, 0x42, 0x50, 0x32]) { return "SBP2" } // traffic padding
            if magic.elementsEqual([0x53, 0x42, 0x52, 0x46]) { return "SBRF" } // screen frame
            if magic.elementsEqual([0x53, 0x42, 0x52, 0x41]) { return "SBRA" } // audio frame
            if magic.elementsEqual([0x53, 0x42, 0x43, 0x32]) { return "SBC2" } // screen chunk
            return nil
        }
    }

    struct ScreenChannelWireDecoder {
        enum Mode: String, Equatable {
            case unknown
            case lengthFramed
            case directPayload
            case chunkedPayload = "sbc2-chunked-v1"
        }

        private(set) var mode: Mode = .unknown
        private(set) var parser: InboundFrameParser
        private var chunkedReassembler: ScreenChunkedPayloadReassembler
        let maxInboundFrameBytes: Int

        private var pendingDirectCandidate: (data: Data, receivedAt: Date)?
        private let pendingCandidateTTL: TimeInterval = 1.0

        init(maxInboundFrameBytes: Int) {
            self.maxInboundFrameBytes = maxInboundFrameBytes
            self.parser = InboundFrameParser(maxInboundFrameBytes: maxInboundFrameBytes)
            self.chunkedReassembler = ScreenChunkedPayloadReassembler(maxFrameBytes: maxInboundFrameBytes)
        }

        var canProbeDirectPayload: Bool {
            mode != .lengthFramed && parser.canProbeDirectCompatibility
        }

        var hasPendingDirectCandidate: Bool {
            pendingDirectCandidate != nil
        }

        mutating func markDirectPayloadMode() {
            mode = .directPayload
            parser = InboundFrameParser(maxInboundFrameBytes: maxInboundFrameBytes)
            chunkedReassembler.reset()
            pendingDirectCandidate = nil
        }

        mutating func markLengthFramedMode() {
            if mode == .unknown {
                mode = .lengthFramed
            }
            pendingDirectCandidate = nil
        }

        mutating func resetLengthFramedAfterDecodeFailure() {
            parser = InboundFrameParser(maxInboundFrameBytes: maxInboundFrameBytes)
            if mode == .lengthFramed {
                mode = .unknown
            }
            pendingDirectCandidate = nil
        }

        mutating func markChunkedPayloadMode() {
            mode = .chunkedPayload
            parser = InboundFrameParser(maxInboundFrameBytes: maxInboundFrameBytes)
            pendingDirectCandidate = nil
        }

        func isChunkedPayload(_ chunk: Data) -> Bool {
            ScreenChunkedPayloadEnvelope.startsWithMagic(chunk)
        }

        mutating func appendChunkedPayload(_ chunk: Data, now: Date) -> ScreenChunkedPayloadReassembler.Result {
            guard let envelope = ScreenChunkedPayloadEnvelope.decode(chunk) else {
                chunkedReassembler.reset()
                return .dropped(reason: "invalid-sbc2-envelope", frameId: nil)
            }
            return chunkedReassembler.append(envelope, now: now)
        }

        func shouldKeepOutOfLengthParser(_ chunk: Data) -> Bool {
            guard canProbeDirectPayload else { return mode == .directPayload }
            if InboundFrameParser.startsWithKnownDirectEnvelope(chunk) {
                return true
            }
            guard let length = InboundFrameParser.lengthPrefix(from: chunk) else {
                return false
            }
            return length <= 0 || length >= maxInboundFrameBytes
        }

        mutating func cacheDirectCandidateIfPossible(_ chunk: Data, now: Date) -> Bool {
            guard chunk.count <= maxInboundFrameBytes else { return false }
            pendingDirectCandidate = (chunk, now)
            return true
        }

        mutating func takePendingDirectCandidate(now: Date) -> Data? {
            guard let candidate = pendingDirectCandidate else { return nil }
            pendingDirectCandidate = nil
            guard now.timeIntervalSince(candidate.receivedAt) <= pendingCandidateTTL else {
                return nil
            }
            return candidate.data
        }

        mutating func appendLengthChunk(_ chunk: Data) {
            parser.append(chunk)
        }

        mutating func nextLengthPayload(sessionId: String, logLabel: String) -> Data? {
            parser.nextPayload(sessionId: sessionId, logLabel: logLabel)
        }
    }

    struct ScreenChunkedPayloadEnvelope {
        static let magic: UInt32 = 0x5342_4332 // SBC2
        static let version: UInt8 = 1
        static let headerLength = 36

        let frameId: UInt64
        let chunkIndex: Int
        let chunkCount: Int
        let totalBytes: Int
        let chunkOffset: Int
        let payload: Data

        static func startsWithMagic(_ data: Data) -> Bool {
            guard data.count >= 4 else { return false }
            return readUInt32(data, at: 0) == magic
        }

        static func decode(_ data: Data) -> ScreenChunkedPayloadEnvelope? {
            guard data.count >= headerLength,
                  readUInt32(data, at: 0) == magic,
                  data[4] == version,
                  Int(readUInt16(data, at: 6)) == headerLength else {
                return nil
            }
            let chunkBytes = Int(readUInt32(data, at: 32))
            guard chunkBytes >= 0,
                  data.count == headerLength + chunkBytes else {
                return nil
            }
            let frameId = readUInt64(data, at: 8)
            let chunkIndex = Int(readUInt32(data, at: 16))
            let chunkCount = Int(readUInt32(data, at: 20))
            let totalBytes = Int(readUInt32(data, at: 24))
            let chunkOffset = Int(readUInt32(data, at: 28))
            let payload = data.subdata(in: headerLength..<data.count)
            return ScreenChunkedPayloadEnvelope(
                frameId: frameId,
                chunkIndex: chunkIndex,
                chunkCount: chunkCount,
                totalBytes: totalBytes,
                chunkOffset: chunkOffset,
                payload: payload
            )
        }

        private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
            data.withUnsafeBytes { ptr in
                let b0 = UInt16(ptr.load(fromByteOffset: offset, as: UInt8.self))
                let b1 = UInt16(ptr.load(fromByteOffset: offset + 1, as: UInt8.self))
                return (b0 << 8) | b1
            }
        }

        private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
            data.withUnsafeBytes { ptr in
                let b0 = UInt32(ptr.load(fromByteOffset: offset, as: UInt8.self))
                let b1 = UInt32(ptr.load(fromByteOffset: offset + 1, as: UInt8.self))
                let b2 = UInt32(ptr.load(fromByteOffset: offset + 2, as: UInt8.self))
                let b3 = UInt32(ptr.load(fromByteOffset: offset + 3, as: UInt8.self))
                return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
            }
        }

        private static func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
            data.withUnsafeBytes { ptr in
                var value: UInt64 = 0
                for idx in 0..<8 {
                    value = (value << 8) | UInt64(ptr.load(fromByteOffset: offset + idx, as: UInt8.self))
                }
                return value
            }
        }
    }

    struct ScreenChunkedPayloadReassembler {
        enum Result: Equatable {
            case waiting(frameId: UInt64, chunkIndex: Int, chunkCount: Int)
            case complete(frameId: UInt64, payload: Data)
            case dropped(reason: String, frameId: UInt64?)
            case suppressed(frameId: UInt64, reason: String)
        }

        private let maxFrameBytes: Int
        private var frameId: UInt64?
        private var suppressedFrameReasons: [UInt64: String] = [:]
        private var expectedChunkCount: Int = 0
        private var expectedTotalBytes: Int = 0
        private var nextChunkIndex: Int = 0
        private var receivedBytes: Int = 0
        private var chunks: [Data] = []
        private var lastUpdatedAt: Date = .distantPast
        private let frameTTL: TimeInterval = 1.0

        init(maxFrameBytes: Int) {
            self.maxFrameBytes = maxFrameBytes
        }

        mutating func reset(clearSuppression: Bool = true) {
            frameId = nil
            expectedChunkCount = 0
            expectedTotalBytes = 0
            nextChunkIndex = 0
            receivedBytes = 0
            chunks.removeAll(keepingCapacity: true)
            lastUpdatedAt = .distantPast
            if clearSuppression {
                clearSuppressedFrame()
            }
        }

        private mutating func clearSuppressedFrame() {
            suppressedFrameReasons.removeAll(keepingCapacity: true)
        }

        private mutating func drop(
            reason: String,
            frameId droppedFrameId: UInt64?,
            suppressOrphansFor orphanFrameIds: [UInt64] = []
        ) -> Result {
            reset(clearSuppression: orphanFrameIds.isEmpty)
            for orphanFrameId in orphanFrameIds {
                suppressedFrameReasons[orphanFrameId] = reason
            }
            return .dropped(reason: reason, frameId: droppedFrameId)
        }

        private mutating func beginFrame(_ envelope: ScreenChunkedPayloadEnvelope) {
            clearSuppressedFrame()
            frameId = envelope.frameId
            expectedChunkCount = envelope.chunkCount
            expectedTotalBytes = envelope.totalBytes
            nextChunkIndex = 0
            receivedBytes = 0
            chunks.removeAll(keepingCapacity: true)
        }

        mutating func append(
            _ envelope: ScreenChunkedPayloadEnvelope,
            now: Date
        ) -> Result {
            if let suppressedReason = suppressedFrameReasons[envelope.frameId] {
                return .suppressed(frameId: envelope.frameId, reason: suppressedReason)
            } else if envelope.chunkIndex == 0 {
                clearSuppressedFrame()
            }

            if frameId != nil, now.timeIntervalSince(lastUpdatedAt) > frameTTL {
                let droppedFrame = frameId
                reset()
                if envelope.chunkIndex != 0 {
                    return drop(
                        reason: "expired-missing-first-chunk",
                        frameId: droppedFrame,
                        suppressOrphansFor: [envelope.frameId]
                    )
                }
            }

            guard envelope.chunkCount > 0,
                  envelope.chunkIndex >= 0,
                  envelope.chunkIndex < envelope.chunkCount,
                  envelope.totalBytes > 0,
                  envelope.totalBytes <= maxFrameBytes,
                  envelope.chunkOffset >= 0,
                  envelope.chunkOffset + envelope.payload.count <= envelope.totalBytes else {
                return drop(reason: "invalid-sbc2-chunk-metadata", frameId: envelope.frameId)
            }

            if frameId == nil {
                guard envelope.chunkIndex == 0,
                      envelope.chunkOffset == 0 else {
                    return drop(
                        reason: "missing-first-chunk",
                        frameId: envelope.frameId,
                        suppressOrphansFor: [envelope.frameId]
                    )
                }
                beginFrame(envelope)
            } else if frameId != envelope.frameId ||
                        expectedChunkCount != envelope.chunkCount ||
                        expectedTotalBytes != envelope.totalBytes {
                let droppedFrame = frameId
                guard envelope.chunkIndex == 0,
                      envelope.chunkOffset == 0,
                      frameId != envelope.frameId else {
                    let orphanFrames = frameId == envelope.frameId
                        ? [droppedFrame ?? envelope.frameId]
                        : [droppedFrame, envelope.frameId].compactMap { $0 }
                    return drop(
                        reason: "out-of-order-or-new-frame",
                        frameId: orphanFrames.first ?? envelope.frameId,
                        suppressOrphansFor: orphanFrames
                    )
                }
                reset()
                beginFrame(envelope)
            }

            guard envelope.chunkIndex == nextChunkIndex,
                  envelope.chunkOffset == receivedBytes else {
                let droppedFrame = frameId ?? envelope.frameId
                return drop(
                    reason: "out-of-order-or-new-frame",
                    frameId: droppedFrame,
                    suppressOrphansFor: [droppedFrame]
                )
            }

            chunks.append(envelope.payload)
            receivedBytes += envelope.payload.count
            nextChunkIndex += 1
            lastUpdatedAt = now

            if nextChunkIndex == expectedChunkCount {
                guard receivedBytes == expectedTotalBytes else {
                    let droppedFrame = frameId
                    return drop(reason: "total-bytes-mismatch", frameId: droppedFrame)
                }
                let completeFrameId = frameId ?? envelope.frameId
                var payload = Data(capacity: expectedTotalBytes)
                for chunk in chunks { payload.append(chunk) }
                reset()
                return .complete(frameId: completeFrameId, payload: payload)
            }

            return .waiting(
                frameId: envelope.frameId,
                chunkIndex: envelope.chunkIndex,
                chunkCount: envelope.chunkCount
            )
        }
    }
}

@available(iOS 17.0, *)
private extension CrossNetworkWebRTCManager {
    @discardableResult
    private func handleDecodedScreenPlaintext(_ plaintext: Data) -> Bool {
        guard let screenData = Self.decodeScreenDataPayload(plaintext) else { return false }
        publishDecodedScreenData(screenData)
        return true
    }

    nonisolated private static func decodeScreenDataPayload(_ plaintext: Data) -> ScreenData? {
        if let screenData = RemoteDesktopScreenFrameWire.decodeIfPresent(plaintext) {
            return screenData
        }

        if let msg = try? JSONDecoder().decode(RemoteMessage.self, from: plaintext),
           msg.type == .screenData {
            return try? JSONDecoder().decode(ScreenData.self, from: msg.payload)
        }

        return nil
    }

    nonisolated private static func decodeRemoteDesktopHighThroughputPayload(
        _ plaintext: Data
    ) -> RemoteDesktopControlPayloadDecodeResult? {
        if let audioChunk = RemoteDesktopAudioChunkWire.decodeIfPresent(plaintext) {
            return .audio(audioChunk)
        }

        if let screenData = decodeScreenDataPayload(plaintext) {
            return .screen(screenData)
        }

        return nil
    }

    private func publishDecodedScreenData(_ screenData: ScreenData) {
        noteCurrentSessionActivity()
        lastScreenData = screenData
#if canImport(WebRTC)
        lastScreenDataAt = Date()
        maybeConfirmRemoteVideoTrackFromFallbackEvidence(now: lastScreenDataAt ?? Date())
#endif
        postScreenFrameNotification(screenData)
    }

    private func postScreenFrameNotification(_ screenData: ScreenData) {
        guard let sessionId = activeRemoteDesktopSessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionId.isEmpty else {
            return
        }

        NotificationCenter.default.post(
            name: .crossNetworkScreenDataUpdated,
            object: nil,
            userInfo: [
                CrossNetworkNotificationUserInfoKey.sessionId: sessionId,
                CrossNetworkNotificationUserInfoKey.screenData: screenData
            ]
        )
    }

    @MainActor
    private func sessionKeysIfCurrent(
        sessionId: String,
        sessionObjectIdentifier: ObjectIdentifier
    ) -> SessionKeys? {
        guard currentSessionId == sessionId,
              let session,
              ObjectIdentifier(session) == sessionObjectIdentifier else {
            return nil
        }
        return sessionKeys
    }

    @MainActor
    private func isCurrentSession(
        sessionId: String,
        sessionObjectIdentifier: ObjectIdentifier
    ) -> Bool {
        guard currentSessionId == sessionId,
              let session,
              ObjectIdentifier(session) == sessionObjectIdentifier else {
            return false
        }
        return true
    }

    @MainActor
    private func isStrictPQCClassicBootstrapOnlyCurrentSession(
        sessionId: String,
        sessionObjectIdentifier: ObjectIdentifier
    ) -> Bool {
        guard currentSessionId == sessionId,
              let session,
              ObjectIdentifier(session) == sessionObjectIdentifier else {
            return false
        }
        return strictPQCClassicBootstrapOnlySessionIds.contains(sessionId)
    }

    @MainActor
    @discardableResult
    private func publishHighThroughputRemoteDesktopPayloadIfCurrent(
        _ payload: RemoteDesktopControlPayloadDecodeResult,
        sessionId: String,
        sessionObjectIdentifier: ObjectIdentifier
    ) -> Bool {
        guard isCurrentSession(
            sessionId: sessionId,
            sessionObjectIdentifier: sessionObjectIdentifier
        ) else {
            return false
        }

        guard !isStrictPQCClassicBootstrapOnlyCurrentSession(
            sessionId: sessionId,
            sessionObjectIdentifier: sessionObjectIdentifier
        ) else {
            appendSmokeTrace("strict-pqc-bootstrap drop media payload source=control-channel session=\(sessionId)")
            SkyBridgeLogger.shared.debug(
                "ℹ️ WebRTC strictPQC classic bootstrap dropped media payload before PQC rekey: session=\(sessionId) source=control-channel"
            )
            return false
        }

        switch payload {
        case .screen(let screenData):
            publishDecodedScreenData(screenData)
        case .audio(let audioChunk):
            RemoteDesktopManager.instance.handleInboundRemoteAudioChunk(audioChunk)
        }
        return true
    }

    @discardableResult
    private func handleDecodedControlPlaintext(
        _ plaintext: Data,
        sessionId: String,
        peer: PeerIdentifier,
        session: WebRTCSession,
        strictPQCRequested: Bool
    ) async -> Bool {
        if let appMessage = try? JSONDecoder().decode(AppMessage.self, from: plaintext) {
            if strictPQCClassicBootstrapOnlySessionIds.contains(sessionId) {
                let messageKind = Self.bootstrapAppMessageKind(appMessage)
                switch appMessage {
                case .pairingIdentityExchange:
                    break
                case .heartbeat, .ping, .pong, .peerDisconnecting:
                    SkyBridgeLogger.shared.debug(
                        "ℹ️ WebRTC strictPQC classic bootstrap accepted control app message before PQC rekey: session=\(sessionId) type=\(messageKind) lastRekey=\(lastRekeyEvent ?? "-")"
                    )
                default:
                    SkyBridgeLogger.shared.debug(
                        "ℹ️ WebRTC strictPQC classic bootstrap ignored non-bootstrap app message: session=\(sessionId) type=\(messageKind) lastRekey=\(lastRekeyEvent ?? "-")"
                    )
                    return true
                }
            }
            await handleInboundAppMessageOverWebRTC(
                appMessage,
                sessionId: sessionId,
                peerDeviceId: peer.deviceId,
                session: session,
                strictPQCRequested: strictPQCRequested
            )
            return true
        }

        guard !strictPQCClassicBootstrapOnlySessionIds.contains(sessionId) else {
            SkyBridgeLogger.shared.debug(
                "ℹ️ WebRTC strictPQC classic bootstrap ignored business payload before PQC rekey: session=\(sessionId)"
            )
            return true
        }

        if let fileTransfer = try? JSONDecoder().decode(CrossNetworkFileTransferMessage.self, from: plaintext),
           fileTransfer.version == 1 {
            await handleInboundFileTransferFromMac(fileTransfer)
            return true
        }

        if let audioChunk = RemoteDesktopAudioChunkWire.decodeIfPresent(plaintext) {
            RemoteDesktopManager.instance.handleInboundRemoteAudioChunk(audioChunk)
            return true
        }

        if handleDecodedScreenPlaintext(plaintext) { return true }

        guard let msg = try? JSONDecoder().decode(RemoteMessage.self, from: plaintext) else {
            return false
        }

        if msg.type == .damageReport,
           let report = try? JSONDecoder().decode(RemoteDesktopDamageReportPayload.self, from: msg.payload) {
            RemoteDesktopManager.instance.handleInboundDamageReport(report)
            return true
        }

        if msg.type == .cursorUpdate,
           let payload = try? JSONDecoder().decode(RemoteDesktopCursorPayload.self, from: msg.payload) {
            RemoteDesktopManager.instance.handleInboundCursorUpdate(payload)
            return true
        }

        if msg.type == .overlayUpdate,
           let payload = try? JSONDecoder().decode(RemoteDesktopOverlayPayload.self, from: msg.payload) {
            RemoteDesktopManager.instance.handleInboundOverlayUpdate(payload)
            return true
        }

        if msg.type == .streamConfigurationAck,
           let payload = try? JSONDecoder().decode(RemoteDesktopStreamConfigurationAckPayload.self, from: msg.payload) {
            RemoteDesktopManager.instance.handleStreamConfigurationAck(payload)
            return true
        }

        if msg.type == .clipboard,
           let payload = try? JSONDecoder().decode(RemoteClipboardMessagePayload.self, from: msg.payload) {
            RemoteDesktopManager.instance.handleInboundRemoteClipboard(
                data: payload.data,
                mimeType: payload.mimeType,
                fromDeviceId: remoteDeviceId
            )
            return true
        }

        return false
    }

    private static func bootstrapAppMessageKind(_ message: AppMessage) -> String {
        switch message {
        case .clipboard:
            return "clipboard"
        case .pairingIdentityExchange:
            return "pairingIdentityExchange"
        case .heartbeat:
            return "heartbeat"
        case .peerDisconnecting:
            return "peerDisconnecting"
        case .ping:
            return "ping"
        case .pong:
            return "pong"
        }
    }

    nonisolated private func isLikelyCompleteHandshakeControlPacket(_ data: Data) -> Bool {
        let frame = HandshakePadding.unwrapIfNeeded(data, label: "rx/webrtc")
        if frame.count == 38, (try? HandshakeFinished.decode(from: frame)) != nil { return true }
        guard frame.count >= 5 else { return false }
        guard frame.first == HandshakeConstants.protocolVersion else { return false }
        if (try? HandshakeMessageA.decode(from: frame)) != nil { return true }
        if (try? HandshakeMessageB.decode(from: frame)) != nil { return true }
        return false
    }

    nonisolated private func isActiveHandshakeDriverFrame(_ data: Data) -> Bool {
        let frame = HandshakePadding.unwrapIfNeeded(data, label: "rx/webrtc")
        if isLikelyCompleteHandshakeControlPacket(frame) { return true }
        return false
    }

    private func hasActiveHandshakeDriver() -> Bool {
        handshakeDriver != nil
    }

    @discardableResult
    private func handlePossibleHandshakeControlFrame(
        _ frame: Data,
        sessionId: String,
        peer: PeerIdentifier,
        session: WebRTCSession,
        strictPQCRequested: Bool
    ) async -> Bool {
        let inboundInitialDriver = await ensureInboundInitialHandshakeDriverIfNeeded(
            sessionId: sessionId,
            frame: frame,
            peer: peer,
            session: session,
            strictPQCRequested: strictPQCRequested
        )
        let inboundRekeyDriver = await ensureInboundPQCRekeyDriverIfNeeded(
            sessionId: sessionId,
            frame: frame,
            peer: peer,
            session: session,
            strictPQCRequested: strictPQCRequested
        )

        if let inboundDriver = inboundInitialDriver ?? inboundRekeyDriver {
            if let messageA = try? HandshakeMessageA.decode(from: frame) {
                let suites = messageA.supportedSuites.map(\.rawValue).joined(separator: ",")
                appendSmokeTrace("rx messageA raw=\(frame.count) suites=\(suites)")
                if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                    print("🧪 WebRTC rekey rx MessageA raw=\(frame.count) suites=\(suites)")
                }
            }
            await inboundDriver.handleMessage(frame, from: peer)
            if inboundInitialHandshakeResponderSessionIds.contains(sessionId) {
                await syncInboundInitialHandshakeState(
                    sessionId: sessionId,
                    strictPQCRequested: strictPQCRequested
                )
            } else {
                await syncInboundPQCRekeyState(
                    sessionId: sessionId,
                    strictPQCRequested: strictPQCRequested
                )
            }
            return true
        }

        if let driver = handshakeDriver {
            guard isActiveHandshakeDriverFrame(frame) else {
                return false
            }
            if let messageB = try? HandshakeMessageB.decode(from: frame) {
                lastRekeyEvent = "messageB suite=\(messageB.selectedSuite.rawValue)"
                appendSmokeTrace("rx messageB raw=\(frame.count) suite=\(messageB.selectedSuite.rawValue)")
                if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                    print("🧪 WebRTC rekey rx MessageB raw=\(frame.count) suite=\(messageB.selectedSuite.rawValue)")
                }
            } else if (try? HandshakeFinished.decode(from: frame)) != nil {
                lastRekeyEvent = "finished"
                appendSmokeTrace("rx finished raw=\(frame.count)")
                if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                    print("🧪 WebRTC rekey rx Finished raw=\(frame.count)")
                }
            }
            await driver.handleMessage(frame, from: peer)
            await syncInboundPQCRekeyState(
                sessionId: sessionId,
                strictPQCRequested: strictPQCRequested
            )
            return true
        }

        return false
    }

    nonisolated private static func decodeDirectScreenChannelPayload(
        _ payload: Data,
        keys: SessionKeys
    ) -> ScreenData? {
        let trafficUnwrapped = TrafficPadding.unwrapIfNeeded(payload, label: "rx/webrtc-screen")
        guard let plaintext = try? decryptScreenPayload(ciphertext: trafficUnwrapped, with: keys) else {
            return nil
        }
        return decodeScreenDataPayload(plaintext)
    }

    nonisolated private static func decodeEncryptedScreenChannelPayload(
        _ payload: Data,
        keys: SessionKeys
    ) throws -> ScreenData? {
        let trafficUnwrapped = TrafficPadding.unwrapIfNeeded(payload, label: "rx/webrtc-screen")
        let plaintext = try decryptScreenPayload(ciphertext: trafficUnwrapped, with: keys)
        return decodeScreenDataPayload(plaintext)
    }

    nonisolated private static func decryptScreenPayload(
        ciphertext: Data,
        with keys: SessionKeys
    ) throws -> Data {
        let key = SymmetricKey(data: keys.receiveKey)
        let box = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(box, using: key)
    }

    nonisolated private static func decryptDirectControlProbePayload(
        _ payload: Data,
        keys: SessionKeys
    ) -> Data? {
        let trafficUnwrapped = TrafficPadding.unwrapIfNeeded(payload, label: "rx/webrtc")
        let key = SymmetricKey(data: keys.receiveKey)
        guard let box = try? AES.GCM.SealedBox(combined: trafficUnwrapped) else {
            return nil
        }
        return try? AES.GCM.open(box, using: key)
    }

    nonisolated func receiveLoop(
        sessionId: String,
        session: WebRTCSession,
        inbound: InboundChunkQueue,
        peer: PeerIdentifier,
        strictPQCRequested: Bool
    ) async {
        let sessionObjectIdentifier = ObjectIdentifier(session)
        let maxInboundFrameBytes = 8_000_000
        do {
            self.appendSmokeTrace("receiveLoop start session=\(sessionId)")
            var parser = InboundFrameParser(maxInboundFrameBytes: maxInboundFrameBytes)
            var usesDirectControlPayloads = false
            while !Task.isCancelled {
                let chunk = try await inbound.next()

                if parser.canProbeDirectCompatibility,
                   await isCurrentSession(
                    sessionId: sessionId,
                    sessionObjectIdentifier: sessionObjectIdentifier
                   ) {
                    if let keys = await sessionKeysIfCurrent(
                        sessionId: sessionId,
                        sessionObjectIdentifier: sessionObjectIdentifier
                    ), let plaintext = Self.decryptDirectControlProbePayload(chunk, keys: keys) {
                        if let decoded = Self.decodeRemoteDesktopHighThroughputPayload(plaintext) {
                            let published = await publishHighThroughputRemoteDesktopPayloadIfCurrent(
                                decoded,
                                sessionId: sessionId,
                                sessionObjectIdentifier: sessionObjectIdentifier
                            )
                            if published && !usesDirectControlPayloads {
                                usesDirectControlPayloads = true
                                parser = InboundFrameParser(maxInboundFrameBytes: maxInboundFrameBytes)
                                self.appendSmokeTrace(
                                    "control-channel direct-payload compatibility mode session=\(sessionId) bytes=\(chunk.count)"
                                )
                                SkyBridgeLogger.shared.info(
                                    "ℹ️ WebRTC 控制通道检测到直发远桌数据模式，已在后台数据面处理: session=\(sessionId)"
                                )
                            }
                            continue
                        }

                        if await handleDecodedControlPlaintext(
                            plaintext,
                            sessionId: sessionId,
                            peer: peer,
                            session: session,
                            strictPQCRequested: strictPQCRequested
                        ) {
                            if !usesDirectControlPayloads {
                                usesDirectControlPayloads = true
                                parser = InboundFrameParser(maxInboundFrameBytes: maxInboundFrameBytes)
                                self.appendSmokeTrace(
                                    "control-channel direct-payload compatibility mode session=\(sessionId) bytes=\(chunk.count)"
                                )
                                SkyBridgeLogger.shared.info(
                                    "ℹ️ WebRTC 控制通道检测到直发兼容模式，已跳过分帧解析: session=\(sessionId)"
                                )
                            }
                            continue
                        }
                    }

                    let trafficUnwrapped = TrafficPadding.unwrapIfNeeded(chunk, label: "rx/webrtc")
                    let handshakeUnwrapped = HandshakePadding.unwrapIfNeeded(
                        trafficUnwrapped,
                        label: "rx/webrtc-direct"
                    )
                    if isLikelyCompleteHandshakeControlPacket(handshakeUnwrapped),
                       await handlePossibleHandshakeControlFrame(
                        handshakeUnwrapped,
                        sessionId: sessionId,
                        peer: peer,
                        session: session,
                        strictPQCRequested: strictPQCRequested
                       ) {
                        if !usesDirectControlPayloads {
                            usesDirectControlPayloads = true
                            parser = InboundFrameParser(maxInboundFrameBytes: maxInboundFrameBytes)
                            self.appendSmokeTrace(
                                "control-channel direct-handshake compatibility mode session=\(sessionId) bytes=\(chunk.count)"
                            )
                            SkyBridgeLogger.shared.info(
                                "ℹ️ WebRTC 控制通道检测到直发握手兼容模式，已跳过分帧解析: session=\(sessionId)"
                            )
                        }
                        continue
                    }
                }
                parser.append(chunk)

                while let payload = parser.nextPayload(sessionId: sessionId, logLabel: "WebRTC") {
                    let length = payload.count
                    let trafficUnwrapped = TrafficPadding.unwrapIfNeeded(payload, label: "rx/webrtc")
                    if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                        print("🧪 WebRTC rekey rx frame len=\(length)")
                    }
                    let handshakeFrame = HandshakePadding.unwrapIfNeeded(
                        trafficUnwrapped,
                        label: "rx/webrtc"
                    )
                    let hasActiveDriver = await hasActiveHandshakeDriver()
                    if (isLikelyCompleteHandshakeControlPacket(handshakeFrame) ||
                        (hasActiveDriver && isActiveHandshakeDriverFrame(handshakeFrame))),
                       await handlePossibleHandshakeControlFrame(
                        handshakeFrame,
                        sessionId: sessionId,
                        peer: peer,
                        session: session,
                        strictPQCRequested: strictPQCRequested
                       ) {
                        continue
                    }
                    let hasSessionKeys: Bool
                    if let keys = await sessionKeysIfCurrent(
                        sessionId: sessionId,
                        sessionObjectIdentifier: sessionObjectIdentifier
                    ) {
                        hasSessionKeys = true
                        do {
                            let plaintext = try decrypt(ciphertext: trafficUnwrapped, with: keys)
                            if let decoded = Self.decodeRemoteDesktopHighThroughputPayload(plaintext) {
                                _ = await publishHighThroughputRemoteDesktopPayloadIfCurrent(
                                    decoded,
                                    sessionId: sessionId,
                                    sessionObjectIdentifier: sessionObjectIdentifier
                                )
                                continue
                            }
                            if await handleDecodedControlPlaintext(
                                plaintext,
                                sessionId: sessionId,
                                peer: peer,
                                session: session,
                                strictPQCRequested: strictPQCRequested
                            ) {
                                continue
                            }
                        } catch {
                            // Fall through into handshake-control handling.
                        }
                    } else {
                        hasSessionKeys = false
                    }
                    self.appendSmokeTrace("rx frame len=\(length) keys=\(hasSessionKeys)")

                    if isLikelyCompleteHandshakeControlPacket(handshakeFrame) {
                        _ = await handlePossibleHandshakeControlFrame(
                            handshakeFrame,
                            sessionId: sessionId,
                            peer: peer,
                            session: session,
                            strictPQCRequested: strictPQCRequested
                        )
                    } else if strictPQCRequested, hasSessionKeys, length >= 1024 {
                        let sbp1Wrapped = trafficUnwrapped.count >= 4
                            && trafficUnwrapped.prefix(4).elementsEqual([0x53, 0x42, 0x50, 0x31])
                        let firstByte = handshakeFrame.first
                            .map { String(format: "%02x", $0) } ?? "-"
                        let decodeFailure: String
                        do {
                            _ = try HandshakeMessageA.decode(from: handshakeFrame)
                            decodeFailure = "none"
                        } catch {
                            decodeFailure = Self.smokeTraceToken(error.localizedDescription)
                        }
                        self.appendSmokeTrace(
                            "handshake-control decode-miss session=\(sessionId) frame=\(length) raw=\(handshakeFrame.count) first=\(firstByte) sbp1=\(sbp1Wrapped) messageA=\(decodeFailure)"
                        )
                    }
                }
            }
        } catch {
            self.appendSmokeTrace("receiveLoop ended error=\(error.localizedDescription)")
        }
    }

    nonisolated func receiveScreenLoop(
        sessionId: String,
        sessionObjectIdentifier: ObjectIdentifier,
        inbound: InboundChunkQueue
    ) async {
        let maxInboundFrameBytes = 8_000_000
        do {
            self.appendSmokeTrace("screen-receiveLoop start session=\(sessionId)")
            var wireDecoder = ScreenChannelWireDecoder(maxInboundFrameBytes: maxInboundFrameBytes)
            var announcedWireMode: ScreenChannelWireDecoder.Mode?

            while !Task.isCancelled {
                let chunk = try await inbound.next()
                let now = Date()
                let keys = await screenReceiveSessionKeysIfCurrent(
                    sessionId: sessionId,
                    sessionObjectIdentifier: sessionObjectIdentifier
                )

                if let keys,
                   let pending = wireDecoder.takePendingDirectCandidate(now: now) {
                    if let screenData = Self.decodeDirectScreenChannelPayload(pending, keys: keys) {
                        wireDecoder.markDirectPayloadMode()
                        if announcedWireMode != wireDecoder.mode {
                            announcedWireMode = wireDecoder.mode
                            self.appendSmokeTrace(
                                "screen-channel wire-mode=\(wireDecoder.mode.rawValue) session=\(sessionId) bytes=\(pending.count) source=pending-direct"
                            )
                            SkyBridgeLogger.shared.info(
                                "ℹ️ screen-channel wire 模式锁定: mode=\(wireDecoder.mode.rawValue) session=\(sessionId)"
                            )
                        }
                        await publishDecodedScreenDataIfCurrent(
                            screenData,
                            sessionId: sessionId,
                            sessionObjectIdentifier: sessionObjectIdentifier
                        )
                    } else {
                        self.appendSmokeTrace(
                            "screen-channel wireMode=waiting-keys-drop session=\(sessionId) bytes=\(pending.count)"
                        )
                        SkyBridgeLogger.shared.debug(
                            "ℹ️ screen-channel direct candidate 解密失败，已丢弃: mode=waiting-keys-drop session=\(sessionId) bytes=\(pending.count)"
                        )
                    }
                }

                if wireDecoder.isChunkedPayload(chunk) {
                    switch wireDecoder.appendChunkedPayload(chunk, now: now) {
                    case .waiting(let frameId, let chunkIndex, let chunkCount):
                        if chunkIndex == 0 {
                            self.appendSmokeTrace(
                                "screen-channel wire=sbc2-chunked-v1 frameId=\(frameId) chunk=1/\(chunkCount) session=\(sessionId)"
                            )
                        }
                        continue
                    case .dropped(let reason, let frameId):
                        self.appendSmokeTrace(
                            "screen-channel wire=sbc2-chunked-v1 reassemblyDropReason=\(reason) frameId=\(frameId.map(String.init) ?? "-") session=\(sessionId)"
                        )
                        SkyBridgeLogger.shared.debug(
                            "ℹ️ screen-channel SBC2 分片已丢弃: reason=\(reason) frameId=\(frameId.map(String.init) ?? "-") session=\(sessionId)"
                        )
                        continue
                    case .suppressed:
                        continue
                    case .complete(let frameId, let payload):
                        guard let frameKeys = await screenReceiveSessionKeysIfCurrent(
                            sessionId: sessionId,
                            sessionObjectIdentifier: sessionObjectIdentifier
                        ) else {
                            self.appendSmokeTrace(
                                "screen-channel wire=sbc2-chunked-v1 waiting-keys-drop frameId=\(frameId) session=\(sessionId)"
                            )
                            continue
                        }
                        do {
                            guard let screenData = try Self.decodeEncryptedScreenChannelPayload(payload, keys: frameKeys) else {
                                continue
                            }
                            wireDecoder.markChunkedPayloadMode()
                            if announcedWireMode != wireDecoder.mode {
                                announcedWireMode = wireDecoder.mode
                                self.appendSmokeTrace(
                                    "screen-channel wire-mode=\(wireDecoder.mode.rawValue) session=\(sessionId) frameId=\(frameId)"
                                )
                                SkyBridgeLogger.shared.info(
                                    "ℹ️ screen-channel wire 模式锁定: mode=\(wireDecoder.mode.rawValue) session=\(sessionId)"
                                )
                            }
                            await publishDecodedScreenDataIfCurrent(
                                screenData,
                                sessionId: sessionId,
                                sessionObjectIdentifier: sessionObjectIdentifier
                            )
                        } catch {
                            self.appendSmokeTrace(
                                "screen-channel wire=sbc2-chunked-v1 decryptFailed frameId=\(frameId) session=\(sessionId)"
                            )
                            SkyBridgeLogger.shared.debug(
                                "ℹ️ screen-channel SBC2 payload 解密/解析失败: \(error.localizedDescription)"
                            )
                        }
                        continue
                    }
                }

                if wireDecoder.mode == .directPayload {
                    guard let keys else {
                        _ = wireDecoder.cacheDirectCandidateIfPossible(chunk, now: now)
                        self.appendSmokeTrace(
                            "screen-channel wireMode=directPayload waiting-keys session=\(sessionId) bytes=\(chunk.count)"
                        )
                        continue
                    }

                    if let screenData = Self.decodeDirectScreenChannelPayload(chunk, keys: keys) {
                        await publishDecodedScreenDataIfCurrent(
                            screenData,
                            sessionId: sessionId,
                            sessionObjectIdentifier: sessionObjectIdentifier
                        )
                    } else {
                        SkyBridgeLogger.shared.debug(
                            "ℹ️ screen-channel direct payload 解密/解析失败，已丢弃: session=\(sessionId) bytes=\(chunk.count)"
                        )
                    }
                    continue
                }

                if wireDecoder.canProbeDirectPayload,
                   let keys,
                   let screenData = Self.decodeDirectScreenChannelPayload(chunk, keys: keys) {
                    wireDecoder.markDirectPayloadMode()
                    if announcedWireMode != wireDecoder.mode {
                        announcedWireMode = wireDecoder.mode
                        self.appendSmokeTrace(
                            "screen-channel wire-mode=\(wireDecoder.mode.rawValue) session=\(sessionId) bytes=\(chunk.count) source=direct-probe"
                        )
                        SkyBridgeLogger.shared.info(
                            "ℹ️ screen-channel wire 模式锁定: mode=\(wireDecoder.mode.rawValue) session=\(sessionId)"
                        )
                    }
                    await publishDecodedScreenDataIfCurrent(
                        screenData,
                        sessionId: sessionId,
                        sessionObjectIdentifier: sessionObjectIdentifier
                    )
                    continue
                }

                if wireDecoder.shouldKeepOutOfLengthParser(chunk) {
                    if keys == nil,
                       wireDecoder.cacheDirectCandidateIfPossible(chunk, now: now) {
                        self.appendSmokeTrace(
                            "screen-channel wireMode=waiting-keys-cache session=\(sessionId) bytes=\(chunk.count)"
                        )
                        SkyBridgeLogger.shared.debug(
                            "ℹ️ screen-channel direct-looking payload 已等待密钥后重试: session=\(sessionId) bytes=\(chunk.count)"
                        )
                    } else {
                        self.appendSmokeTrace(
                            "screen-channel wireMode=direct-candidate-drop session=\(sessionId) bytes=\(chunk.count)"
                        )
                        SkyBridgeLogger.shared.debug(
                            "ℹ️ screen-channel direct-looking payload 未通过解密/解析，已丢弃且未进入 length parser: session=\(sessionId) bytes=\(chunk.count)"
                        )
                    }
                    continue
                }

                wireDecoder.appendLengthChunk(chunk)

                while let payload = wireDecoder.nextLengthPayload(sessionId: sessionId, logLabel: "screen-channel") {
                    guard let frameKeys = await screenReceiveSessionKeysIfCurrent(
                        sessionId: sessionId,
                        sessionObjectIdentifier: sessionObjectIdentifier
                    ) else {
                        continue
                    }

                    do {
                        guard let screenData = try Self.decodeEncryptedScreenChannelPayload(payload, keys: frameKeys) else {
                            wireDecoder.resetLengthFramedAfterDecodeFailure()
                            announcedWireMode = nil
                            self.appendSmokeTrace(
                                "screen-channel wire=length-framed decodeEmpty reset session=\(sessionId)"
                            )
                            continue
                        }
                        wireDecoder.markLengthFramedMode()
                        if announcedWireMode != wireDecoder.mode {
                            announcedWireMode = wireDecoder.mode
                            self.appendSmokeTrace(
                                "screen-channel wire-mode=\(wireDecoder.mode.rawValue) session=\(sessionId) payloadBytes=\(payload.count)"
                            )
                            SkyBridgeLogger.shared.info(
                                "ℹ️ screen-channel wire 模式锁定: mode=\(wireDecoder.mode.rawValue) session=\(sessionId)"
                            )
                        }
                        await publishDecodedScreenDataIfCurrent(
                            screenData,
                            sessionId: sessionId,
                            sessionObjectIdentifier: sessionObjectIdentifier
                        )
                    } catch {
                        wireDecoder.resetLengthFramedAfterDecodeFailure()
                        announcedWireMode = nil
                        self.appendSmokeTrace(
                            "screen-channel wire=length-framed decryptFailed reset session=\(sessionId)"
                        )
                        SkyBridgeLogger.shared.debug(
                            "ℹ️ screen-channel payload 解密/解析失败，已重置 length parser: wireMode=lengthFramed \(error.localizedDescription)"
                        )
                    }
                }
            }
        } catch {
            self.appendSmokeTrace("screen-receiveLoop ended error=\(error.localizedDescription)")
        }
    }

    @MainActor
    private func screenReceiveSessionKeysIfCurrent(
        sessionId: String,
        sessionObjectIdentifier: ObjectIdentifier
    ) -> SessionKeys? {
        guard currentSessionId == sessionId,
              let session,
              ObjectIdentifier(session) == sessionObjectIdentifier else {
            return nil
        }
        return sessionKeys
    }

    @MainActor
    @discardableResult
    private func publishDecodedScreenDataIfCurrent(
        _ screenData: ScreenData,
        sessionId: String,
        sessionObjectIdentifier: ObjectIdentifier
    ) -> Bool {
        guard currentSessionId == sessionId,
              let session,
              ObjectIdentifier(session) == sessionObjectIdentifier else {
            return false
        }
        guard !strictPQCClassicBootstrapOnlySessionIds.contains(sessionId) else {
            appendSmokeTrace("strict-pqc-bootstrap drop media payload source=screen-channel session=\(sessionId)")
            SkyBridgeLogger.shared.debug(
                "ℹ️ WebRTC strictPQC classic bootstrap dropped media payload before PQC rekey: session=\(sessionId) source=screen-channel"
            )
            return false
        }
        publishDecodedScreenData(screenData)
        return true
    }

    func sendFramed(_ data: Data, over session: WebRTCSession) async throws {
        try await session.sendFramedPayloadAsync(data)
    }

    nonisolated func encrypt(plaintext: Data, with keys: SessionKeys) throws -> Data {
        let key = SymmetricKey(data: keys.sendKey)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        return sealed.combined ?? Data()
    }

    nonisolated func decrypt(ciphertext: Data, with keys: SessionKeys) throws -> Data {
        let key = SymmetricKey(data: keys.receiveKey)
        let box = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(box, using: key)
    }

    nonisolated func appendSmokeTrace(_ line: String) {
        SkyBridgeSmokeTraceWriter.append(line)
    }

    nonisolated private static func smokeTraceToken(_ value: String) -> String {
        let sanitized = value
            .replacingOccurrences(of: "\n", with: "_")
            .replacingOccurrences(of: "\r", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        let allowed = sanitized.filter { character in
            character.isLetter || character.isNumber || character == "_" || character == "-" || character == "."
        }
        return String(allowed.prefix(120))
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
        var mediaSections = 0
        var hasVideo = false
        var videoDirection = "unspecified"
        var inVideoSection = false

        for rawLine in sdp.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("m=") {
                mediaSections += 1
                inVideoSection = line.hasPrefix("m=video ")
                if inVideoSection {
                    hasVideo = true
                    videoDirection = "unspecified"
                }
                continue
            }

            if inVideoSection, line.hasPrefix("a=") {
                if line == "a=sendrecv" {
                    videoDirection = "sendrecv"
                } else if line == "a=sendonly" {
                    videoDirection = "sendonly"
                } else if line == "a=recvonly" {
                    videoDirection = "recvonly"
                } else if line == "a=inactive" {
                    videoDirection = "inactive"
                }
            }

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

        return "media=\(mediaSections) hasVideo=\(hasVideo) videoDir=\(videoDirection) candidates total=\(total) host=\(host) srflx=\(srflx) relay=\(relay) prflx=\(prflx)"
    }
}

@available(iOS 17.0, *)
extension CrossNetworkWebRTCManager {
    nonisolated private static func inboundPQCRekeySelectionPolicy(
        supportedSuites: [CryptoSuite],
        strictPQCRequested: Bool,
        localPQCAvailable: Bool
    ) -> CryptoProviderFactory.SelectionPolicy? {
        let hasPQCGroup = supportedSuites.contains { $0.isPQCGroup }
        guard !strictPQCRequested || hasPQCGroup else { return nil }
        guard !strictPQCRequested || localPQCAvailable else { return nil }
        return hasPQCGroup ? (strictPQCRequested ? .requirePQC : .preferPQC) : .classicOnly
    }

    nonisolated private static func inboundInitialHandshakeSelectionPolicy(
        supportedSuites: [CryptoSuite],
        strictPQCRequested: Bool,
        localPQCAvailable: Bool,
        expectedRemoteAuthorityAlgorithm: ProtocolSigningAlgorithm?
    ) -> CryptoProviderFactory.SelectionPolicy? {
        let hasPQCGroup = supportedSuites.contains { $0.isPQCGroup }
        if hasPQCGroup {
            guard !strictPQCRequested || localPQCAvailable else { return nil }
            return strictPQCRequested ? .requirePQC : .preferPQC
        }
        guard !strictPQCRequested || shouldAllowClassicAuthorityBootstrapForInboundInitialWebRTCHandshake(
            supportedSuites: supportedSuites,
            strictPQCRequested: strictPQCRequested,
            expectedRemoteAuthorityAlgorithm: expectedRemoteAuthorityAlgorithm
        ) else {
            return nil
        }
        return .classicOnly
    }

    nonisolated private static func shouldAllowClassicAuthorityBootstrapForInboundInitialWebRTCHandshake(
        supportedSuites: [CryptoSuite],
        strictPQCRequested: Bool,
        expectedRemoteAuthorityAlgorithm: ProtocolSigningAlgorithm?
    ) -> Bool {
        strictPQCRequested
            && expectedRemoteAuthorityAlgorithm == .ed25519
            && !supportedSuites.contains(where: { $0.isPQCGroup })
            && supportedSuites.contains(where: { !$0.isPQCGroup })
    }

    nonisolated private static func inboundPQCRekeyNegotiatedSuiteAllowed(
        _ suite: CryptoSuite,
        strictPQCRequested: Bool
    ) -> Bool {
        !strictPQCRequested || suite.isPQCGroup
    }

    nonisolated private static func inboundInitialHandshakeNegotiatedSuiteAllowed(
        _ suite: CryptoSuite,
        strictPQCRequested: Bool,
        allowsClassicAuthorityBootstrap: Bool
    ) -> Bool {
        !strictPQCRequested
            || suite.isPQCGroup
            || (allowsClassicAuthorityBootstrap && !suite.isPQCGroup)
    }

    nonisolated internal static func testOnlyDecryptDirectControlProbePayload(
        _ payload: Data,
        keys: SessionKeys
    ) -> Data? {
        decryptDirectControlProbePayload(payload, keys: keys)
    }

    nonisolated internal static func testOnlyDecodeHighThroughputRemoteDesktopPayloadKind(
        _ plaintext: Data
    ) -> String? {
        switch decodeRemoteDesktopHighThroughputPayload(plaintext) {
        case .screen:
            return "screen"
        case .audio:
            return "audio"
        case nil:
            return nil
        }
    }

    nonisolated internal static func testOnlyDecodeDirectScreenChannelPayloadKind(
        _ payload: Data,
        keys: SessionKeys
    ) -> String? {
        decodeDirectScreenChannelPayload(payload, keys: keys).map { _ in "screen" }
    }

    nonisolated internal static func testOnlyDecodeEncryptedScreenChannelPayloadKind(
        _ payload: Data,
        keys: SessionKeys
    ) throws -> String? {
        try decodeEncryptedScreenChannelPayload(payload, keys: keys).map { _ in "screen" }
    }

    nonisolated internal static func testOnlyMediaRelayLeaseFailureReason(status: Int, body: String) -> String {
        mediaRelayLeaseFailureReason(for: SignalServerClientCompat.ClientError.serverRejected(status, body))
    }

    nonisolated internal static func testOnlyMediaRelayLeaseFailureReasonAfterRefresh(status: Int, body: String) -> String {
        mediaRelayLeaseFailureReasonAfterRefresh(for: SignalServerClientCompat.ClientError.serverRejected(status, body))
    }

    nonisolated internal static func testOnlyMediaAdmissionRefreshFailureReason(status: Int, body: String) -> String {
        mediaAdmissionRefreshFailureReason(for: SignalServerClientCompat.ClientError.serverRejected(status, body))
    }

    nonisolated internal static func testOnlySessionRefreshFailureReason(status: Int, body: String) -> String {
        sessionRefreshFailureReason(for: SignalServerClientCompat.ClientError.serverRejected(status, body))
    }

    nonisolated internal static func testOnlyDecodeMediaRelayLeaseResponse(_ data: Data) throws -> (
        localToken: String?,
        localRole: String,
        localExpiresAt: TimeInterval?
    ) {
        let lease = try SignalServerClientCompat.testOnlyDecodeMediaRelayLeaseResponse(data)
        return (
            localToken: lease.endpoint.relayToken,
            localRole: lease.role,
            localExpiresAt: lease.endpoint.expiresAt
        )
    }

    nonisolated internal static func testOnlyShouldReuseRedeemedQRSessionArtifacts(
        canonicalQRSignalingOrigin: String,
        qrDeviceId: String,
        qrProtocolSigningAlgorithm: ProtocolSigningAlgorithm,
        qrProtocolPublicKeyFingerprint: String,
        qrProtocolPublicKeyBytes: Data,
        signalingToken: String?,
        turnAdmissionToken: String?,
        cachedSignalingOrigin: String?,
        cachedAuthorityDeviceId: String?,
        cachedAuthorityProtocolSigningAlgorithm: ProtocolSigningAlgorithm?,
        cachedAuthorityProtocolPublicKeyFingerprint: String?,
        cachedAuthorityProtocolPublicKeyBytes: Data = Data()
    ) -> Bool {
        let cachedAuthority: CurrentPathRemoteAuthorityCompat?
        if let cachedAuthorityDeviceId,
           let cachedAuthorityProtocolSigningAlgorithm,
           let cachedAuthorityProtocolPublicKeyFingerprint {
            cachedAuthority = CurrentPathRemoteAuthorityCompat(
                deviceId: cachedAuthorityDeviceId,
                protocolSigningAlgorithm: cachedAuthorityProtocolSigningAlgorithm,
                protocolPublicKeyFingerprint: cachedAuthorityProtocolPublicKeyFingerprint,
                protocolPublicKeyBytes: cachedAuthorityProtocolPublicKeyBytes,
                deviceName: nil
            )
        } else {
            cachedAuthority = nil
        }

        return shouldReuseRedeemedQRSessionArtifacts(
            canonicalQRSignalingOrigin: canonicalQRSignalingOrigin,
            qrDeviceId: qrDeviceId,
            qrProtocolSigningAlgorithm: qrProtocolSigningAlgorithm,
            qrProtocolPublicKeyFingerprint: qrProtocolPublicKeyFingerprint,
            qrProtocolPublicKeyBytes: qrProtocolPublicKeyBytes,
            signalingToken: normalizedNonEmptyToken(signalingToken),
            turnAdmissionToken: normalizedNonEmptyToken(turnAdmissionToken),
            cachedSignalingOrigin: cachedSignalingOrigin,
            cachedAuthority: cachedAuthority
        )
    }

    nonisolated internal static func testOnlyIsActualNativeRenderEvidence(_ source: String) -> Bool {
        isActualNativeRenderEvidence(source: source)
    }

    nonisolated internal static func testOnlyInboundPQCRekeySelectionPolicy(
        supportedSuites: [CryptoSuite],
        strictPQCRequested: Bool,
        localPQCAvailable: Bool
    ) -> CryptoProviderFactory.SelectionPolicy? {
        inboundPQCRekeySelectionPolicy(
            supportedSuites: supportedSuites,
            strictPQCRequested: strictPQCRequested,
            localPQCAvailable: localPQCAvailable
        )
    }

    nonisolated internal static func testOnlyInboundPQCRekeyNegotiatedSuiteAllowed(
        _ suite: CryptoSuite,
        strictPQCRequested: Bool
    ) -> Bool {
        inboundPQCRekeyNegotiatedSuiteAllowed(
            suite,
            strictPQCRequested: strictPQCRequested
        )
    }

    nonisolated internal static func testOnlyResolveTrustedPeerKEMCoverage(
        requiredSuites: [CryptoSuite],
        trustedPeerKEM: [CryptoSuite: Data]
    ) -> (availableSuites: [CryptoSuite], missingSuites: [CryptoSuite]) {
        resolveTrustedPeerKEMCoverage(
            requiredSuites: requiredSuites,
            trustedPeerKEM: trustedPeerKEM
        )
    }

    nonisolated internal static func testOnlyStrictPQCRekeyCandidateSuites(
        capability: CryptoProviderFactory.Capability,
        selectedProviderSuites: [CryptoSuite],
        selectedProviderTier: CryptoTier,
        appleXWingAvailable: Bool
    ) -> [CryptoSuite] {
        strictPQCRekeyCandidateSuites(
            capability: capability,
            selectedProviderSuites: selectedProviderSuites,
            selectedProviderTier: selectedProviderTier,
            appleXWingAvailable: appleXWingAvailable
        )
    }

    nonisolated internal static func testOnlyWebRTCPQCRekeyProviderPlans(
        capability: CryptoProviderFactory.Capability,
        prefersLiboqsForPeer: Bool,
        peerHasXWing: Bool,
        appleXWingAvailable: Bool
    ) -> [WebRTCPQCRekeyProviderPlan] {
        webRTCPQCRekeyProviderPlans(
            capability: capability,
            prefersLiboqsForPeer: prefersLiboqsForPeer,
            peerHasXWing: peerHasXWing,
            appleXWingAvailable: appleXWingAvailable
        )
    }

    nonisolated internal static func testOnlyInboundInitialHandshakeSelectionPolicy(
        supportedSuites: [CryptoSuite],
        strictPQCRequested: Bool,
        localPQCAvailable: Bool,
        expectedRemoteAuthorityAlgorithm: ProtocolSigningAlgorithm?
    ) -> CryptoProviderFactory.SelectionPolicy? {
        inboundInitialHandshakeSelectionPolicy(
            supportedSuites: supportedSuites,
            strictPQCRequested: strictPQCRequested,
            localPQCAvailable: localPQCAvailable,
            expectedRemoteAuthorityAlgorithm: expectedRemoteAuthorityAlgorithm
        )
    }

    nonisolated internal static func testOnlyInboundInitialHandshakeNegotiatedSuiteAllowed(
        _ suite: CryptoSuite,
        strictPQCRequested: Bool,
        allowsClassicAuthorityBootstrap: Bool
    ) -> Bool {
        inboundInitialHandshakeNegotiatedSuiteAllowed(
            suite,
            strictPQCRequested: strictPQCRequested,
            allowsClassicAuthorityBootstrap: allowsClassicAuthorityBootstrap
        )
    }

    nonisolated internal static func testOnlyShouldInitiateInitialWebRTCHandshake(
        role: WebRTCSession.Role
    ) -> Bool {
        shouldInitiateInitialWebRTCHandshake(role: role)
    }

    nonisolated internal static func testOnlyShouldUseClassicAuthorityBootstrapForInitialWebRTCHandshake(
        sessionId: String,
        authorityBoundBootstrapSessionIds: Set<String>,
        expectedRemoteAuthorityAlgorithm: ProtocolSigningAlgorithm?,
        localConnectionSessionId: String?
    ) -> Bool {
        shouldUseClassicAuthorityBootstrapForInitialWebRTCHandshake(
            sessionId: sessionId,
            authorityBoundBootstrapSessionIds: authorityBoundBootstrapSessionIds,
            expectedRemoteAuthorityAlgorithm: expectedRemoteAuthorityAlgorithm,
            localConnectionSessionId: localConnectionSessionId
        )
    }

    nonisolated internal static func testOnlyCurrentPathRequestTimeoutSeconds() -> TimeInterval {
        SignalServerClientCompat.testOnlyRequestTimeoutSeconds()
    }

    nonisolated internal static func testOnlyWebRTCStartupJoinHeartbeatAttempts() -> Int {
        webRTCStartupJoinHeartbeatAttempts
    }

    nonisolated private static func shouldInitiateInitialWebRTCHandshake(
        role: WebRTCSession.Role
    ) -> Bool {
        role == .offerer
    }

    nonisolated private static func shouldUseClassicAuthorityBootstrapForInitialWebRTCHandshake(
        sessionId: String,
        authorityBoundBootstrapSessionIds: Set<String>,
        expectedRemoteAuthorityAlgorithm: ProtocolSigningAlgorithm?,
        localConnectionSessionId: String?
    ) -> Bool {
        authorityBoundBootstrapSessionIds.contains(sessionId)
            || localConnectionSessionId == sessionId
            || expectedRemoteAuthorityAlgorithm == .ed25519
    }
}
