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
        XCTAssertTrue(source.contains("private func waitForAdvertisingReady("))
        XCTAssertTrue(source.contains("let readyPort = try await waitForAdvertisingReady("))
        XCTAssertTrue(source.contains("throw AdvertisingError.timedOut"))
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
        let managerStart = try sourceSlice(
            from: "public override func performStart() async throws",
            to: "public override func performStop() async",
            in: p2p
        )
        let managerStop = try sourceSlice(
            from: "public override func performStop() async",
            to: "public override func cleanup()",
            in: p2p
        )
        let stopScanning = try sourceSlice(
            from: "public func stopScanning()",
            to: "public func connectToDevice(_ device: DiscoveredDevice)",
            in: p2p
        )

        XCTAssertTrue(p2p.contains("private static let controlAdvertisementOwner = \"P2PDiscoveryService\""))
        XCTAssertTrue(p2p.contains("advertisementSnapshot(for: Self.controlServiceType)"))
        XCTAssertTrue(p2p.contains("ensureAdvertisingHealthy()"))
        XCTAssertTrue(p2p.contains("owner: Self.controlAdvertisementOwner"))
        XCTAssertTrue(localServices.contains("try await p2pDiscoveryService.ensureAdvertisingHealthy()"))
        XCTAssertTrue(p2p.contains("private func startAdvertising(forceRebind: Bool = false) async throws"))
        XCTAssertTrue(p2p.contains("public func ensureStartedAndScanning() async throws"))
        XCTAssertTrue(p2p.contains("try await startupLifecycle.ensureStarted("))
        XCTAssertTrue(p2p.contains("try await ensureStartedAndScanning()"))
        XCTAssertTrue(p2p.contains("try await reconcileAdvertisingHealth()"))
        XCTAssertTrue(p2p.contains("_ = beginScanningIfNeeded()"))
        XCTAssertTrue(p2p.contains("advertisingLifecycleOperation == .starting"))
        XCTAssertTrue(p2p.contains("try await existingTask.value"))
        XCTAssertTrue(p2p.contains("try Task.checkCancellation()"))
        XCTAssertTrue(p2p.contains("readySnapshot.isOwned(by: Self.controlAdvertisementOwner)"))
        XCTAssertTrue(p2p.contains("readySnapshot.isConnectable"))
        XCTAssertTrue(p2p.contains("centerSnapshot.isConnectable"))
        XCTAssertTrue(p2p.contains("waitUntilReady(Self.controlServiceType)"))
        XCTAssertTrue(
            managerStart.contains("await performStop()"),
            "A failed manager start must tear down browsing and advertising before propagating the error."
        )
        XCTAssertFalse(
            managerStart.contains("if startedScanning"),
            "Conditionally rolling back only newly-created browsers leaves an inactive manager half-started."
        )
        XCTAssertFalse(
            stopScanning.contains("stopAdvertising()")
                || stopScanning.contains("acceptingInboundControlConnections = false"),
            "Stopping an outbound browser lease must not withdraw or reject the app-wide inbound service."
        )
        let stopBrowserOffset = try XCTUnwrap(managerStop.range(of: "stopScanning()")?.lowerBound)
        let stopAdvertisementOffset = try XCTUnwrap(
            managerStop.range(of: "stopAdvertising()")?.lowerBound
        )
        XCTAssertLessThan(
            stopBrowserOffset,
            stopAdvertisementOffset,
            "Only the full manager stop may release both browser and advertisement lifecycles."
        )
        XCTAssertFalse(
            p2p.contains("centerSnapshot.isConnectable || centerSnapshot.isStarting"),
            "A listener that is merely starting must not be reported as an active advertisement."
        )
    }

    func testP2PDiscoveryReadinessPolicyStartsInactiveManagerAndWaitsForInFlightStart() {
        XCTAssertEqual(
            P2PDiscoveryReadinessPolicy.action(
                isInitialized: true,
                status: .inactive,
                isScanning: false
            ),
            .startManager
        )
        XCTAssertEqual(
            P2PDiscoveryReadinessPolicy.action(
                isInitialized: true,
                status: .starting,
                isScanning: true
            ),
            .waitForManagerStart
        )
        XCTAssertEqual(
            P2PDiscoveryReadinessPolicy.action(
                isInitialized: true,
                status: .active,
                isScanning: true
            ),
            .ready
        )
    }

    func testP2PDiscoveryReadinessPolicyRepairsStoppedScanningAndAllowsFreshStartAfterFailure() {
        XCTAssertEqual(
            P2PDiscoveryReadinessPolicy.action(
                isInitialized: true,
                status: .active,
                isScanning: false
            ),
            .resumeScanning
        )
        XCTAssertEqual(
            P2PDiscoveryReadinessPolicy.action(
                isInitialized: false,
                status: .inactive,
                isScanning: false
            ),
            .waitForInitialization
        )
        XCTAssertEqual(
            P2PDiscoveryReadinessPolicy.action(
                isInitialized: true,
                status: .stopping,
                isScanning: false
            ),
            .rejectStopping
        )
        XCTAssertEqual(
            P2PDiscoveryReadinessPolicy.action(
                isInitialized: true,
                status: .error("listener failed"),
                isScanning: false
            ),
            .startManager,
            "A completed failed attempt must leave the singular lifecycle able to start a fresh generation."
        )
    }

    func testManagedP2PStartupCommitsNetworkManagerOnlyAfterDiscoveryReadiness() throws {
        let discovery = try readSource("Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift")
        let networkManager = try readSource("Sources/SkyBridgeCore/P2P/P2PNetworkManager.swift")
        let networkStart = try sourceSlice(
            from: "public func start() async throws",
            to: "public func stop() async",
            in: networkManager
        )
        let browserOnlyStart = try sourceSlice(
            from: "public func startBrowsing()",
            to: "@discardableResult\n    private func beginScanningIfNeeded()",
            in: discovery
        )

        let readinessCall = try XCTUnwrap(
            networkStart.range(of: "try await self.discoveryService.ensureStartedAndScanning()")
        )
        let startedCommit = try XCTUnwrap(networkStart.range(of: "self.isStarted = true"))
        XCTAssertLessThan(
            readinessCall.lowerBound,
            startedCommit.lowerBound,
            "P2PNetworkManager must not publish started before discovery and advertising are connectable."
        )
        XCTAssertTrue(networkStart.contains("startupLifecycle.ensureStarted("))
        XCTAssertTrue(networkStart.contains("try Task.checkCancellation()"))
        XCTAssertTrue(
            networkManager.contains("@Published public private(set) var isStarted: Bool = false"),
            "Only the managed lifecycle may publish P2P startup readiness."
        )
        XCTAssertTrue(browserOnlyStart.contains("_ = beginScanningIfNeeded()"))
        XCTAssertFalse(browserOnlyStart.contains("Task {"))
        XCTAssertFalse(browserOnlyStart.contains("startAdvertising("))
        XCTAssertFalse(networkManager.contains("discoveryService.startScanning()"))
    }

    func testIOSInboundBonjourConnectionBreaksStateHandlerCycleAndTimesOut() throws {
        let source = try readSource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/DeviceDiscoveryManager.swift"
        )

        XCTAssertTrue(source.contains("let readinessTimeoutTask = Task { @MainActor [weak self, weak connection] in"))
        XCTAssertTrue(source.contains("[weak self, weak connection] state in"))
        XCTAssertTrue(source.contains("connection.stateUpdateHandler = nil"))
        XCTAssertTrue(source.contains("p2p-listener inbound-timeout"))
        XCTAssertTrue(source.contains("maximumPreReadyInboundConnections = 32"))
        XCTAssertTrue(source.contains("maximumPreReadyInboundConnectionsPerEndpoint = 4"))
    }

    func testIOSLiveBonjourRoutesPreserveBrowserReportedInterfaceOwnership() throws {
        let discovery = try readSource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/DeviceDiscoveryManager.swift"
        )
        let connectionManager = try readSource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )
        let harness = try readSource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/App/Smoke/LocalP2PSmokeHarness.swift"
        )

        XCTAssertTrue(discovery.contains("let interfaces: [NWInterface]"))
        XCTAssertTrue(discovery.contains("interfaces: result.interfaces"))
        XCTAssertTrue(discovery.contains("let observedInterfaces = Array(Set(snapshot.interfaces))"))
        XCTAssertTrue(discovery.contains("interface: interface"))
        XCTAssertTrue(connectionManager.contains("parameters.requiredInterface = observedInterface"))
        XCTAssertTrue(harness.contains("observedInterfaces="))
    }

    func testP2PAuthenticationDoesNotBlockOnOptionalPostAuthPairingExchange() throws {
        let source = try readSource("Sources/SkyBridgeCore/P2P/P2PModels.swift")
        let authenticateBody = try sourceSlice(
            from: "public func authenticate() async throws",
            to: "private func performHandshake(",
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

    func testP2PControlAdvertiserPreservesBonjourPeerToPeerRoutes() throws {
        let center = try readSource("Sources/SkyBridgeCore/DeviceDiscovery/DiscoveryOrchestrator.swift")
        let p2p = try readSource("Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift")

        XCTAssertTrue(center.contains("includePeerToPeer: Bool = true"))
        XCTAssertTrue(center.contains("parameters.includePeerToPeer = includePeerToPeer"))
        XCTAssertTrue(center.contains("peerToPeer=\\(includePeerToPeer"))
        XCTAssertTrue(center.contains("BonjourInteropContract.makeCanonicalAdvertisementTXT("))
        XCTAssertTrue(center.contains("platform: .macOS"))
        XCTAssertTrue(center.contains("role: .control"))
        XCTAssertFalse(center.contains("LocalNetworkAdvertisementAddressProvider.attachAddressTXT"))
        XCTAssertFalse(center.contains("record[\"skybridgePort\"]"))
        XCTAssertFalse(center.contains("record[\"controlPort\"]"))
        XCTAssertTrue(
            p2p.contains("includePeerToPeer: true"),
            "The shipping P2P listener must remain reachable through resolved Bonjour/AWDL routes when peers do not share an infrastructure-LAN address."
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
    func testLegacyTXTPortAliasesRemainServiceTypeAwareInputOnly() {
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
            P2PDiscoveryBonjourPolicy.advertisedServicePort(
                from: txt,
                serviceType: BonjourInteropContract.legacyFileTransferServiceType
            ),
            8080
        )
        XCTAssertEqual(
            P2PDiscoveryBonjourPolicy.advertisedServicePort(
                from: txt,
                serviceType: BonjourInteropContract.legacyRemoteControlServiceType
            ),
            5901
        )
    }

    func testTCPConnectorNeverTreatsUDPAdvertisementAsDialRoute() {
        XCTAssertEqual(
            P2PDiscoveryBonjourPolicy.normalizedConnectableServiceTypes(
                from: ["_skybridge._udp", "_skybridge._tcp"]
            ),
            ["_skybridge._tcp"]
        )
        XCTAssertNil(
            P2PDiscoveryBonjourPolicy.tcpControlPort(
                from: ["_skybridge._udp": 60_001]
            )
        )
        XCTAssertEqual(
            P2PDiscoveryBonjourPolicy.tcpControlPort(
                from: ["_skybridge._udp": 60_001, "_skybridge._tcp": 9_527]
            ),
            9_527
        )
        XCTAssertNil(
            P2PDiscoveryBonjourPolicy.tcpControlPort(
                from: ["_skybridge._tcp": 0]
            )
        )
        XCTAssertNil(
            P2PDiscoveryBonjourPolicy.tcpControlPort(
                from: ["_skybridge._tcp": 65_536]
            )
        )
    }

    func testRemotePresentationPreservesIPadAndUnknownPlatformTruth() {
        XCTAssertEqual(
            P2PDeviceType.remoteType(
                platformName: "iPadOS",
                modelName: "iPad Pro 11-inch (M4)"
            ),
            .iPadOS
        )
        XCTAssertEqual(
            P2PDeviceType.remoteType(platformName: nil, modelName: "iPhone17,1"),
            .iOS
        )
        XCTAssertEqual(
            P2PDeviceType.remoteType(platformName: "futureOS", modelName: "Device99,1"),
            .unknown
        )
    }

    func testDiscoveryPreservesRemotePresentationThroughMergeAndHydration() throws {
        let discovery = try readSource("Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift")
        let advertiser = try readSource(
            "Sources/SkyBridgeCore/DeviceDiscovery/DiscoveryOrchestrator.swift"
        )

        XCTAssertTrue(discovery.contains("platformName: deviceInfo.platform"))
        XCTAssertTrue(discovery.contains("osVersion: deviceInfo.osVersion"))
        XCTAssertTrue(discovery.contains("modelName: deviceInfo.model"))
        XCTAssertTrue(discovery.contains("chip: deviceInfo.chip"))
        XCTAssertTrue(discovery.contains("existing.platformName = deviceInfo.platform ?? existing.platformName"))
        XCTAssertTrue(discovery.contains("existing.remoteVideoFormats.formUnion"))
        XCTAssertTrue(discovery.contains("platformName: dd.platformName"))
        XCTAssertTrue(discovery.contains("remoteVideoFormats: dd.remoteVideoFormats"))
        XCTAssertTrue(advertiser.contains("platform: .macOS"))
        XCTAssertTrue(advertiser.contains("role: .control"))
        XCTAssertFalse(advertiser.contains("localPresentation"))
    }

    func testConnectableNotificationSelfFilterNeverUsesDisplayNameAsIdentity() {
        let remote = P2PDevice(
            id: "remote-device-id",
            name: "Shared Device Name",
            type: .iPadOS,
            address: "192.0.2.20",
            port: 9_527,
            osVersion: "27.0",
            capabilities: [],
            publicKey: Data(),
            lastSeen: Date()
        )

        let aliasedRemote = P2PDevice(
            id: remote.deviceId,
            name: remote.name,
            type: remote.type,
            address: remote.address,
            port: remote.port,
            osVersion: remote.osVersion,
            capabilities: remote.capabilities,
            publicKey: remote.publicKey,
            lastSeen: remote.lastSeen,
            persistentDeviceId: "persistent-remote-id"
        )
        XCTAssertTrue(
            P2PNetworkManager.shouldSuppressConnectableNotification(
                for: aliasedRemote,
                localProtocolDeviceId: "PERSISTENT-REMOTE-ID"
            )
        )
        XCTAssertTrue(
            P2PNetworkManager.shouldSuppressConnectableNotification(
                for: remote,
                localProtocolDeviceId: "REMOTE-DEVICE-ID"
            )
        )
        XCTAssertFalse(
            P2PNetworkManager.shouldSuppressConnectableNotification(
                for: remote,
                localProtocolDeviceId: "different-local-id"
            )
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

    func testP2PDiscoveryServiceIsTheOnlyControlAdvertisementOwner() throws {
        let manager = try readSource("Sources/SkyBridgeCore/DeviceDiscovery/DeviceDiscoveryManager.swift")
        let optimized = try readSource("Sources/SkyBridgeCore/DeviceDiscovery/DeviceDiscoveryManagerOptimized.swift")
        let p2p = try readSource("Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift")
        let center = try readSource("Sources/SkyBridgeCore/DeviceDiscovery/DiscoveryOrchestrator.swift")

        XCTAssertFalse(manager.contains("ServiceAdvertiserCenter.shared.startAdvertising("))
        XCTAssertFalse(manager.contains("ServiceAdvertiserCenter.shared.stopAdvertising("))
        XCTAssertFalse(optimized.contains("ServiceAdvertiserCenter.shared.startAdvertising("))
        XCTAssertFalse(optimized.contains("ServiceAdvertiserCenter.shared.stopAdvertising("))
        XCTAssertTrue(p2p.contains("owner: Self.controlAdvertisementOwner"))
        XCTAssertTrue(center.contains("case ownerConflict(serviceType: String"))
        XCTAssertTrue(center.contains("try validateOwner("))
        XCTAssertTrue(center.contains("startOperations[serviceType]"))
        XCTAssertTrue(center.contains("current == requested"))
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
            p2pSource.contains("liveBonjourEndpointAttemptsAwaitingHydration(") &&
            p2pSource.contains("ApplePeerConnectivityPolicy.match(") &&
            p2pSource.contains("provenance: .liveBrowser") &&
            p2pSource.contains("if requiresLiveAppleRoute {\n            freshBonjourHostFallbackEndpoints = []") &&
            p2pSource.contains("} else if !bonjourEndpointAttempts.isEmpty {\n            endpointAttempts.append(contentsOf: bonjourEndpointAttempts)\n            endpointAttempts.append(contentsOf: freshBonjourHostFallbackEndpoints)\n            endpointAttempts.append(contentsOf: hostFallbackEndpoints)") &&
            p2pSource.contains("reason=no_live_control_route") &&
            !p2pSource.contains("interface: nil"),
            "Apple LAN connects must use authority-bound endpoints from the current browser generation and must never reconstruct an interface-less Bonjour route from persisted presentation metadata."
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
        let outboundConnectionWaitBody = try sourceSlice(
            from: "private func waitForConnection(",
            to: "// MARK: - 辅助方法：名称 / 网络信息解析",
            in: p2pSource
        )

        XCTAssertTrue(makeConnectionBody.contains("params.includePeerToPeer = Self.shouldIncludePeerToPeer(for: endpoint)"))
        XCTAssertFalse(makeConnectionBody.contains("params.includePeerToPeer = true"))
        XCTAssertTrue(
            makeConnectionBody.contains("applyRouteOwnership(") &&
                p2pSource.contains("parameters.requiredInterface = observedInterface"),
            "A live Bonjour endpoint must retain the NWInterface observed by the same browser result."
        )
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
            bootstrapWaitBody.contains("case .failed(let error):") &&
            bootstrapWaitBody.contains("connection.currentPath") &&
            bootstrapWaitBody.contains("NetworkFrameworkLocalNetworkPermissionClassifier.isDenied(") &&
            p2pSource.contains("reason=local-network-permission-denied") &&
            bootstrapWaitBody.contains("P2PDiscoveryError.localNetworkPermissionDenied"),
            "Strict-PQC bootstrap must fail fast when Network.framework reports Local Network privacy denial, instead of collapsing the app-side authorization failure into a generic timeout."
        )
        XCTAssertTrue(
            outboundConnectionWaitBody.contains("case .waiting(let error):") &&
            outboundConnectionWaitBody.contains("NetworkFrameworkLocalNetworkPermissionClassifier.isDenied(") &&
            outboundConnectionWaitBody.contains("P2PDiscoveryError.localNetworkPermissionDenied"),
            "Authenticated outbound P2P dials must preserve the same Local Network privacy diagnosis after strict-PQC preflight has already succeeded."
        )
    }

    func testRemoteControlServerBoundsPreHandshakeInspectionAndPreservesHandoffBytes() throws {
        let server = try readSource("Sources/SkyBridgeCore/RemoteControl/RemoteControlServer.swift")
        let manager = try readSource("Sources/SkyBridgeCore/RemoteControl/RemoteControlManager.swift")
        let harness = try readSource("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/App/Smoke/LocalP2PSmokeHarness.swift")

        XCTAssertTrue(server.contains("SKYBRIDGE_REMOTE_ROUTE_PROBE_V1"))
        XCTAssertTrue(server.contains("probe=remote-route-preflight"))
        XCTAssertTrue(server.contains("receiveInitialConnectionBytes("))
        XCTAssertTrue(server.contains("RemoteControlInboundAdmission"))
        XCTAssertTrue(server.contains("maximumConnections: Int = 32"))
        XCTAssertTrue(server.contains("maximumConnectionsPerEndpoint: Int = 4"))
        XCTAssertTrue(server.contains("inboundAdmission.release(admissionLease)"))
        XCTAssertTrue(
            server.contains("let handoffConnection = connection")
                && server.contains("let handoffData = initialData")
                && server.contains("connection: handoffConnection,\n                        initialData: handoffData"),
            "Server-side first-byte sniffing must transfer real handshake bytes into RemoteControlManager instead of consuming MessageA."
        )

        XCTAssertTrue(manager.contains("initialData: Data? = nil"))
        XCTAssertTrue(manager.contains("var pendingInitialData = initialData"))
        XCTAssertTrue(manager.contains("processInboundRemoteEventChunk("))

        XCTAssertFalse(harness.contains("remoteControlRoutePreflightProbePayload"))
        XCTAssertFalse(harness.contains("control-route-preflight"))
        XCTAssertTrue(harness.contains("liveBonjourServiceEndpoints("))
        XCTAssertTrue(harness.contains("liveBonjourControlEndpoints: liveEndpoints"))
        XCTAssertTrue(harness.contains("preferredInterface="))
    }

    func testP2PConnectCancellationAndReadinessHandlersAreLifecycleBound() throws {
        let p2pSource = try readSource("Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift")
        let networkManagerSource = try readSource("Sources/SkyBridgeCore/P2P/P2PNetworkManager.swift")
        let bootstrapExchange = try sourceSlice(
            from: "private func exchangeBootstrapControlMessage(",
            to: "private func waitForBootstrapControlConnection",
            in: p2pSource
        )
        let bootstrapWait = try sourceSlice(
            from: "private func waitForBootstrapControlConnection(",
            to: "private func sendBootstrapFrame",
            in: p2pSource
        )
        let activeWait = try sourceSlice(
            from: "private func waitForConnection(",
            to: "// MARK: - 辅助方法",
            in: p2pSource
        )

        XCTAssertTrue(bootstrapExchange.contains("try Task.checkCancellation()"))
        XCTAssertTrue(bootstrapExchange.contains("error is CancellationError || Task.isCancelled"))
        XCTAssertTrue(bootstrapExchange.contains("throw CancellationError()"))
        XCTAssertTrue(bootstrapWait.contains("withTaskCancellationHandler"))
        XCTAssertTrue(bootstrapWait.contains("cancellationHandle.cancel(connection: connection)"))
        XCTAssertTrue(p2pSource.contains("private var outboundConnectionAttemptIds: [String: UUID]"))
        XCTAssertTrue(p2pSource.contains("guard connections[deviceKey] === connection"))
        XCTAssertTrue(activeWait.contains("[weak self, weak connection] terminalState"))
        XCTAssertTrue(networkManagerSource.contains("[weak connection, weak p2p] state"))
        XCTAssertTrue(networkManagerSource.contains("connection.stateUpdateHandler = nil"))
    }

    func testP2PSmokeConnectionPathClassificationRejectsAttachedAndLinkLocalRoutes() throws {
        XCTAssertEqual(
            P2PDiscoveryService.smokeConnectionPathClassification(
                interfaceTypes: ["wifi"],
                interfaceNames: ["en0"],
                pathDescription: "satisfied interface en0"
            ),
            .init(routeClass: "wifi", attached: false, linkLocal: false)
        )
        XCTAssertEqual(
            P2PDiscoveryService.smokeConnectionPathClassification(
                interfaceTypes: ["other"],
                interfaceNames: ["awdl0"],
                pathDescription: "satisfied interface awdl0 local fe80::1234"
            ),
            .init(routeClass: "awdl", attached: false, linkLocal: false)
        )
        XCTAssertEqual(
            P2PDiscoveryService.smokeConnectionPathClassification(
                interfaceTypes: ["wiredEthernet"],
                interfaceNames: ["en9"],
                pathDescription: "satisfied interface en9 local 169.254.8.2"
            ),
            .init(routeClass: "attached", attached: true, linkLocal: true)
        )
        XCTAssertEqual(
            P2PDiscoveryService.smokeConnectionPathClassification(
                interfaceTypes: ["other"],
                interfaceNames: ["en9"],
                pathDescription: "satisfied interface en9"
            ).routeClass,
            "attached"
        )

        let source = try readSource("Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift")
        let activeWait = try sourceSlice(
            from: "private func waitForConnection(",
            to: "// MARK: - 辅助方法",
            in: source
        )
        XCTAssertTrue(activeWait.contains("Self.appendSmokeConnectionPathEvidence("))
        XCTAssertTrue(source.contains("p2p-connect-plan dialRef="))
        XCTAssertTrue(source.contains("p2p-connection-ready-path dialRef="))
        XCTAssertTrue(source.contains("usedInterfaceTypes="))
        XCTAssertTrue(source.contains("usedInterfaceNames="))
        XCTAssertTrue(source.contains("routeClass=\\(classification.routeClass)"))
    }

    func testAdvertisingReadinessObserversCannotCancelSharedListener() throws {
        let source = try readSource("Sources/SkyBridgeCore/DeviceDiscovery/DiscoveryOrchestrator.swift")
        let waitBody = try sourceSlice(
            from: "private func waitForAdvertisingReady(",
            to: "private func cancelRecord(",
            in: source
        )

        XCTAssertTrue(waitBody.contains("cancelRecordOnFailure: Bool = false"))
        XCTAssertTrue(waitBody.contains("if cancelRecordOnFailure"))
        XCTAssertTrue(
            source.contains("token: token,\n            cancelRecordOnFailure: true"),
            "Only the listener creator may tear down its record when startup fails."
        )
        XCTAssertTrue(
            source.contains("public func waitUntilReady(")
                && source.contains("return try await waitForAdvertisingReady("),
            "Health observers must use the non-owning readiness path."
        )
    }

    func testNetServiceResolutionUsesBoundedCancellablePermitHandoffAndSingleFlight() throws {
        let source = try readSource("Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift")
        let limiter = try sourceSlice(
            from: "actor NetServiceResolveLimiter",
            to: "private struct NetServiceResolvedEndpoint",
            in: source
        )

        XCTAssertTrue(limiter.contains("maximumWaiters: Int = 64"))
        XCTAssertTrue(limiter.contains("withTaskCancellationHandler"))
        XCTAssertTrue(limiter.contains("waiter.cancel()"))
        XCTAssertTrue(limiter.contains("removeWaiter(id: waiter.id)"))
        XCTAssertTrue(source.contains("final class NetServiceResolvePermitWaiter"))
        XCTAssertTrue(limiter.contains("Direct permit handoff"))
        XCTAssertFalse(
            limiter.contains("waiter.resume()\n            }\n            inFlight += 1"),
            "A resumed waiter must inherit the released permit instead of incrementing past the limit."
        )
        XCTAssertTrue(source.contains("maximumTXTResolveCooldownEntries = 256"))
        XCTAssertTrue(source.contains("if let owner = netServiceResolveTasks[route]"))
        XCTAssertTrue(source.contains("owner.ticket.stableDeviceIdentity == stableDeviceIdentity"))
        XCTAssertTrue(source.contains("discoveryHydrationGenerationState.accepts("))
        XCTAssertTrue(source.contains("cancelNetServiceResolveTasks()"))
    }

    func testIOSDiscoveryAndReconnectWorkAreBoundedAndCancellationOwned() throws {
        let discovery = try readSource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/DeviceDiscoveryManager.swift"
        )
        XCTAssertTrue(discovery.contains("maximumCachedDevices = 128"))
        XCTAssertTrue(discovery.contains("maximumEndpointMappings = 1_024"))
        XCTAssertTrue(discovery.contains("maximumAliasesPerDevice = 32"))
        XCTAssertTrue(discovery.contains("removeCachedDiscoveryDevice("))
        XCTAssertTrue(discovery.contains("pruneDiscoveryReverseIndexes()"))
        XCTAssertFalse(
            discovery.contains("try? await Task.sleep(for: .milliseconds(250))"),
            "Cancelling a debounced publish must not immediately execute stale work."
        )

        let p2p = try readSource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )
        XCTAssertTrue(p2p.contains("maximumInFlightConnectWaitersPerPeer = 32"))
        XCTAssertTrue(p2p.contains("withTaskCancellationHandler"))
        XCTAssertTrue(p2p.contains("reconnectTaskTokens[deviceId] == token"))
        XCTAssertTrue(p2p.contains("pathRecoveryTaskTokens[deviceId] == token"))
        XCTAssertTrue(p2p.contains("!self.userInitiatedDisconnects.contains(deviceId)"))
        XCTAssertFalse(
            p2p.contains("try? await Task.sleep(for: .seconds(delay))"),
            "A cancelled reconnect timer must return instead of initiating a ghost connection."
        )
        XCTAssertTrue(p2p.contains("p2p-connect-attempt dialRef="))
    }

    func testCentralAdvertiserBindsHealthAndInboundConnectionsToExactRegistrationLease() throws {
        let source = try readSource("Sources/SkyBridgeCore/DeviceDiscovery/DiscoveryOrchestrator.swift")
        let inbound = try sourceSlice(
            from: "private func handleNewConnection(",
            to: "private func waitForAdvertisingReady(",
            in: source
        )
        XCTAssertTrue(inbound.contains("record.token == token"))
        XCTAssertTrue(inbound.contains("record.listener === listener"))
        XCTAssertTrue(inbound.contains("record.state == .ready"))
        XCTAssertTrue(inbound.contains("connection.cancel()"))

        let listenerState = try sourceSlice(
            from: "private func handleListenerStateUpdate(",
            to: "private func handleServiceRegistrationUpdate(",
            in: source
        )
        XCTAssertTrue(listenerState.contains("record.readinessGate.observeSocketUnavailable()"))
        XCTAssertTrue(listenerState.contains("record.readinessHandler?(false)"))

        let registration = try sourceSlice(
            from: "private func handleServiceRegistrationUpdate(",
            to: "private func handleNewConnection(",
            in: source
        )
        XCTAssertTrue(registration.contains("record.readinessGate.observeRegistrationRemoved("))
        XCTAssertTrue(registration.contains("record.registrationEndpoints.isEmpty"))
        XCTAssertTrue(registration.contains("record.readinessHandler?(false)"))
    }

    func testDedicatedMacListenersCommitExactPublicationBeforeStartupReturns() throws {
        for relativePath in [
            "Sources/SkyBridgeCore/FileTransfer/FileTransferListenerService.swift",
            "Sources/SkyBridgeCore/RemoteControl/RemoteControlServer.swift"
        ] {
            let source = try readSource(relativePath)
            let commitCall = try XCTUnwrap(source.range(of: "guard self.commitListenerStartup("))
            let continuation = try XCTUnwrap(
                source.range(
                    of: "continuation.resume(returning: port)",
                    range: commitCall.upperBound..<source.endIndex
                )
            )
            XCTAssertLessThan(
                commitCall.lowerBound,
                continuation.lowerBound,
                "\(relativePath) must atomically publish the exact listener before waking start()"
            )

            let commit = try sourceSlice(
                from: "private func commitListenerStartup(",
                to: "private func finishStartTask(",
                in: source
            )
            XCTAssertTrue(commit.contains("listenerGeneration == generation"))
            XCTAssertTrue(commit.contains("pendingListener === candidate"))
            XCTAssertTrue(commit.contains("listener = candidate"))
            XCTAssertTrue(
                commit.contains("isBonjourPublished = true")
                    || commit.contains("bonjourPublished = true")
            )
            XCTAssertTrue(commit.contains("ServiceEndpointRegistry.shared.set"))
        }
    }

    func testOptimizedDiscoveryUsesResolvedSRVEndpointInsteadOfTXTOrDomainAsPort() throws {
        let source = try readSource(
            "Sources/SkyBridgeCore/DeviceDiscovery/DeviceDiscoveryManagerOptimized.swift"
        )
        let resolver = try sourceSlice(
            from: "private func extractNetworkInfoAsync(",
            to: "private func publishHydratedPrimaryControlService(",
            in: source
        )
        XCTAssertTrue(resolver.contains("NetService("))
        XCTAssertTrue(resolver.contains("resolveBonjourServiceOnMain("))
        XCTAssertTrue(resolver.contains("return (resolved.ipv4, resolved.ipv6, resolved.port)"))
        XCTAssertTrue(resolver.contains("endpointType.caseInsensitiveCompare(serviceType)"))
        XCTAssertFalse(resolver.contains("Int(domain)"))
        XCTAssertFalse(resolver.contains("parsePort("))
        XCTAssertFalse(resolver.contains("transferPort"))
        XCTAssertFalse(resolver.contains("remoteControlPort"))
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
