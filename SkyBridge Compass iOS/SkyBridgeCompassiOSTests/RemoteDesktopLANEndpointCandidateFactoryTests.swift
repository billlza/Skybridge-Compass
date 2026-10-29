import Network
import SkyBridgeProtocolCore
import XCTest

@testable import SkyBridgeCompass_iOS

final class RemoteDesktopLANEndpointCandidateFactoryTests: XCTestCase {
    func testFactoryRejectsHostAndInterfaceLessSyntheticServiceEndpoints() {
        let host = NWEndpoint.hostPort(
            host: NWEndpoint.Host("192.168.1.10"),
            port: NWEndpoint.Port(integerLiteral: 5_901)
        )
        let syntheticService = NWEndpoint.service(
            name: "MacBook",
            type: DiscoveredDevice.remoteControlServiceType,
            domain: "local.",
            interface: nil
        )
        let wrongService = NWEndpoint.service(
            name: "MacBook",
            type: DiscoveredDevice.fileTransferServiceType,
            domain: "local.",
            interface: nil
        )

        let plan = RemoteDesktopLANEndpointCandidateFactory.makePlan(
            liveBonjourEndpoints: [host, syntheticService, wrongService],
            remoteServiceType: DiscoveredDevice.remoteControlServiceType
        )

        XCTAssertTrue(plan.endpoints.isEmpty)
        XCTAssertEqual(plan.ignoredEndpointCount, 3)
    }

    func testInterfacePriorityKeepsInfrastructureAheadOfPeerToPeerAndUnsupportedRoutes() {
        XCTAssertEqual(
            RemoteDesktopLANEndpointCandidateFactory.interfacePriority(
                interfaceName: "en0",
                interfaceType: .wifi
            ),
            0
        )
        XCTAssertEqual(
            RemoteDesktopLANEndpointCandidateFactory.interfacePriority(
                interfaceName: "awdl0",
                interfaceType: .other
            ),
            1
        )
        XCTAssertEqual(
            RemoteDesktopLANEndpointCandidateFactory.interfacePriority(
                interfaceName: "lo0",
                interfaceType: .loopback
            ),
            2
        )
    }

    func testPolicyAcceptsOnlyLiveInfrastructureRoutesWithBoundInterfaceEvidence() {
        XCTAssertNil(
            RemoteDesktopLANRoutePolicy.rejectionReason(
                for: evidence(resolvedHost: "fe80::1234%en0")
            )
        )
        XCTAssertNil(
            RemoteDesktopLANRoutePolicy.rejectionReason(
                for: evidence(resolvedHost: "169.254.10.20")
            )
        )
        XCTAssertNil(
            RemoteDesktopLANRoutePolicy.rejectionReason(
                for: evidence(resolvedHost: "192.168.31.20")
            )
        )
        XCTAssertNil(
            RemoteDesktopLANRoutePolicy.rejectionReason(
                for: evidence(resolvedHost: "2001:db8::20")
            )
        )
    }

    func testPolicyRejectsMissingOrMismatchedIPv6LinkLocalScope() {
        XCTAssertEqual(
            RemoteDesktopLANRoutePolicy.rejectionReason(
                for: evidence(resolvedHost: "fe80::1234")
            ),
            .resolvedScopeMismatch
        )
        XCTAssertEqual(
            RemoteDesktopLANRoutePolicy.rejectionReason(
                for: evidence(resolvedHost: "fe80::1234%awdl0")
            ),
            .resolvedScopeMismatch
        )
        XCTAssertFalse(
            RemoteDesktopLANRoutePolicy.interfaceScopeMatches(
                evidence(resolvedHost: "fe80::1234")
            )
        )
        XCTAssertTrue(
            RemoteDesktopLANRoutePolicy.interfaceScopeMatches(
                evidence(resolvedHost: "fe80::1234%en0")
            )
        )
    }

    func testPolicyRejectsUntrustedPeerToPeerAndUnboundRoutes() {
        XCTAssertEqual(
            RemoteDesktopLANRoutePolicy.rejectionReason(
                for: evidence(provenance: .persistedMetadata)
            ),
            .untrustedProvenance
        )
        XCTAssertEqual(
            RemoteDesktopLANRoutePolicy.rejectionReason(
                for: evidence(requestedServiceType: DiscoveredDevice.fileTransferServiceType)
            ),
            .wrongServiceType
        )
        XCTAssertEqual(
            RemoteDesktopLANRoutePolicy.rejectionReason(
                for: evidence(requestedInterfaceName: nil)
            ),
            .missingObservedInterface
        )
        XCTAssertEqual(
            RemoteDesktopLANRoutePolicy.rejectionReason(
                for: evidence(
                    requestedInterfaceName: "awdl0",
                    requestedInterfaceClass: .peerToPeer
                )
            ),
            .peerToPeerMediaRouteDisallowed
        )
        XCTAssertEqual(
            RemoteDesktopLANRoutePolicy.rejectionReason(
                for: evidence(pathUsesRequestedInterfaceType: false)
            ),
            .pathInterfaceTypeMismatch
        )
        XCTAssertEqual(
            RemoteDesktopLANRoutePolicy.rejectionReason(
                for: evidence(resolvedHost: nil)
            ),
            .unresolvedOrNonHostEndpoint
        )
    }

    func testPolicyRejectsInvalidResolvedAddresses() {
        for host in ["example.local", "0.0.0.0", "127.0.0.1", "::", "::1", "ff02::1%en0"] {
            XCTAssertEqual(
                RemoteDesktopLANRoutePolicy.rejectionReason(
                    for: evidence(resolvedHost: host)
                ),
                .invalidResolvedAddress,
                host
            )
        }
    }

    func testRouteAddressClassesRemainDiagnosticOnly() {
        let host = NWEndpoint.hostPort(
            host: NWEndpoint.Host("192.168.31.20"),
            port: NWEndpoint.Port(integerLiteral: 5_901)
        )
        let service = NWEndpoint.service(
            name: "MacBook",
            type: DiscoveredDevice.remoteControlServiceType,
            domain: "local.",
            interface: nil
        )

        XCTAssertEqual(RemoteDesktopLANRoutePolicy.routeAddressClass(for: host), "lan-direct")
        XCTAssertEqual(RemoteDesktopLANRoutePolicy.routeAddressClass(for: service), "bonjour-service")
        XCTAssertEqual(RemoteDesktopLANRoutePolicy.routeAddressClass(for: nil), "unresolved")
    }

    private func evidence(
        provenance: ApplePeerConnectivityPolicy.RouteProvenance = .liveBrowser,
        requestedServiceType: String? = DiscoveredDevice.remoteControlServiceType,
        requestedInterfaceName: String? = "en0",
        requestedInterfaceClass: RemoteDesktopLANRoutePolicy.InterfaceClass = .infrastructure,
        pathUsesRequestedInterfaceType: Bool = true,
        resolvedHost: String? = "192.168.31.20"
    ) -> RemoteDesktopLANRoutePolicy.ResolvedRouteEvidence {
        let addressClass: ApplePeerConnectivityPolicy.RemoteControlResolvedAddressClass
        switch resolvedHost {
        case nil:
            addressClass = .unresolved
        case let host? where host.hasPrefix("fe80:"):
            addressClass = .linkLocalIPv6
        case let host? where host.hasPrefix("169.254."):
            addressClass = .linkLocalIPv4
        case let host? where Set([
            "example.local", "0.0.0.0", "127.0.0.1", "::", "::1", "ff02::1%en0"
        ]).contains(host):
            addressClass = .invalid
        default:
            addressClass = .routable
        }
        let scope = resolvedHost?.split(separator: "%", maxSplits: 1).dropFirst().first
            .map(String.init)
        return RemoteDesktopLANRoutePolicy.ResolvedRouteEvidence(
            provenance: provenance,
            requestedServiceType: requestedServiceType,
            requestedInterfaceName: requestedInterfaceName,
            requestedInterfaceClass: requestedInterfaceClass,
            pathUsesRequestedInterfaceType: pathUsesRequestedInterfaceType,
            resolvedAddressClass: addressClass,
            resolvedInterfaceScope: scope
        )
    }
}
