import XCTest
@testable import SkyBridgeCore

/// 同一台物理设备因协议身份轮换(重装 app → 新 deviceId)在库里留下两个 stable id,
/// 若共享同一条**强格式**硬件序列号,必须合并成一行。
/// 但序列号弱(空/短/默认)的设备——尤其智能家居摄像头——绝不能因此被误并。
@available(macOS 14.0, iOS 17.0, *)
final class SameSerialIdentityMergeTests: XCTestCase {

    private func device(
        name: String,
        uid: String,
        serial: String?,
        source: DeviceSource = .skybridgeBonjour
    ) -> OnlineDevice {
        OnlineDevice(
            id: UUID(),
            name: name,
            deviceType: .unknown,
            ipv4: nil, ipv6: nil,
            platformName: nil, osVersion: nil, modelName: nil, chip: nil,
            macAddress: nil,
            serialNumber: serial,
            connectionTypes: [.usb],
            services: [], portMap: [:],
            uniqueIdentifier: uid,
            sources: [source],
            discoveredAt: Date(), lastSeen: Date(),
            connectionStatus: .online,
            isLocalDevice: false,
            isAuthorized: true
        )
    }

    /// 现场真实数据:iPad 的两个 UUID 身份,同一条 24 位十六进制序列号 → 合并。
    func testSameStrongSerialDifferentProtocolIdsCoalesce() {
        let a = device(name: "Ziang的iPad", uid: "id:07cb9a6e-7492-4680-9dd7-f37dc8568891",
                       serial: "000081320006452C1138801C")
        let b = device(name: "Ziang的iPad", uid: "id:9ddf920e-d7c4-51f2-9c94-67ff629bdf04",
                       serial: "000081320006452C1138801C")
        XCTAssertTrue(
            UnifiedOnlineDeviceManager.shouldCoalesceEquivalentPhysicalDevices(a, b),
            "同一强格式序列号 + 身份轮换 = 同一台 iPad,必须合并"
        )
    }

    /// 安全反例:两台不同的智能家居摄像头,都报空/默认/短序列号,身份不同 → 绝不合并。
    func testWeakSerialDevicesDoNotCoalesceEvenIfSerialStringsMatch() {
        for weak in ["", "0", "00000000", "1234", "SN"] {
            let a = device(name: "Camera A", uid: "id:aaaa1111-2222-4333-8444-555555555555",
                           serial: weak, source: .skybridgeUSB)
            let b = device(name: "Camera B", uid: "id:bbbb1111-2222-4333-8444-555555555555",
                           serial: weak, source: .skybridgeUSB)
            XCTAssertFalse(
                UnifiedOnlineDeviceManager.shouldCoalesceEquivalentPhysicalDevices(a, b),
                "弱序列号(\"\(weak)\")不得把两台不同设备误并"
            )
        }
    }

    /// 不同强序列号 → 不合并(不同设备)。
    func testDifferentStrongSerialsDoNotCoalesce() {
        let a = device(name: "Ziang的iPad", uid: "id:07cb9a6e-7492-4680-9dd7-f37dc8568891",
                       serial: "000081320006452C1138801C")
        let b = device(name: "Ziang的iPhone", uid: "id:31bb9d78-11f6-4843-91ee-0a0c4c003632",
                       serial: "00008140000E788401C0801C")
        XCTAssertFalse(
            UnifiedOnlineDeviceManager.shouldCoalesceEquivalentPhysicalDevices(a, b),
            "不同强序列号 = 不同设备,不得合并"
        )
    }
}
