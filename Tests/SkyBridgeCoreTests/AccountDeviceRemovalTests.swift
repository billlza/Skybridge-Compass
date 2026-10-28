import XCTest
import SkyBridgeProtocolCore

@MainActor
final class AccountDeviceRemovalTests: XCTestCase {
    private func row(_ id: String, caller: Bool, route: AccountDeviceLANRoute? = nil) -> AccountDeviceRecord {
        AccountDeviceRecord(deviceId: id, deviceName: id, status: "active", protocolSigningAlgorithm: "Ed25519",
            protocolPublicKeyFingerprint: String(repeating: caller ? "a" : "b", count: 64), platformRawValue: "macos",
            deviceModel: nil, osVersion: nil, appVersion: nil, lanAddresses: [], publicAddress: nil, capabilities: [],
            registeredAtEpochMilliseconds: nil, lastSeenAtEpochMilliseconds: nil, presenceUpdatedAtEpochMilliseconds: nil,
            online: true, isCaller: caller, lanControlRoute: route)
    }
    func testReceiptRequiresTheExactRemovedIdentity() throws {
        let target = AccountDeviceRemovalTarget(row("peer", caller: false))
        let object: [String: Any] = ["removed": true, "target": ["deviceId": target.deviceId,
            "protocolSigningAlgorithm": target.protocolSigningAlgorithm,
            "protocolPublicKeyFingerprint": target.protocolPublicKeyFingerprint, "status": "revoked"]]
        let receipt = try JSONDecoder().decode(AccountDeviceRemovalReceipt.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNoThrow(try receipt.validate(target))
        XCTAssertThrowsError(try receipt.validate(AccountDeviceRemovalTarget(row("other", caller: false))))
    }
    func testCallerMarkerAndLocalScopeCannotBeForgedThroughJSON() throws {
        let snapshot = AccountDeviceListSnapshot(generatedAtEpochMilliseconds: 1, callerDeviceId: "caller", truncated: false,
            devices: [row("peer", caller: true)])
        XCTAssertThrowsError(try snapshot.validatedFor(deviceID: "caller", algorithm: "Ed25519", fingerprint: String(repeating: "a", count: 64)))
        let scoped = snapshot.scoped(to: "tenant/owner")
        let decoded = try JSONDecoder().decode(AccountDeviceListSnapshot.self, from: JSONEncoder().encode(scoped))
        XCTAssertNil(decoded.accountScope, "Account authority is local request context, never a wire field")
    }
    func testRemovalIsConfirmedBeforeTheSnapshotChangesAndSelfRemovalStopsPolling() async {
        let caller = row("caller", caller: true), peer = row("peer", caller: false)
        var rows = [caller, peer], mutations = 0, heartbeats = 0
        let engine = AccountPresenceRefreshEngine(registerPresence: { heartbeats += 1 }, listAccountDevices: {
            AccountDeviceListSnapshot(generatedAtEpochMilliseconds: 1, callerDeviceId: "caller", truncated: false,
                devices: rows, accountScope: "tenant/owner")
        }, removeAccountDevice: { target, scope in
            XCTAssertEqual(scope, "tenant/owner"); mutations += 1; rows.removeAll { $0.id == target.id }
        }, trustedDeviceIDs: { [] }, classifyFailure: { _ in .transport }, onStateChange: { _ in })
        engine.start(); await engine.waitForCurrentRefresh()
        await engine.removeDevice(peer, expectedScope: engine.removalScope); await engine.waitForCurrentRefresh()
        XCTAssertEqual(engine.state.accountDevices?.devices.map(\.deviceId), ["caller"])
        await engine.removeDevice(caller, expectedScope: engine.removalScope)
        XCTAssertEqual(mutations, 2); XCTAssertTrue(engine.state.callerRemoved); XCTAssertFalse(engine.isStarted)
        let count = heartbeats; engine.start(); engine.triggerRefresh(); await engine.waitForCurrentRefresh()
        XCTAssertEqual(heartbeats, count)
    }
    func testFailureKeepsTheRecordAndAnOldConfirmationCannotActAfterScopeChange() async {
        let caller = row("caller", caller: true), peer = row("peer", caller: false)
        var mutations = 0
        let engine = AccountPresenceRefreshEngine(registerPresence: {}, listAccountDevices: {
            AccountDeviceListSnapshot(generatedAtEpochMilliseconds: 1, callerDeviceId: "caller", truncated: false,
                devices: [caller, peer], accountScope: "tenant/owner")
        }, removeAccountDevice: { _, _ in mutations += 1; throw AccountDeviceContractError.unconfirmed },
        trustedDeviceIDs: { [] }, classifyFailure: { _ in .malformedResponse }, onStateChange: { _ in })
        engine.start(); await engine.waitForCurrentRefresh()
        let scope = engine.removalScope
        await engine.removeDevice(peer, expectedScope: scope)
        XCTAssertEqual(engine.state.accountDevices?.devices.count, 2); XCTAssertEqual(engine.state.lastRemovalFailure, .malformedResponse)
        engine.stop(); engine.start(); await engine.waitForCurrentRefresh()
        await engine.removeDevice(peer, expectedScope: scope)
        XCTAssertEqual(mutations, 1); engine.stop()
    }

    func testRemovingAnotherDevicePreservesTheOriginalRouteDeadlineWhenRefreshFails() async throws {
        let start = ContinuousClock.now
        var current = start, lists = 0
        let route = try AccountDeviceLANRoute(addresses: ["10.0.0.5"], port: 51173, expiresAt: 11000)
        let caller = row("caller", caller: true)
        let removed = row("old-device", caller: false)
        let remaining = row("peer", caller: false, route: route)
        let engine = AccountPresenceRefreshEngine(routeClock: { current }, registerPresence: {}, listAccountDevices: {
            lists += 1
            guard lists == 1 else { throw URLError(.notConnectedToInternet) }
            return AccountDeviceListSnapshot(generatedAtEpochMilliseconds: 1000, callerDeviceId: "caller", truncated: false,
                devices: [caller, removed, remaining], accountScope: "tenant/owner")
        }, removeAccountDevice: { target, scope in
            XCTAssertEqual(target.id, removed.id)
            XCTAssertEqual(scope, "tenant/owner")
            current = start.advanced(by: .seconds(5))
        }, trustedDeviceIDs: { [] }, classifyFailure: { _ in .transport }, onStateChange: { _ in })
        defer { engine.stop() }
        engine.start(); await engine.waitForCurrentRefresh()
        XCTAssertNotNil(engine.state.accountDevices?.liveRouteDeadline(for: remaining.id, at: current))
        await engine.removeDevice(removed, expectedScope: engine.removalScope)
        await engine.waitForCurrentRefresh()
        let snapshot = try XCTUnwrap(engine.state.accountDevices)
        XCTAssertEqual(snapshot.devices.map(\.deviceId), ["caller", "peer"])
        XCTAssertEqual(engine.state.lastListFailure, .transport)
        XCTAssertEqual(snapshot.liveRouteDeadline(for: remaining.id, at: current), start.advanced(by: .seconds(10)))
        XCTAssertNil(snapshot.liveRouteDeadline(for: remaining.id, at: start.advanced(by: .seconds(10))),
                     "Removing an unrelated device must not renew the remaining route")
    }
}
