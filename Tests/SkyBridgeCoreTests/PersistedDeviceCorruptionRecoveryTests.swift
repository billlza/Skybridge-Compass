import XCTest
@testable import SkyBridgeCore

/// 回归：被污染的持久化设备库(同一稳定身份的多行,名字/类型互相污染)必须在加载时
/// 折叠成一行、并按多数票恢复正确身份——否则 iPad 会以「Mac 的名字 + 路由器类型」出现、
/// 永远显示不出真身。数据形状取自真实现场的 com.skybridge.compass.pro.plist。
@available(macOS 14.0, iOS 17.0, *)
final class PersistedDeviceCorruptionRecoveryTests: XCTestCase {

    private let storageKey = "skybridge.persistedDevices"
    private let iPadUID = "id:07CB9A6E-7492-4680-9DD7-F37DC8568891"
    private let iPadSerial = "000081320006452C1138801C"

    private struct Payload: Codable {
        let schemaVersion: Int
        let devices: [OnlineDevice]
    }

    private func makeRow(name: String, type: DeviceClassifier.DeviceType, platform: String, uid: String, authorized: Bool = true, secondsAgo: TimeInterval) -> OnlineDevice {
        OnlineDevice(
            id: UUID(),
            name: name,
            deviceType: type,
            ipv4: "192.168.0.104", ipv6: nil,
            platformName: platform,
            osVersion: nil,
            modelName: "iPad Pro 11-inch (M4)",
            chip: nil,
            macAddress: nil,
            serialNumber: iPadSerial,
            connectionTypes: [.wifi],
            services: [], portMap: [:],
            uniqueIdentifier: uid,
            sources: [.skybridgeBonjour, .skybridgeCloud, .skybridgeUSB],
            discoveredAt: Date(timeIntervalSinceNow: -secondsAgo),
            lastSeen: Date(timeIntervalSinceNow: -secondsAgo),
            connectionStatus: .offline,
            isLocalDevice: false,
            isAuthorized: authorized
        )
    }

    @MainActor
    func testCorruptedStoreCollapsesToOneCorrectlyNamedRow() throws {
        // 真实污染形状:同一 iPad 身份 20 行,多数是 "Ziang的iPad",少数被写成 "Lza的MacBook Pro"/路由器。
        var rows: [OnlineDevice] = []
        for i in 0..<14 {
            rows.append(makeRow(name: "Ziang的iPad", type: .unknown, platform: "ipados", uid: iPadUID, secondsAgo: Double(i * 10)))
        }
        rows.append(makeRow(name: "Lza的MacBook Pro", type: .router, platform: "ipados", uid: iPadUID, secondsAgo: 1))
        rows.append(makeRow(name: "Lza的MacBook Pro", type: .unknown, platform: "ipados", uid: iPadUID, secondsAgo: 2))
        rows.append(makeRow(name: "Ziang的iPad", type: .nas, platform: "ios", uid: iPadUID, secondsAgo: 3))
        // 大小写不同的同一身份 + 未授权的裸行(也应折叠进来)。
        rows.append(makeRow(name: "iPad Pro 11-inch (M4)", type: .unknown, platform: "ipados", uid: iPadUID.lowercased(), authorized: false, secondsAgo: 4))

        let data = try JSONEncoder().encode(Payload(schemaVersion: 2, devices: rows))
        let defaults = UserDefaults.standard
        let previous = defaults.data(forKey: storageKey)
        defaults.set(data, forKey: storageKey)
        defer {
            if let previous { defaults.set(previous, forKey: storageKey) }
            else { defaults.removeObject(forKey: storageKey) }
            UnifiedOnlineDeviceManager.shared.replaceDevicesForTesting([])
        }

        let manager = UnifiedOnlineDeviceManager.shared
        manager.replaceDevicesForTesting([])
        manager.reloadPersistedDevicesForTesting()

        // 该身份只剩一行。
        let iPadRows = manager.onlineDevices.filter {
            $0.uniqueIdentifier.caseInsensitiveCompare(iPadUID) == .orderedSame
        }
        XCTAssertEqual(iPadRows.count, 1, "被污染的重复身份必须折叠成一行；实际：\(iPadRows.map { "\($0.name)/\($0.deviceType)" })")

        let row = try XCTUnwrap(iPadRows.first)
        XCTAssertEqual(row.name, "Ziang的iPad", "多数票必须恢复正确名字，而不是被少数派污染成 Mac 名字")
        XCTAssertNotEqual(row.deviceType, .router, "iPad 的类型不得是路由器")
        XCTAssertTrue(row.isAuthorized, "任一变体已授权则折叠后仍应授权")
        XCTAssertEqual(row.serialNumber, iPadSerial)
    }

    /// 折叠后再来一次真实 USB iPad,应稳定合并、保持正确身份并因 USB 在线。
    @MainActor
    func testCollapsedRowStaysCorrectWhenLiveUSBiPadArrives() throws {
        let rows = [
            makeRow(name: "Ziang的iPad", type: .unknown, platform: "ipados", uid: iPadUID, secondsAgo: 30),
            makeRow(name: "Lza的MacBook Pro", type: .router, platform: "ipados", uid: iPadUID, secondsAgo: 1),
            makeRow(name: "Ziang的iPad", type: .unknown, platform: "ipados", uid: iPadUID, secondsAgo: 20),
        ]
        let data = try JSONEncoder().encode(Payload(schemaVersion: 2, devices: rows))
        let defaults = UserDefaults.standard
        let previous = defaults.data(forKey: storageKey)
        defaults.set(data, forKey: storageKey)
        defer {
            if let previous { defaults.set(previous, forKey: storageKey) }
            else { defaults.removeObject(forKey: storageKey) }
            UnifiedOnlineDeviceManager.shared.applyUSBDevicesUpdateForTesting([])
            UnifiedOnlineDeviceManager.shared.replaceDevicesForTesting([])
        }

        let manager = UnifiedOnlineDeviceManager.shared
        manager.replaceDevicesForTesting([])
        manager.reloadPersistedDevicesForTesting()

        let iPadUSB = USBDevice(
            id: "1452-4779-loc", name: "iPad",
            vendorID: 0x05AC, productID: 0x12AB,
            vendorName: "Apple Inc.", productName: "iPad",
            serialNumber: iPadSerial, deviceType: .iPad, locationID: 1
        )
        manager.applyUSBDevicesUpdateForTesting([iPadUSB])

        let iPadRows = manager.onlineDevices.filter {
            $0.serialNumber == iPadSerial || $0.uniqueIdentifier.caseInsensitiveCompare(iPadUID) == .orderedSame
        }
        XCTAssertFalse(
            iPadRows.contains { $0.name == "Lza的MacBook Pro" || $0.deviceType == .router },
            "USB iPad 上来后不得再显示成 Mac 名字/路由器；实际：\(iPadRows.map { "\($0.name)/\($0.deviceType)/\($0.connectionStatus)" })"
        )
        XCTAssertTrue(
            iPadRows.contains { $0.connectionStatus == .online },
            "USB 直连的 iPad 应为在线；实际：\(iPadRows.map { "\($0.name)/\($0.connectionStatus)" })"
        )
    }
}
