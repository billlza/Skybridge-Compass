import Foundation
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

    func testRemoteControlSOAEstablishedGuardReleasesForReconnect() async throws {
        let binding = try XCTUnwrap(
            RemoteControlManager.remoteControlSOABinding(
                localDeviceId: "id:550e8400-e29b-41d4-a716-446655440000",
                remoteDeviceId: "id:660e8400-e29b-41d4-a716-446655440001"
            )
        )
        let pairKey = PeerSessionArbiter.pairKey(
            localPeerId: binding.localPeerId,
            remotePeerId: binding.expectedRemotePeerId,
            scope: .remoteControl
        )
        let arbiter = PeerSessionArbiter()

        await arbiter.markEstablished(pairKey: pairKey)
        let blocked = await arbiter.registerOutgoing(Self.outgoingAttempt(pairKey: pairKey))
        guard case .alreadyConnected = blocked else {
            XCTFail("Established remote-control SOA pair should block duplicate handshakes.")
            return
        }

        await arbiter.clearEstablished(pairKey: pairKey)
        await arbiter.clearOutgoing(pairKey: pairKey, attemptId: nil)
        let accepted = await arbiter.registerOutgoing(Self.outgoingAttempt(pairKey: pairKey))
        guard case .accepted = accepted else {
            XCTFail("Released remote-control SOA pair should allow immediate reconnect.")
            return
        }
    }

    private static func outgoingAttempt(pairKey: Data) -> PeerSessionArbiter.OutgoingAttempt {
        PeerSessionArbiter.OutgoingAttempt(
            pairKey: pairKey,
            initiatorPeerId: Data(repeating: 0x11, count: 32),
            attemptId: Data(repeating: 0x22, count: 16),
            startedAt: Date(),
            onSuperseded: { _, _ in }
        )
    }
}
