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

        let initialRegistration = await arbiter.registerOutgoing(
            Self.outgoingAttempt(pairKey: pairKey)
        )
        guard case .accepted(let reservation) = initialRegistration else {
            XCTFail("Initial remote-control SOA registration should be accepted.")
            return
        }
        let establishedLease = try await arbiter.commitEstablished(
            reservation,
            sessionId: "remote-control-session"
        )
        let blocked = await arbiter.registerOutgoing(Self.outgoingAttempt(pairKey: pairKey))
        guard case .alreadyConnected = blocked else {
            XCTFail("Established remote-control SOA pair should block duplicate handshakes.")
            return
        }

        // Production callers must retain the exact lease. The compatibility
        // clear deliberately cannot remove a modern session owner.
        await arbiter.clearEstablished(pairKey: pairKey)
        let stillBlocked = await arbiter.registerOutgoing(Self.outgoingAttempt(pairKey: pairKey))
        guard case .alreadyConnected = stillBlocked else {
            XCTFail("Legacy pair-key clear must not release a modern owner.")
            return
        }

        let exactLeaseCleared = await arbiter.clearEstablished(establishedLease)
        XCTAssertTrue(exactLeaseCleared)
        let accepted = await arbiter.registerOutgoing(Self.outgoingAttempt(pairKey: pairKey))
        guard case .accepted(let cleanupReservation) = accepted else {
            XCTFail("Released remote-control SOA pair should allow immediate reconnect.")
            return
        }
        let cleanupCleared = await arbiter.clearOutgoing(cleanupReservation)
        XCTAssertTrue(cleanupCleared)
    }

    func testProductionSOACallersUseExactModernLeaseLifecycle() throws {
        let discovery = try repositorySource(
            "Sources/SkyBridgeCore/DeviceDiscovery/DeviceDiscoveryManager.swift"
        )
        let optimizedDiscovery = try repositorySource(
            "Sources/SkyBridgeCore/DeviceDiscovery/DeviceDiscoveryManagerOptimized.swift"
        )
        let remoteControl = try repositorySource(
            "Sources/SkyBridgeCore/RemoteControl/RemoteControlManager.swift"
        )
        let p2pDiscovery = try repositorySource(
            "Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift"
        )

        for (path, source) in [
            ("DeviceDiscoveryManager.swift", discovery),
            ("DeviceDiscoveryManagerOptimized.swift", optimizedDiscovery),
            ("RemoteControlManager.swift", remoteControl),
            ("P2PDiscoveryService.swift", p2pDiscovery),
        ] {
            XCTAssertFalse(
                source.contains("clearEstablished(pairKey:"),
                "\(path) must not use ownerless teardown for a modern session."
            )
            XCTAssertFalse(
                source.contains("clearOutgoing(pairKey:"),
                "\(path) must cancel the owning driver/reservation instead of clearing an unknown attempt."
            )
            XCTAssertTrue(
                source.contains("getEstablishedArbiterLease()"),
                "\(path) must retain the exact lease exported by HandshakeDriver."
            )
        }

        XCTAssertTrue(discovery.contains("restoreEstablishedIfVacant("))
        XCTAssertTrue(remoteControl.contains("var soaEstablishedLease:"))
        XCTAssertTrue(remoteControl.contains("bindEstablishedSOALease("))

        for (path, source) in [
            ("DeviceDiscoveryManager.swift", discovery),
            ("DeviceDiscoveryManagerOptimized.swift", optimizedDiscovery),
            ("P2PDiscoveryService.swift", p2pDiscovery),
        ] {
            XCTAssertFalse(
                source.contains("ConnectionPresenceService.shared.markDisconnected("),
                "\(path) must disconnect presence through its exact owner lease."
            )
            XCTAssertFalse(
                source.contains("ClassicTransferSessionRegistry.shared.remove(sessionId:"),
                "\(path) must remove classic transfer state through its exact owner lease."
            )
            XCTAssertTrue(source.contains("disconnectIfOwned("))
            XCTAssertTrue(source.contains("upsertOwned("))
            XCTAssertTrue(source.contains("ifOwned:"))
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

    private func repositorySource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
