import XCTest
import Network
@testable import SkyBridgeCompass_iOS

@MainActor
final class P2PConnectableContextRecoveryTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        try TrustedDeviceStore.shared.replaceTrustedDevicesForTesting([])
    }

    override func tearDown() async throws {
        try TrustedDeviceStore.shared.replaceTrustedDevicesForTesting([])
        try await super.tearDown()
    }

    func testTrustedDeviceStoreRestoresPersistedBonjourContextForCanonicalAlias() throws {
        let liveAlias = DiscoveredDevice(
            id: "bonjour:Lza的MacBook Pro@local.",
            name: "Lza的MacBook Pro",
            bonjourServiceName: "Lza的MacBook Pro",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "26.4.1",
            ipAddress: nil,
            bonjourServiceType: "_skybridge._tcp",
            bonjourServiceDomain: "local.",
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 9527]
        )
        try TrustedDeviceStore.shared.trustResolvedPeer(
            liveAlias,
            declaredDeviceId: "E0715A9A-D0D3-47E6-B353-DE0A30293E1F"
        )

        let canonicalOnly = DiscoveredDevice(
            id: "id:e0715a9a-d0d3-47e6-b353-de0a30293e1f",
            name: "Lza的MacBook Pro",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "26.4.1",
            ipAddress: nil
        )

        let resolved = TrustedDeviceStore.shared.resolvedConnectableDevice(for: canonicalOnly)

        XCTAssertEqual(resolved?.bonjourServiceName, "Lza的MacBook Pro")
        XCTAssertEqual(resolved?.bonjourServiceType, "_skybridge._tcp")
        XCTAssertEqual(resolved?.bonjourServiceDomain, "local.")
        XCTAssertEqual(resolved?.portMap["_skybridge._tcp"], 9527)
        XCTAssertEqual(resolved?.services, ["_skybridge._tcp"])
    }

    func testP2PConnectionManagerWaitsForExactLiveEndpointBeforeUsingPersistedBonjourContext() async throws {
        let liveAlias = DiscoveredDevice(
            id: "bonjour:Lza的MacBook Pro@local.",
            name: "Lza的MacBook Pro",
            bonjourServiceName: "Lza的MacBook Pro",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "26.4.1",
            ipAddress: nil,
            bonjourServiceType: "_skybridge._tcp",
            bonjourServiceDomain: "local.",
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 9527]
        )
        try TrustedDeviceStore.shared.trustResolvedPeer(
            liveAlias,
            declaredDeviceId: "E0715A9A-D0D3-47E6-B353-DE0A30293E1F"
        )

        let canonicalOnly = DiscoveredDevice(
            id: "id:e0715a9a-d0d3-47e6-b353-de0a30293e1f",
            name: "Lza的MacBook Pro",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "26.4.1",
            ipAddress: nil
        )

        let manager = P2PConnectionManager.instance
        let resolved = manager.testResolveLatestConnectableDevice(for: canonicalOnly)
        let endpointDescriptions = manager.testConnectionEndpointDescriptions(for: resolved)

        XCTAssertEqual(resolved.bonjourServiceName, "Lza的MacBook Pro")
        XCTAssertTrue(endpointDescriptions.isEmpty)

        // A current v2 advertisement is owned by the stable TXT device identifier. The
        // historical Bonjour alias above is persisted route context only and must never be
        // treated as proof that a live endpoint belongs to this trusted identity.
        let liveStableAdvertisement = DiscoveredDevice(
            id: canonicalOnly.id,
            name: liveAlias.name,
            bonjourServiceName: liveAlias.bonjourServiceName,
            modelName: liveAlias.modelName,
            platform: liveAlias.platform,
            osVersion: liveAlias.osVersion,
            ipAddress: nil,
            bonjourServiceType: liveAlias.bonjourServiceType,
            bonjourServiceDomain: liveAlias.bonjourServiceDomain,
            services: liveAlias.services,
            portMap: liveAlias.portMap
        )
        let endpointKey = "test-live-primary-control-\(UUID().uuidString)"
        let discoveryManager = DeviceDiscoveryManager.instance
        let resolution = Task { @MainActor in
            try await manager.testResolveConnectableDeviceAwaitingControlRoute(
                for: canonicalOnly
            )
        }
        await Task.yield()

        _ = discoveryManager.debugReplaceAdvertisementSnapshot(
            liveStableAdvertisement,
            endpoint: .service(
                name: "Lza的MacBook Pro",
                type: "_skybridge._tcp",
                domain: "local.",
                interface: nil
            ),
            endpointKey: endpointKey,
            serviceType: .skybridge
        )
        defer {
            _ = discoveryManager.debugRemoveAdvertisementSnapshot(
                endpointKey: endpointKey,
                deviceId: liveStableAdvertisement.id,
                serviceType: .skybridge
            )
        }

        let liveResolved = try await resolution.value
        let liveEndpointDescriptions = manager.testConnectionEndpointDescriptions(
            for: liveResolved
        )
        XCTAssertFalse(liveEndpointDescriptions.isEmpty)
        XCTAssertTrue(
            liveEndpointDescriptions.contains { $0.contains("_skybridge._tcp") }
        )
    }

    func testP2PConnectionManagerPrefersUniqueLiveCandidateOverPollutedTrustedAlias() throws {
        try TrustedDeviceStore.shared.mergeFromCloud([
            TrustedDeviceStore.TrustedDevice(
                id: "id:lza的macbook pro",
                name: "Lza的MacBook Pro",
                platform: .macOS,
                ipAddress: nil,
                currentDeviceId: "id:lza的macbook pro",
                knownDeviceIds: ["bonjour:Lza的MacBook Pro@local."]
            )
        ])

        let liveCandidate = DiscoveredDevice(
            id: "bonjour:Lza的MacBook Pro@local.",
            name: "Lza的MacBook Pro",
            bonjourServiceName: "Lza的MacBook Pro",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "26.4.1",
            bonjourServiceType: "_skybridge._tcp",
            bonjourServiceDomain: "local.",
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 9527]
        )
        DeviceDiscoveryManager.instance.injectDiscoveredDevicesForTesting([liveCandidate])

        let pollutedTrustedRow = DiscoveredDevice(
            id: "id:lza的macbook pro",
            name: "Lza的MacBook Pro",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "26.4.1"
        )

        let manager = P2PConnectionManager.instance
        let resolved = manager.testResolveLatestConnectableDevice(for: pollutedTrustedRow)

        XCTAssertEqual(resolved.id, "bonjour:Lza的MacBook Pro@local.")
        XCTAssertEqual(resolved.bonjourServiceName, "Lza的MacBook Pro")
    }

    func testLegacyMixedBonjourRouteIsDroppedWithoutLosingOtherConnectableMetadata() throws {
        let stableId = "id:e0715a9a-d0d3-47e6-b353-de0a30293e1f"
        let legacyMixedContext = TrustedDeviceStore.TrustedDevice.ConnectableContext(
            bonjourServiceName: "Studio MacBook Pro Transfer",
            bonjourServiceType: DiscoveryServiceType.skybridge.rawValue,
            bonjourServiceDomain: "auxiliary.local.",
            services: [
                DiscoveryServiceType.skybridge.rawValue,
                DiscoveredDevice.fileTransferServiceType
            ],
            portMap: [
                DiscoveryServiceType.skybridge.rawValue: 9527,
                DiscoveredDevice.fileTransferServiceType: 8080
            ],
            lastResolvedIPAddress: "192.168.1.20"
        )
        var persisted = [
            TrustedDeviceStore.TrustedDevice(
                id: stableId,
                name: "Studio MacBook Pro",
                platform: .macOS,
                ipAddress: "192.168.1.20",
                currentDeviceId: stableId,
                knownDeviceIds: [stableId],
                currentPathLifecycleState: .active,
                connectableContext: legacyMixedContext
            )
        ]
        let store = TrustedDeviceStore(
            testingLoad: { persisted },
            testingSave: { persisted = $0 }
        )
        let canonicalOnly = DiscoveredDevice(
            id: stableId,
            name: "Studio MacBook Pro",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "26.5"
        )

        let migrated = try XCTUnwrap(store.resolvedConnectableDevice(for: canonicalOnly))
        XCTAssertNil(migrated.bonjourServiceName)
        XCTAssertNil(migrated.bonjourServiceType)
        XCTAssertNil(migrated.bonjourServiceDomain)
        XCTAssertEqual(migrated.ipAddress, "192.168.1.20")
        XCTAssertEqual(
            Set(migrated.services),
            [DiscoveryServiceType.skybridge.rawValue, DiscoveredDevice.fileTransferServiceType]
        )
        XCTAssertEqual(migrated.portMap[DiscoveryServiceType.skybridge.rawValue], 9527)
        XCTAssertEqual(migrated.portMap[DiscoveredDevice.fileTransferServiceType], 8080)

        let livePrimary = DiscoveredDevice(
            id: stableId,
            name: "Studio MacBook Pro",
            bonjourServiceName: "Studio MacBook Pro Control",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "26.5",
            ipAddress: "192.168.1.20",
            bonjourServiceType: DiscoveryServiceType.skybridge.rawValue,
            bonjourServiceDomain: "control.local.",
            services: [DiscoveryServiceType.skybridge.rawValue],
            portMap: [DiscoveryServiceType.skybridge.rawValue: 9527]
        )
        try store.trustResolvedPeer(livePrimary, declaredDeviceId: stableId)

        let rehydrated = try XCTUnwrap(store.resolvedConnectableDevice(for: canonicalOnly))
        XCTAssertEqual(rehydrated.bonjourServiceName, "Studio MacBook Pro Control")
        XCTAssertEqual(rehydrated.bonjourServiceType, DiscoveryServiceType.skybridge.rawValue)
        XCTAssertEqual(rehydrated.bonjourServiceDomain, "control.local.")
    }

    func testPersistedAndLivePartialRoutesCannotBeCombinedFieldByField() throws {
        let stableId = "id:0b4ad788-f949-4cb2-b56a-bf94c7717ec0"
        var persisted = [
            TrustedDeviceStore.TrustedDevice(
                id: stableId,
                name: "Partial Route Mac",
                platform: .macOS,
                ipAddress: "192.168.1.21",
                currentDeviceId: stableId,
                knownDeviceIds: [stableId],
                currentPathLifecycleState: .active,
                connectableContext: .init(
                    bonjourServiceName: "Persisted Name",
                    bonjourServiceType: nil,
                    bonjourServiceDomain: "persisted.local.",
                    services: [DiscoveredDevice.fileTransferServiceType],
                    portMap: [DiscoveredDevice.fileTransferServiceType: 8080],
                    lastResolvedIPAddress: "192.168.1.21"
                )
            )
        ]
        let store = TrustedDeviceStore(
            testingLoad: { persisted },
            testingSave: { persisted = $0 }
        )
        let livePartial = DiscoveredDevice(
            id: stableId,
            name: "Partial Route Mac",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "26.5",
            bonjourServiceType: DiscoveryServiceType.skybridge.rawValue,
            services: [DiscoveryServiceType.skybridge.rawValue],
            portMap: [DiscoveryServiceType.skybridge.rawValue: 9527]
        )

        let resolved = try XCTUnwrap(store.resolvedConnectableDevice(for: livePartial))
        XCTAssertNil(resolved.bonjourServiceName)
        XCTAssertNil(resolved.bonjourServiceType)
        XCTAssertNil(resolved.bonjourServiceDomain)
        XCTAssertEqual(resolved.ipAddress, "192.168.1.21")
        XCTAssertTrue(resolved.services.contains(DiscoveryServiceType.skybridge.rawValue))
        XCTAssertTrue(resolved.services.contains(DiscoveredDevice.fileTransferServiceType))
    }
}
