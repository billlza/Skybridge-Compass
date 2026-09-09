#if os(macOS)
import Network
import XCTest
@testable import SkyBridgeCore

@MainActor
final class RemoteControlInboundSessionCoordinatorTests: XCTestCase {
    private final class Engine: RemoteControlInboundSessionEngine {
        var onInboundSessionEnded: (@MainActor (NWConnection) -> Void)?
        var started: (() -> Void)?
        var connections: [NWConnection] = []
        var initialPayloads: [Data?] = []
        var stoppedDeviceIds: [String] = []

        func allowRemoteControl(from deviceId: String, connection: NWConnection, initialData: Data?) async {
            connections.append(connection)
            initialPayloads.append(initialData)
            started?()
        }

        func stopRemoteControl(from deviceId: String) {
            stoppedDeviceIds.append(deviceId)
        }
    }

    func testCapacityIncludesPendingStartupAndReturnedStartupRemainsOwned() async throws {
        let engines = [Engine(), Engine()]
        let started = expectation(description: "Both exact engines started")
        started.expectedFulfillmentCount = 2
        engines.forEach { $0.started = { started.fulfill() } }
        var made = 0
        let coordinator = RemoteControlInboundSessionCoordinator(limit: 2) {
            defer { made += 1 }
            return engines[made]
        }
        let connections = (0..<3).map { _ in makeConnection() }
        defer { coordinator.stopAll(); connections.forEach { $0.cancel() } }
        let firstBytes = Data([1, 2, 3])
        let secondBytes = Data([4, 5, 6])
        try coordinator.accept(connection: connections[0], deviceId: "same-device", initialData: firstBytes) {}
        try coordinator.accept(connection: connections[1], deviceId: "same-device", initialData: secondBytes) {}
        XCTAssertThrowsError(try coordinator.accept(
            connection: connections[2], deviceId: "third", initialData: nil
        ) {}) { error in
            XCTAssertEqual(error as? RemoteControlInboundSessionError, .atCapacity(limit: 2))
        }
        XCTAssertEqual(made, 2)
        XCTAssertEqual(coordinator.activeSessionCount, 2)
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(coordinator.activeSessionCount, 2, "Returning from startup is not session termination")
        XCTAssertTrue(engines[0].connections.first === connections[0])
        XCTAssertTrue(engines[1].connections.first === connections[1])
        XCTAssertEqual(engines[0].initialPayloads, [firstBytes])
        XCTAssertEqual(engines[1].initialPayloads, [secondBytes])
        XCTAssertTrue(engines.allSatisfy { $0.stoppedDeviceIds.isEmpty })
    }

    func testExactTerminationCannotRetireOtherConnectionWithSameDeviceId() throws {
        let first = Engine()
        let second = Engine()
        var available = [first, second]
        let coordinator = RemoteControlInboundSessionCoordinator(limit: 2) { available.removeFirst() }
        let firstConnection = makeConnection()
        let secondConnection = makeConnection()
        var ended = [0, 0]
        try coordinator.accept(connection: firstConnection, deviceId: "same", initialData: nil) { ended[0] += 1 }
        try coordinator.accept(connection: secondConnection, deviceId: "same", initialData: nil) { ended[1] += 1 }
        let staleCallback = try XCTUnwrap(first.onInboundSessionEnded)
        staleCallback(secondConnection)
        XCTAssertEqual(coordinator.activeSessionCount, 2)
        staleCallback(firstConnection)
        staleCallback(firstConnection)
        XCTAssertEqual(coordinator.activeSessionCount, 1)
        XCTAssertEqual(ended, [1, 0])
        XCTAssertTrue(second.stoppedDeviceIds.isEmpty)
        coordinator.stopAll()
        coordinator.stopAll()
        XCTAssertEqual(coordinator.activeSessionCount, 0)
        XCTAssertEqual(ended, [1, 1])
        XCTAssertEqual(second.stoppedDeviceIds, ["same"])
    }

    func testStaleTerminalCallbackCannotRemoveNewIncarnationOfTransport() throws {
        let old = Engine()
        let replacement = Engine()
        var available = [old, replacement]
        let coordinator = RemoteControlInboundSessionCoordinator(limit: 1) { available.removeFirst() }
        let connection = makeConnection()
        var oldEnded = 0
        var replacementEnded = 0
        try coordinator.accept(connection: connection, deviceId: "same", initialData: nil) { oldEnded += 1 }
        let staleCallback = try XCTUnwrap(old.onInboundSessionEnded)
        coordinator.stopAll()
        try coordinator.accept(connection: connection, deviceId: "same", initialData: nil) { replacementEnded += 1 }
        staleCallback(connection)
        XCTAssertEqual(coordinator.activeSessionCount, 1)
        XCTAssertEqual(oldEnded, 1)
        XCTAssertEqual(replacementEnded, 0)
        XCTAssertTrue(replacement.stoppedDeviceIds.isEmpty)
        coordinator.stopAll()
        XCTAssertEqual(replacementEnded, 1)
    }

    func testDuplicateConnectionIsRejectedWithoutConstructingAnotherEngine() throws {
        var made = 0
        let coordinator = RemoteControlInboundSessionCoordinator(limit: 2) {
            made += 1
            return Engine()
        }
        let connection = makeConnection()
        defer { coordinator.stopAll() }
        try coordinator.accept(connection: connection, deviceId: "first", initialData: nil) {}
        XCTAssertThrowsError(try coordinator.accept(connection: connection, deviceId: "second", initialData: nil) {}) {
            XCTAssertEqual($0 as? RemoteControlInboundSessionError, .connectionAlreadyOwned)
        }
        XCTAssertEqual(made, 1)
        XCTAssertEqual(coordinator.activeSessionCount, 1)
    }

    func testAdmissionRejectsStaleReleaseAfterReplacement() throws {
        let admission = RemoteControlInboundAdmission(maximumConnections: 1, maximumConnectionsPerEndpoint: 1)
        let connection = makeConnection()
        defer { admission.cancelAll() }
        let old = try XCTUnwrap(admission.reserve(connection: connection, endpointKey: "first"))
        admission.release(old)
        let current = try XCTUnwrap(admission.reserve(connection: connection, endpointKey: "second"))
        admission.release(old)
        XCTAssertFalse(admission.isCurrent(old))
        XCTAssertTrue(admission.isCurrent(current))
        XCTAssertEqual(admission.activeConnectionCount, 1)
        XCTAssertEqual(admission.activeConnectionCount(for: "second"), 1)
        admission.cancelAll()
        XCTAssertFalse(admission.isCurrent(current), "A queued handoff must be fenced after server stop")
    }

    private func makeConnection() -> NWConnection {
        NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
    }
}
#endif
