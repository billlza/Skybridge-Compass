import Foundation
import XCTest
@testable import SkyBridgeCore

final class P2PDiscoveryCapacityTests: XCTestCase {
    func testFreshSkyBridgeStormBeyondCapacityIsRejectedWithoutStateChurn() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        var state = P2PDiscoveryService.DiscoveryCapacityState()
        let records = (0..<P2PDiscoveryService.maximumDiscoveredDevices).map { index in
            let id = deterministicUUID(index)
            state.recordActivity(for: id, at: now)
            return P2PDiscoveryService.DiscoveryCapacityRecord(
                id: id,
                priority: .skyBridge,
                isProtected: false
            )
        }

        for _ in 0..<512 {
            XCTAssertEqual(
                state.admissionDecision(
                    existing: records,
                    incomingPriority: .skyBridge,
                    incomingIsProtected: false,
                    limit: P2PDiscoveryService.maximumDiscoveredDevices,
                    staleAfter: 30,
                    now: now
                ),
                .reject
            )
        }
        XCTAssertEqual(state.trackedDeviceCount, P2PDiscoveryService.maximumDiscoveredDevices)
    }

    func testProtectedIncomingEvictsOnlyUnprotectedLowestPriorityLRURecord() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let protectedID = deterministicUUID(1)
        let oldCompatibilityID = deterministicUUID(2)
        let recentCompatibilityID = deterministicUUID(3)
        var state = P2PDiscoveryService.DiscoveryCapacityState()
        state.recordActivity(for: protectedID, at: now.addingTimeInterval(-300))
        state.recordActivity(for: oldCompatibilityID, at: now.addingTimeInterval(-20))
        state.recordActivity(for: recentCompatibilityID, at: now.addingTimeInterval(-10))

        let decision = state.admissionDecision(
            existing: [
                .init(id: protectedID, priority: .protected, isProtected: true),
                .init(id: recentCompatibilityID, priority: .compatibility, isProtected: false),
                .init(id: oldCompatibilityID, priority: .compatibility, isProtected: false),
            ],
            incomingPriority: .protected,
            incomingIsProtected: true,
            limit: 3,
            staleAfter: 30,
            now: now
        )

        XCTAssertEqual(decision, .evict(oldCompatibilityID))
        XCTAssertNotEqual(decision, .evict(protectedID))
    }

    func testActiveTrustedAndLocalProtectionSignalsAreEquivalentFailClosedBoundaries() {
        XCTAssertTrue(
            P2PDiscoveryService.shouldProtectDiscoveryCapacityRecord(
                isLocalDevice: true,
                isTrusted: false,
                hasActiveConnection: false
            )
        )
        XCTAssertTrue(
            P2PDiscoveryService.shouldProtectDiscoveryCapacityRecord(
                isLocalDevice: false,
                isTrusted: true,
                hasActiveConnection: false
            )
        )
        XCTAssertTrue(
            P2PDiscoveryService.shouldProtectDiscoveryCapacityRecord(
                isLocalDevice: false,
                isTrusted: false,
                hasActiveConnection: true
            )
        )
        XCTAssertFalse(
            P2PDiscoveryService.shouldProtectDiscoveryCapacityRecord(
                isLocalDevice: false,
                isTrusted: false,
                hasActiveConnection: false
            )
        )
    }

    func testAllProtectedCapacityRejectsEvenProtectedIncomingInsteadOfReplacingActiveDevice() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        var state = P2PDiscoveryService.DiscoveryCapacityState()
        let records = (0..<8).map { index in
            let id = deterministicUUID(index)
            state.recordActivity(for: id, at: now.addingTimeInterval(-1_000))
            return P2PDiscoveryService.DiscoveryCapacityRecord(
                id: id,
                priority: .protected,
                isProtected: true
            )
        }

        XCTAssertEqual(
            state.admissionDecision(
                existing: records,
                incomingPriority: .protected,
                incomingIsProtected: true,
                limit: records.count,
                staleAfter: 30,
                now: now
            ),
            .reject
        )
    }

    func testSamePriorityAdmissionEvictsOnlyActuallyStaleLRURecord() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let staleID = deterministicUUID(10)
        let freshID = deterministicUUID(11)
        var state = P2PDiscoveryService.DiscoveryCapacityState()
        state.recordActivity(for: staleID, at: now.addingTimeInterval(-31))
        state.recordActivity(for: freshID, at: now.addingTimeInterval(-5))

        XCTAssertEqual(
            state.admissionDecision(
                existing: [
                    .init(id: freshID, priority: .skyBridge, isProtected: false),
                    .init(id: staleID, priority: .skyBridge, isProtected: false),
                ],
                incomingPriority: .skyBridge,
                incomingIsProtected: false,
                limit: 2,
                staleAfter: 30,
                now: now
            ),
            .evict(staleID)
        )
    }

    func testHydrationOwnerAdmissionIsBoundedBeforeTaskCreation() {
        let limit = P2PDiscoveryService.maximumHydrationTaskOwners
        XCTAssertTrue(P2PDiscoveryService.canAdmitHydrationTaskOwner(currentCount: 0, limit: limit))
        XCTAssertTrue(P2PDiscoveryService.canAdmitHydrationTaskOwner(currentCount: limit - 1, limit: limit))
        XCTAssertFalse(P2PDiscoveryService.canAdmitHydrationTaskOwner(currentCount: limit, limit: limit))
        XCTAssertFalse(P2PDiscoveryService.canAdmitHydrationTaskOwner(currentCount: limit + 1_000, limit: limit))

        var admitted = 0
        for _ in 0..<(limit + 512) where
            P2PDiscoveryService.canAdmitHydrationTaskOwner(currentCount: admitted, limit: limit) {
            admitted += 1
        }
        XCTAssertEqual(admitted, limit)
    }

    func testPerDeviceRouteIdentifiersRejectStormBeyondBound() {
        let limit = P2PDiscoveryService.maximumRouteIdentifiersPerDevice
        var identifiers: [String] = []
        var rejectionCount = 0

        for index in 0..<(limit + 512) {
            let result = P2PDiscoveryService.boundedRouteIdentifierMerge(
                existing: identifiers,
                incoming: "bonjour:spoof-\(index)@local.",
                limit: limit
            )
            identifiers = result.identifiers
            if !result.accepted {
                rejectionCount += 1
            }
        }

        XCTAssertEqual(identifiers.count, limit)
        XCTAssertEqual(rejectionCount, 512)
        let duplicate = P2PDiscoveryService.boundedRouteIdentifierMerge(
            existing: identifiers,
            incoming: identifiers[0].uppercased(),
            limit: limit
        )
        XCTAssertTrue(duplicate.accepted)
        XCTAssertEqual(duplicate.identifiers, identifiers)
    }

    func testCapacityStateCleanupRemovesAllActivityIndexes() {
        var state = P2PDiscoveryService.DiscoveryCapacityState()
        for index in 0..<P2PDiscoveryService.maximumDiscoveredDevices {
            state.recordActivity(for: deterministicUUID(index), at: Date())
        }
        XCTAssertEqual(state.trackedDeviceCount, P2PDiscoveryService.maximumDiscoveredDevices)

        state.removeAll()
        XCTAssertEqual(state.trackedDeviceCount, 0)
    }

    func testProductionSourceChecksCapacityBeforePublishedAppendAndTaskCreation() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("@Published public private(set) var discoveredDevices"))
        XCTAssertTrue(source.contains("static let maximumDiscoveredDevices = 128"))
        XCTAssertTrue(source.contains("static let maximumHydrationTaskOwners = 128"))
        XCTAssertTrue(source.contains("static let maximumRouteIdentifiersPerDevice = 32"))
        XCTAssertTrue(source.contains("isTrustedDiscoveryDevice(device)"))
        XCTAssertTrue(source.contains("hasActiveDiscoveryConnection(device)"))
        XCTAssertTrue(source.contains("Self.boundedRouteIdentifierMerge("))
        XCTAssertTrue(source.contains("unprotectedAdmissionBackoffUntil"))

        let upsert = try sourceSlice(
            source,
            from: "private func upsertDiscoveredDevice(",
            to: "private func removeDiscoveredDevice(from result:"
        )
        let admission = try XCTUnwrap(upsert.range(of: "guard admitNewDiscoveredDevice(device, now: activityDate) else { return }"))
        let append = try XCTUnwrap(upsert.range(of: "discoveredDevices.append(device)"))
        XCTAssertLessThan(admission.lowerBound, append.lowerBound)

        let hydration = try sourceSlice(
            source,
            from: "private func resolveViaNetServiceIfNeeded(",
            to: "private func pruneTXTResolveCooldown("
        )
        let ownerAdmission = try XCTUnwrap(hydration.range(of: "guard Self.canAdmitHydrationTaskOwner("))
        let taskCreation = try XCTUnwrap(hydration.range(of: "let task = Task { @MainActor"))
        XCTAssertLessThan(ownerAdmission.lowerBound, taskCreation.lowerBound)
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy: "resetDiscoveryCapacityState()").count - 1,
            3
        )
    }

    private func deterministicUUID(_ index: Int) -> UUID {
        let suffix = String(format: "%012llX", UInt64(index))
        guard let uuid = UUID(uuidString: "00000000-0000-0000-0000-\(suffix)") else {
            preconditionFailure("Deterministic UUID fixture construction failed")
        }
        return uuid
    }

    private func sourceSlice(_ source: String, from start: String, to end: String) throws -> String {
        let startRange = try XCTUnwrap(source.range(of: start))
        let endRange = try XCTUnwrap(
            source.range(of: end, range: startRange.upperBound..<source.endIndex)
        )
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }
}
