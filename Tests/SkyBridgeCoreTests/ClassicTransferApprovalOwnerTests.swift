import CryptoKit
import Foundation
import SkyBridgeProtocolCore
@testable import SkyBridgeCore
import XCTest

@MainActor
final class ClassicTransferApprovalOwnerTests: XCTestCase {
    private func snapshot(_ id: String, keyByte: UInt8 = 0x11, now: Date, capabilityEvidence: ClassicTransferPeerCapabilities? = nil) -> ClassicTransferSessionSnapshot {
        ClassicTransferSessionSnapshot(
            sessionId: id, matchDeviceId: id, resolvedPeerDeviceId: id,
            aliases: [id], endpointHostOrIP: "127.0.0.1", capabilities: ["classic_approval_v1"],
            sessionKeys: SessionKeys(
                sendKey: Data(repeating: keyByte, count: 32), receiveKey: Data(repeating: 0x22, count: 32),
                negotiatedSuite: .x25519Ed25519, role: .initiator,
                transcriptHash: Data(repeating: 0x33, count: 32), sessionId: id, createdAt: now
            ), capabilityEvidence: capabilityEvidence, lastSeenAt: now
        )
    }

    func testHeartbeatHintsCannotPromoteOrClearAuthenticatedApproval() async throws {
        let registry = ClassicTransferSessionRegistry.shared
        for supported in [false, true] {
            let id = "approval-heartbeat-\(UUID().uuidString)"
            let now = Date()
            let evidence = try ClassicTransferPeerCapabilities(
                acceptedCapabilities: supported ? ["classic_approval_v1"] : [],
                sessionID: id, transcriptHash: Data(repeating: 0x33, count: 32)
            )
            let lease = await registry.upsertOwned(session: snapshot(id, now: now, capabilityEvidence: evidence))
            let handles = await registry.activeSessionHandles(now: now)
            let handle = try XCTUnwrap(handles.first { $0.snapshot.sessionId == id })
            let initial = await registry.currentKeyMaterial(for: handle, transferId: "t", now: now)
            XCTAssertEqual(initial?.approvalCapability, supported)
            let refreshed = await registry.refreshIfOwned(
                lease, capabilities: supported ? [] : ["classic_approval_v1"],
                now: now.addingTimeInterval(1)
            )
            XCTAssertTrue(refreshed)
            let current = await registry.currentKeyMaterial(for: handle, transferId: "t", now: now.addingTimeInterval(1))
            XCTAssertEqual(current?.approvalCapability, supported)
            let removed = await registry.remove(ifOwned: lease)
            XCTAssertTrue(removed)
        }
    }

    func testReplacementWithIdenticalIdentityAndKeysInvalidatesReadHandle() async throws {
        let registry = ClassicTransferSessionRegistry.shared
        let id = "approval-owner-\(UUID().uuidString)"
        let now = Date()
        let original = snapshot(id, now: now)
        let oldLease = await registry.upsertOwned(session: original)
        let handles = await registry.activeSessionHandles(now: now)
        let oldHandle = try XCTUnwrap(handles.first { $0.snapshot.sessionId == id })
        let oldMaterial = await registry.currentKeyMaterial(for: oldHandle, transferId: "t", now: now)
        XCTAssertNotNil(oldMaterial)
        let replacementLease = await registry.upsertOwned(session: original)
        let after = await registry.currentKeyMaterial(for: oldHandle, transferId: "t", now: now)
        XCTAssertNil(after, "Equal keys/identity must not substitute for the original registration owner.")
        let currentHandles = await registry.activeSessionHandles(now: now)
        let currentHandle = try XCTUnwrap(currentHandles.first { $0.snapshot.sessionId == id })
        let current = await registry.currentKeyMaterial(for: currentHandle, transferId: "t", now: now)
        XCTAssertTrue(try XCTUnwrap(oldMaterial).matches(XCTUnwrap(current)), "The discriminator holds key material constant.")
        let oldRemoved = await registry.remove(ifOwned: oldLease)
        XCTAssertFalse(oldRemoved)
        let replacementRemoved = await registry.remove(ifOwned: replacementLease)
        XCTAssertTrue(replacementRemoved)
    }

    func testRefreshRekeyRetirementAndExpiryHaveDistinctOutcomes() async throws {
        let registry = ClassicTransferSessionRegistry.shared
        let id = "approval-refresh-\(UUID().uuidString)"
        let now = Date()
        let lease = await registry.upsertOwned(session: snapshot(id, now: now))
        let handles = await registry.activeSessionHandles(now: now)
        let handle = try XCTUnwrap(handles.first { $0.snapshot.sessionId == id })
        let initial = await registry.currentKeyMaterial(for: handle, transferId: "t", now: now)
        let refreshed = await registry.refreshIfOwned(lease, now: now.addingTimeInterval(1))
        XCTAssertTrue(refreshed)
        let afterRefresh = await registry.currentKeyMaterial(for: handle, transferId: "t", now: now.addingTimeInterval(1))
        XCTAssertTrue(try XCTUnwrap(initial).matches(XCTUnwrap(afterRefresh)))
        let updated = await registry.updateAuthenticatedSessionIfOwned(lease, snapshot: snapshot(id, keyByte: 0x44, now: now), now: now)
        XCTAssertTrue(updated)
        let afterRekey = await registry.currentKeyMaterial(for: handle, transferId: "t", now: now)
        XCTAssertFalse(try XCTUnwrap(initial).matches(XCTUnwrap(afterRekey)))
        let expired = await registry.currentKeyMaterial(for: handle, transferId: "t", now: now.addingTimeInterval(ClassicTransferSessionRegistry.sessionSnapshotTimeToLive + 1))
        XCTAssertNil(expired)
        let revived = await registry.refreshIfOwned(lease, now: now.addingTimeInterval(1))
        XCTAssertFalse(revived)
    }
}
