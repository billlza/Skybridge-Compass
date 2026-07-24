import XCTest
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

    func testP2PConnectionManagerUsesTrustedBonjourContextWhenLiveSnapshotLostEndpoint() throws {
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
        XCTAssertFalse(endpointDescriptions.isEmpty)
        XCTAssertTrue(endpointDescriptions.contains { $0.contains("_skybridge._tcp") })
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
}
