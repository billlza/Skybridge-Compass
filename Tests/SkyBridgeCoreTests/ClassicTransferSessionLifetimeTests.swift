import CryptoKit
import Foundation
import SkyBridgeProtocolCore
@testable import SkyBridgeCore
import XCTest

/// Uses synthetic keys and only the in-memory registry; never initializes trust
/// persistence, DeviceIdentityKeyManager, the app runtime or a network connection.
@MainActor
final class ClassicTransferSessionLifetimeTests: XCTestCase {
    private func snapshot(_ id: String, now: Date) -> ClassicTransferSessionSnapshot {
        ClassicTransferSessionSnapshot(
            sessionId: id, matchDeviceId: "same-peer", resolvedPeerDeviceId: "same-peer",
            aliases: ["same-alias"], endpointHostOrIP: "127.0.0.1", capabilities: [],
            sessionKeys: SessionKeys(
                sendKey: Data(repeating: 0x11, count: 32), receiveKey: Data(repeating: 0x22, count: 32),
                negotiatedSuite: .x25519Ed25519, role: .responder,
                transcriptHash: Data(repeating: 0x33, count: 32), sessionId: id, createdAt: now
            ), lastSeenAt: now
        )
    }

    private func handle(_ id: String, now: Date) async throws -> ClassicTransferSessionRegistry.SessionReadHandle {
        let handles = await ClassicTransferSessionRegistry.shared.activeSessionHandles(now: now)
        return try XCTUnwrap(handles.first { $0.snapshot.sessionId == id })
    }

    func testSynchronousRetirementRefusesReadRefreshAndUpdateBeforeCleanup() async throws {
        let registry = ClassicTransferSessionRegistry.shared
        let lifetime = ClassicTransferSessionRegistry.SessionLifetime()
        let id = UUID().uuidString, now = Date(), value = snapshot(id, now: Date())
        let candidate = await registry.upsertOwned(session: value, lifetime: lifetime)
        let lease = try XCTUnwrap(candidate)
        let original = try await handle(id, now: now)
        let before = await registry.currentKeyMaterial(for: original, transferId: "file", now: now)
        XCTAssertNotNil(before)

        lifetime.invalidate()
        lifetime.invalidate() // Terminal and idempotent; no registry remove has run.
        let after = await registry.currentKeyMaterial(for: original, transferId: "file", now: now)
        XCTAssertNil(after)
        let refreshed = await registry.refreshIfOwned(lease, now: now)
        let updated = await registry.updateAuthenticatedSessionIfOwned(lease, snapshot: value, now: now)
        XCTAssertFalse(refreshed)
        XCTAssertFalse(updated)
        let active = await registry.activeSessions(now: now)
        XCTAssertFalse(active.contains { $0.sessionId == id })
        _ = await registry.remove(ifOwned: lease)
    }

    func testMaterialReadBeforeRetirementCannotValidateAfterActorResumes() async throws {
        let registry = ClassicTransferSessionRegistry.shared
        let lifetime = ClassicTransferSessionRegistry.SessionLifetime()
        let id = UUID().uuidString, now = Date()
        let candidate = await registry.upsertOwned(session: snapshot(id, now: now), lifetime: lifetime)
        let lease = try XCTUnwrap(candidate)
        let captured = try await handle(id, now: now)
        let initial = await registry.currentKeyMaterial(for: captured, transferId: "file", now: now)
        let material = try XCTUnwrap(initial)
        // The registry has computed a read before invalidation. Its caller may
        // resume on MainActor only after the synchronous invalidation returns.
        XCTAssertTrue(material.matches(material))
        lifetime.invalidate()
        XCTAssertFalse(material.matches(material), "Equal cached bytes cannot authorize a retired owner after await.")
        _ = await registry.remove(ifOwned: lease)
    }

    func testRemovingOneLeaseInvalidatesCachedMaterialButNotSiblingOnSameControlOwner() async throws {
        let registry = ClassicTransferSessionRegistry.shared
        let owner = ClassicTransferSessionRegistry.SessionLifetime()
        let now = Date(), id = UUID().uuidString, siblingID = UUID().uuidString
        let first = await registry.upsertOwned(session: snapshot(id, now: now), lifetime: owner)
        let second = await registry.upsertOwned(session: snapshot(siblingID, now: now), lifetime: owner)
        let lease = try XCTUnwrap(first), siblingLease = try XCTUnwrap(second)
        let firstHandle = try await handle(id, now: now), siblingHandle = try await handle(siblingID, now: now)
        let firstRead = await registry.currentKeyMaterial(for: firstHandle, transferId: "file", now: now)
        let secondRead = await registry.currentKeyMaterial(for: siblingHandle, transferId: "file", now: now)
        let old = try XCTUnwrap(firstRead), sibling = try XCTUnwrap(secondRead)
        _ = await registry.remove(ifOwned: lease)
        XCTAssertFalse(old.matches(old))
        XCTAssertTrue(owner.isActive)
        XCTAssertTrue(sibling.matches(sibling))
        _ = await registry.remove(ifOwned: siblingLease)
    }

    func testReplacementInvalidatesCachedMaterialWithoutClosingSharedControlOwner() async throws {
        let registry = ClassicTransferSessionRegistry.shared
        let owner = ClassicTransferSessionRegistry.SessionLifetime()
        let now = Date(), id = UUID().uuidString
        let value = snapshot(id, now: now)
        let first = await registry.upsertOwned(session: value, lifetime: owner)
        let oldLease = try XCTUnwrap(first)
        let captured = try await handle(id, now: now)
        let read = await registry.currentKeyMaterial(for: captured, transferId: "file", now: now)
        let old = try XCTUnwrap(read)
        let next = await registry.upsertOwned(session: value, lifetime: owner)
        let newLease = try XCTUnwrap(next)
        XCTAssertFalse(old.matches(old))
        _ = await registry.remove(ifOwned: oldLease)
        let newHandle = try await handle(id, now: now)
        let current = await registry.currentKeyMaterial(for: newHandle, transferId: "file", now: now)
        let currentMaterial = try XCTUnwrap(current)
        XCTAssertTrue(currentMaterial.matches(currentMaterial))
        XCTAssertTrue(owner.isActive)
        _ = await registry.remove(ifOwned: newLease)
    }

    func testLegacyRemovalAndTTLInvalidatePreviouslyReturnedMaterial() async throws {
        let registry = ClassicTransferSessionRegistry.shared
        for expires in [false, true] {
            let now = Date(), id = UUID().uuidString
            await registry.upsert(session: snapshot(id, now: now))
            let captured = try await handle(id, now: now)
            let read = await registry.currentKeyMaterial(for: captured, transferId: "file", now: now)
            let material = try XCTUnwrap(read)
            if expires {
                _ = await registry.activeSessions(now: now.addingTimeInterval(ClassicTransferSessionRegistry.sessionSnapshotTimeToLive + 1))
            } else {
                await registry.remove(sessionId: id)
            }
            XCTAssertFalse(material.matches(material))
        }
    }

    func testAuthenticatedRekeyRetiresCachedMaterialButIdenticalPublicationDoesNot() async throws {
        let registry = ClassicTransferSessionRegistry.shared
        let owner = ClassicTransferSessionRegistry.SessionLifetime()
        let now = Date(), id = UUID().uuidString, value = snapshot(id, now: Date())
        let candidate = await registry.upsertOwned(session: value, lifetime: owner)
        let lease = try XCTUnwrap(candidate)
        let captured = try await handle(id, now: now)
        let read = await registry.currentKeyMaterial(for: captured, transferId: "file", now: now)
        let material = try XCTUnwrap(read)
        _ = await registry.updateAuthenticatedSessionIfOwned(lease, snapshot: value, now: now)
        XCTAssertTrue(material.matches(material))
        let rekey = ClassicTransferSessionSnapshot(
            sessionId: id, matchDeviceId: value.matchDeviceId, resolvedPeerDeviceId: value.resolvedPeerDeviceId,
            aliases: value.aliases, endpointHostOrIP: value.endpointHostOrIP, capabilities: value.capabilities,
            sessionKeys: SessionKeys(sendKey: Data(repeating: 0x44, count: 32), receiveKey: value.sessionKeys.receiveKey,
                negotiatedSuite: value.sessionKeys.negotiatedSuite, role: value.sessionKeys.role,
                transcriptHash: value.sessionKeys.transcriptHash, sessionId: id), lastSeenAt: now
        )
        _ = await registry.updateAuthenticatedSessionIfOwned(lease, snapshot: rekey, now: now)
        XCTAssertFalse(material.matches(material))
        let after = await registry.currentKeyMaterial(for: captured, transferId: "file", now: now)
        let next = try XCTUnwrap(after)
        XCTAssertTrue(next.matches(next))
        XCTAssertTrue(owner.isActive)
        _ = await registry.remove(ifOwned: lease)
    }

    func testRetiredOwnerCannotPublishItsFirstLease() async {
        let registry = ClassicTransferSessionRegistry.shared
        let lifetime = ClassicTransferSessionRegistry.SessionLifetime()
        let id = UUID().uuidString, now = Date()
        lifetime.invalidate()
        let candidate = await registry.upsertOwned(session: snapshot(id, now: now), lifetime: lifetime)
        XCTAssertNil(candidate)
        let handles = await registry.activeSessionHandles(now: now)
        XCTAssertFalse(handles.contains { $0.snapshot.sessionId == id })
    }

    func testOldRetirementAndCleanupCannotRevokeReplacementWithIdenticalKeys() async throws {
        let registry = ClassicTransferSessionRegistry.shared
        let oldLifetime = ClassicTransferSessionRegistry.SessionLifetime()
        let replacementLifetime = ClassicTransferSessionRegistry.SessionLifetime()
        let id = UUID().uuidString, now = Date(), value = snapshot(id, now: Date())
        let first = await registry.upsertOwned(session: value, lifetime: oldLifetime)
        let oldLease = try XCTUnwrap(first)
        let oldHandle = try await handle(id, now: now)
        let originalMaterial = await registry.currentKeyMaterial(for: oldHandle, transferId: "file", now: now)
        let second = await registry.upsertOwned(session: value, lifetime: replacementLifetime)
        let newLease = try XCTUnwrap(second)
        let newHandle = try await handle(id, now: now)

        oldLifetime.invalidate()
        let stale = await registry.currentKeyMaterial(for: oldHandle, transferId: "file", now: now)
        XCTAssertNil(stale)
        let removed = await registry.remove(ifOwned: oldLease)
        let refreshed = await registry.refreshIfOwned(oldLease, now: now)
        let updated = await registry.updateAuthenticatedSessionIfOwned(oldLease, snapshot: value, now: now)
        XCTAssertFalse(removed)
        XCTAssertFalse(refreshed)
        XCTAssertFalse(updated)
        let current = await registry.currentKeyMaterial(for: newHandle, transferId: "file", now: now)
        let retiredMaterial = try XCTUnwrap(originalMaterial)
        let replacementMaterial = try XCTUnwrap(current)
        XCTAssertEqual(
            retiredMaterial.transferKey.withUnsafeBytes { Data($0) },
            replacementMaterial.transferKey.withUnsafeBytes { Data($0) },
            "The replacement discriminator deliberately holds cryptographic keys constant."
        )
        XCTAssertFalse(retiredMaterial.matches(replacementMaterial))
        XCTAssertTrue(replacementMaterial.matches(replacementMaterial))
        XCTAssertTrue(replacementLifetime.isActive)
        _ = await registry.remove(ifOwned: newLease)
    }

    func testLatePublicationAfterRetirementCannotOverwriteReplacement() async throws {
        let registry = ClassicTransferSessionRegistry.shared
        let oldLifetime = ClassicTransferSessionRegistry.SessionLifetime()
        let replacementLifetime = ClassicTransferSessionRegistry.SessionLifetime()
        let id = UUID().uuidString, now = Date(), value = snapshot(id, now: Date())
        let publicationGate = PublicationBarrier()
        let delayedPublication = Task {
            await publicationGate.wait()
            return await registry.upsertOwned(session: value, lifetime: oldLifetime)
        }
        oldLifetime.invalidate()
        let second = await registry.upsertOwned(session: value, lifetime: replacementLifetime)
        let newLease = try XCTUnwrap(second)
        let newHandle = try await handle(id, now: now)
        await publicationGate.release()
        let staleLease = await delayedPublication.value
        XCTAssertNil(staleLease)
        let current = await registry.currentKeyMaterial(for: newHandle, transferId: "file", now: now)
        XCTAssertNotNil(current)
        _ = await registry.remove(ifOwned: newLease)
    }

    func testRetirementClosesAllOwnedSnapshotsButNotSameAliasOnAnotherOwner() async throws {
        let registry = ClassicTransferSessionRegistry.shared
        let retiring = ClassicTransferSessionRegistry.SessionLifetime()
        let independent = ClassicTransferSessionRegistry.SessionLifetime()
        let now = Date(), ids = (0..<3).map { _ in UUID().uuidString }
        var leases: [ClassicTransferSessionRegistry.SessionLease] = []
        var handles: [ClassicTransferSessionRegistry.SessionReadHandle] = []
        for (index, id) in ids.enumerated() {
            let candidate = await registry.upsertOwned(
                session: snapshot(id, now: now), lifetime: index < 2 ? retiring : independent
            )
            leases.append(try XCTUnwrap(candidate))
            handles.append(try await handle(id, now: now))
        }
        retiring.invalidate()
        for (index, captured) in handles.enumerated() {
            let material = await registry.currentKeyMaterial(for: captured, transferId: "file", now: now)
            if index < 2 { XCTAssertNil(material) } else { XCTAssertNotNil(material) }
        }
        for lease in leases { _ = await registry.remove(ifOwned: lease) }
    }

    func testConcurrentAdmissionRefreshAndRetirementNeverRevivesOwner() async throws {
        let registry = ClassicTransferSessionRegistry.shared
        for _ in 0..<32 {
            let lifetime = ClassicTransferSessionRegistry.SessionLifetime()
            let id = UUID().uuidString, now = Date(), value = snapshot(id, now: Date())
            let candidate = await registry.upsertOwned(session: value, lifetime: lifetime)
            let lease = try XCTUnwrap(candidate)
            let original = try await handle(id, now: now)
            await withTaskGroup(of: Void.self) { group in
                group.addTask { _ = await registry.refreshIfOwned(lease, now: now) }
                group.addTask { _ = await registry.updateAuthenticatedSessionIfOwned(lease, snapshot: value, now: now) }
                group.addTask { _ = await registry.upsertOwned(session: value, lifetime: lifetime) }
                group.addTask { lifetime.invalidate() }
            }
            XCTAssertFalse(lifetime.isActive)
            let material = await registry.currentKeyMaterial(for: original, transferId: "file", now: now)
            XCTAssertNil(material)
            let late = await registry.upsertOwned(session: value, lifetime: lifetime)
            XCTAssertNil(late)
            let active = await registry.activeSessionHandles(now: now)
            XCTAssertFalse(active.contains { $0.snapshot.sessionId == id })
        }
    }
}

private actor PublicationBarrier {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
