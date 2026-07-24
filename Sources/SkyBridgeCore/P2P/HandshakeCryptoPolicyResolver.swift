import Foundation
import SkyBridgeProtocolCore

/// Resolves the local handshake crypto policy from suites that have already been
/// selected for negotiation. This keeps provider selection and suite admission
/// aligned, so local P2P paths do not pick `AppleXWing` and then reject the
/// same `X-Wing` suite as "experimental hybrid" during negotiation.
public enum HandshakeCryptoPolicyResolver {
    public static func policy(for offeredSuites: [CryptoSuite]) -> CryptoPolicy {
        let pqcSuites = offeredSuites.filter { $0.isPQCGroup && $0.isNegotiable }
        let hasHybridSuites = pqcSuites.contains(where: \.isHybrid)

        guard hasHybridSuites else {
            return .default
        }

        let onlyOffersHybrid = !pqcSuites.isEmpty && pqcSuites.allSatisfy(\.isHybrid)
        return CryptoPolicy(
            minimumSecurityTier: onlyOffersHybrid ? .hybridPreferred : .pqcPreferred,
            allowExperimentalHybrid: true,
            advertiseHybrid: true,
            requireHybridIfAvailable: onlyOffersHybrid
        )
    }
}
