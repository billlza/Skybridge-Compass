import Dispatch
import os.lock
import XCTest
@testable import SkyBridgeCore

final class NetworkListenerStartupGateTests: XCTestCase {
    func testReadyCompletesStartupAndLaterFailureIsRuntimeTransition() {
        let gate = NetworkListenerStartupGate()

        XCTAssertEqual(gate.observe(.ready), .completesStartup)
        XCTAssertEqual(gate.observe(.failed), .runtimeTransition)
        XCTAssertEqual(gate.observe(.cancelled), .ignored)
        XCTAssertFalse(gate.claimTimeout())
    }

    func testTimeoutWinsAndIgnoresLateListenerState() {
        let gate = NetworkListenerStartupGate()

        XCTAssertTrue(gate.claimTimeout())
        XCTAssertEqual(gate.observe(.ready), .ignored)
        XCTAssertEqual(gate.observe(.failed), .ignored)
        XCTAssertFalse(gate.claimTimeout())
    }

    func testConcurrentTerminalStatesCompleteStartupExactlyOnce() {
        let gate = NetworkListenerStartupGate()
        let completionCount = OSAllocatedUnfairLock(initialState: 0)
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "NetworkListenerStartupGateTests", attributes: .concurrent)

        for state in [
            NetworkListenerStartupGate.TerminalState.ready,
            .failed,
            .cancelled,
            .ready
        ] {
            group.enter()
            queue.async {
                if gate.observe(state) == .completesStartup {
                    completionCount.withLock { $0 += 1 }
                }
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(completionCount.withLock { $0 }, 1)
    }

    func testEveryInboundListenerUsesTheSharedTimeoutGate() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcePaths = [
            "Sources/SkyBridgeCore/FileTransfer/FileTransferListenerService.swift",
            "Sources/SkyBridgeCore/FileTransfer/LocalFileTransferHTTPServer.swift",
            "Sources/SkyBridgeCore/RemoteControl/RemoteControlServer.swift"
        ]

        for path in sourcePaths {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            XCTAssertTrue(source.contains("NetworkListenerStartupGate()"), "Missing shared startup gate in \(path)")
            XCTAssertTrue(source.contains("listenerStartTimeout"), "Missing listener timeout in \(path)")
            XCTAssertTrue(source.contains("POSIXError(.ETIMEDOUT)"), "Missing explicit timeout error in \(path)")
            XCTAssertFalse(source.contains("class StartState"), "Legacy unsynchronized start state remains in \(path)")
        }
    }
}
