import XCTest
import SkyBridgeProtocolCore
@testable import SkyBridgeCore

/// 账号设备列表行 → 局域网在线行的匹配必须走同一打分器，且只在协议指纹一致时成立。
@available(macOS 14.0, *)
@MainActor
final class UnifiedOnlineDeviceManagerAccountResolverTests: XCTestCase {
    private let deviceID = "ACCOUNT-DEVICE-0001-ABCDEFGH"
    private let fingerprint = String(repeating: "1a", count: 32)

    private func onlineRow(
        name: String,
        uniqueIdentifier: String,
        ipv4: String?,
        protocolFingerprint: String?,
        isLocalDevice: Bool = false
    ) -> OnlineDevice {
        OnlineDevice(
            id: UUID(),
            name: name,
            deviceType: .computer,
            ipv4: ipv4,
            ipv6: nil,
            platformName: "macOS",
            osVersion: nil,
            modelName: "MacBook Pro",
            chip: nil,
            macAddress: nil,
            serialNumber: nil,
            connectionTypes: [.wifi],
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 8080],
            protocolFingerprint: protocolFingerprint,
            uniqueIdentifier: uniqueIdentifier,
            sources: [.skybridgeBonjour],
            discoveredAt: Date(),
            lastSeen: Date(),
            connectionStatus: .online,
            isLocalDevice: isLocalDevice,
            isAuthorized: false
        )
    }

    private func record(deviceId: String, fingerprint: String, lanAddresses: [String] = []) -> AccountDeviceRecord {
        AccountDeviceRecord(
            deviceId: deviceId,
            deviceName: "Studio Mac",
            status: "active",
            protocolSigningAlgorithm: "Ed25519",
            protocolPublicKeyFingerprint: fingerprint,
            platformRawValue: "macos",
            deviceModel: "MacBook Pro",
            osVersion: nil,
            appVersion: nil,
            lanAddresses: lanAddresses,
            publicAddress: nil,
            capabilities: ["remote_desktop"],
            registeredAtEpochMilliseconds: nil,
            lastSeenAtEpochMilliseconds: nil,
            presenceUpdatedAtEpochMilliseconds: nil,
            online: true,
            isCaller: false
        )
    }

    func testResolvesWhenStableIdAndProtocolFingerprintMatch() {
        let manager = UnifiedOnlineDeviceManager.shared
        defer { manager.replaceDevicesForTesting([]) }
        manager.replaceDevicesForTesting([
            onlineRow(name: "Studio Mac", uniqueIdentifier: deviceID, ipv4: "10.0.0.5", protocolFingerprint: fingerprint)
        ])
        let resolved = manager.resolvedOnlineDevice(for: record(deviceId: deviceID, fingerprint: fingerprint.uppercased()))
        XCTAssertEqual(resolved?.name, "Studio Mac")
    }

    func testDoesNotResolveWhenTheLiveFingerprintDiffers() {
        let manager = UnifiedOnlineDeviceManager.shared
        defer { manager.replaceDevicesForTesting([]) }
        manager.replaceDevicesForTesting([
            onlineRow(name: "Impostor", uniqueIdentifier: deviceID, ipv4: "10.0.0.5", protocolFingerprint: String(repeating: "2b", count: 32))
        ])
        XCTAssertNil(manager.resolvedOnlineDevice(for: record(deviceId: deviceID, fingerprint: fingerprint, lanAddresses: ["10.0.0.5"])))
    }

    func testDoesNotResolveWhenTheLiveRowHasNoValidatedFingerprint() {
        let manager = UnifiedOnlineDeviceManager.shared
        defer { manager.replaceDevicesForTesting([]) }
        manager.replaceDevicesForTesting([
            onlineRow(name: "Unverified", uniqueIdentifier: deviceID, ipv4: "10.0.0.6", protocolFingerprint: nil)
        ])
        XCTAssertNil(manager.resolvedOnlineDevice(for: record(deviceId: deviceID, fingerprint: fingerprint, lanAddresses: ["10.0.0.6"])))
    }

    func testResolvesByLANAddressWhenTheFingerprintMatchesButTheIdentifierIsARoute() {
        let manager = UnifiedOnlineDeviceManager.shared
        defer { manager.replaceDevicesForTesting([]) }
        manager.replaceDevicesForTesting([
            onlineRow(name: "Studio Mac", uniqueIdentifier: "bonjour:Studio Mac@local.", ipv4: "10.0.0.5", protocolFingerprint: fingerprint)
        ])
        let resolved = manager.resolvedOnlineDevice(for: record(deviceId: deviceID, fingerprint: fingerprint, lanAddresses: ["10.0.0.5"]))
        XCTAssertEqual(resolved?.ipv4, "10.0.0.5")
        XCTAssertNil(manager.resolvedOnlineDevice(for: record(deviceId: "OTHER-DEVICE-0002-ABCDEFGH", fingerprint: fingerprint)))
    }

    func testLocalDeviceRowsAreNeverResolvedAsPeers() {
        let manager = UnifiedOnlineDeviceManager.shared
        defer { manager.replaceDevicesForTesting([]) }
        manager.replaceDevicesForTesting([
            onlineRow(name: "This Mac", uniqueIdentifier: deviceID, ipv4: "10.0.0.5", protocolFingerprint: fingerprint, isLocalDevice: true)
        ])
        XCTAssertNil(manager.resolvedOnlineDevice(for: record(deviceId: deviceID, fingerprint: fingerprint)))
    }

    func testRecordWithoutAFingerprintNeverResolvesEvenWhenEverythingElseMatches() {
        let manager = UnifiedOnlineDeviceManager.shared
        defer { manager.replaceDevicesForTesting([]) }
        manager.replaceDevicesForTesting([
            onlineRow(
                name: "Studio Mac",
                uniqueIdentifier: deviceID,
                ipv4: "10.0.0.5",
                protocolFingerprint: fingerprint
            )
        ])
        for missing in ["", "   "] {
            XCTAssertNil(
                manager.resolvedOnlineDevice(
                    for: record(deviceId: deviceID, fingerprint: missing, lanAddresses: ["10.0.0.5"])
                ),
                "缺少协议指纹时不得退化成按名称/IP 匹配"
            )
        }
        XCTAssertNotNil(
            manager.resolvedOnlineDevice(for: record(deviceId: deviceID, fingerprint: fingerprint)),
            "同一台设备带上指纹后仍然应当匹配（说明失败不是因为其它条件）"
        )
    }
}
