#if os(macOS)
import Combine
import Network
import SkyBridgeProtocolCore
import XCTest
@testable import SkyBridgeCore

@MainActor
final class ControlledHostWorkspaceTests: XCTestCase {
    private enum Failure: Error, LocalizedError {
        case rejected
        var errorDescription: String? { "Test host rejected the stream configuration" }
    }

    private enum Action: Equatable {
        case start(String)
        case tier(String, ControlledHostSessionPolicy.StreamTier)
        case key(String, KeyboardEventType, Int)
        case mouse(String, MouseEventType)
        case stop(String)
    }

    @MainActor
    private final class Journal { var actions: [Action] = [] }

    @MainActor
    private final class Gate {
        let entered = XCTestExpectation(description: "Operation entered its controlled suspension")
        private var continuation: CheckedContinuation<Void, Never>?
        private var opened = false

        func wait() async {
            guard !opened else { return }
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                entered.fulfill()
            }
        }

        func open() {
            opened = true
            continuation?.resume()
            continuation = nil
        }
    }

    @MainActor
    private final class Engine: ControlledHostSessionEngine {
        let name: String
        let journal: Journal
        let errors = CurrentValueSubject<String?, Never>(nil)
        let inputAccess = CurrentValueSubject<RemoteControlAccessTracker, Never>(RemoteControlAccessTracker())
        let started = XCTestExpectation(description: "Engine started its exact session")
        var startGate: Gate?
        var demotionGate: Gate?
        var promotionGate: Gate?
        var rejectedTier: ControlledHostSessionPolicy.StreamTier?
        var exposedManager: RemoteControlManager?
        var startCount = 0
        var stopCount = 0
        var sentInputLeases: [UUID?] = []
        var keySendGate: Gate?
        var blockedKeyCode: Int?
        var onKeySendCompleted: ((Int) -> Void)?

        init(_ name: String, journal: Journal) {
            self.name = name
            self.journal = journal
        }

        var remoteControlManager: RemoteControlManager? { exposedManager }
        var failurePublisher: AnyPublisher<String?, Never> { errors.eraseToAnyPublisher() }
        var viewerInputAccess: RemoteControlAccessTracker { inputAccess.value }
        var inputAccessPublisher: AnyPublisher<RemoteControlAccessTracker, Never> { inputAccess.eraseToAnyPublisher() }

        func updateAccess(_ access: RemoteControlAccess?) throws {
            var tracker = inputAccess.value
            try tracker.accept(access)
            inputAccess.send(tracker)
        }

        func startControlledHostSession(device: DiscoveredDevice, connection: NWConnection) async throws -> String {
            startCount += 1
            journal.actions.append(.start(name))
            started.fulfill()
            if let startGate { await startGate.wait() }
            if !viewerInputAccess.hasAcknowledgement { try updateAccess(nil) }
            return RemoteControlManager.controlPeerIdentifier(for: device)
        }

        func setControlledHostStreamTier(_ tier: ControlledHostSessionPolicy.StreamTier, deviceId: String) async throws {
            journal.actions.append(.tier(name, tier))
            if tier == .background, let demotionGate { await demotionGate.wait() }
            if tier == .focused, let promotionGate { await promotionGate.wait() }
            if tier == rejectedTier { throw Failure.rejected }
        }

        func sendMouseEvent(_ event: RemoteMouseEvent, to deviceId: String, inputControlLease: UUID?) async throws {
            sentInputLeases.append(inputControlLease)
            journal.actions.append(.mouse(deviceId, event.type))
        }

        func sendKeyboardEvent(_ event: RemoteKeyboardEvent, to deviceId: String, inputControlLease: UUID?) async throws {
            sentInputLeases.append(inputControlLease)
            journal.actions.append(.key(deviceId, event.type, event.keyCode))
            if event.keyCode == blockedKeyCode, let keySendGate { await keySendGate.wait() }
            onKeySendCompleted?(event.keyCode)
        }

        func stopControlling(deviceId: String) {
            stopCount += 1
            journal.actions.append(.stop(name))
        }
    }

    private func device(_ id: String) -> DiscoveredDevice {
        DiscoveredDevice(
            id: UUID(), name: "Host \(id)", ipv4: "127.0.0.1", ipv6: nil,
            services: [], portMap: [:], deviceId: id
        )
    }

    private func connection(onAbandon: @escaping @MainActor () -> Void = {}) -> ControlledHostConnection {
        ControlledHostConnection(
            connection: NWConnection(host: "127.0.0.1", port: 9, using: .tcp),
            onAbandon: onAbandon
        )
    }

    private func workspace(_ engines: [Engine], limit: Int = 2) -> ControlledHostWorkspace {
        var remaining = engines
        return ControlledHostWorkspace(concurrentHostLimit: limit) { remaining.removeFirst() }
    }

    func testObserverRemainsConnectedAndNewGrantEnablesInputWithoutReconnect() async throws {
        let journal = Journal()
        let engine = Engine("a", journal: journal)
        try engine.updateAccess(RemoteControlAccess(revision: 1, role: .observer, lease: nil))
        let workspace = workspace([engine])
        defer { workspace.stopAll() }
        try await workspace.connect(to: device("a")) { self.connection() }
        XCTAssertEqual(workspace.sessions.map(\.state), [.connected])
        XCTAssertEqual(workspace.focusedSessionId, "a")
        XCTAssertFalse(workspace.canSendInput(to: "a"))
        XCTAssertThrowsError(try workspace.submitKeyboardEvent(.init(type: .keyDown, keyCode: 1, timestamp: 1), to: "a")) {
            XCTAssertEqual($0 as? ControlledHostWorkspaceError, .inputUnavailable)
        }

        let sent = expectation(description: "New grant enabled the existing session")
        engine.onKeySendCompleted = { code in if code == 2 { sent.fulfill() } }
        let lease = UUID()
        try engine.updateAccess(RemoteControlAccess(revision: 2, role: .controller, lease: lease))
        XCTAssertTrue(workspace.canSendInput(to: "a"))
        try workspace.submitKeyboardEvent(.init(type: .keyDown, keyCode: 2, timestamp: 2), to: "a")
        await fulfillment(of: [sent], timeout: 2)
        XCTAssertEqual(engine.startCount, 1)
        XCTAssertEqual(engine.stopCount, 0)
        XCTAssertEqual(engine.sentInputLeases, [lease])
    }

    func testRevokeAndRegrantDiscardQueuedEventsWithoutBorrowingTheNewLease() async throws {
        let journal = Journal()
        let engine = Engine("a", journal: journal)
        let oldLease = UUID()
        let newLease = UUID()
        try engine.updateAccess(RemoteControlAccess(revision: 1, role: .controller, lease: oldLease))
        let gate = Gate()
        engine.keySendGate = gate
        engine.blockedKeyCode = 10
        let workspace = workspace([engine])
        defer { gate.open(); workspace.stopAll() }
        try await workspace.connect(to: device("a")) { self.connection() }
        try workspace.submitKeyboardEvent(.init(type: .keyDown, keyCode: 10, timestamp: 1), to: "a")
        await fulfillment(of: [gate.entered], timeout: 2)
        try workspace.submitKeyboardEvent(.init(type: .keyDown, keyCode: 11, timestamp: 2), to: "a")

        try engine.updateAccess(RemoteControlAccess(revision: 2, role: .observer, lease: nil))
        XCTAssertFalse(workspace.canSendInput(to: "a"))
        XCTAssertEqual(engine.stopCount, 0)
        try engine.updateAccess(RemoteControlAccess(revision: 3, role: .controller, lease: newLease))
        let newSent = expectation(description: "Only new input uses the new lease")
        let oldCompleted = expectation(description: "The old in-flight sender completed")
        engine.onKeySendCompleted = { code in
            if code == 12 { newSent.fulfill() }
            if code == 10 { oldCompleted.fulfill() }
        }
        try workspace.submitKeyboardEvent(.init(type: .keyDown, keyCode: 12, timestamp: 3), to: "a")
        await fulfillment(of: [newSent], timeout: 2)
        gate.open()
        await fulfillment(of: [oldCompleted], timeout: 2)
        XCTAssertEqual(engine.sentInputLeases, [oldLease, newLease])
        XCTAssertFalse(journal.actions.contains(.key("a", .keyDown, 11)))
        XCTAssertFalse(journal.actions.contains(.key("a", .keyUp, 10)), "The host owns release on revocation")
        XCTAssertEqual(workspace.sessions.map(\.state), [.connected])
        XCTAssertNil(workspace.lastError)
    }

    func testRevokeDuringLocalFocusReleaseKeepsOldViewerConnected() async throws {
        let journal = Journal()
        let first = Engine("a", journal: journal)
        let second = Engine("b", journal: journal)
        let lease = UUID()
        try first.updateAccess(RemoteControlAccess(revision: 1, role: .controller, lease: lease))
        let workspace = workspace([first, second])
        let gate = Gate()
        defer { gate.open(); workspace.stopAll() }
        try await workspace.connect(to: device("a")) { self.connection() }
        first.keySendGate = gate
        first.blockedKeyCode = 10
        try workspace.submitKeyboardEvent(.init(type: .keyDown, keyCode: 10, timestamp: 1), to: "a")
        await fulfillment(of: [gate.entered], timeout: 2)
        let switchTask = Task { @MainActor in
            try await workspace.connect(to: self.device("b")) { self.connection() }
        }
        await fulfillment(of: [second.started], timeout: 2)
        try first.updateAccess(RemoteControlAccess(revision: 2, role: .observer, lease: nil))
        gate.open()
        try await switchTask.value
        XCTAssertEqual(workspace.focusedSessionId, "b")
        XCTAssertEqual(workspace.sessions.map(\.state), [.connected, .connected])
        XCTAssertEqual(first.stopCount, 0)
        XCTAssertNil(workspace.lastError)
        XCTAssertEqual(first.sentInputLeases, [lease])
    }

    func testConnectingReservationCountsTowardCapacityAndDuplicateJoinsIt() async throws {
        let journal = Journal()
        let engine = Engine("a", journal: journal)
        let workspace = workspace([engine], limit: 1)
        let gate = Gate()
        defer { gate.open(); workspace.stopAll() }
        var providerCalls = 0
        let first = Task { @MainActor in
            try await workspace.connect(to: self.device("a")) {
                providerCalls += 1
                await gate.wait()
                return self.connection()
            }
        }
        await fulfillment(of: [gate.entered], timeout: 2)
        XCTAssertEqual(workspace.sessions.map(\.state), [.connecting])
        do {
            try await workspace.connect(to: device("b")) { self.connection() }
            XCTFail("A connecting host must reserve the only admission slot")
        } catch {
            XCTAssertEqual(error as? ControlledHostWorkspaceError, .atCapacity(limit: 1))
        }
        let duplicate = Task { @MainActor in
            try await workspace.connect(to: self.device("a")) {
                providerCalls += 1
                return self.connection()
            }
        }
        gate.open()
        try await first.value
        try await duplicate.value
        XCTAssertEqual(providerCalls, 1)
        XCTAssertEqual(engine.startCount, 1)
        XCTAssertEqual(workspace.sessions.map(\.id), ["a"])
        XCTAssertEqual(workspace.focusedSessionId, "a")
    }

    func testSwitchReleasesHeldInputBeforeDemotionAndRoutesByPersistentHostIdentity() async throws {
        let journal = Journal()
        let first = Engine("a", journal: journal)
        let second = Engine("b", journal: journal)
        let firstLease = UUID()
        try first.updateAccess(RemoteControlAccess(revision: 1, role: .controller, lease: firstLease))
        let workspace = workspace([first, second])
        defer { workspace.stopAll() }
        let a = device("a")
        XCTAssertNotEqual(a.id.uuidString, "a")
        try await workspace.connect(to: a) { self.connection() }
        try workspace.submitKeyboardEvent(.init(type: .keyDown, keyCode: 12, timestamp: 1), to: "a")
        try await workspace.connect(to: device("b")) { self.connection() }
        XCTAssertEqual(workspace.focusedSessionId, "b")
        XCTAssertEqual(workspace.sessions.map(\.state), [.connected, .connected])
        let down = try XCTUnwrap(journal.actions.firstIndex(of: .key("a", .keyDown, 12)))
        let release = try XCTUnwrap(journal.actions.firstIndex(of: .key("a", .keyUp, 12)))
        let demote = try XCTUnwrap(journal.actions.firstIndex(of: .tier("a", .background)))
        let promote = try XCTUnwrap(journal.actions.firstIndex(of: .tier("b", .focused)))
        XCTAssertLessThan(down, release)
        XCTAssertLessThan(release, demote)
        XCTAssertLessThan(demote, promote)
        XCTAssertEqual(first.sentInputLeases, [firstLease, firstLease], "Normal focus loss releases with the original valid grant")
        XCTAssertThrowsError(
            try workspace.submitKeyboardEvent(.init(type: .keyDown, keyCode: 13, timestamp: 2), to: "a")
        ) { error in
            XCTAssertEqual(error as? ControlledHostWorkspaceError, .inputUnavailable)
        }
    }

    func testDisconnectBackgroundPreservesFocusAndForegroundUsesMostRecentSurvivor() async throws {
        let journal = Journal()
        let a = Engine("a", journal: journal)
        let b = Engine("b", journal: journal)
        let c = Engine("c", journal: journal)
        let workspace = workspace([a, b, c], limit: 3)
        defer { workspace.stopAll() }
        for id in ["a", "b", "c"] {
            try await workspace.connect(to: device(id)) { self.connection() }
        }
        try await workspace.focus(sessionId: "a")
        try await workspace.focus(sessionId: "c")
        try await workspace.disconnect(sessionId: "b")
        XCTAssertEqual(workspace.focusedSessionId, "c")
        XCTAssertEqual(b.stopCount, 1)
        XCTAssertEqual(a.stopCount, 0)
        XCTAssertEqual(c.stopCount, 0)
        try await workspace.disconnect(sessionId: "c")
        XCTAssertEqual(workspace.focusedSessionId, "a")
        XCTAssertEqual(workspace.sessions.map(\.id), ["a"])
    }

    func testStopAllAbandonsLateUntransferredConnectionAndNeverStartsEngine() async throws {
        let journal = Journal()
        let engine = Engine("a", journal: journal)
        let workspace = workspace([engine])
        let gate = Gate()
        defer { gate.open(); workspace.stopAll() }
        var abandonCount = 0
        let attempt = Task { @MainActor in
            try await workspace.connect(to: self.device("a")) {
                await gate.wait()
                return self.connection { abandonCount += 1 }
            }
        }
        await fulfillment(of: [gate.entered], timeout: 2)
        workspace.stopAll()
        XCTAssertTrue(workspace.sessions.isEmpty)
        gate.open()
        do {
            try await attempt.value
            XCTFail("A retired reservation must reject late provider completion")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(abandonCount, 1)
        XCTAssertEqual(engine.startCount, 0)
        XCTAssertNil(workspace.focusedSessionId)
    }

    func testOldSameHostStartCompletionCannotRetireReplacementEngine() async throws {
        let journal = Journal()
        let old = Engine("old", journal: journal)
        let replacement = Engine("replacement", journal: journal)
        let gate = Gate()
        old.startGate = gate
        let workspace = workspace([old, replacement])
        defer { gate.open(); workspace.stopAll() }
        let attempt = Task { @MainActor in
            try await workspace.connect(to: self.device("a")) { self.connection() }
        }
        await fulfillment(of: [gate.entered], timeout: 2)
        try await workspace.disconnect(sessionId: "a")
        try await workspace.connect(to: device("a")) { self.connection() }
        gate.open()
        do {
            try await attempt.value
            XCTFail("A replaced incarnation must not publish success")
        } catch { XCTAssertTrue(error is CancellationError) }
        old.errors.send("Delayed failure from retired engine")
        XCTAssertEqual(workspace.sessions.map(\.state), [.connected])
        XCTAssertEqual(workspace.focusedSessionId, "a")
        XCTAssertEqual(replacement.stopCount, 0)
        XCTAssertNil(workspace.sessions.first?.error)
    }

    func testPromotionFailureIsVisibleAndDoesNotDropTheOtherConnection() async throws {
        let journal = Journal()
        let a = Engine("a", journal: journal)
        let b = Engine("b", journal: journal)
        b.rejectedTier = .focused
        let workspace = workspace([a, b])
        defer { workspace.stopAll() }
        try await workspace.connect(to: device("a")) { self.connection() }
        do {
            try await workspace.connect(to: device("b")) { self.connection() }
            XCTFail("Rejected stream configuration must propagate")
        } catch { XCTAssertTrue(error is Failure) }
        XCTAssertEqual(workspace.sessions.map(\.state), [.connected, .failed])
        XCTAssertEqual(workspace.sessions.last?.error, Failure.rejected.localizedDescription)
        XCTAssertEqual(workspace.lastError, Failure.rejected.localizedDescription)
        XCTAssertEqual(a.stopCount, 0)
        XCTAssertEqual(b.stopCount, 1)
        XCTAssertNil(workspace.focusedSessionId)
        try await workspace.focus(sessionId: "a")
        XCTAssertEqual(workspace.focusedSessionId, "a")
    }

    func testInputIsRejectedThroughoutAnAcknowledgementBarrierAndStopAllFencesPromotion() async throws {
        let journal = Journal()
        let a = Engine("a", journal: journal)
        let b = Engine("b", journal: journal)
        let workspace = workspace([a, b])
        let gate = Gate()
        defer { gate.open(); workspace.stopAll() }
        try await workspace.connect(to: device("a")) { self.connection() }
        a.demotionGate = gate
        let attempt = Task { @MainActor in
            try await workspace.connect(to: self.device("b")) { self.connection() }
        }
        await fulfillment(of: [gate.entered], timeout: 2)
        XCTAssertTrue(workspace.isSwitchingFocus)
        for id in ["a", "b"] {
            XCTAssertThrowsError(
                try workspace.submitMouseEvent(.init(type: .leftMouseDown, x: 1, y: 2, timestamp: 3), to: id)
            ) { error in
                XCTAssertEqual(error as? ControlledHostWorkspaceError, .inputUnavailable)
            }
        }
        workspace.stopAll()
        gate.open()
        do {
            try await attempt.value
            XCTFail("Stopping the workspace must fence pending promotion")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(journal.actions.contains(.tier("b", .focused)))
        XCTAssertTrue(workspace.sessions.isEmpty)
        XCTAssertFalse(workspace.isSwitchingFocus)
    }

    func testFocusedManagerUsesTheExactSessionAndFrameFeedsRemainIndependent() async throws {
        let journal = Journal()
        let a = Engine("a", journal: journal)
        let b = Engine("b", journal: journal)
        let managerA = RemoteControlManager(controlledHostStreamTier: .background)
        let managerB = RemoteControlManager(controlledHostStreamTier: .background)
        a.exposedManager = managerA
        b.exposedManager = managerB
        let workspace = workspace([a, b])
        defer { workspace.stopAll() }
        try await workspace.connect(to: device("a")) { self.connection() }
        XCTAssertTrue(workspace.focusedManager === managerA)
        try await workspace.connect(to: device("b")) { self.connection() }
        XCTAssertTrue(workspace.focusedManager === managerB)
        XCTAssertFalse(managerA.textureFeed === managerB.textureFeed)
        try await workspace.focus(sessionId: "a")
        XCTAssertTrue(workspace.focusedManager === managerA)
        XCTAssertEqual(a.startCount, 1)
        XCTAssertEqual(b.startCount, 1)
    }

    func testPendingFocusCannotPromoteADisconnectedSameHostIncarnation() async throws {
        let journal = Journal()
        let a = Engine("a", journal: journal)
        let oldB = Engine("old-b", journal: journal)
        let newB = Engine("new-b", journal: journal)
        let workspace = workspace([a, oldB, newB])
        let gate = Gate()
        defer { gate.open(); workspace.stopAll() }
        try await workspace.connect(to: device("a")) { self.connection() }
        a.demotionGate = gate
        let oldAttempt = Task { @MainActor in
            try await workspace.connect(to: self.device("b")) { self.connection() }
        }
        await fulfillment(of: [gate.entered], timeout: 2)
        try await workspace.disconnect(sessionId: "b")
        let replacement = Task { @MainActor in
            try await workspace.connect(to: self.device("b")) { self.connection() }
        }
        await fulfillment(of: [newB.started], timeout: 2)
        gate.open()
        do {
            try await oldAttempt.value
            XCTFail("Pending focus must be bound to the original incarnation")
        } catch { XCTAssertTrue(error is CancellationError) }
        try await replacement.value
        XCTAssertFalse(journal.actions.contains(.tier("old-b", .focused)))
        XCTAssertTrue(journal.actions.contains(.tier("new-b", .focused)))
        XCTAssertEqual(workspace.sessions.map(\.state), [.connected, .connected])
        XCTAssertEqual(workspace.focusedSessionId, "b")
        XCTAssertEqual(newB.stopCount, 0)
    }

    func testFocusQueueHasABoundedCapacityAndRecoversAfterDrain() async throws {
        let journal = Journal()
        let a = Engine("a", journal: journal)
        let b = Engine("b", journal: journal)
        let workspace = workspace([a, b])
        let gate = Gate()
        defer { gate.open(); workspace.stopAll() }
        try await workspace.connect(to: device("a")) { self.connection() }
        a.demotionGate = gate
        let initial = Task { @MainActor in
            try await workspace.connect(to: self.device("b")) { self.connection() }
        }
        await fulfillment(of: [gate.entered], timeout: 2)
        let enqueued = expectation(description: "Remaining bounded focus slots occupied")
        enqueued.expectedFulfillmentCount = 15
        let queued = (0..<15).map { _ in
            Task { @MainActor in
                enqueued.fulfill()
                try await workspace.focus(sessionId: "b")
            }
        }
        await fulfillment(of: [enqueued], timeout: 2)
        do {
            try await workspace.focus(sessionId: "b")
            XCTFail("The focus transition queue must reject overflow")
        } catch {
            XCTAssertEqual(error as? ControlledHostWorkspaceError, .focusQueueFull)
        }
        gate.open()
        try await initial.value
        for task in queued { try await task.value }
        XCTAssertFalse(workspace.isSwitchingFocus)
        XCTAssertEqual(workspace.focusedSessionId, "b")
        try await workspace.focus(sessionId: "a")
        XCTAssertEqual(workspace.focusedSessionId, "a")
    }

    func testRetiredAutomaticFocusFailureCannotPublishIntoAReopenedWorkspace() async throws {
        let journal = Journal()
        let a = Engine("a", journal: journal)
        let b = Engine("b", journal: journal)
        let c = Engine("c", journal: journal)
        let workspace = workspace([a, b, c])
        let gate = Gate()
        defer { gate.open(); workspace.stopAll() }
        try await workspace.connect(to: device("a")) { self.connection() }
        try await workspace.connect(to: device("b")) { self.connection() }
        try await workspace.focus(sessionId: "a")
        b.promotionGate = gate
        b.rejectedTier = .focused
        a.errors.send("The focused host disconnected")
        await fulfillment(of: [gate.entered], timeout: 2)

        workspace.stopAll()
        try await workspace.connect(to: device("c")) { self.connection() }
        let oldFocusFinished = expectation(description: "Retired automatic focus finished its barrier")
        let subscription = workspace.$isSwitchingFocus
            .dropFirst()
            .filter { !$0 }
            .prefix(1)
            .sink { _ in oldFocusFinished.fulfill() }
        defer { subscription.cancel() }
        gate.open()
        await fulfillment(of: [oldFocusFinished], timeout: 2)

        XCTAssertEqual(workspace.sessions.map(\.id), ["c"])
        XCTAssertEqual(workspace.sessions.map(\.state), [.connected])
        XCTAssertEqual(workspace.focusedSessionId, "c")
        XCTAssertNil(workspace.lastError)
        XCTAssertEqual(c.stopCount, 0)
    }
}
#endif
