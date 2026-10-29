import XCTest
@testable import SkyBridgeCore

@MainActor
final class SSHLaunchContextTests: XCTestCase {
    func testConnectionRequestConsumesPasswordExactlyOnceByOwnerToken() throws {
        let context = SSHLaunchContext()
        let requestID = try context.configure(
            host: "camera.home",
            port: 22,
            username: "operator",
            password: "one-time-secret"
        )

        let request = try XCTUnwrap(
            context.consumeConnectionRequest(requestID: requestID)
        )
        XCTAssertEqual(request.id, requestID)
        XCTAssertEqual(request.host, "camera.home")
        XCTAssertEqual(request.port, 22)
        XCTAssertEqual(request.username, "operator")
        XCTAssertEqual(request.password, "one-time-secret")
        XCTAssertNil(context.consumeConnectionRequest(requestID: requestID))
        XCTAssertNil(context.presentation(for: requestID))
    }

    func testOlderWindowCannotClearNewerWindowsPendingCredentials() throws {
        let context = SSHLaunchContext()
        let olderRequestID = try context.configure(
            host: "older.home",
            port: 22,
            username: "older",
            password: "older-secret"
        )
        let newerRequestID = try context.configure(
            host: "newer.home",
            port: 2222,
            username: "newer",
            password: "newer-secret"
        )

        context.clearPendingCredentials(requestID: olderRequestID)

        XCTAssertNil(context.consumeConnectionRequest(requestID: olderRequestID))
        let newerRequest = try XCTUnwrap(
            context.consumeConnectionRequest(requestID: newerRequestID)
        )
        XCTAssertEqual(newerRequest.host, "newer.home")
        XCTAssertEqual(newerRequest.password, "newer-secret")
    }

    func testPresentationIsScopedToItsWindowToken() throws {
        let context = SSHLaunchContext()
        let firstRequestID = try context.configure(
            host: "first.home",
            port: 22,
            username: "first",
            password: "first-secret"
        )
        let secondRequestID = try context.configure(
            host: "second.home",
            port: 2222,
            username: "second",
            password: "second-secret"
        )

        XCTAssertEqual(
            context.presentation(for: firstRequestID),
            SSHLaunchPresentation(host: "first.home", port: 22, username: "first")
        )
        XCTAssertEqual(
            context.presentation(for: secondRequestID),
            SSHLaunchPresentation(host: "second.home", port: 2222, username: "second")
        )
    }

    func testUnconsumedPasswordExpires() async throws {
        let context = SSHLaunchContext(credentialLifetime: .milliseconds(10))
        let requestID = try context.configure(
            host: "192.168.1.60",
            port: 22,
            username: "viewer",
            password: "short-lived"
        )

        try await Task.sleep(for: .milliseconds(100))

        XCTAssertNil(context.consumeConnectionRequest(requestID: requestID))
    }

    func testCancelledOlderExpirationCannotClearNewerRequest() async throws {
        // The property needs the older request's (cancelled) expiration
        // deadline to pass while the newer request is live — but fixed sleeps
        // near a tight deadline are unreliable on a loaded host, where
        // Task.sleep can overshoot by seconds. Each attempt therefore measures
        // its own timing with a ContinuousClock and only evaluates the
        // assertion when the window provably held; an invalid window escalates
        // the lifetime instead of blaming the product for a scheduling stall.
        let clock = ContinuousClock()
        for lifetimeMilliseconds in [200, 1_000, 5_000] {
            let lifetime = Duration.milliseconds(lifetimeMilliseconds)
            let context = SSHLaunchContext(credentialLifetime: lifetime)
            let olderConfiguredAt = clock.now
            let olderRequestID = try context.configure(
                host: "older.home",
                port: 22,
                username: "older",
                password: "older-secret"
            )
            let olderDeadline = olderConfiguredAt.advanced(by: lifetime)

            // Consuming the older request cancels its expiration task. A nil
            // here means the host already stalled past the deadline — an
            // invalid window, not a product failure.
            guard context.consumeConnectionRequest(requestID: olderRequestID) != nil else {
                continue
            }

            // Let real time approach (but provably not reach) the older
            // deadline before the newer request exists, so the cancelled
            // task's fire moment lands while the newer request is live.
            try await Task.sleep(for: lifetime * 6 / 10)
            let newerConfiguredAt = clock.now
            guard newerConfiguredAt < olderDeadline else { continue }
            let newerRequestID = try context.configure(
                host: "newer.home",
                port: 22,
                username: "newer",
                password: "newer-secret"
            )
            let newerDeadline = newerConfiguredAt.advanced(by: lifetime)

            // Check halfway between the two deadlines: after the older one has
            // certainly passed, before the newer one certainly has not.
            let halfGap = (newerDeadline - olderDeadline) / 2
            try await Task.sleep(until: olderDeadline.advanced(by: halfGap), clock: clock)
            guard clock.now < newerDeadline else { continue }

            XCTAssertNotNil(
                context.consumeConnectionRequest(requestID: newerRequestID),
                "A cancelled older expiration task must not clear the newer request whose lifetime has not elapsed"
            )
            return
        }
        XCTFail(
            "Unable to establish a conclusive expiration timing window even with a 5s lifetime; the host is pathologically stalled."
        )
    }

    func testPendingCredentialQueueIsBoundedWithoutEvictingExistingRequests() throws {
        let context = SSHLaunchContext()
        var requestIDs: [UUID] = []
        for index in 0..<8 {
            requestIDs.append(
                try context.configure(
                    host: "camera-\(index).home",
                    port: 22,
                    username: "viewer",
                    password: "secret-\(index)"
                )
            )
        }

        XCTAssertThrowsError(
            try context.configure(
                host: "overflow.home",
                port: 22,
                username: "viewer",
                password: "must-not-evict"
            )
        ) { error in
            XCTAssertEqual(error as? SSHLaunchContextError, .tooManyPendingRequests)
        }
        for requestID in requestIDs {
            XCTAssertNotNil(context.consumeConnectionRequest(requestID: requestID))
        }
    }

    func testInvalidPortAndControlCharactersAreRejectedBeforeCredentialRetention() {
        let context = SSHLaunchContext()

        XCTAssertThrowsError(
            try context.configure(
                host: "camera.home\nredirect",
                port: 70_000,
                username: "viewer",
                password: "must-not-be-retained"
            )
        ) { error in
            XCTAssertEqual(error as? SSHLaunchContextError, .invalidRequest)
        }
    }
}
