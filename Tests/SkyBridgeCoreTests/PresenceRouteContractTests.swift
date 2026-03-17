import XCTest
@testable import SkyBridgeCore

@MainActor
final class PresenceRouteContractTests: XCTestCase {
    func testPublishConnectedAtomicallyRejectsIncompleteRoute() {
        let peerId = "route-incomplete-\(UUID().uuidString)"
        defer { ConnectionPresenceService.shared.markDisconnected(peerId: peerId) }

        let incomplete = ConnectionPresenceService.PresenceRouteDescriptor(
            peerId: peerId,
            deviceName: "Mac mini",
            displayAddress: "10.0.0.9",
            transferAddress: "",
            transferPort: 8080,
            routeSource: .inbound
        )

        let published = ConnectionPresenceService.shared.publishConnectedAtomically(
            peerId: peerId,
            displayName: "Mac mini",
            address: "10.0.0.9",
            cryptoKind: "Classic",
            suite: "X25519",
            routeDescriptor: incomplete
        )

        XCTAssertFalse(published)
        XCTAssertNil(ConnectionPresenceService.shared.routeDescriptorsByPeerId[peerId])
        XCTAssertFalse(ConnectionPresenceService.shared.activeConnections.contains(where: { $0.id == peerId }))
    }

    func testPublishConnectedAtomicallyPublishesConnectionAndRouteTogether() {
        let peerId = "route-complete-\(UUID().uuidString)"
        defer { ConnectionPresenceService.shared.markDisconnected(peerId: peerId) }

        let route = ConnectionPresenceService.PresenceRouteDescriptor(
            peerId: peerId,
            deviceName: "Mac mini",
            displayAddress: "10.0.0.9",
            transferAddress: "10.0.0.10",
            transferPort: 9090,
            routeSource: .inbound
        )

        let published = ConnectionPresenceService.shared.publishConnectedAtomically(
            peerId: peerId,
            displayName: "Mac mini",
            address: "10.0.0.9",
            cryptoKind: "Classic",
            suite: "X25519",
            routeDescriptor: route
        )

        XCTAssertTrue(published)
        XCTAssertEqual(ConnectionPresenceService.shared.routeDescriptorsByPeerId[peerId], route)
        XCTAssertTrue(ConnectionPresenceService.shared.activeConnections.contains(where: { $0.id == peerId }))
    }

    func testResolveInboundPresenceRouteUsesStableDeviceIdPlusEndpointAddress() {
        let deviceId = UUID().uuidString.lowercased()
        let discovered = DiscoveredDevice(
            id: UUID(),
            name: "MacBook Pro",
            ipv4: "192.168.31.20",
            ipv6: nil,
            services: ["_skybridge._tcp", "_skybridge-transfer._tcp"],
            portMap: ["_skybridge-transfer._tcp": 9528],
            connectionTypes: [.wifi],
            uniqueIdentifier: "id:\(deviceId)",
            deviceId: deviceId
        )

        let resolved = P2PDiscoveryService.resolveInboundPresenceRoute(
            peerId: "id:\(deviceId)",
            endpointLabel: "peer:192.168.31.20",
            discoveredDevices: [discovered],
            unifiedDevices: []
        )

        XCTAssertEqual(resolved.name, "MacBook Pro")
        XCTAssertEqual(resolved.displayAddress, "192.168.31.20")
        XCTAssertEqual(resolved.transferPort, 9528)
    }

    func testResolveInboundPresenceRouteFallsBackToEndpointAddressWhenDiscoveryLags() {
        let resolved = P2PDiscoveryService.resolveInboundPresenceRoute(
            peerId: "id:\(UUID().uuidString.lowercased())",
            endpointLabel: "peer:10.0.0.42",
            discoveredDevices: [],
            unifiedDevices: []
        )

        XCTAssertEqual(resolved.displayAddress, "10.0.0.42")
        XCTAssertEqual(resolved.transferPort, 8080)
    }
}
