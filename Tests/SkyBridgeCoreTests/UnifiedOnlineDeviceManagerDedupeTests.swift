import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class UnifiedOnlineDeviceManagerDedupeTests: XCTestCase {
    private let liveProtocolFingerprint = "336b022ee58b653f08569a1be0e32a740da127882b79897589e75a95f0e2b94c"

    func testRecentStableIdentityCollapsesWhenStrongRecordExists() {
        let recent = makeDevice(
            name: "MacBook Pro",
            uniqueIdentifier: "recent:id:peer-1",
            status: .connected,
            lastConnectedAt: Date()
        )
        let strong = makeDevice(
            name: "MacBook Pro",
            uniqueIdentifier: "id:peer-1",
            status: .connected,
            lastConnectedAt: Date(),
            isConnectable: true
        )

        XCTAssertTrue(
            UnifiedOnlineDeviceManager.shouldCollapseRecentDevice(recent, against: [strong])
        )
    }

    func testRecentStableUUIDCollapsesEvenWhenDisplayNameDiffers() {
        let peerId = "550E8400-E29B-41D4-A716-446655440001"
        let recent = makeDevice(
            name: "peer:fe80::c55:97f0:7246:915",
            uniqueIdentifier: "recent:id:\(peerId)",
            status: .connected,
            lastConnectedAt: Date()
        )
        let strong = makeDevice(
            name: "Ziang的iPhone 16 Pro",
            uniqueIdentifier: "id:\(peerId)",
            status: .online,
            lastConnectedAt: nil,
            isConnectable: true
        )

        XCTAssertTrue(
            UnifiedOnlineDeviceManager.shouldCollapseRecentDevice(recent, against: [strong])
        )
    }

    @MainActor
    func testRouteCoalescingKeepsLiveProtocolIdentityOverNewerStaleStableId() {
        let manager = UnifiedOnlineDeviceManager.shared
        let bonjourRoute = "bonjour:iPad_Pro_11-inch__M4__local."
        let stale = makeDevice(
            name: "Ziang的iPad",
            uniqueIdentifier: "id:07CB9A6E-7492-4680-9DD7-F37DC8568891",
            status: .online,
            lastConnectedAt: nil,
            isConnectable: true,
            routeIdentifiers: [bonjourRoute],
            platformName: "ipados",
            modelName: "iPad_Pro_11-inch__M4_",
            lastSeen: Date().addingTimeInterval(60)
        )
        let live = makeDevice(
            name: "Ziang的iPad",
            uniqueIdentifier: "id:9DDF920E-D7C4-51F2-9C94-67FF629BDF04",
            status: .online,
            lastConnectedAt: nil,
            isConnectable: true,
            routeIdentifiers: [bonjourRoute],
            platformName: "ipados",
            modelName: "iPad_Pro_11-inch__M4_",
            protocolFingerprint: liveProtocolFingerprint
        )
        defer {
            manager.replaceDevicesForTesting([])
        }

        manager.replaceDevicesForTesting([stale, live])
        manager.recomputeDeviceStatusesForTesting()

        XCTAssertEqual(manager.onlineDevices.count, 1)
        XCTAssertEqual(
            manager.onlineDevices.first?.uniqueIdentifier,
            "id:9DDF920E-D7C4-51F2-9C94-67FF629BDF04"
        )
        XCTAssertEqual(
            manager.onlineDevices.first?.protocolFingerprint,
            liveProtocolFingerprint
        )
    }

    func testRecentPeerAddressCollapsesWhenReachableBonjourRecordExists() {
        let recent = makeDevice(
            name: "peer:192.168.31.20",
            uniqueIdentifier: "recent:peer:192.168.31.20",
            status: .connected,
            lastConnectedAt: Date()
        )
        let bonjour = makeDevice(
            name: "Mac mini",
            uniqueIdentifier: "bonjour:Mac mini@local.",
            ipv4: "192.168.31.20",
            status: .online,
            lastConnectedAt: Date(),
            isConnectable: true
        )

        XCTAssertTrue(
            UnifiedOnlineDeviceManager.shouldCollapseRecentDevice(recent, against: [bonjour])
        )
    }

    @MainActor
    func testCrossNetworkSessionRouteDoesNotCreatePersistentRecentDevice() {
        UserDefaults.standard.removeObject(forKey: "skybridge.persistedDevices")
        let manager = UnifiedOnlineDeviceManager.shared
        manager.replaceDevicesForTesting([])
        defer {
            manager.replaceDevicesForTesting([])
            UserDefaults.standard.removeObject(forKey: "skybridge.persistedDevices")
        }

        manager.markDeviceAsConnected(
            peerId: "cross-network:session-123456789",
            displayName: "Remote Device",
            cryptoKind: "Current Path",
            suite: "X-Wing",
            guardStatus: "跨网已连接"
        )

        XCTAssertTrue(manager.onlineDevices.isEmpty)
        XCTAssertNil(UserDefaults.standard.data(forKey: "skybridge.persistedDevices"))
    }

    @MainActor
    func testLoadPersistedDevicesScrubsCrossNetworkRecentRowsAndRewritesStorage() throws {
        UserDefaults.standard.removeObject(forKey: "skybridge.persistedDevices")
        let manager = UnifiedOnlineDeviceManager.shared
        let staleCrossNetworkRecent = makeDevice(
            name: "Remote Device",
            uniqueIdentifier: "recent:peer:cross-network:session-123",
            status: .connected,
            lastConnectedAt: Date()
        )
        let stable = makeDevice(
            name: "Stable iPad",
            uniqueIdentifier: "id:550e8400-e29b-41d4-a716-446655440001",
            status: .connected,
            lastConnectedAt: Date(),
            routeIdentifiers: [
                "bonjour:Stable iPad@local.",
                "peer:cross-network:session-123"
            ]
        )
        defer {
            manager.replaceDevicesForTesting([])
            UserDefaults.standard.removeObject(forKey: "skybridge.persistedDevices")
        }

        try writePersistedDevicesForTesting([staleCrossNetworkRecent, stable], schemaVersion: 2)
        manager.reloadPersistedDevicesForTesting()

        XCTAssertEqual(manager.onlineDevices.map(\.uniqueIdentifier), [stable.uniqueIdentifier])
        let persisted = try persistedDevicesForTesting()
        XCTAssertEqual(persisted.map(\.uniqueIdentifier), [stable.uniqueIdentifier])
        XCTAssertEqual(persisted.first?.routeIdentifiers, ["bonjour:Stable iPad@local."])
    }

    @MainActor
    func testPersistenceKeepsNamedConnectedAndDropsUnknownOrNeverConnected() throws {
        UserDefaults.standard.removeObject(forKey: "skybridge.persistedDevices")
        let manager = UnifiedOnlineDeviceManager.shared
        let namedConnected = makeDevice(
            name: "Ziang的Mac",
            uniqueIdentifier: "id:aaaaaaaa-0000-4000-8000-000000000001",
            status: .offline,
            lastConnectedAt: Date()
        )
        // 无名「未知」设备（即便有连接时间）不应被记住——这是历史堆积的离线幽灵。
        let unknownConnected = makeDevice(
            name: "Unknown Device",
            uniqueIdentifier: "id:bbbbbbbb-0000-4000-8000-000000000002",
            status: .offline,
            lastConnectedAt: Date()
        )
        // 从未连接的被动发现不应被记住。
        let neverConnected = makeDevice(
            name: "Passing iPhone",
            uniqueIdentifier: "id:cccccccc-0000-4000-8000-000000000003",
            status: .offline,
            lastConnectedAt: nil
        )
        defer {
            manager.replaceDevicesForTesting([])
            UserDefaults.standard.removeObject(forKey: "skybridge.persistedDevices")
        }

        try writePersistedDevicesForTesting(
            [namedConnected, unknownConnected, neverConnected],
            schemaVersion: 2
        )
        manager.reloadPersistedDevicesForTesting()

        XCTAssertEqual(
            manager.onlineDevices.map(\.uniqueIdentifier),
            [namedConnected.uniqueIdentifier]
        )
        let persisted = try persistedDevicesForTesting()
        XCTAssertEqual(persisted.map(\.uniqueIdentifier), [namedConnected.uniqueIdentifier])
    }

    @MainActor
    func testClearOfflineDevicesRemovesUnauthorizedOfflineAndKeepsOnline() {
        let manager = UnifiedOnlineDeviceManager.shared
        let offlineNamed = makeDevice(
            name: "Old Offline Mac",
            uniqueIdentifier: "id:dddddddd-0000-4000-8000-000000000004",
            status: .offline,
            lastConnectedAt: Date()
        )
        let onlineDevice = makeDevice(
            name: "Live iPad",
            uniqueIdentifier: "id:eeeeeeee-0000-4000-8000-000000000005",
            status: .online,
            lastConnectedAt: nil
        )
        defer {
            manager.replaceDevicesForTesting([])
            UserDefaults.standard.removeObject(forKey: "skybridge.persistedDevices")
        }

        manager.replaceDevicesForTesting([offlineNamed, onlineDevice])
        let removed = manager.clearOfflineDevices()

        XCTAssertEqual(removed, 1)
        XCTAssertEqual(
            manager.onlineDevices.map(\.uniqueIdentifier),
            [onlineDevice.uniqueIdentifier]
        )
    }

    @MainActor
    func testLegacyPersistedDeviceScrubMigratesToV2WithoutCrossNetworkRows() throws {
        UserDefaults.standard.removeObject(forKey: "skybridge.persistedDevices")
        let manager = UnifiedOnlineDeviceManager.shared
        let staleRecent = makeDevice(
            name: "Remote Device",
            uniqueIdentifier: "recent:cross-network:session-456",
            status: .connected,
            lastConnectedAt: Date()
        )
        let stable = makeDevice(
            name: "Stable Mac",
            uniqueIdentifier: "id:650e8400-e29b-41d4-a716-446655440001",
            status: .connected,
            lastConnectedAt: Date()
        )
        defer {
            manager.replaceDevicesForTesting([])
            UserDefaults.standard.removeObject(forKey: "skybridge.persistedDevices")
        }

        let legacyData = try JSONEncoder().encode([staleRecent, stable])
        UserDefaults.standard.set(legacyData, forKey: "skybridge.persistedDevices")
        manager.reloadPersistedDevicesForTesting()

        XCTAssertEqual(manager.onlineDevices.map(\.uniqueIdentifier), [stable.uniqueIdentifier])
        let persisted = try persistedDevicesForTesting()
        XCTAssertEqual(persisted.map(\.uniqueIdentifier), [stable.uniqueIdentifier])
        XCTAssertNotNil(UserDefaults.standard.data(forKey: "skybridge.persistedDevices"))
    }

    @MainActor
    func testStableOnlineDeviceUsesPreservedBonjourRouteAliasForConnectability() {
        let manager = UnifiedOnlineDeviceManager.shared
        let stableBonjour = makeDevice(
            name: "Ziang的iPad",
            uniqueIdentifier: "id:07CB9A6E-1111-4222-8333-123456789ABC",
            ipv4: nil,
            status: .online,
            lastConnectedAt: nil,
            isConnectable: true,
            connectionTypes: [.wifi],
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 9527],
            routeIdentifiers: ["bonjour:Ziang的iPad@local."],
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro",
            protocolFingerprint: liveProtocolFingerprint
        )

        XCTAssertTrue(manager.hasResolvedConnectableControlRoute(for: stableBonjour))
    }

    @MainActor
    func testStableOnlineDeviceWithoutHostOrBonjourRouteIsNotConnectableFromPortOnly() {
        let manager = UnifiedOnlineDeviceManager.shared
        let stableWithoutRoute = makeDevice(
            name: "Ziang的iPad",
            uniqueIdentifier: "id:07CB9A6E-1111-4222-8333-123456789ABC",
            ipv4: nil,
            status: .online,
            lastConnectedAt: nil,
            isConnectable: true,
            connectionTypes: [.wifi],
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 9527],
            routeIdentifiers: [],
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro"
        )

        XCTAssertFalse(manager.hasResolvedConnectableControlRoute(for: stableWithoutRoute))
    }

    @MainActor
    func testStableOnlineDeviceRejectsMalformedBonjourRouteAlias() {
        let manager = UnifiedOnlineDeviceManager.shared
        let malformedRoute = makeDevice(
            name: "Ziang的iPad",
            uniqueIdentifier: "id:07CB9A6E-1111-4222-8333-123456789ABC",
            ipv4: nil,
            status: .online,
            lastConnectedAt: nil,
            isConnectable: true,
            connectionTypes: [.wifi],
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 9527],
            routeIdentifiers: ["bonjour:id:07CB9A6E-1111-4222-8333-123456789ABC@local."],
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro"
        )

        XCTAssertFalse(manager.hasResolvedConnectableControlRoute(for: malformedRoute))
    }

    @MainActor
    func testTrustedStableIdentityAliasesCoalesceAndPreferConnectableRoute() throws {
        let manager = UnifiedOnlineDeviceManager.shared
        let oldStableId = "07CB9A6E-1111-4222-8333-123456789ABC"
        let currentStableId = "9F9D4114-0EA8-4856-A5B1-6912B2EE2542"
        let staleCloudAlias = makeDevice(
            name: "Ziang的iPad",
            uniqueIdentifier: "id:\(oldStableId)",
            ipv4: nil,
            status: .online,
            lastConnectedAt: nil,
            isConnectable: false,
            connectionTypes: [],
            services: [],
            portMap: [:],
            routeIdentifiers: [],
            sources: [.skybridgeCloud],
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro"
        )
        let liveStableRoute = makeDevice(
            name: "iPad",
            uniqueIdentifier: "id:\(currentStableId)",
            ipv4: "192.168.0.104",
            status: .online,
            lastConnectedAt: nil,
            isConnectable: true,
            connectionTypes: [.wifi],
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 51776],
            routeIdentifiers: ["bonjour:iPad@local."],
            sources: [.skybridgeBonjour],
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro",
            protocolFingerprint: liveProtocolFingerprint
        )
        let trustRecord = TrustRecord(
            deviceId: "id:\(currentStableId)",
            pubKeyFP: String(repeating: "e", count: 64),
            publicKey: Data([0x04]),
            kemPublicKeys: nil,
            capabilities: ["trusted", "declaredDeviceId=\(currentStableId)"],
            signature: Data(),
            deviceName: "iPad",
            currentDeviceId: "id:\(currentStableId)",
            knownDeviceIds: ["id:\(oldStableId)", "id:\(currentStableId)"]
        )
        let previousTrustRecords = TrustSyncService.shared.activeTrustRecords
        TrustSyncService.shared.activeTrustRecords = [trustRecord]
        manager.replaceDevicesForTesting([staleCloudAlias, liveStableRoute])
        defer {
            TrustSyncService.shared.activeTrustRecords = previousTrustRecords
            manager.replaceDevicesForTesting([])
        }

        manager.recomputeDeviceStatusesForTesting()

        XCTAssertEqual(manager.onlineDevices.count, 1)
        let resolved = try XCTUnwrap(manager.onlineDevices.first)
        XCTAssertEqual(resolved.uniqueIdentifier, "id:\(currentStableId)")
        XCTAssertEqual(resolved.ipv4, "192.168.0.104")
        XCTAssertTrue(resolved.sources.contains(.skybridgeCloud))
        XCTAssertTrue(resolved.sources.contains(.skybridgeBonjour))
        XCTAssertTrue(manager.hasResolvedConnectableControlRoute(for: resolved))
    }

    @MainActor
    func testCloudHeartbeatOnlyRowDoesNotRemainConnectableFromPersistedState() throws {
        let manager = UnifiedOnlineDeviceManager.shared
        let cloudOnly = makeDevice(
            name: "Ziang的iPad",
            uniqueIdentifier: "serial:icloud-ipad",
            ipv4: nil,
            status: .online,
            lastConnectedAt: nil,
            isConnectable: true,
            connectionTypes: [],
            services: [],
            portMap: [:],
            routeIdentifiers: [],
            sources: [.skybridgeCloud],
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro"
        )
        manager.replaceDevicesForTesting([cloudOnly])
        defer { manager.replaceDevicesForTesting([]) }

        manager.recomputeDeviceStatusesForTesting()

        let resolved = try XCTUnwrap(manager.onlineDevices.first)
        XCTAssertFalse(
            resolved.isConnectable,
            "Apple mobile endpoints without a resolved positive control port must stay non-connectable."
        )
        XCTAssertFalse(manager.hasResolvedConnectableControlRoute(for: resolved))
    }

    @MainActor
    func testLinkLocalIPv4DoesNotCreateDirectControlRoute() throws {
        let manager = UnifiedOnlineDeviceManager.shared
        let linkLocalOnly = makeDevice(
            name: "Ziang的iPad",
            uniqueIdentifier: "id:51D74800-4C6F-41AA-9F73-711751AF0B56",
            ipv4: "169.254.185.245",
            status: .online,
            lastConnectedAt: nil,
            isConnectable: true,
            connectionTypes: [.usb, .wifi],
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 9527],
            routeIdentifiers: [],
            sources: [.skybridgeCloud],
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro"
        )
        let discovered = DiscoveredDevice(
            id: UUID(),
            name: "Ziang的iPad",
            ipv4: "169.254.185.245",
            ipv6: nil,
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro",
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 9527],
            connectionTypes: [.usb],
            uniqueIdentifier: "host:169.254.185.245"
        )
        manager.replaceDevicesForTesting([linkLocalOnly])
        defer { manager.replaceDevicesForTesting([]) }

        let resolved = try XCTUnwrap(manager.onlineDevices.first)
        XCTAssertFalse(UnifiedOnlineDeviceManager.hasResolvedSkyBridgeControlRoute(discovered))
        XCTAssertFalse(manager.hasResolvedConnectableControlRoute(for: resolved))
    }

    @MainActor
    func testLinkLocalBonjourOnlineDeviceDoesNotRemainConnectableByServiceNameOnly() throws {
        let manager = UnifiedOnlineDeviceManager.shared
        let staleBonjour = makeDevice(
            name: "Ziang的iPad",
            uniqueIdentifier: "id:51D74800-4C6F-41AA-9F73-711751AF0B56",
            ipv4: "169.254.185.245",
            status: .online,
            lastConnectedAt: nil,
            isConnectable: true,
            connectionTypes: [.usb, .wifi],
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 9527],
            routeIdentifiers: ["bonjour:Ziang的iPad@local."],
            sources: [.skybridgeBonjour],
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro",
            protocolFingerprint: liveProtocolFingerprint
        )
        manager.replaceDevicesForTesting([staleBonjour])
        defer { manager.replaceDevicesForTesting([]) }

        manager.recomputeDeviceStatusesForTesting()

        let resolved = try XCTUnwrap(manager.onlineDevices.first)
        XCTAssertFalse(resolved.isConnectable)
        XCTAssertFalse(manager.hasResolvedConnectableControlRoute(for: resolved))
    }

    @MainActor
    func testLiveDiscoveredCandidateMakesStaleAppleMobilePresentationConnectable() throws {
        let manager = UnifiedOnlineDeviceManager.shared
        let bonjourRoute = "bonjour:iPad_Pro_11-inch__M4__local."
        let stalePresentation = makeDevice(
            name: "Ziang的iPad",
            uniqueIdentifier: "id:07CB9A6E-7492-4680-9DD7-F37DC8568891",
            ipv4: "192.168.0.104",
            status: .online,
            lastConnectedAt: nil,
            isConnectable: false,
            connectionTypes: [.wifi],
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 9527],
            routeIdentifiers: [bonjourRoute],
            sources: [.skybridgeBonjour],
            platformName: "ipados",
            osVersion: "27.0",
            modelName: "iPad_Pro_11-inch__M4_"
        )
        let liveCandidate = DiscoveredDevice(
            id: UUID(),
            name: "iPad_Pro_11-inch__M4_",
            ipv4: nil,
            ipv6: nil,
            platformName: "ipados",
            osVersion: "27.0",
            modelName: "iPad_Pro_11-inch__M4_",
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 9527],
            connectionTypes: [.wifi],
            uniqueIdentifier: "id:9DDF920E-D7C4-51F2-9C94-67FF629BDF04",
            routeIdentifiers: [bonjourRoute],
            deviceId: "9DDF920E-D7C4-51F2-9C94-67FF629BDF04",
            pubKeyFP: liveProtocolFingerprint
        )
        manager.replaceDevicesForTesting([stalePresentation])
        manager.replaceNetworkDiscoveredDevicesForTesting([liveCandidate])
        manager.recomputeDeviceStatusesForTesting()
        defer {
            manager.replaceNetworkDiscoveredDevicesForTesting([])
            manager.replaceDevicesForTesting([])
        }

        let resolved = try XCTUnwrap(manager.onlineDevices.first)
        XCTAssertFalse(resolved.isConnectable)
        XCTAssertEqual(manager.resolvedConnectableDiscoveredCandidates(for: resolved, limit: 1).count, 1)
        XCTAssertTrue(manager.hasResolvedConnectableControlRoute(for: resolved))
    }

    @MainActor
    func testLiveDiscoveredAppleMobileCandidateWithoutPortBlocksStalePresentationHost() throws {
        let manager = UnifiedOnlineDeviceManager.shared
        let bonjourRoute = "bonjour:iPad_Pro_11-inch__M4__local."
        let stableDeviceId = "9DDF920E-D7C4-51F2-9C94-67FF629BDF04"
        let stalePresentation = makeDevice(
            name: "Ziang的iPad",
            uniqueIdentifier: "id:\(stableDeviceId)",
            ipv4: "192.168.0.104",
            status: .online,
            lastConnectedAt: nil,
            isConnectable: true,
            connectionTypes: [.wifi],
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 9527],
            routeIdentifiers: [bonjourRoute],
            sources: [.skybridgeBonjour],
            platformName: "ipados",
            osVersion: "27.0",
            modelName: "iPad_Pro_11-inch__M4_",
            protocolFingerprint: liveProtocolFingerprint
        )
        let liveCandidate = DiscoveredDevice(
            id: UUID(),
            name: "iPad_Pro_11-inch__M4_",
            ipv4: "192.168.0.107",
            ipv6: nil,
            platformName: "ipados",
            osVersion: "27.0",
            modelName: "iPad_Pro_11-inch__M4_",
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 0],
            connectionTypes: [.wifi],
            uniqueIdentifier: "id:\(stableDeviceId)",
            routeIdentifiers: [bonjourRoute],
            deviceId: stableDeviceId,
            pubKeyFP: liveProtocolFingerprint
        )
        manager.replaceDevicesForTesting([stalePresentation])
        manager.replaceNetworkDiscoveredDevicesForTesting([liveCandidate])
        manager.recomputeDeviceStatusesForTesting()
        defer {
            manager.replaceNetworkDiscoveredDevicesForTesting([])
            manager.replaceDevicesForTesting([])
        }

        let resolved = try XCTUnwrap(manager.onlineDevices.first)
        let connectable = manager.resolvedConnectableDiscoveredCandidates(for: resolved, limit: 1)

        XCTAssertTrue(manager.hasUnresolvedLiveSkyBridgeControlRoute(for: resolved))
        XCTAssertEqual(connectable.count, 0)
        XCTAssertFalse(manager.hasResolvedConnectableControlRoute(for: resolved))
    }

    @MainActor
    func testLiveDiscoveredAppleMobileCandidateWithoutControlPortDoesNotEnableStalePresentation() throws {
        let manager = UnifiedOnlineDeviceManager.shared
        let bonjourRoute = "bonjour:iPad_Pro_11-inch__M4__local."
        let stalePresentation = makeDevice(
            name: "Ziang的iPad",
            uniqueIdentifier: "id:07CB9A6E-7492-4680-9DD7-F37DC8568891",
            ipv4: "192.168.0.104",
            status: .online,
            lastConnectedAt: nil,
            isConnectable: true,
            connectionTypes: [.wifi],
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 0],
            routeIdentifiers: [bonjourRoute],
            sources: [.skybridgeBonjour],
            platformName: "ipados",
            osVersion: "27.0",
            modelName: "iPad_Pro_11-inch__M4_",
            protocolFingerprint: liveProtocolFingerprint
        )
        let liveCandidate = DiscoveredDevice(
            id: UUID(),
            name: "iPad_Pro_11-inch__M4_",
            ipv4: nil,
            ipv6: nil,
            platformName: "ipados",
            osVersion: "27.0",
            modelName: "iPad_Pro_11-inch__M4_",
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 0],
            connectionTypes: [.wifi],
            uniqueIdentifier: "id:9DDF920E-D7C4-51F2-9C94-67FF629BDF04",
            routeIdentifiers: [bonjourRoute],
            deviceId: "9DDF920E-D7C4-51F2-9C94-67FF629BDF04",
            pubKeyFP: liveProtocolFingerprint
        )
        manager.replaceDevicesForTesting([stalePresentation])
        manager.replaceNetworkDiscoveredDevicesForTesting([liveCandidate])
        manager.recomputeDeviceStatusesForTesting()
        defer {
            manager.replaceNetworkDiscoveredDevicesForTesting([])
            manager.replaceDevicesForTesting([])
        }

        let resolved = try XCTUnwrap(manager.onlineDevices.first)
        XCTAssertFalse(
            resolved.isConnectable,
            "resolved isConnectable=\(resolved.isConnectable) portMap=\(resolved.portMap) platform=\(resolved.platformName ?? "-") model=\(resolved.modelName ?? "-") fingerprint=\(resolved.protocolFingerprint ?? "-") hasRoute=\(manager.hasResolvedConnectableControlRoute(for: resolved))"
        )
        XCTAssertEqual(manager.resolvedConnectableDiscoveredCandidates(for: resolved, limit: 1).count, 0)
        XCTAssertFalse(manager.hasResolvedConnectableControlRoute(for: resolved))
    }

    @MainActor
    func testRoutableAppleMobileBonjourWithoutProtocolFingerprintIsNotConnectable() throws {
        let manager = UnifiedOnlineDeviceManager.shared
        let staleBonjour = makeDevice(
            name: "Ziang的iPad",
            uniqueIdentifier: "id:07CB9A6E-7492-4680-9DD7-F37DC8568891",
            ipv4: "192.168.0.104",
            status: .online,
            lastConnectedAt: nil,
            isConnectable: true,
            connectionTypes: [.wifi],
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 9527],
            routeIdentifiers: ["bonjour:iPad_Pro_11-inch__M4__local."],
            sources: [.skybridgeBonjour],
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro"
        )
        manager.replaceDevicesForTesting([staleBonjour])
        defer { manager.replaceDevicesForTesting([]) }

        manager.recomputeDeviceStatusesForTesting()

        let resolved = try XCTUnwrap(manager.onlineDevices.first)
        XCTAssertFalse(resolved.isConnectable)
        XCTAssertFalse(manager.hasResolvedConnectableControlRoute(for: resolved))
    }

    @MainActor
    func testMergedAppleMobileRouteReplacesStaleLinkLocalIPv4WithLANIPv4() throws {
        let manager = UnifiedOnlineDeviceManager.shared
        let staleCloud = makeDevice(
            name: "Ziang的iPad",
            uniqueIdentifier: "serial:icloud-device-chain-ipad",
            ipv4: "169.254.185.245",
            status: .online,
            lastConnectedAt: nil,
            isConnectable: false,
            connectionTypes: [],
            services: [],
            portMap: [:],
            routeIdentifiers: [],
            sources: [.skybridgeCloud],
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro"
        )
        let liveBonjour = makeDevice(
            name: "Ziang的iPad",
            uniqueIdentifier: "bonjour:Ziang的iPad@local.",
            ipv4: "192.168.0.104",
            status: .online,
            lastConnectedAt: nil,
            isConnectable: true,
            connectionTypes: [.wifi],
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 9527],
            routeIdentifiers: ["bonjour:Ziang的iPad@local."],
            sources: [.skybridgeBonjour],
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro",
            protocolFingerprint: liveProtocolFingerprint
        )
        manager.replaceDevicesForTesting([staleCloud, liveBonjour])
        defer { manager.replaceDevicesForTesting([]) }

        manager.recomputeDeviceStatusesForTesting()

        XCTAssertEqual(manager.onlineDevices.count, 1)
        let resolved = try XCTUnwrap(manager.onlineDevices.first)
        XCTAssertEqual(resolved.ipv4, "192.168.0.104")
        XCTAssertEqual(
            resolved.protocolFingerprint,
            "336b022ee58b653f08569a1be0e32a740da127882b79897589e75a95f0e2b94c"
        )
        XCTAssertTrue(manager.hasResolvedConnectableControlRoute(for: resolved))
    }

    @MainActor
    func testRoutableAppleMobileBonjourRowShadowsStaleLinkLocalIdentityRow() throws {
        let manager = UnifiedOnlineDeviceManager.shared
        let staleBonjour = makeDevice(
            name: "Ziang的iPad",
            uniqueIdentifier: "id:51D74800-4C6F-41AA-9F73-711751AF0B56",
            ipv4: "169.254.185.245",
            status: .online,
            lastConnectedAt: nil,
            isConnectable: true,
            connectionTypes: [.usb, .wifi],
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 9527],
            routeIdentifiers: ["bonjour:Ziang的iPad@local."],
            sources: [.skybridgeBonjour],
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro",
            protocolFingerprint: liveProtocolFingerprint
        )
        let routableBonjour = makeDevice(
            name: "iPad",
            uniqueIdentifier: "id:EFDF569E-194A-44AF-B288-ADD5B4EAFF77",
            ipv4: "192.168.0.104",
            status: .online,
            lastConnectedAt: nil,
            isConnectable: true,
            connectionTypes: [.wifi],
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 9527],
            routeIdentifiers: ["bonjour:iPad@local."],
            sources: [.skybridgeBonjour],
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro",
            protocolFingerprint: "336b022ee58b653f08569a1be0e32a740da127882b79897589e75a95f0e2b94c"
        )
        manager.replaceDevicesForTesting([staleBonjour, routableBonjour])
        defer { manager.replaceDevicesForTesting([]) }

        manager.recomputeDeviceStatusesForTesting()

        XCTAssertEqual(manager.onlineDevices.count, 1)
        let resolved = try XCTUnwrap(manager.onlineDevices.first)
        XCTAssertEqual(resolved.uniqueIdentifier, "id:EFDF569E-194A-44AF-B288-ADD5B4EAFF77")
        XCTAssertEqual(resolved.ipv4, "192.168.0.104")
        XCTAssertTrue(manager.hasResolvedConnectableControlRoute(for: resolved))
    }

    @MainActor
    func testUSBOnlyAppleMobilePresenceDoesNotCreateControlRoute() throws {
        let manager = UnifiedOnlineDeviceManager.shared
        let usbOnly = makeDevice(
            name: "Ziang的iPad",
            uniqueIdentifier: "serial:00008103-0011223344556677",
            ipv4: nil,
            status: .online,
            lastConnectedAt: nil,
            isConnectable: true,
            connectionTypes: [.usb],
            services: [],
            portMap: [:],
            routeIdentifiers: [],
            sources: [.skybridgeUSB],
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro"
        )
        manager.replaceDevicesForTesting([usbOnly])
        defer { manager.replaceDevicesForTesting([]) }

        manager.recomputeDeviceStatusesForTesting()

        let resolved = try XCTUnwrap(manager.onlineDevices.first)
        XCTAssertFalse(resolved.isConnectable)
        XCTAssertFalse(manager.hasResolvedConnectableControlRoute(for: resolved))
    }

    @MainActor
    func testCloudAndBonjourMergeKeepsStableIdentityAndRealBonjourRoute() throws {
        let manager = UnifiedOnlineDeviceManager.shared
        let cloudOnly = makeDevice(
            name: "Ziang的iPad",
            uniqueIdentifier: "serial:icloud-ipad",
            ipv4: nil,
            status: .online,
            lastConnectedAt: nil,
            isConnectable: false,
            connectionTypes: [],
            services: [],
            portMap: [:],
            routeIdentifiers: [],
            sources: [.skybridgeCloud],
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro"
        )
        let stableBonjour = makeDevice(
            name: "Ziang的iPad",
            uniqueIdentifier: "id:07CB9A6E-1111-4222-8333-123456789ABC",
            ipv4: nil,
            status: .online,
            lastConnectedAt: nil,
            isConnectable: true,
            connectionTypes: [.wifi],
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 9527],
            routeIdentifiers: ["bonjour:Ziang的iPad@local."],
            sources: [.skybridgeBonjour],
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro",
            protocolFingerprint: liveProtocolFingerprint
        )
        manager.replaceDevicesForTesting([cloudOnly, stableBonjour])
        defer { manager.replaceDevicesForTesting([]) }

        manager.recomputeDeviceStatusesForTesting()

        let resolved = try XCTUnwrap(manager.onlineDevices.first)
        XCTAssertEqual(manager.onlineDevices.count, 1)
        XCTAssertEqual(resolved.uniqueIdentifier, "id:07CB9A6E-1111-4222-8333-123456789ABC")
        XCTAssertEqual(resolved.routeIdentifiers, ["bonjour:Ziang的iPad@local."])
        XCTAssertTrue(manager.hasResolvedConnectableControlRoute(for: resolved))
    }

    @MainActor
    func testCloudUSBAndBonjourIPadRowsCoalesceDespitePseudoSerialAndPlatformAlias() throws {
        let manager = UnifiedOnlineDeviceManager.shared
        let cloudOnly = makeDevice(
            name: "Ziang的iPad",
            uniqueIdentifier: "serial:icloud-device-chain-ipad",
            ipv4: nil,
            status: .online,
            lastConnectedAt: nil,
            isConnectable: false,
            connectionTypes: [],
            services: [],
            portMap: [:],
            routeIdentifiers: [],
            sources: [.skybridgeCloud],
            platformName: nil,
            osVersion: "26.5",
            modelName: "iPad",
            serialNumber: "icloud-device-chain-ipad"
        )
        let usbHistory = makeDevice(
            name: "Ziang的iPad",
            uniqueIdentifier: "serial:00008103-0011223344556677",
            ipv4: nil,
            status: .offline,
            lastConnectedAt: Date(timeIntervalSince1970: 100),
            isConnectable: true,
            connectionTypes: [.usb],
            services: [],
            portMap: [:],
            routeIdentifiers: [],
            sources: [.skybridgeUSB],
            platformName: "iOS",
            osVersion: "26.5",
            modelName: "iPad Pro",
            lastSeen: Date(timeIntervalSinceNow: -30),
            serialNumber: "00008103-0011223344556677"
        )
        let bonjour = makeDevice(
            name: "Ziang的iPad",
            uniqueIdentifier: "bonjour:Ziang的iPad@local.",
            ipv4: "192.168.0.103",
            status: .online,
            lastConnectedAt: nil,
            isConnectable: true,
            connectionTypes: [.wifi],
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 11550],
            routeIdentifiers: ["bonjour:Ziang的iPad@local."],
            sources: [.skybridgeBonjour],
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro",
            protocolFingerprint: liveProtocolFingerprint
        )
        manager.replaceDevicesForTesting([cloudOnly, usbHistory, bonjour])
        defer { manager.replaceDevicesForTesting([]) }

        manager.recomputeDeviceStatusesForTesting()

        XCTAssertEqual(manager.onlineDevices.count, 1)
        let resolved = try XCTUnwrap(manager.onlineDevices.first)
        XCTAssertEqual(resolved.uniqueIdentifier, "bonjour:Ziang的iPad@local.")
        XCTAssertEqual(resolved.ipv4, "192.168.0.103")
        XCTAssertEqual(resolved.platformName, "iPadOS")
        XCTAssertEqual(resolved.modelName, "iPad Pro")
        XCTAssertTrue(resolved.connectionTypes.contains(.usb))
        XCTAssertTrue(resolved.connectionTypes.contains(.wifi))
        XCTAssertTrue(resolved.sources.contains(.skybridgeCloud))
        XCTAssertTrue(resolved.sources.contains(.skybridgeUSB))
        XCTAssertTrue(resolved.sources.contains(.skybridgeBonjour))
        XCTAssertTrue(manager.hasResolvedConnectableControlRoute(for: resolved))
        XCTAssertEqual(resolved.serialNumber, "00008103-0011223344556677")
    }

    @MainActor
    func testCloudUSBBonjourAndHostIPadRowsCoalesceAndPreserveDialableRoute() throws {
        let manager = UnifiedOnlineDeviceManager.shared
        let cloudOnly = makeDevice(
            name: "Ziang的iPad",
            uniqueIdentifier: "serial:icloud-device-chain-ipad",
            ipv4: nil,
            status: .online,
            lastConnectedAt: nil,
            isConnectable: false,
            connectionTypes: [],
            services: [],
            portMap: [:],
            routeIdentifiers: [],
            sources: [.skybridgeCloud],
            platformName: nil,
            osVersion: "26.5",
            modelName: "iPad",
            serialNumber: "icloud-device-chain-ipad"
        )
        let usbHistory = makeDevice(
            name: "Ziang的iPad",
            uniqueIdentifier: "serial:00008103-0011223344556677",
            ipv4: nil,
            status: .offline,
            lastConnectedAt: Date(timeIntervalSince1970: 100),
            isConnectable: true,
            connectionTypes: [.usb],
            services: [],
            portMap: [:],
            routeIdentifiers: [],
            sources: [.skybridgeUSB],
            platformName: "iOS",
            osVersion: "26.5",
            modelName: "iPad Pro",
            lastSeen: Date(timeIntervalSinceNow: -30),
            serialNumber: "00008103-0011223344556677"
        )
        let bonjour = makeDevice(
            name: "Ziang的iPad",
            uniqueIdentifier: "bonjour:Ziang的iPad@local.",
            ipv4: "192.168.0.103",
            status: .online,
            lastConnectedAt: nil,
            isConnectable: true,
            connectionTypes: [.wifi],
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 11550],
            routeIdentifiers: ["bonjour:Ziang的iPad@local."],
            sources: [.skybridgeBonjour],
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro"
        )
        let host = makeDevice(
            name: "Ziang的iPad",
            uniqueIdentifier: "host:192.168.0.103",
            ipv4: "192.168.0.103",
            status: .online,
            lastConnectedAt: nil,
            isConnectable: true,
            connectionTypes: [.wifi],
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 11550],
            routeIdentifiers: [],
            sources: [.skybridgeP2P],
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro",
            protocolFingerprint: liveProtocolFingerprint
        )
        manager.replaceDevicesForTesting([cloudOnly, usbHistory, bonjour, host])
        defer { manager.replaceDevicesForTesting([]) }

        manager.recomputeDeviceStatusesForTesting()

        XCTAssertEqual(manager.onlineDevices.count, 1)
        let resolved = try XCTUnwrap(manager.onlineDevices.first)
        XCTAssertEqual(resolved.ipv4, "192.168.0.103")
        XCTAssertEqual(resolved.serialNumber, "00008103-0011223344556677")
        XCTAssertTrue(resolved.routeIdentifiers.contains("bonjour:Ziang的iPad@local."))
        XCTAssertTrue(resolved.sources.contains(.skybridgeCloud))
        XCTAssertTrue(resolved.sources.contains(.skybridgeUSB))
        XCTAssertTrue(resolved.sources.contains(.skybridgeBonjour))
        XCTAssertTrue(resolved.sources.contains(.skybridgeP2P))
        XCTAssertTrue(manager.hasResolvedConnectableControlRoute(for: resolved))
    }

    @MainActor
    func testUSBGenericIPadNameCoalescesWithPersonalizedBonjourAndP2PRoutes() throws {
        let manager = UnifiedOnlineDeviceManager.shared
        let usb = makeDevice(
            name: "iPad",
            uniqueIdentifier: "serial:00008103-0011223344556677",
            ipv4: nil,
            status: .offline,
            lastConnectedAt: Date(timeIntervalSince1970: 100),
            isConnectable: false,
            connectionTypes: [.usb],
            services: [],
            portMap: [:],
            routeIdentifiers: [],
            sources: [.skybridgeUSB],
            platformName: "iOS",
            osVersion: "26.5",
            modelName: "iPad Pro",
            serialNumber: "00008103-0011223344556677"
        )
        let bonjour = makeDevice(
            name: "Ziang的iPad",
            uniqueIdentifier: "bonjour:Ziang的iPad@local.",
            ipv4: "192.168.0.103",
            status: .online,
            lastConnectedAt: nil,
            isConnectable: true,
            connectionTypes: [.wifi],
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 11550],
            routeIdentifiers: ["bonjour:Ziang的iPad@local."],
            sources: [.skybridgeBonjour],
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro"
        )
        let p2pHost = makeDevice(
            name: "192.168.0.103",
            uniqueIdentifier: "host:192.168.0.103",
            ipv4: "192.168.0.103",
            status: .online,
            lastConnectedAt: nil,
            isConnectable: true,
            connectionTypes: [.wifi],
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 11550],
            routeIdentifiers: [],
            sources: [.skybridgeP2P],
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro",
            protocolFingerprint: liveProtocolFingerprint
        )
        manager.replaceDevicesForTesting([usb, bonjour, p2pHost])
        defer { manager.replaceDevicesForTesting([]) }

        manager.recomputeDeviceStatusesForTesting()

        XCTAssertEqual(manager.onlineDevices.count, 1)
        let resolved = try XCTUnwrap(manager.onlineDevices.first)
        XCTAssertEqual(resolved.name, "Ziang的iPad")
        XCTAssertEqual(resolved.ipv4, "192.168.0.103")
        XCTAssertTrue(resolved.connectionTypes.contains(.usb))
        XCTAssertTrue(resolved.connectionTypes.contains(.wifi))
        XCTAssertTrue(resolved.sources.contains(.skybridgeUSB))
        XCTAssertTrue(resolved.sources.contains(.skybridgeBonjour))
        XCTAssertTrue(resolved.sources.contains(.skybridgeP2P))
        XCTAssertTrue(manager.hasResolvedConnectableControlRoute(for: resolved))
    }

    func testGenericIPadNameDoesNotCoalesceTwoNetworkOnlyRows() {
        let genericNetwork = makeDevice(
            name: "iPad",
            uniqueIdentifier: "bonjour:iPad@local.",
            ipv4: "192.168.0.103",
            status: .online,
            lastConnectedAt: nil,
            isConnectable: true,
            connectionTypes: [.wifi],
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 11550],
            routeIdentifiers: ["bonjour:iPad@local."],
            sources: [.skybridgeBonjour],
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro"
        )
        let personalizedNetwork = makeDevice(
            name: "Ziang的iPad",
            uniqueIdentifier: "bonjour:Ziang的iPad@local.",
            ipv4: "192.168.0.120",
            status: .online,
            lastConnectedAt: nil,
            isConnectable: true,
            connectionTypes: [.wifi],
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 11551],
            routeIdentifiers: ["bonjour:Ziang的iPad@local."],
            sources: [.skybridgeBonjour],
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro"
        )

        XCTAssertFalse(
            UnifiedOnlineDeviceManager.shouldCoalesceEquivalentPhysicalDevices(
                genericNetwork,
                personalizedNetwork
            )
        )
    }

    @MainActor
    func testStableGenericIPadRowKeepsPersonalizedBonjourNameAfterCoalescing() throws {
        let manager = UnifiedOnlineDeviceManager.shared
        let stable = makeDevice(
            name: "iPad",
            uniqueIdentifier: "id:550E8400-E29B-41D4-A716-446655440004",
            ipv4: "192.168.0.103",
            status: .online,
            lastConnectedAt: nil,
            isConnectable: true,
            connectionTypes: [.wifi],
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 11550],
            routeIdentifiers: ["bonjour:Ziang的iPad@local."],
            sources: [.skybridgeCloud],
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro",
            protocolFingerprint: liveProtocolFingerprint
        )
        let bonjour = makeDevice(
            name: "Ziang的iPad",
            uniqueIdentifier: "bonjour:Ziang的iPad@local.",
            ipv4: "192.168.0.103",
            status: .online,
            lastConnectedAt: nil,
            isConnectable: true,
            connectionTypes: [.wifi],
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 11550],
            routeIdentifiers: ["bonjour:Ziang的iPad@local."],
            sources: [.skybridgeBonjour],
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro",
            protocolFingerprint: liveProtocolFingerprint
        )
        manager.replaceDevicesForTesting([stable, bonjour])
        defer { manager.replaceDevicesForTesting([]) }

        manager.recomputeDeviceStatusesForTesting()

        XCTAssertEqual(manager.onlineDevices.count, 1)
        let resolved = try XCTUnwrap(manager.onlineDevices.first)
        XCTAssertEqual(resolved.uniqueIdentifier, "id:550E8400-E29B-41D4-A716-446655440004")
        XCTAssertEqual(resolved.name, "Ziang的iPad")
        XCTAssertTrue(resolved.sources.contains(.skybridgeCloud))
        XCTAssertTrue(resolved.sources.contains(.skybridgeBonjour))
        XCTAssertTrue(manager.hasResolvedConnectableControlRoute(for: resolved))
    }

    @MainActor
    func testMergedIPadRowsPreferHumanDisplayNameOverGenericAndRouteIdentifiers() throws {
        let manager = UnifiedOnlineDeviceManager.shared
        let stableDeviceId = "550E8400-E29B-41D4-A716-446655440088"
        let cloud = makeDevice(
            name: "Ziang的iPad",
            uniqueIdentifier: "id:\(stableDeviceId)",
            ipv4: nil,
            status: .online,
            lastConnectedAt: nil,
            isConnectable: false,
            connectionTypes: [],
            services: [],
            portMap: [:],
            routeIdentifiers: [],
            sources: [.skybridgeCloud],
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro 11-inch (M4)"
        )
        let genericBonjour = makeDevice(
            name: "iPad",
            uniqueIdentifier: "bonjour:iPad@local.",
            ipv4: "192.168.0.103",
            status: .online,
            lastConnectedAt: nil,
            isConnectable: true,
            connectionTypes: [.wifi],
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 11550],
            routeIdentifiers: ["bonjour:iPad@local."],
            sources: [.skybridgeBonjour],
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro 11-inch (M4)",
            protocolFingerprint: liveProtocolFingerprint
        )
        let hostAlias = makeDevice(
            name: "host:192.168.0.103",
            uniqueIdentifier: "host:192.168.0.103",
            ipv4: "192.168.0.103",
            status: .online,
            lastConnectedAt: nil,
            isConnectable: true,
            connectionTypes: [.wifi],
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 11550],
            sources: [.skybridgeP2P],
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro 11-inch (M4)",
            protocolFingerprint: liveProtocolFingerprint
        )
        manager.replaceDevicesForTesting([genericBonjour, hostAlias, cloud])
        defer { manager.replaceDevicesForTesting([]) }

        manager.recomputeDeviceStatusesForTesting()

        XCTAssertEqual(manager.onlineDevices.count, 1)
        let resolved = try XCTUnwrap(manager.onlineDevices.first)
        XCTAssertEqual(resolved.name, "Ziang的iPad")
        XCTAssertEqual(resolved.ipv4, "192.168.0.103")
        XCTAssertTrue(manager.hasResolvedConnectableControlRoute(for: resolved))
    }

    @MainActor
    func testGenericIPadRowsPreferModelNameWhenNoHumanNameExists() throws {
        let manager = UnifiedOnlineDeviceManager.shared
        let stableDeviceId = "550E8400-E29B-41D4-A716-446655440089"
        let stable = makeDevice(
            name: "id:\(stableDeviceId)",
            uniqueIdentifier: "id:\(stableDeviceId)",
            ipv4: nil,
            status: .online,
            lastConnectedAt: nil,
            isConnectable: false,
            connectionTypes: [],
            services: [],
            portMap: [:],
            routeIdentifiers: [],
            sources: [.skybridgeCloud],
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro 11-inch (M4)"
        )
        let genericBonjour = makeDevice(
            name: "iPad",
            uniqueIdentifier: "bonjour:iPad@local.",
            ipv4: "192.168.0.103",
            status: .online,
            lastConnectedAt: nil,
            isConnectable: true,
            connectionTypes: [.wifi],
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 11550],
            routeIdentifiers: ["bonjour:iPad@local."],
            sources: [.skybridgeBonjour],
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro 11-inch (M4)"
        )
        manager.replaceDevicesForTesting([stable, genericBonjour])
        defer { manager.replaceDevicesForTesting([]) }

        manager.recomputeDeviceStatusesForTesting()

        XCTAssertEqual(manager.onlineDevices.count, 1)
        XCTAssertEqual(manager.onlineDevices.first?.name, "iPad Pro 11-inch (M4)")
    }

    @MainActor
    func testGenericIPadRowsDoNotUsePlatformAsDisplayNameWhenModelIsMissing() throws {
        let manager = UnifiedOnlineDeviceManager.shared
        let stableDeviceId = "550E8400-E29B-41D4-A716-446655440090"
        let bonjourRoute = "bonjour:iPad@local."
        let stable = makeDevice(
            name: "id:550E8400-E29B-41D4-A716-446655440090",
            uniqueIdentifier: "id:\(stableDeviceId)",
            ipv4: nil,
            status: .online,
            lastConnectedAt: nil,
            isConnectable: false,
            connectionTypes: [],
            services: [],
            portMap: [:],
            routeIdentifiers: [bonjourRoute],
            sources: [.skybridgeCloud],
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: nil
        )
        let genericBonjour = makeDevice(
            name: "iPad",
            uniqueIdentifier: bonjourRoute,
            ipv4: "192.168.0.103",
            status: .online,
            lastConnectedAt: nil,
            isConnectable: true,
            connectionTypes: [.wifi],
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 11550],
            routeIdentifiers: [bonjourRoute],
            sources: [.skybridgeBonjour],
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: nil
        )
        manager.replaceDevicesForTesting([stable, genericBonjour])
        defer { manager.replaceDevicesForTesting([]) }

        manager.recomputeDeviceStatusesForTesting()

        XCTAssertEqual(manager.onlineDevices.count, 1)
        XCTAssertEqual(manager.onlineDevices.first?.name, "iPad")
    }

    @MainActor
    func testLegacyCloudSerialStableIDCoalescesWithBonjourStableIDWhenNamesDiffer() throws {
        let manager = UnifiedOnlineDeviceManager.shared
        let stableDeviceId = "ipad-stable-device-id"
        let legacyCloudOnly = makeDevice(
            name: "Ziang的iPad",
            uniqueIdentifier: "serial:\(stableDeviceId)",
            ipv4: nil,
            status: .online,
            lastConnectedAt: nil,
            isConnectable: false,
            connectionTypes: [],
            services: [],
            portMap: [:],
            routeIdentifiers: [],
            sources: [.skybridgeCloud],
            platformName: nil,
            osVersion: "26.5",
            modelName: "iPad",
            serialNumber: stableDeviceId
        )
        let liveBonjour = makeDevice(
            name: "iPad",
            uniqueIdentifier: "id:\(stableDeviceId)",
            ipv4: "192.168.0.103",
            status: .online,
            lastConnectedAt: nil,
            isConnectable: true,
            connectionTypes: [.wifi],
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 11550],
            routeIdentifiers: ["bonjour:iPad@local."],
            sources: [.skybridgeBonjour],
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro",
            protocolFingerprint: liveProtocolFingerprint
        )
        let hostAlias = makeDevice(
            name: "192.168.0.103",
            uniqueIdentifier: "host:192.168.0.103",
            ipv4: "192.168.0.103",
            status: .online,
            lastConnectedAt: nil,
            isConnectable: true,
            connectionTypes: [.wifi],
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 11550],
            routeIdentifiers: [],
            sources: [.skybridgeP2P],
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro",
            protocolFingerprint: liveProtocolFingerprint
        )
        manager.replaceDevicesForTesting([legacyCloudOnly, liveBonjour, hostAlias])
        defer { manager.replaceDevicesForTesting([]) }

        manager.recomputeDeviceStatusesForTesting()

        XCTAssertEqual(manager.onlineDevices.count, 1)
        let resolved = try XCTUnwrap(manager.onlineDevices.first)
        XCTAssertEqual(resolved.uniqueIdentifier, "id:\(stableDeviceId)")
        XCTAssertEqual(resolved.serialNumber, nil)
        XCTAssertEqual(resolved.ipv4, "192.168.0.103")
        XCTAssertTrue(resolved.routeIdentifiers.contains("bonjour:iPad@local."))
        XCTAssertTrue(resolved.sources.contains(.skybridgeCloud))
        XCTAssertTrue(resolved.sources.contains(.skybridgeBonjour))
        XCTAssertTrue(resolved.sources.contains(.skybridgeP2P))
        XCTAssertTrue(manager.hasResolvedConnectableControlRoute(for: resolved))
    }

    @MainActor
    func testCloudHeartbeatDoesNotKeepStaleBonjourRouteConnectable() throws {
        let manager = UnifiedOnlineDeviceManager.shared
        let stale = Date(timeIntervalSinceNow: -180)
        let recent = Date()
        let staleBonjour = makeDevice(
            name: "Ziang的iPad",
            uniqueIdentifier: "bonjour:Ziang的iPad@local.",
            ipv4: "192.168.0.103",
            status: .offline,
            lastConnectedAt: Date(timeIntervalSince1970: 100),
            isConnectable: true,
            connectionTypes: [.wifi],
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 11550],
            routeIdentifiers: ["bonjour:Ziang的iPad@local."],
            sources: [.skybridgeBonjour],
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro",
            lastSeen: stale
        )
        let cloudHeartbeat = makeDevice(
            name: "Ziang的iPad",
            uniqueIdentifier: "serial:icloud-ipad",
            ipv4: nil,
            status: .online,
            lastConnectedAt: nil,
            isConnectable: false,
            connectionTypes: [],
            services: [],
            portMap: [:],
            routeIdentifiers: [],
            sources: [.skybridgeCloud],
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro",
            lastSeen: recent
        )
        manager.replaceDevicesForTesting([staleBonjour, cloudHeartbeat])
        defer { manager.replaceDevicesForTesting([]) }

        manager.recomputeDeviceStatusesForTesting()

        XCTAssertEqual(manager.onlineDevices.count, 1)
        let resolved = try XCTUnwrap(manager.onlineDevices.first)
        XCTAssertEqual(resolved.name, "Ziang的iPad")
        XCTAssertEqual(resolved.connectionStatus, .online)
        XCTAssertFalse(resolved.isConnectable)
        XCTAssertFalse(manager.hasResolvedConnectableControlRoute(for: resolved))
    }

    func testRecentEntrySurvivesWithoutEquivalentRealRecord() {
        let recent = makeDevice(
            name: "MacBook Pro",
            uniqueIdentifier: "recent:id:peer-2",
            status: .connected,
            lastConnectedAt: Date()
        )
        let unrelated = makeDevice(
            name: "Other Mac",
            uniqueIdentifier: "id:peer-3",
            ipv4: "192.168.31.21",
            status: .online,
            lastConnectedAt: Date(),
            isConnectable: true
        )

        XCTAssertFalse(
            UnifiedOnlineDeviceManager.shouldCollapseRecentDevice(recent, against: [unrelated])
        )
    }

    func testUSBAndBonjourRowsForSameRecentIPhoneCoalesce() {
        let usb = makeDevice(
            name: "Ziang的iPhone 16 Pro",
            uniqueIdentifier: "serial:00008140-000E788401C0801C",
            status: .offline,
            lastConnectedAt: Date(timeIntervalSince1970: 100),
            isConnectable: true,
            connectionTypes: [.usb],
            services: [],
            portMap: [:],
            platformName: "iOS",
            osVersion: "26.5",
            modelName: "iPhone 16 Pro"
        )
        let bonjour = makeDevice(
            name: "Ziang的iPhone 16 Pro",
            uniqueIdentifier: "bonjour:Ziang的iPhone 16 Pro@local.",
            ipv4: "192.168.0.106",
            status: .online,
            lastConnectedAt: Date(timeIntervalSince1970: 200),
            isConnectable: true,
            connectionTypes: [.wifi],
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 50873],
            platformName: "iOS",
            osVersion: "26.5",
            modelName: "iPhone 16 Pro"
        )

        XCTAssertTrue(
            UnifiedOnlineDeviceManager.shouldCoalesceEquivalentPhysicalDevices(usb, bonjour)
        )
    }

    func testPseudoCloudSerialDoesNotBlockUSBAndBonjourIPadCoalescing() {
        let cloudShadow = makeDevice(
            name: "Ziang的iPad",
            uniqueIdentifier: "serial:icloud-device-chain-ipad",
            status: .online,
            lastConnectedAt: Date(timeIntervalSince1970: 100),
            isConnectable: false,
            connectionTypes: [.usb],
            services: [],
            portMap: [:],
            sources: [.skybridgeCloud, .skybridgeUSB],
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro",
            serialNumber: "icloud-device-chain-ipad"
        )
        let liveBonjour = makeDevice(
            name: "Ziang的iPad",
            uniqueIdentifier: "bonjour:Ziang的iPad@local.",
            ipv4: "192.168.0.102",
            status: .online,
            lastConnectedAt: nil,
            isConnectable: true,
            connectionTypes: [.wifi],
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 51537],
            routeIdentifiers: ["bonjour:Ziang的iPad@local."],
            sources: [.skybridgeBonjour],
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro"
        )

        XCTAssertTrue(
            UnifiedOnlineDeviceManager.shouldCoalesceEquivalentPhysicalDevices(cloudShadow, liveBonjour)
        )
    }

    func testRecentPeerAliasCoalescesWithLiveHostRoute() {
        let recentPeerAlias = makeDevice(
            name: "peer:192.168.0.102",
            uniqueIdentifier: "recent:peer:192.168.0.102",
            status: .offline,
            lastConnectedAt: Date(timeIntervalSince1970: 100),
            isConnectable: false,
            connectionTypes: [.wifi],
            services: [],
            portMap: [:]
        )
        let liveHostRoute = makeDevice(
            name: "Ziang的iPad",
            uniqueIdentifier: "host:192.168.0.102",
            ipv4: "192.168.0.102",
            status: .online,
            lastConnectedAt: nil,
            isConnectable: true,
            connectionTypes: [.wifi],
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 51537],
            sources: [.skybridgeP2P],
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro"
        )

        XCTAssertTrue(
            UnifiedOnlineDeviceManager.shouldCoalesceEquivalentPhysicalDevices(recentPeerAlias, liveHostRoute)
        )
    }

    func testMacSkyBridgeServiceRowsWithSameNameCoalesceAcrossComplementaryRoutes() {
        let bonjourControl = makeDevice(
            name: "Lza的MacBook Pro",
            uniqueIdentifier: "bonjour:Lza的MacBook Pro@local.",
            status: .online,
            lastConnectedAt: nil,
            isConnectable: true,
            connectionTypes: [.wifi],
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 51542],
            routeIdentifiers: ["bonjour:Lza的MacBook Pro@local."],
            sources: [.skybridgeBonjour],
            platformName: "macOS",
            osVersion: "15.5",
            modelName: "MacBook Pro"
        )
        let remoteControl = makeDevice(
            name: "Lza的MacBook Pro",
            uniqueIdentifier: "ip:192.168.0.101",
            ipv4: "192.168.0.101",
            status: .online,
            lastConnectedAt: nil,
            isConnectable: true,
            connectionTypes: [.wifi],
            services: ["_skybridge-remote._tcp"],
            portMap: ["_skybridge-remote._tcp": 5901],
            routeIdentifiers: ["host:192.168.0.101"],
            sources: [.skybridgeP2P],
            platformName: "macOS",
            osVersion: "15.5",
            modelName: "MacBookPro18,2"
        )

        XCTAssertTrue(
            UnifiedOnlineDeviceManager.shouldCoalesceEquivalentPhysicalDevices(
                bonjourControl,
                remoteControl
            )
        )
    }

    func testMacPersonalizedNameCoalescesWithHardwareModelServiceAlias() {
        let bonjourControl = makeDevice(
            name: "Lza的MacBook Pro",
            uniqueIdentifier: "bonjour:Lza的MacBook Pro@local.",
            status: .online,
            lastConnectedAt: nil,
            isConnectable: true,
            connectionTypes: [.wifi],
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 51752],
            routeIdentifiers: ["bonjour:Lza的MacBook Pro@local."],
            sources: [.skybridgeBonjour],
            platformName: "macOS",
            osVersion: "26.5",
            modelName: "MacBook Pro"
        )
        let remoteControlAlias = makeDevice(
            name: "MacBookPro18,2",
            uniqueIdentifier: "bonjour:MacBookPro18,2@local.",
            status: .online,
            lastConnectedAt: nil,
            isConnectable: true,
            connectionTypes: [.wifi],
            services: ["_skybridge-remote._tcp"],
            portMap: ["_skybridge-remote._tcp": 51776],
            routeIdentifiers: ["bonjour:MacBookPro18,2@local."],
            sources: [.skybridgeBonjour],
            platformName: "macOS",
            osVersion: "26.5",
            modelName: "MacBookPro18,2"
        )

        XCTAssertTrue(
            UnifiedOnlineDeviceManager.shouldCoalesceEquivalentPhysicalDevices(
                bonjourControl,
                remoteControlAlias
            )
        )
    }

    @MainActor
    func testUpdateDevicesListCoalescesMacHardwareModelAliasRows() throws {
        let manager = UnifiedOnlineDeviceManager.shared
        let bonjourControl = makeDevice(
            name: "Lza的MacBook Pro",
            uniqueIdentifier: "bonjour:Lza的MacBook Pro@local.",
            status: .online,
            lastConnectedAt: nil,
            isConnectable: true,
            connectionTypes: [.wifi],
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 51752],
            routeIdentifiers: ["bonjour:Lza的MacBook Pro@local."],
            sources: [.skybridgeBonjour],
            platformName: "macOS",
            osVersion: "26.5",
            modelName: "MacBook Pro"
        )
        let remoteControlAlias = makeDevice(
            name: "MacBookPro18,2",
            uniqueIdentifier: "bonjour:MacBookPro18,2@local.",
            status: .online,
            lastConnectedAt: nil,
            isConnectable: true,
            connectionTypes: [.wifi],
            services: ["_skybridge-remote._tcp"],
            portMap: ["_skybridge-remote._tcp": 51776],
            routeIdentifiers: ["bonjour:MacBookPro18,2@local."],
            sources: [.skybridgeBonjour],
            platformName: "macOS",
            osVersion: "26.5",
            modelName: "MacBookPro18,2"
        )
        manager.replaceDevicesForTesting([bonjourControl, remoteControlAlias])
        defer { manager.replaceDevicesForTesting([]) }

        manager.recomputeDeviceStatusesForTesting()

        XCTAssertEqual(manager.onlineDevices.count, 1)
        let resolved = try XCTUnwrap(manager.onlineDevices.first)
        XCTAssertEqual(resolved.name, "Lza的MacBook Pro")
        XCTAssertTrue(resolved.services.contains("_skybridge._tcp"))
        XCTAssertTrue(resolved.services.contains("_skybridge-remote._tcp"))
        XCTAssertEqual(resolved.portMap["_skybridge._tcp"], 51752)
        XCTAssertEqual(resolved.portMap["_skybridge-remote._tcp"], 51776)
    }

    func testDifferentMacNamesDoNotCoalesceAcrossSkyBridgeRoutes() {
        let first = makeDevice(
            name: "Lza的MacBook Pro",
            uniqueIdentifier: "bonjour:Lza的MacBook Pro@local.",
            status: .online,
            lastConnectedAt: nil,
            isConnectable: true,
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 51542],
            routeIdentifiers: ["bonjour:Lza的MacBook Pro@local."],
            platformName: "macOS",
            modelName: "MacBook Pro"
        )
        let second = makeDevice(
            name: "Studio Mac",
            uniqueIdentifier: "ip:192.168.0.110",
            ipv4: "192.168.0.110",
            status: .online,
            lastConnectedAt: nil,
            isConnectable: true,
            services: ["_skybridge-remote._tcp"],
            portMap: ["_skybridge-remote._tcp": 5901],
            routeIdentifiers: ["host:192.168.0.110"],
            platformName: "macOS",
            modelName: "Mac Studio"
        )

        XCTAssertFalse(
            UnifiedOnlineDeviceManager.shouldCoalesceEquivalentPhysicalDevices(first, second)
        )
    }

    @MainActor
    func testUpdateDevicesListCoalescesPersistedUSBAndBonjourRowsForSameRecentIPhone() throws {
        let manager = UnifiedOnlineDeviceManager.shared
        let usb = makeDevice(
            name: "Ziang的iPhone 16 Pro",
            uniqueIdentifier: "serial:00008140-000E788401C0801C",
            status: .offline,
            lastConnectedAt: Date(timeIntervalSince1970: 100),
            isConnectable: true,
            connectionTypes: [.usb],
            services: [],
            portMap: [:],
            platformName: "iOS",
            osVersion: "26.5",
            modelName: "iPhone 16 Pro"
        )
        let bonjour = makeDevice(
            name: "Ziang的iPhone 16 Pro",
            uniqueIdentifier: "bonjour:Ziang的iPhone 16 Pro@local.",
            ipv4: "192.168.0.106",
            status: .online,
            lastConnectedAt: Date(timeIntervalSince1970: 200),
            isConnectable: true,
            connectionTypes: [.wifi],
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 50873],
            platformName: "iOS",
            osVersion: "26.5",
            modelName: "iPhone 16 Pro"
        )
        manager.replaceDevicesForTesting([usb, bonjour])
        defer { manager.replaceDevicesForTesting([]) }

        manager.recomputeDeviceStatusesForTesting()

        XCTAssertEqual(manager.onlineDevices.count, 1)
        let merged = try XCTUnwrap(manager.onlineDevices.first)
        XCTAssertEqual(merged.name, "Ziang的iPhone 16 Pro")
        XCTAssertEqual(merged.connectionStatus, .online)
        XCTAssertEqual(merged.uniqueIdentifier, "bonjour:Ziang的iPhone 16 Pro@local.")
        XCTAssertEqual(merged.ipv4, "192.168.0.106")
        XCTAssertTrue(merged.connectionTypes.contains(.usb))
        XCTAssertTrue(merged.connectionTypes.contains(.wifi))
        XCTAssertEqual(merged.portMap["_skybridge._tcp"], 50873)
    }

    func testSameNamedIPhonesDoNotCoalesceWhenSerialsConflict() {
        let first = makeDevice(
            name: "Ziang的iPhone 16 Pro",
            uniqueIdentifier: "serial:00008140-000E788401C0801C",
            status: .online,
            lastConnectedAt: Date(),
            isConnectable: true,
            platformName: "iOS",
            osVersion: "26.5",
            modelName: "iPhone 16 Pro"
        )
        let second = makeDevice(
            name: "Ziang的iPhone 16 Pro",
            uniqueIdentifier: "serial:00008140-000E788401C0801D",
            status: .online,
            lastConnectedAt: Date(),
            isConnectable: true,
            platformName: "iOS",
            osVersion: "26.5",
            modelName: "iPhone 16 Pro"
        )

        XCTAssertFalse(
            UnifiedOnlineDeviceManager.shouldCoalesceEquivalentPhysicalDevices(first, second)
        )
    }

    @MainActor
    func testResolvedTrustRecordMatchesOfflineAliasToCanonicalTrustedIdentity() {
        let manager = UnifiedOnlineDeviceManager.shared
        let trustRecord = TrustRecord(
            deviceId: "id:peer-iphone",
            pubKeyFP: String(repeating: "a", count: 64),
            publicKey: Data([0x01]),
            kemPublicKeys: nil,
            capabilities: [
                "trusted",
                "peerEndpoint=bonjour:ziang的iphone 16 pro@local."
            ],
            signature: Data(),
            deviceName: "Ziang的iPhone 16 Pro",
            currentDeviceId: "id:peer-iphone",
            knownDeviceIds: ["peer:169.254.186.235"]
        )
        let shadowAlias = makeDevice(
            name: "169.254.186.235",
            uniqueIdentifier: "recent:peer:169.254.186.235",
            ipv4: "169.254.186.235",
            status: .offline,
            lastConnectedAt: Date()
        )

        let matched = manager.resolvedTrustRecord(for: shadowAlias, among: [trustRecord])

        XCTAssertEqual(matched?.deviceId, trustRecord.deviceId)
    }

    @MainActor
    func testTrustedRecordStatusPrefersLiveBonjourOverOfflineHistory() throws {
        let manager = UnifiedOnlineDeviceManager.shared
        let old = Date(timeIntervalSinceNow: -3_600)
        let offlineHistory = makeDevice(
            name: "Ziang的iPad",
            uniqueIdentifier: "serial:00008103-0011223344556677",
            status: .offline,
            lastConnectedAt: old,
            isConnectable: false,
            connectionTypes: [.usb],
            services: [],
            portMap: [:],
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro",
            lastSeen: old
        )
        let liveBonjour = makeDevice(
            name: "Ziang的iPad",
            uniqueIdentifier: "bonjour:Ziang的iPad@local.",
            ipv4: "192.168.0.103",
            status: .online,
            lastConnectedAt: nil,
            isConnectable: true,
            connectionTypes: [.wifi],
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 11550],
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro",
            lastSeen: Date()
        )
        let trustRecord = TrustRecord(
            deviceId: "id:trusted-ipad",
            pubKeyFP: String(repeating: "b", count: 64),
            publicKey: Data([0x01]),
            kemPublicKeys: nil,
            capabilities: [
                "trusted",
                "peerEndpoint=bonjour:ziang的ipad@local."
            ],
            signature: Data(),
            deviceName: "Ziang的iPad",
            currentDeviceId: "id:trusted-ipad",
            knownDeviceIds: ["bonjour:ziang的ipad@local."]
        )
        manager.replaceDevicesForTesting([offlineHistory, liveBonjour])
        defer { manager.replaceDevicesForTesting([]) }

        let resolved = try XCTUnwrap(manager.resolvedOnlineDevice(for: trustRecord))
        XCTAssertEqual(resolved.uniqueIdentifier, "bonjour:Ziang的iPad@local.")
        XCTAssertEqual(resolved.connectionStatus, .online)
    }

    @MainActor
    func testTrustRecordDoesNotResolveUnrelatedConnectedDeviceWithoutIdentityMatch() {
        let manager = UnifiedOnlineDeviceManager.shared
        let unrelated = makeDevice(
            name: "Other iPad",
            uniqueIdentifier: "bonjour:Other iPad@local.",
            ipv4: "192.168.0.120",
            status: .connected,
            lastConnectedAt: Date(),
            isConnectable: true,
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro"
        )
        let trustRecord = TrustRecord(
            deviceId: "id:trusted-ipad",
            pubKeyFP: String(repeating: "c", count: 64),
            publicKey: Data([0x02]),
            kemPublicKeys: nil,
            capabilities: ["trusted"],
            signature: Data(),
            deviceName: "Ziang的iPad",
            currentDeviceId: "id:trusted-ipad",
            knownDeviceIds: []
        )
        manager.replaceDevicesForTesting([unrelated])
        defer { manager.replaceDevicesForTesting([]) }

        XCTAssertNil(manager.resolvedOnlineDevice(for: trustRecord))
    }

    @MainActor
    func testAppleMobileTrustRecordDoesNotResolveNameOnlyLiveDeviceWithoutStrongAnchor() {
        let manager = UnifiedOnlineDeviceManager.shared
        let sameNamedLiveDevice = makeDevice(
            name: "Ziang的iPad",
            uniqueIdentifier: "bonjour:Ziang的iPad@local.",
            ipv4: nil,
            status: .online,
            lastConnectedAt: nil,
            isConnectable: true,
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro"
        )
        let trustRecord = TrustRecord(
            deviceId: "id:trusted-ipad",
            pubKeyFP: String(repeating: "d", count: 64),
            publicKey: Data([0x03]),
            kemPublicKeys: nil,
            capabilities: ["trusted"],
            signature: Data(),
            deviceName: "Ziang的iPad",
            currentDeviceId: "id:trusted-ipad",
            knownDeviceIds: []
        )
        manager.replaceDevicesForTesting([sameNamedLiveDevice])
        defer { manager.replaceDevicesForTesting([]) }

        XCTAssertNil(manager.resolvedOnlineDevice(for: trustRecord))
    }

    @MainActor
    func testDiscoveredDeviceResolvesStatusThroughUnifiedOnlineState() throws {
        let manager = UnifiedOnlineDeviceManager.shared
        let connected = makeDevice(
            name: "Ziang的iPhone",
            uniqueIdentifier: "bonjour:Ziang的iPhone@local.",
            ipv4: nil,
            status: .connected,
            lastConnectedAt: Date(),
            isConnectable: true,
            connectionTypes: [.wifi],
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 11550],
            platformName: "iOS",
            osVersion: "26.5",
            modelName: "iPhone 16 Pro"
        )
        let discovered = DiscoveredDevice(
            id: UUID(),
            name: "Ziang的iPhone",
            ipv4: nil,
            ipv6: nil,
            platformName: "iOS",
            osVersion: "26.5",
            modelName: "iPhone 16 Pro",
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 11550],
            connectionTypes: [.wifi],
            uniqueIdentifier: "bonjour:Ziang的iPhone@local."
        )
        manager.replaceDevicesForTesting([connected])
        defer { manager.replaceDevicesForTesting([]) }

        let resolved = try XCTUnwrap(manager.resolvedOnlineDevice(for: discovered))
        XCTAssertEqual(resolved.connectionStatus, .connected)
    }

    @MainActor
    func testDiscoveredAppleMobileDoesNotResolveNameOnlyOnlineStateWithoutAnchor() {
        let manager = UnifiedOnlineDeviceManager.shared
        let nameOnlyHistory = makeDevice(
            name: "Ziang的iPad",
            uniqueIdentifier: "name:ziang-ipad-history",
            ipv4: nil,
            status: .online,
            lastConnectedAt: nil,
            isConnectable: true,
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro"
        )
        let discovered = DiscoveredDevice(
            id: UUID(),
            name: "Ziang的iPad",
            ipv4: nil,
            ipv6: nil,
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro",
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 11550],
            connectionTypes: [.wifi],
            uniqueIdentifier: "bonjour:Ziang的iPad@local."
        )
        manager.replaceDevicesForTesting([nameOnlyHistory])
        defer { manager.replaceDevicesForTesting([]) }

        XCTAssertNil(manager.resolvedOnlineDevice(for: discovered))
    }

    @MainActor
    func testResolvedICloudDevicePrefersLiveBonjourRowOverOfflineHistory() throws {
        let manager = UnifiedOnlineDeviceManager.shared
        let old = Date(timeIntervalSinceNow: -3_600)
        let staleHistory = makeDevice(
            name: "Ziang的iPad",
            uniqueIdentifier: "serial:00008103-0011223344556677",
            ipv4: nil,
            status: .offline,
            lastConnectedAt: old,
            isConnectable: false,
            connectionTypes: [.usb],
            services: [],
            portMap: [:],
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro",
            lastSeen: old
        )
        let liveBonjour = makeDevice(
            name: "Ziang的iPad",
            uniqueIdentifier: "bonjour:Ziang的iPad@local.",
            ipv4: "192.168.0.103",
            status: .online,
            lastConnectedAt: nil,
            isConnectable: true,
            connectionTypes: [.wifi],
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 11550],
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro",
            lastSeen: Date()
        )
        let cloudDevice = iCloudDevice(
            id: "icloud-ipad",
            name: "Ziang的iPad",
            model: "iPad Pro",
            osVersion: "26.5",
            appVersion: "1.0.0",
            lastSeen: old,
            capabilities: [.remoteDesktop],
            isOnline: false,
            networkType: .wifi,
            ipAddress: "192.168.0.103"
        )

        manager.replaceDevicesForTesting([staleHistory, liveBonjour])
        defer { manager.replaceDevicesForTesting([]) }

        let matched = try XCTUnwrap(manager.resolvedOnlineDevice(for: cloudDevice))
        XCTAssertEqual(matched.uniqueIdentifier, "bonjour:Ziang的iPad@local.")
        XCTAssertEqual(matched.connectionStatus, .online)
    }

    @MainActor
    func testResolvedICloudDeviceUsesStableIdentityHintWhenPathIdsDiffer() throws {
        let manager = UnifiedOnlineDeviceManager.shared
        let stableDeviceId = "550e8400-e29b-41d4-a716-446655440001"
        let liveDevice = makeDevice(
            name: "Bill iPad",
            uniqueIdentifier: "id:\(stableDeviceId)",
            ipv4: nil,
            status: .online,
            lastConnectedAt: nil,
            isConnectable: true,
            connectionTypes: [.wifi],
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 11550],
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro 11-inch (M4)"
        )
        let cloudDevice = iCloudDevice(
            id: "kvs-path-usb",
            name: "Bill iPad",
            model: "iPad Pro 11-inch (M4)",
            osVersion: "26.5",
            appVersion: "1.0.0",
            lastSeen: Date(),
            capabilities: [.remoteDesktop],
            isOnline: true,
            networkType: .wifi,
            ipAddress: nil,
            stableIdentityDeviceId: stableDeviceId
        )

        manager.replaceDevicesForTesting([liveDevice])
        defer { manager.replaceDevicesForTesting([]) }

        let matched = try XCTUnwrap(manager.resolvedOnlineDevice(for: cloudDevice))
        XCTAssertEqual(matched.uniqueIdentifier, "id:\(stableDeviceId)")
    }

    @MainActor
    func testConflictingStableAppleMobileRowsDoNotCoalesceFromSameGenericNameAndReusedEndpoint() {
        let manager = UnifiedOnlineDeviceManager.shared
        let staleGeneratedStableId = "id:07CB9A6E-7492-4680-9DD7-F37DC8568891"
        let protocolStableId = "id:9DDF82C4-56A7-4B0D-8E91-998877665544"
        let now = Date()
        let staleGeneratedBonjour = makeDevice(
            name: "iPad",
            uniqueIdentifier: staleGeneratedStableId,
            ipv4: "192.168.0.104",
            status: .online,
            lastConnectedAt: nil,
            isConnectable: true,
            connectionTypes: [.wifi],
            services: ["_skybridge._tcp", "_skybridge-remote._tcp"],
            portMap: ["_skybridge._tcp": 51776, "_skybridge-remote._tcp": 51777],
            routeIdentifiers: ["bonjour:iPad_local@local."],
            sources: [.skybridgeBonjour],
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro 11-inch (M4)",
            lastSeen: now.addingTimeInterval(-10)
        )
        let protocolStableBonjour = makeDevice(
            name: "iPad",
            uniqueIdentifier: protocolStableId,
            ipv4: "192.168.0.104",
            status: .online,
            lastConnectedAt: nil,
            isConnectable: true,
            connectionTypes: [.wifi],
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 51776],
            routeIdentifiers: ["bonjour:iPad@local."],
            sources: [.skybridgeBonjour],
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro 11-inch (M4)",
            lastSeen: now
        )
        manager.replaceDevicesForTesting([staleGeneratedBonjour, protocolStableBonjour])
        defer { manager.replaceDevicesForTesting([]) }

        manager.recomputeDeviceStatusesForTesting()

        XCTAssertEqual(
            Set(manager.onlineDevices.map(\.uniqueIdentifier)),
            [staleGeneratedStableId, protocolStableId]
        )
        XCTAssertEqual(manager.onlineDevices.count, 2)
        XCTAssertFalse(
            UnifiedOnlineDeviceManager.shouldCoalesceEquivalentPhysicalDevices(
                staleGeneratedBonjour,
                protocolStableBonjour
            )
        )
    }

    func testConflictingStableAppleMobileRowsDoNotCoalesceAcrossDifferentEndpoints() {
        let first = makeDevice(
            name: "iPad",
            uniqueIdentifier: "id:07CB9A6E-7492-4680-9DD7-F37DC8568891",
            ipv4: "192.168.0.104",
            status: .online,
            lastConnectedAt: nil,
            isConnectable: true,
            connectionTypes: [.wifi],
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 51776],
            routeIdentifiers: ["bonjour:iPad@local."],
            sources: [.skybridgeBonjour],
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro 11-inch (M4)"
        )
        let second = makeDevice(
            name: "iPad",
            uniqueIdentifier: "id:9DDF82C4-56A7-4B0D-8E91-998877665544",
            ipv4: "192.168.0.120",
            status: .online,
            lastConnectedAt: nil,
            isConnectable: true,
            connectionTypes: [.wifi],
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 51776],
            routeIdentifiers: ["bonjour:iPad-Office@local."],
            sources: [.skybridgeBonjour],
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro 11-inch (M4)"
        )

        XCTAssertFalse(
            UnifiedOnlineDeviceManager.shouldCoalesceEquivalentPhysicalDevices(first, second)
        )
    }

    @MainActor
    func testTrustedCanonicalProtocolIdentityWinsWhenOldAndNewIPadRowsCoalesce() async throws {
        let manager = UnifiedOnlineDeviceManager.shared
        let trust = TrustSyncService.shared
        let oldDeviceId = "07cb9a6e-7492-4680-9dd7-f37dc8568891"
        let newDeviceId = "fe040ab2-0a7b-4b83-9f53-c80b4e2c8295"
        let oldStableId = "id:\(oldDeviceId)"
        let newStableId = "id:\(newDeviceId)"
        let bonjourAlias = "bonjour:ziang-ipad@local."
        let now = Date()

        trust.setInMemoryPersistenceForTesting(true)
        await trust.removeRecordsForTesting(deviceIds: [oldStableId, newStableId, bonjourAlias])
        defer {
            manager.replaceDevicesForTesting([])
            Task { @MainActor in
                await trust.removeRecordsForTesting(deviceIds: [oldStableId, newStableId, bonjourAlias])
                trust.setInMemoryPersistenceForTesting(false)
            }
        }

        _ = try await trust.addTrustRecord(
            TrustRecord(
                deviceId: newStableId,
                pubKeyFP: String(repeating: "a", count: 64),
                publicKey: Data([0x01]),
                protocolSigningAlgorithm: .mlDSA65,
                protocolPublicKeyFingerprint: String(repeating: "b", count: 64),
                signature: Data(),
                deviceName: "Ziang的iPad",
                currentDeviceId: newStableId,
                knownDeviceIds: [oldStableId, newStableId, bonjourAlias],
                lifecycleState: .active
            )
        )

        let oldRow = makeDevice(
            name: "Ziang的iPad",
            uniqueIdentifier: oldStableId,
            ipv4: "192.168.0.102",
            status: .online,
            lastConnectedAt: Date(timeIntervalSince1970: 100),
            isConnectable: true,
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 9527],
            routeIdentifiers: [bonjourAlias],
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro 11-inch (M4)",
            lastSeen: now.addingTimeInterval(-1)
        )
        let currentRow = makeDevice(
            name: "Ziang的iPad",
            uniqueIdentifier: newStableId,
            ipv4: "192.168.0.102",
            status: .online,
            lastConnectedAt: Date(timeIntervalSince1970: 200),
            isConnectable: true,
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 9527],
            routeIdentifiers: [bonjourAlias],
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro 11-inch (M4)",
            lastSeen: now
        )

        manager.replaceDevicesForTesting([oldRow, currentRow])
        manager.recomputeDeviceStatusesForTesting()

        XCTAssertEqual(manager.onlineDevices.count, 1)
        XCTAssertEqual(manager.onlineDevices.first?.uniqueIdentifier, newStableId)
        XCTAssertEqual(manager.onlineDevices.first?.connectionStatus, .online)
    }

    @MainActor
    func testLiveStableProtocolIdentityWinsOverStaleTrustedAliasDuringCoalesce() async throws {
        let manager = UnifiedOnlineDeviceManager.shared
        let trust = TrustSyncService.shared
        let staleDeviceId = "07cb9a6e-7492-4680-9dd7-f37dc8568891"
        let liveDeviceId = "f951b140-a4d8-4664-ab9d-d90118738c54"
        let staleStableId = "id:\(staleDeviceId)"
        let liveStableId = "id:\(liveDeviceId)"
        let bonjourAlias = "bonjour:iPad@local."
        let now = Date()

        trust.setInMemoryPersistenceForTesting(true)
        await trust.removeRecordsForTesting(deviceIds: [staleStableId, liveStableId, bonjourAlias])
        defer {
            manager.replaceDevicesForTesting([])
            Task { @MainActor in
                await trust.removeRecordsForTesting(deviceIds: [staleStableId, liveStableId, bonjourAlias])
                trust.setInMemoryPersistenceForTesting(false)
            }
        }

        _ = try await trust.addTrustRecord(
            TrustRecord(
                deviceId: staleStableId,
                pubKeyFP: String(repeating: "c", count: 64),
                publicKey: Data([0x02]),
                protocolSigningAlgorithm: .mlDSA65,
                protocolPublicKeyFingerprint: String(repeating: "d", count: 64),
                signature: Data(),
                deviceName: "iPad",
                currentDeviceId: staleStableId,
                knownDeviceIds: [staleStableId, liveStableId, bonjourAlias],
                lifecycleState: .active
            )
        )

        let staleRow = makeDevice(
            name: "iPad",
            uniqueIdentifier: staleStableId,
            ipv4: "169.254.12.10",
            status: .online,
            lastConnectedAt: Date(timeIntervalSince1970: 100),
            isConnectable: true,
            routeIdentifiers: [bonjourAlias],
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro 11-inch (M4)",
            lastSeen: now.addingTimeInterval(-30)
        )
        let liveRow = makeDevice(
            name: "iPad",
            uniqueIdentifier: liveStableId,
            ipv4: "192.168.0.102",
            status: .online,
            lastConnectedAt: Date(timeIntervalSince1970: 200),
            isConnectable: true,
            routeIdentifiers: [bonjourAlias],
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro 11-inch (M4)",
            lastSeen: now
        )

        manager.replaceDevicesForTesting([staleRow, liveRow])
        manager.recomputeDeviceStatusesForTesting()

        XCTAssertEqual(manager.onlineDevices.count, 1)
        XCTAssertEqual(manager.onlineDevices.first?.uniqueIdentifier, liveStableId)
        XCTAssertEqual(manager.onlineDevices.first?.ipv4, "192.168.0.102")
    }

    @MainActor
    func testResolvedICloudDeviceDoesNotCrossMatchDifferentAppleMobileFamilies() {
        let manager = UnifiedOnlineDeviceManager.shared
        let misleadingName = makeDevice(
            name: "Ziang的iPad",
            uniqueIdentifier: "bonjour:Ziang的iPhone@local.",
            ipv4: "192.168.0.104",
            status: .online,
            lastConnectedAt: nil,
            isConnectable: true,
            platformName: "iOS",
            osVersion: "26.5",
            modelName: "iPhone 16 Pro"
        )
        let cloudDevice = iCloudDevice(
            id: "icloud-ipad",
            name: "Ziang的iPad",
            model: "iPad Pro",
            osVersion: "26.5",
            appVersion: "1.0.0",
            lastSeen: Date(timeIntervalSinceNow: -3_600),
            capabilities: [.remoteDesktop],
            isOnline: false,
            networkType: .wifi,
            ipAddress: nil
        )

        manager.replaceDevicesForTesting([misleadingName])
        defer { manager.replaceDevicesForTesting([]) }

        XCTAssertNil(manager.resolvedOnlineDevice(for: cloudDevice))
    }

    @MainActor
    func testResolvedICloudDeviceRequiresStableOrAddressAnchorForSameNamedLiveDevice() {
        let manager = UnifiedOnlineDeviceManager.shared
        let sameNamedLiveDevice = makeDevice(
            name: "Ziang的iPad",
            uniqueIdentifier: "bonjour:Ziang的iPad@local.",
            ipv4: nil,
            status: .online,
            lastConnectedAt: nil,
            isConnectable: true,
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro"
        )
        let cloudDevice = iCloudDevice(
            id: "icloud-ipad",
            name: "Ziang的iPad",
            model: "iPad Pro",
            osVersion: "26.5",
            appVersion: "1.0.0",
            lastSeen: Date(timeIntervalSinceNow: -3_600),
            capabilities: [.remoteDesktop],
            isOnline: false,
            networkType: .wifi,
            ipAddress: nil
        )

        manager.replaceDevicesForTesting([sameNamedLiveDevice])
        defer { manager.replaceDevicesForTesting([]) }

        XCTAssertNil(manager.resolvedOnlineDevice(for: cloudDevice))
    }

    @MainActor
    func testMarkDeviceAsConnectedUpdatesStableIdentityEvenWhenDisplayNameIsEphemeral() {
        let manager = UnifiedOnlineDeviceManager.shared
        let peerId = "id:550E8400-E29B-41D4-A716-446655440001"
        let existing = makeDevice(
            name: "Trusted iPhone",
            uniqueIdentifier: peerId,
            status: .offline,
            lastConnectedAt: Date(),
            isConnectable: true
        )
        manager.replaceDevicesForTesting([existing])
        ConnectionPresenceService.shared.markConnected(
            peerId: peerId,
            displayName: "Trusted iPhone",
            address: nil,
            cryptoKind: "Apple PQC",
            suite: "ML-KEM-768"
        )
        defer {
            ConnectionPresenceService.shared.markDisconnected(peerId: peerId)
            manager.replaceDevicesForTesting([])
        }

        manager.markDeviceAsConnected(
            peerId: peerId,
            displayName: "peer:fe80::1",
            cryptoKind: "Apple PQC",
            suite: "ML-KEM-768"
        )

        XCTAssertEqual(manager.onlineDevices.count, 1)
        XCTAssertEqual(manager.onlineDevices.first?.uniqueIdentifier, peerId)
        XCTAssertEqual(manager.onlineDevices.first?.connectionStatus, .connected)
        XCTAssertEqual(manager.onlineDevices.first?.lastCryptoSuite, "ML-KEM-768")
    }

    @MainActor
    func testMarkDeviceAsConnectedUsesBonjourRouteAliasBeforeCreatingRecentRow() {
        let manager = UnifiedOnlineDeviceManager.shared
        let stableId = "id:550E8400-E29B-41D4-A716-446655440002"
        let bonjourPeer = "bonjour:Ziang的iPad@local."
        let existing = makeDevice(
            name: "Ziang的iPad",
            uniqueIdentifier: stableId,
            status: .offline,
            lastConnectedAt: nil,
            isConnectable: true,
            connectionTypes: [.wifi],
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 9527],
            routeIdentifiers: [bonjourPeer],
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro"
        )
        manager.replaceDevicesForTesting([existing])
        ConnectionPresenceService.shared.markConnected(
            peerId: bonjourPeer,
            displayName: "peer:fe80::1",
            address: nil,
            cryptoKind: "Apple PQC",
            suite: "ML-KEM-768"
        )
        defer {
            ConnectionPresenceService.shared.markDisconnected(peerId: bonjourPeer)
            manager.replaceDevicesForTesting([])
        }

        manager.markDeviceAsConnected(
            peerId: bonjourPeer,
            displayName: "peer:fe80::1",
            cryptoKind: "Apple PQC",
            suite: "ML-KEM-768"
        )

        XCTAssertEqual(manager.onlineDevices.count, 1)
        XCTAssertEqual(manager.onlineDevices.first?.uniqueIdentifier, stableId)
        XCTAssertEqual(manager.onlineDevices.first?.connectionStatus, .connected)
        XCTAssertEqual(manager.onlineDevices.first?.lastCryptoSuite, "ML-KEM-768")
        XCTAssertTrue(manager.onlineDevices.first?.routeIdentifiers.contains(bonjourPeer) == true)
    }

    @MainActor
    func testMarkDeviceAsConnectedDoesNotBindAppleMobileByDisplayNameOnly() {
        let manager = UnifiedOnlineDeviceManager.shared
        let staleId = "id:07CB9A6E-7492-4680-9DD7-F37DC8568891"
        let livePeerId = "id:F951B140-A4D8-4664-AB9D-D90118738C54"
        let staleRow = makeDevice(
            name: "iPad",
            uniqueIdentifier: staleId,
            status: .online,
            lastConnectedAt: Date(timeIntervalSince1970: 100),
            isConnectable: true,
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro 11-inch (M4)"
        )
        manager.replaceDevicesForTesting([staleRow])
        defer { manager.replaceDevicesForTesting([]) }

        manager.markDeviceAsConnected(
            peerId: livePeerId,
            displayName: "iPad",
            cryptoKind: "Apple PQC",
            suite: "ML-KEM-768"
        )

        let staleAfter = manager.onlineDevices.first { $0.uniqueIdentifier == staleId }
        XCTAssertNotEqual(staleAfter?.connectionStatus, .connected)
        XCTAssertTrue(
            manager.onlineDevices.contains {
                $0.uniqueIdentifier.lowercased() == livePeerId.lowercased()
            },
            manager.onlineDevices
                .map { "\($0.uniqueIdentifier)|\($0.connectionStatus.rawValue)" }
                .joined(separator: ";")
        )
    }

    @MainActor
    func testPresenceRecomputeKeepsStableIdentityConnectedWhenPeerIdUsesIdPrefix() {
        let manager = UnifiedOnlineDeviceManager.shared
        let peerId = "id:550E8400-E29B-41D4-A716-446655440000"
        let existing = makeDevice(
            name: "Trusted iPhone",
            uniqueIdentifier: peerId,
            status: .offline,
            lastConnectedAt: Date(),
            isConnectable: true
        )
        manager.replaceDevicesForTesting([existing])
        ConnectionPresenceService.shared.markConnected(
            peerId: peerId,
            displayName: "Trusted iPhone",
            address: nil,
            cryptoKind: "Apple PQC",
            suite: "ML-KEM-768"
        )
        defer {
            ConnectionPresenceService.shared.markDisconnected(peerId: peerId)
            manager.replaceDevicesForTesting([])
        }

        manager.recomputeDeviceStatusesForTesting()

        XCTAssertEqual(manager.onlineDevices.first?.connectionStatus, .connected)
        XCTAssertEqual(manager.onlineDevices.first?.guardStatus, "守护中")
    }

    @MainActor
    func testPresenceRecomputeKeepsStableIdentityConnectedWhenPeerIdUsesBonjourRoute() {
        let manager = UnifiedOnlineDeviceManager.shared
        let stableId = "id:550E8400-E29B-41D4-A716-446655440003"
        let bonjourPeer = "bonjour:Ziang的iPad@local."
        let existing = makeDevice(
            name: "Ziang的iPad",
            uniqueIdentifier: stableId,
            status: .offline,
            lastConnectedAt: nil,
            isConnectable: true,
            connectionTypes: [.wifi],
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 9527],
            routeIdentifiers: [bonjourPeer],
            platformName: "iPadOS",
            osVersion: "26.5",
            modelName: "iPad Pro"
        )
        manager.replaceDevicesForTesting([existing])
        ConnectionPresenceService.shared.markConnected(
            peerId: bonjourPeer,
            displayName: "peer:fe80::1",
            address: nil,
            cryptoKind: "Apple PQC",
            suite: "ML-KEM-768"
        )
        defer {
            ConnectionPresenceService.shared.markDisconnected(peerId: bonjourPeer)
            manager.replaceDevicesForTesting([])
        }

        manager.recomputeDeviceStatusesForTesting()

        XCTAssertEqual(manager.onlineDevices.count, 1)
        XCTAssertEqual(manager.onlineDevices.first?.uniqueIdentifier, stableId)
        XCTAssertEqual(manager.onlineDevices.first?.connectionStatus, .connected)
        XCTAssertEqual(manager.onlineDevices.first?.guardStatus, "守护中")
    }

    private func makeDevice(
        name: String,
        uniqueIdentifier: String,
        ipv4: String? = nil,
        status: OnlineDeviceStatus,
        lastConnectedAt: Date?,
        isConnectable: Bool = false,
        connectionTypes: Set<DeviceConnectionType> = [.wifi],
        services: [String] = ["_skybridge._tcp"],
        portMap: [String: Int] = ["_skybridge._tcp": 9527],
        routeIdentifiers: [String] = [],
        sources: [DeviceSource] = [.skybridgeBonjour],
        platformName: String? = nil,
        osVersion: String? = nil,
        modelName: String? = nil,
        lastSeen: Date = Date(),
        serialNumber: String? = nil,
        protocolFingerprint: String? = nil
    ) -> OnlineDevice {
        OnlineDevice(
            id: UUID(),
            name: name,
            deviceType: .computer,
            ipv4: ipv4,
            ipv6: nil,
            platformName: platformName,
            osVersion: osVersion,
            modelName: modelName,
            chip: nil,
            macAddress: nil,
            serialNumber: serialNumber,
            connectionTypes: connectionTypes,
            services: services,
            portMap: portMap,
            routeIdentifiers: routeIdentifiers,
            protocolFingerprint: protocolFingerprint,
            uniqueIdentifier: uniqueIdentifier,
            sources: sources,
            discoveredAt: Date(),
            lastSeen: lastSeen,
            connectionStatus: status,
            lastConnectedAt: lastConnectedAt,
            lastCryptoKind: "Apple PQC",
            lastCryptoSuite: "ML-KEM-768",
            guardStatus: "守护中",
            isLocalDevice: false,
            isAuthorized: false,
            signalStrength: nil,
            isConnectable: isConnectable
        )
    }

    private struct PersistedDevicesPayloadForTesting: Codable {
        let schemaVersion: Int
        let devices: [OnlineDevice]
    }

    private func writePersistedDevicesForTesting(
        _ devices: [OnlineDevice],
        schemaVersion: Int
    ) throws {
        let payload = PersistedDevicesPayloadForTesting(
            schemaVersion: schemaVersion,
            devices: devices
        )
        let data = try JSONEncoder().encode(payload)
        UserDefaults.standard.set(data, forKey: "skybridge.persistedDevices")
    }

    private func persistedDevicesForTesting() throws -> [OnlineDevice] {
        let data = try XCTUnwrap(UserDefaults.standard.data(forKey: "skybridge.persistedDevices"))
        let payload = try JSONDecoder().decode(PersistedDevicesPayloadForTesting.self, from: data)
        XCTAssertEqual(payload.schemaVersion, 2)
        return payload.devices
    }
}
