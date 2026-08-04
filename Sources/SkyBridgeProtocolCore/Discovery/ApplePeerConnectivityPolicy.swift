import Foundation

/// Platform-neutral decisions for Apple peer discovery and dialing.
///
/// Network.framework objects stay in the platform adapters. This policy owns
/// every decision that must remain identical on macOS and iOS: service roles,
/// normalized DNS-SD route identity, authority matching, route provenance, and
/// stable connection failure classification.
public enum ApplePeerConnectivityPolicy {
    public enum ServiceKind: String, Sendable, Equatable {
        case control
        case fileTransfer
        case remoteControl
        case unsupported

        public init(serviceType rawServiceType: String) {
            switch rawServiceType
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() {
            case BonjourInteropProtocolContract.controlServiceType:
                self = .control
            case BonjourInteropProtocolContract.fileTransferServiceType,
                 BonjourInteropProtocolContract.legacyFileTransferServiceType:
                self = .fileTransfer
            case BonjourInteropProtocolContract.remoteControlServiceType,
                 BonjourInteropProtocolContract.legacyRemoteControlServiceType:
                self = .remoteControl
            default:
                self = .unsupported
            }
        }

        public var canonicalServiceType: String? {
            switch self {
            case .control:
                return BonjourInteropProtocolContract.controlServiceType
            case .fileTransfer:
                return BonjourInteropProtocolContract.fileTransferServiceType
            case .remoteControl:
                return BonjourInteropProtocolContract.remoteControlServiceType
            case .unsupported:
                return nil
            }
        }
    }

    public struct BonjourRouteIdentity: Hashable, Sendable {
        public let name: String
        public let type: String
        public let domain: String

        public init?(name rawName: String?, type rawType: String?, domain rawDomain: String?) {
            guard let rawName,
                  let rawType,
                  let rawDomain else {
                return nil
            }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            let type = rawType
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            var domain = rawDomain
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()

            guard !name.isEmpty,
                  name.utf8.count <= 63,
                  !name.contains("/"),
                  BonjourInteropProtocolContract.isValidDNSServiceType(type),
                  !domain.isEmpty else {
                return nil
            }
            if !domain.hasSuffix(".") {
                domain.append(".")
            }

            self.name = name
            self.type = type
            self.domain = domain
        }

        public var serviceKind: ServiceKind {
            ServiceKind(serviceType: type)
        }

        public var stableKey: String {
            [name, type, domain]
                .map { "\($0.utf8.count):\($0)" }
                .joined(separator: "|")
        }
    }

    public struct AuthorityClaim: Sendable, Equatable {
        public let deviceId: String?
        public let protocolPublicKeyFingerprint: String?
        public let platform: BonjourInteropProtocolContract.AdvertisementPlatform?

        public init(
            deviceId rawDeviceId: String?,
            protocolPublicKeyFingerprint rawFingerprint: String?,
            platform: BonjourInteropProtocolContract.AdvertisementPlatform?
        ) {
            deviceId = ApplePeerConnectivityPolicy.normalizedAuthorityDeviceId(
                rawDeviceId
            )
            protocolPublicKeyFingerprint =
                BonjourInteropProtocolContract.normalizedPubKeyFingerprint(rawFingerprint)
            self.platform = platform
        }

        public var hasStrongIdentity: Bool {
            deviceId != nil || protocolPublicKeyFingerprint != nil
        }
    }

    public struct DialTarget: Sendable, Equatable {
        public let deviceIds: Set<String>
        public let protocolPublicKeyFingerprints: Set<String>
        public let routes: Set<BonjourRouteIdentity>

        public init(
            deviceIds rawDeviceIds: [String],
            protocolPublicKeyFingerprints rawFingerprints: [String],
            routes: [BonjourRouteIdentity]
        ) {
            deviceIds = Set(
                rawDeviceIds.compactMap(
                    ApplePeerConnectivityPolicy.normalizedAuthorityDeviceId
                )
            )
            protocolPublicKeyFingerprints = Set(
                rawFingerprints.compactMap(
                    BonjourInteropProtocolContract.normalizedPubKeyFingerprint
                )
            )
            self.routes = Set(routes)
        }

        public var hasStrongIdentity: Bool {
            !deviceIds.isEmpty || !protocolPublicKeyFingerprints.isEmpty
        }
    }

    private static func normalizedAuthorityDeviceId(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        if value.lowercased().hasPrefix("id:") {
            value.removeFirst("id:".count)
        }
        guard let validated =
                BonjourInteropProtocolContract.normalizedDeviceId(value) else {
            return nil
        }
        return validated.lowercased()
    }

    public enum RouteProvenance: String, Sendable, Equatable {
        /// Exact endpoint from the current NWBrowser result generation.
        case liveBrowser
        /// Host route carried by an authenticated application-layer binding.
        case authenticatedHost
        /// Host route freshly resolved from the exact live DNS-SD service.
        case freshServiceResolution
        /// Persisted/display/TXT metadata without current route ownership.
        case persistedMetadata

        public var isDialEligible: Bool {
            self != .persistedMetadata
        }
    }

    public struct RouteClaim: Sendable, Equatable {
        public let route: BonjourRouteIdentity
        public let authority: AuthorityClaim
        public let provenance: RouteProvenance

        public init(
            route: BonjourRouteIdentity,
            authority: AuthorityClaim,
            provenance: RouteProvenance
        ) {
            self.route = route
            self.authority = authority
            self.provenance = provenance
        }
    }

    public enum MatchStrength: Int, Sendable, Equatable, Comparable {
        case none = 0
        case exactRoute = 1
        case strongAuthority = 2

        public static func < (lhs: MatchStrength, rhs: MatchStrength) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public enum RouteMatch: Sendable, Equatable {
        case eligible(MatchStrength)
        case rejectedAuthorityConflict
        case rejectedServiceKind
        case rejectedUnprovenRoute
        case noMatch
    }

    public static func match(
        target: DialTarget,
        claim: RouteClaim,
        requiredServiceKind: ServiceKind
    ) -> RouteMatch {
        guard claim.route.serviceKind == requiredServiceKind else {
            return .rejectedServiceKind
        }
        guard claim.provenance.isDialEligible else {
            return .rejectedUnprovenRoute
        }

        let claimDeviceIds = Set([claim.authority.deviceId].compactMap { $0 })
        let claimFingerprints = Set(
            [claim.authority.protocolPublicKeyFingerprint].compactMap { $0 }
        )
        let deviceIdMatches =
            !target.deviceIds.isEmpty
                && !claimDeviceIds.isEmpty
                && !target.deviceIds.isDisjoint(with: claimDeviceIds)
        let fingerprintMatches =
            !target.protocolPublicKeyFingerprints.isEmpty
                && !claimFingerprints.isEmpty
                && !target.protocolPublicKeyFingerprints.isDisjoint(
                    with: claimFingerprints
                )
        let deviceIdConflicts =
            !target.deviceIds.isEmpty
                && !claimDeviceIds.isEmpty
                && target.deviceIds.isDisjoint(with: claimDeviceIds)
        let fingerprintConflicts =
            !target.protocolPublicKeyFingerprints.isEmpty
                && !claimFingerprints.isEmpty
                && target.protocolPublicKeyFingerprints.isDisjoint(
                    with: claimFingerprints
                )
        if deviceIdConflicts || fingerprintConflicts {
            return .rejectedAuthorityConflict
        }

        if deviceIdMatches || fingerprintMatches {
            return .eligible(.strongAuthority)
        }

        if target.routes.contains(claim.route) {
            return .eligible(.exactRoute)
        }
        return .noMatch
    }

    public static func orderedEligibleClaimIndices(
        target: DialTarget,
        claims: [RouteClaim],
        requiredServiceKind: ServiceKind
    ) -> [Int] {
        claims.indices.compactMap { index -> (Int, MatchStrength, String)? in
            guard case .eligible(let strength) = match(
                target: target,
                claim: claims[index],
                requiredServiceKind: requiredServiceKind
            ) else {
                return nil
            }
            return (index, strength, claims[index].route.stableKey)
        }
        .sorted { lhs, rhs in
            if lhs.1 != rhs.1 {
                return lhs.1 > rhs.1
            }
            return lhs.2 < rhs.2
        }
        .map(\.0)
    }

    public static func requiresLiveBonjourRoute(
        platform: BonjourInteropProtocolContract.AdvertisementPlatform?
    ) -> Bool {
        switch platform {
        case .macOS, .iOS, .iPadOS:
            return true
        case .android, .windows, .linux, .none:
            return false
        }
    }

    public enum PathUnsatisfiedReason: String, Sendable, Equatable {
        case notAvailable
        case cellularDenied
        case wifiDenied
        case localNetworkDenied
        case vpnInactive
        case unknown
    }

    public enum ConnectionEvent: String, Sendable, Equatable {
        case waiting
        case failed
        case timedOut
    }

    public enum ConnectionFailureCode: String, Sendable, Equatable {
        case localNetworkPermissionDenied = "local_network_permission_denied"
        case transportWaiting = "transport_waiting"
        case transportFailed = "transport_failed"
        case transportTimedOut = "transport_timed_out"
        case noLiveControlRoute = "no_live_control_route"
        case noLiveFileTransferRoute = "no_live_file_transfer_route"
        case noAuthenticatedPeer = "no_authenticated_peer"
        case ambiguousTarget = "ambiguous_target"
    }

    public static func connectionFailureCode(
        event: ConnectionEvent,
        pathReason: PathUnsatisfiedReason?,
        errorDescriptions: [String]
    ) -> ConnectionFailureCode {
        if isLocalNetworkPermissionDenied(
            pathReason: pathReason,
            errorDescriptions: errorDescriptions
        ) {
            return .localNetworkPermissionDenied
        }
        switch event {
        case .waiting:
            return .transportWaiting
        case .failed:
            return .transportFailed
        case .timedOut:
            return .transportTimedOut
        }
    }

    public static func isLocalNetworkPermissionDenied(
        pathReason: PathUnsatisfiedReason?,
        errorDescriptions: [String]
    ) -> Bool {
        if pathReason == .localNetworkDenied {
            return true
        }
        let details = errorDescriptions
            .joined(separator: " ")
            .lowercased()
        return details.contains("local network prohibited")
            || details.contains("local network denied")
            || details.contains("localnetworkdenied")
    }
}
