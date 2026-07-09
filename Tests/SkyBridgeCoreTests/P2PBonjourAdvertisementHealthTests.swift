import XCTest
@testable import SkyBridgeCore

final class P2PBonjourAdvertisementHealthTests: XCTestCase {
    func testAdvertisementSnapshotRequiresReadyListenerAndPort() {
        let absent = ServiceAdvertisementSnapshot(serviceType: "_skybridge._tcp")
        XCTAssertFalse(absent.isAdvertising)
        XCTAssertFalse(absent.isConnectable)

        let starting = ServiceAdvertisementSnapshot(
            serviceType: "_skybridge._tcp",
            owner: "P2PDiscoveryService",
            port: nil,
            state: .starting
        )
        XCTAssertTrue(starting.isAdvertising)
        XCTAssertTrue(starting.isStarting)
        XCTAssertFalse(starting.isConnectable)

        let readyWithoutPort = ServiceAdvertisementSnapshot(
            serviceType: "_skybridge._tcp",
            owner: "P2PDiscoveryService",
            port: nil,
            state: .ready
        )
        XCTAssertFalse(readyWithoutPort.isConnectable)

        let ready = ServiceAdvertisementSnapshot(
            serviceType: "_skybridge._tcp",
            owner: "P2PDiscoveryService",
            port: 56432,
            state: .ready
        )
        XCTAssertTrue(ready.isConnectable)
        XCTAssertTrue(ready.isOwned(by: "P2PDiscoveryService"))
    }

    func testServiceAdvertiserCenterTracksOwnerAndInvalidatesDeadListeners() throws {
        let source = try readSource("Sources/SkyBridgeCore/DeviceDiscovery/DiscoveryOrchestrator.swift")

        XCTAssertTrue(source.contains("public struct ServiceAdvertisementSnapshot"))
        XCTAssertTrue(source.contains("owner: String? = nil"))
        XCTAssertTrue(source.contains("public func advertisementSnapshot(for serviceType: String)"))
        XCTAssertTrue(source.contains("private func handleListenerStateUpdate("))
        XCTAssertTrue(source.contains("case .failed, .cancelled:"))
        XCTAssertTrue(
            source.contains("records.removeValue(forKey: serviceType)"),
            "Failed or cancelled listeners must be removed so Bonjour visibility is not mistaken for a live TCP listener."
        )

        let recordWrite = try XCTUnwrap(source.range(of: "records[serviceType] = ListenerRecord("))
        let listenerStart = try XCTUnwrap(source.range(of: "listener.start(queue:"))
        XCTAssertLessThan(
            recordWrite.lowerBound,
            listenerStart.lowerBound,
            "The center must register the listener before start() so early ready/failed callbacks cannot be lost."
        )
    }

    func testP2PAdvertisingUsesCentralHealthSnapshot() throws {
        let p2p = try readSource("Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift")
        let localServices = try readSource("Sources/SkyBridgeCompassApp/LocalPeerServiceCoordinator.swift")

        XCTAssertTrue(p2p.contains("private static let controlAdvertisementOwner = \"P2PDiscoveryService\""))
        XCTAssertTrue(p2p.contains("advertisementSnapshot(for: Self.controlServiceType)"))
        XCTAssertTrue(p2p.contains("ensureAdvertisingHealthy()"))
        XCTAssertTrue(p2p.contains("owner: Self.controlAdvertisementOwner"))
        XCTAssertTrue(localServices.contains("await p2pDiscoveryService.ensureAdvertisingHealthy()"))
    }

    func testP2PAuthenticationDoesNotBlockOnOptionalPostAuthPairingExchange() throws {
        let source = try readSource("Sources/SkyBridgeCore/P2P/P2PModels.swift")
        let authenticateBody = try sourceSlice(
            from: "public func authenticate() async throws",
            to: "private func performHandshake() async throws",
            in: source
        )
        let postAuthHelperBody = try sourceSlice(
            from: "private func schedulePostAuthPairingIdentityExchange()",
            to: "private func sendPairingIdentityExchange(force:",
            in: source
        )

        XCTAssertTrue(authenticateBody.contains("schedulePostAuthPairingIdentityExchange()"))
        XCTAssertFalse(
            authenticateBody.contains("try await sendPairingIdentityExchange(force: true)"),
            "A completed authenticated session must return before optional post-auth trust metadata sync."
        )
        XCTAssertTrue(postAuthHelperBody.contains("Task { [weak self] in"))
        XCTAssertTrue(postAuthHelperBody.contains("sendPostAuthPairingIdentityExchangeWithTimeout"))
        XCTAssertTrue(postAuthHelperBody.contains("postAuthPairingIdentityExchangeTimeout"))
        XCTAssertTrue(postAuthHelperBody.contains("SkyBridgeLogger.p2p.info("))
    }

    func testP2PControlAdvertiserUsesLANDirectListenerParameters() throws {
        let center = try readSource("Sources/SkyBridgeCore/DeviceDiscovery/DiscoveryOrchestrator.swift")
        let p2p = try readSource("Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift")

        XCTAssertTrue(center.contains("includePeerToPeer: Bool = true"))
        XCTAssertTrue(center.contains("parameters.includePeerToPeer = includePeerToPeer"))
        XCTAssertTrue(center.contains("peerToPeer=\\(includePeerToPeer"))
        XCTAssertTrue(center.contains("LocalNetworkAdvertisementAddressProvider.attachAddressTXT(to: &record)"))
        XCTAssertTrue(center.contains("record[\"skybridgePort\"] = portValue"))
        XCTAssertTrue(center.contains("record[\"controlPort\"] = portValue"))
        XCTAssertTrue(center.contains("record[\"controlPortSource\"] = \"listener\""))
        XCTAssertTrue(
            p2p.contains("includePeerToPeer: false"),
            "P2P control advertising must use LAN-routable listener parameters so direct host:port control probes do not silently fall back to Bonjour/AWDL."
        )
    }

    @available(macOS 14.0, iOS 17.0, *)
    func testP2PConnectionAdvertisesSOAWhenStableIdentityIsKnownWithoutBonjourFlag() {
        let stableId = UUID().uuidString

        XCTAssertTrue(
            P2PConnection.shouldAdvertiseSOAForCurrentPath(
                capabilities: ["_skybridge._tcp"],
                handshakePeerDeviceId: "id:\(stableId.lowercased())",
                connectionDeviceId: "bonjour:office-ipad@local.",
                persistentDeviceId: nil
            )
        )
        XCTAssertTrue(
            P2PConnection.shouldAdvertiseSOAForCurrentPath(
                capabilities: ["_skybridge._tcp"],
                handshakePeerDeviceId: "bonjour:office-ipad@local.",
                connectionDeviceId: "bonjour:office-ipad@local.",
                persistentDeviceId: stableId
            )
        )
        XCTAssertTrue(
            P2PConnection.shouldAdvertiseSOAForCurrentPath(
                capabilities: ["HS_SOA"],
                handshakePeerDeviceId: "host:fe80::812:27b6:c448:dad0%en0",
                connectionDeviceId: "host:fe80::812:27b6:c448:dad0%en0",
                persistentDeviceId: nil
            )
        )
        XCTAssertFalse(
            P2PConnection.shouldAdvertiseSOAForCurrentPath(
                capabilities: ["_skybridge._tcp"],
                handshakePeerDeviceId: "host:fe80::812:27b6:c448:dad0%en0",
                connectionDeviceId: "host:fe80::812:27b6:c448:dad0%en0",
                persistentDeviceId: nil
            )
        )
    }

    func testBonjourBrowserDoesNotPinDiscoveryToOtherInterface() throws {
        let source = try readSource("Sources/SkyBridgeCore/DeviceDiscovery/DeviceDiscoveryManagerOptimized.swift")
        let browser = try sourceSlice(
            from: "private func startSingleBrowser(serviceType:",
            to: "browser.stateUpdateHandler",
            in: source
        )

        XCTAssertTrue(browser.contains("parameters.includePeerToPeer = true"))
        XCTAssertFalse(
            browser.contains("requiredInterfaceType"),
            "Bonjour browsing must not be pinned to .other; that hides normal Wi-Fi/Ethernet/AWDL iPad advertisements."
        )
    }

    @available(macOS 14.0, iOS 17.0, *)
    func testP2PControlPortParsingIsServiceTypeAware() {
        let txt = [
            "port": "51241",
            "skybridgePort": "51242",
            "controlPort": "51243",
            "transferPort": "8080",
            "fileTransferPort": "8080",
            "remoteControlPort": "5901"
        ]

        XCTAssertEqual(
            P2PDiscoveryBonjourPolicy.advertisedServicePort(from: txt, serviceType: "_skybridge._tcp"),
            51241
        )
        XCTAssertEqual(
            P2PDiscoveryBonjourPolicy.advertisedServicePort(from: txt, serviceType: "_skybridge-transfer._tcp"),
            8080
        )
        XCTAssertEqual(
            P2PDiscoveryBonjourPolicy.advertisedServicePort(from: txt, serviceType: "_skybridge-remote._tcp"),
            5901
        )
    }

    @available(macOS 14.0, iOS 17.0, *)
    func testP2PBonjourPolicySanitizesInferredNamesWithoutWeakIdentityFallbackForStrongDevices() {
        var weakDevice = DiscoveredDevice(
            id: UUID(),
            name: "Bill's iPad [高速]",
            ipv4: nil,
            ipv6: nil,
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 9527],
            connectionTypes: [.wifi],
            uniqueIdentifier: "recent:name:Bill's iPad [高速]"
        )

        XCTAssertEqual(
            P2PDiscoveryBonjourPolicy.resolvedBonjourServiceNameCandidates(for: weakDevice),
            ["Bill's iPad", "iPad"]
        )

        weakDevice.uniqueIdentifier = nil
        XCTAssertEqual(
            P2PDiscoveryBonjourPolicy.resolvedBonjourServiceNameCandidates(for: weakDevice),
            ["iPad", "Bill's iPad"]
        )

        let strongDevice = DiscoveredDevice(
            id: UUID(),
            name: "Bill's iPad",
            ipv4: nil,
            ipv6: nil,
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 9527],
            connectionTypes: [.wifi],
            uniqueIdentifier: nil,
            deviceId: "id:stable-ipad"
        )
        XCTAssertEqual(
            P2PDiscoveryBonjourPolicy.resolvedBonjourServiceNameCandidates(for: strongDevice),
            []
        )

        let routedStrongDevice = DiscoveredDevice(
            id: UUID(),
            name: "Bill's iPad",
            ipv4: nil,
            ipv6: nil,
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 9527],
            connectionTypes: [.wifi],
            uniqueIdentifier: "bonjour:Bill's iPad@local.",
            deviceId: "stable-ipad"
        )
        XCTAssertEqual(
            P2PDiscoveryBonjourPolicy.resolvedBonjourServiceNameCandidates(for: routedStrongDevice),
            ["Bill's iPad"]
        )

        let stableRoutedDevice = DiscoveredDevice(
            id: UUID(),
            name: "Bill's iPad",
            ipv4: nil,
            ipv6: nil,
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 9527],
            connectionTypes: [.wifi],
            uniqueIdentifier: "id:stable-ipad",
            routeIdentifiers: ["bonjour:Bill's iPad@local."],
            deviceId: "stable-ipad"
        )
        XCTAssertEqual(
            P2PDiscoveryBonjourPolicy.resolvedBonjourServiceNameCandidates(for: stableRoutedDevice),
            ["Bill's iPad"]
        )

        let legacyRoutedStrongDevice = DiscoveredDevice(
            id: UUID(),
            name: "Ziang的iPad",
            ipv4: "192.168.0.104",
            ipv6: nil,
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 9527],
            connectionTypes: [.wifi],
            uniqueIdentifier: "id:9DDF920E-D7C4-51F2-9C94-67FF629BDF04",
            routeIdentifiers: ["bonjour:iPad_Pro_11-inch__M4__local."],
            deviceId: "9DDF920E-D7C4-51F2-9C94-67FF629BDF04",
            pubKeyFP: String(repeating: "a", count: 64)
        )
        XCTAssertEqual(
            P2PDiscoveryBonjourPolicy.resolvedBonjourServiceNameCandidates(for: legacyRoutedStrongDevice),
            ["iPad Pro 11-inch (M4)"]
        )
    }

    @available(macOS 14.0, iOS 17.0, *)
    func testOnlineRouteValidationRejectsStrongIdentityWithoutDialableRoute() {
        let identityOnly = DiscoveredDevice(
            id: UUID(),
            name: "Linux Workstation",
            ipv4: nil,
            ipv6: nil,
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 9527],
            connectionTypes: [.wifi],
            uniqueIdentifier: "id:stable-linux-workstation",
            deviceId: "stable-linux-workstation"
        )
        XCTAssertFalse(
            UnifiedOnlineDeviceManager.hasResolvedSkyBridgeControlRoute(identityOnly),
            "A stable id plus control-port metadata is not a dialable Bonjour route."
        )

        let bonjourRouted = DiscoveredDevice(
            id: UUID(),
            name: "Linux Workstation",
            ipv4: nil,
            ipv6: nil,
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 9527],
            connectionTypes: [.wifi],
            uniqueIdentifier: "bonjour:linux-workstation@local.",
            deviceId: "stable-linux-workstation"
        )
        XCTAssertTrue(UnifiedOnlineDeviceManager.hasResolvedSkyBridgeControlRoute(bonjourRouted))

        let stableWithPreservedRoute = DiscoveredDevice(
            id: UUID(),
            name: "Linux Workstation",
            ipv4: nil,
            ipv6: nil,
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 9527],
            connectionTypes: [.wifi],
            uniqueIdentifier: "id:stable-linux-workstation",
            routeIdentifiers: ["bonjour:linux-workstation@local."],
            deviceId: "stable-linux-workstation"
        )
        XCTAssertTrue(
            UnifiedOnlineDeviceManager.hasResolvedSkyBridgeControlRoute(stableWithPreservedRoute),
            "Stable identity is connectable only when the real Bonjour instance route is preserved separately."
        )

        let malformedBonjourRoute = DiscoveredDevice(
            id: UUID(),
            name: "Linux Workstation",
            ipv4: nil,
            ipv6: nil,
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 9527],
            connectionTypes: [.wifi],
            uniqueIdentifier: "id:stable-linux-workstation",
            routeIdentifiers: ["bonjour:id:stable-linux-workstation@local."],
            deviceId: "stable-linux-workstation"
        )
        XCTAssertFalse(
            UnifiedOnlineDeviceManager.hasResolvedSkyBridgeControlRoute(malformedBonjourRoute),
            "A stable id must never be treated as a Bonjour service instance."
        )

        let hostRouted = DiscoveredDevice(
            id: UUID(),
            name: "Linux Workstation",
            ipv4: "192.0.2.44",
            ipv6: nil,
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 9527],
            connectionTypes: [.wifi],
            uniqueIdentifier: "id:stable-linux-workstation",
            deviceId: "stable-linux-workstation"
        )
        XCTAssertTrue(UnifiedOnlineDeviceManager.hasResolvedSkyBridgeControlRoute(hostRouted))

        let hostRoutedWithoutResolvedPort = DiscoveredDevice(
            id: UUID(),
            name: "Linux Workstation",
            ipv4: "192.0.2.44",
            ipv6: nil,
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 0],
            connectionTypes: [.wifi],
            uniqueIdentifier: "id:stable-linux-workstation",
            deviceId: "stable-linux-workstation"
        )
        XCTAssertFalse(
            UnifiedOnlineDeviceManager.hasResolvedSkyBridgeControlRoute(hostRoutedWithoutResolvedPort),
            "A host route must carry a resolved positive SkyBridge control port; guessing 9527 turns stale route metadata into TCP timeouts."
        )

        let bonjourRoutedWithoutResolvedPort = DiscoveredDevice(
            id: UUID(),
            name: "Linux Workstation",
            ipv4: nil,
            ipv6: nil,
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 0],
            connectionTypes: [.wifi],
            uniqueIdentifier: "bonjour:linux-workstation@local.",
            deviceId: "stable-linux-workstation"
        )
        XCTAssertTrue(
            UnifiedOnlineDeviceManager.hasResolvedSkyBridgeControlRoute(bonjourRoutedWithoutResolvedPort),
            "A non-Apple Bonjour service instance remains dialable through NWEndpoint.service before its TXT/A records have populated a host port."
        )

        let appleMobileFingerprint = String(repeating: "a", count: 64)
        let appleMobileBonjourWithoutResolvedPort = DiscoveredDevice(
            id: UUID(),
            name: "Bill's iPad",
            ipv4: nil,
            ipv6: nil,
            platformName: "iPadOS",
            modelName: "iPad Pro",
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 0],
            connectionTypes: [.wifi],
            uniqueIdentifier: "bonjour:Bill's iPad@local.",
            deviceId: "stable-ipad",
            pubKeyFP: appleMobileFingerprint
        )
        XCTAssertFalse(
            UnifiedOnlineDeviceManager.hasResolvedSkyBridgeControlRoute(appleMobileBonjourWithoutResolvedPort),
            "Apple mobile rows must not expose strict-PQC connect buttons until discovery resolves the actual SkyBridge control port."
        )

        let appleMobileBonjourWithResolvedPort = DiscoveredDevice(
            id: UUID(),
            name: "Bill's iPad",
            ipv4: nil,
            ipv6: nil,
            platformName: "iPadOS",
            modelName: "iPad Pro",
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 9527],
            connectionTypes: [.wifi],
            uniqueIdentifier: "bonjour:Bill's iPad@local.",
            deviceId: "stable-ipad",
            pubKeyFP: appleMobileFingerprint
        )
        XCTAssertTrue(
            UnifiedOnlineDeviceManager.hasResolvedSkyBridgeControlRoute(appleMobileBonjourWithResolvedPort),
            "Apple mobile Bonjour routes become connectable only after strong protocol identity and a positive control port are present."
        )
    }

    @available(macOS 14.0, iOS 17.0, *)
    func testBonjourServiceConnectionUsesRouteIdentityAsRuntimePeerId() throws {
        let stableRoutedDevice = DiscoveredDevice(
            id: UUID(),
            name: "Bill's iPad",
            ipv4: nil,
            ipv6: nil,
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 9527],
            connectionTypes: [.wifi],
            uniqueIdentifier: "id:07CB9A6E-7492-4680-9DD7-F37DC8568891",
            routeIdentifiers: ["bonjour:iPad@local."],
            deviceId: "07CB9A6E-7492-4680-9DD7-F37DC8568891"
        )

        XCTAssertEqual(
            P2PDiscoveryBonjourPolicy.connectionPeerIdentifier(
                for: stableRoutedDevice,
                usesBonjourServiceEndpoint: true
            ),
            "bonjour:iPad@local."
        )
        XCTAssertEqual(
            P2PDiscoveryBonjourPolicy.connectionPeerIdentifier(
                for: stableRoutedDevice,
                usesBonjourServiceEndpoint: false
            ),
            "07CB9A6E-7492-4680-9DD7-F37DC8568891"
        )

        let malformedRouteDevice = DiscoveredDevice(
            id: UUID(),
            name: "Bill's iPad",
            ipv4: nil,
            ipv6: nil,
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 9527],
            connectionTypes: [.wifi],
            uniqueIdentifier: "id:07CB9A6E-7492-4680-9DD7-F37DC8568891",
            routeIdentifiers: ["bonjour:id:07CB9A6E-7492-4680-9DD7-F37DC8568891@local."],
            deviceId: "07CB9A6E-7492-4680-9DD7-F37DC8568891"
        )

        XCTAssertEqual(
            P2PDiscoveryBonjourPolicy.connectionPeerIdentifier(
                for: malformedRouteDevice,
                usesBonjourServiceEndpoint: true
            ),
            "07CB9A6E-7492-4680-9DD7-F37DC8568891",
            "Stable ids must not be smuggled into Bonjour service names for route dialing."
        )

        let p2p = try readSource("Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift")
        XCTAssertTrue(
            p2p.contains("P2PDiscoveryBonjourPolicy.connectionPeerIdentifier("),
            "P2P service connects must use the route-aware peer-id policy, not the UI stable identity directly."
        )
    }

    func testP2PReconnectDiscoveryDoesNotInferWeakNameTargetsForStrongIdentity() throws {
        let source = try [
            readSource("Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift"),
            readSource("Sources/SkyBridgeCore/P2P/P2PDiscoveryBonjourPolicy.swift")
        ].joined(separator: "\n")

        let routeBoundIdentityMerge = try XCTUnwrap(
            source.range(of: "Self.discoveredDevice(existing, hasNormalizedBonjourIdentifier: normalizedBonjourIdentifier)")
        )
        let strongIdentityWeakMergeGuard = try XCTUnwrap(
            source.range(of: "guard !hasStrongIdentity else {\n            return nil\n        }")
        )
        XCTAssertLessThan(
            routeBoundIdentityMerge.lowerBound,
            strongIdentityWeakMergeGuard.lowerBound,
            "A complete TXT identity may upgrade the same Bonjour service instance before strong-identity records are blocked from weak name/IP merging."
        )
        XCTAssertTrue(
            source.contains("Self.hasCompleteProtocolIdentity(") &&
            source.contains("P2PDiscoveryBonjourPolicy.isRoutableBonjourIdentifier(bonjourIdentifier)"),
            "Route-bound identity upgrades must require a routable Bonjour service instance plus complete protocol identity."
        )
        XCTAssertTrue(
            source.contains("guard !hasStrongIdentity else {\n            return nil\n        }"),
            "Discovery refresh must not graft a supplied strong identity onto same-name or same-IP weak Bonjour snapshots."
        )
        XCTAssertTrue(
            source.contains("guard !hasStrongIdentity else {\n            return candidates\n        }"),
            "Strong-identity connection targets may use only a real Bonjour instance, not an inferred iPad/iPhone display name."
        )
        XCTAssertFalse(
            source.contains("let cleanExisting"),
            "Discovered device merge must not collapse records by display name; that can hide stale or wrong-identity Bonjour records."
        )
    }

    func testP2PDiscoveryMergesPortOnlyBonjourRefreshIntoRouteBoundProtocolIdentity() throws {
        let source = try readSource("Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift")
        let latestResolver = try sourceSlice(
            from: "private func resolveLatestConnectableDevice(from device: DiscoveredDevice)",
            to: "private func bonjourIdentifier(from endpoint:",
            in: source
        )
        let finder = try sourceSlice(
            from: "private func findDiscoveredDeviceIndex(",
            to: "private nonisolated static func hasCompleteProtocolIdentity(",
            in: source
        )

        XCTAssertTrue(
            latestResolver.contains("P2PDiscoveryBonjourPolicy.preferredRoutableBonjourIdentifier(for: device)")
                && latestResolver.contains("bonjourIdentifier: routeBoundBonjourIdentifier")
                && latestResolver.contains("preserveSuppliedConnectableRouteContext(from: device, into: &refreshed)"),
            "Strict-PQC connect refresh must look up the latest discovery record by the real Bonjour route, not by a stable device id masquerading as a service name."
        )
        XCTAssertTrue(
            finder.contains("let routeMatchedIndexes = discoveredDevices.indices.filter")
                && finder.contains("Self.discoveredDevice(\n                    discoveredDevices[$0],\n                    hasNormalizedBonjourIdentifier: normalizedBonjourIdentifier")
                && finder.contains("Self.hasCompleteProtocolIdentity(\n                    deviceId: discoveredDevices[$0].deviceId")
                && finder.contains("return identityBackedIndex")
                && finder.contains("return routedIndex"),
            "A port-only Bonjour refresh must merge into an existing route-bound protocol identity before falling back to weak IP/name matching."
        )
        XCTAssertLessThan(
            try XCTUnwrap(finder.range(of: "let routeMatchedIndexes = discoveredDevices.indices.filter")?.lowerBound),
            try XCTUnwrap(finder.range(of: "return discoveredDevices.firstIndex(where: { existing in")?.lowerBound),
            "Route-bound Bonjour merging must happen before weak uniqueIdentifier/IP fallback matching."
        )
    }

    func testLegacyDiscoveryManagersCannotStopP2POwnedSkybridgeAdvertiser() throws {
        let manager = try readSource("Sources/SkyBridgeCore/DeviceDiscovery/DeviceDiscoveryManager.swift")
        let optimized = try readSource("Sources/SkyBridgeCore/DeviceDiscovery/DeviceDiscoveryManagerOptimized.swift")
        let p2p = try readSource("Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift")

        XCTAssertFalse(manager.contains("ServiceAdvertiserCenter.shared.stopAdvertising(\"_skybridge._tcp\")"))
        XCTAssertFalse(optimized.contains("ServiceAdvertiserCenter.shared.stopAdvertising(\"_skybridge._tcp\")"))
        XCTAssertFalse(p2p.contains("ServiceAdvertiserCenter.shared.stopAdvertising(\"_skybridge._tcp\")"))

        XCTAssertTrue(manager.contains("owner: advertisementOwner"))
        XCTAssertTrue(optimized.contains("owner: Self.advertisementOwner"))
        XCTAssertTrue(manager.contains("owner: advertisementOwner\n            )"))
        XCTAssertTrue(optimized.contains("owner: Self.advertisementOwner\n            )"))
    }

    func testInboundDiscoveryConnectionsDetachStateHandlers() throws {
        let sources = [
            try readSource("Sources/SkyBridgeCore/DeviceDiscovery/DeviceDiscoveryManager.swift"),
            try readSource("Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift")
        ]

        for source in sources {
            let handleNewConnectionStart = source.contains("private func handleNewConnection(_ connection: NWConnection)")
                ? "private func handleNewConnection(_ connection: NWConnection)"
                : "nonisolated private static func handleNewConnection(_ connection: NWConnection)"
            let handleNewConnection = try sourceSlice(
                from: handleNewConnectionStart,
                to: "private func handleConnectionStateUpdate",
                in: source
            )
            XCTAssertTrue(
                handleNewConnection.contains("weak connection] state in"),
                "Inbound NWConnection state handlers must not strongly capture the connection they are installed on."
            )
            XCTAssertFalse(
                handleNewConnection.contains("[connection] state in"),
                "Inbound NWConnection state handlers must not strongly capture the connection they are installed on."
            )
            if handleNewConnection.contains("Task { @MainActor") {
                XCTAssertTrue(
                    handleNewConnection.contains("Task { @MainActor [weak self, weak connection] in"),
                    "The MainActor hop must preserve weak connection ownership to avoid an indirect closure cycle."
                )
            }

            let handleIncomingStart = source.contains("private func handleIncomingConnectionStateUpdate(_ state: NWConnection.State, connection: NWConnection)")
                ? "private func handleIncomingConnectionStateUpdate(_ state: NWConnection.State, connection: NWConnection)"
                : "nonisolated private static func handleIncomingConnectionStateUpdate(_ state: NWConnection.State, connection: NWConnection)"
            let handleIncoming = try sourceSlice(
                from: handleIncomingStart,
                to: source.contains("private func resolveInboundPeerIdentifier") ? "private func resolveInboundPeerIdentifier" : "// MARK: - Inbound control channel",
                in: source
            )
            XCTAssertEqual(
                handleIncoming.components(separatedBy: "connection.stateUpdateHandler = nil").count - 1,
                3,
                "Ready, failed, and cancelled inbound states must detach stateUpdateHandler before handoff or cancel."
            )
        }
    }

    func testTrustedBonjourTXTResolverHasBoundedCallbackLifetime() throws {
        let source = try readSource("Sources/SkyBridgeCompassApp/Views/EnhancedDeviceDiscoveryView.swift")
        let resolver = try sourceSlice(
            from: "private final class BonjourTXTLookupResolver",
            to: "struct InfoBanner",
            in: source
        )

        XCTAssertTrue(
            resolver.contains("private let resumed = OSAllocatedUnfairLock(initialState: false)"),
            "NetService resolve callbacks and timeout callbacks must share a one-shot completion gate."
        )
        XCTAssertTrue(
            resolver.contains("service.delegate = nil"),
            "The resolver must detach the NetService delegate before releasing its self-retain."
        )
        XCTAssertTrue(
            resolver.contains("service.remove(from: .main, forMode: .common)"),
            "NetService should be removed from the run loop during completion cleanup."
        )
        XCTAssertTrue(
            resolver.contains("process.terminationHandler"),
            "dns-sd fallback should use terminationHandler instead of blocking a cooperative Swift task thread."
        )
        XCTAssertFalse(
            resolver.contains("process.waitUntilExit()"),
            "Blocking waitUntilExit can run Foundation run-loop callbacks on the cooperative worker and revive stale weak delegates."
        )
    }

    func testOnlineDeviceConnectFallbackRequiresRealSkyBridgeEndpoint() throws {
        let source = try readSource("Sources/SkyBridgeCompassApp/Services/OnlineDeviceConnectionCoordinator.swift")
        let p2pSource = try readSource("Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift")
        let connector = source

        XCTAssertTrue(
            source.contains("resolvedConnectableDiscoveredCandidates(for: device, limit: 6)"),
            "Connect must prefer matched discovery candidates that already contain a real route."
        )
        XCTAssertTrue(
            source.contains("let protocolDeviceId = preferredLiveProtocolDeviceId(from: liveDiscoveredCandidates)") &&
            source.contains("let protocolFingerprint = preferredLiveProtocolFingerprint(from: liveDiscoveredCandidates)") &&
            source.contains("var discoveredCandidates = liveDiscoveredCandidates.map") &&
            source.contains("withAuthoritativeProtocolIdentity(") &&
            source.contains("withPresentationRouteContext(") &&
            source.contains("let currentStableDeviceId = stableProtocolIdentityKey(from: enriched.deviceId)") &&
            source.contains("let replacementStableDeviceId = stableProtocolIdentityKey(from: deviceId)") &&
            source.contains("currentStableDeviceId != replacementStableDeviceId") &&
            source.contains("normalizedProtocolFingerprint($0.pubKeyFP) != nil") &&
            source.contains("normalizedProtocolFingerprint(enriched.pubKeyFP) == nil") &&
            source.contains("normalizedProtocolFingerprint(device.protocolFingerprint)") &&
            source.contains("stableProtocolIdentityKey(from: device.uniqueIdentifier)"),
            "Live discovery candidates must carry the online row's stable protocol identity so strict PQC does not reject a real route as an endpoint alias."
        )
        XCTAssertTrue(
            source.contains("canBorrowPresentationRouteContext(") &&
            source.contains("routableIPv4(device.ipv4)") &&
            source.contains("routableIPv6(device.ipv6)") &&
            source.contains("candidateRoutes(candidate).isDisjoint(with: onlineRoutes(device))"),
            "When a live route-bound candidate has protocol identity but no resolved address, connect planning must carry the online row's matching LAN route into strict-PQC bootstrap without guessing endpoints."
        )
        XCTAssertTrue(
            source.contains("if let fallback = fallbackDiscoveredDevice(for: device, unifiedDeviceManager: unifiedDeviceManager)"),
            "Connect must not append a synthetic fallback candidate for stale recent or USB-only rows."
        )
        XCTAssertTrue(
            connector.contains("UnifiedOnlineDeviceManager.hasResolvedSkyBridgeControlRoute(fallback)"),
            "Fallback candidates must be gated on a dialable host route or Bonjour instance, not only endpoint metadata."
        )
        XCTAssertTrue(
            connector.contains("isAppleMobilePresentation(device)") &&
            connector.contains("normalizedProtocolFingerprint(fallback.pubKeyFP) == nil") &&
            connector.contains("跳过在线设备 Apple mobile fallback"),
            "Apple mobile fallback candidates must fail closed unless they carry a normalized protocol fingerprint."
        )
        XCTAssertFalse(
            connector.contains("guard hasSkyBridgeControlService\n            || hasSkyBridgeControlPort"),
            "A control service/port alone must not turn a stable id into a Bonjour service name."
        )
        XCTAssertTrue(
            connector.contains("return nil"),
            "Fallback creation should fail closed instead of guessing a generic iPhone/iPad Bonjour service name."
        )
        XCTAssertFalse(
            connector.contains("source: .skybridgeBonjour"),
            "The UI must not mark every fallback as SkyBridge Bonjour; that makes stale rows look connectable."
        )
        XCTAssertFalse(
            p2pSource.contains("allowSkyBridgeDefaultFallback") || p2pSource.contains("return 9527"),
            "P2P host endpoint construction must not guess SkyBridge's default control port when discovery has not resolved a real port."
        )
        XCTAssertTrue(
            p2pSource.contains("P2PDiscoveryService.sendContent") &&
            p2pSource.contains("SendContentContext") &&
            p2pSource.contains("context.complete(.failure(P2PDiscoveryError.timeout))"),
            "Bootstrap/control sends must have a bounded continuation lifecycle so cancelled NWConnection sends cannot suspend forever."
        )
        XCTAssertTrue(
            p2pSource.contains("let freshBonjourHostFallbackEndpoints = await makeFreshBonjourHostFallbackEndpoints(") &&
            p2pSource.contains("} else if !bonjourEndpointAttempts.isEmpty {\n            endpointAttempts.append(contentsOf: bonjourEndpointAttempts)\n            endpointAttempts.append(contentsOf: freshBonjourHostFallbackEndpoints)\n            endpointAttempts.append(contentsOf: hostFallbackEndpoints)") &&
            p2pSource.contains("resolveNetServiceEndpoint(") &&
            p2pSource.contains("Self.resolveNetServiceEndpointOnMain(") &&
            p2pSource.contains("timeoutSeconds: 3.0") &&
            p2pSource.contains("return (directRoutable + directAny + service).filter"),
            "Automatic LAN connects should still prefer live Bonjour/current NetService endpoints, while strict-PQC bootstrap should try already-resolved direct LAN endpoints before Bonjour service fallback."
        )
    }

    func testMacStrictPQCBootstrapUsesEndpointScopedPeerToPeerPolicy() throws {
        let p2pSource = try readSource("Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift")
        let makeConnectionBody = try sourceSlice(
            from: "private func makeConnection(",
            to: "private func applyInterfacePreference",
            in: p2pSource
        )
        let endpointPolicyBody = try sourceSlice(
            from: "private static func shouldIncludePeerToPeer(for endpoint: NWEndpoint)",
            to: "private func applyInterfacePreference",
            in: p2pSource
        )
        let bootstrapExchangeBody = try sourceSlice(
            from: "private func exchangeBootstrapControlMessage(",
            to: "private func waitForBootstrapControlConnection",
            in: p2pSource
        )
        let bootstrapWaitBody = try sourceSlice(
            from: "private func waitForBootstrapControlConnection(",
            to: "private func sendBootstrapFrame",
            in: p2pSource
        )

        XCTAssertTrue(makeConnectionBody.contains("params.includePeerToPeer = Self.shouldIncludePeerToPeer(for: endpoint)"))
        XCTAssertFalse(makeConnectionBody.contains("params.includePeerToPeer = true"))
        XCTAssertTrue(endpointPolicyBody.contains("guard case .hostPort(let host, _) = endpoint else { return true }"))
        XCTAssertTrue(endpointPolicyBody.contains("if IPv4Address(value) != nil {\n            return value.hasPrefix(\"169.254.\")\n        }"))
        XCTAssertTrue(endpointPolicyBody.contains("if IPv6Address(value) != nil {\n            return value.hasPrefix(\"fe80:\")\n        }"))
        XCTAssertTrue(
            endpointPolicyBody.contains("return false"),
            "Direct hostPort endpoints should only opt into peer-to-peer for validated link-local addresses; Bonjour/service endpoints keep peer-to-peer through the non-hostPort branch."
        )
        XCTAssertTrue(bootstrapExchangeBody.contains("peerToPeer=\\(Self.shouldIncludePeerToPeer(for: endpoint) ? 1 : 0)"))
        XCTAssertTrue(
            bootstrapWaitBody.contains("case .waiting(let error):") &&
            bootstrapWaitBody.contains("connection.currentPath") &&
            p2pSource.contains("reason=local-network-permission-denied") &&
            bootstrapWaitBody.contains("P2PDiscoveryError.localNetworkPermissionDenied"),
            "Strict-PQC bootstrap must fail fast when Network.framework reports Local Network privacy denial, instead of collapsing the app-side authorization failure into a generic timeout."
        )
    }

    func testRemoteControlRoutePreflightDoesNotEnterSessionLifecycle() throws {
        let server = try readSource("Sources/SkyBridgeCore/RemoteControl/RemoteControlServer.swift")
        let manager = try readSource("Sources/SkyBridgeCore/RemoteControl/RemoteControlManager.swift")
        let harness = try readSource("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/App/Smoke/LocalP2PSmokeHarness.swift")

        XCTAssertTrue(server.contains("SKYBRIDGE_REMOTE_ROUTE_PROBE_V1"))
        XCTAssertTrue(server.contains("probe=remote-route-preflight"))
        XCTAssertTrue(server.contains("receiveInitialConnectionBytes("))
        XCTAssertTrue(
            server.contains("let handoffConnection = connection")
                && server.contains("let handoffData = initialData")
                && server.contains("connection: handoffConnection,\n                        initialData: handoffData"),
            "Server-side first-byte sniffing must transfer real handshake bytes into RemoteControlManager instead of consuming MessageA."
        )

        XCTAssertTrue(manager.contains("initialData: Data? = nil"))
        XCTAssertTrue(manager.contains("var pendingInitialData = initialData"))
        XCTAssertTrue(manager.contains("processInboundRemoteEventChunk("))

        XCTAssertTrue(harness.contains("remoteControlRoutePreflightProbePayload"))
        XCTAssertTrue(harness.contains("probePayload: Self.remoteControlRoutePreflightProbePayload"))
        XCTAssertTrue(harness.contains("probe-send=ok"))
    }

    private func readSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func sourceSlice(from start: String, to end: String, in source: String) throws -> String {
        let startRange = try XCTUnwrap(source.range(of: start))
        let endRange = try XCTUnwrap(source.range(of: end, range: startRange.upperBound..<source.endIndex))
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }
}
