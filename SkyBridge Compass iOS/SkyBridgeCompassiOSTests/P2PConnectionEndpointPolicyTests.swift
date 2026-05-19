import Network
import XCTest
@testable import SkyBridgeCompass_iOS

final class P2PConnectionEndpointPolicyTests: XCTestCase {
    func testParsesBonjourPeerIdentifierAndRejectsSyntheticNames() throws {
        let parsed = try XCTUnwrap(
            P2PConnectionEndpointPolicy.parseBonjourPeerIdentifier("bonjour:Studio MacBook Pro@local.")
        )

        XCTAssertEqual(parsed.name, "Studio MacBook Pro")
        XCTAssertEqual(parsed.domain, "local.")
        XCTAssertTrue(P2PConnectionEndpointPolicy.isPlausibleSkyBridgeServiceInstanceName("Studio MacBook Pro"))
        XCTAssertFalse(P2PConnectionEndpointPolicy.isPlausibleSkyBridgeServiceInstanceName("id:e0715a9a-d0d3-47e6-b353-de0a30293e1f"))
        XCTAssertFalse(P2PConnectionEndpointPolicy.isPlausibleSkyBridgeServiceInstanceName("host:fe80::1%en0"))
        XCTAssertFalse(P2PConnectionEndpointPolicy.isPlausibleSkyBridgeServiceInstanceName("192.168.1.20"))
    }

    func testBonjourServiceEndpointIsUsedWhenNoDirectAddressExists() throws {
        let endpoints = P2PConnectionEndpointPolicy.connectionEndpointCandidates(
            for: skybridgeDevice(ipAddress: nil)
        )

        XCTAssertEqual(endpoints.count, 1)
        try assertServiceEndpoint(endpoints[0], name: "Studio MacBook Pro", domain: "local.")
    }

    func testDirectHostCanBePreferredBeforeBonjourService() throws {
        let endpoints = P2PConnectionEndpointPolicy.connectionEndpointCandidates(
            for: skybridgeDevice(ipAddress: "192.168.1.20"),
            preferDirectHostPort: true
        )

        XCTAssertEqual(endpoints.count, 2)
        try assertHostEndpoint(endpoints[0], host: "192.168.1.20", port: 9527)
        try assertServiceEndpoint(endpoints[1], name: "Studio MacBook Pro", domain: "local.")
    }

    func testBonjourServiceStaysFirstForNormalSkyBridgeDiscovery() throws {
        let endpoints = P2PConnectionEndpointPolicy.connectionEndpointCandidates(
            for: skybridgeDevice(ipAddress: "192.168.1.20")
        )

        XCTAssertEqual(endpoints.count, 2)
        try assertServiceEndpoint(endpoints[0], name: "Studio MacBook Pro", domain: "local.")
        try assertHostEndpoint(endpoints[1], host: "192.168.1.20", port: 9527)
    }

    func testLinkLocalHostScopeIsPreservedForConnectionTarget() throws {
        let device = DiscoveredDevice(
            id: "host:fe80::1%bridge100",
            name: "Studio MacBook Pro",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "26.5",
            portMap: [DiscoveryServiceType.skybridge.rawValue: 9527]
        )

        XCTAssertEqual(P2PConnectionEndpointPolicy.sanitizedConnectableAddress(for: device), "fe80::1")
        XCTAssertEqual(P2PConnectionEndpointPolicy.connectableAddress(for: device), "fe80::1%bridge100")

        let endpointDevice = DiscoveredDevice(
            id: "host:fe80::1",
            name: "Studio MacBook Pro",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "26.5",
            portMap: [DiscoveryServiceType.skybridge.rawValue: 9527]
        )
        let endpoints = P2PConnectionEndpointPolicy.connectionEndpointCandidates(for: endpointDevice)
        XCTAssertEqual(endpoints.count, 1)
        try assertHostEndpoint(endpoints[0], host: "fe80::1", port: 9527)
    }

    func testConnectableScoringPrefersRicherLiveCandidate() {
        let bareCanonical = DiscoveredDevice(
            id: "id:e0715a9a-d0d3-47e6-b353-de0a30293e1f",
            name: "Studio MacBook Pro",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "26.5"
        )
        let liveCandidate = skybridgeDevice(ipAddress: "192.168.1.20")

        let preferred = P2PConnectionEndpointPolicy.preferredConnectableDevice(bareCanonical, liveCandidate)

        XCTAssertEqual(preferred.id, liveCandidate.id)
        XCTAssertGreaterThan(
            P2PConnectionEndpointPolicy.connectableDeviceScore(liveCandidate),
            P2PConnectionEndpointPolicy.connectableDeviceScore(bareCanonical)
        )
    }

    func testPeerToPeerPolicyMatchesEndpointClass() {
        XCTAssertTrue(
            P2PConnectionEndpointPolicy.shouldIncludePeerToPeer(
                for: .service(
                    name: "Studio MacBook Pro",
                    type: DiscoveryServiceType.skybridge.rawValue,
                    domain: "local.",
                    interface: nil
                )
            )
        )
        XCTAssertFalse(
            P2PConnectionEndpointPolicy.shouldIncludePeerToPeer(
                for: .hostPort(host: NWEndpoint.Host("192.168.1.20"), port: 9527)
            )
        )
        XCTAssertTrue(
            P2PConnectionEndpointPolicy.shouldIncludePeerToPeer(
                for: .hostPort(host: NWEndpoint.Host("fe80::1%en0"), port: 9527)
            )
        )
    }

    private func skybridgeDevice(ipAddress: String?) -> DiscoveredDevice {
        DiscoveredDevice(
            id: "bonjour:Studio MacBook Pro@local.",
            name: "Studio MacBook Pro",
            bonjourServiceName: "Studio MacBook Pro",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "26.5",
            ipAddress: ipAddress,
            bonjourServiceType: DiscoveryServiceType.skybridge.rawValue,
            bonjourServiceDomain: "local.",
            services: [DiscoveryServiceType.skybridge.rawValue],
            portMap: [DiscoveryServiceType.skybridge.rawValue: 9527]
        )
    }

    private func assertServiceEndpoint(
        _ endpoint: NWEndpoint,
        name: String,
        domain: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        guard case .service(let endpointName, let type, let endpointDomain, _) = endpoint else {
            XCTFail("Expected service endpoint, got \(endpoint)", file: file, line: line)
            return
        }

        XCTAssertEqual(endpointName, name, file: file, line: line)
        XCTAssertEqual(type, DiscoveryServiceType.skybridge.rawValue, file: file, line: line)
        XCTAssertEqual(endpointDomain, domain, file: file, line: line)
    }

    private func assertHostEndpoint(
        _ endpoint: NWEndpoint,
        host: String,
        port: UInt16,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        guard case .hostPort(let endpointHost, let endpointPort) = endpoint else {
            XCTFail("Expected host endpoint, got \(endpoint)", file: file, line: line)
            return
        }

        XCTAssertEqual(String(describing: endpointHost), host, file: file, line: line)
        XCTAssertEqual(endpointPort.rawValue, port, file: file, line: line)
    }
}
