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

    func testPublishConnectedAtomicallyRejectsZeroTransferPort() {
        let peerId = "route-zero-port-\(UUID().uuidString)"
        defer { ConnectionPresenceService.shared.markDisconnected(peerId: peerId) }

        let incomplete = ConnectionPresenceService.PresenceRouteDescriptor(
            peerId: peerId,
            deviceName: "iPad",
            displayAddress: "10.0.0.9",
            transferAddress: "10.0.0.9",
            transferPort: 0,
            routeSource: .inbound
        )

        let published = ConnectionPresenceService.shared.publishConnectedAtomically(
            peerId: peerId,
            displayName: "iPad",
            address: "10.0.0.9",
            cryptoKind: "Apple PQC",
            suite: "X-Wing",
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

    func testMarkConnectedDoesNotSynthesizeFileTransferRouteFromLocalListenerPort() {
        let peerId = "route-no-synthesize-\(UUID().uuidString)"
        let oldTransferPort = ServiceEndpointRegistry.shared.snapshot().fileTransferPort
        ServiceEndpointRegistry.shared.setFileTransferPort(49152)
        defer {
            ConnectionPresenceService.shared.markDisconnected(peerId: peerId)
            ServiceEndpointRegistry.shared.setFileTransferPort(oldTransferPort)
        }

        ConnectionPresenceService.shared.markConnected(
            peerId: peerId,
            displayName: "iPad",
            address: "10.0.0.9",
            cryptoKind: "Apple PQC",
            suite: "X-Wing"
        )

        XCTAssertTrue(ConnectionPresenceService.shared.activeConnections.contains(where: { $0.id == peerId }))
        XCTAssertNil(ConnectionPresenceService.shared.routeDescriptorsByPeerId[peerId])
    }

    func testPresenceCanonicalizesAliasUpdatesAndDisconnectsAcrossPeerIdentifiers() {
        let stablePeerId = "id:\(UUID().uuidString.lowercased())"
        let rawPeerId = String(stablePeerId.dropFirst(3))
        defer { ConnectionPresenceService.shared.markDisconnected(peerId: stablePeerId) }

        ConnectionPresenceService.shared.markConnected(
            peerId: stablePeerId,
            displayName: "Mac mini",
            address: "10.0.0.9",
            cryptoKind: "Apple PQC",
            suite: "ML-KEM-768"
        )

        ConnectionPresenceService.shared.markConnected(
            peerId: rawPeerId,
            displayName: "Mac mini",
            address: "10.0.0.9",
            cryptoKind: "Apple PQC",
            suite: "ML-KEM-768"
        )

        XCTAssertEqual(ConnectionPresenceService.shared.activeConnections.count, 1)
        XCTAssertEqual(ConnectionPresenceService.shared.activeConnections.first?.id, stablePeerId)

        ConnectionPresenceService.shared.markDisconnected(peerId: rawPeerId)

        XCTAssertTrue(ConnectionPresenceService.shared.activeConnections.isEmpty)
        XCTAssertTrue(ConnectionPresenceService.shared.routeDescriptorsByPeerId.isEmpty)
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
        XCTAssertEqual(resolved.transferPort, -1)
    }
}
