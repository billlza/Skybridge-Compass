import Foundation
import CryptoKit

public enum CurrentPathFailureClass: String, Codable, Sendable, CaseIterable {
    case peerReverificationRequired
    case identityConflict
    case deviceIdMigrationRequired
    case bootstrapVersionRejected
    case bootstrapOriginMismatch
    case bootstrapExpired
    case bootstrapTokenConsumed
    case sessionExpired
    case quarantinedIdentity
    case revokedIdentity
    case authTokenRejected
    case missingPinnedTrust
    case legacyTrustInsufficient
    case integrityProofRequired
    case finalDigestMismatch
    case merkleMismatch
}

public struct ProtocolIdentityBinding: Codable, Sendable, Equatable, Hashable {
    public static let maxDeviceIdLength = 128
    public static let minDeviceIdLength = 16
    private static let allowedDeviceIdScalars = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:-")

    public let deviceId: String
    public let protocolSigningAlgorithm: ProtocolSigningAlgorithm
    public let protocolPublicKeyBytes: Data
    public let protocolPublicKeyFingerprint: String

    public init(
        deviceId: String,
        protocolSigningAlgorithm: ProtocolSigningAlgorithm,
        protocolPublicKeyBytes: Data,
        protocolPublicKeyFingerprint: String? = nil
    ) throws {
        let normalizedDeviceId = try Self.normalizedDeviceId(deviceId)
        try Self.validateKeyEncoding(bytes: protocolPublicKeyBytes, algorithm: protocolSigningAlgorithm)
        let fingerprint = protocolPublicKeyFingerprint ?? Self.computeFingerprint(
            algorithm: protocolSigningAlgorithm,
            publicKeyBytes: protocolPublicKeyBytes
        )
        guard Self.isValidFingerprint(fingerprint) else {
            throw CurrentPathSecurityError.invalidProtocolIdentity("invalid authoritative fingerprint")
        }

        self.deviceId = normalizedDeviceId
        self.protocolSigningAlgorithm = protocolSigningAlgorithm
        self.protocolPublicKeyBytes = protocolPublicKeyBytes
        self.protocolPublicKeyFingerprint = fingerprint.lowercased()
    }

    public static func normalizedDeviceId(_ raw: String) throws -> String {
        let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate.count >= Self.minDeviceIdLength, candidate.count <= Self.maxDeviceIdLength else {
            throw CurrentPathSecurityError.invalidDeviceId
        }
        guard candidate.unicodeScalars.allSatisfy({ scalar in
            scalar.isASCII && Self.allowedDeviceIdScalars.contains(scalar)
        }) else {
            throw CurrentPathSecurityError.invalidDeviceId
        }
        return candidate
    }

    public static func isValidFingerprint(_ raw: String) -> Bool {
        raw.count == 64 && raw.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    public static func validateKeyEncoding(bytes: Data, algorithm: ProtocolSigningAlgorithm) throws {
        switch algorithm {
        case .ed25519:
            guard bytes.count == 32 else {
                throw CurrentPathSecurityError.invalidProtocolIdentity("ed25519 public key must be 32 bytes")
            }
        case .mlDSA65:
            guard !bytes.isEmpty else {
                throw CurrentPathSecurityError.invalidProtocolIdentity("mlDSA65 public key must not be empty")
            }
        }
    }

    public static func computeFingerprint(
        algorithm: ProtocolSigningAlgorithm,
        publicKeyBytes: Data
    ) -> String {
        var payload = Data()
        let tagBytes = Array(algorithm.rawValue.utf8)
        var tagLength = UInt16(tagBytes.count).littleEndian
        withUnsafeBytes(of: &tagLength) { payload.append(contentsOf: $0) }
        payload.append(contentsOf: tagBytes)
        var keyLength = UInt32(publicKeyBytes.count).littleEndian
        withUnsafeBytes(of: &keyLength) { payload.append(contentsOf: $0) }
        payload.append(publicKeyBytes)
        return SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }
}

public enum CurrentPathSecurityError: LocalizedError, Sendable {
    case invalidDeviceId
    case invalidOrigin
    case invalidProtocolIdentity(String)
    case invalidBootstrap(String)

    public var errorDescription: String? {
        switch self {
        case .invalidDeviceId:
            return "invalid current-path deviceId"
        case .invalidOrigin:
            return "invalid signaling origin"
        case .invalidProtocolIdentity(let reason):
            return "invalid authoritative identity: \(reason)"
        case .invalidBootstrap(let reason):
            return "invalid bootstrap payload: \(reason)"
        }
    }
}

public enum CurrentPathOriginPolicy {
    public static func canonicalOrigin(_ raw: String) throws -> String {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              (scheme == "https" || (scheme == "http" && isLoopbackHost(host)))
        else {
            throw CurrentPathSecurityError.invalidOrigin
        }
        guard url.path.isEmpty || url.path == "/" else {
            throw CurrentPathSecurityError.invalidOrigin
        }
        guard url.query == nil, url.fragment == nil else {
            throw CurrentPathSecurityError.invalidOrigin
        }

        let explicitPort = url.port
        let shouldIncludePort: Bool
        switch (scheme, explicitPort) {
        case ("https", nil), ("https", 443), ("http", nil), ("http", 80):
            shouldIncludePort = false
        default:
            shouldIncludePort = explicitPort != nil
        }

        if shouldIncludePort, let port = explicitPort {
            return "\(scheme)://\(serializedHost(host)):\(port)"
        }
        return "\(scheme)://\(serializedHost(host))"
    }

    public static func isLoopbackHost(_ rawHost: String) -> Bool {
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        guard !host.isEmpty else { return false }
        if host == "localhost" || host == "::1" || host == "0:0:0:0:0:0:0:1" {
            return true
        }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        let values = octets.compactMap { UInt8($0) }
        return values.count == 4 && values[0] == 127
    }

    private static func serializedHost(_ host: String) -> String {
        if host.contains(":"), !(host.hasPrefix("[") && host.hasSuffix("]")) {
            return "[\(host)]"
        }
        return host
    }
}
