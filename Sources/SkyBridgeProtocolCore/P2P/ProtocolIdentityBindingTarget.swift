import Foundation

/// Admits only the responder's stable identity or an already-established stable alias.
/// This never rewrites the signed request. The original legal spelling is returned
/// only after identity matching, so the signed candidate can prove the exact target
/// that the requester used (including an uppercase UUID or an `id:` wrapper).
public enum ProtocolIdentityBindingTarget {
    public static func candidateAliases(
        targetDeviceId: String,
        localId: String,
        aliases: [String]
    ) -> [String]? {
        guard let localIdentity = PeerIdentityFusionPolicy.normalizedStableDeviceId(localId),
              let targetIdentity = PeerIdentityFusionPolicy.normalizedStableDeviceId(targetDeviceId) else {
            return nil
        }
        let stableAliases = ([localId] + aliases).compactMap { raw -> (String, String)? in
            guard let identity = PeerIdentityFusionPolicy.normalizedStableDeviceId(raw) else { return nil }
            return (raw.trimmingCharacters(in: .whitespacesAndNewlines), identity)
        }
        let admittedIdentities = Set(stableAliases.map { $0.1 }).union([localIdentity])
        guard admittedIdentities.contains(targetIdentity) else { return nil }
        let targetSpelling = targetDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        return Array(Set(stableAliases.map { $0.0 } + [targetSpelling])).sorted()
    }
}
