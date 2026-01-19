import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class AuditTrailTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        await AuditTrail.shared.resetAll()
        SecurityEventEmitter.setAuditTrailEnabled(true)
        // Give the detached setter a moment to run (no-op if already enabled)
        try? await Task.sleep(for: .milliseconds(10))
    }

    func testEmitDetachedRecordsIntoAuditTrailWithoutSubscribers() async throws {
        // Ensure no UI subscribers are registered.
        let subscriberCount = await SecurityEventEmitter.shared.subscriberCount
        XCTAssertEqual(subscriberCount, 0)

        // Emit without subscribers: should still land in AuditTrail (global session).
        SecurityEventEmitter.emitDetached(SecurityEvent(
            type: .cryptoProviderSelected,
            severity: .info,
            message: "provider selected (test)",
            context: ["provider": "ClassicCryptoProvider"]
        ))

        // Detached path is async; poll briefly.
        var snapshot: AuditTrail.Snapshot?
        for _ in 0..<20 {
            snapshot = await AuditTrail.shared.snapshot(sessionId: "global")
            if snapshot?.count ?? 0 > 0 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        guard let snap = snapshot else {
            XCTFail("Expected audit snapshot to exist")
            return
        }

        XCTAssertEqual(snap.sessionId, "global")
        XCTAssertEqual(snap.count, 1)
        XCTAssertEqual(snap.entries.first?.eventType, SecurityEventType.cryptoProviderSelected.rawValue)
        XCTAssertNotEqual(snap.anchorHex, snap.headHashHex, "head hash should advance from anchor after first entry")
        XCTAssertEqual(snap.entries.first?.seq, 1)
    }
}


