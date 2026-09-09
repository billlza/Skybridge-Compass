import Combine
import XCTest
import SkyBridgeProtocolCore
@testable import SkyBridgeCompass_iOS

@available(iOS 17.0, *)
@MainActor
final class RemoteDesktopWorkspaceTests: XCTestCase {
    func testSwitchPausesAndAcknowledgesPreviousBeforeGrantingNewInputFocus() async throws {
        let journal = Journal()
        var created = 0
        let workspace = RemoteDesktopWorkspaceCoordinator<FakeRuntime> {
            created += 1
            return FakeRuntime(name: String(created), journal: journal)
        }
        try await workspace.connect(connection("one"))
        try await workspace.connect(connection("two"))
        XCTAssertEqual(workspace.sessions.count, 2)
        XCTAssertEqual(workspace.focusedSessionID, "two")
        XCTAssertEqual(journal.events, ["1:start", "1:ack", "1:focus:true",
                                        "1:focus:false", "1:pause-ack", "2:start", "2:ack", "2:focus:true"])
        try await workspace.focus("one")
        XCTAssertEqual(created, 2, "Returning focus must reuse the authenticated transport owner")
        XCTAssertEqual(Array(journal.events.suffix(5)), ["2:focus:false", "2:pause-ack", "1:start", "1:ack", "1:focus:true"])
    }

    func testTwoHostLimitRefusesThirdWithoutReplacingExistingRuntimes() async throws {
        let workspace = RemoteDesktopWorkspaceCoordinator<FakeRuntime> {
            FakeRuntime(name: "runtime", journal: Journal())
        }
        try await workspace.connect(connection("one"))
        try await workspace.connect(connection("two"))
        do {
            try await workspace.connect(connection("three"))
            XCTFail("A third host must be refused")
        } catch {
            XCTAssertEqual(error as? RemoteDesktopWorkspaceCoordinator<FakeRuntime>.Failure, .atCapacity(2))
        }
        XCTAssertEqual(workspace.sessions.map(\.id), ["one", "two"])
        XCTAssertEqual(workspace.focusedSessionID, "two")
    }

    func testPreservedWebRTCCountsTowardSameTwoHostLimit() async throws {
        let workspace = RemoteDesktopWorkspaceCoordinator<FakeRuntime>(
            makeRuntime: { FakeRuntime(name: "lan", journal: Journal()) },
            reservedExternalHostKeys: { ["primary:webrtc-peer"] }
        )
        try await workspace.connect(connection("one"))
        XCTAssertNoThrow(try workspace.requireExternalAdmission(hostKey: "primary:webrtc-peer"))
        do {
            try await workspace.connect(connection("two"))
            XCTFail("A retained WebRTC transport occupies the other host slot")
        } catch {
            XCTAssertEqual(error as? RemoteDesktopWorkspaceCoordinator<FakeRuntime>.Failure, .atCapacity(2))
        }
        XCTAssertEqual(workspace.sessions.map(\.id), ["one"])
    }

    func testFailedPauseNeverStartsOrFocusesSecondHost() async throws {
        let journal = Journal()
        var runtimes: [FakeRuntime] = []
        let workspace = RemoteDesktopWorkspaceCoordinator<FakeRuntime> {
            let runtime = FakeRuntime(name: String(runtimes.count + 1), journal: journal)
            runtimes.append(runtime)
            return runtime
        }
        try await workspace.connect(connection("one"))
        runtimes[0].pauseFails = true
        do {
            try await workspace.connect(connection("two"))
            XCTFail("A peer that has not acknowledged pause prevents focus transfer")
        } catch {
            XCTAssertEqual(error as? TestFailure, .pauseRejected)
        }
        XCTAssertEqual(workspace.sessions.map(\.id), ["one"])
        XCTAssertEqual(workspace.focusedSessionID, "one")
        XCTAssertFalse(journal.events.contains("2:start"))
        XCTAssertFalse(journal.events.contains("2:focus:true"))
        XCTAssertTrue(journal.events.contains("2:disconnect"))
    }

    func testClosingBackgroundHostDoesNotPauseOrDisconnectFocusedHost() async throws {
        let journal = Journal()
        var number = 0
        let workspace = RemoteDesktopWorkspaceCoordinator<FakeRuntime> {
            number += 1
            return FakeRuntime(name: String(number), journal: journal)
        }
        try await workspace.connect(connection("one"))
        try await workspace.connect(connection("two"))
        journal.events.removeAll()
        try await workspace.close("one")
        XCTAssertEqual(journal.events, ["1:focus:false", "1:disconnect"])
        XCTAssertEqual(workspace.focusedSessionID, "two")
    }

    func testConnectingHostIsReservedAndConcurrentFocusIsRejected() async throws {
        let entered = Signal()
        let release = Signal()
        let workspace = RemoteDesktopWorkspaceCoordinator<FakeRuntime> {
            let runtime = FakeRuntime(name: "one", journal: Journal())
            runtime.startHook = { entered.signal(); await release.wait() }
            return runtime
        }
        let connecting = Task { try await workspace.connect(connection("one")) }
        await entered.wait()
        XCTAssertEqual(workspace.sessions.map(\.id), ["one"])
        XCTAssertTrue(workspace.isChangingFocus)
        do {
            try await workspace.connect(connection("two"))
            XCTFail("Concurrent focus changes must have an explicit result")
        } catch {
            XCTAssertEqual(error as? RemoteDesktopWorkspaceCoordinator<FakeRuntime>.Failure, .operationInProgress)
        }
        release.signal()
        try await connecting.value
        XCTAssertFalse(workspace.isChangingFocus)
    }

    private func connection(_ id: String) -> Connection {
        Connection(id: "connection-\(id)", device: DiscoveredDevice(
            id: id, name: id, modelName: "Mac", platform: .macOS, osVersion: "",
            ipAddress: nil, services: [], portMap: [:], signalStrength: -40,
            lastSeen: Date(), isConnected: true, isTrusted: true, publicKey: nil,
            advertisedCapabilities: [], capabilities: []
        ))
    }

    private enum TestFailure: Error, Equatable { case pauseRejected }
    private final class Journal { var events: [String] = [] }
    private final class FakeRuntime: RemoteDesktopWorkspaceRuntime {
        let objectWillChange = ObservableObjectPublisher()
        var isStreaming = false
        let name: String
        let journal: Journal
        var pauseFails = false
        var startHook: (@MainActor () async -> Void)?
        init(name: String, journal: Journal) { self.name = name; self.journal = journal }
        func startStreaming(from connection: Connection, routeIntent: PeerTransportRouteIntent) async throws {
            journal.events.append("\(name):start")
            await startHook?()
            isStreaming = true
        }
        func pauseWorkspaceStream() async throws {
            if pauseFails { throw TestFailure.pauseRejected }
            journal.events.append("\(name):pause-ack")
            isStreaming = false
        }
        func waitForWorkspaceConfigurationAcknowledgement() async throws { journal.events.append("\(name):ack") }
        func setWorkspaceInputFocus(_ focused: Bool) { journal.events.append("\(name):focus:\(focused)") }
        func disconnect(tearDownTransport: Bool) async {
            journal.events.append("\(name):disconnect")
            isStreaming = false
        }
    }

    @MainActor
    private final class Signal {
        private var signalled = false
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            if signalled { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func signal() { signalled = true; continuation?.resume(); continuation = nil }
    }
}
