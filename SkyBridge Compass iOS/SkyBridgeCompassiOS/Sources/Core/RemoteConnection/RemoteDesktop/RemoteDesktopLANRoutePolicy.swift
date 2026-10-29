import Foundation
import Network
import SkyBridgeProtocolCore

struct RemoteDesktopLANEndpointCandidate {
    let endpoint: NWEndpoint
    let provenance: ApplePeerConnectivityPolicy.RouteProvenance
    let observedInterface: NWInterface
    let interfaceClass: RemoteDesktopLANRoutePolicy.InterfaceClass
}

enum RemoteDesktopLANRoutePolicy {
    typealias InterfaceClass = ApplePeerConnectivityPolicy.RemoteControlInterfaceClass
    typealias RejectionReason = ApplePeerConnectivityPolicy.RemoteControlRouteRejectionReason
    typealias ResolvedRouteEvidence = ApplePeerConnectivityPolicy.RemoteControlRouteEvidence

    static func shouldIncludePeerToPeer(for candidate: RemoteDesktopLANEndpointCandidate) -> Bool {
        ApplePeerConnectivityPolicy.remoteControlMediaIncludesPeerToPeer(
            for: candidate.interfaceClass
        )
    }

    static func interfaceClass(
        interfaceName: String,
        interfaceType: NWInterface.InterfaceType
    ) -> InterfaceClass {
        ApplePeerConnectivityPolicy.remoteControlInterfaceClass(
            interfaceName: interfaceName,
            isWiFi: interfaceType == .wifi,
            isWiredEthernet: interfaceType == .wiredEthernet
        )
    }

    static func resolvedRouteEvidence(
        candidate: RemoteDesktopLANEndpointCandidate,
        resolvedEndpoint: NWEndpoint?,
        pathUsesRequestedInterfaceType: Bool
    ) -> ResolvedRouteEvidence {
        let requestedServiceType: String?
        if case .service(_, let type, _, _) = candidate.endpoint {
            requestedServiceType = type
        } else {
            requestedServiceType = nil
        }

        let resolvedHost: String?
        if let resolvedEndpoint,
           case .hostPort(let host, _) = resolvedEndpoint {
            resolvedHost = String(describing: host)
        } else {
            resolvedHost = nil
        }

        return ResolvedRouteEvidence(
            provenance: candidate.provenance,
            requestedServiceType: requestedServiceType,
            requestedInterfaceName: candidate.observedInterface.name,
            requestedInterfaceClass: candidate.interfaceClass,
            pathUsesRequestedInterfaceType: pathUsesRequestedInterfaceType,
            resolvedAddressClass: resolvedAddressClass(resolvedHost),
            resolvedInterfaceScope: resolvedInterfaceScope(resolvedHost)
        )
    }

    static func rejectionReason(for evidence: ResolvedRouteEvidence) -> RejectionReason? {
        ApplePeerConnectivityPolicy.remoteControlRouteRejectionReason(for: evidence)
    }

    static func resolvedRouteRejection(for evidence: ResolvedRouteEvidence) -> String? {
        rejectionReason(for: evidence).map {
            "remote route rejected: reason=\($0.rawValue) provenance=\(evidence.provenance.rawValue)"
        }
    }

    static func routeAddressClass(for endpoint: NWEndpoint?) -> String {
        guard let endpoint else { return "unresolved" }
        return routeAddressClass(for: endpoint)
    }

    static func routeAddressClass(for endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .hostPort(let host, _):
            return ConnectableAddressCanonicalizer.routeClass(String(describing: host))
        case .service:
            return "bonjour-service"
        default:
            return "other"
        }
    }

    static func resolvedInterfaceScope(_ rawHost: String?) -> String? {
        guard let normalized = ConnectableAddressCanonicalizer.connectionTarget(rawHost),
              let percentIndex = normalized.firstIndex(of: "%") else {
            return nil
        }
        let scope = normalized[normalized.index(after: percentIndex)...]
        guard !scope.isEmpty else { return nil }
        return String(scope).lowercased()
    }

    static func interfaceScopeMatches(_ evidence: ResolvedRouteEvidence) -> Bool {
        ApplePeerConnectivityPolicy.remoteControlInterfaceScopeMatches(evidence)
    }

    static func routeDescription(for endpoint: NWEndpoint?) -> String {
        guard let endpoint else { return "nil" }
        return String(describing: endpoint)
    }

    private static func resolvedAddressClass(
        _ rawHost: String?
    ) -> ApplePeerConnectivityPolicy.RemoteControlResolvedAddressClass {
        guard let normalized = ConnectableAddressCanonicalizer.connectionTarget(rawHost) else {
            return rawHost == nil ? .unresolved : .invalid
        }
        let unscoped = normalized.split(separator: "%", maxSplits: 1).first.map(String.init)
            ?? normalized

        if let ipv4 = IPv4Address(unscoped) {
            let bytes = Array(ipv4.rawValue)
            guard bytes.count == 4,
                  !bytes.allSatisfy({ $0 == 0 }),
                  bytes[0] != 127,
                  !(224...239).contains(bytes[0]) else {
                return .invalid
            }
            return ConnectableAddressCanonicalizer.isLinkLocal(normalized)
                ? .linkLocalIPv4
                : .routable
        }
        if let ipv6 = IPv6Address(unscoped) {
            let bytes = Array(ipv6.rawValue)
            guard bytes.count == 16,
                  !bytes.allSatisfy({ $0 == 0 }),
                  bytes != Array(repeating: 0, count: 15) + [1],
                  bytes[0] != 0xff else {
                return .invalid
            }
            return ConnectableAddressCanonicalizer.isLinkLocal(normalized)
                ? .linkLocalIPv6
                : .routable
        }
        return .invalid
    }
}
