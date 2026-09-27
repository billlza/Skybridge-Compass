#if os(macOS)
import Network
import XCTest
import os
@testable import SkyBridgeCore

@MainActor
final class RemoteControlConnectionStartTests: XCTestCase {
    func testPreCancelledAttemptClosesWithoutStarting() async {
        let transport = StartTransport()
        let operation = DiscoveryConnectionStartOperation(transport: transport)
        let completed = expectation(description: "Cancelled attempt completes once")
        completed.assertForOverFulfill = true
        let attempt = Task { @MainActor in
            defer { completed.fulfill() }
            withUnsafeCurrentTask { $0?.cancel() }
            try await operation.run()
        }
        await assertCancelled(attempt)
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(transport.startCount, 0)
        assertRetiredOnce(transport)
    }

    func testRunningCancellationRetiresOnceDespiteLateCallbacks() async {
        let started = expectation(description: "Transport started")
        let transport = StartTransport(onStart: { started.fulfill() })
        let operation = DiscoveryConnectionStartOperation(transport: transport)
        let attempt = Task { @MainActor in try await operation.run() }
        await fulfillment(of: [started], timeout: 2)
        attempt.cancel()
        transport.emitRetainedState(.ready)
        transport.emitRetainedState(.failed(.posix(.ECONNRESET)))
        operation.timeOut()
        await assertCancelled(attempt)
        assertRetiredOnce(transport)
    }

    func testTimeoutRetainsItsErrorAndRetiresOnce() async {
        let transport = StartTransport()
        let operation = DiscoveryConnectionStartOperation(transport: transport, timeout: .milliseconds(40))
        do {
            try await operation.run()
            XCTFail("An unready transport must time out")
        } catch {
            guard case DeviceDiscoveryError.connectionTimeout = error else {
                return XCTFail("Unexpected timeout result: \(error)")
            }
        }
        transport.emitRetainedState(.ready)
        transport.emitRetainedState(.cancelled)
        operation.timeOut()
        operation.cancel()
        XCTAssertEqual(transport.startCount, 1)
        assertRetiredOnce(transport)
    }

    func testCancellationAfterReadyBeforeActorResumesStillOwnsTransport() async {
        let started = expectation(description: "Transport started")
        let transport = StartTransport(onStart: { started.fulfill() })
        let operation = DiscoveryConnectionStartOperation(transport: transport)
        let attempt = Task { @MainActor in try await operation.run() }
        await fulfillment(of: [started], timeout: 2)
        // No suspension here: run() cannot resume on MainActor between these
        // events, even though its readiness continuation has been resumed.
        transport.emitRetainedState(.ready)
        attempt.cancel()
        await assertCancelled(attempt)
        assertRetiredOnce(transport)
    }

    func testConnectionFailureAfterReadyBeforeTransferRemainsObservable() async {
        let started = expectation(description: "Transport started")
        let transport = StartTransport(onStart: { started.fulfill() })
        let operation = DiscoveryConnectionStartOperation(transport: transport)
        let attempt = Task { @MainActor in try await operation.run() }
        await fulfillment(of: [started], timeout: 2)
        transport.emitRetainedState(.ready)
        transport.emitRetainedState(.failed(.posix(.ECONNRESET)))
        do {
            try await attempt.value
            XCTFail("A ready connection that fails before transfer must not escape")
        } catch {
            XCTAssertEqual(error as? NWError, .posix(.ECONNRESET))
        }
        assertRetiredOnce(transport)
    }

    func testFirstFailureIsNotReplacedByLaterCancellation() async {
        let started = expectation(description: "Transport started")
        let transport = StartTransport(onStart: { started.fulfill() })
        let operation = DiscoveryConnectionStartOperation(transport: transport)
        let attempt = Task { @MainActor in try await operation.run() }
        await fulfillment(of: [started], timeout: 2)
        transport.emitRetainedState(.failed(.posix(.ECONNREFUSED)))
        attempt.cancel()
        do {
            try await attempt.value
            XCTFail("Expected the first transport failure")
        } catch {
            XCTAssertEqual(error as? NWError, .posix(.ECONNREFUSED))
        }
        assertRetiredOnce(transport)
    }

    func testCancellationDuringSetupNeverStartsAnAlreadyCancelledTransport() async {
        let installing = expectation(description: "State handler installation entered")
        let releaseInstallation = DispatchSemaphore(value: 0)
        let transport = StartTransport(onInstall: {
            installing.fulfill()
            releaseInstallation.wait()
        })
        let operation = DiscoveryConnectionStartOperation(transport: transport)
        let attempt = Task { @MainActor in try await operation.run() }
        await fulfillment(of: [installing], timeout: 2)
        attempt.cancel()
        releaseInstallation.signal()
        await assertCancelled(attempt)
        XCTAssertEqual(transport.events, ["start", "cancel"])
        assertRetiredOnce(transport)
    }

    func testTransferredTransportIgnoresLateTimeoutFailureAndCancellation() async throws {
        let cancelled = expectation(description: "Transferred transport must stay open")
        cancelled.isInverted = true
        let transport = StartTransport(readyOnStart: true, onCancel: { cancelled.fulfill() })
        let operation = DiscoveryConnectionStartOperation(transport: transport)
        let completed = expectation(description: "Ready attempt completes once")
        completed.assertForOverFulfill = true
        let attempt = Task { @MainActor in
            defer { completed.fulfill() }
            try await operation.run()
        }
        try await attempt.value
        operation.timeOut()
        transport.emitRetainedState(.ready)
        transport.emitRetainedState(.failed(.posix(.ECONNRESET)))
        XCTAssertFalse(operation.cancel(), "A cache now owns the transferred socket's retirement")
        attempt.cancel()
        await fulfillment(of: [completed, cancelled], timeout: 0.05)
        XCTAssertEqual(transport.startCount, 1)
        XCTAssertEqual(transport.cancelCount, 0)
        XCTAssertEqual(transport.clearHandlerCount, 1)
        XCTAssertFalse(transport.hasHandler)
    }

    func testConcurrentReadyAndCancellationCompleteAndRetireOnce() async {
        for _ in 0..<12 {
            let started = expectation(description: "Transport started")
            let transport = StartTransport(onStart: { started.fulfill() })
            let operation = DiscoveryConnectionStartOperation(transport: transport)
            let attempt = Task { @MainActor in try await operation.run() }
            await fulfillment(of: [started], timeout: 2)
            // Both callbacks finish while the actor remains occupied, so even
            // a readiness winner has not transferred ownership to the caller.
            DispatchQueue.concurrentPerform(iterations: 2) { index in
                if index == 0 { transport.emitRetainedState(.ready) }
                else { operation.cancel() }
            }
            await assertCancelled(attempt)
            assertRetiredOnce(transport)
        }
    }

    private func assertCancelled(_ attempt: Task<Void, Error>, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await attempt.value
            XCTFail("Expected cancellation before transfer", file: file, line: line)
        } catch {
            XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)", file: file, line: line)
        }
    }

    private func assertRetiredOnce(_ transport: StartTransport, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(transport.cancelCount, 1, file: file, line: line)
        XCTAssertEqual(transport.clearHandlerCount, 1, file: file, line: line)
        XCTAssertFalse(transport.hasHandler, file: file, line: line)
    }
}

private final class StartTransport: DiscoveryConnectionStartTransport, @unchecked Sendable {
    private struct State {
        var handler: (@Sendable (NWConnection.State) -> Void)?
        var retainedHandler: (@Sendable (NWConnection.State) -> Void)?
        var startCount = 0
        var cancelCount = 0
        var clearHandlerCount = 0
        var events: [String] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let readyOnStart: Bool
    private let onStart: @Sendable () -> Void
    private let onInstall: @Sendable () -> Void
    private let onCancel: @Sendable () -> Void

    init(
        readyOnStart: Bool = false,
        onStart: @escaping @Sendable () -> Void = {},
        onInstall: @escaping @Sendable () -> Void = {},
        onCancel: @escaping @Sendable () -> Void = {}
    ) {
        self.readyOnStart = readyOnStart
        self.onStart = onStart
        self.onInstall = onInstall
        self.onCancel = onCancel
    }

    var startCount: Int { state.withLock { $0.startCount } }
    var cancelCount: Int { state.withLock { $0.cancelCount } }
    var clearHandlerCount: Int { state.withLock { $0.clearHandlerCount } }
    var hasHandler: Bool { state.withLock { $0.handler != nil } }
    var events: [String] { state.withLock { $0.events } }

    func setStateUpdateHandler(_ handler: @escaping @Sendable (NWConnection.State) -> Void) {
        state.withLock {
            $0.handler = handler
            $0.retainedHandler = handler
        }
        onInstall()
    }

    func clearStateUpdateHandler() {
        state.withLock {
            $0.handler = nil
            $0.clearHandlerCount += 1
        }
    }

    func start() {
        state.withLock {
            $0.startCount += 1
            $0.events.append("start")
        }
        onStart()
        if readyOnStart { emitRetainedState(.ready) }
    }

    func cancel() {
        state.withLock {
            $0.cancelCount += 1
            $0.events.append("cancel")
        }
        onCancel()
        // Exercise adapters that synchronously deliver their terminal callback,
        // including one already captured before handler removal.
        emitRetainedState(.cancelled)
    }

    func emitRetainedState(_ value: NWConnection.State) {
        let handler = state.withLock { $0.retainedHandler }
        handler?(value)
    }
}
#endif
