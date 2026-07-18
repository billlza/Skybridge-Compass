import XCTest
@testable import SkyBridgeCore

@MainActor
final class FileTransferRouteResolutionTests: XCTestCase {
    func testResolveActivePeerRoutesPrefersPublishedPresenceRouteDescriptor() async throws {
        let manager = FileTransferManager()
        let peerId = "route-priority-\(UUID().uuidString)"
        defer { ConnectionPresenceService.shared.markDisconnected(peerId: peerId) }

        ConnectionPresenceService.shared.markConnected(
            peerId: peerId,
            displayName: "Compatibility Peer",
            address: "10.0.0.9",
            cryptoKind: "Classic",
            suite: "X25519"
        )

        let preferredRoute = ConnectionPresenceService.PresenceRouteDescriptor(
            peerId: peerId,
            deviceName: "Precise Peer",
            displayAddress: "10.0.0.9",
            transferAddress: "10.0.0.42",
            transferPort: 9443,
            routeSource: .inbound
        )
        _ = ConnectionPresenceService.shared.publishConnectedAtomically(
            peerId: peerId,
            displayName: "Precise Peer",
            address: "10.0.0.9",
            cryptoKind: "Classic",
            suite: "X25519",
            routeDescriptor: preferredRoute
        )

        let routes = await manager.resolveActivePeerRoutes()
        let selected = try XCTUnwrap(routes.first(where: { $0.deviceId == peerId }))

        XCTAssertEqual(selected.ipAddress, "10.0.0.42")
        XCTAssertEqual(selected.port, 9443)
        XCTAssertEqual(selected.routeSource, "presence:inbound")
    }

    func testResolveActivePeerRoutesFailsClosedWithoutExplicitTransferPort() async throws {
        let manager = FileTransferManager()
        let peerId = "route-missing-\(UUID().uuidString)"
        defer { ConnectionPresenceService.shared.markDisconnected(peerId: peerId) }
        ServiceEndpointRegistry.shared.setFileTransferPort(nil)

        ConnectionPresenceService.shared.markConnected(
            peerId: peerId,
            displayName: "Compatibility Peer",
            address: "10.0.0.9",
            cryptoKind: "Classic",
            suite: "X25519"
        )

        let routes = await manager.resolveActivePeerRoutes()
        XCTAssertFalse(routes.contains(where: { $0.deviceId == peerId }))
    }

    func testResolveActivePeerRoutesDoesNotUseLocalListenerPortAsRemoteRoute() async throws {
        let manager = FileTransferManager()
        let peerId = "route-local-port-\(UUID().uuidString)"
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

        let routes = await manager.resolveActivePeerRoutes()
        XCTAssertFalse(routes.contains(where: { $0.deviceId == peerId }))
    }

    func testResolveActivePeerRoutesCanBindToTargetPeerWhenEndpointIsReused() async throws {
        let manager = FileTransferManager()
        let oldPeerId = "route-old-\(UUID().uuidString)"
        let targetPeerId = "route-target-\(UUID().uuidString)"
        defer {
            ConnectionPresenceService.shared.markDisconnected(peerId: oldPeerId)
            ConnectionPresenceService.shared.markDisconnected(peerId: targetPeerId)
        }

        _ = ConnectionPresenceService.shared.publishConnectedAtomically(
            peerId: oldPeerId,
            displayName: "Old iPhone",
            address: "10.0.0.42",
            cryptoKind: "Apple PQC",
            suite: "X-Wing",
            routeDescriptor: .init(
                peerId: oldPeerId,
                deviceName: "Old iPhone",
                displayAddress: "10.0.0.42",
                transferAddress: "10.0.0.42",
                transferPort: 8080,
                routeSource: .inbound,
                connectedAt: Date().addingTimeInterval(-30)
            )
        )
        _ = ConnectionPresenceService.shared.publishConnectedAtomically(
            peerId: targetPeerId,
            displayName: "Fresh iPhone",
            address: "10.0.0.42",
            cryptoKind: "Apple PQC",
            suite: "X-Wing",
            routeDescriptor: .init(
                peerId: targetPeerId,
                deviceName: "Fresh iPhone",
                displayAddress: "10.0.0.42",
                transferAddress: "10.0.0.42",
                transferPort: 8080,
                routeSource: .inbound
            )
        )

        let allRoutes = await manager.resolveActivePeerRoutes()
        XCTAssertTrue(allRoutes.contains(where: { $0.deviceId == oldPeerId }))
        XCTAssertTrue(allRoutes.contains(where: { $0.deviceId == targetPeerId }))

        let targetRoutes = await manager.resolveActivePeerRoutes(matchingPeerIds: [targetPeerId])
        XCTAssertFalse(targetRoutes.isEmpty)
        XCTAssertTrue(targetRoutes.allSatisfy { $0.deviceId == targetPeerId })
    }

    func testResolveActivePeerRoutesDoesNotMatchSameNameWhenTargetIdDiffers() async throws {
        let manager = FileTransferManager()
        let oldPeerId = "route-old-\(UUID().uuidString)"
        let targetPeerId = "route-target-\(UUID().uuidString)"
        let sharedName = "Ziang iPhone"
        defer {
            ConnectionPresenceService.shared.markDisconnected(peerId: oldPeerId)
            ConnectionPresenceService.shared.markDisconnected(peerId: targetPeerId)
        }

        _ = ConnectionPresenceService.shared.publishConnectedAtomically(
            peerId: oldPeerId,
            displayName: sharedName,
            address: "10.0.0.42",
            cryptoKind: "Apple PQC",
            suite: "X-Wing",
            routeDescriptor: .init(
                peerId: oldPeerId,
                deviceName: sharedName,
                displayAddress: "10.0.0.42",
                transferAddress: "10.0.0.42",
                transferPort: 8080,
                routeSource: .inbound,
                connectedAt: Date().addingTimeInterval(-30)
            )
        )
        _ = ConnectionPresenceService.shared.publishConnectedAtomically(
            peerId: targetPeerId,
            displayName: sharedName,
            address: "10.0.0.43",
            cryptoKind: "Apple PQC",
            suite: "X-Wing",
            routeDescriptor: .init(
                peerId: targetPeerId,
                deviceName: sharedName,
                displayAddress: "10.0.0.43",
                transferAddress: "10.0.0.43",
                transferPort: 8080,
                routeSource: .inbound
            )
        )

        let targetRoutes = await manager.resolveActivePeerRoutes(
            matchingPeerIds: [targetPeerId],
            preferredDeviceName: sharedName
        )

        XCTAssertEqual(targetRoutes.map(\.deviceId), [targetPeerId])
    }

    func testResolveActivePeerRoutesFailsClosedWhenReconnectAliasMissesEvenIfNameMatches() async throws {
        let manager = FileTransferManager()
        let authenticatedPeerId = "31BB9D78-11F6-4843-91EE-0A0C4C003632"
        let reconnectBonjourAlias = "bonjour:iPhone-\(UUID().uuidString)@local."
        let preferredName = "Reconnect iPhone \(UUID().uuidString.prefix(8))"
        defer {
            ConnectionPresenceService.shared.markDisconnected(peerId: authenticatedPeerId)
        }

        _ = ConnectionPresenceService.shared.publishConnectedAtomically(
            peerId: authenticatedPeerId,
            displayName: preferredName,
            address: "10.0.0.44",
            cryptoKind: "Apple PQC",
            suite: "X-Wing",
            routeDescriptor: .init(
                peerId: authenticatedPeerId,
                deviceName: preferredName,
                displayAddress: "10.0.0.44",
                transferAddress: "10.0.0.44",
                transferPort: 8080,
                routeSource: .outbound
            )
        )

        let routes = await manager.resolveActivePeerRoutes(
            matchingPeerIds: [reconnectBonjourAlias],
            preferredDeviceName: preferredName
        )

        XCTAssertTrue(routes.isEmpty)
    }

    func testActivePeerRoutesPreferAuthenticatedSessionOverInboundPresenceForReconnect() {
        let stalePresence = FileTransferManager.ActivePeerRoute(
            deviceId: "id:31bb9d78-11f6-4843-91ee-0a0c4c003632",
            deviceName: "iPhone",
            ipAddress: "fe80::bc:dca9:7759:5a45%en0",
            port: 8080,
            routeSource: "presence:inbound"
        )
        let freshAuthenticated = FileTransferManager.ActivePeerRoute(
            deviceId: "bonjour:iPhone@local.",
            deviceName: "iPhone",
            ipAddress: "fe80::bc:dca9:7759:5a45%en0",
            port: 8080,
            routeSource: "authenticated-session"
        )

        let sorted = FileTransferManager.sortedActivePeerRoutes([stalePresence, freshAuthenticated])

        XCTAssertEqual(sorted.first?.routeSource, "authenticated-session")
        XCTAssertEqual(sorted.first?.deviceId, "bonjour:iPhone@local.")
    }

    func testPeerHostTokenNormalizerPreservesLinkLocalIPv6Zone() {
        // 链路本地 IPv6 (fe80::/10) 必须保留 %zone 作用域 id，否则地址不可路由，
        // 入站文件传输到 fe80::…%en0 会连接失败（修复 #6 的回归保护）。
        XCTAssertEqual(
            P2PPeerHostTokenNormalizer.normalize("fe80::bc:dca9:7759:5a45%en0"),
            "fe80::bc:dca9:7759:5a45%en0"
        )
        // 带方括号包裹时同样保留作用域。
        XCTAssertEqual(
            P2PPeerHostTokenNormalizer.normalize("[fe80::1%en0]"),
            "fe80::1%en0"
        )
        // 大写 FE80 前缀也应识别为链路本地。
        XCTAssertEqual(
            P2PPeerHostTokenNormalizer.normalize("FE80::1%en5"),
            "fe80::1%en5"
        )
        // 非链路本地 IPv6 的 '%' 不承载连接作用域，应被剥离。
        XCTAssertEqual(
            P2PPeerHostTokenNormalizer.normalize("2001:db8::1%eth0"),
            "2001:db8::1"
        )
        // IPv4 不受影响。
        XCTAssertEqual(
            P2PPeerHostTokenNormalizer.normalize("192.168.0.106"),
            "192.168.0.106"
        )
    }

    func testRecentAuthenticatedInboundTransferRouteBeatsStaleClassicRegistry() {
        let staleRegistry = FileTransferManager.ActivePeerRoute(
            deviceId: "id:31bb9d78-11f6-4843-91ee-0a0c4c003632",
            deviceName: "iPad",
            ipAddress: "192.168.0.102",
            port: 8080,
            routeSource: "classic-session-registry"
        )
        let recentInbound = FileTransferManager.ActivePeerRoute(
            deviceId: staleRegistry.deviceId,
            deviceName: "iPad",
            ipAddress: "192.168.0.106",
            port: 8080,
            routeSource: "recent-authenticated-inbound-transfer"
        )

        let sorted = FileTransferManager.sortedActivePeerRoutes([staleRegistry, recentInbound])

        XCTAssertEqual(sorted.first?.routeSource, "recent-authenticated-inbound-transfer")
        XCTAssertEqual(sorted.first?.ipAddress, "192.168.0.106")
    }

    func testActivePeerRouteDedupeKeepsAuthenticatedSourceForSameEndpoint() {
        let stalePresence = FileTransferManager.ActivePeerRoute(
            deviceId: "id:31bb9d78-11f6-4843-91ee-0a0c4c003632",
            deviceName: "iPhone",
            ipAddress: "fe80::bc:dca9:7759:5a45%en0",
            port: 8080,
            routeSource: "presence:inbound"
        )
        let freshAuthenticated = FileTransferManager.ActivePeerRoute(
            deviceId: stalePresence.deviceId,
            deviceName: "iPhone",
            ipAddress: stalePresence.ipAddress,
            port: stalePresence.port,
            routeSource: "authenticated-session"
        )

        let deduped = FileTransferManager.deduplicatedActivePeerRoutes([
            stalePresence,
            freshAuthenticated
        ])

        XCTAssertEqual(deduped.count, 1)
        XCTAssertEqual(deduped.first?.routeSource, "authenticated-session")
    }

    func testMacReconnectSmokeWaitsForNonInboundPresenceRouteBeforeFailing() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/SkyBridgeCompassApp/LocalP2PFileTransferSmokeHarness.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("disallowedRouteSource: \"presence:inbound\""))
        XCTAssertTrue(source.contains("timeoutSeconds: 15.0"))
        XCTAssertTrue(source.contains("var lastDisallowedRoute: FileTransferManager.ActivePeerRoute?"))
        XCTAssertTrue(source.contains("route.routeSource == disallowedRouteSource"))
        XCTAssertTrue(source.contains("return lastDisallowedRoute"))
        XCTAssertTrue(source.contains("mac_smoke_stale_inbound_presence_route"))
    }

    func testMacReconnectSmokeUsesStrongTransferBonjourRouteWhenControlRediscoveryIsUnavailable() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/SkyBridgeCompassApp/LocalP2PFileTransferSmokeHarness.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("mac-reconnect control-discovery-timeout"))
        XCTAssertTrue(source.contains("mac-reconnect control-connect-unavailable"))
        XCTAssertTrue(source.contains("mac-reconnect already-connected"))
        XCTAssertTrue(source.contains("action=wait-remote-cleanup"))
        XCTAssertTrue(source.contains("connectToDeviceForMacReconnect"))
        XCTAssertTrue(source.contains("let maxAttempts = 6"))
        XCTAssertTrue(source.contains("isAlreadyConnectedHandshakeRejection"))
        XCTAssertTrue(source.contains("case .failed(.peerRejected(let message))"))
        XCTAssertTrue(source.contains("== \"already_connected\""))
        XCTAssertTrue(source.contains("shouldFallbackToTransferRouteAfterControlReconnectFailure"))
        XCTAssertTrue(source.contains("case .noConnectableEndpoint"))
        XCTAssertTrue(source.contains("macInitiatedTransfer=1"))
        XCTAssertTrue(source.contains("macReconnectControl="))
        XCTAssertTrue(source.contains("macReconnectRoute="))
        XCTAssertTrue(source.contains("performMacInitiatedTransferRouteReconnect"))
        XCTAssertTrue(source.contains("guard let stablePeerDeviceId = Self.stableBonjourTargetDeviceId(peer.deviceId)"))
        XCTAssertTrue(source.contains("targetDeviceId: stablePeerDeviceId"))
        XCTAssertTrue(source.contains("preferredName: nil"))
        XCTAssertTrue(source.contains("mac-reconnect transfer-route-target source=bonjour-transfer"))
        XCTAssertTrue(source.contains("fileTransferManager.sendFile("))
        XCTAssertTrue(source.contains("to: peer.deviceId"))
        XCTAssertTrue(source.contains("ipAddress: transferRoute.host"))
        XCTAssertTrue(source.contains("mac_smoke_reconnect_control_endpoint_missing"))
        XCTAssertTrue(source.contains("mac_smoke_reconnect_stable_identity_missing"))
        XCTAssertTrue(source.contains("mac_smoke_reconnect_transfer_route_timeout"))
    }

    func testP2PDiscoveryDisconnectTracksInboundControlSessions() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("private var inboundControlSessions"))
        XCTAssertTrue(source.contains("upsertInboundControlSession"))
        XCTAssertTrue(source.contains("removeInboundControlSession"))
        XCTAssertTrue(source.contains("refreshInboundControlSessionAliases"))
        XCTAssertTrue(source.contains("let inboundSessionsToDisconnect = inboundControlSessions.filter"))
        XCTAssertTrue(source.contains("session.connection.cancel()"))
        XCTAssertTrue(source.contains("self?.removeInboundControlSession(id: inboundControlSessionId)"))
    }

    func testInboundPresenceResolverPrefersRouteCompleteTransferCandidate() throws {
        let peerId = "id:11111111-1111-4111-8111-111111111111"
        let identityOnly = DiscoveredDevice(
            id: UUID(),
            name: "Lza iPhone",
            ipv4: "10.0.0.42",
            ipv6: nil,
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 50873],
            connectionTypes: [.wifi],
            uniqueIdentifier: peerId,
            source: .skybridgeBonjour,
            deviceId: "11111111-1111-4111-8111-111111111111"
        )
        let transferCapable = DiscoveredDevice(
            id: UUID(),
            name: "Lza iPhone",
            ipv4: "10.0.0.42",
            ipv6: nil,
            services: ["_skybridge-transfer._tcp"],
            portMap: ["_skybridge-transfer._tcp": 8080],
            connectionTypes: [.wifi],
            uniqueIdentifier: "bonjour:Lza iPhone@local.",
            source: .skybridgeBonjour
        )

        let route = P2PDiscoveryService.resolveInboundPresenceRoute(
            peerId: peerId,
            endpointLabel: "host:10.0.0.42",
            discoveredDevices: [identityOnly, transferCapable],
            unifiedDevices: []
        )

        XCTAssertEqual(route.displayAddress, "10.0.0.42")
        XCTAssertEqual(route.transferPort, 8080)
    }

    func testInboundPresenceResolverDoesNotSpliceStrongIdentityWithDifferentTransferRecord() throws {
        let peerId = "id:11111111-1111-4111-8111-111111111111"
        let identityOnly = DiscoveredDevice(
            id: UUID(),
            name: "Lza iPhone",
            ipv4: "10.0.0.42",
            ipv6: nil,
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 50873],
            connectionTypes: [.wifi],
            uniqueIdentifier: peerId,
            source: .skybridgeBonjour,
            deviceId: "11111111-1111-4111-8111-111111111111"
        )
        let unrelatedTransferCapable = DiscoveredDevice(
            id: UUID(),
            name: "Other iPad",
            ipv4: "10.0.0.77",
            ipv6: nil,
            services: ["_skybridge-transfer._tcp"],
            portMap: ["_skybridge-transfer._tcp": 8080],
            connectionTypes: [.wifi],
            uniqueIdentifier: "bonjour:Other iPad@local.",
            source: .skybridgeBonjour
        )

        let route = P2PDiscoveryService.resolveInboundPresenceRoute(
            peerId: peerId,
            endpointLabel: "host:10.0.0.77",
            discoveredDevices: [identityOnly, unrelatedTransferCapable],
            unifiedDevices: []
        )

        XCTAssertEqual(route.transferPort, -1)
    }

    func testInboundPresenceResolverTreatsBareUUIDAsStrongIdentity() throws {
        let peerId = "11111111-1111-4111-8111-111111111111"
        let identityOnly = DiscoveredDevice(
            id: UUID(),
            name: "Lza iPhone",
            ipv4: "10.0.0.42",
            ipv6: nil,
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 50873],
            connectionTypes: [.wifi],
            uniqueIdentifier: peerId,
            source: .skybridgeBonjour,
            deviceId: peerId
        )
        let unrelatedTransferCapable = DiscoveredDevice(
            id: UUID(),
            name: "Other iPad",
            ipv4: "10.0.0.77",
            ipv6: nil,
            services: ["_skybridge-transfer._tcp"],
            portMap: ["_skybridge-transfer._tcp": 8080],
            connectionTypes: [.wifi],
            uniqueIdentifier: "bonjour:Other iPad@local.",
            source: .skybridgeBonjour
        )

        let route = P2PDiscoveryService.resolveInboundPresenceRoute(
            peerId: peerId,
            endpointLabel: "host:10.0.0.77",
            discoveredDevices: [identityOnly, unrelatedTransferCapable],
            unifiedDevices: []
        )

        XCTAssertEqual(route.transferPort, -1)
    }

    func testInboundPresenceResolverRejectsNameOnlyMatchForStrongPeerIdentity() throws {
        let unrelatedTransferOnly = DiscoveredDevice(
            id: UUID(),
            name: "iPad",
            ipv4: "10.0.0.77",
            ipv6: nil,
            services: ["_skybridge-transfer._tcp"],
            portMap: ["_skybridge-transfer._tcp": 8080],
            connectionTypes: [.wifi],
            uniqueIdentifier: "bonjour:iPad@local.",
            source: .skybridgeBonjour
        )

        let route = P2PDiscoveryService.resolveInboundPresenceRoute(
            peerId: "id:11111111-1111-4111-8111-111111111111",
            endpointLabel: "bonjour:iPad@local.",
            discoveredDevices: [unrelatedTransferOnly],
            unifiedDevices: []
        )

        XCTAssertEqual(route.name, "iPad")
        XCTAssertNil(route.displayAddress)
        XCTAssertEqual(route.transferPort, -1)
    }

    func testAuthenticatedClassicSessionsCanSupplyRoutesWhenPresenceIsMissing() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/FileTransfer/FileTransferManager.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("activeAuthenticatedConnectionsForClassicTransfer()"))
        XCTAssertTrue(source.contains("ClassicTransferSessionRegistry.shared.activeConnections()"))
        XCTAssertTrue(source.contains("ClassicTransferSessionRegistry.shared.activeSessions()"))
        XCTAssertTrue(source.contains("recent-authenticated-inbound-transfer"))
        XCTAssertTrue(source.contains("transfer.deviceIPAddress = inboundEndpointAddress"))
        XCTAssertTrue(source.contains("advertisedClassicTransferPort"))
        XCTAssertTrue(source.contains("deduplicatedActivePeerRoutes"))
        XCTAssertTrue(source.contains("routeSource: \"authenticated-session\""))
        XCTAssertTrue(source.contains("resolveActivePeerRoutesWithReadinessWait"))
    }

    func testIOSP2PIdentityExchangeAdvertisesFileTransferPortAndClearsProtectionRoots() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("FileTransferConstants.defaultPort"))
        XCTAssertTrue(source.contains("cancelPeerProtectionRoots(for: runtimePeerId)"))
        XCTAssertTrue(source.contains("pathRecoveryTasks[key]?.cancel()"))
        XCTAssertTrue(source.contains("bootstrapRekeyTasks[key]?.cancel()"))
    }

    func testMacInboundPairingIdentityRefreshesFileTransferRoute() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("latestPeerFileTransferPort = payload.fileTransferPort"))
        XCTAssertTrue(source.contains("capabilities.append(\"fileTransferPort=\\(port)\")"))
        XCTAssertTrue(source.contains("await publishInboundClassicTransferSession(keys: keys)"))
        XCTAssertTrue(source.contains("capabilities: provisionalCapabilities"))
        XCTAssertTrue(source.contains("PairingIdentityExchangeCommitCoordinator.isCurrent("))
    }

    func testMacBonjourIdentityBrowsersRequestTXTRecords() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let p2pSource = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift"),
            encoding: .utf8
        )
        let discoverySource = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/DeviceDiscovery/DeviceDiscoveryManager.swift"),
            encoding: .utf8
        )
        let optimizedDiscoverySource = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/DeviceDiscovery/DeviceDiscoveryManagerOptimized.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(p2pSource.contains("NWBrowser.Descriptor.bonjourWithTXTRecord(type: serviceType, domain: serviceDomain)"))
        XCTAssertTrue(discoverySource.contains("NWBrowser.Descriptor.bonjourWithTXTRecord(type: serviceType, domain: serviceDomain)"))
        XCTAssertTrue(optimizedDiscoverySource.contains("NWBrowser.Descriptor.bonjourWithTXTRecord(type: serviceType, domain: serviceDomain)"))
        XCTAssertFalse(
            p2pSource.contains("NWBrowser.Descriptor.bonjour(type: serviceType, domain: serviceDomain)"),
            "P2P discovery parses TXT deviceId/transferPort, so the browser must request TXT metadata."
        )
    }

    func testMacOutboundHandshakePublishesAuthenticatedPresenceBeforePairingIdentity() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/P2P/P2PModels.swift"),
            encoding: .utf8
        )
        let authenticateStart = try XCTUnwrap(source.range(of: "public func authenticate() async throws"))
        let startMetrics = try XCTUnwrap(source.range(of: "startMetricsIfNeeded()", range: authenticateStart.lowerBound..<source.endIndex))
        let authenticateBody = String(source[authenticateStart.lowerBound..<startMetrics.upperBound])
        let publishRange = try XCTUnwrap(authenticateBody.range(of: "await publishAuthenticatedPresence(keys: keys)"))
        let pairingRange = try XCTUnwrap(authenticateBody.range(of: "schedulePostAuthPairingIdentityExchange()"))

        XCTAssertLessThan(publishRange.lowerBound, pairingRange.lowerBound)
        XCTAssertFalse(authenticateBody.contains("await publishClassicTransferSessionSnapshot(keys: keys)"))

        let scheduleStart = try XCTUnwrap(source.range(of: "private func schedulePostAuthPairingIdentityExchange()"))
        let sendWithTimeout = try XCTUnwrap(
            source.range(
                of: "private func sendPostAuthPairingIdentityExchangeWithTimeout",
                range: scheduleStart.lowerBound..<source.endIndex
            )
        )
        let scheduledPath = String(source[scheduleStart.lowerBound..<sendWithTimeout.upperBound])
        XCTAssertTrue(scheduledPath.contains("sendPostAuthPairingIdentityExchangeWithTimeout()"))
        let scheduledSend = try XCTUnwrap(
            source.range(
                of: "sendPairingIdentityExchange(force: true)",
                range: sendWithTimeout.lowerBound..<source.endIndex
            )
        )
        XCTAssertLessThan(sendWithTimeout.lowerBound, scheduledSend.lowerBound)
    }

    func testMacInboundKeepsControlSessionUntilRouteMetadataArrives() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("refreshInboundRouteFromHeartbeat"))
        XCTAssertTrue(source.contains("waiting for pairing identity or heartbeat metadata"))
        XCTAssertFalse(
            source.contains("guard published else { break }"),
            "Inbound control sessions must not be dropped before pairing identity or heartbeat can advertise the file-transfer port."
        )
    }

    func testMacInboundSendsPostAuthPairingIdentityBridgeWhenSessionEstablishes() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift"),
            encoding: .utf8
        )
        let establishedStart = try XCTUnwrap(source.range(of: "case .established(let keys):"))
        let establishedEnd = try XCTUnwrap(
            source.range(of: "default:", range: establishedStart.lowerBound..<source.endIndex)
        )
        let establishedBody = String(source[establishedStart.lowerBound..<establishedEnd.lowerBound])
        let postAuthSendRange = try XCTUnwrap(
            establishedBody.range(of: "sendInboundPostAuthPairingIdentityExchange(keys: keys)")
        )
        let publishRange = try XCTUnwrap(establishedBody.range(of: "await publishInboundClassicTransferSession(keys: keys)"))

        XCTAssertTrue(source.contains("var didSendPostAuthPairingIdentityExchange = false"))
        XCTAssertTrue(source.contains("inbound post-auth pairingIdentityExchange sent"))
        XCTAssertTrue(source.contains("inbound post-auth pairingIdentityExchange fail-fast"))
        XCTAssertTrue(source.contains("inbound_post_auth_pairing_identity_unavailable"))
        XCTAssertTrue(source.contains("fileTransferPort: endpoints.fileTransferPort"))
        XCTAssertTrue(source.contains("remoteControlPort: endpoints.remoteControlPort"))
        XCTAssertLessThan(postAuthSendRange.lowerBound, publishRange.lowerBound)
    }

    func testIOSClassicFileTransferRequiresPairingIdentityBridgeConfirmation() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/FileTransferManager.swift"),
            encoding: .utf8
        )
        let p2pSource = try String(
            contentsOf: root.appendingPathComponent("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("ensureClassicTransferIdentityBridgeReady(for: resolvedDevice)"))
        XCTAssertTrue(source.contains("connectionManager.sendPairingIdentityExchange(to: device.id)"))
        XCTAssertTrue(source.contains("waitForPairingIdentityExchangeActivity"))
        XCTAssertTrue(p2pSource.contains("pairingIdentityObservationAliases(for: deviceId)"))
        XCTAssertTrue(source.contains("P2P pairing identity exchange 未被对端确认，拒绝启动经典文件传输"))
        XCTAssertTrue(source.contains("stage: \"identity_bridge_send_failed\""))
        XCTAssertTrue(source.contains("stage: \"identity_bridge_not_confirmed\""))
        XCTAssertTrue(source.contains("stage: \"route_resolution_missing_transfer_endpoint\""))
        XCTAssertTrue(source.contains("stage: \"route_resolution_invalid_destination\""))
        XCTAssertTrue(source.contains("stage: \"connect_no_endpoint_candidates\""))
        XCTAssertTrue(source.contains("stage: \"\\(stage)_connection_closed\""))

        let invalidPayloadStart = try XCTUnwrap(
            p2pSource.range(of: "guard let payload = payload.normalizedBootstrapPayload else {")
        )
        let invalidPayloadEnd = try XCTUnwrap(
            p2pSource.range(of: "let declaredDeviceId = payload.deviceId", range: invalidPayloadStart.lowerBound..<p2pSource.endIndex)
        )
        let invalidPayloadBlock = String(p2pSource[invalidPayloadStart.lowerBound..<invalidPayloadEnd.lowerBound])
        XCTAssertFalse(
            invalidPayloadBlock.contains("lastPairingIdentityExchangeReceivedAt"),
            "Malformed pairingIdentityExchange frames must not confirm the classic file-transfer identity bridge."
        )
    }

    func testFileTransferSmokeRejectsUnknownFailurePhaseAndPreservesConcreteIOSPhases() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSource = try [
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/App/SkyBridgeCompassApp.swift",
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/App/Smoke/LocalP2PSmokeHarness.swift",
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/App/Smoke/SmokeSupport.swift",
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/App/Smoke/LocalWebRTCSmokeHarness.swift",
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/App/Smoke/SmokeStatusReporter.swift"
        ].map { path in
            try String(
                contentsOf: root.appendingPathComponent(path),
                encoding: .utf8
            )
        }.joined(separator: "\n")
        let smokeScript = try String(
            contentsOf: root.appendingPathComponent("Scripts/run_real_device_file_transfer_smoke.sh"),
            encoding: .utf8
        )
        let macSmokeHarness = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCompassApp/LocalP2PFileTransferSmokeHarness.swift"),
            encoding: .utf8
        )
        let localLanInteropHost = try String(
            contentsOf: root.appendingPathComponent("Sources/LocalLanInteropHost/main.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(appSource.contains("case .networkStageFailed(let stage, let endpoint, let details):"))
        XCTAssertTrue(appSource.contains("phase: \"route_resolution_invalid_destination\""))
        XCTAssertTrue(appSource.contains("phase: \"connect_failed\""))
        XCTAssertTrue(appSource.contains("phase: \"secure_session_required\""))
        XCTAssertTrue(appSource.contains("phase: \"transfer_failed\""))
        XCTAssertTrue(appSource.contains("category=\\(Self.sanitize(category))"))
        XCTAssertTrue(appSource.contains("fileTransferFailureCategory(forNetworkStage: stage)"))
        XCTAssertTrue(appSource.contains("category: \"discovery\""))
        XCTAssertTrue(appSource.contains("category: \"handshake\""))
        XCTAssertTrue(appSource.contains("category: \"secure_channel\""))
        XCTAssertTrue(appSource.contains("category: \"payload_framing\""))
        XCTAssertTrue(appSource.contains("category: \"auth_policy\""))
        XCTAssertTrue(smokeScript.contains("failed stage=file-transfer phase=unknown"))
        XCTAssertTrue(smokeScript.contains("has_file_transfer_failure_without_phase"))
        XCTAssertTrue(smokeScript.contains("Detected file-transfer missing phase"))
        XCTAssertTrue(smokeScript.contains("Detected file-transfer instrumentation gap"))
        XCTAssertTrue(macSmokeHarness.contains("private static func fileTransferFailureLine(for error: Error) -> String"))
        XCTAssertTrue(macSmokeHarness.contains("phase=\\(sanitizePhase(phase)) category=\\(sanitizePhase(category))"))
        XCTAssertTrue(macSmokeHarness.contains("private static func fileTransferFailureCategory(for error: Error, phase: String) -> String"))
        XCTAssertTrue(macSmokeHarness.contains("return \"discovery\""))
        XCTAssertTrue(macSmokeHarness.contains("return \"handshake\""))
        XCTAssertTrue(macSmokeHarness.contains("return \"secure_channel\""))
        XCTAssertTrue(macSmokeHarness.contains("return \"payload_framing\""))
        XCTAssertTrue(macSmokeHarness.contains("return \"auth_policy\""))
        XCTAssertTrue(macSmokeHarness.contains("case .receiptWaitFailed(let stage, _):"))
        XCTAssertFalse(
            macSmokeHarness.contains("failed stage=file-transfer error=\\(Self.sanitize(error.localizedDescription))"),
            "macOS smoke output must not collapse file-transfer failures into a phase-less network error."
        )
        XCTAssertTrue(localLanInteropHost.contains("private func fileTransferFailureLine(for error: Error) -> String"))
        XCTAssertTrue(localLanInteropHost.contains("phase=\\(sanitizePhase(phase)) category=\\(sanitizePhase(category))"))
        XCTAssertTrue(localLanInteropHost.contains("private func fileTransferFailureCategory(for error: Error, phase: String) -> String"))
        XCTAssertTrue(localLanInteropHost.contains("return \"discovery\""))
        XCTAssertTrue(localLanInteropHost.contains("return \"handshake\""))
        XCTAssertTrue(localLanInteropHost.contains("return \"secure_channel\""))
        XCTAssertTrue(localLanInteropHost.contains("return \"payload_framing\""))
        XCTAssertTrue(localLanInteropHost.contains("return \"auth_policy\""))
        XCTAssertTrue(localLanInteropHost.contains("case .receiptWaitFailed(let stage, _):"))
        XCTAssertFalse(
            localLanInteropHost.contains("failed stage=file-transfer error=\\(sanitize(error.localizedDescription))"),
            "LocalLanInteropHost output must classify real file-transfer failures with phase/category."
        )
    }

    func testMacInboundFileTransferSmokeReportsConcreteReceiveFailurePhase() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let listenerSource = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/FileTransfer/FileTransferListenerService.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(listenerSource.contains("fileTransferFailurePhase(for: error)"))
        XCTAssertTrue(listenerSource.contains("mac_receive_file_integrity_check_failed"))
        XCTAssertTrue(listenerSource.contains("mac_receive_file_secure_session_required"))
        XCTAssertTrue(listenerSource.contains("mac_receive_file_connection_closed"))
        XCTAssertFalse(
            listenerSource.contains("phase=mac_receive_file detail="),
            "Mac inbound failures must expose the concrete receive phase instead of collapsing every failure to mac_receive_file."
        )
    }

    func testPairingIdentityReplyBypassesRateLimitForFirstAcceptedIdentity() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let macSource = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/P2P/P2PModels.swift"),
            encoding: .utf8
        )
        let iOSSource = try String(
            contentsOf: root.appendingPathComponent("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(macSource.contains("let shouldForceIdentityReply = latestRemotePairingIdentityPayloadLock.withLock"))
        XCTAssertTrue(macSource.contains("force: shouldForceIdentityReply"))
        XCTAssertTrue(iOSSource.contains("lastAcceptedPairingIdentityDeviceIdByPeerId"))
        XCTAssertTrue(iOSSource.contains("if !shouldForceIdentityReply,"))
    }

    func testMacInboundPairingIdentityPersistsAuthorityBeforeReply() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift"),
            encoding: .utf8
        )
        let handlerStart = try XCTUnwrap(source.range(of: "case .pairingIdentityExchange(let payload):"))
        let handlerEnd = try XCTUnwrap(source.range(of: "case .ping(let payload):", range: handlerStart.lowerBound..<source.endIndex))
        let handler = String(source[handlerStart.lowerBound..<handlerEnd.lowerBound])
        let commitRange = try XCTUnwrap(handler.range(of: ".commitAuthorityAndKEM("))
        let replyRange = try XCTUnwrap(
            handler.range(
                of: "try await sendFramed(outPadded)",
                range: commitRange.lowerBound..<handler.endIndex
            )
        )

        XCTAssertLessThan(commitRange.lowerBound, replyRange.lowerBound)
        XCTAssertTrue(handler.contains("guard let pairingAuthorityLease = authenticatedRemoteAuthority"))
        XCTAssertTrue(handler.contains("PairingTrustApprovalService.shared.decide(for: request)"))
        XCTAssertTrue(handler.contains("PairingIdentityExchangeCommitCoordinator.isCurrent("))
        XCTAssertTrue(handler.contains("recordRemoteControlSecurityIdentity(from: payload)"))
        XCTAssertTrue(source.contains("Self.localProtocolIdentityPublicKeysForPairing()"))
    }

    func testAuthenticatedPairingIdentityBridgeStillRespectsPersistedRejectPolicy() async throws {
        let service = PairingTrustApprovalService.shared
        let deviceId = "policy-reject-\(UUID().uuidString)"
        let fingerprint = String(repeating: "a", count: 64)
        let bindingKey = try XCTUnwrap(
            PairingTrustApprovalService.policyBindingKey(
                declaredDeviceId: deviceId,
                algorithmRawValue: ProtocolSigningAlgorithm.ed25519.rawValue,
                protocolPublicKeyFingerprint: fingerprint
            )
        )
        let request = PairingTrustApprovalService.Request(
            peerEndpoint: "127.0.0.1:9000",
            declaredDeviceId: deviceId,
            policyBindingKey: bindingKey,
            displayName: "Rejected iPad",
            model: "iPad",
            platform: "iOS",
            osVersion: "18.0",
            kemKeyCount: 2
        )

        try service.clearPolicy(for: deviceId)
        defer { XCTAssertNoThrow(try service.clearPolicy(for: deviceId)) }

        XCTAssertNil(try service.persistedPolicyDecision(for: request))
        let decisionTask = Task { @MainActor in
            try await service.decide(for: request)
        }
        for _ in 0..<100 where service.pendingRequest?.id != request.id {
            await Task.yield()
        }
        XCTAssertEqual(service.pendingRequest?.id, request.id)
        service.resolve(request, decision: .reject)
        let decision = try await decisionTask.value
        XCTAssertEqual(decision, .reject)
        XCTAssertEqual(try service.persistedPolicyDecision(for: request), .reject)
    }

    func testTrustBridgeKeychainInteractionFailureUsesProtectedLocalMirror() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/P2P/TrustSyncService.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("errSecInteractionNotAllowed"))
        XCTAssertTrue(source.contains("protected local trust mirror"))
        XCTAssertTrue(source.contains("path: \"P2PTrust/fallback-records.json\""))
        XCTAssertTrue(source.contains("SecItemUpdate("))
        XCTAssertFalse(source.contains("SecItemDelete(deleteQuery as CFDictionary)"))
        XCTAssertFalse(source.contains("UserDefaults.standard.set(data, forKey: FallbackStorageConstants.recordsKey)"))
    }

    func testMacSmokeOutboundTargetsInboundPeerInsteadOfFirstActivePeer() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCompassApp/LocalP2PFileTransferSmokeHarness.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("sendFileToActivePeer"))
        XCTAssertTrue(source.contains("matchingPeerIds"))
        XCTAssertTrue(source.contains("let stableInboundPeerId = stableBonjourTargetDeviceId(peer.deviceId)"))
        XCTAssertTrue(source.contains("waitForActiveRouteProbe"))
        XCTAssertTrue(source.contains("guard peerAliases.isEmpty else"))
        XCTAssertTrue(source.contains("Mac 重连后的首选文件路由仍是旧 inbound presence"))
        XCTAssertFalse(source.contains("[\n            peer.deviceId,"))
        XCTAssertFalse(source.contains("sendFileToFirstActivePeer(at: outboundURL)"))
    }

    func testP2PReconnectPreservesSuppliedStrongIdentityWhenRefreshingDiscoverySnapshot() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("var refreshed = discoveredDevices[matchIndex]"))
        XCTAssertTrue(source.contains("refreshed.deviceId = suppliedDeviceId"))
        XCTAssertTrue(source.contains("refreshed.pubKeyFP = suppliedFingerprint"))
    }

    func testNetworkFrameParsersUseUnalignedLoadsForLengthHeaders() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let files = [
            "Sources/SkyBridgeCore/P2P/P2PModels.swift",
            "Sources/SkyBridgeCore/FileTransfer/FileTransferManager.swift",
            "Sources/SkyBridgeCore/FileTransfer/FileTransferNetworkService.swift",
            "Sources/SkyBridgeCore/FileTransfer/FileTransferEngine.swift",
            "Sources/SkyBridgeCore/P2P/DiscoveryTransport.swift",
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/Handshake/HandshakeTypes.swift"
        ]

        for file in files {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(
                source.contains("loadUnaligned"),
                "\(file) must parse network byte headers without alignment traps."
            )
        }
    }

    func testFileTransferViewRetainsFailedSelectionsAfterOfflineSendAttempt() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeUI/FileTransfer/FileTransferView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("var failedFiles: [URL] = []"))
        XCTAssertTrue(source.contains("failedFiles.append(fileURL)"))
        XCTAssertTrue(source.contains("let newlyQueuedFiles = selectedFiles.filter"))
        XCTAssertTrue(source.contains("selectedFiles = failedFiles"))
        XCTAssertTrue(source.contains("待发送文件已保留，请重新连接后重试"))
        XCTAssertFalse(
            source.contains("selectedFiles.removeAll()\n        }\n    }\n\n    private func fileIcon"),
            "A failed offline send must not clear the pending file list; otherwise the UI makes the file look sent while nothing was delivered."
        )
    }

    func testP2PReceiveLoopFailureRunsFullDisconnectCleanup() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/P2P/P2PModels.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("P2P receive loop ended; tearing down authenticated session"))
        XCTAssertTrue(
            source.contains("self.disconnect()"),
            "Receive-loop EOF/errors must run the same cleanup as explicit disconnect so presence, unified status, and transfer session registry cannot retain stale routes."
        )
    }

    func testIOSStrictInboundReconnectUsesAuthenticatedEstablishedReplacement() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manager = try String(
            contentsOf: root.appendingPathComponent("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"),
            encoding: .utf8
        )
        let driver = try String(
            contentsOf: root.appendingPathComponent("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/Handshake/HandshakeDriver.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(manager.contains("authenticatedIncomingEstablishedPolicy: strictTrustContext == nil"))
        XCTAssertTrue(manager.contains(": .replaceAuthenticated"))
        XCTAssertTrue(manager.contains("strictInboundStablePeerIdByRuntimePeerId[peerId] = context.stablePeerId"))
        XCTAssertTrue(manager.contains("replaceStrictInboundStableSession("))
        XCTAssertTrue(driver.contains("case acceptAndReplaceEstablished"))
        XCTAssertTrue(driver.contains("establishedPolicy: authenticatedIncomingEstablishedPolicy"))
    }

    func testIOSConnectionStateCleanupIsConnectionAware() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("connection: NWConnection? = nil"))
        XCTAssertTrue(source.contains("if let connection, !isTrackedConnection(connection)"))
        XCTAssertTrue(source.contains("stale-state-ignored"))
        XCTAssertTrue(source.contains("handleConnectionStateChange(state, for: device, connection: connection)"))
        XCTAssertTrue(source.contains("connections.values.contains { $0 === connection }"))
    }

    func testIOSFileTransferInboundMetadataFailuresFailClosed() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/FileTransfer/FileTransferNetworkService.swift"),
            encoding: .utf8
        )

        let receiveStart = try XCTUnwrap(source.range(of: "private func receiveMetadata"))
        let receiveEnd = try XCTUnwrap(
            source.range(of: "private nonisolated func getPeerName", range: receiveStart.lowerBound..<source.endIndex)
        )
        let receiveMetadataBlock = String(source[receiveStart.lowerBound..<receiveEnd.lowerBound])

        XCTAssertTrue(source.contains("private enum InboundInitialMetadataError"))
        XCTAssertTrue(receiveMetadataBlock.contains("decodeInboundInitialMetadataHeader"))
        XCTAssertTrue(receiveMetadataBlock.contains("decodeInboundInitialMetadataPayload"))
        XCTAssertTrue(receiveMetadataBlock.contains("Result<TransferHeader, InboundInitialMetadataError>"))
        XCTAssertTrue(receiveMetadataBlock.contains("Result<FileMetadata, InboundInitialMetadataError>"))
        XCTAssertTrue(receiveMetadataBlock.contains("rejectInboundMetadataConnection"))
        for reason in [
            "header_receive_failed",
            "missing_header",
            "malformed_header",
            "unsupported_resume_request",
            "unexpected_initial_message",
            "invalid_metadata_length",
            "metadata_receive_failed",
            "missing_metadata_payload",
            "malformed_metadata_json"
        ] {
            XCTAssertTrue(source.contains("\"\(reason)\""), "Missing fail-closed reason \(reason)")
        }
        XCTAssertTrue(receiveMetadataBlock.contains("activeConnections.removeValue(forKey: connectionId)"))
        XCTAssertTrue(receiveMetadataBlock.contains("connection.stateUpdateHandler = nil"))
        XCTAssertTrue(receiveMetadataBlock.contains("connection.cancel()"))
        XCTAssertFalse(receiveMetadataBlock.contains("try? JSONDecoder().decode(FileMetadata.self"))
        XCTAssertFalse(receiveMetadataBlock.contains("error.localizedDescription"))
    }
}
