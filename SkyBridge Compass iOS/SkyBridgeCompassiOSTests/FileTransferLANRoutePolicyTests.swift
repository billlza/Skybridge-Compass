import Network
import XCTest
@testable import SkyBridgeCompass_iOS

final class FileTransferLANRoutePolicyTests: XCTestCase {
    func testClassifiesRouteAddressesAndPeerToPeerPreference() {
        let lanHost = NWEndpoint.hostPort(host: "192.168.31.20", port: 8080)
        let linkLocalHost = NWEndpoint.hostPort(host: "fe80::1%en0", port: 8080)
        let bonjour = NWEndpoint.service(
            name: "Mac",
            type: "_skybridge-transfer._tcp",
            domain: "local",
            interface: nil
        )

        XCTAssertEqual(FileTransferLANRoutePolicy.routeAddressClass(for: lanHost), "lan-direct")
        XCTAssertEqual(FileTransferLANRoutePolicy.routeAddressClass(for: bonjour), "bonjour-service")
        XCTAssertEqual(FileTransferLANRoutePolicy.routeAddressClass(for: nil), "unresolved")
        XCTAssertFalse(FileTransferLANRoutePolicy.shouldIncludePeerToPeer(for: lanHost))
        XCTAssertTrue(FileTransferLANRoutePolicy.shouldIncludePeerToPeer(for: linkLocalHost))
        XCTAssertTrue(FileTransferLANRoutePolicy.routePrefersPeerToPeer(for: linkLocalHost))
        XCTAssertEqual(
            FileTransferLANRoutePolicy.statusToken("host 192.168.31.20"),
            "host_192.168.31.20"
        )
    }

    func testRejectsUnverifiedBonjourAndPeerToPeerRoutes() {
        let bonjour = NWEndpoint.service(
            name: "Mac",
            type: "_skybridge-transfer._tcp",
            domain: "local",
            interface: nil
        )
        let routableHost = NWEndpoint.hostPort(host: "192.168.31.20", port: 8080)
        let linkLocalHost = NWEndpoint.hostPort(host: "fe80::1%en0", port: 8080)

        XCTAssertNil(
            FileTransferLANRoutePolicy.resolvedRouteRejection(
                requestedEndpoint: routableHost,
                resolvedEndpoint: routableHost
            )
        )
        XCTAssertEqual(
            FileTransferLANRoutePolicy.resolvedRouteRejection(
                requestedEndpoint: linkLocalHost,
                resolvedEndpoint: linkLocalHost
            ),
            "requested peer-to-peer file-transfer route rejected: requested=\(String(describing: linkLocalHost))"
        )
        XCTAssertEqual(
            FileTransferLANRoutePolicy.resolvedRouteRejection(
                requestedEndpoint: bonjour,
                resolvedEndpoint: nil
            ),
            "unverified Bonjour file-transfer route rejected: requested=\(String(describing: bonjour))"
        )
        XCTAssertEqual(
            FileTransferLANRoutePolicy.resolvedRouteRejection(
                requestedEndpoint: bonjour,
                resolvedEndpoint: linkLocalHost
            ),
            "resolved peer-to-peer file-transfer route rejected: requested=\(String(describing: bonjour)) resolved=\(String(describing: linkLocalHost))"
        )
    }
}
