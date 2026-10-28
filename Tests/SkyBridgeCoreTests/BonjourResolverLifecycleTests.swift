import Foundation
import XCTest
@testable import SkyBridgeCore

final class BonjourResolverLifecycleTests: XCTestCase {
    @MainActor
    func testTimeoutDisposesServiceOnMainRunLoop() async throws {
        let service = TrackingNetService()
        defer { service.dispatchedDelegate = nil }

        do {
            _ = try await DeviceDiscoveryManagerOptimized.resolveBonjourServiceOnMain(
                service: service, timeoutSeconds: 0.01
            )
            XCTFail("An unresolved service must report its timeout")
        } catch DeviceDiscoveryManagerOptimized.BonjourResolveError.timeout {
            // The unresolved service has one explicit terminal outcome.
        }

        await assertDisposedOnceOnMain(service)
    }

    @MainActor
    func testSuccessfulCallbackPreservesResultAndDisposesService() async throws {
        let service = TrackingNetService()
        defer { service.dispatchedDelegate = nil }

        let resolution = Task { @MainActor in
            try await DeviceDiscoveryManagerOptimized.resolveBonjourServiceOnMain(
                service: service, timeoutSeconds: 1
            )
        }
        await assertResolutionStarted(service)
        let callback = try XCTUnwrap(service.dispatchedDelegate)
        callback.netServiceDidResolveAddress?(service)
        let result = try await resolution.value

        XCTAssertEqual(result.port, 58820)
        XCTAssertEqual(result.rawTXTData, service.expectedTXTData)
        await assertDisposedOnceOnMain(service)
    }

    @MainActor
    func testFailedCallbackPreservesFailureAndDisposesService() async throws {
        let service = TrackingNetService()
        defer { service.dispatchedDelegate = nil }

        let resolution = Task { @MainActor in
            try await DeviceDiscoveryManagerOptimized.resolveBonjourServiceOnMain(
                service: service, timeoutSeconds: 1
            )
        }
        await assertResolutionStarted(service)
        let callback = try XCTUnwrap(service.dispatchedDelegate)
        callback.netService?(service, didNotResolve: ["error": NSNumber(value: 42)])
        do {
            _ = try await resolution.value
            XCTFail("A native resolution failure must not become an empty success")
        } catch DeviceDiscoveryManagerOptimized.BonjourResolveError.failed(let details) {
            XCTAssertEqual(details["error"], NSNumber(value: 42))
        }

        await assertDisposedOnceOnMain(service)
    }

    @MainActor
    func testLateCallbacksAfterTimeoutDoNotCompleteOrDisposeAgain() async throws {
        let service = TrackingNetService()
        defer { service.dispatchedDelegate = nil }

        do {
            _ = try await DeviceDiscoveryManagerOptimized.resolveBonjourServiceOnMain(
                service: service, timeoutSeconds: 0.01
            )
            XCTFail("The timeout must win before the delayed native callbacks")
        } catch DeviceDiscoveryManagerOptimized.BonjourResolveError.timeout {
            // Retain the already-dispatched delegate to model a late callback.
        }

        await assertDisposedOnceOnMain(service)
        let callback = try XCTUnwrap(service.dispatchedDelegate)
        callback.netServiceDidResolveAddress?(service)
        callback.netService?(service, didNotResolve: ["error": NSNumber(value: 42)])
        service.dispatchedDelegate = nil
        await Task.yield()

        XCTAssertEqual(service.teardown.stopCount, 1)
        XCTAssertEqual(service.teardown.removeCount, 1)
        XCTAssertNil(service.delegate)
    }

    @MainActor
    func testCompletedTimeoutReleasesItsServiceAndDelegate() async throws {
        let didDeallocate = XCTestExpectation(description: "Resolved service ownership released")
        var service: TrackingNetService? = TrackingNetService(didDeallocate: didDeallocate)
        do {
            let active = try XCTUnwrap(service)
            defer { active.dispatchedDelegate = nil }
            do {
                _ = try await DeviceDiscoveryManagerOptimized.resolveBonjourServiceOnMain(
                    service: active, timeoutSeconds: 0.01
                )
                XCTFail("An unresolved service must report its timeout")
            } catch DeviceDiscoveryManagerOptimized.BonjourResolveError.timeout {
                // Cleanup must also release the context's retained service.
            }
            await assertDisposedOnceOnMain(active)
        }
        service = nil

        let released = await XCTWaiter.fulfillment(of: [didDeallocate], timeout: 2)
        XCTAssertEqual(released, .completed, "A completed resolver must not retain itself and its service")
    }

    @MainActor
    private func assertResolutionStarted(_ service: TrackingNetService) async {
        let completion = await XCTWaiter.fulfillment(of: [service.didStart], timeout: 2)
        XCTAssertEqual(completion, .completed, "The service must start before a native callback is delivered")
    }

    @MainActor
    private func assertDisposedOnceOnMain(_ service: TrackingNetService) async {
        let completion = await XCTWaiter.fulfillment(of: [service.didRemove], timeout: 2)
        XCTAssertEqual(completion, .completed, "The resolver must retire its scheduled service")
        let teardown = service.teardown
        XCTAssertTrue(teardown.allOperationsOnMainThread, "NetService teardown raced its main-run-loop callbacks")
        XCTAssertTrue(teardown.removedFromMainCommonMode)
        XCTAssertEqual(teardown.stopCount, 1)
        XCTAssertEqual(teardown.removeCount, 1)
        XCTAssertNil(service.delegate)
    }
}

/// Uses the real resolver and its timeout task, without advertising or resolving
/// a LAN service. Native callbacks are delivered through the actual delegate.
private final class TrackingNetService: NetService, @unchecked Sendable {
    struct Teardown {
        var allOperationsOnMainThread = true
        var removedFromMainCommonMode = false
        var stopCount = 0
        var removeCount = 0
    }

    let didStart = XCTestExpectation(description: "NetService resolution started")
    let didRemove = XCTestExpectation(description: "NetService removed from its run loop")
    let expectedTXTData = NetService.data(fromTXTRecord: ["id": Data("lifecycle-validation".utf8)])
    var dispatchedDelegate: (any NetServiceDelegate)?
    private let didDeallocate: XCTestExpectation?
    private let stateLock = NSLock()
    private var state = Teardown()

    init(didDeallocate: XCTestExpectation? = nil) {
        self.didDeallocate = didDeallocate
        super.init(domain: "local.", type: "_skybridge._tcp.", name: "lifecycle-validation", port: 58820)
    }

    deinit { didDeallocate?.fulfill() }

    var teardown: Teardown { stateLock.withLock { state } }
    override var port: Int { 58820 }
    override func txtRecordData() -> Data? { expectedTXTData }
    override func schedule(in runLoop: RunLoop, forMode mode: RunLoop.Mode) {}

    override func resolve(withTimeout timeout: TimeInterval) {
        dispatchedDelegate = delegate
        didStart.fulfill()
    }

    override func stop() {
        stateLock.withLock {
            state.stopCount += 1
            state.allOperationsOnMainThread = state.allOperationsOnMainThread && Thread.isMainThread
        }
    }

    override func remove(from runLoop: RunLoop, forMode mode: RunLoop.Mode) {
        stateLock.withLock {
            state.removeCount += 1
            state.allOperationsOnMainThread = state.allOperationsOnMainThread && Thread.isMainThread
            state.removedFromMainCommonMode = runLoop === RunLoop.main && mode == .common
        }
        didRemove.fulfill()
    }
}
