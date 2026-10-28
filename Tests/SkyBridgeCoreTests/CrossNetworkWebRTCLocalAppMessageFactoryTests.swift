import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class CrossNetworkWebRTCLocalAppMessageFactoryTests: XCTestCase {
    func testProtocolMetadataPreservesDisplayIdentityAndCanonicalizesIPadFamily() {
        let version = OperatingSystemVersion(majorVersion: 27, minorVersion: 1, patchVersion: 2)
        for (displayPlatform, wirePlatform) in [("macOS", "macOS"), ("iOS", "iOS"), ("iPadOS", "iOS")] {
            let display = LocalDevicePresentation.Snapshot(
                deviceName: "Test device",
                modelName: "Test model",
                platformName: displayPlatform,
                osVersion: "版本27.1.2（版号测试）"
            )
            let wire = display.protocolMetadata(operatingSystemVersion: version)
            XCTAssertEqual(wire.platformName, wirePlatform)
            XCTAssertEqual(wire.osVersion, "27.1.2")
            XCTAssertEqual(wire.deviceName, display.deviceName)
            XCTAssertEqual(wire.modelName, display.modelName)
            XCTAssertEqual(display.osVersion, "版本27.1.2（版号测试）")
            XCTAssertTrue(QPeriaptPlatformPolicy.isPeerAppPlatformEligible(
                platform: wire.platformName, osVersion: wire.osVersion
            ))
            let old = display.protocolMetadata(operatingSystemVersion:
                OperatingSystemVersion(majorVersion: 25, minorVersion: 9, patchVersion: 0)
            )
            XCTAssertFalse(QPeriaptPlatformPolicy.isPeerAppPlatformEligible(
                platform: old.platformName, osVersion: old.osVersion
            ))
        }
    }

    func testCurrentDescriptorUsesMachineReadableOperatingSystemVersion() {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let expected = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        let descriptor = CrossNetworkWebRTCLocalDeviceDescriptor.current()
        XCTAssertEqual(descriptor.osVersion, expected)
        XCTAssertEqual(
            QPeriaptPlatformPolicy.isPeerAppPlatformEligible(
                platform: descriptor.platform,
                osVersion: descriptor.osVersion
            ),
            version.majorVersion >= 26
        )
    }

    func testDefaultPairingAndHeartbeatMetadataPassTheSamePlatformContract() {
        let pairing = CrossNetworkWebRTCLocalAppMessageFactory.pairingIdentityExchangePayload(
            deviceId: "local-device",
            kemPublicKeys: [],
            protocolIdentityPublicKeys: nil,
            remoteVideoFormats: []
        )
        let message = CrossNetworkWebRTCLocalAppMessageFactory.heartbeatMessage(
            deviceId: "local-device",
            remoteVideoFormats: []
        )
        guard case .heartbeat(let heartbeat) = message else {
            return XCTFail("Expected heartbeat message")
        }
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let expected = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        XCTAssertEqual(pairing.osVersion, expected)
        XCTAssertEqual(heartbeat.osVersion, expected)
        XCTAssertEqual(pairing.platform, heartbeat.platform)
        XCTAssertEqual(
            QPeriaptPlatformPolicy.isPeerAppPlatformEligible(
                platform: pairing.platform,
                osVersion: pairing.osVersion
            ),
            version.majorVersion >= 26
        )
    }

    func testHeartbeatMessageIncludesLocalDescriptorAndRemoteVideoFormats() {
        let sentAt = Date(timeIntervalSince1970: 1_234)
        let descriptor = CrossNetworkWebRTCLocalDeviceDescriptor(
            deviceName: "Test Mac",
            modelName: "Mac",
            platform: "macOS",
            osVersion: "Version Test"
        )

        let message = CrossNetworkWebRTCLocalAppMessageFactory.heartbeatMessage(
            deviceId: "device-a",
            remoteVideoFormats: ["hevc", "h264"],
            sentAt: sentAt,
            descriptor: descriptor
        )

        guard case .heartbeat(let payload) = message else {
            return XCTFail("Expected heartbeat message")
        }
        XCTAssertEqual(payload.sentAt, sentAt)
        XCTAssertEqual(payload.deviceId, "device-a")
        XCTAssertEqual(payload.deviceName, "Test Mac")
        XCTAssertEqual(payload.modelName, "Mac")
        XCTAssertEqual(payload.platform, "macOS")
        XCTAssertEqual(payload.osVersion, "Version Test")
        XCTAssertEqual(payload.remoteVideoFormats, ["hevc", "h264"])
    }

    func testPairingIdentityExchangePayloadIncludesLocalDescriptorAndRemoteVideoFormats() {
        let sentAt = Date(timeIntervalSince1970: 5_678)
        let descriptor = CrossNetworkWebRTCLocalDeviceDescriptor(
            deviceName: "Test iPad",
            modelName: "iPad",
            platform: "iOS",
            osVersion: "Version Test"
        )
        let kemKey = KEMPublicKeyInfo(
            suiteWireId: CryptoSuite.xwingMLDSA.wireId,
            publicKey: Data(repeating: 0x42, count: 1_216)
        )

        let payload = CrossNetworkWebRTCLocalAppMessageFactory.pairingIdentityExchangePayload(
            deviceId: "device-b",
            kemPublicKeys: [kemKey],
            protocolIdentityPublicKeys: nil,
            remoteVideoFormats: ["hevc"],
            sentAt: sentAt,
            descriptor: descriptor
        )

        XCTAssertEqual(payload.deviceId, "device-b")
        XCTAssertEqual(payload.kemPublicKeys, [kemKey])
        XCTAssertEqual(payload.deviceName, "Test iPad")
        XCTAssertEqual(payload.modelName, "iPad")
        XCTAssertEqual(payload.platform, "iOS")
        XCTAssertEqual(payload.osVersion, "Version Test")
        XCTAssertEqual(payload.remoteVideoFormats, ["hevc"])
        XCTAssertEqual(payload.sentAt, sentAt)
    }
}
