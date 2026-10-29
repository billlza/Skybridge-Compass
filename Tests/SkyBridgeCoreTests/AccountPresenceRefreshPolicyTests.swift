import XCTest
@testable import SkyBridgeProtocolCore

final class AccountPresenceRefreshPolicyTests: XCTestCase {
    func testClassifiesServerCodesBeforeStatusCodes() {
        XCTAssertEqual(AccountPresenceRefreshPolicy.classify(status: 403, code: "device_revoked"), .deviceNotActive(code: "device_revoked"))
        XCTAssertEqual(AccountPresenceRefreshPolicy.classify(status: 403, code: " Device_Not_Registered "), .deviceNotActive(code: "device_not_registered"))
        XCTAssertEqual(AccountPresenceRefreshPolicy.classify(status: 503, code: "registry_schema_outdated"), .registryUnavailable(code: "registry_schema_outdated"))
        XCTAssertEqual(AccountPresenceRefreshPolicy.classify(status: 401, code: nil), .notAuthenticated)
        XCTAssertEqual(AccountPresenceRefreshPolicy.classify(status: 429, code: nil), .rateLimited)
        XCTAssertEqual(AccountPresenceRefreshPolicy.classify(status: 403, code: "tenant_public_access_disabled"), .serverRejected(status: 403, code: "tenant_public_access_disabled"))
        XCTAssertEqual(AccountPresenceRefreshPolicy.classify(status: 500, code: nil), .serverRejected(status: 500, code: nil))
    }

    func testRetryDelaysBackOffAndAreBoundedPerFailureClass() {
        XCTAssertEqual(AccountPresenceRefreshPolicy.retryDelay(after: .transport, consecutiveFailures: 1), 30)
        XCTAssertEqual(AccountPresenceRefreshPolicy.retryDelay(after: .transport, consecutiveFailures: 2), 60)
        XCTAssertEqual(AccountPresenceRefreshPolicy.retryDelay(after: .transport, consecutiveFailures: 3), 120)
        XCTAssertEqual(AccountPresenceRefreshPolicy.retryDelay(after: .transport, consecutiveFailures: 40), 300)
        XCTAssertEqual(AccountPresenceRefreshPolicy.retryDelay(after: .deviceNotActive(code: "device_revoked"), consecutiveFailures: 1), 300)
        XCTAssertEqual(AccountPresenceRefreshPolicy.retryDelay(after: .notAuthenticated, consecutiveFailures: 9), 60)
        XCTAssertEqual(AccountPresenceRefreshPolicy.retryDelay(after: .localIdentityUnavailable, consecutiveFailures: 1), 60)
        XCTAssertEqual(AccountPresenceRefreshPolicy.retryDelay(after: .rateLimited, consecutiveFailures: 1), 60)
        XCTAssertEqual(AccountPresenceRefreshPolicy.retryDelay(after: .serverRejected(status: 502, code: nil), consecutiveFailures: 1), 30)
        XCTAssertEqual(AccountPresenceRefreshPolicy.retryDelay(after: .serverRejected(status: 400, code: "bad_device_binding"), consecutiveFailures: 1), 60)
        XCTAssertEqual(AccountPresenceRefreshPolicy.retryDelay(after: .transport, consecutiveFailures: 0), 30)
    }

    func testSnapshotStalenessFailsClosedOnMissingSuccessAndClockRollback() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertTrue(AccountPresenceRefreshPolicy.isSnapshotStale(lastSuccessAt: nil, now: now))
        XCTAssertFalse(AccountPresenceRefreshPolicy.isSnapshotStale(lastSuccessAt: now.addingTimeInterval(-89), now: now))
        XCTAssertTrue(AccountPresenceRefreshPolicy.isSnapshotStale(lastSuccessAt: now.addingTimeInterval(-90), now: now))
        XCTAssertTrue(AccountPresenceRefreshPolicy.isSnapshotStale(lastSuccessAt: now.addingTimeInterval(1), now: now))
        XCTAssertFalse(AccountPresenceRefreshPolicy.isSnapshotStale(lastSuccessAt: now.addingTimeInterval(-500), now: now, ttl: 600))
    }

    func testLoopSleepIntervalWakesForExpiryBeforeALongBackoffAndNeverGoesNegative() {
        XCTAssertEqual(AccountPresenceRefreshPolicy.loopSleepInterval(untilRefresh: 30, untilOnlineStateExpires: nil), 30)
        XCTAssertEqual(AccountPresenceRefreshPolicy.loopSleepInterval(untilRefresh: 300, untilOnlineStateExpires: 42), 42)
        XCTAssertEqual(AccountPresenceRefreshPolicy.loopSleepInterval(untilRefresh: 30, untilOnlineStateExpires: 90), 30)
        XCTAssertEqual(AccountPresenceRefreshPolicy.loopSleepInterval(untilRefresh: -5, untilOnlineStateExpires: nil), 0)
        XCTAssertEqual(AccountPresenceRefreshPolicy.loopSleepInterval(untilRefresh: 30, untilOnlineStateExpires: -1), 0)
        XCTAssertEqual(AccountPresenceRefreshPolicy.loopSleepInterval(untilRefresh: 0, untilOnlineStateExpires: 10), 0)
    }
}
