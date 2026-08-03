import Foundation
import Network
import SkyBridgeProtocolCore

struct FileTransferEndpointCandidate {
    let endpoint: NWEndpoint
    let provenance: ApplePeerConnectivityPolicy.RouteProvenance
}

enum FileTransferLANRoutePolicy {
    static func shouldIncludePeerToPeer(for endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        return ConnectableAddressCanonicalizer.prefersPeerToPeer(for: String(describing: host))
    }

    static func resolvedRouteRejection(
        requestedEndpoint: NWEndpoint,
        resolvedEndpoint: NWEndpoint?,
        provenance: ApplePeerConnectivityPolicy.RouteProvenance = .persistedMetadata
    ) -> String? {
        if case .hostPort(let host, _) = requestedEndpoint,
           ConnectableAddressCanonicalizer.prefersPeerToPeer(for: String(describing: host)) {
            guard provenance.isDialEligible else {
                return "requested peer-to-peer file-transfer route rejected: requested=\(String(describing: requestedEndpoint))"
            }
        }

        guard let resolvedEndpoint else {
            if case .service = requestedEndpoint {
                return "unverified Bonjour file-transfer route rejected: requested=\(String(describing: requestedEndpoint))"
            }
            return nil
        }

        guard case .hostPort(let resolvedHost, _) = resolvedEndpoint else {
            return "unverified file-transfer route rejected: requested=\(String(describing: requestedEndpoint)) resolved=\(String(describing: resolvedEndpoint))"
        }

        let resolvedHostText = String(describing: resolvedHost)
        if ConnectableAddressCanonicalizer.prefersPeerToPeer(for: resolvedHostText) {
            guard provenance.isDialEligible else {
                return "resolved peer-to-peer file-transfer route rejected: requested=\(String(describing: requestedEndpoint)) resolved=\(String(describing: resolvedEndpoint))"
            }
            return nil
        }

        if case .service = requestedEndpoint,
           !ConnectableAddressCanonicalizer.isRoutableLANAddress(resolvedHostText) {
            return "unverified Bonjour file-transfer route rejected: requested=\(String(describing: requestedEndpoint)) resolved=\(String(describing: resolvedEndpoint))"
        }
        return nil
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

    static func routePrefersPeerToPeer(for endpoint: NWEndpoint?) -> Bool {
        guard let endpoint,
              case .hostPort(let host, _) = endpoint else { return false }
        return ConnectableAddressCanonicalizer.prefersPeerToPeer(for: String(describing: host))
    }

    static func routeDescription(for endpoint: NWEndpoint?) -> String {
        guard let endpoint else { return "nil" }
        return String(describing: endpoint)
    }

    static func statusToken(_ raw: String) -> String {
        raw.replacingOccurrences(of: " ", with: "_")
    }
}
