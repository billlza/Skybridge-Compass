import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, *)
final class RemoteControlSOABindingTests: XCTestCase {
    func testRemoteControlSOABindingNormalizesStableIdentifiers() {
        let localRaw = "550E8400-E29B-41D4-A716-446655440000"
        let remoteRaw = "660E8400-E29B-41D4-A716-446655440001"

        let rawBinding = RemoteControlManager.remoteControlSOABinding(
            localDeviceId: localRaw,
            remoteDeviceId: remoteRaw
        )
        let persistentBinding = RemoteControlManager.remoteControlSOABinding(
            localDeviceId: "id:\(localRaw.lowercased())",
            remoteDeviceId: "id:\(remoteRaw.lowercased())"
        )

        XCTAssertNotNil(rawBinding)
        XCTAssertEqual(rawBinding, persistentBinding)
        XCTAssertNotEqual(rawBinding?.localPeerId, rawBinding?.expectedRemotePeerId)
    }

    func testRemoteControlSOABindingRejectsEphemeralAliases() {
        let localStable = "id:550e8400-e29b-41d4-a716-446655440000"

        XCTAssertNil(
            RemoteControlManager.remoteControlSOABinding(
                localDeviceId: localStable,
                remoteDeviceId: "bonjour:lza's macbook pro@local."
            )
        )
        XCTAssertNil(
            RemoteControlManager.remoteControlSOABinding(
                localDeviceId: "host:192.168.1.10",
                remoteDeviceId: localStable
            )
        )
    }
}
