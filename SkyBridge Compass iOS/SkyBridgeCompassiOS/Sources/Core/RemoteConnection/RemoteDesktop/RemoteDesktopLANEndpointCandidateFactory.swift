import Foundation
import Network

enum RemoteDesktopLANEndpointCandidateFactory {
    struct BonjourServiceIdentity: Equatable {
        let name: String
        let domain: String
    }

    struct HostCandidateLog: Equatable {
        let reason: String
        let host: String
        let port: UInt16
        let routeClass: String
        let prefersPeerToPeer: Bool

        var message: String {
            "📡 远控候选地址: reason=\(reason) host=\(host) port=\(port) routeClass=\(routeClass) peerToPeer=\(prefersPeerToPeer)"
        }
    }

    struct Plan {
        let endpoints: [NWEndpoint]
        let hostCandidateLogs: [HostCandidateLog]
        let missingActivePeerPortHost: String?
    }

    static func makePlan(
        remoteControlPort port: UInt16?,
        directIP: String?,
        resolvedIP: String?,
        bonjourService: BonjourServiceIdentity?,
        activePeerAddress: String?,
        remoteServiceType: String
    ) -> Plan {
        var endpoints: [NWEndpoint] = []
        var seen = Set<String>()
        var hostCandidateLogs: [HostCandidateLog] = []

        if let port {
            for ip in [directIP, resolvedIP]
                .compactMap({ $0 })
                .filter({ ConnectableAddressCanonicalizer.isRoutableLANAddress($0) }) {
                appendHostEndpoint(
                    ip,
                    port: port,
                    reason: "lan-direct",
                    to: &endpoints,
                    seen: &seen,
                    hostCandidateLogs: &hostCandidateLogs
                )
            }
        }

        if let bonjourService {
            appendEndpoint(
                .service(
                    name: bonjourService.name,
                    type: remoteServiceType,
                    domain: bonjourService.domain,
                    interface: nil
                ),
                to: &endpoints,
                seen: &seen
            )
        }

        if let port {
            for ip in [directIP, resolvedIP]
                .compactMap({ $0 })
                .filter({ ConnectableAddressCanonicalizer.isLinkLocal($0) }) {
                appendHostEndpoint(
                    ip,
                    port: port,
                    reason: "link-local-fallback",
                    to: &endpoints,
                    seen: &seen,
                    hostCandidateLogs: &hostCandidateLogs
                )
            }
        }

        var missingActivePeerPortHost: String?
        if let activePeerAddress {
            if let port {
                appendHostEndpoint(
                    activePeerAddress,
                    port: port,
                    reason: "active-peer-fallback",
                    to: &endpoints,
                    seen: &seen,
                    hostCandidateLogs: &hostCandidateLogs
                )
            } else {
                missingActivePeerPortHost = activePeerAddress
            }
        }

        return Plan(
            endpoints: endpoints,
            hostCandidateLogs: hostCandidateLogs,
            missingActivePeerPortHost: missingActivePeerPortHost
        )
    }

    private static func appendHostEndpoint(
        _ ip: String,
        port: UInt16,
        reason: String,
        to endpoints: inout [NWEndpoint],
        seen: inout Set<String>,
        hostCandidateLogs: inout [HostCandidateLog]
    ) {
        hostCandidateLogs.append(
            HostCandidateLog(
                reason: reason,
                host: ip,
                port: port,
                routeClass: ConnectableAddressCanonicalizer.routeClass(ip),
                prefersPeerToPeer: ConnectableAddressCanonicalizer.prefersPeerToPeer(for: ip)
            )
        )
        appendEndpoint(
            .hostPort(host: .init(ip), port: .init(integerLiteral: port)),
            to: &endpoints,
            seen: &seen
        )
    }

    private static func appendEndpoint(
        _ endpoint: NWEndpoint,
        to endpoints: inout [NWEndpoint],
        seen: inout Set<String>
    ) {
        let key = String(describing: endpoint)
        guard seen.insert(key).inserted else { return }
        endpoints.append(endpoint)
    }
}
