import XCTest
@testable import SkyBridgeCompass_iOS

final class P2PConnectionLeaseStoreTests: XCTestCase {
    private final class TestConnection: @unchecked Sendable {}

    func testStaleLeaseCannotRemoveReplacementConnection() throws {
        var store = P2PConnectionLeaseStore<TestConnection>()
        let firstConnection = TestConnection()
        let replacementConnection = TestConnection()

        let firstLease = try store.install(firstConnection, for: "peer")
        let replacementLease = try store.install(replacementConnection, for: "peer")

        XCTAssertFalse(store.isCurrent(firstLease, for: "peer"))
        XCTAssertTrue(store.isCurrent(replacementLease, for: "peer"))
        XCTAssertNil(store.removeIfOwned(firstLease, for: "peer"))
        XCTAssertTrue(try XCTUnwrap(store["peer"]) === replacementConnection)
    }

    func testCurrentLeaseRemovalIsExactAndTerminal() throws {
        var store = P2PConnectionLeaseStore<TestConnection>()
        let connection = TestConnection()
        let lease = try store.install(connection, for: "peer")

        XCTAssertTrue(store.removeIfOwned(lease, for: "peer") === connection)
        XCTAssertNil(store["peer"])
        XCTAssertFalse(store.isCurrent(lease, for: "peer"))
    }

    func testLateOldConnectionFailureCannotRemoveInstalledReplacement() throws {
        var store = P2PConnectionLeaseStore<TestConnection>()
        let oldConnection = TestConnection()
        let replacementConnection = TestConnection()
        _ = try store.install(oldConnection, for: "peer")
        let replacementLease = try store.install(replacementConnection, for: "peer")

        // Mirrors cleanupBrokenInboundConnection: obtain the current lease,
        // then remove only when that lease still owns the failing object.
        if let currentLease = store.lease(for: "peer"),
           currentLease.connection === oldConnection {
            _ = store.removeIfOwned(currentLease, for: "peer")
        }

        XCTAssertTrue(store.isCurrent(replacementLease, for: "peer"))
        XCTAssertTrue(try XCTUnwrap(store["peer"]) === replacementConnection)
    }

    func testSequenceExhaustionFailsWithoutInstallingConnection() {
        var store = P2PConnectionLeaseStore<TestConnection>(
            testingNextSequence: .max
        )

        XCTAssertThrowsError(
            try store.install(TestConnection(), for: "peer")
        ) { error in
            XCTAssertEqual(
                error as? P2PConnectionLeaseStore<TestConnection>.LeaseError,
                .sequenceExhausted
            )
        }
        XCTAssertNil(store["peer"])
    }
}
