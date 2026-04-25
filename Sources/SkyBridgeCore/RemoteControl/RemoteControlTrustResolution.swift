import Foundation
import CryptoKit

@available(macOS 14.0, iOS 17.0, *)
enum RemoteControlInboundTrustResolution: Equatable {
    case missing
    case ambiguous(deviceIds: [String], fingerprints: [String])
    case resolved(deviceId: String, fingerprint: String?)
}

@available(macOS 14.0, iOS 17.0, *)
enum RemoteControlInboundTrustResolver {
    static func soaPeerId(for identifier: String?) -> Data? {
        guard let seed = soaSeed(for: identifier) else {
            return nil
        }

        var normalized = seed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("id:") {
            normalized.removeFirst(3)
        }
        guard !normalized.isEmpty else {
            return nil
        }
        return Data(SHA256.hash(data: Data(normalized.utf8)))
    }

    static func resolve(remoteSOAPeerId: Data?, records: [TrustRecord]) -> RemoteControlInboundTrustResolution {
        guard let remoteSOAPeerId else {
            return .missing
        }

        let matches = records.filter { record in
            guard !record.isTombstone, !record.isExpired else {
                return false
            }
            return PeerTrustLookup.recordLookupCandidates(record).contains { candidate in
                soaPeerId(for: candidate) == remoteSOAPeerId
            }
        }

        return collapse(matches)
    }

    private static func collapse(_ matches: [TrustRecord]) -> RemoteControlInboundTrustResolution {
        guard !matches.isEmpty else {
            return .missing
        }

        let deviceIds = Array(
            Set(
                matches
                    .map(\.currentDeviceId)
                    .map(canonicalTrustedDeviceId)
                    .filter { !$0.isEmpty }
            )
        ).sorted()

        let fingerprints = Array(
            Set(
                matches
                    .compactMap(\.currentPathAuthorityFingerprint)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                    .filter { !$0.isEmpty }
            )
        ).sorted()

        if deviceIds.count == 1 && !hasProtocolAlgorithmFingerprintConflict(in: matches) {
            return .resolved(
                deviceId: deviceIds[0],
                fingerprint: fingerprints.count == 1 ? fingerprints.first : nil
            )
        }

        return .ambiguous(deviceIds: deviceIds, fingerprints: fingerprints)
    }

    private static func hasProtocolAlgorithmFingerprintConflict(in matches: [TrustRecord]) -> Bool {
        var fingerprintsByAlgorithm: [String: Set<String>] = [:]

        for record in matches {
            guard let fingerprint = canonicalFingerprint(record.currentPathAuthorityFingerprint) else {
                continue
            }
            let algorithm = record.protocolSigningAlgorithm?.rawValue ?? "unknown"
            fingerprintsByAlgorithm[algorithm, default: []].insert(fingerprint)
        }

        return fingerprintsByAlgorithm.values.contains { $0.count > 1 }
    }

    private static func canonicalFingerprint(_ raw: String?) -> String? {
        guard let normalized = raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !normalized.isEmpty else {
            return nil
        }
        return normalized
    }

    private static func canonicalTrustedDeviceId(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }
        if let persistent = PeerTrustLookup.persistentDeviceId(from: trimmed) {
            return persistent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        return trimmed.lowercased()
    }

    private static func soaSeed(for identifier: String?) -> String? {
        guard let identifier = identifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !identifier.isEmpty else {
            return nil
        }
        if let persistent = PeerTrustLookup.persistentDeviceId(from: identifier) {
            return persistent
        }
        if identifier.lowercased().hasPrefix("id:") {
            return identifier
        }
        return nil
    }
}
