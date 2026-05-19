import Network
import XCTest

@testable import SkyBridgeCompass_iOS

final class RemoteDesktopLANEndpointCandidateFactoryTests: XCTestCase {
    func testCandidateOrderPrefersRoutableBonjourThenLinkLocalAndActivePeer() {
        let plan = RemoteDesktopLANEndpointCandidateFactory.makePlan(
            remoteControlPort: 5_901,
            directIP: "192.168.1.10",
            resolvedIP: "169.254.10.20",
            bonjourService: .init(name: "MacBook", domain: "local."),
            activePeerAddress: "10.0.0.42",
            remoteServiceType: "_skybridge-remote._tcp"
        )

        XCTAssertEqual(
            plan.endpoints.map(endpointIdentity),
            [
                "192.168.1.10:5901",
                "service:MacBook:_skybridge-remote._tcp:local.",
                "169.254.10.20:5901",
                "10.0.0.42:5901"
            ]
        )
        XCTAssertEqual(
            plan.hostCandidateLogs.map(\.reason),
            ["lan-direct", "link-local-fallback", "active-peer-fallback"]
        )
        XCTAssertNil(plan.missingActivePeerPortHost)
    }

    func testDuplicateHostCandidatesAreOnlyReturnedOnce() {
        let plan = RemoteDesktopLANEndpointCandidateFactory.makePlan(
            remoteControlPort: 5_901,
            directIP: "192.168.1.10",
            resolvedIP: "192.168.1.10",
            bonjourService: nil,
            activePeerAddress: "192.168.1.10",
            remoteServiceType: "_skybridge-remote._tcp"
        )

        XCTAssertEqual(plan.endpoints.map(endpointIdentity), ["192.168.1.10:5901"])
        XCTAssertEqual(plan.hostCandidateLogs.map(\.reason), ["lan-direct", "lan-direct", "active-peer-fallback"])
    }

    func testActivePeerWithoutExplicitPortReturnsWarningOnly() {
        let plan = RemoteDesktopLANEndpointCandidateFactory.makePlan(
            remoteControlPort: nil,
            directIP: nil,
            resolvedIP: nil,
            bonjourService: nil,
            activePeerAddress: "10.0.0.42",
            remoteServiceType: "_skybridge-remote._tcp"
        )

        XCTAssertTrue(plan.endpoints.isEmpty)
        XCTAssertEqual(plan.missingActivePeerPortHost, "10.0.0.42")
        XCTAssertTrue(plan.hostCandidateLogs.isEmpty)
    }

    func testLinkLocalEndpointStillReliesOnRoutePolicyForPeerToPeerParameters() {
        let plan = RemoteDesktopLANEndpointCandidateFactory.makePlan(
            remoteControlPort: 5_901,
            directIP: "169.254.10.20",
            resolvedIP: nil,
            bonjourService: nil,
            activePeerAddress: nil,
            remoteServiceType: "_skybridge-remote._tcp"
        )

        let endpoint = try! XCTUnwrap(plan.endpoints.first)
        XCTAssertEqual(endpointIdentity(endpoint), "169.254.10.20:5901")
        XCTAssertEqual(
            RemoteDesktopLANRoutePolicy.shouldIncludePeerToPeer(for: endpoint),
            true
        )
        XCTAssertEqual(plan.hostCandidateLogs.first?.routeClass, "link-local")
        XCTAssertTrue(plan.hostCandidateLogs.first?.prefersPeerToPeer ?? false)
    }

    private func endpointIdentity(_ endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .hostPort(let host, let port):
            "\(host):\(port)"
        case .service(let name, let type, let domain, _):
            "service:\(name):\(type):\(domain)"
        default:
            String(describing: endpoint)
        }
    }
}
