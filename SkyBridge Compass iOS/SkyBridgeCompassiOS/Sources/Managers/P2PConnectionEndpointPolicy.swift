import Foundation
import Network
import SkyBridgeProtocolCore

/// The persistable identity portion of one DNS-SD route. A service endpoint is actionable
/// only when this tuple and the Network.framework interface came from the same live result.
///
/// Keeping this as a value prevents the discovery cache, active-connection enrichment, and
/// trusted-device persistence from independently filling fields and manufacturing an endpoint
/// that no peer actually published. The interface itself remains in the process-local discovery
/// snapshot because `NWInterface` has no supported persistence/reconstruction contract.
struct BonjourRouteTuple: Equatable, Sendable {
    private let identity: ApplePeerConnectivityPolicy.BonjourRouteIdentity

    var name: String { identity.name }
    var type: String { identity.type }
    var domain: String { identity.domain }
    var sharedIdentity: ApplePeerConnectivityPolicy.BonjourRouteIdentity {
        identity
    }

    init?(name: String?, type: String?, domain: String?) {
        guard let identity = ApplePeerConnectivityPolicy.BonjourRouteIdentity(
            name: BonjourServiceIdentitySanitizer.sanitizedServiceInstanceName(name),
            type: type,
            domain: domain
        ) else {
            return nil
        }
        self.identity = identity
    }

    init?(_ device: DiscoveredDevice) {
        self.init(
            name: device.bonjourServiceName,
            type: device.bonjourServiceType,
            domain: device.bonjourServiceDomain
        )
    }

    var isPrimaryControlRoute: Bool {
        identity.serviceKind == .control
    }

    /// Selects one complete route without combining fields.
    ///
    /// A newly observed primary control advertisement is authoritative, including when it
    /// replaces an older primary route after a rename. Auxiliary advertisements may seed an
    /// empty route but never displace a selected primary route.
    static func preferred(
        existing: BonjourRouteTuple?,
        update: BonjourRouteTuple?
    ) -> BonjourRouteTuple? {
        guard let update else { return existing }
        guard let existing else { return update }
        if update.isPrimaryControlRoute {
            return update
        }
        return existing
    }

    func apply(to device: inout DiscoveredDevice) {
        device.bonjourServiceName = name
        device.bonjourServiceType = type
        device.bonjourServiceDomain = domain
    }

    static func clear(from device: inout DiscoveredDevice) {
        device.bonjourServiceName = nil
        device.bonjourServiceType = nil
        device.bonjourServiceDomain = nil
    }
}

enum P2PConnectionEndpointPolicy {
    static func parseBonjourPeerIdentifier(_ peerId: String) -> (name: String, domain: String)? {
        guard peerId.hasPrefix("bonjour:") else { return nil }
        let payload = String(peerId.dropFirst("bonjour:".count))
        let parts = payload.split(separator: "@", maxSplits: 1).map(String.init)
        guard let name = BonjourServiceIdentitySanitizer.sanitizedServiceInstanceName(parts.first) else { return nil }
        let domain = parts.count > 1 ? parts[1] : "local."
        return (name, domain)
    }

    static func shouldPreferBonjourSkyBridgeEndpoint(
        for device: DiscoveredDevice,
        bonjourName: String
    ) -> Bool {
        let normalizedBonjourName = bonjourName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedBonjourName.isEmpty,
              isPlausibleSkyBridgeServiceInstanceName(normalizedBonjourName),
              let route = BonjourRouteTuple(device),
              route.isPrimaryControlRoute,
              route.name == normalizedBonjourName else {
            return false
        }
        return true
    }

    static func isPlausibleSkyBridgeServiceInstanceName(_ raw: String?) -> Bool {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              BonjourServiceIdentitySanitizer.sanitizedServiceInstanceName(raw) != nil else {
            return false
        }
        let lowercased = raw.lowercased()
        if lowercased == "unknown device" || lowercased == "未知设备" {
            return false
        }
        if lowercased.hasPrefix("id:")
            || lowercased.hasPrefix("host:")
            || lowercased.hasPrefix("peer:")
            || lowercased.hasPrefix("recent:") {
            return false
        }
        if UUID(uuidString: raw) != nil {
            return false
        }
        if let sanitized = connectableAddress(raw),
           sanitized == raw || sanitized == lowercased {
            return false
        }
        return true
    }

    static func deduplicatedConnectableCandidates(_ candidates: [DiscoveredDevice]) -> [DiscoveredDevice] {
        var seen = Set<String>()
        return candidates.filter { candidate in
            let key = candidate.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { return false }
            return seen.insert(key).inserted
        }
    }

    static func preferredConnectableDevice(_ lhs: DiscoveredDevice, _ rhs: DiscoveredDevice) -> DiscoveredDevice {
        connectableDeviceScore(rhs) > connectableDeviceScore(lhs) ? rhs : lhs
    }

    static func connectableDeviceScore(_ device: DiscoveredDevice) -> Int {
        let skybridgeTCP = DiscoveryServiceType.skybridge.rawValue
        let skybridgeUDP = DiscoveryServiceType.skybridgeQUIC.rawValue
        let remoteService = DiscoveredDevice.remoteControlServiceType
        let transferService = DiscoveredDevice.fileTransferServiceType

        var score = 0
        if normalizedStrongDeviceId(for: device) != nil {
            score += 220
        }
        if device.services.contains(skybridgeTCP) {
            score += 200
        }
        if device.bonjourServiceType == skybridgeTCP {
            score += 140
        }
        if BonjourRouteTuple(device)?.isPrimaryControlRoute == true {
            score += 100
        }
        if device.services.contains(skybridgeUDP) || device.portMap[skybridgeUDP] != nil {
            score += 40
        }
        if device.services.contains(remoteService) || device.bonjourServiceType == remoteService {
            score += 180
        }
        if device.remoteControlPort != nil {
            score += 140
        }
        if device.supportsRemoteControl {
            score += 120
        }
        if device.services.contains(transferService) || device.bonjourServiceType == transferService {
            score += 100
        }
        if device.fileTransferPort != nil {
            score += 80
        }
        if device.supportsFileTransfer {
            score += 60
        }
        if device.bonjourServiceName?.isEmpty == false {
            score += 60
        }
        return score
    }

    static func uniqueSameNameConnectableCandidate(
        for device: DiscoveredDevice,
        candidates: [DiscoveredDevice]
    ) -> DiscoveredDevice? {
        let targetName = normalizedDeviceNameToken(device.name)
        guard !targetName.isEmpty else { return nil }

        let matches = candidates.filter { candidate in
            let candidateName = normalizedDeviceNameToken(candidate.name)
            guard candidateName == targetName else { return false }
            return candidate.platform == .unknown
                || device.platform == .unknown
                || candidate.platform == device.platform
        }

        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    static func normalizedDeviceNameToken(_ raw: String?) -> String {
        raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased() ?? ""
    }

    static func connectionEndpointCandidates(
        for device: DiscoveredDevice,
        liveBonjourControlEndpoints: [NWEndpoint]
    ) -> [NWEndpoint] {
        let parsedBonjourIdentity = parseBonjourPeerIdentifier(device.id)
        let bonjourName = BonjourServiceIdentitySanitizer.sanitizedServiceInstanceName(device.bonjourServiceName)
            ?? parsedBonjourIdentity?.name
        let bonjourDomain = device.bonjourServiceDomain
            ?? parsedBonjourIdentity?.domain
            ?? "local."
        let skybridgeTCP = DiscoveryServiceType.skybridge.rawValue
        let usableBonjourName =
            isPlausibleSkyBridgeServiceInstanceName(bonjourName)
            ? bonjourName?.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        let hasTCPBonjourEvidence = shouldPreferBonjourSkyBridgeEndpoint(
            for: device,
            bonjourName: usableBonjourName ?? ""
        )
        // `ipAddress` and `portMap` may originate from independent TXT fields. Reconstructing a
        // `.service` value from persisted name/type/domain is also insufficient: it discards the
        // live result's interface, which is the route ownership needed for AWDL. Accept only the
        // exact live endpoint after proving it matches this device's primary advertisement.
        guard hasTCPBonjourEvidence,
              let usableBonjourName,
              let advertisedRoute = BonjourRouteTuple(
                name: usableBonjourName,
                type: skybridgeTCP,
                domain: bonjourDomain
              ) else {
            return []
        }

        let target = ApplePeerConnectivityPolicy.DialTarget(
            deviceIds: [normalizedStrongDeviceId(for: device)].compactMap { $0 },
            protocolPublicKeyFingerprints: [],
            routes: [advertisedRoute.sharedIdentity]
        )
        var endpointClaims: [(endpoint: NWEndpoint, claim: ApplePeerConnectivityPolicy.RouteClaim)] = []
        for endpoint in liveBonjourControlEndpoints {
            guard case .service(let liveName, let liveType, let liveDomain, _) = endpoint,
                  let liveRoute = BonjourRouteTuple(
                    name: liveName,
                    type: liveType,
                    domain: liveDomain
                  ) else {
                continue
            }
            endpointClaims.append((
                endpoint,
                ApplePeerConnectivityPolicy.RouteClaim(
                    route: liveRoute.sharedIdentity,
                    authority: .init(
                        deviceId: nil,
                        protocolPublicKeyFingerprint: nil,
                        platform: nil
                    ),
                    provenance: .liveBrowser
                )
            ))
        }
        let orderedIndices = ApplePeerConnectivityPolicy.orderedEligibleClaimIndices(
            target: target,
            claims: endpointClaims.map(\.claim),
            requiredServiceKind: .control
        )
        var seenEndpointKeys = Set<String>()
        return orderedIndices.compactMap { index in
            let endpoint = endpointClaims[index].endpoint
            return seenEndpointKeys.insert(BonjourBrowseEndpointIdentity.key(for: endpoint)).inserted
                ? endpoint
                : nil
        }
    }

    #if DEBUG || SKYBRIDGE_TESTING
    /// Pure policy convenience for unit tests. Runtime code must supply the exact live browser
    /// endpoint so an AWDL interface is never reconstructed as `nil`.
    static func connectionEndpointCandidates(for device: DiscoveredDevice) -> [NWEndpoint] {
        guard let route = BonjourRouteTuple(device) else { return [] }
        return connectionEndpointCandidates(
            for: device,
            liveBonjourControlEndpoints: [.service(
                name: route.name,
                type: route.type,
                domain: route.domain,
                interface: nil
            )]
        )
    }
    #endif

    static func shouldAwaitSkyBridgeControlRoute(
        for device: DiscoveredDevice,
        liveBonjourControlEndpoints: [NWEndpoint] = []
    ) -> Bool {
        guard connectionEndpointCandidates(
                for: device,
                liveBonjourControlEndpoints: liveBonjourControlEndpoints
              ).isEmpty,
              normalizedStrongDeviceId(for: device) != nil,
              isPlausibleSkyBridgeServiceInstanceName(device.bonjourServiceName) else {
            return false
        }

        // A persisted primary route is identity/context evidence, not an actionable
        // endpoint because it no longer carries the exact live NWInterface. Give the
        // browser a bounded opportunity to republish that exact route before failing.
        if BonjourRouteTuple(device)?.isPrimaryControlRoute == true {
            return true
        }

        let partialRouteServices: Set<String> = [
            DiscoveryServiceType.skybridgeQUIC.rawValue,
            DiscoveredDevice.fileTransferServiceType,
            DiscoveredDevice.remoteControlServiceType
        ]
        if let serviceType = device.bonjourServiceType,
           partialRouteServices.contains(serviceType) {
            return true
        }
        return !partialRouteServices.isDisjoint(with: device.services)
    }

    static func resolvedSkyBridgeControlPort(for device: DiscoveredDevice) -> UInt16? {
        // Diagnostic only. This TXT-derived value must never be combined with `ipAddress` to
        // construct an actionable endpoint; use `connectionEndpointCandidates(for:)` instead.
        let skybridgeTCP = DiscoveryServiceType.skybridge.rawValue
        guard let value = device.portMap[skybridgeTCP], value > 0 else { return nil }
        return value
    }

    static func signedLANRefreshEndpointClass(_ endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .hostPort:
            return "direct-host"
        case .service:
            return "bonjour-service"
        default:
            return "other"
        }
    }

    static func shouldIncludePeerToPeer(for endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return true }
        return ConnectableAddressCanonicalizer.prefersPeerToPeer(for: String(describing: host))
    }

    static func normalizedStrongDeviceId(for device: DiscoveredDevice) -> String? {
        PeerIdentityAliasResolver.persistentDeviceId(from: device.id)
    }

    static func sanitizedConnectableAddress(for device: DiscoveredDevice) -> String? {
        sanitizedConnectableAddress(device.ipAddress) ?? sanitizedConnectableAddress(hostAddress(from: device.id))
    }

    static func connectableAddress(for device: DiscoveredDevice) -> String? {
        let hostScopedAddress = connectableAddress(hostAddress(from: device.id))
        if let directAddress = connectableAddress(device.ipAddress) {
            return directAddress
        }
        return hostScopedAddress
    }

    static func hostAddress(from identifier: String) -> String? {
        let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("host:") {
            return String(normalized.dropFirst("host:".count))
        }
        if normalized.hasPrefix("peer:") {
            return String(normalized.dropFirst("peer:".count))
        }
        return nil
    }

    static func sanitizedConnectableAddress(_ raw: String?) -> String? {
        ConnectableAddressCanonicalizer.lookupKey(raw)
    }

    static func connectableAddress(_ raw: String?) -> String? {
        ConnectableAddressCanonicalizer.connectionTarget(raw)
    }

    static func endpointHostAddress(_ endpoint: NWEndpoint?) -> String? {
        guard let endpoint else { return nil }
        guard case .hostPort(let host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let ipv4):
            return "\(ipv4)"
        case .ipv6(let ipv6):
            return "\(ipv6)"
        case .name(let name, _):
            return name
        @unknown default:
            return nil
        }
    }

    static func isLoopbackAddress(_ ipAddress: String) -> Bool {
        let normalized = ipAddress.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).lowercased()
        return normalized == "127.0.0.1"
            || normalized == "::1"
            || normalized == "0:0:0:0:0:0:0:1"
            || normalized == "::ffff:127.0.0.1"
            || normalized == "localhost"
    }
}
