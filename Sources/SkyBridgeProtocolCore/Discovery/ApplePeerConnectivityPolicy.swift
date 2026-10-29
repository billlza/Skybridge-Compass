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

    /// Transport class for the post-handshake remote-control media socket.
    ///
    /// This is intentionally distinct from the primary P2P control handshake,
    /// which may use an exact authority-bound peer-to-peer interface. The
    /// high-bandwidth remote-control media contract remains infrastructure-only
    /// until a separately versioned peer-to-peer media policy is introduced.
    public enum RemoteControlInterfaceClass: String, Sendable, Equatable {
        case infrastructure
        case peerToPeer = "peer-to-peer"
        case unsupported
    }

    public enum RemoteControlResolvedAddressClass: String, Sendable, Equatable {
        case routable
        case linkLocalIPv4 = "link-local-ipv4"
        case linkLocalIPv6 = "link-local-ipv6"
        case unresolved
        case invalid
    }

    public enum RemoteControlRouteRejectionReason: String, Sendable, Equatable {
        case untrustedProvenance = "untrusted_provenance"
        case wrongServiceType = "wrong_service_type"
        case missingObservedInterface = "missing_observed_interface"
        case unsupportedInterface = "unsupported_interface"
        case peerToPeerMediaRouteDisallowed = "peer_to_peer_media_route_disallowed"
        case pathInterfaceTypeMismatch = "path_interface_type_mismatch"
        case unresolvedOrNonHostEndpoint = "unresolved_or_non_host_endpoint"
        case invalidResolvedAddress = "invalid_resolved_address"
        case resolvedScopeMismatch = "resolved_scope_mismatch"
    }

    /// Relationship between a media endpoint advertised inside the encrypted
    /// control session and the peer address already authenticated by that
    /// session. Direct-LAN media may use a wildcard host (the authenticated
    /// peer address is substituted) or the exact authenticated host; it may
    /// never redirect the sender to a third host.
    public enum RemoteControlMediaAdvertisedHostRelation: String, Sendable, Equatable {
        case unspecified
        case exactAuthenticatedHost = "exact_authenticated_host"
        case mismatch
    }

    public struct RemoteControlMediaInterfaceCandidate: Sendable, Equatable {
        public let name: String
        public let index: Int
        public let interfaceClass: RemoteControlInterfaceClass
        public let pathUsesInterfaceType: Bool

        public init(
            name: String,
            index: Int,
            interfaceClass: RemoteControlInterfaceClass,
            pathUsesInterfaceType: Bool
        ) {
            self.name = name
            self.index = index
            self.interfaceClass = interfaceClass
            self.pathUsesInterfaceType = pathUsesInterfaceType
        }
    }

    public struct RemoteControlMediaInterfaceBindingEvidence: Sendable, Equatable {
        public let advertisedHostRelation: RemoteControlMediaAdvertisedHostRelation
        public let authenticatedAddressClass: RemoteControlResolvedAddressClass
        public let authenticatedInterfaceScope: String?
        public let candidates: [RemoteControlMediaInterfaceCandidate]

        public init(
            advertisedHostRelation: RemoteControlMediaAdvertisedHostRelation,
            authenticatedAddressClass: RemoteControlResolvedAddressClass,
            authenticatedInterfaceScope: String?,
            candidates: [RemoteControlMediaInterfaceCandidate]
        ) {
            self.advertisedHostRelation = advertisedHostRelation
            self.authenticatedAddressClass = authenticatedAddressClass
            self.authenticatedInterfaceScope = authenticatedInterfaceScope
            self.candidates = candidates
        }
    }

    public enum RemoteControlMediaInterfaceBindingRejectionReason: String, Error, Sendable, Equatable {
        case advertisedHostMismatch = "advertised_host_mismatch"
        case invalidAuthenticatedAddress = "invalid_authenticated_address"
        case missingInterfaceScope = "missing_interface_scope"
        case interfaceNotAvailable = "interface_not_available"
        case ambiguousInterface = "ambiguous_interface"
        case unsupportedInterface = "unsupported_interface"
        case peerToPeerForbidden = "peer_to_peer_forbidden"
        case scopeMismatch = "scope_mismatch"
    }

    public enum RemoteControlMediaInterfaceBindingDecision: Sendable, Equatable {
        case use(interfaceName: String, interfaceIndex: Int)
        case reject(RemoteControlMediaInterfaceBindingRejectionReason)
    }

    public struct RemoteControlRouteEvidence: Sendable, Equatable {
        public let provenance: RouteProvenance
        public let requestedServiceType: String?
        public let requestedInterfaceName: String?
        public let requestedInterfaceClass: RemoteControlInterfaceClass
        public let pathUsesRequestedInterfaceType: Bool
        public let resolvedAddressClass: RemoteControlResolvedAddressClass
        public let resolvedInterfaceScope: String?

        public init(
            provenance: RouteProvenance,
            requestedServiceType: String?,
            requestedInterfaceName: String?,
            requestedInterfaceClass: RemoteControlInterfaceClass,
            pathUsesRequestedInterfaceType: Bool,
            resolvedAddressClass: RemoteControlResolvedAddressClass,
            resolvedInterfaceScope: String?
        ) {
            self.provenance = provenance
            self.requestedServiceType = requestedServiceType
            self.requestedInterfaceName = requestedInterfaceName
            self.requestedInterfaceClass = requestedInterfaceClass
            self.pathUsesRequestedInterfaceType = pathUsesRequestedInterfaceType
            self.resolvedAddressClass = resolvedAddressClass
            self.resolvedInterfaceScope = resolvedInterfaceScope
        }
    }

    /// Product policy for the dedicated `_skybridge-rd._tcp` media socket.
    /// This does not alter the primary P2P control listener or handshake.
    public static let remoteControlMediaAllowsPeerToPeer = false

    public static func remoteControlMediaIncludesPeerToPeer(
        for interfaceClass: RemoteControlInterfaceClass
    ) -> Bool {
        remoteControlMediaAllowsPeerToPeer && interfaceClass == .peerToPeer
    }

    public static func remoteControlInterfaceClass(
        interfaceName: String,
        isWiFi: Bool,
        isWiredEthernet: Bool
    ) -> RemoteControlInterfaceClass {
        guard let normalizedName = normalizedRemoteControlInterfaceName(interfaceName) else {
            return .unsupported
        }
        if normalizedName.hasPrefix("awdl") || normalizedName.hasPrefix("p2p") {
            return .peerToPeer
        }
        if isWiFi || isWiredEthernet || normalizedName.hasPrefix("en") {
            return .infrastructure
        }
        return .unsupported
    }

    /// Selects the one local interface that is owned by the already
    /// authenticated remote-control path. The adapter supplies Network.framework
    /// observations as values; the admission decision remains identical on
    /// macOS and iOS.
    public static func remoteControlMediaInterfaceBindingDecision(
        for evidence: RemoteControlMediaInterfaceBindingEvidence
    ) -> RemoteControlMediaInterfaceBindingDecision {
        guard evidence.advertisedHostRelation != .mismatch else {
            return .reject(.advertisedHostMismatch)
        }
        switch evidence.authenticatedAddressClass {
        case .routable, .linkLocalIPv4, .linkLocalIPv6:
            break
        case .unresolved, .invalid:
            return .reject(.invalidAuthenticatedAddress)
        }

        let usedCandidates = evidence.candidates.filter(\.pathUsesInterfaceType)
        let eligible: [RemoteControlMediaInterfaceCandidate]
        if evidence.authenticatedAddressClass == .linkLocalIPv6 {
            guard let scope = normalizedRemoteControlInterfaceName(
                evidence.authenticatedInterfaceScope
            ) else {
                return .reject(.missingInterfaceScope)
            }
            let scopedCandidates = usedCandidates.filter {
                normalizedRemoteControlInterfaceName($0.name) == scope
            }
            guard !scopedCandidates.isEmpty else {
                return .reject(.scopeMismatch)
            }
            eligible = scopedCandidates
        } else {
            eligible = usedCandidates
        }

        if eligible.contains(where: { $0.interfaceClass == .peerToPeer }) {
            return .reject(.peerToPeerForbidden)
        }
        let infrastructureCandidates = eligible.filter {
            $0.interfaceClass == .infrastructure
        }
        if infrastructureCandidates.isEmpty {
            return .reject(
                eligible.isEmpty ? .interfaceNotAvailable : .unsupportedInterface
            )
        }
        guard infrastructureCandidates.count == 1 else {
            return .reject(.ambiguousInterface)
        }
        let selected = infrastructureCandidates[0]
        guard let normalizedName = normalizedRemoteControlInterfaceName(selected.name) else {
            return .reject(.unsupportedInterface)
        }
        return .use(
            interfaceName: normalizedName,
            interfaceIndex: selected.index
        )
    }

    public static func remoteControlRouteRejectionReason(
        for evidence: RemoteControlRouteEvidence
    ) -> RemoteControlRouteRejectionReason? {
        guard evidence.provenance == .liveBrowser else {
            return .untrustedProvenance
        }
        guard evidence.requestedServiceType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == BonjourInteropProtocolContract.remoteControlServiceType else {
            return .wrongServiceType
        }
        guard let requestedInterfaceName = normalizedRemoteControlInterfaceName(
            evidence.requestedInterfaceName
        ) else {
            return .missingObservedInterface
        }
        switch evidence.requestedInterfaceClass {
        case .infrastructure:
            break
        case .peerToPeer:
            guard remoteControlMediaAllowsPeerToPeer else {
                return .peerToPeerMediaRouteDisallowed
            }
        case .unsupported:
            return .unsupportedInterface
        }
        guard evidence.pathUsesRequestedInterfaceType else {
            return .pathInterfaceTypeMismatch
        }
        switch evidence.resolvedAddressClass {
        case .routable, .linkLocalIPv4:
            break
        case .linkLocalIPv6:
            guard normalizedRemoteControlInterfaceName(evidence.resolvedInterfaceScope)
                    == requestedInterfaceName else {
                return .resolvedScopeMismatch
            }
        case .unresolved:
            return .unresolvedOrNonHostEndpoint
        case .invalid:
            return .invalidResolvedAddress
        }
        return nil
    }

    public static func remoteControlInterfaceScopeMatches(
        _ evidence: RemoteControlRouteEvidence
    ) -> Bool {
        guard evidence.resolvedAddressClass == .linkLocalIPv6 else { return true }
        guard let requested = normalizedRemoteControlInterfaceName(
            evidence.requestedInterfaceName
        ) else {
            return false
        }
        return normalizedRemoteControlInterfaceName(evidence.resolvedInterfaceScope)
            == requested
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

    private static func normalizedRemoteControlInterfaceName(_ raw: String?) -> String? {
        guard let normalized = raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !normalized.isEmpty else {
            return nil
        }
        return normalized
    }
}
