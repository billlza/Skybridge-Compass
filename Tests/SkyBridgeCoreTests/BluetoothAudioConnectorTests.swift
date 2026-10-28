import CoreBluetooth
import Foundation
import XCTest
import os
import SkyBridgeProtocolCore
@testable import SkyBridgeAppleTransport

/// Controlled discovery callbacks plus the real framed stream worker and child
/// cryptography. These cases do not establish a Bluetooth radio or account lease.
@MainActor
final class BluetoothAudioConnectorTests: XCTestCase {
    private enum Failure: Error { case revoked, eventTimeout, connectFailed }

    func testNativeFailurePreservesCallbackAndCodeThroughCleanupWithoutPrivateDescription() async throws {
        for operation in BluetoothAudioNativeFailure.Operation.allCases {
            let f = try BluetoothAudioFixture.load(), driver = Driver()
            driver.autoConnect = operation != .connect
            let dial = try connector(f, driver)
            let task = Task { try await dial.connect() }
            try await until { !driver.scanned.isEmpty }; driver.discover()
            let native = NSError(domain: CBErrorDomain, code: 0,
                userInfo: [NSLocalizedDescriptionKey: "private-device; example-secret"])
            driver.events?.failed(BluetoothAudioNativeFailure(operation: operation, underlying: native))
            let error = await failure { try await task.value }
            guard let observed = error as? BluetoothAudioNativeFailure else {
                return XCTFail("Native failure context was discarded")
            }
            XCTAssertEqual(observed.operation, operation)
            XCTAssertEqual(observed.diagnosticLabel, "native.\(operation.rawValue).bluetooth.cb.0")
            XCTAssertEqual(String(describing: observed), observed.diagnosticLabel)
            XCTAssertEqual((observed.underlying as NSError).code, 0)
            XCTAssertTrue(dial.isClosed); XCTAssertNil(driver.events)
            XCTAssertEqual(driver.detachCount, 1)
        }
    }

    func testGATTPSMMustExactlyMatchAuthenticatedRouteAndLittleEndianEncoding() throws {
        XCTAssertEqual(try NativeBluetoothAudioDialDriver.verifiedPSM(Data([0x80, 0]), expected: 0x80), 0x80)
        let slice = Data([0xff, 0x81, 0]).dropFirst()
        XCTAssertEqual(try NativeBluetoothAudioDialDriver.verifiedPSM(slice, expected: 0x81), 0x81)
        for value: Data? in [nil, Data(), Data([0x80]), Data([0x80, 0, 0])] {
            XCTAssertThrowsError(try NativeBluetoothAudioDialDriver.verifiedPSM(value, expected: 0x80)) { error in
                guard case .invalidPSMValue = error as? BluetoothAudioConnectorError else { return XCTFail("Malformed PSM was not rejected") }
            }
        }
        for value in [Data([0, 0x80]), Data([0x81, 0]), Data([0, 0])] {
            XCTAssertThrowsError(try NativeBluetoothAudioDialDriver.verifiedPSM(value, expected: 0x80)) { error in
                guard case .psmMismatch = error as? BluetoothAudioConnectorError else { return XCTFail("GATT cannot replace the authenticated route") }
            }
        }
        for expected: UInt16 in [0, 256, UInt16.max] {
            XCTAssertThrowsError(try NativeBluetoothAudioDialDriver.verifiedPSM(Data([0, 0]), expected: expected))
        }
    }

    func testExactRouteAndRealChildAuthenticationPrecedeReadinessAndMedia() async throws {
        let f = try BluetoothAudioFixture.load(), driver = Driver(), pair = try streams()
        let sourceOwner = try f.attachment(.source)
        let dial = try connector(f, driver, attachment: sourceOwner)
        let sink = BluetoothAudioChannel(transport: pair.1, attachment: try f.attachment(.sink))
        let task = Task { try await dial.connect() }
        try await until { driver.scanned.count == 1 }
        guard case .bluetoothRoute(let route) = sourceOwner.binding.route.body else { return XCTFail("Missing route") }
        XCTAssertEqual(driver.scanned, [route.serviceID])
        XCTAssertThrowsError(try dial.channel)
        driver.discover()
        XCTAssertEqual(driver.connected, [driver.identifier]); XCTAssertEqual(driver.openedPSMs, [route.psm])
        XCTAssertThrowsError(try dial.channel)
        driver.events?.opened(pair.0, identifier: driver.identifier, psm: route.psm)
        XCTAssertThrowsError(try dial.channel, "Native open is not authenticated readiness")
        try await sink.authenticate(requireEffectAuthorization: {}); try await task.value
        let child = try dial.channel
        let packet = try f.packet()
        async let incoming = sink.receive(requireEffectAuthorization: {})
        try await child.send(packet, requireEffectAuthorization: {})
        let actual = try await incoming; XCTAssertEqual(actual, packet)
        try await dial.closeAndAwait(); try await sink.closeAndAwait()
        XCTAssertTrue(dial.isClosed); XCTAssertFalse(dial.cleanupPending)
        XCTAssertEqual(driver.detachCount, 1); XCTAssertNil(driver.events)
    }

    func testEstablishedChildSurvivesPreparationExpiryButNotParentRevocation() async throws {
        let f = try BluetoothAudioFixture.load(), driver = Driver(), pair = try streams()
        let clock = OSAllocatedUnfairLock(initialState: ContinuousClock.now)
        let allowed = OSAllocatedUnfairLock(initialState: true)
        let owner = try f.attachment(.source, current: {
            guard allowed.withLock({ $0 }) else { throw Failure.revoked }
        }, now: { clock.withLock { $0 } })
        try owner.requireLifetimeCurrent()
        XCTAssertThrowsError(try owner.requireEstablishedCurrent())
        let dial = try connector(f, driver, attachment: owner, now: { clock.withLock { $0 } })
        let sink = BluetoothAudioChannel(transport: pair.1, attachment: try f.attachment(.sink))
        let task = Task { try await dial.connect() }
        try await until { !driver.scanned.isEmpty }; driver.discover()
        driver.events?.opened(pair.0, identifier: driver.identifier, psm: try psm(f))
        try await sink.authenticate(requireEffectAuthorization: {}); try await task.value
        clock.withLock { $0 = $0.advanced(by: .seconds(60)) }
        try owner.requireLifetimeCurrent(); try owner.requireEstablishedCurrent()
        try await Task.sleep(for: .milliseconds(100)) // Allow the active lifetime monitor to run.
        _ = try dial.channel
        allowed.withLock { $0 = false }
        try await until { dial.cleanupPending }
        XCTAssertThrowsError(try dial.channel)
        try await dial.closeAndAwait(); try await sink.closeAndAwait()
        XCTAssertTrue(dial.isClosed)
    }

    func testCancellingPendingDialClosesLateConnectWithoutOpeningChannel() async throws {
        let f = try BluetoothAudioFixture.load(), driver = Driver()
        driver.autoConnect = false; driver.acknowledgeStop = false
        let dial = try connector(f, driver)
        let task = Task { try await dial.connect() }
        try await until { !driver.scanned.isEmpty }; driver.discover()
        try await until { !driver.connected.isEmpty }
        task.cancel(); try await until { driver.stops > 0 }
        driver.completeConnect()
        XCTAssertTrue(driver.openedPSMs.isEmpty)
        XCTAssertFalse(dial.isClosed)
        driver.completeDisconnect()
        let error = await failure { try await task.value }
        XCTAssertTrue(error is CancellationError, "\(String(describing: error))")
        XCTAssertTrue(dial.isClosed); XCTAssertNil(driver.events)
    }

    func testUnconfirmedDisconnectRetainsOwnerForExplicitCleanupRetry() async throws {
        let f = try BluetoothAudioFixture.load(), driver = Driver()
        driver.autoConnect = false; driver.acknowledgeStop = false
        let dial = try connector(f, driver)
        let task = Task { try await dial.connect() }
        try await until { !driver.scanned.isEmpty }; driver.discover()
        task.cancel()
        let error = await failure { try await task.value }
        guard case .cleanupFailed(let primary, let cleanup) = error as? BluetoothAudioConnectorError else {
            driver.completeDisconnect(); try await dial.closeAndAwait()
            return XCTFail("Missing retained cleanup failure: \(String(describing: error))")
        }
        XCTAssertTrue(primary is CancellationError)
        guard case .cleanupUnconfirmed = cleanup as? BluetoothAudioConnectorError else { return XCTFail("Wrong cleanup failure") }
        XCTAssertTrue(dial.cleanupPending); XCTAssertFalse(dial.isClosed); XCTAssertNotNil(driver.events)
        driver.completeDisconnect()
        try await dial.closeAndAwait()
        XCTAssertTrue(dial.isClosed); XCTAssertEqual(driver.detachCount, 1)
    }

    func testCancelledConcurrentCleanupCallersJoinOneNativeAcknowledgement() async throws {
        let f = try BluetoothAudioFixture.load(), driver = Driver()
        driver.autoConnect = false; driver.acknowledgeStop = false
        let dial = try connector(f, driver)
        let task = Task { try await dial.connect() }
        try await until { !driver.scanned.isEmpty }; driver.discover()
        let finished = OSAllocatedUnfairLock(initialState: 0)
        let first = Task { try await dial.closeAndAwait(); finished.withLock { $0 += 1 } }
        try await until { driver.stops > 0 }
        let second = Task { try await dial.closeAndAwait(); finished.withLock { $0 += 1 } }
        first.cancel(); second.cancel()
        try await Task.sleep(for: .milliseconds(20)); XCTAssertEqual(finished.withLock { $0 }, 0)
        driver.completeDisconnect()
        try await first.value; try await second.value
        _ = await failure { try await task.value }
        XCTAssertEqual(finished.withLock { $0 }, 2); XCTAssertEqual(driver.detachCount, 1)
    }

    func testRevokedDiscoveryDoesNotConnectAndUnavailableBluetoothDoesNotScan() async throws {
        let f = try BluetoothAudioFixture.load(), driver = Driver()
        let allowed = OSAllocatedUnfairLock(initialState: true)
        let dial = try connector(f, driver, check: {
            guard allowed.withLock({ $0 }) else { throw Failure.revoked }
        })
        let task = Task { try await dial.connect() }
        try await until { !driver.scanned.isEmpty }
        allowed.withLock { $0 = false }; driver.discover()
        let error = await failure { try await task.value }
        XCTAssertTrue(error is Failure); XCTAssertTrue(driver.connected.isEmpty); XCTAssertTrue(dial.isClosed)
        for state: CBManagerState in [.poweredOff, .unauthorized, .unsupported] {
            let off = Driver(); off.initialState = state
            let other = try connector(f, off)
            let error = await failure { try await other.connect() }
            guard case .unavailable(let actual) = error as? BluetoothAudioConnectorError else { return XCTFail("Missing native state") }
            XCTAssertEqual(actual, state.rawValue); XCTAssertTrue(off.scanned.isEmpty); XCTAssertTrue(other.isClosed)
        }
    }

    func testConnectionDeadlineRetiresDiscoveryWithoutNativeRetry() async throws {
        let f = try BluetoothAudioFixture.load(), driver = Driver()
        let clock = OSAllocatedUnfairLock(initialState: ContinuousClock.now)
        let dial = try connector(f, driver, now: { clock.withLock { $0 } })
        let task = Task { try await dial.connect(timeout: .seconds(1)) }
        try await until { !driver.scanned.isEmpty }
        clock.withLock { $0 = $0.advanced(by: .seconds(2)) }
        let error = await failure { try await task.value }
        guard case .timedOut = error as? BluetoothAudioConnectorError else { return XCTFail("Missing deadline: \(String(describing: error))") }
        XCTAssertTrue(driver.connected.isEmpty); XCTAssertEqual(driver.starts, 1); XCTAssertTrue(dial.isClosed)
    }

    func testInitialAuthorizationDenialIsTerminalAndAllocatesNoNativeManager() async throws {
        let f = try BluetoothAudioFixture.load(), driver = Driver()
        let allowed = OSAllocatedUnfairLock(initialState: false)
        let dial = try connector(f, driver, check: {
            guard allowed.withLock({ $0 }) else { throw Failure.revoked }
        })
        let rejected = await failure { try await dial.connect() }
        guard case .revoked = rejected as? Failure else { return XCTFail("Initial denial was not preserved") }
        XCTAssertEqual(driver.starts, 0); XCTAssertTrue(dial.isClosed)
        allowed.withLock { $0 = true }
        let repeated = await failure { try await dial.connect() }
        guard case .alreadyStarted = repeated as? BluetoothAudioConnectorError else { return XCTFail("A failed owner restarted") }
        XCTAssertEqual(driver.starts, 0)
    }

    func testWrongCandidateOrPSMNeverBecomesReadyAndHandoffWorkerIsClosed() async throws {
        let f = try BluetoothAudioFixture.load()
        for wrongCandidate in [true, false] {
            let driver = Driver(), pair = try streams()
            let dial = try connector(f, driver)
            let task = Task { try await dial.connect() }
            try await until { !driver.scanned.isEmpty }; driver.discover()
            driver.events?.opened(pair.0, identifier: wrongCandidate ? UUID() : driver.identifier,
                                  psm: wrongCandidate ? try psm(f) : 255)
            let error = await failure { try await task.value }
            guard case .unexpectedCallback = error as? BluetoothAudioConnectorError else { return XCTFail("Foreign native channel escaped") }
            XCTAssertTrue(pair.0.isClosed); XCTAssertThrowsError(try dial.channel)
            try await dial.closeAndAwait(); XCTAssertTrue(dial.isClosed)
        }
    }

    func testCancellationDuringChildAuthenticationClosesNativeWorker() async throws {
        let f = try BluetoothAudioFixture.load(), driver = Driver(), pair = try streams()
        let dial = try connector(f, driver)
        let task = Task { try await dial.connect() }
        try await until { !driver.scanned.isEmpty }; driver.discover()
        driver.events?.opened(pair.0, identifier: driver.identifier, psm: try psm(f))
        // Read the real source Hello but never answer it. Cancellation must wake
        // the actual native read, not merely finish a fake callback promise.
        let hello = try await pair.1.readFrame(maximumBytes: 4096, timeout: .seconds(2))
        XCTAssertFalse(hello.isEmpty)
        task.cancel()
        let error = await failure { try await task.value }
        XCTAssertTrue(error is CancellationError, "\(String(describing: error))")
        XCTAssertTrue(pair.0.isClosed); XCTAssertTrue(dial.isClosed); XCTAssertEqual(driver.detachCount, 1)
    }

    private func connector(_ f: BluetoothAudioFixture, _ driver: Driver, attachment: AudioBluetoothAttachment? = nil,
                           check: @escaping @Sendable () throws -> Void = {},
                           now: @escaping @MainActor () -> ContinuousClock.Instant = { .now }) throws -> BluetoothAudioConnector {
        let owner = try BluetoothAudioConnector(attachment: attachment ?? f.attachment(.source), requireCurrent: check,
                                                makeDriver: { driver }, now: now)
        addTeardownBlock { @MainActor in driver.completeDisconnect(); try await owner.closeAndAwait() }
        return owner
    }
    private func psm(_ f: BluetoothAudioFixture) throws -> UInt16 {
        guard case .bluetoothRoute(let route) = try f.binding(.source).route.body else { throw Failure.eventTimeout }
        return route.psm
    }
    private func streams() throws -> (BluetoothControlFrameTransport, BluetoothControlFrameTransport) {
        var forwardIn: InputStream?, forwardOut: OutputStream?, reverseIn: InputStream?, reverseOut: OutputStream?
        Stream.getBoundStreams(withBufferSize: 17, inputStream: &forwardIn, outputStream: &forwardOut)
        Stream.getBoundStreams(withBufferSize: 17, inputStream: &reverseIn, outputStream: &reverseOut)
        let source = try BluetoothControlFrameTransport(input: XCTUnwrap(reverseIn), output: XCTUnwrap(forwardOut))
        let sink = try BluetoothControlFrameTransport(input: XCTUnwrap(forwardIn), output: XCTUnwrap(reverseOut))
        addTeardownBlock { source.close(); sink.close(); try await source.closeAndAwait(); try await sink.closeAndAwait() }
        return (source, sink)
    }
    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw Failure.eventTimeout }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
    private func failure<T>(_ action: () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async -> (any Error)? {
        do { _ = try await action(); XCTFail("Expected failure", file: file, line: line); return nil }
        catch { return error }
    }

    private final class Driver: BluetoothAudioDialDriver {
        weak var events: (any BluetoothAudioDialEvents)?
        let identifier = UUID()
        var initialState = CBManagerState.poweredOn
        var autoConnect = true, acknowledgeStop = true
        var scanning = false, outstandingConnection = false
        var starts = 0, stops = 0, detachCount = 0
        var scanned: [UUID] = [], connected: [UUID] = [], openedPSMs: [UInt16] = []
        var isQuiescent: Bool { !scanning && !outstandingConnection }
        func start() { starts += 1; events?.stateChanged(initialState) }
        func scan(serviceID: UUID) { scanned.append(serviceID); scanning = true }
        func stopScan() { scanning = false }
        func discover() { events?.discovered(identifier) }
        func connect(identifier: UUID) {
            connected.append(identifier); outstandingConnection = true
            if autoConnect { completeConnect() }
        }
        func completeConnect() { outstandingConnection = true; events?.connected(identifier) }
        func open(psm: UInt16) { openedPSMs.append(psm) }
        func stop() {
            stops += 1; scanning = false
            if acknowledgeStop, outstandingConnection { completeDisconnect() }
        }
        func completeDisconnect() {
            guard outstandingConnection else { return }
            outstandingConnection = false; events?.disconnected(identifier, error: nil)
        }
        func detach() throws {
            guard isQuiescent else { throw BluetoothAudioConnectorError.cleanupUnconfirmed }
            detachCount += 1; events = nil
        }
    }
}
