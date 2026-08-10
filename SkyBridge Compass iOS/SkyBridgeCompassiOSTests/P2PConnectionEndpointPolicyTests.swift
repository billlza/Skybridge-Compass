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

    func testRuntimeControlRouteRequiresTheExactLiveBonjourEndpoint() throws {
        let device = skybridgeDevice(ipAddress: "192.168.1.20")
        let liveEndpoint = NWEndpoint.service(
            name: "Studio MacBook Pro",
            type: DiscoveryServiceType.skybridge.rawValue,
            domain: "local.",
            interface: nil
        )

        XCTAssertTrue(
            P2PConnectionEndpointPolicy.connectionEndpointCandidates(
                for: device,
                liveBonjourControlEndpoints: []
            ).isEmpty,
            "Persisted DNS-SD fields must not manufacture a live route without its browser endpoint."
        )
        XCTAssertEqual(
            P2PConnectionEndpointPolicy.connectionEndpointCandidates(
                for: device,
                liveBonjourControlEndpoints: [liveEndpoint]
            ),
            [liveEndpoint]
        )
        XCTAssertTrue(
            P2PConnectionEndpointPolicy.connectionEndpointCandidates(
                for: device,
                liveBonjourControlEndpoints: [
                    .service(
                        name: "Studio MacBook Pro",
                        type: DiscoveryServiceType.skybridge.rawValue,
                        domain: "other.local.",
                        interface: nil
                    )
                ]
            ).isEmpty,
            "A live endpoint from another DNS-SD route must not be rebound to this device."
        )
    }

    func testExactAggregateRouteRemainsEligibleAlongsideSameIdentityNameCollision() throws {
        var collisionSelectedDevice = skybridgeDevice(ipAddress: nil)
        collisionSelectedDevice.bonjourServiceName = "Studio MacBook Pro (2)"
        let liveEndpoints: [NWEndpoint] = [
            .service(
                name: "Studio MacBook Pro",
                type: DiscoveryServiceType.skybridge.rawValue,
                domain: "local.",
                interface: nil
            ),
            .service(
                name: "Studio MacBook Pro (2)",
                type: DiscoveryServiceType.skybridge.rawValue,
                domain: "local.",
                interface: nil
            )
        ]

        let eligible = P2PConnectionEndpointPolicy.connectionEndpointCandidates(
            for: collisionSelectedDevice,
            liveBonjourControlEndpoints: liveEndpoints
        )

        XCTAssertEqual(eligible.count, 1)
        XCTAssertLessThan(eligible.count, liveEndpoints.count)
        try assertServiceEndpoint(
            eligible[0],
            name: "Studio MacBook Pro (2)",
            domain: "local."
        )
    }

    func testLiveBonjourRoutePreferenceTriesAWDLBeforeInfrastructureWiFi() {
        XCTAssertLessThan(
            DeviceDiscoveryManager.liveBonjourInterfacePriority(interfaceName: "awdl0"),
            DeviceDiscoveryManager.liveBonjourInterfacePriority(interfaceName: "en0")
        )
        XCTAssertLessThan(
            DeviceDiscoveryManager.liveBonjourInterfacePriority(interfaceName: "en0"),
            DeviceDiscoveryManager.liveBonjourInterfacePriority(interfaceName: nil)
        )
    }

    func testTXTAddressAndPortNeverPrecedeResolvedBonjourService() throws {
        let endpoints = P2PConnectionEndpointPolicy.connectionEndpointCandidates(
            for: skybridgeDevice(ipAddress: "192.168.1.20")
        )

        XCTAssertEqual(endpoints.count, 1)
        try assertServiceEndpoint(endpoints[0], name: "Studio MacBook Pro", domain: "local.")
    }

    func testBonjourServiceIsTheOnlyActionableDiscoveryEndpoint() throws {
        let endpoints = P2PConnectionEndpointPolicy.connectionEndpointCandidates(
            for: skybridgeDevice(ipAddress: "192.168.1.20")
        )

        XCTAssertEqual(endpoints.count, 1)
        try assertServiceEndpoint(endpoints[0], name: "Studio MacBook Pro", domain: "local.")
    }

    func testBonjourServiceDoesNotDependOnDiagnosticControlPort() throws {
        let missingPortEndpoints = P2PConnectionEndpointPolicy.connectionEndpointCandidates(
            for: skybridgeDevice(ipAddress: "192.168.1.20", portMap: [:])
        )

        XCTAssertEqual(missingPortEndpoints.count, 1)
        try assertServiceEndpoint(missingPortEndpoints[0], name: "Studio MacBook Pro", domain: "local.")

        let zeroPortEndpoints = P2PConnectionEndpointPolicy.connectionEndpointCandidates(
            for: skybridgeDevice(
                ipAddress: "192.168.1.20",
                portMap: [DiscoveryServiceType.skybridge.rawValue: 0]
            )
        )

        XCTAssertEqual(zeroPortEndpoints.count, 1)
        try assertServiceEndpoint(zeroPortEndpoints[0], name: "Studio MacBook Pro", domain: "local.")
        XCTAssertNil(
            P2PConnectionEndpointPolicy.resolvedSkyBridgeControlPort(
                for: skybridgeDevice(ipAddress: "192.168.1.20", portMap: [:])
            )
        )
    }

    func testUDPOnlyAdvertisementNeverProducesATCPControlCandidate() {
        let udpOnly = DiscoveredDevice(
            id: "bonjour:Studio MacBook Pro@local.",
            name: "Studio MacBook Pro",
            bonjourServiceName: "Studio MacBook Pro",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "26.5",
            ipAddress: "192.168.1.20",
            bonjourServiceType: DiscoveryServiceType.skybridgeQUIC.rawValue,
            bonjourServiceDomain: "local.",
            services: [DiscoveryServiceType.skybridgeQUIC.rawValue],
            portMap: [DiscoveryServiceType.skybridgeQUIC.rawValue: 9528]
        )

        XCTAssertNil(P2PConnectionEndpointPolicy.resolvedSkyBridgeControlPort(for: udpOnly))
        XCTAssertTrue(
            P2PConnectionEndpointPolicy.connectionEndpointCandidates(for: udpOnly).isEmpty,
            "UDP/QUIC evidence must not be dialled with NWParameters.tcp"
        )
    }

    func testTCPPortRemainsDiagnosticWhenTCPAndUDPAdvertisementsCoexist() throws {
        let dualTransport = DiscoveredDevice(
            id: "bonjour:Studio MacBook Pro@local.",
            name: "Studio MacBook Pro",
            bonjourServiceName: "Studio MacBook Pro",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "26.5",
            ipAddress: "192.168.1.20",
            bonjourServiceType: DiscoveryServiceType.skybridge.rawValue,
            bonjourServiceDomain: "local.",
            services: [
                DiscoveryServiceType.skybridge.rawValue,
                DiscoveryServiceType.skybridgeQUIC.rawValue
            ],
            portMap: [
                DiscoveryServiceType.skybridge.rawValue: 9527,
                DiscoveryServiceType.skybridgeQUIC.rawValue: 9528
            ]
        )

        XCTAssertEqual(
            P2PConnectionEndpointPolicy.resolvedSkyBridgeControlPort(for: dualTransport),
            9527
        )
        let endpoints = P2PConnectionEndpointPolicy.connectionEndpointCandidates(
            for: dualTransport
        )
        XCTAssertEqual(endpoints.count, 1)
        try assertServiceEndpoint(endpoints[0], name: "Studio MacBook Pro", domain: "local.")
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
        XCTAssertTrue(
            endpoints.isEmpty,
            "A host identity plus a TXT-derived port is diagnostic evidence, not an actionable route"
        )
    }

    func testStrongIdentityWithTXTAddressAndPortCannotManufactureControlRoute() {
        let diagnosticOnly = DiscoveredDevice(
            id: "id:e0715a9a-d0d3-47e6-b353-de0a30293e1f",
            name: "Studio MacBook Pro",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "26.5",
            ipAddress: "192.168.1.20",
            services: [DiscoveryServiceType.skybridge.rawValue],
            portMap: [DiscoveryServiceType.skybridge.rawValue: 9527]
        )

        XCTAssertEqual(
            P2PConnectionEndpointPolicy.resolvedSkyBridgeControlPort(for: diagnosticOnly),
            9527
        )
        XCTAssertTrue(
            P2PConnectionEndpointPolicy.connectionEndpointCandidates(
                for: diagnosticOnly
            ).isEmpty
        )
    }

    func testCompleteBonjourTupleIsAProvenanceBoundDirectLANRefreshCandidate() throws {
        let endpoint = try XCTUnwrap(
            P2PConnectionEndpointPolicy.connectionEndpointCandidates(
                for: skybridgeDevice(ipAddress: "192.168.1.20")
            ).first
        )

        XCTAssertEqual(
            P2PConnectionEndpointPolicy.signedLANRefreshEndpointClass(endpoint),
            "bonjour-service"
        )
        try assertServiceEndpoint(endpoint, name: "Studio MacBook Pro", domain: "local.")
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

    func testPartialSiblingServiceWaitsForControlRouteWithoutSynthesizingTCP() {
        let partialTransferRoute = DiscoveredDevice(
            id: "id:e0715a9a-d0d3-47e6-b353-de0a30293e1f",
            name: "Studio MacBook Pro",
            bonjourServiceName: "Studio MacBook Pro",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "26.5",
            bonjourServiceType: DiscoveredDevice.fileTransferServiceType,
            bonjourServiceDomain: "local.",
            services: [DiscoveredDevice.fileTransferServiceType],
            portMap: [DiscoveredDevice.fileTransferServiceType: 8080]
        )

        XCTAssertTrue(
            P2PConnectionEndpointPolicy.connectionEndpointCandidates(for: partialTransferRoute).isEmpty,
            "A transfer listener must never be dialled as the P2P control channel."
        )
        XCTAssertTrue(
            P2PConnectionEndpointPolicy.shouldAwaitSkyBridgeControlRoute(for: partialTransferRoute),
            "A strongly identified sibling Bonjour service should wait briefly for the matching control record."
        )
        XCTAssertFalse(
            P2PConnectionEndpointPolicy.shouldAwaitSkyBridgeControlRoute(
                for: skybridgeDevice(ipAddress: nil)
            )
        )

        let offlineIdentity = DiscoveredDevice(
            id: "id:e0715a9a-d0d3-47e6-b353-de0a30293e1f",
            name: "Studio MacBook Pro",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "26.5"
        )
        XCTAssertFalse(
            P2PConnectionEndpointPolicy.shouldAwaitSkyBridgeControlRoute(for: offlineIdentity),
            "A historical identity with no live Bonjour sibling route should still fail fast."
        )
        XCTAssertTrue(
            P2PConnectionEndpointPolicy.shouldAwaitSkyBridgeControlRoute(
                for: offlineIdentity,
                mode: .selectedDiscoveryTarget
            ),
            "A caller that just selected the strong identity from live discovery must tolerate aggregate-row hydration."
        )
    }

    func testPersistedPrimaryRouteWaitsOnlyUntilExactLiveEndpointReturns() {
        let persistedPrimary = DiscoveredDevice(
            id: "id:e0715a9a-d0d3-47e6-b353-de0a30293e1f",
            name: "Studio MacBook Pro",
            bonjourServiceName: "Studio MacBook Pro",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "26.5",
            bonjourServiceType: DiscoveryServiceType.skybridge.rawValue,
            bonjourServiceDomain: "local.",
            services: [DiscoveryServiceType.skybridge.rawValue],
            portMap: [DiscoveryServiceType.skybridge.rawValue: 9527]
        )
        let mismatchedEndpoint = NWEndpoint.service(
            name: "Studio MacBook Pro",
            type: DiscoveryServiceType.skybridge.rawValue,
            domain: "other.local.",
            interface: nil
        )
        let exactEndpoint = NWEndpoint.service(
            name: "Studio MacBook Pro",
            type: DiscoveryServiceType.skybridge.rawValue,
            domain: "local.",
            interface: nil
        )

        XCTAssertTrue(
            P2PConnectionEndpointPolicy.shouldAwaitSkyBridgeControlRoute(
                for: persistedPrimary,
                liveBonjourControlEndpoints: []
            )
        )
        XCTAssertTrue(
            P2PConnectionEndpointPolicy.shouldAwaitSkyBridgeControlRoute(
                for: persistedPrimary,
                liveBonjourControlEndpoints: [mismatchedEndpoint]
            ),
            "A live route from another DNS-SD domain must not release the wait."
        )
        XCTAssertFalse(
            P2PConnectionEndpointPolicy.shouldAwaitSkyBridgeControlRoute(
                for: persistedPrimary,
                liveBonjourControlEndpoints: [exactEndpoint]
            )
        )
    }

    @MainActor
    func testAuxiliaryRemoteRouteComesFromItsOwnLiveAdvertisementSnapshot() throws {
        let manager = DeviceDiscoveryManager.debugMakeIsolatedInstance()
        let stableID = "id:e0715a9a-d0d3-47e6-b353-de0a30293e1f"
        let primary = DiscoveredDevice(
            id: stableID,
            name: "Studio MacBook Pro",
            bonjourServiceName: "Studio Mac Control",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "27.0",
            bonjourServiceType: DiscoveryServiceType.skybridge.rawValue,
            bonjourServiceDomain: "control.local.",
            services: [DiscoveryServiceType.skybridge.rawValue],
            portMap: [DiscoveryServiceType.skybridge.rawValue: 9527]
        )
        let remote = DiscoveredDevice(
            id: stableID,
            name: primary.name,
            bonjourServiceName: "Studio Mac Remote",
            modelName: primary.modelName,
            platform: primary.platform,
            osVersion: primary.osVersion,
            bonjourServiceType: DiscoveryServiceType.skybridgeRemote.rawValue,
            bonjourServiceDomain: "remote.local.",
            services: [DiscoveryServiceType.skybridgeRemote.rawValue],
            portMap: [DiscoveryServiceType.skybridgeRemote.rawValue: 5901]
        )
        let remoteEndpoint = NWEndpoint.service(
            name: "Studio Mac Remote",
            type: DiscoveryServiceType.skybridgeRemote.rawValue,
            domain: "remote.local.",
            interface: nil
        )

        _ = manager.debugReplaceAdvertisementSnapshot(
            primary,
            endpointKey: "primary-route",
            serviceType: .skybridge
        )
        let aggregate = try XCTUnwrap(
            manager.debugReplaceAdvertisementSnapshot(
                remote,
                endpoint: remoteEndpoint,
                endpointKey: "remote-route",
                serviceType: .skybridgeRemote
            )
        )
        XCTAssertEqual(aggregate.bonjourServiceName, primary.bonjourServiceName)
        XCTAssertEqual(aggregate.bonjourServiceType, DiscoveryServiceType.skybridge.rawValue)

        let liveRemote = try XCTUnwrap(
            manager.liveBonjourAdvertisement(for: aggregate, serviceType: .skybridgeRemote)
        )
        XCTAssertEqual(liveRemote.bonjourServiceName, remote.bonjourServiceName)
        XCTAssertEqual(liveRemote.bonjourServiceDomain, remote.bonjourServiceDomain)
        XCTAssertEqual(liveRemote.remoteControlPort, 5901)

        let endpoint = try XCTUnwrap(
            manager.liveBonjourServiceEndpoint(for: aggregate, serviceType: .skybridgeRemote)
        )
        XCTAssertEqual(endpoint, remoteEndpoint)
        try assertServiceEndpoint(
            endpoint,
            name: "Studio Mac Remote",
            type: DiscoveryServiceType.skybridgeRemote.rawValue,
            domain: "remote.local."
        )

        _ = manager.debugRemoveAdvertisementSnapshot(
            endpointKey: "remote-route",
            deviceId: stableID,
            serviceType: .skybridgeRemote
        )
        XCTAssertNil(manager.liveBonjourAdvertisement(for: aggregate, serviceType: .skybridgeRemote))
        XCTAssertNil(manager.liveBonjourServiceEndpoint(for: aggregate, serviceType: .skybridgeRemote))
    }

    @MainActor
    func testPrimaryControlRouteAtomicallyReplacesAuxiliaryBonjourTuple() {
        let manager = DeviceDiscoveryManager.debugMakeIsolatedInstance()
        let auxiliary = DiscoveredDevice(
            id: "id:e0715a9a-d0d3-47e6-b353-de0a30293e1f",
            name: "Studio MacBook Pro",
            bonjourServiceName: "Studio MacBook Pro Transfer",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "26.5",
            bonjourServiceType: DiscoveredDevice.fileTransferServiceType,
            bonjourServiceDomain: "auxiliary.local.",
            services: [DiscoveredDevice.fileTransferServiceType],
            portMap: [DiscoveredDevice.fileTransferServiceType: 8080]
        )
        let primary = DiscoveredDevice(
            id: auxiliary.id,
            name: auxiliary.name,
            bonjourServiceName: "Studio MacBook Pro Control",
            modelName: auxiliary.modelName,
            platform: auxiliary.platform,
            osVersion: auxiliary.osVersion,
            bonjourServiceType: DiscoveryServiceType.skybridge.rawValue,
            bonjourServiceDomain: "control.local",
            services: [DiscoveryServiceType.skybridge.rawValue],
            portMap: [DiscoveryServiceType.skybridge.rawValue: 9527]
        )

        let primaryAfterAuxiliary = manager.debugMergeDiscoveryDevice(
            existing: auxiliary,
            update: primary
        )
        XCTAssertEqual(primaryAfterAuxiliary.bonjourServiceName, "Studio MacBook Pro Control")
        XCTAssertEqual(
            primaryAfterAuxiliary.bonjourServiceType,
            DiscoveryServiceType.skybridge.rawValue
        )
        XCTAssertEqual(primaryAfterAuxiliary.bonjourServiceDomain, "control.local.")
        XCTAssertEqual(
            primaryAfterAuxiliary.portMap[DiscoveryServiceType.skybridge.rawValue],
            9527
        )
        XCTAssertEqual(
            primaryAfterAuxiliary.portMap[DiscoveredDevice.fileTransferServiceType],
            8080
        )
        XCTAssertEqual(
            P2PConnectionEndpointPolicy.connectionEndpointCandidates(for: primaryAfterAuxiliary),
            [
                .service(
                    name: "Studio MacBook Pro Control",
                    type: DiscoveryServiceType.skybridge.rawValue,
                    domain: "control.local.",
                    interface: nil
                )
            ]
        )

        let auxiliaryAfterPrimary = manager.debugMergeDiscoveryDevice(
            existing: primaryAfterAuxiliary,
            update: auxiliary
        )
        XCTAssertEqual(auxiliaryAfterPrimary.bonjourServiceName, "Studio MacBook Pro Control")
        XCTAssertEqual(
            auxiliaryAfterPrimary.bonjourServiceType,
            DiscoveryServiceType.skybridge.rawValue
        )
        XCTAssertEqual(auxiliaryAfterPrimary.bonjourServiceDomain, "control.local.")
        XCTAssertEqual(
            auxiliaryAfterPrimary.portMap[DiscoveryServiceType.skybridge.rawValue],
            9527
        )
        XCTAssertEqual(
            auxiliaryAfterPrimary.portMap[DiscoveredDevice.fileTransferServiceType],
            8080
        )
        XCTAssertEqual(
            P2PConnectionEndpointPolicy.connectionEndpointCandidates(for: auxiliaryAfterPrimary),
            [
                .service(
                    name: "Studio MacBook Pro Control",
                    type: DiscoveryServiceType.skybridge.rawValue,
                    domain: "control.local.",
                    interface: nil
                )
            ]
        )
    }

    @MainActor
    func testChangedAdvertisementReplacesRevocableTXTState() throws {
        let manager = DeviceDiscoveryManager.debugMakeIsolatedInstance()
        var original = routeRemovalFixture()
        original.services = [DiscoveryServiceType.skybridge.rawValue]
        original.portMap = [DiscoveryServiceType.skybridge.rawValue: 9527]
        original.advertisedCapabilities = ["clipboard", "legacy_capability"]
        original.capabilities = ["clipboard", "legacy_capability"]

        _ = manager.debugReplaceAdvertisementSnapshot(
            original,
            endpointKey: "control-endpoint",
            serviceType: .skybridge
        )

        var replacement = original
        replacement.portMap = [:]
        replacement.advertisedCapabilities = ["clipboard"]
        replacement.capabilities = ["clipboard"]
        replacement.lastSeen = original.lastSeen.addingTimeInterval(1)
        let rebuilt = try XCTUnwrap(
            manager.debugReplaceAdvertisementSnapshot(
                replacement,
                endpointKey: "control-endpoint",
                serviceType: .skybridge,
                replacingEndpointKey: "control-endpoint"
            )
        )

        XCTAssertTrue(rebuilt.portMap.isEmpty)
        XCTAssertEqual(rebuilt.advertisedCapabilities, ["clipboard"])
        XCTAssertEqual(rebuilt.capabilities, ["clipboard"])
        XCTAssertFalse(rebuilt.capabilities.contains("legacy_capability"))
    }

    @MainActor
    func testRemovingPrimarySnapshotWithdrawsItsRoutePortAndCapabilities() throws {
        let manager = DeviceDiscoveryManager.debugMakeIsolatedInstance()
        var primary = routeRemovalFixture()
        primary.services = [DiscoveryServiceType.skybridge.rawValue]
        primary.portMap = [DiscoveryServiceType.skybridge.rawValue: 9527]
        primary.advertisedCapabilities = ["control_capability"]
        primary.capabilities = ["control_capability"]
        let transfer = DiscoveredDevice(
            id: primary.id,
            name: primary.name,
            bonjourServiceName: "Studio MacBook Pro Transfer",
            modelName: primary.modelName,
            platform: primary.platform,
            osVersion: primary.osVersion,
            bonjourServiceType: DiscoveredDevice.fileTransferServiceType,
            bonjourServiceDomain: "transfer.local.",
            services: [DiscoveredDevice.fileTransferServiceType],
            portMap: [DiscoveredDevice.fileTransferServiceType: 8080],
            advertisedCapabilities: ["transfer_capability"],
            capabilities: ["file", "file_transfer", "transfer_capability"]
        )

        _ = manager.debugReplaceAdvertisementSnapshot(
            primary,
            endpointKey: "primary-endpoint",
            serviceType: .skybridge
        )
        _ = manager.debugReplaceAdvertisementSnapshot(
            transfer,
            endpointKey: "transfer-endpoint",
            serviceType: .skybridgeTransfer
        )
        let remaining = try XCTUnwrap(
            manager.debugRemoveAdvertisementSnapshot(
                endpointKey: "primary-endpoint",
                deviceId: primary.id,
                serviceType: .skybridge
            )
        )

        XCTAssertEqual(remaining.bonjourServiceName, transfer.bonjourServiceName)
        XCTAssertEqual(remaining.bonjourServiceType, DiscoveredDevice.fileTransferServiceType)
        XCTAssertEqual(remaining.bonjourServiceDomain, "transfer.local.")
        XCTAssertEqual(remaining.services, [DiscoveredDevice.fileTransferServiceType])
        XCTAssertNil(remaining.portMap[DiscoveryServiceType.skybridge.rawValue])
        XCTAssertEqual(remaining.portMap[DiscoveredDevice.fileTransferServiceType], 8080)
        XCTAssertFalse(remaining.advertisedCapabilities.contains("control_capability"))
        XCTAssertTrue(remaining.advertisedCapabilities.contains("transfer_capability"))
        XCTAssertTrue(P2PConnectionEndpointPolicy.connectionEndpointCandidates(for: remaining).isEmpty)
    }

    @MainActor
    func testRemovingNewestSameServiceSnapshotRestoresRemainingAdvertisement() throws {
        let manager = DeviceDiscoveryManager.debugMakeIsolatedInstance()
        var first = routeRemovalFixture()
        first.services = [DiscoveryServiceType.skybridge.rawValue]
        first.portMap = [DiscoveryServiceType.skybridge.rawValue: 9527]
        first.advertisedCapabilities = ["first_route"]
        first.capabilities = ["first_route"]
        first.lastSeen = Date(timeIntervalSince1970: 1)
        var newest = first
        newest.portMap = [DiscoveryServiceType.skybridge.rawValue: 9627]
        newest.advertisedCapabilities = ["newest_route"]
        newest.capabilities = ["newest_route"]
        newest.lastSeen = Date(timeIntervalSince1970: 2)

        _ = manager.debugReplaceAdvertisementSnapshot(
            first,
            endpointKey: "control-interface-a",
            serviceType: .skybridge
        )
        let combined = try XCTUnwrap(
            manager.debugReplaceAdvertisementSnapshot(
                newest,
                endpointKey: "control-interface-b",
                serviceType: .skybridge
            )
        )
        XCTAssertEqual(combined.portMap[DiscoveryServiceType.skybridge.rawValue], 9627)
        XCTAssertEqual(Set(combined.advertisedCapabilities), ["first_route", "newest_route"])

        let restored = try XCTUnwrap(
            manager.debugRemoveAdvertisementSnapshot(
                endpointKey: "control-interface-b",
                deviceId: first.id,
                serviceType: .skybridge
            )
        )
        XCTAssertEqual(restored.portMap[DiscoveryServiceType.skybridge.rawValue], 9527)
        XCTAssertEqual(restored.advertisedCapabilities, ["first_route"])
        XCTAssertEqual(restored.capabilities, ["first_route"])
    }

    @MainActor
    func testPrimaryRemovalKeepsRouteWhileSameServiceHasAnotherLiveEndpoint() throws {
        let manager = DeviceDiscoveryManager.debugMakeIsolatedInstance()
        var oldAdvertisement = routeRemovalFixture()
        oldAdvertisement.lastSeen = Date(timeIntervalSince1970: 1)
        var liveAdvertisement = oldAdvertisement
        liveAdvertisement.lastSeen = Date(timeIntervalSince1970: 2)
        _ = manager.debugReplaceAdvertisementSnapshot(
            oldAdvertisement,
            endpointKey: "primary-old",
            serviceType: .skybridge
        )
        _ = manager.debugReplaceAdvertisementSnapshot(
            liveAdvertisement,
            endpointKey: "primary-live",
            serviceType: .skybridge
        )

        let retained = try XCTUnwrap(
            manager.debugRemoveAdvertisementSnapshot(
                endpointKey: "primary-old",
                deviceId: oldAdvertisement.id,
                serviceType: .skybridge
            )
        )

        XCTAssertEqual(retained.bonjourServiceName, liveAdvertisement.bonjourServiceName)
        XCTAssertEqual(retained.bonjourServiceType, DiscoveryServiceType.skybridge.rawValue)
        XCTAssertEqual(retained.bonjourServiceDomain, "control.local.")
        XCTAssertTrue(retained.services.contains(DiscoveryServiceType.skybridge.rawValue))
        XCTAssertEqual(retained.portMap[DiscoveryServiceType.skybridge.rawValue], 9527)
    }

    @MainActor
    func testPrimaryRemovalWithoutOwnerClearsRouteButKeepsAuxiliaryMetadata() throws {
        let manager = DeviceDiscoveryManager.debugMakeIsolatedInstance()
        var primary = routeRemovalFixture()
        primary.services = [DiscoveryServiceType.skybridge.rawValue]
        primary.portMap = [DiscoveryServiceType.skybridge.rawValue: 9527]
        let transfer = DiscoveredDevice(
            id: primary.id,
            name: primary.name,
            bonjourServiceName: "Studio MacBook Pro Transfer",
            modelName: primary.modelName,
            platform: primary.platform,
            osVersion: primary.osVersion,
            bonjourServiceType: DiscoveredDevice.fileTransferServiceType,
            bonjourServiceDomain: "transfer.local.",
            services: [DiscoveredDevice.fileTransferServiceType],
            portMap: [DiscoveredDevice.fileTransferServiceType: 8080],
            capabilities: ["file", "file_transfer"]
        )
        _ = manager.debugReplaceAdvertisementSnapshot(
            primary,
            endpointKey: "primary",
            serviceType: .skybridge
        )
        _ = manager.debugReplaceAdvertisementSnapshot(
            transfer,
            endpointKey: "transfer",
            serviceType: .skybridgeTransfer
        )

        let retained = try XCTUnwrap(
            manager.debugRemoveAdvertisementSnapshot(
                endpointKey: "primary",
                deviceId: primary.id,
                serviceType: .skybridge
            )
        )

        XCTAssertEqual(retained.bonjourServiceName, transfer.bonjourServiceName)
        XCTAssertEqual(retained.bonjourServiceType, DiscoveredDevice.fileTransferServiceType)
        XCTAssertEqual(retained.bonjourServiceDomain, "transfer.local.")
        XCTAssertFalse(retained.services.contains(DiscoveryServiceType.skybridge.rawValue))
        XCTAssertNil(retained.portMap[DiscoveryServiceType.skybridge.rawValue])
        XCTAssertTrue(retained.services.contains(DiscoveredDevice.fileTransferServiceType))
        XCTAssertEqual(retained.portMap[DiscoveredDevice.fileTransferServiceType], 8080)
    }

    @MainActor
    func testProtectedIdentityDropsWithdrawnPrimaryRouteAndCanBeRehydrated() throws {
        let manager = DeviceDiscoveryManager.debugMakeIsolatedInstance()
        var primaryOnly = routeRemovalFixture()
        primaryOnly.services = [DiscoveryServiceType.skybridge.rawValue]
        primaryOnly.portMap = [DiscoveryServiceType.skybridge.rawValue: 9527]
        _ = manager.debugReplaceAdvertisementSnapshot(
            primaryOnly,
            endpointKey: "primary",
            serviceType: .skybridge
        )

        let protectedRow = try XCTUnwrap(
            manager.debugRemoveAdvertisementSnapshot(
                endpointKey: "primary",
                deviceId: primaryOnly.id,
                serviceType: .skybridge,
                protectedIdentifiers: [primaryOnly.id],
                activeIdentifiers: [primaryOnly.id]
            )
        )
        XCTAssertEqual(protectedRow.id, primaryOnly.id)
        XCTAssertTrue(protectedRow.isConnected)
        XCTAssertTrue(protectedRow.services.isEmpty)
        XCTAssertTrue(protectedRow.portMap.isEmpty)
        XCTAssertNil(protectedRow.bonjourServiceName)
        XCTAssertNil(protectedRow.bonjourServiceType)
        XCTAssertNil(protectedRow.bonjourServiceDomain)

        let rehydrated = try XCTUnwrap(
            manager.debugReplaceAdvertisementSnapshot(
                primaryOnly,
                endpointKey: "primary-rehydrated",
                serviceType: .skybridge
            )
        )
        XCTAssertEqual(rehydrated.id, primaryOnly.id)
        XCTAssertEqual(rehydrated.bonjourServiceName, primaryOnly.bonjourServiceName)
        XCTAssertEqual(rehydrated.bonjourServiceType, DiscoveryServiceType.skybridge.rawValue)
        XCTAssertEqual(rehydrated.bonjourServiceDomain, "control.local.")
        XCTAssertEqual(rehydrated.portMap[DiscoveryServiceType.skybridge.rawValue], 9527)
    }

    @MainActor
    func testActiveConnectionMetadataNeverMixesPrimaryAndAuxiliaryRouteFields() {
        let primary = routeRemovalFixture()
        let auxiliary = DiscoveredDevice(
            id: primary.id,
            name: primary.name,
            bonjourServiceName: "Studio MacBook Pro Transfer",
            modelName: primary.modelName,
            platform: primary.platform,
            osVersion: primary.osVersion,
            bonjourServiceType: DiscoveredDevice.fileTransferServiceType,
            bonjourServiceDomain: "auxiliary.local.",
            services: [DiscoveredDevice.fileTransferServiceType],
            portMap: [DiscoveredDevice.fileTransferServiceType: 8080]
        )

        let primaryThenAuxiliary = P2PConnectionManager.instance
            .testMergeActiveConnectionMetadata(base: primary, update: auxiliary)
        XCTAssertEqual(primaryThenAuxiliary.bonjourServiceName, primary.bonjourServiceName)
        XCTAssertEqual(
            primaryThenAuxiliary.bonjourServiceType,
            DiscoveryServiceType.skybridge.rawValue
        )
        XCTAssertEqual(primaryThenAuxiliary.bonjourServiceDomain, "control.local.")

        let auxiliaryThenPrimary = P2PConnectionManager.instance
            .testMergeActiveConnectionMetadata(base: auxiliary, update: primary)
        XCTAssertEqual(auxiliaryThenPrimary.bonjourServiceName, primary.bonjourServiceName)
        XCTAssertEqual(
            auxiliaryThenPrimary.bonjourServiceType,
            DiscoveryServiceType.skybridge.rawValue
        )
        XCTAssertEqual(auxiliaryThenPrimary.bonjourServiceDomain, "control.local.")

        var auxiliaryWithPrimaryCapabilityEvidence = auxiliary
        auxiliaryWithPrimaryCapabilityEvidence.services.append(
            DiscoveryServiceType.skybridge.rawValue
        )
        auxiliaryWithPrimaryCapabilityEvidence.portMap[
            DiscoveryServiceType.skybridge.rawValue
        ] = 9527
        XCTAssertTrue(
            P2PConnectionEndpointPolicy.connectionEndpointCandidates(
                for: auxiliaryWithPrimaryCapabilityEvidence
            ).isEmpty,
            "Primary service evidence must not reinterpret an auxiliary DNS-SD tuple as a control route"
        )
    }

    @MainActor
    func testControlRouteWaitReadsCanonicalCacheBeforePublishedDiscoveryDebounce() async throws {
        let discoveryManager = DeviceDiscoveryManager.instance
        let originalState = discoveryManager.debugCaptureState()
        defer { discoveryManager.debugRestoreState(originalState) }
        let routeToken = UUID().uuidString.lowercased()
        let deviceId = "id:\(routeToken)"
        let transferServiceName = "Route Wait \(routeToken.prefix(8)) Transfer"
        let controlServiceName = "Route Wait \(routeToken.prefix(8)) Control"

        let partial = DiscoveredDevice(
            id: deviceId,
            name: controlServiceName,
            bonjourServiceName: transferServiceName,
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "26.5",
            bonjourServiceType: DiscoveredDevice.fileTransferServiceType,
            bonjourServiceDomain: "local.",
            services: [DiscoveredDevice.fileTransferServiceType],
            portMap: [DiscoveredDevice.fileTransferServiceType: 8080]
        )
        discoveryManager.debugSeedDiscoveryState(
            devices: [partial],
            lastActivity: Date(),
            endpointToDeviceId: ["transfer-endpoint": partial.id],
            liveBrowseEndpointKeysByServiceType: [
                .skybridgeTransfer: ["transfer-endpoint"]
            ]
        )

        let waitTask = Task { @MainActor in
            try await P2PConnectionManager.instance
                .testResolveConnectableDeviceAwaitingControlRoute(for: partial)
        }
        defer { waitTask.cancel() }
        let waitStartedAt = Date()
        try await Task.sleep(for: .milliseconds(100))

        let primary = DiscoveredDevice(
            id: partial.id,
            name: partial.name,
            bonjourServiceName: controlServiceName,
            modelName: partial.modelName,
            platform: partial.platform,
            osVersion: partial.osVersion,
            bonjourServiceType: DiscoveryServiceType.skybridge.rawValue,
            bonjourServiceDomain: "local.",
            services: [DiscoveryServiceType.skybridge.rawValue],
            portMap: [DiscoveryServiceType.skybridge.rawValue: 9527]
        )
        _ = discoveryManager.debugReplaceAdvertisementSnapshot(
            primary,
            endpointKey: "control-endpoint",
            serviceType: .skybridge
        )

        let resolved = try await waitTask.value
        XCTAssertLessThan(Date().timeIntervalSince(waitStartedAt), 2.0)
        XCTAssertEqual(resolved.bonjourServiceName, controlServiceName)
        XCTAssertEqual(resolved.bonjourServiceType, DiscoveryServiceType.skybridge.rawValue)
        XCTAssertFalse(
            P2PConnectionEndpointPolicy.connectionEndpointCandidates(
                for: resolved,
                liveBonjourControlEndpoints: discoveryManager.liveBonjourServiceEndpoints(
                    for: resolved,
                    serviceType: .skybridge
                )
            ).isEmpty
        )
    }

    @MainActor
    func testSelectedStrongDiscoveryTargetWaitsWithoutPartialBonjourMetadata() async throws {
        let discoveryManager = DeviceDiscoveryManager.instance
        let originalState = discoveryManager.debugCaptureState()
        defer { discoveryManager.debugRestoreState(originalState) }
        let routeToken = UUID().uuidString.lowercased()
        let deviceId = "id:\(routeToken)"
        let aggregateOnly = DiscoveredDevice(
            id: deviceId,
            name: "Aggregate Route \(routeToken.prefix(8))",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "27.0"
        )
        discoveryManager.debugSeedDiscoveryState(
            devices: [aggregateOnly],
            lastActivity: Date(),
            endpointToDeviceId: [:],
            liveBrowseEndpointKeysByServiceType: [:]
        )

        let waitTask = Task { @MainActor in
            try await P2PConnectionManager.instance
                .testResolveConnectableDeviceAwaitingControlRoute(
                    for: aggregateOnly,
                    mode: .selectedDiscoveryTarget
                )
        }
        defer { waitTask.cancel() }
        let waitStartedAt = Date()
        try await Task.sleep(for: .milliseconds(100))

        let controlServiceName = "Aggregate Route \(routeToken.prefix(8)) Control"
        let primary = DiscoveredDevice(
            id: deviceId,
            name: aggregateOnly.name,
            bonjourServiceName: controlServiceName,
            modelName: aggregateOnly.modelName,
            platform: aggregateOnly.platform,
            osVersion: aggregateOnly.osVersion,
            bonjourServiceType: DiscoveryServiceType.skybridge.rawValue,
            bonjourServiceDomain: "local.",
            services: [DiscoveryServiceType.skybridge.rawValue],
            portMap: [DiscoveryServiceType.skybridge.rawValue: 9527]
        )
        _ = discoveryManager.debugReplaceAdvertisementSnapshot(
            primary,
            endpointKey: "control-endpoint",
            serviceType: .skybridge
        )

        let resolved = try await waitTask.value
        XCTAssertLessThan(Date().timeIntervalSince(waitStartedAt), 2.0)
        XCTAssertEqual(resolved.id, primary.id)
        XCTAssertEqual(resolved.bonjourServiceName, controlServiceName)
        XCTAssertFalse(
            P2PConnectionEndpointPolicy.connectionEndpointCandidates(
                for: resolved,
                liveBonjourControlEndpoints: discoveryManager.liveBonjourServiceEndpoints(
                    for: resolved,
                    serviceType: .skybridge
                )
            ).isEmpty
        )
    }

    @MainActor
    func testControlRouteWaitPropagatesCancellation() async {
        let routeToken = UUID().uuidString.lowercased()
        let selectedDiscoveryTarget = DiscoveredDevice(
            id: "id:\(routeToken)",
            name: "Route Cancel \(routeToken.prefix(8))",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "27.0"
        )
        let waitTask = Task { @MainActor in
            try await P2PConnectionManager.instance
                .testResolveConnectableDeviceAwaitingControlRoute(
                    for: selectedDiscoveryTarget,
                    mode: .selectedDiscoveryTarget
                )
        }
        await Task.yield()
        waitTask.cancel()

        do {
            _ = try await waitTask.value
            XCTFail("Expected the route hydration wait to propagate cancellation")
        } catch is CancellationError {
            // Expected: cancellation must never be converted into a missing-route result.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    @MainActor
    func testStrongTargetResolutionNeverCrossesToSameNameDifferentIdentity() {
        let discoveryManager = DeviceDiscoveryManager.instance
        let originalState = discoveryManager.debugCaptureState()
        defer { discoveryManager.debugRestoreState(originalState) }

        let target = DiscoveredDevice(
            id: "id:\(UUID().uuidString.lowercased())",
            name: "Shared Studio Mac",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "27.0"
        )
        let differentStrongIdentity = DiscoveredDevice(
            id: "id:\(UUID().uuidString.lowercased())",
            name: target.name,
            bonjourServiceName: "Shared Studio Mac",
            modelName: target.modelName,
            platform: target.platform,
            osVersion: target.osVersion,
            bonjourServiceType: DiscoveryServiceType.skybridge.rawValue,
            bonjourServiceDomain: "local.",
            services: [DiscoveryServiceType.skybridge.rawValue],
            portMap: [DiscoveryServiceType.skybridge.rawValue: 9527]
        )
        discoveryManager.debugSeedDiscoveryState(
            devices: [differentStrongIdentity],
            lastActivity: Date(),
            endpointToDeviceId: ["different-strong-identity": differentStrongIdentity.id],
            liveBrowseEndpointKeysByServiceType: [
                .skybridge: ["different-strong-identity"]
            ]
        )

        let resolved = P2PConnectionManager.instance
            .testResolveLatestConnectableDevice(for: target)

        XCTAssertEqual(resolved.id, target.id)
        XCTAssertEqual(
            P2PConnectionEndpointPolicy.normalizedStrongDeviceId(for: resolved),
            P2PConnectionEndpointPolicy.normalizedStrongDeviceId(for: target)
        )
    }

    @MainActor
    func testLiveBonjourSnapshotNeverCrossesSharedServiceAliasToDifferentStrongIdentity() throws {
        let discoveryManager = DeviceDiscoveryManager.debugMakeIsolatedInstance()
        let sharedServiceName = "Shared Strong Identity Route"
        let target = DiscoveredDevice(
            id: "id:\(UUID().uuidString.lowercased())",
            name: sharedServiceName,
            bonjourServiceName: sharedServiceName,
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "27.0",
            bonjourServiceType: DiscoveryServiceType.skybridge.rawValue,
            bonjourServiceDomain: "local.",
            services: [DiscoveryServiceType.skybridge.rawValue],
            portMap: [DiscoveryServiceType.skybridge.rawValue: 9527]
        )
        let differentStrongIdentity = DiscoveredDevice(
            id: "id:\(UUID().uuidString.lowercased())",
            name: sharedServiceName,
            bonjourServiceName: sharedServiceName,
            modelName: target.modelName,
            platform: target.platform,
            osVersion: target.osVersion,
            bonjourServiceType: DiscoveryServiceType.skybridge.rawValue,
            bonjourServiceDomain: "local.",
            services: [DiscoveryServiceType.skybridge.rawValue],
            portMap: [DiscoveryServiceType.skybridge.rawValue: 9527]
        )
        let differentEndpoint = NWEndpoint.service(
            name: sharedServiceName,
            type: DiscoveryServiceType.skybridge.rawValue,
            domain: "local.",
            interface: nil
        )

        _ = discoveryManager.debugReplaceAdvertisementSnapshot(
            differentStrongIdentity,
            endpoint: differentEndpoint,
            endpointKey: "different-strong-identity-live-route",
            serviceType: .skybridge
        )

        XCTAssertEqual(
            try XCTUnwrap(discoveryManager.canonicalDiscoveredDevice(for: target)).id,
            differentStrongIdentity.id,
            "The fixture must reproduce weak Bonjour alias ownership by another strong identity."
        )
        XCTAssertTrue(
            discoveryManager.liveBonjourServiceEndpoints(
                for: target,
                serviceType: .skybridge
            ).isEmpty,
            "A weak shared service alias must never substitute another strong identity's live route."
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
        XCTAssertFalse(
            P2PConnectionEndpointPolicy.shouldIncludePeerToPeer(
                for: .hostPort(host: NWEndpoint.Host("ipad-pro.local"), port: 9527)
            )
        )
        XCTAssertTrue(
            P2PConnectionEndpointPolicy.shouldIncludePeerToPeer(
                for: .hostPort(host: NWEndpoint.Host("fe80::1%en0"), port: 9527)
            )
        )
    }

    private func routeRemovalFixture() -> DiscoveredDevice {
        DiscoveredDevice(
            id: "id:e0715a9a-d0d3-47e6-b353-de0a30293e1f",
            name: "Studio MacBook Pro",
            bonjourServiceName: "Studio MacBook Pro Control",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "26.5",
            bonjourServiceType: DiscoveryServiceType.skybridge.rawValue,
            bonjourServiceDomain: "control.local.",
            services: [
                DiscoveryServiceType.skybridge.rawValue,
                DiscoveredDevice.fileTransferServiceType
            ],
            portMap: [
                DiscoveryServiceType.skybridge.rawValue: 9527,
                DiscoveredDevice.fileTransferServiceType: 8080
            ]
        )
    }

    private func skybridgeDevice(
        ipAddress: String?,
        portMap: [String: UInt16] = [DiscoveryServiceType.skybridge.rawValue: 9527]
    ) -> DiscoveredDevice {
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
            portMap: portMap
        )
    }

    private func assertServiceEndpoint(
        _ endpoint: NWEndpoint,
        name: String,
        type expectedType: String = DiscoveryServiceType.skybridge.rawValue,
        domain: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        guard case .service(let endpointName, let type, let endpointDomain, _) = endpoint else {
            XCTFail("Expected service endpoint, got \(endpoint)", file: file, line: line)
            return
        }

        XCTAssertEqual(endpointName, name, file: file, line: line)
        XCTAssertEqual(type, expectedType, file: file, line: line)
        XCTAssertEqual(endpointDomain, domain, file: file, line: line)
    }

}
