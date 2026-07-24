import XCTest
@testable import SkyBridgeCore

final class NetServiceResolvePermitWaiterTests: XCTestCase {
    func testCancellationBeforeContinuationInstallationFailsImmediately() async {
        let waiter = P2PDiscoveryService.NetServiceResolvePermitWaiter()
        XCTAssertTrue(waiter.cancel())

        do {
            try await withCheckedThrowingContinuation { continuation in
                XCTAssertFalse(waiter.install(continuation))
            }
            XCTFail("A pre-cancelled waiter must not acquire a permit")
        } catch is CancellationError {
            // Expected fail-closed cancellation.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCancellationAfterContinuationInstallationResumesExactlyOnce() async {
        let waiter = P2PDiscoveryService.NetServiceResolvePermitWaiter()

        do {
            try await withCheckedThrowingContinuation { continuation in
                XCTAssertTrue(waiter.install(continuation))
                XCTAssertTrue(waiter.cancel())
                XCTAssertFalse(waiter.cancel())
                XCTAssertFalse(waiter.resumeSuccess())
            }
            XCTFail("A cancelled waiter must not acquire a permit")
        } catch is CancellationError {
            // Expected fail-closed cancellation.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSuccessfulHandoffCannotBeOverwrittenByCancellation() async throws {
        let waiter = P2PDiscoveryService.NetServiceResolvePermitWaiter()

        try await withCheckedThrowingContinuation { continuation in
            XCTAssertTrue(waiter.install(continuation))
            XCTAssertTrue(waiter.resumeSuccess())
            XCTAssertFalse(waiter.cancel())
            XCTAssertFalse(waiter.resumeSuccess())
        }
    }

    func testNetServiceResolutionOwnsInFlightCancellationSynchronously() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let resolverStart = try XCTUnwrap(
            source.range(of: "private static func resolveNetServiceEndpointOnMain(")
        )
        let resolverEnd = try XCTUnwrap(
            source.range(
                of: "private func resolveViaNetServiceIfNeeded(",
                range: resolverStart.upperBound..<source.endIndex
            )
        )
        let resolver = String(source[resolverStart.lowerBound..<resolverEnd.lowerBound])

        XCTAssertTrue(resolver.contains("withTaskCancellationHandler"))
        XCTAssertTrue(resolver.contains("cancellationHandle.install(context)"))
        XCTAssertTrue(resolver.contains("cancellationHandle.cancel()"))
        XCTAssertTrue(source.contains("private final class NetServiceResolveCancellationHandle"))
        XCTAssertTrue(source.contains("func cancel() {\n            finish(.failure(CancellationError()))"))
    }

    func testSlowResolversRemainBoundedUnderConcurrentPressure() async throws {
        let limiter = P2PDiscoveryService.NetServiceResolveLimiter(limit: 3, maximumWaiters: 32)
        let probe = ResolverConcurrencyProbe()
        let resolverCount = 18

        let completed = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<resolverCount {
                group.addTask {
                    try await limiter.withPermit {
                        await probe.enter()
                        do {
                            try await Task.sleep(for: .milliseconds(40))
                        } catch {
                            await probe.leave()
                            throw error
                        }
                        await probe.leave()
                        return 1
                    }
                }
            }

            var total = 0
            for try await value in group {
                total += value
            }
            return total
        }

        let maximumObserved = await probe.maximumObserved()
        let finalSnapshot = await limiter.snapshot()
        XCTAssertEqual(completed, resolverCount)
        XCTAssertEqual(maximumObserved, 3)
        XCTAssertEqual(finalSnapshot, .init(inFlight: 0, waiting: 0))
    }

    func testQueuedSlowResolverCancellationReleasesPermitForNextWaiter() async throws {
        let limiter = P2PDiscoveryService.NetServiceResolveLimiter(limit: 1, maximumWaiters: 4)
        let blockerEntered = AsyncTestGate()
        let releaseBlocker = AsyncTestGate()

        let blocker = Task {
            try await limiter.withPermit {
                await blockerEntered.open()
                await releaseBlocker.wait()
                return 1
            }
        }
        await blockerEntered.wait()

        let cancelled = Task {
            try await limiter.withPermit { 2 }
        }
        try await waitForLimiter(limiter, waiting: 1)
        cancelled.cancel()

        do {
            _ = try await cancelled.value
            XCTFail("A queued resolver must not run after cancellation")
        } catch is CancellationError {
            // Expected fail-closed cancellation.
        } catch {
            XCTFail("Unexpected queued resolver error: \(error)")
        }

        let successor = Task {
            try await limiter.withPermit { 3 }
        }
        await releaseBlocker.open()
        let blockerValue = try await blocker.value
        let successorValue = try await successor.value
        XCTAssertEqual(blockerValue, 1)
        XCTAssertEqual(successorValue, 3)
        let finalSnapshot = await limiter.snapshot()
        XCTAssertEqual(finalSnapshot, .init(inFlight: 0, waiting: 0))
    }

    func testLimiterRejectsPressureBeyondBoundedQueue() async throws {
        let limiter = P2PDiscoveryService.NetServiceResolveLimiter(limit: 1, maximumWaiters: 2)
        let blockerEntered = AsyncTestGate()
        let releaseBlocker = AsyncTestGate()

        let blocker = Task {
            try await limiter.withPermit {
                await blockerEntered.open()
                await releaseBlocker.wait()
                return 1
            }
        }
        await blockerEntered.wait()

        let firstWaiter = Task { try await limiter.withPermit { 2 } }
        let secondWaiter = Task { try await limiter.withPermit { 3 } }
        try await waitForLimiter(limiter, waiting: 2)

        do {
            _ = try await limiter.withPermit { 4 }
            XCTFail("Resolver pressure beyond the queue bound must fail closed")
        } catch P2PDiscoveryService.NetServiceResolveLimiter.PermitError.queueFull {
            // Expected bounded rejection.
        } catch {
            XCTFail("Unexpected pressure error: \(error)")
        }

        await releaseBlocker.open()
        let blockerValue = try await blocker.value
        let firstValue = try await firstWaiter.value
        let secondValue = try await secondWaiter.value
        XCTAssertEqual(blockerValue, 1)
        let waiterValues = [firstValue, secondValue].sorted()
        XCTAssertEqual(waiterValues, [2, 3])
        let finalSnapshot = await limiter.snapshot()
        XCTAssertEqual(finalSnapshot, .init(inFlight: 0, waiting: 0))
    }

    func testSlowHydrationResultCannotOverwriteNewerGenerationOrStableIdentity() async throws {
        let route = P2PDiscoveryService.DiscoveryHydrationRoute(
            serviceName: "Mac",
            serviceType: "_skybridge._tcp",
            domain: "local."
        )
        var state = P2PDiscoveryService.DiscoveryHydrationGenerationState()
        let staleTicket = state.issue(
            route: route,
            stableDeviceIdentity: "id:device-a",
            serviceType: "_skybridge._tcp"
        )
        let slowResolver = Task {
            try await Task.sleep(for: .milliseconds(30))
            return staleTicket
        }

        state.invalidate(route: route)
        let currentTicket = state.issue(
            route: route,
            stableDeviceIdentity: "id:device-a",
            serviceType: "_skybridge._tcp"
        )
        let completedTicket = try await slowResolver.value

        XCTAssertFalse(
            state.accepts(
                completedTicket,
                currentStableDeviceIdentity: "id:device-a",
                hasService: true
            )
        )
        XCTAssertFalse(
            state.accepts(
                currentTicket,
                currentStableDeviceIdentity: "id:device-b",
                hasService: true
            )
        )
        XCTAssertTrue(
            state.accepts(
                currentTicket,
                currentStableDeviceIdentity: "id:device-a",
                hasService: true
            )
        )
    }

    func testHydrationCancellationAndLifecycleResetRejectOutstandingTickets() {
        let route = P2PDiscoveryService.DiscoveryHydrationRoute(
            serviceName: "iPad",
            serviceType: "_skybridge._tcp",
            domain: "local."
        )
        var state = P2PDiscoveryService.DiscoveryHydrationGenerationState()
        let cancelled = state.issue(
            route: route,
            stableDeviceIdentity: "id:device-a",
            serviceType: "_skybridge._tcp"
        )
        state.invalidate(route: route)
        XCTAssertFalse(
            state.accepts(
                cancelled,
                currentStableDeviceIdentity: "id:device-a",
                hasService: true
            )
        )

        let stopped = state.issue(
            route: route,
            stableDeviceIdentity: "id:device-a",
            serviceType: "_skybridge._tcp"
        )
        state.invalidateAll()
        XCTAssertFalse(
            state.accepts(
                stopped,
                currentStableDeviceIdentity: "id:device-a",
                hasService: true
            )
        )
    }

    func testDiscoverySourceUsesOnlyAsyncBoundedHydrationForDNS() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("getaddrinfo("))
        XCTAssertFalse(source.contains("extractNetworkInfo(from:"))
        XCTAssertFalse(source.contains("P2P_ResolveHost"))
        XCTAssertFalse(source.contains("P2P_ExtractNetworkAddrs"))
        XCTAssertTrue(source.contains("private nonisolated static func numericNetworkAddresses("))
        XCTAssertTrue(source.contains("netServiceResolveLimiter.withPermit"))
        XCTAssertTrue(source.contains("discoveryHydrationGenerationState.accepts("))
        XCTAssertTrue(source.contains("currentHydrationDeviceIndex(for: ticket)"))
        XCTAssertTrue(source.contains("replaceExistingHydration: true"))
        XCTAssertTrue(source.contains("replaceExisting: replaceExistingHydration"))
        XCTAssertTrue(source.contains("invalidateDiscoveryHydration(for: result.endpoint)"))

        let upsertStart = try XCTUnwrap(source.range(of: "private func upsertDiscoveredDevice("))
        let removalStart = try XCTUnwrap(
            source.range(
                of: "private func removeDiscoveredDevice(",
                range: upsertStart.upperBound..<source.endIndex
            )
        )
        let upsertBody = String(source[upsertStart.lowerBound..<removalStart.lowerBound])
        XCTAssertFalse(upsertBody.contains("Task.detached"))
        XCTAssertFalse(upsertBody.contains("NetService("))
    }

    private func waitForLimiter(
        _ limiter: P2PDiscoveryService.NetServiceResolveLimiter,
        waiting expectedWaiting: Int
    ) async throws {
        for _ in 0..<200 {
            let snapshot = await limiter.snapshot()
            if snapshot.waiting == expectedWaiting {
                return
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        let snapshot = await limiter.snapshot()
        XCTFail("Timed out waiting for resolver queue depth \(expectedWaiting); got \(snapshot.waiting)")
        throw ResolverTestError.timedOut
    }
}

private enum ResolverTestError: Error {
    case timedOut
}

private actor AsyncTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        pending.forEach { $0.resume() }
    }
}

private actor ResolverConcurrencyProbe {
    private var active = 0
    private var maximum = 0

    func enter() {
        active += 1
        maximum = max(maximum, active)
    }

    func leave() {
        active -= 1
    }

    func maximumObserved() -> Int {
        maximum
    }
}
