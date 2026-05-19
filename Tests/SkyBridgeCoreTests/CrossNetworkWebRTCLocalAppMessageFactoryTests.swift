import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class CrossNetworkWebRTCLocalAppMessageFactoryTests: XCTestCase {
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
