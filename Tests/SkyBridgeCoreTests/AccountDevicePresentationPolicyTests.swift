import XCTest
@testable import SkyBridgeProtocolCore

/// 锁定 macOS / iOS 共用的账号设备展示与可连接性规则。
final class AccountDevicePresentationPolicyTests: XCTestCase {
    private func record(
        id: String,
        name: String? = nil,
        online: Bool = false,
        isCaller: Bool = false,
        lastSeen: Int64? = nil,
        platform: String? = "macos",
        lanAddresses: [String] = [],
        publicAddress: String? = nil,
        capabilities: [String] = [],
        status: String = "active",
        model: String? = nil
    ) -> AccountDeviceRecord {
        AccountDeviceRecord(
            deviceId: id,
            deviceName: name,
            status: status,
            protocolSigningAlgorithm: "Ed25519",
            protocolPublicKeyFingerprint: String(repeating: "a", count: 64),
            platformRawValue: platform,
            deviceModel: model,
            osVersion: nil,
            appVersion: nil,
            lanAddresses: lanAddresses,
            publicAddress: publicAddress,
            capabilities: capabilities,
            registeredAtEpochMilliseconds: nil,
            lastSeenAtEpochMilliseconds: lastSeen,
            presenceUpdatedAtEpochMilliseconds: nil,
            online: online,
            isCaller: isCaller
        )
    }

    func testOrderingIsCallerFirstThenOnlineThenRecencyThenNameThenId() {
        let devices = [
            record(id: "z-offline-old", name: "Zed", lastSeen: 10),
            record(id: "b-online", name: "Bravo", online: true, lastSeen: 5),
            record(id: "a-online", name: "alpha", online: true, lastSeen: 5),
            record(id: "self", name: "Self", isCaller: true),
            record(id: "offline-never", name: "Never"),
            record(id: "c-online-newer", name: "Charlie", online: true, lastSeen: 50)
        ]
        let ordered = AccountDevicePresentationPolicy.orderedDevices(devices).map(\.deviceId)
        XCTAssertEqual(ordered, ["self", "c-online-newer", "a-online", "b-online", "z-offline-old", "offline-never"])
    }

    func testOrderingIsDeterministicForShuffledInput() {
        let devices = (0..<40).map { index in
            record(id: "d-\(index)", name: "Device \(index % 5)", online: index % 3 == 0, lastSeen: Int64(index % 7))
        }
        let expected = AccountDevicePresentationPolicy.orderedDevices(devices).map(\.deviceId)
        for _ in 0..<5 {
            XCTAssertEqual(AccountDevicePresentationPolicy.orderedDevices(devices.shuffled()).map(\.deviceId), expected)
        }
        XCTAssertEqual(AccountDevicePresentationPolicy.orderedDevices([]), [])
    }

    func testConnectivityPrefersDirectLANEvidenceAndKeepsCallerAsThisDevice() {
        let peer = record(id: "peer", online: true)
        XCTAssertEqual(AccountDevicePresentationPolicy.connectivity(for: peer, isLANReachable: true), .lanReachable)
        XCTAssertEqual(AccountDevicePresentationPolicy.connectivity(for: peer, isLANReachable: false), .online)
        let offlinePeer = record(id: "peer-offline", online: false)
        XCTAssertEqual(AccountDevicePresentationPolicy.connectivity(for: offlinePeer, isLANReachable: true), .lanReachable)
        XCTAssertEqual(AccountDevicePresentationPolicy.connectivity(for: offlinePeer, isLANReachable: false), .offline)
        let caller = record(id: "self", online: false, isCaller: true)
        XCTAssertEqual(AccountDevicePresentationPolicy.connectivity(for: caller, isLANReachable: true), .thisDevice)
    }

    func testRemoteControlHostingKeysOnTheCapabilityTokenOnly() {
        XCTAssertTrue(AccountDevicePresentationPolicy.supportsRemoteControlHosting(record(id: "mac", capabilities: ["remote_desktop"])))
        XCTAssertTrue(AccountDevicePresentationPolicy.supportsRemoteControlHosting(record(id: "win", platform: "windows", capabilities: ["clipboard", "remote_desktop"])))
        XCTAssertFalse(AccountDevicePresentationPolicy.supportsRemoteControlHosting(record(id: "mac-no-cap", capabilities: ["file_transfer"])))
        XCTAssertFalse(AccountDevicePresentationPolicy.supportsRemoteControlHosting(record(id: "ipad", platform: "ipados", capabilities: ["file_transfer", "clipboard"])))
        XCTAssertFalse(AccountDevicePresentationPolicy.supportsRemoteControlHosting(record(id: "unknown", platform: "visionos", capabilities: ["Remote_Desktop"])))
    }

    func testPrimaryAddressPrefersIPv4LANThenAnyLANThenPublic() {
        XCTAssertEqual(
            AccountDevicePresentationPolicy.primaryAddress(for: record(id: "a", lanAddresses: ["fd12::1", "10.0.0.5"], publicAddress: "203.0.113.9")),
            "10.0.0.5"
        )
        XCTAssertEqual(
            AccountDevicePresentationPolicy.primaryAddress(for: record(id: "b", lanAddresses: ["fd12::1"], publicAddress: "203.0.113.9")),
            "fd12::1"
        )
        XCTAssertEqual(
            AccountDevicePresentationPolicy.primaryAddress(for: record(id: "c", publicAddress: "203.0.113.9")),
            "203.0.113.9"
        )
        XCTAssertNil(AccountDevicePresentationPolicy.primaryAddress(for: record(id: "d")))
    }

    func testDisplayNameFallsBackToModelThenShortId() {
        XCTAssertEqual(AccountDevicePresentationPolicy.displayName(for: record(id: "abcdef1234", name: "  Studio  ")), "Studio")
        XCTAssertEqual(AccountDevicePresentationPolicy.displayName(for: record(id: "abcdef1234", name: " ", model: "Mac16,7")), "MacBook Pro (16-inch, 2024)")
        XCTAssertEqual(AccountDevicePresentationPolicy.displayName(for: record(id: "abcdef1234")), "ABCDEF12")
        XCTAssertEqual(AccountDevicePresentationPolicy.shortDeviceId("ab"), "AB")
    }

    func testGenericNameDoesNotHideTheHardwareModelAndCustomNamesArePreserved() {
        XCTAssertEqual(AccountDevicePresentationPolicy.displayName(for: record(id: "phone", name: "iPhone", platform: "ios", model: "iPhone17,1")), "iPhone 16 Pro")
        XCTAssertEqual(AccountDevicePresentationPolicy.displayName(for: record(id: "mac", name: "Studio", model: "MacBookPro18,2")), "Studio")
        XCTAssertEqual(AccountDevicePresentationPolicy.displayName(for: record(id: "new", model: "Mac99,99")), "Mac99,99")
    }

    func testDifferentSigningIdentitiesDoNotShareASwiftUIRowIdentifier() throws {
        let old = record(id: "same-device", name: "Old registration")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json["protocolSigningAlgorithm"] = "ML-DSA-65"
        json["protocolPublicKeyFingerprint"] = String(repeating: "b", count: 64)
        let current = try JSONDecoder().decode(AccountDeviceRecord.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNotEqual(old.id, current.id)
        XCTAssertEqual(old.deviceId, current.deviceId, "Presentation identity must not rewrite the protocol device ID")
    }

    func testRegistrationStateRequiresTheExactCallerBinding() {
        func snapshot(_ devices: [AccountDeviceRecord], truncated: Bool = false) -> AccountDeviceListSnapshot {
            AccountDeviceListSnapshot(generatedAtEpochMilliseconds: 1, callerDeviceId: "self", truncated: truncated, devices: devices)
        }
        let old = record(id: "self", name: "Bill Mac")
        XCTAssertEqual(AccountDevicePresentationPolicy.registrationIssue(for: snapshot([old])), .identityMismatch)
        XCTAssertEqual(AccountDevicePresentationPolicy.registrationIssue(for: snapshot([])), .notRegistered)
        XCTAssertNil(AccountDevicePresentationPolicy.registrationIssue(for: snapshot([old], truncated: true)))
        XCTAssertNil(AccountDevicePresentationPolicy.registrationIssue(for: snapshot([old, record(id: "self", isCaller: true)])))
        XCTAssertEqual(AccountDevicePresentationPolicy.registrationIssue(for: snapshot([record(id: "self", isCaller: true, status: "pending")])), .pending)
        XCTAssertEqual(AccountDevicePresentationPolicy.registrationIssue(for: snapshot([record(id: "self", isCaller: true, status: "frozen")])), .frozen)
        XCTAssertEqual(AccountDevicePresentationPolicy.registrationIssue(for: snapshot([record(id: "self", isCaller: true, status: "future-state")])), .unrecognizedStatus)
    }

    func testHardwareResolutionDoesNotInventMetadataFromHistoricalNicknames() {
        let legacy = record(id: "old", name: "Bill Mac", platform: "")
        XCTAssertNil(AccountDevicePresentationPolicy.modelDisplayName(for: legacy))
        XCTAssertNil(AccountDevicePresentationPolicy.displayPlatform(for: legacy))
        XCTAssertEqual(AccountDevicePresentationPolicy.displayName(for: legacy), "Bill Mac")
        let rawPad = record(id: "pad", platform: "", model: " iPad16,3 ")
        XCTAssertEqual(AccountDevicePresentationPolicy.modelDisplayName(for: rawPad), "iPad Pro 11-inch (M4)")
        XCTAssertEqual(AccountDevicePresentationPolicy.displayPlatform(for: rawPad), .iPadOS)
        XCTAssertEqual(AppleHardwareModelCatalog.model(for: "MacBookPro18,2")?.name, "MacBook Pro (16-inch, 2021)")
        XCTAssertEqual(AppleHardwareModelCatalog.model(for: "iphone18,1")?.name, "iPhone 17 Pro")
        XCTAssertNil(AppleHardwareModelCatalog.model(for: "Mac99,99"))
        XCTAssertNil(AppleHardwareModelCatalog.model(for: "MacBookPro15,1"), "Apple lists multiple models for this identifier; do not guess the year")
    }

    func testSummaryCountsOnlineAndControllableDevices() {
        let summary = AccountDevicePresentationPolicy.summary(for: [
            record(id: "a", online: true, capabilities: ["remote_desktop"]),
            record(id: "b", online: false, capabilities: ["remote_desktop"]),
            record(id: "c", online: true, platform: "ios", capabilities: ["clipboard"])
        ])
        XCTAssertEqual(summary.total, 3)
        XCTAssertEqual(summary.online, 2)
        XCTAssertEqual(summary.remoteControllable, 2)
    }

    func testUnknownPlatformDecodesLenientlyAndKeepsRawValue() {
        let unknown = record(id: "x", platform: "visionos")
        XCTAssertNil(unknown.platform)
        XCTAssertEqual(unknown.platformRawValue, "visionos")
        XCTAssertEqual(record(id: "y", platform: "ipados").platform, .iPadOS)
    }
}
