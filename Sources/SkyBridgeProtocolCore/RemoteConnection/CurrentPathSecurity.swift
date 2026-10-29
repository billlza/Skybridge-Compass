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
            guard bytes.count == 1_952 else {
                throw CurrentPathSecurityError.invalidProtocolIdentity("ML-DSA-65 public key must be 1952 bytes")
            }
        case .mlDSA87:
            guard bytes.count == 2_592 else {
                throw CurrentPathSecurityError.invalidProtocolIdentity("ML-DSA-87 public key must be 2592 bytes")
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
    case invalidIdentityRotation(String)

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
        case .invalidIdentityRotation(let reason):
            return "invalid protocol identity rotation: \(reason)"
        }
    }
}

/// Canonical dual-proof transcript for changing the current-path device
/// authority. Both the old and the candidate key sign these exact bytes.
/// The server commits the new identity only after both proofs verify in one
/// database transaction.
public struct DeviceIdentityRotationTranscript: Sendable, Equatable {
    public static let domain = "SkyBridge.DeviceIdentityRotation"
    public static let version: UInt16 = 1
    private static let fieldCount: UInt16 = 13
    private static let nonceByteCount = 32
    private static let maximumTextFieldBytes = 512

    public let rotationID: String
    public let nonce: Data
    public let expiresAtMilliseconds: Int64
    public let tenantID: String
    public let userID: String
    public let deviceID: String
    public let oldGeneration: UInt64
    public let oldIdentity: ProtocolIdentityBinding
    public let newIdentity: ProtocolIdentityBinding

    public init(
        rotationID: String,
        nonce: Data,
        expiresAtMilliseconds: Int64,
        tenantID: String,
        userID: String,
        deviceID: String,
        oldGeneration: UInt64,
        oldIdentity: ProtocolIdentityBinding,
        newIdentity: ProtocolIdentityBinding
    ) throws {
        guard let uuid = UUID(uuidString: rotationID),
              uuid.uuidString.lowercased() == rotationID else {
            throw CurrentPathSecurityError.invalidIdentityRotation(
                "rotationId must be a canonical lowercase UUID"
            )
        }
        guard nonce.count == Self.nonceByteCount else {
            throw CurrentPathSecurityError.invalidIdentityRotation(
                "nonce must be exactly \(Self.nonceByteCount) bytes"
            )
        }
        guard expiresAtMilliseconds > 0 else {
            throw CurrentPathSecurityError.invalidIdentityRotation(
                "expiresAt must be a positive Unix millisecond timestamp"
            )
        }
        let normalizedTenantID = try Self.validatedTextField(tenantID, name: "tenantId")
        let normalizedUserID = try Self.validatedTextField(userID, name: "userId")
        let normalizedDeviceID = try ProtocolIdentityBinding.normalizedDeviceId(deviceID)
        guard oldIdentity.deviceId == normalizedDeviceID,
              newIdentity.deviceId == normalizedDeviceID else {
            throw CurrentPathSecurityError.invalidIdentityRotation(
                "old and new identities must bind the same deviceId"
            )
        }
        guard oldIdentity.protocolPublicKeyFingerprint == ProtocolIdentityBinding.computeFingerprint(
                algorithm: oldIdentity.protocolSigningAlgorithm,
                publicKeyBytes: oldIdentity.protocolPublicKeyBytes
              ),
              newIdentity.protocolPublicKeyFingerprint == ProtocolIdentityBinding.computeFingerprint(
                algorithm: newIdentity.protocolSigningAlgorithm,
                publicKeyBytes: newIdentity.protocolPublicKeyBytes
              ) else {
            throw CurrentPathSecurityError.invalidIdentityRotation(
                "identity fingerprint does not match its algorithm-tagged public key"
            )
        }
        guard oldIdentity.protocolSigningAlgorithm != newIdentity.protocolSigningAlgorithm
                || oldIdentity.protocolPublicKeyFingerprint
                    != newIdentity.protocolPublicKeyFingerprint
                || oldIdentity.protocolPublicKeyBytes != newIdentity.protocolPublicKeyBytes else {
            throw CurrentPathSecurityError.invalidIdentityRotation(
                "new identity must differ from the active identity"
            )
        }

        self.rotationID = rotationID
        self.nonce = nonce
        self.expiresAtMilliseconds = expiresAtMilliseconds
        self.tenantID = normalizedTenantID
        self.userID = normalizedUserID
        self.deviceID = normalizedDeviceID
        self.oldGeneration = oldGeneration
        self.oldIdentity = oldIdentity
        self.newIdentity = newIdentity
    }

    public var encoded: Data {
        Self.canonicalEncoded(
            rotationID: rotationID,
            nonce: nonce,
            expiresAtMilliseconds: expiresAtMilliseconds,
            tenantID: tenantID,
            userID: userID,
            deviceID: deviceID,
            oldGeneration: oldGeneration,
            oldAlgorithm: oldIdentity.protocolSigningAlgorithm.rawValue,
            oldFingerprintBytes: Self.fingerprintBytes(
                oldIdentity.protocolPublicKeyFingerprint
            ),
            oldPublicKey: oldIdentity.protocolPublicKeyBytes,
            newAlgorithm: newIdentity.protocolSigningAlgorithm.rawValue,
            newFingerprintBytes: Self.fingerprintBytes(
                newIdentity.protocolPublicKeyFingerprint
            ),
            newPublicKey: newIdentity.protocolPublicKeyBytes
        )
    }

    static func canonicalEncoded(
        rotationID: String,
        nonce: Data,
        expiresAtMilliseconds: Int64,
        tenantID: String,
        userID: String,
        deviceID: String,
        oldGeneration: UInt64,
        oldAlgorithm: String,
        oldFingerprintBytes: Data,
        oldPublicKey: Data,
        newAlgorithm: String,
        newFingerprintBytes: Data,
        newPublicKey: Data
    ) -> Data {
        var output = Data()
        Self.appendLengthPrefixed(Data(Self.domain.utf8), to: &output)
        Self.append(Self.version, to: &output)
        Self.append(Self.fieldCount, to: &output)
        Self.appendLengthPrefixed(Data(rotationID.utf8), to: &output)
        Self.appendLengthPrefixed(nonce, to: &output)

        var expiryBytes = Data()
        Self.append(UInt64(expiresAtMilliseconds), to: &expiryBytes)
        Self.appendLengthPrefixed(expiryBytes, to: &output)

        Self.appendLengthPrefixed(Data(tenantID.utf8), to: &output)
        Self.appendLengthPrefixed(Data(userID.utf8), to: &output)
        Self.appendLengthPrefixed(Data(deviceID.utf8), to: &output)

        var generationBytes = Data()
        Self.append(oldGeneration, to: &generationBytes)
        Self.appendLengthPrefixed(generationBytes, to: &output)

        Self.appendLengthPrefixed(Data(oldAlgorithm.utf8), to: &output)
        Self.appendLengthPrefixed(oldFingerprintBytes, to: &output)
        Self.appendLengthPrefixed(oldPublicKey, to: &output)
        Self.appendLengthPrefixed(Data(newAlgorithm.utf8), to: &output)
        Self.appendLengthPrefixed(newFingerprintBytes, to: &output)
        Self.appendLengthPrefixed(newPublicKey, to: &output)
        return output
    }

    public var sha256Hex: String {
        SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
    }

    public func validateServerCommitment(
        transcriptBase64: String,
        transcriptHash: String
    ) throws {
        guard ProtocolIdentityBinding.isValidFingerprint(transcriptHash) else {
            throw CurrentPathSecurityError.invalidIdentityRotation(
                "server transcript hash is not canonical SHA-256 hex"
            )
        }
        guard let serverBytes = Data(base64Encoded: transcriptBase64),
              serverBytes.base64EncodedString() == transcriptBase64 else {
            throw CurrentPathSecurityError.invalidIdentityRotation(
                "server transcript is not canonical Base64"
            )
        }
        guard serverBytes == encoded, transcriptHash == sha256Hex else {
            throw CurrentPathSecurityError.invalidIdentityRotation(
                "server transcript commitment does not match the requested identities"
            )
        }
    }

    public static func decodeCanonicalBase64URLNonce(_ raw: String) throws -> Data {
        guard !raw.isEmpty,
              !raw.contains("="),
              raw.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
              }) else {
            throw CurrentPathSecurityError.invalidIdentityRotation(
                "nonce is not canonical unpadded Base64URL"
            )
        }
        var standard = raw.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = standard.count % 4
        if remainder != 0 {
            standard.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let decoded = Data(base64Encoded: standard),
              decoded.count == Self.nonceByteCount,
              Self.canonicalBase64URL(decoded) == raw else {
            throw CurrentPathSecurityError.invalidIdentityRotation(
                "nonce must encode exactly \(Self.nonceByteCount) bytes"
            )
        }
        return decoded
    }

    public static func canonicalBase64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func validatedTextField(_ raw: String, name: String) throws -> String {
        guard raw == raw.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              raw.utf8.count <= maximumTextFieldBytes,
              !raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw CurrentPathSecurityError.invalidIdentityRotation(
                "\(name) is empty, non-canonical, or too large"
            )
        }
        return raw
    }

    private static func fingerprintBytes(_ fingerprint: String) -> Data {
        let bytes = Array(fingerprint.utf8)
        precondition(bytes.count == 64)
        var output = Data(capacity: 32)
        for offset in stride(from: 0, to: bytes.count, by: 2) {
            output.append((hexNibble(bytes[offset]) << 4) | hexNibble(bytes[offset + 1]))
        }
        return output
    }

    private static func hexNibble(_ byte: UInt8) -> UInt8 {
        switch byte {
        case 48...57:
            return byte - 48
        case 97...102:
            return byte - 87
        default:
            preconditionFailure("fingerprint was validated before canonical encoding")
        }
    }

    private static func appendLengthPrefixed(_ field: Data, to output: inout Data) {
        precondition(field.count <= Int(UInt32.max))
        append(UInt32(field.count), to: &output)
        output.append(field)
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to output: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { output.append(contentsOf: $0) }
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
