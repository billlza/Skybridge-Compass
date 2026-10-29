import CryptoKit
import Foundation

@available(iOS 17.0, *)
extension ProtocolSigningAlgorithm {
    var signatureByteCount: Int {
        switch self {
        case .ed25519: return 64
        case .mlDSA65: return 3_309
        case .mlDSA87: return 4_627
        }
    }
}

@available(iOS 17.0, *)
struct ProtocolIdentityBindingCompat: Sendable, Equatable {
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
struct DeviceIdentityRotationTranscriptCompat: Sendable, Equatable {
    static let domain = "SkyBridge.DeviceIdentityRotation"
    static let version: UInt16 = 1
    private static let fieldCount: UInt16 = 13
    private static let nonceByteCount = 32

    let rotationID: String
    let nonce: Data
    let expiresAtMilliseconds: Int64
    let tenantID: String
    let userID: String
    let deviceID: String
    let oldGeneration: UInt64
    let oldIdentity: ProtocolIdentityBindingCompat
    let newIdentity: ProtocolIdentityBindingCompat

    init(
        rotationID: String,
        nonce: Data,
        expiresAtMilliseconds: Int64,
        tenantID: String,
        userID: String,
        deviceID: String,
        oldGeneration: UInt64,
        oldIdentity: ProtocolIdentityBindingCompat,
        newIdentity: ProtocolIdentityBindingCompat
    ) throws {
        guard let uuid = UUID(uuidString: rotationID),
              uuid.uuidString.lowercased() == rotationID else {
            throw Self.error("rotationId must be a canonical lowercase UUID")
        }
        guard nonce.count == Self.nonceByteCount else {
            throw Self.error("nonce must be exactly 32 bytes")
        }
        guard expiresAtMilliseconds > 0 else {
            throw Self.error("expiresAt must be a positive Unix millisecond timestamp")
        }
        let normalizedTenantID = try Self.validatedTextField(tenantID, name: "tenantId")
        let normalizedUserID = try Self.validatedTextField(userID, name: "userId")
        let normalizedDeviceID = try CurrentPathSecurityCompat.normalizeDeviceId(deviceID)
        guard oldIdentity.deviceId == normalizedDeviceID,
              newIdentity.deviceId == normalizedDeviceID else {
            throw Self.error("old and new identities must bind the same deviceId")
        }
        guard oldIdentity.protocolPublicKeyFingerprint
                == CurrentPathSecurityCompat.computeFingerprint(
                    algorithm: oldIdentity.protocolSigningAlgorithm,
                    publicKeyBytes: oldIdentity.protocolPublicKeyBytes
                ),
              newIdentity.protocolPublicKeyFingerprint
                == CurrentPathSecurityCompat.computeFingerprint(
                    algorithm: newIdentity.protocolSigningAlgorithm,
                    publicKeyBytes: newIdentity.protocolPublicKeyBytes
                ) else {
            throw Self.error(
                "identity fingerprint does not match its algorithm-tagged public key"
            )
        }
        guard oldIdentity.protocolSigningAlgorithm != newIdentity.protocolSigningAlgorithm
                || oldIdentity.protocolPublicKeyFingerprint
                    != newIdentity.protocolPublicKeyFingerprint
                || oldIdentity.protocolPublicKeyBytes != newIdentity.protocolPublicKeyBytes else {
            throw Self.error("new identity must differ from the active identity")
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

    var encoded: Data {
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

    var sha256Hex: String {
        SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
    }

    func validateServerCommitment(
        transcriptBase64: String,
        transcriptHash: String
    ) throws {
        guard Self.isCanonicalSHA256Hex(transcriptHash) else {
            throw Self.error("server transcript hash is not canonical SHA-256 hex")
        }
        guard let serverBytes = Data(base64Encoded: transcriptBase64),
              serverBytes.base64EncodedString() == transcriptBase64,
              serverBytes == encoded,
              transcriptHash == sha256Hex else {
            throw Self.error(
                "server transcript commitment does not match the requested identities"
            )
        }
    }

    static func decodeCanonicalBase64URLNonce(_ raw: String) throws -> Data {
        guard !raw.isEmpty,
              !raw.contains("="),
              raw.utf8.allSatisfy({ byte in
                  (48...57).contains(byte)
                      || (65...90).contains(byte)
                      || (97...122).contains(byte)
                      || byte == 45
                      || byte == 95
              }) else {
            throw error("nonce is not canonical unpadded Base64URL")
        }
        var standard = raw.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = standard.count % 4
        if remainder != 0 {
            standard.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let decoded = Data(base64Encoded: standard),
              decoded.count == nonceByteCount,
              canonicalBase64URL(decoded) == raw else {
            throw error("nonce must encode exactly 32 bytes")
        }
        return decoded
    }

    static func canonicalBase64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
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
        appendLengthPrefixed(Data(domain.utf8), to: &output)
        append(version, to: &output)
        append(fieldCount, to: &output)
        appendLengthPrefixed(Data(rotationID.utf8), to: &output)
        appendLengthPrefixed(nonce, to: &output)

        var expiryBytes = Data()
        append(UInt64(expiresAtMilliseconds), to: &expiryBytes)
        appendLengthPrefixed(expiryBytes, to: &output)
        appendLengthPrefixed(Data(tenantID.utf8), to: &output)
        appendLengthPrefixed(Data(userID.utf8), to: &output)
        appendLengthPrefixed(Data(deviceID.utf8), to: &output)

        var generationBytes = Data()
        append(oldGeneration, to: &generationBytes)
        appendLengthPrefixed(generationBytes, to: &output)
        appendLengthPrefixed(Data(oldAlgorithm.utf8), to: &output)
        appendLengthPrefixed(oldFingerprintBytes, to: &output)
        appendLengthPrefixed(oldPublicKey, to: &output)
        appendLengthPrefixed(Data(newAlgorithm.utf8), to: &output)
        appendLengthPrefixed(newFingerprintBytes, to: &output)
        appendLengthPrefixed(newPublicKey, to: &output)
        return output
    }

    private static func validatedTextField(_ raw: String, name: String) throws -> String {
        guard raw == raw.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              raw.utf8.count <= 512,
              !raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw error("\(name) is empty, non-canonical, or too large")
        }
        return raw
    }

    private static func isCanonicalSHA256Hex(_ raw: String) -> Bool {
        raw.utf8.count == 64 && raw.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static func fingerprintBytes(_ fingerprint: String) -> Data {
        precondition(isCanonicalSHA256Hex(fingerprint))
        let bytes = Array(fingerprint.utf8)
        var output = Data(capacity: 32)
        for offset in stride(from: 0, to: bytes.count, by: 2) {
            output.append((hexNibble(bytes[offset]) << 4) | hexNibble(bytes[offset + 1]))
        }
        return output
    }

    private static func hexNibble(_ byte: UInt8) -> UInt8 {
        if (48...57).contains(byte) { return byte - 48 }
        if (97...102).contains(byte) { return byte - 87 }
        preconditionFailure("fingerprint was validated before canonical encoding")
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

    private static func error(_ reason: String) -> NSError {
        NSError(
            domain: "CurrentPathSecurityCompat.IdentityRotation",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: reason]
        )
    }
}

@available(iOS 17.0, *)
enum CurrentPathSecurityCompat {
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
              (scheme == "https" || (scheme == "http" && isLoopbackHost(host)))
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
            return "\(scheme)://\(serializedHost(host))"
        default:
            guard let port else {
                return "\(scheme)://\(serializedHost(host))"
            }
            return "\(scheme)://\(serializedHost(host)):\(port)"
        }
    }

    static func isLoopbackHost(_ rawHost: String) -> Bool {
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

    static func validateKeyEncoding(bytes: Data, algorithm: ProtocolSigningAlgorithm) throws {
        switch algorithm {
        case .ed25519:
            guard bytes.count == 32 else {
                throw NSError(domain: "CurrentPathSecurityCompat", code: 6, userInfo: [NSLocalizedDescriptionKey: "ed25519 public key must be 32 bytes"])
            }
        case .mlDSA65:
            guard bytes.count == 1_952 else {
                throw NSError(domain: "CurrentPathSecurityCompat", code: 7, userInfo: [NSLocalizedDescriptionKey: "ML-DSA-65 public key must be 1952 bytes"])
            }
        case .mlDSA87:
            guard bytes.count == 2_592 else {
                throw NSError(domain: "CurrentPathSecurityCompat", code: 8, userInfo: [NSLocalizedDescriptionKey: "ML-DSA-87 public key must be 2592 bytes"])
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
extension CrossNetworkWebRTCManager {
    func validateCurrentPathOrigin(_ rawOrigin: String) throws -> String {
        let configured = try CurrentPathSecurityCompat.canonicalOrigin(CrossNetworkServerConfig.signalingServerURL)
        let claimed = try CurrentPathSecurityCompat.canonicalOrigin(rawOrigin)
        guard configured == claimed else {
            throw NSError(domain: "CrossNetworkWebRTCManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "signaling origin mismatch"])
        }
        return claimed
    }
}
