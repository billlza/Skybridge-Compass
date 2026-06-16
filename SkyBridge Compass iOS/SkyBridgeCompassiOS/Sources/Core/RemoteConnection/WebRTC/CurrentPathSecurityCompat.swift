import CryptoKit
import Foundation

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
