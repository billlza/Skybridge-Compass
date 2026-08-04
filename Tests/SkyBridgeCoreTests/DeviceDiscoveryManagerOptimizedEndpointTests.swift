import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class DeviceDiscoveryManagerOptimizedEndpointTests: XCTestCase {
    @MainActor
    func testNetworkDiscoveryDoesNotPublishUSBPresenceByDefault() {
        let manager = DeviceDiscoveryManagerOptimized()

        XCTAssertFalse(manager.publishesUSBPresenceInDiscoveredDevices)
    }

    func testPreferredBonjourEndpointPrefersStableBonjourIdentifierOverIPAddressLikeName() {
        let device = DiscoveredDevice(
            id: UUID(),
            name: "fe80::ce0:3cf9:13d0:85b3%en0",
            ipv4: nil,
            ipv6: nil,
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 9527],
            uniqueIdentifier: "bonjour:iPad@local."
        )

        let endpoint = DeviceDiscoveryManagerOptimized.preferredBonjourEndpoint(
            for: device,
            defaultDomain: "local."
        )

        XCTAssertEqual(endpoint?.name, "iPad")
        XCTAssertEqual(endpoint?.domain, "local.")
    }

    func testPreferredBonjourEndpointRejectsIPAddressLiteralWithoutStableBonjourIdentifier() {
        let device = DiscoveredDevice(
            id: UUID(),
            name: "fe80::ce0:3cf9:13d0:85b3%en0",
            ipv4: nil,
            ipv6: nil,
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 9527],
            uniqueIdentifier: nil
        )

        let endpoint = DeviceDiscoveryManagerOptimized.preferredBonjourEndpoint(
            for: device,
            defaultDomain: "local."
        )

        XCTAssertNil(endpoint)
    }

    func testPreferredBonjourEndpointRejectsSyntheticServiceNamesWithoutStableBonjourIdentifier() {
        for name in [
            "id:11111111-1111-1111-1111-111111111111",
            "host:11111111-1111-1111-1111-111111111111",
            "11111111-1111-1111-1111-111111111111"
        ] {
            let device = DiscoveredDevice(
                id: UUID(),
                name: name,
                ipv4: nil,
                ipv6: nil,
                services: ["_skybridge._tcp"],
                portMap: ["_skybridge._tcp": 9527],
                uniqueIdentifier: nil
            )

            XCTAssertNil(
                DeviceDiscoveryManagerOptimized.preferredBonjourEndpoint(
                    for: device,
                    defaultDomain: "local."
                )
            )
        }
    }

    func testUSBPresenceIdentifierIsNamespacedAsSerial() {
        XCTAssertEqual(
            DeviceDiscoveryManagerOptimized.usbPresenceIdentifier(
                serialNumber: "00008140-000E788401C0801C",
                deviceID: "fallback"
            ),
            "serial:00008140-000E788401C0801C"
        )

        XCTAssertEqual(
            DeviceDiscoveryManagerOptimized.usbPresenceIdentifier(
                serialNumber: " ",
                deviceID: "00008140-000E788401C0801D"
            ),
            "serial:00008140-000E788401C0801D"
        )
    }

    func testRouteBoundPortRefreshMergesIntoIdentityBackedBonjourDevice() {
        let route = "bonjour:iPad_Pro_11-inch__M4_@local."
        let identityFingerprint = String(repeating: "a", count: 64)
        let identityBacked = DiscoveredDevice(
            id: UUID(),
            name: "iPad Pro 11-inch (M4)",
            ipv4: nil,
            ipv6: nil,
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 0],
            connectionTypes: [.wifi],
            uniqueIdentifier: "id:<ios-device-sha256:c52ea764fc00>",
            routeIdentifiers: [route],
            source: .skybridgeBonjour,
            deviceId: "<ios-device-sha256:c52ea764fc00>",
            pubKeyFP: identityFingerprint
        )
        let portRefresh = DiscoveredDevice(
            id: UUID(),
            name: "iPad Pro 11-inch (M4)",
            ipv4: nil,
            ipv6: nil,
            services: [BonjourInteropContract.fileTransferServiceType, "_skybridge._tcp"],
            portMap: [BonjourInteropContract.fileTransferServiceType: 8080, "_skybridge._tcp": 9527],
            connectionTypes: [.wifi],
            uniqueIdentifier: route,
            routeIdentifiers: [route],
            source: .skybridgeBonjour
        )

        XCTAssertEqual(
            DeviceDiscoveryManagerOptimized.routeBoundMergeIndex(
                in: [identityBacked],
                candidate: portRefresh
            ),
            0
        )
        XCTAssertTrue(
            DeviceDiscoveryManagerOptimized.isRouteBoundProtocolMerge(
                existing: identityBacked,
                candidate: portRefresh
            ),
            "A port-only Bonjour refresh for the same route must merge into the identity-backed record without clearing deviceId/pubKeyFP."
        )
    }

    func testPortMapMergePreservesResolvedControlPortWhenRefreshCarriesZero() {
        let merged = DeviceDiscoveryManagerOptimized.mergedPortMapPreservingResolvedPorts(
            incoming: [
                "_skybridge._tcp": 0,
                BonjourInteropContract.fileTransferServiceType: 8080,
                BonjourInteropContract.remoteControlServiceType: 0
            ],
            existing: [
                "_skybridge._tcp": 9527,
                BonjourInteropContract.remoteControlServiceType: 5901
            ]
        )

        XCTAssertEqual(merged["_skybridge._tcp"], 9527)
        XCTAssertEqual(merged[BonjourInteropContract.fileTransferServiceType], 8080)
        XCTAssertEqual(merged[BonjourInteropContract.remoteControlServiceType], 5901)
    }

    func testPortMapMergeAllowsFreshResolvedPortToReplaceStalePort() {
        let merged = DeviceDiscoveryManagerOptimized.mergedPortMapPreservingResolvedPorts(
            incoming: ["_skybridge._tcp": 51752],
            existing: ["_skybridge._tcp": 9527]
        )

        XCTAssertEqual(merged["_skybridge._tcp"], 51752)
    }

    func testPortMapMergeKeepsUnresolvedServiceWhenNoResolvedPortExists() {
        let merged = DeviceDiscoveryManagerOptimized.mergedPortMapPreservingResolvedPorts(
            incoming: ["_skybridge._tcp": 0],
            existing: [:]
        )

        XCTAssertEqual(merged["_skybridge._tcp"], 0)
    }

    func testCompleteProtocolIdentityUpgradesRouteOnlyBonjourDevice() {
        let route = "bonjour:iPad_Pro_11-inch__M4_@local."
        let identityFingerprint = String(repeating: "b", count: 64)
        let routeOnly = DiscoveredDevice(
            id: UUID(),
            name: "iPad Pro 11-inch (M4)",
            ipv4: nil,
            ipv6: nil,
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 9527],
            connectionTypes: [.wifi],
            uniqueIdentifier: route,
            routeIdentifiers: [route],
            source: .skybridgeBonjour
        )
        let identityRefresh = DiscoveredDevice(
            id: UUID(),
            name: "iPad Pro 11-inch (M4)",
            ipv4: nil,
            ipv6: nil,
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 0],
            connectionTypes: [.wifi],
            uniqueIdentifier: "id:<ios-device-sha256:c52ea764fc00>",
            routeIdentifiers: [route],
            source: .skybridgeBonjour,
            deviceId: "<ios-device-sha256:c52ea764fc00>",
            pubKeyFP: identityFingerprint
        )

        XCTAssertEqual(
            DeviceDiscoveryManagerOptimized.routeBoundMergeIndex(
                in: [routeOnly],
                candidate: identityRefresh
            ),
            0
        )
        XCTAssertTrue(
            DeviceDiscoveryManagerOptimized.isRouteBoundProtocolMerge(
                existing: routeOnly,
                candidate: identityRefresh
            )
        )
    }

    func testRouteBoundMergeRejectsConflictingCompleteProtocolIdentities() {
        let route = "bonjour:iPad_Pro_11-inch__M4_@local."
        let existing = DiscoveredDevice(
            id: UUID(),
            name: "iPad Pro 11-inch (M4)",
            ipv4: nil,
            ipv6: nil,
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 9527],
            connectionTypes: [.wifi],
            uniqueIdentifier: "id:<ios-device-sha256:aaaa>",
            routeIdentifiers: [route],
            source: .skybridgeBonjour,
            deviceId: "<ios-device-sha256:aaaa>",
            pubKeyFP: String(repeating: "c", count: 64)
        )
        let conflictingCandidate = DiscoveredDevice(
            id: UUID(),
            name: "iPad Pro 11-inch (M4)",
            ipv4: nil,
            ipv6: nil,
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 0],
            connectionTypes: [.wifi],
            uniqueIdentifier: "id:<ios-device-sha256:bbbb>",
            routeIdentifiers: [route],
            source: .skybridgeBonjour,
            deviceId: "<ios-device-sha256:bbbb>",
            pubKeyFP: String(repeating: "d", count: 64)
        )

        XCTAssertNil(
            DeviceDiscoveryManagerOptimized.routeBoundMergeIndex(
                in: [existing],
                candidate: conflictingCandidate
            )
        )
        XCTAssertFalse(
            DeviceDiscoveryManagerOptimized.isRouteBoundProtocolMerge(
                existing: existing,
                candidate: conflictingCandidate
            ),
            "A shared Bonjour service name is not enough to merge two different complete protocol identities."
        )
    }

    func testTransferBonjourDiscoveryHydratesSameInstancePrimaryControlService() throws {
        let source = try repositorySource("Sources/SkyBridgeCore/DeviceDiscovery/DeviceDiscoveryManagerOptimized.swift")

        XCTAssertTrue(source.contains("schedulePrimaryControlServiceHydrationIfNeeded("))
        XCTAssertTrue(source.contains("normalizedServiceType != BonjourInteropContract.controlServiceType"))
        XCTAssertTrue(source.contains("normalizedServiceType.hasPrefix(\"_skybridge\")"))
        XCTAssertTrue(source.contains("Self.resolveBonjourServiceOnMain("))
        XCTAssertTrue(source.contains("timeoutSeconds: 3.0"))
        XCTAssertTrue(source.contains("primaryControlResolveCooldown"))
        XCTAssertTrue(source.contains("services: [controlType]"))
        XCTAssertTrue(source.contains("portMap: [controlType: controlPort]"))
        XCTAssertTrue(source.contains("deviceId: identity.deviceId"))
        XCTAssertTrue(source.contains("pubKeyFP: identity.pubKeyFP"))
        XCTAssertTrue(source.contains("mergedPortMapPreservingResolvedPorts("))
        XCTAssertFalse(
            source.contains("portMap.merging"),
            "Bonjour merge paths must not let a fresh zero port overwrite an already resolved control port."
        )
    }

    func testDiscoveryDoesNotProbeStatefulServicePortsForSignalStrength() throws {
        let source = try repositorySource(
            "Sources/SkyBridgeCore/DeviceDiscovery/DeviceDiscoveryManagerOptimized.swift"
        )

        XCTAssertTrue(
            source.contains(
                "let resolvedSignalStrength = Self.signalPercentage(from: networkLinkStatus)"
            )
        )
        XCTAssertFalse(source.contains("measureLinkQuality("))
        XCTAssertFalse(source.contains("effectivePort = port > 0 ? port : 80"))
    }

    func testWeakNameMergeDoesNotCoalesceStableProtocolIdentities() throws {
        let source = try repositorySource("Sources/SkyBridgeCore/DeviceDiscovery/UnifiedOnlineDeviceManager.swift")

        XCTAssertTrue(source.contains("incomingHasProtocolIdentity"))
        XCTAssertTrue(source.contains("existingHasProtocolIdentity"))
        XCTAssertTrue(
            source.contains("guard !incomingHasProtocolIdentity, !existingHasProtocolIdentity else"),
            "Stable Bonjour/iCloud identities must not be merged by name-only similarity."
        )
    }

    private func repositorySource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
