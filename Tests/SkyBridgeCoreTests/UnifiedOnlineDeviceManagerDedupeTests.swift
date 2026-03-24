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

    private func makeDevice(
        name: String,
        uniqueIdentifier: String,
        ipv4: String? = nil,
        status: OnlineDeviceStatus,
        lastConnectedAt: Date?,
        isConnectable: Bool = false
    ) -> OnlineDevice {
        OnlineDevice(
            id: UUID(),
            name: name,
            deviceType: .computer,
            ipv4: ipv4,
            ipv6: nil,
            macAddress: nil,
            serialNumber: nil,
            connectionTypes: [.wifi],
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 9527],
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
