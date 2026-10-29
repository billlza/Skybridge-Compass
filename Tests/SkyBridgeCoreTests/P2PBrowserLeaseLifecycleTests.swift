import XCTest
@testable import SkyBridgeCore

final class P2PBrowserLeaseLifecycleTests: XCTestCase {
    private let controlServiceType = "_skybridge._tcp"

    func testOldGenerationCallbacksLoseAuthorityAfterBrowserReplacement() throws {
        var state = P2PBrowserLeaseLifecycleState()
        let oldLease = try XCTUnwrap(
            state.beginScanning(serviceTypes: [controlServiceType]).first
        )
        let replacementLease = try XCTUnwrap(
            state.beginScanning(serviceTypes: [controlServiceType]).first
        )

        XCTAssertFalse(state.accepts(oldLease))
        XCTAssertEqual(state.terminalAction(for: oldLease), .ignored)
        XCTAssertTrue(state.accepts(replacementLease))
        XCTAssertNotEqual(oldLease.ownerToken, replacementLease.ownerToken)
        XCTAssertNotEqual(oldLease.lifecycleToken, replacementLease.lifecycleToken)
    }

    func testRepeatedFailuresKeepOneSupervisedRestartWithCappedBackoff() throws {
        var state = P2PBrowserLeaseLifecycleState()
        var lease = try XCTUnwrap(
            state.beginScanning(serviceTypes: [controlServiceType]).first
        )
        let initialLease = lease
        var delays: [Duration] = []

        for _ in 0..<12 {
            let ticket: P2PBrowserRestartTicket
            switch state.terminalAction(for: lease) {
            case .scheduleRestart(let scheduled, let delay):
                ticket = scheduled
                delays.append(delay)
            case .ignored:
                return XCTFail("A current failed browser must always retain desired-state supervision")
            }
            XCTAssertFalse(state.accepts(lease))
            XCTAssertEqual(state.pendingRestartsByServiceType.count, 1)
            XCTAssertEqual(
                state.terminalAction(for: lease),
                .ignored,
                "A duplicate terminal callback must not enqueue a second restart"
            )
            XCTAssertEqual(state.pendingRestartsByServiceType.count, 1)

            lease = try XCTUnwrap(state.activateRestart(ticket))
            XCTAssertTrue(state.accepts(lease))
            XCTAssertTrue(state.pendingRestartsByServiceType.isEmpty)
        }

        XCTAssertNotEqual(lease.ownerToken, initialLease.ownerToken)
        XCTAssertTrue(delays.allSatisfy { $0 <= P2PBrowserLeaseLifecycleState.maximumRestartDelay })
        let cappedDelay = try XCTUnwrap(delays.last)
        XCTAssertEqual(
            Array(delays.suffix(4)),
            Array(repeating: cappedDelay, count: 4),
            "Backoff must remain capped instead of growing or exhausting"
        )
    }

    func testReadyResetsConsecutiveFailureBackoff() throws {
        var state = P2PBrowserLeaseLifecycleState()
        var lease = try XCTUnwrap(
            state.beginScanning(serviceTypes: [controlServiceType]).first
        )

        for _ in 0..<4 {
            guard case .scheduleRestart(let ticket, _) = state.terminalAction(for: lease) else {
                return XCTFail("Expected supervised restart")
            }
            lease = try XCTUnwrap(state.activateRestart(ticket))
        }
        XCTAssertTrue(state.markReady(lease))

        guard case .scheduleRestart(let ticket, let resetDelay) = state.terminalAction(for: lease) else {
            return XCTFail("Expected restart after a post-ready failure")
        }
        XCTAssertEqual(ticket.restartAttempt, 1)
        XCTAssertEqual(
            resetDelay,
            P2PBrowserLeaseLifecycleState.restartDelay(
                serviceType: controlServiceType,
                scanGeneration: ticket.scanGeneration,
                attempt: 1
            )
        )
    }

    func testStopInvalidatesPendingRestartAndCannotRecreateBrowser() throws {
        var state = P2PBrowserLeaseLifecycleState()
        let lease = try XCTUnwrap(
            state.beginScanning(serviceTypes: [controlServiceType]).first
        )
        let ticket: P2PBrowserRestartTicket
        switch state.terminalAction(for: lease) {
        case .scheduleRestart(let scheduled, _):
            ticket = scheduled
        case .ignored:
            return XCTFail("Expected a pending restart before stop")
        }

        state.stopScanning()

        XCTAssertNil(state.activateRestart(ticket))
        XCTAssertFalse(state.isScanning)
        XCTAssertTrue(state.leasesByServiceType.isEmpty)
        XCTAssertTrue(state.pendingRestartsByServiceType.isEmpty)
    }

    func testConcurrentRefreshesLeaveExactlyOneAcceptedGeneration() async throws {
        let harness = BrowserRefreshHarness(serviceType: controlServiceType)
        let initialLease = try await harness.refresh()

        async let firstRefresh = harness.refresh()
        async let secondRefresh = harness.refresh()
        let refreshedLeases = try await [firstRefresh, secondRefresh]
        let accepted = await harness.accepted(refreshedLeases)
        let initialLeaseIsAccepted = await harness.accepts(initialLease)

        XCTAssertFalse(initialLeaseIsAccepted)
        XCTAssertEqual(accepted.filter { $0 }.count, 1)
        XCTAssertEqual(Set(refreshedLeases.map(\.scanGeneration)).count, 2)
    }

    func testNewFullSnapshotSupersedesReentrantCallbackWithinSameLease() throws {
        var state = P2PBrowserLeaseLifecycleState()
        let lease = try XCTUnwrap(
            state.beginScanning(serviceTypes: [controlServiceType]).first
        )
        let oldCallback = try XCTUnwrap(state.issueResultCallback(for: lease))
        let currentCallback = try XCTUnwrap(state.issueResultCallback(for: lease))

        XCTAssertFalse(state.accepts(oldCallback))
        XCTAssertTrue(state.accepts(currentCallback))
    }

    func testRemovalIsIgnoredWhileEndpointRemainsInCurrentSnapshot() {
        let currentEndpoints: Set = ["endpoint-a", "endpoint-b"]

        XCTAssertFalse(
            P2PBrowserResultSnapshotPolicy.shouldApplyRemoval(
                "endpoint-a",
                currentEndpoints: currentEndpoints
            )
        )
        XCTAssertTrue(
            P2PBrowserResultSnapshotPolicy.shouldApplyRemoval(
                "endpoint-c",
                currentEndpoints: currentEndpoints
            )
        )
    }

    func testProductionCallbacksValidateLeaseBeforeAndAfterSuspension() throws {
        let source = try repositorySource("Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift")

        XCTAssertTrue(source.contains("handleBrowserStateUpdate(state, lease: lease)"))
        XCTAssertTrue(source.contains("changes: changes,\n                    lease: lease"))
        XCTAssertTrue(source.contains("guard browserLifecycleState.accepts(lease) else"))
        XCTAssertTrue(source.contains("handleBrowserTerminalState(lease)"))
        XCTAssertTrue(source.contains("let selfIdentity = await SelfIdentityProvider.shared.presentationSnapshot()\n        guard acceptsBrowserResultCallback(browserResultCallback) else"))
        XCTAssertTrue(source.contains("browserLifecycleState.issueResultCallback(for: lease)"))
        XCTAssertTrue(source.contains("currentEndpoints: currentSnapshot.endpoints"))
        XCTAssertTrue(source.contains("browserLifecycleState.stopScanning()"))
    }

    private func repositorySource(_ relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}

private actor BrowserRefreshHarness {
    private let serviceType: String
    private var state = P2PBrowserLeaseLifecycleState()

    init(serviceType: String) {
        self.serviceType = serviceType
    }

    func refresh() throws -> P2PBrowserLeaseIdentity {
        guard let lease = state.beginScanning(serviceTypes: [serviceType]).first else {
            throw BrowserRefreshHarnessError.missingLease
        }
        return lease
    }

    func accepts(_ lease: P2PBrowserLeaseIdentity) -> Bool {
        state.accepts(lease)
    }

    func accepted(_ leases: [P2PBrowserLeaseIdentity]) -> [Bool] {
        leases.map { state.accepts($0) }
    }
}

private enum BrowserRefreshHarnessError: Error {
    case missingLease
}
