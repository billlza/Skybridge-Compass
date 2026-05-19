import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class UnifiedOnlineDeviceManagerDedupeTests: XCTestCase {
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
        platformName: String? = nil,
        osVersion: String? = nil,
        modelName: String? = nil
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
            serialNumber: nil,
            connectionTypes: connectionTypes,
            services: services,
            portMap: portMap,
            uniqueIdentifier: uniqueIdentifier,
            sources: [.skybridgeBonjour],
            discoveredAt: Date(),
            lastSeen: Date(),
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
}
