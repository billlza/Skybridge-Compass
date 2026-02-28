import XCTest
@testable import SkyBridgeCompass_iOS

@available(iOS 17.0, *)
final class WebRTCSignalingFaultInjectionTests: XCTestCase {
    func testInvalidWebSocketURLFailsFastWithoutRetry() async {
        await Task { @MainActor in
            let probe = RetryProbe()
            let controller = SignalingRetryController(
                retryDelay: .milliseconds(10),
                attemptTimeout: .milliseconds(50),
                sleep: { duration in
                    await probe.recordSleep(duration)
                }
            )

            XCTAssertNil(SignalingRetryController.validatedWebSocketURL("http://example.com/ws"))
            XCTAssertNil(SignalingRetryController.validatedWebSocketURL("wss://"))
            XCTAssertNotNil(SignalingRetryController.validatedWebSocketURL("wss://example.com/ws"))

            do {
                try await controller.sendWithRetry(
                    retries: 3,
                    reconnectIfNeeded: {
                        await probe.recordReconnect()
                    },
                    send: {
                        throw SignalingRetryControllerError.invalidWebSocketURL("wss://")
                    }
                )
                XCTFail("Expected invalid URL error")
            } catch let error as SignalingRetryControllerError {
                XCTAssertEqual(error, .invalidWebSocketURL("wss://"))
            } catch {
                XCTFail("Unexpected error: \(error)")
            }

            let reconnectCount = await probe.reconnectCount()
            let sleepCount = await probe.sleepCount()
            XCTAssertEqual(reconnectCount, 0)
            XCTAssertEqual(sleepCount, 0)
        }.value
    }

    func testReconnectBackoffAfterNotConnectedThenSuccess() async throws {
        try await Task { @MainActor in
            let probe = RetryProbe()
            let controller = SignalingRetryController(
                retryDelay: .milliseconds(10),
                attemptTimeout: .seconds(1),
                sleep: { duration in
                    await probe.recordSleep(duration)
                }
            )

            try await controller.sendWithRetry(
                retries: 2,
                reconnectIfNeeded: {
                    await probe.recordReconnect()
                },
                send: {
                    let attempt = await probe.nextAttempt()
                    if attempt == 1 {
                        throw WebSocketSignalingClient.SignalingError.notConnected
                    }
                }
            )

            let attemptCount = await probe.attemptCount()
            let reconnectCount = await probe.reconnectCount()
            let sleepCount = await probe.sleepCount()
            XCTAssertEqual(attemptCount, 2)
            XCTAssertEqual(reconnectCount, 1)
            XCTAssertEqual(sleepCount, 1)
        }.value
    }

    func testTimeoutCancelsHangingSendAttempt() async {
        await Task { @MainActor in
            let cancelFlag = CancellationFlag()
            let controller = SignalingRetryController(
                retryDelay: .milliseconds(10),
                attemptTimeout: .milliseconds(40),
                sleep: { _ in }
            )

            do {
                try await controller.sendWithRetry(
                    retries: 0,
                    reconnectIfNeeded: {},
                    send: {
                        try await withTaskCancellationHandler {
                            try await Task.sleep(for: .seconds(2))
                        } onCancel: {
                            cancelFlag.markCancelled()
                        }
                    }
                )
                XCTFail("Expected timeout error")
            } catch let error as SignalingRetryControllerError {
                XCTAssertEqual(error, .attemptTimedOut)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }

            try? await Task.sleep(for: .milliseconds(50))
            XCTAssertTrue(cancelFlag.isCancelled)
        }.value
    }
}

@available(iOS 17.0, *)
private actor RetryProbe {
    private var attempts: Int = 0
    private var reconnects: Int = 0
    private var sleeps: Int = 0

    func nextAttempt() -> Int {
        attempts += 1
        return attempts
    }

    func recordReconnect() {
        reconnects += 1
    }

    func recordSleep(_ duration: Duration) {
        _ = duration
        sleeps += 1
    }

    func attemptCount() -> Int { attempts }
    func reconnectCount() -> Int { reconnects }
    func sleepCount() -> Int { sleeps }
}

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled: Bool = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func markCancelled() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
