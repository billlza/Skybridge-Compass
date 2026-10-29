import XCTest
@testable import SkyBridgeCore

@MainActor
final class PresenceRouteContractTests: XCTestCase {
    func testUSBPresenceNeverAdoptsANetworkAddressOrFileListenerFromDiscovery() {
        let peer = UUID().uuidString
        let discovered = P2PDiscoveryService.InboundPresenceResolution(
            name: "Discovered iPad", displayAddress: "192.0.2.14", transferPort: 8080)
        for cable in ["usb:physical-apple-device", "usb-android:physical-attachment"] {
            let projection = P2PConnection.outboundPresenceProjection(peerId: peer, displayName: "USB peer",
                remoteDisplayName: "Current iPad", carrierAddress: cable, controlTransport: .usb,
                discovered: discovered, advertisedTransferPort: 9528, connectedAt: Date())
            XCTAssertEqual(projection.address, cable)
            XCTAssertEqual(projection.displayName, "USB peer")
            XCTAssertNil(projection.fileRoute, "An advertised TCP port is not a file route over this USB carrier")
        }
    }

    func testNetworkPresenceRetainsItsResolvedFileRouteAndAuthenticatedDisplayName() throws {
        let peer = UUID().uuidString, now = Date()
        let discovered = P2PDiscoveryService.InboundPresenceResolution(
            name: "Discovered iPad", displayAddress: "192.0.2.14", transferPort: 8080)
        let projection = P2PConnection.outboundPresenceProjection(peerId: peer, displayName: "Fallback peer",
            remoteDisplayName: "Current iPad", carrierAddress: "peer.local", controlTransport: .network,
            discovered: discovered, advertisedTransferPort: 9528, connectedAt: now)
        let route = try XCTUnwrap(projection.fileRoute)
        XCTAssertEqual(projection.address, "192.0.2.14")
        XCTAssertEqual(projection.displayName, "Current iPad")
        XCTAssertEqual(route.transferPort, 9528)
        XCTAssertEqual(route.routeSource, .outbound)
        XCTAssertEqual(route.connectedAt, now)
    }

    func testOneSocketMigratesEndpointPresenceToValidatedDeviceIdentity() throws {
        let service = ConnectionPresenceService.shared
        let endpoint = "peer:192.0.2.18:\(UUID().uuidString)"
        let peer = UUID().uuidString
        let provisional = try XCTUnwrap(service.markConnectedOwned(peerId: endpoint,
            displayName: "P2P Peer", cryptoKind: "PQC", suite: "test", controlTransport: .network))
        let current = try XCTUnwrap(service.markConnectedOwned(peerId: peer,
            displayName: "Phone", cryptoKind: "PQC", suite: "test", controlTransport: .network,
            replacing: provisional))
        defer { _ = service.disconnectIfOwned(current); _ = service.disconnectIfOwned(provisional) }
        XCTAssertNil(service.activeConnection(forPeerId: endpoint))
        XCTAssertNotNil(service.activeConnection(forPeerId: peer))
        XCTAssertFalse(service.disconnectIfOwned(provisional))
        let refreshed = try XCTUnwrap(service.markConnectedOwned(peerId: peer,
            displayName: "Phone", cryptoKind: "PQC", suite: "test", controlTransport: .network,
            replacing: current))
        XCTAssertEqual(refreshed, current, "Heartbeat must preserve exact socket ownership")
        XCTAssertTrue(service.disconnectIfOwned(refreshed))
        XCTAssertNil(service.activeConnection(forPeerId: peer))
        XCTAssertNil(service.activeConnection(forPeerId: endpoint))
    }

    func testLateEndpointIdentityCannotStealReplacementSocketPresence() throws {
        let service = ConnectionPresenceService.shared
        let endpoint = "peer:192.0.2.19:\(UUID().uuidString)"
        let peer = UUID().uuidString
        let old = try XCTUnwrap(service.markConnectedOwned(peerId: endpoint,
            displayName: "Old endpoint", cryptoKind: "PQC", suite: "test"))
        let current = try XCTUnwrap(service.markConnectedOwned(peerId: peer,
            displayName: "Replacement phone", cryptoKind: "PQC", suite: "test"))
        defer { _ = service.disconnectIfOwned(current); _ = service.disconnectIfOwned(old) }
        XCTAssertNil(service.markConnectedOwned(peerId: peer, displayName: "Late old phone",
            cryptoKind: "PQC", suite: "test", replacing: old))
        XCTAssertEqual(service.activeConnection(forPeerId: peer)?.displayName, "Replacement phone")
        XCTAssertTrue(service.disconnectIfOwned(old))
        XCTAssertNotNil(service.activeConnection(forPeerId: peer))
        XCTAssertNil(service.markConnectedOwned(peerId: peer, displayName: "Already retired",
            cryptoKind: "PQC", suite: "test", replacing: old))
    }

    func testCurrentControlTransportSurvivesAliasRefreshAndRejectsOldOwner() throws {
        let service = ConnectionPresenceService.shared
        let rawID = UUID().uuidString
        let canonicalID = "id:" + rawID.lowercased()
        let route = ConnectionPresenceService.PresenceRouteDescriptor(peerId: rawID,
            deviceName: "Same peer", displayAddress: "192.0.2.1", transferAddress: "192.0.2.1",
            transferPort: 9528, routeSource: .outbound)
        let old = try XCTUnwrap(service.markConnectedOwned(peerId: rawID, displayName: "Same peer",
            cryptoKind: "PQC", suite: "test", routeDescriptor: route, controlTransport: .network))
        let beforeUSB = ConnectionRouteAttributionRecorder.shared.conclusiveSampleCount
        let current = try XCTUnwrap(service.markConnectedOwned(peerId: canonicalID, displayName: "Same peer",
            cryptoKind: "PQC", suite: "test", controlTransport: .usb))
        defer { _ = service.disconnectIfOwned(current); _ = service.disconnectIfOwned(old) }
        XCTAssertEqual(service.activeConnection(forPeerId: rawID)?.controlTransport, .usb)
        XCTAssertEqual(service.activeConnection(forPeerId: canonicalID)?.controlTransport, .usb)
        XCTAssertNil(service.routeDescriptorsByPeerId[canonicalID], "USB without a network file route cannot inherit an old address")
        XCTAssertEqual(ConnectionRouteAttributionRecorder.shared.attributionsBySessionKey[canonicalID]?.route, .usbDirect)
        XCTAssertEqual(ConnectionRouteAttributionRecorder.shared.conclusiveSampleCount, beforeUSB)

        XCTAssertFalse(service.refreshConnectedIfOwned(old, displayName: "Old network owner",
            cryptoKind: "PQC", suite: "test", routeDescriptor: route, controlTransport: .network))
        XCTAssertFalse(service.disconnectIfOwned(old))
        XCTAssertEqual(service.activeConnection(forPeerId: rawID)?.controlTransport, .usb)
        XCTAssertTrue(service.refreshConnectedIfOwned(current, displayName: "Current USB owner",
            cryptoKind: "PQC", suite: "test", controlTransport: .usb))
        XCTAssertEqual(service.activeConnection(forPeerId: rawID)?.controlTransport, .usb)
        XCTAssertTrue(service.disconnectIfOwned(current))
        XCTAssertNil(service.activeConnection(forPeerId: rawID))
        XCTAssertNil(ConnectionRouteAttributionRecorder.shared.attributionsBySessionKey[canonicalID])
    }

    func testDisplayLookupNeverMatchesAnotherPeersNameOrAddress() throws {
        let service = ConnectionPresenceService.shared
        let peer = UUID().uuidString
        let lease = try XCTUnwrap(service.markConnectedOwned(peerId: peer, displayName: "Shared device name",
            address: "192.0.2.20", cryptoKind: "PQC", suite: "test", controlTransport: .usb))
        defer { _ = service.disconnectIfOwned(lease) }
        XCTAssertNotNil(service.activeConnection(forPeerId: "id:" + peer.lowercased()))
        XCTAssertNil(service.activeConnection(forPeerId: "Shared device name"))
        XCTAssertNil(service.activeConnection(forPeerId: "192.0.2.20"))
        XCTAssertNil(service.activeConnection(forPeerId: UUID().uuidString))
        XCTAssertNil(service.activeConnection(forPeerId: ""))
    }

    func testUnknownReplacementTransportDoesNotInheritUSBAttribution() throws {
        let service = ConnectionPresenceService.shared
        let peer = UUID().uuidString
        let usb = try XCTUnwrap(service.markConnectedOwned(peerId: peer, displayName: "USB peer",
            cryptoKind: "PQC", suite: "test", controlTransport: .usb))
        let unknown = try XCTUnwrap(service.markConnectedOwned(peerId: peer, displayName: "Replacement peer",
            cryptoKind: "PQC", suite: "test"))
        defer { _ = service.disconnectIfOwned(unknown); _ = service.disconnectIfOwned(usb) }
        XCTAssertNil(service.activeConnection(forPeerId: peer)?.controlTransport)
        XCTAssertNil(ConnectionRouteAttributionRecorder.shared.attributionsBySessionKey[unknown.peerId])
    }

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

    func testDelayedOldOwnerAndLegacyDisconnectCannotRemoveReplacementPresence() {
        let stablePeerId = "id:\(UUID().uuidString.lowercased())"
        let rawPeerId = String(stablePeerId.dropFirst(3))
        let oldRoute = ConnectionPresenceService.PresenceRouteDescriptor(
            peerId: stablePeerId,
            deviceName: "Old iPad",
            displayAddress: "10.0.0.8",
            transferAddress: "10.0.0.8",
            transferPort: 9528,
            routeSource: .inbound
        )
        let replacementRoute = ConnectionPresenceService.PresenceRouteDescriptor(
            peerId: rawPeerId,
            deviceName: "Replacement iPad",
            displayAddress: "10.0.0.9",
            transferAddress: "10.0.0.9",
            transferPort: 9529,
            routeSource: .inbound
        )

        guard let oldLease = ConnectionPresenceService.shared.publishConnectedOwnedAtomically(
            peerId: stablePeerId,
            displayName: "Old iPad",
            address: "10.0.0.8",
            cryptoKind: "Classic",
            suite: "X25519",
            routeDescriptor: oldRoute
        ), let replacementLease = ConnectionPresenceService.shared.publishConnectedOwnedAtomically(
            peerId: rawPeerId,
            displayName: "Replacement iPad",
            address: "10.0.0.9",
            cryptoKind: "Apple PQC",
            suite: "ML-KEM-768",
            routeDescriptor: replacementRoute
        ) else {
            XCTFail("Complete routes must publish owner leases")
            return
        }
        defer {
            _ = ConnectionPresenceService.shared.disconnectIfOwned(oldLease)
            _ = ConnectionPresenceService.shared.disconnectIfOwned(replacementLease)
        }

        XCTAssertFalse(ConnectionPresenceService.shared.disconnectIfOwned(oldLease))
        ConnectionPresenceService.shared.markDisconnected(peerId: rawPeerId)

        XCTAssertEqual(
            ConnectionPresenceService.shared.routeDescriptorsByPeerId[stablePeerId]?.transferAddress,
            "10.0.0.9"
        )
        XCTAssertEqual(
            ConnectionPresenceService.shared.activeConnections.first(where: { $0.id == stablePeerId })?.displayName,
            "Replacement iPad"
        )
        XCTAssertTrue(ConnectionPresenceService.shared.disconnectIfOwned(replacementLease))
        XCTAssertNil(ConnectionPresenceService.shared.routeDescriptorsByPeerId[stablePeerId])
    }

    func testResolveInboundPresenceRouteUsesStableDeviceIdPlusEndpointAddress() {
        let deviceId = UUID().uuidString.lowercased()
        let discovered = DiscoveredDevice(
            id: UUID(),
            name: "MacBook Pro",
            ipv4: "192.168.31.20",
            ipv6: nil,
            services: ["_skybridge._tcp", BonjourInteropContract.fileTransferServiceType],
            portMap: [BonjourInteropContract.fileTransferServiceType: 9528],
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

    func testAuthenticatedMobilePresenceDoesNotRequireAnInventedFileListener() throws {
        let peer = UUID().uuidString.lowercased()
        let resolved = P2PDiscoveryService.resolveInboundPresenceRoute(
            peerId: "id:" + peer, endpointLabel: "peer:10.0.0.42",
            discoveredDevices: [], unifiedDevices: [])
        let route = resolved.transferRouteDescriptor(peerId: peer, advertisedPort: nil, connectedAt: Date())
        XCTAssertNil(route, "An inbound MAIN is not a file-server address")
        let service = ConnectionPresenceService.shared
        let lease = try XCTUnwrap(service.markConnectedOwned(peerId: peer, displayName: "Android phone",
            address: resolved.displayAddress, cryptoKind: "PQC", suite: "test", routeDescriptor: route))
        defer { _ = service.disconnectIfOwned(lease) }
        XCTAssertNotNil(service.activeConnection(forPeerId: peer))
        XCTAssertNil(service.routeDescriptorsByPeerId[lease.peerId])
        XCTAssertTrue(service.disconnectIfOwned(lease))
        XCTAssertNil(service.activeConnection(forPeerId: peer))
    }

    func testOnlyAnAdvertisedOrResolvedFilePortCreatesTheOptionalFileRoute() throws {
        let resolution = P2PDiscoveryService.InboundPresenceResolution(
            name: "Android phone", displayAddress: "10.0.0.42", transferPort: -1)
        let now = Date()
        XCTAssertNil(resolution.transferRouteDescriptor(peerId: "phone", advertisedPort: 0, connectedAt: now))
        let route = try XCTUnwrap(resolution.transferRouteDescriptor(peerId: "phone", advertisedPort: 8080, connectedAt: now))
        XCTAssertEqual(route.transferPort, 8080)
        XCTAssertEqual(route.transferAddress, "10.0.0.42")
        XCTAssertEqual(route.connectedAt, now)
        let absentAddress = P2PDiscoveryService.InboundPresenceResolution(name: "phone", displayAddress: nil, transferPort: 8080)
        XCTAssertNil(absentAddress.transferRouteDescriptor(peerId: "phone", advertisedPort: 8080, connectedAt: now))
    }

    func testResolveInboundPresenceRouteDoesNotUseIdentifierAsFallbackName() {
        let peerId = "id:\(UUID().uuidString.lowercased())"
        let resolved = P2PDiscoveryService.resolveInboundPresenceRoute(
            peerId: peerId,
            endpointLabel: "peer:10.0.0.42",
            discoveredDevices: [],
            unifiedDevices: []
        )

        XCTAssertEqual(resolved.name, "P2P Peer")
        XCTAssertEqual(resolved.displayAddress, "10.0.0.42")
        XCTAssertEqual(resolved.transferPort, -1)
    }
}
