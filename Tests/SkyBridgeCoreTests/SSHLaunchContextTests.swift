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
        let context = SSHLaunchContext(credentialLifetime: .milliseconds(80))
        let olderRequestID = try context.configure(
            host: "older.home",
            port: 22,
            username: "older",
            password: "older-secret"
        )
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNotNil(context.consumeConnectionRequest(requestID: olderRequestID))

        let newerRequestID = try context.configure(
            host: "newer.home",
            port: 22,
            username: "newer",
            password: "newer-secret"
        )
        try await Task.sleep(for: .milliseconds(60))

        XCTAssertNotNil(context.consumeConnectionRequest(requestID: newerRequestID))
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
