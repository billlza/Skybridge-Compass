import Foundation
import Network
import SkyBridgeProtocolCore

enum RemoteDesktopLANEndpointCandidateFactory {
    struct Plan {
        let endpoints: [RemoteDesktopLANEndpointCandidate]
        let ignoredEndpointCount: Int
    }

    static func makePlan(
        liveBonjourEndpoints: [NWEndpoint],
        remoteServiceType: String
    ) -> Plan {
        var candidates: [RemoteDesktopLANEndpointCandidate] = []
        var seen = Set<String>()
        var ignoredEndpointCount = 0

        let orderedEndpoints = liveBonjourEndpoints.sorted {
            interfacePriority($0) < interfacePriority($1)
        }
        for endpoint in orderedEndpoints {
            guard case .service(_, let type, _, let observedInterface) = endpoint,
                  type == remoteServiceType,
                  let observedInterface else {
                ignoredEndpointCount += 1
                continue
            }
            let interfaceClass = RemoteDesktopLANRoutePolicy.interfaceClass(
                interfaceName: observedInterface.name,
                interfaceType: observedInterface.type
            )
            guard interfaceClass != .unsupported,
                  interfaceClass != .peerToPeer
                    || ApplePeerConnectivityPolicy.remoteControlMediaAllowsPeerToPeer else {
                ignoredEndpointCount += 1
                continue
            }

            let key = String(describing: endpoint)
            guard seen.insert(key).inserted else { continue }
            candidates.append(
                RemoteDesktopLANEndpointCandidate(
                    endpoint: endpoint,
                    provenance: .liveBrowser,
                    observedInterface: observedInterface,
                    interfaceClass: interfaceClass
                )
            )
        }

        return Plan(
            endpoints: candidates,
            ignoredEndpointCount: ignoredEndpointCount
        )
    }

    static func interfacePriority(
        interfaceName: String,
        interfaceType: NWInterface.InterfaceType
    ) -> Int {
        switch RemoteDesktopLANRoutePolicy.interfaceClass(
            interfaceName: interfaceName,
            interfaceType: interfaceType
        ) {
        case .infrastructure:
            return 0
        case .peerToPeer:
            return 1
        case .unsupported:
            return 2
        }
    }

    private static func interfacePriority(_ endpoint: NWEndpoint) -> Int {
        guard case .service(_, _, _, let interface) = endpoint,
              let interface else {
            return 3
        }
        return interfacePriority(interfaceName: interface.name, interfaceType: interface.type)
    }
}
