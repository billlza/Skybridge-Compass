#if os(macOS)
import Foundation
import os
import XCTest
@testable import SkyBridgeCore

@MainActor
final class CoreWLANConcurrencyTests: XCTestCase {
    func testBlockingHardwareLeavesMainThreadAndSerializesOperations() async throws {
        let entered = XCTestExpectation(description: "scan entered hardware")
        let release = DispatchSemaphore(value: 0)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let client = CoreWLANClient {
            XCTAssertFalse(Thread.isMainThread, "CoreWLAN initialization must also leave MainActor")
            return ScriptedRadio(onScan: {
                XCTAssertFalse(Thread.isMainThread)
                calls.withLock { $0 += 1 }
                entered.fulfill()
                guard release.wait(timeout: .now() + 3) == .success else { throw ProbeError.timedOut }
                return RadioFixture.scan
            }, onConnection: {
                XCTAssertFalse(Thread.isMainThread)
                calls.withLock { $0 += 1 }
                return RadioFixture.connection
            })
        }
        let scan = Task { try await client.scan() }
        defer { release.signal() }
        let wait = await XCTWaiter.fulfillment(of: [entered], timeout: 1)
        XCTAssertEqual(wait, .completed)
        // This continuation runs on MainActor while the real serial worker is
        // blocked. It would time out if scan were still executing on MainActor.
        let connection = Task { try await client.connection() }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(calls.withLock { $0 }, 1, "Only one hardware operation may run at a time")
        release.signal()
        _ = try await scan.value
        _ = try await connection.value
        XCTAssertEqual(calls.withLock { $0 }, 2)
    }

    func testCancelledQueuedConnectionNeverReachesHardware() async throws {
        let entered = XCTestExpectation(description: "scan entered hardware")
        let release = DispatchSemaphore(value: 0)
        let connections = OSAllocatedUnfairLock(initialState: 0)
        let client = CoreWLANClient {
            ScriptedRadio(onScan: {
                entered.fulfill()
                guard release.wait(timeout: .now() + 3) == .success else { throw ProbeError.timedOut }
                return RadioFixture.scan
            }, onConnect: { _, _, _ in
                connections.withLock { $0 += 1 }
                return RadioFixture.scan
            })
        }
        let scan = Task { try await client.scan() }
        defer { release.signal() }
        let wait = await XCTWaiter.fulfillment(of: [entered], timeout: 1)
        XCTAssertEqual(wait, .completed)
        let connection = Task { try await client.connect(ssid: "known", bssid: "bssid", password: nil) }
        await Task.yield()
        connection.cancel()
        release.signal()
        _ = try await scan.value
        do {
            _ = try await connection.value
            XCTFail("A cancelled request must not report a successful connection")
        } catch is CancellationError {
            XCTAssertEqual(connections.withLock { $0 }, 0)
        }
    }

    func testHardwareFailurePropagatesInsteadOfReturningEmptySuccess() async {
        let client = CoreWLANClient { ScriptedRadio(onScan: { throw ProbeError.denied }) }
        do {
            _ = try await client.scan()
            XCTFail("Permission failures must propagate")
        } catch {
            XCTAssertEqual(error as? ProbeError, .denied)
        }
    }

    func testCancellationDuringBlockingScanDiscardsItsReturnValue() async throws {
        let entered = XCTestExpectation(description: "scan entered hardware")
        let release = DispatchSemaphore(value: 0)
        let client = CoreWLANClient {
            ScriptedRadio(onScan: {
                entered.fulfill()
                guard release.wait(timeout: .now() + 3) == .success else { throw ProbeError.timedOut }
                return RadioFixture.scan
            })
        }
        let request = Task { try await client.scan() }
        defer { release.signal() }
        let wait = await XCTWaiter.fulfillment(of: [entered], timeout: 1)
        XCTAssertEqual(wait, .completed)
        request.cancel()
        release.signal()
        do {
            _ = try await request.value
            XCTFail("An uncancellable hardware call must not publish success after cancellation")
        } catch is CancellationError {
            // The hardware returned normally; the client rejected that obsolete result.
        }
    }

    func testPreferenceScansCoalesceAndKeepBandSelection() async throws {
        let radio = SuspendedRadio()
        let service = try makePreferences(radio)
        service.knownNetworkSSIDs = ["known"]
        let requests = (0..<12).map { _ in Task { await service.scanAvailableNetworks() } }
        try await radio.waitUntilScanning()
        // Allow all of the main-actor requests to join the first scan.
        for _ in 0..<20 { await Task.yield() }
        let count = await radio.scanCount
        XCTAssertEqual(count, 1)
        await radio.finishScan()
        for request in requests { await request.value }
        XCTAssertEqual(service.availableNetworks.count, 3)
        XCTAssertEqual(service.recommendedNetwork?.band, .band6GHz)
        XCTAssertEqual(service.recommendedNetwork?.bssid, "six")
        service.stopNetworkMonitoring()
    }

    func testStopDiscardsLateResultsWithoutAutoConnectOrPersistence() async throws {
        let radio = SuspendedRadio()
        let service = try makePreferences(radio)
        let request = Task { await service.scanAvailableNetworks() }
        try await radio.waitUntilScanning()
        service.stopNetworkMonitoring()
        // This test double deliberately ignores cancellation, as an in-progress
        // system scan can. The service must still reject its stale result.
        await radio.finishScan()
        await request.value
        XCTAssertTrue(service.availableNetworks.isEmpty)
        XCTAssertTrue(service.knownNetworkSSIDs.isEmpty)
        XCTAssertNil(service.currentNetwork)
        XCTAssertNil(service.recommendedNetwork)
        let connections = await radio.connectionCount
        XCTAssertEqual(connections, 0)
    }

    func testRestartWaitsForCancelledScanThenPerformsFreshScan() async throws {
        let radio = SuspendedRadio()
        let service = try makePreferences(radio)
        let first = Task { await service.scanAvailableNetworks() }
        try await radio.waitUntilScanning()
        service.stopNetworkMonitoring()
        let restarted = Task { await service.scanAvailableNetworks() }
        for _ in 0..<10 { await Task.yield() }
        let before = await radio.scanCount
        XCTAssertEqual(before, 1)
        await radio.finishScan()
        await first.value
        try await radio.waitUntilScanning()
        let after = await radio.scanCount
        XCTAssertEqual(after, 2)
        await radio.finishScan()
        await restarted.value
        XCTAssertEqual(service.availableNetworks.count, 3)
        service.stopNetworkMonitoring()
    }

    func testDeviceManagerStopRejectsLateScanAndAllowsRestart() async throws {
        let radio = SuspendedRadio()
        let manager = WiFiManager(radio: radio, observeSystemChanges: false)
        manager.hasPermission = true
        let first = Task { await manager.startScanning() }
        try await radio.waitUntilScanning()
        manager.stopScanning()
        await radio.finishScan()
        await first.value
        XCTAssertFalse(manager.isScanning)
        XCTAssertTrue(manager.availableNetworks.isEmpty)
        let second = Task { await manager.startScanning() }
        try await radio.waitUntilScanning()
        await radio.finishScan()
        await second.value
        XCTAssertTrue(manager.isScanning)
        XCTAssertEqual(manager.availableNetworks.count, 3)
        manager.stopScanning()
    }

    private func makePreferences(_ radio: any WiFiRadioAccess) throws -> NetworkPreferenceService {
        // A unique suite prevents these tests from reading or changing real known SSIDs.
        let suite = "CoreWLANConcurrencyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return NetworkPreferenceService(radio: radio, defaults: defaults)
    }
}

private enum ProbeError: Error { case timedOut, denied, overlappingScan }

private struct ScriptedRadio: WiFiRadioHardware {
    var onScan: () throws -> WiFiRadioScan
    var onConnection: () throws -> WiFiRadioConnection = { RadioFixture.connection }
    var onConnect: (String, String?, String?) throws -> WiFiRadioScan = { _, _, _ in RadioFixture.scan }
    func scan() throws -> WiFiRadioScan { try onScan() }
    func connection() throws -> WiFiRadioConnection { try onConnection() }
    func connect(ssid: String, bssid: String?, password: String?) throws -> WiFiRadioScan { try onConnect(ssid, bssid, password) }
    func disconnect() throws {}
}

private actor SuspendedRadio: WiFiRadioAccess {
    private(set) var scanCount = 0
    private(set) var connectionCount = 0
    private var pending: CheckedContinuation<WiFiRadioScan, Never>?

    func scan() async throws -> WiFiRadioScan {
        scanCount += 1
        guard pending == nil else { throw ProbeError.overlappingScan }
        return await withCheckedContinuation { pending = $0 }
    }
    func waitUntilScanning() async throws {
        for _ in 0..<100 {
            if pending != nil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ProbeError.timedOut
    }
    func finishScan() {
        let continuation = pending
        pending = nil
        continuation?.resume(returning: RadioFixture.scan)
    }
    func connection() async throws -> WiFiRadioConnection { RadioFixture.connection }
    func connect(ssid: String, bssid: String?, password: String?) async throws -> WiFiRadioScan {
        connectionCount += 1
        return RadioFixture.scan
    }
    func disconnect() async throws {}
}

private enum RadioFixture {
    static let connection = WiFiRadioConnection(
        interfaceName: "test", powerOn: true, ssid: "known", bssid: "two",
        channel: 1, band: .band2_4GHz, rssi: -30
    )
    static let scan = WiFiRadioScan(networks: [
        WiFiRadioNetwork(ssid: "known", bssid: "two", channel: 1, band: .band2_4GHz, rssi: -30, security: .wpa2, frequency: 1),
        WiFiRadioNetwork(ssid: "known", bssid: "five", channel: 36, band: .band5GHz, rssi: -40, security: .wpa2, frequency: 2),
        WiFiRadioNetwork(ssid: "known", bssid: "six", channel: 37, band: .band6GHz, rssi: -60, security: .wpa3, frequency: 3)
    ], connection: connection)
}
#endif
